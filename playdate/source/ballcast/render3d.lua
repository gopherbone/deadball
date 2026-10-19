-- BallCast rendering backends + the live camera director.
--
--   Live (C extension `bc3d` present): the park is rasterized every frame from a moving
--   camera; puppets/ball are queued to C, which projects, depth-sorts and draws them.
--   Static (pdc-only build): shipped per-camera backgrounds (images/parks/) or a painted
--   copy of the geometry, with Lua-side projection and puppet drawing.
--
-- Both expose the same renderer interface used by Play.drawWorld:
--   R:puppet(variant, frame, x, y, z, flip [, dx, dy])   R:ball(x, y, z [, scale])   R:dot(x, y, z, white, big)
--   R:puppetT(variant, table, f, x, y, z, flip, sx, sy, rot, dx, dy, pivot)   (animatic track key)
--   R:project(x, y, z) → sx, sy, depth (screen)                 R:finish()
--
-- puppetT: raw imagetable frame + per-billboard transform — squash/stretch sx, sy about the
-- pivot (0 = feet anchor, 20 = body centre, in 1x px above the feet), rot degrees clockwise,
-- dx, dy offset in 1x sprite pixels (scaled with the puppet). The live renderer does this in
-- C (bc3d.bb args 7-12); the static fallback only honours flip and the offset.

import "ballcast/kit"
import "ballcast/cam"
import "ballcast/geo"
import "ballcast/puppets"

local gfx <const> = playdate.graphics
local floor <const>, sin <const>, cos <const>, rad <const>, sqrt <const>, max <const> = math.floor, math.sin, math.cos, math.rad, math.sqrt, math.max

BallCast = BallCast or {}
local R3 = {}
BallCast.Render = R3
local K = BCKit
local Cam = BallCast.Cam
local Pup = BallCast.Puppets

function R3.live() return bc3d ~= nil and not R3.forceStatic end

---------------------------------------------------------------------------
-- live renderer (C)

local Live = {}
Live.__index = Live

--- Y (optional): called between chunks of work so a loader coroutine can yield (see scene).
function R3.newLive(park, Y)
  local r = setmetatable({ park = park, ox = 0, oy = 0 }, Live)
  local bk = BallCast.Geo.baked(park)
  if Y then Y() end
  if bk then
    BallCast.Geo.uploadBaked(bk, Y)
    r.geo = bk
    r.presets = Cam.presets(park, bk.cams)
  else
    r.geo = BallCast.Geo.build(park)
    BallCast.Geo.upload(r.geo)
    r.presets = Cam.presets(park)
  end
  r.cam = nil   -- current { ex,ey,ez, tx,ty,tz, fov }
  -- puppet draw counters for the [bcpup] device check (Pup.report)
  r.diag = { calls = 0, far = 0, bb = 0, notrack = 0, culled = 0 }
  R3.diag = r.diag
  -- every puppet table the replay can show, now (sliced), so no imagetable loads mid-play
  local t0 = playdate.getCurrentTimeMilliseconds()
  local nf = Pup.preload(Y)
  print(string.format("[bcload] puppets preloaded %d files in %d ms (slowest file %d ms %s)", nf,
    playdate.getCurrentTimeMilliseconds() - t0, Pup.preloadMax, Pup.preloadMaxName))
  -- impact-effect puff images (juice.lua), prerendered once per session
  if BallCast.Juice and BallCast.Juice.preload then BallCast.Juice.preload(Y) end
  if K.DEBUG then R3.selfTestLive(park) end
  return r
end

--- true when a puppet with its feet at (x, y, z) can't reach the screen (behind the camera, or
--- off an edge by more than its own height + squash/rotation slack): callers skip all the Lua
--- work for it (track sampling, view pick, sprite lookup, bb). Tight cut-ins (deep*, pitcher
--- side) leave most of the 15 puppets off screen.
function Live:offscreen(x, y, z)
  local sx, sy, d = bc3d.project(x, y, z)
  if not sx then return true end
  local h = 6.2 * self.scale / d
  sx, sy = sx + self.ox, sy + self.oy
  if sx < -h or sx > 400 + h or sy < -12 or sy - 1.7 * h > 252 then
    self.diag.culled = self.diag.culled + 1
    return true
  end
  return false
