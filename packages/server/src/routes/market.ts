// The Diamond Exchange: fixed-price listings and eBay-style auctions.
//
// Auctions: starting bid, optional hidden reserve, optional Buy It Now (until the first bid),
// a duration in real hours, minimum increments, proxy (max) bidding, soft close (a bid in the
// last 5 minutes pushes the end to 5 minutes from now), escrow (the leading bidder's max is
// held from their money through the ledger and released when they're outbid or the auction
// ends unsold), settlement on time (DO alarm, plus lazily on market reads), a 5% house cut on
// the final price, a watch list and per-card price history.
//
// Every market mutation runs inside League.withMarket (one at a time in this DO) and writes
// one D1 batch gated by a ledger row, with the listing's version as an optimistic guard.

import type { Ctx } from "../router.ts";
import type { League } from "../league.ts";
import { decCursor, encCursor, fail, int, newId, str } from "../http.ts";
import type { Card } from "../sim.ts";
import { cardView, personRef } from "../views.ts";
import { accountView, gate, limitParam, moneyMove } from "./common.ts";

export const MARKET_CUT = 0.05;
export const SOFT_CLOSE_MS = 5 * 60_000;
export const MIN_HOURS = 1;
export const MAX_HOURS = 72;
const HOUR = 3_600_000;

/** Minimum raise over the current price. */
export function increment(price: number): number {
  return price < 100 ? 5 : price < 1000 ? 25 : price < 5000 ? 100 : 250;
}

/** "Lefty Loot" -> "L***t" */
export function mask(name: string | null | undefined): string {
  if (!name) return "(gone)";
  const s = name.replace(/\s+/g, "");
  return s.length <= 2 ? `${s[0]}***` : `${s[0]}***${s[s.length - 1]}`;
}

export type ListingRow = {
  id: string; card_id: string; seller_id: string; price: number; status: string; created_at: number; buyer_id: string | null; sold_at: number | null;
  kind: string; start_bid: number | null; reserve: number | null; buy_now: number | null; ends_at: number | null; high_bidder_id: string | null;
  max_bid: number; bid_count: number; version: number; def_id: string | null; rarity: string | null; redeem: string | null; person_id: string | null; team_id: string | null;
  seller: string; cdata: string; leader: string | null; watchers?: number;
};
const SELECT = `SELECT l.*, a.name AS seller, k.data AS cdata, hb.name AS leader, (SELECT COUNT(*) FROM watches w WHERE w.listing_id = l.id) AS watchers
  FROM listings l JOIN accounts a ON a.id = l.seller_id JOIN cards k ON k.id = l.card_id LEFT JOIN accounts hb ON hb.id = l.high_bidder_id`;

export type ListingView = {
  id: string; card: ReturnType<typeof cardView>; price: number; seller: string; at: number; kind: "fixed" | "auction"; status: string; watchers: number;
  watching?: boolean;
  auction?: {
    startBid: number; currentBid: number; bids: number; endsAt: number; minBid: number; hasReserve: boolean; reserveMet?: boolean;
    buyNow?: number; leader?: string; leading?: boolean; yourMax?: number;
  };
};

function view(c: Ctx, r: ListingRow, watching?: boolean): ListingView {
  const v: ListingView = {
    id: r.id, card: cardView(c.L.world, r.card_id, JSON.parse(r.cdata) as Card), price: r.price, seller: r.seller, at: r.created_at,
    kind: r.kind === "auction" ? "auction" : "fixed", status: r.status, watchers: r.watchers ?? 0,
  };
  if (watching !== undefined) v.watching = watching;
  if (r.kind === "auction") {
    const a: NonNullable<ListingView["auction"]> = {
      startBid: r.start_bid ?? r.price, currentBid: r.price, bids: r.bid_count, endsAt: r.ends_at ?? 0,
      minBid: r.bid_count ? r.price + increment(r.price) : (r.start_bid ?? r.price), hasReserve: r.reserve != null,
    };
    if (r.reserve != null) a.reserveMet = r.bid_count > 0 && r.max_bid >= r.reserve && r.price >= r.reserve;
    if (r.buy_now != null && r.bid_count === 0 && r.status === "active") a.buyNow = r.buy_now;
    if (r.high_bidder_id) {
      a.leader = mask(r.leader);
      if (r.high_bidder_id === c.acct.id) { a.leading = true; a.yourMax = r.max_bid; }
    }
    v.auction = a;
  }
  return v;
}

async function row(c: Ctx, id: string): Promise<ListingRow | undefined> {
  return (await c.db.prepare(`${SELECT} WHERE l.id = ?`).bind(id).first<ListingRow>()) ?? undefined;
}

