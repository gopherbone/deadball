// Route table for /v1. Each handler gets a Ctx with the League DO, D1, auth and body.

import type { League } from "./league.ts";
import { fail, json, bodyText, parseBody, safeEqual, HttpError, withRelativeTimes } from "./http.ts";
import { loadAccount, principal, type Principal } from "./auth.ts";
import * as account from "./routes/account.ts";
import * as games from "./routes/games.ts";
import * as bets from "./routes/bets.ts";
import * as news from "./routes/news.ts";
import * as social from "./routes/social.ts";
import * as crew from "./routes/crew.ts";
import * as mail from "./routes/mail.ts";
import * as cards from "./routes/cards.ts";
import * as syndicate from "./routes/syndicate.ts";
import * as admin from "./routes/admin.ts";
import * as redeem from "./redeem.ts";
import * as market from "./routes/market.ts";
import * as props from "./routes/props.ts";
import * as chipin from "./routes/chipin.ts";
import * as digest from "./routes/digest.ts";
import * as bonus from "./routes/bonus.ts";

export interface AccountRow {
  id: string; name: string; money: number; heat: number; joined_day: number; free_packs: number; syndicate_id: string | null; sign_key: string | null;
  last_comment_at: number; comment_day: string; comments_today: number; created_at: number;
}

export interface Ctx {
  L: League;
  db: D1Database;
  req: Request;
  url: URL;
  q: URLSearchParams;
  now: number;
  body: Record<string, unknown>;
  params: string[];
  acct: AccountRow;
  /** how the caller authenticated (set on "user" routes) */
  who: Principal;
}

type Handler = (c: Ctx) => Promise<unknown> | unknown;
/** Routes that render card backs or redeem cards: they load the archived seasons first. */
const STATS_PATHS = /^\/v1\/(cards|packs|market|watchlist|admin\/card)(\/|$)/;
type Auth = "none" | "user" | "admin";
const routes: [string, RegExp, Auth, Handler][] = [];
const add = (method: string, path: string, auth: Auth, h: Handler) =>
  routes.push([method, new RegExp("^/v1" + path.replace(/:[a-z]+/g, "([^/]+)") + "$"), auth, h]);

add("POST", "/register", "none", account.register);
add("GET", "/me", "user", account.me);
add("GET", "/digest", "user", digest.digest);
add("GET", "/clock", "none", account.clock);
add("POST", "/auth/key", "user", account.authKey);

add("GET", "/bonus", "user", bonus.get);
add("POST", "/bonus/punch", "user", bonus.punch);
add("POST", "/bonus/jobs/:id/claim", "user", bonus.claim);
add("POST", "/bonus/report", "user", bonus.report);

add("GET", "/today", "user", games.today);
add("GET", "/games/:id", "user", games.detail);
add("GET", "/games/:id/log", "user", games.log);
add("GET", "/games/:id/wire", "user", games.wire);
add("GET", "/standings", "user", games.standingsRoute);
add("GET", "/schedule", "user", games.schedule);

add("POST", "/bets", "user", bets.place);
add("GET", "/bets", "user", bets.list);

add("GET", "/gossip", "user", props.gossip);
add("GET", "/props", "user", props.list);
add("GET", "/props/bets", "user", props.bets);
add("POST", "/props/bets", "user", props.place);

add("GET", "/news", "user", news.list);
add("GET", "/news/:id", "user", news.story);
add("GET", "/people/:id", "user", news.person);
add("GET", "/teams/:id", "user", news.team);

add("GET", "/words", "user", social.words);
add("POST", "/comments", "user", social.post);
add("POST", "/comments/:id/react", "user", social.react);
add("GET", "/threads/:thread", "user", social.thread);

add("GET", "/crew", "user", crew.list);
add("GET", "/crew/candidates", "user", crew.candidates);
add("POST", "/crew/recruit", "user", crew.recruit);
add("POST", "/crew/:id/dismiss", "user", crew.dismiss);
add("GET", "/ops/catalog", "user", crew.catalog);
add("POST", "/ops", "user", crew.order);
add("GET", "/ops", "user", crew.ops);
add("DELETE", "/ops/:id", "user", chipin.cancel);
add("POST", "/ops/:id/chipin", "user", chipin.respond);

