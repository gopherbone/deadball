// Births, weddings, divorces and deaths; owners' successions; and the sweep that lets people
// with no remaining tie to baseball quietly leave the story (so the world stays a stable size).

import type { Rng } from "../rng.ts";
import { OCCUPATIONS, SPOUSE_JOBS } from "../names.ts";
import type { Npc, Person, Player, Umpire, World } from "../types.ts";
import { mkEvent, type LifeEvent } from "./events.ts";
import {
  DAYS_PER_YEAR, addDrama, archivePerson, bumpHouse, createNpc, ensureHouse, living, makeChild, makeSpouse, marry,
  personById, setRelation, shortName, unmarry, wasPlayer,
} from "./people.ts";
import { balanceOrg, orgId } from "./roster.ts";
import { relsOf } from "./people.ts";
import { addConcern, achieveGoal, goalOf } from "./inner.ts";
import { setHireHook } from "./storylines.ts";
import { clamp } from "./ratings.ts";

/** Children not in baseball leave the story (move away) at this age. */
export const KID_AGE = 20;

/** Annual probability of death by age. */
export function mortality(age: number): number {
  return Math.min(0.6, 0.00004 * Math.exp(0.095 * age)) + 0.0004;
}

/** People whose lives we keep simulating in full (they can marry, have children, make news). */
export function isNotable(world: World, p: Person & { kind: string; role?: string }): boolean {
  if (p.kind === "player") return true;
  if (p.role && p.role !== "citizen") return true;
  const c = p.career;
  return !!c && (c.mlGames >= 600 || c.peak >= 60);
}

const DEATH_OLD = ["in his sleep", "of heart failure", "of pneumonia", "after a long illness", "peacefully, at home", "while watching the game on TV", "after a fall at the bowling alley"];
const DEATH_YOUNG = ["in a car accident", "in a boating accident", "after being struck by lightning on a golf course", "in a grain-silo mishap", "in a fireworks accident", "after a bar fight went wrong"];

export function killPerson(world: World, rng: Rng, p: Player | Npc, events: LifeEvent[], cause?: string) {
  const why = cause ?? (p.age >= 60 ? rng.pick(DEATH_OLD) : rng.pick(DEATH_YOUNG));
  const why2 = p.sex === "F" ? why.replace("his", "her") : why;
  const teams = p.kind === "player" ? [p.teamId] : [];
  const mlOrg = p.kind === "player" && world.teams[p.teamId] ? orgId(world.teams[p.teamId]) : undefined;
  const relatives = [p.family.spouse, ...p.family.children, ...p.family.parents].map(id => living(world, id)).filter(Boolean) as (Player | Npc)[];
  const was = p.kind === "npc" ? p.role : "player";
  const friends = relsOf(world, p.id).filter(r => r.value >= 2 && (r.kind === "friend" || r.kind === "mentor")).map(r => living(world, r.a === p.id ? r.b : r.a)).filter(Boolean) as (Player | Npc)[];
  archivePerson(world, p.id, "dead");
  for (const r of relatives) addDrama(r, { kind: "bereavement", with: p.id, since: world.day, weight: -3, note: `${p.first} died` });
  for (const f of friends) addConcern(world, f, { kind: "grieving", about: p.id, until: world.day + 30, weight: -2, note: `${p.first} ${p.last}` });
  events.push(mkEvent(world, "death", [p.id, ...relatives.filter(r => r.kind === "player").map(r => r.id)], teams, { cause: why2, age: p.age, role: was, career: p.career }));
  if (mlOrg) balanceOrg(world, mlOrg, rng, events, { reason: "death" });
  if (p.kind === "npc") replaceRole(world, rng, p, events);
}

