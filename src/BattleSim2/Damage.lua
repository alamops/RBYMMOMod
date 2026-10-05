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
--   * Variation last: floor(d * roll / 255) for roll in 217..255 (the
--     cart's rotated byte; wave 4), only when
--     running damage ≥ 2, at least 1.  NO cap after it: DamageCalc's 997 + 2
--     is the only one, and STAB, the matchup, RageDamage and the variation each
--     keep their own 16-bit result (BattleCommand_Stab's `add hl, bc`, the
--     matchup's and DamageVariation's low quotient bytes), so a hit can pass
--     999 -- which only HP-free readers see (Bide's store, Counter).
--   * `double` is DoubleDamage / DoubleMinimizeDamage, run by the caller after
--     the variation: a 16-bit shift whose carry pins $ffff.
--   * The referee-gaps run's wave 3 (R2c) splits `compute` into the cart's own
--     commands, because the Gold-only scripts run them apart: `calc`
--     (BattleCommand_DamageCalc, with the wCurDamage it adds to -- 0 but for
--     Gold's PRESENT), `stab` (BattleCommand_Stab: DoWeatherModifiers, the
--     badge type boost, STAB, the matchup -- and the c register it leaves,
--     which PRESENT's own `stab` call hands DamageCalc on Gold), `applyRoll`
--     (DamageVariation: no draw and no change under 2 damage), and the
--     scripts' word multipliers (`multiply` -- TRIPLE KICK's added kicks --
--     and `doubleTimes`, ROLLOUT's and FURY CUTTER's doublings).  `compute` is
--     the NormalHit chain over them and keeps its old shape.
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

-- BattleCommand_DamageVariation's multiplier (effect_commands.asm:1500-
-- 1550): a BattleRandom byte rotated right (`rrca`), redrawn below
-- `85 percent + 1` (217), so 217..255; the damage is x/255 of it (`100
-- percent` is 255).  The referee-gaps run's wave 4 (R2d) moved it here from
-- a uniform 85..100 percent (Rng:damageRoll draws the cart's loop).
M.ROLL_MIN = 217
M.ROLL_MAX = 255
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
-- 1 or 0 damage" -- `ret c` before the BattleRandom, so the caller draws no
-- roll for them either: `varies`), otherwise floor(d * roll / 255) -- roll
-- 217..255, M.ROLL_MIN / ROLL_MAX -- at least 1 and NOT capped (see the
-- header): `modified` is a 16-bit value already, and roll <= 255 keeps the
-- product's quotient inside it.
function M.varies(modified)
  return max(0, int(modified, 0)) >= 2
end

function M.applyRoll(modified, roll)
  local d = max(0, int(modified, 0))
  if d < 2 then return d end
  local r = int(roll, M.ROLL_MAX)
  if r < M.ROLL_MIN then r = M.ROLL_MIN end
  if r > M.ROLL_MAX then r = M.ROLL_MAX end
  return max(1, floor(d * r / M.ROLL_MAX))
end

-- DoubleDamage / BattleCommand_DoubleMinimizeDamage (effect_commands.asm:
-- 5977-5987, 6515-6531): wCurDamage shifted left as a 16-bit pair, a carry
-- out pinning it at $ffff.
function M.double(damage)
  return min(M.WORD_MAX, max(0, int(damage, 0)) * 2)
end

-- `count` of those shifts in a row: BattleCommand_RolloutPower's and
-- BattleCommand_FuryCutter's `.loop` / `.checkdouble`, each a `sla` / `rl` that
-- pins $ffff on a carry (move_effects/rollout.asm, fury_cutter.asm).
function M.doubleTimes(damage, count)
  local d = max(0, int(damage, 0))
  for _ = 1, max(0, int(count, 0)) do
    d = M.double(d)
    if d >= M.WORD_MAX then return M.WORD_MAX end
  end
  return d
end

-- BattleCommand_TripleKick (move_effects/triple_kick.asm): wCurDamage plus
-- itself `times - 1` more times, a 16-bit add whose carry pins $ffff -- the
-- second kick doubles DamageCalc's result, the third triples it.
function M.multiply(damage, times)
  local base = max(0, int(damage, 0))
  local d = base
  for _ = 2, max(1, int(times, 1)) do
    d = d + base
    if d > M.WORD_MAX then return M.WORD_MAX end
  end
  return d
end

-- BattleCommand_DamageCalc (effect_commands.asm:2900-3131) on the stats the
-- caller hands it -- `level`, `power`, `attack`, `defense` as the d / e / b / c
-- registers -- with opts { crit, itemBoostPercent, carry }:
--
--   * power 0 is `ret z` ("No damage if move power is 0"): nil, wCurDamage
--     left as it was (`carry`);
--   * a defense of 0 is 1; floor(2L/5) + 2, times power, times attack, over
--     defense, over 50;
--   * the type-boost item's (100 + parameter) / 100, then the crit's x2 (a
--     16-bit shift pinned at $ffff);
--   * added to wCurDamage -- `carry`, 0 everywhere but Gold's PRESENT, whose
--     own `stab` call can leave a 1 there (its high byte is also added into the
--     quotient's low byte first, as the cart's cap check does) -- held at
--     997, then MIN_DAMAGE.
function M.calc(level, power, attack, defense, opts)
  opts = opts or {}
  local p = max(0, int(power, 0))
  if p <= 0 then return nil end
  local d = M.base(level, p, attack, max(1, int(defense, 1)))
  if opts.itemBoostPercent and int(opts.itemBoostPercent, 0) ~= 0 then
    d = floor(d * (100 + int(opts.itemBoostPercent, 0)) / 100)
  end
  if opts.crit then d = min(M.WORD_MAX, d * 2) end
  local carry = max(0, int(opts.carry, 0)) % (M.WORD_MAX + 1)
  local q = d + floor(carry / 256)
  local sum = q + carry
  if q > M.MAX_DAMAGE - M.MIN_DAMAGE or sum > M.MAX_DAMAGE - M.MIN_DAMAGE then
    sum = M.MAX_DAMAGE - M.MIN_DAMAGE
  end
  return sum + M.MIN_DAMAGE
end

-- BattleCommand_Stab (effect_commands.asm:1214-1396) on wCurDamage `d`, past
-- its STRUGGLE return (the caller skips the whole command for Struggle):
--
--   * DoWeatherModifiers (engine/battle/misc.asm:49-131): `weatherTenths`
--     (15 or 5, the matching WeatherTypeModifiers / WeatherMoveModifiers row)
--     -- d x tenths / 10, a quotient past 16 bits pinned at $ffff and one of 0
--     raised to 1;
--   * DoBadgeTypeBoosts: an eighth of d, at least 1, pinned at $ffff;
--   * STAB: hl + hl >> 1 (`add hl, bc`, no carry kept), the c register left
--     holding the low byte of hl >> 1 -- `cReg`;
--   * the matchup rows, one percent per row: a product of 0 stays 0 (the
--     `jr z, .ok` -- a 0 damage is never raised), otherwise floor(d x pct /
--     100) raised to 1; a row of 0 is the immunity (wAttackMissed).
--
-- opts { weatherTenths, badgeTypeBoost, stab, typeEffect }.  Returns d,
-- immune, cReg (nil without STAB: the c register is the user's second type
-- then, which the caller knows).
function M.stab(d, opts)
  opts = opts or {}
  d = max(0, int(d, 0))
  local tenths = int(opts.weatherTenths, nil)
  if tenths then
    d = floor(d * tenths / 10)
    if d > M.WORD_MAX then d = M.WORD_MAX end
    if d == 0 then d = 1 end
  end
  if opts.badgeTypeBoost then d = min(M.WORD_MAX, d + max(1, floor(d / 8))) end
  local cReg = nil
  if opts.stab then
    local half = floor(d / 2)
    cReg = half % 256
    d = (d + half) % (M.WORD_MAX + 1)
  end
  local immune = false
  local effect = opts.typeEffect
  if effect == nil then effect = opts.typeEff end
  for _, pct in ipairs(percents(effect)) do
    if pct <= 0 then
      immune = true
      d = 0
    elseif d > 0 then
      d = floor(d * pct / 100)
      if d == 0 then d = 1 end
    end
  end
  return d, immune, cReg
end

-- attacker: { level, attack|atk, spa|spc, ... }
-- defender: { defense|def, spd|spc, ... }
-- move:     { power }
-- opts:     { crit, stab, typeEffect|typeEff, roll, physical,
--             itemBoostPercent, badgeTypeBoost, rageCount, weatherTenths,
--             carry, kicks }
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

  -- BattleCommand_DamageCalc (`calc`), the TRIPLE KICK multiplier its script
  -- puts before `stab` (`kicks`), then BattleCommand_Stab (`stab`): the
  -- weather, the badge type boost, STAB and the matchup rows.
  local d = M.calc(attacker.level, power, attack, defense, {
    crit = opts.crit, itemBoostPercent = opts.itemBoostPercent, carry = opts.carry,
  })
  if opts.kicks then d = M.multiply(d, opts.kicks) end
  local effect = opts.typeEffect
  if effect == nil then effect = opts.typeEff end
  local immune
  d, immune = M.stab(d, {
    weatherTenths = opts.weatherTenths, badgeTypeBoost = opts.badgeTypeBoost,
    stab = opts.stab, typeEffect = effect,
  })
  if immune then
    result.modified = 0
    result.immune = true
    result.damage = 0
    result.minDamage = 0
    result.maxDamage = 0
    return result
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