end
-- far cameras (the blimp, ~500 ft up): puppets are 3-7 px, so they're drawn as dots — no view
-- pick, no track sampling, no sprite caches (see Live:puppet / Play putTrack, putIdle, tags)
local FAR_Z <const> = 250
function Live:setCamera(c)
  c = Cam.safeEye(self.park, c)   -- (never inside the stands: see Cam.safeEye)
  self.cam = c
  self.far = c[3] > FAR_Z
  bc3d.camera(c[1], c[2], c[3], c[4], c[5], c[6], c[7])
  self.scale = bc3d.scale()
end

-- Park-render cache (bc3d.store/restore): when the camera hasn't moved by more than ~1 px of
-- picture since the last render, restore that render instead of re-rasterizing the park and
-- stands (the costly part of the blimp and other wide shots). Far cameras tolerate ~1.2 ft of
-- eye/target drift (their slow orbit re-renders every few frames); near cameras only reuse an
-- exactly-held camera, and not while the crowd is bouncing. Re-rendered at least every 30 frames.
-- C park render cost per camera ([bcrender] at scene exit; a restored cached frame counts 0)
local rcAcc = {}
local function renderCost(ms)
  local sc = BallCast.scene
  local cam = sc and sc.curCam or "?"
  local a = rcAcc[cam]
  if not a then a = { 0, 0, 0 }; rcAcc[cam] = a end
  a[1], a[2] = a[1] + ms, a[2] + 1
  if ms == 0 then a[3] = a[3] + 1 end
end
function R3.renderReport()
  for cam, a in pairs(rcAcc) do
    if a[2] > 0 then
      print(string.format("[bcrender] cost cam=%s avg %.2f ms over %d frames (%d from the park cache)", cam, a[1] / a[2], a[2], a[3]))
    end
  end
  rcAcc = {}
end

-- Park-render cache (bc3d.store/restore): reuse the last park render while the picture would
-- move less than ~1 px (eye/target/zoom drift converted to screen px). An excited crowd bobs
-- every 3 frames, so then the cache is refreshed at that rate; otherwise at least every 30 frames.
local CACHE_PX <const>, CACHE_MAX_AGE <const>, CACHE_AGE_EXCITED <const> = 1.0, 30, 3
function Live:background(ox, oy, crowd)
  self.ox, self.oy = ox or 0, oy or 0
  crowd = crowd or 0.3
  -- wave / flashes (set by Play.drawWorld for big moments; one frame late is fine)
  local wave, flash = self.crowdWave or 0, self.crowdFlash or 0
  bc3d.crowd(crowd, wave, flash)
  local c = self.cam
  if bc3d.store and c and self.ox == 0 and self.oy == 0 and wave == 0 and flash == 0 then
    local k = self.pkCam
    -- an excited crowd bobs every 3 frames: re-render at that rate (far shots: crowd is specks)
    local maxAge = (crowd > 0.45 and not self.far) and CACHE_AGE_EXCITED or CACHE_MAX_AGE
    local same = k ~= nil and self.pkAge < maxAge
    if same then
      -- how far would the picture move? eye/target drift as an angle at the target distance,
      -- plus the zoom change, in screen px; reuse the last render below ~0.6 px
      local dx, dy, dz = c[4] - c[1], c[5] - c[2], c[6] - c[3]
      local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
      if dist < 1 then dist = 1 end
      local e = math.abs(c[1] - k[1]) + math.abs(c[2] - k[2]) + math.abs(c[3] - k[3])
      local t = math.abs(c[4] - k[4]) + math.abs(c[5] - k[5]) + math.abs(c[6] - k[6])
      local px = (e + t) / dist * (self.scale or 300) + math.abs(c[7] - k[7]) * 200 / math.max(c[7], 1)
      if px > CACHE_PX then same = false end
    end
    if same and bc3d.restore() then
      self.pkAge = self.pkAge + 1
      self.pkHits = (self.pkHits or 0) + 1
      renderCost(0)
      return
    end
    bc3d.render(0, 0)
    if bc3d.renderMs then renderCost(bc3d.renderMs()) end
    bc3d.store()
    k = k or {}
    for i = 1, 7 do k[i] = c[i] end
    self.pkCam, self.pkAge, self.pkFar = k, 0, self.far
    return
  end
  self.pkCam = nil
  bc3d.render(self.ox, self.oy)
  if bc3d.renderMs then renderCost(bc3d.renderMs()) end
end

