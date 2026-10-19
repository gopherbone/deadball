import type { Ctx } from "../router.ts";
import { decCursor, encCursor, fail, newId, oneOf, str, strArray } from "../http.ts";
import { commentTemplates, sim } from "../sim.ts";
import { markStmt } from "./bonus.ts";
import { COMMENT_SELECT, commentView, limitParam, page, type CommentRow } from "./common.ts";

export const BOARDS = ["general", "trades", "rumors", "crime", "help"];
export const COMMENT_GAP_MS = 20_000;
export const COMMENTS_PER_DAY = 30;

let wordsCache: { key: string; body: unknown } | undefined;

export function words(c: Ctx) {
  const key = `${c.L.state.season}:${c.L.state.day}`;
  if (wordsCache?.key !== key) {
    const templates = commentTemplates();
    const slots = sim.vocabulary(c.L.world);
    // sorted case-insensitively here so the Playdate can skip sorting ~1,000 names
    for (const k of Object.keys(slots) as (keyof typeof slots)[]) {
      const list = slots[k] as unknown;
      if (Array.isArray(list)) list.sort((a: string, b: string) => (a.toLowerCase() < b.toLowerCase() ? -1 : a.toLowerCase() > b.toLowerCase() ? 1 : 0));
    }
    let h = 0;
    const s = JSON.stringify([templates, slots]);
    for (let i = 0; i < s.length; i++) h = (Math.imul(h, 31) + s.charCodeAt(i)) | 0;
    wordsCache = { key, body: { templates, slots, version: (h >>> 0).toString(36) } };
  }
  return wordsCache.body;
}

/** Validates the thread id and the caller's access to it. */
export async function checkThread(c: Ctx, thread: string): Promise<void> {
  const m = /^(story|person|team|bbs|listing):([A-Za-z0-9:_.-]{1,80})$/.exec(thread);
  if (!m) fail("bad_request", "thread must look like story:<id>, person:<id>, team:<id>, bbs:<board> or listing:<id>");
  const [, kind, ref] = m!;
  const w = c.L.world;
  if (kind === "person" && !w.players[ref] && !w.npcs[ref] && !w.archive?.[ref]) fail("not_found", "no such person");
  if (kind === "team" && !w.teams[ref]) fail("not_found", "no such team");
  if (kind === "story" && !(await c.db.prepare("SELECT 1 FROM stories WHERE id = ? AND publish_at <= ?").bind(ref, c.now).first())) fail("not_found", "no such story");
  if (kind === "listing" && !(await c.db.prepare("SELECT 1 FROM listings WHERE id = ?").bind(ref).first())) fail("not_found", "no such listing");
  if (kind === "bbs") {
    if (ref.startsWith("syn:")) {
      if (c.acct.syndicate_id !== ref.slice(4)) fail("forbidden", "members only");
    } else if (!BOARDS.includes(ref)) fail("not_found", `boards: ${BOARDS.join(", ")}`);
  }
}

export async function post(c: Ctx) {
  const thread = str(c.body, "thread", 100);
  const template = str(c.body, "template", 60);
  const wordsIn = strArray(c.body, "words", 8, 80);
  await checkThread(c, thread);
  const v = sim.validateComment(c.L.world, { template, words: wordsIn });
  if (!v.ok) fail("invalid_comment", v.reason);
  const text = (v as { text: string }).text;
  // rate limit, atomically: 1 per 20s, 30 per (UTC) day
  const today = new Date(c.now).toISOString().slice(0, 10);
  const gap = Number(c.L.bindings.COMMENT_GAP_MS ?? COMMENT_GAP_MS);
  const rl = await c.db.prepare(`UPDATE accounts SET last_comment_at = ?, comments_today = CASE WHEN comment_day = ? THEN comments_today + 1 ELSE 1 END, comment_day = ?
      WHERE id = ? AND last_comment_at <= ? AND (comment_day != ? OR comments_today < ?)`)
    .bind(c.now, today, today, c.acct.id, c.now - gap, today, COMMENTS_PER_DAY).run();
  if (!rl.meta.changes) {
    const a = await c.db.prepare("SELECT last_comment_at, comment_day, comments_today FROM accounts WHERE id = ?").bind(c.acct.id).first<{ last_comment_at: number; comment_day: string; comments_today: number }>();
    if (a && a.comment_day === today && a.comments_today >= COMMENTS_PER_DAY) fail("rate_limited", "that's 30 comments today; the guestbook needs a rest");
    fail("rate_limited", `slow down: one comment every ${Math.round(gap / 1000)} seconds`);
  }
  const id = newId("c");
  await c.db.batch([
    c.db.prepare("INSERT INTO comments (id, thread, author_id, template, words, text, at) VALUES (?,?,?,?,?,?,?)").bind(id, thread, c.acct.id, template, JSON.stringify(wordsIn), text, c.now),
    c.db.prepare("INSERT INTO threads (id, comment_count, last_at) VALUES (?, 1, ?) ON CONFLICT (id) DO UPDATE SET comment_count = comment_count + 1, last_at = excluded.last_at").bind(thread, c.now),
  ]);
  return { comment: commentView({ id, thread, text, at: c.now, agree: 0, lol: 0, rat: 0, author: c.acct.name, money: c.acct.money }) };
}

export async function react(c: Ctx) {
  const kind = oneOf(c.body, "kind", ["agree", "lol", "rat"] as const);
  const id = c.params[0];
  const row = await c.db.prepare(`${COMMENT_SELECT} WHERE c.id = ?`).bind(id).first<CommentRow & { author_id?: string }>();
  if (!row) fail("not_found", "no such comment");
  if (row!.thread.startsWith("bbs:syn:") && c.acct.syndicate_id !== row!.thread.slice(8)) fail("forbidden", "members only");
  const own = await c.db.prepare("SELECT 1 FROM comments WHERE id = ? AND author_id = ?").bind(id, c.acct.id).first();
  if (own) fail("bad_request", "you can't react to your own comment");
  await c.db.batch([
    c.db.prepare("INSERT OR IGNORE INTO reactions (comment_id, account_id, kind) VALUES (?,?,?)").bind(id, c.acct.id, kind),
    c.db.prepare(`UPDATE comments SET ${kind} = (SELECT COUNT(*) FROM reactions WHERE comment_id = ? AND kind = ?) WHERE id = ?`).bind(id, kind, id),
    markStmt(c, "react", id),  // odd jobs: "rate somebody's comment"
  ]);
  const fresh = await c.db.prepare(`${COMMENT_SELECT} WHERE c.id = ?`).bind(id).first<CommentRow>();
  return { comment: commentView(fresh!) };
}

export async function thread(c: Ctx) {
  const t = c.params[0];
  await checkThread(c, t);
  const cur = decCursor<[number, string]>(c.q.get("cursor"));
  const limit = limitParam(c, 20, 50);
  // NPC chatter is written ahead with its publish time: only show what has "been posted"
  const rows = (await c.db.prepare(`${COMMENT_SELECT} WHERE c.thread = ? AND c.at <= ? ${cur ? "AND (c.at < ? OR (c.at = ? AND c.id < ?))" : ""} ORDER BY c.at DESC, c.id DESC LIMIT ?`)
    .bind(t, c.now, ...(cur ? [cur[0], cur[0], cur[1]] : []), limit + 1).all<CommentRow>()).results;
  const p = page(rows, limit, l => [l.at, l.id]);
  const out: { comments: unknown[]; next?: string } = { comments: p.items.map(commentView) };
  if (p.next) out.next = encCursor(p.next);
  return out;
}
