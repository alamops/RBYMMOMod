-- Deterministic RNG for the Gen 2 mediated battle sim.
--
-- Same LCG as Gen 1 BattleSim/Rng.lua so Lua and the future Node twin share
-- one sequence.  Only the damage-variance band differs: Gen 2 draws 85..100
-- inclusive (engine Damage.MIN_VARIATION / MAX_VARIATION).
--
-- No love, no engine modules, no mod facade.

local need = ...

local M = {}
M.__index = M

local floor = math.floor

local TWO32 = 4294967296
local MULT, INCR = 1664525, 1013904223

M.DAMAGE_ROLL_MIN = 85
M.DAMAGE_ROLL_MAX = 100

local function normaliseSeed(seed)
  local n = tonumber(seed)
  if not n or n ~= n then return 0 end
  n = floor(n) % TWO32
  if n < 0 then n = n + TWO32 end
  return n
end

function M.new(seed)
  return setmetatable({ s = normaliseSeed(seed) }, M)
end

function M:next()
  self.s = (MULT * self.s + INCR) % TWO32
  return self.s
end

function M:byte()
  return floor(self:next() / 65536) % 256
end

-- 0..n-1, matching engine Damage.rollCritical / rand(..., n).
function M:below(n)
  local span = floor(tonumber(n) or 0)
  if span <= 1 then return 0 end
  return self:next() % span
end

function M:nextInt(min, max)
  local lo, hi = tonumber(min), tonumber(max)
  if not lo and not hi then return self:byte() end
  lo = floor(lo or 0)
  hi = floor(hi or lo)
  if hi < lo then lo, hi = hi, lo end
  local span = hi - lo + 1
  if span <= 1 then return lo end
  return lo + (self:next() % span)
end

function M:damageRoll()
  return self:nextInt(M.DAMAGE_ROLL_MIN, M.DAMAGE_ROLL_MAX)
end

function M:state()
  return self.s
end

function M:setState(value)
  self.s = normaliseSeed(value)
  return self
end

function M:clone()
  return setmetatable({ s = self.s }, M)
end

return M