--- face (optional): the puppet's world facing yaw in radians (0 = +x, pi/2 = +y). Given a
--- facing, the view table is picked from the camera direction (Pup.orient) and `flip` means
--- "mirror the figure" (left-handed) instead of "face screen-left"; key rotation/offset is
--- mirrored when the chosen view faces screen-left. kflip: the track key's own flip.
--- key: per-puppet hysteresis key (its seed).
local function orient(self, tname, f, x, y, z, flip, rot, dx, face, key, kflip, ex, ey, ez)
  local vt, vf, faceL = Pup.orient(tname, f, x, y, z, face, flip, key, ex, ey, ez)
  if vt then
    tname, f = vt, vf
    flip = (flip and true or false) ~= (kflip and true or false)
  else
    -- no view tables: the legacy side-on art, flipped by where the facing points on screen
    local a = self:project(x, y, z)
    local b = self:project(x + math.cos(face), y + math.sin(face), z)
    faceL = (a and b and b < a) or false
    flip = faceL ~= (kflip and true or false)
  end
  if faceL then rot, dx = -rot, -dx end
  return tname, f, flip, rot, dx
end
R3.orient = orient

function Live:puppet(variant, frame, x, y, z, flip, dx, dy, face, key)
  local dg = self.diag
  if self.far then dg.calls = dg.calls + 1; dg.far = dg.far + 1; bc3d.dot(x, y, (z or 0) + 3, false, true); return end
  if face then
    local tn, f = Pup.tableOf(variant, frame)
    if tn then return self:puppetT(variant, tn, f, x, y, z, flip, 1, 1, 0, dx or 0, dy or 0, 0, face, key, false) end
  end
  dg.calls = dg.calls + 1
  local id, inv = Pup.id(variant, frame)
  Pup.live(id)      -- counts draws with an id C doesn't hold (harness / [bcpup] check: must stay 0)
  local fl = (flip and not inv) or (inv and not flip)
  if (dx and dx ~= 0) or (dy and dy ~= 0) then
    bc3d.bb(id, x, y, z, fl, 1, 1, 1, 0, dx, dy, 0)
  else
    bc3d.bb(id, x, y, z, fl)
  end
  self.diag.bb = self.diag.bb + 1
end
function Live:puppetT(variant, tname, f, x, y, z, flip, sx, sy, rot, dx, dy, piv, face, key, kflip)
  local dg = self.diag
  dg.calls = dg.calls + 1
  if self.far then dg.far = dg.far + 1; bc3d.dot(x, y, (z or 0) + 3, false, true); return end
  if face then
    local c = self.cam
    tname, f, flip, rot, dx = orient(self, tname, f, x, y, z, flip, rot, dx, face, key, kflip, c[1], c[2], c[3])
  end
  local id, inv = Pup.idT(variant, tname, f)
  Pup.live(id)
  local fl = (flip and not inv) or (inv and not flip)
  bc3d.bb(id, x, y, z, fl, 1, sx, sy, rot, dx, dy, piv)
  self.diag.bb = self.diag.bb + 1
end
function Live:ball(x, y, z, s, bias, shadow) bc3d.ball(x, y, z, s, bias, shadow ~= false) end
function Live:dot(x, y, z, white, big) bc3d.dot(x, y, z, white, big) end
function Live:project(x, y, z)
  local sx, sy, d = bc3d.project(x, y, z)
  if not sx then return nil end
  return sx + self.ox, sy + self.oy, d
end
function Live:ppf(d) return self.scale / d end
function Live:finish() bc3d.flush(self.ox, self.oy); Pup.frameDone() end
function Live:release() R3.renderReport(); bc3d.reset() end

--- Check the C projection against parks.json test vectors (debug builds).
function R3.selfTestLive(park)
  local entry = Cam.parkEntry(park)
  if not entry or not entry.cams then return end
  for name, sc in pairs(entry.cams) do
    if sc.eye and sc.tests then
      bc3d.camera(sc.eye[1], sc.eye[2], sc.eye[3], sc.target[1], sc.target[2], sc.target[3], sc.fov_x_deg or 60, sc.cx or 200, sc.cy or 120)
      local worst = 0
      for _, t in ipairs(sc.tests) do
        if t.expect then
          local x, y = bc3d.project(t.p[1], t.p[2], t.p[3])
          local e = x and math.max(math.abs(x - t.expect[1]), math.abs(y - t.expect[2])) or 999
          if e > worst then worst = e end
        end
      end
      print(string.format("[ballcast] C projection test %s/%s: max error %.3f px%s", park and park.id or "?", name, worst, worst > 0.5 and "  <-- MISMATCH" or ""))
    end
  end
