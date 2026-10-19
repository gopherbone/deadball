// Bobby's Loyalty Club and Odd Jobs (migrations/0008_bonus.sql, docs/API.md "Loyalty card &
// odd jobs").
//
// LOYALTY CARD. A seven-hole punch card, one punch per real (UTC) day: POST /bonus/punch. The
// holes pay a little cash and the seventh a free pack; then a fresh card. One missed day per card
// is forgiven ("Bobby looked the other way"); miss more and the next punch starts a new card.
// Real days, not game days: a game day is 30 minutes, so a per-game-day login bonus would pay
// people to keep the Playdate on. UTC because the Playdate's local clock and time zone are the
// player's to set (and Lua can't do epoch math); the one forgiven day covers the time-zone edge
// (an evening player in UTC-8 punches "today" and "tomorrow" on the same evening at worst).
//
// ODD JOBS. Three small jobs per game day, picked per account from a pool of things the server can
// see happen (a bet, an underdog bet, a prop bet, a comment, a reaction, a job, a market listing
// or bid, a pack; a replay watched to the final out and a story read are reported by the client
// and checked against what it fetched), plus one bigger job per UTC week. Progress is counted from
// the tables where the action is recorded (bets, prop_bets, comments, ops, listings, bids,
// ledger) or from bonus_marks; completion is checked by the server at claim time. A finished job
// is claimed with a press: POST /bonus/jobs/:id/claim. The daily jobs share a petty-cash drawer:
// at most PETTY_CASH claims per UTC day, so someone sitting on the Playdate all day earns about
// what a regular gets from a couple of good bets, not a salary.
//
// Every payout is one D1 batch: [ledger row with a deterministic id, the claim/punch row, the
// account update gated on that ledger row]. A retry collides with the ledger's primary key and
// the batch rolls back, so nothing pays twice; the route then answers with what already happened.

import type { Ctx } from "../router.ts";
import type { GameRow } from "../league.ts";
import { fail, HttpError, oneOf, str } from "../http.ts";
import { accountView } from "./common.ts";

export const DAY_MS = 86_400_000;
/** Odd-job claims per UTC day (the weekly job doesn't count). */
export const PETTY_CASH = 4;
/** Seven holes: cash per hole, the last one a free pack. */
export const HOLES: { cash: number; packs: number }[] = [
  { cash: 10, packs: 0 }, { cash: 15, packs: 0 }, { cash: 20, packs: 0 }, { cash: 25, packs: 0 },
  { cash: 30, packs: 0 }, { cash: 40, packs: 0 }, { cash: 0, packs: 1 },
];
/** Client reports (replay to the final out, a story read): per account per hour. */
export const REPORTS_PER_HOUR = 30;
/** A replay report needs the game's log fetched at least this long before (it was on screen). */
export const REPLAY_MIN_MS = 30_000;

export const utcDay = (now: number) => Math.floor(now / DAY_MS);
export const utcLabel = (d: number) => new Date(d * DAY_MS).toISOString().slice(0, 10);
/** Monday-based UTC week number (1970-01-01 was a Thursday). */
export const utcWeek = (d: number) => Math.floor((d + 3) / 7);
const weekStartDay = (wk: number) => wk * 7 - 3;

// ------------------------------------------------------------------ the punch card

export type PunchRow = { account_id: string; utc_day: number; hole: number; streak: number; grace: number; cash: number; packs: number; at: number };
export type PunchStep = { hole: number; streak: number; grace: number; graced: boolean; fresh: boolean; lapsed: boolean };

/**
 * What today's punch would be after `last` (the newest punch row, or none). Pure.
 * fresh = a new card starts (first ever, after hole 7, or lapsed); graced = this punch used the
 * card's forgiven day; lapsed = the old card was dropped for missing days.
 */
export function nextPunch(last: Pick<PunchRow, "utc_day" | "hole" | "streak" | "grace"> | undefined, today: number): PunchStep {
  if (!last) return { hole: 1, streak: 1, grace: 0, graced: false, fresh: true, lapsed: false };
  const gap = today - last.utc_day;
  if (gap <= 0) return { hole: last.hole, streak: last.streak, grace: last.grace, graced: false, fresh: false, lapsed: false };
  const graced = gap === 2 && !last.grace;
  if (gap === 1 || graced) {
    // the streak goes on; after the seventh hole Bobby hands you a new card
    if (last.hole >= HOLES.length) return { hole: 1, streak: last.streak + 1, grace: graced ? 1 : 0, graced, fresh: true, lapsed: false };
    return { hole: last.hole + 1, streak: last.streak + 1, grace: last.grace || (graced ? 1 : 0), graced, fresh: false, lapsed: false };
  }
  return { hole: 1, streak: 1, grace: 0, graced: false, fresh: true, lapsed: true };
}

