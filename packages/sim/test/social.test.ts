import { test } from "node:test";
import assert from "node:assert/strict";
import { generateWorld } from "../src/worldgen.ts";
import { Rng } from "../src/rng.ts";
import {
  TEMPLATES, STATIC_WORDS, SLOT_KINDS, WORDS_VERSION, MAX_COMMENT_CHARS,
  vocabulary, vocabularyVersion, validateComment, renderComment, templateById,
} from "../src/social/comments.ts";
import { checkAccountName, isProfane, isReservedName, normalizeName } from "../src/social/names.ts";

const world = generateWorld("social-test");

// ---------------------------------------------------------------- comments

test("templates: ~70+, unique ids, slots derived from text", () => {
  assert.ok(TEMPLATES.length >= 70, `only ${TEMPLATES.length} templates`);
  assert.equal(new Set(TEMPLATES.map(t => t.id)).size, TEMPLATES.length);
  for (const t of TEMPLATES) {
    const marks = [...t.text.matchAll(/\{([a-z]+)\}/g)].map(m => m[1]);
    assert.deepEqual(t.slots, marks, t.id);
  }
  const kinds = new Set(TEMPLATES.map(t => t.kind));
  for (const k of ["praise", "trash", "rumor", "prophecy", "nostalgia", "conspiracy", "web"]) assert.ok(kinds.has(k as never), k);
  const used = new Set(TEMPLATES.flatMap(t => t.slots));
  for (const k of SLOT_KINDS) assert.ok(used.has(k), `slot ${k} unused`);
  assert.ok(TEMPLATES.some(t => t.text === "first!!!"));
  assert.ok(TEMPLATES.some(t => t.text === "this page rules"));
  assert.ok(TEMPLATES.some(t => t.text.startsWith("bookmarked")));
});

test("static word lists: sized, ASCII, short, unique, clean", () => {
  const big = ["person", "adjective", "noun", "verb", "exclamation", "emote", "item"] as const;
  for (const k of big) assert.ok(STATIC_WORDS[k].length >= 40, `${k}: ${STATIC_WORDS[k].length}`);
  assert.ok(STATIC_WORDS.number.length >= 20);
  assert.ok(STATIC_WORDS.time.length >= 25);
  assert.ok(STATIC_WORDS.place.length >= 30);
  for (const k of SLOT_KINDS) {
    const ws = STATIC_WORDS[k];
    assert.equal(new Set(ws.map(w => w.toLowerCase())).size, ws.length, `dupes in ${k}`);
    for (const w of ws) {
      assert.ok(/^[\x20-\x7e]+$/.test(w), `non-ascii ${w}`);
      assert.ok(w.length <= 28, `too long: ${w}`);
      assert.equal(w, w.trim());
      // (digits skipped: leetspeak makes e.g. "in 1999" look like a slur to the strict name filter)
      if (!/\d/.test(w)) assert.ok(!isProfane(w), `static word trips the name filter: ${w}`);
    }
  }
});

test("vocabulary: static + world words", () => {
  const v = vocabulary(world);
  const p = Object.values(world.players).find(x => x.active)!;
  assert.ok(v.player.includes(`${p.first} ${p.last}`));
  assert.ok(v.team.includes("Lamplighters"));
  const owner = world.npcs[world.factions.hcl.leaderId!];
  assert.ok(v.person.includes(`${owner.first} ${owner.last}`));
  assert.ok(v.person.includes("Hot Dog Hal"));
  assert.ok(v.incident.includes("the bullpen raccoons"));
  assert.ok(v.place.includes("Bellwood Park"));
  for (const k of SLOT_KINDS) assert.ok(v[k].length > 0, k);
  assert.match(WORDS_VERSION, /^[0-9a-f]{8}$/);
  assert.equal(vocabularyVersion(world), vocabularyVersion(generateWorld("social-test")));
  assert.notEqual(vocabularyVersion(world), vocabularyVersion(generateWorld("other")));
});

