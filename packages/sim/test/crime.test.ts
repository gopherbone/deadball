import { test } from "node:test";
import assert from "node:assert/strict";
import { generateWorld } from "../src/worldgen.ts";
import { simulateGame, type GameSpec } from "../src/game.ts";
import { Rng } from "../src/rng.ts";
import type { Umpire, World } from "../src/types.ts";
import {
  OP_KINDS, GEAR, afterGame, canJoin, exposureChance, hireCandidate, leakTips, opChance, opModifiers, recruitPool, resolveChoice,
  resolveOps, splitCost, syndicateStandings, tickCrew, type CrewMember, type CrewSkill, type OpOrder, type OpOutcome,
} from "../src/crime/index.ts";

const SKILLS: CrewSkill[] = ["sneak", "charm", "muscle", "access", "nerve", "knowhow"];

function ump(world: World, corrupt?: number): Umpire {
  const u = Object.values(world.npcs).find(n => n.role === "umpire") as Umpire;
  if (corrupt !== undefined) u.stats.corruptible = corrupt;
  return u;
}

function spec(world: World, umpireId: string, modifiers: GameSpec["modifiers"] = [], id = "g1"): GameSpec {
  return { id, day: 1, homeId: "HCL", awayId: "STA", umpireId, weather: { tempF: 72, windDir: 0, windMph: 5, rain: 0 }, modifiers };
}

/** Hire `n` crew for an owner with every skill set to `lvl`. */
function crewOf(world: World, owner: string, n: number, lvl: number, extra: Partial<CrewMember> = {}): Record<string, CrewMember> {
  const out: Record<string, CrewMember> = {};
  const cands = recruitPool(world, owner, 7);
  for (let i = 0; i < n; i++) {
    const c = hireCandidate(world, { ...cands[i % cands.length], id: `${cands[i % cands.length].id}-${i}`, person: { ...cands[i % cands.length].person, id: `${cands[i % cands.length].person.id}-${i}` } });
    for (const s of SKILLS) c.skills[s] = lvl;
    c.role = "usher"; // no affinities with most ops
    Object.assign(c, extra);
    out[c.id] = c;
  }
  return out;
}

const order = (o: Partial<OpOrder> & Pick<OpOrder, "kind" | "crew">): OpOrder => ({
  id: o.id ?? `o-${o.kind}`, ownerId: "acct1", gameId: "g1", targetTeamId: "STA", gear: [], placedDay: 1, opponentTeamId: "HCL", ...o,
});

test("recruit pool is deterministic per owner and day, and hiring stores the NPC", () => {
  const w = generateWorld("crime");
  const before = Object.keys(w.npcs).length;
  const a = recruitPool(w, "acct1", 3, new Rng("x"));
  const b = recruitPool(w, "acct1", 3, new Rng("y"));
  assert.deepEqual(a.map(c => [c.person.first, c.person.last, c.role, c.skills]), b.map(c => [c.person.first, c.person.last, c.role, c.skills]));
  assert.notDeepEqual(a.map(c => c.person.last), recruitPool(w, "acct2", 3).map(c => c.person.last), "other owners see other faces");
  assert.notDeepEqual(a.map(c => c.person.last), recruitPool(w, "acct1", 4).map(c => c.person.last), "the board refreshes daily");
  assert.equal(a.length, 5);
  assert.equal(Object.keys(w.npcs).length, before, "candidates are not stored until hired");
  for (const c of a) {
    assert.ok(c.price > 0 && c.loyalty >= 0 && c.loyalty <= 5);
    for (const s of SKILLS) assert.ok(c.skills[s] >= 0 && c.skills[s] <= 5);
    assert.ok((c.person as { sex?: string }).sex === "M" || (c.person as { sex?: string }).sex === "F");
    assert.ok(c.pitch.length > 10);
  }
  const m = hireCandidate(w, a[0]);
  assert.equal(w.npcs[a[0].person.id].role, "crew");
  assert.equal(m.status, "free");
  assert.equal(m.personId, a[0].person.id);
});