const holeReward = (hole: number) => HOLES[Math.max(0, Math.min(HOLES.length, hole) - 1)];
const rewardLabel = (r: { cash: number; packs: number; heat?: number }) => {
  const parts: string[] = [];
  if (r.packs) parts.push(r.packs > 1 ? `${r.packs} free packs` : "Free pack");
  if (r.cash) parts.push(`$${r.cash}`);
  if (r.heat) parts.push(`Heat -${r.heat}`);
  return parts.join(" + ") || "Bobby's gratitude";
};

const PUNCH_LINES = [
  "Bobby punched your card without looking up.",
  "Bobby punched your card and asked about your mother.",
  "Bobby punched your card with a cigar in his mouth.",
  "Punched. Bobby says you're a regular now. He says that to everybody.",
  "Bobby punched your card. The punch is shaped like a horseshoe.",
  "Punched. Somebody in the back room laughed at nothing.",
];

async function lastPunch(c: Ctx, id = c.acct.id): Promise<PunchRow | undefined> {
  return (await c.db.prepare("SELECT * FROM punches WHERE account_id = ? ORDER BY utc_day DESC LIMIT 1").bind(id).first<PunchRow>()) ?? undefined;
}

type CardView = {
  hole: number; punchedToday: boolean; streak: number; best: number; total: number; graceLeft: boolean; lapsed?: true;
  holes: { n: number; reward: string; cash: number; packs: number; stamped: boolean; today?: true; graced?: true }[];
  nextAt: number; utcDay: string;
};

async function cardView(c: Ctx): Promise<CardView> {
  const today = utcDay(c.now);
  const rows = (await c.db.prepare("SELECT * FROM punches WHERE account_id = ? ORDER BY utc_day DESC LIMIT 7").bind(c.acct.id).all<PunchRow>()).results;
  const stats = (await c.db.prepare("SELECT COUNT(*) AS n, COALESCE(MAX(streak), 0) AS best FROM punches WHERE account_id = ?").bind(c.acct.id).first<{ n: number; best: number }>())!;
  const last = rows[0];
  const punchedToday = !!last && last.utc_day === today;
  const step = nextPunch(last, today);
  // the card on show: today's (punched) or the one the next punch lands on
  const showLast = last && (punchedToday || !step.fresh);
  const hole = showLast ? last!.hole : 0;
  // the current card's punches (newest first, back to its first hole)
  const onCard: PunchRow[] = [];
  if (showLast) for (const r of rows) { onCard.push(r); if (r.hole === 1) break; }
  const graceUsed = showLast ? !!last!.grace : false;
  const holes = HOLES.map((h, i) => {
    const p = onCard.find(r => r.hole === i + 1);
    return {
      n: i + 1, reward: rewardLabel(h), cash: h.cash, packs: h.packs, stamped: !!p,
      ...(p && p.utc_day === today ? { today: true as const } : {}),
      // a hole punched the day after a gap: the forgiven day sits just before it
      ...(p && onCard.find(r => r.hole === i) && onCard.find(r => r.hole === i)!.utc_day === p.utc_day - 2 ? { graced: true as const } : {}),
    };
  });
  const out: CardView = {
    hole, punchedToday, streak: last && (punchedToday || !step.lapsed) ? last.streak : 0, best: stats.best, total: stats.n,
    graceLeft: !graceUsed, holes, nextAt: (today + 1) * DAY_MS, utcDay: utcLabel(today),
  };
  if (last && !punchedToday && step.lapsed) out.lapsed = true;
  return out;
}

