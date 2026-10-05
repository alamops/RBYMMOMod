-- Gen2 move-effect ids and stat-stage multipliers (light port of Gen1 Effects).
--
-- The same 87-slot pret-ordered table as BattleSim/Effects.lua (ids 0..86),
-- which Gold's EFFECT_* names fold onto where a Gen 1 handler is the cart's
-- command (`idOf`), and after it the Gold-native rows (87..MAX_EFFECT_ID):
-- the scripts whose commands no Gen 1 id runs -- SP. DEF / ACCURACY down,
-- ATTACK / DEFENSE / ALL up, FLAME WHEEL and SACRED FIRE, STOMP, TWISTER,
-- SNORE, THUNDER, TRI ATTACK, GUST, EARTHQUAKE and SKY ATTACK
-- (docs/plans/gen12-referee-known-gaps.md section 13) -- and, from the
-- referee-gaps run's wave 2, SLEEP TALK, LOCK-ON, SAFEGUARD and TOXIC
-- (102..105), and from its wave 3 the Gold-only damage formulas, protection,
-- COUNTER / MIRROR COAT, FUTURE SIGHT, PURSUIT, the weather moves and the
-- fixed-damage scripts Gold names apart (106..132), and from its wave 4 the
-- status and field scripts -- ATTRACT, BATON PASS, BELLY DRUM, CONVERSION2,
-- CURSE, DESTINY BOND, ENCORE, FORESIGHT, HEAL BELL, MEAN LOOK, NIGHTMARE,
-- PAIN SPLIT, PERISH SONG, PSYCH UP, RAPID SPIN, SKETCH, SPIKES, SPITE, the
-- SP. DEF stat moves (AMNESIA), SWAGGER, TELEPORT and SKULL BASH (133..157).
-- Stage and sheet keys
-- are Gen2: atk/def/spe/spa/spd (Sp.Def). Calcium / X_SPECIAL write spa.
--
-- No love, no engine modules, no mod facade.

local need = ...

-- For the burn / paralysis tail of `battleStat`, so the halving and the
-- quartering are one rule with one owner rather than a second copy here.
local Status = need("BattleSim2/Status")
-- The HELD_PREVENT_* tokens the status commands ask about (Items.prevents).
local Items = need("BattleSim2/Items")

local M = {}

local floor, max, min = math.floor, math.max, math.min

