// Boots the Worker locally (wrangler's unstable_dev: real workerd, local D1/R2/DO) for
// scripts. Applies D1 migrations into the same persistence dir first.

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { unstable_dev } from "wrangler";

export const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
export const ADMIN_TOKEN = "dev-admin-token";
/** The Playdate client's build (pdxinfo buildNumber): sent as X-Build so the build gate (src/version.ts) lets scripts in. */
export const CLIENT_BUILD = /^buildNumber=(\d+)\s*$/m.exec(readFileSync(join(ROOT, "..", "..", "playdate", "source", "pdxinfo"), "utf8"))?.[1] ?? "0";

export interface Local {
  call<T = any>(method: string, path: string, body?: unknown, token?: string, admin?: boolean): Promise<{ status: number; body: T }>;
  ok<T = any>(method: string, path: string, body?: unknown, token?: string, admin?: boolean): Promise<T>;
  stop(): Promise<void>;
}

export async function startLocal(opts: { persistTo: string; vars?: Record<string, string> }): Promise<Local> {
  const persistTo = resolve(ROOT, opts.persistTo);
  const wrangler = join(ROOT, "..", "..", "node_modules", ".bin", "wrangler");
  execFileSync(wrangler, ["d1", "migrations", "apply", "DB", "--local", "--persist-to", persistTo], { cwd: ROOT, stdio: ["ignore", "ignore", "inherit"], env: { ...process.env, CI: "1" } });
  const worker = await unstable_dev(join(ROOT, "src", "index.ts"), {
    config: join(ROOT, "wrangler.jsonc"),
    persistTo,
    vars: { ADMIN_TOKEN, ...opts.vars },
    logLevel: "warn",
    experimental: { disableExperimentalWarning: true, testMode: true },
  } as Parameters<typeof unstable_dev>[1]);
  const call = async (method: string, path: string, body?: unknown, token?: string, admin = false) => {
    // stand in for an HTTPS client (bearer tokens are refused over plain HTTP off localhost)
    const headers: Record<string, string> = { "content-type": "application/json", "cf-visitor": '{"scheme":"https"}', "x-build": CLIENT_BUILD };
    if (token) headers.authorization = `Bearer ${token}`;
    if (admin) headers["x-admin-token"] = ADMIN_TOKEN;
    const res = await worker.fetch(`/v1${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
    const text = await res.text();
    return { status: res.status, body: text ? JSON.parse(text) : undefined };
  };
  return {
    call,
    async ok(method, path, body, token, admin) {
      const r = await call(method, path, body, token, admin);
      if (r.status !== 200) throw new Error(`${method} ${path} -> ${r.status} ${JSON.stringify(r.body)}`);
      return r.body;
    },
    stop: () => worker.stop(),
  };
}

export const sleep = (ms: number) => new Promise(r => setTimeout(r, ms));
