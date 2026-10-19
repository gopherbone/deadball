// One game day of the league, as pure functions over (world, season state, orders, crew):
// playGames (some of the day's games, each with its own jobs) and closeDay (storyline jobs,
// life, phases, crew timers). The League DO plays each aired game at its own first pitch
// (src/schedule.ts) and closes the day after the last one; runDay does a whole day at once for
// scripts/measure.ts and scripts/economy.ts. No Cloudflare APIs here.

import {
  Rng, simulateGame, sim, moodModifiers, usingTemp, redeemModifiers, type RedeemMods,
  type CrewMember, type EventCard, type GameResult, type GameSpec, type LifeEvent, type MailItem, type OpOrder,
  type OpOutcome, type ScheduledGame, type SeasonState, type Story, type WireLine, type World, type CrimeEffect,
} from "./sim.ts";
import { boxNotes, settleOps, coolGrudges } from "./sim.ts";
import { buildSummary, type GameSummaryRow } from "./views.ts";
import { aired, simOrder } from "./schedule.ts";

export interface PlayedGame {
  game: ScheduledGame;
  res: GameResult;
  summary: GameSummaryRow;
  stories: Story[];
  wire?: WireLine[];
  starters: { home: string; away: string };
  /** this game's jobs: outcomes, mail/cards from before first pitch, and what came after the game */
  outcomes: OpOutcome[];
  preMail: MailItem[];
  preEvents: EventCard[];
  mail: MailItem[];
  events: EventCard[];
  effects: CrimeEffect[];
  /** crime stories from afterGame (published with the game's final, like the recap) */
  crimeStories: Story[];
}

export interface DayResult {
  season: number;
  day: number;
  games: PlayedGame[];
  outcomes: OpOutcome[];
  /** mail produced before first pitch (resolveOps) */
  preMail: MailItem[];
  preEvents: EventCard[];
  /** mail/events produced after the games (afterGame) */
  mail: MailItem[];
  events: EventCard[];
  effects: CrimeEffect[];
  /** hostile owners cooling off (ownerId = account or syndicate id; the DO fans syndicate mail out) */
  grudgeMail: MailItem[];
  /** crew snapshots to persist (afterGame + tickCrew) */
  crew: CrewMember[];
  stories: Story[];
  life: LifeEvent[];
  newSeason?: SeasonState;
  offDays: number;
}

export interface DayInput {
  world: World;
  state: SeasonState;
  seed: string;
  orders: OpOrder[];
  crew: Record<string, CrewMember>;
  offDays: number;
  offseasonLength: number;
  /** Active redeemed-card boosts; applied to games involving the player's team. */
  redeemMods?: RedeemMods[];
}

export interface GamesResult {
  games: PlayedGame[];
  /** crew snapshots to persist (resolveOps + afterGame) */
  crew: CrewMember[];
}

/** Rng for one game's jobs and aftermath: per (season, day, game), so games can be played one at a time. */
const gameRng = (seed: string, season: number, day: number, id: string) => new Rng(`${seed}:${season}:${day}:${id}`);

/**
 * Play some of today's games (the League DO plays each one at its own first pitch), in the order
 * given: their jobs resolve first, then the games are simulated and recorded, then the aftermath.
 * `orders` may hold orders for other games; only these games' are used.
 */
export function playGames(inp: Pick<DayInput, "world" | "state" | "seed" | "orders" | "crew" | "redeemMods">, games: ScheduledGame[]): GamesResult {
  const { world, state, seed } = inp;
  const season = state.season, day = state.day;
  const crewSeen = new Map<string, CrewMember>();
  const out: GamesResult = { games: [], crew: [] };
  for (const g of games) {
    const rng = gameRng(seed, season, day, g.id);
    const orders = inp.orders.filter(o => o.gameId === g.id);
    const mine = orders.length ? sim.resolveOps(world, orders, inp.crew, rng.fork("ops")) : [];
    const spec: GameSpec = {
      id: g.id, day: g.day, homeId: g.homeId, awayId: g.awayId, umpireId: g.umpireId, weather: g.weather,
      modifiers: [...moodModifiers(world, g), ...mine.flatMap(o => o.modifiers ?? []), ...redeemModifiers(world, inp.redeemMods ?? [], [g.homeId, g.awayId])],
    };
    const res = simulateGame(world, spec, `${seed}:${g.id}`);
    const starters = { home: res.home.pitch[0]?.id ?? "", away: res.away.pitch[0]?.id ?? "" };
    sim.recordResult(world, state, g, res);
    const summary = buildSummary(world, res, season);
    const played: PlayedGame = {
      game: g, res, summary, starters, stories: [], outcomes: mine, preMail: mine.flatMap(o => o.mail ?? []), preEvents: mine.flatMap(o => o.events ?? []),
      mail: [], events: [], effects: [], crimeStories: [],
    };
    // major-league and Enhanced League games get recaps, wire lines and full replay logs
    if (aired(g)) {
      const notes = boxNotes(world, res);
      if (notes.length) summary.notes = notes;
      played.stories = sim.writeGameStories(world, res, g, res.incidents);
      played.wire = sim.wireLines(world, res);
    }
    if (mine.length) {
      const after = sim.afterGame(world, mine, res, rng.fork("after"));
      played.mail.push(...(after.mail ?? []));
      played.events.push(...(after.events ?? []));
      played.effects.push(...(after.effects ?? []));
      played.crimeStories.push(...(after.stories ?? []));
      for (const c of after.crew ?? []) crewSeen.set(c.id, c);
    }
    // crew who went on jobs: the snapshots resolveOps/afterGame mutated
    for (const o of mine) for (const c of (o.crew as CrewMember[] | undefined) ?? []) if (!crewSeen.has(c.id)) crewSeen.set(c.id, c);
    for (const o of orders) for (const id of o.crew) { const c = inp.crew[id]; if (c && !crewSeen.has(id)) crewSeen.set(id, c); }
    // compact the in-memory result: the log only matters for aired replays
    if (!aired(g)) res.log = [];
    out.games.push(played);
  }
  out.crew = [...crewSeen.values()];
  return out;
}

