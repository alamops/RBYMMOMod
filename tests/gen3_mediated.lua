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
  eq(Mediated.badgesOf(GAME), nil, "link rules: no badge boosts on Gen 3")
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
                        losers = out.losers, reason = out.reason, caught = out.caught })
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
  unstubAll()
  GameVersion.set("red")
end

T.finish("gen3_mediated")
