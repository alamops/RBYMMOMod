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
    -- Exp is the *client's* arithmetic and can only ever be. The referee holds
    -- no species table (the legal floor -- no ROM bytes on a hub), so it can
    -- never price a faint: it states what fell and how many shared it, and
    -- this runs the engine's own formula over the player's own save (see
    -- `gainExp`). Grabbed rather than required so a build that cannot load it
    -- fights on, exp-less, instead of failing to open a battle at all.
    Experience = grab("Experience", "src.battle.Experience"),
    -- The curve behind the exp strip, soft beside Experience because it is a
    -- *display* dependency: a build without it still awards exp and still
    -- levels, the plate simply draws no strip (see `expFraction`). Twin of
    -- CoopBattle's own grab, and for the same reason.
    Growth = grab("Growth", "src.pokemon.Growth"),
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

-- ------- how far along its level a monster is
--
-- Verbatim twin of CoopBattle's helper of the same name (which is itself the
-- Gen 2 HUD's `HpBar.expFraction` ported to Gen 1 spellings): the exp a mon
-- carries is `mon.exp`, and the curve comes off the species def's
-- `growthRate` through `Growth.expForLevel` -- the same call `Experience.apply`
-- levels by, so the strip and the level can never disagree about where a level
-- ends. Kept a copy rather than shared because the two screens load their
-- engines separately and neither requires the other.
--
-- **nil is a real answer and means "draw no strip".** No species def, no
-- Growth module, no `mon.exp`: three states where any number this could return
-- would be invented, and an invented exp bar on somebody's plate is worse than
-- no bar at all -- Battlefield's `plateModel` treats a nil `expFrac` as exactly
-- that no-data state. Everything is pcall-guarded because it runs inside the
-- draw path.
--
-- The mon here is the **save** mon, never the wire sheet: a `Wire.battleMon`
-- carries level and HP and no exp at all, so a fraction worked off one would
-- be a fraction of nothing.
local function expFraction(data, mon)
  if type(data) ~= "table" or type(mon) ~= "table" then return nil end
  if mon.exp == nil then return nil end
  local eng = loadEngine()
  local Growth = eng and eng.Growth
  if not (Growth and Growth.expForLevel) then return nil end
  local def = mon.species and (data.pokemon or {})[mon.species]
  if not def then return nil end
  local level = tonumber(mon.level) or 1
  local ok, base = pcall(Growth.expForLevel, def.growthRate, level,
    data.growth_rates)
  if not ok then return nil end
  local okNext, after = pcall(Growth.expForLevel, def.growthRate, level + 1,
    data.growth_rates)
  if not okNext then return nil end
  base, after = tonumber(base), tonumber(after)
  if not (base and after) or after <= base then return nil end
  local into = (tonumber(mon.exp) or base) - base
  local frac = into / (after - base)
  -- NaN compares false against every bound there is, so it is refused rather
  -- than clamped -- the same rule `startDrain` applies to a wire `to`.
  if frac ~= frac then return nil end
  return math.max(0, math.min(1, frac))
end

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

-- The per-attack chronology's two deliberate gaps. One attack is four beats on
-- the arena, in this order and never two of them in the same tick:
--
--   1. the trainer's callout bubble, alone          (BEAT_SPAN.callout)
--   2. the attacker's lunge                         (FX_SPAN.lunge)
--   3. the defender's flash and the field's nudge   (BEAT_SPAN.hit)
--   4. the bar falling                              (the drain, DRAIN_BUDGET)
--
-- Beats 2 and 4 are effects and a descent with lifetimes of their own; 1 and 3
-- are *holds* the queue takes with nothing else running, so they are their own
-- table rather than more `FX_SPAN` entries -- no `emitFx` call ever names
-- either. Shared verbatim with CoopBattle's twin, which plays the same
-- chronology over its own queue: the two screens must not drift on the timing
-- a player reads as the game's rhythm.
local BEAT_SPAN = {
  -- 1 -> 2. The shout is a moment of its own: the bubble goes up over the
  -- trainer, and only then does the monster lean in. Comfortably inside the
  -- bubble's own life (BUBBLE_LIFE, 90 frames) with the lunge's 0.35s on top
  -- -- 33 + 21 of 90 -- so the shout is still on screen for the whole of the
  -- lunge it introduces, which is the point of saying it first, and it is
  -- never re-noted for the second beat (that would restart its fade).
  callout = 0.55,
  -- 3 -> 4. The strike reads before the bar answers it: the defender flashes
  -- and the field takes its nudge with the bar held exactly where it was, and
  -- only once that has been seen does the drain start. Exactly the flash it
  -- opens (FX_SPAN.flash, and `stepFx` keeps running through the hold), so the
  -- white is on the defender for the whole beat and gone as the bar begins to
  -- move -- the two are one hit, not two.
  hit = 0.30,
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
--
-- `ball` is deliberately not one of them. The arc is a ball still in the air,
-- and the monster is standing on the seat it is flying at -- HIDEPIC is the row
-- that puts it inside, and it arrives *after* the toss (`_emitBallChain`:
-- TOSS, POOF, HIDEPIC, SHAKE...). Hiding on the throw put the monster in the
-- ball before the ball reached it, and Battlefield's own renderer already
-- refuses to hide for a `ball` effect for exactly that reason -- so listing it
-- here only kept a finished arc alive at t == 1 and dropped it again on a
-- side-wide clear that has nothing to do with it.
local BALL_HIDE_FX = { recall = true, wobble = true }

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

-- The exp strip's rate, and CoopBattle's numbers verbatim: a whole bar in
-- about 1.2 seconds, counted in 60Hz frames like the drain above. Linear
-- rather than the cart's accelerating three-frames-a-pixel crawl
-- (AnimateExpBar) because the strip here is a fraction rather than 64 discrete
-- pixels -- there are no pixel steps to lengthen, and a constant rate reads as
-- the same deliberate crawl. The two screens must not drift on a rhythm the
-- player reads as the game's.
local EXP_FILL_FRAMES = 72
local EXP_FILL_STEP = 1 / EXP_FILL_FRAMES

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

-- ...and back the other way. Side a holds slots 0-1, side b holds 2-3, so the
-- read is a halving rather than an equality -- a co-op seat sits on the odd
-- slot of its side and is no less that side's for it. A slot this build cannot
-- read as a number is nobody's, and answers "a" so that the one caller (the
-- exp credit below) treats it as *not* a foe -- the conservative half.
local function sideOfSlot(index)
  local n = tonumber(index)
  if not n then return "a" end
  return (math.floor(n) >= 2) and "b" or "a"
end

