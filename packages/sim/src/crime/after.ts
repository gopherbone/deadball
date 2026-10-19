// After the final out: who saw what. Exposure, arrests, snitches, threats and the
// morning paper.

import type { GameResult } from "../game.ts";
import type { World } from "../types.ts";
import { Rng } from "../rng.ts";
import { GEAR, RISK_EXPOSURE, groupSkill, opKind } from "./ops.ts";
import { crewName, crewRoleLabel } from "./recruit.ts";
import { splitHeat } from "./resolve.ts";
import { arrestCard, heatCard, snitchCard } from "./events.ts";
import { writeScandalStory } from "../news/scandal.ts";
import { dateLine } from "../news/util.ts";
import type { Story } from "../news/types.ts";
import type { CrewMember, CrimeEffect, EventCard, MailItem, NewsHook, OpOutcome } from "./types.ts";
import { cardPhoto, mailPhoto } from "./photos.ts";
import { angerFaction, grudgeMail, hostility, securityDetail } from "./hostility.ts";

const clamp = (x: number, lo: number, hi: number) => Math.max(lo, Math.min(hi, x));

/** Exposure chance for one finished job (exported for tests and the planner). */
export function exposureChance(world: World, out: OpOutcome, res?: GameResult): number {
  const def = opKind(out.kind);
  if (!def) return 0;
  const crew = out.crew ?? [];
  let p = RISK_EXPOSURE[def.risk];
  const heat = crew.length ? crew.reduce((a, c) => a + c.heat, 0) / crew.length : 0;
  p *= 1 + 0.08 * heat;
  p *= clamp(1.3 - 0.1 * groupSkill(crew, "sneak", out.gear ?? []), 0.5, 1.4);
  p *= clamp(1.15 - 0.05 * groupSkill(crew, "nerve", out.gear ?? []), 0.8, 1.2);
  for (const g of out.gear ?? []) if (def.gear.includes(g)) p *= GEAR[g]?.exposure ?? 1;
  if (!out.success) p *= 1.3;
  if (out.collision?.length) p *= 1.5;
  if (res?.incidents.some(i => i.sources.includes(out.orderId))) p *= 1.6; // a big incident brings investigators
  if (crew.some(c => c.role === "nun") && def.kind === "laser") p *= 0.8; // nobody suspects the nun
  if (out.guard) p *= securityDetail(out.guard).exposure; // the owners' own men are watching for us
  return clamp(p, 0.01, 0.85);
}

export interface AfterGameResult {
  mail: MailItem[];
  events: EventCard[];
  stories: Story[];
  effects: CrimeEffect[];
  /** Updated crew snapshots (status, heat, loyalty) to persist. */
  crew: CrewMember[];
}

/** Run once per finished game with the outcomes of jobs on that game. */
export function afterGame(world: World, outcomes: OpOutcome[], res: GameResult, rng: Rng): AfterGameResult {
  return settle(world, outcomes.filter(o => o.gameId === undefined || o.gameId === res.id), rng, res);
}

/**
 * Settle jobs that weren't tied to a game (storyline ops with gameId ""): exposure, arrests,
 * mail, cards and stories, exactly as afterGame does. The server calls it once at day end.
 */
export function settleOps(world: World, outcomes: OpOutcome[], rng: Rng): AfterGameResult {
  return settle(world, outcomes.filter(o => !o.gameId), rng);
}

