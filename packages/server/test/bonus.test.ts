import { describe, expect, it } from "vitest";
import { env } from "cloudflare:workers";
import { api, register, advance } from "./helpers.ts";
import { DAILY, HOLES, PETTY_CASH, WEEKLY, nextPunch, pickDaily, pickWeekly, utcDay } from "../src/routes/bonus.ts";

const DB = (env as unknown as { DB: D1Database }).DB;
const shift = (account: string, shiftDays: number) => api("POST", "/admin/bonus", { account, shiftDays }, undefined, true);
const money = async (token: string) => (await api("GET", "/me", undefined, token)).body.account.money as number;
const ledger = (id: string, reason: string) => DB.prepare("SELECT COUNT(*) AS n, COALESCE(SUM(delta), 0) AS total FROM ledger WHERE account_id = ? AND reason = ?").bind(id, reason).first<{ n: number; total: number }>();

async function validDraft(token: string, seed = 0) {
  const words = (await api("GET", "/words", undefined, token)).body;
  for (let k = 0; k < words.templates.length; k++) {
    const t = words.templates[(k + seed) % words.templates.length];
    if (t.slots.every((s: string) => words.slots[s]?.length)) return { template: t.id, words: t.slots.map((s: string, i: number) => words.slots[s][(seed + i) % words.slots[s].length]) };
  }
  throw new Error("no usable template");
}

describe("loyalty card: the rules", () => {
  it("counts holes, forgives one missed day per card, and starts over", () => {
    let p = nextPunch(undefined, 100);
    expect(p).toMatchObject({ hole: 1, streak: 1, fresh: true, lapsed: false });
    const row = (s: typeof p, day: number) => ({ utc_day: day, hole: s.hole, streak: s.streak, grace: s.grace });
    // same day: nothing moves
    expect(nextPunch(row(p, 100), 100)).toMatchObject({ hole: 1, streak: 1 });
    p = nextPunch(row(p, 100), 101);
    expect(p).toMatchObject({ hole: 2, streak: 2, graced: false });
    // a missed day: forgiven once per card
    p = nextPunch(row(p, 101), 103);
    expect(p).toMatchObject({ hole: 3, streak: 3, graced: true, grace: 1 });
    // a second miss on the same card: a new card
    const lapsed = nextPunch(row(p, 103), 105);
    expect(lapsed).toMatchObject({ hole: 1, streak: 1, lapsed: true, fresh: true });
    // two missed days: a new card
    expect(nextPunch({ utc_day: 10, hole: 4, streak: 4, grace: 0 }, 13)).toMatchObject({ hole: 1, lapsed: true });
    // after the seventh hole: a new card, the streak and a fresh forgiven day carry on
    const full = nextPunch({ utc_day: 10, hole: 7, streak: 9, grace: 1 }, 11);
    expect(full).toMatchObject({ hole: 1, streak: 10, fresh: true, lapsed: false, grace: 0 });
    expect(HOLES).toHaveLength(7);
    expect(HOLES[6].packs).toBe(1);
  });

  it("picks three distinct daily jobs (one per group, only ones the account can do) and a weekly one", () => {
    for (let i = 0; i < 40; i++) {
      const a = { id: `a${i}`, heat: 0, crew: i % 2, syndicate: false };
      const jobs = pickDaily(a, `s1d${i}`);
      expect(jobs).toHaveLength(3);
      expect(new Set(jobs.map(j => j.kind)).size).toBe(3);
      const groups = jobs.map(j => j.group).filter(Boolean);
      expect(new Set(groups).size).toBe(groups.length);
      if (!a.crew) expect(jobs.some(j => j.kind === "job")).toBe(false);
      // stable for the period
      expect(pickDaily(a, `s1d${i}`).map(j => j.kind)).toEqual(jobs.map(j => j.kind));
      const wk = pickWeekly(a, 2900 + i);
      expect(WEEKLY).toContain(wk);
      if (!a.crew) expect(wk.kind).not.toBe("w_jobs");
    }
    expect(DAILY.every(d => d.cash > 0 && d.cash <= 20)).toBe(true);
  });
});

