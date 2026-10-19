-- DEADBALL D1 schema. Money columns carry CHECK (>= 0) so any batch that would
-- overdraw an account fails and rolls back as a whole.

CREATE TABLE accounts (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  name_lc TEXT NOT NULL UNIQUE,
  token_hash TEXT NOT NULL UNIQUE,
  money INTEGER NOT NULL DEFAULT 1000 CHECK (money >= 0),
  heat INTEGER NOT NULL DEFAULT 0,
  joined_day INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  free_packs INTEGER NOT NULL DEFAULT 1 CHECK (free_packs >= 0),
  syndicate_id TEXT,
  last_comment_at INTEGER NOT NULL DEFAULT 0,
  comment_day TEXT NOT NULL DEFAULT '',
  comments_today INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX accounts_syndicate ON accounts (syndicate_id);

-- Every money movement. Inserted first in a batch as the "gate": later statements in the
-- batch only act if the ledger row with that id exists.
CREATE TABLE ledger (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL,
  delta INTEGER NOT NULL,
  reason TEXT NOT NULL,
  at INTEGER NOT NULL,
  season INTEGER NOT NULL DEFAULT 1,
  syndicate_id TEXT
);
CREATE INDEX ledger_account ON ledger (account_id, at);
CREATE INDEX ledger_syndicate ON ledger (syndicate_id, season);

-- Major- and minor-league games known to the API (written by the League DO).
CREATE TABLE games (
  id TEXT PRIMARY KEY,
  season INTEGER NOT NULL,
  day INTEGER NOT NULL,
  level TEXT NOT NULL,
  slot INTEGER NOT NULL DEFAULT 0,
  home_id TEXT NOT NULL,
  away_id TEXT NOT NULL,
  umpire_id TEXT NOT NULL,
  weather TEXT NOT NULL,
  first_pitch_at INTEGER NOT NULL,
  air_ms INTEGER NOT NULL,
  simmed INTEGER NOT NULL DEFAULT 0,
  settled INTEGER NOT NULL DEFAULT 0,
  home_runs INTEGER,
  away_runs INTEGER,
  innings INTEGER,
  winner TEXT,
  pool_home INTEGER NOT NULL DEFAULT 0,
  pool_away INTEGER NOT NULL DEFAULT 0,
  probables TEXT,
  summary TEXT,
  story_id TEXT,
  has_log INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX games_day ON games (season, day, level);
CREATE INDEX games_home ON games (home_id, season, day);
CREATE INDEX games_away ON games (away_id, season, day);

CREATE TABLE bets (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL,
  game_id TEXT NOT NULL,
  side TEXT NOT NULL CHECK (side IN ('home', 'away')),
  amount INTEGER NOT NULL CHECK (amount > 0),
  status TEXT NOT NULL DEFAULT 'open',
  payout INTEGER NOT NULL DEFAULT 0,
  placed_at INTEGER NOT NULL,
  settled_at INTEGER,
  UNIQUE (account_id, game_id)
);
CREATE INDEX bets_game ON bets (game_id, status);
CREATE INDEX bets_account ON bets (account_id, status, placed_at);

CREATE TABLE crew (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL,
  person_id TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT '',
  note TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'free',
  data TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX crew_account ON crew (account_id, status);

-- recruit candidates already hired (so a candidate can't be hired twice)
CREATE TABLE hired (
  candidate_id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL
);

CREATE TABLE ops (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL,
  syndicate_id TEXT,
  kind TEXT NOT NULL,
  game_id TEXT NOT NULL,
  target_team_id TEXT NOT NULL,
  crew TEXT NOT NULL,
  gear TEXT NOT NULL,
  placed_day INTEGER NOT NULL,
  season INTEGER NOT NULL DEFAULT 1,
  cost INTEGER NOT NULL,
  status TEXT NOT NULL DEFAULT 'planned',
  result TEXT,
  arrests INTEGER NOT NULL DEFAULT 0,
  outcome TEXT,
  created_at INTEGER NOT NULL
);
CREATE INDEX ops_game ON ops (game_id, status);
CREATE INDEX ops_account ON ops (account_id, created_at);
CREATE INDEX ops_syndicate ON ops (syndicate_id, season);

CREATE TABLE mail (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL,
  at INTEGER NOT NULL,
  read INTEGER NOT NULL DEFAULT 0,
  kind TEXT NOT NULL,
  data TEXT NOT NULL
);
CREATE INDEX mail_account ON mail (account_id, at);

CREATE TABLE events (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL,
  at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  data TEXT NOT NULL,
  result TEXT
);
CREATE INDEX events_account ON events (account_id, status, at);

CREATE TABLE card_defs (
  id TEXT PRIMARY KEY,
  season INTEGER NOT NULL,
  data TEXT NOT NULL
);

-- serial counters keyed by the cards module's mint key ("<defId>:<rarity>")
CREATE TABLE serials (
  def_id TEXT PRIMARY KEY,
  n INTEGER NOT NULL
);

CREATE TABLE cards (
  id TEXT PRIMARY KEY,
  def_id TEXT NOT NULL,
  owner_id TEXT NOT NULL,
  serial INTEGER,
  print_run INTEGER,
  data TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX cards_owner ON cards (owner_id, created_at);

CREATE TABLE listings (
  id TEXT PRIMARY KEY,
  card_id TEXT NOT NULL,
  seller_id TEXT NOT NULL,
  price INTEGER NOT NULL CHECK (price > 0),
  status TEXT NOT NULL DEFAULT 'active',
  search TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL,
  buyer_id TEXT,
  sold_at INTEGER
);
CREATE UNIQUE INDEX listings_active_card ON listings (card_id) WHERE status = 'active';
CREATE INDEX listings_status ON listings (status, created_at);

CREATE TABLE threads (
  id TEXT PRIMARY KEY,
  comment_count INTEGER NOT NULL DEFAULT 0,
  last_at INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE comments (
  id TEXT PRIMARY KEY,
  thread TEXT NOT NULL,
  author_id TEXT NOT NULL,
  template TEXT NOT NULL,
  words TEXT NOT NULL,
  text TEXT NOT NULL,
  at INTEGER NOT NULL,
  agree INTEGER NOT NULL DEFAULT 0,
  lol INTEGER NOT NULL DEFAULT 0,
  rat INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX comments_thread ON comments (thread, at);

CREATE TABLE reactions (
  comment_id TEXT NOT NULL,
  account_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  PRIMARY KEY (comment_id, account_id, kind)
);

CREATE TABLE stories (
  id TEXT PRIMARY KEY,
  season INTEGER NOT NULL,
  day INTEGER NOT NULL,
  kind TEXT NOT NULL,
  headline TEXT NOT NULL,
  publish_at INTEGER NOT NULL,
  game_id TEXT,
  data TEXT NOT NULL
);
CREATE INDEX stories_publish ON stories (publish_at);

CREATE TABLE visitors (
  page TEXT PRIMARY KEY,
  n INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE syndicates (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  name_lc TEXT NOT NULL UNIQUE,
  founder_id TEXT NOT NULL,
  treasury INTEGER NOT NULL DEFAULT 0 CHECK (treasury >= 0),
  created_at INTEGER NOT NULL,
  created_season INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE syndicate_invites (
  id TEXT PRIMARY KEY,
  syndicate_id TEXT NOT NULL,
  from_id TEXT NOT NULL,
  to_id TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  created_at INTEGER NOT NULL
);
CREATE INDEX invites_to ON syndicate_invites (to_id, status);
