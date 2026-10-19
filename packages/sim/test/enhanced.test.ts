import { test } from "node:test";
import assert from "node:assert/strict";
import { generateWorld } from "../src/worldgen.ts";
import { Rng } from "../src/rng.ts";
import type { Umpire, World } from "../src/types.ts";
import {
  REGULAR_DAYS, advanceSeasonDay, enhancedSlate, newSeason, recordResult, slateFor, standings, type ScheduledGame, type SeasonState,
} from "../src/league/index.ts";
import { simulateGame } from "../src/game.ts";
import { moodModifiers } from "../src/life/drama.ts";
import type { LifeEvent } from "../src/life/events.ts";
import { rosterProblems } from "../src/life/roster.ts";
import { TEMPLATE, groupOf } from "../src/life/ratings.ts";
import { transferToEnhanced, unexplained } from "../src/life/enhanced.ts";
import { ENHANCED_CLUBS, enhancedTeamIds } from "../src/league/enhanced.ts";

test("worldgen: six desert clubs with odd parks, powered rosters, their own umpires", () => {
  const w = generateWorld("desert");
  const ids = enhancedTeamIds(w);
  assert.equal(ids.length, 6);
  assert.deepEqual(ids.sort(), ENHANCED_CLUBS.map(c => c.abbr).sort());
  let powered = 0;
  for (const id of ids) {
    const t = w.teams[id];
    assert.equal(t.level, "EL");
    assert.equal(t.circuit, "enhanced");
    assert.ok(!t.parentId, "no farm system");
    const groups: Record<string, number> = {};
    for (const pid of t.roster) { const p = w.players[pid]; groups[groupOf(p)] = (groups[groupOf(p)] ?? 0) + 1; if (p.powers?.length) powered++; }
    assert.deepEqual(groups, TEMPLATE, `${id} roster template`);
    assert.ok(w.parks[t.parkId].climate && w.parks[t.parkId].climate!.temp > 5, "a hot park");
    assert.ok(w.factions[t.factionId], "owned by a faction");
  }
  assert.ok(powered >= 30 && powered <= 90, `powered players (${powered})`);
  assert.ok(Object.values(w.players).some(p => p.historical && w.teams[p.teamId]?.level === "EL"), "historical figures already out there");
  assert.ok((Object.values(w.npcs).filter(n => n.role === "umpire") as Umpire[]).filter(u => u.stats.ml === 2).length >= 4, "desert umpires");
  assert.deepEqual(rosterProblems(w), []);
});

// --- two seasons on the shared day clock --------------------------------------------------------------

function run(seed: string, seasons: number) {
  const world = generateWorld(seed);
  // a few unexplained players in the Continental league to start things off
  const ml = Object.values(world.players).filter(p => world.teams[p.teamId]?.level === "ML");
  for (const p of ml.slice(0, 3)) p.powers = [{ kind: p.pos === "P" ? "FIREBALL" : "HYPER_HIT", level: 1 }];
  const rng = new Rng(seed);
  const state = newSeason(world, rng);
  const events: LifeEvent[] = [];
  const ends: { el: ReturnType<typeof standings>; ml: ReturnType<typeof standings> }[] = [];
  const exhibitions: ScheduledGame[] = [];
  let slateOk = true, ms = 0, n = 0;
  while (world.season <= seasons) {
    const day = state.day, phase = state.phase;
    const es = enhancedSlate(world, state, day);
    if (phase === "regular" && es.filter(g => g.level === "EL").length !== 3) slateOk = false;
    for (const g of slateFor(state, day)) {
      if (g.exhibition) exhibitions.push(g);
      const res = simulateGame(world, { ...g, modifiers: moodModifiers(world, [g.homeId, g.awayId], g) }, `${seed}-${g.id}`);
      recordResult(world, state, g, res);
    }
    if (phase === "regular" && day === REGULAR_DAYS) ends.push({ el: standings(world, state, "EL"), ml: standings(world, state, "ML") });
    const t0 = performance.now();
    events.push(...advanceSeasonDay(world, state, rng));
    if (phase === "regular") { ms += performance.now() - t0; n++; }
  }
  return { world, state, events, ends, exhibitions, slateOk, msPerDay: ms / n };
}
const R = run("enhanced-test", 2);