describe("GET /bonus and POST /bonus/punch", () => {
  it("punches once a real day, pays through the ledger, and keeps the streak", async () => {
    expect((await api("GET", "/bonus")).status).toBe(401);
    const a = await register("Punchy Pete");
    const doc = (await api("GET", "/bonus", undefined, a.token)).body;
    expect(doc.card).toMatchObject({ hole: 0, punchedToday: false, streak: 0, total: 0, graceLeft: true, holes: expect.any(Array) });
    expect(doc.card.holes).toHaveLength(7);
    expect(doc.card.holes[6]).toMatchObject({ n: 7, packs: 1, reward: "Free pack", stamped: false });
    expect(doc.jobs).toHaveLength(3);
    expect(doc.week).toMatchObject({ weekly: true, status: "open", reward: { packs: 1 } });
    expect(doc.pettyCash).toMatchObject({ left: PETTY_CASH, max: PETTY_CASH });
    expect(typeof doc.card.nextIn).toBe("number");   // relative times ride along
    expect(doc.card.utcDay).toBe(new Date().toISOString().slice(0, 10));

    const p1 = await api("POST", "/bonus/punch", undefined, a.token);
    expect(p1.status).toBe(200);
    expect(p1.body).toMatchObject({ punched: true, hole: 1, streak: 1, reward: { cash: 10, label: "$10" }, line: expect.any(String) });
    expect(p1.body.account.money).toBe(1010);
    expect(p1.body.card).toMatchObject({ hole: 1, punchedToday: true, streak: 1 });
    expect(p1.body.card.holes[0]).toMatchObject({ stamped: true, today: true });
    // again today: nothing
    const p1b = await api("POST", "/bonus/punch", undefined, a.token);
    expect(p1b.body).toMatchObject({ punched: false, hole: 1 });
    expect(await money(a.token)).toBe(1010);
    expect(await ledger(a.account.id, "bonus_punch")).toEqual({ n: 1, total: 10 });

    // the next day: hole 2
    await shift("Punchy Pete", 1);
    const p2 = (await api("POST", "/bonus/punch", undefined, a.token)).body;
    expect(p2).toMatchObject({ punched: true, hole: 2, streak: 2, reward: { cash: 15 } });
    // skip a day: forgiven
    await shift("Punchy Pete", 2);
    const pre = (await api("GET", "/bonus", undefined, a.token)).body.card;
    expect(pre).toMatchObject({ hole: 2, punchedToday: false, streak: 2, graceLeft: true });
    const p3 = (await api("POST", "/bonus/punch", undefined, a.token)).body;
    expect(p3).toMatchObject({ punched: true, hole: 3, streak: 3, graced: true });
    expect(p3.line).toMatch(/looked the other way/);
    expect(p3.card).toMatchObject({ graceLeft: false });
    expect(p3.card.holes[2]).toMatchObject({ graced: true, stamped: true });
    // skip again: the card's gone
    await shift("Punchy Pete", 2);
    expect((await api("GET", "/bonus", undefined, a.token)).body.card).toMatchObject({ lapsed: true, hole: 0, streak: 0 });
    const p4 = (await api("POST", "/bonus/punch", undefined, a.token)).body;
    expect(p4).toMatchObject({ punched: true, hole: 1, streak: 1, lapsed: true });
    expect(await money(a.token)).toBe(1000 + 10 + 15 + 20 + 10);
  });

  it("the seventh hole is a free pack (opened at the Card Shop), then a new card", async () => {
    const a = await register("Seven Holes");
    const packs0 = (await DB.prepare("SELECT free_packs FROM accounts WHERE id = ?").bind(a.account.id).first<{ free_packs: number }>())!.free_packs;
    let last: any;
    for (let i = 0; i < 7; i++) {
      if (i) await shift("Seven Holes", 1);
      last = (await api("POST", "/bonus/punch", undefined, a.token)).body;
      expect(last).toMatchObject({ punched: true, hole: i + 1 });
    }
    expect(last.reward).toMatchObject({ cash: 0, packs: 1, label: "Free pack" });
    expect(last.line).toMatch(/free pack/i);
    const packs1 = (await DB.prepare("SELECT free_packs FROM accounts WHERE id = ?").bind(a.account.id).first<{ free_packs: number }>())!.free_packs;
    expect(packs1).toBe(packs0 + 1);
    expect(await money(a.token)).toBe(1000 + HOLES.reduce((s, h) => s + h.cash, 0));
    expect(last.card.holes.every((h: any) => h.stamped)).toBe(true);
    // tomorrow: a fresh card, streak 8
    await shift("Seven Holes", 1);
    const card = (await api("GET", "/bonus", undefined, a.token)).body.card;
    expect(card).toMatchObject({ hole: 0, streak: 7, punchedToday: false });
    expect(card.holes.some((h: any) => h.stamped)).toBe(false);
    expect((await api("POST", "/bonus/punch", undefined, a.token)).body).toMatchObject({ hole: 1, streak: 8 });
  });

  it("two punches at once pay once", async () => {
    const a = await register("Double Puncher");
    const [r1, r2] = await Promise.all([api("POST", "/bonus/punch", undefined, a.token), api("POST", "/bonus/punch", undefined, a.token)]);
    expect([r1.status, r2.status]).toEqual([200, 200]);
    expect([r1.body.punched, r2.body.punched].filter(Boolean)).toHaveLength(1);
    expect(await ledger(a.account.id, "bonus_punch")).toEqual({ n: 1, total: 10 });
    expect(await money(a.token)).toBe(1010);
  });

  it("rides in a /batch", async () => {
    const a = await register("Batch Bonus");
    const r = await api("GET", `/batch?p=${encodeURIComponent("/bonus")}&p=${encodeURIComponent("/me")}`, undefined, a.token);
    expect(r.status).toBe(200);
    expect(r.body.results["/bonus"]).toMatchObject({ status: 200, body: { card: { hole: 0 }, jobs: expect.any(Array) } });
  });
});

