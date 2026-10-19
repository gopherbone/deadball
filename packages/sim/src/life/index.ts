// Lives & dynasties: the daily life round (after each game day) and the offseason.

import type { Rng } from "../rng.ts";
import type { World } from "../types.ts";
import { mkEvent, type LifeEvent } from "./events.ts";
import { tickDrama } from "./drama.ts";
import { familyDay } from "./family.ts";
import { manageInjuredLists, meritMoves, releasesAndSignings } from "./roster.ts";
import { tryTrade } from "./trades.ts";
import { rollWorldEvents } from "./worldnews.ts";
import { DAYS_PER_YEAR } from "./people.ts";
import { seedInnerLife } from "./inner.ts";
import { dailyDrama } from "./starts.ts";
import { advanceStorylines } from "./storylines.ts";
import { rollWeird } from "./weird.ts";
import { enhancedDay } from "./enhanced.ts";

export type { LifeEvent, LifeEventKind } from "./events.ts";
export { mkEvent } from "./events.ts";
export { runOffseason, retirePlayer } from "./offseason.ts";
export { moodModifiers, moodNote, dramaPressure } from "./drama.ts";
export { dramaModifiers, contextModifiers, chemistry, shavesGame, type GameCtx } from "./context.ts";
export {
  bettableStorylines, resolveProps, nudgeStoryline, storylineHazards, propsFor, openStorylines, KINDS as STORYLINE_KINDS,
  type BettableStoryline, type NudgeKind as StorylineNudgeKind, type Rates,
} from "./storylines.ts";
export { lifeAfterGame, propagateInjury } from "./aftergame.ts";
export { seasonOpeners } from "./starts.ts";
export { unexplained, transferToEnhanced, returnToContinental, balanceEnhancedTeam } from "./enhanced.ts";
export { FIGURES, WEIRD_RATES, forceWeird, type WeirdKind } from "./weird.ts";
export { fameOf, goalNote } from "./inner.ts";
export { worldMultipliers, type WorldMultipliers } from "./worldnews.ts";
export { personById, living, fullName, shortName, houseName, baseballKin, siblingsOf, fatherOf, wasPlayer, relation } from "./people.ts";
export { value as playerValue, groupOf, TEMPLATE, type Group } from "./ratings.ts";
export { rosterProblems, orgTeams, orgId, mlTeamIds } from "./roster.ts";
export { isNotable } from "./family.ts";

export interface LifeContext {
  phase?: "preseason" | "regular" | "playoffs" | "offseason";
  /** Win percentage by team id (contenders buy at the deadline). */
  winPct?: Record<string, number>;
  /** Today's calendar date (month drives seasonal world events). */
  date?: { month: number; year: number };
  /** Season day (trade deadline after day 110). */
  day?: number;
  /** Regular-season records (from SeasonState.table) for hot seats. */
  table?: Record<string, { w: number; l: number; seq: string }>;
}

const INJURIES_HIT = ["tweaked hamstring", "sprained ankle", "strained oblique", "jammed thumb", "bad back", "pulled groin", "hand fracture", "concussion (foul ball)", "knee surgery"];
const INJURIES_ARM = ["sore shoulder", "elbow inflammation", "blister", "strained lat", "torn elbow ligament", "rotator cuff tear", "back spasms", "bruised pitching hand"];
const INJURY_DAYS: Record<string, [number, number]> = {
  "tweaked hamstring": [4, 16], "sprained ankle": [5, 20], "strained oblique": [15, 40], "jammed thumb": [3, 10], "bad back": [4, 25],
  "pulled groin": [8, 25], "hand fracture": [30, 60], "concussion (foul ball)": [7, 21], "knee surgery": [60, 160], "sore shoulder": [5, 25],
  "elbow inflammation": [10, 30], blister: [3, 10], "strained lat": [20, 50], "torn elbow ligament": [120, 300], "rotator cuff tear": [90, 200],
  "back spasms": [4, 15], "bruised pitching hand": [3, 12],
};

/** Once per game day, after the games: injuries, drama and mood, roster moves, trades, family life, world news. */
export function advanceLife(world: World, rng: Rng, ctx: LifeContext = {}): LifeEvent[] {
  const events: LifeEvent[] = [];
  const r = rng.fork(`life-${world.day}`);
  const phase = ctx.phase ?? "regular";
  const inSeason = phase === "regular" || phase === "playoffs";

  // random (non-game) injuries for rostered players
  if (phase === "regular") {
    for (const t of Object.values(world.teams)) {
      for (const id of t.roster) {
        const p = world.players[id];
        if (!p || p.injury) continue;
        const rate = 0.0018 * (p.traits.includes("FRAGILE") ? 2.2 : p.traits.includes("IRON_MAN") ? 0.35 : 1) * (p.age >= 33 ? 1.4 : 1);
        if (!r.chance(rate)) continue;
        const kind = r.pick(p.pos === "P" ? INJURIES_ARM : INJURIES_HIT);
        const [lo, hi] = INJURY_DAYS[kind];
        const days = lo + r.int(hi - lo + 1);
        p.injury = { kind, daysLeft: days };
        if (t.level === "ML" || days >= 30) events.push(mkEvent(world, "injury", [id], [t.id], { kind, days }));
        if (days >= 100 && p.pos === "P") p.potential = Math.max(20, p.potential - 3);
      }
    }
  }
  if (phase !== "offseason") manageInjuredLists(world, r, events);
  // newcomers get an inner life
  for (const p of Object.values(world.players)) if (!p.goals) seedInnerLife(world, r, p);
  const day = ctx.day ?? 0;
  tickDrama(world, r, events, inSeason, { deadline: phase === "regular" && day >= 90 && day <= 110 });
  const sctx = { phase, table: ctx.table, day: ctx.day };
  dailyDrama(world, r, events, sctx);
  advanceStorylines(world, r, events, sctx);
  rollWeird(world, r, events, phase);
  enhancedDay(world, r, events, phase);

  if (phase === "regular") {
    if (world.day % 7 === 0) meritMoves(world, r, events);
    releasesAndSignings(world, r, events);
    const deadline = (ctx.day ?? 0) <= 110;
    if (deadline && r.chance(0.05)) tryTrade(world, r, events, ctx.winPct ?? {}, false);
  } else if (phase === "offseason") {
    if (r.chance(0.12)) tryTrade(world, r, events, {}, true);
  }

  familyDay(world, r, events);
  const month = ctx.date?.month ?? 6, year = ctx.date?.year ?? world.year;
  events.push(...rollWorldEvents(world, r, { offseason: phase === "offseason", month, year }));
  void DAYS_PER_YEAR;
  return events;
}
