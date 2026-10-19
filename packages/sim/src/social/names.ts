// Account names: the only free text in the game, so the filter is strict.
//
// Pipeline: charset/shape rules → normalize (unicode fold, lookalikes, lowercase, strip
// separators) → regex match against an encoded blocklist where every letter also accepts
// its leetspeak forms and any run of repeats ("fuuuuck", "a$$") → known-safe words that
// happen to contain a blocked substring (Scunthorpe, Dickens, assassin) are exempted.

import type { World } from "../types.ts";
import { BLOCKLIST_B64 } from "./blocklist.ts";

export const NAME_MIN = 3;
export const NAME_MAX = 16;

// Words that contain a blocked substring but are fine. Normalized (lowercase, no spaces).
export const ALLOWLIST: readonly string[] = [
  "scunthorpe", "dickens", "dickinson", "dickey", "dickson", "dickerson", "benedick", "assassin", "assist", "passion",
  "classic", "class", "bass", "grass", "brass", "glass", "mass", "pass", "sass", "lass", "embassy", "cassidy",
  "peacock", "cocktail", "cockpit", "hancock", "babcock", "cockroach", "shuttlecock", "cockatoo", "cocker", "woodcock",
  "gamecock", "hitchcock", "cockney", "cockle", "cockburn", "cockerel", "pimple", "pimpernel", "montenegro",
  "negroni", "janus", "manus", "uranus", "anushka", "grape", "drape", "scrape", "trapeze", "rapeseed", "therapist",
  "torpedo", "pedometer", "sexton", "sussex", "essex", "middlesex", "sextant", "sextet", "pissarro", "retardant",
  "swank", "thorny", "semenov", "semenya", "cummings", "cummins", "shiitake", "shitake", "penistone", "snigger",
  "niggle", "niggling", "vandyke", "fukuoka", "fukuda", "fukushima", "nazir", "booboo", "analyst", "canal",
  "banal", "titan", "matsushita", "kishita", "hoboken", "cockrell", "spicer", "dickel", "bastardo",
  "raccoon", "tycoon", "cocoon", "niigata", "nightwatch", "atwater", "outwatch",
];

// Reserved: staff / brand / in-world institutions. Substrings are blocked anywhere;
// tokens only when they are a whole word of the name.
const RESERVED_SUBSTRINGS = [
  "admin", "moderator", "commissioner", "commish", "sportswire", "sysop", "playdate", "anthropic", "claude",
  "deadball", "betsbybobby", "webmaster", "official",
];
const RESERVED_TOKENS = ["mod", "mods", "bobby", "system", "panic", "staff", "support", "root", "server", "gm", "dev", "ump", "umpire"];

let decoded: { s: string[]; w: string[] } | null = null;
function blocklist(): { s: string[]; w: string[] } {
  if (!decoded) decoded = JSON.parse(atob(BLOCKLIST_B64)) as { s: string[]; w: string[] };
  return decoded;
}

// Unicode lookalikes (Cyrillic, Greek, a few symbols) → Latin. Applied after NFKD, which
// already folds fullwidth letters and strips most accents.
const LOOKALIKES: Record<string, string> = {
  "а": "a", "в": "b", "с": "c", "е": "e", "ё": "e", "һ": "h", "і": "i", "ї": "i", "ј": "j", "к": "k", "м": "m",
  "н": "h", "о": "o", "р": "p", "ѕ": "s", "т": "t", "у": "y", "х": "x", "ԁ": "d", "ɡ": "g", "ո": "n", "ս": "u",
  "α": "a", "β": "b", "ε": "e", "η": "n", "ι": "i", "κ": "k", "ν": "v", "ο": "o", "ρ": "p", "τ": "t", "υ": "u",
  "χ": "x", "ω": "w", "ß": "ss", "æ": "ae", "œ": "oe", "ø": "o", "đ": "d", "ł": "l", "ı": "i", "ŀ": "l",
  "¡": "i", "€": "e", "£": "l", "¢": "c", "¥": "y", "©": "c", "®": "r", "µ": "u",
};

/** Lowercase, fold unicode and lookalikes, and strip separators. Leet digits/symbols are kept. */
export function normalizeName(s: string): string {
  let out = "";
  for (const ch of s.normalize("NFKD").replace(/[̀-ͯ]/g, "").toLowerCase()) {
    const c = LOOKALIKES[ch] ?? ch;
    if (/^[a-z0-9@$!|+(<]+$/.test(c)) out += c;
  }
  return out;
}

// Each letter also matches its leetspeak forms. Digits like 1 are ambiguous (i or l), so
// both letters accept them.
const LEET: Record<string, string> = {
  a: "a4@", b: "b8", c: "c(<k", e: "e3", g: "g96", i: "i1!|", l: "l1|", o: "o0", s: "s5$", t: "t7+", z: "z2",
  u: "uv", k: "kq",
};
const esc = (c: string) => c.replace(/[\\\]^-]/g, "\\$&");

