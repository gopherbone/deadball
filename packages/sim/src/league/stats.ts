// Season and career statistics: world.stats[personId][season] = { bat, pitch, ... }.

import type { GameResult, TeamBox } from "../game.ts";
import type { BatTotals, Level, PitchTotals, SeasonStats, StatLine, World } from "../types.ts";
import { LEVELS } from "../types.ts";

export function emptyBat(): BatTotals {
  return { g: 0, pa: 0, ab: 0, r: 0, h: 0, d: 0, t: 0, hr: 0, rbi: 0, bb: 0, k: 0, sb: 0, cs: 0, hbp: 0, sf: 0 };
}
export function emptyPitch(): PitchTotals {
  return { g: 0, gs: 0, w: 0, l: 0, sv: 0, outs: 0, h: 0, r: 0, er: 0, bb: 0, k: 0, hr: 0, hbp: 0, bf: 0, pitches: 0 };
}

function addInto<T extends object>(into: T, from: T) {
  const a = into as Record<string, number>, b = from as Record<string, number>;
  for (const k in b) a[k] = (a[k] ?? 0) + b[k];
}

const rank = (lv: Level) => (lv === "EL" ? 0.5 : LEVELS.indexOf(lv)); // 0 = ML (highest); the Enhanced League sits just below

function seasonEntry(world: World, id: string, season: number, teamId: string, level: Level): SeasonStats {
  const byId = world.stats[id] ?? (world.stats[id] = {});
  let s = byId[season];
  if (!s) s = byId[season] = { teamId, level, byLevel: {} };
  s.teamId = teamId;
  if (rank(level) < rank(s.level)) s.level = level;
  return s;
}

/** Fold one game's box score into season stats (postseason games go to `post`). */
export function addGameStats(world: World, season: number, level: Level, res: GameResult, post = false) {
  for (const box of [res.home, res.away] as TeamBox[]) {
    const seen = new Set<string>();
    for (const l of box.bat) {
      if (seen.has(l.id)) continue;
      seen.add(l.id);
      const b: BatTotals = {
        g: 1, pa: l.ab + l.bb + l.hbp + l.sf, ab: l.ab, r: l.r, h: l.h, d: l.d, t: l.t, hr: l.hr, rbi: l.rbi,
        bb: l.bb, k: l.k, sb: l.sb, cs: l.cs, hbp: l.hbp, sf: l.sf,
      };
      addLine(world, l.id, season, box.teamId, level, b, undefined, post);
    }
    box.pitch.forEach((l, i) => {
      const p: PitchTotals = {
        g: 1, gs: i === 0 ? 1 : 0, w: res.decisions.w === l.id ? 1 : 0, l: res.decisions.l === l.id ? 1 : 0,
        sv: res.decisions.s === l.id ? 1 : 0, outs: l.outs, h: l.h, r: l.r, er: l.er, bb: l.bb, k: l.k, hr: l.hr,
        hbp: l.hbp, bf: l.bf, pitches: l.pitches,
      };
      addLine(world, l.id, season, box.teamId, level, undefined, p, post);
    });
  }
}

function addLine(world: World, id: string, season: number, teamId: string, level: Level, bat?: BatTotals, pitch?: PitchTotals, post = false) {
  const s = seasonEntry(world, id, season, teamId, level);
  if (post) {
    const ps = (s.post ??= {});
    if (bat) addInto(ps.bat ??= emptyBat(), bat);
    if (pitch) addInto(ps.pitch ??= emptyPitch(), pitch);
    return;
  }
  const lv = (s.byLevel ??= {})[level] ?? (s.byLevel[level] = {});
  if (bat) {
    addInto(s.bat ??= emptyBat(), bat);
    addInto(lv.bat ??= emptyBat(), bat);
  }
  if (pitch) {
    addInto(s.pitch ??= emptyPitch(), pitch);
    addInto(lv.pitch ??= emptyPitch(), pitch);
  }
}

/** After the season: drop the per-level split for players who only played at one level. */
export function compressSeason(world: World, season: number) {
  for (const byId of Object.values(world.stats)) {
    const s = byId[season];
    if (!s?.byLevel) continue;
    const levels = Object.keys(s.byLevel) as Level[];
    if (levels.length > 1) continue;
    // the one level they played regular-season games at (a postseason-only call-up can have
    // raised s.level above it, which would misfile the whole line once byLevel is gone)
    if (levels.length === 1) s.level = levels[0];
    delete s.byLevel;
  }
}

