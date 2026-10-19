// Newsroom types. Story/WireLine match docs/ARCHITECTURE.md; extras are additive.

import type { Level, Weather } from "../types.ts";

export interface Story {
  id: string;
  day: number;
  kind: "recap" | "scandal" | "life" | "trade" | "feature" | "brief";
  headline: string;
  dek: string;
  body: string[];
  faceIds: string[];
  people: string[];
  teams: string[];
  gameId?: string;
  /** Page section: "Sports", "Crime", "Transactions", "Metro", "Elsewhere". */
  section?: string;
  /** "April 9, 1996" when the calendar is known. */
  dateline?: string;
  /** Archive picture id (archive.ts): client draws images/archive/<photo>-<w>.png. */
  photo?: string;
  /** Short caption for the picture. */
  photoCaption?: string;
  /** Front-page weight: higher leads the page (fame-driven for people stories). Default 1. */
  prominence?: number;
}

export interface WireLine { i: number; text: string }

/**
 * Structural copy of life/index.ts LifeEvent, so the newsroom compiles whether or not the
 * life module has landed. Anything optional is guarded.
 */
export interface LifeEventLike {
  id: string;
  day: number;
  kind: string;
  who: string[];
  teams?: string[];
  data?: Record<string, unknown>;
}

/** Structural subset of league ScheduledGame. */
export interface ScheduledGameLike {
  id: string;
  day: number;
  homeId: string;
  awayId: string;
  season?: number;
  level?: Level;
  umpireId?: string;
  weather?: Weather;
  slot?: number;
}

export interface BbsPost {
  id: string;
  board: string;
  author: string;
  day: number;
  text: string;
  /** Thread subject. */
  subject: string;
}

export const HEADLINE_MAX = 48;
export const DEK_MAX = 90;
export const WIRE_MAX = 36;
