-- Lineup: batting order + positions (pick a row with A, then another row or a bench player to
-- swap; left/right changes his position), and the pitching staff: a five-man rotation and
-- bullpen roles (left/right on a reliever: closer / setup / middle / long). Auto buttons for both.

local gfx <const> = playdate.graphics
PennantUI = PennantUI or {}

local Lineup = PUI.define({ title = "Lineup", hint = "A: pick, then A on another to swap  left/right: position / role" })
PennantUI.Lineup = Lineup

local POS_CYCLE <const> = { "C", "1B", "2B", "3B", "SS", "LF", "CF", "RF", "DH" }

function Lineup:init(args)
  self.tab = args.tab or "bat"
  self.pick = nil
  local L = Pennant.L
  PRoster.validate(L, L.teams[L.user])
end
function Lineup:resume(r) Page.resume(self, r) self:render(true) end

--- Positions problems: missing / doubled.
function PennantUI.lineupProblems(L, T)
  local seen, probs = {}, {}
  for _, id in ipairs(T.order or {}) do
    local pos = T.field[id] or "DH"
    if seen[pos] then probs[#probs + 1] = "Two at " .. pos end
    seen[pos] = true
  end
  for _, pos in ipairs(POS_CYCLE) do if not seen[pos] then probs[#probs + 1] = "Nobody at " .. pos end end
  return probs
end

function Lineup:swapOrder(a, b)
  -- a, b: { kind = "order"|"bench", id, slot }
  local L = Pennant.L
  local T = L.teams[L.user]
  if a.kind == "order" and b.kind == "order" then
    T.order[a.slot], T.order[b.slot] = T.order[b.slot], T.order[a.slot]
  else
    local o, bn = a.kind == "order" and a or b, a.kind == "bench" and a or b
    if o.kind ~= "order" or bn.kind ~= "bench" then return end
    local out = T.order[o.slot]
    T.order[o.slot] = bn.id
    T.field[bn.id] = T.field[out] or "DH"
    T.field[out] = nil
  end
end

function Lineup:swapStaff(a, b)
  local L = Pennant.L
  local T = L.teams[L.user]
  if a.kind == "rot" and b.kind == "rot" then
    T.rot[a.slot], T.rot[b.slot] = T.rot[b.slot], T.rot[a.slot]
  else
    local r, p = a.kind == "rot" and a or b, a.kind == "pen" and a or b
    if r.kind ~= "rot" or p.kind ~= "pen" then return end
    local out = T.rot[r.slot]
    local role = T.pen[p.id]
    T.rot[r.slot] = p.id
    T.pen[p.id] = nil
    T.pen[out] = role or "MR"
  end
end

function Lineup:choose(item)
  if not self.pick then
    self.pick = item
    Sfx.select()
  else
    local a = self.pick
    self.pick = nil
    if a.id == item.id then Sfx.back() self:render(true) return end
    if self.tab == "bat" then self:swapOrder(a, item) else self:swapStaff(a, item) end
    Sfx.coin()
  end
  self:render(true)
end

local function ratingCols(p, x, y, keys)
  for i, k in ipairs(keys) do
    local v = math.floor(p.r[k] or 0)
    Text.draw(PM.grade(v), x + (i - 1) * 24, y, UI.fonts.bold)
    Text.draw(tostring(v), x + (i - 1) * 24 + 9, y, UI.fonts.body)
  end
end

function Lineup:row(Lb, p, y, label, item, extra, adj)
  local picked = self.pick and self.pick.id == p.id
  if picked then
    -- picked: a heavy outline and a pointer
    gfx.setLineWidth(2)
    gfx.drawRect(2, y - 2, 391, 17)
    gfx.setLineWidth(1)
    Text.draw("\u{25c0}", 390, y, UI.fonts.bold, nil, "right")
  end
  Text.draw(label, 6, y, UI.fonts.bold)
  Text.draw(Text.ellipsize(PM.short(p), UI.fonts.body, 92), 50, y, UI.fonts.body)
  Text.draw(p.pos == "P" and p.throws or p.bats, 146, y, UI.fonts.body)
  if p.inj then PUI.cross(158, y + 1) else PUI.arrow(158, y + 1, p.cond) end
  PUI.fatigue(174, y + 4, p.fat, 20)
  if extra then extra(p, 200, y) end
  Lb:link(2, y - 1, 391, 16, function() self:choose(item) end,
    { id = "r" .. p.id, style = "invert", hint = PM.name(p) .. (picked and ": picked. A on another to swap" or ": A to pick" .. (adj and ", left/right to change" or "")),
      data = adj and { adj = adj } or nil })
end

function Lineup:layout(Lb)
  local L = Pennant.L
  local T = L.teams[L.user]
  local y = PUI.tabs(Lb, {
    { "bat", "Batting order", function() self.tab = "bat" self.pick = nil self:render() end },
    { "pit", "Pitching staff", function() self.tab = "pit" self.pick = nil self:render() end },
  }, self.tab, 2)
  if self.tab == "bat" then
    Lb:button("Auto lineup", 300, 2, 90, 15, function() PRoster.autoLineup(L, T) self.pick = nil Sfx.coin() self:render(true) end, { id = "auto", hint = "Let the coaches pick positions and the order" })
    local probs = PennantUI.lineupProblems(L, T)
    if #probs > 0 then
      gfx.fillRect(4, y, 388, 14)
      Text.draw("! " .. table.concat(probs, ", "), 8, y, UI.fonts.bold, "white")
      y = y + 16
    end
    Text.draw("#  POS", 6, y, UI.fonts.body) Text.draw("CON  POW  EYE  SPD  FLD", 200, y, UI.fonts.body)
    gfx.drawLine(4, y + 13, 392, y + 13)
    y = y + 16
    for slot, id in ipairs(T.order or {}) do
      local p = L.players[id]
      local pos = T.field[id] or "DH"
      self:row(Lb, p, y, slot .. "  " .. pos, { kind = "order", id = id, slot = slot }, function(pp, x, yy) ratingCols(pp, x, yy, { "con", "pow", "eye", "spd", "fld" }) end,
        function(d)
          local cur = 9
          for i, ps in ipairs(POS_CYCLE) do if ps == pos then cur = i end end
          T.field[id] = POS_CYCLE[(cur - 1 + d) % #POS_CYCLE + 1]
        end)
      y = y + 16
    end
    y = PUI.head(Lb, "Bench", 4, y + 4, 388)
    for _, id in ipairs(PRoster.bench(L, T)) do
      local p = L.players[id]
      self:row(Lb, p, y, p.pos, { kind = "bench", id = id }, function(pp, x, yy) ratingCols(pp, x, yy, { "con", "pow", "eye", "spd", "fld" }) end)
      y = y + 16
    end
    for _, p in ipairs(PRoster.hitters(L, T)) do
      if p.inj then
        Text.draw(p.pos .. "  " .. PM.short(p) .. " \u{2014} " .. p.inj.k .. ", back " .. PL.date(L, L.day + p.inj.d), 6, y, UI.fonts.body)
        y = y + 14
      end
    end
  else
    Lb:button("Auto staff", 300, 2, 90, 15, function() PRoster.autoPitching(L, T) self.pick = nil Sfx.coin() self:render(true) end, { id = "auto", hint = "Let the pitching coach set the rotation and roles" })
    Text.draw("ROTATION", 6, y, UI.fonts.head)
    Text.draw("VEL  CTL  STF  STA", 200, y + 2, UI.fonts.body)
    Text.draw("ERA", 392, y + 2, UI.fonts.body, nil, "right")
    y = y + 18
    for slot, id in ipairs(T.rot or {}) do
      local p = L.players[id]
      local label = slot .. (slot == T.rotIdx and "\u{25b6}" or "")
      self:row(Lb, p, y, label, { kind = "rot", id = id, slot = slot }, function(pp, x, yy)
        ratingCols(pp, x, yy, { "velo", "ctl", "stf", "sta" })
        Text.draw(string.format("%.2f", PM.era(pp.st.p)), 392, yy, UI.fonts.body, nil, "right")
      end)
      y = y + 16
    end
    y = PUI.head(Lb, "BULLPEN", 4, y + 4, 388)
    local pen = {}
    for id, role in pairs(T.pen or {}) do if L.players[id] then pen[#pen + 1] = { id = id, role = role } end end
    local RO = { CL = 1, SU = 2, MR = 3, LR = 4 }
    table.sort(pen, function(a, b) if a.role ~= b.role then return RO[a.role] < RO[b.role] end return a.id < b.id end)
    for _, e in ipairs(pen) do
      local p = L.players[e.id]
      self:row(Lb, p, y, e.role, { kind = "pen", id = e.id }, function(pp, x, yy)
        ratingCols(pp, x, yy, { "velo", "ctl", "stf", "sta" })
        local s = pp.st.p
        Text.draw(string.format("%.2f", PM.era(s)) .. ((s.sv or 0) > 0 and (" " .. s.sv .. "sv") or ""), 392, yy, UI.fonts.body, nil, "right")
      end, function(d)
        local cur = RO[T.pen[e.id]] or 3
        T.pen[e.id] = PRoster.ROLES[(cur - 1 + d) % 4 + 1]
      end)
      y = y + 16
    end
    Text.draw("CL closes leads of 1-3 in the 9th; SU the 8th; LR goes long early.", 6, y + 4, UI.fonts.body)
    y = y + 18
  end
  Lb:mark(y + 4)
end

function Lineup:initialFocus()
  for i, l in ipairs(self.links) do if l.id and l.id:sub(1, 1) == "r" then return i end end
  return 1
end

function Lineup:goBack()
  if self.pick then self.pick = nil Sfx.back() self:render(true) return end
  Page.goBack(self)
end