/** Someone with a job died or left it: managers get replaced, owners pass the club on. */
export function replaceRole(world: World, rng: Rng, p: Npc, events: LifeEvent[]) {
  if (p.role === "manager") {
    const team = Object.values(world.teams).find(t => t.managerId === p.id);
    if (team) hireManager(world, rng, team.id, events, "the late " + shortName(p));
  }
  for (const f of Object.values(world.factions)) {
    if (f.leaderId !== p.id) continue;
    const heir = heirOf(world, p);
    let next: Npc;
    if (heir) {
      next = heir;
      next.role = p.role;
      next.factionId = f.id;
      next.occupation = undefined;
      next.active = true;
      ensureHouse(world, next.family.house, next);
    } else {
      next = createNpc(world, rng, { sex: rng.chance(0.2) ? "F" : "M", age: 40 + rng.int(25), role: p.role, factionId: f.id });
      ensureHouse(world, next.family.house, next);
    }
    f.leaderId = next.id;
    events.push(mkEvent(world, "succession", [next.id, p.id], Object.values(world.teams).filter(t => t.factionId === f.id && t.level === "ML").map(t => t.id), {
      faction: f.id, what: `${shortName(next)} takes over ${f.name}${heir ? ` from ${heir.sex === "F" ? "her" : "his"} ${p.sex === "F" ? "mother" : "father"}` : ""}`, heir: !!heir,
    }));
  }
  if (p.role === "umpire") {
    // promote the best minor-league ump, hire a new minor-leaguer
    const u = p as Umpire;
    if (u.stats.ml === 1) {
      const minors = (Object.values(world.npcs).filter(n => n.role === "umpire" && (n as Umpire).stats.ml !== 1) as Umpire[]);
      if (minors.length) {
        const best = minors.reduce((a, b) => (b.stats.consistency > a.stats.consistency ? b : a));
        best.stats.ml = 1;
      }
    }
    newUmpire(world, rng);
  }
}

export function newUmpire(world: World, rng: Rng): Npc {
  // retired catchers make decent umpires
  const exCatcher = Object.values(world.npcs).find(n => n.role === "citizen" && n.career?.pos === "C" && n.age < 45);
  const stats = { zoneWidth: clamp(rng.normal(50, 10)), consistency: clamp(rng.normal(44, 10)), temper: clamp(rng.normal(54, 12)), corruptible: clamp(rng.normal(46, 15)), ml: 0 };
  if (exCatcher) {
    exCatcher.role = "umpire";
    exCatcher.factionId = "umps";
    exCatcher.stats = stats;
    exCatcher.occupation = undefined;
    exCatcher.active = true;
    return exCatcher;
  }
  return createNpc(world, rng, { sex: rng.chance(0.06) ? "F" : "M", age: 26 + rng.int(12), role: "umpire", factionId: "umps", stats });
}

function heirOf(world: World, p: Person): Npc | undefined {
  const kids = p.family.children.map(id => world.npcs[id]).filter(k => k && k.age >= 21 && k.role === "citizen");
  if (kids.length) return kids.sort((a, b) => b.age - a.age)[0];
  const sp = p.family.spouse ? world.npcs[p.family.spouse] : undefined;
  if (sp && sp.role === "citizen") return sp;
  return undefined;
}

export function hireManager(world: World, rng: Rng, teamId: string, events: LifeEvent[], replacing: string): Npc {
  const team = world.teams[teamId];
  // prefer the club's coaches, then retired stars, then a farm manager, then a stranger
  const pool = Object.values(world.npcs).filter(n => n.age >= 36 && n.age <= 62 && !n.dead && !n.stats.retiredManager &&
    ((n.role === "coach" && n.factionId === team.factionId) || (n.role === "citizen" && n.career && n.career.peak >= 55 && !n.traits.includes("DRUNK")) || n.role === "scout"));
  let m: Npc;
  if (pool.length) {
    m = pool.reduce((a, b) => (((b.career?.peak ?? 45) + (b.factionId === team.factionId ? 5 : 0)) > ((a.career?.peak ?? 45) + (a.factionId === team.factionId ? 5 : 0)) ? b : a));
  } else {
    m = createNpc(world, rng, { sex: "M", age: 40 + rng.int(20), role: "manager", factionId: team.factionId });
  }
  m.role = "manager";
  m.factionId = team.factionId;
  m.occupation = undefined;
  m.active = true;
  ensureHouse(world, m.family.house, m);
  team.managerId = m.id;
  events.push(mkEvent(world, "hire", [m.id], [teamId], { role: "manager", replacing, formerPlayer: !!m.career }));
  if (goalOf(m, "become_manager")) achieveGoal(world, rng, m, "become_manager", events, `hired by ${team.city}`);
  m.goals = [...(m.goals ?? []).filter(g => g.kind !== "keep_job"), { kind: "keep_job", since: world.day, intensity: 2, note: "keep his job" }];
  return m;
}
setHireHook(hireManager);

