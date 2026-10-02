-- Gen 3 damage, as an integer pipeline.
--
-- Port of engine src/core/game3/battle/damage.lua (`Damage.base`, `Damage.calc`),
-- which is itself pret:
--
--   CalculateBaseDamage   pokefirered/src/pokemon.c:2385     (`M.base`)
--   Cmd_damagecalc        pokefirered/src/battle_script_commands.c:1209
--   Cmd_typecalc          pokefirered/src/battle_script_commands.c:1274
--   ApplyRandomDmgMultiplier / Cmd_adjustnormaldamage   battle_script_commands.c:1558
--
-- The battler shape both functions read (the turn machine builds it; the vector
-- runner builds the same thing with `M.battler`):
--
--   b.mon      = { level, hp, maxHp, status, holdEffect, holdParam, friendship,
--                  weight, hiddenPower = { type, power }, beatUp = { atk, def } }
--   b.stats    = { atk, def, spe, spa, spd }      effective (Transform swaps it)
--   b.stages   = { atk, def, spe, spa, spd, acc, eva }   -6..6
--   b.type1, b.type2 (nil when single-typed), b.ability (pret token or nil),
--   b.speciesNum, and the volatiles this file reads: flashFire, charged,
--   helpingHand, substituteHP, lastPhysDmg / lastPhysBy, lastSpecDmg /
--   lastSpecBy (Counter, Mirror Coat, Revenge), identified (Foresight).
--   b.badges   = { [n] = true } (n 1..8) or nil: its trainer's badges, set only
--                on side a of a fight against the computer (Turn.BADGE_MODES).
--
-- Randomness is drawn from `opts.rng` (an Rng or Rng.scripted), in the engine's
-- order: Magnitude, Psywave, critical hit, damage roll -- each only when reached.
-- `opts.forceCrit` / `opts.forceRoll` / `opts.noRandom` pin those for vectors.
--
-- Nothing here raises; no love, no engine modules, no mod facade.

local need = ...
local Types = need("BattleSim3/Types")
local Crit = need("BattleSim3/Crit")

local M = {}

local floor, max, min = math.floor, math.max, math.min

M.ROLL_MIN = 85
M.ROLL_MAX = 100

-- pret EFFECT_* the pipeline branches on (include/constants/battle_move_effects.h).
local E = {
  EXPLOSION = 7, RETURN = 121, FRUSTRATION = 123, MAGNITUDE = 126, PURSUIT = 128,
  SONICBOOM = 130, HIDDEN_POWER = 135, DRAGON_RAGE = 41, SUPER_FANG = 40,
  LEVEL_DAMAGE = 87, PSYWAVE = 88, COUNTER = 89, FLAIL = 99, FALSE_SWIPE = 101,
  MIRROR_COAT = 144, SOLAR_BEAM = 151, FACADE = 169, SMELLINGSALT = 171,
  REVENGE = 185, ENDEAVOR = 189, ERUPTION = 190, LOW_KICK = 196, WEATHER_BALL = 203,
}
M.E = E

-- pret HOLD_EFFECT_* the base formula reads (include/constants/hold_effects.h).
local HOLD = {
  CHOICE_BAND = 29, SOUL_DEW = 34, DEEP_SEA_TOOTH = 35, DEEP_SEA_SCALE = 36,
  LIGHT_BALL = 45, METAL_POWDER = 64, THICK_CLUB = 65,
}

-- pret SPECIES_* the base formula reads (internal numbering).
local SPECIES = {
  PIKACHU = 25, CUBONE = 104, MAROWAK = 105, DITTO = 132, CLAMPERL = 373,
  LATIAS = 407, LATIOS = 408,
}

local MOVE_STRUGGLE = 165

