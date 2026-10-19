// Staggered first pitches (src/schedule.ts): every aired game has its own first pitch, betting
// closes per game, each pool settles when its own broadcast ends, nothing about a game is
// published before it leaves the air, something is always on the air, and the day still turns
// over (playoffs included) when the alarm drives it one first pitch at a time.

import { describe, expect, it } from "vitest";
import { env } from "cloudflare:workers";
import { runInDurableObject } from "cloudflare:test";
import { pubGameId, type GameRow, type League } from "../src/league.ts";
import { aired, airOrder, dayTimes, type DayTiming } from "../src/schedule.ts";
import { sim, type ScheduledGame } from "../src/sim.ts";
import { api, register, advance } from "./helpers.ts";

const E = env as unknown as { LEAGUE: DurableObjectNamespace; DB: D1Database };
const DB = E.DB;
const inLeague = <R>(fn: (L: League) => R | Promise<R>) => runInDurableObject(E.LEAGUE.get(E.LEAGUE.idFromName("league")), (L: League) => fn(L));
const reboot = (L: League) => (L as unknown as { boot(): Promise<void> }).boot();

/** The day being played: its aired games' ids, first pitches and air times (offsets from its start). */
const today = () => inLeague(L => {
  const t = L.timesFor(L.state.day);
  return {
    day: L.state.day, season: L.state.season, start: L.clock.curDayStart, closeAt: t.closeAt - L.clock.curDayStart, preMs: L.preMs, dayMs: L.dayMs,
    games: t.order.map(g => ({ id: pubGameId(L.state.season, g.id), level: g.level, at: t.pitches.get(g.id)!.at - L.clock.curDayStart, air: t.pitches.get(g.id)!.air })),
  };
});

/** Wind the clock so `elapsed` ms of the day being played have passed, then run whatever is due (what the alarm does). */
const runAt = (elapsed: number) => inLeague(async L => {
  const start = L.clock.curDayStart = Date.now() - elapsed;
  await L.retimeUpcoming();
  await L.tick(Date.now());
  return start;
});

const row = async (id: string) => (await DB.prepare("SELECT * FROM games WHERE id = ?").bind(id).first<GameRow>())!;

/** Fraction of [from, to) covered by at least one [at, at + air) interval, at 1 s resolution. */
function coverage(spans: { at: number; air: number }[], from: number, to: number) {
  let on = 0, n = 0;
  for (let t = from; t < to; t += 1000, n++) if (spans.some(s => t >= s.at && t < s.at + s.air)) on++;
  return on / n;
}

