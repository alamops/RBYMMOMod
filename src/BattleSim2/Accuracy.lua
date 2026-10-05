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
-- Two checks are the cart's byte domain instead (BattleCommand_CheckHit's
-- own, effect_commands.asm:1574-1610): a target holding BRIGHTPOWDER, whose
-- parameter comes off the accuracy BYTE, and a one-hit KO move, whose
-- BattleCommand_OHKO raises the byte by the level gap before CheckHit.  Both
-- roll a BattleRandom byte against the byte (`hitBytes`), never a percent
-- rebuilt from it.  The stage ratios are this file's either way, so the two
-- domains agree wherever no powder and no level enter.
--
-- Nothing here raises; no love, no engine modules, no mod facade.

local need = ...
local Items = need("BattleSim2/Items")

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

-- The cart's accuracy byte for a sheet's accuracy: a percent (0..100)
-- through RGBDS `percent` (`* $ff / 100`, the `move` macro's), a byte a Gen 1
-- sheet still carries (101..255) as it is.
function M.moveByte(accuracy)
  local acc = max(0, int(accuracy, M.MAX))
  if acc > M.MAX then return min(255, acc) end
  return floor(acc * 255 / 100)
end

-- `.StatModifiers` on a byte, over the stage ratios above: the user's
-- accuracy stage, then the target's evasion negated, each pass at least 1
-- (`.min_accuracy`), and a result past a byte held at 255 (`.finish_accuracy`:
-- "max out at 100%").  The intermediate keeps its width, as hQuotient does.
function M.effectiveByte(byte, accuracyStage, evasionStage)
  local num, den = stageMul(accuracyStage)
  local value = floor(max(0, int(byte, 0)) * num / den)
  if value < 1 then value = 1 end
  num, den = stageMul(-(int(evasionStage, 0)))
  value = floor(value * num / den)
  if value < 1 then value = 1 end
  if value > 255 then value = 255 end
  return value
end

-- `.skip_brightpowder`: `cp -1 / jr z, .Hit`, then `BattleRandom / cp b /
-- jr nc, .Miss`.  `roll` is the byte.
function M.hitByte(byteAccuracy, roll)
  local b = int(byteAccuracy, 0)
  if b >= 255 then return true end
  return int(roll, 255) < b
end

-- The byte-domain tail of CheckHit from a base byte (the move's, or the one
-- BattleCommand_OHKO raised): `.StatModifiers`, `.BrightPowder` (the
-- defender's parameter, `opts.brightPowder`, when it holds one) and the roll.
-- Returns hit and the byte rolled against.
function M.hitBytes(byte, roll, opts)
  opts = opts or {}
  local b = M.effectiveByte(byte, opts.accuracyStage, opts.evasionStage)
  if opts.brightPowder ~= nil then b = Items.brightPowder(b, opts.brightPowder) end
  return M.hitByte(b, roll), b
end

-- Percent-mod path for fixtures that do not carry stages.
function M.effectiveFromMods(accuracy, accuracyMod, evasionMod)
  local acc = max(0, int(accuracy, M.MAX))
  if acc <= 0 then return nil end
  local value = floor(acc * max(0, int(accuracyMod, 100)) / 100)
  value = floor(value * max(0, int(evasionMod, 100)) / 100)
  return min(M.MAX, max(M.MIN, value))
end

-- opts: { accuracyStage, evasionStage, accuracyMod, evasionMod, alwaysHits,
--         brightPowder }
-- Returns hit (boolean) and effective accuracy (nil when never-miss).
--
-- `brightPowder` is the DEFENDER's HELD_BRIGHTPOWDER parameter, when it holds
-- one: BattleCommand_CheckHit's `.BrightPowder` takes it off the stage-scaled
-- accuracy BYTE after `.StatModifiers` and before the roll, so with it the
-- check is `hitBytes` over the move's byte and `roll` is a BattleRandom byte
-- (0..255), the effective accuracy returned a byte too.  An always-hit move --
-- Swift, X Accuracy -- returns above and never meets it, as on the cart.
function M.hit(moveAccuracy, roll, opts)
  opts = opts or {}
  if opts.alwaysHits then return true, nil end
  local acc = max(0, int(moveAccuracy, M.MAX))
  if acc <= 0 then return true, nil end
  if opts.brightPowder ~= nil then
    return M.hitBytes(M.moveByte(acc), roll, opts)
  end

  local effective
  if opts.accuracyStage ~= nil or opts.evasionStage ~= nil then
    effective = M.effective(acc, opts.accuracyStage, opts.evasionStage)
  else
    effective = M.effectiveFromMods(acc, opts.accuracyMod, opts.evasionMod)
  end
  return int(roll, 0) < effective, effective
end

return M
