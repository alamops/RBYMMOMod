-- Gen 3 abilities: the id table and every battle behaviour.
--
-- Port of engine src/core/game3/battle/abilities.lua (pret battle_util.c
-- AbilityBattleEffects) plus the ability call sites scattered through the
-- engine's damage / accuracy / canceller / residual code (those live beside
-- their formula: Damage.lua, Accuracy.lua, Move.lua).  This file holds the ones
-- with a trigger of their own: switch-in (weather setters, Intimidate, Trace,
-- Forecast, Cloud Nine / Air Lock), end of turn (Rain Dish, Shed Skin, Speed
-- Boost, Truant), absorb (Volt / Water Absorb, Flash Fire), contact (Static,
-- Flame Body, Poison Point, Effect Spore, Rough Skin, Cute Charm), Color Change,
-- the immunity cures, Synchronize, the escape blockers and Natural Cure.
--
-- Every behaviour takes the battle `B` first and talks to the field through the
-- helper surface Move.lua installs on it (B:roll, B:active, B:foes, B:say,
-- B:emitAbility, B:heal, B:loseHp, B:inflict, B:cure, B:weather, ...).  The ids
-- are pret include/constants/abilities.h -- code constants, not data.
--
-- Nothing here raises; no love, no engine modules, no mod facade.

local need = ...
local Types = need("BattleSim3/Types")
local Status = need("BattleSim3/Status")

local M = {}

local floor, max = math.floor, math.max

-- pokefirered/include/constants/abilities.h
M.BY_ID = {
  [1] = "STENCH", [2] = "DRIZZLE", [3] = "SPEED_BOOST", [4] = "BATTLE_ARMOR", [5] = "STURDY",
  [6] = "DAMP", [7] = "LIMBER", [8] = "SAND_VEIL", [9] = "STATIC", [10] = "VOLT_ABSORB",
  [11] = "WATER_ABSORB", [12] = "OBLIVIOUS", [13] = "CLOUD_NINE", [14] = "COMPOUND_EYES",
  [15] = "INSOMNIA", [16] = "COLOR_CHANGE", [17] = "IMMUNITY", [18] = "FLASH_FIRE",
  [19] = "SHIELD_DUST", [20] = "OWN_TEMPO", [21] = "SUCTION_CUPS", [22] = "INTIMIDATE",
  [23] = "SHADOW_TAG", [24] = "ROUGH_SKIN", [25] = "WONDER_GUARD", [26] = "LEVITATE",
  [27] = "EFFECT_SPORE", [28] = "SYNCHRONIZE", [29] = "CLEAR_BODY", [30] = "NATURAL_CURE",
  [31] = "LIGHTNING_ROD", [32] = "SERENE_GRACE", [33] = "SWIFT_SWIM", [34] = "CHLOROPHYLL",
  [35] = "ILLUMINATE", [36] = "TRACE", [37] = "HUGE_POWER", [38] = "POISON_POINT",
  [39] = "INNER_FOCUS", [40] = "MAGMA_ARMOR", [41] = "WATER_VEIL", [42] = "MAGNET_PULL",
  [43] = "SOUNDPROOF", [44] = "RAIN_DISH", [45] = "SAND_STREAM", [46] = "PRESSURE",
  [47] = "THICK_FAT", [48] = "EARLY_BIRD", [49] = "FLAME_BODY", [50] = "RUN_AWAY",
  [51] = "KEEN_EYE", [52] = "HYPER_CUTTER", [53] = "PICKUP", [54] = "TRUANT", [55] = "HUSTLE",
  [56] = "CUTE_CHARM", [57] = "PLUS", [58] = "MINUS", [59] = "FORECAST", [60] = "STICKY_HOLD",
  [61] = "SHED_SKIN", [62] = "GUTS", [63] = "MARVEL_SCALE", [64] = "LIQUID_OOZE",
  [65] = "OVERGROW", [66] = "BLAZE", [67] = "TORRENT", [68] = "SWARM", [69] = "ROCK_HEAD",
  [70] = "DROUGHT", [71] = "ARENA_TRAP", [72] = "VITAL_SPIRIT", [73] = "WHITE_SMOKE",
  [74] = "PURE_POWER", [75] = "SHELL_ARMOR", [76] = "CACOPHONY", [77] = "AIR_LOCK",
}
M.ID = {}
for id, name in pairs(M.BY_ID) do M.ID[name] = id end
M.MAX = 77