test("catalog: every op is well formed and maps to modifiers on success", () => {
  const w = generateWorld("crime");
  assert.ok(OP_KINDS.length >= 14);
  for (const k of OP_KINDS) {
    assert.ok(k.name.length <= 26, `${k.kind} name fits the planner`);
    for (const g of k.gear) assert.ok(GEAR[g], `${k.kind} gear ${g} exists`);
    if (k.kind === "security" || k.storyline?.only) continue;
    const { mods } = opModifiers(w, order({ kind: k.kind, crew: [] }), 1);
    assert.ok(mods.length > 0, `${k.kind} produces modifiers`);
    for (const m of mods) assert.equal(m.source, `o-${k.kind}`);
  }
});

test("success chance responds to crew skills, gear and the umpire", () => {
  const w = generateWorld("crime");
  const weak = Object.values(crewOf(w, "acct1", 2, 0));
  const strong = Object.values(crewOf(w, "acct1", 2, 5));
  for (const k of OP_KINDS) {
    const lo = opChance(w, { kind: k.kind, targetTeamId: "STA", gear: [] }, weak).p;
    const hi = opChance(w, { kind: k.kind, targetTeamId: "STA", gear: [] }, strong).p;
    assert.ok(hi > lo + 0.2, `${k.kind}: strong crew ${hi} vs weak ${lo}`);
  }
  const mid = Object.values(crewOf(w, "acct1", 1, 2));
  const raw = opChance(w, { kind: "raccoons", targetTeamId: "STA", gear: [] }, mid).p;
  const geared = opChance(w, { kind: "raccoons", targetTeamId: "STA", gear: ["burlap_sack"] }, mid).p;
  assert.ok(geared > raw);
  const honest = ump(w, 20).id;
  const pHonest = opChance(w, { kind: "bribe_ump", targetTeamId: "STA", gear: [], umpireId: honest }, mid).p;
  ump(w, 75);
  const pCrooked = opChance(w, { kind: "bribe_ump", targetTeamId: "STA", gear: [], umpireId: honest }, mid).p;
  assert.ok(pCrooked > pHonest + 0.3, `corruptible ump ${pCrooked} vs honest ${pHonest}`);

  // empirically, through resolveOps
  let wins = { weak: 0, strong: 0 };
  for (let i = 0; i < 200; i++) {
    for (const [label, crew] of [["weak", crewOf(w, "a", 2, 1)], ["strong", crewOf(w, "a", 2, 4)]] as const) {
      const out = resolveOps(w, [order({ kind: "grease_mound", crew: Object.keys(crew), ownerId: "a" })], crew, new Rng(`s${i}${label}`));
      if (out[0].success) wins[label]++;
    }
  }
  assert.ok(wins.strong > wins.weak * 1.5, `strong ${wins.strong} vs weak ${wins.weak}`);
});

test("raccoon op fires the incident often, aimed at the target", () => {
  const w = generateWorld("rac-op");
  const u = ump(w);
  let fired = 0, ok = 0;
  for (let i = 0; i < 40; i++) {
    const crew = crewOf(w, "acct1", 3, 5);
    const out = resolveOps(w, [order({ kind: "raccoons", crew: Object.keys(crew), gear: ["burlap_sack", "eels"] })], crew, new Rng(`r${i}`));
    if (!out[0].success) continue;
    ok++;
    const res = simulateGame(w, spec(w, u.id, out[0].modifiers), `rac-${i}`);
    const inc = res.incidents.find(x => x.kind === "RACCOONS_BULLPEN");
    if (inc) {
      fired++;
      assert.equal(inc.team, "STA");
      assert.ok(inc.sources.includes(out[0].orderId));
    }
  }
  assert.ok(ok >= 30, `a skilled crew usually pulls it off (${ok}/40)`);
  assert.ok(fired >= ok * 0.25, `raccoons fire often when paid for (${fired}/${ok})`);
});

