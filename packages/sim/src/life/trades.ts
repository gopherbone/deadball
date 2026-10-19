// Trades between organisations: a contender with a hole swaps a prospect for a seller's veteran.
// Which clubs will even pick up the phone depends on their owners' relations (world.relationships).

import type { Rng } from "../rng.ts";
import type { Player, World } from "../types.ts";
import { mkEvent, type LifeEvent } from "./events.ts";
import { relation, relsOf, shiftRelation, addDrama } from "./people.ts";
import { addConcern, achieveGoal, goalOf } from "./inner.ts";
import { setSwapHook } from "./storylines.ts";
import { GROUPS, groupOf, value, type Group } from "./ratings.ts";
import { balanceOrg, healthy, mlTeamIds, movePlayer, orgTeams } from "./roster.ts";

const NEED_WORDS: Record<Group, string> = { C: "a catcher", IF: "infield help", OF: "an outfielder", SP: "a starter", RP: "bullpen help" };

/** Mean value of the top-n players of a group on a roster. */
function groupStrength(world: World, roster: string[], g: Group, n: number): number {
  const vs = roster.map(id => world.players[id]).filter(p => p && groupOf(p) === g).map(value).sort((a, b) => b - a).slice(0, n);
  return vs.length ? vs.reduce((a, b) => a + b, 0) / vs.length : 30;
}
const STARTERS: Record<Group, number> = { C: 1, IF: 4, OF: 3, SP: 5, RP: 4 };

/** Prospect value: what a club thinks a youngster will become. */
export function futureValue(p: Player): number {
  const v = value(p);
  return p.age <= 25 ? v + (p.potential - v) * 0.7 : v;
}

/**
 * Maybe make one trade today. `winPct` (by ML team id) tells contenders from sellers.
 * Returns true if a trade happened.
 */
export function tryTrade(world: World, rng: Rng, events: LifeEvent[], winPct: Record<string, number> = {}, offseason = false): boolean {
  const ml = mlTeamIds(world);
  // buyer: contenders more likely (or anyone in the winter)
  const buyerId = rng.weighted(ml, id => (offseason ? 1 : Math.max(0.05, (winPct[id] ?? 0.5) - 0.35) * 4));
  const buyer = world.teams[buyerId];
  // the buyer's weakest group, relative to the league
  const leagueAvg = (g: Group) => ml.reduce((a, id) => a + groupStrength(world, world.teams[id].roster, g, STARTERS[g]), 0) / ml.length;
  const need = GROUPS.map(g => [g, groupStrength(world, buyer.roster, g, STARTERS[g]) - leagueAvg(g)] as [Group, number]).sort((a, b) => a[1] - b[1])[0][0];
  const buyerWorst = buyer.roster.map(id => world.players[id]).filter(p => p && groupOf(p) === need).sort((a, b) => value(a) - value(b))[0];
  if (!buyerWorst) return false;

  // sellers: willing partners (owners who aren't at war), losing clubs keener
  const sellers = ml.filter(id => id !== buyerId).map(id => {
    const rel = relation(world, buyer.factionId, world.teams[id].factionId);
    const w = rel <= -4 ? 0.02 : 1 + rel * 0.4 + (offseason ? 0 : Math.max(0, 0.5 - (winPct[id] ?? 0.5)) * 6);
    return { id, rel, w: Math.max(0.02, w) };
  });
  const seller = rng.weighted(sellers, s => s.w);
  const sTeam = world.teams[seller.id];
  const vets = sTeam.roster.map(id => world.players[id])
    .filter(p => p && groupOf(p) === need && healthy(p) && value(p) > value(buyerWorst) + 3 && world.day - (p.tradedDay ?? -1e9) > 150 && !(p.traits.includes("LOYAL") && rng.chance(0.7)));
  if (!vets.length) return false;
  const vet = vets.sort((a, b) => value(b) - value(a))[rng.int(Math.min(2, vets.length))];

  // the buyer's best prospect in the same group (keeps roster shapes intact)
  const farm = orgTeams(world, buyerId).slice(1);
  const prospects = farm.flatMap(t => t.roster.map(id => world.players[id])).filter(p => p && groupOf(p) === need && p.age <= 26 && healthy(p) && world.day - (p.tradedDay ?? -1e9) > 150);
  if (!prospects.length) return false;
  const prospect = prospects.sort((a, b) => futureValue(b) - futureValue(a))[0];
  const rebuilding = (winPct[seller.id] ?? 0.5) < 0.47 || offseason;
  if (futureValue(prospect) + (rebuilding ? 6 : 0) + seller.rel < value(vet) - 4) return false;

  const prospectTeam = world.teams[prospect.teamId];
  const sellerLevelTeam = orgTeams(world, seller.id).find(t => t.level === prospectTeam.level)!;
  vet.tradedDay = prospect.tradedDay = world.day;
  movePlayer(world, vet, buyer);
  movePlayer(world, prospect, sellerLevelTeam);
  balanceOrg(world, buyerId, rng, events, { reason: "trade" });
  balanceOrg(world, seller.id, rng, events, { reason: "trade" });

  // feelings
  for (const p of [vet, prospect]) traded(world, rng, p, events);
  for (const p of [vet, prospect]) {
    p.mood = Math.max(-5, p.mood - (p.traits.includes("LOYAL") ? 3 : 1));
    if (p.traits.includes("LOYAL")) addDrama(p, { kind: "feud", with: world.factions[p === vet ? sTeam.factionId : buyer.factionId]?.leaderId, since: world.day, weight: -2, note: "traded away" });
  }
  shiftRelation(world, buyer.factionId, sTeam.factionId, 1, `the ${vet.last} trade`);
  const reason = `${buyer.city} needed ${NEED_WORDS[need]}`;
  events.push(mkEvent(world, "trade", [vet.id, prospect.id], [buyerId, seller.id], {
    from: seller.id, to: buyerId, players: [vet.id, prospect.id], reason, need, value: Math.round(value(vet)),
    prospectFuture: Math.round(futureValue(prospect)), relation: seller.rel,
  }));
  return true;
}