-- pokefirered/src/battle_util.c:31 sSoundMovesTable (move numbers)
M.SOUND_MOVES = { [45] = true, [46] = true, [47] = true, [48] = true, [103] = true,
  [173] = true, [253] = true, [319] = true, [320] = true, [304] = true }

M.SPECIES_CASTFORM = 385

local function int(value, fallback)
  local n = tonumber(value)
  if not n or n ~= n then return fallback end
  return floor(n)
end

function M.nameOf(id)
  id = int(id, 0)
  return M.BY_ID[id]
end

function M.idOf(name)
  return M.ID[name] or 0
end

-- The display name an ability is narrated under: the sheet's, or the token.
function M.label(name, sheetName)
  if type(sheetName) == "string" and sheetName ~= "" then return sheetName end
  if type(name) ~= "string" then return "ability" end
  return (name:gsub("_", " "))
end

local function isType(b, t) return b ~= nil and (b.type1 == t or b.type2 == t) end
M.isType = isType

local function setType(b, t) b.type1 = t; b.type2 = nil end

local function nm(B, b) return B:nameOf(b) end

-- ------------------------------------------------------------------
-- Forecast (pokefirered/src/battle_util.c:1611 CastformDataTypeChange)
-- ------------------------------------------------------------------

-- Returns 0 for no change, else form + 1 (1 normal, 2 sunny, 3 rainy, 4 snowy),
-- the engine's encoding; the `form` event carries form - 1.
function M.castformChange(B, b)
  if not b or int(b.speciesNum, 0) ~= M.SPECIES_CASTFORM or b.ability ~= "FORECAST"
      or int(b.mon.hp, 0) <= 0 then
    return 0
  end
  local w = B:weather()
  if not w and not isType(b, Types.ID.NORMAL) then
    setType(b, Types.ID.NORMAL)
    return 1
  end
  if not w then return 0 end
  local form = 0
  if w ~= "RAIN" and w ~= "SUN" and w ~= "HAIL" and not isType(b, Types.ID.NORMAL) then
    setType(b, Types.ID.NORMAL); form = 1
  end
  if w == "SUN" and not isType(b, Types.ID.FIRE) then setType(b, Types.ID.FIRE); form = 2 end
  if w == "RAIN" and not isType(b, Types.ID.WATER) then setType(b, Types.ID.WATER); form = 3 end
  if w == "HAIL" and not isType(b, Types.ID.ICE) then setType(b, Types.ID.ICE); form = 4 end
  return form
end

-- pokefirered/data/battle_scripts_1.s:3972
local function castformScript(B, b, form)
  b.castformForm = form - 1
  B:emit("form", { slot = b.slot, side = b.side, amount = form - 1 })
  B:say(nm(B, b) .. " transformed!")
end

-- pokefirered/src/battle_util.c:2169 (ABILITYEFFECT_FORECAST): the first
-- Castform that changes, and only one per call.
function M.forecast(B)
  for _, b in ipairs(B:active()) do
    if b.ability == "FORECAST" then
      local form = M.castformChange(B, b)
      if form ~= 0 then
        castformScript(B, b, form)
        return true
      end
    end
  end
  return false
end

local function weatherFormChanges(B)
  for _ = 1, 2 do
    if not M.forecast(B) then break end
  end
end

-- ------------------------------------------------------------------
-- switch-in (pokefirered/src/battle_util.c:1704 ABILITYEFFECT_ON_SWITCHIN)
-- ------------------------------------------------------------------

local WEATHER_ABILITY = {
  DRIZZLE = { "RAIN", "'s DRIZZLE made it rain!" },
  SAND_STREAM = { "SAND", "'s SAND STREAM whipped up a sandstorm!" },
  DROUGHT = { "SUN", "'s DROUGHT intensified the sun's rays!" },
}

