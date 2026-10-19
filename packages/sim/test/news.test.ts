import { test } from "node:test";
import assert from "node:assert/strict";
import { generateWorld } from "../src/worldgen.ts";
import { simulateGame, type GameResult, type GameSpec, type LogEv } from "../src/game.ts";
import type { Modifier } from "../src/modifiers.ts";
import type { World } from "../src/types.ts";
import { bbsPosts, rumorLines, wireLines, writeGameStories, writeLifeStories, writeScandalStory, HEADLINE_MAX, DEK_MAX, WIRE_MAX, type Story } from "../src/news/index.ts";
import { hireCandidate, recruitPool } from "../src/crime/index.ts";

const PAIRS: [string, string][] = [["HCL", "STA"], ["PEM", "MIL"], ["CSR", "NCG"], ["MRL", "ELC"]];

function play(world: World, i: number, modifiers: Modifier[] = []): { res: GameResult; game: GameSpec } {
  const umps = Object.values(world.npcs).filter(n => n.role === "umpire");
  const [homeId, awayId] = PAIRS[i % PAIRS.length];
  const game: GameSpec = { id: `g${i}`, day: 1 + (i % 150), homeId, awayId, umpireId: umps[i % umps.length].id, weather: { tempF: 75, windDir: 0, windMph: 8, rain: i % 7 === 0 ? 0.6 : 0 }, modifiers };
  return { res: simulateGame(world, game, `news-${i}`), game };
}

const chaos = (i: number): Modifier[] => i % 3 ? [] : [
  { id: "r", source: "op-r", target: { kind: "team", id: PAIRS[i % 4][1] }, effect: "incident", incident: "RACCOONS_BULLPEN", value: 200 },
  { id: "l", source: "op-l", target: { kind: "team", id: PAIRS[i % 4][0] }, effect: "incident", incident: "LASER_POINTER", value: 400 },
  { id: "f", source: "op-f", target: { kind: "game", id: `g${i}` }, effect: "incident", incident: "FOOD_POISONING", value: 150 },
  { id: "b", source: "op-b", target: { kind: "game", id: `g${i}` }, effect: "incident", incident: "BRAWL", value: 30 },
  { id: "d", source: "op-d", target: { kind: "game", id: `g${i}` }, effect: "incident", incident: "BLACKOUT", value: 100 },
];

