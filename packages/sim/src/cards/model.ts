// Card types and small shared helpers (person lookup, ratings).

import type { Npc, Person, Player, Team, World } from "../types.ts";
import type { CardKind, Rarity } from "./data.ts";

export interface CardDef {
  id: string;          // "S1-042"
  personId: string;    // main subject; for Moments the central person ("" if nobody)
  season: number;
  set: string;         // "Series 1"
  number: number;      // 1-based within the set
  rarity: Rarity;      // base rarity of the def ("common"); a pulled Card carries its own
  variant?: string;    // misprint id (MISPRINTS) or original flair id (ORIGINAL_FLAIRS)
  // --- additions (optional so older stored defs still type-check)
  kind?: CardKind;
  setName?: string;    // "Series 1: Smoke & Mirrors"
  teamId?: string;     // club at print time
  pos?: string;        // "SS", "SP", "MGR", "UMP", "OWN", "EXEC", "MOMENT"
  title?: string;      // Moments: "Night of the Raccoons"
  moment?: MomentInfo;
  /** Archive picture for Moment cards (images/archive/<photo>-<400|160|96|48>.png). */
  photo?: string;
  photoCaption?: string;
}

/** What redeeming the card does. Printed on the card; deterministic. */
export type Redeem =
  | { kind: "boost"; boost: number; days: number }
  | { kind: "retire" };

export interface Card extends CardDef {
  serial?: number;
  printRun?: number;
  /** Printed redeemable effect (scarce: every Original, every 5th Gilded print of a player). */
  redeem?: Redeem;
  /** Its subject retired via a redeemed card: a "Final Season" collectible. */
  finalSeason?: boolean;
}

/** One big in-world happening, supplied by the server (e.g. from game incidents or news). */
export interface MomentInput {
  id: string;                // stable id, e.g. `${gameId}:${index}`
  season: number;
  day: number;
  kind: string;              // IncidentKind or "FEUD" / "SCANDAL" / anything
  who?: string[];            // people involved, most important first
  teams?: string[];
  gameId?: string;
  inning?: number;
  title?: string;            // override the default title
  blurb?: string;            // override the default card-back blurb
}

export interface MomentInfo { sourceId: string; kind: string; day: number; who: string[]; teams: string[]; gameId?: string; inning?: number; blurb?: string }

export function personOf(world: World, id: string): Person | undefined {
  return world.players[id] ?? world.npcs[id];
}

export function isPlayer(p: Person | undefined): p is Player {
  return !!p && (p as Player).kind === "player" && !!(p as Player).batting; // archived ex-players have no ratings
}

export function isNpc(p: Person | undefined): p is Npc {
  return !!p && (p as Npc).kind === "npc" && !!(p as Npc).stats;
}

export const fullName = (p: Person) => `${p.first} ${p.last}`;

const avg = (xs: number[]) => xs.reduce((a, b) => a + b, 0) / xs.length;

/** 20–80 overall for a player (pitchers by pitching ratings). */
export function overall(p: Player): number {
  if (p.pitching) {
    const r = p.pitching;
    return avg([r.stuff, r.stuff, r.control, r.command, r.movement]);
  }
  const b = p.batting, f = p.fielding;
  return avg([b.contact, b.contact, b.power, b.power, b.eye, b.gap, b.speed, (f.range + f.hands + f.arm + f.reaction) / 4]);
}

export function teamOf(world: World, p: Person | undefined, fallbackTeamId?: string): Team | undefined {
  if (isPlayer(p) && world.teams[p.teamId]) return world.teams[p.teamId];
  if (fallbackTeamId && world.teams[fallbackTeamId]) return world.teams[fallbackTeamId];
  if (isNpc(p)) {
    for (const t of Object.values(world.teams)) if (t.managerId === p.id) return t;
    if (p.factionId) for (const t of Object.values(world.teams)) if (t.level === "ML" && t.factionId === p.factionId) return t;
  }
  return undefined;
}

export function inferKind(world: World, def: CardDef): CardKind {
  if (def.kind) return def.kind;
  if (def.moment) return "moment";
  const p = personOf(world, def.personId);
  if (isPlayer(p)) return world.teams[p.teamId]?.level === "ML" ? "player" : "prospect";
  if (isNpc(p)) {
    if (p.role === "umpire") return "umpire";
    if (p.role === "manager") return "manager";
    if (p.role === "owner") return "owner";
    return "figure";
  }
  return "player";
}

/** Small stable hash for picking flavor deterministically from ids. */
export function strHash(s: string): number {
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); }
  return h >>> 0;
}