async function watchingSet(c: Ctx, ids: string[]): Promise<Set<string>> {
  if (!ids.length) return new Set();
  const rows = (await c.db.prepare("SELECT listing_id FROM watches WHERE account_id = ? AND listing_id IN (SELECT value FROM json_each(?))").bind(c.acct.id, JSON.stringify(ids)).all<{ listing_id: string }>()).results;
  return new Set(rows.map(r => r.listing_id));
}

const mailStmt = (c: { db: D1Database }, id: string, to: string, at: number, subject: string, body: string[], gateId?: string) =>
  c.db.prepare(`INSERT OR IGNORE INTO mail (id, account_id, at, read, kind, data) SELECT ?, ?, ?, 0, 'bank', ? ${gateId ? `WHERE ${gate()}` : ""}`)
    .bind(id, to, at, JSON.stringify({ from: "Diamond Exchange", subject, body }), ...(gateId ? [gateId] : []));

// ------------------------------------------------------------------ search

/** GET /v1/market?q=&sort=&kind=&rarity=&redeemable=&team=&person=&def=&ending=soon&min=&max=&cursor= */
export async function search(c: Ctx) {
  await settleDue(c.L, c.now);
  const q = (c.q.get("q") ?? "").toLowerCase().trim().slice(0, 40);
  const sort = c.q.get("sort") ?? "new";
  const order = {
    new: "l.created_at DESC, l.id DESC", old: "l.created_at ASC, l.id ASC", price: "l.price ASC, l.id ASC", "-price": "l.price DESC, l.id DESC",
    ending: "CASE WHEN l.kind = 'auction' THEN 0 ELSE 1 END, l.ends_at ASC, l.id ASC", bids: "l.bid_count DESC, l.id DESC",
  }[sort];
  if (!order) fail("bad_request", "sort must be new, old, price, -price, ending or bids");
  const where: string[] = ["l.status = 'active'"];
  const args: unknown[] = [];
  if (q) { where.push("l.search LIKE ?"); args.push(`%${q.replace(/[%_]/g, "")}%`); }
  const kind = c.q.get("kind");
  if (kind) { if (kind !== "auction" && kind !== "fixed") fail("bad_request", "kind must be auction or fixed"); where.push("l.kind = ?"); args.push(kind); }
  const rarity = c.q.get("rarity");
  if (rarity) { where.push("l.rarity = ?"); args.push(rarity.toLowerCase()); }
  const red = c.q.get("redeemable");
  if (red === "1" || red === "true") where.push("l.redeem IS NOT NULL");
  else if (red === "boost" || red === "retire") { where.push("l.redeem = ?"); args.push(red); }
  const team = c.q.get("team");
  if (team) { where.push("(l.team_id = ? OR l.search LIKE ?)"); args.push(team, `%${team.toLowerCase()}%`); }
  const person = c.q.get("person");
  if (person) { where.push("l.person_id = ?"); args.push(person); }
  const def = c.q.get("def");
  if (def) { where.push("l.def_id = ?"); args.push(def); }
  if (c.q.get("ending") === "soon") { where.push("l.kind = 'auction' AND l.ends_at <= ?"); args.push(c.now + HOUR); }
  const min = Number(c.q.get("min")), max = Number(c.q.get("max"));
  if (c.q.get("min") && Number.isFinite(min)) { where.push("l.price >= ?"); args.push(min); }
  if (c.q.get("max") && Number.isFinite(max)) { where.push("l.price <= ?"); args.push(max); }
  const offset = decCursor<number>(c.q.get("cursor")) ?? 0;
  const limit = limitParam(c, 10, 30);
  const rows = (await c.db.prepare(`${SELECT} WHERE ${where.join(" AND ")} ORDER BY ${order} LIMIT ? OFFSET ?`).bind(...args, limit + 1, offset).all<ListingRow>()).results;
  const items = rows.slice(0, limit);
  const w = await watchingSet(c, items.map(r => r.id));
  const out: { listings: ListingView[]; next?: string } = { listings: items.map(r => view(c, r, w.has(r.id))) };
  if (rows.length > limit) out.next = encCursor(offset + limit);
  return out;
}

