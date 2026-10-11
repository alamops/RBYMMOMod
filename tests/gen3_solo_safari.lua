-- Headless Gen 3 solo battles, the Safari Zone (wave 3 K-SAF of
-- docs/plans/gen3-solo-remaining-fights.md): src/Solo3/Safari.lua's `safari`
-- kind through the real solo core (src/SoloBattle.lua), the real referee
-- (src/BattleSim3, its Safari mode) and the real screen (MediatedBattle), over
-- stand-ins src/CoopField.lua's own wild door builds while the engine's own
-- Safari module (src/core/game3/safari.lua, the real one) says the Safari Zone
-- is on -- FireRed / LeafGreen and Emerald.
--
--   1. The family module through the registry.
--   2. Seating: the referee's `safari` option from the cart and the save (the
--      family, the SAFARI BALLS the session carries, Emerald's three tables
--      out of the engine's decoded cart, 1-based), side a the trainer alone,
--      the screen's `noOwnBattler` and `safari`; a cart whose tables cannot
--      be read is the cart's fight.
--   3. The endings and their words -- caught, out of SAFARI BALLS, the
--      monster fled, the player ran -- with the balls written home on every
--      throw and at the end, the SAFARI BALL in no catch count, no whiteout;
--      and (4) the engine's tails, after `done`: Emerald's
--      Safari.endBattleRse (the Fan Club's counts, the out-of-balls scripts),
--      FireRed's outOfBallsMidBattle; the quest log's caught scene; no
--      POKeMON TODAY.
--   5. Emerald's POKeBLOCK: the case slot read off the save, the verdict from
--      the wild monster's nature, the block gone at once, the vanilla escape
--      glitch through the referee.
--   6. The full BOX: BALL refused at selection, nothing spent.
--   7. The hand-back: the balls already spent, the blocks already thrown.
--   8. The pure helpers.
--
-- Legal: every species, move, item and table row below is the SDK fixture's
-- or invented here with synthetic numbers; the only real values are pret
-- enum numbers the battle code branches on (ITEM_*), pret's script labels and
-- string ids, and the cart's code constants the engine states too.
--
-- Run from the engine checkout root:
--
--   luajit mods/rby_mmo/tests/gen3_solo_safari.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local check, eq = T.check, T.eq

local MOD_PATH = "mods/rby_mmo"
if not io.open(MOD_PATH .. "/src/SoloBattle.lua", "rb") then
  local src = debug.getinfo(1, "S").source
  if type(src) == "string" and src:sub(1, 1) == "@" then
    local dir = src:sub(2):match("(.+)[/\\]")
    if dir then MOD_PATH = dir:gsub("[/\\]tests$", "") end
  end
end

local warns = {}
local OPTIONS = { solo = true }
local stubMod = {
  id = "rby_mmo",
  path = MOD_PATH,
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
  options = { get = function(_, key) return OPTIONS[key] end },
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
  for name, original in pairs(saved) do package.loaded[name] = original or nil end
  saved = {}
end

local function contains(list, needle)
  for _, line in ipairs(list) do
    if type(line) == "string" and line:find(needle, 1, true) then return true end
  end
  return false
end

-- ===================================================================
-- the fixture, extended
-- ===================================================================

local DATA = T.sdk.gen3Data()
local P3 = DATA.gen3Pokemon
local ROM = DATA.gen3Moves._rom
local ITEMS = DATA.gen3Items._byId

ROM[45] = { effect = 18, power = 0, type = 0, accuracy = 100, pp = 40,
            secondaryChance = 0, target = 8, priority = 0, flags = 18 }
P3._moveNames[45] = "GROWL"
ITEMS[5] = { name = "SAFARI BALL", pocket = "POKE_BALLS", price = 0 }

-- Synthetic species: one Normal-typed move each.  The Safari reads two
-- numbers off them: the catch rate (its catch factor) and FireRed /
-- LeafGreen's safariZoneFleeRate (its escape factor).
local function base(hp, atk, def, spe, spa, spd)
  return { hp = hp, atk = atk, def = def, spe = spe, spa = spa, spd = spd }
end
local function addSpecies(id, name, catchRate, fleeRate)
  P3._names[id] = name
  P3._types[id] = { 0, 0 }
  P3._stats[id] = base(40, 40, 40, 40, 40, 40)
  P3._speciesMeta[id] = { catchRate = catchRate, expYield = 100, genderRatio = 127, eggCycles = 20,
    friendship = 70, growthRate = 0, eggGroup1 = 15, eggGroup2 = 15, itemCommon = 0, itemRare = 0,
    safariZoneFleeRate = fleeRate }
  P3._abilities[id] = { 0, 0 }
  P3._learnsets[id] = { { 1, 45 } }
end
-- Caught by any ball at 1 HP (a factor of 20); and flees on every turn it
-- opens with nothing thrown on FireRed (an escape factor of 20).
addSpecies(115, "SAFARIKANG", 255, 255)
-- Never caught (a factor of 0: no ball shakes).
addSpecies(128, "SAFARIBULL", 0, 0)

-- ===================================================================
-- the stand-in engine modules
-- ===================================================================

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
  local r = ITEMS[tonumber(id)]
  return r and r.pocket or "ITEMS"
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
    if tonumber(slot.id) == tonumber(id) then slot.qty = slot.qty + qty; return true, qty end
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
    rows[#rows + 1] = { id = slot.id, qty = slot.qty, name = (ITEMS[tonumber(slot.id)] or {}).name }
  end
  return rows
end

local function fakeImage(tag)
  return setmetatable({ tag = tag, w = 64, h = 64 },
    { __index = { getDimensions = function(self) return self.w, self.h end } })
end

local FakePokemon = { FRIENDSHIP_EVENT_GROW_LEVEL = 0, NUMBERING_INTERNAL = "internal", SPECIES_EGG = 412 }
function FakePokemon.name(sp) return P3._names[tonumber(sp)] end
function FakePokemon.speciesMeta(sp) return P3._speciesMeta[tonumber(sp)] end
function FakePokemon.stats(sp) return P3._stats[tonumber(sp)] end
function FakePokemon.speciesOf(mon) return tonumber(mon and (mon.species or mon.speciesId)) end
function FakePokemon.speciesFromName(name)
  for id, n in pairs(P3._names) do if n == name then return id end end
  return nil
end
function FakePokemon.calcStats(sp, level, ivs, evs)
  local b = P3._stats[tonumber(sp)]
  ivs, evs = ivs or {}, evs or {}
  local function other(bs, k)
    return math.floor(((2 * bs + (ivs[k] or 0) + math.floor((evs[k] or 0) / 4)) * level) / 100) + 5
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
function FakePokemon.gainEVs() return 0 end
function FakePokemon.adjustFriendship() end
function FakePokemon.currentMapSec() return 88 end
function FakePokemon.movesLearnedAt(sp, level)
  local out = {}
  for _, row in ipairs(P3._learnsets[tonumber(sp)] or {}) do
    if row[1] == level then out[#out + 1] = row[2] end
  end
  return out
end
function FakePokemon.movesAtLevel(sp, level)
  local moves = {}
  for _, row in ipairs(P3._learnsets[tonumber(sp)] or {}) do
    if row[1] <= level then
      moves[#moves + 1] = row[2]
      if #moves > 4 then table.remove(moves, 1) end
    end
  end
  local pp, maxPp = {}, {}
  for i, m in ipairs(moves) do pp[i] = ROM[m].pp; maxPp[i] = ROM[m].pp end
  return moves, pp, maxPp
end
function FakePokemon.movePp(m) return ROM[tonumber(m)] and ROM[tonumber(m)].pp or 5 end
function FakePokemon.natureId(p) return (tonumber(p) or 0) % 25 end
function FakePokemon.abilityId(sp) return (P3._abilities[tonumber(sp)] or { 0 })[1] end
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
function FakePokemon.teachMove() return false end
function FakePokemon.isTradedMon() return false end
function FakePokemon.displayMonName(mon) return FakePokemon.name(mon.species) end
function FakePokemon.gender() return "M" end
function FakePokemon.frontPic(sp) return { image = fakeImage("front" .. tostring(sp)), w = 64, h = 64 } end
function FakePokemon.backPic(sp) return { image = fakeImage("back" .. tostring(sp)), w = 64, h = 64 } end
function FakePokemon.monFrontPic(mon) return FakePokemon.frontPic(mon.species) end
function FakePokemon.monBackPic(mon) return FakePokemon.backPic(mon.species) end
function FakePokemon.icon(sp) return { image = fakeImage("icon" .. tostring(sp)), w = 32, h = 32, frames = 2, quads = {} } end
function FakePokemon.monIcon(mon) return FakePokemon.icon(mon.species) end
function FakePokemon.isShiny() return false end

local FakeDex = { captures = {}, seen = {} }
function FakeDex.new() return { seen = {}, caught = {}, owned = {} } end
function FakeDex.isCaught(dex, sp) return dex.caught[tonumber(sp)] == true end
function FakeDex.registerCapture(dex, sp, _, personality)
  local was = dex.caught[sp] == true
  dex.seen[sp], dex.caught[sp] = true, true
  FakeDex.captures[#FakeDex.captures + 1] = { species = sp, personality = personality }
  return was
end
function FakeDex.handleSetPokedexFlag(dex, sp, caught, personality)
  dex.seen[sp] = true
  FakeDex.seen[#FakeDex.seen + 1] = { species = sp, caught = caught, personality = personality }
  if caught then dex.caught[sp] = true end
end

-- The PC: the engine's own questions about it (Storage.ensure /
-- findOpenSlot, as its catch asks them), over a `full` switch.
local FakeStorage = { sent = {}, full = false }
function FakeStorage.ensure(session)
  session.storage = session.storage or { currentBox = 1, boxes = {} }
  return session.storage
end
function FakeStorage.findOpenSlot(storage)
  if not storage then return nil, nil end
  if FakeStorage.full then return nil, nil end
  return 1, 1
end
function FakeStorage.sendMonToPC(session, mon)
  session.pc = session.pc or {}
  session.pc[#session.pc + 1] = mon
  FakeStorage.sent[#FakeStorage.sent + 1] = mon
  return true, 1, #session.pc
end
function FakeStorage.pcTransferMessage(_, name) return tostring(name) .. " was sent to the PC." end

local audioCalls = {}
local FakeAudio = {}
for _, name in ipairs({ "playSong", "playSe", "playCry", "restoreMapSong", "playFanfare",
                        "clearSavedSong" }) do
  FakeAudio[name] = function(...)
    audioCalls[#audioCalls + 1] = { name, ... }
    return true
  end
end
function FakeAudio.role() return nil end

local rngState = 12345
local FakeRng = {}
function FakeRng.Random()
  rngState = (rngState * 1103515245 + 12345) % 2147483648
  return math.floor(rngState / 65536) % 65536
end
function FakeRng.Random32() return FakeRng.Random() * 65536 + FakeRng.Random() end

local FakeDamage = {}
function FakeDamage.ensureStats(mon, level)
  mon.level = level or mon.level
  FakePokemon.applyStats(mon)
  if not mon.ability then
    mon.ability = FakePokemon.abilityId(mon.species)
    mon.abilityId = mon.ability
  end
  return mon
end

local FakeBattleText = {}
function FakeBattleText.get(id, fill)
  fill = fill or {}
  return id .. "|" .. tostring(fill.buff1 or "") .. "|" .. tostring(fill.trainer1Name or "")
end

-- The battle profile: FireRed's has no Safari row; Emerald's names the
-- engine's (profiles/emerald/battle.lua's shape -- pret's script labels; the
-- tables' path points at the synthetic cache below).
local SYNTH_TABLES_PATH = "synthetic/safari/rse_tables.lua"
local EM_SAFARI = {
  kind = "pokeblock_gonear", actions = { "ball", "pokeblock", "go_near", "run" },
  balls = 30, steps = 500, flag = "FLAG_SYS_SAFARI_MODE", escapeFactor = 3,
  tables = SYNTH_TABLES_PATH,
  timesUp = "SafariZone_EventScript_TimesUp",
  outOfBalls = "SafariZone_EventScript_OutOfBalls",
  outOfBallsMidBattle = "SafariZone_EventScript_OutOfBallsMidBattle",
  retire = "SafariZone_EventScript_RetirePrompt",
}
local PROFILE = {
  family = "frlg",
  rules = { money = "frlg", lostText = "frlg", pickup = "flat", amuletCoinPlayerOnly = false },
  aiFlagBits = { CHECK_BAD_MOVE = 0, CHECK_VIABILITY = 1, TRY_TO_FAINT = 2,
                 SETUP_FIRST_TURN = 3, RISKY = 4, PREFER_STRONGEST_MOVE = 5 },
}
local FakeProfile = { get = function() return PROFILE end, of = function() return PROFILE end }

local bridgeCalls = {}
local FakeBridge = {}
function FakeBridge.calcMoneyLossFrlg() return 120 end
function FakeBridge.applyWhiteoutMoneyLoss() bridgeCalls[#bridgeCalls + 1] = { "loss" } end
function FakeBridge.start(_, _, foe, opts) bridgeCalls[#bridgeCalls + 1] = { "start", foe, opts }; return true end
function FakeBridge.startWild(_, _, foe, opts)
  bridgeCalls[#bridgeCalls + 1] = { "startWild", foe, opts }
  return true
end

local fieldCalls = {}
local FakeField = {}
function FakeField.respawnAtHeal() fieldCalls[#fieldCalls + 1] = "respawn" end
local FakeParty = {}
function FakeParty.healAll() fieldCalls[#fieldCalls + 1] = "heal" end

-- The engine's whole outcome vocabulary (scripting/natives.lua outcome_to_code).
local CODES = {
  win = 1, won = 1, lose = 2, lost = 2, whiteout = 2, blackout = 2, draw = 3, drew = 3,
  run = 4, ran = 4, fled_player = 4, teleport_player = 5, player_teleported = 5,
  fled = 6, mon_fled = 6, caught = 7, catch = 7, no_safari_balls = 8, forfeited = 9,
  mon_teleported = 10,
}
local FakeNatives = {}
function FakeNatives.outcome_to_code(r)
  if type(r) == "number" then return r end
  return CODES[r] or 1
end

-- One ordered log of what the end of a fight did, across every module the
-- engine's tails reach (`done` included, so the order is checked).
local tailLog = {}
local function logged(kind)
  local out = {}
  for _, e in ipairs(tailLog) do if e[1] == kind then out[#out + 1] = e end end
  return out
end
local function indexOf(kind)
  for i, e in ipairs(tailLog) do if e[1] == kind then return i end end
  return nil
end

-- The script VM and its store (Space.store, the flags and vars the engine's
-- Safari module writes through Flags).
local FakeVm = { running = false, halted = 0 }
function FakeVm:isRunning() return self.running end
function FakeVm:halt() self.halted = self.halted + 1; self.running = false end
local FakeSpace = { vm = FakeVm, store = { flags = {}, vars = {} } }
function FakeSpace.returnToField() tailLog[#tailLog + 1] = { "returnToField" } end
function FakeSpace.runImmediately(name) tailLog[#tailLog + 1] = { "runImmediately", name }; return true end
function FakeSpace.scriptKey(label) return "key:" .. tostring(label) end
function FakeSpace.startScript(key) tailLog[#tailLog + 1] = { "startScript", key }; return true end

local FakeFlags = {}
function FakeFlags.getFlag(store, _, id) return type(store) == "table" and store.flags[id] == true end
function FakeFlags.setFlag(store, _, id, on) store.flags[id] = on and true or nil end
function FakeFlags.getVar(store, _, id) return store.vars[id] end
function FakeFlags.setVar(store, _, id, v) store.vars[id] = v end
function FakeFlags.hasBadge() return false end

local FakeWarp = {}
function FakeWarp.request(_, _, map, x, y, dir, opts)
  tailLog[#tailLog + 1] = { "warp", map, x, y, dir, opts }
  return true
end

local encounterResets = 0
local FakeEncounters = {
  resetRateModifiers = function() encounterResets = encounterResets + 1 end,
  rules = function() return { wildHeldItem = function() return 0 end } end,
}

-- What the core's ending does beyond the rewards (M:_finishEffects3): the
-- quest log, the TV, `battle.ended`.
local effectsLog = {}
local function effectsOf(kind)
  local out = {}
  for _, e in ipairs(effectsLog) do if e[1] == kind then out[#out + 1] = e end end
  return out
end
function FakePokemon.randomlyGivePartyPokerus(party, s) effectsLog[#effectsLog + 1] = { "pokerus.give", party, s } end
function FakePokemon.partySpreadPokerus(party, s) effectsLog[#effectsLog + 1] = { "pokerus.spread", party, s } end
local FakeFieldModules = { enabled = function(name) return name == "questLog" end }
local FakeQuestLog = {
  battle = function(s, st) effectsLog[#effectsLog + 1] = { "questlog", s, st } end,
}
-- Emerald's flag ids, by name (rse/init.lua flagId): a synthetic id for the
-- Safari's flag, apart from FireRed's FLAG_SYS_SAFARI_MODE.
local EM_SAFARI_FLAG = 0x9001
local FakeRse = {
  call = function(name, fn, what, logger, ...)
    effectsLog[#effectsLog + 1] = { "rse", name, fn, what, logger, ... }
    tailLog[#tailLog + 1] = { "rse", name, fn }
    return nil, true
  end,
  flagId = function(name) return name == "FLAG_SYS_SAFARI_MODE" and EM_SAFARI_FLAG or nil end,
}
local FakeRuntime = {
  wants = function(name) return name == "battle.ended" end,
  wantsHook = function() return false end,
  emit = function(name, payload) effectsLog[#effectsLog + 1] = { "emit", name, payload } end,
  call = function(_, vanilla, ...) return vanilla(nil, ...) end,
}
local FakeWeather = { id = 0 }
function FakeWeather.get() return FakeWeather.id end
-- No cache on disk is read: the Safari tables and the block names are
-- handed in below.
local FakeDataset = { cache = function() return { read = function() return nil end } end }

stub("src.core.game3.runtime", { getSession = function() return SESSION end })
stub("src.core.game3.pokemon", FakePokemon)
stub("src.core.game3.bag", FakeBag)
stub("src.core.game3.dex", FakeDex)
stub("src.core.game3.evolution", { levelTarget = function() return nil end })
stub("src.ui.game3.evolution_scene", { start = function() return false end })
stub("src.core.game3.storage", FakeStorage)
stub("src.core.game3.battle.learn_move", { begin = function(o) if o.onDone then o.onDone(false) end end })
stub("src.ui.game3.summary_menu", { openMenu = function() end })
stub("src.core.game3.audio", FakeAudio)
stub("src.core.game3.battle", { isActive = function() return false end })
stub("src.core.game3.battle.catching", { playerSecretId = function(s) return s.secretId end })
stub("src.core.game3.constants", { of = function()
  return { song = function() return 7 end, id = function() return nil end,
           name = function() return nil end }
end })
stub("src.core.game3.rng", FakeRng)
stub("src.core.game3.battle.damage", FakeDamage)
stub("src.core.game3.scripting.trainers", { foeFromId = function() return nil end,
  getBattleMusicRole = function() return "battleTrainer", 297 end,
  getVictoryMusicRole = function() return "victoryTrainer", 310 end })
stub("src.core.game3.battle.battle_text", FakeBattleText)
stub("src.core.game3.battle.profile", FakeProfile)
stub("src.core.game3.battle_bridge", FakeBridge)
stub("src.core.game3.field", FakeField)
stub("src.core.game3.party", FakeParty)
stub("src.core.game3.scripting.natives", FakeNatives)
stub("src.core.game3.scripting.space", FakeSpace)
stub("src.core.game3.scripting.flags", FakeFlags)
stub("src.core.game3.warp", FakeWarp)
stub("src.core.game3.encounters", FakeEncounters)
stub("src.core.game3.field_modules", FakeFieldModules)
stub("src.core.game3.quest_log_recorder", FakeQuestLog)
stub("src.core.game3.rse.init", FakeRse)
stub("src.mods.Runtime", FakeRuntime)
stub("src.core.game3.weather", FakeWeather)
stub("src.core.game3.dataset", FakeDataset)

-- The real engine modules a Safari fight reaches, after the stand-ins they
-- close over: the Safari Zone's session state and tails, the battle rules
-- (Rules.safari: its decoded-tables cache, the ball default, pokeblockGain),
-- and the POKeBLOCK case's data.
local Experience = require("src.core.game3.battle.experience")
local Stack = require("src.ui.game3.stack")
local EngineSafari = require("src.core.game3.safari")
local Rules = require("src.core.game3.battle.rules")
local Pokeblock = require("src.core.game3.rse.pokeblock")
check(type(EngineSafari.endBattleRse) == "function", "the engine's Safari module loads headless")
check(type(Rules.safari.rseTables) == "function", "the engine's battle rules load headless")
check(type(Pokeblock.gain) == "function", "the engine's POKeBLOCK module loads headless")

-- Emerald's three Safari tables and the flavor table, as the engine's import
-- decodes a cart (src/import/gba/rse/safari_rse_extract.lua's shape: the
-- go-near lists 1-based, sPkblToEscapeFactor's rows 0-keyed, the flavor
-- table 0-keyed) -- every number invented.
local SYNTH = {
  goNearCounterToCatchFactor = { 6, 5, 4, 3 },
  goNearCounterToEscapeFactor = { 2, 2, 2, 2 },
  pkblToEscapeFactor = { [0] = { 0, 0, 0 }, { 3, 6, 0 }, { 2, 4, 0 }, { 1, 2, 0 }, { 1, 1, 0 } },
  flavorCompatibility = {},
}
for i = 0, 25 * 5 - 1 do SYNTH.flavorCompatibility[i] = 0 end
-- Nature 7 likes the first flavor (spicy) and dislikes the second (dry).
SYNTH.flavorCompatibility[7 * 5 + 0] = 1
SYNTH.flavorCompatibility[7 * 5 + 1] = -1
Rules.safari._rseTables[SYNTH_TABLES_PATH] = SYNTH
-- Block names by color, invented.
Pokeblock.setNames({ [0] = "", "CRIMSON CUBE", "AZURE CUBE", "ROSE CUBE", "MOSS CUBE" })

local need = newNeed()
local Sheet3 = need("Sheet3")
local Mediated = need("MediatedBattle")
local Gen3Ui = need("Gen3Ui")
local Solo = need("SoloBattle")
local CoopField = need("CoopField")
local Turn3 = need("BattleSim3/Turn")

-- Record every line a screen shows, in order.
do
  local say = Mediated.say
  Mediated.say = function(self, text)
    self.textLog = self.textLog or {}
    self.textLog[#self.textLog + 1] = tostring(text)
    return say(self, text)
  end
end

local function fakeInput()
  return { pressed = {}, wasPressed = function() return false end,
           isDown = function() return false end }
end

-- What the referee and the screen are built with, captured on the way; a
-- scenario may pin the referee's escape factor (its own documented
-- override) so a monster that would flee on a roll stays for the turns the
-- scenario needs.
local createdWith, screenedWith = nil, nil
local PIN_ESCAPE = nil
local realCreate, realNew = Turn3.create, Mediated.new
Turn3.create = function(o)
  createdWith = o
  if PIN_ESCAPE ~= nil and type(o.safari) == "table" then
    local copy = {}
    for k, v in pairs(o) do copy[k] = v end
    copy.safari = {}
    for k, v in pairs(o.safari) do copy.safari[k] = v end
    copy.safari.escapeFactor = PIN_ESCAPE
    return realCreate(copy)
  end
  return realCreate(o)
end
Mediated.new = function(o) screenedWith = o; return realNew(o) end

local GAME
local function newGame(sessionExtra)
  SESSION = newSession(sessionExtra)
  GAME = { generation = 3, phase = "field", data = DATA, session = SESSION, input = fakeInput() }
  stubMod.game = GAME
  Stack.clear()
  FakeDex.captures, FakeDex.seen = {}, {}
  FakeStorage.sent, FakeStorage.full = {}, false
  FakeSpace.store = { flags = {}, vars = {} }
  FakeVm.running, FakeVm.halted = false, 0
  bridgeCalls, fieldCalls = {}, {}
  encounterResets = 0
  effectsLog, tailLog, audioCalls = {}, {}, {}
  createdWith, screenedWith, PIN_ESCAPE = nil, nil, nil
  return GAME
end

local function monOf(species, level, extra)
  local mon = {
    species = species, speciesId = species, level = level, nickname = "",
    growthRate = P3._speciesMeta[species].growthRate,
    exp = Experience.expForLevel(P3._speciesMeta[species].growthRate, level),
    moves = { 45 }, pp = { 40 }, maxPp = { 40 },
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

-- The player's party: the fixture's CHARMANDER (it never fights here).
local function lead(level) return monOf(4, level or 20) end

-- FireRed / LeafGreen and Emerald, with the Safari Zone on the way the game
-- turns it on: the engine's own Safari.enter (the flag in the script store,
-- the balls and steps in session.safari).
local function frSafari(extra)
  PROFILE.family = "frlg"
  PROFILE.safari = nil
  PROFILE.rules.teleportOutcome = nil
  local g = newGame(extra)
  SESSION.party = { lead() }
  EngineSafari.enter(SESSION)
  return g
end
local function emSafari(extra)
  local x = { version = "emerald" }
  for k, v in pairs(extra or {}) do x[k] = v end
  PROFILE.family = "rse"
  PROFILE.safari = EM_SAFARI
  PROFILE.rules.teleportOutcome = "side"
  local g = newGame(x)
  SESSION.party = { lead() }
  EngineSafari.enter(SESSION)
  return g
end

-- The Ui a solo fight is handed: boxes recorded, the state onto the real
-- game3 stack through Gen3Ui.
local said = {}
local UI = {
  pushState = function(_, game, state) return Gen3Ui.pushState(game, state) end,
  say = function(_, text, cb) said[#said + 1] = text; if cb then cb() end; return {} end,
  confirm = function(_, _, text, cb) said[#said + 1] = text; if cb then cb(true) end; return {} end,
  askNickname = function() return true end,
}

local function newSolo(seed)
  return Solo.new(UI, {
    enabled = function() return OPTIONS.solo == true end,
    seed = function() return seed or 7 end,
  })
end

local function textOf(fight)
  return table.concat((fight and fight.textLog) or {}, " | ")
end

-- The wild door's stand-in (CoopField.wildStand3, a step encounter: no
-- opts), and what src/Client.lua's offerFight3 hands solo for it -- the
-- Safari's `opts.safari` / `enc.safari` included.  `hp` / `personality`
-- set the built monster's before the fight sees it.
local fightAloneCalls = 0
local function standFor(enc, mapId)
  return CoopField.wildStand3(enc, {
    game = GAME, mapId = mapId or "FR_SAFARI_ZONE_CENTER", solo = true,
    fightAlone = function() fightAloneCalls = fightAloneCalls + 1 end,
  }, {})
end
local function offer(solo, stand, enc, opts, monFields)
  local o = {}
  for k, v in pairs(opts or {}) do o[k] = v end
  o.mapId = stand.mapId
  o.done = o.done or function() end
  o.fallback = o.fallback or function() stand:fightAlone() end
  o.party = stand.enemyParty
  o.stand3 = stand
  if stand.safari then o.safari = true end
  local lead1 = stand.enemyParty[1]
  for k, v in pairs(monFields or {}) do lead1[k] = v end
  local withMon = {}
  for k, v in pairs(enc) do withMon[k] = v end
  withMon.mon = lead1
  if stand.safari then withMon.safari = true end
  return solo:fromGen3Encounter(GAME, withMon, o)
end

-- Pump a fight the way the game does, answering each command menu with
-- `onChoose(fight, turn)`, until the ending has printed; then leave it.
local function drive(solo, onChoose, maxSteps)
  local fight = solo.fight
  local lastFight = fight
  local turn = 0
  for _ = 1, maxSteps or 300 do
    solo:update(0.5, GAME)
    fight = solo.fight
    if not fight then return true, lastFight end
    lastFight = fight
    for _ = 1, 60 do
      fight:update(2.0)
      if fight.phase == "choose"
         or (fight.phase == "over" and #fight.lines == 0 and not fight.shown) then
        break
      end
    end
    if fight.phase == "over" and #fight.lines == 0 and not fight.shown then
      for _ = 1, 60 do
        fight:update(2.0)
        if #fight.lines == 0 and not fight.shown then break end
      end
      fight:leave()
      return true, lastFight
    end
    if fight.phase == "choose" and onChoose then
      turn = turn + 1
      onChoose(fight, turn)
    end
  end
  return false, lastFight
end

-- Pump until the command menu is up (a fight left running, for a hand-back).
local function toMenu(solo)
  for _ = 1, 100 do
    solo:update(0.5, GAME)
    local fight = solo.fight
    if not fight then return nil end
    for _ = 1, 60 do
      fight:update(2.0)
      if fight.phase == "choose" then return fight end
    end
  end
  return nil
end

local function throw(f, what, extra)
  local fields = { action = "safari", throw = what }
  for k, v in pairs(extra or {}) do fields[k] = v end
  return f:sendChoice(fields)
end
local function runAway(f) return f:sendChoice({ action = "run" }) end

-- One Safari fight from the door to the end.  -> { result, fight, solo,
-- stand }.
local function safariFight(label, species, choose, o)
  o = o or {}
  local enc = { species = species, level = o.level or 20 }
  local stand = standFor(enc, o.mapId)
  check(stand ~= nil and stand.kind3 == "safari", label .. ": the door's stand says safari")
  local solo = newSolo(o.seed)
  local out = { stand = stand, solo = solo }
  local taken = offer(solo, stand, enc, {
    done = function(r)
      out.result = r
      tailLog[#tailLog + 1] = { "done", r }
    end,
  }, o.mon)
  check(taken, label .. ": taken")
  out.taken = taken
  if not taken then return out end
  out.sim = solo.sim
  local ok, fight = drive(solo, choose)
  check(ok, label .. ": the fight ran to its end")
  out.fight = fight
  return out
end

local SafariKind

-- ===================================================================
-- 1. the family module, found through the registry
-- ===================================================================
do
  eq(Solo.KIND_FILES3.safari, "Solo3/Safari", "registry: the safari kind's module is Solo3/Safari")
  stubMod.read = function(_, path)
    local h = io.open(MOD_PATH .. "/" .. path, "rb")
    if not h then return nil end
    local body = h:read("*a")
    h:close()
    return body
  end
  local kind = Solo.kind3("safari")
  check(type(kind) == "table", "registry: the safari kind is read from src/Solo3/Safari.lua")
  SafariKind = need("Solo3/Safari")
  check(type(SafariKind) == "table" and type(SafariKind.kinds3) == "table",
        "registry: the module returns its kinds3")
  local names = {}
  for name in pairs(SafariKind.kinds3) do names[#names + 1] = name end
  table.sort(names)
  eq(table.concat(names, ","), "safari", "registry: exactly the one kind")
  eq(kind, SafariKind.kinds3.safari, "registry: ...the very table kind3() found")
  for key, fn in pairs(kind) do
    check(type(fn) == "function", "registry: safari." .. tostring(key) .. " is a hook")
  end
  eq(#warns, 0, "registry: read without a word said")
end

-- ===================================================================
-- 2. seating
-- ===================================================================

-- (a) FireRed: the family, the balls the session carries, side a alone,
-- the screen told
do
  frSafari()
  SESSION.safari.balls = 17
  local enc = { species = 128, level = 20 }
  local stand = standFor(enc)
  eq(stand and stand.kind3, "safari", "seat (FRLG): the door's stand is a Safari one (the engine's Safari mode on)")
  eq(stand and stand.safari, true, "seat (FRLG): ...stamped `safari`")
  local solo = newSolo()
  check(offer(solo, stand, enc), "seat (FRLG): taken")
  local s = createdWith and createdWith.safari
  check(type(s) == "table", "seat (FRLG): the referee's `safari` option")
  eq(s and s.family, "frlg", "seat (FRLG): family frlg (the cart)")
  eq(s and s.balls, 17, "seat (FRLG): the SAFARI BALLS the session carries")
  eq(s and s.goNearCatch, nil, "seat (FRLG): no Emerald tables")
  local a = createdWith and createdWith.sides.a
  eq(a and #a, 1, "seat (FRLG): one entry on side a")
  eq(a and a[1].playerId, "solo_player", "seat (FRLG): ...the player's seat")
  eq(a and a[1].name, "ANN", "seat (FRLG): ...named")
  eq(a and a[1].mons, nil, "seat (FRLG): ...with no monsters (the battler zeroed)")
  eq(a and a[1].bag, nil, "seat (FRLG): ...and no bag")
  local seat = solo.sim and solo.sim.byId.solo_player
  eq(seat and seat.noBattler, true, "seat (FRLG): the referee seats the trainer alone")
  check(solo.sim and solo.sim.safari ~= nil, "seat (FRLG): the referee is in its Safari mode")
  eq(screenedWith and screenedWith.noOwnBattler, true, "seat (FRLG): the screen fields nothing of ours")
  local so = screenedWith and screenedWith.safari
  eq(so and so.family, "frlg", "seat (FRLG): the screen's `safari` names the cart")
  eq(so and so.balls, 17, "seat (FRLG): ...and the balls it opens on")
  eq(createdWith and createdWith.sides.b[1].mons[1].safariFleeRate, 0,
     "seat (FRLG): the wild sheet carries the species' safariZoneFleeRate")
  solo:reset()
end

-- (b) Emerald: the cart's three tables, 1-based as the referee reads them
do
  emSafari()
  local enc = { species = 128, level = 20 }
  local stand = standFor(enc, "EM_SAFARI_ZONE_SOUTH")
  eq(stand and stand.kind3, "safari", "seat (EM): the door's stand is a Safari one")
  local solo = newSolo()
  check(offer(solo, stand, enc), "seat (EM): taken")
  local s = createdWith and createdWith.safari or {}
  eq(s.family, "rse", "seat (EM): family rse")
  eq(s.balls, 30, "seat (EM): Safari.enter's balls, from the session")
  eq(table.concat(s.goNearCatch or {}, ","), "6,5,4,3", "seat (EM): sGoNearCounterToCatchFactor, from the cart")
  eq(table.concat(s.goNearEscape or {}, ","), "2,2,2,2", "seat (EM): sGoNearCounterToEscapeFactor")
  local rows = s.pkblToEscape or {}
  eq(#rows, 5, "seat (EM): every sPkblToEscapeFactor row")
  eq(table.concat(rows[1] or {}, ","), "0,0,0", "seat (EM): pret row 0 at list[1]")
  eq(table.concat(rows[2] or {}, ","), "3,6,0", "seat (EM): pret row 1 at list[2]")
  eq(table.concat(rows[5] or {}, ","), "1,1,0", "seat (EM): pret row 4 at list[5]")
  check(rows[2] ~= SYNTH.pkblToEscapeFactor[1], "seat (EM): copies, never the engine's own rows")
  eq(solo.sim and solo.sim.safari and solo.sim.safari.escapeFactor, 3,
     "seat (EM): the referee's escape factor is the cart's constant 3")
  eq(screenedWith and screenedWith.safari and screenedWith.safari.family, "rse",
     "seat (EM): the screen draws Emerald's menu")
  solo:reset()

  -- Tables the import never decoded: the cart's own fight, said once.
  emSafari()
  PROFILE.safari = {}
  for k, v in pairs(EM_SAFARI) do PROFILE.safari[k] = v end
  PROFILE.safari.tables = "synthetic/not-imported.lua"
  local stand2 = standFor(enc, "EM_SAFARI_ZONE_SOUTH")
  local before = #warns
  local s2 = newSolo()
  check(not offer(s2, stand2, enc), "seat (EM, no tables): handed back to the cart")
  eq(s2.fight, nil, "seat (EM, no tables): no screen opened")
  check(#warns == before + 1 and warns[#warns]:find("re-import", 1, true) ~= nil,
        "seat (EM, no tables): one warning, naming the remedy")
  for i = #warns, before + 1, -1 do table.remove(warns, i) end
  PROFILE.safari = EM_SAFARI
end

-- (c) No Safari state in the session (a direct start that says `safari`):
-- the engine's own start default
do
  frSafari()
  SESSION.safari = nil
  local solo = newSolo()
  local mon = monOf(128, 20)
  check(solo:fromGen3Encounter(GAME, { species = 128, level = 20, mon = mon }, { safari = true }),
        "seat (no state): taken")
  eq(createdWith and createdWith.safari and createdWith.safari.balls, Rules.safari.BALLS,
     "seat (no state): FireRed's start default (Rules.safari.BALLS)")
  solo:reset()
end

-- ===================================================================
-- 3. the endings
-- ===================================================================

-- (a) caught: the word, the ball written home, no catch count, the monster
-- joins
do
  frSafari()
  local balls = {}
  local out = safariFight("caught (FRLG)", 115, function(f)
    throw(f, "ball")
  end, { mon = { hp = 1 } })
  eq(out.result, "caught", "caught (FRLG): done('caught')")
  eq(SESSION.battleOutcome, 7, "caught (FRLG): B_OUTCOME_CAUGHT")
  eq(SESSION.safari.balls, 29, "caught (FRLG): one SAFARI BALL spent, written home")
  eq(#SESSION.party, 2, "caught (FRLG): the monster joins the party")
  eq(SESSION.party[2] and SESSION.party[2].species, 115, "caught (FRLG): ...the one met")
  eq(SESSION.party[1].hp, SESSION.party[1].maxHp, "caught (FRLG): the party never fought")
  check(textOf(out.fight):find("SAFARI BALL", 1, true) ~= nil, "caught (FRLG): 'ANN used SAFARI BALL!'")
  local seen = false
  for _, s in ipairs(FakeDex.seen) do if s.species == 115 then seen = true end end
  check(seen, "caught (FRLG): the dex sees a Safari monster (no exclusion for it, pret battle_main.c:2614)")
  -- The quest log (FRLG): the caught scene, the battle type saying Safari.
  local ql = effectsOf("questlog")
  eq(#ql, 1, "caught (FRLG): the quest log is told once")
  local st = ql[1] and ql[1][3] or {}
  eq(st.result, "catch", "caught (FRLG): ...a catch (CaughtWildMon)")
  eq(st.wild, true, "caught (FRLG): ...a wild one")
  eq(st.safari, true, "caught (FRLG): ...in the Safari Zone")
  eq(st.kinds and st.kinds.safari, true, "caught (FRLG): ...its kinds say safari")
  eq(st.player, nil, "caught (FRLG): ...with no battler of ours")
  local results = st.battleResults or {}
  eq(results.lastUsedItem, 5, "caught (FRLG): gLastUsedItem the SAFARI BALL")
  eq(next(results.catchAttempts or {}), nil, "caught (FRLG): the SAFARI BALL is in no catch count")
  eq(#logged("warp"), 0, "caught (FRLG): balls left -- no tail")
  eq(EngineSafari.isActive(SESSION), true, "caught (FRLG): still in the Safari Zone")
  eq(#fieldCalls, 0, "caught (FRLG): no whiteout, no heal")
end

-- (b) out of SAFARI BALLS (FRLG): the last ball misses -- the word, and the
-- engine's outOfBallsMidBattle after `done`
do
  frSafari()
  SESSION.safari.balls = 1
  local out = safariFight("no balls (FRLG)", 128, function(f) throw(f, "ball") end)
  eq(out.result, "no_safari_balls", "no balls (FRLG): done('no_safari_balls')")
  eq(SESSION.battleOutcome, 8, "no balls (FRLG): B_OUTCOME_NO_SAFARI_BALLS")
  check(textOf(out.fight):find("out of SAFARI BALLS", 1, true) ~= nil,
        "no balls (FRLG): the announcer's line")
  eq(#fieldCalls, 0, "no balls (FRLG): no whiteout")
  local warp = logged("warp")[1]
  check(warp ~= nil, "no balls (FRLG): Safari.outOfBallsMidBattle warps the player out")
  eq(warp and warp[2], EngineSafari.EXIT_MAP, "no balls (FRLG): ...to the Safari Zone's gate")
  eq(warp and warp[6] and warp[6].fade, false, "no balls (FRLG): ...without the fade (safari_zone.c:68)")
  check((indexOf("done") or 99) < (indexOf("warp") or 0), "no balls (FRLG): the tail runs after `done`")
  eq(FakeSpace.store.vars[EngineSafari.VAR_ENTRANCE_SCENE], 3,
     "no balls (FRLG): the gate's scene 3 (SafariZone_EventScript_OutOfBallsMidBattle)")
  eq(EngineSafari.isActive(SESSION), false, "no balls (FRLG): the Safari is over (ExitSafariMode)")
  eq(SESSION.safari.balls, 0, "no balls (FRLG): no balls left")
end

-- (c) caught with the last ball (FRLG): nothing from the tail -- the
-- field's own poll ends the Safari
do
  frSafari()
  SESSION.safari.balls = 1
  local out = safariFight("last-ball catch (FRLG)", 115, function(f) throw(f, "ball") end,
    { mon = { hp = 1 } })
  eq(out.result, "caught", "last-ball catch (FRLG): done('caught')")
  eq(SESSION.safari.balls, 0, "last-ball catch (FRLG): 0 balls written home")
  eq(#logged("warp"), 0, "last-ball catch (FRLG): no warp from the battle")
  eq(EngineSafari.isActive(SESSION), true,
     "last-ball catch (FRLG): the Safari still on, for Field.pollSafariBalls to end")
end

-- (d) the monster flees (FRLG, an escape factor of 20): the ball spent,
-- the word, nothing else
do
  frSafari()
  local out = safariFight("flees (FRLG)", 115, function(f) throw(f, "bait") end)
  eq(out.result, "mon_fled", "flees (FRLG): done('mon_fled')")
  eq(SESSION.battleOutcome, 6, "flees (FRLG): B_OUTCOME_MON_FLED")
  check(textOf(out.fight):find("BAIT", 1, true) ~= nil, "flees (FRLG): the BAIT thrown first (the player acts first)")
  check(textOf(out.fight):find("fled", 1, true) ~= nil, "flees (FRLG): 'Wild SAFARIKANG fled!'")
  eq(SESSION.safari.balls, 30, "flees (FRLG): no ball spent")
  eq(#logged("warp"), 0, "flees (FRLG): no tail")
  eq(#SESSION.party, 1, "flees (FRLG): nobody joins")
end

-- (e) the player runs: always gets away
do
  frSafari()
  local out = safariFight("run (FRLG)", 115, function(f) runAway(f) end)
  eq(out.result, "run", "run (FRLG): done('run')")
  eq(SESSION.battleOutcome, 4, "run (FRLG): B_OUTCOME_RAN")
  check(textOf(out.fight):find("Got away safely", 1, true) ~= nil, "run (FRLG): 'Got away safely!'")
end

-- (f) many throws: the balls home on every one, as the engine's battle syncs
-- them (the monster pinned so it stays)
do
  frSafari()
  local seen = {}
  local out
  do
    local enc = { species = 128, level = 20 }
    local stand = standFor(enc)
    local solo = newSolo()
    PIN_ESCAPE = 0
    check(offer(solo, stand, enc, { done = function(r) out = r end }), "many throws (FRLG): taken")
    local ok = drive(solo, function(f, turn)
      seen[#seen + 1] = SESSION.safari.balls
      if turn <= 3 then throw(f, "ball") elseif turn == 4 then throw(f, "rock")
      else runAway(f) end
    end)
    check(ok, "many throws (FRLG): the fight ran to its end")
  end
  eq(table.concat(seen, ","), "30,29,28,27,27", "many throws (FRLG): written home after each ball, before the next turn")
  eq(SESSION.safari.balls, 27, "many throws (FRLG): three spent")
  eq(out, "run", "many throws (FRLG): run")
end

-- (g) Emerald: no POKeMON TODAY, Pokérus, and endBattleRse after `done`
do
  emSafari()
  local out = safariFight("caught (EM)", 115, function(f) throw(f, "ball") end,
    { mon = { hp = 1 }, mapId = "EM_SAFARI_ZONE_SOUTH" })
  eq(out.result, "caught", "caught (EM): done('caught')")
  eq(SESSION.safari.balls, 29, "caught (EM): one ball spent")
  local tv
  for _, e in ipairs(effectsOf("rse")) do if e[2] == "tv" and e[3] == "onBattleEnd" then tv = e end end
  check(tv ~= nil, "caught (EM): the TV is asked, as the engine asks it")
  local bt = tv and tv[9] or {}
  eq(bt.safari, true, "caught (EM): ...told it was a Safari battle (pret battle_main.c:5102: never on air)")
  local results = tv and tv[7] or {}
  eq(results.lastUsedItem, 5, "caught (EM): gBattleResults' last item the SAFARI BALL")
  eq(next(results.catchAttempts or {}), nil, "caught (EM): no catch counted for it")
  eq(#effectsOf("pokerus.give"), 1, "caught (EM): Pokérus still applies")
  eq(#effectsOf("questlog"), 0, "caught (EM): no quest log on Emerald")
  eq(SESSION.safari.caughtMons, 1, "caught (EM): the Fan Club counts the catch (endBattleRse)")
  eq(SESSION.safari.pkblkUses, 0, "caught (EM): ...and no POKeBLOCK")
  eq(#logged("runImmediately") + #logged("startScript"), 0, "caught (EM): balls left -- no script")
end

do
  emSafari()
  SESSION.safari.balls = 1
  SESSION.warpDestination = { map = "EM_ROUTE121_SAFARI_ZONE_ENTRANCE", x = 2, y = 5 }
  local out = safariFight("no balls (EM)", 128, function(f) throw(f, "ball") end,
    { mapId = "EM_SAFARI_ZONE_SOUTH" })
  eq(out.result, "no_safari_balls", "no balls (EM): done('no_safari_balls')")
  eq(SESSION.battleOutcome, 8, "no balls (EM): B_OUTCOME_NO_SAFARI_BALLS")
  local run = logged("runImmediately")[1]
  eq(run and run[2], EM_SAFARI.outOfBallsMidBattle, "no balls (EM): the out-of-balls-mid-battle script")
  local warp = logged("warp")[1]
  eq(warp and warp[2], "EM_ROUTE121_SAFARI_ZONE_ENTRANCE", "no balls (EM): ...and its warp")
  check((indexOf("done") or 99) < (indexOf("runImmediately") or 0), "no balls (EM): after `done`")
  eq(#logged("startScript"), 0, "no balls (EM): not the caught arm")
end

do
  emSafari()
  SESSION.safari.balls = 1
  local out = safariFight("last-ball catch (EM)", 115, function(f) throw(f, "ball") end,
    { mon = { hp = 1 }, mapId = "EM_SAFARI_ZONE_SOUTH" })
  eq(out.result, "caught", "last-ball catch (EM): done('caught')")
  local started = logged("startScript")[1]
  eq(started and started[2], "key:" .. EM_SAFARI.outOfBalls,
     "last-ball catch (EM): SafariZone_EventScript_OutOfBalls (CB2_EndSafariBattle's CAUGHT arm)")
  eq(#logged("runImmediately"), 0, "last-ball catch (EM): not the mid-battle arm")
  eq(SESSION.safari.caughtMons, 1, "last-ball catch (EM): the catch counted")
end

-- ===================================================================
-- 5. Emerald's POKeBLOCK
-- ===================================================================

local function blockAt(slot, fields)
  local list = Pokeblock.slots(SESSION)
  local b = Pokeblock.empty()
  for k, v in pairs(fields) do b[k] = v end
  list[slot] = b
  return b
end

-- (a) the verdict by nature, the block gone, the vanilla escape glitch
do
  -- Nature 7 (personality 7) likes spicy and dislikes dry (SYNTH above).
  local cases = {
    { label = "enthralled", fields = { color = 1, spicy = 10 }, verdict = 1, line = "enthralled by the CRIMSON CUBE",
      esc = 1 },
    { label = "ignored", fields = { color = 2, dry = 10 }, verdict = 2, line = "completely ignored the AZURE CUBE",
      esc = 3 },
    { label = "curious", fields = { color = 3, sweet = 10 }, verdict = 0, line = "curious about the ROSE CUBE",
      esc = 0 },
  }
  for _, c in ipairs(cases) do
    emSafari()
    blockAt(4, c.fields)
    blockAt(9, { color = 4, sour = 5 })
    local enc = { species = 128, level = 20 }
    local stand = standFor(enc, "EM_SAFARI_ZONE_SOUTH")
    local solo = newSolo()
    local result
    check(offer(solo, stand, enc, { done = function(r) result = r end }, { personality = 7 + 25 * 3 }),
          "block " .. c.label .. ": taken")
    local sim = solo.sim
    local fight = toMenu(solo)
    check(fight ~= nil, "block " .. c.label .. ": the menu is up")
    -- The flee roll for turn 1 was made as it opened (escape factor 3);
    -- the scenario needs the monster to stay for the throw's turn.
    local wild = sim.bySide.b[1]
    wild.choice = { action = "safari", watch = true }
    check(throw(fight, "block", { block = 4 }), "block " .. c.label .. ": the throw is taken")
    local left = Pokeblock.get(SESSION, 3)
    eq(left.color, 0, "block " .. c.label .. ": the block left the case at once")
    eq(Pokeblock.get(SESSION, 8).color, 4, "block " .. c.label .. ": ...and no other")
    eq(sim.safari.pokeblockThrows, 1, "block " .. c.label .. ": the referee threw it")
    eq(sim.safari.escapeFactor, c.esc, "block " .. c.label .. ": the cart's escape change"
       .. (c.esc == 0 and " -- the vanilla glitch: 3 - 3 = 0, the monster never flees" or ""))
    local ok, f = drive(solo, function(ff) runAway(ff) end)
    check(ok, "block " .. c.label .. ": the fight ran to its end")
    check(textOf(f):find(c.line, 1, true) ~= nil, "block " .. c.label .. ": '" .. c.line .. "!'")
    eq(result, "run", "block " .. c.label .. ": run")
    eq(SESSION.safari.pkblkUses, 1, "block " .. c.label .. ": the Fan Club counts the throw (endBattleRse)")
    eq(SESSION.safari.balls, 30, "block " .. c.label .. ": no ball spent")
  end
end

-- (b) a slot with no block, a slot out of range, and FireRed: refused,
-- nothing touched
do
  emSafari()
  blockAt(2, { color = 1, spicy = 10 })
  local enc = { species = 128, level = 20 }
  local stand = standFor(enc, "EM_SAFARI_ZONE_SOUTH")
  local solo = newSolo()
  check(offer(solo, stand, enc), "block refused: taken")
  local fight = toMenu(solo)
  check(not throw(fight, "block", { block = 3 }), "block refused: an empty slot is refused")
  check(not throw(fight, "block"), "block refused: a throw naming no slot is refused")
  eq(Pokeblock.get(SESSION, 1).color, 1, "block refused: the case untouched")
  eq(fight.phase, "choose", "block refused: the menu stays open")
  eq(solo.sim.safari.pokeblockThrows, 0, "block refused: nothing thrown")
  solo:reset()

  frSafari()
  SESSION.pokeblocks = nil
  local encF = { species = 128, level = 20 }
  local standF = standFor(encF)
  local soloF = newSolo()
  check(offer(soloF, standF, encF), "block (FRLG): taken")
  local fightF = toMenu(soloF)
  check(not throw(fightF, "block", { block = 1 }), "block (FRLG): FireRed has no POKeBLOCK")
  eq(SESSION.pokeblocks, nil, "block (FRLG): no case made")
  soloF:reset()
end

-- (c) Go Near and the other cart's throws (the referee's)
do
  emSafari()
  local enc = { species = 128, level = 20 }
  local stand = standFor(enc, "EM_SAFARI_ZONE_SOUTH")
  local solo = newSolo()
  PIN_ESCAPE = 0
  check(offer(solo, stand, enc), "go near (EM): taken")
  local sim = solo.sim
  local ok, f = drive(solo, function(ff, turn)
    if turn == 1 then
      check(not throw(ff, "bait"), "go near (EM): BAIT is FireRed's")
      throw(ff, "near")
    else
      runAway(ff)
    end
  end)
  check(ok, "go near (EM): the fight ran to its end")
  eq(sim.safari.catchFactor, 6, "go near (EM): the cart's table raised the catch factor (0 + 6)")
  check(textOf(f):find("crept closer", 1, true) ~= nil, "go near (EM): 'ANN crept closer to ...'")
end

-- ===================================================================
-- 6. the full BOX
-- ===================================================================
do
  frSafari()
  SESSION.party = { lead(), lead(), lead(), lead(), lead(), lead() }
  FakeStorage.full = true
  local enc = { species = 115, level = 20 }
  local stand = standFor(enc)
  local solo = newSolo()
  PIN_ESCAPE = 0
  local result
  check(offer(solo, stand, enc, { done = function(r) result = r end }), "full box: taken")
  local sim = solo.sim
  local turns = {}
  local ok, f = drive(solo, function(ff, turn)
    turns[#turns + 1] = sim.turn
    if turn == 1 then
      check(throw(ff, "ball"), "full box: BALL closes the menu (the cart's selection script runs)")
    else
      runAway(ff)
    end
  end)
  check(ok, "full box: the fight ran to its end")
  check(textOf(f):find("STRINGID_BOXISFULL", 1, true) ~= nil,
        "full box: BattleScript_PrintFullBox's STRINGID_BOXISFULL")
  eq(table.concat(turns, ","), "1,1", "full box: the menu back on the same turn -- nothing spent")
  eq(SESSION.safari.balls, 30, "full box: no ball thrown")
  eq(result, "run", "full box: the player ran")
  eq(#SESSION.party, 6, "full box: nobody joined")

  -- A full party with room in the PC is no full BOX.
  frSafari()
  SESSION.party = { lead(), lead(), lead(), lead(), lead(), lead() }
  FakeStorage.full = false
  local out = safariFight("full party", 115, function(ff) throw(ff, "ball") end, { mon = { hp = 1 } })
  eq(out.result, "caught", "full party, room in the PC: the ball is thrown and catches")
  eq(#FakeStorage.sent, 1, "full party, room in the PC: ...sent to the PC")
end

-- ===================================================================
-- 7. the hand-back
-- ===================================================================
do
  -- FireRed: a ball thrown, then the referee gives up -- the door's restart
  -- (stand:fightAlone, src/Client.lua's own), with the ball already spent.
  frSafari()
  local enc = { species = 128, level = 20 }
  local stand = standFor(enc)
  local solo = newSolo()
  PIN_ESCAPE = 0
  fightAloneCalls = 0
  local doneCalls = 0
  check(offer(solo, stand, enc, { done = function() doneCalls = doneCalls + 1 end }), "hand-back (FRLG): taken")
  local fight = toMenu(solo)
  throw(fight, "ball")
  fight = toMenu(solo)
  check(fight ~= nil, "hand-back (FRLG): a second turn")
  eq(SESSION.safari.balls, 29, "hand-back (FRLG): the ball spent before the fault")
  solo:reset()
  eq(fightAloneCalls, 1, "hand-back (FRLG): the door's restart, once")
  eq(SESSION.safari.balls, 29, "hand-back (FRLG): ...with the ball already spent")
  eq(doneCalls, 0, "hand-back (FRLG): `done` is the cart's battle's to call")
  eq(#logged("warp"), 0, "hand-back (FRLG): no tail")

  -- Emerald: a POKeBLOCK thrown -- gone from the case, and counted for the
  -- Fan Club (the cart's battle that takes over counts only its own).
  emSafari()
  blockAt(1, { color = 1, spicy = 10 })
  local encE = { species = 128, level = 20 }
  local standE = standFor(encE, "EM_SAFARI_ZONE_SOUTH")
  local soloE = newSolo()
  PIN_ESCAPE = 0
  fightAloneCalls = 0
  check(offer(soloE, standE, encE), "hand-back (EM): taken")
  local fightE = toMenu(soloE)
  check(throw(fightE, "block", { block = 1 }), "hand-back (EM): the block is thrown")
  check(toMenu(soloE) ~= nil, "hand-back (EM): a second turn")
  soloE:reset()
  eq(fightAloneCalls, 1, "hand-back (EM): the door's restart")
  eq(Pokeblock.get(SESSION, 0).color, 0, "hand-back (EM): the block stays gone")
  eq(SESSION.safari.pkblkUses, 1, "hand-back (EM): its throw counted once")
  eq(#logged("runImmediately") + #logged("startScript"), 0, "hand-back (EM): no script")

  -- Nothing thrown: nothing counted.
  emSafari()
  local soloN = newSolo()
  check(offer(soloN, standFor(encE, "EM_SAFARI_ZONE_SOUTH"), encE), "hand-back (EM, nothing thrown): taken")
  soloN:reset()
  eq(SESSION.safari.pkblkUses, 0, "hand-back (EM, nothing thrown): nothing counted")
end

-- ===================================================================
-- 8. the pure helpers
-- ===================================================================
do
  eq(SafariKind.verdict3(0), 0, "verdict: gain 0 is curious")
  eq(SafariKind.verdict3(12), 1, "verdict: a gain is enthralled")
  eq(SafariKind.verdict3(-3), 2, "verdict: a loss is ignored")
  eq(SafariKind.verdict3(nil), nil, "verdict: no gain, no verdict")
  eq(SafariKind.nature3({ personality = 57 }), 7, "nature: the personality's (57 % 25)")
  eq(SafariKind.nature3({ nature = 4 }), 4, "nature: ...else the monster's own")
  local lists = SafariKind.rseTables3(SYNTH)
  eq(lists and #lists.pkblToEscape, 5, "tables: every row")
  eq(SafariKind.rseTables3({ goNearCounterToCatchFactor = { 1, 2, 3 },
    goNearCounterToEscapeFactor = { 1, 1, 1, 1 }, pkblToEscapeFactor = SYNTH.pkblToEscapeFactor }), nil,
    "tables: a short list is no table")
  eq(SafariKind.rseTables3({ goNearCounterToCatchFactor = { 1, 2, 3, 4 },
    goNearCounterToEscapeFactor = { 1, 1, 1, 1 }, pkblToEscapeFactor = { [0] = { 0, 0, 0 } } }), nil,
    "tables: fewer than four rows is no table")
  local s = {}
  check(SafariKind.writeBalls3(s, 300), "balls: written")
  eq(s.safari and s.safari.balls, 255, "balls: a u8")
  check(not SafariKind.writeBalls3(nil, 3), "balls: no session, nothing written")
  frSafari()
  check(not SafariKind.boxFull3(SESSION), "box: one monster in the party is no full BOX")
  SESSION.party = { lead(), lead(), lead(), lead(), lead(), lead() }
  FakeStorage.full = true
  check(SafariKind.boxFull3(SESSION), "box: six and no open box slot")
  SESSION.party[6] = { species = 0 }
  check(not SafariKind.boxFull3(SESSION), "box: an empty party slot is room")
  FakeStorage.full = false

  -- `takes`: the flags the core reads for a fight the party is not in.
  frSafari()
  local kind = SafariKind.kinds3.safari
  local ctx = { kind = "wild", family = "frlg", session = SESSION }
  check(kind:takes(ctx), "takes: a wild Safari fight is taken")
  eq(ctx.partyless, true, "takes: partyless (the screen's party is not seated)")
  eq(ctx.noReconcile, true, "takes: no reconcile (nothing of ours fought)")
  eq(ctx.lossless, true, "takes: lossless (out of balls is no defeat -- no whiteout)")
  eq(ctx.noPickup, true, "takes: no Pickup")
  eq(ctx.safari3 and ctx.safari3.balls, 30, "takes: the option read up front")
  local trainerCtx = { kind = "trainer", family = "frlg", session = SESSION }
  check(not kind:takes(trainerCtx), "takes: a trainer start is no Safari fight")
  eq(trainerCtx.partyless, nil, "takes: ...and is left alone")
end

Turn3.create, Mediated.new = realCreate, realNew

check(package.loaded["src.battle.BattleState"] == nil, "no Gen 1 BattleState on a Gen 3 boot")
check(not contains(warns, "ERROR"), "no error was logged: " .. table.concat(warns, " / "))
check(not contains(warns, "could not"), "no fallback warning fired: " .. table.concat(warns, " / "))
check(not contains(warns, "own rules failed"), "no kind hook threw: " .. table.concat(warns, " / "))

unstubAll()
T.finish("gen3_solo_safari")
