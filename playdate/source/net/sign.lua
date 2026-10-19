--[[
  net/sign.lua — request signing for plain-HTTP API calls (see docs/API.md "Transport &
  signing"). A TLS handshake costs the Playdate ~3.6 s; plain HTTP ~0.3 s. Nothing we send
  is secret, so after ONE HTTPS call to get a signing key (POST /v1/register or
  POST /v1/auth/key), requests go over HTTP with:

    X-Acct: <account id>
    X-Seq:  <counter>
    X-Sig:  hex(HMAC-SHA256(key, METHOD .. "\n" .. target .. "\n" .. seq .. "\n" .. hex(SHA256(body))))

  `target` is the request target as sent ("/v1/batch?p=%2Fme"), `body` the exact JSON text.
  HMAC comes from the C extension (playdate/c/crypto.c, `dbcrypto`); without it (a pdc-only
  build) Signer.available() is false and everything stays on HTTPS.

  Replay protection is a per-account counter, not a timestamp (Playdate numbers can't hold
  epoch seconds). The counter is persisted in the datastore every SEQ_PERSIST requests and
  jumps SEQ_JUMP ahead on every boot, so a crash never reuses a value. The server accepts
  each seq once within a window of 128 below the highest seen.
]]

Signer = Signer or {}

local SEQ_JUMP <const> = 1000
local SEQ_PERSIST <const> = 500
local SEQ_MAX <const> = 2000000000   -- server limit is 2^31-1

local cur = nil        -- { scope, tok, id, key }
local seq = 0
local persisted = 0
local scope = nil

local function tokHash(t)
  if not t then return nil end
  return (DiskCache and DiskCache.hash and (DiskCache.hash(t) .. DiskCache.hash(t:reverse()))) or tostring(#t)
end

function Signer.available()
  return dbcrypto ~= nil and dbcrypto.hmac_sha256_hex ~= nil and dbcrypto.sha256_hex ~= nil
end

local function persistSeq()
  local all = playdate.datastore.read("sigseq")
  if type(all) ~= "table" then all = {} end
  all[scope] = seq
  playdate.datastore.write(all, "sigseq")
  persisted = seq
end

--- Selects the key store for a host (Api.configure) and loads its key + counter.
function Signer.setScope(s)
  if s == scope then return end
  scope = s
  cur = nil
  seq, persisted = 0, 0
  if not s then return end
  local keys = playdate.datastore.read("signkeys")
  local k = type(keys) == "table" and keys[s] or nil
  if type(k) == "table" and k.key and k.id then cur = { tok = k.tok, id = k.id, key = k.key } end
  local all = playdate.datastore.read("sigseq")
  local n = type(all) == "table" and tonumber(all[s]) or 0
  -- jump ahead: requests after the last persist may have used up to SEQ_PERSIST more
  seq = math.min(SEQ_MAX - SEQ_JUMP, (n or 0)) + SEQ_JUMP
  if seq >= SEQ_MAX then seq = SEQ_JUMP end
  persistSeq()
end

--- True when we hold a key for this account (token).
function Signer.has(token)
  return cur ~= nil and token ~= nil and cur.tok == tokHash(token)
end

function Signer.accountId() return cur and cur.id end

function Signer.setKey(id, key, token)
  if not scope or not id or not key then return end
  cur = { tok = tokHash(token), id = id, key = key }
  local keys = playdate.datastore.read("signkeys")
  if type(keys) ~= "table" then keys = {} end
  keys[scope] = cur
  playdate.datastore.write(keys, "signkeys")
  print("[sign] key stored for " .. tostring(id))
end

--- Forget the key (the server rejected it); the next request fetches a new one over HTTPS.
function Signer.drop()
  if not cur then return end
  cur = nil
  local keys = playdate.datastore.read("signkeys")
  if type(keys) == "table" and scope then keys[scope] = nil playdate.datastore.write(keys, "signkeys") end
  print("[sign] key dropped")
end

--- Adds X-Acct / X-Seq / X-Sig to headers for METHOD target body.
function Signer.sign(headers, method, target, body)
  seq += 1
  if seq >= SEQ_MAX then seq = SEQ_JUMP end   -- a fresh key (and window) follows any rejection
  if seq - persisted >= SEQ_PERSIST then persistSeq() end
  local msg = method .. "\n" .. target .. "\n" .. seq .. "\n" .. dbcrypto.sha256_hex(body or "")
  headers["X-Acct"] = cur.id
  headers["X-Seq"] = tostring(seq)
  headers["X-Sig"] = dbcrypto.hmac_sha256_hex(cur.key, msg)
  return seq
end

--- RFC 4231 / FIPS known answers through the Lua binding (Simulator check; Debug prints it).
function Signer.selftest()
  if not Signer.available() then return false, "no dbcrypto (pdc-only build)" end
  local ok = dbcrypto.selftest and dbcrypto.selftest() or false
  local h = dbcrypto.hmac_sha256_hex
  ok = ok and h("Jefe", "what do ya want for nothing?") == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
  ok = ok and h(string.rep("\x0b", 20), "Hi There") == "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
  ok = ok and h(string.rep("\xaa", 131), "Test Using Larger Than Block-Size Key - Hash Key First") == "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"
  ok = ok and dbcrypto.sha256_hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  ok = ok and dbcrypto.sha256_hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  return ok
end
