import { test } from "node:test";
import assert from "node:assert/strict";
import { generateWorld } from "../src/worldgen.ts";
import { Rng } from "../src/rng.ts";
import { simulateGame } from "../src/game.ts";
import type { Umpire, World } from "../src/types.ts";
import { LEVELS } from "../src/types.ts";
import {
  REGULAR_DAYS, advanceSeasonDay, dateFor, newSeason, recordResult, slateFor, standings, type SeasonState,
} from "../src/league/index.ts";
import { playDay } from "../src/league/driver.ts";
import { levelLine } from "../src/league/stats.ts";
import type { LifeEvent } from "../src/life/events.ts";

test("schedule: 154 games, one per team per day, balanced home/away, 4 games per level per day", () => {
  const world = generateWorld("sched");
  const state = newSeason(world, new Rng("sched"));
  for (const lv of LEVELS) {
    const games = state.schedule.filter(g => g.level === lv && !g.exhibition);
    assert.equal(games.length, REGULAR_DAYS * 4);
    const teams = Object.values(world.teams).filter(t => t.level === lv).map(t => t.id);
    for (const t of teams) {
      const mine = games.filter(g => g.homeId === t || g.awayId === t);
      assert.equal(mine.length, REGULAR_DAYS, `${t} plays 154`);
      assert.equal(mine.filter(g => g.homeId === t).length, REGULAR_DAYS / 2, `${t} 77 at home`);
      assert.equal(new Set(mine.map(g => g.day)).size, REGULAR_DAYS, `${t} once a day`);
      for (const o of teams) if (o !== t) assert.equal(mine.filter(g => g.homeId === o || g.awayId === o).length, 22, "22 vs each rival");
    }
    for (let d = 1; d <= REGULAR_DAYS; d++) {
      const slate = games.filter(g => g.day === d);
      assert.deepEqual(slate.map(g => g.slot).sort(), [0, 1, 2, 3]);
    }
  }
  assert.equal(slateFor(state, 1).filter(g => g.level === "ML").length, 4);
  // umpires exist; major-league games get the major-league staff
  for (const g of state.schedule) {
    const u = world.npcs[g.umpireId] as Umpire | undefined;
    assert.ok(u && u.role === "umpire", "umpire assigned");
    if (g.level === "ML") assert.equal(u.stats.ml, 1);
  }
  const ids = new Set(state.schedule.map(g => g.id));
  assert.equal(ids.size, state.schedule.length, "unique game ids");
});

test("calendar: real dates from early April, Mondays off, weather follows the months", () => {
  const world = generateWorld("cal");
  const state = newSeason(world, new Rng("cal"));
  const d1 = dateFor(world, state, 1);
  assert.equal(d1.year, 1996);
  assert.equal(d1.month, 4);
  assert.ok(d1.dom <= 7);
  assert.equal(d1.weekday, "Tue");
  assert.match(d1.label, /^Tue, April \d, 1996$/);
  for (let d = 1; d <= REGULAR_DAYS; d++) assert.notEqual(dateFor(world, state, d).weekday, "Mon");
  const last = dateFor(world, state, REGULAR_DAYS);
  assert.equal(last.month, 9);
  assert.equal(dateFor(world, state, REGULAR_DAYS + 10).month, 10, "playoffs in October");
  const avgTemp = (m: number) => {
    const gs = state.schedule.filter(g => dateFor(world, state, g.day).month === m);
    return gs.reduce((a, g) => a + g.weather.tempF, 0) / gs.length;
  };
  assert.ok(avgTemp(7) > avgTemp(4) + 12, `July (${avgTemp(7)}) hotter than April (${avgTemp(4)})`);
  for (const g of state.schedule) {
    assert.ok(g.weather.rain >= 0 && g.weather.rain <= 1);
    assert.ok(g.weather.windMph >= 0 && g.weather.windMph < 40);
  }
});

/** Two full seasons through the phase machine, with checks along the way. */
function run(seasons: number, seed: string) {
  const world = generateWorld(seed);
  const rng = new Rng(seed);
  const state = newSeason(world, rng);
  const phases: string[] = [];
  const events: LifeEvent[] = [];
  const ends: { state: SeasonState; world: World; ml: ReturnType<typeof standings>; levels: Record<string, ReturnType<typeof standings>> }[] = [];
  let lifeMs = 0, lifeDays = 0;
  const startSeason = state.season;
  while (state.season < startSeason + seasons) {
    const day = state.day, phase = state.phase;
    for (const g of slateFor(state, day)) {
      if (state.results[g.id]) continue;
      const res = simulateGame(world, { ...g, modifiers: [] }, `${seed}-${g.id}`);
      recordResult(world, state, g, res);
      recordResult(world, state, g, res); // idempotent
    }
    if (phase === "regular" && day === REGULAR_DAYS) {
      ends.push({ state: structuredClone(state), world, ml: standings(world, state, "ML"), levels: Object.fromEntries(LEVELS.map(l => [l, standings(world, state, l)])) });
    }
    const t0 = performance.now();
    events.push(...advanceSeasonDay(world, state, rng));
    if (phase === "regular") { lifeMs += performance.now() - t0; lifeDays++; }
    if (phases[phases.length - 1] !== state.phase) phases.push(state.phase);
  }
  return { world, state, phases, events, ends, lifeMs: lifeMs / lifeDays };
}

