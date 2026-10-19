import { describe, expect, it } from "vitest";
import { exports } from "cloudflare:workers";
import { BATCH_MAX_ITEMS } from "../src/router.ts";

/** vitest.config.ts sets BATCH_MAX_BYTES=65536 so a couple of replay logs overflow it */
const BATCH_MAX_BYTES = 65536;
import { advance, api, register } from "./helpers.ts";

const q = (paths: string[]) => "/batch?" + paths.map(p => "p=" + encodeURIComponent(p)).join("&");

describe("GET /v1/batch", () => {
  it("returns each path's body exactly as a lone GET would (relative times included)", async () => {
    const a = await register("Batch Fan");
    const paths = ["/me", "/clock", "/bets?status=open", "/standings?level=ML"];
    const b = await api("GET", q(paths), undefined, a.token);
    expect(b.status).toBe(200);
    expect(b.body.n).toBe(4);
    expect(Object.keys(b.body.results).sort()).toEqual([...paths].sort());
    for (const p of paths) {
      const single = await api("GET", p, undefined, a.token);
      const item = b.body.results[p];
      expect(item.status).toBe(200);
      if (p === "/clock") {
        // time moves between the two calls; compare the shape and the relative field
        expect(item.body.day).toBe(single.body.day);
        expect(typeof item.body.nextDayIn).toBe("number");
        expect(Math.abs(item.body.nextDayIn - single.body.nextDayIn)).toBeLessThanOrEqual(2);
      } else {
        expect(item.body).toEqual(single.body);
      }
    }
    expect(b.body.results["/me"].body.account.name).toBe("Batch Fan");
  });

  it("reports errors per item: auth, 404, bad method, nesting", async () => {
    const a = await register("Batch Errs");
    const b = await api("GET", q(["/clock", "/nope", "/register", "/batch?p=/clock", "/news/doesnotexist"]), undefined, a.token);
    expect(b.status).toBe(200);
    const r = b.body.results;
    expect(r["/clock"].status).toBe(200);
    expect(r["/nope"]).toEqual({ status: 404, body: { error: "not_found", message: "no such page" } });
    expect(r["/register"].status).toBe(400); // POST-only route
    expect(r["/batch?p=/clock"].status).toBe(400);
    expect(r["/news/doesnotexist"].status).toBe(404);
    // no token: public paths work, user paths 401 one by one
    const anon = await api("GET", q(["/clock", "/me"]));
    expect(anon.body.results["/clock"].status).toBe(200);
    expect(anon.body.results["/me"].status).toBe(401);
    expect(anon.body.results["/me"].body.error).toBe("unauthorized");
    // a bad token is a per-item 401 too, not a failed batch
    const bad = await api("GET", q(["/me"]), undefined, "x".repeat(32));
    expect(bad.status).toBe(200);
    expect(bad.body.results["/me"].status).toBe(401);
  });

  it("validates the path list and caps it", async () => {
    expect((await api("GET", "/batch")).status).toBe(400);
    expect((await api("GET", q(["clock"]))).status).toBe(400);
    expect((await api("GET", q(["/" + "x".repeat(600)]))).status).toBe(400);
    const many = Array.from({ length: BATCH_MAX_ITEMS + 1 }, (_, i) => `/clock?i=${i}`);
    expect((await api("GET", q(many))).status).toBe(400);
    // duplicates collapse
    const dup = await api("GET", q(["/clock", "/clock"]));
    expect(dup.body.n).toBe(1);
    expect((await api("DELETE", "/batch")).status).toBe(400);
  });

  it("accepts POST with a JSON list", async () => {
    const a = await register("Batch Poster");
    const r1 = await api("POST", "/batch", ["/me", "/clock"], a.token);
    expect(r1.status).toBe(200);
    expect(r1.body.results["/me"].body.account.name).toBe("Batch Poster");
    const r2 = await api("POST", "/batch", { paths: ["/clock"] }, a.token);
    expect(r2.body.results["/clock"].status).toBe(200);
    expect((await api("POST", "/batch", { nope: 1 }, a.token)).status).toBe(400);
  });

  it("returns 413 too_large for items past the byte budget", async () => {
    const a = await register("Batch Hog");
    const today = await api("GET", "/today", undefined, a.token);
    const ids: string[] = (today.body.games ?? []).map((g: any) => g.id);
    await advance(1);
    expect(ids.length).toBeGreaterThan(0);
    // full replay logs are the big responses; ask for enough of them to blow the budget
    const paths = ids.flatMap(id => [`/games/${id}/log`, `/games/${id}/log?fmt=c`]).slice(0, BATCH_MAX_ITEMS);
    const sizes = await Promise.all(paths.map(async p => JSON.stringify((await api("GET", p, undefined, a.token)).body).length));
    const b = await api("GET", q(paths), undefined, a.token);
    let used = 0, cut = 0;
    paths.forEach((p, i) => {
      const it = b.body.results[p];
      if (used + sizes[i] <= BATCH_MAX_BYTES) { expect(it.status).toBe(200); used += sizes[i]; }
      else { expect(it).toEqual({ status: 413, body: { error: "too_large", message: expect.any(String) } }); cut++; used += JSON.stringify(it.body).length; }
    });
    expect(sizes.reduce((x, y) => x + y, 0)).toBeGreaterThan(BATCH_MAX_BYTES);
    expect(cut).toBeGreaterThan(0);
  });

  it("the raw response is one JSON object with results keyed by the requested path", async () => {
    const res = await (exports as any).default.fetch(new Request("https://deadball.test/v1" + q(["/clock"])));
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("application/json");
    const j = await res.json();
    expect(j.results["/clock"].body.nextDayIn).toBeTypeOf("number");
  });
});
