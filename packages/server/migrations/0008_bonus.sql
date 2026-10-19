-- Bobby's Loyalty Club (a daily punch card) and Odd Jobs (small per-game-day tasks). See
-- docs/API.md "Loyalty card & odd jobs" and src/routes/bonus.ts. Every payout is a ledger row
-- with a deterministic id (punch:<acct>:<n-th punch>, job:<acct>:<period>:<slot>), so a retried
-- request can never pay twice: the second insert hits the ledger's primary key and the whole
-- batch rolls back.

-- One row per punch. utc_day = days since 1970-01-01 (UTC); the newest row is the card's state.
--   hole   1..7 on the current card (7 = the free pack); a new card starts at 1
--   streak consecutive real days (one missed day forgiven per card)
--   grace  1 once this card has used its one forgiven day
CREATE TABLE punches (
  account_id TEXT NOT NULL,
  utc_day INTEGER NOT NULL,
  hole INTEGER NOT NULL,
  streak INTEGER NOT NULL,
  grace INTEGER NOT NULL DEFAULT 0,
  cash INTEGER NOT NULL DEFAULT 0,
  packs INTEGER NOT NULL DEFAULT 0,
  at INTEGER NOT NULL,
  PRIMARY KEY (account_id, utc_day)
);

-- The account's odd jobs: 3 per game day (period "s<season>d<day>", slots 0-2) and one weekly
-- job (period "w<utc week>", slot 9). Picked when first shown, then fixed for the period.
-- Progress counts actions in [from_at, to_at); a job can be claimed until claim_until.
CREATE TABLE odd_jobs (
  account_id TEXT NOT NULL,
  period TEXT NOT NULL,
  slot INTEGER NOT NULL,
  kind TEXT NOT NULL,
  need INTEGER NOT NULL,
  cash INTEGER NOT NULL DEFAULT 0,
  packs INTEGER NOT NULL DEFAULT 0,
  heat INTEGER NOT NULL DEFAULT 0,
  from_at INTEGER NOT NULL,
  to_at INTEGER NOT NULL,
  claim_until INTEGER NOT NULL,
  claimed_at INTEGER,
  claim_day INTEGER,             -- utc day of the claim (the daily petty-cash cap)
  created_at INTEGER NOT NULL,
  PRIMARY KEY (account_id, period, slot)
);
CREATE INDEX odd_jobs_claims ON odd_jobs (account_id, claim_day);

-- Things that happened that the other tables can't date: an underdog bet, a reaction, a replay
-- watched to the final out, a story read. One row per (account, kind, ref), so the same game or
-- comment never counts twice.
CREATE TABLE bonus_marks (
  account_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  ref TEXT NOT NULL,
  at INTEGER NOT NULL,
  PRIMARY KEY (account_id, kind, ref)
);
CREATE INDEX bonus_marks_at ON bonus_marks (account_id, kind, at);

-- comment activity by author (odd jobs count posts per window)
CREATE INDEX IF NOT EXISTS comments_author ON comments (author_id, at);
