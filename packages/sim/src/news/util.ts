// Newsroom helpers: names, dates, length fitting.

import type { Npc, Person, Player, World } from "../types.ts";
import { Rng } from "../rng.ts";
import { DEK_MAX, HEADLINE_MAX } from "./types.ts";
import { ROLES } from "../crime/npcs.ts";
import { seasonDate } from "../league/calendar.ts";

export const person = (world: World, id: string | undefined): Player | Npc | undefined =>
  id ? world.players[id] ?? world.npcs[id] ?? ((world as { archive?: Record<string, unknown> }).archive?.[id] as Player | Npc | undefined) : undefined;

export const lastName = (world: World, id: string | undefined): string => person(world, id)?.last ?? "Somebody";

/** Full name; nickname in quotes on first reference when there is one. */
export function fullName(world: World, id: string | undefined, nick = true): string {
  const p = person(world, id);
  if (!p) return "an unidentified person";
  const title = crewTitle(p);
  if (title) return `${title} ${p.first} ${p.last}`;
  return p.nickname && nick ? `${p.first} "${p.nickname}" ${p.last}` : `${p.first} ${p.last}`;
}

/** "Sister" for nuns etc. */
function crewTitle(p: Person): string | undefined {
  const s = (p as Npc).stats;
  const idx = s && typeof s.roleIdx === "number" ? s.roleIdx : -1;
  return idx >= 0 ? ROLES[idx]?.title : undefined;
}

/** Role label for crew NPCs ("church organist"), or a sensible fallback. */
export function roleLabel(world: World, id: string): string {
  const p = person(world, id);
  if (!p) return "person";
  if (p.kind === "player") return p.pos === "P" ? "pitcher" : "infielder";
  const idx = typeof p.stats?.roleIdx === "number" ? p.stats.roleIdx : -1;
  if (idx >= 0 && ROLES[idx]) return ROLES[idx].label;
  return p.role === "umpire" ? "umpire" : p.role === "owner" ? "owner" : p.role === "manager" ? "manager" : "local";
}

export const sexOf = (p: Person | undefined): "M" | "F" | undefined => (p as { sex?: "M" | "F" } | undefined)?.sex;

export const teamName = (world: World, id: string | undefined) => (id && world.teams[id]?.name) || "club";
export const teamCity = (world: World, id: string | undefined) => (id && world.teams[id]?.city) || "town";
export const teamFull = (world: World, id: string | undefined) => (id && world.teams[id] ? `${world.teams[id].city} ${world.teams[id].name}` : "the club");

export function ordinal(n: number): string {
  const s = ["th", "st", "nd", "rd"], v = n % 100;
  return n + (s[(v - 20) % 10] || s[v] || s[0]);
}

export const capFirst = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);

/** Calendar date via the league calendar ("Tue, April 2, 1996"). Season 1 = 1996. */
export function dateLine(world: World, day: number): string {
  const year = world.year >= 1900 ? world.year : 1995 + world.season;
  return seasonDate(year, day).label;
}

/** First candidate that fits, else the shortest, hard-trimmed. */
export function fit(cands: string[], max: number): string {
  const ok = cands.find(c => c.length <= max);
  if (ok) return ok;
  const s = [...cands].sort((a, b) => a.length - b.length)[0] ?? "";
  if (s.length <= max) return s;
  const cut = s.slice(0, max - 1);
  const sp = cut.lastIndexOf(" ");
  return (sp > max * 0.6 ? cut.slice(0, sp) : cut).replace(/[,;:\-\s]+$/, "") + "…";
}

export const headline = (rng: Rng, cands: string[]) => fit(rng.shuffle(cands.filter(Boolean)), HEADLINE_MAX);
export const dek = (cands: string[]) => fit(cands.filter(Boolean), DEK_MAX);

export function faces(world: World, ids: string[]): string[] {
  const out: string[] = [];
  for (const id of ids) {
    const f = person(world, id)?.face;
    if (f && !out.includes(f)) out.push(f);
  }
  return out;
}

export const uniq = <T>(xs: T[]) => [...new Set(xs)];

