// Redeemable cards on the server: POST /v1/cards/:id/redeem, GET /v1/bulletins, and the
// day-tick hook that feeds active boosts into GameSpecs.
//
// Atomicity (same shape as every money move here):
//   1. CLAIM (one D1 batch, gated by a zero-delta ledger row): the card must still be ours and
//      unlisted. It moves to a holding owner "redeem:<account>" so it can't be sold or redeemed twice.
//   2. APPLY (synchronous, no awaits): the sim applies the printed effect to the World; the World
//      and a "pending redemption" record are persisted to DO storage before anything is awaited.
//   3. COMMIT (one D1 batch): delete the card, write the redemption, boost modifiers, Final Season
//      marks, the bulletin and the notification mail. The first statement is a plain INSERT, so
//      replaying a committed payload fails on the primary key and counts as done. A failed commit
//      is replayed by flushRedemptions() on the next request or day tick.

import type { Ctx } from "./router.ts";
import type { League } from "./league.ts";
import { decCursor, encCursor, fail } from "./http.ts";
import { Rng, performRedeem, checkRedeem, type Card, type SimCard, type RedeemMods, type RedeemResult } from "./sim.ts";
import { cardView, personRef, teamRef } from "./views.ts";
import { accountView, limitParam, page } from "./routes/common.ts";
import { storyKey } from "./league.ts";

const PENDING = "redeem:";

export interface RedeemPayload {
  id: string;
  accountId: string;
  accountName: string;
  cardRowId: string;
  card: Card;
  season: number;
  day: number;
  at: number;
  /** Team whose next game's bettors/op-runners get a heads-up. */
  teamId?: string;
  result: RedeemResult;
}

function commitStmts(L: League, p: RedeemPayload): D1PreparedStatement[] {
  const db = L.db;
  const r = p.result;
  const storyId = storyKey(p.season, r.story.id);
  const stmts: D1PreparedStatement[] = [
    db.prepare("INSERT INTO redemptions (id, account_id, card_id, kind, person_id, team_id, season, day, card, result, story_id, created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)")
      .bind(p.id, p.accountId, p.cardRowId, r.kind, r.personId, p.teamId ?? null, p.season, p.day, JSON.stringify(p.card),
        JSON.stringify({ summary: r.summary, boost: r.boost, days: r.days, fromDay: r.fromDay, untilDay: r.untilDay }), storyId, p.at),
    db.prepare("DELETE FROM cards WHERE id = ? AND owner_id = ?").bind(p.cardRowId, `redeem:${p.accountId}`),
  ];
  // the redeemed card leaves its print run: every surviving copy is a little scarcer
  if (p.card.printRun) {
    stmts.push(db.prepare(`UPDATE cards SET print_run = MAX(1, print_run - 1), data = json_set(data, '$.printRun', MAX(1, print_run - 1))
      WHERE def_id = ? AND print_run IS NOT NULL AND json_extract(data, '$.rarity') = ?`).bind(p.card.id, p.card.rarity));
  }
  for (const m of r.mods) {
    stmts.push(db.prepare("INSERT OR IGNORE INTO redeem_mods (id, redemption_id, person_id, from_day, until_day, data) VALUES (?,?,?,?,?,?)")
      .bind(m.id, p.id, m.personId, m.fromDay, m.untilDay, JSON.stringify(m)));
  }
  if (r.kind === "retire") {
    stmts.push(db.prepare("INSERT OR IGNORE INTO retired_people (person_id, redemption_id, at) VALUES (?,?,?)").bind(r.personId, p.id, p.at));
    stmts.push(db.prepare(`UPDATE cards SET data = json_set(data, '$.finalSeason', json('true')) WHERE json_extract(data, '$.personId') = ?`).bind(r.personId));
  }
  stmts.push(L.storyStmt(r.story, p.season, p.at));
  // heads-up mail to everyone with an open bet on, or a planned op against, the team's next game
  if (p.teamId) {
    const mail = JSON.stringify({
      from: "League Office", subject: r.story.headline, kind: "league", ...(r.story.photo ? { photo: r.story.photo, photoCaption: r.story.photoCaption } : {}),
      body: [...r.story.body.slice(0, 2), "This affects the team's next game, which you have money or a job riding on."],
    });
    stmts.push(db.prepare(`INSERT OR IGNORE INTO mail (id, account_id, at, read, kind, data)
      SELECT 'rdm:' || ?1 || ':' || who, who, ?2, 0, 'league', ?3 FROM (
        SELECT account_id AS who FROM bets WHERE status = 'open' AND game_id = (SELECT id FROM games WHERE simmed = 0 AND (home_id = ?4 OR away_id = ?4) ORDER BY first_pitch_at, id LIMIT 1)
        UNION SELECT account_id FROM ops WHERE status = 'planned' AND target_team_id = ?4 AND game_id = (SELECT id FROM games WHERE simmed = 0 AND (home_id = ?4 OR away_id = ?4) ORDER BY first_pitch_at, id LIMIT 1)
      )`).bind(p.id, p.at, mail, p.teamId));
  }
  return stmts;
}

