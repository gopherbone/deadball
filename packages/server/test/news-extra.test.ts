import { describe, expect, it } from "vitest";
import { env } from "cloudflare:workers";
import { api, register } from "./helpers.ts";

const DB = (env as unknown as { DB: D1Database }).DB;

describe("GET /news: EXTRA! stories", () => {
  it("flags the most prominent stories as extra", async () => {
    const a = await register("Extra Ed");
    const story = (id: string, headline: string, prominence: number) =>
      DB.prepare("INSERT INTO stories (id, season, day, kind, headline, publish_at, game_id, data, prominence) VALUES (?,?,?,?,?,?,?,?,?)")
        .bind(id, 1, 1, "feature", headline, Date.now() - 1000, null, JSON.stringify({ id, day: 1, kind: "feature", headline, dek: "d", body: [], faceIds: [], people: [], teams: [] }), prominence).run();
    await story("x-big", "Shortstop Abducted From On-Deck Circle", 6.2);
    await story("x-small", "Pitcher Buys a Boat", 1);
    const news = (await api("GET", "/news", undefined, a.token)).body.stories;
    const big = news.find((s: { id: string }) => s.id === "x-big");
    const small = news.find((s: { id: string }) => s.id === "x-small");
    expect(big.extra).toBe(true);
    expect(small.extra).toBeUndefined();
  });
});
