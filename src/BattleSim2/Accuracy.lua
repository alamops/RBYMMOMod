-- Gen 2 accuracy: BattleCommand_CheckHit's byte domain, as the cart rolls it.
--
-- pokecrystal engine/battle/effect_commands.asm:1553-1850 (pokegold the
-- same), from `.StatModifiers` on -- the earlier steps (`.DreamEater`,
-- `.Protect`, `.DrainSub`, `.LockOn`, `.FlyDigMoves`, `.ThunderRain`,
-- `.XAccuracy`, EFFECT_ALWAYS_HIT) are the turn machine's (Turn `_checkHit`):
--
--   1. the move's accuracy BYTE -- the wire's (Wire.battleMove: a Gen 1/2
--      move's accuracy is the cart's byte, `floor(pct * 255 / 100)`, which is
--      what MediatedBattle stamps), or the one BattleCommand_OHKO raised by
--      the level gap, or THUNDER's under the sun (BattleCommand_ThunderAccuracy:
--      `50 percent + 1`);
--   2. `.StatModifiers`: the user's accuracy level, then the target's evasion
--      level negated (`MAX_STAT_LEVEL + 1 - evasion`), each a pass of
--      AccuracyLevelMultipliers (data/battle/accuracy_multipliers.asm: 33/100
--      at -6 .. 3/1 at +6 -- NOT the stat ratios), the product kept wide
--      between the passes and each pass at least 1; a result past a byte is
--      held at $ff ("max out at 100%").  A FORESIGHT-identified target whose
--      evasion level is at least the user's accuracy level skips the whole
--      step (`opts.identified`);
--   3. `.BrightPowder`: the defender's HELD_BRIGHTPOWDER parameter off the
--      byte, at least 0;
--   4. `cp -1 / jr z, .Hit`: a byte of 255 hits and draws NOTHING; otherwise
--      BattleRandom, and the move hits under the byte.
--
-- So a 100% move with neutral levels and no powder never draws, and every
-- other check rolls a byte -- there is no percent roll on the cart.  The
-- engine port's percent domain (src/battle/gen2/Damage.lua rollHit) is not the
-- cart's, and the cart wins.
--
-- Nothing here raises; no love, no engine modules, no mod facade.

local need = ...
local Items = need("BattleSim2/Items")

local M = {}

local floor, max, min = math.floor, math.max, math.min

M.BYTE_MAX = 255

-- AccuracyLevelMultipliers, -6..+6, as num/den.
M.LEVEL_MULT = {
  [-6] = { 33, 100 }, [-5] = { 36, 100 }, [-4] = { 43, 100 },
  [-3] = { 50, 100 }, [-2] = { 60, 100 }, [-1] = { 75, 100 },
  [0] = { 1, 1 },
  [1] = { 133, 100 }, [2] = { 166, 100 }, [3] = { 2, 1 },
  [4] = { 233, 100 }, [5] = { 133, 50 }, [6] = { 3, 1 },
}

-- BattleCommand_ThunderAccuracy's sun byte (`50 percent + 1`).
M.THUNDER_SUN_BYTE = 128

local function int(value, fallback)
  local n = tonumber(value)
  if not n or n ~= n then return fallback end
  return floor(n)
end

local function stageMul(stage)
  local entry = M.LEVEL_MULT[max(-6, min(6, int(stage, 0)))]
  return entry[1], entry[2]
end

-- The cart's accuracy byte for a sheet's accuracy: the byte itself, 0..255.
function M.moveByte(accuracy)
  return max(0, min(M.BYTE_MAX, int(accuracy, M.BYTE_MAX)))
end

-- `.StatModifiers` on a byte.  `identified` is the target's SUBSTATUS_IDENTIFIED
-- (FORESIGHT): with the target's evasion level at least the user's accuracy
-- level (`cp b / jr c` -- the levels compared as stages here), the byte stands.
function M.effectiveByte(byte, accuracyStage, evasionStage, identified)
  local acc, eva = int(accuracyStage, 0), int(evasionStage, 0)
  local value = max(0, int(byte, 0))
  if identified and eva >= acc then return min(M.BYTE_MAX, value) end
  local num, den = stageMul(acc)
  value = floor(value * num / den)
  if value < 1 then value = 1 end
  num, den = stageMul(-eva)
  value = floor(value * num / den)
  if value < 1 then value = 1 end
  if value > M.BYTE_MAX then value = M.BYTE_MAX end
  return value
end

-- Steps 2 and 3: the byte the roll is compared with.
-- opts: { accuracyStage, evasionStage, brightPowder, identified }
function M.finalByte(byte, opts)
  opts = opts or {}
  local b = M.effectiveByte(byte, opts.accuracyStage, opts.evasionStage, opts.identified)
  if opts.brightPowder ~= nil then b = Items.brightPowder(b, opts.brightPowder) end
  return b
end

-- Whether the check draws its BattleRandom: every byte but 255.
function M.draws(finalByte)
  return int(finalByte, 0) < M.BYTE_MAX
end

-- `cp -1 / jr z, .Hit`, then `BattleRandom / cp b / jr nc, .Miss`.  `roll` is
-- the byte (ignored at 255, where none is drawn).
function M.hitByte(byteAccuracy, roll)
  local b = int(byteAccuracy, 0)
  if b >= M.BYTE_MAX then return true end
  return int(roll, M.BYTE_MAX) < b
end

-- The whole tail from a base byte.
-- opts: { accuracyStage, evasionStage, brightPowder, identified, alwaysHits }
-- Returns hit (boolean) and the byte rolled against (nil when `alwaysHits`:
-- the caller's earlier step decided).
function M.hit(byte, roll, opts)
  opts = opts or {}
  if opts.alwaysHits then return true, nil end
  local b = M.finalByte(M.moveByte(byte), opts)
  return M.hitByte(b, roll), b
end

return M
