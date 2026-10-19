// Syndicate "chip in": allies share the cost of a joint job (migrations/0004_chipin.sql).
//
// The orderer pays the whole job up front, as before. With `chipIn: true` on POST /ops, every
// ally whose crew is on the job is asked for their share (sim splitCost: the job cost split
// evenly, the orderer keeps the gear and the odd dollars) by event card and mail. Accepting
// moves the share from the ally to the orderer in one ledger-gated batch; declining leaves the
// orderer paying. Unanswered asks expire when the job locks (first pitch, or the next day's play
// for a storyline-only job). Cancelling a planned job (DELETE /ops/:id), or a job called off
// before it starts (nobody free, the story over, banned at the turnstiles), refunds the
// orderer's part and every paid share.

import type { Ctx } from "../router.ts";
import type { GameRow, League, OpRow } from "../league.ts";
import { fail } from "../http.ts";
import { sim, splitCost, type CrewMember, type OpOrder } from "../sim.ts";
import { teamRef } from "../views.ts";
import { accountView, gate, gameRow, moneyMove } from "./common.ts";
import { opViews } from "./crew.ts";

export type ShareRow = { op_id: string; account_id: string; amount: number; status: string; created_at: number; decided_at: number | null };
export type ShareStatus = "proposed" | "paid" | "declined" | "expired" | "refunded" | "void";

const jobName = (kind: string) => sim.OP_KINDS.find(k => k.kind === kind)?.name ?? kind;

/** Allies' shares of a joint order: account id -> $ (the orderer is left out; they paid it all). */
export function allyShares(order: OpOrder, crew: Record<string, CrewMember>): Record<string, number> {
  const split = splitCost(order, crew);
  const out: Record<string, number> = {};
  for (const [acct, amt] of Object.entries(split)) if (acct !== order.ownerId && amt > 0) out[acct] = amt;
  return out;
}

/** "HCL @ STA, Day 5" or "a storyline job". */
function whereText(L: League, g: GameRow | undefined) {
  if (!g) return "a storyline job";
  const w = L.world;
  return `${w.teams[g.away_id]?.abbr ?? g.away_id} @ ${w.teams[g.home_id]?.abbr ?? g.home_id}, Day ${g.day}`;
}

/**
 * Statements that file the asks (rows, event cards, mail). Gated on the order's ledger row so
 * they only happen if the order went through. `lockAt` is when unanswered asks lapse.
 */
export function proposeStmts(c: Ctx, tx: string, o: { id: string; kind: string; targetTeamId: string; cost: number; g?: GameRow; lockAt: number }, shares: Record<string, number>): D1PreparedStatement[] {
  const out: D1PreparedStatement[] = [];
  const team = c.L.world.teams[o.targetTeamId]?.name ?? "them";
  const where = whereText(c.L, o.g);
  for (const [acct, amount] of Object.entries(shares)) {
    const card = {
      id: `ev-chip-${o.id}-${acct}`, ownerId: acct, title: "Chip In?",
      body: `${c.acct.name} is running "${jobName(o.kind)}" against the ${team} (${where}) with your crew. Your share: $${amount} of $${o.cost}.`,
      choices: [{ key: "accept", label: `Chip in $${amount}`, cost: amount }, { key: "decline", label: "Let them pay" }],
      chipIn: o.id,
    };
    out.push(
      c.db.prepare(`INSERT INTO op_shares (op_id, account_id, amount, status, created_at) SELECT ?, ?, ?, 'proposed', ? WHERE ${gate()}`).bind(o.id, acct, amount, c.now, tx),
      c.db.prepare(`INSERT INTO events (id, account_id, at, expires_at, status, data) SELECT ?, ?, ?, ?, 'pending', ? WHERE ${gate()}`).bind(card.id, acct, c.now, o.lockAt, JSON.stringify(card), tx),
      c.db.prepare(`INSERT INTO mail (id, account_id, at, read, kind, data) SELECT ?, ?, ?, 0, 'op', ? WHERE ${gate()}`).bind(`chip:${o.id}:${acct}`, acct, c.now, JSON.stringify({
        from: "The Clubhouse BBS", subject: `Chip in? ${jobName(o.kind)}`, kind: "op",
        body: [`${c.acct.name} has your crew on "${jobName(o.kind)}" against the ${team} (${where}).`, `Your share is $${amount} of $${o.cost}. Answer on the syndicate page or the event card before the job locks.`],
      }), tx),
    );
  }
  return out;
}