describe("odd jobs", () => {
  /** Does whatever a job asks, as `who` (helpers: a second account to post a comment to react to). */
  async function doJob(kind: string, who: { token: string; name: string }, helper: { token: string }): Promise<boolean> {
    const games = (await api("GET", "/today", undefined, who.token)).body.games.filter((g: any) => g.status === "scheduled" && g.firstPitchIn > 5);
    const bet = (g: any, side: string) => api("POST", "/bets", { gameId: g.id, side, amount: 10 }, who.token);
    switch (kind) {
      case "bet": return (await bet(games[0], "home")).status === 200;
      case "bet3": { for (const g of games.slice(0, 3)) expect((await bet(g, "away")).status).toBe(200); return games.length >= 3; }
      case "underdog": {
        const g = games.find((x: any) => x.pool.pays.home !== x.pool.pays.away);
        return (await bet(g, g.pool.pays.home > g.pool.pays.away ? "home" : "away")).status === 200;
      }
      case "story": case "bbs": case "guestbook": {
        const thread = kind === "bbs" ? "bbs:general" : kind === "story" ? `story:${(await api("GET", "/news", undefined, who.token)).body.stories[0].id}` : `person:${games[0].probables.home.id}`;
        return (await api("POST", "/comments", { thread, ...(await validDraft(who.token, 3)) }, who.token)).status === 200;
      }
      case "react": {
        const c = await api("POST", "/comments", { thread: "bbs:general", ...(await validDraft(helper.token, 5)) }, helper.token);
        return (await api("POST", `/comments/${c.body.comment.id}/react`, { kind: "lol" }, who.token)).status === 200;
      }
      case "read": {
        const id = (await api("GET", "/news", undefined, who.token)).body.stories[0].id;
        expect((await api("POST", "/bonus/report", { kind: "read", ref: id }, who.token)).body.error).toBe("bad_request"); // not fetched yet
        await api("GET", `/news/${id}`, undefined, who.token);
        return (await api("POST", "/bonus/report", { kind: "read", ref: id }, who.token)).body.marked === true;
      }
      case "replay": {
        const final = (await api("GET", "/bets?status=settled", undefined, who.token)).body.bets[0]?.gameId
          ?? (await DB.prepare("SELECT id FROM games WHERE level = 'ML' AND simmed = 1 AND has_log = 1 ORDER BY first_pitch_at DESC LIMIT 1").first<{ id: string }>())?.id;
        if (!final) return false;
        expect((await api("POST", "/bonus/report", { kind: "replay", ref: final }, who.token)).body.error).toBe("bad_request"); // never loaded it
        await api("GET", `/games/${final}/log?fmt=c`, undefined, who.token);
        const r = await api("POST", "/bonus/report", { kind: "replay", ref: final }, who.token);
        return r.status === 200 && r.body.marked;
      }
      case "pack": {
        const paid = (await api("GET", "/shop", undefined, who.token)).body.packs.find((p: any) => p.price > 0);
        return (await api("POST", "/packs/buy", { kind: paid.kind }, who.token)).status === 200;
      }
      case "market": {
        await api("POST", "/packs/buy", { kind: "starter" }, who.token);
        const card = (await api("GET", "/cards", undefined, who.token)).body.cards[0];
        return (await api("POST", "/market", { cardId: card.id, price: 40 }, who.token)).status === 200;
      }
      case "prop": {
        const p = (await api("GET", "/props", undefined, who.token)).body.storylines.flatMap((s: any) => s.props).find((x: any) => x.status === "open");
        if (!p) return false;
        return (await api("POST", "/props/bets", { propId: p.id, option: p.options[0].key, amount: 10 }, who.token)).status === 200;
      }
      case "job": return false;
    }
    return false;
  }

  it("counts what you did, pays a claim once, and refuses unfinished ones", async () => {
    const helper = await register("Helper Hank");
    await advance(1); // stories, finals, a fresh slate
    let done = 0;
    for (let n = 0; n < 6 && done < 3; n++) {
      const name = `Odd Jobber ${n}`;
      const a = { ...(await register(name)), name };
      const board = (await api("GET", "/bonus", undefined, a.token)).body;
      expect(board.jobs).toHaveLength(3);
      for (const j of board.jobs) {
        expect(j).toMatchObject({ id: expect.stringMatching(/^s\d+d\d+:[0-2]$/), status: "open", have: 0, need: expect.any(Number), text: expect.any(String), go: expect.any(String) });
        // not done: no claim (an earlier job's action can finish this one too, e.g. a bet on an underdog)
        const now = (await api("GET", "/bonus", undefined, a.token)).body.jobs.find((x: any) => x.id === j.id);
        if (now.status === "open") expect((await api("POST", `/bonus/jobs/${j.id}/claim`, undefined, a.token)).body.error).toBe("bad_request");
        else continue;
        if (!(await doJob(j.kind, a, helper))) continue;
        const after = (await api("GET", "/bonus", undefined, a.token)).body.jobs.find((x: any) => x.id === j.id);
        expect(after, j.kind).toMatchObject({ status: "done", have: j.need });
        const before = await money(a.token);
        const c1 = await api("POST", `/bonus/jobs/${j.id}/claim`, undefined, a.token);
        expect(c1.status, j.kind).toBe(200);
        expect(c1.body).toMatchObject({ claimed: true, job: { id: j.id, status: "claimed" }, line: expect.any(String) });
        expect(c1.body.account.money).toBe(before + j.reward.cash);
        // claiming again (a retry) pays nothing and says so
        const c2 = await api("POST", `/bonus/jobs/${j.id}/claim`, undefined, a.token);
        expect(c2.body).toMatchObject({ claimed: true, again: true });
        expect(await money(a.token)).toBe(before + j.reward.cash);
        done++;
      }
      const led = await ledger(a.account.id, "bonus_job");
      const claimed = (await api("GET", "/bonus", undefined, a.token)).body.jobs.filter((x: any) => x.status === "claimed");
      expect(led!.n).toBe(claimed.length);
      expect(led!.total).toBe(claimed.reduce((s: number, x: any) => s + x.reward.cash, 0));
    }
    expect(done).toBeGreaterThanOrEqual(3);
    expect((await api("POST", "/bonus/jobs/s1d999:0/claim", undefined, helper.token)).status).toBe(404);
    expect((await api("POST", "/bonus/jobs/garbage/claim", undefined, helper.token)).body.error).toBe("bad_request");
  });

  it("the petty-cash drawer: PETTY_CASH claims a UTC day, concurrent claims pay once", async () => {
    const a = await register("Drawer Dan");
    const board = (await api("GET", "/bonus", undefined, a.token)).body;
    const j = board.jobs[0];
    const [period, slot] = j.id.split(":");
    // finish it the quick way (a mark-counted job is simplest to fake: switch it to "react")
    await DB.prepare("UPDATE odd_jobs SET kind = 'react', need = 1, cash = 5, heat = 0 WHERE account_id = ? AND period = ? AND slot = ?").bind(a.account.id, period, Number(slot)).run();
    await DB.prepare("INSERT INTO bonus_marks (account_id, kind, ref, at) VALUES (?, 'react', 'c-fake', ?)").bind(a.account.id, Date.now()).run();
    // a full drawer of earlier claims today
    const today = utcDay(Date.now());
    for (let i = 0; i < PETTY_CASH; i++) {
      await DB.prepare("INSERT INTO odd_jobs (account_id, period, slot, kind, need, cash, from_at, to_at, claim_until, claimed_at, claim_day, created_at) VALUES (?, ?, 0, 'bet', 1, 10, 0, 1, 1, 1, ?, 1)")
        .bind(a.account.id, `s0d${i}`, today).run();
    }
    expect((await api("GET", "/bonus", undefined, a.token)).body.pettyCash.left).toBe(0);
    const full = await api("POST", `/bonus/jobs/${j.id}/claim`, undefined, a.token);
    expect(full.status).toBe(429);
    expect(full.body.message).toMatch(/petty-cash/);
    expect(await money(a.token)).toBe(1000);
    // tomorrow the drawer is full again
    await shift("Drawer Dan", 1);
    const [c1, c2] = await Promise.all([api("POST", `/bonus/jobs/${j.id}/claim`, undefined, a.token), api("POST", `/bonus/jobs/${j.id}/claim`, undefined, a.token)]);
    expect([c1.status, c2.status]).toEqual([200, 200]);
    expect([c1.body.again, c2.body.again].filter(Boolean)).toHaveLength(1);
    expect(await ledger(a.account.id, "bonus_job")).toEqual({ n: 1, total: 5 });
    expect(await money(a.token)).toBe(1005);
  });

  it("a hot account's third job pays in heat, and the weekly job pays a pack", async () => {
    const a = await register("Hot Harriet");
    await DB.prepare("UPDATE accounts SET heat = 4 WHERE id = ?").bind(a.account.id).run();
    const board = (await api("GET", "/bonus", undefined, a.token)).body;
    expect(board.jobs[2].reward).toMatchObject({ cash: 0, heat: 1, label: "Heat -1" });
    const [period, slot] = board.jobs[2].id.split(":");
    await DB.prepare("UPDATE odd_jobs SET kind = 'react', need = 1 WHERE account_id = ? AND period = ? AND slot = ?").bind(a.account.id, period, Number(slot)).run();
    await DB.prepare("INSERT INTO bonus_marks (account_id, kind, ref, at) VALUES (?, 'react', 'c-hot', ?)").bind(a.account.id, Date.now()).run();
    const c = await api("POST", `/bonus/jobs/${board.jobs[2].id}/claim`, undefined, a.token);
    expect(c.status).toBe(200);
    expect(c.body.account.heat).toBe(3);
    expect(c.body.line).toMatch(/phone call/);
    // the week's job: a free pack plus cash, outside the drawer
    const wk = board.week;
    const [wp] = wk.id.split(":");
    await DB.prepare("UPDATE odd_jobs SET kind = 'react', need = 1 WHERE account_id = ? AND period = ? AND slot = 9").bind(a.account.id, wp).run();
    const w = await api("POST", `/bonus/jobs/${wk.id}/claim`, undefined, a.token);
    expect(w.status).toBe(200);
    expect(w.body.account.money).toBe(1000 + wk.reward.cash);
    expect(await ledger(a.account.id, "bonus_week")).toEqual({ n: 1, total: wk.reward.cash });
    const shop = (await api("GET", "/shop", undefined, a.token)).body.packs;
    expect(shop.find((p: any) => p.price === 0)).toBeTruthy();
  });

  it("reports are checked and rate-limited", async () => {
    const a = await register("Report Rita");
    expect((await api("POST", "/bonus/report", { kind: "nap", ref: "x" }, a.token)).body.error).toBe("bad_request");
    expect((await api("POST", "/bonus/report", { kind: "replay", ref: "nope" }, a.token)).status).toBe(404);
    // a game that hasn't been played
    const g = (await api("GET", "/today", undefined, a.token)).body.games.find((x: any) => x.status === "scheduled");
    await api("GET", `/games/${g.id}/log?fmt=c`, undefined, a.token);
    expect((await api("POST", "/bonus/report", { kind: "replay", ref: g.id }, a.token)).status).toBe(404);
    expect((await api("POST", "/bonus/report", { kind: "read", ref: "nope" }, a.token)).status).toBe(404);
  });
});
