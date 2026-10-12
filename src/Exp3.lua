-- Gen 3 experience: the client half of a refereed knockout on FireRed,
-- LeafGreen and Emerald.  The Gen 3 sibling of src/Exp2.lua.
--
-- The hub holds no species table (the legal floor), so a mediated `exp` event
-- states facts and nothing else -- which monster fell, at what level, and which
-- of this player's monsters fought it (src/BattleSim3/Turn.lua _awardExp).
-- Pricing those facts is the owner's job, on the owner's save, with the
-- owner's cart's formula.  On Gen 3 that formula is pret Cmd_getexp
-- (pokefirered/src/battle_script_commands.c:3113), which the engine carries as
-- src/core/game3/battle/experience.lua `Experience.awardFoe` -- a function of
-- a live battle state a mediated fight does not have and must not fake.  So
-- this file is the orchestration and the engine keeps the arithmetic:
-- `Experience.apply` levels the mon (stats, HP, the `pokemon.level_up` event),
-- `Pokemon.gainEVs` pays the effort values (Pokerus and Macho Brace doubled,
-- 255 / 510 caps), `Pokemon.adjustFriendship` the level-up friendship.
--
-- What Gen 3 does, and therefore what this file gets right rather than
-- approximates (Cmd_getexp, case 0 and 1):
--
--   * calculatedExp = floor(expYield * foeLevel / 7).
--   * viaSentIn counts the *living* party members that fought the foe;
--     viaExpShare the living ones holding HOLD_EFFECT_EXP_SHARE.
--   * with any Exp. Share holder the pool halves: exp = floor(half / viaSentIn),
--     shareExp = floor(half / viaExpShare), each floored up to 1; without one
--     exp = floor(calculated / viaSentIn), floored up to 1.
--   * each recipient (fought, or holds the Share -- a holder that fought gets
--     both) takes exp + shareExp, then x1.5 (floored) for a Lucky Egg, for a
--     trainer's mon and for a traded mon, in that order.
--   * every recipient gains EVs; a recipient at level 100 gains nothing.
--   * each recipient's amount is offered to the `exp.gain` hook first, with
--     the ctx the engine's own award raises it with, so a mod that retunes
--     experience retunes a mediated fight too.
--
-- Unlike Gen 2's award this is one sum per monster, not two passes, so a
-- screen hands over a whole knockout at once (MediatedBattle banks the `exp`
-- events of one faint and prices them together).
--
-- Nothing here reads the wire and nothing draws.  Every engine reach goes
-- through Gen3.engine (nil off Gen 3), and a missing module is a reason
-- returned, never a raise.

local need = ...
local Gen3 = need("Gen3")

local M = {}

local floor, max, min = math.floor, math.max, math.min

M.MAX_LEVEL = 100
-- pret include/constants/hold_effects.h
M.HOLD_EFFECT_EXP_SHARE = 25
M.HOLD_EFFECT_LUCKY_EGG = 40

local SPECIES_EGG = 412

local function int(value, fallback)
  local n = tonumber(value)
  if not n or n ~= n then return fallback end
  return floor(n)
end

