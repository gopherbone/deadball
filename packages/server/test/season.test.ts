import { describe, expect, it } from "vitest";
import { api, register, advance } from "./helpers.ts";

describe("a whole season", () => {
  it("plays through playoffs and the offseason into season 2", { timeout: 300_000 }, async () => {
    const a = await register("Season Ticket");
    await api("POST", "/packs/buy", { kind: "starter" }, a.token);
    let clock = (await api("GET", "/clock")).body;
    expect(clock.season).toBe(1);
    const phases = new Set<string>();
    for (let i = 0; i < 12 && clock.season === 1; i++) {
      const r = await advance(20);
      expect(r.status).toBe(200);
      clock = (await api("GET", "/clock")).body;
      phases.add(clock.phase);
    }
    expect(clock.season).toBe(2);
    expect(phases.has("offseason") || phases.has("playoffs")).toBe(true);
    const today = await api("GET", "/today", undefined, a.token);
    expect(today.status).toBe(200);
    // new season: fresh standings, packs from the new set, old cards still in the binder
    const st = await api("GET", "/standings?level=ML", undefined, a.token);
    expect(st.body.rows.every((r: { w: number; l: number }) => r.w + r.l < 30)).toBe(true);
    const pack = await api("POST", "/packs/buy", { kind: (await api("GET", "/shop", undefined, a.token)).body.packs[0].kind }, a.token);
    expect(pack.status).toBe(200);
    const binder = await api("GET", "/cards?limit=30", undefined, a.token);
    expect(new Set(binder.body.cards.map((c: { season: number }) => c.season)).size).toBe(2);
    const news = await api("GET", "/news", undefined, a.token);
    expect(news.body.stories.length).toBeGreaterThan(0);
  });
});