-- pokefirered/src/pokemon.c:1461 sHoldEffectToType
M.TYPE_BOOST = {
  [31] = 6,  [42] = 8,  [46] = 4,  [47] = 5,  [48] = 12, [49] = 17, [50] = 1,
  [51] = 13, [52] = 11, [53] = 2,  [54] = 3,  [55] = 15, [56] = 7,  [57] = 14,
  [58] = 10, [59] = 16, [60] = 0,
}

-- pokefirered/src/pokemon.c:1442 gStatStageRatios
M.STAGE_RATIO = {
  [-6] = { 10, 40 }, [-5] = { 10, 35 }, [-4] = { 10, 30 }, [-3] = { 10, 25 },
  [-2] = { 10, 20 }, [-1] = { 10, 15 }, [0] = { 10, 10 }, [1] = { 15, 10 },
  [2] = { 20, 10 }, [3] = { 25, 10 }, [4] = { 30, 10 }, [5] = { 35, 10 }, [6] = { 40, 10 },
}

local function int(value, fallback)
  local n = tonumber(value)
  if not n or n ~= n then return fallback end
  return floor(n)
end

local function clampStage(s)
  s = int(s, 0)
  if s < -6 then return -6 end
  if s > 6 then return 6 end
  return s
end
M.clampStage = clampStage

-- pokefirered/src/pokemon.c:2374 APPLY_STAT_MOD
function M.applyStage(stat, stage)
  local r = M.STAGE_RATIO[clampStage(stage)]
  return floor(max(0, int(stat, 0)) * r[1] / r[2])
end

-- ------------------------------------------------------------------
-- accessors (one place that knows the battler shape)
-- ------------------------------------------------------------------

local function monOf(b) return (b and b.mon) or {} end

local function statOf(b, key)
  local s = b and b.stats
  if type(s) ~= "table" then s = monOf(b).stats end
  if type(s) ~= "table" then return 1 end
  return max(0, int(s[key], 1))
end

local function stageOf(b, key)
  local s = b and b.stages
  if type(s) ~= "table" then return 0 end
  return clampStage(s[key])
end

local function statusOf(b)
  local s = monOf(b).status
  if s == nil or s == "" or s == 0 then return nil end
  return s
end

local function holdOf(b)
  local m = monOf(b)
  return int(m.holdEffect, 0), int(m.holdParam, 0)
end

local function hasType(b, t)
  return b ~= nil and (b.type1 == t or b.type2 == t)
end

-- The badges a trainer brings (docs/plans/gen3-badge-rules.md K1), as the set
-- { [n] = true } over n = 1..8, or nil when none survive.  Accepts a list
-- ({ "1", "3" } / { 1, 3 }: each value a badge) or a set ({ [1] = true } /
-- { ["1"] = true }: each key whose value is true); anything that is not an
-- integer 1..8 is dropped, never an error.  The turn machine calls it for side a
-- of a fight against the computer only, so a battler carrying `badges` IS the
-- cart's "the player's side, not a link battle" (Engine.hasBadge, engine.lua:166).
function M.badgeSet(raw)
  if type(raw) ~= "table" then return nil end
  local out, any = {}, false
  for k, v in pairs(raw) do
    local n = nil
    if v == true then
      n = tonumber(k)
    elseif type(k) == "number" then
      n = tonumber(v)
    end
    if n and n == floor(n) and n >= 1 and n <= 8 then
      out[n] = true
      any = true
    end
  end
  return any and out or nil
end

-- pokefirered/src/pokemon.c:2381 FlagGet(FLAG_BADGE0n_GET), read off the
-- battler's own trainer (each human brings their own; the foe side has none).
local function hasBadge(b, n)
  local set = b and b.badges
  return type(set) == "table" and set[n] == true
end
M.hasBadge = hasBadge

