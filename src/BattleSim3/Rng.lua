-- Deterministic RNG for the Gen 3 mediated battle sim.
--
-- The same LCG as BattleSim/Rng.lua and BattleSim2/Rng.lua, so a hub carries one
-- generator shape across all three generations:
--
--   s = (1664525 * s + 1013904223) mod 2^32
--
-- What differs is the one primitive every Gen 3 draw site uses.  The engine asks
-- for `roll(lo, hi)` at every random point (src/core/game3/battle/engine.lua
-- `roll`, adapter `roll`), and so does this sim -- but it must not be
-- `lo + s % span`.  An LCG modulo a power of two has a short period in its low
-- bits (bit 0 alternates every step), so a coin flip taken that way is a rota,
-- not a coin: confusion would hit on every other turn and never twice running.
-- `roll` therefore reads the TOP of the state:
--
--   roll(lo, hi) = lo + floor(s * (hi - lo + 1) / 2^32)
--
-- which is a multiply-high: every bit of the state contributes, and the product
-- stays exact in a double (s < 2^32 and every span this sim draws is ≤ 2^16, so
-- the product is < 2^48).  The Node twin computes the same expression with the
-- same doubles.
--
-- A range with one value (or an inverted one) returns `lo` and draws NOTHING.
-- That is part of the draw-order contract: "a random target among one living
-- foe" costs no state on either runtime.
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
  return setmetatable({ s = normaliseSeed(seed), draws = 0 }, M)
end

function M:next()
  self.s = (MULT * self.s + INCR) % TWO32
  self.draws = self.draws + 1
  return self.s
end

-- The Gen 3 primitive.  Inclusive on both ends, like the engine's roll(lo, hi).
function M:roll(lo, hi)
  lo = floor(tonumber(lo) or 0)
  hi = floor(tonumber(hi) or lo)
  if hi <= lo then return lo end
  local span = hi - lo + 1
  return lo + floor(self:next() * span / TWO32)
end

-- 85..100, the damage variance band (pret `100 - Random() % 16`).
function M:damageRoll()
  return self:roll(M.DAMAGE_ROLL_MIN, M.DAMAGE_ROLL_MAX)
end

-- Kept for callers ported from BattleSim2 (the aim stream draws with byte()).
function M:byte()
  return floor(self:next() / 65536) % 256
end

function M:state()
  return self.s
end

function M:setState(value)
  self.s = normaliseSeed(value)
  return self
end

function M:clone()
  return setmetatable({ s = self.s, draws = self.draws }, M)
end

-- A scripted stand-in with the same interface, for the vector pack and for the
-- engine cross-check: `values` is consumed in order, and a draw past the end (or
-- outside the requested range) answers the range's top, which is the engine
-- test harness's own default (tests/game3_battle_items_abilities_test.lua
-- mkRng).  Never used by the turn machine.
function M.scripted(values)
  local list = type(values) == "table" and values or {}
  local script = { i = 0, draws = 0, log = {} }
  function script:roll(lo, hi)
    lo = floor(tonumber(lo) or 0)
    hi = floor(tonumber(hi) or lo)
    if hi <= lo then return lo end
    self.i = self.i + 1
    self.draws = self.draws + 1
    local v = list[self.i]
    self.log[#self.log + 1] = { lo = lo, hi = hi, v = v }
    v = tonumber(v)
    if v == nil or v < lo or v > hi then return hi end
    return floor(v)
  end
  function script:damageRoll() return self:roll(M.DAMAGE_ROLL_MIN, M.DAMAGE_ROLL_MAX) end
  function script:state() return self.i end
  return script
end

return M
