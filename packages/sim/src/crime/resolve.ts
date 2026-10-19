// Before first pitch: crews go to work. Orders turn into modifiers (or into trouble).

import type { Modifier } from "../modifiers.ts";
import type { World } from "../types.ts";
import { Rng } from "../rng.ts";
import { GEAR, RISK_HEAT, groupSkill, opChance, opKind, opModifiers, pickVictim, storylineNudge } from "./ops.ts";
import { nudgeStoryline } from "../life/index.ts";
import { crewName, crewRoleLabel } from "./recruit.ts";
import { arrestCard, hospitalCard, turfCard } from "./events.ts";
import type { CrewMember, MailItem, NewsHook, CrewNudge, OpOrder, OpOutcome } from "./types.ts";
import { cardPhoto, mailPhoto } from "./photos.ts";
import { bleacherBan, securityDetail, teamHostility } from "./hostility.ts";

const clamp = (x: number, lo: number, hi: number) => Math.max(lo, Math.min(hi, x));

/** The defensive job. Sweeps a club's clubhouse for the day; ops aimed at that club suffer. */
export const SECURITY_KIND = "security";

/** Ops whose intent is "hurt targetTeamId". Security protects instead. */
const isOffense = (kind: string) => kind !== SECURITY_KIND;

/** Everyone with skin in an order: the orderer plus allies whose crew went. */
export function participants(order: OpOrder, crew: Record<string, CrewMember>): string[] {
  const s = new Set<string>([order.ownerId]);
  for (const id of order.crew) {
    const c = crew[id];
    if (c) s.add(c.ownerId);
  }
  return [...s].sort();
}

/** Cost of an order (job + gear) split across participants. The orderer pays for the gear. */
export function splitCost(order: OpOrder, crew: Record<string, CrewMember>): Record<string, number> {
  const def = opKind(order.kind);
  const owners = participants(order, crew);
  const out: Record<string, number> = {};
  if (!def) return out;
  const share = Math.floor(def.cost / owners.length);
  for (const o of owners) out[o] = share;
  out[order.ownerId] += def.cost - share * owners.length;
  out[order.ownerId] += order.gear.filter(g => def.gear.includes(g)).reduce((a, g) => a + (GEAR[g]?.cost ?? 0), 0);
  return out;
}

/** May this crew member work this order? Own crew always; allied crew only on a syndicate job. */
export function crewAllowed(order: OpOrder, c: CrewMember): boolean {
  if (c.ownerId === order.ownerId) return true;
  return !!order.syndicateId && !!order.allies?.includes(c.ownerId);
}

const sideKey = (o: OpOrder) => o.syndicateId ?? `acct:${o.ownerId}`;

/** Split heat across participants (rounded up so a joint job is never free). */
export function splitHeat(total: number, owners: string[]): Record<string, number> {
  const out: Record<string, number> = {};
  const each = owners.length ? Math.ceil((total / owners.length) * 10) / 10 : 0;
  for (const o of owners) out[o] = each;
  return out;
}

/**
 * Resolve the day's orders. Pure apart from small world touches (a forged letter adds
 * marital drama; a tip sours the press on a club). Crew snapshots in the outcomes carry
 * status changes (busy / jailed / hospital) for the server to persist.
 */
