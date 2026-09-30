-- Headless Gen 3 co-op (Wave 4 T11): the Gen 3 arms of src/Coop.lua,
-- src/CoopBattle.lua, src/CoopSim.lua and src/CoopField.lua, and the
-- encounter divert src/Client.lua wires on a FireRed / Emerald boot.
--
-- The shape tests/gen3_mediated.lua set: a FireRed-shaped boot (the stub
-- facade says generation 3) over the engine SDK's own Gen 3 fixture
-- (T.sdk.gen3Data, synthetic numbers), the engine modules that would need an
-- imported cache stood in by small fakes that record what they were asked,
-- and the engine's own *pure* modules run for real (the exp curve, the game3
-- modal stack).  The referee is the real one twice over: src/Hub.lua opened
-- at generation 3, which seats the fight and runs src/BattleSim3, and the
-- screens are the real CoopBattle built through its real constructor.
--
--   1. the screen on Gen 3: no Gen 1 module asked for, the replay shell, C4
--      move rows, the cart's command grid;
--   2. a 2-on-2 against a trainer on a Gen 3 hub: uploads, battle_ready,
--      Gen 3 targeting (a SELECTED move may aim at the partner, a spread one
--      asks nobody), the C5 kinds (weather, ability, stat delta), the result;
--   3. a 2-on-2 against a wild: the knockout priced by Exp3 on the session
--      party, and a catch into the session party;
--   4. the stand-in and the ritual: prize (FireRed and Emerald rules, the
--      AMULET COIN), the trainer script's `done` after the screen is free,
--      the whiteout, a draw, the rival's heal-and-carry-on, blacksOut on the
--      live party, the invite joiner's trainer flag, the forget prompt;
--   5. divert decisions: which encounters a divert may take, the
--      BattleBridge.start wrap (take / refuse / hand back / restore);
--   6. prompts wait for the cart's own menus (Ui:whenFree, Gen3Ui.occupied);
--   7. the client's wiring through the real headless loader: encounter.roll
--      registered on Gen 3 only, inert for a lone player, cancelling when a
--      divert takes the encounter, and the trainer wrap installed from the
--      field;
--   8. Gold regressions: the item-effect table is Gen 2's, and an invite
--      joiner's prize lands in save.player.money.
--
-- Legal: every species, move, trainer and item row below is the SDK
-- fixture's or invented here with synthetic numbers; the only real values are
-- pret enum numbers the battle code branches on (MOVE_TARGET_*, HOLD_EFFECT_*,
-- ITEM_* ids), the policy docs/plans/gen3-battle-sheet.md states for the sim.
--
-- Run from the engine checkout root:
--
--   luajit mods/rby_mmo/tests/gen3_coop.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local check, eq = T.check, T.eq

local MOD_PATH = "mods/rby_mmo"
if not io.open(MOD_PATH .. "/src/CoopField.lua", "rb") then
  local src = debug.getinfo(1, "S").source
  if type(src) == "string" and src:sub(1, 1) == "@" then
    local dir = src:sub(2):match("(.+)[/\\]")
    if dir then MOD_PATH = dir:gsub("[/\\]tests$", "") end
  end
end
-- An out-of-tree checkout (an agetor worktree): load the files this suite was
-- read from, as the main suite does.
do
  local src = debug.getinfo(1, "S").source
  if type(src) == "string" and src:sub(1, 1) == "@" then
    local dir = src:sub(2):match("(.+)[/\\]")
    if dir then
      local fallback = dir:gsub("[/\\]tests$", "")
      local handle = io.open(fallback .. "/src/CoopField.lua", "rb")
      if handle then
        handle:close()
        MOD_PATH = fallback
      end
    end
  end
end

local function contains(list, needle)
  for _, line in ipairs(list) do
    if type(line) == "string" and line:find(needle, 1, true) then return true end
  end
  return false
end

-- ------------------------------------------------------------------
-- the facade and the module graph
-- ------------------------------------------------------------------

local warns = {}
local OPTIONS = {}
local SAVED = {}
local function stubFacade(generation)
  local facade = {
    id = "rby_mmo",
    path = MOD_PATH,
    generation = generation,
    exports = {},
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
    save = {
      get = function(_, key) return SAVED[key] end,
      set = function(_, key, value) SAVED[key] = value end,
    },
    events = { emit = function() end },
  }
  -- The loaded instance is this one (Cast / CoopField ask mod.find).
  facade.find = function() return { exports = facade.exports } end
  return facade
end
local stubMod = stubFacade(3)

local loadstr = loadstring or load
local function newNeed(facade)
  local cache = {}
  local function need(n)
    if cache[n] ~= nil then return cache[n] end
    local h = assert(io.open(MOD_PATH .. "/src/" .. n .. ".lua", "rb"))
    local body = h:read("*a")
    h:close()
    local chunk = assert(loadstr(body, "@" .. n .. ".lua"))
    local value = chunk(need, facade)
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

-- ------------------------------------------------------------------
-- the fixture, and the stand-in engine
-- ------------------------------------------------------------------

local DATA = T.sdk.gen3Data()
local P3 = DATA.gen3Pokemon
local ROM = DATA.gen3Moves._rom
local ITEMS = DATA.gen3Items._byId

-- More synthetic rows, in the fixture's own shapes.
ROM[45] = { effect = 18, power = 0, type = 0, accuracy = 100, pp = 40,
            secondaryChance = 0, target = 8, priority = 0, flags = 18 }
P3._moveNames[45] = "GROWL"
ROM[33].flags = 3
-- A spread move (MOVE_TARGET_BOTH) and a self move (MOVE_TARGET_USER).
ROM[57].target = 8
ROM[14] = { effect = 50, power = 0, type = 0, accuracy = 0, pp = 30,
            secondaryChance = 0, target = 16, priority = 0, flags = 0 }
P3._moveNames[14] = "SWORDS DANCE"
ITEMS[1] = { name = "MASTER BALL", pocket = "POKE_BALLS", price = 0 }
ITEMS[139] = { name = "ORAN BERRY", pocket = "BERRY_POUCH", price = 20,
               holdEffect = 1, holdEffectParam = 10 }
ITEMS[189] = { name = "AMULET COIN", pocket = "ITEMS", price = 100, holdEffect = 32 }
P3._abilityNames[2] = "DRIZZLE"
P3._learnsets[4] = { { 1, 10 }, { 7, 52 } }
P3._speciesMeta[16].evSpe = 1