type ShareCtx = ShareRow & { orderer: string; orderer_name: string; kind: string; game_id: string; target_team_id: string; op_status: string; syndicate_id: string | null; cost: number };

async function shareFor(c: Ctx, opId: string): Promise<ShareCtx> {
  const s = await c.db.prepare(`SELECT s.*, o.account_id AS orderer, a.name AS orderer_name, o.kind, o.game_id, o.target_team_id, o.status AS op_status, o.syndicate_id, o.cost
      FROM op_shares s JOIN ops o ON o.id = s.op_id JOIN accounts a ON a.id = o.account_id WHERE s.op_id = ? AND s.account_id = ?`).bind(opId, c.acct.id).first<ShareCtx>();
  if (!s) return fail("not_found", "nobody asked you to chip in on that");
  return s;
}

/** SQL: the share is still open and the job hasn't locked (bind opId, now). Row alias `a` = the ally. */
const OPEN_SHARE = `EXISTS (SELECT 1 FROM op_shares s JOIN ops o ON o.id = s.op_id LEFT JOIN games g ON g.id = o.game_id
  WHERE s.op_id = ? AND s.account_id = a.id AND s.status = 'proposed' AND o.status = 'planned'
    AND (o.game_id = '' OR (g.simmed = 0 AND g.first_pitch_at > ?)) AND o.syndicate_id IS NOT NULL AND o.syndicate_id = a.syndicate_id)`;

/** Accept: pay your share; the orderer gets it back. Returns a one-line result. */
export async function acceptChipIn(c: Ctx, opId: string): Promise<string> {
  const s = await shareFor(c, opId);
  if (s.status !== "proposed") fail("bad_request", `already ${s.status === "paid" ? "paid" : s.status}`);
  const g = s.game_id ? await gameRow(c, s.game_id) : undefined;
  if (s.op_status !== "planned" || (g && (g.simmed || c.now >= g.first_pitch_at))) fail("window_closed", "the job has locked");
  const name = jobName(s.kind);
  const { ok } = await moneyMove(c, {
    delta: -s.amount, reason: "chip_in", cond: OPEN_SHARE, condArgs: [opId, c.now],
    then: tx => [
      c.db.prepare(`UPDATE op_shares SET status = 'paid', decided_at = ? WHERE op_id = ? AND account_id = ? AND status = 'proposed' AND ${gate()}`).bind(c.now, opId, c.acct.id, tx),
      c.db.prepare(`INSERT INTO ledger (id, account_id, delta, reason, at, season, syndicate_id) SELECT ?, a.id, ?, 'chip_in_back', ?, ?, a.syndicate_id FROM accounts a WHERE a.id = ? AND ${gate()}`)
        .bind(`chipback:${tx}`, s.amount, c.now, c.L.state.season, s.orderer, tx),
      c.db.prepare(`UPDATE accounts SET money = money + ? WHERE id = ? AND ${gate()}`).bind(s.amount, s.orderer, tx),
      c.db.prepare(`INSERT OR IGNORE INTO mail (id, account_id, at, read, kind, data) SELECT ?, ?, ?, 0, 'bank', ? WHERE ${gate()}`).bind(`chipin:${opId}:${c.acct.id}`, s.orderer, c.now, JSON.stringify({
        from: "The Clubhouse BBS", subject: `${c.acct.name} chipped in $${s.amount}`, kind: "bank",
        body: [`${c.acct.name} paid $${s.amount} toward "${name}". It has been credited to you.`],
      }), tx),
      c.db.prepare(`UPDATE events SET status = 'done', result = 'accepted' WHERE id = ? AND status = 'pending' AND ${gate()}`).bind(`ev-chip-${opId}-${c.acct.id}`, tx),
    ],
  });
  if (!ok) {
    const again = await shareFor(c, opId);
    if (again.status !== "proposed") fail("bad_request", `already ${again.status}`);
    if (c.acct.syndicate_id !== s.syndicate_id) fail("forbidden", "you're no longer in that syndicate");
    const fresh = s.game_id ? await gameRow(c, s.game_id) : undefined;
    if (fresh && (fresh.simmed || c.now >= fresh.first_pitch_at)) fail("window_closed", "the job has locked");
    fail("insufficient_funds", `your share is $${s.amount}`);
  }
  return `You chipped in $${s.amount} on "${name}".`;
}

