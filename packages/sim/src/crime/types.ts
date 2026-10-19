// Shared crime types. The signatures in docs/ARCHITECTURE.md are the contract; extra
// fields here are additive.

import type { Modifier } from "../modifiers.ts";
import type { Npc, Trait } from "../types.ts";

/** Crew skills, 0..5 (the BBS shows them as "Charm5 Nerve4"). */
export type CrewSkill = "sneak" | "charm" | "muscle" | "access" | "nerve" | "knowhow";
export const CREW_SKILLS: readonly CrewSkill[] = ["sneak", "charm", "muscle", "access", "nerve", "knowhow"];
export const SKILL_LABEL: Record<CrewSkill, string> = {
  sneak: "Sneak", charm: "Charm", muscle: "Muscle", access: "Access", nerve: "Nerve", knowhow: "Know-how",
};

export type CrewStatus = "free" | "busy" | "jailed" | "hospital" | "dead" | "turned" | "gone";

export interface CrewMember {
  id: string;
  personId: string;
  ownerId: string;
  skills: Record<CrewSkill, number>;
  /** 0..5. Low loyalty crew talk to the D.A. */
  loyalty: number;
  status: CrewStatus;
  /** 0..10. How well the cops know this face. */
  heat: number;
  /** Role key from ROLES (e.g. "organist"). */
  role?: string;
  /** Day the current status (jailed, hospital, busy) ends; the server calls tickCrew. */
  until?: number;
  /** Ops pulled off, for flavour and loyalty drift. */
  jobs?: number;
}

export interface Candidate {
  id: string;
  ownerId: string;
  day: number;
  /** The NPC, not yet in world.npcs. hireCandidate stores it. */
  person: Npc;
  role: string;
  roleLabel: string;
  skills: Record<CrewSkill, number>;
  loyalty: number;
  /** One-off signing fee in $. */
  price: number;
  /** BBS blurb: what they say about themselves. */
  pitch: string;
  traits: Trait[];
}

export type Risk = "low" | "mod" | "high" | "lol";

export interface OpKindDef {
  kind: string;
  name: string;
  blurb: string;
  cost: number;
  risk: Risk;
  /** Skill levels the crew needs, as a group (best member + help from the rest). */
  needs: Partial<Record<CrewSkill, number>>;
  /** Max crew on the job. */
  slots: number;
  gear: string[];
  /** Min crew (default 1). */
  minCrew?: number;
  /** One-line "if it works / if it fails" text for the planner. */
  ifWorks?: string;
  ifFails?: string;
  /**
   * Storyline ops: the job can aim at a storyline (OpOrder.storylineId) and nudges it through
   * life's nudgeStoryline. `kinds` = storyline kinds it works on ("any" = all); `nudge` = what it
   * does ("choice" = the order picks expose or soothe); `only` = the job needs a storyline target.
   */
  storyline?: { kinds: string[] | "any"; nudge: CrewNudge | "choice"; only?: boolean };
  /** Worked from the stands: a club whose owners hold a grudge against you can ban you (hostility.ts). */
  bleachers?: boolean;
}

export type CrewNudge = "expose" | "inflame" | "soothe";

export interface GearDef {
  id: string;
  name: string;
  cost: number;
  /** Added to the success probability. */
  success?: number;
  /** Added to effect quality on success. */
  quality?: number;
  /** Multiplies exposure chance (<1 is good). */
  exposure?: number;
  /** Skill bumps while carried. */
  skills?: Partial<Record<CrewSkill, number>>;
  note: string;
}

export interface OpOrder {
  id: string;
  ownerId: string;
  kind: string;
  gameId: string;
  targetTeamId: string;
  crew: string[];
  gear: string[];
  placedDay: number;
  /** Optional game context the server should fill in from the schedule. Some ops
   * (rabbit balls, stolen signs) help the other club's hitters; bribes need the umpire. */
  opponentTeamId?: string;
  umpireId?: string;
  /** The home club (whose park it is): bleacher bans. The server fills it in from the schedule. */
  homeTeamId?: string;
  /** Optional: a specific player to aim at (blackmail, love letter). */
  targetPlayerId?: string;
  /** Syndicate job: crew from `allies` (owner ids in the same syndicate) may join. */
  syndicateId?: string;
  allies?: string[];
  /** Storyline ops: the storyline to work on (public, rumoured, or a secret one learned from a tip). */
  storylineId?: string;
  /** For ops whose storyline nudge is "choice" (blackmail): expose or soothe. Default expose. */
  nudge?: CrewNudge;
}