test("every template fits 120 chars with the longest words", () => {
  const v = vocabulary(world);
  const longest = Object.fromEntries(SLOT_KINDS.map(k => [k, v[k].reduce((a, b) => (b.length > a.length ? b : a), "")]));
  for (const t of TEMPLATES) {
    const text = renderComment(t, t.slots.map(k => longest[k]));
    assert.ok(text.length <= MAX_COMMENT_CHARS, `${t.id} -> ${text.length}: ${text}`);
  }
});

test("validateComment accepts good drafts and renders tidy text", () => {
  const p = Object.values(world.players).find(x => x.active)!;
  const name = `${p.first} ${p.last}`;
  const r = validateComment(world, { template: "praise.01", words: [name, "legendary"] });
  assert.deepEqual(r, { ok: true, text: `${name} is legendary!` });
  // case-insensitive input, canonical output
  const r2 = validateComment(world, { template: "praise.01", words: [name.toUpperCase(), "LEGENDARY"] });
  assert.ok(r2.ok && r2.text === `${name} is legendary!`);
  // a/an agreement and capitalisation
  const r3 = validateComment(world, { template: "trash.05", words: [name, "eel", "a dozen"] });
  assert.ok(r3.ok && r3.text.includes("for an eel and a dozen hot dogs."), JSON.stringify(r3));
  const r4 = validateComment(world, { template: "conspiracy.01", words: ["the blackout"] });
  assert.ok(r4.ok && r4.text === "The blackout was an inside job.");
  const r5 = validateComment(world, { template: "advice.09", words: ["Zoinks", "the brawl"] });
  assert.ok(r5.ok && r5.text === "Zoinks! The brawl again?!", JSON.stringify(r5));
  const r6 = validateComment(world, { template: "web.01", words: [] });
  assert.ok(r6.ok && r6.text === "first!!!");
  const r7 = validateComment(world, { template: "web.08", words: ["lol"] });
  assert.ok(r7.ok && r7.text === "lol lol");
  const r8 = validateComment(world, { template: "web.11", words: ["Not", "lol"] });
  assert.ok(r8.ok && r8.text === "Not!!! lol", JSON.stringify(r8));
});

test("validateComment rejects bad drafts", () => {
  const bad = (d: unknown, why: RegExp, w = world) => {
    const r = validateComment(w, d as never);
    assert.equal(r.ok, false, JSON.stringify(d));
    if (!r.ok) assert.match(r.reason, why);
  };
  bad({ template: "nope.99", words: [] }, /unknown template/);
  bad({ template: "praise.01", words: ["the rookie"] }, /needs 2 words/);
  bad({ template: "praise.01", words: ["the rookie", "clutch", "extra"] }, /needs 2 words/);
  bad({ template: "praise.01", words: ["clutch", "the rookie"] }, /not a player word/);
  bad({ template: "praise.01", words: ["the rookie", "a total idiot"] }, /not a adjective word/);
  bad({ template: "praise.01", words: ["the rookie", 7] }, /not a string/);
  bad({ template: "praise.01", words: ["<script>", "clutch"] }, /not a player/);
  bad({ template: "praise.01" }, /malformed/);
  bad(null, /malformed/);
  // retired/inactive players drop out of the vocabulary
  const w2 = generateWorld("social-test");
  const p = Object.values(w2.players)[0];
  p.active = false;
  w2.day++; // vocabulary cache key
  assert.ok(validateComment(world, { template: "praise.01", words: [`${p.first} ${p.last}`, "clutch"] }).ok);
  bad({ template: "praise.01", words: [`${p.first} ${p.last}`, "clutch"] }, /not a player/, w2);
});

test("random comments always validate and fit", () => {
  const v = vocabulary(world);
  const rng = new Rng("comments");
  for (let i = 0; i < 2000; i++) {
    const t = rng.pick(TEMPLATES);
    const words = t.slots.map(k => rng.pick(v[k]));
    const r = validateComment(world, { template: t.id, words });
    assert.ok(r.ok, `${t.id} ${JSON.stringify(words)} ${JSON.stringify(r)}`);
    if (r.ok) {
      assert.ok(r.text.length <= MAX_COMMENT_CHARS);
      assert.ok(!/\s{2}/.test(r.text) && r.text === r.text.trim());
      assert.ok(!/\ba [aeio]/i.test(r.text.replace(/\ba one\b|\ba eu/gi, "")), r.text);
    }
  }
  assert.equal(templateById("praise.01")?.text, "{player} is {adjective}!");
});