export async function declineChipIn(c: Ctx, opId: string): Promise<string> {
  const s = await shareFor(c, opId);
  if (s.status !== "proposed") fail("bad_request", `already ${s.status}`);
  const name = jobName(s.kind);
  const res = await c.db.batch([
    c.db.prepare("UPDATE op_shares SET status = 'declined', decided_at = ? WHERE op_id = ? AND account_id = ? AND status = 'proposed'").bind(c.now, opId, c.acct.id),
    c.db.prepare(`INSERT OR IGNORE INTO mail (id, account_id, at, read, kind, data) SELECT ?, ?, ?, 0, 'op', ? WHERE EXISTS (SELECT 1 FROM op_shares WHERE op_id = ? AND account_id = ? AND status = 'declined')`).bind(`chipno:${opId}:${c.acct.id}`, s.orderer, c.now, JSON.stringify({
      from: "The Clubhouse BBS", subject: `${c.acct.name} won't chip in`, kind: "op",
      body: [`${c.acct.name} passed on "${name}". Their crew is still on it. You're still paying for it.`],
    }), opId, c.acct.id),
    c.db.prepare("UPDATE events SET status = 'done', result = 'declined' WHERE id = ? AND status = 'pending'").bind(`ev-chip-${opId}-${c.acct.id}`),
  ]);
  if (!res[0].meta.changes) fail("bad_request", "already decided");
  return `You pass. ${s.orderer_name} pays for "${name}".`;
}

/** POST /ops/:id/chipin { accept: boolean } */
export async function respond(c: Ctx) {
  const v = c.body.accept;
  if (typeof v !== "boolean") fail("bad_request", "accept must be true or false");
  const opId = c.params[0];
  const result = v ? await acceptChipIn(c, opId) : await declineChipIn(c, opId);
  const view = (await pendingFor(c, opId, true))[0];
  return { result, chipIn: view, account: await accountView(c) };
}

/**
 * Refund a planned job in one batch: the orderer's part (cost minus paid shares) and every paid
 * share, crew back to free, unanswered asks void, then `status` (default "cancelled"). Every step
 * is keyed off the op's status transition, so running it twice does nothing the second time.
 */
