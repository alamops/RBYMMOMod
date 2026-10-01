-- Headless Gen 3 solo double battles (the solo-doubles plan, task T4): the
-- two-a-side screen `CoopBattle.newSoloDouble` builds for a lone trainer's
-- double on FireRed / LeafGreen / Emerald, and the GBA double page
-- `src/ClassicBattle.lua` draws from the model it hands over (contracts C3
-- and C4 of docs/plans/gen3-solo-doubles.md).
--
-- The shape tests/gen3_coop.lua and tests/gen3_solo.lua set: a FireRed-shaped
-- boot (the stub facade says generation 3) over the engine SDK's own Gen 3
-- fixture (T.sdk.gen3Data, synthetic numbers), the engine modules that would
-- need an imported cache stood in by small fakes that record what they were
-- asked, and the engine's own *pure* modules run for real (the exp curve, the
-- game3 modal stack).  The referee is the real src/BattleSim3 seated with
-- `seats = 2` on both sides (contract C1), and the screen is the real
-- CoopBattle built through its real constructor.  What stands where
-- src/SoloBattle.lua stands is a table transport: it maps a choice's `seat`
-- (the field slot the screen names) onto the seat's referee id, files it, and
-- hands the referee's events back -- so a fight here is the fight a player
-- gets, minus the pixels.
--
--   1. uploads and seating: what `start` sends, `medMap` of the shared
--      team's `#2` seat, the leads;
--   2. the opening: the trainer's line, its send-out, ours -- one mon and two;
--   3. two commands a turn: each filed with its `seat` as it is confirmed; a
--      command the referee refuses keeps that seat's menu with the cart's
--      line and mon 2 is never asked; B back to mon 1 through the referee's
--      `cancel`, its claim released (and not after a medicine); a seat the
--      referee answered for (a recharge) is skipped; one standing seat, one
--      command; the bare `turn`;
--   4. the party list: the bench leaves out both actives and the sibling's
--      pick, the cart's two refusal lines, the list reopened after one;
--   5. aiming: asked only when more than one other battler stands, the
--      partner may be aimed at, a Ghost's CURSE is aimed and the referee
--      lands it where it was aimed, the cart's ring on the GBA page, B back
--      to the move menu;
--   6. replacement: a double knockout owes two picks in battler order, the
--      second bench leaves out the first's claim; one bench monster refills
--      one seat; a seat left empty that the referee asks for again (a REVIVE
--      gave the party a bench) gets its picker, its send-out, and its menu;
--   7. one bag: a medicine filed for mon 1 is out of mon 2's bag, an X item is
--      only ever the chooser's own monster's;
--   8. the ending: EXP to both seats, `onDone("win")`, the after-words said
--      through `say`, PAY DAY after them, a loss;
--   9. the C4 model: `double.foes / allies / choosing / blink / hpText` and
--      the move rows' `num` / `target` through the command, move, target and
--      list phases;
--  10. ClassicBattle's pure functions fed by that model: the double layout,
--      the blink clock, the move-target preview, the preview fade;
--  11. the arena: one human with two ally seats and one trainer behind two
--      foes -- every rect on screen, none on another;
--  12. the co-op regression guard: a minimal co-op `CoopBattle.new`
--      (`ownSlots == nil`) keeps one `mine`, one command a turn and the
--      strip classic model.
--  13. through src/SoloBattle.lua: a lone double is taken onto this screen and
--      played to the win on the glue the caller owns (the seat -> referee id
--      map, the referee, the `done` the trainer script resumes on, the
--      refusal's line), the backstop for a seat the screen stopped asking
--      about (silent in a real fight), and a trainer seat asked again.
--
-- Each block of checks runs under `block`, so an error in one flow is a
-- failure of its own and the rest of the run is still measured.
--
-- Legal: every species, move, trainer and item row below is the SDK
-- fixture's or invented here with synthetic numbers; the only real values are
-- pret enum numbers the battle code branches on (MOVE_TARGET_*, EFFECT_*,
-- TYPE_*, ITEM_* ids and the MOVE_CURSE / MOVE_HAZE / MOVE_HELPING_HAND
-- numbers the preview reads), the policy docs/plans/gen3-battle-sheet.md
-- states for the sim.
--
-- Run from the engine checkout root:
--
--   luajit mods/rby_mmo/tests/gen3_solo_double.lua

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
  return { family = rse and "rse" or "frlg", safari = false, kinds = { ghost = not rse },
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
local Wire = need("Wire")
local Gen3Ui = need("Gen3Ui")
local Sheet3 = need("Sheet3")
local CoopField = need("CoopField")
local CoopBattle = need("CoopBattle")

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


-- =====================================================================
-- the rig: the screen under test, the real referee beside it
-- =====================================================================

local Turn = need("BattleSim3/Turn")
local Battlefield = need("Battlefield")
local ClassicBattle = need("ClassicBattle")
local Mediated = need("MediatedBattle")
local Solo = need("SoloBattle")
local G3, G3D = ClassicBattle.G3, ClassicBattle.G3D

-- One block of checks.  An error raised inside it is a failure of its own, not
-- the end of the run: a screen that breaks one flow should still be measured on
-- the rest.
local function block(name, fn)
  local ok, err = pcall(fn)
  if not ok then check(false, name .. ": the block raised -- " .. tostring(err):match("^[^\n]*")) end
end

-- More synthetic rows, in the fixture's shapes.  A Ghost and CURSE (the cart's
-- menu aims a Ghost's CURSE although its table byte is USER); HYPER BEAM's
-- recharge turn (EFFECT_RECHARGE, a turn the referee answers for); a move for
-- each target byte the move-menu preview tells apart; and X ATTACK.
ROM[174] = { effect = 109, power = 0, type = 7, accuracy = 0, pp = 10,
             secondaryChance = 0, target = 16, priority = 0, flags = 0 }
P3._moveNames[174] = "CURSE"
ROM[63] = { effect = 80, power = 40, type = 0, accuracy = 100, pp = 5,
            secondaryChance = 0, target = 0, priority = 0, flags = 0 }
P3._moveNames[63] = "HYPER BEAM"
-- FOES_AND_ALLY (32) and OPPONENTS_FIELD (64): hovered, never used.
ROM[90] = { effect = 0, power = 30, type = 0, accuracy = 100, pp = 10,
            secondaryChance = 0, target = 32, priority = 0, flags = 0 }
P3._moveNames[90] = "SHOCKWAVE"
ROM[91] = { effect = 0, power = 0, type = 0, accuracy = 0, pp = 20,
            secondaryChance = 0, target = 64, priority = 0, flags = 0 }
P3._moveNames[91] = "FIELDWALL"
-- A USER move that touches the whole field (HAZE's number) and one that helps
-- the partner (HELPING HAND's): both preview by number, not by byte.
ROM[114] = { effect = 0, power = 0, type = 0, accuracy = 0, pp = 30,
             secondaryChance = 0, target = 16, priority = 0, flags = 0 }
P3._moveNames[114] = "HAZE"
ROM[270] = { effect = 0, power = 0, type = 0, accuracy = 0, pp = 20,
             secondaryChance = 0, target = 16, priority = 5, flags = 0 }
P3._moveNames[270] = "HELPING HAND"
P3._names[92] = "GASTLY"
P3._types[92] = { 7, 3 }
P3._stats[92] = P3._stats[16]
P3._speciesMeta[92] = P3._speciesMeta[16]
P3._abilities[92] = { 51, 0 }
P3._learnsets[92] = { { 1, 174 } }
ITEMS[75] = { name = "X ATTACK", pocket = "ITEMS", price = 500 }
ITEMS[24] = { name = "REVIVE", pocket = "ITEMS", price = 1500 }
if not FakePokemon.types then
  function FakePokemon.types(sp) return P3._types[tonumber(sp)] end
end

-- A party mon whose PP follows its moves.
local function mon(species, level, extra)
  extra = copyTable(extra or {})
  if extra.moves and not extra.pp then
    extra.pp, extra.maxPp = {}, {}
    for i, id in ipairs(extra.moves) do
      extra.pp[i], extra.maxPp[i] = FakePokemon.movePp(id), FakePokemon.movePp(id)
    end
  end
  return monOf(species, level, extra)
end

-- The trainer's team, as the fixture's row 400 holds it.
local FOE_DEFAULT = {
  { species = 151, level = 6, iv = 0, moves = { 33 } },
  { species = 16, level = 6, iv = 0, moves = { 33 } },
}

-- The line each distinct `shown` text printed, in order.
local function shownLog(screen, seen)
  local s = screen.shown
  if s ~= nil and s ~= seen._last then
    seen[#seen + 1] = s
    seen._last = s
  end
  if s == nil then seen._last = nil end
end

local function flat(line) return (tostring(line):gsub("\n", " ")) end

-- Everything that drives a screen against a referee, once both exist: the
-- referee's events fed to the screen in order, the trainer side and anybody
-- else the screen does not own answering for themselves, one frame at a time.
local function attachRig(ctx, screen, sim, autoIds)
  ctx.screen, ctx.sim = screen, sim
  ctx.events = {}
  function ctx.feed(ev)
    ctx.seq = ctx.seq + 1
    ev.battle = ctx.battleId
    ev.seq = ctx.seq
    ctx.events[#ctx.events + 1] = ev
    screen:onEvent(ev)
  end
  function ctx.pump()
    for _ = 1, 6 do
      local any = false
      for _, id in ipairs(autoIds) do
        for _, seat in ipairs(sim:seatsOf(id)) do
          if sim:autoPick(seat.playerId) then any = true end
        end
      end
      if not any then break end
    end
    for _, ev in ipairs(sim:drainEvents()) do ctx.feed(ev) end
    sim:tick(0)
    for _, ev in ipairs(sim:drainEvents()) do ctx.feed(ev) end
    local out = sim:outcome()
    if out and not ctx.settled then
      ctx.settled = true
      ctx.outcome = out
      screen:onOutcome(out)
      for _, line in ipairs(ctx.afterWords or {}) do screen:say(line) end
    end
  end
  function ctx.tick(key)
    GAME.input = fakeInput(key)
    screen:update(key and (1 / 60) or 1.0)
    GAME.input = fakeInput()
    shownLog(screen, ctx.seen)
  end
  function ctx.press(key)
    ctx.pump()
    ctx.tick(key)
  end
  -- Read down to the next menu (synced), a picker, or the end.
  function ctx.settle()
    for _ = 1, 2000 do
      ctx.pump()
      ctx.tick(nil)
      if screen.finished then
        if not ctx.done then screen:exit() end
        return "finished"
      end
      if screen.replacing and not screen:boxLive() then return "replacing" end
      if screen.phase == "switch" and not screen:boxLive() then return "switch" end
      if screen.phase == "choose" and not screen:boxLive() then
        -- one more frame: the handover's chooser sync
        ctx.tick(nil)
        if screen.phase == "choose" then return "choose" end
      end
    end
    return "stuck:" .. tostring(screen.phase)
  end
  ctx.pump()
  return ctx
end

-- A solo double, the way src/SoloBattle.lua builds one: our party, the fixture
-- trainer 400 (its team is `opts.foeParty`), the referee seated with
-- `seats = 2` on both sides from what `start` uploaded, and a table transport
-- that files each choice under the seat id its `seat` names -- answering the
-- referee's verdict at once, and naming a refusal the way SoloBattle's
-- transport does (`refusal`, Solo.refusalText3).
--
--   party, foeParty   the two teams
--   bag               { { itemId, count } ... } put into the session bag first
--   foeItems          the trainer's four item ids (its kit, uploaded as side b's bag)
--   classicUi         the GBA page rather than the arena
--   seed              the referee's
local function makeFight(opts)
  opts = opts or {}
  newGame()
  SESSION.party = opts.party
  for _, entry in ipairs(opts.bag or {}) do FakeBag.add(SESSION.bag, entry[1], entry[2]) end
  TRAINERS[400].party = opts.foeParty or FOE_DEFAULT
  TRAINERS[400].items = opts.foeItems or { 0, 0, 0, 0 }
  local trainerFoe = FakeTrainers.foeFromId(400)
  local foeParty = assert(CoopField.trainerParty3(trainerFoe))
  local sheets = Sheet3.mons(GAME, foeParty, {})
  local trainer = CoopField.trainerRecord3(trainerFoe)
  trainer.trainerName = trainer.name
  local foeSeats = (#sheets >= 2) and 2 or 1
  local ctx = { choices = {}, sent = {}, seq = 0, seen = {}, battleId = "sd1", sheets = sheets }
  local pending = {}
  local transport = {
    isReady = function() return true end,
    send = function(self_, kind, payload)
      ctx.sent[#ctx.sent + 1] = { kind = kind, payload = payload }
      if kind == Wire.BATTLE_RULESET then
        pending.ruleset = payload
      elseif kind == Wire.BATTLE_PARTY then
        if payload.side == "b" then pending.foe = payload else pending.party = payload end
      elseif kind == Wire.BATTLE_CHOICE then
        ctx.choices[#ctx.choices + 1] = copyTable(payload)
        self_.refusal = nil
        local seatId
        if payload.seat == 0 then seatId = "solo_player"
        elseif payload.seat == 1 then seatId = "solo_player#2" end
        if not seatId then
          ctx.unseated = (ctx.unseated or 0) + 1
          return false
        end
        local ok, filed = pcall(ctx.sim.submitChoice, ctx.sim, seatId, payload)
        if not ok then ctx.err = filed end
        if ok and not filed then
          ctx.refused = (ctx.refused or 0) + 1
          self_.refusal = Solo.refusalText3(ctx.sim, seatId, payload)
        end
        return (ok and filed) and true or false
      end
    end,
  }
  local screen, why = CoopBattle.newSoloDouble(GAME, {
    transport = transport, battle = "sd1", trainer = trainer,
    peerName = "PKMN TRAINER DUO", npcParty = sheets, mode = "coop_npc",
    selfId = "solo_player", foeId = "solo_foe", foeSeats = foeSeats,
    onDone = function(result, toLearn) ctx.done = { result = result, toLearn = toLearn } end,
    classicUi = opts.classicUi,
  })
  assert(screen, why)
  ctx.started = screen:start(GAME)
  ctx.pending = pending
  local ruleset = pending.ruleset or {}
  local sim, err = Turn.create({
    id = "sd1", mode = "coop_npc", seed = opts.seed or 11,
    typeTable = ruleset.typeTable, specialTypes = ruleset.specialTypes,
    movePool = ruleset.movePool, choiceTimeout = 0, now = 0,
    sides = {
      a = { { playerId = "solo_player", seats = 2, name = "ANN",
              mons = pending.party.mons, bag = pending.party.bag } },
      b = { { playerId = "solo_foe", seats = foeSeats, name = "DUO", mons = sheets,
              bag = pending.foe and pending.foe.bag or nil } },
    },
  })
  assert(sim, err)
  screen:enter()
  local sidesB = foeSeats == 2 and { "solo_foe", "solo_foe#2" } or { "solo_foe" }
  screen:onReady({ battle = "sd1", mode = "coop_npc",
                   sides = { a = { "solo_player", "solo_player#2" }, b = sidesB } })
  return attachRig(ctx, screen, sim, { "solo_foe" })
end

-- A minimal co-op fight on the same shell, built the way tests/gen3_coop.lua
-- builds one: our seat and a partner's against a trainer dealt into two
-- buckets, the referee holding four separate fighters, the partner and the
-- trainer answering for themselves.  `ownSlots` is nil here.
local function makeCoop(opts)
  opts = opts or {}
  newGame()
  SESSION.party = opts.party
  local partnerParty = opts.partnerParty
  TRAINERS[400].party = FOE_DEFAULT
  local foe = FakeTrainers.foeFromId(400)
  local party = assert(CoopField.trainerParty3(foe))
  local packed = assert(CoopBattle.packParty(party, GAME))
  local b1, b2 = {}, {}
  for i, m in ipairs(assert(CoopBattle.unpackParty(GAME, packed))) do
    if i % 2 == 1 then b1[#b1 + 1] = m else b2[#b2 + 1] = m end
  end
  local trainer = CoopField.trainerRecord3(foe)
  local ctx = { choices = {}, sent = {}, seq = 0, seen = {}, battleId = "c1" }
  local transport = {
    isReady = function() return true end,
    send = function(_, kind, payload)
      ctx.sent[#ctx.sent + 1] = { kind = kind, payload = payload }
      if kind == Wire.BATTLE_CHOICE then
        ctx.choices[#ctx.choices + 1] = copyTable(payload)
        local ok, filed = pcall(ctx.sim.submitChoice, ctx.sim, "me", payload)
        if not ok then ctx.err = filed end
        return (ok and filed) and true or false
      end
    end,
  }
  local screen = assert(CoopBattle.new(GAME, {
    slots = {
      { side = "a", owner = "me", name = "ANN", party = SESSION.party },
      { side = "a", owner = "p2", name = "BOB", party = partnerParty },
      { side = "b", name = "DUO", party = b1 },
      { side = "b", name = "DUO", party = b2 },
    },
    mine = 1, host = true, mode = "coop_npc", trainer = trainer, selfId = "me",
    battleId = "c1", transport = transport, classicUi = opts.classicUi,
  }))
  screen.medMine = Sheet3.mons(GAME, SESSION.party, {})
  local ruleset = Mediated.snapshotRuleset(GAME, { wild = false })
  local sim = assert(Turn.create({
    id = "c1", mode = "coop_npc", seed = opts.seed or 5, typeTable = ruleset.typeTable,
    specialTypes = ruleset.specialTypes, movePool = ruleset.movePool, choiceTimeout = 0, now = 0,
    sides = {
      a = { { playerId = "me", name = "ANN", mons = screen.medMine },
            { playerId = "p2", name = "BOB", mons = Sheet3.mons(GAME, partnerParty, {}) } },
      b = { { playerId = "n1", name = "DUO", mons = Sheet3.mons(GAME, b1, {}) },
            { playerId = "n2", name = "DUO", mons = Sheet3.mons(GAME, b2, {}) } },
    },
  }))
  screen:enter()
  screen:onReady({ battle = "c1", mode = "coop_npc",
                   sides = { a = { "me", "p2" }, b = { "n1", "n2" } } })
  return attachRig(ctx, screen, sim, { "p2", "n1", "n2" })
end

-- ------- driving the menus the way a player does

-- Walk the aim cursor to the battler on screen slot `index` (any, when nil) and
-- confirm it.
local function aimAt(f, index)
  local s = f.screen
  if index ~= nil then
    for _ = 1, 4 do
      local pick = s:targetChoices()[s.targetIndex]
      if pick and pick.index == index then break end
      f.press("down")
    end
  end
  f.press("a")
end

-- From a command menu: FIGHT, the move on row `row`, and -- when that move
-- opens the aim -- the battler `aim`.
local function fightWith(f, row, aim)
  local s = f.screen
  s.commandIndex = 1
  f.press("a")
  s.moveIndex = row or 1
  f.press("a")
  if s.phase == "target" then aimAt(f, aim) end
end

-- A whole turn's two commands: each seat's first move at its first foe.
local function bothFight(f)
  local s = f.screen
  fightWith(f, 1)
  if s.phase == "choose" and s.mine == 2 then fightWith(f, 1) end
end

-- How many of this turn's commands the screen has filed with the referee (an
-- emptied table holds none).
local function filedCount(s)
  local n = 0
  for _ in pairs(s.filed or {}) do n = n + 1 end
  return n
end

-- Does `line` carry every one of `...` (plain text)?
local function says(line, ...)
  if type(line) ~= "string" then return false end
  for _, needle in ipairs({ ... }) do
    if not line:find(needle, 1, true) then return false end
  end
  return true
end

-- The n-th command the screen sent, or an empty one.
local function choiceAt(f, n) return f.choices[n] or {} end

-- The command own seat `seat` (1 | 2) has filed this turn, or an empty one.
local function filedAction(s, seat)
  local filed = s.filed and s.filed[seat]
  return filed and filed.action or {}
end

-- Read the box down to whatever it hands back to (a menu, a list, a picker),
-- and say which: `settle` only stops at the command menu, a switch list or a
-- replacement picker, and a refusal goes back to the move or item list too.
local function readOut(f)
  local s = f.screen
  for _ = 1, 400 do
    if s.phase ~= "messages" and not s:boxLive() then return s.phase end
    f.press(nil)
  end
  return "stuck:" .. tostring(s.phase)
end

-- The referee's seat fighters, and the choice each holds.
local PLAYER1, PLAYER2 = "solo_player", "solo_player#2"
local function heldBy(f, id) return f.sim.byId[id] and f.sim.byId[id].choice end

-- Every `chose` / `unchose` the referee sent for our side, as "c0", "u0", ...
local function choseLog(f)
  local out = {}
  for _, ev in ipairs(f.events) do
    if (ev.t == "chose" or ev.t == "unchose") and ev.side == "a" then
      out[#out + 1] = (ev.t == "chose" and "c" or "u") .. tostring(ev.slot)
    end
  end
  return table.concat(out, ",")
end

-- Indices as "a,b,c", whatever is missing.
local function joined(...)
  local out = {}
  for i = 1, select("#", ...) do out[i] = tostring((select(i, ...))) end
  return table.concat(out, ",")
end

local function lineIndex(list, ...)
  for i, line in ipairs(list) do
    if says(line, ...) then return i end
  end
  return nil
end

local function overlaps(a, b)
  return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h
end
local function sameRect(a, b)
  return a ~= nil and b ~= nil and a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h
end

-- ------------------------------------------------------------------
-- 1. uploads and seating
-- ------------------------------------------------------------------

block("uploads", function()
  local f = makeFight({
    party = { mon(4, 20), mon(16, 20), mon(29, 18), mon(5, 18) },
    bag = { { 13, 2 }, { 75, 1 } }, foeItems = { 13, 0, 0, 0 },
  })
  local s = f.screen
  check(f.started == true, "uploads: start() answers true")
  eq(#f.sent, 3, "uploads: exactly three messages went out")
  eq(f.sent[1] and f.sent[1].kind, Wire.BATTLE_RULESET, "uploads: the ruleset goes first")
  eq(f.sent[2] and f.sent[2].kind, Wire.BATTLE_PARTY, "uploads: then the player's party")
  eq(f.sent[3] and f.sent[3].kind, Wire.BATTLE_PARTY, "uploads: then the trainer's")

  local ruleset = f.sent[1].payload
  check(type(ruleset.typeTable) == "table" and next(ruleset.typeTable) ~= nil,
        "uploads: the ruleset carries the type chart")
  check(type(ruleset.movePool) == "table" and next(ruleset.movePool) ~= nil,
        "uploads: ...and the move pool")
  eq(ruleset.generation, 3, "uploads: ...for Gen 3")

  local mine = f.sent[2].payload
  eq(mine.battle, "sd1", "uploads: the party names the battle")
  eq(mine.side, nil, "uploads: the player's party has no side (the transport reads nil as ours)")
  eq(#mine.mons, 4, "uploads: four sheets, the whole team")
  eq(tonumber(mine.mons[1].speciesId), 4, "uploads: in party order (the lead first)")
  eq(tonumber(mine.mons[4].speciesId), 5, "uploads: ...to the last")
  local counts = {}
  for _, entry in ipairs(mine.bag or {}) do counts[tonumber(entry.id)] = entry.count end
  eq(counts[13], 2, "uploads: the bag rides along (two POTION)")
  eq(counts[75], 1, "uploads: ...and the X ATTACK")

  local foe = f.sent[3].payload
  eq(foe.battle, "sd1", "uploads: the trainer's team names the battle")
  eq(foe.side, "b", "uploads: the trainer's team is side b")
  eq(#foe.mons, 2, "uploads: two trainer sheets")
  check(rawequal(foe.mons, f.sheets), "uploads: the sheets handed to the screen are the ones uploaded")
  eq(foe.bag and foe.bag[1] and tonumber(foe.bag[1].id), 13, "uploads: with the trainer's kit (its POTION)")

  local again = #f.sent
  check(s:start(GAME) == true, "uploads: a second start() still answers true")
  eq(#f.sent, again, "uploads: ...and sends nothing again")

  -- the screen's own identity
  check(s.soloDouble == true, "uploads: the screen says it is a solo double")
  eq(joined(s.ownSlots[1], s.ownSlots[2]), "1,2", "uploads: both of side a's seats are ours")
  eq(s.battle, "sd1", "uploads: `battle` is the id the caller handed in")
  check(type(s.onDone) == "function", "uploads: `onDone` is the caller's")
  eq(s.foeId, nil, "uploads: the trainer's owner id is accepted and not kept (nothing reads it)")
  eq(s.mode, "coop_npc", "uploads: the mode the hub path reads for a trainer")

  -- the referee seated both sides' shared teams from those uploads
  local seats = f.sim:seatsOf("solo_player")
  eq(#seats, 2, "referee: the player's shared team is two seats")
  eq(seats[1].playerId, "solo_player", "referee: seat 1 keeps the player id")
  eq(seats[2].playerId, "solo_player#2", "referee: seat 2 is `#2`")
  eq(seats[2].owner, "solo_player", "referee: both seats are the player's")
  eq(#f.sim:seatsOf("solo_foe"), 2, "referee: the trainer's two foes are two seats")

  -- medMap: the shared team's second seat lands on our second slot, not the first
  eq(s.medSlots[0], 1, "medMap: field 0 is our seat 1")
  eq(s.medSlots[1], 2, "medMap: field 1 (solo_player#2) is our seat 2")
  eq(s.medSlots[3], 3, "medMap: field 3 is the trainer's seat 1")
  eq(s.medSlots[4], 4, "medMap: field 4 is the trainer's seat 2")
  eq(s.medFields[1], 0, "medMap: and back, seat 1 is field 0")
  eq(s.medFields[2], 1, "medMap: seat 2 is field 1")
  eq(s.medFields[3], 3, "medMap: seat 3 is field 3")
  eq(s.medFields[4], 4, "medMap: seat 4 is field 4")
  local byField = s:medMap({ a = { "solo_player", "solo_player#2" }, b = { "solo_foe" } })
  eq(byField[1], 2, "medMap: `#2` takes the owner's next seat on that side")
  eq(byField[3], 3, "medMap: a trainer with one foe is field 3")
  eq(byField[4], nil, "medMap: ...and field 4 is nobody")

  -- the leads: the live session mons, mon 1 and mon 2
  eq(s.sim:slot(1).battler.mon, SESSION.party[1], "leads: seat 1 fights with the live mon 1")
  eq(s.sim:slot(2).battler.mon, SESSION.party[2], "leads: seat 2 fights with the live mon 2")
  eq(s.sim:slot(1).party, s.sim:slot(2).party, "leads: one party behind both seats")
  eq(s.mine, 1, "leads: mon 1 chooses first")
  eq(s.chooser, 1, "leads: the chooser starts at 1")
  eq(f.err, nil, "leads: nothing threw")
end)

-- A fainted monster and an egg are not leads: seat 1 gets the first monster
-- that can fight, seat 2 the next one after it (contract C1).
block("leads", function()
  local f = makeFight({
    party = { mon(4, 20, { hp = 0 }), mon(16, 20, { isEgg = true }), mon(29, 20),
              mon(5, 18), mon(16, 18) },
  })
  local s = f.screen
  eq(s.sim:slot(1).active, 3, "leads: a fainted monster is passed over for seat 1")
  eq(s.sim:slot(2).active, 4, "leads: ...and so is the egg, for seat 2")
  eq(f.settle(), "choose", "leads: the opening plays out")
  check(lineIndex(f.seen, "Go! ", "NIDORAN", "CHARMELEON") ~= nil,
        "leads: the player's line names the two that went out")
end)

-- Not a Gen 3 boot, and a trainer with nothing to field: no screen, and why.
block("refusals", function()
  newGame()
  SESSION.party = { mon(4, 20), mon(16, 20) }
  local sheets = Sheet3.mons(GAME, assert(CoopField.trainerParty3(FakeTrainers.foeFromId(400))), {})
  local gen1 = { generation = 1, data = DATA, session = SESSION, save = {} }
  local screen, why = CoopBattle.newSoloDouble(gen1, { npcParty = sheets, battle = "x" })
  eq(screen, nil, "refusals: a Gen 1 boot builds no solo double")
  check(type(why) == "string" and why ~= "", "refusals: ...and says why (" .. tostring(why) .. ")")
  screen, why = CoopBattle.newSoloDouble(GAME, { npcParty = {}, battle = "x" })
  eq(screen, nil, "refusals: a trainer with no monsters builds none")
  check(type(why) == "string" and why ~= "", "refusals: ...and says why (" .. tostring(why) .. ")")
  -- Built without a transport or a battle id, start() uploads nothing and says so.
  local bare = assert(CoopBattle.newSoloDouble(GAME, { npcParty = sheets }))
  eq(bare:start(GAME), false, "refusals: start() with nowhere to upload answers false")
end)

-- ------------------------------------------------------------------
-- 2. the opening: the trainer's line, its send-out, ours
-- ------------------------------------------------------------------

block("intro", function()
  local f = makeFight({
    party = { mon(4, 20), mon(16, 20), mon(29, 18) },
  })
  local s = f.screen
  eq(f.settle(), "choose", "intro: the first menu opens")
  local opening = lineIndex(f.seen, "would like to battle", "DUO")
  local foeSend = lineIndex(f.seen, "sent", "MEW", "PIDGEY")
  local goLine = lineIndex(f.seen, "Go! ", "CHARMANDER", "PIDGEY")
  check(opening ~= nil, "intro: the trainer's challenge is the first line")
  check(foeSend ~= nil, "intro: the trainer sends out both its monsters in one line")
  check(goLine ~= nil, "intro: we send ours out in one line")
  check(opening and foeSend and goLine and opening < foeSend and foeSend < goLine,
        "intro: challenge, then the trainer's send-out, then ours")
  eq(opening, 1, "intro: nothing is said before the challenge")
  local goLines = 0
  for _, line in ipairs(f.seen) do
    if line:find("^Go! ") then goLines = goLines + 1 end
  end
  eq(goLines, 1, "intro: one `Go!` line for the pair, not one per monster")
  eq(s.mine, 1, "intro: and then mon 1 is asked")
  eq(s.phase, "choose", "intro: on its command menu")
end)

-- A trainer with one monster is one send-out line of its own; our two still
-- go out together.
block("intro", function()
  local f = makeFight({
    party = { mon(4, 20), mon(16, 20) },
    foeParty = { { species = 151, level = 6, iv = 0, moves = { 33 } } },
  })
  local s = f.screen
  eq(#s.sim.slots, 3, "intro: one trainer monster is three seats on the field")
  eq(f.settle(), "choose", "intro: the first menu opens")
  local one = lineIndex(f.seen, "sent out", "MEW")
  check(one ~= nil, "intro: the one-monster send-out line (" .. tostring(f.seen[one or 0]) .. ")")
  check(one and not f.seen[one]:find("PIDGEY", 1, true), "intro: ...names only the one")
  check(lineIndex(f.seen, "Go! ", "CHARMANDER", "PIDGEY") ~= nil, "intro: ours still go out together")
  check(one and lineIndex(f.seen, "Go! ") > one, "intro: the trainer's line still comes first")
end)

-- One monster of ours that can fight: the one-monster `Go!` line, and the seat
-- left empty is not asked for.
block("intro", function()
  local f = makeFight({
    party = { mon(4, 20), mon(16, 20, { hp = 0 }) },
  })
  local s = f.screen
  eq(f.settle(), "choose", "intro: the menu opens with one monster of ours")
  local go = lineIndex(f.seen, "Go! ", "CHARMANDER")
  check(go ~= nil, "intro: the one-monster `Go!` line")
  check(go and not f.seen[go]:find("and", 1, true), "intro: ...is not a pair")
  eq(s.mine, 1, "intro: mon 1 is asked")
  eq(s.sim:slot(2).active, 0, "intro: the second seat starts empty (the referee's absent battler)")
end)

-- ------------------------------------------------------------------
-- 3. two commands a turn
-- ------------------------------------------------------------------

-- Each command goes to the referee the moment it is confirmed, under its own
-- seat; B on mon 2's command menu takes mon 1's back through the referee's
-- `cancel`, and mon 1 chooses again.
block("commands", function()
  local f = makeFight({
    party = { mon(4, 20, { moves = { 33, 57, 14 } }), mon(16, 20, { moves = { 33, 45 } }),
              mon(29, 18), mon(5, 18) },
  })
  local s = f.screen
  eq(f.settle(), "choose", "commands: the first menu opens")
  eq(s.mine, 1, "commands: mon 1 chooses first")
  eq(s.chooser, 1, "commands: chooser 1")
  eq(s.filed, nil, "commands: nothing is filed at the turn's start")

  f.press("a")
  eq(s.phase, "move", "commands: FIGHT opens mon 1's moves")
  f.press("a")
  eq(s.phase, "target", "commands: TACKLE (SELECTED) asks for a target")
  f.press("a")
  eq(#f.choices, 1, "commands: mon 1's confirm goes to the referee at once")
  eq(choiceAt(f, 1).seat, 0, "commands: under seat 0")
  eq(choiceAt(f, 1).action, "fight", "commands: a move")
  eq(choiceAt(f, 1).move, 0, "commands: TACKLE, 0-based")
  eq(choiceAt(f, 1).target, 3, "commands: at the foe the cursor opened on, field 3")
  check(heldBy(f, PLAYER1) ~= nil, "commands: the referee holds mon 1's command")
  eq(heldBy(f, PLAYER2), nil, "commands: ...and nothing yet for mon 2")
  eq(s.mine, 2, "commands: mon 2's menu is up")
  eq(s.chooser, 2, "commands: chooser 2")
  eq(s.phase, "choose", "commands: on mon 2's command menu")
  eq(filedAction(s, 1).move, 1, "commands: the screen keeps what mon 1 filed")

  f.press("b")
  eq(#f.choices, 2, "commands: B on mon 2's command menu sends one thing")
  eq(choiceAt(f, 2).action, "cancel", "commands: ...the referee's own cancel")
  eq(choiceAt(f, 2).seat, 0, "commands: ...for seat 0")
  eq(heldBy(f, PLAYER1), nil, "commands: the referee no longer holds mon 1's command")
  eq(s.mine, 1, "commands: mon 1's menu reopens")
  eq(s.chooser, 1, "commands: chooser back to 1")
  eq(s.phase, "choose", "commands: on mon 1's command menu")
  check(not (s.filed and s.filed[1]), "commands: the screen let go of mon 1's command too")
  eq(s.commandIndex, 1, "commands: the cursor is where mon 1 left it (FIGHT)")
  f.press("b")
  eq(s.mine, 1, "commands: B on mon 1's menu has nothing to take back")
  eq(s.phase, "choose", "commands: ...and stays")
  eq(#f.choices, 2, "commands: ...and sends nothing")

  -- mon 1 again, at the second foe (field slot 4)
  fightWith(f, 1, 4)
  eq(#f.choices, 3, "commands: mon 1's new command went at once")
  eq(choiceAt(f, 3).seat, 0, "commands: ...under seat 0")
  eq(choiceAt(f, 3).target, 4, "commands: ...aimed at field 4 this time")
  eq(s.mine, 2, "commands: mon 2's turn again")
  -- mon 2: FIGHT, TACKLE, aimed at its partner
  f.press("a")
  s.moveIndex = 1
  f.press("a")
  eq(s.phase, "target", "commands: mon 2 aims too")
  aimAt(f, 1)
  eq(#f.choices, 4, "commands: mon 2's confirm is one more command")
  eq(choiceAt(f, 4).seat, 1, "commands: under seat 1")
  eq(choiceAt(f, 4).target, 0, "commands: mon 2 aimed at its partner, field 0")
  eq(f.unseated, nil, "commands: every choice named its seat")
  eq(f.refused, nil, "commands: the referee refused none of them")
  eq(f.err, nil, "commands: the referee took them without a throw")
  eq(s.phase, "wait", "commands: both in, the screen waits on the referee")
  eq(f.settle(), "choose", "commands: the turn plays out and a menu opens")
  eq(choseLog(f), "c0,u0,c0,c1",
     "commands: the referee heard seat 0, its cancel, seat 0 again, then seat 1")
  eq(s.mine, 1, "commands: the next turn starts at mon 1 again")
  eq(s.chooser, 1, "commands: ...with the chooser reset")
  eq(s.filed, nil, "commands: ...and nothing filed")
  local hitAlly, hitFour = false, false
  for _, ev in ipairs(f.events) do
    if ev.t == "anim" and ev.slot == 1 and ev.target == 0 then hitAlly = true end
    if ev.t == "anim" and ev.slot == 0 and ev.target == 4 then hitFour = true end
  end
  check(hitAlly, "commands: the referee resolved mon 2's TACKLE onto its partner")
  check(hitFour, "commands: ...and mon 1's second command, not its first")
end)

-- A command the referee refuses is refused at that seat's own menu, in the
-- cart's words, and mon 2 is never asked: a POTION on a monster at full HP
-- (the review's probe -- it used to loop back to mon 1 with no line).
block("refused", function()
  local f = makeFight({
    party = { mon(4, 20), mon(16, 20), mon(29, 18) },
    bag = { { 13, 1 } },
  })
  local s = f.screen
  eq(f.settle(), "choose", "refused: menu")
  s.commandIndex = 2
  f.press("a")
  eq(s.phase, "item", "refused: the bag opens")
  f.press("a")
  eq(s.phase, "item_party", "refused: POTION asks who")
  s.switchIndex = 1
  f.press("a")
  eq(#f.choices, 1, "refused: the POTION went to the referee")
  eq(choiceAt(f, 1).seat, 0, "refused: ...for seat 0")
  eq(f.refused, 1, "refused: ...which turned it down (mon 1 is at full HP)")
  eq(heldBy(f, PLAYER1), nil, "refused: the referee holds nothing for mon 1")
  eq(s.phase, "messages", "refused: the refusal is said")
  local line = s.messages[#s.messages] or s.shown
  check(says(line, "won't have", "effect"), "refused: ...in the cart's words: " .. flat(line))
  eq(s.mine, 1, "refused: still mon 1 choosing -- mon 2 is never asked")
  eq(s.after, "item_party", "refused: ...and it goes back to the party list")
  eq(s.filed, nil, "refused: nothing is filed")
  eq(s.pendingItems, nil, "refused: nothing is waiting to be spent")
  eq(readOut(f), "item_party", "refused: the line read, mon 1's party list is back")
  eq(s.mine, 1, "refused: ...for mon 1")
  check(s.itemPick ~= nil, "refused: ...still aiming the POTION")
  f.press("b")
  eq(s.phase, "item", "refused: B to the bag")
  f.press("b")
  eq(s.phase, "choose", "refused: B to mon 1's commands")
  eq(s.mine, 1, "refused: ...still mon 1's")
  fightWith(f, 1)
  eq(#f.choices, 2, "refused: mon 1's move went")
  eq(choiceAt(f, 2).seat, 0, "refused: ...under seat 0")
  eq(s.mine, 2, "refused: only now is mon 2 asked")
  eq(FakeBag.get(SESSION.bag, 13), 1, "refused: the POTION was never spent")
end)

-- A Disabled move and a Taunted status move: refused at the move list, each in
-- its own line, the list kept, mon 2 not asked.  (The referee's own Disable
-- and Taunt fields, set where a foe's move would set them.)
block("refused", function()
  local f = makeFight({
    party = { mon(4, 20, { moves = { 33, 45 } }), mon(16, 20), mon(29, 18) },
  })
  local s = f.screen
  eq(f.settle(), "choose", "disabled: menu")
  local b = f.sim.byId[PLAYER1].b
  b.disabledNum = 33
  f.press("a")
  s.moveIndex = 1
  f.press("a")
  eq(s.phase, "target", "disabled: TACKLE is aimed first")
  f.press("a")
  eq(f.refused, 1, "disabled: the referee refused the Disabled TACKLE")
  eq(s.phase, "messages", "disabled: and the screen says so")
  local line = s.messages[#s.messages] or s.shown
  check(says(line, "TACKLE", "disabled"), "disabled: ...in the cart's words: " .. flat(line))
  eq(s.after, "move", "disabled: back to the move list")
  eq(s.mine, 1, "disabled: mon 2 is not asked")
  eq(readOut(f), "move", "disabled: the move list is back")
  eq(s.mine, 1, "disabled: ...mon 1's")
  b.disabledNum = nil
  b.tauntTurns = 2
  s.moveIndex = 2
  f.press("a")
  eq(f.refused, 2, "taunt: a status move under Taunt is refused")
  line = s.messages[#s.messages] or s.shown
  check(says(line, "GROWL", "taunt"), "taunt: ...in the cart's words: " .. flat(line))
  eq(readOut(f), "move", "taunt: the move list is back")
  b.tauntTurns = nil
  s.moveIndex = 1
  f.press("a")
  aimAt(f)
  eq(#f.choices, 3, "refused: the move that may be used goes")
  eq(s.mine, 2, "refused: and then mon 2 is asked")
end)

-- A switch out of a trap: refused at the party list in the cart's words.
block("refused", function()
  local f = makeFight({ party = { mon(4, 20), mon(16, 20), mon(29, 18) } })
  local s = f.screen
  eq(f.settle(), "choose", "trapped: menu")
  local b = f.sim.byId[PLAYER1].b
  b.ingrain = true
  s.commandIndex = 3
  f.press("a")
  eq(s.phase, "switch", "trapped: the party list opens")
  f.press("a")
  eq(f.refused, 1, "trapped: the referee refused the switch (Ingrain)")
  local line = s.messages[#s.messages] or s.shown
  check(says(line, "CHARMANDER", "switched"), "trapped: ...in the cart's words: " .. flat(line))
  eq(readOut(f), "switch", "trapped: the party list is back")
  eq(s.mine, 1, "trapped: ...mon 1's, mon 2 not asked")
  b.ingrain = nil
  f.press("a")
  eq(#f.choices, 2, "trapped: free again, the switch goes")
  eq(s.mine, 2, "trapped: and mon 2 is asked")
end)

-- B gives mon 1's switch back: the referee drops the command and the monster
-- it claimed, and mon 2's party list has that monster again.
block("cancel", function()
  local f = makeFight({ party = { mon(4, 20), mon(16, 20), mon(29, 18), mon(5, 18) } })
  local s = f.screen
  eq(f.settle(), "choose", "cancel: menu")
  s.commandIndex = 3
  f.press("a")
  f.press("a")
  eq(#f.choices, 1, "cancel: mon 1's switch went at once")
  eq(choiceAt(f, 1).slot, 2, "cancel: ...to party 3")
  local seat2 = f.sim.byId[PLAYER2]
  check(f.sim:partyTaken(seat2, 3), "cancel: the referee holds party 3 for mon 1's switch")
  local function benchIds()
    local ids = {}
    for _, row in ipairs(s:benchOf(s:mySlot())) do ids[#ids + 1] = row.index end
    return table.concat(ids, ",")
  end
  eq(s.mine, 2, "cancel: mon 2 asked")
  eq(benchIds(), "4", "cancel: mon 2's bench leaves out mon 1's pick")
  f.press("b")
  eq(choiceAt(f, 2).action, "cancel", "cancel: B sent the cancel")
  eq(heldBy(f, PLAYER1), nil, "cancel: the referee holds nothing for mon 1")
  check(not f.sim:partyTaken(seat2, 3), "cancel: ...and has let party 3 go")
  eq(s.mine, 1, "cancel: mon 1's menu is back")
  eq(s.commandIndex, 3, "cancel: ...on POKéMON, where it was left")
  fightWith(f, 1)
  eq(s.mine, 2, "cancel: mon 1 fights instead, mon 2 asked")
  eq(benchIds(), "3,4", "cancel: mon 2's bench has party 3 again")
  f.pump()
  eq(heldBy(f, PLAYER1) and heldBy(f, PLAYER1).action, "fight",
     "cancel: the late `unchose` did not undo the new command")
  check(s.filed and s.filed[1], "cancel: ...on the screen either")
end)

-- A ball is the one bag item B gives back (the cart refunds balls); taken
-- back and a POTION filed in its place before the referee's `unchose` for the
-- ball has been read, the late word does not undo the POTION's spend.
block("cancel", function()
  local f = makeFight({
    party = { mon(4, 20, { hp = 10 }), mon(16, 20), mon(29, 18) },
    bag = { { 4, 1 }, { 13, 1 } },
  })
  local s = f.screen
  eq(f.settle(), "choose", "ball back: menu")
  s.commandIndex = 2
  f.press("a")
  s.itemIndex = 1
  f.press("a")
  eq(filedAction(s, 1).kind, "item", "ball back: mon 1's POKé BALL is filed")
  eq(tonumber(filedAction(s, 1).item), 4, "ball back: ...the ball")
  eq(s.mine, 2, "ball back: mon 2 asked")
  -- B and the POTION, frame on frame, the referee's events not read between
  f.tick("b")
  eq(s.mine, 1, "ball back: B takes the ball back")
  eq(choiceAt(f, #f.choices).action, "cancel", "ball back: ...through the referee's cancel")
  s.commandIndex = 2
  f.tick("a")
  s.itemIndex = 2
  f.tick("a")
  eq(s.phase, "item_party", "ball back: POTION asks who")
  s.switchIndex = 1
  f.tick("a")
  eq(tonumber(filedAction(s, 1).item), 13, "ball back: the POTION is filed for mon 1")
  f.pump()
  check(s.pendingItems and s.pendingItems[1] and tonumber(s.pendingItems[1].id) == 13,
        "ball back: the late `unchose` left the POTION's spend pending")
  fightWith(f, 1)
  f.settle()
  eq(FakeBag.get(SESSION.bag, 13), 0, "ball back: the POTION was spent when the referee used it")
  eq(FakeBag.get(SESSION.bag, 4), 1, "ball back: the ball was never spent")
end)

-- RUN is the cart's answer to a trainer battle, for either seat: refused, with
-- nothing filed, nothing sent, and the same mon still choosing.
block("run", function()
  local f = makeFight({ party = { mon(4, 20), mon(16, 20), mon(29, 18) } })
  local s = f.screen
  eq(f.settle(), "choose", "run: menu")
  s.commandIndex = 4
  f.press("a")
  eq(s.phase, "messages", "run: RUN is answered with a line")
  check(says(s.messages[#s.messages], "trainer battle"), "run: ...there is no running from a trainer battle")
  eq(#f.choices, 0, "run: nothing was sent")
  eq(filedCount(s), 0, "run: nothing was filed")
  eq(f.settle(), "choose", "run: the menu comes back")
  eq(s.mine, 1, "run: for the same mon")
end)

-- A move with no PP left is refused in the move menu's own words, before the
-- referee is asked.
block("commands", function()
  local f = makeFight({
    party = { mon(4, 20, { moves = { 33, 45 }, pp = { 0, 40 }, maxPp = { 35, 40 } }),
              mon(16, 20) },
  })
  local s = f.screen
  eq(f.settle(), "choose", "commands: menu")
  f.press("a")
  s.moveIndex = 1
  f.press("a")
  eq(s.phase, "messages", "commands: a 0-PP move is refused with a line")
  check(contains(s.messages, "PP") or (s.shown and s.shown:find("PP", 1, true)),
        "commands: ...about PP")
  eq(s.filed, nil, "commands: ...and nothing was filed")
  eq(#f.choices, 0, "commands: ...nor sent")
end)

-- A seat the referee answered for -- mon 2's HYPER BEAM leaves it recharging
-- -- is not asked: mon 1 is the only command, and it closes the turn.
block("recharge", function()
  local f = makeFight({
    party = { mon(4, 30, { moves = { 33 } }), mon(16, 30, { moves = { 63 } }), mon(29, 18) },
    foeParty = { { species = 151, level = 30, iv = 0, moves = { 33 } },
                 { species = 16, level = 30, iv = 0, moves = { 33 } } },
  })
  local s = f.screen
  eq(f.settle(), "choose", "recharge: menu")
  bothFight(f)
  eq(#f.choices, 2, "recharge: turn 1 sends two commands")
  eq(f.settle(), "choose", "recharge: turn 2 opens")
  local chose = 0
  for _, ev in ipairs(f.events) do
    if ev.t == "chose" and ev.side == "a" and ev.slot == 1 then chose = chose + 1 end
  end
  eq(chose, 2, "recharge: the referee answered for seat 1 (turn 2) after seat 1's own choice")
  eq(s.mine, 1, "recharge: mon 1 is asked")
  fightWith(f, 1, 3)
  eq(#f.choices, 3, "recharge: one command is all that was owed -- it goes out at once")
  eq(choiceAt(f, 3).seat, 0, "recharge: under seat 0")
  eq(filedCount(s), 1, "recharge: that one command is the turn's whole")
  eq(s.phase, "wait", "recharge: the screen waits on the referee")
  eq(f.settle(), "choose", "recharge: turn 3 opens")
  eq(s.mine, 1, "recharge: mon 1 first again")
  bothFight(f)
  eq(#f.choices, 5, "recharge: the recharge is one turn -- turn 3 owes two again")
end)

-- ...and the other way about: mon 1 is the one recharging, so mon 2 is the
-- first and only one asked, and has no command of mon 1's to take back.
block("recharge", function()
  local f = makeFight({
    party = { mon(4, 30, { moves = { 63 } }), mon(16, 30, { moves = { 33 } }), mon(29, 18) },
    foeParty = { { species = 151, level = 30, iv = 0, moves = { 33 } },
                 { species = 16, level = 30, iv = 0, moves = { 33 } } },
  })
  local s = f.screen
  eq(f.settle(), "choose", "recharge: menu")
  bothFight(f)
  eq(f.settle(), "choose", "recharge: turn 2 opens")
  eq(s.mine, 2, "recharge: mon 1 is answered for, so mon 2 chooses")
  eq(s.chooser, 2, "recharge: the chooser starts at 2")
  local before = #f.choices
  f.press("b")
  eq(s.mine, 2, "recharge: B has no command of ours to take back")
  eq(s.phase, "choose", "recharge: ...and the menu stays")
  eq(#f.choices, before, "recharge: ...and no cancel is sent for the referee's own")
  fightWith(f, 1, 3)
  eq(#f.choices, before + 1, "recharge: mon 2's single command goes at once")
  eq(choiceAt(f, before + 1).seat, 1, "recharge: under seat 1")
end)

-- One standing seat, one command: the seat with nobody in it is not asked.
block("one seat", function()
  local f = makeFight({
    party = { mon(4, 20), mon(16, 20, { hp = 0 }) },
  })
  local s = f.screen
  eq(f.settle(), "choose", "one seat: menu")
  eq(s.mine, 1, "one seat: mon 1")
  fightWith(f, 1)
  eq(#f.choices, 1, "one seat: one command is the whole turn")
  eq(choiceAt(f, 1).seat, 0, "one seat: under seat 0")
  eq(s.phase, "wait", "one seat: nobody else is asked")
  eq(f.err, nil, "one seat: the referee took it")
end)

-- The bare `turn` (SoloBattle's RUN backstop) hands the window that is still
-- open back: what was filed in it stays filed at the referee, so the menu
-- reopens on the seat that still owes, and nothing goes out twice.
block("bare turn", function()
  local f = makeFight({
    party = { mon(4, 20), mon(16, 20), mon(29, 18) },
  })
  local s = f.screen
  eq(f.settle(), "choose", "bare turn: menu")
  fightWith(f, 1)
  eq(s.mine, 2, "bare turn: mon 2 asked, mon 1's command filed")
  check(heldBy(f, PLAYER1) ~= nil, "bare turn: the referee holds mon 1's")
  f.pump()
  f.feed({ t = "turn", amount = f.sim.turn })
  eq(s.phase, "messages", "bare turn: the window is handed back")
  check(s.filed and s.filed[1], "bare turn: mon 1's command is still filed")
  f.tick(nil); f.tick(nil)
  eq(s.phase, "choose", "bare turn: the command menu reopens")
  eq(s.mine, 2, "bare turn: ...for mon 2, the seat that still owes")
  eq(#f.choices, 1, "bare turn: nothing was sent again")
  fightWith(f, 1)
  eq(#f.choices, 2, "bare turn: mon 2's command closes the turn")
  eq(f.refused, nil, "bare turn: the referee took both")
  eq(f.settle(), "choose", "bare turn: the turn plays out")
  eq(s.mine, 1, "bare turn: and the next one starts at mon 1")
end)

-- ------------------------------------------------------------------
-- 4. the party list: one team, two seats
-- ------------------------------------------------------------------

block("switch", function()
  local f = makeFight({
    party = { mon(4, 20), mon(16, 20), mon(29, 18), mon(5, 18), mon(16, 12, { hp = 0 }) },
  })
  local s = f.screen
  eq(f.settle(), "choose", "switch: menu")
  local bench = s:benchOf(s:mySlot())
  eq(#bench, 2, "switch: mon 1's bench leaves out both monsters standing (and the fainted one)")
  eq(bench[1].index, 3, "switch: it starts at party 3")
  eq(bench[2].index, 4, "switch: ...then party 4")

  -- SWITCH is the cart's POKéMON, the third command
  s.commandIndex = 3
  f.press("a")
  eq(s.phase, "switch", "switch: the party list opens")
  f.press("b")
  eq(s.phase, "choose", "switch: B closes the list to the same menu")
  eq(s.mine, 1, "switch: ...of the same seat")
  s.commandIndex = 3
  f.press("a")
  f.press("a")
  eq(s.mine, 2, "switch: mon 1's switch is filed, mon 2 asked")
  eq(filedAction(s, 1).kind, "switch", "switch: ...it is a switch")
  eq(filedAction(s, 1).index, 3, "switch: ...to party 3")
  eq(#f.choices, 1, "switch: ...and it went to the referee at once")
  local bench2 = s:benchOf(s:mySlot())
  eq(#bench2, 1, "switch: mon 2's bench leaves out both actives and mon 1's pick")
  eq(bench2[1] and bench2[1].index, 4, "switch: only party 4 is left")
  local takenBy = s:siblingTaken(s:mySlot())
  eq(takenBy and takenBy[1], "battle", "switch: the partner's active is `battle` to mon 2")
  eq(takenBy and takenBy[3], "selected", "switch: mon 1's pick is `selected`")

  -- a pick naming either is refused in the cart's words, before the referee hears it
  local before = #f.choices
  s:commit({ slot = 2, kind = "switch", index = 1 })
  eq(s.phase, "messages", "switch: naming the partner's monster is refused with a line")
  local line1 = s.messages[#s.messages]
  check(says(line1, "in battle", "CHARMANDER"), "switch: ...already in battle, by name: " .. flat(line1))
  f.settle()
  s:commit({ slot = 2, kind = "switch", index = 3 })
  local line2 = s.messages[#s.messages]
  check(says(line2, "selected", "NIDORAN"), "switch: naming mon 1's pick is `already selected`: " .. flat(line2))
  f.settle()
  s:commit({ slot = 2, kind = "switch", index = 2 })
  local line3 = s.messages[#s.messages]
  check(says(line3, "in battle", "PIDGEY"), "switch: naming its own monster is `already in battle`: " .. flat(line3))
  eq(#f.choices, before, "switch: none of the refusals reached the referee")
  local back = f.settle()
  eq(s.mine, 2, "switch: still mon 2 choosing")
  eq(s.phase, "switch", "switch: a refusal leaves mon 2 on its party list (" .. back .. ")")
  eq(filedAction(s, 1).index, 3, "switch: mon 1's filed switch survived the refusals")
  eq(heldBy(f, PLAYER1) and heldBy(f, PLAYER1).slot, 3, "switch: ...at the referee too")

  s.switchIndex = 1
  f.press("a")
  eq(#f.choices, 2, "switch: both switches are filed")
  eq(choiceAt(f, 1).action, "switch", "switch: the first is a switch")
  eq(choiceAt(f, 1).slot, 2, "switch: mon 1 -> party 3 (0-based 2)")
  eq(choiceAt(f, 1).seat, 0, "switch: for seat 0")
  eq(choiceAt(f, 2).slot, 3, "switch: mon 2 -> party 4 (0-based 3)")
  eq(choiceAt(f, 2).seat, 1, "switch: for seat 1")
  eq(f.err, nil, "switch: the referee took both")
  local r = f.settle()
  check(r == "choose", "switch: next turn opens (" .. r .. ")")
  eq(s.sim:slot(1).active, 3, "switch: seat 1 now shows party 3")
  eq(s.sim:slot(2).active, 4, "switch: seat 2 now shows party 4")
  local after = s:benchOf(s:mySlot())
  eq(#after, 2, "switch: the next bench is the two that came off the field")
  local ids = {}
  for _, row in ipairs(after) do ids[#ids + 1] = row.index end
  eq(table.concat(ids, ","), "1,2", "switch: ...party 1 and 2")
end)

-- With nobody to send in, the list is not opened.
block("switch", function()
  local f = makeFight({ party = { mon(4, 20), mon(16, 20) } })
  local s = f.screen
  eq(f.settle(), "choose", "switch: menu")
  s.commandIndex = 3
  f.press("a")
  f.press("a")
  eq(s.phase, "messages", "switch: no bench says so")
  check(says(s.messages[#s.messages] or s.shown, "no one"), "switch: ...in the cart's words")
  eq(#f.choices, 0, "switch: ...and sends nothing")
end)

-- ------------------------------------------------------------------
-- 5. aiming
-- ------------------------------------------------------------------

-- A SELECTED move is aimed when more than one other battler stands, and the
-- partner is one of them; a spread or self move asks nobody.
block("aim", function()
  local f = makeFight({
    party = { mon(4, 20, { moves = { 33, 57, 14 } }), mon(16, 20, { moves = { 33, 45 } }),
              mon(29, 18) },
  })
  local s = f.screen
  eq(f.settle(), "choose", "aim: menu")
  f.press("a")
  s.moveIndex = 1
  f.press("a")
  eq(s.phase, "target", "aim: TACKLE asks for a target (three others stand)")
  local tc = s:targetChoices()
  eq(#tc, 3, "aim: both foes and the partner")
  eq(joined(tc[1] and tc[1].index, tc[2] and tc[2].index, tc[3] and tc[3].index), "3,4,2",
     "aim: the foes in order, then the partner (seat 2)")
  eq(tc[3].side, "a", "aim: the partner is on our side")
  f.press("b")
  eq(s.phase, "move", "aim: B on the aim goes back to the move menu (the cart's rule)")
  eq(s.moveIndex, 1, "aim: ...with the move still under the cursor")
  f.press("b")
  eq(s.phase, "choose", "aim: B in the move menu goes back to the commands")

  -- SURF (BOTH): nobody to ask
  f.press("a")
  s.moveIndex = 2
  f.press("a")
  eq(s.phase, "choose", "aim: SURF (BOTH) is aimed at nobody -- mon 2's menu is up")
  eq(s.mine, 2, "aim: ...mon 2's")
  check(s.filed and s.filed[1] ~= nil, "aim: ...with SURF filed for mon 1")
  eq(s:needsTarget3(s:liveMovesAt(1)[2]), false, "aim: a spread move needs no target")
  eq(s:needsTarget3(s:liveMovesAt(1)[3]), false, "aim: a self move (SWORDS DANCE) needs none")
  eq(s:needsTarget3(s:liveMovesAt(1)[1]), true, "aim: a selected one does")
  -- mon 2 aims at its partner (seat 1)
  f.press("a")
  s.moveIndex = 1
  f.press("a")
  eq(s.phase, "target", "aim: mon 2's TACKLE asks too")
  local hasPartner = false
  for _, t in ipairs(s:targetChoices()) do
    if t.index == 1 then hasPartner = true end
  end
  check(hasPartner, "aim: mon 2 may aim at mon 1 (seat 1)")
  aimAt(f, 1)
  eq(#f.choices, 2, "aim: both go out")
  eq(choiceAt(f, 1).move, 1, "aim: mon 1's SURF, 0-based")
  eq(choiceAt(f, 2).target, 0, "aim: mon 2 at field 0, its partner")
end)

-- Only one other battler standing: nothing to ask.  Two foes down to one, or a
-- trainer with one monster and a partner seat standing: ask.
block("aim", function()
  local f = makeFight({
    party = { mon(4, 20), mon(16, 20, { hp = 0 }) },
    foeParty = { { species = 151, level = 6, iv = 0, moves = { 33 } } },
  })
  local s = f.screen
  eq(f.settle(), "choose", "aim: menu")
  eq(#s:targetChoices(), 1, "aim: one foe and an empty seat -- one battler to aim at")
  eq(s:needsTarget3(s:liveMovesAt(1)[1]), false, "aim: so TACKLE is not aimed")
  fightWith(f, 1)
  eq(#f.choices, 1, "aim: the move went straight out")
  eq(choiceAt(f, 1).target, 3, "aim: at the one foe, field 3")
end)
block("aim", function()
  local f = makeFight({
    party = { mon(4, 20), mon(16, 20) },
    foeParty = { { species = 151, level = 6, iv = 0, moves = { 33 } } },
  })
  local s = f.screen
  eq(f.settle(), "choose", "aim: menu")
  eq(#s:targetChoices(), 2, "aim: one foe and the partner -- two battlers, so the cursor opens")
  f.press("a")
  s.moveIndex = 1
  f.press("a")
  eq(s.phase, "target", "aim: TACKLE is aimed")
end)

-- A Ghost's CURSE is aimed like a SELECTED move (the cart's menu offers it
-- so), and the referee lands it on the battler the filed field slot names.
block("curse", function()
  local aims = {
    { index = 3, field = 3, victim = "MEW" },
    { index = 4, field = 4, victim = "PIDGEY" },
    { index = 2, field = 1, victim = "CHARMELEON" },
  }
  for _, aim in ipairs(aims) do
    local f = makeFight({
      party = { mon(92, 20, { moves = { 174, 33 } }), mon(5, 20, { moves = { 33 } }), mon(29, 18) },
      foeParty = { { species = 151, level = 30, iv = 0, moves = { 33 } },
                   { species = 16, level = 30, iv = 0, moves = { 33 } } },
    })
    local s = f.screen
    local tag = "curse -> " .. aim.victim
    eq(f.settle(), "choose", tag .. ": menu")
    eq(s:needsTarget3(s:liveMovesAt(1)[1]), true, tag .. ": a Ghost's CURSE asks for a target")
    f.press("a")
    s.moveIndex = 1
    f.press("a")
    eq(s.phase, "target", tag .. ": the cursor opens")
    eq(#s:targetChoices(), 3, tag .. ": on all three other battlers")
    aimAt(f, aim.index)
    fightWith(f, 1, 3)
    eq(#f.choices, 2, tag .. ": both commands went")
    eq(choiceAt(f, 1).move, 0, tag .. ": CURSE, 0-based")
    eq(choiceAt(f, 1).target, aim.field, tag .. ": filed at the aimed field slot")
    f.settle()
    local anim, laid
    for _, ev in ipairs(f.events) do
      if ev.t == "anim" and ev.text == "CURSE" then anim = anim or ev end
      if ev.t == "msg" and ev.text and ev.text:find("laid a CURSE on", 1, true) then
        laid = laid or ev.text
      end
    end
    eq(anim and anim.slot, 0, tag .. ": the referee played it from seat 0")
    eq(anim and anim.target, aim.field, tag .. ": ...onto the chosen slot")
    check(laid and laid:find(aim.victim, 1, true), tag .. ": it says whom it cursed: " .. tostring(laid))
  end

  -- anyone else's CURSE is the user's own and asks nobody
  local f = makeFight({
    party = { mon(4, 20, { moves = { 174 } }), mon(16, 20), mon(29, 18) },
  })
  local s = f.screen
  eq(f.settle(), "choose", "curse: menu")
  eq(s:needsTarget3(s:liveMovesAt(1)[1]), false, "curse: a non-Ghost's CURSE is not aimed")
  f.press("a")
  s.moveIndex = 1
  f.press("a")
  eq(s.phase, "choose", "curse: ...it is held at once")
  eq(s.mine, 2, "curse: and mon 2 asked")
end)

-- The GBA page's cursor: no list, the cart's ring (player left, player right,
-- opponent right, opponent left), each step restarting the blink.
block("ring", function()
  local f = makeFight({
    classicUi = true,
    party = { mon(4, 20, { moves = { 33, 57 } }), mon(16, 20, { moves = { 33 } }), mon(29, 18) },
  })
  local s = f.screen
  eq(s:usesBattlefield(), false, "ring: the classic UI is latched")
  eq(f.settle(), "choose", "ring: menu")
  f.press("a")
  s.moveIndex = 1
  f.press("a")
  eq(s.phase, "target", "ring: aiming")
  local function blink() return s:gen3ClassicModel().double.blink end
  eq(blink().side .. blink().index, "b1", "ring: it opens on the opponent left")
  local steps = {
    { "right", "a2", "RIGHT from opponent left: the partner (player right; the chooser is skipped)" },
    { "right", "b2", "RIGHT again: opponent right" },
    { "right", "b1", "RIGHT again: wraps to opponent left" },
    { "left", "b2", "LEFT: back to opponent right" },
    { "left", "a2", "LEFT: the partner" },
    { "left", "b1", "LEFT: past the chooser to opponent left" },
    { "down", "a2", "DOWN walks the ring as RIGHT does" },
    { "up", "b1", "UP walks it as LEFT does" },
  }
  for _, step in ipairs(steps) do
    local was = blink().since
    f.press(step[1])
    local now = blink()
    eq(now.side .. now.index, step[2], "ring: " .. step[3])
    check(now.since ~= was and now.since <= s.frame, "ring: ...and the blink restarts (" .. tostring(was) .. " -> " .. tostring(now.since) .. ")")
  end
  f.press("a")
  eq(s.phase, "choose", "ring: confirming files mon 1's aim and asks mon 2")
  eq(filedAction(s, 1).target, 3, "ring: ...at opponent left, screen slot 3")

  -- mon 2's ring runs past its own seat to the partner on the left
  f.press("a")
  s.moveIndex = 1
  f.press("a")
  eq(s.phase, "target", "ring: mon 2 aims")
  eq(blink().side .. blink().index, "b1", "ring: mon 2 opens on the opponent left too")
  f.press("right")
  eq(blink().side .. blink().index, "a1", "ring: RIGHT from there is mon 1 (player left)")
  f.press("b")
  eq(s.phase, "move", "ring: B goes back to mon 2's move menu")
  eq(s:gen3ClassicModel().double.blink, nil, "ring: ...and nothing blinks there")
end)

-- The arena walks its own field cursor, and B backs out of it the same way.
block("arena aim", function()
  local f = makeFight({
    party = { mon(4, 20, { moves = { 33 } }), mon(16, 20), mon(29, 18) },
  })
  local s = f.screen
  eq(s:usesBattlefield(), true, "arena aim: the arena is the default")
  eq(f.settle(), "choose", "arena aim: menu")
  f.press("a")
  s.moveIndex = 1
  f.press("a")
  eq(s.phase, "target", "arena aim: aiming")
  eq(#s:battlefieldCtx().targets, 3, "arena aim: three targets on the field cursor")
  f.press("b")
  eq(s.phase, "move", "arena aim: B goes back to the move menu there too")
end)

-- ------------------------------------------------------------------
-- 6. replacement: a pick per seat that owes one
-- ------------------------------------------------------------------

-- Both of our monsters go down in one turn (SURF from both foes); two bench
-- monsters, so two picks, mon 1's seat first -- and the second bench leaves out
-- what the first took.
local function doubleKnockout(party)
  return makeFight({
    party = party,
    foeParty = { { species = 151, level = 40, iv = 31, moves = { 57 } },
                 { species = 151, level = 40, iv = 31, moves = { 57 } } },
  })
end

block("replace", function()
  local f = doubleKnockout({ mon(4, 5, { hp = 1 }), mon(16, 5, { hp = 1 }), mon(29, 30), mon(5, 30) })
  local s = f.screen
  eq(f.settle(), "choose", "replace: menu")
  bothFight(f)
  eq(#f.choices, 2, "replace: both commands filed")
  eq(f.settle(), "replacing", "replace: a replacement is asked")
  eq(s.replaceQueue and #s.replaceQueue, 2, "replace: both seats owe one")
  eq(joined(s.replaceQueue and s.replaceQueue[1], s.replaceQueue and s.replaceQueue[2]), "1,2", "replace: in battler order, seat 1 first")
  eq(s.mine, 1, "replace: seat 1 is asked")
  local bench1 = s:benchOf(s:mySlot())
  eq(#bench1, 2, "replace: seat 1's bench is both healthy monsters")
  f.press("b")
  check(s.replacing, "replace: B cannot cancel a replacement")
  eq(#f.choices, 2, "replace: ...and sends nothing")
  f.press("a")
  eq(#f.choices, 3, "replace: seat 1's pick went out")
  eq(choiceAt(f, 3).action, "switch", "replace: as a switch")
  eq(choiceAt(f, 3).seat, 0, "replace: for seat 0")
  eq(choiceAt(f, 3).slot, 2, "replace: the first on the bench, party 3")
  eq(s.claims and s.claims[1], 3, "replace: held as seat 1's claim")
  eq(s.mine, 2, "replace: seat 2 is asked next")
  local bench2 = s:benchOf(s:mySlot())
  eq(#bench2, 1, "replace: seat 2's bench leaves out seat 1's pick")
  eq(bench2[1].index, 4, "replace: party 4 is all that is left")
  f.press("a")
  eq(#f.choices, 4, "replace: seat 2's pick went out")
  eq(choiceAt(f, 4).seat, 1, "replace: for seat 1")
  eq(choiceAt(f, 4).slot, 3, "replace: party 4")
  eq(s.replacing, nil, "replace: no picker is left up")
  eq(s.replaceQueue, nil, "replace: ...and the queue is empty")
  eq(f.err, nil, "replace: the referee took both")
  local r = f.settle()
  check(r == "choose" or r == "finished", "replace: the next turn opens (" .. r .. ")")
  eq(s.sim:slot(1).active, 3, "replace: seat 1 is refilled with party 3")
  eq(s.sim:slot(2).active, 4, "replace: seat 2 with party 4")
  eq(s.mine, 1, "replace: the next turn starts at mon 1")
  eq(s.claims, nil, "replace: the claims are gone with the turn")
  eq(s.replacing, nil, "replace: nothing is left to replace")
end)

-- The same, taking the second monster first: the other seat is left the one
-- it did not take, whichever it was.
block("replace", function()
  local f = doubleKnockout({ mon(4, 5, { hp = 1 }), mon(16, 5, { hp = 1 }), mon(29, 30), mon(5, 30) })
  local s = f.screen
  eq(f.settle(), "choose", "replace: menu")
  bothFight(f)
  eq(f.settle(), "replacing", "replace: a replacement is asked")
  f.press("down")
  eq(s.switchIndex, 2, "replace: seat 1's cursor is on the second bench monster")
  f.press("a")
  eq(choiceAt(f, 3).slot, 3, "replace: seat 1 took party 4")
  local bench2 = s:benchOf(s:mySlot())
  eq(#bench2, 1, "replace: seat 2's bench is one")
  eq(bench2[1].index, 3, "replace: ...party 3")
  f.press("a")
  eq(choiceAt(f, 4).slot, 2, "replace: seat 2 took party 3")
  f.settle()
  eq(s.sim:slot(1).active, 4, "replace: seat 1 shows party 4")
  eq(s.sim:slot(2).active, 3, "replace: seat 2 shows party 3")
end)

-- Both down with one bench monster: one seat refills, the other stays empty,
-- and a turn is one command from then on.
block("last mon", function()
  local f = doubleKnockout({ mon(4, 5, { hp = 1 }), mon(16, 5, { hp = 1 }), mon(29, 30) })
  local s = f.screen
  eq(f.settle(), "choose", "last mon: menu")
  bothFight(f)
  eq(f.settle(), "replacing", "last mon: a replacement is asked")
  eq(s.replaceQueue and #s.replaceQueue, 1, "last mon: only one seat is asked")
  eq(s.mine, 1, "last mon: seat 1")
  eq(#s:benchOf(s:mySlot()), 1, "last mon: from a bench of one")
  f.press("a")
  eq(#f.choices, 3, "last mon: the pick went out")
  eq(choiceAt(f, 3).seat, 0, "last mon: for seat 0")
  eq(f.settle(), "choose", "last mon: the next turn opens")
  eq(s.mine, 1, "last mon: seat 1 chooses")
  eq(s.sim:slot(1).active, 3, "last mon: it was refilled with party 3")
  check(s.sim:isDown(s.sim:slot(2)), "last mon: seat 2 stays empty")
  fightWith(f, 1)
  eq(#f.choices, 4, "last mon: one command is the whole turn, filed at once")
  eq(choiceAt(f, 4).seat, 0, "last mon: under seat 0")
  eq(s.phase, "wait", "last mon: nobody else is asked")
end)

-- One of the two falls: the other stands, so the bench the picker offers
-- leaves out the survivor.
block("one down", function()
  local f = makeFight({
    party = { mon(4, 5, { hp = 1 }), mon(16, 60), mon(29, 30), mon(5, 30) },
    foeParty = { { species = 151, level = 40, iv = 31, moves = { 33 } },
                 { species = 151, level = 40, iv = 31, moves = { 33 } } },
    seed = 3,
  })
  local s = f.screen
  eq(f.settle(), "choose", "one down: menu")
  local rounds = 0
  while rounds < 6 do
    rounds = rounds + 1
    bothFight(f)
    local r = f.settle()
    if r == "replacing" or r == "finished" then break end
  end
  eq(s.replacing, true, "one down: a replacement is asked once seat 1 falls")
  eq(s.replaceQueue and #s.replaceQueue, 1, "one down: only the fallen seat owes one")
  eq(s.mine, 1, "one down: seat 1")
  local bench = s:benchOf(s:mySlot())
  local ids = {}
  for _, row in ipairs(bench) do ids[#ids + 1] = row.index end
  eq(table.concat(ids, ","), "3,4", "one down: the bench leaves out the monster still standing (party 2)")
end)

-- One falls with nobody on the bench: no replacement is asked, the seat stays
-- empty, and mon 2 is the one command a turn from then on.
block("one seat left", function()
  local f = makeFight({
    classicUi = true,
    party = { mon(4, 5, { hp = 1 }), mon(16, 60) },
    foeParty = { { species = 151, level = 40, iv = 31, moves = { 33 } },
                 { species = 151, level = 40, iv = 31, moves = { 33 } } },
    seed = 3,
  })
  local s = f.screen
  for _ = 1, 6 do
    if f.settle() ~= "choose" or s.sim:isDown(s.sim:slot(1)) then break end
    bothFight(f)
  end
  check(s.sim:isDown(s.sim:slot(1)), "one seat left: mon 1 went down with nobody to replace it")
  eq(s.replacing, nil, "one seat left: no replacement is asked")
  eq(f.settle(), "choose", "one seat left: the turn opens")
  eq(s.mine, 2, "one seat left: mon 2 is the one asked")
  eq(s.chooser, 2, "one seat left: the chooser starts there")
  local before = #f.choices
  fightWith(f, 1)
  eq(#f.choices, before + 1, "one seat left: one command is the whole turn")
  eq(choiceAt(f, before + 1).seat, 1, "one seat left: under seat 1")
  local d = s:gen3ClassicModel().double
  eq(d.allies[1], nil, "one seat left: the emptied seat is drawn empty")
  check(d.allies[2] ~= nil, "one seat left: the standing one is drawn")
end)

-- A seat emptied for good is asked again once a REVIVE gives the party a bench:
-- the cart sends the revived monster in at the turn's end (the engine's
-- refreshAbsent -> pickReplacement).  The referee's re-arm -- `mustReplace`
-- on the vacant seat, its replace phase soliciting it with a `turn` naming
-- the seat -- is staged here on the referee itself, through its own
-- `_openReplace`, since the referee that sends it lands with its own change.
-- The screen opens that seat's picker over the revived monster, files the
-- pick under the seat, draws the send-out, and asks the seat for a command
-- from then on.
block("re-armed seat", function()
  local f = makeFight({
    classicUi = true,
    party = { mon(4, 5, { hp = 1 }), mon(16, 5, { hp = 1 }), mon(29, 80) },
    foeParty = { { species = 151, level = 40, iv = 31, moves = { 57 } },
                 { species = 151, level = 40, iv = 31, moves = { 57 } } },
    bag = { { 24, 1 } },
  })
  local s = f.screen
  local pidgey = SESSION.party[2]
  eq(f.settle(), "choose", "re-armed: menu")
  bothFight(f)
  eq(f.settle(), "replacing", "re-armed: both down, one bench monster -- one seat is asked")
  eq(s.mine, 1, "re-armed: seat 1")
  f.press("a")
  eq(f.settle(), "choose", "re-armed: the next turn, seat 2 left empty")
  check(s.sim:isDown(s.sim:slot(2)), "re-armed: seat 2 is empty")
  eq(f.sim.byId[PLAYER2].b, nil, "re-armed: ...on the referee too")
  eq(s.mine, 1, "re-armed: only mon 1 chooses")

  -- mon 1: REVIVE on PIDGEY, the monster that fell on seat 2
  s.commandIndex = 2
  f.press("a")
  eq(s.phase, "item", "re-armed: the bag opens")
  f.press("a")
  eq(s.phase, "item_party", "re-armed: REVIVE asks who")
  s.switchIndex = 2
  f.press("a")
  local revived = #f.choices
  eq(choiceAt(f, revived).action, "item", "re-armed: the REVIVE went")
  eq(choiceAt(f, revived).slot, 1, "re-armed: ...on party 2")
  eq(f.refused, nil, "re-armed: the referee took it")
  -- The turn it closed, as the referee left it -- everything up to the next
  -- turn's opening, which the re-arm comes in front of.
  local evs = f.sim:drainEvents()
  local cut = #evs + 1
  for i, ev in ipairs(evs) do
    if ev.t == "turn" and ev.slot == nil then cut = i end
  end
  for i = 1, cut - 1 do f.feed(evs[i]) end
  check(f.sim.byId[PLAYER2].mons[2].hp > 0, "re-armed: the referee revived PIDGEY")
  check(pidgey.hp > 0, "re-armed: the screen wrote the revive onto the live party mon")
  eq(pidgey.hp, math.max(1, math.floor(pidgey.maxHp / 2)), "re-armed: ...at half its HP, the referee's number")
  check(s.sim:isDown(s.sim:slot(2)), "re-armed: seat 2 is still empty -- a revived monster is benched")
  eq(FakeBag.get(SESSION.bag, 24), 0, "re-armed: the REVIVE was spent")
  -- the re-arm
  local seat2 = f.sim.byId[PLAYER2]
  seat2.mustReplace = true
  f.sim:_openReplace()
  for _, ev in ipairs(f.sim:drainEvents()) do f.feed(ev) end
  eq(f.settle(), "replacing", "re-armed: the empty seat's picker opens")
  eq(s.replaceQueue and #s.replaceQueue, 1, "re-armed: one seat asked")
  eq(s.mine, 2, "re-armed: ...seat 2")
  local bench = s:benchOf(s:mySlot())
  eq(#bench, 1, "re-armed: its bench is the revived monster")
  eq(bench[1] and bench[1].index, 2, "re-armed: ...PIDGEY, party 2 -- its own last monster, not held back")
  f.press("a")
  local sent = #f.choices
  eq(choiceAt(f, sent).action, "switch", "re-armed: the pick went")
  eq(choiceAt(f, sent).seat, 1, "re-armed: ...under seat 1")
  eq(choiceAt(f, sent).slot, 1, "re-armed: ...party 2")
  eq(f.refused, nil, "re-armed: the referee took it")
  eq(f.settle(), "choose", "re-armed: the next turn opens")
  local slot2 = s.sim:slot(2)
  check(not s.sim:isDown(slot2), "re-armed: seat 2 stands again")
  check(slot2.battler and slot2.battler.mon == pidgey, "re-armed: ...with PIDGEY")
  check(lineIndex(f.seen, "Go! ", "PIDGEY") ~= nil, "re-armed: its send-out was said")
  check(s:gen3ClassicModel().double.allies[2] ~= nil, "re-armed: and it is drawn")
  eq(s.mine, 1, "re-armed: mon 1 chooses first")
  fightWith(f, 1)
  eq(s.mine, 2, "re-armed: and seat 2 is asked for a command again")
  fightWith(f, 1)
  eq(choiceAt(f, #f.choices).seat, 1, "re-armed: ...which goes under seat 1")
  eq(f.refused, nil, "re-armed: the referee took both")
end)

-- ------------------------------------------------------------------
-- 7. one bag, two seats
-- ------------------------------------------------------------------

-- Two POTION: mon 1's goes on its partner, mon 2's on mon 1 -- a medicine may
-- name any party member -- and what mon 1 holds is already out of mon 2's bag.
block("bag", function()
  local f = makeFight({
    party = { mon(4, 30, { hp = 10 }), mon(16, 30, { hp = 10 }), mon(29, 18) },
    bag = { { 13, 2 } },
  })
  local s = f.screen
  eq(f.settle(), "choose", "bag: menu")
  local items = s:usableItems()
  eq(#items, 1, "bag: mon 1 sees one kind of item")
  eq(items[1].count, 2, "bag: two POTION")
  s.commandIndex = 2
  f.press("a")
  eq(s.phase, "item", "bag: the bag opens")
  f.press("a")
  eq(s.phase, "item_party", "bag: POTION asks who")
  local rows = s:itemPartyRows()
  eq(#rows, 3, "bag: every party member is a target")
  s.switchIndex = 2
  f.press("a")
  eq(s.mine, 2, "bag: mon 1's POTION is filed and mon 2 is asked")
  eq(filedAction(s, 1).kind, "item", "bag: ...it is an item")
  local left = s:usableItems()
  eq(#left, 1, "bag: mon 2 still sees the POTION")
  eq(left[1].count, 1, "bag: ...one of them -- the other is mon 1's")
  s.commandIndex = 2
  f.press("a")
  f.press("a")
  eq(s.phase, "item_party", "bag: mon 2's POTION asks who")
  s.switchIndex = 1
  f.press("a")
  eq(#f.choices, 2, "bag: both commands filed")
  eq(choiceAt(f, 1).action, "item", "bag: mon 1's is an item")
  eq(tonumber(choiceAt(f, 1).item), 13, "bag: a POTION")
  eq(choiceAt(f, 1).seat, 0, "bag: under seat 0")
  eq(choiceAt(f, 1).slot, 1, "bag: on the partner (party 2, 0-based 1)")
  eq(choiceAt(f, 2).seat, 1, "bag: mon 2's under seat 1")
  eq(choiceAt(f, 2).slot, 0, "bag: on mon 1 (party 1)")
  eq(f.err, nil, "bag: the referee took both")
  f.settle()
  local used = {}
  for _, ev in ipairs(f.events) do
    if ev.t == "item" and ev.side == "a" then used[#used + 1] = ev.slot end
  end
  eq(table.concat(used, ","), "0,1", "bag: the referee used one from each seat")
  eq(FakeBag.get(SESSION.bag, 13), 0, "bag: both POTION were spent from the session's pocket")
end)

-- One POTION: the one mon 1 holds is gone from mon 2's list, and B cannot hand
-- a medicine back (the cart gives back balls only).
block("bag", function()
  local f = makeFight({
    party = { mon(4, 20, { hp = 10 }), mon(16, 20, { hp = 10 }), mon(29, 18) },
    bag = { { 13, 1 } },
  })
  local s = f.screen
  eq(f.settle(), "choose", "bag: menu")
  eq(#s:usableItems(), 1, "bag: mon 1 sees the one POTION")
  s.commandIndex = 2
  f.press("a")
  f.press("a")
  eq(s.phase, "item_party", "bag: POTION asks who")
  f.press("a")
  eq(s.mine, 2, "bag: mon 1's POTION is held, mon 2 asked")
  eq(#s:usableItems(), 0, "bag: mon 2's bag has no POTION left")
  s.commandIndex = 2
  f.press("a")
  f.tick(nil)
  eq(s.phase, "messages", "bag: so mon 2's BAG says there is nothing to use")
  check(says(s.messages[#s.messages] or s.shown, "nothing"), "bag: ...in the cart's words")
  f.settle()
  f.press("b")
  eq(s.mine, 2, "bag: B does not hand a medicine back (the cart's rule)")
  check(s.filed and s.filed[1], "bag: ...mon 1's POTION stays filed")
  check(heldBy(f, PLAYER1) ~= nil, "bag: ...at the referee too (no cancel was sent)")
  fightWith(f, 1)
  eq(#f.choices, 2, "bag: mon 2 fights, and both go out")
  eq(choiceAt(f, 1).action, "item", "bag: mon 1's item")
  eq(choiceAt(f, 1).slot, 0, "bag: on party 1")
  eq(choiceAt(f, 2).action, "fight", "bag: mon 2's move")
  eq(f.err, nil, "bag: the referee took it")
  f.settle()
  eq(FakeBag.get(SESSION.bag, 13), 0, "bag: the POTION was spent when the referee used it")
end)

-- An X item is the chooser's own monster's: no party picker, filed on the seat
-- it was chosen in; the referee raises that monster's stat.
block("x item", function()
  local f = makeFight({
    party = { mon(4, 30, { moves = { 33 } }), mon(16, 30, { moves = { 33 } }), mon(29, 18) },
    bag = { { 75, 2 } },
  })
  local s = f.screen
  eq(f.settle(), "choose", "x item: menu")
  s.commandIndex = 2
  f.press("a")
  eq(s.phase, "item", "x item: the bag opens")
  f.press("a")
  eq(s.mine, 2, "x item: X ATTACK is filed at once -- no party picker -- and mon 2 asked")
  eq(filedAction(s, 1).kind, "item", "x item: ...an item")
  eq(filedAction(s, 1).partySlot, 0, "x item: ...on mon 1's own party slot")
  local left = s:usableItems()
  eq(left[1] and left[1].count, 1, "x item: mon 2 sees the other X ATTACK")
  f.press("b")
  eq(s.mine, 2, "x item: B does not take an X item back either (it is not a ball)")
  check(s.filed and s.filed[1], "x item: ...it stays filed")
  s.commandIndex = 2
  f.press("a")
  f.press("a")
  eq(s.phase, "wait", "x item: mon 2's confirms at once -- no picker -- and both go to the referee")
  eq(#f.choices, 2, "x item: both are filed")
  eq(choiceAt(f, 1).seat, 0, "x item: mon 1's under seat 0")
  eq(choiceAt(f, 1).slot, 0, "x item: on party 1")
  eq(choiceAt(f, 2).seat, 1, "x item: mon 2's under seat 1")
  eq(choiceAt(f, 2).slot, 1, "x item: on party 2 -- its own, not mon 1's")
  eq(f.err, nil, "x item: the referee took both")
  f.settle()
  local rose = {}
  for _, ev in ipairs(f.events) do
    if ev.t == "stat" and ev.side == "a" then rose[#rose + 1] = ev.slot .. ":" .. tostring(ev.stat) end
  end
  eq(table.concat(rose, ","), "0:atk,1:atk", "x item: each monster's own ATTACK rose")
  eq(FakeBag.get(SESSION.bag, 75), 0, "x item: both were spent")

  -- the referee itself refuses an X item on the partner
  local g = makeFight({
    party = { mon(4, 30), mon(16, 30), mon(29, 18) },
    bag = { { 75, 1 } },
  })
  g.settle()
  local ok = g.sim:submitChoice("solo_player", { action = "item", item = 75, slot = 1 })
  check(not ok, "x item: the referee refuses an X item aimed at the partner")
end)

-- ------------------------------------------------------------------
-- 8. the ending
-- ------------------------------------------------------------------

-- Win: both of our seats earn EXP, the caller hears "win", and what the caller
-- says after the fight (src/SoloBattle.lua's after-words) is said through `say`.
block("end", function()
  local f = makeFight({
    party = { mon(4, 30, { moves = { 33 } }), mon(16, 30, { moves = { 33 } }) },
    foeParty = { { species = 151, level = 2, iv = 0, moves = { 33 } },
                 { species = 16, level = 2, iv = 0, moves = { 33 } } },
  })
  f.afterWords = { "ANN defeated\nPKMN TRAINER DUO!" }
  local s = f.screen
  local exp1, exp2 = SESSION.party[1].exp, SESSION.party[2].exp
  for _ = 1, 10 do
    local r = f.settle()
    if r ~= "choose" then break end
    -- each seat at a foe, never at its partner
    fightWith(f, 1)
    if s.phase == "choose" and s.mine == 2 then fightWith(f, 1) end
  end
  check(f.outcome ~= nil, "end: the fight ended")
  eq(f.outcome and #f.outcome.winners, 1, "end: ...with one winner, the owner (the two seats count once)")
  eq(f.outcome and f.outcome.winners[1], "solo_player", "end: ...the player")
  eq(f.outcome and f.outcome.losers[1], "solo_foe", "end: ...against the trainer")
  eq(s.result, "win", "end: the screen's result is a win")
  check(SESSION.party[1].exp > exp1, "end: mon 1 gained EXP (" .. exp1 .. " -> " .. tostring(SESSION.party[1].exp) .. ")")
  check(SESSION.party[2].exp > exp2, "end: mon 2 gained EXP (" .. exp2 .. " -> " .. tostring(SESSION.party[2].exp) .. ")")
  local one = lineIndex(f.seen, "CHARMANDER", "gained")
  local two = lineIndex(f.seen, "PIDGEY", "gained")
  check(one ~= nil, "end: 'gained' is said for mon 1")
  check(two ~= nil, "end: 'gained' is said for mon 2")
  local defeated = lineIndex(f.seen, "defeated")
  check(defeated ~= nil, "end: the caller's after-words were said through say()")
  check(defeated and one and two and defeated > one and defeated > two,
        "end: ...after the EXP lines")
  check(not contains(f.seen, "No points"), "end: no co-op unranked note on a solo fight")
  check(s.finished, "end: the screen finishes")
  eq(f.done and f.done.result, "win", "end: onDone(win) when the screen is left")
end)

-- A knocked-out foe's EXP goes to the monster that fought, wherever it stood:
-- one that was benched mid-fight is paid too, once.
block("end", function()
  local f = makeFight({
    party = { mon(4, 30, { moves = { 33 } }), mon(16, 30, { moves = { 33 } }), mon(29, 30) },
    foeParty = { { species = 151, level = 2, iv = 0, moves = { 33 } },
                 { species = 16, level = 2, iv = 0, moves = { 33 } } },
  })
  local s = f.screen
  local before = { SESSION.party[1].exp, SESSION.party[2].exp, SESSION.party[3].exp }
  for _ = 1, 10 do
    local r = f.settle()
    if r ~= "choose" then break end
    fightWith(f, 1)
    if s.phase == "choose" and s.mine == 2 then fightWith(f, 1) end
  end
  eq(f.done and f.done.result, "win", "end: the fight is won")
  check(SESSION.party[1].exp > before[1] and SESSION.party[2].exp > before[2],
        "end: both monsters that fought earned EXP")
  eq(SESSION.party[3].exp, before[3], "end: a monster that never fought earned none")
end)

-- Both seats level on the same knockout, and each leaves a move waiting: the
-- caller is handed both, in battler order, for the after-battle prompts.
block("levels", function()
  local Experience = require("src.core.game3.battle.experience")
  local savedLearnset = P3._learnsets[16]
  P3._learnsets[16] = { { 1, 33 }, { 7, 45 } }
  local a = mon(4, 6, { moves = { 10, 45, 33, 1 } })
  a.exp = Experience.expForLevel(a.growthRate, 7) - 1
  local b = mon(16, 6, { moves = { 10, 33, 1, 14 } })
  b.exp = Experience.expForLevel(b.growthRate, 7) - 1
  local f = makeFight({
    party = { a, b, mon(29, 18) },
    foeParty = { { species = 151, level = 2, iv = 0, moves = { 33 } },
                 { species = 16, level = 2, iv = 0, moves = { 33 } } },
  })
  local s = f.screen
  for _ = 1, 10 do
    if f.settle() ~= "choose" then break end
    fightWith(f, 1)
    if s.phase == "choose" and s.mine == 2 then fightWith(f, 1) end
  end
  P3._learnsets[16] = savedLearnset
  eq(f.done and f.done.result, "win", "levels: the fight is won")
  eq(a.level, 7, "levels: mon 1 grew a level")
  eq(b.level, 7, "levels: mon 2 grew a level")
  check(lineIndex(f.seen, "CHARMANDER", "grew to") ~= nil, "levels: mon 1's level-up is said")
  check(lineIndex(f.seen, "PIDGEY", "grew to") ~= nil, "levels: mon 2's level-up is said")
  local toLearn = f.done and f.done.toLearn or {}
  eq(#toLearn, 2, "levels: two moves wait for the after-battle prompts")
  check(toLearn[1] and rawequal(toLearn[1].mon, a) and toLearn[1].move == 52, "levels: EMBER for mon 1 first")
  check(toLearn[2] and rawequal(toLearn[2].mon, b) and toLearn[2].move == 45, "levels: GROWL for mon 2 second")
end)

-- A trainer with a monster on its bench refills its fallen seat itself: nothing
-- is asked of us, and the fight carries on to the win.
block("bench", function()
  local f = makeFight({
    party = { mon(4, 30, { moves = { 33 } }), mon(16, 30, { moves = { 33 } }), mon(29, 18) },
    foeParty = { { species = 151, level = 2, iv = 0, moves = { 33 } },
                 { species = 16, level = 2, iv = 0, moves = { 33 } },
                 { species = 5, level = 2, iv = 0, moves = { 33 } } },
  })
  local s = f.screen
  eq(#s.sim.slots, 4, "bench: the trainer has two seats on the field")
  for _ = 1, 12 do
    local r = f.settle()
    if r ~= "choose" then break end
    fightWith(f, 1)
    if s.phase == "choose" and s.mine == 2 then fightWith(f, 1) end
  end
  eq(f.done and f.done.result, "win", "bench: the fight is won")
  check(lineIndex(f.seen, "CHARMELEON") ~= nil, "bench: the trainer's third monster came out")
  eq(s.replacing, nil, "bench: and we were never asked to replace anything")
  check(f.outcome ~= nil and f.outcome.winners[1] == "solo_player", "bench: the player is the winner")
end)

-- PAY DAY: paid at once, said after the caller's after-words (the cart's order).
block("pay day", function()
  local f = makeFight({
    party = { mon(4, 20), mon(16, 20) },
  })
  local s = f.screen
  eq(f.settle(), "choose", "pay day: menu")
  local before = SESSION.money
  s:onOutcome({ battle = "sd1", outcome = "win", winners = { "solo_player" },
                losers = { "solo_foe" }, reason = "ko", payDay = 50 })
  eq(s.result, "win", "pay day: a win")
  eq(SESSION.money, before + 50, "pay day: the coins are paid at once")
  s:say("ANN defeated\nPKMN TRAINER DUO!")
  for _ = 1, 400 do
    f.tick(nil)
    if s.finished then break end
  end
  local defeated = lineIndex(f.seen, "defeated")
  local picked = lineIndex(f.seen, "picked up")
  check(defeated and picked and defeated < picked,
        "pay day: 'picked up' comes after the defeated line (" .. tostring(defeated) .. "," .. tostring(picked) .. ")")
  check(s.finished, "pay day: the screen then finishes")
  if not f.done then s:exit() end
  eq(f.done and f.done.result, "win", "pay day: onDone(win) on exit")
end)

-- The ending's other results.
block("result", function()
  local f = makeFight({ party = { mon(4, 20), mon(16, 20) } })
  local s = f.screen
  eq(f.settle(), "choose", "result: menu")
  s:onOutcome({ battle = "sd1", outcome = "loss", winners = { "solo_foe" },
                losers = { "solo_player" }, reason = "ko" })
  eq(s.result, "loss", "result: the trainer winning is our loss")
  local g = makeFight({ party = { mon(4, 20), mon(16, 20) } })
  eq(g.settle(), "choose", "result: menu")
  g.screen:onOutcome({ battle = "sd1", outcome = "draw", winners = {}, losers = {}, reason = "ko" })
  eq(g.screen.result, "draw", "result: nobody winning is a draw")
end)

-- Played out: both of ours go down with nothing on the bench -- a loss.
block("loss", function()
  local f = makeFight({
    party = { mon(4, 5, { hp = 1, moves = { 33 } }), mon(16, 5, { hp = 1, moves = { 33 } }) },
    foeParty = { { species = 151, level = 40, iv = 31, moves = { 57 } },
                 { species = 151, level = 40, iv = 31, moves = { 57 } } },
  })
  local s = f.screen
  for _ = 1, 10 do
    local r = f.settle()
    if r ~= "choose" then break end
    fightWith(f, 1)
    if s.phase == "choose" and s.mine == 2 then fightWith(f, 1) end
  end
  check(f.outcome ~= nil, "loss: the fight ended")
  eq(f.outcome and f.outcome.winners[1], "solo_foe", "loss: the trainer won")
  eq(s.result, "loss", "loss: the screen's result is a loss")
  if not f.done then s:exit() end
  eq(f.done and f.done.result, "loss", "loss: onDone(loss)")
end)

-- ------------------------------------------------------------------
-- 9. the C4 model: what the GBA double page is handed
-- ------------------------------------------------------------------

-- Mon 1 and mon 2 each hold one move per target byte the preview tells apart.
local function modelFight()
  return makeFight({
    classicUi = true,
    party = { mon(4, 20, { moves = { 33, 57, 14, 90 } }),
              mon(16, 20, { moves = { 91, 114, 270, 14 } }),
              mon(29, 18), mon(5, 18) },
  })
end

block("model", function()
  local f = modelFight()
  local s = f.screen
  eq(s:usesBattlefield(), false, "model: the classic UI is latched")
  eq(f.settle(), "choose", "model: menu")
  local m = s:gen3ClassicModel()
  check(type(m.double) == "table", "model: `double` is present")
  eq(m.foe, nil, "model: no centre foe in its place")
  eq(m.ally, nil, "model: ...nor a centre ally")
  eq(m.foeStrip, nil, "model: ...nor a foe strip")
  eq(m.allyStrip, nil, "model: ...nor an ally strip")
  eq(m.phase, "choose", "model: the phase is the screen's own")
  local d = m.double
  check(d.foes[1] ~= nil and d.foes[2] ~= nil, "model: two foes")
  check(d.allies[1] ~= nil and d.allies[2] ~= nil, "model: two allies")
  eq(d.foes[1].name, "MEW", "model: foes[1] is field slot 3 (the trainer's first)")
  eq(d.foes[2].name, "PIDGEY", "model: foes[2] is slot 4")
  eq(d.allies[1].name, "CHARMANDER", "model: allies[1] is field slot 0 (mon 1)")
  eq(d.allies[2].name, "PIDGEY", "model: allies[2] is slot 1 (mon 2)")
  eq(d.allies[1].level, 20, "model: a seat carries its level")
  eq(d.foes[1].level, 6, "model: ...a foe's too")
  check(d.allies[1].hp == d.allies[1].maxHp and d.allies[1].maxHp > 0, "model: ...and its HP")
  eq(d.choosing, 1, "model: mon 1's menu is up")
  eq(d.blink, nil, "model: nothing is aimed at")
  eq(d.hpText, nil, "model: the bars show, not the numbers")
  check(m.commands ~= nil, "model: the action menu's commands")
  eq(m.moves, nil, "model: no move rows in the action menu")
  eq(m.prompt, "What will\nCHARMANDER do?", "model: the prompt names mon 1")
  eq(m.playerBack ~= nil, true, "model: the player's back pic is described")

  -- START flips the HP numbers and keeps them there, through every menu
  f.press("start")
  eq(s:gen3ClassicModel().double.hpText, true, "model: START shows the HP numbers")
  f.press("a")
  s.moveIndex = 1
  local mm = s:gen3ClassicModel()
  eq(mm.double.hpText, true, "model: the toggle stays into the move menu")
  eq(mm.double.choosing, 1, "model: mon 1 still chooses in the move menu")
  eq(mm.commands, nil, "model: the move menu has no commands")
  eq(#mm.moves, 4, "model: four move rows")
  eq(mm.cursor, 1, "model: the cursor rides on the model")
  eq(mm.list, nil, "model: no list in the move menu")
  eq(mm.moves[1].num, 33, "model: a row carries its move number")
  eq(mm.moves[1].label, "TACKLE", "model: ...and its name")
  eq(mm.moves[1].target, 0, "model: TACKLE is SELECTED")
  eq(mm.moves[2].target, 8, "model: SURF is BOTH")
  eq(mm.moves[3].target, 16, "model: SWORDS DANCE is USER")
  eq(mm.moves[4].target, 32, "model: SHOCKWAVE is FOES_AND_ALLY")
  f.press("a")
  local mt = s:gen3ClassicModel()
  eq(mt.phase, "target", "model: aiming")
  eq(mt.list, nil, "model: no TARGET list on the double page")
  check(mt.moves ~= nil and #mt.moves == 4 and mt.cursor == 1, "model: the move menu stays up while aiming")
  eq(mt.moves[1].num, 33, "model: ...with its rows' numbers")
  eq(mt.moves[2].target, 8, "model: ...and their target bytes")
  eq(mt.commands, nil, "model: ...and not the commands")
  eq(mt.double.choosing, 1, "model: mon 1 is still the one choosing")
  eq(mt.double.hpText, true, "model: ...and the numbers still show")
  eq(mt.double.blink and mt.double.blink.side, "b", "model: the blink is on a foe")
  eq(mt.double.blink and mt.double.blink.index, 1, "model: ...foe 1 (opponent left)")
  check(type(mt.double.blink.since) == "number", "model: ...with the frame the cursor landed on")
  f.press("a")
  local m2 = s:gen3ClassicModel()
  eq(m2.phase, "choose", "model: then mon 2's command menu")
  eq(m2.double.choosing, 2, "model: mon 2 is the one choosing")
  eq(m2.prompt, "What will\nPIDGEY do?", "model: the prompt names mon 2")
  eq(m2.double.blink, nil, "model: nothing blinks at the commands")
  eq(m2.double.hpText, true, "model: the numbers still show for mon 2")
  f.press("a")
  s.moveIndex = 1
  local m2m = s:gen3ClassicModel()
  eq(m2m.moves[1].num, 91, "model: mon 2's moves, not mon 1's")
  eq(m2m.moves[1].target, 64, "model: FIELDWALL is OPPONENTS_FIELD")
  eq(m2m.double.choosing, 2, "model: mon 2 chooses in its move menu")
  f.press("b")
  f.press("start")
  eq(s:gen3ClassicModel().double.hpText, nil, "model: START again restores the bars")

  -- B from mon 2 back to mon 1: the choice is mon 1's again
  f.press("b")
  local back = s:gen3ClassicModel()
  eq(back.double.choosing, 1, "model: B on mon 2's commands makes mon 1 the chooser")
  eq(back.prompt, "What will\nCHARMANDER do?", "model: ...and the prompt follows")
end)

-- The fields the double model shares with every other page keep their meaning:
-- the line up, the trainer's face for its challenge, the sky, the clock.
block("model/intro", function()
  local f = modelFight()
  local s = f.screen
  f.tick(nil)
  local m = s:gen3ClassicModel()
  check(says(s.shown, "would like to battle"), "model/intro: the challenge is the line up")
  eq(m.message, s.shown, "model/intro: `message` is the line up")
  eq(m.hint, true, "model/intro: ...with the page-turn arrow")
  eq(m.trainer and m.trainer.pic, 9, "model/intro: the trainer's face is up for its challenge")
  eq(m.showTrainer, true, "model/intro: ...and it replaces the foes")
  eq(m.frame, s.frame, "model/intro: `frame` is the screen's clock")
  eq(m.mode, "coop_npc", "model/intro: `mode` is the fight's")
  eq(m.weather, nil, "model/intro: no sky yet")
  s.weatherShown = "RAIN"
  eq(s:gen3ClassicModel().weather, "RAIN", "model/intro: `weather` is the sky shown")
  s.weatherShown = nil
  eq(f.settle(), "choose", "model/intro: the opening plays out")
  m = s:gen3ClassicModel()
  eq(m.trainer, nil, "model/intro: the face is gone once the monsters are out")
  eq(m.showTrainer, nil, "model/intro: ...and so is the flag")
  eq(m.message, nil, "model/intro: no line is up at the command menu")
end)

-- A CURSE row reads the monster choosing: a Ghost's is SELECTED, anyone's is USER.
block("model", function()
  local ghost = makeFight({
    classicUi = true,
    party = { mon(92, 20, { moves = { 174 } }), mon(16, 20), mon(29, 18) },
  })
  local s = ghost.screen
  eq(ghost.settle(), "choose", "model: menu")
  ghost.press("a")
  s.moveIndex = 1
  eq(s:gen3ClassicModel().moves[1].target, 0, "model: a Ghost's CURSE row is SELECTED")
  local plain = makeFight({
    classicUi = true,
    party = { mon(4, 20, { moves = { 174 } }), mon(16, 20), mon(29, 18) },
  })
  plain.settle()
  plain.press("a")
  eq(plain.screen:gen3ClassicModel().moves[1].target, 16, "model: anyone else's is USER")
end)

-- The party list is the cart's POKéMON window over the bench; a replacement
-- has nobody choosing.
block("model", function()
  local f = makeFight({
    classicUi = true,
    party = { mon(4, 20), mon(16, 20), mon(29, 18), mon(5, 18) },
  })
  local s = f.screen
  eq(f.settle(), "choose", "model: menu")
  s.commandIndex = 3
  f.press("a")
  local m = s:gen3ClassicModel()
  eq(m.phase, "switch", "model: the party list")
  check(m.list ~= nil and m.list.rows ~= nil, "model: it is a list")
  eq(#m.list.rows, #s:benchOf(s:mySlot()), "model: with a row per bench monster")
  eq(m.commands, nil, "model: ...and no commands under it")
end)
block("model", function()
  local f = doubleKnockout({ mon(4, 5, { hp = 1 }), mon(16, 5, { hp = 1 }), mon(29, 30), mon(5, 30) })
  local s = f.screen
  s.classic3 = nil
  eq(f.settle(), "choose", "model: menu")
  bothFight(f)
  eq(f.settle(), "replacing", "model: a replacement is asked")
  local m = s:gen3ClassicModel()
  eq(m.double.choosing, nil, "model: nobody is choosing a command while a replacement is asked")
  check(m.list ~= nil, "model: the bench list is up")
end)

-- Seats: a seat with nobody in it is drawn empty.
block("model", function()
  local f = makeFight({
    classicUi = true,
    party = { mon(4, 5, { hp = 1 }), mon(16, 5, { hp = 1 }), mon(29, 30) },
    foeParty = { { species = 151, level = 40, iv = 31, moves = { 57 } },
                 { species = 151, level = 40, iv = 31, moves = { 57 } } },
  })
  local s = f.screen
  eq(f.settle(), "choose", "model: menu")
  bothFight(f)
  eq(f.settle(), "replacing", "model: a replacement")
  f.press("a")
  eq(f.settle(), "choose", "model: the next turn")
  local d = s:gen3ClassicModel().double
  check(says(d.allies[1] and d.allies[1].name, "NIDORAN"), "model: the refilled seat shows its new monster")
  eq(d.allies[2], nil, "model: the seat that stays empty is drawn empty")
  check(d.foes[1] ~= nil and d.foes[2] ~= nil, "model: the foes still stand")
  eq(d.choosing, 1, "model: only mon 1 chooses")
end)

-- A lone foe: one foe seat, the other not drawn.
block("model", function()
  local f = makeFight({
    classicUi = true,
    party = { mon(4, 20), mon(16, 20) },
    foeParty = { { species = 151, level = 6, iv = 0, moves = { 33 } } },
  })
  eq(f.settle(), "choose", "model: menu")
  local d = f.screen:gen3ClassicModel().double
  check(d.foes[1] ~= nil, "model: the one foe")
  eq(d.foes[2], nil, "model: ...and no second")
end)

-- ------------------------------------------------------------------
-- 10. ClassicBattle's pure functions, fed by that model
-- ------------------------------------------------------------------

local function inside(r) return r.x >= 0 and r.y >= 0 and r.x + r.w <= G3.W and r.y + r.h <= G3.H end
local function within(r, outer)
  return r.x >= outer.x and r.y >= outer.y and r.x + r.w <= outer.x + outer.w
    and r.y + r.h <= outer.y + outer.h
end
local function sharedRows(a, b)
  if a.x >= b.x + b.w or b.x >= a.x + a.w then return 0 end
  return math.max(0, math.min(a.y + a.h, b.y + b.h) - math.max(a.y, b.y))
end

-- Every promise the page's layout makes, on whatever `L` this model produced.
local function checkLayout(L, tag)
  local names = {}
  for key, rect in pairs(L) do
    if type(rect) == "table" and rect.x ~= nil then names[#names + 1] = key end
  end
  table.sort(names)
  for _, key in ipairs(names) do
    check(inside(L[key]), tag .. ": " .. key .. " lies on the 240x160 page")
  end
  for _, key in ipairs(L.preview and #L.preview > 0 and { "preview" } or {}) do
    for i, rect in ipairs(L[key]) do
      check(inside(rect), tag .. ": preview rect " .. i .. " lies on the page")
    end
  end
  local boxes = {}
  for _, key in ipairs({ "foeBox1", "foeBox2", "allyBox1", "allyBox2" }) do
    if L[key] then
      boxes[#boxes + 1] = key
      check(not overlaps(L[key], L.panel), tag .. ": " .. key .. " stays off the textbox")
    end
  end
  for _, foe in ipairs({ "foeBox1", "foeBox2" }) do
    for _, ally in ipairs({ "allyBox1", "allyBox2" }) do
      if L[foe] and L[ally] then
        check(not overlaps(L[foe], L[ally]), tag .. ": " .. foe .. " and " .. ally .. " are apart")
      end
    end
  end
  for _, side in ipairs({ "foe", "ally" }) do
    local one, two = L[side .. "Box1"], L[side .. "Box2"]
    if one and two then
      check(sharedRows(one, two) <= G3D.SIDE_BOX_SHARE,
            tag .. ": the two " .. side .. " boxes share at most " .. G3D.SIDE_BOX_SHARE
            .. " row (" .. sharedRows(one, two) .. ")")
    end
  end
  for i = 1, 2 do
    if L["allyHp" .. i] then
      check(L["allyBox" .. i] ~= nil and within(L["allyHp" .. i], L["allyBox" .. i]),
            tag .. ": ally " .. i .. "'s HP figures sit inside its box")
    end
  end
end

block("layout", function()
  local f = modelFight()
  local s = f.screen
  eq(f.settle(), "choose", "layout: menu")
  local function model() return s:gen3ClassicModel() end
  local function layout() return ClassicBattle.gen3DoubleLayout(model()) end

  local L = layout()
  checkLayout(L, "layout/commands")
  check(L.foePic1 and L.foePic2 and L.allyPic1 and L.allyPic2, "layout: four pics")
  check(L.foeBox1 and L.foeBox2 and L.allyBox1 and L.allyBox2, "layout: four healthboxes")
  eq(L.blink, nil, "layout: nothing blinks at the commands")
  eq(L.allyHp1, nil, "layout: the bars, not the figures")
  eq(L.preview, nil, "layout: nothing previewed at the commands")
  eq(L.list, nil, "layout: no list")

  f.press("start")
  L = layout()
  checkLayout(L, "layout/hp text")
  check(L.allyHp1 and L.allyHp2, "layout: START lays the HP figures out for both allies")
  eq(L.foeHp1 or L.foeHp2, nil, "layout: ...and never the foes'")

  -- the move menu: previews, by the move under the cursor
  f.press("a")
  for row = 1, 4 do
    s.moveIndex = row
    checkLayout(layout(), "layout/move " .. row)
  end

  -- aiming: the blink is the aimed-at battler's pic, the move menu stays up
  s.moveIndex = 1
  f.press("a")
  eq(s.phase, "target", "layout: aiming")
  L = layout()
  checkLayout(L, "layout/target")
  eq(L.preview, nil, "layout: the preview is the move menu's, not the aim's")
  check(sameRect(L.blink, L.foePic1), "layout: the blink is the opponent left's pic")
  f.press("right")
  L = layout()
  check(sameRect(L.blink, L.allyPic2), "layout: RIGHT moves it to the partner's pic")
  check(not sameRect(L.blink, L.foePic1), "layout: ...and off the foe")
  f.press("right")
  L = layout()
  check(sameRect(L.blink, L.foePic2), "layout: then to the opponent right's pic")
  checkLayout(L, "layout/target 2")
end)

-- the blink's clock: lit from the frame the cursor landed on, 8 frames each way
block("blink", function()
  local f = makeFight({
    classicUi = true,
    party = { mon(4, 20), mon(16, 20), mon(29, 18) },
  })
  local s = f.screen
  eq(f.settle(), "choose", "blink: menu")
  fightWith(f, 1)
  eq(s.mine, 2, "blink: mon 1 aimed")
  f.press("a")
  s.moveIndex = 1
  f.press("a")
  eq(s.phase, "target", "blink: mon 2 aims")
  local blink = s:gen3ClassicModel().double.blink
  local since = blink.since
  local shown = ClassicBattle.gen3BlinkShown
  eq(shown(blink, since), true, "blink: lit on the frame the cursor landed")
  eq(shown(blink, since + 7), true, "blink: ...still lit on the 8th frame")
  eq(shown(blink, since + 8), false, "blink: hidden for the next 8")
  eq(shown(blink, since + 15), false, "blink: ...to the 16th")
  eq(shown(blink, since + 16), true, "blink: lit again")
  eq(shown(blink, since + 24), false, "blink: and hidden again")
  eq(shown(blink, since - 3), true, "blink: before it landed there is nothing to hide")
  eq(shown(nil, 100), true, "blink: nothing aimed at is never hidden")
  eq(shown({ side = "b" }, 100), true, "blink: a blink naming nobody is never hidden")
  -- moving the cursor restarts it lit
  for _ = 1, 20 do f.tick(nil) end
  f.press("right")
  local moved = s:gen3ClassicModel().double.blink
  check(moved.since > since, "blink: a cursor move restarts the clock later")
  eq(shown(moved, s.frame), true, "blink: ...lit on the frame it landed")
end)

-- the move menu's preview, by the target byte of the row under the cursor
block("preview", function()
  local f = modelFight()
  local s = f.screen
  eq(f.settle(), "choose", "preview: menu")
  local preview = ClassicBattle.gen3PreviewTargets
  local function mask(row)
    s.moveIndex = row
    return preview(s:gen3ClassicModel())
  end
  eq(preview(s:gen3ClassicModel()), nil, "preview: nothing at the action menu")
  f.press("a")

  local m, y = mask(1)
  check(m and m.a1 and m.b1 and m.a2 and m.b2 and y == 0,
        "preview: SELECTED is all four from 0 -- nothing lit until it is aimed")
  m, y = mask(2)
  check(m and m.b1 and m.b2 and not m.a1 and not m.a2, "preview: BOTH hits the two foes")
  eq(y, G3D.PREVIEW_Y, "preview: ...fading from the cart's start")
  m, y = mask(3)
  check(m and m.a1 and not m.a2 and not m.b1 and not m.b2, "preview: USER (mon 1's) is mon 1 alone")
  eq(y, G3D.PREVIEW_Y, "preview: ...fading from the cart's start")
  m = mask(4)
  check(m and m.b1 and m.b2 and m.a2 and not m.a1,
        "preview: FOES_AND_ALLY is both foes and the partner, not the chooser")

  local function layoutAt(row)
    s.moveIndex = row
    return ClassicBattle.gen3DoubleLayout(s:gen3ClassicModel())
  end
  local L = layoutAt(2)
  eq(L.preview and #L.preview, 2, "preview: the layout washes two pics for SURF")
  check(L.preview and sameRect(L.preview[1], L.foePic1) and sameRect(L.preview[2], L.foePic2),
        "preview: ...the two foes' (in the cart's battler order)")
  eq(layoutAt(1).preview, nil, "preview: an unaimed SELECTED move washes nothing")

  -- aiming ends the preview; then mon 2 chooses, and the rows are read for it
  s.moveIndex = 1
  f.press("a")
  eq(s.phase, "target", "preview: TACKLE is aimed")
  eq(preview(s:gen3ClassicModel()), nil, "preview: none while aiming")
  f.press("a")
  eq(s.mine, 2, "preview: mon 2's menu")
  s.commandIndex = 1
  f.press("a")
  eq(s.phase, "move", "preview: mon 2's moves")
  m, y = mask(1)
  check(m and m.b1 and m.b2 and not m.a1 and not m.a2, "preview: OPPONENTS_FIELD hits the foes' side")
  eq(y, G3D.PREVIEW_Y, "preview: ...from the cart's start")
  m = mask(2)
  check(m and m.a1 and m.a2 and m.b1 and m.b2, "preview: HAZE (a USER move by number) touches the whole field")
  m = mask(3)
  check(m and m.a1 and not m.a2 and not m.b1 and not m.b2,
        "preview: HELPING HAND is the partner -- mon 1 -- alone")
  m = mask(4)
  check(m and m.a2 and not m.a1 and not m.b1 and not m.b2, "preview: USER, for mon 2, is mon 2 alone")
end)

-- the preview fade's clock (pure)
block("wash", function()
  local wash = ClassicBattle.gen3PreviewWash
  local at, length = wash(G3D.PREVIEW_Y, 0)
  eq(at, G3D.PREVIEW_Y, "wash: a fade begins at its start")
  eq(length, 46, "wash: ...and lasts 46 frames from 8")
  eq((wash(G3D.PREVIEW_Y, G3D.PREVIEW_DELAY + 2)), G3D.PREVIEW_Y - G3D.PREVIEW_DELTA,
     "wash: ...a step lighter every delay plus two frames")
  eq((wash(G3D.PREVIEW_Y, 41)), 0, "wash: ...and fully clear once the steps are done")
  local _, none = wash(0, 0)
  eq(none, 6, "wash: a fade from 0 (nothing lit) is the six finishing frames")
end)

-- ------------------------------------------------------------------
-- 11. the arena: one human with two ally seats, one trainer behind two foes
-- ------------------------------------------------------------------

-- The rects an arena layout places, as { name, x0, y0, x1, y1 }: a mon is
-- centred on x, y at its draw size; a Gen 3 trainer stands with its feet on
-- the row y, its figure reaching up from there (HUMAN_REACH3 for a walker, the
-- whole 64px frame for a trainer pic -- the convention tests/gen3_battlefield.lua
-- holds the field to); plates and roster chips are corner-anchored.
local function arenaRects(layout)
  local out = { figures = {}, plates = {}, rosters = {} }
  local function centred(kind, e)
    local w, h = e.drawW or 0, e.drawH or 0
    return { name = kind .. ":" .. tostring(e.side) .. tostring(e.index or ""),
             x0 = e.x - w / 2, y0 = e.y - h / 2, x1 = e.x + w / 2, y1 = e.y + h / 2 }
  end
  local function standing(kind, e)
    local reach = (e.side == "foe") and (e.drawH or 0) or Battlefield.HUMAN_REACH3
    return { name = kind .. ":" .. tostring(e.side) .. tostring(e.index or ""),
             x0 = e.x - (e.drawW or 0) / 2, y0 = e.y - reach,
             x1 = e.x + (e.drawW or 0) / 2, y1 = e.y }
  end
  local function cornered(kind, e)
    return { name = kind .. ":" .. tostring(e.side) .. tostring(e.humanIndex or ""),
             x0 = e.x, y0 = e.y, x1 = e.x + e.w, y1 = e.y + e.h }
  end
  for _, e in ipairs(layout.humans or {}) do out.figures[#out.figures + 1] = standing("human", e) end
  for _, e in ipairs(layout.mons or {}) do out.figures[#out.figures + 1] = centred("mon", e) end
  for _, e in ipairs(layout.plates or {}) do out.plates[#out.plates + 1] = cornered("plate", e) end
  for _, e in ipairs(layout.rosters or {}) do out.rosters[#out.rosters + 1] = cornered("roster", e) end
  return out
end

local function rectsApart(a, b) return a.x0 >= b.x1 or b.x0 >= a.x1 or a.y0 >= b.y1 or b.y0 >= a.y1 end

local function checkArena(layout, tag)
  local r = arenaRects(layout)
  local all = {}
  for _, group in ipairs({ r.figures, r.plates, r.rosters }) do
    for _, rect in ipairs(group) do all[#all + 1] = rect end
  end
  for _, rect in ipairs(all) do
    check(rect.x0 >= 0 and rect.x1 <= Battlefield.WIDTH, tag .. ": " .. rect.name .. " is on screen horizontally")
    check(rect.y0 >= 0 and rect.y1 <= Battlefield.HEIGHT, tag .. ": " .. rect.name .. " is on screen vertically")
  end
  for _, rect in ipairs(r.figures) do
    check(rect.y1 <= Battlefield.FIELD_BOTTOM and rect.y0 >= Battlefield.FIELD_TOP,
          tag .. ": " .. rect.name .. " stands on the field, off the menu band")
  end
  for i = 1, #all do
    for j = i + 1, #all do
      check(rectsApart(all[i], all[j]), tag .. ": " .. all[i].name .. " and " .. all[j].name .. " do not overlap")
    end
  end
  return r
end

block("arena", function()
  local f = makeFight({ party = { mon(4, 20), mon(16, 20), mon(29, 18) } })
  local s = f.screen
  eq(s:usesBattlefield(), true, "arena: the arena is the default UI")
  eq(f.settle(), "choose", "arena: menu")
  local allies = s:battlefieldAllyHumans()
  eq(#allies, 1, "arena: one ally figure for the two seats")
  eq(allies[1] and allies[1].id, "solo_player", "arena: ...the player")
  eq(#s:battlefieldFoeHumans(), 1, "arena: one trainer behind the two foes")
  eq(#s:battlefieldSeats(false), 2, "arena: two ally seats drawn")
  eq(#s:battlefieldSeats(true), 2, "arena: two foe seats drawn")
  local layout = Battlefield.layout(s:battlefieldCtx())
  eq(#layout.humans, 2, "arena: two figures placed (the player and the trainer)")
  eq(#layout.mons, 4, "arena: four monsters placed")
  eq(#layout.plates, 4, "arena: four plates")
  local r = checkArena(layout, "arena")
  -- the trainer stands behind its two foes, the player behind its two
  local ally, foe, allyMons, foeMons = nil, nil, {}, {}
  for _, e in ipairs(layout.humans) do
    if e.side == "ally" then ally = e else foe = e end
  end
  for _, e in ipairs(layout.mons) do
    if e.side == "ally" then allyMons[#allyMons + 1] = e else foeMons[#foeMons + 1] = e end
  end
  check(ally and ally.x < math.min(allyMons[1].x, allyMons[2].x), "arena: the player stands behind (left of) both ally seats")
  check(foe and foe.x > math.max(foeMons[1].x, foeMons[2].x), "arena: the trainer stands behind (right of) both foes")
  check(ally and ally.y > math.min(allyMons[1].y, allyMons[2].y)
        and ally.y < math.max(allyMons[1].y, allyMons[2].y), "arena: the player stands between its two seats")

  -- aiming: three targets, an arrow on the aimed battler, the card on screen
  f.press("a")
  s.moveIndex = 1
  f.press("a")
  eq(s.phase, "target", "arena: aiming")
  local ctx = s:battlefieldCtx()
  eq(#ctx.targets, 3, "arena: the cursor has three targets")
  local aiming = Battlefield.layout(ctx)
  check(aiming.arrow ~= nil, "arena: an arrow marks the battler aimed at")
  check(aiming.arrow and aiming.arrow.x >= 0 and aiming.arrow.x <= Battlefield.WIDTH
        and aiming.arrow.y >= 0 and aiming.arrow.y <= Battlefield.HEIGHT, "arena: ...on screen")
  check(aiming.card ~= nil, "arena: the card names the pick among three")
  if aiming.card then
    check(aiming.card.x >= 0 and aiming.card.x + aiming.card.w <= Battlefield.WIDTH
          and aiming.card.y >= 0 and aiming.card.y + aiming.card.h <= Battlefield.HEIGHT,
          "arena: ...and sits on screen")
  end
  checkArena(aiming, "arena/aiming")
end)

-- A trainer with one monster, and one of ours left: fewer figures, still apart.
block("arena", function()
  local f = makeFight({
    party = { mon(4, 20), mon(16, 20, { hp = 0 }) },
    foeParty = { { species = 151, level = 6, iv = 0, moves = { 33 } } },
  })
  local s = f.screen
  eq(f.settle(), "choose", "arena: menu")
  eq(#s:battlefieldSeats(false), 1, "arena: one ally seat drawn")
  eq(#s:battlefieldSeats(true), 1, "arena: one foe seat drawn")
  local layout = Battlefield.layout(s:battlefieldCtx())
  eq(#layout.mons, 2, "arena: two monsters placed")
  checkArena(layout, "arena/lone")
end)

-- ------------------------------------------------------------------
-- 12. the co-op regression guard: `ownSlots == nil` is every co-op fight
-- ------------------------------------------------------------------

block("co-op", function()
  local f = makeCoop({
    classicUi = true,
    party = { mon(4, 12, { moves = { 33, 57, 14 } }), mon(29, 12), mon(5, 12) },
    partnerParty = { mon(16, 12) },
  })
  local s = f.screen
  eq(s.ownSlots, nil, "co-op: no `ownSlots`")
  eq(s.soloDouble, nil, "co-op: not a solo double")
  eq(s.chooser, nil, "co-op: no chooser")
  eq(s.mediated, true, "co-op: the referee's fight")
  eq(s.mine, 1, "co-op: one `mine`")
  eq(s:isMine(1), true, "co-op: `isMine` is `index == mine`")
  eq(s:isMine(2), false, "co-op: ...so the partner's seat is not ours")
  eq(s:isMine(3), false, "co-op: ...nor a foe's")
  eq(f.settle(), "choose", "co-op: the first menu opens")
  eq(s.soloIntro3, nil, "co-op: the opening is not composed as a solo double's")
  eq(s.mine, 1, "co-op: still `mine` = 1 at the menu")

  -- the strip classic model, not the double page
  local m = s:gen3ClassicModel()
  eq(m.double, nil, "co-op: the classic model has no `double`")
  check(m.foe ~= nil and m.ally ~= nil, "co-op: it has the focused pair")
  check(m.foeStrip ~= nil and m.allyStrip ~= nil, "co-op: ...and the strips")
  eq(m.foe.name, "MEW", "co-op: the focused foe")
  eq(m.ally.name, "CHARMANDER", "co-op: the focused ally is ours")
  check(m.commands ~= nil, "co-op: the commands")

  -- START and B at the menu do nothing special
  f.press("start")
  eq(s.hpText3, nil, "co-op: START toggles no HP numbers")
  f.press("b")
  eq(s.mine, 1, "co-op: B at the menu takes nothing back")
  eq(s.phase, "choose", "co-op: ...and stays")

  -- one command and it goes at once, with no seat named
  eq(#s:benchOf(s:mySlot()), 2, "co-op: the bench leaves out only the seat's own monster")
  f.press("a")
  s.moveIndex = 1
  f.press("a")
  eq(s.phase, "target", "co-op: TACKLE asks for a target")
  eq(#s:targetChoices(), 3, "co-op: both foes and the partner")
  f.press("b")
  eq(s.phase, "choose", "co-op: B on the aim goes back to the commands (co-op always has)")
  f.press("a")
  s.moveIndex = 1
  f.press("a")
  f.press("a")
  eq(#f.choices, 1, "co-op: one command is the whole turn, sent at once")
  eq(choiceAt(f, 1).seat, nil, "co-op: it names no seat")
  eq(choiceAt(f, 1).action, "fight", "co-op: a move")
  eq(choiceAt(f, 1).target, 3, "co-op: at the foe aimed at")
  eq(s.filed, nil, "co-op: nothing is ever kept as filed")
  eq(s.claims, nil, "co-op: nothing is claimed")
  eq(f.err, nil, "co-op: the referee took it")
  eq(f.settle(), "choose", "co-op: the turn plays out")
  eq(s.mine, 1, "co-op: `mine` is 1 the next turn too")
  eq(#f.choices, 1, "co-op: and nothing else was sent for it")
  check(s.sim:slot(1).battler.mon == SESSION.party[1], "co-op: our seat wears the live party's lead")
end)

-- The arena skin of the same fight is the co-op layout, not the solo double's.
block("co-op arena", function()
  local f = makeCoop({
    party = { mon(4, 12), mon(29, 12) },
    partnerParty = { mon(16, 12) },
  })
  local s = f.screen
  eq(f.settle(), "choose", "co-op arena: menu")
  eq(#s:battlefieldAllyHumans(), 2, "co-op arena: two ally figures (us and the partner), not one")
  eq(#s:battlefieldSeats(false), 2, "co-op arena: two ally seats")
end)

-- ------------------------------------------------------------------
-- 13. through SoloBattle: the glue the caller owns (seat -> referee id, the
--     refusal's line, the backstop, a trainer seat asked again)
-- ------------------------------------------------------------------

local SOLO_UI = {
  pushState = function(_, game, state) return Gen3Ui.pushState(game, state) end,
  say = function(_, _, cb) if cb then cb() end; return {} end,
  confirm = function(_, _, _, cb) if cb then cb(true) end; return {} end,
  askNickname = function() return true end,
}

-- A lone double taken through src/SoloBattle.lua itself, against trainer 400
-- (FOE_DEFAULT): the real door, the real transport, the real referee.
local function startSolo(party, bag)
  OPTIONS.solo = true
  newGame()
  SESSION.party = party
  for _, entry in ipairs(bag or {}) do FakeBag.add(SESSION.bag, entry[1], entry[2]) end
  TRAINERS[400].party = FOE_DEFAULT
  TRAINERS[400].items = { 0, 0, 0, 0 }
  local solo = Solo.new(SOLO_UI, {
    enabled = function() return OPTIONS.solo == true end,
    seed = function() return 7 end,
  })
  local run = { solo = solo }
  run.took = solo:fromGen3Trainer(GAME, 400, { trainerId = 400,
    done = function(r) run.result = r end })
  return run
end

-- One frame the way the game runs one: the pump, then the screen, A on any open
-- menu or picker (aiming at a foe, never the partner).
local function soloFrame(solo, press)
  solo:update(1 / 60, GAME)
  local fight = solo.fight
  if not fight then return false end
  local key
  local menu = fight.phase == "choose" or fight.phase == "move" or fight.phase == "target"
  if press and (menu or fight.replacing) and not fight:boxLive() then
    key = "a"
    if fight.phase == "target" then
      local pick = fight:targetChoices()[fight.targetIndex or 1]
      if pick and not fight:foeSide(pick.index) then key = "down" end
    end
  end
  GAME.input = fakeInput(key)
  fight:update(key and (1 / 60) or 1.0)
  GAME.input = fakeInput()
  return true
end

local function playSolo(solo, limit)
  local frames = 0
  for _ = 1, limit or 4000 do
    if not solo.fight then break end
    frames = frames + 1
    if not soloFrame(solo, true) then break end
  end
  return frames
end

-- Down to mon 1's command menu, nothing pressed.
local function untilMenu(solo)
  for _ = 1, 400 do
    local fight = solo.fight
    if fight and fight.phase == "choose" and not fight:boxLive() then
      soloFrame(solo, false)
      if fight.phase == "choose" then return true end
    end
    if not soloFrame(solo, false) then return false end
  end
  return false
end

block("solo", function()
  local a = mon(4, 20, { moves = { 10 } })
  local b = mon(16, 20, { moves = { 10 } })
  local expA, expB = a.exp, b.exp
  local run = startSolo({ a, b, mon(29, 18) })
  local solo = run.solo
  check(run.took, "solo: a lone double is taken (" .. table.concat(warns, " / ") .. ")")
  local fight = solo.fight
  check(fight and fight.soloDouble == true, "solo: it is fought on the solo double screen")
  eq(fight and fight.ownSlots and #fight.ownSlots, 2, "solo: with both seats ours")
  local frames = playSolo(solo)
  check(solo.fight == nil, "solo: the fight ended and let go (" .. frames .. " frames)")
  eq(run.result, "win", "solo: the script's done() hears win")
  check(a.exp > expA and b.exp > expB, "solo: both leads earned EXP")
  check(not contains(warns, "double battle screen"), "solo: the backstop never stepped in")
end)

-- SoloBattle's own transport names the refusal (Solo.refusalText3), and the
-- screen says it at mon 1's menu: a POTION on a monster at full HP.
block("solo refusal", function()
  local run = startSolo({ mon(4, 20, { moves = { 10 } }), mon(16, 20, { moves = { 10 } }), mon(29, 18) },
                        { { 13, 1 } })
  local solo = run.solo
  check(run.took and untilMenu(solo), "solo refusal: mon 1's menu")
  local fight = solo.fight
  eq(fight.mine, 1, "solo refusal: mon 1 chooses")
  fight.itemPick = fight:usableItems()[1]
  eq(fight.itemPick and fight.itemPick.id, 13, "solo refusal: the POTION")
  check(not fight:commitMediatedItem(1, nil), "solo refusal: the POTION on mon 1 is refused")
  local line = fight.transport.refusal
  check(says(line, "won't have", "effect"), "solo refusal: the transport named the cart's line: " .. flat(line))
  eq(fight.phase, "messages", "solo refusal: the screen says it")
  check(says(fight.messages[#fight.messages], "won't have"), "solo refusal: ...that line")
  eq(fight.after, "item_party", "solo refusal: ...back to the party list")
  eq(fight.mine, 1, "solo refusal: mon 2 is not asked")
  eq(solo.sim.byId[PLAYER1].choice, nil, "solo refusal: the referee holds nothing for mon 1")
  for _ = 1, 40 do
    if fight.phase == "item_party" then break end
    soloFrame(solo, false)
  end
  eq(fight.phase, "item_party", "solo refusal: the line read, the party list is back")
  for _ = 1, 2 do
    GAME.input = fakeInput("b")
    fight:update(1 / 60)
    GAME.input = fakeInput()
  end
  eq(fight.phase, "choose", "solo refusal: B, B: mon 1's commands")
  playSolo(solo)
  eq(run.result, "win", "solo refusal: the fight goes on to the win")
  eq(FakeBag.get(SESSION.bag, 13), 1, "solo refusal: the POTION was never spent")
end)

-- The backstop (SoloBattle M:_backstop3): the screen made to believe it has
-- nothing to ask while the referee waits on mon 1.  Under three seconds it
-- waits; then the screen puts mon 1's menu back; the same seat in the same
-- window again and the referee picks for it; mon 2, still owed, gets its menu
-- put back too -- and the fight plays on to the end.
block("solo backstop", function()
  local run = startSolo({ mon(4, 20, { moves = { 10 } }), mon(16, 20, { moves = { 10 } }), mon(29, 18) })
  local solo = run.solo
  check(run.took and untilMenu(solo), "backstop: mon 1's menu")
  local fight = solo.fight
  local mark = #warns
  check(not fight:waitingOnReferee(), "backstop: a menu up is not waiting on the referee")
  fight.phase = "wait"
  check(fight:waitingOnReferee(), "backstop: the screen now says it waits on the referee")
  for _ = 1, 170 do solo:update(1 / 60, GAME) end
  eq(fight.phase, "wait", "backstop: under three seconds nothing is done")
  eq(#warns, mark, "backstop: ...and nothing is said")
  for _ = 1, 20 do solo:update(1 / 60, GAME) end
  eq(fight.phase, "choose", "backstop: then mon 1's menu is put back up")
  eq(fight.mine, 1, "backstop: ...mon 1's")
  check(contains(warns, "asked again"), "backstop: ...and it is reported")
  eq(solo.sim.byId[PLAYER1].choice, nil, "backstop: the referee was not answered for it")
  fight.phase = "wait"
  for _ = 1, 190 do solo:update(1 / 60, GAME) end
  check(solo.sim.byId[PLAYER1].choice ~= nil, "backstop: the same seat again -- the referee picked for mon 1")
  check(contains(warns, "referee chose"), "backstop: ...and that is reported, with what to do")
  for _ = 1, 190 do solo:update(1 / 60, GAME) end
  eq(fight.phase, "choose", "backstop: mon 2, still owed, gets its menu put back")
  eq(fight.mine, 2, "backstop: ...mon 2's")
  playSolo(solo)
  eq(run.result, "win", "backstop: the fight played on to its end")
  for i = #warns, mark + 1, -1 do table.remove(warns, i) end
end)

-- A trainer seat left empty that the referee asks for again is answered like
-- any other owing seat (M:_answerFoes3): the re-arm staged on the referee as
-- in "re-armed seat", the trainer's second seat vacated the way
-- Battle:_faintBattler leaves one (no battler, no active, the last kept) with
-- its monster standing again.
block("solo re-armed foe", function()
  local run = startSolo({ mon(4, 20, { moves = { 10 } }), mon(16, 20, { moves = { 10 } }), mon(29, 18) })
  local solo = run.solo
  check(run.took and untilMenu(solo), "re-armed foe: mon 1's menu")
  local sim = solo.sim
  local foe2 = sim.byId["solo_foe#2"]
  foe2.lastB, foe2.b, foe2.active = foe2.b, nil, nil
  foe2.mustReplace = true
  sim:_openReplace()
  eq(sim.phase, "replace", "re-armed foe: the referee asks the vacant trainer seat")
  check(solo:_answerFoes3(), "re-armed foe: the trainer's emptied seat is answered")
  check(foe2.b ~= nil, "re-armed foe: a monster is out on it again")
  eq(foe2.active, 2, "re-armed foe: ...its second, the one standing again")
  eq(sim.phase, "choice", "re-armed foe: and the referee moved on to the turn")
  playSolo(solo)
  eq(run.result, "win", "re-armed foe: the fight played on to its end")
end)

-- ------------------------------------------------------------------
-- the whole run
-- ------------------------------------------------------------------

eq(#warns, 0, "no mod warning was logged by any fight (" .. table.concat(warns, " / ") .. ")")
eq(#gen1Asked, 0, "and nothing of Gen 1's battle engine was asked for")

-- Hand the engine's modules back, as the other suites do.
for name, original in pairs(saved) do package.loaded[name] = original or nil end
for _, name in ipairs({ "src.battle.BattleState", "src.battle.Damage", "src.battle.TurnOrder",
                        "src.battle.Experience", "src.core.Sound", "src.core.Music" }) do
  package.preload[name] = nil
end

T.finish("gen3_solo_double")