test("ump bribe against the visitors raises strikeouts for the home staff", () => {
  const u = ump(generateWorld("ump-op"), 80);
  let kBase = 0, kBribed = 0, kVictimBase = 0, kVictimBribed = 0;
  for (let i = 0; i < 60; i++) {
    const w = generateWorld("ump-op");
    (w.npcs[u.id] as Umpire).stats.corruptible = 80;
    const crew = crewOf(w, "acct1", 1, 5);
    const out = resolveOps(w, [order({ kind: "bribe_ump", crew: Object.keys(crew), gear: ["envelope"], umpireId: u.id })], crew, new Rng(`b${i}`));
    const base = simulateGame(generateWorld("ump-op"), spec(w, u.id), `u-${i}`);
    const fixed = simulateGame(w, spec(w, u.id, out[0].modifiers), `u-${i}`);
    kBase += base.home.pitch.reduce((a, p) => a + p.k, 0);
    kBribed += fixed.home.pitch.reduce((a, p) => a + p.k, 0);
    kVictimBase += base.away.pitch.reduce((a, p) => a + p.k, 0);
    kVictimBribed += fixed.away.pitch.reduce((a, p) => a + p.k, 0);
  }
  assert.ok(kBribed > kBase * 1.05, `favoured staff Ks ${kBase} -> ${kBribed}`);
  assert.ok(kVictimBribed < kVictimBase, `victim staff Ks ${kVictimBase} -> ${kVictimBribed}`);
});

test("sprinklers make the target boot more balls", () => {
  let eBase = 0, eWet = 0;
  for (let i = 0; i < 80; i++) {
    const w = generateWorld("wet");
    const u = ump(w);
    const { mods } = opModifiers(w, order({ kind: "sprinklers", crew: [] }), 1.2);
    eBase += simulateGame(w, spec(w, u.id), `w-${i}`).away.errors;
    eWet += simulateGame(w, spec(w, u.id, mods), `w-${i}`).away.errors;
  }
  assert.ok(eWet > eBase, `errors ${eBase} -> ${eWet}`);
});

test("exposure, arrests and snitches", () => {
  const w = generateWorld("expose");
  const u = ump(w);
  let exposed = 0, arrests = 0, snitchCards = 0, arrestCards = 0, stories = 0;
  for (let i = 0; i < 60; i++) {
    const crew = crewOf(w, "acct1", 3, 1, { heat: 9, loyalty: i % 2 ? 1 : 4 });
    const out = resolveOps(w, [order({ id: `o${i}`, kind: "kidnap_mascot", crew: Object.keys(crew), gear: ["eels"] })], crew, new Rng(`e${i}`));
    const res = simulateGame(w, spec(w, u.id, out[0].modifiers), `e-${i}`);
    const ag = afterGame(w, out, res, new Rng(`ag${i}`));
    if (out[0].exposed) exposed++;
    arrests += out[0].arrests.length;
    snitchCards += ag.events.filter(e => e.kind === "snitch").length + out[0].events.filter(e => e.kind === "snitch").length;
    arrestCards += ag.events.filter(e => e.kind === "arrest").length + out[0].events.filter(e => e.kind === "arrest").length;
    stories += ag.stories.length;
    for (const id of out[0].arrests) assert.equal(out[0].crew!.find(c => c.id === id)!.status, "jailed");
    for (const c of out[0].crew!) assert.notEqual(c.status, "busy", "crew come home after the game");
    if (out[0].exposed) {
      assert.ok(ag.mail.some(m => m.kind === "league"));
      assert.ok(out[0].heat >= 3);
    }
  }
  assert.ok(exposed >= 15, `hot sloppy crews get exposed (${exposed}/60)`);
  assert.ok(arrests > 0 && snitchCards > 0 && arrestCards > 0, `arrests ${arrests}, snitch ${snitchCards}, arrest ${arrestCards}`);
  assert.ok(stories > 0);

  // a cold, sneaky crew on a low-risk job is rarely caught
  const sneaky: OpOutcome = { orderId: "x", success: true, modifiers: [], exposed: false, heat: 0, arrests: [], mail: [], events: [], kind: "lucky_glove",
    crew: Object.values(crewOf(w, "acct1", 1, 5)), gear: [] };
  const sloppy: OpOutcome = { ...sneaky, kind: "kidnap_mascot", success: false, crew: Object.values(crewOf(w, "acct1", 1, 0, { heat: 10 })) };
  assert.ok(exposureChance(w, sneaky) < 0.06);
  assert.ok(exposureChance(w, sloppy) > 0.4);
});