add("GET", "/mail", "user", mail.list);
add("POST", "/mail/:id/read", "user", mail.read);
add("GET", "/events", "user", mail.events);
add("POST", "/events/:id/choose", "user", mail.choose);

add("GET", "/shop", "user", cards.shop);
add("POST", "/packs/buy", "user", cards.buyPack);
add("GET", "/cards", "user", cards.binder);
add("GET", "/cards/:id", "user", cards.one);
add("POST", "/cards/:id/redeem", "user", redeem.redeem);
add("GET", "/bulletins", "user", redeem.bulletins);
add("GET", "/market", "user", market.search);
add("POST", "/market", "user", market.list);
add("GET", "/market/history", "user", market.history);
add("GET", "/market/:id", "user", market.detail);
add("POST", "/market/:id/buy", "user", market.buy);
add("POST", "/market/:id/bid", "user", market.bid);
add("POST", "/market/:id/watch", "user", market.watch);
add("DELETE", "/market/:id/watch", "user", market.unwatch);
add("DELETE", "/market/:id", "user", market.cancel);
add("GET", "/watchlist", "user", market.watchlist);

add("GET", "/syndicate", "user", syndicate.mine);
add("POST", "/syndicate", "user", syndicate.create);
add("POST", "/syndicate/invite", "user", syndicate.invite);
add("POST", "/syndicate/invites/:id/accept", "user", syndicate.accept);
add("POST", "/syndicate/leave", "user", syndicate.leave);
add("POST", "/syndicate/treasury", "user", syndicate.treasury);
add("GET", "/syndicates/leaderboard", "user", syndicate.leaderboard);

add("GET", "/admin/status", "admin", admin.status);
add("POST", "/admin/advance", "admin", admin.advance);
add("POST", "/admin/reset", "admin", admin.reset);
add("POST", "/admin/house", "admin", admin.house);
add("POST", "/admin/card", "admin", admin.grantCard);
add("POST", "/admin/grudge", "admin", admin.grudge);
add("POST", "/admin/bonus", "admin", admin.bonus);

export async function route(L: League, req: Request): Promise<Response> {
  const url = new URL(req.url);
  const path = normPath(url.pathname);
  const text = await bodyText(req);
  if (text.length > 16384) fail("bad_request", "body too large");
  if (path === "/v1/batch") return batch(L, req, url, text);
  let who: Promise<Principal> | undefined;
  const r = await dispatch(L, req, url, path, text, () => (who ??= principal(L, req, url, text)));
  if (r) return json(r.body, 200, r.now);
  if (path === "/" || path === "/v1") return json({ name: "DEADBALL", api: "v1" });
  return fail("not_found", "no such page");
}

function normPath(p: string): string {
  const path = p.replace(/\/+$/, "");
  return path === "" ? "/" : path;
}

/**
 * Runs the matching handler and returns its (not yet serialized) result, or undefined when
 * no route matches the path. Throws HttpError for auth failures, a wrong method, and
 * whatever the handler throws. `who` resolves the caller (bearer / signed), only when needed.
 */
async function dispatch(L: League, req: Request, url: URL, path: string, text: string, who: () => Promise<Principal>): Promise<{ body: unknown; now: number } | undefined> {
  let methodMatched = false;
  for (const [method, re, auth, h] of routes) {
    const m = re.exec(path);
    if (!m) continue;
    methodMatched = true;
    if (method !== req.method) continue;
    const params = m.slice(1).map(decodeURIComponent);
    const c = { L, db: L.bindings.DB, req, url, q: url.searchParams, now: Date.now(), params, body: {} } as unknown as Ctx;
    if (auth === "admin") {
      const want = L.bindings.ADMIN_TOKEN;
      const got = req.headers.get("x-admin-token") ?? "";
      if (!want || !safeEqual(got, want)) fail("unauthorized", "admin token required");
    } else if (auth === "user") {
      c.who = await who();
      c.acct = await loadAccount(L.bindings.DB, c.who);
    }
    c.body = req.method === "GET" || req.method === "DELETE" ? {} : parseBody(text);
    // card backs (any season's card) and redemptions (career totals) need every season's stats
    if (STATS_PATHS.test(path)) L.ensureStats();
    return { body: await h(c), now: c.now };
  }
  if (methodMatched) fail("bad_request", `method ${req.method} not allowed`);
  return undefined;
}

