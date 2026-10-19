// Random in-game incidents. Base rates are per game; modifiers (sabotage, weather, moods)
// multiply them. Each incident changes game state through new modifiers or substitutions,
// and leaves a line in the log for the wire and the newspaper.

export type IncidentKind =
  | "RACCOONS_BULLPEN"
  | "RACCOON_ON_FIELD"
  | "FOOD_POISONING"
  | "FAN_ON_FIELD"
  | "LASER_POINTER"
  | "RAIN_DELAY"
  | "EJECTION"
  | "BRAWL"
  | "BALL_TAMPERING"
  | "BLACKOUT";

export interface IncidentDef {
  kind: IncidentKind;
  /** Expected occurrences per game before modifiers. */
  perGame: number;
  /** Only happens when triggered by something (e.g. an HBP), not on the clock. */
  triggered?: boolean;
  /** Can happen at most once per game. */
  once: boolean;
}

export const INCIDENTS: Record<IncidentKind, IncidentDef> = {
  RACCOONS_BULLPEN: { kind: "RACCOONS_BULLPEN", perGame: 0.0015, once: true },
  RACCOON_ON_FIELD: { kind: "RACCOON_ON_FIELD", perGame: 0.004, once: false },
  FOOD_POISONING: { kind: "FOOD_POISONING", perGame: 0.002, once: true },
  FAN_ON_FIELD: { kind: "FAN_ON_FIELD", perGame: 0.02, once: false },
  LASER_POINTER: { kind: "LASER_POINTER", perGame: 0.001, once: false },
  RAIN_DELAY: { kind: "RAIN_DELAY", perGame: 0, once: true }, // driven by weather.rain
  EJECTION: { kind: "EJECTION", perGame: 0, triggered: true, once: false },
  BRAWL: { kind: "BRAWL", perGame: 0, triggered: true, once: true },
  BALL_TAMPERING: { kind: "BALL_TAMPERING", perGame: 0.0008, once: true },
  BLACKOUT: { kind: "BLACKOUT", perGame: 0.0005, once: true },
};

/** Clock-driven incidents are rolled at the start of each half inning. */
export const HALF_INNINGS_PER_GAME = 18;
