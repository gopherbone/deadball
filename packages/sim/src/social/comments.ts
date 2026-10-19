// Mad-libs comments: a template plus words from curated lists and the live world.
// The server validates drafts with `validateComment`; the client fetches templates and
// the vocabulary (GET /v1/words) and caches the static part by `WORDS_VERSION`.

import type { World } from "../types.ts";
import { INCIDENTS } from "../incidents.ts";
import {
  INCIDENT_PHRASES, SLOT_KINDS, STATIC_WORDS, TEMPLATE_TEXT,
  type SlotKind, type TemplateKind,
} from "./words.ts";

export { SLOT_KINDS, STATIC_WORDS, type SlotKind, type TemplateKind } from "./words.ts";

export interface CommentTemplate {
  id: string;
  text: string; // "{player} is {adjective}!"
  slots: SlotKind[];
  kind: TemplateKind;
}

export interface CommentDraft {
  template: string;
  words: string[];
}

export const MAX_COMMENT_CHARS = 120;

const SLOT_RE = /\{([a-z]+)\}/g;

function slotsOf(text: string): SlotKind[] {
  const out: SlotKind[] = [];
  for (const m of text.matchAll(SLOT_RE)) {
    const k = m[1] as SlotKind;
    if (!SLOT_KINDS.includes(k)) throw new Error(`template "${text}" has unknown slot {${k}}`);
    out.push(k);
  }
  return out;
}

export const TEMPLATES: CommentTemplate[] = (Object.keys(TEMPLATE_TEXT) as TemplateKind[]).flatMap(kind =>
  TEMPLATE_TEXT[kind].map((text, i) => ({
    id: `${kind}.${String(i + 1).padStart(2, "0")}`, text, slots: slotsOf(text), kind,
  })),
);

const TEMPLATE_BY_ID = new Map(TEMPLATES.map(t => [t.id, t]));

export function templateById(id: string): CommentTemplate | undefined {
  return TEMPLATE_BY_ID.get(id);
}

/** FNV-1a 32-bit, hex. Deterministic and cheap; used for cache versions. */
export function hashString(s: string): string {
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return (h >>> 0).toString(16).padStart(8, "0");
}

/** Version of the static part (templates + STATIC_WORDS). Bump-free: changes when content does. */
export const WORDS_VERSION: string = hashString(JSON.stringify([TEMPLATES, STATIC_WORDS]));

export function incidentPhrase(kind: string): string {
  return INCIDENT_PHRASES[kind] ?? `the ${kind.toLowerCase().replace(/_/g, " ")}`;
}

const personName = (p: { first: string; last: string }) => `${p.first} ${p.last}`;

/** Only the world-derived words (players, notable people, teams, parks, incidents). */
export function worldWords(world: World): Partial<Record<SlotKind, string[]>> {
  const players: string[] = [];
  for (const p of Object.values(world.players)) if (p.active && !p.dead) players.push(personName(p));
  const notable = new Set(["owner", "manager", "umpire", "fixer", "reporter", "official"]);
  const people: string[] = [];
  for (const n of Object.values(world.npcs)) if (n.active && !n.dead && notable.has(n.role)) people.push(personName(n));
  const teams = Object.values(world.teams).map(t => t.name);
  const places = Object.values(world.parks).map(p => p.name);
  const incidents = Object.keys(INCIDENTS).map(incidentPhrase);
  return { player: players, person: people, team: teams, place: places, incident: incidents };
}

function uniq(xs: string[]): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const x of xs) {
    const k = x.toLowerCase();
    if (!seen.has(k)) { seen.add(k); out.push(x); }
  }
  return out;
}

/** Static words + world words, de-duplicated (case-insensitive), static first. */
export function vocabulary(world: World): Record<SlotKind, string[]> {
  const ww = worldWords(world);
  const out = {} as Record<SlotKind, string[]>;
  for (const k of SLOT_KINDS) out[k] = uniq([...STATIC_WORDS[k], ...(ww[k] ?? [])]);
  return out;
}

/** Version string for the full vocabulary (static + world words). */
export function vocabularyVersion(world: World): string {
  return hashString(WORDS_VERSION + JSON.stringify(worldWords(world)));
}

// Cache lowercase→canonical lookups per world object; rebuilt when the roster changes
// shape (cheap fingerprint: counts + day).
const lookupCache = new WeakMap<World, { key: string; map: Map<SlotKind, Map<string, string>> }>();

