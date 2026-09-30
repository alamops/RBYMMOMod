-- Gen 3 items: hold effects (what a held item does in battle) and the bag
-- catalog (what a player may use from the bag mid-fight).
--
-- Held items port engine src/core/game3/battle/held_items.lua (pret
-- battle_util.c ItemBattleEffects: ITEMEFFECT_NORMAL :2557, ITEMEFFECT_MOVE_END
-- :2851, ITEMEFFECT_KINGSROCK_SHELLBELL :2995, ITEMEFFECT_ON_SWITCH_IN :2532,
-- Focus Band battle_script_commands.c:1596).  The mapping item -> hold effect is
-- ROM data and rides on the sheet (`holdEffect`, `holdEffectParam`); the enum is
-- pret include/constants/hold_effects.h and is written out here.
--
-- The bag catalog is the in-battle item set of docs/plans/gen3-battle-sheet.md §4,
-- keyed by pret item ids with the public in-battle amounts -- the same
-- hand-authored policy BattleSim2/Effects.itemEffect follows.  The engine applies
-- a bag item through the ROM's gItemEffectTable bytes; the hub holds no ROM, so
-- the catalog states each item's class instead, and Wire refuses anything else.
--
-- Nothing here raises; no love, no engine modules, no mod facade.

local need = ...
local Status = need("BattleSim3/Status")

local M = {}

local floor, max, min = math.floor, math.max, math.min

-- pokefirered/include/constants/hold_effects.h
M.HOLD = {
  RESTORE_HP = 1, CURE_PAR = 2, CURE_SLP = 3, CURE_PSN = 4, CURE_BRN = 5, CURE_FRZ = 6,
  RESTORE_PP = 7, CURE_CONFUSION = 8, CURE_STATUS = 9, CONFUSE_SPICY = 10, CONFUSE_DRY = 11,
  CONFUSE_SWEET = 12, CONFUSE_BITTER = 13, CONFUSE_SOUR = 14, ATTACK_UP = 15, DEFENSE_UP = 16,
  SPEED_UP = 17, SP_ATTACK_UP = 18, SP_DEFENSE_UP = 19, CRITICAL_UP = 20, RANDOM_STAT_UP = 21,
  EVASION_UP = 22, RESTORE_STATS = 23, MACHO_BRACE = 24, EXP_SHARE = 25, QUICK_CLAW = 26,
  FRIENDSHIP_UP = 27, CURE_ATTRACT = 28, CHOICE_BAND = 29, FLINCH = 30, BUG_POWER = 31,
  DOUBLE_PRIZE = 32, REPEL = 33, SOUL_DEW = 34, DEEP_SEA_TOOTH = 35, DEEP_SEA_SCALE = 36,
  CAN_ALWAYS_RUN = 37, PREVENT_EVOLVE = 38, FOCUS_BAND = 39, LUCKY_EGG = 40, SCOPE_LENS = 41,
  STEEL_POWER = 42, LEFTOVERS = 43, DRAGON_SCALE = 44, LIGHT_BALL = 45, GROUND_POWER = 46,
  ROCK_POWER = 47, GRASS_POWER = 48, DARK_POWER = 49, FIGHTING_POWER = 50, ELECTRIC_POWER = 51,
  WATER_POWER = 52, FLYING_POWER = 53, POISON_POWER = 54, ICE_POWER = 55, GHOST_POWER = 56,
  PSYCHIC_POWER = 57, FIRE_POWER = 58, DRAGON_POWER = 59, NORMAL_POWER = 60, UP_GRADE = 61,
  SHELL_BELL = 62, LUCKY_PUNCH = 63, METAL_POWDER = 64, THICK_CLUB = 65, STICK = 66,
}
local H = M.HOLD
M.HOLD_MAX = 66

-- pret ITEM_* ids the battle code branches on.
M.ITEM_MAIL_FIRST, M.ITEM_MAIL_LAST = 121, 132
M.ITEM_ENIGMA_BERRY = 175