local function try(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, value = pcall(fn, ...)
  if ok then return value end
  return nil
end

local function engine(name) return Gen3.engine(name) end

local function Pokemon() return engine("src.core.game3.pokemon") end
local function Experience() return engine("src.core.game3.battle.experience") end

-- Is the Gen 3 award path usable at all?  Callers warn once and skip.
function M.available()
  local E, P = Experience(), Pokemon()
  return (E and type(E.apply) == "function" and P and type(P.gainEVs) == "function")
    and true or false
end

-- ------------------------------------------------------------------
-- the formula (pure; the numbers the suite pins)
-- ------------------------------------------------------------------

function M.calculated(expYield, foeLevel)
  return floor(max(0, int(expYield, 0)) * max(1, int(foeLevel, 1)) / 7)
end

-- (exp, shareExp) for one knockout.
function M.split(calculated, viaSentIn, viaExpShare)
  calculated = max(0, int(calculated, 0))
  viaSentIn = max(0, int(viaSentIn, 0))
  viaExpShare = max(0, int(viaExpShare, 0))
  local exp, shareExp
  if viaExpShare > 0 then
    local half = floor(calculated / 2)
    exp = (viaSentIn > 0) and floor(half / viaSentIn) or 0
    if exp == 0 then exp = 1 end
    shareExp = floor(half / viaExpShare)
    if shareExp == 0 then shareExp = 1 end
  else
    exp = (viaSentIn > 0) and floor(calculated / viaSentIn) or 0
    if exp == 0 then exp = 1 end
    shareExp = 0
  end
  return exp, shareExp
end

-- One recipient's amount: its share of the pool, then the three x1.5s.
function M.amount(exp, shareExp, opts)
  opts = opts or {}
  local amount = (opts.sentIn and exp or 0) + (opts.holder and shareExp or 0)
  if opts.luckyEgg then amount = floor(amount * 150 / 100) end
  if opts.trainer then amount = floor(amount * 150 / 100) end
  if opts.traded then amount = floor(amount * 150 / 100) end
  return amount
end

-- ------------------------------------------------------------------
-- the party facts
-- ------------------------------------------------------------------

local function speciesOf(mon)
  return type(mon) == "table" and tonumber(mon.species or mon.speciesId) or nil
end

local function alive(mon)
  if type(mon) ~= "table" or mon.isEgg then return false end
  local sp = speciesOf(mon)
  if not sp or sp == 0 or sp == SPECIES_EGG then return false end
  return (tonumber(mon.hp) or 0) > 0
end
M.alive = alive

-- The held item's hold effect: the cart's item row (ItemsData.info), the
-- engine's own resolver when the adapter has no row.
function M.holdEffectOf(mon)
  if type(mon) ~= "table" then return 0 end
  local id = mon.heldItem
  if id == nil or id == 0 then id = mon.item end
  if id == nil or id == 0 then return 0 end
  local info = Gen3.itemInfo(id)
  local he = info and tonumber(info.holdEffect)
  if he then return floor(he) end
  local HeldItems = engine("src.core.game3.battle.held_items")
  return int(HeldItems and try(HeldItems.effectOf, id), 0)
end

-- Living, non-egg party indices holding the Exp. Share, in party order.
function M.holders(party)
  local out = {}
  if type(party) ~= "table" then return out end
  for index = 1, #party do
    local mon = party[index]
    if alive(mon) and M.holdEffectOf(mon) == M.HOLD_EFFECT_EXP_SHARE then
      out[#out + 1] = index
    end
  end
  return out
end

-- pret IsTradedMon: the OT id / name against the player's.
function M.traded(mon)
  local P = Pokemon()
  if P and type(P.isTradedMon) == "function" then
    return try(P.isTradedMon, mon) == true
  end
  local player = Gen3.player()
  if not (player and type(mon) == "table" and mon.otId ~= nil) then return false end
  return tonumber(mon.otId) ~= tonumber(player.trainerId)
end

function M.expYield(species)
  local info = Gen3.speciesInfo(species)
  local y = info and tonumber(info.expYield)
  if y then return floor(y) end
  local E = Experience()
  return int(E and try(E.expYield, species), 0)
end

-- ------------------------------------------------------------------
-- one knockout
-- ------------------------------------------------------------------

-- The engine's mod runtime, for the `exp.gain` hook.  Reached through the
-- same guarded lazy require every Gen 3 arm uses (SoloBattle's
-- `trainer.party` does the same), so a Gen 1 / Gen 2 boot never loads it here.
local function Runtime() return engine("src.mods.Runtime") end

-- One recipient's amount through `exp.gain`, the way the engine's own award
-- raises it (src/core/game3/battle/experience.lua awardFoe, pret
-- battle_script_commands.c:3230): the same ctx keys, the vanilla amount as the
-- chain's innermost link, the answer floored and never negative.  Only when a
-- hook is actually wrapped -- `wantsHook` is the hot-path guard, so an
-- unhooked award allocates no ctx.  A mediated fight has no engine battle
-- state and no loser battler: `battle` is whatever the caller handed in (the
-- screen, as MediatedBattle's `pokemon.caught` payload does), `loser` is nil.
local function gainHooked()
  local R = Runtime()
  if not (R and type(R.wantsHook) == "function" and type(R.call) == "function") then
    return nil
  end
  local ok, wants = pcall(R.wantsHook, "exp.gain")
  if ok and wants then return R end
  return nil
end

local function hookedAmount(R, vanilla, ctx)
  local ok, amount = pcall(R.call, "exp.gain", function() return vanilla end, ctx)
  if not ok then return vanilla end
  return max(0, floor(tonumber(amount) or 0))
end

-- `ko`:
--   species    the fallen mon's internal species number (referee fact)
--   level      its level                                (referee fact)
--   isTrainer  a trainer's mon (x1.5)
--   sentIn     { [partyIndex] = true } -- this player's mons that fought it
--   party      the party they live in (the session party)
--   session    for the level-up friendship's map section (optional)
--   battle     what `exp.gain`'s ctx.battle names (optional; the screen)
--
-- `opts` (optional):
--   alive(partyIndex, mon)  whether that party member is standing *in this
--       fight*.  The session party's HP is the one the fight started with --
--       a mediated screen never writes HP home mid-fight -- so a caller that
--       knows better (the referee's roster) answers here: a fainted Exp. Share
--       holder is not paid, a mon revived mid-fight is.  nil (or an answer of
--       nil) falls back to the mon's own HP, which is right for every caller
--       that writes HP back as it goes.  Eggs are never alive either way.
--
-- Returns a list, in party order, of
--   { index, mon, amount, boosted, gained, levels = { N, ... },
--     fromLevel, toLevel, fromMaxHp }
-- or nil plus a reason.  **The mons are mutated in place** -- this is where
-- the award persists, because the session party is the only place it can.
function M.award(ko, opts)
  if type(ko) ~= "table" then return nil, "no knockout to price" end
  local override = type(opts) == "table" and type(opts.alive) == "function"
    and opts.alive or nil
  local function standing(i, mon)
    if not override then return alive(mon) end
    -- The egg / species half of `alive` still stands; only the HP question
    -- is the caller's.
    if type(mon) ~= "table" or mon.isEgg then return false end
    local sp = speciesOf(mon)
    if not sp or sp == 0 or sp == SPECIES_EGG then return false end
    local ok, answer = pcall(override, i, mon)
    if ok and answer ~= nil then return answer and true or false end
    return alive(mon)
  end
  local E, P = Experience(), Pokemon()
  if not (E and P and type(E.apply) == "function") then
    return nil, "the engine's Gen 3 experience modules are unavailable"
  end
  local party = ko.party
  if type(party) ~= "table" then return nil, "no party to pay" end
  local foe = int(ko.species, nil)
  if not foe or foe < 1 then return nil, "the fallen monster's species is unknown" end
  local foeLevel = max(1, int(ko.level, 1))
  local sentIn = type(ko.sentIn) == "table" and ko.sentIn or {}

  local viaSentIn, viaExpShare = 0, 0
  local holder, up = {}, {}
  for i = 1, min(6, #party) do
    local mon = party[i]
    if standing(i, mon) then
      up[i] = true
      if sentIn[i] then viaSentIn = viaSentIn + 1 end
      if M.holdEffectOf(mon) == M.HOLD_EFFECT_EXP_SHARE then
        holder[i] = true
        viaExpShare = viaExpShare + 1
      end
    end
  end
  local exp, shareExp = M.split(M.calculated(M.expYield(foe), foeLevel), viaSentIn, viaExpShare)

  local mapSec = try(P.currentMapSec, ko.session or Gen3.session())
  local isTrainer = ko.isTrainer and true or false
  local out = {}
  for i = 1, min(6, #party) do
    local mon = party[i]
    if up[i] and (sentIn[i] or holder[i]) and (int(mon.level, 1) < M.MAX_LEVEL) then
      local traded = M.traded(mon)
      local luckyEgg = M.holdEffectOf(mon) == M.HOLD_EFFECT_LUCKY_EGG
      local amount = M.amount(exp, shareExp, {
        sentIn = sentIn[i], holder = holder[i],
        luckyEgg = luckyEgg, trainer = isTrainer, traded = traded,
      })
      local R = gainHooked()
      if R then
        local G3 = engine("src.mods.Gen3Compat")
        amount = hookedAmount(R, amount, {
          defeatedDef = G3 and try(G3.speciesView, foe) or nil,
          level = foeLevel, isTrainer = isTrainer,
          participants = viaSentIn, traded = traded, luckyEgg = luckyEgg,
          expShare = holder[i] and true or false, mon = mon, index = i,
          battle = ko.battle, loser = nil,
        })
      end
      local fromMaxHp = int(mon.maxHp, nil)
      -- pokefirered/src/battle_script_commands.c:3271: EVs first, then the
      -- points, so a level crossed on this kill counts the effort just earned.
      pcall(P.gainEVs, mon, foe)
      local ok, result = pcall(E.apply, mon, amount)
      if ok and type(result) == "table" then
        -- pokefirered/src/battle_script_commands.c:3314
        local grow = tonumber(P.FRIENDSHIP_EVENT_GROW_LEVEL) or 0
        for _ = 1, #(result.levels or {}) do
          pcall(P.adjustFriendship, mon, grow, { mapSec = mapSec })
        end
        out[#out + 1] = {
          index = i,
          mon = mon,
          amount = amount,
          boosted = traded,
          gained = tonumber(result.gained) or 0,
          levels = result.levels or {},
          fromLevel = result.fromLevel,
          toLevel = result.toLevel,
          fromMaxHp = fromMaxHp,
        }
      end
    end
  end
  return out
end

-- ------------------------------------------------------------------
-- display
-- ------------------------------------------------------------------

-- Moves this mon's species learns at exactly `level` (numeric move ids).
function M.movesLearnedAt(mon, level)
  local P = Pokemon()
  local sp = speciesOf(mon)
  if not (P and sp) then return {} end
  local got = try(P.movesLearnedAt, sp, level)
  return type(got) == "table" and got or {}
end

-- How far along its level a mon is, 0..1, for the plate's exp strip.  nil
-- when it cannot be computed (the plate draws no strip for nil).
function M.fraction(mon)
  if type(mon) ~= "table" then return nil end
  local level = int(mon.level, 0)
  if level < 1 then return nil end
  if level >= M.MAX_LEVEL then return 1 end
  local SummaryData = engine("src.core.game3.summary_data")
  local E = Experience()
  local growth = E and try(E.growthRate, mon)
  if not (SummaryData and growth) then return nil end
  local here = tonumber(try(SummaryData.expForLevel, growth, level))
  local nextLv = tonumber(try(SummaryData.expForLevel, growth, level + 1))
  if not (here and nextLv) or nextLv <= here then return nil end
  local have = tonumber(mon.exp) or here
  return min(1, max(0, (have - here) / (nextLv - here)))
end

-- A line of the cart's text as the mod's boxes print it.  The engine's text
-- pack hands a battle string back with the message printer's own control
-- codes still in it -- `\p` (next page), `\l` (scroll a line), `\n` -- which
-- the cart's printer acts on and a mod box would print as two characters.
-- A page break becomes a blank line (MediatedBattle pages on it), the other
-- two a line break, and a trailing one nothing at all.
function M.cleanText(text)
  if type(text) ~= "string" then return text end
  text = text:gsub("\\[pl]%s*$", ""):gsub("\\p", "\n\n"):gsub("\\[ln]", "\n")
  return (text:gsub("%s+$", ""))
end

local function cart(id, fill)
  local text = Gen3.battleText(id, fill)
  if text == nil then return nil end
  text = M.cleanText(text)
  if text == "" then return nil end
  return text
end

-- The cart's own sentences (pret battle strings through the engine's text
-- pack), with a plain one for a build whose text pack is not there.
function M.gainedText(name, amount, boosted)
  name = tostring(name or "?")
  local boost = boosted and (cart("STRINGID_ABOOSTED") or "a boosted") or ""
  local text = cart("STRINGID_PKMNGAINEDEXP", {
    buff1 = name, buff2 = boost, buff3 = tostring(amount or 0),
  })
  if text then return text end
  return name .. " gained " .. (boosted and "a boosted\n" or "\n")
    .. tostring(amount or 0) .. " EXP. Points!"
end

function M.grewText(name, level)
  name = tostring(name or "?")
  return cart("STRINGID_PKMNGREWTOLV", { buff1 = name, buff2 = tostring(level) })
    or (name .. " grew to\nLV. " .. tostring(level) .. "!")
end

function M.learnedText(name, moveName)
  name = tostring(name or "?")
  moveName = tostring(moveName or "?")
  return cart("STRINGID_PKMNLEARNEDMOVE", { buff1 = name, buff2 = moveName })
    or (name .. " learned\n" .. moveName .. "!")
end

return M
