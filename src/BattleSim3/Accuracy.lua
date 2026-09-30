-- Gen 3 accuracy: percent domain, one combined stage, a 1..100 roll.
--
-- Port of engine src/core/game3/battle/engine.lua `Ctx:accuracyCheck`
-- (pokefirered/src/battle_script_commands.c:1003 Cmd_accuracycheck) and the stage
-- table `Rules.ACCURACY_STAGE` (battle_script_commands.c:570 sAccuracyStageRatios).
--
--   buff = accStage - evaStage          (evasion ignored when Foresighted)
--   clamp -6..6; calc = floor(ratio[1] * moveAcc / ratio[2])
--   Compound Eyes x130/100, Sand Veil in sand x80/100, Hustle on physical
--   x80/100, BrightPowder / Lax Incense (HOLD_EFFECT_EVASION_UP) x(100-param)/100
--   hit when roll(1, 100) <= calc
--
-- Unlike Gen 1/2 the stage is ONE number: accuracy and evasion are combined
-- before the table, so +1 accuracy against +1 evasion is exactly neutral.  The
-- pre-roll gates (Protect, semi-invulnerable, Lock-On, never-miss effects,
-- Thunder in rain) are the turn machine's, because they decide whether a roll
-- is drawn at all; this module answers only the number.
--
-- Nothing here raises; no love, no engine modules, no mod facade.

local need = ...

local M = {}

local floor, max, min = math.floor, math.max, math.min

-- pokefirered/src/battle_script_commands.c:570
M.STAGE = {
  [-6] = { 33, 100 }, [-5] = { 36, 100 }, [-4] = { 43, 100 }, [-3] = { 50, 100 },
  [-2] = { 60, 100 }, [-1] = { 75, 100 }, [0] = { 1, 1 }, [1] = { 133, 100 },
  [2] = { 166, 100 }, [3] = { 2, 1 }, [4] = { 233, 100 }, [5] = { 133, 50 }, [6] = { 3, 1 },
}

M.ROLL_MIN = 1
M.ROLL_MAX = 100

local HOLD_EVASION_UP = 22

local function int(value, fallback)
  local n = tonumber(value)
  if not n or n ~= n then return fallback end
  return floor(n)
end

-- opts: accStage, evaStage, foresight, compoundEyes, sandVeilInSand,
--       hustlePhysical, evasionItemParam (the BrightPowder param, or nil)
-- Returns the effective accuracy (an integer; may exceed 100).
function M.calc(moveAccuracy, opts)
  opts = opts or {}
  local acc = max(0, int(moveAccuracy, 100))
  local accStage = int(opts.accStage, 0)
  local evaStage = int(opts.evaStage, 0)
  local buff
  if opts.foresight then buff = accStage else buff = accStage - evaStage end
  if buff < -6 then buff = -6 elseif buff > 6 then buff = 6 end
  local ratio = M.STAGE[buff]
  local calc = floor(ratio[1] * acc / ratio[2])
  if opts.compoundEyes then calc = floor(calc * 130 / 100) end
  if opts.sandVeilInSand then calc = floor(calc * 80 / 100) end
  if opts.hustlePhysical then calc = floor(calc * 80 / 100) end
  if opts.evasionItemParam ~= nil then
    calc = floor(calc * (100 - int(opts.evasionItemParam, 0)) / 100)
  end
  return calc
end

-- Battler-level convenience: the same calc read off the Damage.lua battler
-- shape.  `physical` and `sand` are the caller's (the chart split and the
-- Cloud-Nine-filtered weather).
function M.forBattlers(moveAccuracy, user, target, physical, sand)
  local tHe = int(target and target.mon and target.mon.holdEffect, 0)
  local tParam = int(target and target.mon and target.mon.holdParam, 0)
  return M.calc(moveAccuracy, {
    accStage = user and user.stages and user.stages.acc or 0,
    evaStage = target and target.stages and target.stages.eva or 0,
    foresight = target and target.identified,
    compoundEyes = user and user.ability == "COMPOUND_EYES",
    sandVeilInSand = sand and target and target.ability == "SAND_VEIL",
    hustlePhysical = physical and user and user.ability == "HUSTLE",
    evasionItemParam = (tHe == HOLD_EVASION_UP) and tParam or nil,
  })
end

-- roll: 1..100.  Returns hit, calc.
function M.hit(calc, roll)
  local c = int(calc, 0)
  return int(roll, M.ROLL_MAX) <= c, c
end

return M