function lookups(world: World): Map<SlotKind, Map<string, string>> {
  const key = `${world.season}:${world.day}:${Object.keys(world.players).length}:${Object.keys(world.npcs).length}`;
  const hit = lookupCache.get(world);
  if (hit && hit.key === key) return hit.map;
  const vocab = vocabulary(world);
  const map = new Map<SlotKind, Map<string, string>>();
  for (const k of SLOT_KINDS) map.set(k, new Map(vocab[k].map(w => [w.toLowerCase(), w])));
  lookupCache.set(world, { key, map });
  return map;
}

const VOWEL_SOUND = /^(?:[aeiou]|8|11|18|hour|honest|heir|X)/i;
const CONSONANT_SOUND_EXCEPTIONS = /^(?:uni|use|usu|uto|one|once|eu|ur[aio])/i;

function article(next: string): "a" | "an" {
  if (CONSONANT_SOUND_EXCEPTIONS.test(next)) return "a";
  return VOWEL_SOUND.test(next) ? "an" : "a";
}

const LOWERCASE_OK = new Set(["lol", "rofl", "haha", "hehe", "brb", "afk", "w00t", "o_O"]);

/** Fill a template with words and tidy spacing, articles, capitalization and the ending. */
export function renderComment(template: CommentTemplate | string, words: string[]): string {
  const text = typeof template === "string" ? template : template.text;
  let i = 0;
  let s = text.replace(SLOT_RE, () => words[i++] ?? "");
  // a/an agreement ("a eel" -> "an eel")
  s = s.replace(/\b([Aa])(n?) (?=(\S+))/g, (m, a: string, _n: string, next: string) => {
    if (!/^[A-Za-z0-9]/.test(next)) return m;
    const art = article(next);
    return (a === "A" ? art[0].toUpperCase() + art.slice(1) : art) + " ";
  });
  s = s.replace(/\s+/g, " ").trim();
  s = s.replace(/ +([,.;:?!])(?=\s|$)/g, "$1");     // no space before punctuation
  s = s.replace(/([!?])\.(?=\s|$)/g, "$1");          // "Not!." -> "Not!"
  s = s.replace(/(?<!\.)\.\.(?!\.)/g, ".");          // ".." -> "." but keep "..."
  // Templates that open with a slot get a capital; literal openers ("first!!!", "lol") keep their style.
  if (text.startsWith("{") && /^[a-z]/.test(s)) s = s[0].toUpperCase() + s.slice(1);
  // New sentence after a slot-filled exclamation etc. ("Zoinks! the blackout" -> "Zoinks! The blackout"),
  // but chat-speak stays lowercase ("Whoa!!! lol").
  s = s.replace(/([.!?] )([a-z])(\w*)/g, (m, pre: string, c: string, rest: string) =>
    LOWERCASE_OK.has(c + rest) ? m : pre + c.toUpperCase() + rest);
  return s;
}

export function validateComment(world: World, d: CommentDraft): { ok: true; text: string } | { ok: false; reason: string } {
  if (!d || typeof d.template !== "string" || !Array.isArray(d.words)) return { ok: false, reason: "malformed draft" };
  const t = TEMPLATE_BY_ID.get(d.template);
  if (!t) return { ok: false, reason: `unknown template "${String(d.template).slice(0, 40)}"` };
  if (d.words.length !== t.slots.length) {
    return { ok: false, reason: `template ${t.id} needs ${t.slots.length} words, got ${d.words.length}` };
  }
  const look = lookups(world);
  const canonical: string[] = [];
  for (let i = 0; i < t.slots.length; i++) {
    const w = d.words[i];
    const kind = t.slots[i];
    if (typeof w !== "string") return { ok: false, reason: `word ${i + 1} is not a string` };
    const c = look.get(kind)!.get(w.trim().toLowerCase());
    if (c === undefined) return { ok: false, reason: `"${w.slice(0, 40)}" is not a ${kind} word` };
    canonical.push(c);
  }
  const text = renderComment(t, canonical);
  if (text.length > MAX_COMMENT_CHARS) return { ok: false, reason: `comment too long (${text.length} > ${MAX_COMMENT_CHARS})` };
  return { ok: true, text };
}
