// League calendar and competition: schedule, results, standings, playoffs (semis best-of-5, the
// Continental Series best-of-7), and the phase machine that drives the world day by day.

import type { Rng } from "../rng.ts";
import type { GameResult } from "../game.ts";
import type { Level, Player, Weather, World } from "../types.ts";
import { LEVELS } from "../types.ts";
import { applyGameToWorld, advanceDay } from "../season.ts";
import { mkEvent, type LifeEvent } from "../life/events.ts";
import { advanceLife, runOffseason } from "../life/index.ts";
import { baseballKin } from "../life/people.ts";
import { applyWeatherEffects } from "../life/worldnews.ts";
import { lifeAfterGame } from "../life/aftergame.ts";
import { seasonOpeners } from "../life/starts.ts";
import { addGameStats, careerTotals } from "./stats.ts";
import { OFFSEASON_DAYS, REGULAR_DAYS, levelTeams, makeWeather, roundRobin, seasonDate, umpirePool, type GameDate } from "./calendar.ts";
import { finishSeason, noteHeadlines } from "./history.ts";
import { MIRAGE_CUP, enhancedSchedule, enhancedTeamIds, makeExhibition } from "./enhanced.ts";

export { REGULAR_DAYS, OFFSEASON_DAYS, seasonDate, type GameDate } from "./calendar.ts";
export {
  addGameStats, careerTotals, levelLine, leaders, avg, obp, slg, ops, era, whip, ipString, rate3, batValue, pitchValue,
  emptyBat, emptyPitch, type CareerTotals, type LeaderKey,
} from "./stats.ts";
export { historyBook, headlineFor } from "./history.ts";
export { playDay, playSeason, type DayOutcome } from "./driver.ts";
export { ENHANCED_CLUBS, MIRAGE_CUP, enhancedTeams, enhancedTeamIds, mintOddball } from "./enhanced.ts";

/** Today's Enhanced League games (regular season and Mirage Cup) plus any exhibitions. */
export function enhancedSlate(world: World, state: SeasonState, day: number = state.day): ScheduledGame[] {
  return slateFor(state, day).filter(g => g.level === "EL" || g.exhibition || (world.teams[g.homeId]?.level === "EL"));
}

export interface ScheduledGame {
  id: string; season: number; day: number; level: Level; homeId: string; awayId: string; umpireId: string; weather: Weather; slot: number;
  /** Playoff games: which series and game number. */
  series?: string;
  game?: number;
  /** Enhanced vs Continental exhibition (not in standings or season stats). */
  exhibition?: boolean;
}
export interface Standing { teamId: string; w: number; l: number; gb: number; streak: string; last10: string; rs: number; ra: number }
export interface GameSummary { id: string; homeId: string; awayId: string; home: number; away: number; innings: number; w: string; l: string; s?: string }

export interface TeamRecord { w: number; l: number; rs: number; ra: number; /** "WWLW…" in order */ seq: string }

export interface Series {
  id: string;
  round: "semi" | "final";
  /** Higher seed (home-field advantage). */
  high: string;
  low: string;
  need: number;
  wins: Record<string, number>;
  games: string[];
  winner?: string;
  loser?: string;
}

export interface PlayoffState {
  seeds: string[];
  series: Series[];
  champion?: string;
  runnerUp?: string;
  /** "4-2" */
  finalScore?: string;
}

export interface SeasonState {
  season: number;
  phase: "preseason" | "regular" | "playoffs" | "offseason";
  day: number;
  schedule: ScheduledGame[];
  results: Record<string, GameSummary>;
  playoff?: PlayoffState;
  // --- additions
  /** Calendar year of this season. */
  year: number;
  /** Regular-season records by team id (all levels). */
  table: Record<string, TeamRecord>;
  /** Events produced by recordResult (debuts, milestones, injuries) waiting for the next day rollover. */
  pending: LifeEvent[];
  /** First day number of the offseason (for calendar dates). */
  offseasonStart?: number;
  /** Notable things this season, for the history book. */
  headlines: { kind: string; text: string; weight: number; who?: string[] }[];
  /** The Enhanced League's playoffs (the Mirage Cup), run alongside the Continental ones. */
  enhancedPlayoff?: PlayoffState;
}

