import { test } from "node:test";
import assert from "node:assert/strict";
import { generateWorld } from "../src/worldgen.ts";
import { simulateGame, type GameSpec } from "../src/game.ts";
import { Rng } from "../src/rng.ts";
import type { World } from "../src/types.ts";
import {
  BAN_AT, GRUDGE_COOL_DAYS, afterGame, angerFaction, bleacherBan, coolGrudges, exposureChance, grudge, grudgeParties, hireCandidate, hostility,
  leanOnPress, opPlannerView, recruitPool, resolveOps, securityDetail, OP_KINDS, type CrewMember, type CrewSkill, type OpOrder, type OpOutcome,
} from "../src/crime/index.ts";

const SKILLS: CrewSkill[] = ["sneak", "charm", "muscle", "access", "nerve", "knowhow"];

function crewOf(world: World, owner: string, n: number, lvl: number, extra: Partial<CrewMember> = {}, tag = ""): Record<string, CrewMember> {
  const out: Record<string, CrewMember> = {};
  const cands = recruitPool(world, owner, 7);
  for (let i = 0; i < n; i++) {
    const cd = cands[i % cands.length];
    const c = hireCandidate(world, { ...cd, id: `${cd.id}-${tag}${i}`, person: { ...cd.person, id: `${cd.person.id}-${tag}${i}` } });
    for (const s of SKILLS) c.skills[s] = lvl;
    c.role = "usher";
    Object.assign(c, extra);
    out[c.id] = c;
  }
  return out;
}

// HCL hosts STA in these tests
const order = (o: Partial<OpOrder> & Pick<OpOrder, "kind" | "crew">): OpOrder => ({
  id: o.id ?? `o-${o.kind}`, ownerId: "acct1", gameId: "g1", targetTeamId: "STA", gear: [], placedDay: 1, opponentTeamId: "HCL", homeTeamId: "HCL", ...o,
});
const spec = (w: World, mods: GameSpec["modifiers"], id: string): GameSpec => ({
  id: "g1", day: 1, homeId: "HCL", awayId: "STA", umpireId: Object.values(w.npcs).find(n => n.role === "umpire")!.id,
  weather: { tempF: 72, windDir: 0, windMph: 5, rain: 0 }, modifiers: mods,
});
const fac = (w: World, team: string) => w.teams[team].factionId;

test("exposure makes the wronged owners hostile to every account on the job and its syndicate, with notices", () => {
  const w = generateWorld("grudge-1");
  const f = fac(w, "STA");
  let exposures = 0;
  const notices = new Set<string>();
  for (let i = 0; i < 40 && grudge(w, f, "acct1") < BAN_AT; i++) {
    const a = crewOf(w, "acct1", 2, 0, { heat: 10 }, `a${i}`);
    const b = crewOf(w, "acct2", 1, 0, { heat: 10 }, `b${i}`);
    const job = order({ id: `j${i}`, kind: "kidnap_mascot", crew: [...Object.keys(a), ...Object.keys(b)], syndicateId: "syn1", allies: ["acct2"] });
    const outs = resolveOps(w, [job], { ...a, ...b }, new Rng(`r${i}`));
    const res = simulateGame(w, spec(w, outs[0].modifiers, `g${i}`), `g-${i}`);
    const ag = afterGame(w, outs, res, new Rng(`ag${i}`));
    if (outs[0].exposed) exposures++;
    for (const m of ag.mail) if (m.id.startsWith("grudge:")) notices.add(`${m.ownerId}:${m.subject}`);
  }
  assert.ok(exposures > 0, "sloppy hot crews get exposed");
  // lol-risk jobs cost two points a time: the owners, the ally and the syndicate all carry it
  assert.ok(grudge(w, f, "acct1") >= BAN_AT, `acct1 grudge ${grudge(w, f, "acct1")}`);
  assert.ok(grudge(w, f, "acct2") >= BAN_AT);
  assert.ok(grudge(w, f, "syn1") >= BAN_AT);
  assert.equal(grudge(w, fac(w, "HCL") === f ? "nobody" : fac(w, "HCL"), "acct1"), 0, "other owners don't care");
  assert.ok(notices.has("acct1:We have hired some people") && notices.has("acct1:Your photograph"), [...notices].join(" | "));
  assert.ok(notices.has("acct2:Your photograph"), "allies are told too");
  assert.deepEqual(grudgeParties(w).filter(p => ["acct1", "acct2", "syn1"].includes(p)), ["acct1", "acct2", "syn1"]);
  // a syndicate grudge covers a member who was never on a job
  assert.ok(hostility(w, f, ["acct3", "syn1"]) >= BAN_AT);
  assert.equal(hostility(w, f, ["acct3"]), 0);
});

