// Organisations: keeping every roster at 26 (13 P / 13 position), the injured list, call-ups and
// demotions on merit, releases and free-agent signings, and minting new amateurs.

import type { Rng } from "../rng.ts";
import { FIRST, LAST, NICKS } from "../names.ts";
import type { Level, Person, Player, Pos, Team, World } from "../types.ts";
import { FREE_AGENT, LEVELS } from "../types.ts";
import { mkEvent, type LifeEvent } from "./events.ts";
import { ensureHouse, newHouseId, pickFace, nextId, removeFromTeams } from "./people.ts";
import {
  GROUPS, GROUP_POS, TEMPLATE, battingFor, clamp, fieldingFor, groupOf, handsFor, pitchingFor, randomTraits, value,
  type Group,
} from "./ratings.ts";
import { levelLine } from "../league/stats.ts";

/** Set by life/enhanced.ts (Enhanced clubs have no farm system). */
let enhancedBalancer: ((w: World, rng: Rng, teamId: string, ev: LifeEvent[]) => void) | undefined;
export function setEnhancedBalancer(f: typeof enhancedBalancer) { enhancedBalancer = f; }

export const LEVEL_MEAN: Record<Level, number> = { ML: 50, AA: 43, B: 37, D: 31, EL: 46 };

export function orgId(team: Team): string {
  return team.parentId ?? team.id;
}

/** [ML, AA, B, D] teams of one organisation. */
export function orgTeams(world: World, mlId: string): Team[] {
  return LEVELS.map(lv => world.teams[lv === "ML" ? mlId : `${mlId}-${lv}`]).filter(Boolean);
}

export function mlTeamIds(world: World): string[] {
  return Object.values(world.teams).filter(t => t.level === "ML").map(t => t.id).sort();
}

export const healthy = (p: Player) => !p.injury || p.injury.daysLeft <= 0;

interface Baseline { ops: number; era: number }
const baselineCache = new WeakMap<World, { key: string; by: Partial<Record<Level, Baseline>> }>();

/** League-average OPS and ERA at a level this season (cached per day). */
export function levelBaseline(world: World, lv: Level): Baseline {
  const key = `${world.season}:${world.day}`;
  let c = baselineCache.get(world);
  if (!c || c.key !== key) { c = { key, by: {} }; baselineCache.set(world, c); }
  const hit = c.by[lv];
  if (hit) return hit;
  let h = 0, bb = 0, hbp = 0, ab = 0, sf = 0, tb = 0, er = 0, outs = 0;
  for (const byS of Object.values(world.stats)) {
    const l = levelLine(byS[world.season], lv);
    if (!l) continue;
    if (l.bat) { const b = l.bat; h += b.h; bb += b.bb; hbp += b.hbp; ab += b.ab; sf += b.sf; tb += b.h + b.d + 2 * b.t + 3 * b.hr; }
    if (l.pitch) { er += l.pitch.er; outs += l.pitch.outs; }
  }
  const res = ab > 2000
    ? { ops: (h + bb + hbp) / Math.max(1, ab + bb + hbp + sf) + tb / Math.max(1, ab), era: (er * 27) / Math.max(1, outs) }
    : { ops: 0.71, era: 4.3 };
  c.by[lv] = res;
  return res;
}

/** Season performance relative to the level's average line, in rating points (±6). */
export function perf(world: World, p: Player): number {
  const s = world.stats[p.id]?.[world.season];
  const lv = world.teams[p.teamId]?.level;
  if (!s || !lv) return 0;
  const line = levelLine(s, lv);
  if (!line) return 0;
  if (p.pos === "P") {
    const pl = line.pitch;
    if (!pl || pl.outs < 60) return 0;
    const era = (pl.er * 27) / pl.outs;
    return Math.max(-6, Math.min(6, (levelBaseline(world, lv).era - era) * 1.6 * Math.min(1, pl.outs / 240)));
  }
  const b = line.bat;
  if (!b || b.pa < 60) return 0;
  const obp = (b.h + b.bb + b.hbp) / Math.max(1, b.ab + b.bb + b.hbp + b.sf);
  const slg = (b.h + b.d + 2 * b.t + 3 * b.hr) / Math.max(1, b.ab);
  return Math.max(-6, Math.min(6, (obp + slg - levelBaseline(world, lv).ops) * 35 * Math.min(1, b.pa / 250)));
}

/** How much the organisation wants this player at the higher level. */
export function promoteScore(world: World, p: Player): number {
  const youth = p.age <= 24 ? Math.max(0, p.potential - value(p)) * 0.12 : 0;
  return value(p) + perf(world, p) + youth - (healthy(p) ? 0 : 100);
}

