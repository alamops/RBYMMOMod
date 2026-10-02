-- Gen1 critical hits, including the Focus Energy bug.
--
-- pokered's CriticalHitTest (engine/battle/core.asm :4478-4540), one shift at
-- a time, every left shift held at 255:
--
--   b = floor(baseSpeed / 2)
--   Focus Energy:   b = floor(b / 2)        (`srl b` -- the bug: it should
--                                            have been a left shift)
--   otherwise:      b = min(255, b * 2)
--   high-crit move: b = min(255, b * 2), then min(255, b * 2) again
--   otherwise:      b = floor(b / 2)
--   isCrit = roll < b
--
-- So an ordinary move lands on floor(baseSpeed/2), a high-crit move on
-- min(255, 8 * floor(baseSpeed/2)), Focus Energy alone on a quarter of the
-- ordinary threshold -- the original's famous inverted shift, kept for the
-- same reason the 1/256 miss is kept in Accuracy.lua: this sim has to resolve
-- a fight the way the game the players are playing would resolve it, not the
-- way the manual says it should.  Focus Energy *with* a high-crit move is the
-- case a "quarter it, then times eight" shortcut gets wrong: the halving
-- happens before the doubling chain, so the threshold is 4 * floor(b0 / 2)
-- (b0 = floor(baseSpeed / 2)) -- 100 for a base Speed of 100, not 96.
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
-- What the high-crit chain multiplies an unpumped threshold by, end to end
-- (the x2 every move gets, then two more), kept as a named number for logs.
M.HIGH_RATIO = 8

local function int(value, fallback)
  local n = tonumber(value)
  if not n or n ~= n then return fallback end
  return floor(n)
end

-- One left shift of the 8-bit register: carry out means "cap at 255/256".
local function sla(b)
  return min(M.MAX, b * 2)
end

-- opts: { focusEnergy, highCritMove }
function M.threshold(baseSpeed, opts)
  opts = opts or {}
  local b = floor(min(M.MAX, max(0, int(baseSpeed, 0))) / 2)
  if opts.focusEnergy then
    b = floor(b / 2)
  else
    b = sla(b)
  end
  if opts.highCritMove then
    b = sla(sla(b))
  else
    b = floor(b / 2)
  end
  return min(M.MAX, max(M.MIN, b))
end

-- Returns isCrit (boolean) and the threshold it was decided against, so a
-- caller logging a surprising crit can show the number without recomputing it.
function M.check(baseSpeed, roll, opts)
  local threshold = M.threshold(baseSpeed, opts)
  return int(roll, M.MAX) < threshold, threshold
end

return M
