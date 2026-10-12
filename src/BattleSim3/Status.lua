-- Gen 3 major status: who can take which condition, and what each one costs.
--
-- Port of engine src/core/game3/battle/status.lua (`Status.tickChip`,
-- pokefirered/src/battle_util.c:805) and adapter.lua (`canApplyStatus`,
-- `rollSleepTurns`, `applyStatus`; battle_script_commands.c:2150 / 2356):
--
--   * sleep lasts roll(0,3)+2 = 2..5 turns; Early Bird counts it down twice
--     (the gate is the turn machine's -- the waking turn is a free turn in Gen 3)
--   * burn / poison chip max(1, floor(maxHp / 8)) at the end of the turn
--   * toxic chip max(1, floor(maxHp / 16)) * n, n = 1..15, counted per switch-in
--   * burn halves physical Attack (Damage.base), paralysis quarters Speed
--   * freeze thaws on roll(0,4) == 0, paralysis stops on roll(0,3) == 0
--
-- Status tokens are the wire's (SLP PSN BRN FRZ PAR TOX) end to end: the Gen 3
-- engine spells them that way internally too, so there is no second vocabulary.
--
-- Nothing here raises; no love, no engine modules, no mod facade.

local need = ...
local Types = need("BattleSim3/Types")

local M = {}

local floor, max, min = math.floor, math.max, math.min

M.TOKENS = { SLP = true, PSN = true, BRN = true, FRZ = true, PAR = true, TOX = true }

-- Legacy spellings a sheet may carry (BattleSim2's words, the engine's words).
M.ALIASES = {
  sleep = "SLP", poison = "PSN", burn = "BRN", freeze = "FRZ", paralysis = "PAR",
  toxic = "TOX", SLEEP = "SLP", POISON = "PSN", BURN = "BRN", FREEZE = "FRZ",
  PARALYSIS = "PAR", TOXIC = "TOX",
}

M.THAW_ROLL_MAX = 4        -- roll(0,4); thaw on 0
M.PARALYSIS_ROLL_MAX = 3   -- roll(0,3); stuck on 0
M.TOXIC_MAX = 15

local function int(value, fallback)
  local n = tonumber(value)
  if not n or n ~= n then return fallback end
  return floor(n)
end

function M.normalise(token)
  if token == nil or token == "" or token == 0 then return nil end
  if type(token) ~= "string" then return nil end
  if M.TOKENS[token] then return token end
  return M.ALIASES[token]
end

-- pokefirered/src/battle_script_commands.c:2356 (adapter rollSleepTurns)
function M.sleepTurns(rng)
  return (rng and rng:roll(0, 3) or 0) + 2
end

-- One sleep tick (pret battle_util.c:1268): returns the counter left and whether
-- the mon woke this turn.  Early Bird subtracts two.  A mon at 0 is awake.
function M.sleepTick(turns, earlyBird)
  local left = max(0, int(turns, 0))
  local toSub = earlyBird and 2 or 1
  if left < toSub then left = 0 else left = left - toSub end
  return left, left == 0
end

-- pokefirered/src/battle_util.c:805-850
-- Returns amount, newToxicCounter (nil for non-toxic).
function M.chip(status, maxHp, toxicCounter)
  status = M.normalise(status)
  local mhp = max(1, int(maxHp, 1))
  if status == "PSN" or status == "BRN" then
    local loss = floor(mhp / 8)
    if loss == 0 then loss = 1 end
    return loss, nil
  end
  if status == "TOX" then
    local loss = floor(mhp / 16)
    if loss == 0 then loss = 1 end
    local c = max(0, int(toxicCounter, 0))
    if c < M.TOXIC_MAX then c = c + 1 end
    return loss * c, c
  end
  return nil, nil
end

function M.paralysisSpeed(speed)
  return floor(max(0, int(speed, 0)) / 4)
end

-- What stops a condition from landing at all, given the facts the turn machine
-- knows.  Mirrors adapter `canApplyStatus` (battle_script_commands.c:2150).
--
-- ctx: { sun = bool (effective weather is SUN), uproar = bool (an uproar is on),
--        safeguard = bool (the victim's side), ignoreSafeguard = bool }
-- Returns ok, reason ("status" | "safeguard" | "type" | "ability" | "sun" | "uproar").
function M.canApply(b, status, ctx)
  ctx = ctx or {}
  status = M.normalise(status)
  if not b or not status then return false, "none" end
  if M.normalise(b.mon and b.mon.status) then return false, "status" end
  if ctx.safeguard and not ctx.ignoreSafeguard then return false, "safeguard" end
  local ab = b.ability
  local function isType(t) return b.type1 == t or b.type2 == t end
  if status == "PSN" or status == "TOX" then
    if isType(Types.ID.POISON) or isType(Types.ID.STEEL) then return false, "type" end
    if ab == "IMMUNITY" then return false, "ability" end
  elseif status == "BRN" then
    if isType(Types.ID.FIRE) then return false, "type" end
    if ab == "WATER_VEIL" then return false, "ability" end
  elseif status == "FRZ" then
    if isType(Types.ID.ICE) then return false, "type" end
    if ctx.sun then return false, "sun" end
    if ab == "MAGMA_ARMOR" then return false, "ability" end
  elseif status == "PAR" then
    if ab == "LIMBER" then return false, "ability" end
  elseif status == "SLP" then
    if ab ~= "SOUNDPROOF" and ctx.uproar then return false, "uproar" end
    if ab == "INSOMNIA" or ab == "VITAL_SPIRIT" then return false, "ability" end
  end
  return true
end

-- Sentence fragments the turn machine narrates with (our own words, not ROM text).
M.INFLICT_TEXT = {
  SLP = " fell asleep!", PSN = " was poisoned!", BRN = " was burned!",
  FRZ = " was frozen solid!", PAR = " is paralyzed! It may be unable to move!",
  TOX = " is badly poisoned!",
}
M.CHIP_TEXT = {
  PSN = " is hurt by poison!", TOX = " is hurt by poison!", BRN = " is hurt by its burn!",
}
M.WORD = {
  PSN = "poison", TOX = "poison", SLP = "sleep", PAR = "paralysis", BRN = "burn", FRZ = "ice",
}

return M