export const SERIES_NAME = "the Continental Series";

// --- season setup ----------------------------------------------------------------------------------

export function newSeason(world: World, rng: Rng): SeasonState {
  const season = world.season;
  const year = world.year;
  const r = rng.fork(`season-${season}`);
  const schedule: ScheduledGame[] = [];
  const table: Record<string, TeamRecord> = {};
  for (const level of LEVELS) {
    const teams = levelTeams(world, level);
    for (const t of teams) table[t.id] = { w: 0, l: 0, rs: 0, ra: 0, seq: "" };
    const pairings = roundRobin(teams.map(t => t.id), r);
    const umps = umpirePool(world, level);
    const byDay = new Map<number, typeof pairings>();
    for (const p of pairings) (byDay.get(p.day) ?? byDay.set(p.day, []).get(p.day)!).push(p);
    for (const [day, games] of [...byDay.entries()].sort((a, b) => a[0] - b[0])) {
      const date = seasonDate(year, day);
      const slots = r.shuffle(games.map((_, i) => i));
      games.forEach((g, i) => {
        const slot = slots[i];
        const park = world.parks[world.teams[g.homeId].parkId];
        schedule.push({
          id: `S${season}D${day}${level}${slot}`, season, day, level, homeId: g.homeId, awayId: g.awayId,
          umpireId: umps.length ? umps[(day * games.length + i) % umps.length].id : "",
          weather: makeWeather(park, date, slot, r), slot,
        });
      });
    }
  }
  // the Enhanced League (its own stream so Continental schedules don't change)
  const er = r.fork("enhanced");
  const el = enhancedTeamIds(world);
  for (const id of el) table[id] = { w: 0, l: 0, rs: 0, ra: 0, seq: "" };
  schedule.push(...enhancedSchedule(world, season, year, er));
  // opening-eve exhibitions: two desert clubs visit (or host) Continental clubs
  const ml = levelTeams(world, "ML").map(t => t.id);
  if (el.length && ml.length) {
    const els = er.shuffle([...el]), mls = er.shuffle([...ml]);
    for (let i = 0; i < 2; i++) schedule.push(makeExhibition(world, season, year, 0, els[i], mls[i], i, er));
  }
  const order = (l: Level) => (l === "EL" ? 4 : LEVELS.indexOf(l));
  schedule.sort((a, b) => a.day - b.day || order(a.level) - order(b.level) || a.slot - b.slot);
  return { season, phase: "preseason", day: 0, schedule, results: {}, year, table, pending: [], headlines: [] };
}

export function slateFor(state: SeasonState, day: number): ScheduledGame[] {
  return state.schedule.filter(g => g.day === day);
}

/** Calendar date of a season day ("Tue, June 13, 1996"). Defaults to the current day. */
export function dateFor(world: World, state: SeasonState, day: number = state.day): GameDate {
  void world;
  return seasonDate(state.year, day, state.offseasonStart);
}

// --- results -----------------------------------------------------------------------------------------

