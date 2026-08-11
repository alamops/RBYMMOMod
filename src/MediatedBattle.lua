-- The client half of a mediated 1v1: a screen that sends choices and draws
-- what it is told.
--
-- **Nothing in this file decides anything about the fight.**  That is the whole
-- point of it.  Until PROTOCOL 10 an MMO battle was the engine's own
-- `LinkBattle` running in lockstep inside both players' processes over
-- `SessionNet`, which meant the arithmetic of a fight lived on the same side of
-- the wire as the person who benefits from getting it wrong -- and it meant the
-- two copies had to agree about their content before they were allowed to
-- start, which is what `Sessions.canBattle` and the fingerprint were for.  The
-- intermediator (the Node hub, or a LAN host running `src/BattleSim/`) now owns
-- hit, crit, damage, status and the outcome, so this side is reduced to three
-- jobs:
--
--   1. upload what we are bringing -- `mmo.battle_party` (mons + optional
--      battle `bag` for PROTOCOL 15 proofs), and on the host
--      `mmo.battle_ruleset` -- before the fight opens;
--   2. put a choice on the wire when a turn opens;
--   3. apply the ordered `mmo.battle_event` stream to a screen.
--
-- Everything the sim needs about a monster therefore rides on (1), because
-- there is no move table and no type chart on either intermediator and there
-- must never be one: those are the player's own decoded ROM, and this repo may
-- not carry them (see the legal posture in CLAUDE.md).  A move brings its own
-- power and accuracy; the chart is uploaded for one match and thrown away with
-- it.
--
-- Because the fingerprint gate is gone, two players whose copies disagree can
-- now fight -- a Red against a Yellow, a data pack against vanilla.  What they
-- are agreeing on instead is *this upload*: the host's chart decides the
-- matchups and each side's own records decide its own moves.  That is a real
-- change in what a battle means and it is deliberate; the residual is that a
-- modified client can lie on the sheet it sends, which is the accepted v1
-- surface written down in src/Wire.lua's mediated-battle section.
--
-- The screen draws a classic Gen1 1v1 field: foe front pic + top-left HUD,
-- ally back pic + bottom HUD, message box, optional AnimPlayer. Co-op still
-- owns the four-slot renderer.

local need, mod = ...
local Config = need("Config")
local Wire = need("Wire")
local Effects = need("BattleSim/Effects")

local M = {}
M.__index = M

local floor, max, min = math.floor, math.max, math.min

-- ------- the engine, loaded once and never at file scope
--
-- Lazily and behind pcall, for the reason src/CoopBattle.lua loads its own
-- renderer that way: `modkit validate` loads this file headlessly with no love
-- and no data, and the mod's suite drives the whole exchange with no engine at
-- all.  A build that cannot draw still uploads, still sends choices and still
-- hears the outcome -- it simply has nothing to paint, which is a far better
-- failure than a battle that cannot start.
local engine, engineTried

local function loadEngine()
  if engineTried then return engine end
  engineTried = true
  local ok, Font = pcall(require, "src.render.Font")
  if not ok then
    mod.log:warn("the engine's font module is unavailable, so a mediated "
      .. "battle cannot be drawn; the fight still runs -- report this with "
      .. "the game version")
    engine = false
    return engine
  end
  local function grab(key, path)
    local good, value = pcall(require, path)
    if good then return value end
    return nil
  end
  engine = {
    Font = Font,
    HudTiles = grab("HudTiles", "src.render.HudTiles"),
    AnimPlayer = grab("AnimPlayer", "src.battle.AnimPlayer"),
    BattleState = grab("BattleState", "src.battle.BattleState"),
    Sprites = grab("Sprites", "src.pokemon.Sprites"),
  }
  return engine
end

-- Classic 1v1 anchors (AnimPlayer / BattleState pic windows).
-- Ally back pics draw at 2x on the GB (BattleState.BATTLE_SCALE_DEFAULT.back);
-- front pics stay 1x. MediatedBattle used to draw both at 1x, which left the
-- player mon looking like a postage stamp next to the foe.
local CLASSIC_PLAYER = { x = 8, y = 40 }
local CLASSIC_ENEMY = { x = 88, y = 0 }
local PLAYER_PIC_SCALE = 2
M.PLAYER_PIC_SCALE = PLAYER_PIC_SCALE
M.CLASSIC_PLAYER = CLASSIC_PLAYER
M.CLASSIC_ENEMY = CLASSIC_ENEMY

-- ------- snapshots
--
-- What this client claims it is bringing, in the shapes src/Wire.lua sanitises.
-- Both halves are built from `game.data` -- the player's own decoded copy --
-- and neither is stored anywhere past the match.

-- The widest neutral chart to offer when there is no type table to read.
--
-- A fallback rather than a default: a build with no `type_chart` has no
-- matchups to state, and a chart of nothing but neutral cells says exactly
-- that.  Sixteen is comfortably above Gen 1's fifteen types and comfortably
-- inside Config.BATTLE_TYPE_MAX, so a move naming any type this client could
-- have produced still finds a row -- and every row reads 100, which is the
-- honest answer for a client that does not know the matchups.
M.NEUTRAL_TYPES = 16

-- The engine spells a type as an id ("NORMAL"); the wire spells it as a small
-- integer, because the chart that crosses it is a rectangle of numbers and a
-- move names its own type by index into that rectangle.
--
-- **The ordering has to be the same on both clients, and nothing on the wire
-- states it.**  The host uploads the chart and the guest uploads moves carrying
-- indices into it, so a guest that ordered its types differently would have
-- every matchup read off the wrong row -- silently, and only for its own moves.
-- A plain sort of the ids is what makes that agree: two copies with the same
-- type set produce the same list whatever order their tables happened to
-- iterate in, and Lua's `pairs` order is not something either side may rely on.
--
-- Two copies with *different* type sets still disagree, and that is the
-- residual the fingerprint gate used to cover.  It is accepted rather than
-- fixed here: refusing the fight would put the mods-incompatibility refusal
-- back, which is the thing PROTOCOL 10 exists to remove.
--
-- Memoised against the data table itself and weakly, so a hot reload that
-- rebuilds `game.data` does not keep the old ordering alive.  `false` is
-- cached for a build with no chart at all, so the walk is not repeated per
-- battle.
local typeOrderCache = setmetatable({}, { __mode = "k" })

