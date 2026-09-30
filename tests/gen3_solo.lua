-- Headless Gen 3 solo battles (Wave 4 T12): the Gen 3 arms of
-- src/SoloBattle.lua and src/SoloBrain.lua.
--
-- The shape tests/gen3_mediated.lua set: a FireRed-shaped boot (the stub
-- facade says generation 3) over the engine SDK's own Gen 3 fixture
-- (T.sdk.gen3Data, synthetic numbers), the engine modules that would need an
-- imported cache stood in by small fakes that record what they were asked,
-- and the engine's own *pure* modules run for real (the ordered type chart,
-- the exp curve, the game3 modal stack, the prize formula).  The referee is
-- the real src/BattleSim3 and the screen the real MediatedBattle, so a fight
-- here is the fight a player gets, minus the pixels.
--
--   1. SoloBrain, Gen 3: crafted fields on a real BattleSim3 referee --
--      ability immunities, the weather, heal thresholds, the KO, the
--      trainer's AI flag bits in both carts' layouts, items, switching and
--      the send-out.
--   2. SoloBattle, Gen 3: a wild fight to a catch, a trainer fight to a win
--      (prize money, exp, the `done` the trainer script resumes on), a loss to
--      the whiteout, RUN (away, refused by the roll, refused by a trap), the
--      refusals, the after-battle prompts, the hand-back, and the mid-fight
--      moveset.
--
-- Legal: every species, move, trainer and item row below is either the SDK
-- fixture's or invented here with synthetic numbers; the only real values are
-- pret enum numbers the battle code branches on (TYPE_*, EFFECT_*, ABILITY_*,
-- HOLD_EFFECT_*, ITEM_* ids), which is the policy docs/plans/gen3-battle-sheet.md
-- states for the sim itself.
--
-- Run from the engine checkout root:
--
--   luajit mods/rby_mmo/tests/gen3_solo.lua

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
-- 1. SoloBrain, Gen 3
-- ===================================================================

