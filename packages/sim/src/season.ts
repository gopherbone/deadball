// Folding a finished game back into the world: pitcher rest, injuries, moods.

import type { GameResult } from "./game.ts";
import type { World } from "./types.ts";

/** Call once per finished game. `advanceDay` once per calendar day (see below). */
export function applyGameToWorld(world: World, res: GameResult) {
  for (const [id, n] of Object.entries(res.pitchCounts)) {
    const p = world.players[id];
    if (p) p.recentPitches[0] = (p.recentPitches[0] ?? 0) + n;
  }
  for (const inj of res.injuries) {
    const p = world.players[inj.id];
    if (p) p.injury = { kind: inj.kind, daysLeft: inj.days };
  }
  // winners feel good, losers less so
  const sides = [[res.home, res.winner === "home"], [res.away, res.winner === "away"]] as const;
  for (const [box, won] of sides) {
    for (const l of box.bat) {
      const p = world.players[l.id];
      if (!p) continue;
      const day = (won ? 0.3 : -0.2) + (l.h >= 2 ? 0.4 : 0) + (l.hr ? 0.4 : 0) - (l.k >= 3 ? 0.5 : 0);
      p.mood = Math.max(-5, Math.min(5, p.mood * 0.9 + day));
    }
  }
}

/** Start of a new day: shift rest windows, heal injuries. */
export function advanceDay(world: World) {
  world.day++;
  for (const p of Object.values(world.players)) {
    p.recentPitches.unshift(0);
    p.recentPitches.length = 5;
    if (p.injury) {
      p.injury.daysLeft--;
      if (p.injury.daysLeft <= 0) delete p.injury;
    }
  }
}