test("security details scale with hostility: lower success, higher exposure, noted in the planner and the mail", () => {
  assert.deepEqual(securityDetail(0), { success: 0, exposure: 1 });
  assert.ok(securityDetail(5).success > securityDetail(1).success && securityDetail(5).exposure > securityDetail(1).exposure);
  const w = generateWorld("grudge-2");
  const crew = crewOf(w, "acct1", 2, 3);
  const plain = opPlannerView(w, "grease_mound", "STA", Object.values(crew), [], undefined, { parties: ["acct1"], homeTeamId: "HCL" })!;
  angerFaction(w, fac(w, "STA"), "acct1", 3, "test");
  const guarded = opPlannerView(w, "grease_mound", "STA", Object.values(crew), [], undefined, { parties: ["acct1"], homeTeamId: "HCL" })!;
  assert.equal(plain.successPct - guarded.successPct, Math.round(securityDetail(3).success * 100));
  assert.ok(guarded.notes.some(n => /guards out for you/.test(n)), guarded.notes.join("; "));
  // security jobs aren't affected (you're guarding, not sneaking)
  const sec = opPlannerView(w, "security", "STA", Object.values(crew), [], undefined, { parties: ["acct1"] })!;
  assert.ok(!sec.notes.some(n => /guards out/.test(n)));

  let mine = 0, theirs = 0;
  for (let i = 0; i < 150; i++) {
    const a = crewOf(w, "acct1", 2, 3, {}, `x${i}`);
    const b = crewOf(w, "acct9", 2, 3, {}, `y${i}`);
    const out = resolveOps(w, [order({ id: "A", kind: "raccoons", crew: Object.keys(a) }), order({ id: "B", ownerId: "acct9", kind: "raccoons", crew: Object.keys(b), gameId: "g2" })], { ...a, ...b }, new Rng(`s${i}`));
    if (out[0].success) mine++;
    if (out[1].success) theirs++;
    assert.equal(out[0].guard, 3);
    assert.equal(out[1].guard, undefined);
    if (i === 0) assert.ok(out[0].mail.some(m => m.body.some(l => /men at the gates/.test(l))), "the job mail mentions the guards");
  }
  assert.ok(mine < theirs, `guarded jobs land less often (${mine} vs ${theirs})`);
  const base: OpOutcome = { orderId: "x", success: true, modifiers: [], exposed: false, heat: 0, arrests: [], mail: [], events: [], kind: "raccoons", crew: Object.values(crew), gear: [] };
  assert.ok(exposureChance(w, { ...base, guard: 4 }) > exposureChance(w, base) * 1.4);
});

test("bleacher ban: hostile owners keep your crew out of their park's stands", () => {
  const w = generateWorld("grudge-3");
  const bleacher = OP_KINDS.filter(k => k.bleachers).map(k => k.kind).sort();
  assert.deepEqual(bleacher, ["heckle", "laser", "steal_signs"]);
  const crew = crewOf(w, "acct1", 3, 3);
  const ctx = { parties: ["acct1", "syn1"], homeTeamId: "HCL" };
  assert.equal(opPlannerView(w, "laser", "STA", Object.values(crew), [], undefined, ctx)!.blocked, undefined);
  angerFaction(w, fac(w, "HCL"), "syn1", BAN_AT - 1, "test");
  assert.equal(bleacherBan(w, "laser", "HCL", ctx.parties), undefined, "one point short of a ban");
  angerFaction(w, fac(w, "HCL"), "syn1", 1, "test");
  const why = bleacherBan(w, "laser", "HCL", ctx.parties);
  assert.match(why ?? "", /^Banned from the .+ bleachers by /);
  assert.equal(opPlannerView(w, "laser", "STA", Object.values(crew), [], undefined, ctx)!.blocked, why);
  assert.equal(opPlannerView(w, "grease_mound", "STA", Object.values(crew), [], undefined, ctx)!.blocked, undefined, "only bleacher jobs");
  assert.equal(bleacherBan(w, "laser", "STA", ctx.parties), undefined, "their road games are fine");
  assert.equal(bleacherBan(w, "laser", "HCL", ["acct2"]), undefined, "strangers are fine");

  // a ban that lands after the order was placed calls the job off at the gate; nothing else happens
  const outs = resolveOps(w, [order({ id: "L", kind: "heckle", crew: Object.keys(crew), syndicateId: "syn1" })], crew, new Rng("ban"));
  const o = outs[0];
  assert.equal(o.calledOff, true);
  assert.equal(o.blocked, why);
  assert.equal(o.success, false);
  assert.equal(o.modifiers.length, 0);
  assert.ok(o.crew!.every(c => c.status === "free"));
  assert.ok(o.mail.some(m => /turned away/.test(m.subject)));
  const res = simulateGame(w, spec(w, [], "b"), "b");
  const ag = afterGame(w, outs, res, new Rng("ag"));
  assert.equal(o.exposed, false);
  assert.equal(ag.stories.length, 0);
  assert.ok(!ag.effects.some(e => e.kind === "heat"));
});