-- Stat order of the pinch berries (HOLD_EFFECT_ATTACK_UP .. SP_DEFENSE_UP) and
-- of the Starf/Salac random raise (held_items.lua STAT_ORDER).
local STAT_ORDER = { "atk", "def", "spe", "spa", "spd" }
local STAT_LABEL = {
  atk = "ATTACK", def = "DEFENSE", spe = "SPEED", spa = "SP. ATK", spd = "SP. DEF",
  acc = "accuracy", eva = "evasiveness",
}
M.STAT_LABEL = STAT_LABEL

local function int(value, fallback)
  local n = tonumber(value)
  if not n or n ~= n then return fallback end
  return floor(n)
end

function M.isMail(id)
  id = int(id, 0)
  return id >= M.ITEM_MAIL_FIRST and id <= M.ITEM_MAIL_LAST
end

-- The effective hold effect of a battler: nothing once Knock Off has taken it.
function M.of(b)
  if not b or not b.mon then return 0, 0, 0 end
  local item = int(b.mon.heldItem, 0)
  if item == 0 then return 0, 0, 0 end
  return int(b.mon.holdEffect, 0), int(b.mon.holdParam, 0), item
end

function M.has(b, he)
  return (M.of(b)) == he
end

-- ------------------------------------------------------------------
-- confusion-berry flavour (derived from the nature, see the sheet doc §5.4)
-- ------------------------------------------------------------------

-- Flavour f (0 Spicy, 1 Dry, 2 Sweet, 3 Bitter, 4 Sour) and the nature stat it
-- tracks, in the nature order Atk 0, Def 1, Spe 2, SpA 3, SpD 4.
local FLAVOR_STAT = { [0] = 0, [1] = 3, [2] = 2, [3] = 4, [4] = 1 }

-- +1 likes, -1 dislikes, 0 neutral -- pret gPokeblockFlavorCompatibilityTable
-- (pokemon.c:1398), which is exactly this rule over the nature table.
function M.flavorRelation(nature, flavor)
  local n = int(nature, 0) % 25
  local up, down = floor(n / 5), n % 5
  if up == down then return 0 end
  local stat = FLAVOR_STAT[int(flavor, 0)]
  if stat == up then return 1 end
  if stat == down then return -1 end
  return 0
end

-- ------------------------------------------------------------------
-- consuming / swapping (battle_script_commands.c:5642 Cmd_removeitem)
-- ------------------------------------------------------------------

-- The mon's held item after a change, stated on a `held` event so every client
-- can write it back.
local function heldEvent(B, b, actedItem, text)
  B:emit("held", {
    slot = b.slot, side = b.side, mon = b.partyIndex - 1, amount = actedItem,
    holding = int(b.mon.knockedOff, nil) or int(b.mon.heldItem, 0), text = text,
  })
end
M.heldEvent = heldEvent

function M.consume(B, b)
  local item = int(b.mon.heldItem, 0)
  if item == 0 then return end
  local side = B:sideState(b.side)
  -- Recycle brings back the last item this SIDE used (pret gLastUsedItem per
  -- battler, engine side.expUsedHeldItem); the hold effect rides with it.
  local used = { item = item, effect = int(b.mon.holdEffect, 0), param = int(b.mon.holdParam, 0),
                 name = b.mon.itemName }
  b.usedHeldItem = used
  side.usedHeldItem = used
  b.mon.heldItem, b.mon.holdEffect, b.mon.holdParam, b.mon.itemName = 0, 0, 0, nil
end

function M.give(b, row)
  if not row then
    b.mon.heldItem, b.mon.holdEffect, b.mon.holdParam, b.mon.itemName = 0, 0, 0, nil
    return
  end
  b.mon.heldItem = int(row.item, 0)
  b.mon.holdEffect = int(row.effect, 0)
  b.mon.holdParam = int(row.param, 0)
  b.mon.itemName = row.name
