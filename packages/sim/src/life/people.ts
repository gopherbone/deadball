// People plumbing: ids, lookups, faces, houses, kinship, and the archive of the dead and departed.

import type { Rng } from "../rng.ts";
import { FACES } from "../faces.ts";
import { FIRST, LAST, NICKS, FEMALE_FIRST, FEMALE_NICKS } from "../names.ts";
import type { ArchivedPerson, Drama, Npc, Person, Player, Relationship, Role, Sex, World } from "../types.ts";
import { FREE_AGENT } from "../types.ts";
import { randomTraits } from "./ratings.ts";

/** advanceLife runs about this many times per in-game year (season + playoffs + hot stove). */
export const DAYS_PER_YEAR = 180;

export function nextId(world: World, prefix: "p" | "n"): string {
  const n = world.seq[prefix] ?? 0;
  world.seq[prefix] = n + 1;
  return `${prefix}${n}`;
}

export type AnyPerson = Player | Npc | ArchivedPerson;

export function personById(world: World, id: string | undefined): AnyPerson | undefined {
  if (!id) return undefined;
  return (world.players[id] as Player | undefined) ?? (world.npcs[id] as Npc | undefined) ?? world.archive[id];
}

export function living(world: World, id: string | undefined): Player | Npc | undefined {
  if (!id) return undefined;
  return (world.players[id] as Player | undefined) ?? world.npcs[id];
}

export function fullName(p: Person | undefined): string {
  if (!p) return "somebody";
  return p.nickname ? `${p.first} "${p.nickname}" ${p.last}` : `${p.first} ${p.last}`;
}

export function shortName(p: Person | undefined): string {
  if (!p) return "somebody";
  return `${p.first} ${p.last}`;
}

// --- faces -----------------------------------------------------------------------------

export function ageBucket(age: number): "young" | "adult" | "old" {
  return age < 30 ? "young" : age < 55 ? "adult" : "old";
}

const faceUse = new WeakMap<World, Map<string, number>>();

function faceCounts(world: World): Map<string, number> {
  let m = faceUse.get(world);
  if (!m) {
    m = new Map();
    for (const p of Object.values(world.players)) m.set(p.face, (m.get(p.face) ?? 0) + 1);
    for (const p of Object.values(world.npcs)) m.set(p.face, (m.get(p.face) ?? 0) + 1);
    faceUse.set(world, m);
  }
  return m;
}

/** Forget cached face usage (call after bulk archive operations). */
export function resetFaceCache(world: World) {
  faceUse.delete(world);
}

/** Least-used face matching sex and age bucket (falls back to sex, then anything). */
export function pickFace(world: World, sex: Sex, age: number, rng: Rng): string {
  if (FACES.length === 0) return "face:0";
  const bucket = ageBucket(age);
  let pool = FACES.filter(f => f.sex === sex && f.age === bucket);
  if (pool.length < 4) pool = FACES.filter(f => f.sex === sex);
  if (pool.length === 0) pool = FACES;
  const counts = faceCounts(world);
  let min = Infinity;
  for (const f of pool) min = Math.min(min, counts.get(f.id) ?? 0);
  const best = pool.filter(f => (counts.get(f.id) ?? 0) === min);
  const id = rng.pick(best).id;
  counts.set(id, (counts.get(id) ?? 0) + 1);
  return id;
}

// --- names & houses -------------------------------------------------------------------------

export function randomFirst(rng: Rng, sex: Sex): string {
  return rng.pick(sex === "M" ? FIRST : FEMALE_FIRST);
}

export function randomNick(rng: Rng, sex: Sex): string {
  return rng.pick(sex === "M" ? NICKS : FEMALE_NICKS);
}

/** A fresh, unique house id for a new family line with this surname. */
export function newHouseId(world: World, surname: string): string {
  const key = `h:${surname}`;
  const n = (world.seq[key] ?? 0) + 1;
  world.seq[key] = n;
  return n === 1 ? surname : `${surname}-${n}`;
}

export function houseName(world: World, id: string): string {
  return world.houses[id]?.name ?? id.replace(/-\d+$/, "");
}

/** Register a house (when a member becomes a public figure). */
export function ensureHouse(world: World, id: string, founder?: Person) {
  if (world.houses[id]) return world.houses[id];
  const h = { id, name: id.replace(/-\d+$/, ""), reputation: 0, founded: world.year, founderId: founder?.id, titles: 0, players: 0 };
  world.houses[id] = h;
  return h;
}