test("grudges cool a point a week and are dropped at zero, with mail on the way down", () => {
  const w = generateWorld("grudge-4");
  const f = fac(w, "HCL");
  angerFaction(w, f, "acct1", BAN_AT, "test");
  const len = w.relationships.length;
  let lifted = false, calm = false;
  for (let d = 0; d < GRUDGE_COOL_DAYS * BAN_AT + 1; d++) {
    w.day++;
    const { changes, mail } = coolGrudges(w);
    for (const c of changes) assert.equal(c.to, c.from - 1);
    if (mail.some(m => m.subject === "Notice to ticket holders" && m.ownerId === "acct1")) lifted = true;
    if (mail.some(m => m.subject === "Security detail")) calm = true;
    if (d < GRUDGE_COOL_DAYS - 1) assert.equal(grudge(w, f, "acct1"), BAN_AT, `day ${d}`);
  }
  assert.equal(grudge(w, f, "acct1"), 0);
  assert.ok(lifted && calm);
  assert.equal(w.relationships.length, len - 1, "the spent grudge is removed");
  // a fresh offence resets the clock
  angerFaction(w, f, "acct1", 1, "again");
  w.day += GRUDGE_COOL_DAYS - 1;
  assert.equal(coolGrudges(w).changes.length, 0);
  // people and factions are never cooled by this
  const people = w.relationships.filter(r => r.value < 0).length;
  w.day += 100;
  coolGrudges(w);
  assert.equal(w.relationships.filter(r => r.value < 0).length, people - 1);
});

test("hostile owners lean on SportsWire: unflattering items about your crew, more heat, scaled by hostility", () => {
  const w = generateWorld("grudge-5");
  const crew = Object.values(crewOf(w, "acct1", 2, 2));
  const crew2 = Object.values(crewOf(w, "acct2", 1, 2, {}, "z"));
  const none = leanOnPress(w, [{ ownerId: "acct1", crew }], new Rng("p"));
  assert.deepEqual(none, { stories: [], mail: [], effects: [] }, "no grudge, no calls");
  angerFaction(w, fac(w, "HCL"), "acct1", 1, "t");
  angerFaction(w, fac(w, "STA"), "syn2", 5, "t");
  let low = 0, high = 0;
  for (let i = 0; i < 400; i++) {
    const r = leanOnPress(w, [{ ownerId: "acct1", crew }, { ownerId: "acct2", syndicateId: "syn2", crew: crew2 }], new Rng(`p${i}`));
    for (const s of r.stories) {
      assert.equal(s.kind, "brief");
      assert.ok(s.people.length === 1 && w.npcs[s.people[0]], "names a crew member");
      assert.ok(![s.headline, s.dek, ...s.body].join(" ").includes("acct"), "never the account");
    }
    for (const e of r.effects) assert.ok(e.kind === "heat" && e.delta >= 1);
    low += r.effects.filter(e => e.kind === "heat" && e.ownerId === "acct1").length;
    high += r.effects.filter(e => e.kind === "heat" && e.ownerId === "acct2").length;
    if (i === 0) assert.deepEqual(r, leanOnPress(w, [{ ownerId: "acct2", syndicateId: "syn2", crew: crew2 }, { ownerId: "acct1", crew }], new Rng("p0")), "deterministic, order-free");
  }
  assert.ok(low > 4 && low < 35, `1 point: ~4% a day (${low}/400)`);
  assert.ok(high > 50 && high < 110, `5 points: ~20% a day (${high}/400)`);
});
