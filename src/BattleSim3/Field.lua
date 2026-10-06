-- Gen 3 field state: weather, the per-side conditions, and the end-of-turn
-- order.
--
-- Port of engine src/core/game3/battle/rules.lua (`Rules.weather`,
-- `FIELD_PHASES_ORDER` pokefirered/src/battle_util.c:453, `BATTLER_PHASES_ORDER`
-- :722, `POST_PHASES_ORDER` :1064, `FAINT_HALT_PHASES`) and capabilities.lua
-- (5-turn screens / weather, 1/16 chips).  The residual handlers themselves are
-- the turn machine's (Turn.lua `_endTurn`), because every one of them writes the
-- event stream; this file is the order they run in and the numbers they use.
--
-- Nothing here raises; no love, no engine modules, no mod facade.

local need = ...
local Types = need("BattleSim3/Types")
local Damage = need("BattleSim3/Damage")

local M = {}

local floor, max = math.floor, math.max

M.WEATHER = { RAIN = true, SUN = true, SAND = true, HAIL = true }
M.WEATHER_TURNS = 5          -- Rain Dance / Sunny Day / Sandstorm / Hail
M.SCREEN_TURNS = 5           -- Reflect / Light Screen
M.SAFEGUARD_TURNS = 5
M.MIST_TURNS = 5
M.WEATHER_CHIP_DENOM = 16
M.TRAP_CHIP_DENOM = 16

-- pokefirered/src/battle_util.c:453
M.FIELD_PHASES = { "reflect", "light_screen", "mist", "safeguard", "wish", "weather" }

-- pokefirered/src/battle_util.c:722 (the enum order is the run order):
-- ENDTURN_ITEMS1 is `held_items` (ItemBattleEffects(NORMAL, battler, FALSE)),
-- ENDTURN_ITEMS2 after Yawn is `held_items2` (the same with moveTurn TRUE --
-- the status cures, a Yawn sleep included).  `volatiles` is the sim's own
-- per-turn bookkeeping, not a cart step.
M.BATTLER_PHASES = {
  "ingrain", "abilities", "held_items", "leech_seed", "status_chip", "nightmare",
  "curse", "partial_trap", "uproar", "thrash", "disable", "encore", "lock_on",
  "charge", "taunt", "yawn", "held_items2", "volatiles",
}

-- pokefirered/src/battle_util.c:1064
M.POST_PHASES = { "fainted_actions", "future_sight", "perish_song" }

-- A battler that faints in one of these stops its remaining end-of-turn steps.
M.FAINT_HALT = {
  ingrain = true, leech_seed = true, status_chip = true, nightmare = true,
  curse = true, partial_trap = true,
}

local function int(value, fallback)
  local n = tonumber(value)
  if not n or n ~= n then return fallback end
  return floor(n)
end

function M.kind(weather)
  if type(weather) ~= "string" then return nil end
  local w = weather:upper()
  if w == "RAIN" or w == "RAINY" or w == "DOWNPOUR" then return "RAIN" end
  if w == "SUN" or w == "SUNNY" then return "SUN" end
  if w == "SAND" or w == "SANDSTORM" then return "SAND" end
  if w == "HAIL" then return "HAIL" end
  return nil
end

-- pokefirered/include/battle_util.h:49 WEATHER_HAS_EFFECT: no Cloud Nine / Air
-- Lock on any standing battler.
function M.effective(weather, battlers)
  local kind = M.kind(weather)
  if not kind then return nil end
  for _, b in ipairs(battlers or {}) do
    if b.ability == "CLOUD_NINE" or b.ability == "AIR_LOCK" then return nil end
  end
  return kind
end

function M.chip(maxHp, denom)
  return max(1, floor(max(0, int(maxHp, 16)) / (denom or M.WEATHER_CHIP_DENOM)))
end

-- Who a sandstorm / hail spares (residual_handlers.lua tickWeather):
-- Rock / Ground / Steel and Sand Veil in sand, Ice in hail, and anyone hidden
-- underground or underwater.
function M.weatherImmune(b, kind)
  local semi = b.semi == "UNDERGROUND" or b.semi == "UNDERWATER"
  local function is(t) return b.type1 == t or b.type2 == t end
  if kind == "SAND" then
    return is(Types.ID.ROCK) or is(Types.ID.STEEL) or is(Types.ID.GROUND)
      or b.ability == "SAND_VEIL" or semi
  end
  if kind == "HAIL" then return is(Types.ID.ICE) or semi end
  return true
end