describe("staggered first pitches", () => {
  it("gives every aired game its own first pitch, ML and EL rotated, spread over the day", async () => {
    await advance(1);
    const d = await today();
    expect(d.games.length).toBeGreaterThanOrEqual(6);
    const ats = d.games.map(g => g.at);
    expect(new Set(ats).size).toBe(ats.length);
    expect([...ats].sort((a, b) => a - b)).toEqual(ats);
    expect(ats[0]).toBe(d.preMs);
    expect(ats[ats.length - 1]).toBeLessThan(d.dayMs);
    // an even cadence: (dayMs - preMs) / n apart, give or take rounding
    const s = (d.dayMs - d.preMs) / ats.length;
    for (let i = 1; i < ats.length; i++) expect(Math.abs(ats[i] - ats[i - 1] - s)).toBeLessThanOrEqual(1);
    // the Enhanced League's games aren't bunched at the end: one in each third of the day
    const el = d.games.map((g, i) => (g.level === "EL" ? i / d.games.length : -1)).filter(x => x >= 0);
    if (el.length >= 3) expect(el.map(x => Math.floor(x * 3))).toEqual([0, 1, 2]);

    // the API and the stored rows agree: firstPitchAt/finalAt (and their *In twins), status
    const a = await register("Clock Watcher");
    const slate = (await api("GET", "/today", undefined, a.token)).body;
    const mine = slate.games.filter((g: { day: number }) => g.day === d.day);
    expect(mine.map((g: { id: string }) => g.id).sort()).toEqual(d.games.map(g => g.id).sort());
    for (const g of mine) {
      const want = d.games.find(x => x.id === g.id)!;
      expect(g.firstPitchAt).toBe(d.start + want.at);
      expect(g.finalAt).toBe(g.firstPitchAt + want.air);
      expect(typeof g.firstPitchIn).toBe("number");
      expect(typeof g.finalIn).toBe("number");
      expect(g.status).toBe("scheduled");
      expect((await row(g.id)).first_pitch_at).toBe(g.firstPitchAt);
    }
    // /clock: the next lock, and nothing on the air yet
    const clock = (await api("GET", "/clock")).body;
    expect(clock).toMatchObject({ nextPitchAt: d.start + d.games[0].at, nextGame: { id: d.games[0].id }, onAir: 0, nextDayAt: d.start + d.dayMs });
  });

  it("closes betting per game: later games stay open after the first one pitches", async () => {
    await advance(1);
    const a = await register("Late Bettor");
    const d = await today();
    const [g0, g1] = d.games;
    await runAt(g0.at + 1000);
    expect((await row(g0.id)).simmed).toBe(1);
    expect((await row(g1.id)).simmed).toBe(0);
    const slate = (await api("GET", "/today", undefined, a.token)).body.games;
    expect(slate.find((g: { id: string }) => g.id === g0.id).status).toBe("live");
    expect(slate.find((g: { id: string }) => g.id === g1.id).status).toBe("scheduled");
    const late = await api("POST", "/bets", { gameId: g0.id, side: "home", amount: 10 }, a.token);
    expect(late.status).toBe(409);
    expect(late.body.error).toBe("window_closed");
    expect((await api("POST", "/bets", { gameId: g1.id, side: "home", amount: 10 }, a.token)).status).toBe(200);
    const clock = (await api("GET", "/clock")).body;
    expect(clock.nextGame.id).toBe(g1.id);
    expect(clock.onAir).toBe(1);
  });

  it("settles each pool when its own broadcast ends, and publishes nothing about a game before then", async () => {
    await advance(1);
    const a = await register("Early Bird");
    const b = await register("Night Owl");
    const d = await today();
    const [g0, g1] = d.games;
    for (const g of [g0, g1]) {
      expect((await api("POST", "/bets", { gameId: g.id, side: "home", amount: 50 }, a.token)).status).toBe(200);
      expect((await api("POST", "/bets", { gameId: g.id, side: "away", amount: 50 }, b.token)).status).toBe(200);
    }
    // a few seconds after g0 leaves the air: g1 (one gap later) is still on
    await runAt(g0.at + g0.air + 3000);
    const r0 = await row(g0.id), r1 = await row(g1.id);
    expect(r0).toMatchObject({ simmed: 1, settled: 1 });
    expect(r1).toMatchObject({ simmed: 1, settled: 0 });
    expect(r1.first_pitch_at + r1.air_ms).toBeGreaterThan(Date.now());
    const settled = (await api("GET", "/bets?status=settled", undefined, a.token)).body.bets;
    expect(settled.map((x: { gameId: string }) => x.gameId)).toEqual([g0.id]);
    const open = (await api("GET", "/bets?status=open", undefined, a.token)).body.bets;
    expect(open.map((x: { gameId: string }) => x.gameId)).toEqual([g1.id]);

    // g0's recap is out, g1's isn't (stamped with its own final)
    expect(r0.story_id && r1.story_id).toBeTruthy();
    expect((await api("GET", `/news/${r0.story_id}`, undefined, a.token)).status).toBe(200);
    expect((await api("GET", `/news/${r1.story_id}`, undefined, a.token)).status).toBe(404);
    const s1 = (await DB.prepare("SELECT publish_at FROM stories WHERE id = ?").bind(r1.story_id).first<{ publish_at: number }>())!;
    expect(s1.publish_at).toBe(r1.first_pitch_at + r1.air_ms);
    // the bank only writes about g0
    const mail = (await api("GET", "/mail", undefined, a.token)).body.mail as { subject: string; body?: string[] }[];
    expect(mail.filter(m => m.subject && /won|refunded|Tough luck/.test(m.subject))).toHaveLength(1);

    // nothing on /news is from the future, and the closed day's life news waits for its last broadcast
    const news = (await api("GET", "/news?limit=50", undefined, a.token)).body.stories as { at: number }[];
    expect(news.every(s => s.at <= Date.now())).toBe(true);
    const closed = await inLeague(L => L.state.day !== d.day);
    if (closed) {
      const lastEnd = Math.max(...await Promise.all(d.games.map(async g => { const r = await row(g.id); return r.first_pitch_at + r.air_ms; })));
      const life = (await DB.prepare("SELECT publish_at FROM stories WHERE season = ? AND game_id IS NULL AND kind IN ('life', 'trade') AND publish_at > ?").bind(d.season, Date.now()).all<{ publish_at: number }>()).results;
      for (const s of life) expect(s.publish_at).toBe(lastEnd);
      expect(await inLeague(L => L.clock.finalAt)).toBe(lastEnd);
    }

    // once everything has aired: every pool on the day settles
    await inLeague(L => L.settleGames(Math.max(...d.games.map(g => d.start + g.at + g.air)) + 60_000));
    for (const g of d.games) expect((await row(g.id)).settled).toBe(1);
    expect((await api("GET", "/bets?status=settled", undefined, b.token)).body.bets).toHaveLength(2);
  });

  it("keeps a bettable game on the air at almost every moment, across day boundaries", async () => {
    await advance(1);
    // the real slate, three days running (day boundaries included)
    const spans = await inLeague(L => [0, 1, 2].flatMap(k => {
      const t = L.timesFor(L.state.day + k);
      return t.order.map(g => t.pitches.get(g.id)!);
    }));
    const t0 = await inLeague(L => L.clock.curDayStart + L.preMs);
    const dayMs = await inLeague(L => L.dayMs);
    expect(coverage(spans, t0, t0 + 2 * dayMs)).toBeGreaterThanOrEqual(0.95);
    expect(coverage(spans, t0, t0 + 2 * dayMs)).toBe(1);

    // production timing (30 min days) with playoff-sized slates: 1, 2, 3 and 5 games a day
    const T: DayTiming = { dayMs: 1_800_000, preMs: 450_000, airMs: 1_260_000 };
    const fake = (n: number, day: number): ScheduledGame[] => Array.from({ length: n }, (_, i) => ({
      id: `D${day}G${i}`, season: 1, day, level: i % 2 ? "EL" : "ML", homeId: "h", awayId: "a", umpireId: "u", weather: {} as ScheduledGame["weather"], slot: i,
    }));
    for (const counts of [[11, 11, 11], [1, 1, 1], [2, 1, 3], [5, 2, 11], [11, 1, 2]]) {
      const all = counts.flatMap((n, day) => [...dayTimes(fake(n, day), day * T.dayMs, T).pitches.values()]);
      expect(coverage(all, T.preMs, 2 * T.dayMs + T.preMs)).toBeGreaterThanOrEqual(0.95);
    }
    // every slate's aired games get a slot; farm games share the first pitch and air normally
    const mixed = [...fake(3, 0), { ...fake(1, 0)[0], id: "farm", level: "AA" as ScheduledGame["level"] }];
    const t = dayTimes(mixed, 0, T);
    expect(airOrder(mixed).map(g => g.id)).toEqual(["D0G0", "D0G1", "D0G2"]);
    expect(t.pitches.get("farm")).toEqual({ at: T.preMs, air: T.airMs });
    expect(aired(mixed[3])).toBe(false);
  });

  it("converts a running pre-stagger clock: the first game keeps the old first pitch, later ones follow", async () => {
    await advance(1);
    for (const next of ["play", "final"] as const) {
      const out = await inLeague(async L => {
        const now = Date.now();
        const playAt = next === "play" ? now + 60_000 : now - 60_000;
        L.store.setMeta("clock", { curDay: L.state.day - 1, curDayStart: playAt - L.preMs, next, playAt, finalAt: playAt + L.airMs, offDays: 0 });
        await reboot(L);
        const t = L.timesFor(L.state.day);
        return { playAt, dayMs: L.dayMs, airMs: L.airMs, clock: L.clock, first: pubGameId(L.state.season, t.order[0].id), second: pubGameId(L.state.season, t.order[1].id) };
      });
      const sharedNext = next === "play" ? out.playAt : out.playAt + out.dayMs;
      expect(out.clock.v).toBe(2);
      expect((await row(out.first)).first_pitch_at).toBe(sharedNext);
      expect((await row(out.second)).first_pitch_at).toBeGreaterThan(sharedNext);
      expect(out.clock.finalAt).toBe(next === "final" ? out.playAt + out.airMs : 0);
    }
  });

  it("turns the day over one first pitch at a time, through the playoffs", { timeout: 300_000 }, async () => {
    // to the playoffs by fast-forward
    for (let i = 0; i < 40 && ["preseason", "regular"].includes(await inLeague(L => L.state.phase)); i++) {
      const day = await inLeague(L => L.state.day);
      await advance(Math.max(1, Math.min(20, 154 - day)));
    }
    expect(await inLeague(L => L.state.phase)).toBe("playoffs");
    const phases: number[] = [];
    for (let k = 0; k < 4 && (await inLeague(L => L.state.phase)) === "playoffs"; k++) {
      const d = await today();
      if (!d.games.length) { await advance(1); continue; }
      // halfway through the slate: the first games played, the day not closed
      if (d.games.length > 2) {
        await runAt(d.games[1].at + 500);
        const mid = await inLeague(L => ({ day: L.state.day, simmed: sim.slateFor(L.state, d.day).filter(g => aired(g) && L.state.results[g.id]).length }));
        expect(mid).toEqual({ day: d.day, simmed: 2 });
      }
      phases.push(d.games.length);
      // just after the last first pitch: every game played, the day closed, tomorrow's games on the board
      const start = await runAt(d.closeAt + 500);
      const after = await inLeague(L => ({
        day: L.state.day, phase: L.state.phase, left: sim.slateFor(L.state, d.day).filter(g => !L.state.results[g.id]).length,
        nextStart: L.clock.curDayStart, next: L.timesFor(L.state.day).order.map(g => pubGameId(L.state.season, g.id)),
      }));
      expect(after.day).toBe(d.day + 1);
      expect(after.left).toBe(0);
      expect(after.nextStart).toBe(start + d.dayMs);
      if (after.phase === "playoffs" && after.next.length) {
        // tomorrow's (playoff) games exist with a betting window of at least preMs + one gap
        const r = await row(after.next[0]);
        expect(r.simmed).toBe(0);
        expect(r.first_pitch_at - (start + d.closeAt)).toBeGreaterThanOrEqual(d.preMs);
      }
    }
    expect(phases.length).toBeGreaterThan(0);
    // and on to the offseason and a new season by fast-forward
    for (let i = 0; i < 6 && (await inLeague(L => L.state.season)) === 1; i++) await advance(10);
    expect(await inLeague(L => L.state.season)).toBe(2);
    expect((await api("GET", "/clock")).body.season).toBe(2);
  });
});
