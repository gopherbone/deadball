import { test } from "node:test";
import assert from "node:assert/strict";
import { generateWorld } from "../src/worldgen.ts";
import { Rng } from "../src/rng.ts";
import type { World } from "../src/types.ts";
import {
  PACKS, RARITIES, PRINT_RUNS, setFor, extendSet, openPack, cardBack, cardValue, cardFront, setTitle, serialLabel,
  BACK_LINES, BACK_WIDTH, type Card, type CardDef, type Rarity, type MomentInput,
} from "../src/cards/index.ts";

const world = generateWorld("cards-test");

function counter() {
  const n: Record<string, number> = {};
  return (k: string) => (n[k] = (n[k] ?? 0) + 1);
}

test("packs: catalogue and odds", () => {
  const kinds = PACKS.map(p => p.kind);
  assert.deepEqual(kinds.sort(), ["cigar", "scandal", "starter", "wax"]);
  for (const p of PACKS) {
    const sum = RARITIES.reduce((a, r) => a + p.odds[r], 0);
    assert.ok(Math.abs(sum - 1) < 1e-9, `${p.kind} odds sum ${sum}`);
  }
  const wax = PACKS.find(p => p.kind === "wax")!, cigar = PACKS.find(p => p.kind === "cigar")!;
  assert.equal(wax.price, 50); assert.equal(wax.count, 5);
  assert.equal(cigar.price, 250); assert.equal(cigar.count, 10);
  assert.equal(PACKS.find(p => p.kind === "starter")!.price, 0);
  assert.ok(cigar.odds.rare > wax.odds.rare && cigar.odds.original > wax.odds.original);
  assert.equal(setTitle(1).startsWith("Series 1: "), true);
  assert.notEqual(setTitle(1), setTitle(2));
});

test("setFor: deterministic, numbered, covers the league", () => {
  const a = setFor(world, 1), b = setFor(generateWorld("cards-test"), 1);
  assert.deepEqual(a, b);
  assert.equal(new Set(a.map(d => d.id)).size, a.length);
  a.forEach((d, i) => { assert.equal(d.number, i + 1); assert.equal(d.set, "Series 1"); assert.equal(d.rarity, "common"); });
  const ids = new Set(a.map(d => d.personId));
  for (const t of Object.values(world.teams).filter(t => t.level === "ML")) {
    for (const pid of t.roster) if (world.players[pid].active) assert.ok(ids.has(pid), `missing ML player ${pid}`);
    assert.ok(ids.has(t.managerId), "manager");
    assert.ok(ids.has(world.factions[t.factionId].leaderId!), "owner");
  }
  const kinds = new Set(a.map(d => d.kind));
  for (const k of ["player", "prospect", "manager", "umpire", "owner", "figure", "moment"]) assert.ok(kinds.has(k as never), k);
  assert.ok(a.filter(d => d.kind === "umpire").length <= 12);
  assert.ok(a.filter(d => d.kind === "prospect").every(d => world.teams[d.teamId!].level !== "ML"));
});

test("setFor/extendSet: Moments from incidents", () => {
  const p = Object.values(world.players)[3];
  const moments: MomentInput[] = [
    { id: "g12:0", season: 1, day: 12, kind: "RACCOONS_BULLPEN", who: [p.id], teams: ["HCL", "STA"], gameId: "g12", inning: 7 },
    { id: "g30:1", season: 1, day: 30, kind: "BRAWL", who: [p.id], teams: ["HCL"] },
    { id: "old", season: 0, day: 3, kind: "BRAWL" },
  ];
  const set = setFor(world, 1, moments);
  const m = set.filter(d => d.moment && d.moment.sourceId.startsWith("g"));
  assert.equal(m.length, 2);
  assert.equal(m[0].title, "Night of the Raccoons");
  const base = setFor(world, 1);
  const extra = extendSet(world, base, moments);
  assert.equal(extra.length, 2);
  assert.equal(extra[0].number, base.length + 1);
  assert.equal(extendSet(world, [...base, ...extra], moments).length, 0);
  const back = cardBack(world, { ...m[0] });
  assert.ok(back.lines.join(" ").includes("Day 12, inning 7, HCL vs STA."), back.lines.join("|"));
});

test("openPack: deterministic, right size, no dupes in a pack", () => {
  const set = setFor(world, 1);
  for (const pack of PACKS) {
    const a = openPack(world, 1, pack.kind, new Rng("p1"), counter(), set);
    const b = openPack(world, 1, pack.kind, new Rng("p1"), counter(), set);
    assert.deepEqual(a, b, pack.kind);
    assert.equal(a.length, pack.count);
    assert.equal(new Set(a.map(c => c.id)).size, a.length);
  }
  // without a snapshot it builds the set itself
  assert.deepEqual(openPack(world, 1, "wax", new Rng("p2"), counter()), openPack(world, 1, "wax", new Rng("p2"), counter(), set));
  assert.throws(() => openPack(world, 1, "nope", new Rng("x"), counter(), set), /unknown pack/);
});

