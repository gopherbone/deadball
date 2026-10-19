// Modifiers are how the outside world (crew jobs, bribes, tips, injuries, moods) leans
// on a game. They never script an outcome: they shift ratings and probabilities, and the
// sim rolls the dice.

import type { IncidentKind } from "./incidents.ts";

export type Effect =
  // rating deltas, in 20–80 scale points
  | "contact" | "power" | "eye" | "speed" | "fielding"
  | "stuff" | "control" | "stamina"
  // umpire: + makes edge calls favour the target team's pitchers, in probability points (0.05 = 5%)
  | "zone"
  // multiplies the chance of an incident kind
  | "incident"
  // pitcher's hit-by-pitch chance: +1 = twice as likely (retaliation, a grudge); summed, floor 0
  | "hbp";

export interface Modifier {
  id: string;
  /** What caused it: an operation id, "injury", "mood", etc. */
  source: string;
  target: { kind: "player" | "team" | "umpire" | "game"; id: string };
  effect: Effect;
  value: number;
  incident?: IncidentKind;
  note?: string;
}

export class ModSet {
  private readonly mods: Modifier[];
  constructor(mods: Modifier[]) {
    this.mods = mods;
  }

  add(m: Modifier) {
    this.mods.push(m);
  }

  /** Sum of rating deltas that apply to a player (directly or via their team). */
  rating(effect: Effect, playerId: string, teamId: string): number {
    let v = 0;
    for (const m of this.mods) {
      if (m.effect !== effect) continue;
      if ((m.target.kind === "player" && m.target.id === playerId) || (m.target.kind === "team" && m.target.id === teamId)) v += m.value;
    }
    return v;
  }

  /**
   * How far edge calls lean toward the pitcher (positive = more strikes). A zone mod on
   * the umpire widens the zone for everyone; a zone mod on a team means the ump was
   * paid to favour that team's pitchers (and squeeze its opponents').
   */
  zoneLean(umpireId: string, pitchingTeamId: string, battingTeamId: string): number {
    let v = 0;
    for (const m of this.mods) {
      if (m.effect !== "zone") continue;
      if (m.target.kind === "umpire" && m.target.id === umpireId) v += m.value;
      if (m.target.kind === "team" && m.target.id === pitchingTeamId) v += m.value;
      if (m.target.kind === "team" && m.target.id === battingTeamId) v -= m.value;
    }
    return v;
  }

  /** Team ids named by incident mods of this kind (who the sabotage was aimed at). */
  incidentTargets(kind: IncidentKind): string[] {
    return this.mods.filter(m => m.effect === "incident" && m.incident === kind && m.target.kind === "team").map(m => m.target.id);
  }

  incidentMult(kind: IncidentKind, teamIds: string[]): number {
    let v = 1;
    for (const m of this.mods) {
      if (m.effect !== "incident" || m.incident !== kind) continue;
      if (m.target.kind === "game" || (m.target.kind === "team" && teamIds.includes(m.target.id))) v *= m.value;
    }
    return v;
  }

  sources(kind: IncidentKind): string[] {
    return this.mods.filter(m => m.effect === "incident" && m.incident === kind).map(m => m.source);
  }
}
