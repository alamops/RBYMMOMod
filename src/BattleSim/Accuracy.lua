-- Gen1 accuracy: the 1/256 miss, written down on purpose.
--
-- Accuracy is an 8-bit value in 1..255 and the roll is a byte in 0..255, so
-- there are 256 rolls for at most 255 hitting values and a "100%" move misses
-- once in 256 tries.  That is a bug in the original and it is reproduced here,
-- because a mediated battle that quietly fixed it would resolve differently
-- from the same battle fought offline -- and players notice the fix, not the
-- faithfulness.
--
--   effectiveAccuracy = clamp(floor(floor(acc * accMod/100) * evaMod/100), 1, 255)
--   hit               = roll < effectiveAccuracy
--
-- The two modifier steps truncate separately, matching the original's
-- successive 8-bit multiplies, and the clamp is what stops a stack of
-- accuracy drops from reaching an unmissable 0 or a boost from reaching a
-- never-missing 256.
--
-- `alwaysHits` bypasses the roll entirely and reports no effective accuracy at
-- all -- there is no number to report, and returning 255 instead would be a
-- lie a caller could act on (it would still miss one time in 256).
--
-- Nothing here raises; no love, no engine modules, no mod facade.

local need = ...            -- entry-chunk shape; this module resolves nothing

local M = {}

local floor, max, min = math.floor, math.max, math.min

M.MIN = 1
M.MAX = 255

local function int(value, fallback)
  local n = tonumber(value)
  if not n or n ~= n then return fallback end
  return floor(n)
end

-- accuracy: 0..255 (the move's own value)
-- accuracyMod / evasionMod: percents, 100 being unmodified
function M.effective(accuracy, accuracyMod, evasionMod)
  local acc = max(0, int(accuracy, M.MAX))
  local value = floor(acc * max(0, int(accuracyMod, 100)) / 100)
  value = floor(value * max(0, int(evasionMod, 100)) / 100)
  return min(M.MAX, max(M.MIN, value))
end

-- Returns hit (boolean) and the effective accuracy it was decided against,
-- which is nil for a move that cannot miss.  Two returns rather than a table
-- because the answer callers want is almost always just the boolean.
--
-- opts: { accuracyMod, evasionMod, alwaysHits }
function M.hit(moveAccuracy, roll, opts)
  opts = opts or {}
  if opts.alwaysHits then return true, nil end
  local effective = M.effective(moveAccuracy, opts.accuracyMod, opts.evasionMod)
  return int(roll, 0) < effective, effective
end

return M
