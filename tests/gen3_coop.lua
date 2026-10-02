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
--  3b. the badge rules through the real screens and the in-game hub
--      (docs/plans/gen3-badge-rules.md): each human's own badges (K1) and
--      traded / unfateful sheets (K2) reach the referee on their own cart's
--      terms, a boosted strike and a changed speed order against the same fight
--      with the badges taken away, a traded mon over its cap refusing on a
--      human seat with the cart's line said once (K3), and none of it in a
--      coop_pvp spar -- from an honest client or a hostile one;
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
-- ITEM_* ids, the badge flags FLAG_BADGE01_GET), the policy
-- docs/plans/gen3-battle-sheet.md states for the sim.
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
-- FireRed / LeafGreen's badge test (pret FLAG_BADGE01_GET is 0x820 there): the
-- flag store answers one badge by its number.  Emerald's is the battle
-- profile's own `badgeFlags` below, asked flag by flag, as the engine does
-- (battle/engine.lua Engine.hasBadge).
local FRLG_BADGE1, RSE_BADGE1 = 0x820, 0x867
function FakeFlags.hasBadge(store, n) return store.flags[FRLG_BADGE1 + n - 1] == true end
local FakeSpace = { store = STORE }
function FakeSpace.getStore() return STORE end
function FakeSpace.returnToField() note("returnToField") end
-- The script VM a trainerbattle command waits in (Space.vm): `running` is
-- what Vm:isRunning answers (true while the opcode waits -- the engine counts
-- "waiting"), `halted` counts Vm:halt.
local FakeVm = { running = false, halted = 0 }
function FakeVm:isRunning() return self.running end
function FakeVm:halt(aborted)
  self.halted = self.halted + 1
  self.running = false
  self.aborted = aborted
  note("halt")
end
FakeSpace.vm = FakeVm
-- The map's object events (objects.lua `_byId`) and what trainer each one's
-- script fights (trainer_sight.lua getTrainerId), and a rematch table.
local FakeObjects = { _byId = {}, _order = {} }
local FakeSight = {}
function FakeSight.getTrainerId(eo) return eo and tonumber(eo.trainerId) end
local FakeVsSeeker = { rematch = {} }
function FakeVsSeeker.rematchTrainerId(tid) return FakeVsSeeker.rematch[tonumber(tid)] or 0 end
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
-- Trainers.info's rival rule (class 81 here, synthetic): the player's rival's
-- name replaces the row's placeholder when the caller hands one in.
function FakeTrainers.info(id, opts)
  local info = FakeTrainers.get(id)
  if info and type(opts) == "table" and type(opts.rivalName) == "string"
     and opts.rivalName ~= "" and info.class == 81 then
    info.name = opts.rivalName
  end
  return info
end
-- The name-hash personalities (Trainers._doublePersonalities), synthetic:
-- 0x80 plus a per-slot step, as the engine's hash is 0x80 plus the hash.
function FakeTrainers._doublePersonalities(t)
  local out = {}
  for i = 1, #(t.party or {}) do out[i] = 0x80 + i * 0x1000 end
  return out
end
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
-- Prize.payDay's shape: the coins times the multiplier, into the session.
function FakePrize.payDay(session, coins, opts)
  local bonus = coins * ((opts and opts.moneyMultiplier) or 1)
  session.money = math.min(999999, (session.money or 0) + bonus)
  note("payDay", coins, opts and opts.moneyMultiplier)
  return bonus