export function refundStmts(db: D1Database, op: Pick<OpRow, "id" | "crew">, now: number, season: number, why: string, beforeLock?: number): D1PreparedStatement[] {
  const cancelling = `EXISTS (SELECT 1 FROM ops WHERE id = ? AND status = 'cancelling')`;
  // the claim: only a planned job (and, from the API, only one that hasn't locked)
  const claim = beforeLock === undefined
    ? db.prepare(`UPDATE ops SET status = 'cancelling' WHERE id = ? AND status = 'planned'`).bind(op.id)
    : db.prepare(`UPDATE ops SET status = 'cancelling' WHERE id = ? AND status = 'planned' AND (game_id = '' OR EXISTS (SELECT 1 FROM games g WHERE g.id = ops.game_id AND g.simmed = 0 AND g.first_pitch_at > ?))`).bind(op.id, beforeLock);
  return [
    claim,
    db.prepare(`UPDATE op_shares SET status = 'refunding' WHERE op_id = ? AND status = 'paid' AND ${cancelling}`).bind(op.id, op.id),
    db.prepare(`INSERT OR IGNORE INTO ledger (id, account_id, delta, reason, at, season, syndicate_id)
        SELECT 'refund:' || o.id, o.account_id, o.cost - (SELECT COALESCE(SUM(amount), 0) FROM op_shares WHERE op_id = o.id AND status = 'refunding'), 'op_refund', ?, ?, a.syndicate_id
        FROM ops o JOIN accounts a ON a.id = o.account_id WHERE o.id = ? AND o.status = 'cancelling'`).bind(now, season, op.id),
    db.prepare(`INSERT OR IGNORE INTO ledger (id, account_id, delta, reason, at, season, syndicate_id)
        SELECT 'refund:' || s.op_id || ':' || s.account_id, s.account_id, s.amount, 'op_refund', ?, ?, a.syndicate_id FROM op_shares s JOIN accounts a ON a.id = s.account_id
        WHERE s.op_id = ? AND s.status = 'refunding'`).bind(now, season, op.id),
    db.prepare(`UPDATE accounts SET money = money + (SELECT o.cost - (SELECT COALESCE(SUM(amount), 0) FROM op_shares WHERE op_id = o.id AND status = 'refunding') FROM ops o WHERE o.id = ?)
        WHERE id = (SELECT account_id FROM ops WHERE id = ? AND status = 'cancelling')`).bind(op.id, op.id),
    db.prepare(`UPDATE accounts SET money = money + (SELECT amount FROM op_shares WHERE op_id = ? AND account_id = accounts.id AND status = 'refunding')
        WHERE id IN (SELECT account_id FROM op_shares WHERE op_id = ? AND status = 'refunding')`).bind(op.id, op.id),
    db.prepare(`INSERT OR IGNORE INTO mail (id, account_id, at, read, kind, data) SELECT 'refund:' || s.op_id || ':' || s.account_id, s.account_id, ?, 0, 'bank',
        json_object('from', 'The Clubhouse BBS', 'subject', 'Refund: $' || s.amount, 'body', json_array(?, 'Your $' || s.amount || ' share has been returned.'))
        FROM op_shares s WHERE s.op_id = ? AND s.status = 'refunding'`).bind(now, why, op.id),
    db.prepare(`UPDATE op_shares SET status = CASE status WHEN 'refunding' THEN 'refunded' ELSE 'void' END, decided_at = COALESCE(decided_at, ?)
        WHERE op_id = ? AND status IN ('refunding', 'proposed') AND ${cancelling}`).bind(now, op.id, op.id),
    db.prepare(`UPDATE events SET status = 'expired' WHERE id LIKE ? AND status = 'pending' AND ${cancelling}`).bind(`ev-chip-${op.id}-%`, op.id),
    db.prepare(`UPDATE crew SET status = 'free' WHERE id IN (SELECT value FROM json_each(?)) AND status = 'busy' AND ${cancelling}`).bind(op.crew, op.id),
    db.prepare(`UPDATE ops SET status = 'cancelled' WHERE id = ? AND status = 'cancelling'`).bind(op.id),
  ];
}

/** DELETE /ops/:id: call off your own planned job before it locks. Everyone who paid gets it back. */
export async function cancel(c: Ctx) {
  const op = await c.db.prepare("SELECT * FROM ops WHERE id = ? AND account_id = ?").bind(c.params[0], c.acct.id).first<OpRow>();
  if (!op) return fail("not_found", "no such job");
  if (op.status !== "planned") fail("bad_request", `that job is already ${op.status}`);
  if (op.game_id) {
    const g = await gameRow(c, op.game_id);
    if (g.simmed || c.now >= g.first_pitch_at) fail("window_closed", "orders lock at first pitch");
  }
  const res = await c.db.batch(refundStmts(c.db, op, c.now, c.L.state.season, `${c.acct.name} called off "${jobName(op.kind)}".`, c.now));
  if (!res[0].meta.changes) fail("window_closed", "too late to call it off");
  await c.db.prepare("UPDATE ops SET result = ? WHERE id = ?").bind("Called off. Everyone was refunded.", op.id).run();
  const row = await c.db.prepare("SELECT * FROM ops WHERE id = ?").bind(op.id).first<OpRow>();
  return { op: (await opViews(c, [row!]))[0], account: await accountView(c) };
}