/** GET /v1/market/:id: listing + bid history (bidder names masked). */
export async function detail(c: Ctx) {
  await settleDue(c.L, c.now);
  const r = await row(c, c.params[0]);
  if (!r) fail("not_found", "no such listing");
  const bids = (await c.db.prepare(`SELECT b.shown, b.auto, b.at, b.bidder_id, a.name FROM bids b LEFT JOIN accounts a ON a.id = b.bidder_id WHERE b.listing_id = ? ORDER BY b.at DESC, b.shown DESC, b.id DESC LIMIT 50`)
    .bind(r!.id).all<{ shown: number; auto: number; at: number; bidder_id: string; name: string | null }>()).results;
  const w = await watchingSet(c, [r!.id]);
  return {
    listing: view(c, r!, w.has(r!.id)),
    bids: bids.map(b => ({ bidder: b.bidder_id === c.acct.id ? "you" : mask(b.name), amount: b.shown, at: b.at, ...(b.auto ? { auto: true } : {}) })),
  };
}

// ------------------------------------------------------------------ listing

/**
 * POST /v1/market
 *   fixed:   { cardId, price }
 *   auction: { cardId, kind: "auction", startBid, hours (1–72), reserve?, buyNow? }
 */
export async function list(c: Ctx) {
  const cardId = str(c.body, "cardId", 60);
  const auction = c.body.kind === "auction";
  if (c.body.kind !== undefined && c.body.kind !== "auction" && c.body.kind !== "fixed") fail("bad_request", "kind must be fixed or auction");
  let price: number, startBid: number | null = null, reserve: number | null = null, buyNow: number | null = null, endsAt: number | null = null;
  if (auction) {
    startBid = int(c.body, "startBid", 1, 1_000_000);
    const hours = int(c.body, "hours", MIN_HOURS, MAX_HOURS);
    if (c.body.reserve !== undefined) { reserve = int(c.body, "reserve", 1, 10_000_000); if (reserve <= startBid) fail("bad_request", "reserve must be above the starting bid"); }
    if (c.body.buyNow !== undefined) {
      buyNow = int(c.body, "buyNow", 1, 10_000_000);
      if (buyNow <= startBid || (reserve != null && buyNow < reserve)) fail("bad_request", "buyNow must be above the starting bid and the reserve");
    }
    price = startBid;
    endsAt = c.now + hours * HOUR;
  } else {
    price = int(c.body, "price", 1, 1_000_000);
  }
  const card = await c.db.prepare("SELECT * FROM cards WHERE id = ? AND owner_id = ?").bind(cardId, c.acct.id).first<{ data: string }>();
  if (!card) fail("not_found", "that card isn't in your binder");
  const data = JSON.parse(card!.data) as Card;
  const v = cardView(c.L.world, cardId, data);
  const id = newId("l");
  const search = `${v.person.name} ${v.team.city} ${v.team.name} ${v.team.abbr} ${v.rarity} ${v.set}${data.redeem ? " redeemable " + data.redeem.kind : ""}`.toLowerCase();
  const r = await c.db.prepare(`INSERT OR IGNORE INTO listings (id, card_id, seller_id, price, search, created_at, kind, start_bid, reserve, buy_now, ends_at, def_id, rarity, redeem, person_id, team_id)
      SELECT ?, id, owner_id, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ? FROM cards WHERE id = ? AND owner_id = ?`)
    .bind(id, price, search, c.now, auction ? "auction" : "fixed", startBid, reserve, buyNow, endsAt, data.id, data.rarity, data.redeem?.kind ?? null, data.personId, v.team.id, cardId, c.acct.id).run();
  if (!r.meta.changes) fail("bad_request", "that card is already listed");
  if (auction) await c.L.armAlarm();
  return { listing: view(c, (await row(c, id))!) };
}

/** DELETE /v1/market/:id: sellers can pull a fixed listing, or an auction with no bids. */
export async function cancel(c: Ctx) {
  return c.L.withMarket(async () => {
    const r = await c.db.prepare("UPDATE listings SET status = 'cancelled', version = version + 1 WHERE id = ? AND seller_id = ? AND status = 'active' AND bid_count = 0").bind(c.params[0], c.acct.id).run();
    if (!r.meta.changes) {
      const l = await c.db.prepare("SELECT bid_count FROM listings WHERE id = ? AND seller_id = ? AND status = 'active'").bind(c.params[0], c.acct.id).first<{ bid_count: number }>();
      if (l && l.bid_count > 0) fail("bad_request", "an auction with bids can't be cancelled");
      fail("not_found", "no active listing of yours with that id");
    }
    return { ok: true };
  });
}

// ------------------------------------------------------------------ buying