export async function punch(c: Ctx) {
  const today = utcDay(c.now);
  const last = await lastPunch(c);
  if (last && last.utc_day >= today) {
    return { punched: false, hole: last.hole, reward: { cash: last.cash, packs: last.packs, label: rewardLabel(last) }, line: "Already punched today. Bobby remembers faces.", account: await accountView(c), ...(await bonusDoc(c)) };
  }
  const step = nextPunch(last, today);
  const r = holeReward(step.hole);
  // the n-th punch: two at once both try the same ledger id and one of them rolls back
  const n = (await one(c, "SELECT COUNT(*) AS n FROM punches WHERE account_id = ?", c.acct.id)) + 1;
  const tx = `punch:${c.acct.id}:${n}`;
  const gate = "EXISTS (SELECT 1 FROM ledger WHERE id = ?)";
  try {
    await c.db.batch([
      c.db.prepare(`INSERT INTO ledger (id, account_id, delta, reason, at, season, syndicate_id) SELECT ?, a.id, ?, 'bonus_punch', ?, ?, a.syndicate_id FROM accounts a WHERE a.id = ?`)
        .bind(tx, r.cash, c.now, c.L.state.season, c.acct.id),
      c.db.prepare(`INSERT INTO punches (account_id, utc_day, hole, streak, grace, cash, packs, at) SELECT ?, ?, ?, ?, ?, ?, ?, ? WHERE ${gate}`)
        .bind(c.acct.id, today, step.hole, step.streak, step.grace, r.cash, r.packs, c.now, tx),
      c.db.prepare(`UPDATE accounts SET money = money + ?, free_packs = free_packs + ? WHERE id = ? AND ${gate}`).bind(r.cash, r.packs, c.acct.id, tx),
    ]);
  } catch (e) {
    // a retry of today's punch (or two at once): the ledger id is taken, nothing happened twice
    if (!isConstraint(e)) throw e;
    const now = await lastPunch(c);
    if (!now || now.utc_day !== today) throw e;
    return { punched: false, hole: now.hole, reward: { cash: now.cash, packs: now.packs, label: rewardLabel(now) }, line: "Already punched today. Bobby remembers faces.", account: await accountView(c), ...(await bonusDoc(c)) };
  }
  let line = PUNCH_LINES[(today + step.streak) % PUNCH_LINES.length];
  if (step.graced) line = "You missed a day. Bobby looked the other way. Once.";
  else if (step.lapsed) line = "Your old card went through the wash. Bobby gave you a new one.";
  else if (step.hole === HOLES.length) line = "Full card! Bobby slid a free pack across the counter. Pick it up at the Card Shop.";
  else if (step.fresh && last) line = "New card. Bobby keeps the old ones in a shoebox.";
  return { punched: true, hole: step.hole, streak: step.streak, graced: step.graced, lapsed: step.lapsed, reward: { cash: r.cash, packs: r.packs, label: rewardLabel(r) }, line, account: await accountView(c), ...(await bonusDoc(c)) };
}

const isConstraint = (e: unknown) => /UNIQUE|PRIMARY KEY|constraint/i.test(String((e as Error)?.message ?? e));

// ------------------------------------------------------------------ odd jobs

type Acct = { id: string; heat: number; crew: number; syndicate: boolean };
type Win = { from: number; to: number };
/** go: where the client sends you to do it */
type JobDef = { kind: string; text: string; need: number; cash: number; packs?: number; go: string; group?: string; eligible?: (a: Acct) => boolean; count: (c: Ctx, w: Win) => Promise<number> };

const one = async (c: Ctx, sql: string, ...args: unknown[]) => ((await c.db.prepare(sql).bind(...args).first<{ n: number }>())?.n ?? 0);
const marks = (kind: string) => (c: Ctx, w: Win) => one(c, "SELECT COUNT(*) AS n FROM bonus_marks WHERE account_id = ? AND kind = ? AND at >= ? AND at < ?", c.acct.id, kind, w.from, w.to);
const betsPlaced = (c: Ctx, w: Win) => one(c, "SELECT COUNT(DISTINCT game_id) AS n FROM bets WHERE account_id = ? AND placed_at >= ? AND placed_at < ?", c.acct.id, w.from, w.to);
const propsPlaced = (c: Ctx, w: Win) => one(c, "SELECT COUNT(*) AS n FROM prop_bets WHERE account_id = ? AND placed_at >= ? AND placed_at < ?", c.acct.id, w.from, w.to);
const posts = (like: string) => (c: Ctx, w: Win) => one(c, "SELECT COUNT(*) AS n FROM comments WHERE author_id = ? AND thread LIKE ? AND at >= ? AND at < ?", c.acct.id, like, w.from, w.to);