/** "1 RBI", "2 RBIs" style helpers. */
export const plural = (n: number, one: string, many = one + "s") => `${n} ${n === 1 ? one : many}`;
export const numWord = (n: number) => ["no", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"][n] ?? String(n);

/** "a usher" -> "an usher". */
export const article = (word: string) => (/^[aeiou]/i.test(word) ? `an ${word}` : `a ${word}`);

/** Quote that ends a clause before an attribution: "Long season." said -> "Long season," said. */
export const quoteLead = (q: string) => (q.endsWith(".") ? q.slice(0, -1) + "," : q);

/** "The Archdiocese of X" mid-sentence -> "the Archdiocese of X". */
export const midName = (name: string) => name.replace(/^The /, "the ");

/** "A, B and C" */
export const andList = (xs: string[]) => (xs.length <= 1 ? xs.join("") : `${xs.slice(0, -1).join(", ")} and ${xs[xs.length - 1]}`);

const NTH = ["zeroth", "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "10th", "11th", "12th", "13th", "14th", "15th", "16th", "17th", "18th", "19th", "20th"];
/** Newspaper-style inning ordinal: "sixth", "11th". */
export const nth = (n: number) => NTH[n] ?? ordinal(n);

const WEEKDAY: Record<string, string> = { Sun: "Sunday", Mon: "Monday", Tue: "Tuesday", Wed: "Wednesday", Thu: "Thursday", Fri: "Friday", Sat: "Saturday" };
/** "Tuesday" for a season day (league calendar). */
export function weekday(world: World, day: number): string {
  const year = world.year >= 1900 ? world.year : 1995 + world.season;
  return WEEKDAY[seasonDate(year, day).weekday] ?? "";
}

export const parkName = (world: World, teamId: string | undefined) => (teamId && world.parks[world.teams[teamId]?.parkId ?? ""]?.name) || "the ballpark";

/** Deterministic small number in [lo, hi] from a string. */
export function seeded(seed: string, lo: number, hi: number): number {
  let h = 2166136261;
  for (let i = 0; i < seed.length; i++) { h ^= seed.charCodeAt(i); h = Math.imul(h, 16777619) >>> 0; }
  return lo + (h % (hi - lo + 1));
}

export const str = (x: unknown): string | undefined => (typeof x === "string" && x.trim() ? x.trim() : undefined);
export const num = (x: unknown): number | undefined => (typeof x === "number" && Number.isFinite(x) ? x : undefined);
export const isPlayer = (p: Person | undefined): p is Player => (p as Player | undefined)?.kind === "player";
export const pro = (p: Person | undefined) => (sexOf(p) === "F" ? "she" : "he");
export const poss = (p: Person | undefined) => (sexOf(p) === "F" ? "her" : "his");
export const obj = (p: Person | undefined) => (sexOf(p) === "F" ? "her" : "him");

/**
 * Fame 0..100 if the life engine tracks it (Person.fame), else a rough stand-in from the
 * career résumé / ratings so prominence still works before the field exists.
 */
export function fameOf(world: World, id: string | undefined): number {
  const p = person(world, id) as (Person & { fame?: unknown; career?: { war?: number; allStars?: number } }) | undefined;
  if (!p) return 0;
  const f = num(p.fame);
  if (f !== undefined) return Math.max(0, Math.min(100, f));
  if (isPlayer(p)) {
    const t = p.teamId ? (world.teams[p.teamId]?.level ?? "D") : "D";
    const best = p.pos === "P" && p.pitching ? (p.pitching.stuff + p.pitching.control) / 2 : (p.batting.contact + p.batting.power) / 2;
    return Math.max(0, Math.min(100, (t === "ML" ? 30 : 5) + (best - 45) * 1.5));
  }
  const role = (p as Npc).role;
  return role === "owner" ? 40 : role === "manager" ? 30 : role === "umpire" ? 15 : 5;
}

/** Front-page weight: base + up to +4 for the most famous person involved. */
export const prominence = (world: World, ids: string[], base = 1) => Math.round((base + Math.max(0, ...ids.map(id => fameOf(world, id))) / 25) * 10) / 10;

/** "found asleep in the bullpen" -> "was found asleep in the bullpen"; active verbs pass through. */
export function wasPhrase(what: string): string {
  return /^(arrested|caught|photographed|booked|sued|found|fined|subject|seen|spotted|charged|cited|named|accused|investigated)\b/.test(what) ? `was ${what}` : what;
}