export function bumpHouse(world: World, id: string, rep: number) {
  const h = world.houses[id];
  if (h) h.reputation = Math.round((h.reputation + rep) * 10) / 10;
}

// --- creating people ----------------------------------------------------------------------

export interface NpcOpts {
  sex: Sex;
  age: number;
  role?: Role;
  first?: string;
  last?: string;
  house?: string;
  factionId?: string;
  occupation?: string;
  talent?: number;
  stats?: Record<string, number>;
  traits?: number;
}

export function createNpc(world: World, rng: Rng, o: NpcOpts): Npc {
  const last = o.last ?? rng.pick(LAST);
  const p: Npc = {
    id: nextId(world, "n"), kind: "npc", role: o.role ?? "citizen", factionId: o.factionId,
    first: o.first ?? randomFirst(rng, o.sex), last, sex: o.sex, face: pickFace(world, o.sex, o.age, rng),
    age: o.age, born: world.year - o.age, traits: randomTraits(rng, o.traits ?? (rng.chance(0.4) ? 2 : 1)), mood: 0,
    stats: o.stats ?? {}, family: { house: o.house ?? newHouseId(world, last), parents: [], children: [], drama: [] },
    active: true,
  };
  if (o.occupation) p.occupation = o.occupation;
  if (o.talent !== undefined) p.talent = o.talent;
  if (rng.chance(o.sex === "M" ? 0.2 : 0.08)) p.nickname = randomNick(rng, o.sex);
  world.npcs[p.id] = p;
  return p;
}

// --- kinship -------------------------------------------------------------------------------

export function marry(world: World, a: Person, b: Person) {
  a.family.spouse = b.id;
  b.family.spouse = a.id;
  // the wife takes the husband's surname; she keeps her birth house
  const wife = a.sex === "F" ? a : b.sex === "F" ? b : undefined;
  const husband = wife === a ? b : a;
  if (wife && husband.sex === "M") wife.last = husband.last;
}

export function unmarry(a: Person, b: Person | undefined) {
  if (a.family.spouse) (a.family.exSpouses ??= []).push(a.family.spouse);
  a.family.spouse = undefined;
  if (b && b.family.spouse === a.id) {
    (b.family.exSpouses ??= []).push(a.id);
    b.family.spouse = undefined;
  }
}

export function linkChild(parent: Person, child: Person) {
  if (!child.family.parents.includes(parent.id)) child.family.parents.push(parent.id);
  if (!parent.family.children.includes(child.id)) parent.family.children.push(child.id);
}

export function fatherOf(world: World, p: Person): AnyPerson | undefined {
  for (const id of p.family.parents) {
    const q = personById(world, id);
    if (q && q.sex === "M") return q;
  }
  return undefined;
}

export function siblingsOf(world: World, p: Person): AnyPerson[] {
  const out = new Map<string, AnyPerson>();
  for (const pid of p.family.parents) {
    const par = personById(world, pid);
    for (const cid of par?.family.children ?? []) {
      if (cid === p.id) continue;
      const c = personById(world, cid);
      if (c) out.set(cid, c);
    }
  }
  return [...out.values()];
}

/** Was this person ever a ballplayer (current or former)? */
export function wasPlayer(world: World, p: AnyPerson | undefined): boolean {
  if (!p) return false;
  return p.kind === "player" || !!p.career;
}

/** The nearest baseball ancestor ("son of", "grandson of", "nephew of"), for second-generation stories. */
export function baseballKin(world: World, p: Person): { id: string; relation: string } | undefined {
  for (const pid of p.family.parents) {
    const par = personById(world, pid);
    if (wasPlayer(world, par)) return { id: pid, relation: par!.sex === "M" ? "son" : "son" };
  }
  for (const pid of p.family.parents) {
    const par = personById(world, pid);
    for (const gid of par?.family.parents ?? []) {
      const g = personById(world, gid);
      if (wasPlayer(world, g)) return { id: gid, relation: "grandson" };
    }
    for (const sib of par ? siblingsOf(world, par) : []) {
      if (wasPlayer(world, sib)) return { id: sib.id, relation: "nephew" };
    }
  }
  return undefined;
}

export function addDrama(p: Person, d: Drama) {
  // one drama of each kind/with at a time; refresh instead of stacking
  const i = p.family.drama.findIndex(x => x.kind === d.kind && x.with === d.with);
  if (i >= 0) p.family.drama[i] = d;
  else p.family.drama.push(d);
  if (p.family.drama.length > 6) p.family.drama.shift();
}

