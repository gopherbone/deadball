// Drama → mood → performance. Drama (Family.drama), concerns, fears and obsessions pull each
// player's mood; game.ts adds mood*0.6 to batting ratings, and moodModifiers()/dramaModifiers()
// add the pitchers' share plus all the contextual effects (see context.ts).

import type { Rng } from "../rng.ts";
import type { Modifier } from "../modifiers.ts";
import type { Drama, Person, World } from "../types.ts";
import type { LifeEvent } from "./events.ts";
import { hasT } from "./people.ts";
import { worldMultipliers } from "./worldnews.ts";
import { concernPressure, decayFame, innerPressure, pruneConcerns } from "./inner.ts";
import { contextModifiers, type GameCtx } from "./context.ts";

export const DRAMA_DAYS: Record<Drama["kind"], number> = {
  newborn: 25, divorce: 70, illness_in_family: 40, affair: 50, feud: 60, debt: 80, scandal: 40, wedding: 15, bereavement: 35, holdout: 30,
};

/** Current mood pressure from one drama (fades linearly). */
export function dramaWeight(world: World, d: Drama): number {
  const len = d.days ?? DRAMA_DAYS[d.kind];
  const age = world.day - d.since;
  if (age >= len) return 0;
  return d.weight * (1 - age / len);
}

export function dramaPressure(world: World, p: Person): number {
  let v = 0;
  for (const d of p.family.drama) v += dramaWeight(world, d);
  return v;
}

const r1 = (x: number) => Math.round(x * 10) / 10;

/**
 * Daily: fade drama and concerns, decay fame, and move moods toward the pressure of everything
 * on a player's mind. (New drama comes from starts.ts and storylines.ts.)
 */
export function tickDrama(world: World, _rng: Rng, _events: LifeEvent[], inSeason: boolean, ctx: { deadline?: boolean } = {}) {
  const moodByTeam = new Map<string, number>();
  const worldMood = (teamId: string) => {
    let m = moodByTeam.get(teamId);
    if (m === undefined) { m = worldMultipliers(world, teamId).mood; moodByTeam.set(teamId, m); }
    return m;
  };
  for (const p of Object.values(world.players)) {
    if (p.family.drama.length) p.family.drama = p.family.drama.filter(d => world.day - d.since < (d.days ?? DRAMA_DAYS[d.kind]));
    pruneConcerns(world, p);
    decayFame(world, p);
    const target = Math.max(-5, Math.min(5, dramaPressure(world, p) + concernPressure(world, p) + innerPressure(world, p, ctx) + worldMood(p.teamId) +
      (hasT(p, "SHOWBOAT") ? 0.3 : 0) - (hasT(p, "PARANOID") ? 0.3 : 0)));
    const k = inSeason ? 0.15 : 0.25;
    p.mood = r1(Math.max(-5, Math.min(5, p.mood * (1 - k) + target * k)));
  }
  for (const n of Object.values(world.npcs)) {
    if (n.concerns?.length) pruneConcerns(world, n);
    if (n.fame) decayFame(world, n);
  }
}

/**
 * Per-game mood and drama modifiers for the server to pass into GameSpec.modifiers.
 * `teamIds` = [home, away]; pass the scheduled game for game-specific context (night games,
 * playoffs, point shaving). Hitters' plain mood is already applied by game.ts.
 */
export function moodModifiers(world: World, teamIds: string[], game?: GameCtx): Modifier[] {
  return contextModifiers(world, teamIds, game);
}

/** Short reason for a player's mood (the heaviest current drama or concern), for logs and news. */
export function moodNote(world: World, p: Person): string {
  let best = "", bw = 0;
  for (const d of p.family.drama) {
    const w = Math.abs(dramaWeight(world, d));
    if (w > bw) { bw = w; best = `${d.kind}${d.note ? `: ${d.note}` : ""}`; }
  }
  for (const c of p.concerns ?? []) {
    if (c.until < world.day) continue;
    if (Math.abs(c.weight) > bw) { bw = Math.abs(c.weight); best = `${c.kind}${c.note ? `: ${c.note}` : ""}`; }
  }
  return best || (p.mood >= 0 ? "feeling good" : "in a funk");
}
