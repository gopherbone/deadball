-- Syndicate "chip in": the orderer of a joint job proposes a split (sim splitCost) and each ally
-- whose crew is on it accepts or declines before the job locks. The orderer pays the whole cost
-- up front; an accepted share moves that amount from the ally back to the orderer (ledger
-- chip_in / chip_in_back). A cancelled or called-off job refunds the orderer's part and every
-- paid share (ledger op_refund).
--   status: proposed -> paid | declined | expired (job locked) | void (job cancelled before an answer)
--           paid -> refunding -> refunded (job cancelled)
CREATE TABLE op_shares (
  op_id TEXT NOT NULL,
  account_id TEXT NOT NULL,
  amount INTEGER NOT NULL CHECK (amount >= 0),
  status TEXT NOT NULL DEFAULT 'proposed',
  created_at INTEGER NOT NULL,
  decided_at INTEGER,
  PRIMARY KEY (op_id, account_id)
);
CREATE INDEX op_shares_account ON op_shares (account_id, status);
