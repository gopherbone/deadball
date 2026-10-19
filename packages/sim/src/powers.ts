// Enhanced powers, in the spirit of Baseball Simulator 1.000's Ultra League. A player
// may carry powers; active ones cost from a per-game team pool and the manager spends
// them in big spots. Passive ones (arm, legs) always apply. Normal leagues have none,
// so calibration is untouched.

import type { Player } from "./types.ts";

export type PowerKind =
  | "FIREBALL"    // pitch: blazing, very hard to square up
  | "STOPPER"     // pitch: stalls mid-flight, swings come early
  | "WARP_PITCH"  // pitch: jumps location, takes become strikes
  | "CLOUD_BALL"  // pitch: vanishes, the batter guesses
  | "HYPER_HIT"   // bat: barrels it up with absurd exit velocity
  | "LEAP_CATCH"  // field: climbs the wall to rob home runs
  | "LASER_ARM"   // field: passive, throws at twice the speed
  | "WARP_RUN";   // run: passive, absurd speed

export interface Power {
  kind: PowerKind;
  level: 1 | 2 | 3;
}

export const POWER_COST: Record<PowerKind, number> = {
  FIREBALL: 3, STOPPER: 4, WARP_PITCH: 3, CLOUD_BALL: 4, HYPER_HIT: 4, LEAP_CATCH: 3, LASER_ARM: 0, WARP_RUN: 0,
};

/** Most times one player may use each active power in a game, so a single powered
 *  player can't carry every at-bat (a level-3 hyper hitter once hit 167 home runs). */
export const USE_CAP: Record<PowerKind, number> = {
  FIREBALL: 5, STOPPER: 4, WARP_PITCH: 5, CLOUD_BALL: 4, HYPER_HIT: 2, LEAP_CATCH: 2, LASER_ARM: 99, WARP_RUN: 99,
};

/** Ultra points each team gets per game (only matters if anyone on it has powers). */
export const TEAM_POINTS = 40;

export const PITCH_POWERS: PowerKind[] = ["FIREBALL", "STOPPER", "WARP_PITCH", "CLOUD_BALL"];

export function powersOf(p: Player): Power[] {
  return (p as Player & { powers?: Power[] }).powers ?? [];
}

export function power(p: Player, kind: PowerKind): number {
  for (const x of powersOf(p)) if (x.kind === kind) return x.level;
  return 0;
}

/** Per-pitch effect of an active pitching power. */
export interface PitchPowerEffect {
  kind: PowerKind;
  velo: number;        // mph added (cosmetic + contact)
  contactMult: number; // multiplies P(contact | swing)
  swingAdd: number;    // added to P(swing)
  forceZone?: 0 | 1;   // the pitch ends up in the zone no matter what
  evAdd: number;       // exit velocity change on contact
}

export function pitchEffect(kind: PowerKind, level: number): PitchPowerEffect {
  const k = level / 3;
  switch (kind) {
    case "FIREBALL": return { kind, velo: 8 + 6 * k, contactMult: 1 - 0.45 * k - 0.1, swingAdd: 0, evAdd: -6 };
    case "STOPPER": return { kind, velo: -25, contactMult: 1 - 0.55 * k - 0.1, swingAdd: 0.15, evAdd: -10 };
    case "WARP_PITCH": return { kind, velo: 0, contactMult: 1 - 0.3 * k - 0.05, swingAdd: -0.1, forceZone: 0, evAdd: -4 };
    case "CLOUD_BALL": return { kind, velo: 0, contactMult: 1 - 0.5 * k - 0.1, swingAdd: 0.05, evAdd: -8 };
    default: return { kind, velo: 0, contactMult: 1, swingAdd: 0, evAdd: 0 };
  }
}

/** Hyper hit: contact and exit velocity way up, launch angle in the sweet spot. */
export function hyperEffect(level: number) {
  return { contactAdd: 0.06 + 0.03 * level, evAdd: 6 + 4 * level, la: 24, laSd: 9 };
}

/** Chance a LEAP_CATCH fielder robs a home run he can get to. */
export function leapRobChance(level: number): number {
  return 0.25 + 0.15 * level;
}

/**
 * Manager AI: spend a power now? Leverage = late and close, runners in scoring
 * position, or a two-strike / full count. Keeps some points in reserve early.
 */
export function shouldUse(pointsLeft: number, cost: number, inning: number, leverage: boolean, rand: number): boolean {
  if (pointsLeft < cost) return false;
  const reserve = inning < 7 ? 8 : 0;
  if (pointsLeft - cost < reserve && !leverage) return false;
  return rand < (leverage ? 0.7 : 0.14);
}
