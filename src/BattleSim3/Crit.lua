-- Gen 3 critical hits: a five-step stage ladder.
--
-- Port of engine src/core/game3/battle/rules.lua `Rules.crit` (pokefirered/src/
-- battle_script_commands.c:1170 Cmd_critcalc):
--
--   stage = +2 Focus Energy (or Dire Hit), +1 high-crit move effect, +1 Scope
--           Lens, +2 Lucky Punch on Chansey, +2 Stick on Farfetch'd; cap 4
--   chance = 1 in { 16, 8, 4, 3, 2 }[stage]; critical when roll(0, n-1) == 0
--   damage = x2 (Damage.calc), and a crit ignores the attacker's lowered and
--            the defender's raised stages (Damage.base)
--
-- The engine reads the held ITEM id (198 / 222 / 225); pret reads the HOLD
-- EFFECT (HOLD_EFFECT_SCOPE_LENS / LUCKY_PUNCH / STICK).  They agree on every
-- cart item, and the hold effect is what the sheet carries, so that is what is
-- read here.  Battle Armor / Shell Armor skip the roll entirely -- that check
-- lives at the call site (Damage.calc) so the draw is skipped with it.
--
-- Nothing here raises; no love, no engine modules, no mod facade.

local need = ...

local M = {}

local floor, max, min = math.floor, math.max, math.min

M.CHANCE = { [0] = 16, [1] = 8, [2] = 4, [3] = 3, [4] = 2 }
M.MAX_STAGE = 4
M.MULTIPLIER = 2

-- pokefirered/src/battle_script_commands.c:1170 (sHighCritEffects via move effect)
M.HIGH_CRIT_EFFECTS = { [43] = true, [75] = true, [200] = true, [209] = true }

local HOLD_SCOPE_LENS, HOLD_LUCKY_PUNCH, HOLD_STICK = 41, 63, 66
local SPECIES_CHANSEY, SPECIES_FARFETCHD = 113, 83

local function int(value, fallback)
  local n = tonumber(value)
  if not n or n ~= n then return fallback end
  return floor(n)
end

function M.isHighCrit(effect)
  return M.HIGH_CRIT_EFFECTS[int(effect, -1)] == true
end

-- attacker: the battler shape Damage.lua documents (focusEnergy, mon.holdEffect,
-- speciesNum).  move: a move row (effect).
function M.stage(attacker, move)
  local stage = 0
  if attacker and attacker.focusEnergy then stage = stage + 2 end
  if type(move) == "table" and M.isHighCrit(move.effect) then stage = stage + 1 end
  local he = int(attacker and attacker.mon and attacker.mon.holdEffect, 0)
  local species = int(attacker and attacker.speciesNum, 0)
  if he == HOLD_SCOPE_LENS then stage = stage + 1 end
  if he == HOLD_LUCKY_PUNCH and species == SPECIES_CHANSEY then stage = stage + 2 end
  if he == HOLD_STICK and species == SPECIES_FARFETCHD then stage = stage + 2 end
  if stage > M.MAX_STAGE then stage = M.MAX_STAGE end
  return stage
end

-- Stage from explicit flags (the vector pack's view of the same ladder).
function M.stageFrom(opts)
  opts = opts or {}
  local stage = 0
  if opts.focusEnergy then stage = stage + 2 end
  if opts.highCrit then stage = stage + 1 end
  if opts.scopeLens then stage = stage + 1 end
  if opts.speciesItem then stage = stage + 2 end
  return min(M.MAX_STAGE, stage)
end

function M.chance(stage)
  return M.CHANCE[max(0, min(M.MAX_STAGE, int(stage, 0)))]
end

-- roll: 0..chance-1.  Returns isCrit, chance.
function M.check(stage, roll)
  local chance = M.chance(stage)
  return int(roll, chance) == 0, chance
end

return M
