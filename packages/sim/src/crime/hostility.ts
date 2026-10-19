// Hostile owners. An exposed job turns the wronged club's owners against the account that
// ordered it, every ally whose crew went, and their syndicate. The grudge is a relationship
// (kind "grudge", faction <-> account or syndicate id, -1..-5), cools by one point every
// GRUDGE_COOL_DAYS, and while it lasts the owners act on it:
//   1+  security details against your jobs on their clubs (success down, exposure up, by level)
//   2+  your photograph at their turnstiles: no bleacher jobs at their home games
//   any now and then they lean on SportsWire: an unflattering item about your crew, more heat
// Everything here is pure; the server stores nothing extra (the grudge rides in the world).

import type { Relationship, World } from "../types.ts";
import { Rng } from "../rng.ts";
import { relation, setRelation } from "../life/people.ts";
import { opKind } from "./ops.ts";
import { article, dateLine, faces, fit, fullName, lastName, midName, parkName, person, pro, roleLabel, weekday } from "../news/util.ts";
import { DEK_MAX, HEADLINE_MAX, type Story } from "../news/types.ts";
import type { CrewMember, CrimeEffect, MailItem } from "./types.ts";

/** Days per point of cooling. A 5-point grudge is gone in five weeks of quiet. */
export const GRUDGE_COOL_DAYS = 7;
export const GRUDGE_MAX = 5;
/** Hostility at which a club bans you from its bleachers. */
export const BAN_AT = 2;
/** Hostility at which the owners start calling SportsWire about you more often. */
export const PRESS_AT = 4;

const isPerson = (world: World, id: string) => !!(world.players[id] || world.npcs[id] || world.archive?.[id]);

/** How much a faction hates one party (account or syndicate id): 0..5. */
export function grudge(world: World, factionId: string | undefined, partyId: string | undefined): number {
  if (!factionId || !partyId) return 0;
  const v = relation(world, factionId, partyId);
  return v < 0 ? Math.min(GRUDGE_MAX, -v) : 0;
}

/** The worst grudge a faction holds against any of these parties (an order's accounts and its syndicate). */
export function hostility(world: World, factionId: string | undefined, parties: (string | undefined)[]): number {
  let h = 0;
  for (const p of parties) h = Math.max(h, grudge(world, factionId, p));
  return h;
}

/** Hostility of the owners of a club. */
export function teamHostility(world: World, teamId: string | undefined, parties: (string | undefined)[]): number {
  return hostility(world, teamId ? world.teams[teamId]?.factionId : undefined, parties);
}

/** Make a faction angrier at a party by `delta` (> 0). Returns the grudge before and after. */
export function angerFaction(world: World, factionId: string, partyId: string, delta: number, reason: string): { before: number; after: number } {
  const before = grudge(world, factionId, partyId);
  setRelation(world, factionId, partyId, Math.max(-GRUDGE_MAX, relation(world, factionId, partyId) - delta), reason, "grudge");
  return { before, after: grudge(world, factionId, partyId) };
}

/** What a security detail does to a job at this hostility: success penalty and exposure multiplier. */
export function securityDetail(h: number): { success: number; exposure: number } {
  const lv = Math.max(0, Math.min(GRUDGE_MAX, h));
  return { success: Math.round(0.04 * lv * 100) / 100, exposure: Math.round((1 + 0.12 * lv) * 100) / 100 };
}

const factionName = (world: World, fid: string | undefined) => (fid && world.factions[fid]?.name) || "the owners";

/** One-line planner note for a guarded club, or undefined. */
export function guardNote(world: World, targetTeamId: string | undefined, parties: (string | undefined)[]): string | undefined {
  const t = targetTeamId ? world.teams[targetTeamId] : undefined;
  const h = teamHostility(world, targetTeamId, parties);
  if (!t || !h) return undefined;
  return `${factionName(world, t.factionId)} has guards out for you (-${Math.round(securityDetail(h).success * 100)}%)`;
}

/**
 * Bleacher ban: bleacher jobs (laser, heckle squad, sign stealing) can't work a game at a park
 * whose owners hold a grudge of BAN_AT or more against the order's side. Returns the reason
 * the planner shows, or undefined if the job may go ahead.
 */
export function bleacherBan(world: World, kind: string, homeTeamId: string | undefined, parties: (string | undefined)[]): string | undefined {
  if (!opKind(kind)?.bleachers || !homeTeamId) return undefined;
  const t = world.teams[homeTeamId];
  if (!t || teamHostility(world, homeTeamId, parties) < BAN_AT) return undefined;
  return `Banned from the ${parkName(world, homeTeamId)} bleachers by ${midName(factionName(world, t.factionId))}.`;
}

/** Ids of every account or syndicate some faction holds a grudge against. */
export function grudgeParties(world: World): string[] {
  const out = new Set<string>();
  for (const r of world.relationships) {
    const g = grudgeSides(world, r);
    if (g && r.value < 0) out.add(g[1]);
  }
  return [...out].sort();
}

