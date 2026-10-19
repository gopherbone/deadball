// HTTP plumbing: errors, JSON, validation, cursors, ids, hashing.

export interface Env {
  DB: D1Database;
  LOGS: R2Bucket;
  LEAGUE: DurableObjectNamespace;
  GAME_DAY_MS?: string;
  AIR_MS?: string;
  WORLD_SEED?: string;
  /** server-only secret mixed into the run-time seed (wrangler secret put SIM_SALT) */
  SIM_SALT?: string;
  ADMIN_TOKEN?: string;
  OFFSEASON_DAYS?: string;
  /** dev/fixtures only: override the 20 s comment gap */
  COMMENT_GAP_MS?: string;
  /** POST /v1/register: accounts per client IP per window (default 5 per hour) */
  REGISTER_LIMIT?: string;
  REGISTER_WINDOW_MS?: string;
  /** GET /v1/batch response budget in bytes (default 256 KB) */
  BATCH_MAX_BYTES?: string;
  /** Multiplier on Bobby's regulars' (house NPC) money, default 1; 0 = off. POST /v1/admin/house overrides it. */
  HOUSE_SCALE?: string;
}

export type ErrorCode =
  | "bad_request" | "unauthorized" | "not_found" | "name_taken" | "name_rejected" | "insufficient_funds"
  | "window_closed" | "rate_limited" | "invalid_comment" | "forbidden" | "too_large" | "internal"
  | "bad_signature" | "replayed" | "https_required";

const STATUS: Record<ErrorCode, number> = {
  bad_request: 400, unauthorized: 401, not_found: 404, name_taken: 409, name_rejected: 400, insufficient_funds: 402,
  window_closed: 409, rate_limited: 429, invalid_comment: 400, forbidden: 403, too_large: 413, internal: 500,
  bad_signature: 401, replayed: 401, https_required: 403,
};

export class HttpError extends Error {
  code: ErrorCode;
  status: number;
  /** seconds, for 429s (Retry-After) */
  retryAfter?: number;
  constructor(code: ErrorCode, message: string, status = STATUS[code], retryAfter?: number) {
    super(message);
    this.code = code;
    this.status = status;
    if (retryAfter !== undefined) this.retryAfter = retryAfter;
  }
}
export const fail = (code: ErrorCode, message: string): never => { throw new HttpError(code, message); };

/**
 * The Playdate's JSON decoder mangles 13-digit epoch-ms numbers (Lua floats are single
 * precision there), so every timestamp also gets a small relative companion in seconds:
 * `fooAt` -> `fooIn` (seconds until; negative if past) and `at` -> `ago` (seconds since).
 * The client should prefer the relative fields; the absolute ones stay for everyone else.
 */
export function withRelativeTimes(v: unknown, now: number): unknown {
  if (Array.isArray(v)) return v.map(x => withRelativeTimes(x, now));
  if (!v || typeof v !== "object") return v;
  const out: Record<string, unknown> = {};
  for (const [k, x] of Object.entries(v as Record<string, unknown>)) {
    out[k] = withRelativeTimes(x, now);
    if (typeof x !== "number" || x < 1e12) continue;
    if (k === "at") { if (!("ago" in v)) out.ago = Math.round((now - x) / 1000); }
    else if (k.endsWith("At")) {
      const rel = `${k.slice(0, -2)}In`;
      if (!(rel in v)) out[rel] = Math.round((x - now) / 1000);
    }
  }
  return out;
}

export function json(body: unknown, status = 200, now = Date.now()): Response {
  return new Response(JSON.stringify(withRelativeTimes(body, now)), { status, headers: { "content-type": "application/json; charset=utf-8" } });
}
export function errorResponse(e: unknown): Response {
  if (e instanceof HttpError) {
    const r = json({ error: e.code, message: e.message }, e.status);
    if (e.code === "rate_limited") r.headers.set("retry-after", String(e.retryAfter ?? 20));
    return r;
  }
  console.error(e);
  return json({ error: "internal", message: "Something broke at the ballpark." }, 500);
}

export async function readBody(req: Request): Promise<Record<string, unknown>> {
  if (req.method === "GET" || req.method === "DELETE") return {};
  return parseBody(await req.text());
}

export async function bodyText(req: Request): Promise<string> {
  if (req.method === "GET" || req.method === "DELETE") return "";
  return req.text();
}

export function parseBody(text: string): Record<string, unknown> {
  if (!text) return {};
  if (text.length > 8192) fail("bad_request", "body too large");
  try {
    const v = JSON.parse(text);
    // The Playdate's json.encode turns an empty Lua table into "[]": same as no fields.
    if (Array.isArray(v) && v.length === 0) return {};
    if (!v || typeof v !== "object" || Array.isArray(v)) fail("bad_request", "body must be a JSON object");
    return v as Record<string, unknown>;
  } catch (e) {
    if (e instanceof HttpError) throw e;
    return fail("bad_request", "body is not valid JSON");
  }
}

export function str(b: Record<string, unknown>, k: string, max = 200): string {
  const v = b[k];
  if (typeof v !== "string" || !v.length) fail("bad_request", `${k} is required`);
  if ((v as string).length > max) fail("bad_request", `${k} is too long`);
  return v as string;
}
export function int(b: Record<string, unknown>, k: string, min: number, max: number): number {
  const v = b[k];
  if (typeof v !== "number" || !Number.isInteger(v)) fail("bad_request", `${k} must be an integer`);
  if ((v as number) < min || (v as number) > max) fail("bad_request", `${k} must be between ${min} and ${max}`);
  return v as number;
}
export function strArray(b: Record<string, unknown>, k: string, maxLen: number, maxItem = 80): string[] {
  const v = b[k] ?? [];
  if (!Array.isArray(v) || v.length > maxLen || v.some(x => typeof x !== "string" || x.length > maxItem)) fail("bad_request", `${k} must be an array of strings (max ${maxLen})`);
  return v as string[];
}
export function oneOf<T extends string>(b: Record<string, unknown>, k: string, opts: readonly T[]): T {
  const v = b[k];
  if (typeof v !== "string" || !opts.includes(v as T)) fail("bad_request", `${k} must be one of ${opts.join(", ")}`);
  return v as T;
}

/** Opaque pagination cursors: base64url JSON. */
export function encCursor(v: unknown): string {
  return btoa(JSON.stringify(v)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
export function decCursor<T>(s: string | null): T | undefined {
  if (!s) return undefined;
  try {
    return JSON.parse(atob(s.replace(/-/g, "+").replace(/_/g, "/"))) as T;
  } catch {
    return fail("bad_request", "bad cursor");
  }
}

export function newId(prefix: string): string {
  const b = new Uint8Array(9);
  crypto.getRandomValues(b);
  return prefix + Array.from(b, x => x.toString(36).padStart(2, "0")).join("").slice(0, 14);
}
export function newToken(): string {
  const b = new Uint8Array(24);
  crypto.getRandomValues(b);
  return Array.from(b, x => x.toString(16).padStart(2, "0")).join("");
}
export async function sha256(s: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return Array.from(new Uint8Array(d), x => x.toString(16).padStart(2, "0")).join("");
}

/** Constant-time-ish string compare for the admin token. */
export function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let x = 0;
  for (let i = 0; i < a.length; i++) x |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return x === 0;
}
