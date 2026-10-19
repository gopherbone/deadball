import type { Ctx } from "../router.ts";
import { decCursor, encCursor, fail, str } from "../http.ts";
import { Rng, sim, type CrimeEffect, type EventCard, type MailItem } from "../sim.ts";
import { accountView, limitParam, page } from "./common.ts";
import { acceptInvite, declineInvite } from "./syndicate.ts";
import { acceptChipIn, declineChipIn } from "./chipin.ts";


type MailRow = { id: string; account_id: string; at: number; read: number; kind: string; data: string };
const KINDS = ["tip", "op", "league", "bank", "fan", "threat"];

export function mailView(r: MailRow) {
  // mail rows come from the crime module (MailItem) and from the server itself (bank, league)
  const m = JSON.parse(r.data) as Partial<MailItem> & { faceId?: string; body?: unknown };
  const body = Array.isArray(m.body) ? m.body.map(String) : m.body ? [String(m.body)] : [];
  const face = m.fromFace ?? m.faceId;
  return {
    id: r.id, from: String(m.from ?? "Unknown"), ...(face ? { fromFace: String(face) } : {}), subject: String(m.subject ?? "(no subject)"), body, at: r.at,
    ...(m.photo ? { photo: String(m.photo) } : {}), ...(m.photoCaption ? { photoCaption: String(m.photoCaption) } : {}),
    read: !!r.read, kind: (KINDS.includes(r.kind) ? r.kind : "league") as "tip" | "op" | "league" | "bank" | "fan" | "threat",
    // links a tip to its Gossip Board entry (only ever in the recipient's own mail)
    ...(m.storylineId ? { storylineId: String(m.storylineId) } : {}),
  };
}

export async function list(c: Ctx) {
  const cur = decCursor<[number, string]>(c.q.get("cursor"));
  const limit = limitParam(c, 20, 50);
  const rows = (await c.db.prepare(`SELECT * FROM mail WHERE account_id = ? AND at <= ? ${cur ? "AND (at < ? OR (at = ? AND id < ?))" : ""} ORDER BY at DESC, id DESC LIMIT ?`)
    .bind(c.acct.id, c.now, ...(cur ? [cur[0], cur[0], cur[1]] : []), limit + 1).all<MailRow>()).results;
  const p = page(rows, limit, l => [l.at, l.id]);
  const out: { mail: unknown[]; next?: string } = { mail: p.items.map(mailView) };
  if (p.next) out.next = encCursor(p.next);
  return out;
}

export async function read(c: Ctx) {
  const r = await c.db.prepare("UPDATE mail SET read = 1 WHERE id = ? AND account_id = ? AND at <= ?").bind(c.params[0], c.acct.id, c.now).run();
  if (!r.meta.changes) fail("not_found", "no such mail");
  return { ok: true };
}

type EventRow = { id: string; account_id: string; at: number; expires_at: number; status: string; data: string; result: string | null };

export function eventView(r: EventRow) {
  const e = JSON.parse(r.data) as EventCard;
  return {
    id: r.id, title: e.title, body: e.body, ...(e.faceId ? { face: e.faceId } : {}),
    ...(e.photo ? { photo: e.photo } : {}), ...(e.photoCaption ? { photoCaption: e.photoCaption } : {}),
    choices: e.choices.map(ch => ({
      key: ch.key, label: ch.label, ...(ch.cost ? { cost: ch.cost } : {}),
      ...((ch as { note?: string }).note || ch.heat ? { note: (ch as { note?: string }).note ?? `${ch.heat! > 0 ? "+" : ""}${ch.heat} heat` } : {}),
    })),
    expiresAt: r.expires_at,
  };
}

export async function events(c: Ctx) {
  const rows = (await c.db.prepare("SELECT * FROM events WHERE account_id = ? AND status = 'pending' AND at <= ? AND expires_at > ? ORDER BY at DESC LIMIT 30")
    .bind(c.acct.id, c.now, c.now).all<EventRow>()).results;
  return { events: rows.map(eventView) };
}

export async function choose(c: Ctx) {
  const key = str(c.body, "key", 40);
  const row = await c.db.prepare("SELECT * FROM events WHERE id = ? AND account_id = ? AND at <= ?").bind(c.params[0], c.acct.id, c.now).first<EventRow>();
  if (!row) fail("not_found", "no such event");
  if (row!.status !== "pending" || row!.expires_at <= c.now) fail("bad_request", "that's already been decided");
  const card = JSON.parse(row!.data) as EventCard & { syndicateInvite?: string; chipIn?: string };
  const choice = card.choices.find(ch => ch.key === key);
  if (!choice) fail("bad_request", `choices: ${card.choices.map(ch => ch.key).join(", ")}`);

  // syndicate invites are server-side cards
  if (card.syndicateInvite) {
    const result = key === "accept" ? await acceptInvite(c, card.syndicateInvite) : await declineInvite(c, card.syndicateInvite);
    await c.db.prepare("UPDATE events SET status = 'done', result = ? WHERE id = ?").bind(result, row!.id).run();
    return { result, account: await accountView(c) };
  }

  // chip-in asks: same as POST /ops/:id/chipin
  if (card.chipIn) {
    const result = key === "accept" ? await acceptChipIn(c, card.chipIn) : await declineChipIn(c, card.chipIn);
    await c.db.prepare("UPDATE events SET status = 'done', result = ? WHERE id = ?").bind(result, row!.id).run();
    return { result, account: await accountView(c) };
  }

  const cost = choice!.cost ?? 0;
  if (cost > c.acct.money) fail("insufficient_funds", `that costs $${cost}`);
  // claim the card first so it can only resolve once
  const claim = await c.db.prepare("UPDATE events SET status = 'resolving' WHERE id = ? AND status = 'pending'").bind(row!.id).run();
  if (!claim.meta.changes) fail("bad_request", "that's already been decided");
  const L = c.L;
  const out = sim.resolveChoice(L.world, card, key, new Rng(`${L.seed}:choice:${row!.id}:${key}`));
  const effects: CrimeEffect[] = [...(out.effects ?? [])];
  if (cost && !effects.some(e => e.kind === "money" && e.ownerId === c.acct.id)) effects.push({ kind: "money", ownerId: c.acct.id, delta: -cost, why: "event" });
  if (choice!.heat && !effects.some(e => e.kind === "heat" && e.ownerId === c.acct.id)) effects.push({ kind: "heat", ownerId: c.acct.id, delta: choice!.heat, why: "event" });
  const result = out.result || `You chose: ${choice!.label}.`;
  const stmts = [
    ...L.effectStmts(effects, c.now, L.state.season),
    ...L.mailStmts((out.mail ?? []).map(m => ({ ...m, ownerId: m.ownerId ?? c.acct.id })), c.now),
    ...L.eventStmts(out.events ?? [], c.now),
    c.db.prepare("UPDATE events SET status = 'done', result = ? WHERE id = ?").bind(String(result), row!.id),
  ];
  await c.db.batch(stmts);
  if (effects.some(e => e.kind === "relation")) L.store.saveField("world", L.world, "relationships");
  return { result: String(result), account: await accountView(c) };
}
