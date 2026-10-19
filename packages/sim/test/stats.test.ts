import { test } from "node:test";
import assert from "node:assert/strict";
import { compressSeason, levelLine } from "../src/league/stats.ts";
import type { World } from "../src/types.ts";

test("compressSeason: a postseason-only call-up keeps his minor-league line out of ML", () => {
  const bat = { g: 120, pa: 500, ab: 440, r: 90, h: 130, d: 25, t: 3, hr: 20, rbi: 95, bb: 45, k: 100, sb: 5, cs: 2, hbp: 10, sf: 5 };
  const post = { ...bat, g: 4, pa: 15, ab: 15, r: 3, h: 5 };
  // regular season at AA; the ML postseason game raised `level` to ML without touching byLevel
  const world = { stats: { p1: { 1: { teamId: "ML1", level: "ML", bat, byLevel: { AA: { bat } }, post: { bat: post } } } } } as unknown as World;
  compressSeason(world, 1);
  const s = world.stats.p1[1];
  assert.equal(s.byLevel, undefined);
  assert.equal(s.level, "AA");
  assert.equal(levelLine(s, "ML"), undefined);
  assert.equal(levelLine(s, "AA")?.bat?.r, 90);
});
