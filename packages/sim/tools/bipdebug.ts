// Tabulates batted-ball outcomes by launch-angle bucket against a league-average defense.
import { generateWorld } from "../src/worldgen.ts";
import { resolveBip, buildFielder } from "../src/fielding.ts";
import { Rng } from "../src/rng.ts";
import { T } from "../src/tuning.ts";
import { buildLineup } from "../src/lineup.ts";

const world = generateWorld("dbg");
const team = world.teams["HCL"];
const lu = buildLineup(world, team);
const pitcher = Object.values(world.players).find(p => p.teamId === "HCL" && p.pos === "P")!;
const fielders = (["C", "1B", "2B", "3B", "SS", "LF", "CF", "RF"] as const).map(pos => buildFielder(pos, lu.defense[pos]!));
fielders.push(buildFielder("P", pitcher));
const park = world.parks[team.parkId];
const rng = new Rng("x");
const batter = lu.order[0].player;
const buckets: Record<string, Record<string, number>> = {};
for (let i = 0; i < 40000; i++) {
  const la = rng.normal(T.laMean, T.laSd);
  const z = rng.normal(0, 1);
  const ev = Math.max(25, T.evMean - Math.min(T.laPenaltyCap, T.laPenalty * (la - 15) ** 2) + T.evSd * (z > 0 ? z * T.evUpper : z * T.evLower));
  const sp = rng.normal(0, T.spraySd);
  const res = resolveBip(ev, la, sp, { batter, runners: [], outs: 0, fielders, park, weather: { tempF: 72, windDir: 0, windMph: 0, rain: 0 }, rng });
  const b = la < 10 ? "GB <10" : la < 25 ? "LD 10-25" : la < 50 ? "FB 25-50" : "PU 50+";
  buckets[b] ??= {};
  const key = res.kind + (res.fielder ? ":" + res.fielder : "");
  buckets[b][res.kind] = (buckets[b][res.kind] ?? 0) + 1;
  buckets[b]["_" + key] = (buckets[b]["_" + key] ?? 0) + 1;
}
for (const [b, m] of Object.entries(buckets)) {
  const n = Object.entries(m).filter(([k]) => !k.startsWith("_")).reduce((a, [, v]) => a + v, 0);
  console.log(b, n, Object.entries(m).filter(([k]) => !k.startsWith("_")).map(([k, v]) => `${k} ${(v / n * 100).toFixed(1)}%`).join("  "));
  console.log("   ", Object.entries(m).filter(([k]) => k.startsWith("_")).sort((a, b) => b[1] - a[1]).slice(0, 8).map(([k, v]) => `${k.slice(1)} ${(v / n * 100).toFixed(1)}%`).join("  "));
}
