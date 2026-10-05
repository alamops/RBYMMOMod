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

-- One draw into 0..span-1 off the state's HIGH bits (contract K12): its high
-- 16 bits (16..31) modulo the span.  `next() % span` kept the low bits, and an
-- LCG's bit k cycles with period 2^(k+1) -- bit 0 alternates, bits 0..1 repeat
-- every four draws -- so a crit at chance 4 or 2 and the 16-wide damage roll
-- followed a fixed pattern set by the draw's position in the stream.  The same
-- rule as Gen 1's BattleSim/Rng.lua (one K12 for both referees), exact in both
-- runtimes: `floor(s / 65536)` of a state under 2^32 is an integer in a double
-- and in V8.  A span wider than 65536 (no referee caller has one) stitches two
-- high halves into a 32-bit value first, still exact.
local function high16(self)
  return floor(self:next() / 65536)
end

local function scaled(self, span)
  if span <= 65536 then return high16(self) % span end
  local top = high16(self)               -- two statements: Lua leaves the
  local bottom = high16(self)            -- order of operands unspecified
  return (top * 65536 + bottom) % span
end

-- 0..n-1, matching engine Damage.rollCritical / rand(..., n).
function M:below(n)
  local span = floor(tonumber(n) or 0)
  if span <= 1 then return 0 end
  return scaled(self, span)
end

function M:nextInt(min, max)
  local lo, hi = tonumber(min), tonumber(max)
  if not lo and not hi then return self:byte() end
  lo = floor(lo or 0)
  hi = floor(hi or lo)
  if hi < lo then lo, hi = hi, lo end
  local span = hi - lo + 1
  if span <= 1 then return lo end
  return lo + scaled(self, span)
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