export function movePlayer(world: World, p: Player, to: Team | typeof FREE_AGENT) {
  removeFromTeams(world, p);
  if (to === FREE_AGENT) {
    p.teamId = FREE_AGENT;
    world.freeAgents.push(p.id);
    return;
  }
  p.teamId = to.id;
  to.roster.push(p.id);
}

const inGroup = (world: World, ids: string[], g: Group) => ids.map(id => world.players[id]).filter(p => p && groupOf(p) === g);

export interface BalanceOpts {
  /** Emit events for farm-only shuffles too (default: only moves touching the majors). */
  verbose?: boolean;
  reason?: string;
  /** Allow minting brand-new amateurs when the free-agent pool is dry (default true). */
  mint?: boolean;
}

/**
 * Make every team in the organisation match the roster template, top-down: surplus players
 * go down a level (or are released from D ball), holes are filled from below (or from free
 * agency / new amateurs at the bottom).
 */
export function balanceOrg(world: World, mlId: string, rng: Rng, events: LifeEvent[], opts: BalanceOpts = {}) {
  if (world.teams[mlId]?.level === "EL") { enhancedBalancer?.(world, rng, mlId, events); return; }
  const chain = orgTeams(world, mlId);
  for (let li = 0; li < chain.length; li++) {
    const team = chain[li];
    const below = chain.slice(li + 1);
    for (const g of GROUPS) {
      let members = inGroup(world, team.roster, g);
      while (members.length > TEMPLATE[g]) {
        // send down the least useful (healthy players first if any are hurt: hurt ones go to the IL instead)
        const keep = (p: Player) => promoteScore(world, p) + (healthy(p) ? 0 : 100);
        const worst = members.reduce((a, b) => (keep(b) < keep(a) ? b : a));
        if (below.length) {
          movePlayer(world, worst, below[0]);
          if (opts.verbose || team.level === "ML") events.push(mkEvent(world, "demotion", [worst.id], [team.id, below[0].id], { from: team.id, to: below[0].id, reason: opts.reason ?? "roster crunch" }));
        } else {
          movePlayer(world, worst, FREE_AGENT);
          events.push(mkEvent(world, "release", [worst.id], [team.id], { from: team.id, reason: opts.reason ?? "roster crunch" }));
        }
        members = members.filter(p => p !== worst);
      }
      while (members.length < TEMPLATE[g]) {
        let pick: Player | undefined;
        let from: Team | undefined;
        for (const lower of below) {
          const cands = inGroup(world, lower.roster, g).filter(healthy);
          if (cands.length) {
            pick = cands.reduce((a, b) => (promoteScore(world, b) > promoteScore(world, a) ? b : a));
            from = lower;
            break;
          }
        }
        if (pick && from) {
          movePlayer(world, pick, team);
          if (opts.verbose || team.level === "ML") {
            events.push(mkEvent(world, "callup", [pick.id], [from.id, team.id], { from: from.id, to: team.id, reason: opts.reason ?? "need", group: g }));
          }
        } else {
          const p = signOrMint(world, rng, g, team, events, opts.mint !== false);
          if (!p) break;
          pick = p;
        }
        members.push(pick);
      }
    }
  }
}

/** Best free agent in this group who'd take the job, or a brand-new amateur. */
export function signOrMint(world: World, rng: Rng, g: Group, team: Team, events: LifeEvent[], mint = true): Player | undefined {
  const fas = world.freeAgents.map(id => world.players[id]).filter(p => p && groupOf(p) === g && healthy(p) && p.age < 37);
  const levelFloor = LEVEL_MEAN[team.level] - 8;
  const fa = fas.length ? fas.reduce((a, b) => (value(b) > value(a) ? b : a)) : undefined;
  if (fa && value(fa) >= levelFloor) {
    movePlayer(world, fa, team);
    fa.contract = { years: 1 + rng.int(2), salary: Math.round(value(fa) * 2) };
    events.push(mkEvent(world, "signing", [fa.id], [team.id], { to: team.id, from: FREE_AGENT, reason: "free agent" }));
    return fa;
  }
  if (!mint) return undefined;
  const p = mintAmateur(world, rng, g, { age: 18 + rng.int(5) });
  movePlayer(world, p, team);
  events.push(mkEvent(world, "signing", [p.id], [team.id], { to: team.id, reason: "undrafted amateur" }));
  return p;
}

export interface AmateurOpts {
  age: number;
  pos?: Pos;
  /** Ceiling; random if omitted. */
  potential?: number;
  first?: string;
  last?: string;
  house?: string;
  throws?: "L" | "R";
  /** Turn an existing person (a league kid coming of age) into the player: keeps id, face, family, traits. */
  identity?: Person;
}

