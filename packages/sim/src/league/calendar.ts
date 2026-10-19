// The league calendar: real dates for game days, the regular-season schedule, umpire crews and
// weather per park and date.

import type { Rng } from "../rng.ts";
import type { Level, Park, Team, Umpire, Weather, World } from "../types.ts";

export const REGULAR_DAYS = 154;
export const OFFSEASON_DAYS = 12;

const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

export interface GameDate {
  year: number;
  /** 1–12 */
  month: number;
  dom: number;
  weekday: string;
  /** "Tue, June 13, 1996" */
  label: string;
  /** "1996-06-13" */
  iso: string;
}

const DAY_MS = 86400000;

/** Opening day: the first Tuesday on or after April 1 (Mondays are off days). */
function openingDay(year: number): number {
  const apr1 = Date.UTC(year, 3, 1);
  const dow = new Date(apr1).getUTCDay();
  return apr1 + ((2 - dow + 7) % 7) * DAY_MS;
}

function regularOffset(day: number): number {
  const d = Math.max(1, day) - 1;
  return Math.floor(d / 6) * 7 + (d % 6);
}

/**
 * Calendar date for a season day. Day 0 is the eve of opening day, 1..154 the regular season
 * (six games a week, Mondays off), then playoffs on consecutive days, then the hot-stove days
 * spread across the winter (pass `offseasonStart`, the first offseason day number).
 */
export function seasonDate(year: number, day: number, offseasonStart?: number): GameDate {
  const open = openingDay(year);
  let t: number;
  if (day <= 0) t = open - DAY_MS;
  else if (offseasonStart !== undefined && day >= offseasonStart) {
    const k = day - offseasonStart; // 0..OFFSEASON_DAYS-1, Nov 1 → mid March
    t = Date.UTC(year, 10, 1) + Math.round(k * (135 / OFFSEASON_DAYS)) * DAY_MS;
  } else if (day <= REGULAR_DAYS) t = open + regularOffset(day) * DAY_MS;
  else t = open + (regularOffset(REGULAR_DAYS) + 2 + (day - REGULAR_DAYS - 1)) * DAY_MS;
  const dt = new Date(t);
  const y = dt.getUTCFullYear(), m = dt.getUTCMonth(), dom = dt.getUTCDate();
  return {
    year: y, month: m + 1, dom, weekday: WEEKDAYS[dt.getUTCDay()],
    label: `${WEEKDAYS[dt.getUTCDay()]}, ${MONTHS[m]} ${dom}, ${y}`,
    iso: `${y}-${String(m + 1).padStart(2, "0")}-${String(dom).padStart(2, "0")}`,
  };
}

// --- weather ---------------------------------------------------------------------------------

const MONTH_TEMP: Record<number, number> = { 1: 32, 2: 36, 3: 48, 4: 57, 5: 66, 6: 75, 7: 80, 8: 78, 9: 70, 10: 59, 11: 47, 12: 36 };
const MONTH_RAIN: Record<number, number> = { 3: 0.22, 4: 0.22, 5: 0.2, 6: 0.16, 7: 0.13, 8: 0.13, 9: 0.15, 10: 0.17 };

function hash(s: string): number {
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) h = Math.imul(h ^ s.charCodeAt(i), 16777619);
  return (h >>> 0) / 4294967296;
}

/** Per-park climate: a fixed temperature offset, prevailing wind and how windy it is. */
export function parkClimate(park: Park): { temp: number; windDir: number; windy: number } {
  const h = hash(park.id);
  const coastal = /wharf|harbor|bellwood/i.test(park.name) ? 1 : 0;
  return {
    temp: Math.round((h - 0.5) * 8 - park.altitudeFt / 1000 * 1.5),
    windDir: Math.round(hash(park.id + "w") * 360 - 180),
    windy: coastal * 4 + (park.altitudeFt > 3000 ? 2 : 0) + Math.round(h * 3),
  };
}

export function makeWeather(park: Park, date: GameDate, slot: number, rng: Rng): Weather {
  const c = parkClimate(park);
  const night = slot >= 2 ? -4 : 0;
  const tempF = Math.round(MONTH_TEMP[date.month] + c.temp + night + rng.normal(0, 6));
  const windMph = Math.max(0, Math.round(Math.abs(rng.normal(4.5 + c.windy * 0.8, 3.5))));
  const windDir = Math.round(((c.windDir + rng.normal(0, 60) + 540) % 360) - 180);
  const base = MONTH_RAIN[date.month] ?? 0.15;
  const rain = Math.round(Math.min(1, rng.chance(base * 1.6) ? rng.range(0.2, 0.9) : rng.range(0, 0.15)) * 100) / 100;
  return { tempF, windDir, windMph, rain };
}

// --- schedule ----------------------------------------------------------------------------------

export interface Pairing { day: number; homeId: string; awayId: string }

/**
 * Balanced 154-game schedule for an 8-team league: each pair meets 22 times (11 at each park),
 * in series — six 3-game sets and one 4-game set split 2/2. One game per team per day.
 */
export function roundRobin(teamIds: string[], rng: Rng): Pairing[] {
  const ids = rng.shuffle([...teamIds]);
  const n = ids.length; // 8
  const rounds: [string, string][][] = [];
  const rot = ids.slice(1);
  for (let r = 0; r < n - 1; r++) {
    const left = [ids[0], ...rot.slice(0, n / 2 - 1)];
    const right = rot.slice(n / 2 - 1).reverse();
    const round: [string, string][] = [];
    for (let i = 0; i < n / 2; i++) round.push(r % 2 === 0 ? [left[i], right[i]] : [right[i], left[i]]);
    rounds.push(round);
    rot.unshift(rot.pop()!);
  }
  const out: Pairing[] = [];
  let day = 1;
  for (let cycle = 0; cycle < 7; cycle++) {
    const len = cycle < 6 ? 3 : 4;
    const order = rng.shuffle(rounds.map((_, i) => i));
    for (const ri of order) {
      for (let g = 0; g < len; g++) {
        for (const [a, b] of rounds[ri]) {
          const aHome = len === 4 ? g < 2 : cycle % 2 === 0;
          out.push({ day: day + g, homeId: aHome ? a : b, awayId: aHome ? b : a });
        }
      }
      day += len;
    }
  }
  return out;
}

/** Umpires for a level: the major-league staff for ML games, the minor-league pool otherwise. */
export function umpirePool(world: World, level: Level): Umpire[] {
  const all = Object.values(world.npcs).filter(n => n.role === "umpire" && n.active) as Umpire[];
  const ml = all.filter(u => u.stats.ml === 1);
  const minor = all.filter(u => !u.stats.ml);
  const desert = all.filter(u => u.stats.ml === 2);
  const pool = level === "ML" ? ml : level === "EL" ? (desert.length >= 3 ? desert : minor) : minor;
  return (pool.length >= 4 ? pool : all).sort((a, b) => (a.id < b.id ? -1 : 1));
}

export function levelTeams(world: World, level: Level): Team[] {
  return Object.values(world.teams).filter(t => t.level === level).sort((a, b) => (a.id < b.id ? -1 : 1));
}
