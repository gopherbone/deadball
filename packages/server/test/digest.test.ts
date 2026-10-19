import { describe, expect, it } from "vitest";
import { api, register, advance } from "./helpers.ts";

describe("GET /digest (While You Were Out)", () => {
  it("sums what settled since a day, and the cursor only shows what's new", async () => {
    expect((await api("GET", "/digest?sinceDay=1")).status).toBe(401);
    const a = await register("Digest Dan");
    const b = await register("Digest Dot");

    const clock = (await api("GET", "/clock")).body;
    const before = await api("GET", `/digest?sinceDay=${clock.day}`, undefined, a.token);
    expect(before.status).toBe(200);
    expect(before.body).toMatchObject({ sinceDay: clock.day, day: clock.day, empty: true, bets: { won: 0, lost: 0, net: 0 }, jobs: [], arrests: [] });
    expect(typeof before.body.cursor).toBe("string");
    expect((await api("GET", "/digest?sinceDay=abc", undefined, a.token)).body.error).toBe("bad_request");

    // a and b take opposite sides of two games
    const games = (await api("GET", "/today", undefined, a.token)).body.games.filter((g: any) => g.status === "scheduled").slice(0, 2);
    expect(games.length).toBe(2);
    for (const g of games) {
      expect((await api("POST", "/bets", { gameId: g.id, side: "home", amount: 50 }, a.token)).status).toBe(200);
      expect((await api("POST", "/bets", { gameId: g.id, side: "away", amount: 50 }, b.token)).status).toBe(200);
    }
    const afterBets = (await api("GET", "/me", undefined, a.token)).body.account.money;
    expect(afterBets).toBe(900);

    expect((await advance(1)).status).toBe(200);
    const settled = (await api("GET", "/bets?status=settled", undefined, a.token)).body.bets;
    expect(settled).toHaveLength(2);
    const paid = settled.reduce((s: number, x: any) => s + (x.payout ?? 0), 0);
    const won = settled.filter((x: any) => (x.payout ?? 0) > 0).length;

    const d = await api("GET", `/digest?sinceDay=${clock.day}`, undefined, a.token);
    expect(d.status).toBe(200);
    expect(d.body.empty).toBe(false);
    expect(d.body.bets).toEqual({ won, lost: 2 - won, staked: 100, paid, net: paid - 100 });
    const money = (await api("GET", "/me", undefined, a.token)).body.account.money;
    expect(d.body.money).toBe(money);
    // net: the haul (payouts less stakes); moneyChange: every ledger move but the grant
    expect(d.body.net).toBe(paid - 100);
    expect(d.body.moneyChange).toBe(money - 1000);
    expect(d.body.day).toBeGreaterThan(clock.day);
    expect(d.body.cards).toEqual({ sold: 0, soldFor: 0, won: 0, outbid: 0 });

    // the other side of the same games
    const db = (await api("GET", `/digest?sinceDay=${clock.day}`, undefined, b.token)).body;
    expect(db.bets.won + db.bets.lost).toBe(2);
    expect(db.bets.won).toBe(2 - won);

    // with the cursor from the last visit nothing is new
    const again = await api("GET", `/digest?sinceDay=${d.body.day}&since=${d.body.cursor}`, undefined, a.token);
    expect(again.body).toMatchObject({ empty: true, net: 0, moneyChange: 0, bets: { won: 0, lost: 0 } });
    // a future (next season's) day doesn't break it
    expect((await api("GET", "/digest?sinceDay=9999", undefined, a.token)).status).toBe(200);
  });

  it("lists jobs once their game is off the air, with what they cost", async () => {
    const a = await register("Digest Boss");
    const cands = (await api("GET", "/crew/candidates", undefined, a.token)).body.candidates;
    const cheapest = [...cands].sort((x: { ask: number }, y: { ask: number }) => x.ask - y.ask)[0];
    const crewId = (await api("POST", "/crew/recruit", { candidateId: cheapest.id }, a.token)).body.crew[0].id;
    const day = (await api("GET", "/clock")).body.day;
    const g = (await api("GET", "/today", undefined, a.token)).body.games.find((x: any) => x.status === "scheduled");
    const cat = (await api("GET", `/ops/catalog?game=${g.id}`, undefined, a.token)).body;
    const kind = cat.kinds.find((k: any) => k.kind !== "security" && k.cost <= 300 && !k.blocked && !(k.storyline && k.storyline.required));
    expect((await api("POST", "/ops", { kind: kind.kind, gameId: g.id, targetTeamId: g.home.id, crew: [crewId], gear: [] }, a.token)).status).toBe(200);
    // planned, not out yet
    expect((await api("GET", `/digest?sinceDay=${day}`, undefined, a.token)).body.jobs).toEqual([]);
    await advance(1);
    const d = (await api("GET", `/digest?sinceDay=${day}`, undefined, a.token)).body;
    expect(d.jobs).toHaveLength(1);
    expect(d.jobs[0]).toMatchObject({ name: kind.name, gameId: g.id, target: g.home.abbr, status: expect.stringMatching(/^(done|blown|cancelled)$/), result: expect.any(String) });
    expect(d.net).toBe(-d.jobs[0].cost);
    expect(d.empty).toBe(false);
    if (d.jobs[0].arrests > 0) expect(d.arrests.length).toBeGreaterThan(0);
  });
});