-- pokefirered/src/battle_main.c:3399 GetWhoStrikesFirst's speed (engine
-- speed_of, engine.lua:203): Swift Swim / Chlorophyll x2 in their weather, the
-- Speed stage, badge 3 x110/100 floored (the battler's own trainer's, which only
-- side a carries against the computer -- Turn.BADGE_MODES; engine.lua:221 --
-- and not in a Frontier fight: the battler's `noSpeedBadge`, Turn.create
-- `rules.boosts.speed = false`, pokeemerald battle_main.c:4640), Macho Brace
-- halves, paralysis quarters, and Quick Claw makes it the maximum
-- when this turn's random number falls under 0xFFFF * param / 100.  `weather` is
-- already Cloud-Nine-filtered; `quickClawNumber` is the turn's roll(0, 65535), or
-- nil when none was drawn.  Escape odds read the raw stat, not this (Turn.lua's
-- run: pret TryRunFromBattle reads gBattleMons[].speed).
local HOLD_MACHO_BRACE, HOLD_QUICK_CLAW = 24, 26
M.QUICK_CLAW_SPEED = 0xFFFFFFFF

function M.speed(b, weather, quickClawNumber)
  if not b then return 0 end
  local spe = int(b.stats and b.stats.spe, 1)
  local mul = 1
  if (b.ability == "SWIFT_SWIM" and weather == "RAIN") or (b.ability == "CHLOROPHYLL" and weather == "SUN") then
    mul = 2
  end
  spe = Damage.applyStage(spe * mul, b.stages and b.stages.spe)
  if Damage.hasBadge(b, 3) and not b.noSpeedBadge then spe = floor(spe * 110 / 100) end
  local mon = b.mon or {}
  local he = (int(mon.heldItem, 0) ~= 0) and int(mon.holdEffect, 0) or 0
  local param = int(mon.holdParam, 0)
  if he == HOLD_MACHO_BRACE then spe = floor(spe / 2) end
  if mon.status == "PAR" then spe = floor(spe / 4) end
  if he == HOLD_QUICK_CLAW and quickClawNumber ~= nil
      and quickClawNumber < floor(0xFFFF * param / 100) then
    spe = M.QUICK_CLAW_SPEED
  end
  return spe
end

-- The turn-order policy (sheet doc §6): rows { pri, spe, order } sorted by
-- priority, then speed, then `order`; every group tied on both priority and
-- speed spends ONE rng:roll(0, 255), and a value >= tieRoll reverses the group.
-- A group of one draws nothing.  Sorts in place and returns the rows.
function M.sortRows(rows, rng, tieRoll)
  if #rows <= 1 then return rows end
  table.sort(rows, function(x, y)
    if x.pri ~= y.pri then return x.pri > y.pri end
    if x.spe ~= y.spe then return x.spe > y.spe end
    return x.order < y.order
  end)
  local i = 1
  while i <= #rows do
    local j = i
    while j < #rows and rows[j + 1].pri == rows[i].pri and rows[j + 1].spe == rows[i].spe do j = j + 1 end
    if j > i and rng:roll(0, 255) >= (tieRoll or 128) then
      for lo = i, i + floor((j - i) / 2) do
        local hi = j - (lo - i)
        rows[lo], rows[hi] = rows[hi], rows[lo]
      end
    end
    i = j + 1
  end
  return rows
end

-- One side's conditions, fresh.
function M.newSide()
  return {
    reflectTurns = 0, lightScreenTurns = 0, mistTurns = 0, safeguardTurns = 0,
    spikes = 0,
    wish = {},          -- { { turns, wisher (name), slot } }
    futureSight = {},   -- { { turns, damage, moveNum, move, attackerSlot, targetSlot, doom } }
    followMe = nil,     -- the battler drawing attacks this turn
  }
end

-- pokefirered/src/battle_script_commands.c:793 sTerrainToType (Camouflage) and
-- :741 sNaturePowerMoves / :9226 sSecretPowerEffects, keyed by BATTLE_TERRAIN_*.
M.TERRAIN_TYPE = {
  [0] = Types.ID.GRASS, [1] = Types.ID.GRASS, [2] = Types.ID.GROUND, [3] = Types.ID.WATER,
  [4] = Types.ID.WATER, [5] = Types.ID.WATER, [6] = Types.ID.ROCK, [7] = Types.ID.ROCK,
  [8] = Types.ID.NORMAL, [9] = Types.ID.NORMAL,
}
M.NATURE_POWER_MOVE = {
  [0] = 78, [1] = 75, [2] = 89, [3] = 56, [4] = 57, [5] = 61, [6] = 157, [7] = 247, [8] = 129, [9] = 129,
}
M.SECRET_POWER_EFFECT = {
  [0] = "POISON", [1] = "SLEEP", [2] = "ACC_MINUS_1", [3] = "DEF_MINUS_1",
  [4] = "ATK_MINUS_1", [5] = "SPD_MINUS_1", [6] = "CONFUSION", [7] = "FLINCH",
  [8] = "PARALYSIS", [9] = "PARALYSIS",
}
M.DEFAULT_TERRAIN = 8

return M