export const DAILY: JobDef[] = [
  { kind: "bet", group: "bet", text: "Put money on any game at Bobby's.", need: 1, cash: 5, go: "bets", count: betsPlaced },
  { kind: "bet3", group: "bet", text: "Bet three different games. Spread it around.", need: 3, cash: 15, go: "bets", count: betsPlaced },
  { kind: "underdog", text: "Back an underdog. Somebody has to.", need: 1, cash: 10, go: "bets", count: marks("underdog") },
  { kind: "prop", text: "Bet on a ballplayer's private life at the Gossip Board.", need: 1, cash: 10, go: "gossip", count: propsPlaced },
  { kind: "story", group: "post", text: "Leave a comment under a SportsWire story.", need: 1, cash: 5, go: "news", count: posts("story:%") },
  { kind: "bbs", group: "post", text: "Post something on the Clubhouse BBS.", need: 1, cash: 5, go: "bbs", count: posts("bbs:%") },
  { kind: "guestbook", group: "post", text: "Sign a ballplayer's guestbook. Be nice. Or don't.", need: 1, cash: 5, go: "fanpage", count: posts("person:%") },
  { kind: "react", text: "Rate somebody's comment: Agree, LOL or Rat.", need: 1, cash: 5, go: "news", count: marks("react") },
  { kind: "replay", text: "Watch a game on BallCast to the final out.", need: 1, cash: 10, go: "scores", count: marks("replay") },
  { kind: "read", text: "Read a story at SportsWire. The whole thing, ideally.", need: 1, cash: 5, go: "news", count: marks("read") },
  { kind: "job", text: "Send your crew on a job. Any job.", need: 1, cash: 15, go: "bbs", eligible: a => a.crew > 0,
    count: (c, w) => one(c, "SELECT COUNT(*) AS n FROM ops WHERE account_id = ? AND status != 'cancelled' AND created_at >= ? AND created_at < ?", c.acct.id, w.from, w.to) },
  { kind: "market", text: "List a card or bid on one at Bidz-R-Us.", need: 1, cash: 5, go: "market",
    count: async (c, w) => (await one(c, "SELECT COUNT(*) AS n FROM listings WHERE seller_id = ? AND created_at >= ? AND created_at < ?", c.acct.id, w.from, w.to))
      + (await one(c, "SELECT COUNT(*) AS n FROM bids WHERE bidder_id = ? AND auto = 0 AND at >= ? AND at < ?", c.acct.id, w.from, w.to)) },
  { kind: "pack", text: "Open a pack at the Card Shop. Smell the gum.", need: 1, cash: 10, go: "shop",
    count: (c, w) => one(c, "SELECT COUNT(*) AS n FROM ledger WHERE account_id = ? AND reason = 'pack' AND at >= ? AND at < ?", c.acct.id, w.from, w.to) },
];

export const WEEKLY: JobDef[] = [
  { kind: "w_win", text: "Win 5 bets this week.", need: 5, cash: 40, packs: 1, go: "bets",
    count: (c, w) => one(c, "SELECT COUNT(*) AS n FROM bets WHERE account_id = ? AND status = 'settled' AND payout > amount AND settled_at >= ? AND settled_at < ?", c.acct.id, w.from, w.to) },
  { kind: "w_bets", text: "Bet 15 different games this week.", need: 15, cash: 40, packs: 1, go: "bets", count: betsPlaced },
  { kind: "w_posts", text: "Post 6 comments this week. Anywhere. About anything.", need: 6, cash: 40, packs: 1, go: "news", count: posts("%") },
  { kind: "w_props", text: "Place 5 bets at the Gossip Board this week.", need: 5, cash: 40, packs: 1, go: "gossip", count: propsPlaced },
  { kind: "w_jobs", text: "Pull off 2 crew jobs this week. Clean ones.", need: 2, cash: 40, packs: 1, go: "bbs", eligible: a => a.crew > 0,
    count: (c, w) => one(c, "SELECT COUNT(*) AS n FROM ops WHERE account_id = ? AND status = 'done' AND created_at >= ? AND created_at < ?", c.acct.id, w.from, w.to) },
];

const WEEK_SLOT = 9;
const defOf = (kind: string) => DAILY.find(d => d.kind === kind) ?? WEEKLY.find(d => d.kind === kind);

/** Small deterministic hash (FNV-1a) for picking an account's jobs. */
function hash(s: string): number {
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193); }
  return h >>> 0;
}

