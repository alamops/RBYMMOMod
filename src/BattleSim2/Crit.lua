-- Gen 2 critical hits: a chance ladder, not Gen 1's base-Speed threshold.
--
-- Engine: src/battle/gen2/Damage.lua (CRITICAL_CHANCES, criticalLevel,
-- rollCritical).  Level 0..6 indexes 1-in-N chances {15,8,4,3,2,2,2}.
-- A hit is critical when random(N) returns 0 (cart compares a BattleRandom
-- byte against the chance).
--
-- Level contributions (capped at 6):
--   +1 Focus Energy, +2 high-crit move, +1 Scope Lens,
--   +2 species+item bonus (Lucky Punch / Stick).
--
-- Unlike Gen 1 there is no Focus Energy bug here — Focus Energy raises the
-- level.  Crit *damage* (flat x2, ignore negative attacker stages) lives in
-- Damage.lua; this module only answers the roll.
--
-- Nothing here raises; no love, no engine modules, no mod facade.

local need = ...

local M = {}

local floor, max, min = math.floor, math.max, math.min

-- data/battle/critical_hit_chances.asm, as "1 in N".
M.CRITICAL_CHANCES = { [0] = 15, [1] = 8, [2] = 4, [3] = 3, [4] = 2, [5] = 2, [6] = 2 }

local function int(value, fallback)
  local n = tonumber(value)
  if not n or n ~= n then return fallback end
  return floor(n)
end

function M.chance(level)
  local capped = max(0, min(6, int(level, 0)))
  return M.CRITICAL_CHANCES[capped]
end

-- opts: { focusEnergy, highCritMove, scopeLens, speciesItemBonus }
function M.level(opts)
  opts = opts or {}
  local level = 0
  if opts.focusEnergy then level = level + 1 end
  if opts.highCritMove then level = level + 2 end
  if opts.scopeLens then level = level + 1 end
  if opts.speciesItemBonus then level = level + 2 end
  return min(6, level)
end

-- roll: 0..chance-1 (caller draws with Rng:below(chance)).
-- Returns isCrit, chance (1-in-N), level.
function M.check(criticalLevel, roll, opts)
  local level = int(criticalLevel, 0)
  if opts and (opts.focusEnergy or opts.highCritMove
               or opts.scopeLens or opts.speciesItemBonus) then
    level = M.level(opts)
  end
  local chance = M.chance(level)
  local r = int(roll, chance)
  return r == 0, chance, level
end

return M