// Batch ------------------------------------------------------------------------------------
// The Playdate pays 7-11 s of Wi-Fi/TLS setup per connection and almost nothing per byte,
// so it fetches several GETs in one request. Each item runs through the same route table,
// auth and relative-time rewrite as a lone GET; failures are per item.

export const BATCH_MAX_ITEMS = 20;
export const BATCH_MAX_PATH = 512;
/** Response budget (serialized item bodies; env BATCH_MAX_BYTES overrides). Items past it come back 413 `too_large`; fetch those alone. */
export const BATCH_MAX_BYTES = 256 * 1024;

function batchPaths(req: Request, url: URL, text: string): string[] {
  if (req.method === "GET") return url.searchParams.getAll("p");
  if (req.method !== "POST") return fail("bad_request", `method ${req.method} not allowed`);
  let v: unknown;
  try { v = JSON.parse(text); } catch { return fail("bad_request", "body is not valid JSON"); }
  const list = Array.isArray(v) ? v : (v && typeof v === "object" ? (v as Record<string, unknown>).paths : undefined);
  if (!Array.isArray(list)) fail("bad_request", "body must be a JSON array of paths (or { paths: [...] })");
  return list as string[];
}

async function batch(L: League, req: Request, url: URL, text: string): Promise<Response> {
  const raw = batchPaths(req, url, text);
  if (!raw.length) fail("bad_request", "p (a path) is required");
  if (raw.some(p => typeof p !== "string" || !p.startsWith("/") || p.length > BATCH_MAX_PATH)) {
    fail("bad_request", `each path must be a string starting with "/" (max ${BATCH_MAX_PATH} chars)`);
  }
  const paths = [...new Set(raw)];
  if (paths.length > BATCH_MAX_ITEMS) fail("bad_request", `at most ${BATCH_MAX_ITEMS} paths per batch`);
  // a signed batch is verified (and spends its seq) once, here; every item runs as that caller
  const who = await principal(L, req, url, text);
  const whoFn = () => Promise.resolve(who);
  const headers = new Headers(req.headers);
  headers.delete("content-type");
  headers.delete("content-length");
  const budget = Number(L.bindings.BATCH_MAX_BYTES) || BATCH_MAX_BYTES;
  let used = 0;
  const parts: string[] = [];
  for (const p of paths) {
    let status = 200;
    let text: string;
    try {
      const sub = new URL("/v1" + p, url);
      const path = normPath(sub.pathname);
      if (path === "/v1/batch") fail("bad_request", "batches don't nest");
      const r = await dispatch(L, new Request(sub, { method: "GET", headers }), sub, path, "", whoFn);
      if (!r) fail("not_found", "no such page");
      text = JSON.stringify(withRelativeTimes(r!.body, r!.now));
    } catch (e) {
      const he = e instanceof HttpError ? e : new HttpError("internal", "Something broke at the ballpark.");
      if (!(e instanceof HttpError)) console.error(e);
      status = he.status;
      text = JSON.stringify({ error: he.code, message: he.message });
    }
    if (status === 200 && used + text.length > budget) {
      status = 413;
      text = JSON.stringify({ error: "too_large", message: "batch budget exceeded; fetch this path on its own" });
    }
    used += text.length;
    parts.push(`${JSON.stringify(p)}:{"status":${status},"body":${text}}`);
  }
  return new Response(`{"n":${paths.length},"results":{${parts.join(",")}}}`, { status: 200, headers: { "content-type": "application/json; charset=utf-8" } });
}