end

---------------------------------------------------------------------------
-- static renderer (Lua)

local Static = {}
Static.__index = Static

function R3.newStatic(park)
  local r = setmetatable({ park = park, ox = 0, oy = 0, items = {}, n = 0 }, Static)
  r.rig = Cam.rig(park)
  for i = 1, 40 do r.items[i] = {} end
  return r
end

function Static:use(name)
  local e = self.rig[name] or self.rig.high
  self.entry = e
  self.c = e.cam
end

function Static:background(ox, oy)
  self.ox, self.oy = ox or 0, oy or 0
  Cam.ensureBg(self.entry, self.park):draw(self.ox, self.oy)
  self.n = 0
end

function Static:project(x, y, z)
  local sx, sy, d = Cam.project(self.c, x, y, z)
  if not sx then return nil end
  return sx + self.ox, sy + self.oy, d
end
function Static:ppf(d) return self.c.scale / d end

local function push(self, kind, a, b, x, y, z, flip, big, tf, dx, dy)
  local sx, sy, d = Cam.project(self.c, x, y, z)
  if not sx then return end
  if sx < -60 or sx > 460 or sy < -20 or sy > 300 then return end
  self.n = self.n + 1
  local it = self.items[self.n]
  if not it then it = {}; self.items[self.n] = it end
  it.kind, it.a, it.b, it.sx, it.sy, it.d, it.flip, it.big, it.x, it.y, it.z = kind, a, b, sx, sy, d, flip, big, x, y, z
  it.tf, it.dx, it.dy = tf, dx or 0, dy or 0
end

function Static:puppet(variant, frame, x, y, z, flip, dx, dy, face, key)
  if face then
    local tn, f = Pup.tableOf(variant, frame)
    if tn then return self:puppetT(variant, tn, f, x, y, z, flip, 1, 1, 0, dx or 0, dy or 0, 0, face, key, false) end
  end
  push(self, 0, variant, frame, x, y, z, flip, nil, nil, dx, dy)
end
function Static:puppetT(variant, tname, f, x, y, z, flip, sx, sy, rot, dx, dy, piv, face, key, kflip)
  if face then
    local c = self.c
    tname, f, flip, rot, dx = orient(self, tname, f, x, y, z, flip, rot or 0, dx or 0, face, key, kflip, c.ex, c.ey, c.ez)
  end
  push(self, 0, variant, tname, x, y, z, flip, nil, f, dx, dy)
end
function Static:ball(x, y, z, s, bias, shadow) push(self, 1, nil, nil, x, y, z, shadow == false, nil, nil, nil, nil) end
function Static:dot(x, y, z, white, big) push(self, 2, nil, nil, x, y, z, white, big) end

function Static:finish()
  local items, n = self.items, self.n
  -- insertion sort far → near
  for i = 2, n do
    local v = items[i]
    local j = i - 1
    while j >= 1 and items[j].d < v.d do items[j + 1] = items[j]; j = j - 1 end
    items[j + 1] = v
  end
  local c = self.c
  local ox, oy = self.ox, self.oy
  for i = 1, n do
    local it = items[i]
    if it.kind == 1 and it.z > 0.6 and not it.flip then
      local gx, gy, gd = Cam.project(c, it.x, it.y, 0)
      if gx then
        local r = K.clamp(c.scale * 0.9 / gd, 1.5, 7)
        gfx.setColor(gfx.kColorBlack)
        gfx.fillEllipseInRect(gx + ox - r, gy + oy - r * 0.4, r * 2, r * 0.8 + 1)
      end
    end
  end
  for i = 1, n do
    local it = items[i]
    local sx, sy = it.sx + ox, it.sy + oy
    if it.kind == 0 then
      local ppf = c.scale / it.d
      local k = math.max(0.5, 6.2 * ppf / 40)
      Pup.drawAt(it.a, it.b, sx + floor(it.dx * k + 0.5), sy + floor(it.dy * k + 0.5), ppf, it.flip, it.tf)
    elseif it.kind == 1 then
      local r = K.clamp(c.scale * 0.6 / it.d * (1 + K.clamp(it.z, 0, 140) / 55), 1.5, 10)
      gfx.setColor(gfx.kColorBlack)
      gfx.fillCircleAtPoint(sx, sy, r + 1)
      gfx.setColor(gfx.kColorWhite)
      gfx.fillCircleAtPoint(sx, sy, r)
    else
      gfx.setColor(it.flip and gfx.kColorWhite or gfx.kColorBlack)
      local sz = it.big and 2 or 1
      gfx.fillRect(sx, sy, sz, sz)
    end
  end
  self.n = 0
  Pup.frameDone()
