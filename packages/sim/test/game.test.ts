import { test } from "node:test";
import assert from "node:assert/strict";
import { generateWorld } from "../src/worldgen.ts";
import { simulateGame, type GameSpec } from "../src/game.ts";
import type { World } from "../src/types.ts";

function spec(world: World, extra: Partial<GameSpec> = {}): GameSpec {
  const ump = Object.values(world.npcs).find(n => n.role === "umpire")!;
  return {
    id: "g1", day: 1, homeId: "HCL", awayId: "STA", umpireId: ump.id,
    weather: { tempF: 72, windDir: 0, windMph: 5, rain: 0 }, modifiers: [], ...extra,
  };
}

test("same seed, same game", () => {
  const a = simulateGame(generateWorld("w"), spec(generateWorld("w")), "seed");
  const b = simulateGame(generateWorld("w"), spec(generateWorld("w")), "seed");
  assert.deepEqual(a.log, b.log);
  assert.equal(a.home.runs, b.home.runs);
});

test("different seeds diverge", () => {
  const w = generateWorld("w");
  const a = simulateGame(w, spec(w), "one");
  const b = simulateGame(w, spec(w), "two");
  assert.notDeepEqual(a.log, b.log);
});

test("box scores add up", () => {
  const w = generateWorld("w");
  for (let i = 0; i < 50; i++) {
    const res = simulateGame(w, spec(w), `box-${i}`);
    for (const box of [res.home, res.away]) {
      const lineRuns = box.line.filter(x => !Number.isNaN(x)).reduce((a, b) => a + b, 0);
      assert.equal(lineRuns, box.runs, "line score sums to runs");
      assert.equal(box.bat.reduce((a, l) => a + l.r, 0), box.runs, "batters' runs sum to team runs");
      assert.equal(box.bat.reduce((a, l) => a + l.h, 0), box.hits, "batters' hits sum to team hits");
    }
    // the defense records 3 outs per completed half inning
    const awayOuts = res.home.pitch.reduce((a, p) => a + p.outs, 0);
    assert.equal(awayOuts, res.innings * 3, "away team made 3 outs every inning");
    assert.notEqual(res.home.runs, res.away.runs, "no ties");
    const ends = res.log.filter(e => e.k === "end");
    assert.equal(ends.length, 1);
  }
});

test("a paid-off umpire squeezes the other side", () => {
  // favour the home team's pitchers heavily and compare strikeouts over many games
  let kFavoured = 0, kBase = 0;
  for (let i = 0; i < 60; i++) {
    const w = generateWorld("ump");
    const base = simulateGame(w, spec(w), `u-${i}`);
    const fixed = simulateGame(generateWorld("ump"), spec(w, {
      modifiers: [{ id: "bribe", source: "op1", target: { kind: "team", id: "HCL" }, effect: "zone", value: 0.15 }],
    }), `u-${i}`);
    kBase += base.home.pitch.reduce((a, p) => a + p.k, 0);
    kFavoured += fixed.home.pitch.reduce((a, p) => a + p.k, 0);
  }
  assert.ok(kFavoured > kBase * 1.05, `bribed zone should add strikeouts (${kBase} -> ${kFavoured})`);
});

test("sabotage raises incident odds", () => {
  let fired = 0;
  for (let i = 0; i < 40; i++) {
    const w = generateWorld("rac");
    const res = simulateGame(w, spec(w, {
      modifiers: [{ id: "op", source: "crew-op-7", target: { kind: "team", id: "STA" }, effect: "incident", incident: "RACCOONS_BULLPEN", value: 800 }],
    }), `r-${i}`);
    const inc = res.incidents.find(x => x.kind === "RACCOONS_BULLPEN");
    if (inc) {
      fired++;
      assert.equal(inc.team, "STA");
      assert.deepEqual(inc.sources, ["crew-op-7"]);
    }
  }
  assert.ok(fired >= 14, `raccoons should be likely when paid for (fired ${fired}/40)`);
});
