import { exports } from "cloudflare:workers";
import pdxinfo from "../../../playdate/source/pdxinfo?raw";

export const ADMIN = "test-admin";

/** The Playdate client's build number (pdxinfo buildNumber), sent as X-Build like the client does. */
export const BUILD = Number(/^buildNumber=(\d+)\s*$/m.exec(pdxinfo)?.[1]);
/** Headers every client request carries. */
export const clientHeaders = (h: Record<string, string> = {}): Record<string, string> => ({ "x-build": String(BUILD), ...h });

export async function api<T = any>(method: string, path: string, body?: unknown, token?: string, admin = false): Promise<{ status: number; body: T }> {
  const headers = clientHeaders({ "content-type": "application/json" });
  if (token) headers.authorization = `Bearer ${token}`;
  if (admin) headers["x-admin-token"] = ADMIN;
  const res = await (exports as any).default.fetch(new Request(`https://deadball.test/v1${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) }));
  const text = await res.text();
  return { status: res.status, body: text ? JSON.parse(text) : undefined };
}

export async function register(name: string) {
  const r = await api("POST", "/register", { name });
  if (r.status !== 200) throw new Error(`register ${name}: ${r.status} ${JSON.stringify(r.body)}`);
  return r.body as { token: string; account: any };
}

export const advance = (days = 1) => api("POST", "/admin/advance", { days }, undefined, true);

/** Bobby's regulars (house NPC money) multiplier; 0 = off (player-only pools, the pre-house rules). */
export const houseScale = (scale: number) => api("POST", "/admin/house", { scale }, undefined, true);
