import { test } from "node:test";
import assert from "node:assert/strict";
import { generateWorld } from "../src/worldgen.ts";
import { Rng } from "../src/rng.ts";
import { simulateGame } from "../src/game.ts";
import type { World } from "../src/types.ts";
import { setFor, openPack, cardBack, cardFront, cardValue, redeemFor, redeemValue, type Card, type CardDef } from "../src/cards/index.ts";
import { rosterProblems } from "../src/life/roster.ts";
import { HEADLINE_MAX, DEK_MAX } from "../src/news/types.ts";
import { performRedeem, checkRedeem, redeemModifiers, type RedeemResult } from "../src/redeem/index.ts";

const mlPlayers = (w: World) => Object.values(w.players).filter(p => p.active && w.teams[p.teamId]?.level === "ML");
const defOf = (w: World, pid: string) => setFor(w, 1).find(d => d.personId === pid)!;
const boostCard = (d: CardDef, boost = 12, days = 7): Card => ({ ...d, rarity: "gilded", serial: 5, printRun: 50, redeem: { kind: "boost", boost, days } });
const retireCard = (d: CardDef): Card => ({ ...d, rarity: "original", serial: 1, printRun: 1, variant: "signed", redeem: { kind: "retire" } });
function ok(r: ReturnType<typeof performRedeem>): RedeemResult {
  assert.ok(r.ok, JSON.stringify(r));
  return r as RedeemResult;
}

test("which prints are redeemable", () => {
  const w = generateWorld("rd-which");
  const set = setFor(w, 1);
  const player = set.find(d => d.kind === "player")!;
  const ump = set.find(d => d.kind === "umpire")!;
  const moment = set.find(d => d.kind === "moment")!;
  const rng = new Rng("x");
  for (let s = 1; s <= 50; s++) {
    const r = redeemFor(w, player, "gilded", s, rng);
    if (s % 5 === 0) assert.deepEqual(r, { kind: "boost", boost: 12, days: 7 });
    else assert.equal(r, undefined);
  }
  assert.equal(redeemFor(w, ump, "gilded", 10, rng), undefined);
  assert.deepEqual(redeemFor(w, ump, "original", 1, rng), { kind: "retire" });
  assert.equal(redeemFor(w, moment, "original", 1, rng), undefined);
  for (const r of ["common", "uncommon", "rare", "misprint"] as const) assert.equal(redeemFor(w, player, r, 5, rng), undefined);
  let retire = 0, boost = 0;
  for (let i = 0; i < 400; i++) {
    const r = redeemFor(w, player, "original", 1, rng)!;
    if (r.kind === "retire") retire++; else { boost++; assert.deepEqual(r, { kind: "boost", boost: 20, days: 15 }); }
  }
  assert.ok(retire > 120 && retire < 200, `${retire} retire / ${boost} boost`);
  // packs print it on the card, and Gilded prints #5, #10... carry it
  const mint: Record<string, number> = {};
  let seen = 0;
  for (let i = 0; i < 300; i++) {
    for (const c of openPack(w, 1, "cigar", new Rng(`p${i}`), k => (mint[k] = (mint[k] ?? 0) + 1), set)) {
      if (c.rarity === "gilded" && c.kind === "player") assert.equal(!!c.redeem, c.serial! % 5 === 0);
      if (c.rarity === "original" && c.kind !== "moment") assert.ok(c.redeem);
      if (c.redeem) seen++;
      if (!["gilded", "original"].includes(c.rarity)) assert.equal(c.redeem, undefined);
    }
  }
  assert.ok(seen > 0);
});

test("front, back and value show the effect", () => {
  const w = generateWorld("rd-show");
  const star = [...mlPlayers(w)].sort((a, b) => b.batting.power + b.batting.contact - a.batting.power - a.batting.contact)[0];
  const scrub = [...mlPlayers(w)].filter(p => !p.pitching).sort((a, b) => a.batting.power + a.batting.contact - b.batting.power - b.batting.contact)[0];
  const c = boostCard(defOf(w, star.id));
  assert.equal(cardFront(w, c).redeem, "REDEEMABLE: BOOST +12 FOR 7 DAYS");
  assert.equal(cardFront(w, retireCard(defOf(w, star.id))).redeem, "REDEEMABLE: RETIRES PLAYER");
  const back = cardBack(w, c);
  assert.ok(back.lines.length <= 6 && back.lines.every(l => l.length <= 40));
  assert.match(back.lines.join(" "), /REDEEM: \+12 .* FOR 7 GAME DAYS/);
  const plain: Card = { ...c, redeem: undefined };
  assert.ok(cardValue(w, c) >= cardValue(w, plain) + 200, `${cardValue(w, c)} vs ${cardValue(w, plain)}`);
  const retireStar = cardValue(w, retireCard(defOf(w, star.id)));
  const retireScrub = cardValue(w, retireCard(defOf(w, scrub.id)));
  const boostOrig = cardValue(w, { ...retireCard(defOf(w, star.id)), redeem: { kind: "boost", boost: 20, days: 15 } });
  assert.ok(retireStar > retireScrub, `${retireStar} vs ${retireScrub}`);
  assert.ok(retireStar > boostOrig, `retire ${retireStar} vs boost ${boostOrig}`);
  assert.ok(retireScrub >= 1250 && retireStar <= 20000);
  assert.ok(redeemValue(w, c) >= 200 && redeemValue(w, c) <= 1600);
});

