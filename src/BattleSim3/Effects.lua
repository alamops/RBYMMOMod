-- Gen 3 move effects: secondary effects, stat changes, and every status / setup
-- move handler, keyed by pret EFFECT_* number.
--
-- Port of engine src/core/game3/battle/effects/*.lua (secondary, status, stats,
-- setup, special, volatiles, healing, screens, hazards, weather) and
-- effect_ids.lua (1:1 pret include/constants/battle_move_effects.h numbering,
-- `SECONDARY` after-hit specs, `STAT_CHANGES`).  Each handler cites the pret
-- script or command it mirrors.
--
-- A handler receives the move context `C` built by Move.lua:
--   C.B (the battle), C.user, C.target (battlers), C.move (row), C.mnum,
--   C.effect, C.slot, and the methods C:accuracyCheck(mode, printFail),
--   C:attackAnimation(), C:fail(text?), C:isProtected(), C:tryFaintUser(),
--   C:tryFaintTarget().
-- and talks to the field through the battle's helper surface (B:say, B:emit,
-- B:heal, B:loseHp, B:inflict, B:cure, B:roll, B:foes, B:sideState, ...).
--
-- Every EFFECT_* 0..213 resolves: damaging effects go through Move.lua's hit
-- pipeline and reach `M.secondaryAfter`; every non-damaging effect has a handler
-- in `M.HANDLERS`; the five unused slots (96, 110, 131, 141, 163) and plain
-- EFFECT_HIT with no power say "But nothing happened!", as the cart's
-- placeholder script does.
--
-- Nothing here raises; no love, no engine modules, no mod facade.

local need = ...
local Types = need("BattleSim3/Types")
local Status = need("BattleSim3/Status")
local Abilities = need("BattleSim3/Abilities")
local Items = need("BattleSim3/Items")
local Field = need("BattleSim3/Field")
local Damage = need("BattleSim3/Damage")

local M = {}

local floor, max, min = math.floor, math.max, math.min

-- pret include/constants/battle_move_effects.h
M.E = {
  HIT = 0, SLEEP = 1, POISON_HIT = 2, ABSORB = 3, BURN_HIT = 4, FREEZE_HIT = 5,
  PARALYZE_HIT = 6, EXPLOSION = 7, DREAM_EATER = 8, MIRROR_MOVE = 9, ATTACK_UP = 10,
  DEFENSE_UP = 11, SPEED_UP = 12, SPECIAL_ATTACK_UP = 13, SPECIAL_DEFENSE_UP = 14,
  ACCURACY_UP = 15, EVASION_UP = 16, ALWAYS_HIT = 17, ATTACK_DOWN = 18, DEFENSE_DOWN = 19,
  SPEED_DOWN = 20, SPECIAL_ATTACK_DOWN = 21, SPECIAL_DEFENSE_DOWN = 22, ACCURACY_DOWN = 23,
  EVASION_DOWN = 24, HAZE = 25, BIDE = 26, RAMPAGE = 27, ROAR = 28, MULTI_HIT = 29,
  CONVERSION = 30, FLINCH_HIT = 31, RESTORE_HP = 32, TOXIC = 33, PAY_DAY = 34,
  LIGHT_SCREEN = 35, TRI_ATTACK = 36, REST = 37, OHKO = 38, RAZOR_WIND = 39,
  SUPER_FANG = 40, DRAGON_RAGE = 41, TRAP = 42, HIGH_CRITICAL = 43, DOUBLE_HIT = 44,
  RECOIL_IF_MISS = 45, MIST = 46, FOCUS_ENERGY = 47, RECOIL = 48, CONFUSE = 49,
  ATTACK_UP_2 = 50, DEFENSE_UP_2 = 51, SPEED_UP_2 = 52, SPECIAL_ATTACK_UP_2 = 53,
  SPECIAL_DEFENSE_UP_2 = 54, ACCURACY_UP_2 = 55, EVASION_UP_2 = 56, TRANSFORM = 57,
  ATTACK_DOWN_2 = 58, DEFENSE_DOWN_2 = 59, SPEED_DOWN_2 = 60, SPECIAL_ATTACK_DOWN_2 = 61,
  SPECIAL_DEFENSE_DOWN_2 = 62, ACCURACY_DOWN_2 = 63, EVASION_DOWN_2 = 64, REFLECT = 65,
  POISON = 66, PARALYZE = 67, ATTACK_DOWN_HIT = 68, DEFENSE_DOWN_HIT = 69,
  SPEED_DOWN_HIT = 70, SPECIAL_ATTACK_DOWN_HIT = 71, SPECIAL_DEFENSE_DOWN_HIT = 72,
  ACCURACY_DOWN_HIT = 73, EVASION_DOWN_HIT = 74, SKY_ATTACK = 75, CONFUSE_HIT = 76,
  TWINEEDLE = 77, VITAL_THROW = 78, SUBSTITUTE = 79, RECHARGE = 80, RAGE = 81, MIMIC = 82,
  METRONOME = 83, LEECH_SEED = 84, SPLASH = 85, DISABLE = 86, LEVEL_DAMAGE = 87,
  PSYWAVE = 88, COUNTER = 89, ENCORE = 90, PAIN_SPLIT = 91, SNORE = 92, CONVERSION_2 = 93,
  LOCK_ON = 94, SKETCH = 95, UNUSED_60 = 96, SLEEP_TALK = 97, DESTINY_BOND = 98,
  FLAIL = 99, SPITE = 100, FALSE_SWIPE = 101, HEAL_BELL = 102, QUICK_ATTACK = 103,
  TRIPLE_KICK = 104, THIEF = 105, MEAN_LOOK = 106, NIGHTMARE = 107, MINIMIZE = 108,
  CURSE = 109, UNUSED_6E = 110, PROTECT = 111, SPIKES = 112, FORESIGHT = 113,
  PERISH_SONG = 114, SANDSTORM = 115, ENDURE = 116, ROLLOUT = 117, SWAGGER = 118,
  FURY_CUTTER = 119, ATTRACT = 120, RETURN = 121, PRESENT = 122, FRUSTRATION = 123,
  SAFEGUARD = 124, THAW_HIT = 125, MAGNITUDE = 126, BATON_PASS = 127, PURSUIT = 128,
  RAPID_SPIN = 129, SONICBOOM = 130, UNUSED_83 = 131, MORNING_SUN = 132, SYNTHESIS = 133,
  MOONLIGHT = 134, HIDDEN_POWER = 135, RAIN_DANCE = 136, SUNNY_DAY = 137,
  DEFENSE_UP_HIT = 138, ATTACK_UP_HIT = 139, ALL_STATS_UP_HIT = 140, UNUSED_8D = 141,
  BELLY_DRUM = 142, PSYCH_UP = 143, MIRROR_COAT = 144, SKULL_BASH = 145, TWISTER = 146,
  EARTHQUAKE = 147, FUTURE_SIGHT = 148, GUST = 149, FLINCH_MINIMIZE_HIT = 150,
  SOLAR_BEAM = 151, THUNDER = 152, TELEPORT = 153, BEAT_UP = 154, SEMI_INVULNERABLE = 155,
  DEFENSE_CURL = 156, SOFTBOILED = 157, FAKE_OUT = 158, UPROAR = 159, STOCKPILE = 160,
  SPIT_UP = 161, SWALLOW = 162, UNUSED_A3 = 163, HAIL = 164, TORMENT = 165, FLATTER = 166,
  WILL_O_WISP = 167, MEMENTO = 168, FACADE = 169, FOCUS_PUNCH = 170, SMELLINGSALT = 171,
  FOLLOW_ME = 172, NATURE_POWER = 173, CHARGE = 174, TAUNT = 175, HELPING_HAND = 176,
  TRICK = 177, ROLE_PLAY = 178, WISH = 179, ASSIST = 180, INGRAIN = 181, SUPERPOWER = 182,
  MAGIC_COAT = 183, RECYCLE = 184, REVENGE = 185, BRICK_BREAK = 186, YAWN = 187,
  KNOCK_OFF = 188, ENDEAVOR = 189, ERUPTION = 190, SKILL_SWAP = 191, IMPRISON = 192,
  REFRESH = 193, GRUDGE = 194, SNATCH = 195, LOW_KICK = 196, SECRET_POWER = 197,
  DOUBLE_EDGE = 198, TEETER_DANCE = 199, BLAZE_KICK = 200, MUD_SPORT = 201,
  POISON_FANG = 202, WEATHER_BALL = 203, OVERHEAT = 204, TICKLE = 205, COSMIC_POWER = 206,
  SKY_UPPERCUT = 207, BULK_UP = 208, POISON_TAIL = 209, WATER_SPORT = 210,
  CALM_MIND = 211, DRAGON_DANCE = 212, CAMOUFLAGE = 213,
}
local E = M.E
M.MAX = 213

-- After-hit secondary effects (pokefirered/data/battle_scripts_1.s:321; engine
-- effect_ids.lua SECONDARY).
M.SECONDARY = {
  [2] = { eff = "POISON" }, [4] = { eff = "BURN" }, [5] = { eff = "FREEZE" },
  [6] = { eff = "PARALYSIS" }, [31] = { eff = "FLINCH" }, [34] = { eff = "PAYDAY" },
  [36] = { eff = "TRI_ATTACK" }, [42] = { eff = "WRAP" },
  [48] = { eff = "RECOIL_25", user = true, certain = true },
  [68] = { eff = "ATK_MINUS_1" }, [69] = { eff = "DEF_MINUS_1" }, [70] = { eff = "SPD_MINUS_1" },
  [71] = { eff = "SP_ATK_MINUS_1" }, [72] = { eff = "SP_DEF_MINUS_1" },
  [73] = { eff = "ACC_MINUS_1" }, [74] = { eff = "EVS_MINUS_1" },
  [76] = { eff = "CONFUSION" }, [77] = { eff = "POISON" },
  [80] = { eff = "RECHARGE", user = true, certain = true },
  [92] = { eff = "FLINCH" }, [105] = { eff = "STEAL_ITEM" }, [125] = { eff = "BURN" },
  [129] = { eff = "RAPIDSPIN", user = true, certain = true },
  [138] = { eff = "DEF_PLUS_1", user = true }, [139] = { eff = "ATK_PLUS_1", user = true },
  [140] = { eff = "ALL_STATS_UP", user = true }, [146] = { eff = "FLINCH" },
  [150] = { eff = "FLINCH" }, [152] = { eff = "PARALYSIS" },
  [158] = { eff = "FLINCH", certain = true }, [159] = { eff = "UPROAR", user = true },
  [171] = { eff = "REMOVE_PARALYSIS", certain = true },
  [182] = { eff = "ATK_DEF_DOWN", user = true, certain = true }, [188] = { eff = "KNOCK_OFF" },
  [198] = { eff = "RECOIL_33", user = true, certain = true }, [200] = { eff = "BURN" },
  [202] = { eff = "TOXIC" }, [204] = { eff = "SP_ATK_TWO_DOWN", user = true, certain = true },
  [209] = { eff = "POISON" },
}

-- Stat effects the generic handler resolves (self = user, else target).
M.STAT_CHANGES = {
  [10] = { true, "atk", 1 }, [11] = { true, "def", 1 }, [12] = { true, "spe", 1 },
  [13] = { true, "spa", 1 }, [14] = { true, "spd", 1 }, [15] = { true, "acc", 1 },
  [16] = { true, "eva", 1 },
  [18] = { false, "atk", -1 }, [19] = { false, "def", -1 }, [20] = { false, "spe", -1 },
  [21] = { false, "spa", -1 }, [22] = { false, "spd", -1 }, [23] = { false, "acc", -1 },
  [24] = { false, "eva", -1 },
  [50] = { true, "atk", 2 }, [51] = { true, "def", 2 }, [52] = { true, "spe", 2 },
  [53] = { true, "spa", 2 }, [54] = { true, "spd", 2 }, [55] = { true, "acc", 2 },
  [56] = { true, "eva", 2 },
  [58] = { false, "atk", -2 }, [59] = { false, "def", -2 }, [60] = { false, "spe", -2 },
  [61] = { false, "spa", -2 }, [62] = { false, "spd", -2 }, [63] = { false, "acc", -2 },
  [64] = { false, "eva", -2 },
}

-- pokefirered/src/battle_script_commands.c:707 sMovesForbiddenToCopy (the -1
-- sentinel splits the Metronome list from Mimic's shorter one).
M.FORBIDDEN_TO_COPY = {
  118, 165, 166, 102, -1, 68, 243, 182, 197, 203, 194, 214, 168, 266, 289, 270, 343, 271, 264,
}

function M.forbidden(num, stopAtSentinel)
  for _, m in ipairs(M.FORBIDDEN_TO_COPY) do
    if m == -1 then
      if stopAtSentinel then return false end
    elseif m == num then
      return true
    end
  end
  return false
end

-- Move numbers the handlers branch on (pret include/constants/moves.h).
local MOVE = {
  STRUGGLE = 165, SKETCH = 166, ENCORE = 227, MIRROR_MOVE = 119, HEAL_BELL = 215,
  DOOM_DESIRE = 353, PROTECT = 182, DETECT = 197, ENDURE = 203,
}
M.MOVE = MOVE

local STAT_LABEL = {
  atk = "ATTACK", def = "DEFENSE", spe = "SPEED", spa = "SP. ATK", spd = "SP. DEF",
  acc = "ACCURACY", eva = "EVASIVENESS",
}
M.STAT_LABEL = STAT_LABEL
local STAT_ORDER = { "atk", "def", "spe", "spa", "spd", "acc", "eva" }

local function int(value, fallback)
  local n = tonumber(value)
  if not n or n ~= n then return fallback end
  return floor(n)
end

local function isType(b, t) return b ~= nil and (b.type1 == t or b.type2 == t) end

local function nm(B, b) return B:nameOf(b) end

-- ------------------------------------------------------------------
-- stat changes (pokefirered/src/battle_script_commands.c:6655 ChangeStatBuffs)
-- ------------------------------------------------------------------

-- flags: user (the change is the user's own), certain (MOVE_EFFECT_CERTAIN),
--        curse (Curse's self-drop), allowPtr (a primary move: print why it
--        failed), noMsg, noEvent
-- Returns "worked" | "blocked" | "wont".
function M.changeStat(B, b, stat, delta, flags)
  flags = flags or {}
  if not b or not b.stages then return "blocked" end
  local cur = b.stages[stat] or 0
  if delta < 0 then
    local side = B:sideState(b.side)
    local ab = b.ability
    if int(side.mistTurns, 0) > 0 and not flags.certain and not flags.curse then
      if flags.allowPtr and not b.statLoweredMsg then
        b.statLoweredMsg = true
        B:say(nm(B, b) .. " is protected by MIST!")
      end
      return "blocked"
    end
    if (ab == "CLEAR_BODY" or ab == "WHITE_SMOKE") and not flags.certain and not flags.curse then
      if flags.allowPtr and not b.statLoweredMsg then
        b.statLoweredMsg = true
        B:emitAbility(b)
        B:say(nm(B, b) .. "'s " .. B:abilityLabel(b) .. " prevents stat loss!")
      end
      return "blocked"
    end
    if ((ab == "KEEN_EYE" and stat == "acc") or (ab == "HYPER_CUTTER" and stat == "atk"))
        and not flags.certain then
      if flags.allowPtr then
        B:emitAbility(b)
        B:say(nm(B, b) .. "'s " .. B:abilityLabel(b) .. " prevents " .. STAT_LABEL[stat] .. " loss!")
      end
      return "blocked"
    end
    if ab == "SHIELD_DUST" and not flags.allowPtr and not flags.user then
      return "blocked"
    end
    if cur <= -6 then
      if not flags.noMsg then B:say(nm(B, b) .. "'s " .. STAT_LABEL[stat] .. " won't go lower!") end
      return "wont"
    end
  else
    if cur >= 6 then
      if not flags.noMsg then B:say(nm(B, b) .. "'s " .. STAT_LABEL[stat] .. " won't go higher!") end
      return "wont"
    end
  end
  local nxt = cur + delta
  if nxt < -6 then nxt = -6 elseif nxt > 6 then nxt = 6 end
  b.stages[stat] = nxt
  local text
  if delta >= 2 then text = " sharply rose!"
  elseif delta >= 1 then text = " rose!"
  elseif delta <= -2 then text = " harshly fell!"
  else text = " fell!" end
  text = nm(B, b) .. "'s " .. STAT_LABEL[stat] .. text
  if not flags.noEvent then
    B:emit("stat", { slot = b.slot, side = b.side, stat = stat, stage = nxt, delta = nxt - cur,
                     text = text })
  end
  if not flags.noMsg then B:say(text) end
  return "worked"
end

-- ------------------------------------------------------------------
-- secondary effects (pokefirered/src/battle_script_commands.c:2110 SetMoveEffect)
-- ------------------------------------------------------------------

local EFFECT_TO_STATUS = {
  SLEEP = "SLP", POISON = "PSN", BURN = "BRN", FREEZE = "FRZ", PARALYSIS = "PAR", TOXIC = "TOX",
}

local STATUS_EFFECT_RANK = {
  SLEEP = 1, POISON = 2, BURN = 3, FREEZE = 4, PARALYSIS = 5, TOXIC = 6, CONFUSION = 7,
  FLINCH = 8, TRI_ATTACK = 9,
}

local STAT_EFFECTS = {
  ATK_PLUS_1 = { "atk", 1 }, DEF_PLUS_1 = { "def", 1 }, SPD_PLUS_1 = { "spe", 1 },
  SP_ATK_PLUS_1 = { "spa", 1 }, SP_DEF_PLUS_1 = { "spd", 1 }, ACC_PLUS_1 = { "acc", 1 },
  EVS_PLUS_1 = { "eva", 1 },
  ATK_MINUS_1 = { "atk", -1 }, DEF_MINUS_1 = { "def", -1 }, SPD_MINUS_1 = { "spe", -1 },
  SP_ATK_MINUS_1 = { "spa", -1 }, SP_DEF_MINUS_1 = { "spd", -1 }, ACC_MINUS_1 = { "acc", -1 },
  EVS_MINUS_1 = { "eva", -1 },
}

-- src/battle_message.c:1042 (partial-trap sentences, by move number)
local TRAP_TEXT = {
  [20] = "%s was squeezed by %s!", [35] = "%s was wrapped by %s!",
  [83] = "%s was trapped in the vortex!", [128] = "%s clamped %s!",
  [250] = "%s was trapped in the vortex!", [328] = "%s was trapped by SAND TOMB!",
}

local function applyStatusEffect(C, eff, primary, certain, effBattler)
  local B = C.B
  local status = EFFECT_TO_STATUS[eff]
  local ab = effBattler.ability
  local strict = primary or certain
  local function prevent(text)
    B:emitAbility(effBattler)
    B:say(text)
    return false
  end
  if status == "PSN" or status == "TOX" then
    if ab == "IMMUNITY" and strict then
      return prevent(nm(B, effBattler) .. "'s IMMUNITY prevents poisoning!")
    end
  elseif status == "BRN" then
    if ab == "WATER_VEIL" and strict then
      return prevent(nm(B, effBattler) .. "'s WATER VEIL prevents burns!")
    end
  elseif status == "PAR" then
    if ab == "LIMBER" and strict then
      return prevent(nm(B, effBattler) .. "'s LIMBER prevents paralysis!")
    end
  end
  if not B:canInflict(effBattler, status, { ignoreSafeguard = true }) then
    if status == "TOX" and not Status.normalise(effBattler.mon.status)
        and (isType(effBattler, Types.ID.POISON) or isType(effBattler, Types.ID.STEEL)) then
      C.doesntAffect = true
    end
    return false
  end
  B:inflict(effBattler, status, { source = C.user })
  -- pokefirered/src/battle_script_commands.c:2376 (Synchronize bookkeeping)
  if status == "PSN" or status == "TOX" or status == "PAR" or status == "BRN" then
    B.syncEffect = { status = status }
  end
  return true
end

function M.set(C, eff, primary, certain, affectsUser)
  local B = C.B
  local user, target = C.user, C.target
  local effBattler = affectsUser and user or target
  local rank = STATUS_EFFECT_RANK[eff]
  if not effBattler then return false end
  if rank and rank <= 9 and not primary and effBattler.ability == "SHIELD_DUST" and not affectsUser then
    return false
  end
  if rank and rank <= 7 and not primary and not affectsUser then
    if int(B:sideState(effBattler.side).safeguardTurns, 0) > 0 then return false end
  end
  if int(effBattler.mon.hp, 0) <= 0 and eff ~= "PAYDAY" and eff ~= "STEAL_ITEM" then return false end
  if not affectsUser and int(effBattler.substituteHP, 0) > 0 then return false end

  if EFFECT_TO_STATUS[eff] then
    return applyStatusEffect(C, eff, primary, certain, effBattler)
  end

  if eff == "CONFUSION" then
    if effBattler.ability == "OWN_TEMPO" or int(effBattler.confusion, 0) > 0 then return false end
    effBattler.confusion = B:roll(0, 3) + 2
    local text = nm(B, effBattler) .. " became confused!"
    B:emit("status", { slot = effBattler.slot, side = effBattler.side, confused = 1, text = text })
    B:say(text)
    return true
  elseif eff == "FLINCH" then
    if effBattler.ability == "INNER_FOCUS" then
      if primary or certain then
        B:emitAbility(effBattler)
        B:say(nm(B, effBattler) .. "'s INNER FOCUS prevents flinching!")
      end
      return false
    end
    if not effBattler.movedThisTurn then effBattler.flinched = true end
    return true
  elseif eff == "UPROAR" then
    if int(effBattler.uproarTurns, 0) > 0 then return false end
    effBattler.lockedNum = C.mnum
    effBattler.lockedSlot = C.slot
    effBattler.uproarTurns = B:roll(0, 3) + 2
    B:say(nm(B, effBattler) .. " caused an UPROAR!")
    return true
  elseif eff == "PAYDAY" then
    -- battle_script_commands.c:2455: the coins are a link-free player bonus; a
    -- mediated fight says the line and pays nothing (sheet doc §6).
    B:say("Coins scattered everywhere!")
    return true
  elseif eff == "TRI_ATTACK" then
    if Status.normalise(effBattler.mon.status) then return false end
    local r = B:roll(0, 2)
    local pick = ({ [0] = "BURN", [1] = "FREEZE", [2] = "PARALYSIS" })[r]
    return M.set(C, pick, false, false, false)
  elseif eff == "WRAP" then
    if int(effBattler.trapTurns, 0) > 0 then return false end
    -- pokefirered/src/battle_script_commands.c:2490 ((Random() & 3) + 3)
    effBattler.trapTurns = B:roll(0, 3) + 3
    effBattler.trapMove = C.mnum
    effBattler.trapSource = user
    local fmt = TRAP_TEXT[C.mnum] or "%s was trapped by %s!"
    B:say(fmt:format(nm(B, effBattler), nm(B, user)))
    return true
  elseif eff == "RECOIL_25" or eff == "RECOIL_33" then
    local div = (eff == "RECOIL_25") and 4 or 3
    local dmg = floor(int(C.hpDealt, 0) / div)
    if dmg == 0 then dmg = 1 end
    if C.mnum ~= MOVE.STRUGGLE and user.ability == "ROCK_HEAD" then return false end
    B:loseHp(user, dmg)
    B:say(nm(B, user) .. " is hit with recoil!")
    C.checkUserFaint = true
    return true
  elseif STAT_EFFECTS[eff] then
    local spec = STAT_EFFECTS[eff]
    local res = M.changeStat(B, effBattler, spec[1], spec[2], {
      user = affectsUser, certain = certain, allowPtr = false,
    })
    return res == "worked"
  elseif eff == "RECHARGE" then
    effBattler.rechargeTurns = 2
    effBattler.mustRecharge = true
    return true
  elseif eff == "STEAL_ITEM" then
    -- src/battle_script_commands.c:2610 (a mediated fight is a link fight: either
    -- side may steal).  A mon whose item was knocked off may not (:2628, pret
    -- knockedOffMons): it still owns that item after the fight (Knock Off keeps
    -- `mon.knockedOff` for the `holding` writeback), so a stolen item would
    -- vanish there.  The cart skips this check only in link fights; this one
    -- writes items back like a non-link fight, so the check stands.
    if user.mon.knockedOff then return false end
    local tItem = int(target.mon.heldItem, 0)
    if tItem ~= 0 and target.ability == "STICKY_HOLD" then
      B:emitAbility(target)
      B:say(nm(B, target) .. "'s STICKY HOLD made " .. C:moveName() .. " ineffective!")
      return false
    end
    if int(user.mon.heldItem, 0) ~= 0 or tItem == 0 or tItem == Items.ITEM_ENIGMA_BERRY
        or Items.isMail(tItem) then
      return false
    end
    local row = Items.rowOf(target)
    local lbl = B:itemLabel(target)
    Items.give(user, row)
    Items.give(target, nil)
    Items.heldEvent(B, user, tItem, lbl)
    Items.heldEvent(B, target, tItem, lbl)
    B:say(nm(B, user) .. " stole " .. nm(B, target) .. "'s " .. lbl .. "!")
    return true
  elseif eff == "ALL_STATS_UP" then
    local order = { "atk", "def", "spe", "spa", "spd" }
    local any = false
    for _, s in ipairs(order) do
      if user.stages[s] < 6 then any = true end
    end
    if not any then return false end
    for _, s in ipairs(order) do
      if user.stages[s] < 6 then M.changeStat(B, user, s, 1, { user = true }) end
    end
    return true
  elseif eff == "RAPIDSPIN" then
    -- pokefirered/src/battle_script_commands.c:8435
    local did = false
    if int(user.trapTurns, 0) > 0 then
      local src = user.trapSource
      B:say(nm(B, user) .. " got free of " .. (src and nm(B, src) or "the foe") .. "'s "
        .. B:moveLabelByNum(user.trapMove) .. "!")
      user.trapTurns, user.trapMove, user.trapSource = nil, nil, nil
      did = true
    end
    if user.seededBy then
      user.seededBy = nil
      B:say(nm(B, user) .. " was freed from LEECH SEED!")
      did = true
    end
    local side = B:sideState(user.side)
    if int(side.spikes, 0) > 0 then
      side.spikes = 0
      B:say(nm(B, user) .. " blew away SPIKES!")
      did = true
    end
    return did
  elseif eff == "REMOVE_PARALYSIS" then
    if Status.normalise(target.mon.status) ~= "PAR" then return false end
    B:cure(target, nm(B, target) .. " was cured of paralysis.")
    return true
  elseif eff == "ATK_DEF_DOWN" then
    M.changeStat(B, user, "atk", -1, { user = true, certain = true, allowPtr = true, noMsg = user.stages.atk <= -6 })
    M.changeStat(B, user, "def", -1, { user = true, certain = true, allowPtr = true, noMsg = user.stages.def <= -6 })
    return true
  elseif eff == "SP_ATK_TWO_DOWN" then
    if user.stages.spa > -6 then
      M.changeStat(B, user, "spa", -2, { user = true, certain = true, allowPtr = true })
    end
    return true
  elseif eff == "THRASH" then
    if int(effBattler.rampageTurns, 0) > 0 then return false end
    effBattler.lockedNum = C.mnum
    effBattler.lockedSlot = C.slot
    effBattler.rampageTurns = B:roll(0, 1) + 2
    return true
  elseif eff == "KNOCK_OFF" then
    local tItem = int(effBattler.mon.heldItem, 0)
    if effBattler.ability == "STICKY_HOLD" then
      if tItem == 0 then return false end
      B:emitAbility(effBattler)
      B:say(nm(B, effBattler) .. "'s STICKY HOLD made " .. C:moveName() .. " ineffective!")
      return false
    end
    if tItem == 0 then return false end
    -- pokefirered/src/battle_script_commands.c:2730: gone for the rest of the
    -- battle, still held in the party afterwards (`holding` says so).
    local lbl = B:itemLabel(effBattler)
    effBattler.mon.knockedOff = tItem
    Items.give(effBattler, nil)
    Items.heldEvent(B, effBattler, tItem, lbl)
    B:say(nm(B, user) .. " knocked off " .. nm(B, effBattler) .. "'s " .. lbl .. "!")
    return true
  end
  return false
end

-- pokefirered/src/battle_script_commands.c:2774 Cmd_seteffectwithchance.
-- `Random() % 100 <= chance`: the cart's off-by-one, so a 10% effect lands 11%.
function M.withChance(C, eff, certainFlag, affectsUser)
  if not eff then return false end
  if C.noEffect then return false end
  local chance = int(C.move and C.move.chance, 0)
  if C.user.ability == "SERENE_GRACE" then chance = chance * 2 end
  if certainFlag then
    return M.set(C, eff, false, true, affectsUser)
  end
  if C.B:roll(0, 99) <= chance then
    return M.set(C, eff, false, chance >= 100, affectsUser)
  end
  return false
end

-- engine effects/hit.lua secondary_after
function M.secondaryAfter(C)
  if C.noEffect then return end
  local eff = C.effect
  local spec = M.SECONDARY[eff]
  if eff == E.SMELLINGSALT and C.hitSubstitute then spec = nil end
  if eff == E.SECRET_POWER then
    spec = { eff = Field.SECRET_POWER_EFFECT[C.B.terrain] or "PARALYSIS" }
  end
  if C.extraEffect then spec = C.extraEffect end
  if spec then
    M.withChance(C, spec.eff, spec.certain, spec.user)
  end
  if eff == E.RAMPAGE and C.startRampage then
    M.set(C, "THRASH", false, true, true)
  end
end

-- ------------------------------------------------------------------
-- handler helpers
-- ------------------------------------------------------------------

local function sub(b) return int(b and b.substituteHP, 0) > 0 end

local function safeguarded(C, b)
  if int(C.B:sideState(b.side).safeguardTurns, 0) > 0 then
    C.B:say(nm(C.B, b) .. " is protected by SAFEGUARD!")
    return true
  end
  return false
end

local function notAffected(C, b)
  C.noEffect = true
  C.B:say("It doesn't affect " .. nm(C.B, b) .. "...")
end

local function primary(C, eff)
  return M.set(C, eff, true, false, false)
end

-- pokefirered/src/battle_script_commands.c:6546
local function cantMakeAsleep(C, b)
  local B = C.B
  local ab = b.ability
  if B:uproarActive() and ab ~= "SOUNDPROOF" then
    B:say("But the UPROAR kept " .. nm(B, b) .. " awake!")
    return true
  end
  if ab == "INSOMNIA" or ab == "VITAL_SPIRIT" then
    B:emitAbility(b)
    B:say(nm(B, b) .. " stayed awake using its " .. B:abilityLabel(b) .. "!")
    return true
  end
  return false
end

-- pokefirered/data/battle_scripts_1.s:491 (BattleScript_EffectStatUp)
local function statUp(C, stat, delta)
  local B, user = C.B, C.user
  if user.stages[stat] >= 6 then
    B:say(nm(B, user) .. "'s " .. STAT_LABEL[stat] .. " won't go higher!")
    C.failed = true
    return
  end
  C:attackAnimation()
  M.changeStat(B, user, stat, delta, { user = true, allowPtr = true })
end

-- pokefirered/data/battle_scripts_1.s:536 (BattleScript_EffectStatDown)
local function statDown(C, stat, delta)
  local B, t = C.B, C.target
  if sub(t) then return C:fail() end
  if not C:accuracyCheck("normal", true) then return end
  local side = B:sideState(t.side)
  local ab = t.ability
  local blocked = int(side.mistTurns, 0) > 0 or ab == "CLEAR_BODY" or ab == "WHITE_SMOKE"
    or (ab == "KEEN_EYE" and stat == "acc") or (ab == "HYPER_CUTTER" and stat == "atk")
  if not blocked and t.stages[stat] > -6 then C:attackAnimation() end
  M.changeStat(B, t, stat, delta, { allowPtr = true })
end

local function multiUp(C, stats)
  local B, user = C.B, C.user
  local any = false
  for _, s in ipairs(stats) do
    if user.stages[s] < 6 then any = true end
  end
  if not any then
    C.failed = true
    B:say(nm(B, user) .. "'s stats won't go any higher!")
    return
  end
  C:attackAnimation()
  for _, s in ipairs(stats) do
    if user.stages[s] < 6 then
      M.changeStat(B, user, s, 1, { user = true, allowPtr = true })
    end
  end
end

-- engine effects/stats.lua swagger_like (pokefirered/data/battle_scripts_1.s:1604)
local function swaggerLike(C, stat, delta)
  local B, t = C.B, C.target
  if sub(t) then
    C.missed = true
    B:say(nm(B, C.user) .. "'s attack missed!")
    return
  end
  if not C:accuracyCheck("normal", true) then return end
  if int(t.confusion, 0) > 0 and t.stages[stat] >= 6 then return C:fail() end
  C:attackAnimation()
  if t.stages[stat] < 6 then
    M.changeStat(B, t, stat, delta, { allowPtr = true })
  end
  if t.ability == "OWN_TEMPO" then
    B:emitAbility(t)
    B:say(nm(B, t) .. "'s OWN TEMPO prevents confusion!")
    return
  end
  if int(B:sideState(t.side).safeguardTurns, 0) > 0 then
    B:say(nm(B, t) .. " is protected by SAFEGUARD!")
    return
  end
  M.set(C, "CONFUSION", true, false, false)
end

-- pokefirered/src/battle_script_commands.c:6220 (Protect / Detect / Endure)
local function protectLike(C, onSuccess)
  local B, user = C.B, C.user
  local last = user.lastResultingNum
  if last ~= MOVE.PROTECT and last ~= MOVE.DETECT and last ~= MOVE.ENDURE then
    user.protectStreak = 0
  end
  local streak = int(user.protectStreak, 0)
  local ok = user.turnOrder ~= B:battlerCount()
  if ok and streak > 0 then
    local denom = 2 ^ min(streak, 3)
    ok = B:roll(0, denom - 1) == 0
  end
  if not ok then
    user.protectStreak = 0
    return C:fail()
  end
  user.protectStreak = streak + 1
  C:attackAnimation()
  onSuccess(user)
end

-- The weather moves (pokefirered/src/battle_script_commands.c:6399).
local function setWeather(C, kind, text)
  local B = C.B
  if B.field.weather == kind then return C:fail() end
  B.field.weather, B.field.weatherTurns = kind, Field.WEATHER_TURNS
  C:attackAnimation()
  B:emit("weather", { text = kind, amount = 1, slot = C.user.slot, side = C.user.side })
  B:say(text)
end

-- The last move a battler used (pret gLastMoves), as a move row the user can
-- read, or nil.
local function lastMoveRow(B, b)
  local num = b and b.lastMoveNum
  if not num or num == 0 then return nil end
  return B:moveRowByNum(num, b), num
end

-- ------------------------------------------------------------------
-- the handlers, by effect number
-- ------------------------------------------------------------------

local H = {}
M.HANDLERS = H

-- pokefirered/data/battle_scripts_1.s:287
H[E.SLEEP] = function(C)
  local B, t = C.B, C.target
  if sub(t) then return C:fail() end
  if Status.normalise(t.mon.status) == "SLP" then
    return B:say(nm(B, t) .. " is already asleep!")
  end
  if cantMakeAsleep(C, t) then return end
  if Status.normalise(t.mon.status) then return C:fail() end
  if not C:accuracyCheck("normal", true) then return end
  if safeguarded(C, t) then return end
  C:attackAnimation()
  primary(C, "SLEEP")
end

-- pokefirered/data/battle_scripts_1.s:984
H[E.POISON] = function(C)
  local B, t = C.B, C.target
  if t.ability == "IMMUNITY" then
    B:emitAbility(t)
    return B:say(nm(B, t) .. "'s IMMUNITY prevents poisoning!")
  end
  if sub(t) then return C:fail() end
  local s = Status.normalise(t.mon.status)
  if s == "PSN" or s == "TOX" then return B:say(nm(B, t) .. " is already poisoned.") end
  if isType(t, Types.ID.POISON) or isType(t, Types.ID.STEEL) then return notAffected(C, t) end
  if s then return C:fail() end
  if not C:accuracyCheck("normal", true) then return end
  if safeguarded(C, t) then return end
  C:attackAnimation()
  primary(C, "POISON")
end

-- pokefirered/data/battle_scripts_1.s:687
H[E.TOXIC] = function(C)
  local B, t = C.B, C.target
  if t.ability == "IMMUNITY" then
    B:emitAbility(t)
    return B:say(nm(B, t) .. "'s IMMUNITY prevents poisoning!")
  end
  if sub(t) then return C:fail() end
  local s = Status.normalise(t.mon.status)
  if s == "PSN" or s == "TOX" then return B:say(nm(B, t) .. " is already poisoned.") end
  if s then return C:fail() end
  if isType(t, Types.ID.POISON) or isType(t, Types.ID.STEEL) then return notAffected(C, t) end
  if not C:accuracyCheck("normal", true) then return end
  if safeguarded(C, t) then return end
  C:attackAnimation()
  primary(C, "TOXIC")
end

-- pokefirered/data/battle_scripts_1.s:1005
H[E.PARALYZE] = function(C)
  local B, t = C.B, C.target
  if t.ability == "LIMBER" then
    B:emitAbility(t)
    return B:say(nm(B, t) .. "'s LIMBER prevents paralysis!")
  end
  if sub(t) then return C:fail() end
  local mt = int(C.move.type, 0)
  local _, flags = Types.typeCalc(B.typeTable, mt, t.type1, t.type2, nil, t.identified)
  if flags.immune or (t.ability == "LEVITATE" and mt == Types.ID.GROUND) then
    return notAffected(C, t)
  end
  local s = Status.normalise(t.mon.status)
  if s == "PAR" then return B:say(nm(B, t) .. " is already paralyzed!") end
  if s then return C:fail() end
  if not C:accuracyCheck("normal", true) then return end
  if safeguarded(C, t) then return end
  C:attackAnimation()
  primary(C, "PARALYSIS")
end

-- pokefirered/data/battle_scripts_1.s:2170
H[E.WILL_O_WISP] = function(C)
  local B, t = C.B, C.target
  if sub(t) then return C:fail() end
  local s = Status.normalise(t.mon.status)
  if s == "BRN" then return B:say(nm(B, t) .. " already has a burn.") end
  if isType(t, Types.ID.FIRE) then return notAffected(C, t) end
  if t.ability == "WATER_VEIL" then
    B:emitAbility(t)
    return B:say(nm(B, t) .. "'s WATER VEIL prevents burns!")
  end
  if s then return C:fail() end
  if not C:accuracyCheck("normal", true) then return end
  if safeguarded(C, t) then return end
  C:attackAnimation()
  primary(C, "BURN")
end

-- The generic stat moves (EXP_STAT_FROM_EFFECT) over every stat effect id.
for id, spec in pairs(M.STAT_CHANGES) do
  if spec[1] then
    H[id] = function(C) statUp(C, spec[2], spec[3]) end
  else
    H[id] = function(C) statDown(C, spec[2], spec[3]) end
  end
end

-- pokefirered/data/battle_scripts_1.s:1472
H[E.MINIMIZE] = function(C)
  C.user.minimized = true
  statUp(C, "eva", 1)
end

-- pokefirered/data/battle_scripts_1.s:2010
H[E.DEFENSE_CURL] = function(C)
  C.user.defenseCurl = true
  statUp(C, "def", 1)
end

H[E.CALM_MIND] = function(C) multiUp(C, { "spa", "spd" }) end
H[E.BULK_UP] = function(C) multiUp(C, { "atk", "def" }) end
H[E.DRAGON_DANCE] = function(C) multiUp(C, { "atk", "spe" }) end
H[E.COSMIC_POWER] = function(C) multiUp(C, { "def", "spd" }) end

-- pokefirered/data/battle_scripts_1.s:2644
H[E.TICKLE] = function(C)
  local B, t = C.B, C.target
  if t.stages.atk <= -6 and t.stages.def <= -6 then
    C.failed = true
    return B:say(nm(B, t) .. "'s stats won't go any lower!")
  end
  if not C:accuracyCheck("normal", true) then return end
  C:attackAnimation()
  M.changeStat(B, t, "atk", -1, { allowPtr = true, noMsg = t.stages.atk <= -6 })
  M.changeStat(B, t, "def", -1, { allowPtr = true, noMsg = t.stages.def <= -6 })
end

H[E.SWAGGER] = function(C) swaggerLike(C, "atk", 2) end
H[E.FLATTER] = function(C) swaggerLike(C, "spa", 1) end

-- pokefirered/src/battle_script_commands.c:8423
H[E.PSYCH_UP] = function(C)
  local t = C.target
  if not t or not t.stages then return C:fail() end
  for _, s in ipairs(STAT_ORDER) do C.user.stages[s] = t.stages[s] or 0 end
  C:attackAnimation()
  C.B:say(nm(C.B, C.user) .. " copied " .. nm(C.B, t) .. "'s stat changes!")
end

-- pokefirered/src/battle_script_commands.c:6568
H[E.STOCKPILE] = function(C)
  local n = int(C.user.stockpile, 0)
  if n >= 3 then
    C.failed = true
    return C.B:say(nm(C.B, C.user) .. " can't STOCKPILE any more!")
  end
  C.user.stockpile = n + 1
  C:attackAnimation()
  C.B:say(nm(C.B, C.user) .. " STOCKPILED " .. (n + 1) .. "!")
end

-- pokefirered/src/battle_script_commands.c:8709
H[E.CHARGE] = function(C)
  C.user.charged = 2
  C:attackAnimation()
  C.B:say(nm(C.B, C.user) .. " began charging power!")
end

-- pokefirered/data/battle_scripts_1.s:2199
H[E.MEMENTO] = function(C)
  local B, user, t = C.B, C.user, C.target
  local protected = C:isProtected()
  if not protected and t.stages.atk <= -6 and t.stages.spa <= -6 then return C:fail() end
  B:setHp(user, 0)
  if protected then
    B:say(nm(B, t) .. " protected itself!")
  else
    C:attackAnimation()
    if sub(t) then
      B:say("But it had no effect!")
    else
      M.changeStat(B, t, "atk", -2, { allowPtr = true, noMsg = t.stages.atk <= -6 })
      M.changeStat(B, t, "spa", -2, { allowPtr = true, noMsg = t.stages.spa <= -6 })
    end
  end
  C.checkUserFaint = true
  C:tryFaintUser()
end

-- pokefirered/src/battle_script_commands.c:8266
H[E.SAFEGUARD] = function(C)
  local side = C.B:sideState(C.user.side)
  if int(side.safeguardTurns, 0) > 0 then return C:fail() end
  side.safeguardTurns = Field.SAFEGUARD_TURNS
  C:attackAnimation()
  C.B:say(nm(C.B, C.user) .. "'s party is covered by a veil!")
end

-- pokefirered/src/battle_script_commands.c:6415 / :7082
local function screen(C, key, what)
  local B = C.B
  local side = B:sideState(C.user.side)
  if int(side[key], 0) > 0 then return C:fail() end
  side[key] = Field.SCREEN_TURNS
  C:attackAnimation()
  local little = B.double and B:countStandingOnSide(C.user.side) >= 2
  B:say(C:moveName() .. " raised " .. what .. (little and " a little!" or "!"))
end
H[E.REFLECT] = function(C) screen(C, "reflectTurns", "DEFENSE") end
H[E.LIGHT_SCREEN] = function(C) screen(C, "lightScreenTurns", "SP. DEF") end

-- pokefirered/data/battle_scripts_1.s:873
H[E.MIST] = function(C)
  local side = C.B:sideState(C.user.side)
  if int(side.mistTurns, 0) > 0 then return C:fail() end
  side.mistTurns = Field.MIST_TURNS
  C:attackAnimation()
  C.B:say(nm(C.B, C.user) .. "'s party became shrouded in MIST!")
end

-- pokefirered/src/battle_script_commands.c:8110
H[E.SPIKES] = function(C)
  local foeSide = C.B:sideState(C.user.side == "a" and "b" or "a")
  if int(foeSide.spikes, 0) >= 3 then return C:fail() end
  foeSide.spikes = int(foeSide.spikes, 0) + 1
  C:attackAnimation()
  C.B:say("SPIKES were scattered all around the opponent's side!")
end

H[E.SUNNY_DAY] = function(C) setWeather(C, "SUN", "The sunlight got bright!") end
H[E.RAIN_DANCE] = function(C) setWeather(C, "RAIN", "It started to rain!") end
H[E.SANDSTORM] = function(C) setWeather(C, "SAND", "A sandstorm brewed!") end
H[E.HAIL] = function(C) setWeather(C, "HAIL", "It started to hail!") end

-- pokefirered/data/battle_scripts_1.s:2515
H[E.REFRESH] = function(C)
  local s = Status.normalise(C.user.mon.status)
  if not (s == "BRN" or s == "PSN" or s == "PAR" or s == "TOX") then return C:fail() end
  C:attackAnimation()
  C.B:cure(C.user, nm(C.B, C.user) .. "'s status returned to normal!")
end

-- pokefirered/data/battle_scripts_1.s:2372
H[E.INGRAIN] = function(C)
  if C.user.ingrain then return C:fail() end
  C.user.ingrain = true
  C:attackAnimation()
  C.B:say(nm(C.B, C.user) .. " planted its roots!")
end

local function hpFull(C, b)
  C.B:say(nm(C.B, b) .. "'s HP is full!")
end

-- pokefirered/src/battle_script_commands.c:6332
local function recover(C)
  local B, user = C.B, C.user
  if user.mon.hp >= user.mon.maxHp then return hpFull(C, user) end
  local heal = floor(user.mon.maxHp / 2)
  if heal == 0 then heal = 1 end
  C:attackAnimation()
  B:heal(user, heal)
  B:say(nm(B, user) .. " regained health!")
end
H[E.RESTORE_HP] = recover
H[E.SOFTBOILED] = recover

-- pokefirered/src/battle_script_commands.c:8478
local function morningSun(C)
  local B, user = C.B, C.user
  local maxHp = user.mon.maxHp
  if user.mon.hp >= maxHp then return hpFull(C, user) end
  local weather = B:weather()
  local heal
  if not weather then heal = floor(maxHp / 2)
  elseif weather == "SUN" then heal = floor(20 * maxHp / 30)
  else heal = floor(maxHp / 4) end
  if heal == 0 then heal = 1 end
  C:attackAnimation()
  B:heal(user, heal)
  B:say(nm(B, user) .. " regained health!")
end
H[E.MORNING_SUN] = morningSun
H[E.SYNTHESIS] = morningSun
H[E.MOONLIGHT] = morningSun

-- pokefirered/data/battle_scripts_1.s:735
H[E.REST] = function(C)
  local B, user = C.B, C.user
  if Status.normalise(user.mon.status) == "SLP" then
    return B:say(nm(B, user) .. " is already asleep!")
  end
  if cantMakeAsleep(C, user) then return end
  local maxHp, hp = user.mon.maxHp, user.mon.hp
  if hp >= maxHp then return hpFull(C, user) end
  local had = Status.normalise(user.mon.status) ~= nil
  B:cure(user, nil)
  -- pokefirered/src/battle_script_commands.c:6480 (3 turns, so 2 asleep)
  B:inflict(user, "SLP", { turns = 3, force = true, silent = true, source = user })
  if had then
    B:say(nm(B, user) .. " slept and became healthy!")
  else
    B:say(nm(B, user) .. " went to sleep!")
  end
  C:attackAnimation()
  B:heal(user, maxHp - hp)
  B:say(nm(B, user) .. " regained health!")
end

-- pokefirered/src/battle_script_commands.c:8399
H[E.BELLY_DRUM] = function(C)
  local B, user = C.B, C.user
  local half = floor(user.mon.maxHp / 2)
  if half == 0 then half = 1 end
  if user.stages.atk >= 6 or user.mon.hp <= half then return C:fail() end
  local before = user.stages.atk
  user.stages.atk = 6
  C:attackAnimation()
  B:loseHp(user, half)
  local text = nm(B, user) .. " cut its own HP and maximized ATTACK!"
  B:emit("stat", { slot = user.slot, side = user.side, stat = "atk", stage = 6, delta = 6 - before, text = text })
  B:say(text)
end

-- pokefirered/src/battle_script_commands.c:8899
H[E.WISH] = function(C)
  local B = C.B
  local side = B:sideState(C.user.side)
  for _, tok in ipairs(side.wish) do
    if tok.slot == C.user.slot then return C:fail() end
  end
  side.wish[#side.wish + 1] = { turns = 2, wisher = nm(B, C.user), slot = C.user.slot }
  C:attackAnimation()
  B:say(nm(B, C.user) .. " made a WISH!")
end

-- pokefirered/src/battle_script_commands.c:7995 (Heal Bell / Aromatherapy)
H[E.HEAL_BELL] = function(C)
  local B, user = C.B, C.user
  local isBell = C.mnum == MOVE.HEAL_BELL
  local blocked = isBell and user.ability == "SOUNDPROOF"
  if not blocked and Status.normalise(user.mon.status) then
    B:cure(user, nil)
    user.nightmare = nil
  end
  local blockedAllies = {}
  for _, ally in ipairs(B:allies(user)) do
    if isBell and ally.ability == "SOUNDPROOF" then
      blockedAllies[#blockedAllies + 1] = ally
    elseif Status.normalise(ally.mon.status) then
      B:cure(ally, nil)
      ally.nightmare = nil
    end
  end
  -- The benched party: every mon of the user's seat that is not on the field.
  for i, mon in ipairs(user.fighter.mons) do
    if i ~= user.fighter.active and mon.hp > 0 and Status.normalise(mon.status) then
      mon.status, mon.sleepTurns = nil, nil
    end
  end
  C:attackAnimation()
  if isBell then
    B:say("A bell chimed!")
    if blocked then B:emitAbility(user); B:say(nm(B, user) .. "'s SOUNDPROOF blocks the bell!") end
    for _, ally in ipairs(blockedAllies) do
      B:emitAbility(ally)
      B:say(nm(B, ally) .. "'s SOUNDPROOF blocks the bell!")
    end
  else
    B:say("A soothing aroma wafted through the area!")
  end
  B:syncTeamsNow()
end

-- pokefirered/src/battle_script_commands.c:7674
H[E.PAIN_SPLIT] = function(C)
  local B, user, t = C.B, C.user, C.target
  if not C:accuracyCheck("lockon", true) then return end
  if sub(t) then return C:fail() end
  local avg = floor((user.mon.hp + t.mon.hp) / 2)
  C:attackAnimation()
  B:setHp(user, min(user.mon.maxHp, avg))
  B:setHp(t, min(t.mon.maxHp, avg))
  B:say("The battlers shared their pain!")
end

-- pokefirered/src/battle_script_commands.c:6612
H[E.SWALLOW] = function(C)
  local B, user = C.B, C.user
  local n = int(user.stockpile, 0)
  if n <= 0 then return B:say("But it failed to SWALLOW a thing!") end
  local maxHp = user.mon.maxHp
  user.stockpile = 0
  if user.mon.hp >= maxHp then return hpFull(C, user) end
  local heal = floor(maxHp / (2 ^ (3 - n)))
  if heal == 0 then heal = 1 end
  C:attackAnimation()
  B:heal(user, heal)
  B:say(nm(B, user) .. " regained health!")
end

-- pokefirered/data/battle_scripts_1.s:1440 (Mean Look / Block / Spider Web)
H[E.MEAN_LOOK] = function(C)
  local B, t = C.B, C.target
  if not t then return C:fail() end
  if not C:accuracyCheck("noacc", true) then return end
  if t.trappedBy then return C:fail() end
  if sub(t) then return C:fail() end
  C:attackAnimation()
  t.trappedBy = C.user
  B:say(nm(B, t) .. " can't escape now!")
end

-- pokefirered/src/battle_script_commands.c:6436
H[E.LEECH_SEED] = function(C)
  local B, t = C.B, C.target
  if sub(t) then return C:fail() end
  local hit = C:accuracyCheck("normal", false)
  C:attackAnimation()
  if not hit or t.seededBy then
    return B:say(nm(B, t) .. " evaded the attack!")
  end
  if isType(t, Types.ID.GRASS) then
    return B:say("It doesn't affect " .. nm(B, t) .. "...")
  end
  t.seededBy = C.user.slot
  B:say(nm(B, t) .. " was seeded!")
end

-- pokefirered/data/battle_scripts_1.s:1330
H[E.DESTINY_BOND] = function(C)
  C.user.destinyBond = true
  C:attackAnimation()
  C.B:say(nm(C.B, C.user) .. " is trying to take its foe with it!")
end

-- pokefirered/data/battle_scripts_1.s:1455
H[E.NIGHTMARE] = function(C)
  local B, t = C.B, C.target
  if sub(t) then return C:fail() end
  if t.nightmare then return C:fail() end
  if Status.normalise(t.mon.status) ~= "SLP" then return C:fail() end
  C:attackAnimation()
  t.nightmare = true
  B:say(nm(B, t) .. " began having a NIGHTMARE!")
end

-- pokefirered/data/battle_scripts_1.s:884
H[E.FOCUS_ENERGY] = function(C)
  if C.user.focusEnergy then return C:fail() end
  C.user.focusEnergy = true
  C:attackAnimation()
  C.B:say(nm(C.B, C.user) .. " is getting pumped!")
end

-- pokefirered/data/battle_scripts_1.s:1551 (Foresight / Odor Sleuth)
H[E.FORESIGHT] = function(C)
  if not C:accuracyCheck("normal", true) then return end
  C.target.identified = true
  C:attackAnimation()
  C.B:say(nm(C.B, C.user) .. " identified " .. nm(C.B, C.target) .. "!")
end

-- pokefirered/src/battle_script_commands.c:7759 (Lock-On / Mind Reader)
H[E.LOCK_ON] = function(C)
  local t = C.target
  if sub(t) then return C:fail() end
  if not C:accuracyCheck("normal", true) then return end
  t.lockedOnTurns = 2
  t.lockedOnBy = C.user
  C:attackAnimation()
  C.B:say(nm(C.B, C.user) .. " took aim at " .. nm(C.B, t) .. "!")
end

-- pokefirered/src/battle_script_commands.c:9144 / :9160 (fail when last to move)
H[E.MAGIC_COAT] = function(C)
  if C.user.turnOrder == C.B:battlerCount() then return C:fail() end
  C.user.magicCoat = true
  C:attackAnimation()
  C.B:say(nm(C.B, C.user) .. " shrouded itself in MAGIC COAT!")
end

H[E.SNATCH] = function(C)
  if C.user.turnOrder == C.B:battlerCount() then return C:fail() end
  C.user.snatch = true
  C:attackAnimation()
  C.B:say(nm(C.B, C.user) .. " waits for a target to make a move!")
end

-- pokefirered/data/battle_scripts_1.s:2527
H[E.GRUDGE] = function(C)
  if C.user.grudge then return C:fail() end
  C.user.grudge = true
  C:attackAnimation()
  C.B:say(nm(C.B, C.user) .. " wants the opponent to bear a GRUDGE!")
end

-- pokefirered/src/battle_script_commands.c:9019
H[E.IMPRISON] = function(C)
  local B, user = C.B, C.user
  if user.imprison then return C:fail() end
  local shared = false
  for _, foe in ipairs(B:foes(user)) do
    for i = 1, #user.moves do
      local a = int(user.moves[i].num, 0)
      if a ~= 0 then
        for j = 1, #foe.moves do
          if int(foe.moves[j].num, 0) == a then shared = true end
        end
      end
    end
  end
  if not shared then return C:fail() end
  user.imprison = true
  C:attackAnimation()
  B:say(nm(B, user) .. " sealed the opponent's move(s)!")
end

-- pokefirered/src/battle_script_commands.c:9316
H[E.MUD_SPORT] = function(C)
  if C.user.mudSport then return C:fail() end
  C.user.mudSport = true
  C:attackAnimation()
  C.B:say("Electricity's power was weakened!")
end

H[E.WATER_SPORT] = function(C)
  if C.user.waterSport then return C:fail() end
  C.user.waterSport = true
  C:attackAnimation()
  C.B:say("FIRE's power was weakened!")
end

-- pokefirered/src/battle_script_commands.c:9389
H[E.CAMOUFLAGE] = function(C)
  local B, user = C.B, C.user
  local t = Field.TERRAIN_TYPE[B.terrain] or Types.ID.NORMAL
  if isType(user, t) then return C:fail() end
  user.type1, user.type2 = t, nil
  C:attackAnimation()
  B:say(nm(B, user) .. " transformed into the " .. B:typeLabel(t) .. " type!")
end

-- pokefirered/src/battle_script_commands.c:8884
H[E.ROLE_PLAY] = function(C)
  local B = C.B
  if not C:accuracyCheck("lockon", true) then return end
  local foeAb = C.target.ability
  if not foeAb or foeAb == "WONDER_GUARD" then return C:fail() end
  C.user.ability = foeAb
  C.user.abilityName = C.target.abilityName
  C:attackAnimation()
  B:emitAbility(C.user)
  B:say(nm(B, C.user) .. " copied " .. nm(B, C.target) .. "'s " .. B:abilityLabel(C.target) .. "!")
end

-- pokefirered/src/battle_script_commands.c:8999
H[E.SKILL_SWAP] = function(C)
  local B = C.B
  if not C:accuracyCheck("lockon", true) then return end
  local a, b = C.user.ability, C.target.ability
  if (not a and not b) or a == "WONDER_GUARD" or b == "WONDER_GUARD" then return C:fail() end
  local an, bn = C.user.abilityName, C.target.abilityName
  C.user.ability, C.target.ability = b, a
  C.user.abilityName, C.target.abilityName = bn, an
  C:attackAnimation()
  B:emitAbility(C.user)
  B:emitAbility(C.target)
  B:say(nm(B, C.user) .. " swapped abilities with its opponent!")
end

-- pokefirered/src/battle_script_commands.c:8544 (Future Sight / Doom Desire):
-- a delayed hit whose base damage is fixed now and rolled when it lands.
H[E.FUTURE_SIGHT] = function(C)
  local B, user, t = C.B, C.user, C.target
  local side = B:sideState(t.side)
  for _, tok in ipairs(side.futureSight) do
    if tok.targetSlot == t.slot then return C:fail() end
  end
  local defSide = B:sideState(t.side)
  local dmg = Damage.base(user, t, C.move, {
    weather = B:weather(), specialTypes = B.specialTypes,
    reflect = int(defSide.reflectTurns, 0) > 0, lightScreen = int(defSide.lightScreenTurns, 0) > 0,
    doubleScreens = B.double and B:countStandingOnSide(t.side) >= 2,
    mudSport = B:fieldSport("mudSport"), waterSport = B:fieldSport("waterSport"),
    plusPartner = B:abilityOnField("PLUS"), minusPartner = B:abilityOnField("MINUS"),
  })
  -- pokefirered/src/battle_script_commands.c:8558
  if user.helpingHand then dmg = floor(dmg * 15 / 10) end
  local doom = C.mnum == MOVE.DOOM_DESIRE
  side.futureSight[#side.futureSight + 1] = {
    turns = 3, damage = dmg, move = C.move, attackerSlot = user.slot, targetSlot = t.slot,
    doom = doom, attackerName = nm(B, user),
  }
  C:attackAnimation()
  if doom then
    B:say(nm(B, user) .. " chose DOOM DESIRE as its destiny!")
  else
    B:say(nm(B, user) .. " foresaw an attack!")
  end
end

-- pokefirered/data/battle_scripts_1.s:1478
H[E.CURSE] = function(C)
  local B, user = C.B, C.user
  if isType(user, Types.ID.GHOST) then
    local t = C.target
    if t == user or not t then
      t = B:foes(user)[1]
      C.target = t
    end
    if not t then return C:fail() end
    if sub(t) then return C:fail() end
    if not C:accuracyCheck("lockon", true) then return end
    if t.cursed then return C:fail() end
    t.cursed = true
    local cost = floor(user.mon.maxHp / 2)
    if cost == 0 then cost = 1 end
    C:attackAnimation()
    B:loseHp(user, cost)
    B:say(nm(B, user) .. " cut its own HP and laid a CURSE on " .. nm(B, t) .. "!")
    C.checkUserFaint = true
    return
  end
  local s = user.stages
  if s.spe <= -6 and s.atk >= 6 and s.def >= 6 then return C:fail() end
  C:attackAnimation()
  M.changeStat(B, user, "spe", -1, { user = true, allowPtr = true, curse = true, noMsg = s.spe <= -6 })
  M.changeStat(B, user, "atk", 1, { user = true, allowPtr = true, noMsg = s.atk >= 6 })
  M.changeStat(B, user, "def", 1, { user = true, allowPtr = true, noMsg = s.def >= 6 })
end

-- pokefirered/src/battle_script_commands.c:8779 (the nearest ally)
H[E.HELPING_HAND] = function(C)
  local B, user = C.B, C.user
  local partner = C.chosenAlly or B:partner(user)
  if not B.double or not partner or user.helpingHand or partner.helpingHand then
    return C:fail()
  end
  partner.helpingHand = true
  C.target = partner
  C:attackAnimation()
  B:say(nm(B, user) .. " is ready to help " .. nm(B, partner) .. "!")
end

H[E.SPLASH] = function(C)
  C:attackAnimation()
  C.B:say("But nothing happened!")
end

-- pokefirered/data/battle_scripts_1.s:902 (Supersonic / Confuse Ray / Sweet Kiss)
H[E.CONFUSE] = function(C)
  local B, t = C.B, C.target
  if t.ability == "OWN_TEMPO" then
    B:emitAbility(t)
    return B:say(nm(B, t) .. "'s OWN TEMPO prevents confusion!")
  end
  if sub(t) then return C:fail() end
  if int(t.confusion, 0) > 0 then return B:say(nm(B, t) .. " is already confused!") end
  if not C:accuracyCheck("normal", true) then return end
  if safeguarded(C, t) then return end
  C:attackAnimation()
  M.set(C, "CONFUSION", true, false, false)
end

-- pokefirered/data/battle_scripts_1.s:2566 (Teeter Dance: every other battler)
H[E.TEETER_DANCE] = function(C)
  local B, t = C.B, C.target
  if t.ability == "OWN_TEMPO" then
    B:emitAbility(t)
    return B:say(nm(B, t) .. "'s OWN TEMPO prevents confusion!")
  end
  if sub(t) then return C:fail() end
  if int(t.confusion, 0) > 0 then return B:say(nm(B, t) .. " is already confused!") end
  if not C:accuracyCheck("normal", true) then return end
  if int(B:sideState(t.side).safeguardTurns, 0) > 0 then
    return B:say(nm(B, t) .. " is protected by SAFEGUARD!")
  end
  C:attackAnimation()
  M.set(C, "CONFUSION", true, false, false)
end

-- pokefirered/src/battle_script_commands.c:6826
H[E.HAZE] = function(C)
  C:attackAnimation()
  for _, b in ipairs(C.B:active()) do
    for _, k in ipairs(STAT_ORDER) do b.stages[k] = 0 end
  end
  C.B:say("All stat changes were eliminated!")
end

-- pokefirered/src/battle_script_commands.c:7442
H[E.SUBSTITUTE] = function(C)
  local B, user = C.B, C.user
  if sub(user) then return B:say(nm(B, user) .. " already has a SUBSTITUTE!") end
  local cost = floor(user.mon.maxHp / 4)
  if cost == 0 then cost = 1 end
  if user.mon.hp <= cost then
    C.failed = true
    return B:say("It was too weak to make a SUBSTITUTE!")
  end
  user.substituteHP = cost
  user.trapTurns, user.trapMove, user.trapSource = nil, nil, nil
  C:attackAnimation()
  B:loseHp(user, cost)
  B:emit("sub", { slot = user.slot, side = user.side, amount = 1 })
  B:say(nm(B, user) .. " made a SUBSTITUTE!")
end

-- pokefirered/src/battle_script_commands.c:6220
H[E.PROTECT] = function(C)
  protectLike(C, function(user)
    user.protected = true
    C.B:say(nm(C.B, user) .. " protected itself!")
  end)
end

H[E.ENDURE] = function(C)
  protectLike(C, function(user)
    user.enduring = true
    C.B:say(nm(C.B, user) .. " braced itself!")
  end)
end

-- pokefirered/src/battle_script_commands.c:7642
H[E.ENCORE] = function(C)
  local B, t = C.B, C.target
  if not C:accuracyCheck("normal", true) then return end
  local last = int(t.lastMoveNum, 0)
  if last == 0 or last == MOVE.STRUGGLE or last == MOVE.ENCORE or last == MOVE.MIRROR_MOVE then
    return C:fail()
  end
  if int(t.encoreTurns, 0) > 0 then return C:fail() end
  local slot = B:slotOfNum(t, last)
  if not slot or int(t.moves[slot].pp, 0) <= 0 then return C:fail() end
  t.encoreNum = last
  t.encoreSlot = slot
  t.encoreTurns = B:roll(0, 3) + 3
  C:attackAnimation()
  B:say(nm(B, t) .. " got an ENCORE!")
end

-- pokefirered/src/battle_script_commands.c:8133
H[E.PERISH_SONG] = function(C)
  local B = C.B
  local affected, blocked = 0, {}
  for _, b in ipairs(B:active()) do
    if b.ability == "SOUNDPROOF" then
      blocked[#blocked + 1] = b
    elseif b.perishTurns == nil then
      b.perishTurns = 3
      affected = affected + 1
    end
  end
  if affected == 0 then return C:fail() end
  C:attackAnimation()
  B:say("All affected POKeMON will faint in three turns!")
  for _, b in ipairs(blocked) do
    B:emitAbility(b)
    B:say(nm(B, b) .. "'s SOUNDPROOF blocks PERISH SONG!")
  end
end

-- pokefirered/src/battle_script_commands.c:7275
H[E.ATTRACT] = function(C)
  local B, t = C.B, C.target
  if not C:accuracyCheck("normal", true) then return end
  if t.ability == "OBLIVIOUS" then
    B:emitAbility(t)
    return B:say(nm(B, t) .. "'s OBLIVIOUS prevents romance!")
  end
  local ug, tg = C.user.mon.gender, t.mon.gender
  if t.infatuatedWith or not ug or not tg or ug == "U" or tg == "U" or ug == tg then
    return C:fail()
  end
  t.infatuatedWith = C.user
  C:attackAnimation()
  B:say(nm(B, t) .. " fell in love!")
end

-- pokefirered/src/battle_script_commands.c:7943
H[E.SPITE] = function(C)
  local B, t = C.B, C.target
  if not C:accuracyCheck("normal", true) then return end
  local last = int(t.lastMoveNum, 0)
  local slot = last ~= 0 and B:slotOfNum(t, last) or nil
  if not slot or int(t.moves[slot].pp, 0) <= 1 then return C:fail() end
  local mv = t.moves[slot]
  local cut = B:roll(0, 3) + 2
  if mv.pp < cut then cut = mv.pp end
  mv.pp = mv.pp - cut
  if mv.pp == 0 then B:cancelMultiTurn(t) end
  C:attackAnimation()
  B:say("It reduced the PP of " .. nm(B, t) .. "'s " .. B:moveLabel(mv) .. " by " .. cut .. "!")
  B:emitMovesOf(t)
end

-- pokefirered/src/battle_script_commands.c:8744
H[E.TORMENT] = function(C)
  if not C:accuracyCheck("normal", true) then return end
  if C.target.tormented then return C:fail() end
  C.target.tormented = true
  C:attackAnimation()
  C.B:say(nm(C.B, C.target) .. " was subjected to TORMENT!")
end

-- pokefirered/data/battle_scripts_1.s:2303
H[E.TAUNT] = function(C)
  if not C:accuracyCheck("normal", true) then return end
  if int(C.target.tauntTurns, 0) > 0 then return C:fail() end
  -- pokefirered/src/battle_script_commands.c:8765
  C.target.tauntTurns = 2
  C:attackAnimation()
  C.B:say(nm(C.B, C.target) .. " fell for the TAUNT!")
end

-- pokefirered/data/battle_scripts_1.s:2446
H[E.YAWN] = function(C)
  local B, t = C.B, C.target
  local ab = t.ability
  if ab == "VITAL_SPIRIT" or ab == "INSOMNIA" then
    B:emitAbility(t)
    return B:say(nm(B, t) .. "'s " .. B:abilityLabel(t) .. " made it ineffective!")
  end
  if sub(t) then return C:fail() end
  if int(B:sideState(t.side).safeguardTurns, 0) > 0 then
    return B:say(nm(B, t) .. " is protected by SAFEGUARD!")
  end
  if not C:accuracyCheck("lockon", true) then return end
  if B:uproarActive() and ab ~= "SOUNDPROOF" then return C:fail() end
  if int(t.yawnTurns, 0) > 0 or Status.normalise(t.mon.status) then return C:fail() end
  t.yawnTurns = 2
  C:attackAnimation()
  B:say(nm(B, C.user) .. " made " .. nm(B, t) .. " drowsy!")
end

-- pokefirered/src/battle_script_commands.c:6905 (Roar / Whirlwind)
H[E.ROAR] = function(C)
  local B, user, t = C.B, C.user, C.target
  if t.ability == "SUCTION_CUPS" then
    B:emitAbility(t)
    return B:say(nm(B, t) .. " anchors itself with SUCTION CUPS!")
  end
  if t.ingrain then return B:say(nm(B, t) .. " anchored itself with its roots!") end
  if not C:accuracyCheck("lockon", true) then return end
  if not C:accuracyCheck("normal", true) then return end
  local candidates = B:benchOf(t.fighter)
  if not B:isWild() and #candidates < 1 then return C:fail() end
  local uLvl, tLvl = int(user.mon.level, 1), int(t.mon.level, 1)
  if uLvl < tLvl then
    local r = B:roll(0, 255)
    if floor(r * (uLvl + tLvl) / 256) + 1 <= floor(tLvl / 4) then return C:fail() end
  end
  C:attackAnimation()
  if B:isWild() then
    -- pokefirered/data/battle_scripts_1.s:3283: blown out of a wild fight
    B:blownAway(t)
    return
  end
  local slot = candidates[B:roll(1, #candidates)]
  local nb = B:forceSwitch(t.fighter, slot, "roar")
  if nb then
    C.target = nb
    B:say(nm(B, nb) .. " was dragged out!")
    B:switchInEffects(nb, { spikes = true, deferIntimidate = true })
  end
end

-- pokefirered/src/battle_script_commands.c:7003
H[E.CONVERSION] = function(C)
  local B, user = C.B, C.user
  local list = {}
  for i = 1, #user.moves do
    local mv = user.moves[i]
    if not mv or int(mv.num, 0) == 0 then break end
    local t = int(mv.type, 0)
    if t == Types.ID.MYSTERY then
      t = isType(user, Types.ID.GHOST) and Types.ID.GHOST or Types.ID.NORMAL
    end
    if not isType(user, t) then list[#list + 1] = t end
  end
  if #list == 0 then return C:fail() end
  local t = list[B:roll(1, #list)]
  user.type1, user.type2 = t, nil
  C:attackAnimation()
  B:say(nm(B, user) .. " transformed into the " .. B:typeLabel(t) .. " type!")
end

-- pokefirered/src/battle_script_commands.c:7699
H[E.CONVERSION_2] = function(C)
  local B, user = C.B, C.user
  local last = int(user.lastLandedMove, 0)
  local lastType = user.lastHitByType
  if last == 0 or lastType == nil then return C:fail() end
  local foe = user.lastHitBy
  if foe and B:isTwoTurnNum(last) and foe.twoTurnNum then return C:fail() end
  local valid = {}
  local t = B.typeTable or {}
  local i = 1
  while i + 2 <= #t do
    local a, d, m = t[i], t[i + 1], t[i + 2]
    if a == Types.FORESIGHT_SENTINEL then break end
    if a == lastType and m <= 5 and not isType(user, d) then valid[#valid + 1] = d end
    i = i + 3
  end
  if #valid == 0 then return C:fail() end
  local pick = valid[B:roll(1, #valid)]
  user.type1, user.type2 = pick, nil
  C:attackAnimation()
  B:say(nm(B, user) .. " transformed into the " .. B:typeLabel(pick) .. " type!")
end

-- pokefirered/src/battle_script_commands.c:7398
H[E.TRANSFORM] = function(C)
  local B, user, t = C.B, C.user, C.target
  if t.transformed or t.semi then return C:fail() end
  user.stats = { atk = t.stats.atk, def = t.stats.def, spe = t.stats.spe,
                 spa = t.stats.spa, spd = t.stats.spd }
  local moves = {}
  for i = 1, #t.moves do
    local src = t.moves[i]
    local copy = B:copyMove(src)
    copy.pp = min(5, int(src.maxPp, 5))
    copy.maxPp = copy.pp
    moves[i] = copy
  end
  user.moves = moves
  user.overlay = true
  for _, k in ipairs(STAT_ORDER) do user.stages[k] = t.stages[k] end
  user.type1, user.type2 = t.type1, t.type2
  user.ability, user.abilityName = t.ability, t.abilityName
  -- pret copies the whole battle struct from species on (the species too), so
  -- species-keyed items follow the new species.
  user.speciesNum = t.speciesNum
  user.transformed = true
  user.disabledNum, user.disableTurns = nil, nil
  C:attackAnimation()
  B:emit("form", { slot = user.slot, side = user.side, speciesId = t.mon.speciesId,
                   text = t.mon.species })
  B:say(nm(B, user) .. " transformed into " .. t.mon.species .. "!")
  B:emitMovesOf(user)
end

-- pokefirered/src/battle_script_commands.c:7478
H[E.MIMIC] = function(C)
  local B, user, t = C.B, C.user, C.target
  if sub(t) then return C:fail() end
  if not C:accuracyCheck("lockon", true) then return end
  local row, last = lastMoveRow(B, t)
  if not row or user.transformed or M.forbidden(last, true) then return C:fail() end
  if B:slotOfNum(user, last) then return C:fail() end
  local slot = C.slot
  if not slot then return C:fail() end
  B:overlayMoves(user)
  local copy = B:copyMove(row)
  copy.pp = min(5, int(row.maxPp or row.pp, 5))
  copy.maxPp = copy.pp
  user.moves[slot] = copy
  C:attackAnimation()
  B:say(nm(B, user) .. " learned " .. B:moveLabel(copy) .. "!")
  B:emitMovesOf(user)
end

-- pokefirered/src/battle_script_commands.c:7617
H[E.DISABLE] = function(C)
  local B, t = C.B, C.target
  if not C:accuracyCheck("normal", true) then return end
  local last = int(t.lastMoveNum, 0)
  local slot = last ~= 0 and B:slotOfNum(t, last) or nil
  if t.disabledNum or not slot or int(t.moves[slot].pp, 0) <= 0 then return C:fail() end
  t.disabledNum = int(t.moves[slot].num, 0)
  t.disableTurns = B:roll(0, 3) + 2
  C:attackAnimation()
  B:say(nm(B, t) .. "'s " .. B:moveLabel(t.moves[slot]) .. " was disabled!")
end

-- pokefirered/src/battle_script_commands.c:7768 (permanent: the party learns it)
H[E.SKETCH] = function(C)
  local B, user, t = C.B, C.user, C.target
  if sub(t) then return C:fail() end
  local last = int(t.lastPrinted, 0)
  if user.transformed or last == 0 or last == MOVE.STRUGGLE or last == MOVE.SKETCH then
    return C:fail()
  end
  for i = 1, #user.moves do
    local n = int(user.moves[i].num, 0)
    if n ~= MOVE.SKETCH and n == last then return C:fail() end
  end
  local slot = C.slot
  local row = B:moveRowByNum(last, t)
  if not slot or not row then return C:fail() end
  local copy = B:copyMove(row)
  copy.pp = int(row.maxPp or row.pp, 5)
  copy.maxPp = copy.pp
  user.mon.moves[slot] = copy
  if not user.overlay then user.moves = user.mon.moves else user.moves[slot] = B:copyMove(copy) end
  C:attackAnimation()
  B:say(nm(B, user) .. " SKETCHED " .. B:moveLabel(copy) .. "!")
  B:emitMovesOf(user, true)
end

-- pokefirered/data/battle_scripts_1.s:1690
H[E.BATON_PASS] = function(C)
  local B, user = C.B, C.user
  local candidates = B:benchOf(user.fighter)
  if #candidates == 0 then return C:fail() end
  C:attackAnimation()
  local slot = candidates[1]
  local want = C.passSlot
  for _, c in ipairs(candidates) do
    if c == want then slot = want end
  end
  local nb = B:forceSwitch(user.fighter, slot, "baton_pass", user)
  if nb then
    C.user = nb
    B:switchInEffects(nb, { spikes = true, deferIntimidate = true })
  end
end

-- pokefirered/data/battle_scripts_1.s:1921
H[E.TELEPORT] = function(C)
  local B, user = C.B, C.user
  if not B:isWild() then return C:fail() end
  local he = Items.of(user)
  if not (user.ability == "RUN_AWAY" or he == Items.HOLD.CAN_ALWAYS_RUN) then
    local holder, fab = Abilities.escapeBlocker(B, user)
    if holder then
      B:emitAbility(holder)
      return B:say(nm(B, holder) .. "'s " .. B:abilityLabel(holder) .. " made it ineffective!")
    end
    if B:isTrapped(user) then return C:fail() end
  end
  C:attackAnimation()
  B:say(nm(B, user) .. " fled from battle!")
  B:concede(user.fighter)
end

-- pokefirered/src/battle_script_commands.c:8702
H[E.FOLLOW_ME] = function(C)
  local side = C.B:sideState(C.user.side)
  side.followMe = C.user
  C:attackAnimation()
  C.B:say(nm(C.B, C.user) .. " became the center of attention!")
end

-- pokefirered/src/battle_script_commands.c:8798 (Trick: either side, link rules)
H[E.TRICK] = function(C)
  local B, user, t = C.B, C.user, C.target
  if sub(t) then return C:fail() end
  if not C:accuracyCheck("normal", true) then return end
  if user.mon.knockedOff or t.mon.knockedOff then return C:fail() end
  local ui, ti = int(user.mon.heldItem, 0), int(t.mon.heldItem, 0)
  if (ui == 0 and ti == 0) or ui == Items.ITEM_ENIGMA_BERRY or ti == Items.ITEM_ENIGMA_BERRY
      or Items.isMail(ui) or Items.isMail(ti) then
    return C:fail()
  end
  if t.ability == "STICKY_HOLD" then
    B:emitAbility(t)
    return B:say(nm(B, t) .. "'s STICKY HOLD made " .. C:moveName() .. " ineffective!")
  end
  local urow, trow = Items.rowOf(user), Items.rowOf(t)
  local ulbl, tlbl = B:itemLabel(user), B:itemLabel(t)
  Items.give(user, trow)
  Items.give(t, urow)
  C:attackAnimation()
  Items.heldEvent(B, user, ti, tlbl)
  Items.heldEvent(B, t, ui, ulbl)
  B:say(nm(B, user) .. " switched items with its opponent!")
  if ti ~= 0 then B:say(nm(B, user) .. " obtained " .. tlbl .. ".") end
  if ui ~= 0 then B:say(nm(B, t) .. " obtained " .. ulbl .. ".") end
end

-- pokefirered/src/battle_script_commands.c:9366
H[E.RECYCLE] = function(C)
  local B, user = C.B, C.user
  local side = B:sideState(user.side)
  local used = side.usedHeldItem or user.usedHeldItem
  if not used or int(user.mon.heldItem, 0) ~= 0 then return C:fail() end
  user.usedHeldItem, side.usedHeldItem = nil, nil
  Items.give(user, used)
  C:attackAnimation()
  local lbl = B:itemLabel(user)
  Items.heldEvent(B, user, used.item, lbl)
  B:say(nm(B, user) .. " found one " .. lbl .. "!")
end

-- The unused slots and a power-0 plain hit: the cart's placeholder.
for _, id in ipairs({ 0, 96, 110, 131, 141, 163 }) do
  H[id] = function(C)
    C:attackAnimation()
    C.B:say("But nothing happened!")
  end
end

-- Resolves a non-damaging effect.  Returns false when there is no handler, so
-- the caller can say "But nothing happened!" (the damaging and calling effects
-- never reach here).
function M.run(C)
  local fn = H[int(C.effect, -1)]
  if not fn then return false end
  fn(C)
  return true
end

function M.handles(effect)
  return H[int(effect, -1)] ~= nil
end

return M
