// Syndicates: up to 4 allied accounts sharing crews, a treasury and a private board.

import type { Ctx } from "../router.ts";
import { fail, int, newId, str } from "../http.ts";
import { rankFor } from "../views.ts";
import { accountView, gate, moneyMove } from "./common.ts";
import { checkName, normName } from "./account.ts";
import { pendingFor } from "./chipin.ts";

export const SYNDICATE_MAX = 4;
type SynRow = { id: string; name: string; founder_id: string; treasury: number; created_at: number; created_season: number };

async function synView(c: Ctx, id: string) {
  const s = await c.db.prepare("SELECT * FROM syndicates WHERE id = ?").bind(id).first<SynRow>();
  if (!s) return null;
  const members = (await c.db.prepare(`SELECT a.id, a.name, a.money, a.heat,
      (SELECT COUNT(*) FROM crew WHERE account_id = a.id AND status NOT IN ('gone', 'dead')) AS crew_size
      FROM accounts a WHERE a.syndicate_id = ? ORDER BY a.created_at`).bind(id).all<{ id: string; name: string; money: number; heat: number; crew_size: number }>()).results;
  return {
    id: s.id, name: s.name, founder: members.find(m => m.id === s.founder_id)?.name ?? "", treasury: s.treasury, board: `bbs:syn:${s.id}`, max: SYNDICATE_MAX,
    members: members.map(m => ({ name: m.name, rank: rankFor(m.money), money: m.money, heat: m.heat, crewSize: m.crew_size, founder: m.id === s.founder_id })),
  };
}

async function invitesFor(c: Ctx) {
  return (await c.db.prepare(`SELECT i.id, s.name AS syndicate, a.name AS from_name, i.created_at FROM syndicate_invites i JOIN syndicates s ON s.id = i.syndicate_id
      JOIN accounts a ON a.id = i.from_id WHERE i.to_id = ? AND i.status = 'pending' ORDER BY i.created_at DESC LIMIT 10`).bind(c.acct.id)
    .all<{ id: string; syndicate: string; from_name: string; created_at: number }>()).results.map(r => ({ id: r.id, syndicate: r.syndicate, from: r.from_name, at: r.created_at }));
}

export async function mine(c: Ctx) {
  return { syndicate: c.acct.syndicate_id ? await synView(c, c.acct.syndicate_id) : null, invites: await invitesFor(c), chipIns: await pendingFor(c) };
}

export async function create(c: Ctx) {
  if (c.acct.syndicate_id) fail("bad_request", "leave your syndicate first");
  const name = checkName(c, str(c.body, "name", 64));
  const id = newId("sy");
  const res = await c.db.batch([
    c.db.prepare(`INSERT OR IGNORE INTO syndicates (id, name, name_lc, founder_id, treasury, created_at, created_season) SELECT ?, ?, ?, ?, 0, ?, ? WHERE EXISTS (SELECT 1 FROM accounts WHERE id = ? AND syndicate_id IS NULL)`)
      .bind(id, name, normName(name), c.acct.id, c.now, c.L.state.season, c.acct.id),
    c.db.prepare(`UPDATE accounts SET syndicate_id = ? WHERE id = ? AND syndicate_id IS NULL AND EXISTS (SELECT 1 FROM syndicates WHERE id = ?)`).bind(id, c.acct.id, id),
  ]);
  if (!res[0].meta.changes) fail("name_taken", "a syndicate already goes by that name");
  c.acct.syndicate_id = id;
  return { syndicate: await synView(c, id), account: await accountView(c) };
}

