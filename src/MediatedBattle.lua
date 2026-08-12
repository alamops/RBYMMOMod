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
-- The screen draws a classic Gen1 1v1 field on Gen2 / when Battlefield is
-- off: foe front pic + top-left HUD, ally back pic + bottom HUD, message box,
-- optional AnimPlayer. On Gen1 with Battlefield.enabled, presentation is the
-- top-down arena theatre (640×360 fill) from src/Battlefield.lua. Co-op still
-- owns the four-slot renderer.

local need, mod = ...
local Config = need("Config")
local Wire = need("Wire")
local Effects1 = need("BattleSim/Effects")
local Gen = need("Gen")
local Battlefield = need("Battlefield")

local M = {}
M.__index = M

local floor, max, min = math.floor, math.max, math.min

-- BattleSim vs BattleSim2 item tables — vitamins already gen-switched;
-- bag upload / ball hints must match the hub sim generation too.
local Effects2
local function effectsFor(game)
  if Gen.generation(game) == 2 then
    if not Effects2 then Effects2 = need("BattleSim2/Effects") end
    return Effects2
  end
  return Effects1
end
-- Back-compat alias for any leftover Effects.* call sites in this file.
local Effects = setmetatable({}, {
  __index = function(_, k)
    return Effects1[k]
  end,
})

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
  -- Optional SFX / music. Missing Sound or Music must not fail the whole
  -- load — headless / no-audio builds still fight without them.
  do
    local good, value = pcall(require, "src.core.Sound")
    if good then engine.Sound = value end
  end
  do
    local good, value = pcall(require, "src.core.Music")
    if good then engine.Music = value end
  end
  return engine
end

M.loadEngine = loadEngine

-- Classic 1v1 anchors (AnimPlayer / BattleState pic windows).
-- Ally back pics draw at 2x on Gen 1 (32×32); Gen 2 backs are 48×48 at 1x.
local CLASSIC_PLAYER = { x = 8, y = 40 }
local CLASSIC_ENEMY = { x = 88, y = 0 }
local PLAYER_PIC_SCALE_GEN1 = 2
local PLAYER_PIC_SCALE_GEN2 = 1
M.PLAYER_PIC_SCALE = PLAYER_PIC_SCALE_GEN1
M.CLASSIC_PLAYER = CLASSIC_PLAYER
M.CLASSIC_ENEMY = CLASSIC_ENEMY

local function playerPicScale(game)
  if Gen.generation(game) == 2 then return PLAYER_PIC_SCALE_GEN2 end
  return PLAYER_PIC_SCALE_GEN1
end

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

-- Battle stats for the wire sheet.
--
-- Gen 1: atk/def/spd/spc (engine attack/defense/speed/special). SPC is one
-- stat — Special did not split until Gen 2.
-- Gen 2: atk/def/spe/spa/spd from specialAttack/specialDefense (or spa/spd
-- aliases) with Speed as `spe`.
--
-- Clamped rather than refused, which is the opposite of what Wire does with the
-- same numbers and is right on this side of the boundary: Wire is judging a
-- stranger's claim and a number out of range there means the sender is not to
-- be believed, while here the number is our own truth and the only alternative
-- to trimming it is uploading a party the far end throws away whole -- a
-- player losing a fight they never got to start, over a stat nothing can fight
-- with anyway.
local function statsOf(mon, generation)
  local stats = type(mon.stats) == "table" and mon.stats or nil
  if not stats then return nil end
  if generation == 2 then
    local spa = stats.specialAttack or stats.spa or stats.special
    local spDef = stats.specialDefense or stats.spd or stats.special
    return {
      atk = clamp(intOr(stats.attack, 1), 1, Wire.STAT_MAX),
      def = clamp(intOr(stats.defense, 1), 1, Wire.STAT_MAX),
      spe = clamp(intOr(stats.speed, 1), 1, Wire.STAT_MAX),
      spa = clamp(intOr(spa, 1), 1, Wire.STAT_MAX),
      spd = clamp(intOr(spDef, 1), 1, Wire.STAT_MAX),
    }
  end
  return {
    atk = clamp(intOr(stats.attack, 1), 1, Wire.STAT_MAX),
    def = clamp(intOr(stats.defense, 1), 1, Wire.STAT_MAX),
    spd = clamp(intOr(stats.speed, 1), 1, Wire.STAT_MAX),
    spc = clamp(intOr(stats.special, 1), 1, Wire.STAT_MAX),
  }
end

