import { test } from "node:test";
import assert from "node:assert/strict";
import { generateWorld } from "../src/worldgen.ts";
import { resolveBip, buildFielder, type BipResult, type Runner } from "../src/fielding.ts";
import { buildLineup } from "../src/lineup.ts";
import { Rng } from "../src/rng.ts";

const world = generateWorld("fielding");
const team = world.teams["HCL"];
const lu = buildLineup(world, team);
const pitcher = Object.values(world.players).find(p => p.teamId === "HCL" && p.pos === "P")!;
const fielders = (["C", "1B", "2B", "3B", "SS", "LF", "CF", "RF"] as const).map(pos => buildFielder(pos, lu.defense[pos]!));
fielders.push(buildFielder("P", pitcher));
const park = world.parks[team.parkId];
const weather = { tempF: 72, windDir: 0, windMph: 0, rain: 0 };
const [batter, r1, r2, r3] = lu.order.slice(0, 4).map(x => x.player);

function onBase(mask: number): Runner[] {
  const out: Runner[] = [];
  if (mask & 1) out.push({ player: r1, base: 1 });
  if (mask & 2) out.push({ player: r2, base: 2 });
  if (mask & 4) out.push({ player: r3, base: 3 });
  return out;
}

/** Every runner (and the batter) gets exactly one move, and no two end on the same base. */
function checkMoves(res: BipResult, runners: Runner[], label: string) {
  if (res.kind === "FOUL") return;
  assert.equal(res.moves.filter(m => m.from === 0).length, 1, `${label}: batter has one move`);
  for (const run of runners) {
    assert.equal(res.moves.filter(m => m.from === run.base).length, 1, `${label}: runner on ${run.base} has one move`);
  }
  const ends = res.moves.map(m => m.to).filter(t => t >= 1 && t <= 3);
  assert.equal(new Set(ends).size, ends.length, `${label}: two runners on one base (${JSON.stringify(res.moves.map(m => [m.from, m.to]))})`);
}

test("caught foul pop leaves the runners where they were", () => {
  const rng = new Rng("foul-out");
  const runners = onBase(7);
  let found = 0;
  for (let i = 0; i < 20000 && found < 20; i++) {
    const spray = (rng.chance(0.5) ? 1 : -1) * (46 + rng.float() * 30);
    const res = resolveBip(60 + rng.float() * 30, 45 + rng.float() * 30, spray, { batter, runners, outs: 0, fielders, park, weather, rng });
    if (res.kind !== "FOUL_OUT") continue;
    found++;
    checkMoves(res, runners, "foul out");
    assert.deepEqual(res.moves.filter(m => m.from !== 0).map(m => [m.from, m.to]).sort(), [[1, 1], [2, 2], [3, 3]]);
    assert.equal(res.outs, 1);
  }
  assert.ok(found > 0, "found a caught foul pop");
});

test("grounder to the right side with men on 2nd and 3rd: never two runners on third", () => {
  const rng = new Rng("go-collide");
  const runners = onBase(6);
  let held = 0;
  for (let i = 0; i < 20000; i++) {
    const res = resolveBip(70 + rng.float() * 30, -5 + rng.float() * 10, rng.float() * 40, { batter, runners, outs: rng.chance(0.5) ? 0 : 1, fielders, park, weather, rng });
    checkMoves(res, runners, "grounder");
    if (res.kind === "OUT" && res.outType === "GO" && res.moves.some(m => m.from === 3 && m.to === 3)) {
      held++;
      assert.deepEqual(res.moves.find(m => m.from === 2)!.to, 2, "runner from second holds when third stays occupied");
    }
  }
  assert.ok(held > 0, "found a groundout where the runner on third held");
});

test("every batted ball accounts for every runner, all base states", () => {
  const rng = new Rng("bip-invariant");
  for (let mask = 0; mask < 8; mask++) {
    const runners = onBase(mask);
    for (let i = 0; i < 4000; i++) {
      const la = rng.normal(12, 25);
      const ev = 50 + rng.float() * 65;
      const spray = rng.normal(0, 30);
      const outs = Math.floor(rng.float() * 3);
      const res = resolveBip(ev, la, spray, { batter, runners, outs, fielders, park, weather, rng });
      checkMoves(res, runners, `mask ${mask}`);
    }
  }
});