/** POST /v1/market/:id/buy: a fixed-price listing, or an auction's Buy It Now (before the first bid). */
export async function buy(c: Ctx) {
  const L = c.L;
  return L.withMarket(async () => {
    await settleDue(L, c.now, true);
    const id = c.params[0];
    const l = await c.db.prepare("SELECT * FROM listings WHERE id = ?").bind(id).first<ListingRow>();
    if (!l || l.status !== "active") fail("not_found", "that listing is gone");
    if (l!.seller_id === c.acct.id) fail("bad_request", "you can't buy your own card");
    const isAuction = l!.kind === "auction";
    if (isAuction && (l!.buy_now == null || l!.bid_count > 0)) fail("bad_request", "this is an auction: bid on it (Buy It Now is gone once bidding starts)");
    if (isAuction && (l!.ends_at ?? 0) <= c.now) fail("bad_request", "that auction has ended");
    const price = isAuction ? l!.buy_now! : l!.price;
    if (price > c.acct.money) fail("insufficient_funds", `that card costs $${price}`);
    const fee = Math.floor(price * MARKET_CUT);
    const { ok } = await moneyMove(c, {
      delta: -price, reason: "market_buy",
      cond: `EXISTS (SELECT 1 FROM listings l JOIN cards k ON k.id = l.card_id AND k.owner_id = l.seller_id WHERE l.id = ? AND l.status = 'active' AND l.version = ? AND l.seller_id != a.id)`,
      condArgs: [id, l!.version],
      then: tx => [
        c.db.prepare(`INSERT INTO ledger (id, account_id, delta, reason, at, season, syndicate_id) SELECT ?, a.id, ?, 'market_sale', ?, ?, a.syndicate_id FROM accounts a WHERE a.id = ? AND ${gate()}`)
          .bind(`sale:${tx}`, price - fee, c.now, L.state.season, l!.seller_id, tx),
        c.db.prepare(`UPDATE accounts SET money = money + ? WHERE id = ? AND ${gate()}`).bind(price - fee, l!.seller_id, tx),
        c.db.prepare(`UPDATE cards SET owner_id = ? WHERE id = ? AND owner_id = ? AND ${gate()}`).bind(c.acct.id, l!.card_id, l!.seller_id, tx),
        c.db.prepare(`UPDATE listings SET status = 'sold', buyer_id = ?, sold_at = ?, price = ?, version = version + 1 WHERE id = ? AND status = 'active' AND ${gate()}`).bind(c.acct.id, c.now, price, id, tx),
        saleStmt(c.db, id, isAuction ? "buy_now" : "fixed", price, L.state.season, c.now, tx),
        mailStmt(c, `sold:${tx}`, l!.seller_id, c.now, `Sold for $${price}`, [`${c.acct.name} bought your card${isAuction ? " with Buy It Now" : ""}.`, `After the house's 5% you got $${price - fee}.`], tx),
      ],
    });
    if (!ok) {
      const fresh = await c.db.prepare("SELECT status FROM listings WHERE id = ?").bind(id).first<{ status: string }>();
      if (fresh?.status !== "active") fail("not_found", "someone beat you to it");
      fail("insufficient_funds", "not enough money");
    }
    const card = await c.db.prepare("SELECT id, data FROM cards WHERE id = ?").bind(l!.card_id).first<{ id: string; data: string }>();
    return { card: cardView(L.world, card!.id, JSON.parse(card!.data) as Card), account: await accountView(c) };
  });
}

/** Price-history row for a completed sale (gated on `gateId` if given, else on the listing being sold). */
function saleStmt(db: D1Database, listingId: string, kind: string, price: number, season: number, at: number, gateId?: string): D1PreparedStatement {
  return db.prepare(`INSERT OR IGNORE INTO sales (id, def_id, card_id, rarity, serial, print_run, redeem, price, kind, season, at)
      SELECT l.id, COALESCE(l.def_id, json_extract(k.data, '$.id')), l.card_id, COALESCE(l.rarity, json_extract(k.data, '$.rarity')), k.serial, k.print_run,
        COALESCE(l.redeem, json_extract(k.data, '$.redeem.kind')), ?, ?, ?, ? FROM listings l JOIN cards k ON k.id = l.card_id WHERE l.id = ? ${gateId ? `AND ${gate()}` : ""}`)
    .bind(price, kind, season, at, listingId, ...(gateId ? [gateId] : []));
}

// ------------------------------------------------------------------ bidding

export interface AuctionState { price: number; startBid: number; reserve: number | null; leader: string | null; leaderMax: number; bids: number }
export interface BidOutcome {
  state: AuctionState;
  /** Money to hold from the bidder now (their max, or the raise of their own max). */
  hold: number;
  /** Previous leader to refund and notify, with the amount held for them. */
  outbid?: { account: string; amount: number };
  /** Bid history rows to write, in order. */
  history: { bidder: string; shown: number; auto: boolean }[];
  /** The bidder leads after this bid. */
  leading: boolean;
}