-- A full set of the dialect's keys or nothing at all, on Wire's own rule: a
-- snapshot from a client that does not track DVs is ordinary, while one
-- carrying two of the required keys is a bug on this side that the far end
-- would silently zero the rest of.
--
-- Gen 2 DVs / Stat Exp still use one `special` word (engine gen2 Mon); both
-- spa and spd on the wire are fed from that single engine field.
local function sheetOf(raw, low, high, generation)
  if type(raw) ~= "table" then return nil end
  local out = {}
  if generation == 2 then
    local keys = {
      atk = "attack", def = "defense", spe = "speed",
      spa = "special", spd = "special",
    }
    for wireKey, engineKey in pairs(keys) do
      local n = tonumber(raw[engineKey])
      if wireKey == "spa" and (not n or n ~= n) then
        n = tonumber(raw.specialAttack)
      end
      if wireKey == "spd" and (not n or n ~= n) then
        n = tonumber(raw.specialDefense or raw.special)
      end
      if not n or n ~= n then return nil end
      out[wireKey] = clamp(floor(n), low, high)
    end
  else
    local keys = { atk = "attack", def = "defense", spd = "speed", spc = "special" }
    for wireKey, engineKey in pairs(keys) do
      local n = tonumber(raw[engineKey])
      if not n or n ~= n then return nil end
      out[wireKey] = clamp(floor(n), low, high)
    end
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
  local generation = Gen.generation(game)

  local out = {}
  for index = 1, #party do
    if #out >= Config.BATTLE_MON_MAX then break end
    local mon = party[index]
    if type(mon) == "table" then
      local stats = statsOf(mon, generation)
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
          local sheet = {
            species = species,
            -- Registry id for battle art (local only; the wire keeps `species`
            -- as the display / nickname token the sim narrates under).
            speciesId = mon.species,
            level   = clamp(intOr(mon.level, 1), 1, Wire.LEVEL_MAX),
            hp      = clamp(intOr(mon.hp, maxHp), 0, maxHp),
            maxHp   = maxHp,
            stats   = stats,
            generation = generation,
            -- The engine spells a condition with the same three-letter token
            -- the wire does ("SLP", "PSN", ...), so this passes through rather
            -- than being translated.  nil is healthy and is a real answer.
            status  = Wire.battleStatus(mon.status) or nil,
            slot    = clamp(index - 1, 0, Wire.SLOT_MAX),
            ivs     = sheetOf(mon.dvs, 0, 15, generation),
            evs     = sheetOf(mon.statExp, 0, 65535, generation),
            types   = typesOf(data, mon, order),
            moves   = moves,
          }
          -- Gen 2 held item (engine field `item`). Optional; Wire.id cleans it.
          if generation == 2 and type(mon.item) == "string" and mon.item ~= "" then
            local held = Wire.id(mon.item)
            if held then sheet.heldItem = held end
          end
          out[#out + 1] = sheet
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
  -- Party-level generation when every mon agrees (Wire prefers this, then shape).
  local gen = mons[1] and mons[1].generation
  if gen == 1 or gen == 2 then
    local same = true
    for i = 2, #mons do
      if mons[i].generation ~= gen then same = false; break end
    end
    if same then msg.generation = gen end
  end
  transport:send(Wire.BATTLE_PARTY, msg)
  return true
end

-- The badges this player has earned, as a list for the wire.
--
-- Read off the badge *rows* rather than off a list written down here, so a mod
-- that adds a badge -- or retunes which ones boost what -- is covered without
-- this file knowing about it.
--
-- MK403: never hard-require Gen 1 `src.battle.Damage` on Gold. Prefer
-- `data.constants.badgeBoosts`, then a soft Gen 2 Damage/Battle module, then
-- Gen 1 Damage only on a Gen 1 boot; missing rows soft-degrade to no badges.
function M.badgesOf(game)
  local data = game and game.data
  local save = game and game.save
  if not (data and save) then return nil end

  local rows = data.constants and data.constants.badgeBoosts
  if not rows then
    local generation = Gen.generation(game)
    if generation == 2 then
      -- Gen 2 Damage has no BADGE_BOOSTS twin; Battle.BADGE_TYPE_BOOSTS names
      -- every Johto/Kanto badge for ownership checks.
      local ok, Battle = pcall(require, "src.battle.gen2.Battle")
      if ok and Battle and type(Battle.BADGE_TYPE_BOOSTS) == "table" then
        rows = Battle.BADGE_TYPE_BOOSTS
      else
        local okD, Damage = pcall(require, "src.battle.gen2.Damage")
        rows = okD and Damage and Damage.BADGE_BOOSTS or nil
      end
    else
      -- Concat so gen2check does not treat this as a hard Gen1 Damage site
      -- on a Gold boot (MK403); this arm only runs when generation ~= 2.
      local ok, Damage = pcall(require, table.concat({ "src", "battle", "Damage" }, "."))
      rows = ok and Damage and Damage.BADGE_BOOSTS or nil
    end
  end
  if not rows then return nil end

  local inventory = save.inventory or {}
  local playerBadges = save.player and save.player.badges
  local out, seen = {}, {}
  for _, row in ipairs(rows) do
    local id = row.badge
    if id and not seen[id] then
      local has = inventory[id]
      if not has and type(playerBadges) == "table" then
        has = playerBadges[id]
      end
      if has then
        seen[id] = true
        out[#out + 1] = id
      end
    end
  end
  if #out == 0 then return nil end
  return out
end

-- Battle-usable stacks from the local save, for the hub bag proof.
-- Only ids BattleSim knows (`itemEffect`); vitamins included (fight-local EV).
-- Truncated to BATTLE_BAG_MAX so the menu and the upload stay the same set.
function M.itemIsBattleUsable(id, game)
  if type(id) ~= "string" or id == "" then return nil end
  local effect = effectsFor(game).itemEffect(id)
  if not effect then return nil end
  local items = (game and game.data and game.data.items) or {}
  local def = items[id]
  if effect.pokeFlute or effect.noConsume then return effect end
  if def and (def.key or def.machine) then return nil end
  return effect
end

-- Engine save.statExp keys for BattleSim vitaminStat tokens.
-- Gen 1 wire: spd/spc. Gen 2 wire: spe/spa (BattleSim2). Engine gen2 Mon still
-- stores one Special Stat Exp word (`special`) that feeds both SpA and SpD.
local VITAMIN_SAVE_KEY = {
  hp = "hp", atk = "attack", def = "defense",
  spd = "speed", spc = "special",
  spe = "speed", spa = "special",
}

-- Live mon.stats field updated after a vitamin, by generation.
-- Gen 2 has no single `special` battle stat — write specialAttack (Calcium)
-- or the matching physical/speed field; SpD shares Special Stat Exp so both
-- specials are refreshed when spa is applied via Mon.stats when available.
local function vitaminLiveKeys(wireStat, generation)
  if wireStat == "hp" then return { "hp" } end
  if generation == 2 then
    if wireStat == "atk" then return { "attack" } end
    if wireStat == "def" then return { "defense" } end
    if wireStat == "spe" then return { "speed" } end
    -- spa (Calcium) / legacy spc: one Special Stat Exp word feeds both SpA/SpD.
    if wireStat == "spa" or wireStat == "spc" or wireStat == "spd" then
      return { "specialAttack", "specialDefense" }
    end
  end
  if wireStat == "atk" then return { "attack" } end
  if wireStat == "def" then return { "defense" } end
  if wireStat == "spd" or wireStat == "spe" then return { "speed" } end
  if wireStat == "spc" or wireStat == "spa" then return { "special" } end
  return nil
end

-- Write vitamin Stat Exp onto save.party[partyIndex] (1-based).
-- Fight-local sheet mutation is the hub's job; permanence is the client's.
-- Only call after an `item` event with amount=1 (vitamin applied).
function M.writebackVitamin(game, partyIndex, itemId)
  -- Gen 2 resolves vitamins via BattleSim2/Effects only (spa/spe tokens);
  -- Gen 1 stays on BattleSim/Effects. Never try Gen1 Effects first on Gen2.
  local EffectsMod = Effects
  if Gen.generation(game) == 2 then
    local ok2, Effects2 = pcall(function() return need("BattleSim2/Effects") end)
    if ok2 and Effects2 and Effects2.itemEffect then
      EffectsMod = Effects2
    else
      return false
    end
  end
  local effect = EffectsMod.itemEffect(itemId)
  local wireStat = effect and effect.vitaminStat
  local saveKey = wireStat and VITAMIN_SAVE_KEY[wireStat]
  if not saveKey then return false end
  local party = game and game.save and game.save.party
  local mon = party and party[partyIndex]
  if type(mon) ~= "table" then return false end
  mon.statExp = mon.statExp or {}
  local before = math.max(0, math.floor(tonumber(mon.statExp[saveKey]) or 0))
  if before >= EffectsMod.VITAMIN_FAIL_AT then return false end
  local after = math.min(65535, before + EffectsMod.VITAMIN_GAIN)
  mon.statExp[saveKey] = after

  local generation = Gen.generation(game)
  -- Recalc live battle stats / max HP so the party screen does not lag.
  local oldMax = tonumber(mon.stats and mon.stats.hp) or tonumber(mon.hp) or 0
  local level = math.max(1, math.floor(tonumber(mon.level) or 1))
  local applied = false
  local def = game.data and game.data.pokemon and game.data.pokemon[mon.species]
  if generation == 2 then
    local okMon, Mon2 = pcall(require, "src.battle.gen2.Mon")
    if okMon and Mon2 and type(Mon2.stats) == "function"
       and type(def) == "table" and type(def.baseStats) == "table" then
      local ok, stats = pcall(Mon2.stats, def.baseStats, mon.dvs or {}, level,
        mon.statExp)
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
  else
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
      local liveKeys = vitaminLiveKeys(wireStat, generation) or { saveKey }
      for _, liveKey in ipairs(liveKeys) do
        local curStat = math.max(1, math.floor(tonumber(mon.stats[liveKey]) or 1))
        mon.stats[liveKey] = math.max(1, curStat + delta)
      end
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

-- ------- display clock (Battlefield arena only)
--
-- Two clocks, the engine's own: `slot.hp` is the referee's number and lands
-- the instant an event says so, and `slot.shownHp` is the number the arena
-- plates are drawn from.  The gap between the two *is* the animation, and it
-- is closed only by a queued row -- so nothing on screen can jump ahead of
-- the line that explains it.
--
-- None of this exists on the classic 160x144 path or on Gen2: those HUDs read
-- `slot.hp` straight and have no renderer for an effect, so a display clock
-- there would animate nothing and only cost the queue rows.  Every emitter
-- below is gated on `usesBattlefield()`.

-- Effect lifetimes in seconds.  `lunge` is held to the battlefield anim dwell
-- in tickMessages (0.35) so an attacker's lean is never cut off half way.
local FX_SPAN = {
  lunge = 0.35,
  flash = 0.30,
  shake = 0.25,
  faint = 0.60,
  spawn = 0.40,
  -- The ball flow. One constant per kind, and each one is also the dwell the
  -- queued row that emits it is held for -- the row *is* the effect, so a
  -- throw that outlives its row would be cut off by the next line and a row
  -- that outlives its throw would stall the fight on a finished animation.
  recall = 0.35, -- HIDEPIC: the monster shrinks into the ball
  ball   = 0.60, -- TOSS / GREATTOSS / ULTRATOSS: the arc
  wobble = 0.70, -- SHAKE: one rock, one per shake the referee counted
  poof   = 0.45, -- POOF / SHOWPIC: the burst, and what comes out of it
}

-- The engine's ball markers, and what each one is on the arena. Ball ids vary
-- with the ball (`_emitBallChain` in BattleSim/Turn.lua picks the toss by item),
-- so the toss is listed three times rather than pattern-matched.
local BALL_FX = {
  TOSS_ANIM      = "ball",
  GREATTOSS_ANIM = "ball",
  ULTRATOSS_ANIM = "ball",
  HIDEPIC_ANIM   = "recall",
  SHAKE_ANIM     = "wobble",
  POOF_ANIM      = "poof",
  SHOWPIC_ANIM   = "poof",
}

-- The kinds that mean "this seat is inside the ball". Held at t == 1 the way a
-- faint sink is (see stepFx): the queue leaves a frame or two between one row
-- ending and the next starting, and a monster that flickered back into view in
-- that gap would be out of the ball and in it again twice a throw.
local BALL_HIDE_FX = { ball = true, recall = true, wobble = true }

-- Most wobbles one SHAKE row is allowed to spend. Gen 1 counts three; the
-- number came off the wire, and a hub claiming a thousand would otherwise
-- queue a thousand rows the player cannot skip past.
local BALL_SHAKE_MAX = 8

-- The bar's *rate*, not its duration: `max(1, maxHp / 96)` a frame is what the
-- engine uses (BattleState's HP drain) and what CoopBattle's twin uses, so a
-- big monster empties over about a second and a half and a small one -- whose
-- 96th of a bar is under a point -- falls at the engine's one-HP-a-frame floor
-- instead of crawling.  The budget is the second half of that: a step that
-- loses its last fraction to floating point would never land on `to` exactly,
-- and a drain is deliberately unskippable -- so one that overruns a whole
-- descent is snapped home rather than left holding the queue forever.
local DRAIN_FRAMES = 96
local DRAIN_BUDGET = 120

-- How many 60Hz frames one update covers.  In game this is always 1 (the
-- engine's step is fixed at 1/60); the headless suite drives whole seconds at
-- a time and has to land on the far end of a drain rather than wedge on it.
local function frameCount(dt)
  local n = floor((tonumber(dt) or 0) * 60 + 0.5)
  if n < 1 then return 1 end
  if n > DRAIN_BUDGET then return DRAIN_BUDGET end
  return n
end

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

    phase     = "setup",   -- setup | play | choose | move | target | item | item_party | item_move | switch | over
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
    -- Gen1 Battlefield theatre (top-down arena). Unused on Gen2 / when
    -- Battlefield.enabled is false.
    frame = 0,
    -- Display clock, arena only. `fx` is the list Battlefield renders from;
    -- `draining` / `faintFx` are the two states that hold the message queue
    -- while the bar falls and the monster after it. All three stay nil until
    -- something is actually playing.
    fx = nil,
    draining = nil,
    faintFx = nil,
    -- #36: the fanfare finish() parked because the arena still owed one of those.
    victoryMusicHeld = nil,
    battlefieldLoaded = false,
    battlefieldBubbles = nil, -- { { side, humanIndex, text, born }, ... }
    targetIndex = 1,          -- field cursor when a target list exists
  }, M)
end

-- ------- Gen1 Battlefield theatre gate
--
-- Hard-cut on Gen1 when Battlefield.enabled(game): wide fill canvas + arena
-- draw. Gen2 (and any generation that fails the gate) keeps the classic
-- 160×144 side-view path below untouched.

local BUBBLE_LIFE = 90

function M:usesBattlefield()
  return Battlefield.enabled(self.game)
end

function M:isWideBattleLayout()
  return self:usesBattlefield()
end

function M:uiSize()
  if self:usesBattlefield() then
    return Battlefield.WIDTH, Battlefield.HEIGHT
  end
  return 160, 144
end

function M:wantsFillScale()
  return self:usesBattlefield()
end

function M:ensureBattlefield()
  if self.battlefieldLoaded then return end
  self.battlefieldLoaded = true
  pcall(Battlefield.reloadArena)
  pcall(Battlefield.load, mod)
end

-- Soft: local OW sprite id from mod save/options (same sources Client uses).
local function selfSpriteId()
  local ok, id = pcall(function()
    local chosen = mod.save and mod.save:get("sprite")
    if type(chosen) ~= "string" or chosen == "" then
      chosen = mod.options and mod.options:get("sprite")
    end
    if type(chosen) ~= "string" or chosen == "" then return nil end
    local Chars = need("Chars")
    if Chars and Chars.resolve then return Chars.resolve(chosen) end
    return chosen
  end)
  if ok and type(id) == "string" and id ~= "" then return id end
  return nil
end

-- Soft: peer OW sprite from the live roster export, if any.
local function peerSpriteId(peerId)
  if peerId == nil then return nil end
  local ok, players = pcall(function()
    return mod.exports and mod.exports.players and mod.exports.players()
  end)
  if not (ok and type(players) == "table") then return nil end
  for _, row in ipairs(players) do
    if type(row) == "table" and row.id == peerId
        and type(row.sprite) == "string" and row.sprite ~= "" then
      return row.sprite
    end
  end
  return nil
end

local function playerName(game)
  local name = game and game.save and game.save.player and game.save.player.name
  if type(name) == "string" and name ~= "" then return name end
  return "YOU"
end

-- Bag icon for a field seat. Soft-fail to nil; Battlefield draws a stand-in.
function M:seatIcon(speciesKey, monHint)
  if type(speciesKey) ~= "string" or speciesKey == "" then return nil end
  local data = self.game and self.game.data
  if not data then return nil end
  local eng = loadEngine()
  local Sprites = eng and eng.Sprites
  local icons = data.icons
  local def = data.pokemon and data.pokemon[speciesKey]
  local mon = monHint or { species = speciesKey }
  local path, name
  pcall(function()
    local entry = (icons and icons.bySpecies and icons.bySpecies[speciesKey])
      or (def and def.icon)
    if type(entry) == "string" then
      name = entry
      path = icons and icons.icons and icons.icons[entry]
    elseif type(entry) == "table" then
      path = entry.image
    end
    if not path and def and def.dex and icons and icons.byDex then
      name = icons.byDex[def.dex]
      path = name and icons.icons and icons.icons[name]
    end
    if Sprites and Sprites.iconPath then
      path = Sprites.iconPath(data, mon, path, { name = name })
    end
  end)
  if type(path) ~= "string" or path == "" then return nil end
  local ok, img = pcall(function()
    local Assets = require("src.render.Assets")
    if Assets and Assets.image then return Assets.image(path) end
    return love.graphics.newImage(path)
  end)
  if ok then return img end
  return nil
end

-- Battle FRONT pic for the arena (player slots hold backs in classic 1v1).
function M:seatFront(speciesKey, monHint, slot)
  if type(speciesKey) ~= "string" or speciesKey == "" then return nil end
  if slot and slot._bfFront ~= nil and slot._bfFrontSpecies == speciesKey then
    local cached = slot._bfFront
    return (cached ~= false) and cached or nil
  end
  local resolved = nil
  local eng = loadEngine()
  local data = self.game and self.game.data
  local save = self.game and self.game.save
  local mon = monHint
  if (not mon or not mon.species) and data then
    mon = { species = speciesKey, level = (monHint and monHint.level) or 5 }
  end
  if eng and eng.BattleState and eng.BattleState.makeBattler and mon and data then
    local ok, probe = pcall(eng.BattleState.makeBattler, data, mon, false, save)
    if ok and probe and probe.sprite then resolved = probe.sprite end
  end
  if slot then
    slot._bfFront = resolved or false
    slot._bfFrontSpecies = speciesKey
  end
  return resolved
end

-- One Battlefield seat from a live field slot (player or foe active).
function M:battlefieldSeat(slotIndex, isPlayer)
  local slot = self.slots[slotIndex]
  if not slot or not slot.species then return nil end
  -- Keep KO'd seats until releasePic clears the sprite, matching classic hold.
  -- A seat whose display clock has not caught up is still falling: dropping it
  -- here would take the bar off the arena in the middle of its own drain.
  if (slot.hp or 0) <= 0 and not slot.sprite and not slot.koHold
      and (slot.shownHp or 0) <= 0 then
    return nil
  end
  local monHint = nil
  if isPlayer then monHint = self.mine and self.mine[self.active] end
  local key = self:speciesKeyFor(slot.species, isPlayer) or slot.species
  local acting = false
  if self.anim and self.anim.slot == slotIndex then acting = true end
  local icon = slot.icon
  if icon == nil then
    icon = self:seatIcon(key, monHint and {
      species = monHint.speciesId or key,
      hp = slot.hp,
    } or { species = key })
    slot.icon = icon or false
  elseif icon == false then
    icon = nil
  end
  local frontMon = monHint
  if not frontMon then
    frontMon = {
      species = key,
      level = slot.level or 5,
      hp = slot.hp,
      maxHp = slot.maxHp,
    }
  elseif not frontMon.species then
    frontMon = {
      species = frontMon.speciesId or key,
      level = frontMon.level or slot.level or 5,
      hp = slot.hp,
      maxHp = slot.maxHp,
    }
  end
  local front = self:seatFront(key, frontMon, slot) or slot.sprite
  return {
    index = slotIndex,
    name = slot.species,
    level = slot.level or (monHint and monHint.level) or 1,
    hp = slot.hp or 0,
    -- Display clock. Battlefield falls back to `hp` when this is absent, so a
    -- seat that never drained reads exactly as it did before.
    shownHp = self:shownHpOf(slot),
    maxHp = slot.maxHp or 1,
    status = slot.status,
    species = key,
    icon = icon,
    front = front,
    acting = acting,
  }
end

function M:pruneBattlefieldBubbles()
  local list = self.battlefieldBubbles
  if type(list) ~= "table" then return end
  local frame = self.frame or 0
  local kept = {}
  for _, b in ipairs(list) do
    if type(b) == "table" then
      local born = tonumber(b.born) or 0
      local age = frame - born
      if age < BUBBLE_LIFE then
        local t = 1 - (age / BUBBLE_LIFE)
        kept[#kept + 1] = {
          side = b.side,
          humanIndex = b.humanIndex or 1,
          text = b.text,
          -- Optional, and only on a move callout: the renderer emphasises it.
          moveName = b.moveName,
          t = t,
          born = born,
        }
      end
    end
  end
  self.battlefieldBubbles = (#kept > 0) and kept or nil
end

-- Trainer callout when a human-owned mon acts. Never for the wild foe.
function M:noteBattlefieldBubble(row)
  if not self:usesBattlefield() then return end
  if type(row) ~= "table" then return end
  local anim = row.anim
  if type(anim) ~= "string" or anim == "" then return end
  -- Engine ball / hide / shake markers are not move callouts.
  if anim:find("_ANIM", 1, true) then return end

  -- The label a player would read in "X used Y!". The raw id stays the bubble's
  -- text so nothing that reads it changes meaning; `moveName` is the part the
  -- renderer is allowed to emphasise, and is the id again when the build has no
  -- record for the move (a modded move whose definition did not survive).
  local moveName = self:moveLabel(anim)

  local mine = row.slot == self:mySlot()
    or (row.side ~= nil and row.side == self.mySide)
  if not mine then
    if self.mode == "wild" then return end
    self.battlefieldBubbles = {{
      side = "foe",
      humanIndex = 1,
      text = anim,
      moveName = moveName,
      born = self.frame or 0,
    }}
    return
  end
  self.battlefieldBubbles = {{
    side = "ally",
    humanIndex = 1,
    text = anim,
    moveName = moveName,
    born = self.frame or 0,
  }}
end

-- A move's display name, CoopBattle's lookup: the registry name when the build
-- has one, the wire id otherwise.
function M:moveLabel(id)
  if type(id) ~= "string" or id == "" then return nil end
  local moves = self.game and self.game.data and self.game.data.moves
  local def = type(moves) == "table" and moves[id] or nil
  local name = def and def.name
  if type(name) == "string" and name ~= "" then return name end
  return id
end

-- Living foe seats for a field cursor (1v1 has exactly one).
function M:battlefieldTargets()
  local foe = self:battlefieldSeat(self:foeSlot(), false)
  if not foe then return {} end
  if (foe.hp or 0) <= 0 and not foe.front then return {} end
  return { foe }
end

function M:battlefieldCtx()
  local mode = (self.mode == "wild") and "wild" or "1v1"
  local allyHumans = {{
    id = "self",
    name = playerName(self.game),
    spriteId = selfSpriteId(),
  }}
  local foeHumans = {}
  if mode == "1v1" then
    foeHumans[1] = {
      id = self.peerId,
      name = self.peerName or "FRIEND",
      spriteId = peerSpriteId(self.peerId),
    }
  end

  local ally = self:battlefieldSeat(self:mySlot(), true)
  local foe = self:battlefieldSeat(self:foeSlot(), false)
  local allySeats = ally and { ally } or {}
  local foeSeats = foe and { foe } or {}

  -- Target card: show while picking FIGHT / moves. 1v1 has no multi-target
  -- picker, but the card still lands on the lone foe.
  local targets, targetIndex = nil, nil
  local showTarget = false
  if self.phase == "move" then
    showTarget = true
  elseif self.phase == "choose" and M.COMMANDS[self.commandIndex or 1] == "FIGHT" then
    showTarget = true
  elseif self.phase == "target" then
    showTarget = true
  end
  if showTarget then
    targets = self:battlefieldTargets()
    if #targets > 0 then
      targetIndex = self.targetIndex or 1
      if targetIndex < 1 or targetIndex > #targets then targetIndex = 1 end
      self.targetIndex = targetIndex
    end
  end

  local frame = self.frame
  if not frame or frame == 0 then
    local ok, t = pcall(function()
      return love and love.timer and love.timer.getTime() * 60
    end)
    frame = (ok and t) or 0
  end

  self:pruneBattlefieldBubbles()

  return {
    mode = mode,
    allyHumans = allyHumans,
    foeHumans = foeHumans,
    allySeats = allySeats,
    foeSeats = foeSeats,
    targets = targets,
    targetIndex = targetIndex,
    showTarget = showTarget,
    frame = frame,
    bubbles = self.battlefieldBubbles,
    -- One direction only: this screen advances `t`, Battlefield draws whatever
    -- `t` says. Absent when nothing is playing -- the renderer tolerates that.
    fx = self.fx,
  }
end

-- Classic 160×144 chrome drawn into Battlefield.MENU_BAND at the bottom.
-- Scissor matches CoopBattle.drawMenuBand: clip chrome to the menu band only.
function M:withMenuBand(drawFn)
  local g = love and love.graphics
  if not (g and g.push) then
    pcall(drawFn)
    return
  end
  local bandY = Battlefield.FIELD_BOTTOM
  local band = Battlefield.MENU_BAND
  local classicBox = 48 -- Font.drawBox(0, 12, 20, 6) occupies y=96..144
  g.push()
  g.translate(0, bandY)
  g.scale(Battlefield.WIDTH / 160, band / classicBox)
  g.translate(0, -96)
  if g.setScissor then
    local prev = { g.getScissor() }
    g.setScissor(0, bandY, Battlefield.WIDTH, band)
    pcall(drawFn)
    if prev[1] then
      g.setScissor(prev[1], prev[2], prev[3], prev[4])
    else
      g.setScissor()
    end
  else
    pcall(drawFn)
  end
  g.pop()
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
    -- `amount` is shake count on SHAKE_ANIM; ball id is stashed from `item`.
    if msg.text then
      self.lines[#self.lines + 1] = {
        anim = msg.text, slot = msg.slot, side = msg.side, amount = msg.amount,
      }
    end

  elseif kind == "send" or kind == "switch" then
    -- The first HP we are told about is a full bar: the sim sends this the
    -- moment a monster comes out, so the number is that monster's maximum
    -- unless it walked in already hurt.  It is the only handle on a foe's
    -- maximum there is -- an event carries current HP and nothing else -- so
    -- the largest value ever seen is what the bar is drawn against.
    self:noteSlot(msg)
    -- A monster arriving pops onto the field rather than blinking into it --
    -- queued, like every other effect, so the pop plays with the send line
    -- rather than the instant the packet was parsed.
    self:queueSpawnFx(msg.slot, msg.side)
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
    -- Truth first, then the bar. `syncMineHp` keeps the party sheet on the
    -- referee's number -- partyRows / mustReplace read it and must never see
    -- a display clock.
    self:noteSlot(msg)
    self:syncMineHp(msg)
    -- The flash and the field's nudge are not emitted here: a resolved turn
    -- arrives as one batch, so both seats would jolt in the same frame, ahead
    -- of the text that explains either. `startDrain` fires them when the bar
    -- this row queued actually starts falling.
    self:queueDrain(msg.slot)

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
    -- Arena order, which is the engine's: the bar finishes falling, then the
    -- monster sinks, and only then does the line print. Both rows block the
    -- queue while they play; neither exists on the classic path, where the
    -- faint line still comes straight after the event.
    self:queueDrain(msg.slot)
    self:queueFaintFx(msg.slot)
    if msg.text then self:say(("%s fainted!"):format(msg.text)) end
    -- After the faint line has been read (and any anim still ahead of it in
    -- `lines` has played), drop the pic. Queued behind the say so the KO stays
    -- on screen through the flash + "X fainted!". Stamped with its occupant
    -- for the same reason the drain row is: an auto-replacement batched behind
    -- the KO would otherwise have this row take the newcomer's pic down.
    self.lines[#self.lines + 1] = { clearPic = msg.slot, species = slot and slot.species }

  elseif kind == "status" then
    self:noteSlot(msg)

  elseif kind == "item" then
    -- Debit only once the hub has accepted and resolved the item choice.
    -- Spending on send left a soft-lock when the bag proof refused: phase
    -- "play", item gone, no `chose`.
    if msg.slot == self:mySlot() then
      self:confirmPendingItem(msg.text, msg.amount)
    end
    -- Ball id for AnimPlayer opts on the following toss/shake chain.
    local effect = msg.text and effectsFor(self.game).itemEffect(msg.text)
    if effect and effect.ball then self.medBall = msg.text end

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
    -- Keep medBall through the queued toss/shake anims (they drain after turn).

  elseif kind == "over" then
    -- The field is done; the outcome is a separate message and is what this
    -- screen actually ends on.
    self.pendingTurn = false
    self.answeredTurn = false
    self.mustReplace = false
    self.replaceOnly = false
    self.pendingItem = nil
    self.pendingItemSlot = nil
    self.medBall = nil
    self.foePicHidden = nil

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
           or self.phase == "target"
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
  local fresh = false
  if msg.text and (msg.t == "send" or msg.t == "switch") then
    slot.species = msg.text
    slot.sprite = nil
    slot.icon = nil
    slot.koHold = nil
    fresh = true
  end
  if msg.hp ~= nil then
    slot.hp = msg.hp
    if msg.hp > slot.maxHp then slot.maxHp = msg.hp end
  elseif msg.amount ~= nil and msg.t == "damage" then
    slot.hp = max(0, slot.hp - msg.amount)
  end
  -- Seed the display clock, or keep it welded to truth where nothing draws
  -- from it. A monster that just walked on has nothing to animate down from,
  -- so its bar starts where the referee says it is.
  if slot.shownHp == nil or fresh or not self:usesBattlefield() then
    slot.shownHp = slot.hp
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
  local data = self.game and self.game.data
  if not data then
    slot.sprite = nil
    return
  end
  local key = self:speciesKeyFor(slot.species, isPlayer)
  if not key or not data.pokemon or not data.pokemon[key] then
    slot.sprite = nil
    return
  end
  local monHint = nil
  if isPlayer then
    monHint = self.mine and self.mine[self.active]
  end

  -- Gen 2: Gen2Compat's BattleState has no makeBattler. Load spriteFront /
  -- spriteBack the way ui/gen2/BattleState:pic does.
  if Gen.generation(self.game) == 2 then
    local def = data.pokemon[key]
    local path = isPlayer and def.spriteBack or def.spriteFront
    if type(path) ~= "string" or path == "" then
      slot.sprite = nil
      return
    end
    local okImg, Assets = pcall(require, "src.render.Assets")
    if not (okImg and Assets and type(Assets.image) == "function") then
      slot.sprite = nil
      return
    end
    local ok, image = pcall(Assets.image, path)
    if ok and image then
      slot.sprite = image
      slot.level = (monHint and monHint.level) or slot.level or 1
    else
      slot.sprite = nil
    end
    return
  end

  local eng = loadEngine()
  if not (eng and eng.BattleState and eng.BattleState.makeBattler) then
    slot.sprite = nil
    return
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
  -- Fanfare once the outcome is known. Same guard CoopBattle uses so a second
  -- finish path cannot restart the jingle.
  --
  -- On the arena the outcome can land while the loser's bar is still falling
  -- and its monster has not sunk yet, so the jingle is held until those rows
  -- have played (#36 -- a fanfare over a KO that still looks alive was the
  -- reported bug). The classic 160x144 path queues no such rows and fires
  -- here exactly as it did.
  if self.result == "win" then
    if self:usesBattlefield() and self:hasPendingHpFx() then
      self.victoryMusicHeld = true
    else
      self:playVictoryMusic()
    end
  end
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
  local effect = effectsFor(self.game).itemEffect(id)
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
  local effect = pick.effect or effectsFor(self.game).itemEffect(pick.id)
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

-- ------- theatre (battle / victory / map music)
--
-- Same contract as CoopBattle: play the fight theme on enter, the fanfare
-- once on a win, and restore the map theme on the way out win or lose -- a
-- Defeated* song ends in `sound_loop 0` and would otherwise follow the player
-- into the overworld. 1v1 is the link cue; protocol-only wild is the wild cue.

function M:musicKind()
  if self.cachedMusicKind then return self.cachedMusicKind end
  self.cachedMusicKind = (self.mode == "wild") and "wild" or "link"
  return self.cachedMusicKind
end

function M:playVictoryMusic()
  if self.result ~= "win" or self.victoryMusicPlayed then return end
  self.victoryMusicPlayed = true
  local eng = loadEngine()
  if not (eng and eng.Music and self.game) then return end
  -- Gen 1: kind .. "Win" (final→gym). Gen 2: BattleMusic victory label.
  Gen.playVictoryMusic(self.game, {
    Music = eng.Music,
    kind = self:musicKind(),
    mode = self.mode,
  })
end

-- ------- the screen
--
-- enter/exit/update/draw is the whole of the engine's state interface, and
-- src/Ui.lua's RbyMmoState screen hands this object straight to the stack.

function M:enter()
  loadEngine()
  if self:usesBattlefield() then self:ensureBattlefield() end
  local eng = engine
  if eng and eng.Music and self.game then
    Gen.playBattleMusic(self.game, {
      Music = eng.Music,
      kind = self:musicKind(),
      mode = self.mode,
    })
  end
  self:start(self.game)
end

function M:exit()
  if self.left then return end
  self.left = true
  -- Pending choice was never accepted: inventory untouched. Confirmed spends
  -- already match the hub and must not be refunded.
  self.pendingItem = nil
  self.pendingItemSlot = nil
  -- A fanfare still waiting on a drain is dropped rather than started over
  -- the map theme this is about to restore.
  self.victoryMusicHeld = nil
  -- Map theme back unconditionally: victory jingles loop until something
  -- stops them (same reason the engine's BattleState:finish restores).
  local eng = loadEngine()
  if eng and eng.Music and self.game then
    Gen.restoreMapMusic(self.game, { Music = eng.Music })
  end
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
    if self.animPlayer and self.animPlayer.update then
      pcall(self.animPlayer.update, self.animPlayer)
    end
    self:pollAnimEffects()
    local done = true
    if self.animPlayer and self.animPlayer.isDone then
      local ok, finished = pcall(self.animPlayer.isDone, self.animPlayer)
      done = (not ok) or finished
    else
      -- 0.35 is the plain move dwell; a ball-flow row sets its own hold to the
      -- lifetime of the effect it emitted, so the throw, the wobble and the
      -- burst each finish before the row behind them starts.
      local hold = tonumber(self.animHold) or 0.35
      self.dwell = self.dwell + (dt or 0)
      done = self.dwell >= hold
        or (input and (input:wasPressed("a") or input:wasPressed("b"))
            and self.dwell >= MSG_MIN_DWELL)
    end
    if done or (input and input:wasPressed("b") and self.dwell >= MSG_MIN_DWELL) then
      self:applyPendingHitFx()
      self.anim = nil
      self.animHold = nil
      self.dwell = 0
    end
    return true
  end

  -- Two more blocking states, both display-only and both unskippable: the bar
  -- falling and the monster after it. There is deliberately no input here to
  -- find -- the queue itself is what holds them, the way the engine reads a
  -- button only for a text page that has finished printing.
  if self.draining then
    self:stepDrain(dt)
    self.dwell = 0
    return true
  end
  if self.faintFx then
    -- Retired by stepFx once its `t` reaches 1.
    self.dwell = 0
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
    if type(next) == "table" and next.drain ~= nil then
      -- A bar already where it was going costs nothing but the row.
      self:startDrain(next)
      return true
    end
    if type(next) == "table" and next.faintfx ~= nil then
      self:startFaintFx(next)
      return true
    end
    if type(next) == "table" and next.spawnfx ~= nil then
      -- Nothing waits on the pop: it plays under the send line, which is the
      -- next row up. No dwell, exactly like `clearPic`.
      self:emitFx("spawn", next.spawnfx, next.side)
      return true
    end
    if type(next) == "table" and next.clearPic ~= nil then
      self:releasePic(next.clearPic, next)
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

-- ------- move / catch SFX (same contract as CoopBattle / BattleState)

local function hitSfxFromText(text)
  if type(text) ~= "string" then return nil end
  -- Engine / BattleSim lines may break mid-phrase ("It's super\neffective!").
  local lower = text:lower():gsub("%s+", " ")
  if lower:find("super effective", 1, true) then
    return { sound = "Super_Effective", pitch = 0xe0 }
  end
  if lower:find("not very effective", 1, true) then
    return { sound = "Not_Very_Effective", pitch = 0x50 }
  end
  return nil
end

function M:peekHitSfx()
  -- Mirror CoopBattle / solo: thud only when a following effectiveness line,
  -- faint line, or real HP-drain cue exists. Status flashes (GROWL etc.) and
  -- bare move-id anims stay silent — no default Damage fallthrough.
  local sawDamage = false
  local function remap(sfx)
    if not sfx then return nil end
    return {
      sound = Gen.sfx(self.game, sfx.sound),
      pitch = sfx.pitch,
    }
  end
  for _, row in ipairs(self.lines or {}) do
    if type(row) == "table" then
      if row.anim then break end
      if row.drain or row.faintfx then sawDamage = true end
    elseif type(row) == "string" then
      local sfx = remap(hitSfxFromText(row))
      if sfx then return sfx end
      local lower = row:lower()
      if lower:find("fainted", 1, true) then sawDamage = true end
    end
  end
  if sawDamage then
    return { sound = Gen.sfx(self.game, "Damage"), pitch = 0x20 }
  end
  return nil
end

function M:playAnimSound(soundMove)
  local eng = loadEngine()
  local Sound = eng and eng.Sound
  if not Sound then return end
  local data = self.game and self.game.data
  if not data then return end
  local animName = self.anim and self.anim.anim
  local mdef = data.moves and data.moves[soundMove]
  if animName == "GROWL" or animName == "ROAR" then
    local slot = self.anim and self.slots and self.slots[self.anim.slot]
    local species = slot and self:speciesKeyFor(slot.species, true)
    if not species and slot then species = slot.species end
    if species and Sound.playMoveCry then
      pcall(Sound.playMoveCry, data, species,
        mdef and mdef.anim and mdef.anim.tempo)
    end
    return
  end
  if mdef and mdef.anim then
    if Sound.playMove then
      pcall(Sound.playMove, data, mdef.anim)
    elseif mdef.anim.sound and Sound.play then
      pcall(Sound.play, data, mdef.anim.sound)
    end
  end
end

function M:applyAnimEffect(ev)
  if type(ev) ~= "table" then return end
  if ev.sound then self:playAnimSound(ev.sound) end
  if ev.effect == "SFX_TINK" then
    local eng = loadEngine()
    local Sound = eng and eng.Sound
    local data = self.game and self.game.data
    if Sound and Sound.play and data then
      pcall(Sound.play, data, Gen.sfx(self.game, "Tink"))
    end
  end
end

function M:pollAnimEffects()
  local player = self.animPlayer
  if not (player and player.pollEffects) then return end
  local ok, events = pcall(player.pollEffects, player)
  if not ok or type(events) ~= "table" then return end
  for _, ev in ipairs(events) do
    self:applyAnimEffect(ev)
  end
end

function M:applyPendingHitFx()
  local hit = self.pendingHit
  self.pendingHit = nil
  if not hit or not hit.sfx then return end
  local eng = loadEngine()
  local Sound = eng and eng.Sound
  local data = self.game and self.game.data
  if not (Sound and data) then return end
  if type(hit.sfx) == "table" then
    if Sound.playMove then
      pcall(Sound.playMove, data, hit.sfx)
    elseif hit.sfx.sound and Sound.play then
      pcall(Sound.play, data, hit.sfx.sound)
    end
  elseif Sound.play then
    pcall(Sound.play, data, hit.sfx)
  end
end

function M:playMoveAnimFallback(row)
  local eng = loadEngine()
  local Sound = eng and eng.Sound
  local data = self.game and self.game.data
  if not (data and Sound and row and row.anim) then return end
  local mdef = data.moves and data.moves[row.anim]
  local anim = mdef and mdef.anim
  if row.anim == "GROWL" or row.anim == "ROAR" then
    local slot = row.slot and self.slots and self.slots[row.slot]
    local species = slot and self:speciesKeyFor(slot.species, true)
    if not species and slot then species = slot.species end
    if species and Sound.playMoveCry then
      pcall(Sound.playMoveCry, data, species, anim and anim.tempo)
    end
  elseif anim and anim.sound then
    if Sound.playMove then
      pcall(Sound.playMove, data, anim)
    elseif Sound.play then
      pcall(Sound.play, data, anim.sound)
    end
  end
end

function M:startAnim(row)
  self.anim = row
  self.animHold = nil
  self.pendingHit = nil
  self:noteBattlefieldBubble(row)
  -- Ball chain: HIDEPIC / SHOWPIC gate foe stage pics (engine enemyHidden).
  if row.anim == "HIDEPIC_ANIM" then
    self.foePicHidden = true
  elseif row.anim == "SHOWPIC_ANIM" then
    self.foePicHidden = nil
  end
  local hitSfx = self:peekHitSfx()
  if hitSfx then self.pendingHit = { sfx = hitSfx } end
  -- Top-down theatre: skip classic AnimPlayer stage flashes (coords are
  -- 160×144); message/SFX timing still runs via the dwell path below.
  if self:usesBattlefield() then
    -- The attacker leans in -- but only for a real move. `HIDEPIC_ANIM`,
    -- `SHOWPIC_ANIM`, `TOSS_ANIM` and `SHAKE_ANIM` are the engine's ball
    -- markers, and a thrown ball must not make the thrower lurch. Same filter
    -- noteBattlefieldBubble uses on the same field.
    local moveAnim = type(row.anim) == "string" and row.anim ~= ""
      and not row.anim:find("_ANIM", 1, true)
    if moveAnim then
      -- The defender's flash and the field's nudge ride the drain row behind
      -- this one, so a move that misses only lunges.
      self:emitFx("lunge", row.slot, row.side)
    else
      -- ...and the markers it excludes are the throw itself: the arc, the
      -- recall, each wobble and the burst, one per queued row and each held
      -- for as long as it plays.
      self:startBallFx(row)
    end
    self:playMoveAnimFallback(row)
    self:applyPendingHitFx()
    return
  end
  local player = self:ensureAnimPlayer()
  if not (player and player.start) then
    self:playMoveAnimFallback(row)
    self:applyPendingHitFx()
    -- Still hold briefly via dwell path when there is no player.
    return
  end
  -- Field slot on the wire; fall back to side so a missing slot still faces
  -- the flash the right way rather than always as the foe.
  local mine = row.slot == self:mySlot()
    or (row.side ~= nil and row.side == self.mySide)
  local ball = self.medBall
  local opts = {
    shakes = row.amount,
    ball = ball,
    ballFlicker = ball == "MASTER_BALL" or ball == "ULTRA_BALL" or nil,
  }
  local ok = pcall(player.start, player, row.anim, mine, opts)
  if not ok then
    self:playMoveAnimFallback(row)
    self:applyPendingHitFx()
    -- still hold briefly via dwell path
    return
  end
  self:pollAnimEffects()
end

-- Drop a KO'd pic after its faint line (and any anim queued ahead of it).
--
-- `row` is the queued row, which names the occupant the release was filed for.
-- Same refusal as `startDrain`: a send batched behind the KO means the seat has
-- already changed hands, and the pic standing on it is the newcomer's -- taking
-- it down here left the arrival invisible until something else refreshed it.
-- The held sink still goes, though: it belongs to the monster that left, and
-- there is no pic of theirs for it to apply to any more.
function M:releasePic(index, row)
  local slot = self.slots[index]
  if not slot then return end
  if row ~= nil and slot.species ~= row.species then
    self:dropFaintFx(index)
    return
  end
  slot.sprite = nil
  slot.icon = nil
  slot.koHold = nil
  -- Nothing is drawn from this seat any more; put the two clocks back in step
  -- so a later send into the same slot cannot inherit a stale descent.
  slot.shownHp = slot.hp or 0
  -- And drop the held sink (stepFx keeps a finished one so the KO stays down
  -- while its line is read) -- there is no pic left for it to apply to, and a
  -- fresh monster on this seat must not walk on already face down.
  self:dropFaintFx(index)
  -- And the same for a throw held on this seat: there is no monster left here
  -- to keep inside a ball.
  if self.ballFlow and self.ballFlow.index == index then self:clearBallFlow() end
end

-- Retire any faint effect on the seat a released pic sat on.
--
-- Matched by seat and not by side alone: `emitFx` stamps `seatIndex`, and in a
-- future multi-seat mode one seat's release would otherwise drop a
-- co-occupant's sink. An entry carrying no stamp still matches on side, so
-- nothing filed before this survives a release that used to clear it.
function M:dropFaintFx(index, seatIndex)
  local list = self.fx
  if type(list) ~= "table" then return end
  local side = self:fxSideFor(index)
  local seat = seatIndex or 1
  local kept = {}
  for _, fx in ipairs(list) do
    local mine = type(fx) == "table" and fx.kind == "faint" and fx.side == side
      and (fx.seatIndex == nil or fx.seatIndex == seat)
    if not mine then kept[#kept + 1] = fx end
  end
  self.fx = (#kept > 0) and kept or nil
end

-- ------- the bar falling, and the monster after it

-- Which arena side a field slot sits on. `side` is the fallback for a row
-- that names no slot, so an effect still lands the right way round rather
-- than always as the foe.
function M:fxSideFor(index, side)
  if index ~= nil and index == self:mySlot() then return "ally" end
  if index == nil and side ~= nil then
    return (side == self.mySide) and "ally" or "foe"
  end
  return "foe"
end

-- Start one effect. Returns the record so a caller that needs to wait on it
-- (the faint row) can hold the reference rather than search the list.
--
-- `seatIndex` is 1-based within the side; a mediated 1v1 has exactly one seat
-- per side, and the argument is here so a future multi-seat mode does not
-- have to change the contract Battlefield renders against.
function M:emitFx(kind, index, side, seatIndex)
  if not self:usesBattlefield() then return nil end
  local span = FX_SPAN[kind]
  if not span then return nil end
  local fx = {
    kind = kind,
    side = self:fxSideFor(index, side),
    seatIndex = seatIndex or 1,
    t = 0,
    elapsed = 0,
    duration = span,
  }
  local list = self.fx
  if type(list) ~= "table" then
    list = {}
    self.fx = list
  end
  list[#list + 1] = fx
  return fx
end

-- ------- the ball flow
--
-- Five queued rows describe one throw -- toss, burst, recall, shake, and the
-- pair that ends a failure -- and each one of them is played here as it
-- reaches the head of the queue, never when the packet carrying it arrived.
-- `_emitBallChain` (src/BattleSim/Turn.lua, mirrored in server/lib/battle) is
-- the order they come in.

-- The seat a ball row is really about.
--
-- Every row in the chain is stamped with the *thrower's* slot and side, and
-- the engine's own chain hides the enemy pic whoever threw -- so the arc, the
-- recall and the wobbles all belong to the seat opposite the thrower.
function M:ballTargetSlot(row)
  local threw = self:mySlot()
  if type(row) == "table" then
    if row.slot ~= nil then
      threw = row.slot
    elseif row.side ~= nil then
      threw = slotOfSide(row.side)
    end
  end
  if threw == self:foeSlot() then return self:mySlot() end
  return self:foeSlot()
end

-- Retire the hiding effects on one side. Paired with the emit that replaces
-- them, so the seat is never uncovered between two rows of the same throw.
function M:dropBallFx(side)
  local list = self.fx
  if type(list) ~= "table" then return end
  local kept = {}
  for _, fx in ipairs(list) do
    local hiding = type(fx) == "table" and BALL_HIDE_FX[fx.kind] and fx.side == side
    if not hiding then kept[#kept + 1] = fx end
  end
  self.fx = (#kept > 0) and kept or nil
end

-- The monster is out of the ball (or the seat it was on is gone): drop the
-- hold that kept it hidden.
function M:clearBallFlow()
  local flow = self.ballFlow
  if not flow then return end
  self.ballFlow = nil
  self:dropBallFx(flow.side)
end

-- A ball marker reaches the head of the queue. Returns the effect kind it
-- played, or nil for a row with nothing left to show.
--
-- Only ever called from the battlefield branch of `startAnim`: the classic
-- 160x144 path and Gen2 run the engine's AnimPlayer over these same rows and
-- have no arena for any of this.
function M:startBallFx(row)
  if not self:usesBattlefield() then return nil end
  if type(row) ~= "table" then return nil end
  local kind = BALL_FX[row.anim]
  if not kind then return nil end

  local index = self:ballTargetSlot(row)
  local side = self:fxSideFor(index)
  local flow = self.ballFlow
  if flow and flow.side ~= side then
    -- A throw at the other seat: the old one is over whatever it was waiting
    -- for, and leaving it held would keep a monster in a ball nobody threw.
    self:clearBallFlow()
    flow = nil
  end
  local hidden = (flow ~= nil) and flow.hidden == true

  if kind == "poof" then
    -- A POOF with no throw open is a send-out marker rather than part of a
    -- chain, and the arrival pop is already the `spawnfx` row queued by the
    -- send (see tickMessages) -- bursting again here would double it over a
    -- monster that has only just walked on.
    if flow == nil then return nil end
    -- POOF is both halves of a throw: the ball bursting open on the way in,
    -- and the monster coming back out of it when it breaks free. Which one it
    -- is is which side of HIDEPIC the row landed on. A failure ends
    -- POOF + SHOWPIC and only the first of those is the reappearance -- the
    -- second would be a burst over a monster already standing there.
    if row.anim == "SHOWPIC_ANIM" and not hidden then return nil end
    self:emitFx("poof", index)
    -- Either way the ball is open, so the hold that hid the seat for the arc
    -- ends here: a throw the referee gave no shakes at all is TOSS + POOF and
    -- nothing else (`_emitBallChain` returns early), and leaving the flow
    -- standing kept the seat inside a ball that had already burst for the rest
    -- of the fight. The recall behind a real attempt opens a fresh flow of its
    -- own -- HIDEPIC is the next row.
    self:clearBallFlow()
    -- ...and if it *was* hidden, this POOF is the monster coming back out.
    if hidden then self:emitFx("spawn", index) end
    self.animHold = FX_SPAN.poof
    return kind
  end

  -- SHAKE carries the whole count on a single row (`anim("SHAKE_ANIM", shakes)`
  -- in both twins), and the contract is one wobble per effect -- so the row
  -- plays the first rock and puts the remainder back at the head of the queue.
  -- Still queue-ordered, and still one thing at a time: nothing behind it can
  -- start until the last wobble has been through here.
  if kind == "wobble" then
    local left = floor(tonumber(row.amount) or 1)
    if left > BALL_SHAKE_MAX then left = BALL_SHAKE_MAX end
    if left > 1 then
      table.insert(self.lines, 1, {
        anim = row.anim, slot = row.slot, side = row.side, amount = left - 1,
      })
    end
  end

  -- The hiding kinds. The previous one is dropped in the same call the next is
  -- emitted in, and `stepFx` holds a finished one at its last frame, so the
  -- seat stays covered from the recall to the burst that undoes it.
  self:dropBallFx(side)
  self.ballFlow = { side = side, index = index, hidden = hidden or kind == "recall" }
  self:emitFx(kind, index)
  self.animHold = FX_SPAN[kind]
  return kind
end

-- Advance every live effect and retire the finished ones. Scaled by dt so the
-- fixed 60Hz step reads as one frame and a headless second still completes.
function M:stepFx(dt)
  local list = self.fx
  if type(list) ~= "table" or #list == 0 then return end
  local step = tonumber(dt) or 0
  if step <= 0 then step = 1 / 60 end
  local kept = {}
  for _, fx in ipairs(list) do
    if type(fx) == "table" then
      local span = tonumber(fx.duration) or FX_SPAN[fx.kind] or 0.3
      if span <= 0 then span = 0.3 end
      fx.elapsed = (tonumber(fx.elapsed) or 0) + step
      local t = fx.elapsed / span
      if t >= 1 then
        fx.t = 1
        -- The faint row waits on this one; releasing it is what lets the
        -- "X fainted!" line behind it print.
        if self.faintFx == fx then self.faintFx = nil end
        -- A finished sink is *held* rather than retired: its end state is the
        -- monster face down and invisible, and the pic is still on the seat
        -- for another second and a half behind the "X fainted!" line. Retiring
        -- it here popped the KO back to full opacity for exactly that long.
        -- `releasePic` drops it when the seat is genuinely cleared.
        if fx.kind == "faint" then
          kept[#kept + 1] = fx
        elseif BALL_HIDE_FX[fx.kind] and self.ballFlow
            and self.ballFlow.side == fx.side then
          -- Same hold, same reason, for a monster inside a ball: its end state
          -- is a seat with nothing standing on it, and the row that undoes that
          -- is still to come. `startBallFx` replaces it as each row plays and
          -- `clearBallFlow` drops it when the monster comes back out (or the
          -- seat is released), so nothing here outlives the throw.
          kept[#kept + 1] = fx
        end
      else
        fx.t = t
        kept[#kept + 1] = fx
      end
    end
  end
  self.fx = (#kept > 0) and kept or nil
end

-- The HP the arena plates are drawn from, which trails `slot.hp` while a
-- drain plays.
--
-- Rounded the engine's way: a bar on its way down rounds up and one on its
-- way up rounds down, so the number always lags the animation by less than a
-- point rather than reaching the destination before the bar does.
function M:shownHpOf(slot)
  if type(slot) ~= "table" then return 0 end
  local truth = tonumber(slot.hp) or 0
  local shown = tonumber(slot.shownHp)
  if shown == nil then return truth end
  if shown > truth then return math.ceil(shown) end
  return floor(shown)
end

-- The pop a monster arrives with, queued rather than played on arrival.
--
-- It is the one queued effect that holds nothing: the row is consumed, the
-- pop starts, and the send line behind it prints on the next tick over the
-- top of it. Deliberately not in `hasPendingHpFx` either -- a spawn is not a
-- bar or a body, and a fanfare has no reason to wait on one.
function M:queueSpawnFx(index, side)
  if index == nil then return false end
  if not self:usesBattlefield() then return false end
  self.lines[#self.lines + 1] = { spawnfx = index, side = side }
  return true
end

-- Queue the fall for a slot whose truth HP has already moved.
--
-- Draining to an absolute target is idempotent, which is why a `damage` event
-- and the `faint` behind it can both queue one for the same seat without the
-- bar moving twice: the second finds the first has already landed.
--
-- The row carries the occupant it was queued for, not just the seat: a switch
-- can land between queue and play, and a fall meant for the monster that left
-- would otherwise be run against the one that replaced it. CoopBattle's twin
-- names the battler for the same reason.
function M:queueDrain(index)
  if index == nil then return false end
  if not self:usesBattlefield() then return false end
  local slot = self.slots[index]
  if not slot then return false end
  local to = tonumber(slot.hp) or 0
  if slot.shownHp == nil then
    slot.shownHp = to
    return false
  end
  if slot.shownHp == to then return false end
  self.lines[#self.lines + 1] = { drain = index, to = to, species = slot.species }
  return true
end

-- A queued drain row comes up.
--
-- `to` is clamped and NaN refused, and that is a wire rule rather than a tidy
-- one: the number came off the hub, `stepDrain` stops on exact equality, and
-- a drain is deliberately unskippable -- so an infinity is a stop condition
-- that never comes true and a message queue that never moves again.
function M:startDrain(row)
  local slot = self.slots[row and row.drain]
  local to = tonumber(row and row.to)
  if not (slot and to) then return false end
  if to ~= to then return false end
  -- Somebody else is standing here now: the row belongs to the monster that
  -- was recalled, and running it would drain the newcomer's bar to a number
  -- that was never theirs. Dropped, not deferred.
  if slot.species ~= row.species then return false end
  local maxHp = tonumber(slot.maxHp) or 0
  to = max(0, min(maxHp, to))
  if slot.shownHp == nil then
    slot.shownHp = to
    return false
  end
  if slot.shownHp == to then return false end
  self.draining = { slot = row.drain, to = to, frames = DRAIN_BUDGET }
  -- Now, with the bar about to move, is when the hit reads: the defender
  -- flashes white and the field takes a nudge. Emitted here rather than when
  -- the `damage` event arrived because a resolved turn arrives as one batch --
  -- both seats would jolt in the same frame, ahead of any text. A climb (a
  -- heal, a drain move's restore) gets neither: nothing was struck.
  if slot.shownHp > to then
    self:emitFx("flash", row.drain)
    self:emitFx("shake", row.drain)
  end
  return true
end

function M:stepDrain(dt)
  local at = self.draining
  if not at then return end
  local slot = self.slots[at.slot]
  if not slot then
    self.draining = nil
    return
  end
  local frames = frameCount(dt)
  at.frames = (tonumber(at.frames) or DRAIN_BUDGET) - frames
  local step = max(1, (tonumber(slot.maxHp) or 1) / DRAIN_FRAMES) * frames
  local shown = tonumber(slot.shownHp) or at.to
  if shown > at.to then
    shown = max(at.to, shown - step)
  else
    shown = min(at.to, shown + step)
  end
  slot.shownHp = shown
  -- Out of budget: the bar has had longer than a full descent and still has
  -- not landed, so it is put there. There is no button out of a drain, and
  -- the only other end to this is a queue that never moves again.
  if shown == at.to or at.frames <= 0 then
    slot.shownHp = at.to
    self.draining = nil
  end
end

-- The fall of the monster itself, queued as its own row so the sink finishes
-- before "X fainted!" prints -- the engine's order, and the reason the pic is
-- not released until the line behind it has been read.
--
-- Stamped with its occupant, exactly like the drain row: the referee can batch
-- an auto-replacement behind the KO, and a sink meant for the monster that left
-- would otherwise play against the one standing there now.
function M:queueFaintFx(index)
  if index == nil then return false end
  if not self:usesBattlefield() then return false end
  local slot = self.slots[index]
  self.lines[#self.lines + 1] = { faintfx = index, species = slot and slot.species }
  return true
end

function M:startFaintFx(row)
  local index = row and row.faintfx
  local slot = self.slots[index]
  -- Somebody else is standing here now: the sink belongs to the monster that
  -- was recalled, and playing it would drop the newcomer through the floor
  -- under a "X fainted!" that never named them. Dropped, not deferred.
  if slot and row ~= nil and slot.species ~= row.species then return false end
  local fx = self:emitFx("faint", index)
  if not fx then return false end
  self.faintFx = fx
  return true
end

-- Is a bar still falling, or a monster still on its way down?
--
-- The fanfare waits on this (#36): a win announced while the loser's bar is
-- mid-drain plays the jingle over a monster that still looks alive. Asked of
-- the queue as well as of the live states, because the outcome message can
-- land while the rows that show the last KO are still stacked up.
-- A throw counts too, and for the same reason one step further on: a catch is
-- decided by the referee the moment the last shake lands, but the ball on the
-- arena is still wobbling. Without this the "Gotcha!" fanfare started over a
-- ball that had not settled -- the outcome message is queued behind the anim
-- rows and prints in order, but the jingle is not a line and had nothing
-- holding it. The rows are what is asked about (plus the one playing now), so
-- the hold ends with the last wobble rather than with the throw's result: a
-- caught monster stays in its ball and the fanfare still plays.
function M:hasPendingHpFx()
  if self.draining or self.faintFx then return true end
  if type(self.anim) == "table" and BALL_FX[self.anim.anim] then return true end
  for _, row in ipairs(self.lines or {}) do
    if type(row) == "table" then
      if row.drain ~= nil or row.faintfx ~= nil then return true end
      if row.anim ~= nil and BALL_FX[row.anim] then return true end
    end
  end
  return false
end

function M:update(dt)
  self.frame = (self.frame or 0) + 1
  self:pruneBattlefieldBubbles()
  self:stepFx(dt)
  -- Held fanfare: the outcome was known before the arena had finished showing
  -- the KO that produced it.
  if self.victoryMusicHeld and not self:hasPendingHpFx() then
    self.victoryMusicHeld = nil
    self:playVictoryMusic()
  end

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
       and self.phase ~= "item_move" and self.phase ~= "switch"
       and self.phase ~= "target" then
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
  if self.phase == "target" then return self:updateTarget(input) end
  if self.phase == "item" then return self:updateItemMenu(input) end
  if self.phase == "item_party" then return self:updateItemParty(input) end
  if self.phase == "item_move" then return self:updateItemMove(input) end
  if self.phase == "switch" then return self:updateSwitch(input) end
end

-- Field cursor among living foe seats. 1v1 has a single target, so this is
-- mostly dormant; kept so a future multi-target mediated mode shares the API.
function M:updateTarget(input)
  local targets = self:battlefieldTargets()
  if #targets == 0 then
    self.phase = "move"
    return
  end
  if self.targetIndex > #targets then self.targetIndex = #targets end
  if input:wasPressed("left") or input:wasPressed("up") then
    self.targetIndex = Battlefield.nextTarget(targets, self.targetIndex, -1) or 1
  elseif input:wasPressed("right") or input:wasPressed("down") then
    self.targetIndex = Battlefield.nextTarget(targets, self.targetIndex, 1) or 1
  elseif input:wasPressed("b") then
    self.phase = "move"
  elseif input:wasPressed("a") then
    -- Mediated 1v1 still omits an explicit target on the wire (sim picks the
    -- first living foe); the cursor is presentation-only.
    self:pickMove(self.cursor)
  end
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
  local scale = playerPicScale(self.game)
  if not sprite then return CLASSIC_PLAYER.x, CLASSIC_PLAYER.y, scale end
  local ok, w, h = pcall(sprite.getDimensions, sprite)
  if not ok then return CLASSIC_PLAYER.x, CLASSIC_PLAYER.y, scale end
  -- Gen 2: feet in the 6x6 box at (16, 48) — same as BattleState.PLAYER_PIC_*.
  if Gen.generation(self.game) == 2 then
    return 16, 48 + (48 - h), scale
  end
  -- Gen 1: Same contract as BattleState.backPlacement: feet flush on y=96.
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
  local w, h = 160, 144
  if self:usesBattlefield() then
    w, h = Battlefield.WIDTH, Battlefield.HEIGHT
  end
  return { { colors = false, x = 0, y = 0, w = w, h = h } }
end

function M:drawFieldPics()
  local foe = self.slots[self:foeSlot()]
  local mine = self.slots[self:mySlot()]
  love.graphics.setColor(1, 1, 1, 1)
  -- Draw while the sprite is held -- including at 0 HP through the move flash
  -- and "X fainted!". `releasePic` (after that line) is what takes it down.
  if foe and foe.sprite and not self.foePicHidden then
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
    scale = scale or playerPicScale(self.game)
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
  -- Classic Gen 1 / engine BattleState: status replaces Lxx. Group battles
  -- put status on the HP bar instead (CoopBattle.drawReadout).
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

-- ------- the modern band (battlefield path only)
--
-- The same phases the GB chrome below draws, drawn instead as Battlefield's
-- panel widgets. Draw-only: every row source and every cursor is the one the
-- input handlers already read, so what a press does is untouched -- a list
-- drawn from a different set than `updateSwitch` filters would pick the mon
-- above the one the player is looking at.
--
-- Classic 160x144 and Gen2 never reach here; `drawSafe` sends them to the GB
-- path, which is byte-identical to what it always was.

-- The commands, with SWITCH under the name the player knows it by. The order
-- and the index are `M.COMMANDS`' own -- `updateCommand` steps that grid.
function M:bandCommandItems()
  local items = {}
  for i, command in ipairs(M.COMMANDS) do
    items[i] = { label = (command == "SWITCH") and "PKMN" or command }
  end
  return items
end

function M:bandMoveRows()
  local mon = self:activeMon()
  if self.phase == "item_move" then
    mon = (self.mine or {})[self.itemPartyIndex or self.active]
  end
  local rows = {}
  for _, move in ipairs((mon and mon.moves) or {}) do
    -- `pp` / `maxPp` are what a sheet carries (`moveOf`); a referee-published
    -- list after Transform/Mimic carries `pp` and may carry no maximum, so the
    -- right column is dropped rather than invented.
    local row = { label = self:moveLabel(move.id) or tostring(move.id) }
    local pp = tonumber(move.pp)
    local maxPp = tonumber(move.maxPp)
    if pp and maxPp then
      row.right = ("%d/%d"):format(pp, maxPp)
    elseif pp then
      row.right = tostring(floor(pp))
    end
    if pp and pp <= 0 then row.dim = true end
    rows[#rows + 1] = row
  end
  return rows
end

function M:bandPartyRows(all)
  local rows = {}
  for _, row in ipairs(self:partyRows()) do
    -- SWITCH shows what it will let you pick; the item menu shows the whole
    -- party (a Revive wants the fainted one). Both match their handler.
    if all or (not row.fainted and (self.replaceOnly or not row.active)) then
      local mon = (self.mine or {})[row.index]
      local entry = { label = row.label, dim = row.fainted or nil }
      if mon and tonumber(mon.hp) and tonumber(mon.maxHp) then
        entry.right = ("%d/%d"):format(mon.hp, mon.maxHp)
      end
      rows[#rows + 1] = entry
    end
  end
  return rows
end

function M:drawModernBand()
  local message = Battlefield.drawMessagePanel
  local grid = Battlefield.drawCommandGrid
  local list = Battlefield.drawListPanel
  -- An arena without the band widgets (an older Battlefield) still gets the
  -- GB chrome rather than an empty band. Nothing to remediate: the caller
  -- falls back on a false return.
  if type(message) ~= "function" or type(grid) ~= "function"
     or type(list) ~= "function" then
    return false
  end

  if self.shown then
    message(tostring(self.shown))
    return true
  end
  if self.anim then
    message("")
    return true
  end
  if self.phase == "choose" then
    grid(self:bandCommandItems(), self.commandIndex or 1)
    return true
  end
  if self.phase == "move" or self.phase == "item_move" then
    list(self:bandMoveRows(), self.cursor, { title = "MOVES" })
    return true
  end
  if self.phase == "target" then
    local rows = {}
    for _, seat in ipairs(self:battlefieldTargets()) do
      local entry = { label = tostring(seat.name or "?") }
      if tonumber(seat.maxHp) then
        entry.right = ("%d/%d"):format(seat.shownHp or seat.hp or 0, seat.maxHp)
      end
      if (seat.hp or 0) <= 0 then entry.dim = true end
      rows[#rows + 1] = entry
    end
    list(rows, self.targetIndex or 1, { title = "TARGET" })
    return true
  end
  if self.phase == "item" then
    local rows = {}
    for _, item in ipairs(self:usableItems()) do
      rows[#rows + 1] = {
        label = tostring(item.name or item.id),
        right = item.count and ("x%d"):format(item.count) or nil,
      }
    end
    list(rows, self.itemIndex or 1, { title = "ITEMS" })
    return true
  end
  if self.phase == "item_party" then
    list(self:bandPartyRows(true), self.switchIndex or 1, { title = "POKeMON" })
    return true
  end
  if self.phase == "switch" then
    list(self:bandPartyRows(false), self.switchIndex or 1, { title = "POKeMON" })
    return true
  end
  if self.phase == "setup" then
    message("Getting ready...")
    return true
  end
  if self.phase == "over" then
    message(self.shown or "")
    return true
  end
  message(("Waiting for\n%s..."):format(self.peerName))
  return true
end

function M:drawBattlefieldMenus(Font)
  local ok, drew = pcall(self.drawModernBand, self)
  if ok and drew then return end

  local function chrome()
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
    if self.phase == "target" then
      local targets = self:battlefieldTargets()
      local rows = {}
      for _, seat in ipairs(targets) do
        rows[#rows + 1] = tostring(seat.name or "?")
      end
      return self:drawList(Font, rows, self.targetIndex or 1)
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
    if self.phase == "over" then
      return self:drawBox(Font, self.shown or "")
    end
    self:drawBox(Font, ("Waiting for\n%s..."):format(self.peerName))
  end
  self:withMenuBand(chrome)
end

function M:drawBattlefieldSafe()
  self:ensureBattlefield()
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.rectangle("fill", 0, 0, Battlefield.WIDTH, Battlefield.HEIGHT)

  local eng = loadEngine()
  local engBag = {
    Font = eng and eng.Font,
    Sprites = eng and eng.Sprites,
    sprites = self.game and self.game.data and self.game.data.sprites,
    game = self.game,
  }
  do
    local ok, SR = pcall(require, "src.render.SpriteRenderer")
    if ok then engBag.SpriteRenderer = SR end
  end
  pcall(Battlefield.draw, self, self:battlefieldCtx(), engBag)

  if not (eng and eng.Font) then return end
  self:drawBattlefieldMenus(eng.Font)
end

function M:drawSafe()
  if self:usesBattlefield() then
    return self:drawBattlefieldSafe()
  end

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