-- A convenience for the vector pack and the cross-check: build the battler
-- shape above from one flat spec.
function M.battler(spec)
  spec = spec or {}
  local stats = spec.stats or {}
  local stages = spec.stages or {}
  local types = spec.types or { 0 }
  local he = int(spec.holdEffect, 0)
  local b = {
    mon = {
      level = int(spec.level, 50), hp = int(spec.hp, 100), maxHp = int(spec.maxHp, 100),
      status = spec.status, heldItem = int(spec.heldItem, he > 0 and 1 or 0),
      holdEffect = he, holdParam = int(spec.holdParam, 0),
      friendship = int(spec.friendship, 70), weight = int(spec.weight, 0),
      hiddenPower = spec.hiddenPower, beatUp = spec.beatUp,
    },
    stats = {
      atk = int(stats.atk, 50), def = int(stats.def, 50), spe = int(stats.spe, 50),
      spa = int(stats.spa, 50), spd = int(stats.spd, 50),
    },
    stages = {
      atk = clampStage(stages.atk), def = clampStage(stages.def), spe = clampStage(stages.spe),
      spa = clampStage(stages.spa), spd = clampStage(stages.spd), acc = clampStage(stages.acc),
      eva = clampStage(stages.eva),
    },
    type1 = int(types[1], 0),
    ability = spec.ability,
    speciesNum = int(spec.speciesNum, 0),
    focusEnergy = spec.focusEnergy == true,
    flashFire = spec.flashFire == true,
    charged = spec.charged == true,
    helpingHand = spec.helpingHand == true,
    substituteHP = int(spec.substituteHP, 0),
    identified = spec.identified == true,
    lastPhysDmg = int(spec.lastPhysDmg, 0), lastPhysBy = spec.lastPhysBy,
    lastSpecDmg = int(spec.lastSpecDmg, 0), lastSpecBy = spec.lastSpecBy,
    badges = M.badgeSet(spec.badges),
  }
  local t2 = int(types[2], nil)
  if t2 ~= nil and t2 ~= b.type1 then b.type2 = t2 end
  return b
end

-- ------------------------------------------------------------------
-- variable power
-- ------------------------------------------------------------------