function checkStory(world: World, s: Story) {
  assert.ok(s.headline.length > 0 && s.headline.length <= HEADLINE_MAX, `headline ${s.headline.length}: ${s.headline}`);
  assert.ok(s.dek.length > 0 && s.dek.length <= DEK_MAX, `dek ${s.dek.length}: ${s.dek}`);
  assert.ok(s.body.length >= 2 && s.body.length <= 6, `${s.body.length} paragraphs in ${s.headline}`);
  for (const p of s.body) {
    assert.ok(p.length > 20, `paragraph too short: ${p}`);
    assert.ok(!/undefined|NaN|\[object/.test(p), `bad interpolation: ${p}`);
  }
  assert.ok(!/undefined|NaN/.test(s.headline + s.dek), `bad interpolation: ${s.headline} / ${s.dek}`);
  for (const id of s.people) assert.ok(world.players[id] || world.npcs[id], `real person ${id}`);
  for (const t of s.teams) assert.ok(world.teams[t], `real team ${t}`);
}

test("every LogEv kind produces wire text; lines are short, caps, and aligned", () => {
  const w = generateWorld("wire");
  const kinds = new Set<string>();
  const texted = new Set<string>();
  for (let i = 0; i < 40; i++) {
    const { res } = play(w, i, chaos(i));
    const lines = wireLines(w, res);
    let last = -1;
    for (const l of lines) {
      assert.ok(l.text.length <= WIRE_MAX, `${l.text.length}: ${l.text}`);
      assert.equal(l.text, l.text.toUpperCase());
      assert.ok(l.i >= last && l.i < res.log.length, "indices ascend and point into the log");
      last = l.i;
      texted.add(res.log[l.i].k);
    }
    for (const e of res.log) kinds.add(e.k);
    // every plate appearance has an outcome line
    const pas = res.log.filter(e => e.k === "pa").length;
    const outcomes = lines.filter(l => { const e = res.log[l.i]; return e.k === "bip" || (e.k === "p" && /STRIKES|CALLED|WALKS|HIT BY|FANS|LOOKS/.test(l.text)); }).length;
    assert.ok(outcomes >= pas - 3, `PA outcomes ${outcomes} vs PAs ${pas}`); // a caught stealing can end a PA early
    // final line
    assert.ok(lines.some(l => l.text.startsWith("FINAL")));
  }
  const all: LogEv["k"][] = ["half", "pa", "p", "bip", "mv", "sb", "wp", "sub", "inc", "end"];
  for (const k of all) {
    assert.ok(kinds.has(k), `sims produced a ${k} event`);
    assert.ok(texted.has(k), `wire covers ${k}`);
  }
});

test("game stories: limits, real people, real facts", () => {
  const w = generateWorld("recaps");
  const heads = new Set<string>();
  for (let i = 0; i < 80; i++) {
    const { res, game } = play(w, i, chaos(i));
    const stories = writeGameStories(w, res, game, res.incidents);
    assert.ok(stories.length >= 1);
    const recap = stories[0];
    assert.equal(recap.kind, "recap");
    assert.equal(recap.gameId, res.id);
    assert.ok(recap.body.length >= 3);
    heads.add(recap.headline);
    for (const s of stories) checkStory(w, s);
    // the final score appears, and the winning pitcher is named
    const W = res.winner === "home" ? res.home : res.away, L = res.winner === "home" ? res.away : res.home;
    const text = [recap.headline, recap.dek, ...recap.body].join(" ");
    assert.ok(text.includes(`${W.runs}-${L.runs}`), `score in story: ${recap.headline}`);
    assert.ok(text.includes(w.players[res.decisions.w].last), "winning pitcher named");
    assert.ok(recap.people.includes(res.decisions.w));
    assert.ok(recap.faceIds.length > 0);
    // deterministic
    assert.deepEqual(writeGameStories(w, res, game, res.incidents), stories);
  }
  assert.ok(heads.size > 60, `headlines vary (${heads.size}/80)`);
});

test("life and metro stories, guarded against missing data", () => {
  const w = generateWorld("life");
  const ps = Object.values(w.players).filter(p => w.teams[p.teamId].level === "ML");
  const [a, b, c] = ps;
  const kid = ps.find(p => w.teams[p.teamId].level === "ML" && p !== a)!;
  kid.family.parents = [b.id];
  const events = [
    { id: "e1", day: 5, kind: "wedding", who: [a.id, b.id] },
    { id: "e2", day: 5, kind: "death", who: [c.id], data: { cause: "a bad clam" } },
    { id: "e3", day: 5, kind: "debut", who: [kid.id], teams: [kid.teamId] },
    { id: "e4", day: 5, kind: "trade", who: [a.id, b.id], teams: [a.teamId, "STA"] },
    { id: "e5", day: 5, kind: "callup", who: [c.id], teams: ["HCL-AA", "HCL"] },
    { id: "e6", day: 5, kind: "demotion", who: [b.id] },
    { id: "e7", day: 5, kind: "retirement", who: [a.id], data: { seasons: 14 } },
    { id: "e8", day: 5, kind: "drama", who: [a.id], data: { kind: "holdout" } },
    { id: "e9", day: 5, kind: "milestone", who: [a.id], data: { what: "100th homer" } },
    { id: "e10", day: 5, kind: "world", who: [], data: { sub: "strike", who: "dock", factionId: "pem" } },
    { id: "e11", day: 5, kind: "world", who: [], data: { type: "y2k" } },
    { id: "e12", day: 5, kind: "world", who: [], data: { topic: "comet" } },
    { id: "e13", day: 5, kind: "world", who: [] },
    { id: "e14", day: 5, kind: "birth", who: ["nobody"] },
    { id: "e15", day: 5, kind: "mystery", who: [] },
    { id: "e16", day: 5, kind: "award", who: [a.id], data: { award: "MVP" } },
    { id: "e17", day: 5, kind: "champion", who: [], teams: ["HCL"] },
    { id: "e18", day: 5, kind: "wedding", who: ["ghost"] },
  ];
  const stories = writeLifeStories(w, events);
  for (const s of stories) checkStory(w, s);
  const byHead = stories.map(s => s.headline).join(" | ");
  assert.ok(stories.some(s => s.kind === "trade"), byHead);
  assert.ok(stories.some(s => s.headline.includes(b.last) && /Son|Daughter|Dynasty|Another/.test(s.headline)), `dynasty story: ${byHead}`);
  assert.ok(stories.some(s => s.section === "Transactions" && s.kind === "brief"), "roundup");
  assert.ok(stories.some(s => /Hot Dogs|Strike|Picket/.test(s.headline)), `strike story: ${byHead}`);
  assert.ok(stories.filter(s => s.section === "Metro" || s.section === "Elsewhere").length >= 3);
  assert.ok(stories.every(s => s.dateline && /1996|19\d\d|20\d\d/.test(s.dateline)));
  assert.doesNotThrow(() => writeLifeStories(w, [{ id: "x", day: 1, kind: "death", who: [] }, { id: "y", day: 1, kind: "trade", who: [a.id] }]));
});

test("scandal stories name crew members, not accounts", () => {
  const w = generateWorld("scandal");
  const cands = recruitPool(w, "SECRET_ACCOUNT_NAME", 1);
  const crew = cands.slice(0, 2).map(c => hireCandidate(w, c));
  for (const kind of ["arrest", "exposed", "deal", "judge", "skipped", "convicted", "acquitted"] as const) {
    const s = writeScandalStory(w, { kind, day: 3, opKind: "raccoons", people: crew.map(c => c.personId), targetTeamId: "STA", gameId: "g1", factions: ["sta"] });
    assert.ok(s, kind);
    checkStory(w, s);
    const text = [s.headline, s.dek, ...s.body].join(" ");
    assert.ok(!text.includes("SECRET_ACCOUNT_NAME"));
    assert.ok(text.includes(w.npcs[crew[0].personId].last), `${kind} names the crew`);
    assert.equal(s.kind, "scandal");
  }
  const tip = writeScandalStory(w, { kind: "tip", day: 3, opKind: "tip_wire", people: [], targetTeamId: "MIL" });
  assert.ok(tip);
  checkStory(w, tip);
  const mascot = writeScandalStory(w, { kind: "op", day: 3, opKind: "kidnap_mascot", people: [], targetTeamId: "MIL" });
  assert.ok(mascot && /Mascot/.test(mascot.headline));
  const posts = bbsPosts(w, 3, [tip, mascot], { tips: ["raccoons tonight"] });
  assert.equal(posts.length, 5);
  for (const p of posts) assert.ok(p.text.length > 0 && p.subject.length <= 48);
});

test("drama desk: every drama kind gets a deadpan story; secrets stay secret; fame leads", () => {
  const w = generateWorld("drama");
  const ml = Object.values(w.players).filter(p => w.teams[p.teamId].level === "ML");
  const [a, b, c, d] = ml;
  a.fame = 90; b.fame = 5;
  const T = a.teamId;
  const ev = (id: string, kind: string, who: string[], data: Record<string, unknown> = {}, teams = [T]) => ({ id, day: 9, kind, who, teams, data });
  const events = [
    ev("d1", "drama", [b.id, "n0"], { kind: "debt", what: "owes Bets By Bobby $1400", amount: 1400 }),
    ev("d2", "drama", [a.id], { kind: "scandal", what: "found asleep in the visitors' bullpen" }),
    ev("d3", "fight", [a.id, b.id], { sub: "bar", where: "bar", hurt: [{ id: b.id, days: 9 }], suspended: [a.id] }),
    ev("d4", "beanball", [c.id, d.id], { sub: "retaliation", injured: false, why: "a grudge" }),
    ev("d5", "fame", [a.id], { sub: "tier", tier: "national icon", fame: 91, why: "a walk-off" }),
    ev("d6", "fame", [b.id], { sub: "nickname", nickname: "the Hammer", why: "a homer" }),
    ev("d7", "fame", [c.id], { sub: "endorsement", brand: "Pepper Cola", fee: 300 }),
    ev("d8", "goal", [c.id], { sub: "achieved", goal: "win_title", note: "win a title", how: "the Continental Series", yearsWanted: 6 }),
    ev("d9", "fear", [a.id, b.id, c.id], { sub: "realized", fear: "flying", what: "refusing to fly; taking the bus" }),
    ev("d10", "drama", [c.id, d.id], { sub: "hazing", what: "taped to a goalpost in his underwear", tookItBadly: true }),
    ev("d11", "drama", [d.id, c.id], { sub: "vendetta", injured: d.id, culprit: c.id, friends: [b.id], cause: "a spike to the knee" }),
    // storyline beats
    ev("s1", "drama", [a.id, b.id], { kind: "feud", storyline: "sl1", stage: "public_spat", visibility: "public", how: "shouting match in the dugout", cause: "a bat-flip" }),
    ev("s2", "drama", [b.id, "n0"], { kind: "gambling_debt", storyline: "sl2", stage: "shaving", visibility: "public", amount: 2200 }),
    ev("s3", "drama", [b.id, "n0"], { kind: "gambling_debt", storyline: "sl2", stage: "resolved", outcome: "ejected_from_league", visibility: "public" }),
    ev("s4", "drama", [c.id], { kind: "curse", storyline: "sl3", stage: "cursed", visibility: "public", begins: true, cause: "a raccoon crossed his path at the ballpark" }),
    ev("s5", "drama", [d.id], { kind: "stalker", storyline: "sl4", stage: "resolved", outcome: "arrested", visibility: "public", how: "caught in the team bus luggage bay" }),
    ev("s6", "drama", [a.id], { kind: "affair", storyline: "sl5", stage: "ongoing", visibility: "secret", secret: true }),
    ev("s7", "drama", [a.id, b.id], { kind: "feud", storyline: "sl6", stage: "words", visibility: "rumoured", cause: "a stolen parking spot" }),
    // the weird tier
    ev("w1", "drama", [c.id], { kind: "weird", sub: "weird", storyline: "sl7", stage: "missing", visibility: "public", begins: true, weird: "abduction", days: 6, cause: "his car found idling on a county road, radio playing static" }),
    ev("w2", "drama", [c.id], { kind: "weird", sub: "weird", storyline: "sl7", stage: "resolved", outcome: "returned_changed", visibility: "public", weird: "abduction", days: 6, power: "WARP_PITCH", says: "says 'they were very polite'" }),
    ev("w3", "weird", [c.id], { sub: "abduction_return", storyline: "sl7", power: "WARP_PITCH" }),
    ev("w4", "weird", [b.id, d.id], { sub: "plane_crash", where: "Lake Oneida", dead: [{ id: b.id }, { id: d.id }], cause: "a flock of geese", survivors: 22 }),
    ev("w5", "weird", [d.id], { sub: "resurrection", diedYear: 1971, wasDeadYears: 26, how: "found sitting in the dugout at dawn" }),
    ev("w6", "weird", [c.id, a.id], { sub: "clone", original: a.id, where: "a Cold Spring cattle auction" }),
    ev("w7", "weird", [d.id], { sub: "historical_arrival", figure: "Ulysses S. Grant", era: "1860s", how: "climbed out of a time capsule dug up in Millbrook" }),
    ev("w8", "release", [b.id], { reason: "banned for life: point shaving", banned: true, dramatic: true }),
  ];
  const stories = writeLifeStories(w, events);
  const byId = new Map(stories.map(s => [s.id.replace("story:life:", ""), s]));
  for (const s of stories) {
    checkStory(w, s);
    assert.ok(!/!/.test(s.headline + s.dek), `deadpan: no exclamation marks (${s.headline})`);
  }
  for (const id of ["d1", "d2", "d3", "d4", "d5", "d6", "d7", "d8", "d9", "d10", "d11", "s1", "s2", "s3", "s4", "s5", "w1", "w2", "w4", "w5", "w6", "w7", "w8"]) assert.ok(byId.has(id), `story for ${id}`);
  assert.ok(!byId.has("s6"), "secret beats are never printed");
  assert.ok(!byId.has("s7"), "rumoured beats go to the BBS, not the paper");
  assert.ok(!byId.has("w3"), "the return is told once");
  assert.match(byId.get("w2")!.body.join(" "), /before they are released/);
  assert.match(byId.get("w7")!.headline, /Grant/);
  assert.match(byId.get("w4")!.body.join(" "), new RegExp(b.last));
  // fame leads the page: the icon's scandal outranks the nobody's debt
  assert.ok((byId.get("d2")!.prominence ?? 0) > (byId.get("d1")!.prominence ?? 0));
  for (let i = 1; i < stories.length; i++) assert.ok((stories[i - 1].prominence ?? 1) >= (stories[i].prominence ?? 1), "sorted by prominence");
  // photos where the archive has a fit
  assert.ok(stories.filter(s => s.photo).length >= stories.length * 0.8);
  // rumours for the BBS
  const rumors = rumorLines(w, events);
  assert.equal(rumors.length, 1);
  assert.ok(rumors[0].includes(a.last));
  const posts = bbsPosts(w, 9, stories, { tips: rumors, count: 8 });
  assert.equal(posts.length, 8);
});

test("deadpan recaps: no exclamation marks, no winks", () => {
  const w = generateWorld("tone");
  for (let i = 0; i < 40; i++) {
    const { res, game } = play(w, i, chaos(i));
    for (const s of writeGameStories(w, res, game, res.incidents)) {
      const text = [s.headline, s.dek, ...s.body].join(" ");
      assert.ok(!/!/.test(s.headline + s.dek), s.headline);
      assert.ok(!/\b(lol|lmao|IMHO)\b/i.test(text));
    }
  }
});

test("enhanced powers: wire lines, box notes, recap lines; a Continental game makes it a scandal", async () => {
  const { boxNotes, ultraUses } = await import("../src/news/index.ts");
  const w = generateWorld("ultra");
  for (const id of [...w.teams.HCL.roster, ...w.teams.STA.roster]) {
    const p = w.players[id];
    (p as { powers?: unknown }).powers = p.pos === "P" ? [{ kind: "FIREBALL", level: 3 }, { kind: "CLOUD_BALL", level: 2 }] : [{ kind: "HYPER_HIT", level: 3 }, { kind: "LEAP_CATCH", level: 2 }];
  }
  let seen = 0;
  for (let i = 0; i < 12; i++) {
    const { res, game } = play(w, i * 4); // HCL vs STA
    const uses = ultraUses(res);
    if (!uses.length) continue;
    seen++;
    const lines = wireLines(w, res);
    for (const u of uses) assert.ok(lines.some(l => l.i === u.i && l.text.length <= WIRE_MAX), "every power use is on the wire");
    const notes = boxNotes(w, res);
    assert.ok(notes.length >= 1 && notes.every(n => n.startsWith("POWERS")));
    const stories = writeGameStories(w, res, game, res.incidents);
    for (const s of stories) checkStory(w, s);
    assert.ok(stories[0].body.some(p => /Enhanced powers were used/.test(p)));
    const scandal = stories.find(s => s.id.endsWith(":powers"));
    assert.ok(scandal && scandal.kind === "scandal", "powers in a Continental game are a scandal");
    // the same game in the Enhanced League is just a game
    w.teams.HCL.level = "EL" as never;
    assert.ok(!writeGameStories(w, res, game, res.incidents).some(s => s.id.endsWith(":powers")));
    w.teams.HCL.level = "ML";
  }
  assert.ok(seen >= 6, `powers used in ${seen}/12 games`);
});

test("enhanced league desks: transfers, exhibitions, investigations, the Mirage Cup", () => {
  const w = generateWorld("el");
  const p = Object.values(w.players).find(x => w.teams[x.teamId].level === "ML")!;
  const elTeam = Object.values(w.teams).find(t => t.level === "EL") ?? (() => { w.teams.ELC.level = "EL" as never; return w.teams.ELC; })();
  const ev = (id: string, kind: string, who: string[], data: Record<string, unknown>, teams?: string[]) => ({ id, day: 30, kind, who, teams, data });
  const stories = writeLifeStories(w, [
    ev("t1", "transfer", [p.id], { sub: "to_enhanced", from: p.teamId, to: elTeam.id, cause: "a pitch that stopped in midair" }, [p.teamId, elTeam.id]),
    ev("t2", "transfer", [p.id], { sub: "return", to: p.teamId }, [p.teamId]),
    ev("x1", "exhibition", [], { winner: elTeam.id, loser: "HCL", score: "9-2", powers: 6 }, [elTeam.id, "HCL"]),
    ev("i1", "drama", [p.id], { kind: "enhanced_watch", storyline: "slE", stage: "investigation", visibility: "rumoured" }),
    ev("i2", "drama", [p.id], { kind: "enhanced_watch", storyline: "slE", stage: "investigation", visibility: "public", how: "an opposing manager filed a protest" }),
    ev("c1", "champion", [], { series: "the Mirage Cup", score: "4-1" }, [elTeam.id]),
  ]);
  const ids = new Set(stories.map(s => s.id.replace("story:life:", "")));
  for (const id of ["t1", "t2", "x1", "i2", "c1"]) assert.ok(ids.has(id), id);
  assert.ok(!ids.has("i1"), "rumoured investigation stays off the page");
  for (const s of stories) checkStory(w, s);
  assert.ok(stories.some(s => /Mirage Cup/.test(s.headline + s.body.join(" "))));
});