test("event card choices resolve to effects, deterministically", () => {
  const w = generateWorld("cards");
  const u = ump(w);
  let card;
  for (let i = 0; i < 200 && !card; i++) {
    const crew = { ...crewOf(w, "acct1", 1, 0, { heat: 10, loyalty: 4 }), ...crewOf(w, "acct2", 1, 0, { heat: 10, loyalty: 4 }) };
    const out = resolveOps(w, [order({ id: `c${i}`, kind: "cooler", crew: Object.keys(crew), syndicateId: "s1", allies: ["acct2"] })], crew, new Rng(`c${i}`));
    assert.deepEqual(out[0].participants, ["acct1", "acct2"]);
    const res = simulateGame(w, spec(w, u.id, out[0].modifiers), `c-${i}`);
    const ag = afterGame(w, out, res, new Rng(`c${i}`));
    card = [...out[0].events, ...ag.events].find(e => e.kind === "arrest" || e.kind === "snitch");
  }
  assert.ok(card, "got an arrest card");
  assert.ok(card.choices.length >= 3 && card.choices.length <= 4);
  assert.ok(card.title.length <= 48, card.title);
  const keys = card.choices.map(c => c.key);
  for (const k of keys) {
    const r1 = resolveChoice(w, card, k, new Rng("z"));
    const r2 = resolveChoice(w, card, k, new Rng("z"));
    assert.deepEqual(r1.effects, r2.effects, "deterministic");
    assert.ok(r1.result.length > 0 && r1.mail.length > 0);
    const cost = card.choices.find(c => c.key === k)!.cost;
    if (cost) assert.ok(r1.effects.some(e => e.kind === "money" && e.delta === -cost));
    if (k === "deal") {
      const heat = r1.effects.filter(e => e.kind === "heat");
      assert.deepEqual(heat.map(h => h.ownerId).sort(), ["acct1", "acct2"], "the deal names the whole syndicate");
      assert.equal(r1.events.filter(e => e.kind === "named").length, 2);
      const named = r1.events[0];
      const pay = resolveChoice(w, named, "pay", new Rng("q"));
      assert.ok(pay.effects.some(e => e.kind === "money"));
    }
    if (k === "lawyer") assert.ok(r1.effects.some(e => e.kind === "crew"));
  }
  const fallback = resolveChoice(w, card, "nonsense", new Rng("z"));
  assert.deepEqual(fallback, resolveChoice(w, card, card.defaultKey!, new Rng("z")));
  // lawyer odds: over many seeds, some acquittals and some convictions
  const verdicts = new Set<string>();
  for (let i = 0; i < 40; i++) {
    const e = resolveChoice(w, card, "lawyer", new Rng(`l${i}`)).effects.find(x => x.kind === "crew");
    if (e && e.kind === "crew") verdicts.add(e.status);
  }
  assert.deepEqual([...verdicts].sort(), ["free", "jailed"]);
});

test("tips leak to rivals, never to syndicate allies, and include false rumours", () => {
  const w = generateWorld("tips");
  const crew = crewOf(w, "acct1", 2, 0);
  const orders = [order({ kind: "raccoons", crew: Object.keys(crew), syndicateId: "s1" })];
  let rivalTips = 0, falseTips = 0;
  for (let d = 0; d < 80; d++) {
    const mail = leakTips(w, orders, ["acct1", "ally", "rival"], d, new Rng(`t${d}`), {
      syndicateOf: { acct1: "s1", ally: "s1", rival: "s2" }, crew, games: [{ id: "g1", homeId: "HCL", awayId: "STA" }],
    });
    for (const m of mail) {
      if (m.truth) assert.notEqual(m.ownerId, "acct1", "you don't get tipped about your own job");
      if (m.truth) assert.notEqual(m.ownerId, "ally", "allies never get tipped about each other");
      if (m.ownerId === "rival" && m.truth) rivalTips++;
      if (m.truth === false) falseTips++;
      assert.equal(m.kind, "tip");
    }
  }
  assert.ok(rivalTips >= 5, `rivals hear about sloppy jobs (${rivalTips})`);
  assert.ok(falseTips >= 5, `rumours (${falseTips})`);
});

