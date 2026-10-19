// The server's single entry point into @deadball/sim. Every other server file imports
// sim functionality from here, never from @deadball/sim directly.
//
// Contract types mirror docs/ARCHITECTURE.md; the server codes against these, and the
// real module functions are checked against them at compile time.

import * as Sim from "@deadball/sim";
import type { GameResult, Level, Modifier, Rng, Weather, World } from "@deadball/sim";

export { Rng, generateWorld, simulateGame, ModSet, INCIDENTS, buildStaff, pickStarter, normalizeName, isReservedName, writeScandalStory, houseName, moodNote } from "@deadball/sim";
// redeemable cards
export { performRedeem, checkRedeem, redeemModifiers, redeemFor, redeemLabel } from "@deadball/sim";
export type { Card as SimCard, Redeem, RedeemMods, RedeemResult, RedeemRefusal } from "@deadball/sim";
// drama: storylines, prop markets, rumours
export { bettableStorylines, resolveProps, propsFor, STORYLINE_KINDS, rumorLine, rumorLines, bbsPosts, dramaTips, boxNotes } from "@deadball/sim";
// storyline ops (crew jobs on drama arcs)
export { storylineTargets, storylineAllowed, storylineNudge, settleOps } from "@deadball/sim";
export type { StorylineTarget } from "@deadball/sim";
// hostile owners (grudges from exposed jobs) and syndicate cost sharing
export { coolGrudges, leanOnPress, grudgeParties, grudgesAgainst, bleacherBan, angerFaction, grudge, splitCost, BAN_AT } from "@deadball/sim";
export type { PressParty, PlannerCtx } from "@deadball/sim";
export type { Storyline, PropQuestion, BbsPost } from "@deadball/sim";
export type { World, GameSpec, GameResult, LogEv, TeamBox, Modifier, Level, Player, Npc, Person, Team, Park, Weather } from "@deadball/sim";

// ---------------------------------------------------------------- contract types
export interface LifeEvent { id: string; day: number; kind: string; who: string[]; teams?: string[]; data?: Record<string, unknown> }
export interface ScheduledGame { id: string; season: number; day: number; level: Level; homeId: string; awayId: string; umpireId: string; weather: Weather; slot: number; series?: string; exhibition?: boolean }
/** Playoff bracket (league PlayoffState): the Continental Series and the Mirage Cup. */
export interface PlayoffLike { seeds: string[]; series: { id: string; round: "semi" | "final"; high: string; low: string; need: number; wins: Record<string, number>; games: string[]; winner?: string; loser?: string }[]; champion?: string; runnerUp?: string; finalScore?: string }
export interface Standing { teamId: string; w: number; l: number; gb: number; streak: string; last10: string; rs: number; ra: number }
export interface GameSummary { id: string; homeId: string; awayId: string; home: number; away: number; innings: number; w: string; l: string; s?: string }
export interface SeasonState { season: number; phase: "preseason" | "regular" | "playoffs" | "offseason"; day: number; schedule: ScheduledGame[]; results: Record<string, GameSummary>; playoff?: PlayoffLike; enhancedPlayoff?: PlayoffLike }

// crime types come straight from the crime module (richer than the contract)
export type { CrewSkill, CrewMember, OpKindDef, OpOrder, EventCard, MailItem, OpOutcome, Candidate, CrimeEffect } from "@deadball/sim";
import type { CrewMember, OpKindDef, OpOrder, EventCard, MailItem, OpOutcome, Candidate, CrimeEffect, AfterGameResult, ChoiceResult, TipOpts, PlannerCtx } from "@deadball/sim";

export interface Story { id: string; day: number; kind: "recap" | "scandal" | "life" | "trade" | "feature" | "brief"; headline: string; dek: string; body: string[]; faceIds: string[]; people: string[]; teams: string[]; gameId?: string; section?: string; photo?: string; photoCaption?: string; prominence?: number }
export interface WireLine { i: number; text: string }

export interface CommentTemplate { id: string; text: string; slots: string[] }
export interface CommentDraft { template: string; words: string[] }

export interface CardDef { id: string; personId: string; season: number; set: string; number: number; rarity: string; variant?: string }
export interface Card extends CardDef { serial?: number; printRun?: number; photo?: string; photoCaption?: string; redeem?: import("@deadball/sim").Redeem; finalSeason?: boolean }
export interface PackDef { kind: string; name: string; price: number; count: number; odds: Record<string, number>; blurb?: string }

// ---------------------------------------------------------------- module surface
interface Modules {
  newSeason(world: World, rng: Rng): SeasonState;
  slateFor(state: SeasonState, day: number): ScheduledGame[];
  recordResult(world: World, state: SeasonState, game: ScheduledGame, res: GameResult): void;
  standings(world: World, state: SeasonState, level: Level): Standing[];
  advanceSeasonDay(world: World, state: SeasonState, rng: Rng): LifeEvent[];
  runOffseason(world: World, rng: Rng): LifeEvent[];

