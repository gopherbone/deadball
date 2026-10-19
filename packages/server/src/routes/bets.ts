import type { Ctx } from "../router.ts";
import type { GameRow } from "../league.ts";
import { decCursor, encCursor, fail, int, newId, oneOf, str } from "../http.ts";
import { accountView, gamePool, gate, gameRow, limitParam, moneyMove, page, slateGame, slateGames } from "./common.ts";

export const MIN_BET = 5;

export async function place(c: Ctx) {
  const gameId = str(c.body, "gameId", 80);
  const side = oneOf(c.body, "side", ["home", "away"] as const);
  const amount = int(c.body, "amount", MIN_BET, 10_000_000);
  const row = await gameRow(c, gameId);
  if (row.level !== "ML" && row.level !== "EL") fail("bad_request", "betting is on major-league and Enhanced League games only");
  if (row.simmed || c.now >= row.first_pitch_at) fail("window_closed", "betting closed at first pitch");
  if (amount * 2 > c.acct.money) {
    if (amount > c.acct.money) fail("insufficient_funds", "you don't have that kind of money");
    fail("bad_request", `max bet is 50% of your money ($${Math.floor(c.acct.money / 2)})`);
  }
  const existing = await c.db.prepare("SELECT side FROM bets WHERE account_id = ? AND game_id = ?").bind(c.acct.id, gameId).first<{ side: string }>();
  if (existing && existing.side !== side) fail("bad_request", "you already bet the other side of this game");
  // odd jobs: an underdog is the side the pool pays more on before this bet lands
  const before = gamePool(c.L, row, c.now).view.pays;
  const underdog = before[side] > before[side === "home" ? "away" : "home"];
  const betId = newId("b");
  const { ok } = await moneyMove(c, {
    delta: -amount, reason: "bet",
    // re-checked atomically: 50% rule, window still open, no bet on the other side
    cond: `a.money >= ? * 2 AND EXISTS (SELECT 1 FROM games g WHERE g.id = ? AND g.simmed = 0 AND g.first_pitch_at > ?) AND NOT EXISTS (SELECT 1 FROM bets WHERE account_id = a.id AND game_id = ? AND side != ?)`,
    condArgs: [amount, gameId, c.now, gameId, side],
    then: tx => [
      c.db.prepare(`INSERT INTO bets (id, account_id, game_id, side, amount, placed_at) SELECT ?, ?, ?, ?, ?, ? WHERE ${gate()}
          ON CONFLICT (account_id, game_id) DO UPDATE SET amount = amount + excluded.amount, placed_at = excluded.placed_at`)
        .bind(betId, c.acct.id, gameId, side, amount, c.now, tx),
      c.db.prepare(`UPDATE games SET pool_${side} = pool_${side} + ? WHERE id = ? AND ${gate()}`).bind(amount, gameId, tx),
      ...(underdog ? [c.db.prepare(`INSERT OR IGNORE INTO bonus_marks (account_id, kind, ref, at) SELECT ?, 'underdog', ?, ? WHERE ${gate()}`).bind(c.acct.id, gameId, c.now, tx)] : []),
    ],
  });
  if (!ok) {
    const fresh = await gameRow(c, gameId);
    if (fresh.simmed || c.now >= fresh.first_pitch_at) fail("window_closed", "betting closed at first pitch");
    fail("insufficient_funds", "not enough money for that bet (max 50% of what you have)");
  }
  const bet = await c.db.prepare("SELECT * FROM bets WHERE account_id = ? AND game_id = ?").bind(c.acct.id, gameId).first<BetRow>();
  const g = slateGame(c.L, await gameRow(c, gameId), c.now, bet!);
  return { bet: betView(bet!), pool: g.pool, account: await accountView(c) };
}

export type BetRow = { id: string; account_id: string; game_id: string; side: string; amount: number; status: string; payout: number; placed_at: number; settled_at: number | null };
export const betView = (b: BetRow) => ({
  id: b.id, gameId: b.game_id, side: b.side, amount: b.amount, status: b.status === "settled" ? "settled" : "open",
  ...(b.status === "settled" ? { payout: b.payout, won: b.payout > b.amount } : {}), placedAt: b.placed_at,
});

export async function list(c: Ctx) {
  const status = c.q.get("status") ?? "open";
  if (status !== "open" && status !== "settled") fail("bad_request", "status must be open or settled");
  const cur = decCursor<[number, string]>(c.q.get("cursor"));
  const limit = limitParam(c, 20, 50);
  const rows = (await c.db.prepare(`SELECT * FROM bets WHERE account_id = ? AND status ${status === "open" ? "!= 'settled'" : "= 'settled'"}
      ${cur ? "AND (placed_at < ? OR (placed_at = ? AND id < ?))" : ""} ORDER BY placed_at DESC, id DESC LIMIT ?`)
    .bind(c.acct.id, ...(cur ? [cur[0], cur[0], cur[1]] : []), limit + 1).all<BetRow>()).results;
  const p = page(rows, limit, l => [l.placed_at, l.id]);
  const games = p.items.length
    ? (await c.db.prepare("SELECT * FROM games WHERE id IN (SELECT value FROM json_each(?))").bind(JSON.stringify(p.items.map(b => b.game_id))).all<GameRow>()).results
    : [];
  const views = new Map((await slateGames(c, games)).map(g => [g.id, g]));
  const out: { bets: unknown[]; next?: string } = { bets: p.items.map(b => ({ ...betView(b), game: views.get(b.game_id) })) };
  if (p.next) out.next = encCursor(p.next);
  return out;
}