/** Every grudge held against these parties, worst first: { factionId, partyId, level }. */
export function grudgesAgainst(world: World, parties: (string | undefined)[]): { factionId: string; partyId: string; level: number }[] {
  const want = new Set(parties.filter((p): p is string => !!p));
  const out: { factionId: string; partyId: string; level: number }[] = [];
  for (const r of world.relationships) {
    const g = grudgeSides(world, r);
    if (g && r.value < 0 && want.has(g[1])) out.push({ factionId: g[0], partyId: g[1], level: Math.min(GRUDGE_MAX, -r.value) });
  }
  return out.sort((a, b) => b.level - a.level || (a.factionId < b.factionId ? -1 : 1));
}

/** [factionId, partyId] if this relationship is a faction's grudge against an account or syndicate. */
function grudgeSides(world: World, r: Relationship): [string, string] | undefined {
  if (r.kind !== undefined && r.kind !== "grudge") return undefined;
  const [f, p] = world.factions[r.a] ? [r.a, r.b] : world.factions[r.b] ? [r.b, r.a] : [undefined, undefined];
  if (!f || !p || world.factions[p] || p === "press" || isPerson(world, p)) return undefined;
  return [f, p];
}

export interface GrudgeChange { factionId: string; partyId: string; from: number; to: number }

/**
 * Daily: every grudge against an account or syndicate cools by a point once it has gone
 * GRUDGE_COOL_DAYS without a new offence (angerFaction resets the timer). Grudges that reach 0
 * are dropped. Returns what changed and the mail that goes with it (ownerId = the party; the
 * server fans a syndicate's mail out to its members).
 */
export function coolGrudges(world: World): { changes: GrudgeChange[]; mail: MailItem[] } {
  const changes: GrudgeChange[] = [];
  const drop = new Set<Relationship>();
  for (const r of world.relationships) {
    const g = grudgeSides(world, r);
    if (!g || r.value >= 0) continue;
    if (r.since === undefined || r.since > world.day) { r.since = world.day; continue; }
    if (world.day - r.since < GRUDGE_COOL_DAYS) continue;
    const from = Math.min(GRUDGE_MAX, -r.value);
    r.value += 1;
    r.since = world.day;
    if (r.value >= 0) drop.add(r);
    changes.push({ factionId: g[0], partyId: g[1], from, to: Math.max(0, -r.value) });
  }
  if (drop.size) world.relationships = world.relationships.filter(r => !drop.has(r));
  const mail = changes.flatMap(c => grudgeMail(world, c.factionId, c.partyId, c.from, c.to, `cool:${world.day}`));
  return { changes, mail };
}

function leaderOf(world: World, fid: string): { name: string; face?: string } {
  const f = world.factions[fid];
  const l = f?.leaderId ? world.npcs[f.leaderId] ?? world.players[f.leaderId] : undefined;
  return l ? { name: `${l.first} ${l.last}`, face: l.face } : { name: f?.name ?? "A friend" };
}

/** The clubs a faction owns at the top level (their parks are the ones that matter). */
function homeClub(world: World, fid: string): string | undefined {
  const ts = Object.values(world.teams).filter(t => t.factionId === fid).sort((a, b) => (a.level === "ML" ? 0 : 1) - (b.level === "ML" ? 0 : 1) || (a.id < b.id ? -1 : 1));
  return ts[0]?.id;
}

/**
 * Mail for a grudge crossing a threshold, either way. Deadpan, from the faction's leader on
 * the way up and from the front office on the way down. `tag` keeps ids unique per cause.
 */
export function grudgeMail(world: World, factionId: string, ownerId: string, before: number, after: number, tag: string): MailItem[] {
  const out: MailItem[] = [];
  const day = world.day;
  const lead = leaderOf(world, factionId);
  const club = homeClub(world, factionId);
  const park = parkName(world, club);
  const fname = factionName(world, factionId);
  const add = (key: string, subject: string, body: string[], kind: MailItem["kind"], from = lead.name, face = lead.face) =>
    out.push({ id: `grudge:${tag}:${factionId}:${ownerId}:${key}`, ownerId, from, ...(face ? { fromFace: face } : {}), subject, body, day, kind });
  if (after > before) {
    if (before < 1 && after >= 1) add("guards", "We have hired some people", [
      `We have posted men at the gates and in the tunnels of every club owned by ${midName(fname)}. They have your description.`,
      "They are paid by the hour. They have nothing else to do.",
    ], "threat");
    if (before < BAN_AT && after >= BAN_AT) add("ban", "Your photograph", [
      `Your crew's photographs are now taped inside every ticket booth at ${park}.`,
      "The ushers have been told. The bleachers are closed to you until further notice.",
    ], "threat");
    if (before < PRESS_AT && after >= PRESS_AT) add("press", "Lunch with SportsWire", [
      `${lead.name} had lunch with the SportsWire sports editor on ${weekday(world, day) || "Tuesday"}. They had the veal.`,
      "Expect to read about yourself.",
    ], "threat");
  } else if (after < before) {
    const office = `${fname} Front Office`;
    if (before >= BAN_AT && after < BAN_AT) add("unban", "Notice to ticket holders", [
      `The photographs at ${park} have been taken down. They were fading.`,
      "You may buy a bleacher seat like anyone else. You will be watched like anyone else.",
    ], "league", office, undefined);
    if (after === 0) add("calm", "Security detail", [
      `${fname} has sent its extra guards home. The overtime was not in the budget.`,
    ], "league", office, undefined);
  }
  return out;
}

