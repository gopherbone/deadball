// Helpers shared by route handlers.

import type { Ctx } from "../router.ts";
import type { GameRow, League } from "../league.ts";
import { fail, newId } from "../http.ts";
import { paysFor, parseWaves, visible } from "../house.ts";
import {
  finalInning, formatWeather, partialLine, personRef, rankFor, scoreAt, teamRef,
  type GameSummaryRow, type PersonRef, type TeamRef,
} from "../views.ts";

export type Account = { id: string; name: string; money: number; heat: number; crewSize: number; unreadMail: number; cards: number; joinedDay: number; rank: string; syndicateId?: string; /** money held in escrow for your leading auction bids */ escrow?: number };

export async function accountView(c: Ctx, id = c.acct.id): Promise<Account> {
  const r = await c.db.prepare(`SELECT a.id, a.name, a.money, a.heat, a.joined_day, a.syndicate_id,
      (SELECT COALESCE(SUM(amount), 0) FROM holds WHERE account_id = a.id) AS escrow,
      (SELECT COUNT(*) FROM crew WHERE account_id = a.id AND status NOT IN ('gone', 'dead')) AS crew_size,
      (SELECT COUNT(*) FROM mail WHERE account_id = a.id AND read = 0 AND at <= ?) AS unread,
      (SELECT COUNT(*) FROM cards WHERE owner_id = a.id) AS cards
    FROM accounts a WHERE a.id = ?`).bind(c.now, id).first<{ id: string; name: string; money: number; heat: number; joined_day: number; syndicate_id: string | null; escrow: number; crew_size: number; unread: number; cards: number }>();
  if (!r) return fail("not_found", "no such account");
  const a: Account = { id: r.id, name: r.name, money: r.money, heat: r.heat, crewSize: r.crew_size, unreadMail: r.unread, cards: r.cards, joinedDay: r.joined_day, rank: rankFor(r.money) };
  if (r.syndicate_id) a.syndicateId = r.syndicate_id;
  if (r.escrow) a.escrow = r.escrow;
  return a;
}

/**
 * Atomic money move. The first statement inserts a ledger row only if the account can
 * afford it (plus any extra `cond` on the accounts row `a`); every following statement
 * must be gated with `gate(tx)` so nothing happens unless that ledger row exists.
 * Returns true if the move happened.
 */
export async function moneyMove(c: Ctx, o: { delta: number; reason: string; cond?: string; condArgs?: unknown[]; then: (tx: string) => D1PreparedStatement[]; account?: string }): Promise<{ ok: boolean; tx: string }> {
  const tx = newId("tx");
  const acct = o.account ?? c.acct.id;
  const first = c.db.prepare(`INSERT INTO ledger (id, account_id, delta, reason, at, season, syndicate_id)
      SELECT ?, a.id, ?, ?, ?, ?, a.syndicate_id FROM accounts a WHERE a.id = ? AND a.money + ? >= 0 ${o.cond ? `AND (${o.cond})` : ""}`)
    .bind(tx, o.delta, o.reason, c.now, c.L.state.season, acct, o.delta, ...(o.condArgs ?? []));
  const upd = c.db.prepare(`UPDATE accounts SET money = money + ? WHERE id = ? AND ${gate()}`).bind(o.delta, acct, tx);
  const res = await c.db.batch([first, upd, ...o.then(tx)]);
  return { ok: (res[0].meta.changes ?? 0) === 1, tx };
}
/** SQL fragment: "the ledger row ? exists" (bind the tx id). */
export const gate = () => `EXISTS (SELECT 1 FROM ledger WHERE id = ?)`;

export function page<T>(rows: T[], limit: number, cursorOf: (last: T) => unknown): { items: T[]; next?: unknown } {
  if (rows.length <= limit) return { items: rows };
  const items = rows.slice(0, limit);
  return { items, next: cursorOf(items[items.length - 1]) };
}
export function limitParam(c: Ctx, def: number, max: number) {
  const v = Number(c.q.get("limit") ?? def);
  return Number.isInteger(v) && v > 0 ? Math.min(v, max) : def;
}

// ------------------------------------------------------------------ games
export type SlateGame = {
  /** bets and jobs on this game lock at firstPitchAt; it airs until finalAt, when its pool settles */
  id: string; day: number; firstPitchAt: number; finalAt: number; status: "scheduled" | "live" | "final";
  home: TeamRef & { record: string }; away: TeamRef & { record: string };
  probables: { home: PersonRef & { line: string }; away: PersonRef & { line: string } };
  score?: { home: number; away: number; inning: string };
  /** home/away include the house's money (`house`, Bobby's regulars); pays = return per $1. */
  pool: { home: number; away: number; pays: { home: number; away: number }; house: { home: number; away: number } };
  umpire: PersonRef; weather: string; park: string;
  myBet?: { side: "home" | "away"; amount: number };
  /** "continental" | "enhanced" (Enhanced League games); exhibitions are Enhanced vs Continental */
  circuit: "continental" | "enhanced";
  exhibition?: true;
};

/** Exhibition ids look like S1D0EX0 (or g1-...EX0). */
export const isExhibition = (id: string) => /EX\d+$/.test(id);

