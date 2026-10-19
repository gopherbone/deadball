// Dumps the calibration league (packages/sim tools/calibrate.ts: generateWorld(`${seed}-${s}`))
// for the C harness: one line per major-league team (pdsim spec `team` JSON + park), and the
// major-league umpires. Read-only use of packages/sim.
//   node dump_world.ts <seasons> <seed> <outdir>
import { generateWorld } from "../../../packages/sim/src/worldgen.ts";
import type { Umpire } from "../../../packages/sim/src/types.ts";
import { writeFileSync, mkdirSync } from "node:fs";

const seasons = Number(process.argv[2] ?? 1);
const seed = process.argv[3] ?? "calib";
const out = process.argv[4] ?? ".";
mkdirSync(out, { recursive: true });
for (let s = 0; s < seasons; s++) {
  const world = generateWorld(`${seed}-${s}`);
  const lines: string[] = [];
  const allUmps = Object.values(world.npcs).filter(n => n.role === "umpire") as Umpire[];
  const mlUmps = allUmps.filter(u => u.stats.ml === 1);
  const umps = mlUmps.length ? mlUmps : allUmps;
  lines.push("UMPS " + umps.map(u => `${u.stats.zoneWidth},${u.stats.consistency}`).join(" "));
  for (const t of Object.values(world.teams).filter(x => x.level === "ML")) {
    const park = world.parks[t.parkId];
    lines.push(`PARK ${t.id} ${park.fences.join(" ")} ${park.walls.join(" ")} ${park.altitudeFt} ${park.foulTerritory} ${park.turf ? 1 : 0}`);
    const players = t.roster.map(id => world.players[id]).map(p => ({
      id: p.id, name: `${p.first} ${p.last}`, bats: p.bats, throws: p.throws, pos: p.pos,
      batting: p.batting, fielding: p.fielding, pitching: p.pitching, traits: p.traits, mood: p.mood,
      recentPitches: p.recentPitches,
    }));
    lines.push("TEAM " + JSON.stringify({ id: t.id, abbr: t.abbr, players }));
  }
  writeFileSync(`${out}/world-${s}.txt`, lines.join("\n") + "\n");
}
console.log(`dumped ${seasons} worlds to ${out}`);