function M.switchIn(B, b)
  if not b or int(b.mon.hp, 0) <= 0 then return false end
  local ab = b.ability
  -- pokefirered/src/battle_util.c:1698: in a veiled GHOST fight Intimidate and
  -- Trace do nothing, either side (Turn.create `ghost = "veiled"`; the engine's
  -- Abilities.ghostBlocks).
  if B.ghost == "veiled" and (ab == "INTIMIDATE" or ab == "TRACE") then return false end
  local row = WEATHER_ABILITY[ab or ""]
  if row then
    -- An ability's weather is permanent (weatherTurns 0); the same permanent
    -- weather already up does nothing.
    if not (B.field.weather == row[1] and int(B.field.weatherTurns, 0) <= 0) then
      B.field.weather, B.field.weatherTurns = row[1], 0
      B:emitAbility(b)
      B:emit("weather", { text = row[1], amount = 1, slot = b.slot, side = b.side })
      B:say(nm(B, b) .. row[2])
      weatherFormChanges(B)
      return true
    end
  elseif ab == "INTIMIDATE" then
    if not b.intimidated then
      b.intimidatePending = true
      b.intimidated = true
    end
  elseif ab == "FORECAST" then
    local form = M.castformChange(B, b)
    if form ~= 0 then
      castformScript(B, b, form)
      return true
    end
  elseif ab == "TRACE" then
    if not b.traced then
      b.tracePending = true
      b.traced = true
    end
  elseif ab == "CLOUD_NINE" or ab == "AIR_LOCK" then
    for _, o in ipairs(B:active()) do
      local form = M.castformChange(B, o)
      if form ~= 0 then
        castformScript(B, o, form)
        return true
      end
    end
  end
  return false
end

-- pokefirered/data/battle_scripts_1.s:3983 BattleScript_IntimidateActivates
local function intimidateOne(B, b, foe)
  if not (foe and int(foe.mon.hp, 0) > 0 and int(foe.substituteHP, 0) <= 0) then return end
  local fab = foe.ability
  if fab == "CLEAR_BODY" or fab == "HYPER_CUTTER" or fab == "WHITE_SMOKE" then
    -- src/battle_script_commands.c:9181
    B:emitAbility(foe)
    B:say(nm(B, foe) .. "'s " .. B:abilityLabel(foe) .. " prevents " .. B:abilityLabel(b) .. "!")
  else
    local side = B:sideState(foe.side)
    if int(side.mistTurns, 0) > 0 then
      if not foe.statLoweredMsg then
        foe.statLoweredMsg = true
        B:say(nm(B, foe) .. " is protected by MIST!")
      end
    elseif foe.stages.atk > -6 then
      foe.stages.atk = foe.stages.atk - 1
      B:emit("stat", { slot = foe.slot, side = foe.side, stat = "atk", stage = foe.stages.atk,
                       delta = -1, text = nm(B, b) .. "'s INTIMIDATE cuts " .. nm(B, foe) .. "'s ATTACK!" })
      B:say(nm(B, b) .. "'s INTIMIDATE cuts " .. nm(B, foe) .. "'s ATTACK!")
    end
  end
end

-- The first pending Intimidate on the field resolves; the caller loops.
function M.runIntimidate(B)
  for _, b in ipairs(B:active()) do
    if b.intimidatePending and b.ability == "INTIMIDATE" then
      b.intimidatePending = nil
      -- pokefirered/src/battle_script_commands.c:9174 (every foe in doubles);
      -- one `ability` event for the activation, a line per foe.
      B:emitAbility(b)
      for _, foe in ipairs(B:foes(b)) do intimidateOne(B, b, foe) end
      return true
    end
  end
  return false
end