/** Three daily jobs for an account and period: distinct kinds, at most one per group. Pure. */
export function pickDaily(a: Acct, period: string): JobDef[] {
  const pool = DAILY.filter(d => !d.eligible || d.eligible(a));
  const out: JobDef[] = [];
  let h = hash(`${a.id}:${period}`);
  const left = [...pool];
  while (out.length < 3 && left.length) {
    h = Math.imul(h ^ (h >>> 15), 0x2c1b3c6d) >>> 0;
    const d = left.splice(h % left.length, 1)[0];
    if (d.group && out.some(o => o.group === d.group)) continue;
    out.push(d);
  }
  return out;
}
export function pickWeekly(a: Acct, week: number): JobDef {
  const pool = WEEKLY.filter(d => !d.eligible || d.eligible(a));
  return pool[hash(`${a.id}:w${week}`) % pool.length];
}

type JobRow = { account_id: string; period: string; slot: number; kind: string; need: number; cash: number; packs: number; heat: number; from_at: number; to_at: number; claim_until: number; claimed_at: number | null; claim_day: number | null };

async function acctFacts(c: Ctx): Promise<Acct> {
  const r = await c.db.prepare(`SELECT a.heat, a.syndicate_id, (SELECT COUNT(*) FROM crew WHERE account_id = a.id AND status NOT IN ('gone', 'dead')) AS crew
    FROM accounts a WHERE a.id = ?`).bind(c.acct.id).first<{ heat: number; syndicate_id: string | null; crew: number }>();
  return { id: c.acct.id, heat: r?.heat ?? 0, crew: r?.crew ?? 0, syndicate: !!r?.syndicate_id };
}

/** The account's rows for today's game day and this UTC week, created on first sight. */
async function ensureJobs(c: Ctx): Promise<{ daily: JobRow[]; week: JobRow; period: string; endsAt: number }> {
  const d = c.L.shownDay(c.now);
  const period = `s${d.season}d${d.day}`;
  const wk = utcWeek(utcDay(c.now));
  const wperiod = `w${wk}`;
  const load = () => c.db.prepare("SELECT * FROM odd_jobs WHERE account_id = ? AND period IN (?, ?) ORDER BY slot").bind(c.acct.id, period, wperiod).all<JobRow>();
  let rows = (await load()).results;
  const haveDaily = rows.some(r => r.period === period), haveWeek = rows.some(r => r.period === wperiod);
  if (!haveDaily || !haveWeek) {
    const a = await acctFacts(c);
    const ins: D1PreparedStatement[] = [];
    const add = (p: string, slot: number, j: JobDef, from: number, to: number, until: number, heat = 0) => ins.push(c.db.prepare(
      `INSERT OR IGNORE INTO odd_jobs (account_id, period, slot, kind, need, cash, packs, heat, from_at, to_at, claim_until, created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)`)
      .bind(c.acct.id, p, slot, j.kind, j.need, heat ? 0 : j.cash, j.packs ?? 0, heat, from, to, until, c.now));
    if (!haveDaily) {
      // claimable through the next game day too (finish at 11:59, collect after the bell)
      pickDaily(a, period).forEach((j, i) => add(period, i, j, d.startAt, d.nextDayAt, d.nextDayAt + c.L.dayMs,
        // running hot: Bobby pays the third job in phone calls downtown instead of cash
        i === 2 && a.heat >= 2 ? 1 : 0));
    }
    if (!haveWeek) {
      const from = weekStartDay(wk) * DAY_MS, to = from + 7 * DAY_MS;
      add(wperiod, WEEK_SLOT, pickWeekly(a, wk), from, to, to + DAY_MS);
    }
    await c.db.batch(ins);
    rows = (await load()).results;
  }
  return { daily: rows.filter(r => r.period === period), week: rows.find(r => r.period === wperiod)!, period, endsAt: d.nextDayAt };
}

type OddJob = { id: string; kind: string; text: string; need: number; have: number; status: "open" | "done" | "claimed";
  reward: { cash: number; packs: number; heat: number; label: string }; go: string; endsAt: number; claimUntilAt: number; weekly?: true };

