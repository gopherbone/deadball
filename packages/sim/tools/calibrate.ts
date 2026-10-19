// Plays full major-league seasons and compares league rates to MLB-like targets.
// Usage: node tools/calibrate.ts [seasons=1] [seed=calib]

import { generateWorld } from "../src/worldgen.ts";
import { simulateGame } from "../src/game.ts";
import { applyGameToWorld, advanceDay } from "../src/season.ts";
import { Rng } from "../src/rng.ts";
import type { Umpire } from "../src/types.ts";

const seasons = Number(process.argv[2] ?? 1);
const seed = process.argv[3] ?? "calib";

const TARGETS: Record<string, [number, number]> = {
  // stat: [target, tolerance]
  "R/G (per team)": [4.5, 0.25],
  AVG: [0.245, 0.008],
  OBP: [0.315, 0.008],
  SLG: [0.405, 0.015],
  "K%": [0.225, 0.012],
  "BB%": [0.083, 0.006],
  "HBP%": [0.011, 0.003],
  "HR/PA": [0.03, 0.003],
  BABIP: [0.29, 0.008],
  "2B/PA": [0.044, 0.005],
  "3B/PA": [0.004, 0.0015],
  "SB/G": [0.65, 0.2],
  "E/G": [0.55, 0.15],
  "DP/G": [0.8, 0.15],
  "P/PA": [3.9, 0.12],
  "SP IP/GS": [5.5, 0.4],
};

const pc = { n: 0, zone: 0, swing: 0, zswing: 0, oswing: 0, contact: 0, zcontact: 0, ocontact: 0, called: 0, foul: 0 };
const t = { pa: 0, ab: 0, h: 0, d: 0, tr: 0, hr: 0, bb: 0, k: 0, hbp: 0, sf: 0, r: 0, sb: 0, e: 0, dp: 0, pitches: 0, games: 0, spOuts: 0, inc: 0 };
const incidents: Record<string, number> = {};
const start = Date.now();

for (let s = 0; s < seasons; s++) {
  const world = generateWorld(`${seed}-${s}`);
  const rng = new Rng(`${seed}-sched-${s}`);
  const ml = Object.values(world.teams).filter(x => x.level === "ML").map(x => x.id);
  // major-league games get the major-league umpiring staff (worldgen also makes minor-league umps)
  const allUmps = Object.values(world.npcs).filter(n => n.role === "umpire") as Umpire[];
  const mlUmps = allUmps.filter(u => u.stats.ml === 1);
  const umps = mlUmps.length ? mlUmps : allUmps;
  for (let day = 0; day < 162; day++) {
    advanceDay(world);
    const order = rng.shuffle([...ml]);
    for (let g = 0; g < order.length; g += 2) {
      const res = simulateGame(world, {
        id: `s${s}d${day}g${g}`, day, homeId: order[g], awayId: order[g + 1], umpireId: rng.pick(umps).id,
        weather: { tempF: 50 + rng.int(45), windDir: rng.range(-180, 180), windMph: rng.int(15), rain: rng.float() * 0.3 },
        modifiers: [],
      }, `${seed}-${s}-${day}-${g}`);
      applyGameToWorld(world, res);
      t.games++;
      for (const box of [res.home, res.away]) {
        for (const l of box.bat) {
          t.ab += l.ab; t.h += l.h; t.d += l.d; t.tr += l.t; t.hr += l.hr; t.bb += l.bb; t.k += l.k; t.hbp += l.hbp; t.sf += l.sf; t.sb += l.sb;
          t.pa += l.ab + l.bb + l.hbp + l.sf;
        }
        t.r += box.runs;
        t.e += box.errors;
        for (const p of box.pitch) t.pitches += p.pitches;
        t.spOuts += box.pitch[0].outs;
      }
      for (const ev of res.log) {
        if (ev.k === "bip" && ev.res === "DP") t.dp++;
        if (ev.k !== "p" || ev.r === "H") continue;
        const inZ = ev.z <= 1, sw = ev.r === "S" || ev.r === "F" || ev.r === "X", con = ev.r === "F" || ev.r === "X";
        pc.n++; if (inZ) pc.zone++;
        if (sw) { pc.swing++; if (inZ) pc.zswing++; else pc.oswing++; }
        if (con) { pc.contact++; if (inZ) pc.zcontact++; else pc.ocontact++; }
        if (ev.r === "C") pc.called++;
        if (ev.r === "F") pc.foul++;
      }
      for (const i of res.incidents) incidents[i.kind] = (incidents[i.kind] ?? 0) + 1;
    }
  }
}

const teamGames = t.games * 2;
const obpDen = t.ab + t.bb + t.hbp + t.sf;
const tb = t.h + t.d + 2 * t.tr + 3 * t.hr;
const stats: Record<string, number> = {
  "R/G (per team)": t.r / teamGames,
  AVG: t.h / t.ab,
  OBP: (t.h + t.bb + t.hbp) / obpDen,
  SLG: tb / t.ab,
  "K%": t.k / t.pa,
  "BB%": t.bb / t.pa,
  "HBP%": t.hbp / t.pa,
  "HR/PA": t.hr / t.pa,
  BABIP: (t.h - t.hr) / (t.ab - t.k - t.hr + t.sf),
  "2B/PA": t.d / t.pa,
  "3B/PA": t.tr / t.pa,
  "SB/G": t.sb / t.games,
  "E/G": t.e / t.games,
  "DP/G": t.dp / t.games,
  "P/PA": t.pitches / t.pa,
  "SP IP/GS": t.spOuts / 3 / teamGames,
};

console.log(`${t.games} games in ${((Date.now() - start) / 1000).toFixed(1)}s\n`);
let bad = 0;
for (const [k, v] of Object.entries(stats)) {
  const [target, tol] = TARGETS[k];
  const ok = Math.abs(v - target) <= tol;
  if (!ok) bad++;
  const fmt = (x: number) => (x < 1 ? x.toFixed(3) : x.toFixed(2));
  console.log(`${ok ? "  " : "!!"} ${k.padEnd(16)} ${fmt(v).padStart(7)}   target ${fmt(target)} ±${fmt(tol)}`);
}
const pitchStats: [string, number, number][] = [
  ["Zone%", pc.zone / pc.n, 0.49], ["Swing%", pc.swing / pc.n, 0.47], ["Z-Swing%", pc.zswing / pc.zone, 0.67],
  ["O-Swing%", pc.oswing / (pc.n - pc.zone), 0.3], ["Contact%", pc.contact / pc.swing, 0.76],
  ["Z-Contact%", pc.zcontact / pc.zswing, 0.85], ["O-Contact%", pc.ocontact / pc.oswing, 0.59],
  ["CalledStr%", pc.called / pc.n, 0.165], ["Foul%", pc.foul / pc.n, 0.18],
];
console.log("\npitch level (MLB reference)");
for (const [k, v, ref] of pitchStats) console.log(`   ${k.padEnd(16)} ${v.toFixed(3).padStart(7)}   ref ${ref.toFixed(3)}`);
console.log(`\nincidents/season:`, Object.fromEntries(Object.entries(incidents).map(([k, v]) => [k, +(v / seasons).toFixed(1)])));
console.log(bad ? `\n${bad} stats out of range` : "\nall stats in range");