export function resolveOps(world: World, orders: OpOrder[], crew: Record<string, CrewMember>, rng: Rng): OpOutcome[] {
  const day = world.day;
  // security sweeps go first so they can blunt everything else
  const sorted = [...orders].sort((a, b) => (a.kind === SECURITY_KIND ? 0 : 1) - (b.kind === SECURITY_KIND ? 0 : 1) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  const used = new Set<string>();
  const protection: Record<string, number> = {}; // `${gameId}|${teamId}` -> success penalty
  const outcomes: OpOutcome[] = [];

  // rival crews colliding: same game, opposite intents, different sides
  const collide = new Map<string, OpOrder[]>();
  for (const o of sorted) {
    if (!isOffense(o.kind) || !opKind(o.kind)) continue;
    const rivals = sorted.filter(x => x !== o && isOffense(x.kind) && x.gameId === o.gameId && sideKey(x) !== sideKey(o) && x.targetTeamId !== o.targetTeamId);
    if (rivals.length) collide.set(o.id, rivals);
  }

  for (const ord of sorted) {
    let order = ord;
    const def = opKind(order.kind);
    const r = rng.fork(`op:${order.id}`);
    const going: CrewMember[] = [];
    for (const id of order.crew) {
      const c = crew[id];
      if (!c || used.has(id) || c.status !== "free" || !crewAllowed(order, c)) continue;
      if (def && going.length >= def.slots) break;
      going.push(c);
      used.add(id);
    }
    const snaps = going.map(c => ({ ...c, skills: { ...c.skills } }));
    const owners = participants({ ...order, crew: going.map(c => c.id) }, crew);
    const base: OpOutcome = {
      orderId: order.id, success: false, modifiers: [], exposed: false, heat: 0, arrests: [], mail: [], events: [],
      ownerId: order.ownerId, kind: order.kind, gameId: order.gameId, targetTeamId: order.targetTeamId, quality: 0,
      crew: snaps, gear: order.gear, hooks: [], syndicateId: order.syndicateId, participants: owners, heatBy: {},
    };
    outcomes.push(base);
    if (!def) { base.summary = "Unknown job."; continue; }
    // storyline jobs: aim at the arc's lead and his club
    let nudgeKind: CrewNudge | undefined;
    if (order.storylineId) {
      const sl = (world.storylines ?? []).find(x => x.id === order.storylineId && !x.resolved);
      nudgeKind = sl ? storylineNudge(order, sl.kind) : undefined;
      if (sl && nudgeKind) {
        const lead = sl.people.find(id => world.players[id]);
        order = { ...order, targetTeamId: (lead && world.players[lead].teamId) || order.targetTeamId || sl.teams[0] || "", targetPlayerId: order.targetPlayerId ?? lead };
        base.targetTeamId = order.targetTeamId;
      }
    }
    if (def.storyline?.only && !nudgeKind) {
      base.summary = "No such storyline.";
      base.calledOff = true;
      base.mail.push({ id: `${order.id}:m0`, ownerId: order.ownerId, from: "The Clubhouse BBS", subject: `${def.name}: called off`, body: ["There is nothing to smooth over. The story has ended or was never ours to touch."], day, kind: "op" });
      for (const c of snaps) c.status = "free";
      continue;
    }
    const target = world.teams[order.targetTeamId];
    const tName = target ? target.name : "them";
    const mail = (to: string, subject: string, body: string[], kind: MailItem["kind"] = "op", from = "The Clubhouse BBS") =>
      base.mail.push({ id: `${order.id}:m${base.mail.length}`, ownerId: to, from, subject, body, day, kind });

    if (!snaps.length) {
      base.summary = "Nobody showed up.";
      base.calledOff = true;
      mail(order.ownerId, `${def.name}: nobody showed`, [`No one was available for the ${def.name.toLowerCase()} job against the ${tName}. The money was not spent.`]);
      continue;
    }

    // hostile owners: their ushers have our photographs (bleacher jobs at their park are off)
    const parties = [...owners, order.syndicateId];
    const ban = order.gameId ? bleacherBan(world, order.kind, order.homeTeamId, parties) : undefined;
    if (ban) {
      base.summary = "Turned away at the turnstiles.";
      base.calledOff = true;
      base.blocked = ban;
      const who = snaps.map(c => crewName(world, c)).join(", ");
      for (const c of snaps) c.status = "free";
      for (const o of owners) mail(o, `${def.name}: turned away`, [`${who} got as far as the turnstiles. The ticket taker had a photograph and compared it twice.`, ban, "The job is off. The money comes back."]);
      continue;
    }

    let { p } = opChance(world, order, snaps);
    const prot = protection[`${order.gameId}|${order.targetTeamId}`] ?? 0;
    if (isOffense(order.kind)) p = clamp(p - prot, 0.02, 0.95);
    // their security detail for us in particular
    const guard = isOffense(order.kind) ? teamHostility(world, order.targetTeamId, parties) : 0;
    if (guard) {
      p = clamp(p - securityDetail(guard).success, 0.02, 0.95);
      base.guard = guard;
    }
    base.chance = Math.round(p * 1000) / 1000;
    const u = r.float();
    const success = u < p;
    const gearQ = order.gear.filter(g => def.gear.includes(g)).reduce((a, g) => a + (GEAR[g]?.quality ?? 0), 0);
    const rivals = collide.get(order.id);
    let heat = RISK_HEAT[def.risk];
    for (const c of snaps) { c.status = "busy"; c.until = day + 1; c.jobs = (c.jobs ?? 0) + 1; }

    if (success) {
      let q = clamp(0.4 + 0.6 * (1 - u / p) + gearQ, 0.2, 1.2);
      if (rivals) q *= 0.6; // the other crew's work partly undoes ours
      base.success = true;
      base.quality = Math.round(q * 100) / 100;
      if (order.kind === SECURITY_KIND) {
        const strength = 0.12 + 0.2 * q + 0.03 * groupSkill(snaps, "muscle");
        const k = `${order.gameId}|${order.targetTeamId}`;
        protection[k] = Math.max(protection[k] ?? 0, Math.round(strength * 100) / 100);
        base.summary = `The ${tName} clubhouse is guarded today.`;
        mail(order.ownerId, `Sweep: ${tName} clubhouse is clean`, [`Our people walked the tunnels and checked the coolers. Two men with burlap sacks were turned away at the bullpen gate.`, `Jobs against the ${tName} today will be harder.`]);
      } else {
        const { mods, note: opNote } = order.gameId ? opModifiers(world, order, q) : { mods: [], note: "" };
        let note = opNote;
        base.modifiers = mods;
        if (nudgeKind && order.storylineId) {
          const strength = Math.round((1 + 2 * q) * 10) / 10;
          const applied = nudgeStoryline(world, order.storylineId, nudgeKind, strength);
          base.nudge = { storylineId: order.storylineId, kind: nudgeKind, strength, applied };
          note = note || (nudgeKind === "expose" ? "The story has been passed to people who repeat things." : nudgeKind === "inflame" ? "It was delivered. It is on the kitchen table." : "The people involved have calmed down.");
        }
        base.summary = note || `${def.name}: done.`;
        sideEffects(world, order, q, base);
        const who = snaps.map(c => crewName(world, c)).join(", ");
        for (const o of owners) mail(o, `${def.name}: done`, [note, `${who} report the job done. The game starts at 7:05.`]);
      }
    } else {
      base.summary = `${def.name}: failed.`;
      const backfire = u > p + (1 - p) * 0.55;
      if (backfire && nudgeKind === "soothe" && order.storylineId) {
        // the fixer was recognized: now it's a bigger story
        const applied = nudgeStoryline(world, order.storylineId, "expose", 1);
        base.nudge = { storylineId: order.storylineId, kind: "expose", strength: 1, applied };
      }
      const victim = snaps[r.int(snaps.length)];
      const vName = crewName(world, victim);
      if (backfire) {
        base.backfire = true;
        heat += 1;
        const caught = prot > 0 || guard > 0 ? 0.7 : 0.45;
        if (r.chance(caught)) {
          // nabbed before first pitch
          victim.status = "jailed";
          victim.until = day + 5;
          victim.heat = Math.min(10, victim.heat + 2);
          base.exposed = true;
          base.arrests.push(victim.id);
          base.summary = `${vName} was arrested at the gate.`;
          const hook: NewsHook = { kind: "arrest", day, opKind: def.kind, people: [victim.personId], targetTeamId: order.targetTeamId, gameId: order.gameId, success: false };
          base.hooks!.push(hook);
          base.events.push(arrestCard(world, base, victim, prot > 0 || guard > 0 ? "security" : "gate"));
          for (const o of owners) mail(o, `${def.name}: ${vName} arrested`, [`${vName} (${crewRoleLabel(victim)}) was stopped at the ${prot > 0 || guard > 0 ? "clubhouse door by hired security" : "service gate"} holding the ${GEAR[order.gear[0]]?.name.toLowerCase() ?? "goods"}.`, `${vName} is at the 9th Precinct. Bail has not been set.`]);
        } else if (order.opponentTeamId && ["grease_mound", "rabbit_balls", "raccoons", "cooler", "laser", "sprinklers", "lucky_glove"].includes(def.kind)) {
          // wrong dugout
          const { mods } = opModifiers(world, { ...order, targetTeamId: order.opponentTeamId, opponentTeamId: order.targetTeamId }, 0.5);
          base.modifiers = mods.map(m => ({ ...m, id: `${m.id}:oops`, note: `${m.note ?? def.name} (wrong team)` }));
          const other = world.teams[order.opponentTeamId]?.name ?? "other guys";
          base.summary = `The job was done on the ${other} by mistake.`;
          for (const o of owners) mail(o, `${def.name}: wrong dugout`, [`${vName} did the job on the ${other} dugout. The ${other} were not the target.`, "The dugouts are the same color."]);
        } else {
          victim.status = "hospital";
          victim.until = day + 3;
          base.summary = `${vName} is in the hospital.`;
          base.events.push(hospitalCard(world, base, victim));
          for (const o of owners) mail(o, `${def.name}: ${vName} hurt`, [hurtLine(def.kind, vName), "The hospital asked who is paying. We gave them your name."]);
        }
      } else {
        for (const o of owners) mail(o, `${def.name}: did not work`, [failLine(def.kind, vName, tName), "No one saw anything, as far as we know."]);
      }
    }

    if (rivals) {
      heat += 1;
      base.collision = rivals.map(x => x.id);
      for (const o of owners) {
        mail(o, "Another crew at the ballpark", [`Another crew worked the same game for the other side. Our ${def.name.toLowerCase()} was partly undone.`, "Two crews in one ballpark draw more police."], "threat", "Anonymous");
      }
      base.events.push(turfCard(world, base, rivals[0]));
    }
    if (guard) {
      // the owners' men were there for us; say so in the job mail
      const line = `The ${tName} owners had ${guard + 1} men at the gates with our photographs.`;
      for (const m of base.mail) if (m.kind === "op" && owners.includes(m.ownerId)) m.body.push(line);
    }
    base.heat = heat;
    base.heatBy = splitHeat(heat, owners);
  }
  for (const o of outcomes) {
    for (const m of o.mail) mailPhoto(m, o.kind);
    for (const e of o.events) cardPhoto(e);
  }
  return outcomes;
}

function sideEffects(world: World, order: OpOrder, q: number, out: OpOutcome) {
  const day = world.day;
  const t = world.teams[order.targetTeamId];
  if (order.kind === "love_letter") {
    const v = pickVictim(world, order);
    if (v) {
      v.mood = Math.max(-5, v.mood - (1 + 2 * q));
      const drama = v.family?.drama;
      if (Array.isArray(drama)) drama.push({ kind: "affair", with: v.family.spouse, since: day, weight: -Math.round(1 + 2 * q) });
      out.hooks!.push({ kind: "op", day, opKind: order.kind, people: [v.id], targetTeamId: order.targetTeamId, gameId: order.gameId, success: true });
    }
  } else if (order.kind === "blackmail") {
    const v = pickVictim(world, order);
    if (v) v.mood = Math.max(-5, v.mood - 1.5);
  } else if (order.kind === "tip_wire" && t) {
    bumpRelation(world, "press", t.factionId, -1, "ran the anonymous tip");
    const people = t.roster.map(id => world.players[id]).filter(p => p && p.traits.some(x => x === "DRUNK" || x === "GAMBLER" || x === "CROOKED")).slice(0, 2).map(p => p.id);
    out.hooks!.push({ kind: "tip", day, opKind: order.kind, people, targetTeamId: order.targetTeamId, gameId: order.gameId, success: true, factions: [t.factionId] });
  } else if (order.kind === "kidnap_mascot") {
    out.hooks!.push({ kind: "op", day, opKind: order.kind, people: [], targetTeamId: order.targetTeamId, gameId: order.gameId, success: true });
  }
}

export function bumpRelation(world: World, a: string, b: string, delta: number, reason: string) {
  let rel = world.relationships.find(r => (r.a === a && r.b === b) || (r.a === b && r.b === a));
  if (!rel) {
    rel = { a, b, value: 0, reason };
    world.relationships.push(rel);
  }
  rel.value = Math.max(-5, Math.min(5, rel.value + delta));
  rel.reason = reason;
}

function hurtLine(kind: string, who: string): string {
  switch (kind) {
    case "cooler": return `${who} drank from the cooler to check it. It was ready.`;
    case "blackout": return `${who} touched the live cable. ${who} is conscious.`;
    case "raccoons": return `${who} was bitten by a raccoon. The raccoon was not hurt.`;
    case "kidnap_mascot": return `The mascot resisted. ${who} has two broken ribs.`;
    case "heckle": return `${who} was struck by a souvenir bat thrown from the upper deck.`;
    case "sprinklers": return `${who} opened the main valve. The pressure was higher than expected.`;
    default: return `${who} fell from a loading dock while leaving.`;
  }
}

function failLine(kind: string, who: string, team: string): string {
  switch (kind) {
    case "bribe_ump": return `The umpire took ${who}'s envelope, counted it and handed it back. He said he would think about it.`;
    case "raccoons": return `The raccoons did not leave the sacks. ${who} waited until the eighth inning.`;
    case "laser": return `The laser batteries died in the second inning. ${who} did not bring spares.`;
    case "steal_signs": return `The ${team} changed their signs before the game. ${who} wrote down signs that meant nothing.`;
    case "tip_wire": return `SportsWire put ${who} on hold for forty minutes. The fax jammed.`;
    case "love_letter": return `The letter reached his wife. She thought it was from him.`;
    case "kidnap_mascot": return `The mascot was not in the costume. ${who} took the empty head.`;
    default: return `${who} could not get past the ${team} night watchman. The job is off.`;
  }
}

export type { Modifier };