/** A new player (not on any team yet; caller places him). */
export function mintAmateur(world: World, rng: Rng, g: Group, o: AmateurOpts): Player {
  const pos: Pos = o.pos ?? rng.pick(GROUP_POS[g]);
  const age = o.age;
  const potential = clamp(o.potential ?? rng.normal(44, 9));
  // current ability: raw D-ball level, a bit better the older and more gifted he is
  const mean = 29 + (age - 18) * 1.6 + (potential - 44) * 0.22 + rng.normal(0, 2.5);
  const hands = handsFor(rng, pos);
  const throws = o.throws ?? hands.throws;
  const bats = o.throws && o.throws !== hands.throws ? (throws === "L" ? "L" : "R") : hands.bats;
  const who = o.identity;
  const last = who?.last ?? o.last ?? rng.pick(LAST);
  const p: Player = {
    id: who?.id ?? nextId(world, "p"), kind: "player", first: who?.first ?? o.first ?? rng.pick(FIRST), last, sex: "M",
    face: who?.face ?? pickFace(world, "M", age, rng), age, born: who?.born ?? world.year - age,
    traits: who?.traits.length ? who.traits : randomTraits(rng, rng.chance(0.35) ? 2 : 1),
    mood: who?.mood ?? 0, bats, throws, pos, teamId: FREE_AGENT,
    family: who?.family ?? { house: o.house ?? newHouseId(world, last), parents: [], children: [], drama: [] }, active: true,
    batting: battingFor(rng, pos, mean), fielding: fieldingFor(rng, pos, mean), potential, talent: who?.talent ?? potential,
    recentPitches: [0, 0, 0, 0, 0], contract: { years: 3, salary: 6 },
  };
  if (pos === "P") {
    p.pitching = pitchingFor(rng, mean, g === "SP" ? "SP" : "RP", throws);
    // keep him in the group he was minted for (groupOf splits SP/RP on stamina 46)
    p.pitching.stamina = g === "SP" ? Math.max(50, p.pitching.stamina) : Math.min(42, p.pitching.stamina);
  }
  if (who?.nickname) p.nickname = who.nickname;
  else if (!who && rng.chance(0.15)) p.nickname = rng.pick(NICKS);
  if (who) delete world.npcs[who.id];
  p.peak = Math.round(value(p));
  world.players[p.id] = p;
  const h = ensureHouse(world, p.family.house, p);
  h.players++;
  return p;
}

// --- injured list -----------------------------------------------------------------------------

/** Long injuries go on the IL (and get replaced); healed players come back. */
export function manageInjuredLists(world: World, rng: Rng, events: LifeEvent[]) {
  const touched = new Set<string>();
  for (const team of Object.values(world.teams)) {
    team.il ??= [];
    for (const id of [...team.il]) {
      const p = world.players[id];
      if (!p) { team.il = team.il.filter(x => x !== id); continue; }
      if (healthy(p)) {
        team.il = team.il.filter(x => x !== id);
        team.roster.push(id);
        touched.add(orgId(team));
        if (team.level === "ML") events.push(mkEvent(world, "return", [id], [team.id], { from: "IL" }));
      }
    }
    const players = team.roster.map(id => world.players[id]).filter(Boolean);
    const healthyHitters = players.filter(p => p.pos !== "P" && healthy(p)).length;
    const healthyArms = players.filter(p => p.pos === "P" && healthy(p)).length;
    for (const p of players) {
      if (healthy(p)) continue;
      const long = p.injury!.daysLeft > (team.level === "ML" ? 10 : team.level === "AA" ? 20 : 45);
      const short = (p.pos === "P" ? healthyArms < 10 : healthyHitters < 11);
      if (!long && !short) continue;
      team.roster = team.roster.filter(x => x !== p.id);
      team.il.push(p.id);
      touched.add(orgId(team));
      if (team.level === "ML") events.push(mkEvent(world, "il", [p.id], [team.id], { injury: p.injury!.kind, days: p.injury!.daysLeft }));
    }
  }
  for (const org of [...touched].sort()) balanceOrg(world, org, rng, events, { reason: "injury" });
}

// --- merit moves --------------------------------------------------------------------------------

