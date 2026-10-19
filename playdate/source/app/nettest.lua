-- Network benchmark (device only, dev). With "nettest.flag" in the Data folder, runs a
-- fixed set of requests against the configured server a few seconds after boot and
-- prints per-request phase timings ([net] lines from net/api.lua) plus summaries. The
-- host script streams them over USB serial (playdate/tools/serial_run.py).
--
-- Part 4 compares the same N paths over HTTPS (bearer; singles, then one batch) and over
-- signed plain HTTP (singles sequential, singles parallel = 2 connections, one batch), then
-- times reading them back from the disk cache. All requests are fresh + ttl 0. Each [net]
-- line says how it travelled ("https", "http+sig"); "[net] batch n=N" lines are batches.
-- Parts 1-3 use the default transport (signed HTTP once a key is held).

NetTest = NetTest or {}

local function now() return playdate.getCurrentTimeMilliseconds() end

local SINGLE <const> = { fresh = true, ttl = 0, retries = 0, single = true }
local BATCHED <const> = { fresh = true, ttl = 0, retries = 0 }

local function seq(paths, done)
  local i, t0, errs = 0, now(), 0
  local function nextReq()
    i += 1
    local p = paths[i]
    if not p then done(now() - t0, errs) return end
    Api.get(p, function(err) if err then errs += 1 end nextReq() end, SINGLE)
  end
  nextReq()
end

--- All paths queued in one frame: singles open up to 4 connections; batched ones go as one /batch.
local function together(paths, opts, done)
  local left, t0, errs = #paths, now(), 0
  for _, p in ipairs(paths) do
    Api.get(p, function(err)
      if err then errs += 1 end
      left -= 1
      if left == 0 then done(now() - t0, errs) end
    end, opts)
  end
end
local function parallel(paths, done) together(paths, SINGLE, done) end