-- pokefirered/src/battle_util.c:2231 ABILITYEFFECT_TRACE
function M.runTrace(B)
  for _, b in ipairs(B:active()) do
    if b.tracePending and b.ability == "TRACE" then
      local cands = {}
      for _, foe in ipairs(B:foes(b)) do
        if foe.ability and int(foe.mon.hp, 0) > 0 then cands[#cands + 1] = foe end
      end
      local foe = nil
      if #cands == 1 then
        foe = cands[1]
      elseif #cands >= 2 then
        -- battle_util.c:2243: a coin between the two foes; with a wider field,
        -- one draw over every traceable foe (a single foe draws nothing).
        foe = cands[B:roll(0, #cands - 1) + 1]
      end
      if foe then
        b.tracePending = nil
        b.ability = foe.ability
        b.abilityName = foe.abilityName
        -- src/battle_util.c:2281
        B:emitAbility(b)
        B:say(nm(B, b) .. " TRACED " .. nm(B, foe) .. "'s " .. B:abilityLabel(foe) .. "!")
        return true
      end
    end
  end
  return false
end

-- ------------------------------------------------------------------
-- end of turn (pokefirered/src/battle_util.c:1816 ABILITYEFFECT_ENDTURN)
-- ------------------------------------------------------------------

function M.endTurn(B, b)
  if not b or int(b.mon.hp, 0) <= 0 then return false end
  local ab = b.ability
  if ab == "RAIN_DISH" then
    if B:weather() == "RAIN" and b.mon.maxHp > b.mon.hp then
      local amt = floor(b.mon.maxHp / 16)
      if amt == 0 then amt = 1 end
      B:emitAbility(b)
      B:say(nm(B, b) .. "'s RAIN DISH restored its HP a little!")
      B:heal(b, amt)
      return true
    end
  elseif ab == "SHED_SKIN" then
    local s = Status.normalise(b.mon.status)
    if s and B:roll(0, 2) == 0 then
      B:emitAbility(b)
      B:cure(b, nm(B, b) .. "'s SHED SKIN cured its " .. (Status.WORD[s] or "status") .. " problem!")
      b.nightmare = nil
      return true
    end
  elseif ab == "SPEED_BOOST" then
    if b.stages.spe < 6 and int(b.isFirstTurn, 0) ~= 2 then
      b.stages.spe = b.stages.spe + 1
      B:emitAbility(b)
      B:emit("stat", { slot = b.slot, side = b.side, stat = "spe", stage = b.stages.spe, delta = 1,
                       text = nm(B, b) .. "'s SPEED BOOST raised its SPEED!" })
      B:say(nm(B, b) .. "'s SPEED BOOST raised its SPEED!")
      return true
    end
  elseif ab == "TRUANT" then
    b.truantCounter = (int(b.truantCounter, 0) == 0) and 1 or 0
  end
  return false
end

-- pokefirered/src/battle_util.c:1337
function M.truantLoafs(b)
  return b ~= nil and b.ability == "TRUANT" and int(b.truantCounter, 0) ~= 0
end

-- pokefirered/src/battle_util.c:1874: the move is a sound move and the target
-- is Soundproof.
function M.soundproofBlocks(target, moveNum)
  return target ~= nil and target.ability == "SOUNDPROOF" and M.SOUND_MOVES[int(moveNum, -1)] == true
end

-- ------------------------------------------------------------------
-- absorb (pokefirered/src/battle_util.c:1891 ABILITYEFFECT_ABSORBING)
-- ------------------------------------------------------------------

-- Returns true when the target's ability swallowed the move (the caller marks
-- the move as having no effect).  Narration and healing happen here.
function M.absorb(B, user, target, moveType, power, moveName)
  if not target or target == user then return false end
  local ab = target.ability
  local kind
  if ab == "VOLT_ABSORB" and moveType == Types.ID.ELECTRIC and power ~= 0 then kind = "hp"
  elseif ab == "WATER_ABSORB" and moveType == Types.ID.WATER and power ~= 0 then kind = "hp"
  elseif ab == "FLASH_FIRE" and moveType == Types.ID.FIRE
      and Status.normalise(target.mon.status) ~= "FRZ" then kind = "fire" end
  if not kind then return false end
  B:emitAbility(target)
  if kind == "fire" then
    if not target.flashFire then
      target.flashFire = true
      B:say(nm(B, target) .. "'s FLASH FIRE raised its FIRE power!")
    else
      B:say(nm(B, target) .. "'s FLASH FIRE made " .. moveName .. " ineffective!")
    end
    return true
  end
  if target.mon.hp >= target.mon.maxHp then
    B:say(nm(B, target) .. "'s " .. B:abilityLabel(target) .. " made " .. moveName .. " useless!")
  else
    local amt = floor(target.mon.maxHp / 4)
    if amt == 0 then amt = 1 end
    B:heal(target, amt)
    B:say(nm(B, target) .. " restored HP using its " .. B:abilityLabel(target) .. "!")
  end
  return true
end

-- ------------------------------------------------------------------
-- status from an ability (pokefirered/src/battle_script_commands.c:2110)
-- ------------------------------------------------------------------

-- holder: the battler whose ability acts; victim: who takes the status.
-- primary: a Synchronize pass (announces the prevention the way a primary
-- status move does).
function M.applyStatus(B, holder, victim, status, primary, M_)
  if not victim or int(victim.mon.hp, 0) <= 0 then return false end
  -- SetMoveEffect's TEACHY TV arm (pokefirered/src/battle_script_commands.c:
  -- 2128; Effects.set): no status but sleep lands on side b, silently.
  if B.tutorial == "pokedude" and status ~= "SLP" and victim.side == "b" then return false end
  if int(victim.substituteHP, 0) > 0 and victim ~= (M_ and M_.user) then return false end
  local vab = victim.ability
  local vs = Status.normalise(victim.mon.status)
  local function prevents()
    B:emitAbility(victim)
    B:say(nm(B, victim) .. "'s " .. B:abilityLabel(victim) .. " prevents it!")
    return false
  end
  local function noEffect()
    B:say(nm(B, holder) .. "'s " .. B:abilityLabel(holder) .. " had no effect on " .. nm(B, victim) .. "!")
    return false
  end
  if status == "SLP" then
    if vs then return false end
    if vab ~= "SOUNDPROOF" and B:uproarActive() then return false end
    if vab == "VITAL_SPIRIT" or vab == "INSOMNIA" then return false end
  elseif status == "PSN" or status == "TOX" then
    if vab == "IMMUNITY" and primary then return prevents() end
    local immuneType = isType(victim, Types.ID.POISON) or isType(victim, Types.ID.STEEL)
    if immuneType and primary then return noEffect() end
    if immuneType then return false end
    if vs or vab == "IMMUNITY" then return false end
  elseif status == "BRN" then
    if vab == "WATER_VEIL" and primary then return prevents() end
    if isType(victim, Types.ID.FIRE) and primary then return noEffect() end
    if isType(victim, Types.ID.FIRE) or vab == "WATER_VEIL" or vs then return false end
  elseif status == "PAR" then
    if vab == "LIMBER" then
      if primary then return prevents() end
      return false
    end
    if vs then return false end
  else
    return false
  end
  B:emitAbility(holder)
  local text
  if status == "TOX" then
    text = nm(B, victim) .. " is badly poisoned!"
  elseif status == "PSN" then
    text = nm(B, holder) .. "'s " .. B:abilityLabel(holder) .. " poisoned " .. nm(B, victim) .. "!"
  elseif status == "PAR" then
    text = nm(B, holder) .. "'s " .. B:abilityLabel(holder) .. " paralyzed " .. nm(B, victim) .. "!"
  elseif status == "BRN" then
    text = nm(B, holder) .. "'s " .. B:abilityLabel(holder) .. " burned " .. nm(B, victim) .. "!"
  else
    text = nm(B, holder) .. "'s " .. B:abilityLabel(holder) .. " made " .. nm(B, victim) .. " sleep!"
  end
  B:inflict(victim, status, { text = text, source = holder })
  if status ~= "SLP" then B.syncEffect = { status = status } end
  return true
end

-- ------------------------------------------------------------------
-- on damage (pokefirered/src/battle_util.c:1964 ABILITYEFFECT_ON_DAMAGE)
-- ------------------------------------------------------------------

local function contact(move)
  return move ~= nil and int(move.flags, 0) % 2 == 1
end

-- M_: the move context (user, target, move, moveType, mnum, noEffect,
-- targetDamaged).  Returns true when something happened.
function M.onDamage(B, M_)
  local user, target = M_.user, M_.target
  if not target or target == user or M_.noEffect or not M_.targetDamaged then return false end
  local ab = target.ability
  local mt = int(M_.moveType or (M_.move and M_.move.type), 0)
  if ab == "COLOR_CHANGE" then
    if M_.mnum ~= 165 and int(M_.move.power, 0) ~= 0 and not isType(target, mt)
        and int(target.mon.hp, 0) > 0 then
      setType(target, mt)
      B:emitAbility(target)
      B:say(nm(B, target) .. "'s COLOR CHANGE made it the " .. B:typeLabel(mt) .. " type!")
      return true
    end
    return false
  end
  if int(user.mon.hp, 0) <= 0 or not contact(M_.move) then return false end
  if ab == "ROUGH_SKIN" then
    local amt = floor(user.mon.maxHp / 16)
    if amt == 0 then amt = 1 end
    B:emitAbility(target)
    B:loseHp(user, amt)
    B:say(nm(B, user) .. " was hurt by " .. nm(B, target) .. "'s ROUGH SKIN!")
    M_:tryFaintUser()
    return true
  elseif ab == "EFFECT_SPORE" then
    if B:roll(0, 9) == 0 then
      local r
      repeat r = B:roll(0, 3) until r ~= 0
      local status = ({ "SLP", "PSN", "PAR" })[r]
      M.applyStatus(B, target, user, status, false, M_)
      return true
    end
  elseif ab == "POISON_POINT" or ab == "STATIC" or ab == "FLAME_BODY" then
    if B:roll(0, 2) == 0 then
      local status = (ab == "POISON_POINT" and "PSN") or (ab == "STATIC" and "PAR") or "BRN"
      M.applyStatus(B, target, user, status, false, M_)
      return true
    end
  elseif ab == "CUTE_CHARM" then
    if int(target.mon.hp, 0) > 0 and B:roll(0, 2) == 0 and user.ability ~= "OBLIVIOUS" then
      local ug, tg = user.mon.gender or "U", target.mon.gender or "U"
      if ug ~= tg and not user.infatuatedWith and ug ~= "U" and tg ~= "U" then
        user.infatuatedWith = target
        B:emitAbility(target)
        B:say(nm(B, target) .. "'s CUTE CHARM infatuated " .. nm(B, user) .. "!")
        return true
      end
    end
  end
  return false
end

-- ------------------------------------------------------------------
-- immunity cures (pokefirered/src/battle_util.c:2087 ABILITYEFFECT_IMMUNITY)
-- ------------------------------------------------------------------

function M.immunityCure(B)
  local any = false
  for _, b in ipairs(B:active()) do
    local ab = b.ability
    local s = Status.normalise(b.mon.status)
    local word, kind
    if ab == "IMMUNITY" and (s == "PSN" or s == "TOX") then word, kind = "poison", 1
    elseif ab == "OWN_TEMPO" and int(b.confusion, 0) > 0 then word, kind = "confusion", 2
    elseif ab == "LIMBER" and s == "PAR" then word, kind = "paralysis", 1
    elseif (ab == "INSOMNIA" or ab == "VITAL_SPIRIT") and s == "SLP" then
      b.nightmare = nil
      word, kind = "sleep", 1
    elseif ab == "WATER_VEIL" and s == "BRN" then word, kind = "burn", 1
    elseif ab == "MAGMA_ARMOR" and s == "FRZ" then word, kind = "ice", 1
    elseif ab == "OBLIVIOUS" and b.infatuatedWith then word, kind = "love", 3 end
    if kind then
      local text = nm(B, b) .. "'s " .. B:abilityLabel(b) .. " cured its " .. word .. " problem!"
      B:emitAbility(b)
      if kind == 1 then
        B:cure(b, text)
      elseif kind == 2 then
        b.confusion = nil
        B:emit("status", { slot = b.slot, side = b.side, confused = 0, text = text })
        B:say(text)
      else
        b.infatuatedWith = nil
        B:say(text)
      end
      any = true
    end
  end
  return any
end

-- pokefirered/src/battle_util.c:2185 ABILITYEFFECT_SYNCHRONIZE: a pending
-- status the move just inflicted on the holder is passed back to the victim.
function M.synchronize(B, M_, holder, victim)
  local pend = B.syncEffect
  if not pend or not holder or holder.ability ~= "SYNCHRONIZE" then return false end
  B.syncEffect = nil
  local status = pend.status
  if status == "TOX" then status = "PSN" end
  M.applyStatus(B, holder, victim, status, true, M_)
  return true
end

-- ------------------------------------------------------------------
-- escape (pokefirered/src/battle_main.c:3002 IsRunningFromBattleImpossible)
-- ------------------------------------------------------------------

-- Returns the blocking battler and its ability, or nil.
function M.escapeBlocker(B, b)
  for _, foe in ipairs(B:foes(b)) do
    local fab = foe.ability
    if fab == "SHADOW_TAG" then return foe, fab end
    if fab == "ARENA_TRAP" and b.ability ~= "LEVITATE" and not isType(b, Types.ID.FLYING) then
      return foe, fab
    end
  end
  -- pokefirered/src/battle_main.c:3036 (Magnet Pull traps a Steel type)
  if isType(b, Types.ID.STEEL) then
    for _, o in ipairs(B:active()) do
      if o ~= b and o.side ~= b.side and o.ability == "MAGNET_PULL" then return o, "MAGNET_PULL" end
    end
  end
  return nil
end

-- pokefirered/src/battle_script_commands.c:9197 (Natural Cure on switch-out).
-- The cart prints nothing; the `ability` event and the cleared status are the
-- whole of it.
function M.switchOut(B, b)
  if b and b.ability == "NATURAL_CURE" and Status.normalise(b.mon.status) then
    B:emitAbility(b)
    B:cure(b, nil)
    return true
  end
  return false
end

return M