end
local FakeProfile = {}
function FakeProfile.get(session)
  local rse = session and session.version == "emerald"
  local badgeFlags = nil
  if rse then
    badgeFlags = {}
    for n = 1, 8 do badgeFlags[n] = RSE_BADGE1 + n - 1 end
  end
  return { family = rse and "rse" or "frlg", safari = false, kinds = { ghost = not rse },
           badgeFlags = badgeFlags,
           rules = { money = rse and "rse" or "frlg", whiteout = rse and "half" or "frlg",
                     amuletCoinPlayerOnly = rse } }
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
  stub("src.core.game3.objects", FakeObjects)
  stub("src.core.game3.trainer_sight", FakeSight)
  stub("src.core.game3.vs_seeker", FakeVsSeeker)
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
  FakeVm.running, FakeVm.halted, FakeVm.aborted = false, 0, nil
  FakeObjects._byId = {}
  FakeVsSeeker.rematch = {}
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

  -- The arena callout names the move the way the cart does: Gen 3's anim
  -- token is the sheet's move id, which data.moves does not key, so the live
  -- run shouted "TAIL_WHIP!" over the partner.
  check(screen:usesBattlefield(), "the Gen 3 co-op screen uses the arena (callout test below runs)")
  if screen:usesBattlefield() then
    local token = battler.curMoves[3].id
    screen:splitCalloutBeat({ anim = token, from = 1 })
    local bubble = screen.battlefieldBubbles and screen.battlefieldBubbles[1]
    eq(bubble and bubble.moveName, "SWORDS DANCE",
       "the callout shouts the move's name, not its token (" .. tostring(token) .. ")")
  end
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
  -- RF6 #6, both seats: every human's own PP spend reaches their own party
  -- (the guest's here is its seat's party; each client writes only its own).
  check((mine.pp[1] or 35) + (mine.pp[2] or 15) < 35 + 15,
        "the host's PP spend is written to its session mon ("
        .. tostring(mine.pp[1]) .. "/" .. tostring(mine.pp[2]) .. ")")
  check((partnerParty[1].pp[1] or 35) < 35,
        "and the guest's to its own party (" .. tostring(partnerParty[1].pp[1]) .. ")")
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
  local specs = { { 4, 30 }, { 16, 30 }, { 29, 8, 5 }, { 151, 8, 5 } }
  -- CAL (screen 3) is this process's own player: its seat is the live
  -- session party, as src/Coop.lua hands it over; everybody else's seats are
  -- copies unpacked off the wire, one set per client, as on four machines.
  local calMon = monOf(29, 8, { moves = { 33 }, pp = { 35 }, maxPp = { 35 }, hp = 5 })
  SESSION.party = { calMon }
  local calExp, calLevel = calMon.exp, calMon.level
  local function slotsFor(me)
    local out = {}
    for i = 1, 4 do
      local p = (i == 3 and me == 3) and SESSION.party
        or party(specs[i][1], specs[i][2], specs[i][3])
      out[i] = { side = i <= 2 and "a" or "b", owner = ids[i], name = names[i], party = p }
    end
    return out
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
    screens[i] = assert(CoopBattle.new(GAME, { slots = slotsFor(i), mine = i, host = i == 1,
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
  -- Link rules (pokefirered cable_club.c LoadPlayerParty): the spar fought
  -- with copies, and the session party is exactly as it was.
  local calSeat = screens[3].sim:slot(3)
  check(calSeat.party[1] ~= calMon, "a spar's own seat fights with a copy of the session mon")
  eq(calSeat.party[1].hp, 0, "(which the fight knocked out)")
  eq(calMon.hp, 5, "the session mon's HP is as it was before the spar")
  eq(calMon.status, nil, "its status too")
  eq(calMon.pp[1], 35, "and its PP")
  eq(calMon.exp, calExp, "no EXP")
  eq(calMon.level, calLevel, "and no level")
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
-- 3b. badge rules through the real co-op screens and the in-game hub
--     (docs/plans/gen3-badge-rules.md: K1 badges, K2 traded / unfateful,
--     K3 the obey event)
-- ------------------------------------------------------------------
--
-- Two humans, each on their own cart -- ANN on FireRed, BOB on Emerald -- each
-- with their own session, trainer id and flag store.  This process is one
-- machine, so a player is a *swap* of what the fakes read (`actAs`: the
-- session and the flag store), made around that screen's own upload (`enter`),
-- which is the moment a client reads its badges and cuts its sheets.  Everything
-- after the upload is the hub's: src/Hub.lua seating src/BattleSim3, and the
-- real CoopBattle screens it feeds.  A boost or a refusal to obey is read off
-- the referee's own stream, a fight at a pinned `forceBattleSeed` against the
-- same fight with the badges taken away.

do
  local Gen3 = need("Gen3")
  local Mediated = need("MediatedBattle")

  -- Two synthetic hitting moves in the SDK fixture's row shape: a physical one
  -- (Normal) and a special one (Fire; Gen 3 splits by type), single-target and
  -- strong enough that a x1.1 stat shows in the damage.
  ROM[70] = { effect = 0, power = 120, type = 0, accuracy = 100, pp = 20,
              secondaryChance = 0, target = 0, priority = 0, flags = 3 }
  P3._moveNames[70] = "BODY SLAM"
  ROM[71] = { effect = 0, power = 120, type = 10, accuracy = 100, pp = 20,
              secondaryChance = 0, target = 0, priority = 0, flags = 0 }
  P3._moveNames[71] = "FLAMETHROWER"

  -- A trainer whose lead is faster than ANN's CHARMANDER, but by less than the
  -- x1.1 of badge 3 (the speeds are read off the referee below, not assumed).
  TRAINERS[401] = { class = 44, className = "PKMN TRAINER", name = "TWINS", pic = 9,
                    items = { 0, 0, 0, 0 }, lastLevel = 76, doubleBattle = true,
                    party = { { species = 16, level = 76, iv = 0, moves = { 33 } },
                              { species = 16, level = 60, iv = 0, moves = { 33 } } } }

  local function nums(list) return table.concat(list or {}, ",") end
  -- Comparisons that answer false, rather than raise, when a strike never
  -- happened: a broken rule must read as a failed check, not a dead block.
  local function more(a, b) return a ~= nil and b ~= nil and a > b end
  local function before(turn, a, b)
    local x, y = turn.at(a), turn.at(b)
    return x ~= nil and y ~= nil and x < y
  end
  -- A stream, as one comparable string.
  local function sigOf(log)
    local sig = {}
    for _, e in ipairs(log) do
      sig[#sig + 1] = table.concat({ tostring(e.t), tostring(e.slot), tostring(e.amount),
                                     tostring(e.hp), tostring(e.text) }, ":")
    end
    return table.concat(sig, "|")
  end
  local function setNums(set)
    local out = {}
    for n in pairs(set or {}) do out[#out + 1] = n end
    table.sort(out)
    return table.concat(out, ",")
  end

  -- The flags that say "this player holds these badges", on their own cart's
  -- numbering (FireRed 0x820.., Emerald 0x867..).
  local function badgeFlagsOf(version, list)
    local base = version == "emerald" and RSE_BADGE1 or FRLG_BADGE1
    local flags = {}
    for _, n in ipairs(list) do flags[base + n - 1] = true end
    return flags
  end

  local function player(name, version, trainerId, badges, stray)
    local session = newSession({ name = name, trainerId = trainerId,
                                 secretId = trainerId + 1, version = version })
    local flags = badgeFlagsOf(version, badges)
    -- Flags that are *another cart's* badges: they must not count.
    for _, id in ipairs(stray or {}) do flags[id] = true end
    return { name = name, version = version, session = session, flags = flags }
  end

  local function actAs(p)
    SESSION = p.session
    GAME.session = p.session
    STORE.flags = p.flags
  end

  local function lead(species, level, owner, moves, extra)
    local pp, maxPp = {}, {}
    for i, id in ipairs(moves) do pp[i], maxPp[i] = ROM[id].pp, ROM[id].pp end
    local mon = { moves = moves, pp = pp, maxPp = maxPp,
                  otId = owner.session.trainerId, otName = owner.name }
    for k, v in pairs(extra or {}) do mon[k] = v end
    return monOf(species, level, mon)
  end

  -- Two humans against a trainer's two seats (coop_npc) or a wild mon
  -- (coop_wild), each upload made as its own player.
  local function badgeFight(o)
    newGame()
    local annP, bobP = o.ann, o.bob
    local hub = Hub.new({ maxPlayers = 4, generation = 3 })
    hub.forceBattleSeed = o.seed
    local ann, annPeer = join3(hub, "ANN", annP.version)
    local bob, bobPeer = join3(hub, "BOB", bobP.version)
    hub:openCoopBattle(o.id, { ann.id, bob.id }, { mode = o.mode, hostId = ann.id })
    annP.session.party, bobP.session.party = o.annParty, o.bobParty
    actAs(annP)
    local slots = {
      { side = "a", owner = ann.id, name = "ANN", party = o.annParty },
      { side = "a", owner = bob.id, name = "BOB", party = o.bobParty },
    }
    local trainer
    if o.mode == "coop_npc" then
      local b1, b2, record = npcSeats(GAME, o.trainerId)
      trainer = record
      slots[3] = { side = "b", name = "TWINS", party = b1 }
      slots[4] = { side = "b", name = "TWINS", party = b2 }
    else
      slots[3] = { side = "b", name = "PIDGEY", party = { o.wild } }
    end
    local hostT, guestT = transportFor(hub, ann), transportFor(hub, bob)
    -- A hostile client: what it sends is rewritten on its way out.
    if o.forge then
      local real = hostT.send
      hostT.send = function(self, kind, msg) return real(self, kind, o.forge(kind, msg)) end
    end
    local host = assert(CoopBattle.new(GAME, { slots = slots, mine = 1, host = true,
      mode = o.mode, trainer = trainer, wildCatchMon = o.wild, transport = hostT,
      battleId = o.id, selfId = ann.id }))
    local guest = assert(CoopBattle.new(GAME, { slots = slots, mine = 2, host = false,
      mode = o.mode, transport = guestT, battleId = o.id, selfId = bob.id }))
    -- What each screen put up for reading, a line at a time, in order.  Taken
    -- as the line goes up (the field is assigned from nil each time), because
    -- a fast step dismisses it in the tick it appears.
    local function watch(screen)
      local said = {}
      local class = getmetatable(screen)
      setmetatable(screen, { __index = class.__index or class,
        __newindex = function(t, k, v)
          if k == "shown" and v ~= nil then said[#said + 1] = (tostring(v):gsub("%s*\n%s*", " ")) end
          rawset(t, k, v)
        end })
      return said
    end
    local f = { hub = hub, ann = ann, bob = bob, annPeer = annPeer, bobPeer = bobPeer,
                host = host, guest = guest, hostT = hostT, guestT = guestT,
                record = hub.battles[o.id], annP = annP, bobP = bobP, log = {},
                hostSaid = watch(host), guestSaid = watch(guest) }
    host:enter()
    actAs(bobP)
    guest:enter()
    actAs(annP)
    f.record = hub.battles[o.id]
    -- Let the opening play out to the first menu, keeping the referee's stream.
    function f.pump()
      for _, msg in ipairs(annPeer.outbox) do
        if msg.type == Wire.BATTLE_EVENT then f.log[#f.log + 1] = msg end
      end
      deliver(annPeer, host)
      deliver(bobPeer, guest)
      settle(host)
      settle(guest)
    end
    return f
  end

  -- The upload a screen's transport sent for one side.
  local function uploadOf(transport, side)
    for _, msg in ipairs(transport.sent) do
      if msg.type == Wire.BATTLE_PARTY and msg.side == side then return msg end
    end
    return nil
  end

  local function fighterOf(f, id) return f.record.sim.byId[id] end

  -- From a stream: who acted in what order (`anim` rows by the acting slot),
  -- the damage each human's first strike did to the foe, and the `obey` events.
  local function readTurn(log)
    local order, dealt, obeys, cur = {}, {}, {}, nil
    for i, e in ipairs(log) do
      if e.t == "anim" then
        order[#order + 1] = e.slot
        cur = e.slot
      elseif e.t == "damage" and e.side == "b" and cur ~= nil and dealt[cur] == nil then
        dealt[cur] = e.amount
      elseif e.t == "obey" then
        obeys[#obeys + 1] = { slot = e.slot, token = e.text, say = log[i + 1] }
      end
    end
    local function index(slot)
      for i, s in ipairs(order) do if s == slot then return i end end
      return nil
    end
    return { order = order, dealt = dealt, obeys = obeys, at = index }
  end

  -- One turn of the same fight, at one seed: ANN's lead strikes the trainer's
  -- first seat, BOB's the second.  Only the badges the two humans hold differ.
  local SEED = 5
  local function turnOne(annBadges, bobBadges, id, forge)
    local annP = player("ANN", "firered", 111, annBadges)
    local bobP = player("BOB", "emerald", 333, bobBadges)
    local f = badgeFight({ id = id, mode = "coop_npc", seed = SEED, trainerId = 401,
      ann = annP, bob = bobP, forge = forge,
      annParty = { lead(4, 50, annP, { 70 }) },
      bobParty = { lead(16, 50, bobP, { 71 }) } })
    f.pump()
    f.host:commit({ slot = 1, move = 1, target = 3 })
    f.guest:commit({ slot = 2, move = 1, target = 4 })
    f.pump()
    f.turn = readTurn(f.log)
    return f
  end

  -- The cart's lines for the disobedience outcomes, in capitals so a line the
  -- player's text pack printed can be told from the referee's own sentence.  A
  -- stand-in for the engine's pack (Gen3.battleText), as tests/gen3_mediated.lua
  -- §9 has one: the engine's battle_text.lua names a mon on the player's side
  -- by `atk` with side "player".  Switched off, it answers as this harness's
  -- real one does -- there is no ROM text here, so with nothing at all.
  local CART = {
    STRINGID_PKMNIGNORESASLEEP = "%s IGNORED\nORDERS WHILE ASLEEP!",
    STRINGID_PKMNIGNOREDORDERS = "%s IGNORED\nORDERS!",
    STRINGID_PKMNBEGANTONAP = "%s BEGAN TO NAP!",
    STRINGID_PKMNLOAFING = "%s IS\nLOAFING AROUND!",
    STRINGID_PKMNWONTOBEY = "%s WON'T\nOBEY!",
    STRINGID_PKMNTURNEDAWAY = "%s TURNED AWAY!",
    STRINGID_PKMNPRETENDNOTNOTICE = "%s PRETENDED\nNOT TO NOTICE!",
  }
  local realText, packOn = Gen3.battleText, true
  Gen3.battleText = function(id, fill)
    local shape = CART[id]
    if not (shape and packOn) then return realText(id, fill) end
    local atk = type(fill) == "table" and fill.atk or nil
    if not (type(atk) == "table" and atk.side == "player" and type(atk.name) == "string") then
      return nil
    end
    return shape:format(atk.name)
  end
  local function flat(text) return (tostring(text):gsub("%s*\n%s*", " ")) end
  local function cartLine(token, name)
    return flat(CART[Mediated.OBEY_STRINGS3[token]]:format(name))
  end
  local function count(lines, text)
    local n = 0
    for _, line in ipairs(lines) do if line == flat(text) then n = n + 1 end end
    return n
  end
  local function indexOf(lines, text)
    for i, line in ipairs(lines) do if line == flat(text) then return i end end
    return nil
  end

  local ok, err = pcall(function()
    -- --------------------------------------------------------------
    -- K1 + K2: each human's own badges and sheets reach the referee
    -- --------------------------------------------------------------
    --
    -- ANN's flags carry a stray Emerald badge-8 flag and BOB's a stray FireRed
    -- badge-1 flag: a cart reads its own numbering, so neither counts.  BOB's
    -- lead has BOB's own OT (333): not traded under BOB's session, and it would
    -- read as traded had his sheets been cut under ANN's (111) -- so the
    -- upload is only right if each client cuts its own.  His MEW came from a
    -- stranger and its ribbon field was never set, which the engine reads as
    -- the ordinary rules (nothing named); ANN's MEW has the bit explicitly
    -- clear, the one case the engine holds to cap 0 (`unfateful`).
    local annP = player("ANN", "firered", 111, { 1, 3 }, { RSE_BADGE1 + 7 })
    local bobP = player("BOB", "emerald", 333, { 5, 7 }, { FRLG_BADGE1 })
    local f = badgeFight({ id = "bd1", mode = "coop_npc", seed = SEED, trainerId = 401,
      ann = annP, bob = bobP,
      annParty = { lead(4, 50, annP, { 70 }),
                   lead(151, 5, annP, { 10 }, { fatefulEncounter = false }) },
      bobParty = { lead(16, 50, bobP, { 71 }),
                   lead(151, 30, bobP, { 10 }, { otId = 999, otName = "ZED" }) } })

    local hostUp, guestUp = uploadOf(f.hostT, "a"), uploadOf(f.guestT, "a")
    eq(nums(hostUp and hostUp.badges), "1,3", "badges: ANN uploads her own, off her FireRed flags")
    eq(nums(guestUp and guestUp.badges), "5,7", "badges: BOB uploads his own, off his Emerald profile's flags")
    local hostMons, guestMons = hostUp and hostUp.mons or {}, guestUp and guestUp.mons or {}
    eq(hostMons[1] and hostMons[1].traded, nil, "traded: ANN's own catch is not")
    eq(hostMons[2] and hostMons[2].traded, nil, "traded: ...nor her MEW, caught by her")
    eq(hostMons[2] and hostMons[2].unfateful, true, "unfateful: ...and her MEW's ribbon bit is explicitly clear")
    eq(guestMons[1] and guestMons[1].traded, nil, "traded: BOB's own catch is not (cut under BOB's trainer id)")
    eq(guestMons[2] and guestMons[2].traded, true, "traded: BOB's MEW from a stranger is")
    eq(guestMons[2] and guestMons[2].unfateful, nil, "unfateful: ...and it names no clear ribbon bit")
    local retired = false
    for _, mon in ipairs(hostMons) do if mon.fateful ~= nil then retired = true end end
    for _, mon in ipairs(guestMons) do if mon.fateful ~= nil then retired = true end end
    eq(retired, false, "K2: neither upload carries the retired fateful")
    local npcUp = uploadOf(f.hostT, "b")
    eq(npcUp and npcUp.badges, nil, "the trainer's team carries no badges")
    local npcClean = true
    for _, mon in ipairs(npcUp and npcUp.mons or {}) do
      if mon.traded ~= nil or mon.unfateful ~= nil then npcClean = false end
    end
    check(npcUp ~= nil and npcClean, "...and its sheets neither traded nor unfateful")

    check(f.record.sim ~= nil, "the hub referees the fight")
    local annF, bobF = fighterOf(f, f.ann.id), fighterOf(f, f.bob.id)
    eq(annF and annF.badgeRules, true, "referee: ANN's seat plays the cart's badge rules")
    eq(setNums(annF and annF.badges), "1,3", "referee: ...with ANN's badges")
    eq(annF and annF.family, "frlg", "referee: ...as her FireRed cart (Focus Punch's exemption)")
    eq(bobF and bobF.badgeRules, true, "referee: BOB's seat plays them too")
    eq(setNums(bobF and bobF.badges), "5,7", "referee: ...with BOB's own badges, not ANN's")
    eq(bobF and bobF.family, "rse", "referee: ...as his Emerald cart")
    eq(bobF and bobF.mons[2].traded, true, "referee: BOB's traded MEW is traded here too")
    eq(bobF and bobF.mons[2].unfateful, nil, "referee: ...held to the ordinary rules, nothing named")
    eq(bobF and bobF.mons[1].traded, nil, "referee: ...and his own catch is not")
    eq(annF and annF.mons[2].unfateful, true, "referee: ANN's MEW is held to its clear ribbon bit")
    for _, npcId in ipairs(f.record.npcIds or {}) do
      local seat = fighterOf(f, npcId)
      eq(seat and seat.badgeRules, nil, "referee: a trainer's seat plays no badge rules")
      eq(seat and seat.badges, nil, "referee: ...and holds no badges")
      eq(seat and seat.family, nil, "referee: ...and names no cart")
    end

    -- --------------------------------------------------------------
    -- the boosts: the same turn with the badges taken away
    -- --------------------------------------------------------------
    local none = turnOne({}, {}, "bd2")
    local annSpe = fighterOf(none, none.ann.id).b.stats.spe
    local foeSpe = fighterOf(none, none.record.npcIds[1]).b.stats.spe
    check(annSpe < foeSpe, "boosts: the premise -- the trainer's lead outspeeds ANN's CHARMANDER ("
      .. tostring(annSpe) .. " < " .. tostring(foeSpe) .. ")")
    check(none.turn.at(3) ~= nil and none.turn.at(0) ~= nil, "boosts: both strikes land")
    check(before(none.turn, 3, 0), "boosts: with no badges the trainer's lead strikes first")
    check(none.turn.dealt[0] ~= nil and none.turn.dealt[1] ~= nil,
          "boosts: ...and both humans' strikes did damage (" .. tostring(none.turn.dealt[0])
          .. " / " .. tostring(none.turn.dealt[1]) .. ")")

    -- Badge 1 (Attack): ANN's physical strike hits harder -- and only hers.
    -- The order is unchanged, so every roll lines up with the baseline's.
    local atk = turnOne({ 1 }, {}, "bd3")
    check(before(atk.turn, 3, 0), "badge 1: the order is the baseline's")
    check(more(atk.turn.dealt[0], none.turn.dealt[0]),
          "badge 1: ANN's strike is stronger than with no badges (" .. tostring(atk.turn.dealt[0])
          .. " > " .. tostring(none.turn.dealt[0]) .. ")")
    eq(atk.turn.dealt[1], none.turn.dealt[1], "badge 1: ...and BOB's partner strike is not")

    -- Badge 7 (Sp. Atk) on the *other* human's cart: BOB's special strike.
    local spa = turnOne({}, { 7 }, "bd4")
    check(more(spa.turn.dealt[1], none.turn.dealt[1]),
          "badge 7: BOB's strike is stronger than with no badges (" .. tostring(spa.turn.dealt[1])
          .. " > " .. tostring(none.turn.dealt[1]) .. ")")
    eq(spa.turn.dealt[0], none.turn.dealt[0], "badge 7: ...and ANN's partner strike is not")

    -- Badge 3 (Speed): the order flips.
    local spe = turnOne({ 3 }, {}, "bd5")
    check(before(spe.turn, 0, 3),
          "badge 3: ANN's CHARMANDER now strikes before the trainer's lead")
    eq(spe.turn.at(1), none.turn.at(1), "badge 3: ...and BOB's place in the order is the baseline's")

    -- The trainer's team is never the player's: a hostile host who hangs badges
    -- and a traded flag on every one of its monsters (any of which, at L76 with
    -- no cap-lifting badge, would refuse to obey) plays the same fight.
    local forgedFoe = turnOne({}, {}, "bd7", function(kind, msg)
      if kind ~= Wire.BATTLE_PARTY or msg.side ~= "b" then return msg end
      msg = copyTable(msg)
      msg.badges = { "1", "3" }
      local mons = {}
      for i, mon in ipairs(msg.mons) do
        mons[i] = copyTable(mon)
        mons[i].traded = true
      end
      msg.mons = mons
      return msg
    end)
    local forgedSeat = forgedFoe.record.parties[forgedFoe.record.npcIds[1]]
    check(forgedSeat ~= nil and forgedSeat.badges ~= nil and forgedSeat.mons[1].traded == true,
          "forged trainer: the badges and traded flag reached the hub's record")
    for _, npcId in ipairs(forgedFoe.record.npcIds) do
      local seat = fighterOf(forgedFoe, npcId)
      eq(seat and seat.badgeRules, nil, "forged trainer: its seat plays no badge rules")
      eq(seat and seat.badges, nil, "forged trainer: ...and holds no badges")
    end
    eq(#forgedFoe.turn.obeys, 0, "forged trainer: none of its monsters disobeys")
    check(#sigOf(none.log) > 400, "forged trainer: the stream compared is a whole turn's")
    eq(sigOf(forgedFoe.log), sigOf(none.log), "forged trainer: the fight is the honest one's, event for event")

    -- Everyone's badges at once (the fight above).
    local both = turnOne({ 1, 3 }, { 5, 7 }, "bd6")
    check(before(both.turn, 0, 3), "both: ANN strikes first")
    check(more(both.turn.dealt[1], none.turn.dealt[1]), "both: BOB's strike is boosted")

    -- --------------------------------------------------------------
    -- coop_wild: the same rule against a wild mon
    -- --------------------------------------------------------------
    local function wildTurn(annBadges, id)
      local wannP = player("ANN", "firered", 111, annBadges)
      local wbobP = player("BOB", "emerald", 333, {})
      local wild = monOf(16, 76, { moves = { 33 }, pp = { 35 }, maxPp = { 35 }, otId = 5, otName = "" })
      local w = badgeFight({ id = id, mode = "coop_wild", seed = SEED, ann = wannP, bob = wbobP,
        annParty = { lead(4, 50, wannP, { 70 }) }, bobParty = { lead(16, 50, wbobP, { 71 }) },
        wild = wild })
      w.pump()
      w.host:commit({ slot = 1, move = 1, target = 3 })
      w.guest:commit({ slot = 2, move = 1, target = 3 })
      w.pump()
      w.turn = readTurn(w.log)
      return w
    end
    local wNone = wildTurn({}, "bw1")
    local wBadged = wildTurn({ 1 }, "bw2")
    eq(nums(uploadOf(wBadged.hostT, "a").badges), "1", "coop_wild: ANN uploads her badge")
    eq(uploadOf(wBadged.guestT, "a").badges, nil, "coop_wild: ...and BOB, with none, uploads none")
    eq(uploadOf(wBadged.hostT, "b").badges, nil, "coop_wild: the wild mon's seat carries none")
    local wAnn, wFoe = fighterOf(wBadged, wBadged.ann.id), fighterOf(wBadged, wBadged.record.npcIds[1])
    eq(wAnn and wAnn.badgeRules, true, "coop_wild: ANN's seat plays the badge rules")
    eq(setNums(wAnn and wAnn.badges), "1", "coop_wild: ...with her badge")
    eq(wFoe and wFoe.badgeRules, nil, "coop_wild: the wild mon plays none")
    eq(wAnn and wAnn.family, "frlg", "coop_wild: ANN's seat names her FireRed cart")
    eq(fighterOf(wBadged, wBadged.bob.id).family, "rse", "coop_wild: ...and BOB's his Emerald")
    check(more(wBadged.turn.dealt[0], wNone.turn.dealt[0]),
          "coop_wild: ANN's strike is stronger with badge 1 (" .. tostring(wBadged.turn.dealt[0])
          .. " > " .. tostring(wNone.turn.dealt[0]) .. ")")
    eq(wBadged.turn.dealt[1], wNone.turn.dealt[1], "coop_wild: ...and BOB's, with no badge, is not")

    -- --------------------------------------------------------------
    -- K3: a traded mon over its badge cap, on a human seat
    -- --------------------------------------------------------------
    --
    -- A traded L50 mon with no badge obeys to level 10 only, and mostly ignores
    -- its player.  The seeds are pinned and the stream is the referee's own:
    -- at 5 ANN's CHARMANDER won't obey, at 1 it ignores orders and uses another
    -- move, at 7 BOB's PIDGEY loafs around.
    eq(realText("STRINGID_PKMNLOAFING", { atk = { side = "player", name = "CHARMANDER" } }), nil,
       "obey: the premise -- this harness has no text pack of its own")

    local function obeyRun(o)
      local annP = player("ANN", "firered", 111, o.annBadges or {})
      local bobP = player("BOB", "emerald", 333, {})
      local stranger = { otId = 999, otName = "ZED" }
      local wildFoe = o.mode == "coop_wild"
        and monOf(16, 76, { moves = { 33 }, pp = { 35 }, maxPp = { 35 }, otId = 5, otName = "" })
        or nil
      local annLead = o.annLead
        and lead(o.annLead[1], 50, annP, { 70, 10 }, o.annLead[2])
        or lead(4, 50, annP, { 70, 10 }, o.annTraded and stranger or nil)
      local r = badgeFight({ id = o.id, mode = o.mode or "coop_npc", seed = o.seed, trainerId = 401,
        ann = annP, bob = bobP, wild = wildFoe,
        annParty = { annLead },
        bobParty = { lead(16, 50, bobP, { 71 }, o.bobTraded and stranger or nil) } })
      r.pump()
      r.host:commit({ slot = 1, move = 1, target = 3 })
      r.guest:commit({ slot = 2, move = 1, target = wildFoe and 3 or 4 })
      r.pump()
      r.turn = readTurn(r.log)
      r.turns = 0
      for _, e in ipairs(r.log) do if e.t == "turn" then r.turns = r.turns + 1 end end
      return r
    end
    local function screensSay(r, line, times, what)
      eq(count(r.hostSaid, line), times, "ANN's screen: " .. what)
      eq(count(r.guestSaid, line), times, "BOB's screen: " .. what)
    end

    -- ANN's mon, traded and over the cap, with the player's text pack.
    packOn = true
    local ob = obeyRun({ id = "ob1", seed = 5, annTraded = true })
    local up = uploadOf(ob.hostT, "a")
    eq(up and up.mons[1].traded, true, "obey: ANN's sheet says her CHARMANDER is traded")
    eq(up and up.badges, nil, "obey: ...and she holds no badge to send")
    eq(#ob.turn.obeys, 1, "obey: the referee sends one refusal for the turn")
    local refusal = ob.turn.obeys[1] or {}
    eq(refusal.slot, 0, "obey: ...from ANN's seat")
    eq(refusal.token, "wont_obey", "obey: ...naming the outcome")
    eq(refusal.say and refusal.say.t, "msg", "obey: ...with its own sentence straight behind")
    screensSay(ob, cartLine("wont_obey", "CHARMANDER"), 1, "the cart's line, once")
    screensSay(ob, refusal.say and refusal.say.text or "?", 0, "...and not the referee's sentence as well")
    eq(ob.turn.dealt[0], nil, "obey: the mon that would not obey did not strike")
    check(ob.turn.dealt[1] ~= nil, "obey: ...the turn went on -- BOB's partner struck")
    eq(ob.turns, 2, "obey: ...and the next turn opened")
    eq(ob.host.phase, "choose", "obey: ANN's screen is at its menu again")
    eq(ob.guest.phase, "choose", "obey: ...and BOB's")

    -- The same fight with the player's text pack gone: the referee's sentence,
    -- said once, in the line's place.
    packOn = false
    local nopack = obeyRun({ id = "ob2", seed = 5, annTraded = true })
    local nopackRefusal = nopack.turn.obeys[1]
    eq(nopackRefusal and nopackRefusal.token, "wont_obey", "obey (no pack): the same refusal at the same seed")
    screensSay(nopack, nopackRefusal and nopackRefusal.say.text or "?", 1,
               "no text pack -- the referee's sentence, once")
    screensSay(nopack, cartLine("wont_obey", "CHARMANDER"), 0, "...and no line of the cart's")
    eq(nopack.turns, 2, "obey (no pack): the turn went on")
    packOn = true

    -- The same seed, the same mon, but the rule is not on: ANN holds the
    -- eighth badge (no cap) / the mon is her own catch.
    local capped = obeyRun({ id = "ob3", seed = 5, annTraded = true, annBadges = { 8 } })
    eq(nums(uploadOf(capped.hostT, "a").badges), "8", "obey (badge 8): ANN sends her badge")
    eq(uploadOf(capped.hostT, "a").mons[1].traded, true, "obey (badge 8): ...of a traded mon")
    eq(#capped.turn.obeys, 0, "obey (badge 8): the traded mon obeys, whatever its level")
    check(capped.turn.dealt[0] ~= nil, "obey (badge 8): ANN's strike landed")
    local own = obeyRun({ id = "ob4", seed = 5 })
    eq(uploadOf(own.hostT, "a").mons[1].traded, nil, "obey (own catch): her sheet says it is not traded")
    eq(#own.turn.obeys, 0, "obey (own catch): a mon that is hers obeys at any level")
    check(own.turn.dealt[0] ~= nil, "obey (own catch): ANN's strike landed")

    -- The Mew / Deoxys rule (contract K2, battle/engine.lua:1299): ANN's own
    -- MEW whose fateful-encounter bit is explicitly clear obeys nobody -- cap
    -- 0, the eighth badge or not, so every seed disobeys -- and one that never
    -- had the field plays the ordinary rules, as the engine's nil does: her
    -- own catch, so it obeys.  The referee reads `unfateful == true`; an
    -- absent flag can never cost a MEW its obedience.
    local mewClear = obeyRun({ id = "ob8", seed = 5, annBadges = { 8 },
                               annLead = { 151, { fatefulEncounter = false } } })
    local mewUp = uploadOf(mewClear.hostT, "a")
    eq(mewUp and mewUp.mons[1].unfateful, true, "obey (MEW, bit clear): ANN's sheet names the clear bit")
    eq(mewUp and mewUp.mons[1].traded, nil, "obey (MEW, bit clear): ...of her own catch")
    eq(nums(mewUp and mewUp.badges), "8", "obey (MEW, bit clear): ...and she sends the eighth badge")
    local mewF = fighterOf(mewClear, mewClear.ann.id)
    eq(mewF and mewF.mons[1].unfateful, true, "obey (MEW, bit clear): the referee holds the flag")
    eq(#mewClear.turn.obeys, 1, "obey (MEW, bit clear): it disobeys, badge 8 and all")
    eq(mewClear.turn.obeys[1] and mewClear.turn.obeys[1].slot, 0, "obey (MEW, bit clear): ...on ANN's seat")
    eq(mewClear.turns, 2, "obey (MEW, bit clear): the turn went on")
    local mewUnset = obeyRun({ id = "ob9", seed = 5, annLead = { 151 } })
    local unsetUp = uploadOf(mewUnset.hostT, "a")
    check(unsetUp ~= nil and unsetUp.mons[1].unfateful == nil and unsetUp.mons[1].fateful == nil,
          "obey (MEW, field unset): ANN's sheet names nothing")
    eq(#mewUnset.turn.obeys, 0, "obey (MEW, field unset): it obeys with no badge at all")
    check(mewUnset.turn.dealt[0] ~= nil, "obey (MEW, field unset): ANN's strike landed")

    -- Another outcome: ignores orders and uses a different move -- which
    -- lands, and is announced once after the line that said why.
    local called = obeyRun({ id = "ob5", seed = 1, annTraded = true })
    eq(called.turn.obeys[1] and called.turn.obeys[1].token, "uses_random_move", "obey (called): the outcome")
    local calledLine = cartLine("uses_random_move", "CHARMANDER")
    screensSay(called, calledLine, 1, "the cart's line, once")
    screensSay(called, "CHARMANDER used SCRATCH!", 1, "the move it used instead, once")
    check(more(indexOf(called.hostSaid, "CHARMANDER used SCRATCH!"), indexOf(called.hostSaid, calledLine)),
          "obey (called): ...in that order")
    check(called.turn.dealt[0] ~= nil, "obey (called): the called move struck")
    eq(called.turns, 2, "obey (called): the turn went on")

    -- Against a wild mon the rule is the same.
    local wildOb = obeyRun({ id = "ob7", mode = "coop_wild", seed = 5, annTraded = true })
    eq(wildOb.turn.obeys[1] and wildOb.turn.obeys[1].token, "wont_obey", "obey (coop_wild): the traded mon won't obey")
    screensSay(wildOb, cartLine("wont_obey", "CHARMANDER"), 1, "coop_wild: the cart's line, once")
    eq(wildOb.turn.dealt[0], nil, "obey (coop_wild): ...and did not strike")
    check(wildOb.turn.dealt[1] ~= nil, "obey (coop_wild): ...while BOB's partner did")
    eq(wildOb.turns, 2, "obey (coop_wild): the turn went on")

    -- The partner's seat, on BOB's Emerald: ANN's screen reads it too.
    local partner = obeyRun({ id = "ob6", seed = 7, bobTraded = true })
    eq(uploadOf(partner.guestT, "a").mons[1].traded, true, "obey (partner): BOB's sheet says his PIDGEY is traded")
    local bobRefusal = partner.turn.obeys[1]
    eq(bobRefusal and bobRefusal.slot, 1, "obey (partner): the refusal is on BOB's seat")
    eq(bobRefusal and bobRefusal.token, "loafing", "obey (partner): ...a loafing line")
    screensSay(partner, cartLine("loafing", "PIDGEY"), 1, "BOB's PIDGEY, in the cart's line, once")
    screensSay(partner, bobRefusal and bobRefusal.say.text or "?", 0, "...not the referee's sentence")
    eq(partner.turn.dealt[1], nil, "obey (partner): BOB's mon did not strike")
    check(partner.turn.dealt[0] ~= nil, "obey (partner): ANN's did")
    eq(partner.turns, 2, "obey (partner): the turn went on")

    -- --------------------------------------------------------------
    -- coop_pvp: a link battle -- nothing of it applies
    -- --------------------------------------------------------------
    --
    -- Four players, each holding badges and a traded mon over the cap.  An
    -- honest client uploads none of it; a hostile one uploads all of it, and the
    -- referee ignores it all the same: the fight plays out identically.
    local NAMES = { "ANN", "BOB", "CAL", "DEE" }
    local VERSIONS = { "firered", "emerald", "firered", "emerald" }
    local function pvpFight(forged)
      newGame()
      local hub = Hub.new({ maxPlayers = 4, generation = 3 })
      hub.forceBattleSeed = 7
      local clients, peers, players, ids = {}, {}, {}, {}
      for i, name in ipairs(NAMES) do
        clients[i], peers[i] = join3(hub, name, VERSIONS[i])
        players[i] = player(name, VERSIONS[i], 100 * i + 11, { 1, 3, 5, 7 })
        players[i].session.party = {
          lead(i % 3 == 1 and 4 or 16, 50, players[i], { 10 }, { otId = 999, otName = "ZED" }),
          lead(151, 30, players[i], { 10 }, { otId = 999, otName = "ZED" }),
        }
        ids[i] = clients[i].id
      end
      hub:openCoopBattle("pv2", ids, { mode = "coop_pvp", hostId = ids[1],
        sides = { a = { ids[1], ids[2] }, b = { ids[3], ids[4] } } })
      local function slotsFor(me)
        local out = {}
        for i = 1, 4 do
          actAs(players[i])
          local party = i == me and players[i].session.party
            or assert(CoopBattle.unpackParty(GAME,
                 assert(CoopBattle.packParty(players[i].session.party, GAME))))
          out[i] = { side = i <= 2 and "a" or "b", owner = ids[i], name = NAMES[i], party = party }
        end
        return out
      end
      local screens, transports = {}, {}
      for i = 1, 4 do
        transports[i] = transportFor(hub, clients[i])
        if forged then
          -- A hostile client: badges and every flag of K2, on every mon.
          local real = transports[i].send
          transports[i].send = function(self, kind, msg)
            if kind == Wire.BATTLE_PARTY and msg.mons then
              msg = copyTable(msg)
              msg.badges = { "1", "3", "5", "7" }
              local mons = {}
              for at, mon in ipairs(msg.mons) do
                mons[at] = copyTable(mon)
                mons[at].traded = true
                if mon.species == "MEW" then mons[at].unfateful = true end
              end
              msg.mons = mons
            end
            return real(self, kind, msg)
          end
        end
        local slots = slotsFor(i)
        screens[i] = assert(CoopBattle.new(GAME, { slots = slots, mine = i, host = i == 1,
          mode = "coop_pvp", transport = transports[i], battleId = "pv2", selfId = ids[i],
          ranksPoints = true }))
        actAs(players[i])
        -- The rule is on for this player against the computer; it is the link
        -- that takes it away.
        eq(nums(Mediated.badgesOf(GAME, "coop_npc")), "1,3,5,7",
           "pvp: " .. NAMES[i] .. " holds badges (a fight against the computer would send them)")
        screens[i]:enter()
      end
      actAs(players[1])
      local log, rounds = {}, 0
      local function collect()
        for _, msg in ipairs(peers[1].outbox) do
          if msg.type == Wire.BATTLE_EVENT then log[#log + 1] = msg end
        end
      end
      for _ = 1, 3 do
        collect()
        for i = 1, 4 do deliver(peers[i], screens[i]) end
        for i = 1, 4 do
          settle(screens[i])
          local sc = screens[i]
          if sc.phase == "choose" and not sc.result then
            local aim = sc:targetChoices()[1]
            sc:commit({ slot = i, move = 1, target = aim and aim.index })
            rounds = rounds + 1
          end
        end
      end
      collect()
      return { hub = hub, record = hub.battles["pv2"], ids = ids, transports = transports,
               log = log, sig = sigOf(log), rounds = rounds, screens = screens }
    end

    local honest = pvpFight(false)
    check(honest.record and honest.record.sim ~= nil, "pvp: four uploads, and the hub referees")
    for i = 1, 4 do
      local sent = uploadOf(honest.transports[i], i <= 2 and "a" or "b")
      check(sent ~= nil, "pvp: " .. NAMES[i] .. " uploaded a party")
      eq(sent and sent.badges, nil, "pvp: " .. NAMES[i] .. " uploads no badges")
      local flagged = false
      for _, mon in ipairs(sent and sent.mons or {}) do
        if mon.traded ~= nil or mon.unfateful ~= nil or mon.fateful ~= nil then flagged = true end
      end
      eq(flagged, false, "pvp: " .. NAMES[i] .. "'s sheets carry neither traded nor unfateful")
      local fighter = fighterOf(honest, honest.ids[i])
      eq(fighter and fighter.badgeRules, nil, "pvp: " .. NAMES[i] .. "'s seat plays no badge rules")
      eq(fighter and fighter.badges, nil, "pvp: ...and holds no badges")
    end
    local honestTurn = readTurn(honest.log)
    eq(#honestTurn.obeys, 0, "pvp: no mon disobeys, though every lead is a traded L50")
    local firstFour = {}
    for i = 1, 4 do firstFour[i] = honestTurn.order[i] end
    table.sort(firstFour)
    eq(table.concat(firstFour, ","), "0,1,3,4", "pvp: ...all four struck in the first turn (field slots 0 1 | 3 4)")
    check(honest.rounds >= 8, "pvp: and the fight went on over several turns (" .. tostring(honest.rounds) .. " commits)")

    local forged = pvpFight(true)
    local sentUp = forged.record.parties and forged.record.parties[forged.ids[1]]
    check(sentUp ~= nil and sentUp.badges ~= nil and sentUp.mons[1].traded == true,
          "pvp (hostile): the forged badges and traded flag reached the hub's record")
    eq(sentUp and sentUp.mons[2] and sentUp.mons[2].unfateful, true,
       "pvp (hostile): ...as did the forged MEW's unfateful (cap 0, were the rule on)")
    for i = 1, 4 do
      local fighter = fighterOf(forged, forged.ids[i])
      eq(fighter and fighter.badgeRules, nil, "pvp (hostile): " .. NAMES[i] .. "'s seat plays no badge rules")
      eq(fighter and fighter.badges, nil, "pvp (hostile): ...and holds no badges")
    end
    eq(#readTurn(forged.log).obeys, 0, "pvp (hostile): no mon disobeys")
    check(#honest.sig > 400, "pvp (hostile): ...the stream compared is a whole fight's (" .. #honest.sig .. " bytes)")
    eq(forged.sig, honest.sig, "pvp (hostile): the fight is the honest one's, event for event")
  end)
  if not ok then check(false, "badges: the block raised -- " .. tostring(err)) end

  Gen3.battleText = realText
  ROM[70], ROM[71], P3._moveNames[70], P3._moveNames[71] = nil, nil, nil, nil
  TRAINERS[401] = nil
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
  -- RF6 #4: a draw that leaves the player standing (a dropped link, a
  -- referee timeout) must not reach the opcode at all -- "lose" ran the bytes
  -- after trainerbattle (a leader's TM without the badge).
  newGame()
  SESSION.party = { monOf(4, 10) }
  local stand, results = trainerStand(326)
  FakeVm.running = true   -- the trainerbattle command waits in the VM
  Coop.finishBuriedBattle(stand, GAME, "draw", false)
  CoopField.pump3(0.1)
  eq(#results, 0, "a draw is never handed to the opcode (no post-battle bytes run)")
  eq(FakeVm.halted, 1, "the trainer's waiting script is halted instead")
  eq(FakeVm.aborted, true, "as aborted, the cart's own ending for it")
  eq(STORE.flags[0x500 + 326], nil, "the trainer stays unbeaten")
  eq(recorded("moneyLoss"), 0, "and nobody is taxed for it")
  eq(recorded("respawn"), 0, "or sent to a POKeMON CENTER")
  eq(recorded("returnToField"), 1, "the field comes back")
  eq(SESSION.battleOutcome, 3, "B_OUTCOME_DREW")

  -- A draw that leaves the team on nothing is the cart's whiteout
  -- (IsPlayerDefeated counts B_OUTCOME_DREW): "lose", the ritual, no flag.
  newGame()
  SESSION.party = { monOf(4, 10, { hp = 0 }) }
  local stand2, results2 = trainerStand(326)
  FakeVm.running = true
  eq(Coop.blacksOut("draw", GAME), true, "a wiped draw blacks out")
  local handled, ritual = Coop.finishBuriedBattle(stand2, GAME, "draw", true)
  CoopField.pump3(0.1)
  eq(handled and ritual, true, "handed over as a loss the engine side whites out")
  eq(recorded("respawn"), 1, "to the heal location")
  eq(results2[1], "lose", "and the opcode hears a loss")
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
  -- RF6 #7: the id and the fight's trainer both come off the wire; the
  -- trainer has to stand on this client's own map.
  eq(coop:syntheticFinish(GAME, { npcId = "g3t326" }, { trainer = { trainerId = 326 } }), false,
     "a trainer who is not on this map is not finished, whatever the partner says")
  eq(STORE.flags[0x500 + 326], nil, "no flag is set for them")
  eq(SESSION.money, 1000, "and no purse is paid")
  FakeObjects._byId = { [3] = { localId = 3, trainerId = 326 }, [4] = { localId = 4 } }
  eq(coop:syntheticFinish(GAME, { npcId = "g3t326" }, nil), true,
     "an invite joiner finishes the trainer their partner walked into")
  eq(STORE.flags[0x500 + 326], true, "that trainer's flag is set in this client's store")
  eq(SESSION.money, 1200, "and the prize is paid")
  eq(coop:syntheticFinish(GAME, { npcId = "g3t999" }, nil), false,
     "a trainer this cart has no row for is refused")
  eq(coop:syntheticFinish(GAME, { npcId = "g3t326" }, { trainer = { trainerId = 400 } }), false,
     "and one the fight was not against")
  -- A rematch fights a later row of the same trainer (the object's script
  -- names the first; the rematch table names today's).
  STORE.flags = {}
  eq(coop:syntheticFinish(GAME, { npcId = "g3t400" }, nil), false,
     "a row no object here fights is refused")
  FakeVsSeeker.rematch[326] = 400
  eq(coop:syntheticFinish(GAME, { npcId = "g3t400" }, nil), true,
     "the row a trainer here fights as a rematch is theirs")
  eq(STORE.flags[0x500 + 400], true, "and is marked beaten")

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

-- ------- RF6: the review findings on the co-op + divert slice

-- A Coop whose ui holds every line while the cart is using the screen (the
-- real Ui:whenFree rule) -- which, for a trainer wait, is the whole wait: the
-- trainerbattle command holds the VM "waiting" under the stand-in's cover.
local function coopHeld(partnerOnMap)
  local coop, sent, toasts = coopWith(partnerOnMap)
  local queued = {}
  coop.ui = {
    say = function() return {} end,
    whenFree = function(_, _, show)
      if Gen3Ui.occupied() then
        queued[#queued + 1] = show
        return { deferred = true }
      end
      return show()
    end,
  }
  return coop, sent, toasts, queued
end

do
  -- #1: a trainer wait that ends without a join must not freeze the game.
  local function waitOn(coop)
    local stand, results, started = trainerStand(326)
    stand:push(GAME)
    FakeVm.running = true
    eq(coop:onTrainerBattle(GAME, stand, "FR_ROUTE_1"), true, "a trainer wait is out")
    eq(Gen3Ui.occupied(), true, "and the player is busy for the whole of it")
    return stand, results, started
  end

  newGame()
  SESSION.party = { monOf(4, 10) }
  local coop, _, toasts, queued = coopHeld(true)
  local stand, _, started = waitOn(coop)
  coop:update(10, GAME)
  eq(started(), 1, "the clock: the cart's battle starts at once, not behind a queued box")
  eq(Gen3Ui.has(stand), false, "the cover is down")
  eq(toasts[#toasts], "BOB couldn't\njoin!", "and the line is in the corner")
  eq(#queued, 0, "nothing waits on a player who is never free")
  eq(coop.encounter, nil, "the encounter is spent")

  newGame()
  SESSION.party = { monOf(4, 10) }
  coop, _, toasts, queued = coopHeld(true)
  stand, _, started = waitOn(coop)
  coop:onDecline({ name = "BOB", reason = "no" })
  eq(started(), 1, "a decline: the cart's battle starts at once")
  eq(toasts[#toasts - 1], "BOB decided\nnot to join.", "said in the corner")
  eq(toasts[#toasts], "You can take\nthem alone!", "both lines")
  eq(#queued, 0, "none of it queued")

  newGame()
  SESSION.party = { monOf(4, 10) }
  coop, _, toasts, queued = coopHeld(true)
  stand, _, started = waitOn(coop)
  coop:onPartyEnd()
  eq(started(), 1, "the party ending: the cart's battle starts at once")
  eq(toasts[#toasts], "There's nobody\nto wait for.", "in the corner")

  newGame()
  SESSION.party = { monOf(4, 10) }
  coop, _, toasts, queued = coopHeld(true)
  stand, _, started = waitOn(coop)
  coop.waiting = nil
  coop:abandon("That battle can't\nstart.")
  eq(started(), 1, "an abandoned assembly: the held trainer is fought at once")
  eq(#queued, 0, "with nothing left queued")

  -- ...and the hub is told, so neither seat stays bound to the fight given
  -- up. Before, the goodbye came only from a finished battle.
  newGame()
  SESSION.party = { monOf(4, 10) }
  local sent
  coop, sent, toasts, queued = coopHeld(true)
  stand, _, started = waitOn(coop)
  coop.waiting = nil
  coop.running = true
  coop.battle = { plan = { id = "c7", hostId = "me" }, host = true,
                  parties = {}, badges = {}, ready = false }
  coop:abandon("That battle can't\nstart.")
  local leaves = 0
  for _, m in ipairs(sent) do
    if m.kind == Wire.COOP_LEAVE then leaves = leaves + 1 end
  end
  eq(leaves, 1, "giving up an assembly says goodbye to the hub, once")

  -- The partner's half: the hub calls the fight off while this player is
  -- still assembling, before any screen is up to hear it.
  newGame()
  SESSION.party = { monOf(4, 10) }
  coop, sent, toasts, queued = coopHeld(true)
  stand, _, started = waitOn(coop)
  coop.waiting = nil
  coop.running = true
  coop.battle = { plan = { id = "c8", hostId = "p2" }, host = false,
                  parties = {}, badges = {}, ready = false }
  coop:onBattleOutcome({ battle = "c9", outcome = "draw", reason = "gone" })
  check(coop.battle ~= nil, "an outcome for some other fight leaves the assembly be")
  eq(started(), 0, "and the held trainer with it")
  coop:onBattleOutcome({ battle = "c8", outcome = "draw", reason = "gone" })
  eq(coop.battle, nil, "the hub calling it off ends the assembly")
  eq(coop.running, false, "and the player is no longer mid-battle")
  eq(started(), 1, "the held trainer is fought at once")
  eq(toasts[#toasts], "The battle was\ncalled off.", "and the line is in the corner")
  eq(#queued, 0, "with nothing left queued")
end

do
  -- #3: a won trainer fight with this player's own team wiped: no whiteout
  -- (pret never whites out a won battle), and the beaten-script completes.
  newGame()
  local fainted = monOf(4, 10, { hp = 0 })
  SESSION.party = { fainted }
  SESSION.money = 1000
  local coop = coopWith(true)
  local stand, results = trainerStand(326)
  FakeVm.running = true
  coop.engineBattle = stand
  eq(Coop.blacksOut("win", GAME), true, "(this player's own team is on nothing)")
  coop:onBattleOver("win", GAME, { leveledUp = nil }, nil)
  CoopField.pump3(0.1)
  eq(results[1], "win", "the opcode hears the win (the flag, the beaten script)")
  eq(recorded("moneyLoss"), 0, "no whiteout money is taken")
  eq(recorded("respawn"), 0, "and nobody is warped mid-script")
  CoopField.pump3(100)
  eq(recorded("respawn"), 0, "not later either")
  eq(fainted.hp, 0, "the party stays as the fight left it (the cart's rule after a won battle)")
  eq(SESSION.money, 1200, "the prize is paid")

  -- A whiteout that answers no trainerbattle waits for the script to end.
  newGame()
  SESSION.party = { monOf(4, 10, { hp = 0 }) }
  FakeVm.running = true   -- a script is running (a beaten-script, an NPC)
  eq(Coop.blackout({}, GAME), true, "a party battle lost: the cart's whiteout")
  CoopField.pump3(0.1)
  eq(recorded("respawn"), 0, "its warp does not cut a running script off")
  FakeVm.running = false
  CoopField.pump3(0.1)
  eq(recorded("respawn"), 1, "it waits for the script to end")
end

do
  -- #5: a stand-in never reaches into a save other than its own.
  newGame()
  SESSION.party = { monOf(4, 10) }
  local stand, results, started = trainerStand(326)
  local old = SESSION
  SESSION = newSession()          -- CONTINUE: another session is running
  eq(stand:fightAlone(), false, "a stale stand-in is not handed back")
  eq(started(), 0, "the old save's trainer is never started in the new one")
  SESSION = old
  local stand2, results2, started2 = trainerStand(326)
  SESSION = newSession()
  eq(stand2:finish("win"), false, "a result for a save that is gone is dropped")
  CoopField.pump3(0.1)
  eq(#results2, 0, "and the new save's VM is never handed it")
  eq(#results, 0, "(nothing resumed)")
  SESSION = old
  local stand3, _, started3 = trainerStand(326)
  stand3:fightAlone()
  eq(started3(), 1, "a stand-in in its own save is handed back as ever")
  eq(started2(), 0, "(and the dropped one never was)")

  -- The deferred queue: a step queued by one save is dropped under another,
  -- and nothing runs off the field (a title screen) however long it waits.
  newGame()
  local ran = 0
  CoopField.defer3(function() ran = ran + 1 end, "a test step")
  -- (free now: it ran at once)
  eq(ran, 1, "a step with the field free runs at once")
  Gen3Ui.pushScreen(GAME, "RbyMmoText", { draw = function() end })
  CoopField.defer3(function() ran = ran + 1 end, "a test step")
  SESSION = newSession()
  CoopField.pump3(0.1)
  eq(ran, 1, "a step owed to another save is not run")
  eq(CoopField.pending3(), 0, "it is dropped")
  Gen3Ui.pop(GAME)
  CoopField.defer3(function() ran = ran + 1 end, "a test step")
  eq(ran, 2, "(the new save's own steps run)")
  GAME.phase = "title"
  CoopField.defer3(function() ran = ran + 1 end, "a test step")
  CoopField.pump3(CoopField.DEFER3_WAIT + 5)
  eq(ran, 2, "off the field nothing runs, even past the wait")
  GAME.phase = "field"
  CoopField.pump3(0.1)
  eq(ran, 3, "and it runs once the field is back in the same save")

  -- The disconnect path after a load: Coop:reset lets go of an old wait.
  newGame()
  SESSION.party = { monOf(4, 10) }
  local coop = coopWith(true)
  local waitStand, _, waitStarted = trainerStand(326)
  waitStand:push(GAME)
  coop:onTrainerBattle(GAME, waitStand, "FR_ROUTE_1")
  SESSION = newSession()
  coop:reset()
  eq(waitStarted(), 0, "a save load's disconnect starts no stale fight")
end

do
  -- #6: PP spent in a Gen 3 co-op NPC / wild fight reaches the session mon.
  local function ppScreen(mode)
    newGame()
    local mine = monOf(4, 20)
    SESSION.party = { mine }
    local b1, b2, trainer = npcSeats(GAME, 400)
    local screen = assert(CoopBattle.new(GAME, {
      slots = {
        { side = "a", owner = "me", name = "ANN", party = SESSION.party },
        { side = "a", owner = "p2", name = "BOB", party = { monOf(16, 20) } },
        { side = "b", name = "DUO", party = b1 },
        { side = "b", name = "DUO", party = b2 },
      },
      mine = 1, host = true, mode = mode, trainer = trainer, selfId = "me", battleId = "pp1",
    }))
    screen.medMine = Sheet3.mons(GAME, SESSION.party, {})
    screen:onBattleReady({ battle = "pp1", mode = mode,
      sides = { a = { "me", "p2" }, b = { "n1", "n2" } } })
    -- The referee's rows for our lead, one PP spent on the first move.
    local rows = Sheet3.moves(mine)
    rows[1].pp = rows[1].pp - 4
    screen:onBattleEvent({ battle = "pp1", seq = 1, t = "moves", slot = 0, side = "a", mon = 0,
      moves = rows })
    return mine, screen
  end
  local mine, screen = ppScreen("coop_npc")
  eq(screen.mediated, true, "(a refereed screen)")
  eq(mine.pp[1], 31, "a trainer fight's PP spend is written to the session mon")
  eq(mine.pp[2], 40, "slot by slot")
  eq(screen:liveMoves()[1].pp, 31, "and the FIGHT list shows it")
  mine = ppScreen("coop_wild")
  eq(mine.pp[1], 31, "and a party encounter's")
  mine = ppScreen("coop_pvp")
  eq(mine.pp[1], 35, "a fight between players spends nothing in the save (link rules)")
  -- An exp share that reached a spar anyway is not banked (link rules: no
  -- EXP); the same share in a trainer fight is.
  for _, mode in ipairs({ "coop_npc", "coop_pvp" }) do
    local _, sc = ppScreen(mode)
    sc.expCredit3 = 6
    sc:medRows({ battle = "pp1", seq = 5, t = "exp", slot = 0, side = "a",
                 speciesId = 16, level = 5, mon = 0, participants = 1 })
    if mode == "coop_npc" then
      check(sc.expBatch3 ~= nil, "(a trainer fight banks the share)")
    else
      eq(sc.expBatch3, nil, "a link battle banks no experience")
    end
  end
end

do
  -- #8: the co-op trainer party is the cart's and a solo fight's.
  newGame()
  local Solo = need("SoloBattle")
  local stand = trainerStand(326)
  local pers = Solo.gen3TrainerPersonalities(326, 1)
  check(pers ~= nil, "(the cart's name-hash personalities for this trainer)")
  eq(stand.enemyParty[1].personality, pers and pers[1],
     "the co-op foe carries the cart's personality, not a random one")
  local again = trainerStand(326)
  eq(again.enemyParty[1].personality, stand.enemyParty[1].personality,
     "so every visit meets the same monster")
  local soloParty = Solo.gen3TrainerParty(FakeTrainers.foeFromId(326), 326)
  eq(soloParty[1].personality, stand.enemyParty[1].personality, "the one a solo fight meets")
  eq(soloParty[1].nature, stand.enemyParty[1].nature, "with its nature")
  -- The rival is named the cart's way.
  SESSION.rivalName = "GARY"
  local rival = trainerStand(326)
  eq(rival.trainer.name, "GARY", "the rival's placeholder name is the player's rival's")
  eq(rival.label, "RIVAL GARY", "on the wire label too")
  SESSION.rivalName = nil
  -- Another mod's trainer.party hook reshapes the co-op team as it does the
  -- cart's (battle_bridge.lua hooked_trainer_party): the engine's own mod
  -- runtime is asked, so its two calls are the ones stood in for here.
  local Runtime = require("src.mods.Runtime")
  local Compat = require("src.mods.Gen3Compat")
  local saved3 = { Runtime.wantsHook, Runtime.call, Compat.partyNames, Compat.partyNums }
  Runtime.wantsHook = function(name) return name == "trainer.party" end
  Runtime.call = function(_, _, _, _, party)
    local out = {}
    for i, m in ipairs(party) do out[i] = m end
    out[#out + 1] = { species = 16, level = 9, iv = 0, moves = { 33 } }
    return out
  end
  Compat.partyNames = function(p) return p end
  Compat.partyNums = function(p) return p end
  local okHook, hooked = pcall(trainerStand, 326)
  Runtime.wantsHook, Runtime.call, Compat.partyNames, Compat.partyNums =
    saved3[1], saved3[2], saved3[3], saved3[4]
  check(okHook, "(the hooked build ran: " .. tostring(okHook or hooked) .. ")")
  eq(okHook and #hooked.enemyParty, 2, "a trainer.party hook's extra monster is in the co-op team")
  eq(okHook and (hooked.enemyParty[2] or {}).species, 16, "(the one it added)")
end

do
  -- #9: two identical knockouts in one action are two awards; the
  -- holders-only share pays EXP. SHARE holders alone.
  newGame()
  ITEMS[197] = { name = "EXP. SHARE", pocket = "ITEMS", price = 0, holdEffect = 25 }
  local lead = monOf(4, 10, { hp = 0 })
  local holder = monOf(16, 10, { heldItem = 197, item = 197 })
  SESSION.party = { lead, holder }
  local b1, b2, trainer = npcSeats(GAME, 400)
  local screen = assert(CoopBattle.new(GAME, {
    slots = {
      { side = "a", owner = "me", name = "ANN", party = SESSION.party },
      { side = "a", owner = "p2", name = "BOB", party = { monOf(16, 20) } },
      { side = "b", name = "DUO", party = b1 },
      { side = "b", name = "DUO", party = b2 },
    },
    mine = 1, host = true, mode = "coop_npc", trainer = trainer, selfId = "me", battleId = "x1",
  }))
  screen.medMine = Sheet3.mons(GAME, SESSION.party, {})
  screen.expCredit3 = 18
  screen:bankExp3({ speciesId = 16, level = 5, mon = 0, participants = 1 })
  screen:bankExp3({ speciesId = 16, level = 5, mon = 0, participants = 1 })
  local rows = {}
  screen:flushExp3Batch(rows)
  eq(#rows, 2, "two PIDGEY felled by one SURF are two knockouts, not one")
  screen:bankExp3({ speciesId = 16, level = 5, participants = 0 })
  rows = {}
  screen:flushExp3Batch(rows)
  eq(#rows, 1, "the holders-only share is a knockout of its own")
  local batch = rows[1] and rows[1].batch
  eq(batch and next(batch.sentIn), nil, "with nobody sent in (the fallen lead is not paid)")
  local leadExp, holderExp = lead.exp, holder.exp
  screen:gainExp3(rows[1])
  eq(lead.exp, leadExp, "the fainted participant earns nothing")
  check(holder.exp > holderExp, "the EXP. SHARE holder is paid (" .. tostring(holder.exp - holderExp) .. ")")
  ITEMS[197] = nil
end

do
  -- #11: an egg is carried, never fought.
  newGame()
  local egg = monOf(4, 5, { isEgg = true })
  local lead = monOf(4, 10)
  local bench = monOf(16, 10)
  SESSION.party = { egg, lead, bench }
  eq(Coop.blacksOut("loss", GAME), true, "(a loss is a loss)")
  lead.hp, bench.hp = 0, 0
  eq(Coop.blacksOut("win", GAME), true, "fainted monsters and an egg are a wiped team")
  lead.hp, bench.hp = lead.maxHp, bench.maxHp
  local b1, b2, trainer = npcSeats(GAME, 400)
  local screen = assert(CoopBattle.new(GAME, {
    slots = {
      { side = "a", owner = "me", name = "ANN", party = SESSION.party },
      { side = "a", owner = "p2", name = "BOB", party = { monOf(16, 20) } },
      { side = "b", name = "DUO", party = b1 },
      { side = "b", name = "DUO", party = b2 },
    },
    mine = 1, host = true, mode = "coop_npc", trainer = trainer, selfId = "me", battleId = "e1",
  }))
  local seat = screen.sim:slot(1)
  eq(seat.active, 2, "the seat opens on the first monster that can fight, not the egg")
  local bench3 = screen:benchOf(seat)
  eq(#bench3, 1, "the bench leaves the egg out")
  eq(bench3[1] and bench3[1].index, 3, "(the party index the referee's sheet carries)")
  for _, row in ipairs(screen:itemPartyRows()) do
    check(row.index ~= 1, "an item's POKeMON picker leaves the egg out")
  end
  eq(screen.sim:hasReserve(seat), 3, "and the egg is no reserve")
  local sheets = Sheet3.mons(GAME, SESSION.party, {})
  eq(sheets[2] and sheets[2].slot, 2, "(the sheet for the bench mon names party slot 3)")
end

do
  -- #12: co-op is asked before a wild's monster is built.
  newGame()
  local coop = coopWith(false)
  eq(coop:wouldTakeWild("FR_ROUTE_1"), false, "a partner on another map: co-op would not take it")
  local here = coopWith(true)
  eq(here:wouldTakeWild("FR_ROUTE_1"), true, "a partner here: it would")
  here.roster = { get = function() return { id = "p2", map = "FR_ROUTE_1", busy = true } end }
  eq(here:wouldTakeWild("FR_ROUTE_1"), false, "a partner mid-trade: it would not")
  here.roster = { get = function() return { id = "p2", map = "FR_ROUTE_1" } end }
  here.wildCoop = false
  eq(here:wouldTakeWild("FR_ROUTE_1"), false, "WILD: OFF: it would not")
end

do
  -- PAY DAY's coins, picked up by side a after its win (RF8's outcome field).
  local function payScreen(mode, side, heldCoin, foeCoin, version, winners)
    newGame(version and { version = version } or nil)
    ITEMS[189].holdEffect = 32
    local mine = monOf(4, 20, heldCoin and { heldItem = 189, item = 189 } or nil)
    SESSION.party = { mine }
    SESSION.money = 1000
    local b1, b2, trainer = npcSeats(GAME, 400)
    local slots = {
      { side = side, owner = "me", name = "ANN", party = SESSION.party },
      { side = side, owner = "p2", name = "BOB", party = { monOf(16, 20) } },
      { side = side == "a" and "b" or "a", name = "DUO", party = b1 },
      { side = side == "a" and "b" or "a", name = "DUO", party = b2 },
    }
    local screen = assert(CoopBattle.new(GAME, {
      slots = slots, mine = 1, host = true, mode = mode, trainer = trainer,
      selfId = "me", battleId = "pd1" }))
    screen.medMine = Sheet3.mons(GAME, SESSION.party, {})
    local sides = side == "a" and { a = { "me", "p2" }, b = { "n1", "n2" } }
      or { b = { "me", "p2" }, a = { "n1", "n2" } }
    screen:onBattleReady({ battle = "pd1", mode = mode, sides = sides })
    if heldCoin then screen.fielded3 = { [1] = true } end
    if foeCoin then
      b1[1].heldItem, b1[1].item = 189, 189
      screen:noteFoeAmulet3(screen.sim:slot(3), 1)
    end
    screen:onBattleOutcome({ battle = "pd1", outcome = "win", winners = winners or { "me", "p2" },
      losers = { "n1", "n2" }, reason = "ko", payDay = 45 })
    return screen
  end
  local screen = payScreen("coop_wild", "a", false)
  eq(SESSION.money, 1045, "PAY DAY's coins are picked up after the win")
  eq(screen.payDayPaid, 45, "(what was paid)")
  local said = false
  for _, row in ipairs(screen.messages or {}) do
    local text = type(row) == "table" and (row.text or row.msg) or row
    if type(text) == "string" and text:find("picked up", 1, true) then said = true end
  end
  if type(screen.shown) == "string" and screen.shown:find("picked up", 1, true) then said = true end
  check(said, "and the cart's line is said")
  payScreen("coop_npc", "a", true)
  eq(SESSION.money, 1090, "an AMULET COIN this player fielded doubles them")
  payScreen("coop_pvp", "a", false)
  eq(SESSION.money, 1000, "a fight between players pays none (link rules)")
  payScreen("coop_npc", "a", false, true, "firered")
  eq(SESSION.money, 1090, "FireRed doubles them for a foe's AMULET COIN too")
  payScreen("coop_npc", "a", false, true, "emerald")
  eq(SESSION.money, 1045, "Emerald counts only the player's own (amuletCoinPlayerOnly)")
  local other = payScreen("coop_wild", "a", false, false, nil, { "p2" })
  eq(SESSION.money, 1000, "a player the outcome does not name a winner picks nothing up")
  eq(other.payDayPaid, nil, "(nothing owed)")
end

do
  -- A spar lost is not a whiteout: no money, no warp (the cart reloads the
  -- party after a link battle and carries on where the player stands).
  newGame()
  SESSION.party = { monOf(4, 10, { hp = 0 }) }
  SESSION.money = 1000
  local coop = coopWith(true)
  coop.battle = { plan = { id = "pv2", allies = { { id = "me" }, { id = "p2" } },
                           foes = { { id = "p3" }, { id = "p4" } } } }
  coop:onBattleOver("loss", GAME, { mode = "coop_pvp" }, nil)
  CoopField.pump3(100)
  eq(recorded("moneyLoss"), 0, "a lost spar takes no whiteout money")
  eq(recorded("respawn"), 0, "and sends nobody to a POKeMON CENTER")
  eq(SESSION.money, 1000, "the wallet is untouched")
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
  -- RF6 #10: taking is not beginning. A wait that times out hands the fight
  -- back and the cart's own start does the bookkeeping; counting it at the
  -- take counted it twice.
  eq(recorded("league"), 0, "the start's bookkeeping does not run at the take")
  local stand = taken[1].stand
  stand:fightAlone()
  eq(recorded("engineStart"), 1, "handing it back starts the cart's own battle")
  eq(recorded("league"), 0, "and the mod runs none of the start's bookkeeping for it")
  stand:fightAlone()
  eq(recorded("engineStart"), 1, "once")
  local fought = CoopField.trainerStand3(foe, { trainerId = 326 }, { game = GAME })
  eq(fought:begin3(), true, "a fight the mod fights begins with the start's bookkeeping")
  eq(recorded("league"), 1, "(the league friendship pass)")
  eq(fought:begin3(), false, "once")
  eq(recorded("league"), 1, "and never twice")

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

  -- RF6 #2: a start this mod makes to hand a fight back is the cart's.
  taken = {}
  local handedBefore = recorded("engineStart")
  FakeBB.startWild("ENGINE_MOD", GAME, { species = 16, level = 5 },
    { [CoopField.HANDBACK3] = true })
  eq(#taken, 0, "a handed-back wild is never offered to a divert again")
  eq(recorded("engineStart"), handedBefore + 1, "it reaches the cart as handed back")
  FakeBB.startWild("ENGINE_MOD", GAME, { species = 16, level = 5 }, {})
  eq(#taken, 1, "and the marker marked that one start, not the next")

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
  eq(spied and spied.enc.speciesId, 16, version .. ": solo was handed the rolled encounter")
  check(spied and spied.enc ~= enc and enc.mon == nil,
        version .. ": (a copy: the cart's own encounter table is not written)")
  local built = spied and spied.opts.party
  eq(type(built) == "table" and #built, 1, version .. ": with the monster the stand-in built")
  eq(spied and spied.enc.mon, built and built[1], version .. ": as the encounter's own mon too")
  eq(spied and spied.game, game, version .. ": on the live game")
  eq(type(spied and spied.opts.done), "function", version .. ": with a done to call")
  eq(type(spied and spied.opts.fallback), "function", version .. ": and a way to hand it back")
  eq(encReset, resets + 1, version .. ": the encounter rate re-arms as a battle start does")
  eq(#Gen3Ui.states(), 0, version .. ": the cover came down for solo's own screen")
  -- RF6 #2: handing a step wild back starts the cart's own fight once -- the
  -- start wrap must not offer it to solo (or a co-op wait) all over again.
  local offers, startsBefore = 0, recorded("engineStart")
  local spy = ctx.solo.fromGen3Encounter
  ctx.solo.fromGen3Encounter = function(...) offers = offers + 1; return spy(...) end
  spied.opts.fallback()
  eq(recorded("engineStart"), startsBefore + 1, version .. ": a handed-back wild is the cart's fight")
  eq(offers, 0, version .. ": and nobody is offered it again (no divert loop)")
  -- ...against the very monster the cover announced and solo was handed:
  -- the engine re-rolls whatever the foe row leaves out.
  local handedFoe
  for _, r in ipairs(rec) do if r.kind == "engineStart" then handedFoe = r[1] end end
  local lead = built and built[1]
  eq(handedFoe and handedFoe.personality, lead and lead.personality,
     version .. ": the handed-back wild keeps its personality")
  check(handedFoe and lead and handedFoe.ivs == lead.ivs and type(lead.ivs) == "table",
        version .. ": ...its IVs (not a re-roll)")
  eq(handedFoe and handedFoe.item, lead and (tonumber(lead.item) or tonumber(lead.heldItem) or 0),
     version .. ": ...its held item")
  eq(table.concat((handedFoe and handedFoe.moves) or {}, ","),
     table.concat((lead and lead.moves) or {}, ","), version .. ": ...its moves")
  eq(handedFoe and handedFoe.level, lead and lead.level, version .. ": ...its level")
  spied.opts.fallback()
  eq(recorded("engineStart"), startsBefore + 1, version .. ": once")
  ctx.solo.fromGen3Encounter = spy
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
