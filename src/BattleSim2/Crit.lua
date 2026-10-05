-- Gen 2 critical hits: a chance ladder, not Gen 1's base-Speed threshold.
--
-- Engine: src/battle/gen2/Damage.lua (CRITICAL_CHANCES, criticalLevel,
-- rollCritical).  Level 0..6 indexes data/battle/critical_hit_chances.asm,
-- `1 out_of N` -- `* $100 /`, so 17, 32, 64, 85, 128, 128, 128 -- and
-- BattleCommand_Critical's `.Tally` is one BattleRandom byte compared
-- against that row: `cp [hl] / ret nc`, a crit below it.  The referee-gaps
-- run's wave 4 (R2d) moved this from `below(N) == 0` (1 in 15 for 17 in 256,
-- the engine port's) to the cart's byte.
--
-- Level contributions (capped at 6):
--   +1 Focus Energy, +2 high-crit move, +1 Scope Lens.
-- The species+item bonus (Chansey's Lucky Punch, Farfetch'd's Stick) is not a
-- contribution: BattleCommand_Critical loads c = 2 and jumps straight to
-- `.Tally`, past Focus Energy, the high-crit list and Scope Lens, so with it
-- the level IS 2 (pokecrystal engine/battle/effect_commands.asm:1120-1206;
-- the Gold engine port adds it instead, and the cart wins).
--
-- Unlike Gen 1 there is no Focus Energy bug here — Focus Energy raises the
-- level.  Crit *damage* (flat x2, ignore negative attacker stages) lives in
-- Damage.lua; this module only answers the roll.
--
-- Nothing here raises; no love, no engine modules, no mod facade.

local need = ...

local M = {}

local floor, max, min = math.floor, math.max, math.min

-- data/battle/critical_hit_chances.asm, as "1 in N" (the row's source) and
-- as the byte the cart compares (`1 out_of N` = floor(256 / N)).
M.CRITICAL_CHANCES = { [0] = 15, [1] = 8, [2] = 4, [3] = 3, [4] = 2, [5] = 2, [6] = 2 }
M.CRITICAL_BYTES = { [0] = 17, [1] = 32, [2] = 64, [3] = 85, [4] = 128, [5] = 128, [6] = 128 }

local function int(value, fallback)
  local n = tonumber(value)
  if not n or n ~= n then return fallback end
  return floor(n)
end

function M.chance(level)
  local capped = max(0, min(6, int(level, 0)))
  return M.CRITICAL_CHANCES[capped]
end

-- The byte a level's crit is drawn under.
function M.threshold(level)
  local capped = max(0, min(6, int(level, 0)))
  return M.CRITICAL_BYTES[capped]
end

M.SPECIES_ITEM_LEVEL = 2

-- opts: { focusEnergy, highCritMove, scopeLens, speciesItemBonus }
function M.level(opts)
  opts = opts or {}
  if opts.speciesItemBonus then return M.SPECIES_ITEM_LEVEL end
  local level = 0
  if opts.focusEnergy then level = level + 1 end
  if opts.highCritMove then level = level + 2 end
  if opts.scopeLens then level = level + 1 end
  return min(6, level)
end

-- roll: the BattleRandom byte (0..255) `.Tally` compares.
-- Returns isCrit, threshold (the byte a crit is under), level.
function M.check(criticalLevel, roll, opts)
  local level = int(criticalLevel, 0)
  if opts and (opts.focusEnergy or opts.highCritMove
               or opts.scopeLens or opts.speciesItemBonus) then
    level = M.level(opts)
  end
  local threshold = M.threshold(level)
  local r = int(roll, 255)
  return r < threshold, threshold, level
end

return M