// ---------------------------------------------------------------- names

const GOOD_NAMES = [
  "Scunthorpe", "Dickens Fan", "Assassin", "Raccoon King", "Pizza Pete", "Basemen", "Cocktail Hour", "Therapist",
  "Grapefruit", "Classic Ken", "Spooky Joe", "Japan Fan", "Hancock", "Essex Ace", "Peacock", "Shiitake", "Torpedo",
  "Pass Rusher", "Titanic", "Homer", "Lamplighter4", "Hot Dog Hal", "Mississippi", "Analyst", "Bass Pro",
  "Grasshopper", "Cassidy", "Sussex", "Montenegro", "Cocoon", "Tycoon", "Hitchcock", "Moose_99", "Nick",
  "xX_Slugger_Xx", "Sextant", "Cummings", "Spicer", "Matsushita", "Lucas", "Kasserine", "Glass Joe", "Shuttlecock",
  "Penistone", "Free Zone", "Bunt Lord", "Knuckle Sandwich", "Rally Cap",
  "Lefty", "Gooch Fan", "Pickles", "Swindell", "Sir Hits A Lot", "Mudcat-1999", "Peanut Guy", "The Organist",
  "Bat Dog", "Sinker Sam", "Charlotte", "Matsuda", "Cockburn", "Niigata", "Uranus Gang", "Pimple Popper",
  "Scrapes", "Drapes R Us", "Hello World", "abc", "Big Papi", "A-Rod", "Ruth_Fan_1927", "Seventh Stretch",
];

// ROT13 so the test file doesn't read like a bathroom wall (same reason the blocklist is encoded).
const rot13 = (s: string) => s.replace(/[a-z]/gi, c => String.fromCharCode((c <= "Z" ? 65 : 97) + ((c.toLowerCase().charCodeAt(0) - 97 + 13) % 26)));
const BAD_NAMES = [
  "shpx", "ShPx", "s_h_p_x", "s-h-p-x", "sipx", "cuhpx", "Shhhhpx", "SHPXRE99", "Zbgureshpxre", "fu1g", "5uvg",
  "Fuvvvg", "ohyyfuvg", "n55", "Nff", "Ovt Nff", "ZlNff", "Qhzo_Nff", "Wnpx Nff", "o1gpu", "Ovngpu", "phag",
  "p h a g", "FphagubecrPhag", "piag", "anmv", "a4mv", "Uvgyre", "Urvy", "1488", "Sna 1488", "xxx", "XXX Xyna",
  "Crqb Orne", "Cbea Fgne", "c0ea", "frkl", "Frkl Fnqvr", "kKencrKk", "Encvfg", "fc1p", "Pbba", "Pbbaf", "a1tt3e",
  "avttn", "s4tt0g", "Snt", "Erg4eq", "Ju0er", "Fyhg", "G1gf", "Obbof", "Cravf", "Qvyqb", "Ubeal", "Jnaxre", "Gjng",
  "Onfgneq", "Cvffrq", "Pbpx", "P0px", "Qvpx", "Q1px", "Chffl", "Phz", "Wvmm", "Zvys", "Gubg", "Xvxr", "Puvax",
  "Tbbx", "Jrgonpx", "Genaal", "Qlxr", "Fxnax", "Qbhpur", "XvyyWrjf", "Fvrt Urvy", "Juvgr Cbjre", "Yrfob", "Ubbxre",
  "Cvzc", "Nffubyr", "N55ubyr",
].map(rot13);

test("names: profanity filter blocks obvious and obfuscated words", () => {
  for (const n of BAD_NAMES) {
    const r = checkAccountName(n);
    assert.equal(r.ok, false, `should block "${n}"`);
  }
});