export async function invite(c: Ctx) {
  const syn = c.acct.syndicate_id;
  if (!syn) fail("bad_request", "you're not in a syndicate");
  const who = str(c.body, "accountName", 64);
  const to = await c.db.prepare("SELECT id, name, syndicate_id FROM accounts WHERE name_lc = ?").bind(normName(who)).first<{ id: string; name: string; syndicate_id: string | null }>();
  if (!to) fail("not_found", "no account by that name");
  if (to!.id === c.acct.id) fail("bad_request", "you can't invite yourself");
  if (to!.syndicate_id) fail("bad_request", `${to!.name} is already in a syndicate`);
  const count = await c.db.prepare("SELECT COUNT(*) AS n FROM accounts WHERE syndicate_id = ?").bind(syn).first<{ n: number }>();
  if ((count?.n ?? 0) >= SYNDICATE_MAX) fail("bad_request", "your syndicate is full (4 max)");
  const dup = await c.db.prepare("SELECT 1 FROM syndicate_invites WHERE syndicate_id = ? AND to_id = ? AND status = 'pending'").bind(syn, to!.id).first();
  if (dup) fail("bad_request", "already invited");
  const s = await c.db.prepare("SELECT name FROM syndicates WHERE id = ?").bind(syn).first<{ name: string }>();
  const id = newId("iv");
  const card = {
    id: `ev-${id}`, ownerId: to!.id, title: "An Offer You Could Refuse",
    body: `${c.acct.name} wants you in the ${s!.name} syndicate. Shared crews, shared treasury, shared bail.`,
    choices: [{ key: "accept", label: "Join up" }, { key: "decline", label: "Thanks, no" }],
    syndicateInvite: id,
  };
  await c.db.batch([
    c.db.prepare("INSERT INTO syndicate_invites (id, syndicate_id, from_id, to_id, status, created_at) VALUES (?,?,?,?, 'pending', ?)").bind(id, syn, c.acct.id, to!.id, c.now),
    c.db.prepare("INSERT INTO events (id, account_id, at, expires_at, status, data) VALUES (?,?,?,?, 'pending', ?)").bind(card.id, to!.id, c.now, c.now + 7 * 86_400_000, JSON.stringify(card)),
  ]);
  return { invite: { id, to: to!.name, syndicate: s!.name, at: c.now } };
}

/** Shared with the event-card path. Returns a one-line result. */
export async function acceptInvite(c: Ctx, inviteId: string): Promise<string> {
  const inv = await c.db.prepare("SELECT * FROM syndicate_invites WHERE id = ? AND to_id = ?").bind(inviteId, c.acct.id).first<{ id: string; syndicate_id: string; status: string }>();
  if (!inv || inv.status !== "pending") fail("not_found", "no such invite");
  if (c.acct.syndicate_id) fail("bad_request", "leave your syndicate first");
  const res = await c.db.batch([
    c.db.prepare(`UPDATE accounts SET syndicate_id = ? WHERE id = ? AND syndicate_id IS NULL AND EXISTS (SELECT 1 FROM syndicates WHERE id = ?)
        AND (SELECT COUNT(*) FROM accounts WHERE syndicate_id = ?) < ?`).bind(inv!.syndicate_id, c.acct.id, inv!.syndicate_id, inv!.syndicate_id, SYNDICATE_MAX),
    c.db.prepare(`UPDATE syndicate_invites SET status = 'accepted' WHERE id = ? AND EXISTS (SELECT 1 FROM accounts WHERE id = ? AND syndicate_id = ?)`).bind(inviteId, c.acct.id, inv!.syndicate_id),
    c.db.prepare(`UPDATE events SET status = 'done', result = 'accepted' WHERE id = ? AND status = 'pending'`).bind(`ev-${inviteId}`),
  ]);
  if (!res[0].meta.changes) fail("bad_request", "that syndicate is full or gone");
  c.acct.syndicate_id = inv!.syndicate_id;
  const s = await c.db.prepare("SELECT name FROM syndicates WHERE id = ?").bind(inv!.syndicate_id).first<{ name: string }>();
  return `You're in. Welcome to ${s?.name ?? "the syndicate"}.`;
}
export async function declineInvite(c: Ctx, inviteId: string): Promise<string> {
  await c.db.prepare("UPDATE syndicate_invites SET status = 'declined' WHERE id = ? AND to_id = ? AND status = 'pending'").bind(inviteId, c.acct.id).run();
  return "You pass. They'll remember that.";
}

export async function accept(c: Ctx) {
  const result = await acceptInvite(c, c.params[0]);
  return { result, syndicate: await synView(c, c.acct.syndicate_id!), account: await accountView(c) };
}

