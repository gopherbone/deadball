import { describe, expect, it } from "vitest";
import { env } from "cloudflare:workers";
import { runInDurableObject } from "cloudflare:test";
import type { League } from "../src/league.ts";
import { api, register, advance } from "./helpers.ts";

const E = env as unknown as { LEAGUE: DurableObjectNamespace };
const inLeague = <R>(fn: (L: League) => R | Promise<R>) => runInDurableObject(E.LEAGUE.get(E.LEAGUE.idFromName("league")), (L: League) => fn(L));
/** What the DO does when it wakes up after being evicted. */
const reboot = (L: League) => (L as unknown as { boot(): Promise<void> }).boot();
const sql1 = <T>(L: League, q: string, ...args: unknown[]) => (L as unknown as { ctx: DurableObjectState }).ctx.storage.sql.exec(q, ...args).toArray()[0] as T;
const seasonsIn = (L: League) => new Set(Object.values(L.world.stats).flatMap(by => Object.keys(by).map(Number)));

describe("world.stats per season", () => {
  it("keeps the current season hot, freezes older seasons, reads them on demand, and migrates the old layout", { timeout: 300_000 }, async () => {
    const a = await register("Stat Sheet Sam");
    await api("POST", "/packs/buy", { kind: "starter" }, a.token);
    const sizes: { season: number; worldBytes: number; statsBytes: number }[] = [];
    let season = 1;
    for (let i = 0; i < 40 && season < 3; i++) {
      expect((await advance(20)).status).toBe(200);
      const now = (await api("GET", "/clock")).body.season as number;
      if (now !== season) {
        season = now;
        sizes.push(await inLeague(L => ({
          season,
          worldBytes: sql1<{ b: number }>(L, "SELECT SUM(LENGTH(v)) AS b FROM blob WHERE ns = 'world'").b,
          statsBytes: sql1<{ b: number }>(L, "SELECT SUM(LENGTH(v)) AS b FROM stats").b,
        })));
      }
    }
    expect(season).toBe(3);

    // --- storage layout: one row per (season, person), nothing in the world blob
    const snap = await inLeague(L => {
      const info = L.stats.info();
      expect(info.hotSeason).toBe(3);
      expect(info.seasons.map(s => s.season)).toEqual([1, 2, 3]);
      for (const s of info.seasons.slice(0, 2)) {
        expect(s.rows).toBeGreaterThan(500); // every level's players, a full season each
        expect(s.bytes / s.rows).toBeLessThan(2000);
      }
      expect(sql1<{ n: number }>(L, "SELECT COUNT(*) AS n FROM blob WHERE ns = 'world' AND (k LIKE 'r:stats:%' OR k = 'm:stats')").n).toBe(0);
      expect(sql1<{ v: string }>(L, "SELECT v FROM blob WHERE ns = 'world' AND k = '$'").v).not.toContain('"stats"');
      L.ensureStats();
      return JSON.parse(JSON.stringify(L.world.stats)) as Record<string, Record<string, unknown>>;
    });
    // sizes at each season's start: a finished season adds its rows to `stats`, not to the world blob
    const [s2, s3] = sizes;
    console.log("sizes at season start (bytes):", JSON.stringify(sizes));
    expect(s3.statsBytes).toBeGreaterThan(s2.statsBytes * 1.6);
    expect(s3.statsBytes - s2.statsBytes).toBeGreaterThan(200_000);
    expect(s3.worldBytes).toBeLessThan(4_000_000);

    // a veteran with lines in both finished seasons
    const vet = Object.keys(snap).find(id => snap[id]["1"] && snap[id]["2"] && (snap[id]["1"] as { level: string }).level === "ML")!;
    expect(vet).toBeTruthy();

    // --- after an eviction only the hot season is in memory
    await inLeague(async L => {
      await reboot(L);
      expect([...seasonsIn(L)]).toEqual([3]);
      expect(L.stats.archiveLoaded).toBe(false);
      // straight from storage, without loading anything into the world
      const p = L.stats.personSeasons(L.world, vet);
      expect(p[1]).toEqual(snap[vet]["1"]);
      expect(p[2]).toEqual(snap[vet]["2"]);
      expect([...seasonsIn(L)]).toEqual([3]);
    });

    // person pages read one person's old seasons on demand
    const page = await api("GET", `/people/${vet}`, undefined, a.token);
    expect(page.status).toBe(200);
    expect(page.body.stats.map((s: { season: number }) => s.season)).toEqual(expect.arrayContaining([1, 2]));
    await inLeague(L => {
      expect(L.stats.archiveLoaded).toBe(false);
      expect(Object.keys(L.world.stats[vet]).map(Number).sort()).toEqual(Object.keys(snap[vet]).map(Number).sort());
    });

    // card backs (any season) load the whole archive, and it matches what was there before the eviction
    expect((await api("GET", "/cards", undefined, a.token)).status).toBe(200);
    await inLeague(L => {
      expect(L.stats.archiveLoaded).toBe(true);
      const now = JSON.parse(JSON.stringify(L.world.stats)) as Record<string, Record<string, unknown>>;
      for (const id of Object.keys(snap)) for (const s of ["1", "2"]) expect(now[id]?.[s]).toEqual(snap[id][s]);
    });

    // a day tick writes only the hot season (frozen seasons are never rewritten)
    const frozen = await inLeague(L => sql1<{ n: number; b: number }>(L, "SELECT COUNT(*) AS n, SUM(LENGTH(v)) AS b FROM stats WHERE season < 3"));
    await advance(2);
    await inLeague(async L => {
      // the next first pitch (with the day's farm games) saves box scores; the day's close saves none
      await L.pitch(L.timesFor(L.state.day).order.slice(0, 1));
      const after = sql1<{ n: number; b: number }>(L, "SELECT COUNT(*) AS n, SUM(LENGTH(v)) AS b FROM stats WHERE season < 3");
      expect(after.n).toBeLessThanOrEqual(frozen.n); // only deletions (forgotten minor-leaguers) can touch them
      expect(after.b).toBeLessThanOrEqual(frozen.b);
      expect(L.stats.lastSave.seasons).toEqual([3]);
      expect(L.stats.lastSave.written).toBeGreaterThan(100); // today's box scores
      expect(L.stats.lastSave.written).toBeLessThanOrEqual(sql1<{ n: number }>(L, "SELECT COUNT(*) AS n FROM stats WHERE season = 3").n);

      // --- migration: a world saved the old way (stats inside the blob) moves them out on boot
      L.ensureStats();
      const full = JSON.parse(JSON.stringify(L.world.stats));
      L.store.save("world", L.world); // the old saveWorld
      L.stats.clear();
      expect(sql1<{ n: number }>(L, "SELECT COUNT(*) AS n FROM blob WHERE ns = 'world' AND k LIKE 'r:stats:%'").n).toBeGreaterThan(500);
      await reboot(L);
      expect(sql1<{ n: number }>(L, "SELECT COUNT(*) AS n FROM blob WHERE ns = 'world' AND k LIKE 'r:stats:%'").n).toBe(0);
      expect(L.stats.info().seasons.map(s => s.season)).toEqual([1, 2, 3]);
      expect(JSON.parse(JSON.stringify(L.world.stats))).toEqual(full);
      await reboot(L);
      expect([...seasonsIn(L)]).toEqual([3]);
      L.ensureStats();
      expect(JSON.parse(JSON.stringify(L.world.stats))).toEqual(full);
    });
  });
});