async function jobView(c: Ctx, r: JobRow): Promise<OddJob> {
  const def = defOf(r.kind);
  const have = r.claimed_at ? r.need : Math.min(r.need, def ? await def.count(c, { from: r.from_at, to: r.to_at }) : 0);
  const reward = { cash: r.cash, packs: r.packs, heat: r.heat, label: rewardLabel(r) };
  return {
    id: `${r.period}:${r.slot}`, kind: r.kind, text: def?.text ?? r.kind, need: r.need, have,
    status: r.claimed_at ? "claimed" : have >= r.need ? "done" : "open", reward, go: def?.go ?? "desktop",
    endsAt: r.to_at, claimUntilAt: r.claim_until, ...(r.slot === WEEK_SLOT ? { weekly: true as const } : {}),
  };
}

async function pettyLeft(c: Ctx): Promise<number> {
  const used = await one(c, `SELECT COUNT(*) AS n FROM odd_jobs WHERE account_id = ? AND claim_day = ? AND slot != ${WEEK_SLOT}`, c.acct.id, utcDay(c.now));
  return Math.max(0, PETTY_CASH - used);
}

/** The whole page doc: the card, today's jobs, the week's job and the petty cash. */
async function bonusDoc(c: Ctx) {
  const j = await ensureJobs(c);
  // yesterday's finished-but-unclaimed jobs can still be collected (the bell rang mid-job)
  const prev = (await c.db.prepare("SELECT * FROM odd_jobs WHERE account_id = ? AND slot != ? AND period != ? AND claimed_at IS NULL AND claim_until > ? AND to_at <= ? ORDER BY to_at DESC LIMIT 3")
    .bind(c.acct.id, WEEK_SLOT, j.period, c.now, c.now).all<JobRow>()).results;
  const leftovers = (await Promise.all(prev.map(r => jobView(c, r)))).filter(v => v.status === "done");
  const jobs = await Promise.all(j.daily.map(r => jobView(c, r)));
  const week = await jobView(c, j.week);
  const all = [...leftovers, ...jobs, week];
  const petty = await pettyLeft(c);
  const claimable = all.filter(v => v.status === "done" && (v.weekly || petty > 0)).length;
  return {
    card: await cardView(c), day: c.L.shownDay(c.now).day, endsAt: j.endsAt,
    jobs, ...(leftovers.length ? { leftovers } : {}), week,
    pettyCash: { left: petty, max: PETTY_CASH, refillAt: (utcDay(c.now) + 1) * DAY_MS }, claimable,
  };
}

export async function get(c: Ctx) {
  return bonusDoc(c);
}

const CLAIM_LINES = [
  "Bobby counted it out twice. Once for you, once for the camera that isn't there.",
  "Bobby paid you from a cigar box marked PETTY.",
  "Bobby slid an envelope across the counter. It was already open.",
  "Paid in small bills. Some of them are Canadian.",
  "Bobby paid you and said nothing. That's a compliment.",
];