-- How many `exp` events one observed foe knockout may pay for.
--
-- **Six, because vanilla participation is a whole party wide.** The referee
-- pays every monster of yours that was ever in against the fallen foe and is
-- still alive (round 6; `src/BattleSim/Turn.lua` and its Node twin), one `exp`
-- event each, and the own-slot gate lets *all* of yours through -- they differ
-- by the new `mon` field, not by `slot`. A player who cycled all six of their
-- team through one long foe is owed six awards for that single knockout, so
-- the old bound of two would have silently eaten four of them.
--
-- Still a bound, and still the same one in spirit: a party is six monsters and
-- cannot be paid seven times for one faint. The guard that spends this exists
-- to cap a hostile hub streaming awards nobody refereed, never to argue with a
-- well-behaved one. Declared up here rather than beside `gainExp` because
-- `onEvent` is the one that banks it, and a local is only in scope after its
-- own line.
local EXP_PER_FAINT = 6

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
    -- 1-based index into `mine` (the uploaded sheets), which is what the wire
    -- is stated in. `savePartyIndex` is what turns it into a save.party slot.
    pendingItemSlot = nil,
    -- Awards this client may still honour, banked by the foe knockouts it has
    -- actually seen narrated. See EXP_PER_FAINT and the `exp` event branch.
    expCredit = 0,
    -- EXP.ALL's *second* pass, which belongs to the knockout rather than to
    -- the award. Three-valued, like CoopBattle's: nil / true (armed by a foe
    -- faint) / false (spent by the award after it). Deliberately left nil
    -- rather than false here: nil means "no faint has ever been armed on this
    -- screen", which is the direct-call path (`gainExp` driven straight from a
    -- harness) and runs the pass the way it always did. See `gainExp`'s
    -- EXP.ALL block for the whole argument.
    expAllCredit = nil,
    seq       = 0,         -- the highest event sequence applied
    gaps      = 0,         -- events that arrived out of order
    pendingTurn = false,
    answeredTurn = false, -- own seat already answered (forced skip or filed choice)
    mustReplace = false,  -- faint with bench: next turn opens the switch picker
    replaceOnly = false,  -- B cannot cancel out of a forced replacement
    -- The field slot the referee is asking for a send-out, while it is asking.
    -- Set by a `turn` that carries a slot (the replace phase -- see the `turn`
    -- branch in `onEvent`), cleared by the send that answers it, by the
    -- slot-less `turn` that opens the choice window behind it, and by every
    -- teardown that puts the screen back where the referee says it is.
    replaceWait = nil,
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
    -- `draining` / `faintFx` / `expFilling` are the three states that hold the
    -- message queue while the bar falls, the monster after it, and the exp
    -- strip that answers the award. All of them stay nil until something is
    -- actually playing.
    fx = nil,
    draining = nil,
    faintFx = nil,
    -- Seats holding an arrival that has not had its spawn beat yet: slot index
    -- -> true, raised by `queueSpawnFx` for an *empty* seat and dropped by the
    -- `spawnfx` row that pops. `battlefieldSeat` draws nothing while one is
    -- held, so a monster materialises with its pop rather than standing on the
    -- arena from the moment the packet was parsed. CoopBattle's `introHide`
    -- (src/CoopBattle.lua:1067, dropped by the intro `act` row at :957/:995/
    -- :1027) is the twin. A seat that still has somebody on it is covered by
    -- `slot.pending` instead -- see `noteSlot`.
    spawnHide = nil,
    -- The exp strip mid-crawl: { slot, mon, toLevel, toFrac, frames }. The two
    -- clocks it drives (`shownExpFrac` / `shownLevel`) live on the seat's own
    -- `slots` entry beside `shownHp`, not here -- this is only what is moving
    -- them. Own seat only: the peer's client draws the peer's own strip, the
    -- same ownership rule the whole exp path runs on.
    expFilling = nil,
    -- Moves a level-up produced for a monster that already knows four, handed
    -- to `onDone` on the way out (CoopBattle's `toLearn`, same shape).
    toLearn = nil,
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
  -- An arrival that has not had its spawn beat yet is not on the arena. The
  -- seat record is already filled -- the referee's field moved the moment the
  -- packet was parsed and the rules read it from here -- but nothing is drawn
  -- until the queued `spawnfx` row plays and `applySwap` drops the hold.
  -- Same shape as the ball flow's hold below (`BALL_HIDE_FX`) and as
  -- CoopBattle's `introHide` (src/CoopBattle.lua:5030).
  if self.spawnHide and self.spawnHide[slotIndex] then return nil end
  -- Keep KO'd seats until releasePic clears the sprite, matching classic hold.
  -- A seat whose display clock has not caught up is still falling: dropping it
  -- here would take the bar off the arena in the middle of its own drain.
  if (slot.hp or 0) <= 0 and not slot.sprite and not slot.koHold
      and (slot.shownHp or 0) <= 0 then
    return nil
  end
  local monHint = nil
  if isPlayer then
    monHint = self.mine and self.mine[self.active]
    -- ...but only while it still describes who is standing here. `self.active`
    -- moves at parse, because the referee is already asking this client about
    -- the monster it just sent; the seat moves at the swap. In the window
    -- between, the hint is the *arrival's* sheet, and the pic and level pill it
    -- would furnish belong to a monster that is not on the arena yet.
    if monHint and slot.pending ~= nil and monHint.species ~= slot.species then
      monHint = nil
    end
  end
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
  -- The exp strip's two clocks, and only ever on this client's own seat.
  --
  -- Ownership is the whole rule: the fraction is read off *this* save file, and
  -- nothing on the wire carries one, so the peer's plate is drawn by the peer's
  -- own client from their own party and this one leaves theirs nil -- which is
  -- Battlefield's no-data state and draws no strip at all. Seeded here, at
  -- first sight, because a `slots` entry is built from a wire event and the
  -- wire knows nothing about exp; `seedExpClock` only ever fills a nil, so a
  -- clock mid-fill is never yanked back to truth by a draw.
  local expFrac, shownLevel
  if isPlayer and slotIndex == self:mySlot() then
    self:seedExpClock(slot)
    expFrac = slot.shownExpFrac
    shownLevel = slot.shownLevel
  end
  return {
    index = slotIndex,
    name = slot.species,
    level = slot.level or (monHint and monHint.level) or 1,
    hp = slot.hp or 0,
    -- Display clocks, plate-only (see Battlefield's seat HP contract). nil
    -- keeps meaning "no exp data" all the way down to drawPlate; the pill
    -- prefers `shownLevel` so it ticks over as the strip tops out rather than
    -- a message later.
    expFrac = expFrac,
    shownLevel = shownLevel,
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
          -- The acting mon's display name, carried like `moveName` so a
          -- rebuilt bubble keeps the line the renderer draws above the move.
          name = b.name,
          t = t,
          born = born,
        }
      end
    end
  end
  self.battlefieldBubbles = (#kept > 0) and kept or nil
end

-- Trainer callout when a human-owned mon acts. Never for the wild foe.
--
-- Returns true when a bubble was actually put up, which is what `startAnim`
-- reads to decide whether the row has a callout beat to hold for: a move with
-- nobody to shout it (the wild foe) must not stall the arena on a bubble that
-- was never drawn.
function M:noteBattlefieldBubble(row)
  if not self:usesBattlefield() then return end
  if type(row) ~= "table" then return end
  local anim = row.anim
  if type(anim) ~= "string" or anim == "" then return end
  -- Engine ball / hide / shake markers are not move callouts.
  if anim:find("_ANIM", 1, true) then return end

  -- The bubble is one sentence in two parts, CoopBattle's twin exactly: "used"
  -- is the small lead-in and `moveName` is the line the renderer emphasises.
  -- The raw id used to be the text as well, on the theory that nothing reading
  -- the bubble should change meaning -- but the renderer draws both parts, so
  -- a bubble said the move twice ("FIX_BOOST" over "FIX BOOST"). `moveName` is
  -- the registry name, or the wire id again when the build has no record for
  -- the move (a modded move whose definition did not survive).
  local moveName = self:moveLabel(anim)

  local mine = row.slot == self:mySlot()
    or (row.side ~= nil and row.side == self.mySide)
  if not mine then
    if self.mode == "wild" then return end
    self.battlefieldBubbles = {{
      side = "foe",
      humanIndex = 1,
      text = "used",
      moveName = moveName,
      name = self:battlefieldSeatName(row.slot or self:foeSlot()),
      born = self.frame or 0,
    }}
    return true
  end
  self.battlefieldBubbles = {{
    side = "ally",
    humanIndex = 1,
    text = "used",
    moveName = moveName,
    name = self:battlefieldSeatName(row.slot or self:mySlot()),
    born = self.frame or 0,
  }}
  return true
end

-- The acting mon's display name for a field slot: exactly the string the seat
-- plate shows, because it is the same field `battlefieldSeat` puts in `name`
-- (the slot's wire species label, which plateModel then truncates). Reading
-- the slot rather than re-deriving it is what keeps a bubble and the plate
-- under it from ever naming two different mons. nil when the slot is gone, and
-- a bubble with no `name` renders as it always did.
function M:battlefieldSeatName(slotIndex)
  local slot = slotIndex and self.slots and self.slots[slotIndex]
  local name = slot and slot.species
  if type(name) == "string" and name ~= "" then return name end
  return nil
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

  elseif kind == "switch" then
    -- Nothing. The referee emits `switch` and `send` as a *pair* for the same
    -- arrival -- voluntary switches and forced post-faint replacements alike
    -- (`_resolveSwitches`, src/BattleSim/Turn.lua:1432, mirrored in
    -- server/lib/battle/Turn.js) -- and both carry the same seat, the same
    -- species and the same `mon` stamp. Running the arrival branch for both
    -- fielded the newcomer twice: two send lines printed one after the other
    -- and two arrival chains queued, the first of them bursting over whoever
    -- was still standing on the seat. `send` is the one place a seat's
    -- occupant changes here, exactly as it is in CoopBattle's twin
    -- (src/CoopBattle.lua:8062).

  elseif kind == "send" then
    -- The first HP we are told about is a full bar: the sim sends this the
    -- moment a monster comes out, so the number is that monster's maximum
    -- unless it walked in already hurt.  It is the only handle on a foe's
    -- maximum there is -- an event carries current HP and nothing else -- so
    -- the largest value ever seen is what the bar is drawn against.
    self:noteSlot(msg)
    -- Parked behind somebody still finishing their exit (`noteSlot`): the seat
    -- below is still *theirs*, so everything that describes what is drawn on it
    -- -- the level pill, the pic, the exp clocks -- is deferred to the swap
    -- (`arriveOnSeat`, called from `applySwap`). Everything that describes the
    -- *rules* -- which sheet is out, whether a replacement is still owed --
    -- stays here, at parse, because the referee is already asking about it.
    local parked = (self.slots[msg.slot] or {}).pending ~= nil
    -- The solicitation this send answers is over -- for whichever seat it was.
    -- Cleared on the *event* rather than only on the slot-less `turn` behind
    -- it, because the referee can answer for a player who ran out of time and
    -- because the band's hold line is about a seat that is empty: the moment
    -- the referee says it is filled, the line stops being true. (`mustReplace`
    -- below is the same clear for our own seat's picker, and has always been.)
    if self.replaceWait ~= nil and self.replaceWait == msg.slot then
      self.replaceWait = nil
    end
    -- New mon on our seat drops any Transform/Mimic overlay until the
    -- referee publishes another `moves` list for it.
    if msg.slot == self:mySlot() then
      self.liveMoves = nil
      self.mustReplace = false
      if self.replaceOnly then
        self.replaceOnly = false
        if self.phase == "switch" then self.phase = "play" end
      end
      -- ...and the exp clocks go with it. They describe the monster that was
      -- standing here, and a fraction left behind would be the departing
      -- monster's progress drawn under the newcomer's name until the next
      -- award. Cleared rather than recomputed: nil is what `seedExpClock`
      -- reads as "ask again", and the answer it wants comes off `self.active`,
      -- which `trackActive` has not updated yet this far up the branch.
      local slot = self.slots[msg.slot]
      if slot and not parked then
        slot.shownExpFrac = nil
        slot.shownLevel = nil
      end
      -- A crawl already running on this seat goes too. Events arrive off the
      -- wire while the queue is held, so a send *can* land mid-fill, and a
      -- fill that kept stepping would write the departed monster's target
      -- straight back over the clocks just cleared. The queued-row case is
      -- caught by `startExpFill`'s occupant check; this is the live one.
      --
      -- Not while an arrival is parked: the monster the strip is filling for is
      -- still the one on the seat, and the fill is one of the rows the swap is
      -- waiting behind. `arriveOnSeat` clears the clocks when it lands.
      if not parked and self.expFilling and self.expFilling.slot == msg.slot then
        self.expFilling = nil
      end
    end
    -- The sentence comes FIRST, and the arrival is queued behind it.
    --
    -- A trainer says who they are sending out and *then* throws: the line, the
    -- ball, the burst, the monster. Queued the other way round -- which is what
    -- this did until round 8 -- the pop took no dwell at all, so the monster
    -- appeared and the sentence introducing it printed one tick later over a
    -- monster already standing there. Only the two queue appends move; the
    -- seat record still follows the referee at parse (`noteSlot` above), which
    -- is what every rule on this screen is read from.
    if msg.text then
      if msg.slot ~= self:mySlot() then
        self:say(("%s sent out\n%s!"):format(self.peerName, msg.text))
        if not parked then self:refreshSlotSprite(msg.slot, false) end
      else
        self:say(("Go! %s!"):format(msg.text))
        self:trackActive(msg.text, msg)
        if not parked then self:arriveOnSeat(msg.slot, true) end
      end
    end
    -- ...and then the arrival itself: the throw, and the burst it comes out of
    -- (`queueSpawnFx`). Queued, like every other effect, so it plays where the
    -- stream put it rather than the instant the packet was parsed.
    self:queueSpawnFx(msg.slot, msg.side)

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
    -- A knockout on the *other* side is the only thing that can owe this
    -- client experience, so this is where the credit for one is banked. See
    -- the `exp` branch below for what spends it.
    if sideOfSlot(msg.slot) ~= (self.mySide or "a") then
      self.expCredit = (self.expCredit or 0) + EXP_PER_FAINT
      -- ...and exactly one EXP.ALL party pass, however many participants this
      -- knockout ends up paying. The engine runs its second pass once per
      -- `awardExp` call -- once per faint -- not once per participant
      -- (BattleState's `vanillaExpAward`), and from round 6 a single faint can
      -- put six `exp` events on this wire.
      --
      -- A flag, not a counter, and the same three-valued one CoopBattle keeps
      -- (`nil` unmetered / `true` armed / `false` spent): armed by each foe
      -- knockout, spent by the first award that follows it, re-armed by the
      -- next knockout. A tally would have to be *spent* to come back down, and
      -- a knockout that pays this client nothing -- every one of its
      -- participants already fainted, or every share aimed at another seat --
      -- leaves the count standing, so the award after the *following* faint
      -- would run the party pass twice.
      self.expAllCredit = true
    end

  elseif kind == "exp" then
    -- The spoils of the faint just above, and they arrive *after* it for the
    -- same reason the engine awards after `enemyMonFainted`: the bar falls,
    -- the monster sinks, "X fainted!" prints, and only then is anybody paid.
    -- Nothing here reorders that -- the lines this queues go on the back of a
    -- queue those rows are already sitting in.
    --
    -- One event per *alive participant*, so a knockout the whole team took
    -- turns on puts one of these on the wire per monster and every client sees
    -- all of them. Only ours is ours to pay: the referee holds no save file
    -- and this client holds exactly one, so a share aimed at somebody else's
    -- seat is theirs to apply on their own copy. Same own-slot rule the `item`
    -- debit and the faint's bench check run on, a few lines up.
    --
    -- `slot` is still the owning *seat* -- the gate below is unchanged -- and
    -- the new `mon` field says which of that seat's six banks this particular
    -- share. Several events therefore pass the gate for one faint now, where
    -- round 5 let through at most one; see EXP_PER_FAINT.
    --
    -- **Bounded by the knockouts actually seen.** `exp` is the one event on
    -- this wire that writes the save file, and nothing else in the stream
    -- limits how many of them a hub may send -- an unbounded loop of them is a
    -- party levelled to 100 by a server the player merely connected to. The
    -- bound is the referee's own contract rather than a rate limit: a faint
    -- comes before the exp it pays for (`_awardExp` runs off the knockout, in
    -- both halves of the intermediator), so each observed foe knockout banks
    -- credit for the handful of awards it can honestly owe and every award
    -- spends one. A well-behaved hub is never refused; a hostile one gets at
    -- most what the fights it actually narrated were worth. Refused, warned
    -- through the same one-line `warnNoExp`, and never thrown -- an event
    -- handler that throws takes the whole stream with it.
    --
    -- The one honest cost: a hub that genuinely *lost* the faint message (a
    -- counted `gaps` jump above) loses the award with it. That is the same
    -- trade the rest of this handler makes for a dropped event, and it is the
    -- right way round -- a missing knockout should cost one payout, not open
    -- the save file to a stream nobody can account for.
    if msg.slot == self:mySlot() then
      if (self.expCredit or 0) <= 0 then
        self:warnNoExp("the referee paid experience with no knockout ahead of "
          .. "it, which is not a payout this client can account for")
      elseif self:gainExp(msg) then
        self.expCredit = self.expCredit - 1
      end
    end

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
    --
    -- ------- and a `turn` that names a slot is not that turn at all
    --
    -- It is the referee's replacement solicitation (`Battle:_openReplace` in
    -- src/BattleSim/Turn.lua): the seat at that field slot fainted with a bench
    -- left, and the choice window does **not** open until it has answered and
    -- the referee has sent the successor out behind a slot-less `turn`. So the
    -- two readings are told apart here and nowhere else -- everything below
    -- reads `pendingTurn`, and the whole of "no menu yet" is not setting it.
    --
    -- An older referee sends no `slot`, `owed` is nil, and every `turn` opens
    -- the window exactly as it did.
    local owed = msg.slot
    self.replaceWait = owed
    self.answeredTurn = false
    if owed == nil then
      self.pendingTurn = true
    elseif owed == self:mySlot() then
      -- Our own seat: this is the picker the faint already asked for, so it is
      -- opened by the flow that has always opened it -- `mustReplace` +
      -- `replaceOnly` in update(), which waits for the faint's own rows (the
      -- drain, the sink, "X fainted!") to drain before it takes the box. Set
      -- here rather than trusted from the `faint`, because the referee has now
      -- said it out loud: a lossy stream that dropped the faint would otherwise
      -- open the *command* menu over an empty seat, which is the exact thing
      -- this phase exists to make unreachable.
      --
      -- Except on an empty bench, which is not a picker at all -- `partyRows`
      -- would list nothing and `updateSwitch` has no B to leave with, since the
      -- replacement is forced. The referee does not solicit a seat with nothing
      -- to send, so this is a disagreement about our own party; the screen sits
      -- and waits for the referee rather than opening a menu with no way out.
      local hasBench = false
      for _, m in ipairs(self.mine or {}) do
        if (m.hp or 0) > 0 then hasBench = true; break end
      end
      if hasBench then
        self.mustReplace = true
        self.pendingTurn = true
      else
        self.mustReplace = false
        self.pendingTurn = false
        self.replaceWait = nil
      end
    else
      -- Somebody else's decision: no menu, and a line that says whose. Queued
      -- through `say` rather than printed, so it lands **behind** the rows the
      -- faint that caused it already queued -- the bar falling, the monster
      -- sinking, "X fainted!" -- which is the order they happened in. The band
      -- keeps saying it after the line is dismissed, for as long as the seat is
      -- still empty (see `drawModernBand`).
      self.pendingTurn = false
      self:say(("%s is choosing\nwho to send out..."):format(self.peerName))
    end
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
    self.replaceWait = nil
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

-- ------- exp
--
-- **Two monsters, and telling them apart is the whole of this section.**
-- `self.mine[self.active]` is a *wire sheet* -- what the referee is fighting
-- with, carrying level, HP and moves and no exp at all -- and it is thrown
-- away with the battle. The monster that keeps what it earns is the one in
-- `game.save.party`, and that is the only one written to here.
--
-- The referee sends no amount, and cannot: the hub holds no species table (no
-- ROM bytes on a hub, the legal floor), so `baseExp` is a number it has never
-- seen. It states facts -- who fell, at what level, split how many ways -- and
-- each client prices them with the engine's own `Experience.apply`, which is
-- also what divides the stat exp, recomputes the stats and decides whether a
-- level was crossed. A hub-computed number would skip all three, and would be
-- a hub deciding how strong somebody's party gets.
--
-- Applied here, at event receipt, rather than at `finish`: a mediated battle
-- has several ends that never reach finish (a dropped hub, a referee timeout,
-- the player closing the game), and exp banked only at the end would be exp
-- lost on every one of them. Same precedent as the vitamin writeback above --
-- fight-local sheet mutation is the referee's job, permanence is the client's.

-- Where the monster behind a fight sheet actually lives in the save file.
--
-- **The drift this closes, stated where it was assumed:** `mine[i]` is *not*
-- `save.party[i]`. `snapshotMons` skips a monster it cannot describe (no
-- stats, no species, no moves; see the comment on it), and one skip shifts
-- every index after it -- which would be exp paid to the wrong party member,
-- and Stat Exp written onto the wrong one at the vitamin writeback below.
-- The snapshot already stamps the party position it cut each sheet from
-- (`slot`, 0-based, `M.snapshotMons`), so both sites resolve through here
-- rather than through the array index. A sheet with no `slot` -- an older
-- upload, or a hand-built one in a test -- falls back to the array index,
-- which is exactly the behaviour this replaces.
function M:savePartyIndex(sheetIndex)
  local index = sheetIndex or self.active or 1
  local sheet = self.mine and self.mine[index]
  local slot = sheet and tonumber(sheet.slot)
  if not slot then return index end
  slot = math.floor(slot) + 1
  if slot < 1 then return index end
  return slot
end

-- The save-file monster behind a fight sheet index.
function M:saveMon(index)
  local party = self.game and self.game.save and self.game.save.party
  local mon = party and party[self:savePartyIndex(index)]
  if type(mon) ~= "table" then return nil end
  return mon
end

-- Which uploaded sheet an `exp` event names, as an index into `mine`.
--
-- **The referee counts in the party it was given.** `mon` is 0-based over the
-- monsters this client actually uploaded (`snapshotParty` order, which is what
-- the hub holds and the only party it has ever seen), so +1 lands on the sheet
-- and `savePartyIndex` turns that into the save slot -- the same two-step every
-- other party-addressed field on this wire takes (`pendingItemSlot`, the
-- vitamin writeback). Doing it in one step would pay `save.party[mon+1]`, which
-- is a different monster the moment `snapshotMons` skipped one.
--
-- **Absent is the round-5 referee**, which paid whoever was standing at the
-- faint and had no field to say so with. Falling back to the active sheet is
-- exactly what this did before `mon` existed, so a PROTOCOL 21 hub that never
-- learned the field keeps paying the same monster it always did.
function M:paidSheetIndex(msg)
  local raw = msg and tonumber(msg.mon)
  if not raw or raw ~= raw then return self.active or 1 end
  local index = floor(raw) + 1
  if index < 1 then return self.active or 1 end
  return index
end

-- The exp-awarding modes that have a *trainer* on the other side.
--
-- The referee's own gate is `EXP_MODES` = wild / coop_wild / coop_npc
-- (server/lib/battle/Turn.js, src/BattleSim/Turn.lua). Two of those three are
-- wildlife; only `coop_npc` fields a trainer, so the x1.5 belongs to it alone
-- and every other token -- including a mode this screen never learned -- pays
-- the plain wild rate.
local TRAINER_MODES = { coop_npc = true }

-- Warn once per screen rather than once per faint: a build with no Experience
-- module loses exp on every knockout, and forty identical lines in the log
-- describe the same single fact.
function M:warnNoExp(why)
  if self.expWarned then return false end
  self.expWarned = true
  mod.log:warn("no experience could be awarded in this battle (%s), so the "
    .. "fight still plays out but nothing levels up -- report this with the "
    .. "game version; levelling still works in ordinary battles", why)
  return true
end

-- Pay the monster of this client's the referee just named, for a faint it just
-- narrated.
--
-- **Not necessarily the one on the field.** Vanilla pays every monster that was
-- ever in against the fallen foe and is still alive, benched included, and from
-- round 6 the referee says which by name (`mon`). So this resolves a *target*
-- first and asks afterwards whether that target happens to be the one standing
-- -- because only the standing one has a bar on screen to fill.
function M:gainExp(msg)
  local data = self.game and self.game.data
  local paidIndex = self:paidSheetIndex(msg)
  -- A `mon` the uploaded party has no sheet for is a referee talking about a
  -- monster this client never sent it. Refused rather than resolved through
  -- the array-index fallback, which would quietly pay whichever save member
  -- happened to sit at that number. Only checked when there *is* an uploaded
  -- party: a screen driven straight from a harness has none, and its indices
  -- are save indices by definition.
  local mine = self.mine
  if msg and msg.mon ~= nil and type(mine) == "table" and #mine > 0
     and mine[paidIndex] == nil then
    self:warnNoExp("the referee paid a party member this client never uploaded")
    return false
  end
  local mon = self:saveMon(paidIndex)
  if not (type(data) == "table" and mon) then
    self:warnNoExp("this client holds no save party to pay")
    return false
  end

  -- **Wire tolerance.** An older or more lenient hub can send this event with
  -- any of the three facts missing, and every one of them is load-bearing: no
  -- species is no `baseExp` and no stat exp, no level is no formula, no
  -- participant count is a division by an unknown. There is no honest default
  -- for any of them -- inventing one pays a number nobody refereed -- so the
  -- award is skipped and said so, and the fight carries on. Never thrown: an
  -- event handler that throws takes the whole stream with it.
  local label = msg.species
  local key = (type(label) == "string" and label ~= "") and self:speciesKeyFor(label) or nil
  local def = key and type(data.pokemon) == "table" and data.pokemon[key] or nil
  local level = tonumber(msg.level)
  local participants = tonumber(msg.participants)
  if not (def and level and participants and participants >= 1) then
    self:warnNoExp("the referee's exp event named no species, level or share "
      .. "count this build could read")
    return false
  end
  level = math.max(1, math.floor(level))
  participants = math.max(1, math.floor(participants))

  local eng = loadEngine()
  if not (eng and eng.Experience and eng.Experience.apply) then
    self:warnNoExp("the engine's Experience module is unavailable")
    return false
  end

  -- Wild or trainer, decided from the mode this screen already knows.
  --
  -- **Deliberately not CoopBattle's unconditional `true`.** The trainer x1.5
  -- is a real rule of the formula (experience.asm), and paying it for a
  -- *wild* mediated kill would make the same PIDGEY worth more fought in the
  -- MMO than fought alone -- the kind of divergence a player finds in an
  -- afternoon.
  --
  -- Named as a positive set rather than "anything that is not `wild`", for
  -- two reasons the negative test got wrong: `coop_wild` is a wild fight too
  -- (the referee's own `EXP_MODES` is `wild` / `coop_wild` / `coop_npc`, and
  -- only the last of those has a trainer on the other side), and a screen
  -- whose `mode` never arrived reads as nil -- which under `~= "wild"` paid
  -- the bonus off a fact nobody stated. Unknown now means the smaller,
  -- unearned-nothing payout.
  local isTrainer = TRAINER_MODES[self.mode] or false

  local save = self.game.save
  local inventory = save and save.inventory
  -- EXP.ALL, the way the original splits it: the monster that fought takes
  -- half, and the other half is divided again across the whole living party.
  -- The engine expresses that as a *divisor* rather than a fraction (the base
  -- values are halved in place and the second pass inherits the participant
  -- division), so holding one doubles the divisor on the first pass and the
  -- second pass divides by the party size on top. Verbatim from
  -- BattleState:awardExp's own `vanillaExpAward`, so a mediated wild fight and
  -- a local one pay the same party the same numbers.
  local expAll = inventory and (tonumber(inventory.EXP_ALL) or 0) > 0
  local party = (save and save.party) or {}

  -- The three fields `Experience.apply` writes through without checking, and
  -- the one it reads. Filled rather than trusted because `apply` adds the exp
  -- *before* it recomputes the stats: a missing `dvs` or `stats` would throw
  -- half way and leave a monster holding exp it never levelled for -- and the
  -- pcall below would swallow the reason, so the damage would be silent. A
  -- save mon that has no stat block at all is not a save mon this fight
  -- uploaded (see the drift note on `savePartyIndex`), so it is refused rather
  -- than invented.
  local pokedex = (type(data.pokemon) == "table") and data.pokemon or {}
  mon.statExp = mon.statExp or {}
  mon.dvs = mon.dvs or {}
  mon.exp = mon.exp or 0
  if type(mon.stats) ~= "table" then
    self:warnNoExp("the party monster this fight is holding has no stat block")
    return false
  end
  -- The fourth thing `apply` reads, and the one this used to look up *after*
  -- the award: recomputing the stats needs the receiving monster's own species
  -- record, so a species this build cannot name is the same half-way throw.
  -- Hoisted above the first `apply` and refused there.
  local myDef = pokedex[mon.species]
  if type(myDef) ~= "table" then
    self:warnNoExp("this build has no species record for the party monster "
      .. "being paid")
    return false
  end

  -- Where the strip is *now*, read before the award lands.
  --
  -- `Experience.apply` mutates `mon.exp` and `mon.level` in place, so once it
  -- has run there is nothing left to work the starting fraction back out of.
  -- That is the whole job of this capture, and its only one: `startExpFill`
  -- starts from the *live* display clock and reaches for `from*` only when
  -- that clock is still nil, precisely so a second award in the same batch
  -- (both foes down in one 2-on-2 turn) begins where the first fill stopped
  -- rather than rewinding under it.
  --
  -- Battlefield only. The classic 160x144 readout has no exp strip: nothing
  -- below is computed, nothing is queued, and its exp text flow is the plain
  -- engine one -- the award still lands and still persists.
  --
  -- **And on-field only, which is the round-6 half of the same gate.** The
  -- strip on this seat's plate is the *standing* monster's -- one bar, one
  -- occupant -- so a benched participant's award has nowhere to draw itself.
  -- Crawling it there anyway would run somebody else's exp across the fighter's
  -- plate and leave the pill on a level the fighter never reached; freezing the
  -- fighter's own clocks to make room would be worse. A bench award is
  -- therefore text and save-file only: the "gained EXP" line, the "grew to
  -- level N!" lines, and the moves that come with them (`toLearn` and its
  -- forget prompt included) all still run, because those are the monster's,
  -- not the plate's. Nothing below writes `shownExpFrac` / `shownLevel` for a
  -- benched award -- not even the `seedExpClock` that would look harmless,
  -- since seeding the *seat* off a *bench* monster is exactly the mix-up this
  -- gate exists to prevent.
  local onField = paidIndex == (self.active or 1)
  local wide = self:usesBattlefield() and onField
  local index = self:mySlot()
  local slot = self.slots[index]
  local fromFrac, fromLevel
  if wide and slot then
    self:seedExpClock(slot, mon)
    fromFrac = slot.shownExpFrac
    fromLevel = slot.shownLevel or mon.level or 1
  end

  local ok, levels, gained = pcall(eng.Experience.apply, data, mon, def,
    level, isTrainer, participants * (expAll and 2 or 1), mon.traded)
  if not ok then
    self:warnNoExp("the engine refused the award for this monster")
    return false
  end

  -- The name the box has been calling it all fight: the referee narrates under
  -- the sheet's `species` (a nickname when there is one), so the exp line must
  -- not suddenly switch to the species def and read as a different monster.
  -- Read off the sheet being *paid* rather than the one on the field -- a bench
  -- award announced under the fighter's name is a player watching the wrong
  -- monster level up.
  local sheet = mine and mine[paidIndex]
  local name = (sheet and sheet.species) or mon.nickname or myDef.name or "?"

  self:say(name .. " gained\n" .. tostring(gained or 0) .. " EXP. Points!")

  -- ...and *then* the strip crawls, which is the cart's chronology: the line
  -- is read, and the bar answers it. Queued ahead of the level lines
  -- deliberately -- the pill ticks over as the strip tops out (`stepExpFill`),
  -- so "grew to level N!" prints after the plate already says N rather than a
  -- beat before it.
  --
  -- No target rides on the row: it is read off the mon when the row comes up,
  -- because the mon is *still being written to* after this point (the EXP.ALL
  -- pass below walks `save.party`, and this fighter is in it). A target frozen
  -- here would be the first half of the award and would leave the pill short
  -- of the "grew to level N!" lines printed beside it.
  if wide and slot then
    self.lines[#self.lines + 1] = {
      expfill = index,
      mon = mon,
      name = name,
      fromFrac = fromFrac,
      fromLevel = fromLevel,
      -- Stamped with its occupant like every other display row here: a switch
      -- landing between queue and play would otherwise crawl this monster's
      -- award across the newcomer's plate.
      species = slot.species,
    }
  end

  self:levelled(mon, name, levels)

  -- **No HP-climb row, and that is a decision rather than an omission.**
  -- CoopBattle queues one because there the levelling mon *is* the battler on
  -- the field, so its max HP moves under a bar mid-fight. Here the field is the
  -- referee's: `slot.hp` / `slot.maxHp` are its numbers, the save mon is a
  -- different table, and this fight goes on being fought with the sheet that
  -- was uploaded. Climbing the arena bar to a save-file HP would put a number
  -- on screen no referee holds -- one the very next `damage` event would
  -- contradict, and one `startDrain` would clamp against the old maximum
  -- anyway. The stat gain is real and is already banked; it shows in the party
  -- screen, and in the next battle's upload.

  -- ...and the other half, spread over everyone still standing -- including
  -- the monster that fought, exactly as the original's second pass does.
  -- Fainted party members are skipped, and no "gained EXP" line is printed for
  -- any of them: the original prints only what a level-up produces.
  --
  -- Every member is held to the same four checks the fighter above is, and for
  -- the same reason: `apply` banks the exp before it recomputes the stats, so
  -- a member with no `dvs`, no stat block or a species this build cannot name
  -- throws *after* the level has already moved, and the `pcall` here would
  -- report a skip while leaving the monster holding a level its stats never
  -- caught up with. A member that fails them is passed over whole.
  --
  -- **Once per knockout, not once per award** -- the round-6 correction. The
  -- engine's second pass is inside `vanillaExpAward`, which runs once per
  -- `awardExp`, i.e. once per faint, *after* the loop over participants
  -- (BattleState). Round 5 got that for free: the own-slot gate let exactly one
  -- `exp` event through per faint, so one award meant one pass. Now a faint can
  -- pay up to six of this client's monsters, and running the party pass on each
  -- of them would hand an EXP.ALL holder six second-halves for one kill -- the
  -- item quietly becoming several times better in the MMO than in the cart.
  --
  -- So the pass spends its own credit, armed by the foe knockout the same way
  -- the awards' is. Three-valued, exactly as CoopBattle's is: `nil` means no
  -- faint was ever narrated to this screen (`gainExp` driven straight from a
  -- harness) and runs unmetered -- the wire path always arms, so nil is never a
  -- hub the meter was meant to catch, and `expCredit` has already refused a hub
  -- that pays with no knockout at all. `true` is armed, `false` is spent, and
  -- the next knockout re-arms. A running tally instead would strand a credit
  -- whenever a knockout pays this client nothing at all.
  --
  -- Only the second pass is metered. The first one's divisor still doubles for
  -- everyone holding the item (`participants * 2` above), because that halving
  -- is the item's cost and is charged per participant in the cart too.
  if expAll and self.expAllCredit ~= false then
    if self.expAllCredit then self.expAllCredit = false end
    for _, member in ipairs(party) do
      local memberDef = type(member) == "table" and pokedex[member.species] or nil
      if type(memberDef) == "table" and (tonumber(member.hp) or 0) > 0
         and type(member.stats) == "table" then
        member.statExp = member.statExp or {}
        member.dvs = member.dvs or {}
        member.exp = member.exp or 0
        local gotOk, gotLevels = pcall(eng.Experience.apply, data, member, def,
          level, isTrainer, participants * 2 * math.max(1, #party),
          member.traded)
        if gotOk then self:levelled(member, nil, gotLevels) end
      end
    end
  end
  return true
end

-- What a level-up costs, wherever it happened: a line, and whatever moves come
-- with the level. CoopBattle's twin, minus its evolution note -- a mediated
-- battle has no `afterBattle` of its own to run the check in, so evolution
-- stays where the round pinned it: out.
function M:levelled(mon, fallbackName, levels)
  if not (levels and #levels > 0) then return false end
  local data = self.game and self.game.data
  local def = type(data) == "table" and (data.pokemon or {})[mon.species] or nil
  local name = mon.nickname or fallbackName or (def and def.name) or "?"
  local eng = loadEngine()
  for _, newLevel in ipairs(levels) do
    self:say(name .. " grew to\nlevel " .. tostring(newLevel) .. "!")
    -- Levelled here, so the moves it learns are decided here too -- the
    -- referee cannot know, because it never held the copy that gained them.
    --
    -- Unpacked in full rather than through `select(2, pcall(...))`: on a
    -- failure that second value is the error *string*, and `ipairs` over a
    -- string throws -- out of a function whose whole contract is that a
    -- level-up never takes the event stream down with it.
    local moves
    if def and eng and eng.Experience
       and type(eng.Experience.movesLearnedAt) == "function" then
      local ok, got = pcall(eng.Experience.movesLearnedAt, def, newLevel)
      if ok and type(got) == "table" then moves = got end
    end
    for _, moveId in ipairs(moves or {}) do
      self:teach(mon, name, moveId)
    end
  end
  return true
end

-- ------- learning a move
--
-- CoopBattle's twin. A monster with a free slot simply learns it; a full
-- moveset is a choice only its owner can make, so it is set aside and handed
-- to `onDone` -- the session that pushed this screen is where a forget prompt
-- belongs, not over a battle that is still finishing its own lines. Until one
-- is wired there the move is announced and kept in the list rather than
-- silently dropped: `toLearn` is the record that it was earned.
function M:teach(mon, name, moveId)
  local data = self.game and self.game.data
  local def = type(data) == "table" and (data.moves or {})[moveId] or nil
  if not def then return false end
  mon.moves = mon.moves or {}
  for _, known in ipairs(mon.moves) do
    if known.id == moveId then return false end
  end
  name = name or "?"
  if #mon.moves < 4 then
    mon.moves[#mon.moves + 1] = { id = moveId, pp = def.pp }
    self:say(name .. " learned\n" .. (def.name or moveId) .. "!")
    return true
  end
  self.toLearn = self.toLearn or {}
  self.toLearn[#self.toLearn + 1] = { mon = mon, move = moveId }
  self:say(name .. " is trying to\nlearn " .. (def.name or moveId) .. "!")
  return true
end

-- Record whatever an event said about a field slot.  Every event that names one
-- carries the HP that slot is now on, so one place reads it and the screen
-- never has to guess.
--
-- **A seat's occupant changes when the queued row says so, never when the
-- packet is parsed.** That is the invariant this screen and CoopBattle share,
-- and it is the whole of bug "the sent-out animation plays with the monster
-- already drawn". A `send` batched behind the knockout it replaces used to
-- relabel the seat here, at parse: the newcomer stood on the arena for the
-- two and a half seconds its own pop was still queued behind, and -- worse --
-- every one of the departing monster's exit rows then refused itself on its
-- own occupant stamp (`startDrain`, `startFaintFx`, `releasePic` all check
-- `slot.species ~= row.species`), so the monster that just fainted neither
-- drained nor sank. It was simply overwritten.
--
-- So an arrival into a seat that still has somebody on it is *parked* as
-- `slot.pending` and installed by `applySwap` where the queued `spawnfx` row
-- pops. This is CoopBattle's display shadow (`shownBattler` /
-- `src/CoopBattle.lua:3500-3525`), whose `applySwap` does exactly this for the
-- same reason and against the same failure. An arrival into an *empty* seat
-- lands immediately and is covered by `spawnHide` instead (`queueSpawnFx`);
-- both windows end at the same row.
function M:noteSlot(msg)
  local index = msg.slot
  if index == nil then return nil end
  local slot = self.slots[index]
  if not slot then
    slot = { species = nil, hp = 0, maxHp = 1 }
    self.slots[index] = slot
  end
  -- While an arrival is parked, the referee is talking about *it*: it is the
  -- monster the field holds, and the one still drawn is only finishing its
  -- exit. So a `damage` / `faint` / `status` that lands in the window is
  -- written to the parked record and never to the seat -- the departing
  -- monster's numbers are what its own queued rows are still animating
  -- against. (Only a forced-choice turn resolving while this queue is busy can
  -- produce one; the bar simply arrives already low, rather than the wrong
  -- monster's bar falling.)
  local parked = slot.pending
  if parked and not (msg.text and (msg.t == "send" or msg.t == "switch")) then
    if msg.hp ~= nil then
      parked.hp = msg.hp
    elseif msg.amount ~= nil and msg.t == "damage" then
      parked.hp = max(0, (parked.hp or 0) - msg.amount)
    end
    if msg.status ~= nil then parked.status = msg.status end
    if msg.t == "faint" then parked.hp = 0 end
    return slot
  end
  local fresh = false
  if msg.text and (msg.t == "send" or msg.t == "switch") then
    -- Battlefield only. The classic 160x144 path queues no `spawnfx` row
    -- (`queueSpawnFx` answers false off the arena), so there would be nothing
    -- to install a parked arrival -- that path relabels at parse exactly as it
    -- always has.
    if slot.species ~= nil and self:usesBattlefield() then
      -- Somebody is still on this seat -- draining, sinking, or merely waiting
      -- for the `clearPic` behind their faint line. Park the newcomer whole:
      -- everything the seat is rebuilt from at the swap, and nothing of it
      -- written here. Deliberately not gated on the two names differing: a
      -- trainer fielding two of the same species is the case where a relabel
      -- is *least* visible and most wrong, and the sink it cancels is the same
      -- sink either way.
      slot.pending = {
        species = msg.text,
        hp = msg.hp,
        status = msg.status,
        level = nil,   -- filled by `arriveOnSeat` at the swap, own seat only
      }
      return slot
    end
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

-- Which of ours is out.
--
-- **The referee says so where it can.** From round 6 a `send` / `switch` on
-- this client's own seat carries `mon` -- the 0-based index into the party
-- this client uploaded, the same space `exp` states its payee in -- so it goes
-- through the same two-step every other party-addressed field on this wire
-- takes (`paidSheetIndex`, then `savePartyIndex` wherever a save slot is
-- wanted). A `mon` the uploaded party has no sheet for is refused rather than
-- resolved, exactly as `gainExp` refuses one: the alternative is silently
-- pointing the move list at whichever sheet happens to sit at that number.
--
-- **Otherwise the name, preferring a living sheet.** Only the name crosses on
-- an older stream, and a party holding two monsters under one name would
-- always match the first -- including a first that is already face down, which
-- is precisely the monster the referee cannot have sent. Preferring a living
-- entry mirrors the referee's own `firstLiving` (src/BattleSim/Turn.lua:405),
-- so both ends land on the same sheet in every case a duplicate name can
-- produce; the dead-or-alive first match stays as the fallback so a stream
-- this client cannot reconcile behaves exactly as it did before.
--
-- This is `self.active`, which drives the move list, the party rows, the level
-- pill and the exp strip -- so a mis-point is visible, not merely academic.
function M:trackActive(species, msg)
  local mine = self.mine or {}
  local raw = msg and tonumber(msg.mon)
  if raw and raw == raw then
    local index = floor(raw) + 1
    if index >= 1 and (mine[index] ~= nil or #mine == 0) then
      self.active = index
      return
    end
  end
  local fallback = nil
  for index, mon in ipairs(mine) do
    if mon.species == species or mon.speciesId == species then
      if (tonumber(mon.hp) or 1) > 0 then
        self.active = index
        return
      end
      if fallback == nil then fallback = index end
    end
  end
  if fallback ~= nil then self.active = fallback end
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

-- The display side of a monster walking onto a seat: the pic, the level the
-- pill prints, and the two exp clocks the strip is drawn from.
--
-- Split out because it happens at one of two moments and never at both. A seat
-- that was empty is furnished at parse (the `send` branch); a seat somebody was
-- still standing on is furnished by `applySwap`, at the swap, because until
-- then every one of these describes the monster that is still being shown out.
-- Nothing here touches the rules -- `self.active`, `mustReplace`, `liveMoves`
-- all move at parse, where the referee is already asking about them.
function M:arriveOnSeat(index, isPlayer)
  local slot = self.slots[index]
  if not slot then return false end
  if isPlayer then
    -- Cleared rather than recomputed: nil is what `seedExpClock` reads as "ask
    -- again", and the answer it wants comes off `self.active`, which is already
    -- pointing at the arrival by the time this runs.
    slot.shownExpFrac = nil
    slot.shownLevel = nil
    local mon = self.mine and self.mine[self.active]
    if mon and mon.level then slot.level = mon.level end
  end
  self:refreshSlotSprite(index, isPlayer)
  return true
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
  -- Anything the arena is still holding with nothing left to release it is
  -- dropped here too -- but only when the arena owes nothing, which is the
  -- same question the fanfare above just asked. It has to be gated on that:
  -- the outcome lands while the rows that show it are still queued, and on a
  -- catch those rows *are* the throw. Snapping here would stand the caught
  -- monster back up on its seat one line before "Gotcha!" printed, and on an
  -- ordinary win it would cut the last KO short. When the answer is "something
  -- is still owed", the rows themselves finish the job: a KO's `clearPic` takes
  -- the sink down with the pic, a failed throw's closing burst clears the flow,
  -- a catch keeps it (nothing undoes a ball that was never opened), and `exit`
  -- clears whatever is left on the way out.
  if not self:hasPendingHpFx() then self:snapDisplay() end
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

-- One step around a `cols`-wide grid of `count` items, clamped at every edge
-- (Gen 1 never wraps the command menu).
--
-- `cols` defaults to 2, which is the classic 160x144 chrome and Gen2: at two
-- columns and four commands this is byte-identical to the 2x2 stepping it
-- replaces. The battlefield band lays the same four commands out four across
-- when it has the width for it, and a cursor that still stepped 2x2 under a
-- 1x4 paint was the bug: RIGHT from the second slab did nothing (there is no
-- column 2 to move into) and UP / DOWN jumped two slabs sideways.
local function gridStep(index, count, direction, cols)
  cols = math.floor(tonumber(cols) or 2)
  if cols < 1 then cols = 2 end
  local lastRow = math.max(0, math.ceil(count / cols) - 1)
  local row = math.floor((index - 1) / cols)
  local col = (index - 1) % cols
  if direction == "left" then col = math.max(0, col - 1)
  elseif direction == "right" then col = math.min(cols - 1, col + 1)
  elseif direction == "up" then row = math.max(0, row - 1)
  elseif direction == "down" then row = math.min(lastRow, row + 1)
  else return index end
  local moved = row * cols + col + 1
  -- A ragged last row has holes in it; a press into one stays put rather than
  -- selecting a command that is not on screen.
  if moved > count then return index end
  return moved
end

local GRID_KEYS = { "left", "right", "up", "down" }

local function gridPress(index, count, input, cols)
  for _, key in ipairs(GRID_KEYS) do
    if input:wasPressed(key) then return gridStep(index, count, key, cols) end
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
  local sheetIndex = self.pendingItemSlot or self.active
  self.pendingItem = nil
  self.pendingItemSlot = nil
  local effect = effectsFor(self.game).itemEffect(id)
  if effect and effect.vitamin and amount == 1 then
    -- The sheet index is what the wire is stated in (the hub indexes the
    -- `mons` array it was uploaded), and it is *not* the save.party position:
    -- `snapshotMons` skips a monster it cannot describe and one skip shifts
    -- every later index. The drift is closed through the party position the
    -- snapshot stamps on each sheet -- see `savePartyIndex`, which the exp
    -- writeback resolves through too.
    M.writebackVitamin(self.game, self:savePartyIndex(sheetIndex), id)
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

-- How many columns the command menu is *drawn* in, which is what the cursor
-- has to step in. The band widget owns that rule (`Battlefield.bandGridCols`,
-- which `drawCommandGrid` reads too), so it is asked rather than restated --
-- the two drifting apart is a highlight that walks onto a slab the player is
-- not looking at. Classic 160x144 chrome and Gen2 are always 2x2, and so is
-- an arena too old to answer: nothing to remediate, the fallback is the layout
-- those paths draw anyway.
function M:commandCols()
  if not self:usesBattlefield() then return 2 end
  local cols = Battlefield and Battlefield.bandGridCols
  if type(cols) ~= "function" then return 2 end
  local ok, got = pcall(cols, #M.COMMANDS)
  got = ok and tonumber(got) or nil
  if not got or got < 1 then return 2 end
  return math.floor(got)
end

function M:updateCommand(input)
  self.commandIndex = self.commandIndex or 1
  local moved = gridPress(self.commandIndex, #M.COMMANDS, input, self:commandCols())
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
  -- And the arena stops animating. Nothing draws this screen after here, so
  -- this is hygiene rather than a fix -- but it is the one place every path
  -- off the screen passes through, and a held effect is a hold on an object
  -- the session may still be holding a reference to.
  self:snapDisplay()
  -- Map theme back unconditionally: victory jingles loop until something
  -- stops them (same reason the engine's BattleState:finish restores).
  local eng = loadEngine()
  if eng and eng.Music and self.game then
    Gen.restoreMapMusic(self.game, { Music = eng.Music })
  end
  -- `toLearn` rides out with the result, exactly as CoopBattle's does: a
  -- monster that levelled into a fifth move needs a forget prompt, and that
  -- belongs to whoever pushed this screen (Coop hands its list to
  -- `offerForgets`), not over a battle still reading its own last lines. A
  -- session that ignores the second argument is no worse off than before --
  -- the move is announced and the level is banked either way.
  if self.onDone then self.onDone(self.result or "draw", self.toLearn) end
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

  -- Three more blocking states, all display-only and all unskippable: the hit
  -- landing, the bar falling, and the monster after it. There is deliberately
  -- no input here to find -- the queue itself is what holds them, the way the
  -- engine reads a button only for a text page that has finished printing.
  --
  -- The hit beat is `startDrain`'s half of the same split the callout does:
  -- the flash and the nudge have already been emitted and the drain row is
  -- back at the head of the queue, frozen behind this hold. Falling *through*
  -- on the tick it expires rather than returning is what keeps the bar's first
  -- frame in the same tick as the last frame of the flash -- returning here
  -- left one frame with no beat running at all, and the band drew the gap.
  if self.hitHold then
    self.hitHold = self.hitHold - (dt or 0)
    if self.hitHold > 0 then
      self.dwell = 0
      return true
    end
    self.hitHold = nil
  end
  if self.draining then
    self:stepDrain(dt)
    self.dwell = 0
    return true
  end
  -- ...and a filling exp strip holds the queue the same way, for the same
  -- reason: it is a bar crawling on the cart's own unskippable loop, not a text
  -- page with a button to answer it.
  if self.expFilling then
    self:stepExpFill(dt)
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
    if #self.lines == 0 then
      -- The queue is spent and nothing is playing, so a throw still standing
      -- here has nothing left to end it: the rows that would have -- the burst,
      -- the SHOWPIC -- are never coming. That is a hub drop mid-chain, and
      -- without this the seat stays inside a ball for the rest of the fight.
      -- Only while the fight is live: a finished one is *meant* to end holding
      -- a caught monster in its ball (see `snapDisplay`).
      if self.ballFlow and not self.finished then self:snapDisplay() end
      return false
    end
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
    if type(next) == "table" and next.expfill ~= nil then
      -- A strip already where it was going costs nothing but the row:
      -- `startExpFill` answers false and the queue moves on this same tick.
      self:startExpFill(next)
      return true
    end
    if type(next) == "table" and next.faintfx ~= nil then
      self:startFaintFx(next)
      return true
    end
    if type(next) == "table" and next.sendball ~= nil then
      -- The throw, held for the arc's own lifetime.
      self:startSendBall(next)
      return true
    end
    if type(next) == "table" and next.spawnfx ~= nil then
      -- ...and the reveal it lands on: the swap, the burst, the monster.
      -- Holds for the burst -- unless the row was superseded, in which case it
      -- emits nothing and costs no more than the row (`startSpawnFx`).
      self:startSpawnFx(next)
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
  -- Only on the first pass: a move row reaches here twice (the callout beat
  -- below puts it straight back at the head of the queue), and re-noting the
  -- bubble for the lunge would restart a fade the lunge is meant to be read
  -- under. The bubble outlives both beats on its own -- see BEAT_SPAN.callout.
  local spoke = (not row.calledOut) and self:noteBattlefieldBubble(row)
  -- Ball chain: HIDEPIC / SHOWPIC gate foe stage pics (engine enemyHidden).
  if row.anim == "HIDEPIC_ANIM" then
    self.foePicHidden = true
  elseif row.anim == "SHOWPIC_ANIM" then
    self.foePicHidden = nil
  end

  -- ------- beat 1: the callout, on its own.
  --
  -- The shout and the lean used to land in the same tick, which read as one
  -- indistinct event -- the bubble appeared over a monster already mid-lunge.
  -- They are two beats now, and the split is the queue's own: this pass puts
  -- the bubble up, holds for BEAT_SPAN.callout and pushes the *same row* back at
  -- the head of the queue (the SHAKE fan-out in `startBallFx` does exactly
  -- this), so the next pass through here plays the lunge with nothing else on
  -- screen to compete with it. Same row and not a copy, so `self.anim` is the
  -- identical table across both beats and everything that reads it -- the
  -- acting-seat mark, `playAnimSound`, `hasPendingHpFx` -- cannot tell one
  -- beat from the other.
  --
  -- Gated on a bubble actually having gone up, which is also the gate on
  -- everything this beat is for: no bubble on the classic 160x144 path, none
  -- on Gen2, none for a ball marker, and none for the wild foe -- and each of
  -- those plays exactly as it did before, in one beat.
  if spoke then
    row.calledOut = true
    table.insert(self.lines, 1, row)
    self.animHold = BEAT_SPAN.callout
    -- Deliberately before `peekHitSfx`: the thud belongs to the lunge, and
    -- arming it here would sound it at the end of the callout *and* again on
    -- the beat that follows.
    return
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
      -- Beat 2, with the callout above already spent and its bubble still up.
      -- The defender's flash and the field's nudge ride the drain row behind
      -- this one -- their own beat again -- so a move that misses only lunges.
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

-- The arrival, queued rather than played the moment the packet was parsed.
--
-- **Two rows, not one** -- a monster is *thrown* onto the field:
--
--   1. `sendball` -- the ball leaves the owning trainer and arcs at the seat,
--      held for `FX_SPAN.ball` (`startSendBall`);
--   2. `spawnfx`  -- the reveal: the ball opens, and the monster comes out of
--      the burst. `applySwap` + `poof` + `spawn` in one row, held for
--      `FX_SPAN.poof` (`startSpawnFx`).
--
-- The send line is already ahead of both (`onEvent`'s `send` branch), so the
-- whole of it reads as one sentence: "BOB sent out RATTATA!", the throw, the
-- burst, the monster. Nothing appears before the ball lands -- which is the
-- point, and was the bug: the pop used to be the *first* row of a send and
-- took no dwell, so the monster was standing there before its own line.
--
-- Nobody throws a wild monster. A wild-side arrival (`sendThrows`) keeps the
-- plain poof + spawn it always had -- one row, no ball -- and so does any seat
-- with no trainer to throw from.
--
-- Both rows now hold the queue, so both are in `hasPendingHpFx`: a fanfare
-- must not start over a ball still in the air.
--
-- **The reveal row is also where the arrival window closes**, for the seat
-- nobody is standing on.
--
-- A seat that already has an occupant is covered by `slot.pending`: the
-- newcomer is not on the seat record at all yet, so there is nothing to hide
-- and the monster still being shown out keeps its bar, its pic and its sink.
-- An *empty* seat -- the intro, and any replacement whose predecessor has
-- already been released -- has no such cover, because `noteSlot` filled it at
-- parse: the arrival is on the record and `battlefieldSeat` would draw it.
-- So that case raises a hold instead, and both windows end at the same row.
--
-- The gate matters. Hiding unconditionally is the fix's failure mode: it takes
-- a KO'd monster off the arena in the middle of its own sink, which is a worse
-- bug than the one being fixed.
--
-- This is the ball flow's `BALL_HIDE_FX` hold (see `startBallFx`) with one
-- difference worth stating: a ball hold is *held at t == 1* by `stepFx`,
-- because the row that undoes it may be several rows away. A spawn hold is
-- dropped by the very row that emits the effect, so it needs no retention at
-- all -- there is no window in which the hold outlives its own row. The seat
-- stays hidden for the whole of the throw, which is exactly what an empty seat
-- with a ball flying at it should look like.
--
-- The send chain is deliberately *not* `ballFlow`. That flow exists for a
-- throw at an occupied seat -- it hides a monster that is standing there and
-- holds the hiding effect until the row that opens the ball again. Here the
-- seat is empty (`spawnHide`) or still somebody else's (`slot.pending`), so
-- there is nothing to hide and nothing to hold: the two rows carry their own
-- `animHold` and answer to nobody else. A catch throw landing in the middle of
-- one is therefore unchanged, which is the property worth keeping.
--
-- The row names the arrival it was queued for, the same way the drain, the
-- sink and the release name their occupant: two sends can reach this queue
-- before either row plays, and a row that installed whatever happened to be
-- parked would then hand the seat to the *second* newcomer at the *first*
-- one's pop -- collapsing the exit sequence the park exists to protect.
-- `hide` is the same stamp for the other window: the row that raised the hold
-- is the row that drops it.
function M:queueSpawnFx(index, side)
  if index == nil then return false end
  if not self:usesBattlefield() then return false end
  local slot = self.slots[index]
  local arrive = slot and slot.pending or nil
  local hide = nil
  if not arrive then
    self.spawnHide = self.spawnHide or {}
    self.spawnHide[index] = true
    hide = true
  end
  local thrown = self:sendThrows(index) or nil
  if thrown then
    -- Stamped with the same arrival the reveal row is, so both halves of one
    -- chain live or die together: a throw whose reveal has been superseded (or
    -- closed forwards by `snapDisplay`) must not fly at a seat that is already
    -- showing the monster it was going to deliver.
    self.lines[#self.lines + 1] = {
      sendball = index, side = side, arrive = arrive, hide = hide,
    }
  end
  self.lines[#self.lines + 1] = {
    spawnfx = index, side = side, arrive = arrive, hide = hide,
  }
  return true
end

-- Is there a trainer to throw this arrival's ball?
--
-- Everybody on a mediated field is somebody's monster except the wild foe: a
-- protocol-only wild encounter fields a synthetic seat that no trainer owns
-- (`mode == "wild"`, our own seat excepted -- we throw ours), and a ball
-- arcing out of an empty patch of grass is worse than no ball at all. That
-- seat keeps the plain burst it has always had.
--
-- Written as "wild, and not mine" rather than "not mine": every other mode on
-- this screen (1v1, and the coop modes CoopBattle drives) has a trainer on
-- both sides, and `ballOrigin`'s own fallback already covers a side whose
-- trainer is not placed.
function M:sendThrows(index)
  if not self:usesBattlefield() then return false end
  if self.mode ~= "wild" then return true end
  return index == self:mySlot()
end

-- Is this row's arrival still the one the seat is waiting for?
--
-- One test for both rows of a chain, and it is the round-7 stamp rule read
-- once rather than twice: a row filed against a parked arrival is live while
-- that arrival is still parked (`slot.pending == row.arrive`), and a row filed
-- against an empty seat is live while the hold it raised is still standing
-- (`spawnHide`). Anything else -- a second send that re-parked the seat, a
-- `snapDisplay` that closed the window forwards -- means the monster this
-- chain was going to deliver is already accounted for, and every effect the
-- chain would play would land on somebody else.
function M:sendChainLive(row)
  if type(row) ~= "table" then return false end
  local index = row.sendball or row.spawnfx
  if index == nil then return false end
  if row.arrive ~= nil then
    local slot = self.slots[index]
    return slot ~= nil and slot.pending == row.arrive
  end
  if row.hide then
    return (self.spawnHide and self.spawnHide[index]) and true or false
  end
  return false
end

-- The `sendball` row comes up: the ball is in the air.
--
-- Held for its own lifetime the way every ball-flow row is (`startBallFx`),
-- with `self.anim` set so the message band shows the empty box a throw plays
-- under rather than the line before it -- again exactly as the catch chain
-- does. The seat it is flying at is hidden or still the departing monster's,
-- and stays that way until the reveal row behind this one.
--
-- `own` is what tells Battlefield the arc starts on the *thrower's* side: a
-- catch ball comes from the seat opposite its target, a send-out ball comes
-- from the trainer who owns the seat.
function M:startSendBall(row)
  if type(row) ~= "table" then return false end
  -- The same liveness test the reveal row applies, asked one row earlier: a
  -- chain whose arrival is no longer the one this seat is waiting for throws
  -- nothing at all.
  if not self:sendChainLive(row) then return false end
  local fx = self:emitFx("ball", row.sendball, row.side)
  if not fx then return false end
  fx.own = true
  self.anim = row
  self.animHold = FX_SPAN.ball
  self.dwell = 0
  return true
end

-- The `spawnfx` row comes up: the ball opens and the monster is on the arena.
--
-- Three things in one row because they are one moment: the seat changes hands
-- (`applySwap` -- the parked arrival is installed, or the hold on an empty
-- seat dropped), the burst is emitted over it, and the monster scales out of
-- the burst. Every frame before this one showed the seat as it was -- empty,
-- or somebody else's -- which is the point.
--
-- **A row that did not land emits nothing.** Two sends can reach the queue
-- before either row plays; the first row's arrival has then been superseded by
-- the second's (`applySwap` answers false, `slot.pending ~= row.arrive`) and
-- the seat still belongs to whoever is being shown out. Bursting anyway --
-- which is what this did until round 8 -- popped a spawn over the *outgoing*
-- monster, the second half of the doubled send the owner reported. The same
-- test covers the other window: a `hide` row whose hold is already gone (a
-- `snapDisplay` closed it forwards) is stale too, and the monster it would
-- announce has been standing there since.
function M:startSpawnFx(row)
  if type(row) ~= "table" then return false end
  local index = row.spawnfx
  -- Asked before the swap, because the swap is what consumes the park this
  -- reads. `applySwap` still runs either way -- on a stale row it is a no-op
  -- that answers false, and it is the only thing allowed to change a seat's
  -- occupant.
  local live = self:sendChainLive(row)
  self:applySwap(row)
  if not live then return false end
  self:emitFx("poof", index, row.side)
  self:emitFx("spawn", index, row.side)
  -- The reveal is a beat of its own now that the send line is ahead of it
  -- rather than behind it: the burst is read, and only then does the queue move
  -- on. `FX_SPAN.poof` is the burst's own lifetime, which is the same rule
  -- every ball row is held by -- the row *is* the effect.
  self.anim = row
  self.animHold = FX_SPAN.poof
  self.dwell = 0
  return true
end

-- The queued `spawnfx` row comes up: this is the frame the arrival is on the
-- arena, and the only frame on which the seat's occupant is allowed to change.
--
-- CoopBattle's `applySwap` (src/CoopBattle.lua:3518), same beat and same
-- argument -- there the shadow is dropped and `noteBattlefieldSpawn` fires;
-- here the parked record is installed and the pop is emitted. Both windows the
-- send opened close here: the hold on an empty seat, and the park on an
-- occupied one.
function M:applySwap(row)
  if type(row) ~= "table" then return false end
  local index = row.spawnfx
  local slot = self.slots[index]
  -- The hold this row raised, dropped by this row. A later row's hold is not
  -- this row's to release.
  if row.hide and self.spawnHide then self.spawnHide[index] = nil end
  local arrival = row.arrive
  -- Superseded: a second send landed on this seat before either row played, so
  -- the park no longer describes this row's newcomer. The row behind is the one
  -- that installs; the seat keeps who it is showing until then.
  if not (arrival and slot and slot.pending == arrival) then return false end
  slot.pending = nil
  slot.species = arrival.species
  slot.sprite = nil
  slot.icon = nil
  slot.koHold = nil
  -- Same reading of a first HP as `noteSlot`'s: what the referee says a monster
  -- is on the moment it walks out is the biggest bar this seat has ever been
  -- told about, unless it walked in already hurt.
  slot.hp = arrival.hp or 0
  if slot.hp > (slot.maxHp or 1) then slot.maxHp = slot.hp end
  -- A monster that just walked on has nothing to animate down from, so its bar
  -- starts where the referee says it is -- and the predecessor's descent, which
  -- ended on this same record, must not be inherited.
  slot.shownHp = slot.hp
  slot.status = arrival.status
  self:arriveOnSeat(index, index == self:mySlot())
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

  -- ------- beat 3: the hit, with the bar still frozen.
  --
  -- Now, with the bar about to move, is when the hit reads: the defender
  -- flashes white and the field takes a nudge. Emitted here rather than when
  -- the `damage` event arrived because a resolved turn arrives as one batch --
  -- both seats would jolt in the same frame, ahead of any text.
  --
  -- And *before* the fall rather than under it, the callout's split again: a
  -- flash over a bar already sliding is one indistinct event, so the strike
  -- gets BEAT_SPAN.hit of its own with the bar held exactly where it was, and
  -- the row goes back at the head of the queue to start the drain when the
  -- hold expires. Re-validated on the way back through, which is the point of
  -- re-queueing the row instead of remembering it: a switch landing between
  -- the two beats drops the fall the same way it always did.
  --
  -- A climb (a heal, a drain move's restore) gets no beat and no effects at
  -- all: nothing was struck, so the bar starts moving on this very tick, as
  -- before. Multi-hit is one anim row and one damage event per strike
  -- (`BattleSim/Turn.lua` loops `_damage` under a single `_emit("anim")`), so
  -- the callout and the lunge play once and each strike gets its own beat here.
  if slot.shownHp > to and not row.hit then
    row.hit = true
    table.insert(self.lines, 1, row)
    self:emitFx("flash", row.drain)
    self:emitFx("shake", row.drain)
    self.hitHold = BEAT_SPAN.hit
    return true
  end

  -- ------- beat 4: the fall.
  self.draining = { slot = row.drain, to = to, frames = DRAIN_BUDGET }
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

-- ------- the exp strip filling, which is the arena's third display clock
--
-- Same shape as the drain above and for the same reason: `Experience.apply`
-- runs the instant the `exp` event is received and moves `mon.exp` and
-- `mon.level` in one step, so the number the plate is drawn from has to be a
-- separate clock that trails it. `slot.shownExpFrac` is the strip's fill (0..1,
-- or nil for "no strip") and `slot.shownLevel` is the number the level pill
-- prints; the gap between those two and the save mon's own truth *is* the
-- animation, exactly as `shownHp` is for the bar.
--
-- Own seat only. The peer's plate is driven by the peer's own client off their
-- own save file -- there is no wire field for a fraction and there must not be
-- one -- so no other seat is ever seeded and no other seat draws a strip.
--
-- Battlefield-only. The classic 160x144 readout has no strip and never reads
-- either clock, so nothing here is ever queued on that path (see `gainExp`).

-- Seed the two display clocks off the save monster's own truth.
--
-- Lazy rather than at build time, because a `slots` entry is built from a wire
-- event and the wire knows nothing about exp. Idempotent: it only ever fills a
-- nil, so a clock mid-fill is never yanked back to truth by a draw.
--
-- A seeded-nil `shownExpFrac` is not a failure to seed -- it is the honest
-- "this monster has no fraction to show" (no Growth module, no save mon, a
-- species this build cannot describe) -- and it is re-asked every call
-- precisely so a monster that gains one later picks it up.
function M:seedExpClock(slot, mon)
  if type(slot) ~= "table" then return false end
  mon = mon or self:saveMon()
  if type(mon) ~= "table" then return false end
  if slot.shownLevel == nil then
    slot.shownLevel = tonumber(mon.level) or tonumber(slot.level) or 1
  end
  if slot.shownExpFrac == nil then
    slot.shownExpFrac = expFraction(self.game and self.game.data, mon)
  end
  return true
end

-- A queued exp-fill row comes up. Answered on the spot (returning false) when
-- there is nothing to crawl, so the queue never stalls on one.
--
-- The row carries the *save* mon it was queued for as well as the seat, and
-- both are checked: the award belongs to that monster wherever it now is, and
-- the clocks belong to the seat, so a switch that landed between queue and
-- play means the strip on that plate is describing somebody else. Dropped in
-- that case, with the clocks cleared so the newcomer reseeds from its own
-- truth rather than inheriting a fraction that was never theirs.
--
-- **Both ends are read here, not at queue time, and each for its own reason.**
--
-- The *target* comes off the mon now because the mon is still being written to
-- after the row is queued: with an EXP.ALL held, `gainExp` runs a second
-- `Experience.apply` pass over the whole party -- and the fighter is in that
-- party, so a target frozen before that pass is short by whatever the second
-- half added. Reading it at row-start means every pass has landed, so the
-- strip and the pill agree with the "grew to level N!" lines beside them.
--
-- The *start* is the live display clock, because that is where the strip
-- visibly is. Two awards in one batch (both foes down in one 2-on-2 turn) both
-- capture their `from*` before either has played, so honouring the second
-- row's capture would drag the strip back down to where the first one started.
-- `row.from*` remains the fallback for a clock that is still nil -- the
-- capture `gainExp` takes before `Experience.apply` mutates the mon, which is
-- the one thing that genuinely cannot be worked back out later.
function M:startExpFill(row)
  local index = row and row.expfill
  local slot = self.slots[index]
  local mon = row and row.mon
  if not (type(slot) == "table" and type(mon) == "table") then return false end
  if row.species ~= nil and slot.species ~= row.species then
    slot.shownExpFrac = nil
    slot.shownLevel = nil
    return false
  end
  local function level(value, fallback)
    local got = tonumber(value)
    if not got or got ~= got then return fallback end
    return max(1, floor(got))
  end
  local function frac(value)
    local got = tonumber(value)
    -- NaN refused rather than clamped: `stepExpFill` stops on a comparison
    -- against a target, and a NaN target is a stop condition that never comes
    -- true -- the same rule `startDrain` applies to a wire `to`.
    if not got or got ~= got then return nil end
    return max(0, min(1, got))
  end
  local data = self.game and self.game.data
  local toLevel = level(mon.level, 1)
  local toFrac = frac(expFraction(data, mon)) or 0
  local from = frac(slot.shownExpFrac)
  if from == nil then from = frac(row.fromFrac) end
  -- No fraction to start from means this monster draws no strip at all, so
  -- there is nothing to fill. The pill is still put where the level is: it is
  -- printed from `shownLevel` and would otherwise sit a level behind forever.
  if from == nil then
    slot.shownLevel = toLevel
    return false
  end
  local fromLevel = min(level(slot.shownLevel, level(row.fromLevel, toLevel)),
    toLevel)
  slot.shownExpFrac = from
  slot.shownLevel = fromLevel
  -- Nothing crossed and nothing added (a rounding-sized gain, or an award that
  -- priced to zero): put the strip where it belongs and let the queue move on
  -- rather than holding it for a crawl nobody can see.
  if fromLevel == toLevel and toFrac <= from then
    slot.shownExpFrac = toFrac
    return false
  end
  -- The budget, and it is the same guarantee the drain's is: a fill is
  -- deliberately unskippable, so the only other end to a target it somehow
  -- cannot reach is a message queue that never moves again. One whole bar per
  -- level to cross plus two bars of slack, after which it is snapped home.
  self.expFilling = {
    slot = index,
    mon = mon,
    toLevel = toLevel,
    toFrac = toFrac,
    frames = EXP_FILL_FRAMES * (2 + (toLevel - fromLevel)),
  }
  return true
end

-- One frame of it -- or however many this update covers, the way `stepDrain`
-- counts them, so the headless suite can drive whole seconds at a time.
--
-- A level crossing is the cart's own (AnimateExpBar, engine/battle/core.asm):
-- the segment fills to full, the level the HUD prints ticks up, and the strip
-- restarts at empty -- which is why the pill changes as the bar tops out and
-- not a message later. Two levels in one award is that twice.
function M:stepExpFill(dt)
  local at = self.expFilling
  if not at then return end
  local slot = self.slots[at.slot]
  if not (type(slot) == "table" and type(at.mon) == "table") then
    self.expFilling = nil
    return
  end
  local frames = frameCount(dt)
  at.frames = (tonumber(at.frames) or 0) - frames
  if at.frames <= 0 then
    slot.shownExpFrac = at.toFrac
    slot.shownLevel = at.toLevel
    self.expFilling = nil
    return
  end
  local shownLevel = tonumber(slot.shownLevel) or at.toLevel
  -- Every level still to cross fills the whole strip; the last one stops
  -- wherever the award actually left the monster.
  local target = (shownLevel < at.toLevel) and 1 or at.toFrac
  local shown = min(target, (tonumber(slot.shownExpFrac) or 0)
    + EXP_FILL_STEP * frames)
  slot.shownExpFrac = shown
  if shown < target then return end
  if shownLevel < at.toLevel then
    slot.shownLevel = shownLevel + 1
    slot.shownExpFrac = 0
    return
  end
  self.expFilling = nil
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
  -- `hitHold` counts for the same reason `draining` does, and is the beat
  -- immediately before it: the fanfare must not start in the gap between a
  -- strike landing and the bar that answers it. (The re-queued drain row in
  -- `lines` already answers true below; this says it directly, so the hold
  -- still holds if that row is ever dropped rather than re-queued.)
  -- A filling exp strip counts as well, live or still queued, and for the
  -- plainest reading of the same rule: the award is the last thing a knockout
  -- owes, so a jingle over a bar still crawling is a fight congratulating
  -- itself before it has finished paying out.
  if self.draining or self.faintFx or self.hitHold or self.expFilling then
    return true
  end
  -- A send-out counts for the same reason a throw does, and it is the same
  -- animation seen from the other end: the referee can call the fight the
  -- moment a replacement is fielded, and a jingle over a ball still in the air
  -- -- or over a burst the monster has not come out of yet -- congratulates a
  -- field that is not on screen yet. Both rows of the chain, queued or
  -- playing: they hold the queue, so they are owed.
  if type(self.anim) == "table"
      and (BALL_FX[self.anim.anim] or self.anim.sendball ~= nil
           or self.anim.spawnfx ~= nil) then
    return true
  end
  for _, row in ipairs(self.lines or {}) do
    if type(row) == "table" then
      if row.drain ~= nil or row.faintfx ~= nil or row.expfill ~= nil then
        return true
      end
      if row.sendball ~= nil or row.spawnfx ~= nil then return true end
      if row.anim ~= nil and BALL_FX[row.anim] then return true end
    end
  end
  return false
end

-- Put the arena back where the referee says the field is, and stop animating.
--
-- CoopBattle's `snapDisplay`, and the same argument. Two of the arena's
-- effects deliberately outlive their own clock -- a sink that keeps a KO face
-- down, and a throw that keeps a monster inside its ball -- and the only thing
-- that ever ends either one is the row that was going to undo it. A chain that
-- never finishes (a hub drop between HIDEPIC and the burst that opens the ball
-- again) therefore left a seat invisible for the rest of the fight. This is
-- the way out: the flow goes first and the effects it justified go with it, so
-- nothing is left held by a hold that no longer exists.
--
-- Never called while the fight is over. The last frame of a finished battle is
-- part of the outcome -- a monster face down, a caught monster inside its ball
-- -- and snapping it would stand both of them back up under the ending line.
function M:snapDisplay()
  -- The replace phase goes too, and forwards like everything else here: this is
  -- "put the screen where the referee says the field is", and a seat whose
  -- arrival is being installed below is not a seat anybody is still choosing
  -- for. Left standing it would hold the band on "X is choosing who to send
  -- out..." over a monster already on the field, for the rest of a fight that
  -- was re-synced or ended mid-solicitation.
  self.replaceWait = nil
  self.ballFlow = nil
  self.fx = nil
  self.animHold = nil
  self.hitHold = nil
  self.draining = nil
  self.faintFx = nil
  self.expFilling = nil
  -- The arrival window closes here too, and it closes *forwards*: this is
  -- "put the arena where the referee says the field is", and the referee says
  -- the newcomer is out. A parked arrival is therefore installed rather than
  -- dropped -- discarding it would leave the seat showing a monster the field
  -- no longer holds -- and any hold on an empty seat is released, so a battle
  -- that ends (or is re-synced) mid-window can never strand a seat invisible.
  -- Same shape as the ball flow above, for the same reason.
  self.spawnHide = nil
  for index, slot in pairs(self.slots or {}) do
    if type(slot) == "table" and slot.pending then
      local arrival = slot.pending
      slot.pending = nil
      slot.species = arrival.species
      slot.sprite = nil
      slot.icon = nil
      slot.koHold = nil
      slot.hp = arrival.hp or 0
      if slot.hp > (slot.maxHp or 1) then slot.maxHp = slot.hp end
      slot.status = arrival.status
      -- No `arriveOnSeat` here: `exit` calls this on stubs that carry neither a
      -- game nor a party, and the pic is refreshed by the next draw anyway
      -- (`battlefieldSeat` resolves a nil sprite through `seatFront`). The
      -- clocks below are welded by the loop that follows.
      slot.shownExpFrac = nil
      slot.shownLevel = nil
      if index ~= nil then self:refreshSlotSprite(index, index == self:mySlot()) end
    end
  end
  -- And the two clocks back in step: a descent abandoned half way is a bar
  -- that would otherwise sit at a number nobody holds until the next drain.
  for _, slot in pairs(self.slots or {}) do
    if type(slot) == "table" then slot.shownHp = slot.hp or 0 end
  end
  -- The exp clocks are welded the same way, and only on the one seat that owns
  -- them: a battle that ends mid-fill would otherwise leave a strip frozen
  -- part-way and a pill a level behind the monster it names. Welding wider than
  -- the own seat would invent clocks on plates that read none -- and spend a
  -- Growth walk per slot on the classic path, which is documented as untouched
  -- by any of this. nil stays nil: a monster with no fraction still shows none.
  --
  -- Queued `expfill` rows are deliberately *not* dropped here (this screen
  -- drops no queued rows -- see the drain rows, which stay too): a row that
  -- comes up after a weld finds its target already reached and answers false
  -- without crawling, which is the same outcome one fewer branch.
  if self:usesBattlefield() then
    -- `or {}` for the same reason the loop above has one: `exit` calls this on
    -- any object holding the screen's methods, and the suite's stubs do not
    -- carry a field table.
    local slot = (self.slots or {})[self:mySlot()]
    local mon = self:saveMon()
    if type(slot) == "table" and type(mon) == "table" then
      slot.shownExpFrac = expFraction(self.game and self.game.data, mon)
      slot.shownLevel = tonumber(mon.level) or slot.shownLevel
    end
  end
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

-- A widget's verdict. The band widgets report `false` when they could not
-- draw; an older Battlefield returns nothing at all, and that has always meant
-- "drawn" -- so only an explicit `false` sends the frame to the GB chrome.
local function bandDrew(ok)
  return ok ~= false
end

function M:drawModernBand()
  local message = Battlefield.drawMessagePanel
  local grid = Battlefield.drawCommandGrid
  local list = Battlefield.drawListPanel
  -- An arena without the band widgets (an older Battlefield) still gets the
  -- GB chrome rather than an empty band. Nothing to remediate, and nothing to
  -- warn about either -- the second return says so, and the caller falls back
  -- quietly.
  if type(message) ~= "function" or type(grid) ~= "function"
     or type(list) ~= "function" then
    return false, "unavailable"
  end
  if type(Battlefield.drawBandBackdrop) == "function" then
    -- Once, here, and never inside a widget: two scrims would double-darken
    -- the band. Without it the panels float on grass with no ground of their
    -- own, which is what the arena art runs edge to edge into.
    Battlefield.drawBandBackdrop()
  end

  -- From here every branch reports what the widget reported: a widget that
  -- could not draw leaves the band empty over a live fight, and the GB chrome
  -- is a worse-looking menu rather than no menu at all.
  if self.shown then
    return bandDrew(message(tostring(self.shown)))
  end
  if self.anim then
    return bandDrew(message(""))
  end
  if self.phase == "choose" then
    return bandDrew(grid(self:bandCommandItems(), self.commandIndex or 1))
  end
  if self.phase == "move" or self.phase == "item_move" then
    return bandDrew(list(self:bandMoveRows(), self.cursor, { title = "MOVES" }))
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
    return bandDrew(list(rows, self.targetIndex or 1, { title = "TARGET" }))
  end
  if self.phase == "item" then
    local rows = {}
    for _, item in ipairs(self:usableItems()) do
      rows[#rows + 1] = {
        label = tostring(item.name or item.id),
        right = item.count and ("x%d"):format(item.count) or nil,
      }
    end
    return bandDrew(list(rows, self.itemIndex or 1, { title = "ITEMS" }))
  end
  if self.phase == "item_party" then
    return bandDrew(list(self:bandPartyRows(true), self.switchIndex or 1,
      { title = "POKeMON" }))
  end
  if self.phase == "switch" then
    return bandDrew(list(self:bandPartyRows(false), self.switchIndex or 1,
      { title = "POKeMON" }))
  end
  if self.phase == "setup" then
    return bandDrew(message("Getting ready..."))
  end
  if self.phase == "over" then
    return bandDrew(message(self.shown or ""))
  end
  return bandDrew(message(self:holdLine()))
end

-- What the band says when there is no menu and no queued line: which of the two
-- waits this is.
--
-- "Waiting for X..." is a turn they have not answered yet. A seat still owed a
-- send-out is a different thing and reads as one -- the field is a monster
-- short, and the player is owed the reason it has stopped rather than a line
-- that sounds like an ordinary slow opponent. Our own solicitation never
-- reaches here: that one is a picker.
function M:holdLine()
  if self.replaceWait ~= nil and self.replaceWait ~= self:mySlot() then
    return ("%s is choosing\nwho to send out..."):format(self.peerName)
  end
  return ("Waiting for\n%s..."):format(self.peerName)
end

function M:drawBattlefieldMenus(Font)
  local ok, drew, why = pcall(self.drawModernBand, self)
  if ok and drew then return end
  -- The band failing is a visible downgrade in the middle of a fight, and the
  -- GB chrome hides it well enough that nobody would report it -- so it is
  -- said once, with what went wrong. `why == "unavailable"` is the one
  -- expected way down here (an arena with no band widgets at all), and is not
  -- worth a line.
  if not self.bandWarned and not (ok and why == "unavailable") then
    self.bandWarned = true
    mod.log:warn("the battle band could not draw (%s); this fight falls back "
      .. "to the classic menu chrome inside the band and stays playable -- "
      .. "report this with the message above so the arena widgets can be fixed",
      ok and "a band widget reported failure" or tostring(drew))
  end

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
    self:drawBox(Font, self:holdLine())
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
  self:drawBox(Font, self:holdLine())
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
