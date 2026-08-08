-- Gen1 critical hits, including the Focus Energy bug.
--
--   threshold = floor(baseSpeed / 2)
--   Focus Energy:  threshold = floor(threshold / 4)
--   high-crit move: threshold = threshold * 8
--   clamp to 0..255, then isCrit = roll < threshold
--
-- Focus Energy *quarters* the threshold instead of doubling it.  That is the
-- original's famous inverted shift and it is kept, for the same reason the
-- 1/256 miss is kept in Accuracy.lua: this sim has to resolve a fight the way
-- the game the players are playing would resolve it, not the way the manual
-- says it should.  A mod that silently corrected it would make every mediated
-- battle diverge from every offline one.
--
-- The clamp gives the two ends their behaviour for free: a threshold of 0
-- never crits (no roll is below 0) and a threshold of 255 still fails on roll
-- 255, so nothing in Gen1 crits every single turn.
--
-- Note this is *base* speed, the species' constant -- not the battler's
-- current speed, which is why paralysis quartering speed does not lower the
-- crit rate.
--
-- Nothing here raises; no love, no engine modules, no mod facade.

local need = ...            -- entry-chunk shape; this module resolves nothing

local M = {}

local floor, max, min = math.floor, math.max, math.min

M.MIN = 0
M.MAX = 255
M.HIGH_RATIO = 8

local function int(value, fallback)
  local n = tonumber(value)
  if not n or n ~= n then return fallback end
  return floor(n)
end

-- opts: { focusEnergy, highCritMove }
function M.threshold(baseSpeed, opts)
  opts = opts or {}
  local t = floor(max(0, int(baseSpeed, 0)) / 2)
  if opts.focusEnergy then t = floor(t / 4) end
  if opts.highCritMove then t = t * M.HIGH_RATIO end
  return min(M.MAX, max(M.MIN, t))
end

-- Returns isCrit (boolean) and the threshold it was decided against, so a
-- caller logging a surprising crit can show the number without recomputing it.
function M.check(baseSpeed, roll, opts)
  local threshold = M.threshold(baseSpeed, opts)
  return int(roll, M.MAX) < threshold, threshold
end

return M
