-- Staggered first pitches (src/schedule.ts): every aired game has its own first pitch and air
-- time, already stored per row (games.first_pitch_at, games.air_ms), so no new columns. These
-- indexes serve what now runs on every alarm and every /today and /clock: the next broadcast to
-- end (per-game settlement) and the games on the air right now.
CREATE INDEX IF NOT EXISTS games_first_pitch ON games (first_pitch_at);
CREATE INDEX IF NOT EXISTS games_unsettled ON games (settled, simmed, first_pitch_at);