export interface PressParty {
  ownerId: string;
  syndicateId?: string;
  /** The owner's crew (snapshots), for names; the item names a crew member, never the account. */
  crew: CrewMember[];
}

export interface PressResult { stories: Story[]; mail: MailItem[]; effects: CrimeEffect[] }

/**
 * Daily: hostile owners lean on SportsWire. Each account with a grudge against it has a
 * 4% chance per point of the worst grudge (20% at 5) of an unflattering brief about one of its
 * crew, plus heat (+1, +2 from PRESS_AT). Deterministic for a given rng.
 */
export function leanOnPress(world: World, parties: PressParty[], rng: Rng): PressResult {
  const out: PressResult = { stories: [], mail: [], effects: [] };
  const day = world.day;
  for (const party of [...parties].sort((a, b) => (a.ownerId < b.ownerId ? -1 : 1))) {
    const worst = grudgesAgainst(world, [party.ownerId, party.syndicateId])[0];
    if (!worst) continue;
    const r = rng.fork(`press:${party.ownerId}`);
    if (!r.chance(0.04 * worst.level)) continue;
    const fid = worst.factionId;
    const heat = worst.level >= PRESS_AT ? 2 : 1;
    out.effects.push({ kind: "heat", ownerId: party.ownerId, delta: heat, why: "SportsWire" });
    const crew = party.crew.filter(c => c.status !== "dead" && c.status !== "gone" && person(world, c.personId))
      .sort((a, b) => b.heat - a.heat || (a.id < b.id ? -1 : 1));
    const who = crew.length ? crew[r.int(Math.min(2, crew.length))] : undefined;
    const lead = leaderOf(world, fid);
    if (who) {
      const s = pressStory(world, fid, who, r);
      out.stories.push(s);
      out.mail.push({
        id: `press:${day}:${party.ownerId}`, ownerId: party.ownerId, from: lead.name, ...(lead.face ? { fromFace: lead.face } : {}),
        subject: "Page 6", kind: "threat", day,
        body: [`SportsWire ran an item about ${fullName(world, who.personId, false)} this morning. ${lead.name} did not deny calling it in.`, `The police read SportsWire too. (+${heat} heat)`],
      });
    } else {
      out.mail.push({
        id: `press:${day}:${party.ownerId}`, ownerId: party.ownerId, from: lead.name, ...(lead.face ? { fromFace: lead.face } : {}),
        subject: "A phone call", kind: "threat", day,
        body: [`${lead.name} called the police about you. They had nobody to name, so they described your car.`, `(+${heat} heat)`],
      });
    }
  }
  return out;
}

function pressStory(world: World, fid: string, c: CrewMember, rng: Rng): Story {
  const day = world.day;
  const pid = c.personId;
  const p = person(world, pid);
  const last = lastName(world, pid);
  const role = roleLabel(world, pid);
  const Role = role.charAt(0).toUpperCase() + role.slice(1);
  const club = homeClub(world, fid);
  const park = parkName(world, club);
  const fname = factionName(world, fid);
  const lead = leaderOf(world, fid);
  const wd = weekday(world, day) || "Tuesday";
  const headline = fit(rng.shuffle([
    `${Role} ${last} Seen Near ${park}`,
    `${park} Ushers Given Photograph of ${last}`,
    `Questions About ${Role} ${last}`,
    `${last} Not Welcome at ${park}`,
  ]), HEADLINE_MAX);
  const dek = fit([`${fname} says it "has concerns" about ${article(role)} seen near the turnstiles`, `${fname} says it "has concerns"`], DEK_MAX);
  const body = [
    `${fullName(world, pid, true)}, ${p?.age ?? "age unknown"}, ${article(role)}, was seen near ${park} on ${wd}, according to a person familiar with the club's security arrangements.`,
    rng.pick([
      `"We have nothing against ${role}s as a group," said ${lead.name}.`,
      `${lead.name} said the club keeps "a file" on ${last}. The file was described as thick.`,
      `${lead.name} declined to say who had called SportsWire. The call came from the club's offices.`,
    ]),
    rng.pick([
      `${last} could not be reached. A neighbor said ${pro(p)} keeps irregular hours.`,
      `Police said they were aware of ${last}. They did not say how.`,
      `${last} has no listed telephone number. ${pro(p).charAt(0).toUpperCase() + pro(p).slice(1)} has two unlisted ones.`,
    ]),
  ];
  return {
    id: `press-${day}-${pid}`, day, kind: "brief", headline, dek, body, faceIds: faces(world, [pid]), people: [pid], teams: club ? [club] : [],
    section: "Crime", dateline: dateLine(world, day), prominence: 0.6,
  };
}