// --- leaving the world ------------------------------------------------------------------------

/**
 * Move a person to the archive (dead, or moved away out of the story). Family links stay,
 * so they still resolve through personById; rosters, relationships and spouse links are cleaned up.
 */
export function archivePerson(world: World, id: string, gone: "dead" | "moved"): ArchivedPerson | undefined {
  const p = (world.players[id] ?? world.npcs[id]) as Player | Npc | undefined;
  if (!p) return world.archive[id];
  const role = p.kind === "npc" ? p.role : undefined;
  const occupation = p.kind === "npc" ? p.occupation : undefined;
  if (p.kind === "player") {
    removeFromTeams(world, p);
    delete world.players[id];
  } else delete world.npcs[id];
  if (gone === "dead") {
    p.dead = true;
    p.died = world.year;
    const sp = living(world, p.family.spouse);
    if (sp) unmarry(sp, p);
  }
  p.active = false;
  const a: ArchivedPerson = {
    id: p.id, kind: p.kind, first: p.first, last: p.last, face: p.face, sex: p.sex, age: p.age, born: p.born,
    traits: p.traits, mood: 0, active: false, gone, goneYear: world.year,
    family: { house: p.family.house, parents: p.family.parents, spouse: p.family.spouse, children: p.family.children, exSpouses: p.family.exSpouses, drama: [] },
  };
  if (p.nickname) a.nickname = p.nickname;
  if (p.dead) { a.dead = true; a.died = p.died; }
  if (p.talent !== undefined) a.talent = p.talent;
  if (p.career) a.career = p.career;
  if (p.quirks?.length) a.quirks = p.quirks;
  if (p.fame) a.fame = Math.round(p.fame);
  if (p.historical) a.historical = p.historical;
  if (p.cloneOf) a.cloneOf = p.cloneOf;
  if (role) a.role = role;
  if (occupation) a.occupation = occupation;
  world.archive[id] = a;
  world.relationships = world.relationships.filter(r => r.a !== id && r.b !== id);
  const counts = faceUse.get(world);
  if (counts) counts.set(p.face, Math.max(0, (counts.get(p.face) ?? 1) - 1));
  return a;
}

export function removeFromTeams(world: World, p: Player) {
  const t = world.teams[p.teamId];
  if (t) {
    t.roster = t.roster.filter(x => x !== p.id);
    if (t.il) t.il = t.il.filter(x => x !== p.id);
  }
  if (p.teamId === FREE_AGENT) world.freeAgents = world.freeAgents.filter(x => x !== p.id);
}

// --- relationships (world.relationships is shared with the game engine's brawl logic) ------------

interface RelIndex { arr: Relationship[]; len: number; byPair: Map<string, Relationship[]>; byPerson: Map<string, Relationship[]> }
const relCache = new WeakMap<World, RelIndex>();
const pairKey = (a: string, b: string) => (a < b ? `${a}|${b}` : `${b}|${a}`);

function relIndex(world: World): RelIndex {
  let ix = relCache.get(world);
  if (ix && ix.arr === world.relationships && ix.len === world.relationships.length) return ix;
  ix = { arr: world.relationships, len: world.relationships.length, byPair: new Map(), byPerson: new Map() };
  for (const r of world.relationships) {
    const k = pairKey(r.a, r.b);
    (ix.byPair.get(k) ?? ix.byPair.set(k, []).get(k)!).push(r);
    (ix.byPerson.get(r.a) ?? ix.byPerson.set(r.a, []).get(r.a)!).push(r);
    (ix.byPerson.get(r.b) ?? ix.byPerson.set(r.b, []).get(r.b)!).push(r);
  }
  relCache.set(world, ix);
  return ix;
}

/** Every relationship touching this id. */
export function relsOf(world: World, id: string): Relationship[] {
  return relIndex(world).byPerson.get(id) ?? [];
}

export function relEntry(world: World, a: string, b: string): Relationship | undefined {
  return relIndex(world).byPair.get(pairKey(a, b))?.[0];
}

export function relation(world: World, a: string, b: string): number {
  const rs = relIndex(world).byPair.get(pairKey(a, b));
  if (!rs) return 0;
  let v = 0;
  for (const r of rs) v += r.value;
  return Math.max(-5, Math.min(5, v));
}