  OP_KINDS: OpKindDef[];
  recruitPool(world: World, ownerId: string, day: number, rng?: Rng): Candidate[];
  resolveOps(world: World, orders: OpOrder[], crew: Record<string, CrewMember>, rng: Rng): OpOutcome[];
  afterGame(world: World, outcomes: OpOutcome[], res: GameResult, rng: Rng): AfterGameResult;
  resolveChoice(world: World, card: EventCard, key: string, rng: Rng): ChoiceResult;

  writeGameStories(world: World, res: GameResult, game: ScheduledGame, incidents: GameResult["incidents"]): Story[];
  writeLifeStories(world: World, events: LifeEvent[]): Story[];
  wireLines(world: World, res: GameResult): WireLine[];

  vocabulary(world: World): Record<string, string[]>;
  validateComment(world: World, d: CommentDraft): { ok: true; text: string } | { ok: false; reason: string };
  checkAccountName(name: string): { ok: true; name: string } | { ok: false; reason: string };

  PACKS: PackDef[];
  setFor(world: World, season: number): CardDef[];
  openPack(world: World, season: number, kind: string, rng: Rng, mint: (defId: string) => number, set?: CardDef[]): Card[];
  cardBack(world: World, card: Card): { lines: string[]; stats: string[][] };
  cardValue(world: World, card: Card): number;
  cardFront(world: World, card: Card): { caption: string; pos: string; team?: string; rarity: string; serial?: string; misprint?: string; redeem?: string; finalSeason?: boolean };

  // additive crime helpers (not in the ARCHITECTURE contract, provided by the crime module)
  hireCandidate(world: World, cand: Candidate): CrewMember;
  tickCrew(crew: CrewMember[], day: number): CrewMember[];
  leakTips(world: World, orders: OpOrder[], recipients: string[], day: number, rng: Rng, opts?: TipOpts): MailItem[];
  opPlannerView(world: World, kind: string, targetTeamId: string, crew: CrewMember[], gear: string[], umpireId?: string, ctx?: PlannerCtx): OpPlannerView | undefined;
}

export interface OpPlannerView { kind: string; name: string; blurb: string; cost: number; risk: string; slots: number; needs: string; gear: { id: string; name: string; cost: number }[]; successPct: number; blocked?: string; [k: string]: unknown }


/**
 * The sim modules, statically imported and checked against the contract above
 * (`satisfies Modules`): a signature drift in a sim module is a server compile error.
 */
export const sim = {
  newSeason: Sim.newSeason, slateFor: Sim.slateFor, recordResult: Sim.recordResult, standings: Sim.standings,
  advanceSeasonDay: Sim.advanceSeasonDay, runOffseason: Sim.runOffseason,
  OP_KINDS: Sim.OP_KINDS, recruitPool: Sim.recruitPool, resolveOps: Sim.resolveOps, afterGame: Sim.afterGame, resolveChoice: Sim.resolveChoice,
  writeGameStories: Sim.writeGameStories, writeLifeStories: Sim.writeLifeStories, wireLines: Sim.wireLines,
  vocabulary: Sim.vocabulary, validateComment: Sim.validateComment, checkAccountName: Sim.checkAccountName,
  PACKS: Sim.PACKS, setFor: Sim.setFor, openPack: Sim.openPack, cardBack: Sim.cardBack, cardValue: Sim.cardValue, cardFront: Sim.cardFront,
  hireCandidate: Sim.hireCandidate, tickCrew: Sim.tickCrew, leakTips: Sim.leakTips, opPlannerView: Sim.opPlannerView,
} satisfies Modules as unknown as Modules;

/** Kept for /v1/admin/status: sim functions still served by TEMP stand-ins (none). */
export const usingTemp: string[] = [];

/** Comment templates: the social module's export name isn't fixed by the contract. */
export function commentTemplates(): CommentTemplate[] {
  return Sim.TEMPLATES;
}

/** Gear catalogue (id -> name/cost), if the crime module exports one. */
export function gearInfo(id: string): { name: string; cost: number } {
  const hit = (Sim.GEAR as Record<string, { name?: string; cost?: number } | undefined>)[id];
  return { name: hit?.name ?? id.replace(/_/g, " "), cost: hit?.cost ?? 0 };
}

/**
 * Mood and drama modifiers for a scheduled game (docs/DRAMA.md "Per-game modifiers"). Passing the
 * game turns on the contextual ones: night games, playoffs (`series`), grudges vs the opponent,
 * brawl heat and hidden point shaving. Same as `dramaModifiers(world, game)`.
 */
export function moodModifiers(world: World, game: ScheduledGame): Modifier[] {
  return Sim.dramaModifiers(world, game);
}
