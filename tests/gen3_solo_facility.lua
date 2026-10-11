-- Headless Gen 3 solo facility fights (W2-K-FAC): src/Solo3/Facility.lua, the
-- `facility` kind of the solo kind registry (contract C2 of
-- docs/plans/gen3-solo-remaining-fights.md, research §1.4 / §2.5).
--
-- The shape tests/gen3_solo.lua set, and its harness copied as it stands: a
-- Gen 3 boot (the stub facade says generation 3) over the engine SDK's Gen 3
-- fixture (synthetic numbers), the engine modules that would need an
-- imported cache stood in by small fakes that record what they were asked,
-- and the engine's own *pure* modules run for real (the exp curve, the prize
-- formula, the game3 modal stack).  The referee is the real src/BattleSim3,
-- the screens the real MediatedBattle / CoopBattle, the core the real
-- src/SoloBattle.lua, and every fight comes in through the real door
-- (src/CoopField.lua's trainerStand3 / wildStand3, walked the way
-- src/Client.lua's offerFight3 walks it) -- so a fight here is the fight a
-- player gets in the Frontier, minus the pixels.
--
--   1. The module: found by name, its pure answers (the hall, the rules per
--      hall, the screen's prompts).
--   2. The hand-backs: the Palace and the Arena (the halls and the tents),
--      a Tower multi, the Pike's two-trainer double, a Pyramid floor whose
--      run rule cannot be read -- nothing built, nothing taken.
--   3. Each hall, through the referee: the Battle Tower (win, forfeit, loss,
--      draw, the interview record, the double), the Dome (its last moves,
--      Battle._nextFacility taken and put back), the Factory and the Pike
--      (their AI flags and rules), the Pike and Pyramid wilds (Pay Day kept,
--      the Pyramid's run rule, bag and Pickup), Trainer Hill (the item quirk),
--      FireRed's Trainer Tower and an Emerald Secret Base.
--
-- Legal: every species, move, trainer and item row below is either the SDK
-- fixture's or invented here with synthetic numbers; the only real values are
-- pret enum numbers the battle code branches on (VAR_LAST_TALKED, TRAINER_
-- SECRET_BASE, ITEM_* ids), the policy docs/plans/gen3-battle-sheet.md states.
--
-- Run from the engine checkout root:
--
--   luajit mods/rby_mmo/tests/gen3_solo_facility.lua

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
-- the facility suite's own stand-ins
-- ===================================================================

local FOE = "solo_foe"
local PLAYER = "solo_player"

-- The engine's whole outcome vocabulary (scripting/natives.lua).
local CODES = {
  win = 1, lose = 2, draw = 3, run = 4, teleport_player = 5, mon_fled = 6, fled = 6,
  caught = 7, no_safari_balls = 8, forfeited = 9, mon_teleported = 10,
}
FakeNatives.outcome_to_code = function(r) return CODES[r] or 1 end

-- The engine's battle module, as the harness stands it in: Battle._nextFacility
-- lives on it (rse/frontier/palace.lua startFacilityBattle).
local BattleMod = package.loaded["src.core.game3.battle"]

-- The script VM's context (VAR_LAST_TALKED is a special var, 0x800F) and the
-- engine's var reader.
FakeVm.ctx = { specialVars = {} }
FakeVm.store = { vars = {} }
function FakeFlags.getVar(store, ctx, id)
  id = tonumber(id) or 0
  if id >= 0x8000 then return (ctx and ctx.specialVars and ctx.specialVars[id]) or 0 end
  return (store and store.vars and store.vars[id]) or 0
end

-- The two rows of the cart's trainer book a hill opponent reads its items
-- from (rows 1 and 2; invented).
TRAINERS[1] = { class = 57, className = "HIKER", name = "SAWYER", pic = 5, gender = 0,
                encounterMusic = 0, lastLevel = 21, aiFlags = 1, items = { 21, 0, 0, 0 },
                party = { { species = 16, level = 21 } } }
TRAINERS[2] = { class = 57, className = "GRUNT", name = "GRUNT", pic = 5, gender = 0,
                encounterMusic = 0, lastLevel = 32, aiFlags = 1, items = { 13, 13, 0, 0 },
                party = { { species = 16, level = 32 } } }

-- The Trainer Hill floor's two trainers.
local HILL = { [1] = { name = "SAWYER" }, [2] = { name = "KEIKO" } }
local FakeHill = { VAR_LAST_TALKED = 0x800F }
function FakeHill.trainer(_, localId) return HILL[tonumber(localId)] end

-- The Battle Pyramid: its floor's run multiplier and its bag, which the
-- engine's Bag routes to while the player is in the Pyramid (bag.lua).
local PYR = { mult = 4, items = {}, qty = {}, active = false }
local FakePyramid = {}
function FakePyramid.runMultiplier() return PYR.mult end
function FakePyramid.bagLists() return PYR.items, PYR.qty end
function FakePyramid.bagCount(_, id)
  local n = 0
  for i = 1, #PYR.items do
    if PYR.items[i] == tonumber(id) then n = n + PYR.qty[i] end
  end
  return n
end
function FakePyramid.bagRemove(_, id, count)
  id, count = tonumber(id), tonumber(count) or 1
  for i = 1, #PYR.items do
    if PYR.items[i] == id and PYR.qty[i] >= count then
      PYR.qty[i] = PYR.qty[i] - count
      if PYR.qty[i] == 0 then PYR.items[i] = 0 end
      return true
    end
  end
  return false
end
do
  local get, remove = FakeBag.get, FakeBag.remove
  function FakeBag.get(bag, id)
    if PYR.active then return FakePyramid.bagCount(nil, id) end
    return get(bag, id)
  end
  function FakeBag.remove(bag, id, qty)
    if PYR.active then return FakePyramid.bagRemove(nil, id, qty) end
    return remove(bag, id, qty)
  end
end

-- A Secret Base owner's defeat words, by label, as the script cache holds them
-- (the engine's own rom_text, answering this one label besides its own --
-- battle/types.lua reads it at load).
local SB_LABEL = "SecretBase_Text_Trainer3Defeated"
local FakeSecretBase = { loseTextLabel = function() return SB_LABEL end }
local RomText = require("src.core.game3.rom_text")
local realHas, realPlain = RomText.has, RomText.plain
RomText.has = function(key, ...)
  if key == SB_LABEL then return true end
  return realHas(key, ...)
end
RomText.plain = function(key, ...)
  if key == SB_LABEL then return "Your base beat mine!" end
  return realPlain(key, ...)
end

-- The Frontier's save block, and the Battle Tower's interview (what it read).
local FakeFrontierUtil = {}
function FakeFrontierUtil.frontier(sess)
  if type(sess.frontier) ~= "table" then sess.frontier = {} end
  return sess.frontier
end
local interviews = {}
local FakeTower = {}
function FakeTower.setInterviewData(sess) interviews[#interviews + 1] = sess.lastFrontierBattle end

stub("src.core.game3.rse.frontier.pyramid", FakePyramid)
stub("src.core.game3.rse.trainer_hill", FakeHill)
stub("src.core.game3.rse.secret_base", FakeSecretBase)
stub("src.core.game3.rse.frontier.util", FakeFrontierUtil)
stub("src.core.game3.rse.frontier.tower", FakeTower)

-- Every Pickup the ending ran, and with which rules (the engine's own
-- Prize.pickup, recorded rather than rolled).
local pickups = {}
Prize.pickup = function(party, _, rules)
  pickups[#pickups + 1] = { party = party, rules = rules }
  return {}
end

local CoopField = need("CoopField")
local Turn3 = need("BattleSim3/Turn")
local CoopBattle = need("CoopBattle")

-- What the referee and the screens are built with, captured on the way.
local createdWith, screenedWith, doubledWith = nil, nil, nil
local realCreate, realNew, realDouble = Turn3.create, Mediated.new, CoopBattle.newSoloDouble
Turn3.create = function(o) createdWith = o; return realCreate(o) end
Mediated.new = function(o) screenedWith = o; return realNew(o) end
CoopBattle.newSoloDouble = function(game, o) doubledWith = o; return realDouble(game, o) end

local function emerald()
  PROFILE.family = "rse"
  PROFILE.rules.money, PROFILE.rules.lostText = "rse", "rse"
  PROFILE.rules.amuletCoinPlayerOnly = true
  PROFILE.rules.pickup = "level_bands"
end
local function fireRed()
  PROFILE.family = "frlg"
  PROFILE.rules.money, PROFILE.rules.lostText = "frlg", "frlg"
  PROFILE.rules.amuletCoinPlayerOnly = false
  PROFILE.rules.pickup = "flat"
end

local function fresh(cart)
  newGame()
  if cart == "frlg" then fireRed() else emerald() end
  createdWith, screenedWith, doubledWith = nil, nil, nil
  pickups, interviews = {}, {}
  PYR.mult, PYR.items, PYR.qty, PYR.active = 4, {}, {}, false
  FakeVm.ctx.specialVars = {}
  BattleMod._nextFacility = nil
end

local function countIn(list, needle)
  local n = 0
  for _, line in ipairs(list or {}) do
    if type(line) == "string" and line:find(needle, 1, true) then n = n + 1 end
  end
  return n
end
local function dropWarnsSince(mark)
  for i = #warns, mark + 1, -1 do warns[i] = nil end
end

-- Up to the command menu of a fight that has just been taken.
local function toMenu(solo)
  local f = solo.fight
  for _ = 1, 40 do
    f:update(2.0); solo:update(0.5, GAME)
    if f.phase == "choose" then break end
  end
  return f
end

local function strong(species, level, extra)
  local fields = { moves = { 300 }, pp = { 10 }, maxPp = { 10 } }
  for k, v in pairs(extra or {}) do fields[k] = v end
  return monOf(species, level, fields)
end

-- A Frontier trainer's foe record and start opts, as rse/frontier/tower.lua
-- Tower.startBattle hands them to BattleBridge.start (`battleOpts[kind] =
-- true`; the Battle Tower's kind also sets `battleTower`).
local function frontierFoe(party, name)
  return { party = party, trainerName = name or "ANABEL", trainerClass = 60,
           trainerClassName = "SALON MAIDEN", trainerPicId = 30, frontierTrainerId = 300,
           species = party[1].species, level = party[1].level }
end
local function startOpts(hall, extra)
  local o = {
    wild = false, frontier = true, aiFlags = 7, trainerItems = { 0, 0, 0, 0 }, scriptedLoss = true,
    trainerName = "ANABEL", trainerPicId = 30,
    defeatText = "ANABEL: Splendid!", victoryText = "ANABEL: Too bad!",
    frontierTrainer = { class = 60, className = "SALON MAIDEN", name = "ANABEL", pic = 30 },
  }
  o[hall] = true
  if hall == "tower" then o.battleTower = true end
  for k, v in pairs(extra or {}) do o[k] = v end
  return o
end

-- The door, the way src/Client.lua's offerFight3 walks it: CoopField's stand
-- for the start (solo listening), solo offered the stand's own monsters and
-- the stand itself, the stand's begin3 once solo took the fight, its
-- giveBack3 when nobody did.  The stand's own hand-back (`fightAlone`)
-- records the cart's start.
local function offerTrainer(solo, foe, opts)
  local stand, why = CoopField.trainerStand3(foe, opts, {
    solo = true, game = GAME,
    fightAlone = function() bridgeCalls[#bridgeCalls + 1] = { "cart", foe, opts } end,
  })
  if not stand then return false, nil, why end
  local o = {}
  for k, v in pairs(opts) do o[k] = v end
  o.done = opts.done or function() end
  o.fallback = function() stand:fightAlone() end
  o.party = stand.enemyParty
  o.stand3 = stand
  local taken = solo:fromGen3Trainer(GAME, foe, o) == true
  if taken then stand:begin3() else stand:giveBack3() end
  return taken, stand
end

local function offerWild(solo, enc, opts)
  local stand, why = CoopField.wildStand3(enc, {
    solo = true, game = GAME,
    fightAlone = function() bridgeCalls[#bridgeCalls + 1] = { "cartWild", enc, opts } end,
  }, opts)
  if not stand then return false, nil, why end
  local o = {}
  for k, v in pairs(opts) do o[k] = v end
  o.done = opts.done or function() end
  o.fallback = function() stand:fightAlone() end
  o.party = stand.enemyParty
  o.stand3 = stand
  local withMon = {}
  for k, v in pairs(enc) do withMon[k] = v end
  withMon.mon = stand.enemyParty[1]
  local taken = solo:fromGen3Encounter(GAME, withMon, o) == true
  if taken then stand:begin3() else stand:giveBack3() end
  return taken, stand
end

local function seenSpecies(species)
  for _, s in ipairs(FakeDex.seen) do
    if s.species == species then return true end
  end
  return false
end

-- ===================================================================
-- 1. the module
-- ===================================================================

local Facility = need("Solo3/Facility")
check(type(Facility) == "table" and type(Facility.kinds3) == "table"
      and type(Facility.kinds3.facility) == "table", "module: Solo3/Facility returns its kinds3")

do
  -- Found by name the first time a fight asks (SoloBattle.KIND_FILES3), once
  -- the file is there to read.
  stubMod.read = function(_, path)
    local h = io.open(MOD_PATH .. "/" .. path, "rb")
    if not h then return nil end
    local body = h:read("*a")
    h:close()
    return body
  end
  local kind = Solo.kind3("facility")
  stubMod.read = nil
  eq(Solo.KIND_FILES3.facility, "Solo3/Facility", "module: the registry names this file")
  eq(kind, Facility.kinds3.facility, "module: ...and finds the facility kind in it")
  for _, hook in ipairs({ "takes", "screen", "seat", "brains", "choose", "note", "settle", "word",
                          "finish", "handBack" }) do
    eq(type(kind and kind[hook]), "function", "module: the kind has its " .. hook .. " hook")
  end
end

do
  local H = Facility.hallOf
  eq(H({ facility3 = "dome", opts = { pike = true } }), "dome", "hall: the stand's word first")
  eq(H({ opts = { pike = true, battleTower = true, frontier = true } }), "pike",
     "hall: a Pike single (BATTLE_TOWER type on the cart) is the Pike")
  eq(H({ opts = { frontier = true, battleTower = true, tower = true } }), "tower", "hall: the Battle Tower")
  eq(H({ opts = { frontier = true } }), "tower", "hall: the Frontier's plain rules are the Tower's")
  eq(H({ opts = { trainerHill = true } }), "hill", "hall: Trainer Hill")
  eq(H({ opts = { trainerTower = true } }), "trainerTower", "hall: the Trainer Tower")
  eq(H({ opts = { secretBase = true } }), "secretBase", "hall: a Secret Base")
  eq(H({ foe = { kinds = { factory = true } } }), "factory", "hall: ...read off a kinds table too")
  eq(H({ opts = {} }), nil, "hall: none")

  local R = Facility.rulesFor
  local function same(a, b, label)
    local keys = {}
    for k in pairs(a or {}) do keys[k] = true end
    for k in pairs(b or {}) do keys[k] = true end
    for k in pairs(keys) do
      local x, y = (a or {})[k], (b or {})[k]
      if type(x) == "table" and type(y) == "table" then
        same(x, y, label .. "." .. k)
      else
        eq(x, y, label .. ": " .. k)
      end
    end
  end
  local frontier = { exp = false, boosts = false, obedience = false, theft = "foe", soulDew = false }
  for _, hall in ipairs({ "tower", "dome", "factory", "pike" }) do
    local want = { bag = false, forfeit = true }
    for k, v in pairs(frontier) do want[k] = v end
    same(R(hall, "trainer"), want, "rules (" .. hall .. " trainer)")
  end
  local pikeWild = { bag = false }
  for k, v in pairs(frontier) do pikeWild[k] = v end
  same(R("pike", "wild"), pikeWild, "rules (Pike wild): no forfeit -- a wild RUN stays a RUN")
  local pyramid = { pyramidBag = true, pyramidRun = 4, forfeit = true }
  for k, v in pairs(frontier) do pyramid[k] = v end
  PYR.mult = 4
  same(R("pyramid", "trainer"), pyramid, "rules (Pyramid trainer): its own bag, its run rule")
  same(R("hill", "trainer"), { exp = false, theft = "none", forfeit = true },
       "rules (Trainer Hill): the bag and the badges stay; no EXP, no theft, RUN forfeits")
  same(R("trainerTower", "trainer"), { exp = false, theft = "none" },
       "rules (Trainer Tower): no EXP, no theft, RUN refused like any trainer's (no forfeit)")
  same(R("secretBase", "trainer"), { boosts = { damage = false }, theft = "foe" },
       "rules (Secret Base): EXP, the bag; the stat badge boosts off, the speed one on; the foe steals")
  PYR.mult = nil
  local none, why = R("pyramid", "wild")
  eq(none, nil, "rules (Pyramid): a floor whose run rule cannot be read seats nothing")
  check(type(why) == "string", "rules (Pyramid): ...and says why")
  PYR.mult = 4

  local S = Facility.screenRules3
  same(S(R("tower", "trainer")), { bag = false, forfeit = true }, "screen: the Frontier's prompts")
  same(S(R("hill", "trainer")), { forfeit = true }, "screen: Trainer Hill's (the bag is open)")
  eq(S(R("trainerTower", "trainer")), nil, "screen: the Trainer Tower changes neither")
  eq(S(R("secretBase", "trainer")), nil, "screen: nor does a Secret Base")
end

-- ===================================================================
-- 2. the hand-backs
-- ===================================================================

do
  -- The Palace and the Arena (and Verdanturf's / Fallarbor's tents, which the
  -- engine starts as those halls): wave 3's rules, the cart's fight for now.
  for _, hall in ipairs({ "palace", "arena" }) do
    fresh()
    SESSION.party = { monOf(4, 30), monOf(5, 30) }
    local rulesObj = { kind = hall }
    BattleMod._nextFacility = rulesObj
    local solo = newSolo()
    local taken, stand = offerTrainer(solo, frontierFoe({ monOf(16, 30) }), startOpts(hall))
    eq(taken, false, "hand-back: a Battle " .. hall .. " fight is the cart's")
    eq(stand and stand.facility3, hall, "hand-back: ...the door named the hall")
    eq(solo:isRunning(), false, "hand-back (" .. hall .. "): nothing is running")
    eq(Stack.depth(), 0, "hand-back (" .. hall .. "): nothing went onto the stack")
    eq(rawget(BattleMod, "_nextFacility"), rulesObj,
       "hand-back (" .. hall .. "): the hall's rules object is still there for the cart's start")
  end

  -- A Battle Tower multi: a partner and two trainers.
  fresh()
  local mine = { monOf(4, 30), monOf(5, 30) }
  local partnerMons = { monOf(29, 30), monOf(151, 30) }
  SESSION.party = { mine[1], mine[2], partnerMons[1], partnerMons[2] }
  local solo = newSolo()
  local taken = offerTrainer(solo, frontierFoe({ monOf(16, 30), monOf(16, 31), monOf(16, 32), monOf(16, 33) }),
    startOpts("tower", { double = true, partner = true, playerHalf = 2, twoOpponents = true,
                         frontierPartner = 9, partnerName = "LUCY", partnerPicId = 4,
                         frontierFoeHalf = 2, frontierOpponentB = 12,
                         frontierTrainerB = { class = 61, className = "EXPERT", name = "OWEN", pic = 31 } }))
  eq(taken, false, "hand-back: a Battle Tower multi is the cart's (the partner work comes later)")
  eq(#SESSION.party, 4, "hand-back (multi): the partner's monsters are back on the party")
  eq(SESSION.party[3], partnerMons[1], "hand-back (multi): ...in their place")
  eq(solo:isRunning(), false, "hand-back (multi): nothing is running")

  -- The Pike's two-trainer double.
  fresh()
  SESSION.party = { monOf(4, 30), monOf(5, 30) }
  solo = newSolo()
  taken = offerTrainer(solo, frontierFoe({ monOf(16, 30), monOf(16, 31) }),
    startOpts("pike", { double = true, twoOpponents = true, frontierFoeHalf = 1, frontierOpponentB = 12,
                        frontierTrainerB = { class = 61, className = "EXPERT", name = "OWEN", pic = 31 },
                        defeatTextB = "OWEN: Hmm." }))
  eq(taken, false, "hand-back: the Pike's two-trainer double is the cart's (the pair work comes later)")
  eq(solo:isRunning(), false, "hand-back (Pike double): nothing is running")

  -- A Pyramid floor whose run rule cannot be read.
  fresh()
  SESSION.party = { monOf(4, 30) }
  PYR.mult = nil
  local mark = #warns
  solo = newSolo()
  taken = offerWild(solo, monOf(16, 20), { pyramid = true, frontier = true, scriptedLoss = true })
  eq(taken, false, "hand-back: a Pyramid wild with no run multiplier is the cart's")
  check(countIn(warns, "run multiplier") == 1, "hand-back (Pyramid): ...said once, with a remedy")
  dropWarnsSince(mark)
  eq(#bridgeCalls, 0, "hand-backs: nothing was started in their place here (the caller starts the cart's)")
end

-- ===================================================================
-- 3. the halls
-- ===================================================================

-- (a) the Battle Tower: a single won ------------------------------------
do
  fresh()
  local lead = monOf(4, 60, { moves = { 6 }, pp = { 20 }, maxPp = { 20 } })
  SESSION.party = { lead, monOf(5, 50) }
  SESSION.money = 1000
  FakeBag.add(SESSION.bag, 21, 2)
  local expBefore = lead.exp
  local results = {}
  local stale = { opponentSpecies = 999, playerSpecies = 998, playerNickname = "STALE" }
  local opts = startOpts("tower", { done = function(r)
    results[#results + 1] = r
    -- rse/frontier/tower.lua Tower.startBattle's own `done`: the record
    -- rebuilt from the engine's battle state, then the battle room's script
    -- runs on to tower_setinterviewdata in the same tick.
    SESSION.lastFrontierBattle = stale
    FakeTower.setInterviewData(SESSION)
  end })
  local solo = newSolo()
  local taken, stand = offerTrainer(solo, frontierFoe({ monOf(16, 2), monOf(16, 2) }), opts)
  check(taken, "tower: a Battle Tower single is taken (" .. table.concat(warns, " / ") .. ")")
  eq(stand and stand.kind3, "facility", "tower: the door says facility")
  eq(solo.gen3 and solo.gen3.facility3, "tower", "tower: ...the Battle Tower")
  local r = createdWith and createdWith.rules or {}
  eq(r.bag, false, "tower rules: no bag")
  eq(r.forfeit, true, "tower rules: RUN forfeits")
  eq(r.exp, false, "tower rules: no EXP")
  eq(r.boosts, false, "tower rules: no badge boosts")
  eq(r.obedience, false, "tower rules: no disobedience")
  eq(r.theft, "foe", "tower rules: the foe may steal")
  eq(r.soulDew, false, "tower rules: SOUL DEW inert")
  local nr = solo.sim and solo.sim.rules or {}
  check(nr.noBag and nr.forfeit and nr.noExp and nr.noDamageBoost and nr.noSpeedBoost
        and nr.noObedience and nr.noSoulDew and nr.theft == "foe",
        "tower rules: ...and the referee plays by them")
  eq(screenedWith and screenedWith.rules and screenedWith.rules.bag, false, "tower screen: BAG refused")
  eq(screenedWith and screenedWith.rules and screenedWith.rules.forfeit, true, "tower screen: RUN asks to forfeit")
  eq(solo.fight and solo.fight.rules and solo.fight.rules.forfeit, true, "tower screen: ...the screen took them")
  local brain = solo.gen3 and solo.gen3.npcs and solo.gen3.npcs[FOE]
  check(type(brain) == "table" and brain.noItems == true, "tower brain: the trainer uses no items")
  eq(brain and brain.aiFlags, 7, "tower brain: the facility's AI scripts")
  eq(solo.gen3 and solo.gen3.trainer and solo.gen3.trainer.trainerName, "ANABEL", "tower: the facility's trainer")
  check(not seenSpecies(16), "tower: no dex 'seen' for a Frontier foe")
  eq(solo.sim.byId[PLAYER].bag and solo.sim.byId[PLAYER].bag[21], 2, "tower: the bag rode along...")
  eq(solo.sim:submitChoice(PLAYER, { action = "item", item = "21", slot = 0 }), false,
     "tower: ...and the referee refuses it (FRONTIER_NO_PYRAMID)")
  local _, fight = drive(solo, function(f) f:pickMove(1) end)
  eq(table.concat(results, ","), "win", "tower: done('win'), once")
  eq(SESSION.battleOutcome, 1, "tower: B_OUTCOME_WON")
  eq(SESSION.money, 1000, "tower: no prize, and PAY DAY's coins are not paid")
  check(not textOf(fight):find("picked up", 1, true), "tower: ...nor said")
  eq(lead.exp, expBefore, "tower: no EXP")
  eq(#pickups, 0, "tower: no Pickup")
  check(textOf(fight):find("STRINGID_PLAYERDEFEATEDTRAINER1", 1, true) ~= nil, "tower: 'PLAYER defeated ...!'")
  check(textOf(fight):find("ANABEL: Splendid!", 1, true) ~= nil, "tower: ...and the trainer's defeat words")
  check(not textOf(fight):find("STRINGID_PLAYERGOTMONEY", 1, true), "tower: no money line")
  eq(SESSION.frontier and SESSION.frontier.disableRecordBattle, 1, "tower: the battle cannot be recorded")
  local lfb = SESSION.lastFrontierBattle
  check(lfb ~= stale, "tower: lastFrontierBattle is the mod's fight, not the engine's stale one")
  eq(lfb and lfb.playerSpecies, 4, "tower: ...the player's battler")
  eq(lfb and lfb.opponentSpecies, 16, "tower: ...the foe's")
  eq(lfb and lfb.playerNickname, "CHARMANDER", "tower: ...and its name")
  eq(#interviews, 2, "tower: the interview was asked again after the script's own")
  eq(interviews[2], lfb, "tower: ...over this fight's record")
  check(not textOf(fight):find("STRINGID_PLAYERWHITEOUT", 1, true), "tower: no whiteout lines")
end

-- (b) the Battle Tower: a forfeit ---------------------------------------
do
  fresh()
  local lead = monOf(4, 30)
  SESSION.party = { lead }
  SESSION.money = 500
  local result
  local solo = newSolo()
  check(offerTrainer(solo, frontierFoe({ monOf(16, 30) }), startOpts("tower", {
    done = function(r) result = r end })), "forfeit: taken")
  local f = toMenu(solo)
  f:sendChoice({ action = "run" })
  local _, fight = drive(solo, function(fx) fx:pickMove(1) end)
  eq(result, "forfeited", "forfeit: done('forfeited')")
  eq(SESSION.battleOutcome, 9, "forfeit: B_OUTCOME_FORFEITED")
  eq(#fieldCalls, 0, "forfeit: no whiteout")
  eq(SESSION.money, 500, "forfeit: nothing paid or lost")
  check(textOf(fight):find("forfeited the match", 1, true) ~= nil, "forfeit: 'PLAYER forfeited the match!'")
  check(not textOf(fight):find("ANABEL: Too bad!", 1, true), "forfeit: no win words from the trainer")
  check(not textOf(fight):find("STRINGID_PLAYERWHITEOUT", 1, true), "forfeit: no whiteout lines")
  eq(SESSION.frontier and SESSION.frontier.disableRecordBattle, 1, "forfeit: not recordable either")
end

-- (c) the Battle Tower: a loss and a draw ---------------------------------
do
  fresh()
  local lead = monOf(4, 5, { moves = { 10 }, pp = { 35 }, maxPp = { 35 }, hp = 3 })
  SESSION.party = { lead }
  SESSION.money = 500
  local result
  FakeVm.running = true
  local solo = newSolo()
  check(offerTrainer(solo, frontierFoe({ strong(151, 70) }), startOpts("tower", {
    done = function(r) result = r end })), "loss: taken")
  local _, fight = drive(solo, function(f) f:pickMove(1) end)
  eq(result, "lose", "loss: done('lose')")
  eq(SESSION.battleOutcome, 2, "loss: B_OUTCOME_LOST")
  eq(#fieldCalls, 0, "loss: no whiteout warp (the script decides)")
  eq(SESSION.money, 500, "loss: no money lost")
  eq(lead.hp, 0, "loss: no heal")
  eq(FakeVm.halted, 0, "loss: the waiting script is answered, never halted")
  check(textOf(fight):find("ANABEL: Too bad!", 1, true) ~= nil, "loss: the trainer's win words")
  check(not textOf(fight):find("STRINGID_PLAYERWHITEOUT", 1, true), "loss: no whiteout lines")
  check(not textOf(fight):find("STRINGID_PLAYERLOSTAGAINSTENEMYTRAINER", 1, true), "loss: ...of either cart")
  FakeVm.running = false

  fresh()
  SESSION.party = { monOf(4, 30) }
  FakeVm.running = true
  local dr
  local d = newSolo()
  check(offerTrainer(d, frontierFoe({ monOf(16, 30) }), startOpts("tower", {
    done = function(r) dr = r end })), "draw: taken")
  d.sim:_finish("draw", nil, nil, "ko", "ko", nil)
  local _, df = drive(d, function(f) f:pickMove(1) end)
  eq(dr, "draw", "draw: done('draw') -- a facility's caller is a native, not the trainerbattle opcode")
  eq(SESSION.battleOutcome, 3, "draw: B_OUTCOME_DREW")
  eq(FakeVm.halted, 0, "draw: nothing halted")
  check(textOf(df):find("ANABEL: Too bad!", 1, true) ~= nil, "draw: the trainer's win words (not the Dome)")
  FakeVm.running = false
end

-- (d) the Battle Tower: a double, on CoopBattle's real screen -------------
do
  local say = CoopBattle.say
  CoopBattle.say = function(self_, text)
    self_.textLog = self_.textLog or {}
    self_.textLog[#self_.textLog + 1] = tostring(text)
    return say(self_, text)
  end
  local function keyInput(key)
    return { pressed = {}, wasPressed = function(_, k) return key ~= nil and k == key end,
             isDown = function() return false end }
  end
  fresh()
  local a, b = strong(4, 50), strong(5, 50)
  SESSION.party = { a, b }
  local result
  local solo = newSolo()
  local taken = offerTrainer(solo, frontierFoe({ monOf(16, 30), monOf(16, 30), monOf(29, 30), monOf(29, 30) }),
    startOpts("tower", { double = true, done = function(r) result = r end }))
  check(taken, "double: a Battle Tower double is taken (" .. table.concat(warns, " / ") .. ")")
  local fight = solo.fight
  check(fight and fight.soloDouble, "double: on CoopBattle's solo double screen")
  eq(solo.gen3 and solo.gen3.screen, "double", "double: the kind was told it is a double")
  eq(doubledWith and doubledWith.rules and doubledWith.rules.forfeit, true, "double: the screen asks to forfeit")
  eq(doubledWith and doubledWith.rules and doubledWith.rules.bag, false, "double: ...and refuses the bag")
  eq(fight and fight.rules3 and fight.rules3.forfeit, true, "double: ...and keeps them")
  eq(#solo.sim:seatsOf(PLAYER), 2, "double: two player seats")
  eq(#solo.sim:seatsOf(FOE), 2, "double: two trainer seats over one party")
  local brain = solo.gen3.npcs[FOE]
  check(type(brain) == "table" and brain.noItems == true and brain.owner == nil,
        "double: one facility brain answers both of the trainer's seats")
  -- Both of the player's seats forfeit (the screen's YES files `run` with its seat).
  check(solo:_choose({ action = "run", seat = 0 }), "double: seat 1's forfeit is filed")
  check(solo:_choose({ action = "run", seat = 1 }), "double: seat 2's too")
  solo:update(0.5, GAME)
  local o = solo.sim:outcome()
  eq(o and o.how, "forfeit", "double: the referee ends it as a forfeit")
  for _ = 1, 3000 do
    if not solo.fight then break end
    solo:update(1 / 60, GAME)
    local f = solo.fight
    if not f then break end
    GAME.input = keyInput((not f:boxLive()) and "a" or nil)
    f:update(1 / 60)
    GAME.input = keyInput(nil)
  end
  check(solo.fight == nil, "double: the fight ended and was let go")
  eq(result, "forfeited", "double: done('forfeited')")

  -- Won through the real screen, driven by key presses (tests/gen3_solo.lua's
  -- frame): the Frontier's after-words with the trainer slid back in, no EXP,
  -- no prize, and the referee's HP on the live party.
  local function frame(s)
    local f = s.fight
    if not f then return false end
    local key
    local menu = (f.phase == "choose" or f.phase == "move" or f.phase == "target")
    if (menu or f.replacing) and not f:boxLive() then
      key = "a"
      if f.phase == "target" then
        local p = f:targetChoices()[f.targetIndex or 1]
        if p and not f:foeSide(p.index) then key = "down" end
      end
    end
    GAME.input = keyInput(key)
    f:update(key and (1 / 60) or 1.0)
    GAME.input = keyInput(nil)
    return true
  end
  fresh()
  local a2, b2 = strong(4, 60), strong(5, 60)
  SESSION.party = { a2, b2 }
  SESSION.money = 800
  local expA, expB = a2.exp, b2.exp
  local won
  local w = newSolo()
  check(offerTrainer(w, frontierFoe({ monOf(16, 5), monOf(16, 5), monOf(29, 5), monOf(29, 5) }),
    startOpts("tower", { double = true, done = function(r) won = r end })), "double win: taken")
  local screen = w.fight
  local sim = w.sim
  for _ = 1, 6000 do
    if not w.fight then break end
    w:update(1 / 60, GAME)
    if not frame(w) then break end
  end
  check(w.fight == nil, "double win: the fight ended and was let go")
  eq(won, "win", "double win: done('win')")
  local log = table.concat(screen and screen.textLog or {}, " | ")
  check(log:find("STRINGID_PLAYERDEFEATEDTRAINER1", 1, true) ~= nil, "double win: 'PLAYER defeated ...!'")
  check(log:find("ANABEL: Splendid!", 1, true) ~= nil, "double win: ...the trainer's defeat words")
  eq(a2.exp, expA, "double win: no EXP (seat 1)")
  eq(b2.exp, expB, "double win: no EXP (seat 2)")
  eq(SESSION.money, 800, "double win: no prize")
  eq(a2.hp, sim.byId[PLAYER].mons[1].hp, "double win: seat 1's monster ends on the referee's HP")
  eq(b2.hp, sim.byId[PLAYER].mons[2].hp, "double win: seat 2's too")
  check(type(SESSION.lastFrontierBattle) == "table" and SESSION.lastFrontierBattle.playerSpecies == 4,
        "double win: the Frontier record names the first battler")
end

-- (e) the Battle Dome: its last moves, and Battle._nextFacility -----------
do
  fresh()
  SESSION.party = { monOf(151, 50, { moves = { 10 }, pp = { 35 }, maxPp = { 35 } }) }
  local rulesObj = { kind = "dome" }
  BattleMod._nextFacility = rulesObj
  local result
  local solo = newSolo()
  local taken, stand = offerTrainer(solo, frontierFoe({ monOf(16, 30, { moves = { 33 }, pp = { 35 },
    maxPp = { 35 } }) }), startOpts("dome", { done = function(r) result = r end }))
  check(taken, "dome: a Dome fight is taken")
  eq(stand and stand.nextFacility3, rulesObj, "dome: the stand recorded the Dome's rules object")
  eq(rawget(BattleMod, "_nextFacility"), nil, "dome: ...and none is left for the next engine fight")
  drive(solo, function(f) f:pickMove(1) end)
  eq(result, "win", "dome: won")
  local lm = SESSION.frontierDomeLastMoves
  eq(lm and lm.player, 10, "dome: the player's last move (SCRATCH)")
  eq(lm and lm.opponent, 33, "dome: the foe's last move (TACKLE)")
  eq(lm and lm.outcome, "win", "dome: ...and the outcome")
  eq(rawget(BattleMod, "_nextFacility"), nil, "dome: a fight that ended keeps nothing for the engine")

  -- A draw: the outcome word, and no words (BattleScript_CheckDomeDrew).
  fresh()
  SESSION.party = { monOf(4, 30) }
  local dsolo = newSolo()
  check(offerTrainer(dsolo, frontierFoe({ monOf(16, 30) }), startOpts("dome")), "dome draw: taken")
  dsolo.sim:_finish("draw", nil, nil, "ko", "ko", nil)
  local _, df = drive(dsolo, function(f) f:pickMove(1) end)
  eq(SESSION.frontierDomeLastMoves and SESSION.frontierDomeLastMoves.outcome, "draw", "dome draw: 'draw'")
  check(not textOf(df):find("ANABEL: Too bad!", 1, true), "dome draw: no win words")

  -- Handed back: the rules object is the cart's battle's again.
  fresh()
  SESSION.party = { monOf(4, 30) }
  BattleMod._nextFacility = rulesObj
  local hsolo = newSolo()
  check(offerTrainer(hsolo, frontierFoe({ monOf(16, 30) }), startOpts("dome")), "dome hand-back: taken")
  eq(rawget(BattleMod, "_nextFacility"), nil, "dome hand-back: taken off the engine")
  hsolo:reset()
  eq(rawget(BattleMod, "_nextFacility"), rulesObj, "dome hand-back: put back for the cart's start")
  eq(bridgeCalls[#bridgeCalls] and bridgeCalls[#bridgeCalls][1], "cart", "dome hand-back: the cart's own start ran")

  -- ...and with no stand behind the fight: this file takes it and puts it back.
  fresh()
  SESSION.party = { monOf(4, 30) }
  BattleMod._nextFacility = rulesObj
  local nsolo = newSolo()
  local foe = frontierFoe({ monOf(16, 30) })
  check(nsolo:fromGen3Trainer(GAME, foe, startOpts("dome")), "dome (no stand): taken by its keys")
  eq(nsolo.gen3 and nsolo.gen3.facility3, "dome", "dome (no stand): the hall read off the opts")
  eq(nsolo.gen3 and nsolo.gen3.trainer and nsolo.gen3.trainer.trainerName, "ANABEL",
     "dome (no stand): the trainer read off the start")
  eq(nsolo.gen3 and nsolo.gen3.party and nsolo.gen3.party[1], foe.party[1],
     "dome (no stand): the facility's own monsters, as built")
  eq(rawget(BattleMod, "_nextFacility"), nil, "dome (no stand): taken off the engine")
  nsolo:reset()
  eq(rawget(BattleMod, "_nextFacility"), rulesObj, "dome (no stand): put back on the hand-back")
  eq(bridgeCalls[#bridgeCalls] and bridgeCalls[#bridgeCalls][1], "start",
     "dome (no stand): the core started the cart's battle")
  eq(bridgeCalls[#bridgeCalls] and bridgeCalls[#bridgeCalls][3].dome, true, "dome (no stand): ...the Dome's")
  BattleMod._nextFacility = nil
end

-- (f) the Battle Factory and the Pike: their AI flags and rules -----------
do
  fresh()
  SESSION.party = { monOf(4, 30) }
  local solo = newSolo()
  check(offerTrainer(solo, frontierFoe({ monOf(16, 30) }), startOpts("factory", { aiFlags = 3 })),
        "factory: taken")
  eq(solo.gen3.npcs[FOE].aiFlags, 3, "factory: the challenge's own AI flags (GetAiScriptsInBattleFactory)")
  eq(createdWith.rules.forfeit, true, "factory: RUN forfeits")
  solo:reset()

  fresh()
  SESSION.party = { monOf(4, 30) }
  solo = newSolo()
  check(offerTrainer(solo, frontierFoe({ monOf(16, 30) }), startOpts("pike", { battleTower = true })),
        "pike: a Pike single is taken")
  eq(solo.gen3.facility3, "pike", "pike: ...as the Pike")
  eq(createdWith.rules.bag, false, "pike: no bag")
  eq(solo.gen3.noPickup, true, "pike: no Pickup")
  solo:reset()
end

-- (g) the Battle Pike's wild ------------------------------------------------
do
  fresh()
  local lead = monOf(4, 60, { moves = { 6 }, pp = { 20 }, maxPp = { 20 }, status = "PSN" })
  lead.hp = lead.maxHp - 20
  local startHp = lead.hp
  SESSION.party = { lead }
  SESSION.money = 100
  local expBefore = lead.exp
  local result
  local solo = newSolo()
  local taken, stand = offerWild(solo, monOf(16, 5), { pike = true, frontier = true, scriptedLoss = true,
    done = function(r) result = r end })
  check(taken, "pike wild: taken")
  local sheet = solo.sim.byId[PLAYER].mons[1]
  eq(stand and stand.facility3, "pike", "pike wild: the Pike's")
  local r = createdWith.rules
  eq(r.bag, false, "pike wild: no bag")
  eq(r.forfeit, nil, "pike wild: RUN stays a RUN")
  eq(r.exp, false, "pike wild: no EXP")
  eq(createdWith.wildPick, "cart", "pike wild: the cart's random wild move")
  eq(screenedWith.rules and screenedWith.rules.bag, false, "pike wild screen: BAG refused")
  eq(screenedWith.rules and screenedWith.rules.forfeit, nil, "pike wild screen: no forfeit question")
  check(not seenSpecies(16), "pike wild: no dex 'seen'")
  local _, fight = drive(solo, function(f) f:pickMove(1) end)
  eq(result, "win", "pike wild: done('win')")
  check(SESSION.money > 100, "pike wild: PAY DAY pays (BattleScript_PayDayMoneyAndPickUpItems)")
  check(textOf(fight):find("picked up", 1, true) ~= nil or (fight.payDayPaid or 0) > 0,
        "pike wild: ...and is said")
  eq(#pickups, 0, "pike wild: no Pickup in the Pike")
  eq(lead.exp, expBefore, "pike wild: no EXP")
  eq(lead.hp, sheet.hp, "pike wild: the party ends on the referee's HP (carried to the next room)")
  check(lead.hp > 0 and lead.hp <= startHp, "pike wild: ...the damage the fight left, not a heal")
  eq(lead.status, "PSN", "pike wild: ...and its status")
  eq(lead.pp[1], sheet.moves[1].pp, "pike wild: ...and its PP")
  eq(SESSION.frontier and SESSION.frontier.disableRecordBattle, 1, "pike wild: not recordable")
  eq(SESSION.lastFrontierBattle, nil, "pike wild: the interview record is a trainer fight's only")

  -- A loss: the whiteout lines, no warp, no heal.
  fresh()
  local weak = monOf(4, 5, { moves = { 10 }, pp = { 35 }, maxPp = { 35 }, hp = 3 })
  SESSION.party = { weak }
  local lr
  local l = newSolo()
  check(offerWild(l, strong(151, 70), { pike = true, frontier = true, scriptedLoss = true,
    done = function(r2) lr = r2 end }), "pike wild loss: taken")
  local _, lf = drive(l, function(f) f:pickMove(1) end)
  eq(lr, "lose", "pike wild loss: done('lose')")
  eq(#fieldCalls, 0, "pike wild loss: no whiteout warp (CB2_EndWildBattle's Pike arm)")
  eq(weak.hp, 0, "pike wild loss: no heal")
  check(textOf(lf):find("STRINGID_PLAYERWHITEOUT", 1, true) ~= nil,
        "pike wild loss: the cart's whiteout lines (BattleScript_LocalBattleLost, not a TRAINER)")
end

-- (h) the Battle Pyramid: a wild, its bag, its Pickup -------------------------
do
  fresh()
  local lead = monOf(4, 60, { moves = { 10 }, pp = { 35 }, maxPp = { 35 } })
  lead.hp = lead.maxHp - 30
  SESSION.party = { lead }
  FakeBag.add(SESSION.bag, 21, 5)
  PYR.items, PYR.qty = { 21, 13, 0 }, { 2, 1, 0 }
  PYR.active = true
  local result
  local solo = newSolo()
  local taken = offerWild(solo, monOf(16, 30), { pyramid = true, frontier = true, scriptedLoss = true,
    done = function(r) result = r end })
  check(taken, "pyramid: a Pyramid wild is taken")
  local r = createdWith.rules
  eq(r.pyramidRun, 4, "pyramid: the floor's run multiplier")
  eq(r.pyramidBag, true, "pyramid: the Pyramid bag")
  eq(r.bag, nil, "pyramid: ...which is open")
  local bag = solo.sim.byId[PLAYER].bag
  eq(bag[21], 2, "pyramid: side a's bag is the Pyramid's (2 HYPER POTION)")
  eq(bag[13], 1, "pyramid: ...(1 POTION)")
  eq(solo.fight.bagSheet[21], 2, "pyramid: the item menu lists the Pyramid bag, not the 5 in the pockets")
  eq(solo.sim.rules.pyramidRun, 4, "pyramid: the referee runs by the floor's multiplier")
  local used = false
  drive(solo, function(f)
    if not used then
      used = true
      f.itemPick = { id = 21, effect = Sheet3.itemEffect(21) }
      f:commitItem(1, nil)
    else
      f:pickMove(1)
    end
  end)
  eq(result, "win", "pyramid: won")
  eq(FakePyramid.bagCount(nil, 21), 1, "pyramid: the Pyramid bag gave exactly one HYPER POTION")
  PYR.active = false
  eq(FakeBag.get(SESSION.bag, 21), 5, "pyramid: the pockets were never touched")
  eq(#pickups, 1, "pyramid: Pickup after the win")
  eq(pickups[1] and pickups[1].rules and pickups[1].rules.pyramidSession, SESSION,
     "pyramid: ...the Pyramid's own table (Cmd_pickup's InBattlePyramid arm)")

  -- The writeback squares the bag with the referee, once.
  PYR.items, PYR.qty = { 21 }, { 3 }
  local ctx = { session = SESSION, pyramidBag3 = { start = { [21] = 3 }, had = { [21] = 3 } },
                sim = { byId = { [PLAYER] = { bag = { [21] = 1 } } } } }
  eq(Facility.pyramidWriteback3(ctx), 2, "pyramid writeback: two spent and not yet taken: taken")
  eq(FakePyramid.bagCount(nil, 21), 1, "pyramid writeback: ...leaving one")
  eq(Facility.pyramidWriteback3(ctx), 0, "pyramid writeback: never twice")
  eq(FakePyramid.bagCount(nil, 21), 1, "pyramid writeback: ...still one")

  -- A Pyramid trainer: a forfeit by RUN, the Pyramid bag, Pickup on a win.
  fresh()
  SESSION.party = { strong(4, 60) }
  PYR.items, PYR.qty = { 13 }, { 1 }
  PYR.active = true
  local tr
  local t = newSolo()
  check(offerTrainer(t, frontierFoe({ monOf(16, 5) }), startOpts("pyramid", {
    done = function(r2) tr = r2 end })), "pyramid trainer: taken")
  eq(createdWith.rules.forfeit, true, "pyramid trainer: RUN forfeits")
  eq(createdWith.rules.pyramidBag, true, "pyramid trainer: the Pyramid bag")
  eq(t.sim.byId[PLAYER].bag and t.sim.byId[PLAYER].bag[13], 1, "pyramid trainer: ...on side a")
  drive(t, function(f) f:pickMove(1) end)
  eq(tr, "win", "pyramid trainer: won")
  eq(#pickups, 1, "pyramid trainer: Pickup (BattleScript_FrontierTrainerBattleWon's TryPickUpItems)")
  check(type(SESSION.lastFrontierBattle) == "table", "pyramid trainer: the Frontier record is written")
  PYR.active = false
end

-- (i) Trainer Hill: the item quirk ------------------------------------------
do
  local function hillOpts(extra)
    local o = { wild = false, trainerHill = true, aiFlags = 7, trainerItems = { 0, 0, 0, 0 },
      scriptedLoss = true, trainerName = "KEIKO", trainerPicId = 31,
      defeatText = "KEIKO: You win.", victoryText = "KEIKO: I win.",
      frontierTrainer = { class = 61, className = "EXPERT", name = "KEIKO", pic = 31 } }
    for k, v in pairs(extra or {}) do o[k] = v end
    return o
  end
  local function hillFoe(party)
    return { party = party, trainerName = "KEIKO", trainerClass = 61, trainerClassName = "EXPERT",
             trainerPicId = 31, species = party[1].species, level = party[1].level }
  end

  fresh()
  FakeVm.ctx.specialVars[0x800F] = 2
  SESSION.party = { strong(4, 60) }
  SESSION.money = 700
  local result
  local solo = newSolo()
  local taken, stand = offerTrainer(solo, hillFoe({ monOf(16, 20) }), hillOpts({
    done = function(r) result = r end }))
  check(taken, "hill: a Trainer Hill trainer is taken")
  eq(stand and stand.facility3, "hill", "hill: the door says the Hill")
  local r = createdWith.rules
  eq(r.exp, false, "hill rules: no EXP")
  eq(r.theft, "none", "hill rules: nobody steals")
  eq(r.forfeit, true, "hill rules: RUN forfeits")
  eq(r.bag, nil, "hill rules: the bag is open")
  eq(r.boosts, nil, "hill rules: the badge boosts stay")
  eq(r.obedience, nil, "hill rules: ...and obedience")
  local items = solo.gen3.trainer.items
  eq(table.concat(items, ","), "13,13,0,0",
     "hill: the opponent carries trainer row 2's items (gTrainers[localId], the cart's quirk)")
  eq(table.concat(stand.trainer.items, ","), "0,0,0,0", "hill: ...the stand's own record untouched")
  eq(solo.sim.byId[FOE].bag and solo.sim.byId[FOE].bag[13], 2, "hill: ...on the referee's side b")
  local brain = solo.gen3.npcs[FOE]
  eq(brain and brain.noItems, false, "hill brain: may use them")
  eq(brain and brain.itemsNo3, 2, "hill brain: ...both")
  check(not seenSpecies(16), "hill: no dex 'seen'")
  local _, fight = drive(solo, function(f) f:pickMove(1) end)
  eq(result, "win", "hill: won")
  eq(SESSION.money, 700, "hill: no prize")
  eq(#pickups, 0, "hill: no Pickup")
  check(textOf(fight):find("KEIKO: You win.", 1, true) ~= nil, "hill: the defeat words")
  eq(SESSION.frontier and SESSION.frontier.disableRecordBattle, nil, "hill: no Frontier records touched")

  -- The local id by name, when the VM says none.
  fresh()
  SESSION.party = { strong(4, 60) }
  local byName = newSolo()
  check(offerTrainer(byName, hillFoe({ monOf(16, 20) }), hillOpts()), "hill (by name): taken")
  eq(table.concat(byName.gen3.trainer.items, ","), "13,13,0,0", "hill (by name): KEIKO is local id 2")
  byName:reset()
  -- ...and a trainer this floor does not know: no items, said once.
  fresh()
  SESSION.party = { strong(4, 60) }
  local mark = #warns
  local unknown = newSolo()
  local foeX = hillFoe({ monOf(16, 20) })
  foeX.trainerName = "NOBODY"
  check(offerTrainer(unknown, foeX, hillOpts({ trainerName = "NOBODY",
    frontierTrainer = { class = 61, className = "EXPERT", name = "NOBODY", pic = 31 } })),
    "hill (unknown): taken")
  eq(unknown.gen3.npcs[FOE].noItems, true, "hill (unknown): no items")
  check(countIn(warns, "item slots could not be read") == 1, "hill (unknown): said")
  dropWarnsSince(mark)
  unknown:reset()

  -- A loss: the hill trainer's win words, no whiteout.
  fresh()
  FakeVm.ctx.specialVars[0x800F] = 1
  local weak = monOf(4, 5, { moves = { 10 }, pp = { 35 }, maxPp = { 35 }, hp = 3 })
  SESSION.party = { weak }
  local lr
  local l = newSolo()
  check(offerTrainer(l, hillFoe({ strong(151, 70) }), hillOpts({ done = function(r2) lr = r2 end })),
        "hill loss: taken")
  eq(table.concat(l.gen3.trainer.items, ","), "21,0,0,0", "hill loss: local id 1 reads row 1's items")
  local _, lf = drive(l, function(f) f:pickMove(1) end)
  eq(lr, "lose", "hill loss: done('lose')")
  eq(#fieldCalls, 0, "hill loss: no whiteout")
  eq(weak.hp, 0, "hill loss: no heal")
  check(textOf(lf):find("KEIKO: I win.", 1, true) ~= nil, "hill loss: the trainer's win words")
  check(not textOf(lf):find("STRINGID_PLAYERWHITEOUT", 1, true), "hill loss: no whiteout lines")
end

-- (j) FireRed / LeafGreen's Trainer Tower --------------------------------------
do
  local function ttOpts(extra)
    local o = { trainerId = 0, double = false, trainerTower = true, trainerName = "LUCAS",
                trainerPicId = 12, noWhiteout = true, victoryText = "LUCAS: Gotcha!" }
    for k, v in pairs(extra or {}) do o[k] = v end
    return o
  end
  local function ttFoe(party)
    return { party = party, trainerId = 0, trainerName = "LUCAS", trainerClass = 3, trainerPicId = 12,
             doubleBattle = false, species = party[1].species, level = party[1].level }
  end

  fresh("frlg")
  local lead = strong(4, 60)
  SESSION.party = { lead }
  SESSION.money = 300
  local result
  local solo = newSolo()
  local taken, stand = offerTrainer(solo, ttFoe({ monOf(16, 20), monOf(16, 20) }), ttOpts({
    done = function(r) result = r end }))
  check(taken, "trainer tower: taken")
  eq(stand and stand.facility3, "trainerTower", "trainer tower: the door says so")
  local r = createdWith.rules
  eq(r.exp, false, "trainer tower rules: no EXP")
  eq(r.theft, "none", "trainer tower rules: nobody steals")
  eq(r.forfeit, nil, "trainer tower rules: no forfeit (FireRed has none)")
  eq(r.bag, nil, "trainer tower rules: the bag is open")
  eq(screenedWith.rules, nil, "trainer tower screen: no facility prompts")
  eq(solo.gen3.npcs[FOE].noItems, true, "trainer tower brain: no items")
  eq(solo.gen3.npcs[FOE].aiFlags, 7, "trainer tower brain: the facility scripts (pret, where the engine says 1)")
  check(seenSpecies(16), "trainer tower: the dex sees its monsters")
  -- RUN: the trainer's refusal, nothing spent.
  local f = toMenu(solo)
  local turn = solo.sim.turn
  f:sendChoice({ action = "run" })
  solo:update(0.5, GAME)
  eq(solo.sim.turn, turn, "trainer tower: RUN is refused, the turn unspent")
  eq(solo.sim:outcome(), nil, "trainer tower: ...and the fight goes on")
  local _, fight = drive(solo, function(fx) fx:pickMove(1) end)
  eq(result, "win", "trainer tower: won")
  eq(SESSION.money, 300, "trainer tower: no prize money")
  eq(#pickups, 1, "trainer tower: Pickup (BattleScript_BattleTowerTrainerBattleWon)")
  check(textOf(fight):find("STRINGID_PLAYERDEFEATEDTRAINER1", 1, true) ~= nil,
        "trainer tower: 'PLAYER defeated ...!'")
  check(not textOf(fight):find("STRINGID_PLAYERGOTMONEY", 1, true), "trainer tower: no money line")
  eq(SESSION.frontier, nil, "trainer tower: nothing of the Frontier touched")

  -- A loss: no heal (CB2_EndTrainerTowerBattle), the trainer's win words.
  fresh("frlg")
  local weak = monOf(4, 5, { moves = { 10 }, pp = { 35 }, maxPp = { 35 }, hp = 3 })
  SESSION.party = { weak }
  FakeVm.running = true
  local lr
  local l = newSolo()
  check(offerTrainer(l, ttFoe({ strong(151, 70) }), ttOpts({ done = function(r2) lr = r2 end })),
        "trainer tower loss: taken")
  local _, lf = drive(l, function(fx) fx:pickMove(1) end)
  eq(lr, "lose", "trainer tower loss: done('lose')")
  eq(weak.hp, 0, "trainer tower loss: no heal now -- the script heals and warps")
  eq(#fieldCalls, 0, "trainer tower loss: no whiteout")
  eq(FakeVm.halted, 0, "trainer tower loss: the script is answered")
  check(textOf(lf):find("LUCAS: Gotcha!", 1, true) ~= nil, "trainer tower loss: the trainer's win words")
  check(not textOf(lf):find("STRINGID_PLAYERLOSTAGAINSTENEMYTRAINER", 1, true),
        "trainer tower loss: no lost lines (BattleScript_BattleTowerLost)")
  FakeVm.running = false
  emerald()
end

-- (k) an Emerald Secret Base ---------------------------------------------------
do
  local function sbOpts(extra)
    local o = { wild = false, trainerId = 1024, trainerName = "AYA", trainerClass = 5,
                trainerClassName = "PKMN BREEDER", trainerPicId = 7, secretBase = true,
                noWhiteout = true, deferHeal = true }
    for k, v in pairs(extra or {}) do o[k] = v end
    return o
  end
  local function sbFoe(party)
    return { party = party, trainerId = 1024, trainerClass = 5, trainerClassName = "PKMN BREEDER",
             trainerName = "AYA", trainerPicId = 7, species = party[1].species, level = party[1].level }
  end

  fresh()
  local lead = strong(4, 30)
  SESSION.party = { lead }
  SESSION.money = 1000
  local expBefore = lead.exp
  local result
  local solo = newSolo()
  local taken, stand = offerTrainer(solo, sbFoe({ monOf(16, 12), monOf(16, 9) }), sbOpts({
    done = function(r) result = r end }))
  check(taken, "secret base: taken")
  eq(stand and stand.facility3, "secretBase", "secret base: the door says so")
  local r = createdWith.rules
  eq(r.boosts and r.boosts.damage, false, "secret base rules: no stat badge boosts")
  eq(r.boosts and r.boosts.speed, nil, "secret base rules: ...the speed one stays")
  eq(r.theft, "foe", "secret base rules: the foe may steal")
  eq(r.exp, nil, "secret base rules: EXP")
  eq(r.forfeit, nil, "secret base rules: RUN refused like any trainer's")
  eq(solo.gen3.npcs[FOE].noItems, true, "secret base brain: no items")
  eq(solo.gen3.trainer.defeatText, "Your base beat mine!", "secret base: the owner's defeat words, from the cart")
  check(seenSpecies(16), "secret base: the dex sees its monsters")
  local _, fight = drive(solo, function(f) f:pickMove(1) end)
  eq(result, "win", "secret base: won")
  eq(SESSION.money, 1000 + 20 * 12, "secret base: the prize is 20 x the base's first level")
  check(textOf(fight):find("STRINGID_PLAYERGOTMONEY|240|", 1, true) ~= nil, "secret base: ...said")
  check(textOf(fight):find("Your base beat mine!", 1, true) ~= nil, "secret base: the defeat words said")
  check(lead.exp > expBefore, "secret base: EXP earned")
  eq(#pickups, 1, "secret base: Pickup")

  -- A loss: no whiteout, the heal deferred to the base's script, no lines.
  fresh()
  local weak = monOf(4, 5, { moves = { 10 }, pp = { 35 }, maxPp = { 35 }, hp = 3 })
  SESSION.party = { weak }
  SESSION.money = 1000
  local lr
  local l = newSolo()
  check(offerTrainer(l, sbFoe({ strong(151, 70) }), sbOpts({ done = function(r2) lr = r2 end })),
        "secret base loss: taken")
  local _, lf = drive(l, function(f) f:pickMove(1) end)
  eq(lr, "lose", "secret base loss: done('lose')")
  eq(#fieldCalls, 0, "secret base loss: no whiteout")
  eq(SESSION.money, 1000, "secret base loss: no money lost")
  eq(weak.hp, 0, "secret base loss: the heal is the script's, later")
  check(not textOf(lf):find("STRINGID_PLAYERWHITEOUT", 1, true), "secret base loss: no lines")
end

Turn3.create, Mediated.new, CoopBattle.newSoloDouble = realCreate, realNew, realDouble
RomText.has, RomText.plain = realHas, realPlain

-- Nothing of Gen 1's engine was reached on a Gen 3 boot, and nothing failed.
check(package.loaded["src.battle.BattleState"] == nil, "no Gen 1 BattleState on a Gen 3 boot")
check(not contains(warns, "ERROR"), "no error was logged: " .. table.concat(warns, " / "))
check(not contains(warns, "own rules failed"), "no facility hook failed: " .. table.concat(warns, " / "))
check(not contains(warns, "could not"), "no fallback warning fired: " .. table.concat(warns, " / "))

unstubAll()
T.finish("gen3_solo_facility")