export function recordResult(world: World, state: SeasonState, game: ScheduledGame, res: GameResult): void {
  if (state.results[game.id]) return;
  const homeWon = res.winner === "home";
  state.results[game.id] = {
    id: game.id, homeId: game.homeId, awayId: game.awayId, home: res.home.runs, away: res.away.runs, innings: res.innings,
    w: res.decisions.w, l: res.decisions.l, ...(res.decisions.s ? { s: res.decisions.s } : {}),
  };
  if (game.exhibition) {
    // counts for nothing but pride: no standings, no season stats
    applyGameToWorld(world, res);
    lifeAfterGame(world, { id: game.id, level: game.level, homeId: game.homeId, awayId: game.awayId, series: game.series, exhibition: true }, res, state.pending);
    const winner = homeWon ? game.homeId : game.awayId, loser = homeWon ? game.awayId : game.homeId;
    state.pending.push(mkEvent(world, "exhibition", [res.decisions.w, res.decisions.l].filter(Boolean), [game.homeId, game.awayId], {
      gameId: game.id, winner, loser, score: `${Math.max(res.home.runs, res.away.runs)}-${Math.min(res.home.runs, res.away.runs)}`, innings: res.innings,
      circuitWinner: world.teams[winner]?.level === "EL" ? "enhanced" : "continental",
      powersUsed: res.log.filter(e => (e as { k: string }).k === "ultra").length,
    }));
    return;
  }
  const before = game.level === "ML" ? snapshotMilestones(world, res) : undefined;
  addGameStats(world, state.season, game.level, res, !!game.series);
  applyGameToWorld(world, res);

  // pitchers' moods (game.ts folds batters' in)
  for (const box of [res.home, res.away]) {
    for (const l of box.pitch) {
      const p = world.players[l.id];
      if (!p) continue;
      const d = (res.decisions.w === l.id ? 0.6 : 0) - (res.decisions.l === l.id ? 0.5 : 0) + (res.decisions.s === l.id ? 0.4 : 0) - (l.er >= 5 ? 0.8 : 0) + (l.outs >= 21 && l.er <= 1 ? 0.6 : 0);
      p.mood = Math.max(-5, Math.min(5, p.mood * 0.9 + d));
    }
  }

  if (!game.series) {
    const h = state.table[game.homeId], a = state.table[game.awayId];
    if (h && a) {
      h.rs += res.home.runs; h.ra += res.away.runs; a.rs += res.away.runs; a.ra += res.home.runs;
      if (homeWon) { h.w++; a.l++; h.seq += "W"; a.seq += "L"; } else { a.w++; h.l++; a.seq += "W"; h.seq += "L"; }
    }
  } else {
    const s = state.playoff?.series.find(x => x.id === game.series) ?? state.enhancedPlayoff?.series.find(x => x.id === game.series);
    if (s) {
      const winner = homeWon ? game.homeId : game.awayId;
      s.wins[winner] = (s.wins[winner] ?? 0) + 1;
    }
  }

  // debuts, injuries, milestones and feats → news on the next rollover
  const teams = [game.homeId, game.awayId];
  if (game.level === "ML") {
    for (const box of [res.home, res.away]) {
      const ids = new Set([...box.bat.map(l => l.id), ...box.pitch.map(l => l.id)]);
      for (const id of ids) {
        const p = world.players[id];
        if (!p || p.debut) continue;
        p.debut = { year: state.year, season: state.season, teamId: box.teamId, gameId: game.id };
        const kin = baseballKin(world, p);
        state.pending.push(mkEvent(world, "debut", [id, ...(kin ? [kin.id] : [])], [box.teamId], {
          gameId: game.id, secondGen: !!kin, relation: kin?.relation, kin: kin?.id, age: p.age, draft: p.draft,
        }));
      }
    }
    milestones(world, state, game, res, before!);
  }
  lifeAfterGame(world, { id: game.id, level: game.level, homeId: game.homeId, awayId: game.awayId, series: game.series }, res, state.pending);
  for (const inj of res.injuries) {
    if (game.level === "ML" || inj.days >= 15) {
      state.pending.push(mkEvent(world, "injury", [inj.id], [world.players[inj.id]?.teamId ?? game.homeId], { kind: inj.kind, days: inj.days, gameId: game.id, inGame: true }));
    }
  }
  void teams;
}

interface Snap { hr: number; h: number; w: number; k: number; sv: number }

function snapshotMilestones(world: World, res: GameResult): Map<string, Snap> {
  const m = new Map<string, Snap>();
  const ids = new Set<string>();
  for (const box of [res.home, res.away]) {
    for (const l of box.bat) if (l.hr || l.h) ids.add(l.id);
    for (const l of box.pitch) if (l.k || res.decisions.w === l.id || res.decisions.s === l.id) ids.add(l.id);
  }
  for (const id of ids) {
    const c = careerTotals(world, id, "ML");
    m.set(id, { hr: c.bat.hr, h: c.bat.h, w: c.pitch.w, k: c.pitch.k, sv: c.pitch.sv });
  }
  return m;
}

