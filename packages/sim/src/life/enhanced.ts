// Life on the Enhanced circuit: unexplained players (powers, clones, the resurrected, historical
// figures, changed abductees) draw the Commissioner's attention and get sent to the desert;
// once in a while somebody comes back. Enhanced rosters stay at 26 (13 P / 13 position).

import type { Rng } from "../rng.ts";
import type { Player, Team, World } from "../types.ts";
import { FREE_AGENT } from "../types.ts";
import { mkEvent, type LifeEvent } from "./events.ts";
import { DAYS_PER_YEAR, hasQ } from "./people.ts";
import { GROUPS, TEMPLATE, groupOf, value, type Group } from "./ratings.ts";
import { LEVEL_MEAN, balanceOrg, healthy, mlTeamIds, movePlayer, orgTeams, setEnhancedBalancer } from "./roster.ts";
import { findOpen, nudgeStoryline, retireHook, setTransferHook, startStoryline } from "./storylines.ts";
import { addConcern, gainFame } from "./inner.ts";
import { mintOddball } from "../league/enhanced.ts";

const ODD: NonNullable<Player["quirks"]> = ["CLONE", "RESURRECTED", "TIME_DISPLACED", "GLOWS", "KNOWS_THINGS", "NO_SHADOW", "SPEAKS_TO_BIRDS"];

/** Why the league can't explain this player (undefined if it can). */
export function unexplained(p: Player): string | undefined {
  if (p.powers?.length) return `powers (${p.powers.map(x => x.kind).join(", ")})`;
  if (p.historical) return `a historical figure (${p.historical.figure})`;
  if (p.cloneOf || hasQ(p, "CLONE")) return "a clone";
  if (hasQ(p, "RESURRECTED")) return "came back from the dead";
  if (p.quirks?.some(q => ODD.includes(q))) return "changed after an abduction";
  return undefined;
}

export const enhancedIds = (world: World) => Object.values(world.teams).filter(t => t.level === "EL").map(t => t.id).sort();

/** Daily: watch storylines for unexplained Continental players, keep the circuit stocked, rare returns. */
export function enhancedDay(world: World, rng: Rng, events: LifeEvent[], phase: string) {
  const el = enhancedIds(world);
  if (!el.length) return;
  // the Commissioner starts asking questions
  for (const p of Object.values(world.players)) {
    const t = world.teams[p.teamId];
    if (!t || t.level === "EL") continue;
    const why = unexplained(p);
    if (!why || findOpen(world, "enhanced_watch", p.id)) continue;
    startStoryline(world, "enhanced_watch", [p.id], [t.id], {
      visibility: p.powers?.length || p.historical || p.cloneOf ? "rumoured" : "secret", stage: "whispers", cause: why, stakes: "his place in the Continental league",
      data: { power: p.powers?.[0]?.kind, figure: p.historical?.figure },
    }, events);
  }
  // free agents the league can't explain go straight to the desert
  for (const id of [...world.freeAgents]) {
    const p = world.players[id];
    if (p && unexplained(p) && rng.chance(0.2)) transferToEnhanced(world, rng, p, events, unexplained(p)!);
  }
  // now and then somebody is allowed home
  if (phase !== "offseason" || rng.chance(0.5)) {
    for (const id of el) {
      for (const pid of [...world.teams[id].roster]) {
        const p = world.players[pid];
        if (!p) continue;
        const odd = unexplained(p);
        const rate = !odd ? 0.03 : p.powers?.length ? 0.003 : 0.008;
        if (rng.chance(rate / DAYS_PER_YEAR)) returnToContinental(world, rng, p, events, !odd ? "never belonged out here" : rng.pick(["the power faded", "a sympathetic judge", "public pressure", "the Commissioner owed his family a favour"]));
      }
    }
  }
  for (const id of el) balanceEnhancedTeam(world, rng, world.teams[id], events);
}