end

function M.rowOf(b)
  local item = int(b.mon.heldItem, 0)
  if item == 0 then return nil end
  return { item = item, effect = int(b.mon.holdEffect, 0), param = int(b.mon.holdParam, 0),
           name = b.mon.itemName }
end

local function label(B, b)
  return B:itemLabel(b)
end

-- ------------------------------------------------------------------
-- the individual triggers
-- ------------------------------------------------------------------

local function statUp(B, b, stat, delta)
  local item = int(b.mon.heldItem, 0)
  local lbl = label(B, b)
  b.stages[stat] = min(6, b.stages[stat] + delta)
  local verb = delta >= 2 and " sharply rose!" or " rose!"
  local text = "Using " .. lbl .. ", the " .. STAT_LABEL[stat] .. " of " .. B:nameOf(b) .. verb
  M.consume(B, b)
  heldEvent(B, b, item, lbl)
  B:emit("stat", { slot = b.slot, side = b.side, stat = stat, stage = b.stages[stat],
                   delta = delta, text = text })
  B:say(text)
end

-- data/battle_scripts_1.s:4216
local CURE_TEXT = {
  [H.CURE_PAR] = "'s %s cured paralysis!", [H.CURE_PSN] = "'s %s cured poison!",
  [H.CURE_BRN] = "'s %s healed its burn!", [H.CURE_FRZ] = "'s %s defrosted it!",
  [H.CURE_SLP] = "'s %s woke it from its sleep!",
}

local function cureStatusItem(B, b, he)
  local s = Status.normalise(b.mon.status)
  local ok = (he == H.CURE_PAR and s == "PAR") or (he == H.CURE_PSN and (s == "PSN" or s == "TOX"))
    or (he == H.CURE_BRN and s == "BRN") or (he == H.CURE_FRZ and s == "FRZ")
    or (he == H.CURE_SLP and s == "SLP")
  if not ok then return false end
  local item, lbl = int(b.mon.heldItem, 0), label(B, b)
  if he == H.CURE_SLP then b.nightmare = nil end
  M.consume(B, b)
  heldEvent(B, b, item, lbl)
  B:cure(b, B:nameOf(b) .. CURE_TEXT[he]:format(lbl))
  return true
end

-- src/battle_util.c:2778 (Lum Berry)
local function lum(B, b, allowNormalized)
  local s = Status.normalise(b.mon.status)
  local confused = int(b.confusion, 0) > 0
  if not s and not confused then return false end
  local count, word = 0, nil
  if s then word = Status.WORD[s] or "status"; count = count + 1 end
  if s == "SLP" then b.nightmare = nil end
  if confused then word = "confusion"; count = count + 1 end
  local item, lbl = int(b.mon.heldItem, 0), label(B, b)
  M.consume(B, b)
  heldEvent(B, b, item, lbl)
  local text
  if allowNormalized and count > 1 then
    text = B:nameOf(b) .. "'s " .. lbl .. " normalized its status!"
  else
    text = B:nameOf(b) .. "'s " .. lbl .. " cured its " .. word .. " problem!"
  end
  -- data/battle_scripts_1.s:4287: one sentence for the whole cure.  With
  -- confusion as well, the status clears silently and the confusion line below
  -- says it (spelled as a branch: `confused and nil or text` is always text).
  if s then
    if confused then B:cure(b, nil) else B:cure(b, text) end
  end
  if confused then
    b.confusion = nil
    B:emit("status", { slot = b.slot, side = b.side, confused = 0, text = text })
    B:say(text)
  end
  return true
end

local function whiteHerb(B, b)
  local any = false
  for _, k in ipairs({ "atk", "def", "spe", "spa", "spd", "acc", "eva" }) do
    if b.stages[k] < 0 then b.stages[k] = 0; any = true end
  end
  if not any then return false end
  local item, lbl = int(b.mon.heldItem, 0), label(B, b)
  M.consume(B, b)
  heldEvent(B, b, item, lbl)
  B:say(B:nameOf(b) .. "'s " .. lbl .. " restored its status!")
  return true
