// Convenience loop for tools and tests: play a day's slate, record it, roll the day over.
// (The server runs its own version with crew operations and bets in between.)

import { simulateGame, type GameResult } from "../game.ts";
import type { Rng } from "../rng.ts";
import type { World } from "../types.ts";
import { moodModifiers } from "../life/drama.ts";
import type { LifeEvent } from "../life/events.ts";
import { advanceSeasonDay, recordResult, slateFor, type ScheduledGame, type SeasonState } from "./index.ts";

export interface DayOutcome {
  day: number;
  phase: SeasonState["phase"];
  games: { game: ScheduledGame; result: GameResult }[];
  events: LifeEvent[];
}

/** Play every game on today's slate (optionally only some levels), then advance the day. */
export function playDay(world: World, state: SeasonState, rng: Rng, opts: { keepResults?: boolean } = {}): DayOutcome {
  const day = state.day, phase = state.phase;
  const games: DayOutcome["games"] = [];
  for (const g of slateFor(state, day)) {
    if (state.results[g.id]) continue;
    const res = simulateGame(world, {
      id: g.id, day: g.day, homeId: g.homeId, awayId: g.awayId, umpireId: g.umpireId, weather: g.weather,
      modifiers: moodModifiers(world, [g.homeId, g.awayId], g),
    }, `${g.id}:${world.seq.e ?? 0}`);
    recordResult(world, state, g, res);
    if (opts.keepResults) games.push({ game: g, result: res });
  }
  const events = advanceSeasonDay(world, state, rng);
  return { day, phase, games, events };
}

/** Play until the season number changes (one full season incl. playoffs and offseason). */
export function playSeason(world: World, state: SeasonState, rng: Rng, onDay?: (o: DayOutcome) => void): void {
  const season = state.season;
  let guard = 0;
  while (state.season === season && guard++ < 400) {
    const o = playDay(world, state, rng);
    onDay?.(o);
  }
}