/** Proxy-bidding rules (pure). Throws HttpError on an invalid bid. */
export function applyBid(s: AuctionState, bidder: string, max: number): BidOutcome {
  const reserveJump = (price: number, topMax: number) => (s.reserve != null && price < s.reserve && topMax >= s.reserve ? s.reserve : price);
  if (!s.leader) {
    if (max < s.startBid) fail("bad_request", `the opening bid is at least $${s.startBid}`);
    const price = reserveJump(s.startBid, max);
    return { state: { ...s, price, leader: bidder, leaderMax: max, bids: s.bids + 1 }, hold: max, history: [{ bidder, shown: price, auto: false }], leading: true };
  }
  if (bidder === s.leader) {
    if (max <= s.leaderMax) fail("bad_request", `you're already winning; to raise your max, bid more than $${s.leaderMax}`);
    const price = reserveJump(s.price, max);
    return { state: { ...s, price, leaderMax: max, bids: s.bids + (price !== s.price ? 1 : 0) }, hold: max - s.leaderMax, history: price !== s.price ? [{ bidder, shown: price, auto: false }] : [], leading: true };
  }
  const minBid = s.price + increment(s.price);
  if (max < minBid) fail("bad_request", `bid at least $${minBid}`);
  if (max > s.leaderMax) {
    const price = reserveJump(Math.max(minBid, Math.min(max, s.leaderMax + increment(s.leaderMax))), max);
    return {
      state: { ...s, price, leader: bidder, leaderMax: max, bids: s.bids + 2 }, hold: max, outbid: { account: s.leader, amount: s.leaderMax },
      history: [{ bidder: s.leader, shown: s.leaderMax, auto: true }, { bidder, shown: price, auto: false }], leading: true,
    };
  }
  // the leader's proxy covers it: price rises to just above this bid (or to the leader's max on a tie)
  const price = reserveJump(Math.min(s.leaderMax, max + increment(max)), s.leaderMax);
  return {
    state: { ...s, price, bids: s.bids + 2 }, hold: 0,
    history: [{ bidder, shown: max, auto: false }, { bidder: s.leader, shown: price, auto: true }], leading: false,
  };
}

