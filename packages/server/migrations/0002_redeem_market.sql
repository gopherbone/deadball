-- Redeemable cards and the auction market.

-- ---------------------------------------------------------------- redeemable cards
-- One row per redeemed card. The id doubles as the idempotency key for the final write.
CREATE TABLE redemptions (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL,
  card_id TEXT NOT NULL UNIQUE,
  kind TEXT NOT NULL,              -- boost | retire
  person_id TEXT NOT NULL,
  team_id TEXT,
  season INTEGER NOT NULL,
  day INTEGER NOT NULL,
  card TEXT NOT NULL,
  result TEXT NOT NULL,
  story_id TEXT,
  created_at INTEGER NOT NULL
);
CREATE INDEX redemptions_at ON redemptions (created_at);

-- Boost modifiers injected into game specs while world.day is in [from_day, until_day].
CREATE TABLE redeem_mods (
  id TEXT PRIMARY KEY,
  redemption_id TEXT NOT NULL,
  person_id TEXT NOT NULL,
  from_day INTEGER NOT NULL,
  until_day INTEGER NOT NULL,
  data TEXT NOT NULL
);
CREATE INDEX redeem_mods_days ON redeem_mods (until_day, from_day);

-- People retired by a redeemed card: their cards (old and new pulls) are "Final Season" editions.
CREATE TABLE retired_people (
  person_id TEXT PRIMARY KEY,
  redemption_id TEXT NOT NULL,
  at INTEGER NOT NULL
);

-- ---------------------------------------------------------------- market: auctions
-- Fixed-price listings keep working as before (kind = 'fixed', price = asking price).
-- Auctions: price = current bid (or the starting bid before any bids).
ALTER TABLE listings ADD COLUMN kind TEXT NOT NULL DEFAULT 'fixed';
ALTER TABLE listings ADD COLUMN start_bid INTEGER;
ALTER TABLE listings ADD COLUMN reserve INTEGER;          -- hidden; only "reserve met / not met" is shown
ALTER TABLE listings ADD COLUMN buy_now INTEGER;          -- available until the first bid
ALTER TABLE listings ADD COLUMN ends_at INTEGER;
ALTER TABLE listings ADD COLUMN high_bidder_id TEXT;
ALTER TABLE listings ADD COLUMN max_bid INTEGER NOT NULL DEFAULT 0;   -- leader's proxy max (hidden)
ALTER TABLE listings ADD COLUMN bid_count INTEGER NOT NULL DEFAULT 0;
ALTER TABLE listings ADD COLUMN version INTEGER NOT NULL DEFAULT 0;
-- denormalized card facts for search/filter
ALTER TABLE listings ADD COLUMN def_id TEXT;
ALTER TABLE listings ADD COLUMN rarity TEXT;
ALTER TABLE listings ADD COLUMN redeem TEXT;              -- boost | retire | NULL
ALTER TABLE listings ADD COLUMN person_id TEXT;
ALTER TABLE listings ADD COLUMN team_id TEXT;
CREATE INDEX listings_open ON listings (status, kind, ends_at);

-- Bid history. shown = the visible bid amount; auto = 1 for proxy bids placed by the system.
CREATE TABLE bids (
  id TEXT PRIMARY KEY,
  listing_id TEXT NOT NULL,
  bidder_id TEXT NOT NULL,
  max INTEGER NOT NULL,
  shown INTEGER NOT NULL,
  auto INTEGER NOT NULL DEFAULT 0,
  at INTEGER NOT NULL
);
CREATE INDEX bids_listing ON bids (listing_id, at);

-- Escrow: money held from the leading bidder (their max). Released when outbid or unsold.
CREATE TABLE holds (
  listing_id TEXT NOT NULL,
  account_id TEXT NOT NULL,
  amount INTEGER NOT NULL CHECK (amount >= 0),
  PRIMARY KEY (listing_id, account_id)
);
CREATE INDEX holds_account ON holds (account_id);

CREATE TABLE watches (
  account_id TEXT NOT NULL,
  listing_id TEXT NOT NULL,
  at INTEGER NOT NULL,
  PRIMARY KEY (account_id, listing_id)
);
CREATE INDEX watches_listing ON watches (listing_id);

-- Completed sales (fixed, buy-it-now, auction): price history per card def.
CREATE TABLE sales (
  id TEXT PRIMARY KEY,             -- the listing id
  def_id TEXT NOT NULL,
  card_id TEXT NOT NULL,
  rarity TEXT NOT NULL,
  serial INTEGER,
  print_run INTEGER,
  redeem TEXT,
  price INTEGER NOT NULL,
  kind TEXT NOT NULL,              -- fixed | buy_now | auction
  season INTEGER NOT NULL,
  at INTEGER NOT NULL
);
CREATE INDEX sales_def ON sales (def_id, at);
