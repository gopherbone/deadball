import { describe, expect, it } from "vitest";
import { api, register, advance, houseScale } from "./helpers.ts";

describe("the Enhanced League", () => {
  it("slates, pools, replays, standings and schedule for EL games and exhibitions", async () => {
    await houseScale(0); // player-only pools (house money: house.test.ts)
    const a = await register("Desert Rat");
    const b = await register("Mirage Mo");
    // opening eve: exhibitions only, flagged as such
    const t0 = (await api("GET", "/today", undefined, a.token)).body;
    for (const g of t0.games.filter((x: { id: string }) => /EX\d+$/.test(x.id))) expect(g).toMatchObject({ exhibition: true, circuit: "continental" });
    await advance(1);
    const today = (await api("GET", "/today", undefined, a.token)).body;
    const el = today.games.filter((g: { circuit: string }) => g.circuit === "enhanced");
    expect(el).toHaveLength(3);
    expect(el.every((g: { home: { level: string }; away: { level: string } }) => g.home.level === "EL" && g.away.level === "EL")).toBe(true);
    // Continental games come first on the slate
    expect(today.games[0].circuit).toBe("continental");

    const g = el[0];
    expect((await api("POST", "/bets", { gameId: g.id, side: "home", amount: 100 }, a.token)).status).toBe(200);
    expect((await api("POST", "/bets", { gameId: g.id, side: "away", amount: 100 }, b.token)).status).toBe(200);
    await advance(1);
    const detail = (await api("GET", `/games/${g.id}`, undefined, a.token)).body;
    expect(detail).toMatchObject({ status: "final", circuit: "enhanced" });
    expect(detail.box.home.bat.length).toBeGreaterThan(8);
    if (detail.notes) expect(detail.notes[0]).toMatch(/^POWERS/);
    const log = (await api("GET", `/games/${g.id}/log`, undefined, a.token)).body;
    expect(log.log.length).toBeGreaterThan(10);
    const settled = (await api("GET", "/bets?status=settled", undefined, a.token)).body.bets;
    expect(settled[0]).toMatchObject({ gameId: g.id, status: "settled" });
    const ma = (await api("GET", "/me", undefined, a.token)).body.account.money;
    const mb = (await api("GET", "/me", undefined, b.token)).body.account.money;
    expect(ma + mb).toBe(2000 - 200 + 180); // pool of 200 pays out 180

    const st = (await api("GET", "/standings?level=EL", undefined, a.token)).body;
    expect(st.rows).toHaveLength(6);
    expect(st.rows.every((r: { team: { level: string } }) => r.team.level === "EL")).toBe(true);
    const sch = (await api("GET", "/schedule?level=EL", undefined, a.token)).body;
    expect(sch.level).toBe("EL");
    expect(sch.games.length).toBeGreaterThanOrEqual(9);
    expect(JSON.stringify(sch).length).toBeLessThan(48 * 1024);
    const mfp = (await api("GET", "/schedule?team=MFP", undefined, a.token)).body;
    expect(mfp.games.every((x: { home: { id: string }; away: { id: string } }) => x.home.id === "MFP" || x.away.id === "MFP")).toBe(true);
  });
});