export function setRelation(world: World, a: string, b: string, value: number, reason: string, kind?: Relationship["kind"]) {
  const r = relEntry(world, a, b);
  const v = Math.max(-5, Math.min(5, Math.round(value)));
  if (r) {
    r.value = v; r.reason = reason; r.since = world.day;
    if (kind) r.kind = kind;
  } else {
    const n: Relationship = { a, b, value: v, reason, since: world.day };
    if (kind) n.kind = kind;
    const ix = relCache.get(world);
    const fresh = ix && ix.arr === world.relationships && ix.len === world.relationships.length;
    world.relationships.push(n);
    if (fresh) {
      // keep the index current instead of rebuilding it
      ix.len++;
      const k = pairKey(a, b);
      (ix.byPair.get(k) ?? ix.byPair.set(k, []).get(k)!).push(n);
      (ix.byPerson.get(a) ?? ix.byPerson.set(a, []).get(a)!).push(n);
      (ix.byPerson.get(b) ?? ix.byPerson.set(b, []).get(b)!).push(n);
    }
  }
}

export function shiftRelation(world: World, a: string, b: string, delta: number, reason: string, kind?: Relationship["kind"]) {
  setRelation(world, a, b, relation(world, a, b) + delta, reason, kind);
}

// --- households ---------------------------------------------------------------------------------

const DEFAULT_TALENT = 42;

/** Children inherit talent with regression to the mean, and some of their parents' traits. */
export function childTalent(father: Person | undefined, mother: Person | undefined, rng: Rng): number {
  const f = father?.talent ?? DEFAULT_TALENT, m = mother?.talent ?? DEFAULT_TALENT;
  const mid = f * 0.6 + m * 0.4;
  return Math.round(Math.max(20, Math.min(80, 0.55 * mid + 0.45 * DEFAULT_TALENT + rng.normal(0, 7))));
}

export function makeChild(world: World, rng: Rng, father: Person | undefined, mother: Person | undefined, age: number, sex?: Sex): Npc {
  const s: Sex = sex ?? (rng.chance(0.51) ? "M" : "F");
  const last = father?.last ?? mother?.last ?? rng.pick(LAST);
  const house = father?.family.house ?? mother?.family.house ?? newHouseId(world, last);
  let first = randomFirst(rng, s);
  // juniors: sons named after their father
  if (s === "M" && father && rng.chance(0.12)) first = father.first;
  const kid = createNpc(world, rng, { sex: s, age, first, last, house, talent: childTalent(father, mother, rng), traits: 0 });
  const inherited = new Set<Person["traits"][number]>();
  for (const par of [father, mother]) for (const t of par?.traits ?? []) if (rng.chance(0.3)) inherited.add(t);
  if (inherited.size === 0 || rng.chance(0.5)) for (const t of randomTraits(rng, 1)) inherited.add(t);
  kid.traits = [...inherited].slice(0, 3);
  const quirks = new Set<NonNullable<Person["quirks"]>[number]>();
  for (const par of [father, mother]) for (const q of par?.quirks ?? []) if (BEHAVIOUR_QUIRKS.includes(q) && rng.chance(0.3)) quirks.add(q);
  if (quirks.size) kid.quirks = [...quirks];
  if (s === "M" && father && first === father.first) kid.nickname = rng.pick(["Junior", "Kid", "Sonny", "Little " + father.first]);
  if (father) linkChild(father, kid);
  if (mother) linkChild(mother, kid);
  return kid;
}

export function makeSpouse(world: World, rng: Rng, p: Person, job: string): Npc {
  const sex: Sex = p.sex === "M" ? "F" : "M";
  const age = Math.max(19, Math.round(p.age + (sex === "F" ? -2 : 2) + rng.normal(0, 3)));
  const sp = createNpc(world, rng, { sex, age, occupation: job, talent: Math.round(rng.normal(DEFAULT_TALENT, 7)) });
  marry(world, p, sp);
  return sp;
}

/** Ordinary behaviour quirks (the rest are weird-tier marks). */
export const BEHAVIOUR_QUIRKS: NonNullable<Person["quirks"]> = ["VAIN", "JEALOUS", "CHARITABLE", "LONER", "PRANKSTER"];

export const hasQ = (p: Person | undefined, q: NonNullable<Person["quirks"]>[number]) => !!p?.quirks?.includes(q);
export const hasT = (p: Person | undefined, t: Person["traits"][number]) => !!p?.traits.includes(t);