// --- the daily family round -----------------------------------------------------------------------

export function familyDay(world: World, rng: Rng, events: LifeEvent[]) {
  const perDay = (annual: number) => annual / DAYS_PER_YEAR;
  const people: (Player | Npc)[] = [...Object.values(world.players), ...Object.values(world.npcs)];
  for (const p of people) {
    if (!world.players[p.id] && !world.npcs[p.id]) continue; // died earlier today
    // NPC drama fades too
    if (p.kind === "npc" && p.family.drama.length) p.family.drama = p.family.drama.filter(d => world.day - d.since < (d.days ?? 60));

    // death
    const umpOnDuty = p.kind === "npc" && p.role === "umpire";
    const q = p.kind === "player" ? (p.age < 45 ? 0.0003 : mortality(p.age)) : umpOnDuty ? 0 : mortality(p.age);
    if (rng.chance(perDay(q))) { killPerson(world, rng, p, events); continue; }

    const notable = isNotable(world, p as Person & { kind: string; role?: string });
    if (!notable) continue;

    // weddings (Enhanced League drifters rarely settle down out in the desert)
    const desert = p.kind === "player" && world.teams[p.teamId]?.level === "EL" ? 0.3 : 1;
    if (!p.family.spouse && p.age >= 21 && p.age <= 50 && rng.chance(perDay((p.age < 24 ? 0.06 : 0.14) * desert))) wedding(world, rng, p, events);

    // births (rolled on the wife's side; husband or wife notable)
    const sp = living(world, p.family.spouse);
    if (sp) {
      const wife = p.sex === "F" ? p : sp.sex === "F" ? sp : undefined;
      const husband = wife === p ? sp : p;
      if (wife && (p === husband || !isNotable(world, husband as Person & { kind: string; role?: string })) && wife.age >= 19 && wife.age <= 40) {
        const kids = wife.family.children.filter(id => husband.family.children.includes(id)).length;
        const desertHome = [husband, wife].some(x => (x as Player).kind === "player" && world.teams[(x as Player).teamId]?.level === "EL") ? 0.4 : 1;
        if (kids < 3 && rng.chance(perDay((0.13 - kids * 0.035) * desertHome))) birth(world, rng, husband, wife, events);
      }
      // divorce outside the league's storylines (players' marriages go through marriage_trouble arcs)
      if (p.kind !== "player" && rng.chance(perDay(0.008))) divorce(world, rng, p, sp, events, rng.pick(["irreconcilable differences", "his gambling", "the road trips", "her new career", "a dispute over the dog"]));
    }
  }
}

function wedding(world: World, rng: Rng, p: Player | Npc, events: LifeEvent[]) {
  // sometimes a daughter (or niece) of a league family: dynasties intermarry
  const pool = Object.values(world.npcs).filter(n => n.sex !== p.sex && !n.family.spouse && n.role === "citizen" && n.age >= 19 && Math.abs(n.age - (p.age - (p.sex === "M" ? 2 : -2))) <= 7 &&
    n.family.parents.some(id => wasPlayer(world, personById(world, id)) || (world.npcs[id] && world.npcs[id].role !== "citizen")) &&
    !n.family.parents.some(id => p.family.parents.includes(id)));
  let spouse: Npc;
  const wanted = goalOf(p, "marry")?.target;
  const target = wanted ? world.npcs[wanted] : undefined;
  if (target && !target.family.spouse && target.sex !== p.sex && rng.chance(0.6)) {
    spouse = target;
    marry(world, p, spouse);
  } else if (pool.length && rng.chance(0.5)) {
    spouse = rng.pick(pool);
    marry(world, p, spouse);
    if (!spouse.occupation) spouse.occupation = rng.pick(SPOUSE_JOBS);
    for (const pid of spouse.family.parents) if (living(world, pid)) setRelation(world, p.id, pid, 2, "in-laws");
  } else {
    spouse = makeSpouse(world, rng, p, rng.pick(SPOUSE_JOBS));
  }
  for (const x of [p, spouse]) addDrama(x, { kind: "wedding", with: x === p ? spouse.id : p.id, since: world.day, weight: 2 });
  if (goalOf(p, "marry")) achieveGoal(world, rng, p, "marry", events, `married ${spouse.first} ${spouse.last}`);
  bumpHouse(world, p.family.house, 0.5);
  const fatherInLaw = spouse.family.parents.map(id => personById(world, id)).find(q => q && wasPlayer(world, q));
  events.push(mkEvent(world, "wedding", [p.id, spouse.id], p.kind === "player" ? [p.teamId] : [], {
    bride: p.sex === "M" ? spouse.id : p.id, groom: p.sex === "M" ? p.id : spouse.id, fatherInLaw: fatherInLaw?.id,
  }));
}

