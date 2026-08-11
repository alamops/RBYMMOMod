-- Gen 2 damage, as an integer pipeline.
--
-- Pure twin of engine src/battle/gen2/Damage.lua (BattleCommand_DamageCalc /
-- Stab / DamageVariation).  Differs from Gen 1 BattleSim/Damage.lua:
--
--   * Special is SpA vs SpD (sheet keys spa/spd; legacy spc fills both).
--   * No 255-stat pair clamp.
--   * Crit is a flat x2 after the base product (not a doubled level term),
--     and ignores only the attacker's *negative* / defender's *positive*
--     stages when the caller has already applied stages — this module's
--     compute() takes pre-staged attack/defense ints like Gen 1's API.
--   * After base (+ optional item boost + crit): cap at 997 then +2
--     (MIN_DAMAGE), so every non-immune damaging hit leaves DamageCalc ≥ 2.
--   * STAB is floor(d * 15/10); type rows are percents applied one at a
--     time as floor(d * pct/100), with a non-immune floor of 1.
--   * Variation last: floor(d * roll / 100) for roll in 85..100, only when
--     running damage ≥ 2; final clamp 1..999.
--
-- Physical vs special: opts.physical (default true).  When false, attacker
-- reads spa (or spc) and defender reads spd (or spc).
--
-- Returns the same shape Gen 1 compute() does (levelTerm, base, modified,
-- damage, minDamage, maxDamage, immune, …) so Turn and the vector harness
-- stay familiar.  levelTerm here is floor(2L/5)+2 with L *not* doubled on
-- crit (crit is applied later).
--
-- No love, no engine modules, no mod facade.

local need = ...

local M = {}

local floor, max, min = math.floor, math.max, math.min

M.ROLL_MIN = 85
M.ROLL_MAX = 100
M.MAX_DAMAGE = 999
M.MIN_DAMAGE = 2

local function int(value, fallback)
  local n = tonumber(value)
  if not n or n ~= n then return fallback end
  return floor(n)
end

local function stat(source, long, short, fallback)
  if type(source) ~= "table" then return fallback end
  local value = source[long]
  if value == nil then value = source[short] end
  return int(value, fallback)
end

-- Prefer spa/spd; fall back to legacy Gen 1 spc for either side.
local function attackStat(attacker, physical)
  if physical then
    return stat(attacker, "attack", "atk", 0)
  end
  if type(attacker) ~= "table" then return 0 end
  local value = attacker.spa
  if value == nil then value = attacker.specialAttack end
  if value == nil then value = attacker.spc end
  if value == nil then value = attacker.special end
  return int(value, 0)
end

local function defenseStat(defender, physical)
  if physical then
    return stat(defender, "defense", "def", 1)
  end
  if type(defender) ~= "table" then return 1 end
  local value = defender.spd
  if value == nil then value = defender.specialDefense end
  if value == nil then value = defender.spc end
  if value == nil then value = defender.special end
  return int(value, 1)
end

local function percents(effect)
  if effect == nil then return { 100 } end
  if type(effect) == "number" then return { floor(effect) } end
  if type(effect) ~= "table" then return { 100 } end
  local list = {}
  for i = 1, #effect do list[i] = int(effect[i], 100) end
  if #list == 0 then return { 100 } end
  return list
end

-- floor(2L/5)+2 — Gen 2 does not double L on crit.
function M.levelTerm(level, _crit)
  local L = max(0, int(level, 1))
  return floor(L * 2 / 5) + 2
end

-- Core product before the +2 min-damage pad.
function M.base(level, power, attack, defense)
  if (power or 0) <= 0 then return 0 end
  defense = max(1, int(defense, 1))
  local value = M.levelTerm(level, false)
  value = value * max(0, int(power, 0))
  value = value * max(0, int(attack, 0))
  value = floor(value / defense)
  value = floor(value / 50)
  return value
end

function M.applyRoll(modified, roll)
  local d = max(0, int(modified, 0))
  if d < 2 then return max(1, d) end
  local r = int(roll, M.ROLL_MAX)
  if r < M.ROLL_MIN then r = M.ROLL_MIN end
  if r > M.ROLL_MAX then r = M.ROLL_MAX end
  return max(1, min(M.MAX_DAMAGE, floor(d * r / 100)))
end

-- attacker: { level, attack|atk, spa|spc, ... }
-- defender: { defense|def, spd|spc, ... }
-- move:     { power }
-- opts:     { crit, stab, typeEffect|typeEff, roll, physical,
--             itemBoostPercent }
function M.compute(attacker, defender, move, opts)
  attacker, defender = attacker or {}, defender or {}
  move, opts = move or {}, opts or {}

  local physical = opts.physical
  if physical == nil then physical = true end

  local attack = attackStat(attacker, physical)
  local defense = max(1, defenseStat(defender, physical))
  local levelTerm = M.levelTerm(attacker.level, false)
  local power = max(0, int(move.power, 0))

  local base = M.base(attacker.level, power, attack, defense)

  local result = {
    levelTerm = levelTerm,
    base = base,
    attack = attack,
    defense = defense,
    physical = physical and true or false,
    statClamped = false,
    crit = opts.crit and true or false,
    stab = opts.stab and true or false,
    immune = false,
  }

  if power <= 0 then
    result.modified = 0
    result.damage = 0
    result.minDamage = 0
    result.maxDamage = 0
    return result
  end

  local d = base

  if opts.itemBoostPercent and int(opts.itemBoostPercent, 0) > 0 then
    d = floor(d * (100 + int(opts.itemBoostPercent, 0)) / 100)
  end

  if opts.crit then d = d * 2 end

  -- Cap at DAMAGE_CAP then add MIN_DAMAGE (engine DamageCalc tail).
  d = min(d, M.MAX_DAMAGE - M.MIN_DAMAGE) + M.MIN_DAMAGE

  if opts.stab then d = floor(d * 15 / 10) end

  local effect = opts.typeEffect
  if effect == nil then effect = opts.typeEff end

  for _, pct in ipairs(percents(effect)) do
    if pct <= 0 then
      result.modified = 0
      result.immune = true
      result.damage = 0
      result.minDamage = 0
      result.maxDamage = 0
      return result
    end
    d = floor(d * pct / 100)
    if d == 0 then d = 1 end
  end

  result.modified = d
  result.minDamage = M.applyRoll(d, M.ROLL_MIN)
  result.maxDamage = M.applyRoll(d, M.ROLL_MAX)

  if opts.roll ~= nil then
    result.roll = int(opts.roll, M.ROLL_MAX)
    result.damage = M.applyRoll(d, result.roll)
  end

  return result
end

return M