/** POST /v1/market/:id/bid { max } (alias: amount). Your max is secret; the system bids for you up to it. */
export async function bid(c: Ctx) {
  const L = c.L;
  const max = int(c.body, c.body.max !== undefined ? "max" : "amount", 1, 10_000_000);
  return L.withMarket(async () => {
    await settleDue(L, c.now, true);
    const l = await row(c, c.params[0]);
    if (!l || l.status !== "active") fail("not_found", "that listing is gone");
    if (l!.kind !== "auction") fail("bad_request", "that's a fixed-price listing: buy it instead");
    if ((l!.ends_at ?? 0) <= c.now) fail("bad_request", "that auction has ended");
    if (l!.seller_id === c.acct.id) fail("bad_request", "you can't bid on your own auction");
    const before: AuctionState = { price: l!.price, startBid: l!.start_bid ?? l!.price, reserve: l!.reserve, leader: l!.high_bidder_id, leaderMax: l!.max_bid, bids: l!.bid_count };
    const o = applyBid(before, c.acct.id, max);
    if (o.hold > c.acct.money) fail("insufficient_funds", `bidding $${max} holds $${o.hold} in escrow; you have $${c.acct.money}`);
    const endsAt = Math.max(l!.ends_at!, (l!.ends_at! - c.now) < SOFT_CLOSE_MS ? c.now + SOFT_CLOSE_MS : 0);
    const bidId = newId("b");
    const db = c.db;
    const stmts: D1PreparedStatement[] = [
      // gate: the bidder can cover the hold and the listing hasn't moved since we read it
      db.prepare(`INSERT INTO ledger (id, account_id, delta, reason, at, season, syndicate_id)
          SELECT ?, a.id, ?, 'bid_escrow', ?, ?, a.syndicate_id FROM accounts a WHERE a.id = ? AND a.money >= ?
            AND EXISTS (SELECT 1 FROM listings WHERE id = ? AND version = ? AND status = 'active')`)
        .bind(bidId, -o.hold, c.now, L.state.season, c.acct.id, o.hold, l!.id, l!.version),
      db.prepare(`UPDATE accounts SET money = money - ? WHERE id = ? AND ${gate()}`).bind(o.hold, c.acct.id, bidId),
    ];
    if (o.hold > 0) {
      stmts.push(db.prepare(`INSERT INTO holds (listing_id, account_id, amount) SELECT ?, ?, ? WHERE ${gate()} ON CONFLICT (listing_id, account_id) DO UPDATE SET amount = amount + excluded.amount`)
        .bind(l!.id, c.acct.id, o.hold, bidId));
    }
    if (o.outbid) {
      const prev = o.outbid.account;
      stmts.push(
        db.prepare(`INSERT INTO ledger (id, account_id, delta, reason, at, season, syndicate_id) SELECT ?, a.id, (SELECT amount FROM holds WHERE listing_id = ? AND account_id = a.id), 'bid_release', ?, ?, a.syndicate_id FROM accounts a WHERE a.id = ? AND ${gate()}`)
          .bind(`rel:${bidId}`, l!.id, c.now, L.state.season, prev, bidId),
        db.prepare(`UPDATE accounts SET money = money + COALESCE((SELECT amount FROM holds WHERE listing_id = ? AND account_id = ?), 0) WHERE id = ? AND ${gate()}`).bind(l!.id, prev, prev, bidId),
        db.prepare(`DELETE FROM holds WHERE listing_id = ? AND account_id = ? AND ${gate()}`).bind(l!.id, prev, bidId),
        mailStmt(c, `outbid:${bidId}`, prev, c.now, "You've been outbid", [`Someone outbid your max on ${cardName(l!)}. The bid is now $${o.state.price}.`, `Your $${o.outbid.amount} hold has been released.`], bidId),
      );
    }
    stmts.push(db.prepare(`UPDATE listings SET price = ?, high_bidder_id = ?, max_bid = ?, bid_count = ?, ends_at = ?, version = version + 1 WHERE id = ? AND version = ? AND ${gate()}`)
      .bind(o.state.price, o.state.leader, o.state.leaderMax, o.state.bids, endsAt, l!.id, l!.version, bidId));
    o.history.forEach((h, i) => stmts.push(db.prepare(`INSERT INTO bids (id, listing_id, bidder_id, max, shown, auto, at) SELECT ?, ?, ?, ?, ?, ?, ? WHERE ${gate()}`)
      .bind(`${bidId}:${i}`, l!.id, h.bidder, h.bidder === c.acct.id ? max : 0, h.shown, h.auto ? 1 : 0, c.now + i, bidId)));
    // a bidder watches what they bid on
    stmts.push(db.prepare(`INSERT OR IGNORE INTO watches (account_id, listing_id, at) SELECT ?, ?, ? WHERE ${gate()}`).bind(c.acct.id, l!.id, c.now, bidId));
    const res = await db.batch(stmts);
    if (!res[0].meta.changes) {
      const a = await db.prepare("SELECT money FROM accounts WHERE id = ?").bind(c.acct.id).first<{ money: number }>();
      if ((a?.money ?? 0) < o.hold) fail("insufficient_funds", "not enough money for that hold");
      fail("bad_request", "the auction changed; try again");
    }
    if (endsAt !== l!.ends_at) await L.armAlarm();
    const fresh = (await row(c, l!.id))!;
    return {
      listing: view(c, fresh, true), leading: o.leading,
      result: o.leading ? `You're the high bidder at $${o.state.price}. Your max ($${max}) is held in escrow.` : `Outbid instantly by another bidder's max. The bid is now $${o.state.price}.`,
      account: await accountView(c),
    };
  });
}

const cardName = (l: ListingRow) => {
  try {
    const d = JSON.parse(l.cdata) as Card;
    return `${d.set} #${d.number}`;
  } catch { return "a card"; }
};

// ------------------------------------------------------------------ settlement

/** Earliest end of an active auction (for the DO alarm). */
export async function nextAuctionEnd(L: League): Promise<number | undefined> {
  const r = await L.db.prepare("SELECT MIN(ends_at) AS t FROM listings WHERE status = 'active' AND kind = 'auction'").first<{ t: number | null }>();
  return r?.t ?? undefined;
}

/** Settle every auction that has ended. Idempotent: every statement requires the listing to still be active. */
export async function settleDue(L: League, now: number, locked = false): Promise<number> {
  const due = await L.db.prepare("SELECT 1 FROM listings WHERE status = 'active' AND kind = 'auction' AND ends_at <= ? LIMIT 1").bind(now).first();
  if (!due) return 0;
  return locked ? settleNow(L, now) : L.withMarket(() => settleNow(L, now));
}

