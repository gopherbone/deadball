import { describe, expect, it } from "vitest";
import { env, exports } from "cloudflare:workers";
import pdxinfo from "../../../playdate/source/pdxinfo?raw";
import { BUILD, api } from "./helpers.ts";

const fetchW = (r: Request) => (exports as any).default.fetch(r) as Promise<Response>;
const MIN = Number((env as unknown as { MIN_BUILD?: string }).MIN_BUILD);

async function get(path: string, headers: Record<string, string> = {}, method = "GET") {
  const res = await fetchW(new Request(`https://deadball.test${path}`, { method, headers }));
  const t = await res.text();
  let body: any = t;
  try { body = JSON.parse(t); } catch { /* the health text */ }
  return { status: res.status, body };
}

describe("build gate (X-Build vs MIN_BUILD)", () => {
  it("the client's pdxinfo buildNumber equals wrangler.jsonc's MIN_BUILD (bump both every release)", () => {
    const m = /^buildNumber=(\d+)\s*$/m.exec(pdxinfo);
    expect(m, "playdate/source/pdxinfo has a buildNumber line").not.toBeNull();
    expect(Number.isInteger(MIN) && MIN > 0, "wrangler.jsonc vars.MIN_BUILD is a positive integer").toBe(true);
    expect(Number(m![1])).toBe(MIN);
    expect(BUILD).toBe(MIN);
  });

  it("a request without X-Build gets 426 upgrade_required with minBuild", async () => {
    const r = await get("/v1/clock");
    expect(r.status).toBe(426);
    expect(r.body).toMatchObject({ error: "upgrade_required", minBuild: MIN, build: null });
    expect(r.body.message).toMatch(/out of date/);
    // writes and authenticated paths too, before auth runs
    const reg = await fetchW(new Request("https://deadball.test/v1/register", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ name: "Old Timer" }) }));
    expect(reg.status).toBe(426);
    expect((await get("/v1/me", { authorization: "Bearer nope" })).status).toBe(426);
    expect((await get("/v1/batch?p=%2Fclock")).status).toBe(426);
    expect((await get("/v1/clock", { "x-build": "two" })).status).toBe(426);
  });

  it("an older build gets 426 and is told what it has and what it needs", async () => {
    const r = await get("/v1/clock", { "x-build": String(MIN - 1) });
    expect(r.status).toBe(426);
    expect(r.body).toEqual({ error: "upgrade_required", message: expect.stringContaining(`build ${MIN - 1}`), minBuild: MIN, build: MIN - 1 });
    expect(r.body.message).toContain(`build ${MIN} or newer`);
  });

  it("the current build (and newer) goes through", async () => {
    expect((await get("/v1/clock", { "x-build": String(MIN) })).status).toBe(200);
    expect((await get("/v1/clock", { "x-build": String(MIN + 1) })).status).toBe(200);
    const reg = await api("POST", "/register", { name: "Fresh Build" });
    expect(reg.status).toBe(200);
    expect((await api("GET", "/me", undefined, reg.body.token)).status).toBe(200);
  });

  it("GET /v1/version and the health text answer any build", async () => {
    for (const p of ["/v1/version", "/v1/version/"]) {
      const r = await get(p);
      expect(r.status).toBe(200);
      expect(r.body).toEqual({ minBuild: MIN });
    }
    expect((await get("/v1/version", { "x-build": "1" })).body).toEqual({ minBuild: MIN });
    const root = await get("/");
    expect(root.status).toBe(200);
    expect(root.body).toContain("DEADBALL");
    // only the GET is exempt
    expect((await get("/v1/version", {}, "POST")).status).toBe(426);
  });
});
