-- Drama props: pari-mutuel markets on storylines (docs/DRAMA.md "Prop markets").

-- One row per prop question ("<storylineId>:yes|when|how"). Only rumoured/public storylines
-- ever get rows, so nothing here can name a secret arc.
CREATE TABLE props (
  id TEXT PRIMARY KEY,
  storyline_id TEXT NOT NULL,
  season INTEGER NOT NULL,
  kind TEXT NOT NULL,              -- storyline kind (affair, feud, ...)
  type TEXT NOT NULL,              -- yesno | buckets
  question TEXT NOT NULL,
  options TEXT NOT NULL,           -- JSON [{ key, label }]
  closes_day INTEGER NOT NULL,     -- world.day: betting closes at the end of it
  resolve_by INTEGER NOT NULL,
  closes_at INTEGER NOT NULL,      -- epoch ms estimate of closes_day's end (re-timed with the clock)
  status TEXT NOT NULL DEFAULT 'open',   -- open | closed | settled | refunded
  outcome TEXT,
  settled_at INTEGER,
  created_at INTEGER NOT NULL
);
CREATE INDEX props_status ON props (status, closes_at);
CREATE INDEX props_storyline ON props (storyline_id);

-- Pools are the sums of these rows. One option per account per question (top-ups allowed).
CREATE TABLE prop_bets (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL,
  prop_id TEXT NOT NULL,
  option TEXT NOT NULL,
  amount INTEGER NOT NULL CHECK (amount > 0),
  status TEXT NOT NULL DEFAULT 'open',   -- open | paying | settled
  payout INTEGER NOT NULL DEFAULT 0,
  placed_at INTEGER NOT NULL,
  settled_at INTEGER,
  UNIQUE (account_id, prop_id)
);
CREATE INDEX prop_bets_prop ON prop_bets (prop_id, status);
CREATE INDEX prop_bets_account ON prop_bets (account_id, status, placed_at);

-- Front page order: newest batch first, then the most prominent story within it.
ALTER TABLE stories ADD COLUMN prominence REAL NOT NULL DEFAULT 1;
CREATE INDEX stories_front ON stories (publish_at, prominence);

-- Storyline ops (crew jobs on drama arcs): the arc a job works on and the nudge it asked for.
-- Storyline-only jobs have game_id = '' and resolve at the next day's play.
ALTER TABLE ops ADD COLUMN storyline_id TEXT;
ALTER TABLE ops ADD COLUMN nudge TEXT;
CREATE INDEX ops_planned ON ops (status, game_id);

-- Secret storylines an account learned about from a tip (MailItem.storylineId). They become
-- op targets and "you heard..." rows on that account's Gossip Board, and nobody else's.
CREATE TABLE known_storylines (
  account_id TEXT NOT NULL,
  storyline_id TEXT NOT NULL,
  at INTEGER NOT NULL,
  PRIMARY KEY (account_id, storyline_id)
);
