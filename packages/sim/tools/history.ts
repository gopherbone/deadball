// Runs N seasons of the living league and prints a short history book: champions, award
// winners and leaders, dynasties, scandals, trades and world news.
// Usage: node packages/sim/tools/history.ts [seasons=10] [seed=history] [--stats]

import { generateWorld } from "../src/worldgen.ts";
import { Rng } from "../src/rng.ts";
import { newSeason } from "../src/league/index.ts";
import { playSeason } from "../src/league/driver.ts";
import { historyBook } from "../src/league/history.ts";

const args = process.argv.slice(2).filter(a => !a.startsWith("--"));
const seasons = Number(args[0] ?? 10);
const seed = args[1] ?? "history";
const showStats = process.argv.includes("--stats");

const t0 = Date.now();
const world = generateWorld(seed);
const rng = new Rng(`${seed}-league`);
const state = newSeason(world, rng);
const counts: Record<string, number> = {};
for (let s = 0; s < seasons; s++) {
  playSeason(world, state, rng, o => { for (const e of o.events) counts[e.kind] = (counts[e.kind] ?? 0) + 1; });
  if (showStats) {
    const live = Object.keys(world.players).length + Object.keys(world.npcs).length;
    console.error(`season ${s + 1}/${seasons}: ${((Date.now() - t0) / 1000).toFixed(1)}s, ${live} living, ${Object.keys(world.archive).length} archived`);
  }
}

for (const line of historyBook(world)) console.log(line);
console.log("");
console.log(`(${seasons} seasons, seed "${seed}", ${((Date.now() - t0) / 1000).toFixed(1)}s · ` +
  `${counts.birth ?? 0} births, ${counts.wedding ?? 0} weddings, ${counts.divorce ?? 0} divorces, ${counts.death ?? 0} deaths, ` +
  `${counts.trade ?? 0} trades, ${counts.draft ?? 0} draftees, ${counts.debut ?? 0} debuts)`);
