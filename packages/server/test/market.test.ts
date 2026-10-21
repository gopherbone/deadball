import { describe, expect, it } from "vitest";
import { env } from "cloudflare:workers";
import { api, register } from "./helpers.ts";

const DB = (env as unknown as { DB: D1Database }).DB;
const grant = (account: string, rarity: string, extra: Record<string, unknown> = {}) =>
  api("POST", "/admin/card", { account, rarity, ...extra }, undefined, true).then(r => {
    if (r.status !== 200) throw new Error(JSON.stringify(r.body));
    return r.body as { id: string; card: { id: string; personId: string } };
  });
const money = async (id: string) => (await DB.prepare("SELECT money FROM accounts WHERE id = ?").bind(id).first<{ money: number }>())!.money;
const held = async (id: string) => (await DB.prepare("SELECT COALESCE(SUM(amount), 0) AS h FROM holds WHERE account_id = ?").bind(id).first<{ h: number }>())!.h;
const endNow = (listingId: string) => DB.prepare("UPDATE listings SET ends_at = ? WHERE id = ?").bind(Date.now() - 1000, listingId).run();

async function auction(seller: string, token: string, body: Record<string, unknown> = {}) {
  const card = await grant(seller, "gilded", { redeem: "none" });
  const r = await api("POST", "/market", { cardId: card.id, kind: "auction", startBid: 100, hours: 24, ...body }, token);
  if (r.status !== 200) throw new Error(JSON.stringify(r.body));
  return { card, listing: r.body.listing };
}