end

local function mentalHerb(B, b)
  if not b.infatuatedWith then return false end
  b.infatuatedWith = nil
  local item, lbl = int(b.mon.heldItem, 0), label(B, b)
  M.consume(B, b)
  heldEvent(B, b, item, lbl)
  B:say(B:nameOf(b) .. "'s " .. lbl .. " cured its love problem!")
  return true
end

local function persim(B, b)
  if int(b.confusion, 0) <= 0 then return false end
  b.confusion = nil
  local item, lbl = int(b.mon.heldItem, 0), label(B, b)
  M.consume(B, b)
  heldEvent(B, b, item, lbl)
  local text = B:nameOf(b) .. "'s " .. lbl .. " snapped it out of confusion!"
  B:emit("status", { slot = b.slot, side = b.side, confused = 0, text = text })
  B:say(text)
  return true
end

-- Leppa Berry: the first move slot at 0 PP (held_items.lua leppa).
local function leppa(B, b, param)
  local slot
  for i = 1, #b.moves do
    local mv = b.moves[i]
    if mv and int(mv.pp, 0) == 0 then slot = i; break end
  end
  if not slot then return false end
  local mv = b.moves[slot]
  local base = int(mv.maxPp, param)
  local pp = min(base, param)
  local item, lbl = int(b.mon.heldItem, 0), label(B, b)
  M.consume(B, b)
  heldEvent(B, b, item, lbl)
  mv.pp = pp
  B:say(B:nameOf(b) .. "'s " .. lbl .. " restored " .. B:moveLabel(mv) .. "'s PP!")
  B:emitMovesOf(b)
  return true
end

local function healBerry(B, b, amount)
  local item, lbl = int(b.mon.heldItem, 0), label(B, b)
  B:say(B:nameOf(b) .. "'s " .. lbl .. " restored health!")
  B:heal(b, amount)
  return item, lbl
end

