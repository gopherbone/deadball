// The League Durable Object: owns the World and SeasonState, runs the day clock on its
// alarm, and serves the whole /v1 API (the Worker forwards every request here).
//
// Day timeline (dayMs = GAME_DAY_MS, preMs = 25%, airMs = AIR_MS or 70% of dayMs; src/schedule.ts):
//   dayStart ──preMs── g0 ──s── g1 ──s── ... g(n-1) ──s── next dayStart
// Every aired game has its own first pitch (ML and EL rotated, s = (dayMs - preMs) / n) and airs
// for airMs. At a game's first pitch: its jobs resolve, it's simulated and recorded, its log goes
// to R2; its recap, crime stories, post-game mail and cards are stamped with ITS final (first
// pitch + air). When it leaves the air its pool settles. Right after the day's last aired game is
// simulated the day closes (storyline jobs, life, phases, tomorrow's playoff games), its news
// stamped with the day's last final; tomorrow's games pitch from the next dayStart + preMs while
// today's last broadcasts are still on. Bets and op orders for a game are accepted until its first pitch.

import { DurableObject } from "cloudflare:workers";
import { BlobStore } from "./store.ts";
import { StatsStore } from "./stats.ts";
import { closeDay, playGames, type CloseResult } from "./day.ts";
import {
  sim, generateWorld, Rng, usingTemp, buildStaff, pickStarter, writeScandalStory, bbsPosts, rumorLines, dramaTips, grudgeParties, leanOnPress, type LifeEvent,
  type CardDef, type CrewMember, type EventCard, type MailItem, type OpOrder, type OpOutcome, type ScheduledGame, type SeasonState, type Story, type World, type CrimeEffect,
} from "./sim.ts";
import { personRef, pitcherLine } from "./views.ts";
import { type Env, errorResponse, newId } from "./http.ts";
import { route } from "./router.ts";
import { activeRedeemMods, flushRedemptions } from "./redeem.ts";
import { nextAuctionEnd, settleDue } from "./routes/market.ts";
import { propRetimeStmts, propSyncStmts, settleProps } from "./routes/props.ts";
import { expireStmts, refundStmts } from "./routes/chipin.ts";
import { aired, dayTimes, simOrder, type DayTiming, type Pitch } from "./schedule.ts";
import { bettableLevel, fairHome, gameWaves, parseWaves, regularsLine, rivals, settleMath, teamForm, visible, type TeamRecord } from "./house.ts";

export interface Clock {
  /** 2 = staggered first pitches. Older clocks ({ next, playAt, finalAt, curDay, curDayStart }) are converted at boot. */
  v: 2;
  /** start of state.day (the day being played): its games pitch from curDayStart + preMs */
  curDayStart: number;
  /** the last closed day, shown until curDayStart */
  prevDay: number;
  prevSeason: number;
  /** when the last closed day's news is out (its last broadcast ends): drama props settle then; 0 = nothing pending */
  finalAt: number;
  offDays: number;
}

/** The clock before staggered first pitches (one shared first pitch a day). */
interface LegacyClock { curDay: number; curDayStart: number; next: "play" | "final"; playAt: number; finalAt: number; offDays: number }

export interface TickStats { kind: string; day: number; games: number; rowsWritten: number; bytes: number; at: number; wallMs: number }

export interface GameRow {
  id: string; season: number; day: number; level: string; slot: number; home_id: string; away_id: string; umpire_id: string; weather: string;
  first_pitch_at: number; air_ms: number; simmed: number; settled: number; home_runs: number | null; away_runs: number | null; innings: number | null;
  winner: string | null; pool_home: number; pool_away: number; probables: string | null; summary: string | null; story_id: string | null; has_log: number;
  /** house (NPC) waves, JSON HouseWave[] (src/house.ts) */
  house: string | null;
}

export const storyKey = (season: number, id: string) => (id.startsWith(`s${season}-`) ? id : `s${season}-${id}`);
/** Public game id: the schedule id when it already names the season (real league ids look like "S1D5ML0"), else prefixed. */
export const pubGameId = (season: number, schedId: string) => (schedId.startsWith(`S${season}D`) || schedId.startsWith(`g${season}-`) ? schedId : `g${season}-${schedId}`);
const BATCH = 80;

export async function runBatch(db: D1Database, stmts: D1PreparedStatement[]) {
  for (let i = 0; i < stmts.length; i += BATCH) await db.batch(stmts.slice(i, i + BATCH));
}