async function settleNow(L: League, now: number): Promise<number> {
  const db = L.db;
  const rows = (await db.prepare(`${SELECT} WHERE l.status = 'active' AND l.kind = 'auction' AND l.ends_at <= ? ORDER BY l.ends_at LIMIT 50`).bind(now).all<ListingRow>()).results;
  const season = L.state.season;
  for (const l of rows) {
    const live = `EXISTS (SELECT 1 FROM listings WHERE id = '${l.id.replace(/'/g, "")}' AND status = 'active' AND version = ${Number(l.version)})`;
    const sold = l.bid_count > 0 && !!l.high_bidder_id && (l.reserve == null || l.price >= l.reserve);
    const stmts: D1PreparedStatement[] = [];
    const name = cardName(l);
    if (sold) {
      const price = l.price, fee = Math.floor(price * MARKET_CUT), winner = l.high_bidder_id!;
      stmts.push(
        db.prepare(`INSERT OR IGNORE INTO ledger (id, account_id, delta, reason, at, season, syndicate_id) SELECT ?, a.id, ?, 'auction_sale', ?, ?, a.syndicate_id FROM accounts a WHERE a.id = ? AND ${live}`)
          .bind(`settle:${l.id}`, price - fee, now, season, l.seller_id),
        db.prepare(`UPDATE accounts SET money = money + ? WHERE id = ? AND ${live}`).bind(price - fee, l.seller_id),
        db.prepare(`INSERT OR IGNORE INTO ledger (id, account_id, delta, reason, at, season, syndicate_id) SELECT ?, a.id, COALESCE((SELECT amount FROM holds WHERE listing_id = ? AND account_id = a.id), 0) - ?, 'escrow_refund', ?, ?, a.syndicate_id FROM accounts a WHERE a.id = ? AND ${live}`)
          .bind(`settle-ref:${l.id}`, l.id, price, now, season, winner),
        db.prepare(`UPDATE accounts SET money = money + MAX(0, COALESCE((SELECT amount FROM holds WHERE listing_id = ? AND account_id = ?), 0) - ?) WHERE id = ? AND ${live}`).bind(l.id, winner, price, winner),
        db.prepare(`UPDATE cards SET owner_id = ? WHERE id = ? AND owner_id = ? AND ${live}`).bind(winner, l.card_id, l.seller_id),
        db.prepare(`INSERT OR IGNORE INTO sales (id, def_id, card_id, rarity, serial, print_run, redeem, price, kind, season, at)
            SELECT l.id, COALESCE(l.def_id, json_extract(k.data, '$.id')), l.card_id, COALESCE(l.rarity, json_extract(k.data, '$.rarity')), k.serial, k.print_run, l.redeem, ?, 'auction', ?, ? FROM listings l JOIN cards k ON k.id = l.card_id WHERE l.id = ? AND ${live}`)
          .bind(price, season, now, l.id),
        db.prepare(`INSERT OR IGNORE INTO mail (id, account_id, at, read, kind, data) SELECT ?, ?, ?, 0, 'bank', ? WHERE ${live}`)
          .bind(`won:${l.id}`, winner, now, JSON.stringify({ from: "Diamond Exchange", subject: `You won ${name} for $${price}`, body: [`The card is in your binder.`, `Your escrow beyond $${price} has been returned.`] })),
        db.prepare(`INSERT OR IGNORE INTO mail (id, account_id, at, read, kind, data) SELECT ?, ?, ?, 0, 'bank', ? WHERE ${live}`)
          .bind(`sold:${l.id}`, l.seller_id, now, JSON.stringify({ from: "Diamond Exchange", subject: `Auction sold for $${price}`, body: [`${l.bid_count} bids. Winner: ${mask(l.leader)}.`, `After the house's 5% you got $${price - fee}.`] })),
        db.prepare(`DELETE FROM holds WHERE listing_id = ? AND ${live}`).bind(l.id),
        db.prepare("UPDATE listings SET status = 'sold', buyer_id = ?, sold_at = ?, version = version + 1 WHERE id = ? AND status = 'active' AND version = ?").bind(winner, now, l.id, l.version),
      );
    } else {
      const leader = l.high_bidder_id;
      if (leader) {
        stmts.push(
          db.prepare(`INSERT OR IGNORE INTO ledger (id, account_id, delta, reason, at, season, syndicate_id) SELECT ?, a.id, COALESCE((SELECT amount FROM holds WHERE listing_id = ? AND account_id = a.id), 0), 'bid_release', ?, ?, a.syndicate_id FROM accounts a WHERE a.id = ? AND ${live}`)
            .bind(`settle-rel:${l.id}`, l.id, now, season, leader),
          db.prepare(`UPDATE accounts SET money = money + COALESCE((SELECT amount FROM holds WHERE listing_id = ? AND account_id = ?), 0) WHERE id = ? AND ${live}`).bind(l.id, leader, leader),
          db.prepare(`INSERT OR IGNORE INTO mail (id, account_id, at, read, kind, data) SELECT ?, ?, ?, 0, 'bank', ? WHERE ${live}`)
            .bind(`unsold-b:${l.id}`, leader, now, JSON.stringify({ from: "Diamond Exchange", subject: "Reserve not met", body: [`The auction for ${name} ended below the seller's reserve.`, "Your escrow has been returned."] })),
          db.prepare(`DELETE FROM holds WHERE listing_id = ? AND ${live}`).bind(l.id),
        );
      }
      stmts.push(
        db.prepare(`INSERT OR IGNORE INTO mail (id, account_id, at, read, kind, data) SELECT ?, ?, ?, 0, 'bank', ? WHERE ${live}`)
          .bind(`unsold:${l.id}`, l.seller_id, now, JSON.stringify({ from: "Diamond Exchange", subject: "Auction ended unsold", body: [l.bid_count ? `${name} didn't reach your reserve (high bid $${l.price}).` : `Nobody bid on ${name}.`, "The card is back in your binder. Relist any time."] })),
        db.prepare("UPDATE listings SET status = 'ended', version = version + 1 WHERE id = ? AND status = 'active' AND version = ?").bind(l.id, l.version),
      );
    }
    await db.batch(stmts);
  }
  return rows.length;
}