-- pokefirered/src/battle_util.c:2557 ITEMEFFECT_NORMAL.  `moveTurn` true is the
-- after-action pass (Leftovers only ticks at the end of the turn).
function M.normal(B, b, moveTurn)
  if not b or int(b.mon.hp, 0) <= 0 then return false end
  local he, param = M.of(b)
  if he == 0 then return false end
  local hp, maxHp = b.mon.hp, b.mon.maxHp
  if he == H.RESTORE_HP then
    if hp <= floor(maxHp / 2) then
      local amt = param
      if hp + param > maxHp then amt = maxHp - hp end
      local item, lbl = healBerry(B, b, amt)
      M.consume(B, b)
      heldEvent(B, b, item, lbl)
      return true
    end
  elseif he == H.RESTORE_PP then
    return leppa(B, b, param)
  elseif he == H.RESTORE_STATS then
    return whiteHerb(B, b)
  elseif he == H.LEFTOVERS then
    if hp < maxHp and not moveTurn then
      local amt = floor(maxHp / 16)
      if amt == 0 then amt = 1 end
      local item, lbl = int(b.mon.heldItem, 0), label(B, b)
      heldEvent(B, b, item, lbl)
      B:say(B:nameOf(b) .. "'s " .. lbl .. " restored its HP a little!")
      B:heal(b, amt)
      return true
    end
  elseif he >= H.CONFUSE_SPICY and he <= H.CONFUSE_SOUR then
    if hp <= floor(maxHp / 2) then
      local flavor = he - H.CONFUSE_SPICY
      local amt = floor(maxHp / max(1, param))
      if amt == 0 then amt = 1 end
      if hp + amt > maxHp then amt = maxHp - hp end
      local item, lbl = healBerry(B, b, amt)
      if M.flavorRelation(b.mon.nature, flavor) < 0 then
        -- src/battle_message.c:2282
        B:say("For " .. B:nameOf(b) .. ", the " .. lbl .. " was bad!")
        if b.ability ~= "OWN_TEMPO" and int(b.confusion, 0) <= 0 then
          b.confusion = B:roll(0, 3) + 2
          local text = B:nameOf(b) .. " became confused!"
          B:emit("status", { slot = b.slot, side = b.side, confused = 1, text = text })
          B:say(text)
        end
      end
      M.consume(B, b)
      heldEvent(B, b, item, lbl)
      return true
    end
  elseif he >= H.ATTACK_UP and he <= H.SP_DEFENSE_UP then
    local stat = STAT_ORDER[he - H.ATTACK_UP + 1]
    if hp <= floor(maxHp / max(1, param)) and b.stages[stat] < 6 then
      statUp(B, b, stat, 1)
      return true
    end
  elseif he == H.CRITICAL_UP then
    if hp <= floor(maxHp / max(1, param)) and not b.focusEnergy then
      b.focusEnergy = true
      local item, lbl = int(b.mon.heldItem, 0), label(B, b)
      M.consume(B, b)
      heldEvent(B, b, item, lbl)
      B:say(B:nameOf(b) .. " used " .. lbl .. " to get pumped!")
      return true
    end
  elseif he == H.RANDOM_STAT_UP then
    if hp <= floor(maxHp / max(1, param)) then
      local any = false
      for _, s in ipairs(STAT_ORDER) do
        if b.stages[s] < 6 then any = true end
      end
      if any then
        local stat
        repeat
          stat = STAT_ORDER[B:roll(0, 4) + 1]
        until b.stages[stat] < 6
        statUp(B, b, stat, 2)
        return true
      end
    end
  elseif he >= H.CURE_PAR and he <= H.CURE_FRZ then
    return cureStatusItem(B, b, he)
  elseif he == H.CURE_CONFUSION then
    return persim(B, b)
  elseif he == H.CURE_STATUS then
    return lum(B, b, true)
  elseif he == H.CURE_ATTRACT then
    return mentalHerb(B, b)
  end
  return false
end

-- pokefirered/src/battle_util.c:2851 ITEMEFFECT_MOVE_END (every standing battler)
function M.moveEnd(B)
  local any = false
  for _, b in ipairs(B:active()) do
    local he = M.of(b)
    local did = false
    if he >= H.CURE_PAR and he <= H.CURE_FRZ then
      did = cureStatusItem(B, b, he)
    elseif he == H.CURE_CONFUSION then
      did = persim(B, b)
    elseif he == H.CURE_ATTRACT then
      did = mentalHerb(B, b)
    elseif he == H.CURE_STATUS then
      did = lum(B, b, false)
    elseif he == H.RESTORE_STATS then
      did = whiteHerb(B, b)
    end
    any = any or did
  end
  return any
end

-- pokefirered/src/battle_util.c:2532 ITEMEFFECT_ON_SWITCH_IN (Amulet Coin's
-- money multiplier has no meaning on a mediated field; White Herb does).
function M.onSwitchIn(B, b)
  if not b then return false end
  local he = M.of(b)
  if he == H.RESTORE_STATS then return whiteHerb(B, b) end
  return false
end

-- pokefirered/src/battle_script_commands.c:1596.  Draws only for a holder.
function M.rollFocusBand(B, target)
  local he, param = M.of(target)
  if he == H.FOCUS_BAND and B:roll(0, 99) < param then
    target.focusBanded = true
    return true
  end
  return false
end

function M.focusBandMessage(B, target)
  local lbl = label(B, target)
  heldEvent(B, target, int(target.mon.heldItem, 0), lbl)
  B:say(B:nameOf(target) .. " hung on using its " .. lbl .. "!")
end