-- pokefirered/src/battle_script_commands.c:8503 (the client precomputes it onto
-- the sheet; the formula is here for the vectors and the client's own use).
function M.hiddenPower(ivs)
  ivs = ivs or {}
  local function g(k) return max(0, int(ivs[k], 0)) end
  local hp, atk, def, spe, spa, spd = g("hp"), g("atk"), g("def"), g("spe"), g("spa"), g("spd")
  local function b(v, bit) return floor(v / bit) % 2 end
  local powerBits = b(hp, 2) + 2 * b(atk, 2) + 4 * b(def, 2) + 8 * b(spe, 2) + 16 * b(spa, 2) + 32 * b(spd, 2)
  local typeBits = b(hp, 1) + 2 * b(atk, 1) + 4 * b(def, 1) + 8 * b(spe, 1) + 16 * b(spa, 1) + 32 * b(spd, 1)
  local power = floor(40 * powerBits / 63) + 30
  local t = floor(15 * typeBits / 63) + 1
  if t >= Types.ID.MYSTERY then t = t + 1 end
  return power, t
end

-- pokefirered/src/battle_script_commands.c:7928
function M.flailPower(hp, maxHp)
  hp = int(hp, 1)
  maxHp = max(1, int(maxHp, 1))
  local n = floor(hp * 48 / maxHp)
  if n == 0 and hp > 0 then n = 1 end
  if n <= 1 then return 200 end
  if n <= 4 then return 150 end
  if n <= 9 then return 100 end
  if n <= 16 then return 80 end
  if n <= 32 then return 40 end
  return 20
end

-- pokefirered/src/battle_script_commands.c:9074 (weight in hectograms)
function M.lowKickPower(weight)
  local wt = int(weight, 0)
  local tbl = { { 100, 20 }, { 250, 40 }, { 500, 60 }, { 1000, 80 }, { 2000, 100 } }
  for _, row in ipairs(tbl) do
    if row[1] > wt then return row[2] end
  end
  return 120
end

-- pokefirered/src/battle_script_commands.c:8284 -> magnitude, power
function M.magnitude(r)
  r = int(r, 0)
  if r < 5 then return 4, 10 end
  if r < 15 then return 5, 30 end
  if r < 35 then return 6, 50 end
  if r < 65 then return 7, 70 end
  if r < 85 then return 8, 90 end
  if r < 95 then return 9, 110 end
  return 10, 150
end

-- pokefirered/src/battle_script_commands.c:7557
function M.psywave(level, r)
  r = max(0, min(10, int(r, 0)))
  return floor(int(level, 1) * (r * 10 + 50) / 100)
end

-- ------------------------------------------------------------------
-- CalculateBaseDamage
-- ------------------------------------------------------------------

-- opts: power, moveType, crit, reflect, lightScreen, doubleScreens, spread,
--       weather ("RAIN"|"SUN"|"SAND"|"HAIL"|nil, already Cloud-Nine-filtered),
--       mudSport, waterSport, specialTypes, plusPartner (a PLUS is on the
--       field), minusPartner (a MINUS is on the field)
function M.base(attacker, defender, move, opts)
  opts = opts or {}
  move = move or {}
  local aMon, dMon = monOf(attacker), monOf(defender)
  local power = int(opts.power, nil) or max(0, int(move.power, 0))
  local moveType = int(opts.moveType, nil) or int(move.type, 0)
  local crit = opts.crit and true or false

  local attack = statOf(attacker, "atk")
  local defense = statOf(defender, "def")
  local spAttack = statOf(attacker, "spa")
  local spDefense = statOf(defender, "spd")

  local aAb = attacker and attacker.ability
  local dAb = defender and defender.ability
  if aAb == "HUGE_POWER" or aAb == "PURE_POWER" then attack = attack * 2 end

  -- pokefirered/src/pokemon.c:2381 badge boosts (engine damage.lua:205-217):
  -- x110/100 floored, after Huge Power / Pure Power and before the held items and
  -- the abilities below; the stat stages come later, in the formula.  Badge 1 the
  -- attacker's Attack, 5 the defender's Defense, 7 the attacker's Sp. Atk and the
  -- defender's Sp. Def -- each read off that battler's own trainer, so a self-hit
  -- (confusion, disobedience: attacker and defender the same battler) carries
  -- both of its own.  `b.badges` exists only on side a against the computer
  -- (Turn.BADGE_MODES); Emerald's e-reader / secret base / frontier / recorded
  -- exclusions (pokeemerald/src/pokemon.c:3407) are fights no referee hosts.
  if hasBadge(attacker, 1) then attack = floor(110 * attack / 100) end
  if hasBadge(defender, 5) then defense = floor(110 * defense / 100) end
  if hasBadge(attacker, 7) then spAttack = floor(110 * spAttack / 100) end
  if hasBadge(defender, 7) then spDefense = floor(110 * spDefense / 100) end

  local aHe, aParam = holdOf(attacker)
  local dHe = holdOf(defender)
  if M.TYPE_BOOST[aHe] ~= nil and M.TYPE_BOOST[aHe] == moveType then
    if Types.isPhysical(moveType, opts.specialTypes) then
      attack = floor(attack * (aParam + 100) / 100)
    else
      spAttack = floor(spAttack * (aParam + 100) / 100)
    end
  end
  local aSp = int(attacker and attacker.speciesNum, 0)
  local dSp = int(defender and defender.speciesNum, 0)
  if aHe == HOLD.CHOICE_BAND then attack = floor(150 * attack / 100) end
  if aHe == HOLD.SOUL_DEW and (aSp == SPECIES.LATIAS or aSp == SPECIES.LATIOS) then
    spAttack = floor(150 * spAttack / 100)
  end
  if dHe == HOLD.SOUL_DEW and (dSp == SPECIES.LATIAS or dSp == SPECIES.LATIOS) then
    spDefense = floor(150 * spDefense / 100)
  end
  if aHe == HOLD.DEEP_SEA_TOOTH and aSp == SPECIES.CLAMPERL then spAttack = spAttack * 2 end
  if dHe == HOLD.DEEP_SEA_SCALE and dSp == SPECIES.CLAMPERL then spDefense = spDefense * 2 end
  if aHe == HOLD.LIGHT_BALL and aSp == SPECIES.PIKACHU then spAttack = spAttack * 2 end
  if dHe == HOLD.METAL_POWDER and dSp == SPECIES.DITTO then defense = defense * 2 end
  if aHe == HOLD.THICK_CLUB and (aSp == SPECIES.CUBONE or aSp == SPECIES.MAROWAK) then
    attack = attack * 2
  end
  if dAb == "THICK_FAT" and (moveType == Types.ID.FIRE or moveType == Types.ID.ICE) then
    spAttack = floor(spAttack / 2)
  end
  if aAb == "HUSTLE" then attack = floor(150 * attack / 100) end
  if (aAb == "PLUS" and opts.minusPartner) or (aAb == "MINUS" and opts.plusPartner) then
    spAttack = floor(150 * spAttack / 100)
  end
  if aAb == "GUTS" and statusOf(attacker) then attack = floor(150 * attack / 100) end
  if dAb == "MARVEL_SCALE" and statusOf(defender) then defense = floor(150 * defense / 100) end
  if moveType == Types.ID.ELECTRIC and opts.mudSport then power = floor(5 * power / 10) end
  if moveType == Types.ID.FIRE and opts.waterSport then power = floor(5 * power / 10) end
  local aHp = int(aMon.hp, 0)
  local aMax = max(1, int(aMon.maxHp, 1))
  if aHp <= floor(aMax / 3) and ((moveType == Types.ID.GRASS and aAb == "OVERGROW")
      or (moveType == Types.ID.FIRE and aAb == "BLAZE")
      or (moveType == Types.ID.WATER and aAb == "TORRENT")
      or (moveType == Types.ID.BUG and aAb == "SWARM")) then
    power = floor(150 * power / 100)
  end

  if int(move.effect, -1) == E.EXPLOSION then defense = floor(defense / 2) end

  local level = int(aMon.level, 1)
  local levelFactor = floor(2 * level / 5) + 2
  local damage = 0

  if Types.isPhysical(moveType, opts.specialTypes) then
    local atkStage = stageOf(attacker, "atk")
    if crit and atkStage <= 0 then atkStage = 0 end
    damage = M.applyStage(attack, atkStage)
    damage = damage * power
    damage = damage * levelFactor
    local defStage = stageOf(defender, "def")
    if crit and defStage >= 0 then defStage = 0 end
    local helper = max(1, M.applyStage(defense, defStage))
    damage = floor(damage / helper)
    damage = floor(damage / 50)
    if statusOf(attacker) == "BRN" and aAb ~= "GUTS" then damage = floor(damage / 2) end
    if opts.reflect and not crit then
      if opts.doubleScreens then damage = 2 * floor(damage / 3) else damage = floor(damage / 2) end
    end
    -- pokefirered/src/pokemon.c:2552
    if opts.spread then damage = floor(damage / 2) end
    if damage == 0 then damage = 1 end
  end

  if moveType == Types.ID.MYSTERY then damage = 0 end

  if Types.isSpecial(moveType, opts.specialTypes) then
    local atkStage = stageOf(attacker, "spa")
    if crit and atkStage <= 0 then atkStage = 0 end
    damage = M.applyStage(spAttack, atkStage)
    damage = damage * power
    damage = damage * levelFactor
    local defStage = stageOf(defender, "spd")
    if crit and defStage >= 0 then defStage = 0 end
    local helper = max(1, M.applyStage(spDefense, defStage))
    damage = floor(damage / helper)
    damage = floor(damage / 50)
    if opts.lightScreen and not crit then
      if opts.doubleScreens then damage = 2 * floor(damage / 3) else damage = floor(damage / 2) end
    end
    -- pokefirered/src/pokemon.c:2604
    if opts.spread then damage = floor(damage / 2) end
    local weather = opts.weather
    if weather == "RAIN" then
      if moveType == Types.ID.FIRE then damage = floor(damage / 2)
      elseif moveType == Types.ID.WATER then damage = floor(15 * damage / 10) end
    end
    if (weather == "RAIN" or weather == "SAND" or weather == "HAIL")
        and int(move.effect, -1) == E.SOLAR_BEAM then
      damage = floor(damage / 2)
    end
    if weather == "SUN" then
      if moveType == Types.ID.FIRE then damage = floor(15 * damage / 10)
      elseif moveType == Types.ID.WATER then damage = floor(damage / 2) end
    end
    if attacker and attacker.flashFire and moveType == Types.ID.FIRE then
      damage = floor(15 * damage / 10)
    end
  end

  return damage + 2
end

-- ------------------------------------------------------------------
-- the whole pipeline
-- ------------------------------------------------------------------

local function roll(opts, lo, hi)
  local rng = opts.rng
  if rng and rng.roll then return rng:roll(lo, hi) end
  return hi
end

local function fixedInfo(move, product, flags, physical, extra)
  local info = {
    move = move, effectiveness = product, critical = false, physical = physical,
    fixed = true, typeFlags = flags,
  }
  for k, v in pairs(extra or {}) do info[k] = v end
  return info
end

-- opts (beyond M.base's): typeTable, rng, forceCrit, forceRoll, noRandom, noCrit,
--   dmgMultiplier, magnitudeRoll, psywaveRoll, pursuitSwitch, double
--   (doubles-mode Revenge bookkeeping), attackerId (this battle's id for the
--   attacker, Revenge), foresight (override; default defender.identified).
--
-- Returns damage, info = { effectiveness (product x100), critical, physical,
--   stab, magnitude, moveType, typeFlags, power, failed?, fixed?, setDamage?,
--   status? }.
function M.calc(attacker, defender, move, opts)
  opts = opts or {}
  move = move or {}
  local aMon, dMon = monOf(attacker), monOf(defender)
  local effect = int(move.effect, 0)
  local power = int(opts.power, nil) or max(0, int(move.power, 0))
  local moveType = int(opts.moveType, nil) or int(move.type, 0)
  local dmgMultiplier = max(1, int(opts.dmgMultiplier, 1))
  local magnitudeVal = nil
  local weather = opts.weather
  local level = int(aMon.level, 1)

  if power <= 0 and opts.power == nil then
    return 0, { move = move, effectiveness = 100, critical = false, status = true }
  end

  if effect == E.MAGNITUDE and opts.power == nil then
    local r = int(opts.magnitudeRoll, nil) or roll(opts, 0, 99)
    magnitudeVal, power = M.magnitude(r)
  elseif effect == E.RETURN and opts.power == nil then
    power = floor(10 * int(aMon.friendship, 70) / 25)
  elseif effect == E.FRUSTRATION and opts.power == nil then
    power = floor(10 * (255 - int(aMon.friendship, 70)) / 25)
  elseif effect == E.ERUPTION and opts.power == nil then
    power = floor(int(aMon.hp, 1) * power / max(1, int(aMon.maxHp, 1)))
    if power == 0 then power = 1 end
  elseif effect == E.FLAIL and opts.power == nil then
    power = M.flailPower(aMon.hp, aMon.maxHp)
  elseif effect == E.LOW_KICK and opts.power == nil then
    power = M.lowKickPower(dMon.weight)
  elseif effect == E.HIDDEN_POWER and opts.power == nil then
    local hpw = aMon.hiddenPower
    if type(hpw) == "table" then
      power = max(1, int(hpw.power, 70))
      if opts.moveType == nil then moveType = int(hpw.type, moveType) end
    end
  elseif effect == E.WEATHER_BALL and opts.moveType == nil then
    -- pokefirered/src/battle_script_commands.c:9345
    if weather then
      dmgMultiplier = dmgMultiplier * 2
      if weather == "RAIN" then moveType = Types.ID.WATER
      elseif weather == "SAND" then moveType = Types.ID.ROCK
      elseif weather == "SUN" then moveType = Types.ID.FIRE
      elseif weather == "HAIL" then moveType = Types.ID.ICE end
    end
  end

  -- The engine guards these three with `not opts.dmgMultiplier`, which is always
  -- false on its in-battle path (calc_opts passes the scripting multiplier, 1 by
  -- default), so its Facade / Revenge / SmellingSalt never double.  pret sets the
  -- multiplier in the move's own script (battle_scripts_1.s BattleScript_Facade-
  -- DoubleDmg, Revenge, SmellingSalt), so the doubling is applied here
  -- unconditionally -- the cart's behaviour, and a documented engine gap.
  if effect == E.PURSUIT and opts.pursuitSwitch then
    dmgMultiplier = dmgMultiplier * 2
  elseif effect == E.FACADE then
    local st = statusOf(attacker)
    if st == "BRN" or st == "PAR" or st == "PSN" or st == "TOX" then
      dmgMultiplier = dmgMultiplier * 2
    end
  elseif effect == E.REVENGE then
    -- pokefirered/src/battle_script_commands.c:8946 Cmd_doubledamagedealtifdamaged:
    -- hurt this turn, physically or specially, BY THIS TARGET.  (The engine keys
    -- the singles case on the side and the doubles case on the id; one seat is
    -- one battler here, so the id is the whole rule.)
    local by = opts.defenderId
    if (int(attacker.lastPhysDmg, 0) > 0 and attacker.lastPhysBy == by)
        or (int(attacker.lastSpecDmg, 0) > 0 and attacker.lastSpecBy == by) then
      dmgMultiplier = dmgMultiplier * 2
    end
  elseif effect == E.SMELLINGSALT then
    if statusOf(defender) == "PAR" and int(defender.substituteHP, 0) <= 0 then
      dmgMultiplier = dmgMultiplier * 2
    end
  end

  local physical = Types.isPhysical(moveType, opts.specialTypes)
  local foresight = opts.foresight
  if foresight == nil then foresight = defender.identified and true or false end
  local _, flags, product = Types.typeCalc(opts.typeTable, moveType, defender.type1,
    defender.type2, nil, foresight)

  local fixedAmount = nil
  if effect == E.COUNTER or effect == E.MIRROR_COAT then
    local taken = (effect == E.COUNTER) and int(attacker.lastPhysDmg, 0) or int(attacker.lastSpecDmg, 0)
    if taken <= 0 then
      return 0, { move = move, effectiveness = product, critical = false, physical = physical, failed = true }
    end
    return (flags.immune and 0 or taken * 2), {
      move = move, effectiveness = product, critical = false, physical = physical,
      typeFlags = flags, setDamage = true, moveType = moveType,
    }
  elseif effect == E.DRAGON_RAGE then
    fixedAmount = 40
  elseif effect == E.SONICBOOM then
    fixedAmount = 20
  elseif effect == E.LEVEL_DAMAGE then
    fixedAmount = level
  elseif effect == E.SUPER_FANG then
    fixedAmount = max(1, floor(int(dMon.hp, 1) / 2))
  elseif effect == E.ENDEAVOR then
    local uHp, dHp = int(aMon.hp, 0), int(dMon.hp, 0)
    if dHp <= uHp then
      return 0, { move = move, effectiveness = product, critical = false, physical = physical, failed = true }
    end
    fixedAmount = dHp - uHp
  elseif effect == E.PSYWAVE then
    local r = int(opts.psywaveRoll, nil) or roll(opts, 0, 10)
    fixedAmount = M.psywave(level, r)
  elseif opts.fixedDamage then
    fixedAmount = int(opts.fixedDamage, 0)
  end
  if fixedAmount then
    if flags.immune then return 0, fixedInfo(move, 0, flags, physical, { moveType = moveType }) end
    return fixedAmount, fixedInfo(move, product, flags, physical, { moveType = moveType })
  end

  local crit = false
  local dAb = defender.ability
  if opts.forceCrit ~= nil then
    crit = opts.forceCrit and true or false
  elseif dAb ~= "BATTLE_ARMOR" and dAb ~= "SHELL_ARMOR" and not opts.noCrit then
    -- pokefirered/src/battle_script_commands.c:1170
    local stage = Crit.stage(attacker, move)
    crit = Crit.check(stage, roll(opts, 0, Crit.chance(stage) - 1))
  end
  local critMul = crit and Crit.MULTIPLIER or 1

  local dmg = M.base(attacker, defender, move, {
    power = power, moveType = moveType, crit = crit,
    reflect = opts.reflect, lightScreen = opts.lightScreen, doubleScreens = opts.doubleScreens,
    spread = opts.spread, weather = weather, mudSport = opts.mudSport,
    waterSport = opts.waterSport, specialTypes = opts.specialTypes,
    plusPartner = opts.plusPartner, minusPartner = opts.minusPartner,
  })
  -- pokefirered/src/battle_script_commands.c:1209
  dmg = dmg * critMul * dmgMultiplier
  if attacker.charged and int(move.type, -1) == Types.ID.ELECTRIC then dmg = dmg * 2 end
  -- pokefirered/src/battle_script_commands.c:1219
  if attacker.helpingHand then dmg = floor(dmg * 15 / 10) end

  local stab = false
  local struggle = int(move.num, 0) == MOVE_STRUGGLE
  if not struggle then
    if hasType(attacker, moveType) then
      stab = true
      dmg = floor(dmg * 15 / 10)
    end
    dmg, flags, product = Types.typeCalc(opts.typeTable, moveType, defender.type1,
      defender.type2, dmg, foresight)
  else
    flags = { super = false, notVery = false, immune = false }
    product = 100
  end
  if flags.immune then
    return 0, {
      move = move, effectiveness = 0, critical = false, physical = physical,
      stab = stab, magnitude = magnitudeVal, moveType = moveType, typeFlags = flags,
      power = power, struggle = struggle,
    }
  end

  -- pokefirered/src/battle_script_commands.c:1558
  if dmg ~= 0 and not opts.noRandom then
    local r = int(opts.forceRoll, nil) or roll(opts, M.ROLL_MIN, M.ROLL_MAX)
    dmg = floor(dmg * r / 100)
    if dmg == 0 then dmg = 1 end
  end

  if effect == E.FALSE_SWIPE and int(defender.substituteHP, 0) <= 0 then
    local curHp = int(dMon.hp, 1)
    if dmg >= curHp then dmg = max(0, curHp - 1) end
  end

  return dmg, {
    move = move, effectiveness = product, critical = crit, physical = physical,
    stab = stab, magnitude = magnitudeVal, moveType = moveType, typeFlags = flags,
    power = power, struggle = struggle,
  }
end

-- The confusion self-hit and disobedience self-hit: pret battle_util.c:1424,
-- a typeless 40-power physical hit on itself (CalculateBaseDamage with the
-- attacker as both sides), no crit, no STAB, no chart, then the 85..100 roll
-- (battle_scripts_1.s:3741) which the caller draws.  The battler's own badges
-- boost it as on the cart (badge 1 its Attack, badge 5 its Defense: the engine's
-- Damage.base(user, user, ...), engine.lua:668 / :1341).
function M.selfHitBase(b)
  return M.base(b, b, { power = 40, type = 0, effect = 0 }, { power = 40, moveType = 0 })
end

return M
