-- Network shim (Simulator, dev only). The Simulator can't be driven past the OS network-
-- permission dialog headlessly, so with "netshim.flag" in the Data folder this replaces
-- playdate.network.http with an in-process fake league server backed by the fixtures. It
-- speaks the real wire protocol, so the client's whole live path runs: HTTPS vs signed HTTP
-- transport choice, POST /auth/key, X-Acct/X-Seq/X-Sig (verified here with dbcrypto),
-- replay rejection + re-key, /batch fan-out, the disk cache, stale-while-revalidate and
-- prefetch. "netshim-replay.flag" starts the replay window high so the first signed
-- request is rejected as replayed (tests the re-key path). Latency: HTTPS 900 ms, HTTP 90 ms.

if not playdate.file.exists("netshim.flag") then return end

NetShim = { log = {}, conns = 0, https = 0, http = 0, violations = 0 }
local SHIM_HOST <const> = "shim.local"
local TOKEN <const> = "shimtoken0123456789abcdef"
local ACCT <const> = "ashim"
local key = nil
local hi, seen = 0, {}
if playdate.file.exists("netshim-replay.flag") then hi = 50000 end

local function hex32()
  local t = {}
  for i = 1, 32 do t[i] = string.format("%02x", math.random(0, 255)) end
  return table.concat(t)
end

local function urldecode(s)
  return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function respond(status, body)
  return status, json.encode(body)
end

local function shimRoute(ssl, method, target, headers, bodyText)
  local path = target:gsub("^/v1", "")
  local base = path:match("^[^?]*")
  local bearer = headers["Authorization"]
  if bearer and not ssl then
    NetShim.violations += 1
    print("[shim] VIOLATION: bearer token over plain HTTP " .. method .. " " .. path)
    return respond(403, { error = "https_required", message = "bearer tokens only over HTTPS" })
  end
  if (base == "/register" or base == "/auth/key") and not ssl then
    NetShim.violations += 1
    print("[shim] VIOLATION: " .. base .. " over plain HTTP")
    return respond(403, { error = "https_required", message = "needs HTTPS" })
  end
  -- auth
  local who = nil
  if headers["X-Acct"] then
    local seq = tonumber(headers["X-Seq"] or "")
    local want = key and dbcrypto.hmac_sha256_hex(key, method .. "\n" .. target .. "\n" .. tostring(headers["X-Seq"]) .. "\n" .. dbcrypto.sha256_hex(bodyText or ""))
    if not want or want ~= headers["X-Sig"] or headers["X-Acct"] ~= ACCT then
      return respond(401, { error = "bad_signature", message = "signature doesn't match" })
    end
    if not seq or seq <= hi - 128 or seen[seq] then
      return respond(401, { error = "replayed", message = "that request was already used" })
    end
    seen[seq] = true
    if seq > hi then hi = seq end
    who = "signed"
  elseif bearer then
    who = bearer == "Bearer " .. TOKEN and "bearer" or nil
  end
  if base == "/auth/key" then
    if who ~= "bearer" then return respond(401, { error = "unauthorized", message = "bearer needed" }) end
    key = hex32()
    hi, seen = 0, {}
    print("[shim] issued key")
    return respond(200, { key = key, accountId = ACCT })
  end
  if base ~= "/clock" and not who then
    return respond(401, { error = "unauthorized", message = "missing auth" })
  end
  if base == "/batch" then
    local parts, n = {}, 0
    for p in (path:match("%?(.*)$") or ""):gmatch("p=([^&]*)") do
      local ip = urldecode(p)
      local err, data = Fixtures.handle("GET", ip, nil)
      local st = err and (err.status or 404) or 200
      local b = err and { error = err.code or "not_found", message = err.message or "" } or (data or {})
      parts[#parts + 1] = json.encode(ip) .. ':{"status":' .. st .. ',"body":' .. json.encode(b) .. "}"
      n += 1
    end
    return 200, '{"n":' .. n .. ',"results":{' .. table.concat(parts, ",") .. "}}"
  end
  local body = nil
  if bodyText and bodyText ~= "" then body = json.decode(bodyText) end
  local err, data = Fixtures.handle(method, path, body)
  if err then return respond(err.status or 404, { error = err.code or "not_found", message = err.message or "" }) end
  return respond(200, data or {})
end

local Conn = {}
Conn.__index = Conn
function Conn:setConnectTimeout() end
function Conn:setReadTimeout() end
function Conn:setReadBufferSize() end
function Conn:setKeepAlive() end
function Conn:setRequestCallback(f) self.onData = f end
function Conn:setRequestCompleteCallback(f) self.onDone = f end
function Conn:setConnectionClosedCallback(f) self.onClosed = f end
function Conn:getBytesAvailable() return self.out and (#self.out - self.pos + 1) or 0 end
function Conn:read(n)
  if not self.out then return nil end
  local s = self.out:sub(self.pos, self.pos + n - 1)
  self.pos += #s
  return s
end
function Conn:getResponseStatus() return self.status end
function Conn:getError() return nil end
function Conn:close() end
function Conn:send(method, target, headers, body)
  local h = {}
  if type(headers) == "table" then for k, v in pairs(headers) do h[k] = v end end
  NetShim.conns += 1
  if self.ssl then NetShim.https += 1 else NetShim.http += 1 end
  playdate.timer.performAfterDelay(self.ssl and 900 or 90, function()
    local ok, st, out = pcall(shimRoute, self.ssl, method, target, h, body or "")
    if not ok then print("[shim] error: " .. tostring(st)) st, out = 500, '{"error":"internal"}' end
    self.status, self.out, self.pos = st, out, 1
    if self.onData then self.onData() end
    if self.onDone then self.onDone() end
  end)
  return true
end
function Conn:get(target, headers) return self:send("GET", target, headers, "") end
function Conn:post(target, headers, body) return self:send("POST", target, headers, body) end
function Conn:query(method, target, headers, body) return self:send(method, target, headers, body) end

local fake = {
  new = function(host, port, ssl)
    if host ~= SHIM_HOST then print("[shim] unexpected host " .. tostring(host)) end
    if (ssl and port ~= 443) or (not ssl and port ~= 80) then print("[shim] odd port " .. tostring(port) .. " ssl=" .. tostring(ssl)) end
    return setmetatable({ ssl = ssl, port = port }, Conn)
  end,
  requestAccess = function() return true end,
}
playdate.network.http = fake

-- point the client at the shim with a known token (doesn't touch settings.json / auth.json)
local origLoad = Game.loadSettings
Game.loadSettings = function()
  origLoad()
  Api.configure({ host = SHIM_HOST, port = 443, ssl = true })
  Api.setToken(TOKEN)
end
Game.saveToken = function(t) Api.setToken(t) end
print("[shim] network shim active (fake league at " .. SHIM_HOST .. ")")

function NetShim.report()
  print(string.format("[shim] connections %d (https %d, http %d), violations %d", NetShim.conns, NetShim.https, NetShim.http, NetShim.violations))
end