export type ChipInView = { opId: string; from: string; job: string; kind: string; target?: ReturnType<typeof teamRef>; game: string; share: number; total: number;
  status: ShareStatus; locksAt?: number; eventId: string };

/** The chip-in asks addressed to this account (open ones unless `all`). */
export async function pendingFor(c: Ctx, opId?: string, all = false): Promise<ChipInView[]> {
  const rows = (await c.db.prepare(`SELECT s.*, o.kind, o.game_id, o.target_team_id, o.cost, a.name AS orderer_name, g.first_pitch_at, g.day, g.home_id, g.away_id
      FROM op_shares s JOIN ops o ON o.id = s.op_id JOIN accounts a ON a.id = o.account_id LEFT JOIN games g ON g.id = o.game_id
      WHERE s.account_id = ? ${opId ? "AND s.op_id = ?" : ""} ${all ? "" : "AND s.status = 'proposed' AND o.status = 'planned'"} ORDER BY s.created_at DESC LIMIT 10`)
    .bind(c.acct.id, ...(opId ? [opId] : [])).all<ShareRow & { kind: string; game_id: string; target_team_id: string; cost: number; orderer_name: string; first_pitch_at: number | null; day: number | null; home_id: string | null; away_id: string | null }>()).results;
  const w = c.L.world;
  return rows.map(r => ({
    opId: r.op_id, from: r.orderer_name, job: jobName(r.kind), kind: r.kind, ...(w.teams[r.target_team_id] ? { target: teamRef(w, r.target_team_id) } : {}),
    game: r.home_id ? `${w.teams[r.away_id!]?.abbr ?? r.away_id} @ ${w.teams[r.home_id]?.abbr ?? r.home_id}, Day ${r.day}` : "storyline job",
    share: r.amount, total: r.cost, status: r.status as ShareStatus, ...(r.first_pitch_at ? { locksAt: r.first_pitch_at } : {}), eventId: `ev-chip-${r.op_id}-${r.account_id}`,
  }));
}

export type OpChipIn = { total: number; yours: number; shares: { name: string; amount: number; status: ShareStatus }[]; line: string };

/** The orderer's view of the split, for OpView.chipIn (keyed by op id). */
export async function chipInFor(c: Ctx, ops: Pick<OpRow, "id" | "cost">[]): Promise<Map<string, OpChipIn>> {
  const out = new Map<string, OpChipIn>();
  if (!ops.length) return out;
  const rows = (await c.db.prepare(`SELECT s.op_id, s.amount, s.status, a.name FROM op_shares s JOIN accounts a ON a.id = s.account_id
      WHERE s.op_id IN (SELECT value FROM json_each(?)) ORDER BY a.name`).bind(JSON.stringify(ops.map(o => o.id))).all<{ op_id: string; amount: number; status: string; name: string }>()).results;
  for (const o of ops) {
    const mine = rows.filter(r => r.op_id === o.id);
    if (!mine.length) continue;
    const paid = mine.filter(r => r.status === "paid").reduce((a, r) => a + r.amount, 0);
    const word: Record<string, string> = { proposed: "asked", paid: "paid", declined: "passed", expired: "never answered", refunded: "refunded", void: "void", refunding: "refunded" };
    const shares = mine.map(r => ({ name: r.name, amount: r.amount, status: (r.status === "refunding" ? "refunded" : r.status) as ShareStatus }));
    out.set(o.id, {
      total: o.cost, yours: o.cost - paid, shares,
      line: `Chip-in: ${shares.map(s => `${s.name} ${word[s.status] ?? s.status} $${s.amount}`).join(", ")}. You: $${o.cost - paid}.`,
    });
  }
  return out;
}

/** At first pitch: unanswered asks on these jobs lapse. */
export function expireStmts(db: D1Database, opIds: string[], now: number): D1PreparedStatement[] {
  if (!opIds.length) return [];
  return [db.prepare("UPDATE op_shares SET status = 'expired', decided_at = ? WHERE status = 'proposed' AND op_id IN (SELECT value FROM json_each(?))").bind(now, JSON.stringify(opIds))];
}