test("rival crews collide; security blunts jobs; syndicate crews pool", () => {
  const w = generateWorld("turf");
  const a = crewOf(w, "acct1", 2, 4);
  const b = crewOf(w, "rival", 2, 4);
  const all = { ...a, ...b };
  const outs = resolveOps(w, [
    order({ id: "A", kind: "grease_mound", crew: Object.keys(a), targetTeamId: "STA", opponentTeamId: "HCL" }),
    order({ id: "B", ownerId: "rival", kind: "grease_mound", crew: Object.keys(b), targetTeamId: "HCL", opponentTeamId: "STA" }),
  ], all, new Rng("turf"));
  for (const o of outs) {
    assert.ok(o.collision?.length, "collision noted");
    assert.ok(o.events.some(e => e.ctx?.rivalOwnerId), "turf card");
    assert.ok(o.mail.some(m => m.subject.includes("Another crew")));
  }
  const turf = outs[0].events.find(e => e.ctx?.rivalOwnerId)!;
  resolveChoice(w, turf, "escalate", new Rng("t"));
  assert.ok(w.relationships.some(r => r.a === "acct1" && r.b === "rival" && r.value < 0));

  // security
  let plain = 0, guarded = 0;
  for (let i = 0; i < 150; i++) {
    const att = crewOf(w, "acct1", 2, 3);
    const sec = crewOf(w, "guard", 3, 5);
    const job = order({ id: "J", kind: "raccoons", crew: Object.keys(att) });
    if (resolveOps(w, [job], att, new Rng(`p${i}`))[0].success) plain++;
    const res = resolveOps(w, [job, order({ id: "S", ownerId: "guard", kind: "security", crew: Object.keys(sec), targetTeamId: "STA" })], { ...att, ...sec }, new Rng(`p${i}`));
    if (res.find(o => o.orderId === "J")!.success) guarded++;
  }
  assert.ok(guarded < plain * 0.85, `security cuts success (${plain} -> ${guarded})`);

  // syndicates: allied crew only joins a syndicate job
  const ally = crewOf(w, "acct2", 2, 5);
  const solo = resolveOps(w, [order({ id: "X", kind: "heckle", crew: Object.keys(ally) })], ally, new Rng("x"));
  assert.equal(solo[0].crew!.length, 0, "can't borrow crew without a syndicate");
  const joint = order({ id: "Y", kind: "heckle", crew: [...Object.keys(a).slice(0, 1), ...Object.keys(ally)], syndicateId: "s1", allies: ["acct2"] });
  const j = resolveOps(w, [joint], { ...a, ...ally }, new Rng("y"));
  assert.equal(j[0].crew!.length, 3);
  assert.deepEqual(j[0].participants, ["acct1", "acct2"]);
  assert.deepEqual(Object.keys(j[0].heatBy!).sort(), ["acct1", "acct2"]);
  const cost = splitCost({ ...joint, gear: ["megaphone"] }, { ...a, ...ally });
  assert.equal(cost.acct1 + cost.acct2, OP_KINDS.find(k => k.kind === "heckle")!.cost + GEAR.megaphone.cost);

  const syns = [{ id: "s1", name: "The Pew Crew", members: ["acct1", "acct2"] }, { id: "s2", name: "Bleacher Bums", members: ["rival"] }];
  const table = syndicateStandings(syns, [...outs, ...j], { acct1: 100, acct2: 50, rival: 400 });
  assert.equal(table[0].syndicateId, "s2");
  assert.equal(table[1].ops, 2);
  assert.equal(canJoin(syns[0], "rival", syns).ok, false);
  assert.equal(canJoin({ ...syns[0], members: ["a", "b", "c", "d"] }, "e", syns).ok, false);
});

test("crew tick releases jailbirds", () => {
  const c: CrewMember = { id: "c", personId: "p", ownerId: "o", skills: { sneak: 1, charm: 1, muscle: 1, access: 1, nerve: 1, knowhow: 1 }, loyalty: 3, status: "jailed", heat: 3, until: 5 };
  assert.equal(tickCrew([c], 4).length, 0);
  assert.equal(tickCrew([c], 5).length, 1);
  assert.equal(c.status, "free");
});