function settle(world: World, outcomes: OpOutcome[], rng: Rng, res?: GameResult): AfterGameResult {
  const day = world.day;
  const mail: MailItem[] = [];
  const events: EventCard[] = [];
  const stories: Story[] = [];
  const effects: CrimeEffect[] = [];
  const crewOut: CrewMember[] = [];
  const heatTotals: Record<string, number> = {};

  for (const out of outcomes) {
    const def = opKind(out.kind);
    if (!def) continue;
    const crew = out.crew ?? [];
    if (out.calledOff) {
      // never started: nobody saw anything; crew go home
      for (const c of crew) {
        if (c.status === "busy") { c.status = "free"; delete c.until; }
        crewOut.push(c);
        effects.push({ kind: "crew", crewId: c.id, status: c.status, until: c.until, loyalty: c.loyalty, heat: c.heat });
      }
      continue;
    }
    const r = rng.fork(`after:${out.orderId}`);
    const owners = out.participants?.length ? out.participants : out.ownerId ? [out.ownerId] : [];
    const team = world.teams[out.targetTeamId ?? ""];
    const tName = team?.name ?? "them";
    const send = (to: string, m: Omit<MailItem, "id" | "ownerId" | "day">) => mail.push({ ...m, id: `${out.orderId}:after:${mail.length}`, ownerId: to, day });
    const incident = res?.incidents.find(i => i.sources.includes(out.orderId));
    let heat = 0;

    // --- the report
    const report: string[] = [];
    if (out.success) {
      report.push(incident ? `It happened in the ${ordinal(incident.inning)}: ${incidentLine(incident.kind, tName)}` : out.nudge ? nudgeLine(out.nudge.kind) : reportLine(def.kind, tName));
    } else report.push(out.summary ?? "The job didn't take.");
    if (res) {
      const winner = res.winner === "home" ? res.home : res.away;
      const targetLost = out.targetTeamId ? winner.teamId !== out.targetTeamId : false;
      report.push(out.targetTeamId ? `Final: ${final(world, res)}. The ${tName} ${targetLost ? "lost" : "won anyway"}.` : `Final: ${final(world, res)}.`);
    }
    for (const o of owners) send(o, { from: "The Clubhouse BBS", subject: `Report: ${def.name}`, body: report, kind: "op" });

    // --- exposure (jobs nabbed before first pitch are already exposed)
    const already = out.exposed;
    const p = exposureChance(world, out, res);
    const exposed = already || r.chance(p);
    if (exposed && !already) {
      out.exposed = true;
      heat += 3;
      for (const c of crew) {
        c.heat = Math.min(10, c.heat + 2);
        const pArrest = clamp(0.3 + 0.05 * c.heat - 0.07 * c.skills.sneak - 0.03 * c.skills.nerve, 0.08, 0.8);
        if (c.status !== "jailed" && r.chance(pArrest)) {
          c.status = "jailed";
          c.until = day + 5;
          out.arrests.push(c.id);
        }
      }
      const hook: NewsHook = { kind: out.arrests.length ? "arrest" : "exposed", day, opKind: def.kind, people: crew.map(c => c.personId), targetTeamId: out.targetTeamId ?? "", gameId: res?.id, success: out.success, factions: team ? [team.factionId] : [] };
      out.hooks = [...(out.hooks ?? []), hook];
      // the wronged club's owners remember: a grudge against everyone on the job and their syndicate
      if (team) {
        angerOwners(world, team.factionId, out, owners, def.risk === "high" || def.risk === "lol" ? 2 : 1, `the ${def.name.toLowerCase()}`, mail);
        const leader = team ? world.npcs[world.factions[team.factionId]?.leaderId ?? ""] : undefined;
        for (const o of owners) send(o, {
          from: leader ? `${leader.first} ${leader.last}` : world.factions[team.factionId]?.name ?? "A friend", fromFace: leader?.face,
          subject: "We know", kind: "threat",
          body: [threatLine(world.factions[team.factionId]?.kind ?? "owner", tName), "There will not be a second letter."],
        });
      }
      for (const o of owners) send(o, {
        from: "Commissioner's Office", subject: "Notice of inquiry", kind: "league",
        body: [`The Office is aware of irregularities at the ${tName} game of ${dateLine(world, day)}. An inquiry is open. Persons with knowledge are encouraged to call the hotline (1-800-555-0144).`],
      });
      // arrests: loyal crew sit tight, the rest talk
      for (const id of out.arrests) {
        const c = crew.find(x => x.id === id);
        if (!c) continue;
        const talky = world.npcs[c.personId]?.traits.includes("SNITCH") || c.loyalty <= 1 || (c.loyalty === 2 && r.chance(0.5));
        events.push(talky ? snitchCard(world, out, c) : arrestCard(world, out, c, "after"));
      }
      if (!out.arrests.length) {
        const wanted = crew[0];
        if (wanted) for (const o of owners) send(o, { from: "The Clubhouse BBS", subject: "A sketch in the paper", kind: "op", body: [`SportsWire has a sketch of ${crewName(world, wanted)} (${crewRoleLabel(wanted)}). It is accurate.`] });
      }
    } else if (already) {
      if (team) angerOwners(world, team.factionId, out, owners, def.risk === "high" || def.risk === "lol" ? 2 : 1, `the ${def.name.toLowerCase()}`, mail);
      for (const o of owners) send(o, {
        from: "Commissioner's Office", subject: "Notice of inquiry", kind: "league",
        body: [`An individual was detained at the ${tName} game of ${dateLine(world, day)}. The Office has notified local police.`],
      });
      // pre-game arrests: snitches still snitch
      for (const id of out.arrests) {
        const c = crew.find(x => x.id === id);
        if (c && world.npcs[c.personId]?.traits.includes("SNITCH") && !out.events.some(e => e.kind === "snitch")) events.push(snitchCard(world, out, c));
      }
    }

    // --- stories from hooks (tips, kidnappings, letters, exposures)
    for (const h of out.hooks ?? []) {
      const s = writeScandalStory(world, h);
      if (s) stories.push(s);
    }

    // --- crew home (unless in custody or hospital); loyalty drifts with results
    for (const c of crew) {
      if (c.status === "busy") { c.status = "free"; delete c.until; }
      if (out.success && r.chance(0.3)) c.loyalty = Math.min(5, c.loyalty + 1);
      if (!out.success && r.chance(0.25)) c.loyalty = Math.max(0, c.loyalty - 1);
      if (!exposed && c.heat > 0 && r.chance(0.3)) c.heat -= 1;
      crewOut.push(c);
      effects.push({ kind: "crew", crewId: c.id, status: c.status, until: c.until, loyalty: c.loyalty, heat: c.heat });
    }

    // --- heat, split across a syndicate
    const split = splitHeat(heat, owners);
    out.heat += heat;
    out.heatBy = out.heatBy ?? {};
    for (const o of owners) {
      out.heatBy[o] = Math.round(((out.heatBy[o] ?? 0) + (split[o] ?? 0)) * 10) / 10;
      heatTotals[o] = (heatTotals[o] ?? 0) + out.heatBy[o];
      effects.push({ kind: "heat", ownerId: o, delta: out.heatBy[o], why: def.name });
    }
  }

  for (const [o, h] of Object.entries(heatTotals)) {
    if (h >= 4) events.push(heatCard(world, o, h, res ? `${res.id}` : `day${day}`));
  }
  const kindOf = new Map(outcomes.map(o => [o.orderId, o.kind]));
  for (const m of mail) mailPhoto(m, kindOf.get(m.id.split(":after:")[0]));
  for (const e of events) cardPhoto(e);
  return { mail, events, stories, effects, crew: crewOut };
}

