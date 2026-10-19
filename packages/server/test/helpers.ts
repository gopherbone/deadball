import { exports } from "cloudflare:workers";

export const ADMIN = "test-admin";

export async function api<T = any>(method: string, path: string, body?: unknown, token?: string, admin = false): Promise<{ status: number; body: T }> {
  const headers: Record<string, string> = { "content-type": "application/json" };
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