local SESSION
local function newSession(extra)
  local s = {
    engine = "game3", generation = 3,
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
function FakeBag.has(bag, id, qty) return FakeBag.get(bag, id) >= (qty or 1) end
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

local FakePokemon = { FRIENDSHIP_EVENT_GROW_LEVEL = 0, NUMBERING_INTERNAL = "internal",
                      SPECIES_EGG = 412 }
function FakePokemon.name(sp) return P3._names[tonumber(sp)] end
function FakePokemon.keyName(sp) return P3._names[tonumber(sp)] end
function FakePokemon.speciesMeta(sp) return P3._speciesMeta[tonumber(sp)] end
function FakePokemon.stats(sp) return P3._stats[tonumber(sp)] end
function FakePokemon.speciesOf(mon) return tonumber(mon and (mon.species or mon.speciesId)) end
function FakePokemon.abilities(sp) return P3._abilities[tonumber(sp)] or { 0, 0 } end
function FakePokemon.abilityId(sp, personality)
  local pair = FakePokemon.abilities(sp)
  if pair[2] ~= 0 and (tonumber(personality) or 0) % 2 == 1 then return pair[2] end
  return pair[1]
end
function FakePokemon.natureId(personality) return (tonumber(personality) or 0) % 25 end
function FakePokemon.gender() return "M" end
function FakePokemon.isEgg(mon) return type(mon) == "table" and mon.isEgg == true end
function FakePokemon.movePp(id) local row = ROM[tonumber(id)] return row and row.pp or 0 end
function FakePokemon.movesAtLevel(sp, level)
  local moves, pp, maxPp = {}, {}, {}
  for _, row in ipairs(P3._learnsets[tonumber(sp)] or {}) do
    if row[1] <= level and #moves < 4 then
      moves[#moves + 1] = row[2]
      pp[#pp + 1] = FakePokemon.movePp(row[2])
      maxPp[#maxPp + 1] = FakePokemon.movePp(row[2])
    end
  end
  return moves, pp, maxPp
end
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
  local grew = mon.maxHp and (st.maxHp - mon.maxHp) or 0
  mon.maxHp = st.maxHp
  if mon.hp == nil then mon.hp = st.maxHp
  elseif grew > 0 then mon.hp = math.min(st.maxHp, mon.hp + grew) end
  if mon.hp > st.maxHp then mon.hp = st.maxHp end
  mon.attack, mon.defense, mon.speed = st.attack, st.defense, st.speed
  mon.spAtk, mon.spDef = st.spAtk, st.spDef
  return mon
end
function FakePokemon.gainEVs(mon, foe)
  local meta = P3._speciesMeta[tonumber(foe)] or {}
  mon.evs = mon.evs or {}
  mon.evs.spe = (mon.evs.spe or 0) + (meta.evSpe or 0)
  return 1
end
function FakePokemon.adjustFriendship(mon) mon.friendship = (mon.friendship or 70) + 5 end
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
      mon.pp[i], mon.maxPp[i] = ROM[id].pp, ROM[id].pp
      return true, i
    end
  end
  return false
end
function FakePokemon.isTradedMon() return false end
function FakePokemon.displayMonName(mon) return FakePokemon.name(mon.species) end
function FakePokemon.frontPic(sp) return { image = fakeImage("front" .. tostring(sp)), w = 64, h = 64 } end
function FakePokemon.backPic(sp) return { image = fakeImage("back" .. tostring(sp)), w = 64, h = 64 } end
function FakePokemon.monFrontPic(mon) return FakePokemon.frontPic(mon.species) end
function FakePokemon.monBackPic(mon) return FakePokemon.backPic(mon.species) end
function FakePokemon.icon(sp) return { image = fakeImage("icon" .. tostring(sp)), w = 32, h = 32, frames = 2, quads = {} } end
function FakePokemon.monIcon(mon) return FakePokemon.icon(mon.species) end

local FakeDex = {}
function FakeDex.isCaught(dex, sp) return dex.caught[tonumber(sp)] == true end
function FakeDex.registerCapture(dex, sp)
  local was = dex.caught[sp] == true
  dex.seen[sp], dex.caught[sp] = true, true
  return was
end
function FakeDex.handleSetPokedexFlag(dex, sp, caught)
  dex.seen[sp] = true
  if caught then dex.caught[sp] = true end
end

local FakeLearn = { begun = {} }
function FakeLearn.begin(opts)
  FakeLearn.begun[#FakeLearn.begun + 1] = opts
  if opts.onDone then opts.onDone(false) end
end

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

-- A deterministic RNG in the engine's two widths.
local rngState = 12345
local FakeRng = {}
function FakeRng.Random()
  rngState = (rngState * 1103515245 + 12345) % 2147483648
  return math.floor(rngState / 65536) % 65536
end
function FakeRng.Random32() return FakeRng.Random() * 65536 + FakeRng.Random() end

-- The cart's link codec, reduced to what a round trip keeps.
local FakeProtocol = {}
function FakeProtocol.packMon3(mon)
  local moves, pp = {}, {}
  for i, id in ipairs(mon.moves or {}) do moves[i] = id; pp[i] = (mon.pp or {})[i] end
  return {
    species = tonumber(mon.species), level = mon.level, hp = mon.hp, status = mon.status,
    personality = mon.personality, ivs = mon.ivs, evs = mon.evs, ability = mon.ability,
    moves = moves, pp = pp, item = mon.heldItem or 0, nickname = mon.nickname,
    friendship = mon.friendship, gender = mon.gender, isEgg = mon.isEgg,
  }
end
function FakeProtocol.unpackMon3(_, packed)
  if type(packed) ~= "table" or not P3._stats[tonumber(packed.species)] then
    return nil, "unknown species"
  end
  local mon = {
    species = packed.species, speciesId = packed.species, level = packed.level,
    personality = packed.personality, nature = (packed.personality or 0) % 25,
    ivs = packed.ivs, evs = packed.evs, ability = packed.ability,
    moves = {}, pp = {}, maxPp = {}, heldItem = packed.item, item = packed.item,
    nickname = packed.nickname or "", friendship = packed.friendship, gender = packed.gender,
    growthRate = P3._speciesMeta[packed.species].growthRate,
  }
  for i, id in ipairs(packed.moves or {}) do
    mon.moves[i] = id
    mon.maxPp[i] = FakePokemon.movePp(id)
    mon.pp[i] = packed.pp and packed.pp[i] or mon.maxPp[i]
  end
  FakePokemon.applyStats(mon)
  mon.hp = math.min(packed.hp or mon.maxHp, mon.maxHp)
  return mon
end

-- The cart's battle entry, whiteout, field and script VM, recording.
local rec = {}
local function note(kind, ...) rec[#rec + 1] = { kind = kind, ... } end
local function recorded(kind)
  local n = 0
  for _, r in ipairs(rec) do if r.kind == kind then n = n + 1 end end
  return n
end
local FakeBB = {}
function FakeBB.start(_, _, foe, opts)
  note("engineStart", foe, opts)
  return true
end
function FakeBB.startWild(modArg, game, enc, opts)
  opts = opts or {}
  opts.wild = true
  return FakeBB.start(modArg, game, enc, opts)
end
function FakeBB.applyWhiteoutMoneyLoss(session)
  note("moneyLoss")
  local before = session.money
  session.money = math.floor(session.money / 2)
  return before - session.money, session.money
end
function FakeBB.applyLeagueFriendship() note("league") end
local FakeField = {}
function FakeField.respawnAtHeal()
  note("respawn")
  SESSION.map = "HEAL"
end
local FakeParty = {}
function FakeParty.healAll(party)
  note("heal")
  for _, mon in ipairs(party or {}) do mon.hp = mon.maxHp; mon.status = nil end
end
local STORE = { flags = {} }
local FakeFlags = {}
function FakeFlags.trainerFlagId(id) return 0x500 + tonumber(id) end
function FakeFlags.setFlag(store, _, id, on) store.flags[id] = on end
function FakeFlags.getFlag(store, _, id) return store.flags[id] end
local FakeSpace = { store = STORE }
function FakeSpace.getStore() return STORE end
function FakeSpace.returnToField() note("returnToField") end
local FakeNatives = {}
function FakeNatives.outcome_to_code(r)
  if r == "win" then return 1 elseif r == "lose" then return 2 elseif r == "draw" then return 3 end
  return 1
end

-- Two synthetic trainers: 326 (the SDK's), and a double-battle one whose lead
-- has DRIZZLE.
local TRAINERS = {
  [326] = { class = 81, className = "RIVAL", name = "TERRY", pic = 5, items = { 13, 0, 0, 0 },
            lastLevel = 5, doubleBattle = false,
            party = { { species = 4, level = 5, iv = 0 } } },
  [400] = { class = 44, className = "PKMN TRAINER", name = "DUO", pic = 9, items = { 0, 0, 0, 0 },
            lastLevel = 6, doubleBattle = true,
            party = { { species = 151, level = 6, iv = 0, moves = { 33 } },
                      { species = 16, level = 6, iv = 0, moves = { 33 } } } },
}
local FakeTrainers = {}
function FakeTrainers.get(id)
  local t = TRAINERS[tonumber(id)]
  if not t then return nil end
  local out = {}
  for k, v in pairs(t) do out[k] = v end
  out.id = tonumber(id)
  return out
end
function FakeTrainers.info(id) return FakeTrainers.get(id) end
function FakeTrainers.foeFromId(id)
  local t = TRAINERS[tonumber(id)]
  if not t then return nil end
  local party = {}
  for i, m in ipairs(t.party) do
    party[i] = { species = m.species, level = m.level,
                 ivs = { hp = m.iv, atk = m.iv, def = m.iv, spa = m.iv, spd = m.iv, spe = m.iv },
                 evs = { hp = 0, atk = 0, def = 0, spa = 0, spd = 0, spe = 0 },
                 moves = m.moves, trainerId = tonumber(id) }
  end
  local lead = party[1]
  return { species = lead.species, level = lead.level, ivs = lead.ivs, evs = lead.evs,
           moves = lead.moves, trainerId = tonumber(id), items = t.items, party = party,
           trainerName = t.name, trainerClass = t.class, trainerClassName = t.className,
           trainerPic = t.pic, doubleBattle = t.doubleBattle }
end

-- The prize formula's shape (battle/prize.lua), with a flat class value.
local FakePrize = {}
function FakePrize.calc(tid, opts)
  opts = opts or {}
  local info = FakeTrainers.info(tid) or {}
  local mult = opts.moneyMultiplier or 1
  return 4 * (opts.lastLevel or info.lastLevel or 1) * mult * (opts.double and 2 or 1) * 10
end
function FakePrize.rewardRse(tid, opts)
  opts = opts or {}
  local info = FakeTrainers.info(tid) or {}
  return 4 * (info.lastLevel or 1) * (opts.moneyMultiplier or 1) * (opts.double and 2 or 1) * 7
end
local FakeProfile = {}
function FakeProfile.get(session)
  local rse = session and session.version == "emerald"
  return { family = rse and "rse" or "frlg", safari = false, kinds = { ghost = not rse },
           rules = { money = rse and "rse" or "frlg", whiteout = rse and "half" or "frlg" } }
end
local encReset = 0
local FakeEncounters = { rules = function() return { wildHeldItem = function() return 0 end } end,
                         resetRateModifiers = function() encReset = encReset + 1 end }
local FakeSafari = { isActive = function(session) return session and session.safariOn == true end }

local function installStubs()
  stub("src.core.game3.runtime", { getSession = function() return SESSION end,
                                   _mod = "ENGINE_MOD" })
  stub("src.core.game3.pokemon", FakePokemon)
  stub("src.core.game3.bag", FakeBag)
  stub("src.core.game3.dex", FakeDex)
  stub("src.core.game3.battle.learn_move", FakeLearn)
  stub("src.ui.game3.summary_menu", { openMenu = function() end })
  stub("src.core.game3.audio", FakeAudio)
  stub("src.core.game3.battle", { isActive = function() return false end })
  stub("src.core.game3.battle.catching", { playerSecretId = function(s) return s.secretId end })
  stub("src.core.game3.constants", { of = function()
    return { song = function() return 7 end, id = function() return nil end,
             name = function() return nil end }
  end })
  stub("src.core.game3.rng", FakeRng)
  stub("src.link.Protocol", FakeProtocol)
  stub("src.core.game3.battle_bridge", FakeBB)
  stub("src.core.game3.field", FakeField)
  stub("src.core.game3.party", FakeParty)
  stub("src.core.game3.scripting.flags", FakeFlags)
  stub("src.core.game3.scripting.space", FakeSpace)
  stub("src.core.game3.scripting.natives", FakeNatives)
  stub("src.core.game3.scripting.trainers", FakeTrainers)
  stub("src.core.game3.battle.prize", FakePrize)
  stub("src.core.game3.battle.profile", FakeProfile)
  stub("src.core.game3.encounters", FakeEncounters)
  stub("src.core.game3.safari", FakeSafari)
  stub("src.core.game3.capabilities", { gate = function() return false end })
  stub("src.core.game3.evolution", { levelTarget = function() return nil end })
  stub("src.ui.game3.evolution_scene", { start = function() return false end })
  stub("src.core.game3.storage", { sendMonToPC = function(session, mon)
    session.pc = session.pc or {}
    session.pc[#session.pc + 1] = mon
    return true
  end })
end
installStubs()

-- Asking for the Gen 1 battle engine on a Gen 3 boot is the bug this file
-- exists to keep out (on Emerald it is a boot error and a dead module).
local gen1Asked = {}
for _, name in ipairs({ "src.battle.BattleState", "src.battle.Damage",
                        "src.battle.TurnOrder", "src.battle.Experience",
                        "src.core.Sound", "src.core.Music" }) do
  package.loaded[name] = nil
  package.preload[name] = function()
    gen1Asked[#gen1Asked + 1] = name
    error("Gen 1 module " .. name .. " required on a Gen 3 boot")
  end
end

local Experience = require("src.core.game3.battle.experience")
local Stack = require("src.ui.game3.stack")

local need = newNeed(stubMod)
local Config = need("Config")
local Wire = need("Wire")
local Gen3Ui = need("Gen3Ui")
local Sheet3 = need("Sheet3")
local CoopSim = need("CoopSim")
local CoopField = need("CoopField")
local CoopBattle = need("CoopBattle")
local Coop = need("Coop")
local Hub = need("Hub")

local function fakeInput(key)
  return { pressed = {}, wasPressed = function(_, k) return key ~= nil and k == key end,
           isDown = function() return false end }
end

local GAME
local function newGame(sessionExtra)
  SESSION = newSession(sessionExtra)
  GAME = { generation = 3, phase = "field", data = DATA, session = SESSION,
           save = { engine = "game3", generation = 3, money = SESSION.money },
           input = fakeInput() }
  stubMod.game = GAME
  Stack.clear()
  rec = {}
  STORE.flags = {}
  CoopField.resetDeferred3()
  return GAME
end

-- A FireRed-shaped party mon, the way party.lua's giveMon leaves one.
local function monOf(species, level, extra)
  local growth = P3._speciesMeta[species].growthRate
  local mon = {
    species = species, speciesId = species, level = level,
    nickname = "", growthRate = growth,
    exp = Experience.expForLevel(growth, level),
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

local function copyTable(t)
  local out = {}
  for k, v in pairs(t) do out[k] = v end
  return out
end

-- ------------------------------------------------------------------
-- 1. the screen on Gen 3
-- ------------------------------------------------------------------

-- Four seats the way src/Coop.lua's startBattle hands them over: our own live
-- party, the partner's unpacked, the trainer's team dealt into two buckets.
local function npcSeats(game, trainerId)
  local foe = FakeTrainers.foeFromId(trainerId)
  local party = assert(CoopField.trainerParty3(foe))
  local packed = assert(CoopBattle.packParty(party, game))
  local b1, b2 = {}, {}
  for i, mon in ipairs(assert(CoopBattle.unpackParty(game, packed))) do
    if i % 2 == 1 then b1[#b1 + 1] = mon else b2[#b2 + 1] = mon end
  end
  return b1, b2, CoopField.trainerRecord3(foe)
end

local function buildScreen(game, opts)
  local screen, why = CoopBattle.new(game, opts)
  return screen, why
end

do
  newGame()
  local mine = monOf(4, 12, { moves = { 33, 57, 14 }, pp = { 35, 15, 30 }, maxPp = { 35, 15, 30 } })
  SESSION.party = { mine }
  local partner = assert(CoopBattle.unpackParty(GAME, assert(CoopBattle.packParty({ monOf(16, 12) }, GAME))))
  local b1, b2, trainer = npcSeats(GAME, 400)
  local screen, why = buildScreen(GAME, {
    slots = {
      { side = "a", owner = "me", name = "ANN", party = SESSION.party },
      { side = "a", owner = "p2", name = "BOB", party = partner },
      { side = "b", name = "DUO", party = b1 },
      { side = "b", name = "DUO", party = b2 },
    },
    mine = 1, host = true, mode = "coop_npc", trainer = trainer, trainerPic = trainer.trainerPic,
    selfId = "me", battleId = "c1",
  })
  check(screen ~= nil, "the co-op screen builds on a Gen 3 boot (" .. tostring(why) .. ")")
  eq(#gen1Asked, 0, "and nothing of Gen 1's battle engine was asked for")
  eq(screen.gen3, true, "the screen knows it is Gen 3")
  eq(screen.sim.gen2NoHostSim, true, "the field is a replay shell: the hub rolls")
  eq(screen.sim.makeBattler, nil, "no Gen 1 makeBattler on the field")
  local battler = screen.sim:slot(1).battler
  eq(battler.mon, mine, "our seat fights with the live session mon")
  eq(battler.name, "CHARMANDER", "named the way the sheet narrates it")
  eq(battler.curMoves[1].id, "TACKLE", "FIGHT lists C4 rows (the token)")
  eq(battler.curMoves[1].name, "TACKLE", "...with the cart's name")
  eq(battler.curMoves[2].target, 8, "...and the move's MOVE_TARGET_* bits")
  check(battler.sprite ~= nil and battler.sprite.tag == "back4", "our seat wears the cart's back pic")
  check(screen.sim:slot(3).battler.sprite.tag == "front151", "a foe wears its front pic")
  eq(screen:commandList()[2], "ITEM", "the cart's grid: FIGHT BAG / POKeMON RUN")
  eq(screen:bandCommandItems()[3].label, "POKéMON", "in the cart's words")
  eq(screen:moveLabel("SURF"), "SURF", "a move is named off our own rows")
  eq(screen:moveTypeName("SURF"), nil, "an unnamed type reads as nothing, not a crash")

  -- Targeting: a SELECTED move asks about both foes and the partner; a
  -- spread / self move asks nobody.
  local choices = screen:targetChoices()
  eq(#choices, 3, "Gen 3 doubles: both foes and the partner can be aimed at")
  eq(choices[1].side, "b", "foes first")
  eq(choices[3].index, 2, "the partner last")
  eq(screen:needsTarget(battler.curMoves[1]), true, "TACKLE (SELECTED) opens the picker")
  eq(screen:needsTarget(battler.curMoves[2]), false, "SURF (BOTH) is aimed at nobody")
  eq(screen:needsTarget(battler.curMoves[3]), false, "SWORDS DANCE (USER) is aimed at nobody")
  eq(screen:drawsWidescreen(), screen:usesBattlefield(), "Gen 3 paints the arena in window space")
  eq(CoopBattle.allyPicScale(GAME), 1, "a 64x64 back is not doubled")
end


-- ------------------------------------------------------------------
-- 2. a 2-on-2 against a trainer, refereed by a Gen 3 hub
-- ------------------------------------------------------------------

local function testPlayerId(seed)
  local s = tostring(seed or "")
  local out = {}
  for i = 1, 32 do
    local c = s:byte((i - 1) % #s + 1) or 97
    out[i] = string.format("%x", (c + i) % 16)
  end
  return table.concat(out)
end

local function join3(hub, name, version)
  local peer = { outbox = {} }
  function peer:send(msg) self.outbox[#self.outbox + 1] = msg end
  function peer:close() end
  local client = hub:accept(peer)
  hub:receive(client, { type = Wire.HELLO, proto = Config.PROTOCOL,
    name = name, map = "FR_ROUTE_1", x = 5, y = 5, facing = "down",
    generation = 3, version = version or "firered", playerId = testPlayerId(name) })
  return client, peer
end

-- A screen's transport: what it sends reaches the hub as its own client.
local function transportFor(hub, client)
  return {
    sent = {},
    isReady = function() return true end,
    send = function(self, kind, msg)
      local payload = copyTable(msg)
      payload.type = kind
      self.sent[#self.sent + 1] = payload
      hub:receive(client, payload)
    end,
  }
end

-- Deliver what the hub told a peer to that peer's screen, through the client
-- sanitisers the real dispatch runs (Coop.onBattleReady / Event / Outcome).
local function deliver(peer, screen)
  local box = peer.outbox
  peer.outbox = {}
  for _, msg in ipairs(box) do
    if msg.type == Wire.BATTLE_READY then
      local clean = Wire.battleReady(msg)
      if clean then screen:onBattleReady(clean) end
    elseif msg.type == Wire.BATTLE_EVENT then
      local clean = Wire.battleEvent(msg, 3)
      if clean then screen:onBattleEvent(clean) end
    elseif msg.type == Wire.BATTLE_OUTCOME then
      local clean = Wire.battleOutcome(msg)
      if clean then screen:onBattleOutcome(clean) end
    end
  end
end

-- Let a screen read its queue down to the next menu (or the end).
local function settle(screen)
  for _ = 1, 600 do
    screen:update(2.0)
    if screen.finished or screen.phase == "choose" or screen.replacing then return end
  end
end

do
  newGame()
  local mine = monOf(4, 20, { moves = { 33, 57 }, pp = { 35, 15 }, maxPp = { 35, 15 } })
  SESSION.party = { mine }
  local partnerParty = assert(CoopBattle.unpackParty(GAME,
    assert(CoopBattle.packParty({ monOf(16, 20, { moves = { 33 }, pp = { 35 }, maxPp = { 35 } }) }, GAME))))
  local b1, b2, trainer = npcSeats(GAME, 400)
  -- The trainer's lead brings the rain in with it.
  b1[1].ability = 2

  local hub = Hub.new({ maxPlayers = 4, generation = 3 })
  hub.forceBattleSeed = 5
  local ann, annPeer = join3(hub, "ANN", "firered")
  local bob, bobPeer = join3(hub, "BOB", "emerald")
  hub:openCoopBattle("cb1", { ann.id, bob.id }, { mode = "coop_npc", hostId = ann.id })
  local record = hub.battles["cb1"]
  check(record ~= nil and #(record.npcIds or {}) == 2, "the Gen 3 hub holds two trainer seats")

  local slots = {
    { side = "a", owner = ann.id, name = "ANN", party = SESSION.party },
    { side = "a", owner = bob.id, name = "BOB", party = partnerParty },
    { side = "b", name = "DUO", party = b1 },
    { side = "b", name = "DUO", party = b2 },
  }
  local hostT, guestT = transportFor(hub, ann), transportFor(hub, bob)
  local host = assert(CoopBattle.new(GAME, { slots = slots, mine = 1, host = true,
    mode = "coop_npc", trainer = trainer, trainerPic = trainer.trainerPic,
    transport = hostT, battleId = "cb1", selfId = ann.id }))
  local guest = assert(CoopBattle.new(GAME, { slots = slots, mine = 2, host = false,
    mode = "coop_npc", trainer = trainer, transport = guestT, battleId = "cb1",
    selfId = bob.id }))
  local linkAsked = {}
  local realMons = Sheet3.mons
  Sheet3.mons = function(game, party, opts)
    linkAsked[#linkAsked + 1] = opts and opts.link or false
    return realMons(game, party, opts)
  end
  host:enter()
  guest:enter()
  Sheet3.mons = realMons
  check(#linkAsked >= 2, "the players' and the trainer's sheets are built")
  local anyLink = false
  for _, v in ipairs(linkAsked) do anyLink = anyLink or v == true end
  eq(anyLink, false, "none as a link battle's: a trainer fight is the cart's own")

  local partyUp, rules, npcUp
  for _, msg in ipairs(hostT.sent) do
    if msg.type == Wire.BATTLE_PARTY and msg.side == "b" then npcUp = msg
    elseif msg.type == Wire.BATTLE_PARTY then partyUp = msg
    elseif msg.type == Wire.BATTLE_RULESET then rules = msg end
  end
  eq(partyUp and partyUp.generation, 3, "the host uploads a Gen 3 party")
  eq(partyUp and partyUp.mons[1].catchRate, nil, "our own sheets carry no catch rate")
  eq(partyUp and partyUp.mons[1].moves[2].target, 8, "the move rows carry their target bits")
  check(rules ~= nil and rules.generation == 3, "the host uploads the Gen 3 ruleset")
  eq(npcUp and #npcUp.mons, 2, "and the trainer's team as side b")
  eq(npcUp and npcUp.mons[1].ability, 2, "with the lead's ability on its sheet")
  check(record.sim ~= nil, "with every upload in, the Gen 3 hub referees")
  eq(record.sim and record.sim.byId and record.sim.byId[ann.id] ~= nil, true,
     "the host's seat is the host's")

  deliver(annPeer, host)
  deliver(bobPeer, guest)
  eq(host.mediated, true, "battle_ready reaches the host's screen")
  eq(guest.mediated, true, "and the guest's")
  eq(host.medSlots[0], 1, "field slot 0 is the host")
  eq(host.medSlots[3], 3, "field slot 3 is the trainer's first seat")
  settle(host)
  settle(guest)
  eq(host.weatherShown, "RAIN", "DRIZZLE's rain is over the field once its row played")
  eq(host.phase, "choose", "the host's command grid opens")

  -- A SELECTED move aimed at the partner goes out as the partner's field slot.
  host:commit({ slot = 1, move = 1, target = 2 })
  local choice = hostT.sent[#hostT.sent]
  eq(choice.type, Wire.BATTLE_CHOICE, "the host's choice goes out")
  eq(choice.target, 1, "aimed at the partner's field slot")
  guest:commit({ slot = 2, move = 1, target = 3 })
  deliver(annPeer, host)
  deliver(bobPeer, guest)
  settle(host)
  local pidgey = host.sim:slot(2).battler.mon
  check(pidgey.hp < pidgey.maxHp, "the partner took the host's TACKLE (" .. tostring(pidgey.hp)
    .. "/" .. tostring(pidgey.maxHp) .. ")")

  local guard = 0
  while not host.finished and guard < 60 do
    guard = guard + 1
    deliver(annPeer, host)
    deliver(bobPeer, guest)
    settle(host)
    settle(guest)
    if host.phase == "choose" and not host.result then
      host:commit({ slot = 1, move = 2, target = 3 })   -- SURF: both foes
    end
    if guest.phase == "choose" and not guest.result then
      guest:commit({ slot = 2, move = 1, target = 3 })
    end
    if host.replacing or guest.replacing then break end
    if host.result and guest.result then
      for _ = 1, 50 do host:update(2.0); guest:update(2.0) end
      break
    end
  end
  check(host.result == "win" or host.result == "loss",
        "the fight reaches a result (" .. tostring(host.result) .. ")")
  check(guard > 1, "over more than one turn")
  eq(host.result, guest.result, "and both screens agree about it")
  eq(#gen1Asked, 0, "still nothing of Gen 1's was asked for")
end


-- ------- party against party: four players, two sides, one Gen 3 hub

do
  newGame()
  local hub = Hub.new({ maxPlayers = 4, generation = 3 })
  hub.forceBattleSeed = 13
  local names = { "ANN", "BOB", "CAL", "DEE" }
  local clients, peers = {}, {}
  for i, name in ipairs(names) do clients[i], peers[i] = join3(hub, name, i % 2 == 0 and "emerald" or "firered") end
  local ids = {}
  for i = 1, 4 do ids[i] = clients[i].id end
  hub:openCoopBattle("pv1", ids, { mode = "coop_pvp", hostId = ids[1],
    sides = { a = { ids[1], ids[2] }, b = { ids[3], ids[4] } } })
  local function party(sp, lv, hp)
    return assert(CoopBattle.unpackParty(GAME, assert(CoopBattle.packParty(
      { monOf(sp, lv, { moves = { 33 }, pp = { 35 }, maxPp = { 35 }, hp = hp }) }, GAME))))
  end
  local parties = { party(4, 30), party(16, 30), party(29, 8, 5), party(151, 8, 5) }
  local slots = {}
  for i = 1, 4 do
    slots[i] = { side = i <= 2 and "a" or "b", owner = ids[i], name = names[i], party = parties[i] }
  end
  local screens, transports = {}, {}
  local linkAsked = {}
  local realMons = Sheet3.mons
  Sheet3.mons = function(game, party, opts)
    linkAsked[#linkAsked + 1] = opts and opts.link
    return realMons(game, party, opts)
  end
  for i = 1, 4 do
    transports[i] = transportFor(hub, clients[i])
    screens[i] = assert(CoopBattle.new(GAME, { slots = slots, mine = i, host = i == 1,
      mode = "coop_pvp", transport = transports[i], battleId = "pv1",
      selfId = ids[i], ranksPoints = true }))
    screens[i]:enter()
  end
  Sheet3.mons = realMons
  eq(#linkAsked, 4, "four sheets, one per player")
  check(linkAsked[1] == true and linkAsked[2] == true and linkAsked[3] == true
        and linkAsked[4] == true, "each a link battle's sheet (Deoxys on its link stats)")
  local sides = {}
  for i = 1, 4 do
    for _, msg in ipairs(transports[i].sent) do
      if msg.type == Wire.BATTLE_PARTY then
        sides[i] = msg.side
        eq(msg.generation, 3, names[i] .. " uploads a Gen 3 party")
      end
    end
  end
  eq(table.concat({ sides[1] or "?", sides[2] or "?", sides[3] or "?", sides[4] or "?" }), "aabb",
     "each player uploads its own party, on its own side")
  check(hub.battles["pv1"] and hub.battles["pv1"].sim ~= nil,
        "party vs party: four uploads and the Gen 3 hub referees")
  local guard = 0
  while guard < 40 and not (screens[1].result and screens[3].result) do
    guard = guard + 1
    for i = 1, 4 do deliver(peers[i], screens[i]) end
    for i = 1, 4 do
      settle(screens[i])
      local sc = screens[i]
      if sc.phase == "choose" and not sc.result then
        local aim = sc:targetChoices()[1]
        sc:commit({ slot = i, move = 1, target = aim and aim.index })
      end
    end
  end
  eq(screens[1].result, "win", "party vs party: the stronger side wins")
  eq(screens[2].result, "win", "on both of its screens")
  eq(screens[3].result, "loss", "and the other side loses")
  eq(screens[4].result, "loss", "on both of its screens")
  eq(#gen1Asked, 0, "and no side asked for anything of Gen 1's")
end

-- ------- the C5 kinds, one at a time (synthetic events on a mediated screen)

do
  newGame()
  local mine = monOf(4, 20, { heldItem = 139, item = 139 })
  SESSION.party = { mine }
  local partnerParty = { monOf(16, 20) }
  local b1, b2, trainer = npcSeats(GAME, 400)
  local screen = assert(CoopBattle.new(GAME, {
    slots = {
      { side = "a", owner = "me", name = "ANN", party = SESSION.party },
      { side = "a", owner = "p2", name = "BOB", party = partnerParty },
      { side = "b", name = "DUO", party = b1 },
      { side = "b", name = "DUO", party = b2 },
    },
    mine = 1, host = true, mode = "coop_npc", trainer = trainer, selfId = "me", battleId = "k1",
  }))
  screen.medMine = Sheet3.mons(GAME, SESSION.party, {})
  screen:onBattleReady({ battle = "k1", mode = "coop_npc",
    sides = { a = { "me", "p2" }, b = { "n1", "n2" } } })
  local function rowsOf(ev)
    ev.battle = "k1"
    return screen:medRows(ev)
  end
  local rows = rowsOf({ t = "stat", slot = 3, side = "b", text = "ANN's X rose!",
                        stat = "atk", stage = -1, delta = -1 })
  eq(rows[1] and rows[1].kind, "vfx", "a stat change draws on the seat")
  eq(rows[1] and rows[1].spec and rows[1].spec.style,
     (need("Vfx").forStat(-1) or {}).style, "a drop reads off `delta`, whatever the sentence says")
  rows = rowsOf({ t = "weather", text = "SUN", amount = 1 })
  eq(rows[1] and rows[1].kind, "state3", "weather is a state row")
  screen:playEvents(rows)
  for _ = 1, 20 do screen:update(2.0) end
  eq(screen.weatherShown, "SUN", "applied when its row plays")
  screen:playEvents(rowsOf({ t = "weather", text = "SUN", amount = 0 }))
  for _ = 1, 20 do screen:update(2.0) end
  eq(screen.weatherShown, nil, "and the sky clears when it ends")
  rows = rowsOf({ t = "ability", slot = 3, side = "b", amount = 2, text = "DRIZZLE" })
  eq(rows[1] and rows[1].kind, "vfx", "an ability shines on its seat")
  eq(screen.sim:slot(3).battler.ability.id, 2, "and the seat remembers which")
  rows = rowsOf({ t = "sub", slot = 3, side = "b", amount = 1 })
  screen:playEvents(rows)
  for _ = 1, 20 do screen:update(2.0) end
  eq(screen.sim:slot(3).substitute, true, "a Substitute doll stands on the seat")
  local seats = screen:battlefieldSeats(true)
  eq(seats[1] and seats[1].substitute, true, "and the arena is told")
  rows = rowsOf({ t = "held", slot = 0, side = "a", mon = 0, amount = 139, holding = 0,
                  text = "ORAN BERRY" })
  eq(mine.heldItem, 0, "a berry eaten in the fight is gone from the session mon")
  rows = rowsOf({ t = "held", slot = 1, side = "a", mon = 0, amount = 139, holding = 0 })
  eq(partnerParty[1].heldItem, 0, "a partner's seat is theirs to write, not ours")
  rows = rowsOf({ t = "ball", slot = 0, side = "a", target = 3, amount = 2, text = "4" })
  local anims = {}
  for _, r in ipairs(rows) do anims[#anims + 1] = r.anim end
  eq(table.concat(anims, ","), "TOSS_ANIM,POOF_ANIM,HIDEPIC_ANIM,SHAKE_ANIM,POOF_ANIM,SHOWPIC_ANIM",
     "a two-shake break-out is the ball flow's six rows")
  rows = rowsOf({ t = "anim", slot = 0, side = "a", text = "SURF", target = 4, spread = 1 })
  eq(rows[1] and rows[1].to, 4, "a Gen 3 anim names where the move went")
  eq(rows[1] and rows[1].spread, true, "and that it spread")
  rows = rowsOf({ t = "form", slot = 3, side = "b", speciesId = "16" })
  screen:playEvents(rows)
  for _ = 1, 20 do screen:update(2.0) end
  eq(screen.sim:slot(3).transformId, 16, "a Transform changes the seat's picture")
  local model = screen:gen3ClassicModel()
  check(model.foe ~= nil and model.ally ~= nil, "the GBA page has a focused pair")
  check(model.foeStrip ~= nil and #model.foeStrip.seats == 2, "and a rail of the trainer's two seats")
end

-- ------- held items and the exp award's roster (MediatedBattle's twins)

do
  newGame()
  local lead = monOf(4, 20, { heldItem = 139, item = 139 })
  local bench = monOf(151, 18)
  SESSION.party = { lead, bench }
  local partnerParty = { monOf(16, 20) }
  local b1, b2, trainer = npcSeats(GAME, 400)
  local screen = assert(CoopBattle.new(GAME, {
    slots = {
      { side = "a", owner = "me", name = "ANN", party = SESSION.party },
      { side = "a", owner = "p2", name = "BOB", party = partnerParty },
      { side = "b", name = "DUO", party = b1 },
      { side = "b", name = "DUO", party = b2 },
    },
    mine = 1, host = true, mode = "coop_npc", trainer = trainer, selfId = "me", battleId = "h1",
  }))
  screen.medMine = Sheet3.mons(GAME, SESSION.party, {})
  screen:onBattleReady({ battle = "h1", mode = "coop_npc",
    sides = { a = { "me", "p2" }, b = { "n1", "n2" } } })
  screen:medRows({ battle = "h1", t = "held", slot = 0, side = "a", mon = 0, amount = 200,
                   holding = 200 })
  eq(lead.heldItem, 139, "an item nothing of ours brought never enters the save")
  eq(screen.medMine[1].heldItem, 200, "though the fight's own sheet shows it")
  screen:medRows({ battle = "h1", t = "held", slot = 0, side = "a", mon = 0, amount = 139,
                   holding = 0 })
  eq(lead.heldItem, 0, "a trainer fight keeps the cart's rule: a berry eaten is gone")

  -- The award asks the referee's roster who is standing, not the party's HP.
  screen:medRows({ battle = "h1", t = "team", slot = 0, side = "a", team = "ox" })
  local alive = screen:standingInFight3()
  eq(alive(1), true, "the lead stands, by the roster")
  eq(alive(2), false, "the bench mon is down in this fight, whatever its HP says")
  local Exp3 = need("Exp3")
  local realAward, seen = Exp3.award, nil
  Exp3.award = function(ko, opts) seen = { ko = ko, opts = opts }; return {} end
  screen:gainExp3({ batch = { species = 16, level = 5, sentIn = { [1] = true } } })
  Exp3.award = realAward
  eq(seen and seen.ko.battle, screen, "the award names the fight for exp.gain")
  eq(seen and seen.opts and seen.opts.alive and seen.opts.alive(2), false,
     "and hands Exp3 the roster's answer")
  screen.myTeam3 = nil
  eq(screen:standingInFight3()(2), true, "with no roster yet, the party's HP answers")
end

do
  newGame()
  local lead = monOf(4, 20, { heldItem = 139, item = 139 })
  SESSION.party = { lead }
  local slots = {
    { side = "a", owner = "me", name = "ANN", party = SESSION.party },
    { side = "a", owner = "p2", name = "BOB", party = { monOf(16, 20) } },
    { side = "b", owner = "p3", name = "CAL", party = { monOf(29, 20) } },
    { side = "b", owner = "p4", name = "DEE", party = { monOf(151, 20) } },
  }
  local screen = assert(CoopBattle.new(GAME, { slots = slots, mine = 1, host = true,
    mode = "coop_pvp", selfId = "me", battleId = "h2" }))
  screen.medMine = Sheet3.mons(GAME, SESSION.party, { link = true })
  screen:onBattleReady({ battle = "h2", mode = "coop_pvp",
    sides = { a = { "me", "p2" }, b = { "p3", "p4" } } })
  screen:medRows({ battle = "h2", t = "held", slot = 0, side = "a", mon = 0, amount = 139,
                   holding = 0 })
  eq(lead.heldItem, 139, "a spar between players moves nothing in the save")
  eq(screen.medMine[1].heldItem, 0, "only the fight's sheet")
end

-- ------------------------------------------------------------------
-- 3. a 2-on-2 against a wild: the award and the catch
-- ------------------------------------------------------------------

local function wildFight(opts)
  newGame()
  local hub = Hub.new({ maxPlayers = 4, generation = 3 })
  hub.forceBattleSeed = opts.seed or 9
  local ann, annPeer = join3(hub, "ANN", "firered")
  local bob, bobPeer = join3(hub, "BOB", "firered")
  hub:openCoopBattle(opts.id, { ann.id, bob.id }, { mode = "coop_wild", hostId = ann.id })
  SESSION.party = { opts.mine }
  for _, entry in ipairs(opts.bag or {}) do FakeBag.add(SESSION.bag, entry[1], entry[2]) end
  local partnerParty = assert(CoopBattle.unpackParty(GAME,
    assert(CoopBattle.packParty({ monOf(16, 5, { moves = { 45 }, pp = { 40 }, maxPp = { 40 } }) }, GAME))))
  local wild = opts.wild
  local slots = {
    { side = "a", owner = ann.id, name = "ANN", party = SESSION.party },
    { side = "a", owner = bob.id, name = "BOB", party = partnerParty },
    { side = "b", name = "PIDGEY", party = { wild } },
  }
  local hostT, guestT = transportFor(hub, ann), transportFor(hub, bob)
  local host = assert(CoopBattle.new(GAME, { slots = slots, mine = 1, host = true,
    mode = "coop_wild", wildCatchMon = wild, transport = hostT, battleId = opts.id,
    selfId = ann.id }))
  local guest = assert(CoopBattle.new(GAME, { slots = slots, mine = 2, host = false,
    mode = "coop_wild", transport = guestT, battleId = opts.id, selfId = bob.id }))
  host:enter()
  guest:enter()
  local h = { hub = hub, host = host, guest = guest, hostT = hostT,
              record = hub.battles[opts.id] }
  function h.pump()
    deliver(annPeer, host)
    deliver(bobPeer, guest)
    settle(host)
    settle(guest)
  end
  return h
end

do
  local mine = monOf(4, 6, { moves = { 10, 45, 33, 1 }, pp = { 35, 40, 35, 35 },
                             maxPp = { 35, 40, 35, 35 } })
  -- One point short of level 7, where CHARMANDER learns EMBER with four moves
  -- already known: the award levels it, and the fifth move waits.
  mine.exp = Experience.expForLevel(mine.growthRate, 7) - 1
  local wild = monOf(16, 3, { hp = 1, moves = { 45 }, pp = { 40 }, maxPp = { 40 },
                              otId = 5, otName = "" })
  local h = wildFight({ id = "cw1", mine = mine, wild = wild })
  check(h.record and h.record.sim ~= nil, "the Gen 3 hub referees a party encounter")
  h.pump()
  eq(h.host.phase, "choose", "the host's grid opens")
  h.host:commit({ slot = 1, move = 1, target = 3 })   -- SCRATCH the 1-HP PIDGEY
  h.guest:commit({ slot = 2, move = 1, target = 3 })
  for _ = 1, 10 do
    h.pump()
    if h.host.result then break end
    if h.host.phase == "choose" then h.host:commit({ slot = 1, move = 1, target = 3 }) end
    if h.guest.phase == "choose" then h.guest:commit({ slot = 2, move = 1, target = 3 }) end
  end
  for _ = 1, 60 do h.host:update(2.0) end
  eq(h.host.result, "win", "the knockout wins the party encounter")
  eq(h.host.expPaid, 1, "one award, priced on this client")
  eq(mine.level, 7, "the award levelled the session mon (the engine's curve)")
  eq(mine.evs.spe, 1, "and paid its EVs")
  local toLearn = h.host.toLearn or {}
  eq(#toLearn, 1, "EMBER with four moves known waits for the after-battle prompt")
  eq(toLearn[1] and toLearn[1].move, 52, "...for EMBER")
end

do
  local mine = monOf(4, 30, { moves = { 45 }, pp = { 40 }, maxPp = { 40 } })
  local wild = monOf(16, 5, { moves = { 45 }, pp = { 40 }, maxPp = { 40 }, otId = 5 })
  local h = wildFight({ id = "cw2", mine = mine, wild = wild, bag = { { 1, 1 } } })
  h.pump()
  eq(h.host.phase, "choose", "the grid opens for the catch")
  local items = h.host:usableItems()
  eq(items[1] and items[1].id, 1, "the MASTER BALL is on the Gen 3 bag list")
  eq(items[1] and items[1].name, "MASTER BALL", "under the cart's name")
  h.host.itemPick = items[1]
  check(h.host:commitMediatedItem(nil, nil), "the ball goes out")
  local choice = h.hostT.sent[#h.hostT.sent]
  eq(choice.item, "1", "the throw names the ball by number")
  eq(choice.dexCaught, false, "and says the dex has no PIDGEY caught (Repeat Ball)")
  h.guest:commit({ slot = 2, move = 1, target = 3 })
  for _ = 1, 10 do
    h.pump()
    if h.host.result then break end
  end
  for _ = 1, 60 do h.host:update(2.0) end
  eq(h.host.result, "win", "a catch is a win")
  eq(#SESSION.party, 2, "the catch joined the session party")
  eq(SESSION.party[2] == wild, true, "as the very mon the encounter built")
  eq(SESSION.party[2].pokeball, 1, "in the ball it was caught in")
  eq(FakeBag.get(SESSION.bag, 1), 0, "and the ball was spent")
  eq(SESSION.dex.caught[16], true, "the dex has it caught")
end


-- ------------------------------------------------------------------
-- 4. the stand-in and the ritual
-- ------------------------------------------------------------------

-- A trainer stand-in, built at the BattleBridge.start door the way the wrap
-- builds one, with the opcode's `done` recorded.
local function trainerStand(trainerId, opts)
  opts = opts or {}
  local results = {}
  local battleOpts = { trainerId = trainerId, defeatText = "Well done!\\pYou win.",
                       done = function(result) results[#results + 1] = result end }
  for k, v in pairs(opts) do battleOpts[k] = v end
  local started = 0
  local stand = CoopField.trainerStand3(FakeTrainers.foeFromId(trainerId), battleOpts, {
    game = GAME, mapId = "FR_ROUTE_1",
    fightAlone = function() started = started + 1 end,
  })
  return stand, results, function() return started end
end

do
  newGame()
  SESSION.party = { monOf(4, 10) }
  local stand, results = trainerStand(326)
  check(stand ~= nil, "a standard trainer start builds a stand-in")
  eq(stand.kind, "trainer", "shaped like the buried battle Coop reads")
  eq(stand.gen3Divert, true, "and says it is Gen 3's")
  eq(#stand.enemyParty, 1, "the trainer's team, built the way the cart builds a foe")
  eq(stand.enemyParty[1].species, 4, "...its species")
  check(stand.enemyParty[1].maxHp ~= nil and stand.enemyParty[1].hp == stand.enemyParty[1].maxHp,
        "...its stats, at full HP")
  eq(stand.trainer.id, "326", "the record's id is the string a co-op field carries")
  eq(stand.trainer.trainerPic, 5, "and it names the trainer's pic")
  eq(stand.label, "RIVAL TERRY", "labelled by class and name")
  eq(stand.checkpointOrigin.npcId, "g3t326", "the origin an invite joiner is told")
  eq(stand.endBattleText, "Well done!\fYou win.", "the defeat line, paged the way CoopBattle pages it")
  check(stand.coverText:find("would like to battle", 1, true) ~= nil, "the cover says who is waiting")

  -- The prize, the cart's way (FireRed: 4 x last level x class x multiplier).
  SESSION.money = 1000
  local paid = Coop.payTrainerPrize(stand, GAME, "win")
  eq(paid, 4 * 5 * 10, "a win pays the cart's prize")
  eq(SESSION.money, 1200, "into the live session")
  eq(Coop.payTrainerPrize(stand, GAME, "loss"), 0, "a loss pays nothing")
  stand.amuletCoin = true
  eq(Coop.payTrainerPrize(stand, GAME, "win"), 400, "an AMULET COIN this player fielded doubles it")
  stand.amuletCoin = nil
  stand.double = true
  eq(Coop.payTrainerPrize(stand, GAME, "win"), 400, "and so does the trainer's own double battle")
  stand.double = nil
  SESSION.version = "emerald"
  eq(Coop.payTrainerPrize(stand, GAME, "win"), 4 * 5 * 7, "Emerald pays by its own table")
  SESSION.version = "firered"

  -- A win: the ritual pays, and the trainer's script carries on once the
  -- screen is free -- not while a prompt the fight left is still up.
  SESSION.money = 1000
  Gen3Ui.pushScreen(GAME, "RbyMmoText", { draw = function() end })
  local handled, ritual = Coop.finishBuriedBattle(stand, GAME, "win", false)
  eq(handled, true, "the buried stand-in is finished")
  eq(ritual, false, "a win owes no whiteout")
  eq(SESSION.money, 1200, "the prize is paid")
  eq(#results, 0, "the script waits while a prompt the fight left is up")
  CoopField.pump3(0.1)
  eq(#results, 0, "still waiting")
  Gen3Ui.pop(GAME)
  CoopField.pump3(0.1)
  eq(results[1], "win", "then the opcode's own done(\"win\") sets the flag and resumes")
  eq(SESSION.battleOutcome, 1, "with B_OUTCOME_WON where scripts read it")
  eq(recorded("returnToField"), 1, "and the map's return-to-field scripts")
  eq(recorded("respawn"), 0, "nobody was sent anywhere")
  check(#audioCalls > 0, "the map song came back")
end

do
  newGame()
  SESSION.party = { monOf(4, 10, { hp = 0 }) }
  SESSION.money = 1000
  local stand, results = trainerStand(326)
  eq(Coop.blacksOut("loss", GAME), true, "a loss blacks out")
  local handled, ritual = Coop.finishBuriedBattle(stand, GAME, "loss", true)
  eq(handled, true, "the loss is finished")
  eq(ritual, true, "and the engine side owns the whiteout")
  eq(recorded("moneyLoss"), 1, "the cart's money rule runs")
  eq(SESSION.money, 500, "taking what the cart takes")
  CoopField.pump3(0.1)
  eq(recorded("respawn"), 1, "the warp to the heal location")
  eq(results[1], "lose", "and the opcode hears a loss (no trainer flag)")
  eq(SESSION.battleOutcome, 2, "B_OUTCOME_LOST")
end

do
  newGame()
  SESSION.party = { monOf(4, 10) }
  local stand, results = trainerStand(326)
  Coop.finishBuriedBattle(stand, GAME, "draw", false)
  CoopField.pump3(0.1)
  eq(results[1], "lose", "a draw is not a win: the trainer stays unbeaten")
  eq(recorded("moneyLoss"), 0, "and nobody is taxed for it")
  eq(recorded("respawn"), 0, "or sent to a POKeMON CENTER")
  eq(SESSION.battleOutcome, 3, "B_OUTCOME_DREW")
end

do
  newGame()
  SESSION.party = { monOf(4, 10, { hp = 0 }) }
  local stand, results = trainerStand(326, { earlyRival = true, rivalFlags = 1 })
  Coop.finishBuriedBattle(stand, GAME, "loss", true)
  CoopField.pump3(0.1)
  eq(recorded("moneyLoss"), 0, "the early rival's heal-after loss costs no money")
  eq(recorded("heal"), 1, "the party is healed")
  eq(results[1], "lose", "and the script carries on")
end

do
  newGame()
  local fainted = monOf(4, 10, { hp = 0 })
  SESSION.party = { fainted }
  GAME.save.party = { monOf(4, 10) }   -- a stale snapshot
  eq(Coop.blacksOut("win", GAME), true, "blacksOut reads the live session party, not the snapshot")
  local holder = {}
  SESSION.money = 800
  -- A post-battle prompt is still up (the forget-a-move box, an evolution).
  Gen3Ui.pushScreen(GAME, "RbyMmoText", { draw = function() end })
  eq(Coop.blackout(holder, GAME), true, "Coop.blackout runs the cart's whiteout on Gen 3")
  eq(SESSION.money, 400, "its money rule")
  eq(fainted.hp, fainted.maxHp, "the party healed now")
  eq(recorded("respawn"), 0, "the warp waits behind the prompt")
  Gen3Ui.pop(GAME)
  CoopField.pump3(0.1)
  eq(recorded("respawn"), 1, "until the screen is free")
end

do
  newGame()
  SESSION.party = { monOf(4, 10) }
  local coop = Coop.new({ isReady = function() return true end, send = function() end },
    { say = function() return {} end }, nil, nil, nil)
  STORE.flags = {}
  SESSION.money = 1000
  eq(coop:syntheticFinish(GAME, { npcId = "g3t326" }, nil), true,
     "an invite joiner finishes the trainer their partner walked into")
  eq(STORE.flags[0x500 + 326], true, "that trainer's flag is set in this client's store")
  eq(SESSION.money, 1200, "and the prize is paid")
  eq(coop:syntheticFinish(GAME, { npcId = "g3t999" }, nil), false,
     "a trainer this cart has no row for is refused")
  eq(coop:syntheticFinish(GAME, { npcId = "g3t326" }, { trainer = { trainerId = 400 } }), false,
     "and one the fight was not against")

  -- The forget prompt is the cart's own (LearnMove.begin), one at a time.
  FakeLearn.begun = {}
  local mon = SESSION.party[1]
  coop:offerForgets(GAME, { { mon = mon, move = 52 }, { mon = mon, move = 57 } })
  eq(#FakeLearn.begun, 2, "both leftovers reach the cart's learn-move exchange")
  eq(FakeLearn.begun[1].moveId, 52, "in order")
  eq(FakeLearn.begun[1].battleText, false, "in its field wording")
end

-- ------- Coop's two doors with a stand-in in them

local function coopWith(partnerOnMap)
  local sent = {}
  local toasts = {}
  local transport = { isReady = function() return true end,
                      send = function(_, kind, msg) sent[#sent + 1] = { kind = kind, msg = msg } end }
  local party = {
    selfId = "me",
    has = function() return true end,
    partners = function() return { { id = "p2", name = "BOB" } } end,
    partnerName = function() return "BOB" end,
    count = function() return 2 end,
    isPartner = function(_, id) return id == "p2" end,
    isSelf = function(_, id) return id == "me" end,
    list = function() return { { id = "me", name = "ANN" }, { id = "p2", name = "BOB" } } end,
  }
  local roster = { get = function(_, id)
    if id == "p2" then return { id = "p2", map = partnerOnMap and "FR_ROUTE_1" or "FR_PALLET_TOWN" } end
  end }
  local said = {}
  local ui = { say = function(_, text, cb) said[#said + 1] = text; return {} end }
  local coop = Coop.new(transport, ui, party, roster, nil)
  coop.toast = function(text) toasts[#toasts + 1] = text end
  return coop, sent, toasts, said
end

do
  newGame()
  SESSION.party = { monOf(4, 10) }
  local coop, sent = coopWith(true)
  local stand, results, started = trainerStand(326)
  stand:push(GAME)
  eq(coop:onTrainerBattle(GAME, stand, "FR_ROUTE_1"), true, "a partied player's trainer becomes a wait")
  eq(sent[1] and sent[1].kind, Wire.COOP_WAIT, "COOP_WAIT goes out")
  eq(sent[1] and sent[1].msg.battle, "FR_ROUTE_1|t|326", "keyed on the map and the cart's trainer number")
  eq(sent[1] and sent[1].msg.label, "RIVAL TERRY", "labelled by class and name")
  eq(sent[1] and sent[1].msg.npcId, "g3t326", "with the origin an invite joiner needs")
  eq(Coop.stackHasFight(GAME), true, "the stand-in counts as a fight on the stack")
  -- Nobody came: the wait's clock hands the fight back to the cart.
  coop:update(10, GAME)
  eq(coop.waiting, nil, "the wait is withdrawn")
  coop:release()
  eq(started(), 1, "and the cart's own trainer battle starts, once")
  eq(Gen3Ui.has(stand), false, "with the cover down")
  coop:release()
  eq(started(), 1, "a second release starts nothing")
  eq(#results, 0, "the opcode's done belongs to the cart's own battle now")

  newGame()
  local coop2, sent2, toasts2, said2 = coopWith(false)
  local stand2 = trainerStand(326)
  eq(coop2:onTrainerBattle(GAME, stand2, "FR_ROUTE_1"), false, "an off-map partner: no divert")
  eq(#sent2, 0, "nothing sent")
  eq(toasts2[1], "BOB was too far\nto join!", "said in the corner")
  eq(#said2, 0, "not in a box that would sit over the cart's battle")
end

do
  newGame()
  local coop, sent = coopWith(true)
  local enc = { species = "PIDGEY", speciesId = 16, level = 3 }
  local stand = CoopField.wildStand3(enc, { game = GAME, mapId = "FR_ROUTE_1" })
  check(stand ~= nil, "a step encounter builds a wild stand-in")
  eq(stand.enemyParty[1].species, 16, "with the rolled species")
  eq(stand.enemyParty[1].level, 3, "at the rolled level")
  check(stand.enemyParty[1].personality ~= nil, "a personality rolled the cart's way")
  eq(stand.coverText, "Wild PIDGEY\nappeared!", "and the cart's own line on the cover")
  stand:push(GAME)
  eq(coop:onWildEncounter(GAME, stand, "FR_ROUTE_1"), true, "a partied wild becomes a wait")
  eq(sent[1] and sent[1].msg.mode, "coop_wild", "a coop_wild one")
  eq(sent[1] and sent[1].msg.label, "PIDGEY", "labelled with the cart's species name")
end

-- ------- walking into the trainer the partner is already waiting at

do
  newGame()
  SESSION.party = { monOf(4, 10) }
  local coop, sent = coopWith(true)
  coop.offer = { from = "p2", name = "BOB", battle = "FR_ROUTE_1|t|326", map = "FR_ROUTE_1" }
  local stand = trainerStand(326)
  stand:push(GAME)
  eq(coop:onTrainerBattle(GAME, stand, "FR_ROUTE_1"), true,
     "a walk-in on the trainer a partner waits at joins their fight")
  eq(sent[1] and sent[1].kind, Wire.COOP_JOIN, "COOP_JOIN goes out, no second wait")
  eq(sent[1] and sent[1].msg.battle, "FR_ROUTE_1|t|326", "for the same key, derived on both carts")
  eq(coop.encounter and coop.encounter.engine, stand,
     "and our own stand-in is held for startBattle to adopt")
end

-- ------- a refereed event is read in this boot's own vocabulary

do
  newGame()
  local coop = coopWith(true)
  local got = {}
  coop.state = { game = GAME, onBattleEvent = function(_, event) got[#got + 1] = event end }
  coop:onBattleEvent({ battle = "cb1", seq = 4, t = "weather", text = "RAIN", value = 1 })
  eq(got[1] and got[1].t, "weather", "a Gen 3 client reads its referee's Gen 3 kinds")
  local Gen = need("Gen")
  local realGeneration = Gen.generation
  Gen.generation = function() return 1 end
  coop:onBattleEvent({ battle = "cb1", seq = 5, t = "weather", text = "RAIN", value = 1 })
  Gen.generation = realGeneration
  eq(#got, 1, "a Gen 1 boot reads the older vocabulary only, as it always did")
end


-- ------------------------------------------------------------------
-- 5. which fights a divert may take, and the BattleBridge.start wrap
-- ------------------------------------------------------------------

do
  newGame()
  local base = { species = "PIDGEY", speciesId = 16, level = 3 }
  local function wildOk(enc, mapId)
    return CoopField.wildStand3(enc, { game = GAME, mapId = mapId or "FR_ROUTE_1" }) ~= nil
  end
  eq(wildOk(base), true, "a standard grass encounter may be diverted")
  eq(wildOk({ species = "RAIKOU", speciesId = 243, level = 50, roamer = true }), false,
     "a roamer is the cart's")
  eq(wildOk({ speciesId = 16, level = 3, foe = { species = 16 } }), false,
     "an encounter carrying its own foe record is the cart's")
  STORE.flags[0x800] = true   -- FLAG_SYS_SAFARI_MODE, FireRed's way of saying so
  eq(wildOk(base), false, "a Safari Zone encounter is the cart's")
  STORE.flags[0x800] = nil
  eq(wildOk(base, "FR_POKEMON_TOWER_3F"), false,
     "a POKeMON TOWER wild without the SILPH SCOPE is the ghost's")
  FakeBag.add(SESSION.bag, 359, 1)
  eq(wildOk(base, "FR_POKEMON_TOWER_3F"), true, "and an ordinary wild with it")
  local foe = FakeTrainers.foeFromId(326)
  local function trainerOk(opts) return CoopField.trainerStand3(foe, opts, { game = GAME }) ~= nil end
  eq(trainerOk({ trainerId = 326 }), true, "a standard trainer may be diverted")
  eq(trainerOk({ trainerId = 326, firstBattle = true }), false, "the first battle is the cart's")
  eq(trainerOk({ trainerId = 326, trainerTower = true }), false, "the Trainer Tower is the cart's")
  eq(trainerOk({ trainerId = 326, frontier = true }), false, "a frontier facility is the cart's")
  eq(trainerOk({ trainerId = 326, link = true }), false, "a link battle is another player's")
  eq(trainerOk({ trainerId = 326, twoOpponents = true }), false, "two trainers at once are the cart's")
  eq(CoopField.trainerStand3({ species = 4, level = 5 }, {}, { game = GAME }), nil,
     "a start with no trainer id is not a trainer")
end

do
  newGame()
  SESSION.party = { monOf(4, 10) }
  local original = FakeBB.start
  local decision, taken = true, {}
  local handler = {
    wants = function() return true end,
    skipWild = function() return false end,
    take = function(stand, foe, opts, kind)
      taken[#taken + 1] = { stand = stand, foe = foe, opts = opts, kind = kind }
      return decision
    end,
  }
  eq(CoopField.installStart3(handler), true, "the wrap installs over BattleBridge.start")
  check(FakeBB.start ~= original, "the slot holds the wrapper")
  eq(rawget(FakeBB, "__rby_mmo_start"), original, "and the original is kept on the module")
  eq(CoopField.installStart3(handler), true, "installing again is a no-op")
  eq(rawget(FakeBB, "__rby_mmo_start"), original, "and never wraps the wrapper")

  -- A trainer the divert takes: the cart never starts it.
  local foe = FakeTrainers.foeFromId(326)
  local doneWith
  local opts = { trainerId = 326, done = function(r) doneWith = r end }
  eq(FakeBB.start("ENGINE_MOD", GAME, foe, opts), true, "the start answers as started")
  eq(recorded("engineStart"), 0, "and the cart's battle did not start")
  eq(taken[1] and taken[1].kind, "trainer", "the handler took a trainer")
  eq(taken[1] and taken[1].opts, opts, "with the engine's own opts (the opcode's done)")
  eq(recorded("league"), 1, "the start's own bookkeeping ran for the fight it took")
  local stand = taken[1].stand
  stand:fightAlone()
  eq(recorded("engineStart"), 1, "handing it back starts the cart's own battle")
  stand:fightAlone()
  eq(recorded("engineStart"), 1, "once")

  -- Refused kinds and declined fights reach the cart untouched.
  taken = {}
  FakeBB.start("ENGINE_MOD", GAME, foe, { trainerId = 326, trainerTower = true })
  eq(#taken, 0, "a refused kind is never offered")
  eq(recorded("engineStart"), 2, "and runs the cart's battle")
  decision = false
  FakeBB.start("ENGINE_MOD", GAME, foe, { trainerId = 326 })
  eq(#taken, 1, "a declined trainer was offered")
  eq(recorded("engineStart"), 3, "and runs the cart's battle")
  decision = true

  -- A wild that did not come through encounter.roll (a fishing rod).
  taken = {}
  FakeBB.startWild("ENGINE_MOD", GAME, { species = 16, level = 5 }, {})
  eq(taken[1] and taken[1].kind, "wild", "a fishing encounter is offered at the wrap")
  eq(recorded("engineStart"), 3, "and taken, the cart starts nothing")
  handler.skipWild = function() return true end
  FakeBB.startWild("ENGINE_MOD", GAME, { species = 16, level = 5 }, {})
  eq(#taken, 1, "a step encounter the roll hook already offered is not offered twice")
  eq(recorded("engineStart"), 4, "it reaches the cart as rolled")
  FakeBB.startWild("ENGINE_MOD", GAME, { species = 16, level = 5 }, { legendary = true })
  eq(recorded("engineStart"), 5, "a scripted legendary is the cart's")

  -- Another instance of the mod loaded: this wrapper answers vanilla.
  handler.skipWild = function() return false end
  local find = stubMod.find
  stubMod.find = function() return { exports = {} } end
  taken = {}
  FakeBB.start("ENGINE_MOD", GAME, foe, { trainerId = 326 })
  eq(#taken, 0, "a wrapper left by an unloaded instance takes nothing")
  eq(recorded("engineStart"), 6, "and the cart fights")
  stubMod.find = find

  eq(CoopField.restoreStart3(), true, "the wrap comes off")
  eq(FakeBB.start, original, "and the engine's own function is back")
  eq(rawget(FakeBB, "__rby_mmo_start"), nil, "with nothing left on the module")

  -- Another mod wraps on top of ours (Gen3.wrapFn's discipline).
  eq(CoopField.installStart3(handler), true, "the wrap goes back in")
  local ours = FakeBB.start
  local otherCalls = 0
  local other = function(...) otherCalls = otherCalls + 1; return ours(...) end
  FakeBB.start = other
  eq(CoopField.installStart3(handler), true, "a second install with a wrapper on top")
  eq(FakeBB.start, other, "keeps the other mod's wrapper in the slot")
  taken = {}
  local before = recorded("engineStart")
  FakeBB.start("ENGINE_MOD", GAME, foe, { trainerId = 326 })
  eq(otherCalls, 1, "the other mod still sees every start")
  eq(#taken, 1, "and ours under it still diverts")
  taken[1].stand:fightAlone()
  eq(recorded("engineStart"), before + 1, "a fight handed back reaches the engine through the chain")
  eq(CoopField.restoreStart3(), true, "taking ours off under somebody else's")
  eq(FakeBB.start, other, "leaves their wrapper where it is")
  taken = {}
  FakeBB.start("ENGINE_MOD", GAME, foe, { trainerId = 326 })
  eq(otherCalls, 2, "their wrapper still runs")
  eq(#taken, 0, "ours, retired in place, takes nothing")
  eq(recorded("engineStart"), before + 2, "and the cart fights")
  FakeBB.start = original
  rawset(FakeBB, "__rby_mmo_start", nil)
  rawset(FakeBB, "__rby_mmo_start:live", nil)
end

-- ------------------------------------------------------------------
-- 6. prompts wait for the cart's own menus
-- ------------------------------------------------------------------

do
  newGame()
  local queue, confirms = {}, {}
  local ui = {
    say = function() return {} end,
    confirm = function(_, _, text, cb) confirms[#confirms + 1] = { text = text, cb = cb }; return {} end,
    -- Ui:whenFree's rule, in brief: now when the cart is not using the
    -- screen, else once it is free, and only if the prompt still matters.
    whenFree = function(_, _, show, opts)
      if Gen3Ui.occupied() then
        queue[#queue + 1] = { show = show, alive = opts and opts.alive }
        return { deferred = true }
      end
      return show()
    end,
  }
  local function pump()
    if Gen3Ui.occupied() then return end
    while queue[1] do
      local entry = table.remove(queue, 1)
      if not entry.alive or entry.alive() then entry.show() end
    end
  end
  local transport = { isReady = function() return true end, send = function() end }
  local coop = Coop.new(transport, ui, { has = function() return true end,
    partners = function() return {} end, count = function() return 2 end,
    partnerName = function() return "BOB" end }, nil, nil)
  Stack.push("bag", { draw = function() end })
  eq(Gen3Ui.occupied(), true, "the cart's BAG is up")
  coop:onAsk(GAME, { id = "ask1", from = "p3", name = "CAL", side = "b" })
  eq(#confirms, 0, "a party-battle ask waits behind the cart's menu")
  check(coop.ask ~= nil, "while the ask is held")
  Stack.pop("bag")
  pump()
  eq(#confirms, 1, "and goes up once the player is free")
  eq(confirms[1].text, "CAL wants a\n2-on-2 battle!", "the same question")

  Stack.push("bag", { draw = function() end })
  coop.ask = nil
  coop:onAsk(GAME, { id = "ask2", from = "p3", name = "CAL", side = "b" })
  coop.ask = nil  -- withdrawn meanwhile (the hub's clock, the asker leaving)
  Stack.pop("bag")
  pump()
  eq(#confirms, 1, "an ask that ended while the player was busy is never shown")

  -- A partner's standing offer is not taken over the cart's menu either.
  coop.offer = { from = "p2", name = "BOB", battle = "FR_ROUTE_1|t|326", map = "FR_ROUTE_1" }
  coop.party.selfId = "me"
  coop.party.isPartner = function(_, id) return id == "p2" end
  local joined = 0
  coop.autoJoin = function() joined = joined + 1; return true end
  Stack.push("start", { draw = function() end })
  eq(coop:considerOffer(GAME, "FR_ROUTE_1"), false, "a join waits while START is open")
  eq(joined, 0, "nothing was sent")
  Stack.pop("start")
  eq(coop:considerOffer(GAME, "FR_ROUTE_1"), true, "and is taken once the player is free")
end


eq(#gen1Asked, 0, "no section above asked for Gen 1's battle engine on a Gen 3 boot")
-- The traps come down: the loader sections below load the mod as Red too.
for _, name in ipairs({ "src.battle.BattleState", "src.battle.Damage",
                        "src.battle.TurnOrder", "src.battle.Experience",
                        "src.core.Sound", "src.core.Music" }) do
  package.preload[name] = nil
end

-- ------------------------------------------------------------------
-- 7. the client's wiring, through the real headless loader
-- ------------------------------------------------------------------

local GameVersion = require("src.core.GameVersion")
local makeRemapFs = dofile(MOD_PATH .. "/tests/mod_remap_fs.lua")

local function loadAs(version, generation)
  GameVersion.set(version)
  local opts = { generation = generation }
  if generation == 3 then opts.data = T.sdk.gen3Data() end
  if MOD_PATH ~= "mods/rby_mmo" then opts.fs = makeRemapFs(T, MOD_PATH) end
  return T.sdk.loadMod("mods/rby_mmo", opts)
end

local function upvalue(fn, name)
  for i = 1, 200 do
    local n, v = debug.getupvalue(fn, i)
    if not n then break end
    if n == name then return v end
  end
  return nil
end

local function rbyChain(run, hook)
  local chain = run.loader.hooks.chains[hook] or {}
  local n = 0
  for _, entry in ipairs(chain) do
    if entry.owner == "rby_mmo" then n = n + 1 end
  end
  return n
end

do
  local red = loadAs("red", 1)
  eq(red.mod and red.mod.state, "loaded", "Red: the mod loads")
  eq(rbyChain(red, "encounter.roll"), 0,
     "Red: no encounter.roll link (the screen.pushed divert is Gen 1 / Gen 2's)")
  red.release()
end

for _, version in ipairs({ "firered", "emerald" }) do
  newGame({ version = version })
  SESSION.party = { monOf(4, 10) }
  local run = loadAs(version, 3)
  eq(run.mod and run.mod.state, "loaded", version .. ": the mod loads on a Gen 3 boot")
  eq(rbyChain(run, "encounter.roll"), 1, version .. ": the mod wraps encounter.roll")
  local game = { generation = 3, phase = "field", session = SESSION, data = run.data,
                 input = fakeInput() }
  run.loader.game = game
  local exports = run.loader.exports and run.loader.exports.rby_mmo
  local ctx = exports and type(exports.players) == "function" and upvalue(exports.players, "ctx")
  check(ctx ~= nil and ctx.solo ~= nil, version .. ": the client's context is reachable")

  -- A lone player (no party, SOLO BATTLES off): the encounter is untouched.
  local enc = { species = "PIDGEY", speciesId = 16, level = 3 }
  local vanilla = function() return enc end
  local got = run.loader.hooks:call("encounter.roll", vanilla, {}, { mapId = "FR_ROUTE_1" })
  eq(got, enc, version .. ": a lone player's encounter passes through untouched")
  eq(#Gen3Ui.states(), 0, version .. ": and nothing was put on the screen")

  -- One field tick: the trainer wrap goes on from the field.
  local original = FakeBB.start
  run.loader.hooks:call("input.step", function() end, game, 1 / 60)
  check(FakeBB.start ~= original, version .. ": the BattleBridge.start wrap is installed from the field")
  eq(rawget(FakeBB, "__rby_mmo_start"), original, version .. ": over the engine's own")

  -- SOLO BATTLES on: the encounter is diverted and the roll answers nil.
  run.loader.modOptions.rby_mmo = { solo = true }
  local spied
  local decide = true
  ctx.solo.fromGen3Encounter = function(_, g, e, o)
    spied = { game = g, enc = e, opts = o }
    return decide
  end
  local resets = encReset
  got = run.loader.hooks:call("encounter.roll", vanilla, {}, { mapId = "FR_ROUTE_1" })
  eq(got, nil, version .. ": a diverted encounter is cancelled at the roll")
  eq(spied and spied.enc, enc, version .. ": solo was handed the rolled encounter")
  eq(spied and spied.game, game, version .. ": on the live game")
  eq(type(spied and spied.opts.done), "function", version .. ": with a done to call")
  eq(type(spied and spied.opts.fallback), "function", version .. ": and a way to hand it back")
  eq(encReset, resets + 1, version .. ": the encounter rate re-arms as a battle start does")
  eq(#Gen3Ui.states(), 0, version .. ": the cover came down for solo's own screen")
  decide = false
  got = run.loader.hooks:call("encounter.roll", vanilla, {}, { mapId = "FR_ROUTE_1" })
  eq(got, enc, version .. ": declined, the encounter is the cart's again")

  -- A trainer at the wrap.
  rec = {}
  local trainerSpy
  ctx.solo.fromGen3Trainer = function(_, g, foe, o)
    trainerSpy = { foe = foe, opts = o }
    return true
  end
  local resumed
  local tfoe = FakeTrainers.foeFromId(326)
  FakeBB.start("ENGINE_MOD", game, tfoe, { trainerId = 326, done = function(r) resumed = r end })
  eq(recorded("engineStart"), 0, version .. ": a diverted trainer never starts the cart's battle")
  eq(trainerSpy and trainerSpy.foe, tfoe, version .. ": solo gets the trainer's foe record")
  trainerSpy.opts.done("win")
  eq(resumed, "win", version .. ": and its done is the opcode's own continuation")
  ctx.solo.fromGen3Trainer = function() return false end
  FakeBB.start("ENGINE_MOD", game, tfoe, { trainerId = 326, done = function() end })
  eq(recorded("engineStart"), 1, version .. ": declined, the cart fights the trainer")

  -- Leave the engine function as it was found.
  FakeBB.start = rawget(FakeBB, "__rby_mmo_start") or original
  rawset(FakeBB, "__rby_mmo_start", nil)
  run.release()
end
GameVersion.set("red")


-- ------------------------------------------------------------------
-- 8. Gold regressions (a Gen 1 / Gen 2 loader, a Gold game)
-- ------------------------------------------------------------------

do
  local goldFacade = stubFacade(nil)
  local needGold = newNeed(goldFacade)
  local CoopBattleG = needGold("CoopBattle")
  local CoopSimG = needGold("CoopSim")
  local CoopG = needGold("Coop")
  local WireG = needGold("Wire")
  local gold = { generation = 2, data = { generation = 2, pokemon = {}, moves = {} },
                 save = { generation = 2, player = { money = 100 }, party = {} } }
  local red = { generation = 1, data = { pokemon = {}, moves = {} }, save = { party = {} } }
  goldFacade.game = gold
  eq(CoopBattleG.effectsFor(gold), needGold("BattleSim2/Effects"),
     "a Gold co-op screen reads BattleSim2's item table")
  eq(CoopBattleG.effectsFor(red), needGold("BattleSim/Effects"),
     "Red keeps BattleSim's")

  -- A Kurt ball thrown in a Gold co-op fight: the throw chain and the caught
  -- announcement need to know it was a ball, which Gen 1's table cannot say.
  local screen = setmetatable({
    game = gold, mediated = true, battleId = "g2", mine = 1,
    medSlots = { [0] = 1 }, medFields = { [1] = 0 }, messages = {},
    sim = CoopSimG.new({ data = gold.data, game = gold }, {
      { side = "a", owner = "me", name = "GOLD", party = { { species = "X", hp = 10, stats = { hp = 10 } } } },
      { side = "b", name = "WILD", party = { { species = "Y", hp = 10, stats = { hp = 10 } } } },
    }),
  }, CoopBattleG)
  screen:medRows({ t = "item", battle = "g2", slot = 0, side = "a", text = "LEVEL_BALL" })
  eq(screen.medBall, "LEVEL_BALL", "a LEVEL BALL is a ball on Gold")
  eq(screen.caughtBall, "LEVEL_BALL", "and the catcher remembers which one")
  eq(needGold("BattleSim/Effects").itemEffect("LEVEL_BALL"), nil,
     "(Gen 1's table has no such ball -- which is what the screen used to ask)")

  -- An invite joiner's prize on Gold lands where Gold keeps its money.
  local ow = {
    npcPool = { npc7 = { def = { trainerClass = "OPP_X", trainerParty = 1, index = 1 } } },
    map = { def = { label = "ROUTE_29" } },
  }
  goldFacade.world = { overworld = function() return ow end }
  gold.data.trainers = { OPP_X = { id = "OPP_X", baseMoney = 10, parties = { { { level = 20 } } } } }
  local coop = CoopG.new({ isReady = function() return true end, send = function() end },
    { say = function() return {} end }, nil, nil, nil)
  eq(coop:syntheticFinish(gold, { npcId = "npc7" }, nil), true, "the Gold invite joiner's finish runs")
  eq(gold.save.player.money, 300, "its prize is paid into save.player.money")
  eq(gold.save.money, nil, "and not into a save.money nothing on Gold reads")
  eq(gold.save.defeatedTrainers.npc7, true, "the trainer is marked beaten")
  check(WireG.npcId("npc7") ~= nil, "(the id the wire carries is the one finished)")
end

T.finish("gen3_coop")