const MARKS: Record<keyof Snap, number[]> = {
  hr: [100, 200, 300, 400, 500, 600, 700], h: [1000, 1500, 2000, 2500, 3000], w: [100, 150, 200, 250, 300],
  k: [1000, 1500, 2000, 2500, 3000, 3500], sv: [100, 200, 300, 400],
};
const MARK_NAME: Record<keyof Snap, string> = { hr: "home runs", h: "hits", w: "wins", k: "strikeouts", sv: "saves" };

function milestones(world: World, state: SeasonState, game: ScheduledGame, res: GameResult, before: Map<string, Snap>) {
  for (const [id, b] of before) {
    const c = careerTotals(world, id, "ML");
    const now: Snap = { hr: c.bat.hr, h: c.bat.h, w: c.pitch.w, k: c.pitch.k, sv: c.pitch.sv };
    for (const k of Object.keys(MARKS) as (keyof Snap)[]) {
      for (const m of MARKS[k]) {
        if (b[k] < m && now[k] >= m) {
          state.pending.push(mkEvent(world, "milestone", [id], [world.players[id]?.teamId ?? game.homeId], { stat: k, label: `${m} career ${MARK_NAME[k]}`, value: m, gameId: game.id }));
        }
      }
    }
  }
  // single-game feats
  for (const [box, opp] of [[res.home, res.away], [res.away, res.home]] as const) {
    for (const l of box.bat) {
      if (l.hr >= 3) state.pending.push(mkEvent(world, "milestone", [l.id], [box.teamId], { feat: `${l.hr}-homer game`, gameId: game.id }));
      if (l.h >= 5) state.pending.push(mkEvent(world, "milestone", [l.id], [box.teamId], { feat: `${l.h}-hit game`, gameId: game.id }));
    }
    if (opp.hits === 0 && res.innings >= 9) {
      const sp = box.pitch[0];
      state.pending.push(mkEvent(world, "milestone", box.pitch.map(p => p.id), [box.teamId, opp.teamId], {
        feat: box.pitch.length === 1 ? "no-hitter" : "combined no-hitter", gameId: game.id, starter: sp?.id,
      }));
    }
    for (const l of box.pitch) if (l.k >= 15) state.pending.push(mkEvent(world, "milestone", [l.id], [box.teamId], { feat: `${l.k}-strikeout game`, gameId: game.id }));
  }
}

// --- standings ---------------------------------------------------------------------------------------

export function standings(world: World, state: SeasonState, level: Level): Standing[] {
  const rows = levelTeams(world, level).map(t => {
    const r = state.table[t.id] ?? { w: 0, l: 0, rs: 0, ra: 0, seq: "" };
    const last = r.seq.slice(-10);
    const lw = [...last].filter(c => c === "W").length;
    let streak = "";
    if (r.seq.length) {
      const c = r.seq[r.seq.length - 1];
      let n = 0;
      for (let i = r.seq.length - 1; i >= 0 && r.seq[i] === c; i--) n++;
      streak = `${c}${n}`;
    }
    return { teamId: t.id, w: r.w, l: r.l, gb: 0, streak, last10: `${lw}-${last.length - lw}`, rs: r.rs, ra: r.ra };
  });
  const pct = (s: Standing) => (s.w + s.l ? s.w / (s.w + s.l) : 0.5);
  rows.sort((a, b) => pct(b) - pct(a) || (b.rs - b.ra) - (a.rs - a.ra) || b.w - a.w || (a.teamId < b.teamId ? -1 : 1));
  const lead = rows[0];
  for (const r of rows) r.gb = ((lead.w - r.w) + (r.l - lead.l)) / 2;
  return rows;
}

function winPct(state: SeasonState): Record<string, number> {
  const out: Record<string, number> = {};
  for (const [id, r] of Object.entries(state.table)) out[id] = r.w + r.l ? r.w / (r.w + r.l) : 0.5;
  return out;
}

// --- playoffs ------------------------------------------------------------------------------------------

const PATTERN: Record<number, boolean[]> = {
  3: [true, true, false, false, true],               // best of 5: 2-2-1
  4: [true, true, false, false, false, true, true],  // best of 7: 2-3-2
};

