--[[
  net/api.lua — the one way the client talks to the league server.

  USAGE (stable contract; other modules such as ballcast/ and cards/ rely on it):

    Api.get(path, cb [, opts])          -- GET  /v1<path>
    Api.post(path, body, cb [, opts])   -- POST /v1<path> with a JSON body (table or nil)
    Api.delete(path, cb [, opts])       -- DELETE /v1<path>

      path  e.g. "/today", "/games/g12/log?from=40" (leading slash, no "/v1")
      cb    function(err, data)  -- ALWAYS called asynchronously (never inside the call)
              err  nil on success, else { code = "name_taken" | "timeout" | "offline" | ...,
                                           message = "human text", status = 409 }
              data decoded JSON table on success
      opts  { fresh = true }   -- GET: bypass the response cache
            { ttl = ms }       -- GET: cache lifetime (default 20 s; 0 = don't cache)
            { retries = n }    -- override retry count (GET default 2, POST/DELETE 0)
            { single = true }  -- GET: never fold into a /batch request
            { bg = true }      -- GET: background prefetch (held while Api.holdBackground()
                                  says so; dropped instead of retried singly if /batch is missing)

    Api.now()            server time in epoch ms (uses the /clock offset)
    Api.busy()           number of requests queued or in flight (drives the throbber)
    Api.invalidate(pfx)  drop cached GETs whose path starts with pfx ("" = everything)
    Api.isFixtureMode()  true when no host is configured (offline fixtures)
    Api.update()         call once per frame from playdate.update (main.lua does this)
    Api.peek(path)       -> data, ageSec, fresh: the newest copy we have (memory cache, even
                         expired, else the disk cache; nil if none). For painting stale.
    Api.prefetch(paths, done)  background GETs that only fill the caches; done(nOk, nErr)

  BATCHING. Connection setup on the device costs 7-11 s (Wi-Fi wake + DNS + TCP + TLS);
  bytes are nearly free. So GETs queued in the same frame are sent as ONE
  `GET /v1/batch?p=...&p=...` and the results fan back out to the same cache, dedupe and
  callbacks as single GETs (each item is rebased with Api.rebaseTimes exactly like a single
  response). Writes are never batched. If the server answers 404 to /batch the client
  falls back to singles for this host; fixture mode never batches. Every successful GET
  also lands in the disk cache (net/diskcache.lua) for stale-while-revalidate.

  TRANSPORT (live server, Api.config.ssl = true). A TLS handshake costs the device ~3.6 s
  and they queue on the Wi-Fi chip; plain HTTP costs ~0.3 s. So:
    - /register and /auth/key (which return secrets) go over HTTPS with the bearer token;
    - everything else goes over plain HTTP (port 80) signed with HMAC (net/sign.lua);
      the bearer token never travels over HTTP. A missing key is fetched automatically
      (POST /auth/key over HTTPS, other requests wait for it); a 401 bad_signature /
      replayed drops the key, fetches a new one and retries once.
    - Without a token only public paths exist (/clock): plain HTTP, unsigned.
    - Api.config.forceHttps (Settings), or no `dbcrypto` C extension: HTTPS + bearer.
    - At most 1 HTTPS connection at a time (handshakes serialize anyway), 2 over HTTP.
  With Api.config.ssl = false (a dev server, e.g. wrangler dev on localhost) everything
  goes plain HTTP to the configured port, signed when a key is held.
  Api.transport() -> "https" | "signed http" | "fixtures" ... for the Settings page.

  BUILD GATE. Every request carries `X-Build: <pdxinfo buildNumber>` (Api.BUILD). The server
  answers 426 `upgrade_required` (body has minBuild) to builds older than its MIN_BUILD. The
  first 426 sets Api.blocked = { build, minBuild, message }: everything queued fails with that
  error, new requests fail at once without touching the network (no polling, no prefetch) until
  the game is relaunched or pointed at another server, and Api.onUpgradeRequired(info) runs
  once (app/upgrade.lua shows the "update required" page). Fixture mode is never gated.

  FIXTURE MODE is the default when no server host is configured (Settings > Server).
  Paths map to JSON files (see net/fixtures.lua) with 120-500 ms of simulated latency.
]]

local net <const> = playdate.network

Api = Api or {}

local MAX_CONN <const> = 4        -- fixture mode
local MAX_HTTPS <const> = 1       -- TLS handshakes queue on the Wi-Fi chip: one at a time
local MAX_HTTP <const> = 2
local HTTP_PORT <const> = 80
local TIMEOUT_MS <const> = 15000
local BATCH_TIMEOUT_MS <const> = 20000
local KEY_RETRY_MS <const> = 60000
local SECURE_PATHS <const> = { ["/register"] = true, ["/auth/key"] = true }
local DEFAULT_TTL <const> = 20000
local MAX_BATCH <const> = 16   -- server cap (packages/server/src/router.ts BATCH_MAX_ITEMS)

local queue = {}        -- pending requests
local active = {}       -- in-flight requests
local cache = {}        -- path -> { at, data }
local inflightGets = {} -- path -> request (dedupe)
local deferred = {}     -- callbacks to run next frame
local clockOffset = 0   -- server ms - local ms

Api.config = { host = "", port = 443, ssl = true, forceHttps = false }
--- This build's number (pdxinfo buildNumber), sent as X-Build on every request.
Api.BUILD = tonumber(playdate.metadata and playdate.metadata.buildNumber) or 0
Api.blocked = nil       -- set by a 426 upgrade_required: { build, minBuild, message }
Api.onUpgradeRequired = nil -- function(info), called (next frame) when the server first says 426
Api.batching = true     -- coalesce same-frame GETs into /v1/batch (live server only)
Api.batchOff = false    -- set when the server answered 404 to /batch (reset by configure)
Api.holdBackground = nil -- optional function() -> true to keep bg (prefetch) GETs queued
Api.ACCESS_REASON = "DEADBALL talks to the league server for games and news and bets."

--- Shows the OS network-permission prompt up front (call from playdate.update context).
function Api.requestAccess()
  if Api.isFixtureMode() or Api.accessAsked then return end
  Api.accessAsked = true
  local cfg = Api.config
  pcall(net.http.requestAccess, cfg.host, cfg.port, cfg.ssl, Api.ACCESS_REASON)
end
Api.token = nil

-- Time. Epoch milliseconds don't fit Playdate Lua numbers (32-bit ints / single floats),
-- and the JSON decoder mangles 13-digit values. So the client never uses epoch time:
-- Api.now() is the device's own millisecond counter, and every response is rebased onto
-- it from the server's relative fields (`fooIn` seconds -> `fooAt`, `ago` -> `at`).
local function localMs()
  return playdate.getCurrentTimeMilliseconds()
end

function Api.now()
  return localMs() + clockOffset
end

--- Kept for compatibility; absolute server times are no longer used.
function Api.setClock(_) end

--- Rewrite relative time fields into Api.now()-based absolute ones, in place.
function Api.rebaseTimes(t, base)
  if type(t) ~= "table" then return t end
  base = base or Api.now()
  for k, v in pairs(t) do
    if type(v) == "table" then
      Api.rebaseTimes(v, base)
    elseif type(v) == "number" and type(k) == "string" then
      if k == "ago" then
        t.at = base - v * 1000
      elseif #k > 2 and k:sub(-2) == "In" then
        t[k:sub(1, -3) .. "At"] = base + v * 1000
      end
    end
  end
  return t
end

function Api.isFixtureMode()
  return not Api.config.host or Api.config.host == ""
end

-- The disk cache is per host + account (token), and off in fixture mode.
local function updateDiskScope()
  if not DiskCache then return end
  if Api.isFixtureMode() or not Api.token then
    DiskCache.setScope(nil)
  else
    DiskCache.setScope(Api.config.host .. ":" .. tostring(Api.config.port) .. "|" .. Api.token)
  end
end

local keyState = { req = nil, retryAt = 0 }

function Api.configure(cfg)
  -- a different server may take this build: the gate is per host
  local port = tonumber(cfg.port) or (cfg.ssl == false and 80 or 443)
  if Api.blocked and ((cfg.host or "") ~= Api.config.host or port ~= Api.config.port) then Api.blocked = nil end
  Api.config.host = cfg.host or ""
  Api.config.port = tonumber(cfg.port) or (cfg.ssl == false and 80 or 443)
  Api.config.ssl = cfg.ssl ~= false
  Api.config.forceHttps = cfg.forceHttps == true
  Api.batchOff = false
  keyState.retryAt = 0
  Api.invalidate("")
  updateDiskScope()
  if Signer then Signer.setScope(not Api.isFixtureMode() and (Api.config.host .. ":" .. tostring(Api.config.port)) or nil) end
end

local function canSign()
  return Signer ~= nil and Signer.available() and not Api.config.forceHttps
end

--- How a request travels: returns ssl, port, auth ("bearer" | "signed" | "none"), or
--- "wait" while a signing key is being fetched.
local function transportFor(req)
  local cfg = Api.config
  local base = req.path:match("^[^?]*")
  local secure = SECURE_PATHS[base]
  local plainPort = cfg.ssl and HTTP_PORT or cfg.port
  if secure or not canSign() then
    return cfg.ssl, cfg.port, Api.token and "bearer" or "none"
  end
  if not Api.token then return false, plainPort, "none" end    -- public paths only
  if Signer.has(Api.token) then return false, plainPort, "signed" end
  if keyState.req then return "wait" end
  -- no key and the last fetch failed recently: HTTPS + bearer meanwhile
  return cfg.ssl, cfg.port, "bearer"
end

--- Human summary for Settings.
function Api.transport()
  if Api.isFixtureMode() then return "offline fixtures" end
  local cfg = Api.config
  if not cfg.ssl then return "plain HTTP (dev)" .. ((Api.token and Signer and Signer.has(Api.token)) and ", signed" or "") end
  if cfg.forceHttps then return "HTTPS (forced)" end
  if not (Signer and Signer.available()) then return "HTTPS (no signing module)" end
  if Api.token and Signer.has(Api.token) then return "signed HTTP (HTTPS for keys)" end
  return "HTTPS until a signing key arrives"
end

function Api.setToken(t)
  if t ~= Api.token then Api.invalidate("") end
  Api.token = t
  updateDiskScope()
end

function Api.busy()
  return #queue + #active
end

function Api.invalidate(prefix)
  prefix = prefix or ""
  for k in pairs(cache) do
    if k:sub(1, #prefix) == prefix then cache[k] = nil end
  end
end

local function later(fn, a, b)
  deferred[#deferred + 1] = { fn, a, b }
end

--- raw: the response's JSON text (before rebasing), for the disk cache.
local function finish(req, err, data, raw)
  if req.method == "GET" then
    inflightGets[req.path] = nil
    if not err and (req.ttl or DEFAULT_TTL) > 0 then
      cache[req.path] = { at = playdate.getCurrentTimeMilliseconds(), data = data, ttl = req.ttl or DEFAULT_TTL }
    end
    if not err and raw and DiskCache and DiskCache.accepts(req.path, req.ttl) then DiskCache.put(req.path, raw) end
  elseif not err and req.path ~= "/auth/key" then
    -- any successful write may change what GETs return
    Api.invalidate("")
  end
  if err then print("[api] " .. req.method .. " " .. req.path .. " -> " .. tostring(err.code) .. ": " .. tostring(err.message)) end
  for _, cb in ipairs(req.cbs) do
    later(cb, err, data)
  end
  -- shell-wide listeners (status bar, pager) see every fresh copy of the paths they watch
  if not err and req.method == "GET" then
    local obs = Api.observers[req.path]
    if obs then for _, fn in ipairs(obs) do later(fn, data, req.path) end end
  end
end

Api.observers = {}

--- fn(data, path) runs (next frame) after every successful GET of exactly `path`, whoever asked.
function Api.observe(path, fn)
  local l = Api.observers[path]
  if not l then l = {} Api.observers[path] = l end
  l[#l + 1] = fn
end

--- The error every request gets once the server has refused this build.
local function blockedErr()
  local b = Api.blocked or {}
  return { status = 426, code = "upgrade_required", message = b.message or "This build is out of date.", minBuild = b.minBuild }
end

--- True while live requests are refused (a 426 from this server). Fixtures never are.
function Api.isBlocked()
  return Api.blocked ~= nil and not Api.isFixtureMode()
end

local function enqueue(method, path, body, cb, opts)
  opts = opts or {}
  cb = cb or function() end
  if Api.isBlocked() then later(cb, blockedErr()) return end
  if method == "GET" and not opts.fresh then
    local c = cache[path]
    if c and playdate.getCurrentTimeMilliseconds() - c.at < (c.ttl or DEFAULT_TTL) then
      later(cb, nil, c.data)
      return
    end
    local dup = inflightGets[path]
    if dup then
      dup.cbs[#dup.cbs + 1] = cb
      if not opts.bg then dup.bg = false end
      return
    end
  end
  local req = {
    method = method, path = path, body = body, cbs = { cb }, ttl = opts.ttl,
    retries = opts.retries or (method == "GET" and 2 or 0), attempt = 0,
    single = opts.single, bg = opts.bg or nil,
  }
  if method == "GET" then inflightGets[path] = req end
  queue[#queue + 1] = req
end

function Api.get(path, cb, opts) enqueue("GET", path, nil, cb, opts) end
function Api.post(path, body, cb, opts) enqueue("POST", path, body or {}, cb, opts) end
function Api.delete(path, cb, opts) enqueue("DELETE", path, nil, cb, opts) end

--- The newest copy of a GET we have, without touching the network: data, ageSec, fresh.
--- Memory first (even past its ttl), then disk (rebased onto Api.now() by its age).
function Api.peek(path)
  local c = cache[path]
  if c then
    local age = playdate.getCurrentTimeMilliseconds() - c.at
    return c.data, age // 1000, age < (c.ttl or DEFAULT_TTL)
  end
  if Api.isFixtureMode() or not DiskCache then return nil end
  local d, ageS = DiskCache.get(path)
  if not d then return nil end
  -- the relative fields were measured when it was saved, ageS ago
  return Api.rebaseTimes(d, Api.now() - ageS * 1000), ageS, false
end

--- Background GETs that only warm the caches (memory + disk). Skips paths already fresh or
--- in flight; all of them go out together, i.e. in one /batch. done(nOk, nErr) optional.
function Api.prefetch(paths, done)
  local left, okN, errN = 0, 0, 0
  local nowMs = playdate.getCurrentTimeMilliseconds()
  local todo = {}
  for _, p in ipairs(paths) do
    local c = cache[p]
    if not (c and nowMs - c.at < (c.ttl or DEFAULT_TTL)) and not inflightGets[p] then todo[#todo + 1] = p end
  end
  if #todo == 0 then
    if done then later(done, 0, 0) end
    return 0
  end
  left = #todo
  for _, p in ipairs(todo) do
    enqueue("GET", p, nil, function(err)
      if err then errN += 1 else okN += 1 end
      left -= 1
      if left == 0 and done then done(okN, errN) end
    end, { bg = true, retries = 1 })
  end
  return #todo
end

-- Real network ---------------------------------------------------------------

local function decodeBody(chunks)
  local s = table.concat(chunks)
  if s == "" then return nil end
  local ok, data = pcall(json.decode, s)
  if ok then return data, s end
  return nil
end

-- %-encode a path for a query parameter value
local function qenc(s)
  return (s:gsub("[^%w%-%._~/]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function startHttp(req)
  req.attempt += 1
  req.chunks = {}
  req.started = playdate.getCurrentTimeMilliseconds()
  local cfg = Api.config
  local ssl, port, auth = req.ssl, req.port, req.auth
  local conn = net.http.new(cfg.host, port, ssl, Api.ACCESS_REASON)
  if not conn then
    return false, "Network access denied"
  end
  req.conn = conn
  conn:setConnectTimeout(10)
  -- (a 1 s read timeout made plain HTTP fail with "Read timeout" on the device)
  conn:setReadTimeout(15)
  conn:setReadBufferSize(48 * 1024)
  local function drain()
    local n = conn:getBytesAvailable()
    while n and n > 0 do
      local chunk = conn:read(n)
      if not chunk or #chunk == 0 then break end
      if not req.tFirst then req.tFirst = playdate.getCurrentTimeMilliseconds() end
      req.bytes = (req.bytes or 0) + #chunk
      req.chunks[#req.chunks + 1] = chunk
      n = conn:getBytesAvailable()
    end
  end
  conn:setRequestCallback(drain)
  local function complete()
    if req.done then return end
    drain()
    req.tDone = playdate.getCurrentTimeMilliseconds()
    req.done = true
    req.status = conn:getResponseStatus()
    req.netErr = conn:getError()
  end
  conn:setRequestCompleteCallback(complete)
  conn:setConnectionClosedCallback(complete)

  local headers = { ["Content-Type"] = "application/json", ["Accept"] = "application/json", ["X-Build"] = tostring(Api.BUILD) }
  local full = "/v1" .. req.path
  local bodyText = req.method == "POST" and json.encode(req.body or {}) or ""
  if auth == "bearer" and Api.token then
    headers["Authorization"] = "Bearer " .. Api.token   -- only ever over HTTPS (or a dev server)
  elseif auth == "signed" then
    req.seq = Signer.sign(headers, req.method, full, bodyText)
  end
  local ok, err
  if req.method == "GET" then
    ok, err = conn:get(full, headers)
  elseif req.method == "POST" then
    ok, err = conn:post(full, headers, bodyText)
  else
    ok, err = conn:query(req.method, full, headers)
  end
  return ok, err
end

local failBatch

local function retryOrFail(req, code, message)
  if req.conn then pcall(function() req.conn:close() end) end
  req.conn = nil
  req.done = nil
  if req.batch then return failBatch(req, code, message) end
  if req.attempt <= req.retries then
    -- back off a little: re-queue at the end
    req.notBefore = playdate.getCurrentTimeMilliseconds() + 400 * req.attempt
    queue[#queue + 1] = req
  else
    finish(req, { code = code, message = message })
  end
end

-- Batches ---------------------------------------------------------------------------

local function makeBatch(items)
  local q = {}
  for i, it in ipairs(items) do q[i] = "p=" .. qenc(it.path) end
  return { method = "GET", path = "/batch?" .. table.concat(q, "&"), batch = items, cbs = {}, attempt = 0, retries = 0, timeout = BATCH_TIMEOUT_MS }
end

--- Puts a batch's item back in the queue as its own request.
local function requeueSingle(it)
  it.single = true
  queue[#queue + 1] = it
end

--- The whole batch failed in transport (offline, timeout, 5xx): each item spends one of
--- its retries and goes back in the queue, where the next frame re-batches the survivors.
failBatch = function(req, code, message)
  local nowMs = playdate.getCurrentTimeMilliseconds()
  for _, it in ipairs(req.batch) do
    it.attempt += 1
    if it.attempt <= it.retries then
      it.notBefore = nowMs + 400 * it.attempt
      queue[#queue + 1] = it
    else
      finish(it, { code = code, message = message })
    end
  end
end

local function finishBatch(req, status, data)
  local items = req.batch
  local results = type(data) == "table" and type(data.results) == "table" and data.results or nil
  if status == 404 and not results then
    -- an older server without /batch: singles from now on; pure prefetches are dropped
    print("[net] batch unsupported by server (404): falling back to single requests")
    Api.batchOff = true
    for _, it in ipairs(items) do
      if it.bg then finish(it, { code = "skipped", message = "prefetch skipped" }) else requeueSingle(it) end
    end
    return
  end
  if status == 0 then return failBatch(req, "offline", req.netErr or "Could not reach the server") end
  if status >= 500 or (status >= 200 and status < 300 and not results) then
    return failBatch(req, "server_error", "Server error " .. status)
  end
  if not results then
    -- 4xx for the batch itself (bad path list?): let each item try on its own
    for _, it in ipairs(items) do requeueSingle(it) end
    return
  end
  local base = Api.now()
  local marks = {}
  for _, it in ipairs(items) do
    local r = results[it.path]
    local st = type(r) == "table" and tonumber(r.status) or nil
    marks[#marks + 1] = it.path .. ":" .. tostring(st or "-")
    if st and st >= 200 and st < 300 then
      local body = type(r.body) == "table" and r.body or {}
      local raw = nil
      if DiskCache and DiskCache.accepts(it.path, it.ttl) then
        local ok, enc = pcall(json.encode, body)
        if ok then raw = enc end
      end
      finish(it, nil, Api.rebaseTimes(body, base), raw)
    elseif not st or st == 413 or st >= 500 then
      -- missing, over the batch's byte budget, or a server error: fetch it alone (a single
      -- never re-batches, and keeps its own retries)
      requeueSingle(it)
    else
      local b = type(r.body) == "table" and r.body or {}
      finish(it, { status = st, code = b.error or ("http_" .. st), message = b.message or ("HTTP " .. st) })
    end
  end
  print("[net] batch items " .. table.concat(marks, " "))
end

local function pollHttp(req)
  if req.done then
    local status = req.status or 0
    local t0 = playdate.getCurrentTimeMilliseconds()
    local data, raw = decodeBody(req.chunks)
    local t1 = playdate.getCurrentTimeMilliseconds()
    -- phases: until the first byte (wake + connect + TLS + server), the transfer, our
    -- poll latency, and JSON decode
    local first, done = req.tFirst or req.tDone or t0, req.tDone or t0
    req.timing = { total = t1 - req.started, ttfb = first - req.started, xfer = done - first, wait = t0 - done, decode = t1 - t0, bytes = req.bytes or 0 }
    local what = req.batch and ("batch n=" .. #req.batch) or (req.method .. " " .. req.path)
    local via = (req.ssl and "https" or "http") .. (req.auth == "signed" and "+sig" or "")
    print(string.format("[net] %s %d %s total %d ttfb %d xfer %d wait %d decode %d bytes %d", what, status, via,
      req.timing.total, req.timing.ttfb, req.timing.xfer, req.timing.wait, req.timing.decode, req.timing.bytes))
    pcall(function() req.conn:close() end)
    req.conn = nil
    if status == 426 then
      Api.upgradeRequired(type(data) == "table" and data or {})
      if req.batch then
        for _, it in ipairs(req.batch) do finish(it, blockedErr()) end
      else
        finish(req, blockedErr())
      end
      return true
    end
    -- the server didn't accept our signature (key rotated elsewhere, counter lost): get a new
    -- key over HTTPS and send this again, once
    if status == 401 and req.auth == "signed" and data and (data.error == "bad_signature" or data.error == "replayed") then
      print("[net] signature rejected (" .. data.error .. "): fetching a new key")
      Signer.drop()
      if req.batch then
        for _, it in ipairs(req.batch) do
          if it.rekeyed then finish(it, { status = 401, code = data.error, message = data.message or "signature rejected" })
          else it.rekeyed = true queue[#queue + 1] = it end
        end
        return true
      end
      if not req.rekeyed then
        req.rekeyed = true
        req.attempt -= 1
        queue[#queue + 1] = req
        return true
      end
    end
    if status >= 200 and status < 300 and req.path == "/register" and type(data) == "table" and data.key and data.account then
      Signer.setKey(data.account.id, data.key, data.token)
    end
    if req.batch then
      finishBatch(req, status, data)
      if Api.onTiming then Api.onTiming(req) end
      return true
    end
    if Api.onTiming then Api.onTiming(req) end
    if status >= 200 and status < 300 then
      finish(req, nil, Api.rebaseTimes(data or {}), raw)
    elseif status == 0 then
      retryOrFail(req, "offline", req.netErr or "Could not reach the server")
      return true
    elseif status >= 500 and req.attempt <= req.retries then
      retryOrFail(req, "server_error", "Server error " .. status)
      return true
    else
      local e = { status = status, code = (data and data.error) or ("http_" .. status), message = (data and data.message) or ("HTTP " .. status) }
      finish(req, e)
    end
    return true
  end
  if playdate.getCurrentTimeMilliseconds() - req.started > (req.timeout or TIMEOUT_MS) then
    retryOrFail(req, "timeout", "The server took too long to answer")
    return true
  end
  return false
end

--- The server refused this build (426): stop talking to it until relaunch. Fails every
--- queued request (no retries, no polling) and tells the UI once.
function Api.upgradeRequired(d)
  local first = Api.blocked == nil
  Api.blocked = {
    build = Api.BUILD,
    minBuild = tonumber(d.minBuild),
    message = type(d.message) == "string" and d.message or nil,
  }
  if first then print(string.format("[api] server needs build %s, this is build %d: online requests stopped", tostring(Api.blocked.minBuild), Api.BUILD)) end
  local q = queue
  queue = {}
  for _, r in ipairs(q) do
    if r.batch then for _, it in ipairs(r.batch) do finish(it, blockedErr()) end else finish(r, blockedErr()) end
  end
  if keyState.req then keyState.req = nil end
  if first and Api.onUpgradeRequired then later(Api.onUpgradeRequired, Api.blocked) end
end

-- Fixture network --------------------------------------------------------------

local function startFixture(req)
  req.started = playdate.getCurrentTimeMilliseconds()
  req.readyAt = req.started + math.random(120, 500)
  return true
end

local function pollFixture(req)
  if playdate.getCurrentTimeMilliseconds() < req.readyAt then return false end
  local err, data = Fixtures.handle(req.method, req.path, req.body)
  finish(req, err, Api.rebaseTimes(data))
  return true
end

-- Pump ----------------------------------------------------------------------------

local function held(req)
  return req.bg and Api.holdBackground and Api.holdBackground()
end

--- Starts POST /auth/key (HTTPS + bearer) when we have a token but no signing key.
local function ensureKey(nowMs)
  if Api.blocked then return end
  if keyState.req or not Api.token or not canSign() or Signer.has(Api.token) then return end
  if nowMs < keyState.retryAt or not Api.config.host or Api.config.host == "" then return end
  local token = Api.token
  print("[sign] no signing key: requesting one over HTTPS")
  local req = { method = "POST", path = "/auth/key", body = {}, attempt = 0, retries = 0, cbs = {} }
  req.cbs[1] = function(err, d)
    keyState.req = nil
    if not err and d and d.key and d.accountId then
      Signer.setKey(d.accountId, d.key, token)
    else
      -- an older server without /auth/key (404): stay on HTTPS for a good while
      keyState.retryAt = playdate.getCurrentTimeMilliseconds() + ((err and err.status == 404) and KEY_RETRY_MS * 10 or KEY_RETRY_MS)
      print("[sign] key request failed (" .. tostring(err and err.code) .. "): HTTPS for now")
    end
  end
  keyState.req = req
  table.insert(queue, 1, req)
end

local function startReq(req, fixture)
  req.fixture = fixture
  local ok, err
  if fixture then ok, err = startFixture(req) else ok, err = startHttp(req) end
  if ok then
    active[#active + 1] = req
  else
    retryOrFail(req, "offline", err or "Could not start request")
  end
end

local function activeCount(ssl)
  local n = 0
  for _, r in ipairs(active) do if r.ssl == ssl then n += 1 end end
  return n
end

--- Can req start now? Fills req.ssl / port / auth. False while waiting for a key or a slot.
local function admit(req)
  local ssl, port, auth = transportFor(req)
  if ssl == "wait" then return false end
  if activeCount(ssl) >= (ssl and MAX_HTTPS or MAX_HTTP) then return false end
  req.ssl, req.port, req.auth = ssl, port, auth
  return true
end

--- Pulls every due, batchable GET out of the queue into one /batch request (needs 2+).
local function startBatch(nowMs)
  local picked, idx = {}, {}
  for i, req in ipairs(queue) do
    if #picked >= MAX_BATCH then break end
    if req.method == "GET" and not req.single and not (req.notBefore and req.notBefore > nowMs) and not held(req) then
      picked[#picked + 1] = req
      idx[#idx + 1] = i
    end
  end
  if #picked < 2 then return end
  local b = makeBatch(picked)
  if not admit(b) then return end
  for k = #idx, 1, -1 do table.remove(queue, idx[k]) end
  startReq(b, false)
end

function Api.update()
  -- run deferred callbacks first (they may enqueue more work)
  if #deferred > 0 then
    local d = deferred
    deferred = {}
    for _, item in ipairs(d) do
      local ok, e = pcall(item[1], item[2], item[3])
      if not ok then print("[api] callback error: " .. tostring(e)) ; if Api.onCallbackError then Api.onCallbackError(e) end end
    end
  end
  local fixture = Api.isFixtureMode()
  local nowMs = playdate.getCurrentTimeMilliseconds()
  -- refused build: anything that got back in the queue (a retry) fails instead of going out
  if not fixture and Api.blocked and #queue > 0 then Api.upgradeRequired(Api.blocked) end
  if not fixture and #queue > 0 then ensureKey(nowMs) end
  -- everything GET queued since last frame goes out as one /batch (live server only)
  if not fixture and Api.batching and not Api.batchOff and #queue > 1 then
    startBatch(nowMs)
  end
  -- start queued requests (http.new may yield for a permission prompt; we're in update)
  local i = 1
  while i <= #queue and (not fixture or #active < MAX_CONN) do
    local req = queue[i]
    if (req.notBefore and req.notBefore > nowMs) or held(req) or (not fixture and not admit(req)) then
      i += 1
    else
      table.remove(queue, i)
      startReq(req, fixture)
    end
  end
  -- poll in-flight
  local j = 1
  while j <= #active do
    local req = active[j]
    local doneNow = req.fixture and pollFixture(req) or (not req.fixture and pollHttp(req))
    if doneNow then table.remove(active, j) else j += 1 end
  end
  if DiskCache and not fixture then DiskCache.update() end
end

--- Human message for an error object, with friendly overrides.
local FRIENDLY = {
  name_taken = "Somebody already goes by that name.",
  name_rejected = "The League's Decency Board rejected that name.",
  insufficient_funds = "You can't afford that. Bobby doesn't do credit.",
  window_closed = "Too late! First pitch already happened.",
  rate_limited = "Slow down, slugger. Try again in a bit.",
  invalid_comment = "That comment doesn't parse. Try another template.",
  unauthorized = "The server doesn't recognize this Playdate.",
  offline = "Can't reach the server. Check Wi-Fi or Settings.",
  timeout = "The server took too long to answer.",
  not_found = "404: That page has moved or never existed.",
  upgrade_required = "This build is out of date. Online play needs the latest build.",
}
function Api.errorText(err)
  if not err then return "" end
  return (err.message and err.message ~= "" and err.code ~= "offline" and err.code ~= "timeout") and err.message
    or FRIENDLY[err.code] or err.message or tostring(err.code)
end
