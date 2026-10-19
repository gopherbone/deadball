// Crew recruitment: a daily board of oddballs per account, deterministic from (ownerId, day).

import { Rng } from "../rng.ts";
import type { World } from "../types.ts";
import { ERA_ASIDES, ROLES, citizenName, makeCitizen, roleDef } from "./npcs.ts";
import { CREW_SKILLS, type Candidate, type CrewMember, type CrewSkill } from "./types.ts";

export const CANDIDATES_PER_DAY = 5;

const clamp = (x: number, lo: number, hi: number) => Math.max(lo, Math.min(hi, x));

/**
 * Today's candidates for an account. The `rng` argument is accepted for signature
 * compatibility, but the board is derived from (ownerId, season, day) so every call
 * on the same day shows the same faces. The NPCs are not stored until hired.
 */
export function recruitPool(world: World, ownerId: string, day: number, rng?: Rng): Candidate[] {
  void rng;
  const r = new Rng(`recruit:${ownerId}:${world.season}:${day}`);
  const roles = r.shuffle([...ROLES]).slice(0, CANDIDATES_PER_DAY);
  const out: Candidate[] = [];
  roles.forEach((role, i) => {
    const id = `cit-${ownerId}-${world.season}-${day}-${i}`;
    const person = makeCitizen(world, role, id, r);
    const skills = {} as Record<CrewSkill, number>;
    for (const s of CREW_SKILLS) {
      const base = role.base[s] ?? 0;
      const noise = base ? r.int(3) - 1 : r.chance(0.3) ? 1 : 0;
      skills[s] = clamp(base + noise, 0, 5);
    }
    if (person.traits.includes("CHARMING")) skills.charm = clamp(skills.charm + 1, 0, 5);
    if (person.traits.includes("PARANOID")) skills.sneak = clamp(skills.sneak + 1, 0, 5);
    if (person.traits.includes("HOTHEAD")) skills.muscle = clamp(skills.muscle + 1, 0, 5);
    if (person.traits.includes("DRUNK")) skills.nerve = clamp(skills.nerve + 1, 0, 5);
    let loyalty = 2 + r.int(3);
    if (person.traits.includes("LOYAL")) loyalty += 1;
    if (person.traits.includes("SNITCH")) loyalty -= 1;
    if (person.traits.includes("GREEDY")) loyalty -= 1;
    loyalty = clamp(loyalty, 0, 5);
    const total = CREW_SKILLS.reduce((a, s) => a + skills[s], 0);
    const price = Math.round((20 + total * 9 + loyalty * 6) * (person.traits.includes("GREEDY") ? 1.4 : 1) / 5) * 5;
    out.push({
      id, ownerId, day, person, role: role.key, roleLabel: role.label, skills, loyalty, price,
      pitch: r.pick(role.pitches).replace("{name}", citizenName(person, role)) + (r.chance(0.3) ? ` ${r.pick(ERA_ASIDES)}` : ""), traits: person.traits,
    });
  });
  return out;
}

/** Hire a candidate: the NPC joins world.npcs (role "crew") and becomes a crew member. */
export function hireCandidate(world: World, cand: Candidate): CrewMember {
  const p = world.npcs[cand.person.id] ?? cand.person;
  p.role = "crew";
  p.stats = { ...p.stats, ...cand.skills, loyalty: cand.loyalty, roleIdx: ROLES.findIndex(r => r.key === cand.role) };
  world.npcs[p.id] = p;
  return {
    id: `crew-${p.id}`, personId: p.id, ownerId: cand.ownerId, skills: { ...cand.skills }, loyalty: cand.loyalty,
    status: "free", heat: 0, role: cand.role, jobs: 0,
  };
}

/** Day rollover: release crew whose jail/hospital/busy time is up. Mutates and returns the changed ones. */
export function tickCrew(crew: CrewMember[], day: number): CrewMember[] {
  const changed: CrewMember[] = [];
  for (const c of crew) {
    if ((c.status === "jailed" || c.status === "hospital" || c.status === "busy") && (c.until ?? 0) <= day) {
      c.status = "free";
      delete c.until;
      changed.push(c);
    }
    // heat cools slowly
    if (c.heat > 0 && day % 3 === 0) c.heat = Math.max(0, c.heat - 1);
  }
  return changed;
}

/** "Sister Agnes", "Hot Dog Hal"... for a crew member's person. */
export function crewName(world: World, c: Pick<CrewMember, "personId" | "role">): string {
  const p = world.npcs[c.personId];
  return p ? citizenName(p, roleDef(c.role)) : "a person of interest";
}

/** "church organist" etc. */
export function crewRoleLabel(c: Pick<CrewMember, "role">): string {
  return roleDef(c.role)?.label ?? "associate";
}