test("storyline ops nudge arcs; targets respect secrecy; secret tips unlock them", async () => {
  const { storylineTargets, settleOps, secretTips } = await import("../src/crime/index.ts");
  const w = generateWorld("arcs");
  const ml = Object.values(w.players).filter(p => w.teams[p.teamId].level === "ML");
  const mk = (id: string, kind: string, visibility: "secret" | "rumoured" | "public", people: string[]) => {
    const s = { id, kind, people, teams: [w.players[people[0]].teamId], startedDay: 0, season: 1, visibility, stage: "ongoing", nudges: { expose: 0, inflame: 0, soothe: 0 }, data: {}, log: [] };
    (w.storylines ??= []).push(s as never);
    return s;
  };
  const affair = mk("slA", "affair", "public", [ml[0].id]);
  const debt = mk("slD", "gambling_debt", "rumoured", [ml[1].id]);
  const hidden = mk("slS", "affair", "secret", [ml[2].id]);
  const ids = storylineTargets(w).map(t => t.storylineId);
  assert.ok(ids.includes("slA") && ids.includes("slD") && !ids.includes("slS"), "secret arcs are hidden");
  assert.ok(storylineTargets(w, ["slS"]).some(t => t.storylineId === "slS"), "unless the account was tipped");
  const t = storylineTargets(w).find(x => x.storylineId === "slA")!;
  assert.ok(t.ops.some(o => o.kind === "love_letter" && o.nudge === "inflame") && t.label.includes(ml[0].last));

  const crew = crewOf(w, "acct1", 2, 5);
  const keys = Object.keys(crew);
  const orders: OpOrder[] = [
    order({ id: "L", kind: "love_letter", crew: [keys[0]], gameId: "", targetTeamId: "", storylineId: "slA" }),
    order({ id: "B", kind: "blackmail", crew: [keys[1]], gameId: "", targetTeamId: "", storylineId: "slD", nudge: "soothe" }),
  ];
  let inflamed = false, soothed = false;
  for (let i = 0; i < 20 && !(inflamed && soothed); i++) {
    const c2 = crewOf(w, "acct1", 2, 5);
    const k2 = Object.keys(c2);
    const outs = resolveOps(w, orders.map((o, j) => ({ ...o, crew: [k2[j]] })), c2, new Rng(`arc${i}`));
    for (const o of outs) {
      assert.equal(o.modifiers.length, 0, "gameless storyline jobs change no game");
      if (o.nudge?.applied && o.nudge.kind === "inflame") inflamed = true;
      if (o.nudge?.applied && o.nudge.kind === "soothe") soothed = true;
    }
    const settled = settleOps(w, outs, new Rng(`s${i}`));
    assert.ok(settled.mail.some(m => m.subject.startsWith("Report")));
  }
  assert.ok(inflamed && soothed);
  assert.ok(affair.nudges.inflame > 0 && debt.nudges.soothe > 0);

  // smooth_over needs a storyline target
  const off = resolveOps(w, [order({ id: "X", kind: "smooth_over", crew: [keys[0]], gameId: "" })], crew, new Rng("x"));
  assert.equal(off[0].summary, "No such storyline.");
  // tip_wire on an arc exposes it
  const tw = resolveOps(w, [order({ id: "T", kind: "tip_wire", crew: [keys[0]], gameId: "", targetTeamId: "", storylineId: "slS" })], crewOf(w, "acct1", 1, 5), new Rng("tw"));
  if (tw[0].success) assert.ok(hidden.nudges.expose > 0);

  // secret tips name the arc so the server can unlock it
  let tipped = 0;
  for (let d = 0; d < 60; d++) for (const m of secretTips(w, ["a", "b", "c"], d, new Rng(`st${d}`))) {
    assert.equal(m.storylineId, "slS");
    assert.ok(m.body[0].includes(ml[2].last));
    tipped++;
  }
  assert.ok(tipped > 5, `secret tips (${tipped})`);
});