export function gameStatus(row: GameRow, now: number): SlateGame["status"] {
  if (!row.simmed || now < row.first_pitch_at) return "scheduled";
  return now < row.first_pitch_at + row.air_ms ? "live" : "final";
}
/** Pitches aired so far (proportional to elapsed air time). */
export function airedPitches(row: GameRow, sum: GameSummaryRow, now: number): number {
  const f = Math.max(0, Math.min(1, (now - row.first_pitch_at) / row.air_ms));
  return Math.floor(sum.pitches * f);
}

/** A game's pool right now: player money (pool_home/pool_away) plus the house waves that have landed. */
export function gamePool(L: League, row: GameRow, now: number) {
  const waves = parseWaves(row.house);
  // once the game is underway every wave has landed (they all come before first pitch)
  const [hh, ha] = visible(waves, 2, row.first_pitch_at, row.simmed || now >= row.first_pitch_at ? Infinity : now, L.houseScale);
  const player = [row.pool_home, row.pool_away], house = [hh, ha];
  const [ph, pa] = paysFor(player, house);
  return { player, house, view: { home: row.pool_home + hh, away: row.pool_away + ha, pays: { home: ph, away: pa }, house: { home: hh, away: ha } } };
}

export function slateGame(L: League, row: GameRow, now: number, myBet?: { side: string; amount: number }): SlateGame {
  const w = L.world;
  const rec = (teamId: string) => L.records(w.teams[teamId]?.level ?? row.level).get(teamId) ?? "0-0";
  const status = gameStatus(row, now);
  const prob = row.probables ? (JSON.parse(row.probables) as { home: string; away: string }) : { home: L.probable(row.home_id), away: L.probable(row.away_id) };
  const weather = JSON.parse(row.weather);
  const g: SlateGame = {
    id: row.id, day: row.day, firstPitchAt: row.first_pitch_at, finalAt: row.first_pitch_at + row.air_ms, status,
    home: { ...teamRef(w, row.home_id), record: rec(row.home_id) },
    away: { ...teamRef(w, row.away_id), record: rec(row.away_id) },
    probables: { home: L.probableRef(prob.home), away: L.probableRef(prob.away) },
    pool: gamePool(L, row, now).view,
    umpire: personRef(w, row.umpire_id), weather: formatWeather(weather), park: w.parks[w.teams[row.home_id]?.parkId ?? ""]?.name ?? "",
    circuit: row.level === "EL" ? "enhanced" : "continental",
  };
  if (isExhibition(row.id)) g.exhibition = true;
  if (status === "live" && row.summary) {
    const sum = JSON.parse(row.summary) as GameSummaryRow;
    const s = scoreAt(sum, airedPitches(row, sum, now));
    g.score = { home: s.home, away: s.away, inning: s.inning };
  } else if (status === "final") {
    g.score = { home: row.home_runs ?? 0, away: row.away_runs ?? 0, inning: finalInning(row.innings ?? 9) };
  }
  if (myBet) g.myBet = { side: myBet.side as "home" | "away", amount: myBet.amount };
  return g;
}

export async function slateGames(c: Ctx, rows: GameRow[]): Promise<SlateGame[]> {
  if (!rows.length) return [];
  const bets = (await c.db.prepare(`SELECT game_id, side, amount FROM bets WHERE account_id = ? AND game_id IN (SELECT value FROM json_each(?))`)
    .bind(c.acct.id, JSON.stringify(rows.map(r => r.id))).all<{ game_id: string; side: string; amount: number }>()).results;
  const by = new Map(bets.map(b => [b.game_id, b]));
  return rows.map(r => slateGame(c.L, r, c.now, by.get(r.id)));
}

export async function gameRow(c: Ctx, id: string): Promise<GameRow> {
  const row = await c.db.prepare("SELECT * FROM games WHERE id = ?").bind(id).first<GameRow>();
  if (!row) return fail("not_found", "no such game");
  return row;
}

export { partialLine };

// ------------------------------------------------------------------ comments
export type Comment = { id: string; author: string; authorRank: string; text: string; at: number; reactions: { agree: number; lol: number; rat: number } };
export type CommentRow = { id: string; thread: string; text: string; at: number; agree: number; lol: number; rat: number; author: string | null; money: number | null };
/** NPC posts (BBS chatter) carry author_id "npc:<handle>" and no account. */
export const COMMENT_SELECT = `SELECT c.id, c.thread, c.text, c.at, c.agree, c.lol, c.rat, CASE WHEN c.author_id LIKE 'npc:%' THEN substr(c.author_id, 5) ELSE a.name END AS author, a.money AS money FROM comments c LEFT JOIN accounts a ON a.id = c.author_id`;
export const commentView = (r: CommentRow): Comment => ({
  id: r.id, author: r.author ?? "(gone)", authorRank: rankFor(r.money ?? 0), text: r.text, at: r.at, reactions: { agree: r.agree, lol: r.lol, rat: r.rat },
});
export async function latestComments(c: Ctx, thread: string, n: number): Promise<Comment[]> {
  const rows = (await c.db.prepare(`${COMMENT_SELECT} WHERE c.thread = ? ORDER BY c.at DESC, c.id DESC LIMIT ?`).bind(thread, n).all<CommentRow>()).results;
  return rows.map(commentView);
}
