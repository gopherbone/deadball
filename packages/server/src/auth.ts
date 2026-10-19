// Who is calling: a bearer token (HTTPS only) or an HMAC-signed request (any transport).
//
// The Playdate pays ~3.6 s per TLS handshake and ~0.3 s for plain HTTP, and nothing here is
// secret, so after one HTTPS call to get a signing key it talks plain HTTP with every request
// signed: integrity + authentication + replay protection, no confidentiality. See docs/API.md
// "Transport & signing" and docs/DEPLOY.md "Security model".
//
//   X-Acct: <account id>
//   X-Seq:  <integer 1..2^31-1, per account, never reused>
//   X-Sig:  hex(HMAC-SHA256(key, METHOD + "\n" + path-with-query + "\n" + seq + "\n" + hex(SHA256(body))))
//
// key is the 64-char hex string as ASCII bytes; path-with-query is the request target exactly
// as sent ("/v1/batch?p=%2Fme"); body is the raw body text ("" for GET/DELETE).

import type { League } from "./league.ts";
import type { AccountRow } from "./router.ts";
import { HttpError, fail, sha256 } from "./http.ts";

export type Principal = { kind: "none" } | { kind: "bearer"; tokenHash: string } | { kind: "signed"; id: string };

/** Replay window: a seq is accepted once, if it's above (highest seen - SEQ_WINDOW). */
export const SEQ_WINDOW = 128;

const LOCAL = /^(localhost|127\.0\.0\.1|\[::1\])$/;

/** True when the request came in over plain HTTP (local dev hosts excepted). */
export function insecure(req: Request, url: URL): boolean {
  if (LOCAL.test(url.hostname)) return false;
  const v = req.headers.get("cf-visitor");
  if (v) {
    try { return (JSON.parse(v) as { scheme?: string }).scheme === "http"; } catch { /* fall through */ }
  }
  return url.protocol === "http:";
}

export function requireHttps(req: Request, url: URL) {
  if (insecure(req, url)) throw new HttpError("https_required", "this needs HTTPS (tokens and keys never travel in the clear)", 403);
}

const enc = new TextEncoder();
const hex = (b: ArrayBuffer) => Array.from(new Uint8Array(b), x => x.toString(16).padStart(2, "0")).join("");

export async function hmacHex(key: string, msg: string): Promise<string> {
  const k = await crypto.subtle.importKey("raw", enc.encode(key), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return hex(await crypto.subtle.sign("HMAC", k, enc.encode(msg)));
}

export async function signingString(method: string, target: string, seq: number | string, body: string): Promise<string> {
  return `${method}\n${target}\n${seq}\n${await sha256(body)}`;
}

function constEq(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let x = 0;
  for (let i = 0; i < a.length; i++) x |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return x === 0;
}

/**
 * Works out the caller. Signed requests are verified (signature, then replay window) here,
 * once per HTTP request; a bearer token over plain HTTP is refused.
 */
export async function principal(L: League, req: Request, url: URL, body: string): Promise<Principal> {
  const acct = req.headers.get("x-acct");
  if (acct) {
    const seqS = req.headers.get("x-seq") ?? "";
    const sig = (req.headers.get("x-sig") ?? "").toLowerCase();
    if (!/^[1-9][0-9]{0,9}$/.test(seqS) || Number(seqS) > 2147483647 || !/^[0-9a-f]{64}$/.test(sig)) fail("bad_signature", "X-Seq and X-Sig are required");
    const row = await L.bindings.DB.prepare("SELECT sign_key FROM accounts WHERE id = ?").bind(acct).first<{ sign_key: string | null }>();
    if (!row || !row.sign_key) fail("bad_signature", "no signing key for that account; get one at POST /v1/auth/key");
    const want = await hmacHex(row!.sign_key!, await signingString(req.method, url.pathname + url.search, seqS, body));
    if (!constEq(want, sig)) fail("bad_signature", "signature doesn't match");
    if (!L.acceptSeq(acct, Number(seqS), SEQ_WINDOW)) fail("replayed", "that request was already used");
    return { kind: "signed", id: acct };
  }
  const h = req.headers.get("authorization");
  if (h) {
    const m = /^Bearer\s+([A-Za-z0-9_-]{16,128})$/.exec(h);
    if (!m) fail("unauthorized", "missing bearer token");
    // the token already crossed the wire in the clear, but never act on it: the client must not do this
    if (insecure(req, url)) throw new HttpError("https_required", "bearer tokens only over HTTPS; sign plain-HTTP requests (X-Acct/X-Seq/X-Sig)", 403);
    return { kind: "bearer", tokenHash: await sha256(m![1]) };
  }
  return { kind: "none" };
}

export async function loadAccount(db: D1Database, p: Principal): Promise<AccountRow> {
  let row: AccountRow | null = null;
  if (p.kind === "bearer") row = await db.prepare("SELECT * FROM accounts WHERE token_hash = ?").bind(p.tokenHash).first<AccountRow>();
  else if (p.kind === "signed") row = await db.prepare("SELECT * FROM accounts WHERE id = ?").bind(p.id).first<AccountRow>();
  else fail("unauthorized", "missing bearer token");
  if (!row) fail("unauthorized", "unknown token");
  return row!;
}

export function newSignKey(): string {
  const b = new Uint8Array(32);
  crypto.getRandomValues(b);
  return Array.from(b, x => x.toString(16).padStart(2, "0")).join("");
}