export async function leave(c: Ctx) {
  const syn = c.acct.syndicate_id;
  if (!syn) fail("bad_request", "you're not in a syndicate");
  const s = await c.db.prepare("SELECT * FROM syndicates WHERE id = ?").bind(syn).first<SynRow>();
  const others = (await c.db.prepare("SELECT id FROM accounts WHERE syndicate_id = ? AND id != ? ORDER BY created_at").bind(syn, c.acct.id).all<{ id: string }>()).results;
  const stmts = [c.db.prepare("UPDATE accounts SET syndicate_id = NULL WHERE id = ?").bind(c.acct.id)];
  if (!others.length) {
    // last one out takes the treasury and turns off the lights
    if (s && s.treasury > 0) {
      stmts.push(c.db.prepare("INSERT INTO ledger (id, account_id, delta, reason, at, season) VALUES (?,?,?,'treasury_out',?,?)").bind(newId("tx"), c.acct.id, s.treasury, c.now, c.L.state.season));
      stmts.push(c.db.prepare("UPDATE accounts SET money = money + ? WHERE id = ?").bind(s.treasury, c.acct.id));
    }
    stmts.push(c.db.prepare("DELETE FROM syndicates WHERE id = ?").bind(syn));
    stmts.push(c.db.prepare("UPDATE syndicate_invites SET status = 'void' WHERE syndicate_id = ? AND status = 'pending'").bind(syn));
  } else if (s?.founder_id === c.acct.id) {
    stmts.push(c.db.prepare("UPDATE syndicates SET founder_id = ? WHERE id = ?").bind(others[0].id, syn));
  }
  await c.db.batch(stmts);
  c.acct.syndicate_id = null;
  return { syndicate: null, account: await accountView(c) };
}

export async function treasury(c: Ctx) {
  const syn = c.acct.syndicate_id;
  if (!syn) fail("bad_request", "you're not in a syndicate");
  const amount = int(c.body, "amount", -10_000_000, 10_000_000);
  if (amount === 0) fail("bad_request", "amount can't be zero");
  if (amount > 0) {
    const { ok } = await moneyMove(c, {
      delta: -amount, reason: "treasury_in",
      then: tx => [c.db.prepare(`UPDATE syndicates SET treasury = treasury + ? WHERE id = ? AND ${gate()}`).bind(amount, syn, tx)],
    });
    if (!ok) fail("insufficient_funds", "you don't have that much");
  } else {
    const s = await c.db.prepare("SELECT founder_id, treasury FROM syndicates WHERE id = ?").bind(syn).first<{ founder_id: string; treasury: number }>();
    if (s?.founder_id !== c.acct.id) fail("forbidden", "only the founder can withdraw");
    if (s!.treasury < -amount) fail("insufficient_funds", "the treasury doesn't have that much");
    const tx = newId("tx");
    const res = await c.db.batch([
      c.db.prepare(`INSERT INTO ledger (id, account_id, delta, reason, at, season, syndicate_id) SELECT ?, ?, ?, 'treasury_out', ?, ?, id FROM syndicates WHERE id = ? AND founder_id = ? AND treasury >= ?`)
        .bind(tx, c.acct.id, -amount, c.now, c.L.state.season, syn, c.acct.id, -amount),
      c.db.prepare(`UPDATE syndicates SET treasury = treasury + ? WHERE id = ? AND ${gate()}`).bind(amount, syn, tx),
      c.db.prepare(`UPDATE accounts SET money = money + ? WHERE id = ? AND ${gate()}`).bind(-amount, c.acct.id, tx),
    ]);
    if (!res[0].meta.changes) fail("insufficient_funds", "the treasury doesn't have that much");
  }
  return { syndicate: await synView(c, syn!), account: await accountView(c) };
}

export async function leaderboard(c: Ctx) {
  const season = Number(c.q.get("season") ?? c.L.state.season);
  if (!Number.isInteger(season) || season < 1) fail("bad_request", "bad season");
  const rows = (await c.db.prepare(`SELECT s.id, s.name,
      (SELECT COALESCE(SUM(delta), 0) FROM ledger WHERE syndicate_id = s.id AND season = ? AND reason NOT IN ('grant', 'treasury_in', 'treasury_out')) AS net,
      (SELECT COUNT(*) FROM ops WHERE syndicate_id = s.id AND season = ? AND status IN ('done', 'blown')) AS ops,
      (SELECT COUNT(*) FROM ops WHERE syndicate_id = s.id AND season = ? AND status = 'done') AS pulled,
      (SELECT COALESCE(SUM(arrests), 0) FROM ops WHERE syndicate_id = s.id AND season = ?) AS arrests,
      (SELECT group_concat(name, '|') FROM accounts WHERE syndicate_id = s.id) AS members
    FROM syndicates s ORDER BY net DESC, pulled DESC, arrests ASC, s.id LIMIT 50`).bind(season, season, season, season)
    .all<{ id: string; name: string; net: number; ops: number; pulled: number; arrests: number; members: string | null }>()).results;
  return {
    season,
    rows: rows.map((r, i) => ({ rank: i + 1, id: r.id, name: r.name, members: r.members ? r.members.split("|") : [], net: r.net, ops: r.ops, pulledOff: r.pulled, arrests: r.arrests })),
  };
}
