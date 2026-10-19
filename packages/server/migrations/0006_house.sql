-- Bobby's regulars (src/house.ts): house (NPC) money in every bettable pool. The stakes are
-- minted, never an account's: they live here as wave schedules, JSON [{ k, off, a }] where a wave
-- lands `off` ms before the pool's anchor (games: first_pitch_at, props: closes_at) and `a` is the
-- amount per option (games: [home, away]; props: in `options` order). NULL = no house money.
ALTER TABLE games ADD COLUMN house TEXT;
ALTER TABLE props ADD COLUMN house TEXT;
