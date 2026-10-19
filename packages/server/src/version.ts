// Build gate. Online play needs the latest client: every /v1 request carries the client's
// build number (`X-Build`, the Playdate's pdxinfo `buildNumber`) and anything older than
// MIN_BUILD (wrangler.jsonc vars) gets 426 `upgrade_required`. Offline play never talks to
// the server, so old builds keep working there. Each release bumps pdxinfo's buildNumber and
// MIN_BUILD together (test/version.test.ts keeps them equal).
//
// Exempt: GET /v1/version (`{ minBuild }`, so anything can ask what it needs) and the
// non-/v1 health text.

import { json, type Env } from "./http.ts";

/** MIN_BUILD as a number; 0 (no gate) when unset or not a positive integer. */
export function minBuild(env: Env): number {
  const n = Number(env.MIN_BUILD);
  return Number.isInteger(n) && n > 0 ? n : 0;
}

/** The client's X-Build, or undefined when it's missing or not a plain integer. */
export function clientBuild(req: Request): number | undefined {
  const raw = (req.headers.get("x-build") ?? "").trim();
  return /^\d{1,9}$/.test(raw) ? Number(raw) : undefined;
}

/**
 * Answers GET /v1/version, or 426 for a /v1 request from a build older than MIN_BUILD.
 * Returns undefined when the request may go on to the league.
 */
export function buildGate(req: Request, url: URL, env: Env): Response | undefined {
  const min = minBuild(env);
  const path = url.pathname.replace(/\/+$/, "");
  if (path === "/v1/version" && (req.method === "GET" || req.method === "HEAD")) return json({ minBuild: min });
  if (min === 0) return undefined;
  const build = clientBuild(req);
  if (build !== undefined && build >= min) return undefined;
  const yours = build === undefined ? "an unknown build" : `build ${build}`;
  return json({
    error: "upgrade_required",
    message: `This copy of DEADBALL is out of date (${yours}; the league needs build ${min} or newer). Rebuild it from the latest source or download the newest release. Pennant '96 still works offline.`,
    minBuild: min,
    build: build ?? null,
  }, 426);
}
