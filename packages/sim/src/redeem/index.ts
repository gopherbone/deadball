// Redeemable cards: a scarce subset of prints carries an effect (see cards/redeem.ts).
// Redeeming uses the card up and applies the printed effect to the sim, deterministically:
//   BOOST  +N to the player's key ratings for D game days (stacking halves each extra one)
//   RETIRE the subject retires from baseball now (life-module helpers; rosters/jobs refill)
// Nothing else happens to the redeemer. Every redemption is announced in a league bulletin.

import type { Rng } from "../rng.ts";
import type { Npc, Player, World } from "../types.ts";
import type { Modifier, Effect } from "../modifiers.ts";
import type { Card } from "../cards/model.ts";
import type { LifeEvent } from "../life/events.ts";
import { archivePerson } from "../life/people.ts";
import { balanceOrg, orgId } from "../life/roster.ts";
import { replaceRole } from "../life/family.ts";
import { retirePlayer } from "../life/offseason.ts";
import { writeRedeemBulletin } from "./bulletin.ts";
import type { Story } from "../news/types.ts";

export { writeRedeemBulletin } from "./bulletin.ts";

/** A second (third...) boost on the same player while one is active is worth this fraction. */
export const BOOST_STACK_DECAY = 0.5;

/** Modifiers the server injects into GameSpecs while world.day is in [fromDay, untilDay]. */
export interface RedeemMods {
  id: string;
  redemptionId: string;
  personId: string;
  fromDay: number;
  /** Inclusive. */
  untilDay: number;
  modifiers: Modifier[];
}

export interface RedeemResult {
  ok: true;
  id: string;
  kind: "boost" | "retire";
  personId: string;
  /** Club(s) affected: for bulletins and mail. */
  teamIds: string[];
  /** Effective boost after stacking (boost only). */
  boost?: number;
  days?: number;
  fromDay?: number;
  untilDay?: number;
  /** Plain one-liner for the API. */
  summary: string;
  mods: RedeemMods[];
  life: LifeEvent[];
  /** The public league bulletin (Story kind "brief", section "Bulletin"). */
  story: Story;
}

export type RedeemRefusal = { ok: false; reason: string };

export interface RedeemOpts {
  /** Redemption id (defaults to `rd-<card id>`). */
  id?: string;
  /** Boosts already active on this player. */
  stack?: number;
  /** Display name of the redeeming account, for the bulletin. */
  redeemer?: string;
}

export function boostEffects(p: Player): Effect[] {
  return p.pitching ? ["stuff", "control"] : ["contact", "power", "eye"];
}

export function checkRedeem(world: World, card: Card): { ok: true } | RedeemRefusal {
  const r = card.redeem;
  if (!r) return { ok: false, reason: "This card isn't redeemable." };
  if (r.kind === "boost") {
    const p = world.players[card.personId];
    if (!p || !p.active) return { ok: false, reason: "That player is no longer in the game." };
    return { ok: true };
  }
  const p = (world.players[card.personId] ?? world.npcs[card.personId]) as Player | Npc | undefined;
  if (!p || !p.active || p.dead) return { ok: false, reason: "That person is no longer in the game." };
  return { ok: true };
}

/** Apply a redeemable card's printed effect. Mutates the World on success. */
export function performRedeem(world: World, card: Card, rng: Rng, o: RedeemOpts = {}): RedeemResult | RedeemRefusal {
  const ok = checkRedeem(world, card);
  if (!ok.ok) return ok;
  const id = o.id ?? `rd-${card.id}${card.serial ? `-${card.serial}` : ""}`;
  const r = card.redeem!;
  const base = { ok: true as const, id, personId: card.personId, mods: [] as RedeemMods[], life: [] as LifeEvent[] };
  let res: RedeemResult;
  if (r.kind === "boost") {
    const p = world.players[card.personId];
    const boost = Math.max(1, Math.round(r.boost * Math.pow(BOOST_STACK_DECAY, o.stack ?? 0)));
    const fromDay = world.day, untilDay = world.day + r.days - 1;
    const modifiers: Modifier[] = boostEffects(p).map(effect => ({
      id: `rd:${id}:${effect}`, source: `redeem:${id}`, target: { kind: "player", id: p.id }, effect, value: boost, note: "redeemed card",
    }));
    const what = p.pitching ? "stuff and control" : "contact, power and eye";
    res = {
      ...base, kind: "boost", teamIds: [p.teamId], boost, days: r.days, fromDay, untilDay,
      mods: [{ id: `rd:${id}`, redemptionId: id, personId: p.id, fromDay, untilDay, modifiers }],
      summary: `Redeemed. ${p.first} ${p.last} gets +${boost} ${what} for ${r.days} game days (through day ${untilDay}).`,
      story: undefined as unknown as Story,
    };
  } else {
    const p = (world.players[card.personId] ?? world.npcs[card.personId]) as Player | Npc;
    const life: LifeEvent[] = [];
    let teamIds: string[] = [];
    if (p.kind === "player") {
      const team = world.teams[p.teamId];
      teamIds = team ? [team.id] : [];
      retirePlayer(world, rng, p, life, "retired (card redeemed)");
      if (team) balanceOrg(world, orgId(team), rng, life, { reason: "retirement" });
    } else {
      const t = Object.values(world.teams).find(x => x.managerId === p.id);
      if (t) teamIds = [t.id];
      archivePerson(world, p.id, "moved");
      replaceRole(world, rng, p, life);
    }
    res = {
      ...base, kind: "retire", teamIds, life,
      summary: `Redeemed. ${p.first} ${p.last} has retired from baseball.`,
      story: undefined as unknown as Story,
    };
  }
  res.story = writeRedeemBulletin(world, res, card, o.redeemer);
  return res;
}

/** Modifiers from active redemptions that apply to a game between these teams on `day`. */
export function redeemModifiers(world: World, active: RedeemMods[], teamIds: string[], day = world.day): Modifier[] {
  const out: Modifier[] = [];
  for (const r of active) {
    if (day < r.fromDay || day > r.untilDay) continue;
    const p = world.players[r.personId];
    if (!p || !teamIds.includes(p.teamId)) continue;
    out.push(...r.modifiers);
  }
  return out;
}