-- A crafted ordered chart (synthetic rows in pret's triple format): the
-- immunities and the handful of matchups the scenarios lean on.
local CHART = {
  4, 2, 0,      -- GROUND -> FLYING: immune
  13, 4, 0,     -- ELECTRIC -> GROUND: immune
  10, 12, 20,   -- FIRE -> GRASS
  10, 6, 20,    -- FIRE -> BUG
  11, 10, 20,   -- WATER -> FIRE
  10, 11, 5,    -- FIRE -> WATER
  12, 11, 20,   -- GRASS -> WATER
  13, 11, 20,   -- ELECTRIC -> WATER
  -1, -1, 0,    -- the Foresight sentinel
  0, 7, 0,      -- NORMAL -> GHOST: immune
}

local function mv(num, fields)
  local row = { id = "FIX_" .. num, num = num, pp = 10, maxPp = 10, power = 0, type = 0,
                accuracy = 100, effect = 0, chance = 0, target = 0, priority = 0, flags = 0 }
  for k, v in pairs(fields or {}) do row[k] = v end
  return row
end

local function sheet(fields)
  local s = {
    generation = 3, species = "FOO", speciesId = "1", speciesNum = 1, slot = 0,
    level = 50, hp = 100, maxHp = 100,
    stats = { atk = 80, def = 80, spe = 80, spa = 80, spd = 80 },
    types = { 0 }, ability = 0, heldItem = 0, holdEffect = 0, holdEffectParam = 0,
    gender = "M", friendship = 70, weight = 100, nature = 0,
    hiddenPower = { type = 1, power = 70 }, beatUp = { atk = 50, def = 50 },
    moves = { mv(1, { power = 40 }) },
  }
  for k, v in pairs(fields or {}) do s[k] = v end
  return s
end

-- A referee with the NPC on side b (the solo seating), and the view SoloBattle
-- hands the brain for it.
local function field(npc, player, extra)
  extra = extra or {}
  local battle = assert(Sim.Turn.create({
    id = "brain", mode = "coop_npc", seed = extra.seed or 3, typeTable = CHART,
    weather = extra.weather,
    sides = {
      a = { { playerId = "p", name = "P", mons = { player } } },
      b = { { playerId = "n", name = "N", mons = npc, bag = extra.bag } },
    },
  }))
  battle:drainEvents()
  local n, p = battle.byId.n, battle.byId.p
  return battle, {
    sim = battle, battler = n.b, foeBattler = p.b, fighter = n,
    mon = n.b.mon, foe = p.b.mon, party = n.mons, active = n.active, bag = n.bag,
  }
end

-- rng that always answers the bottom of the range: no random bonus ever
-- fires, ties go to the first move, the simulated roll is 100.
local function lowRng(lo, hi) if hi == nil then return 1 end return lo end

local function brain3(flags, extra)
  extra = extra or {}
  return assert(Brain.new({
    generation = 3, trainer = { aiFlags = flags, items = extra.items or {} },
    rng = extra.rng or lowRng, aiBits = extra.aiBits or Brain.AI_BITS_FRLG,
  }))
end

do
  eq(Brain.new({ generation = 3 }), nil, "brain3: no trainer record, no brain (a wild fight)")
  local b = Brain.new({ generation = 3, trainer = { aiFlags = 5, items = { 13, 0, 21, 0 } } })
  check(b ~= nil, "brain3: builds with no dataset at all -- the sheets carry every number")
  eq(b and b.generation, 3, "brain3: a Gen 3 brain is Gen 3, not clamped to Red")
  eq(b and b.aiFlags, 5, "brain3: the trainer's own AI flags")
  local bag = Brain.bagFor({ items = { 13, 0, 13, 21 } }, nil, 3)
  eq(bag[13], 2, "bagFor(3): numeric ids, one use per slot")
  eq(bag[21], 1, "bagFor(3): ...and the rest")
  eq(#Brain.itemsFor({ items = { 13, 0, 0, 21 } }, nil, 3), 2, "itemsFor(3): zeros dropped")
end

-- Ability immunities under CHECK_BAD_MOVE, each against a plain alternative.
local function pickAgainst(ability, bad, flags)
  local npc = { sheet({ moves = { bad, mv(1, { power = 40 }) } }) }
  local _, view = field(npc, sheet({ ability = ability, types = { 14 } }))
  return brain3(flags):choose(view)
end

do
  local quake = mv(89, { power = 100, type = 4 })
  eq(pickAgainst(26, quake, 1).move, 1, "brain3: a Ground move into LEVITATE is avoided")
  eq(pickAgainst(26, quake, 0).move, 0, "brain3: ...and only because the trainer's flags say so")
  eq(pickAgainst(10, mv(85, { power = 95, type = 13 }), 1).move, 1,
     "brain3: an Electric move into VOLT ABSORB is avoided")
  eq(pickAgainst(11, mv(57, { power = 95, type = 11 }), 1).move, 1,
     "brain3: a Water move into WATER ABSORB is avoided")
  eq(pickAgainst(18, mv(52, { power = 95, type = 10 }), 1).move, 1,
     "brain3: a Fire move into FLASH FIRE is avoided")
  eq(pickAgainst(43, mv(46, { power = 0, effect = E.SLEEP }), 1).move, 1,
     "brain3: a sound move into SOUNDPROOF is avoided")
  -- a plain type immunity (Normal into Ghost)
  local npc = { sheet({ moves = { mv(33, { power = 90 }), mv(52, { power = 40, type = 10 }) } }) }
  local _, view = field(npc, sheet({ types = { 7 } }))
  eq(brain3(1):choose(view).move, 1, "brain3: a Normal move into a Ghost is avoided")
end

-- WONDER GUARD lets only a super-effective move through.
do
  local npc = { sheet({ moves = {
    mv(33, { power = 90 }),                -- Normal: immune by type anyway
    mv(57, { power = 90, type = 11 }),     -- Water: neutral, blocked
    mv(52, { power = 40, type = 10 }),     -- Fire into a Bug: through
  } }) }
  local _, view = field(npc, sheet({ ability = 25, types = { 6, 7 } }))
  eq(brain3(1):choose(view).move, 2, "brain3: into WONDER GUARD only the super-effective move is scored up")
end

-- The weather: Thunder in rain / sun, and a weather move the sky already has.
do
  local thunder = mv(87, { power = 120, type = 13, effect = E.THUNDER, accuracy = 70 })
  local bolt = mv(85, { power = 120, type = 13 })
  local _, rain = field({ sheet({ moves = { bolt, thunder } }) }, sheet(), { weather = "RAIN" })
  eq(brain3(3):choose(rain).move, 1, "brain3: CHECK_VIABILITY takes Thunder in the rain")
  local _, sun = field({ sheet({ moves = { thunder, bolt } }) }, sheet(), { weather = "SUN" })
  eq(brain3(3):choose(sun).move, 1, "brain3: ...and leaves it in the sun")
  local _, again = field({ sheet({ moves = { mv(240, { effect = E.RAIN_DANCE, target = 16 }),
                                             mv(1, { power = 40 }) } }) }, sheet(), { weather = "RAIN" })
  eq(brain3(1):choose(again).move, 1, "brain3: no RAIN DANCE into a sky that is already raining")
end

-- Heal thresholds.
do
  local recover = mv(105, { effect = E.RESTORE_HP, target = 16 })
  local _, low = field({ sheet({ hp = 20, moves = { mv(1, { power = 40 }), recover } }) }, sheet())
  eq(brain3(3):choose(low).move, 1, "brain3: low on HP, a viability trainer heals")
  local _, full = field({ sheet({ moves = { recover, mv(1, { power = 40 }) } }) }, sheet())
  eq(brain3(3):choose(full).move, 1, "brain3: at full HP it does not")
end

-- TRY_TO_FAINT, in both carts' bit layouts.
do
  local npc = { sheet({ moves = { mv(1, { power = 20 }), mv(2, { power = 200 }) } }) }
  local _, view = field(npc, sheet({ hp = 30 }))
  eq(brain3(0):choose(view).move, 0, "brain3: with no flags the pick is random (low rng: slot 0)")
  eq(brain3(4):choose(view).move, 1, "brain3: FireRed bit 2, TRY_TO_FAINT, takes the knockout")
  local emerald = { CHECK_BAD_MOVE = 0, TRY_TO_FAINT = 1, CHECK_VIABILITY = 2 }
  eq(brain3(2, { aiBits = emerald }):choose(view).move, 1,
     "brain3: Emerald numbers TRY_TO_FAINT bit 1, and the engine's layout is honoured")
  eq(brain3(2):choose(view).move, 0, "brain3: ...where on FireRed bit 1 is CHECK_VIABILITY")
end

-- Struggle: nothing usable is the referee's any-index Struggle.
do
  local empty = mv(1, { power = 40, pp = 0 })
  local _, view = field({ sheet({ moves = { empty } }) }, sheet())
  local c = brain3(1):choose(view)
  eq(c and c.action, "fight", "brain3: an all-empty moveset still answers")
  eq(c and c.move, 0, "brain3: ...as slot 0 (Struggle)")
end

-- Items: pret ShouldUseItem over the trainer's slots, spent once.
do
  local npc = { sheet({ hp = 20 }) }
  local battle, view = field(npc, sheet(), { bag = { { id = 21, count = 1 } } })
  local brain = brain3(1, { items = { 21, 0, 0, 0 } })
  local c = brain:choose(view)
  eq(c and c.action, "item", "brain3: under a quarter HP the trainer drinks its HYPER POTION")
  eq(c and c.item, 21, "brain3: ...by its numeric id")
  check(battle:submitChoice("n", c), "brain3: the referee takes the item choice")
  local _, view2 = field(npc, sheet(), { bag = { { id = 21, count = 1 } } })
  eq(brain:choose(view2).action, "fight", "brain3: the slot is spent -- no second potion")
  local _, full = field({ sheet() }, sheet(), { bag = { { id = 21, count = 1 } } })
  eq(brain3(1, { items = { 21, 0, 0, 0 } }):choose(full).action, "fight",
     "brain3: at full HP the potion stays in the bag")
end

-- Switching: Wonder Guard with nothing that gets through, a bench mon that does.
do
  local npc = {
    sheet({ slot = 0, moves = { mv(57, { power = 90, type = 11 }) } }),
    sheet({ slot = 1, moves = { mv(52, { power = 40, type = 10 }) } }),
  }
  local _, view = field(npc, sheet({ ability = 25, types = { 6, 7 } }))
  local c = brain3(1):choose(view)
  eq(c and c.action, "switch", "brain3: against WONDER GUARD with no way through, rotate")
  eq(c and c.slot, 1, "brain3: ...to the bench mon whose move gets past it")
  -- the same field, but the player's SHADOW TAG holds the NPC in
  local held = { sheet({ slot = 0, moves = { mv(57, { power = 90, type = 11 }) } }),
                 sheet({ slot = 1, moves = { mv(52, { power = 40, type = 10 }) } }) }
  local _, trapped = field(held, sheet({ ability = 23 }))
  eq(brain3(1):choose(trapped).action, "fight", "brain3: a trapped trainer does not try to switch")
end

-- The send-out: GetMostSuitableMonToSwitchInto, backwards typing and all.
do
  local npc = {
    sheet({ slot = 0, hp = 0 }),
    sheet({ slot = 1, types = { 11 }, moves = { mv(57, { power = 90, type = 11 }) } }),
    sheet({ slot = 2, types = { 12 }, moves = { mv(57, { power = 90, type = 11 }) } }),
  }
  local _, view = field(npc, sheet({ types = { 10 } }))
  view.mustReplace = true
  view.mon = npc[1]
  view.battler = nil
  local c = brain3(1):choose(view)
  eq(c and c.action, "switch", "brain3: a faint asks for a send-out")
  eq(c and c.slot, 2, "brain3: the cart's pick -- the mon the player's typing hits hardest "
     .. "that still has a super-effective move (pret's backwards test)")
end

-- ------- the cart's own scripts, per family (the engine runs them from the
--         cart: battle/ai.lua over the imported script pack)

-- Emerald's AI_SCRIPT_* numbering (pokeemerald include/constants/battle_ai.h,
-- the engine's emerald battle profile): the layout the brain reads the
-- family off.
local EM_BITS = { CHECK_BAD_MOVE = 0, TRY_TO_FAINT = 1, CHECK_VIABILITY = 2, SETUP_FIRST_TURN = 3,
                  RISKY = 4, PREFER_POWER_EXTREMES = 5, PREFER_BATON_PASS = 6, DOUBLE_BATTLE = 7,
                  HP_AWARE = 8, TRY_SUNNY_DAY_START = 9 }

-- rng that clears every "if_random_less_than" (the 0..255 draws answer 255)
-- and answers the bottom of every other range.
local function highRand(lo, hi)
  if hi == nil then return 1 end
  if lo == 0 and hi == 255 then return 255 end
  return lo
end

do
  eq(Brain.aiFamily3(Brain.AI_BITS_FRLG), "frlg", "aiFamily3: FireRed's layout")
  eq(Brain.aiFamily3(EM_BITS), "rse", "aiFamily3: Emerald's")
  eq(brain3(1).family3, "frlg", "brain3: the family is read off the layout it runs")
  eq(brain3(1, { aiBits = EM_BITS }).family3, "rse", "brain3: ...Emerald's too")
end

-- TRY_TO_FAINT: `if_can_faint` passes over anything of power under 2, so a
-- one-hit KO move is not a knockout to it.
do
  local ohko = mv(32, { power = 1, effect = E.OHKO })
  local npc = { sheet({ moves = { mv(1, { power = 40 }), ohko } }) }
  local _, view = field(npc, sheet())
  eq(brain3(4):choose(view).move, 0, "brain3: TRY_TO_FAINT does not count a one-hit KO move as a knockout")
  local _, ko = field({ sheet({ moves = { mv(1, { power = 40 }), mv(2, { power = 200 }) } }) }, sheet({ hp = 30 }))
  eq(brain3(4):choose(ko).move, 1, "brain3: ...a real knockout still is")
end

-- TRY_TO_FAINT's 4x bonus is Emerald's script alone.
do
  local npc = { sheet({ moves = { mv(1, { power = 40 }), mv(52, { power = 40, type = 10 }) } }) }
  local _, view = field(npc, sheet({ types = { 12, 6 } }))
  local fr = brain3(4, { rng = highRand })
  fr:choose(view)
  eq(fr.lastScores3 and fr.lastScores3[2], 100, "brain3: FireRed's AI_TryToFaint has no 4x bonus")
  local _, view2 = field(npc, sheet({ types = { 12, 6 } }))
  local em = brain3(2, { rng = highRand, aiBits = EM_BITS })
  em:choose(view2)
  eq(em.lastScores3 and em.lastScores3[2], 102, "brain3: Emerald's adds +2 for a 4x hit")
end

-- Slot 5: FireRed's PREFER_STRONGEST_MOVE is the same script as Emerald's
-- PREFER_POWER_EXTREMES -- a DISCOURAGED move (status, fixed damage) +2.
do
  local npc = { sheet({ moves = { mv(1, { power = 40 }), mv(45, { power = 0, effect = E.ATTACK_DOWN }) } }) }
  local _, view = field(npc, sheet())
  eq(brain3(32, { rng = highRand }):choose(view).move, 1,
     "brain3: FireRed's PREFER_STRONGEST_MOVE favours the status move, as the cart's script does")
  local _, view2 = field(npc, sheet())
  eq(brain3(32, { rng = highRand, aiBits = EM_BITS }):choose(view2).move, 1,
     "brain3: ...exactly as Emerald's PREFER_POWER_EXTREMES")
end

-- AI_CheckBadMove sends only a move the power reading does not discourage
-- through the immunity checks (and, on Emerald, FISSURE / HORN DRILL too).
do
  -- EXPLOSION (a discouraged effect) into a Ghost is not written off here.
  local npc = { sheet({ moves = { mv(153, { power = 250, effect = E.EXPLOSION }),
                                  mv(52, { power = 40, type = 10 }) } }) }
  local _, view = field(npc, sheet({ types = { 7 } }))
  eq(brain3(1):choose(view).move, 0,
     "brain3: a discouraged move skips AI_CBM_CheckIfNegatesType (its score is left at 100)")
  -- FISSURE into a Flying type: FireRed's script never checks it...
  local fissure = mv(90, { power = 1, type = 4, effect = E.OHKO })
  local _, fr = field({ sheet({ moves = { fissure, mv(1, { power = 40 }) } }) }, sheet({ types = { 2 } }))
  eq(brain3(1):choose(fr).move, 0, "brain3: FireRed does not send FISSURE through the immunity checks")
  -- ...Emerald's names it and marks it down.
  local _, em = field({ sheet({ moves = { fissure, mv(1, { power = 40 }) } }) }, sheet({ types = { 2 } }))
  eq(brain3(1, { aiBits = EM_BITS }):choose(em).move, 1,
     "brain3: Emerald sends FISSURE through them, and a Flying type is immune")
  -- the SOUNDPROOF check still covers a discouraged sound move
  eq(pickAgainst(43, mv(47, { power = 0, effect = E.SLEEP }), 1).move, 1,
     "brain3: SING into SOUNDPROOF is still avoided")
end

-- ShouldSwitch's own trap reading: an opposing ARENA TRAP holds a Flying type
-- in, and a MAGNET PULL anywhere -- its own -- holds a Steel type in.
do
  local function perishField(npcLead, player)
    local npc = { npcLead, sheet({ slot = 1, moves = { mv(1, { power = 40 }) } }) }
    local _, view = field(npc, player)
    view.battler.perishTurns = 0
    return view
  end
  local free = perishField(sheet({ slot = 0 }), sheet())
  eq(brain3(1):choose(free).action, "switch", "brain3: a perish count at 0 switches out")
  local trapped = perishField(sheet({ slot = 0, types = { 2 } }), sheet({ ability = 71 }))
  eq(brain3(1):choose(trapped).action, "fight",
     "brain3: an opposing ARENA TRAP holds a Flying type in, as the cart's AI reads it")
  local pulled = perishField(sheet({ slot = 0, types = { 8 }, ability = 42 }), sheet())
  eq(brain3(1):choose(pulled).action, "fight",
     "brain3: its own MAGNET PULL holds a Steel type in")
end

-- ShouldSwitchIfNaturalCure: asleep only; then the flags search.
do
  local function coin(lo, hi)
    if hi == nil then return 1 end
    if lo == 0 and hi == 1 then return 1 end
    return lo
  end
  local function cureField(status)
    local npc = { sheet({ slot = 0, ability = 30 }), sheet({ slot = 1 }) }
    local _, view = field(npc, sheet())
    view.battler.mon.status = status
    return view
  end
  eq(brain3(1, { rng = coin }):choose(cureField("PSN")).action, "fight",
     "brain3: NATURAL CURE does not switch out of poison (the cart asks for sleep)")
  eq(brain3(1, { rng = coin }):choose(cureField("SLP")).action, "switch",
     "brain3: ...it switches out of sleep")
  -- asleep, hit by an Electric move: a Ground bench mon with a Grass move
  -- for the Water player is sent in (FindMonWithFlags, no roll), where the
  -- super-effective check alone would have stayed.
  local function sayStay(lo, hi)
    if hi == nil then return 1 end
    if lo == 0 and hi == 9 then return 1 end
    return lo
  end
  local grass = mv(22, { power = 45, type = 12 })
  local npc = { sheet({ slot = 0, ability = 30, moves = { grass } }),
                sheet({ slot = 1, types = { 4 }, moves = { grass } }) }
  local _, view = field(npc, sheet({ types = { 11 }, moves = { mv(85, { power = 95, type = 13 }) } }))
  view.battler.mon.status = "SLP"
  view.battler.lastLandedMove = 85
  view.battler.lastHitBy = "p"
  local c = brain3(1, { rng = sayStay }):choose(view)
  eq(c and c.action, "switch", "brain3: NATURAL CURE asleep: the mon the last hit cannot touch")
  eq(c and c.slot, 1, "brain3: ...is the one sent in")
end

-- GetMostSuitableMonToSwitchInto's second pass, read the cart's way: a base
-- of 2 per move not of power 1, x1.5 for sharing a type with the mon being
-- replaced, through the chart -- not whoever hits hardest.
do
  local npc = {
    sheet({ slot = 0, hp = 0, types = { 10 } }),
    sheet({ slot = 1, types = { 0 }, moves = { mv(2, { power = 200 }) } }),
    sheet({ slot = 2, types = { 11 }, moves = { mv(52, { power = 10, type = 10 }) } }),
  }
  local _, view = field(npc, sheet())
  view.mustReplace = true
  view.mon = npc[1]
  view.battler = nil
  local c = brain3(1):choose(view)
  eq(c and c.slot, 2, "brain3: the send-out's second pass prices STAB off the fainted mon, "
     .. "not the candidate's damage")
end

-- ===================================================================
-- 2. SoloBattle, Gen 3
-- ===================================================================

eq(Solo.turnFor(3), need("BattleSim3/Turn"), "turnFor(3) is BattleSim3")
eq(Solo.turnFor(2), need("BattleSim2/Turn"), "turnFor(2) is still BattleSim2")
eq(Solo.turnFor(1), need("BattleSim/Turn"), "turnFor(1) is still BattleSim")

-- (a) the kinds and the refusals
do
  eq(Solo.gen3Kind({ wild = true }, {}), "wild", "gen3Kind: the wild flag")
  eq(Solo.gen3Kind({}, { species = 16, level = 3 }), "wild", "gen3Kind: an encounter row")
  eq(Solo.gen3Kind({ trainerId = 900 }, {}), "trainer", "gen3Kind: a trainer id")
  eq(Solo.gen3Kind({}, 900), "trainer", "gen3Kind: a bare trainer id")
  for _, field_ in ipairs({ "safari", "roamer", "legendary", "wildScripted", "oldManTutorial",
                            "firstBattle", "pokedude", "ghost", "link", "twoOpponents" }) do
    check(Solo.gen3Refused({ [field_] = true }, {}), "gen3Refused: " .. field_ .. " on the opts")
  end
  check(Solo.gen3Refused({}, { roamer = true }), "gen3Refused: ...and on the foe")
  check(Solo.gen3Refused({}, { kinds = { tutorial = "oldman" } }), "gen3Refused: ...and in a kinds table")
  check(not Solo.gen3Refused({ firstBattle = false, trainerId = 900 }, {}),
        "gen3Refused: firstBattle = false is an ordinary trainer, not a refusal")
  check(Solo.gen3Double({ double = true }, {}), "gen3Double: the double flag")
  check(Solo.gen3Double({}, { doubleBattle = true }), "gen3Double: a double trainer row")
  eq(Solo.gen3Result("win", "catch", false), "caught", "gen3Result: catch")
  eq(Solo.gen3Result("loss", "run", false), "run", "gen3Result: the player ran")
  eq(Solo.gen3Result("win", "run", false), "fled", "gen3Result: the wild mon left")
  eq(Solo.gen3Result("draw", "ko", true), "lose", "gen3Result: a whiteout draw is a defeat")
  eq(Solo.gen3Result("win", "ko", false), "win", "gen3Result: win")
  -- A flight is decided by who ran, not by who the referee named the winner.
  eq(Solo.gen3Result("win", "run", false, "a"), "run",
     "gen3Result: our side left -- a POKe DOLL names us the winners, and it is still RAN")
  eq(Solo.gen3Result("loss", "run", false, "b"), "fled", "gen3Result: their side left")
  -- A draw is not a win for a trainer script; the save still says DREW.
  eq(Solo.gen3Result("draw", "timeout", false, nil, "trainer"), "lose",
     "gen3Result: a drawn trainer fight answers the script 'lose'")
  eq(Solo.gen3Result("draw", "timeout", false, nil, "wild"), "draw", "gen3Result: a wild draw is a draw")
  eq(Solo.gen3OutcomeWord("draw", "timeout", false), "draw", "gen3OutcomeWord: ...and the save says DREW")
  eq(Solo.gen3Result("draw", "ko", true, nil, "trainer"), "lose",
     "gen3Result: a double knockout is the cart's whiteout either way")

  newGame()
  SESSION.party = { monOf(4, 20) }
  local solo = newSolo()
  OPTIONS.solo = false
  eq(solo:fromGen3Encounter(GAME, { species = 16, level = 3 }, {}), false, "row off: declined")
  OPTIONS.solo = true
  eq(solo:fromGen3Encounter(GAME, { species = 16, level = 3 }, { safari = true }), false,
     "a safari encounter is handed back")
  eq(solo:fromGen3Encounter(GAME, { species = 16, level = 3, roamer = true }, {}), false,
     "a roamer is handed back")
  eq(solo:fromGen3Trainer(GAME, 902, {}), false, "a double trainer is handed back")
  eq(solo:fromGen3Encounter({ generation = 1 }, { species = 16, level = 3 }, {}), false,
     "not a Gen 3 game: declined")
  battleActive = true
  eq(solo:fromGen3Encounter(GAME, { species = 16, level = 3 }, {}), false,
     "the cart's own battle is running: declined")
  battleActive = false
  eq(solo:isRunning(), false, "nothing was started by any of the above")
  eq(Stack.depth(), 0, "and nothing went onto the stack")
end

-- (b) a wild fight to a catch
do
  newGame()
  local lead = monOf(4, 30)
  SESSION.party = { lead }
  FakeBag.add(SESSION.bag, 1, 1)
  local solo = newSolo()
  local result, calls = nil, 0
  local took = solo:fromGen3Encounter(GAME, { species = 16, level = 5 }, {
    done = function(r) result = r; calls = calls + 1 end,
  })
  check(took, "wild: the encounter is taken")
  check(solo:isRunning(), "wild: a fight is running")
  eq(encounterResets, 1, "wild: the encounter cooldown re-armed, as the engine does")
  check(Gen3Ui.has(solo.fight), "wild: the screen is a game3 layer")
  check(solo.sim and solo.sim.id and solo.sim.mode == Config.SOLO_WILD_MODE,
        "wild: seated as the wild mode")
  eq(solo.sim and type(solo.sim.typeTable), "table", "wild: the cart's ordered chart reached the referee")
  local wild = solo.wildMon
  eq(wild and wild.species, 16, "wild: the engine-built wild mon")
  check(wild and wild.exp and wild.exp > 0, "wild: ...with its exp on the growth curve")
  check(wild and #wild.moves >= 1 and wild.pp and #wild.pp == #wild.moves,
        "wild: ...and the learnset's moves with their PP")
  local seen = false
  for _, s in ipairs(FakeDex.seen) do if s.species == 16 and not s.caught then seen = true end end
  check(seen, "wild: the dex saw it the moment it came out")
  local thrown = false
  local ok, fight = drive(solo, function(f)
    if not thrown then
      thrown = true
      f.itemPick = { id = 1, effect = Sheet3.itemEffect(1) }
      f:commitItem(nil, nil)
    else
      f:pickMove(1)
    end
  end)
  check(ok, "wild: the fight ran to its end")
  eq(result, "caught", "wild: done('caught')")
  eq(calls, 1, "wild: done exactly once")
  eq(#SESSION.party, 2, "wild: the catch joined the session party")
  eq(SESSION.party[2], wild, "wild: ...the very engine mon, not a rebuilt sheet")
  eq(wild.pokeball, 1, "wild: in the ball it was caught in")
  eq(wild.otName, "ANN", "wild: the catcher is its original trainer")
  eq(#FakeDex.captures, 1, "wild: the dex registered the capture")
  eq(FakeBag.get(SESSION.bag, 1), 0, "wild: the ball was spent")
  check(textOf(fight):find("Wild PIDGEY", 1, true) ~= nil, "wild: 'Wild PIDGEY appeared!'")
  eq(nicknames[#nicknames], "PIDGEY", "wild: the nickname was offered")
  check(not solo:isRunning(), "wild: nothing is left running")
  eq(Gen3Ui.has(fight), false, "wild: the screen left the stack")
  eq(spaceCalls, 1, "wild: the map's resume scripts ran after the fight")
end

-- (c) a trainer fight to a win: prize, exp, `done`
do
  newGame()
  local lead = monOf(4, 20, { moves = { 10 }, pp = { 35 }, maxPp = { 35 } })
  SESSION.party = { lead }
  SESSION.money = 500
  local expBefore, ppBefore = lead.exp, lead.pp[1]
  local solo = newSolo()
  local result, calls = nil, 0
  local took = solo:fromGen3Trainer(GAME, { trainerId = 900 }, {
    trainerId = 900, done = function(r) result = r; calls = calls + 1 end,
  })
  check(took, "trainer: the trainer is taken")
  eq(solo.sim.mode, Config.SOLO_TRAINER_MODE, "trainer: seated as coop_npc")
  check(solo.brain ~= nil and solo.brain.generation == 3, "trainer: the Gen 3 brain answers for them")
  eq(solo.brain and solo.brain.aiFlags, 1, "trainer: ...with the trainer's own AI flags")
  eq(solo.fight.trainer and solo.fight.trainer.trainerId, 900,
     "trainer: the screen holds the numeric trainer id (its music, its pic)")
  eq(solo.fight.trainer and solo.fight.trainer.trainerPic, 5, "trainer: its TRAINER_PIC")
  local foeMon = solo.gen3 and solo.gen3.party[1]
  eq(foeMon and foeMon.personality, (0x80 + 256 - 0x80 + 0x88) % 4294967296,
     "trainer: the pret personality, re-based for a single battle")
  eq(foeMon and foeMon.heldItem, 0, "trainer: no wild held-item roll on a trainer's mon")
  local ok, fight = drive(solo, function(f) f:pickMove(1) end)
  check(ok, "trainer: the fight ran to its end")
  eq(result, "win", "trainer: done('win') -- the trainer script's resume and its flag")
  eq(calls, 1, "trainer: exactly once")
  local want = Prize.calc(900, { lastLevel = 3, moneyMultiplier = 1 })
  check(want > 0, "trainer: the engine's formula prices this trainer")
  eq(SESSION.money, 500 + want, "trainer: the prize is paid into the session")
  local text = textOf(fight)
  check(text:find("would like", 1, true) ~= nil, "trainer: 'YOUNGSTER BEN would like to battle!'")
  check(text:find("STRINGID_PLAYERDEFEATEDTRAINER1", 1, true) ~= nil, "trainer: the defeated line")
  check(text:find("I lost to you!", 1, true) ~= nil, "trainer: the trainer's defeat speech")
  check(text:find("STRINGID_PLAYERGOTMONEY|" .. want, 1, true) ~= nil, "trainer: the money line")
  check(lead.exp > expBefore, "trainer: the knockout paid exp onto the session mon")
  check(lead.pp[1] < ppBefore, "trainer: the PP the fight spent came home (mon.pp[])")
  eq(fieldCalls[1], nil, "trainer: no whiteout on a win")
end

-- (d) a loss: the whiteout
do
  newGame()
  local lead = monOf(4, 5, { moves = { 10 }, pp = { 35 }, maxPp = { 35 }, hp = 3 })
  SESSION.party = { lead }
  SESSION.money = 500
  local solo = newSolo()
  local result
  check(solo:fromGen3Trainer(GAME, 901, { done = function(r) result = r end }),
        "loss: the leader is taken")
  local ok, fight = drive(solo, function(f) f:pickMove(1) end)
  check(ok, "loss: the fight ran to its end")
  eq(result, "lose", "loss: done('lose')")
  eq(fieldCalls[1], "respawn", "loss: Field.respawnAtHeal -- the warp, the heal")
  eq(bridgeCalls[1] and bridgeCalls[1][1], "loss", "loss: the cart's money loss")
  eq(SESSION.money, 380, "loss: ...taken from the session")
  eq(lead.hp, lead.maxHp, "loss: the party was healed by the respawn")
  local text = textOf(fight)
  check(text:find("STRINGID_PLAYERLOSTAGAINSTENEMYTRAINER", 1, true) ~= nil, "loss: the cart's lost line")
  check(text:find("STRINGID_PLAYERPAIDPRIZEMONEY|120", 1, true) ~= nil,
        "loss: what it costs, said before it is taken")

  -- Emerald says its two whiteout lines instead.
  newGame()
  SESSION.party = { monOf(4, 5, { moves = { 10 }, pp = { 35 }, maxPp = { 35 }, hp = 3 }) }
  PROFILE.rules.lostText = "rse"
  local em = newSolo()
  check(em:fromGen3Trainer(GAME, 901, {}), "loss (rse): taken")
  local _, emFight = drive(em, function(f) f:pickMove(1) end)
  PROFILE.rules.lostText = "frlg"
  check(textOf(emFight):find("STRINGID_PLAYERWHITEOUT2", 1, true) ~= nil, "loss (rse): Emerald's lines")

  -- The early rival's heal-after: no warp, a healed party.
  newGame()
  local rivalLead = monOf(4, 5, { moves = { 10 }, pp = { 35 }, maxPp = { 35 }, hp = 3 })
  SESSION.party = { rivalLead }
  SESSION.money = 500
  local rival = newSolo()
  local rr
  check(rival:fromGen3Trainer(GAME, 901, { noWhiteout = true, done = function(r) rr = r end }),
        "rival: taken")
  drive(rival, function(f) f:pickMove(1) end)
  eq(fieldCalls[1], nil, "rival: no whiteout warp")
  eq(SESSION.money, 500, "rival: no money lost")
  eq(rivalLead.hp, rivalLead.maxHp, "rival: the party healed and the script carries on")
  eq(rr, "lose", "rival: still a loss to the script (VAR_RESULT)")
end

-- (e) RUN: away, refused by the roll, refused by a trap
do
  newGame()
  SESSION.party = { monOf(4, 40) }
  local solo = newSolo()
  local result
  check(solo:fromGen3Encounter(GAME, { species = 16, level = 2 }, { done = function(r) result = r end }),
        "run: taken")
  local ok, fight = drive(solo, function(f) f:sendChoice({ action = "run" }) end)
  check(ok, "run: the fight ended")
  eq(result, "run", "run: done('run') -- the faster runner always gets away")
  check(textOf(fight):find("Got away safely!", 1, true) ~= nil, "run: in the referee's words")

  -- The roll: a slow runner, a fast wild mon, seeds until one fails.
  local failed = false
  for seed = 1, 40 do
    newGame()
    SESSION.party = { monOf(4, 2, { moves = { 45 }, pp = { 40 }, maxPp = { 40 } }) }
    local s = newSolo(seed)
    s:fromGen3Encounter(GAME, { species = 151, level = 70, moves = { 45 } }, {})
    local f = s.fight
    for _ = 1, 40 do f:update(2.0); s:update(0.5, GAME); if f.phase == "choose" then break end end
    local turn = s.sim.turn
    f:sendChoice({ action = "run" })
    for _ = 1, 3 do s:update(0.5, GAME) end
    if s.sim and not s.sim:outcome() then
      failed = true
      local text = table.concat(f.textLog or {}, " | ")
      for _ = 1, 40 do f:update(2.0) end
      check(table.concat(f.textLog or {}, " | "):find("Can't escape!", 1, true) ~= nil
            or text:find("Can't escape!", 1, true) ~= nil,
            "run: a failed roll says \"Can't escape!\"")
      check(s.sim.turn > turn, "run: ...and the turn was spent (the foe moved)")
      s:reset()
      break
    end
    s:reset()
  end
  check(failed, "run: some seed fails the escape roll")

  -- A trap: the wild mon's SHADOW TAG.  The line, the menu back, no turn spent.
  newGame()
  SESSION.party = { monOf(4, 40) }
  local trap = newSolo()
  trap:fromGen3Encounter(GAME, { species = 16, level = 3, ability = 23 }, {})
  local f = trap.fight
  for _ = 1, 40 do f:update(2.0); trap:update(0.5, GAME); if f.phase == "choose" then break end end
  local turn = trap.sim.turn
  f:sendChoice({ action = "run" })
  trap:update(0.5, GAME)
  for _ = 1, 40 do f:update(2.0); if f.phase == "choose" then break end end
  check(textOf(f):find("prevents", 1, true) ~= nil and textOf(f):find("SHADOW TAG", 1, true) ~= nil,
        "trap: 'Wild PIDGEY prevents escape with SHADOW TAG!'")
  eq(trap.sim.turn, turn, "trap: the turn was not spent")
  eq(f.phase, "choose", "trap: the command menu is back")
  trap:reset()
end

-- (f) the after-battle prompts, in order, then `done`
do
  newGame()
  local mon = monOf(4, 16)
  SESSION.party = { mon }
  local solo = newSolo()
  local order = {}
  solo:_afterBattle3(GAME, { { mon = mon, move = 52 } }, { [mon] = true }, function()
    order[#order + 1] = "done"
  end)
  eq(#FakeLearn.begun, 1, "after: the unanswered move-learn prompt opened")
  eq(FakeLearn.begun[1] and FakeLearn.begun[1].battleText, false, "after: in the overworld wording")
  eq(#FakeScene.started, 1, "after: the cart's EvolutionScene for the levelled mon")
  eq(FakeScene.started[1] and FakeScene.started[1].into, 5, "after: ...into what the cart says")
  eq(order[1], "done", "after: done last, once the prompts closed")
  local levels = Solo.levels3(SESSION.party)
  mon.level = 17
  local up = Solo.levelled3(SESSION.party, levels)
  check(up and up[mon], "levelled3: a level gained is seen by identity")
end

-- (g) the mid-fight moveset, and the hand-back
do
  newGame()
  SESSION.party = { monOf(4, 30) }
  local solo = newSolo()
  local result
  solo:fromGen3Encounter(GAME, { species = 16, level = 5 }, { done = function(r) result = r end })
  local sheetMoves = Sheet3.moves({ moves = { 10, 45, 52 }, pp = { 35, 40, 25 }, maxPp = { 35, 40, 25 } })
  check(solo:_applyMoveset3({ mon = 0, moves = sheetMoves }), "moveset: a learned move reaches the referee")
  local simMon = solo.sim.byId.solo_player.mons[1]
  eq(#simMon.moves, 3, "moveset: the referee's copy has the new slot")
  eq(simMon.moves[3].num, 52, "moveset: ...holding the new move")
  eq(solo.sim.byId.solo_player.b.moves, simMon.moves, "moveset: the active battler fights with it")

  local fight = solo.fight
  solo:reset()
  eq(solo:isRunning(), false, "hand back: the fight is let go")
  eq(Gen3Ui.has(fight), false, "hand back: our screen left the stack")
  eq(bridgeCalls[#bridgeCalls] and bridgeCalls[#bridgeCalls][1], "startWild",
     "hand back: the engine's own wild battle starts in its place")
  local handed = bridgeCalls[#bridgeCalls]
  eq(handed and handed[2] and handed[2].species, 16, "hand back: against the same encounter")
  check(handed and handed[3] and type(handed[3].done) == "function", "hand back: with the caller's done")
  eq(result, nil, "hand back: done is the engine battle's to call now")

  -- A save loaded under the fight: nothing to hand back to.
  newGame()
  SESSION.party = { monOf(4, 30) }
  local dropped = newSolo()
  dropped:fromGen3Encounter(GAME, { species = 16, level = 5 }, {})
  SESSION = newSession()
  dropped:reset()
  eq(#bridgeCalls, 0, "reload: nothing restarted over a different save")
end

-- Warnings a scenario provokes on purpose are checked where they happen and
-- then dropped, so the suite's closing "nothing could not" check still
-- covers every other scenario.
local function dropWarnsSince(mark)
  for i = #warns, mark + 1, -1 do warns[i] = nil end
end

local function countIn(list, needle)
  local n = 0
  for _, line in ipairs(list or {}) do
    if type(line) == "string" and line:find(needle, 1, true) then n = n + 1 end
  end
  return n
end

local function indexIn(list, needle)
  for i, line in ipairs(list or {}) do
    if type(line) == "string" and line:find(needle, 1, true) then return i end
  end
  return nil
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

-- (h) Gen 3's one door is `fromGen3*`.  The engine raises no `screen.pushed`
--     on Gen 3, so the Gen 1 / Gen 2 screen divert (`onWildEncounter` /
--     `onTrainerBattle`) declines there; src/Client.lua hands solo the
--     stand-in's monsters instead (`opts.party`, a wild's `enc.mon`), and the
--     fight is fought -- and handed back -- with exactly those.
do
  newGame()
  SESSION.party = { monOf(4, 30) }
  local solo = newSolo()
  local wild = Solo.gen3FoeMon({ species = 16, level = 5 }, { wild = true })
  eq(solo:onWildEncounter(GAME, { kind = "wild", enemyParty = { wild } }, "FR_ROUTE_1"), false,
     "divert: a Gen 3 screen divert is declined -- fromGen3Encounter is the Gen 3 door")
  eq(solo:onTrainerBattle(GAME, { kind = "trainer", enemyParty = { wild } }, "FR_ROUTE_1"), false,
     "divert: ...and fromGen3Trainer the trainer's")
  eq(solo:isRunning(), false, "divert: nothing was started")

  -- enc.mon: the cover's own monster, not a second roll of the species
  local built = Solo.gen3FoeMon({ species = 16, level = 5, personality = 424242 }, { wild = true })
  local rolled = rngState
  check(solo:fromGen3Encounter(GAME, { species = 16, level = 5, mon = built }, {}),
        "prebuilt: a wild with its monster built is taken")
  eq(solo.wildMon, built, "prebuilt: that monster is the one fought and caught")
  eq(rngState, rolled, "prebuilt: nothing was rolled for it a second time")
  solo:reset()
  local handed = bridgeCalls[#bridgeCalls]
  eq(handed and handed[1], "startWild", "prebuilt: handed back to the engine")
  eq(handed and handed[2] and handed[2].personality, 424242,
     "prebuilt: the engine is handed the monster that was fought, personality and all")
  eq(handed and handed[2] and handed[2].ivs, built.ivs, "prebuilt: ...and its IVs")
  eq(handed and handed[2] and handed[2].item, built.item or 0, "prebuilt: ...its held item")
  eq(table.concat((handed and handed[2] and handed[2].moves) or {}, ","), table.concat(built.moves, ","),
     "prebuilt: ...its moves")
  eq(handed and handed[2] and handed[2].mon, nil, "prebuilt: ...as a foe row, not the fought table")
  local row = { species = 16, level = 5, mon = built, personality = 1 }
  local copy = Solo.gen3HandedFoe(row, built)
  eq(row.personality, 1, "gen3HandedFoe: the encounter row is copied, never written")
  check(copy.moves ~= built.moves, "gen3HandedFoe: ...and the move list is the engine's own copy")
  eq(Solo.gen3HandedFoe(row, nil), row, "gen3HandedFoe: no monster, the row as it was")

  -- opts.party (either door): used as it is
  newGame()
  SESSION.party = { monOf(4, 30) }
  local party = Solo.gen3TrainerParty(FakeTrainers.foeFromId(900), 900)
  local tsolo = newSolo()
  check(tsolo:fromGen3Trainer(GAME, 900, { trainerId = 900, party = party }), "prebuilt: a trainer is taken")
  eq(tsolo.gen3 and tsolo.gen3.party, party, "prebuilt: the stand-in's party is the trainer's team")
  tsolo:reset()
  local wsolo = newSolo()
  local lead = Solo.gen3FoeMon({ species = 16, level = 4 }, { wild = true })
  check(wsolo:fromGen3Encounter(GAME, { species = 16, level = 4 }, { party = { lead } }),
        "prebuilt: a wild with opts.party is taken")
  eq(wsolo.wildMon, lead, "prebuilt: opts.party's lead is the wild monster")
  wsolo:reset()
end

-- The hand-back goes through the same divert that offered the fight, which
-- must not be able to hand it straight back to solo (a fight re-diverted into
-- itself forever).  A fallback that asks again, and the engine's own start
-- that asks again, are both told no.
do
  newGame()
  SESSION.party = { monOf(4, 30) }
  local solo = newSolo()
  local again, asked = nil, 0
  local enc = { species = 16, level = 5 }
  local opts = {}
  opts.fallback = function()
    asked = asked + 1
    again = solo:fromGen3Encounter(GAME, enc, {})
  end
  check(solo:fromGen3Encounter(GAME, enc, opts), "handback: taken")
  solo:reset()
  eq(asked, 1, "handback: the caller's fallback started the cart's fight")
  eq(again, false, "handback: the divert it re-entered did not hand it to solo again")
  eq(solo:isRunning(), false, "handback: no second solo fight")
  eq(solo.handingBack3, false, "handback: the guard is down once the start returned")

  local start = FakeBridge.startWild
  local reoffered
  FakeBridge.startWild = function(...)
    reoffered = solo:fromGen3Encounter(GAME, enc, {})
    return start(...)
  end
  check(solo:fromGen3Encounter(GAME, enc, {}), "handback: taken (no fallback)")
  solo:reset()
  FakeBridge.startWild = start
  eq(reoffered, false, "handback: the engine start's own divert declines too")
  eq(solo:isRunning(), false, "handback: ...and nothing is running")
  check(solo:fromGen3Encounter(GAME, enc, {}), "handback: the next encounter is taken as usual")
  solo:reset()
end

-- (i) A draw against a trainer the player is still standing after (a
--     referee's own clock).  The trainerbattle opcode has no answer for it:
--     anything but a loss sets the trainer flag and runs the beaten script,
--     and a loss sets no flag but lets the VM run on into the bytes after the
--     command (a gym leader's TM without the badge) -- the cart's loss only
--     stops there because its whiteout halts the script.  So the waiting
--     script is halted, the opcode is never answered, nobody is whited out,
--     nothing is paid, and the save says B_OUTCOME_DREW -- CoopField's rule.
do
  newGame()
  local lead = monOf(4, 20, { moves = { 10 }, pp = { 35 }, maxPp = { 35 } })
  SESSION.party = { lead }
  SESSION.money = 500
  local solo = newSolo()
  local op = trainerOpcode()
  FakeVm.running = true -- the trainerbattle command waits in the VM
  check(solo:fromGen3Trainer(GAME, 900, { trainerId = 900, done = op.done }), "draw: taken")
  solo.sim:_finish("draw", nil, nil, "timeout")
  local ok, fight = drive(solo, function(f) f:pickMove(1) end)
  check(ok, "draw: the fight ended")
  eq(op.answered, nil, "draw: the trainerbattle opcode is never answered")
  eq(op.postBytes, false, "draw: no post-battle bytes run (no TM without the badge)")
  eq(op.flag, false, "draw: the trainer stays unbeaten")
  eq(FakeVm.halted, 1, "draw: the waiting script is halted instead")
  eq(FakeVm.aborted, true, "draw: ...as aborted, the whiteout's own ending for it")
  eq(SESSION.battleOutcome, FakeNatives.outcome_to_code("draw"), "draw: the save's outcome is DREW")
  eq(SESSION.money, 500, "draw: no prize")
  eq(#fieldCalls, 0, "draw: nobody still standing is whited out")
  check(spaceCalls >= 1, "draw: the field comes back")
  check(not textOf(fight):find("STRINGID_PLAYERGOTMONEY", 1, true), "draw: no money line")
  local ended = effectsOf("emit")[1]
  eq(ended and ended[3].result, "draw", "draw: battle.ended says 'draw'")

  -- The same draw with no script waiting (a fight nothing is waiting on):
  -- nothing to halt, nothing answered.
  newGame()
  SESSION.party = { monOf(4, 20, { moves = { 10 }, pp = { 35 }, maxPp = { 35 } }) }
  local free = newSolo()
  local op2 = trainerOpcode()
  check(free:fromGen3Trainer(GAME, 900, { trainerId = 900, done = op2.done }), "draw (no script): taken")
  free.sim:_finish("draw", nil, nil, "timeout")
  drive(free, function(f) f:pickMove(1) end)
  eq(FakeVm.halted, 0, "draw (no script): nothing running, nothing halted")
  eq(op2.answered, nil, "draw (no script): and nothing answered")

  -- A win still answers the opcode, which sets the flag; a whiteout's loss
  -- answers it after the whiteout has halted the script.
  newGame()
  SESSION.party = { monOf(4, 20, { moves = { 10 }, pp = { 35 }, maxPp = { 35 } }) }
  local won = newSolo()
  local op3 = trainerOpcode()
  FakeVm.running = true
  check(won:fromGen3Trainer(GAME, 900, { trainerId = 900, done = op3.done }), "win: taken")
  drive(won, function(f) f:pickMove(1) end)
  eq(op3.answered, "win", "win: the opcode hears the win")
  eq(op3.flag, true, "win: ...and sets the trainer flag")
  eq(FakeVm.halted, 0, "win: nothing is halted")
end

-- (j) A turn that throws half way through: the referee is left `resolving`,
--     and would call the fight a draw once its resolve clock ran out.  It is
--     handed back to the engine instead, a few frames later.
do
  newGame()
  SESSION.party = { monOf(4, 20, { moves = { 10 }, pp = { 35 }, maxPp = { 35 } }) }
  local solo = newSolo()
  local result
  check(solo:fromGen3Trainer(GAME, 900, { trainerId = 900, done = function(r) result = r end }),
        "stall: taken")
  local fight = toMenu(solo)
  eq(fight.phase, "choose", "stall: at the command menu")
  local mark = #warns
  solo.sim._resolveFights = function() error("a move this build cannot resolve") end
  local okPick = pcall(fight.pickMove, fight, 1)
  check(okPick, "stall: the throw stays out of the screen's menu code")
  for _ = 1, 80 do
    if not solo:isRunning() then break end
    solo:update(0.5, GAME)
  end
  eq(solo:isRunning(), false, "stall: the fight was let go")
  eq(result, nil, "stall: never scored -- not a draw, not a win")
  local last = bridgeCalls[#bridgeCalls]
  eq(last and last[1], "start", "stall: the engine's own trainer battle starts in its place")
  eq(last and last[3] and last[3].trainerId, 900, "stall: ...against the same trainer")
  check(contains(warns, "part way through a turn"), "stall: the log says why")
  dropWarnsSince(mark)
end

-- (k) FireRed's rival and Champion are named by the player: the trainer book
--     answers with `rivalName`, where the row and the foe record carry the
--     cart's placeholder.
do
  newGame({ rivalName = "GARY" })
  SESSION.party = { monOf(4, 20) }
  local rec = Solo.gen3TrainerRecord(FakeTrainers.foeFromId(903), 903, {})
  eq(rec.trainerName, "GARY", "rival: the name the player gave the rival, not the row's placeholder")
  eq(Solo.gen3FoeLabel(rec), "RIVAL GARY", "rival: 'RIVAL GARY would like to battle!'")
  eq(Solo.gen3TrainerRecord(FakeTrainers.foeFromId(903), 903, { rivalName = "BLUE" }).trainerName,
     "BLUE", "rival: the battle opts' rivalName first, as the engine's start passes it")
  eq(Solo.gen3TrainerRecord(FakeTrainers.foeFromId(900), 900, {}).trainerName, "BEN",
     "rival: an ordinary trainer keeps its own name")
  local solo = newSolo()
  check(solo:fromGen3Trainer(GAME, 903, { trainerId = 903 }), "rival: taken")
  eq(solo.fight and solo.fight.peerName, "RIVAL GARY", "rival: the screen names the rival the player named")
  solo:reset()
end

-- (l) The overworld's weather opens a trainer fight too (the engine applies
--     it to every battle off the link), not only a wild one.
do
  newGame()
  SESSION.party = { monOf(4, 20) }
  FakeWeather.id = 3 -- WEATHER_RAIN
  local solo = newSolo()
  check(solo:fromGen3Trainer(GAME, 900, { trainerId = 900 }), "weather: a trainer on a rainy route")
  eq(solo.sim and solo.sim.field and solo.sim.field.weather, "RAIN", "weather: the fight opens in the rain")
  solo:reset()
  local wsolo = newSolo()
  check(wsolo:fromGen3Encounter(GAME, { species = 16, level = 3 }, {}), "weather: a wild on the same route")
  eq(wsolo.sim and wsolo.sim.field and wsolo.sim.field.weather, "RAIN", "weather: ...in the rain as before")
  wsolo:reset()
  -- A live boot's sandbox hands a mod no real `package` (LegacyCompat's
  -- shim: an empty `loaded`).  Sheet3 compiled into such an environment still
  -- reads the field's weather, through the engine require.
  do
    local h = assert(io.open(MOD_PATH .. "/src/Sheet3.lua", "rb"))
    local body = h:read("*a")
    h:close()
    local env = setmetatable({ package = { loaded = {}, preload = {}, path = "", cpath = "" } },
      { __index = _G })
    local chunk = assert(loadstr(body, "@Sheet3.lua"))
    setfenv(chunk, env)
    local Sandboxed = chunk(need, stubMod)
    FakeWeather.id = 13 -- WEATHER_DOWNPOUR
    eq(Sandboxed.fieldWeather(), "RAIN", "weather: a sandboxed Sheet3 still sees the downpour")
    eq(Sandboxed.ruleset(GAME, { wild = true }).weather, "RAIN",
       "weather: ...and a co-op / hub wild fight's ruleset opens in it")
    FakeWeather.id = 8 -- WEATHER_SANDSTORM
    eq(Sandboxed.fieldWeather(), "SAND", "weather: the sandstorm")
    FakeWeather.id = 12 -- WEATHER_DROUGHT
    eq(Sandboxed.fieldWeather(), "SUN", "weather: the drought")
  end
  FakeWeather.id = 0
  local dry = newSolo()
  check(dry:fromGen3Trainer(GAME, 900, { trainerId = 900 }), "weather: a trainer under a clear sky")
  eq(dry.sim and dry.sim.field and dry.sim.field.weather, nil, "weather: no weather when the field has none")
  dry:reset()
end

-- (m) PAY DAY.  The coins are the screen's to pay (MediatedBattle's Gen 3
--     `payDay3`, fed the local referee's outcome), once, after the knockout,
--     with the cart's line -- after a trainer's prize line, as
--     BattleScript_LocalTrainerBattleWon says it.  This file pays nothing more.
do
  newGame()
  SESSION.party = { monOf(4, 20, { moves = { 6 }, pp = { 20 }, maxPp = { 20 } }) }
  SESSION.money = 1000
  local solo = newSolo()
  local result
  check(solo:fromGen3Encounter(GAME, { species = 16, level = 2 }, { done = function(r) result = r end }),
        "payday: a wild fight with PAY DAY")
  local ok, fight = drive(solo, function(f) f:pickMove(1) end)
  check(ok, "payday: the fight ended")
  eq(result, "win", "payday: won by the knockout")
  eq(SESSION.money, 1000 + 20 * 5, "payday: level x 5 coins, paid once")
  eq(countIn(fight.textLog, "STRINGID_PLAYERPICKEDUPMONEY|100"), 1, "payday: 'ANN picked up ¥100!', once")

  newGame()
  SESSION.party = { monOf(4, 20, { moves = { 6 }, pp = { 20 }, maxPp = { 20 } }) }
  SESSION.money = 500
  local tsolo = newSolo()
  check(tsolo:fromGen3Trainer(GAME, 900, { trainerId = 900 }), "payday: a trainer fight with PAY DAY")
  local okT, tfight = drive(tsolo, function(f) f:pickMove(1) end)
  check(okT, "payday: the trainer fight ended")
  local prize = Prize.calc(900, { lastLevel = 3 })
  eq(SESSION.money, 500 + prize + 20 * 5, "payday: the prize and the coins, each once")
  local prizeAt = indexIn(tfight.textLog, "STRINGID_PLAYERGOTMONEY")
  local coinsAt = indexIn(tfight.textLog, "STRINGID_PLAYERPICKEDUPMONEY")
  check(prizeAt and coinsAt and prizeAt < coinsAt, "payday: the coins' line comes after the prize line",
        tostring(prizeAt) .. " / " .. tostring(coinsAt))
  eq(countIn(tfight.textLog, "STRINGID_PLAYERPICKEDUPMONEY"), 1, "payday: ...once")
end

-- (n) The early rival's loss: the rival's victory speech first
--     (BattleScript_LocalBattleLost's early-rival arm), and with the heal-after
--     flag nothing more -- no lost lines, no warp.
do
  newGame()
  local rivalLead = monOf(4, 5, { moves = { 10 }, pp = { 35 }, maxPp = { 35 }, hp = 3 })
  SESSION.party = { rivalLead }
  SESSION.money = 500
  local solo = newSolo()
  local result
  check(solo:fromGen3Trainer(GAME, 901, { trainerId = 901, earlyRival = true, rivalFlags = 1,
    victoryText = "HA! LOOK AT THAT!", done = function(r) result = r end }), "rival loss: taken")
  local _, fight = drive(solo, function(f) f:pickMove(1) end)
  eq(countIn(fight.textLog, "HA! LOOK AT THAT!"), 1, "rival loss: the rival's victory speech")
  check(not textOf(fight):find("STRINGID_PLAYERLOSTAGAINSTENEMYTRAINER", 1, true),
        "rival loss: a heal-after fight says nothing more")
  eq(#fieldCalls, 0, "rival loss: no whiteout")
  eq(rivalLead.hp, rivalLead.maxHp, "rival loss: healed")
  eq(result, "lose", "rival loss: the script hears it lost (VAR_RESULT)")

  newGame()
  SESSION.party = { monOf(4, 5, { moves = { 10 }, pp = { 35 }, maxPp = { 35 }, hp = 3 }) }
  local hard = newSolo()
  check(hard:fromGen3Trainer(GAME, 901, { trainerId = 901, earlyRival = true, rivalFlags = 0,
    victoryText = "HA! LOOK AT THAT!" }), "rival loss (no heal): taken")
  local _, hardFight = drive(hard, function(f) f:pickMove(1) end)
  local speechAt = indexIn(hardFight.textLog, "HA! LOOK AT THAT!")
  local lostAt = indexIn(hardFight.textLog, "STRINGID_PLAYERLOSTAGAINSTENEMYTRAINER")
  check(speechAt and lostAt and speechAt < lostAt, "rival loss (no heal): the speech, then the lost lines")
  eq(fieldCalls[1], "respawn", "rival loss (no heal): the whiteout")

  -- An ordinary trainer's loss has no speech in it.
  newGame()
  SESSION.party = { monOf(4, 5, { moves = { 10 }, pp = { 35 }, maxPp = { 35 }, hp = 3 }) }
  local plain = newSolo()
  check(plain:fromGen3Trainer(GAME, 901, { trainerId = 901, victoryText = "HA! LOOK AT THAT!" }),
        "plain loss: taken")
  local _, plainFight = drive(plain, function(f) f:pickMove(1) end)
  eq(countIn(plainFight.textLog, "HA! LOOK AT THAT!"), 0, "plain loss: no victory speech")
end

-- (o) The map's resume scripts run once the after-battle prompts have
--     closed, right before `done` -- not under an evolution or a learn prompt.
do
  newGame()
  SESSION.party = { monOf(4, 20, { moves = { 10 }, pp = { 35 }, maxPp = { 35 } }) }
  local solo = newSolo()
  local order = {}
  local realField = FakeSpace.returnToField
  FakeSpace.returnToField = function() order[#order + 1] = "field" end
  solo._afterBattle3 = function(_, _, _, _, finish)
    order[#order + 1] = "prompts"
    return finish()
  end
  check(solo:fromGen3Encounter(GAME, { species = 16, level = 2 },
    { done = function() order[#order + 1] = "done" end }), "order: taken")
  drive(solo, function(f) f:pickMove(1) end)
  FakeSpace.returnToField = realField
  eq(table.concat(order, ","), "prompts,field,done",
     "order: the prompts, then the map's resume scripts, then done")
end

-- (p) What the engine does as its own battle ends, done for one it did not
--     run: FireRed's quest log and `battle.ended` (the engine's payload); on
--     Emerald, Pokérus and the TV instead of the quest log.
do
  newGame()
  local lead = monOf(4, 20, { moves = { 10 }, pp = { 35 }, maxPp = { 35 } })
  SESSION.party = { lead }
  local solo = newSolo()
  check(solo:fromGen3Encounter(GAME, { species = 16, level = 2 }, {}), "effects: a FireRed wild win")
  local wild = solo.wildMon
  drive(solo, function(f) f:pickMove(1) end)
  local ql = effectsOf("questlog")[1]
  check(ql ~= nil, "effects: the quest log records the win")
  eq(ql and ql[2], SESSION, "effects: ...on the session")
  eq(ql and ql[3].result, "win", "effects: ...as a win")
  eq(ql and ql[3].wild, true, "effects: ...against a wild")
  eq(ql and ql[3].enemy and ql[3].enemy.mon, wild, "effects: ...naming the wild monster")
  eq(ql and ql[3].player and ql[3].player.mon, lead, "effects: ...and ours")
  local ended = effectsOf("emit")[1]
  eq(ended and ended[2], "battle.ended", "effects: battle.ended is raised")
  eq(ended and ended[3].result, "win", "effects: ...with the result")
  eq(ended and ended[3].battle and ended[3].battle.wild, true, "effects: ...and the battle's state")
  eq(ended and ended[3].battle.enemy.mon.species, 16, "effects: ...whose foe is the wild monster")
  eq(ended and ended[3].battle.link, false, "effects: ...off the link")
  eq(#effectsOf("pokerus.give"), 0, "effects: no Pokérus on FireRed")
  eq(#effectsOf("rse"), 0, "effects: no TV on FireRed")

  -- a trainer: the quest log names the trainer
  newGame()
  SESSION.party = { monOf(4, 20, { moves = { 10 }, pp = { 35 }, maxPp = { 35 } }) }
  local tsolo = newSolo()
  check(tsolo:fromGen3Trainer(GAME, 900, { trainerId = 900 }), "effects: a FireRed trainer win")
  drive(tsolo, function(f) f:pickMove(1) end)
  local tql = effectsOf("questlog")[1]
  eq(tql and tql[3].trainerName, "BEN", "effects: the quest log names the trainer")
  eq(tql and tql[3].trainerClass, 57, "effects: ...and its class (the gym / E4 / Champion lines)")
  eq(tql and tql[3].wild, false, "effects: ...a trainer fight")

  -- Emerald: Pokérus and the TV, with the session first
  newGame()
  SESSION.party = { monOf(4, 30) }
  FakeBag.add(SESSION.bag, 1, 1)
  PROFILE.family = "rse"
  local em = newSolo()
  check(em:fromGen3Encounter(GAME, { species = 16, level = 5 }, {}), "effects (rse): a wild to catch")
  local emWild = em.wildMon
  local thrown = false
  drive(em, function(f)
    if not thrown then
      thrown = true
      f.itemPick = { id = 1, effect = Sheet3.itemEffect(1) }
      f:commitItem(nil, nil)
    else
      f:pickMove(1)
    end
  end)
  PROFILE.family = "frlg"
  eq(#effectsOf("pokerus.give"), 1, "effects (rse): the party may catch Pokérus")
  eq(#effectsOf("pokerus.spread"), 1, "effects (rse): ...and spread it")
  eq(#effectsOf("questlog"), 0, "effects (rse): no quest log on Emerald")
  local tv = effectsOf("rse")[1]
  eq(tv and tv[2], "tv", "effects (rse): the TV is told")
  eq(tv and tv[3], "onBattleEnd", "effects (rse): ...onBattleEnd")
  eq(tv and tv[6], SESSION, "effects (rse): ...with the session first, as the TV reads it")
  eq(tv and tv[7] and tv[7].caughtMonSpecies, 16, "effects (rse): ...the catch")
  eq(tv and tv[7] and tv[7].usedMasterBall, true, "effects (rse): ...in a MASTER BALL")
  eq(tv and tv[7] and tv[7].lastUsedItem, 1, "effects (rse): ...the last ball thrown")
  eq(tv and tv[8], FakeNatives.outcome_to_code("caught"), "effects (rse): ...B_OUTCOME_CAUGHT")
  eq(tv and tv[9] and tv[9].trainer, false, "effects (rse): ...a wild battle")
  local emEnded = effectsOf("emit")[1]
  eq(emEnded and emEnded[3].result, "catch", "effects (rse): battle.ended says 'catch', the engine's word")
  eq(emEnded and emEnded[3].battle.enemy.mon, emWild, "effects (rse): ...naming the caught monster")
end

-- (q) A screen the modal stack will not take is not a fight: the caller is
--     told no (and fights the cart's battle), and nothing is left running.
do
  newGame()
  SESSION.party = { monOf(4, 20) }
  local mark = #warns
  local refusing = setmetatable({ pushState = function() return nil end }, { __index = UI })
  local solo = Solo.new(refusing, { enabled = function() return true end, seed = function() return 7 end })
  eq(solo:fromGen3Encounter(GAME, { species = 16, level = 3 }, {}), false,
     "push: a fight whose screen could not go up is declined")
  eq(solo:isRunning(), false, "push: nothing is running")
  eq(solo.gen3, nil, "push: no half-built fight is left behind")
  eq(encounterResets, 0, "push: the encounter cooldown was not spent on it")
  check(contains(warns, "could not be opened"), "push: the log says why")
  dropWarnsSince(mark)
  check(solo:fromGen3Trainer(GAME, 900, { trainerId = 900 }) == false, "push: a trainer the same way")
  dropWarnsSince(mark)
end

-- (r) A POKé DOLL is the player's escape (B_OUTCOME_RAN), though the referee
--     names the thrower's side the winners.
do
  newGame()
  SESSION.party = { monOf(4, 20) }
  ITEMS[80] = { name = "POKe DOLL", pocket = "ITEMS", price = 1000 }
  FakeBag.add(SESSION.bag, 80, 1)
  local solo = newSolo()
  local result
  check(solo:fromGen3Encounter(GAME, { species = 16, level = 5 }, { done = function(r) result = r end }),
        "doll: taken")
  local thrown = false
  drive(solo, function(f)
    if not thrown then
      thrown = true
      f.itemPick = { id = 80, effect = Sheet3.itemEffect(80) }
      f:commitItem(nil, nil)
    else
      f:pickMove(1)
    end
  end)
  eq(result, "run", "doll: done('run') -- the player got away, the wild monster did not flee")
  eq(SESSION.battleOutcome, FakeNatives.outcome_to_code("run"), "doll: B_OUTCOME_RAN on the save")
end

-- (s) The badges ride on our side for a referee that uses them (BattleSim3
--     does not: link rules, sheet doc §6).
do
  newGame({ badges = { [1] = true, [3] = true } })
  local b = Solo.gen3Badges()
  check(b and b[1] and b[3] and not b[2], "badges: the save's badge flags, by number")
  newGame()
  eq(Solo.gen3Badges(), nil, "badges: none held, none sent")
end

-- Nothing of Gen 1's engine was reached on a Gen 3 boot.
check(package.loaded["src.battle.BattleState"] == nil, "no Gen 1 BattleState on a Gen 3 boot")
check(package.loaded["src.battle.TrainerAI"] == nil, "no Gen 1 TrainerAI on a Gen 3 boot")
check(not contains(warns, "ERROR"), "no error was logged: " .. table.concat(warns, " / "))
check(not contains(warns, "could not"), "no fallback warning fired: " .. table.concat(warns, " / "))

unstubAll()
T.finish("gen3_solo")
