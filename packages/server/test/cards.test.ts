import { describe, expect, it } from "vitest";
import { env } from "cloudflare:workers";
import { api, register } from "./helpers.ts";

const DB = (env as unknown as { DB: D1Database }).DB;

describe("pack buy -> list -> buy", () => {
  it("opens packs, lists a card and sells it with the house cut", async () => {
    const a = await register("Seller Sam");
    const b = await register("Buyer Bea");
    const shop = await api("GET", "/shop", undefined, a.token);
    expect(shop.body.packs.find((p: { kind: string }) => p.kind === "starter")).toMatchObject({ price: 0 });
    const starter = await api("POST", "/packs/buy", { kind: "starter" }, a.token);
    expect(starter.status).toBe(200);
    expect(starter.body.cards.length).toBeGreaterThan(0);
    expect(starter.body.account.money).toBe(1000);
    expect((await api("POST", "/packs/buy", { kind: "starter" }, a.token)).body.error).toBe("bad_request"); // only one free pack
    const card = starter.body.cards[0];
    expect(card).toMatchObject({ person: { name: expect.any(String) }, team: { abbr: expect.any(String) }, back: { lines: expect.any(Array) }, value: expect.any(Number) });

    const paid = (await api("GET", "/shop", undefined, a.token)).body.packs.find((p: { price: number }) => p.price > 0);
    const bought = await api("POST", "/packs/buy", { kind: paid.kind }, a.token);
    expect(bought.status).toBe(200);
    expect(bought.body.account.money).toBe(1000 - paid.price);
    expect(bought.body.account.cards).toBe(starter.body.cards.length + bought.body.cards.length);

    // can't overspend
    await DB.prepare("UPDATE accounts SET money = 3 WHERE id = ?").bind(b.account.id).run();
    expect((await api("POST", "/packs/buy", { kind: paid.kind }, b.token)).body.error).toBe("insufficient_funds");
    await DB.prepare("UPDATE accounts SET money = 1000 WHERE id = ?").bind(b.account.id).run();

    const listing = await api("POST", "/market", { cardId: card.id, price: 200 }, a.token);
    expect(listing.status).toBe(200);
    expect(listing.body.listing).toMatchObject({ price: 200, seller: "Seller Sam", card: { id: card.id } });
    expect((await api("POST", "/market", { cardId: card.id, price: 50 }, a.token)).body.error).toBe("bad_request");
    expect((await api("POST", "/market", { cardId: card.id, price: 50 }, b.token)).status).toBe(404); // not b's card
    const market = await api("GET", "/market?sort=price", undefined, b.token);
    expect(market.body.listings.map((l: { id: string }) => l.id)).toContain(listing.body.listing.id);
    expect((await api("POST", `/market/${listing.body.listing.id}/buy`, undefined, a.token)).body.error).toBe("bad_request"); // own

    const before = (await api("GET", "/me", undefined, a.token)).body.account.money;
    const buy = await api("POST", `/market/${listing.body.listing.id}/buy`, undefined, b.token);
    expect(buy.status).toBe(200);
    expect(buy.body.card.id).toBe(card.id);
    expect(buy.body.account.money).toBe(800);
    expect((await api("GET", "/me", undefined, a.token)).body.account.money).toBe(before + 190); // 5% cut
    expect((await api("POST", `/market/${listing.body.listing.id}/buy`, undefined, b.token)).status).toBe(404); // sold
    const binder = await api("GET", "/cards", undefined, b.token);
    expect(binder.body.cards.map((c: { id: string }) => c.id)).toContain(card.id);

    // list + cancel
    const l2 = await api("POST", "/market", { cardId: card.id, price: 999 }, b.token);
    expect((await api("DELETE", `/market/${l2.body.listing.id}`, undefined, a.token)).status).toBe(404);
    expect((await api("DELETE", `/market/${l2.body.listing.id}`, undefined, b.token)).body).toEqual({ ok: true });
  });

  it("parallel market buys can't double-spend", async () => {
    const s = await register("Parallel Pete");
    const buyers = await Promise.all(["Racer One", "Racer Two", "Racer Three"].map(register));
    const pack = await api("POST", "/packs/buy", { kind: "starter" }, s.token);
    const l = await api("POST", "/market", { cardId: pack.body.cards[0].id, price: 100 }, s.token);
    const results = await Promise.all(buyers.map(b => api("POST", `/market/${l.body.listing.id}/buy`, undefined, b.token)));
    expect(results.filter(r => r.status === 200)).toHaveLength(1);
    const total = await DB.prepare("SELECT SUM(money) AS m FROM accounts WHERE id IN (?,?,?,?)").bind(s.account.id, ...buyers.map(b => b.account.id)).first<{ m: number }>();
    expect(total!.m).toBe(4000 - 5); // only the house cut left the system
  });
});