test("boost: exact, deterministic, stacking halves, injected by team and day", () => {
  const run = (stack = 0) => {
    const w = generateWorld("rd-boost");
    const p = mlPlayers(w).find(x => !x.pitching)!;
    return { w, p, r: ok(performRedeem(w, boostCard(defOf(w, p.id)), new Rng("b"), { stack, redeemer: "Lefty Loot" })) };
  };
  const { w, p, r } = run();
  assert.deepEqual(r, run().r);
  assert.equal(r.kind, "boost");
  assert.equal(r.boost, 12);
  const m = r.mods[0];
  assert.equal(m.untilDay - m.fromDay + 1, 7);
  assert.deepEqual(m.modifiers.map(x => x.effect).sort(), ["contact", "eye", "power"]);
  assert.ok(m.modifiers.every(x => x.value === 12));
  assert.equal(redeemModifiers(w, r.mods, [p.teamId]).length, 3);
  assert.equal(redeemModifiers(w, r.mods, ["NOPE"]).length, 0);
  assert.equal(redeemModifiers(w, r.mods, [p.teamId], m.untilDay + 1).length, 0);
  assert.equal(run(1).r.boost, 6);
  assert.equal(run(2).r.boost, 3);
  // the bulletin is plain and names the redeemer
  assert.equal(r.story.kind, "brief");
  assert.equal(r.story.section, "Bulletin");
  assert.ok(r.story.headline.startsWith("Card Redeemed:") || r.story.headline.startsWith("Redeemed:"), r.story.headline);
  assert.ok(r.story.headline.length <= HEADLINE_MAX && r.story.dek.length <= DEK_MAX);
  assert.match(r.story.body.join(" "), /Lefty Loot redeemed/);
  // the sim runs with it
  const ump = Object.values(w.npcs).find(n => n.role === "umpire")!;
  const opp = Object.values(w.teams).find(t => t.level === "ML" && t.id !== p.teamId)!;
  const res = simulateGame(w, { id: "g", day: 1, homeId: p.teamId, awayId: opp.id, umpireId: ump.id, weather: { tempF: 72, windDir: 0, windMph: 0, rain: 0 }, modifiers: redeemModifiers(w, r.mods, [p.teamId, opp.id]) }, "s");
  assert.ok(res.home.runs >= 0);
});

test("retire: player leaves, roster refills, bulletin explains", () => {
  const w = generateWorld("rd-retire");
  const p = mlPlayers(w)[5];
  const team = w.teams[p.teamId];
  const r = ok(performRedeem(w, retireCard(defOf(w, p.id)), new Rng("r"), { redeemer: "Dotty Dial" }));
  assert.equal(r.kind, "retire");
  assert.equal(w.players[p.id], undefined);
  assert.ok(!team.roster.includes(p.id));
  assert.deepEqual(rosterProblems(w), []);
  assert.ok(r.life.some(e => e.kind === "retirement" && e.who.includes(p.id)));
  assert.equal(r.story.headline, `Card Redeemed: ${p.last} Retired`.length <= HEADLINE_MAX ? `Card Redeemed: ${p.last} Retired` : r.story.headline);
  assert.match(r.story.body.join(" "), /retired from baseball/);
  assert.match(r.story.body.join(" "), /Final Season/);
  // no second redemption, and the leftover cards are Final Season collectibles
  assert.equal(checkRedeem(w, retireCard(defOf(generateWorld("rd-retire"), p.id))).ok, false);
  const leftover: Card = { ...defOf(generateWorld("rd-retire"), p.id), rarity: "rare", finalSeason: true };
  assert.match(cardBack(w, leftover).lines[0], /^FINAL SEASON/);
  assert.equal(cardFront(w, leftover).finalSeason, true);
  assert.ok(cardValue(w, leftover) > cardValue(w, { ...leftover, finalSeason: false }));
});

test("retire: staff are replaced", () => {
  const w = generateWorld("rd-staff");
  const mgr = setFor(w, 1).find(d => d.kind === "manager")!;
  const team = w.teams[mgr.teamId!];
  ok(performRedeem(w, retireCard(mgr), new Rng("m")));
  assert.ok(!w.npcs[mgr.personId]);
  assert.ok(w.npcs[team.managerId] && team.managerId !== mgr.personId);
});

test("refusals: not redeemable, subject gone", () => {
  const w = generateWorld("rd-no");
  const p = mlPlayers(w)[0];
  const d = defOf(w, p.id);
  assert.equal(performRedeem(w, { ...d, rarity: "original" }, new Rng("n")).ok, false);
  assert.equal(performRedeem(w, { ...d, rarity: "rare" }, new Rng("n")).ok, false);
  ok(performRedeem(w, retireCard(d), new Rng("n")));
  assert.equal(performRedeem(w, boostCard(d), new Rng("n")).ok, false);
});