test("names: no false positives on common words that contain bad substrings", () => {
  for (const n of GOOD_NAMES) {
    const r = checkAccountName(n);
    assert.ok(r.ok, `false positive "${n}": ${!r.ok ? r.reason : ""}`);
    if (r.ok) assert.equal(r.name, n);
  }
});

test("names: unicode lookalikes and symbols are normalized", () => {
  assert.equal(normalizeName("Ｆｕｃｋ"), rot13("shpx"));
  assert.equal(normalizeName("F.U.C.K"), rot13("shpx"));
  assert.ok(isProfane("fuсk"));      // Cyrillic с
  assert.ok(isProfane("ѕhit"));      // Cyrillic ѕ
  assert.ok(isProfane("fück"));      // diacritic
  assert.ok(isProfane("A$$hole"));
  assert.ok(isProfane("@ss"));
  assert.ok(isProfane("$h!t"));
  assert.ok(isProfane("b!tch"));
  assert.ok(isProfane("s h i t"));
  assert.ok(isProfane("ph uck"));
  assert.ok(!isProfane("raccoon"));
  assert.ok(!isProfane(""));
  // unicode is rejected by the charset anyway
  assert.equal(checkAccountName("Jósé").ok, false);
});

test("names: shape rules", () => {
  const no = (n: string, why: RegExp) => {
    const r = checkAccountName(n);
    assert.equal(r.ok, false, n);
    if (!r.ok) assert.match(r.reason, why);
  };
  no("ab", /at least 3/);
  no("a".repeat(17), /at most 16/);
  no(" Moose", /start or end/);
  no("Moose ", /start or end/);
  no("Moose  Dunphy", /double spaces/);
  no("Moose!", /letters, digits/);
  no("Moose.Dunphy", /letters, digits/);
  no("Moose\tD", /letters, digits/);
  no("12345", /at least one letter/);
  no("___", /at least one letter/);
  assert.ok(checkAccountName("abc").ok);
  assert.ok(checkAccountName("a".repeat(16)).ok);
  assert.ok(checkAccountName("Moose Dunphy").ok);
  assert.ok(checkAccountName("moose_dunphy-2").ok);
  assert.equal(checkAccountName(42 as unknown as string).ok, false);
});

test("names: reserved and impersonation", () => {
  for (const n of ["Admin", "The Admin", "xAdminx", "Moderator", "Mod", "Bobby", "Bets By Bobby", "SportsWire",
    "System", "Playdate Fan", "Panic", "Anthropic", "Claude", "Commissioner", "The Commish", "DEADBALL", "Sysop",
    "Official Ump", "Webmaster"]) {
    assert.ok(isReservedName(n), n);
    assert.equal(checkAccountName(n).ok, false, n);
  }
  for (const n of ["Modest Mouse", "Bob", "Panicky Pete", "Systematic", "Rootbeer"]) {
    assert.ok(!isReservedName(n), n);
  }
  const p = Object.values(world.players)[0];
  assert.ok(isReservedName(`${p.first} ${p.last}`, world));
  assert.ok(isReservedName(`${p.first}_${p.last}`.toUpperCase(), world));
  assert.ok(!isReservedName(`${p.first} ${p.last}`));          // without a world, only staff names
  assert.ok(!isReservedName("Totally Unique", world));
});

test("names: every blocklist entry (and a leet/stretched/spaced variant) is caught", async () => {
  const { BLOCKLIST_B64 } = await import("../src/social/blocklist.ts");
  const { s, w } = JSON.parse(atob(BLOCKLIST_B64)) as { s: string[]; w: string[] };
  const leet = (x: string) => x.replace(/o/g, "0").replace(/e/g, "3").replace(/a/g, "4");
  for (const x of [...s, ...w]) {
    assert.ok(isProfane(x), `entry ${rot13(x)}`);
    assert.ok(isProfane(x.toUpperCase()), `upper ${rot13(x)}`);
    assert.ok(isProfane(leet(x)), `leet ${rot13(x)}`);
    assert.ok(isProfane(x.split("").join(" ")), `spaced ${rot13(x)}`);
    assert.ok(isProfane(x.replace(/([a-z])/, "$1$1$1")), `stretched ${rot13(x)}`);
  }
});
