// Redeemable cards: which prints carry an effect, how it reads, and what it's worth.
// The effect itself is applied by sim/src/redeem.

import type { Rng } from "../rng.ts";
import type { World } from "../types.ts";
import { GILDED_BOOST, GILDED_REDEEM_EVERY, ORIGINAL_BOOST, ORIGINAL_RETIRE_SHARE, type Rarity } from "./data.ts";
import { inferKind, isPlayer, overall, type Card, type CardDef, type Redeem } from "./model.ts";

/**
 * The printed effect for a freshly minted card, or undefined. Rules:
 * - Original (1/1) of a player: RETIRE (40%) or BOOST +20 for 15 game days (60%), rolled once at print.
 * - Original of a manager/umpire/owner/figure: RETIRE.
 * - Gilded of a player whose serial is a multiple of 5 (#05, #10 ... #50 of 50): BOOST +12 for 7 game days.
 * - Everything else (and every Moment): not redeemable.
 */
export function redeemFor(world: World, def: CardDef, rarity: Rarity, serial: number | undefined, rng: Rng): Redeem | undefined {
  const kind = inferKind(world, def);
  if (kind === "moment") return undefined;
  const playerCard = kind === "player" || kind === "prospect";
  if (rarity === "original") {
    if (!playerCard) return { kind: "retire" };
    return rng.chance(ORIGINAL_RETIRE_SHARE) ? { kind: "retire" } : { kind: "boost", ...ORIGINAL_BOOST };
  }
  if (rarity === "gilded" && playerCard && serial && serial % GILDED_REDEEM_EVERY === 0) return { kind: "boost", ...GILDED_BOOST };
  return undefined;
}

/** "REDEEMABLE: BOOST +12 FOR 7 DAYS" / "REDEEMABLE: RETIRES PLAYER" (ASCII, fits the card front). */
export function redeemLabel(r: Redeem | undefined, staff = false): string | undefined {
  if (!r) return undefined;
  if (r.kind === "boost") return `REDEEMABLE: BOOST +${r.boost} FOR ${r.days} DAYS`;
  return staff ? "REDEEMABLE: RETIRES SUBJECT" : "REDEEMABLE: RETIRES PLAYER";
}

/** Plain sentence for card backs and bulletins. */
export function redeemText(r: Redeem, hitter: boolean): string {
  if (r.kind === "boost") return `Redeem to give him +${r.boost} ${hitter ? "contact, power and eye" : "stuff and control"} for ${r.days} game days.`;
  return "Redeem to retire him from baseball, permanently.";
}

const clamp = (lo: number, hi: number, x: number) => Math.max(lo, Math.min(hi, x));

/**
 * Dollar value of the printed effect (added to the card's collectible value). Zero once the
 * subject is out of the game. Scales with the subject's quality: juicing or retiring a star
 * matters more than a scrub.
 *   Gilded BOOST  ~ $200 – $1,600   Original BOOST ~ $600 – $4,800   RETIRE ~ $1,250 – $10,000
 */
export function redeemValue(world: World, card: Card): number {
  const r = card.redeem;
  if (!r) return 0;
  const p = world.players[card.personId];
  const npc = world.npcs[card.personId];
  if (r.kind === "boost") {
    if (!p || !p.active) return 0;
    const q = Math.max(overall(p), p.potential - 6);
    const base = card.rarity === "original" ? 1200 : 400;
    return Math.round(base * clamp(0.5, 4, Math.pow(2, (q - 50) / 10)) * (r.boost / (card.rarity === "original" ? 20 : 12)) * (r.days / (card.rarity === "original" ? 15 : 7)));
  }
  if (isPlayer(p) && p.active) return Math.round(2500 * clamp(0.5, 4, Math.pow(2, (overall(p) - 50) / 10)));
  if (npc && npc.active && !npc.dead) return 1500;
  return 0;
}