export async function claim(c: Ctx) {
  const m = /^((?:s\d+d\d+)|(?:w\d+)):(\d+)$/.exec(c.params[0] ?? "");
  if (!m) fail("bad_request", "job ids look like s1d5:0 or w2900:9");
  const [, period, slotS] = m!;
  const slot = Number(slotS);
  const row = await c.db.prepare("SELECT * FROM odd_jobs WHERE account_id = ? AND period = ? AND slot = ?").bind(c.acct.id, period, slot).first<JobRow>();
  if (!row) fail("not_found", "no such job on your board");
  const r = row!;
  const already = async () => {
    const v = await jobView(c, (await c.db.prepare("SELECT * FROM odd_jobs WHERE account_id = ? AND period = ? AND slot = ?").bind(c.acct.id, period, slot).first<JobRow>())!);
    return { claimed: true, again: true, job: v, line: "Already paid. Bobby doesn't pay twice.", account: await accountView(c), ...(await bonusDoc(c)) };
  };
  if (r.claimed_at) return already();
  if (c.now >= r.claim_until) fail("window_closed", "that job's off the board. Bobby found somebody else");
  const v = await jobView(c, r);
  if (v.status !== "done") fail("bad_request", `not done yet (${v.have}/${v.need})`);
  const weekly = slot === WEEK_SLOT;
  const day = utcDay(c.now);
  const tx = `job:${c.acct.id}:${period}:${slot}`;
  const gate = "EXISTS (SELECT 1 FROM ledger WHERE id = ?)";
  // the drawer: the ledger row (and with it everything) only goes in while there's petty cash left
  const cap = weekly ? "" : `AND (SELECT COUNT(*) FROM odd_jobs WHERE account_id = a.id AND claim_day = ? AND slot != ${WEEK_SLOT}) < ${PETTY_CASH}`;
  let res: D1Result[];
  try {
    res = await c.db.batch([
      c.db.prepare(`INSERT INTO ledger (id, account_id, delta, reason, at, season, syndicate_id) SELECT ?, a.id, ?, ?, ?, ?, a.syndicate_id FROM accounts a WHERE a.id = ? ${cap}`)
        .bind(tx, r.cash, weekly ? "bonus_week" : "bonus_job", c.now, c.L.state.season, c.acct.id, ...(weekly ? [] : [day])),
      c.db.prepare(`UPDATE odd_jobs SET claimed_at = ?, claim_day = ? WHERE account_id = ? AND period = ? AND slot = ? AND claimed_at IS NULL AND ${gate}`)
        .bind(c.now, day, c.acct.id, period, slot, tx),
      c.db.prepare(`UPDATE accounts SET money = money + ?, free_packs = free_packs + ?, heat = MAX(0, heat - ?) WHERE id = ? AND ${gate}`)
        .bind(r.cash, r.packs, r.heat, c.acct.id, tx),
    ]);
  } catch (e) {
    if (!isConstraint(e)) throw e;
    return already();
  }
  if (!(res[0].meta.changes ?? 0)) {
    const wait = Math.ceil(((day + 1) * DAY_MS - c.now) / 1000);
    throw new HttpError("rate_limited", `Bobby's petty-cash drawer is empty until midnight (UTC). ${PETTY_CASH} jobs a day.`, 429, wait);
  }
  const fresh = (await c.db.prepare("SELECT * FROM odd_jobs WHERE account_id = ? AND period = ? AND slot = ?").bind(c.acct.id, period, slot).first<JobRow>())!;
  const line = r.heat ? "Bobby made a phone call downtown. Somebody lost a file." : r.packs ? "Bobby threw in a pack. It's at the Card Shop, under your name." : CLAIM_LINES[hash(tx) % CLAIM_LINES.length];
  return { claimed: true, job: await jobView(c, fresh), line, account: await accountView(c), ...(await bonusDoc(c)) };
}

// ------------------------------------------------------------------ marks (server side)

/** Statement that records a mark (an underdog bet, a reaction): idempotent per (kind, ref). */
export const markStmt = (c: Ctx, kind: string, ref: string) =>
  c.db.prepare("INSERT OR IGNORE INTO bonus_marks (account_id, kind, ref, at) VALUES (?, ?, ?, ?)").bind(c.acct.id, kind, ref, c.now);

/**
 * POST /bonus/report { kind: "replay" | "read", ref }: the client says it watched a replay to the
 * final out or read a story. Checked against what the account fetched (the DO remembers the
 * first fetch of a game's log or a story per account), rate-limited, and worth $5-15 at most.
 */
export async function report(c: Ctx) {
  const kind = oneOf(c.body, "kind", ["replay", "read"] as const);
  const ref = str(c.body, "ref", 80);
  const wait = c.L.rateLimit(`bonus:${c.acct.id}`, REPORTS_PER_HOUR, 3_600_000, c.now);
  if (wait) throw new HttpError("rate_limited", "that's a lot of reading. Bobby's suspicious", 429, wait);
  if (kind === "replay") {
    const g = await c.db.prepare("SELECT * FROM games WHERE id = ?").bind(ref).first<GameRow>();
    if (!g || (g.level !== "ML" && g.level !== "EL") || !g.simmed) fail("not_found", "no replay of that game");
    // the final out has aired (live viewers get there around finalAt)
    if (c.now < g!.first_pitch_at + g!.air_ms - 90_000) fail("bad_request", "that game isn't over yet");
    const seen = c.L.firstSeen(c.acct.id, `log:${ref}`);
    const min = Number(c.L.bindings.BONUS_REPLAY_MIN_MS ?? REPLAY_MIN_MS);
    if (seen === undefined || c.now - seen < min) fail("bad_request", "watch it first");
  } else {
    const s = await c.db.prepare("SELECT 1 AS ok FROM stories WHERE id = ? AND publish_at <= ?").bind(ref, c.now).first();
    if (!s) fail("not_found", "no such story");
    if (c.L.firstSeen(c.acct.id, `story:${ref}`) === undefined) fail("bad_request", "read it first");
  }
  const r = await markStmt(c, kind, ref).run();
  return { marked: (r.meta.changes ?? 0) > 0, ...(await bonusDoc(c)) };
}