test("the circuit plays full seasons: 154 games each, three a day, standings add up", () => {
  assert.ok(R.slateOk, "three Enhanced games every regular-season day");
  for (const end of R.ends) {
    assert.equal(end.el.length, 6);
    for (const r of end.el) assert.equal(r.w + r.l, REGULAR_DAYS, `${r.teamId} played 154`);
    assert.equal(end.el.reduce((a, r) => a + r.w, 0), 3 * REGULAR_DAYS);
    // exhibitions don't leak into the Continental standings
    assert.equal(end.ml.reduce((a, r) => a + r.w, 0), 4 * REGULAR_DAYS);
  }
});

test("the Mirage Cup crowns a champion every season", () => {
  assert.equal(R.world.history.length, 2);
  for (let i = 0; i < 2; i++) {
    const h = R.world.history[i];
    assert.ok(h.enhanced?.champion && h.enhanced.runnerUp, "Enhanced champion and runner-up");
    const top4 = R.ends[i].el.slice(0, 4).map(r => r.teamId);
    assert.ok(top4.includes(h.enhanced!.champion!), "champion was a top-four seed");
    assert.match(h.enhanced!.finalScore!, /^4-[0-3]$/);
    assert.ok(h.champion, "and the Continental Series still happened");
  }
  const cups = R.events.filter(e => e.kind === "champion" && e.data?.circuit === "enhanced");
  assert.equal(cups.length, 2);
});

test("exhibitions happen, are flagged, and don't count", () => {
  assert.ok(R.exhibitions.length >= 4, `exhibitions (${R.exhibitions.length})`);
  for (const g of R.exhibitions) {
    const levels = [R.world.teams[g.homeId]?.level, R.world.teams[g.awayId]?.level].sort();
    assert.ok(levels.includes("EL") && (levels.includes("ML") || !R.world.teams[g.homeId] || !R.world.teams[g.awayId]), "Enhanced vs Continental");
    assert.equal(g.level, "ML", "bettable like a big-league game");
  }
  assert.ok(R.events.filter(e => e.kind === "exhibition").length >= 4);
  for (const e of R.events.filter(x => x.kind === "exhibition")) assert.ok(["enhanced", "continental"].includes(String(e.data?.circuitWinner)));
});

test("transfers: unexplained players get sent out (at sensible rates), some come back", () => {
  const to = R.events.filter(e => e.kind === "transfer" && e.data?.sub === "to_enhanced");
  const back = R.events.filter(e => e.kind === "transfer" && e.data?.sub === "return");
  assert.ok(to.length >= 1 && to.length <= 20, `to the desert: ${to.length} in 2 seasons`);
  assert.ok(back.length <= 15, `returns: ${back.length}`);
  for (const e of to) assert.equal(R.world.teams[String(e.data?.to)]?.level, "EL");
  assert.ok(R.events.some(e => e.kind === "drama" && e.data?.sub === "enhanced_watch"), "watch storylines");
  assert.deepEqual(rosterProblems(R.world), []);
});

test("forced transfer keeps both circuits' rosters whole", () => {
  const w = generateWorld("xfer");
  const p = w.players[w.teams.HCL.roster[0]];
  p.powers = [{ kind: "WARP_RUN", level: 2 }];
  assert.ok(unexplained(p));
  const ev: LifeEvent[] = [];
  const to = transferToEnhanced(w, new Rng("x"), p, ev, "powers");
  assert.ok(to && w.teams[to].level === "EL" && w.teams[to].roster.includes(p.id));
  assert.deepEqual(rosterProblems(w), []);
  assert.ok(ev.some(e => e.kind === "transfer" && e.data?.sub === "to_enhanced"));
});

test("still fast: the day machine stays under budget with the second circuit", () => {
  assert.ok(R.msPerDay < 6, `${R.msPerDay.toFixed(2)} ms/day`);
});

test("deterministic", () => {
  const a = run("enhanced-det", 1), b = run("enhanced-det", 1);
  assert.equal(JSON.stringify(a.world.history), JSON.stringify(b.world.history));
  assert.equal(a.events.length, b.events.length);
});

void ({} as SeasonState as unknown as World);