test("openPack: starter is 8 ML-player commons", () => {
  const cards = openPack(world, 1, "starter", new Rng("s"), counter());
  assert.equal(cards.length, 8);
  for (const c of cards) {
    assert.equal(c.rarity, "common");
    assert.equal(c.kind, "player");
    assert.equal(world.teams[c.teamId!].level, "ML");
  }
});

test("openPack: rarity odds, guarantees, serials", () => {
  const set = setFor(world, 1);
  const mint = counter();
  const counts: Record<Rarity, number> = { common: 0, uncommon: 0, rare: 0, gilded: 0, misprint: 0, original: 0 };
  const rng = new Rng("odds");
  const N = 3000;
  for (let i = 0; i < N; i++) {
    const cards = openPack(world, 1, "cigar", rng, mint, set);
    assert.ok(RARITIES.indexOf(cards[9].rarity) >= RARITIES.indexOf("rare"), "cigar guarantee");
    cards.slice(0, 9).forEach(c => counts[c.rarity]++);
    for (const c of cards) {
      const run = PRINT_RUNS[c.rarity];
      if (run) {
        assert.ok(c.serial! >= 1 && c.serial! <= run && c.printRun === run, JSON.stringify(c));
        assert.ok(serialLabel(c)!.endsWith(`/${run}`));
      } else {
        assert.equal(c.serial, undefined);
      }
      if (c.rarity === "misprint" || c.rarity === "original") assert.ok(c.variant);
      else assert.equal(c.variant, undefined);
    }
  }
  const odds = PACKS.find(p => p.kind === "cigar")!.odds;
  const total = N * 9;
  for (const r of ["common", "uncommon", "rare"] as Rarity[]) {
    const got = counts[r] / total;
    assert.ok(Math.abs(got - odds[r]) < 0.02, `${r}: ${got} vs ${odds[r]}`);
  }
  for (let i = 0; i < 200; i++) {
    const wax = openPack(world, 1, "wax", rng, mint, set);
    assert.notEqual(wax[4].rarity, "common", "wax guarantee");
  }
});

test("openPack: sold-out print runs fall back", () => {
  const soldOut = () => 9999;
  const rng = new Rng("sold");
  for (let i = 0; i < 400; i++) {
    for (const c of openPack(world, 1, "cigar", rng, soldOut)) {
      assert.ok(!PRINT_RUNS[c.rarity], c.rarity);
      assert.equal(c.serial, undefined);
    }
  }
  // Only one Original per card ever exists.
  const mint = counter();
  const seen = new Set<string>();
  const r2 = new Rng("orig");
  for (let i = 0; i < 2000; i++) {
    for (const c of openPack(world, 1, "cigar", r2, mint)) {
      if (c.rarity === "original") { assert.ok(!seen.has(c.id)); seen.add(c.id); assert.equal(c.serial, 1); }
    }
  }
});

test("openPack: Scandal Pack is Moments-heavy", () => {
  const set = setFor(world, 1);
  const rng = new Rng("scandal");
  let moments = 0, total = 0;
  for (let i = 0; i < 300; i++) {
    for (const c of openPack(world, 1, "scandal", rng, counter(), set)) { total++; if (c.kind === "moment") moments++; }
  }
  assert.ok(moments / total > 0.3, `moments ${moments}/${total}`);
});

function checkBack(w: World, c: Card) {
  const b = cardBack(w, c);
  assert.ok(b.lines.length >= 1 && b.lines.length <= BACK_LINES, `${c.id}: ${b.lines.length} lines`);
  for (const l of b.lines) assert.ok(l.length <= BACK_WIDTH, `${c.id}: "${l}" (${l.length})`);
  assert.ok(!b.lines.join(" ").includes("{"), b.lines.join(" "));
  assert.ok(!b.lines.join(" ").includes("undefined"), b.lines.join(" "));
  for (const row of b.stats) for (const cell of row) assert.ok(cell.length <= 7, `cell ${cell}`);
  assert.ok(b.stats.length <= 4);
  return b;
}