interface Bracket { key: "continental" | "enhanced"; level: Level; semis: [string, string]; final: string; name: string; slot: number }
const CONTINENTAL: Bracket = { key: "continental", level: "ML", semis: ["SF1", "SF2"], final: "CS", name: SERIES_NAME, slot: 0 };
const ENHANCED_BRACKET: Bracket = { key: "enhanced", level: "EL", semis: ["ESF1", "ESF2"], final: "ECUP", name: MIRAGE_CUP, slot: 2 };

function scheduleSeriesGame(world: World, state: SeasonState, s: Series, day: number, slot: number, rng: Rng, level: Level) {
  const n = s.games.length;
  const highHome = PATTERN[s.need][n];
  const homeId = highHome ? s.high : s.low, awayId = highHome ? s.low : s.high;
  const umps = umpirePool(world, level).sort((a, b) => b.stats.consistency - a.stats.consistency).slice(0, 8);
  const park = world.parks[world.teams[homeId].parkId];
  const date = seasonDate(state.year, day);
  const g: ScheduledGame = {
    id: `S${state.season}${s.id}G${n + 1}`, season: state.season, day, level, homeId, awayId,
    umpireId: umps.length ? umps[(day + slot) % umps.length].id : "", weather: makeWeather(park, date, Math.min(3, slot + 2), rng), slot,
    series: s.id, game: n + 1,
  };
  s.games.push(g.id);
  state.schedule.push(g);
}

function startBracket(world: World, state: SeasonState, rng: Rng, events: LifeEvent[], b: Bracket): PlayoffState | undefined {
  const table = standings(world, state, b.level);
  if (table.length < 4) return undefined;
  const seeds = table.slice(0, 4).map(s => s.teamId);
  const semi = (id: string, a: string, c: string): Series => ({ id, round: "semi", high: a, low: c, need: 3, wins: { [a]: 0, [c]: 0 }, games: [] });
  const po: PlayoffState = { seeds, series: [semi(b.semis[0], seeds[0], seeds[3]), semi(b.semis[1], seeds[1], seeds[2])] };
  po.series.forEach((s, i) => scheduleSeriesGame(world, state, s, state.day, b.slot + i, rng, b.level));
  events.push(mkEvent(world, "playoffs", [], seeds, { what: "playoffs begin", circuit: b.key, seeds, standings: table.slice(0, 4).map(s => [s.teamId, s.w, s.l]) }));
  return po;
}

function startPlayoffs(world: World, state: SeasonState, rng: Rng, events: LifeEvent[]) {
  state.phase = "playoffs";
  state.playoff = startBracket(world, state, rng, events, CONTINENTAL);
  state.enhancedPlayoff = startBracket(world, state, rng, events, ENHANCED_BRACKET);
  // the also-rans' farm seasons are over too: crown the pennant winners
  for (const lv of [...LEVELS, "EL" as Level]) {
    const top = standings(world, state, lv)[0];
    if (!top) continue;
    events.push(mkEvent(world, "season", [], [top.teamId], { what: lv === "ML" || lv === "EL" ? "regular season ends" : "pennant", level: lv, circuit: lv === "EL" ? "enhanced" : "continental", w: top.w, l: top.l }));
  }
}

/** Returns true when this bracket's champion has been decided. */
function progressBracket(world: World, state: SeasonState, rng: Rng, events: LifeEvent[], po: PlayoffState | undefined, b: Bracket): boolean {
  if (!po) return true;
  if (po.champion) return true;
  for (const s of po.series) {
    if (s.winner) continue;
    const [a, c] = [s.high, s.low];
    const w = s.wins[a] >= s.need ? a : s.wins[c] >= s.need ? c : undefined;
    if (!w) continue;
    s.winner = w;
    s.loser = w === a ? c : a;
    const score = `${s.wins[w]}-${s.wins[s.loser]}`;
    const won = b.key === "continental" ? "Continental Series won" : "Mirage Cup won";
    events.push(mkEvent(world, "playoffs", [], [w, s.loser], { what: s.round === "semi" ? "semifinal won" : won, circuit: b.key, series: s.id, winner: w, loser: s.loser, score }));
    if (s.round === "final") {
      po.champion = w;
      po.runnerUp = s.loser;
      po.finalScore = score;
      return true;
    }
  }
  const semis = po.series.filter(s => s.round === "semi");
  if (semis.every(s => s.winner) && !po.series.some(s => s.round === "final")) {
    const [w1, w2] = semis.map(s => s.winner!);
    const high = po.seeds.indexOf(w1) < po.seeds.indexOf(w2) ? w1 : w2;
    const low = high === w1 ? w2 : w1;
    po.series.push({ id: b.final, round: "final", high, low, need: 4, wins: { [high]: 0, [low]: 0 }, games: [] });
    events.push(mkEvent(world, "playoffs", [], [high, low], { what: `${b.name} set`, circuit: b.key, high, low }));
  }
  let slot = b.slot;
  for (const s of po.series) {
    if (s.winner) continue;
    const last = s.games[s.games.length - 1];
    if (last && !state.results[last]) continue; // still waiting on a game
    scheduleSeriesGame(world, state, s, state.day, slot++, rng, b.level);
  }
  return false;
}