// ------------------------------------------------------------------ watch list & history

export async function watch(c: Ctx) {
  const l = await c.db.prepare("SELECT 1 FROM listings WHERE id = ?").bind(c.params[0]).first();
  if (!l) fail("not_found", "no such listing");
  await c.db.prepare("INSERT OR IGNORE INTO watches (account_id, listing_id, at) VALUES (?,?,?)").bind(c.acct.id, c.params[0], c.now).run();
  return { ok: true, watching: true };
}

export async function unwatch(c: Ctx) {
  await c.db.prepare("DELETE FROM watches WHERE account_id = ? AND listing_id = ?").bind(c.acct.id, c.params[0]).run();
  return { ok: true, watching: false };
}

/** GET /v1/watchlist: listings you watch (active first, then recently ended), with your bid status. */
export async function watchlist(c: Ctx) {
  await settleDue(c.L, c.now);
  const rows = (await c.db.prepare(`${SELECT} JOIN watches w2 ON w2.listing_id = l.id AND w2.account_id = ?
      ORDER BY CASE WHEN l.status = 'active' THEN 0 ELSE 1 END, COALESCE(l.ends_at, l.created_at) ASC LIMIT 40`).bind(c.acct.id).all<ListingRow>()).results;
  return { listings: rows.map(r => view(c, r, true)) };
}

/** GET /v1/market/history?def=S1-042[&rarity=gilded]: recent sales of a card, with summary stats. */
export async function history(c: Ctx) {
  const def = c.q.get("def") ?? "";
  if (!/^[A-Za-z0-9-]{1,40}$/.test(def)) fail("bad_request", "def is required, e.g. ?def=S1-042");
  const rarity = c.q.get("rarity");
  const rows = (await c.db.prepare(`SELECT * FROM sales WHERE def_id = ? ${rarity ? "AND rarity = ?" : ""} ORDER BY at DESC LIMIT 30`)
    .bind(def, ...(rarity ? [rarity] : [])).all<{ price: number; rarity: string; serial: number | null; print_run: number | null; redeem: string | null; kind: string; at: number }>()).results;
  const prices = rows.map(r => r.price).sort((a, b) => a - b);
  const stored = await c.db.prepare("SELECT data FROM card_defs WHERE id = ?").bind(def).first<{ data: string }>();
  const d = stored ? (JSON.parse(stored.data) as { personId: string; set: string; number: number; setName?: string }) : undefined;
  return {
    def, ...(d ? { card: { person: personRef(c.L.world, d.personId), set: d.set, number: d.number } } : {}),
    sales: rows.map(r => ({
      price: r.price, rarity: r.rarity, ...(r.serial && r.print_run ? { serial: `${String(r.serial).padStart(String(r.print_run).length, "0")}/${r.print_run}` } : {}),
      ...(r.redeem ? { redeem: r.redeem } : {}), kind: r.kind, at: r.at,
    })),
    stats: prices.length ? {
      count: prices.length, low: prices[0], high: prices[prices.length - 1], median: prices[Math.floor(prices.length / 2)],
      avg: Math.round(prices.reduce((a, b) => a + b, 0) / prices.length), last: rows[0].price,
    } : { count: 0 },
  };
}