async function commit(L: League, p: RedeemPayload): Promise<void> {
  try {
    await L.db.batch(commitStmts(L, p));
  } catch (e) {
    if (String((e as Error)?.message ?? e).includes("UNIQUE") && (await L.db.prepare("SELECT 1 FROM redemptions WHERE id = ?").bind(p.id).first())) return; // already committed
    throw e;
  }
}

/** Replay any redemption whose final write didn't land. */
export async function flushRedemptions(L: League): Promise<number> {
  let n = 0;
  for (const k of L.store.metaKeys(PENDING)) {
    const p = L.store.getMeta<RedeemPayload>(k);
    if (p) await commit(L, p);
    L.store.delMeta(k);
    n++;
  }
  return n;
}

/** Redeemed boosts active on this world day. */
export async function activeRedeemMods(L: League, day: number): Promise<RedeemMods[]> {
  const rows = (await L.db.prepare("SELECT data FROM redeem_mods WHERE until_day >= ? AND from_day <= ?").bind(day, day).all<{ data: string }>()).results;
  return rows.map(r => JSON.parse(r.data) as RedeemMods);
}

/** POST /v1/cards/:id/redeem { confirm: true } */
export async function redeem(c: Ctx) {
  const L = c.L;
  if (c.body.confirm !== true) fail("bad_request", "redeeming uses the card up: send confirm: true");
  await flushRedemptions(L);
  const cardId = c.params[0];
  const row = await c.db.prepare("SELECT * FROM cards WHERE id = ? AND owner_id = ?").bind(cardId, c.acct.id).first<{ id: string; data: string; print_run: number | null }>();
  if (!row) fail("not_found", "that card isn't in your binder");
  if (await c.db.prepare("SELECT 1 FROM listings WHERE card_id = ? AND status = 'active'").bind(cardId).first()) fail("bad_request", "take it off the market first");
  const card = JSON.parse(row!.data) as Card;
  if (row!.print_run) card.printRun = row!.print_run;
  const pre = checkRedeem(L.world, card as SimCard);
  if (!pre.ok) fail("bad_request", pre.reason);

  // 1. claim
  const gate = `redeem:${cardId}`;
  const claim = await c.db.batch([
    c.db.prepare(`INSERT OR IGNORE INTO ledger (id, account_id, delta, reason, at, season, syndicate_id)
        SELECT ?, a.id, 0, 'redeem', ?, ?, a.syndicate_id FROM accounts a WHERE a.id = ?
          AND EXISTS (SELECT 1 FROM cards WHERE id = ? AND owner_id = a.id)
          AND NOT EXISTS (SELECT 1 FROM listings WHERE card_id = ? AND status = 'active')`)
      .bind(gate, c.now, L.state.season, c.acct.id, cardId, cardId),
    c.db.prepare("UPDATE cards SET owner_id = ? WHERE id = ? AND owner_id = ? AND EXISTS (SELECT 1 FROM ledger WHERE id = ? AND at = ?)").bind(`redeem:${c.acct.id}`, cardId, c.acct.id, gate, c.now),
  ]);
  if (!claim[1].meta.changes) fail("bad_request", "that card is gone or listed");

  // 2. apply (no awaits until the World and the pending payload are saved)
  const stack = card.redeem?.kind === "boost" ? await boostStack(L, card.personId) : 0;
  const teamId = L.world.players[card.personId]?.teamId ?? Object.values(L.world.teams).find(t => t.managerId === card.personId)?.id;
  const res = performRedeem(L.world, card as SimCard, new Rng(`${L.seed}:redeem:${cardId}`), { id: `rd-${cardId}`, stack, redeemer: c.acct.name });
  if (!res.ok) {
    await c.db.batch([
      c.db.prepare("UPDATE cards SET owner_id = ? WHERE id = ? AND owner_id = ?").bind(c.acct.id, cardId, `redeem:${c.acct.id}`),
      c.db.prepare("DELETE FROM ledger WHERE id = ?").bind(gate),
    ]);
    fail("bad_request", res.reason);
  }
  const r = res as RedeemResult;
  const payload: RedeemPayload = { id: r.id, accountId: c.acct.id, accountName: c.acct.name, cardRowId: cardId, card, season: L.state.season, day: L.world.day, at: c.now, result: r };
  if (teamId && L.world.teams[teamId]) payload.teamId = teamId;
  L.store.setMeta(`${PENDING}${r.id}`, payload);
  if (r.life.length) L.recordMoves({ life: r.life, season: L.state.season } as Parameters<League["recordMoves"]>[0]);
  L.saveWorld();

  // 3. commit
  await commit(L, payload);
  L.store.delMeta(`${PENDING}${r.id}`);

  const out: Record<string, unknown> = {
    result: r.summary, kind: r.kind,
    card: { ...cardView(L.world, cardId, card), redeemed: true },
    story: { id: storyKey(L.state.season, r.story.id), headline: r.story.headline, dek: r.story.dek },
    effect: r.kind === "boost"
      ? { kind: "boost", person: personRef(L.world, r.personId), boost: r.boost, days: r.days, fromDay: r.fromDay, untilDay: r.untilDay }
      : { kind: "retire", person: personRef(L.world, r.personId) },
    account: await accountView(c),
  };
  return out;
}