-- ------------------------------------------------------------------
-- the bag (docs/plans/gen3-battle-sheet.md §4)
-- ------------------------------------------------------------------

local ALL = { SLP = true, PSN = true, BRN = true, FRZ = true, PAR = true, TOX = true }

M.BAG = {
  -- balls
  [1] = { ball = true }, [2] = { ball = true }, [3] = { ball = true }, [4] = { ball = true },
  [6] = { ball = true }, [7] = { ball = true }, [8] = { ball = true }, [9] = { ball = true },
  [10] = { ball = true }, [11] = { ball = true }, [12] = { ball = true },
  -- heals
  [13] = { heal = 20 }, [22] = { heal = 50 }, [21] = { heal = 200 }, [20] = { healFull = true },
  [26] = { heal = 50 }, [27] = { heal = 60 }, [28] = { heal = 80 }, [29] = { heal = 100 },
  [30] = { heal = 50 }, [31] = { heal = 200 }, [44] = { heal = 20 }, [139] = { heal = 10 },
  [142] = { heal = 30 },
  [19] = { healFull = true, cure = ALL, confusion = true },
  -- cures
  [14] = { cure = { PSN = true, TOX = true } }, [15] = { cure = { BRN = true } },
  [16] = { cure = { FRZ = true } }, [17] = { cure = { SLP = true } }, [18] = { cure = { PAR = true } },
  [23] = { cure = ALL, confusion = true }, [32] = { cure = ALL, confusion = true },
  [38] = { cure = ALL, confusion = true },
  [133] = { cure = { PAR = true } }, [134] = { cure = { SLP = true } },
  [135] = { cure = { PSN = true, TOX = true } }, [136] = { cure = { BRN = true } },
  [137] = { cure = { FRZ = true } }, [140] = { confusion = true },
  [141] = { cure = ALL, confusion = true },
  [39] = { cure = { SLP = true } }, [40] = { confusion = true }, [41] = { attract = true },
  -- revives (fainted only)
  [24] = { revive = "half" }, [25] = { revive = "full" }, [33] = { revive = "full" },
  -- PP
  [34] = { pp = 10, needsMove = true }, [35] = { ppFull = true, needsMove = true },
  [36] = { ppAll = 10 }, [37] = { ppAllFull = true }, [138] = { pp = 10, needsMove = true },
  -- battle stat items (+1 in Gen 3), active mon only
  [73] = { mist = true, activeOnly = true }, [74] = { focusEnergy = true, activeOnly = true },
  [75] = { stage = "atk", activeOnly = true }, [76] = { stage = "def", activeOnly = true },
  [77] = { stage = "spe", activeOnly = true }, [78] = { stage = "acc", activeOnly = true },
  [79] = { stage = "spa", activeOnly = true },
  -- escape
  [80] = { escape = true }, [81] = { escape = true },
  -- FRLG Poke Flute (key item)
  [350] = { flute = true, noConsume = true },
}

-- Numeric id from a number or a numeric string (the choice / Wire form).
function M.idOf(item)
  local n = tonumber(item)
  if not n or n ~= n then return nil end
  n = floor(n)
  if n < 1 or n > 999 then return nil end
  return n
end

function M.bagEffect(item)
  local id = M.idOf(item)
  return id and M.BAG[id] or nil
end

-- Items that cannot do anything for a fainted mon (everything but a revive).
function M.failsOnFainted(effect)
  if type(effect) ~= "table" then return false end
  if effect.revive then return false end
  return not not (effect.heal or effect.healFull or effect.cure or effect.confusion
    or effect.attract or effect.pp or effect.ppFull or effect.ppAll or effect.ppAllFull)
end

function M.needsParty(effect)
  if type(effect) ~= "table" then return false end
  return not not (effect.heal or effect.healFull or effect.cure or effect.confusion
    or effect.attract or effect.revive or effect.pp or effect.ppFull or effect.ppAll
    or effect.ppAllFull)
end

return M
