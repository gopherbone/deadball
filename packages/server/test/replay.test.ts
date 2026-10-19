import { describe, expect, it } from "vitest";
import { env } from "cloudflare:workers";
import { api, register, advance } from "./helpers.ts";
import { explode, implode } from "../src/store.ts";

const DB = (env as unknown as { DB: D1Database }).DB;

describe("live broadcast", () => {
  it("only reveals the log, score and incidents aired so far", async () => {
    const a = await register("Couch Potato");
    const g = (await api("GET", "/today", undefined, a.token)).body.games[0];
    await advance(1);
    const full = await api("GET", `/games/${g.id}/log`, undefined, a.token);
    let all = full.body.log;
    let next = full.body.next;
    while (next !== undefined) {
      const p = await api("GET", `/games/${g.id}/log?from=${next}`, undefined, a.token);
      all = all.concat(p.body.log);
      next = p.body.next;
    }
    expect(all[all.length - 1].k).toBe("end");
    const pitches = all.filter((e: { k: string }) => e.k === "p").length;

    // put the game half-way through its broadcast
    const row = await DB.prepare("SELECT air_ms FROM games WHERE id = ?").bind(g.id).first<{ air_ms: number }>();
    await DB.prepare("UPDATE games SET first_pitch_at = ? WHERE id = ?").bind(Date.now() - row!.air_ms / 2, g.id).run();
    const live = await api("GET", `/games/${g.id}`, undefined, a.token);
    expect(live.body.status).toBe("live");
    expect(live.body.box).toBeUndefined();
    expect(live.body.decisions).toBeUndefined();
    expect(live.body.score.inning).toMatch(/^(TOP|BOT) \d+$/);
    const llog = await api("GET", `/games/${g.id}/log?from=0`, undefined, a.token);
    let partial = llog.body.log;
    let n2 = llog.body.next;
    while (n2 !== undefined) {
      const p = await api("GET", `/games/${g.id}/log?from=${n2}`, undefined, a.token);
      partial = partial.concat(p.body.log);
      n2 = p.body.next;
    }
    const aired = partial.filter((e: { k: string }) => e.k === "p").length;
    expect(aired).toBeGreaterThan(pitches * 0.4);
    expect(aired).toBeLessThan(pitches * 0.6);
    expect(partial.some((e: { k: string }) => e.k === "end")).toBe(false);
    expect(partial).toEqual(all.slice(0, partial.length));
    const wire = await api("GET", `/games/${g.id}/wire`, undefined, a.token);
    expect(wire.body.lines.every((l: { i: number }) => l.i < partial.length)).toBe(true);
    const today = await api("GET", "/today", undefined, a.token);
    void today;

    // not started yet: no log at all
    await DB.prepare("UPDATE games SET first_pitch_at = ? WHERE id = ?").bind(Date.now() + 60_000, g.id).run();
    const pre = await api("GET", `/games/${g.id}/log`, undefined, a.token);
    expect(pre.body.log).toEqual([]);
  });

  it("farm games have box scores but no replay", async () => {
    const a = await register("Bush Leaguer");
    await advance(1);
    const r = await DB.prepare("SELECT id FROM games WHERE level = 'AA' AND simmed = 1 LIMIT 1").first<{ id: string }>();
    const d = await api("GET", `/games/${r!.id}`, undefined, a.token);
    expect(d.body.box.home.bat.length).toBeGreaterThan(0);
    expect((await api("GET", `/games/${r!.id}/log`, undefined, a.token)).status).toBe(404);
  });
});

describe("world store", () => {
  it("round-trips records, chunked arrays and root fields", () => {
    const obj = {
      season: 3, name: "x", small: { a: { v: 1 } },
      big: Object.fromEntries(Array.from({ length: 40 }, (_, i) => [`p${i}`, { i, tags: ["a"] }])),
      list: Array.from({ length: 1000 }, (_, i) => ({ i })),
      short: [1, 2, 3],
    };
    const rows = explode(obj);
    expect(rows.has("r:big:p7")).toBe(true);
    expect(rows.has("a:list:3")).toBe(true);
    expect(implode(rows)).toEqual(obj);
  });
});

describe("durable object restart", () => {
  it("reloads the same world and season from storage", async () => {
    const { evictAllDurableObjects } = await import("cloudflare:test");
    const a = await register("Ghost Writer");
    await advance(3);
    const st1 = await api("GET", "/standings?level=ML", undefined, a.token);
    const team1 = await api("GET", "/teams/HCL", undefined, a.token);
    const status1 = await api("GET", "/admin/status", undefined, undefined, true);
    await evictAllDurableObjects();
    const st2 = await api("GET", "/standings?level=ML", undefined, a.token);
    const team2 = await api("GET", "/teams/HCL", undefined, a.token);
    const status2 = await api("GET", "/admin/status", undefined, undefined, true);
    expect(st2.body).toEqual(st1.body);
    expect(team2.body).toEqual(team1.body);
    expect(status2.body.day).toBe(status1.body.day);
    expect(status2.body.clock).toEqual(status1.body.clock);
    // and keeps playing
    expect((await advance(1)).status).toBe(200);
  });
});
