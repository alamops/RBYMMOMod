-- AIChooseMove: the computer's move choice on Gold / Silver / Crystal.
--
-- pokecrystal engine/battle/ai/move.asm (AIChooseMove), every scoring layer
-- of engine/battle/ai/scoring.asm -- AI_Basic, AI_Setup, AI_Types,
-- AI_Offensive, AI_Smart and its AI_Smart_* handlers, AI_Opportunist,
-- AI_Aggressive (AIDamageCalc), AI_Cautious, AI_Status, AI_Risky -- and
-- engine/battle/ai/redundant.asm (AI_Redundant); pokegold's copies where Gold
-- and Silver differ (`family`, contract K6: "gs" or "crystal").  Plus
-- ParseEnemyAction's wild pick (engine/battle/core.asm), which is not
-- AIChooseMove's but draws where it does.
--
-- A pure module over the referee's own battle state: it reads `fighter.mons`,
-- the stages, the volatile fields, the screens, the weather and
-- `fighter.aiFlags` (TRNATTR_AI_MOVE_WEIGHTS, contract K16) and changes
-- nothing on them; the only thing it moves is `battle.rng`, one byte where
-- the cart calls `Random` -- every AI_80_20 / AI_50_50, every `call Random`
-- in a handler, PSYWAVE's loop inside AIDamageCalc and the final pick among
-- the lowest scores -- in the cart's order.  Outside a link battle the cart's
-- BattleRandom IS Random (engine/battle/core.asm _BattleRandom: `ld a,
-- [wLinkMode] / and a / jp z, Random`), and this AI never runs in a link
-- battle, so both are the one referee stream.
--
-- The cart reads some state the referee does not keep.  Each such read is a
-- named field with a documented default (see `turnsTaken`, `usedMoves`):
--
--   * mon.turnsTaken -- wPlayerTurnsTaken / wEnemyTurnsTaken, the byte
--     BattleCommand_DoTurn counts up (effect_commands.asm `.proceed`: `inc a`
--     once per move that reaches `doturn`: Struggle, an `.out_of_pp`, and a
--     lock-in's FIRST turn -- a charge's, a rampage's, the first ROLLOUT,
--     BIDE's start -- but not its later ones, whose CheckCharge / CheckRampage
--     / CheckRollout / StoreEnergy skip past `doturn`; not a METRONOME /
--     MIRROR MOVE / SLEEP TALK call -- those run with wPlayerCharging set,
--     CheckUserIsCharging's `ret nz`), cleared by NewBattleMonStatus /
--     NewEnemyMonStatus at a send-out (not BATON PASS's): Turn keeps it
--     (`_useMove`, `_sendOut`).  Absent reads 0: the monster's first turn.
--   * mon.usedMoves -- wPlayerUsedMoves (the PLAYER's monster's only): the
--     moves UpdateUsedMoves appends in UsedMoveText on the player's turn
--     (wPlayerMoveStruct + MOVE_ANIM, unless already there), first use
--     order, four at most (a fifth shifts the first out), cleared by
--     NewBattleMonStatus.  Each entry a move id or a move record (AiSwitch's
--     `recordUsedMove` rows serve): `M.usedMove` reads it.  Absent reads
--     empty: "unknown moves".
--
-- What the cart reads at a fixed point the referee keeps on the monster:
-- wLastPlayerCounterMove (`lastCounterMove`), wLastPlayerMove (`lastMove`),
-- the FURY CUTTER / ROLLOUT / PROTECT / RAGE / PERISH / wrap counts, the
-- substatus bits (`inLove`, `identified`, `nightmare`, `cursed`, `encore`,
-- `lockOn`, `meanLook`, `charging`, `rollout`, `toxicLatent`, ...).
--
-- hBattleTurn is 1 as AIChooseMove starts (BattleTurn calls HandleBerserkGene
-- -- `.player` then `.enemy`'s SetEnemyTurn -- right before it), the scoring
-- layers set it to 1 before every BattleCheckTypeMatchup, and only
-- AI_Smart_Conversion2 sets it to 0; `ctx.turn` follows it, because
-- CheckTypeMatchup reads BATTLE_VARS_MOVE_TYPE through it (the documented
-- "false assumption about CheckTypeMatchup").
--
-- No love, no engine modules, no mod facade.

local need = ...

local Damage  = need("BattleSim2/Damage")
local Effects = need("BattleSim2/Effects")
local Items   = need("BattleSim2/Items")

local M = {}

local floor, max, min = math.floor, math.max, math.min

M.NUM_MOVES = 4
-- AIChooseMove's `ld a, 20`, the score an unusable move takes (`ld [hl], 80`),
-- and AIDiscourageMove's `add 10`.
M.BASE_SCORE = 20
M.UNUSABLE_SCORE = 80
M.DISMISS = 10
-- constants/battle_constants.asm.
M.BASE_STAT_LEVEL = 7
M.MAX_STAT_LEVEL = 13
M.EFFECTIVE = 10
M.BASE_AI_SWITCH_SCORE = 10
-- `cp 16 ; up to 16 scoring layers`: the bit numbers of TRNATTR_AI_MOVE_WEIGHTS
-- (constants/trainer_data_constants.asm, AI_BASIC_F ..) in AIScoringPointers'
-- order; bits 10..15 are AI_None.
M.LAYERS = {
  "BASIC", "SETUP", "TYPES", "OFFENSIVE", "SMART",
  "OPPORTUNIST", "AGGRESSIVE", "CAUTIOUS", "STATUS", "RISKY",
}
M.LAYER_SLOTS = 16
-- Turn.REDRAW_LIMIT's number: the guard on `.ChooseMove`'s and the wild
-- `.loop2`'s redraws and on PSYWAVE's loop (Effects.fixedDamage).
M.REDRAW_LIMIT = 1024
-- Turn.LINK_MODES, mirrored rather than required (Turn requires this file).
M.LINK_MODES = { ["1v1"] = true, coop_pvp = true }

-- The `percent` thresholds the layers compare a Random byte against
-- (macros/data.asm: `percent EQUS "* $ff / 100"`, integer arithmetic).
local P4, P8, P10, P12, P16 = 10, 20, 25, 30, 40   -- 4, 8, 10, 12, 16 percent
local P20M1 = 50                                    -- 20 percent - 1 (AI_80_20)
local P28M1 = 70                                    -- 28 percent - 1
local P31P1 = 80                                    -- 31 percent + 1
local P35P1 = 90                                    -- 35 percent + 1 (Gold)
local P39P1 = 100                                   -- 39 percent + 1
local P50P1 = 128                                   -- 50 percent + 1 (AI_50_50)
local P70 = 178                                     -- 70 percent
local P71M1 = 180                                   -- 71 percent - 1
local P79M1 = 200                                   -- 79 percent - 1
local P90P1 = 230                                   -- 90 percent + 1

-- constants/move_effect_constants.asm (pokecrystal and pokegold the same), the
-- cart's effect numbers in order: AI_Setup compares ranges of them.
M.CART_EFFECTS = {
  [0] = "EFFECT_NORMAL_HIT", "EFFECT_SLEEP", "EFFECT_POISON_HIT", "EFFECT_LEECH_HIT",
  "EFFECT_BURN_HIT", "EFFECT_FREEZE_HIT", "EFFECT_PARALYZE_HIT", "EFFECT_SELFDESTRUCT",
  "EFFECT_DREAM_EATER", "EFFECT_MIRROR_MOVE", "EFFECT_ATTACK_UP", "EFFECT_DEFENSE_UP",
  "EFFECT_SPEED_UP", "EFFECT_SP_ATK_UP", "EFFECT_SP_DEF_UP", "EFFECT_ACCURACY_UP",
  "EFFECT_EVASION_UP", "EFFECT_ALWAYS_HIT", "EFFECT_ATTACK_DOWN", "EFFECT_DEFENSE_DOWN",
  "EFFECT_SPEED_DOWN", "EFFECT_SP_ATK_DOWN", "EFFECT_SP_DEF_DOWN", "EFFECT_ACCURACY_DOWN",
  "EFFECT_EVASION_DOWN", "EFFECT_RESET_STATS", "EFFECT_BIDE", "EFFECT_RAMPAGE",
  "EFFECT_FORCE_SWITCH", "EFFECT_MULTI_HIT", "EFFECT_CONVERSION", "EFFECT_FLINCH_HIT",
  "EFFECT_HEAL", "EFFECT_TOXIC", "EFFECT_PAY_DAY", "EFFECT_LIGHT_SCREEN",
  "EFFECT_TRI_ATTACK", "EFFECT_UNUSED_25", "EFFECT_OHKO", "EFFECT_RAZOR_WIND",
  "EFFECT_SUPER_FANG", "EFFECT_STATIC_DAMAGE", "EFFECT_TRAP_TARGET", "EFFECT_UNUSED_2B",
  "EFFECT_DOUBLE_HIT", "EFFECT_JUMP_KICK", "EFFECT_MIST", "EFFECT_FOCUS_ENERGY",
  "EFFECT_RECOIL_HIT", "EFFECT_CONFUSE", "EFFECT_ATTACK_UP_2", "EFFECT_DEFENSE_UP_2",
  "EFFECT_SPEED_UP_2", "EFFECT_SP_ATK_UP_2", "EFFECT_SP_DEF_UP_2", "EFFECT_ACCURACY_UP_2",
  "EFFECT_EVASION_UP_2", "EFFECT_TRANSFORM", "EFFECT_ATTACK_DOWN_2", "EFFECT_DEFENSE_DOWN_2",
  "EFFECT_SPEED_DOWN_2", "EFFECT_SP_ATK_DOWN_2", "EFFECT_SP_DEF_DOWN_2",
  "EFFECT_ACCURACY_DOWN_2", "EFFECT_EVASION_DOWN_2", "EFFECT_REFLECT", "EFFECT_POISON",
  "EFFECT_PARALYZE", "EFFECT_ATTACK_DOWN_HIT", "EFFECT_DEFENSE_DOWN_HIT",
  "EFFECT_SPEED_DOWN_HIT", "EFFECT_SP_ATK_DOWN_HIT", "EFFECT_SP_DEF_DOWN_HIT",
  "EFFECT_ACCURACY_DOWN_HIT", "EFFECT_EVASION_DOWN_HIT", "EFFECT_SKY_ATTACK",
  "EFFECT_CONFUSE_HIT", "EFFECT_POISON_MULTI_HIT", "EFFECT_UNUSED_4E", "EFFECT_SUBSTITUTE",
  "EFFECT_HYPER_BEAM", "EFFECT_RAGE", "EFFECT_MIMIC", "EFFECT_METRONOME",
  "EFFECT_LEECH_SEED", "EFFECT_SPLASH", "EFFECT_DISABLE", "EFFECT_LEVEL_DAMAGE",
  "EFFECT_PSYWAVE", "EFFECT_COUNTER", "EFFECT_ENCORE", "EFFECT_PAIN_SPLIT", "EFFECT_SNORE",
  "EFFECT_CONVERSION2", "EFFECT_LOCK_ON", "EFFECT_SKETCH", "EFFECT_DEFROST_OPPONENT",
  "EFFECT_SLEEP_TALK", "EFFECT_DESTINY_BOND", "EFFECT_REVERSAL", "EFFECT_SPITE",
  "EFFECT_FALSE_SWIPE", "EFFECT_HEAL_BELL", "EFFECT_PRIORITY_HIT", "EFFECT_TRIPLE_KICK",
  "EFFECT_THIEF", "EFFECT_MEAN_LOOK", "EFFECT_NIGHTMARE", "EFFECT_FLAME_WHEEL",
  "EFFECT_CURSE", "EFFECT_UNUSED_6E", "EFFECT_PROTECT", "EFFECT_SPIKES", "EFFECT_FORESIGHT",
  "EFFECT_PERISH_SONG", "EFFECT_SANDSTORM", "EFFECT_ENDURE", "EFFECT_ROLLOUT",
  "EFFECT_SWAGGER", "EFFECT_FURY_CUTTER", "EFFECT_ATTRACT", "EFFECT_RETURN",
  "EFFECT_PRESENT", "EFFECT_FRUSTRATION", "EFFECT_SAFEGUARD", "EFFECT_SACRED_FIRE",
  "EFFECT_MAGNITUDE", "EFFECT_BATON_PASS", "EFFECT_PURSUIT", "EFFECT_RAPID_SPIN",
  "EFFECT_UNUSED_82", "EFFECT_UNUSED_83", "EFFECT_MORNING_SUN", "EFFECT_SYNTHESIS",
  "EFFECT_MOONLIGHT", "EFFECT_HIDDEN_POWER", "EFFECT_RAIN_DANCE", "EFFECT_SUNNY_DAY",
  "EFFECT_DEFENSE_UP_HIT", "EFFECT_ATTACK_UP_HIT", "EFFECT_ALL_UP_HIT", "EFFECT_FAKE_OUT",
  "EFFECT_BELLY_DRUM", "EFFECT_PSYCH_UP", "EFFECT_MIRROR_COAT", "EFFECT_SKULL_BASH",
  "EFFECT_TWISTER", "EFFECT_EARTHQUAKE", "EFFECT_FUTURE_SIGHT", "EFFECT_GUST",
  "EFFECT_STOMP", "EFFECT_SOLARBEAM", "EFFECT_THUNDER", "EFFECT_TELEPORT",
  "EFFECT_BEAT_UP", "EFFECT_FLY", "EFFECT_DEFENSE_CURL",
}
M.CART_EFFECT_NUM = {}
for num = 0, #M.CART_EFFECTS do M.CART_EFFECT_NUM[M.CART_EFFECTS[num]] = num end

-- The referee's effect id back to the cart's number: every EFFECT_* name
-- Effects.idOf answers (one id each), the first one for 0 (NORMAL_HIT).  The
-- two Gold effects Effects.idOf folds to 0 are told apart by the move:
-- EFFECT_THIEF by its id (Items.THIEF, as Turn keys THIEF), EFFECT_PRIORITY_HIT
-- by GetMovePriority's 2 (Effects.movePriority: the K8 `priority` the client
-- stamps from the effect, or the move-id table), the only effect with that row
-- (data/moves/effects_priorities.asm).  No move carries EFFECT_UNUSED_2B or
-- EFFECT_DEFROST_OPPONENT, so their handlers below are the cart's table and
-- no referee id reaches them.
local FROM_REFEREE = {}
for num = 0, #M.CART_EFFECTS do
  local id = Effects.idOf(M.CART_EFFECTS[num])
  if id ~= nil and FROM_REFEREE[id] == nil then FROM_REFEREE[id] = num end
end
M.FROM_REFEREE = FROM_REFEREE

local function int(value, fallback)
  local n = tonumber(value)
  if not n or n ~= n then return fallback end
  return floor(n)
end

local function byte(value)
  return int(value, 0) % 256
end

-- The cart's effect number of a move record (-1: none the cart has).
function M.cartEffect(rec)
  if type(rec) ~= "table" then return -1 end
  local id = int(rec.effect, 0)
  if id == 0 then
    if Effects.moveKey(rec) == Items.THIEF then return M.CART_EFFECT_NUM.EFFECT_THIEF end
    if Effects.movePriority(rec) == 2 then return M.CART_EFFECT_NUM.EFFECT_PRIORITY_HIT end
    return 0
  end
  local num = FROM_REFEREE[id]
  if num == nil then return -1 end
  return num
end

local function set(list)
  local out = {}
  for _, key in ipairs(list) do out[key] = true end
  return out
end

local function effectSet(names)
  local out = {}
  for _, name in ipairs(names) do out[M.CART_EFFECT_NUM[name]] = true end
  return out
end

-- data/battle/ai/*.asm (pokecrystal and pokegold the same), the move lists by
-- move id and the effect lists by the cart's effect number.
M.STATUS_ONLY_EFFECTS = effectSet({
  "EFFECT_SLEEP", "EFFECT_TOXIC", "EFFECT_POISON", "EFFECT_PARALYZE",
})
M.USEFUL_MOVES = set({
  "DOUBLE_EDGE", "SING", "FLAMETHROWER", "HYDRO_PUMP", "SURF", "ICE_BEAM", "BLIZZARD",
  "HYPER_BEAM", "SLEEP_POWDER", "THUNDERBOLT", "THUNDER", "EARTHQUAKE", "TOXIC",
  "PSYCHIC_M", "HYPNOSIS", "RECOVER", "FIRE_BLAST", "SOFTBOILED", "SUPER_FANG",
})
M.ENCORE_MOVES = set({
  "SWORDS_DANCE", "WHIRLWIND", "LEER", "ROAR", "DISABLE", "MIST", "LEECH_SEED", "GROWTH",
  "POISONPOWDER", "STRING_SHOT", "MEDITATE", "AGILITY", "TELEPORT", "SCREECH", "HAZE",
  "FOCUS_ENERGY", "DREAM_EATER", "POISON_GAS", "SPLASH", "SHARPEN", "CONVERSION",
  "SUPER_FANG", "SUBSTITUTE", "TRIPLE_KICK", "SPIDER_WEB", "MIND_READER", "FLAME_WHEEL",
  "AEROBLAST", "COTTON_SPORE", "POWDER_SNOW",
})
M.RAIN_DANCE_MOVES = {
  "WATER_GUN", "HYDRO_PUMP", "SURF", "BUBBLEBEAM", "THUNDER", "WATERFALL", "CLAMP",
  "BUBBLE", "CRABHAMMER", "OCTAZOOKA", "WHIRLPOOL",
}
-- SunnyDayMoves without SOLARBEAM, FLAME_WHEEL and MOONLIGHT -- the cart's
-- list (docs/bugs_and_glitches.md, "Smart" AI does not encourage Sunny Day
-- when it knows Solar Beam, Flame Wheel, or Moonlight).
M.SUNNY_DAY_MOVES = {
  "FIRE_PUNCH", "EMBER", "FLAMETHROWER", "FIRE_SPIN", "FIRE_BLAST", "SACRED_FIRE",
  "MORNING_SUN", "SYNTHESIS",
}
M.STALL_MOVES = set({
  "SWORDS_DANCE", "TAIL_WHIP", "LEER", "GROWL", "DISABLE", "MIST", "COUNTER",
  "LEECH_SEED", "GROWTH", "STRING_SHOT", "MEDITATE", "AGILITY", "RAGE", "MIMIC",
  "SCREECH", "HARDEN", "WITHDRAW", "DEFENSE_CURL", "BARRIER", "LIGHT_SCREEN", "HAZE",
  "REFLECT", "FOCUS_ENERGY", "BIDE", "AMNESIA", "TRANSFORM", "SPLASH", "ACID_ARMOR",
  "SHARPEN", "CONVERSION", "SUBSTITUTE", "FLAME_WHEEL",
})
M.RECKLESS_EFFECTS = effectSet({
  "EFFECT_SELFDESTRUCT", "EFFECT_RAMPAGE", "EFFECT_MULTI_HIT", "EFFECT_DOUBLE_HIT",
})
M.CONSTANT_DAMAGE_EFFECTS = effectSet({
  "EFFECT_SUPER_FANG", "EFFECT_STATIC_DAMAGE", "EFFECT_LEVEL_DAMAGE", "EFFECT_PSYWAVE",
})
M.RESIDUAL_MOVES = set({
  "MIST", "LEECH_SEED", "POISONPOWDER", "STUN_SPORE", "THUNDER_WAVE", "FOCUS_ENERGY",
  "BIDE", "POISON_GAS", "TRANSFORM", "CONVERSION", "SUBSTITUTE", "SPIKES",
})
M.RISKY_EFFECTS = effectSet({ "EFFECT_SELFDESTRUCT", "EFFECT_OHKO" })

local E = M.CART_EFFECT_NUM

-- ------------------------------------------------------------------
-- the cart's state, read off the referee's
-- ------------------------------------------------------------------

-- The status byte (constants/battle_constants.asm): SLP_MASK's turns in bits
-- 0..2, PSN 3 (badly poisoned too: SUBSTATUS_TOXIC is a substatus), BRN 4,
-- FRZ 5, PAR 6.
local SLP_MASK, PSN_BIT, BRN_BIT, FRZ_BIT, PAR_BIT = 7, 8, 16, 32, 64
local function statusByte(mon)
  local s = mon and mon.status
  if s == "sleep" then return int(mon.statusTurns, 0) % 8 end
  if s == "poison" or s == "toxic" then return PSN_BIT end
  if s == "burn" then return BRN_BIT end
  if s == "freeze" then return FRZ_BIT end
  if s == "paralysis" then return PAR_BIT end
  return 0
end
M.statusByte = statusByte

local function band(a, b)
  local out, bit = 0, 1
  while a > 0 and b > 0 do
    if a % 2 == 1 and b % 2 == 1 then out = out + bit end
    a, b, bit = floor(a / 2), floor(b / 2), bit * 2
  end
  return out
end

local function sleepTurns(mon) return band(statusByte(mon), SLP_MASK) end

-- A stat level as the cart stores it: BASE_STAT_LEVEL plus the stage.
local function level(mon, key)
  return M.BASE_STAT_LEVEL + Effects.clampStage(mon.stages and mon.stages[key])
end

-- SUBSTATUS_TOXIC: badly poisoned, or HEAL BELL's cure left the bit
-- (`toxicLatent`, Turn `_healBell`).
local function toxic(mon)
  return mon.status == "toxic" or mon.toxicLatent == true
end

local function confused(mon) return int(mon.confusion, 0) > 0 end
local function rolling(mon)
  return type(mon.rollout) == "table" and mon.rollout.active == true
end

-- wBattleMonType1 / 2 (wEnemyMonType1 / 2): a monster that states one type
-- holds it in both bytes.
local function type1(mon) return int(mon.types and mon.types[1], 0) end
local function type2(mon)
  local t = mon.types and mon.types[2]
  if t == nil then return type1(mon) end
  return int(t, 0)
end

local function typeName(ctx, t)
  if t == nil then return nil end
  return ctx.battle:_typeIdOf(t)
end

-- `cp SPECIAL / jr nc`: the referee's split (ruleset `specialTypes`), which
-- EnemyAttackDamage's own `cp SPECIAL` reads in `_damageStats` as well.
local function special(ctx, t)
  return Effects.isSpecialType(t, ctx.battle.specialTypes)
end

-- The referee's stat snapshot put back as it was: Effects.storedStat clears a
-- stale one as it reads, and AIChooseMove reads -- it never rebuilds a stat.
local function keepSnap(mon, snap)
  if mon.statSnap ~= snap then mon.statSnap = snap end
end

-- A battle stat (wBattleMonSpeed / wEnemyMonSpeed).
local function speedOf(ctx, fighter, mon)
  local snap = mon.statSnap
  local value = ctx.battle:_speedOf(fighter, mon)
  keepSnap(mon, snap)
  return int(value, 0)
end

local function typeIndexOf(typeIds, name)
  if type(typeIds) ~= "table" or type(name) ~= "string" then return nil end
  for i = 1, #typeIds do
    if typeIds[i] == name then return i - 1 end
  end
  return nil
end

-- A move record's type: its chart index -- or, for the STRUGGLE sentinel
-- (Turn's, whose `type` is a placeholder), the index of its row's NORMAL.
local function recType(ctx, rec)
  if rec.typeId then
    local index = typeIndexOf(ctx.battle.typeIds, rec.typeId)
    if index ~= nil then return index end
  end
  return int(rec.type, 0)
end

-- AIGetEnemyMove: the move's row copied into wEnemyMoveStruct -- here the
-- record itself, its type and its cart effect.  Every caller that loads a
-- move loads it here, so `ctx.cur` is the struct's contents at every read.
local function load(ctx, rec)
  ctx.cur = {
    rec = rec,
    id = Effects.moveKey(rec),
    effect = M.cartEffect(rec),
    power = byte(rec.power),
    type = recType(ctx, rec),
    acc = byte(rec.accuracy),
  }
  return ctx.cur
end

-- The four move slots (wEnemyMonMoves): a record or nil (move 0).
local function slot(ctx, i)
  local moves = ctx.mon.moves
  local rec = type(moves) == "table" and moves[i] or nil
  if type(rec) ~= "table" then return nil end
  return rec
end

-- ------------------------------------------------------------------
-- the HP and speed checks (scoring.asm AICheck*, AICompareSpeed)
-- ------------------------------------------------------------------

-- AICheck*HalfHP / *QuarterHP: carry when the HP doubled (twice: x4) as a
-- 16-bit `sla` / `rl` pair is above the max HP -- above half (a quarter).
local function above(mon, shift)
  return (int(mon.hp, 0) * shift) % 65536 > int(mon.maxHp, 0) % 65536
end
local function enemyHalf(ctx) return above(ctx.mon, 2) end
local function enemyQuarter(ctx) return above(ctx.mon, 4) end
local function playerHalf(ctx) return above(ctx.foeMon, 2) end
local function playerQuarter(ctx) return above(ctx.foeMon, 4) end
-- AICheckMaxHP: carry when both HP bytes match the max HP's.
local function enemyMax(ctx)
  return int(ctx.mon.hp, 0) % 65536 == int(ctx.mon.maxHp, 0) % 65536
end
local function playerMax(ctx)
  return int(ctx.foeMon.hp, 0) % 65536 == int(ctx.foeMon.maxHp, 0) % 65536
end

-- AICompareSpeed: carry when the enemy is strictly faster.
local function enemyFaster(ctx)
  return speedOf(ctx, ctx.fighter, ctx.mon) > speedOf(ctx, ctx.foe, ctx.foeMon)
end

-- FindAliveEnemyMons (engine/battle/ai/switch.asm): carry when no other
-- monster of the computer's party has HP -- wOTPartyCount under 2, or every
-- one but wCurOTMon at 0.  The seat's own party is the cart's wOTParty.
local function enemyLastMon(ctx)
  local mons = ctx.fighter.mons
  if #mons < 2 then return true end
  for i = 1, #mons do
    if i ~= ctx.fighter.active and int(mons[i].hp, 0) ~= 0 then return false end
  end
  return true
end

-- AICheckLastPlayerMon: nz (true here) when another monster of the player's
-- party than wCurBattleMon has HP.
local function playerHasOthers(ctx)
  local mons = ctx.foe.mons
  for i = 1, #mons do
    if i ~= ctx.foe.active and int(mons[i].hp, 0) ~= 0 then return true end
  end
  return false
end

-- AIHasMoveEffect: carry when one of the enemy's moves has effect `effect`,
-- each loaded through AIGetEnemyMove on the way (wEnemyMoveStruct is left on
-- the last one looked at).
local function hasMoveEffect(ctx, effect)
  for i = 1, M.NUM_MOVES do
    local rec = slot(ctx, i)
    if not rec then return false end
    if load(ctx, rec).effect == effect then return true end
  end
  return false
end

-- AIHasMoveInArray: carry when the enemy knows a move of the list, which is
-- walked in its own order (no wEnemyMoveStruct load).
local function hasMoveInArray(ctx, list)
  for _, id in ipairs(list) do
    for i = 1, M.NUM_MOVES do
      local rec = slot(ctx, i)
      if rec and Effects.moveKey(rec) == id then return true end
    end
  end
  return false
end

-- ------------------------------------------------------------------
-- the draws
-- ------------------------------------------------------------------

local function random(ctx)
  ctx.draws = ctx.draws + 1
  return ctx.battle.rng:byte()
end

-- AI_80_20 (`cp 20 percent - 1`) and AI_50_50 (`cp 50 percent + 1`): carry
-- -- the "skip" -- on the low byte.
local function ai8020(ctx) return random(ctx) < P20M1 end
local function ai5050(ctx) return random(ctx) < P50P1 end

-- ------------------------------------------------------------------
-- the score bytes (wEnemyAIMoveScores)
-- ------------------------------------------------------------------

local function add(ctx, i, n)
  ctx.scores[i] = (ctx.scores[i] + n) % 256
end
local function dismiss(ctx, i) add(ctx, i, M.DISMISS) end   -- AIDiscourageMove

-- ------------------------------------------------------------------
-- type matchups
-- ------------------------------------------------------------------

-- CheckTypeMatchup's wTypeMatchup: EFFECTIVE (10), times each TypeMatchups
-- row of the attacking type that names either defending type (a monster with
-- one type matches its row once), over 10 -- from the referee's chart, a
-- percent per cell (`_matchupCell`, which also skips the Foresight rows for an
-- identified defender).  `identified` is BATTLE_VARS_SUBSTATUS1_OPP's bit,
-- which follows hBattleTurn, not the defender.  A type of nil is a byte that
-- names no row (AI_Smart_Conversion2's): EFFECTIVE.
local function matchupStep(ctx, m, t, defType, probe)
  local pct = int(ctx.battle:_matchupCell(t, defType, probe), 100)
  -- A cell under 0 is no row the cart can hold: an immunity, as the hit's own
  -- `_typePercents` reads it.
  if pct < 0 then pct = 0 end
  return floor(m * floor(pct / 10) / 10)
end

local function matchup(ctx, t, defType1, defType2, identified)
  if t == nil then return M.EFFECTIVE end
  local probe = { identified = identified == true }
  local m = matchupStep(ctx, M.EFFECTIVE, t, defType1, probe)
  if defType2 ~= defType1 then m = matchupStep(ctx, m, t, defType2, probe) end
  return m % 256
end

-- BATTLE_VARS_MOVE_TYPE and BATTLE_VARS_SUBSTATUS1_OPP's IDENTIFIED bit,
-- through hBattleTurn: the enemy's move struct and the player's bit on 1, the
-- player's move struct (`ctx.playerMoveType`) and the enemy's bit on 0.
local function moveType(ctx)
  if ctx.turn == 1 then return ctx.cur and ctx.cur.type end
  return ctx.playerMoveType
end
local function oppIdentified(ctx)
  if ctx.turn == 1 then return ctx.foeMon.identified == true end
  return ctx.mon.identified == true
end

-- CheckTypeMatchup with hl at a defender's types, the move type read through
-- hBattleTurn (the AI's "false assumption": a type placed in `a` is ignored).
local function checkTypeMatchup(ctx, defender)
  return matchup(ctx, moveType(ctx), type1(defender), type2(defender), oppIdentified(ctx))
end

-- BattleCheckTypeMatchup: the player's types on hBattleTurn 1, the enemy's
-- on 0.
local function battleCheckTypeMatchup(ctx)
  if ctx.turn == 1 then return checkTypeMatchup(ctx, ctx.foeMon) end
  return checkTypeMatchup(ctx, ctx.mon)
end

-- CheckPlayerMoveTypeMatchups (engine/battle/ai/switch.asm) as AI_Smart calls
-- it: wEnemyAISwitchScore from BASE_AI_SWITCH_SCORE.  Every CheckTypeMatchup
-- in it reads BATTLE_VARS_MOVE_TYPE -- the move being scored, on hBattleTurn
-- 1 -- not the type GetMoveByte put in `a`, so the player's moves are each
-- "that type against the enemy" and the enemy's moves "that type against the
-- player"; only their powers count which branch runs.
local function checkPlayerMoveTypeMatchups(ctx)
  local score = M.BASE_AI_SWITCH_SCORE
  local foeMon, mon = ctx.foeMon, ctx.mon
  local used = type(foeMon.usedMoves) == "table" and foeMon.usedMoves or {}
  if not used[1] then
    -- `.unknown_moves`: the player's types -- each CheckTypeMatchup the same.
    if checkTypeMatchup(ctx, mon) >= M.EFFECTIVE + 1 then score = score - 1 end
    if type2(foeMon) ~= type1(foeMon) then
      if checkTypeMatchup(ctx, mon) >= M.EFFECTIVE + 1 then score = score - 1 end
    end
  else
    local e, done = 0, false
    for i = 1, M.NUM_MOVES do
      local rec = M.usedMove(foeMon, used[i])
      if not rec then break end
      if byte(rec.power) ~= 0 then
        local m = checkTypeMatchup(ctx, mon)
        if m >= M.EFFECTIVE + 1 then
          score = score - 1
          done = true
          break
        end
        if m ~= 0 then
          if m >= M.EFFECTIVE then
            e = 2
          elseif e < 1 then
            e = 1
          end
        end
      end
    end
    if not done and e ~= 2 then
      score = score + 1
      if e == 0 then score = score + 1 end
    end
  end
  -- `.CheckEnemyMoveMatchups`: one `inc c` for a not-very-effective move,
  -- five more for a neutral one, `ld c, 100` for a super-effective one.
  local c = 0
  for i = 1, M.NUM_MOVES do
    local rec = slot(ctx, i)
    if not rec then break end
    if byte(rec.power) ~= 0 then
      local m = checkTypeMatchup(ctx, foeMon)
      if m ~= 0 then
        c = (c + 1) % 256
        if m >= M.EFFECTIVE then
          c = (c + 5) % 256
          if m ~= M.EFFECTIVE then c = 100 end
        end
      end
    end
  end
  if c == 0 then
    score = score - 2
  elseif c < 5 then
    score = score - 1
  elseif c >= 100 then
    score = score + 1
  end
  return score % 256
end

-- A wPlayerUsedMoves entry -- a move id the cart reads the Moves table by
-- (AIGetEnemyMove, GetMoveAttr) -- as a move record: the row of the player's
-- monster's own move with that id (its sheet row is the table's), else the
-- entry itself when it is a record (a move the sheet no longer holds: a
-- METRONOME call, STRUGGLE), else power 0, type 0, effect 0.
function M.usedMove(mon, entry)
  if entry == nil or entry == false then return nil end
  local key = Effects.moveKey(entry)
  if key ~= "" then
    for _, rec in ipairs(type(mon.moves) == "table" and mon.moves or {}) do
      if type(rec) == "table" and Effects.moveKey(rec) == key then return rec end
    end
  end
  if type(entry) == "table" then return entry end
  if key == "" then return nil end
  return { id = key, power = 0, type = 0, effect = 0, accuracy = 255 }
end

-- ------------------------------------------------------------------
-- AIDamageCalc
-- ------------------------------------------------------------------

-- AIDamageCalc (scoring.asm), hBattleTurn 1: the ConstantDamageEffects
-- through BattleCommand_ConstantDamage (Effects.fixedDamage: SUPER FANG's
-- half of the player's HP, LEVEL_DAMAGE's level, PSYWAVE's BattleRandom loop
-- -- drawn here -- and STATIC_DAMAGE's power), every other one through
-- EnemyAttackDamage, BattleCommand_DamageCalc and BattleCommand_Stab: the
-- referee's own stat pick (`_damageStats`: screens, TruncateHL_BC by family,
-- Thick Club / Light Ball, Metal Powder, Explosion's halving), no critical
-- (wCriticalHit is 0 between turns: every script's `criticaltext` or
-- failure text clears it), the type-boost item, the weather, STAB and the
-- matchup rows -- no badge boost (DoBadgeTypeBoosts returns on the enemy's
-- turn) and no DamageVariation.  The power is the move's row (wEnemyMoveStruct
-- + MOVE_POWER), so HIDDEN POWER, RETURN and the like count their table power.
local function damageCalc(ctx, constant)
  ctx.turn = 1
  local cur = ctx.cur
  if constant and M.CONSTANT_DAMAGE_EFFECTS[cur.effect] then
    local fixed = Effects.fixedDamage({
      effectId = int(cur.rec.effect, 0), userMon = ctx.mon, targetMon = ctx.foeMon,
      power = cur.power, rng = ctx.counter,
    })
    return int(fixed, 0) % 65536
  end
  local battle, mon, foeMon = ctx.battle, ctx.mon, ctx.foeMon
  local snapA, snapB = mon.statSnap, foeMon.statSnap
  local effectId = int(cur.rec.effect, 0)
  local attack, defense = battle:_damageStats(ctx.fighter, mon, ctx.foe, foeMon,
    cur.type, effectId, false)
  keepSnap(mon, snapA)
  keepSnap(foeMon, snapB)
  local name = typeName(ctx, cur.type)
  local d = Damage.calc(mon.level, cur.power, attack, defense, {
    itemBoostPercent = Items.typeBoostPercent(mon, name),
  }) or 0
  d = Damage.stab(d, {
    weatherTenths = Effects.weatherTenths(battle:_weatherKind(), name, effectId),
    badgeTypeBoost = false,
    stab = cur.type == type1(mon) or cur.type == type2(mon),
    typeEffect = battle:_typePercents(cur.type, foeMon),
  })
  return int(d, 0) % 65536
end

-- ------------------------------------------------------------------
-- AI_Redundant (engine/battle/ai/redundant.asm): true for "nz", a move that
-- fails because it is already in place.
-- ------------------------------------------------------------------

local function screens(ctx, fighter)
  return ctx.battle.screens and ctx.battle.screens[fighter.side] or {}
end

local function weather(ctx) return ctx.battle:_weatherKind() end

local REDUNDANT = {}
REDUNDANT[E.EFFECT_DREAM_EATER] = function(ctx) return sleepTurns(ctx.foeMon) == 0 end
local function redundantHeal(ctx) return enemyMax(ctx) end
REDUNDANT[E.EFFECT_HEAL] = redundantHeal
REDUNDANT[E.EFFECT_MORNING_SUN] = redundantHeal
REDUNDANT[E.EFFECT_SYNTHESIS] = redundantHeal
REDUNDANT[E.EFFECT_MOONLIGHT] = redundantHeal
REDUNDANT[E.EFFECT_LIGHT_SCREEN] = function(ctx)
  return int(screens(ctx, ctx.fighter).lightScreen, 0) > 0
end
REDUNDANT[E.EFFECT_MIST] = function(ctx) return ctx.mon.mist == true end
REDUNDANT[E.EFFECT_FOCUS_ENERGY] = function(ctx) return ctx.mon.focusEnergy == true end
REDUNDANT[E.EFFECT_CONFUSE] = function(ctx)
  if confused(ctx.foeMon) then return true end
  return int(screens(ctx, ctx.foe).safeguard, 0) > 0
end
REDUNDANT[E.EFFECT_TRANSFORM] = function(ctx) return ctx.mon.transformed == true end
REDUNDANT[E.EFFECT_REFLECT] = function(ctx)
  return int(screens(ctx, ctx.fighter).reflect, 0) > 0
end
REDUNDANT[E.EFFECT_SUBSTITUTE] = function(ctx) return int(ctx.mon.substitute, 0) > 0 end
REDUNDANT[E.EFFECT_LEECH_SEED] = function(ctx) return ctx.foeMon.leechSeed ~= nil end
-- wPlayerDisableCount: the slot and the count, 0 once it runs out.
REDUNDANT[E.EFFECT_DISABLE] = function(ctx)
  local d = ctx.foeMon.disable
  return type(d) == "table" and int(d.turns, 0) > 0
end
REDUNDANT[E.EFFECT_ENCORE] = function(ctx) return ctx.foeMon.encore ~= nil end
local function redundantSnore(ctx) return sleepTurns(ctx.mon) == 0 end
REDUNDANT[E.EFFECT_SNORE] = redundantSnore
REDUNDANT[E.EFFECT_SLEEP_TALK] = redundantSnore
-- `.MeanLook`: the ENEMY's own SUBSTATUS_CANT_RUN -- the bit is the user's,
-- "the opponent can't run" (BattleCommand_ArenaTrap), Turn's `meanLook`.
REDUNDANT[E.EFFECT_MEAN_LOOK] = function(ctx) return ctx.mon.meanLook ~= nil end
-- `.Nightmare`: any status at all passes (docs/bugs_and_glitches.md, "AI does
-- not discourage Nightmare if the player has any status condition").
REDUNDANT[E.EFFECT_NIGHTMARE] = function(ctx)
  if statusByte(ctx.foeMon) == 0 then return true end
  return ctx.foeMon.nightmare == true
end
REDUNDANT[E.EFFECT_SPIKES] = function(ctx) return screens(ctx, ctx.foe).spikes == true end
REDUNDANT[E.EFFECT_FORESIGHT] = function(ctx) return ctx.foeMon.identified == true end
REDUNDANT[E.EFFECT_PERISH_SONG] = function(ctx) return ctx.foeMon.perish ~= nil end
REDUNDANT[E.EFFECT_SANDSTORM] = function(ctx) return weather(ctx) == "sandstorm" end
-- `.Attract`: CheckOppositeGender's carry (genderless, unknown or the same
-- gender -- Effects.gender, the player's party monster against the enemy's
-- backup DVs), then the player's SUBSTATUS_IN_LOVE.
REDUNDANT[E.EFFECT_ATTRACT] = function(ctx)
  local mine, theirs = Effects.gender(ctx.foeMon), Effects.gender(ctx.mon)
  if not mine or not theirs or mine == theirs then return true end
  return ctx.foeMon.inLove ~= nil
end
REDUNDANT[E.EFFECT_SAFEGUARD] = function(ctx)
  return int(screens(ctx, ctx.fighter).safeguard, 0) > 0
end
REDUNDANT[E.EFFECT_RAIN_DANCE] = function(ctx) return weather(ctx) == "rain" end
REDUNDANT[E.EFFECT_SUNNY_DAY] = function(ctx) return weather(ctx) == "sun" end
REDUNDANT[E.EFFECT_TELEPORT] = function() return true end
REDUNDANT[E.EFFECT_SWAGGER] = function(ctx) return confused(ctx.foeMon) end
-- `.FutureSight` reads SCREENS_UNUSED, a bit nothing sets: never redundant
-- (docs/bugs_and_glitches.md, "AI does not discourage Future Sight when it's
-- already been used").
REDUNDANT[E.EFFECT_FUTURE_SIGHT] = function() return false end
M.REDUNDANT = REDUNDANT

-- ------------------------------------------------------------------
-- the layers
-- ------------------------------------------------------------------

-- Every layer walks wEnemyMonMoves from the first slot and stops at the first
-- empty one (`ld a, [de] / and a / ret z`).

-- AI_Basic: AI_Redundant's moves, then the status-only effects against a
-- statused or Safeguarded player.
local function aiBasic(ctx)
  for i = 1, M.NUM_MOVES do
    local rec = slot(ctx, i)
    if not rec then return end
    local cur = load(ctx, rec)
    local redundant = REDUNDANT[cur.effect]
    if redundant and redundant(ctx) then
      dismiss(ctx, i)
    elseif M.STATUS_ONLY_EFFECTS[cur.effect] then
      if statusByte(ctx.foeMon) ~= 0 or int(screens(ctx, ctx.foe).safeguard, 0) > 0 then
        dismiss(ctx, i)
      end
    end
  end
end

-- AI_Setup: the stat-up effects (EFFECT_ATTACK_UP..EFFECT_EVASION_UP and the
-- _2 block) on the enemy's first turn and the stat-down ones on the player's
-- -- the `jr z` after each `cp ..._UP + 1` skips ALWAYS_HIT (17) and
-- TRANSFORM (57) -- greatly encouraged half the time, greatly discouraged
-- otherwise unless the byte is under 12 percent.
local function aiSetup(ctx)
  for i = 1, M.NUM_MOVES do
    local rec = slot(ctx, i)
    if not rec then return end
    local e = load(ctx, rec).effect
    local kind = nil
    if e >= E.EFFECT_ATTACK_UP and e <= E.EFFECT_EVASION_UP then
      kind = "up"
    elseif e >= E.EFFECT_ATTACK_DOWN and e <= E.EFFECT_EVASION_DOWN then
      kind = "down"
    elseif e >= E.EFFECT_ATTACK_UP_2 and e <= E.EFFECT_EVASION_UP_2 then
      kind = "up"
    elseif e >= E.EFFECT_ATTACK_DOWN_2 and e <= E.EFFECT_EVASION_DOWN_2 then
      kind = "down"
    end
    if kind then
      local turns = (kind == "up") and M.turnsTaken(ctx.mon) or M.turnsTaken(ctx.foeMon)
      if turns ~= 0 then
        if random(ctx) >= P12 then add(ctx, i, 2) end
      elseif not ai5050(ctx) then
        add(ctx, i, -2)
      end
    end
  end
end

-- AI_Types: dismiss what the player is immune to, encourage a super-effective
-- damaging move, discourage a not-very-effective one when another move of a
-- different type does damage (that scan loads each of those moves).
local function aiTypes(ctx)
  for i = 1, M.NUM_MOVES do
    local rec = slot(ctx, i)
    if not rec then return end
    local cur = load(ctx, rec)
    ctx.turn = 1
    local m = battleCheckTypeMatchup(ctx)
    if m == 0 then
      dismiss(ctx, i)
    elseif m > M.EFFECTIVE then
      if cur.power ~= 0 then add(ctx, i, -1) end
    elseif m < M.EFFECTIVE then
      local d = cur.type
      local c = 0
      for j = 1, M.NUM_MOVES do
        local other = slot(ctx, j)
        if not other then break end
        local o = load(ctx, other)
        if o.type ~= d and o.power ~= 0 then
          c = o.power
          break
        end
      end
      if c ~= 0 then add(ctx, i, 1) end
    end
  end
end

-- AI_Offensive: greatly discourage every move with no power.
local function aiOffensive(ctx)
  for i = 1, M.NUM_MOVES do
    local rec = slot(ctx, i)
    if not rec then return end
    if load(ctx, rec).power == 0 then add(ctx, i, 2) end
  end
end

-- AI_Opportunist: at or under half HP, half the time (always at or under a
-- quarter), discourage the StallMoves.
local function aiOpportunist(ctx)
  if enemyHalf(ctx) then return end
  if enemyQuarter(ctx) and ai5050(ctx) then return end
  for i = 1, M.NUM_MOVES do
    local rec = slot(ctx, i)
    if not rec then return end
    if M.STALL_MOVES[Effects.moveKey(rec)] then add(ctx, i, 1) end
  end
end

-- AI_Aggressive: the damaging move AIDamageCalc rates highest (a later tie
-- wins: `jr c` on below only; any damaging move beats the 0 it starts from,
-- an immune one included), then every other move with power 2 or more that is
-- not a RecklessMoves effect is discouraged.  The second walk does not stop
-- at an empty slot -- it loads move 0 there, AIGetEnemyMove reading past the
-- Moves table -- but whatever it adds to an empty slot's score is never read
-- (`.loop2` zeroes it), so the empty slots are skipped.
local function aiAggressive(ctx)
  local best, bestSlot = 0, 0
  for i = 1, M.NUM_MOVES do
    local rec = slot(ctx, i)
    if not rec then break end
    if load(ctx, rec).power ~= 0 then
      local dmg = damageCalc(ctx, true)
      if dmg >= best then
        best, bestSlot = dmg, i
      end
    end
  end
  if bestSlot == 0 then return end
  for i = 1, M.NUM_MOVES do
    local rec = slot(ctx, i)
    if i ~= bestSlot and rec then
      local cur = load(ctx, rec)
      if cur.power >= 2 and not M.RECKLESS_EFFECTS[cur.effect] then add(ctx, i, 1) end
    end
  end
end

-- AI_Cautious: after the enemy's first turn, 90% of the time discourage each
-- ResidualMoves move -- and a byte at or past `90 percent + 1` ends the whole
-- layer (`ret nc`, docs/bugs_and_glitches.md: "Cautious" AI may fail to
-- discourage residual moves).
local function aiCautious(ctx)
  if M.turnsTaken(ctx.mon) == 0 then return end
  for i = 1, M.NUM_MOVES do
    local rec = slot(ctx, i)
    if not rec then return end
    if M.RESIDUAL_MOVES[Effects.moveKey(rec)] then
      if random(ctx) >= P90P1 then return end
      add(ctx, i, 1)
    end
  end
end

-- AI_Status: dismiss TOXIC / POISON against a Poison type, and SLEEP,
-- PARALYZE and every damaging move against a type the matchup makes immune.
local function aiStatus(ctx)
  for i = 1, M.NUM_MOVES do
    local rec = slot(ctx, i)
    if not rec then return end
    local cur = load(ctx, rec)
    local e = cur.effect
    local check = false
    if e == E.EFFECT_TOXIC or e == E.EFFECT_POISON then
      if typeName(ctx, type1(ctx.foeMon)) == "POISON"
         or typeName(ctx, type2(ctx.foeMon)) == "POISON" then
        dismiss(ctx, i)
      else
        check = true
      end
    elseif e == E.EFFECT_SLEEP or e == E.EFFECT_PARALYZE then
      check = true
    elseif cur.power ~= 0 then
      check = true
    end
    if check then
      ctx.turn = 1
      if battleCheckTypeMatchup(ctx) == 0 then dismiss(ctx, i) end
    end
  end
end

-- AI_Risky: a damaging move AIDamageCalc rates past the player's HP (strictly:
-- `sbc` with no carry on equal) is encouraged by 5 -- but a RiskyEffects move
-- (SELFDESTRUCT, OHKO) is left alone at max HP, and below it 80% of the time,
-- before its damage is counted.
local function aiRisky(ctx)
  for i = 1, M.NUM_MOVES do
    local rec = slot(ctx, i)
    if not rec then return end
    local cur = load(ctx, rec)
    if cur.power ~= 0 then
      local skip = false
      if M.RISKY_EFFECTS[cur.effect] then
        if enemyMax(ctx) then
          skip = true
        elseif random(ctx) < P79M1 then
          skip = true
        end
      end
      if not skip then
        local dmg = damageCalc(ctx, true)
        if int(ctx.foeMon.hp, 0) % 65536 < dmg then add(ctx, i, -5) end
      end
    end
  end
end

-- ------------------------------------------------------------------
-- AI_Smart's handlers (scoring.asm AI_Smart_EffectHandlers), by effect
-- ------------------------------------------------------------------

local SMART = {}
M.SMART = SMART

SMART[E.EFFECT_SLEEP] = function(ctx, i)
  if hasMoveEffect(ctx, E.EFFECT_DREAM_EATER) or hasMoveEffect(ctx, E.EFFECT_NIGHTMARE) then
    if not ai5050(ctx) then add(ctx, i, -2) end
  end
end

SMART[E.EFFECT_LEECH_HIT] = function(ctx, i)
  ctx.turn = 1
  local m = battleCheckTypeMatchup(ctx)
  if m < M.EFFECTIVE then
    if random(ctx) >= P39P1 then add(ctx, i, 1) end
    return
  end
  if m == M.EFFECTIVE then return end
  if enemyMax(ctx) then return end
  if not ai8020(ctx) then add(ctx, i, -1) end
end

SMART[E.EFFECT_LOCK_ON] = function(ctx, i)
  if ctx.foeMon.lockOn == true then
    -- `.player_locked_on`: every move under 70 percent accuracy greatly
    -- encouraged, then this one dismissed.
    for j = 1, M.NUM_MOVES do
      local rec = slot(ctx, j)
      if not rec then break end
      if load(ctx, rec).acc < P71M1 then add(ctx, j, -2) end
    end
    dismiss(ctx, i)
    return
  end
  if not enemyQuarter(ctx) then add(ctx, i, 1); return end
  if not enemyHalf(ctx) and not enemyFaster(ctx) then add(ctx, i, 1); return end
  local encourage = false
  local pe, ea = level(ctx.foeMon, "eva"), level(ctx.mon, "acc")
  if pe >= M.BASE_STAT_LEVEL + 3 then
    encourage = true
  elseif pe >= M.BASE_STAT_LEVEL + 1 then
    return
  elseif ea < M.BASE_STAT_LEVEL - 2 then
    encourage = true
  elseif ea < M.BASE_STAT_LEVEL then
    return
  else
    for j = 1, M.NUM_MOVES do
      local rec = slot(ctx, j)
      if not rec then break end
      if load(ctx, rec).acc < P71M1 then
        ctx.turn = 1
        if battleCheckTypeMatchup(ctx) >= M.EFFECTIVE then return end
      end
    end
    add(ctx, i, 1)
    return
  end
  if encourage and not ai5050(ctx) then add(ctx, i, -2) end
end

-- Crystal first asks whether this is the enemy's last monster and the
-- player's is not; Gold and Silver do not (pokegold scoring.asm).
SMART[E.EFFECT_SELFDESTRUCT] = function(ctx, i)
  if ctx.family == "crystal" and enemyLastMon(ctx) and playerHasOthers(ctx) then
    add(ctx, i, 3)
    return
  end
  if enemyHalf(ctx) then add(ctx, i, 3); return end
  if not enemyQuarter(ctx) then return end
  if random(ctx) < P8 then return end
  add(ctx, i, 3)
end

SMART[E.EFFECT_DREAM_EATER] = function(ctx, i)
  if random(ctx) < P10 then return end
  add(ctx, i, -3)
end

-- `.EvasionUp` / `.AccuracyDown` share one shape; `hpMax` / `hpHalf` /
-- `hpQuarter` are the enemy's HP for EVASION UP and the player's for ACCURACY
-- DOWN (whose first gate also wants the enemy above half).
local function evasionShape(ctx, i, first, hpHalf, hpQuarter)
  local greatly = false
  local notEncouraged = false
  if first then
    if toxic(ctx.foeMon) then
      greatly = true
    elseif random(ctx) >= P70 then
      notEncouraged = true
    else
      greatly = true
    end
  else
    local mismatch2 = false
    if not hpQuarter(ctx) then
      mismatch2 = true
    elseif random(ctx) < P4 then
      greatly = true
    elseif not hpHalf(ctx) then
      if ai5050(ctx) then notEncouraged = true else mismatch2 = true end
    elseif ai8020(ctx) then
      greatly = true
    else
      notEncouraged = true
    end
    if mismatch2 then
      add(ctx, i, 2)
      notEncouraged = true
    end
  end
  if greatly then add(ctx, i, -2); return end
  if not notEncouraged then return end
  -- `.not_encouraged`.
  if toxic(ctx.foeMon) then
    if random(ctx) < P31P1 then return end
    add(ctx, i, -2)
    return
  end
  if ctx.foeMon.leechSeed ~= nil then
    if not ai5050(ctx) then add(ctx, i, -1) end
    return
  end
  if level(ctx.foeMon, "acc") < level(ctx.mon, "eva") then add(ctx, i, 1); return end
  if byte(ctx.foeMon.furyCutter) ~= 0 or rolling(ctx.foeMon) then add(ctx, i, -2); return end
  add(ctx, i, 1)
end

SMART[E.EFFECT_EVASION_UP] = function(ctx, i)
  if level(ctx.mon, "eva") >= M.MAX_STAT_LEVEL then dismiss(ctx, i); return end
  evasionShape(ctx, i, enemyMax(ctx), enemyHalf, enemyQuarter)
end

SMART[E.EFFECT_ALWAYS_HIT] = function(ctx, i)
  if level(ctx.mon, "acc") >= M.BASE_STAT_LEVEL - 2
     and level(ctx.foeMon, "eva") < M.BASE_STAT_LEVEL + 3 then
    return
  end
  if not ai8020(ctx) then add(ctx, i, -2) end
end

SMART[E.EFFECT_MIRROR_MOVE] = function(ctx, i)
  local last = ctx.foeMon.lastCounterMove
  if not last then
    if not enemyFaster(ctx) then return end
    dismiss(ctx, i)
    return
  end
  if not M.USEFUL_MOVES[Effects.moveKey(last)] then return end
  if ai5050(ctx) then return end
  add(ctx, i, -1)
  if not enemyFaster(ctx) then return end
  if random(ctx) < P10 then return end
  add(ctx, i, -1)
end

SMART[E.EFFECT_ACCURACY_DOWN] = function(ctx, i)
  evasionShape(ctx, i, playerMax(ctx) and enemyHalf(ctx), playerHalf, playerQuarter)
end

-- `.enemystatsloop` / `.playerstatsloop`: `ld c, NUM_LEVEL_STATS` (8) with a
-- `dec c` before each read -- the seven levels, Attack to Evasion.
local STAT_LEVEL_KEYS = { "atk", "def", "spe", "spa", "spd", "acc", "eva" }
SMART[E.EFFECT_RESET_STATS] = function(ctx, i)
  local encourage = false
  for _, key in ipairs(STAT_LEVEL_KEYS) do
    if level(ctx.mon, key) < M.BASE_STAT_LEVEL - 2 then encourage = true; break end
  end
  if not encourage then
    for _, key in ipairs(STAT_LEVEL_KEYS) do
      if level(ctx.foeMon, key) >= M.BASE_STAT_LEVEL + 3 then encourage = true; break end
    end
  end
  if not encourage then add(ctx, i, 1); return end
  if random(ctx) < P16 then return end
  add(ctx, i, -1)
end

SMART[E.EFFECT_BIDE] = function(ctx, i)
  if enemyMax(ctx) then return end
  if random(ctx) < P10 then return end
  add(ctx, i, 1)
end

local function switchScoreDiscourage(ctx, i)
  if checkPlayerMoveTypeMatchups(ctx) < M.BASE_AI_SWITCH_SCORE then return end
  add(ctx, i, 1)
end
SMART[E.EFFECT_FORCE_SWITCH] = switchScoreDiscourage
SMART[E.EFFECT_BATON_PASS] = switchScoreDiscourage

local function smartHeal(ctx, i)
  if not enemyQuarter(ctx) then
    if random(ctx) < P10 then return end
    add(ctx, i, -2)
    return
  end
  if not enemyHalf(ctx) then return end
  add(ctx, i, 1)
end
SMART[E.EFFECT_HEAL] = smartHeal
SMART[E.EFFECT_MORNING_SUN] = smartHeal
SMART[E.EFFECT_SYNTHESIS] = smartHeal
SMART[E.EFFECT_MOONLIGHT] = smartHeal

local function smartToxic(ctx, i)
  if playerHalf(ctx) then return end
  add(ctx, i, 1)
end
SMART[E.EFFECT_TOXIC] = smartToxic
SMART[E.EFFECT_LEECH_SEED] = smartToxic

local function smartScreen(ctx, i)
  if enemyMax(ctx) then return end
  if random(ctx) < P8 then return end
  add(ctx, i, 1)
end
SMART[E.EFFECT_LIGHT_SCREEN] = smartScreen
SMART[E.EFFECT_REFLECT] = smartScreen

SMART[E.EFFECT_OHKO] = function(ctx, i)
  if byte(ctx.mon.level) < byte(ctx.foeMon.level) then dismiss(ctx, i); return end
  if playerHalf(ctx) then return end
  add(ctx, i, 1)
end

-- wPlayerSubStatus1's IN_LOVE | ROLLOUT | IDENTIFIED | NIGHTMARE mask.
local function playerHeld(ctx)
  local m = ctx.foeMon
  return m.inLove ~= nil or rolling(m) or m.identified == true or m.nightmare == true
end

SMART[E.EFFECT_TRAP_TARGET] = function(ctx, i)
  local trapped = ctx.foeMon.trapped
  local encourage = false
  if not (type(trapped) == "table" and int(trapped.turns, 0) % 256 ~= 0) then
    encourage = toxic(ctx.foeMon) or playerHeld(ctx) or M.turnsTaken(ctx.foeMon) == 0
  end
  if not encourage then
    if not ai5050(ctx) then add(ctx, i, 1) end
    return
  end
  if not enemyQuarter(ctx) then return end
  if ai5050(ctx) then return end
  add(ctx, i, -2)
end

local function smartRazorWind(ctx, i)
  if ctx.mon.perish ~= nil and byte(ctx.mon.perish) < 3 then add(ctx, i, 1); return end
  local used = type(ctx.foeMon.usedMoves) == "table" and ctx.foeMon.usedMoves or {}
  for k = 1, M.NUM_MOVES do
    local rec = M.usedMove(ctx.foeMon, used[k])
    if not rec then break end
    if load(ctx, rec).effect == E.EFFECT_PROTECT then add(ctx, i, 6); return end
  end
  if not confused(ctx.mon) and enemyHalf(ctx) then return end
  if random(ctx) < P79M1 then return end
  add(ctx, i, 1)
end
SMART[E.EFFECT_RAZOR_WIND] = smartRazorWind
SMART[E.EFFECT_UNUSED_2B] = smartRazorWind

SMART[E.EFFECT_CONFUSE] = function(ctx, i)
  if playerHalf(ctx) then return end
  if random(ctx) >= P10 then add(ctx, i, 1) end
  if playerQuarter(ctx) then return end
  add(ctx, i, 1)
end

SMART[E.EFFECT_SP_DEF_UP_2] = function(ctx, i)
  if not enemyHalf(ctx) then add(ctx, i, 1); return end
  local sd = level(ctx.mon, "spd")
  if sd >= M.BASE_STAT_LEVEL + 4 then add(ctx, i, 1); return end
  if sd >= M.BASE_STAT_LEVEL + 2 then return end
  if not special(ctx, type1(ctx.foeMon)) and not special(ctx, type2(ctx.foeMon)) then return end
  if ai8020(ctx) then return end
  add(ctx, i, -2)
end

-- SUBSTATUS_FLYING / _UNDERGROUND: BattleCommand_Charge sets them by move id
-- (Turn `_vanishedInto`).
local function vanished(ctx, mon)
  local into = ctx.battle:_vanishedInto(mon)
  return into == "FLY" or into == "DIG", into
end

SMART[E.EFFECT_FLY] = function(ctx, i)
  if not vanished(ctx, ctx.foeMon) then return end
  if not enemyFaster(ctx) then return end
  add(ctx, i, -3)
end

SMART[E.EFFECT_SUPER_FANG] = function(ctx, i)
  if playerQuarter(ctx) then return end
  add(ctx, i, 1)
end

SMART[E.EFFECT_PARALYZE] = function(ctx, i)
  if not playerQuarter(ctx) then
    if not ai5050(ctx) then add(ctx, i, 1) end
    return
  end
  if enemyFaster(ctx) then return end
  if not enemyQuarter(ctx) then return end
  if ai8020(ctx) then return end
  add(ctx, i, -2)
end

SMART[E.EFFECT_SPEED_DOWN_HIT] = function(ctx, i)
  if ctx.cur.id ~= "ICY_WIND" then return end
  if not enemyQuarter(ctx) then return end
  if M.turnsTaken(ctx.foeMon) ~= 0 then return end
  if enemyFaster(ctx) then return end
  if random(ctx) < P12 then return end
  add(ctx, i, -2)
end

SMART[E.EFFECT_SUBSTITUTE] = function(ctx, i)
  if enemyHalf(ctx) then return end
  dismiss(ctx, i)
end

-- `.discourage`'s byte: `cp 16 percent` on Crystal, `cp 35 percent + 1` on
-- Gold and Silver (pokegold scoring.asm).
SMART[E.EFFECT_HYPER_BEAM] = function(ctx, i)
  if enemyHalf(ctx) then
    local threshold = (ctx.family == "crystal") and P16 or P35P1
    if random(ctx) < threshold then return end
    add(ctx, i, 1)
    if ai5050(ctx) then return end
    add(ctx, i, 1)
    return
  end
  if enemyQuarter(ctx) then return end
  if ai5050(ctx) then return end
  add(ctx, i, -1)
end

SMART[E.EFFECT_RAGE] = function(ctx, i)
  if ctx.mon.raging == true then
    if not ai5050(ctx) then add(ctx, i, -1) end
    local counter = byte(ctx.mon.rageCounter)
    if counter < 2 then return end
    add(ctx, i, -1)
    if counter < 3 then return end
    add(ctx, i, -1)
    return
  end
  if not enemyHalf(ctx) then add(ctx, i, 1); return end
  if not ai8020(ctx) then return end
  add(ctx, i, -1)
end

SMART[E.EFFECT_MIMIC] = function(ctx, i)
  local last = ctx.foeMon.lastCounterMove
  if not last then
    if enemyFaster(ctx) then dismiss(ctx, i) else add(ctx, i, 1) end
    return
  end
  if not enemyHalf(ctx) then add(ctx, i, 1); return end
  load(ctx, last)
  ctx.turn = 1
  local m = battleCheckTypeMatchup(ctx)
  if m < M.EFFECTIVE then add(ctx, i, 1); return end
  if m ~= M.EFFECTIVE and not ai5050(ctx) then add(ctx, i, -1) end
  if not M.USEFUL_MOVES[Effects.moveKey(last)] then return end
  if ai5050(ctx) then return end
  add(ctx, i, -1)
end

-- COUNTER (physical: `cp SPECIAL / jr nc, .skipmove`) and MIRROR COAT
-- (special): how many of the player's used moves are damaging of that kind,
-- every one of the four entries looked at (`jr z, .skipmove` goes on), each
-- loaded; then the last counter move's kind.
local function counterShape(ctx, i, wantSpecial)
  local used = type(ctx.foeMon.usedMoves) == "table" and ctx.foeMon.usedMoves or {}
  local b = 0
  for k = 1, M.NUM_MOVES do
    local rec = M.usedMove(ctx.foeMon, used[k])
    if rec then
      local cur = load(ctx, rec)
      if cur.power ~= 0 and special(ctx, cur.type) == wantSpecial then b = b + 1 end
    end
  end
  if b == 0 then add(ctx, i, 1); return end
  if b < 3 then
    local last = ctx.foeMon.lastCounterMove
    if not last then return end
    local cur = load(ctx, last)
    if cur.power == 0 then return end
    if special(ctx, cur.type) ~= wantSpecial then return end
  end
  if random(ctx) < P39P1 then return end
  add(ctx, i, -1)
end
SMART[E.EFFECT_COUNTER] = function(ctx, i) counterShape(ctx, i, false) end
SMART[E.EFFECT_MIRROR_COAT] = function(ctx, i) counterShape(ctx, i, true) end

-- ENCORE: the player's LAST_MOVE (`lastMove`) loaded, its type against the
-- ENEMY's through CheckTypeMatchup (BATTLE_VARS_MOVE_TYPE: the loaded move on
-- hBattleTurn 1); a move that would hurt the enemy (or has no power) is weak
-- only when the last COUNTER move is an EncoreMoves one.
SMART[E.EFFECT_ENCORE] = function(ctx, i)
  if not enemyFaster(ctx) then add(ctx, i, 3); return end
  local last = ctx.foeMon.lastMove
  if not last then dismiss(ctx, i); return end
  local cur = load(ctx, last)
  local weak = true
  if cur.power ~= 0 then
    local m = checkTypeMatchup(ctx, ctx.mon)
    if m < M.EFFECTIVE then
      if m ~= 0 then return end
      weak = false
    end
  end
  if weak then
    local counter = ctx.foeMon.lastCounterMove
    if not (counter and M.ENCORE_MOVES[Effects.moveKey(counter)]) then
      add(ctx, i, 3)
      return
    end
  end
  if random(ctx) < P28M1 then return end
  add(ctx, i, -2)
end

-- PAIN SPLIT: discouraged unless the player's HP is at least twice the
-- enemy's (a 16-bit doubling).
SMART[E.EFFECT_PAIN_SPLIT] = function(ctx, i)
  local double = (int(ctx.mon.hp, 0) * 2) % 65536
  if int(ctx.foeMon.hp, 0) % 65536 >= double then return end
  add(ctx, i, 1)
end

-- SNORE / SLEEP TALK: `cp 1` on the sleep turns -- an enemy about to wake (or
-- awake, which AI_Basic already dismissed) is the other branch.
local function smartSnore(ctx, i)
  if sleepTurns(ctx.mon) == 1 then add(ctx, i, 3) else add(ctx, i, -3) end
end
SMART[E.EFFECT_SNORE] = smartSnore
SMART[E.EFFECT_SLEEP_TALK] = smartSnore

SMART[E.EFFECT_DEFROST_OPPONENT] = function(ctx, i)
  if band(statusByte(ctx.mon), FRZ_BIT) == 0 then return end
  add(ctx, i, -3)
end

-- CONVERSION2: a player that used a move is discouraged 90% of the time (the
-- branch is inverted, docs/bugs_and_glitches.md: "Smart" AI discourages
-- Conversion2 after the first turn).  With no LAST_MOVE it reads Moves[$ff]'s
-- type -- `dec a` on 0 -- into wPlayerMoveStruct and matches it against the
-- enemy on hBattleTurn 0: four rows past the 251-move table, that byte is in
-- engine/pokemon/evolve.asm's opening code, the high byte of wCurPartyMon's
-- address ($C0..$DF on both carts), which no TypeMatchups row names --
-- EFFECTIVE, `ret z`, no change and no draw; hBattleTurn stays 0.
SMART[E.EFFECT_CONVERSION2] = function(ctx, i)
  local m
  if ctx.foeMon.lastMove then
    m = nil
  else
    ctx.playerMoveType = nil
    ctx.turn = 0
    m = battleCheckTypeMatchup(ctx)
    if m == M.EFFECTIVE then return end
  end
  if m == nil or m < M.EFFECTIVE then
    if random(ctx) < P10 then return end
    add(ctx, i, 1)
    return
  end
  if ai5050(ctx) then return end
  add(ctx, i, -1)
end

local function smartLowHpOnly(ctx, i)
  if not enemyQuarter(ctx) then return end
  add(ctx, i, 1)
end
SMART[E.EFFECT_DESTINY_BOND] = smartLowHpOnly
SMART[E.EFFECT_REVERSAL] = smartLowHpOnly
SMART[E.EFFECT_SKULL_BASH] = smartLowHpOnly

-- SPITE: the PP byte of the player's slot holding the last counter move, PP
-- Ups in its top two bits (`ld a, [de] / cp 6` -- no PP_MASK).
SMART[E.EFFECT_SPITE] = function(ctx, i)
  local last = ctx.foeMon.lastCounterMove
  if not last then
    if enemyFaster(ctx) then dismiss(ctx, i); return end
    if ai5050(ctx) then return end
    add(ctx, i, 1)
    return
  end
  local key = Effects.moveKey(last)
  local found = nil
  for k = 1, M.NUM_MOVES do
    local rec = type(ctx.foeMon.moves) == "table" and ctx.foeMon.moves[k] or nil
    if type(rec) == "table" and Effects.moveKey(rec) == key then found = rec; break end
  end
  if not found then return end
  local pp = min(63, max(0, int(found.pp, 0))) + 64 * (int(found.ppUps, 0) % 4)
  if pp < 6 then
    if random(ctx) < P39P1 then return end
    add(ctx, i, -2)
    return
  end
  if pp < 15 and random(ctx) >= P39P1 then return end
  add(ctx, i, 1)
end

-- HEAL BELL: the status bytes of every monster of the computer's party with
-- HP OR'd together (the battle monster's synced by UpdateBattleMonInParty).
SMART[E.EFFECT_HEAL_BELL] = function(ctx, i)
  local any = false
  for _, m in ipairs(ctx.fighter.mons) do
    if int(m.hp, 0) ~= 0 and statusByte(m) ~= 0 then any = true end
  end
  local own = statusByte(ctx.mon)
  if not any then
    if own ~= 0 then return end
    dismiss(ctx, i)
    return
  end
  if own ~= 0 then add(ctx, i, -1) end
  if band(own, FRZ_BIT + SLP_MASK) == 0 then return end
  if ai5050(ctx) then return end
  add(ctx, i, -2)
end

SMART[E.EFFECT_PRIORITY_HIT] = function(ctx, i)
  if enemyFaster(ctx) then return end
  if vanished(ctx, ctx.foeMon) then dismiss(ctx, i); return end
  local dmg = damageCalc(ctx, false)
  if int(ctx.foeMon.hp, 0) % 65536 >= dmg then return end
  add(ctx, i, -3)
end

-- THIEF: `add $1e` -- only when nothing else is left.
SMART[E.EFFECT_THIEF] = function(ctx, i) add(ctx, i, 30) end

-- MEAN LOOK's toxic test reads the ENEMY's SUBSTATUS_TOXIC (docs/
-- bugs_and_glitches.md: "Smart" AI encourages Mean Look if its own Pokémon is
-- badly poisoned).
SMART[E.EFFECT_MEAN_LOOK] = function(ctx, i)
  if not enemyHalf(ctx) then add(ctx, i, 1); return end
  if not playerHasOthers(ctx) then dismiss(ctx, i); return end
  if not (toxic(ctx.mon) or playerHeld(ctx)) then
    if checkPlayerMoveTypeMatchups(ctx) >= M.BASE_AI_SWITCH_SCORE + 1 then return end
    add(ctx, i, 1)
    return
  end
  if ai8020(ctx) then return end
  add(ctx, i, -3)
end

SMART[E.EFFECT_NIGHTMARE] = function(ctx, i)
  if ai5050(ctx) then return end
  add(ctx, i, -1)
end

SMART[E.EFFECT_FLAME_WHEEL] = function(ctx, i)
  if band(statusByte(ctx.mon), FRZ_BIT) == 0 then return end
  add(ctx, i, -5)
end

-- CURSE: the non-Ghost branch is the same on both carts; the Ghost one is
-- Crystal's last-monster ladder or Gold's HP gates (pokegold scoring.asm).
SMART[E.EFFECT_CURSE] = function(ctx, i)
  local mon, foeMon = ctx.mon, ctx.foeMon
  if typeName(ctx, type1(mon)) ~= "GHOST" and typeName(ctx, type2(mon)) ~= "GHOST" then
    if not enemyHalf(ctx) then add(ctx, i, 1); return end
    local atk = level(mon, "atk")
    if atk >= M.BASE_STAT_LEVEL + 4 then add(ctx, i, 1); return end
    if atk >= M.BASE_STAT_LEVEL + 2 then return end
    if typeName(ctx, type1(foeMon)) == "GHOST" then add(ctx, i, 2); return end
    if special(ctx, type1(foeMon)) then return end
    if special(ctx, type2(foeMon)) then return end
    if ai8020(ctx) then return end
    add(ctx, i, -2)
    return
  end
  if ctx.family ~= "crystal" then
    if not enemyQuarter(ctx) then dismiss(ctx, i); return end
    if not enemyHalf(ctx) then add(ctx, i, 1); return end
    if foeMon.cursed == true then dismiss(ctx, i); return end
    if M.turnsTaken(foeMon) ~= 0 then return end
    if ai5050(ctx) then return end
    add(ctx, i, -2)
    return
  end
  if foeMon.cursed == true then dismiss(ctx, i); return end
  local encourage = false
  if enemyLastMon(ctx) then
    if playerHasOthers(ctx) then add(ctx, i, 4); return end
  elseif not playerHasOthers(ctx) then
    encourage = true
  end
  if not encourage then
    -- `.ghost_continue`.
    if not enemyQuarter(ctx) then add(ctx, i, 4); return end
    if not enemyHalf(ctx) then add(ctx, i, 2); return end
    if not enemyMax(ctx) then return end
    if M.turnsTaken(foeMon) ~= 0 then return end
  end
  if ai5050(ctx) then return end
  add(ctx, i, -2)
end

SMART[E.EFFECT_PROTECT] = function(ctx, i)
  local foeMon = ctx.foeMon
  local discourage = false
  local extra = 0
  if byte(ctx.mon.protectCount) ~= 0 then
    discourage, extra = true, 1
  elseif foeMon.lockOn == true then
    discourage = true
  elseif byte(foeMon.furyCutter) >= 3 or foeMon.charging ~= nil or toxic(foeMon)
         or foeMon.leechSeed ~= nil or foeMon.cursed == true then
    discourage = false
  elseif not rolling(foeMon) or byte(foeMon.rollout and foeMon.rollout.count) < 3 then
    discourage = true
  end
  if discourage then
    add(ctx, i, extra)
    if random(ctx) < P8 then return end
    add(ctx, i, 2)
    return
  end
  if ai8020(ctx) then return end
  add(ctx, i, -1)
end

SMART[E.EFFECT_FORESIGHT] = function(ctx, i)
  local foeMon = ctx.foeMon
  if level(ctx.mon, "acc") < M.BASE_STAT_LEVEL - 2
     or level(foeMon, "eva") >= M.BASE_STAT_LEVEL + 3
     or typeName(ctx, type1(foeMon)) == "GHOST" or typeName(ctx, type2(foeMon)) == "GHOST" then
    if random(ctx) < P39P1 then return end
    add(ctx, i, -2)
    return
  end
  if random(ctx) < P8 then return end
  add(ctx, i, 1)
end

-- PERISH SONG: the player's SUBSTATUS_CANT_RUN is the PLAYER's hold on the
-- enemy (Turn's `meanLook` on the player's monster).
SMART[E.EFFECT_PERISH_SONG] = function(ctx, i)
  if enemyLastMon(ctx) then add(ctx, i, 5); return end
  if ctx.foeMon.meanLook ~= nil then
    if ai5050(ctx) then return end
    add(ctx, i, -1)
    return
  end
  if checkPlayerMoveTypeMatchups(ctx) < M.BASE_AI_SWITCH_SCORE then return end
  if ai5050(ctx) then return end
  add(ctx, i, 1)
end

local SANDSTORM_IMMUNE = { ROCK = true, GROUND = true, STEEL = true }
SMART[E.EFFECT_SANDSTORM] = function(ctx, i)
  if SANDSTORM_IMMUNE[typeName(ctx, type1(ctx.foeMon)) or ""]
     or SANDSTORM_IMMUNE[typeName(ctx, type2(ctx.foeMon)) or ""] then
    add(ctx, i, 2)
    return
  end
  if not playerHalf(ctx) then add(ctx, i, 1); return end
  if ai5050(ctx) then return end
  add(ctx, i, -1)
end

SMART[E.EFFECT_ENDURE] = function(ctx, i)
  if byte(ctx.mon.protectCount) ~= 0 then add(ctx, i, 2); return end
  if enemyMax(ctx) then add(ctx, i, 2); return end
  if enemyQuarter(ctx) then add(ctx, i, 1); return end
  if hasMoveEffect(ctx, E.EFFECT_REVERSAL) then
    if ai8020(ctx) then return end
    add(ctx, i, -3)
    return
  end
  if ctx.mon.lockOn ~= true then return end
  if ai5050(ctx) then return end
  add(ctx, i, -2)
end

local function smartRollout(ctx, i)
  local mon = ctx.mon
  local maybe = mon.inLove ~= nil or confused(mon) or band(statusByte(mon), PAR_BIT) ~= 0
    or not enemyQuarter(ctx)
    or level(mon, "acc") < M.BASE_STAT_LEVEL
    or level(ctx.foeMon, "eva") >= M.BASE_STAT_LEVEL + 1
  if maybe then
    if ai8020(ctx) then return end
    add(ctx, i, 1)
    return
  end
  if random(ctx) >= P79M1 then return end
  add(ctx, i, -2)
end
SMART[E.EFFECT_ROLLOUT] = smartRollout

SMART[E.EFFECT_FURY_CUTTER] = function(ctx, i)
  local count = byte(ctx.mon.furyCutter)
  if count ~= 0 then
    add(ctx, i, -1)
    if count >= 2 then
      add(ctx, i, -2)
      if count >= 3 then add(ctx, i, -3) end
    end
  end
  smartRollout(ctx, i)
end

local function smartSwagger(ctx, i)
  if M.turnsTaken(ctx.foeMon) == 0 then
    if random(ctx) >= P79M1 then return end
    add(ctx, i, -1)
    return
  end
  if ai8020(ctx) then return end
  add(ctx, i, 1)
end
SMART[E.EFFECT_SWAGGER] = smartSwagger
SMART[E.EFFECT_ATTRACT] = smartSwagger

SMART[E.EFFECT_SAFEGUARD] = function(ctx, i)
  if playerHalf(ctx) then return end
  if ai8020(ctx) then return end
  add(ctx, i, 1)
end

-- MAGNITUDE / EARTHQUAKE against DIG, TWISTER / GUST against FLY: the last
-- counter move by id, then the player's SUBSTATUS_UNDERGROUND / _FLYING.
local function smartAgainst(ctx, i, moveId)
  local last = ctx.foeMon.lastCounterMove
  if not last or Effects.moveKey(last) ~= moveId then return end
  local _, into = vanished(ctx, ctx.foeMon)
  if into == moveId then
    if not enemyFaster(ctx) then return end
    add(ctx, i, -2)
    return
  end
  if enemyFaster(ctx) then return end
  if ai5050(ctx) then return end
  add(ctx, i, -1)
end
SMART[E.EFFECT_MAGNITUDE] = function(ctx, i) smartAgainst(ctx, i, "DIG") end
SMART[E.EFFECT_EARTHQUAKE] = function(ctx, i) smartAgainst(ctx, i, "DIG") end
SMART[E.EFFECT_TWISTER] = function(ctx, i) smartAgainst(ctx, i, "FLY") end
SMART[E.EFFECT_GUST] = function(ctx, i) smartAgainst(ctx, i, "FLY") end

SMART[E.EFFECT_PURSUIT] = function(ctx, i)
  if not playerQuarter(ctx) then
    if ai5050(ctx) then return end
    add(ctx, i, -2)
    return
  end
  if ai8020(ctx) then return end
  add(ctx, i, 1)
end

SMART[E.EFFECT_RAPID_SPIN] = function(ctx, i)
  local trapped = ctx.mon.trapped
  if not ((type(trapped) == "table" and int(trapped.turns, 0) % 256 ~= 0) or ctx.mon.leechSeed ~= nil
          or screens(ctx, ctx.fighter).spikes == true) then
    return
  end
  if ai8020(ctx) then return end
  add(ctx, i, -2)
end

-- HIDDEN POWER: HiddenPowerDamage's power and type from the enemy's DVs
-- (Effects.hiddenPower), the type written over BATTLE_VARS_MOVE_TYPE; with no
-- DVs on the sheet, or a type the ruleset does not name, the move's own --
-- the referee's rule for the hit (Turn `_hitDamage`).
SMART[E.EFFECT_HIDDEN_POWER] = function(ctx, i)
  ctx.turn = 1
  local power, hpType = Effects.hiddenPower(ctx.mon.dvs)
  local d = power or ctx.cur.power
  local index = hpType and typeIndexOf(ctx.battle.typeIds, hpType) or nil
  if index ~= nil then ctx.cur.type = index end
  local m = battleCheckTypeMatchup(ctx)
  if m < M.EFFECTIVE or d < 50 then add(ctx, i, 1); return end
  if m < M.EFFECTIVE + 1 and d < 70 then return end
  add(ctx, i, -1)
end

-- AIGoodWeatherType: the player above half HP, on its first turn -- or the
-- enemy's.
local function goodWeather(ctx, i)
  if not playerHalf(ctx) then return end
  if M.turnsTaken(ctx.foeMon) ~= 0 and M.turnsTaken(ctx.mon) ~= 0 then return end
  add(ctx, i, -2)
end

-- AI_Smart_RainDance / _SunnyDay: the player's types against the weather's
-- (`bad` first, then `good`, type 1 before type 2), then AI_Smart_WeatherMove.
local function weatherMove(ctx, i, bad, good, list)
  for _, t in ipairs({ type1(ctx.foeMon), type2(ctx.foeMon) }) do
    local name = typeName(ctx, t)
    if name == bad then add(ctx, i, 3); return end
    if name == good then goodWeather(ctx, i); return end
  end
  if not hasMoveInArray(ctx, list) then add(ctx, i, 3); return end
  if not playerHalf(ctx) then add(ctx, i, 3); return end
  if ai5050(ctx) then return end
  add(ctx, i, -1)
end
SMART[E.EFFECT_RAIN_DANCE] = function(ctx, i)
  weatherMove(ctx, i, "WATER", "FIRE", M.RAIN_DANCE_MOVES)
end
SMART[E.EFFECT_SUNNY_DAY] = function(ctx, i)
  weatherMove(ctx, i, "FIRE", "WATER", M.SUNNY_DAY_MOVES)
end

SMART[E.EFFECT_BELLY_DRUM] = function(ctx, i)
  if level(ctx.mon, "atk") >= M.BASE_STAT_LEVEL + 3 then add(ctx, i, 5); return end
  if enemyMax(ctx) then return end
  add(ctx, i, 1)
  if enemyHalf(ctx) then return end
  add(ctx, i, 5)
end

-- PSYCH UP: the two sums of the levels (each side's eighth byte, the "ds 1"
-- past Evasion, is BASE_STAT_LEVEL -- ResetPlayerStatLevels /
-- ResetEnemyStatLevels write all eight and PSYCH UP copies them -- so it adds
-- nothing).  Crystal then gates on the enemy's Evasion and discourages by 2;
-- Gold and Silver read the player's Evasion twice -- under +2, then not under
-- +1, which every level past the first gate is -- and discourage by 1
-- (pokegold scoring.asm: "This block will never be reached").
SMART[E.EFFECT_PSYCH_UP] = function(ctx, i)
  local c, d = 100, 100
  for _, key in ipairs(STAT_LEVEL_KEYS) do
    c = (c + level(ctx.mon, key) - M.BASE_STAT_LEVEL) % 256
    d = (d + level(ctx.foeMon, key) - M.BASE_STAT_LEVEL) % 256
  end
  local crystal = ctx.family == "crystal"
  if c >= d then add(ctx, i, crystal and 2 or 1); return end
  if level(ctx.foeMon, "acc") < M.BASE_STAT_LEVEL - 1 then return end
  if crystal then
    if level(ctx.mon, "eva") >= M.BASE_STAT_LEVEL + 1 then return end
  else
    if level(ctx.foeMon, "eva") < M.BASE_STAT_LEVEL + 2 then return end
    if level(ctx.foeMon, "eva") >= M.BASE_STAT_LEVEL + 1 then return end
  end
  if ai8020(ctx) then return end
  add(ctx, i, -1)
end

SMART[E.EFFECT_FUTURE_SIGHT] = function(ctx, i)
  if not enemyFaster(ctx) then return end
  if not vanished(ctx, ctx.foeMon) then return end
  add(ctx, i, -2)
end

SMART[E.EFFECT_STOMP] = function(ctx, i)
  if ctx.foeMon.minimized ~= true then return end
  if ai8020(ctx) then return end
  add(ctx, i, -1)
end

SMART[E.EFFECT_SOLARBEAM] = function(ctx, i)
  local w = weather(ctx)
  if w == "sun" then
    if ai8020(ctx) then return end
    add(ctx, i, -2)
    return
  end
  if w ~= "rain" then return end
  if random(ctx) < P10 then return end
  add(ctx, i, 2)
end

SMART[E.EFFECT_THUNDER] = function(ctx, i)
  if weather(ctx) ~= "sun" then return end
  if random(ctx) < P10 then return end
  add(ctx, i, 1)
end

-- DISABLE: `.notencourage` reads the power of the move being scored -- DISABLE
-- itself, 0 -- so a not-useful last move is always the discourage branch.
SMART[E.EFFECT_DISABLE] = function(ctx, i)
  if enemyFaster(ctx) then
    local last = ctx.foeMon.lastCounterMove
    if last and M.USEFUL_MOVES[Effects.moveKey(last)] then
      if random(ctx) < P39P1 then return end
      add(ctx, i, -1)
      return
    end
    if ctx.cur.power ~= 0 then return end
  end
  if random(ctx) < P8 then return end
  add(ctx, i, 1)
end

-- AI_Smart: each move's handler, by its effect (`IsInArray` on the table).
local function aiSmart(ctx)
  for i = 1, M.NUM_MOVES do
    local rec = slot(ctx, i)
    if not rec then return end
    local handler = SMART[load(ctx, rec).effect]
    if handler then handler(ctx, i) end
  end
end

-- AIScoringPointers, by TRNATTR_AI_MOVE_WEIGHTS bit.
M.LAYER_FUNCS = {
  aiBasic, aiSetup, aiTypes, aiOffensive, aiSmart,
  aiOpportunist, aiAggressive, aiCautious, aiStatus, aiRisky,
}

-- ------------------------------------------------------------------
-- the state fields the referee does not keep (see the header)
-- ------------------------------------------------------------------

-- wPlayerTurnsTaken / wEnemyTurnsTaken (a byte; absent is 0).
function M.turnsTaken(mon)
  return byte(mon and mon.turnsTaken)
end

-- CheckEnemyLockedIn (engine/battle/core.asm): SUBSTATUS_RECHARGE, _CHARGED /
-- _RAMPAGE / _BIDE, _ROLLOUT -- the referee's `mustRecharge`, `charging`, a
-- rampage with turns left, `bide` and an active `rollout` (the lock-ins Turn's
-- `_fillForcedChoices` fills).
function M.enemyLockedIn(mon)
  if type(mon) ~= "table" then return false end
  if mon.mustRecharge == true then return true end
  if mon.charging ~= nil then return true end
  if type(mon.thrashing) == "table" and int(mon.thrashing.turns, 0) > 0 then return true end
  if mon.bide ~= nil then return true end
  return rolling(mon)
end

-- wEnemyDisabledMove: the disabled slot's move, while the count runs.
local function disabledKey(mon)
  local d = mon.disable
  if type(d) ~= "table" or int(d.turns, 0) <= 0 then return nil end
  local rec = type(mon.moves) == "table" and mon.moves[int(d.moveIndex, 0)] or nil
  if type(rec) ~= "table" then return nil end
  return Effects.moveKey(rec)
end

-- ParseEnemyAction's `.continue` (pokecrystal engine/battle/core.asm, pokegold
-- the same): the first slot that is not empty, not wEnemyDisabledMove and has
-- PP -- nil when an empty slot or the end comes first (`.struggle`).
function M.usableMove(mon)
  if type(mon) ~= "table" then return nil end
  local disabled = disabledKey(mon)
  for i = 1, M.NUM_MOVES do
    local rec = type(mon.moves) == "table" and mon.moves[i] or nil
    if type(rec) ~= "table" then return nil end
    if Effects.moveKey(rec) ~= disabled and int(rec.pp, 0) > 0 then return i end
  end
  return nil
end

-- ------------------------------------------------------------------
-- AIChooseMove
-- ------------------------------------------------------------------

-- The fight's cart family (contract K6), as Turn keeps it.
local function familyOf(battle, opts)
  if opts.family == "crystal" or opts.family == "gs" then return opts.family end
  if battle.family == "crystal" then return "crystal" end
  return "gs"
end

-- AIChooseMove, scored and picked.  Returns a table:
--   slot     the 1-based move slot (wCurEnemyMoveNum + 1), or nil
--   reason   why there is no slot: "wild", "link", "locked", "nomon", "nomoves"
--   scores   wEnemyAIMoveScores after the layers (before the countdown)
--   layerDraws  the bytes the layers took (the rest are `.ChooseMove`'s)
--   draws    the bytes taken off battle.rng
-- opts: aiFlags (TRNATTR_AI_MOVE_WEIGHTS; default fighter.aiFlags, then 0),
--   family ("gs" | "crystal"; default the battle's), wild / link (booleans;
--   default from battle.mode).
function M.evaluate(battle, fighter, foe, opts)
  opts = type(opts) == "table" and opts or {}
  local out = { slot = nil, reason = nil, scores = nil, layerDraws = 0, draws = 0 }
  -- `ld a, [wBattleMode] / dec a / ret z`: wild monsters attack at random
  -- (ParseEnemyAction's loop, `wildPick`).
  local wild = opts.wild
  if wild == nil then wild = Effects.isWildMode(battle.mode) end
  if wild then out.reason = "wild"; return out end
  -- `ld a, [wLinkMode] / and a / ret nz`.
  local link = opts.link
  if link == nil then link = M.LINK_MODES[battle.mode] == true end
  if link then out.reason = "link"; return out end
  local mon = fighter and fighter.active and fighter.mons[fighter.active] or nil
  local foeMon = foe and foe.active and foe.mons[foe.active] or nil
  if not mon or not foeMon then out.reason = "nomon"; return out end
  -- `farcall CheckEnemyLockedIn / ret nz`: no use picking with no choice.
  if M.enemyLockedIn(mon) then out.reason = "locked"; return out end

  local ctx = {
    battle = battle, fighter = fighter, foe = foe, mon = mon, foeMon = foeMon,
    family = familyOf(battle, opts),
    scores = { M.BASE_SCORE, M.BASE_SCORE, M.BASE_SCORE, M.BASE_SCORE },
    turn = 1, cur = nil, playerMoveType = nil, draws = 0,
  }
  -- PSYWAVE's loop draws through Effects.fixedDamage's `rng:byte()`; the
  -- counter is that stream with the AI's count on it.
  ctx.counter = { byte = function() return random(ctx) end }

  -- `.CheckDisabledMove`: the first slot holding wEnemyDisabledMove, 80.
  local disabled = disabledKey(mon)
  if disabled then
    for i = 1, M.NUM_MOVES do
      local rec = slot(ctx, i)
      if rec and Effects.moveKey(rec) == disabled then
        ctx.scores[i] = M.UNUSABLE_SCORE
        break
      end
    end
  end
  -- `.CheckMovePP`: every slot whose PP byte has no PP (an empty slot too), 80.
  for i = 1, M.NUM_MOVES do
    local rec = slot(ctx, i)
    if not rec or int(rec.pp, 0) <= 0 then ctx.scores[i] = M.UNUSABLE_SCORE end
  end

  -- `.ApplyLayers`: bits 0..15 of the word, low byte first (SmallFarFlagAction).
  local flags = int(opts.aiFlags, nil)
  if flags == nil then flags = int(fighter.aiFlags, 0) end
  flags = max(0, flags) % 65536
  for bit = 0, M.LAYER_SLOTS - 1 do
    if floor(flags / 2 ^ bit) % 2 == 1 then
      local layer = M.LAYER_FUNCS[bit + 1]
      if layer then layer(ctx) end
    end
  end
  out.scores = { ctx.scores[1], ctx.scores[2], ctx.scores[3], ctx.scores[4] }
  out.layerDraws = ctx.draws

  -- `.DecrementScores`: every slot up to the first empty one loses one per
  -- round, round after round, until one reaches 0 (`dec [hl] / jr z`); a slot
  -- whose move is 0 restarts the round.  No move at all is the cart's
  -- infinite loop -- never kept: nil.
  local sc = ctx.scores
  if not slot(ctx, 1) then
    out.reason = "nomoves"
    out.draws = ctx.draws
    return out
  end
  local hit = nil
  for _ = 1, 257 do
    for i = 1, M.NUM_MOVES do
      if not slot(ctx, i) then break end
      sc[i] = (sc[i] - 1) % 256
      if sc[i] == 0 then hit = i; break end
    end
    if hit then break end
  end
  -- `.PickLowestScoreMoves`: the slots decremented once more than the rest in
  -- that last round get it back, so every one tied for lowest reads 1.
  for i = hit, 1, -1 do sc[i] = (sc[i] + 1) % 256 end
  -- `.loop2`: a blank move's score is 0, and only a score of 1 keeps its move.
  local keep = {}
  for i = 1, M.NUM_MOVES do
    local rec = slot(ctx, i)
    keep[i] = (rec ~= nil and sc[i] == 1) and true or false
  end
  -- `.ChooseMove`: a Random byte's low two bits until they name a kept slot.
  local chosen = hit
  for _ = 1, M.REDRAW_LIMIT do
    local c = random(ctx) % 4
    if keep[c + 1] then chosen = c + 1; break end
  end
  out.slot = chosen
  out.draws = ctx.draws
  return out
end

-- The slot AIChooseMove picks for the computer's active monster against the
-- player's (`foe`), or nil where the cart picks none (wild, link, a lock-in).
function M.choose(battle, fighter, foe, opts)
  return M.evaluate(battle, fighter, foe, opts).slot
end

-- ParseEnemyAction's wild pick (`.loop2`), once `.not_linked`'s ENCORE and
-- CheckEnemyLockedIn have passed (the caller's, as for a trainer): nil when
-- `.continue` finds no usable move (Struggle); otherwise a BattleRandom byte's
-- low two bits, redrawn on the disabled slot (wEnemyDisableCount's high
-- nibble, 0 once the count ran out), an empty slot or one with no PP.
function M.wildPick(battle, fighter)
  local mon = fighter and fighter.active and fighter.mons[fighter.active] or nil
  local first = M.usableMove(mon)
  if not first then return nil end
  local d = mon.disable
  local disabledSlot = (type(d) == "table" and int(d.turns, 0) > 0) and int(d.moveIndex, 0) or 0
  for _ = 1, M.REDRAW_LIMIT do
    local c = battle.rng:byte() % 4
    local rec = mon.moves[c + 1]
    if c + 1 ~= disabledSlot and type(rec) == "table" and int(rec.pp, 0) > 0 then return c + 1 end
  end
  return first
end

return M
