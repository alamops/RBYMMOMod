-- Gen 2 damage, as an integer pipeline.
--
-- Pure twin of engine src/battle/gen2/Damage.lua (BattleCommand_DamageCalc /
-- Stab / DamageVariation).  Differs from Gen 1 BattleSim/Damage.lua:
--
--   * Special is SpA vs SpD (sheet keys spa/spd; legacy spc fills both).
--   * No 255-stat pair clamp inside compute(): the cart's own fold to a byte
--     is TruncateHL_BC, run by the caller on the stats it chose
--     (`truncateStats` below), and compute() takes the pair it hands back.
--   * Crit is a flat x2 after the base product and the type-boost item
--     (BattleCommand_DamageCalc's .CriticalMultiplier, pokecrystal engine/
--     battle/effect_commands.asm:3108), not a doubled level term.  WHICH
--     stats a crit reads is not decided here: CheckDamageStatsCritical
--     (:2660) keeps the boosted pair only when the defender's stage is
--     strictly lower than the attacker's, and otherwise reads the unmodified
--     stats -- no stages, badges, burn, paralysis or screens.  Turn makes that
--     choice before it calls in.
--   * After base (+ optional item boost + crit): cap at 997 then +2
--     (MIN_DAMAGE), so every non-immune damaging hit leaves DamageCalc ≥ 2.
--   * DoBadgeTypeBoosts (opts.badgeTypeBoost) next, ahead of STAB: an
--     eighth of the running damage, at least 1.
--   * STAB is floor(d * 15/10); type rows are percents applied one at a
--     time as floor(d * pct/100), with a non-immune floor of 1.
--   * Rage's RageDamage (opts.rageCount) next: x(count + 1), 16-bit.
--   * Variation last: floor(d * roll / 100) for roll in 85..100, only when
--     running damage ≥ 2, at least 1.  NO cap after it: DamageCalc's 997 + 2
--     is the only one, and STAB, the matchup, RageDamage and the variation each
--     keep their own 16-bit result (BattleCommand_Stab's `add hl, bc`, the
--     matchup's and DamageVariation's low quotient bytes), so a hit can pass
--     999 -- which only HP-free readers see (Bide's store, Counter).
--   * `double` is DoubleDamage / DoubleMinimizeDamage, run by the caller after
--     the variation: a 16-bit shift whose carry pins $ffff.
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
-- DamageCalc's tail: the base is held at MAX_DAMAGE - MIN_DAMAGE (997) and
-- MIN_DAMAGE added -- the one cap Gold's damage has.
M.MAX_DAMAGE = 999
M.MIN_DAMAGE = 2
-- The 16-bit register every later step keeps (wCurDamage).
M.WORD_MAX = 65535

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

-- TruncateHL_BC (pokecrystal engine/battle/effect_commands.asm:2614-2658):
-- fold the attack / defense pair the damage formula multiplies into a byte
-- each.  While either is 255 or more, both are shifted right twice -- a value
-- the shift empties becomes 1 -- and what comes out are the low bytes.
--
-- `onePass` stops after one pass with no re-check, so a stat still past 1023
-- after it keeps only its low byte -- the wrap bug docs/bugs_and_glitches.md
-- names (Reflect / Light Screen past 1024, Thick Club / Light Ball past 1024).
-- Crystal takes that exit in a link battle (`wLinkMode == LINK_COLOSSEUM`);
-- Gold and Silver have no loop at all (pokegold effect_commands.asm:2625), so
-- they always fold once.  Which one a fight is rides on the fight's cart family
-- (Turn `_onePassTruncate`, contract K6).  A wrapped 0 is not repaired here: a
-- defense of 0 is lifted to 1 by DamageCalc (`compute` below) and an attack of
-- 0 leaves the base at 0.  Returns attack, defense.
function M.truncateStats(attack, defense, onePass)
  local a = max(0, int(attack, 0))
  local d = max(0, int(defense, 0))
  while a > 255 or d > 255 do
    d = floor(d / 4)
    if d == 0 then d = 1 end
    a = floor(a / 4)
    if a == 0 then a = 1 end
    if onePass then break end
  end
  return a % 256, d % 256
end

-- BattleCommand_DamageVariation: nothing for 0 or 1 ("No point in reducing
-- 1 or 0 damage"), otherwise floor(d * roll / 100), at least 1 and NOT capped
-- (see the header) -- `modified` is a 16-bit value already, and roll <= 100
-- keeps the product's quotient inside it.
function M.applyRoll(modified, roll)
  local d = max(0, int(modified, 0))
  if d < 2 then return max(1, d) end
  local r = int(roll, M.ROLL_MAX)
  if r < M.ROLL_MIN then r = M.ROLL_MIN end
  if r > M.ROLL_MAX then r = M.ROLL_MAX end
  return max(1, floor(d * r / 100))
end

-- DoubleDamage / BattleCommand_DoubleMinimizeDamage (effect_commands.asm:
-- 5977-5987, 6515-6531): wCurDamage shifted left as a 16-bit pair, a carry
-- out pinning it at $ffff.
function M.double(damage)
  return min(M.WORD_MAX, max(0, int(damage, 0)) * 2)
end

-- attacker: { level, attack|atk, spa|spc, ... }
-- defender: { defense|def, spd|spc, ... }
-- move:     { power }
-- opts:     { crit, stab, typeEffect|typeEff, roll, physical,
--             itemBoostPercent, badgeTypeBoost, rageCount }
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

  -- DamageCalc .DoneItem: the type-boost item's (100 + parameter) out of 100.
  -- The sum is a byte on the cart (Items.typeBoostPercent), so a parameter past
  -- 155 arrives here as a negative percent and is applied all the same.
  if opts.itemBoostPercent and int(opts.itemBoostPercent, 0) ~= 0 then
    d = floor(d * (100 + int(opts.itemBoostPercent, 0)) / 100)
  end

  if opts.crit then d = d * 2 end

  -- Cap at DAMAGE_CAP then add MIN_DAMAGE (engine DamageCalc tail).
  d = min(d, M.MAX_DAMAGE - M.MIN_DAMAGE) + M.MIN_DAMAGE

  -- DoBadgeTypeBoosts (pokecrystal engine/battle/misc.asm:146), farcalled by
  -- BattleCommand_Stab ahead of the STAB multiply: the player owns the badge
  -- whose row names the move's type, and the running damage gains an eighth
  -- of itself, at least 1 (engine src/battle/gen2/Damage.lua:269-274).  The
  -- engine runs DoWeatherModifiers just before it; this sim has no weather,
  -- so nothing sits between the DamageCalc tail and here.
  if opts.badgeTypeBoost then d = d + max(1, floor(d / 8)) end

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

  -- BattleCommand_RageDamage (pokecrystal engine/battle/effect_commands.asm:
  -- 2451-2474), between Stab and DamageVariation in Rage's script: the
  -- damage added to itself once per rage-counter step, x(count + 1), a carry
  -- out of the 16-bit sum pinning it at $ffff.
  local rage = max(0, int(opts.rageCount, 0))
  if rage > 0 then d = min(M.WORD_MAX, d * (rage + 1)) end

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
