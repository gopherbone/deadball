// Staggered first pitches: when each game of a day goes on the air. Pure (no Cloudflare APIs), so
// the League DO, the routes, the scripts and the tests all agree on the same timetable.
//
// A game day is `dayMs` long. The aired games (major league and Enhanced League, exhibitions
// included) pitch one after another from `preMs` into the day to its end, ML and EL rotated:
//
//   dayStart ──preMs── g0 ──s── g1 ──s── g2 ... g(n-1) ──s── next dayStart ──preMs── next g0
//                                      s = (dayMs - preMs) / n
//
// Each game airs for `airMs` (stretched on a one-game day so the broadcast reaches the next
// day's first pitch), so with any two or more games a day something is always on the air.
// Farm games aren't aired: they share the day's first pitch. The day closes (life, phases,
// tomorrow's playoff games) right after the last aired game is simulated, so tomorrow's games
// are on the board for at least `preMs + s` before their first pitch.

import type { ScheduledGame } from "./sim.ts";

export interface DayTiming { dayMs: number; preMs: number; airMs: number }
export interface Pitch { at: number; air: number }

/** Games that get a broadcast (replay log, live score) and a betting pool. */
export const aired = (g: Pick<ScheduledGame, "level">) => g.level === "ML" || g.level === "EL";

/**
 * The aired games of a slate in first-pitch order: each circuit keeps its own slot order and the
 * circuits interleave evenly (8 ML + 3 EL -> M M E M M M E M M E M ... roughly).
 */
export function airOrder(slate: ScheduledGame[]): ScheduledGame[] {
  const groups = new Map<string, ScheduledGame[]>();
  for (const g of slate) if (aired(g)) (groups.get(g.level) ?? groups.set(g.level, []).get(g.level)!).push(g);
  const keyed: { g: ScheduledGame; k: number }[] = [];
  for (const list of groups.values()) {
    list.sort((a, b) => (a.slot ?? 0) - (b.slot ?? 0) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
    list.forEach((g, i) => keyed.push({ g, k: (i + 0.5) / list.length }));
  }
  keyed.sort((a, b) => a.k - b.k || (a.g.level === b.g.level ? 0 : a.g.level === "ML" ? -1 : 1) || (a.g.id < b.g.id ? -1 : 1));
  return keyed.map(x => x.g);
}

/** Simulation order for a day: farm games first (slate order), then the aired games in pitch order. */
export function simOrder(slate: ScheduledGame[]): ScheduledGame[] {
  return [...slate.filter(g => !aired(g)), ...airOrder(slate)];
}

/** Gap between first pitches on a day with `n` aired games. */
export const spacing = (n: number, t: DayTiming) => (n > 0 ? (t.dayMs - t.preMs) / n : t.dayMs - t.preMs);

/** Broadcast length on a day with `n` aired games: AIR_MS, or long enough to reach tomorrow's first pitch. */
export const airFor = (n: number, t: DayTiming) => Math.max(t.airMs, Math.ceil(spacing(n, t) + t.preMs));

/**
 * First pitch and air time of every game on a slate starting at `dayStart`, plus `closeAt`: when
 * the day closes (the last aired first pitch; the first-pitch slot when nothing airs).
 */
export function dayTimes(slate: ScheduledGame[], dayStart: number, t: DayTiming): { pitches: Map<string, Pitch>; closeAt: number; order: ScheduledGame[] } {
  const order = airOrder(slate);
  const s = spacing(order.length, t), air = airFor(order.length, t);
  const first = dayStart + t.preMs;
  const pitches = new Map<string, Pitch>();
  order.forEach((g, k) => pitches.set(g.id, { at: first + Math.round(k * s), air }));
  for (const g of slate) if (!pitches.has(g.id)) pitches.set(g.id, { at: first, air: t.airMs });
  const closeAt = order.length ? pitches.get(order[order.length - 1].id)!.at : first;
  return { pitches, closeAt, order };
}