/** Send a player to the Enhanced League (forced transfer). */
export function transferToEnhanced(world: World, rng: Rng, p: Player, events: LifeEvent[], reason: string, eventOf?: string): string | undefined {
  const el = enhancedIds(world);
  if (!el.length) return undefined;
  const g = groupOf(p);
  // the club that needs him most (weakest in his group)
  const strength = (id: string) => {
    const vs = world.teams[id].roster.map(x => world.players[x]).filter(x => x && groupOf(x) === g).map(value);
    return vs.length ? vs.reduce((a, b) => a + b, 0) / vs.length : 0;
  };
  const to = world.teams[el.reduce((a, b) => (strength(b) < strength(a) ? b : a))];
  const from = world.teams[p.teamId];
  const fromOrg = from ? from.parentId ?? from.id : undefined;
  movePlayer(world, p, to);
  if (p.injury?.kind === "holdout") delete p.injury;
  addConcern(world, p, { kind: "trade_rumours", until: world.day + 30, weight: -1.5, note: "sent to the desert" });
  gainFame(world, rng, p, 5, events, "transfer");
  events.push(mkEvent(world, "transfer", [p.id], [to.id, ...(from ? [from.id] : [])], { sub: "to_enhanced", from: from?.id ?? FREE_AGENT, to: to.id, reason, eventOf, power: p.powers?.[0]?.kind, figure: p.historical?.figure }));
  balanceEnhancedTeam(world, rng, to, events);
  if (fromOrg && world.teams[fromOrg]?.level === "ML") balanceOrg(world, fromOrg, rng, events, { reason: "transfer" });
  return to.id;
}

/** Bring a player back to a Continental organisation at the level his ability merits. */
export function returnToContinental(world: World, rng: Rng, p: Player, events: LifeEvent[], reason: string) {
  const from = world.teams[p.teamId];
  const org = rng.pick(mlTeamIds(world));
  const chain = orgTeams(world, org);
  const v = value(p);
  const team = v >= LEVEL_MEAN.ML - 3 ? chain[0] : v >= LEVEL_MEAN.AA - 3 ? chain[1] : v >= LEVEL_MEAN.B - 3 ? chain[2] : chain[3];
  movePlayer(world, p, team);
  events.push(mkEvent(world, "transfer", [p.id], [team.id, ...(from ? [from.id] : [])], { sub: "return", from: from?.id, to: team.id, reason }));
  balanceOrg(world, org, rng, events, { reason: "return" });
  if (from) balanceEnhancedTeam(world, rng, from, events);
}

/** Keep an Enhanced roster at the template: trim the weakest to free agency, fill from free agents or new oddballs. */
export function balanceEnhancedTeam(world: World, rng: Rng, team: Team, events: LifeEvent[]) {
  if (team.level !== "EL") return;
  for (const g of GROUPS) {
    let members = team.roster.map(id => world.players[id]).filter(p => p && groupOf(p) === g);
    while (members.length > TEMPLATE[g]) {
      const keep = (p: Player) => value(p) + (p.powers?.length ? 6 : 0) + (healthy(p) ? 0 : 100) + (unexplained(p) ? 3 : 0);
      const worst = members.reduce((a, b) => (keep(b) < keep(a) ? b : a));
      if (unexplained(worst) && retireHook) {
        // nobody else will have him: he stays out in the desert for good
        retireHook(world, rng, worst, events, "cut loose in the desert");
      } else {
        movePlayer(world, worst, FREE_AGENT);
        events.push(mkEvent(world, "release", [worst.id], [team.id], { from: team.id, reason: "cut loose in the desert" }));
      }
      members = members.filter(p => p !== worst);
    }
    while (members.length < TEMPLATE[g]) {
      const fa = world.freeAgents.map(id => world.players[id]).filter(p => p && groupOf(p) === g && healthy(p) && p.age < 40 && (unexplained(p) || value(p) >= LEVEL_MEAN.EL - 6));
      const pick = fa.length ? fa.reduce((a, b) => (value(b) > value(a) ? b : a)) : mintOddball(world, rng, g as Group);
      movePlayer(world, pick, team);
      events.push(mkEvent(world, "signing", [pick.id], [team.id], { to: team.id, reason: fa.length ? "free agent" : "walked in from the desert" }));
      members.push(pick);
    }
  }
}

/** A powered player used his power in a Continental game: everybody saw it. */
export function poweredInPublic(world: World, playerId: string) {
  const s = findOpen(world, "enhanced_watch", playerId);
  if (!s) return;
  s.data.used = Number(s.data.used ?? 0) + 1;
  nudgeStoryline(world, s.id, "inflame", 0.5);
  nudgeStoryline(world, s.id, "expose", 1);
}

setTransferHook((w, rng, p, ev, reason, eventOf) => { transferToEnhanced(w, rng, p, ev, reason, eventOf); });
setEnhancedBalancer((w, rng, teamId, ev) => balanceEnhancedTeam(w, rng, w.teams[teamId], ev));
