// npm run measure -w @deadball/server [days]
//
// CPU cost of the League DO's day tick, measured in Node (workerd freezes timers during
// CPU work, so it can't time itself). Runs the same pure pipeline the alarm runs
// (runDay: ops -> simulate every game -> record -> life -> news) plus the incremental
// world diff, over N days of a fresh world.

import { performance } from "node:perf_hooks";
import { generateWorld, Rng, sim, usingTemp } from "../src/sim.ts";
import { runDay } from "../src/day.ts";
import { explode } from "../src/store.ts";

const days = Number(process.argv[2] ?? 30);
const world = generateWorld("measure-1");
let state = sim.newSeason(world, new Rng("measure-1:season"));
const prev = new Map<string, string>();
const diff = (ns: string, obj: object) => {
  let rows = 0, bytes = 0;
  for (const [k, v] of explode(obj as Record<string, unknown>)) {
    const key = `${ns}|${k}`;
    if (prev.get(key) !== v) { rows++; bytes += v.length; prev.set(key, v); }
  }
  return { rows, bytes };
};
// the DO stores world.stats per season (src/stats.ts): only the current season is diffed
const diffWorld = () => {
  const { stats, ...rest } = world;
  const w = diff("world", rest);
  for (const [pid, by] of Object.entries(stats)) {
    const v = by[world.season];
    if (!v) continue;
    const key = `stats|${world.season}|${pid}`, j = JSON.stringify(v);
    if (prev.get(key) !== j) { w.rows++; w.bytes += j.length; prev.set(key, j); }
  }
  return w;
};
const t0 = performance.now();
const init = diffWorld();
diff("season", state);
console.log(`world: ${(JSON.stringify(world).length / 1e6).toFixed(2)} MB, initial rows ${init.rows} (diffed in ${(performance.now() - t0).toFixed(0)} ms); TEMP: ${usingTemp.join(", ") || "none"}`);

const sims: number[] = [], saves: number[] = [], rowsW: number[] = [], bytesW: number[] = [];
let games = 0, offDays = 0;
for (let d = 0; d < days; d++) {
  const a = performance.now();
  const r = runDay({ world, state, seed: "measure-1", orders: [], crew: {}, offDays, offseasonLength: 7 });
  offDays = r.offDays;
  if (r.newSeason) state = r.newSeason;
  const b = performance.now();
  // what the DO serialises to R2 for ML replays + D1 summaries
  for (const g of r.games) { if (g.game.level === "ML") JSON.stringify(g.res.log); JSON.stringify(g.summary); }
  const w = diffWorld(), s = diff("season", state);
  const c = performance.now();
  sims.push(b - a); saves.push(c - b); rowsW.push(w.rows + s.rows); bytesW.push(w.bytes + s.bytes);
  games += r.games.length;
}
const stat = (xs: number[]) => {
  const s = [...xs].sort((x, y) => x - y);
  return `avg ${(xs.reduce((p, q) => p + q, 0) / xs.length).toFixed(0)} / p95 ${s[Math.floor(s.length * 0.95)].toFixed(0)} / max ${s[s.length - 1].toFixed(0)}`;
};
console.log(`${days} days, ${games} games (${(games / days).toFixed(1)}/day), season ${state.season} day ${state.day} phase ${state.phase}`);
console.log(`sim+record+life+news ms: ${stat(sims)}`);
console.log(`serialise+diff ms:        ${stat(saves)}`);
console.log(`rows written per day:     ${stat(rowsW)} (bytes ${stat(bytesW)})`);
console.log(`world now ${(JSON.stringify(world).length / 1e6).toFixed(2)} MB`);
