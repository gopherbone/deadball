// LifeEvent: the record every life/league change leaves behind for news, mail and history.

import type { World } from "../types.ts";

export type LifeEventKind =
  | "birth" | "death" | "wedding" | "divorce" | "retirement" | "debut" | "callup" | "demotion" | "trade"
  | "release" | "signing" | "injury" | "drama" | "milestone" | "draft"
  // additions
  | "return"        // back from the injured list
  | "il"            // placed on the injured list
  | "award"         // MVP, Pitcher of the Year, Rookie of the Year
  | "champion"      // Continental Series won
  | "playoffs"      // series result / clinch
  | "hire" | "fire" // managers
  | "succession"    // ownership / faction leadership passes to someone
  | "coming_of_age" // a league kid turns 18 and chooses (or not) baseball
  | "season"        // season opens / ends, phase changes
  | "world"         // non-baseball background news (elections, fads, strikes, weather)
  // drama layer (see docs/DRAMA.md)
  | "goal"          // a goal achieved / abandoned / turned into an obsession
  | "fear"          // a fear realised or confronted
  | "fame"          // fame tiers, nicknames, endorsements, fan clubs
  | "fight"         // clubhouse fights, bar brawls, on-field brawls
  | "beanball"      // a retaliation hit-by-pitch
  | "weird"         // abductions, plane crashes, resurrections, clones, historical figures
  // Enhanced League (see docs/ENHANCED.md)
  | "transfer"      // sent to the Enhanced League (sub "to_enhanced") or back (sub "return")
  | "exhibition";   // an Enhanced vs Continental exhibition result

export interface LifeEvent {
  id: string;
  day: number;
  kind: LifeEventKind;
  who: string[];
  teams?: string[];
  data?: Record<string, unknown>;
}

export function mkEvent(world: World, kind: LifeEventKind, who: string[], teams?: string[], data?: Record<string, unknown>): LifeEvent {
  const n = world.seq.e = (world.seq.e ?? 0) + 1;
  const e: LifeEvent = { id: `e${n}`, day: world.day, kind, who };
  if (teams && teams.length) e.teams = teams;
  if (data) e.data = { season: world.season, year: world.year, ...data };
  else e.data = { season: world.season, year: world.year };
  return e;
}