export class League extends DurableObject<Env> {
  store: BlobStore;
  /** world.stats per season (stats.ts): the current season hot, older ones on demand */
  stats: StatsStore;
  seed = "";
  world!: World;
  state!: SeasonState;
  clock!: Clock;
  lastTick?: TickStats;
  /** serial counters (def id -> last minted), authoritative copy lives here; mirrored to D1 */
  serials = new Map<string, number>();
  defsSeason = 0;
  /** The season's card set as stored in D1 (stable numbering even as rosters move). */
  defs: CardDef[] = [];
  private standingsCache = new Map<string, Map<string, string>>();
  private logCache = new Map<string, unknown>();
  private timesCache = new Map<string, ReturnType<typeof dayTimes>>();

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.store = new BlobStore(ctx.storage);
    this.stats = new StatsStore(ctx.storage.sql);
    void ctx.blockConcurrencyWhile(() => this.boot());
  }

  get db() { return this.env.DB; }
  get bindings(): Env { return this.env; }
  get dayMs() { return Math.max(10_000, Number(this.env.GAME_DAY_MS ?? 1_800_000)); }
  get airMs() { return this.env.AIR_MS ? Number(this.env.AIR_MS) : Math.round(this.dayMs * 0.7); }
  get preMs() { return Math.round(this.dayMs * 0.25); }
  get timing(): DayTiming { return { dayMs: this.dayMs, preMs: this.preMs, airMs: this.airMs }; }
  /**
   * Multiplier on all house (NPC) money, applied when pools are read and settled: env HOUSE_SCALE
   * (default 1), overridden by POST /v1/admin/house. 0 turns Bobby's regulars off.
   */
  get houseScale(): number {
    const m = this.store.getMeta<{ scale: number }>("house");
    const v = m ? m.scale : Number(this.env.HOUSE_SCALE ?? 1);
    return Number.isFinite(v) && v >= 0 ? v : 1;
  }
  setHouseScale(scale: number) { this.store.setMeta("house", { scale }); }

  /**
   * The seed behind every roll after world generation (games, house bets, packs, tips...). The
   * code is public, so a server-only SIM_SALT secret keeps future results unpredictable; the
   * world itself still comes from the plain seed.
   */
  private salted(seed: string): string {
    return this.env.SIM_SALT ? `${seed}:${this.env.SIM_SALT}` : seed;
  }

  private async boot() {
    const cfg = this.store.getMeta<{ seed: string }>("cfg");
    if (!cfg) { await this.reset(this.env.WORLD_SEED ?? "deadball-1", false); return; }
    this.seed = this.salted(cfg.seed);
    this.world = this.store.load<World>("world")!;
    this.state = this.store.load<SeasonState>("season")!;
    if (this.world.stats && Object.keys(this.world.stats).length) {
      // old layout (stats inside the world blob): move them to per-season rows, once
      this.stats.importAll(this.world);
      this.saveWorld();
    } else this.world.stats = this.stats.loadHot(this.world.season);
    this.clock = this.store.getMeta<Clock>("clock")!;
    if (this.clock.v !== 2) await this.migrateClock(this.clock as unknown as LegacyClock);
    this.lastTick = this.store.getMeta<TickStats>("lastTick");
    const rows = await this.db.prepare("SELECT def_id, n FROM serials").all<{ def_id: string; n: number }>();
    for (const r of rows.results) this.serials.set(r.def_id, r.n);
    if (!(await this.ctx.storage.getAlarm())) await this.armAlarm();
  }

  /** Wipe everything (DO storage, D1 tables, R2 logs) and start a fresh world. */
  async reset(seed: string, wipe = true) {
    if (wipe) {
      const tables = ["accounts", "ledger", "games", "bets", "crew", "hired", "ops", "mail", "events", "card_defs", "serials", "cards", "listings", "threads", "comments", "reactions", "stories", "visitors", "syndicates", "syndicate_invites", "redemptions", "redeem_mods", "retired_people", "bids", "holds", "watches", "sales", "props", "prop_bets", "known_storylines", "op_shares", "punches", "odd_jobs", "bonus_marks"];
      await this.db.batch(tables.map(t => this.db.prepare(`DELETE FROM ${t}`)));
      for (;;) {
        const list = await this.env.LOGS.list({ prefix: "logs/", limit: 500 });
        if (!list.objects.length) break;
        await this.env.LOGS.delete(list.objects.map(o => o.key));
        if (!list.truncated) break;
      }
    }
    const house = this.store.getMeta<{ scale: number }>("house");
    this.store.clear();
    if (house) this.store.setMeta("house", house);
    this.stats.clear();
    this.ctx.storage.sql.exec("CREATE TABLE IF NOT EXISTS moves (team_id TEXT NOT NULL, day INTEGER NOT NULL, season INTEGER NOT NULL, text TEXT NOT NULL)");
    this.ctx.storage.sql.exec("DELETE FROM moves");
    this.ctx.storage.sql.exec("DROP TABLE IF EXISTS seen");
    this.seed = this.salted(seed);
    this.serials.clear();
    this.defsSeason = 0;
    this.defs = [];
    this.logCache.clear();
    this.standingsCache.clear();
    this.world = generateWorld(seed);
    this.state = sim.newSeason(this.world, new Rng(`${seed}:season:${this.world.season}`));
    // skip an empty preseason day so a fresh world opens with games on the slate
    for (let i = 0; i < 3 && !sim.slateFor(this.state, this.state.day).length; i++) sim.advanceSeasonDay(this.world, this.state, new Rng(`${seed}:pre:${i}`));
    const now = Date.now();
    this.clock = { v: 2, curDayStart: now, prevDay: this.state.day - 1, prevSeason: this.state.season, finalAt: 0, offDays: 0 };
    this.timesCache.clear();
    this.store.setMeta("cfg", { seed });
    this.saveWorld();
    await this.ensureGameRows();
    await this.armAlarm();
  }

  saveWorld() {
    // stats are stored per season (stats.ts), not in the world blob
    const { stats: _stats, ...rest } = this.world;
    const a = this.store.save("world", rest);
    const b = this.store.save("season", this.state);
    const s = this.stats.save(this.world);
    this.store.setMeta("clock", this.clock);
    this.standingsCache.clear();
    return { written: a.written + b.written + a.deleted + b.deleted + s.written + s.deleted, bytes: a.bytes + b.bytes + s.bytes };
  }

  /** Older seasons' stats into memory (career totals, card backs). Cheap once loaded. */
  ensureStats() {
    this.stats.ensureArchive(this.world);
  }

  /** Serializes market mutations (bids, buys, settlement, listing) inside this DO. */
  private marketQueue: Promise<unknown> = Promise.resolve();
  withMarket<T>(fn: () => Promise<T>): Promise<T> {
    const run = this.marketQueue.then(fn, fn);
    this.marketQueue = run.catch(() => undefined);
    return run;
  }

  /**
   * Fixed-window rate limit kept in DO SQLite (the DO is single-threaded, so check-and-count is
   * atomic). Returns seconds until the window resets when `key` is over `limit`, else 0 and counts it.
   */
  rateLimit(key: string, limit: number, windowMs: number, now: number): number {
    const sql = this.ctx.storage.sql;
    sql.exec("CREATE TABLE IF NOT EXISTS ratelimit (k TEXT PRIMARY KEY, win INTEGER NOT NULL, n INTEGER NOT NULL)");
    const win = Math.floor(now / windowMs);
    const row = sql.exec<{ win: number; n: number }>("SELECT win, n FROM ratelimit WHERE k = ?", key).toArray()[0];
    const n = row && row.win === win ? row.n : 0;
    if (n >= limit) return Math.max(1, Math.ceil(((win + 1) * windowMs - now) / 1000));
    sql.exec("INSERT OR REPLACE INTO ratelimit (k, win, n) VALUES (?, ?, ?)", key, win, n + 1);
    // sweep stale windows now and then
    if ((n + 1) % 50 === 0 || !row) sql.exec("DELETE FROM ratelimit WHERE win < ?", win);
    return 0;
  }

  /**
   * Replay check for signed requests (src/auth.ts): accepts each seq once, if it's within
   * `window` of the highest seen. DO SQLite, single-threaded, so check-and-record is atomic.
   */
  acceptSeq(acct: string, seq: number, window: number): boolean {
    const sql = this.ctx.storage.sql;
    sql.exec("CREATE TABLE IF NOT EXISTS sigseq (acct TEXT PRIMARY KEY, hi INTEGER NOT NULL, seen TEXT NOT NULL)");
    const row = sql.exec<{ hi: number; seen: string }>("SELECT hi, seen FROM sigseq WHERE acct = ?", acct).toArray()[0];
    const hi = row ? row.hi : 0;
    const seen = row && row.seen ? row.seen.split(",").map(Number) : [];
    if (row && (seq <= hi - window || seen.includes(seq))) return false;
    const nhi = Math.max(hi, seq);
    const keep = seen.filter(s => s > nhi - window);
    keep.push(seq);
    sql.exec("INSERT OR REPLACE INTO sigseq (acct, hi, seen) VALUES (?, ?, ?)", acct, nhi, keep.join(","));
    return true;
  }

  /**
   * First time an account fetched something (a game's log, a story), kept in DO SQLite: the odd
   * jobs' client reports (routes/bonus.ts) check that the replay or story was actually loaded.
   * Cheap enough to call on every log poll (one local upsert, no D1 write).
   */
  noteSeen(acct: string, key: string, now: number) {
    const sql = this.ctx.storage.sql;
    sql.exec("CREATE TABLE IF NOT EXISTS seen (acct TEXT NOT NULL, k TEXT NOT NULL, at INTEGER NOT NULL, PRIMARY KEY (acct, k))");
    sql.exec("INSERT OR IGNORE INTO seen (acct, k, at) VALUES (?, ?, ?)", acct, key, now);
    // forget fetches older than two real days now and then
    if (Math.random() < 0.01) sql.exec("DELETE FROM seen WHERE at < ?", now - 2 * 86_400_000);
  }
  firstSeen(acct: string, key: string): number | undefined {
    const sql = this.ctx.storage.sql;
    sql.exec("CREATE TABLE IF NOT EXISTS seen (acct TEXT NOT NULL, k TEXT NOT NULL, at INTEGER NOT NULL, PRIMARY KEY (acct, k))");
    return sql.exec<{ at: number }>("SELECT at FROM seen WHERE acct = ? AND k = ?", acct, key).toArray()[0]?.at;
  }

  /** A new signing key starts a fresh replay window. */
  resetSeq(acct: string) {
    const sql = this.ctx.storage.sql;
    sql.exec("CREATE TABLE IF NOT EXISTS sigseq (acct TEXT PRIMARY KEY, hi INTEGER NOT NULL, seen TEXT NOT NULL)");
    sql.exec("DELETE FROM sigseq WHERE acct = ?", acct);
  }

  // ------------------------------------------------------------------ clock views
  /** The day the clock shows: state.day from its dayStart; before that, the last closed day. */
  shownDay(now: number): { day: number; season: number; startAt: number; nextDayAt: number } {
    const start = this.clock.curDayStart;
    if (now >= start) return { day: this.state.day, season: this.state.season, startAt: start, nextDayAt: start + this.dayMs };
    return { day: this.clock.prevDay, season: this.clock.prevSeason, startAt: start - this.dayMs, nextDayAt: start };
  }

  /** Start of season day `day` (this season), counted from the day being played. */
  dayStartFor(day: number) { return this.clock.curDayStart + (day - this.state.day) * this.dayMs; }

  /** First pitches, air times and the close of a day of this season (src/schedule.ts). */
  timesFor(day: number) {
    const start = this.dayStartFor(day);
    const slate = sim.slateFor(this.state, day);
    const key = `${this.state.season}:${day}:${start}:${slate.length}:${this.dayMs}:${this.airMs}`;
    let t = this.timesCache.get(key);
    if (!t) {
      t = dayTimes(slate, start, this.timing);
      if (this.timesCache.size > 40) this.timesCache.clear();
      this.timesCache.set(key, t);
    }
    return t;
  }

  /** When a scheduled game of this season pitches and how long it airs. */
  pitchFor(g: ScheduledGame): Pitch {
    return this.timesFor(g.day).pitches.get(g.id) ?? { at: this.dayStartFor(g.day) + this.preMs, air: this.airMs };
  }

  /** The next aired game to pitch (bets on it lock then), looking a few days ahead. */
  nextPitch(): { game: ScheduledGame; at: number } | undefined {
    for (let d = this.state.day; d <= this.state.day + 3; d++) {
      const t = this.timesFor(d);
      const g = t.order.find(x => !this.state.results[x.id]);
      if (g) return { game: g, at: t.pitches.get(g.id)!.at };
    }
    return undefined;
  }

  /** Aired games of the day being played that haven't been simulated yet (pitch order), and the day's times. */
  private pending() {
    const t = this.timesFor(this.state.day);
    return { t, left: t.order.filter(g => !this.state.results[g.id]) };
  }

  // ------------------------------------------------------------------ alarm / ticks
  override async alarm() {
    await settleDue(this, Date.now());
    await this.tick(Date.now());
    await this.armAlarm();
  }

  /**
   * Everything that's due: first pitches (each aired game at its own), the day's close after the
   * last one, per-game settlement when a broadcast ends, and the day's final (drama props).
   */
  async tick(now: number) {
    // way behind with nothing played yet (e.g. a dev server that was off for hours)? don't replay
    // every missed day: start this one now and pick the clock up from here
    const slate = sim.slateFor(this.state, this.state.day);
    if (now - this.clock.curDayStart > 3 * this.dayMs && !slate.some(g => this.state.results[g.id])) {
      this.clock.curDayStart = now - this.preMs;
      this.store.setMeta("clock", this.clock);
      await this.retimeUpcoming();
    }
    // catch up at most a few steps per alarm, then re-arm
    for (let i = 0; i < 8; i++) {
      const { t, left } = this.pending();
      const due = left.filter(g => t.pitches.get(g.id)!.at <= now + 20);
      if (due.length) await this.pitch(due);
      else if (!left.length && now >= t.closeAt - 20) await this.close(now);
      else break;
    }
    await this.settleGames(now);
    if (this.clock.finalAt && now >= this.clock.finalAt) await this.dayFinal(now);
  }

  async armAlarm() {
    const { t, left } = this.pending();
    let at = left.length ? t.pitches.get(left[0].id)!.at : t.closeAt;
    if (this.clock.finalAt) at = Math.min(at, this.clock.finalAt);
    // the next broadcast to end (its pool settles then)
    const end = await this.db.prepare("SELECT MIN(first_pitch_at + air_ms) AS t FROM games WHERE simmed = 1 AND settled = 0").first<{ t: number | null }>();
    if (end?.t != null) at = Math.min(at, end.t);
    // auctions settle on time: wake up for the next one to end
    const auction = await nextAuctionEnd(this);
    if (auction !== undefined && auction < at) at = auction;
    await this.ctx.storage.setAlarm(Math.max(at, Date.now() + 10));
  }

  /**
   * A clock from before staggered first pitches: the day it was about to play (or the next one,
   * if a shared broadcast is on the air) starts so that its first game pitches exactly when the
   * old shared first pitch would have; its other games follow, so no bet locks earlier than it
   * would have. Games already simmed keep their times and settle when their broadcast ends.
   */
  async migrateClock(old: LegacyClock) {
    const nextPlay = old.next === "play" ? old.playAt : old.playAt + this.dayMs;
    const prevDay = typeof old.curDay === "number" ? old.curDay : this.state.day - 1;
    this.clock = { v: 2, curDayStart: nextPlay - this.preMs, prevDay, prevSeason: this.state.season, finalAt: old.next === "final" ? old.finalAt : 0, offDays: old.offDays ?? 0 };
    this.timesCache.clear();
    this.store.setMeta("clock", this.clock);
    await this.retimeUpcoming();
  }

  /** Admin fast-forward: play and settle `days` game days immediately. */
  async advance(days: number) {
    const out: TickStats[] = [];
    for (let i = 0; i < days; i++) {
      // run the day in the past, so its last broadcast ended a second ago
      const now = Date.now();
      let end = this.preMs + this.airMs;
      for (const p of dayTimes(sim.slateFor(this.state, this.state.day), 0, this.timing).pitches.values()) end = Math.max(end, p.at + p.air);
      this.clock.curDayStart = now - end - 1000;
      await this.retimeUpcoming(true);
      const { left } = this.pending();
      if (left.length) await this.pitch(left);
      await this.close(now);
      await this.settleGames(Date.now());
      await this.dayFinal(Date.now());
      if (this.lastTick) out.push(this.lastTick);
    }
    // next regular day starts now
    this.clock.curDayStart = Date.now();
    this.store.setMeta("clock", this.clock);
    await this.retimeUpcoming();
    await this.armAlarm();
    return out;
  }

  /** Make sure D1 has rows for the next few days of games, timed by the clock (src/schedule.ts). */
  async ensureGameRows() {
    const season = this.state.season, d0 = this.state.day;
    const stmts: D1PreparedStatement[] = [];
    for (let d = d0; d <= d0 + 2; d++) {
      const t = this.timesFor(d);
      for (const g of sim.slateFor(this.state, d)) {
        const p = t.pitches.get(g.id)!;
        stmts.push(this.db.prepare(
          `INSERT OR IGNORE INTO games (id, season, day, level, slot, home_id, away_id, umpire_id, weather, first_pitch_at, air_ms) VALUES (?,?,?,?,?,?,?,?,?,?,?)`,
        ).bind(pubGameId(season, g.id), season, g.day, g.level, g.slot ?? 0, g.homeId, g.awayId, g.umpireId, JSON.stringify(g.weather), p.at, p.air));
      }
    }
    // probable starters (best rested arm today), and Bobby's regulars' waves, set once per game:
    // the public line as of the day before. Tomorrow's are set now too, so their early waves
    // (which land while today's last games are still on the air) can't know today's results.
    const slate = [d0, d0 + 1].flatMap(d => sim.slateFor(this.state, d)).filter(g => bettableLevel(g.level));
    const table = slate.length ? this.recordTable() : new Map<string, TeamRecord>();
    for (const g of slate) {
      const prob = { home: this.probable(g.homeId), away: this.probable(g.awayId) };
      stmts.push(this.db.prepare("UPDATE games SET probables = ?, house = COALESCE(house, ?) WHERE id = ? AND simmed = 0")
        .bind(JSON.stringify(prob), JSON.stringify(this.houseWaves(g, prob, table)), pubGameId(season, g.id)));
    }
    await runBatch(this.db, stmts);
  }

  /** Standings rows (w, l, runs, streak) for both bettable circuits. */
  recordTable(): Map<string, TeamRecord> {
    const m = new Map<string, TeamRecord>();
    for (const lv of ["ML", "EL"] as const) for (const r of sim.standings(this.world, this.state, lv)) m.set(r.teamId, r);
    return m;
  }

  /** The regulars' waves for one game (public line: form, probables, home field; prominence). */
  houseWaves(g: ScheduledGame, prob: { home: string; away: string }, table: Map<string, TeamRecord>) {
    const w = this.world;
    const series = g.series ? [...(this.state.playoff?.series ?? []), ...(this.state.enhancedPlayoff?.series ?? [])].find(s => s.id === g.series) : undefined;
    const streak = (id: string) => teamForm(w, id, undefined, table.get(id)).streak;
    return gameWaves(this.seed, {
      id: pubGameId(this.state.season, g.id), level: g.level, homeId: g.homeId, awayId: g.awayId,
      pHome: fairHome(w, g.homeId, g.awayId, prob, table),
      exhibition: !!g.exhibition, playoff: !!g.series, final: series?.round === "final", rivalry: rivals(w, g.homeId, g.awayId),
      streakDiff: streak(g.homeId) - streak(g.awayId),
    }, this.preMs);
  }

  /**
   * Re-time the next few days' unplayed games (and open props) to the clock. `today` also moves
   * the day being played's games that were already simulated (admin fast-forward only).
   */
  async retimeUpcoming(today = false) {
    this.timesCache.clear();
    const season = this.state.season, d0 = this.state.day;
    const stmts: D1PreparedStatement[] = [];
    for (let d = d0; d <= d0 + 2; d++) {
      for (const [id, p] of this.timesFor(d).pitches) {
        stmts.push(this.db.prepare(`UPDATE games SET first_pitch_at = ?, air_ms = ? WHERE id = ? AND ${today && d === d0 ? "settled = 0" : "simmed = 0"}`)
          .bind(p.at, p.air, pubGameId(season, id)));
      }
    }
    stmts.push(...propRetimeStmts(this, this.timesFor(d0).closeAt));
    await runBatch(this.db, stmts);
  }

  probable(teamId: string): string {
    const t = this.world.teams[teamId];
    if (!t) return "";
    try {
      return pickStarter(buildStaff(this.world, t))?.id ?? "";
    } catch {
      return "";
    }
  }

  /** Crew rows for a tick: everyone who isn't idle, plus the crew named on `orderRows`. */
  private async loadCrew(orderRows: OpRow[]): Promise<Record<string, CrewMember>> {
    const crewRows = (await this.db.prepare(`SELECT id, data FROM crew WHERE status NOT IN ('free', 'gone', 'dead') OR id IN (SELECT value FROM json_each(?))`)
      .bind(JSON.stringify(orderRows.flatMap(o => JSON.parse(o.crew) as string[]))).all<{ id: string; data: string }>()).results;
    const crew: Record<string, CrewMember> = {};
    for (const r of crewRows) crew[r.id] = JSON.parse(r.data);
    return crew;
  }

  private toOrders(orderRows: OpRow[], crew: Record<string, CrewMember>, byPub: Map<string, ScheduledGame>): OpOrder[] {
    return orderRows.map(o => {
      const g = o.game_id ? byPub.get(o.game_id) : undefined;
      const ownerIds = [...new Set((JSON.parse(o.crew) as string[]).map(id => crew[id]?.ownerId).filter(Boolean))] as string[];
      return {
        id: o.id, ownerId: o.account_id, kind: o.kind, gameId: g?.id ?? "", targetTeamId: o.target_team_id, crew: JSON.parse(o.crew), gear: JSON.parse(o.gear),
        placedDay: o.placed_day,
        ...(g ? { opponentTeamId: o.target_team_id === g.homeId ? g.awayId : g.homeId, umpireId: g.umpireId, homeTeamId: g.homeId } : {}),
        ...(o.storyline_id ? { storylineId: o.storyline_id } : {}), ...(o.nudge ? { nudge: o.nudge as "expose" | "soothe" } : {}),
        ...(o.syndicate_id ? { syndicateId: o.syndicate_id, allies: ownerIds.filter(x => x !== o.account_id) } : {}),
      };
    });
  }

  /** Statements for finished jobs: refunds for the called-off, outcomes, heat. */
  private async opOutcomeStmts(outcomes: OpOutcome[], orderRows: OpRow[], at: number, season: number): Promise<D1PreparedStatement[]> {
    const stmts: D1PreparedStatement[] = [];
    // jobs that never started (nobody free, the story over, banned at the turnstiles) are refunded,
    // orderer and chipped-in allies alike; unanswered chip-in asks on the rest lapse at first pitch
    for (const o of outcomes) {
      const ord = orderRows.find(x => x.id === o.orderId);
      if (!ord || !o.calledOff) continue;
      const name = sim.OP_KINDS.find(k => k.kind === ord.kind)?.name ?? ord.kind;
      await this.db.batch(refundStmts(this.db, ord, at, season, `"${name}" was called off: ${o.blocked ?? o.summary ?? "nobody went"}`));
    }
    stmts.push(...expireStmts(this.db, orderRows.map(o => o.id), at));
    for (const o of outcomes) {
      const ord = orderRows.find(x => x.id === o.orderId);
      if (!ord) continue;
      const summary = (o.summary as string | undefined) ?? (o.success ? "Pulled it off." : "Blown.");
      stmts.push(this.db.prepare("UPDATE ops SET status = ?, result = ?, arrests = ?, outcome = ? WHERE id = ?")
        .bind(o.calledOff ? "cancelled" : o.success ? "done" : "blown", o.calledOff ? `${summary} Refunded.` : summary, o.arrests.length, JSON.stringify({ ...o, mail: undefined, events: undefined, crew: undefined }), o.orderId));
      const heatBy = (o.heatBy as Record<string, number> | undefined) ?? { [ord.account_id]: o.heat };
      for (const [acct, h] of Object.entries(heatBy)) stmts.push(this.db.prepare("UPDATE accounts SET heat = MAX(0, heat + ?) WHERE id = ?").bind(Math.round(h), acct));
    }
    return stmts;
  }

  private crewStmts(crew: CrewMember[]): D1PreparedStatement[] {
    // jobs done: free anyone still marked busy without a timer
    return crew.map(c => {
      if (c.status === "busy" && c.until === undefined) c.status = "free";
      return this.db.prepare("UPDATE crew SET status = ?, data = ? WHERE id = ?").bind(c.status, JSON.stringify(c), c.id);
    });
  }

  /**
   * First pitch for some of today's aired games (usually one; several when the alarm is behind):
   * their jobs resolve, they're simulated and recorded, logs go to R2, and everything the public
   * or a player could learn from the result (recap, crime stories, post-game mail and cards) is
   * stamped with that game's own final. Farm games still to play go first, at the day's first tick.
   */
  async pitch(due: ScheduledGame[]) {
    const t0 = Date.now();
    const season = this.state.season, day = this.state.day;
    const t = this.timesFor(day);
    // milestones and retirements read career totals: every season in memory
    this.ensureStats();
    const farm = sim.slateFor(this.state, day).filter(g => !aired(g) && !this.state.results[g.id]);
    const games = [...simOrder(farm), ...due.filter(g => !this.state.results[g.id])];
    const pub = (g: ScheduledGame) => pubGameId(season, g.id);
    const byPub = new Map(games.map(g => [pub(g), g]));
    const ids = [...byPub.keys()];

    const orderRows = (await this.db.prepare(`SELECT * FROM ops WHERE status = 'planned' AND game_id IN (SELECT value FROM json_each(?))`).bind(JSON.stringify(ids)).all<OpRow>()).results;
    const crew = await this.loadCrew(orderRows);
    const orders = this.toOrders(orderRows, crew, byPub);
    await flushRedemptions(this);
    const redeemMods = await activeRedeemMods(this, this.world.day);
    const r = playGames({ world: this.world, state: this.state, seed: this.seed, orders, crew, redeemMods }, games);
    const stmts: D1PreparedStatement[] = [];

    for (const pg of r.games) {
      const id = pub(pg.game);
      const p = t.pitches.get(pg.game.id) ?? { at: t0, air: this.airMs };
      const at = p.at, finalAt = p.at + p.air;
      const recap = pg.stories[0];
      stmts.push(this.db.prepare(
        `UPDATE games SET simmed = 1, first_pitch_at = ?, air_ms = ?, home_runs = ?, away_runs = ?, innings = ?, winner = ?, summary = ?, probables = ?, story_id = ?, has_log = ? WHERE id = ?`,
      ).bind(at, p.air, pg.res.home.runs, pg.res.away.runs, pg.res.innings, pg.res.winner, JSON.stringify(pg.summary), JSON.stringify(pg.starters),
        recap ? storyKey(season, recap.id) : null, aired(pg.game) ? 1 : 0, id));
      if (aired(pg.game)) await this.env.LOGS.put(`logs/${id}.json`, JSON.stringify(this.logDoc(id, pg.game, pg.res.log, pg.wire ?? [])));
      for (const s of pg.stories) stmts.push(this.storyStmt({ ...s, gameId: id }, season, finalAt));
      for (const s of pg.crimeStories) stmts.push(this.storyStmt(s.gameId ? { ...s, gameId: this.pubForSched(season, s.gameId) } : s, season, finalAt));
      const rows = orderRows.filter(o => o.game_id === id);
      if (rows.length) {
        stmts.push(...(await this.opOutcomeStmts(pg.outcomes, rows, at, season)));
        stmts.push(...this.mailStmts(pg.preMail, at), ...this.eventStmts(pg.preEvents, at));
        stmts.push(...this.mailStmts(pg.mail, finalAt), ...this.eventStmts(pg.events, finalAt));
        stmts.push(...this.effectStmts(pg.effects, at, season, finalAt, id));
      }
    }
    stmts.push(...this.crewStmts(r.crew));

    const saved = this.saveWorld();
    await runBatch(this.db, stmts);
    this.lastTick = { kind: "pitch", day, games: r.games.length, rowsWritten: saved.written, bytes: saved.bytes, at: t.pitches.get(games[games.length - 1]?.id ?? "")?.at ?? t0, wallMs: Date.now() - t0 };
    this.store.setMeta("lastTick", this.lastTick);
  }

  /**
   * The day's close, right after its last aired game is simulated: anything left to play, the
   * storyline-only jobs, grudges, the rollover (life, phases, tomorrow's playoff games), tips,
   * BBS chatter, props. The day's news is stamped with its last final, so nothing leaks while a
   * game is still on the air; tomorrow starts one dayMs after today did.
   */
  async close(now: number) {
    const t0 = Date.now();
    const season = this.state.season, day = this.state.day;
    const left = sim.slateFor(this.state, day).filter(g => !this.state.results[g.id]);
    if (left.length) await this.pitch(left);
    this.ensureStats();
    const t = this.timesFor(day);
    const at = t.closeAt;
    // the day's news is out when its last broadcast ends
    let newsAt = at;
    for (const g of t.order) { const p = t.pitches.get(g.id)!; newsAt = Math.max(newsAt, p.at + p.air); }

    const orderRows = (await this.db.prepare(`SELECT * FROM ops WHERE status = 'planned' AND game_id = ''`).all<OpRow>()).results;
    const crew = await this.loadCrew(orderRows);
    const orders = this.toOrders(orderRows, crew, new Map());
    const r = closeDay({ world: this.world, state: this.state, seed: this.seed, orders, crew, offDays: this.clock.offDays, offseasonLength: Number(this.env.OFFSEASON_DAYS ?? 7) });
    const stmts: D1PreparedStatement[] = [];

    for (const s of r.stories) stmts.push(this.storyStmt(s.gameId ? { ...s, gameId: this.pubForSched(season, s.gameId) } : s, season, newsAt));
    stmts.push(...(await this.opOutcomeStmts(r.outcomes, orderRows, at, season)));
    stmts.push(...this.crewStmts(r.crew));
    stmts.push(...this.mailStmts(r.preMail, at), ...this.eventStmts(r.preEvents, at));
    stmts.push(...this.mailStmts(r.mail, newsAt), ...this.eventStmts(r.events, newsAt));
    stmts.push(...this.effectStmts(r.effects, at, season, newsAt, `close:${season}:${day}`));
    // hostile owners: cooling-off notices, and calls to SportsWire about the crews they hate
    stmts.push(...(await this.grudgeStmts(r.grudgeMail, season, at, newsAt)));
    // heat cools a point a day
    stmts.push(this.db.prepare("UPDATE accounts SET heat = heat - 1 WHERE heat > 0"));

    // team moves from life events
    this.recordMoves(r);
    if (r.newSeason) this.state = r.newSeason;
    if (this.state.season !== season) this.defsSeason = 0;
    // tomorrow starts a day after today did (or now, if the clock fell far behind)
    let start = this.clock.curDayStart + this.dayMs;
    if (now - start > 3 * this.dayMs) start = now;
    this.clock = { ...this.clock, curDayStart: start, prevDay: day, prevSeason: season, finalAt: Math.max(this.clock.finalAt, newsAt), offDays: r.offDays };
    this.timesCache.clear();

    // tips about tomorrow's planned jobs go to rival crews; drama tips go to bettors and crews
    stmts.push(...(await this.tipStmts(at)));
    stmts.push(...(await this.dramaTipStmts(r.life, at)));
    // BBS rumour chatter on bbs:rumors (the day's recaps and news; rumoured storyline beats become overheard tips)
    const recaps = (await this.db.prepare("SELECT data FROM stories WHERE season = ? AND game_id IN (SELECT value FROM json_each(?))")
      .bind(season, JSON.stringify(t.order.map(g => pubGameId(season, g.id)))).all<{ data: string }>()).results.map(x => JSON.parse(x.data) as Story);
    stmts.push(...this.bbsStmts([...recaps, ...r.stories], r.life, season, day, newsAt));
    // drama props: open new markets, close the ones past their day or already decided
    stmts.push(...propSyncStmts(this, this.timesFor(this.state.day).closeAt, at));
    // expired redeemed-card boosts
    stmts.push(this.db.prepare("DELETE FROM redeem_mods WHERE until_day < ?").bind(this.world.day - 1));

    const saved = this.saveWorld();
    await runBatch(this.db, stmts);
    await this.ensureGameRows();
    await runBatch(this.db, await this.regularsStmts(season, day, newsAt));
    this.lastTick = { kind: "close", day, games: t.order.length, rowsWritten: saved.written, bytes: saved.bytes, at, wallMs: Date.now() - t0 };
    this.store.setMeta("lastTick", this.lastTick);
  }

  /** Settle every game whose broadcast has ended (its own pool, at its own final), and expire old event cards. */
  async settleGames(now: number) {
    const due = (await this.db.prepare("SELECT id, winner, pool_home, pool_away, home_runs, away_runs, home_id, away_id, season, house FROM games WHERE simmed = 1 AND settled = 0 AND first_pitch_at + air_ms <= ?")
      .bind(now + 1000).all<GameRow>()).results;
    const stmts: D1PreparedStatement[] = [];
    for (const g of due) stmts.push(...this.settleStmts(g, now));
    stmts.push(this.db.prepare("UPDATE events SET status = 'expired' WHERE status = 'pending' AND expires_at < ?").bind(now));
    await runBatch(this.db, stmts);
  }

  /** The day's final, once its news is out: drama props decided by its life events settle. */
  async dayFinal(now: number) {
    await settleProps(this, now);
    this.clock.finalAt = 0;
    this.store.setMeta("clock", this.clock);
  }

  /**
   * Pari-mutuel settlement for one game, idempotent (bets move open -> paying -> settled). The pool
   * is player money plus the house's waves (all landed by first pitch); the house's own winnings
   * are burned, so only player bets get rows, ledger entries and mail.
   */
  settleStmts(g: Pick<GameRow, "id" | "winner" | "pool_home" | "pool_away" | "home_runs" | "away_runs" | "home_id" | "away_id" | "season" | "house">, now: number): D1PreparedStatement[] {
    const db = this.db;
    const w = g.winner === "home" ? "home" : "away";
    const house = visible(parseWaves(g.house), 2, 0, Infinity, this.houseScale);
    const m = settleMath([g.pool_home, g.pool_away], house, w === "home" ? 0 : 1);
    const net = m.net, winPool = m.refund ? 0 : m.winPool;
    const h = this.world.teams[g.home_id], a = this.world.teams[g.away_id];
    const head = `${a?.abbr ?? g.away_id} ${g.away_runs}, ${h?.abbr ?? g.home_id} ${g.home_runs}`;
    const payExpr = winPool > 0 ? `CASE WHEN side = ? THEN (amount * CAST(? AS INTEGER)) / CAST(? AS INTEGER) ELSE 0 END` : `amount`;
    const payArgs = winPool > 0 ? [w, net, winPool] : [];
    return [
      db.prepare(`UPDATE bets SET status = 'paying', settled_at = ?, payout = ${payExpr} WHERE game_id = ? AND status = 'open'`).bind(now, ...payArgs, g.id),
      db.prepare(`INSERT OR IGNORE INTO ledger (id, account_id, delta, reason, at, season, syndicate_id)
        SELECT 'pay:' || b.id, b.account_id, b.payout, ?, ?, ?, a.syndicate_id FROM bets b JOIN accounts a ON a.id = b.account_id WHERE b.game_id = ? AND b.status = 'paying' AND b.payout > 0`)
        .bind(winPool > 0 ? "payout" : "refund", now, g.season, g.id),
      db.prepare(`UPDATE accounts SET money = money + (SELECT COALESCE(SUM(payout), 0) FROM bets b WHERE b.account_id = accounts.id AND b.game_id = ? AND b.status = 'paying')
        WHERE id IN (SELECT account_id FROM bets WHERE game_id = ? AND status = 'paying')`).bind(g.id, g.id),
      db.prepare(`INSERT OR IGNORE INTO mail (id, account_id, at, read, kind, data)
        SELECT 'mb:' || id, account_id, ?, 0, 'bank', json_object('from', 'Bets By Bobby', 'subject', CASE WHEN payout > amount THEN 'You won $' || payout WHEN payout = amount THEN 'Bet refunded' ELSE 'Tough luck' END,
          'body', json_array(?, 'You had $' || amount || ' on the ' || side || ' side.', CASE WHEN payout > 0 THEN 'Paid out: $' || payout || '.' ELSE 'Better luck tomorrow.' END))
        FROM bets WHERE game_id = ? AND status = 'paying'`).bind(now, `Final: ${head}.`, g.id),
      db.prepare(`UPDATE bets SET status = 'settled' WHERE game_id = ? AND status = 'paying'`).bind(g.id),
      db.prepare(`UPDATE games SET settled = 1 WHERE id = ?`).bind(g.id),
    ];
  }

  // ------------------------------------------------------------------ helpers used by pitch() and close()
  pubForSched(season: number, schedId: string) {
    return pubGameId(season, schedId);
  }

  storyStmt(s: Story, season: number, publishAt: number): D1PreparedStatement {
    const prominence = typeof s.prominence === "number" && Number.isFinite(s.prominence) ? s.prominence : 1;
    return this.db.prepare("INSERT OR REPLACE INTO stories (id, season, day, kind, headline, publish_at, game_id, data, prominence) VALUES (?,?,?,?,?,?,?,?,?)")
      .bind(storyKey(season, s.id), season, s.day, s.kind, s.headline, publishAt, s.gameId ?? null, JSON.stringify(s), prominence);
  }

  mailStmts(mail: MailItem[], at: number): D1PreparedStatement[] {
    const out = mail.filter(m => m.ownerId).map(m => this.db.prepare("INSERT OR IGNORE INTO mail (id, account_id, at, read, kind, data) VALUES (?,?,?,0,?,?)")
      .bind(m.id ? `${m.id}` : newId("m"), m.ownerId!, at, String(m.kind ?? "league"), JSON.stringify(m)));
    // a tip about a storyline makes it known to that account (secret arcs: op target + "you heard" row)
    for (const m of mail) {
      if (m.ownerId && m.storylineId) out.push(this.db.prepare("INSERT OR IGNORE INTO known_storylines (account_id, storyline_id, at) VALUES (?,?,?)").bind(m.ownerId, m.storylineId, at));
    }
    return out;
  }

  /** Storyline ids an account learned about from tips. */
  async knownStorylines(accountId: string): Promise<string[]> {
    return (await this.db.prepare("SELECT storyline_id FROM known_storylines WHERE account_id = ?").bind(accountId).all<{ storyline_id: string }>()).results.map(r => r.storyline_id);
  }

  eventStmts(evs: EventCard[], at: number): D1PreparedStatement[] {
    return evs.filter(e => e.ownerId).map(e => this.db.prepare("INSERT OR IGNORE INTO events (id, account_id, at, expires_at, status, data) VALUES (?,?,?,?, 'pending', ?)")
      .bind(e.id || newId("e"), e.ownerId, at, at + this.dayMs * 2, JSON.stringify(e)));
  }

  /** Apply crime effects (money, heat, crew, relations, story hooks; the stories publish at `publishAt`). */
  effectStmts(effects: CrimeEffect[], at: number, season: number, publishAt = at, key = String(at)): D1PreparedStatement[] {
    const out: D1PreparedStatement[] = [];
    let n = 0;
    for (const e of effects) {
      if (e.kind === "money") {
        const id = `fx:${key}:${n++}:${e.ownerId}`;
        out.push(this.db.prepare("INSERT OR IGNORE INTO ledger (id, account_id, delta, reason, at, season, syndicate_id) SELECT ?, id, MAX(?, -money), ?, ?, ?, syndicate_id FROM accounts WHERE id = ?")
          .bind(id, Math.round(e.delta), `effect:${e.why}`.slice(0, 60), at, season, e.ownerId));
        out.push(this.db.prepare("UPDATE accounts SET money = MAX(0, money + ?) WHERE id = ?").bind(Math.round(e.delta), e.ownerId));
      } else if (e.kind === "heat") {
        out.push(this.db.prepare("UPDATE accounts SET heat = MAX(0, heat + ?) WHERE id = ?").bind(Math.round(e.delta), e.ownerId));
      } else if (e.kind === "crew") {
        out.push(this.db.prepare(`UPDATE crew SET status = ?, data = json_set(data, '$.status', ?${e.until !== undefined ? ", '$.until', ?" : ""}${e.loyalty !== undefined ? ", '$.loyalty', ?" : ""}${e.heat !== undefined ? ", '$.heat', ?" : ""}) WHERE id = ?`)
          .bind(e.status, e.status, ...[e.until, e.loyalty, e.heat].filter(x => x !== undefined), e.crewId));
      } else if (e.kind === "relation") {
        const r = this.world.relationships.find(x => (x.a === e.a && x.b === e.b) || (x.a === e.b && x.b === e.a));
        if (r) { r.value = Math.max(-5, Math.min(5, r.value + e.delta)); r.reason = e.reason; }
        else this.world.relationships.push({ a: e.a, b: e.b, value: Math.max(-5, Math.min(5, e.delta)), reason: e.reason });
      }
      else if (e.kind === "story") {
        const st = writeScandalStory(this.world, e.hook);
        if (st) out.push(this.storyStmt(st, season, publishAt));
      }
    }
    return out;
  }

  /**
   * Hostile owners, daily: deliver the grudge mail from the day (a syndicate's goes to each member)
   * and let them lean on SportsWire (sim leanOnPress: briefs about your crew, heat).
   */
  async grudgeStmts(grudgeMail: MailItem[], season: number, at: number, publishAt: number): Promise<D1PreparedStatement[]> {
    const parties = [...new Set([...grudgeParties(this.world), ...grudgeMail.map(m => m.ownerId)])];
    if (!parties.length) return [];
    const ids = JSON.stringify(parties);
    const accts = (await this.db.prepare("SELECT id, syndicate_id FROM accounts WHERE id IN (SELECT value FROM json_each(?)) OR syndicate_id IN (SELECT value FROM json_each(?))")
      .bind(ids, ids).all<{ id: string; syndicate_id: string | null }>()).results;
    const mail: MailItem[] = [];
    for (const m of grudgeMail) {
      if (accts.some(a => a.id === m.ownerId)) mail.push(m);
      else for (const a of accts.filter(x => x.syndicate_id === m.ownerId)) mail.push({ ...m, id: `${m.id}:${a.id}`, ownerId: a.id });
    }
    const out = this.mailStmts(mail, publishAt);
    const hated = accts.filter(a => parties.includes(a.id) || (a.syndicate_id && parties.includes(a.syndicate_id)));
    if (!hated.length) return out;
    const crewRows = (await this.db.prepare("SELECT account_id, data FROM crew WHERE account_id IN (SELECT value FROM json_each(?)) AND status NOT IN ('gone', 'dead')")
      .bind(JSON.stringify(hated.map(a => a.id))).all<{ account_id: string; data: string }>()).results;
    const press = leanOnPress(this.world, hated.map(a => ({
      ownerId: a.id, ...(a.syndicate_id ? { syndicateId: a.syndicate_id } : {}),
      crew: crewRows.filter(r => r.account_id === a.id).map(r => JSON.parse(r.data) as CrewMember),
    })), new Rng(`${this.seed}:press:${season}:${this.world.day}`));
    out.push(...press.stories.map(st => this.storyStmt(st, season, publishAt)), ...this.mailStmts(press.mail, publishAt), ...this.effectStmts(press.effects, at, season));
    return out;
  }

  async tipStmts(at: number): Promise<D1PreparedStatement[]> {
    const next = sim.slateFor(this.state, this.state.day);
    if (!next.length) return [];
    const ids = next.map(g => pubGameId(this.state.season, g.id));
    const rows = (await this.db.prepare(`SELECT * FROM ops WHERE status = 'planned' AND game_id IN (SELECT value FROM json_each(?))`).bind(JSON.stringify(ids)).all<OpRow>()).results;
    if (!rows.length) return [];
    const recips = (await this.db.prepare(`SELECT id, syndicate_id FROM accounts WHERE id IN (SELECT DISTINCT account_id FROM crew WHERE status != 'gone') LIMIT 500`).all<{ id: string; syndicate_id: string | null }>()).results;
    const syndicateOf: Record<string, string> = {};
    for (const r of recips) if (r.syndicate_id) syndicateOf[r.id] = r.syndicate_id;
    const bySched = new Map(next.map(g => [pubGameId(this.state.season, g.id), g]));
    const orders: OpOrder[] = rows.map(o => ({
      id: o.id, ownerId: o.account_id, kind: o.kind, gameId: bySched.get(o.game_id)!.id, targetTeamId: o.target_team_id, crew: JSON.parse(o.crew), gear: JSON.parse(o.gear),
      placedDay: o.placed_day, ...(o.syndicate_id ? { syndicateId: o.syndicate_id } : {}),
    }));
    for (const r of rows) if (r.syndicate_id) syndicateOf[r.account_id] = r.syndicate_id;
    const tips = sim.leakTips(this.world, orders, recips.map(r => r.id), this.state.day, new Rng(`${this.seed}:tips:${this.state.season}:${this.state.day}`), {
      syndicateOf, games: next.map(g => ({ id: g.id, homeId: g.homeId, awayId: g.awayId })),
    });
    // belt and braces: never deliver a tip about an ally's job
    const safe = tips.filter(t => !t.ownerId || !orders.some(o => {
      const s = o.syndicateId ?? syndicateOf[o.ownerId];
      return (o.ownerId === t.ownerId || (s && syndicateOf[t.ownerId!] === s)) && JSON.stringify(t).includes(o.id);
    }));
    return this.mailStmts(safe.map(t => ({ ...t, id: `tip:${this.state.day}:${t.id || newId("t")}` })), at);
  }

  /** Drama tips (debts, feuds, the inexplicable) from today's life events, for accounts that bet or run crews. */
  async dramaTipStmts(life: LifeEvent[], at: number): Promise<D1PreparedStatement[]> {
    if (!life.length) return [];
    const recips = (await this.db.prepare(`SELECT id FROM accounts WHERE id IN (SELECT DISTINCT account_id FROM crew WHERE status != 'gone')
        OR id IN (SELECT DISTINCT account_id FROM bets WHERE placed_at > ?) OR id IN (SELECT DISTINCT account_id FROM prop_bets WHERE status = 'open') LIMIT 500`)
      .bind(at - 3 * this.dayMs).all<{ id: string }>()).results.map(r => r.id);
    if (!recips.length) return [];
    const tips = dramaTips(this.world, life, recips, this.world.day, new Rng(`${this.seed}:dtips:${this.state.season}:${this.world.day}`));
    return this.mailStmts(tips.filter(t => t.ownerId), at);
  }

  /** NPC chatter for the rumours board, built from the day's stories plus overheard rumoured storyline beats. */
  bbsStmts(stories: Story[], life: LifeEvent[], season: number, day: number, at: number): D1PreparedStatement[] {
    let posts: ReturnType<typeof bbsPosts>;
    try {
      posts = bbsPosts(this.world, day, stories as Parameters<typeof bbsPosts>[2], { board: "rumors", count: 4, tips: rumorLines(this.world, life) });
    } catch (e) {
      console.error("bbsPosts", e);
      return [];
    }
    if (!posts.length) return [];
    const out = posts.map((p, i) => {
      const text = (p.subject.startsWith("RE:") ? `${p.subject} -- ${p.text}` : p.text).slice(0, 280);
      return this.db.prepare("INSERT OR IGNORE INTO comments (id, thread, author_id, template, words, text, at) VALUES (?, 'bbs:rumors', ?, 'npc', '[]', ?, ?)")
        .bind(`npc:${season}:${day}:${i}`, `npc:${p.author}`, text, at + i);
    });
    out.push(this.db.prepare(`INSERT INTO threads (id, comment_count, last_at) VALUES ('bbs:rumors', (SELECT COUNT(*) FROM comments WHERE thread = 'bbs:rumors'), ?)
      ON CONFLICT (id) DO UPDATE SET comment_count = excluded.comment_count, last_at = MAX(last_at, excluded.last_at)`).bind(at + posts.length));
    return out;
  }

  /**
   * Now and then a deadpan BBS line about the biggest single house stake on tomorrow's slate
   * ("A man in a raincoat put $60 on the Grays."). Only public facts: a wave that will land anyway.
   */
  async regularsStmts(season: number, day: number, at: number): Promise<D1PreparedStatement[]> {
    const rng = new Rng(`${this.seed}:regulars:${season}:${day}`);
    if (this.houseScale <= 0 || !rng.chance(0.5)) return [];
    const ids = sim.slateFor(this.state, this.state.day).filter(g => bettableLevel(g.level)).map(g => pubGameId(this.state.season, g.id));
    if (!ids.length) return [];
    const rows = (await this.db.prepare("SELECT id, home_id, away_id, house FROM games WHERE id IN (SELECT value FROM json_each(?)) AND house IS NOT NULL")
      .bind(JSON.stringify(ids)).all<{ id: string; home_id: string; away_id: string; house: string }>()).results;
    let best: { amt: number; team: string } | undefined;
    for (const r of rows) for (const wv of parseWaves(r.house)) for (let i = 0; i < 2; i++) {
      const amt = Math.floor((wv.a[i] ?? 0) * this.houseScale * rng.range(0.08, 0.2));
      if (!best || amt > best.amt) best = { amt, team: this.world.teams[i === 0 ? r.home_id : r.away_id]?.name ?? "home side" };
    }
    if (!best || best.amt < 10) return [];
    const amt = best.amt >= 50 ? Math.round(best.amt / 10) * 10 : best.amt;
    const text = regularsLine(rng, amt, best.team);
    return [this.db.prepare("INSERT OR IGNORE INTO comments (id, thread, author_id, template, words, text, at) VALUES (?, 'bbs:rumors', ?, 'npc', '[]', ?, ?)")
      .bind(`npc:${season}:${day}:regulars`, `npc:${rng.pick(["Bettor_Bob", "SysOp_Earl", "HotDogHal_NOT"])}`, text, at + 9)];
  }

  recordMoves(r: CloseResult) {
    const MOVE = new Set(["trade", "callup", "demotion", "release", "signing", "draft", "debut", "retirement", "injury", "transfer"]);
    for (const e of r.life) {
      if (!MOVE.has(e.kind)) continue;
      const names = e.who.map(id => personRef(this.world, id).name).join(", ");
      const verb: Record<string, string> = {
        trade: "Traded", transfer: "Transferred:", callup: "Called up", demotion: "Sent down", release: "Released", signing: "Signed", draft: "Drafted", debut: "Debut:", retirement: "Retired:", injury: "Injured:",
      };
      for (const t of e.teams ?? []) {
        this.ctx.storage.sql.exec("INSERT INTO moves (team_id, day, season, text) VALUES (?,?,?,?)", t, e.day, r.season, `${verb[e.kind]} ${names}`);
      }
    }
  }

  movesFor(teamId: string): { day: number; text: string }[] {
    this.ctx.storage.sql.exec("CREATE TABLE IF NOT EXISTS moves (team_id TEXT NOT NULL, day INTEGER NOT NULL, season INTEGER NOT NULL, text TEXT NOT NULL)");
    return this.ctx.storage.sql.exec<{ day: number; text: string }>("SELECT day, text FROM moves WHERE team_id = ? ORDER BY rowid DESC LIMIT 12", teamId).toArray()
      .map(r => ({ day: r.day, text: r.text }));
  }

  logDoc(id: string, g: ScheduledGame, log: unknown[], wire: { i: number; text: string }[]) {
    const ids = new Set<string>([g.umpireId]);
    for (const ev of log as Record<string, unknown>[]) {
      for (const k of ["bat", "pit", "id", "out", "in"]) if (typeof ev[k] === "string" && (k !== "out" || ev.k === "sub")) ids.add(ev[k] as string);
      if (ev.k === "inc" && typeof ev.who === "string") for (const w of ev.who.split(",")) ids.add(w);
    }
    const people: Record<string, ReturnType<typeof personRef>> = {};
    for (const pid of ids) if (this.world.players[pid] || this.world.npcs[pid]) people[pid] = personRef(this.world, pid);
    const h = this.world.teams[g.homeId];
    const park = this.world.parks[h.parkId];
    return {
      id, log, wire, people,
      park: { id: park.id, name: park.name, fences: park.fences, walls: park.walls, altitudeFt: park.altitudeFt, foulTerritory: park.foulTerritory, turf: park.turf, weather: g.weather },
      home: g.homeId, away: g.awayId, umpire: g.umpireId,
    };
  }

  async getLog(id: string): Promise<LogDoc | undefined> {
    const hit = this.logCache.get(id) as LogDoc | undefined;
    if (hit) return hit;
    const obj = await this.env.LOGS.get(`logs/${id}.json`);
    if (!obj) return undefined;
    const doc = (await obj.json()) as LogDoc;
    this.logCache.set(id, doc);
    if (this.logCache.size > 24) this.logCache.delete(this.logCache.keys().next().value!);
    return doc;
  }

  /** "W-L" records per team for a level, cached until the next save. */
  records(level: string): Map<string, string> {
    let m = this.standingsCache.get(level);
    if (!m) {
      m = new Map(sim.standings(this.world, this.state, level as "ML").map(s => [s.teamId, `${s.w}-${s.l}`]));
      this.standingsCache.set(level, m);
    }
    return m;
  }

  probableRef(pid: string) {
    return { ...personRef(this.world, pid), line: pitcherLine(this.world, pid, this.state.season) };
  }

  status() {
    const next = this.nextPitch();
    return { seed: this.seed, clock: this.clock, nextPitchAt: next?.at, nextGame: next ? pubGameId(this.state.season, next.game.id) : undefined, house: this.houseScale, season: this.state.season, day: this.state.day, phase: this.state.phase, usingTemp, lastTick: this.lastTick, stats: this.stats.info() };
  }

  override async fetch(req: Request): Promise<Response> {
    try {
      return await route(this, req);
    } catch (e) {
      return errorResponse(e);
    }
  }
}

export interface LogDoc { id: string; log: Record<string, unknown>[]; wire: { i: number; text: string }[]; people: Record<string, unknown>; park: unknown; home: string; away: string; umpire: string }

export interface OpRow {
  id: string; account_id: string; syndicate_id: string | null; kind: string; game_id: string; target_team_id: string; crew: string; gear: string;
  placed_day: number; season: number; cost: number; status: string; result: string | null; arrests: number; outcome: string | null; created_at: number;
  storyline_id: string | null; nudge: string | null;
}
/** ops.status: planned | done | blown | cancelled (cancelling only inside a refund batch) */