/** Exposure: the faction holds it against each account on the job and its syndicate, and says so as it escalates. */
function angerOwners(world: World, factionId: string, out: OpOutcome, owners: string[], delta: number, reason: string, mail: MailItem[]) {
  const before: Record<string, number> = {};
  for (const o of owners) before[o] = hostility(world, factionId, [o, out.syndicateId]);
  for (const o of owners) angerFaction(world, factionId, o, delta, reason);
  if (out.syndicateId) angerFaction(world, factionId, out.syndicateId, delta, reason);
  for (const o of owners) mail.push(...grudgeMail(world, factionId, o, before[o], hostility(world, factionId, [o, out.syndicateId]), out.orderId));
}

function final(world: World, res: GameResult): string {
  const a = world.teams[res.away.teamId], h = world.teams[res.home.teamId];
  return `${a?.abbr ?? "AWY"} ${res.away.runs}, ${h?.abbr ?? "HOM"} ${res.home.runs}${res.innings > 9 ? ` (${res.innings})` : ""}`;
}

export function ordinal(n: number): string {
  const s = ["th", "st", "nd", "rd"], v = n % 100;
  return n + (s[(v - 20) % 10] || s[v] || s[0]);
}

function incidentLine(kind: string, team: string): string {
  switch (kind) {
    case "RACCOONS_BULLPEN": return `raccoons were found in the ${team} bullpen. Two relievers were treated at the scene.`;
    case "FOOD_POISONING": return `${team} players left the dugout with stomach complaints.`;
    case "LASER_POINTER": return `the laser was on the ${team} hitters. Security searched the wrong section.`;
    case "BRAWL": return "the benches cleared. Our squad was in the front row.";
    case "BLACKOUT": return "the lights went out. Neither starting pitcher returned.";
    case "FAN_ON_FIELD": return "a fan ran onto the field looking for the mascot.";
    case "RACCOON_ON_FIELD": return "a raccoon crossed the infield.";
    default: return "it happened, and people saw it.";
  }
}

function reportLine(kind: string, team: string): string {
  switch (kind) {
    case "grease_mound": return `The ${team} pitchers had trouble with their footing. No one checked the rubber.`;
    case "rabbit_balls": return "The balls carried. No one examined them.";
    case "bribe_ump": return `Close pitches went against the ${team}. The umpire did not look at anyone.`;
    case "steal_signs": return "We had their signs all night.";
    case "lucky_glove": return "The glove was not found. A pitcher was seen crying in the bullpen.";
    case "sprinklers": return `The ${team} infield was under water at first pitch.`;
    case "heckle": return "The squad used all four pages.";
    case "love_letter": return "He looked at the stands for his wife between pitches. She was not there.";
    case "blackmail": return "He had a quiet night at the plate, as requested.";
    case "tip_wire": return "SportsWire ran it. Page one.";
    case "kidnap_mascot": return "The mascot head is in a storage unit on Route 9.";
    case "security": return "The sweep held. No one reached the coolers.";
    case "raccoons": return "The raccoons were in place. They did not come out.";
    case "cooler": return "The cooler was ready. The players drank beer instead.";
    case "laser": return "The laser was on. The hitters were squinting.";
    case "blackout": return "The cable was cut. A backup generator came on.";
    default: return "The job was done.";
  }
}

function threatLine(kind: string, team: string): string {
  switch (kind) {
    case "church": return `The ${team} are a church club. A man named Sal handles matters like this for the church.`;
    case "trust": return `The board of the ${team} has reviewed your activities. It voted 7-0 to have you dealt with.`;
    case "mob": return `We know which ${team} games you bet on.`;
    default: return `The ${team} know who you are. We have your fax number.`;
  }
}

function nudgeLine(kind: string): string {
  return kind === "expose" ? "The story is with the SportsWire night desk. Two other people have been told."
    : kind === "inflame" ? "It was delivered. It is on the kitchen table."
    : "The people involved have calmed down. The fixer kept the receipt.";
}
