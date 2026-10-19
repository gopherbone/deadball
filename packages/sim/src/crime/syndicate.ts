// Syndicates: up to four accounts that share crews, split costs and heat, and never
// tip each other off. Standings are a pure fold the server can run over its records.

import type { OpOutcome } from "./types.ts";

export const SYNDICATE_MAX = 4;

export interface Syndicate {
  id: string;
  name: string;
  members: string[];
}

export interface SyndicateStanding {
  syndicateId: string;
  name: string;
  members: string[];
  /** Betting and op profit net of costs, as supplied by the server per member. */
  net: number;
  ops: number;
  pulledOff: number;
  blown: number;
  exposed: number;
  arrests: number;
  heat: number;
}

/** Can `ownerId` join? (not already a member of another, room left) */
export function canJoin(s: Syndicate, ownerId: string, all: Syndicate[]): { ok: true } | { ok: false; reason: string } {
  if (s.members.includes(ownerId)) return { ok: false, reason: "already a member" };
  if (s.members.length >= SYNDICATE_MAX) return { ok: false, reason: "syndicate is full" };
  if (all.some(x => x.id !== s.id && x.members.includes(ownerId))) return { ok: false, reason: "already in another syndicate" };
  return { ok: true };
}

/**
 * Standings across syndicates. `profit` is each account's net $ over the period
 * (the server knows bets and costs); `outcomes` are op outcomes over the same period.
 * An outcome counts for a syndicate when its syndicateId matches or its orderer is a member.
 */
export function syndicateStandings(syndicates: Syndicate[], outcomes: OpOutcome[], profit: Record<string, number> = {}): SyndicateStanding[] {
  const rows = syndicates.map(s => {
    const mine = outcomes.filter(o => o.syndicateId === s.id || (!!o.ownerId && s.members.includes(o.ownerId)));
    const heat = mine.reduce((a, o) => a + Object.entries(o.heatBy ?? {}).filter(([k]) => s.members.includes(k)).reduce((x, [, v]) => x + v, 0), 0);
    return {
      syndicateId: s.id, name: s.name, members: [...s.members],
      net: s.members.reduce((a, m) => a + (profit[m] ?? 0), 0),
      ops: mine.length,
      pulledOff: mine.filter(o => o.success).length,
      blown: mine.filter(o => !o.success).length,
      exposed: mine.filter(o => o.exposed).length,
      arrests: mine.reduce((a, o) => a + o.arrests.length, 0),
      heat: Math.round(heat * 10) / 10,
    };
  });
  return rows.sort((a, b) => b.net - a.net || b.pulledOff - a.pulledOff || a.arrests - b.arrests || (a.syndicateId < b.syndicateId ? -1 : 1));
}
