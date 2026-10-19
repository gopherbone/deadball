import { describe, expect, it } from "vitest";
import { env } from "cloudflare:workers";
import { api, register } from "./helpers.ts";

const DB = (env as unknown as { DB: D1Database }).DB;
const grant = (account: string, rarity: string, extra: Record<string, unknown> = {}) =>
  api("POST", "/admin/card", { account, rarity, ...extra }, undefined, true).then(r => {
    if (r.status !== 200) throw new Error(JSON.stringify(r.body));
    return r.body as { id: string; card: { id: string; personId: string; serial?: number; printRun?: number; redeem?: { kind: string } } };
  });

describe("redeemable cards", () => {
  it("boost: exact effect, bulletin, ticker, heads-up mail to bettors on the team's next game", async () => {
    const a = await register("Redeemer Ray");
    const b = await register("Bettor Bea");
    const today = (await api("GET", "/today", undefined, b.token)).body;
    const g = today.games[0];
    // the Continental side (opening-eve exhibitions bring Enhanced clubs, which have no cards)
    const team = (await api("GET", `/teams/${g.home.level === "ML" ? g.home.id : g.away.id}`, undefined, b.token)).body;
    const pid = team.roster[0].id;
    await api("POST", "/bets", { gameId: g.id, side: "home", amount: 50 }, b.token);

    const plain = await grant("Redeemer Ray", "rare", { personId: pid });
    expect((await api("POST", `/cards/${plain.id}/redeem`, { confirm: true }, a.token)).body.message).toMatch(/isn't redeemable/);
    const card = await grant("Redeemer Ray", "gilded", { personId: pid, redeem: "boost" });
    const view = (await api("GET", `/cards/${card.id}`, undefined, a.token)).body.card;
    expect(view.redeem).toMatchObject({ kind: "boost", boost: 12, days: 7, label: "REDEEMABLE: BOOST +12 FOR 7 DAYS" });
    expect(view.front.redeem).toBe("REDEEMABLE: BOOST +12 FOR 7 DAYS");
    expect(view.value).toBeGreaterThan(150);
    expect((await api("POST", `/cards/${card.id}/redeem`, {}, a.token)).status).toBe(400); // confirm required
    expect((await api("POST", `/cards/${card.id}/redeem`, { confirm: true }, b.token)).status).toBe(404); // not b's

    const before = (await api("GET", "/me", undefined, a.token)).body.account;
    const r = await api("POST", `/cards/${card.id}/redeem`, { confirm: true }, a.token);
    expect(r.status).toBe(200);
    expect(r.body).toMatchObject({ kind: "boost", effect: { kind: "boost", boost: 12, days: 7, person: { id: pid } }, card: { id: card.id, redeemed: true } });
    expect(r.body.effect.untilDay - r.body.effect.fromDay).toBe(6);
    expect(r.body.account.money).toBe(before.money); // nothing else happens to the redeemer
    expect(r.body.account.heat).toBe(before.heat);
    expect(r.body.story.headline).toMatch(/^(Card )?Redeemed: /);
    expect((await api("GET", `/cards/${card.id}`, undefined, a.token)).status).toBe(404);
    expect((await DB.prepare("SELECT COUNT(*) AS n FROM redeem_mods WHERE person_id = ?").bind(pid).first<{ n: number }>())!.n).toBe(1);

    const story = (await api("GET", `/news/${r.body.story.id}`, undefined, b.token)).body.story;
    expect(story).toMatchObject({ kind: "brief", section: "Bulletin" });
    expect(story.body.join(" ")).toContain("Redeemer Ray redeemed");
    const ticker = (await api("GET", "/bulletins", undefined, b.token)).body.bulletins;
    expect(ticker[0]).toMatchObject({ kind: "boost", redeemer: "Redeemer Ray", person: { id: pid }, boost: 12, days: 7, storyId: r.body.story.id });
    const mail = (await api("GET", "/mail", undefined, b.token)).body.mail;
    const heads = mail.find((m: { subject: string }) => m.subject === r.body.story.headline);
    expect(heads).toBeTruthy();
    // archive photos come through the story summary, the full story and mail
    expect(story.photo).toEqual(expect.any(String));
    const summary = (await api("GET", "/news?kind=brief", undefined, b.token)).body.stories.find((x: { id: string }) => x.id === r.body.story.id);
    expect(summary).toMatchObject({ photo: story.photo, photoCaption: expect.any(String), section: "Bulletin" });
    expect(heads).toMatchObject({ photo: story.photo, photoCaption: expect.any(String) });

    // stacking: a second boost on the same player is worth half
    const again = await grant("Redeemer Ray", "gilded", { personId: pid, redeem: "boost" });
    expect((await api("POST", `/cards/${again.id}/redeem`, { confirm: true }, a.token)).body.effect.boost).toBe(6);
  });

  it("retire: player leaves the team, leftover cards become Final Season, can't redeem twice", async () => {
    const a = await register("Closer Cal");
    const b = await register("Keeper Kay");
    const today = (await api("GET", "/today", undefined, a.token)).body;
    const teamId = today.games[0].away.id;
    const pid = (await api("GET", `/teams/${teamId}`, undefined, a.token)).body.roster[2].id;
    const orig = await grant("Closer Cal", "original", { personId: pid, redeem: "retire" });
    const copy = await grant("Keeper Kay", "rare", { personId: pid });
    const copyBefore = (await api("GET", `/cards/${copy.id}`, undefined, b.token)).body.card;
    const listed = await grant("Closer Cal", "original", { personId: pid, redeem: "retire" });
    await api("POST", "/market", { cardId: listed.id, price: 999 }, a.token);
    expect((await api("POST", `/cards/${listed.id}/redeem`, { confirm: true }, a.token)).body.message).toMatch(/market/);

    const r = await api("POST", `/cards/${orig.id}/redeem`, { confirm: true }, a.token);
    expect(r.status).toBe(200);
    expect(r.body).toMatchObject({ kind: "retire", effect: { kind: "retire", person: { id: pid } } });
    expect(r.body.story.headline).toMatch(/Retire/);
    const team = (await api("GET", `/teams/${teamId}`, undefined, a.token)).body;
    expect(team.roster.map((p: { id: string }) => p.id)).not.toContain(pid);
    expect(team.roster).toHaveLength(26);
    const copyAfter = (await api("GET", `/cards/${copy.id}`, undefined, b.token)).body.card;
    expect(copyAfter.finalSeason).toBe(true);
    expect(copyAfter.back.lines[0]).toMatch(/^FINAL SEASON/);
    expect(copyAfter.value).toBeGreaterThan(copyBefore.value);
    await api("DELETE", `/market/${(await DB.prepare("SELECT id FROM listings WHERE card_id = ?").bind(listed.id).first<{ id: string }>())!.id}`, undefined, a.token);
    expect((await api("POST", `/cards/${listed.id}/redeem`, { confirm: true }, a.token)).body.message).toMatch(/no longer in the game/);
  });

  it("parallel redeems of one card: exactly one wins", async () => {
    const a = await register("Double Dip");
    const card = await grant("Double Dip", "gilded", { redeem: "boost" });
    const rs = await Promise.all([1, 2, 3].map(() => api("POST", `/cards/${card.id}/redeem`, { confirm: true }, a.token)));
    expect(rs.filter(r => r.status === 200)).toHaveLength(1);
    expect((await DB.prepare("SELECT COUNT(*) AS n FROM redemptions WHERE card_id = ?").bind(card.id).first<{ n: number }>())!.n).toBe(1);
  });
});
