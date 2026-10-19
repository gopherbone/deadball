-- Signed plain-HTTP requests (docs/API.md "Transport & signing"): each account gets a 256-bit
-- HMAC key (64 hex chars), issued by POST /v1/register or POST /v1/auth/key over HTTPS.
-- The replay window (highest seq + recently seen seqs) lives in the League DO's SQLite.
ALTER TABLE accounts ADD COLUMN sign_key TEXT;
