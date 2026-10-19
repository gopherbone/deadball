-- Smooth vertical scrolling: crank with inertia, eased scrollTo for focus moves,
-- soft rubber-band at the ends. No allocation per frame.

Scroller = Scroller or {}
Scroller.__index = Scroller

function Scroller.new(max)
  return setmetatable({ pos = 0, vel = 0, max = max or 0, target = nil, idle = 0 }, Scroller)
end

function Scroller:setMax(m)
  self.max = math.max(0, m)
  if self.pos > self.max then self.pos = self.max end
  if self.target and self.target > self.max then self.target = self.max end
end

function Scroller:crank(change)
  if self.max <= 0 then return end
  self.target = nil
  -- accelerate gently: slow cranking is precise, fast cranking flings
  local a = math.abs(change)
  local k = a < 6 and 0.9 or (a < 20 and 1.3 or 1.8)
  self.vel = self.vel * 0.5 + change * k * 0.5
  self.pos += change * k * 0.5
  self.idle = 0
end

function Scroller:scrollTo(y)
  self.target = math.max(0, math.min(self.max, math.floor(y)))
  self.vel = 0
end

function Scroller:scrollBy(dy)
  self:scrollTo((self.target or self.pos) + dy)
end

function Scroller:jump(y)
  self.pos = math.max(0, math.min(self.max, y))
  self.target = nil
  self.vel = 0
end

--- Returns true while moving.
function Scroller:update()
  self.idle += 1
  if self.target then
    local d = self.target - self.pos
    if math.abs(d) < 0.6 then
      self.pos = self.target
      self.target = nil
    else
      self.pos += d * 0.34
    end
  elseif math.abs(self.vel) > 0.05 then
    self.pos += self.vel * 0.5
    self.vel *= 0.86
  else
    self.vel = 0
  end
  -- rubber band
  if self.pos < 0 then
    self.pos *= 0.5
    if self.pos > -0.5 then self.pos = 0 end
    self.vel = 0
  elseif self.pos > self.max then
    self.pos = self.max + (self.pos - self.max) * 0.5
    if self.pos - self.max < 0.5 then self.pos = self.max end
    self.vel = 0
  end
  return self.target ~= nil or self.vel ~= 0
end

function Scroller:y()
  return math.floor(self.pos + 0.5)
end
