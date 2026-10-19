import { describe, expect, it } from "vitest";
import { env } from "cloudflare:workers";
import { api, register, advance, houseScale } from "./helpers.ts";

const DB = (env as unknown as { DB: D1Database }).DB;

describe("register -> bet -> play day -> settle", () => {
  it("runs the whole betting loop with pari-mutuel payouts", async () => {
    // player-only pools here (house money: house.test.ts)
    expect((await houseScale(0)).body).toEqual({ scale: 0 });
    const clock = await api("GET", "/clock");
    expect(clock.status).toBe(200);
    expect(clock.body).toMatchObject({ season: 1, phase: expect.any(String), msPerDay: 600000 });

    const a = await register("Lefty Loot");
    const b = await register("Dotty Dial");
    expect(a.account).toMatchObject({ name: "Lefty Loot", money: 1000, crewSize: 0, cards: 0, rank: expect.any(String) });
    expect((await api("POST", "/register", { name: "LEFTY LOOT" })).body.error).toBe("name_taken");
    expect((await api("POST", "/register", { name: "x" })).body.error).toBe("name_rejected");
    expect((await api("POST", "/register", { name: "Admin" })).body.error).toBe("name_rejected");
    expect((await api("GET", "/me")).status).toBe(401);

    const today = await api("GET", "/today", undefined, a.token);
    expect(today.status).toBe(200);
    const g = today.body.games[0];
    // opening eve: the slate may be Enhanced-vs-Continental exhibitions (level ML, bettable)
    expect(g).toMatchObject({ status: "scheduled", pool: { home: 0, away: 0 }, home: { level: expect.stringMatching(/^(ML|EL)$/), record: expect.any(String) }, circuit: "continental" });
    if (/EX\d+$/.test(g.id)) expect(g.exhibition).toBe(true);
    expect(g.probables.home.line).toMatch(/^\d+-\d+, \d+\.\d\d$/);

    // validation
    expect((await api("POST", "/bets", { gameId: g.id, side: "home", amount: 4 }, a.token)).body.error).toBe("bad_request");
    expect((await api("POST", "/bets", { gameId: g.id, side: "home", amount: 600 }, a.token)).body.error).toBe("bad_request"); // > 50%
    expect((await api("POST", "/bets", { gameId: g.id, side: "up", amount: 10 }, a.token)).body.error).toBe("bad_request");
    expect((await api("POST", "/bets", { gameId: "nope", side: "home", amount: 10 }, a.token)).status).toBe(404);

    const bet = await api("POST", "/bets", { gameId: g.id, side: "home", amount: 100 }, a.token);
    expect(bet.status).toBe(200);
    expect(bet.body.account.money).toBe(900);
    expect(bet.body.pool.home).toBe(100);
    await api("POST", "/bets", { gameId: g.id, side: "home", amount: 50 }, a.token); // adds to the same bet
    expect((await api("POST", "/bets", { gameId: g.id, side: "away", amount: 50 }, a.token)).body.error).toBe("bad_request"); // can't hedge
    const bb = await api("POST", "/bets", { gameId: g.id, side: "away", amount: 300 }, b.token);
    expect(bb.body.pool).toMatchObject({ home: 150, away: 300 });
    expect(bb.body.pool.pays.home).toBeCloseTo((450 * 0.9) / 150, 1);

    const open = await api("GET", "/bets?status=open", undefined, a.token);
    expect(open.body.bets).toHaveLength(1);
    expect(open.body.bets[0]).toMatchObject({ side: "home", amount: 150, status: "open" });
    const t2 = await api("GET", "/today", undefined, a.token);
    expect(t2.body.games[0].myBet).toEqual({ side: "home", amount: 150 });

    // play + settle the day
    const adv = await advance(1);
    expect(adv.status).toBe(200);
    const detail = await api("GET", `/games/${g.id}`, undefined, a.token);
    expect(detail.body.status).toBe("final");
    expect(detail.body.box.home.bat.length).toBeGreaterThan(8);
    expect(detail.body.decisions.w.name).toBeTruthy();
    expect((await api("POST", "/bets", { gameId: g.id, side: "home", amount: 10 }, a.token)).body.error).toBe("window_closed");

    const homeWon = detail.body.score.home > detail.body.score.away;
    const net = Math.floor(450 * 0.9);
    const ma = (await api("GET", "/me", undefined, a.token)).body.account.money;
    const mb = (await api("GET", "/me", undefined, b.token)).body.account.money;
    if (homeWon) { expect(ma).toBe(850 + Math.floor((150 * net) / 150)); expect(mb).toBe(700); }
    else { expect(mb).toBe(700 + Math.floor((300 * net) / 300)); expect(ma).toBe(850); }
    const settled = await api("GET", "/bets?status=settled", undefined, a.token);
    expect(settled.body.bets[0]).toMatchObject({ status: "settled", won: homeWon });
    const mail = await api("GET", "/mail", undefined, a.token);
    expect(mail.body.mail.some((m: { kind: string }) => m.kind === "bank")).toBe(true);

    // settlement is idempotent: re-running it pays nothing more
    await DB.prepare("UPDATE games SET settled = 0 WHERE id = ?").bind(g.id).run();
    await advance(1);
    expect((await api("GET", "/me", undefined, a.token)).body.account.money).toBe(ma);
    const ledger = await DB.prepare("SELECT SUM(delta) AS s FROM ledger WHERE account_id = ?").bind(a.account.id).first<{ s: number }>();
    expect(ledger!.s).toBe(ma);

    // replay + standings + news exist
    const log = await api("GET", `/games/${g.id}/log`, undefined, a.token);
    expect(log.body.log[0]).toMatchObject({ k: "half" });
    expect(Object.keys(log.body.people).length).toBeGreaterThan(18);
    if (log.body.next !== undefined) {
      const p2 = await api("GET", `/games/${g.id}/log?from=${log.body.next}`, undefined, a.token);
      expect(p2.body.from).toBe(log.body.next);
    }
    expect(JSON.stringify(log.body).length).toBeLessThan(48 * 1024);
    const wire = await api("GET", `/games/${g.id}/wire`, undefined, a.token);
    expect(wire.body.lines.length).toBeGreaterThan(10);
    const st = await api("GET", "/standings?level=ML", undefined, a.token);
    expect(st.body.rows).toHaveLength(8);
    const news = await api("GET", "/news", undefined, a.token);
    expect(news.body.stories.length).toBeGreaterThan(0);
    const story = await api("GET", `/news/${detail.body.storyId}`, undefined, a.token);
    expect(story.status).toBe(200);
    expect(story.body.story.headline).toBeTruthy();
  });

  it("serves person, team and schedule pages", async () => {
    const a = await register("Gus Gumshoe");
    await advance(2);
    const team = await api("GET", "/teams/HCL", undefined, a.token);
    expect(team.status).toBe(200);
    expect(team.body.chain).toHaveLength(4);
    expect(team.body.roster.length).toBeGreaterThan(20);
    const pid = team.body.roster[0].id;
    const p1 = await api("GET", `/people/${pid}`, undefined, a.token);
    const p2 = await api("GET", `/people/${pid}`, undefined, a.token);
    expect(p1.body.person).toMatchObject({ id: pid, traits: expect.any(Array), mood: expect.any(String) });
    expect(p2.body.visitors).toBe(p1.body.visitors + 1);
    const sch = await api("GET", "/schedule?team=HCL", undefined, a.token);
    expect(sch.body.games.length).toBeGreaterThan(5);
    expect(sch.body.games.every((g: { home: { id: string }; away: { id: string } }) => g.home.id === "HCL" || g.away.id === "HCL")).toBe(true);
    expect((await api("GET", "/people/nobody", undefined, a.token)).status).toBe(404);
  });
});