/** Weekly: hot farmhands swap places with slumping players one level up. */
export function meritMoves(world: World, rng: Rng, events: LifeEvent[]) {
  for (const mlId of mlTeamIds(world)) {
    const chain = orgTeams(world, mlId);
    let swaps = 0;
    const maxSwaps = 1 + (rng.chance(0.5) ? 1 : 0);
    for (let li = 0; li < chain.length - 1 && swaps < maxSwaps; li++) {
      const upper = chain[li], lower = chain[li + 1];
      for (const g of rng.shuffle([...GROUPS])) {
        const up = inGroup(world, upper.roster, g).filter(healthy);
        const down = inGroup(world, lower.roster, g).filter(healthy);
        if (!up.length || !down.length) continue;
        const worst = up.reduce((a, b) => (promoteScore(world, b) < promoteScore(world, a) ? b : a));
        const best = down.reduce((a, b) => (promoteScore(world, b) > promoteScore(world, a) ? b : a));
        if (promoteScore(world, best) <= promoteScore(world, worst) + (li === 0 ? 3 : 5)) continue;
        movePlayer(world, worst, lower);
        movePlayer(world, best, upper);
        const why = perf(world, best) > 2 ? "tearing it up" : perf(world, worst) < -2 ? "slumping" : "ready";
        events.push(mkEvent(world, "callup", [best.id], [lower.id, upper.id], { from: lower.id, to: upper.id, reason: why, swappedWith: worst.id }));
        events.push(mkEvent(world, "demotion", [worst.id], [upper.id, lower.id], { from: upper.id, to: lower.id, reason: perf(world, worst) < -2 ? "slumping" : "squeezed out", swappedWith: best.id }));
        if (worst.traits.includes("HOTHEAD") || worst.traits.includes("SHOWBOAT")) worst.mood = Math.max(-5, worst.mood - 1.5);
        best.mood = Math.min(5, best.mood + 1.5);
        if (++swaps >= maxSwaps) break;
      }
    }
  }
}

/** Occasional: a club cuts a going-nowhere farmhand, or grabs a useful free agent. */
export function releasesAndSignings(world: World, rng: Rng, events: LifeEvent[]) {
  for (const mlId of mlTeamIds(world)) {
    if (!rng.chance(0.06)) continue;
    const d = orgTeams(world, mlId).find(t => t.level === "D" || t.level === "B");
    if (!d) continue;
    const cands = d.roster.map(id => world.players[id]).filter(p => p && p.age >= 24 && p.potential < 45 && value(p) < LEVEL_MEAN[d.level]);
    if (!cands.length) continue;
    const cut = cands.reduce((a, b) => (value(b) < value(a) ? b : a));
    movePlayer(world, cut, FREE_AGENT);
    events.push(mkEvent(world, "release", [cut.id], [d.id], { from: d.id, reason: rng.pick(["going nowhere", "attitude", "made the coach's daughter cry", "roster space"]) }));
    balanceOrg(world, mlId, rng, events, { verbose: true, reason: "release" });
  }
  // majors: sign a free agent who's better than the worst man in his group
  if (world.freeAgents.length && rng.chance(0.2)) {
    const fas = world.freeAgents.map(id => world.players[id]).filter(p => p && healthy(p) && p.age < 36);
    const best = fas.length ? fas.reduce((a, b) => (value(b) > value(a) ? b : a)) : undefined;
    if (best) {
      const g = groupOf(best);
      for (const mlId of rng.shuffle(mlTeamIds(world))) {
        const team = world.teams[mlId];
        const worst = inGroup(world, team.roster, g);
        if (!worst.length) continue;
        const w = worst.reduce((a, b) => (value(b) < value(a) ? b : a));
        if (value(best) > value(w) + 2) {
          movePlayer(world, best, team);
          best.contract = { years: 1 + rng.int(3), salary: Math.round(value(best) * 3) };
          events.push(mkEvent(world, "signing", [best.id], [team.id], { to: team.id, from: FREE_AGENT, reason: "free agent" }));
          balanceOrg(world, mlId, rng, events, { reason: "signing" });
          break;
        }
      }
    }
  }
}

/** Sanity: every roster matches the template (used by tests and as a self-heal after big moves). */
export function rosterProblems(world: World): string[] {
  const out: string[] = [];
  for (const t of Object.values(world.teams)) {
    if (t.roster.length !== 26) out.push(`${t.id} has ${t.roster.length}`);
    const ps = t.roster.map(id => world.players[id]);
    if (ps.some(p => !p)) out.push(`${t.id} has a missing player`);
    const pit = ps.filter(p => p && p.pos === "P").length;
    if (pit !== 13) out.push(`${t.id} has ${pit} pitchers`);
    for (const p of ps) if (p && p.teamId !== t.id) out.push(`${p.id} on ${t.id} but teamId ${p.teamId}`);
  }
  return out;
}
