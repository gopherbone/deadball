import type { Ctx } from "../router.ts";
import { HttpError, fail, newId, newToken, sha256, str } from "../http.ts";
import { newSignKey, requireHttps } from "../auth.ts";
import { sim, normalizeName, isReservedName } from "../sim.ts";
import { accountView } from "./common.ts";
import { pubGameId } from "../league.ts";

const RESERVED = ["admin", "administrator", "moderator", "mod", "system", "server", "deadball", "house", "the house", "league", "commissioner", "bobby", "bets by bobby", "sportswire", "anonymous", "nobody", "playdate", "panic"];

/** Uniqueness key: case-, accent- and lookalike-insensitive (social module). */
export const normName = (n: string) => normalizeName(n) || n.trim().toLowerCase();

/** Account-name rules: social module filter + reserved names (incl. world teams/factions). */
export function checkName(c: Ctx, raw: string): string {
  const res = sim.checkAccountName(raw);
  if (!res.ok) return fail("name_rejected", res.reason);
  const lc = normName(res.name);
  const flat = lc.replace(/[^a-z0-9]/g, "");
  const w = c.L.world;
  const worldNames = [...Object.values(w.teams).flatMap(t => [t.name, t.abbr, `${t.city} ${t.name}`]), ...Object.values(w.factions).map(f => f.name)];
  if (isReservedName(res.name, w) || RESERVED.some(r => flat === r.replace(/[^a-z0-9]/g, "")) || worldNames.some(n => n.toLowerCase().replace(/[^a-z0-9]/g, "") === flat)) fail("name_rejected", "that name is reserved");
  return res.name;
}

/**
 * Per-IP fixed window on account creation (attempts count, good or bad). Cloudflare always sets
 * CF-Connecting-IP in production; requests without it (local scripts, tests) aren't limited here.
 * The edge rule in docs/DEPLOY.md is the first line of defence; this is the second.
 */
function registerLimit(c: Ctx) {
  const ip = c.req.headers.get("cf-connecting-ip");
  if (!ip) return;
  const limit = Math.max(1, Number(c.L.bindings.REGISTER_LIMIT ?? 5));
  const windowMs = Math.max(1000, Number(c.L.bindings.REGISTER_WINDOW_MS ?? 3_600_000));
  const wait = c.L.rateLimit(`register:${ip}`, limit, windowMs, c.now);
  if (wait) throw new HttpError("rate_limited", `too many new accounts from here; try again in ${Math.ceil(wait / 60)} min`, 429, wait);
}

export async function register(c: Ctx) {
  requireHttps(c.req, c.url);
  registerLimit(c);
  const name = checkName(c, str(c.body, "name", 64));
  const token = newToken();
  const id = newId("a");
  const day = c.L.shownDay(c.now).day;
  const key = newSignKey();
  const r = await c.db.prepare("INSERT OR IGNORE INTO accounts (id, name, name_lc, token_hash, money, joined_day, created_at, free_packs, sign_key) VALUES (?,?,?,?,1000,?,?,1,?)")
    .bind(id, name, normName(name), await sha256(token), day, c.now, key).run();
  if (!r.meta.changes) fail("name_taken", "somebody already goes by that name");
  await c.db.prepare("INSERT INTO ledger (id, account_id, delta, reason, at, season) VALUES (?,?,1000,'grant',?,?)").bind(`grant:${id}`, id, c.now, c.L.state.season).run();
  await c.db.prepare("INSERT INTO mail (id, account_id, at, read, kind, data) VALUES (?,?,?,0,'league',?)").bind(`welcome:${id}`, id, c.now, JSON.stringify({
    from: "The Commissioner's Office", subject: "Welcome to the league",
    body: ["Here's $1,000 and a free starter pack. Spend it wisely, or don't.", "Games air every half hour. Bets close at first pitch.", "Remember: nothing in this league is fixed. Officially."],
    kind: "league",
  })).run();
  c.acct = { id } as Ctx["acct"];
  return { token, key, account: await accountView(c, id) };
}

/**
 * POST /v1/auth/key (HTTPS + bearer only): issues or rotates the account's request-signing
 * key. A new key starts a fresh replay window, so a client that lost its counter recovers here.
 */
export async function authKey(c: Ctx) {
  requireHttps(c.req, c.url);
  if (c.who.kind !== "bearer") fail("unauthorized", "a new signing key needs the bearer token (over HTTPS)");
  const key = newSignKey();
  await c.db.prepare("UPDATE accounts SET sign_key = ? WHERE id = ?").bind(key, c.acct.id).run();
  c.L.resetSeq(c.acct.id);
  return { key, accountId: c.acct.id };
}

export async function me(c: Ctx) {
  return { account: await accountView(c) };
}

export async function clock(c: Ctx) {
  const L = c.L;
  const d = L.shownDay(c.now);
  // first pitches are staggered: the next game to lock, and how many are on the air right now
  const next = L.nextPitch();
  const live = await c.db.prepare("SELECT COUNT(*) AS n FROM games WHERE simmed = 1 AND level IN ('ML', 'EL') AND first_pitch_at > ? AND first_pitch_at <= ? AND first_pitch_at + air_ms > ?")
    .bind(c.now - 2 * L.dayMs, c.now, c.now).first<{ n: number }>();
  const out: Record<string, unknown> = { now: c.now, season: d.season, day: d.day, phase: L.state.phase, nextDayAt: d.nextDayAt, msPerDay: L.dayMs, year: L.world.year, onAir: live?.n ?? 0 };
  if (next) {
    const w = L.world;
    out.nextPitchAt = next.at;
    out.nextGame = { id: pubGameId(L.state.season, next.game.id), away: w.teams[next.game.awayId]?.abbr ?? next.game.awayId, home: w.teams[next.game.homeId]?.abbr ?? next.game.homeId };
  }
  return out;
}
