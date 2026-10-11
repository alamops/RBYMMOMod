-- Headless Gen 3 solo battles, the Legend family (wave 2 K-LEG of
-- docs/plans/gen3-solo-remaining-fights.md): src/Solo3/Legend.lua's four
-- kinds -- roamer, legendary, scripted, ghost -- through the real solo core
-- (src/SoloBattle.lua), the real referee (src/BattleSim3) and the real screen
-- (MediatedBattle), over stand-ins src/CoopField.lua's own door builds.
--
--   1. The family module through the registry: KIND_FILES3 finds it by
--      mod:read, all four kinds register, nothing else does.
--   2. Roamers: the monster the save holds (HP, status and its sleep
--      counter, IVs, personality) seated with AI_Roaming; FireRed's
--      MUS_VS_LEGEND; the dex.  Every ending through the referee, and the
--      engine's own Roamer.onBattleEnd (the real module) called once after
--      it -- HP / status banked, the roamer moved, and an odd outcome putting
--      it away as the cart does (FireRed's ROAR bug included, which the
--      engine port "fixed").  The hand-back, with and without the door's own.
--   3. Legendaries: the cart's wild move, no held item, FireRed's theme per
--      species and no dex "seen" there, Emerald's own theme and its "seen",
--      the fateful bit; the endings that lose a legend when they are wrong
--      (Emerald's Mew TELEPORT, FireRed's WHIRLWIND on Mewtwo, caught, ran,
--      knocked out).
--   4. Scripted wilds: the ordinary wild fight, taken.
--   5. The POKeMON TOWER ghosts, veiled and unveiled: the referee's and the
--      screen's `ghost`, the dex, and the Marowak's VAR_RESULT.
--   6. The pure helpers: the status byte, the dex rule, the song table.
--
-- Legal: every species, move and item row below is the SDK fixture's or
-- invented here with synthetic numbers; the only real values are pret enum
-- numbers the battle code branches on (EFFECT_*, ITEM_*, MOVE_* / SPECIES_*
-- ids, STATUS1_* bits) and pret's own MUS_* / SPECIES_* names.
--
-- Run from the engine checkout root:
--
--   luajit mods/rby_mmo/tests/gen3_solo_legend.lua

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

-- Two invented moves: a strong one for the trainer that wins, a status one.
ROM[45] = { effect = 18, power = 0, type = 0, accuracy = 100, pp = 40,
            secondaryChance = 0, target = 8, priority = 0, flags = 18 }
P3._moveNames[45] = "GROWL"
ROM[300] = { effect = 0, power = 250, type = 14, accuracy = 100, pp = 10,
             secondaryChance = 0, target = 0, priority = 0, flags = 2 }
P3._moveNames[300] = "MINDBLAST"
-- PAY DAY: pret EFFECT_PAY_DAY (34) on an invented row; its coins are the
-- move's secondary effect, so the row carries a certain one.
ROM[6] = { effect = 34, power = 40, type = 0, accuracy = 100, pp = 20,
           secondaryChance = 100, target = 0, priority = 0, flags = 2 }
P3._moveNames[6] = "PAYDAY"
ITEMS[1] = { name = "MASTER BALL", pocket = "POKE_BALLS", price = 0 }
ITEMS[21] = { name = "HYPER POTION", pocket = "ITEMS", price = 1200 }
ITEMS[127] = { name = "AMULET COIN", pocket = "ITEMS", price = 100, holdEffect = 32 }
P3._abilityNames[23] = "SHADOW TAG"
P3._learnsets[16] = { { 1, 33 }, { 1, 45 } }

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
function FakePokemon.gender() return "M" end
function FakePokemon.frontPic(sp) return { image = fakeImage("front" .. tostring(sp)), w = 64, h = 64 } end
function FakePokemon.backPic(sp) return { image = fakeImage("back" .. tostring(sp)), w = 64, h = 64 } end
function FakePokemon.monFrontPic(mon) return FakePokemon.frontPic(mon.species) end
function FakePokemon.monBackPic(mon) return FakePokemon.backPic(mon.species) end
function FakePokemon.icon(sp) return { image = fakeImage("icon" .. tostring(sp)), w = 32, h = 32, frames = 2, quads = {} } end
function FakePokemon.monIcon(mon) return FakePokemon.icon(mon.species) end

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

local FakeEvolution = { applied = {} }
function FakeEvolution.levelTarget(mon)
  for _, row in ipairs(P3._evolutions[tonumber(mon.species)] or {}) do
    if row.method == 4 and (tonumber(mon.level) or 0) >= row.param then return row.target end
  end
  return nil