/** One player's line at one level in a season (handles compressed entries). */
export function levelLine(s: SeasonStats | undefined, level: Level): StatLine | undefined {
  if (!s) return undefined;
  if (s.byLevel) return s.byLevel[level];
  return s.level === level ? s : undefined;
}

export interface CareerTotals {
  seasons: number;
  bat: BatTotals;
  pitch: PitchTotals;
}

/** Career totals, optionally restricted to one level (e.g. "ML"). */
export function careerTotals(world: World, id: string, level?: Level): CareerTotals {
  const out: CareerTotals = { seasons: 0, bat: emptyBat(), pitch: emptyPitch() };
  for (const s of Object.values(world.stats[id] ?? {})) {
    const line = level ? levelLine(s, level) : s;
    if (!line) continue;
    out.seasons++;
    if (line.bat) addInto(out.bat, line.bat);
    if (line.pitch) addInto(out.pitch, line.pitch);
  }
  return out;
}

// --- rate stats ------------------------------------------------------------------------------

export const avg = (b: BatTotals) => (b.ab ? b.h / b.ab : 0);
export const obp = (b: BatTotals) => { const d = b.ab + b.bb + b.hbp + b.sf; return d ? (b.h + b.bb + b.hbp) / d : 0; };
export const slg = (b: BatTotals) => (b.ab ? (b.h + b.d + 2 * b.t + 3 * b.hr) / b.ab : 0);
export const ops = (b: BatTotals) => obp(b) + slg(b);
export const era = (p: PitchTotals) => (p.outs ? (p.er * 27) / p.outs : 0);
export const whip = (p: PitchTotals) => (p.outs ? ((p.bb + p.h) * 3) / p.outs : 0);
/** "182.1" style innings pitched. */
export const ipString = (p: PitchTotals) => `${Math.floor(p.outs / 3)}.${p.outs % 3}`;
/** ".312" style. */
export const rate3 = (x: number) => (x >= 1 ? x.toFixed(3) : x.toFixed(3).replace(/^0/, ""));

/** Rough runs-above-average value for awards (hitters). */
export function batValue(b: BatTotals): number {
  // linear weights-ish runs created minus league-average runs per PA
  const singles = b.h - b.d - b.t - b.hr;
  const runs = 0.7 * (b.bb + b.hbp) + 0.9 * singles + 1.25 * b.d + 1.6 * b.t + 2.0 * b.hr + 0.2 * b.sb - 0.4 * b.cs - 0.27 * (b.ab - b.h);
  return runs;
}

/** Rough runs-saved value for awards (pitchers). */
export function pitchValue(p: PitchTotals): number {
  return ((4.5 - era(p)) * p.outs) / 27 + p.k * 0.05 + p.sv * 0.4;
}

export type LeaderKey = "avg" | "hr" | "rbi" | "sb" | "ops" | "w" | "k" | "era" | "sv";

/** League leaders for a season at one level. Rate stats need ~3.1 PA or 1 IP per team game. */
export function leaders(world: World, season: number, level: Level, key: LeaderKey, n = 5, teamGames = 154): [string, number][] {
  const out: [string, number][] = [];
  for (const [id, byS] of Object.entries(world.stats)) {
    const line = levelLine(byS[season], level);
    if (!line) continue;
    const b = line.bat, p = line.pitch;
    let v: number | undefined;
    switch (key) {
      case "avg": if (b && b.pa >= teamGames * 3.1) v = avg(b); break;
      case "ops": if (b && b.pa >= teamGames * 3.1) v = ops(b); break;
      case "hr": v = b?.hr; break;
      case "rbi": v = b?.rbi; break;
      case "sb": v = b?.sb; break;
      case "w": v = p?.w; break;
      case "k": v = p?.k; break;
      case "sv": v = p?.sv; break;
      case "era": if (p && p.outs >= teamGames * 3) v = era(p); break;
    }
    if (v !== undefined && (v > 0 || key === "era")) out.push([id, v]);
  }
  out.sort((a, b) => (key === "era" ? a[1] - b[1] : b[1] - a[1]));
  return out.slice(0, n);
}
