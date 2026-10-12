-- Headless Gen 3 mediated battle (Wave 3 T8): src/Sheet3.lua, src/Exp3.lua,
-- the Gen 3 arms of src/MediatedBattle.lua, src/LearnMove.lua and
-- src/EvolveFx.lua.
--
-- Two tiers in one file, the shape tests/trade3.lua set.
--
--   A. Always.  A FireRed-shaped boot (loader generation 3) over the engine
--      SDK's own Gen 3 fixture (T.sdk.gen3Data, synthetic numbers) with the
--      engine modules that would need an imported cache stood in: the
--      species / move / item readers read the fixture tables, and the
--      Pokemon / Bag / Dex / Evolution / LearnMove / Storage modules are small
--      fakes that record what they were asked.  The engine's *own* pure
--      modules run for real: battle/types.lua (the ordered chart),
--      battle/experience.lua + summary_data.lua (the level curve), the game3
--      modal stack.  And the referee is the real one -- src/BattleSim3 runs
--      in this process as the hub would, and MediatedBattle reads its stream.
--
--   B. When an imported FireRed cache can be mounted (tests/game3_cache: a
--      POKEPORT_IDENTITY holding one, or POKEPORT_GBA_CACHE): real party mons
--      from Party.giveMon through Sheet3 into BattleSim3, the real move pool
--      and chart.  Skipped with a line saying so otherwise.  Nothing
--      ROM-derived is asserted as a literal either way.
--
-- Run from the engine checkout root:
--
--   luajit mods/rby_mmo/tests/gen3_mediated.lua
--   POKEPORT_IDENTITY=<id> luajit mods/rby_mmo/tests/gen3_mediated.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local check, eq = T.check, T.eq

local MOD_PATH = "mods/rby_mmo"
if not io.open(MOD_PATH .. "/src/Sheet3.lua", "rb") then
  local src = debug.getinfo(1, "S").source
  if type(src) == "string" and src:sub(1, 1) == "@" then
    local dir = src:sub(2):match("(.+)[/\\]")
    if dir then MOD_PATH = dir:gsub("[/\\]tests$", "") end
  end
end

local warns = {}
local stubMod = {
  id = "rby_mmo",
  path = MOD_PATH,
  -- A Gen 3 boot: src/Gen3.lua's guard reads this field.
  generation = 3,
  log = {
    info = function() end,
    warn = function(_, fmt, ...)
      local ok, line = pcall(string.format, fmt, ...)
      warns[#warns + 1] = ok and line or tostring(fmt)
    end,
    error = function(_, fmt, ...)
      local ok, line = pcall(string.format, fmt, ...)
      warns[#warns + 1] = "ERROR " .. (ok and line or tostring(fmt))
    end,
  },
  options = { get = function() return nil end },
  save = { get = function() return nil end },
  exports = {},
}

local loadstr = loadstring or load
local function newNeed()
  local cache = {}
  local function need(n)
    if cache[n] ~= nil then return cache[n] end
    local h = assert(io.open(MOD_PATH .. "/src/" .. n .. ".lua", "rb"))
    local body = h:read("*a")
    h:close()
    local chunk = assert(loadstr(body, "@" .. n .. ".lua"))
    local value = chunk(need, stubMod)
    cache[n] = value == nil and true or value
    return cache[n]
  end
  return need
end

local saved = {}
local function stub(name, value)
  if saved[name] == nil then saved[name] = package.loaded[name] or false end
  package.loaded[name] = value
end
local function unstubAll()
  for name, original in pairs(saved) do
    package.loaded[name] = original or nil
  end
  saved = {}
end

local function contains(list, needle)
  for _, line in ipairs(list) do
    if type(line) == "string" and line:find(needle, 1, true) then return true end
  end
  return false
end

-- ===================================================================
-- Tier A -- the fixture, the real referee
-- ===================================================================

local DATA = T.sdk.gen3Data()
local P3 = DATA.gen3Pokemon
local ROM = DATA.gen3Moves._rom
local ITEMS = DATA.gen3Items._byId

-- A few more synthetic rows, in the fixture's own shapes.
ROM[45] = { effect = 18, power = 0, type = 0, accuracy = 100, pp = 40,
            secondaryChance = 0, target = 8, priority = 0, flags = 18 }
P3._moveNames[45] = "GROWL"
ROM[33].flags = 3
ROM[98] = { effect = 103, power = 40, type = 0, accuracy = 100, pp = 30,
            secondaryChance = 0, target = 0, priority = 1, flags = 51 }
P3._moveNames[98] = "QUICK ATTACK"
ITEMS[1] = { name = "MASTER BALL", pocket = "POKE_BALLS", price = 0 }
ITEMS[139] = { name = "ORAN BERRY", pocket = "BERRY_POUCH", price = 20,
               holdEffect = 1, holdEffectParam = 10 }
ITEMS[182] = { name = "EXP. SHARE", pocket = "ITEMS", price = 3000, holdEffect = 25 }
ITEMS[197] = { name = "LUCKY EGG", pocket = "ITEMS", price = 200, holdEffect = 40 }
ITEMS[350] = { name = "POKE FLUTE", pocket = "KEY_ITEMS", price = 0 }
ITEMS[189] = { name = "AMULET COIN", pocket = "ITEMS", price = 100, holdEffect = 32 }
ROM[6] = { effect = 34, power = 40, type = 0, accuracy = 100, pp = 20,
           secondaryChance = 100, target = 0, priority = 0, flags = 3 }
P3._moveNames[6] = "PAY DAY"
P3._speciesMeta[16].evSpe = 1
P3._speciesMeta[4].evSpa = 1
P3._abilityNames[2] = "DRIZZLE"
P3._learnsets[4] = { { 1, 10 }, { 7, 52 }, { 16, 98 } }

-- ------- the stand-in engine modules

local SESSION
local function newSession(extra)
  local s = {
    name = "ANN", trainerId = 111, secretId = 222, gender = 0, version = "firered",
    party = {}, dex = { seen = {}, caught = {}, owned = {} },
    bag = { pockets = { ITEMS = {}, KEY_ITEMS = {}, POKE_BALLS = {}, TM_CASE = {},
                        BERRY_POUCH = {} } },
    money = 1000,
  }
  for k, v in pairs(extra or {}) do s[k] = v end
  return s
end

local function pocketOf(id)
  local row = ITEMS[tonumber(id)]
  return row and row.pocket or "ITEMS"
end

local FakeBag = {}
function FakeBag.get(bag, id)
  for _, slot in ipairs(bag.pockets[pocketOf(id)] or {}) do
    if tonumber(slot.id) == tonumber(id) then return slot.qty end
  end
  return 0
end
function FakeBag.add(bag, id, qty)
  local slots = bag.pockets[pocketOf(id)]
  for _, slot in ipairs(slots) do
    if tonumber(slot.id) == tonumber(id) then
      slot.qty = slot.qty + qty
      return true, qty
    end
  end
  slots[#slots + 1] = { id = tonumber(id), qty = qty }
  return true, qty
end
function FakeBag.remove(bag, id, qty)
  local slots = bag.pockets[pocketOf(id)]
  for i, slot in ipairs(slots) do
    if tonumber(slot.id) == tonumber(id) then
      if slot.qty < qty then return false end
      slot.qty = slot.qty - qty
      if slot.qty <= 0 then table.remove(slots, i) end
      return true
    end
  end
  return false
end
function FakeBag.listPocket(bag, pocket)
  local rows = {}
  for _, slot in ipairs(bag.pockets[pocket] or {}) do
    rows[#rows + 1] = { id = slot.id, qty = slot.qty,
                        name = (ITEMS[tonumber(slot.id)] or {}).name }
  end
  return rows
end

local function fakeImage(tag)
  return setmetatable({ tag = tag, w = 64, h = 64 },
    { __index = { getDimensions = function(self) return self.w, self.h end } })
end

local evCalls, friendshipCalls = {}, {}
local FakePokemon = { FRIENDSHIP_EVENT_GROW_LEVEL = 0, NUMBERING_INTERNAL = "internal",
                      SPECIES_EGG = 412 }
function FakePokemon.name(sp) return P3._names[tonumber(sp)] end
function FakePokemon.speciesMeta(sp) return P3._speciesMeta[tonumber(sp)] end
function FakePokemon.stats(sp) return P3._stats[tonumber(sp)] end
function FakePokemon.speciesOf(mon) return tonumber(mon and (mon.species or mon.speciesId)) end
function FakePokemon.calcStats(sp, level, ivs, evs)
  local b = P3._stats[tonumber(sp)]
  ivs, evs = ivs or {}, evs or {}
  local function other(base, k)
    return math.floor(((2 * base + (ivs[k] or 0) + math.floor((evs[k] or 0) / 4)) * level) / 100) + 5
  end
  return {
    maxHp = math.floor(((2 * b.hp + (ivs.hp or 0) + math.floor((evs.hp or 0) / 4)) * level) / 100)
      + level + 10,
    attack = other(b.atk, "atk"), defense = other(b.def, "def"), speed = other(b.spe, "spe"),
    spAtk = other(b.spa, "spa"), spDef = other(b.spd, "spd"),
  }
end
function FakePokemon.applyStats(mon)
  local st = FakePokemon.calcStats(mon.species, mon.level, mon.ivs, mon.evs)
  mon.maxHp = st.maxHp
  if mon.hp == nil or mon.hp > st.maxHp then mon.hp = st.maxHp end
  mon.attack, mon.defense, mon.speed = st.attack, st.defense, st.speed
  mon.spAtk, mon.spDef = st.spAtk, st.spDef
  return mon
end
function FakePokemon.gainEVs(mon, foe)
  evCalls[#evCalls + 1] = { mon = mon, foe = foe }
  local meta = P3._speciesMeta[tonumber(foe)] or {}
  mon.evs = mon.evs or {}
  mon.evs.spe = (mon.evs.spe or 0) + (meta.evSpe or 0)
  mon.evs.spa = (mon.evs.spa or 0) + (meta.evSpa or 0)
  return 1
end
function FakePokemon.adjustFriendship(mon, event)
  friendshipCalls[#friendshipCalls + 1] = { mon = mon, event = event }
  mon.friendship = (mon.friendship or 70) + 5
end
function FakePokemon.currentMapSec() return 88 end
function FakePokemon.movesLearnedAt(sp, level)
  local out = {}
  for _, row in ipairs(P3._learnsets[tonumber(sp)] or {}) do
    if row[1] == level then out[#out + 1] = row[2] end
  end
  return out
end
function FakePokemon.moveIdAt(mon, i) return tonumber(mon.moves and mon.moves[i]) end
function FakePokemon.knowsMove(mon, id)
  for i = 1, 4 do if FakePokemon.moveIdAt(mon, i) == tonumber(id) then return true end end
  return false
end
function FakePokemon.moveSlotCount(mon)
  local n = 0
  for i = 1, 4 do if (FakePokemon.moveIdAt(mon, i) or 0) > 0 then n = n + 1 end end
  return n
end
function FakePokemon.teachMove(mon, id)
  for i = 1, 4 do
    if (FakePokemon.moveIdAt(mon, i) or 0) == 0 then
      mon.moves[i] = id
      mon.pp = mon.pp or {}
      mon.maxPp = mon.maxPp or {}
      mon.pp[i] = ROM[id].pp
      mon.maxPp[i] = ROM[id].pp
      return true, i
    end
  end
  return false
end
function FakePokemon.replaceMove(mon, slot, id)
  local old = mon.moves[slot]
  mon.moves[slot] = id
  mon.pp[slot], mon.maxPp[slot] = ROM[id].pp, ROM[id].pp
  return old
end
function FakePokemon.isTradedMon(mon)
  return mon.otId ~= nil and SESSION ~= nil and mon.otId ~= SESSION.trainerId
end
function FakePokemon.displayMonName(mon) return FakePokemon.name(mon.species) end
function FakePokemon.gender() return "M" end
function FakePokemon.frontPic(sp) return { image = fakeImage("front" .. tostring(sp)), w = 64, h = 64 } end
function FakePokemon.backPic(sp) return { image = fakeImage("back" .. tostring(sp)), w = 64, h = 64 } end
function FakePokemon.monFrontPic(mon) return FakePokemon.frontPic(mon.species) end
function FakePokemon.monBackPic(mon) return FakePokemon.backPic(mon.species) end
function FakePokemon.icon(sp) return { image = fakeImage("icon" .. tostring(sp)), w = 32, h = 32, frames = 2, quads = {} } end
function FakePokemon.monIcon(mon) return FakePokemon.icon(mon.species) end

local FakeDex = { captures = {} }
function FakeDex.new() return { seen = {}, caught = {}, owned = {} } end
function FakeDex.isCaught(dex, sp) return dex.caught[tonumber(sp)] == true end
function FakeDex.registerCapture(dex, sp, _, personality)
  local was = dex.caught[sp] == true
  dex.seen[sp], dex.caught[sp] = true, true
  FakeDex.captures[#FakeDex.captures + 1] = { species = sp, personality = personality }
  return was
end
function FakeDex.handleSetPokedexFlag(dex, sp, caught)
  dex.seen[sp] = true
  if caught then dex.caught[sp] = true end
end

local FakeEvolution = { applied = {} }
function FakeEvolution.levelTarget(mon)
  for _, row in ipairs(P3._evolutions[tonumber(mon.species)] or {}) do
    if row.method == 4 and (tonumber(mon.level) or 0) >= row.param then return row.target end
  end
  return nil
end
function FakeEvolution.apply(mon, into, _, _, via)
  mon.species, mon.speciesId = into, into
  FakePokemon.applyStats(mon)
  FakeEvolution.applied[#FakeEvolution.applied + 1] = { mon = mon, into = into, via = via }
  return true
end

local FakeScene = { started = {} }
function FakeScene.start(mon, into, opts)
  FakeScene.started[#FakeScene.started + 1] = { mon = mon, into = into, opts = opts }
  FakeEvolution.apply(mon, into, opts.session, opts.bag, opts.via)
  if opts.onDone then opts.onDone("evolved", mon) end
  return true
end

local FakeStorage = { sent = {} }
function FakeStorage.sendMonToPC(session, mon)
  session.pc = session.pc or {}
  session.pc[#session.pc + 1] = mon
  FakeStorage.sent[#FakeStorage.sent + 1] = mon
  return true, 1, #session.pc
end
function FakeStorage.pcTransferMessage(_, name)
  return tostring(name) .. " was transferred to\nsomeone's PC."
end

-- The learn-move exchange stand-in: it states what it was handed and plays
-- one "yes, forget slot 1" answer through the prompts it was given, which is
-- the whole contract LearnMove.open owes it.
local FakeLearn = { begun = {} }
function FakeLearn.begin(opts)
  FakeLearn.begun[#FakeLearn.begun + 1] = opts
  local mon, id = opts.mon, opts.moveId
  if FakePokemon.moveSlotCount(mon) < 4 then
    FakePokemon.teachMove(mon, id)
    if opts.onDone then opts.onDone(true) end
    return
  end
  if opts.headless then
    if opts.onDone then opts.onDone(false) end
    return
  end
  opts.pushMsg("is trying to learn", function()
    opts.askYesNo("Delete a move?", function(yes)
      if not yes then return opts.onDone(false) end
      opts.askForget({ "a", "b", "c", "d" }, function(slot)
        FakePokemon.replaceMove(mon, (slot or 0) + 1, id)
        opts.onDone(true)
      end, { moveId = id })
    end)
  end)
end

local FakeSummary = { opened = {} }
function FakeSummary.openMenu(party, index, opts)
  FakeSummary.opened[#FakeSummary.opened + 1] = { party = party, opts = opts }
  if opts and opts.onSelectMove then opts.onSelectMove(0) end
end

local audioCalls = {}
local FakeAudio = {}
for _, name in ipairs({ "playSong", "playSe", "playCry", "restoreMapSong", "playFanfare" }) do
  FakeAudio[name] = function(...)
    audioCalls[#audioCalls + 1] = { name, ... }
    return true
  end
end
function FakeAudio.role() return nil end

local function installStubs()
  stub("src.core.game3.runtime", { getSession = function() return SESSION end })
  stub("src.core.game3.pokemon", FakePokemon)
  stub("src.core.game3.bag", FakeBag)
  stub("src.core.game3.dex", FakeDex)
  stub("src.core.game3.evolution", FakeEvolution)
  stub("src.ui.game3.evolution_scene", FakeScene)
  stub("src.core.game3.storage", FakeStorage)
  stub("src.core.game3.battle.learn_move", FakeLearn)
  stub("src.ui.game3.summary_menu", FakeSummary)
  stub("src.core.game3.audio", FakeAudio)
  stub("src.core.game3.battle", { isActive = function() return false end })
  stub("src.core.game3.battle.catching", { playerSecretId = function(s) return s.secretId end })
  -- Song / SE numbers by name (the per-version tables the real module reads).
  stub("src.core.game3.constants", { of = function()
    return { song = function() return 7 end, id = function() return nil end,
             name = function() return nil end }
  end })
end
installStubs()

-- The real pure engine modules, required after the Pokemon stand-in so
-- battle/experience.lua closes over it.
local Experience = require("src.core.game3.battle.experience")
local Types = require("src.core.game3.battle.types")
local Stack = require("src.ui.game3.stack")
check(type(Experience.apply) == "function", "the engine's Gen 3 Experience.apply loads headless")

local need = newNeed()
local Config = need("Config")
local Sheet3 = need("Sheet3")
local Exp3 = need("Exp3")
local Mediated = need("MediatedBattle")
local LearnMove = need("LearnMove")
local EvolveFx = need("EvolveFx")
local Gen = need("Gen")
local Gen3Ui = need("Gen3Ui")
local Vfx = need("Vfx")
local Sim = need("BattleSim3/init")

local function fakeInput()
  return { pressed = {}, wasPressed = function() return false end,
           isDown = function() return false end }
end

local GAME
local function newGame(sessionExtra)
  SESSION = newSession(sessionExtra)
  GAME = { generation = 3, phase = "field", data = DATA, session = SESSION,
           input = fakeInput() }
  stubMod.game = GAME
  Stack.clear()
  return GAME
end

-- A FireRed-shaped party mon, the way party.lua's giveMon leaves one.
local function monOf(species, level, extra)
  local mon = {
    species = species, speciesId = species, level = level,
    nickname = "", growthRate = P3._speciesMeta[species].growthRate,
    exp = Experience.expForLevel(P3._speciesMeta[species].growthRate, level),
    moves = { 10, 45 }, pp = { 35, 40 }, maxPp = { 35, 40 },
    personality = 7, nature = 7,
    ivs = { hp = 31, atk = 31, def = 31, spe = 31, spa = 31, spd = 31 },
    evs = { hp = 0, atk = 0, def = 0, spe = 0, spa = 0, spd = 0 },
    ability = P3._abilities[species][1], gender = "M", friendship = 70,
    heldItem = 0, item = 0, otId = 111, otName = "ANN",
  }
  for k, v in pairs(extra or {}) do mon[k] = v end
  FakePokemon.applyStats(mon)
  if extra and extra.hp then mon.hp = extra.hp end
  return mon
end

-- ------------------------------------------------------------------
-- 1. the sheet (C4 §2)
-- ------------------------------------------------------------------

do
  newGame()
  local mon = monOf(4, 10, { heldItem = 139, item = 139, friendship = 120,
                             status = "PSN", nickname = "EMBERS" })
  local sheet = assert(Sheet3.mon(SESSION, mon, 0))
  eq(sheet.generation, 3, "sheet: dialect tag")
  eq(sheet.species, "EMBERS", "sheet: the nickname is what the sim narrates")
  eq(sheet.speciesId, "4", "sheet: speciesId is the internal number as a string")
  eq(sheet.speciesNum, 4, "sheet: speciesNum is the pret internal id")
  eq(sheet.slot, 0, "sheet: the party index it was cut from")
  eq(sheet.level, 10, "sheet: level")
  eq(sheet.maxHp, mon.maxHp, "sheet: maxHp is the mon's own maximum")
  eq(sheet.hp, mon.hp, "sheet: current HP")
  eq(sheet.stats.atk, mon.attack, "sheet: final Attack (nature/IV/EV applied client-side)")
  eq(sheet.stats.def, mon.defense, "sheet: Defense")
  eq(sheet.stats.spe, mon.speed, "sheet: Speed")
  eq(sheet.stats.spa, mon.spAtk, "sheet: Sp. Atk")
  eq(sheet.stats.spd, mon.spDef, "sheet: Sp. Def")
  eq(sheet.stats.hp, nil, "sheet: HP rides as maxHp, not as a stat")
  eq(#sheet.types, 1, "sheet: a doubled type is dropped to one")
  eq(sheet.types[1], 10, "sheet: pret TYPE_* number")
  eq(sheet.ability, 66, "sheet: ability id")
  eq(sheet.abilityName, "BLAZE", "sheet: ability display name")
  eq(sheet.heldItem, 139, "sheet: held item id")
  eq(sheet.holdEffect, 1, "sheet: its hold effect, from the item row")
  eq(sheet.holdEffectParam, 10, "sheet: and its parameter")
  eq(sheet.itemName, "ORAN BERRY", "sheet: the item's name for `held` narration")
  eq(sheet.gender, "M", "sheet: gender")
  eq(sheet.friendship, 120, "sheet: friendship")
  eq(sheet.weight, 85, "sheet: weight from the dex entry (Low Kick)")
  eq(sheet.nature, 7, "sheet: nature")
  eq(sheet.hiddenPower.type, 17, "sheet: all-31 IVs make Hidden Power Dark")
  eq(sheet.hiddenPower.power, 70, "sheet: ...at 70")
  eq(sheet.beatUp.atk, 52, "sheet: Beat Up reads the species' base Attack")
  eq(sheet.beatUp.def, 43, "sheet: ...and base Defense")
  eq(sheet.status, "PSN", "sheet: the standing condition")
  eq(sheet.catchRate, nil, "sheet: no catch rate on a party sheet")
  eq(sheet.ivs.atk, 31, "sheet: IVs pass through for a caught rebuild")
  eq(sheet.personality, 7, "sheet: personality passes through")
  eq(#sheet.moves, 2, "sheet: every known move")
  local row = sheet.moves[2]
  eq(row.id, "GROWL", "move row: the token")
  eq(row.name, "GROWL", "move row: display name")
  eq(row.num, 45, "move row: pret MOVE_* number")
  eq(row.pp, 40, "move row: pp")
  eq(row.maxPp, 40, "move row: maxPp")
  eq(row.power, 0, "move row: power")
  eq(row.type, 0, "move row: type")
  eq(row.accuracy, 100, "move row: accuracy in percent")
  eq(row.effect, 18, "move row: EFFECT_* number")
  eq(row.target, 8, "move row: MOVE_TARGET_* bits")
  eq(row.priority, 0, "move row: priority")
  eq(row.flags, 18, "move row: flag bits")
  for _, key in ipairs({ "id", "name", "num", "pp", "maxPp", "power", "type", "accuracy",
                         "effect", "chance", "target", "priority", "flags" }) do
    check(row[key] ~= nil, "move row carries " .. key)
  end

  -- What the referee makes of it: the sim's own ingest keeps every number.
  local copied = Sim.Turn.copyMon and Sim.Turn.copyMon(sheet) or nil
  if copied then
    eq(copied.stats.spa, sheet.stats.spa, "BattleSim3 reads the sheet's Sp. Atk")
    eq(copied.holdEffect, 1, "...the hold effect")
    eq(copied.hiddenPower.type, 17, "...and Hidden Power")
  end

  local wild = assert(Sheet3.mon(SESSION, monOf(16, 3), 0, { wild = true }))
  eq(wild.catchRate, 255, "sheet: a wild seat carries its species' catch rate")
  eq(wild.types[2], 2, "sheet: a second type rides beside the first")

  eq(Sheet3.mon(SESSION, monOf(4, 5, { isEgg = true }), 0), nil, "an egg is not a fighter")
  eq(Sheet3.mon(SESSION, { species = 999, level = 5, moves = { 10 } }, 0), nil,
     "a species this cart has no row for is skipped")
  eq(Sheet3.mon(SESSION, monOf(4, 5, { moves = {} }), 0), nil, "a mon with no moves is skipped")
  local bare = monOf(4, 12)
  bare.attack, bare.maxHp = nil, nil
  local recomputed = assert(Sheet3.mon(SESSION, bare, 0))
  eq(recomputed.stats.atk, FakePokemon.calcStats(4, 12, bare.ivs, bare.evs).attack,
     "a mon arriving without its stats has them computed by the engine")

  SESSION.party = { monOf(4, 10), monOf(16, 5, { isEgg = true }), monOf(16, 7) }
  local party = Sheet3.party(GAME)
  eq(#party, 2, "the party sheet skips the egg")
  eq(party[2].slot, 2, "...and keeps each sheet's own party index")
  eq(Mediated.snapshotParty(GAME)[2].slot, 2, "MediatedBattle uploads the Gen 3 sheets")
  eq(Mediated.snapshotMons(GAME, { monOf(16, 3) })[1].catchRate, 255,
     "snapshotMons (the wild / NPC side) stamps the catch rate")

  eq(Sheet3.hiddenPower({ hp = 0, atk = 0, def = 0, spe = 0, spa = 0, spd = 0 }), 1,
     "Hidden Power: no IV bits is Fighting")
  local _, power = Sheet3.hiddenPower({ hp = 2, atk = 2, def = 2, spe = 2, spa = 2, spd = 2 })
  eq(power, 70, "Hidden Power: every second bit set is 70 power")

  -- Sheet3.applyToMon / monFromSheet
  local back = monOf(16, 5)
  Sheet3.applyToMon(back, { hp = 3, status = "PAR", moves = { { num = 10, pp = 1 } } })
  eq(back.hp, 3, "applyToMon: HP")
  eq(back.status, "PAR", "applyToMon: status")
  eq(back.pp[1], 1, "applyToMon: pp by slot, matched by move number")
  local rebuilt = assert(Sheet3.monFromSheet(assert(Sheet3.mon(SESSION, monOf(16, 9,
    { personality = 12345, heldItem = 139 }), 0))))
  eq(rebuilt.species, 16, "monFromSheet: species")
  eq(rebuilt.level, 9, "monFromSheet: level")
  eq(rebuilt.personality, 12345, "monFromSheet: personality")
  eq(rebuilt.heldItem, 139, "monFromSheet: held item")
  eq(rebuilt.moves[1], 10, "monFromSheet: moves by number")
  eq(rebuilt.exp, Experience.expForLevel(3, 9), "monFromSheet: exp on the level's threshold")
end

-- ------------------------------------------------------------------
-- 2. the ruleset (C4 §3)
-- ------------------------------------------------------------------

do
  newGame()
  local rules = Sheet3.ruleset(GAME)
  eq(rules.generation, 3, "ruleset: dialect tag")
  local src = Types.TABLE
  eq(#rules.typeTable, #src, "ruleset: the whole ordered chart")
  eq(#rules.typeTable % 3, 0, "ruleset: flat triples")
  local same = true
  for i = 1, #src do if rules.typeTable[i] ~= src[i] then same = false end end
  check(same, "ruleset: in cart order, untouched")
  local sentinel
  for i = 1, #rules.typeTable, 3 do
    if rules.typeTable[i] == -1 then sentinel = i end
  end
  check(sentinel ~= nil, "ruleset: the Foresight sentinel is there")
  eq(#rules.typeTable - sentinel + 1, 9, "ruleset: ...followed by exactly the two ghost immunities")
  check(#rules.typeTable <= Sheet3.TYPE_TABLE_MAX * 3, "ruleset: inside the triple cap")
  check(#rules.movePool > 0 and #rules.movePool <= Sheet3.MOVE_POOL_MAX, "ruleset: a capped move pool")
  local parsed = Sim.Turn.parsePoolEntry(rules.movePool[1])
  check(parsed ~= nil, "ruleset: pool entries parse on the referee's side")
  eq(parsed and parsed.num, 1, "ruleset: in move-number order")
  local growl
  for _, entry in ipairs(rules.movePool) do
    local p = Sim.Turn.parsePoolEntry(entry)
    if p and p.num == 45 then growl = p end
  end
  eq(growl and growl.effect, 18, "ruleset: a pool row keeps its effect")
  eq(growl and growl.priority, 0, "ruleset: ...and its priority")
  -- An `anim` event names its move by the sheet token only; the VFX catalogue
  -- reads the move's type and power back from the pool.
  local token = growl and growl.id
  local row = token and Sheet3.rowByToken(token)
  eq(row and row.num, 45, "rowByToken: a pool token reads back its move row")
  eq(Sheet3.rowByToken("MOVE_45") and Sheet3.rowByToken("MOVE_45").num, 45,
     "rowByToken: the numeric fallback token reads back too")
  eq(Sheet3.rowByToken("NOT_A_MOVE"), nil, "rowByToken: an unknown token is nil")
  local spec = Vfx.forMove3(token, row)
  check(type(spec) == "table" and spec.style ~= nil,
        "a Gen 3 anim token resolves a VFX look through its row")
  eq(rules.weather, nil, "ruleset: a fight between players has clear skies")
  stub("src.core.game3.weather", { get = function() return 3 end })
  eq(Sheet3.ruleset(GAME, { wild = true }).weather, "RAIN",
     "ruleset: a wild fight opens under the overworld's rain")
  eq(Sheet3.ruleset(GAME, { weather = "SUN", terrain = 4, underwater = true }).terrain, 4,
     "ruleset: a caller's terrain rides along")
  package.loaded["src.core.game3.weather"] = nil
  eq(Mediated.snapshotRuleset(GAME).typeTable ~= nil, true,
     "MediatedBattle's ruleset is Sheet3's on Gen 3")
end

-- ------------------------------------------------------------------
-- 2b. badge rules (docs/plans/gen3-badge-rules.md): the badges and the
--     obedience facts a client sends, and only where they count
-- ------------------------------------------------------------------

-- K1: the cart's own badge flags, as badge numbers, in a fight against the
-- computer; none in a link battle.  Read through the engine's real flag and
-- battle-profile modules (Engine.hasBadge's order), with FireRed's
-- Flags.hasBadge answered off a `badges` set as the solo suite does -- its
-- version table is not this fixture's to build.  This fixture has no live
-- flag store (the real scripting.space does not load under its stand-ins),
-- so the session's flags are read; the live store's precedence is
-- tests/gen3_solo.lua's.
do
  newGame()
  local Wire = need("Wire")
  local Flags = require("src.core.game3.scripting.flags")
  local realHas = Flags.hasBadge
  Flags.hasBadge = function(store, n)
    return type(store.badges) == "table" and store.badges[n] == true
  end
  local function list(mode) return table.concat(Mediated.badgesOf(GAME, mode) or {}, ",") end

  eq(Mediated.badgesOf(GAME, "wild"), nil, "badges: none held, none sent")
  SESSION.badges = { [1] = true, [3] = true }
  eq(list("wild"), "1,3", "badges: a wild fight sends the save's badge numbers")
  eq(list("coop_npc"), "1,3", "badges: ...as does a trainer fight")
  eq(list("coop_wild"), "1,3", "badges: ...and a co-op wild one")
  eq(list(nil), "1,3", "badges: a caller naming no mode is not in a link battle")
  eq(Mediated.badgesOf(GAME, "1v1"), nil, "badges: a 1v1 is a link battle and sends none")
  eq(Mediated.badgesOf(GAME, "coop_pvp"), nil, "badges: ...nor does coop_pvp")
  check(Wire.badges(Mediated.badgesOf(GAME, "wild"))["3"] == true,
        "badges: the badge numbers pass Wire.badges")

  -- Emerald: the battle profile's own badge flags (FLAG_BADGE01_GET is 0x867
  -- there), asked flag by flag -- never FireRed's 0x820, never Flags.hasBadge.
  SESSION.version = "emerald"
  SESSION.badges = { [4] = true }
  SESSION.flags = { [0x820] = true, [0x867] = true, [0x86D] = true }
  eq(list("coop_npc"), "1,7", "badges (rse): the profile's badge flags")
  eq(Mediated.badgesOf(GAME, "1v1"), nil, "badges (rse): ...and none in a link battle")
  Flags.hasBadge = realHas
end

-- K2: the obedience check's facts on this player's own sheets, off the link.
-- `unfateful` names the one Mew / Deoxys the engine's check punishes -- an
-- explicit `fatefulEncounter == false` (battle/engine.lua:1299) -- and the
-- referee reads `unfateful == true`, so an absent flag is the ordinary rules.
do
  newGame()
  local Wire = need("Wire")
  SESSION.party = {
    monOf(16, 5),                                        -- ANN's own catch
    monOf(16, 5, { otId = 999 }),                        -- another trainer's id
    monOf(16, 5, { otName = "BOB" }),                    -- ANN's id, another name
    monOf(151, 5, { fatefulEncounter = true }),          -- an event MEW
    monOf(151, 5, { fatefulEncounter = false }),         -- a MEW without the bit
    monOf(151, 5),                                       -- the field never set
  }
  local own = Mediated.snapshotParty(GAME, { link = false })
  eq(#own, 6, "K2: every monster is described")
  eq(own[1].traded, nil, "traded: ANN's own catch is not")
  eq(own[2].traded, true, "traded: another OT id is (Engine.isTradedMon)")
  eq(own[3].traded, true, "traded: ...as is ANN's id under another OT name")
  eq(own[4].unfateful, nil, "unfateful: an event MEW carries nothing")
  eq(own[5].unfateful, true, "unfateful: a MEW whose bit is explicitly clear (engine.lua:1299)")
  eq(own[6].unfateful, nil,
     "unfateful: ...not one that never had the field, which obeys as the engine's does")
  local retired = false
  for i = 1, #own do
    if own[i].fateful ~= nil then retired = true end
  end
  eq(retired, false, "K2: the retired fateful is never sent")
  SESSION.party = { monOf(16, 5, { fatefulEncounter = false }) }
  local other = Mediated.snapshotParty(GAME, { link = false })
  eq(other[1] and other[1].unfateful, nil, "unfateful: only MEW and DEOXYS carry it")
  SESSION.party = {
    monOf(16, 5, { otId = 999 }),
    monOf(151, 5, { fatefulEncounter = false }),
  }
  local linked = Mediated.snapshotParty(GAME, { link = true })
  eq(linked[1].traded, nil, "K2: a link battle's sheets carry no traded")
  eq(linked[2].unfateful, nil, "K2: ...and no unfateful")
  local foe = Mediated.snapshotMons(GAME, { monOf(16, 5, { otId = 999 }),
                                            monOf(151, 5, { fatefulEncounter = false }) })
  eq(foe[1].traded, nil, "K2: a wild or trainer monster's sheet never carries traded")
  eq(foe[2].unfateful, nil, "K2: ...or unfateful")

  -- Wire's Gen 3 dialect keeps them, as `true` or absent; a non-boolean
  -- refuses the mon; the Gen 1 / Gen 2 reader never copies them; the retired
  -- `fateful` is not read at all.
  local clean = Wire.battleMon(own[2])
  eq(clean and clean.traded, true, "wire: traded survives the Gen 3 dialect")
  clean = Wire.battleMon(own[5])
  eq(clean and clean.unfateful, true, "wire: ...as does unfateful")
  local copy = {}
  for k, v in pairs(own[1]) do copy[k] = v end
  copy.traded, copy.unfateful = false, false
  clean = Wire.battleMon(copy)
  check(clean ~= nil and clean.traded == nil and clean.unfateful == nil,
        "wire: a false is read as absent")
  copy.traded, copy.unfateful = "yes", nil
  eq(Wire.battleMon(copy), nil, "wire: a non-boolean traded refuses the mon")
  copy.traded, copy.unfateful = nil, 1
  eq(Wire.battleMon(copy), nil, "wire: ...as does a non-boolean unfateful")
  copy.unfateful, copy.fateful = nil, true
  clean = Wire.battleMon(copy)
  check(clean ~= nil and clean.fateful == nil and clean.unfateful == nil,
        "wire: the retired fateful is dropped, not copied")
  copy.fateful = 1
  check(Wire.battleMon(copy) ~= nil, "wire: ...and never read, so a non-boolean one refuses nothing")
  local party = Wire.battleParty({ battle = "k2", mons = own }, 3)
  eq(party and party.mons[2].traded, true, "wire: a Gen 3 party keeps traded")
  eq(party and party.mons[5].unfateful, true, "wire: ...and unfateful")
  eq(party and party.mons[4].unfateful, nil, "wire: ...on the one MEW that named it")
end

-- ------------------------------------------------------------------
-- 3. the bag (C4 §4)
-- ------------------------------------------------------------------

do
  newGame()
  FakeBag.add(SESSION.bag, 13, 3)
  FakeBag.add(SESSION.bag, 96, 1)          -- a stone: not a battle item
  FakeBag.add(SESSION.bag, 4, 150)         -- more than the wire takes
  FakeBag.add(SESSION.bag, 139, 2)
  FakeBag.add(SESSION.bag, 350, 1)
  local bag = Sheet3.bag(GAME)
  local ids = {}
  for _, e in ipairs(bag) do ids[#ids + 1] = e.id end
  eq(table.concat(ids, ","), "4,13,139,350", "bag: §4 ids only, in id order")
  eq(bag[1].count, Config.BATTLE_BAG_COUNT_MAX, "bag: a stack is capped for the wire")
  eq(bag[2].name, "POTION", "bag: names ride for the referee's narration")
  local ok = Sim.Turn.create({
    id = "b", mode = "wild", seed = 1,
    sides = { a = { { playerId = "me", name = "ANN", mons = { assert(Sheet3.mon(SESSION, monOf(4, 5), 0)) },
                      bag = bag } },
              b = { { playerId = "wild", name = "WILD", mons = { assert(Sheet3.mon(SESSION, monOf(16, 3), 0, { wild = true })) } } } },
  })
  check(ok ~= nil, "bag: the referee takes the upload")

  eq(Mediated.snapshotBag(GAME)[1].id, 4, "MediatedBattle uploads the Gen 3 bag")
  eq(Mediated.itemIsBattleUsable(13, GAME).needsParty, true, "a POTION wants a party pick")
  eq(Mediated.itemIsBattleUsable(4, GAME).ball, true, "a POKe BALL is a ball")
  eq(Mediated.itemIsBattleUsable(350, GAME).noConsume, true, "the POKe FLUTE is never spent")
  eq(Mediated.itemIsBattleUsable(24, GAME).faintedOnly, true, "a REVIVE is for the fainted")
  eq(Mediated.itemIsBattleUsable(96, GAME), nil, "a stone is not usable in battle")
  eq(Mediated.writebackVitamin(GAME, 1, 63), false, "no vitamins in a Gen 3 battle")
  local trainerBag = Sheet3.trainerBag({ items = { 13, 13, 96, 0 } })
  eq(#trainerBag, 1, "an NPC's kit keeps §4 ids only")
  eq(trainerBag[1].count, 2, "...one use per listed item")
  eq(Mediated.trainerBagEntries({ items = { 22 } }, GAME)[1].id, 22,
     "MediatedBattle builds a Gen 3 NPC kit without SoloBrain")

  -- The menu, the spend and the writeback.
  local sent = {}
  local fight = Mediated.new({
    transport = { isReady = function() return true end,
                  send = function(_, kind, msg) sent[#sent + 1] = { kind = kind, msg = msg } end },
    game = GAME, battle = "bag1", role = "host", peerId = "p", peerName = "BOB",
  })
  fight.bagSheet = Mediated.bagCounts(bag)
  eq(fight.bagSheet[13], 3, "bagCounts keeps numeric ids")
  local rows = fight:usableItems()
  eq(rows[1].id, 4, "usable items: in bag-id order")
  eq(rows[2].name, "POTION", "usable items: the cart's name")
  fight.itemPick = { id = 13, effect = Sheet3.itemEffect(13) }
  fight:commitItem(1, nil)
  local choice = sent[#sent].msg
  eq(choice.item, "13", "the choice names the item by its number, as a string")
  eq(fight.pendingItem, 13, "the item waits for the referee")
  eq(FakeBag.get(SESSION.bag, 13), 3, "...and nothing is spent until it answers")
  fight:onEvent({ battle = "bag1", seq = 1, t = "item", slot = 0, side = "a", text = "13" })
  eq(FakeBag.get(SESSION.bag, 13), 2, "the `item` event spends one from the session's pocket")
  eq(fight.bagSheet[13], 2, "...and from the uploaded sheet")
  fight.itemPick = { id = 350, effect = Sheet3.itemEffect(350) }
  fight:commitItem(nil, nil)
  fight:onEvent({ battle = "bag1", seq = 2, t = "item", slot = 0, side = "a", text = "350" })
  eq(FakeBag.get(SESSION.bag, 350), 1, "the POKe FLUTE is not spent")
end

-- ------------------------------------------------------------------
-- 4. the award (Exp3; synthetic numbers)
-- ------------------------------------------------------------------

do
  eq(Exp3.calculated(64, 10), 91, "exp: floor(64 * 10 / 7)")
  local e, s = Exp3.split(91, 1, 0)
  eq(e, 91, "exp: one participant, no Share")
  eq(s, 0, "exp: ...no share pool")
  e = Exp3.split(91, 2, 0)
  eq(e, 45, "exp: two participants split it")
  e, s = Exp3.split(91, 1, 1)
  eq(e, 45, "exp: a Share holder halves the fighters' pool")
  eq(s, 45, "exp: ...and takes the other half")
  e, s = Exp3.split(91, 1, 2)
  eq(s, 22, "exp: two holders split the share half")
  e = Exp3.split(1, 3, 0)
  eq(e, 1, "exp: never below one")
  eq(Exp3.amount(45, 45, { sentIn = true, holder = true }), 90,
     "exp: a holder that fought takes both halves")
  eq(Exp3.amount(45, 45, { holder = true }), 45, "exp: a bystander holder takes the share")
  eq(Exp3.amount(91, 0, { sentIn = true, luckyEgg = true }), 136, "exp: Lucky Egg x1.5, floored")
  eq(Exp3.amount(91, 0, { sentIn = true, luckyEgg = true, trainer = true }), 204,
     "exp: ...then a trainer's x1.5")
  eq(Exp3.amount(91, 0, { sentIn = true, luckyEgg = true, trainer = true, traded = true }), 306,
     "exp: ...then a traded mon's x1.5")

  newGame()
  local fighter = monOf(4, 6)
  local holder = monOf(16, 8, { heldItem = 182, item = 182 })
  local egg = monOf(16, 5, { isEgg = true })
  local fainted = monOf(16, 8, { hp = 0 })
  local traded = monOf(16, 8, { otId = 999, heldItem = 197, item = 197 })
  SESSION.party = { fighter, holder, egg, fainted, traded }
  -- Six points short of level 7 on MEDIUM_SLOW (the engine's own curve).
  fighter.exp = Experience.expForLevel(3, 7) - 6
  evCalls, friendshipCalls = {}, {}
  local results = assert(Exp3.award({ species = 16, level = 8, isTrainer = false,
    sentIn = { [1] = true, [5] = true, [4] = true }, party = SESSION.party }))
  -- calculated = floor(55 * 8 / 7) = 62; living fighters 2 (the fainted one
  -- does not count), one holder: exp = floor(31 / 2) = 15, share = 31.
  eq(#results, 3, "award: the two living fighters and the holder, nobody else")
  eq(results[1].index, 1, "award: in party order")
  eq(results[1].amount, 15, "award: a fighter's half of the halved pool")
  eq(results[2].amount, 31, "award: the bystander holder's share")
  eq(results[3].amount, 33, "award: Lucky Egg then traded on the fighter's 15 (22, 33)")
  eq(results[3].boosted, true, "award: a traded mon's line says boosted")
  eq(#evCalls, 3, "award: every recipient gains EVs")
  eq(evCalls[1].foe, 16, "award: ...from the fallen species")
  eq(fighter.evs.spe, 1, "award: the EV yield lands")
  eq(fighter.level, 7, "award: 15 exp crosses the six points to level 7 (engine curve)")
  eq(#results[1].levels, 1, "award: the level list")
  eq(#friendshipCalls, 1, "award: friendship moves once per level crossed")
  eq(Exp3.award({ species = 16, level = 8, sentIn = { [1] = true },
                  party = { monOf(4, 100) } })[1], nil, "award: level 100 earns nothing")
  local frac = Exp3.fraction(fighter)
  check(frac ~= nil and frac >= 0 and frac <= 1, "exp strip: a fraction of the level")
  check(Exp3.gainedText("A", 5):find("5", 1, true) ~= nil, "gained line names the amount")
  -- The cart's printer codes never reach a mod box.
  eq(Exp3.cleanText("A gained\\l5 EXP. Points!\\p"), "A gained\n5 EXP. Points!",
     "cart text: \\l is a line break and a trailing \\p goes")
  local paged = Mediated.new({ game = GAME, battle = "p" })
  paged:say("one\\ptwo")
  eq(#paged.lines, 2, "cart text: a \\p starts a page of its own in the battle box")
  eq(paged.lines[2], "two", "cart text: ...with nothing of the code left")
end

-- ------------------------------------------------------------------
-- 5. learn and evolve, the Gen 3 arms
-- ------------------------------------------------------------------

do
  newGame()
  local mon = monOf(4, 7, { moves = { 10, 45 }, pp = { 35, 40 }, maxPp = { 35, 40 } })
  eq(LearnMove.apply(mon, 52, nil), "learned", "LearnMove.apply: a numeric id fills a free slot")
  eq(mon.moves[3], 52, "...in the next slot")
  eq(mon.pp[3], 25, "...with its full PP")
  eq(LearnMove.apply(mon, 52, nil), "known", "LearnMove.apply: already known")
  eq(LearnMove.apply(mon, 9999, nil), "missing", "LearnMove.apply: no row, no move")
  mon.moves[4], mon.pp[4], mon.maxPp[4] = 33, 35, 35
  eq(LearnMove.apply(mon, 98, nil), "full", "LearnMove.apply: four known is the prompt's job")

  local said, asked = {}, {}
  local ui = {
    say = function(_, text, cb) said[#said + 1] = text; if cb then cb() end; return {} end,
    confirm = function(_, _, text, cb) asked[#asked + 1] = text; cb(true); return {} end,
  }
  FakeLearn.begun, FakeSummary.opened = {}, {}
  local answered
  check(LearnMove.open(GAME, mon, 98, function(learned) answered = learned end, { ui = ui }),
        "LearnMove.open: Gen 3 runs the cart's exchange")
  local opts = FakeLearn.begun[1]
  eq(opts and opts.battleText, true, "the battle wording, mid-fight")
  eq(opts and opts.moveId, 98, "the numeric move id")
  eq(#said, 1, "its messages go to the caller's boxes")
  eq(#asked, 1, "its yes / no too")
  eq(#FakeSummary.opened, 1, "the forget picker is the summary screen's")
  eq(FakeSummary.opened[1].opts.mode, "select_move", "...in select_move mode")
  eq(answered, true, "onDone fires once the move is learned")
  eq(mon.moves[1], 98, "and the forgotten slot holds the new move")

  -- EvolveFx
  local low = monOf(4, 15)
  eq(EvolveFx.pending(GAME, low), nil, "evolve: not yet")
  local ready = monOf(4, 16)
  local pending = EvolveFx.pending(GAME, ready)
  eq(pending and pending.into, 5, "evolve: the cart's level rule says CHARMELEON")
  local q = {}
  local row = EvolveFx.enqueue(q, GAME, ready, {})
  eq(row and row.name, "CHARMANDER", "evolve: the movie names the mon the cart's way")
  local movie = EvolveFx.begin(row)
  eq(EvolveFx.applyTo(GAME, movie, {}), ready, "evolve: applied in place")
  eq(ready.species, 5, "evolve: through the cart's Evolution.apply")
  eq(FakeEvolution.applied[#FakeEvolution.applied].via, "level", "evolve: via level")
  local lines = EvolveFx.evolvedLine(movie, GAME)
  check(lines:find("CHARMELEON", 1, true) ~= nil, "evolve: the line names the new species")
  audioCalls = {}
  EvolveFx.playMusic(GAME, nil)
  eq(audioCalls[1] and audioCalls[1][1], "playSong", "evolve: the movie plays the cart's song")
  EvolveFx.playCry(GAME, nil, 5)
  eq(audioCalls[2] and audioCalls[2][1], "playCry", "evolve: and the new form's cry")

  -- the after-battle offer: EvolutionScene, one at a time, a win only
  FakeScene.started = {}
  local a, b = monOf(4, 16), monOf(4, 17)
  SESSION.party = { a, b }
  eq(EvolveFx.offerEvolutions(GAME, { [a] = true, [b] = true }, "loss", nil, {}), false,
     "offer: nothing after a loss (the cart evolves only after a win)")
  check(EvolveFx.offerEvolutions(GAME, { [a] = true, [b] = true }, "win", nil, {}),
        "offer: the cart's scene after a win")
  eq(#FakeScene.started, 2, "offer: both qualifying mons, one scene each")
  eq(FakeScene.started[1].mon, a, "offer: in party order")
end

-- ------------------------------------------------------------------
-- 6. a fight, refereed by BattleSim3 in this process
-- ------------------------------------------------------------------

local function referee(opts)
  local battle = assert(Sim.Turn.create(opts))
  return battle
end

-- A screen wired to a local referee: the upload lands in `pending`, a choice
-- goes straight to the sim, and pump() replays the stream into the screen.
local function harness(mode, foeSheets, extra)
  local pending = {}
  local battle
  local transport = {
    isReady = function() return true end,
    send = function(_, kind, msg)
      if kind == "mmo.battle_choice" or (msg and msg.action) then
        local c = {}
        for k, v in pairs(msg) do if k ~= "battle" then c[k] = v end end
        local took = battle and battle:submitChoice("me", c) or false
        -- The wild seat is the referee's own to answer (the hub auto-picks it).
        if took and mode == "wild" then battle:autoPick("wild") end
        return took
      elseif msg and msg.mons then
        if msg.side == "b" then pending.foe = msg else pending.party = msg end
      elseif msg and (msg.typeTable or msg.movePool) then
        pending.ruleset = msg
      end
    end,
  }
  local said = {}
  local ui = {
    say = function(_, text, cb) said[#said + 1] = text; if cb then cb() end; return {} end,
    confirm = function(_, _, text, cb) said[#said + 1] = text; cb(true); return {} end,
    askNickname = function(_, _, mon, label) said[#said + 1] = "NICKNAME " .. tostring(label); return true end,
  }
  local fight = Mediated.new({
    transport = transport, ui = ui, game = GAME, battle = "g3", role = "host",
    peerId = (mode ~= "wild") and "peer" or nil, peerName = "BOB", mode = mode,
    wildParty = (mode == "wild") and foeSheets or nil,
    wildCatchMon = extra and extra.wildCatchMon,
    classicUi = extra and extra.classicUi,
  })
  fight:start(GAME)
  local ruleset = pending.ruleset or {}
  battle = referee({
    id = "g3", mode = mode, seed = extra and extra.seed or 7,
    typeTable = ruleset.typeTable, movePool = ruleset.movePool,
    weather = ruleset.weather,
    sides = {
      a = { { playerId = "me", name = "ANN", mons = pending.party.mons, bag = pending.party.bag } },
      b = { { playerId = (mode == "wild") and "wild" or "peer", name = "BOB",
              mons = foeSheets } },
    },
  })
  fight:onReady({ battle = "g3", mode = mode, sides = { a = { "me" }, b = { (mode == "wild") and "wild" or "peer" } } })
  local seq = 0
  local function pump()
    battle:tick(0)
    for _, e in ipairs(battle:drainEvents()) do
      seq = math.max(seq, e.seq or 0)
      fight:onEvent(e)
    end
    local out = battle:outcome()
    if out and not fight.finished then
      fight:onOutcome({ battle = "g3", outcome = out.outcome, winners = out.winners,
                        losers = out.losers, reason = out.reason, caught = out.caught,
                        payDay = out.payDay })
    end
    for _ = 1, 400 do
      fight:update(2.0)
      if fight.phase == "choose" or fight.phase == "switch" or (fight.phase == "over"
         and #fight.lines == 0 and not fight.shown) then break end
    end
    -- The frame after the last line is read is the one that asks for a
    -- catch's nickname (MediatedBattle:update's over branch).
    if fight.phase == "over" then fight:update(2.0) end
  end
  return { fight = fight, battle = battle, pump = pump, pending = pending, said = said }
end

local function allText(h)
  local out = {}
  for _, line in ipairs(h.fight.textLog or {}) do out[#out + 1] = line end
  return table.concat(out, " | ")
end

-- Record every line the screen shows, in order.
do
  local say = Mediated.say
  Mediated.say = function(self, text)
    self.textLog = self.textLog or {}
    self.textLog[#self.textLog + 1] = tostring(text)
    return say(self, text)
  end
end

-- (a) 1v1: an ability, the weather, a stat drop, a berry, a faint, the result.
do
  newGame()
  local mine = monOf(4, 20, { moves = { 45, 33 }, pp = { 40, 35 }, maxPp = { 40, 35 },
                              heldItem = 139, item = 139 })
  mine.hp = math.floor(mine.maxHp / 2)
  SESSION.party = { mine }
  local foe = assert(Sheet3.mon(SESSION, monOf(151, 10, { moves = { 33 }, pp = { 35 }, maxPp = { 35 } }), 0))
  foe.ability, foe.abilityName = 2, "DRIZZLE"
  local statSigns = {}
  local forStat = Vfx.forStat
  Vfx.forStat = function(dir) statSigns[#statSigns + 1] = dir; return forStat(dir) end
  local h = harness("1v1", { foe })
  eq(h.pending.party.generation, 3, "1v1: the party upload says generation 3")
  check(h.pending.ruleset and h.pending.ruleset.typeTable ~= nil, "1v1: the host uploads the ordered chart")
  h.pump()
  eq(h.fight.weatherShown, "RAIN", "1v1: DRIZZLE's rain is over the field once its row played")
  local foeSlot = h.fight.slots[h.fight:foeSlot()]
  eq(foeSlot and foeSlot.ability and foeSlot.ability.id, 2, "1v1: the seat remembers the ability that acted")
  eq(h.fight:battlefieldCtx().weather, "RAIN", "1v1: the arena is told about the rain")
  eq(h.fight.phase, "choose", "1v1: the command grid opens")
  eq(h.fight:commandList()[2], "ITEM", "1v1: the cart's grid order, FIGHT BAG / POKeMON RUN")
  eq(h.fight:bandCommandItems()[3].label, "POKéMON", "1v1: ...with the cart's labels")
  eq(h.fight:moveLabel("GROWL"), "GROWL", "1v1: a move is named off our own sheet")
  h.fight:pickMove(1)   -- GROWL
  h.battle:submitChoice("peer", { action = "fight", move = 0 })
  h.pump()
  check(#statSigns > 0 and statSigns[1] < 0, "1v1: a stat drop reads as a drop off its delta")
  -- A link fight's party is reloaded after it (cable_club.c:776
  -- CB2_ReturnFromCableClubBattle -> LoadPlayerParty): the berry is gone from
  -- the fight, and still held in the save.
  eq(h.fight.mine[1].heldItem, 0, "1v1: the ORAN BERRY eaten in the fight is gone from the fight sheet")
  eq(mine.heldItem, 139, "1v1: ...and still on the save mon (the cart reloads the party)")
  local guard = 0
  while not h.fight.finished and guard < 30 do
    guard = guard + 1
    if h.fight.phase == "choose" then h.fight:pickMove(2) end
    h.battle:submitChoice("peer", { action = "fight", move = 0 })
    h.pump()
  end
  check(h.fight.finished, "1v1: the fight ends")
  local text = allText(h)
  check(text:find("fainted", 1, true) ~= nil, "1v1: a faint is narrated")
  check(text:find("You lost!", 1, true) ~= nil or text:find("You won!", 1, true) ~= nil,
        "1v1: the result is said")
  eq(h.fight.expPaid, nil, "1v1: link rules, no exp")
  Vfx.forStat = forStat
  eq(h.fight:drawsWidescreen(), h.fight:usesBattlefield(),
     "Gen 3 takes the window-space path whenever the arena is up")
  local classic = setmetatable({ game = GAME, classicUi = true }, { __index = Mediated })
  eq(classic:drawsWidescreen(), false, "...and CLASSIC BATTLE UI draws into the 240x160 canvas")
end

-- (b) wild: exp, a level, a move to learn with a full moveset, and the catch.
do
  newGame()
  local mine = monOf(4, 6, { moves = { 10, 45, 33, 1 }, pp = { 35, 40, 35, 35 },
                             maxPp = { 35, 40, 35, 35 } })
  SESSION.party = { mine }
  FakeBag.add(SESSION.bag, 1, 1)
  local wildMon = monOf(16, 8, { hp = 1, moves = { 45 }, pp = { 40 }, maxPp = { 40 } })
  local foe = assert(Sheet3.mon(SESSION, wildMon, 0, { wild = true }))
  FakeLearn.begun = {}
  local h = harness("wild", { foe }, { classicUi = true })
  h.pump()
  eq(h.fight.phase, "choose", "wild: the grid opens")
  h.fight:pickMove(1)   -- SCRATCH knocks the 1-HP PIDGEY out
  h.pump()
  local guard = 0
  while not h.fight.finished and guard < 20 do
    guard = guard + 1
    if h.fight.phase == "choose" then h.fight:pickMove(1) end
    h.pump()
  end
  check(h.fight.finished, "wild: the knockout ends the fight")
  eq(h.fight.expPaid, 1, "wild: one award, priced on this client")
  eq(mine.level, 7, "wild: the award levelled the session mon (engine curve)")
  eq(mine.evs.spe, 1, "wild: and paid its EVs")
  local text = allText(h)
  check(text:find("gained", 1, true) ~= nil, "wild: the gained line")
  check(text:find("7", 1, true) ~= nil, "wild: the grew-to line")
  eq(#FakeLearn.begun, 1, "wild: EMBER at level 7 with four moves opens the cart's prompt")
  eq(FakeLearn.begun[1] and FakeLearn.begun[1].moveId, 52, "wild: ...for EMBER")
  eq(mine.moves[1], 52, "wild: answered, the forgotten slot holds EMBER")
  eq(h.fight.learning, nil, "wild: the prompt released the queue")
  eq(h.fight.mine[1].moves[1].num, 52, "wild: the fight sheet was republished with EMBER")
  Mediated.draw(h.fight)
  eq(h.fight.drawFailed, nil, "the Gen 3 page (CLASSIC BATTLE UI) draws headless")

  -- The catch: a MASTER BALL at a fresh wild mon.
  newGame()
  SESSION.party = { monOf(4, 30) }
  FakeBag.add(SESSION.bag, 1, 1)
  FakeDex.captures = {}
  local target = monOf(16, 5, { otId = 5, otName = "WILD" })
  local sheet = assert(Sheet3.mon(SESSION, target, 0, { wild = true }))
  local c = harness("wild", { sheet }, { wildCatchMon = target, classicUi = true })
  c.pump()
  c.fight.bagSheet = c.fight.bagSheet or {}
  c.fight.itemPick = { id = 1, effect = Sheet3.itemEffect(1) }
  check(c.fight:commitItem(nil, nil), "catch: the ball goes out")
  c.pump()
  local g2 = 0
  while not c.fight.finished and g2 < 10 do g2 = g2 + 1; c.pump() end
  eq(c.fight.result, "win", "catch: a catch is a win")
  eq(#SESSION.party, 2, "catch: the mon joins the session party")
  eq(SESSION.party[2], target, "catch: the engine mon the caller built")
  eq(target.pokeball, 1, "catch: in the ball it was caught in")
  eq(target.otName, "ANN", "catch: the catcher is its original trainer")
  eq(target.otId, 111, "catch: ...by id")
  eq(target.metLocation, 88, "catch: met here")
  eq(#FakeDex.captures, 1, "catch: the dex registers the capture")
  eq(FakeBag.get(SESSION.bag, 1), 0, "catch: the ball is spent")
  check(allText(c):find("added to the party", 1, true) ~= nil, "catch: says where it went")
  check(contains(c.said, "NICKNAME PIDGEY"), "catch: the nickname is offered once the ending has printed")


  -- A full party sends the catch to the PC.
  newGame()
  local six = {}
  for i = 1, 6 do six[i] = monOf(4, 30) end
  SESSION.party = six
  FakeBag.add(SESSION.bag, 1, 1)
  FakeStorage.sent = {}
  local boxed = monOf(16, 5)
  local c2 = harness("wild", { assert(Sheet3.mon(SESSION, boxed, 0, { wild = true })) },
    { wildCatchMon = boxed, classicUi = true })
  c2.pump()
  c2.fight.itemPick = { id = 1, effect = Sheet3.itemEffect(1) }
  c2.fight:commitItem(nil, nil)
  local g3 = 0
  while not c2.fight.finished and g3 < 10 do g3 = g3 + 1; c2.pump() end
  eq(#FakeStorage.sent, 1, "catch: a full party sends it to the PC")
  eq(#SESSION.party, 6, "catch: ...and leaves the party as it was")
  check(allText(c2):find("PC", 1, true) ~= nil, "catch: in the cart's words")
end

-- (c) a level-up evolution mid-fight, and the leave.
do
  newGame()
  local mine = monOf(4, 15, { moves = { 10, 45 }, pp = { 35, 40 }, maxPp = { 35, 40 } })
  SESSION.party = { mine }
  local foe = assert(Sheet3.mon(SESSION, monOf(16, 64, { hp = 1, moves = { 45 }, pp = { 40 },
    maxPp = { 40 } }), 0, { wild = true }))
  FakeEvolution.applied = {}
  local h = harness("wild", { foe }, { classicUi = true })
  h.pump()
  h.fight:pickMove(1)
  h.pump()
  local guard = 0
  while not h.fight.finished and guard < 20 do guard = guard + 1; h.pump() end
  eq(mine.level, 16, "evolve: the award crossed level 16")
  eq(#FakeEvolution.applied, 1, "evolve: the movie applied the evolution")
  eq(mine.species, 5, "evolve: CHARMANDER is now CHARMELEON")
  eq(h.fight.mine[1].species, "CHARMELEON", "evolve: the fight sheet takes the new name")
  eq(h.fight.mine[1].speciesId, "5", "evolve: ...and the new species number")
  eq(h.fight.evoResolved and h.fight.evoResolved[mine], true,
     "evolve: resolved on the arena, so the after-battle offer skips it")

  -- The screen leaves the game3 stack through Gen3Ui (there is no game.stack).
  Gen3Ui.pushState(GAME, h.fight)
  check(Gen3Ui.has(h.fight), "the fight is a game3 layer")
  h.fight:leave()
  check(not Gen3Ui.has(h.fight), "leave() pops it through Gen3Ui")
  eq(h.fight.left, true, "...and ran exit on the way")
end

-- (d) the six Gen 3 kinds, by hand: each lands in the queue's order.
do
  newGame()
  local mine = monOf(4, 20, { heldItem = 139, item = 139 })
  SESSION.party = { mine }
  local f = Mediated.new({ game = GAME, battle = "k", role = "host", peerId = "p",
                           peerName = "BOB", classicUi = true })
  f.mine = Sheet3.party(GAME)
  local seq = 0
  local function ev(e) seq = seq + 1; e.battle, e.seq = "k", seq; f:onEvent(e) end
  local function drain() for _ = 1, 40 do f:update(2.0) end end
  ev({ t = "send", slot = 3, side = "b", text = "MEW", speciesId = "151", hp = 50, maxHp = 50, level = 20 })
  ev({ t = "send", slot = 0, side = "a", text = "CHARMANDER", speciesId = "4", hp = 40, maxHp = 40,
       level = 20, mon = 0 })
  ev({ t = "ability", slot = 3, side = "b", amount = 2, text = "DRIZZLE" })
  ev({ t = "weather", slot = 3, side = "b", text = "RAIN", amount = 1 })
  eq(f.weatherShown, nil, "kinds: the sky waits for its row")
  drain()
  eq(f.weatherShown, "RAIN", "kinds: rain once the row played")
  eq(f.slots[3].ability.name, "DRIZZLE", "kinds: the ability that acted")
  ev({ t = "weather", text = "RAIN", amount = 0 })
  drain()
  eq(f.weatherShown, nil, "kinds: the rain ends")
  ev({ t = "sub", slot = 3, side = "b", amount = 1 })
  ev({ t = "form", slot = 3, side = "b", speciesId = "4", text = "CHARMANDER" })
  drain()
  eq(f.slots[3].substitute, true, "kinds: the doll is up")
  eq(f.slots[3].transformId, "4", "kinds: Transform draws the copied species")
  eq(f:seatSpeciesKey(f.slots[3], false), "4", "kinds: ...through the seat's key")
  ev({ t = "held", slot = 0, side = "a", mon = 0, amount = 139, holding = 0, text = "ORAN BERRY" })
  eq(f.mine[1].heldItem, 0, "kinds: a berry eaten leaves the fight sheet")
  eq(mine.heldItem, 139, "kinds: ...and never the save, in a fight between players")
  ev({ t = "held", slot = 3, side = "b", mon = 0, amount = 182, holding = 182 })
  eq(mine.heldItem, 139, "kinds: the foe's `held` never touches our save")
  eq(f.foeHeld and f.foeHeld[0], 182, "kinds: ...it is remembered for a catch")
  ev({ t = "faint", slot = 3, side = "b", text = "MEW" })
  drain()
  ev({ t = "send", slot = 3, side = "b", text = "PIDGEY", speciesId = "16", hp = 30, maxHp = 30, level = 9 })
  drain()
  eq(f.slots[3].substitute, nil, "kinds: a newcomer has no doll")
  eq(f.slots[3].transformId, nil, "kinds: ...and no Transform")
  ev({ t = "ball", slot = 0, side = "a", target = 3, amount = 2, text = "4" })
  local anims = {}
  for _, row in ipairs(f.lines) do if type(row) == "table" and row.anim then anims[#anims + 1] = row.anim end end
  eq(table.concat(anims, ","), "TOSS_ANIM,POOF_ANIM,HIDEPIC_ANIM,SHAKE_ANIM,POOF_ANIM,SHOWPIC_ANIM",
     "kinds: a two-shake break-out is the ball flow's rows")
end

-- ------------------------------------------------------------------
-- 7. review fixes: each block below failed before its fix
-- ------------------------------------------------------------------

-- A screen fed by hand, the way a hub delivers a stream: one event at a time.
local function byHand(mode, extra)
  extra = extra or {}
  local f = Mediated.new({ game = GAME, battle = "rf", role = "host",
    peerId = (mode ~= "wild") and "p" or nil, peerName = extra.peerName or "BOB",
    mode = mode, wildParty = extra.wildParty, wildCatchMon = extra.wildCatchMon,
    trainer = extra.trainer, classicUi = true })
  f.mine = Sheet3.party(GAME)
  local seq = 0
  local function ev(e) seq = seq + 1; e.battle, e.seq = "rf", seq; f:onEvent(e) end
  return f, ev
end

local function gained(mon, before) return (mon.exp or 0) - before end

-- (a) The EXP split asks the referee who is standing, not the save.
do
  -- An Exp. Share holder the referee says fainted: the save still has the HP
  -- it started the fight with.  PIDGEY 8 is floor(55 * 8 / 7) = 62.
  newGame()
  local fighter = monOf(4, 10)
  local holder = monOf(16, 10, { heldItem = 182, item = 182 })
  SESSION.party = { fighter, holder }
  local f, ev = byHand("wild")
  local fx, hx = fighter.exp, holder.exp
  ev({ t = "team", slot = 0, side = "a", team = "ox" })
  ev({ t = "faint", slot = 3, side = "b", text = "PIDGEY" })
  ev({ t = "exp", slot = 0, side = "a", mon = 0, speciesId = "16", level = 8 })
  ev({ t = "msg", text = "next" })
  eq(gained(fighter, fx), 62, "exp split: a holder the referee knocked out halves nothing")
  eq(holder.exp, hx, "exp split: ...and is paid nothing")

  -- A mon that came in fainted and was revived this fight holds the Share.
  newGame()
  fighter = monOf(4, 10)
  local revived = monOf(16, 10, { heldItem = 182, item = 182, hp = 0 })
  SESSION.party = { fighter, revived }
  f, ev = byHand("wild")
  fx, hx = fighter.exp, revived.exp
  ev({ t = "team", slot = 0, side = "a", team = "oo" })
  ev({ t = "faint", slot = 3, side = "b", text = "PIDGEY" })
  ev({ t = "exp", slot = 0, side = "a", mon = 0, speciesId = "16", level = 8 })
  ev({ t = "msg", text = "next" })
  eq(gained(fighter, fx), 31, "exp split: a holder revived this fight halves the pool")
  eq(gained(revived, hx), 31, "exp split: ...and takes the share half")

  -- With no roster yet, the fight sheets' HP answers.
  newGame()
  fighter = monOf(4, 10)
  holder = monOf(16, 10, { heldItem = 182, item = 182 })
  SESSION.party = { fighter, holder }
  f, ev = byHand("wild")
  f.mine[2].hp = 0
  fx = fighter.exp
  ev({ t = "faint", slot = 3, side = "b", text = "PIDGEY" })
  ev({ t = "exp", slot = 0, side = "a", mon = 0, speciesId = "16", level = 8 })
  ev({ t = "msg", text = "next" })
  eq(gained(fighter, fx), 62, "exp split: no roster yet -- the fight sheet's HP says who is down")
end

-- (b) One knockout's `exp` events split across two frames are priced once.
do
  newGame()
  local a, b = monOf(4, 10), monOf(4, 10, { personality = 9 })
  SESSION.party = { a, b }
  local f, ev = byHand("wild")
  local ax, bx = a.exp, b.exp
  ev({ t = "faint", slot = 3, side = "b", text = "PIDGEY" })
  ev({ t = "exp", slot = 0, side = "a", mon = 0, speciesId = "16", level = 8 })
  f:update(2.0)   -- the frame ends between the two halves of one knockout
  ev({ t = "exp", slot = 0, side = "a", mon = 1, speciesId = "16", level = 8 })
  ev({ t = "msg", text = "next" })
  eq(gained(a, ax), 31, "exp frames: both fighters share the one knockout")
  eq(gained(b, bx), 31, "exp frames: ...neither is paid the whole of it")
  eq(f.expPaid, 2, "exp frames: two payments, one pricing")
end

-- (c) `exp.gain` is raised for a mediated award, with the engine's ctx.
do
  local Runtime = require("src.mods.Runtime")
  local prevEvents, prevHooks, prevErrors = Runtime.events, Runtime.hooks, Runtime.errors
  local seen = {}
  Runtime.install(prevEvents, {
    chains = { ["exp.gain"] = { true } },
    call = function(_, name, vanilla, ctx)
      seen[#seen + 1] = { name = name, ctx = ctx }
      return vanilla() * 2
    end,
  }, prevErrors)
  newGame()
  local fighter = monOf(4, 10)
  SESSION.party = { fighter }
  local results = Exp3.award({ species = 16, level = 8, sentIn = { [1] = true },
                               party = SESSION.party, battle = "screen" })
  Runtime.install(prevEvents, prevHooks, prevErrors)
  eq(results and results[1] and results[1].amount, 124, "exp.gain: the hook's answer is the amount paid")
  eq(#seen, 1, "exp.gain: raised once per recipient")
  local ctx = seen[1] and seen[1].ctx or {}
  eq(ctx.level, 8, "exp.gain: ctx.level")
  eq(ctx.isTrainer, false, "exp.gain: ctx.isTrainer")
  eq(ctx.participants, 1, "exp.gain: ctx.participants")
  eq(ctx.expShare, false, "exp.gain: ctx.expShare")
  eq(ctx.mon, fighter, "exp.gain: ctx.mon")
  eq(ctx.index, 1, "exp.gain: ctx.index")
  eq(ctx.battle, "screen", "exp.gain: ctx.battle is the caller's")
  -- ...and nothing is raised with no hook wrapped.
  seen = {}
  local plain = Exp3.award({ species = 16, level = 8, sentIn = { [1] = true },
                             party = { monOf(4, 10) } })
  eq(plain and plain[1] and plain[1].amount, 62, "exp.gain: unhooked, the cart's amount")
  eq(#seen, 0, "exp.gain: ...and no call")
end

-- (d) Held items: written home only where the cart keeps them, and only an
-- item this client uploaded.
do
  -- A fight between players: the cart reloads the party after it.
  newGame()
  local mine = monOf(4, 20, { heldItem = 139, item = 139 })
  SESSION.party = { mine }
  local f, ev = byHand("1v1")
  ev({ t = "held", slot = 0, side = "a", mon = 0, amount = 139, holding = 0, text = "ORAN BERRY" })
  eq(mine.heldItem, 139, "held (1v1): a berry eaten stays in the save")
  ev({ t = "held", slot = 0, side = "a", mon = 0, amount = 260, holding = 260, text = "TICKET" })
  eq(f.mine[1].heldItem, 260, "held (1v1): TRICK's item is on the fight sheet")
  eq(mine.heldItem, 139, "held (1v1): ...and never in the save")
  eq(mine.item, 139, "held (1v1): ...by either field")

  -- A wild fight: the cart keeps what the fight did.
  newGame()
  mine = monOf(4, 20, { heldItem = 139, item = 139 })
  SESSION.party = { mine }
  local wildSheet = assert(Sheet3.mon(SESSION, monOf(16, 5, { heldItem = 197, item = 197 }), 0,
    { wild = true }))
  local warnsBefore = #warns
  f, ev = byHand("wild", { wildParty = { wildSheet } })
  ev({ t = "held", slot = 0, side = "a", mon = 0, amount = 139, holding = 0, text = "ORAN BERRY" })
  eq(mine.heldItem, 0, "held (wild): a berry eaten stays eaten")
  ev({ t = "held", slot = 0, side = "a", mon = 0, amount = 197, holding = 197, text = "LUCKY EGG" })
  eq(mine.heldItem, 197, "held (wild): THIEF keeps the wild mon's item")
  ev({ t = "held", slot = 0, side = "a", mon = 0, amount = 260, holding = 260, text = "TICKET" })
  eq(mine.heldItem, 197, "held (wild): an item no upload held never enters the save")
  eq(#warns, warnsBefore + 1, "held (wild): ...said once, with a remediation")
end

-- (e) KNOCK OFF, then the catch: the caught mon still holds its item.
do
  newGame()
  SESSION.party = { monOf(4, 30) }
  local target = monOf(16, 5, { heldItem = 197, item = 197, personality = 21, otId = 5 })
  local sheet = assert(Sheet3.mon(SESSION, target, 0, { wild = true }))
  local f, ev = byHand("wild", { wildParty = { sheet }, wildCatchMon = target })
  ev({ t = "held", slot = 3, side = "b", mon = 0, amount = 197, holding = 197, text = "LUCKY EGG" })
  f:grantCatch3({ caught = { speciesNum = 16, personality = 21, hp = 5, heldItem = 0 } })
  eq(target.heldItem, 197, "knock off: the caught mon keeps the item KNOCK OFF took from the battler")
  eq(target.item, 197, "knock off: ...by both fields")

  -- THIEF, then the catch: gone.
  newGame()
  SESSION.party = { monOf(4, 30) }
  target = monOf(16, 5, { heldItem = 197, item = 197, personality = 22, otId = 5 })
  sheet = assert(Sheet3.mon(SESSION, target, 0, { wild = true }))
  f, ev = byHand("wild", { wildParty = { sheet }, wildCatchMon = target })
  ev({ t = "held", slot = 3, side = "b", mon = 0, amount = 197, holding = 0, text = "LUCKY EGG" })
  f:grantCatch3({ caught = { speciesNum = 16, personality = 22, hp = 5, heldItem = 0 } })
  eq(target.heldItem, 0, "thief: a stolen item is not in the ball")

  -- A caught sheet claiming an item nothing uploaded: the mon keeps its own.
  newGame()
  SESSION.party = { monOf(4, 30) }
  target = monOf(16, 5, { heldItem = 197, item = 197, personality = 23, otId = 5 })
  sheet = assert(Sheet3.mon(SESSION, target, 0, { wild = true }))
  f = byHand("wild", { wildParty = { sheet }, wildCatchMon = target })
  f:grantCatch3({ caught = { speciesNum = 16, personality = 23, hp = 5, heldItem = 260 } })
  eq(target.heldItem, 197, "catch: an item no upload held never rides in on a caught sheet")
end

-- (f) Deoxys: link stats in a fight between players only.
do
  P3._names[410] = "DEOXYS"
  P3._types[410] = { 13, 13 }
  P3._stats[410] = { hp = 50, atk = 150, def = 50, spe = 150, spa = 150, spd = 50 }
  P3._speciesMeta[410] = { catchRate = 3, expYield = 215, genderRatio = 255, growthRate = 5,
                           friendship = 0, linkStats = { 50, 95, 90, 180, 95, 90 } }
  P3._abilities[410] = { 46, 0 }
  local FakeLB = {}
  function FakeLB.applyLinkStats(mon)
    mon.attack, mon.defense, mon.speed, mon.spAtk, mon.spDef = 77, 66, 199, 88, 55
    return mon
  end
  stub("src.core.game3.link.battle", FakeLB)
  newGame()
  local deoxys = monOf(410, 30, { moves = { 33 }, pp = { 35 }, maxPp = { 35 } })
  local own = assert(Sheet3.mon(SESSION, deoxys, 0))
  eq(own.stats.atk, deoxys.attack, "deoxys: a sheet by default carries this cart's own forme")
  eq(own.beatUp.atk, 150, "deoxys: ...and Beat Up reads the species row")
  local linked = assert(Sheet3.mon(SESSION, deoxys, 0, { link = true }))
  eq(linked.stats.atk, 77, "deoxys: { link = true } takes the link-battle stats")
  eq(linked.stats.spe, 199, "deoxys: ...all five")
  eq(linked.beatUp.atk, 95, "deoxys: ...and Beat Up the link row")
  eq(deoxys.attack ~= 77, true, "deoxys: the party mon keeps its own stats")
  SESSION.party = { deoxys }
  local pvp = harness("1v1", { assert(Sheet3.mon(SESSION, monOf(4, 5), 0)) })
  eq(pvp.pending.party.mons[1].stats.atk, 77, "deoxys: a 1v1 uploads the link stats")
  newGame()
  SESSION.party = { deoxys }
  local wild = harness("wild", { assert(Sheet3.mon(SESSION, monOf(16, 5), 0, { wild = true })) })
  eq(wild.pending.party.mons[1].stats.atk, deoxys.attack, "deoxys: a wild fight uploads its own")
end

-- (g) A mon with no gender field takes the one its species and personality give.
do
  newGame()
  local gender = FakePokemon.gender
  FakePokemon.gender = function(_, pid) return (tonumber(pid) or 0) % 2 == 0 and "F" or "M" end
  local mon = monOf(16, 5, { personality = 4 })
  mon.gender = nil
  eq(assert(Sheet3.mon(SESSION, mon, 0)).gender, "F", "gender: the engine's answer, not U")
  mon.personality = 5
  eq(assert(Sheet3.mon(SESSION, mon, 0)).gender, "M", "gender: ...from the personality")
  mon.gender = "U"
  eq(assert(Sheet3.mon(SESSION, mon, 0)).gender, "U", "gender: a genderless mon stays U")
  FakePokemon.gender = gender
end

-- (h) Names: the cart's é / ♂ / ♀ spelled out for the wire, kept for local text.
do
  newGame()
  local nido = monOf(29, 5)
  eq(assert(Sheet3.mon(SESSION, nido, 0)).species, "NIDORANF",
     "names: NIDORAN♀ goes on the wire as NIDORANF, not NIDORAN")
  eq(assert(Sheet3.mon(SESSION, monOf(4, 5, { nickname = "REN\195\169" }), 0)).species, "RENE",
     "names: an é in a nickname is an E")
  eq(Sheet3.localName(nido), "NIDORAN\226\153\128", "names: the cart's own spelling for local text")
  eq(Sheet3.localName(monOf(4, 5, { nickname = "REN\195\169" })), "REN\195\169",
     "names: ...a nickname as typed")
  FakeBag.add(SESSION.bag, 4, 3)
  local ball
  for _, row in ipairs(Sheet3.bag(GAME)) do if row.id == 4 then ball = row end end
  eq(ball and ball.name, "POKE BALL", "names: the bag uploads POKE BALL, not POK BALL")
  local held = assert(Sheet3.mon(SESSION, monOf(16, 5, { heldItem = 4, item = 4 }), 0))
  eq(held.itemName, "POKE BALL", "names: ...and so does a held item's name")

  -- The catch's own lines use the cart's spelling.
  newGame()
  SESSION.party = { monOf(4, 30) }
  FakeBag.add(SESSION.bag, 1, 1)
  local target = monOf(29, 5, { otId = 5 })
  local c = harness("wild", { assert(Sheet3.mon(SESSION, target, 0, { wild = true })) },
    { wildCatchMon = target, classicUi = true })
  c.pump()
  c.fight.itemPick = { id = 1, effect = Sheet3.itemEffect(1) }
  c.fight:commitItem(nil, nil)
  local g = 0
  while not c.fight.finished and g < 10 do g = g + 1; c.pump() end
  check(allText(c):find("NIDORAN\226\153\128 was\nadded to the party!", 1, true) ~= nil,
        "names: 'NIDORAN♀ was added to the party!'")
  check(contains(c.said, "NICKNAME NIDORAN\226\153\128"), "names: the nickname prompt names it the cart's way")
  -- (the referee's own sentence) "Gotcha! NIDORANF was caught!" -- once.
  local _, gotchas = allText(c):gsub("Gotcha!", "")
  eq(gotchas, 1, "endings: one 'Gotcha!' on Gen 3 -- the referee's, not an echo")
  check(allText(c):find("You won!", 1, true) == nil, "endings: no generic 'You won!' after a catch")
end

-- (h2) A status from a PvP spar never reaches the save; a wild one does.
-- The cart reloads the party after a Cable Club battle (cable_club.c
-- CB2_ReturnFromCableClubBattle -> LoadPlayerParty) -- live e2e caught a
-- THUNDER WAVE from a 1v1 left on the save as PAR.
do
  newGame()
  local lead = monOf(4, 5)
  SESSION.party = { lead }
  local f = byHand("1v1")
  f.active = f.active or 1
  f:syncMineStatus({ t = "status", slot = f:mySlot(), status = "PAR" })
  eq(lead.status, nil, "pvp status: a spar's paralysis stays out of the save")
  eq(f.mine[f.active] and f.mine[f.active].status, "PAR",
     "pvp status: ...while the fight sheet still shows it")
  newGame()
  local wildLead = monOf(4, 5)
  SESSION.party = { wildLead }
  local w = byHand("wild")
  w.active = w.active or 1
  w:syncMineStatus({ t = "status", slot = w:mySlot(), status = "PAR" })
  eq(wildLead.status, "PAR", "wild status: a wild fight's paralysis is kept, as the cart keeps it")
end

-- (i) The party page's pics are per monster on Gen 3.
do
  newGame()
  SESSION.party = { monOf(4, 5, { personality = 1 }), monOf(4, 5, { personality = 2 }) }
  local f = byHand("1v1")
  f.seatFront = function(_, _, mon) return { pid = mon.personality } end
  local one, two = f:partyFront(1, f.mine[1]), f:partyFront(2, f.mine[2])
  eq(one and one.pid, 1, "party pic: the first CHARMANDER's")
  eq(two and two.pid, 2, "party pic: the second is its own, not the first's cached")
  eq(f:partyFront(1, f.mine[1]), one, "party pic: ...and each is cached")
end

-- (j) A missing pic is looked for once, not every frame.
do
  newGame()
  SESSION.party = { monOf(4, 5) }
  local frontPic, calls = FakePokemon.frontPic, 0
  FakePokemon.frontPic = function() calls = calls + 1; return nil end
  local f, ev = byHand("1v1")
  ev({ t = "send", slot = 3, side = "b", text = "MEW", speciesId = "151", hp = 50, maxHp = 50, level = 20 })
  -- (Wave 4b: the page shows an arrival with its send-out row, `spawnHide`.)
  for _ = 1, 20 do f:update(2.0) end
  calls = 0
  local seat
  for _ = 1, 3 do seat = f:gen3SeatModel(3, false) end
  FakePokemon.frontPic = frontPic
  eq(calls, 0, "missing pic: the classic page does not re-read it every frame")
  eq(seat and seat.noPic, true, "missing pic: ...and tells the page not to either")
  eq(seat and seat.sprite, nil, "missing pic: the seat has no sprite, not `false`")
end

-- (k) The classic page's back-pic Quad is built once per sheet.
do
  local ClassicBattle = need("ClassicBattle")
  local Gen3m = need("Gen3")
  local C = Gen3m.engine("src.ui.game3.battle_chrome")
  local TP = Gen3m.engine("src.core.game3.trainer_pic")
  if type(C) == "table" and type(TP) == "table" then
    local saved = { manifest = C.manifest, isRse = C.isRse, drawTerrain = C.drawTerrain,
                    drawPanel = C.drawPanel, drawMenuFrames = C.drawMenuFrames, back = TP.back }
    C.manifest = function() return true end
    C.isRse = function() return false end
    C.drawTerrain = function() return false end
    C.drawPanel = function() end
    C.drawMenuFrames = function() end
    local sheet = fakeImage("backsheet")
    TP.back = function() return { image = sheet } end
    local newQuad, quads = love.graphics.newQuad, 0
    love.graphics.newQuad = function(...) quads = quads + 1; return newQuad(...) end
    for _ = 1, 3 do pcall(ClassicBattle.drawGen3, { playerBack = { gender = 0 }, message = "" }) end
    love.graphics.newQuad = newQuad
    for k, v in pairs(saved) do if k == "back" then TP.back = v else C[k] = v end end
    eq(quads, 1, "classic page: one Quad for the player's back-pic sheet, not one a frame")
  else
    print("[skip] classic page quad: the engine's battle chrome is not loadable here")
  end
end

-- (l) A failed yes / no ends the learn exchange instead of looping it.
do
  newGame()
  local mon = monOf(4, 10, { moves = { 10, 45, 33, 1 }, pp = { 35, 40, 35, 35 },
                             maxPp = { 35, 40, 35, 35 } })
  -- The engine's loop, faithfully: "Delete?" no -> "Stop?" no -> "Delete?"...,
  -- each prompt skipped for "did not learn" once the exchange is headless.
  local begin = FakeLearn.begin
  local asks, looped, done = 0, false, {}
  FakeLearn.begin = function(opts)
    FakeLearn._headless = opts.headless and true or false
    local askDelete, askStop
    local function finish(v) done[#done + 1] = v; opts.onDone(v) end
    function askDelete()
      if FakeLearn._headless then return finish(false) end
      asks = asks + 1
      if asks > 20 then looped = true; return finish(false) end
      opts.askYesNo("Delete a move?", function(yes)
        if yes then return finish(true) end
        askStop()
      end)
    end
    function askStop()
      if FakeLearn._headless then return finish(false) end
      asks = asks + 1
      if asks > 20 then looped = true; return finish(false) end
      opts.askYesNo("Stop learning?", function(stop)
        if stop then return finish(false) end
        askDelete()
      end)
    end
    askDelete()
  end
  local pushScreen = Gen3Ui.pushScreen
  Gen3Ui.pushScreen = function() return nil end
  local ui = {
    say = function(_, _, cb) if cb then cb() end; return {} end,
    confirm = function() error("no box today") end,
  }
  local answered
  check(LearnMove.open(GAME, mon, 98, function(learned) answered = learned end, { ui = ui }),
        "learn: the exchange opened")
  Gen3Ui.pushScreen = pushScreen
  FakeLearn.begin = begin
  eq(looped, false, "learn: a confirm that cannot open does not loop the prompts")
  eq(asks, 1, "learn: ...one failed ask ends it")
  eq(answered, false, "learn: onDone(false) -- the move was not learned")
  eq(#done, 1, "learn: ...once")
end

-- (m) The Gen 3 box pages on a blank line; the openings and endings are the cart's.
do
  newGame()
  local paged = Mediated.new({ game = GAME, battle = "p" })
  paged:say("one\ntwo\n\nthree")
  eq(#paged.lines, 2, "say: a blank line is a page break on Gen 3")
  eq(paged.lines[1], "one\ntwo", "say: ...the first page")
  eq(paged.lines[2], "three", "say: ...and the second, with no blank line left at its top")

  newGame()
  SESSION.party = { monOf(4, 5) }
  local npc = Mediated.new({ game = GAME, battle = "n", role = "host", peerId = "npc",
    peerName = "POK\195\169MON PROF. PROF. OAK", mode = "coop_npc",
    trainer = { className = "POK\195\169MON PROF.", trainerName = "PROF. OAK" } })
  npc:onReady({ battle = "n", mode = "coop_npc", sides = { a = { "me" }, b = { "npc" } } })
  eq(npc.lines[1], "POK\195\169MON PROF. OAK\nwould like to battle!",
     "opening: the trainer's name on its own line, the class said once")
  eq(Mediated.trainerLabel3({ className = "YOUNGSTER", trainerName = "BEN" }), "YOUNGSTER BEN",
     "opening: an ordinary CLASS NAME")
  local peer = Mediated.new({ game = GAME, battle = "q", role = "host", peerId = "p",
    peerName = "BOB" })
  peer:onReady({ battle = "q", sides = { a = { "me" }, b = { "p" } } })
  eq(peer.lines[1], "BOB\nwould like to battle!", "opening: a player, the link wording")

  -- A solo trainer fight ends on the caller's cart lines, not "You won!".
  npc:finish("win", "ko")
  local ended = table.concat(npc.textLog or {}, " | ")
  check(ended:find("You won!", 1, true) == nil, "endings: no generic 'You won!' in an NPC fight")
  -- A fight between players still says how it ended.
  peer:finish("loss", "ko")
  local text = table.concat(peer.textLog or {}, " | ")
  check(text:find("lost", 1, true) ~= nil, "endings: a 1v1 says it was lost")
end

-- (n) Gen 2 regression, pinned in tests/mediated_battle_client.lua ("Gold: a
-- republished status move keeps its Crystal effect id").

-- (o) The pre-send checks read in the boot's generation: a malformed Gen 3
-- field is caught here, not dropped in silence by the hub.
do
  newGame()
  SESSION.party = { monOf(4, 5) }
  local sent = {}
  local transport = { isReady = function() return true end,
                      send = function(_, kind, msg) sent[#sent + 1] = { kind = kind, msg = msg } end }
  local f = Mediated.new({ transport = transport, game = GAME, battle = "o", role = "host",
                           peerId = "p", peerName = "BOB" })
  f.mine = Sheet3.party(GAME)
  local warnsBefore = #warns
  eq(f:sendChoice({ action = "switch", slot = 1, pass = 99 }), false,
     "pre-send: a Gen 3 choice with an out-of-range BATON PASS index is not sent")
  eq(#sent, 0, "pre-send: ...nothing went out")
  eq(#warns, warnsBefore + 1, "pre-send: ...and the log says why")
  check(f:sendChoice({ action = "fight", move = 0, dexCaught = true }),
        "pre-send: a well-formed Gen 3 choice still goes")
  eq(Mediated.sendMoveset(transport, "o", 0, f.mine[1].moves), true,
     "pre-send: a Gen 3 moveset passes its check in the Gen 3 dialect")
end

-- ------------------------------------------------------------------
-- 8. Pay Day's coins and the holders-only exp fact (RF8; sheet doc §1, §7.1)
-- ------------------------------------------------------------------

local Wire = need("Wire")

local function lineAt(h, needle)
  for i, line in ipairs(h.fight.textLog or {}) do
    if line:find(needle, 1, true) then return i end
  end
  return nil
end

-- Frames until the ending has printed and the owed Pay Day line with it: the
-- harness stops at the first frame the queue is empty, and the exp strip may
-- still be filling then.
local function settle(fight)
  for _ = 1, 200 do
    fight:update(2.0)
    if not fight.payDayLine and #fight.lines == 0 and not fight.shown then return true end
  end
  return false
end

-- (a) A wild fight won with PAY DAY: the referee's coins, paid once, x1.
do
  newGame()
  local mine = monOf(4, 20, { moves = { 6 }, pp = { 20 }, maxPp = { 20 } })
  SESSION.party = { mine }
  local foe = assert(Sheet3.mon(SESSION, monOf(16, 3, { hp = 1 }), 0, { wild = true }))
  local h = harness("wild", { foe }, { classicUi = true })
  h.pump()
  eq(h.fight.phase, "choose", "pay day: the grid opens")
  h.fight:pickMove(1)   -- PAY DAY knocks the 1-HP PIDGEY out
  h.pump()
  check(settle(h.fight), "pay day: the ending prints out")
  check(h.fight.finished, "pay day: the knockout ends the fight")
  eq(h.battle:outcome().payDay, 100, "pay day: the referee counted level 20 x 5 coins")
  eq(SESSION.money, 1100, "pay day: the wallet takes them, x1 with no AMULET COIN out")
  eq(h.fight.payDayPaid, 100, "pay day: ...and the screen says what it paid")
  local gained, picked = lineAt(h, "gained"), lineAt(h, "picked up")
  check(picked ~= nil and h.fight.textLog[picked]:find("100", 1, true) ~= nil,
        "pay day: the cart's 'picked up' line names the amount")
  check(gained ~= nil and picked ~= nil and gained < picked,
        "pay day: ...after the knockout's exp, where the cart says it")
  h.fight:payDay3({ payDay = 100 })
  h.fight:onOutcome({ battle = "g3", outcome = "win", winners = { "me" }, losers = { "wild" },
                      reason = "ko", payDay = 100 })
  eq(SESSION.money, 1100, "pay day: a second look at the outcome pays nothing more")
end

-- (b) An AMULET COIN that came out doubles them.
do
  newGame()
  local mine = monOf(4, 20, { moves = { 6 }, pp = { 20 }, maxPp = { 20 },
                              heldItem = 189, item = 189 })
  SESSION.party = { mine }
  local foe = assert(Sheet3.mon(SESSION, monOf(16, 3, { hp = 1 }), 0, { wild = true }))
  local h = harness("wild", { foe }, { classicUi = true })
  h.pump()
  eq(h.fight.amuletMine, true, "amulet coin: its holder walking on is noted")
  h.fight:pickMove(1)
  h.pump()
  settle(h.fight)
  eq(SESSION.money, 1200, "amulet coin: PAY DAY's 100 coins are paid x2")
  check(lineAt(h, "200") ~= nil, "amulet coin: ...and the line says 200")

  -- Held in the bag's sense only (never sent out): no doubling.
  newGame()
  local lead = monOf(4, 20, { moves = { 6 }, pp = { 20 }, maxPp = { 20 } })
  local bench = monOf(4, 20, { personality = 9, heldItem = 189, item = 189 })
  SESSION.party = { lead, bench }
  foe = assert(Sheet3.mon(SESSION, monOf(16, 3, { hp = 1 }), 0, { wild = true }))
  h = harness("wild", { foe }, { classicUi = true })
  h.pump()
  h.fight:pickMove(1)
  h.pump()
  eq(h.fight.amuletMine, nil, "amulet coin: a benched holder that never came out is not")
  eq(SESSION.money, 1100, "amulet coin: ...and PAY DAY pays x1")
end

-- (c) The foe's AMULET COIN: FireRed / LeafGreen double for it too, Emerald
-- does not (its `amuletCoinPlayerOnly`, pret battle_util.c:3294).
do
  for _, case in ipairs({ { version = "firered", money = 1200 }, { version = "emerald", money = 1100 } }) do
    newGame({ version = case.version })
    SESSION.party = { monOf(4, 20, { moves = { 6 }, pp = { 20 }, maxPp = { 20 } }) }
    local foe = assert(Sheet3.mon(SESSION, monOf(16, 3, { hp = 1, heldItem = 189, item = 189 }), 0,
                                  { wild = true }))
    local h = harness("wild", { foe }, { classicUi = true })
    h.pump()
    eq(h.fight.amuletFoe, true, "amulet coin (" .. case.version .. "): the wild holder is noted")
    h.fight:pickMove(1)
    h.pump()
    eq(SESSION.money, case.money, "amulet coin (" .. case.version .. "): the foe's coin "
       .. (case.money == 1200 and "doubles PAY DAY" or "does not count"))
  end
end

-- (d) Who is paid: side a's winner, never a fight between players, never a
-- loser, and never an outcome that carries no coins.
do
  newGame()
  SESSION.party = { monOf(4, 10) }
  local f = byHand("1v1")
  f:onOutcome({ battle = "rf", outcome = "win", winners = { "me" }, losers = { "p" },
                reason = "ko", payDay = 300 })
  eq(f.result, "win", "pvp: the verdict lands")
  eq(SESSION.money, 1000, "pvp: an outcome that (wrongly) carries coins pays nothing (link rules)")
  eq(f.payDayLine, nil, "pvp: ...and owes no line")

  newGame()
  SESSION.party = { monOf(4, 10) }
  f = byHand("wild")
  f.peerId = "w"
  f:onOutcome({ battle = "rf", outcome = "win", winners = { "w" }, losers = { "me" },
                reason = "ko", payDay = 300 })
  eq(f.result, "loss", "loser: the verdict lands")
  eq(SESSION.money, 1000, "loser: the side that lost is paid nothing")

  newGame()
  SESSION.party = { monOf(4, 10) }
  f = byHand("wild")
  f.peerId = "w"
  f:onOutcome({ battle = "rf", outcome = "win", winners = { "me" }, losers = { "w" }, reason = "ko" })
  eq(SESSION.money, 1000, "no coins: an ordinary win pays nothing")
  eq(f.payDayLine, nil, "no coins: ...and says nothing")

  -- What the wire hands over: every reader keeps the coins (Red and Gold pay
  -- Pay Day too since K11, docs/plans/gen12-referee-gaps-fix.md), and a
  -- mangled count is dropped without the outcome.
  local raw = { battle = "rf", outcome = "win", winners = { "me" }, losers = { "w" },
                reason = "ko", payDay = 300 }
  eq(Wire.battleOutcome(raw, 3).payDay, 300, "wire: a Gen 3 outcome keeps payDay")
  eq(Wire.battleOutcome(raw).payDay, 300, "wire: ...as does a reader that names no generation")
  eq(Wire.battleOutcome(raw, 1).payDay, 300, "wire: a Gen 1 reader keeps it too (K11)")
  eq(Wire.battleOutcome(raw, 2).payDay, 300, "wire: and a Gen 2 reader (K11)")
  raw.payDay = 70000
  local clean = Wire.battleOutcome(raw, 3)
  check(clean ~= nil and clean.payDay == nil, "wire: past the cart's u16 the count is dropped, the outcome kept")
end

-- (e) A trainer win (the solo path's shape): the caller's after-words -- the
-- defeated line and the prize -- print before the coins, as the cart orders
-- BattleScript_LocalTrainerBattleWon ahead of BattleScript_PayDayMoneyAndPickUpItems.
do
  newGame()
  SESSION.party = { monOf(4, 10) }
  local f = byHand("coop_npc")
  f:onOutcome({ battle = "rf", outcome = "win", winners = { "me" }, losers = { "p" },
                reason = "ko", payDay = 250 })
  eq(SESSION.money, 1250, "trainer: the coins land with the verdict")
  f:say("ANN defeated\nYOUNGSTER BEN!")
  f:say("ANN got ¥80\nfor winning!")
  settle(f)
  local defeated, prize, picked
  for i, line in ipairs(f.textLog or {}) do
    if line:find("defeated", 1, true) then defeated = i end
    if line:find("for winning", 1, true) then prize = i end
    if line:find("picked up", 1, true) then picked = i end
  end
  check(defeated and prize and picked and defeated < picked and prize < picked,
        "trainer: the 'picked up' line follows the defeated line and the prize")
  check(picked and f.textLog[picked]:find("250", 1, true) ~= nil, "trainer: ...naming the coins")
end

-- (f) The holders-only fact: `participants` 0 and no `mon` banks the knockout
-- with nobody sent in, so only the living Exp. Share holders are paid --
-- never the active mon a `mon`-less event otherwise falls back to.
do
  newGame()
  local fighter = monOf(4, 10)
  local holder = monOf(16, 10, { heldItem = 182, item = 182 })
  local bystander = monOf(4, 10, { personality = 9 })
  SESSION.party = { fighter, holder, bystander }
  local f, ev = byHand("wild")
  local fx, hx, bx = fighter.exp, holder.exp, bystander.exp
  local sanitised = Wire.battleEvent({ battle = "rf", seq = 99, t = "exp", slot = 0,
    speciesId = "16", level = 8, participants = 0 }, 3)
  eq(sanitised.participants, 0, "holders-only: Wire's Gen 3 reading keeps the zero")
  check(Mediated.holdersOnly(sanitised), "holders-only: ...and the screen reads it as the fact")
  eq(Wire.battleEvent({ battle = "rf", seq = 99, t = "exp", slot = 0, participants = 0 }, 1)
       .participants, nil, "holders-only: a Gen 1 reading never keeps a zero")
  ev({ t = "team", slot = 0, side = "a", team = "ooo" })
  ev({ t = "faint", slot = 3, side = "b", text = "PIDGEY" })
  ev({ t = "exp", slot = 0, side = "a", speciesId = "16", level = 8, participants = 0 })
  ev({ t = "msg", text = "next" })
  -- PIDGEY 8: calculated floor(55 * 8 / 7) = 62, the holders' half 31, one holder.
  eq(gained(holder, hx), 31, "holders-only: the Exp. Share holder takes the share half")
  eq(gained(fighter, fx), 0, "holders-only: the active mon is not paid as a fighter")
  eq(gained(bystander, bx), 0, "holders-only: nor is anyone else")
  eq(f.expPaid, 1, "holders-only: one payment")

  -- Two knockouts' holders-only facts of one species and level (an Explosion
  -- that takes two trainer mons with it) are two knockouts, not one.
  newGame()
  holder = monOf(16, 10, { heldItem = 182, item = 182 })
  SESSION.party = { monOf(4, 10, { hp = 0 }), holder }
  f, ev = byHand("coop_npc")
  hx = holder.exp
  ev({ t = "team", slot = 0, side = "a", team = "xo" })
  ev({ t = "faint", slot = 3, side = "b", text = "PIDGEY" })
  ev({ t = "faint", slot = 4, side = "b", text = "PIDGEY" })
  ev({ t = "exp", slot = 0, side = "a", speciesId = "16", level = 8, participants = 0 })
  ev({ t = "exp", slot = 0, side = "a", speciesId = "16", level = 8, participants = 0 })
  ev({ t = "msg", text = "next" })
  -- A trainer's mon: floor(31 * 1.5) = 46, twice.
  eq(gained(holder, hx), 92, "holders-only: each knockout pays the holder its own share")

  -- No holder standing: the fact pays nobody, and says nothing.
  newGame()
  fighter = monOf(4, 10)
  SESSION.party = { fighter, monOf(4, 10, { personality = 9 }) }
  f, ev = byHand("wild")
  fx = fighter.exp
  ev({ t = "team", slot = 0, side = "a", team = "oo" })
  ev({ t = "faint", slot = 3, side = "b", text = "PIDGEY" })
  ev({ t = "exp", slot = 0, side = "a", speciesId = "16", level = 8, participants = 0 })
  ev({ t = "msg", text = "next" })
  eq(gained(fighter, fx), 0, "holders-only: with no Exp. Share out, nobody is paid")
  eq(f.expPaid, nil, "holders-only: ...and no gained line")
end

-- ------------------------------------------------------------------
-- 9. a mon that would not obey (contract K3, docs/plans/gen3-badge-rules.md)
-- ------------------------------------------------------------------
--
-- The referee says each outcome twice over: an `obey` event naming it, and its
-- own English sentence straight behind (BattleSim3 Move.lua Bm:_obeyLine).  The
-- screen says it once, in the cart's line out of the player's text pack.  The
-- text pack here is a stand-in for the engine's (Gen3.battleText): the cart's
-- line shapes, in capitals so a line it printed can be told from the referee's,
-- and only for a mon named the way the engine's battle_text.lua needs one on
-- the player's side (`atk`, side "player").
do
  local Gen3 = need("Gen3")
  local Wire = need("Wire")
  local CART = {
    STRINGID_PKMNIGNORESASLEEP = "%s IGNORED\nORDERS WHILE ASLEEP!",
    STRINGID_PKMNIGNOREDORDERS = "%s IGNORED\nORDERS!",
    STRINGID_PKMNBEGANTONAP = "%s BEGAN TO NAP!",
    STRINGID_PKMNLOAFING = "%s IS\nLOAFING AROUND!",
    STRINGID_PKMNWONTOBEY = "%s WON'T\nOBEY!",
    STRINGID_PKMNTURNEDAWAY = "%s TURNED AWAY!",
    STRINGID_PKMNPRETENDNOTNOTICE = "%s PRETENDED\nNOT TO NOTICE!",
  }
  local realText = Gen3.battleText
  local asked, packOff = {}, false
  Gen3.battleText = function(id, fill)
    local shape = CART[id]
    if not shape then return realText(id, fill) end
    asked[#asked + 1] = { id = id, fill = fill }
    if packOff then return nil end
    local atk = type(fill) == "table" and fill.atk or nil
    if not (type(atk) == "table" and atk.side == "player" and type(atk.name) == "string") then return nil end
    return shape:format(atk.name)
  end
  local function flat(s) return (tostring(s):gsub("\n", " ")) end
  -- How many lines the screen said since `from` read `line`, newlines aside.
  local function saidCount(f, line, from)
    local n = 0
    for i = (from or 0) + 1, #(f.textLog or {}) do
      if flat(f.textLog[i]) == flat(line) then n = n + 1 end
    end
    return n
  end
  local function saidAt(f, line, from)
    for i = (from or 0) + 1, #(f.textLog or {}) do
      if flat(f.textLog[i]) == flat(line) then return i end
    end
    return nil
  end
  -- The first line since `from` that carries `needle`.
  local function saidLike(f, needle, from)
    for i = (from or 0) + 1, #(f.textLog or {}) do
      if f.textLog[i]:find(needle, 1, true) then return i end
    end
    return nil
  end
  local function cartLine(token, name) return CART[Mediated.OBEY_STRINGS3[token]]:format(name) end

  local ok, err = pcall(function()
    -- The table the screens phrase from names exactly the tokens the sanitiser keeps.
    local tokens, keyed = {}, {}
    for token in pairs(Wire.OBEY_TOKENS3) do tokens[#tokens + 1] = token end
    for token in pairs(Mediated.OBEY_STRINGS3) do keyed[#keyed + 1] = token end
    table.sort(tokens)
    table.sort(keyed)
    eq(table.concat(keyed, ","), table.concat(tokens, ","), "obey: a cart line for each of Wire's eight tokens")
    eq(Mediated.OBEY_STRINGS3.hits_itself, "STRINGID_PKMNWONTOBEY",
       "obey: the self-hit opens with the cart's won't-obey line (BattleScript_IgnoresAndHitsItself)")

    -- The sanitiser: a token survives, anything else is dropped from the event,
    -- and an older reader never sees the kind at all.
    local good = Wire.battleEvent({ battle = "b", seq = 1, t = "obey", slot = 0, side = "a", text = "loafing" })
    eq(good and good.text, "loafing", "obey: Wire keeps an outcome token")
    local bad = Wire.battleEvent({ battle = "b", seq = 2, t = "obey", slot = 0, side = "a", text = "LOAFING!" })
    check(bad ~= nil and bad.text == nil, "obey: ...drops anything else, and keeps the event (and its seq)")
    eq(Wire.battleEvent({ battle = "b", seq = 3, t = "obey", slot = 0, side = "a", text = "loafing" }, 2), nil,
       "obey: a Gen 2 reader refuses the kind")

    -- Every outcome by hand, in the referee's own order (each stream is what
    -- BattleSim3 emits for that branch): the cart's line once, the referee's
    -- sentence never, and whatever follows still plays.
    local STREAMS = {
      loafing = { { t = "msg", text = "CHARMANDER is loafing around!" } },
      wont_obey = { { t = "msg", text = "CHARMANDER won't obey!" } },
      turned_away = { { t = "msg", text = "CHARMANDER turned away!" } },
      pretend_not_notice = { { t = "msg", text = "CHARMANDER pretended not to notice!" } },
      ignores_asleep = { { t = "msg", text = "CHARMANDER ignored orders while asleep!" } },
      uses_random_move = {
        { t = "msg", text = "CHARMANDER ignored orders!" },
        { t = "msg", text = "CHARMANDER used TACKLE!" },
        { t = "anim", slot = 0, side = "a", text = "TACKLE", target = 3 },
        { t = "damage", slot = 3, side = "b", hp = 20 },
      },
      falls_asleep = {
        { t = "msg", text = "CHARMANDER began to nap!" },
        { t = "status", slot = 0, side = "a", status = "SLP", text = "CHARMANDER fell asleep!" },
        { t = "msg", text = "CHARMANDER fell asleep!" },
      },
      hits_itself = {
        { t = "msg", text = "CHARMANDER won't obey!" },
        { t = "msg", text = "It hurt itself in its confusion!" },
        { t = "damage", slot = 0, side = "a", hp = 25 },
      },
    }
    local order = {}
    for token in pairs(STREAMS) do order[#order + 1] = token end
    table.sort(order)
    for _, token in ipairs(order) do
      newGame()
      SESSION.party = { monOf(4, 50) }
      local f, ev = byHand("wild")
      ev({ t = "send", slot = 3, side = "b", text = "PIDGEY", speciesId = "16", hp = 50, maxHp = 50, level = 9 })
      ev({ t = "send", slot = 0, side = "a", text = "CHARMANDER", speciesId = "4", hp = 60, maxHp = 60,
           level = 50, mon = 0 })
      for _ = 1, 40 do f:update(2.0) end
      local mark = #(f.textLog or {})
      local was = #asked
      ev({ t = "obey", slot = 0, side = "a", text = token })
      local anims = 0
      for _, e in ipairs(STREAMS[token]) do ev(e) end
      for _, row in ipairs(f.lines) do if type(row) == "table" and row.anim then anims = anims + 1 end end
      for _ = 1, 60 do f:update(2.0) end
      local line = cartLine(token, "CHARMANDER")
      eq(saidCount(f, line, mark), 1, "obey " .. token .. ": the cart's line, once")
      eq(saidCount(f, STREAMS[token][1].text, mark), 0, "obey " .. token .. ": the referee's own sentence is not said")
      eq(asked[was + 1] and asked[was + 1].id, Mediated.OBEY_STRINGS3[token],
         "obey " .. token .. ": looked up by the cart's STRINGID")
      local fill = asked[was + 1] and asked[was + 1].fill
      check(fill and fill.atk and fill.atk.side == "player" and fill.atk.name == "CHARMANDER",
            "obey " .. token .. ": the mon named on the player's side, the engine's `atk`")
      local at = saidAt(f, line, mark)
      if token == "uses_random_move" then
        local used = saidAt(f, "CHARMANDER used TACKLE!", mark)
        check(at and used and used > at, "obey uses_random_move: the called move's line follows")
        eq(anims, 1, "obey uses_random_move: ...its animation is queued")
        eq(f.slots[3].hp, 20, "obey uses_random_move: ...and its damage lands")
      elseif token == "falls_asleep" then
        local slept = saidAt(f, "CHARMANDER fell asleep!", mark)
        check(at and slept and slept > at, "obey falls_asleep: the cart's second line (the sleep) follows")
        eq(f.slots[0].status, "SLP", "obey falls_asleep: ...and the seat is asleep")
      elseif token == "hits_itself" then
        local hurt = saidAt(f, "It hurt itself in its confusion!", mark)
        check(at and hurt and hurt > at, "obey hits_itself: the cart's second line (the self-hit) follows")
        eq(f.slots[0].hp, 25, "obey hits_itself: ...and the self-hit's damage lands")
        eq(f.slots[0].shownHp, 25, "obey hits_itself: ...the bar fell to it")
      end
    end

    -- The fallbacks: each says the referee's sentence instead, still once.
    local function fresh()
      newGame()
      SESSION.party = { monOf(4, 50) }
      local f, ev = byHand("wild")
      ev({ t = "send", slot = 3, side = "b", text = "PIDGEY", speciesId = "16", hp = 50, maxHp = 50, level = 9 })
      ev({ t = "send", slot = 0, side = "a", text = "CHARMANDER", speciesId = "4", hp = 60, maxHp = 60,
           level = 50, mon = 0 })
      return f, ev, #(f.textLog or {})
    end
    local f, ev, mark = fresh()
    packOff = true
    ev({ t = "obey", slot = 0, side = "a", text = "loafing" })
    ev({ t = "msg", text = "CHARMANDER is loafing around!" })
    packOff = false
    eq(saidCount(f, "CHARMANDER is loafing around!", mark), 1, "obey: no text pack -- the referee's sentence, once")
    eq(saidCount(f, cartLine("loafing", "CHARMANDER"), mark), 0, "obey: ...and no line of the cart's")

    f, ev, mark = fresh()
    ev({ t = "obey", slot = 0, side = "a" })
    ev({ t = "msg", text = "CHARMANDER turned away!" })
    eq(saidCount(f, "CHARMANDER turned away!", mark), 1,
       "obey: a token the sanitiser dropped -- the referee's sentence")

    f, ev, mark = fresh()
    ev({ t = "obey", slot = 3, side = "b", text = "wont_obey" })
    ev({ t = "msg", text = "PIDGEY won't obey!" })
    eq(saidCount(f, "PIDGEY won't obey!", mark), 1,
       "obey: the foe's side (the cart never asks it) -- the referee's sentence")
    eq(saidCount(f, cartLine("wont_obey", "PIDGEY"), mark), 0, "obey: ...never phrased as ours")

    -- A lossy stream: the sentence behind the `obey` went missing, and the
    -- line after it is still said.
    f, ev, mark = fresh()
    local seq0 = f.seq
    f:onEvent({ battle = "rf", seq = seq0 + 1, t = "obey", slot = 0, side = "a", text = "hits_itself" })
    f:onEvent({ battle = "rf", seq = seq0 + 3, t = "msg", text = "It hurt itself in its confusion!" })
    eq(saidCount(f, cartLine("hits_itself", "CHARMANDER"), mark), 1, "obey gap: the cart's line")
    eq(saidCount(f, "It hurt itself in its confusion!", mark), 1, "obey gap: ...and the line after the lost one")

    -- The real referee: a traded L50 CHARMANDER with no badges (cap 10) in a
    -- wild fight, over enough seeds to see every branch a plain fight reaches
    -- (all but the asleep-and-SNORE one).  Each `obey` the referee sends is
    -- read once, in the cart's line, and the turn plays on.
    local seen, seeds = {}, {}
    for seed = 1, 120 do
      newGame()
      local mine = monOf(4, 50, { otId = 999, moves = { 10, 33 }, pp = { 35, 35 }, maxPp = { 35, 35 } })
      SESSION.party = { mine }
      local foe = assert(Sheet3.mon(SESSION, monOf(16, 50, { moves = { 45 }, pp = { 40 }, maxPp = { 40 } }),
        0, { wild = true }))
      local h = harness("wild", { foe }, { seed = seed, classicUi = true })
      if seed == 1 then
        eq(h.pending.party.mons[1].traded, true, "obey referee: the sheet says the mon is traded (K2)")
        eq(h.pending.party.badges, nil, "obey referee: ...and the trainer has no badges")
      end
      local events = {}
      h.fight.onEvent = function(self, e)
        events[#events + 1] = e
        return Mediated.onEvent(self, e)
      end
      h.pump()
      local mark1 = #(h.fight.textLog or {})
      h.fight:pickMove(1)
      h.pump()
      for i, e in ipairs(events) do
        if e.t == "obey" and not seen[e.text] then
          seen[e.text] = true
          seeds[#seeds + 1] = e.text .. "@" .. seed
          local nextEv = events[i + 1]
          eq(nextEv and nextEv.t, "msg", "obey referee " .. e.text .. ": the referee's sentence follows the event")
          eq(saidCount(h.fight, cartLine(e.text, "CHARMANDER"), mark1), 1,
             "obey referee " .. e.text .. ": the cart's line, once")
          eq(saidCount(h.fight, nextEv and nextEv.text, mark1), 0,
             "obey referee " .. e.text .. ": the referee's sentence is not said")
          check(h.fight.phase == "choose" or h.fight.finished,
                "obey referee " .. e.text .. ": the turn played on to the next menu")
          if e.text == "hits_itself" then
            check(saidAt(h.fight, "It hurt itself in its confusion!", mark1) ~= nil,
                  "obey referee hits_itself: the self-hit line plays")
            check(h.fight.slots[0].hp < mine.maxHp, "obey referee hits_itself: ...and so does its damage")
          elseif e.text == "falls_asleep" then
            eq(h.fight.slots[0].status, "SLP", "obey referee falls_asleep: the nap's sleep lands")
          elseif e.text == "uses_random_move" then
            local at = saidAt(h.fight, cartLine(e.text, "CHARMANDER"), mark1)
            local used = saidLike(h.fight, "CHARMANDER used", mark1)
            check(at and used and used > at, "obey referee uses_random_move: the called move is used after it")
          end
        end
      end
      local count = 0
      for _ in pairs(seen) do count = count + 1 end
      if count >= 7 then break end
    end
    for _, token in ipairs({ "uses_random_move", "falls_asleep", "hits_itself", "loafing", "wont_obey",
                             "turned_away", "pretend_not_notice" }) do
      check(seen[token], "obey referee: the fight reached " .. token .. " (" .. table.concat(seeds, " ") .. ")")
    end
  end)
  Gen3.battleText = realText
  if not ok then check(false, "obey: the block raised -- " .. tostring(err)) end
end

-- ------------------------------------------------------------------
-- 10. the solo kinds' screen (docs/plans/gen3-solo-remaining-fights.md,
--     wave 1 UM): a fight with no own battler, the facility prompts, Oak's
--     voice-over, the Pokémon Tower GHOST, the fight's own theme and the
--     command-set seam -- every screen option `applyScreenOptions` reads
-- ------------------------------------------------------------------
--
-- The streams are fed by hand (the referee's no-battler side, its facility
-- rules, its `lesson` events and its ghost arms are wave 1 RF / wave 2 R2's),
-- in the shapes contract C3 / C6 fix.  The cart's text is a stand-in for the
-- engine's (Gen3.battleText, the oak_advice table, gText_Ghost): capitals, so
-- a line the screen read off the "cart" can be told from a fallback.
do
  local Gen3 = need("Gen3")
  local ClassicBattle = need("ClassicBattle")
  local Battlefield = need("Battlefield")
  ITEMS[75] = { name = "X ATTACK", pocket = "ITEMS", price = 500 }

  local CART = {
    STRINGID_ITEMSCANTBEUSEDNOW = "ITEMS CAN'T BE USED NOW.",
    STRINGID_QUESTIONFORFEITMATCH = "WOULD YOU LIKE TO FORFEIT THE MATCH\nAND QUIT NOW?",
    STRINGID_ITDODGEDBALL = "IT DODGED THE THROWN BALL!\nTHIS POKéMON CAN'T BE CAUGHT!",
    STRINGID_SILPHSCOPEUNVEILED = "SILPH SCOPE UNVEILED THE GHOST'S\nIDENTITY!",
    STRINGID_GHOSTWASMAROWAK = "THE GHOST WAS MAROWAK!",
  }
  local realText = Gen3.battleText
  local packOff = false
  local introFill = nil
  Gen3.battleText = function(id, fill)
    if packOff then return nil end
    if id == "STRINGID_INTROMSG" and type(fill) == "table" and fill.ghost then
      introFill = fill
      return fill.ghostUnveiled and "THE GHOST APPEARED!" or "THE GHOST APPEARED!\n\nDARN!\nTHE GHOST CAN'T BE ID'D!"
    end
    if CART[id] then return CART[id] end
    return realText(id, fill)
  end

  -- The engine's oak_advice table, stood in (Oak.pages / Oak.screens): one
  -- page a lesson, the intro two -- with a printer page break -- and the
  -- player's name where the cart's text puts it.
  local OAK_TEXT = {
    forPetesSake = { "OAK: OH, FOR PETE'S SAKE...\\pSO PUSHY, {NAME}!", "OAK: THE TRAINER THAT...",
                     "OAK: TRY BATTLING!" },
    inflictingDamage = { "OAK: INFLICTING DAMAGE IS THE KEY." },
    loweringStats = { "OAK: LOWERING THE FOE'S STATS..." },
    keepAnEyeOnHp = { "OAK: KEEP YOUR EYES ON YOUR HP." },
    partyMenu = { "OAK: THIS IS YOUR PARTY." },
    noRunning = { "OAK: NO! THERE'S NO RUNNING AWAY!" },
    winEarnsPrize = { "OAK: HM! EXCELLENT!" },
    howDisappointing = { "OAK: HM... HOW DISAPPOINTING..." },
  }
  local oakOff = false
  local FakeOak = {}
  function FakeOak.pages(st, key)
    if oakOff then return nil end
    local keys = OAK_TEXT[key]
    if not keys then return nil end
    local out = {}
    for i, page in ipairs(keys) do out[i] = page:gsub("{NAME}", tostring(st and st.playerName)) end
    return out
  end
  function FakeOak.screens(pages)
    local out = {}
    for _, page in ipairs(pages or {}) do
      for part in (tostring(page) .. "\\p"):gmatch("(.-)\\p") do
        if part ~= "" then out[#out + 1] = part end
      end
    end
    return out
  end
  stub("src.core.game3.battle.oak_advice", FakeOak)
  -- The ghost silhouette, the engine's own reader stood in.
  local ghostImage = fakeImage("ghost")
  local ghostAsked = 0
  FakePokemon.ghostPic = function()
    ghostAsked = ghostAsked + 1
    return { image = ghostImage, w = 64, h = 64 }
  end

  -- A screen over a recording transport: every choice it files, and the
  -- party / ruleset uploads, as `start` sends them.
  local function screen3(mode, screenOpts, extra)
    extra = extra or {}
    local sent, uploads = {}, {}
    local transport = {
      isReady = function() return true end,
      send = function(_, kind, msg)
        if type(msg) == "table" and msg.action then
          sent[#sent + 1] = msg
          if extra.refuse then return false end
        elseif type(msg) == "table" then
          uploads[#uploads + 1] = msg
        end
        return true
      end,
    }
    local o = {
      transport = transport, game = GAME, battle = "um", role = "host",
      peerId = (mode ~= "wild") and "p" or nil, peerName = extra.peerName or "BOB",
      mode = mode, wildParty = extra.wildParty, wildCatchMon = extra.wildCatchMon,
      trainer = extra.trainer, classicUi = extra.classicUi ~= false,
    }
    for k, v in pairs(screenOpts or {}) do o[k] = v end
    local f = Mediated.new(o)
    f:start(GAME)
    local function ev(e)
      e.battle, e.seq = "um", (f.seq or 0) + 1
      f:onEvent(e)
    end
    -- Reads the queue out, then gives the screen the one frame more it takes
    -- to open whatever menu is owed behind it.
    local function drain()
      for _ = 1, 80 do
        f:update(2.0)
        if #f.lines == 0 and f.shown == nil and not f.anim then
          f:update(2.0)
          if #f.lines == 0 and f.shown == nil and not f.anim then break end
        end
      end
    end
    f:onReady({ battle = "um", mode = mode,
                sides = { a = { "me" }, b = { (mode == "wild") and "wild" or "p" } } })
    return f, ev, sent, drain, uploads
  end

  local function press(f, key)
    local saved = GAME.input
    GAME.input = { pressed = {}, wasPressed = function(_, k) return k == key end,
                   isDown = function() return false end }
    f:update(0)
    GAME.input = saved
  end

  local function said(f, needle, from)
    for i = (from or 0) + 1, #(f.textLog or {}) do
      if tostring(f.textLog[i]):gsub("\n", " "):find(needle, 1, true) then return i end
    end
    return nil
  end
  local function saidCount(f, needle, from)
    local n = 0
    for i = (from or 0) + 1, #(f.textLog or {}) do
      if tostring(f.textLog[i]):gsub("\n", " "):find(needle, 1, true) then n = n + 1 end
    end
    return n
  end

  -- A recording love.graphics, and the cart chrome / font the classic page
  -- reads stood in, so a draw can be asked what it put where.
  local drawnCalls = {}
  local graphics = setmetatable({}, { __index = function(_, key)
    return function(...) drawnCalls[#drawnCalls + 1] = { key, ... } end
  end })
  graphics.newQuad = function(x, y, w, h)
    return { getViewport = function() return x, y, w, h end }
  end
  graphics.getColor = function() return 1, 1, 1, 1 end
  graphics.getScissor = function() return nil end
  graphics.getFont = function() return nil end
  local chromeCalls = {}
  local function rec(name) return function(...) chromeCalls[#chromeCalls + 1] = { name, ... }; return true end end
  local FakeChrome = {
    manifest = rec("manifest"), isRse = function() return false end,
    drawTerrain = rec("drawTerrain"), drawEnemyBox = rec("drawEnemyBox"),
    drawPlayerBox = rec("drawPlayerBox"), drawHpBar = rec("drawHpBar"),
    drawPanel = rec("drawPanel"), drawMenuFrames = rec("drawMenuFrames"),
    drawPartyBall = rec("drawPartyBall"), drawExpBar = rec("drawExpBar"),
  }
  local textDrawn = {}
  local FakeFont = {
    COLOR = { NORMAL = "normal", WHITE = "white" }, LINE_PITCH = 15,
    draw = function(text, x, y, opts)
      textDrawn[#textDrawn + 1] = { text = text, x = x, y = y, colors = opts and opts.colors }
      return #tostring(text) * 6
    end,
    measure = function(text) return #tostring(text) * 6 end,
    wrap = function(text) return text end,
    drawGlyph = function() return 6 end,
  }
  local backPics = 0
  local function classicDraw(model)
    drawnCalls, chromeCalls, textDrawn, backPics = {}, {}, {}, 0
    local savedLove, savedEngine, savedBack = _G.love, Gen3.engine, Gen3.trainerBackPic
    _G.love = { graphics = graphics, timer = { getTime = function() return 0 end } }
    Gen3.engine = function(name)
      if name == "src.ui.game3.battle_chrome" then return FakeChrome end
      if name == "src.ui.game3.frlg_font" then return FakeFont end
      return savedEngine(name)
    end
    Gen3.trainerBackPic = function()
      backPics = backPics + 1
      return { image = fakeImage("playerback") }
    end
    -- The terrain is named, so the page does not go asking the map for one.
    model.terrain = model.terrain or "building"
    local ok, drew = pcall(ClassicBattle.drawGen3, model, {})
    _G.love, Gen3.engine, Gen3.trainerBackPic = savedLove, savedEngine, savedBack
    return ok and drew
  end
  local function chromeCount(name)
    local n = 0
    for _, call in ipairs(chromeCalls) do if call[1] == name then n = n + 1 end end
    return n
  end
  local function textAt(needle)
    for _, t in ipairs(textDrawn) do
      if tostring(t.text):find(needle, 1, true) then return t end
    end
    return nil
  end
  local function textIs(exact)
    for _, t in ipairs(textDrawn) do
      if tostring(t.text) == exact then return t end
    end
    return nil
  end
  local function withLove(fn, ...)
    local savedLove = _G.love
    drawnCalls = {}
    _G.love = { graphics = graphics, timer = { getTime = function() return 0 end } }
    local result = { pcall(fn, ...) }
    _G.love = savedLove
    return (table.unpack or unpack)(result)
  end
  local function dimDrawn(w, h)
    local dark = false
    for _, call in ipairs(drawnCalls) do
      if call[1] == "setColor" then
        dark = call[2] == 0 and call[3] == 0 and call[4] == 0 and call[5] == 0.5
      elseif call[1] == "rectangle" and dark and call[2] == "fill"
             and call[3] == 0 and call[4] == 0 and call[5] == w and call[6] == h then
        return true
      end
    end
    return false
  end

  local ok, err = pcall(function()
    -- ---- (a) a fight with no own battler, start to end, on both pages
    for _, classic in ipairs({ true, false }) do
      local tag = classic and "no battler (classic): " or "no battler (arena): "
      newGame()
      SESSION.party = { monOf(4, 20) }
      FakeBag.add(SESSION.bag, 4, 3)
      FakeBag.add(SESSION.bag, 75, 1)
      local wild = assert(Sheet3.mon(SESSION, monOf(16, 5), 0, { wild = true }))
      local f, ev, sent, drain, uploads = screen3("wild", { noOwnBattler = true },
        { wildParty = { wild }, classicUi = classic })
      eq(f.noOwnBattler, true, tag .. "the screen option is read")
      eq(f:usesBattlefield(), not classic, tag .. "the page under test is the one asked for")
      check(#uploads > 0, tag .. "the party and ruleset still go up (the kind decides what is seated)")
      ev({ t = "send", slot = 3, side = "b", text = "PIDGEY", speciesId = "16", hp = 20, maxHp = 20,
           level = 5 })
      ev({ t = "team", slot = 3, team = "o" })
      ev({ t = "turn" })
      drain()
      eq(f.phase, "choose", tag .. "the command menu opens every turn with nothing of ours out")
      eq(f.slots[0], nil, tag .. "no own seat exists")
      eq(said(f, "Go!"), nil, tag .. "no send-out of ours")
      check(said(f, "Wild PIDGEY") ~= nil, tag .. "the wild opening as ever")
      eq(said(f, "sent out"), nil, tag .. "...and no send-out line for a wild seat")
      local model = f:gen3ClassicModel()
      eq(model.ally, nil, tag .. "no own plate on the classic page")
      check(type(model.playerBack) == "table", tag .. "the trainer back pic stays up")
      eq(model.prompt, "What will\nANN do?", tag .. "the prompt names the player (gText_WhatWillPkmnDo2)")
      eq(model.foe and model.foe.name, "PIDGEY", tag .. "the foe's plate")
      local ctx = f:battlefieldCtx()
      eq(#ctx.allySeats, 0, tag .. "the arena has no ally seat")
      eq(ctx.allyHumans[1].party, nil, tag .. "...and the trainer figure carries no roster chip")
      eq(ctx.showTarget, false, tag .. "FIGHT highlighted shows no target card")
      eq(#f:bandCommandItems(), 4, tag .. "the cart's grid is still offered")
      check(classicDraw(f:gen3ClassicModel()) == true, tag .. "the classic page draws")
      eq(chromeCount("drawPlayerBox"), 0, tag .. "...with no own healthbox")
      check(backPics > 0, tag .. "...and the trainer's back pic")
      eq(chromeCount("drawEnemyBox"), 1, tag .. "...and the foe's box")
      -- FIGHT and POKéMON have nothing behind them.
      f:runCommand("FIGHT")
      eq(f.phase, "choose", tag .. "FIGHT opens no move list")
      f:runCommand("SWITCH")
      eq(f.phase, "choose", tag .. "POKéMON opens no picker")
      eq(#sent, 0, tag .. "...and neither files anything")
      -- The bag: an X item has no battler to raise.
      f:runCommand("ITEM")
      eq(f.phase, "item", tag .. "BAG opens")
      local rows = f:usableItems()
      local xAt
      for i, row in ipairs(rows) do if row.id == 75 then xAt = i end end
      check(xAt ~= nil, tag .. "the X ATTACK is in the bag")
      f.itemIndex = xAt
      press(f, "a")
      eq(#sent, 0, tag .. "an X item is not used with no battler out")
      check(said(f, "won't have any") ~= nil, tag .. "...the cart's no-effect line")
      eq(f.phase, "item", tag .. "...and the bag stays up")
      drain()
      press(f, "b")
      eq(f.phase, "choose", tag .. "B is back to the grid")
      -- A ball, thrown with nobody of ours out.
      f.itemPick = { id = 4, effect = Sheet3.itemEffect(4) }
      check(f:commitItem(nil, nil), tag .. "a ball goes out")
      eq(sent[#sent].action, "item", tag .. "...as an item choice")
      ev({ t = "chose", slot = 0, side = "a", text = "ANN" })
      eq(f.phase, "play", tag .. "the referee took it")
      ev({ t = "item", slot = 0, side = "a", text = "4" })
      eq(FakeBag.get(SESSION.bag, 4), 2, tag .. "the ball is spent on the referee's word")
      ev({ t = "msg", text = "ANN used POKé BALL!" })
      ev({ t = "ball", slot = 0, side = "a", target = 3, amount = 1, text = "4" })
      ev({ t = "msg", text = "Darn! The POKéMON broke free!" })
      ev({ t = "msg", text = "PIDGEY is watching carefully!" })
      ev({ t = "turn" })
      drain()
      eq(f.phase, "choose", tag .. "turn 2's menu")
      check(classicDraw(f:gen3ClassicModel()) == true, tag .. "the page draws after a throw")
      -- A stray solicitation for our seat opens nothing.
      ev({ t = "turn", slot = 0 })
      eq(f.mustReplace, false, tag .. "no replacement is owed on a side that fields nothing")
      eq(f.pendingTurn, false, tag .. "...and no picker opens")
      ev({ t = "faint", slot = 0, side = "a", text = "?" })
      eq(f.mustReplace, false, tag .. "a stray faint on our seat owes nothing either")
      ev({ t = "turn" })
      drain()
      -- RUN: filed as in any wild fight.
      f:runCommand("RUN")
      eq(sent[#sent].action, "run", tag .. "RUN is filed")
      ev({ t = "chose", slot = 0, side = "a", text = "ANN" })
      ev({ t = "run", slot = 0, side = "a" })
      ev({ t = "msg", text = "Got away safely!" })
      ev({ t = "over" })
      f:onOutcome({ battle = "um", outcome = "win", winners = { "wild" }, losers = { "me" },
                    reason = "run" })
      drain()
      check(f.finished, tag .. "the fight ends")
      eq(saidCount(f, "Got away safely!"), 1, tag .. "the getaway is said once")
      if not classic then
        local okW = withLove(f.drawWidescreen, f, 1280, 720)
        check(okW, tag .. "the arena frame is asked for")
      end
      eq(f.drawFailed, nil, tag .. "nothing failed to draw")
    end

    -- The test hook answers a no-battler turn with the one command it has.
    do
      newGame()
      SESSION.party = { monOf(4, 20) }
      local wild = assert(Sheet3.mon(SESSION, monOf(16, 5), 0, { wild = true }))
      local f, ev, sent, drain = screen3("wild", { noOwnBattler = true, autoPick = true },
        { wildParty = { wild } })
      f.autoPick = true
      ev({ t = "send", slot = 3, side = "b", text = "PIDGEY", speciesId = "16", hp = 20, maxHp = 20 })
      ev({ t = "turn" })
      drain()
      eq(sent[1] and sent[1].action, "run", "no battler: autoPick files RUN, never a move")
    end

    -- An empty party is no reason to refuse a fight that fields nothing.
    do
      newGame()
      SESSION.party = {}
      local wild = assert(Sheet3.mon(SESSION, monOf(16, 5), 0, { wild = true }))
      local f = screen3("wild", { noOwnBattler = true }, { wildParty = { wild } })
      eq(f.finished, false, "no battler: an empty party does not end the fight")
      check(not said(f, "no POKeMON"), "no battler: ...and says nothing about it")
      local plain = screen3("wild", nil, { wildParty = { wild } })
      eq(plain.finished, true, "an ordinary fight with an empty party still ends at once")
    end

    -- ---- (b) the command-set seam
    do
      newGame()
      SESSION.party = { monOf(4, 20) }
      local wild = assert(Sheet3.mon(SESSION, monOf(16, 5), 0, { wild = true }))
      local ran = {}
      local f, ev, sent, drain = screen3("wild", {
        noOwnBattler = true,
        commands = { "BALL", "BAIT", "ROCK", "RUN" },
        commandLabels = { BALL = "BALL", BAIT = "BAIT", ROCK = "ROCK" },
        commandHandlers = {
          BALL = function(screen, id) ran[#ran + 1] = id; screen:sendChoice({ action = "run" }) end,
          ROCK = function() error("boom") end,
        },
        prompt = "What will\nANN\nthrow?",
      }, { wildParty = { wild } })
      ev({ t = "send", slot = 3, side = "b", text = "PIDGEY", speciesId = "16", hp = 20, maxHp = 20 })
      ev({ t = "turn" })
      drain()
      eq(table.concat(f:commandList(), ","), "BALL,BAIT,ROCK,RUN", "commands: the fight's own grid")
      local labels = {}
      for i, item in ipairs(f:bandCommandItems()) do labels[i] = item.label end
      eq(table.concat(labels, ","), "BALL,BAIT,ROCK,RUN", "commands: ...labelled its way")
      local model = f:gen3ClassicModel()
      eq(table.concat(model.commands, ","), "BALL,BAIT,ROCK,RUN", "commands: the classic grid")
      eq(model.prompt, "What will\nANN\nthrow?", "commands: the fight's own prompt")
      eq(ClassicBattle.gen3CommandLabel("BALL"), "BALL", "commands: a kind's word is kept, never remapped")
      f:runCommand("BAIT")
      eq(f.phase, "choose", "commands: an id nothing answers is inert")
      eq(#sent, 0, "commands: ...and files nothing")
      local warned = #warns
      f:runCommand("ROCK")
      eq(f.phase, "choose", "commands: a handler that throws leaves the menu up")
      check(#warns > warned, "commands: ...and is logged")
      press(f, "a")   -- the cursor is on BALL
      eq(ran[1], "BALL", "commands: A on a slab runs its handler")
      eq(sent[1] and sent[1].action, "run", "commands: ...which owns what is filed")
      f:runCommand("RUN")
      eq(sent[2] and sent[2].action, "run", "commands: a built-in id keeps its own arm")
    end

    -- ---- (c) facility prompts (C3 `rules`)
    do
      newGame()
      SESSION.party = { monOf(4, 20) }
      FakeBag.add(SESSION.bag, 13, 1)
      local trainer = { trainerPic = 7, className = "COOLTRAINER", trainerName = "ANA" }
      local f, ev, sent, drain = screen3("coop_npc", { rules = { bag = false, forfeit = true } },
        { trainer = trainer })
      ev({ t = "send", slot = 0, side = "a", text = "CHARMANDER", speciesId = "4", hp = 50,
           maxHp = 50, level = 20, mon = 0 })
      ev({ t = "send", slot = 3, side = "b", text = "PIDGEY", speciesId = "16", hp = 30, maxHp = 30 })
      ev({ t = "turn" })
      drain()
      eq(f.phase, "choose", "facility: the menu")
      local mark = #(f.textLog or {})
      f:runCommand("ITEM")
      eq(f.phase, "choose", "facility: BAG does not open with `rules.bag = false`")
      check(said(f, "ITEMS CAN'T BE USED NOW.", mark), "facility: the cart's line (STRINGID_ITEMSCANTBEUSEDNOW)")
      f:update(0)
      local shown = f:gen3ClassicModel()
      eq(shown.commands, nil, "facility: the line takes the box over the menu while it is read")
      check(shown.message ~= nil, "facility: ...as the message")
      drain()
      local back = f:gen3ClassicModel()
      check(back.commands ~= nil, "facility: the menu is back once it is read")
      packOff = true
      f:runCommand("ITEM")
      packOff = false
      check(said(f, "Items can't be used now.", mark), "facility: the fallback without a text pack")
      drain()
      eq(#sent, 0, "facility: no item choice went out")
      -- RUN asks first.
      f:runCommand("RUN")
      eq(f.phase, "ask", "forfeit: RUN asks before anything is filed")
      eq(f.asking and f.asking.cursor, 2, "forfeit: the cursor opens on NO (PlayerHandleYesNoBox)")
      eq(#sent, 0, "forfeit: ...nothing filed yet")
      local asked = f:gen3ClassicModel()
      eq(asked.message, CART.STRINGID_QUESTIONFORFEITMATCH, "forfeit: the cart's question in the box")
      eq(asked.yesNo and asked.yesNo.cursor, 2, "forfeit: ...the YES / NO window beside it")
      eq(asked.commands, nil, "forfeit: ...in place of the grid")
      check(classicDraw(asked) == true, "forfeit: the classic page draws the question")
      local yes, no = textIs("YES"), textIs("NO")
      local box = ClassicBattle.gen3YesNoLayout()
      check(yes and yes.x == box.rows[1].x and yes.y == box.rows[1].y, "forfeit: YES at the cart's window")
      check(no and no.y == box.rows[2].y, "forfeit: NO under it")
      check(box.frame.x == 192 and box.frame.y == 64 and box.frame.w == 48 and box.frame.h == 48,
            "forfeit: the window is YESNOBOX_X_Y's tiles 24..29 x 8..13")
      press(f, "b")
      eq(f.phase, "choose", "forfeit: B is NO -- back to the menu")
      eq(#sent, 0, "forfeit: ...and nothing is filed")
      f:runCommand("RUN")
      press(f, "a")
      eq(#sent, 0, "forfeit: A on NO files nothing")
      eq(f.phase, "choose", "forfeit: ...and the menu is back")
      f:runCommand("RUN")
      press(f, "up")
      eq(f.asking.cursor, 1, "forfeit: UP puts the cursor on YES")
      local band = Battlefield.drawListPanel
      local bandRows, bandTitle
      Battlefield.drawListPanel = function(rows, cursor, opts)
        bandRows, bandTitle = rows, opts and opts.title
        return true
      end
      local okBand = withLove(f.drawModernBand, f)
      Battlefield.drawListPanel = band
      check(okBand, "forfeit: the arena's band draws the question")
      eq(bandRows and #bandRows, 2, "forfeit: ...as a two-row list")
      check(bandTitle and bandTitle:find("FORFEIT", 1, true), "forfeit: ...titled with the question")
      press(f, "a")
      eq(sent[1] and sent[1].action, "run", "forfeit: a YES files RUN")
      eq(f.phase, "play", "forfeit: ...and the turn is answered")
      -- A chose that closes the turn takes a question still up with it.
      ev({ t = "turn" })
      drain()
      f:runCommand("RUN")
      ev({ t = "chose", slot = 0, side = "a", text = "ANN" })
      eq(f.asking, nil, "forfeit: the referee answering the turn drops the question")
      eq(f.phase, "play", "forfeit: ...and the phase")
    end
    -- Without the rules: today's trainer refusal, and today's bag.
    do
      newGame()
      SESSION.party = { monOf(4, 20) }
      FakeBag.add(SESSION.bag, 13, 1)
      local f, ev, sent, drain = screen3("coop_npc", nil, { trainer = { className = "LASS", trainerName = "AMY" } })
      ev({ t = "send", slot = 0, side = "a", text = "CHARMANDER", speciesId = "4", hp = 50, maxHp = 50, mon = 0 })
      ev({ t = "send", slot = 3, side = "b", text = "PIDGEY", speciesId = "16", hp = 30, maxHp = 30 })
      ev({ t = "turn" })
      drain()
      f:runCommand("RUN")
      check(said(f, "No! There's no"), "no rules: RUN is the trainer refusal as before")
      eq(f.phase, "choose", "no rules: ...no question")
      drain()
      f:runCommand("ITEM")
      eq(f.phase, "item", "no rules: BAG opens")
      eq(#sent, 0, "no rules: nothing filed")
    end
    -- `forfeit` is a trainer fight's rule: a wild RUN stays a RUN.
    do
      newGame()
      SESSION.party = { monOf(4, 20) }
      local wild = assert(Sheet3.mon(SESSION, monOf(16, 5), 0, { wild = true }))
      local f, ev, sent, drain = screen3("wild", { rules = { forfeit = true } }, { wildParty = { wild } })
      ev({ t = "send", slot = 0, side = "a", text = "CHARMANDER", speciesId = "4", hp = 50, maxHp = 50, mon = 0 })
      ev({ t = "send", slot = 3, side = "b", text = "PIDGEY", speciesId = "16", hp = 20, maxHp = 20 })
      ev({ t = "turn" })
      drain()
      f:runCommand("RUN")
      eq(sent[1] and sent[1].action, "run", "forfeit in a wild fight: RUN is filed, no question")
    end

    -- ---- (d) Oak's voice-over (C6 `lesson`)
    do
      newGame()
      SESSION.party = { monOf(4, 5), monOf(16, 5) }
      FakeBag.add(SESSION.bag, 13, 2)
      local rival = { trainerPic = 9, className = "RIVAL", trainerName = "TERRY" }
      local f, ev, sent, drain = screen3("coop_npc", { firstBattle = "oak" }, { trainer = rival })
      eq(f.firstBattle, "oak", "oak: the screen option is read")
      ev({ t = "send", slot = 0, side = "a", text = "CHARMANDER", speciesId = "4", hp = 20, maxHp = 20,
           level = 5, mon = 0 })
      ev({ t = "send", slot = 3, side = "b", text = "SQUIRTLE", speciesId = "7", hp = 20, maxHp = 20 })
      ev({ t = "turn" })
      local go = said(f, "Go! CHARMANDER")
      local petes = said(f, "OAK: OH, FOR PETE'S SAKE")
      check(go and petes and petes > go, "oak: 'for Pete's sake' after the intro send-outs")
      check(said(f, "SO PUSHY, ANN!"), "oak: ...paged at the printer's break, with the player's name")
      check(said(f, "OAK: TRY BATTLING!"), "oak: ...every page")
      -- The field darkens under exactly those lines.
      local seenDark, seenLight, litFoe, unlit = false, false, false, true
      for _ = 1, 80 do
        f:update(2.0)
        if f.shown and f.shown:find("OAK:", 1, true) then
          if f.voiceover then seenDark = true end
          local model = f:gen3ClassicModel()
          if f.shown:find("THE TRAINER THAT", 1, true) then
            litFoe = model.voiceoverLit == "foe"
            classicDraw(model)
            eq(chromeCount("drawEnemyBox"), 2, "oak: the foe's box is lit again over the dark")
          elseif model.voiceoverLit ~= nil then
            unlit = false
          end
          if model.voiceover and model.message then
            check(classicDraw(model) == true, "oak: the classic page draws the voice-over")
            check(dimDrawn(240, 112), "oak: ...the field darkened halfway to black")
            local line = textAt("OAK:")
            eq(line and line.colors, "normal", "oak: ...the line in dark ink (the voice-over frame)")
            eq(line and line.x, ClassicBattle.G3.VOICEOVER_X, "oak: ...at B_WIN_OAK_OLD_MAN's origin")
          end
        elseif f.shown == nil and #f.lines == 0 then
          seenLight = f.voiceover == nil
          break
        end
      end
      f:update(2.0)
      check(seenDark, "oak: the voice-over darkens the field")
      check(litFoe, "oak: 'The trainer that...' lights the foe's healthbox (PrintOakText_ForPetesSake)")
      check(unlit, "oak: ...and only that page")
      check(seenLight, "oak: ...and lifts after his last page")
      eq(f.phase, "choose", "oak: the menu opens behind him")
      -- The arena darkens its field the same way.
      f.voiceover = true
      local _, dimmed = withLove(f.drawVoiceoverDim, f)
      local dimCalls = drawnCalls
      f.voiceover = nil
      drawnCalls = dimCalls
      check(dimmed and dimDrawn(Battlefield.WIDTH, Battlefield.FIELD_BOTTOM),
            "oak: the arena's field darkens under him, the band does not")
      -- The referee's lessons.
      local mark = #(f.textLog or {})
      f:runCommand("FIGHT")
      f:pickMove(1)
      ev({ t = "chose", slot = 0, side = "a", text = "ANN" })
      ev({ t = "damage", slot = 3, side = "b", hp = 15, maxHp = 20, amount = 5 })
      ev({ t = "lesson", text = "damage" })
      ev({ t = "msg", text = "SQUIRTLE used TACKLE!" })
      ev({ t = "lesson", text = "damage" })
      ev({ t = "lesson", text = "1" })
      ev({ t = "lesson", text = "stat" })
      ev({ t = "lesson", text = "nonsense" })
      ev({ t = "turn" })
      local dmg, used = said(f, "INFLICTING DAMAGE", mark), said(f, "SQUIRTLE used TACKLE!", mark)
      check(dmg and used and dmg < used, "oak: the damage lesson where the referee put it")
      eq(saidCount(f, "INFLICTING DAMAGE", mark), 1, "oak: ...once, however often it is asked")
      check(said(f, "LOWERING THE FOE'S STATS", mark), "oak: the stat lesson")
      drain()
      -- RUN: his line, every time, never the plain refusal.
      mark = #(f.textLog or {})
      f:runCommand("RUN")
      drain()
      f:runCommand("RUN")
      drain()
      eq(saidCount(f, "NO RUNNING AWAY", mark), 2, "oak: RUN is his line every time")
      eq(said(f, "No! There's no", mark), nil, "oak: ...never the plain trainer refusal")
      eq(#sent, 1, "oak: ...and nothing more is filed")
      -- The first POKéMON menu is his first; the picker opens behind him.
      mark = #(f.textLog or {})
      f:runCommand("SWITCH")
      eq(f.phase, "choose", "oak: the picker waits for his party lesson")
      drain()
      check(said(f, "THIS IS YOUR PARTY", mark), "oak: the party lesson")
      eq(f.phase, "switch", "oak: ...then the picker")
      press(f, "b")
      f:runCommand("SWITCH")
      eq(f.phase, "switch", "oak: the second POKéMON menu opens at once")
      press(f, "b")
      -- The first POTION chosen.
      mark = #(f.textLog or {})
      f.itemPick = { id = 13, effect = Sheet3.itemEffect(13) }
      check(f:commitItem(1, nil), "oak: a POTION goes out")
      check(said(f, "KEEP YOUR EYES ON YOUR HP", mark), "oak: ...after his HP lesson")
      local litRow = nil
      for _, row in ipairs(f.lines) do
        if type(row) == "table" and row.stateRow == "voiceover" and row.value == true then litRow = row end
      end
      eq(litRow and litRow.lit, "ally", "oak: the HP lesson lights the player's healthbox (PrintOakText_KeepAnEyeOnHP)")
      eq(sent[#sent].item, "13", "oak: ...as the item choice")
      ev({ t = "unchose", slot = 0, side = "a", text = "ANN" })
      drain()
      f.itemPick = { id = 13, effect = Sheet3.itemEffect(13) }
      f:commitItem(1, nil)
      eq(saidCount(f, "KEEP YOUR EYES ON YOUR HP", mark), 1, "oak: ...once")
      -- The caller's two, behind its own ending lines.
      check(f:sayLesson3("prize"), "oak: the caller says the prize lesson")
      check(f:sayLesson3("lost"), "oak: ...and the disappointed one")
      check(not f:sayLesson3("prize"), "oak: ...each once")
      check(said(f, "HM! EXCELLENT!") and said(f, "HOW DISAPPOINTING"), "oak: both are said")
      check(f:sayLesson3("winEarnsPrize") == false, "oak: the engine's key names the same lesson")
      check(f:sayLesson3("win") == false and f:sayLesson3("lose") == false,
            "oak: ...and so do the referee's ids")
    end
    -- The referee's ids, as BattleSim3 states them (Turn.LESSONS): each one
    -- names its lesson, and the two ending ones wait for the caller's lines.
    for _, id in ipairs({ "intro", "damage", "stat", "potion", "party", "run", "win", "lose" }) do
      check(Mediated.LESSONS3[id] ~= nil, "oak: the referee's `" .. id .. "` names a lesson")
    end
    do
      newGame()
      SESSION.party = { monOf(4, 5) }
      local rival = { trainerPic = 9, className = "RIVAL", trainerName = "TERRY" }
      local f, ev, sent, drain = screen3("coop_npc", { firstBattle = "oak" }, { trainer = rival })
      ev({ t = "send", slot = 0, side = "a", text = "CHARMANDER", speciesId = "4", hp = 20, maxHp = 20, mon = 0 })
      ev({ t = "lesson", text = "intro" })
      ev({ t = "turn" })
      eq(saidCount(f, "FOR PETE'S SAKE"), 1, "oak: the referee's intro and the screen's are one")
      drain()
      ev({ t = "faint", slot = 3, side = "b", text = "SQUIRTLE" })
      ev({ t = "lesson", text = "win" })
      eq(said(f, "HM! EXCELLENT!"), nil, "oak: `win` waits for the prize line")
      ev({ t = "over" })
      f:onOutcome({ battle = "um", outcome = "win", winners = { "me" }, losers = { "p" }, reason = "ko" })
      f:say("ANN got $96 for winning!")   -- the caller's prize line (SoloBattle)
      drain()
      local prize, oak = said(f, "for winning!"), said(f, "HM! EXCELLENT!")
      check(prize and oak and oak > prize, "oak: ...and follows it once the ending is read")
      eq(saidCount(f, "HM! EXCELLENT!"), 1, "oak: ...once")
      eq(f.voiceover, nil, "oak: the field is light again before the screen closes")
      -- The caller may say it itself, at its own line: the held one goes.
      local g, gev, _, gdrain = screen3("coop_npc", { firstBattle = "oak" }, { trainer = rival })
      gev({ t = "lesson", text = "lose" })
      gev({ t = "over" })
      g:onOutcome({ battle = "um", outcome = "win", winners = { "p" }, losers = { "me" }, reason = "ko" })
      g:say("RIVAL: YEAH! AM I GREAT OR WHAT?")
      check(g:sayLesson3("lose"), "oak: the caller says `lose` behind the win text")
      gdrain()
      eq(saidCount(g, "HOW DISAPPOINTING"), 1, "oak: ...and the held one is not said again")
      -- The bag's party picker is his first party menu too.
      newGame()
      SESSION.party = { monOf(4, 5), monOf(16, 5) }
      FakeBag.add(SESSION.bag, 13, 1)
      local b, bev, _, bdrain = screen3("coop_npc", { firstBattle = "oak" }, { trainer = rival })
      bev({ t = "send", slot = 0, side = "a", text = "CHARMANDER", speciesId = "4", hp = 10, maxHp = 20, mon = 0 })
      bev({ t = "turn" })
      bdrain()
      b:runCommand("ITEM")
      eq(b.phase, "item", "oak: BAG opens")
      press(b, "a")   -- the POTION, the bag's one row
      eq(b.phase, "item", "oak: the party picker waits for his lesson")
      bdrain()
      check(said(b, "THIS IS YOUR PARTY"), "oak: the party lesson from the bag")
      eq(b.phase, "item_party", "oak: ...then the picker")
    end
    -- A fight that is not Oak's: no intro, the plain RUN line; a `lesson`
    -- from the referee is still said.
    do
      newGame()
      SESSION.party = { monOf(4, 5) }
      local f, ev, sent, drain = screen3("coop_npc", nil, { trainer = { className = "RIVAL", trainerName = "T" } })
      ev({ t = "send", slot = 0, side = "a", text = "CHARMANDER", speciesId = "4", hp = 20, maxHp = 20, mon = 0 })
      ev({ t = "turn" })
      eq(said(f, "OAK:"), nil, "no first battle: no voice-over at the intro")
      drain()
      f:runCommand("RUN")
      check(said(f, "No! There's no"), "no first battle: the plain refusal")
      ev({ t = "lesson", text = "stat" })
      check(said(f, "LOWERING"), "a referee `lesson` is said whatever the screen was told")
      -- Birch's fight: nothing of the screen's own.  RUN is filed like any wild
      -- RUN -- a SMOKE BALL or RUN AWAY still gets away first on the cart
      -- (pokeemerald battle_main.c:4021) -- and a refusal's "Don't leave me
      -- like this!" reaches the box as a line from behind the screen (the
      -- kind's `choose` parking it, SoloBattle's pump), said like any other.
      local b, bev, bsent, bdrain = screen3("wild", { firstBattle = "birch" },
        { wildParty = { assert(Sheet3.mon(SESSION, monOf(16, 2), 0, { wild = true })) } })
      eq(b.firstBattle, "birch", "birch: the screen option is read")
      bev({ t = "send", slot = 0, side = "a", text = "CHARMANDER", speciesId = "4", hp = 20, maxHp = 20, mon = 0 })
      bev({ t = "turn" })
      bdrain()
      eq(said(b, "OAK:"), nil, "birch: no voice-over")
      b:runCommand("RUN")
      eq(bsent[1] and bsent[1].action, "run", "birch: RUN is filed (the refusal is the referee's)")
      b:say("PROF. BIRCH: Don't leave me like this!")
      check(said(b, "Don't leave me like this!"), "birch: ...and his line is said when it comes")
    end
    -- No text for the lessons: the fight goes on, warned once.
    do
      newGame()
      SESSION.party = { monOf(4, 5) }
      oakOff = true
      local warned = #warns
      local f, ev = screen3("coop_npc", { firstBattle = "oak" }, { trainer = { className = "RIVAL", trainerName = "T" } })
      ev({ t = "send", slot = 0, side = "a", text = "CHARMANDER", speciesId = "4", hp = 20, maxHp = 20, mon = 0 })
      ev({ t = "turn" })
      ev({ t = "lesson", text = "damage" })
      oakOff = false
      eq(said(f, "OAK:"), nil, "oak, no text: nothing is said")
      eq(#warns, warned + 1, "oak, no text: warned once")
      eq(f.pendingTurn, true, "oak, no text: the turn still opens")
    end

    -- ---- (e) the Pokémon Tower GHOST
    do
      newGame()
      SESSION.party = { monOf(4, 30) }
      FakeBag.add(SESSION.bag, 4, 2)
      local maro = assert(Sheet3.mon(SESSION, monOf(16, 30), 0, { wild = true }))
      local f, ev, sent, drain = screen3("wild", { ghost = "veiled" }, { wildParty = { maro } })
      eq(f.ghost, "veiled", "ghost: the screen option is read")
      check(said(f, "THE GHOST APPEARED!") and said(f, "THE GHOST CAN'T BE ID'D!"),
            "ghost: the cart's opening (sText_GhostAppearedCantId)")
      eq(introFill and introFill.ghostUnveiled, false, "ghost: ...asked as the veiled one")
      eq(said(f, "Wild PIDGEY"), nil, "ghost: no 'Wild X appeared!'")
      ev({ t = "send", slot = 0, side = "a", text = "CHARMANDER", speciesId = "4", hp = 60, maxHp = 60, mon = 0 })
      ev({ t = "send", slot = 3, side = "b", text = "PIDGEY", speciesId = "16", hp = 40, maxHp = 40, level = 30 })
      ev({ t = "turn" })
      drain()
      eq(said(f, "sent out"), nil, "ghost: no send-out line for it")
      local foe = f:gen3ClassicModel().foe
      eq(foe and foe.name, Mediated.ghostName3(), "ghost: the plate reads GHOST")
      eq(foe and foe.sprite, ghostImage, "ghost: the engine's silhouette is its pic")
      eq(foe and foe.gender, nil, "ghost: no gender mark")
      eq(foe and foe.caught, false, "ghost: no owned ball")
      eq(foe and foe.speciesId, nil, "ghost: nothing of the species underneath")
      local seat = f:battlefieldCtx().foeSeats[1]
      eq(seat and seat.name, Mediated.ghostName3(), "ghost: the arena's seat reads GHOST")
      eq(seat and seat.front, ghostImage, "ghost: ...on the silhouette")
      eq(seat and seat.icon, nil, "ghost: ...with no icon of the species")
      check(classicDraw(f:gen3ClassicModel()) == true, "ghost: the classic page draws it")
      local nameDrawn = textAt(Mediated.ghostName3())
      check(nameDrawn ~= nil, "ghost: ...its box named GHOST")
      eq(textAt("PIDGEY"), nil, "ghost: ...and never the species")
      -- A ball: dodged and spent.
      f.itemPick = { id = 4, effect = Sheet3.itemEffect(4) }
      f:commitItem(nil, nil)
      ev({ t = "chose", slot = 0, side = "a", text = "ANN" })
      ev({ t = "item", slot = 0, side = "a", text = "4" })
      ev({ t = "msg", text = "ANN used POKé BALL!" })
      local mark = #(f.textLog or {})
      local before = #f.lines
      ev({ t = "ball", slot = 0, side = "a", target = 3, amount = -1, text = "4" })
      local rows = {}
      for i = before + 1, #f.lines do
        local row = f.lines[i]
        if type(row) == "table" and row.anim then rows[#rows + 1] = row.anim end
      end
      eq(table.concat(rows, ","), "TOSS_ANIM,BLOCKBALL_ANIM",
         "dodge: the throw and nothing to open (no recall, no shakes, no burst)")
      ev({ t = "msg", text = "It dodged the thrown BALL!\nThis POKéMON can't be caught!" })
      ev({ t = "msg", text = "GHOST: Get out...... Get out......" })
      eq(saidCount(f, "DODGED THE THROWN BALL", mark), 1, "dodge: the cart's line (STRINGID_ITDODGEDBALL)")
      eq(saidCount(f, "It dodged the thrown BALL", mark), 0, "dodge: ...and not the referee's again")
      check(said(f, "Get out", mark), "dodge: the line after it is still said")
      eq(FakeBag.get(SESSION.bag, 4), 1, "dodge: the ball is spent")
      drain()
      eq(f.ballFlow, nil, "dodge: no throw is left standing over the GHOST")
      -- Without a text pack: the fallback, still once.
      packOff = true
      mark = #(f.textLog or {})
      ev({ t = "ball", slot = 0, side = "a", target = 3, amount = -1, text = "4" })
      ev({ t = "msg", text = "It dodged the thrown BALL!\nThis POKéMON can't be caught!" })
      packOff = false
      eq(saidCount(f, "It dodged the thrown BALL", mark), 1, "dodge: the fallback, once")
      -- A lossy stream: the referee's sentence went missing, the next line is said.
      mark = #(f.textLog or {})
      local seq0 = f.seq
      f:onEvent({ battle = "um", seq = seq0 + 1, t = "ball", slot = 0, side = "a", target = 3, amount = -1, text = "4" })
      f:onEvent({ battle = "um", seq = seq0 + 3, t = "msg", text = "It dodged the thrown BALL! again" })
      eq(saidCount(f, "again", mark), 1, "dodge gap: a line that is not right behind it is said")
      -- The scared clips are nobody's order: no callout, no lunge.
      local n = #f.lines
      ev({ t = "anim", slot = 0, side = "a", text = "MON_SCARED" })
      ev({ t = "anim", slot = 3, side = "b", text = "GHOST_GET_OUT" })
      eq(f.lines[n + 1] and f.lines[n + 1].quiet, true, "ghost: MON_SCARED is a quiet clip")
      eq(f.lines[n + 2] and f.lines[n + 2].quiet, true, "ghost: GHOST_GET_OUT too")
      drain()
      eq(f.battlefieldBubbles, nil, "ghost: ...so no trainer shouts it")
    end
    -- Unveiled: the silhouette through the opening, MAROWAK from the scope on.
    do
      newGame()
      SESSION.party = { monOf(4, 30) }
      local maro = assert(Sheet3.mon(SESSION, monOf(16, 30), 0, { wild = true }))
      local f, ev, sent, drain = screen3("wild", { ghost = "unveiled" }, { wildParty = { maro } })
      ev({ t = "send", slot = 0, side = "a", text = "CHARMANDER", speciesId = "4", hp = 60, maxHp = 60, mon = 0 })
      ev({ t = "send", slot = 3, side = "b", text = "PIDGEY", speciesId = "16", hp = 40, maxHp = 40, level = 30 })
      ev({ t = "turn" })
      eq(introFill and introFill.ghostUnveiled, true, "unveil: the opening asked as the scoped one")
      local appeared = said(f, "THE GHOST APPEARED!")
      local scope, was = said(f, "SILPH SCOPE UNVEILED"), said(f, "THE GHOST WAS MAROWAK!")
      check(appeared and scope and was and appeared < scope and scope < was,
            "unveil: appeared -> SILPH SCOPE unveiled -> the GHOST was (BattleScript_SilphScopeUnveiled)")
      eq(said(f, "DARN!"), nil, "unveil: no 'can't be ID'd'")
      local go = said(f, "Go! CHARMANDER")
      check(go and was and go > was, "unveil: ...all before our send-out, as the cart opens it")
      eq(f:gen3ClassicModel().foe.name, Mediated.ghostName3(), "unveil: the GHOST until the scope plays")
      local scoped = false
      for _, row in ipairs(f.lines) do
        if type(row) == "table" and row.anim == "SILPH_SCOPED" then scoped = row.quiet == true end
      end
      check(scoped, "unveil: B_ANIM_SILPH_SCOPED plays on the foe, quietly")
      drain()
      local foe = f:gen3ClassicModel().foe
      eq(foe and foe.name, "PIDGEY", "unveil: its own name after the scope")
      check(foe and foe.sprite ~= ghostImage and foe.sprite ~= nil, "unveil: ...and its own pic")
      eq(f:battlefieldCtx().foeSeats[1].name, "PIDGEY", "unveil: the arena too")
      eq(f:ghostVeiled(), false, "unveil: the veil is off")
    end
    -- No silhouette in the cache: no pic at all, never the monster's own.
    do
      newGame()
      SESSION.party = { monOf(4, 30) }
      local saved = FakePokemon.ghostPic
      FakePokemon.ghostPic = nil
      local warned = #warns
      local f, ev = screen3("wild", { ghost = "veiled" },
        { wildParty = { assert(Sheet3.mon(SESSION, monOf(16, 30), 0, { wild = true })) } })
      ev({ t = "send", slot = 3, side = "b", text = "PIDGEY", speciesId = "16", hp = 40, maxHp = 40 })
      local foe = f:gen3ClassicModel().foe
      eq(foe and foe.sprite, nil, "ghost, no pic: nothing drawn")
      eq(foe and foe.noPic, true, "ghost, no pic: ...and nothing looked for again")
      eq(#warns, warned + 1, "ghost, no pic: warned once")
      FakePokemon.ghostPic = saved
    end

    -- ---- (f) the fight's own theme
    do
      newGame()
      SESSION.party = { monOf(4, 30) }
      local wild = assert(Sheet3.mon(SESSION, monOf(16, 30), 0, { wild = true }))
      audioCalls = {}
      local f = screen3("wild", { song = 412 }, { wildParty = { wild } })
      f:enter()
      local played = nil
      for _, call in ipairs(audioCalls) do if call[1] == "playSong" then played = call[2] end end
      eq(played, 412, "song: the kind's theme is what plays")
      audioCalls = {}
      f:restoreBattleTheme()
      played = nil
      for _, call in ipairs(audioCalls) do if call[1] == "playSong" then played = call[2] end end
      eq(played, 412, "song: ...and what an evolution movie restores")
      audioCalls = {}
      local plain = screen3("wild", nil, { wildParty = { wild } })
      plain:enter()
      played = nil
      for _, call in ipairs(audioCalls) do if call[1] == "playSong" then played = call[2] end end
      check(played ~= nil and played ~= 412, "song: without one, the mode's theme as ever")
    end

    -- ---- (h) the real referee's stream (BattleSim3, contract C3 / C6)
    --
    -- The screen over a local referee told the same fight: its `ghost` and
    -- `firstBattle` create options, the foe answered by the referee itself.
    local function realScreen(mode, foeSheets, screenOpts, createOpts)
      local pending, battle = {}, nil
      local foeId = (mode == "wild") and "wild" or "peer"
      local transport = {
        isReady = function() return true end,
        send = function(_, kind, msg)
          if type(msg) == "table" and msg.action then
            local c = {}
            for k, v in pairs(msg) do if k ~= "battle" then c[k] = v end end
            local took = battle and battle:submitChoice("me", c) or false
            if took then battle:autoPick(foeId) end
            return took
          elseif type(msg) == "table" and msg.mons then
            if msg.side ~= "b" then pending.party = msg end
          elseif type(msg) == "table" and (msg.typeTable or msg.movePool) then
            pending.ruleset = msg
          end
        end,
      }
      local o = { transport = transport, game = GAME, battle = "rr", role = "host",
                  peerId = (mode ~= "wild") and foeId or nil, peerName = "BOB", mode = mode,
                  wildParty = (mode == "wild") and foeSheets or nil, classicUi = true }
      for k, v in pairs(screenOpts or {}) do o[k] = v end
      local fight = Mediated.new(o)
      fight:start(GAME)
      local ruleset = pending.ruleset or {}
      local create = {
        id = "rr", mode = mode, seed = 5, typeTable = ruleset.typeTable, movePool = ruleset.movePool,
        sides = {
          a = { { playerId = "me", name = "ANN", mons = pending.party.mons, bag = pending.party.bag } },
          b = { { playerId = foeId, name = "BOB", mons = foeSheets } },
        },
      }
      for k, v in pairs(createOpts or {}) do create[k] = v end
      battle = assert(Sim.Turn.create(create))
      fight:onReady({ battle = "rr", mode = mode, sides = { a = { "me" }, b = { foeId } } })
      local function pump()
        battle:tick(0)
        for _, e in ipairs(battle:drainEvents()) do fight:onEvent(e) end
        local out = battle:outcome()
        if out and not fight.finished then
          fight:onOutcome({ battle = "rr", outcome = out.outcome, winners = out.winners,
                            losers = out.losers, reason = out.reason, caught = out.caught })
        end
        for _ = 1, 400 do
          fight:update(2.0)
          if fight.phase == "choose" or (fight.phase == "over" and #fight.lines == 0
             and not fight.shown) then break end
        end
      end
      return fight, battle, pump
    end
    do
      newGame()
      SESSION.party = { monOf(4, 30, { moves = { 10 }, pp = { 35 }, maxPp = { 35 } }) }
      FakeBag.add(SESSION.bag, 4, 2)
      local maro = assert(Sheet3.mon(SESSION, monOf(16, 30, { moves = { 33 }, pp = { 35 }, maxPp = { 35 } }),
        0, { wild = true }))
      local f, battle, pump = realScreen("wild", { maro }, { ghost = "veiled" }, { ghost = "veiled" })
      pump()
      eq(f.phase, "choose", "referee ghost: the menu opens")
      eq(f:gen3ClassicModel().foe.name, Mediated.ghostName3(), "referee ghost: the GHOST stands there")
      local mark = #(f.textLog or {})
      f.itemPick = { id = 4, effect = Sheet3.itemEffect(4) }
      check(f:commitItem(nil, nil), "referee ghost: a ball goes out")
      pump()
      eq(saidCount(f, "DODGED THE THROWN BALL", mark), 1, "referee ghost: the dodge, in the cart's words")
      eq(saidCount(f, "It dodged the thrown BALL", mark), 0, "referee ghost: ...the referee's sentence not again")
      eq(FakeBag.get(SESSION.bag, 4), 1, "referee ghost: the ball is spent")
      check(said(f, "Get out", mark), "referee ghost: the GHOST's turn is its line")
      eq(f.finished, false, "referee ghost: the fight goes on")
      f:runCommand("RUN")
      pump()
      check(f.finished, "referee ghost: RUN ends it")
    end
    do
      newGame()
      SESSION.party = { monOf(4, 5, { moves = { 10 }, pp = { 35 }, maxPp = { 35 } }) }
      local rival = assert(Sheet3.mon(SESSION, monOf(16, 5, { moves = { 45 }, pp = { 40 }, maxPp = { 40 } }), 0))
      local f, battle, pump = realScreen("coop_npc", { rival }, { firstBattle = "oak" },
        { firstBattle = "oak" })
      pump()
      eq(f.phase, "choose", "referee oak: the menu opens")
      eq(saidCount(f, "FOR PETE'S SAKE"), 1, "referee oak: 'for Pete's sake', once (referee and screen agree)")
      f:runCommand("RUN")
      pump()
      eq(saidCount(f, "NO RUNNING AWAY"), 1, "referee oak: RUN is Oak's line, once")
      f:runCommand("FIGHT")
      f:pickMove(1)
      pump()
      eq(saidCount(f, "INFLICTING DAMAGE"), 1, "referee oak: the damage lesson, from the referee's event")
      local guard = 0
      while not f.finished and guard < 20 do
        guard = guard + 1
        if f.phase == "choose" then f:runCommand("FIGHT"); f:pickMove(1) end
        pump()
      end
      check(f.finished, "referee oak: the fight ends")
      for _ = 1, 20 do f:update(2.0) end
      local won = f.result == "win"
      check(said(f, won and "HM! EXCELLENT!" or "HOW DISAPPOINTING") ~= nil,
            "referee oak: the ending lesson is said once the ending is read")
    end

    -- ---- (g) the options read nothing they were not given
    do
      newGame()
      SESSION.party = { monOf(4, 30) }
      local f = Mediated.new({ game = GAME, battle = "x", mode = "wild", ghost = "nope",
                               firstBattle = "elm", commands = {}, rules = "no" })
      eq(f.ghost, nil, "options: an unknown ghost shape is ignored")
      eq(f.firstBattle, nil, "options: an unknown first battle is ignored")
      eq(f.commandSet, nil, "options: an empty grid is no grid")
      eq(f.rules, nil, "options: rules must be a table")
      eq(f.noOwnBattler, nil, "options: a side fields its battler unless told otherwise")
      f:applyScreenOptions({ noOwnBattler = true, firstBattle = "oak" })
      eq(f.noOwnBattler, true, "options: applyScreenOptions after `new`")
      eq(f.firstBattle, "oak", "options: ...for any key")
    end

    -- ---- (i) the Safari Zone (wave 3 UM3, screen option `safari`)
    --
    -- The cart's prompts stood in (capitals, the player's name filled the way
    -- BattleText fills B_PLAYER_NAME), so a word read off the "cart" can be
    -- told from a fallback.
    local textBefore = Gen3.battleText
    local safariPack = true
    Gen3.battleText = function(id, fill)
      if safariPack and id == "gText_WhatWillPlayerThrow" then
        return ("WHAT WILL %s\nTHROW?"):format(tostring(fill and fill.playerName))
      end
      if safariPack and id == "gText_WhatWillPkmnDo2" then
        return ("WHAT WILL\n%s DO?"):format(tostring(fill and fill.playerName))
      end
      return textBefore(id, fill)
    end
    -- One frame at a time until `pred` holds (the queue, the holds and the
    -- page's own clocks all run on update's dt).
    local function stepUntil(f, pred, frames)
      for _ = 1, frames or 600 do
        if pred() then return true end
        f:update(1 / 60)
      end
      return pred()
    end
    local function fxOf(f, kind, side)
      for _, fx in ipairs(f.fx or {}) do
        if fx.kind == kind and (side == nil or fx.side == side) then return fx end
      end
      return nil
    end
    local function recOf(f, kind, side)
      for _, rec in ipairs(f.classicFx3 or {}) do
        if rec.kind == kind and (side == nil or rec.side == side) then return rec end
      end
      return nil
    end

    for _, classic in ipairs({ true, false }) do
      local tag = classic and "safari (classic): " or "safari (arena): "
      newGame()
      SESSION.party = { monOf(4, 20) }
      local wild = assert(Sheet3.mon(SESSION, monOf(16, 5), 0, { wild = true }))
      local f, ev, sent, drain = screen3("wild", { safari = { family = "frlg", balls = 30 } },
        { wildParty = { wild }, classicUi = classic })
      eq(f.noOwnBattler, true, tag .. "a Safari fight fields no battler of ours (implied)")
      eq(f:usesBattlefield(), not classic, tag .. "the page under test is the one asked for")
      ev({ t = "send", slot = 3, side = "b", text = "PIDGEY", speciesId = "16", hp = 20, maxHp = 20,
           level = 5 })
      ev({ t = "turn" })
      drain()
      eq(f.phase, "choose", tag .. "the action menu opens")
      eq(table.concat(f:commandList(), ","), "BALL,BAIT,ROCK,RUN",
         tag .. "FireRed's grid, in the cart's order (HandleInputChooseAction)")
      local labels = {}
      for i, item in ipairs(f:bandCommandItems()) do labels[i] = item.label end
      eq(table.concat(labels, ","), "BALL,BAIT,ROCK,RUN", tag .. "...in its words (gText_SafariZoneMenu)")
      local model = f:gen3ClassicModel()
      eq(model.prompt, "WHAT WILL ANN\nTHROW?",
         tag .. "the cart's own prompt, the player named (gText_WhatWillPlayerThrow)")
      eq(table.concat(model.commands, ","), "BALL,BAIT,ROCK,RUN", tag .. "the GBA page's grid")
      eq(model.ally, nil, tag .. "no plate of ours")
      eq(model.safari and model.safari.balls, 30, tag .. "the SAFARI BALLS box: 30 left")
      if classic then
        check(classicDraw(f:gen3ClassicModel()) == true, tag .. "the page draws")
        eq(chromeCount("drawPlayerBox"), 1, tag .. "...the box on the player's healthbox sheet")
        local title, left = textIs("SAFARI BALLS"), textIs("Left: 30")
        local G3 = ClassicBattle.G3
        check(title and title.x == G3.ALLY_BOX_X + 16 and title.y == G3.ALLY_BOX_Y + 3,
              tag .. "...'SAFARI BALLS' where the name goes (gText_SafariBalls)")
        check(left and left.y == G3.ALLY_BOX_Y + 21,
              tag .. "...'Left: 30' in the HP-figure window (UpdateLeftNoOfBallsTextOnHealthbox)")
      else
        local okW = withLove(f.drawWidescreen, f, 1280, 720)
        check(okW, tag .. "the arena frame draws")
        local x, y, w, h = Mediated.safariPlateRect3()
        eq(x, Battlefield.PLATE_PAD, tag .. "the box stands where our plate would (x)")
        eq(y, Battlefield.FIELD_BOTTOM - Battlefield.PLATE_H - Battlefield.PLATE_PAD,
           tag .. "...(y, over the field floor)")
        eq(w, Battlefield.PLATE_W, tag .. "...a plate wide")
        local printed = false
        for _, call in ipairs(drawnCalls) do
          if call[1] == "print" and call[2] == "Left: 30" then printed = true end
        end
        check(printed, tag .. "the arena prints the count in it")
      end
      -- BALL: filed as a Safari throw; the box moves once its line is read.
      press(f, "a")
      eq(sent[#sent] and sent[#sent].action, "safari", tag .. "BALL files a Safari choice")
      eq(sent[#sent] and sent[#sent].throw, "ball", tag .. "...throw = ball")
      ev({ t = "chose", slot = 0, side = "a", text = "ANN" })
      ev({ t = "item", slot = 0, side = "a", text = "5", amount = 29 })
      ev({ t = "msg", text = "ANN used SAFARI BALL!" })
      ev({ t = "ball", slot = 0, side = "a", target = 3, amount = 1, text = "5" })
      eq(f:safariBalls3(), 30, tag .. "the box still says 30 while the throw is queued")
      local rowAt, lineAt, tossAt = nil, nil, nil
      for i, row in ipairs(f.lines) do
        if type(row) == "table" and row.stateRow == "safariBalls" then rowAt = i end
        if type(row) == "string" and row:find("SAFARI BALL!", 1, true) then lineAt = i end
        if type(row) == "table" and row.anim and row.anim:find("TOSS", 1, true) and not tossAt then
          tossAt = i
        end
      end
      check(lineAt and rowAt and tossAt and lineAt < rowAt and rowAt < tossAt,
            tag .. "the count changes after 'used SAFARI BALL!' and before the throw "
              .. "(BattleScript_SafariBallThrow: printstring, updatestatusicon, handleballthrow)")
      ev({ t = "msg", text = "Darn! The POKéMON broke free!" })
      ev({ t = "msg", text = "PIDGEY is watching carefully!" })
      ev({ t = "turn" })
      drain()
      eq(f:safariBalls3(), 29, tag .. "...29 once it has been read")
      eq(f:gen3ClassicModel().safari.balls, 29, tag .. "the page's box follows")
      -- BAIT: filed, then its clip -- quiet, thrown from the trainer, the sway behind.
      f:runCommand("BAIT")
      eq(sent[#sent] and sent[#sent].throw, "bait", tag .. "BAIT files throw = bait")
      ev({ t = "chose", slot = 0, side = "a", text = "ANN" })
      ev({ t = "msg", text = "ANN threw some BAIT at the PIDGEY!" })
      local n0 = #f.lines
      ev({ t = "anim", slot = 0, side = "a", target = 3, text = "BAIT_THROW" })
      local bait = f.lines[n0 + 1]
      check(bait and bait.general3 == true and bait.quiet == true,
            tag .. "BAIT_THROW is a quiet general clip (Vfx.isGeneral3)")
      check(stepUntil(f, function() return f.anim == bait end), tag .. "...and plays")
      eq(f.animHold, 1.20, tag .. "...holding the queue for its longest beat (the sway)")
      if classic then
        local throw, sway = recOf(f, "throw", "foe"), recOf(f, "sway", "foe")
        check(throw ~= nil, tag .. "the page throws the bait from our side at the foe")
        check(sway and sway.wait == 0.40, tag .. "...and the foe sways once it has landed")
        -- Wave 4b: the bait waits in the trainer's hand for its throw pose
        -- (SpriteCB_SafariBaitOrRock_WaitPlayerThrow: animCmdIndex == 1 --
        -- sAnimCmd_Red_1's first 20 frames).
        local held = f:gen3ClassicModel()
        eq(held.throws3, nil, tag .. "...not thrown yet: the trainer winds up")
        eq(held.playerBack.frame, 1, tag .. "...in the throw pose (back pic frame 1)")
        local released = stepUntil(f, function() return f:gen3ClassicModel().throws3 ~= nil end, 40)
        check(released and f:gen3ClassicModel().playerBack.frame == 2,
              tag .. "...let go as the pose reaches its second frame")
        local throws = f:gen3ClassicModel().throws3
        check(throws and throws[1] and throws[1].from == "ally" and throws[1].to == "foe",
              tag .. "...handed to the page as `throws3`")
        check(classicDraw(f:gen3ClassicModel()) == true, tag .. "...which draws")
        local circles = 0
        for _, call in ipairs(drawnCalls) do if call[1] == "circle" then circles = circles + 1 end end
        check(circles > 0, tag .. "...a bait in the air")
        local swayed = stepUntil(f, function()
          local foe = f:gen3ClassicModel().foe
          return foe and (foe.dx or 0) ~= 0
        end, 80)
        check(swayed, tag .. "the foe's pic sways on the page (gen3LookSeat)")
      else
        local vfx, sway = fxOf(f, "vfx", "foe"), fxOf(f, "sway", "foe")
        eq(vfx and vfx.fromTrainer, "ally", tag .. "the bait leaves our trainer's figure (fromTrainer)")
        eq(vfx and vfx.palette, "BAIT", tag .. "...in the bait's look")
        check(sway and sway.wait == 0.40, tag .. "...and the foe sways once it has landed (wait)")
        eq(f.battlefieldBubbles, nil, tag .. "nobody shouts it")
      end
      drain()
      eq(f.anim, nil, tag .. "the clip ends")
      -- ROCK: a Safari fight's ROCK_THROW is the clip, never the move.
      f:runCommand("ROCK")
      eq(sent[#sent] and sent[#sent].throw, "rock", tag .. "ROCK files throw = rock")
      n0 = #f.lines
      ev({ t = "anim", slot = 0, side = "a", target = 3, text = "ROCK_THROW" })
      check(f.lines[n0 + 1] and f.lines[n0 + 1].general3 == true,
            tag .. "ROCK_THROW is the general clip in the Safari Zone")
      -- FireRed's reaction: eating nods.
      n0 = #f.lines
      ev({ t = "anim", slot = 3, side = "b", text = "SAFARI_REACTION", amount = 2 })
      local eat = f.lines[n0 + 1]
      check(stepUntil(f, function() return f.anim == eat end), tag .. "the reaction plays")
      if classic then
        check(recOf(f, "nod", "foe") ~= nil, tag .. "eating nods the foe (SAFARI_REACTION 2)")
        check(stepUntil(f, function()
          local foe = f:gen3ClassicModel().foe
          return foe and (foe.dy or 0) ~= 0
        end, 60), tag .. "...on its pic")
      else
        check(fxOf(f, "nod", "foe") ~= nil, tag .. "eating nods the foe (SAFARI_REACTION 2)")
      end
      ev({ t = "turn" })
      drain()
      -- RUN: always the plain run.
      f:runCommand("RUN")
      eq(sent[#sent] and sent[#sent].action, "run", tag .. "RUN files { action = run }")
      eq(f.drawFailed, nil, tag .. "nothing failed to draw")
    end

    -- Without the text pack: the cart's words in this file's spelling.
    do
      safariPack = false
      newGame()
      SESSION.party = { monOf(4, 20) }
      local wild = assert(Sheet3.mon(SESSION, monOf(16, 5), 0, { wild = true }))
      local f = screen3("wild", { safari = { family = "frlg", balls = 3 } }, { wildParty = { wild } })
      eq(f:commandPrompt(), "What will ANN\nthrow?", "safari: the prompt's fallback (pret's words)")
      local g = screen3("wild", { safari = { family = "rse", balls = 3 } }, { wildParty = { wild } })
      eq(g:commandPrompt(), "What will\nANN do?", "safari: Emerald's fallback (gText_WhatWillPkmnDo2)")
      safariPack = true
      -- A kind's own grid and prompt still win.
      local own = screen3("wild", { safari = { family = "frlg", balls = 3 }, commands = { "BALL", "RUN" },
                                    prompt = "MINE" }, { wildParty = { wild } })
      eq(table.concat(own:commandList(), ","), "BALL,RUN", "safari: a kind's `commands` win")
      eq(own:commandPrompt(), "MINE", "safari: ...and its `prompt`")
      -- The options are read only as given.
      local bad = Mediated.new({ game = GAME, battle = "x", mode = "wild",
                                 safari = { family = "dppt", balls = 9 } })
      eq(bad.safari, nil, "safari: an unknown family is no Safari")
      local capped = Mediated.new({ game = GAME, battle = "x", mode = "wild",
                                    safari = { family = "frlg", balls = 999 } })
      eq(capped:safariBalls3(), 255, "safari: the count is a u8 (gNumSafariBalls)")
      -- The ClassicBattle words, pure.
      eq(table.concat(ClassicBattle.gen3SafariLabels("rse"), ","), "BALL,POKéBLOCK,GO NEAR,RUN",
         "safari: Emerald's four words without the cart's text")
      local title, left = ClassicBattle.gen3SafariWords(7, "frlg")
      eq(title, "SAFARI BALLS", "safari: the box's title")
      eq(left, "Left: 7", "safari: ...and its count, left-aligned")
    end

    -- ---- (j) Emerald's grid and the POKéBLOCK case
    do
      newGame()
      SESSION.party = { monOf(4, 20) }
      local wild = assert(Sheet3.mon(SESSION, monOf(16, 5), 0, { wild = true }))
      -- The engine's case stood in: Pokeblock.openCase is the door (never
      -- chooseForBattle, which clears the block itself), the case module is
      -- what a turn answered for us closes.
      local shown, resets = {}, 0
      local FakeCase = { opened = false }
      function FakeCase.isOpen() return FakeCase.opened end
      function FakeCase.reset() resets = resets + 1; FakeCase.opened = false end
      local FakePokeblock = { CASE = { FIELD = 0, BATTLE = 1, FEEDER = 2, GIVE = 3 } }
      function FakePokeblock.openCase(session, opts)
        opts.session = session
        shown[#shown + 1] = opts
        FakeCase.opened = true
        return true
      end
      function FakePokeblock.chooseForBattle() error("chooseForBattle clears the block itself") end
      stub("src.ui.game3.rse.pokeblock_case", FakeCase)
      stub("src.core.game3.rse.pokeblock", FakePokeblock)
      local f, ev, sent, drain = screen3("wild", { safari = { family = "rse", balls = 30 } },
        { wildParty = { wild } })
      ev({ t = "send", slot = 3, side = "b", text = "PIDGEY", speciesId = "16", hp = 20, maxHp = 20 })
      ev({ t = "turn" })
      drain()
      eq(table.concat(f:commandList(), ","), "BALL,POKEBLOCK,NEAR,RUN", "rse: Emerald's grid")
      local labels = {}
      for i, item in ipairs(f:bandCommandItems()) do labels[i] = item.label end
      eq(table.concat(labels, ","), "BALL,POKéBLOCK,GO NEAR,RUN", "rse: ...in its words")
      eq(f:commandPrompt(), "WHAT WILL\nANN DO?", "rse: gText_WhatWillPkmnDo2, the player named")
      f:runCommand("NEAR")
      eq(sent[#sent] and sent[#sent].throw, "near", "rse: GO NEAR files throw = near")
      ev({ t = "chose", slot = 0, side = "a", text = "ANN" })
      ev({ t = "msg", text = "ANN crept closer to PIDGEY!" })
      ev({ t = "turn" })
      drain()
      local filed = #sent
      check(f:runCommand("POKEBLOCK") == nil, "rse: POKéBLOCK runs its handler")
      eq(#shown, 1, "rse: the engine's own case opens")
      eq(shown[1] and shown[1].caseId, 1, "rse: ...as the battle case (USE / CANCEL)")
      eq(shown[1] and shown[1].session, SESSION, "rse: ...on the player's own blocks")
      eq(f.phase, "pokeblock", "rse: the screen waits under it")
      eq(#sent, filed, "rse: nothing is filed yet")
      local under = f:gen3ClassicModel()
      check(under.commands ~= nil, "rse: the grid stays drawn under the case")
      press(f, "a")
      eq(#sent, filed, "rse: the buttons are the case's")
      eq(f.phase, "pokeblock", "rse: ...and the screen does not move")
      -- Closed with nothing used: back to the grid, no turn spent.
      FakeCase.opened = false
      shown[1].onClose(nil)
      eq(f.phase, "choose", "rse: a case closed with no block is the action menu again")
      eq(#sent, filed, "rse: ...and files nothing")
      -- A block used: its case slot, 1-based, and still in the case.
      f:runCommand("POKEBLOCK")
      local used = shown[2].onUse(2)
      eq(used, 2, "rse: USE answers the case's index, and takes nothing out")
      FakeCase.opened = false
      shown[2].onClose(used)
      eq(sent[#sent] and sent[#sent].action, "safari", "rse: a block files a Safari choice")
      eq(sent[#sent] and sent[#sent].throw, "block", "rse: ...throw = block")
      eq(sent[#sent] and sent[#sent].block, 3, "rse: ...block = the case slot + 1 (Wire POKEBLOCK3_MAX)")
      eq(f.phase, "play", "rse: ...and the turn is answered")
      ev({ t = "chose", slot = 0, side = "a", text = "ANN" })
      ev({ t = "msg", text = "ANN threw a POKeBLOCK at the PIDGEY!" })
      local n0 = #f.lines
      ev({ t = "anim", slot = 0, side = "a", target = 3, text = "POKEBLOCK_THROW" })
      check(f.lines[n0 + 1] and f.lines[n0 + 1].general3 == true, "rse: POKEBLOCK_THROW is a general clip")
      ev({ t = "turn" })
      drain()
      -- The referee answering the turn while the case is up closes it.
      f:runCommand("POKEBLOCK")
      ev({ t = "chose", slot = 0, side = "a", text = "ANN" })
      eq(resets, 1, "rse: a turn answered for us closes the case")
      eq(f.phase, "play", "rse: ...and the screen waits as for any answered turn")
      local late = #sent
      shown[3].onClose(0)
      eq(#sent, late, "rse: ...a late close files nothing")
      -- No case to open: said, and the grid stays.
      ev({ t = "turn" })
      drain()
      local savedEngine = Gen3.engine
      Gen3.engine = function(name)
        if name == "src.core.game3.rse.pokeblock" then return nil end
        return savedEngine(name)
      end
      local warned = #warns
      f.pokeblockWarned = nil
      f:runCommand("POKEBLOCK")
      Gen3.engine = savedEngine
      eq(f.phase, "choose", "rse, no case: the grid stays")
      eq(#warns, warned + 1, "rse, no case: ...and it is said, with what to do")
      warns[#warns] = nil
      -- The fight ending under the case closes it too.
      f:runCommand("POKEBLOCK")
      f:onOutcome({ battle = "um", outcome = "win", winners = { "wild" }, losers = { "me" }, reason = "run" })
      eq(resets, 2, "rse: the fight's end closes the case")
    end

    -- ---- (k) the real referee's Safari (BattleSim3 `safari`, wave 2 R2)
    do
      newGame()
      SESSION.party = { monOf(4, 20) }
      local wildSheet = assert(Sheet3.mon(SESSION, monOf(16, 5), 0, { wild = true }))
      wildSheet.safariFleeRate = 0
      wildSheet.catchRate = 3
      local battle, ruleset = nil, {}
      local transport = {
        isReady = function() return true end,
        send = function(_, kind, msg)
          if type(msg) == "table" and msg.action then
            local c = {}
            for k, v in pairs(msg) do if k ~= "battle" then c[k] = v end end
            return battle and battle:submitChoice("me", c) or false
          elseif type(msg) == "table" and (msg.typeTable or msg.movePool) then
            ruleset = msg
          end
        end,
      }
      local f = Mediated.new({ transport = transport, game = GAME, battle = "sf", role = "host",
                               mode = "wild", wildParty = { wildSheet }, classicUi = true,
                               safari = { family = "frlg", balls = 2 } })
      f:start(GAME)
      battle = assert(Sim.Turn.create({
        id = "sf", mode = "wild", seed = 11, typeTable = ruleset.typeTable, movePool = ruleset.movePool,
        safari = { family = "frlg", balls = 2 },
        sides = { a = { { playerId = "me", name = "ANN" } },
                  b = { { playerId = "wild", name = "WILD", mons = { wildSheet } } } },
      }))
      f:onReady({ battle = "sf", mode = "wild", sides = { a = { "me" }, b = { "wild" } } })
      local function pump()
        battle:tick(0)
        for _, e in ipairs(battle:drainEvents()) do f:onEvent(e) end
        local out = battle:outcome()
        if out and not f.finished then
          f:onOutcome({ battle = "sf", outcome = out.outcome, winners = out.winners,
                        losers = out.losers, reason = out.reason, caught = out.caught,
                        given = out.given })
        end
        for _ = 1, 400 do
          f:update(2.0)
          if f.phase == "choose" or (f.phase == "over" and #f.lines == 0 and not f.shown) then break end
        end
      end
      pump()
      eq(f.phase, "choose", "referee safari: the grid opens")
      eq(f:safariBalls3(), 2, "referee safari: two balls")
      f:runCommand("BALL")
      pump()
      eq(f:safariBalls3(), 1, "referee safari: one left after the first throw (`item` amount)")
      eq(f.finished, false, "referee safari: the fight goes on")
      f:runCommand("BALL")
      pump()
      eq(f:safariBalls3(), 0, "referee safari: none left")
      check(f.finished, "referee safari: out of balls ends it")
      check(said(f, "out of SAFARI BALLS"), "referee safari: the announcer's line")
      eq(#SESSION.party, 1, "referee safari: nothing was caught")
    end

    -- ---- (l) the general looks on the single screen (twin of CoopBattle's)
    for _, classic in ipairs({ true, false }) do
      local tag = classic and "general (classic): " or "general (arena): "
      newGame()
      SESSION.party = { monOf(4, 30) }
      local maro = assert(Sheet3.mon(SESSION, monOf(16, 30), 0, { wild = true }))
      local f, ev, sent, drain = screen3("wild", { ghost = "veiled" },
        { wildParty = { maro }, classicUi = classic })
      ev({ t = "send", slot = 0, side = "a", text = "CHARMANDER", speciesId = "4", hp = 60, maxHp = 60, mon = 0 })
      ev({ t = "send", slot = 3, side = "b", text = "PIDGEY", speciesId = "16", hp = 40, maxHp = 40, level = 30 })
      ev({ t = "turn" })
      drain()
      local n0 = #f.lines
      ev({ t = "anim", slot = 0, side = "a", text = "MON_SCARED" })
      local scared = f.lines[n0 + 1]
      check(scared and scared.general3 == true and scared.quiet == true, tag .. "MON_SCARED is general and quiet")
      check(stepUntil(f, function() return f.anim == scared end), tag .. "...and plays")
      eq(f.animHold, 0.70, tag .. "...held for its longest beat (the sweat)")
      if classic then
        check(recOf(f, "tremble", "ally") ~= nil, tag .. "our monster trembles (PLAYER_LEFT)")
        check(recOf(f, "flash", "ally") ~= nil, tag .. "...and lights up where the arena sprays")
        local moved, lit = false, false
        stepUntil(f, function()
          local ally = f:gen3ClassicModel().ally
          if ally and (ally.dx or 0) ~= 0 then moved = true end
          if ally and (ally.flash or 0) > 0 then lit = true end
          return moved and lit
        end, 40)
        check(moved and lit, tag .. "...on its pic")
      else
        check(fxOf(f, "tremble", "ally") ~= nil, tag .. "our monster trembles (PLAYER_LEFT)")
        local sweat = fxOf(f, "vfx", "ally")
        eq(sweat and sweat.palette, "FEAR", tag .. "...in a cold sweat")
      end
      drain()
      -- GHOST_GET_OUT: the GHOST's beat on theirs, the shiver on ours.
      n0 = #f.lines
      ev({ t = "anim", slot = 3, side = "b", text = "GHOST_GET_OUT" })
      local out = f.lines[n0 + 1]
      check(stepUntil(f, function() return f.anim == out end), tag .. "GHOST_GET_OUT plays")
      if classic then
        check(recOf(f, "flash", "foe") ~= nil and recOf(f, "tremble", "ally") ~= nil,
              tag .. "...on the GHOST and on ours")
      else
        check(fxOf(f, "vfx", "foe") ~= nil and fxOf(f, "tremble", "ally") ~= nil,
              tag .. "...on the GHOST and on ours")
        eq(fxOf(f, "tremble", "ally").wait, 0.35, tag .. "...the shiver after its rest")
      end
      drain()
      -- ROCK THROW off the Safari is the move.
      n0 = #f.lines
      ev({ t = "anim", slot = 3, side = "b", text = "ROCK_THROW" })
      local rock = f.lines[n0 + 1]
      check(rock and rock.general3 == nil and rock.quiet == nil, tag .. "ROCK_THROW off the Safari is the move")
      drain()
      -- A SUBSTITUTE on the battler silences the clip (Vfx.subSilences3).
      if type(Vfx.subSilences3) == "function" then
        f.slots[0].substitute = true
        n0 = #f.lines
        ev({ t = "anim", slot = 0, side = "a", text = "MON_SCARED" })
        local behind = f.lines[n0 + 1]
        check(stepUntil(f, function() return f.lines[1] ~= behind and f.anim ~= behind end, 10),
              tag .. "behind a SUBSTITUTE the clip is skipped")
        eq(f.anim, nil, tag .. "...and holds nothing")
        f.slots[0].substitute = nil
      end
      eq(f.drawFailed, nil, tag .. "nothing failed to draw")
    end
    eq(Mediated.GENERAL_ANIMS3, Vfx.GENERAL_ANIMS3, "general: the screen's list is the catalogue's")
    do
      -- The VFX keys reach the arena: a throw from the trainer, a motion's rest.
      newGame()
      SESSION.party = { monOf(4, 30) }
      local wild = assert(Sheet3.mon(SESSION, monOf(16, 30), 0, { wild = true }))
      local f = screen3("wild", nil, { wildParty = { wild }, classicUi = false })
      local fx = f:emitVfx({ style = "rock", palette = "BAIT", delivery = "projectile" }, 3, nil, "ally")
      eq(fx and fx.fromTrainer, "ally", "general: emitVfx carries fromTrainer")
      local motion = f:emitFx("sway", 3, nil, nil, { wait = 0.4 })
      eq(motion and motion.wait, 0.4, "general: emitFx carries a motion's wait")
      eq(motion and motion.duration, Battlefield.FX_MOTION_SPAN.sway, "general: ...on the shared motion clock")
      -- ClassicBattle's pure helpers.
      local dx0 = ClassicBattle.gen3MotionOffset("sway", 0.125, nil, false)
      local dx1 = ClassicBattle.gen3MotionOffset("sway", 0.125, nil, true)
      check(dx0 > 0 and dx1 < 0, "general: a sway leans toward the midline first, either side")
      local rx, ry = ClassicBattle.gen3MotionOffset("sway", 0.1, 0.5, false)
      eq(rx, 0, "general: a motion at rest before its wait is over")
      local _, dy = ClassicBattle.gen3MotionOffset("nod", 0.25, nil, true)
      check(dy > 0, "general: a nod dips")
      local sx, sy, flash = ClassicBattle.gen3LookSeat({ { kind = "flash", side = "foe", t = 0.5 } }, "foe")
      check(sx == 0 and sy == 0 and flash > 0.5, "general: a flash beat lights the pic")
      local _, _, none = ClassicBattle.gen3LookSeat({ { kind = "flash", side = "foe", t = 0.5 } }, "ally")
      eq(none, 0, "general: ...the side it is on only")
      local x0, y0 = ClassicBattle.gen3ThrowAt({ t = 0, to = "foe" })
      local xm, ym = ClassicBattle.gen3ThrowAt({ t = 0.25, to = "foe" })
      local x1, _, r1, a1 = ClassicBattle.gen3ThrowAt({ t = 0.75, to = "foe" })
      local G3 = ClassicBattle.G3
      eq(x0, G3.ALLY_PIC_X, "general: a throw leaves our side")
      check(xm > x0 and ym < y0, "general: ...arcs up and over")
      eq(x1, G3.FOE_PIC_X, "general: ...and bursts on the foe")
      check(r1 > ClassicBattle.GEN3_THROW_R and a1 < 1, "general: ...the burst growing as it fades")
    end

    -- ---- (m) a forced catch gives nothing (`given = false`, BattleSim3 `catch`)
    do
      newGame()
      SESSION.party = { monOf(4, 20) }
      local wild = assert(Sheet3.mon(SESSION, monOf(16, 5), 0, { wild = true }))
      local captures = #FakeDex.captures
      local f, ev, sent, drain = screen3("wild", { noOwnBattler = true },
        { wildParty = { wild }, wildCatchMon = monOf(16, 5) })
      ev({ t = "send", slot = 3, side = "b", text = "PIDGEY", speciesId = "16", hp = 20, maxHp = 20 })
      ev({ t = "msg", text = "Gotcha! PIDGEY was caught!" })
      f:onOutcome({ battle = "um", outcome = "win", winners = { "me" }, losers = { "wild" },
                    reason = "catch", caught = wild, given = false })
      drain()
      check(f.finished, "forced catch: the fight ends caught")
      eq(#SESSION.party, 1, "forced catch: nothing joins the party")
      eq(#FakeDex.captures, captures, "forced catch: ...no dex catch")
      eq(f.owedNickname, nil, "forced catch: ...no nickname owed")
      eq(said(f, "added to the party"), nil, "forced catch: ...and nothing said about it")
      -- The ordinary catch (no `given`) is still the thrower's.
      newGame()
      SESSION.party = { monOf(4, 20) }
      local g, evg, _, draing = screen3("wild", nil, { wildParty = { wild }, wildCatchMon = monOf(16, 5) })
      evg({ t = "send", slot = 3, side = "b", text = "PIDGEY", speciesId = "16", hp = 20, maxHp = 20 })
      g:onOutcome({ battle = "um", outcome = "win", winners = { "me" }, losers = { "wild" },
                    reason = "catch", caught = wild })
      draing()
      eq(#SESSION.party, 2, "an ordinary catch joins the party as ever")
    end

    -- ---- (n) the trainer back in for its end speech (BattleScript_LocalTrainerBattleWon)
    for _, classic in ipairs({ true, false }) do
      local tag = classic and "slide-in (classic): " or "slide-in (arena): "
      newGame()
      SESSION.party = { monOf(4, 20) }
      local trainer = { trainerPic = 7, className = "LASS", trainerName = "AMY",
                        defeatText = "AMY: OH, I LOST!", victoryText = "AMY: I WON!" }
      local f, ev, sent, drain = screen3("coop_npc", nil, { trainer = trainer, classicUi = classic })
      ev({ t = "send", slot = 0, side = "a", text = "CHARMANDER", speciesId = "4", hp = 50, maxHp = 50, mon = 0 })
      ev({ t = "send", slot = 3, side = "b", text = "PIDGEY", speciesId = "16", hp = 30, maxHp = 30 })
      ev({ t = "turn" })
      drain()
      f:say("ANN defeated\nLASS AMY!")
      local before = #f.lines
      f:say(trainer.defeatText)
      local row = f.lines[before + 1]
      check(type(row) == "table" and row.stateRow == "trainer3", tag .. "the speech brings the trainer in first")
      eq(f.lines[before + 2], trainer.defeatText, tag .. "...then its first page")
      local n0 = #f.lines
      f:say("ANN got ¥100\nfor winning!")
      eq(#f.lines, n0 + 1, tag .. "an ordinary line brings nobody in")
      check(stepUntil(f, function() return f.endTrainer3 == true end), tag .. "the trainer comes in")
      if classic then
        local m = f:gen3ClassicModel()
        eq(m.trainer and m.trainer.x, Mediated.END_PIC_X3, tag .. "...at the cart's stop (176 + 32)")
        eq(m.trainer and m.trainer.dx, Mediated.TRAINER_SLIDE_PX3, tag .. "...from 96 further right")
        eq(m.showTrainer, true, tag .. "...in the foe's place")
        eq(f.anim, row, tag .. "the queue waits for the slide (waitstate)")
        eq(f.shown, nil, tag .. "...the speech not yet up")
        for _ = 1, 10 do f:update(1 / 60) end
        eq(f:gen3ClassicModel().trainer.dx, Mediated.TRAINER_SLIDE_PX3 - 10 * Mediated.TRAINER_SLIDE_STEP3,
           tag .. "...sliding 2 px a frame (SpriteCB_TrainerSlideIn)")
        local savedPic = Battlefield.gen3TrainerPic
        Battlefield.gen3TrainerPic = function() return fakeImage("lass") end
        check(classicDraw(f:gen3ClassicModel()) == true, tag .. "the page draws it")
        Battlefield.gen3TrainerPic = savedPic
        local at = nil
        for _, call in ipairs(drawnCalls) do
          if call[1] == "draw" and type(call[2]) == "table" and call[2].tag == "lass" then at = call[3] end
        end
        eq(at, Mediated.END_PIC_X3 + 76 - 32, tag .. "...where it is in its slide")
        check(stepUntil(f, function() return f.shown == trainer.defeatText end, 120),
              tag .. "the speech once it has arrived")
        eq(f:gen3ClassicModel().trainer.dx, 0, tag .. "...standing at its stop")
      else
        eq(f.anim, nil, tag .. "the arena's trainer never left: no wait")
      end
      drain()
      eq(f.endTrainer3, true, tag .. "the trainer stays for the rest of the ending")
      -- Its win text over a loss brings it in the same way.
      local g = screen3("coop_npc", nil, { trainer = trainer, classicUi = classic })
      local b2 = #g.lines
      g:say(trainer.victoryText)
      check(type(g.lines[b2 + 1]) == "table" and g.lines[b2 + 1].stateRow == "trainer3",
            tag .. "the win text over a loss too (BattleScript_RivalBattleLost)")
    end
    do
      -- A wild fight has no trainer to bring in.
      newGame()
      SESSION.party = { monOf(4, 20) }
      local wild = assert(Sheet3.mon(SESSION, monOf(16, 5), 0, { wild = true }))
      local f = screen3("wild", nil, { wildParty = { wild }, trainer = { defeatText = "X" } })
      local before = #f.lines
      f:say("X")
      eq(f.lines[before + 1], "X", "slide-in: never in a wild fight")
    end

    -- ---- (o) a bag of the fight's own (screen option `bag`, the Battle Pyramid's)
    do
      newGame()
      SESSION.party = { monOf(4, 20) }
      local pyramid = { { id = 13, count = 3, name = "POTION" } }
      local trainer = { trainerPic = 7, className = "LASS", trainerName = "AMY" }
      local f, ev, sent, drain, uploads = screen3("coop_npc", { bag = pyramid }, { trainer = trainer })
      local ours = nil
      for _, u in ipairs(uploads) do if u.mons and u.side == nil then ours = u end end
      local bag = ours and ours.bag or {}
      eq(#bag, 1, "bag: the fight's own bag goes up")
      eq(bag[1] and bag[1].count, 3, "bag: ...its counts, not the session's (which has none)")
      eq(f.bagSheet[13], 3, "bag: the sheet the menu reads")
      ev({ t = "send", slot = 0, side = "a", text = "CHARMANDER", speciesId = "4", hp = 50, maxHp = 50, mon = 0 })
      ev({ t = "send", slot = 3, side = "b", text = "PIDGEY", speciesId = "16", hp = 30, maxHp = 30 })
      ev({ t = "turn" })
      drain()
      f:runCommand("ITEM")
      local rows = f:usableItems()
      eq(rows[1] and rows[1].id, 13, "bag: BAG lists the fight's bag")
      eq(rows[1] and rows[1].count, 3, "bag: ...with its counts")
      f.pendingItem = 13
      ev({ t = "item", slot = 0, side = "a", text = "13" })
      eq(f.bagSheet[13], 2, "bag: a use spends from it, whatever the session's pockets hold")
      eq(pyramid[1].count, 3, "bag: the caller's table is never written")
      -- Without the option: the session's pockets, as ever.
      FakeBag.add(SESSION.bag, 13, 1)
      local g = screen3("coop_npc", nil, { trainer = trainer })
      eq(g.bagSheet[13], 1, "bag: without it, the session's own")
    end

    -- ---- (p) the Frontier's victory jingle (screen option `victorySong`)
    do
      newGame()
      SESSION.party = { monOf(4, 20) }
      local trainer = { trainerPic = 7, className = "LASS", trainerName = "AMY" }
      local function jingle(opts)
        local f = screen3("coop_npc", opts, { trainer = trainer })
        audioCalls = {}
        f.result = "win"
        f:playVictoryMusic()
        local played = nil
        for _, call in ipairs(audioCalls) do if call[1] == "playSong" then played = call[2] end end
        return played, f
      end
      eq(jingle({ victorySong = 413 }), 413, "victory: the kind's jingle is what plays")
      eq(jingle({ victorySong = "MUS_VICTORY_GYM_LEADER" }), 7, "victory: ...named, through the cart's song table")
      check(jingle(nil) ~= 413, "victory: without one, the trainer's own as ever")
      local saved = FakeAudio.playSong
      local refused = false
      FakeAudio.playSong = function(id)
        if id == 413 and not refused then refused = true; return false end
        return saved(id)
      end
      local warned = #warns
      local played = jingle({ victorySong = 413 })
      FakeAudio.playSong = saved
      check(played ~= nil, "victory: a jingle the cart refused falls back to the ordinary one")
      eq(#warns, warned + 1, "victory: ...said once, with what to do")
      warns[#warns] = nil
    end

    -- ===============================================================
    -- Wave 4 (UM4): the tutorials, the Battle Palace, the Battle Arena's
    -- judgment, the action menu's cursor, the ball thrown with the trainer
    -- ===============================================================

    -- One frame at a time, `n` of them.
    local function frames(f, n)
      for _ = 1, n do f:update(1 / 60) end
    end
    -- Frames until `pred` holds; how many it took (nil if it never did).
    local function framesUntil(f, pred, cap)
      for i = 1, cap or 2000 do
        if pred() then return i - 1 end
        f:update(1 / 60)
      end
      return pred() and (cap or 2000) or nil
    end
    -- A back-pic strip as the engine's TrainerPic.back hands one over.
    local function backStrip(tag, n)
      local img = fakeImage(tag)
      img.h = 64 * (n or 4)
      return { image = img, w = 64, h = img.h, frames = n or 4 }
    end
    -- Battlefield.gen3TrainerBackPic stood in: a profile key or an index.
    local savedBackPic = Battlefield.gen3TrainerBackPic
    local backAsked = {}
    Battlefield.gen3TrainerBackPic = function(which)
      backAsked[#backAsked + 1] = which
      if which == "wally" or which == 6 then return backStrip("wallyback", 4) end
      if which == 5 then return backStrip("oldmanback", 4) end
      if which == 4 then return backStrip("dudeback", 4) end
      return nil
    end
    -- The cart's TRAINER_BACK_PIC_* numbers, through the engine's constants
    -- table (synthetic, in the cart's order).
    local BACK_IDS = { TRAINER_BACK_PIC_OLD_MAN = 5, TRAINER_BACK_PIC_POKEDUDE = 4,
                       TRAINER_BACK_PIC_WALLY = 6 }
    -- (The module Gen3.engine already holds is the one asked: its `of` is
    -- swapped for this block and put back at its end.)
    local Consts4 = Gen3.engine("src.core.game3.constants")
    local savedOf4 = Consts4.of
    Consts4.of = (function()
      return { song = function() return 7 end,
               id = function(_, kind, name)
                 if kind == "trainer_classes" then return BACK_IDS[name] end
                 if kind == "event_objects" and name == "OBJ_EVENT_GFX_WALLY" then return 135 end
                 if kind == "event_objects" and name == "OBJ_EVENT_GFX_OLD_MAN_1" then return 32 end
                 return nil
               end,
               name = function() return nil end }
    end)
    local textBefore4 = Gen3.battleText
    local pack4 = true
    local returnFill = nil
    -- A line as the screen shows it, its row breaks read as spaces.
    local function flat(text) return (tostring(text or ""):gsub("\n", " ")) end
    -- A text the page drew at exactly this row.
    local function textAtY(exact, y)
      for _, t in ipairs(textDrawn) do
        if tostring(t.text) == exact and t.y == y then return t end
      end
      return nil
    end
    Gen3.battleText = function(id, fill)
      if pack4 then
        if id == "gText_WhatWillOldManDo" then return "WHAT WILL THE\nOLD MAN DO?" end
        if id == "gText_WhatWillWallyDo" then return "WHAT WILL\nWALLY DO?" end
        if id == "gText_WhatWillPkmnDo" then
          return ("WHAT WILL\n%s DO?"):format(tostring(fill and fill.active and fill.active.name))
        end
        if id == "STRINGID_RETURNMON" then
          returnFill = fill
          return ("%s, THAT'S ENOUGH!\nCOME BACK!"):format(tostring(fill and fill.buff1))
        end
        if id == "STRINGID_YOUTHROWABALLNOWRIGHT" then return "YOU THROW A BALL NOW, RIGHT?" end
        if id == "STRINGID_PKMNINCAPABLEOFPOWER" then
          local who = fill and fill.atk
          return ((who and who.side == "player") and "" or "FOE ") .. tostring(who and who.name)
            .. " APPEARS INCAPABLE\nOF USING ITS POWER!"
        end
        if id == "STRINGID_GLINTAPPEARSINEYE" then
          return "A GLINT APPEARS IN\n" .. tostring(fill and fill.scrActive and fill.scrActive.name) .. "'S EYES!"
        end
        if id == "STRINGID_PKMNEAGERFORMORE" then
          return tostring(fill and fill.scrActive and fill.scrActive.name) .. " IS EAGER FOR MORE!"
        end
        if id == "STRINGID_DEFEATEDOPPONENTBYREFEREE" then
          return ("%s DEFEATED THE OPPONENT\n%s IN A REFEREE'S DECISION!"):format(
            tostring(fill and fill.playerMon1), tostring(fill and fill.opponentMon1))
        end
        if id == "STRINGID_LOSTTOOPPONENTBYREFEREE" then
          return ("%s LOST TO THE OPPONENT\n%s IN A REFEREE'S DECISION!"):format(
            tostring(fill and fill.playerMon1), tostring(fill and fill.opponentMon1))
        end
        if id == "STRINGID_TIEDOPPONENTBYREFEREE" then
          return ("%s TIED THE OPPONENT\n%s IN A REFEREE'S DECISION!"):format(
            tostring(fill and fill.playerMon1), tostring(fill and fill.opponentMon1))
        end
      end
      return textBefore4(id, fill)
    end
    -- The tutorial's own bag: POTION and POKé BALL (pret InitOldManBag).
    local TUT_BAG = { { id = 13, count = 1, name = "POTION" }, { id = 4, count = 1, name = "POKé BALL" } }
    local ballRow
    do
      local probe = Mediated.new({ game = GAME, battle = "probe", mode = "wild", bag = TUT_BAG })
      probe.bagSheet = Mediated.bagCounts(probe.bagEntries)
      for i, item in ipairs(probe:usableItems()) do if item.id == 4 then ballRow = i end end
    end
    check(ballRow ~= nil, "tutorial: the fixture's POKé BALL is a bag row")

    -- ---- (q) the tutorials (screen option `tutorial`, `autoplay3`)
    -- q1. the old man: no battler, his back pic and prompt, no input, and
    --     the BALL walked to at the cart's pace.
    for _, classic in ipairs({ true, false }) do
      local tag = classic and "old man (classic): " or "old man (arena): "
      newGame()
      SESSION.party = { monOf(4, 20) }
      FakeBag.add(SESSION.bag, 4, 2)
      local wild = assert(Sheet3.mon(SESSION, monOf(16, 5), 0, { wild = true }))
      local f, ev, sent, drain = screen3("wild", {
        tutorial = { kind = "oldMan", name = "OLD MAN" }, bag = TUT_BAG,
      }, { wildParty = { wild }, classicUi = classic })
      eq(f.tutorial and f.tutorial.kind, "oldMan", tag .. "the option is read")
      eq(f.noOwnBattler, true, tag .. "the old man fields nothing (implied)")
      ev({ t = "send", slot = 3, side = "b", text = "PIDGEY", speciesId = "16", hp = 20, maxHp = 20, level = 5 })
      ev({ t = "turn" })
      drain()
      eq(f.phase, "choose", tag .. "the action menu opens")
      eq(f:commandPrompt(), "WHAT WILL THE\nOLD MAN DO?", tag .. "gText_WhatWillOldManDo, off the cart")
      local m = f:gen3ClassicModel()
      eq(m.ally, nil, tag .. "no plate of ours")
      check(type(m.playerBack.pic) == "table" and m.playerBack.pic.image.tag == "oldmanback",
            tag .. "the old man's back pic (TRAINER_BACK_PIC_OLD_MAN, numbered by the cart)")
      if classic then
        check(classicDraw(f:gen3ClassicModel()) == true, tag .. "the page draws")
        eq(backPics, 0, tag .. "...not the player's back pic")
        local drawnOld = false
        for _, call in ipairs(drawnCalls) do
          if call[1] == "draw" and type(call[2]) == "table" and call[2].tag == "oldmanback" then
            drawnOld = call[4] == ClassicBattle.G3.PLAYER_BACK_X - 32 and call[5] == ClassicBattle.G3.PLAYER_BACK_Y - 32
          end
        end
        check(drawnOld, tag .. "...his, in the player's place")
      else
        local ctx = f:battlefieldCtx()
        eq(ctx.allyHumans[1].spriteId, "OBJ_EVENT_GFX_OLD_MAN_1", tag .. "the arena stands him on our edge")
        eq(ctx.allyHumans[1].name, "OLD MAN", tag .. "...named")
        eq(ctx.allyHumans[1].version, nil, tag .. "...by this cart's own graphic")
      end
      -- No player input.
      press(f, "right")
      press(f, "a")
      eq(f.commandIndex, 1, tag .. "the player's buttons move nothing")
      eq(#sent, 0, tag .. "...and file nothing")
      -- The turn, scripted.
      local filedWith = nil
      check(f:autoplay3({ action = "item", item = 4 }, function(ok, c) filedWith = { ok = ok, c = c } end),
            tag .. "autoplay3 is booked")
      check(not f:autoplay3({ action = "run" }), tag .. "a second one while it runs is refused")
      frames(f, 63)
      eq(f.commandIndex, 1, tag .. "63 frames: the cursor still on FIGHT")
      frames(f, 1)
      eq(f.commandIndex, 2, tag .. "64 frames: the cursor on BAG (SimulateInputChooseAction)")
      eq(f.phase, "choose", tag .. "...the menu still up")
      frames(f, 63)
      eq(f.phase, "choose", tag .. "127: not pressed yet")
      frames(f, 1)
      eq(f.phase, "item", tag .. "128: the bag opens")
      eq(f.itemIndex, 1, tag .. "...on its first row")
      frames(f, 305)
      eq(f.itemIndex, 1, tag .. "the two pocket turns pass (Task_Bag_OldManTutorial 102, 204)")
      frames(f, 1)
      eq(f.itemIndex, ballRow, tag .. "306: the POKé BALL chosen")
      eq(#sent, 0, tag .. "...not used yet")
      frames(f, 101)
      eq(#sent, 0, tag .. "407: still in the bag")
      frames(f, 1)
      eq(#sent, 1, tag .. "408: USE files it")
      eq(sent[1] and sent[1].action, "item", tag .. "...an item choice")
      eq(sent[1] and sent[1].item, "4", tag .. "...the POKé BALL, as Gen 3 spells an item")
      check(filedWith and filedWith.ok == true, tag .. "onFiled(true) runs")
      eq(f.phase, "play", tag .. "the turn is answered")
      eq(f.commandIndex, 1, tag .. "the old man's cursor was only redrawn: FIGHT again next turn")
      eq(f.autoplay3State, nil, tag .. "the walk is over")
      -- The spend: the tutorial's bag, never the player's pockets.
      ev({ t = "item", slot = 0, side = "a", text = "4" })
      eq(f.bagSheet[4], nil, tag .. "the tutorial's ball is spent")
      eq(FakeBag.get(SESSION.bag, 4), 2, tag .. "...the player's own balls are untouched")
    end

    -- q2. WALLY: FIGHT at 64, the move at 80; the throw turn; the ball.
    for _, classic in ipairs({ true, false }) do
      local tag = classic and "wally (classic): " or "wally (arena): "
      newGame({ version = "emerald" })
      SESSION.party = { monOf(4, 20) }
      local wild = assert(Sheet3.mon(SESSION, monOf(16, 5), 0, { wild = true }))
      local f, ev, sent, drain = screen3("wild", {
        tutorial = { kind = "wally", name = "WALLY", backPic = "wally" }, bag = TUT_BAG,
      }, { wildParty = { wild }, classicUi = classic })
      eq(f.noOwnBattler, nil, tag .. "WALLY has a monster out")
      ev({ t = "send", slot = 0, side = "a", text = "CHARMANDER", speciesId = "4", hp = 40, maxHp = 40, mon = 0 })
      ev({ t = "send", slot = 3, side = "b", text = "PIDGEY", speciesId = "16", hp = 20, maxHp = 20 })
      ev({ t = "turn" })
      drain()
      eq(f:commandPrompt(), "WHAT WILL\nWALLY DO?", tag .. "gText_WhatWillWallyDo")
      if not classic then
        local ctx = f:battlefieldCtx()
        eq(ctx.allyHumans[1].spriteId, "OBJ_EVENT_GFX_WALLY", tag .. "WALLY on our edge")
      end
      f:autoplay3({ action = "fight", move = 1 })
      frames(f, 63)
      eq(f.phase, "choose", tag .. "63 frames: the menu")
      frames(f, 1)
      eq(f.phase, "move", tag .. "64: FIGHT, the cursor never moved (WallyHandleActions)")
      eq(f.commandIndex, 1, tag .. "...on FIGHT")
      frames(f, 79)
      eq(#sent, 0, tag .. "79 frames into the moves: nothing yet")
      frames(f, 1)
      eq(#sent, 1, tag .. "80: the move (wallyMoveFrames)")
      eq(sent[1] and sent[1].action, "fight", tag .. "...a FIGHT")
      eq(sent[1] and sent[1].move, 1, tag .. "...the move asked for")
      -- Turn 3: the throw turn, then the ball.
      ev({ t = "turn" })
      drain()
      eq(f.phase, "choose", tag .. "the throw turn's menu")
      check(f:wallyThrow3(), tag .. "wallyThrow3 is booked")
      f:autoplay3({ action = "item", item = 4 })
      frames(f, 63)
      eq(f.phase, "choose", tag .. "63: the menu, nothing moved")
      eq(#f.lines, 0, tag .. "...nothing said")
      local before = #(f.textLog or {})
      frames(f, 1)
      check(said(f, "CHARMANDER, THAT'S ENOUGH!", before) ~= nil,
            tag .. "64: STRINGID_RETURNMON, his monster named, in the cart's words")
      eq(returnFill and returnFill.hpScale, 0, tag .. "...hpScale 0: no hpthresholds ahead of it")
      eq(returnFill and returnFill.side, "player", tag .. "...the player's side")
      check(framesUntil(f, function() return f.withdrawn3 == true end, 400) ~= nil,
            tag .. "the monster is called back")
      local m = f:gen3ClassicModel()
      eq(m.ally, nil, tag .. "...no plate of ours after it")
      check(type(m.playerBack.pic) == "table" and m.playerBack.pic.image.tag == "wallyback",
            tag .. "WALLY's back pic (the profile's key)")
      check(framesUntil(f, function() return f.tutorialSlide3 == true end, 400) ~= nil,
            tag .. "WALLY steps in")
      if classic then
        eq(f:gen3ClassicModel().playerBack.dx, -Mediated.TUTORIAL_SLIDE_PX3,
           tag .. "...from 96 out on the left (WallyHandleTrainerSlide)")
        frames(f, 10)
        eq(f:gen3ClassicModel().playerBack.dx, -Mediated.TUTORIAL_SLIDE_PX3 + 10 * Mediated.TUTORIAL_SLIDE_STEP3,
           tag .. "...2 px a frame")
        eq(f.anim and f.anim.stateRow, "tutorialSlide3", tag .. "...the queue waiting for him")
      end
      check(framesUntil(f, function()
        return said(f, "YOU THROW A BALL NOW, RIGHT?", before) ~= nil
      end, 600) ~= nil, tag .. "STRINGID_YOUTHROWABALLNOWRIGHT")
      local n = framesUntil(f, function() return f.phase == "choose" end, 600)
      check(n ~= nil, tag .. "the menu again once he has spoken")
      eq(#sent, 1, tag .. "...nothing filed by the throw turn")
      frames(f, 63)
      eq(f.commandIndex, 1, tag .. "63: on FIGHT")
      frames(f, 1)
      eq(f.commandIndex, 2, tag .. "64: BAG (case 4)")
      frames(f, 64)
      eq(f.phase, "item", tag .. "128: the bag (case 5)")
      frames(f, 203)
      eq(f.itemIndex, 1, tag .. "203 in: the pocket turn passed")
      frames(f, 1)
      eq(f.itemIndex, ballRow, tag .. "204: the ball (WALLY_BAG_DELAY * 2)")
      frames(f, 102)
      eq(#sent, 2, tag .. "306: USE")
      eq(sent[2] and sent[2].item, "4", tag .. "...the POKé BALL")
      eq(f.commandIndex, 1, tag .. "WALLY's cursor was only redrawn")
    end

    -- q3. the POKé DUDE: the cursor at half the delay, kept between turns;
    --     his moves, his switch, a medicine on his own monster.
    do
      newGame()
      SESSION.party = { monOf(4, 20), monOf(5, 22) }
      local wild = assert(Sheet3.mon(SESSION, monOf(16, 5), 0, { wild = true }))
      local f, ev, sent, drain = screen3("wild", {
        tutorial = { kind = "pokedude", name = "POKé DUDE" }, bag = TUT_BAG,
      }, { wildParty = { wild } })
      ev({ t = "send", slot = 0, side = "a", text = "CHARMANDER", speciesId = "4", hp = 40, maxHp = 40, mon = 0 })
      ev({ t = "send", slot = 3, side = "b", text = "PIDGEY", speciesId = "16", hp = 20, maxHp = 20 })
      ev({ t = "turn" })
      drain()
      eq(f:commandPrompt(), "WHAT WILL\nCHARMANDER DO?", "pokedude: gText_WhatWillPkmnDo, his monster named")
      check(f:gen3ClassicModel().playerBack.pic.image.tag == "dudeback",
            "pokedude: the POKé DUDE's back pic (TRAINER_BACK_PIC_POKEDUDE)")
      -- SWITCH: the cursor at 32, A at 64; the party at 80 / 160 / 240.
      f:autoplay3({ action = "switch", slot = 1 })
      frames(f, 31)
      eq(f.commandIndex, 1, "pokedude: 31 frames: FIGHT")
      frames(f, 1)
      eq(f.commandIndex, 3, "pokedude: 32: the cursor on POKéMON (delay / 2)")
      frames(f, 32)
      eq(f.phase, "switch", "pokedude: 64: the party")
      frames(f, 80)
      eq(f.switchIndex, 1, "pokedude: 80: the cursor on the one to send")
      frames(f, 159)
      eq(#sent, 0, "pokedude: ...the action window, not yet SHIFT")
      frames(f, 1)
      eq(#sent, 1, "pokedude: 240: SHIFT (Task_PartyMenu_PokedudeStep)")
      eq(sent[1] and sent[1].action, "switch", "pokedude: a switch")
      eq(sent[1] and sent[1].slot, 1, "pokedude: ...to the one asked for")
      eq(f.commandIndex, 3, "pokedude: his cursor stays where he left it (gActionSelectionCursor)")
      ev({ t = "turn" })
      drain()
      eq(f.commandIndex, 3, "pokedude: ...and the menu opens there next turn")
      -- A move: back to FIGHT at 32, the move cursor at 32 more, A at 64.
      f:autoplay3({ action = "fight", move = 1 }, nil, nil)
      frames(f, 32)
      eq(f.commandIndex, 1, "pokedude: 32: FIGHT")
      frames(f, 32)
      eq(f.phase, "move", "pokedude: 64: the moves")
      frames(f, 32)
      eq(f.cursor, 2, "pokedude: 32 in: the cursor on the move (PokedudeSimulateInputChooseMove)")
      frames(f, 32)
      eq(sent[2] and sent[2].move, 1, "pokedude: 64 in: the move filed")
      -- A medicine on his own monster: the bag, then the party at 80.
      ev({ t = "turn" })
      drain()
      local pf = nil
      f:autoplay3({ action = "item", item = 13, slot = 0 }, function(ok) pf = ok end)
      frames(f, 64)
      eq(f.commandIndex, 2, "pokedude: the cursor on BAG")
      frames(f, 32)
      eq(f.phase, "item", "pokedude: the bag")
      frames(f, 102 * 3)
      eq(f.phase, "item_party", "pokedude: USE -> the party (Task_Bag_TeachyTvStatus)")
      frames(f, 80)
      eq(sent[3] and sent[3].item, "13", "pokedude: the POTION filed after 80 (Task_PartyMenuFromBag_PokedudeStep)")
      eq(sent[3] and sent[3].slot, 0, "pokedude: ...on the monster asked for")
      eq(pf, true, "pokedude: onFiled")
      -- The voice-over: his line in Oak's frame over the darkened field.
      local n0 = #f.lines
      check(f:sayTutorial3("DUDE: SPEEDIER GOES FIRST\\pTHEN THE OTHER!"), "pokedude: sayTutorial3 is queued")
      eq(f.lines[n0 + 1] and f.lines[n0 + 1].stateRow, "voiceover", "pokedude: the field darkens first")
      eq(f.lines[n0 + 2], "DUDE: SPEEDIER GOES FIRST", "pokedude: ...the cart's line, paged as printed")
      eq(f.lines[n0 + 3], "THEN THE OTHER!", "pokedude: ...its second page")
      eq(f.lines[#f.lines].stateRow, "voiceover", "pokedude: ...and the field comes back after")
      eq(f.lines[#f.lines].value, false, "pokedude: ...(the row that lifts it)")
      check(stepUntil(f, function() return f.voiceover == true and f.shown ~= nil end),
            "pokedude: the line is up with the field dark")
      check(classicDraw(f:gen3ClassicModel()) == true, "pokedude: the page draws it")
      check(textAt("DUDE: SPEEDIER") ~= nil and textAt("DUDE: SPEEDIER").x ==
            ClassicBattle.G3.VOICEOVER_X, "pokedude: ...in the voice-over window (B_WIN_OAK_OLD_MAN)")
      -- Wave 4b (C-V): each of his pages waits for A, and only A.
      frames(f, 200)
      eq(f.shown, "DUDE: SPEEDIER GOES FIRST", "pokedude: the page waits for A (case 3 JOY_NEW(A_BUTTON))")
      press(f, "b")
      eq(f.shown, "DUDE: SPEEDIER GOES FIRST", "pokedude: ...B does not turn it")
      press(f, "a")
      check(stepUntil(f, function() return f.shown == "THEN THE OTHER!" end, 5),
            "pokedude: A turns to the next page")
      frames(f, 200)
      eq(f.shown, "THEN THE OTHER!", "pokedude: ...which waits for A too")
      eq(f:tutorialIdle3(), false, "pokedude: tutorialIdle3 is false under a voice-over")
      press(f, "a")
      drain()
      eq(f.voiceover, nil, "pokedude: the field back after")
      eq(f:tutorialIdle3(), true, "pokedude: ...and the screen idle again")
      local n1 = #f.lines
      f:sayTutorial3("LOOK AT ITS HP!", { lit = "ally", instant = true })
      eq(f.lines[n1 + 1].lit, "ally", "pokedude: the Status demo's line lights his healthbox")
      check(stepUntil(f, function() return f.voiceover == nil and #f.lines == 0 and f.shown == nil end, 10),
            "pokedude: the headless pace (instant) dismisses it at once")
    end

    -- q4. the headless pace, a refused turn, no tutorial no autoplay input.
    do
      newGame()
      SESSION.party = { monOf(4, 20) }
      local wild = assert(Sheet3.mon(SESSION, monOf(16, 5), 0, { wild = true }))
      local f, ev, sent, drain = screen3("wild", { tutorial = { kind = "oldMan" }, bag = TUT_BAG },
        { wildParty = { wild } })
      ev({ t = "send", slot = 3, side = "b", text = "PIDGEY", speciesId = "16", hp = 20, maxHp = 20 })
      ev({ t = "turn" })
      drain()
      f:autoplay3({ action = "item", item = 4 }, nil, { instant = true })
      frames(f, 1)
      eq(#sent, 1, "instant: the whole walk in one frame (headless suites)")
      eq(f:commandPrompt(), "WHAT WILL THE\nOLD MAN DO?", "instant: the prompt as ever")
      -- Without the text pack: the cart's sentence, named.
      pack4 = false
      local g = screen3("wild", { tutorial = { kind = "wally", name = "WALLY" } }, { wildParty = { wild } })
      eq(g:commandPrompt(), "What will\nWALLY do?", "no text pack: WALLY's prompt in this file's words")
      local h = screen3("wild", { tutorial = { kind = "oldMan" } }, { wildParty = { wild } })
      eq(h:commandPrompt(), "What will the\nold man do?", "no text pack: the old man's")
      pack4 = true
      -- A referee that refuses the turn: said once, onFiled(false), the menu back.
      local r, evr, sentr, drainr = screen3("wild", { tutorial = { kind = "oldMan" }, bag = TUT_BAG },
        { wildParty = { wild }, refuse = true })
      evr({ t = "send", slot = 3, side = "b", text = "PIDGEY", speciesId = "16", hp = 20, maxHp = 20 })
      evr({ t = "turn" })
      drainr()
      local got = "unset"
      local warned = #warns
      r:autoplay3({ action = "run" }, function(ok) got = ok end, { instant = true })
      frames(r, 1)
      eq(got, false, "refused: onFiled(false)")
      eq(r.phase, "choose", "refused: the menu back")
      eq(#warns, warned + 1, "refused: said once, with what to do")
      warns[#warns] = nil
      -- A choice with no action is refused at the door.
      local warned2 = #warns
      check(not r:autoplay3({}), "no action: refused")
      eq(#warns, warned2 + 1, "no action: said")
      warns[#warns] = nil
      -- The referee answering the seat itself drops the walk.
      local s, evs, sents, drains = screen3("wild", { tutorial = { kind = "pokedude" }, bag = TUT_BAG },
        { wildParty = { wild } })
      evs({ t = "send", slot = 3, side = "b", text = "PIDGEY", speciesId = "16", hp = 20, maxHp = 20 })
      evs({ t = "turn" })
      drains()
      local dropped = "unset"
      s:autoplay3({ action = "run" }, function(ok) dropped = ok end)
      frames(s, 10)
      evs({ t = "chose", slot = 0, side = "a", text = "ANN" })
      frames(s, 100)
      eq(dropped, false, "answered: the walk is dropped, onFiled(false)")
      eq(#sents, 0, "answered: ...nothing filed")
    end

    -- q5. the POKé DUDE on the arena: no overworld graphic of his on the
    --     cart, so his back pic's first frame stands on our edge; a fainted
    --     monster's replacement walked in the party menu; WALLY's recall on
    --     the arena leaves nothing of the seat behind.
    do
      newGame()
      SESSION.party = { monOf(4, 20), monOf(5, 22) }
      local wild = assert(Sheet3.mon(SESSION, monOf(16, 5), 0, { wild = true }))
      local f, ev, sent, drain = screen3("wild", { tutorial = { kind = "pokedude" }, bag = TUT_BAG },
        { wildParty = { wild }, classicUi = false })
      ev({ t = "send", slot = 0, side = "a", text = "CHARMANDER", speciesId = "4", hp = 40, maxHp = 40, mon = 0 })
      ev({ t = "send", slot = 3, side = "b", text = "PIDGEY", speciesId = "16", hp = 20, maxHp = 20 })
      local canvases = 0
      local savedNew, savedGetCanvas = graphics.newCanvas, graphics.getCanvas
      graphics.newCanvas = function(w, h)
        canvases = canvases + 1
        return setmetatable({ tag = "dudeframe", w = w, h = h },
          { __index = { getDimensions = function(self) return self.w, self.h end } })
      end
      local ctx = nil
      withLove(function() ctx = f:battlefieldCtx() end)
      eq(ctx and ctx.allyHumans[1].trainerPic and ctx.allyHumans[1].trainerPic.tag, "dudeframe",
         "pokedude (arena): his back pic's first frame on our edge")
      eq(ctx and ctx.allyHumans[1].spriteId, nil, "pokedude (arena): ...no walker of his")
      local pushes, pops = 0, 0
      for _, call in ipairs(drawnCalls) do
        if call[1] == "push" then pushes = pushes + 1 elseif call[1] == "pop" then pops = pops + 1 end
      end
      check(pushes == pops and pushes > 0, "pokedude (arena): ...drawn under push('all') / pop")
      withLove(function() f:battlefieldCtx() end)
      eq(canvases, 1, "pokedude (arena): ...made once")
      graphics.newCanvas, graphics.getCanvas = savedNew, savedGetCanvas
      -- His monster down with a bench: the replacement in the party menu.
      ev({ t = "faint", slot = 0, side = "a", text = "CHARMANDER", amount = 1 })
      ev({ t = "turn", slot = 0 })
      drain()
      eq(f.phase, "switch", "pokedude: the replacement picker")
      f:autoplay3({ action = "switch", slot = 1 })
      frames(f, 79)
      eq(#sent, 0, "pokedude: 79 frames: nothing yet")
      frames(f, 161)
      eq(sent[1] and sent[1].action, "switch", "pokedude: 240: the replacement sent (Task_PartyMenu_PokedudeStep)")
      eq(sent[1] and sent[1].slot, 1, "pokedude: ...the one asked for")
    end
    do
      newGame({ version = "emerald" })
      SESSION.party = { monOf(4, 20) }
      local wild = assert(Sheet3.mon(SESSION, monOf(16, 5), 0, { wild = true }))
      local f, ev, sent, drain = screen3("wild", { tutorial = { kind = "wally" }, bag = TUT_BAG },
        { wildParty = { wild }, classicUi = false })
      ev({ t = "send", slot = 0, side = "a", text = "CHARMANDER", speciesId = "4", hp = 40, maxHp = 40, mon = 0 })
      ev({ t = "send", slot = 3, side = "b", text = "PIDGEY", speciesId = "16", hp = 20, maxHp = 20 })
      ev({ t = "turn" })
      drain()
      f:wallyThrow3()
      f:autoplay3({ action = "item", item = 4 }, nil, { instant = true })
      check(stepUntil(f, function() return f.anim and f.anim.stateRow == "withdraw3" end),
            "wally (arena): the recall plays")
      local recall = false
      for _, fx in ipairs(f.fx or {}) do if fx.kind == "recall" and fx.side == "ally" then recall = true end end
      check(recall, "wally (arena): ...on our seat")
      check(f:battlefieldSeat(0, true) ~= nil, "wally (arena): ...the monster still there while it does")
      check(stepUntil(f, function() return f.withdrawn3 == true end), "wally (arena): then gone")
      eq(f:battlefieldSeat(0, true), nil, "wally (arena): ...no seat of ours")
      local left = false
      for _, fx in ipairs(f.fx or {}) do if fx.kind == "recall" then left = true end end
      eq(left, false, "wally (arena): ...and no recall left held on it")
      check(stepUntil(f, function() return #sent == 1 end, 2000), "wally (arena): the ball goes after the throw turn")
    end

    -- ---- (r) the Battle Palace (screen option `palace`)
    for _, classic in ipairs({ true, false }) do
      local tag = classic and "palace (classic): " or "palace (arena): "
      newGame({ version = "emerald" })
      SESSION.party = { monOf(4, 20) }
      local trainer = { trainerPic = 7, className = "LASS", trainerName = "AMY" }
      local picks, answer = 0, true
      local f, ev, sent, drain
      f, ev, sent, drain = screen3("coop_npc", {
        palace = { pick = function(screen)
          picks = picks + 1
          check(screen == f, tag .. "pick is handed the screen")
          if answer == "throw" then error("boom") end
          return answer
        end },
        rules = { bag = false, forfeit = true },
      }, { trainer = trainer, classicUi = classic })
      ev({ t = "send", slot = 0, side = "a", text = "CHARMANDER", speciesId = "4", hp = 40, maxHp = 40, mon = 0 })
      ev({ t = "send", slot = 3, side = "b", text = "PIDGEY", speciesId = "16", hp = 30, maxHp = 30 })
      ev({ t = "turn" })
      drain()
      eq(f:battlefieldCtx().showTarget, false, tag .. "FIGHT highlighted aims nothing (the nature picks)")
      answer = false
      f:runCommand("FIGHT")
      eq(picks, 0, tag .. "FIGHT does not pick at once")
      eq(f.phase, "palace", tag .. "...the 8 frames of PlayerChooseMoveInBattlePalace")
      check(f:gen3ClassicModel().commands ~= nil, tag .. "...the action menu still on screen")
      if not classic then
        local bandGrid = false
        local savedGrid = Battlefield.drawCommandGrid
        Battlefield.drawCommandGrid = function() bandGrid = true; return true end
        withLove(f.drawModernBand, f)
        Battlefield.drawCommandGrid = savedGrid
        check(bandGrid, tag .. "...on the band too")
      end
      press(f, "a")
      press(f, "b")
      eq(f.phase, "palace", tag .. "...no button read meanwhile")
      frames(f, 5)
      eq(picks, 0, tag .. "7 frames: no pick yet")
      frames(f, 1)
      eq(picks, 1, tag .. "the 8th frame: pick (ChooseMoveAndTargetInBattlePalace)")
      eq(f.phase, "choose", tag .. "...a pick that did not go keeps the menu")
      answer = "throw"
      local warned = #warns
      f:runCommand("FIGHT")
      frames(f, 8)
      eq(f.phase, "choose", tag .. "a pick that throws keeps the menu")
      eq(#warns, warned + 1, tag .. "...said once, with what to do")
      warns[#warns] = nil
      answer = true
      f:runCommand("FIGHT")
      frames(f, 8)
      eq(f.phase, "play", tag .. "a pick that went spends the turn")
      eq(f.answeredTurn, true, tag .. "...answered")
      eq(#sent, 0, tag .. "...the screen filed nothing itself (the kind files the pick)")
      -- RUN still forfeits.
      ev({ t = "turn" })
      drain()
      f:runCommand("RUN")
      eq(f.phase, "ask", tag .. "RUN asks the forfeit")
      press(f, "b")
      -- The Palace's lines, in the cart's words.
      ev({ t = "palace", slot = 3, side = "b", text = "unable" })
      ev({ t = "msg", text = "PIDGEY appears incapable of using its power!" })
      ev({ t = "palace", slot = 0, side = "a", text = "flavor", amount = 0 })
      ev({ t = "msg", text = "A glint appears in CHARMANDER's eyes!" })
      ev({ t = "palace", slot = 3, side = "b", text = "flavor", amount = 3 })
      ev({ t = "msg", text = "PIDGEY is eager for more!" })
      check(said(f, "FOE PIDGEY APPEARS INCAPABLE") ~= nil,
            tag .. "unable: STRINGID_PKMNINCAPABLEOFPOWER, the foe's prefixed")
      eq(said(f, "PIDGEY appears incapable"), nil, tag .. "...the referee's sentence not said twice")
      check(said(f, "A GLINT APPEARS IN CHARMANDER'S EYES!") ~= nil,
            tag .. "flavor 0: STRINGID_GLINTAPPEARSINEYE (gBattlePalaceFlavorTextTable)")
      check(said(f, "PIDGEY IS EAGER FOR MORE!") ~= nil, tag .. "flavor 3: STRINGID_PKMNEAGERFORMORE")
      eq(said(f, "is eager for more!"), nil, tag .. "...the referee's not said twice")
      -- Without the text pack the referee's sentence stands.
      pack4 = false
      ev({ t = "palace", slot = 3, side = "b", text = "unable" })
      ev({ t = "msg", text = "PIDGEY appears incapable of using its power!" })
      pack4 = true
      check(said(f, "PIDGEY appears incapable") ~= nil, tag .. "no text pack: the referee's sentence")
      drain()
    end

    -- ---- (s) the Battle Arena's judgment
    -- The engine's frontier data stood in: the referee's strings (one IR a
    -- line, the placeholders the screen fills) and the window's words.
    local function ir(text) return { { t = "text", text = text } } end
    local ARENA = {
      refereeStrings = {
        [1] = ir("REF: IF NOTHING IS DECIDED..."), [2] = ir("REF: THAT'S IT!"),
        [3] = ir("REF: CATEGORY 1, MIND!"), [4] = ir("REF: CATEGORY 2, SKILL!"),
        [5] = ir("REF: CATEGORY 3, BODY!"), [6] = ir("REF: {B1} TO {B2}! {PN}'S {P1} WINS!"),
        [7] = ir("REF: {B1} TO {B2}! {TN}'S {O1} WINS!"), [8] = ir("REF: A DRAW!"),
        [9] = ir("REF: {P1} VS {O1}! COMMENCE!"),
      },
      text = { mind = ir("MIND"), skill = ir("SKILL"), body = ir("BODY"), vs = ir("VS."),
               judgment = ir("{B1} JUDGMENT {B2}") },
    }
    local FakeF2 = {}
    function FakeF2.arena() return ARENA end
    function FakeF2.battleText(rows, fill)
      local text = rows[1].text
      text = text:gsub("{B1}", tostring(fill.buff1)):gsub("{B2}", tostring(fill.buff2))
        :gsub("{P1}", tostring(fill.playerMon1)):gsub("{O1}", tostring(fill.opponentMon1))
        :gsub("{PN}", tostring(fill.playerName)):gsub("{TN}", tostring(fill.trainer1Name))
      return text
    end
    stub("src.core.game3.rse.frontier.f2_data", FakeF2)
    local function arenaFight(classic)
      newGame({ version = "emerald" })
      SESSION.party = { monOf(4, 20), monOf(5, 22) }
      local trainer = { trainerPic = 7, className = "LASS", trainerName = "AMY" }
      local f, ev, sent, drain = screen3("coop_npc", { rules = { bag = false, forfeit = true } },
        { trainer = trainer, classicUi = classic })
      ev({ t = "send", slot = 0, side = "a", text = "CHARMANDER", speciesId = "4", hp = 40, maxHp = 40, mon = 0 })
      ev({ t = "send", slot = 3, side = "b", text = "PIDGEY", speciesId = "16", hp = 30, maxHp = 30 })
      return f, ev, sent, drain
    end
    for _, classic in ipairs({ true, false }) do
      local tag = classic and "arena (classic): " or "arena (arena): "
      local f, ev, sent, drain = arenaFight(classic)
      audioCalls = {}
      ev({ t = "arena", text = "start" })
      ev({ t = "turn" })
      check(stepUntil(f, function() return f.arenaRef3 == true end), tag .. "the referee's box comes up")
      local se = 0
      for _, call in ipairs(audioCalls) do if call[1] == "playSe" and call[2] == "SE_ARENA_TIMEUP1" then se = se + 1 end end
      check(se >= 1, tag .. "...on SE_ARENA_TIMEUP1")
      check(stepUntil(f, function() return f.shown ~= nil end), tag .. "his line")
      eq(flat(f.shown), "REF: CHARMANDER VS PIDGEY! COMMENCE!",
         tag .. "B_MSG_REF_COMMENCE_BATTLE, off the cart, both monsters named")
      if classic then
        local m = f:gen3ClassicModel()
        eq(m.refBox, true, tag .. "the page puts it in his box")
        check(classicDraw(m) == true, tag .. "...and draws")
        local t = textAt("REF: CHARMANDER VS")
        eq(t and t.x, ClassicBattle.G3.VOICEOVER_X, tag .. "...in the dialogue frame, not the textbox")
      end
      drain()
      eq(f.arenaRef3, nil, tag .. "the box goes after B_WAIT_TIME_LONG")
      eq(f.phase, "choose", tag .. "and the turn opens")
      -- The judgment, as the referee states it (Arena.lua `_arenaJudge`).
      f:sendChoice({ action = "fight", move = 0 })
      ev({ t = "arena", text = "judge" })
      ev({ t = "arena", text = "mind", side = "a", slot = 0, amount = 2 })
      ev({ t = "arena", text = "mind", side = "b", slot = 3, amount = 0 })
      ev({ t = "arena", text = "skill", side = "a", slot = 0, amount = 1 })
      ev({ t = "arena", text = "skill", side = "b", slot = 3, amount = 1 })
      ev({ t = "arena", text = "body", side = "a", slot = 0, amount = 0 })
      ev({ t = "arena", text = "body", side = "b", slot = 3, amount = 2 })
      ev({ t = "arena", text = "win", side = "a", slot = 0 })
      ev({ t = "msg", text = "CHARMANDER defeated the opponent PIDGEY in a REFEREE's decision!" })
      ev({ t = "faint", slot = 3, side = "b", text = "PIDGEY", amount = 1 })
      ev({ t = "send", slot = 3, side = "b", text = "NIDORAN♀", speciesId = "29", hp = 25, maxHp = 25 })
      ev({ t = "turn" })
      check(stepUntil(f, function() return f.shown == "REF: THAT'S IT!" end), tag .. "B_MSG_REF_THATS_IT")
      eq(f.arenaRef3, true, tag .. "...in his box")
      eq(f:arenaView3(), nil, tag .. "...the window not open yet")
      check(stepUntil(f, function() return f:arenaView3() ~= nil end), tag .. "the window opens")
      frames(f, 1)
      eq(f:heldLine3(), "REF: THAT'S IT!", tag .. "...his words still up through the pause (arenawaitmessage, pause)")
      if classic then
        eq(f:gen3ClassicModel().message, "REF: THAT'S IT!", tag .. "...in his box on the page")
      end
      local v = f:arenaView3()
      eq(v.names.mine, "CHARMANDER", tag .. "...the player's monster")
      eq(v.names.foe, "PIDGEY", tag .. "...the opponent's")
      eq(v.vs, "VS.", tag .. "...gText_Vs off the cart")
      eq(table.concat(v.labels, ","), "MIND,SKILL,BODY", tag .. "...gText_Mind / Skill / Body")
      eq(v.judgment, "JUDGMENT", tag .. "...gText_Judgment's word, the scores apart")
      eq(#v.marks, 0, tag .. "...no marks yet")
      eq(v.shown, false, tag .. "...while the field darkens")
      check(v.fade < Mediated.ARENA_FADE_MAX3, tag .. "...a fade on its way")
      if classic then
        check(classicDraw(f:gen3ClassicModel()) == true, tag .. "the page draws the fade")
        eq(textIs("MIND"), nil, tag .. "...and nothing of the window yet")
      end
      check(stepUntil(f, function() return #(f:arenaView3() or { marks = {} }).marks == 1 end),
            tag .. "Mind's marks")
      v = f:arenaView3()
      eq(v.shown, true, tag .. "...the window up by then")
      eq(v.marks[1].cat, "mind", tag .. "...Mind first")
      eq(v.marks[1].mine, 2, tag .. "...a circle for the player's (2 points)")
      eq(v.marks[1].foe, 0, tag .. "...a cross for the opponent's")
      eq(v.score.mine, 2, tag .. "...the running score in the title")
      eq(v.score.foe, 0, tag .. "...both sides'")
      check(stepUntil(f, function() return f.shown == "REF: CATEGORY 1, MIND!" end),
            tag .. "B_MSG_REF_JUDGE_MIND after its marks")
      if classic then
        check(classicDraw(f:gen3ClassicModel()) == true, tag .. "the page draws the window")
        local G = ClassicBattle.G3A
        check(textAtY("CHARMANDER", G.WIN.mine[2] * 8 + G.TEXT_Y) ~= nil, tag .. "...the player's name in its window")
        check(textAtY("PIDGEY", G.WIN.foe[2] * 8 + G.TEXT_Y) ~= nil, tag .. "...the opponent's in its own")
        check(textIs("MIND") ~= nil and textIs("BODY") ~= nil, tag .. "...the categories")
        local circle, cross = false, false
        for _, call in ipairs(drawnCalls) do
          if call[1] == "circle" and call[3] == G.ICON_X.mine and call[4] == G.ICON_Y.mind then circle = true end
          if call[1] == "line" and call[2] == G.ICON_X.foe - 6 and call[3] == G.ICON_Y.mind - 6 then cross = true end
        end
        check(circle, tag .. "...a circle at (80, 40) (ShowJudgmentSprite)")
        check(cross, tag .. "...a cross at (160, 40)")
        local ty = G.WIN.title[2] * 8 + G.TEXT_Y
        local a2, w2, b2 = textAtY("2", ty), textAtY("JUDGMENT", ty), textAtY("0", ty)
        check(a2 and w2 and b2 and a2.x < w2.x and w2.x < b2.x, tag .. "...the score either side of the word")
      else
        local okW = withLove(f.drawWidescreen, f, 1280, 720)
        check(okW, tag .. "the arena draws the window")
        local printed = {}
        for _, call in ipairs(drawnCalls) do if call[1] == "print" then printed[call[2]] = true end end
        check(printed["CHARMANDER"] and printed["PIDGEY"] and printed["MIND"], tag .. "...names and words")
      end
      check(stepUntil(f, function() return f.shown == "REF: CATEGORY 2, SKILL!" end), tag .. "Skill")
      eq(f:arenaView3().marks[2].mine, 1, tag .. "...a triangle each on a tie")
      eq(f:arenaView3().score.mine, 3, tag .. "...the score 3")
      check(stepUntil(f, function() return f.shown == "REF: CATEGORY 3, BODY!" end), tag .. "Body")
      check(stepUntil(f, function() return f.shown and f.shown:find("REF: 3 TO 3", 1, true) end),
            tag .. "B_MSG_REF_PLAYER_WON, the totals")
      check(said(f, "REF: 3 TO 3! ANN'S CHARMANDER WINS!") ~= nil,
            tag .. "...the player named (a 3-3 the screen was told is a win)")
      eq(f:arenaView3().result, "win", tag .. "...the result marked")
      check(stepUntil(f, function() return f.shown and flat(f.shown):find("CHARMANDER DEFEATED", 1, true) end),
            tag .. "the cart's result line")
      check(said(f, "CHARMANDER DEFEATED THE OPPONENT PIDGEY IN A REFEREE'S DECISION!") ~= nil,
            tag .. "...STRINGID_DEFEATEDOPPONENTBYREFEREE")
      eq(f:arenaView3(), nil, tag .. "...after the window closed")
      eq(f.arenaRef3, nil, tag .. "...and the box went")
      drain()
      eq(said(f, "CHARMANDER defeated the opponent"), nil, tag .. "the referee's sentence not said twice")
      eq(said(f, "PIDGEY fainted"), nil, tag .. "no faint line for the judged")
      eq(f.slots[3].species, "NIDORAN♀", tag .. "the next one is out")
      eq(f.phase, "choose", tag .. "the turn opens")
      if classic then eq(f:gen3ClassicModel().foe.name, "NIDORAN♀", tag .. "the page shows the newcomer") end
    end
    do
      -- A judged loser keeps its HP: ours.
      local f, ev, sent, drain = arenaFight(true)
      ev({ t = "turn" })
      drain()
      f.commandIndex = 4
      f.moveCursor3 = 2
      ev({ t = "damage", slot = 0, side = "a", amount = 9, hp = 31 })
      drain()
      eq(f.mine[1].hp, 31, "judged (ours): the hit landed")
      ev({ t = "arena", text = "judge" })
      for _, cat in ipairs({ "mind", "skill", "body" }) do
        ev({ t = "arena", text = cat, side = "a", slot = 0, amount = 0 })
        ev({ t = "arena", text = cat, side = "b", slot = 3, amount = 2 })
      end
      ev({ t = "arena", text = "win", side = "b", slot = 3 })
      ev({ t = "msg", text = "CHARMANDER lost to the opponent PIDGEY in a REFEREE's decision!" })
      ev({ t = "faint", slot = 0, side = "a", text = "CHARMANDER", amount = 1 })
      eq(f.mine[1].hp, 31, "judged (ours): the party sheet keeps its HP")
      eq(f.slots[0].hp, 31, "judged (ours): ...and the plate")
      eq(f.commandIndex, 1, "judged (ours): the next one's menu opens on FIGHT (FaintClearSetData)")
      eq(f.moveCursor3, nil, "judged (ours): ...and its move list on the first row")
      local drains = 0
      for _, row in ipairs(f.lines) do if type(row) == "table" and row.drain == 0 then drains = drains + 1 end end
      eq(drains, 0, "judged (ours): no bar falls")
      drain()
      check(said(f, "REF: 0 TO 6! AMY'S PIDGEY WINS!") ~= nil,
            "judged (ours): B_MSG_REF_OPPONENT_WON, the trainer named")
      check(said(f, "CHARMANDER LOST TO THE OPPONENT PIDGEY") ~= nil,
            "judged (ours): STRINGID_LOSTTOOPPONENTBYREFEREE")
      eq(f.slots[0].judgedGone3, true, "judged (ours): down for good, nothing drawn of it")
      eq(f:gen3ClassicModel().ally, nil, "judged (ours): no plate once it has sunk")
      eq(f.slots[0].hp, 31, "judged (ours): its HP still kept")
      ev({ t = "send", slot = 0, side = "a", text = "CHARMELEON", speciesId = "5", hp = 50, maxHp = 50, mon = 1 })
      drain()
      eq(f.slots[0].judgedGone3, nil, "judged (ours): the next one out is drawn")
      eq(f:gen3ClassicModel().ally and f:gen3ClassicModel().ally.name, "CHARMELEON", "judged (ours): ...on its plate")
    end
    do
      -- A draw judges both; without the cart's text this file's words.
      local f, ev, sent, drain = arenaFight(true)
      ev({ t = "turn" })
      drain()
      local savedF2 = package.loaded["src.core.game3.rse.frontier.f2_data"]
      local savedEngine = Gen3.engine
      Gen3.engine = function(name)
        if name == "src.core.game3.rse.frontier.f2_data" then return nil end
        return savedEngine(name)
      end
      pack4 = false
      ev({ t = "arena", text = "judge" })
      for _, cat in ipairs({ "mind", "skill", "body" }) do
        ev({ t = "arena", text = cat, side = "a", slot = 0, amount = 1 })
        ev({ t = "arena", text = cat, side = "b", slot = 3, amount = 1 })
      end
      ev({ t = "arena", text = "draw" })
      ev({ t = "msg", text = "CHARMANDER tied the opponent PIDGEY in a REFEREE's decision!" })
      ev({ t = "faint", slot = 0, side = "a", text = "CHARMANDER" })
      ev({ t = "faint", slot = 3, side = "b", text = "PIDGEY" })
      drain()
      Gen3.engine = savedEngine
      pack4 = true
      check(said(f, "REFEREE: That's it!") ~= nil, "draw, no pack: the referee in this file's words")
      check(said(f, "REFEREE: Judgment: 3 to 3!") ~= nil, "draw, no pack: B_MSG_REF_DRAW")
      check(said(f, "CHARMANDER tied the opponent") ~= nil, "draw, no pack: the referee's own result line")
      eq(saidCount(f, "tied the opponent"), 1, "draw, no pack: ...once")
      eq(f.slots[0].judgedGone3, true, "draw: ours judged")
      eq(f.slots[3].judgedGone3, true, "draw: theirs judged")
      eq(said(f, "fainted"), nil, "draw: no faint line for either")
      check(f.slots[3].hp > 0 and f.slots[0].hp > 0, "draw: both keep their HP")
    end

    -- ---- (t) the action menu's cursor between turns (gActionSelectionCursor)
    do
      newGame()
      SESSION.party = { monOf(4, 20), monOf(5, 22) }
      local wild = assert(Sheet3.mon(SESSION, monOf(16, 5), 0, { wild = true }))
      local f, ev, sent, drain = screen3("wild", nil, { wildParty = { wild } })
      ev({ t = "send", slot = 0, side = "a", text = "CHARMANDER", speciesId = "4", hp = 40, maxHp = 40, mon = 0 })
      ev({ t = "send", slot = 3, side = "b", text = "PIDGEY", speciesId = "16", hp = 20, maxHp = 20 })
      ev({ t = "turn" })
      drain()
      eq(f.commandIndex, 1, "cursor: the first turn opens on FIGHT")
      press(f, "down")
      press(f, "right")
      eq(f.commandIndex, 4, "cursor: moved to RUN")
      f:runCommand("RUN")
      ev({ t = "msg", text = "Can't escape!" })
      ev({ t = "turn" })
      drain()
      eq(f.phase, "choose", "cursor: the next turn's menu")
      eq(f.commandIndex, 4, "cursor: still on RUN (pret keeps gActionSelectionCursor)")
      press(f, "left")
      eq(f.commandIndex, 3, "cursor: on POKéMON")
      f:sendChoice({ action = "switch", slot = 1 })
      ev({ t = "send", slot = 0, side = "a", text = "CHARMELEON", speciesId = "5", hp = 50, maxHp = 50, mon = 1 })
      ev({ t = "turn" })
      drain()
      eq(f.commandIndex, 1, "cursor: a switch-in puts it back on FIGHT (SwitchInClearSetData)")
      press(f, "right")
      f:sendChoice({ action = "item", item = "13" })
      ev({ t = "faint", slot = 0, side = "a", text = "CHARMELEON", amount = 1 })
      eq(f.commandIndex, 1, "cursor: a faint of ours puts it back too (FaintClearSetData)")
      ev({ t = "send", slot = 0, side = "a", text = "CHARMANDER", speciesId = "4", hp = 40, maxHp = 40, mon = 0 })
      ev({ t = "turn" })
      drain()
      press(f, "right")
      ev({ t = "send", slot = 3, side = "b", text = "NIDORAN♀", speciesId = "29", hp = 20, maxHp = 20 })
      eq(f.commandIndex, 2, "cursor: the foe's switch-in moves nothing of ours")
    end

    -- ---- (u) the ball thrown with the trainer (B_ANIM_BALL_THROW_WITH_TRAINER)
    do
      newGame()
      SESSION.party = { monOf(4, 20) }
      local wild = assert(Sheet3.mon(SESSION, monOf(16, 5), 0, { wild = true }))
      local f, ev, sent, drain = screen3("wild", { safari = { family = "frlg", balls = 30 } },
        { wildParty = { wild } })
      ev({ t = "send", slot = 3, side = "b", text = "PIDGEY", speciesId = "16", hp = 20, maxHp = 20 })
      ev({ t = "turn" })
      drain()
      check(f:throwsWithTrainer3(), "throw: a Safari fight throws with the trainer")
      f:runCommand("BALL")
      ev({ t = "msg", text = "ANN used SAFARI BALL!" })
      ev({ t = "item", slot = 0, side = "a", text = "5", amount = 29 })
      ev({ t = "ball", slot = 0, side = "a", target = 3, text = "5", amount = 1 })
      ev({ t = "msg", text = "Darn! The POKéMON broke free!" })
      check(stepUntil(f, function() return f.classicBall3 ~= nil end), "throw: the toss row plays")
      local t0 = f.frame
      local m = f:gen3ClassicModel()
      eq(m.playerBack.frame, 1, "throw: the player's pose, frame 1 (sAnimCmd_Red_1)")
      eq(m.ball3, nil, "throw: the ball still in the hand")
      eq(f.animHold, (20 + Mediated.BALL_FRAMES3) / 60, "throw: the row holds the pose's lead and the arc")
      frames(f, 20)
      m = f:gen3ClassicModel()
      eq(m.playerBack.frame, 2, "throw: 20 frames: frame 2 (animCmdIndex 1)")
      eq(m.playerBack.nudge, 16, "throw: ...nudged 16 right (sPlayerThrowXTranslation)")
      check(m.ball3 and m.ball3.x == 55 and m.ball3.y == 91, "throw: the ball leaves the hand at (55, 91)")
      frames(f, 17)
      m = f:gen3ClassicModel()
      check(m.ball3 and m.ball3.y < 91 - 30, "throw: ...on its arc (amplitude 40)")
      frames(f, 17)
      m = f:gen3ClassicModel()
      local G = ClassicBattle.G3
      check(m.ball3 and m.ball3.x == G.FOE_PIC_X and m.ball3.y == G.FOE_FEET_Y - 32 - 16,
            "throw: 34 frames on, over the foe's pic (its centre, 16 over)")
      check(classicDraw(m) == true, "throw: the page draws it")
      local ballDrawn = false
      for _, call in ipairs(drawnCalls) do
        if call[1] == "translate" and call[2] == m.ball3.x and call[3] == m.ball3.y then ballDrawn = true end
      end
      check(ballDrawn, "throw: ...the ball where it is")
      check(stepUntil(f, function() return f.foePicHidden == true end), "throw: the monster goes in")
      check(stepUntil(f, function() return f.classicBall3 and f.classicBall3.state == "shake" end), "throw: it rocks")
      m = f:gen3ClassicModel()
      eq(m.ball3.y, G.FOE_FEET_Y - 32 - 16 + Mediated.BALL_FALL3, "throw: ...on the ground, 40 below")
      check(stepUntil(f, function() return f.classicBall3 == nil end), "throw: it breaks free: the ball is gone")
      eq(f:throwPoseView3(), nil, "throw: the pose is over")
      drain()
      -- An ordinary throw comes in from off our pic's left (B_ANIM_BALL_THROW).
      newGame()
      SESSION.party = { monOf(4, 20) }
      local g, evg, _, draing = screen3("wild", nil, { wildParty = { wild } })
      evg({ t = "send", slot = 0, side = "a", text = "CHARMANDER", speciesId = "4", hp = 40, maxHp = 40, mon = 0 })
      evg({ t = "send", slot = 3, side = "b", text = "PIDGEY", speciesId = "16", hp = 20, maxHp = 20 })
      evg({ t = "turn" })
      draing()
      frames(g, 60)  -- (the opening send-out's slide-out and its pose are over)
      check(not g:throwsWithTrainer3(), "plain throw: not with the trainer")
      evg({ t = "item", slot = 0, side = "a", text = "4" })
      evg({ t = "ball", slot = 0, side = "a", target = 3, text = "4", amount = 4 })
      check(stepUntil(g, function() return g.classicBall3 ~= nil end), "plain throw: the toss row plays")
      local bm = g:gen3ClassicModel()
      check(bm.ball3 and bm.ball3.x == 32 and bm.ball3.y == 80, "plain throw: from (32, 80) at once")
      eq(bm.playerBack, nil, "plain throw: nobody poses (our trainer left at the send-out)")
      draing()
      check(g.classicBall3 ~= nil, "plain throw: a catch leaves the ball on the ground")
      -- A break-out with no shakes at all: the toss and its burst, and then
      -- no ball (BALL_NO_SHAKES -> SpriteCB_Ball_Release, which fades it out)
      -- -- nothing behind that burst would ever put an open one away.
      newGame()
      SESSION.party = { monOf(4, 20) }
      local z, evz, _, drainz = screen3("wild", nil, { wildParty = { wild } })
      evz({ t = "send", slot = 0, side = "a", text = "CHARMANDER", speciesId = "4", hp = 40, maxHp = 40, mon = 0 })
      evz({ t = "send", slot = 3, side = "b", text = "PIDGEY", speciesId = "16", hp = 20, maxHp = 20 })
      evz({ t = "turn" })
      drainz()
      frames(z, 60)
      evz({ t = "item", slot = 0, side = "a", text = "4" })
      evz({ t = "ball", slot = 0, side = "a", target = 3, text = "4", amount = 0 })
      local rows = {}
      for _, row in ipairs(z.lines) do
        if type(row) == "table" and row.anim then rows[#rows + 1] = row end
      end
      eq(#rows, 2, "0 shakes: the toss and the burst, nothing else")
      eq(rows[2] and rows[2].anim, "POOF_ANIM", "0 shakes: ...the burst last")
      eq(rows[2] and rows[2].last, true, "0 shakes: ...stamped the throw's last row")
      evz({ t = "msg", text = "Oh, no! The POKéMON broke free!" })
      check(stepUntil(z, function() return z.classicBall3 ~= nil end), "0 shakes: the toss row plays")
      check(stepUntil(z, function() return z.classicBall3 == nil end), "0 shakes: the burst: the ball is gone")
      eq(z.foePicHidden, nil, "0 shakes: the monster never went in")
      drainz()
      eq(z.classicBall3, nil, "0 shakes: ...and stays gone once the queue is read")
      eq(z:gen3ClassicModel().ball3, nil, "0 shakes: the page draws no ball over the foe")
      eq(z:classicBallView3(), nil, "0 shakes: ...no view of one")
      -- A throw that shakes keeps its first burst an opening, not an end.
      newGame()
      SESSION.party = { monOf(4, 20) }
      local s1, evs1 = screen3("wild", nil, { wildParty = { wild } })
      evs1({ t = "send", slot = 3, side = "b", text = "PIDGEY", speciesId = "16", hp = 20, maxHp = 20 })
      evs1({ t = "ball", slot = 0, side = "a", target = 3, text = "4", amount = 2 })
      local burst
      for _, row in ipairs(s1.lines) do
        if type(row) == "table" and row.anim == "POOF_ANIM" then burst = burst or row end
      end
      check(burst ~= nil and burst.last == nil, "shakes: the opening burst is not the throw's last")
      -- The old man's hand and pose; WALLY's.
      local o = screen3("wild", { tutorial = { kind = "oldMan" } }, { wildParty = { wild } })
      local pose, hand = o:throwerOf3()
      eq(pose, "oldMan", "old man: his throw (sAnimCmd_OldMan_1)")
      check(hand.x == 60 and hand.y == 91, "old man: from his hand (28 | 32, 11 | 80)")
      newGame({ version = "emerald" })
      local w = screen3("wild", { tutorial = { kind = "wally" } }, { wildParty = { wild } })
      local wpose, whand = w:throwerOf3()
      eq(wpose, "rse", "wally: Emerald's throw (sAnimCmd_Wally_1)")
      check(whand.x == 64 and whand.y == 91, "wally: from his hand (32 + 32, 11 | 80)")
      local s = screen3("wild", { safari = { family = "rse", balls = 30 } }, { wildParty = { wild } })
      local spose, shand = s:throwerOf3()
      eq(spose, "rse", "rse safari: BRENDAN / MAY's throw")
      check(shand.x == 55 and shand.y == 85, "rse safari: from (23 + 32, 5 | 80)")
    end

    -- ---- (v) a bag of the fight's own is the only bag spent
    do
      newGame()
      SESSION.party = { monOf(4, 20) }
      FakeBag.add(SESSION.bag, 13, 2)
      local trainer = { trainerPic = 7, className = "LASS", trainerName = "AMY" }
      local wild = assert(Sheet3.mon(SESSION, monOf(16, 5), 0, { wild = true }))
      local f, ev, sent, drain = screen3("wild", { bag = { { id = 4, count = 2 } } }, { wildParty = { wild } })
      ev({ t = "send", slot = 0, side = "a", text = "CHARMANDER", speciesId = "4", hp = 40, maxHp = 40, mon = 0 })
      ev({ t = "send", slot = 3, side = "b", text = "PIDGEY", speciesId = "16", hp = 30, maxHp = 30 })
      ev({ t = "turn" })
      drain()
      eq(FakeBag.get(SESSION.bag, 4), 0, "own bag: the player has no POKé BALL")
      f.itemPick = { id = 4, effect = Sheet3.itemEffect(4) }
      check(f:commitItem(nil, nil), "own bag: its ball can be used though the pockets hold none")
      ev({ t = "item", slot = 0, side = "a", text = "4" })
      eq(f.bagSheet[4], 1, "own bag: spent from its sheet")
      local g, evg, _, draing = screen3("coop_npc", { bag = { { id = 13, count = 1 } } }, { trainer = trainer })
      evg({ t = "send", slot = 0, side = "a", text = "CHARMANDER", speciesId = "4", hp = 40, maxHp = 40, mon = 0 })
      evg({ t = "turn" })
      draing()
      g.pendingItem = 13
      evg({ t = "item", slot = 0, side = "a", text = "13" })
      eq(FakeBag.get(SESSION.bag, 13), 2, "own bag: the session's POTIONs are not touched")
      eq(g.bagSheet[13], nil, "own bag: ...the fight's is")
    end


    -- ===============================================================
    -- Wave 4b (SCR): WALLY's throw as its own action (C-W), B held quits
    -- the POKé DUDE (C-Q), voice-overs between a command and its sub-menu
    -- (C-V), the POKé DUDE's victory music, the Palace's 8 frames, the
    -- Arena's POKéMON menu, the POKé DUDE's plain ball, the opening slide
    -- ===============================================================

    -- An input that holds / presses the keys given, for one update.
    local function held(f, keys, pressedToo)
      local saved = GAME.input
      local set = {}
      for _, k in ipairs(keys) do set[k] = true end
      GAME.input = { pressed = {}, wasPressed = function(_, k) return pressedToo and set[k] or false end,
                     isDown = function(_, k) return set[k] == true end }
      f:update(1 / 60)
      GAME.input = saved
    end

    -- ---- (w) C-W: WALLY's throw, filed and shown in its turn order
    for _, classic in ipairs({ true, false }) do
      local tag = classic and "C-W (classic): " or "C-W (arena): "
      newGame({ version = "emerald" })
      SESSION.party = { monOf(4, 20) }
      local wild = assert(Sheet3.mon(SESSION, monOf(16, 5), 0, { wild = true }))
      local f, ev, sent, drain = screen3("wild", {
        tutorial = { kind = "wally", name = "WALLY", backPic = "wally" }, bag = TUT_BAG,
      }, { wildParty = { wild }, classicUi = classic })
      ev({ t = "send", slot = 0, side = "a", text = "CHARMANDER", speciesId = "4", hp = 40, maxHp = 40, mon = 0 })
      ev({ t = "send", slot = 3, side = "b", text = "PIDGEY", speciesId = "16", hp = 20, maxHp = 20 })
      ev({ t = "turn" })
      drain()
      local filed = nil
      check(f:autoplay3({ action = "wallyThrow" }, function(ok, c) filed = { ok = ok, c = c } end),
            tag .. "the throw turn is booked")
      frames(f, 63)
      eq(#sent, 0, tag .. "63 frames: the menu")
      eq(f.commandIndex, 1, tag .. "...the cursor never moves (WallyHandleActions state 3)")
      frames(f, 1)
      eq(#sent, 1, tag .. "64: filed")
      eq(sent[1] and sent[1].action, "wallyThrow", tag .. "...as B_ACTION_WALLY_THROW")
      check(filed and filed.ok == true, tag .. "...onFiled(true)")
      eq(#f.lines, 0, tag .. "...and nothing shown yet: the sight is the referee's event's")
      eq(f.withdrawn3, nil, tag .. "...the monster still out")
      -- The turn as the referee orders it: the RALTS first, then the throw.
      local before = #(f.textLog or {})
      ev({ t = "msg", text = "Wild PIDGEY used GROWL!" })
      ev({ t = "wallyThrow", slot = 0, side = "a" })
      local foeAt = said(f, "Wild PIDGEY used GROWL!", before)
      local backAt = said(f, "CHARMANDER, THAT'S ENOUGH!", before)
      check(foeAt and backAt and foeAt < backAt, tag .. "the throw's lines in the turn's order")
      eq(returnFill and returnFill.hpScale, 0, tag .. "...STRINGID_RETURNMON with the stale hpScale 0")
      check(stepUntil(f, function() return f.withdrawn3 == true end), tag .. "the monster is called back")
      check(stepUntil(f, function() return f.tutorialSlide3 == true end), tag .. "WALLY steps in")
      check(stepUntil(f, function() return said(f, "YOU THROW A BALL NOW, RIGHT?", before) ~= nil end),
            tag .. "STRINGID_YOUTHROWABALLNOWRIGHT")
      ev({ t = "turn" })
      drain()
      eq(f.phase, "choose", tag .. "turn 4's menu")
      eq(f:gen3ClassicModel().ally, nil, tag .. "the ZIGZAGOON stays out of sight")
      eq(f:battlefieldSeat(0, true), nil, tag .. "...on the arena too")
      ev({ t = "damage", slot = 0, side = "a", amount = 1, hp = 39 })
      drain()
      eq(f:gen3ClassicModel().ally, nil, tag .. "...whatever the referee says of it")
      check(type(f:gen3ClassicModel().playerBack.pic) == "table", tag .. "WALLY's back pic in its place")
      -- Turn 4: states 4-5, then the bag.
      f:autoplay3({ action = "item", item = 4 })
      frames(f, 64)
      eq(f.commandIndex, 2, tag .. "64: BAG (state 4)")
      frames(f, 64)
      eq(f.phase, "item", tag .. "128: the bag (state 5)")
      frames(f, 306)
      eq(sent[2] and sent[2].item, "4", tag .. "306 later: USE (WALLY_BAG_DELAY * 3)")
      if classic then
        -- ...and the ball goes from his hand, in his pose.
        ev({ t = "item", slot = 0, side = "a", text = "4" })
        ev({ t = "ball", slot = 0, side = "a", target = 3, text = "4", amount = 4 })
        check(stepUntil(f, function() return f.classicBall3 ~= nil end), tag .. "the throw")
        local m = f:gen3ClassicModel()
        eq(m.playerBack.frame, 0, tag .. "...WALLY's pose (sAnimCmd_Wally_1, frame 0 for 24)")
        frames(f, 24)
        m = f:gen3ClassicModel()
        check(m.ball3 and m.ball3.x == 64 and m.ball3.y == 91, tag .. "...the ball leaves his hand at (64, 91)")
      end
      -- No throw event, no throw turn: a screen that never hears one keeps its monster.
      local g, evg, _, draing = screen3("wild", { tutorial = { kind = "wally" } }, { wildParty = { wild } })
      evg({ t = "send", slot = 0, side = "a", text = "CHARMANDER", speciesId = "4", hp = 40, maxHp = 40, mon = 0 })
      evg({ t = "turn" })
      draing()
      check(g:gen3ClassicModel().ally ~= nil, tag .. "without the event the monster stays")
    end

    -- ---- (x) C-Q: holding B quits the POKé DUDE
    local function dude(extraTut, classic)
      newGame()
      SESSION.party = { monOf(4, 20), monOf(5, 22) }
      local wild = assert(Sheet3.mon(SESSION, monOf(16, 5), 0, { wild = true }))
      local quits = {}
      -- The stand's answer when it took the screen down (Tutorial M.quit3).
      local tut = { kind = "pokedude", quit = function(how) quits[#quits + 1] = how; return true end }
      for k, v in pairs(extraTut or {}) do tut[k] = v end
      local f, ev, sent, drain = screen3("wild", { tutorial = tut, bag = TUT_BAG },
        { wildParty = { wild }, classicUi = classic ~= false })
      ev({ t = "send", slot = 0, side = "a", text = "CHARMANDER", speciesId = "4", hp = 40, maxHp = 40, mon = 0 })
      ev({ t = "send", slot = 3, side = "b", text = "PIDGEY", speciesId = "16", hp = 20, maxHp = 20 })
      ev({ t = "turn" })
      drain()
      return f, ev, sent, drain, quits
    end
    do
      local f, ev, sent, drain, quits = dude()
      f:autoplay3({ action = "fight", move = 0 })
      frames(f, 10)
      held(f, { "b" }, false)
      check(f.quit3 ~= nil and f.quit3.how == "battle", "C-Q: B held in the battle starts the quit")
      eq(f.autoplay3State, nil, "C-Q: ...the walk is dropped")
      f:say("A LINE THAT NEVER SHOWS")
      frames(f, 8)
      check(math.abs(f:quitFade3() - 8 / 17) < 1e-9, "C-Q: the fade on pret's clock (8 of 17 frames to black)")
      eq(f.shown, nil, "C-Q: ...the queue frozen")
      frames(f, 13)
      eq(#quits, 0, "C-Q: 21 frames: not handed back yet (the fade's four-frame finish)")
      eq(f:quitFade3(), 1, "C-Q: ...black since the 17th")
      frames(f, 1)
      eq(#quits, 1, "C-Q: the 22nd frame: tutorial.quit (CB2_QuitPokedudeBattle)")
      eq(quits[1], "battle", "C-Q: ...told it came from the battle")
      frames(f, 30)
      held(f, { "b" }, true)
      eq(#quits, 1, "C-Q: ...exactly once")
      eq(#sent, 0, "C-Q: nothing was filed")
      check(classicDraw(f:gen3ClassicModel()) == true, "C-Q: the page still draws")
      drawnCalls = {}
      withLove(f.drawGen3Classic, f)
      local black = false
      for i, call in ipairs(drawnCalls) do
        if call[1] == "rectangle" and call[3] == 0 and call[4] == 0 and call[5] == 240 and call[6] == 160 then
          local c = drawnCalls[i - 1]
          black = c and c[1] == "setColor" and c[2] == 0 and c[5] == 1
        end
      end
      check(black, "C-Q: ...black over it")
    end
    do
      -- In the bag and the party menu: B pressed, their own fades.
      local f, ev, sent, drain, quits = dude()
      f:autoplay3({ action = "item", item = 4 })
      check(framesUntil(f, function() return f.phase == "item" end, 400) ~= nil, "C-Q bag: the bag is open")
      held(f, { "b" }, false)
      eq(f.quit3, nil, "C-Q bag: B held is not the bag's way out")
      held(f, { "b" }, true)
      eq(f.quit3 and f.quit3.how, "bag", "C-Q bag: B pressed is (Task_BButtonInterruptTeachyTv)")
      frames(f, 14)
      eq(#quits, 0, "C-Q bag: 14 frames: not yet")
      frames(f, 1)
      eq(quits[1], "bag", "C-Q bag: the 15th frame: handed back")
      local g, evg, sentg, draing, quitsg = dude()
      g:autoplay3({ action = "switch", slot = 1 })
      check(framesUntil(g, function() return g.phase == "switch" end, 400) ~= nil, "C-Q party: the party is open")
      held(g, { "b" }, true)
      eq(g.quit3 and g.quit3.how, "party", "C-Q party: B pressed (PartyMenuPokedudeIsCancelled)")
      frames(g, 13)
      eq(#quitsg, 0, "C-Q party: 13 frames: not yet")
      frames(g, 1)
      eq(quitsg[1], "party", "C-Q party: the 14th frame: handed back")
      -- On the arena the whole window goes black.
      local a = dude(nil, false)
      held(a, { "b" }, false)
      frames(a, 30)
      local function windowFills(screen)
        drawnCalls = {}
        withLove(screen.drawWidescreen, screen, 1280, 720)
        local n = 0
        for _, call in ipairs(drawnCalls) do
          if call[1] == "rectangle" and call[3] == 0 and call[4] == 0 and call[5] == 1280 and call[6] == 720 then
            n = n + 1
          end
        end
        return n
      end
      local plain = dude(nil, false)
      eq(windowFills(a), windowFills(plain) + 1, "C-Q (arena): the window fades to black over the arena")
      -- Not the old man, not WALLY, not without a quit.
      newGame()
      SESSION.party = { monOf(4, 20) }
      local wild = assert(Sheet3.mon(SESSION, monOf(16, 5), 0, { wild = true }))
      local o = screen3("wild", { tutorial = { kind = "oldMan", quit = function() end } }, { wildParty = { wild } })
      held(o, { "b" }, true)
      eq(o.quit3, nil, "C-Q: the old man has no quit")
      eq(o.tutorial.quit, nil, "C-Q: ...the option is not even read for him")
      local d = dude({ quit = false })
      held(d, { "b" }, false)
      eq(d.quit3, nil, "C-Q: no quit handed, no quit")
    end
    -- A quit that fails -- throws, or answers false with the screen still up
    -- (Tutorial M.quit3 with no stand to end) -- must not leave the screen
    -- black and deaf: the fight ends as a draw through the ordinary way out.
    for _, case in ipairs({
      { tag = "C-Q throws: ", quit = function() error("stand gone") end },
      { tag = "C-Q false: ", quit = function() return false end },
    }) do
      local tag = case.tag
      local calls = 0
      local f, ev, sent, drain = dude({ quit = function(how) calls = calls + 1; return case.quit(how) end })
      local done = {}
      f.onDone = function(result) done[#done + 1] = result end
      Gen3Ui.pushState(GAME, f)
      local warned = #warns
      held(f, { "b" }, false)
      check(f.quit3 ~= nil, tag .. "B held starts the quit")
      frames(f, 21)
      eq(f:quitFade3(), 1, tag .. "black on pret's clock")
      eq(calls, 0, tag .. "...not asked yet")
      frames(f, 1)
      eq(calls, 1, tag .. "tutorial.quit asked on the 22nd frame")
      eq(f.quit3, nil, tag .. "the quit is dropped")
      eq(f:quitFade3(), 0, tag .. "...and the fade with it")
      eq(f.finished, true, tag .. "the fight ends")
      eq(f.result, "draw", tag .. "...a draw (the cart's DREW)")
      eq(f.left, true, tag .. "...and the screen leaves the ordinary way")
      check(not Gen3Ui.has(f), tag .. "...off the game3 stack")
      eq(#done, 1, tag .. "onDone runs once (the stand's ending gives the party back)")
      eq(done[1], "draw", tag .. "...told a draw")
      eq(#warns, warned + 1, tag .. "said once")
      check(warns[#warns]:find("ended as a draw", 1, true) ~= nil
        and warns[#warns]:find("reload from your last save", 1, true) ~= nil,
        tag .. "...with what happened and what to do")
      eq(#sent, 0, tag .. "nothing was filed")
      warns[#warns] = nil
      -- The pop failing too: the screen stays, over, its fade gone, taking A.
      local g = dude({ quit = function(how) calls = calls + 1; return case.quit(how) end })
      local gdone = {}
      g.onDone = function(result) gdone[#gdone + 1] = result end
      held(g, { "b" }, false)
      frames(g, 22)
      check(not g.left, tag .. "no layer: still up")
      eq(g:quitFade3(), 0, tag .. "no layer: ...not black")
      eq(g.phase, "over", tag .. "no layer: ...over")
      frames(g, 30)
      held(g, { "b" }, false)
      eq(g.quit3, nil, tag .. "no layer: B held does not ask again")
      eq(calls, 2, tag .. "no layer: ...tutorial.quit asked once")
      warns[#warns] = nil
      Gen3Ui.pushState(GAME, g)
      check(framesUntil(g, function()
        held(g, { "a" }, true)
        return g.left == true
      end, 120) ~= nil, tag .. "no layer: A leaves it")
      eq(gdone[1], "draw", tag .. "no layer: ...onDone told a draw")
    end

    -- ---- (y) C-V: the voice-over between a command and its sub-menu
    do
      local f, ev, sent, drain = dude()
      local after = 0
      f:autoplay3({ action = "fight", move = 1 }, nil, { afterCommand = function(fight)
        after = after + 1
        check(fight == f, "C-V: afterCommand is handed the screen")
        fight:sayTutorial3("DUDE: NOW PICK A MOVE!")
      end })
      frames(f, 63)
      eq(after, 0, "C-V: not before the command is taken")
      frames(f, 1)
      eq(after, 1, "C-V: called once, as FIGHT is taken")
      eq(f.phase, "choose", "C-V: ...the moves not open yet")
      local m = f:gen3ClassicModel()
      eq(m.commands, nil, "C-V: ...the grid gone")
      check(stepUntil(f, function() return f.shown == "DUDE: NOW PICK A MOVE!" end, 10), "C-V: his line")
      eq(f:tutorialIdle3(), false, "C-V: tutorialIdle3 false while it is up")
      frames(f, 300)
      eq(f.phase, "choose", "C-V: the walk holds while it waits for A")
      press(f, "a")
      check(stepUntil(f, function() return f.phase == "move" end, 10), "C-V: idle again: the moves open")
      eq(after, 1, "C-V: ...afterCommand not called again")
      local opened = f.frame
      frames(f, 32)
      eq(f.cursor, 2, "C-V: the moves' own pace from their opening (32: the cursor)")
      frames(f, 32)
      eq(sent[1] and sent[1].move, 1, "C-V: 64: filed")
      -- Not for RUN, WALLY's throw or the replacement picker.
      ev({ t = "turn" })
      drain()
      local runs = 0
      f:autoplay3({ action = "run" }, nil, { afterCommand = function() runs = runs + 1 end, instant = true })
      frames(f, 2)
      eq(runs, 0, "C-V: never for RUN")
      ev({ t = "faint", slot = 0, side = "a", text = "CHARMANDER", amount = 1 })
      ev({ t = "turn", slot = 0 })
      drain()
      local picks = 0
      f:autoplay3({ action = "switch", slot = 1 }, nil, { afterCommand = function() picks = picks + 1 end,
                                                         instant = true })
      frames(f, 2)
      eq(picks, 0, "C-V: never for the replacement picker")
      newGame({ version = "emerald" })
      SESSION.party = { monOf(4, 20) }
      local wild = assert(Sheet3.mon(SESSION, monOf(16, 5), 0, { wild = true }))
      local w, evw, sentw, drainw = screen3("wild", { tutorial = { kind = "wally" } }, { wildParty = { wild } })
      evw({ t = "send", slot = 0, side = "a", text = "CHARMANDER", speciesId = "4", hp = 40, maxHp = 40, mon = 0 })
      evw({ t = "turn" })
      drainw()
      local throws = 0
      w:autoplay3({ action = "wallyThrow" }, nil, { afterCommand = function() throws = throws + 1 end,
                                                   instant = true })
      frames(w, 2)
      eq(throws, 0, "C-V: never for WALLY's throw")
      eq(sentw[1] and sentw[1].action, "wallyThrow", "C-V: ...which files at once in the headless pace")
      -- Instant: the voice-over dismissed at once, the walk straight through.
      local g, evg, sentg, draing = dude()
      g:autoplay3({ action = "item", item = 13, slot = 0 }, nil, { instant = true,
        afterCommand = function(fight) fight:sayTutorial3("DUDE: THE BAG!") end })
      check(stepUntil(g, function() return #sentg == 1 end, 30), "C-V instant: filed with no A press")
      check(said(g, "DUDE: THE BAG!") ~= nil, "C-V instant: ...its line said all the same")
    end

    -- ---- (z) the POKé DUDE's victory music after his EXP voice-over
    do
      local f, ev, sent, drain = dude()
      audioCalls = {}
      ev({ t = "faint", slot = 3, side = "b", text = "PIDGEY" })
      -- The kind's note says the EXP voice-over ahead of the award.
      f:sayTutorial3("DUDE: IT GAINED EXP!")
      ev({ t = "exp", slot = 0, species = "CHARMANDER", speciesId = "4", level = 20, participants = 1, mon = 0 })
      ev({ t = "over", text = "ko" })
      f:onOutcome({ battle = "um", outcome = "win", winners = { "me" }, losers = { "wild" }, reason = "ko" })
      local function played(song)
        local n = 0
        for _, call in ipairs(audioCalls) do if call[1] == "playSong" and call[2] == song then n = n + 1 end end
        return n
      end
      eq(played(7), 0, "victory (dude): no jingle at the outcome (Cmd_getexp leaves POKEDUDE out)")
      check(stepUntil(f, function() return f.shown == "DUDE: IT GAINED EXP!" end, 400), "victory (dude): his EXP line")
      frames(f, 20)
      eq(played(7), 0, "victory (dude): ...nothing yet under it")
      press(f, "a")
      check(stepUntil(f, function() return f.voiceover == nil end, 10), "victory (dude): it closes")
      eq(played(7), 1, "victory (dude): MUS_VICTORY_WILD as it closes (pokedude.c:2573)")
      drain()
      eq(played(7), 1, "victory (dude): ...once")
      -- With no voice-over said, the jingle comes ahead of the EXP line.
      local g, evg = dude()
      audioCalls = {}
      evg({ t = "faint", slot = 3, side = "b", text = "PIDGEY" })
      evg({ t = "exp", slot = 0, species = "CHARMANDER", speciesId = "4", level = 20, participants = 1, mon = 0 })
      local row = nil
      for _, r in ipairs(g.lines) do if type(r) == "table" and r.stateRow == "victory3" then row = r end end
      check(row ~= nil, "victory (dude, no voice-over): queued ahead of the EXP line")
      -- Any other fight keeps its own jingle.
      newGame()
      SESSION.party = { monOf(4, 20) }
      local wild = assert(Sheet3.mon(SESSION, monOf(16, 5), 0, { wild = true }))
      local o = screen3("wild", nil, { wildParty = { wild } })
      audioCalls = {}
      o.result = "win"
      o:playVictoryMusic()
      local any = 0
      for _, call in ipairs(audioCalls) do if call[1] == "playSong" then any = any + 1 end end
      check(any > 0 or o.victoryMusicPlayed, "victory: an ordinary wild win still plays its jingle")
    end

    -- ---- (aa) the Battle Arena's POKéMON menu: SUMMARY / CANCEL, no SHIFT
    do
      local f, ev, sent, drain = arenaFight(true)
      ev({ t = "arena", text = "start" })
      ev({ t = "turn" })
      drain()
      check(f:arenaFight3(), "arena menu: the referee's start says it is the Arena")
      f:runCommand("SWITCH")
      eq(f.phase, "switch", "arena menu: POKéMON opens the party (PARTY_ACTION_CANT_SWITCH)")
      press(f, "a")
      eq(#sent, 0, "arena menu: A on a monster shifts nothing (ACTIONS_SUMMARY_ONLY)")
      eq(f.phase, "switch", "arena menu: ...the picker stays")
      press(f, "b")
      eq(f.phase, "choose", "arena menu: B leaves it")
      -- A kind's rules.arena arms it too; any other fight shifts as ever.
      newGame()
      SESSION.party = { monOf(4, 20), monOf(5, 22) }
      local trainer = { trainerPic = 7, className = "LASS", trainerName = "AMY" }
      local r, evr, sentr, drainr = screen3("coop_npc", { rules = { arena = true } }, { trainer = trainer })
      check(r:arenaFight3(), "arena menu: rules.arena says so too")
      local o, evo, sento, draino = screen3("coop_npc", nil, { trainer = trainer })
      evo({ t = "send", slot = 0, side = "a", text = "CHARMANDER", speciesId = "4", hp = 40, maxHp = 40, mon = 0 })
      evo({ t = "turn" })
      draino()
      o:runCommand("SWITCH")
      press(o, "a")
      eq(sento[1] and sento[1].action, "switch", "arena menu: outside the Arena A shifts")
    end

    -- ---- (bb) the POKé DUDE throws the plain ball
    do
      local f, ev, sent, drain = dude()
      frames(f, 60)  -- (the opening send-out's slide-out and its pose are over)
      check(not f:throwsWithTrainer3(), "dude ball: not with the trainer (PokedudeHandleBallThrowAnim)")
      ev({ t = "item", slot = 0, side = "a", text = "4" })
      ev({ t = "ball", slot = 0, side = "a", target = 3, text = "4", amount = 4 })
      check(stepUntil(f, function() return f.classicBall3 ~= nil end), "dude ball: the throw")
      local m = f:gen3ClassicModel()
      check(m.ball3 and m.ball3.x == 32 and m.ball3.y == 80, "dude ball: from (32, 80) at once (B_ANIM_BALL_THROW)")
      eq(m.playerBack, nil, "dude ball: nobody poses (he left at the send-out)")
    end

    -- ---- (cc) the opening slide on the GBA page
    do
      newGame()
      SESSION.party = { monOf(4, 20) }
      local trainer = { trainerPic = 7, className = "LASS", trainerName = "AMY" }
      local f, ev = screen3("coop_npc", nil, { trainer = trainer })
      ev({ t = "send", slot = 0, side = "a", text = "CHARMANDER", speciesId = "4", hp = 40, maxHp = 40, mon = 0 })
      ev({ t = "send", slot = 3, side = "b", text = "PIDGEY", speciesId = "16", hp = 30, maxHp = 30 })
      local m = f:gen3ClassicModel()
      eq(m.foe, nil, "intro: the foe's monster not out before its send-out (spawnHide)")
      eq(m.ally, nil, "intro: ...nor ours")
      eq(m.playerBack.dx, 240, "intro: our back pic starts a screen off to the right")
      eq(m.trainer and m.trainer.dx, -240, "intro: the foe trainer a screen off to the left")
      eq(m.hideBoxes, true, "intro: no healthbox yet")
      eq(f.lines[1] and f.lines[1].stateRow, "introSlide3", "intro: the slide comes ahead of the opening line")
      frames(f, 1)
      eq(f.anim and f.anim.stateRow, "introSlide3", "intro: ...and holds the queue")
      frames(f, 34)
      eq(f:gen3ClassicModel().playerBack.dx, 240, "intro: still for the background's 35 frames")
      frames(f, 61)
      m = f:gen3ClassicModel()
      eq(m.playerBack.dx, 120, "intro: then 2 px a frame (SpriteCB_TrainerSlideIn)")
      eq(m.trainer.dx, -120, "intro: ...both of them")
      local savedLass = Battlefield.gen3TrainerPic
      Battlefield.gen3TrainerPic = function() return fakeImage("lass") end
      check(classicDraw(m) == true, "intro: the page draws it")
      Battlefield.gen3TrainerPic = savedLass
      eq(chromeCount("drawEnemyBox") + chromeCount("drawPlayerBox"), 0, "intro: ...with no box")
      local trainerAt = nil
      for _, call in ipairs(drawnCalls) do
        if call[1] == "draw" and type(call[2]) == "table" and call[2].tag == "lass" then trainerAt = call[3] end
      end
      eq(trainerAt, ClassicBattle.G3.TRAINER_X - 120 - 32, "intro: ...the trainer where its slide has got to")
      check(stepUntil(f, function() return f.shown ~= nil end, 70), "intro: the opening line once they are in")
      eq(f:gen3ClassicModel().playerBack.dx or 0, 0, "intro: ...standing in place")
      check(said(f, "would like to battle!") ~= nil, "intro: ...the trainer's challenge")
      check(stepUntil(f, function() return f:gen3ClassicModel().foe ~= nil end, 400),
            "intro: the foe's monster out with its send-out")
      -- A wild monster slides with it; the arena has no slide.
      local wild = assert(Sheet3.mon(SESSION, monOf(16, 5), 0, { wild = true }))
      local g, evg = screen3("wild", nil, { wildParty = { wild } })
      evg({ t = "send", slot = 3, side = "b", text = "PIDGEY", speciesId = "16", hp = 20, maxHp = 20 })
      frames(g, 37)
      local gm = g:gen3ClassicModel()
      eq(gm.foe and gm.foe.dx, -238, "intro: a wild monster slides in from the left with it")
      check(classicDraw(gm) == true, "intro: the page draws the wild monster sliding")
      eq(chromeCount("drawEnemyBox"), 0, "intro: ...its healthbox only once it has arrived")
      check(stepUntil(g, function() return g:introSlideDx3() == 0 end, 200), "intro: the wild slide ends")
      check(classicDraw(g:gen3ClassicModel()) == true and chromeCount("drawEnemyBox") == 1,
            "intro: ...and its box is up")
      local a = screen3("wild", nil, { wildParty = { wild }, classicUi = false })
      eq(a.lines[1] and a.lines[1].stateRow, nil, "intro: the arena has no opening slide")
      eq(a:introSlideDx3(), 0, "intro: ...nothing off its place there")
    end

    -- ---- (dd) the trainers slide back out at the opening send-outs (GBA page)
    -- pret OpponentHandleIntroTrainerBallThrow / TrainerSlideBack: 35 frames
    -- to x 280, the monster out at once; PlayerHandleIntroTrainerBallThrow /
    -- TrainerSlideBack: 50 frames to x -40 in its throw (anim 1), the monster
    -- out after Task_StartSendOutAnim's 31.
    do
      newGame()
      SESSION.party = { monOf(4, 20), monOf(5, 22) }
      local trainer = { trainerPic = 7, className = "LASS", trainerName = "AMY" }
      local f, ev = screen3("coop_npc", nil, { trainer = trainer })
      ev({ t = "send", slot = 3, side = "b", text = "PIDGEY", speciesId = "16", hp = 30, maxHp = 30 })
      ev({ t = "send", slot = 0, side = "a", text = "CHARMANDER", speciesId = "4", hp = 40, maxHp = 40, mon = 0 })
      local savedLass = Battlefield.gen3TrainerPic
      Battlefield.gen3TrainerPic = function() return fakeImage("lass") end
      local function lassAt()
        local at = nil
        for _, call in ipairs(drawnCalls) do
          if call[1] == "draw" and type(call[2]) == "table" and call[2].tag == "lass" then at = call[3] end
        end
        return at
      end
      local TX, PX = ClassicBattle.G3.TRAINER_X, ClassicBattle.G3.PLAYER_BACK_X
      eq(f.foeSlideOut3, nil, "slide-out: nobody leaves before the send-out")
      check(stepUntil(f, function() return f.foeSlideOut3 ~= nil end, 600),
            "slide-out: the foe trainer goes with its first monster")
      local foeStart = f.foeSlideOut3
      local foeOut = framesUntil(f, function() return f:gen3ClassicModel().foe ~= nil end, 60)
      check(foeOut ~= nil and f.foeSlideOut3 ~= nil,
            "slide-out: ...its monster out while it is still going (Task_StartSendOutAnim at once)")
      frames(f, 3)
      local k = f.frame - foeStart
      local m = f:gen3ClassicModel()
      eq(m.trainer and m.trainer.leaving, true, "slide-out: the trainer is leaving")
      eq(m.trainer.dx, math.floor((280 - TX) * k / 35 + 0.5),
         "slide-out: ...right, on pret's line (35 frames to x 280)")
      check(m.trainer.dx > 0 and m.foe ~= nil, "slide-out: ...beside the monster it sent")
      check(classicDraw(m) == true, "slide-out: the page draws it")
      eq(lassAt(), TX + m.trainer.dx - 32, "slide-out: ...the trainer drawn where its slide has got to")
      check(framesUntil(f, function() return f:gen3ClassicModel().trainer == nil end, 60) ~= nil,
            "slide-out: then gone")
      eq(f.frame - foeStart, 35, "slide-out: ...after its 35 frames")
      check(classicDraw(f:gen3ClassicModel()) == true and lassAt() == nil,
            "slide-out: ...and not drawn again")
      -- Ours: its throw, the queue held for the 31 frames before the monster.
      check(stepUntil(f, function() return f.playerSlideOut3 ~= nil end, 600),
            "slide-out: ours goes with our first monster")
      local ourStart = f.playerSlideOut3
      eq(f.anim and f.anim.stateRow, "slideOut3", "slide-out: ...holding the queue")
      m = f:gen3ClassicModel()
      eq(m.playerBack.leaving, true, "slide-out: our trainer is leaving")
      check(m.playerBack.frame ~= nil, "slide-out: ...in its throw (StartSpriteAnim 1)")
      eq(m.ally, nil, "slide-out: ...our monster not out yet")
      frames(f, 10)
      k = f.frame - ourStart
      eq(f:gen3ClassicModel().playerBack.dx, math.floor((-40 - PX) * k / 50 + 0.5),
         "slide-out: ...left, on pret's line (50 frames to x -40)")
      check(framesUntil(f, function() return f:gen3ClassicModel().ally ~= nil end, 60) ~= nil,
            "slide-out: our monster comes out")
      check(f.frame - ourStart >= 31, "slide-out: ...once the 31 frames are up")
      m = f:gen3ClassicModel()
      check(m.playerBack ~= nil and m.playerBack.leaving == true, "slide-out: ...our trainer still going")
      check(classicDraw(m) == true and backPics > 0, "slide-out: ...and drawn beside it")
      check(framesUntil(f, function() return f:gen3ClassicModel().playerBack == nil end, 60) ~= nil,
            "slide-out: then gone")
      eq(f.frame - ourStart, 50, "slide-out: ...after its 50 frames")
      check(classicDraw(f:gen3ClassicModel()) == true and backPics == 0,
            "slide-out: ...and not drawn again")
      -- A later send-out (a switch, a replacement) brings nobody back to leave.
      local rows = #f.lines
      ev({ t = "send", slot = 0, side = "a", text = "CHARMELEON", speciesId = "5", hp = 50, maxHp = 50, mon = 1 })
      local again = false
      for i = rows + 1, #f.lines do
        if type(f.lines[i]) == "table" and f.lines[i].stateRow == "slideOut3" then again = true end
      end
      eq(again, false, "slide-out: once a fight")
      Battlefield.gen3TrainerPic = savedLass

      -- FireRed's player steps through his throw's offsets as he slides
      -- (PlayerThrowBall_StartAnimLinearTranslation -> UpdatePlayerPosInThrowAnim);
      -- Emerald's slides on the plain StartAnimLinearTranslation, the throw
      -- played where the pic stands.  30 frames in, both poses are on a
      -- command whose sPlayerThrowXTranslation is 16.
      for _, family in ipairs({ "frlg", "rse" }) do
        local savedFamily = Gen3.family
        Gen3.family = function() return family end
        newGame()
        SESSION.party = { monOf(4, 20) }
        local h, evh = screen3("coop_npc", nil, { trainer = trainer })
        evh({ t = "send", slot = 0, side = "a", text = "CHARMANDER", speciesId = "4", hp = 40, maxHp = 40, mon = 0 })
        stepUntil(h, function() return h.playerSlideOut3 ~= nil end, 600)
        frames(h, 30)
        local back = h:gen3ClassicModel().playerBack
        Gen3.family = savedFamily
        eq(h.frame - (h.playerSlideOut3 or -1), 30, "slide-out (" .. family .. "): 30 frames in")
        eq(back and back.nudge, family == "frlg" and 16 or 0,
           "slide-out (" .. family .. "): " .. (family == "frlg" and "the throw's offset (FireRed)"
             or "no offset (Emerald's plain translation)"))
      end

      -- A wild fight: only ours goes.  The arena's figures never leave.
      newGame()
      SESSION.party = { monOf(4, 20) }
      local wild = assert(Sheet3.mon(SESSION, monOf(16, 5), 0, { wild = true }))
      local g, evg = screen3("wild", nil, { wildParty = { wild } })
      evg({ t = "send", slot = 3, side = "b", text = "PIDGEY", speciesId = "16", hp = 20, maxHp = 20 })
      evg({ t = "send", slot = 0, side = "a", text = "CHARMANDER", speciesId = "4", hp = 40, maxHp = 40, mon = 0 })
      local foeRow, ourRow = false, false
      for _, row in ipairs(g.lines) do
        if type(row) == "table" and row.stateRow == "slideOut3" then
          if row.side == "foe" then foeRow = true else ourRow = true end
        end
      end
      eq(foeRow, false, "slide-out (wild): no trainer of the foe's to leave")
      eq(ourRow, true, "slide-out (wild): ...ours still does")
      local a, eva = screen3("coop_npc", nil, { trainer = trainer, classicUi = false })
      eva({ t = "send", slot = 3, side = "b", text = "PIDGEY", speciesId = "16", hp = 30, maxHp = 30 })
      eva({ t = "send", slot = 0, side = "a", text = "CHARMANDER", speciesId = "4", hp = 40, maxHp = 40, mon = 0 })
      local any = false
      for _, row in ipairs(a.lines) do
        if type(row) == "table" and row.stateRow == "slideOut3" then any = true end
      end
      eq(any, false, "slide-out (arena): nobody leaves the arena page's edges")
      -- A side that fields nothing (the Safari Zone, the old man) never sends.
      local s3, evs = screen3("wild", { noOwnBattler = true }, { wildParty = { wild } })
      evs({ t = "send", slot = 0, side = "a", text = "CHARMANDER", speciesId = "4", hp = 40, maxHp = 40, mon = 0 })
      local ours = false
      for _, row in ipairs(s3.lines) do
        if type(row) == "table" and row.stateRow == "slideOut3" and row.side == "ally" then ours = true end
      end
      eq(ours, false, "slide-out (no battler): the player stays where the throws come from")
    end

    -- ---- (ee) the move cursor, kept per battler (gMoveSelectionCursor)
    do
      local FOUR = { moves = { 10, 45, 33, 1 }, pp = { 35, 40, 35, 35 }, maxPp = { 35, 40, 35, 35 } }
      newGame()
      SESSION.party = { monOf(4, 20, FOUR), monOf(5, 22, FOUR) }
      local wild = assert(Sheet3.mon(SESSION, monOf(16, 5), 0, { wild = true }))
      local f, ev, sent, drain = screen3("wild", nil, { wildParty = { wild } })
      ev({ t = "send", slot = 0, side = "a", text = "CHARMANDER", speciesId = "4", hp = 40, maxHp = 40, mon = 0 })
      ev({ t = "send", slot = 3, side = "b", text = "PIDGEY", speciesId = "16", hp = 20, maxHp = 20 })
      ev({ t = "turn" })
      drain()
      local function rowsOf(n)
        local out = {}
        for i = 1, n do
          local copy = {}
          for key, v in pairs(f.mine[1].moves[i]) do copy[key] = v end
          out[i] = copy
        end
        return out
      end
      local function openMoves()
        if f.phase == "move" then press(f, "b") end
        f:runCommand("FIGHT")
        return f.phase == "move" and f.cursor or nil
      end
      eq(f.phase, "choose", "move cursor: the command menu")
      eq(openMoves(), 1, "move cursor: the list first opens on the first row")
      press(f, "down")
      eq(f.moveCursor3, 2, "move cursor: the d-pad writes it on every step (HandleInputChooseMove)")
      press(f, "down")
      eq(f.moveCursor3, 3, "move cursor: ...every one")
      press(f, "b")
      eq(f.phase, "choose", "move cursor: B, back to the commands")
      eq(#sent, 0, "move cursor: ...nothing filed")
      eq(openMoves(), 3, "move cursor: the list opens where the d-pad left it, A or no A")
      press(f, "up")
      press(f, "a")
      eq(sent[#sent] and sent[#sent].move, 1, "move cursor: A files the row under it")
      ev({ t = "turn" })
      drain()
      eq(openMoves(), 2, "move cursor: kept across turns")
      -- MIMIC writes the slot and resets nothing (Cmd_mimicattackcopy).
      local mimicked = rowsOf(4)
      mimicked[4] = rowsOf(2)[2]
      ev({ t = "moves", slot = 0, side = "a", moves = mimicked })
      drain()
      eq(f.moveCursor3, 2, "move cursor: a MIMIC resets nothing")
      eq(openMoves(), 2, "move cursor: ...the list opens where it was")
      -- A Castform form names no species: no reset.  The foe's TRANSFORM is not ours.
      ev({ t = "form", slot = 0, side = "a", amount = 2 })
      ev({ t = "form", slot = 3, side = "b", speciesId = "4", text = "CHARMANDER" })
      drain()
      eq(f.moveCursor3, 2, "move cursor: a Castform form, the foe's TRANSFORM: kept")
      -- Clamped to the list it has now: past the end is the last row.
      eq(openMoves(), 2, "move cursor: (open)")
      press(f, "down")
      press(f, "down")
      eq(f.moveCursor3, 4, "move cursor: on the fourth row")
      ev({ t = "moves", slot = 0, side = "a", moves = rowsOf(2) })
      drain()
      eq(openMoves(), 2, "move cursor: a two-move list opens on its last row (clamped)")
      -- Our TRANSFORM landing: the first row (RESET_MOVE_SELECTION).
      press(f, "down")
      eq(f.moveCursor3, 1, "move cursor: (the d-pad wraps a two-move list)")
      press(f, "down")
      ev({ t = "form", slot = 0, side = "a", speciesId = "16", text = "PIDGEY" })
      eq(f.moveCursor3, nil, "move cursor: our TRANSFORM drops it (RESET_MOVE_SELECTION)")
      drain()
      eq(openMoves(), 1, "move cursor: ...the list opens on the first row")
      -- Our send-out: the newcomer's list on the first row (SwitchInClearSetData).
      press(f, "down")
      press(f, "down")
      check(f.moveCursor3 ~= nil, "move cursor: (moved again)")
      press(f, "b")
      ev({ t = "send", slot = 0, side = "a", text = "CHARMELEON", speciesId = "5", hp = 50, maxHp = 50, mon = 1 })
      drain()
      eq(f.moveCursor3, nil, "move cursor: our send-out drops it (SwitchInClearSetData)")
      eq(openMoves(), 1, "move cursor: ...the newcomer's list on its first row")
      -- The foe's send-out and faint leave ours.
      press(f, "down")
      press(f, "down")
      eq(f.moveCursor3, 3, "move cursor: (on the third row)")
      ev({ t = "faint", slot = 3, side = "b", text = "PIDGEY" })
      ev({ t = "send", slot = 3, side = "b", text = "PIDGEY", speciesId = "16", hp = 20, maxHp = 20 })
      drain()
      eq(f.moveCursor3, 3, "move cursor: the foe's faint and send-out leave ours")
      -- Our faint: the first row for whoever comes next (FaintClearSetData).
      ev({ t = "faint", slot = 0, side = "a", text = "CHARMELEON" })
      eq(f.moveCursor3, nil, "move cursor: our faint drops it (FaintClearSetData)")
    end
    Battlefield.gen3TrainerBackPic = savedBackPic
    Consts4.of = savedOf4
    Gen3.battleText = textBefore4
    Gen3.battleText = textBefore
  end)
  Gen3.battleText = realText
  FakePokemon.ghostPic = nil
  if not ok then check(false, "solo kinds' screen: the block raised -- " .. tostring(err)) end
end

-- Nothing of Gen 1's engine was reached on a Gen 3 boot.
check(package.loaded["src.battle.BattleState"] == nil, "no Gen 1 BattleState on a Gen 3 boot")
check(package.loaded["src.ui.PartyMenu"] == nil, "no Gen 1 PartyMenu on a Gen 3 boot")
eq(Mediated.loadEngine().gen3, true, "the Gen 3 engine bag is the marker only")
check(not contains(warns, "ERROR"), "no error was logged: " .. table.concat(warns, " / "))

unstubAll()

-- ===================================================================
-- Tier B -- a real FireRed cache
-- ===================================================================

local okCache, Cache = pcall(require, "tests.game3_cache")
local frRoot = okCache and Cache.root("meta.json") or nil
if not frRoot then
  print("[skip] gen3_mediated real-cache tier: " .. tostring(okCache and Cache.reason or Cache))
else
  local GameVersion = require("src.core.GameVersion")
  local Dataset = require("src.core.game3.dataset")
  GameVersion.set("firered")
  Dataset.cacheRootOverride = frRoot
  pcall(Dataset.mountExtractRoots)
  for _, name in ipairs({ "src.core.game3.pokemon", "src.core.game3.battle.experience",
                          "src.core.game3.battle.moves", "src.core.game3.items_data" }) do
    package.loaded[name] = nil
  end
  local Pokemon = require("src.core.game3.pokemon")
  if Pokemon.invalidate then Pokemon.invalidate() end
  Pokemon.install(nil)
  local ItemsData = require("src.core.game3.items_data")
  pcall(ItemsData.install, nil)
  local Party = require("src.core.game3.party")
  SESSION = newSession()
  stub("src.core.game3.runtime", { getSession = function() return SESSION end })
  GAME = { generation = 3, phase = "field", data = {}, session = SESSION, input = fakeInput() }
  stubMod.game = GAME
  local needB = newNeed()
  local SheetB = needB("Sheet3")
  local SimB = needB("BattleSim3/init")
  local ok, _, mon = Party.giveMon(SESSION, 4, 12)
  check(ok and mon, "real cache: a party mon")
  local sheet = SheetB.mon(SESSION, mon, 0)
  check(sheet ~= nil, "real cache: Sheet3 describes a real party mon")
  eq(sheet and sheet.stats.atk, mon.attack, "real cache: the engine's own final Attack")
  eq(sheet and #sheet.moves, #mon.moves, "real cache: every known move becomes a row")
  local rules = SheetB.ruleset(GAME)
  check(#rules.typeTable > 0 and #rules.typeTable % 3 == 0, "real cache: the ordered chart")
  local parsed = 0
  for _, entry in ipairs(rules.movePool) do
    if SimB.Turn.parsePoolEntry(entry) then parsed = parsed + 1 end
  end
  eq(parsed, #rules.movePool, "real cache: every pool entry parses on the referee's side")
  local b = SimB.Turn.create({ id = "real", mode = "1v1", seed = 3, typeTable = rules.typeTable,
    movePool = rules.movePool,
    sides = { a = { { playerId = "a", name = "A", mons = { sheet } } },
              b = { { playerId = "b", name = "B", mons = { sheet } } } } })
  check(b ~= nil, "real cache: the referee takes the real sheet and ruleset")

  -- The award on the real curve, the real EV yields and the real learnset.
  local Exp3B = needB("Exp3")
  check(Exp3B.available(), "real cache: the engine's Gen 3 experience modules are there")
  local okF, _, fighter = Party.giveMon(SESSION, 4, 6)
  check(okF and fighter, "real cache: a fighter")
  local before, evBefore = fighter.exp, 0
  for _, v in pairs(fighter.evs) do evBefore = evBefore + v end
  local paid = Exp3B.award({ species = 16, level = 30, sentIn = { [#SESSION.party] = true },
                             party = SESSION.party })
  check(paid and paid[1] and paid[1].mon == fighter, "real cache: the fighter is paid")
  check(fighter.exp > before, "real cache: exp moved")
  check(fighter.level > 6, "real cache: a level-30 PIDGEY levels a level-6 fighter")
  local evAfter = 0
  for _, v in pairs(fighter.evs) do evAfter = evAfter + v end
  check(evAfter > evBefore, "real cache: and paid EVs")

  -- Deoxys fights on its link stats in a fight between players (the
  -- cross-version rule), and on its own cart's forme everywhere else.
  local LB = package.loaded["src.core.game3.link.battle"] or select(2, pcall(require, "src.core.game3.link.battle"))
  local okD, _, deoxys = Party.giveMon({ party = {}, name = "ANN", trainerId = 111 }, 410, 30)
  if okD and deoxys and type(LB) == "table" and LB.applyLinkStats then
    local copy = {}
    for k, v in pairs(deoxys) do copy[k] = v end
    local linked = LB.applyLinkStats(copy)
    local dsheet = SheetB.mon(SESSION, deoxys, 0, { link = true })
    if linked then
      eq(dsheet and dsheet.stats.atk, linked.attack, "real cache: Deoxys' link sheet carries its link Attack")
      eq(dsheet and dsheet.stats.spe, linked.speed, "real cache: ...and link Speed")
      eq(deoxys.attack ~= nil, true, "real cache: the party mon keeps its own stats")
      local own = SheetB.mon(SESSION, deoxys, 0)
      eq(own and own.stats.atk, deoxys.attack, "real cache: outside a link fight, its own forme's Attack")
    else
      print("[skip] this cache carries no Deoxys link row")
    end
  end

  -- A mon that would not obey (K3): each outcome's line comes out of this
  -- cart's own text pack through the fill the screens hand it (`atk`, the
  -- player's side, so no prefix), the mon's name first as on the cart.  The
  -- text pack's modules are required fresh over the mounted cache: Tier A,
  -- with no cache, left the failed-require marker `require` stores while it
  -- loads on the script space and the modules under it (LuaJIT's reads as an
  -- odd number).  The marker is taken from a require made to fail here, so
  -- only those entries go.
  local PROBE = "rby_mmo.tests.failed_require_marker"
  package.preload[PROBE] = function() error("marker", 0) end
  pcall(require, PROBE)
  local marker = package.loaded[PROBE]
  package.loaded[PROBE], package.preload[PROBE] = nil, nil
  local marked = {}
  for name, value in pairs(package.loaded) do
    if marker ~= nil and rawequal(value, marker) then marked[#marked + 1] = name end
  end
  for _, name in ipairs(marked) do package.loaded[name] = nil end
  package.loaded["src.core.game3.rom_text"] = nil
  package.loaded["src.core.game3.battle.battle_text"] = nil
  local okM, MedB = pcall(needB, "MediatedBattle")
  check(okM and type(MedB) == "table", "real cache: the screen loads over the real engine")
  if okM and type(MedB) == "table" then
    for token, id in pairs(MedB.OBEY_STRINGS3) do
      local line = MedB.obeyText3(token, "ABRA")
      check(type(line) == "string" and line:find("ABRA", 1, true) == 1 and not line:find("\\", 1, true),
            "real cache: " .. token .. " is " .. id .. " in this cart's words (" .. tostring(line) .. ")")
    end
  end
  unstubAll()
  GameVersion.set("red")
end

T.finish("gen3_mediated")