-- pret/pokered effect name order (effect id = index).
M.NAMES = {
  [0] = "NO_ADDITIONAL_EFFECT",
  [1] = "EFFECT_01",
  [2] = "POISON_SIDE_EFFECT1",
  [3] = "DRAIN_HP_EFFECT",
  [4] = "BURN_SIDE_EFFECT1",
  [5] = "FREEZE_SIDE_EFFECT1",
  [6] = "PARALYZE_SIDE_EFFECT1",
  [7] = "EXPLODE_EFFECT",
  [8] = "DREAM_EATER_EFFECT",
  [9] = "MIRROR_MOVE_EFFECT",
  [10] = "ATTACK_UP1_EFFECT",
  [11] = "DEFENSE_UP1_EFFECT",
  [12] = "SPEED_UP1_EFFECT",
  [13] = "SPECIAL_UP1_EFFECT",
  [14] = "ACCURACY_UP1_EFFECT",
  [15] = "EVASION_UP1_EFFECT",
  [16] = "PAY_DAY_EFFECT",
  [17] = "SWIFT_EFFECT",
  [18] = "ATTACK_DOWN1_EFFECT",
  [19] = "DEFENSE_DOWN1_EFFECT",
  [20] = "SPEED_DOWN1_EFFECT",
  [21] = "SPECIAL_DOWN1_EFFECT",
  [22] = "ACCURACY_DOWN1_EFFECT",
  [23] = "EVASION_DOWN1_EFFECT",
  [24] = "CONVERSION_EFFECT",
  [25] = "HAZE_EFFECT",
  [26] = "BIDE_EFFECT",
  [27] = "THRASH_PETAL_DANCE_EFFECT",
  [28] = "SWITCH_AND_TELEPORT_EFFECT",
  [29] = "TWO_TO_FIVE_ATTACKS_EFFECT",
  [30] = "EFFECT_1E",
  [31] = "FLINCH_SIDE_EFFECT1",
  [32] = "SLEEP_EFFECT",
  [33] = "POISON_SIDE_EFFECT2",
  [34] = "BURN_SIDE_EFFECT2",
  [35] = "FREEZE_SIDE_EFFECT2",
  [36] = "PARALYZE_SIDE_EFFECT2",
  [37] = "FLINCH_SIDE_EFFECT2",
  [38] = "OHKO_EFFECT",
  [39] = "CHARGE_EFFECT",
  [40] = "SUPER_FANG_EFFECT",
  [41] = "SPECIAL_DAMAGE_EFFECT",
  [42] = "TRAPPING_EFFECT",
  [43] = "FLY_EFFECT",
  [44] = "ATTACK_TWICE_EFFECT",
  [45] = "JUMP_KICK_EFFECT",
  [46] = "MIST_EFFECT",
  [47] = "FOCUS_ENERGY_EFFECT",
  [48] = "RECOIL_EFFECT",
  [49] = "CONFUSION_EFFECT",
  [50] = "ATTACK_UP2_EFFECT",
  [51] = "DEFENSE_UP2_EFFECT",
  [52] = "SPEED_UP2_EFFECT",
  [53] = "SPECIAL_UP2_EFFECT",
  [54] = "ACCURACY_UP2_EFFECT",
  [55] = "EVASION_UP2_EFFECT",
  [56] = "HEAL_EFFECT",
  [57] = "TRANSFORM_EFFECT",
  [58] = "ATTACK_DOWN2_EFFECT",
  [59] = "DEFENSE_DOWN2_EFFECT",
  [60] = "SPEED_DOWN2_EFFECT",
  [61] = "SPECIAL_DOWN2_EFFECT",
  [62] = "ACCURACY_DOWN2_EFFECT",
  [63] = "EVASION_DOWN2_EFFECT",
  [64] = "LIGHT_SCREEN_EFFECT",
  [65] = "REFLECT_EFFECT",
  [66] = "POISON_EFFECT",
  [67] = "PARALYZE_EFFECT",
  [68] = "ATTACK_DOWN_SIDE_EFFECT",
  [69] = "DEFENSE_DOWN_SIDE_EFFECT",
  [70] = "SPEED_DOWN_SIDE_EFFECT",
  [71] = "SPECIAL_DOWN_SIDE_EFFECT",
  [72] = "UNUSED",
  [73] = "UNUSED",
  [74] = "UNUSED",
  [75] = "UNUSED",
  [76] = "CONFUSION_SIDE_EFFECT",
  [77] = "TWINEEDLE_EFFECT",
  [78] = "UNUSED",
  [79] = "SUBSTITUTE_EFFECT",
  [80] = "HYPER_BEAM_EFFECT",
  [81] = "RAGE_EFFECT",
  [82] = "MIMIC_EFFECT",
  [83] = "METRONOME_EFFECT",
  [84] = "LEECH_SEED_EFFECT",
  [85] = "SPLASH_EFFECT",
  [86] = "DISABLE_EFFECT",
  -- The Gold-native rows, each under the cart's own constant (pokecrystal
  -- constants/move_effect_constants.asm, pokegold the same), the name a Gold
  -- sheet's `def.effect` carries -- so `idOf` answers them off BY_NAME.  The
  -- move scripts they stand for are data/moves/effects.asm's (identical in
  -- pokegold); the moves are data/moves/moves.asm's.
  [87] = "EFFECT_SP_DEF_DOWN_HIT",    -- CRUNCH, PSYCHIC, SHADOW BALL
  [88] = "EFFECT_ACCURACY_DOWN_HIT",  -- MUD-SLAP, OCTAZOOKA
  [89] = "EFFECT_ATTACK_UP_HIT",      -- METAL CLAW
  [90] = "EFFECT_DEFENSE_UP_HIT",     -- STEEL WING
  [91] = "EFFECT_ALL_UP_HIT",         -- ANCIENTPOWER
  [92] = "EFFECT_FLAME_WHEEL",
  [93] = "EFFECT_SACRED_FIRE",
  [94] = "EFFECT_STOMP",
  [95] = "EFFECT_TWISTER",
  [96] = "EFFECT_SNORE",
  [97] = "EFFECT_THUNDER",
  [98] = "EFFECT_TRI_ATTACK",
  [99] = "EFFECT_GUST",
  [100] = "EFFECT_EARTHQUAKE",
  [101] = "EFFECT_SKY_ATTACK",
  -- The referee-gaps run's wave 2 (R2b): the scripts whose own command the
  -- referee runs now -- BattleCommand_SleepTalk, BattleCommand_LockOn (LOCK-ON
  -- and MIND READER), BattleCommand_Safeguard -- and EFFECT_TOXIC, which used
  -- to fold onto POISON_EFFECT (66) and so never badly poisoned: it shares
  -- BattleCommand_Poison with it and differs in `.check_toxic`.
  [102] = "EFFECT_SLEEP_TALK",
  [103] = "EFFECT_LOCK_ON",
  [104] = "EFFECT_SAFEGUARD",
  [105] = "EFFECT_TOXIC",
  -- The referee-gaps run's wave 3 (R2c): every Gold script the referee used to
  -- fold onto a Gen 1 handler or onto 0, whose own commands it runs now (Turn
  -- `_useMove`; the move scripts are data/moves/effects.asm's).
  [106] = "EFFECT_RETURN",          -- BattleCommand_HappinessPower
  [107] = "EFFECT_FRUSTRATION",     -- BattleCommand_FrustrationPower
  [108] = "EFFECT_HIDDEN_POWER",    -- HiddenPowerDamage
  [109] = "EFFECT_REVERSAL",        -- FLAIL, REVERSAL: ConstantDamage's .reversal
  [110] = "EFFECT_MAGNITUDE",       -- BattleCommand_GetMagnitude
  [111] = "EFFECT_PRESENT",         -- BattleCommand_Present
  [112] = "EFFECT_TRIPLE_KICK",     -- TripleKick / KickCounter / EndLoop
  [113] = "EFFECT_FURY_CUTTER",     -- BattleCommand_FuryCutter
  [114] = "EFFECT_ROLLOUT",         -- CheckRollout / RolloutPower
  [115] = "EFFECT_DEFENSE_CURL",    -- DefenseUp + BattleCommand_Curl
  [116] = "EFFECT_BEAT_UP",         -- BattleCommand_BeatUp / EndLoop
  [117] = "EFFECT_PURSUIT",         -- BattleCommand_Pursuit / PursuitSwitch
  [118] = "EFFECT_FALSE_SWIPE",     -- BattleCommand_FalseSwipe
  [119] = "EFFECT_FUTURE_SIGHT",    -- CheckFutureSight / FutureSight
  [120] = "EFFECT_PROTECT",         -- PROTECT, DETECT: BattleCommand_Protect
  [121] = "EFFECT_ENDURE",          -- BattleCommand_Endure
  [122] = "EFFECT_COUNTER",         -- BattleCommand_Counter
  [123] = "EFFECT_MIRROR_COAT",     -- BattleCommand_MirrorCoat
  [124] = "EFFECT_RAIN_DANCE",      -- BattleCommand_StartRain
  [125] = "EFFECT_SUNNY_DAY",       -- BattleCommand_StartSun
  [126] = "EFFECT_SANDSTORM",       -- BattleCommand_StartSandstorm
  [127] = "EFFECT_SOLARBEAM",       -- SkipSunCharge + Charge; rain's x0.5
  [128] = "EFFECT_MORNING_SUN",     -- BattleCommand_HealMorn
  [129] = "EFFECT_SYNTHESIS",       -- BattleCommand_HealDay
  [130] = "EFFECT_MOONLIGHT",       -- BattleCommand_HealNite
  [131] = "EFFECT_LEVEL_DAMAGE",    -- SEISMIC TOSS, NIGHT SHADE: ConstantDamage
  [132] = "EFFECT_PSYWAVE",         -- ConstantDamage's .psywave
  -- The referee-gaps run's wave 4 (R2d): the status and field scripts, each
  -- under its own command (pokecrystal engine/battle/move_effects/*.asm and
  -- effect_commands.asm), and the four SP. DEF stat rows that used to fold to
  -- 0 (AMNESIA said "But nothing happened").  SKULL BASH leaves CHARGE_EFFECT
  -- (39) because its script raises Defense on the charge turn
  -- (BattleCommand_Charge's SkipToBattleCommand to `endturn`).
  [133] = "EFFECT_ATTRACT",         -- BattleCommand_Attract
  [134] = "EFFECT_BATON_PASS",      -- BattleCommand_BatonPass
  [135] = "EFFECT_BELLY_DRUM",      -- BattleCommand_BellyDrum
  [136] = "EFFECT_CONVERSION2",     -- BattleCommand_Conversion2
  [137] = "EFFECT_CURSE",           -- BattleCommand_Curse
  [138] = "EFFECT_DESTINY_BOND",    -- BattleCommand_DestinyBond
  [139] = "EFFECT_ENCORE",          -- BattleCommand_Encore
  [140] = "EFFECT_FORESIGHT",       -- BattleCommand_Foresight
  [141] = "EFFECT_HEAL_BELL",       -- BattleCommand_HealBell
  [142] = "EFFECT_MEAN_LOOK",       -- MEAN LOOK, SPIDER WEB: BattleCommand_ArenaTrap
  [143] = "EFFECT_NIGHTMARE",       -- BattleCommand_Nightmare
  [144] = "EFFECT_PAIN_SPLIT",      -- BattleCommand_PainSplit
  [145] = "EFFECT_PERISH_SONG",     -- BattleCommand_PerishSong
  [146] = "EFFECT_PSYCH_UP",        -- BattleCommand_PsychUp
  [147] = "EFFECT_RAPID_SPIN",      -- BattleCommand_ClearHazards after the hit
  [148] = "EFFECT_SKETCH",          -- BattleCommand_Sketch
  [149] = "EFFECT_SPIKES",          -- BattleCommand_Spikes
  [150] = "EFFECT_SPITE",           -- BattleCommand_Spite
  [151] = "EFFECT_SP_DEF_UP_2",     -- AMNESIA: BattleCommand_SpecialDefenseUp2
  [152] = "EFFECT_SWAGGER",         -- attackup2 on the target, confusetarget
  [153] = "EFFECT_TELEPORT",        -- BattleCommand_Teleport
  [154] = "EFFECT_SP_DEF_UP",       -- BattleCommand_SpecialDefenseUp
  [155] = "EFFECT_SP_DEF_DOWN",     -- BattleCommand_SpecialDefenseDown
  [156] = "EFFECT_SP_DEF_DOWN_2",   -- BattleCommand_SpecialDefenseDown2
  [157] = "EFFECT_SKULL_BASH",      -- Charge, then `endturn` / `defenseup`
}

-- The last id either table numbers.  The wire carries a Gen 1/2 move's effect
-- as a byte (Wire.battleMove, sanitize EFFECT_MAX), so this may grow to 255.
M.MAX_EFFECT_ID = 157

-- The Gold-native ids by name, for the call sites that branch on one.
M.SP_DEF_DOWN_HIT = 87
M.ACCURACY_DOWN_HIT = 88
M.ATTACK_UP_HIT = 89
M.DEFENSE_UP_HIT = 90
M.ALL_UP_HIT = 91
M.FLAME_WHEEL = 92
M.SACRED_FIRE = 93
M.STOMP = 94
M.TWISTER = 95
M.SNORE = 96
M.THUNDER = 97
M.TRI_ATTACK = 98
M.GUST = 99
M.EARTHQUAKE = 100
M.SKY_ATTACK = 101
M.SLEEP_TALK = 102
M.LOCK_ON = 103
M.SAFEGUARD = 104
M.TOXIC = 105
M.RETURN = 106
M.FRUSTRATION = 107
M.HIDDEN_POWER = 108
M.REVERSAL = 109
M.MAGNITUDE = 110
M.PRESENT = 111
M.TRIPLE_KICK = 112
M.FURY_CUTTER = 113
M.ROLLOUT = 114
M.DEFENSE_CURL = 115
M.BEAT_UP = 116
M.PURSUIT = 117
M.FALSE_SWIPE = 118
M.FUTURE_SIGHT = 119
M.PROTECT = 120
M.ENDURE = 121
M.COUNTER = 122
M.MIRROR_COAT = 123
M.RAIN_DANCE = 124
M.SUNNY_DAY = 125
M.SANDSTORM = 126
M.SOLARBEAM = 127
M.MORNING_SUN = 128
M.SYNTHESIS = 129
M.MOONLIGHT = 130
M.LEVEL_DAMAGE = 131
M.PSYWAVE = 132
M.ATTRACT = 133
M.BATON_PASS = 134
M.BELLY_DRUM = 135
M.CONVERSION2 = 136
M.CURSE = 137
M.DESTINY_BOND = 138
M.ENCORE = 139
M.FORESIGHT = 140
M.HEAL_BELL = 141
M.MEAN_LOOK = 142
M.NIGHTMARE = 143
M.PAIN_SPLIT = 144
M.PERISH_SONG = 145
M.PSYCH_UP = 146
M.RAPID_SPIN = 147
M.SKETCH = 148
M.SPIKES = 149
M.SPITE = 150
M.SP_DEF_UP_2 = 151
M.SWAGGER = 152
M.TELEPORT = 153
M.SP_DEF_UP = 154
M.SP_DEF_DOWN = 155
M.SP_DEF_DOWN_2 = 156
M.SKULL_BASH = 157

M.CATEGORIES = {
  [0] = "none",
  [1] = "other",
  [2] = "status_side",
  [3] = "drain",
  [4] = "status_side",
  [5] = "status_side",
  [6] = "status_side",
  [7] = "other",
  [8] = "drain",
  [9] = "meta",
  [10] = "stat", [11] = "stat", [12] = "stat", [13] = "stat",
  [14] = "stat", [15] = "stat",
  [16] = "other",
  [17] = "other",
  [18] = "stat", [19] = "stat", [20] = "stat", [21] = "stat",
  [22] = "stat", [23] = "stat",
  [24] = "meta",
  [25] = "meta",
  [26] = "other",
  [27] = "thrash",
  [28] = "flow",
  [29] = "multihit",
  [30] = "other",
  [31] = "status_side",
  [32] = "status_primary",
  [33] = "status_side", [34] = "status_side", [35] = "status_side",
  [36] = "status_side", [37] = "status_side",
  [38] = "fixed",
  [39] = "charge",
  [40] = "fixed",
  [41] = "fixed",
  [42] = "trap",
  [43] = "charge",
  [44] = "multihit",
  [45] = "recoil",
  [46] = "volatile",
  [47] = "volatile",
  [48] = "recoil",
  [49] = "status_primary",
  [50] = "stat", [51] = "stat", [52] = "stat", [53] = "stat",
  [54] = "stat", [55] = "stat",
  [56] = "heal",
  [57] = "meta",
  [58] = "stat", [59] = "stat", [60] = "stat", [61] = "stat",
  [62] = "stat", [63] = "stat",
  [64] = "volatile",
  [65] = "volatile",
  [66] = "status_primary",
  [67] = "status_primary",
  [68] = "status_side", [69] = "status_side", [70] = "status_side",
  [71] = "status_side",
  [72] = "unused", [73] = "unused", [74] = "unused", [75] = "unused",
  [76] = "status_side",
  [77] = "multihit",
  [78] = "unused",
  [79] = "volatile",
  [80] = "flow",
  [81] = "other",
  [82] = "meta",
  [83] = "meta",
  [84] = "volatile",
  [85] = "other",
  [86] = "volatile",
  [87] = "status_side", [88] = "status_side",
  [89] = "status_side", [90] = "status_side", [91] = "status_side",
  [92] = "status_side", [93] = "status_side",
  [94] = "status_side", [95] = "status_side", [96] = "status_side",
  [97] = "status_side", [98] = "status_side",
  [99] = "other", [100] = "other",
  [101] = "charge",
  [102] = "meta", [103] = "volatile", [104] = "volatile",
  [105] = "status_primary",
  [106] = "other", [107] = "other", [108] = "other", [109] = "fixed",
  [110] = "other", [111] = "other", [112] = "multihit", [113] = "other",
  [114] = "other", [115] = "stat", [116] = "multihit", [117] = "other",
  [118] = "other", [119] = "other", [120] = "volatile", [121] = "volatile",
  [122] = "fixed", [123] = "fixed", [124] = "field", [125] = "field",
  [126] = "field", [127] = "charge", [128] = "heal", [129] = "heal",
  [130] = "heal", [131] = "fixed", [132] = "fixed",
  [133] = "volatile", [134] = "flow", [135] = "stat", [136] = "meta",
  [137] = "stat", [138] = "volatile", [139] = "volatile", [140] = "volatile",
  [141] = "heal", [142] = "volatile", [143] = "volatile", [144] = "heal",
  [145] = "field", [146] = "stat", [147] = "other", [148] = "meta",
  [149] = "field", [150] = "volatile", [151] = "stat", [152] = "status_primary",
  [153] = "flow", [154] = "stat", [155] = "stat", [156] = "stat",
  [157] = "charge",
}

M.STAGE_MIN = -6
M.STAGE_MAX = 6

-- BattleCommand_Screen's `ld a, 5`: a Reflect or Light Screen counts five
-- between-turn ticks (HandleScreens), the turn it went up included.
M.SCREEN_TURNS = 5

-- Gen1 stage multipliers as percents (25/100 .. 400/100).
M.STAGE_MULT = {
  [-6] = 25, [-5] = 28, [-4] = 33, [-3] = 40, [-2] = 50, [-1] = 66,
  [0] = 100,
  [1] = 150, [2] = 200, [3] = 250, [4] = 300, [5] = 350, [6] = 400,
}

local BY_NAME = {}
for id = 0, M.MAX_EFFECT_ID do
  BY_NAME[M.NAMES[id]] = id
end

local function int(value, fallback)
  local n = tonumber(value)
  if not n or n ~= n then return fallback end
  return floor(n)
end

-- Crystal / Gold sheets name effects EFFECT_* (moveEffectOrder), not the
-- pret/pokered *_EFFECT tokens this table is numbered by.  `moveOf` stores
-- `idOf(def.effect) or 0`, so an unmapped name becomes NO_ADDITIONAL_EFFECT
-- and every 0-power status move says "But nothing happened".  That is why
-- Leer / Hypnosis / Screech worked in engine 1v1 (gen2/Battle.lua) and
-- failed in every BattleSim2 fight -- 2v2 co-op, mediated PvP, solo-on.
--
-- Map every EFFECT_* that already has a handler onto that handler.  The
-- Gold-native rows above answer under their own names (BY_NAME), SKY ATTACK
-- among them: its script is RazorWind's plus `effectchance` / `flinchtarget`,
-- which CHARGE_EFFECT does not run.  Gen 2 only moves (Spikes, …) stay
-- unmapped and still no-op honestly.  Charge / vanish aliases keep the same ids
-- as before.  Wave 3 (R2c) moved SOLARBEAM (its sun skip and rain halving),
-- LEVEL_DAMAGE and PSYWAVE (SEISMIC TOSS and NIGHT SHADE deal the user's
-- level, PSYWAVE its own roll -- as 41 they dealt their sheet power, 1), the
-- three time-of-day heals (as 56 they healed half whatever the weather) and
-- DEFENSE_CURL (as 11 it never curled) off these folds onto ids of their own.
-- Wave 4 (R2d) moved SKULL BASH off 39 onto 157 (its Defense raise) and gave
-- every status / field script a row of its own (133..156), BY_NAME's.
local GEN2_EFFECT_ID = {
  EFFECT_NORMAL_HIT = 0,
  EFFECT_SLEEP = 32,
  EFFECT_POISON_HIT = 2,
  EFFECT_LEECH_HIT = 3,
  EFFECT_BURN_HIT = 4,
  EFFECT_FREEZE_HIT = 5,
  EFFECT_PARALYZE_HIT = 6,
  EFFECT_SELFDESTRUCT = 7,
  EFFECT_DREAM_EATER = 8,
  EFFECT_MIRROR_MOVE = 9,
  EFFECT_ATTACK_UP = 10,
  EFFECT_DEFENSE_UP = 11,
  EFFECT_SPEED_UP = 12,
  EFFECT_SP_ATK_UP = 13,
  EFFECT_ACCURACY_UP = 14,
  EFFECT_EVASION_UP = 15,
  EFFECT_ALWAYS_HIT = 17,
  EFFECT_ATTACK_DOWN = 18,
  EFFECT_DEFENSE_DOWN = 19,
  EFFECT_SPEED_DOWN = 20,
  EFFECT_SP_ATK_DOWN = 21,
  EFFECT_ACCURACY_DOWN = 22,
  EFFECT_EVASION_DOWN = 23,
  EFFECT_CONVERSION = 24,
  EFFECT_RESET_STATS = 25,
  EFFECT_BIDE = 26,
  EFFECT_RAMPAGE = 27,
  EFFECT_FORCE_SWITCH = 28,
  EFFECT_MULTI_HIT = 29,
  EFFECT_FLINCH_HIT = 31,
  EFFECT_PAY_DAY = 16,
  EFFECT_OHKO = 38,
  EFFECT_RAZOR_WIND = 39,
  EFFECT_SUPER_FANG = 40,
  EFFECT_STATIC_DAMAGE = 41,
  EFFECT_TRAP_TARGET = 42,
  EFFECT_FLY = 43,
  EFFECT_DOUBLE_HIT = 44,
  EFFECT_JUMP_KICK = 45,
  EFFECT_MIST = 46,
  EFFECT_FOCUS_ENERGY = 47,
  EFFECT_RECOIL_HIT = 48,
  EFFECT_CONFUSE = 49,
  EFFECT_ATTACK_UP_2 = 50,
  EFFECT_DEFENSE_UP_2 = 51,
  EFFECT_SPEED_UP_2 = 52,
  EFFECT_SP_ATK_UP_2 = 53,
  EFFECT_ACCURACY_UP_2 = 54,
  EFFECT_EVASION_UP_2 = 55,
  EFFECT_HEAL = 56,
  EFFECT_TRANSFORM = 57,
  EFFECT_ATTACK_DOWN_2 = 58,
  EFFECT_DEFENSE_DOWN_2 = 59,
  EFFECT_SPEED_DOWN_2 = 60,
  EFFECT_SP_ATK_DOWN_2 = 61,
  EFFECT_ACCURACY_DOWN_2 = 62,
  EFFECT_EVASION_DOWN_2 = 63,
  EFFECT_LIGHT_SCREEN = 64,
  EFFECT_REFLECT = 65,
  EFFECT_POISON = 66,
  EFFECT_PARALYZE = 67,
  EFFECT_ATTACK_DOWN_HIT = 68,
  EFFECT_DEFENSE_DOWN_HIT = 69,
  EFFECT_SPEED_DOWN_HIT = 70,
  EFFECT_SP_ATK_DOWN_HIT = 71,
  EFFECT_CONFUSE_HIT = 76,
  EFFECT_POISON_MULTI_HIT = 77,
  EFFECT_SUBSTITUTE = 79,
  EFFECT_HYPER_BEAM = 80,
  EFFECT_RAGE = 81,
  EFFECT_MIMIC = 82,
  EFFECT_METRONOME = 83,
  EFFECT_LEECH_SEED = 84,
  EFFECT_SPLASH = 85,
  EFFECT_DISABLE = 86,
}

function M.idOf(name)
  if type(name) ~= "string" then return nil end
  return BY_NAME[name] or GEN2_EFFECT_ID[name]
end

function M.nameOf(id)
  id = int(id, nil)
  if id == nil or id < 0 or id > M.MAX_EFFECT_ID then return nil end
  return M.NAMES[id]
end

function M.category(id)
  id = int(id, nil)
  if id == nil or id < 0 or id > M.MAX_EFFECT_ID then return nil end
  return M.CATEGORIES[id]
end

-- What a move is *called* in a sentence: the display name its sheet carried
-- (PROTOCOL 26), or its registry id when it carried none.  Turn.lua keeps the
-- same one-line rule; both are prose, never a key something indexes.
local function moveLabel(move, fallback)
  fallback = fallback or "move"
  if type(move) ~= "table" then return fallback end
  local name = move.name
  if type(name) == "string" and name ~= "" then return name end
  local id = move.id
  if type(id) == "string" and id ~= "" then return id end
  return fallback
end

function M.clampStage(stage)
  local s = int(stage, 0)
  if s < M.STAGE_MIN then return M.STAGE_MIN end
  if s > M.STAGE_MAX then return M.STAGE_MAX end
  return s
end

function M.stageMult(stage)
  return M.STAGE_MULT[M.clampStage(stage)]
end

-- CalcBattleStats (pokecrystal engine/battle/effect_commands.asm:4817-4875):
-- the unmodified stat times the stage's ratio from data/battle/
-- stat_multipliers.asm, then a quotient of 0 is raised to 1 and one at or past
-- MAX_STAT_VALUE is held at 999.  The cart's ratios are num/den pairs (15/10,
-- 2/1, 25/10 ...); each is the percent above over 100 exactly, so the floor
-- lands on the same integer.
function M.applyStage(base, stage)
  local value = floor(max(0, int(base, 0)) * M.stageMult(stage) / 100)
  if value < 1 then return 1 end
  if value > M.MAX_STAT_VALUE then return M.MAX_STAT_VALUE end
  return value
end

-- Crystal's badge rules, as gen1recomp ports them (src/battle/gen2/Battle.lua,
-- the engine every number here was checked against).  `badges` is a set of
-- Gold badge ids -> true: the eight Johto ids and the eight Kanto ids that
-- name the rows of the engine's BADGE_TYPE_BOOSTS (ZEPHYR ... RISING, BOULDER
-- ... EARTH), which is what a Gold client uploads.  Gen 1's BOULDERBADGE-style
-- ids mean nothing here: Gold has no badge by that name.
--
-- A fighter only holds a set where the cart would have applied it -- side a
-- of a fight against the computer; Turn.create drops it in 1v1 / coop_pvp
-- (link battles, where Crystal's BadgeStatBoosts returns early) and on side b
-- (Turn.BADGE_MODES) -- so nothing below has to ask what kind of fight it is.

-- BadgeStatBoosts (engine/battle/core.asm:6534; port Battle.lua:209-220,
-- BADGE_STAT_BOOSTS): every other wJohtoBadges bit boosts a stat, walked
-- after PlainBadge and MineralBadge swap places, which is what lands Mineral
-- on Defense and Plain on Speed.  Kanto badges boost no stat; Sp. Def has no
-- badge of its own and is only ever reached by Glacier's buggy tail below.
local BADGE_FOR_STAT = {
  atk = "ZEPHYR",
  def = "MINERAL",
  spe = "PLAIN",
  spa = "GLACIER",
}
M.BADGE_FOR_STAT = BADGE_FOR_STAT

-- MAX_STAT_VALUE, the ceiling BoostStat caps a boosted stat at.
M.MAX_STAT_VALUE = 999

-- BoostStat (engine/battle/core.asm:6590; port Battle.lua:787-792):
-- raise a stat by an eighth, capped at MAX_STAT_VALUE.  The eighth is a plain
-- shift, so a stat under 8 gains nothing.
function M.boostStat(value)
  local v = max(0, int(value, 0))
  return min(M.MAX_STAT_VALUE, v + floor(v / 8))
end

-- BadgeStatBoosts' buggy tail (port Battle.lua:794-809, glacierBoostsSpDef):
-- the closing Special Defense check does `srl a` assuming `a` still holds the
-- badge bits, but when GlacierBadge fired for Special Attack the BoostStat
-- before it overwrote `a` with its cap-check arithmetic.  So with Glacier
-- owned, whether Sp. Def is ALSO boosted turns on the boosted Sp. Atk:
--   * at or past the 999 cap `a` leaves as LOW(999) = $e7, odd: boosted;
--   * otherwise `a` is high(v) - 3 - borrow, the borrow set when low(v) <
--     LOW(999), and the bit shifted out of it decides.
-- (pokegold's own comment marks the check buggy.)  `% 256` here is Lua's
-- floored modulo, which is the byte wrap; the JS twin spells it out.
function M.glacierBoostsSpDef(boostedSpa)
  local v = max(0, int(boostedSpa, 0))
  if v >= M.MAX_STAT_VALUE then return true end
  local borrow = (v % 256) < 231 and 1 or 0
  local a = (floor(v / 256) - 3 - borrow) % 256
  return a % 2 == 1
end

-- One stat plus its owner's badge boost.  `wireStatKey` is atk/def/spe/spa/
-- spd.  `spa` is the same monster's Sp. Atk as BadgeStatBoosts finds it --
-- already staged, because CalcPlayerStats runs CalcBattleStats first -- and
-- is read only for `spd`: it is what Glacier's tail is decided on.
function M.badgeBoost(statValue, wireStatKey, badges, spa)
  local base = max(0, int(statValue, 0))
  if type(badges) ~= "table" then return base end
  local badge = BADGE_FOR_STAT[wireStatKey]
  if badge then
    if badges[badge] then return M.boostStat(base) end
    return base
  end
  if wireStatKey == "spd" and badges.GLACIER
     and M.glacierBoostsSpDef(M.boostStat(spa)) then
    return M.boostStat(base)
  end
  return base
end

-- The stat a hit, the turn order or a confusion self-hit reads: the battle
-- stat, rebuilt the way CalcPlayerStats does it (pokecrystal engine/battle/
-- effect_commands.asm:4778-4797) --
--
--   1. CalcBattleStats: the unmodified stat x the stage ratio, 1..999
--      (`applyStage`);
--   2. BadgeStatBoosts (engine/battle/core.asm:6768): +1/8, held at 999, and
--      Glacier's Sp. Def tail reading the staged-then-boosted Sp. Atk;
--   3. ApplyPrzEffectOnSpeed / ApplyBrnEffectOnAttack (core.asm:6585-6669):
--      paralysis quarters Speed and burn halves Attack, each at least 1.
--
-- This is the cart's CalcPlayerStats, the rebuild every stage change, Haze
-- and a status-cure item run (each farcalls it), and a status landing
-- mid-fight cuts the stat it finds -- already staged and boosted -- so the
-- order above is also what a hit reads after one.  The cart computes the
-- stat in another order at three points, which `storedStat` below keeps:
-- a switch-in (InitBattleMon, LoadEnemyMon), Transform and an in-battle
-- level-up.
--
-- `mon` is a sheet: { stats, stages, status }.  `badges` is its seat's set
-- (nil for every seat the cart would not boost; see Turn.BADGE_MODES).
function M.battleStat(mon, key, badges)
  mon = type(mon) == "table" and mon or {}
  local stats = type(mon.stats) == "table" and mon.stats or {}
  local stages = type(mon.stages) == "table" and mon.stages or {}
  local value = M.applyStage(stats[key], stages[key])
  local spa = nil
  if key == "spd" then spa = M.applyStage(stats.spa, stages.spa) end
  value = M.badgeBoost(value, key, badges, spa)
  if key == "atk" and mon.status == "burn" then value = Status.burnAttack(value) end
  if key == "spe" and mon.status == "paralysis" then
    value = Status.paralysisSpeed(value)
  end
  return value
end

-- ------------------------------------------------------------------
-- the stored battle stats (docs/plans/gen12-referee-gaps-fix.md, R2b)
-- ------------------------------------------------------------------
--
-- The cart keeps wBattleMonStats -- what a hit and the turn order read -- and
-- rebuilds it with CalcPlayerStats (`battleStat`, stage -> badge -> status)
-- on every stage change, Haze and status cure.  Three other writers use
-- another order, and what they leave stands until the next rebuild:
--
--   * "init": InitBattleMon (engine/battle/core.asm:3869-3907), the
--     player's switch-in -- the party stats, then ApplyStatusEffectOnPlayerStats,
--     then BadgeStatBoosts: status BEFORE badge -- and InitEnemyMon (:3954),
--     a link fight's foe, the same with no badge; and GiveExperiencePoints'
--     in-battle level-up (:7270-7280), ApplyStatLevelMultiplierOnAllStats,
--     then the status, then the badge -- the same order over the stages.
--   * "load": LoadEnemyMon (:5963), the computer's switch-in outside a link
--     fight -- the party stats and nothing else (docs/bugs_and_glitches.md,
--     "PRZ and BRN stat reductions don't apply to switched Pokemon").
--   * Transform (move_effects/transform.asm): the target's wEnemyMonStats,
--     copied as they stand -- its own badge and status in them.
--
-- `mon.statSnap` holds such a result with the inputs it was taken from (the
-- unmodified stats, the stages, the status and the seat's badges).  It stands
-- while every input does; the first one that moves -- a stage change, a
-- status landing or cured, a level -- is the cart's rebuild, so the snapshot
-- is dropped and the read is `battleStat` again.  `dropSnap` is the explicit
-- form, for the rebuild that may leave every input where it was (Haze on
-- stages already at 0).
M.STAT_KEYS = { "atk", "def", "spe", "spa", "spd" }
local STAGE_KEYS = { "atk", "def", "spe", "spa", "spd", "acc", "eva" }

-- One battle stat in the "init" order: stage, then the status penalty, then
-- the badge (Glacier's tail reading the staged-and-boosted Sp. Atk, which no
-- status touches), and in the "load" order: stage alone.
--
-- From wave 4, the "pass" order: PassedBattleMonEntrance (engine/battle/
-- core.asm), BATON PASS's send-out -- InitBattleMon's status penalty and
-- badge boost over the party stats, THEN ApplyStatLevelMultiplierOnAllStats
-- multiplying those by the levels the monster was passed.  (The computer's
-- pass is LoadEnemyMon's party stats and the levels -- the "load" order.)
local function orderedStat(mon, key, badges, order)
  local stats = type(mon.stats) == "table" and mon.stats or {}
  local stages = type(mon.stages) == "table" and mon.stages or {}
  if order == "pass" then
    local base = max(1, int(stats[key], 1))
    if key == "atk" and mon.status == "burn" then base = Status.burnAttack(base) end
    if key == "spe" and mon.status == "paralysis" then
      base = Status.paralysisSpeed(base)
    end
    base = M.badgeBoost(base, key, badges, stats.spa)
    return M.applyStage(base, stages[key])
  end
  local value = M.applyStage(stats[key], stages[key])
  if order == "load" then return value end
  if key == "atk" and mon.status == "burn" then value = Status.burnAttack(value) end
  if key == "spe" and mon.status == "paralysis" then
    value = Status.paralysisSpeed(value)
  end
  local spa = nil
  if key == "spd" then spa = M.applyStage(stats.spa, stages.spa) end
  return M.badgeBoost(value, key, badges, spa)
end

-- CalcMonStatC (pokecrystal engine/pokemon/move_mon.asm:1424-1610, pokegold
-- the same) for one stat: ((base + DV) * 2 + GetSquareRoot(stat exp) / 4) *
-- level / 100, plus 5 -- or, for HP, plus the level and 10 -- held at
-- MAX_STAT_VALUE.  GetSquareRoot is the smallest root whose square is not
-- below the stat exp, 1 for none, 255 at most.
local function squareRoot(exp)
  local e = max(0, int(exp, 0))
  for b = 1, 254 do
    if b * b >= e then return b end
  end
  return 255
end

local function monStat(base, dv, exp, level, hp)
  local value = (max(0, int(base, 0)) + max(0, int(dv, 0))) * 2 + floor(squareRoot(exp) / 4)
  value = floor(value * level / 100)
  value = value + (hp and (level + 10) or 5)
  if value > M.MAX_STAT_VALUE then value = M.MAX_STAT_VALUE end
  return value
end

-- CalcMonStats over a Gold sheet's K7 blocks (`base` keyed hp atk def spe spa
-- spd, `dvs` atk def spe spc, `statExp` hp atk def spe spc) at `level`:
-- returns the five stats and the max HP, or nil without `base` and `dvs`.
-- The HP DV is built from the four's low bits, and both specials read the
-- one Special DV and stat exp.
function M.calcMonStats(base, dvs, statExp, level)
  if type(base) ~= "table" or type(dvs) ~= "table" then return nil end
  local exp = type(statExp) == "table" and statExp or {}
  local lv = max(1, int(level, 1))
  local hpDv = (int(dvs.atk, 0) % 2) * 8 + (int(dvs.def, 0) % 2) * 4
    + (int(dvs.spe, 0) % 2) * 2 + (int(dvs.spc, 0) % 2)
  return {
    stats = {
      atk = monStat(base.atk, dvs.atk, exp.atk, lv, false),
      def = monStat(base.def, dvs.def, exp.def, lv, false),
      spe = monStat(base.spe, dvs.spe, exp.spe, lv, false),
      spa = monStat(base.spa, dvs.spc, exp.spc, lv, false),
      spd = monStat(base.spd, dvs.spc, exp.spc, lv, false),
    },
    maxHp = monStat(base.hp, hpDv, exp.hp, lv, true),
  }
end

-- The five battle stats in `order` ("calc", "init", "load" or "pass").
function M.calcStats(mon, badges, order)
  local out = {}
  for _, key in ipairs(M.STAT_KEYS) do
    if order == "calc" then
      out[key] = M.battleStat(mon, key, badges)
    else
      out[key] = orderedStat(mon, key, badges, order)
    end
  end
  return out
end

-- Record `values` as the monster's battle stats, with the inputs they stand on.
function M.snapStats(mon, badges, values)
  local stats = type(mon.stats) == "table" and mon.stats or {}
  local stages = type(mon.stages) == "table" and mon.stages or {}
  local snap = { values = {}, stats = {}, stages = {}, status = mon.status, badges = badges }
  for _, key in ipairs(M.STAT_KEYS) do
    snap.values[key] = values[key]
    snap.stats[key] = stats[key]
  end
  for _, key in ipairs(STAGE_KEYS) do snap.stages[key] = M.clampStage(stages[key]) end
  mon.statSnap = snap
end

function M.dropSnap(mon)
  if type(mon) == "table" then mon.statSnap = nil end
end

local function snapStands(snap, mon, badges)
  if snap.status ~= mon.status or snap.badges ~= badges then return false end
  local stats = type(mon.stats) == "table" and mon.stats or {}
  local stages = type(mon.stages) == "table" and mon.stages or {}
  for _, key in ipairs(M.STAT_KEYS) do
    if snap.stats[key] ~= stats[key] then return false end
  end
  for _, key in ipairs(STAGE_KEYS) do
    if snap.stages[key] ~= M.clampStage(stages[key]) then return false end
  end
  return true
end

-- The battle stat a hit, the turn order or RaiseStat's 999 test reads: the
-- snapshot while it stands, CalcPlayerStats's order otherwise.
function M.storedStat(mon, key, badges)
  if type(mon) ~= "table" then return M.battleStat(mon, key, badges) end
  local snap = mon.statSnap
  if snap then
    if snapStands(snap, mon, badges) then return snap.values[key] end
    mon.statSnap = nil
  end
  return M.battleStat(mon, key, badges)
end

-- DoBadgeTypeBoosts (pokecrystal engine/battle/misc.asm:146; port
-- Battle.lua:835-848, badgeTypeBoost; rows from data/types/
-- badge_type_boosts.asm in the cart's own walk order -- the eight wJohtoBadges
-- bits, then the eight wKantoBadges bits).  On the player's turn the move's
-- type is looked up here, each type at most once, and owning that row's badge
-- adds an eighth to the damage (Damage.compute's `badgeTypeBoost`).  `type`
-- is the type's registry id, which the ruleset's `typeIds` resolves a move's
-- chart index to -- PSYCHIC_TYPE is Psychic's, because PSYCHIC is a move.
M.BADGE_TYPE_BOOSTS = {
  { badge = "ZEPHYR", type = "FLYING" },
  { badge = "HIVE", type = "BUG" },
  { badge = "PLAIN", type = "NORMAL" },
  { badge = "FOG", type = "GHOST" },
  { badge = "MINERAL", type = "STEEL" },
  { badge = "STORM", type = "FIGHTING" },
  { badge = "GLACIER", type = "ICE" },
  { badge = "RISING", type = "DRAGON" },
  { badge = "BOULDER", type = "ROCK" },
  { badge = "CASCADE", type = "WATER" },
  { badge = "THUNDER", type = "ELECTRIC" },
  { badge = "RAINBOW", type = "GRASS" },
  { badge = "SOUL", type = "POISON" },
  { badge = "MARSH", type = "PSYCHIC_TYPE" },
  { badge = "VOLCANO", type = "FIRE" },
  { badge = "EARTH", type = "GROUND" },
}

-- Whether a move of type `typeId` is boosted for a fighter holding `badges`.
-- The first row naming the type answers, as the cart's scan does.
function M.badgeTypeBoost(typeId, badges)
  if type(badges) ~= "table" or type(typeId) ~= "string" then return false end
  for _, row in ipairs(M.BADGE_TYPE_BOOSTS) do
    if row.type == typeId then return badges[row.badge] == true end
  end
  return false
end

-- ------------------------------------------------------------------
-- Phase 1 primary handlers
-- ------------------------------------------------------------------

local STAT_LABELS = {
  atk = "ATTACK", def = "DEFENSE", spe = "SPEED",
  spa = "SP.ATK", spd = "SP.DEF", acc = "ACCURACY", eva = "EVASION",
}
M.STAT_LABELS = STAT_LABELS

-- effect id -> { stat, delta, selfTarget }
local STAT_EFFECTS = {
  [10] = { stat = "atk", delta = 1, selfTarget = true },
  [11] = { stat = "def", delta = 1, selfTarget = true },
  [12] = { stat = "spe", delta = 1, selfTarget = true },
  [13] = { stat = "spa", delta = 1, selfTarget = true },
  [14] = { stat = "acc", delta = 1, selfTarget = true },
  [15] = { stat = "eva", delta = 1, selfTarget = true },
  [18] = { stat = "atk", delta = -1, selfTarget = false },
  [19] = { stat = "def", delta = -1, selfTarget = false },
  [20] = { stat = "spe", delta = -1, selfTarget = false },
  [21] = { stat = "spa", delta = -1, selfTarget = false },
  [22] = { stat = "acc", delta = -1, selfTarget = false },
  [23] = { stat = "eva", delta = -1, selfTarget = false },
  [50] = { stat = "atk", delta = 2, selfTarget = true },
  [51] = { stat = "def", delta = 2, selfTarget = true },
  [52] = { stat = "spe", delta = 2, selfTarget = true },
  [53] = { stat = "spa", delta = 2, selfTarget = true },
  [54] = { stat = "acc", delta = 2, selfTarget = true },
  [55] = { stat = "eva", delta = 2, selfTarget = true },
  [58] = { stat = "atk", delta = -2, selfTarget = false },
  [59] = { stat = "def", delta = -2, selfTarget = false },
  [60] = { stat = "spe", delta = -2, selfTarget = false },
  [61] = { stat = "spa", delta = -2, selfTarget = false },
  [62] = { stat = "acc", delta = -2, selfTarget = false },
  [63] = { stat = "eva", delta = -2, selfTarget = false },
  -- Gold's SP. DEF rows (wave 4): BattleCommand_SpecialDefenseUp / Up2 /
  -- Down / Down2, which no Gen 1 id names -- AMNESIA is the Up2.
  [151] = { stat = "spd", delta = 2, selfTarget = true },
  [154] = { stat = "spd", delta = 1, selfTarget = true },
  [155] = { stat = "spd", delta = -1, selfTarget = false },
  [156] = { stat = "spd", delta = -2, selfTarget = false },
}

local PHASE1_PRIMARY = {
  [10] = true, [11] = true, [12] = true, [13] = true, [14] = true, [15] = true,
  [18] = true, [19] = true, [20] = true, [21] = true, [22] = true, [23] = true,
  [25] = true, [32] = true, [49] = true, [50] = true, [51] = true, [52] = true,
  [53] = true, [54] = true, [55] = true, [56] = true, [58] = true, [59] = true,
  [60] = true, [61] = true, [62] = true, [63] = true, [66] = true, [67] = true,
  [84] = true, [85] = true, [86] = true,
  [103] = true, [104] = true, [105] = true, -- LOCK_ON, SAFEGUARD, TOXIC
  [115] = true,                             -- DEFENSE_CURL
  -- Wave 4: the status scripts whose command works on the user and its
  -- target alone (`applyPrimary` below) -- ATTRACT, BELLY DRUM, CURSE,
  -- DESTINY BOND, FORESIGHT, MEAN LOOK, NIGHTMARE, PSYCH UP, SPITE, SWAGGER
  -- and the SP. DEF rows.
  [133] = true, [135] = true, [137] = true, [138] = true, [140] = true,
  [142] = true, [143] = true, [146] = true, [150] = true, [151] = true,
  [152] = true, [154] = true, [155] = true, [156] = true,
}

-- The 0-power Gold scripts whose command works on the field or the user's
-- own record, which Turn runs itself (it holds the turn order, the weather
-- and the clock): PROTECT / DETECT and ENDURE (`_protect`), RAIN DANCE, SUNNY
-- DAY and SANDSTORM (`_startWeather`), MORNING SUN, SYNTHESIS and MOONLIGHT
-- (`_timeHeal`).  None of them runs `checkhit`.
M.FIELD_MOVES = {
  [120] = true, [121] = true, [124] = true, [125] = true, [126] = true,
  [128] = true, [129] = true, [130] = true,
  -- Wave 4: BATON PASS (the switch, `_batonPass`), HEAL BELL (the party,
  -- `_healBell`), PERISH SONG (every monster on the field, `_perishSong`),
  -- SKETCH (the party's move list and the link check, `_sketch`), SPIKES
  -- (the foe's side, `_spikes`) and TELEPORT (the escape, `_teleport`).
  [134] = true, [141] = true, [145] = true, [148] = true, [149] = true,
  [153] = true,
}

-- The 0-power Gold scripts with a `checkhit` whose command Turn runs itself
-- after it (`_statusMove`): CONVERSION2 (the type chart and its byte loop),
-- ENCORE (the target's choice this turn) and PAIN SPLIT (both HP bars).
M.TURN_COMMANDS = { [136] = true, [139] = true, [144] = true }

-- The commands that read wAttackMissed themselves, after the script's
-- `checkhit`, and say their own failure line (`applyPrimary`'s `ctx.missed`,
-- Turn `_statusMove`): SleepTarget, Confuse, Poison (POISON and TOXIC),
-- Paralyze, Mimic, LeechSeed, Disable, LockOn, Attract, Conversion2, Encore,
-- Foresight, PainSplit, Spite, and SWAGGER's RaiseStat / failuretext.  A miss
-- of any other `checkhit` script ends on Turn's own miss line.
M.READS_MISS = {
  [32] = true, [49] = true, [66] = true, [67] = true, [82] = true, [84] = true,
  [86] = true, [103] = true, [105] = true, [133] = true, [136] = true,
  [139] = true, [140] = true, [144] = true, [150] = true, [152] = true,
}

-- The referee-numbered move scripts with no `checkhit` (data/moves/
-- effects.asm): MIRROR MOVE, the stat-raising moves, CONVERSION, HAZE,
-- BIDE's first use (`unleashenergy` ends it before its `checkhit`), MIST,
-- FOCUS ENERGY, the heals, TRANSFORM, the screens, SUBSTITUTE, METRONOME,
-- SPLASH, SLEEP TALK and SAFEGUARD -- and from wave 3 DEFENSE CURL,
-- FUTURE SIGHT's use (its `checkhit` stands after `futuresight`, which ends
-- the move on the turn it is used), PROTECT / DETECT, ENDURE, COUNTER and
-- MIRROR COAT (their own commands set wAttackMissed), the weather moves and
-- the time-of-day heals.  No CheckHit of the cart's runs for them, so Turn
-- runs none either (`_useMove`): no accuracy byte, no `.Protect`, and none of
-- them spends the target's LOCK-ON -- RAIN DANCE's and SUNNY DAY's 90% never
-- misses.  Wave 4 adds BATON PASS, BELLY DRUM, CURSE, DESTINY BOND, HEAL
-- BELL, MEAN LOOK, NIGHTMARE, PERISH SONG, PSYCH UP, SKETCH, SPIKES, the SP.
-- DEF raises and TELEPORT (data/moves/effects.asm: none runs `checkhit`).
M.NO_CHECKHIT = {
  [9] = true, [10] = true, [11] = true, [12] = true, [13] = true, [14] = true,
  [15] = true, [24] = true, [25] = true, [26] = true, [46] = true, [47] = true,
  [50] = true, [51] = true, [52] = true, [53] = true, [54] = true, [55] = true,
  [56] = true, [57] = true, [64] = true, [65] = true, [79] = true, [83] = true,
  [85] = true, [102] = true, [104] = true,
  [115] = true, [119] = true, [120] = true, [121] = true, [122] = true,
  [123] = true, [124] = true, [125] = true, [126] = true, [128] = true,
  [129] = true, [130] = true,
  [134] = true, [135] = true, [137] = true, [138] = true, [141] = true,
  [142] = true, [143] = true, [145] = true, [146] = true, [148] = true,
  [149] = true, [151] = true, [153] = true, [154] = true,
}

-- CheckHit's `.LockOn`: a locked-on target in the sky is still missed by
-- these three (`cp EARTHQUAKE / FISSURE / MAGNITUDE / ret z` into
-- `.FlyDigMoves`).
M.LOCK_ON_SKY_MISS = { EARTHQUAKE = true, FISSURE = true, MAGNITUDE = true }

-- SLEEP TALK's `.check_two_turn_move` (move_effects/sleep_talk.asm): the
-- effects it never calls -- RAZOR WIND (39), FLY / DIG (43), SKY ATTACK,
-- BIDE, SOLARBEAM (127 from wave 3) and SKULL BASH (157 from wave 4).
M.SLEEP_TALK_EXCLUDED = {
  [26] = true, [39] = true, [43] = true, [101] = true, [127] = true,
  [157] = true,
}

-- The scripts with `checksafeguard` after their `checkhit` (DoSleep, DoConfuse,
-- DoPoison -- TOXIC's too -- and DoParalyze).
M.CHECKS_SAFEGUARD = { [32] = true, [49] = true, [66] = true, [67] = true, [105] = true }

function M.isPhase1Primary(effectId)
  effectId = int(effectId, nil)
  if effectId == nil then return false end
  return PHASE1_PRIMARY[effectId] == true
end

local PHASE5_VOLATILE = {
  [24] = true, [46] = true, [47] = true, [57] = true,
  [64] = true, [65] = true, [79] = true,
}

local PHASE6_PRIMARY = {
  [82] = true, -- MIMIC_EFFECT
}

function M.isPhase5Volatile(effectId)
  effectId = int(effectId, nil)
  if effectId == nil then return false end
  return PHASE5_VOLATILE[effectId] == true
end

function M.isPhase6Primary(effectId)
  effectId = int(effectId, nil)
  if effectId == nil then return false end
  return PHASE6_PRIMARY[effectId] == true
end

function M.handlesPrimary(effectId)
  return M.isPhase1Primary(effectId) or M.isPhase5Volatile(effectId)
      or M.isPhase6Primary(effectId)
end

function M.hasMajorStatus(mon)
  if not mon or not mon.status then return false end
  local s = mon.status
  return s == "sleep" or s == "poison" or s == "burn"
      or s == "freeze" or s == "paralysis" or s == "toxic"
end

local function fighterFields(fighter)
  return { slot = fighter.slot, side = fighter.side }
end

-- Whether a monster has the type a chart index names (nil names none).
local function hasType(mon, typeIndex)
  if typeIndex == nil or type(mon.types) ~= "table" then return false end
  for i = 1, #mon.types do
    if mon.types[i] == typeIndex then return true end
  end
  return false
end

-- PrintDidntAffect / PrintDidntAffect2's line (DidntAffect1Text), a status
-- command's own failure: "It didn't affect <TARGET>!" -- not the matchup's
-- "It doesn't affect" (DoesntAffectText).
function M.didntAffectLine(mon)
  return "It didn't affect " .. mon.species .. "!"
end

-- BattleCommand_Safeguard's `ld a, 5`: five between-turn ticks
-- (HandleSafeguard), like a screen's.
M.SAFEGUARD_TURNS = 5

-- BattleCommand_Transform's `.pp_loop`: every copied move gets 5 PP (SKETCH 1).
M.TRANSFORM_PP = 5

-- BattleCommand_Mimic's `ld [hl], 5`: the mimicked move's PP in the slot.
M.MIMIC_PP = 5

-- BattleCommand_Heal's REST: `ld [hl], REST_SLEEP_TURNS + 1` (constants/
-- battle_constants.asm: REST_SLEEP_TURNS 2), the counter CheckTurn runs down.
M.REST_SLEEP_COUNT = 3

-- BattleCommand_BellyDrum's `ld a, MAX_STAT_LEVEL - BASE_STAT_LEVEL - 1`:
-- the AttackUp2s after the first.
M.BELLY_DRUM_CLIMB = 5

-- One move row copied whole (K8's `priority` and `ppUps` with it), the shape
-- MIMIC puts aside (`preMimic`) and Red's twin keeps.
local function copyMoveRow(m)
  return {
    id = m.id or "move", name = m.name,
    pp = max(0, int(m.pp, 0)), maxPp = m.maxPp,
    power = max(0, int(m.power, 0)), accuracy = max(0, int(m.accuracy, 255)),
    type = max(0, int(m.type, 0)), effect = max(0, int(m.effect, 0)),
    chance = max(0, int(m.chance, 0)), highCrit = m.highCrit == true,
    priority = m.priority, ppUps = m.ppUps,
  }
end
M.copyMoveRow = copyMoveRow

-- A move's base PP (its data/moves/moves.asm row), as SKETCH copies it
-- (`ld hl, Moves + MOVE_PP`): the sheet carries the max PP its PP Ups raised
-- (K8 `ppUps`), each worth floor(base / 5) held at 7 (ComputeMaxPP's `cp $8`),
-- so the base is the smallest that reaches that max; a row with no PP Ups is
-- its own max.
function M.basePp(move)
  local top = max(0, int(move.maxPp, int(move.pp, 0)))
  local ups = int(move.ppUps, 0)
  if ups <= 0 then return top end
  for base = 1, top do
    if base + ups * min(7, floor(base / 5)) == top then return base end
  end
  return top
end

-- Confusion is a volatile, not a major status: it does not occupy `mon.status`
-- and does not persist on the party sheet. The chip is a `confused` flag on
-- the status event (1 inflicted, 0 snapped out), independent of PSN/SLP/…
local function confuse(out, fighter, mon, rng, failIfAlready)
  if mon.confusion and mon.confusion > 0 then
    if failIfAlready then out.nothing = true end
    return
  end
  local turns = (rng and rng:byte() or 0) % 4 + 2
  mon.confusion = turns
  local text = mon.species .. " became confused"
  out.messages[#out.messages + 1] = text
  local fields = fighterFields(fighter)
  fields.confused = 1
  fields.text = text
  out.events[#out.events + 1] = { kind = "status", fields = fields }
end

-- The stored battle stats as they stand now (`storedStat` for each).
function M.currentStats(mon, badges)
  local out = {}
  for _, key in ipairs(M.STAT_KEYS) do out[key] = M.storedStat(mon, key, badges) end
  return out
end

-- A status written the way the cart writes one outside a stat rebuild: the
-- status byte changes and wBattleMonStats is left as it stands -- but for the
-- penalty a landing burn or paralysis puts on it (BattleCommand_BurnTarget /
-- _ParalyzeTarget / _Paralyze call ApplyBrnEffectOnAttack /
-- ApplyPrzEffectOnSpeed on the stat they find).  Every status change but a
-- cure item's (UseHeldStatusHealingItem farcalls CalcPlayerStats) is this
-- one: an infliction, a wake-up or a thaw in CheckTurn, HandleDefrost,
-- Defrost, the obedience nap.  `badges` is the monster's seat's.
function M.setStatus(mon, badges, status)
  local values = M.currentStats(mon, badges)
  mon.status = status
  if status == "burn" then values.atk = Status.burnAttack(values.atk) end
  if status == "paralysis" then values.spe = Status.paralysisSpeed(values.spe) end
  M.snapStats(mon, badges, values)
end

-- `setStatus` on a monster whose seat is `fighter` (its badges).
local function setStatusOn(mon, fighter, status)
  M.setStatus(mon, fighter and fighter.badges or nil, status)
end
M.setStatusOn = setStatusOn

-- A stage written the way RaiseStat's `.stats_already_max` writes it: the
-- level moves and no CalcPlayerStats follows, so the battle stats stay.
local function setStageKeep(mon, badges, stat, stage)
  local values = M.currentStats(mon, badges)
  mon.stages[stat] = stage
  M.snapStats(mon, badges, values)
end

-- What a sentence calls a held item (Items.label's rule; Items is not
-- required here for one line).
local function itemLabel(mon)
  return mon.itemName or mon.heldItem or "ITEM"
end

-- The `stat` event for a stage that moved: `amount` as it always rode (the
-- wire's unsigned field drops a negative one) and the signed `stage` beside
-- it (contract K10).
local function statEvent(out, fighter, stage, text)
  local fields = fighterFields(fighter)
  fields.amount = stage
  fields.stage = stage
  fields.text = text
  out.events[#out.events + 1] = { kind = "stat", fields = fields }
end
M.statEvent = statEvent

-- One stage written and announced: the battle stats are rebuilt (the
-- snapshot drops -- CalcPlayerStats follows every StatUp / TryLowerStat that
-- moved a level) and the line is the cart's StatUpMessage / StatDownMessage.
local function applyStatChange(out, fighter, mon, stat, delta)
  local label = STAT_LABELS[stat] or stat
  local before = M.clampStage(mon.stages[stat])
  local after = M.clampStage(before + delta)
  mon.stages[stat] = after
  M.dropSnap(mon)
  local verb = delta > 0 and "rose" or "fell"
  local text = mon.species .. "'s " .. label .. " " .. verb
  out.messages[#out.messages + 1] = text
  statEvent(out, fighter, after, text)
  return true
end

-- Every stage back to 0.  Haze, and the levels a monster leaves behind:
-- pokecrystal keeps one set of stat levels per side (wPlayerStatLevels) and
-- refills it on every send-out (ResetPlayerStatLevels, engine/battle/
-- core.asm:3944), so a monster that switches in or faints brings no stage
-- with it -- the referee keeps them per monster and clears them at those two
-- points instead (Turn `_resolveSwitches` / `_faint`).  Haze rebuilds the
-- battle stats (BattleCommand_ResetStats calls CalcPlayerStats and
-- CalcEnemyStats), so the snapshot goes with them.
local function resetStages(mon)
  mon.stages.atk = 0
  mon.stages.def = 0
  mon.stages.spe = 0
  mon.stages.spa = 0
  mon.stages.spd = 0
  mon.stages.acc = 0
  mon.stages.eva = 0
  M.dropSnap(mon)
end
M.resetStages = resetStages

-- BattleCommand_StatDown's `.ComputerMiss` byte (pokecrystal engine/battle/
-- effect_commands.asm:4320-4440; pokegold the same but for Crystal's Battle
-- Tower exemption, which no fight here is): `cp 25 percent + 1`, and RGBDS
-- `percent` is `* $ff / 100` in integer arithmetic, so 63 + 1 -- the computer
-- misses on a byte under 64.
M.COMPUTER_DROP_MISS = 64

-- The stat a primary stat-down move lowers (ATTACK_DOWN ... EVASION_DOWN and
-- the _2 rows), or nil.  The *DownHit side effects are SIDE_STAT_DOWN below.
function M.primaryStatDown(effectId)
  local statFx = STAT_EFFECTS[int(effectId, -1)]
  if statFx and statFx.delta < 0 and not statFx.selfTarget then return statFx.stat end
  return nil
end

-- BattleCommand_StatDown up to `.DidntMiss`, the one routine a primary
-- stat-down move (`attackdown` after `checkhit`) and a *DownHit side effect
-- (`attackdown` after `buildopponentrage`) both run, in its order:
--
--   1. CheckMist: the target's SUBSTATUS_MIST -> `.Mist`;
--   2. the stage already at -6 (`dec b / jp z, .CantLower`) -> `.CantLower`
--      -- a -2 drop from -5 goes on, its `dec b / jr nz` / `inc b` stopping
--      it at -6;
--   3. `.ComputerMiss`: on the enemy's turn outside a link battle
--      (`computerMover`, Turn's isComputerSeat) a BattleRandom under
--      M.COMPUTER_DROP_MISS -> `.Failed` -- skipped while the target is still
--      locked on (`lockedOn`: "Lock-On still always works", the player's
--      SUBSTATUS_LOCK_ON) and for the attacking moves that lower accuracy
--      (`cp EFFECT_ACCURACY_DOWN_HIT / jr z, .DidntMiss`: MUD-SLAP and
--      OCTAZOOKA, `effectId` M.ACCURACY_DOWN_HIT here).  CheckHit's `.LockOn`
--      clears that bit whenever it is reached, so the exemption only holds
--      for a move whose check stopped before it (Turn `_checkHit`).
--
-- Nothing before the byte asks whether the move hit, whether a substitute
-- stands or whether the side effect's chance landed: `checkhit` only set
-- wAttackMissed, a substitute is CheckSubstituteOpp at `.DidntMiss`, and
-- wEffectFailed is read after that -- so the computer draws it for a missed
-- GROWL, for a hit into a substitute and for an AURORA BEAM whose chance
-- byte failed alike.  Returns "mist", "floor" or "missed" for the step that
-- stopped the drop, or nil when it goes on to `.DidntMiss`.
function M.statDownGate(rng, targetMon, stat, computerMover, effectId, lockedOn)
  if targetMon.mist then return "mist" end
  if M.clampStage(targetMon.stages[stat]) <= M.STAGE_MIN then return "floor" end
  if computerMover and not lockedOn and int(effectId, 0) ~= M.ACCURACY_DOWN_HIT
     and rng and rng:byte() < M.COMPUTER_DROP_MISS then
    return "missed"
  end
  return nil
end

-- TryLowerStat's floor (effect_commands.asm:4520-4545): the battle stat is
-- already 1 -- "The lowest possible stat is 1" -- so the level goes back and
-- the drop fails as `.CouldntLower` (wFailedMessage 3).  Accuracy and evasion
-- have no stat to ask.
local function statAtFloor(mon, stat, badges)
  if stat == "acc" or stat == "eva" then return false end
  return M.storedStat(mon, stat, badges) <= 1
end

-- StatDownFailText / StatUpFailText's lines (effect_commands.asm:4569-4600,
-- data/text/battle.asm): ProtectedByMistText, WontDropAnymoreText,
-- WontRiseAnymoreText.  wFailedMessage 1 is TryPrintButItFailed, the "But it
-- failed" every other site in this referee says.
function M.mistLine(mon)
  return mon.species .. "'s protected by MIST."
end
function M.wontDropLine(mon, stat)
  return mon.species .. "'s " .. (STAT_LABELS[stat] or stat) .. " won't drop anymore!"
end
function M.wontRiseLine(mon, stat)
  return mon.species .. "'s " .. (STAT_LABELS[stat] or stat) .. " won't rise anymore!"
end

-- The line a primary stat-down move ends on when its `checkhit` missed
-- (wAttackMissed): BattleCommand_StatDown still runs -- the scripts have no
-- `failuretext` -- and StatDownFailText says what stopped it: the target's
-- Mist, the stage at -6, and otherwise `.Failed` ("But it failed").  The
-- computer's `.ComputerMiss` byte, between the -6 test and `.DidntMiss`, is
-- Turn `_statDownAfterMiss`'s; its verdict is "But it failed" either way.
function M.statDownMissLine(targetMon, stat)
  if targetMon.mist then return M.mistLine(targetMon) end
  if M.clampStage(targetMon.stages[stat]) <= M.STAGE_MIN then
    return M.wontDropLine(targetMon, stat)
  end
  return "But it failed"
end

-- No generic substitute gate (wave 4): every Gold status command asks the
-- substitute itself, where its own code puts the check -- SleepTarget,
-- Poison, Paralyze, Confuse, LeechSeed, LockOn, Nightmare, PainSplit, Curse's
-- GHOST arm, Sketch -- and DISABLE, MIMIC, ATTRACT, ENCORE, FORESIGHT,
-- SPITE, PSYCH UP, MEAN LOOK and TRANSFORM never ask it at all
-- (move_effects/*.asm).  A stat-down move meets it inside
-- BattleCommand_StatDown (`lowerPrimary`).

-- The cart's failure lines a status command ends on: FailMove /
-- PrintButItFailed ("But it failed!" -- this referee's "But it failed", the
-- line every other site says), PrintDidntAffect / PrintDidntAffect2
-- (DidntAffect1Text / DidntAffect2Text, both "It didn't affect <TARGET>!").
local function butItFailed(out)
  out.messages[#out.messages + 1] = "But it failed"
  return out
end
local function didntAffect(out, targetMon)
  out.messages[#out.messages + 1] = M.didntAffectLine(targetMon)
  return out
end
-- FailMove / FailMimic (effect_commands.asm:6209-6216): "But it failed!" --
-- or, while the target's SUBSTATUS_PROTECT stands (FailText_CheckOpponentProtect),
-- ItFailedText's "It failed!".
function M.failMoveLine(targetMon)
  if targetMon and targetMon.protect then return "It failed!" end
  return "But it failed"
end
local function failMove(out, targetMon)
  out.messages[#out.messages + 1] = M.failMoveLine(targetMon)
  return out
end

-- `.CheckAIRandomFail` (BattleCommand_SleepTarget, effect_commands.asm:3640-
-- 3666) and the same lines inlined in BattleCommand_Poison (:3735-3758) and
-- BattleCommand_Paralyze (:5860-5880): on the enemy's turn outside a link
-- battle (`ctx.computerMover`, Turn's isComputerSeat) and while the player is
-- not locked on (wPlayerSubStatus5's SUBSTATUS_LOCK_ON -- the target's, which
-- CheckHit's `.LockOn` clears whenever it is reached, so it still stands
-- only where the check stopped first), one BattleRandom: `cp 25 percent + 1`,
-- under 64 the computer's move fails ("It didn't affect").  Draws nothing on
-- any other seat.
local function aiRandomFail(ctx, targetMon)
  if not ctx.computerMover or targetMon.lockOn then return false end
  local rng = ctx.rng
  return rng ~= nil and rng:byte() < M.COMPUTER_DROP_MISS
end

-- RaiseStat (effect_commands.asm:4142-4236) with none of its messages, the
-- routine BattleCommand_StatUp and every script built on it (BELLY DRUM's
-- AttackUp2s, CURSE's AttackUp / DefenseUp, SWAGGER's attackup2 on its
-- target, SKULL BASH's defenseup) run: a level already at +6 is
-- `.cant_raise_stat`; otherwise the level goes up (capped at +6) and, for a
-- stat that is not accuracy or evasion, a battle stat already at
-- MAX_STAT_VALUE is `.stats_already_max` -- the level comes back down ONE
-- (`dec [hl]`, so a _2 raise keeps one stage of its two) with no rebuild;
-- else CalcPlayerStats rebuilds (`dropSnap`).  The battle stat is the stored
-- one (`storedStat`, with the seat's badges).  Returns whether the level rose
-- with a rebuild, and the stage it stands at.
local function raiseStat(mon, badges, stat, delta)
  local before = M.clampStage(mon.stages[stat])
  if before >= M.STAGE_MAX then return false, before end
  local after = min(M.STAGE_MAX, before + delta)
  if stat ~= "acc" and stat ~= "eva"
     and M.storedStat(mon, stat, badges) >= M.MAX_STAT_VALUE then
    after = after - 1
    if after ~= before then setStageKeep(mon, badges, stat, after) end
    return false, after
  end
  mon.stages[stat] = after
  M.dropSnap(mon)
  return true, after
end
M.raiseStat = raiseStat

-- GetGender (engine/pokemon/mon_stats.asm:124-232), for CheckOppositeGender
-- (move_effects/attract.asm): the Attack DV and the Speed DV (each DV byte's
-- high nybble, `and $f0` / `swap`) as one byte, against the species'
-- BASE_GENDER -- 255 (GENDER_UNKNOWN) genderless, 0 (GENDER_F0) male, 254
-- (GENDER_F100) female, otherwise male when the ratio is below that byte.
-- CheckOppositeGender reads each monster's own species and DVs -- the
-- player's PARTY struct (BattlePartyAttr), the enemy's wEnemyBackupDVs under
-- Transform -- so a transformed monster keeps its own gender: `base` (which
-- Transform never rewrites; it sets `transformBase`) and `preTransform.dvs`.
-- The ratio is the sheet's `base.gender` (contract K15, proposed: the K7
-- base block's BASE_GENDER byte); a sheet that states none, or no DVs,
-- cannot be placed, and reads as genderless -- `.genderless_samegender`, so
-- ATTRACT fails rather than invent a gender.  Returns "M", "F" or nil.
function M.gender(mon)
  if type(mon) ~= "table" or type(mon.base) ~= "table" then return nil end
  local ratio = int(mon.base.gender, nil)
  if ratio == nil then return nil end
  local dvs = mon.dvs
  if mon.preTransform then dvs = mon.preTransform.dvs end
  if type(dvs) ~= "table" then return nil end
  if ratio == M.GENDER_UNKNOWN then return nil end
  if ratio == M.GENDER_F0 then return "M" end
  if ratio == M.GENDER_F100 then return "F" end
  local byte = (int(dvs.atk, 0) % 16) * 16 + int(dvs.spe, 0) % 16
  if ratio < byte then return "M" end
  return "F"
end
M.GENDER_F0 = 0
M.GENDER_F100 = 254
M.GENDER_UNKNOWN = 255

-- The HELD_PREVENT_* item's line, when the primary status command checks it
-- (SleepTarget, Poison, Paralyze, Confuse: "<TARGET>'s protected by <ITEM>!",
-- ProtectedByText).  No item on either cart carries one of these effects
-- (data/items/attributes.asm), but the rule is keyed on the effect token, so
-- a sheet whose item states one is protected.
local function protectedBy(out, targetMon)
  out.messages[#out.messages + 1] =
    targetMon.species .. "'s protected by " .. itemLabel(targetMon) .. "!"
  return out
end

-- RaiseStat (effect_commands.asm:4142-4236) for a primary stat-up move, then
-- its script's `statupmessage` / `statupfailtext`: a stage already at +6 is
-- `.cant_raise_stat` ("won't rise anymore!"); otherwise the level goes up
-- (two for a _2 move, capped at +6) and, for a stat that is not accuracy or
-- evasion, a battle stat already at MAX_STAT_VALUE is `.stats_already_max`:
-- the level comes back down ONE (`dec [hl]` -- so a _2 move keeps one stage
-- of its two, the cart's own arithmetic) with no rebuild after it, and the
-- move says "won't rise anymore!".  The battle stat is the stored one
-- (`storedStat`, with the seat's badges).  Returns whether the move raised
-- the stat (MinimizeDropSub's wFailedMessage 0).
local function raisePrimary(out, fighter, mon, stat, delta)
  local before = M.clampStage(mon.stages[stat])
  local raised, after = raiseStat(mon, fighter and fighter.badges or nil, stat, delta)
  if raised then
    local text = mon.species .. "'s " .. (STAT_LABELS[stat] or stat) .. " rose"
    out.messages[#out.messages + 1] = text
    statEvent(out, fighter, after, text)
    return true
  end
  local text = M.wontRiseLine(mon, stat)
  if after ~= before then statEvent(out, fighter, after, text) end
  out.messages[#out.messages + 1] = text
  return false
end

-- BattleCommand_StatDown and `statdownmessage` / `statdownfailtext` for a
-- primary stat-down move that hit (a miss is `statDownMissLine`): Mist
-- ("protected by MIST."), the stage at -6 ("won't drop anymore!"), the
-- computer's byte ("But it failed"), then `.DidntMiss` -- a substitute ("But
-- it failed"; CheckHiddenOpponent's vanished target never gets here, Turn
-- missed it first) -- then the level, and TryLowerStat's floor at a battle
-- stat of 1, which puts the level back ("won't drop anymore!").
local function lowerPrimary(out, ctx, fighter, mon, stat, delta)
  local stop = M.statDownGate(ctx.rng, mon, stat, ctx.computerMover == true,
    ctx.effectId, mon.lockOn == true)
  if stop == "mist" then
    out.messages[#out.messages + 1] = M.mistLine(mon)
    return out
  end
  if stop == "floor" then
    out.messages[#out.messages + 1] = M.wontDropLine(mon, stat)
    return out
  end
  if stop == "missed" or int(mon.substitute, 0) > 0 then
    out.messages[#out.messages + 1] = "But it failed"
    return out
  end
  if statAtFloor(mon, stat, fighter and fighter.badges or nil) then
    out.messages[#out.messages + 1] = M.wontDropLine(mon, stat)
    return out
  end
  applyStatChange(out, fighter, mon, stat, delta)
  return out
end

-- ctx: effectId, rng, userMon, targetMon, userFighter, targetFighter,
--      moveIndex (1-based), statusToWire, userScreens (the user's side's
--      screen counts and Safeguard; see LIGHT_SCREEN_EFFECT below),
--      computerMover (the move is the computer's: BattleCommand_StatDown's
--      extra miss), moveKey (the move's id, upper-cased: MinimizeDropSub's
--      `cp MINIMIZE`), moveImmune (the move's matchup against the target is
--      0: `stab`'s wTypeModifier, which Poison and Paralyze read),
--      poisonType / grassType (POISON's and GRASS's chart indices off the
--      ruleset's typeIds, nil when it names none), fieldMons (every monster
--      on the field, for Haze); from wave 4: missed (the script's `checkhit`
--      set wAttackMissed -- Turn passes it to the READS_MISS commands),
--      ghostType (GHOST's chart index, CURSE's `cp GHOST`), targetSafeguard
--      (the target's side has SAFEGUARD up: SWAGGER's SafeCheckSafeguard).
-- Returns { nothing, messages, events, heals, costs, directDamage } where
-- heals = { amount } for the user, and from wave 4 `selfDamage` (an amount
-- straight off the user's HP past its substitute: SubtractHPFromUser),
-- `trailing` (lines said after the heals and HP costs), `failureText` (the
-- script's `failuretext` ends the move on a miss: Turn says its miss line)
-- and `targetMovesChanged` (the target's move list moved: SPITE).
function M.applyPrimary(ctx)
  ctx = ctx or {}
  local out = { nothing = false, messages = {}, events = {}, heals = {}, costs = {},
                directDamage = {}, trailing = {} }
  local effectId = int(ctx.effectId, 0)
  local userMon = ctx.userMon
  local targetMon = ctx.targetMon
  local userFighter = ctx.userFighter
  local targetFighter = ctx.targetFighter
  local wire = ctx.statusToWire or {}
  local rng = ctx.rng
  local targetBadges = targetFighter and targetFighter.badges or nil

  if effectId == 85 then -- SPLASH_EFFECT
    out.nothing = true
    return out
  end

  -- BattleCommand_Heal (effect_commands.asm:6362-6437), RECOVER's,
  -- SOFTBOILED's, MILK DRINK's and REST's: a user whose HP equals its max
  -- (CompareBytes) fails -- "<USER>'s HP is full!".  REST (`cp REST`, by the
  -- move's id) then clears SUBSTATUS_TOXIC and writes REST_SLEEP_TURNS + 1
  -- over whatever status it had (asleep two turns, moving on the third:
  -- CheckTurn's `dec`) -- "went to sleep!" from none, "fell asleep and became
  -- healthy!" from one, nothing else asked (a sleeping user rests again) --
  -- and CalcPlayerStats rebuilds the battle stats; it restores the whole max
  -- HP, every other heal GetHalfMaxHP (at least 1), and "<USER> regained
  -- health!".
  if effectId == 56 then -- HEAL_EFFECT
    local maxHp = max(1, int(userMon.maxHp, 1))
    if userMon.hp >= maxHp then
      out.messages[#out.messages + 1] = userMon.species .. "'s HP is full!"
      return out
    end
    local amount = max(1, floor(maxHp / 2))
    if ctx.moveKey == "REST" then
      local had = userMon.status ~= nil
      userMon.status = "sleep"
      userMon.statusTurns = M.REST_SLEEP_COUNT
      M.dropSnap(userMon)
      local text = userMon.species
        .. (had and " fell asleep and became healthy!" or " went to sleep!")
      out.messages[#out.messages + 1] = text
      local fields = fighterFields(userFighter)
      fields.status = wire.sleep or "SLP"
      fields.text = text
      out.events[#out.events + 1] = { kind = "status", fields = fields }
      amount = maxHp
    end
    out.heals[#out.heals + 1] = { amount = amount }
    out.trailing[#out.trailing + 1] = userMon.species .. " regained health!"
    return out
  end

  -- BattleCommand_ResetStats (effect_commands.asm:6002-6031): both sides'
  -- stat levels back to the base, and both sides' battle stats rebuilt -- in a
  -- 2v2 every monster on the field, all four (`ctx.fieldMons`), not only the
  -- user and its target.  Nothing else is touched on Gold.
  if effectId == 25 then -- HAZE_EFFECT
    local field = type(ctx.fieldMons) == "table" and ctx.fieldMons or { userMon, targetMon }
    for _, mon in ipairs(field) do resetStages(mon) end
    out.messages[#out.messages + 1] = "All stat changes were eliminated"
    return out
  end

  -- DefenseCurl's script (data/moves/effects.asm): `defenseup` -- RaiseStat
  -- and its message as DEFENSE UP's -- then BattleCommand_Curl, which sets
  -- SUBSTATUS_CURLED whatever the raise did (ROLLOUT's extra doubling reads
  -- it; a send-out clears it, Turn `_clearSubstatus`).
  if effectId == M.DEFENSE_CURL then
    raisePrimary(out, userFighter, userMon, "def", 1)
    userMon.curled = true
    return out
  end

  local statFx = STAT_EFFECTS[effectId]
  if statFx then
    if statFx.selfTarget then
      local raised = raisePrimary(out, userFighter, userMon, statFx.stat, statFx.delta)
      -- MinimizeDropSub, the tail of a BattleCommand_StatUp that moved a stage:
      -- the move is MINIMIZE (`BATTLE_VARS_MOVE_ANIM`), so wPlayerMinimized /
      -- wEnemyMinimized goes up -- what STOMP's doubleminimizedamage reads.  A
      -- send-out clears it (Turn `_resolveSwitches` / `_faint`).
      if raised and ctx.moveKey == "MINIMIZE" then userMon.minimized = true end
      return out
    end
    return lowerPrimary(out, ctx, targetFighter, targetMon, statFx.stat, statFx.delta)
  end

  -- BattleCommand_SleepTarget (effect_commands.asm:3571-3667), in its order:
  -- the target's HELD_PREVENT_SLEEP ("protected by"), a target already
  -- asleep ("<TARGET>'s already asleep!"), wAttackMissed (PrintDidntAffect2),
  -- the computer's `.CheckAIRandomFail` byte (`aiRandomFail`), any other
  -- status and a substitute -- each "It didn't affect <TARGET>!".  (A
  -- Safeguard is the script's `checksafeguard`, Turn's.)
  if effectId == 32 then -- SLEEP_EFFECT
    if Items.prevents(targetMon, "sleep") then return protectedBy(out, targetMon) end
    if targetMon.status == "sleep" then
      out.messages[#out.messages + 1] = targetMon.species .. "'s already asleep!"
      return out
    end
    if ctx.missed or aiRandomFail(ctx, targetMon) or M.hasMajorStatus(targetMon)
       or int(targetMon.substitute, 0) > 0 then
      return didntAffect(out, targetMon)
    end
    -- `.random_loop`: BattleRandom & SLP_MASK, drawn again on 0 and on 7, plus
    -- 1 -- a counter of 2..7, which CheckTurn's `dec` runs down to the turn it
    -- wakes and moves on: 1..6 turns asleep (statusTurns is that counter).
    local turns = 0
    for _ = 1, M.REDRAW_LIMIT do
      local r = (rng and rng:byte() or 0) % 8
      if r ~= 0 and r ~= 7 then turns = r + 1; break end
    end
    if turns == 0 then turns = 2 end
    M.setStatus(targetMon, targetBadges, "sleep")
    targetMon.statusTurns = turns
    local token = wire.sleep or "SLP"
    local text = targetMon.species .. " fell asleep"
    out.messages[#out.messages + 1] = text
    local fields = fighterFields(targetFighter)
    fields.status = token
    fields.text = text
    out.events[#out.events + 1] = { kind = "status", fields = fields }
    return out
  end

  -- BattleCommand_Poison (effect_commands.asm:3701-3804), POISONPOWDER's and
  -- TOXIC's one command: a matchup of 0 (`stab` ran first in DoPoison: a
  -- Poison move against a Steel type) and a Poison-type target "doesn't
  -- affect" it; a poisoned target is "<TARGET>'s already poisoned!"; the
  -- target's HELD_PREVENT_POISON "protected by"; then any other status, the
  -- computer's `.dont_sample_failure` byte (`aiRandomFail`), a substitute and
  -- wAttackMissed, in that order, "It didn't affect <TARGET>!" -- so the
  -- computer draws its byte on a miss too; then `.check_toxic`: EFFECT_TOXIC
  -- sets SUBSTATUS_TOXIC and zeroes the toxic count -- badly poisoned, its
  -- residual 1/16 x the count (Turn `_residualFor`) -- and every other
  -- poison move is plain poison.
  if effectId == 66 or effectId == M.TOXIC then -- POISON_EFFECT / EFFECT_TOXIC
    if ctx.moveImmune or hasType(targetMon, ctx.poisonType) then
      out.messages[#out.messages + 1] = "It doesn't affect " .. targetMon.species
      return out
    end
    if targetMon.status == "poison" or targetMon.status == "toxic" then
      out.messages[#out.messages + 1] = targetMon.species .. "'s already poisoned!"
      return out
    end
    if Items.prevents(targetMon, "poison") then return protectedBy(out, targetMon) end
    if M.hasMajorStatus(targetMon) or aiRandomFail(ctx, targetMon)
       or int(targetMon.substitute, 0) > 0 or ctx.missed then
      return didntAffect(out, targetMon)
    end
    local toxic = effectId == M.TOXIC
    M.setStatus(targetMon, targetBadges, toxic and "toxic" or "poison")
    local text
    if toxic then
      targetMon.toxicCounter = 1
      text = targetMon.species .. "'s badly poisoned!"
    else
      text = targetMon.species .. " was poisoned"
    end
    out.messages[#out.messages + 1] = text
    local fields = fighterFields(targetFighter)
    fields.status = toxic and (wire.toxic or "TOX") or (wire.poison or "PSN")
    fields.text = text
    out.events[#out.events + 1] = { kind = "status", fields = fields }
    return out
  end

  -- BattleCommand_Paralyze (effect_commands.asm:5831-5905): a paralysed
  -- target ("<TARGET>'s already paralyzed!"), then a matchup of 0 ("doesn't
  -- affect" -- THUNDER WAVE against a Ground type), then
  -- HELD_PREVENT_PARALYZE ("protected by"), then the computer's
  -- `.dont_sample_failure` byte (`aiRandomFail`), any other status,
  -- wAttackMissed and a substitute, in that order -- PrintDidntAffect2.  The
  -- penalty lands on the stat as it stands (ApplyPrzEffectOnSpeed,
  -- `setStatus`).
  if effectId == 67 then -- PARALYZE_EFFECT
    if targetMon.status == "paralysis" then
      out.messages[#out.messages + 1] = targetMon.species .. "'s already paralyzed!"
      return out
    end
    if ctx.moveImmune then
      out.messages[#out.messages + 1] = "It doesn't affect " .. targetMon.species
      return out
    end
    if Items.prevents(targetMon, "paralysis") then return protectedBy(out, targetMon) end
    if aiRandomFail(ctx, targetMon) or M.hasMajorStatus(targetMon) or ctx.missed
       or int(targetMon.substitute, 0) > 0 then
      return didntAffect(out, targetMon)
    end
    M.setStatus(targetMon, targetBadges, "paralysis")
    local token = wire.paralysis or "PAR"
    local text = targetMon.species .. " is paralyzed"
    out.messages[#out.messages + 1] = text
    local fields = fighterFields(targetFighter)
    fields.status = token
    fields.text = text
    out.events[#out.events + 1] = { kind = "status", fields = fields }
    return out
  end

  -- BattleCommand_Confuse (effect_commands.asm:5750-5776): HELD_PREVENT_CONFUSE
  -- first ("protected by"), then a target already confused ("<TARGET>'s
  -- already confused!"), then a substitute or wAttackMissed (PrintDidntAffect2
  -- by way of `_CheckSnore_Swagger_ConfuseHit`), then FinishConfusingTarget's
  -- 2-5 turns.  No computer byte: Confuse has none.
  if effectId == 49 then -- CONFUSION_EFFECT
    if Items.prevents(targetMon, "confusion") then return protectedBy(out, targetMon) end
    if (targetMon.confusion or 0) > 0 then
      out.messages[#out.messages + 1] = targetMon.species .. "'s already confused!"
      return out
    end
    if int(targetMon.substitute, 0) > 0 or ctx.missed then
      return didntAffect(out, targetMon)
    end
    confuse(out, targetFighter, targetMon, rng, true)
    return out
  end

  -- BattleCommand_LeechSeed (move_effects/leech_seed.asm): wAttackMissed and
  -- a substitute ("<TARGET> evaded the attack!", EvadedText -- the one
  -- caller of that line), then a Grass-type target ("It doesn't affect",
  -- PrintDoesntAffect -- GRASS against either of its types), then one already
  -- seeded (EvadedText again).
  if effectId == 84 then -- LEECH_SEED_EFFECT
    local evaded = targetMon.species .. " evaded the attack!"
    if ctx.missed or int(targetMon.substitute, 0) > 0 then
      out.messages[#out.messages + 1] = evaded
      return out
    end
    if hasType(targetMon, ctx.grassType) then
      out.messages[#out.messages + 1] = "It doesn't affect " .. targetMon.species
      return out
    end
    if targetMon.leechSeed then
      out.messages[#out.messages + 1] = evaded
      return out
    end
    targetMon.leechSeed = { fromSlot = userFighter.slot }
    local text = targetMon.species .. " was seeded"
    out.messages[#out.messages + 1] = text
    local fields = fighterFields(targetFighter)
    fields.text = text
    out.events[#out.events + 1] = { kind = "status", fields = fields }
    return out
  end

  -- BattleCommand_Disable (move_effects/disable.asm, pokegold the same),
  -- after `checkhit`: wAttackMissed, a Disable count already running, no
  -- LAST_COUNTER_MOVE of the target's or STRUGGLE, and that move's slot (the
  -- first holding it) with a PP byte of 0 -- `ld a, [hl] / and a`, the raw
  -- byte, so a slot with PP Ups (K8 `ppUps`) is never empty here -- each
  -- FailMove's "But it failed!".  No substitute is asked.  The count is
  -- `.loop2`'s BattleRandom & 7, redrawn on 0, plus 1: 2..8, run down in
  -- CheckTurn (Turn `_runGates`) -- "<TARGET>'s <MOVE> was DISABLED!".
  if effectId == 86 then -- DISABLE_EFFECT
    local last = targetMon.lastCounterMove
    local running = targetMon.disable and int(targetMon.disable.turns, 0) > 0
    if ctx.missed or running or not last or M.moveKey(last) == "STRUGGLE" then
      return failMove(out, targetMon)
    end
    local index = nil
    for i = 1, #targetMon.moves do
      if M.moveKey(targetMon.moves[i]) == M.moveKey(last) then index = i; break end
    end
    local slotMove = index and targetMon.moves[index]
    if not slotMove or (int(slotMove.pp, 0) <= 0 and int(slotMove.ppUps, 0) <= 0) then
      return failMove(out, targetMon)
    end
    local count = 0
    for _ = 1, M.REDRAW_LIMIT do
      local r = (rng and rng:byte() or 0) % 8
      if r ~= 0 then count = r + 1; break end
    end
    if count == 0 then count = 2 end
    targetMon.disable = { moveIndex = index, turns = count }
    out.messages[#out.messages + 1] =
      targetMon.species .. "'s " .. moveLabel(slotMove) .. " was DISABLED!"
    return out
  end

  if effectId == 79 then -- SUBSTITUTE_EFFECT
    local cost = floor(max(1, int(userMon.maxHp, 1)) / 4)
    if userMon.substitute and userMon.substitute > 0 then
      out.nothing = true
      return out
    end
    if userMon.hp <= cost then
      out.nothing = true
      return out
    end
    userMon.hp = userMon.hp - cost
    userMon.substitute = cost
    out.directDamage = { { amount = cost } }
    out.messages[#out.messages + 1] =
      userMon.species .. " created a substitute"
    return out
  end

  -- BattleCommand_Screen (pokecrystal engine/battle/effect_commands.asm:
  -- 6147-6188): a screen belongs to the user's SIDE (wPlayerScreens), lasts
  -- SCREEN_TURNS, and a second cast while it is up fails ("But it failed!")
  -- rather than refreshing the count.  `ctx.userScreens` is the side's
  -- { lightScreen, reflect, safeguard } turn counts (Turn's
  -- `self.screens[side]`), which the between-turn tick counts down; nothing
  -- else ever clears them.
  if effectId == 64 or effectId == 65 then -- LIGHT_SCREEN_EFFECT / REFLECT_EFFECT
    local key = effectId == 64 and "lightScreen" or "reflect"
    local screens = ctx.userScreens
    if type(screens) ~= "table" or int(screens[key], 0) > 0 then
      out.messages[#out.messages + 1] = "But it failed"
      return out
    end
    screens[key] = M.SCREEN_TURNS
    out.messages[#out.messages + 1] = userMon.species
      .. (effectId == 64 and " created a light screen" or " created a reflect")
    return out
  end

  -- BattleCommand_Safeguard (move_effects/safeguard.asm): SCREENS_SAFEGUARD on
  -- the user's SIDE for five between-turn ticks (Turn `_tickSafeguard`,
  -- HandleSafeguard), "But it failed" while it is already up.  What it
  -- blocks is each status command's SafeCheckSafeguard / `checksafeguard`
  -- (`applySide` below, Turn `_safeguarded`).
  if effectId == M.SAFEGUARD then
    local screens = ctx.userScreens
    if type(screens) ~= "table" or int(screens.safeguard, 0) > 0 then
      out.messages[#out.messages + 1] = "But it failed"
      return out
    end
    screens.safeguard = M.SAFEGUARD_TURNS
    out.messages[#out.messages + 1] = userMon.species .. "'s covered by a veil!"
    return out
  end

  -- BattleCommand_LockOn (move_effects/lock_on.asm), LOCK-ON's and MIND
  -- READER's, after the script's `checkhit`: a substitute, then
  -- wAttackMissed, fail it ("It didn't affect", PrintDidntAffect); otherwise SUBSTATUS_LOCK_ON goes on the TARGET, which the next
  -- CheckHit against it reads and clears (Turn `_checkHit`), and the user
  -- "took aim!".
  if effectId == M.LOCK_ON then
    if int(targetMon.substitute, 0) > 0 or ctx.missed then
      return didntAffect(out, targetMon)
    end
    targetMon.lockOn = true
    out.messages[#out.messages + 1] = userMon.species .. " took aim!"
    return out
  end

  if effectId == 46 then -- MIST_EFFECT
    userMon.mist = true
    out.messages[#out.messages + 1] =
      userMon.species .. " is shrouded in mist"
    return out
  end

  if effectId == 47 then -- FOCUS_ENERGY_EFFECT
    userMon.focusEnergy = true
    out.messages[#out.messages + 1] =
      userMon.species .. " is getting pumped"
    return out
  end

  if effectId == 24 then -- CONVERSION_EFFECT
    local foeType = targetMon.types[1] or 0
    userMon.types = { foeType }
    out.messages[#out.messages + 1] =
      userMon.species .. " converted type"
    return out
  end

  -- BattleCommand_Mimic (move_effects/mimic.asm, pokegold the same):
  -- ClearLastMove first (`out.clearLastMove`), then wAttackMissed, a target in
  -- the sky / underground (CheckHiddenOpponent), no LAST_COUNTER_MOVE of the
  -- target's or STRUGGLE, and a move the user already knows -- each
  -- FailMimic's "But it failed!".  No substitute is asked.  The move goes into
  -- the slot that holds MIMIC (`.find_mimic`, scanning back from the last
  -- slot -- not the chosen one: SLEEP TALK calls it from its own) with 5 PP (`ld [hl], 5`).  The party keeps MIMIC: an untransformed
  -- user puts the slot's row aside (`preMimic`, keyed by the 1-based slot,
  -- the first Mimic only -- Red's shape), which keeps its own PP -- the
  -- party's MIMIC PP is frozen meanwhile (DoTurn's CheckMimicUsed) -- and
  -- comes back at a switch-out or a faint (Turn `_clearSubstatus`);
  -- HandleMysteryberry scans it (`_heldMysteryberry`).
  if effectId == 82 then -- MIMIC_EFFECT
    userMon.lastCounterMove = nil
    userMon.lastMove = nil
    out.clearLastMove = true
    local last = targetMon.lastCounterMove
    if ctx.missed or targetMon.invulnerable or not last
       or M.moveKey(last) == "STRUGGLE" then
      return failMove(out, targetMon)
    end
    local key = M.moveKey(last)
    local slot = nil
    for i = 1, #userMon.moves do
      if M.moveKey(userMon.moves[i]) == key then return failMove(out, targetMon) end
    end
    -- `cp MIMIC` by id; a modded move with Mimic's own command answers too
    -- (the cart's scan would run off the list looking for it).
    for i = #userMon.moves, 1, -1 do
      local m = userMon.moves[i]
      if M.moveKey(m) == "MIMIC" or int(m.effect, 0) == 82 then slot = i; break end
    end
    if not slot then return failMove(out, targetMon) end
    if not userMon.transformed then
      userMon.preMimic = userMon.preMimic or {}
      if not userMon.preMimic[slot] then
        userMon.preMimic[slot] = copyMoveRow(userMon.moves[slot])
      end
    end
    local copy = copyMoveRow(last)
    copy.pp, copy.maxPp, copy.ppUps = M.MIMIC_PP, M.MIMIC_PP, nil
    userMon.moves[slot] = copy
    out.messages[#out.messages + 1] =
      userMon.species .. " learned " .. moveLabel(last) .. "!"
    out.movesChanged = true
    return out
  end

  -- BattleCommand_Transform (move_effects/transform.asm, pokegold the same):
  -- ClearLastMove first (`out.clearLastMove`: the user's last move and last
  -- counter move are forgotten, so a foe's MIRROR MOVE copies nothing of
  -- it), then "But it failed" against a target already transformed or one in
  -- the sky / underground (CheckHiddenOpponent) -- no substitute is asked.
  -- Then SUBSTATUS_TRANSFORMED and ResetActorDisable, and the copy: the
  -- species (wBattleMonSpecies, `transformSpecies` -- what Lucky Punch /
  -- Stick read), the four moves with 5 PP each (1 for SKETCH: the
  -- `.pp_loop`), the DVs, the unmodified stats (wPlayerStats <- wEnemyStats),
  -- the battle stats as the target holds them (wBattleMonStats <-
  -- wEnemyMonStats: its badge and status in them, `snapStats`), the types
  -- and the stat levels.  The party is never touched: what the monster was
  -- is kept in `preTransform` (stats, types, moves with their PP, DVs) for
  -- Turn's `_undoTransform` -- a switch-out or a faint gives it back -- and
  -- for HandleMysteryberry, which scans the party's moves.
  if effectId == 57 then -- TRANSFORM_EFFECT
    userMon.lastCounterMove = nil
    userMon.lastMove = nil
    out.clearLastMove = true
    if targetMon.transformed or targetMon.invulnerable then
      out.messages[#out.messages + 1] = "But it failed"
      return out
    end
    if not userMon.preTransform then
      local partyMoves = {}
      for i = 1, #userMon.moves do partyMoves[i] = userMon.moves[i] end
      userMon.preTransform = {
        stats = userMon.stats, types = userMon.types,
        moves = partyMoves, dvs = userMon.dvs,
      }
    end
    local battleStats = M.currentStats(targetMon, targetBadges)
    userMon.stats = {
      atk = max(1, int(targetMon.stats.atk, 1)),
      def = max(1, int(targetMon.stats.def, 1)),
      spe = max(1, int(targetMon.stats.spe, 1)),
      spa = max(1, int(targetMon.stats.spa, 1)),
      spd = max(1, int(targetMon.stats.spd, 1)),
    }
    userMon.types = {}
    for i = 1, #targetMon.types do userMon.types[i] = targetMon.types[i] end
    if #userMon.types == 0 then userMon.types[1] = 0 end
    userMon.stages.atk = M.clampStage(targetMon.stages.atk)
    userMon.stages.def = M.clampStage(targetMon.stages.def)
    userMon.stages.spe = M.clampStage(targetMon.stages.spe)
    userMon.stages.spa = M.clampStage(targetMon.stages.spa)
    userMon.stages.spd = M.clampStage(targetMon.stages.spd)
    userMon.stages.acc = M.clampStage(targetMon.stages.acc)
    userMon.stages.eva = M.clampStage(targetMon.stages.eva)
    if type(targetMon.dvs) == "table" then
      local dvs = {}
      for key, value in pairs(targetMon.dvs) do dvs[key] = value end
      userMon.dvs = dvs
    else
      userMon.dvs = nil
    end
    local copied = {}
    for i = 1, #targetMon.moves do
      local m = targetMon.moves[i]
      local pp = (M.moveKey(m) == "SKETCH") and 1 or M.TRANSFORM_PP
      copied[#copied + 1] = {
        id = m.id or "move",
        name = m.name,
        pp = pp,
        maxPp = pp,
        power = max(0, int(m.power, 0)),
        accuracy = max(0, int(m.accuracy, 255)),
        type = max(0, int(m.type, 0)),
        effect = max(0, int(m.effect, 0)),
        chance = max(0, int(m.chance, 0)),
        highCrit = m.highCrit == true,
        priority = m.priority,
      }
    end
    userMon.moves = copied
    userMon.transformed = true
    userMon.disable = nil
    -- BattleCommand_Transform copies the target's species into the battle
    -- struct (wBattleMonSpecies), which BattleCommand_Critical's Lucky Punch /
    -- Stick check reads; the party species -- `speciesId`, untouched -- is what
    -- Light Ball, Thick Club and Metal Powder read (Items.lua).
    userMon.transformSpecies = targetMon.speciesId
    -- ...and the copied species' base stats (K7), which BEAT UP reads off
    -- wEnemyMonSpecies' base data for a transformed target's Defense.
    userMon.transformBase = targetMon.transformBase or targetMon.base
    M.snapStats(userMon, userFighter and userFighter.badges or nil, battleStats)
    out.messages[#out.messages + 1] =
      userMon.species .. " transformed into " .. targetMon.species
    out.movesChanged = true
    return out
  end

  -- BattleCommand_Attract (move_effects/attract.asm), after `checkhit`:
  -- wAttackMissed, CheckOppositeGender (`M.gender` for both: a genderless or
  -- unknown one and the same gender fail), CheckHiddenOpponent and a target
  -- already in love -- each FailMove's "But it failed!".  No substitute is
  -- asked.  Otherwise SUBSTATUS_IN_LOVE on the target, whose love is the
  -- user's seat (`inLove.fromSlot`: Turn's CheckTurn gate and
  -- BreakAttraction read it) -- "<TARGET> fell in love!".
  if effectId == M.ATTRACT then
    local mine, theirs = M.gender(userMon), M.gender(targetMon)
    if ctx.missed or not mine or not theirs or mine == theirs
       or targetMon.invulnerable or targetMon.inLove then
      return failMove(out, targetMon)
    end
    targetMon.inLove = { fromSlot = userFighter and userFighter.slot }
    out.messages[#out.messages + 1] = targetMon.species .. " fell in love!"
    return out
  end

  -- BattleCommand_BellyDrum (move_effects/belly_drum.asm), the cart's bug
  -- kept (docs/bugs_and_glitches.md, "Belly Drum sharply boosts Attack even
  -- with under 50% HP"): AttackUp2 FIRST -- `raiseStat`, so a level at +6 or
  -- an Attack of 999 fails the move ("But it failed!", its wAttackMissed) --
  -- then CheckUserHasEnoughHP against GetHalfMaxHP (at least 1): a user with
  -- no more than that fails too, KEEPING the two stages; otherwise the half
  -- comes off its HP (SubtractHPFromUser, past its own substitute), AttackUp2
  -- runs five times more (MAX_STAT_LEVEL - BASE_STAT_LEVEL - 1), each a
  -- RaiseStat with its own 999 test, the first that fails ending the climb,
  -- and "<USER> cut its HP and maximized ATTACK!".  The script has no
  -- `statupmessage`: the `stat` event carries the stage the climb reached.
  if effectId == M.BELLY_DRUM then
    local badges = userFighter and userFighter.badges or nil
    local before = M.clampStage(userMon.stages.atk)
    local raised, after = raiseStat(userMon, badges, "atk", 2)
    local half = max(1, floor(max(1, int(userMon.maxHp, 1)) / 2))
    if not raised or userMon.hp <= half then
      if after ~= before then statEvent(out, userFighter, after, nil) end
      return butItFailed(out)
    end
    out.selfDamage = half
    for _ = 1, M.BELLY_DRUM_CLIMB do
      local ok, now = raiseStat(userMon, badges, "atk", 2)
      after = now
      if not ok then break end
    end
    local text = userMon.species .. " cut its HP and maximized ATTACK!"
    statEvent(out, userFighter, after, text)
    out.trailing[#out.trailing + 1] = text
    return out
  end

  -- BattleCommand_Curse (move_effects/curse.asm).  A user with a GHOST battle
  -- type (`cp GHOST` on wBattleMonType1 / 2 -- TRANSFORM's and CONVERSION's
  -- types count): a target in the sky / underground (CheckHiddenOpponent),
  -- behind a substitute or already cursed fails ("But it failed!"); else
  -- SUBSTATUS_CURSE on the target (a quarter of its max HP each turn, Turn
  -- `_residualFor`), GetHalfMaxHP (at least 1) off the user's own HP
  -- (SubtractHPFromUser -- it can faint), "<USER> cut its own HP and put a
  -- CURSE on <TARGET>!".  Any other user: Attack and Defense both at +6 is
  -- `.cantraise` -- "<USER>'s ABILITY won't rise anymore!" (GetStatName's
  -- ABILITY row, `ld b, ABILITY + 1`) -- else LowerStat SPEED on itself (no
  -- Mist: its own; a level at -6 or a battle Speed of 1 leaves it silently),
  -- whose TryLowerStat rebuilds the OPPONENT's battle stats (it was written
  -- for StatDown: SwitchTurn / CalcEnemyStats -- the cart's own quirk), then
  -- AttackUp and DefenseUp (`raiseStat`, each silent when it fails: the
  -- script has no statupfailtext), each line as it lands.
  if effectId == M.CURSE then
    if hasType(userMon, ctx.ghostType) then
      if targetMon.invulnerable or int(targetMon.substitute, 0) > 0 or targetMon.cursed then
        return butItFailed(out)
      end
      targetMon.cursed = true
      out.selfDamage = max(1, floor(max(1, int(userMon.maxHp, 1)) / 2))
      out.trailing[#out.trailing + 1] = userMon.species
        .. " cut its own HP and put a CURSE on " .. targetMon.species .. "!"
      return out
    end
    if M.clampStage(userMon.stages.atk) >= M.STAGE_MAX
       and M.clampStage(userMon.stages.def) >= M.STAGE_MAX then
      out.messages[#out.messages + 1] = userMon.species .. "'s ABILITY won't rise anymore!"
      return out
    end
    local badges = userFighter and userFighter.badges or nil
    local speed = M.clampStage(userMon.stages.spe)
    if speed > M.STAGE_MIN and M.storedStat(userMon, "spe", badges) > 1 then
      userMon.stages.spe = speed - 1
      M.dropSnap(targetMon)
      M.dropSnap(userMon)
      local text = userMon.species .. "'s SPEED fell"
      out.messages[#out.messages + 1] = text
      statEvent(out, userFighter, speed - 1, text)
    end
    for _, stat in ipairs({ "atk", "def" }) do
      local ok, now = raiseStat(userMon, badges, stat, 1)
      if ok then
        local text = userMon.species .. "'s " .. STAT_LABELS[stat] .. " rose"
        out.messages[#out.messages + 1] = text
        statEvent(out, userFighter, now, text)
      end
    end
    return out
  end

  -- BattleCommand_DestinyBond (move_effects/destiny_bond.asm): no check at
  -- all -- SUBSTATUS_DESTINY_BOND on the user, "<USER>'s trying to take its
  -- opponent with it!".  `checkfaint` reads it on the hit that knocks the
  -- user out (Turn `_destinyBond`); the user's own next turn and every foe's
  -- action end it (Turn `_resolveFights`).
  if effectId == M.DESTINY_BOND then
    userMon.destinyBond = true
    out.messages[#out.messages + 1] =
      userMon.species .. "'s trying to take its opponent with it!"
    return out
  end

  -- BattleCommand_Foresight (move_effects/foresight.asm), after `checkhit`:
  -- wAttackMissed, a target in the sky / underground and a target already
  -- identified fail (FailMove: "But it failed!"); else SUBSTATUS_IDENTIFIED on
  -- the target -- CheckHit's `.StatModifiers` (Accuracy `identified`) and the
  -- type chart's Foresight rows (Turn `_typePercents`) read it -- "<USER>
  -- identified <TARGET>!".
  if effectId == M.FORESIGHT then
    if ctx.missed or targetMon.invulnerable or targetMon.identified then
      return failMove(out, targetMon)
    end
    targetMon.identified = true
    out.messages[#out.messages + 1] =
      userMon.species .. " identified " .. targetMon.species .. "!"
    return out
  end

  -- BattleCommand_ArenaTrap (effect_commands.asm:6285-6306), MEAN LOOK's and
  -- SPIDER WEB's: no `checkhit`; a target in the sky / underground, and a
  -- user already holding its foe -- SUBSTATUS_CANT_RUN is the USER's bit
  -- ("the opponent can't run"), so a second one fails whoever it aims at --
  -- "But it failed!".  Otherwise the user holds the seat it aimed at
  -- (`meanLook.slot`, Turn `_heldBy`: no switch, no run, no TELEPORT for that
  -- seat) -- "<TARGET> can't escape now!".
  if effectId == M.MEAN_LOOK then
    if targetMon.invulnerable or userMon.meanLook then return butItFailed(out) end
    userMon.meanLook = { slot = targetFighter and targetFighter.slot }
    out.messages[#out.messages + 1] = targetMon.species .. " can't escape now!"
    return out
  end

  -- BattleCommand_Nightmare (move_effects/nightmare.asm): no `checkhit`; a
  -- target in the sky / underground, behind a substitute, not asleep or
  -- already having one fails ("But it failed!"); else SUBSTATUS_NIGHTMARE --
  -- a quarter of its max HP each turn while it lasts (Turn `_residualFor`),
  -- gone when it wakes or a cure lands -- "<TARGET> started to have a
  -- NIGHTMARE!".
  if effectId == M.NIGHTMARE then
    if targetMon.invulnerable or int(targetMon.substitute, 0) > 0
       or targetMon.status ~= "sleep" or targetMon.nightmare then
      return butItFailed(out)
    end
    targetMon.nightmare = true
    out.messages[#out.messages + 1] = targetMon.species .. " started to have a NIGHTMARE!"
    return out
  end

  -- BattleCommand_PsychUp (move_effects/psych_up.asm): no `checkhit`, no
  -- substitute; a target whose every stat level is the base (0) fails ("But
  -- it failed!"); else all seven levels copied onto the user and its battle
  -- stats rebuilt (CalcPlayerStats) -- "<USER> copied the stat changes of
  -- <TARGET>!".
  if effectId == M.PSYCH_UP then
    local any = false
    for _, key in ipairs(STAGE_KEYS) do
      if M.clampStage(targetMon.stages[key]) ~= 0 then any = true end
    end
    if not any then return butItFailed(out) end
    for _, key in ipairs(STAGE_KEYS) do
      userMon.stages[key] = M.clampStage(targetMon.stages[key])
    end
    M.dropSnap(userMon)
    out.messages[#out.messages + 1] = userMon.species
      .. " copied the stat changes of " .. targetMon.species .. "!"
    return out
  end

  -- BattleCommand_Spite (move_effects/spite.asm), after `checkhit`:
  -- wAttackMissed, no LAST_COUNTER_MOVE of the target's or STRUGGLE, and that
  -- move's slot (the first holding it) with no PP fail (PrintDidntAffect2);
  -- else BattleRandom & 3, plus 2 -- 2..5 PP, at most what is left -- off
  -- the slot (the battle copy; the party's too unless the target is
  -- transformed, which this referee's one list already is) -- "<TARGET>'s
  -- <MOVE> was reduced by <n>!".
  if effectId == M.SPITE then
    local last = targetMon.lastCounterMove
    if ctx.missed or not last or M.moveKey(last) == "STRUGGLE" then
      return didntAffect(out, targetMon)
    end
    local slotMove = nil
    for i = 1, #targetMon.moves do
      if M.moveKey(targetMon.moves[i]) == M.moveKey(last) then
        slotMove = targetMon.moves[i]
        break
      end
    end
    if not slotMove or int(slotMove.pp, 0) <= 0 then return didntAffect(out, targetMon) end
    local amount = (rng and rng:byte() or 0) % 4 + 2
    if slotMove.pp < amount then amount = slotMove.pp end
    slotMove.pp = slotMove.pp - amount
    out.targetMovesChanged = true
    out.messages[#out.messages + 1] = targetMon.species .. "'s " .. moveLabel(slotMove)
      .. " was reduced by " .. amount .. "!"
    return out
  end

  -- SWAGGER's script (data/moves/effects.asm): `checkhit`, then `attackup2`
  -- on the TARGET (`switchturn`: RaiseStat with the target as its user and
  -- its seat's badges in the 999 test).  RaiseStat on wAttackMissed fails,
  -- and its own `.cant_raise_stat` / `.stats_already_max` SET wAttackMissed
  -- (a level at +6; an Attack of 999, the level keeping one of the two
  -- stages), so the script's `failuretext` then ends the move on its miss
  -- line (`out.failureText`) -- and the target is not confused.  Otherwise
  -- "<TARGET>'s ATTACK rose", and `confusetarget`, silent on
  -- HELD_PREVENT_CONFUSE, on the target's side's SAFEGUARD
  -- (SafeCheckSafeguard), on a substitute and on a confusion already there;
  -- else FinishConfusingTarget's 2..5 turns ("became confused", the confusion
  -- berry -- Turn `_afterInfliction`).
  if effectId == M.SWAGGER then
    if ctx.missed then
      out.failureText = true
      return out
    end
    local before = M.clampStage(targetMon.stages.atk)
    local raised, after = raiseStat(targetMon, targetBadges, "atk", 2)
    if not raised then
      if after ~= before then statEvent(out, targetFighter, after, nil) end
      out.failureText = true
      return out
    end
    local text = targetMon.species .. "'s ATTACK rose"
    out.messages[#out.messages + 1] = text
    statEvent(out, targetFighter, after, text)
    if Items.prevents(targetMon, "confusion") or ctx.targetSafeguard
       or int(targetMon.substitute, 0) > 0 or int(targetMon.confusion, 0) > 0 then
      return out
    end
    confuse(out, targetFighter, targetMon, rng, false)
    return out
  end

  out.nothing = true
  return out
end

-- ------------------------------------------------------------------
-- Phase 2 side-chance handlers (post-damage, damaging hits only)
-- ------------------------------------------------------------------

-- Same 1/256 quirk as Accuracy.lua: byte is 0..255, threshold is
-- floor(chance * 255 / 100), proc when byte < threshold.  chance 0 never;
-- chance 100 is byte < 255 (always except the 1/256 roll of 255).  Draws
-- nothing at chance 0 -- the cart's `effectchance` does (M.effectChance), so
-- the turn machine draws through that one.
function M.sideChanceProc(rng, chance)
  chance = max(0, min(100, int(chance, 0)))
  if chance <= 0 then return false end
  local threshold = floor(chance * 255 / 100)
  if threshold <= 0 then return false end
  return rng and rng:byte() < threshold
end

-- BattleCommand_EffectChance (pokecrystal engine/battle/effect_commands.asm:
-- 1851-1874, pokegold the same): wEffectFailed is cleared, a substitute
-- standing (CheckSubstituteOpp) fails it before any byte, and otherwise
-- BattleRandom is drawn WHATEVER the chance -- 0 included, which then never
-- lands -- and lands under the move's chance byte (the wire's percent back as
-- the cart's byte, floor(pct * 255 / 100); the 1/256 miss of a 100% move is
-- the cart's bug, kept).  Returns whether wEffectFailed stayed clear.
function M.effectChance(rng, chance, behindSub)
  if behindSub then return false end
  local pct = max(0, min(100, int(chance, 0)))
  local byte = rng and rng:byte() or 255
  return byte < floor(pct * 255 / 100)
end

-- The scripts (data/moves/effects.asm) that run `effectchance` right after
-- `checkhit` -- so the byte is drawn on a miss too, failuretext ending the
-- move only after it -- by this table's ids: the status / flinch / stat-down
-- / confusion hits and TWINEEDLE (whose one `effectchance` stands before its
-- loop), and the Gold-native rows but TRI ATTACK (its `tristatuschance`
-- calls EffectChance itself, after `checkfaint`) and GUST (none).
-- EARTHQUAKE and SKY ATTACK draw one at chance 0 on both carts.  Id 0 is
-- NormalHit's fold, which draws none -- but THIEF folds there too (no Gen 1
-- handler is its `thief`), and its script has the command: a damaging id-0
-- move that states a chance is read as one that runs it (`drawsEffectChance`).
M.EFFECT_CHANCE_SCRIPTS = {
  [2] = true, [4] = true, [5] = true, [6] = true, [31] = true,
  [33] = true, [34] = true, [35] = true, [36] = true, [37] = true,
  [68] = true, [69] = true, [70] = true, [71] = true, [76] = true, [77] = true,
  [87] = true, [88] = true, [89] = true, [90] = true, [91] = true,
  [92] = true, [93] = true, [94] = true, [95] = true, [96] = true, [97] = true,
  [100] = true, [101] = true,
}

function M.drawsEffectChance(effectId, move)
  local id = int(effectId, 0)
  if M.EFFECT_CHANCE_SCRIPTS[id] then return true end
  if id ~= 0 or type(move) ~= "table" then return false end
  return int(move.power, 0) > 0 and int(move.chance, 0) > 0
end

local SIDE_STAT_DOWN = {
  [68] = "atk", [69] = "def", [70] = "spe", [71] = "spa",
  [87] = "spd", [88] = "acc",
}
-- The *UpHit scripts' raises, on the USER (BattleCommand_AttackUp /
-- DefenseUp, and AllStatsUp's five in its order).
local SIDE_STAT_UP = {
  [89] = { "atk" },
  [90] = { "def" },
  [91] = { "atk", "def", "spe", "spa", "spd" },
}
local SIDE_POISON = { [2] = true, [33] = true, [77] = true }
local SIDE_BURN = { [4] = true, [34] = true, [92] = true, [93] = true }
local SIDE_FREEZE = { [5] = true, [35] = true }
local SIDE_PARALYZE = { [6] = true, [36] = true, [97] = true }
local SIDE_FLINCH = {
  [31] = true, [37] = true, [94] = true, [95] = true, [96] = true, [101] = true,
}

local SIDE_TEXT = {
  poison = "was poisoned", burn = "was burned",
  freeze = "was frozen solid", paralysis = "is paralyzed",
}
local SIDE_TOKEN = { poison = "PSN", burn = "BRN", freeze = "FRZ", paralysis = "PAR" }

-- The status lands the way the cart writes it (`setStatus`: a burn's or a
-- paralysis's penalty on the battle stat as it stands, no rebuild), on the
-- target's seat's badges.
local function inflict(out, fighter, mon, status, wire)
  setStatusOn(mon, fighter, status)
  local text = mon.species .. " " .. SIDE_TEXT[status]
  out.messages[#out.messages + 1] = text
  local fields = fighterFields(fighter)
  fields.status = wire[status] or SIDE_TOKEN[status]
  fields.text = text
  out.events[#out.events + 1] = { kind = "status", fields = fields }
end

-- CheckMoveTypeMatchesTarget (effect_commands.asm:5909-5945, pokegold the
-- same): the move's type against both of the target's, "unless the move is
-- Normal (Tri Attack)" -- a NORMAL move never matches.  `normalType` is
-- NORMAL's chart index off the ruleset's typeIds; a fight that names no types
-- compares the indices alone, which every burn and freeze move on the carts
-- (none of them Normal) answers the same way.
local function moveTypeMatchesTarget(targetMon, moveType, normalType)
  if moveType == nil then return false end
  if normalType ~= nil and moveType == normalType then return false end
  return hasType(targetMon, moveType)
end

-- The status commands, one function each because TRI ATTACK's
-- `tristatuschance` jumps into whichever its byte names.  `s` is the side
-- state applySide builds: target, fighter, wire, behindSub, moveType,
-- normalType, poisonType, safeguard (the target's side has SAFEGUARD up:
-- SafeCheckSafeguard, the last check before each status lands).  Each
-- command also asks the target's HELD_PREVENT_* item (Items.prevents) just
-- ahead of wEffectFailed, as the cart orders it; all of these stop silently.

-- BattleCommand_PoisonTarget (:3668-3700; Twineedle's `poisontarget` after
-- its loop is the same command): a substitute, any status, a POISON-type
-- target (CheckIfTargetIsPoisonType -- POISON alone, so a STEEL type a
-- non-Poison move reaches, Twineedle's BUG, is poisoned), HELD_PREVENT_POISON,
-- wEffectFailed, then Safeguard.
local function poisonTarget(out, s, hit)
  if s.behindSub or M.hasMajorStatus(s.target) then return end
  if hasType(s.target, s.poisonType) then return end
  if Items.prevents(s.target, "poison") then return end
  if not hit or s.safeguard then return end
  out.proc = true
  inflict(out, s.fighter, s.target, "poison", s.wire)
end

-- BattleCommand_BurnTarget (:3930-3968): a substitute returns; a target
-- with any status jumps to Defrost (:3969-3993) BEFORE wEffectFailed is
-- read, so a frozen target is thawed by every burn-family hit that reaches
-- the command, its chance byte landed or not ("<TARGET> was defrosted!"),
-- and any other status ends it there; then a target sharing the move's type
-- (CheckMoveTypeMatchesTarget: don't burn a Fire type), HELD_PREVENT_BURN,
-- wEffectFailed, then Safeguard.  Defrost writes the status byte with no
-- rebuild (`setStatus`).
local function burnTarget(out, s, hit)
  if s.behindSub then return end
  local targetMon = s.target
  if M.hasMajorStatus(targetMon) then
    if targetMon.status == "freeze" then
      setStatusOn(targetMon, s.fighter, nil)
      targetMon.statusTurns = 0
      local text = targetMon.species .. " was defrosted"
      out.messages[#out.messages + 1] = text
      -- No token: a `status` event without one is a cure (events.lua).
      local fields = fighterFields(s.fighter)
      fields.text = text
      out.events[#out.events + 1] = { kind = "status", fields = fields }
      out.proc = true
    end
    return
  end
  if moveTypeMatchesTarget(targetMon, s.moveType, s.normalType) then return end
  if Items.prevents(targetMon, "burn") then return end
  if not hit or s.safeguard then return end
  out.proc = true
  inflict(out, s.fighter, targetMon, "burn", s.wire)
end

-- BattleCommand_FreezeTarget (:3994-4044): a substitute, any status, the
-- sun (`cp WEATHER_SUN / ret z`: nothing freezes under SUNNY DAY -- `s.sunny`),
-- a target sharing the move's type (don't freeze an Ice type),
-- HELD_PREVENT_FREEZE, wEffectFailed, then Safeguard.  What a landed freeze
-- does after its berry check -- OpponentCantMove, EndRechargeOpp and
-- wEnemyJustGotFrozen -- is Turn's `_applySide`, which asks the berry.
local function freezeTarget(out, s, hit)
  if s.behindSub or M.hasMajorStatus(s.target) then return end
  if s.sunny then return end
  if moveTypeMatchesTarget(s.target, s.moveType, s.normalType) then return end
  if Items.prevents(s.target, "freeze") then return end
  if not hit or s.safeguard then return end
  out.proc = true
  inflict(out, s.fighter, s.target, "freeze", s.wire)
end

-- BattleCommand_ParalyzeTarget (:4045-4078): a substitute, any status,
-- HELD_PREVENT_PARALYZE, wEffectFailed, then Safeguard.  No type check at all
-- -- an ELECTRIC move paralyses an Electric type and a NORMAL one a Normal
-- type on both carts.
local function paralyzeTarget(out, s, hit)
  if s.behindSub or M.hasMajorStatus(s.target) then return end
  if Items.prevents(s.target, "paralysis") then return end
  if not hit or s.safeguard then return end
  out.proc = true
  inflict(out, s.fighter, s.target, "paralysis", s.wire)
end

-- Guard on TRI ATTACK's `.loop`, which redraws a byte whose bits 4-5 are 0;
-- the same count Turn.REDRAW_LIMIT holds the cart's other loops to, and the
-- same in both runtimes.  Won in a handful of draws; the guard only keeps the
-- referee from trusting that.
M.REDRAW_LIMIT = 1024

-- BattleCommand_TriStatusChance (:4730-4746): its own `effectchance` (the
-- script has none after `checkhit`), then `.loop` -- BattleRandom, `swap a`,
-- `and %11`, 0 drawn again -- WHATEVER effectchance said, a substitute
-- standing or not: 1 is ParalyzeTarget, 2 FreezeTarget, 3 BurnTarget, each
-- with its own checks and wEffectFailed.  So a frozen target is thawed when
-- the loop lands on BurnTarget, its chance byte failed or not, and a Normal
-- TRI ATTACK freezes an Ice type (CheckMoveTypeMatchesTarget's exemption).
local function triStatusChance(out, s, rng, chance)
  local hit = M.effectChance(rng, chance, s.behindSub)
  local pick = 0
  for _ = 1, M.REDRAW_LIMIT do
    pick = floor((rng and rng:byte() or 0) / 16) % 4
    if pick ~= 0 then break end
  end
  if pick == 0 then pick = 1 end
  if pick == 1 then
    paralyzeTarget(out, s, hit)
  elseif pick == 2 then
    freezeTarget(out, s, hit)
  else
    burnTarget(out, s, hit)
  end
end

-- RaiseStat (:4142-4231) for the *UpHit side effects: wEffectFailed (the
-- script's `effectchance`), a stage already at +6 (`.cant_raise_stat`), and
-- -- for a stat that is not accuracy or evasion -- the battle stat already at
-- MAX_STAT_VALUE (`.stats_already_max`, the stage put back) all fail it, and
-- silently: these scripts carry `statupmessage`, which speaks only when
-- wFailedMessage is 0, and no fail text.  The battle stat is the one in
-- wBattleMonStats (`storedStat`, with the seat's badges).  Returns whether the
-- stage moved.
local function raiseSideStat(out, fighter, mon, stat, hit, badges)
  if not hit then return false end
  local before = M.clampStage(mon.stages[stat])
  if before >= M.STAGE_MAX then return false end
  if stat ~= "acc" and stat ~= "eva"
     and M.storedStat(mon, stat, badges) >= M.MAX_STAT_VALUE then
    return false
  end
  return applyStatChange(out, fighter, mon, stat, 1)
end

-- The secondary effect of a damaging hit, run where every *Hit script runs it:
-- after `checkfaint` (the caller never asks for a target the hit knocked out)
-- and `buildopponentrage`, whether the hit reached the HP or a substitute took
-- it -- `checkfaint` reads the monster's HP, not the doll's, so a hit into a
-- substitute goes on to the effect command, and each routine asks about the
-- substitute itself (CheckSubstituteOpp: the one standing NOW, so a hit that
-- broke it is past it).
--
-- ctx: effectId, hit, rng, targetMon, targetFighter, userMon, userFighter,
--      userBadges (the user's seat badges, for RaiseStat's 999 test),
--      statusToWire, moveType (the move's chart index), poisonType /
--      normalType (POISON's and NORMAL's chart indices off the ruleset's
--      typeIds, nil when it names none), computerMover (the move is the
--      computer's: BattleCommand_StatDown's extra miss), chance (the move's
--      percent: TRI ATTACK's and DEFENSE_DOWN_HIT's own bytes, and the byte
--      drawn here when `hit` is absent).
-- Returns { proc, messages, events }.  `hit` is BattleCommand_EffectChance's
-- verdict, drawn by the caller where the script's `effectchance` stands --
-- false when a substitute stood at it (CheckSubstituteOpp, before the byte);
-- absent, the byte is drawn here first.  `rng` is also the computer's
-- stat-down byte, the confusion side effect's turn count and TRI ATTACK's
-- loop.  Each routine below runs in pokecrystal's order (engine/battle/
-- effect_commands.asm, diffed against pokegold), HELD_PREVENT_* (no item on
-- either cart carries one, data/items/attributes.asm, but the rule is keyed
-- on the token) and SafeCheckSafeguard (`targetSafeguard`: the target's side
-- has SAFEGUARD up) included, FreezeTarget's WEATHER_SUN return (`sunny`,
-- wave 3) and FlinchTarget's CheckOpponentWentFirst (`targetWentFirst`).
function M.applySide(ctx)
  ctx = ctx or {}
  local out = { proc = false, messages = {}, events = {} }
  local effectId = int(ctx.effectId, 0)
  local rng = ctx.rng
  local targetMon = ctx.targetMon
  local targetFighter = ctx.targetFighter
  if type(targetMon) ~= "table" then return out end
  local behindSub = int(targetMon.substitute, 0) > 0
  local s = {
    target = targetMon, fighter = targetFighter, wire = ctx.statusToWire or {},
    behindSub = behindSub, moveType = int(ctx.moveType, nil),
    normalType = ctx.normalType, poisonType = ctx.poisonType,
    safeguard = ctx.targetSafeguard == true, sunny = ctx.sunny == true,
  }

  if effectId == M.TRI_ATTACK then
    triStatusChance(out, s, rng, ctx.chance)
    return out
  end

  local hit = ctx.hit
  if hit == nil then hit = M.effectChance(rng, ctx.chance, behindSub) end

  if SIDE_POISON[effectId] then poisonTarget(out, s, hit); return out end
  if SIDE_BURN[effectId] then burnTarget(out, s, hit); return out end
  if SIDE_FREEZE[effectId] then freezeTarget(out, s, hit); return out end
  if SIDE_PARALYZE[effectId] then paralyzeTarget(out, s, hit); return out end

  -- BattleCommand_FlinchTarget (:5357-5374): a substitute, then a sleeping or
  -- frozen target (`and 1 << FRZ | SLP_MASK / ret nz`), then
  -- CheckOpponentWentFirst -- a target that already moved this turn
  -- (`targetWentFirst`, Turn `_wentFirst`) is not flinched -- then
  -- wEffectFailed, and FlinchTarget: SUBSTATUS_FLINCHED and EndRechargeOpp, so
  -- a target that owes a recharge loses its turn to "flinched" (CheckTurn's
  -- flinch, its gates run) instead of "must recharge" (R2b's finding (i)).
  -- STOMP, TWISTER, SNORE and SKY ATTACK end in this same command.
  if SIDE_FLINCH[effectId] then
    if behindSub then return out end
    if targetMon.status == "sleep" or targetMon.status == "freeze" then return out end
    if ctx.targetWentFirst then return out end
    if not hit then return out end
    out.proc = true
    targetMon.flinch = true
    targetMon.mustRecharge = false
    return out
  end

  -- BattleCommand_StatDown, the routine the primary moves share
  -- (statDownGate: Mist, -6, the computer's byte -- not for ACCURACY_DOWN_HIT),
  -- then `.DidntMiss`: a substitute, wEffectFailed and CheckHiddenOpponent,
  -- each `.Failed`, and TryLowerStat's floor at a battle stat of 1
  -- (`.CouldntLower`).  A *Hit script has no `statdownfailtext` and
  -- `statdownmessage` speaks only when wFailedMessage is 0, so every one of
  -- those fails silently -- no "But it failed", no "won't drop anymore".
  --
  -- DefenseDownHit runs a SECOND `effectchance` between `buildopponentrage`
  -- and `defensedown` (pokecrystal docs/bugs_and_glitches.md, "Moves that
  -- lower Defense can do so after breaking a Substitute"): its byte is drawn
  -- here, against the substitute standing now -- so a hit that broke the doll
  -- draws it, and the drop can land -- and it is that verdict StatDown reads.
  local stat = SIDE_STAT_DOWN[effectId]
  if stat then
    if effectId == 69 then hit = M.effectChance(rng, ctx.chance, behindSub) end
    if M.statDownGate(rng, targetMon, stat, ctx.computerMover == true, effectId,
                      targetMon.lockOn == true) then
      return out
    end
    if behindSub or not hit or targetMon.invulnerable then return out end
    if statAtFloor(targetMon, stat, targetFighter and targetFighter.badges or nil) then
      return out
    end
    out.proc = true
    applyStatChange(out, targetFighter, targetMon, stat, -1)
    return out
  end

  -- The *UpHit scripts' `attackup` / `defenseup` / `allstatsup` on the user
  -- (raiseSideStat; AllStatsUp's ResetMiss lets each of the five fail alone).
  local ups = SIDE_STAT_UP[effectId]
  if ups then
    local userMon = ctx.userMon
    if type(userMon) ~= "table" then return out end
    for _, key in ipairs(ups) do
      if raiseSideStat(out, ctx.userFighter, userMon, key, hit, ctx.userBadges) then
        out.proc = true
      end
    end
    return out
  end

  -- BattleCommand_ConfuseTarget (:5732-5749): HELD_PREVENT_CONFUSE,
  -- wEffectFailed, Safeguard, a substitute, then a target already confused,
  -- all before FinishConfusingTarget draws the 2-5 turn byte.
  if effectId == 76 then
    if Items.prevents(targetMon, "confusion") then return out end
    if not hit or s.safeguard or behindSub then return out end
    if targetMon.confusion and targetMon.confusion > 0 then return out end
    out.proc = true
    confuse(out, targetFighter, targetMon, rng, false)
    return out
  end

  return out
end

-- ------------------------------------------------------------------
-- Phase 3 multi-hit, fixed damage, drain, recoil
-- ------------------------------------------------------------------

-- The looping scripts that hit through `startloop` / `endloop` -- MultiHit,
-- DoubleHit, PoisonMultiHit and (wave 3) TripleKick -- every hit its own
-- `critical` and `damagevariation`.  BeatUp loops too, over its party, and is
-- Turn's own (`_beatUp`).
local MULTIHIT = { [29] = true, [44] = true, [77] = true, [112] = true }
-- The ConstantDamage scripts (SuperFang / StaticDamage / Psywave, the
-- LEVEL_DAMAGE row sharing them): `constantdamage`, `checkhit`,
-- `resettypematchup` -- no `critical`, no `damagevariation` (R2b's finding
-- (g)).  REVERSAL runs `constantdamage` too but into DamageCalc and `stab`;
-- Turn runs it apart.
local FIXED_DAMAGE = { [38] = true, [40] = true, [41] = true, [131] = true, [132] = true }
local DRAIN = { [3] = true, [8] = true }
local RECOIL = { [48] = true }

-- The damaging scripts whose `checkhit` comes before `critical` and
-- `damagevariation` (data/moves/effects.asm): Rampage (THRASH), TrapTarget
-- and Present -- the looping scripts too (`isMultihit`, BEAT UP).
M.HIT_FIRST = { [27] = true, [42] = true, [111] = true }
-- ...and the ones whose `critical` comes before `checkhit` but whose
-- `damagevariation` comes after it: Rage, FuryCutter, Rollout, Thunder.
M.ROLL_AFTER_CHECKHIT = { [81] = true, [97] = true, [113] = true, [114] = true }
-- RolloutPower's MAX_ROLLOUT_COUNT.
M.ROLLOUT_MAX = 5

function M.isMultihit(effectId)
  return MULTIHIT[int(effectId, 0)] == true
end

-- The hits a script is known to run before its loop starts: DoubleHit and
-- PoisonMultiHit (TWINEEDLE) two (`.double_hit` / `.twineedle`: `ld a, 1`,
-- one more pass), every other script one.  MultiHit's count is not known yet
-- -- BattleCommand_EndLoop draws it after the first hit (`multiHitCount`) --
-- so it starts at one too.  Draws nothing.
function M.fixedHits(effectId)
  effectId = int(effectId, 0)
  if effectId == 44 or effectId == 77 then return 2 end
  return 1
end

-- BattleCommand_EndLoop's first pass for EFFECT_MULTI_HIT (pokecrystal
-- engine/battle/effect_commands.asm:5271-5284, pokegold the same), drawn
-- after the first hit's `checkfaint` / `buildopponentrage` (a first hit that
-- knocked the target out ended the move before it): BattleRandom & 3 stands
-- when under 2, otherwise a second BattleRandom & 3 replaces it, and the move
-- hits that + 2 times in all -- 2 and 3 at 3/8 each, 4 and 5 at 1/8.
function M.multiHitCount(rng)
  local a = (rng and rng:byte() or 0) % 4
  if a >= 2 then a = (rng and rng:byte() or 0) % 4 end
  return a + 2
end

-- EndLoop's `.reject_triple_kick_sample` for TRIPLE KICK, drawn after its
-- first kick the same way: BattleRandom & 3, drawn again on 0 -- the kicks in
-- all, 1, 2 or 3 alike (`dec a / jr nz, .double_hit`; 1 is `.done_loop`).
function M.tripleKickCount(rng)
  for _ = 1, M.REDRAW_LIMIT do
    local a = (rng and rng:byte() or 0) % 4
    if a ~= 0 then return a end
  end
  return 1
end

function M.isFixedDamage(effectId)
  return FIXED_DAMAGE[int(effectId, 0)] == true
end

-- EFFECT_OHKO: BattleCommand_OHKO, its own accuracy and $ffff (Turn).
function M.isOhko(effectId)
  return int(effectId, 0) == 38
end

function M.isDrain(effectId)
  return DRAIN[int(effectId, 0)] == true
end

function M.isRecoil(effectId)
  return RECOIL[int(effectId, 0)] == true
end

function M.drainAmount(damage)
  return floor(max(0, int(damage, 0)) / 2)
end

-- BattleCommand_Recoil (effect_commands.asm:5670-5730): a quarter of
-- wCurDamage, at least 1.  wCurDamage after `applydamage` is the HP the hit
-- took -- the HP left when it was lethal (DoEnemyDamage's underflow) -- and 0
-- when a substitute took it (DoSubstituteDamage ends in ResetDamage), so a
-- recoil move that hits a doll costs its user exactly 1.
function M.recoilAmount(damage)
  return max(1, floor(max(0, int(damage, 0)) / 4))
end

-- BattleCommand_PayDay (move_effects/pay_day.asm): the user's level, `add a`
-- -- doubled in a byte, its carry lost to the `add [hl]` after it -- added to
-- the one wPayDayMoney the fight keeps, whoever's turn it is.
function M.payDayCoins(level)
  return (max(0, int(level, 0)) * 2) % 256
end

-- ctx: effectId, userMon, targetMon, power, rng
-- Returns fixed damage, or nil when the effect fails.  EFFECT_OHKO is not
-- here: Gold's is BattleCommand_OHKO -- a level gate and a raised accuracy,
-- not Red's Speed test -- and Turn resolves it whole (`isOhko`).
--
-- BattleCommand_ConstantDamage (effect_commands.asm:3133-3240): SUPER FANG
-- halves the target's HP (`srl` / `rr` over the 16-bit HP, 1 when that is 0);
-- LEVEL_DAMAGE (SEISMIC TOSS, NIGHT SHADE) is the user's level; PSYWAVE's
-- `.psywave_loop` draws BattleRandom until it is neither 0 nor at or past
-- level + level / 2 (a byte add) -- the only draws these scripts make; every
-- other (STATIC_DAMAGE: SONICBOOM, DRAGON RAGE) is the move's power.
function M.fixedDamage(ctx)
  ctx = ctx or {}
  local effectId = int(ctx.effectId, 0)
  local userMon = ctx.userMon
  local targetMon = ctx.targetMon
  local movePower = int(ctx.power, 0)

  if effectId == 40 then
    return max(1, floor(int(targetMon.hp, 0) / 2))
  end
  if effectId == M.LEVEL_DAMAGE then
    return max(0, int(userMon.level, 1)) % 256
  end
  if effectId == M.PSYWAVE then
    local level = max(0, int(userMon.level, 1)) % 256
    local cap = (level + floor(level / 2)) % 256
    -- A cap of 0 or 1 has no byte in range: the cart's loop never ends (a
    -- level-0 or level-1 user).  Freezes are never kept -- the guard ends it
    -- at the smallest damage the loop could give.
    for _ = 1, M.REDRAW_LIMIT do
      local r = ctx.rng and ctx.rng:byte() or 1
      if r ~= 0 and r < cap then return r end
      if cap <= 1 then break end
    end
    return 1
  end
  if effectId == 41 then
    if movePower >= 1 then return movePower end
    return max(1, int(userMon.level, 1))
  end
  return nil
end

-- ------------------------------------------------------------------
-- the Gold-only damage formulas (wave 3, R2c)
-- ------------------------------------------------------------------

-- BASE_HAPPINESS (constants/pokemon_data_constants.asm): what LoadEnemyMon
-- gives every wild and trainer monster, and what a sheet that states no
-- `happiness` (contract K14) reads as.
M.BASE_HAPPINESS = 70

-- BattleCommand_HappinessPower / FrustrationPower (move_effects/return.asm,
-- frustration.asm): happiness (or 255 - happiness) x 10 / 25, the quotient's
-- low byte -- 0 at the extremes (docs/bugs_and_glitches.md, "Return and
-- Frustration deal no damage when the user's happiness is low or high").
function M.happinessPower(happiness)
  local h = max(0, min(255, int(happiness, M.BASE_HAPPINESS)))
  return floor(h * 10 / 25) % 256
end
function M.frustrationPower(happiness)
  local h = max(0, min(255, int(happiness, M.BASE_HAPPINESS)))
  return floor((255 - h) * 10 / 25) % 256
end

-- HiddenPowerDamage's types (engine/battle/hidden_power.asm): (Atk DV & 3) << 2
-- | (Def DV & 3), plus 1 to skip NORMAL, then past BIRD and the unused types --
-- FIGHTING .. STEEL, then FIRE .. DARK -- as the registry ids a ruleset's
-- `typeIds` names them by.
M.HIDDEN_POWER_TYPES = {
  "FIGHTING", "FLYING", "POISON", "GROUND", "ROCK", "BUG", "GHOST", "STEEL",
  "FIRE", "WATER", "GRASS", "ELECTRIC", "PSYCHIC_TYPE", "ICE", "DRAGON", "DARK",
}

-- The power and the type name HiddenPowerDamage computes from the four DVs
-- (K7 `dvs`, 0..15 each): the top bit of Atk, Def, Speed and Special as a
-- nibble, x 5, plus Special & 3, halved, plus 31 -- 31..70.  nil without DVs.
function M.hiddenPower(dvs)
  if type(dvs) ~= "table" then return nil end
  local atk, def = max(0, int(dvs.atk, 0)) % 16, max(0, int(dvs.def, 0)) % 16
  local spe, spc = max(0, int(dvs.spe, 0)) % 16, max(0, int(dvs.spc, 0)) % 16
  local top = floor(atk / 8) * 8 + floor(def / 8) * 4 + floor(spe / 8) * 2 + floor(spc / 8)
  local power = floor((top * 5 + spc % 4) / 2) + 31
  local index = (atk % 4) * 4 + def % 4
  return power, M.HIDDEN_POWER_TYPES[index + 1]
end

-- FlailReversalPower (data/moves/flail_reversal_power.asm), HP_BAR_LENGTH_PX
-- 48: the HP-bar pixels at or under each row's, and the power it gives.
M.REVERSAL_POWER = {
  { 1, 200 }, { 4, 150 }, { 9, 100 }, { 16, 80 }, { 32, 40 }, { 48, 20 },
}

-- ConstantDamage's `.reversal`: the user's HP x 48 over its max HP -- with a
-- max HP past a byte both sides shifted right twice first (the divisor's low
-- byte, the product's low word; a 0 divisor, which the cart divides by and no
-- 999-HP monster reaches, is read as 1) -- the quotient's low byte, then the
-- first FlailReversalPower row at or past it.
function M.reversalPower(hp, maxHp)
  local h = max(0, int(hp, 0)) % 65536
  local m = max(1, int(maxHp, 1)) % 65536
  local product = h * 48
  local q
  if m < 256 then
    q = floor(product / max(1, m))
  else
    local divisor = floor(m / 4) % 256
    if divisor == 0 then divisor = 1 end
    local dividend = floor(product / 65536) * 65536 + floor((product % 65536) / 4)
    q = floor(dividend / divisor)
  end
  q = q % 256
  for _, row in ipairs(M.REVERSAL_POWER) do
    if row[1] >= q then return row[2] end
  end
  return M.REVERSAL_POWER[#M.REVERSAL_POWER][2]
end

-- MagnitudePower (data/moves/magnitude_power.asm): the first row whose byte is
-- at or past BattleRandom's -- `5 percent + 1` .. `100 percent` -- gives the
-- power and the magnitude its line names.
M.MAGNITUDE_ROWS = {
  { 13, 10, 4 }, { 38, 30, 5 }, { 89, 50, 6 }, { 166, 70, 7 },
  { 217, 90, 8 }, { 242, 110, 9 }, { 255, 150, 10 },
}
function M.magnitude(byte)
  local b = max(0, min(255, int(byte, 0)))
  for _, row in ipairs(M.MAGNITUDE_ROWS) do
    if row[1] >= b then return row[2], row[3] end
  end
  return 150, 10
end

-- PresentPower (data/moves/present_power.asm): 40 / 80 / 120 at or under
-- `40 percent` / `70 percent + 1` / `80 percent`, a heal past that (nil).
M.PRESENT_ROWS = { { 102, 40 }, { 179, 80 }, { 204, 120 } }
function M.presentPower(byte)
  local b = max(0, min(255, int(byte, 0)))
  for _, row in ipairs(M.PRESENT_ROWS) do
    if row[1] >= b then return row[2] end
  end
  return nil
end

-- The cart's own type constants (constants/type_constants.asm), by the
-- registry id a ruleset's `typeIds` names them: what Gold's PRESENT hands
-- DamageCalc as a level and a defense (`present` below) and what CheckTypeMatchup
-- compares.  A type this table does not name reads as NORMAL's 0.
M.TYPE_CONSTANTS = {
  NORMAL = 0, FIGHTING = 1, FLYING = 2, POISON = 3, GROUND = 4, ROCK = 5,
  BIRD = 6, BUG = 7, GHOST = 8, STEEL = 9, CURSE_TYPE = 19, FIRE = 20,
  WATER = 21, GRASS = 22, ELECTRIC = 23, PSYCHIC_TYPE = 24, ICE = 25,
  DRAGON = 26, DARK = 27,
}
function M.typeConstant(name)
  if type(name) ~= "string" then return 0 end
  return M.TYPE_CONSTANTS[name] or 0
end

-- ProtectChance (move_effects/protect.asm), after its went-first and
-- substitute checks: b starts at $ff and halves once per consecutive use
-- before this one (a b of 0 fails with no draw), then BattleRandom is drawn
-- again while it is 0 and the use succeeds when (byte - 1) is under b -- the
-- first use always does, still drawing its byte.
function M.protectChance(rng, count)
  local b = 255
  for _ = 1, max(0, int(count, 0)) do
    b = floor(b / 2)
    if b == 0 then return false end
  end
  local r = 0
  for _ = 1, M.REDRAW_LIMIT do
    r = rng and rng:byte() or 1
    if r ~= 0 then break end
  end
  if r == 0 then r = 1 end
  return (r - 1) < b
end

-- BattleCommand_StartRain / StartSun / StartSandstorm: five turns of weather
-- (wWeatherCount), the count HandleWeather runs down between turns.
M.WEATHER_TURNS = 5
M.WEATHER_OF = { [124] = "rain", [125] = "sun", [126] = "sandstorm" }

-- DoWeatherModifiers (engine/battle/misc.asm:49-131, data/battle/
-- weather_modifiers.asm): the first WeatherTypeModifiers row naming the
-- weather and the move's type -- WATER x1.5 / FIRE x0.5 in rain, FIRE x1.5 /
-- WATER x0.5 in sun -- and only when none does, the WeatherMoveModifiers row:
-- SOLARBEAM x0.5 in rain.  Returns the tenths (15, 5) or nil.  `typeName` is
-- the move's type registry id (the ruleset's `typeIds`); with none, no type
-- row can match.
function M.weatherTenths(weather, typeName, effectId)
  if weather == "rain" then
    if typeName == "WATER" then return 15 end
    if typeName == "FIRE" then return 5 end
  elseif weather == "sun" then
    if typeName == "FIRE" then return 15 end
    if typeName == "WATER" then return 5 end
  end
  if weather == "rain" and int(effectId, 0) == M.SOLARBEAM then return 5 end
  return nil
end

-- HandleWeather's sandstorm: the types it never hits (`cp ROCK / GROUND /
-- STEEL` against both of the battle types).
M.SANDSTORM_IMMUNE = { ROCK = true, GROUND = true, STEEL = true }

-- The weather lines (data/text/battle.asm): the start, the between-turn
-- continuation and the end, per weather.
M.WEATHER_LINES = {
  rain = { start = "A downpour started!", continues = "Rain continues to fall.",
           ended = "The rain stopped." },
  sun = { start = "The sunlight got bright!", continues = "The sunlight is strong.",
          ended = "The sunlight faded." },
  sandstorm = { start = "A SANDSTORM brewed!", continues = "The SANDSTORM rages.",
                ended = "The SANDSTORM subsided." },
}

-- BattleCommand_TimeBasedHealContinue (effect_commands.asm:6421-6513): the
-- heal's row in .Multipliers -- GetEighthMaxHP, GetQuarterMaxHP, GetHalfMaxHP,
-- GetMaxHP (0..3) -- starts at the half; a time of day that is not the
-- move's own (MORNING SUN the morning, SYNTHESIS the day, MOONLIGHT the
-- night; never asked in a link battle -- `timeMatches` true) takes it down
-- one; then any weather takes it up one, and anything but the sun down two
-- more.  Returns the HP it restores.
M.HEAL_TIME = { [128] = "morn", [129] = "day", [130] = "nite" }
function M.timeHealAmount(maxHp, timeMatches, weather)
  local c = 2
  if not timeMatches then c = c - 1 end
  if weather ~= nil then
    c = c + 1
    if weather ~= "sun" then c = c - 2 end
  end
  if c <= 0 then return Items.eighth(maxHp) end
  if c == 1 then return Items.quarter(maxHp) end
  if c == 2 then return Items.half(maxHp) end
  return max(0, int(maxHp, 0)) % 65536
end

-- ------------------------------------------------------------------
-- Phase 4 multi-turn / charge handlers
-- ------------------------------------------------------------------

function M.isCharge(effectId)
  local id = int(effectId, 0)
  return id == 39 or id == 43 or id == M.SKY_ATTACK or id == M.SOLARBEAM
    or id == M.SKULL_BASH
end

function M.isFly(effectId)
  return int(effectId, 0) == 43
end

function M.moveKey(moveOrId)
  local id = moveOrId
  if type(moveOrId) == "table" then id = moveOrId.id end
  if type(id) ~= "string" then return "" end
  return string.upper(id)
end

function M.isDigMove(moveOrId)
  return M.moveKey(moveOrId) == "DIG"
end

function M.isSwift(effectId)
  return int(effectId, 0) == 17
end

function M.vanishes(effectId, moveOrId)
  return M.isFly(effectId) or M.isDigMove(moveOrId)
end

function M.chargeMessage(mon, effectId, moveOrId)
  local key = M.moveKey(moveOrId)
  local species = (mon and mon.species) or "POKéMON"
  if key == "DIG" then return species .. " dug a hole" end
  if key == "SOLARBEAM" then return species .. " took in sunlight" end
  if key == "SKULL_BASH" then return species .. " lowered its head" end
  if key == "RAZOR_WIND" then return species .. " made a whirlwind" end
  if key == "FLY" or M.isFly(effectId) then return species .. " flew up high" end
  return species .. " is glowing"
end

-- CheckHit's .FlyDigMoves (Crystal effect_commands.asm:1713-1746).
-- Swift does *not* reach a vanished target in Gen 2.
M.FLY_DIG_EXCEPTIONS = {
  FLY = { GUST = true, WHIRLWIND = true, THUNDER = true, TWISTER = true },
  DIG = { EARTHQUAKE = true, FISSURE = true, MAGNITUDE = true },
}

function M.hitsInvulnerable(chargeMoveId, attackerMove)
  local charge = M.moveKey(chargeMoveId)
  local id = M.moveKey(attackerMove)
  local reaches = M.FLY_DIG_EXCEPTIONS[charge]
  return (reaches and reaches[id]) and true or false
end

function M.isTrapping(effectId)
  return int(effectId, 0) == 42
end

-- BattleCommand_TrapTarget (effect_commands.asm:5612-5650): BattleRandom & 3,
-- plus 3 -- the wrap count HandleWrap ticks down at the end of every turn,
-- the one the trap landed on included, dealing its sixteenth while the count
-- stays above 0 and releasing at 0: 2..5 turns of residual.
function M.wrapCount(rng)
  return 3 + (rng and rng:byte() or 0) % 4
end

function M.isHyperBeam(effectId)
  return int(effectId, 0) == 80
end

function M.isThrash(effectId)
  return int(effectId, 0) == 27
end

-- BattleCommand_Rampage (effect_commands.asm:4923-4945): "Rampage for 1 or 2
-- more turns", BattleRandom & 1, plus 1 -- the turns after this one.
function M.rampageTurns(rng)
  return 1 + (rng and rng:byte() or 0) % 2
end

-- BattleCommand_CheckRampage's confusion when the count runs out (:4888-
-- 4921): BattleRandom & 1, plus 2.
function M.rampageConfusion(rng)
  return 2 + (rng and rng:byte() or 0) % 2
end

-- BattleCommand_Defrost (:6311-6339), FLAME WHEEL's and SACRED FIRE's
-- `defrost` after the hit: a frozen user thaws.  CheckTurn lets the two
-- through a freeze by move id (`cp FLAME_WHEEL / cp SACRED_FIRE`,
-- :195-202) -- FREEZE_BYPASS.
M.DEFROSTS_USER = { [92] = true, [93] = true }
M.FREEZE_BYPASS = { FLAME_WHEEL = true, SACRED_FIRE = true }

-- The damage doublings the scripts run after `damagevariation`, each a 16-bit
-- shift that pins a carry at $ffff (DoubleDamage, :5962-5987;
-- BattleCommand_DoubleMinimizeDamage, :6515-6531): TWISTER and GUST
-- (`doubleflyingdamage`) against a target in the sky, EARTHQUAKE
-- (`doubleundergrounddamage`) against one underground, STOMP
-- (`doubleminimizedamage`) against one that used MINIMIZE.
M.DOUBLE_VS_FLYING = { [95] = true, [99] = true }
-- ...and MAGNITUDE's `doubleundergrounddamage` after its `checkhit` (wave 3).
M.DOUBLE_VS_UNDERGROUND = { [100] = true, [110] = true }
M.DOUBLE_VS_MINIMIZED = { [94] = true }

function M.isRage(effectId)
  return int(effectId, 0) == 81
end

-- ------------------------------------------------------------------
-- move priority
-- ------------------------------------------------------------------
--
-- GetMovePriority (pokecrystal engine/battle/core.asm:829-850): Vital Throw
-- answers 0 by its move id, every other move by its effect's row in
-- data/moves/effects_priorities.asm, and a move with no row is BASE_PRIORITY
-- (constants/battle_constants.asm: 1).  DetermineMoveOrder compares the two
-- numbers before anything else (CompareMovePriority), so a higher one moves
-- first whatever the Speed.
--
-- The cart keys the table by effect; this keys it by the move ids that carry
-- those effects (data/moves/moves.asm), because none of the five effects has
-- an id in this file's table -- a Gold sheet names EFFECT_PROTECT /
-- EFFECT_ENDURE / EFFECT_PRIORITY_HIT / EFFECT_COUNTER / EFFECT_MIRROR_COAT
-- as effect 0 (GEN2_EFFECT_ID above), and EFFECT_FORCE_SWITCH shares 28 with
-- Gen 1's Teleport row.  The selected move's id is what is read, as the cart
-- reads wCurPlayerMove: Metronome and Mirror Move move at base priority
-- whatever they call.
M.BASE_PRIORITY = 1
M.MOVE_PRIORITY = {
  PROTECT = 3, DETECT = 3,                            -- EFFECT_PROTECT, 3
  ENDURE = 3,                                         -- EFFECT_ENDURE, 3
  QUICK_ATTACK = 2, MACH_PUNCH = 2, EXTREMESPEED = 2, -- EFFECT_PRIORITY_HIT, 2
  WHIRLWIND = 0, ROAR = 0,                            -- EFFECT_FORCE_SWITCH, 0
  COUNTER = 0,                                        -- EFFECT_COUNTER, 0
  MIRROR_COAT = 0,                                    -- EFFECT_MIRROR_COAT, 0
  VITAL_THROW = 0,                                    -- `cp VITAL_THROW / ld a, 0`
}

-- From wave 3 four of those effects have ids of their own, so a sheet that
-- states no `priority` is ordered by them as the cart orders by the effect
-- (data/moves/effects_priorities.asm): PROTECT / ENDURE 3, COUNTER / MIRROR
-- COAT 0 -- after VITAL THROW's move-id row, which the cart asks first.
M.EFFECT_PRIORITY = { [120] = 3, [121] = 3, [122] = 0, [123] = 0 }

-- The priority bracket of a move (a move record or its id).  A record's own
-- `priority` (contract K8: the cart's raw GetMovePriority number, 0..255,
-- which the client stamps from the move's effect -- or a content mod's move
-- states) wins over the table, so a modded move with a priority effect moves
-- in its bracket; the tables answer for a sheet that states none.
function M.movePriority(moveOrId)
  if type(moveOrId) == "table" and type(moveOrId.priority) == "number" then
    return moveOrId.priority
  end
  local key = M.moveKey(moveOrId)
  if key ~= "VITAL_THROW" and type(moveOrId) == "table" then
    local byEffect = M.EFFECT_PRIORITY[int(moveOrId.effect, -1)]
    if byEffect ~= nil then return byEffect end
  end
  local priority = M.MOVE_PRIORITY[key]
  if priority == nil then return M.BASE_PRIORITY end
  return priority
end

-- Gen1 category is type-based (Fire/Water/…/Dragon → Special; else Physical).
-- `specialTypes` is a set of chart indices uploaded with the ruleset; absent
-- or empty means every damaging move stays Physical (atk/def).
function M.isSpecialType(typeId, specialTypes)
  if type(specialTypes) ~= "table" then return false end
  return specialTypes[int(typeId, 0)] == true
end

-- Hand-authored Gen1 battle items (public heal amounts / X-item stages).
-- Unknown ids return nil; Turn announces "But it failed" and still spends the
-- turn (no silent soft-stall on junk ids). Hub bag proofs (PROTOCOL 15) refuse
-- / debit against the uploaded sheet; clients still debit save.inventory.
local ITEM_STATUS = {
  ANTIDOTE = { poison = true, toxic = true },
  BURN_HEAL = { burn = true },
  ICE_HEAL = { freeze = true },
  AWAKENING = { sleep = true },
  PARLYZ_HEAL = { paralysis = true },
  FULL_HEAL = {
    poison = true, toxic = true, burn = true,
    freeze = true, sleep = true, paralysis = true,
  },
  -- Gen 2 berries (same clear sets as the Gen1 cures they replaced).
  PSNCUREBERRY = { poison = true, toxic = true },
  PRZCUREBERRY = { paralysis = true },
  BURNT_BERRY = { freeze = true },
  ICE_BERRY = { burn = true },
  MINT_BERRY = { sleep = true },
  MIRACLEBERRY = {
    poison = true, toxic = true, burn = true,
    freeze = true, sleep = true, paralysis = true,
  },
}
-- Wire keys match Gen1 ids (X_DEFEND, not X_DEFENSE). X_ACCURACY is a flag.
local ITEM_X_STAGE = {
  X_ATTACK = "atk", X_DEFEND = "def", X_SPEED = "spe", X_SPECIAL = "spa",
}
local ITEM_VITAMIN = {
  HP_UP = "hp", PROTEIN = "atk", IRON = "def",
  CARBOS = "spe", CALCIUM = "spa",
}
-- Gen1 vitamins add 2560 Stat Exp and fail once that pool is already ≥ 25600.
M.VITAMIN_GAIN = 2560
M.VITAMIN_FAIL_AT = 25600

local ITEM_BALL = {
  POKE_BALL = true, GREAT_BALL = true, ULTRA_BALL = true,
  MASTER_BALL = true, SAFARI_BALL = true,
  -- Gen 2 Kurt / Park balls (hub treats as ball=true; catch math stays local).
  LEVEL_BALL = true, LURE_BALL = true, MOON_BALL = true, FRIEND_BALL = true,
  FAST_BALL = true, HEAVY_BALL = true, LOVE_BALL = true, PARK_BALL = true,
}

local ITEM_HEAL = {
  POTION = 20, SUPER_POTION = 50, HYPER_POTION = 200,
  FRESH_WATER = 50, SODA_POP = 60, LEMONADE = 80,
  BERRY = 10, BERRY_JUICE = 20,
}

-- Deliberately absent from itemEffect (unknown → "But it failed", still spend
-- the turn; bag upload also omits them via itemIsBattleUsable):
--   PP_UP / PP_UP_2, evolutionary stones, RARE_CANDY, HM/TM,
--   Repel / Super Repel / Max Repel, Escape Rope, and other field-only ids.
-- In-battle catalog covered above: heals, status cures, Revive/Ether/Elixer,
-- X-items / Dire Hit / Guard Spec, balls, Poké Doll, Poké Flute, vitamins.

function M.itemEffect(itemId)
  if type(itemId) ~= "string" or itemId == "" then return nil end
  if itemId == "MAX_POTION" then
    return { healFull = true, needsParty = true }
  end
  if itemId == "FULL_RESTORE" then
    return { healFull = true, clearAllStatus = true, needsParty = true }
  end
  if itemId == "REVIVE" then
    return { revive = 0.5, needsParty = true, faintedOnly = true }
  end
  if itemId == "MAX_REVIVE" then
    return { revive = 1, needsParty = true, faintedOnly = true }
  end
  if itemId == "ETHER" then
    return { ppRestore = 10, needsParty = true, needsMove = true }
  end
  if itemId == "MAX_ETHER" then
    return { ppRestore = true, needsParty = true, needsMove = true }
  end
  if itemId == "ELIXER" or itemId == "ELIXIR" then
    return { ppRestoreAll = 10, needsParty = true }
  end
  if itemId == "MAX_ELIXER" or itemId == "MAX_ELIXIR" then
    return { ppRestoreAll = true, needsParty = true }
  end
  if itemId == "X_ACCURACY" then
    return { xAccuracy = true, activeOnly = true }
  end
  if itemId == "DIRE_HIT" then
    return { focusEnergy = true, activeOnly = true }
  end
  if itemId == "GUARD_SPEC" then
    return { mist = true, activeOnly = true }
  end
  if itemId == "POKE_DOLL" then
    return { pokeDoll = true }
  end
  if itemId == "POKE_FLUTE" then
    -- Key item: wakes sleep on every battler's party; never consumed.
    return { pokeFlute = true, noConsume = true }
  end
  local stageStat = ITEM_X_STAGE[itemId]
  if stageStat then
    return { stage = { stat = stageStat, delta = 1 }, activeOnly = true }
  end
  local vitaminStat = ITEM_VITAMIN[itemId]
  if vitaminStat then
    -- Fight-local Stat Exp on the uploaded sheet; the client writebacks
    -- save.statExp on confirm. No permanent EV store on the hub itself.
    return { vitamin = true, vitaminStat = vitaminStat, needsParty = true }
  end
  if ITEM_BALL[itemId] then
    return { ball = true }
  end
  local heal = ITEM_HEAL[itemId]
  local statuses = ITEM_STATUS[itemId]
  if not heal and not statuses then return nil end
  return { heal = heal, clearStatuses = statuses, needsParty = true }
end

-- Potion / Ether / status cure / vitamin cannot apply to a KO (Revive is
-- faintedOnly). Shared by the item picker and `_normaliseChoice` so a
-- submitted choice cannot spend the bag or the turn.
function M.itemFailsOnFainted(effect)
  if type(effect) ~= "table" or effect.faintedOnly then return false end
  return not not (effect.heal or effect.healFull or effect.clearStatuses
      or effect.clearAllStatus or effect.ppRestore or effect.ppRestoreAll
      or effect.vitamin)
end

-- Apply a Gen1 vitamin to a battle mon sheet. Mutates `mon.evs` and battle
-- stats / maxHp. Returns result table or nil when it fails.
function M.applyVitamin(mon, itemId)
  if type(mon) ~= "table" then return nil end
  local effect = M.itemEffect(itemId)
  local stat = effect and effect.vitaminStat
  if not stat then return nil end
  mon.evs = mon.evs or {}
  local before = math.max(0, int(mon.evs[stat], 0))
  if before >= M.VITAMIN_FAIL_AT then return nil end
  local after = math.min(65535, before + M.VITAMIN_GAIN)
  mon.evs[stat] = after
  local function contrib(ev)
    return math.floor(math.sqrt(math.max(0, ev)) / 4)
  end
  local level = math.max(1, int(mon.level, 1))
  local delta = math.floor((contrib(after) - contrib(before)) * level / 100)
  if stat == "hp" then
    mon.maxHp = math.max(1, int(mon.maxHp, 1) + delta)
    mon.hp = math.min(mon.maxHp, int(mon.hp, 0) + delta)
  else
    mon.stats = mon.stats or {}
    mon.stats[stat] = math.max(1, int(mon.stats[stat], 1) + delta)
  end
  return { stat = stat, delta = delta, before = before, after = after }
end

-- Sheet snapshot for a catch outcome (battleMon-shaped).
function M.caughtSheet(mon)
  if type(mon) ~= "table" then return nil end
  local moves = {}
  for i = 1, #(mon.moves or {}) do
    local m = mon.moves[i]
    if m then
      moves[#moves + 1] = {
        id = m.id or "move",
        name = m.name,
        pp = math.max(0, int(m.pp, 0)),
        power = math.max(0, int(m.power, 0)),
        accuracy = math.max(0, int(m.accuracy, 255)),
        type = math.max(0, int(m.type, 0)),
        effect = math.max(0, int(m.effect, 0)),
        chance = math.max(0, int(m.chance, 0)),
      }
    end
  end
  if #moves == 0 then return nil end
  local out = {
    species = tostring(mon.species or "?"),
    level = math.max(1, int(mon.level, 1)),
    hp = math.max(0, int(mon.hp, 0)),
    maxHp = math.max(1, int(mon.maxHp, 1)),
    stats = {
      atk = math.max(1, int(mon.stats and mon.stats.atk, 1)),
      def = math.max(1, int(mon.stats and mon.stats.def, 1)),
      spe = math.max(1, int(mon.stats and mon.stats.spe, 1)),
      spa = math.max(1, int(mon.stats and mon.stats.spa, 1)),
      spd = math.max(1, int(mon.stats and mon.stats.spd, 1)),
    },
    moves = moves,
    catchRate = math.max(0, math.min(255, int(mon.catchRate, 255))),
  }
  if mon.speciesId then out.speciesId = tostring(mon.speciesId) end
  if type(mon.types) == "table" then out.types = mon.types end
  return out
end

-- Gen1 ItemUseBall factors (engine/items/item_effects.asm). Public constants.
local BALL_DEFS = {
  MASTER_BALL = { autoCatch = true },
  POKE_BALL   = { randMax = 255, hpFactor = 12, wobbleFactor = 255 },
  GREAT_BALL  = { randMax = 200, hpFactor = 8,  wobbleFactor = 200 },
  ULTRA_BALL  = { randMax = 150, hpFactor = 12, wobbleFactor = 150 },
  SAFARI_BALL = { randMax = 150, hpFactor = 12, wobbleFactor = 150 },
}
local BALL_DEFAULT = { randMax = 255, hpFactor = 12, wobbleFactor = 150 }

local function catchRoll(rng, maxV)
  maxV = max(0, int(maxV, 0))
  if maxV <= 0 then return 0 end
  if maxV >= 255 then return rng and rng:byte() or 0 end
  return (rng and rng:byte() or 0) % (maxV + 1)
end

-- Returns caught, shakes (0-3).  RNG order: catch roll, then HP roll when
-- the first roll passed the rate check.  Wobble math draws nothing.
function M.catchAttempt(ballId, targetMon, rng)
  local def = BALL_DEFS[ballId] or BALL_DEFAULT
  if def.autoCatch then return true, 3 end

  local rate = int(targetMon and targetMon.catchRate, 255)
  if rate < 0 then rate = 0 elseif rate > 255 then rate = 255 end

  local statusBonus, shakeBonus = 0, 5
  local s = targetMon and targetMon.status
  if s == "sleep" or s == "freeze" then
    statusBonus, shakeBonus = 25, 10
  elseif s then
    statusBonus, shakeBonus = 12, 5
  end

  local maxhp = max(1, int(targetMon and targetMon.maxHp, 1))
  local hp = max(0, int(targetMon and targetMon.hp, 0))
  local hpQuarter = max(1, floor(hp / 4))
  local factor = def.hpFactor or BALL_DEFAULT.hpFactor
  local f = min(255, floor(floor(maxhp * 255 / factor) / hpQuarter))

  local function shakes()
    local ballFactor2 = def.wobbleFactor or BALL_DEFAULT.wobbleFactor
    local y = floor(rate * 100 / ballFactor2)
    local z
    if y > 255 then
      z = 255
    else
      z = floor(f * y / 255)
    end
    if s then z = z + shakeBonus end
    if z < 10 then return 0 elseif z < 30 then return 1
    elseif z < 70 then return 2 else return 3 end
  end

  local r = catchRoll(rng, def.randMax or 255) - statusBonus
  if r < 0 then return true, 3 end
  if r > rate then return false, shakes() end
  if catchRoll(rng, 255) <= f then return true, 3 end
  return false, shakes()
end

function M.isWildMode(mode)
  return type(mode) == "string" and mode:find("wild", 1, true) ~= nil
end

-- ------------------------------------------------------------------
-- Phase 6 meta / flow handlers
-- ------------------------------------------------------------------

local NO_OP = {
  [1] = true, [30] = true,
  [72] = true, [73] = true, [74] = true, [75] = true, [78] = true,
}

function M.isNoOp(effectId)
  return NO_OP[int(effectId, 0)] == true
end

function M.isBide(effectId)
  return int(effectId, 0) == 26
end

function M.bideTurns(rng)
  return 2 + (rng and rng:byte() or 0) % 2
end

function M.isExplode(effectId)
  return int(effectId, 0) == 7
end

function M.isJumpKick(effectId)
  return int(effectId, 0) == 45
end

function M.jumpKickCrash(maxHp)
  return max(1, floor(max(1, int(maxHp, 1)) / 8))
end

function M.isSwitchAndTeleport(effectId)
  return int(effectId, 0) == 28
end

-- Mediated modes (1v1, coop_*) have no wild flee; only modes whose name
-- contains "wild" may treat Teleport as a successful run.
function M.teleportRunAllowed(mode)
  return type(mode) == "string" and mode:find("wild", 1, true) ~= nil
end

-- RUN finishes the fight in wild/coop_wild (flee) and 1v1/coop_pvp
-- (concession). coop_npc -- and any other non-wild non-pvp mode -- refuses
-- without finishing, so a gym cannot be forfeited by pressing RUN.
function M.runEndsBattle(mode)
  if M.teleportRunAllowed(mode) then return true end
  return mode == "1v1" or mode == "coop_pvp"
end

function M.isPayDay(effectId)
  return int(effectId, 0) == 16
end

function M.isMirrorMove(effectId)
  return int(effectId, 0) == 9
end

function M.isMimic(effectId)
  return int(effectId, 0) == 82
end

function M.isMetronome(effectId)
  return int(effectId, 0) == 83
end

return M