export interface CloseResult {
  season: number;
  day: number;
  /** storyline-only jobs (gameId "") */
  outcomes: OpOutcome[];
  preMail: MailItem[];
  preEvents: EventCard[];
  mail: MailItem[];
  events: EventCard[];
  effects: CrimeEffect[];
  grudgeMail: MailItem[];
  crew: CrewMember[];
  /** storyline-job stories and life stories */
  stories: Story[];
  life: LifeEvent[];
  newSeason?: SeasonState;
  offDays: number;
}

/**
 * Close the day once every game on it has been played: storyline-only jobs, grudges cooling,
 * the day rollover (life, phases, tomorrow's playoff games), crew timers.
 * `orders` are the storyline-only orders (gameId ""); `crew` every crew member that isn't idle.
 */
export function closeDay(inp: DayInput): CloseResult {
  const { world, state, seed } = inp;
  const season = state.season, day = state.day;
  const rng = new Rng(`${seed}:${season}:${day}`);
  const orders = inp.orders.filter(o => !o.gameId);
  const outcomes = orders.length ? sim.resolveOps(world, orders, inp.crew, rng.fork("ops")) : [];
  const out: CloseResult = {
    season, day, outcomes, preMail: outcomes.flatMap(o => o.mail ?? []), preEvents: outcomes.flatMap(o => o.events ?? []),
    mail: [], events: [], effects: [], grudgeMail: [], crew: [], stories: [], life: [], offDays: inp.offDays,
  };
  const crewSeen = new Map<string, CrewMember>();

  // storyline-only jobs settle once (exposure, heat, mail, cards)
  if (outcomes.length) {
    const after = settleOps(world, outcomes.map(o => ({ ...o, gameId: "" })), rng.fork("settle"));
    out.mail.push(...(after.mail ?? []));
    out.events.push(...(after.events ?? []));
    out.effects.push(...(after.effects ?? []));
    out.stories.push(...(after.stories ?? []));
    for (const c of after.crew ?? []) crewSeen.set(c.id, c);
  }

  // grudges against accounts and syndicates cool a point a week
  out.grudgeMail = coolGrudges(world).mail;

  for (const o of outcomes) for (const c of (o.crew as CrewMember[] | undefined) ?? []) if (!crewSeen.has(c.id)) crewSeen.set(c.id, c);
  for (const o of orders) for (const id of o.crew) { const c = inp.crew[id]; if (c && !crewSeen.has(id)) crewSeen.set(id, c); }

  // day rollover (life, phases)
  out.life = sim.advanceSeasonDay(world, state, rng.fork("life"));
  // the real league module rolls offseason -> new season itself; only the TEMP one needs help
  if (usingTemp.includes("advanceSeasonDay") && state.phase === "offseason" && sim.slateFor(state, state.day).length === 0) {
    out.offDays = inp.offDays + 1;
    if (out.offDays >= inp.offseasonLength) {
      out.life.push(...sim.runOffseason(world, rng.fork("offseason")));
      out.newSeason = sim.newSeason(world, rng.fork("season"));
      out.offDays = 0;
    }
  } else out.offDays = 0;
  out.stories.push(...sim.writeLifeStories(world, out.life));

  // crew timers
  for (const c of sim.tickCrew(Object.values(inp.crew), world.day)) crewSeen.set(c.id, c);
  out.crew = [...crewSeen.values()];
  return out;
}

/**
 * A whole game day in one call (scripts, tests): every game in simulation order (farm games,
 * then the aired games in first-pitch order), then the close. Same results as the League DO
 * playing the games one at a time at their first pitches and closing the day after the last.
 */
export function runDay(inp: DayInput): DayResult {
  const { state } = inp;
  const season = state.season, day = state.day;
  const played = playGames(inp, simOrder(sim.slateFor(state, day)));
  // crew snapshots from the games feed the close (tickCrew sees who came back hurt or jailed)
  const crew = { ...inp.crew };
  for (const c of played.crew) crew[c.id] = c;
  const closed = closeDay({ ...inp, crew });
  const merged = new Map<string, CrewMember>();
  for (const c of [...played.crew, ...closed.crew]) merged.set(c.id, c);
  const gs = played.games;
  return {
    season, day, games: gs,
    outcomes: [...gs.flatMap(g => g.outcomes), ...closed.outcomes],
    preMail: [...gs.flatMap(g => g.preMail), ...closed.preMail],
    preEvents: [...gs.flatMap(g => g.preEvents), ...closed.preEvents],
    mail: [...gs.flatMap(g => g.mail), ...closed.mail],
    events: [...gs.flatMap(g => g.events), ...closed.events],
    effects: [...gs.flatMap(g => g.effects), ...closed.effects],
    grudgeMail: closed.grudgeMail,
    crew: [...merged.values()],
    stories: [...gs.flatMap(g => g.crimeStories), ...closed.stories],
    life: closed.life,
    ...(closed.newSeason ? { newSeason: closed.newSeason } : {}),
    offDays: closed.offDays,
  };
}

/** Bytes-ish estimate for logging. */
export const sizeOf = (x: unknown) => JSON.stringify(x).length;
