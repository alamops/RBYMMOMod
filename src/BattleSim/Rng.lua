-- Deterministic RNG for the mediated battle sim.
--
-- The intermediator exists in two runtimes (this file and its twin under
-- server/lib/battle/), and both have to produce the *same* battle from the
-- same seed -- otherwise a fight brokered by a LAN host and the same fight
-- brokered by the Node hub are different games, and the fixture vectors that
-- pin them together stop meaning anything.  math.random cannot do that: its
-- sequence is the interpreter's, not ours, and LuaJIT's differs from
-- Lua 5.4's differs from V8's.
--
-- So: a plain 32-bit LCG, chosen because it is exactly reproducible in both
-- languages with no bignum work.  `state = (1664525 * state + 1013904223) mod
-- 2^32` (Numerical Recipes' constants).  In Lua the intermediate product tops
-- out near 7.2e15, comfortably inside a double's exact-integer range (2^53),
-- so the arithmetic is exact without the bit library; in JS the same step is
-- `(Math.imul(1664525, state) + 1013904223) >>> 0`.  Two lines, one sequence.
--
-- Draws come off bits 16..23 rather than the low byte: an LCG's low bits
-- cycle with a short period (bit 0 alternates every step), which would make a
-- paralysis coin flip visibly regular over a long battle.
--
-- Nothing here raises.  A bad seed or a reversed range is normalised rather
-- than rejected, because every caller is downstream of a mod callback where a
-- bare error() is a loader rule violation -- and a battle that stops mid-turn
-- because a range came in backwards is worse than one that plays on.
--
-- No love, no engine modules, no mod facade: pure arithmetic on purpose, so
-- the headless vector suite runs it unmodified.

local need = ...            -- entry-chunk shape; this module resolves nothing

local M = {}
M.__index = M

local floor = math.floor

local TWO32 = 4294967296
local MULT, INCR = 1664525, 1013904223

-- Gen1's damage variance draws from this closed band; both runtimes need the
-- same two numbers, and they belong with the generator that produces them.
M.DAMAGE_ROLL_MIN = 217
M.DAMAGE_ROLL_MAX = 255

local function normaliseSeed(seed)
  local n = tonumber(seed)
  if not n or n ~= n then return 0 end        -- nil, non-numeric, or NaN
  n = floor(n) % TWO32
  if n < 0 then n = n + TWO32 end
  return n
end

-- seed: any number; nil is 0, which is a perfectly good LCG start because the
-- increment is non-zero.
function M.new(seed)
  return setmetatable({ s = normaliseSeed(seed) }, M)
end

-- The raw 32-bit step.  Exposed because the JS twin's parity test compares
-- states, not just draws.
function M:next()
  self.s = (MULT * self.s + INCR) % TWO32
  return self.s
end

-- 0..255, the unit every Gen1 gate in this sim is expressed in.
function M:byte()
  return floor(self:next() / 65536) % 256
end

-- Inclusive on both ends.  A reversed or partly-nil range is repaired rather
-- than refused; a zero-width range consumes no draw so a caller cannot desync
-- the two runtimes by asking for a constant.
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

-- Snapshot / restore, so a reconnecting client can be replayed from a known
-- point without re-rolling the turns it already saw.
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