end
function Static:release() end

---------------------------------------------------------------------------
-- the live director's camera: desired shot per (beat, tau), smoothed into moves

local Play -- set lazily (play.lua imports us)

local function lerp(a, b, t) return a + (b - a) * t end

--- desired camera {ex,ey,ez,tx,ty,tz,fov} for a shot name at tau
function R3.shot(r, b, tau, cc, out)
  Play = Play or BallCast.Play
  local P = r.presets
  local name = cc.name
  local plan = b.plan
  local p = P[name] or P.high
  out = out or {}
  local function set(e, t, fov)
    out[1], out[2], out[3], out[4], out[5], out[6], out[7] = e[1], e[2], e[3], t[1], t[2], t[3], fov
    return out
  end
  if name == "pitch" then
    -- classic CF shot, tighter than the static art: pitcher ~80 px, plate in frame
    local fov = p.fov * 0.76
    local push = 0
    if plan.pitch then push = K.clamp((tau - 0.2) / 1.0, 0, 1) * 0.2 end
    local tgt = { p.target[1] * 0.6, 21, 0.5 }
    return set(p.eye, tgt, fov - push)
  end
  local opt = cc.opt or {}
  if opt.establish then
    -- slow orbit behind home: the stadium "beauty shot"
    local a = rad(-24 + tau * 7)
    local e = { sin(a) * 260, -cos(a) * 260 + 40, 95 }
    return set(e, { 0, 160, 10 }, 48)
  end
  local hh = P.high
  -- extra live-only angles (the static rig falls back to "high" for unknown names) ----------
  local side = opt.side or 1
  if name == "behindPlate" then
    -- "high home": up behind the backstop, 9 ft off toward the batter's side (the ump then
    -- hides none of him), framing the
    -- batter, catcher and ump in the lower third and the pitcher up the middle. (Pulled back
    -- to 118 ft / 48 ft up last round to keep the ump's billboard sane, it lost the batter
    -- below the frame; this keeps him in, at about 1x-2x sprite height.)
    local bs = Play.batSide(b.pre and b.pre.bat)          -- 1 = right-handed: stands at x = -3.2
    -- (as low as the park's backstop seats allow: 10 ft over the seat surface there)
    local ex, ey = bs * (R3.BP_SIDE or -9), -90
    local surf = Cam.standZ and Cam.standZ(r.park, ex, ey)
    local ez = math.max(30, (surf or 0) + 11)
    -- aim so the plate sits in the lower third whatever the height
    local ty = 41 - (ez - 30) * 1.2
    return set({ ex, ey, ez }, { bs * 1.5, ty, 0 }, 22 + (ez - 30) * 0.15 - K.clamp(tau * 0.3, 0, 0.5))
  elseif name == "pitcherSide" then
    -- side close-up on the mound, slow push in
    local e = { side * 70, 44, 5.5 }
    return set(e, { 0, 60, 4.0 }, 26 - K.clamp(tau * 1.2, 0, 2.5))
  elseif name == "batterSide" then
    local e = { -side * 70, 18, 5.5 }
    return set(e, { -side * 2, 0.5, 3.8 }, 27 - K.clamp(tau * 1.2, 0, 2.5))
  elseif name == "dugout" then
    -- low from a dugout on the side (1B dugout looks across at SS/3B and vice versa)
    local e = { side * 56, 12, 5 }
    local fx, fy = Play.focusPoint(plan, tau)
    fx, fy = fx or 0, fy or 70
    local tx, ty = lerp(0, fx, 0.6), lerp(64, fy, 0.6)
    return set(e, { tx, ty, 2 }, 52)
  elseif name == "blimp" then
    -- straight down-ish from way up, slowly turning
    -- (tighter than a true blimp: the stands are the expensive part of any frame)
    -- (fov 40 -> 35, aimed a little deeper: less of the stands in frame, the costly part)
    local a = rad(tau * 3 + side * 20)
    return set({ sin(a) * 120, 100 - cos(a) * 120, 520 }, { 0, 140, 0 }, 35)
  elseif name == "wallLow" then
    -- low at the wall where the ball is headed, looking back in and up at it
    local sp = math.rad(b.e.sp or 0)
    local fence = Cam.fenceAt(r.park, b.e.sp or 0)
    -- (the sideways offset is an angle along the wall: a straight 30 ft shift used to put the
    -- eye behind the fence near the lines)
    local sp2 = K.clamp(sp + side * math.rad(5), math.rad(-42), math.rad(42))
    local f2 = Cam.fenceAt(r.park, math.deg(sp2))
    local e = { math.sin(sp2) * (f2 - 14), math.cos(sp2) * (f2 - 14), 6 }
    local bx, by, bz = Play.ballAt(plan, tau)
    if not bx then bx, by, bz = math.sin(sp) * fence * 0.7, math.cos(sp) * fence * 0.7, 6 end
    local d = sqrt((bx - e[1]) ^ 2 + (by - e[2]) ^ 2)
    return set(e, { bx, by, bz * 0.8 }, K.clamp(3600 / (d + 40), 24, 60))
  elseif name == "runner" then
    -- follow the lead runner from outside the diamond, ahead of him
    local rx, ry = Play.leadRunner(plan, tau)
    if not rx then rx, ry = 0, 60 end
    local nx, ny = rx, ry - 64
    local l = sqrt(nx * nx + ny * ny)
    if l < 1 then nx, ny, l = 1, 0, 1 end
    nx, ny = nx / l, ny / l
    local e = { rx + nx * 75 - ny * 25 * side, ry + ny * 75 + nx * 25 * side, 22 }
    return set(e, { rx, ry, 3 }, 34)
  end
  if name == "deepL" or name == "deepC" or name == "deepR" then
    -- track the ball from high home; as it comes down, cut in tight on the fielder
    local bx, by, bz = Play.ballAt(plan, tau)
    local tc = plan.catchT
    if tc and tau >= tc - 1.1 and plan.catchPos then
      local cx, cy = plan.catchPos[1], plan.catchPos[2]
      local d = sqrt((cx - hh.eye[1]) ^ 2 + (cy - hh.eye[2]) ^ 2)
      local fov = K.clamp(2 * math.deg(math.atan(200 / (40 / 6.2 * d))), 6, 30)
      return set(hh.eye, { cx, cy, plan.catchZ or 4 }, fov)
    end
    if not bx then bx, by, bz = 0, 200, 20 end
    local d = sqrt((bx - hh.eye[1]) ^ 2 + (by - hh.eye[2]) ^ 2)
    local fov = K.clamp(4200 / (d + 60), 18, 42)
    -- aim below the ball: keeps the field (cheap, readable) in the lower frame, stands up top
    return set(hh.eye, { bx, by, bz * 0.7 }, fov)
  end
  if name == "high" then
    -- frame the action: everything that matters right now (ball, the fielder making the
    -- play, the man taking the throw, runners) fits, with a margin; else the infield
    local x0, x1, y0, y1, fz = Play.interest(plan, tau)
    if opt.incident == "BRAWL" then x0, x1, y0, y1, fz = -40, 40, 20, 70, 3 end
    if not x0 then x0, x1, y0, y1, fz = -60, 60, 10, 140, 0 end
    local tx, ty = (x0 + x1) * 0.5, (y0 + y1) * 0.5
    local d = sqrt((tx - hh.eye[1]) ^ 2 + (ty - hh.eye[2]) ^ 2)
    -- the camera sits behind home, so field x spread is screen width, y spread is foreshortened
    local w = max(x1 - x0, (y1 - y0) * 0.55) + 50
    local fov = K.clamp(math.deg(2 * math.atan(w * 0.5 / d)), 18, 46)
    -- broadcast-style re-framing: the aim snaps to a 20 ft grid and the zoom to 3 deg steps;
    -- (40 ft / 4 deg) the scene's smoothing glides between framings and then HOLDS (so the park render cache
    -- can reuse the frame: the high shot used to drift every frame and never hit it)
    tx, ty = floor(tx / 40 + 0.5) * 40, floor(ty / 40 + 0.5) * 40
    fov = K.clamp(floor(fov / 4 + 0.5) * 4, 18, 46)
    return set(hh.eye, { tx, ty, floor(fz * 0.5 + 0.5) }, fov)
  end
  return set(p.eye, p.target, p.fov)
end

return R3