function wordPattern(w: string): string {
  let p = "";
  for (let i = 0; i < w.length;) {
    let j = i;
    while (j < w.length && w[j] === w[i]) j++;
    const c = w[i], n = j - i;
    const cls = c === "f" ? "(?:f|ph)" : `[${esc(LEET[c] ?? c)}]`;
    p += n === 1 ? `${cls}+` : `${cls}{${n},}`;
    i = j;
  }
  return p;
}

let compiled: { sub: RegExp[]; word: RegExp[]; allow: RegExp[] } | null = null;
function patterns() {
  if (!compiled) {
    const bl = blocklist();
    compiled = {
      sub: bl.s.map(w => new RegExp(wordPattern(w), "g")),
      word: bl.w.map(w => new RegExp(`^${wordPattern(w)}(?:[s5$z]|e[s5$z])?$`)),
      allow: ALLOWLIST.map(w => new RegExp(wordPattern(w), "g")),
    };
  }
  return compiled;
}

function spans(re: RegExp, s: string): [number, number][] {
  const out: [number, number][] = [];
  re.lastIndex = 0;
  for (let m = re.exec(s); m; m = re.exec(s)) {
    out.push([m.index, m.index + m[0].length]);
    re.lastIndex = m.index + 1; // allow overlaps
  }
  return out;
}

/** Split into tokens on separators, camelCase humps and letter/digit-free boundaries. */
function tokens(raw: string): string[] {
  return raw
    .replace(/([a-z])([A-Z])/g, "$1 $2")
    .split(/[\s_\-.,]+/)
    .map(normalizeName)
    .filter(Boolean);
}

/** True if `s` (any text) contains blocked language. Exposed for reuse and tests. */
export function isProfane(raw: string): boolean {
  const s = normalizeName(raw);
  if (!s) return false;
  if (/1488/.test(raw.replace(/\D/g, ""))) return true; // hate-group numerology
  const { sub, word, allow } = patterns();
  const safe: [number, number][] = [];
  for (const re of allow) safe.push(...spans(re, s));
  for (const re of sub) {
    for (const [a, b] of spans(re, s)) {
      if (!safe.some(([x, y]) => x <= a && b <= y)) return true;
    }
  }
  const toks = tokens(raw);
  for (const t of [...toks, s]) {
    if (ALLOWLIST.includes(t)) continue;
    for (const re of word) if (re.test(t)) return true;
  }
  return false;
}

/** Staff/brand/institution names, plus (optionally) exact names of people in the world. */
export function isReservedName(name: string, world?: World): boolean {
  const s = normalizeName(name);
  if (RESERVED_SUBSTRINGS.some(r => s.includes(r))) return true;
  const toks = tokens(name);
  if (toks.some(t => RESERVED_TOKENS.includes(t))) return true;
  if (RESERVED_TOKENS.includes(s)) return true;
  if (world) {
    const people = [...Object.values(world.players), ...Object.values(world.npcs)];
    for (const p of people) {
      if (normalizeName(`${p.first}${p.last}`) === s) return true;
      if (p.nickname && normalizeName(`${p.nickname}${p.last}`) === s) return true;
    }
  }
  return false;
}

export function checkAccountName(name: string): { ok: true; name: string } | { ok: false; reason: string } {
  if (typeof name !== "string") return { ok: false, reason: "Name must be text." };
  if (name.length < NAME_MIN) return { ok: false, reason: `Name must be at least ${NAME_MIN} characters.` };
  if (name.length > NAME_MAX) return { ok: false, reason: `Name must be at most ${NAME_MAX} characters.` };
  // ASCII only: the Playdate fonts don't carry much beyond it, and it shuts out lookalike tricks.
  if (!/^[A-Za-z0-9 _-]+$/.test(name)) return { ok: false, reason: "Use letters, digits, spaces, _ or - only." };
  if (name !== name.trim()) return { ok: false, reason: "No spaces at the start or end." };
  if (name.includes("  ")) return { ok: false, reason: "No double spaces." };
  if (!/[A-Za-z]/.test(name)) return { ok: false, reason: "Name needs at least one letter." };
  if (isProfane(name)) return { ok: false, reason: "That name isn't allowed." };
  if (isReservedName(name)) return { ok: false, reason: "That name is reserved." };
  return { ok: true, name };
}