test("cardBack: fits the Playdate for every card in the set", () => {
  const set = setFor(world, 1);
  for (const d of set) {
    const b = checkBack(world, { ...d });
    assert.deepEqual(cardBack(world, { ...d }), b, "deterministic");
  }
  // rarities and misprints
  const d = set[0];
  assert.match(cardBack(world, { ...d, rarity: "original", variant: "signed", serial: 1, printRun: 1 }).lines[0], /^1 OF 1/);
  const mp = cardBack(world, { ...d, rarity: "misprint", variant: "raccoon-photobomb", serial: 3, printRun: 25 });
  assert.match(mp.lines.join(" "), /PRINTER'S NOTE/);
  assert.equal(cardBack(world, { ...d, rarity: "misprint", variant: "blank-back" }).stats.length, 0);
});

test("cardBack: uses season stats when present, scouting grades when not", () => {
  const w = generateWorld("cards-test");
  const set = setFor(w, 1);
  const hitterDef = set.find(d => d.kind === "player" && !w.players[d.personId].pitching)!;
  const pitcherDef = set.find(d => d.kind === "player" && !!w.players[d.personId].pitching)!;
  assert.deepEqual(cardBack(w, { ...hitterDef }).stats[0], ["CON", "POW", "EYE", "SPD", "GLV"]);
  const stats = ((w as unknown as { stats: Record<string, Record<number, unknown>> }).stats ??= {});
  stats[hitterDef.personId] = { 1: { teamId: hitterDef.teamId, level: "ML", bat: { g: 150, pa: 640, ab: 560, r: 99, h: 185, d: 30, t: 3, hr: 41, rbi: 120, bb: 60, k: 100, sb: 12, cs: 3, hbp: 2, sf: 4 } } };
  stats[pitcherDef.personId] = { 1: { teamId: pitcherDef.teamId, level: "ML", pitch: { g: 32, gs: 32, w: 19, l: 7, sv: 0, outs: 660, h: 180, r: 70, er: 60, bb: 50, k: 210, hr: 15, hbp: 4, bf: 900, pitches: 3300 } } };
  const hb = checkBack(w, { ...hitterDef });
  assert.deepEqual(hb.stats[0], ["YR", "TM", "AVG", "HR", "RBI", "SB"]);
  assert.deepEqual(hb.stats[1].slice(2), [".330", "41", "120", "12"]);
  assert.match(hb.lines.join(" "), /41 homers in S1/);
  const pb = checkBack(w, { ...pitcherDef });
  assert.deepEqual(pb.stats[1].slice(2), ["19-7", "2.45", "220.0", "210"]);
  // stats raise value
  assert.ok(cardValue(w, { ...hitterDef, rarity: "gilded" }) > cardValue(world, { ...hitterDef, rarity: "gilded" }));
  // works with world.stats missing entirely
  const bare = generateWorld("cards-test") as unknown as { stats?: unknown };
  delete bare.stats;
  checkBack(bare as World, { ...hitterDef });
  assert.ok(Number.isInteger(cardValue(bare as World, { ...hitterDef })));
});

test("cardValue: integer dollars, ordered by rarity and scarcity", () => {
  const set = setFor(world, 1);
  const players = set.filter(d => d.kind === "player");
  for (const d of set) {
    const v = cardValue(world, { ...d });
    assert.ok(Number.isInteger(v) && v >= 1, `${d.id}: ${v}`);
  }
  const d: CardDef = players[0];
  const common = cardValue(world, { ...d, rarity: "common" });
  const rare = cardValue(world, { ...d, rarity: "rare" });
  const gilded2 = cardValue(world, { ...d, rarity: "gilded", serial: 2, printRun: 50 });
  const gilded1 = cardValue(world, { ...d, rarity: "gilded", serial: 1, printRun: 50 });
  const orig = cardValue(world, { ...d, rarity: "original", serial: 1, printRun: 1, variant: "printers-proof" });
  assert.ok(common < rare && rare < gilded2 && gilded2 < gilded1 && gilded1 < orig, [common, rare, gilded2, gilded1, orig].join(","));
  // better players are worth more
  const vals = players.map(p => ({ p: world.players[p.personId], v: cardValue(world, { ...p, rarity: "rare" }) }));
  const ovr = (x: (typeof vals)[number]) => x.p.batting.contact + x.p.batting.power + (x.p.pitching?.stuff ?? 0);
  vals.sort((a, b) => ovr(a) - ovr(b));
  const lo = vals.slice(0, 20).reduce((a, x) => a + x.v, 0), hi = vals.slice(-20).reduce((a, x) => a + x.v, 0);
  assert.ok(hi > lo, `${hi} vs ${lo}`);
});

test("cardFront: vintage caption and misprint errors", () => {
  const set = setFor(world, 1);
  const d = set[0];
  const p = world.players[d.personId];
  const f = cardFront(world, { ...d });
  assert.equal(f.caption, `${p.last.toUpperCase()}, ${world.teams[p.teamId].city.toUpperCase()}`);
  const wrong = cardFront(world, { ...d, rarity: "misprint", variant: "wrong-name", serial: 4, printRun: 25 });
  assert.notEqual(wrong.caption, f.caption);
  assert.equal(wrong.serial, "04/25");
  assert.equal(wrong.misprint, "Wrong Name");
});