export interface MailItem {
  id: string;
  ownerId: string;
  from: string;
  fromFace?: string;
  subject: string;
  body: string[];
  day: number;
  kind: "tip" | "op" | "league" | "bank" | "fan" | "threat";
  /** Tips only: true when the rumour is real (never sent to the client). */
  truth?: boolean;
  /** Tips about a storyline: the server records it as known to this account (unlocks storyline ops on secret arcs). */
  storylineId?: string;
  /** Archive picture id (archive.ts): client draws images/archive/<photo>-<w>.png. */
  photo?: string;
  photoCaption?: string;
}

export interface EventChoice { key: string; label: string; cost?: number; heat?: number; note?: string }

export interface EventCard {
  id: string;
  ownerId: string;
  title: string;
  body: string;
  faceId?: string;
  choices: EventChoice[];
  /** What kind of trouble; drives resolveChoice. */
  kind?: "arrest" | "snitch" | "heat" | "hospital" | "named";
  day?: number;
  /** Choice taken if the owner never answers. */
  defaultKey?: string;
  ctx?: EventCtx;
  /** Archive picture id (archive.ts): client draws images/archive/<photo>-<w>.png. */
  photo?: string;
  photoCaption?: string;
}

export interface EventCtx {
  orderId?: string;
  opKind?: string;
  crewId?: string;
  personId?: string;
  targetTeamId?: string;
  gameId?: string;
  risk?: Risk;
  /** Snapshot of the crew member, so the card resolves without server lookups. */
  crew?: CrewMember;
  /** Owners in on the job (syndicate allies can be named by a snitch). */
  participants?: string[];
  syndicateId?: string;
  /** Turf war: the rival order. */
  rivalOrderId?: string;
  rivalOwnerId?: string;
  /** Fine amount for league notices. */
  fine?: number;
}

/** State changes the server applies after resolveChoice / afterGame. */
export type CrimeEffect =
  | { kind: "money"; ownerId: string; delta: number; why: string }
  | { kind: "heat"; ownerId: string; delta: number; why: string }
  | { kind: "crew"; crewId: string; status: CrewStatus; until?: number; loyalty?: number; heat?: number }
  | { kind: "story"; hook: NewsHook }
  | { kind: "relation"; a: string; b: string; delta: number; reason: string };

/** What the newsroom needs to write a scandal story about crime. */
export interface NewsHook {
  kind: "exposed" | "arrest" | "tip" | "deal" | "judge" | "skipped" | "convicted" | "acquitted" | "op";
  day: number;
  opKind: string;
  /** Person ids of crew members (never account names). */
  people: string[];
  targetTeamId: string;
  gameId?: string;
  /** Extra faction ids to quote. */
  factions?: string[];
  success?: boolean;
}

export interface OpOutcome {
  orderId: string;
  success: boolean;
  modifiers: Modifier[];
  exposed: boolean;
  heat: number;
  arrests: string[];
  mail: MailItem[];
  events: EventCard[];
  // --- additive context for afterGame and the server
  ownerId?: string;
  kind?: string;
  gameId?: string;
  targetTeamId?: string;
  /** 0..1.2, how well it went (0 on failure). */
  quality?: number;
  /** Probability shown to the planner at resolve time. */
  chance?: number;
  backfire?: boolean;
  /** Snapshots of the crew who went (status updated in place by afterGame). */
  crew?: CrewMember[];
  gear?: string[];
  hooks?: NewsHook[];
  /** One-line result for OpView.result. */
  summary?: string;
  syndicateId?: string;
  /** Owner ids whose crew went (orderer first is not guaranteed; sorted). */
  participants?: string[];
  /** Heat per participating owner (joint jobs split it). */
  heatBy?: Record<string, number>;
  /** Rival order ids working the same game the other way. */
  collision?: string[];
  /** Storyline ops: the nudge applied (applied false if the arc was gone or the job failed). */
  nudge?: { storylineId: string; kind: CrewNudge; strength: number; applied: boolean };
  /** Hostility of the target club's owners toward this side (hostility.ts): their security detail. */
  guard?: number;
  /** The job never started (nobody free, the story was over, banned at the turnstiles): the server refunds it. */
  calledOff?: boolean;
  /** Why it was called off at the gate (a bleacher ban). */
  blocked?: string;
}