/** On playoff days, idle Enhanced and Continental clubs sometimes play an exhibition. */
function playoffExhibitions(world: World, state: SeasonState, rng: Rng) {
  if (!rng.chance(0.3)) return;
  const busy = new Set<string>();
  for (const po of [state.playoff, state.enhancedPlayoff]) for (const s of po?.series ?? []) if (!s.winner) { busy.add(s.high); busy.add(s.low); }
  const ml = levelTeams(world, "ML").map(t => t.id).filter(id => !busy.has(id));
  const el = enhancedTeamIds(world).filter(id => !busy.has(id));
  if (!ml.length || !el.length) return;
  state.schedule.push(makeExhibition(world, state.season, state.year, state.day, rng.pick(el), rng.pick(ml), 3, rng));
}

// --- the day machine -------------------------------------------------------------------------------------

/**
 * Roll the world over to the next day: life events, rest and healing, then phase changes
 * (opening day → regular season → playoffs → offseason → next season).
 */
export function advanceSeasonDay(world: World, state: SeasonState, rng: Rng): LifeEvent[] {
  const events: LifeEvent[] = state.pending.splice(0);
  const ctx = { phase: state.phase, winPct: winPct(state), date: dateFor(world, state), day: state.day, table: state.table };
  switch (state.phase) {
    case "preseason": {
      advanceDay(world);
      state.phase = "regular";
      state.day = 1;
      events.push(mkEvent(world, "season", [], [], { what: "opening day", date: dateFor(world, state).label }));
      seasonOpeners(world, rng, events);
      break;
    }
    case "regular": {
      events.push(...advanceLife(world, rng, ctx));
      advanceDay(world);
      state.day++;
      if (state.day > REGULAR_DAYS) startPlayoffs(world, state, rng, events);
      break;
    }
    case "playoffs": {
      events.push(...advanceLife(world, rng, ctx));
      advanceDay(world);
      state.day++;
      const doneC = progressBracket(world, state, rng, events, state.playoff, CONTINENTAL);
      const doneE = progressBracket(world, state, rng, events, state.enhancedPlayoff, ENHANCED_BRACKET);
      if (!(doneC && doneE)) playoffExhibitions(world, state, rng);
      if (doneC && doneE) {
        finishSeason(world, state, events);
        state.phase = "offseason";
        state.offseasonStart = state.day;
        events.push(...runOffseason(world, rng));
      }
      break;
    }
    case "offseason": {
      events.push(...advanceLife(world, rng, { ...ctx, phase: "offseason" }));
      advanceDay(world);
      state.day++;
      if (state.day >= (state.offseasonStart ?? state.day) + OFFSEASON_DAYS) {
        world.season++;
        world.year++;
        Object.assign(state, newSeason(world, rng));
        state.playoff = undefined;
        state.enhancedPlayoff = undefined;
        state.offseasonStart = undefined;
        events.push(mkEvent(world, "season", [], [], { what: "new season", season: world.season, year: world.year }));
      }
      break;
    }
  }
  applyWeatherEffects(world, slateFor(state, state.day));
  noteHeadlines(world, state, events);
  return events;
}

/** Convenience for tools/tests: is this player on an active roster and healthy enough to play? */
export function isActive(world: World, p: Player): boolean {
  return !!world.teams[p.teamId]?.roster.includes(p.id);
}