describe("auctions", () => {
  it("validates new auctions", async () => {
    const s = await register("Val Seller");
    const card = await grant("Val Seller", "rare");
    const bad = (b: Record<string, unknown>) => api("POST", "/market", { cardId: card.id, kind: "auction", startBid: 100, hours: 24, ...b }, s.token).then(r => r.status);
    expect(await bad({ hours: 0 })).toBe(400);
    expect(await bad({ hours: 73 })).toBe(400);
    expect(await bad({ reserve: 50 })).toBe(400);
    expect(await bad({ buyNow: 90 })).toBe(400);
    expect(await bad({ reserve: 500, buyNow: 400 })).toBe(400);
    expect(await bad({ startBid: 0 })).toBe(400);
    const ok = await api("POST", "/market", { cardId: card.id, kind: "auction", startBid: 100, hours: 24, reserve: 300, buyNow: 600 }, s.token);
    expect(ok.body.listing).toMatchObject({ kind: "auction", price: 100, auction: { startBid: 100, currentBid: 100, bids: 0, minBid: 100, hasReserve: true, reserveMet: false, buyNow: 600 } });
    expect(ok.body.listing.auction.endsAt).toBeGreaterThan(Date.now() + 23 * 3600_000);
    expect(JSON.stringify(ok.body)).not.toMatch(/[:\[,]300[,\]}]/); // the reserve stays hidden (as a value; ids may contain the digits)
  });

  it("proxy bidding, escrow, outbid release, masked history, settlement and price history", async () => {
    const s = await register("Sally Seller");
    const b = await register("Bob Bidder");
    const c = await register("Cat Collector");
    const { card, listing } = await auction("Sally Seller", s.token);
    expect((await api("POST", `/market/${listing.id}/bid`, { max: 300 }, s.token)).status).toBe(400); // own auction
    expect((await api("POST", `/market/${listing.id}/bid`, { max: 99 }, b.token)).status).toBe(400); // below start

    // B opens with a 300 max: price stays at the start, 300 held
    const b1 = await api("POST", `/market/${listing.id}/bid`, { max: 300 }, b.token);
    expect(b1.body).toMatchObject({ leading: true, listing: { price: 100, auction: { currentBid: 100, leading: true, yourMax: 300, minBid: 125 } }, account: { money: 700, escrow: 300 } });
    // C bids 150: B's proxy answers at 175; C holds nothing
    const c1 = await api("POST", `/market/${listing.id}/bid`, { max: 150 }, c.token);
    expect(c1.body).toMatchObject({ leading: false, listing: { price: 175 } });
    expect(await money(c.account.id)).toBe(1000);
    expect((await api("POST", `/market/${listing.id}/bid`, { max: 190 }, c.token)).status).toBe(400); // below 175 + 25
    // C bids 400: C leads at 325 (B's max + increment); B's 300 comes back with an outbid mail
    const c2 = await api("POST", `/market/${listing.id}/bid`, { max: 400 }, c.token);
    expect(c2.body).toMatchObject({ leading: true, listing: { price: 325, auction: { leader: "C***r", leading: true } } });
    expect(await money(b.account.id)).toBe(1000);
    expect(await held(b.account.id)).toBe(0);
    expect(await money(c.account.id)).toBe(600);
    expect((await api("GET", "/mail", undefined, b.token)).body.mail.some((m: { subject: string }) => m.subject === "You've been outbid")).toBe(true);
    // B can't afford to chase beyond their money
    expect((await api("POST", `/market/${listing.id}/bid`, { max: 5000 }, b.token)).body.error).toBe("insufficient_funds");
    // C raising their own max holds just the difference
    await api("POST", `/market/${listing.id}/bid`, { max: 450 }, c.token);
    expect(await money(c.account.id)).toBe(550);
    expect(await held(c.account.id)).toBe(450);

    const det = (await api("GET", `/market/${listing.id}`, undefined, s.token)).body;
    expect(det.bids.map((x: { bidder: string }) => x.bidder)).toEqual(expect.arrayContaining(["B***r", "C***r"]));
    expect(det.bids.some((x: { auto?: boolean }) => x.auto)).toBe(true);
    expect((await api("DELETE", `/market/${listing.id}`, undefined, s.token)).body.message).toMatch(/bids/);

    // time's up: settle (several readers at once must still settle exactly once)
    await endNow(listing.id);
    await Promise.all([1, 2, 3].map(() => api("GET", `/market/${listing.id}`, undefined, b.token)));
    const done = (await api("GET", `/market/${listing.id}`, undefined, b.token)).body.listing;
    expect(done.status).toBe("sold");
    expect(await money(c.account.id)).toBe(1000 - 325);
    expect(await held(c.account.id)).toBe(0);
    expect(await money(s.account.id)).toBe(1000 + 325 - 16);
    expect((await api("GET", "/cards", undefined, c.token)).body.cards.map((x: { id: string }) => x.id)).toContain(card.id);
    expect((await api("GET", "/mail", undefined, c.token)).body.mail.some((m: { subject: string }) => m.subject.startsWith("You won"))).toBe(true);
    expect((await api("GET", "/mail", undefined, s.token)).body.mail.some((m: { subject: string }) => m.subject.startsWith("Auction sold"))).toBe(true);
    await api("GET", "/market", undefined, s.token); // settling again changes nothing
    expect(await money(s.account.id)).toBe(1000 + 325 - 16);
    expect((await api("POST", `/market/${listing.id}/bid`, { max: 999 }, b.token)).status).toBe(404);

    const hist = (await api("GET", `/market/history?def=${card.card.id}`, undefined, b.token)).body;
    expect(hist.sales[0]).toMatchObject({ price: 325, kind: "auction", rarity: "gilded" });
    expect(hist.stats).toMatchObject({ count: 1, last: 325 });
  });

  it("soft close extends late bids", async () => {
    const s = await register("Late Lou");
    const b = await register("Sniper Sam");
    const { listing } = await auction("Late Lou", s.token);
    await DB.prepare("UPDATE listings SET ends_at = ? WHERE id = ?").bind(Date.now() + 60_000, listing.id).run();
    const r = await api("POST", `/market/${listing.id}/bid`, { max: 120 }, b.token);
    expect(r.body.listing.auction.endsAt).toBeGreaterThanOrEqual(Date.now() + 4.9 * 60_000);
  });

  it("reserve: price jumps to the reserve when a max covers it; below it, the auction ends unsold and escrow returns", async () => {
    const s = await register("Reserve Rita");
    const b = await register("Lowball Lee");
    const c = await register("Highroll Hal");
    const one = await auction("Reserve Rita", s.token, { startBid: 50, reserve: 400 });
    const r = await api("POST", `/market/${one.listing.id}/bid`, { max: 200 }, b.token);
    expect(r.body.listing.auction.reserveMet).toBe(false);
    await endNow(one.listing.id);
    const ended = (await api("GET", `/market/${one.listing.id}`, undefined, b.token)).body.listing;
    expect(ended.status).toBe("ended");
    expect(await money(b.account.id)).toBe(1000);
    expect((await api("GET", "/mail", undefined, b.token)).body.mail.some((m: { subject: string }) => m.subject === "Reserve not met")).toBe(true);
    expect((await api("GET", "/cards", undefined, s.token)).body.cards.map((x: { id: string }) => x.id)).toContain(one.card.id);

    const two = await auction("Reserve Rita", s.token, { startBid: 50, reserve: 400 });
    const r2 = await api("POST", `/market/${two.listing.id}/bid`, { max: 500 }, c.token);
    expect(r2.body.listing).toMatchObject({ price: 400, auction: { reserveMet: true } });
  });

  it("buy it now until the first bid; watch list; search filters", async () => {
    const s = await register("Quick Quinn");
    const b = await register("Impulse Ike");
    const c = await register("Window Wendy");
    const one = await auction("Quick Quinn", s.token, { buyNow: 250 });
    const two = await auction("Quick Quinn", s.token, { buyNow: 250 });
    await api("POST", `/market/${one.listing.id}/watch`, undefined, c.token);
    expect((await api("GET", "/watchlist", undefined, c.token)).body.listings.map((l: { id: string }) => l.id)).toEqual([one.listing.id]);
    const bin = await api("POST", `/market/${one.listing.id}/buy`, undefined, b.token);
    expect(bin.status).toBe(200);
    expect(bin.body.account.money).toBe(750);
    expect((await api("GET", "/watchlist", undefined, c.token)).body.listings[0].status).toBe("sold");
    expect((await api("GET", `/market/history?def=${one.card.card.id}`, undefined, c.token)).body.sales[0]).toMatchObject({ price: 250, kind: "buy_now" });
    await api("DELETE", `/market/${one.listing.id}/watch`, undefined, c.token);
    expect((await api("GET", "/watchlist", undefined, c.token)).body.listings).toHaveLength(0);

    await api("POST", `/market/${two.listing.id}/bid`, { max: 120 }, c.token);
    expect((await api("POST", `/market/${two.listing.id}/buy`, undefined, b.token)).body.message).toMatch(/Buy It Now is gone/);

    const fixedCard = await grant("Quick Quinn", "original", { redeem: "retire" });
    await api("POST", "/market", { cardId: fixedCard.id, price: 5000 }, s.token);
    const auctions = (await api("GET", "/market?kind=auction&sort=ending", undefined, b.token)).body.listings;
    expect(auctions.every((l: { kind: string }) => l.kind === "auction")).toBe(true);
    const red = (await api("GET", "/market?redeemable=1", undefined, b.token)).body.listings;
    expect(red.map((l: { card: { id: string } }) => l.card.id)).toEqual([fixedCard.id]);
    expect(red[0].card.redeem.kind).toBe("retire");
    expect((await api("GET", "/market?rarity=original", undefined, b.token)).body.listings).toHaveLength(1);
    expect((await api("GET", "/market?sort=nope", undefined, b.token)).status).toBe(400);
  });

  it("concurrent bids: one leader, escrow only for the leader, money conserved", async () => {
    const s = await register("Rush Seller");
    const bidders = await Promise.all(["Rush One", "Rush Two", "Rush Three", "Rush Four"].map(register));
    const { listing } = await auction("Rush Seller", s.token);
    const maxes = [200, 350, 500, 275];
    await Promise.all(bidders.map((b, i) => api("POST", `/market/${listing.id}/bid`, { max: maxes[i] }, b.token)));
    const l = await DB.prepare("SELECT * FROM listings WHERE id = ?").bind(listing.id).first<{ high_bidder_id: string; price: number; max_bid: number }>();
    expect(l!.high_bidder_id).toBe(bidders[2].account.id);
    expect(l!.max_bid).toBe(500);
    expect(l!.price).toBe(375); // 350 + 25
    const holds = await DB.prepare("SELECT account_id, amount FROM holds WHERE listing_id = ?").bind(listing.id).all<{ account_id: string; amount: number }>();
    expect(holds.results).toEqual([{ account_id: bidders[2].account.id, amount: 500 }]);
    let total = 0;
    for (const b of bidders) total += await money(b.account.id);
    expect(total + 500).toBe(4000);
  });
});