const R = run(2, "league-test");

test("phase machine: preseason → regular → playoffs → offseason → next season; years advance", () => {
  assert.deepEqual(R.phases.slice(0, 5), ["regular", "playoffs", "offseason", "preseason", "regular"]);
  assert.equal(R.world.season, 3);
  assert.equal(R.world.year, 1998);
  assert.equal(R.world.history.length, 2);
  assert.deepEqual(R.world.history.map(h => h.year), [1996, 1997]);
});

test("standings add up at the end of the regular season", () => {
  for (const end of R.ends) {
    for (const [lv, rows] of Object.entries(end.levels)) {
      const w = rows.reduce((a, r) => a + r.w, 0), l = rows.reduce((a, r) => a + r.l, 0);
      assert.equal(w, l, `${lv}: wins = losses`);
      assert.equal(w, REGULAR_DAYS * 4, `${lv}: one decision per game`);
      for (const r of rows) assert.equal(r.w + r.l, REGULAR_DAYS, `${r.teamId} played 154`);
      assert.equal(rows.reduce((a, r) => a + r.rs, 0), rows.reduce((a, r) => a + r.ra, 0), `${lv}: runs scored = allowed`);
      assert.equal(rows[0].gb, 0);
      for (let i = 1; i < rows.length; i++) assert.ok(rows[i].gb >= rows[i - 1].gb);
      for (const r of rows) {
        assert.match(r.streak, /^[WL]\d+$/);
        const [a, b] = r.last10.split("-").map(Number);
        assert.equal(a + b, 10);
      }
    }
    // season stats agree with the standings (regular season only)
    const season = end.state.season;
    let runs = 0;
    for (const byS of Object.values(R.world.stats)) runs += levelLine(byS[season], "ML")?.bat?.r ?? 0;
    assert.equal(runs, end.ml.reduce((a, r) => a + r.rs, 0), "batters' runs = team runs scored");
  }
});

test("playoffs: top four, best-of-5 semis, best-of-7 Continental Series, a champion", () => {
  for (let i = 0; i < R.world.history.length; i++) {
    const h = R.world.history[i];
    const end = R.ends[i];
    assert.ok(h.champion && h.runnerUp && h.champion !== h.runnerUp);
    const top4 = end.ml.slice(0, 4).map(r => r.teamId);
    assert.ok(top4.includes(h.champion!) && top4.includes(h.runnerUp!), "finalists were top-4 seeds");
    const [w, l] = h.finalScore!.split("-").map(Number);
    assert.equal(w, 4);
    assert.ok(l >= 0 && l <= 3);
    assert.ok(h.awards.mvp && h.awards.pitcher, "awards given");
  }
  const series = R.events.filter(e => e.kind === "playoffs" && e.data?.circuit === "continental" && (e.data?.what === "semifinal won" || e.data?.what === "Continental Series won"));
  assert.equal(series.length, 6, "2 semis + 1 final per season");
  for (const e of series.filter(x => x.data?.what === "semifinal won")) assert.match(String(e.data?.score), /^3-[012]$/);
  assert.equal(R.events.filter(e => e.kind === "champion" && e.data?.circuit === "continental").length, 2);
});

test("advanceSeasonDay is fast (< 5 ms per game day; 6 allowed under parallel test load)", () => {
  assert.ok(R.lifeMs < 6, `${R.lifeMs.toFixed(2)} ms/day`);
});

test("league events carry ids, days and data for the news desk", () => {
  const ids = new Set(R.events.map(e => e.id));
  assert.equal(ids.size, R.events.length, "unique event ids");
  for (const e of R.events) {
    assert.ok(Array.isArray(e.who));
    assert.equal(typeof e.day, "number");
  }
  for (const k of ["debut", "callup", "demotion", "injury", "retirement", "draft", "award", "world"]) {
    assert.ok(R.events.some(e => e.kind === k), `some ${k} events`);
  }
  for (const e of R.events.filter(x => x.kind === "world")) {
    assert.equal(typeof e.data?.sub, "string");
    assert.equal(typeof e.data?.title, "string");
    assert.equal(typeof e.data?.text, "string");
  }
});

test("playDay driver plays the slate and advances", () => {
  const world = generateWorld("drv");
  const rng = new Rng("drv");
  const state = newSeason(world, rng);
  playDay(world, state, rng); // preseason → day 1
  const o = playDay(world, state, rng, { keepResults: true });
  assert.equal(o.games.length, 19, "4 games at each of 4 Continental levels + 3 Enhanced");
  assert.equal(state.day, 2);
  assert.equal(Object.keys(state.results).length, 19 + 2, "plus the two opening-eve exhibitions");
});