async function boostStack(L: League, personId: string): Promise<number> {
  const r = await L.db.prepare("SELECT COUNT(*) AS n FROM redeem_mods WHERE person_id = ? AND until_day >= ? AND from_day <= ?").bind(personId, L.world.day, L.world.day).first<{ n: number }>();
  return r?.n ?? 0;
}

type RedemptionRow = { id: string; account_id: string; kind: string; person_id: string; team_id: string | null; day: number; season: number; result: string; story_id: string | null; created_at: number; redeemer: string | null; headline: string | null };

/** GET /v1/bulletins: recent redemptions, newest first (the league ticker). */
export async function bulletins(c: Ctx) {
  const cur = decCursor<[number, string]>(c.q.get("cursor"));
  const limit = limitParam(c, 15, 40);
  const rows = (await c.db.prepare(`SELECT r.*, a.name AS redeemer, s.headline AS headline FROM redemptions r LEFT JOIN accounts a ON a.id = r.account_id LEFT JOIN stories s ON s.id = r.story_id
      ${cur ? "WHERE (r.created_at < ? OR (r.created_at = ? AND r.id < ?))" : ""} ORDER BY r.created_at DESC, r.id DESC LIMIT ?`)
    .bind(...(cur ? [cur[0], cur[0], cur[1]] : []), limit + 1).all<RedemptionRow>()).results;
  const p = page(rows, limit, l => [l.created_at, l.id]);
  const out: { bulletins: unknown[]; next?: string } = {
    bulletins: p.items.map(r => {
      const res = JSON.parse(r.result) as { boost?: number; days?: number; untilDay?: number };
      return {
        id: r.id, at: r.created_at, season: r.season, day: r.day, kind: r.kind, text: r.headline ?? "Card redeemed",
        person: personRef(c.L.world, r.person_id), ...(r.team_id ? { team: teamRef(c.L.world, r.team_id) } : {}),
        redeemer: r.redeemer ?? "(gone)", ...(r.story_id ? { storyId: r.story_id } : {}),
        ...(r.kind === "boost" ? { boost: res.boost, days: res.days, untilDay: res.untilDay } : {}),
      };
    }),
  };
  if (p.next) out.next = encCursor(p.next);
  return out;
}