--- Run fn with every request forced onto HTTPS + bearer (Settings' "Always use HTTPS").
local function viaHttps(on)
  Api.config.forceHttps = on
end

--- Part 4: HTTPS vs signed HTTP, singles vs one batch, same N paths.
local function compare(paths, done)
  local n = #paths
  local out = {}
  local function line(label, ms, e) out[#out + 1] = string.format("[nettest] N=%d %-28s %6d ms (%d err)", n, label, ms, e) end
  local forced = Api.config.forceHttps
  viaHttps(true)
  print("[nettest] part 4a: HTTPS singles, then one HTTPS batch")
  seq(paths, function(ms1, e1)
    line("https singles sequential:", ms1, e1)
    together(paths, BATCHED, function(ms2, e2)
      line("https one batch:", ms2, e2)
      viaHttps(forced)
      print("[nettest] part 4b: signed HTTP singles (seq, parallel), then one signed batch")
      seq(paths, function(ms3, e3)
        line("signed http singles seq:", ms3, e3)
        together(paths, SINGLE, function(ms4, e4)
          line("signed http singles parallel:", ms4, e4)
          local wasOff = Api.batchOff
          together(paths, BATCHED, function(ms5, e5)
            line("signed http one batch:", ms5, e5)
            if Api.batchOff and not wasOff then out[#out + 1] = "[nettest] (server has no /batch: batches fell back to singles)" end
            for _, l in ipairs(out) do print(l) end
            print("[nettest] transport now: " .. Api.transport())
            -- disk cache read-back (what a stale-while-revalidate paint costs)
            if DiskCache and DiskCache.stats then
              local cn, bytes, q = DiskCache.stats()
              local t0, hits = now(), 0
              for _, p in ipairs(paths) do if DiskCache.get(p) then hits += 1 end end
              print(string.format("[nettest] disk cache: %d entries %d bytes (%d queued); read+decode %d/%d paths in %d ms", cn, bytes, q, hits, n, now() - t0))
            end
            done()
          end)
        end)
      end)
    end)
  end)
end

--- One raw request outside the Api queue (no retries, generous timeouts), timed.
local function rawGet(host, port, ssl, path, done)
  local t0, tFirst, bytes, finished = now(), nil, 0, false
  local conn = playdate.network.http.new(host, port, ssl, "DEADBALL network test")
  if not conn then print("[nettest] raw: no connection object") done() return end
  conn:setConnectTimeout(20)
  conn:setReadTimeout(20)
  conn:setRequestCallback(function()
    local n = conn:getBytesAvailable()
    while n and n > 0 do
      local c = conn:read(n)
      if not c or #c == 0 then break end
      tFirst = tFirst or now()
      bytes += #c
      n = conn:getBytesAvailable()
    end
  end)
  local function fin()
    if finished then return end
    finished = true
    local t = now()
    print(string.format("[nettest] %s %s:%d%s status %s ttfb %d total %d bytes %d err %s", ssl and "https" or "http",
      host, port, path, tostring(conn:getResponseStatus()), (tFirst or t) - t0, t - t0, bytes, tostring(conn:getError())))
    pcall(function() conn:close() end)
    done()
  end
  conn:setRequestCompleteCallback(fin)
  conn:setConnectionClosedCallback(fin)
  local ok, err = conn:get("/v1" .. path, { Accept = "application/json" })
  if not ok then print("[nettest] raw get failed: " .. tostring(err)) finished = true done() end
end

local function rawSeq(list, done)
  local i = 0
  local function nextOne()
    i += 1
    local r = list[i]
    if not r then done() return end
    rawGet(r[1], r[2], r[3], r[4], nextOne)
  end
  nextOne()
end

--- HTTP vs HTTPS with raw requests, after the game's own boot traffic has settled.
function NetTest.raw(done)
  local host = Api.config.host
  local function go()
    print("[nettest] raw: http x3 then https x3")
    rawSeq({
      { host, 80, false, "/clock" }, { host, 80, false, "/clock" }, { host, 80, false, "/clock" },
      { host, 443, true, "/clock" }, { host, 443, true, "/clock" }, { host, 443, true, "/clock" },
    }, done)
  end
  -- wait for the Api queue to drain (boot requests) before measuring
  local waited = 0
  local function poll()
    if Api.busy() == 0 or waited > 60000 then go() return end
    waited += 500
    playdate.timer.performAfterDelay(500, poll)
  end
  poll()
end

--- HTTPS vs plain HTTP: the same tiny request three times each (is TLS the cost?).
function NetTest.tls(done)
  local host = Api.config.host
  print("[nettest] https x3")
  seq({ "/clock", "/clock", "/clock" }, function()
    Api.configure({ host = host, port = 80, ssl = false })
    print("[nettest] http x3")
    seq({ "/clock", "/clock", "/clock" }, function()
      Api.configure({ host = host, port = 443, ssl = true })
      done()
    end)
  end)
end

function NetTest.run()
  if Api.isFixtureMode() then print("[nettest] fixture mode, nothing to test") print("[nettest] done") return end
  print("[nettest] start host=" .. tostring(Api.config.host) .. " transport: " .. Api.transport())
  if Signer then print("[nettest] crypto selftest: " .. tostring((Signer.selftest()))) end
  if playdate.file.exists("nettest-raw.flag") then
    NetTest.raw(function() print("[nettest] done") end)
    return
  end
  if playdate.file.exists("nettest-tls.flag") then
    NetTest.tls(function() print("[nettest] done") end)
    return
  end
  local t0 = now()
  -- 1. handshake baseline: tiny payload, three times in a row
  seq({ "/clock", "/clock", "/clock" }, function()
    -- 2. every main screen's data, one at a time
    Api.get("/today", function(err, today)
      local gid = nil
      for _, g in ipairs(today and today.games or {}) do
        if g.status == "final" or g.status == "live" then gid = g.id break end
      end
      local paths = { "/me", "/news", "/mail", "/standings", "/gossip", "/words", "/ops/catalog", "/schedule" }
      if gid then
        paths[#paths + 1] = "/games/" .. gid
        paths[#paths + 1] = "/games/" .. gid .. "/log"
      end
      seq(paths, function()
        -- 3. four at once: do parallel connections help or queue?
        parallel({ "/clock", "/clock", "/clock", "/clock" }, function(ms)
          print(string.format("[nettest] 4 parallel /clock: %d ms wall", ms))
          -- 4. singles vs one batch, same paths (what boot / page loads send)
          local cmp = { "/clock", "/me", "/events", "/news", "/today", "/bets?status=open", "/mail", "/gossip" }
          compare(cmp, function()
            print(string.format("[nettest] total %d ms", now() - t0))
            print("[nettest] done")
          end)
        end)
      end)
    end, SINGLE)
  end)
end

if playdate.file.exists("nettest.flag") then
  print("[nettest] armed")
  playdate.setAutoLockDisabled(true)
  -- start ~4 s after boot, driven by frames (a timer made at import never fired)
  local frames, prev = 0, Debug.update
  Debug.update = function()
    if prev then prev() end
    frames += 1
    if frames == 120 then
      local ok, e = pcall(NetTest.run)
      if not ok then print("[nettest] error: " .. tostring(e)) print("[nettest] done") end
    end
  end
end

-- Live UI check (Simulator + a dev server, dev only). With "livetest.flag" in the Data folder
-- the client walks a few pages on its own once the desktop is up, so the debug log shows
-- batching, signing, stale-while-revalidate paints and prefetch against a real server.
NetTest.liveSteps = {
  { 60, function()
      print("[livetest] crypto selftest: " .. tostring((Signer and Signer.selftest())) .. "  transport: " .. Api.transport())
      Sites.Syndicate.open()
    end },
  { 150, function() App.pop() Sites.Bets.open() end },
  { 300, function() App.pop() end },
  -- memory ttl (20 s) runs out: reopening paints the old copy, then refreshes behind it
  { 1050, function() Sites.Bets.open() end },
  { 1056, function()
      local p = App.top()
      print(string.format("[livetest] bets reopened: stale=%s updating=%s loading=%s", tostring(p.stale), tostring(p.updating), tostring(p.loading)))
    end },
  { 1200, function()
      local p = App.top()
      print(string.format("[livetest] bets later: stale=%s updating=%s", tostring(p.stale), tostring(p.updating)))
      App.pop()
    end },
  { 1260, function()
      local n, bytes, q = DiskCache.stats()
      print(string.format("[livetest] disk cache %d entries %d bytes %d queued", n, bytes, q))
      if NetShim then NetShim.report() end
      print("[livetest] done")
    end },
}

if playdate.file.exists("livetest.flag") then
  local frames, step, prev = 0, 1, Debug.update
  Debug.update = function()
    if prev then prev() end
    if not Nav.ready then return end
    frames += 1
    local s = NetTest.liveSteps[step]
    if s and frames == s[1] then
      step += 1
      local ok, e = pcall(s[2])
      if not ok then print("[livetest] error: " .. tostring(e)) end
    end
  end
end
