// Read-only access to season stats. The life agent owns `world.stats[personId][season]`
// = { bat, pitch }; it may not exist yet, so everything here is guarded and the field
// names are read loosely. (Local type: replace with the life agent's once it lands.)

import type { World } from "../types.ts";

export interface LooseBat { g?: number; pa?: number; ab?: number; r?: number; h?: number; d?: number; t?: number; hr?: number; rbi?: number; bb?: number; k?: number; so?: number; sb?: number }
export interface LoosePitch { g?: number; gs?: number; outs?: number; ip?: number; w?: number; l?: number; sv?: number; s?: number; h?: number; er?: number; bb?: number; k?: number; so?: number; hr?: number }
export interface LooseSeason { bat?: LooseBat; pitch?: LoosePitch; teamId?: string; team?: string }

type StatsHost = { stats?: Record<string, Record<string | number, LooseSeason | undefined> | undefined> };

export function seasonStats(world: World, personId: string, season: number): LooseSeason | undefined {
  const all = (world as unknown as StatsHost).stats;
  if (!all || typeof all !== "object") return undefined;
  const mine = all[personId];
  if (!mine || typeof mine !== "object") return undefined;
  const s = mine[season] ?? mine[String(season)];
  return s && typeof s === "object" ? s : undefined;
}

/** Seasons with stats for this person, newest first, at or before `upTo`. */
export function statSeasons(world: World, personId: string, upTo: number): number[] {
  const all = (world as unknown as StatsHost).stats;
  const mine = all?.[personId];
  if (!mine || typeof mine !== "object") return [];
  return Object.keys(mine).map(Number).filter(n => Number.isFinite(n) && n <= upTo).sort((a, b) => b - a);
}

const n = (x: unknown) => (typeof x === "number" && Number.isFinite(x) ? x : 0);

export function outsOf(p: LoosePitch): number {
  if (typeof p.outs === "number") return p.outs;
  if (typeof p.ip === "number") return Math.floor(p.ip) * 3 + Math.round((p.ip % 1) * 10);
  return 0;
}

export function batAvg(b: LooseBat): number { return n(b.ab) > 0 ? n(b.h) / n(b.ab) : 0; }
export function batK(b: LooseBat): number { return n(b.k ?? b.so); }
export function pitchK(p: LoosePitch): number { return n(p.k ?? p.so); }
export function era(p: LoosePitch): number { const o = outsOf(p); return o > 0 ? (n(p.er) * 27) / o : 0; }
export function saves(p: LoosePitch): number { return n(p.sv ?? p.s); }

export const fmtAvg = (x: number) => (x >= 1 ? x.toFixed(3) : x.toFixed(3).slice(1));
export const fmtIp = (outs: number) => `${Math.floor(outs / 3)}.${outs % 3}`;
export const num = n;
