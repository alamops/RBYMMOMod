-- Gen 2 accuracy: percent domain with stat stages, not Gen 1's 1/256 miss.
--
-- Engine: src/battle/gen2/Damage.lua Damage.rollHit.  Accuracy of 0 (or
-- alwaysHits) means never miss (Swift).  Otherwise:
--
--   value = accuracy scaled by attacker accuracy stage and defender evasion
--           stage (same STAGE table as damage), clamped to 1..100
--   hit   = roll < value   for roll in 0..99
--
-- There is no Gen 1-style "100% still misses 1/256" quirk: a 100% move with
-- neutral stages hits on every roll 0..99.
--
-- Callers may pass stages (-6..+6) or legacy percent mods (100 = neutral);
-- stages win when present.
--
-- Nothing here raises; no love, no engine modules, no mod facade.

local need = ...

local M = {}

local floor, max, min = math.floor, math.max, math.min

M.MIN = 1
M.MAX = 100
M.ROLL_MAX = 99

-- Same STAGE table as engine Damage.lua / this sim's Damage.applyStage.
local STAGE = {
  [-6] = { 25, 100 }, [-5] = { 28, 100 }, [-4] = { 33, 100 },
  [-3] = { 40, 100 }, [-2] = { 50, 100 }, [-1] = { 66, 100 },
  [0] = { 1, 1 },
  [1] = { 15, 10 }, [2] = { 2, 1 }, [3] = { 25, 10 },
  [4] = { 3, 1 }, [5] = { 35, 10 }, [6] = { 4, 1 },
}

local function int(value, fallback)
  local n = tonumber(value)
  if not n or n ~= n then return fallback end
  return floor(n)
end

local function stageMul(stage)
  local entry = STAGE[max(-6, min(6, int(stage, 0)))]
  return entry[1], entry[2]
end

-- accuracy: move accuracy in 0..100 (0 = never miss).
-- accuracyStage / evasionStage: -6..+6.
function M.effective(accuracy, accuracyStage, evasionStage)
  local acc = max(0, int(accuracy, M.MAX))
  if acc <= 0 then return nil end
  local num, den = stageMul(accuracyStage)
  local value = floor(acc * num / den)
  num, den = stageMul(-(int(evasionStage, 0)))
  value = floor(value * num / den)
  return min(M.MAX, max(M.MIN, value))
end

-- Percent-mod path for fixtures that do not carry stages.
function M.effectiveFromMods(accuracy, accuracyMod, evasionMod)
  local acc = max(0, int(accuracy, M.MAX))
  if acc <= 0 then return nil end
  local value = floor(acc * max(0, int(accuracyMod, 100)) / 100)
  value = floor(value * max(0, int(evasionMod, 100)) / 100)
  return min(M.MAX, max(M.MIN, value))
end

-- opts: { accuracyStage, evasionStage, accuracyMod, evasionMod, alwaysHits }
-- Returns hit (boolean) and effective accuracy (nil when never-miss).
function M.hit(moveAccuracy, roll, opts)
  opts = opts or {}
  if opts.alwaysHits then return true, nil end
  local acc = max(0, int(moveAccuracy, M.MAX))
  if acc <= 0 then return true, nil end

  local effective
  if opts.accuracyStage ~= nil or opts.evasionStage ~= nil then
    effective = M.effective(acc, opts.accuracyStage, opts.evasionStage)
  else
    effective = M.effectiveFromMods(acc, opts.accuracyMod, opts.evasionMod)
  end
  return int(roll, 0) < effective, effective
end

return M