/** What a trade does to a man: fears realised, goals met, old bonds strained. */
export function traded(world: World, rng: Rng, p: Player, events: LifeEvent[]) {
  if (p.fears?.some(f => f.kind === "being_traded")) {
    p.mood = Math.max(-5, p.mood - 2);
    events.push(mkEvent(world, "fear", [p.id], [p.teamId], { sub: "realized", fear: "being_traded" }));
  }
  if (goalOf(p, "get_out")) achieveGoal(world, rng, p, "get_out", events, "traded");
  // friendships strain across the distance; contract-year and hot-seat arcs notice in their own step
  for (const r of relsOf(world, p.id)) {
    if (r.kind === "friend" && r.value > 1 && rng.chance(0.5)) r.value -= 1;
  }
  addConcern(world, p, { kind: "trade_rumours", until: world.day + 20, weight: -1, note: "new town" });
}

/** A one-for-one swap of this player for a same-group major-leaguer elsewhere (holdouts, scandals). */
export function swapTrade(world: World, rng: Rng, p: Player, events: LifeEvent[], reason: string): boolean {
  const g = groupOf(p);
  const fromTeam = world.teams[p.teamId];
  if (!fromTeam) return false;
  const fromOrg = fromTeam.parentId ?? fromTeam.id;
  const partners = mlTeamIds(world).filter(id => id !== fromOrg && relation(world, world.teams[id].factionId, fromTeam.factionId) > -4);
  if (!partners.length) return false;
  const to = world.teams[rng.pick(partners)];
  const back = to.roster.map(id => world.players[id]).filter(x => x && groupOf(x) === g && healthy(x));
  if (!back.length) return false;
  const other = rng.pick(back);
  movePlayer(world, p, to);
  movePlayer(world, other, fromTeam);
  p.tradedDay = other.tradedDay = world.day;
  balanceOrg(world, fromOrg, rng, events, { reason: "trade" });
  balanceOrg(world, to.id, rng, events, { reason: "trade" });
  traded(world, rng, p, events);
  traded(world, rng, other, events);
  events.push(mkEvent(world, "trade", [p.id, other.id], [to.id, fromOrg], { from: fromOrg, to: to.id, players: [p.id, other.id], reason, value: Math.round(value(p)) }));
  return true;
}
setSwapHook(swapTrade);