function birth(world: World, rng: Rng, father: Person, mother: Person, events: LifeEvent[]) {
  const kid = makeChild(world, rng, father, mother, 0);
  for (const par of [father, mother]) addDrama(par, { kind: "newborn", with: kid.id, since: world.day, weight: 1.5 });
  const fp = father as Player | Npc;
  events.push(mkEvent(world, "birth", [kid.id, father.id, mother.id], fp.kind === "player" ? [fp.teamId] : [], { sex: kid.sex, father: father.id, mother: mother.id, talent: kid.talent }));
}

export function divorce(world: World, rng: Rng, a: Person, b: Person, events: LifeEvent[], reason: string) {
  unmarry(a, b);
  for (const x of [a, b]) addDrama(x, { kind: "divorce", with: x === a ? b.id : a.id, since: world.day, weight: -3 });
  setRelation(world, a.id, b.id, -4, "the divorce");
  bumpHouse(world, a.family.house, -1);
  const pa = a as Player | Npc;
  events.push(mkEvent(world, "divorce", [a.id, b.id], pa.kind === "player" ? [pa.teamId] : [], { reason }));
  void rng;
}

// --- the winter sweep ---------------------------------------------------------------------------------

/**
 * People with no remaining tie to the league move out of the story (to the archive).
 * Children stay until 23; spouses of public figures stay; parents of current players stay.
 */
export function fadeSweep(world: World) {
  let n = 0;
  for (const p of Object.values(world.npcs)) {
    if (isNotable(world, p)) continue;
    if (p.age < KID_AGE) continue;
    const sp = living(world, p.family.spouse);
    if (sp && isNotable(world, sp)) continue;
    if (p.family.children.some(id => { const c = living(world, id); return c && (c.age < KID_AGE || c.kind === "player"); })) continue;
    if (p.family.parents.some(id => world.npcs[id]?.role === "owner")) continue; // heirs
    if (p.family.drama.some(d => world.day - d.since < 20 && d.kind !== "bereavement")) continue;
    archivePerson(world, p.id, "moved");
    n++;
  }
  return n;
}

/** Retired players' new lives. */
export function afterlife(world: World, rng: Rng, p: Person, peak: number, factionId?: string): { role: Npc["role"]; occupation?: string } {
  if (p.traits.includes("DRUNK") && rng.chance(0.6)) return { role: "citizen", occupation: "town drunk" };
  const staff = (role: string) => Object.values(world.npcs).filter(n => n.role === role && n.factionId === factionId).length;
  if (factionId && peak >= 56 && rng.chance(0.4) && staff("coach") < 3) return { role: "coach" };
  if (factionId && rng.chance(0.15) && staff("scout") < 2) return { role: "scout" };
  if ((p.traits.includes("CROOKED") || p.traits.includes("GAMBLER")) && rng.chance(0.3)) return { role: "citizen", occupation: rng.pick(["bookie's runner", "bar owner (with a back room)", "'consultant'"]) };
  if (p.traits.includes("PIOUS") && rng.chance(0.4)) return { role: "citizen", occupation: "preacher" };
  return { role: "citizen", occupation: rng.pick(OCCUPATIONS) };
}