end
function FakeEvolution.apply(mon, into)
  mon.species, mon.speciesId = into, into
  FakePokemon.applyStats(mon)
  FakeEvolution.applied[#FakeEvolution.applied + 1] = { mon = mon, into = into }
  return true
end

local FakeScene = { started = {} }
function FakeScene.start(mon, into, opts)
  FakeScene.started[#FakeScene.started + 1] = { mon = mon, into = into, opts = opts }
  FakeEvolution.apply(mon, into)
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
function FakeStorage.pcTransferMessage(_, name) return tostring(name) .. " was sent to the PC." end

local FakeLearn = { begun = {} }
function FakeLearn.begin(opts)
  FakeLearn.begun[#FakeLearn.begun + 1] = opts
  if FakePokemon.moveSlotCount(opts.mon) < 4 then
    FakePokemon.teachMove(opts.mon, opts.moveId)
    if opts.onDone then opts.onDone(true) end
    return
  end
  if opts.onDone then opts.onDone(false) end
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

-- Deterministic engine RNG (the wild monster's personality / IVs / item).
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

-- An invented trainer book.  Class 57's prize value comes from the engine's
-- own table (battle/prize.lua); nothing below asserts it as a literal.  903
-- is a rival: its row carries the cart's placeholder name, and the book
-- answers with the player's rival name instead (Trainers.info's `rivalName`,
-- for the rival and Champion classes).
local TRAINERS = {
  [900] = { class = 57, className = "YOUNGSTER", name = "BEN", pic = 5, gender = 0,
            encounterMusic = 0, lastLevel = 3, aiFlags = 1, items = { 0, 0, 0, 0 },
            party = { { species = 16, level = 3 } } },
  [901] = { class = 84, className = "LEADER", name = "ROCKY", pic = 9, gender = 0,
            encounterMusic = 0, lastLevel = 60, aiFlags = 7, items = { 21, 0, 0, 0 },
            party = { { species = 151, level = 60, moves = { 300 } } } },
  [902] = { class = 57, className = "TWINS", name = "AMY", pic = 6, gender = 1,
            encounterMusic = 130, lastLevel = 5, aiFlags = 1, items = { 0, 0, 0, 0 },
            doubleBattle = true, party = { { species = 16, level = 5 }, { species = 16, level = 5 } } },
  [903] = { class = 89, className = "RIVAL", name = "TERRY", pic = 7, gender = 0,
            encounterMusic = 0, lastLevel = 3, aiFlags = 1, items = { 0, 0, 0, 0 },
            party = { { species = 16, level = 3 } } },
}
local RIVAL_CLASSES = { [81] = true, [89] = true, [90] = true }
local FakeTrainers = {}
local function trainerView(id)
  local t = TRAINERS[tonumber(id)]
  if not t then return nil end
  local out = { id = tonumber(id), dialogs = { defeat = "I lost to you!" } }
  for k, v in pairs(t) do out[k] = v end
  out.partySize = #t.party
  out.ai = {}
  return out
end
FakeTrainers.get = trainerView
function FakeTrainers.info(id, opts)
  local out = trainerView(id)
  if out and RIVAL_CLASSES[out.class] and type(opts) == "table"
      and type(opts.rivalName) == "string" and opts.rivalName ~= "" then
    out.name = opts.rivalName
  end
  return out
end
function FakeTrainers.dialogs(id) return (trainerView(id) or {}).dialogs or {} end
function FakeTrainers._doublePersonalities(t)
  local out = {}
  for i = 1, #t.party do out[i] = 0x80 + i * 256 end
  return out
end
function FakeTrainers.getBattleMusicRole() return "battleTrainer", 297 end
function FakeTrainers.getVictoryMusicRole() return "victoryTrainer", 310 end
function FakeTrainers.foeFromId(id)
  local t = TRAINERS[tonumber(id)]
  if not t then return nil end
  local party = {}
  for _, m in ipairs(t.party) do
    party[#party + 1] = { species = m.species, level = m.level, iv = 0,
      ivs = { hp = 0, atk = 0, def = 0, spa = 0, spd = 0, spe = 0 },
      evs = { hp = 0, atk = 0, def = 0, spa = 0, spd = 0, spe = 0 },
      heldItem = m.heldItem, moves = m.moves, trainerId = tonumber(id) }
  end
  return { species = party[1].species, level = party[1].level, trainerId = tonumber(id),
           aiFlags = t.aiFlags, items = t.items, party = party, trainerName = t.name,
           trainerClass = t.class, trainerClassName = t.className, trainerPic = t.pic,
           gender = t.gender, doubleBattle = t.doubleBattle }
end

local FakeBattleText = {}
function FakeBattleText.get(id, fill)
  fill = fill or {}
  return id .. "|" .. tostring(fill.buff1 or "") .. "|" .. tostring(fill.trainer1Name or "")
end

local PROFILE = {
  family = "frlg",
  rules = { money = "frlg", lostText = "frlg", pickup = "flat", amuletCoinPlayerOnly = false },
  aiFlagBits = { CHECK_BAD_MOVE = 0, CHECK_VIABILITY = 1, TRY_TO_FAINT = 2,
                 SETUP_FIRST_TURN = 3, RISKY = 4, PREFER_STRONGEST_MOVE = 5 },
}
local FakeProfile = { get = function() return PROFILE end }

local bridgeCalls = {}
local FakeBridge = {}
function FakeBridge.calcMoneyLossFrlg() return 120 end
function FakeBridge.applyWhiteoutMoneyLoss(session)
  bridgeCalls[#bridgeCalls + 1] = { "loss" }
  local before = session.money
  session.money = math.max(0, before - 120)
  return before - session.money, session.money
end
function FakeBridge.start(_, _, foe, opts) bridgeCalls[#bridgeCalls + 1] = { "start", foe, opts }; return true end
function FakeBridge.startWild(_, _, foe, opts) bridgeCalls[#bridgeCalls + 1] = { "startWild", foe, opts }; return true end

local fieldCalls = {}
local FakeField = {}
function FakeField.respawnAtHeal()
  fieldCalls[#fieldCalls + 1] = "respawn"
  for _, mon in ipairs(SESSION.party) do mon.hp = mon.maxHp; mon.status = nil end
end
local FakeParty = {}
function FakeParty.healAll(party)
  for _, mon in ipairs(party or {}) do mon.hp = mon.maxHp; mon.status = nil end
end
local FakeNatives = {}
function FakeNatives.outcome_to_code(r)
  return ({ win = 1, lose = 2, draw = 3, run = 4, fled = 6, caught = 7 })[r] or 1
end
local spaceCalls = 0
local FakeSpace = { returnToField = function() spaceCalls = spaceCalls + 1 end }
-- The script VM a trainerbattle command waits in (Space.vm), the way
-- tests/gen3_coop.lua stands it in: `running` is what Vm:isRunning answers
-- (the engine counts "waiting"), `halted` counts Vm:halt.
local FakeVm = { running = false, halted = 0 }
function FakeVm:isRunning() return self.running end
function FakeVm:halt(aborted)
  self.halted = self.halted + 1
  self.running = false
  self.aborted = aborted
end
FakeSpace.vm = FakeVm

-- The trainerbattle opcode's continuation, as ops_a.lua writes it: a result
-- that is not a loss sets the trainer flag; either way the VM then runs on
-- from the bytes after the command -- unless something halted it first (the
-- whiteout's respawnAtHeal, on the cart).  What ran is recorded.
local function trainerOpcode()
  local op = { flag = false, postBytes = false, answered = nil }
  function op.done(result)
    op.answered = result
    local lost = result == "lose" or result == "whiteout" or result == "blackout"
    if not lost then op.flag = true end
    if FakeVm.running then op.postBytes = true end
  end
  return op
end
local encounterResets = 0
local FakeEncounters = {
  resetRateModifiers = function() encounterResets = encounterResets + 1 end,
  rules = function() return { wildHeldItem = function() return 0 end } end,
}
local battleActive = false

-- What the ending does beyond the rewards (SoloBattle M:_finishEffects3), in
-- the order it did it: Pokérus, the quest log, the TV, `battle.ended`.
local effectsLog = {}
local function effectsOf(kind)
  local out = {}
  for _, e in ipairs(effectsLog) do if e[1] == kind then out[#out + 1] = e end end
  return out
end
function FakePokemon.randomlyGivePartyPokerus(party, s)
  effectsLog[#effectsLog + 1] = { "pokerus.give", party, s }
end
function FakePokemon.partySpreadPokerus(party, s)
  effectsLog[#effectsLog + 1] = { "pokerus.spread", party, s }
end
function FakePokemon.isShiny() return false end
local FakeFieldModules = { enabled = function(name) return name == "questLog" end }
local FakeQuestLog = {
  battle = function(s, st) effectsLog[#effectsLog + 1] = { "questlog", s, st } end,
}
local FakeRse = {
  call = function(name, fn, what, logger, ...)
    effectsLog[#effectsLog + 1] = { "rse", name, fn, what, logger, ... }
    return nil, true
  end,
}
local FakeRuntime = {
  wants = function(name) return name == "battle.ended" end,
  wantsHook = function() return false end,
  emit = function(name, payload) effectsLog[#effectsLog + 1] = { "emit", name, payload } end,
  call = function(_, vanilla, ...) return vanilla(nil, ...) end,
}
-- The overworld weather module (Weather.get), its id set per scenario.
local FakeWeather = { id = 0 }
function FakeWeather.get() return FakeWeather.id end
-- FLAG_BADGE0n_GET, read off a `badges` set on the store (the session here).
local FakeFlags = {}
function FakeFlags.hasBadge(store, n) return type(store.badges) == "table" and store.badges[n] == true end

stub("src.core.game3.runtime", { getSession = function() return SESSION end })
stub("src.core.game3.pokemon", FakePokemon)
stub("src.core.game3.bag", FakeBag)
stub("src.core.game3.dex", FakeDex)
stub("src.core.game3.evolution", FakeEvolution)
stub("src.ui.game3.evolution_scene", FakeScene)
stub("src.core.game3.storage", FakeStorage)
stub("src.core.game3.battle.learn_move", FakeLearn)
stub("src.ui.game3.summary_menu", { openMenu = function() end })
stub("src.core.game3.audio", FakeAudio)
stub("src.core.game3.battle", { isActive = function() return battleActive end })
stub("src.core.game3.battle.catching", { playerSecretId = function(s) return s.secretId end })
stub("src.core.game3.constants", { of = function()
  return { song = function() return 7 end, id = function() return nil end,
           name = function() return nil end }
end })
stub("src.core.game3.rng", FakeRng)
stub("src.core.game3.battle.damage", FakeDamage)
stub("src.core.game3.scripting.trainers", FakeTrainers)
stub("src.core.game3.battle.battle_text", FakeBattleText)
stub("src.core.game3.battle.profile", FakeProfile)
stub("src.core.game3.battle_bridge", FakeBridge)
stub("src.core.game3.field", FakeField)
stub("src.core.game3.party", FakeParty)
stub("src.core.game3.scripting.natives", FakeNatives)
stub("src.core.game3.scripting.space", FakeSpace)
stub("src.core.game3.encounters", FakeEncounters)
stub("src.core.game3.field_modules", FakeFieldModules)
stub("src.core.game3.quest_log_recorder", FakeQuestLog)
stub("src.core.game3.rse.init", FakeRse)
stub("src.mods.Runtime", FakeRuntime)
stub("src.core.game3.scripting.flags", FakeFlags)
stub("src.core.game3.weather", FakeWeather)

-- The real pure engine modules, after the stand-ins they close over.
local Experience = require("src.core.game3.battle.experience")
local Prize = require("src.core.game3.battle.prize")
local Stack = require("src.ui.game3.stack")
check(type(Experience.syncExpToLevel) == "function", "the engine's Gen 3 Experience loads headless")
check(type(Prize.calc) == "function", "the engine's Gen 3 prize formula loads headless")

local need = newNeed()
local Config = need("Config")
local Sheet3 = need("Sheet3")
local Mediated = need("MediatedBattle")
local Gen3Ui = need("Gen3Ui")
local Solo = need("SoloBattle")
local Brain = need("SoloBrain")
local Sim = need("BattleSim3/init")
local E = Sim.Effects.E

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

local GAME
local function newGame(sessionExtra)
  SESSION = newSession(sessionExtra)
  GAME = { generation = 3, phase = "field", data = DATA, session = SESSION, input = fakeInput() }
  stubMod.game = GAME
  Stack.clear()
  FakeDex.captures, FakeDex.seen = {}, {}
  FakeScene.started, FakeLearn.begun = {}, {}
  bridgeCalls, fieldCalls = {}, {}
  spaceCalls, encounterResets = 0, 0
  battleActive = false
  effectsLog = {}
  FakeVm.running, FakeVm.halted, FakeVm.aborted = false, 0, nil
  return GAME
end

local function monOf(species, level, extra)
  local mon = {
    species = species, speciesId = species, level = level, nickname = "",
    growthRate = P3._speciesMeta[species].growthRate,
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

-- The Ui a solo fight is handed: boxes are recorded, the state goes onto the
-- real game3 stack through Gen3Ui (so `leave` pops it and runs `exit`).
local said, nicknames = {}, {}
local UI = {
  pushState = function(_, game, state) return Gen3Ui.pushState(game, state) end,
  say = function(_, text, cb) said[#said + 1] = text; if cb then cb() end; return {} end,
  confirm = function(_, _, text, cb) said[#said + 1] = text; if cb then cb(true) end; return {} end,
  askNickname = function(_, _, mon, label) nicknames[#nicknames + 1] = label; return true end,
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

-- Pump a fight the way the game does -- the referee once a frame, the screen
-- once a frame -- answering each command menu with `onChoose(fight)`, until
-- the ending has printed; then leave it (A on the last line).
local function drive(solo, onChoose, maxSteps)
  local fight = solo.fight
  local lastFight = fight
  for _ = 1, maxSteps or 300 do
    solo:update(0.5, GAME)
    fight = solo.fight
    if not fight then return true, lastFight end
    lastFight = fight
    for _ = 1, 60 do
      fight:update(2.0)
      if fight.phase == "choose" or fight.phase == "switch"
         or (fight.phase == "over" and #fight.lines == 0 and not fight.shown) then
        break
      end
    end
    if fight.phase == "over" and #fight.lines == 0 and not fight.shown then
      -- A on the last line is taken only once the screen's own ending has
      -- nothing left to say (a Pay Day line is owed until then).
      for _ = 1, 60 do
        fight:update(2.0)
        if #fight.lines == 0 and not fight.shown and not fight.payDayLine then break end
      end
      fight:leave()
      return true, lastFight
    end
    if fight.phase == "choose" and onChoose then onChoose(fight) end
  end
  return false, lastFight
end


-- ===================================================================
-- the Legend family's fixture
-- ===================================================================

local CURRENT_SOLO = nil
local CoopField = need("CoopField")
local Turn3 = need("BattleSim3/Turn")

-- The engine's whole outcome vocabulary (scripting/natives.lua
-- outcome_to_code): a number passes through, an unknown word is WON.
local CODES = {
  win = 1, won = 1, lose = 2, lost = 2, whiteout = 2, blackout = 2, draw = 3, drew = 3,
  run = 4, ran = 4, fled_player = 4, teleport_player = 5, player_teleported = 5,
  fled = 6, mon_fled = 6, caught = 7, catch = 7, no_safari_balls = 8, forfeited = 9,
  mon_teleported = 10,
}
FakeNatives.outcome_to_code = function(r)
  if type(r) == "number" then return r end
  return CODES[r] or 1
end
FakeAudio.clearSavedSong = function() end

-- The cart's species names, as the engine's constants answer them (pret
-- SPECIES_* enum numbers; the rows behind them are synthetic).
local SPECIES = {
  SPECIES_MOLTRES = 146, SPECIES_ARTICUNO = 144, SPECIES_ZAPDOS = 145, SPECIES_MEWTWO = 150,
  SPECIES_LUGIA = 249, SPECIES_HO_OH = 250, SPECIES_DEOXYS = 410,
}
package.loaded["src.core.game3.constants"].of = function()
  return {
    song = function() return 7 end,
    id = function(_, kind, name)
      if kind == "species" then return SPECIES[name] end
      return nil
    end,
    name = function() return nil end,
  }
end

-- Synthetic species: slow, frail, Normal-typed, one move each.
local function base(hp, atk, def, spe, spa, spd)
  return { hp = hp, atk = atk, def = def, spe = spe, spa = spa, spd = spd }
end
local function addSpecies(id, name, learn)
  P3._names[id] = name
  P3._types[id] = { 0, 0 }
  P3._stats[id] = base(40, 40, 40, 10, 40, 40)
  P3._speciesMeta[id] = { catchRate = 3, expYield = 200, genderRatio = 255, eggCycles = 80,
    friendship = 0, growthRate = 5, eggGroup1 = 15, eggGroup2 = 15, itemCommon = 0, itemRare = 0 }
  P3._abilities[id] = { 0, 0 }
  P3._learnsets[id] = learn
end
addSpecies(243, "RAIKOU", { { 1, 46 } })
addSpecies(381, "LATIOS", { { 1, 46 } })
addSpecies(150, "MEWTWO", { { 1, 45 } })
addSpecies(146, "MOLTRES", { { 1, 45 } })
addSpecies(105, "MAROWAK", { { 1, 45 } })
addSpecies(143, "SNORLAX", { { 1, 45 } })
addSpecies(92, "GASTLY", { { 1, 45 } })

-- ROAR / WHIRLWIND (pret EFFECT_ROAR, priority -6) and TELEPORT (EFFECT_TELEPORT)
-- on invented rows under their MOVE_* numbers.
ROM[46] = { effect = E.ROAR, power = 0, type = 0, accuracy = 100, pp = 20,
            secondaryChance = 0, target = 0, priority = -6, flags = 0 }
P3._moveNames[46] = "ROAR"
ROM[18] = { effect = E.ROAR, power = 0, type = 0, accuracy = 100, pp = 20,
            secondaryChance = 0, target = 0, priority = -6, flags = 0 }
P3._moveNames[18] = "WHIRLWIND"
ROM[100] = { effect = E.TELEPORT, power = 0, type = 14, accuracy = 0, pp = 20,
             secondaryChance = 0, target = 16, priority = 0, flags = 0 }
P3._moveNames[100] = "TELEPORT"
ROM[153] = { effect = E.EXPLOSION, power = 250, type = 0, accuracy = 100, pp = 5,
             secondaryChance = 0, target = 0, priority = 0, flags = 2 }
P3._moveNames[153] = "EXPLOSION"

-- The engine's own Roamer module, over the stand-in RNG and POKeMON module
-- it requires.  Emerald's arm reads its config off the battle profile and
-- its location sets off the dataset cache: both handed in here.
local Roamer = require("src.core.game3.roamer")
check(type(Roamer.onBattleEnd) == "function", "the engine's Roamer module loads headless")
local EM_ROAMER = { level = 40, locations = "synthetic", moveOdds = 16, encounterOdds = 4 }
Roamer._locations[EM_ROAMER] = {
  { "EM_ROUTE_110", "EM_ROUTE_111", "EM_ROUTE_112" },
  { "EM_ROUTE_118", "EM_ROUTE_119", "EM_ROUTE_120" },
  { "EM_ROUTE_121", "EM_ROUTE_122", "EM_ROUTE_123" },
}
local onBattleEndCalls = {}
do
  local real = Roamer.onBattleEnd
  Roamer.onBattleEnd = function(session, foeState, result, reason)
    onBattleEndCalls[#onBattleEndCalls + 1] = { state = foeState, result = result }
    return real(session, foeState, result, reason)
  end
end

FakePokemon.ghostPic = function() return { image = fakeImage("ghost"), w = 64, h = 64 } end
FakeBridge.startWild = function(_, _, foe, opts)
  bridgeCalls[#bridgeCalls + 1] = { "startWild", foe, opts, handingBack = CURRENT_SOLO
    and CURRENT_SOLO.handingBack3 }
  return true
end

-- What the referee and the screen are built with, captured on the way.
local createdWith, screenedWith = nil, nil
local realCreate, realNew = Turn3.create, Mediated.new
Turn3.create = function(o) createdWith = o; return realCreate(o) end
Mediated.new = function(o) screenedWith = o; return realNew(o) end

local function seenAt(species)
  for _, s in ipairs(FakeDex.seen) do
    if s.species == species and not s.caught then return true end
  end
  return false
end

local function frGame(extra)
  PROFILE.family = "frlg"
  PROFILE.rules.teleportOutcome = nil
  PROFILE.roamer = nil
  local g = newGame(extra)
  createdWith, screenedWith = nil, nil
  onBattleEndCalls = {}
  return g
end

local function emGame(extra)
  local x = { version = "emerald" }
  for k, v in pairs(extra or {}) do x[k] = v end
  local g = frGame(x)
  PROFILE.family = "rse"
  PROFILE.rules.teleportOutcome = "side"
  return g
end

-- The player's monster: the fixture's CHARMANDER with the moves a scenario
-- needs (SCRATCH 10, GROWL 45, MINDBLAST 300, WHIRLWIND 18).
local function lead(level, moves, extra)
  local pp, max = {}, {}
  for i, m in ipairs(moves) do pp[i] = ROM[m].pp; max[i] = ROM[m].pp end
  local x = { moves = moves, pp = pp, maxPp = max }
  for k, v in pairs(extra or {}) do x[k] = v end
  return monOf(4, level, x)
end

-- A stand-in from the wild door (CoopField.wildStand3), and what
-- src/Client.lua's offerFight3 hands solo for it.
local fightAloneCalls = 0
local function standFor(enc, opts, mapId)
  return CoopField.wildStand3(enc, {
    game = GAME, mapId = mapId or "FR_ROUTE_1", solo = true,
    fightAlone = function() fightAloneCalls = fightAloneCalls + 1 end,
  }, opts or {})
end
local function offer(solo, stand, enc, opts)
  local o = {}
  for k, v in pairs(opts or {}) do o[k] = v end
  o.mapId = stand.mapId
  o.done = o.done or function() end
  o.fallback = o.fallback or function() stand:fightAlone() end
  o.party = stand.enemyParty
  o.stand3 = stand
  local withMon = {}
  for k, v in pairs(enc) do withMon[k] = v end
  withMon.mon = stand.enemyParty[1]
  CURRENT_SOLO = solo
  return solo:fromGen3Encounter(GAME, withMon, o)
end

-- A FireRed roamer in the save (roamer.lua Roamer.init's shape: `pid`, the
-- spelled-out IV keys, `statusNum`) and the encounter Roamer.tryEncounter
-- builds from it.
local function frRoamer(extra)
  local r = {
    active = true, species = 243, level = 50, hp = 60, maxHp = 100,
    status = 0, statusNum = 0, pid = 0x12345678,
    ivs = { hp = 1, attack = 2, defense = 3, speed = 4, spAtk = 5, spDef = 6 },
    moves = { 46 }, pp = { 20 }, map = "FR_ROUTE_1",
  }
  for k, v in pairs(extra or {}) do r[k] = v end
  SESSION.roamer = r
  local foe = {
    species = r.species, speciesId = r.species, level = r.level, hp = r.hp, maxHp = r.maxHp,
    status = r.status, statusNum = r.statusNum, pid = r.pid, ivs = r.ivs, moves = r.moves,
    pp = r.pp, roamer = true,
  }
  return r, { species = r.species, level = r.level, roamer = true, foe = foe }
end

-- An Emerald roamer (roamer.lua initRse's shape) and try_encounter_rse's
-- encounter.
local function emRoamer(extra)
  local r = {
    active = true, species = 381, level = 40, hp = 50, status = 0,
    ivs = { hp = 9, atk = 8, def = 7, spe = 6, spa = 5, spd = 4 }, personality = 0x0BADCAFE,
    map = "EM_ROUTE_110", history = { false, false, false },
  }
  for k, v in pairs(extra or {}) do r[k] = v end
  SESSION.roamer = r
  PROFILE.roamer = EM_ROAMER
  local foe = {
    species = r.species, speciesId = r.species, level = r.level, ivs = r.ivs,
    personality = r.personality, hp = r.hp, status = r.status, roamer = true,
    moves = r.moves,
  }
  return r, { species = r.species, level = r.level, roamer = true, foe = foe }
end

local function throwBall(f)
  f.itemPick = { id = 1, effect = Sheet3.itemEffect(1) }
  f:commitItem(nil, nil)
end
local function runAway(f) f:sendChoice({ action = "run" }) end

local Legend

-- ===================================================================
-- 1. the family module, found through the registry
-- ===================================================================
do
  eq(Solo.KIND_FILES3.roamer, "Solo3/Legend", "registry: a roamer's module is Solo3/Legend")
  for _, name in ipairs({ "legendary", "scripted", "ghost" }) do
    eq(Solo.KIND_FILES3[name], "Solo3/Legend", "registry: ...and a " .. name .. "'s")
  end
  -- The facade's reader, as the game's: the family is read the first time a
  -- fight asks for one of its kinds.
  stubMod.read = function(_, path)
    local h = io.open(MOD_PATH .. "/" .. path, "rb")
    if not h then return nil end
    local body = h:read("*a")
    h:close()
    return body
  end
  local roamer = Solo.kind3("roamer")
  check(type(roamer) == "table", "registry: the roamer kind is read from src/Solo3/Legend.lua")
  Legend = need("Solo3/Legend")
  check(type(Legend) == "table" and type(Legend.kinds3) == "table", "registry: the module returns its kinds3")
  local names = {}
  for name in pairs(Legend.kinds3) do names[#names + 1] = name end
  table.sort(names)
  eq(table.concat(names, ","), "ghost,legendary,roamer,scripted", "registry: exactly the four kinds")
  for _, name in ipairs(names) do
    eq(Solo.KINDS3[name], Legend.kinds3[name], "registry: " .. name .. " is registered as the module's own")
  end
  eq(roamer, Legend.kinds3.roamer, "registry: ...the very table kind3() found")
  for name, kind in pairs(Legend.kinds3) do
    for key, fn in pairs(kind) do
      check(type(fn) == "function", "registry: " .. name .. "." .. tostring(key) .. " is a hook")
    end
  end
  eq(#warns, 0, "registry: read without a word said")
end

-- ===================================================================
-- 2. roamers
-- ===================================================================

-- (a) seating: the save's roamer, AI_Roaming, FireRed's theme, the dex
do
  frGame()
  SESSION.party = { lead(30, { 45 }) }
  local saved, enc = frRoamer({ status = 64, statusNum = 64 })
  local stand = standFor(enc)
  eq(stand and stand.kind3, "roamer", "roamer: the door's stand says roamer")
  local solo = newSolo()
  check(offer(solo, stand, enc), "roamer: taken")
  local mon = solo.wildMon
  eq(mon, stand.enemyParty[1], "roamer: the stand's own monster is fought")
  eq(mon and mon.personality, saved.pid, "roamer: the saved personality (pret CreateRoamerMonInstance; E5)")
  eq(mon and mon.ivs and mon.ivs.atk, 2, "roamer: the saved IVs, read under FireRed's own keys")
  eq(mon and mon.hp, 60, "roamer: the saved HP")
  eq(mon and mon.status, "PAR", "roamer: the saved status")
  local b = createdWith and createdWith.sides.b[1]
  eq(b and b.ai, "roamer", "roamer: side b's entry runs AI_Roaming")
  eq(b and b.mons[1].hp, 60, "roamer: ...over the saved HP")
  eq(b and b.mons[1].status, "PAR", "roamer: ...and status")
  eq(createdWith and createdWith.wildPick, "cart", "roamer: (the core's wild move under it)")
  eq(solo.sim.byId.solo_foe.ai, "roamer", "roamer: the referee seated the AI")
  eq(screenedWith and screenedWith.song, "MUS_VS_LEGEND",
     "roamer (FRLG): StartRoamerBattle's MUS_VS_LEGEND, not the port's MUS_VS_DEOXYS (E4)")
  check(seenAt(243), "roamer: the dex sees a roamer (pret marks every wild but the excluded)")
  solo:reset()

  -- A music pack's own role wins over the name, as the engine's lookup does.
  frGame()
  SESSION.party = { lead(30, { 45 }) }
  local _, enc2 = frRoamer()
  FakeAudio.role = function(name) return name == "battleLegend" and 341 or nil end
  local s2 = newSolo()
  check(offer(s2, standFor(enc2), enc2), "roamer: taken (a music pack's role)")
  eq(screenedWith and screenedWith.song, 341, "roamer: the role's song")
  FakeAudio.role = function() return nil end
  s2:reset()

  -- Emerald's roamer plays the ordinary wild theme (song 0 at its start).
  emGame()
  SESSION.party = { lead(30, { 45 }) }
  local _, enc3 = emRoamer({ moves = { 46 } })
  local s3 = newSolo()
  check(offer(s3, standFor(enc3, nil, "EM_ROUTE_110"), enc3), "roamer (EM): taken")
  eq(screenedWith and screenedWith.song, nil, "roamer (EM): no theme of its own")
  eq(s3.wildMon and s3.wildMon.personality, 0x0BADCAFE, "roamer (EM): the saved personality")
  eq(createdWith and createdWith.sides.b[1].ai, "roamer", "roamer (EM): AI_Roaming too")
  s3:reset()

  -- No stand (a direct caller): built from the save's descriptor all the
  -- same, never from the encounter's outer species and level.
  frGame()
  SESSION.party = { lead(30, { 45 }) }
  local savedD, encD = frRoamer({ hp = 41 })
  local sd = newSolo()
  CURRENT_SOLO = sd
  check(sd:fromGen3Encounter(GAME, encD, {}), "roamer (no stand): taken")
  eq(sd.wildMon and sd.wildMon.personality, savedD.pid, "roamer (no stand): the saved personality")
  eq(sd.wildMon and sd.wildMon.hp, 41, "roamer (no stand): ...and HP")
  eq(sd.wildMon and sd.wildMon.ivs and sd.wildMon.ivs.spd, 6, "roamer (no stand): ...and IVs")
  sd:reset()
end

-- (b) the endings, the writeback, the move -- FireRed
local function frEnding(label, setup)
  frGame()
  local s = setup()
  local solo = newSolo()
  local result
  check(offer(solo, standFor(s.enc), s.enc, { done = function(r) result = r end }),
        label .. ": taken")
  local ok, fight = drive(solo, s.choose)
  check(ok, label .. ": the fight ran to its end")
  return result, fight, solo
end

do
  -- Fled: AI_Roaming's RUN, after the player's SCRATCH lands.
  local saved
  local result, fight = frEnding("roamer flees", function()
    SESSION.party = { lead(30, { 10 }) }
    local r, enc = frRoamer()
    saved = r
    return { enc = enc, choose = function(f) f:pickMove(1) end }
  end)
  eq(result, "mon_fled", "roamer flees: done('mon_fled')")
  eq(SESSION.battleOutcome, 6, "roamer flees: B_OUTCOME_MON_FLED")
  check(textOf(fight):find("fled", 1, true) ~= nil, "roamer flees: 'Wild RAIKOU fled!'")
  eq(#onBattleEndCalls, 1, "roamer flees: the engine's Roamer.onBattleEnd, once")
  eq(onBattleEndCalls[1] and onBattleEndCalls[1].result, "mon_fled", "roamer flees: ...told the outcome")
  check(saved.hp < 60 and saved.hp > 0, "roamer flees: the SCRATCH it took is banked (" .. tostring(saved.hp) .. ")")
  eq(saved.active, true, "roamer flees: an even outcome keeps it roaming")
  check(saved.map ~= "FR_ROUTE_1", "roamer flees: ...somewhere else (UpdateRoamerHPStatus moves it)")
  eq(saved.status, 0, "roamer flees: healthy, banked as the status byte")
end

do
  -- Knocked out: WON (1), odd -- put away, after it moved.
  local saved
  local result = frEnding("roamer KO", function()
    SESSION.party = { lead(100, { 300 }) }
    local r, enc = frRoamer()
    saved = r
    return { enc = enc, choose = function(f) f:pickMove(1) end }
  end)
  eq(result, "win", "roamer KO: done('win')")
  eq(SESSION.battleOutcome, 1, "roamer KO: B_OUTCOME_WON")
  eq(#onBattleEndCalls, 1, "roamer KO: onBattleEnd once")
  eq(saved.hp, 0, "roamer KO: HP 0 banked")
  eq(saved.active, false, "roamer KO: put away for good")
  check(saved.map ~= "FR_ROUTE_1", "roamer KO: moved first, as UpdateRoamerHPStatus does before the check")
end

do
  -- Caught (7): put away, the catch keeps the damage, the monster joins.
  local saved
  local result = frEnding("roamer caught", function()
    SESSION.party = { lead(30, { 45 }) }
    FakeBag.add(SESSION.bag, 1, 1)
    local r, enc = frRoamer()
    saved = r
    local thrown = false
    return { enc = enc, choose = function(f)
      if not thrown then thrown = true; throwBall(f) else f:pickMove(1) end
    end }
  end)
  eq(result, "caught", "roamer caught: done('caught')")
  eq(SESSION.battleOutcome, 7, "roamer caught: B_OUTCOME_CAUGHT")
  eq(#onBattleEndCalls, 1, "roamer caught: onBattleEnd once")
  eq(saved.active, false, "roamer caught: put away")
  check(saved.map ~= "FR_ROUTE_1", "roamer caught: moved first")
  eq(#SESSION.party, 2, "roamer caught: in the party")
  eq(SESSION.party[2] and SESSION.party[2].hp, 60, "roamer caught: ...with the HP it was met with")
end

do
  -- Its own ROAR (the player holds it with SHADOW TAG): FireRed words it
  -- PLAYER_TELEPORTED (5) -- odd, and the cart's 1.0 rule puts the roamer
  -- away for it; the engine port's FireRed arm would keep it (E1).
  local saved
  local result = frEnding("roamer ROAR (FRLG)", function()
    SESSION.party = { lead(30, { 45 }, { ability = 23 }) }
    local r, enc = frRoamer()
    saved = r
    return { enc = enc, choose = function(f) f:pickMove(1) end }
  end)
  eq(result, "teleport_player", "roamer ROAR (FRLG): done('teleport_player')")
  eq(SESSION.battleOutcome, 5, "roamer ROAR (FRLG): B_OUTCOME_PLAYER_TELEPORTED")
  eq(#onBattleEndCalls, 1, "roamer ROAR (FRLG): onBattleEnd once")
  eq(saved.active, false, "roamer ROAR (FRLG): the vanilla bug -- an odd outcome puts it away (pret, not E1)")
  check(saved.map ~= "FR_ROUTE_1", "roamer ROAR (FRLG): ...after the move every ending makes")
  eq(saved.hp, 60, "roamer ROAR (FRLG): its HP banked")
end

do
  -- Asleep with the cart's counter: held by SHADOW TAG, it sleeps through a
  -- turn (3 -> 2), the player runs, and the byte banked says 2 turns left.
  local saved
  local result = frEnding("roamer asleep", function()
    SESSION.party = { lead(30, { 45 }, { ability = 23 }) }
    local r, enc = frRoamer({ status = 3, statusNum = 3 })
    saved = r
    local turn = 0
    return { enc = enc, choose = function(f)
      turn = turn + 1
      if turn == 1 then f:pickMove(1) else runAway(f) end
    end }
  end)
  eq(result, "run", "roamer asleep: done('run')")
  eq(saved.active, true, "roamer asleep: RAN (4) keeps it")
  eq(saved.status, 2, "roamer asleep: the sleep counter is banked in the status byte (STATUS1_SLEEP = 2)")
  eq(saved.statusNum, 2, "roamer asleep: ...FireRed's statusNum too (the save converters read it)")
  local word, turns = CoopField.status3(saved.status, saved.statusNum)
  eq(word, "SLP", "roamer asleep: the next stand reads it asleep")
  eq(turns, 2, "roamer asleep: ...with the cart's two turns, not a fresh roll")
end

do
  -- Asleep and free, it still flees (AI_Roaming runs before the sleep check;
  -- the engine port's sleeping roamer can't -- E2): its counter untouched.
  local saved
  local result = frEnding("roamer asleep flees", function()
    SESSION.party = { lead(30, { 45 }) }
    local r, enc = frRoamer({ status = 3, statusNum = 3 })
    saved = r
    return { enc = enc, choose = function(f) f:pickMove(1) end }
  end)
  eq(result, "mon_fled", "roamer asleep flees: done('mon_fled')")
  eq(saved.status, 3, "roamer asleep flees: the same three turns banked")
end

do
  -- It whites the player out (LOST, 2 -- even): it roams on with its HP.
  local saved
  local result = frEnding("roamer wins", function()
    SESSION.party = { lead(5, { 45 }, { ability = 23, hp = 1 }) }
    local r, enc = frRoamer({ moves = { 300 }, pp = { 10 } })
    saved = r
    return { enc = enc, choose = function(f) f:pickMove(1) end }
  end)
  eq(result, "lose", "roamer wins: done('lose')")
  eq(SESSION.battleOutcome, 2, "roamer wins: B_OUTCOME_LOST")
  eq(#fieldCalls, 1, "roamer wins: the whiteout")
  eq(saved.active, true, "roamer wins: an even outcome keeps it")
  eq(saved.hp, 60, "roamer wins: its HP banked")
  check(saved.map ~= "FR_ROUTE_1", "roamer wins: moved on")
end

do
  -- Paralysed, it flees: PAR banked as STATUS1_PARALYSIS.
  local saved
  frEnding("roamer PAR", function()
    SESSION.party = { lead(30, { 45 }) }
    local r, enc = frRoamer({ status = 64, statusNum = 64 })
    saved = r
    return { enc = enc, choose = function(f) f:pickMove(1) end }
  end)
  eq(saved.status, 64, "roamer PAR: STATUS1_PARALYSIS banked")
  eq(saved.active, true, "roamer PAR: still roaming")
end

-- (c) the endings -- Emerald (the engine's arm is pret's)
local function emEnding(label, setup)
  emGame()
  local s = setup()
  local solo = newSolo()
  local result
  check(offer(solo, standFor(s.enc, nil, "EM_ROUTE_110"), s.enc,
        { done = function(r) result = r end }), label .. ": taken")
  local ok = drive(solo, s.choose)
  check(ok, label .. ": the fight ran to its end")
  return result
end

do
  -- Its own ROAR: MON_TELEPORTED (10), even -- it roams on.
  local saved
  local result = emEnding("roamer ROAR (EM)", function()
    SESSION.party = { lead(30, { 45 }, { ability = 23 }) }
    local r, enc = emRoamer({ moves = { 46 } })
    saved = r
    return { enc = enc, choose = function(f) f:pickMove(1) end }
  end)
  eq(result, "mon_teleported", "roamer ROAR (EM): done('mon_teleported')")
  eq(SESSION.battleOutcome, 10, "roamer ROAR (EM): B_OUTCOME_MON_TELEPORTED")
  eq(#onBattleEndCalls, 1, "roamer ROAR (EM): onBattleEnd once")
  eq(saved.active, true, "roamer ROAR (EM): an even outcome keeps it")
  check(saved.map ~= "EM_ROUTE_110", "roamer ROAR (EM): moved to another set")
end

do
  -- The player's WHIRLWIND: PLAYER_TELEPORTED (5), odd -- put away (the
  -- vanilla bug, on Emerald too).
  local saved
  local result = emEnding("roamer WHIRLWIND (EM)", function()
    SESSION.party = { lead(50, { 18 }, { ability = 23 }) }
    local r, enc = emRoamer({ moves = { 45 } })
    saved = r
    return { enc = enc, choose = function(f) f:pickMove(1) end }
  end)
  eq(result, "teleport_player", "roamer WHIRLWIND (EM): done('teleport_player')")
  eq(SESSION.battleOutcome, 5, "roamer WHIRLWIND (EM): B_OUTCOME_PLAYER_TELEPORTED")
  eq(#onBattleEndCalls, 1, "roamer WHIRLWIND (EM): onBattleEnd once")
  eq(saved.active, false, "roamer WHIRLWIND (EM): put away")
  check(saved.map ~= "EM_ROUTE_110", "roamer WHIRLWIND (EM): ...after its move")
end

do
  -- Both go down to the player's EXPLOSION: the player whites out (the core
  -- says "lose"), but gBattleOutcome is DREW (3, Cmd_checkteamslost ORs LOST
  -- and WON) -- odd, so the roamer is put away, never left roaming at 0 HP.
  local saved
  local result = emEnding("roamer double KO (EM)", function()
    SESSION.party = { lead(60, { 153 }, { ability = 23 }) }
    local r, enc = emRoamer({ moves = { 45 } })
    saved = r
    return { enc = enc, choose = function(f) f:pickMove(1) end }
  end)
  eq(result, "lose", "roamer double KO (EM): the caller is told 'lose' (a whiteout)")
  eq(#fieldCalls, 1, "roamer double KO (EM): ...and the player whited out")
  eq(onBattleEndCalls[1] and onBattleEndCalls[1].result, "draw",
     "roamer double KO (EM): the roamer's writeback reads DREW")
  eq(saved.hp, 0, "roamer double KO (EM): HP 0 banked")
  eq(saved.active, false, "roamer double KO (EM): put away (3 is odd)")
end

do
  -- Fled on Emerald: banked and kept, the status as the byte.
  local saved
  local result = emEnding("roamer flees (EM)", function()
    SESSION.party = { lead(30, { 45 }) }
    local r, enc = emRoamer({ moves = { 46 }, status = 16 })
    saved = r
    return { enc = enc, choose = function(f) f:pickMove(1) end }
  end)
  eq(result, "mon_fled", "roamer flees (EM): done('mon_fled')")
  eq(saved.active, true, "roamer flees (EM): kept")
  eq(saved.status, 16, "roamer flees (EM): STATUS1_BURN banked")
  -- Its flee ends the battle in its own action: no end-of-turn burn chip.
  eq(saved.hp, 50, "roamer flees (EM): its HP banked as it left")
  PROFILE.roamer = nil
end

-- (d) the hand-back
do
  -- The door's own restart (the stand-in's fightAlone, src/Client.lua's
  -- roamer-shaped one) when it gave one.
  frGame()
  SESSION.party = { lead(30, { 45 }) }
  local _, enc = frRoamer()
  local stand = standFor(enc)
  local fell = 0
  local solo = newSolo()
  check(offer(solo, stand, enc, { fallback = function() fell = fell + 1 end }), "hand-back: taken")
  solo:reset()
  eq(fell, 1, "hand-back: the door's own restart, once")
  eq(#bridgeCalls, 0, "hand-back: ...and nothing started besides")
  eq(#onBattleEndCalls, 0, "hand-back: nothing banked by the mod (the cart's battle banks it)")

  -- No door restart: the engine's wild start with the roamer encounter.
  frGame()
  SESSION.party = { lead(30, { 45 }) }
  local saved, encD = frRoamer({ hp = 33, status = 64, statusNum = 64 })
  local sd = newSolo()
  CURRENT_SOLO = sd
  local doneFn = function() end
  check(sd:fromGen3Encounter(GAME, encD, { done = doneFn }), "hand-back (no door): taken")
  local met = sd.wildMon
  sd:reset()
  local call = bridgeCalls[1]
  eq(#bridgeCalls, 1, "hand-back (no door): one start")
  eq(call and call[1], "startWild", "hand-back (no door): the engine's wild start")
  local foe, o = call and call[2] or {}, call and call[3] or {}
  eq(foe.roamer, true, "hand-back (no door): ...of a roamer (the engine banks it at its end)")
  eq(foe.foe, encD.foe, "hand-back (no door): ...the save's descriptor riding along")
  eq(foe.species, 243, "hand-back (no door): the roamer met")
  eq(foe.personality, saved.pid, "hand-back (no door): ...its personality")
  eq(foe.hp, 33, "hand-back (no door): ...the HP it was met with")
  eq(foe.status, "PAR", "hand-back (no door): ...and status")
  eq(foe.mon, nil, "hand-back (no door): no engine monster on the row")
  check(met and foe.ivs == met.ivs, "hand-back (no door): the IVs it was built with")
  eq(o.roamer, true, "hand-back (no door): the start says roamer")
  eq(o.done, doneFn, "hand-back (no door): the caller's done")
  eq(o[CoopField.HANDBACK3], true, "hand-back (no door): marked a hand-back (no divert offers it again)")
  eq(call and call.handingBack, true, "hand-back (no door): under the core's hand-back guard")
  eq(saved.active, true, "hand-back (no door): the save's roamer untouched")
  eq(#onBattleEndCalls, 0, "hand-back (no door): nothing banked by the mod")
end

-- ===================================================================
-- 3. legendaries
-- ===================================================================

-- (a) FireRed's Mewtwo: the wild move, no held item, MUS_VS_MEWTWO, no "seen"
do
  frGame()
  SESSION.party = { lead(70, { 45 }) }
  local meta = P3._speciesMeta[150]
  meta.itemCommon, meta.itemRare = 21, 21
  local foe = { species = 150, level = 70, legendary = true, specialWild = true }
  local stand = standFor(foe, { wild = true, legendary = true })
  eq(stand and stand.kind3, "legendary", "legendary: the door's stand says legendary")
  local solo = newSolo()
  check(offer(solo, stand, foe, { wild = true, legendary = true }), "legendary: taken")
  eq(createdWith and createdWith.wildPick, "cart", "legendary: the cart's random wild move (no AI under LEGENDARY)")
  eq(createdWith and createdWith.sides.b[1].ai, nil, "legendary: ...and no AI script")
  eq(solo.wildMon and solo.wildMon.item, 0, "legendary: no held-item roll under LEGENDARY (common == rare or not)")
  eq(screenedWith and screenedWith.song, "MUS_VS_MEWTWO", "legendary (FRLG): StartLegendaryBattle's MUS_VS_MEWTWO")
  check(not seenAt(150), "legendary (FRLG): no dex 'seen' at the intro (pret battle_main.c:2622; E7)")
  check(solo.gen3 and solo.gen3.noDexSeen == true, "legendary (FRLG): ...the kind says so")
  meta.itemCommon, meta.itemRare = 0, 0
  solo:reset()

  -- The rest of the switch: the birds, Lugia / Ho-Oh, and the default.
  for _, row in ipairs({ { 146, "MUS_VS_LEGEND" }, { 151, "MUS_RS_VS_TRAINER" } }) do
    frGame()
    SESSION.party = { lead(70, { 45 }) }
    local f2 = { species = row[1], level = 50, legendary = true }
    local s2 = newSolo()
    check(offer(s2, standFor(f2, { wild = true, legendary = true }), f2, { wild = true, legendary = true }),
          "legendary song " .. row[1] .. ": taken")
    eq(screenedWith and screenedWith.song, row[2], "legendary (FRLG) " .. row[1] .. ": " .. row[2])
    s2:reset()
  end
end

-- (b) the endings that lose a legend when they are wrong
local function legendEnding(label, family, setup)
  if family == "rse" then emGame() else frGame() end
  local s = setup()
  local solo = newSolo()
  local result
  check(offer(solo, standFor(s.foe, s.opts), s.foe, {
    wild = true, legendary = true, song = s.song, done = function(r) result = r end,
  }), label .. ": taken")
  local ok, fight = drive(solo, s.choose)
  check(ok, label .. ": the fight ran to its end")
  return result, fight
end

do
  local result = legendEnding("Mewtwo WHIRLWIND (FRLG)", "frlg", function()
    SESSION.party = { lead(70, { 18 }) }
    return { foe = { species = 150, level = 70, legendary = true }, opts = { wild = true, legendary = true },
             choose = function(f) f:pickMove(1) end }
  end)
  eq(result, "teleport_player", "Mewtwo WHIRLWIND (FRLG): 'ran from', never the catch path")
  eq(SESSION.battleOutcome, 5, "Mewtwo WHIRLWIND (FRLG): B_OUTCOME_PLAYER_TELEPORTED (the script's RanFromMewtwo)")

  result = legendEnding("Mewtwo caught", "frlg", function()
    SESSION.party = { lead(70, { 45 }) }
    FakeBag.add(SESSION.bag, 1, 1)
    local thrown = false
    return { foe = { species = 150, level = 70, legendary = true }, opts = { wild = true, legendary = true },
             choose = function(f) if not thrown then thrown = true; throwBall(f) else f:pickMove(1) end end }
  end)
  eq(result, "caught", "Mewtwo caught: done('caught')")
  eq(SESSION.battleOutcome, 7, "Mewtwo caught: B_OUTCOME_CAUGHT")
  eq(SESSION.party[2] and SESSION.party[2].species, 150, "Mewtwo caught: in the party")

  result = legendEnding("Mewtwo ran", "frlg", function()
    SESSION.party = { lead(70, { 45 }) }
    return { foe = { species = 150, level = 70, legendary = true }, opts = { wild = true, legendary = true },
             choose = runAway }
  end)
  eq(result, "run", "Mewtwo ran: done('run')")
  eq(SESSION.battleOutcome, 4, "Mewtwo ran: B_OUTCOME_RAN")

  result = legendEnding("Mewtwo KO", "frlg", function()
    SESSION.party = { lead(100, { 300 }) }
    return { foe = { species = 150, level = 50, legendary = true }, opts = { wild = true, legendary = true },
             choose = function(f) f:pickMove(1) end }
  end)
  eq(result, "win", "Mewtwo KO: done('win') -- 'defeated'")
  eq(SESSION.battleOutcome, 1, "Mewtwo KO: B_OUTCOME_WON")
end

do
  -- Emerald's Mew: its TELEPORT is MON_TELEPORTED (10) -- FARAWAY ISLAND's
  -- script tests 10 and keeps the Mew; the start's own theme; "seen"; the
  -- fateful bit on the referee's sheet and on the monster caught.
  local result = legendEnding("Mew TELEPORT (EM)", "rse", function()
    SESSION.party = { lead(30, { 45 }) }
    return { foe = { species = 151, level = 30, legendary = true, moves = { 100 }, fatefulEncounter = true },
             opts = { wild = true, legendary = true }, song = 412,
             choose = function(f) f:pickMove(1) end }
  end)
  eq(result, "mon_teleported", "Mew TELEPORT (EM): done('mon_teleported')")
  eq(SESSION.battleOutcome, 10, "Mew TELEPORT (EM): B_OUTCOME_MON_TELEPORTED")
  eq(screenedWith and screenedWith.song, 412, "Mew (EM): the start's own theme (opts.song)")
  check(seenAt(151), "Mew (EM): Emerald's legends are seen (no LEGENDARY in its exclusion)")
  eq(createdWith and createdWith.sides.b[1].mons[1].fateful, true, "Mew (EM): the referee's sheet is fateful")

  -- ...and caught, it keeps the bit (obedience reads it).
  result = legendEnding("Mew caught (EM)", "rse", function()
    SESSION.party = { lead(30, { 45 }) }
    FakeBag.add(SESSION.bag, 1, 1)
    local thrown = false
    return { foe = { species = 151, level = 30, legendary = true, moves = { 45 }, fatefulEncounter = true },
             opts = { wild = true, legendary = true }, song = 412,
             choose = function(f) if not thrown then thrown = true; throwBall(f) else f:pickMove(1) end end }
  end)
  eq(result, "caught", "Mew caught (EM): done('caught')")
  eq(SESSION.party[2] and SESSION.party[2].fatefulEncounter, true, "Mew caught (EM): the fateful bit kept")
  -- The same TELEPORT on FireRed is PLAYER_TELEPORTED (the cart's rule, not the side's).
  result = legendEnding("Mew TELEPORT (FRLG)", "frlg", function()
    SESSION.party = { lead(30, { 45 }) }
    return { foe = { species = 151, level = 30, legendary = true, moves = { 100 } },
             opts = { wild = true, legendary = true }, choose = function(f) f:pickMove(1) end }
  end)
  eq(result, "teleport_player", "Mew TELEPORT (FRLG): PLAYER_TELEPORTED whoever used it")
end

-- ===================================================================
-- 4. scripted wilds
-- ===================================================================
do
  frGame()
  SESSION.party = { lead(100, { 300 }) }
  local meta = P3._speciesMeta[143]
  meta.itemCommon, meta.itemRare = 21, 21
  local foe = { species = 143, level = 30, wildScripted = true }
  local stand = standFor(foe, { wild = true, wildScripted = true })
  eq(stand and stand.kind3, "scripted", "scripted: the door's stand says scripted")
  local solo = newSolo()
  local result
  check(offer(solo, stand, foe, { wild = true, wildScripted = true, done = function(r) result = r end }),
        "scripted: taken")
  eq(createdWith and createdWith.wildPick, "cart", "scripted: the cart's wild move")
  eq(solo.wildMon and solo.wildMon.item, 21, "scripted: WILD_SCRIPTED rolls its held item (only LEGENDARY is spared)")
  check(seenAt(143), "scripted: seen")
  eq(screenedWith and screenedWith.song, nil, "scripted: the ordinary theme")
  drive(solo, function(f) f:pickMove(1) end)
  eq(result, "win", "scripted: done('win')")
  meta.itemCommon, meta.itemRare = 0, 0

  frGame()
  SESSION.party = { lead(70, { 45 }) }
  local s2 = newSolo()
  check(offer(s2, standFor(foe, { wild = true, wildScripted = true }), foe,
        { wild = true, wildScripted = true, done = function(r) result = r end }), "scripted: taken again")
  drive(s2, runAway)
  eq(result, "run", "scripted: ran from -- B_OUTCOME_RAN, the 'fought' branch of the script")

  frGame()
  SESSION.party = { lead(70, { 45 }) }
  FakeBag.add(SESSION.bag, 1, 1)
  local s3 = newSolo()
  check(offer(s3, standFor(foe, { wild = true, wildScripted = true }), foe,
        { wild = true, wildScripted = true, done = function(r) result = r end }), "scripted: taken to a catch")
  local thrown = false
  drive(s3, function(f) if not thrown then thrown = true; throwBall(f) else f:pickMove(1) end end)
  eq(result, "caught", "scripted: done('caught') -- the script's caught branch")
  eq(SESSION.battleOutcome, 7, "scripted: B_OUTCOME_CAUGHT")
end

-- ===================================================================
-- 5. the POKeMON TOWER ghosts
-- ===================================================================
do
  -- A tower floor without the SILPH SCOPE: veiled.
  frGame()
  SESSION.party = { lead(30, { 10 }) }
  FakeBag.add(SESSION.bag, 1, 1)
  local foe = { species = 92, level = 20 }
  local stand = standFor(foe, nil, "FR_POKEMON_TOWER_3F")
  eq(stand and stand.kind3, "ghost", "ghost: the tower floor's stand says ghost")
  eq(stand and stand.ghost3, "veiled", "ghost: ...veiled")
  local solo = newSolo()
  local result
  check(offer(solo, stand, foe, { done = function(r) result = r end }), "ghost: taken")
  eq(createdWith and createdWith.ghost, "veiled", "ghost: the referee's `ghost`")
  eq(screenedWith and screenedWith.ghost, "veiled", "ghost: the screen's `ghost`")
  check(not seenAt(92), "ghost: a veiled ghost is not seen (IS_BATTLE_TYPE_GHOST_WITHOUT_SCOPE)")
  local turn = 0
  local _, fight = drive(solo, function(f)
    turn = turn + 1
    if turn == 1 then f:pickMove(1)
    elseif turn == 2 then throwBall(f)
    else runAway(f) end
  end)
  eq(result, "run", "ghost: RUN always works -- done('run')")
  check(textOf(fight):find("too scared", 1, true) ~= nil, "ghost: the player's move is cancelled")
  check(textOf(fight):find("Get out", 1, true) ~= nil, "ghost: ...and the GHOST's")
  eq(FakeBag.get(SESSION.bag, 1), 0, "ghost: the dodged ball was spent")
  eq(#SESSION.party, 1, "ghost: ...and caught nothing")
end

-- The Marowak (StartMarowakBattle): its script reads VAR_RESULT FALSE only
-- on a win -- the engine's native sets it from outcome_to_code of the word
-- `done` is handed.
local function marowak(label, scope, party, choose)
  frGame()
  SESSION.party = party
  local native = {}
  native.done = function(result)
    native.result = result
    native.var = (FakeNatives.outcome_to_code(result) == 1) and 0 or 1
  end
  local foe = { species = 105, level = 30, ghost = true, ghostUnveiled = scope, wildScripted = true }
  if scope then
    foe.gender, foe.nature = "F", 12
    foe.ivs = { hp = 31, atk = 31, def = 31, spe = 31, spa = 31, spd = 31 }
  end
  local opts = { wild = true, wildScripted = true }
  local stand = standFor(foe, opts, "FR_POKEMON_TOWER_6F")
  local solo = newSolo()
  check(offer(solo, stand, foe, { wild = true, wildScripted = true, done = native.done }), label .. ": taken")
  local view = { create = createdWith, screen = screenedWith, stand = stand, seen = seenAt(105) }
  drive(solo, choose)
  return native, view
end

do
  local n, v = marowak("Marowak unveiled KO", true, { lead(100, { 300 }) }, function(f) f:pickMove(1) end)
  eq(v.stand and v.stand.ghost3, "unveiled", "Marowak (scope): the stand says unveiled")
  eq(v.create and v.create.ghost, "unveiled", "Marowak (scope): the referee's `ghost`")
  eq(v.screen and v.screen.ghost, "unveiled", "Marowak (scope): the screen's `ghost`")
  check(v.seen, "Marowak (scope): seen once the scope unveils it")
  eq(n.result, "win", "Marowak (scope) KO: done('win')")
  eq(n.var, 0, "Marowak (scope) KO: VAR_RESULT FALSE -- DefeatedMarowakGhost")

  n = marowak("Marowak unveiled ran", true, { lead(70, { 45 }) }, runAway)
  eq(n.result, "run", "Marowak (scope) ran: done('run')")
  eq(n.var, 1, "Marowak (scope) ran: VAR_RESULT TRUE -- pushed back from the stairs")

  local thrown = false
  n = marowak("Marowak unveiled ball", true, { lead(70, { 45 }) }, function(f)
    if not thrown then
      thrown = true
      FakeBag.add(SESSION.bag, 1, 1)
      throwBall(f)
    else
      runAway(f)
    end
  end)
  eq(#SESSION.party, 1, "Marowak (scope): the ball is dodged (it can't be caught)")
  eq(n.var, 1, "Marowak (scope): ...and RAN after it is TRUE")

  n, v = marowak("Marowak veiled", false, { lead(30, { 10 }) }, runAway)
  eq(v.create and v.create.ghost, "veiled", "Marowak (no scope): veiled")
  check(not v.seen, "Marowak (no scope): not seen")
  eq(n.result, "run", "Marowak (no scope): done('run')")
  eq(n.var, 1, "Marowak (no scope): VAR_RESULT TRUE")
end

-- ===================================================================
-- 6. the pure helpers
-- ===================================================================
do
  local byte = Legend.statusByte3
  eq(byte(nil), 0, "status byte: healthy is 0")
  eq(byte("PSN"), 8, "status byte: STATUS1_POISON")
  eq(byte("BRN"), 16, "status byte: STATUS1_BURN")
  eq(byte("FRZ"), 32, "status byte: STATUS1_FREEZE")
  eq(byte("PAR"), 64, "status byte: STATUS1_PARALYSIS")
  eq(byte("TOX"), 128, "status byte: STATUS1_TOXIC_POISON")
  eq(byte("SLP", 3), 3, "status byte: asleep, the counter in bits 0-2")
  eq(byte("SLP", 9), 7, "status byte: ...never past 7")
  eq(byte("SLP"), nil, "status byte: asleep with no counter is not made up")
  eq(byte(67), 67, "status byte: a byte stays a byte")
  local state = Legend.roamerState3({ hp = 12, status = "SLP" }, { hp = 99, status = "SLP", sleepTurns = 4 })
  eq(state.hp, 12, "roamer state: the engine monster's HP (written by the core)")
  eq(state.status, 4, "roamer state: the byte, with the referee's counter")
  eq(state.statusNum, 4, "roamer state: FireRed's statusNum the same")
  local unknown = Legend.roamerState3({ hp = 5, status = "SLP" }, { hp = 5, status = "SLP" })
  eq(unknown.status, "SLP", "roamer state: no counter anywhere -- the word, as the engine banks it")
  eq(unknown.statusNum, nil, "roamer state: ...and no byte")

  check(Legend.noDexSeen3("legendary", "frlg"), "dex: FRLG legendaries are not seen")
  check(not Legend.noDexSeen3("legendary", "rse"), "dex: Emerald's are")
  check(Legend.noDexSeen3("ghost", "frlg", "veiled"), "dex: a veiled ghost is not")
  check(not Legend.noDexSeen3("ghost", "frlg", "unveiled"), "dex: the scoped one is")
  check(not Legend.noDexSeen3("roamer", "frlg"), "dex: a roamer is seen")
  check(not Legend.noDexSeen3("scripted", "frlg"), "dex: a scripted wild is seen")

  eq(Legend.frlgLegendSong3(410), "MUS_VS_DEOXYS", "song: Deoxys")
  eq(Legend.frlgLegendSong3(249), "MUS_VS_LEGEND", "song: Lugia")
  eq(Legend.frlgLegendSong3(250), "MUS_VS_LEGEND", "song: Ho-Oh")
  eq(Legend.ghostOf3({ opts = { ghostUnveiled = true } }), "unveiled", "ghost: a start that says unveiled")
  eq(Legend.ghostOf3({ foe = { ghost = true } }), "veiled", "ghost: ...else veiled")
  eq(Legend.ghostOf3({ ghost3 = "unveiled" }), "unveiled", "ghost: the stand's word first")
end

Turn3.create, Mediated.new = realCreate, realNew

-- Nothing of Gen 1's engine was reached on a Gen 3 boot.
check(package.loaded["src.battle.BattleState"] == nil, "no Gen 1 BattleState on a Gen 3 boot")
check(not contains(warns, "ERROR"), "no error was logged: " .. table.concat(warns, " / "))
check(not contains(warns, "could not"), "no fallback warning fired: " .. table.concat(warns, " / "))
check(not contains(warns, "own rules failed"), "no kind hook threw: " .. table.concat(warns, " / "))

unstubAll()
T.finish("gen3_solo_legend")
