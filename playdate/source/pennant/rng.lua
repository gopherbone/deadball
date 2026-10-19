-- Seeded RNG for Pennant (xorshift32; deterministic per seed, independent of math.random so a
-- league generated from seed N is always the same league). Written for 32-bit integers (the
-- Playdate's Lua) and gives the same numbers with 64-bit ones (desktop tests): every step is
-- masked to 32 bits and shifts are logical.

PRng = PRng or {}
PRng.__index = PRng

local M32 <const> = 0xFFFFFFFF

function PRng.new(seed)
  local s = (math.tointeger(seed) or math.floor(seed or 1)) & M32
  if s == 0 then s = 0x2545F491 end
  local r = setmetatable({ s = s }, PRng)
  for _ = 1, 6 do r:next() end
  return r
end

--- 31-bit non-negative integer.
function PRng:next()
  local x = self.s
  x = (x ~ (x << 13)) & M32
  x = (x ~ (x >> 17)) & M32
  x = (x ~ (x << 5)) & M32
  self.s = x
  return (x >> 1) & 0x7FFFFFFF
end

--- [0, 1)
function PRng:float()
  return self:next() / 2147483648.0
end

--- 1..n
function PRng:int(n)
  return (self:next() % n) + 1
end

function PRng:range(a, b)
  return a + (b - a) * self:float()
end

function PRng:chance(p)
  return self:float() < p
end

function PRng:normal(m, sd)
  -- Box-Muller (one value; cheap enough)
  local u = self:float()
  if u < 1e-9 then u = 1e-9 end
  local v = self:float()
  return (m or 0) + (sd or 1) * math.sqrt(-2 * math.log(u)) * math.cos(6.283185307 * v)
end

function PRng:pick(t)
  return t[self:int(#t)]
end

--- A child stream (so adding draws to one system doesn't reshuffle another).
function PRng:fork(salt)
  return PRng.new((self:next() * 7919 + (salt or 0) * 104729 + 1) & 0x7FFFFFFF)
end