local function typeOrder(data)
  if type(data) ~= "table" then return nil end
  local hit = typeOrderCache[data]
  if hit ~= nil then return hit or nil end

  local chart = type(data.type_chart) == "table" and data.type_chart or nil
  if not chart then
    typeOrderCache[data] = false
    return nil
  end

  local seen, ids = {}, {}
  local function note(id)
    if type(id) ~= "string" or id == "" or seen[id] then return end
    seen[id] = true
    ids[#ids + 1] = id
  end
  -- The registry's own type records first, then anything a matchup row names
  -- that they missed: a data pack may register a matchup against a type it
  -- did not also describe, and a type with no row is still a type a move can
  -- claim.
  if type(chart.types) == "table" then
    for id in pairs(chart.types) do note(id) end
  end
  if type(chart.matchups) == "table" then
    for _, row in ipairs(chart.matchups) do
      if type(row) == "table" then note(row.attacker); note(row.defender) end
    end
  end

  if #ids == 0 then
    typeOrderCache[data] = false
    return nil
  end
  table.sort(ids)
  -- Config.BATTLE_TYPE_MAX bounds both axes of the chart, and Wire refuses a
  -- wider one outright.  Cutting the tail is what keeps an over-wide pack
  -- fighting: the types that survive keep their matchups, and a move naming
  -- one that did not is read as neutral by the sim rather than refusing
  -- somebody's whole team.
  for i = #ids, Config.BATTLE_TYPE_MAX + 1, -1 do ids[i] = nil end

  local index = {}
  for i = 1, #ids do index[ids[i]] = i - 1 end

  local out = { ids = ids, index = index }
  typeOrderCache[data] = out
  return out
end

M.typeOrder = typeOrder

local moveOf

-- The ephemeral rules for one match: the type chart, as integer percent.
--
-- The engine's table holds x10 multipliers (5 is half, 20 is double, 0 is
-- immune) and states only the matchups that are not neutral; the wire wants a
-- full rectangle of percent, because a fraction that crossed a JSON boundary
-- into two languages would round differently on the two ends and the same
-- attack would hit for different amounts depending on who was hosting.  So the
-- rectangle is filled with EFF_NEUTRAL and the stated rows are written over it.
function M.snapshotRuleset(game)
  local data = game and game.data
  local order = typeOrder(data)
  local width = order and #order.ids or M.NEUTRAL_TYPES

  local chart = {}
  for i = 1, width do
    local row = {}
    for j = 1, width do row[j] = Wire.EFF_NEUTRAL end
    chart[i] = row
  end

  if order and type(data.type_chart.matchups) == "table" then
    for _, entry in ipairs(data.type_chart.matchups) do
      if type(entry) == "table" then
        local attacker = order.index[entry.attacker]
        local defender = order.index[entry.defender]
        local mult = tonumber(entry.multiplier)
        if attacker and defender and mult then
          chart[attacker + 1][defender + 1] =
            min(Wire.CHART_MAX, max(0, floor(mult * 10)))
        end
      end
    end
  end

  -- Gen1 Special category is type-based.  Indices match the chart axes above
  -- so the intermediator never needs type *names*.
  local SPECIAL = {
    FIRE = true, WATER = true, GRASS = true, ELECTRIC = true,
    ICE = true, PSYCHIC = true, DRAGON = true,
  }
  local specialTypes = {}
  if order then
    for i, id in ipairs(order.ids) do
      if SPECIAL[id] then specialTypes[#specialTypes + 1] = i - 1 end
    end
    -- A chart with types but zero Special matches means Light Screen / Spc
    -- damage will never fire. Name the remediation rather than silently
    -- degrading to "everything is Physical".
    if #order.ids > 0 and #specialTypes == 0 then
      mod.log:warn("type chart has %d types but none match Gen1 Special "
        .. "(FIRE/WATER/GRASS/ELECTRIC/ICE/PSYCHIC/DRAGON); Light Screen and "
        .. "Special damage will treat every move as Physical. Check that "
        .. "type ids use those names (or upload specialTypes yourself)",
        #order.ids)
    end
  end

  -- Ephemeral Metronome pool from the host's own move table.  Sorted for a
  -- stable wire order; Metronome itself is excluded so a call cannot recurse.
  local metronomePool = {}
  local moveCount = 0
  if type(data) == "table" and type(data.moves) == "table" then
    local ids = {}
    for id in pairs(data.moves) do
      moveCount = moveCount + 1
      ids[#ids + 1] = id
    end
    table.sort(ids)
    for _, id in ipairs(ids) do
      if #metronomePool >= Config.BATTLE_METRONOME_POOL_MAX then break end
      local sheet = moveOf(data, { id = id, pp = 5 }, order)
      if sheet and sheet.effect ~= Effects.idOf("METRONOME_EFFECT")
         and id ~= "STRUGGLE" and id ~= "struggle" then
        metronomePool[#metronomePool + 1] = sheet
      end
    end
    if moveCount > 0 and #metronomePool == 0 then
      mod.log:warn("move table has %d entries but Metronome pool is empty; "
        .. "METRONOME will say \"But nothing happened\". Check move sheets "
        .. "decode (power/type/effect) from START > POKeMON",
        moveCount)
    end
  end

  -- No seed: the intermediator is the only party that rolls anything and can
  -- perfectly well pick its own.  Offering one would be claiming a say in the
  -- randomness that this side deliberately no longer has.
  local out = { chart = chart }
  if #specialTypes > 0 then out.specialTypes = specialTypes end
  if #metronomePool > 0 then out.metronomePool = metronomePool end
  return out
end

local function intOr(value, fallback)
  local n = tonumber(value)
  if not n or n ~= n then return fallback end
  return floor(n)
end

local function clamp(value, low, high)
  return min(high, max(low, value))
end

-- What the sim needs to resolve one move, read off the player's own move
-- record.
--
-- `accuracy` is converted rather than copied: the engine keeps a percent and
-- Gen 1 compares an 8-bit value against a 0-255 roll, which is the whole
-- mechanism behind the 1-in-256 miss -- `floor(acc * 255 / 100)` is the
-- conversion the engine's own `Damage.accuracyRoll` does, so a mediated fight
-- misses exactly as often as the same fight played offline.
--
-- `effect` and `chance` ride on the wire as integers.  The engine names an
-- effect with a string id ("SLEEP_EFFECT"); `Effects.idOf` is the shared
-- numbering both runtimes agree on.  Turn.lua does not branch on them until
-- Phase 1+ handlers land.
--
-- The defaults are what a client with no record for a move sends -- a modded
-- move whose definition did not survive, most likely.  40 power at full
-- accuracy on type 0 is a plain hit: weaker than assuming the best and far
-- better than refusing the move, which would refuse the monster and then the
-- whole party.
moveOf = function(data, slot, order)
  if type(slot) ~= "table" then return nil end
  local id = Wire.id(slot.id)
  if not id then return nil end

  local def = type(data) == "table" and type(data.moves) == "table"
    and data.moves[slot.id] or nil

  local accuracy = 255
  if def and tonumber(def.accuracy) then
    accuracy = clamp(floor(tonumber(def.accuracy) * 255 / 100), 0, 255)
  end

  local typeId = 0
  if order and def and order.index[def.type] then typeId = order.index[def.type] end

  local effect = 0
  local chance = 0
  if def then
    if def.effect then
      effect = Effects.idOf(def.effect) or 0
    end
    chance = clamp(intOr(def.chance, 0), 0, 100)
  end

  local pp = clamp(intOr(slot.pp, 0), 0, 99)
  local maxPp = clamp(intOr(slot.maxPp or slot.pp, pp), pp, 99)
  return {
    id       = id,
    pp       = pp,
    maxPp    = maxPp,
    power    = clamp(intOr(def and def.power, 40), 0, 999),
    accuracy = accuracy,
    type     = typeId,
    effect   = effect,
    chance   = chance,
  }
end

-- The four stats Gen 1 fights with, from the five the engine stores.
--
-- SPC is one stat and not two: Special did not split until Gen 2, so a
-- snapshot carrying spa/spd would be describing a different game's battler.
-- HP is absent because it rides as `maxHp`.
--
-- Clamped rather than refused, which is the opposite of what Wire does with the
-- same numbers and is right on this side of the boundary: Wire is judging a
-- stranger's claim and a number out of range there means the sender is not to
-- be believed, while here the number is our own truth and the only alternative
-- to trimming it is uploading a party the far end throws away whole -- a
-- player losing a fight they never got to start, over a stat nothing can fight
-- with anyway.
local function statsOf(mon)
  local stats = type(mon.stats) == "table" and mon.stats or nil
  if not stats then return nil end
  return {
    atk = clamp(intOr(stats.attack, 1), 1, Wire.STAT_MAX),
    def = clamp(intOr(stats.defense, 1), 1, Wire.STAT_MAX),
    spd = clamp(intOr(stats.speed, 1), 1, Wire.STAT_MAX),
    spc = clamp(intOr(stats.special, 1), 1, Wire.STAT_MAX),
  }
end

-- A full set of the four or nothing at all, on Wire's own rule: a snapshot
-- from a client that does not track DVs is ordinary, while one carrying two of
-- the four is a bug on this side that the far end would silently zero the rest
-- of.
local function fourOf(raw, low, high)
  if type(raw) ~= "table" then return nil end
  local out = {}
  local keys = { atk = "attack", def = "defense", spd = "speed", spc = "special" }
  for wireKey, engineKey in pairs(keys) do
    local n = tonumber(raw[engineKey])
    if not n or n ~= n then return nil end
    out[wireKey] = clamp(floor(n), low, high)
  end
  -- Optional HP Stat Exp for HP_UP (engine key `hp`).
  local hp = tonumber(raw.hp)
  if hp and hp == hp then
    out.hp = clamp(floor(hp), low, high)
  end
  return out
end

-- What this monster is called on the other player's screen.
--
-- The nickname when it has one, then the species record's display name, then
-- the raw id.  The display name is what the game itself prints, and it is the
-- one of the three that survives Wire.name intact for the species whose ids
-- carry punctuation the sanitiser drops.
local function speciesName(data, mon)
  local def = type(data) == "table" and type(data.pokemon) == "table"
    and data.pokemon[mon.species] or nil
  local name = mon.nickname
  if type(name) ~= "string" or name == "" then name = def and def.name end
  if type(name) ~= "string" or name == "" then name = mon.species end
  return Wire.name(name)
end

-- The types a species has, as indices into the uploaded chart.
--
-- Both sanitisers carry the field now -- `Wire.battleMon` and its JS twin keep a
-- present-and-readable `types` and refuse the battler outright when it is
-- present and unreadable, on the same rule a half-filled EV block gets -- so a
-- matchup and STAB apply to a mediated fight the way they do to a local one.
-- The indices are into *this match's* uploaded chart rather than into anything
-- shipped here, which is the whole reason they are numbers: the chart came from
-- the player's own decoded copy and is thrown away with the battle.  A monster
-- whose species this client cannot describe sends no types at all, and the sim
-- reads that absence as neutral rather than refusing the party.
local function typesOf(data, mon, order)
  if not order then return nil end
  local def = type(data) == "table" and type(data.pokemon) == "table"
    and data.pokemon[mon.species] or nil
  if not (def and type(def.types) == "table") then return nil end
  local out = {}
  for _, id in ipairs(def.types) do
    local index = order.index[id]
    if index then out[#out + 1] = index end
  end
  if #out == 0 then return nil end
  return out
end

-- Any team, as the intermediator will fight it.
--
-- Split out from `snapshotParty` because a co-op fight has more than one team
-- to describe from one client: src/CoopBattle.lua uploads its own party *and*,
-- when it is the host of a battle against an NPC, the trainer's -- and neither
-- of those two is `game.save.party`.  `game` is still handed in whole because
-- what a monster looks like on the wire is read off the player's own `data`
-- (the move records, the species names, the type ordering) whoever owns the
-- monster.
--
-- Best-effort throughout: a monster that cannot be described is skipped rather
-- than taking the party with it, because a party of five is a fight and a party
-- of none is not.  An empty result is the caller's to refuse -- see M:start.
function M.snapshotMons(game, party)
  if type(party) ~= "table" then return {} end

  local data = game and game.data
  local order = typeOrder(data)

  local out = {}
  for index = 1, #party do
    if #out >= Config.BATTLE_MON_MAX then break end
    local mon = party[index]
    if type(mon) == "table" then
      local stats = statsOf(mon)
      local species = speciesName(data, mon)
      if stats and species then
        local maxHp = clamp(intOr(mon.stats and mon.stats.hp, 1), 1, Wire.HP_MAX)
        local moves = {}
        for _, slot in ipairs(mon.moves or {}) do
          if #moves >= Config.BATTLE_MOVE_MAX then break end
          local move = moveOf(data, slot, order)
          if move then moves[#moves + 1] = move end
        end
        if #moves > 0 then
          out[#out + 1] = {
            species = species,
            -- Registry id for battle art (local only; the wire keeps `species`
            -- as the display / nickname token the sim narrates under).
            speciesId = mon.species,
            level   = clamp(intOr(mon.level, 1), 1, Wire.LEVEL_MAX),
            hp      = clamp(intOr(mon.hp, maxHp), 0, maxHp),
            maxHp   = maxHp,
            stats   = stats,
            -- The engine spells a condition with the same three-letter token
            -- the wire does ("SLP", "PSN", ...), so this passes through rather
            -- than being translated.  nil is healthy and is a real answer.
            status  = Wire.battleStatus(mon.status) or nil,
            slot    = clamp(index - 1, 0, Wire.SLOT_MAX),
            ivs     = fourOf(mon.dvs, 0, 15),
            evs     = fourOf(mon.statExp, 0, 65535),
            types   = typesOf(data, mon, order),
            moves   = moves,
          }
          local def = type(data) == "table" and type(data.pokemon) == "table"
            and data.pokemon[mon.species] or nil
          local rate = def and tonumber(def.catchRate)
          if rate then
            out[#out].catchRate = clamp(floor(rate), 0, 255)
          end
        end
      end
    end
  end
  return out
end

-- This player's own team.
function M.snapshotParty(game)
  local save = game and game.save
  return M.snapshotMons(game, save and save.party)
end

-- ------- what goes out before the fight opens, in one place
--
-- Two senders and one validator, shared with src/CoopBattle.lua rather than
-- copied into it.  The uploads are the only thing a client says that decides
-- what the fight *is* -- there is no move table and no chart on either
-- intermediator -- so a second copy of "how a party is put on the wire" is a
-- second place for a 1v1 and a 2-on-2 to start describing the same monster
-- differently.

-- The host's chart, and nobody else's.  Not because a guest's would be worse,
-- but because two charts is a fight with no answer to "which", and both
-- intermediators refuse a ruleset from anyone but the seat they brokered as
-- host.
function M.sendRuleset(transport, game)
  if not transport then return false end
  transport:send(Wire.BATTLE_RULESET, M.snapshotRuleset(game))
  return true
end

-- One seat's team.  `side` is optional for a 1v1 -- there are two combatants and
-- the intermediator knows which is which from the session it brokered -- and is
-- what tells a co-op upload apart: it is how the host of a fight against an NPC
-- fills the synthetic npc seat (side "b") without displacing its own.
-- `bag` is the optional inventory claim for this fight (PROTOCOL 15); omit or
-- pass nil for an empty sheet.
-- `badges` is optional: a list of earned badge ids for human seats (not NPC).
function M.sendParty(transport, battle, mons, side, bag, badges)
  if not (transport and battle) then return false end
  if type(mons) ~= "table" or #mons == 0 then return false end
  local msg = { battle = battle, mons = mons, side = side, bag = bag }
  if badges then msg.badges = badges end
  transport:send(Wire.BATTLE_PARTY, msg)
  return true
end

-- The badges this player has earned, as a list for the wire.
--
-- Read off the badge *rows* rather than off a list written down here, so a mod
-- that adds a badge -- or retunes which ones boost what -- is covered without
-- this file knowing about it.
function M.badgesOf(game)
  local data = game and game.data
  local inventory = game and game.save and game.save.inventory
  if not (data and inventory) then return nil end
  local rows = data.constants and data.constants.badgeBoosts
  if not rows then
    local ok, Damage = pcall(require, "src.battle.Damage")
    rows = ok and Damage and Damage.BADGE_BOOSTS or nil
  end
  local out = {}
  for _, row in ipairs(rows or {}) do
    if row.badge and inventory[row.badge] then out[#out + 1] = row.badge end
  end
  if #out == 0 then return nil end
  return out
end

-- Battle-usable stacks from the local save, for the hub bag proof.
-- Only ids BattleSim knows (`itemEffect`); vitamins included (fight-local EV).
-- Truncated to BATTLE_BAG_MAX so the menu and the upload stay the same set.
function M.itemIsBattleUsable(id, game)
  if type(id) ~= "string" or id == "" then return nil end
  local effect = Effects.itemEffect(id)
  if not effect then return nil end
  local items = (game and game.data and game.data.items) or {}
  local def = items[id]
  if effect.pokeFlute or effect.noConsume then return effect end
  if def and (def.key or def.machine) then return nil end
  return effect
end

-- Engine save.statExp keys for BattleSim vitaminStat tokens.
local VITAMIN_SAVE_KEY = {
  hp = "hp", atk = "attack", def = "defense", spd = "speed", spc = "special",
}

-- Write Gen1 vitamin Stat Exp onto save.party[partyIndex] (1-based).
-- Fight-local sheet mutation is the hub's job; permanence is the client's.
-- Only call after an `item` event with amount=1 (vitamin applied).
function M.writebackVitamin(game, partyIndex, itemId)
  local effect = Effects.itemEffect(itemId)
  local wireStat = effect and effect.vitaminStat
  local saveKey = wireStat and VITAMIN_SAVE_KEY[wireStat]
  if not saveKey then return false end
  local party = game and game.save and game.save.party
  local mon = party and party[partyIndex]
  if type(mon) ~= "table" then return false end
  mon.statExp = mon.statExp or {}
  local before = math.max(0, math.floor(tonumber(mon.statExp[saveKey]) or 0))
  if before >= Effects.VITAMIN_FAIL_AT then return false end
  local after = math.min(65535, before + Effects.VITAMIN_GAIN)
  mon.statExp[saveKey] = after

  -- Recalc live battle stats / max HP so the party screen does not lag.
  -- Prefer engine Stats.calc when the species def is reachable; otherwise apply
  -- the same Gen1 √EV contribution delta BattleSim uses (no ROM / no require).
  local oldMax = tonumber(mon.stats and mon.stats.hp) or tonumber(mon.hp) or 0
  local level = math.max(1, math.floor(tonumber(mon.level) or 1))
  local applied = false
  local def = game.data and game.data.pokemon and game.data.pokemon[mon.species]
  local okStats, Stats = pcall(require, "src.pokemon.Stats")
  if okStats and Stats and type(Stats.calc) == "function"
     and type(def) == "table" and type(def.baseStats) == "table" then
    local ok, stats = pcall(Stats.calc, def, level, mon.dvs or {}, mon.statExp)
    if ok and type(stats) == "table" then
      mon.stats = stats
      local newMax = tonumber(stats.hp) or oldMax
      local cur = tonumber(mon.hp) or oldMax
      if wireStat == "hp" and newMax > oldMax then
        mon.hp = math.min(newMax, cur + (newMax - oldMax))
      else
        mon.hp = math.max(0, math.min(cur, newMax))
      end
      applied = true
    end
  end
  if not applied then
    local function contrib(ev)
      return math.floor(math.sqrt(math.max(0, ev)) / 4)
    end
    local delta = math.floor((contrib(after) - contrib(before)) * level / 100)
    mon.stats = mon.stats or {}
    if wireStat == "hp" then
      local newMax = math.max(1, oldMax + delta)
      mon.stats.hp = newMax
      local cur = tonumber(mon.hp) or oldMax
      mon.hp = math.min(newMax, cur + math.max(0, delta))
    else
      local curStat = math.max(1, math.floor(tonumber(mon.stats[saveKey]) or 1))
      mon.stats[saveKey] = math.max(1, curStat + delta)
      local cur = tonumber(mon.hp) or oldMax
      local maxHp = tonumber(mon.stats.hp) or oldMax
      if maxHp > 0 then mon.hp = math.max(0, math.min(cur, maxHp)) end
    end
  end
  return true
end

-- Resolve which save.party index a co-op seat mon is.
-- `seatPartyIndex` (optional) names seat.party[i] after an ITEM party pick;
-- default is the seat's active. Prefers identity match against save.party,
-- then the seat index as a last resort.
function M.vitaminPartyIndex(game, seat, seatPartyIndex)
  if type(seat) ~= "table" then return 1 end
  local idx = seatPartyIndex or seat.active or 1
  local fieldMon = seat.party and seat.party[idx]
  if not fieldMon and seat.battler then fieldMon = seat.battler.mon end
  local saveParty = game and game.save and game.save.party
  if fieldMon and type(saveParty) == "table" then
    for i, mon in ipairs(saveParty) do
      if mon == fieldMon then return i end
    end
  end
  if type(idx) == "number" and idx >= 1 then return idx end
  return 1
end

function M.bagCounts(list)
  local map = {}
  for _, entry in ipairs(list or {}) do
    if type(entry) == "table" and type(entry.id) == "string"
       and type(entry.count) == "number" and entry.count > 0 then
      map[entry.id] = entry.count
    end
  end
  return map
end

function M.snapshotBag(game)
  local out = {}
  local inventory = (game and game.save and game.save.inventory) or {}
  for id, count in pairs(inventory) do
    if (count or 0) > 0 and M.itemIsBattleUsable(id, game) then
      local n = count
      if n > Config.BATTLE_BAG_COUNT_MAX then n = Config.BATTLE_BAG_COUNT_MAX end
      out[#out + 1] = { id = id, count = n }
    end
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  while #out > Config.BATTLE_BAG_MAX do
    out[#out] = nil
  end
  return out
end

-- One turn's intent.  A choice and never a result: the fields name what was
-- pressed, and what it costs is the intermediator's to decide.
--
-- Checked before it goes rather than after it is refused: both hubs answer a
-- malformed choice with silence, and silence at a battle screen is a turn the
-- player believes they spent.
function M.submitChoice(transport, battle, fields)
  if not (transport and battle) then return false end
  local out = { battle = battle }
  for key, value in pairs(fields or {}) do out[key] = value end
  if not Wire.battleChoice(out) then
    mod.log:warn("a battle choice would not have been understood and was not "
      .. "sent; press again, or wait for the turn clock")
    return false
  end
  transport:send(Wire.BATTLE_CHOICE, out)
  return true
end

-- Is `id` in this list of player ids?
--
-- Exported because an outcome is read by asking it twice, and both screens ask:
-- a 1v1 asks about the peer (the side they are not on is ours) and a 2-on-2
-- asks about itself (there are four ids and no single "other side").
function M.holds(list, id)
  if id == nil then return false end
  for _, entry in ipairs(list or {}) do
    if entry == id then return true end
  end
  return false
end

-- ------- the fight

-- How long a freshly shown line is safe from the button that dismisses it, and
-- how long it stays up when nobody presses anything.  CoopBattle's numbers and
-- CoopBattle's argument: a player holding A through a battle -- which is every
-- player -- otherwise swallows lines they never saw.
local MSG_MIN_DWELL = 0.25
local MSG_AUTO_ADVANCE = 1.6

-- Side a takes field slot 0 and side b takes slot 2.  Mirrored from
-- src/BattleSim/events.lua's numbering rather than derived, because it is the
-- numbering every event on the wire is already stated in: a 1v1 leaves the odd
-- slots empty so that "which box is this" does not change meaning with the
-- mode.
local function slotOfSide(side) return side == "b" and 2 or 0 end

function M.new(opts)
  opts = opts or {}
  return setmetatable({
    transport = opts.transport,
    ui        = opts.ui,
    game      = opts.game,
    battle    = opts.battle,
    role      = opts.role,
    peerId    = opts.peerId,
    peerName  = opts.peerName or "FRIEND",
    onDone    = opts.onDone,

    -- A test hook, and named as one.  With it set, a turn is answered the
    -- instant it opens with the first move at the default target, which is
    -- what lets the headless suite drive a whole fight with no input device.
    -- It is never set in the game: the intermediator already auto-picks for a
    -- player who says nothing before BATTLE_CHOICE_TIMEOUT, so a client that
    -- silently picked as well would be spending turns the player is still
    -- thinking about.
    autoPick  = opts.autoPick == true,

    -- Protocol-only wild: mode "wild", optional wildParty sheets + engine mon
    -- kept for Party.add / Boxes.deposit on a catch outcome.
    mode         = opts.mode or "1v1",
    wildParty    = opts.wildParty,
    wildCatchMon = opts.wildCatchMon,

    -- What src/Sessions.lua's isFightState looks for.  A mediated battle is
    -- not a BattleState and carries none of the engine's markers, so without
    -- this an invite could pop over a live fight.
    mmoBattle = true,

    -- Same contract as engine BattleState / CoopBattle: without isOpaque the
    -- stack keeps drawing the overworld underneath and beginFrame clears the
    -- UI canvas transparent. Letterbox voids stay the engine default (black)
    -- -- letterboxWhite would paint SGB paper pink against this screen's
    -- colors=false white fill.
    isOpaque = true,

    phase     = "setup",   -- setup | play | choose | move | item | item_party | item_move | switch | over
    uploaded  = false,
    finished  = false,
    left      = false,
    mine      = nil,       -- our own snapshot, which the move menu reads
    active    = 1,         -- which of ours is out, as an index into `mine`
    mySide    = (opts.role == "guest") and "b" or "a",
    slots     = {},        -- field slot -> { species, hp, maxHp }
    lines     = {},
    shown     = nil,
    dwell     = 0,
    cursor    = 1,
    commandIndex = 1,
    itemIndex = 1,
    switchIndex = 1,
    itemPick = nil,        -- { id, effect } while picking party/move
    itemList = nil,
    bagSheet = nil,        -- id → count matching the uploaded PROTOCOL 15 bag
    pendingItem = nil,     -- choice sent; debit only after hub `item` event
    pendingItemSlot = nil, -- 1-based party index for vitamin writeback
    seq       = 0,         -- the highest event sequence applied
    gaps      = 0,         -- events that arrived out of order
    pendingTurn = false,
    answeredTurn = false, -- own seat already answered (forced skip or filed choice)
    mustReplace = false,  -- faint with bench: next turn opens the switch picker
    replaceOnly = false,  -- B cannot cancel out of a forced replacement
    anim = nil,           -- { anim = id, slot = n } while AnimPlayer runs
    animPlayer = nil,
    result    = nil,
    -- Set while the hub link is down under a live fight: the intermediator's
    -- reconnect grace is running, and onTransportReady is what resumes it.
    awaitingReconnect = false,
    reconnectSent = false,
    liveMoves   = nil,     -- referee-published list after Transform/Mimic
  }, M)
end

function M:say(text)
  if type(text) ~= "string" or text == "" then return end
  self.lines[#self.lines + 1] = text
end

function M:mySlot() return slotOfSide(self.mySide) end
function M:foeSlot() return slotOfSide(self.mySide == "a" and "b" or "a") end

-- Upload what we are bringing.  Idempotent, because two things call it: the
-- session, the moment the hub pairs us, and `enter`, when the screen actually
-- goes up.  The session's call is the one that matters -- it is what lets the
-- suite drive the exchange with no state stack at all -- and `enter` is the
-- belt for a screen pushed by some other route.
function M:start(game)
  if game then self.game = game end
  if self.uploaded then return true end
  if not (self.transport and self.battle) then return false end

  local mons = M.snapshotParty(self.game)
  if #mons == 0 then
    -- Uploading nothing would leave the intermediator holding a seat open
    -- until its grace expired, and the player watching a screen that never
    -- starts.  Ended here instead, with the reason on it.
    mod.log:warn("no POKeMON could be described for a mediated battle, so "
      .. "there is nothing to fight with -- check the party from START > "
      .. "POKeMON, and report this if it is not empty")
    self.uploaded = true
    self:say("You have no POKeMON\nto battle with!")
    self:finish("draw", "gone")
    return false
  end

  self.uploaded = true
  self.mine = mons

  if self.role == "host" or self.mode == "wild" then
    M.sendRuleset(self.transport, self.game)
  end
  -- No side: a 1v1 has none to name. Wild uploads the encounter as side "b".
  local bag = M.snapshotBag(self.game)
  self.bagSheet = M.bagCounts(bag)
  M.sendParty(self.transport, self.battle, mons, nil, bag, M.badgesOf(self.game))
  if self.mode == "wild" and type(self.wildParty) == "table" and #self.wildParty > 0 then
    M.sendParty(self.transport, self.battle, self.wildParty, "b")
  end
  return true
end

-- ------- inbound

-- The field is assembled and the first turn is open.
--
-- The sides are read back rather than assumed, and the peer's id is what
-- decides them: this client does not carry its own hub id down here, but it
-- does know who it is fighting, so "the side the peer is not on is mine" is an
-- answer that needs nothing else.  The role is the fallback for a hub that
-- named the sides some other way -- the asker hosts, and the hub seats the
-- asker on side a.
function M:onReady(msg)
  if self.finished then return end
  if msg.battle ~= self.battle then return end

  local function holds(list, id)
    for _, entry in ipairs(list or {}) do
      if entry == id then return true end
    end
    return false
  end
  local sides = msg.sides or {}
  if self.peerId then
    if holds(sides.b, self.peerId) then
      self.mySide = "a"
    elseif holds(sides.a, self.peerId) then
      self.mySide = "b"
    end
  elseif self.mode == "wild" then
    -- Solo wild: we sit on side a; the synthetic seat is the peer for resultFor.
    self.mySide = "a"
    self.peerId = sides.b and sides.b[1] or self.peerId
    self.selfId = sides.a and sides.a[1] or self.selfId
  end

  if msg.mode then self.mode = msg.mode end

  if self.phase == "setup" then
    self.phase = "play"
    if self.mode == "wild" then
      self:say("A wild pokemon\nappeared!")
    else
      self:say(("%s wants to\nfight!"):format(self.peerName))
    end
  end
end

-- One thing to draw, in order.
--
-- `seq` is what makes the stream a stream: an event whose sequence is one this
-- side has already passed is a duplicate and is dropped, and a jump forward is
-- counted rather than refused.  Refusing the jump would leave the screen
-- waiting on a message that is not coming; counting it means the gap is
-- visible in a log if a hub really is losing messages, while the fight -- whose
-- state lives on the intermediator anyway -- carries on from what did arrive.
function M:onEvent(msg)
  if self.finished then return end
  if msg.battle ~= self.battle then return end
  if msg.seq <= self.seq then return end
  if msg.seq > self.seq + 1 and self.seq > 0 then
    self.gaps = self.gaps + 1
  end
  self.seq = msg.seq

  if self.phase == "setup" then self.phase = "play" end

  local kind = msg.t
  if kind == "msg" then
    self:say(msg.text)

  elseif kind == "anim" then
    -- Queued with the message stream so the flash lands in referee order.
    if msg.text then
      self.lines[#self.lines + 1] = {
        anim = msg.text, slot = msg.slot, side = msg.side,
      }
    end

  elseif kind == "send" or kind == "switch" then
    -- The first HP we are told about is a full bar: the sim sends this the
    -- moment a monster comes out, so the number is that monster's maximum
    -- unless it walked in already hurt.  It is the only handle on a foe's
    -- maximum there is -- an event carries current HP and nothing else -- so
    -- the largest value ever seen is what the bar is drawn against.
    self:noteSlot(msg)
    -- New mon on our seat drops any Transform/Mimic overlay until the
    -- referee publishes another `moves` list for it.
    if msg.slot == self:mySlot() then
      self.liveMoves = nil
      self.mustReplace = false
      if self.replaceOnly then
        self.replaceOnly = false
        if self.phase == "switch" then self.phase = "play" end
      end
    end
    if msg.text then
      if msg.slot ~= self:mySlot() then
        self:say(("%s sent out\n%s!"):format(self.peerName, msg.text))
        self:refreshSlotSprite(msg.slot, false)
      else
        self:say(("Go! %s!"):format(msg.text))
        self:trackActive(msg.text)
        local mon = self.mine and self.mine[self.active]
        local slot = self.slots[msg.slot]
        if slot and mon and mon.level then slot.level = mon.level end
        self:refreshSlotSprite(msg.slot, true)
      end
    end

  elseif kind == "damage" or kind == "drain" then
    self:noteSlot(msg)
    self:syncMineHp(msg)

  elseif kind == "faint" then
    local slot = self:noteSlot(msg)
    if slot then slot.hp = 0 end
    if msg.slot == self:mySlot() then
      local mon = self.mine and self.mine[self.active]
      if mon then mon.hp = 0 end
      -- Authoritative: hub/sim sets amount=1 when a living bench remains.
      -- Absent amount (older stream) falls back to local party HP.
      if msg.amount == 1 then
        self.mustReplace = true
      elseif msg.amount ~= nil then
        self.mustReplace = false
      else
        local hasBench = false
        for _, m in ipairs(self.mine or {}) do
          if (m.hp or 0) > 0 then hasBench = true; break end
        end
        self.mustReplace = hasBench
      end
    end
    if msg.text then self:say(("%s fainted!"):format(msg.text)) end
    -- After the faint line has been read (and any anim still ahead of it in
    -- `lines` has played), drop the pic. Queued behind the say so the KO stays
    -- on screen through the flash + "X fainted!".
    self.lines[#self.lines + 1] = { clearPic = msg.slot }

  elseif kind == "status" then
    self:noteSlot(msg)

  elseif kind == "item" then
    -- Debit only once the hub has accepted and resolved the item choice.
    -- Spending on send left a soft-lock when the bag proof refused: phase
    -- "play", item gone, no `chose`.
    if msg.slot == self:mySlot() then
      self:confirmPendingItem(msg.text, msg.amount)
    end

  elseif kind == "turn" then
    -- Held rather than acted on: the lines this turn's events produced are
    -- still being read, and opening the menu over them would take the box the
    -- player is reading out from under them.  update() opens it once the
    -- queue is empty — unless the hub already filed our choice (forced skip /
    -- recharge / trap), in which case answeredTurn keeps the menu closed.
    self.pendingTurn = true
    self.answeredTurn = false
    -- Hub refused the item (never debited) or spend already landed via `item`.
    self.pendingItem = nil
    self.pendingItemSlot = nil

  elseif kind == "over" then
    -- The field is done; the outcome is a separate message and is what this
    -- screen actually ends on.
    self.pendingTurn = false
    self.answeredTurn = false
    self.mustReplace = false
    self.replaceOnly = false
    self.pendingItem = nil
    self.pendingItemSlot = nil

  elseif kind == "wait" then
    if msg.text then self:say(("Waiting for\n%s..."):format(msg.text)) end

  elseif kind == "reconnect" then
    -- Their return, or ours after we re-announced: either way the waiting
    -- caption is done.
    self.awaitingReconnect = false
    if msg.text then self:say(("%s is back!"):format(msg.text)) end

  elseif kind == "chose" or kind == "unchose" then
    if msg.slot == self:mySlot() then
      if kind == "chose" then
        -- Forced skip / our filed answer: do not open (or keep) the command
        -- menu for a turn the hub has already spent.
        self.answeredTurn = true
        self.pendingTurn = false
        if self.phase == "choose" or self.phase == "move"
           or self.phase == "item" or self.phase == "item_party"
           or self.phase == "item_move" or self.phase == "switch" then
          self.phase = "play"
        end
      else
        self.answeredTurn = false
        self.pendingItem = nil
        self.pendingItemSlot = nil
      end
    end

  elseif kind == "moves" then
    if msg.slot == self:mySlot() and type(msg.moves) == "table" then
      self.liveMoves = msg.moves
    end
  end
end

-- Keep `mine[].hp` in step with field damage so partyRows / mustReplace see
-- the same numbers the referee just applied.
function M:syncMineHp(msg)
  if msg.slot ~= self:mySlot() then return end
  local mon = self.mine and self.mine[self.active]
  if not mon then return end
  if msg.hp ~= nil then
    mon.hp = msg.hp
  elseif msg.amount ~= nil and msg.t == "damage" then
    mon.hp = max(0, (mon.hp or 0) - msg.amount)
  end
end

-- Record whatever an event said about a field slot.  Every event that names one
-- carries the HP that slot is now on, so one place reads it and the screen
-- never has to guess.
function M:noteSlot(msg)
  local index = msg.slot
  if index == nil then return nil end
  local slot = self.slots[index]
  if not slot then
    slot = { species = nil, hp = 0, maxHp = 1 }
    self.slots[index] = slot
  end
  if msg.text and (msg.t == "send" or msg.t == "switch") then
    slot.species = msg.text
    slot.sprite = nil
    slot.koHold = nil
  end
  if msg.hp ~= nil then
    slot.hp = msg.hp
    if msg.hp > slot.maxHp then slot.maxHp = msg.hp end
  elseif msg.amount ~= nil and msg.t == "damage" then
    slot.hp = max(0, slot.hp - msg.amount)
  end
  if msg.status ~= nil then slot.status = msg.status end
  -- Do not clear the pic here. Faint often arrives in the same batch as the
  -- move's `anim`, which is only played later from `lines` -- nil'ing the
  -- sprite the moment HP hits 0 made the mon vanish under the still-queued
  -- flash. `clearPic` (queued after the faint line) releases it.
  if msg.t == "faint" then
    slot.koHold = true
  end
  return slot
end

-- Which of ours is out, matched by the name the sim narrates it under.
--
-- Only the *name* crosses back, so a party holding two monsters with the same
-- one is matched to the first -- which is wrong only for the move list, and
-- only for a player who nicknamed two of their team identically.  The
-- alternative is tracking send-outs by counting faints, which is wrong more
-- often and more quietly.
function M:trackActive(species)
  for index, mon in ipairs(self.mine or {}) do
    if mon.species == species or mon.speciesId == species then
      self.active = index
      return
    end
  end
end

-- Map a narrated name back to a pokemon registry id for battle art.
function M:speciesKeyFor(label, preferMine)
  if type(label) ~= "string" or label == "" then return nil end
  if preferMine then
    for _, mon in ipairs(self.mine or {}) do
      if mon.species == label and mon.speciesId then return mon.speciesId end
    end
    local active = self.mine and self.mine[self.active]
    if active and active.species == label and active.speciesId then
      return active.speciesId
    end
  end
  local data = self.game and self.game.data
  local pokedex = data and data.pokemon
  if type(pokedex) ~= "table" then return nil end
  if pokedex[label] then return label end
  for id, def in pairs(pokedex) do
    if type(def) == "table" then
      local name = Wire.name(def.name or id)
      if name == label then return id end
    end
  end
  return nil
end

function M:refreshSlotSprite(index, isPlayer)
  local slot = self.slots[index]
  if not slot or not slot.species or (slot.hp or 0) <= 0 then
    if slot then slot.sprite = nil end
    return
  end
  local eng = loadEngine()
  local data = self.game and self.game.data
  if not (eng and eng.BattleState and eng.BattleState.makeBattler and data) then
    slot.sprite = nil
    return
  end
  local key = self:speciesKeyFor(slot.species, isPlayer)
  if not key or not data.pokemon[key] then
    slot.sprite = nil
    return
  end
  local monHint = nil
  if isPlayer then
    monHint = self.mine and self.mine[self.active]
  end
  local stub = {
    species = key,
    nickname = slot.species,
    level = (monHint and monHint.level) or slot.level or 1,
    hp = slot.hp or 1,
    stats = {
      hp = slot.maxHp or 1,
      attack = 1, defense = 1, speed = 1, special = 1,
    },
    moves = (monHint and monHint.moves) or { { id = "TACKLE", pp = 1 } },
    status = slot.status,
  }
  local save = isPlayer and self.game and self.game.save or nil
  local ok, battler = pcall(eng.BattleState.makeBattler, data, stub, isPlayer, save)
  if ok and battler and battler.sprite then
    slot.sprite = battler.sprite
    slot.level = stub.level
  else
    slot.sprite = nil
  end
end

function M:activeMon()
  local mon = self.mine and self.mine[self.active] or nil
  if mon and self.liveMoves then
    local copy = {}
    for k, v in pairs(mon) do copy[k] = v end
    copy.moves = self.liveMoves
    return copy
  end
  return mon
end

-- How it ended, from the only party that knows.
--
-- **No mmo.result goes out for this fight.**  The dual-client vote exists
-- because neither peer in a relayed battle could be believed about its own
-- win; here the intermediator did every roll, so it says who won and both hubs
-- ignore a client's report about a battle they ran.  Sessions never records a
-- `lastBattle` on this path, which is what makes that structural rather than a
-- rule somebody has to remember.
function M:onOutcome(msg)
  if self.finished then return end
  if msg.battle ~= self.battle then return end
  self.pendingTurn = false
  self:finish(M.resultFor(msg, self.peerId), msg.reason, msg)
end

-- This player's result, worked out from who is named rather than from the
-- outcome token.
--
-- `outcome` is stated from the *field's* point of view -- "win" means the
-- winners list won -- so it is the same value in both clients' copies of the
-- message and says nothing on its own about the recipient.  The peer's id is
-- what turns it into a sentence: the side they are not on is ours.  A draw
-- carries no lists at all (Wire refuses an empty one), which is why the
-- absence is read as a draw rather than as a missing field.
function M.resultFor(msg, peerId)
  if peerId then
    if M.holds(msg.winners, peerId) then return "loss" end
    if M.holds(msg.losers, peerId) then return "win" end
  end
  return "draw"
end

-- The same verdict read the other way round: from this client's *own* id.
--
-- A 1v1 can reason from the peer because there is exactly one of them.  A
-- 2-on-2 cannot -- four ids arrive, two of them allies -- so the only question
-- with a single answer is "am I named", and it is asked here rather than in the
-- co-op screen so both readings of one message live side by side.
function M.resultForSelf(msg, selfId)
  if selfId then
    if M.holds(msg.winners, selfId) then return "win" end
    if M.holds(msg.losers, selfId) then return "loss" end
  end
  return "draw"
end

local ENDINGS = {
  win  = "You won!",
  loss = "You lost!",
  draw = "It was a draw.",
}

-- Why it ended, for the reasons a sentence exists for.  An unknown token --
-- a newer intermediator naming something this build cannot phrase -- is
-- deliberately silent rather than printed raw: the result is the part that
-- matters and it has already landed.
local REASONS = {
  timeout    = "Nobody answered\nin time.",
  disconnect = "The link was lost.",
  run        = "Someone ran away!",
  forfeit    = "Someone gave up.",
  catch      = "Gotcha!",
}

function M:grantCatch(msg)
  local mon = self.wildCatchMon
  if not mon and msg and msg.caught then
    -- Sheet-only path: cannot rebuild a full engine mon without ROM data.
    self:say("Caught, but could not\nadd to the party.")
    return
  end
  if not mon then return end
  local game = self.game
  local save = game and game.save
  if not save then return end
  local okParty, Party = pcall(require, "src.pokemon.Party")
  if okParty and Party.add(save.party, mon) then
    self:say((mon.nickname or mon.species or "It") .. " was\nadded to the party!")
    return
  end
  local okBoxes, Boxes = pcall(require, "src.pokemon.Boxes")
  if okBoxes and Boxes.deposit(save, mon) then
    self:say((mon.nickname or mon.species or "It") .. " was\nsent to the PC!")
    return
  end
  self:say("But every BOX\nis full!")
end

function M:finish(result, reason, msg)
  if self.finished then return end
  self.finished = true
  self.pendingItem = nil
  self.pendingItemSlot = nil
  self.result = result or "draw"
  self.phase = "over"
  self.cursor = 1
  if reason == "catch" and result == "win" then
    self:say("Gotcha!")
    self:grantCatch(msg)
  else
    self:say(ENDINGS[self.result] or ENDINGS.draw)
    local why = REASONS[reason]
    if why then self:say(why) end
  end
end

-- ------- outbound

-- The hub link came back under a fight that is still open.
--
-- Both hubs already run reconnect grace + sim.reconnect(); until PROTOCOL 10's
-- clients actually sent mmo.battle_reconnect, every drop rode to forfeit. This
-- is that message. Idempotent per drop cycle: Sessions / Coop call it when
-- transport:isReady() flips false→true, and the headless suite calls it
-- directly as notifyReconnect.
function M:onTransportReady()
  if self.finished or self.left then return false end
  if not (self.transport and self.battle) then return false end
  if self.reconnectSent then return false end
  self.reconnectSent = true
  self.awaitingReconnect = false
  self.transport:send(Wire.BATTLE_RECONNECT, { battle = self.battle })
  return true
end

function M:notifyReconnect()
  return self:onTransportReady()
end

-- The hub link dropped under a live fight. Narrate and wait: finishing here
-- would take the screen away before the intermediator's grace (or a reconnect)
-- can resolve it.
function M:onTransportLost()
  if self.finished or self.left then return end
  if self.awaitingReconnect then return end
  self.awaitingReconnect = true
  self.reconnectSent = false
  self:say("Connection lost.\nWaiting to reconnect...")
end

-- One turn's intent, through the shared sender so a 1v1 and a 2-on-2 put the
-- same shape on the wire.  What is left here is this screen's own bookkeeping:
-- the menu closes on a choice that actually went.
function M:sendChoice(fields)
  if self.finished then return false end
  if not M.submitChoice(self.transport, self.battle, fields) then return false end
  self.phase = "play"
  self.pendingTurn = false
  self.answeredTurn = true
  return true
end

-- FIGHT with the move at `index` (1-based here, zero-based on the wire).  No
-- target: a 1v1 has exactly one thing to hit, and the sim picks the first
-- living foe when none is named -- naming one would be a field slot this
-- screen would have to keep in step for no gain.
function M:pickMove(index)
  local mon = self:activeMon()
  local moves = mon and mon.moves
  if not (moves and moves[index]) then return false end
  return self:sendChoice({ action = "fight", move = index - 1 })
end

-- Classic Gen 1 order (row-major): FIGHT SWITCH / ITEM RUN.
M.COMMANDS = { "FIGHT", "SWITCH", "ITEM", "RUN" }

local function gridStep(index, count, direction)
  local row = math.floor((index - 1) / 2)
  local col = (index - 1) % 2
  if direction == "left" then col = math.max(0, col - 1)
  elseif direction == "right" then col = math.min(1, col + 1)
  elseif direction == "up" then row = math.max(0, row - 1)
  elseif direction == "down" then row = math.min(1, row + 1)
  else return index end
  local moved = row * 2 + col + 1
  if moved > count then return index end
  return moved
end

local GRID_KEYS = { "left", "right", "up", "down" }

local function gridPress(index, count, input)
  for _, key in ipairs(GRID_KEYS) do
    if input:wasPressed(key) then return gridStep(index, count, key) end
  end
  return nil
end

function M:usableItems()
  if self.itemList then return self.itemList end
  local out = {}
  local inventory = (self.game and self.game.save and self.game.save.inventory) or {}
  local items = (self.game and self.game.data and self.game.data.items) or {}
  -- Menu follows the uploaded bag sheet so players cannot pick stacks the hub
  -- never received (truncation / unknown ids).
  local bag = self.bagSheet
  if type(bag) ~= "table" then bag = {} end
  for id, bagCount in pairs(bag) do
    local effect = M.itemIsBattleUsable(id, self.game)
    if effect and (bagCount or 0) > 0 then
      local inv = inventory[id] or 0
      local count
      if effect.noConsume then
        count = (inv >= 1 or bagCount >= 1) and 1 or 0
      else
        count = math.min(bagCount, inv)
      end
      if count > 0 then
        local def = items[id]
        out[#out + 1] = {
          id = id,
          name = (def and def.name) or id,
          count = count,
          effect = effect,
        }
      end
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  self.itemList = out
  return out
end

-- Hub resolved our pending item choice (`item` event on our seat).
-- No `owed`: the hub already decremented; abandon must not refund a spent stack.
-- `amount == 1` on a vitamin means the hub applied Stat Exp (writeback owed);
-- a failed vitamin still debits the bag but must not touch save.statExp.
function M:confirmPendingItem(itemId, amount)
  local id = self.pendingItem
  if not id then return false end
  if itemId and itemId ~= id then return false end
  local partyIndex = self.pendingItemSlot or self.active
  self.pendingItem = nil
  self.pendingItemSlot = nil
  local effect = Effects.itemEffect(id)
  if effect and effect.vitamin and amount == 1 then
    M.writebackVitamin(self.game, partyIndex, id)
  end
  if effect and effect.noConsume then
    self.itemList = nil
    return true
  end
  local inventory = self.game and self.game.save and self.game.save.inventory
  if not (inventory and (inventory[id] or 0) > 0) then return false end
  inventory[id] = inventory[id] - 1
  if inventory[id] <= 0 then inventory[id] = nil end
  if self.bagSheet and self.bagSheet[id] then
    self.bagSheet[id] = self.bagSheet[id] - 1
    if self.bagSheet[id] <= 0 then self.bagSheet[id] = nil end
  end
  self.itemList = nil
  return true
end

function M:partyRows()
  local out = {}
  for i, mon in ipairs(self.mine or {}) do
    out[#out + 1] = {
      index = i,
      label = tostring(mon.species or ("#" .. i)),
      fainted = (mon.hp or 0) <= 0,
      active = i == self.active,
    }
  end
  return out
end

function M:commitItem(partyIndex, moveIndex)
  local pick = self.itemPick
  if not pick then return false end
  local effect = pick.effect or Effects.itemEffect(pick.id)
  if not effect then
    self:say("But it failed")
    self.phase = "choose"
    self.itemPick = nil
    return false
  end
  local bagCount = self.bagSheet and self.bagSheet[pick.id] or 0
  if bagCount < 1 then
    self:say("You have nothing\nto use!")
    self.phase = "choose"
    self.itemPick = nil
    return false
  end
  if not effect.noConsume then
    local inventory = self.game and self.game.save and self.game.save.inventory
    if not (inventory and (inventory[pick.id] or 0) > 0) then
      self:say("You have nothing\nto use!")
      self.phase = "choose"
      self.itemPick = nil
      return false
    end
  end
  -- Do not debit yet: wait for the hub `item` event (or clear on turn/unchose).
  self.pendingItem = pick.id
  self.pendingItemSlot = partyIndex or self.active
  local fields = { action = "item", item = pick.id }
  if partyIndex then fields.slot = partyIndex - 1 end
  if moveIndex then fields.move = moveIndex - 1 end
  self.itemPick = nil
  if not self:sendChoice(fields) then
    self.pendingItem = nil
    self.pendingItemSlot = nil
    return false
  end
  return true
end

function M:updateCommand(input)
  self.commandIndex = self.commandIndex or 1
  local moved = gridPress(self.commandIndex, #M.COMMANDS, input)
  if moved then
    self.commandIndex = moved
  elseif input:wasPressed("a") then
    local command = M.COMMANDS[self.commandIndex]
    if command == "FIGHT" then
      self.cursor = 1
      self.phase = "move"
    elseif command == "SWITCH" then
      self.switchIndex = 1
      self.phase = "switch"
    elseif command == "ITEM" then
      self.itemIndex = 1
      self.itemList = nil
      self.phase = "item"
    elseif command == "RUN" then
      if self.mode == "wild" then
        self:sendChoice({ action = "run" })
      else
        self:say("No! There's no\nrunning from a\ntrainer battle!")
        -- Still spend the turn the way Gen 1 does against trainers.
        self:sendChoice({ action = "run" })
      end
    end
  end
end

function M:updateMoveMenu(input)
  local mon = self:activeMon()
  local moves = (mon and mon.moves) or {}
  if #moves == 0 then
    self.phase = "choose"
    return
  end
  if input:wasPressed("up") then
    self.cursor = self.cursor > 1 and self.cursor - 1 or #moves
  elseif input:wasPressed("down") then
    self.cursor = self.cursor < #moves and self.cursor + 1 or 1
  elseif input:wasPressed("b") then
    self.phase = "choose"
  elseif input:wasPressed("a") then
    self:pickMove(self.cursor)
  end
end

function M:updateItemMenu(input)
  local items = self:usableItems()
  if #items == 0 then
    self:say("You have nothing\nto use!")
    self.phase = "choose"
    return
  end
  if input:wasPressed("up") then
    self.itemIndex = self.itemIndex > 1 and self.itemIndex - 1 or #items
  elseif input:wasPressed("down") then
    self.itemIndex = self.itemIndex < #items and self.itemIndex + 1 or 1
  elseif input:wasPressed("b") then
    self.phase = "choose"
  elseif input:wasPressed("a") then
    local pick = items[self.itemIndex]
    local effect = pick.effect
    self.itemPick = pick
    if not effect then
      -- Unknown bag id: still spend it and let the sim announce failure.
      self:commitItem(self.active, nil)
    elseif effect.ball or effect.pokeDoll or effect.pokeFlute then
      self:commitItem(nil, nil)
    elseif effect.activeOnly then
      self:commitItem(self.active, nil)
    elseif effect.needsMove then
      self.cursor = 1
      self.phase = "item_party"
    elseif effect.needsParty or effect.faintedOnly then
      self.switchIndex = 1
      self.phase = "item_party"
    else
      self:commitItem(self.active, nil)
    end
  end
end

function M:updateItemParty(input)
  local rows = self:partyRows()
  if #rows == 0 then
    self.phase = "item"
    return
  end
  if input:wasPressed("up") then
    self.switchIndex = self.switchIndex > 1 and self.switchIndex - 1 or #rows
  elseif input:wasPressed("down") then
    self.switchIndex = self.switchIndex < #rows and self.switchIndex + 1 or 1
  elseif input:wasPressed("b") then
    self.itemPick = nil
    self.phase = "item"
  elseif input:wasPressed("a") then
    local row = rows[self.switchIndex]
    local effect = self.itemPick and self.itemPick.effect
    if effect and effect.faintedOnly and not row.fainted then
      self:say("It won't have\nany effect.")
      return
    end
    if effect and effect.needsMove then
      self.cursor = 1
      self.itemPartyIndex = row.index
      self.phase = "item_move"
      return
    end
    self:commitItem(row.index, nil)
  end
end

function M:updateItemMove(input)
  local mon = (self.mine or {})[self.itemPartyIndex or self.active]
  local moves = (mon and mon.moves) or {}
  if #moves == 0 then
    self.phase = "item_party"
    return
  end
  if input:wasPressed("up") then
    self.cursor = self.cursor > 1 and self.cursor - 1 or #moves
  elseif input:wasPressed("down") then
    self.cursor = self.cursor < #moves and self.cursor + 1 or 1
  elseif input:wasPressed("b") then
    self.phase = "item_party"
  elseif input:wasPressed("a") then
    self:commitItem(self.itemPartyIndex or self.active, self.cursor)
  end
end

function M:updateSwitch(input)
  local rows = self:partyRows()
  local choices = {}
  for _, row in ipairs(rows) do
    -- Forced replace: active is fainted / empty, so every living mon is legal.
    if not row.fainted and (self.replaceOnly or not row.active) then
      choices[#choices + 1] = row
    end
  end
  if #choices == 0 then
    self:say("There's no one\nto switch to!")
    if not self.replaceOnly then self.phase = "choose" end
    return
  end
  if self.switchIndex > #choices then self.switchIndex = #choices end
  if input:wasPressed("up") then
    self.switchIndex = self.switchIndex > 1 and self.switchIndex - 1 or #choices
  elseif input:wasPressed("down") then
    self.switchIndex = self.switchIndex < #choices and self.switchIndex + 1 or 1
  elseif input:wasPressed("b") then
    if not self.replaceOnly then self.phase = "choose" end
  elseif input:wasPressed("a") then
    local row = choices[self.switchIndex]
    if row then
      self:sendChoice({ action = "switch", slot = row.index - 1 })
    end
  end
end

-- ------- the screen
--
-- enter/exit/update/draw is the whole of the engine's state interface, and
-- src/Ui.lua's RbyMmoState screen hands this object straight to the stack.

function M:enter()
  loadEngine()
  self:start(self.game)
end

function M:exit()
  if self.left then return end
  self.left = true
  -- Pending choice was never accepted: inventory untouched. Confirmed spends
  -- already match the hub and must not be refunded.
  self.pendingItem = nil
  self.pendingItemSlot = nil
  if self.onDone then self.onDone(self.result or "draw") end
end

function M:leave()
  if self.game and self.game.stack then
    pcall(function() self.game.stack:pop() end)
  end
end

-- Advance the message queue.  Returns true while a line is still being read,
-- which is what holds the menu closed.
function M:tickMessages(dt, input)
  -- Move flash holds the queue the way CoopBattle does: AnimPlayer when the
  -- build has battle_anims, otherwise a short dwell so the stream still paces.
  if self.anim then
    local eng = loadEngine()
    if self.animPlayer and self.animPlayer.update then
      pcall(self.animPlayer.update, self.animPlayer)
    end
    local done = true
    if self.animPlayer and self.animPlayer.isDone then
      local ok, finished = pcall(self.animPlayer.isDone, self.animPlayer)
      done = (not ok) or finished
    else
      self.dwell = self.dwell + (dt or 0)
      done = self.dwell >= 0.35
        or (input and (input:wasPressed("a") or input:wasPressed("b"))
            and self.dwell >= MSG_MIN_DWELL)
    end
    if done or (input and input:wasPressed("b") and self.dwell >= MSG_MIN_DWELL) then
      self.anim = nil
      self.dwell = 0
    end
    return true
  end

  self.dwell = self.dwell + (dt or 0)

  if self.shown == nil then
    if #self.lines == 0 then return false end
    local next = table.remove(self.lines, 1)
    if type(next) == "table" and next.anim then
      self:startAnim(next)
      self.dwell = 0
      return true
    end
    if type(next) == "table" and next.clearPic ~= nil then
      self:releasePic(next.clearPic)
      -- No dwell: the faint line ahead already held the screen. Keep ticking
      -- if more of the queue remains.
      return true
    end
    self.shown = next
    self.dwell = 0
    return true
  end

  local pressed = input
    and (input:wasPressed("a") or input:wasPressed("b"))
  if self.dwell >= MSG_AUTO_ADVANCE or (pressed and self.dwell >= MSG_MIN_DWELL) then
    self.shown = nil
    self.dwell = 0
  end
  return true
end

function M:ensureAnimPlayer()
  if self.animPlayer ~= nil then return self.animPlayer end
  local eng = loadEngine()
  local data = self.game and self.game.data
  if not (eng and eng.AnimPlayer and data and data.battle_anims) then
    self.animPlayer = false
    return nil
  end
  local ok, player = pcall(eng.AnimPlayer.new, data.battle_anims)
  self.animPlayer = (ok and player) or false
  return self.animPlayer or nil
end

function M:startAnim(row)
  self.anim = row
  local player = self:ensureAnimPlayer()
  if not (player and player.start) then
    return
  end
  -- Field slot on the wire; fall back to side so a missing slot still faces
  -- the flash the right way rather than always as the foe.
  local mine = row.slot == self:mySlot()
    or (row.side ~= nil and row.side == self.mySide)
  local ok = pcall(player.start, player, row.anim, mine)
  if not ok then self.anim = row end -- still hold briefly via dwell path
end

-- Drop a KO'd pic after its faint line (and any anim queued ahead of it).
function M:releasePic(index)
  local slot = self.slots[index]
  if not slot then return end
  slot.sprite = nil
  slot.koHold = nil
end

function M:update(dt)
  local input = self.game and self.game.input

  if self:tickMessages(dt, input) then return end

  if self.phase == "over" then
    if input and input:wasPressed("a") then self:leave() end
    return
  end

  if self.pendingTurn and not self.answeredTurn then
    if self.mustReplace then
      -- Outranks an open command menu: the seat has no active mon.
      self.pendingTurn = false
      self.replaceOnly = true
      self.switchIndex = 1
      self.phase = "switch"
      if self.autoPick then
        local rows = self:partyRows()
        for _, row in ipairs(rows) do
          if not row.fainted then
            self:sendChoice({ action = "switch", slot = row.index - 1 })
            return
          end
        end
      end
    elseif self.phase ~= "choose" and self.phase ~= "move"
       and self.phase ~= "item" and self.phase ~= "item_party"
       and self.phase ~= "item_move" and self.phase ~= "switch" then
      self.pendingTurn = false
      self.replaceOnly = false
      self.phase = "choose"
      self.commandIndex = 1
      self.cursor = 1
      if self.autoPick then
        self:pickMove(1)
        return
      end
    end
  elseif self.pendingTurn and self.answeredTurn then
    self.pendingTurn = false
  end

  if not input then return end
  if self.phase == "choose" then return self:updateCommand(input) end
  if self.phase == "move" then return self:updateMoveMenu(input) end
  if self.phase == "item" then return self:updateItemMenu(input) end
  if self.phase == "item_party" then return self:updateItemParty(input) end
  if self.phase == "item_move" then return self:updateItemMove(input) end
  if self.phase == "switch" then return self:updateSwitch(input) end
end

-- ------- drawing
--
-- Classic Gen1 1v1: foe front pic (top-right) + HUD (top-left); ally back pic
-- (bottom-left) + HUD (lower-right); message / menus in the bottom box.
-- Coordinates mirror BattleState:drawHUDs / drawPicsLayer.

local function nameX(Font, tx, name)
  local n = 8
  if Font and Font.split then
    local ok, parts = pcall(Font.split, name)
    if ok and type(parts) == "table" then n = #parts end
  else
    n = #tostring(name or "")
  end
  return tx * 8 + (n <= 2 and 16 or n <= 4 and 8 or 0)
end

function M:enemyPicXY(sprite)
  if not sprite then return CLASSIC_ENEMY.x, CLASSIC_ENEMY.y end
  local ok, w, h = pcall(sprite.getDimensions, sprite)
  if not ok then return CLASSIC_ENEMY.x, CLASSIC_ENEMY.y end
  local tw = floor(w / 8)
  local th = floor(h / 8)
  if tw < 1 then tw = 1 elseif tw > 7 then tw = 7 end
  if th < 1 then th = 1 elseif th > 7 then th = 7 end
  local hPad = floor((8 - tw) / 2)
  local vPad = 7 - th
  return 96 + 8 * hPad, 8 * vPad
end

function M:playerPicXY(sprite)
  local scale = PLAYER_PIC_SCALE
  if not sprite then return CLASSIC_PLAYER.x, CLASSIC_PLAYER.y, scale end
  local ok, w, h = pcall(sprite.getDimensions, sprite)
  if not ok then return CLASSIC_PLAYER.x, CLASSIC_PLAYER.y, scale end
  -- Same contract as BattleState.backPlacement: feet flush on y=96 at `scale`.
  local BS = engine and engine.BattleState
  if BS and BS.backPlacement then
    local x, y, s = BS.backPlacement(w, h, 0, 0, scale)
    return x, y, s
  end
  return 8, 96 - h * scale, scale
end

-- This screen resolves its own colours (same contract as CoopBattle / WideBattle).
--
-- Pics come out of BattleState.makeBattler already species-paletted, and the
-- HUD/boxes are the engine's own tiles. Without an opt-out, OG / OG INV /
-- CLASSIC invent a whole-screen GRAYS remap (PaletteFX.ensureZones) and treat
-- those coloured pixels as DMG shades -- pink paper, black outlines, solid
-- black HP bars. Game.lua reads sgbPalettes; zones() is the hook twin.
function M:sgbPalettes()
  return self:zones()
end

function M:zones()
  return { { colors = false, x = 0, y = 0, w = 160, h = 144 } }
end

function M:drawFieldPics()
  local foe = self.slots[self:foeSlot()]
  local mine = self.slots[self:mySlot()]
  love.graphics.setColor(1, 1, 1, 1)
  -- Draw while the sprite is held -- including at 0 HP through the move flash
  -- and "X fainted!". `releasePic` (after that line) is what takes it down.
  if foe and foe.sprite then
    local x, y = self:enemyPicXY(foe.sprite)
    pcall(love.graphics.draw, foe.sprite, x, y)
  end
  if mine and mine.sprite then
    -- Move / item menus replace the lower pic rows on the GB tilemap.
    local clipMenus = self.phase == "move" or self.phase == "item"
      or self.phase == "item_party" or self.phase == "item_move"
      or self.phase == "switch" or self.phase == "choose"
    local scx, scy, scw, sch
    if clipMenus and love.graphics.getScissor then
      scx, scy, scw, sch = love.graphics.getScissor()
      love.graphics.setScissor(0, 0, 160, 96)
    end
    local x, y, scale = self:playerPicXY(mine.sprite)
    scale = scale or PLAYER_PIC_SCALE
    pcall(love.graphics.draw, mine.sprite, x, y, 0, scale, scale)
    if clipMenus and love.graphics.setScissor then
      if scx then love.graphics.setScissor(scx, scy, scw, sch)
      else love.graphics.setScissor() end
    end
  end
end

function M:drawEnemyHUD(Font, HudTiles)
  local slot = self.slots[self:foeSlot()]
  -- Keep chrome up at 0 HP while the pic is still held (same rule as the
  -- player HUD): classic clears after the faint line, not on the damage tick.
  if not (slot and slot.species) then return end
  if (slot.hp or 0) <= 0 and not slot.sprite and not slot.koHold then return end
  local name = tostring(slot.species):sub(1, 10)
  love.graphics.setColor(0, 0, 0, 1)
  Font.draw(name, nameX(Font, 1, name), 0)
  if slot.status then
    Font.draw(tostring(slot.status):sub(1, 3), 40, 8)
  elseif slot.level then
    if HudTiles and HudTiles.tile then
      pcall(HudTiles.tile, 0x6E, 32, 8) -- <LV>
    end
    Font.draw(tostring(slot.level), 40, 8)
  end
  if HudTiles and HudTiles.tile then
    pcall(HudTiles.tile, 0x73, 8, 16)
    pcall(HudTiles.tile, 0x74, 8, 24)
    for i = 2, 9 do pcall(HudTiles.tile, 0x76, i * 8, 24) end
    pcall(HudTiles.tile, 0x78, 80, 24)
  end
  local shown = { hp = slot.hp, stats = { hp = slot.maxHp or 1 } }
  local drew = HudTiles and pcall(HudTiles.drawHPBar, self.game and self.game.data,
    2, 2, shown, nil, false)
  if not drew then
    love.graphics.setColor(0, 0, 0, 1)
    Font.draw(("%d/%d"):format(slot.hp, slot.maxHp or 0), 16, 16)
  end
end

function M:drawPlayerHUD(Font, HudTiles)
  local slot = self.slots[self:mySlot()]
  if not (slot and slot.species) then return end
  -- Keep the chrome up at 0 HP until the faint line finishes (classic clears
  -- after the slide); still draw name/bar at 0 so the KO is visible.
  local name = tostring(slot.species):sub(1, 10)
  love.graphics.setColor(0, 0, 0, 1)
  Font.draw(name, nameX(Font, 10, name), 56)
  if slot.status then
    Font.draw(tostring(slot.status):sub(1, 3), 120, 64)
  else
    local level = slot.level
      or (self.mine and self.mine[self.active] and self.mine[self.active].level)
    if level then
      if HudTiles and HudTiles.tile then
        pcall(HudTiles.tile, 0x6E, 112, 64)
      end
      Font.draw(tostring(level), 120, 64)
    end
  end
  local shown = { hp = slot.hp or 0, stats = { hp = slot.maxHp or 1 } }
  local drew = HudTiles and pcall(HudTiles.drawHPBar, self.game and self.game.data,
    10, 9, shown, 1, false)
  if not drew then
    love.graphics.setColor(0, 0, 0, 1)
    Font.draw(("%d/%d"):format(slot.hp or 0, slot.maxHp or 0), 88, 72)
  else
    love.graphics.setColor(0, 0, 0, 1)
    Font.draw(("%3d/%3d"):format(slot.hp or 0, slot.maxHp or 0), 88, 80)
  end
  if HudTiles and HudTiles.tile then
    pcall(HudTiles.tile, 0x73, 144, 80)
    pcall(HudTiles.tile, 0x77, 144, 88)
    for i = 10, 17 do pcall(HudTiles.tile, 0x76, i * 8, 88) end
    pcall(HudTiles.tile, 0x6F, 72, 88)
  end
end

function M:drawAnim()
  local row = self.anim
  if not (row and self.animPlayer and self.animPlayer.draw) then return end
  pcall(self.animPlayer.draw, self.animPlayer)
end

function M:drawBox(Font, text)
  Font.drawBox(0, 12, 20, 6)
  love.graphics.setColor(0, 0, 0, 1)
  local y = 112
  for line in tostring(text or ""):gmatch("[^\n]+") do
    Font.draw(line, 8, y)
    y = y + 16
  end
end

function M:drawList(Font, rows, cursor)
  Font.drawBox(0, 12, 20, 6)
  love.graphics.setColor(0, 0, 0, 1)
  local shown = min(#rows, 3)
  local first = 1
  if cursor > 3 then first = cursor - 2 end
  for i = 0, shown - 1 do
    local row = rows[first + i]
    if row then
      local label = type(row) == "table" and (row.label or row.name or row.id) or tostring(row)
      Font.draw(tostring(label):sub(1, 16), 16, 112 + i * 16)
    end
  end
  Font.drawCode(0xED, 8, 112 + (cursor - first) * 16)
end

function M:drawCommands(Font)
  -- Full-width 2x2. SWITCH shows as the two-tile PKMN mark so it does not
  -- overlap FIGHT (same columns as CoopBattle).
  Font.drawBox(0, 12, 20, 6)
  love.graphics.setColor(0, 0, 0, 1)
  for i, command in ipairs(M.COMMANDS) do
    local row = math.floor((i - 1) / 2)
    local col = (i - 1) % 2
    local x = col == 0 and 24 or 112
    local y = 112 + row * 16
    if command == "SWITCH" then
      Font.drawCode(0xE1, x, y)
      Font.drawCode(0xE2, x + 8, y)
    else
      Font.draw(command, x, y)
    end
  end
  local i = self.commandIndex or 1
  local row = math.floor((i - 1) / 2)
  local col = (i - 1) % 2
  Font.drawCode(0xED, col == 0 and 16 or 104, 112 + row * 16)
end

function M:drawMoves(Font)
  local mon = self:activeMon()
  if self.phase == "item_move" then
    mon = (self.mine or {})[self.itemPartyIndex or self.active]
  end
  local moves = (mon and mon.moves) or {}
  local rows = {}
  for _, move in ipairs(moves) do
    rows[#rows + 1] = tostring(move.id)
  end
  self:drawList(Font, rows, self.cursor)
end

function M:drawSafe()
  -- Fill first so a missing Font still covers the frame; without isOpaque the
  -- stack would otherwise leave the overworld visible at the top of the view.
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.rectangle("fill", 0, 0, 160, 144)

  local eng = loadEngine()
  if not (eng and eng.Font) then return end
  local Font = eng.Font
  local HudTiles = eng.HudTiles

  self:drawFieldPics()
  self:drawEnemyHUD(Font, HudTiles)
  self:drawPlayerHUD(Font, HudTiles)
  self:drawAnim()

  if self.shown then
    return self:drawBox(Font, self.shown)
  end
  if self.anim then
    return self:drawBox(Font, "")
  end
  if self.phase == "choose" then
    return self:drawCommands(Font)
  end
  if self.phase == "move" or self.phase == "item_move" then
    return self:drawMoves(Font)
  end
  if self.phase == "item" then
    return self:drawList(Font, self:usableItems(), self.itemIndex or 1)
  end
  if self.phase == "item_party" then
    local rows = {}
    for _, row in ipairs(self:partyRows()) do
      rows[#rows + 1] = row.label .. (row.fainted and " *" or "")
    end
    return self:drawList(Font, rows, self.switchIndex or 1)
  end
  if self.phase == "switch" then
    local rows = {}
    for _, row in ipairs(self:partyRows()) do
      if not row.fainted and (self.replaceOnly or not row.active) then
        rows[#rows + 1] = row.label
      end
    end
    return self:drawList(Font, rows, self.switchIndex or 1)
  end
  if self.phase == "setup" then
    return self:drawBox(Font, "Getting ready...")
  end
  self:drawBox(Font, ("Waiting for\n%s..."):format(self.peerName))
end

function M:draw()
  local ok, err = pcall(self.drawSafe, self)
  if ok then return end
  if self.drawFailed then return end
  self.drawFailed = true
  mod.log:error("the mediated battle screen failed to draw (%s); the fight is "
    .. "still running and can be finished blind, but report this", tostring(err))
end

return M
