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
--      the send-out; and a lone double's two trainer seats on the shared-team
--      referee (FireRed's random flank, Emerald's scored targets and
--      AI_DoubleBattle, claim-aware switching and send-outs, a Ghost CURSE
--      aimed at the foe opposite).
--   2. SoloBattle, Gen 3: a wild fight to a catch, a trainer fight to a win
--      (prize money, exp, the `done` the trainer script resumes on), a loss to
--      the whiteout, RUN (away, refused by the roll, refused by a trap), the
--      refusals, the after-battle prompts, the hand-back, and the mid-fight
--      moveset.
--   3. SoloBattle, Gen 3, the lone double: the take-over decision and the
--      hand-backs, the seats (two a side over one shared team), the choices
--      filed per seat, the trainer's answers for both seats, refills from the
--      shared bench, the ending (prize x2, EXP, reconcile, the TV, whiteout,
--      draw) and the hand-back that puts the party back -- first on a
--      stand-in for the double screen, then on CoopBattle's real one.
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
do
  -- Prefer this suite's checkout: the engine's installed mod symlink may
  -- point at an older tree with SoloBattle but without the Gen 3 modules.
  local src = debug.getinfo(1, "S").source
  if type(src) == "string" and src:sub(1, 1) == "@" then
    local dir = src:sub(2):match("(.+)[/\\]")
    if dir then
      local candidate = dir:gsub("[/\\]tests$", "")
      local h = io.open(candidate .. "/src/Sheet3.lua", "rb")
      if h then
        h:close()
        MOD_PATH = candidate
      end
    end
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

-- ------- a lone double: the trainer's two seats, one brain (contract C2 of
--         docs/plans/gen3-solo-doubles.md)
--
-- The shared-team referee (`seats = 2` on a side) and a view shaped as
-- SoloBattle:_foeView3 shapes it: `double`, the choosing seat's field slot,
-- the living `partner`, the player's standing battlers as `foes`, and the
-- party indices the sibling seat has `claimed`.  Section 3 holds the other end
-- of that contract -- the view a real fight hands the brain.

do
  local FR = Brain.AI_BITS_FRLG
  local function highRng(lo, hi) if hi == nil then return 1 end return hi end
  -- answers the queued values first (clamped into the range asked), then the
  -- bottom of every range
  local function queued(values)
    local q = { table.unpack and table.unpack(values) or unpack(values) }
    return function(lo, hi)
      if hi == nil then lo, hi = 1, lo end
      if #q > 0 then
        local v = table.remove(q, 1)
        if v < lo then v = lo end
        if v > hi then v = hi end
        return v
      end
      return lo
    end
  end
  -- a seeded LCG with rng(lo, hi) / rng(n) semantics
  local function seeded(seed)
    local state = seed % 2147483647
    if state <= 0 then state = state + 2147483646 end
    return function(lo, hi)
      if hi == nil then lo, hi = 1, lo end
      if hi < lo then return lo end
      state = (state * 48271) % 2147483647
      return lo + (state % (hi - lo + 1))
    end
  end

  -- The trainer's shared team on side b (two seats), the player's on side a,
  -- and the C2 view for trainer seat `which` (1 or 2).
  local function lone(npc, player, extra)
    extra = extra or {}
    local battle = assert(Sim.Turn.create({
      id = "dbl", mode = "coop_npc", seed = extra.seed or 3, typeTable = CHART,
      weather = extra.weather,
      sides = {
        a = { { playerId = "p", name = "P", seats = extra.playerSeats or 2, mons = player } },
        b = { { playerId = "n", name = "N", seats = extra.npcSeats or 2, mons = npc, bag = extra.bag } },
      },
    }))
    battle:drainEvents()
    local function viewFor(which, claimed)
      local me = battle.byId[which == 2 and "n#2" or "n"]
      local mate = battle.byId[which == 2 and "n" or "n#2"]
      local foes = {}
      for _, id in ipairs({ "p", "p#2" }) do
        local f = battle.byId[id]
        if f and f.b and f.b.mon.hp > 0 then foes[#foes + 1] = { slot = f.slot, battler = f.b } end
      end
      return {
        sim = battle, battler = me.b, foeBattler = foes[1] and foes[1].battler or nil, fighter = me,
        mon = me.b and me.b.mon or (me.lastB and me.lastB.mon), foe = foes[1] and foes[1].battler.mon,
        party = me.mons, active = me.active, bag = me.bag,
        double = true, seat = me.slot, partner = mate and mate.b or nil,
        foes = foes, claimed = claimed or {},
      }
    end
    return battle, viewFor
  end

  local function tackle() return mv(33, { power = 40, type = 0 }) end

  -- --- FireRed / LeafGreen: one random flank (Random() & 2, flipped when empty)
  do
    -- slot 0 a Ghost (a Normal move is -10 into it), slot 1 a Normal
    local npc = { sheet({ slot = 0, moves = { tackle(), mv(52, { power = 40, type = 10 }) } }), sheet({ slot = 1 }) }
    local player = { sheet({ slot = 0, types = { 7 } }), sheet({ slot = 1, types = { 0 } }) }
    local _, viewFor = lone(npc, player)
    local left = brain3(1, { aiBits = FR, rng = queued({ 0 }) }):choose(viewFor(1))
    eq(left and left.target, 0, "brain3 double: FireRed's flank roll, left -> the left position, slot 0")
    eq(left and left.move, 1, "brain3 double: ...and the scripts score against that flank (Tackle into the Ghost is out)")
    local right = brain3(1, { aiBits = FR, rng = queued({ 1 }) }):choose(viewFor(1))
    eq(right and right.target, 1, "brain3 double: the roll, right -> slot 1")
    eq(right and right.move, 0, "brain3 double: ...where Tackle is fine (a tie goes to the first move)")
    eq(left and left.action, "fight", "brain3 double: a fight, aimed")
  end

  do -- the flip when the rolled flank is empty, either way
    local npc = { sheet({ slot = 0, moves = { tackle() } }), sheet({ slot = 1 }) }
    local player = { sheet({ slot = 0 }), sheet({ slot = 1 }) }
    local battle, viewFor = lone(npc, player)
    battle.byId.p.b.mon.hp = 0
    eq(brain3(1, { aiBits = FR, rng = queued({ 0 }) }):choose(viewFor(1)).target, 1,
       "brain3 double: the rolled flank is empty (left down) -> flipped to slot 1")
    local battle2, viewFor2 = lone(npc, player)
    battle2.byId["p#2"].b.mon.hp = 0
    eq(brain3(1, { aiBits = FR, rng = queued({ 1 }) }):choose(viewFor2(1)).target, 0,
       "brain3 double: the rolled flank is empty (right down) -> flipped to slot 0")
    eq(brain3(1, { aiBits = FR, rng = queued({ 0 }) }):choose(viewFor2(1)).target, 0,
       "brain3 double: ...and a flank that stands is taken as rolled")
  end

  do -- the distribution: both flanks, deterministic per seed, never the partner
    local npc = { sheet({ slot = 0, moves = { tackle() } }), sheet({ slot = 1 }) }
    local player = { sheet({ slot = 0 }), sheet({ slot = 1 }) }
    local _, viewFor = lone(npc, player)
    local seen, other, differing = { [0] = 0, [1] = 0 }, 0, 0
    for seed = 1, 200 do
      local a = brain3(1, { aiBits = FR, rng = seeded(seed) }):choose(viewFor(1))
      local b = brain3(1, { aiBits = FR, rng = seeded(seed) }):choose(viewFor(1))
      if not (a and b and a.target == b.target and a.move == b.move and a.action == b.action) then
        differing = differing + 1
      end
      if a and seen[a.target] then seen[a.target] = seen[a.target] + 1 else other = other + 1 end
    end
    check(seen[0] > 60 and seen[1] > 60, "brain3 double: FireRed draws both flanks ("
          .. seen[0] .. " / " .. seen[1] .. " of 200)")
    eq(other, 0, "brain3 double: ...never its partner, never an unaimed fight move")
    eq(differing, 0, "brain3 double: the same seed answers the same")
  end

  do -- FireRed's DOUBLE_BATTLE script is a bare `end`: a partner is not avoided
    local quake = mv(89, { power = 100, type = 4, target = 32 })
    local npc = { sheet({ slot = 0, moves = { quake, quake } }), sheet({ slot = 1, types = { 10 } }) }
    local _, viewFor = lone(npc, { sheet({ slot = 0 }), sheet({ slot = 1 }) })
    local b = brain3(1 + 128, { aiBits = FR })
    b:choose(viewFor(1))
    eq(b.lastScores3 and b.lastScores3[1], 100, "brain3 double: FireRed's DOUBLE_BATTLE bit scores nothing")
  end

  -- --- Emerald: every battler scored, the best target wins
  do
    local function run(lowSlot)
      local npc = { sheet({ slot = 0, moves = { mv(33, { power = 80, type = 0 }) } }), sheet({ slot = 1 }) }
      local player = { sheet({ slot = 0, hp = lowSlot == 0 and 5 or 100 }),
                       sheet({ slot = 1, hp = lowSlot == 1 and 5 or 100 }) }
      local _, viewFor = lone(npc, player)
      local b = brain3(2, { aiBits = EM_BITS })   -- Emerald's bit 1 is TRY_TO_FAINT
      return b:choose(viewFor(1)), b
    end
    local c1, b1 = run(1)
    eq(c1 and c1.target, 1, "brain3 double: Emerald aims at the target it can knock out (slot 1)")
    eq(b1.lastScores3 and b1.lastScores3[1], 104, "brain3 double: ...scored +4 against that one")
    eq((run(0)).target, 0, "brain3 double: ...and at slot 0 when that one is the low one")

    local npc = { sheet({ slot = 0, moves = { tackle() } }), sheet({ slot = 1 }) }
    local _, viewFor = lone(npc, { sheet({ slot = 0 }), sheet({ slot = 1 }) })
    eq(brain3(1, { aiBits = EM_BITS, rng = lowRng }):choose(viewFor(1)).target, 0,
       "brain3 double: equal targets are drawn at random -- a low roll, slot 0")
    eq(brain3(1, { aiBits = EM_BITS, rng = highRng }):choose(viewFor(1)).target, 1,
       "brain3 double: ...a high roll, slot 1")
  end

  do -- the partner pass: a Fire move into a FLASH FIRE ally that has not lit
    local fire = mv(53, { power = 90, type = 10 })
    local npc = { sheet({ slot = 0, moves = { tackle(), fire } }), sheet({ slot = 1, ability = 18 }) }
    local battle, viewFor = lone(npc, { sheet({ slot = 0 }), sheet({ slot = 1 }) })
    local b = brain3(1, { aiBits = EM_BITS })
    local c = b:choose(viewFor(1))
    eq(c and c.target, 4, "brain3 double: Emerald feeds a FLASH FIRE partner the Fire move (its slot, 4)")
    eq(c and c.move, 1, "brain3 double: ...the Fire move")
    eq(b.lastScores3 and b.lastScores3[2], 103, "brain3 double: ...at 103 (AI_TryOnAlly, run because it is a double)")
    eq(b.lastScores3 and b.lastScores3[1], 70, "brain3 double: ...and Tackle at 70 against the ally")
    battle.byId["n#2"].b.flashFire = true
    local lit = brain3(1, { aiBits = EM_BITS }):choose(viewFor(1))
    check(lit and lit.target ~= 4, "brain3 double: a partner whose FLASH FIRE has lit is not fed another")
    -- the same pair seen from seat 2: its partner is slot 3
    local npc2 = { sheet({ slot = 0, ability = 18 }), sheet({ slot = 1, moves = { tackle(), fire } }) }
    local _, viewFor2 = lone(npc2, { sheet({ slot = 0 }), sheet({ slot = 1 }) })
    eq(brain3(1, { aiBits = EM_BITS }):choose(viewFor2(2)).target, 3,
       "brain3 double: seat 2 aims at its partner on slot 3")
    -- FireRed's script has no such pass: the same Fire move is aimed at a foe
    local _, viewFr = lone(npc, { sheet({ slot = 0 }), sheet({ slot = 1 }) })
    local fr = brain3(1, { aiBits = FR, rng = queued({ 0 }) }):choose(viewFr(1))
    eq(fr and fr.target, 0, "brain3 double: FireRed never aims at its partner")
    -- Emerald ORs AI_DoubleBattle into every double's flags: a trainer row with
    -- no script bit at all still prices the partner (and one that FireRed
    -- would leave to the flank roll alone)
    local _, viewBare = lone(npc, { sheet({ slot = 0 }), sheet({ slot = 1 }) })
    local bare = brain3(0, { aiBits = EM_BITS }):choose(viewBare(1))
    eq(bare and bare.target, 4, "brain3 double: Emerald runs the double script for a trainer with no AI flags")
    local _, viewBareFr = lone(npc, { sheet({ slot = 0 }), sheet({ slot = 1 }) })
    local bareFr = brain3(0, { aiBits = FR, rng = queued({ 1 }) }):choose(viewBareFr(1))
    eq(bareFr and bareFr.target, 1, "brain3 double: FireRed with no AI flags is the flank roll alone")
  end

  do -- the partner pass counts only at 100 or more (the cart sets a lower best to -1)
    -- the scorer is stood in for, so the choice among the passes is what is read
    local npc = { sheet({ slot = 0, moves = { tackle() } }), sheet({ slot = 1 }) }
    local _, viewFor = lone(npc, { sheet({ slot = 0 }), sheet({ slot = 1 }) })
    local function pick(allyScore, foeScore)
      local b = brain3(1, { aiBits = EM_BITS })
      b._scoreMoves3 = function(_, ctx, legal)
        local scores = {}
        for _, i in ipairs(legal) do scores[i] = ctx.tIsAlly and allyScore or foeScore end
        return scores
      end
      return b:choose(viewFor(1))
    end
    eq(pick(70, 60).target, 0, "brain3 double: a partner pass under 100 loses even to a worse foe pass")
    eq(pick(99, 60).target, 0, "brain3 double: ...at 99 too")
    eq(pick(100, 60).target, 4, "brain3 double: ...at exactly 100 it counts, and beats a worse foe pass")
    eq(pick(105, 100).target, 4, "brain3 double: ...a partner pass at 100 or more is a real candidate, and the best")
    eq(pick(100, 120).target, 0, "brain3 double: ...and a better foe pass still beats it")
  end

  do -- AI_DoubleBattle: a spread move beside a partner it would hit
    local quake = function() return mv(89, { power = 100, type = 4, target = 32 }) end
    local function score(partnerFields, extra)
      local npc = { sheet({ slot = 0, moves = { quake(), tackle() } }), sheet(partnerFields) }
      local _, viewFor = lone(npc, { sheet({ slot = 0 }), sheet({ slot = 1 }) }, extra)
      local b = brain3(1, { aiBits = EM_BITS })
      local c = b:choose(viewFor(1))
      return b.lastScores3 and b.lastScores3[1], c
    end
    eq((score({ slot = 1, types = { 10 } })), 90, "brain3 double: EARTHQUAKE beside a Fire partner is marked down (-10)")
    eq((score({ slot = 1, types = { 13 } })), 90, "brain3 double: ...an Electric one")
    eq((score({ slot = 1, types = { 3 } })), 90, "brain3 double: ...a Poison one")
    eq((score({ slot = 1, types = { 5 } })), 90, "brain3 double: ...a Rock one")
    eq((score({ slot = 1, types = { 2 } })), 102, "brain3 double: ...a Flying partner is out of its reach (+2)")
    eq((score({ slot = 1, ability = 26 })), 102, "brain3 double: ...so is a LEVITATE one")
    local s, c = score({ slot = 1, types = { 0 } })
    eq(s, 97, "brain3 double: ...anyone else is hit for a small cost (-3)")
    eq(c and c.move, 1, "brain3 double: ...so the trainer uses Tackle instead")
    eq(c and c.target ~= nil, true, "brain3 double: ...aimed at a foe")
    local _, fly = score({ slot = 1, types = { 2 } })
    eq(fly and fly.move, 0, "brain3 double: EARTHQUAKE beside a Flying partner is taken")
    eq(fly and fly.target, nil, "brain3 double: ...and a spread move names no target")
    -- a trainer with one monster: the empty position reads as zeroes (-3)
    local npc1 = { sheet({ slot = 0, moves = { quake(), tackle() } }) }
    local _, vf1 = lone(npc1, { sheet({ slot = 0 }), sheet({ slot = 1 }) }, { npcSeats = 1 })
    local b1 = brain3(1, { aiBits = EM_BITS })
    b1:choose(vf1(1))
    eq(b1.lastScores3 and b1.lastScores3[1], 97, "brain3 double: an empty partner position costs the same small -3")
  end

  do -- check_ability on the target's partner: LIGHTNING ROD
    local bolt = mv(85, { power = 95, type = 13 })
    local npc = { sheet({ slot = 0, moves = { bolt } }), sheet({ slot = 1 }) }
    local player = { sheet({ slot = 0, types = { 0 }, ability = 5 }), sheet({ slot = 1, ability = 31 }) }
    local _, viewFor = lone(npc, player)
    local b = brain3(1, { aiBits = EM_BITS, rng = queued({}) })
    local c = b:choose(viewFor(1))
    eq(c and c.target, 1, "brain3 double: with LIGHTNING ROD on slot 1, the bolt's best target is the rod itself")
  end

  -- --- AI_CheckBadMove in a double
  do
    local helping = mv(270, { power = 0, effect = 176, target = 16 })
    local _, viewFor = lone({ sheet({ slot = 0, moves = { helping } }), sheet({ slot = 1 }) },
                            { sheet({ slot = 0 }), sheet({ slot = 1 }) })
    local b = brain3(1, { aiBits = FR })
    local c = b:choose(viewFor(1))
    eq(b.lastScores3 and b.lastScores3[1], 100, "brain3 double: HELPING HAND is not written off in a double")
    eq(c and c.target, nil, "brain3 double: ...and a move on the user names no target")

    -- EXPLOSION: the player's own partner is not a reserve
    local boom = mv(153, { power = 250, effect = 7, target = 32 })
    local npc = { sheet({ slot = 0, moves = { boom, tackle() } }), sheet({ slot = 1 }) }
    local _, withReserve = lone(npc, { sheet({ slot = 0 }), sheet({ slot = 1 }), sheet({ slot = 2 }) })
    local br = brain3(1, { aiBits = FR })
    br:choose(withReserve(1))
    eq(br.lastScores3 and br.lastScores3[1], 90, "brain3 double: no EXPLOSION while the player still has a reserve")
    local _, noReserve = lone(npc, { sheet({ slot = 0 }), sheet({ slot = 1 }) })
    local bn = brain3(1, { aiBits = FR })
    bn:choose(noReserve(1))
    eq(bn.lastScores3 and bn.lastScores3[1], 100, "brain3 double: ...and the player's own partner is not a reserve")
  end

  -- --- switching and the send-out: never an active, never a claimed monster
  do
    local npc = { sheet({ slot = 0 }), sheet({ slot = 1 }), sheet({ slot = 2 }), sheet({ slot = 3 }) }
    local battle, viewFor = lone(npc, { sheet({ slot = 0 }), sheet({ slot = 1 }) })
    battle.byId.n.b.perishTurns = 0
    local c = brain3(1, { aiBits = FR }):choose(viewFor(1))
    eq(c and c.action, "switch", "brain3 double: a seat whose perish count ran out switches")
    check(c and c.slot ~= 0 and c.slot ~= 1,
          "brain3 double: ...never into either monster already out (got " .. tostring(c and c.slot) .. ")")
    local c2 = brain3(1, { aiBits = FR }):choose(viewFor(1, { [3] = true }))
    eq(c2 and c2.slot, 3, "brain3 double: ...nor into the one its sibling seat claimed")
    local c3 = brain3(1, { aiBits = FR }):choose(viewFor(1, { [3] = true, [4] = true }))
    check(c3 == nil or c3.action ~= "switch", "brain3 double: ...and with nothing unclaimed left, it stays in")
  end

  do -- the forced send-out
    local npc = { sheet({ slot = 0 }), sheet({ slot = 1 }), sheet({ slot = 2 }), sheet({ slot = 3 }) }
    local _, viewFor = lone(npc, { sheet({ slot = 0 }), sheet({ slot = 1 }) })
    local v = viewFor(1)
    v.mon.hp = 0
    v.mustReplace = true
    local c = brain3(1, { aiBits = FR }):choose(v)
    eq(c and c.action, "switch", "brain3 double: an emptied seat asks for a send-out")
    check(c and c.slot >= 2, "brain3 double: ...never the partner's monster (got " .. tostring(c and c.slot) .. ")")
    v.claimed = { [3] = true }
    eq(brain3(1, { aiBits = FR }):choose(v).slot, 3,
       "brain3 double: ...nor the monster its sibling seat claimed (party index 3): the fourth, slot 3, is left")
    v.claimed = { [3] = true, [4] = true }
    eq(brain3(1, { aiBits = FR }):choose(v), nil,
       "brain3 double: ...and with nothing left it gives no answer (the referee leaves the seat empty)")
  end

  do -- the send-out's typing reads one random flank of the player's
    local grass = sheet({ slot = 2, types = { 12 }, moves = { mv(55, { power = 40, type = 11 }) } })
    local firem = sheet({ slot = 3, types = { 10 }, moves = { mv(22, { power = 40, type = 12 }) } })
    local npc = { sheet({ slot = 0 }), sheet({ slot = 1 }), grass, firem }
    local player = { sheet({ slot = 0, types = { 10 } }), sheet({ slot = 1, types = { 11 } }) }
    local _, viewFor = lone(npc, player)
    local v = viewFor(1)
    v.mon.hp = 0
    v.mustReplace = true
    eq(brain3(1, { aiBits = FR, rng = queued({ 0 }) }):choose(v).slot, 2,
       "brain3 double: against the Fire flank the send-out is the Grass monster with a Water move")
    eq(brain3(1, { aiBits = FR, rng = queued({ 1 }) }):choose(v).slot, 3,
       "brain3 double: ...against the Water flank, the Fire monster with a Grass move")
  end

  -- --- the 1v1 view is untouched: no `double`, no target on any answer
  do
    local npc = { sheet({ moves = { mv(1, { power = 40 }), mv(2, { power = 200 }) } }) }
    local _, view = field(npc, sheet({ hp = 30 }))
    eq(view.double, nil, "brain3: a single's view is not a double's")
    local c = brain3(4):choose(view)
    eq(c and c.move, 1, "brain3 single: the knockout is still taken")
    eq(c and c.target, nil, "brain3 single: ...and a 1v1 answer carries no target")
  end

  -- --- a Ghost CURSE names the foe opposite the user (a seat-2 Ghost -> slot 1)
  do
    local function curse() return mv(174, { power = 0, type = 7, effect = E.CURSE, target = 16 }) end
    local function ghostField(player, npcTypes)
      local npc = { sheet({ slot = 0, moves = { tackle() } }),
                    sheet({ slot = 1, types = npcTypes or { 7 }, moves = { curse() } }) }
      return lone(npc, player)
    end
    for _, fam in ipairs({ { "FireRed", FR }, { "Emerald", EM_BITS } }) do
      local name, bits = fam[1], fam[2]
      for _, roll in ipairs({ lowRng, highRng }) do
        local battle, viewFor = ghostField({ sheet({ slot = 0 }), sheet({ slot = 1 }) })
        local c = brain3(1, { aiBits = bits, rng = roll }):choose(viewFor(2))
        eq(c and c.move, 0, "brain3 double: " .. name .. " seat 2 uses its CURSE")
        eq(c and c.target, 1, "brain3 double: " .. name .. " seat 2's Ghost CURSE names slot 1, the foe opposite")
        check(battle:submitChoice("n#2", c), "brain3 double: " .. name .. " the referee takes that choice")
        check(battle:submitChoice("n", { action = "fight", move = 0, target = 0 }),
              "brain3 double: " .. name .. " seat 1 files")
        check(battle:submitChoice("p", { action = "fight", move = 0, target = 3 }),
              "brain3 double: " .. name .. " player 1 files")
        check(battle:submitChoice("p#2", { action = "fight", move = 0, target = 3 }),
              "brain3 double: " .. name .. " player 2 files")
        eq(battle.byId["p#2"].b.cursed, true, "brain3 double: " .. name .. " the curse lands on slot 1")
        eq(battle.byId.p.b.cursed, nil, "brain3 double: ...and not on slot 0")
      end
      -- slot 1 never filled: the nearest foe is slot 0
      local _, viewOne = ghostField({ sheet({ slot = 0 }) })
      eq(brain3(1, { aiBits = bits }):choose(viewOne(2)).target, 0,
         "brain3 double: " .. name .. " with slot 1 empty, the curse names slot 0")
      -- a seat-1 Ghost faces slot 0
      local npc1 = { sheet({ slot = 0, types = { 7 }, moves = { curse() } }), sheet({ slot = 1 }) }
      local _, vf1 = lone(npc1, { sheet({ slot = 0 }), sheet({ slot = 1 }) })
      eq(brain3(1, { aiBits = bits, rng = highRng }):choose(vf1(1)).target, 0,
         "brain3 double: " .. name .. " a seat-1 Ghost CURSE names slot 0")
      -- a non-Ghost CURSE is a move on the user: no target
      local _, vf3 = ghostField({ sheet({ slot = 0 }), sheet({ slot = 1 }) }, { 0 })
      eq(brain3(1, { aiBits = bits, rng = highRng }):choose(vf3(2)).target, nil,
         "brain3 double: " .. name .. " a non-Ghost CURSE names no target")
      -- the same rule with no referee in the view
      local _, vf4 = ghostField({ sheet({ slot = 0 }), sheet({ slot = 1 }) })
      local v4 = vf4(2)
      v4.sim = nil
      eq(brain3(1, { aiBits = bits }):choose(v4).target, 1,
         "brain3 double: " .. name .. " with no referee in the view, the same opposite slot")
      local v5 = vf4(2)
      v5.sim = nil
      v5.foes = { v5.foes[1] }
      eq(brain3(1, { aiBits = bits }):choose(v5).target, 0,
         "brain3 double: " .. name .. " ...and slot 1 not standing -> the nearest, slot 0")
      local _, vf6 = lone({ sheet({ slot = 0, types = { 7 }, moves = { curse() } }), sheet({ slot = 1 }) },
                          { sheet({ slot = 0 }), sheet({ slot = 1 }) })
      local v6 = vf6(1)
      v6.sim = nil
      eq(brain3(1, { aiBits = bits, rng = highRng }):choose(v6).target, 0,
         "brain3 double: " .. name .. " seat 1 with no referee in the view -> slot 0, the one opposite")
    end
  end

  -- --- fuzz: never a throw, never an illegal pick, deterministic per seed
  do
    local effects = { 0, E.SLEEP, E.TOXIC, E.EXPLOSION, E.ROAR, E.BATON_PASS, E.HELPING_HAND, E.FOLLOW_ME,
      E.RESTORE_HP, E.ATTACK_UP, E.SUNNY_DAY, E.PROTECT, E.SKILL_SWAP, E.SWAGGER, E.WILL_O_WISP, E.PERISH_SONG }
    local nums = { 33, 89, 222, 285, 261, 92, 270, 207, 126, 87, 85, 53, 52, 7 }
    local abilities = { 0, 0, 18, 26, 31, 62, 54, 23, 74, 14, 25, 10 }
    local threw, illegal, nondet, refused = 0, 0, 0, 0
    local answered, aimed, switched = 0, 0, 0
    for seed = 1, 600 do
      local rng = seeded(seed * 104729)
      local function pick(list) return list[rng(1, #list)] end
      local function mon(slot)
        local moves = {}
        for i = 1, rng(1, 4) do
          moves[i] = mv(pick(nums), { effect = pick(effects),
            power = (rng(0, 2) == 0) and 0 or rng(10, 120), type = rng(0, 17),
            target = pick({ 0, 0, 8, 16, 32 }), pp = (rng(0, 12) == 0) and 0 or 10 })
        end
        local maxHp = rng(40, 160)
        return sheet({ slot = slot,
          types = (rng(0, 1) == 0) and { rng(0, 17) } or { rng(0, 17), rng(0, 17) },
          ability = pick(abilities), moves = moves, maxHp = maxHp, hp = rng(1, maxHp),
          status = pick({ false, false, "PSN", "SLP" }) or nil, heldItem = pick({ 0, 140 }) })
      end
      local npc, player = {}, {}
      for i = 1, rng(2, 5) do npc[i] = mon(i - 1) end
      for i = 1, rng(2, 4) do player[i] = mon(i - 1) end
      local battle, viewFor = lone(npc, player, { seed = seed })
      if rng(0, 2) == 0 then battle.byId.p.b.mon.hp = 0 end
      if rng(0, 3) == 0 then battle.byId["n#2"].b.mon.hp = 0 end
      local which = rng(1, 2)
      local claimed = {}
      if rng(0, 1) == 0 then claimed[rng(1, #npc)] = true end
      local v = viewFor(which, claimed)
      if v.partner and v.partner.mon.hp <= 0 then v.partner = nil end
      if #v.foes > 0 and v.mon and v.mon.hp > 0 then
        v.mustReplace = rng(0, 4) == 0
        if v.mustReplace then v.mon.hp = 0 end
        local flags = rng(0, 1023)
        local bits = (rng(0, 1) == 0) and FR or EM_BITS
        local items = { pick({ 0, 21 }), 0, 0, 0 }
        local function ask()
          local b = brain3(flags, { aiBits = bits, rng = seeded(seed), items = items })
          return pcall(b._decide, b, v)
        end
        local ok, c = ask()
        if not ok then
          threw = threw + 1
        else
          local ok2, c2 = ask()
          local function key(x) return x and (tostring(x.action) .. "/" .. tostring(x.move) .. "/"
            .. tostring(x.target) .. "/" .. tostring(x.slot) .. "/" .. tostring(x.item)) or "nil" end
          if not ok2 or key(c) ~= key(c2) then nondet = nondet + 1 end
          if c then
            answered = answered + 1
            if c.action == "switch" then
              switched = switched + 1
              local idx
              for i, m in ipairs(v.party) do if m.slot == c.slot then idx = i end end
              if not idx or v.party[idx].hp <= 0 or idx == v.fighter.active
                  or (v.partner and v.party[idx] == v.partner.mon) or claimed[idx] then
                illegal = illegal + 1
              end
            elseif c.action == "fight" and c.target ~= nil then
              aimed = aimed + 1
              local row = v.battler.moves[c.move + 1]
              local named = false
              for _, f in ipairs(v.foes) do if f.slot == c.target then named = true end end
              if v.partner and c.target == v.partner.slot then named = bits == EM_BITS end
              if not named or (row and (row.target or 0) ~= 0) then illegal = illegal + 1 end
              if not v.mustReplace and not battle:submitChoice(v.fighter.playerId, c) then
                refused = refused + 1
              end
            end
          end
        end
      end
    end
    eq(threw, 0, "brain3 double fuzz: no seed throws")
    eq(illegal, 0, "brain3 double fuzz: no active / claimed / fainted switch-in, no target on a "
       .. "move that takes none, FireRed never aims at its partner")
    eq(nondet, 0, "brain3 double fuzz: the same seed answers the same")
    eq(refused, 0, "brain3 double fuzz: the referee takes every aimed answer")
    check(answered > 300 and aimed > 100 and switched > 10,
          ("brain3 double fuzz: it covered ground (answered %d, aimed %d, switched %d)")
            :format(answered, aimed, switched))
  end
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
  -- What stays the cart's for everybody is Config.SOLO_REFUSED_GEN3 (C1: the
  -- link family and the e-Reader); every other refusal key names a kind
  -- (C2) -- the cart's until a module registers it (section 4).
  for _, field_ in ipairs(Config.SOLO_REFUSED_GEN3) do
    check(Solo.gen3Refused({ [field_] = true }, {}), "gen3Refused: " .. field_ .. " on the opts")
  end
  check(Solo.gen3Refused({ link = true }, {}), "gen3Refused: the link is the cart's")
  check(Solo.gen3Refused({}, { link = true }), "gen3Refused: ...and on the foe")
  check(Solo.gen3Refused({}, { kinds = { link = true } }), "gen3Refused: ...and in a kinds table")
  check(not Solo.gen3Refused({ firstBattle = false, trainerId = 900 }, {}),
        "gen3Refused: firstBattle = false is an ordinary trainer, not a refusal")
  for _, row in ipairs({
    { "safari", "safari" }, { "roamer", "roamer" }, { "legendary", "legendary" },
    { "specialWild", "legendary" }, { "regi", "legendary" }, { "wildScripted", "scripted" },
    { "oldManTutorial", "tutorial" }, { "pokedude", "tutorial" }, { "tutorialKind", "tutorial" },
    { "firstBattle", "firstBattle" }, { "firstBattleKind", "firstBattle" }, { "ghost", "ghost" },
    { "ghostBattle", "ghost" }, { "twoOpponents", "pair" }, { "trainerIdB", "pair" },
    { "partner", "partner" }, { "frontier", "facility" }, { "trainerTower", "facility" },
    { "secretBase", "facility" }, { "pike", "facility" },
  }) do
    eq(Solo.kind3Name({ [row[1]] = true }, {}, "wild"), row[2], "kind3Name: " .. row[1])
  end
  eq(Solo.kind3Name({}, { roamer = true }, "wild"), "roamer", "kind3Name: ...on the foe")
  eq(Solo.kind3Name({}, { kinds = { tutorial = "oldman" } }, "wild"), "tutorial",
     "kind3Name: ...in a kinds table")
  eq(Solo.kind3Name({ firstBattle = false, trainerId = 900 }, {}, "trainer"), "trainer",
     "kind3Name: firstBattle = false is an ordinary trainer")
  eq(Solo.kind3Name({ partner = true, twoOpponents = true, trainerIdB = 5 }, {}, "trainer"), "partner",
     "kind3Name: Steven's fight is the partner's, not the pair's")
  eq(Solo.kind3Name({ battleTower = true, partner = true, twoOpponents = true }, {}, "trainer"),
     "facility", "kind3Name: a Battle Tower multi is the facility's")
  eq(Solo.kind3Name({ ghost = true, wildScripted = true }, {}, "wild"), "ghost",
     "kind3Name: the Marowak is a ghost before it is a scripted wild")
  eq(Solo.kind3Name({ legendary = true, stand3 = { kind3 = "wild" } }, {}, "wild"), "wild",
     "kind3Name: the stand's kind3 is the word, whatever the keys say")
  eq(Solo.kind3Name({ kind3 = "safari" }, {}, "wild"), "safari", "kind3Name: a caller's own kind3")
  eq(Solo.kind3Name({}, {}, "wild"), "wild", "kind3Name: nothing set is the entry's own")
  check(Solo.gen3Double({ double = true }, {}), "gen3Double: the double flag")
  check(Solo.gen3Double({}, { doubleBattle = true }), "gen3Double: a double trainer row")
  check(Solo.gen3Double({ trainerIdB = 5 }, {}), "gen3Double: a second trainer is a double of a kind too")
  check(not Solo.gen3Double({}, {}) and not Solo.gen3Double(nil, nil), "gen3Double: a single is not")
  check(not Solo.gen3Double({}, { doubleBattle = false }), "gen3Double: ...nor a row that says false")
  -- the lone double: one trainer, one party (gen3Double is the wider question)
  check(Solo.gen3LoneDouble({ double = true }, {}), "gen3LoneDouble: the double flag")
  check(Solo.gen3LoneDouble({}, { doubleBattle = true }), "gen3LoneDouble: a double trainer row")
  check(not Solo.gen3LoneDouble({}, {}) and not Solo.gen3LoneDouble(nil, nil), "gen3LoneDouble: a single is not")
  check(not Solo.gen3LoneDouble({}, { doubleBattle = false }), "gen3LoneDouble: a row that says false is not")
  check(not Solo.gen3LoneDouble({ trainerIdB = 5 }, {}), "gen3LoneDouble: a second trainer is not")
  check(not Solo.gen3LoneDouble({ double = true, trainerIdB = 5 }, {}),
        "gen3LoneDouble: ...whatever else says double")
  check(not Solo.gen3LoneDouble({ trainerIdB = 5 }, { doubleBattle = true }),
        "gen3LoneDouble: ...nor does the row bring it back")
  -- usable: a species, not an egg, HP above zero (the cart's monsStateToDoubles)
  eq(Solo.gen3UsableMons({ monOf(4, 5), monOf(16, 5) }), 2, "gen3UsableMons: two")
  eq(Solo.gen3UsableMons({ monOf(4, 5), monOf(16, 5, { hp = 0 }) }), 1, "gen3UsableMons: a fainted one is not")
  eq(Solo.gen3UsableMons({ monOf(4, 5), monOf(16, 5, { isEgg = true }) }), 1, "gen3UsableMons: an egg is not")
  eq(Solo.gen3UsableMons({ monOf(4, 5), monOf(16, 5, { egg = true }) }), 1, "gen3UsableMons: ...either egg flag")
  eq(Solo.gen3UsableMons({ monOf(4, 5), { species = 412, hp = 10 } }), 1, "gen3UsableMons: the egg species is not")
  eq(Solo.gen3UsableMons({ monOf(4, 5), { species = 0, hp = 10 } }), 1, "gen3UsableMons: no species is not")
  eq(Solo.gen3UsableMons({ monOf(4, 5), { species = 16 } }), 1, "gen3UsableMons: no HP is not")
  eq(Solo.gen3UsableMons({ monOf(4, 5), "junk", false }), 1, "gen3UsableMons: a non-monster entry is not")
  eq(Solo.gen3UsableMons({ monOf(4, 5), { speciesId = 16, hp = 4 } }), 2,
     "gen3UsableMons: a monster known only by its speciesId counts")
  eq(Solo.gen3UsableMons({}), 0, "gen3UsableMons: an empty party")
  eq(Solo.gen3UsableMons(nil), 0, "gen3UsableMons: no party")
  -- the take-over decision: a lone double AND two who can fight
  local two = { monOf(4, 5), monOf(16, 5) }
  check(Solo.gen3TakesDouble({ double = true }, {}, two), "gen3TakesDouble: a lone double, two usable")
  check(Solo.gen3TakesDouble({}, { doubleBattle = true }, two), "gen3TakesDouble: ...by the row")
  check(not Solo.gen3TakesDouble({ double = true }, {}, { monOf(4, 5) }), "gen3TakesDouble: not with one monster")
  check(not Solo.gen3TakesDouble({ double = true }, {}, { monOf(4, 5), monOf(16, 5, { hp = 0 }) }),
        "gen3TakesDouble: ...nor one usable and a fainted one")
  check(not Solo.gen3TakesDouble({ double = true }, {}, nil), "gen3TakesDouble: nor no party")
  check(not Solo.gen3TakesDouble({ double = true, trainerIdB = 5 }, {}, two), "gen3TakesDouble: not a second trainer")
  check(not Solo.gen3TakesDouble({}, {}, two), "gen3TakesDouble: not a single")
  eq(Solo.kind3Name({ partner = true }, {}, "trainer"), "partner", "kind3Name: Steven's partner is a kind")
  eq(Solo.kind3Name({ twoOpponents = true }, {}, "trainer"), "pair", "kind3Name: ...and two opponents")
  eq(Solo.gen3Result("win", "catch", false), "caught", "gen3Result: catch")
  eq(Solo.gen3Result("loss", "run", false), "run", "gen3Result: the player ran")
  -- C5: a wild seat's own flight is MON_FLED, spelled "mon_fled" (code 6, as
  -- "fled" was).
  eq(Solo.gen3Result("win", "run", false), "mon_fled", "gen3Result: the wild mon left")
  eq(Solo.gen3Result("draw", "ko", true), "lose", "gen3Result: a whiteout draw is a defeat")
  eq(Solo.gen3Result("win", "ko", false), "win", "gen3Result: win")
  -- A flight is decided by who ran, not by who the referee named the winner.
  eq(Solo.gen3Result("win", "run", false, "a"), "run",
     "gen3Result: our side left -- a POKe DOLL names us the winners, and it is still RAN")
  eq(Solo.gen3Result("loss", "run", false, "b"), "mon_fled", "gen3Result: their side left")
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
  eq(solo:fromGen3Trainer(GAME, 902, {}), false,
     "a double trainer is handed back (this party has one usable monster, so the cart refuses it)")
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

-- (i) A timeout draw with the party standing halts the trainer script.
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
  eq(op.answered, nil, "draw: the trainerbattle opcode is not answered")
  eq(op.postBytes, false, "draw: the beaten trainer script does not run")
  eq(op.flag, false, "draw: the trainer is not beaten")
  eq(FakeVm.halted, 1, "draw: the waiting script is halted")
  eq(FakeVm.aborted, true, "draw: the script is aborted where it waits")
  eq(SESSION.battleOutcome, FakeNatives.outcome_to_code("draw"), "draw: the save records DREW")
  eq(SESSION.money, 500, "draw: no prize")
  eq(#fieldCalls, 0, "draw: nobody still standing is whited out")
  check(spaceCalls >= 1, "draw: the field comes back")
  eq(textOf(fight):find("STRINGID_PLAYERGOTMONEY", 1, true), nil, "draw: no prize is announced")
  local ended = effectsOf("emit")[1]
  eq(ended and ended[3].result, "draw", "draw: battle.ended records the draw")

  -- The same draw with no script waiting: nothing is halted, and the caller
  -- is not told it won.
  newGame()
  SESSION.party = { monOf(4, 20, { moves = { 10 }, pp = { 35 }, maxPp = { 35 } }) }
  local free = newSolo()
  local op2 = trainerOpcode()
  check(free:fromGen3Trainer(GAME, 900, { trainerId = 900, done = op2.done }), "draw (no script): taken")
  free.sim:_finish("draw", nil, nil, "timeout")
  drive(free, function(f) f:pickMove(1) end)
  eq(FakeVm.halted, 0, "draw (no script): nothing running, nothing halted")
  eq(op2.answered, nil, "draw (no script): the caller is not told it won")

  -- A knockout the referee called while a sheet still stands disagrees with
  -- the save the fight will write, and completes as a win.
  newGame()
  SESSION.party = { monOf(4, 20, { moves = { 10 }, pp = { 35 }, maxPp = { 35 } }) }
  SESSION.money = 500
  local ko = newSolo()
  local opk = trainerOpcode()
  FakeVm.running = true
  check(ko:fromGen3Trainer(GAME, 900, { trainerId = 900, done = opk.done }), "ko draw: taken")
  ko.sim:_finish("draw", nil, nil, "ko", "ko")
  drive(ko, function(f) f:pickMove(1) end)
  eq(opk.answered, "win", "ko draw: sheets still standing complete the trainer")
  eq(opk.flag, true, "ko draw: the trainer is beaten")
  eq(FakeVm.halted, 0, "ko draw: the waiting script continues")
  eq(SESSION.battleOutcome, FakeNatives.outcome_to_code("win"), "ko draw: the save records victory")
  check(SESSION.money > 500, "ko draw: the prize is paid")

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

-- (p2) The tutorials' endings (wave 4b): FireRed's quest log keeps no scene
--      of the old man's or the POKe DUDE's battles (pret quest_log_battle.c:14
--      TrySetQuestLogBattleEvent: OLD_MAN_TUTORIAL | POKEDUDE); a kind that
--      does not end on the field (`noFieldReturn`) runs no map resume
--      scripts; and M:quit3 ends a fight on the spot -- no further turn,
--      nothing brought home or reported, the cart's outcome code written,
--      the screen off, `done(word)`.
do
  Solo.registerKind3("tutorial", {})
  for _, key in ipairs({ "oldManTutorial", "pokedude" }) do
    newGame()
    SESSION.party = { monOf(4, 20, { moves = { 10 }, pp = { 35 }, maxPp = { 35 } }) }
    local solo = newSolo()
    check(solo:fromGen3Encounter(GAME, { species = 16, level = 2 }, { [key] = true, wild = true }),
          "tutorial ql: a " .. key .. " fight is taken")
    drive(solo, function(f) f:pickMove(1) end)
    eq(#effectsOf("questlog"), 0, "tutorial ql: no quest-log scene for a " .. key .. " fight")
    check(#effectsOf("emit") >= 1, "tutorial ql: ...the rest of the ending still runs (" .. key .. ")")
  end
  Solo.unregisterKind3("tutorial")

  -- noFieldReturn: no map resume scripts, `done` all the same.
  local heard = {}
  Solo.registerKind3("tutorial", { takes = function(_, ctx) ctx.noFieldReturn = true; return true end })
  newGame()
  SESSION.party = { monOf(4, 20, { moves = { 10 }, pp = { 35 }, maxPp = { 35 } }) }
  local solo = newSolo()
  check(solo:fromGen3Encounter(GAME, { species = 16, level = 2 },
    { pokedude = true, wild = true, done = function(w) heard[#heard + 1] = w end }), "noFieldReturn: taken")
  drive(solo, function(f) f:pickMove(1) end)
  eq(spaceCalls, 0, "noFieldReturn: no map resume scripts")
  eq(table.concat(heard, ","), "win", "noFieldReturn: ...and done('win')")

  -- quit3: ended between two frames of the referee.
  newGame()
  local lead = monOf(4, 20, { moves = { 10 }, pp = { 35 }, maxPp = { 35 } })
  SESSION.party = { lead }
  local hp0, exp0 = lead.hp, lead.exp
  heard = {}
  local quitter = newSolo()
  check(quitter:fromGen3Encounter(GAME, { species = 16, level = 2 },
    { pokedude = true, wild = true, done = function(w) heard[#heard + 1] = w end }), "quit: taken")
  local sim, fight = quitter.sim, quitter.fight
  for _ = 1, 40 do
    quitter:update(0.5, GAME)
    fight:update(2.0)
    if fight.phase == "choose" then break end
  end
  eq(fight.phase, "choose", "quit: the menu is up")
  local turn, phase = sim.turn, sim.phase
  eq(quitter:quit3("draw"), true, "quit: the fight is ended")
  eq(quitter.fight, nil, "quit: ...the core holds no fight")
  eq(quitter.sim, nil, "quit: ...nor a referee")
  eq(sim.turn, turn, "quit: no further turn")
  eq(sim.phase, phase, "quit: ...the referee left where it stood")
  eq(sim:outcome(), nil, "quit: ...with no outcome of its own")
  eq(Gen3Ui.has(fight), false, "quit: the screen is off the stack")
  eq(table.concat(heard, ","), "draw", "quit: done('draw')")
  eq(SESSION.battleOutcome, FakeNatives.outcome_to_code("draw"),
     "quit: the save's outcome is DREW (pret gBattleOutcome = B_OUTCOME_DREW)")
  eq(lead.hp, hp0, "quit: nothing brought home")
  eq(lead.exp, exp0, "quit: ...no EXP")
  eq(#effectsOf("questlog"), 0, "quit: no quest log")
  eq(#effectsOf("emit"), 0, "quit: no battle.ended")
  eq(spaceCalls, 0, "quit: no map resume scripts")
  for _ = 1, 3 do quitter:update(0.5, GAME) end
  eq(sim.turn, turn, "quit: ...and no turn on later frames")
  eq(quitter:quit3("draw"), false, "quit: once")
  eq(table.concat(heard, ","), "draw", "quit: done heard once")
  Solo.unregisterKind3("tutorial")
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

-- (s) The badges ride on our side, for the referee's badge boosts and
--     obedience caps (docs/plans/gen3-badge-rules.md, contract K1): the save's
--     badge flags as the badge numbers a hub upload carries.  Our own sheets
--     carry the obedience check's `traded` / `unfateful` (K2); the wild
--     monster's never do.
do
  -- Gen3.badgeList is the one reading every path shares (solo's side entry,
  -- a hub upload): the save's badge flags as their numbers, nil for none.
  local Gen3 = need("Gen3")
  newGame({ badges = { [1] = true, [3] = true } })
  eq(table.concat(Gen3.badgeList() or {}, ","), "1,3", "badges: the save's badge flags, by number")
  newGame()
  eq(Gen3.badgeList(), nil, "badges: none held, none sent")

  -- The live flag store wins whenever it is a table, field or not -- the
  -- engine's own order (Engine.hasBadge), and the moment of a divert.
  newGame({ badges = { [1] = true } })
  FakeSpace.store = { badges = { [2] = true, [8] = true } }
  GAME.phase = "battle"
  eq(table.concat(Gen3.badgeList() or {}, ","), "2,8", "badges: the live flag store, mid-divert")
  FakeSpace.store = nil
  GAME.phase = "field"
  eq(table.concat(Gen3.badgeList() or {}, ","), "1", "badges: ...else the session's flags")

  local Turn = need("BattleSim3/Turn")
  local realCreate = Turn.create
  local seen
  Turn.create = function(opts, ...)
    seen = opts
    return realCreate(opts, ...)
  end
  newGame({ badges = { [1] = true, [3] = true } })
  SESSION.party = {
    monOf(4, 20),                                         -- ANN's own catch
    monOf(5, 20, { otId = 999 }),                         -- another trainer's id
    monOf(4, 20, { otName = "BOB" }),                     -- ANN's id, another name
    monOf(151, 20, { fatefulEncounter = true }),          -- an event MEW
    monOf(151, 20, { fatefulEncounter = false }),         -- a MEW without the bit
    monOf(151, 20),                                       -- the field never set
  }
  local solo = newSolo()
  local took = solo:fromGen3Encounter(GAME, { species = 16, level = 3 }, {})
  Turn.create = realCreate
  check(took, "badges: the wild fight is taken")
  local a = seen and seen.sides and seen.sides.a and seen.sides.a[1] or {}
  eq(seen and seen.mode, "wild", "badges: ...as a wild fight")
  eq(table.concat(a.badges or {}, ","), "1,3", "badges: side a carries the save's badge numbers")
  eq(a.seats, nil, "badges: ...on a single's one-seat entry")
  eq(a.family, "frlg", "badges: the entry names the cart family whose obedience rule applies")
  local mons = a.mons or {}
  eq(mons[1] and mons[1].traded, nil, "traded: ANN's own catch is not")
  eq(mons[2] and mons[2].traded, true, "traded: another OT id is")
  eq(mons[3] and mons[3].traded, true, "traded: ...as is ANN's id under another OT name")
  eq(mons[4] and mons[4].unfateful, nil, "unfateful: an event MEW carries nothing")
  eq(mons[5] and mons[5].unfateful, true, "unfateful: a MEW whose bit is explicitly clear")
  eq(mons[6] and mons[6].unfateful, nil,
     "unfateful: ...not one that never had the field (the engine's reading)")
  local retired = false
  for i = 1, #mons do
    if mons[i].fateful ~= nil then retired = true end
  end
  eq(retired, false, "K2: the retired fateful never reaches the referee")
  local wild = seen and seen.sides.b[1].mons[1] or {}
  check(wild.traded == nil and wild.unfateful == nil, "K2: the wild monster's sheet carries neither")
  drive(solo, function(f) f:pickMove(1) end)
  check(not solo:isRunning(), "badges: the fight still runs to its end")
end

-- ===================================================================
-- 3. SoloBattle, Gen 3: the lone double
-- ===================================================================
--
-- A trainer with the double flag, one trainer and one party, is fought on the
-- mod's referee as the cart fights it: two monsters a side, each side one
-- shared team (docs/plans/gen3-solo-doubles.md).  What is asserted here is
-- SoloBattle's half: the take-over decision, the seats it builds (contract
-- C1), the screen it asks for and the choices it takes back (C3), the trainer
-- answers for both seats (C2), and the ending -- the doubled prize, EXP, the
-- reconcile, the TV, the whiteout, the draw, the hand-back.
--
-- The screen is a stand-in for CoopBattle.newSoloDouble for the first half
-- (it makes the same uploads as MediatedBattle:start and keeps every event it
-- is sent), so a test can play either seat by its field slot and aim, refill
-- and skip exactly; the real screen, driven by key presses, is the second
-- half.  Its own behaviour is tests/gen3_solo_double.lua's.

do
  local PLAYER, PLAYER2, FOE, FOE2 = "solo_player", "solo_player#2", "solo_foe", "solo_foe#2"
  local Wire = need("Wire")
  local CoopBattle = need("CoopBattle")
  local realNewSoloDouble = CoopBattle.newSoloDouble
  check(type(realNewSoloDouble) == "function", "double: CoopBattle.newSoloDouble is in the tree")

  -- More trainer rows: 905 a three-mon double, 906 a strong double (the loss
  -- and the player's refills), 907 a four-mon weak double (two on the bench,
  -- the claims), 908 a one-mon "double", 909 a double that poisons.  910-912
  -- (an Amulet Coin, two kinds, a potion) are added where they are used.
  TRAINERS[905] = { class = 57, className = "TWINS", name = "TRIO", pic = 6, gender = 1,
    encounterMusic = 130, lastLevel = 2, aiFlags = 1, items = { 0, 0, 0, 0 }, doubleBattle = true,
    party = { { species = 16, level = 2 }, { species = 16, level = 2 }, { species = 16, level = 2 } } }
  TRAINERS[906] = { class = 84, className = "LEADER", name = "DUO", pic = 9, gender = 0,
    encounterMusic = 0, lastLevel = 60, aiFlags = 7, items = { 0, 0, 0, 0 }, doubleBattle = true,
    party = { { species = 151, level = 60, moves = { 300 } }, { species = 151, level = 60, moves = { 300 } } } }
  TRAINERS[907] = { class = 57, className = "TWINS", name = "QUAD", pic = 6, gender = 1,
    encounterMusic = 130, lastLevel = 2, aiFlags = 1, items = { 0, 0, 0, 0 }, doubleBattle = true,
    party = { { species = 16, level = 2 }, { species = 16, level = 2 }, { species = 16, level = 2 },
              { species = 16, level = 2 } } }
  TRAINERS[908] = { class = 57, className = "TWINS", name = "SOLO", pic = 6, gender = 1,
    encounterMusic = 130, lastLevel = 2, aiFlags = 1, items = { 0, 0, 0, 0 }, doubleBattle = true,
    party = { { species = 16, level = 2 } } }
  -- A poisoning hit (pret EFFECT_POISON_HIT, a certain secondary), so one turn
  -- leaves damage and a status on whoever it lands on.
  ROM[302] = { effect = 2, power = 40, type = 3, accuracy = 100, pp = 35,
               secondaryChance = 100, target = 0, priority = 0, flags = 2 }
  P3._moveNames[302] = "VENOMJAB"
  TRAINERS[909] = { class = 57, className = "TWINS", name = "VEN", pic = 6, gender = 1,
    encounterMusic = 130, lastLevel = 20, aiFlags = 1, items = { 0, 0, 0, 0 }, doubleBattle = true,
    party = { { species = 16, level = 20, moves = { 302 } }, { species = 16, level = 20, moves = { 302 } } } }
  -- Emerald's money table, for Prize.rewardRse.
  FakeTrainers.pack = function() return { money = { [57] = 4, [84] = 25 }, moneyDefault = 5 } end

  -- ------- the C3 stub screen: what CoopBattle.newSoloDouble must answer to
  local stubMade = {}
  local Stub = {}
  Stub.__index = Stub
  local function stubScreen(game, opts)
    local s = setmetatable({
      game = game, opts = opts, transport = opts.transport, battle = opts.battle,
      onDone = opts.onDone, events = {}, lines = {}, sentChoices = {},
    }, Stub)
    stubMade[#stubMade + 1] = s
    return s
  end
  -- The uploads, exactly as MediatedBattle:start sends them (C3: "exactly as").
  function Stub:start(game)
    self.med = Mediated.new({ transport = self.transport, ui = UI, game = game,
      battle = self.battle, role = "host", mode = self.opts.mode,
      npcParty = self.opts.npcParty, trainer = self.opts.trainer, peerId = self.opts.foeId })
    return self.med:start(game)
  end
  function Stub:onReady(msg) self.ready = msg end
  function Stub:onEvent(e) self.events[#self.events + 1] = e end
  function Stub:onOutcome(o) self.outcome = o end
  function Stub:say(t) self.lines[#self.lines + 1] = tostring(t) end
  function Stub:update() end
  function Stub:draw() end
  function Stub:exit()
    local f = self.onDone
    self.onDone = nil
    if f then f(self.resultWord or "?", self.toLearn or {}) end
  end
  -- A choice as CoopBattle files it: the wire fields plus `seat`, through the
  -- same Mediated.submitChoice the mediated path uses.
  function Stub:choose(seat, fields)
    fields.seat = seat
    self.sentChoices[#self.sentChoices + 1] = fields
    return Mediated.submitChoice(self.transport, self.battle, fields, 3)
  end
  function Stub:leave() return Gen3Ui.pop(self.game, self) end
  CoopBattle.newSoloDouble = stubScreen

  local function eventsOf(s, t, side)
    local out = {}
    for _, e in ipairs(s.events) do
      if e.t == t and (side == nil or e.side == side) then out[#out + 1] = e end
    end
    return out
  end

  -- A seeded rng for every brain a fight builds, and a record of every view
  -- each is shown with the answer it gave (from the opening pump on): the
  -- fight is then a function of the referee's seed alone.
  local brainViews = {}
  local brainSeed = 11
  do
    local newBrain = Brain.new
    Brain.new = function(opts, ...)
      opts = opts or {}
      if opts.rng == nil then
        local state = brainSeed
        opts.rng = function(lo, hi)
          if hi == nil then lo, hi = 1, lo end
          if hi < lo then return lo end
          state = (state * 48271) % 2147483647
          return lo + (state % (hi - lo + 1))
        end
      end
      local brain = newBrain(opts, ...)
      if type(brain) == "table" then
        local choose = brain.choose
        brain.choose = function(self_, view)
          local copy = {}
          for k, v in pairs(view) do copy[k] = v end
          local claimed = {}
          for k, v in pairs(view.claimed or {}) do claimed[k] = v end
          copy.claimed = claimed
          local choice = choose(self_, view)
          copy.answer = choice
          brainViews[#brainViews + 1] = copy
          return choice
        end
      end
      return brain
    end
  end

  -- Every choice the referee is handed, by seat id, with the turn it was filed in.
  local filedBy = {}
  local function instrument(solo)
    local sim = solo.sim
    local submit = sim.submitChoice
    sim.submitChoice = function(self_, id, choice)
      -- read before the call: the last choice of a turn resolves it in there
      local turn, phase = self_.turn, self_.phase
      local ok = submit(self_, id, choice)
      filedBy[#filedBy + 1] = { id = id, ok = ok, action = choice and choice.action,
        seat = choice and choice.seat, turn = turn, phase = phase }
      return ok
    end
  end

  -- The player's side, one frame: every seat that owes, in slot order -- a
  -- move at `aim[i]` (the first standing foe slot when that one is down), or,
  -- in a replacement phase, `pickBench(seat, bench)`'s choice off the bench
  -- (the first one by default).  Seat 2's command goes through the same
  -- screen call as seat 1's, as CoopBattle's chooser files them.
  local function playerTurn(solo, plan)
    plan = plan or {}
    local sim, s = solo.sim, solo.fight
    if not (sim and s) then return end
    for i, seat in ipairs(sim:seatsOf(PLAYER)) do
      if sim:_owes(seat) then
        if sim.phase == "replace" then
          local bench = sim:benchOf(seat)
          local pick = plan.pickBench and plan.pickBench(seat, bench) or bench[1]
          s:choose(seat.slot, { action = "switch", slot = seat.mons[pick].slot })
        elseif sim.phase == "choice" then
          local target = plan.aim and plan.aim[i]
          if target then
            local standing = false
            for _, f in ipairs(sim:seatsOf(FOE)) do
              if f.slot == target and f.b and f.b.mon.hp > 0 then standing = true end
            end
            if not standing then target = nil end
          end
          if not target then
            for _, f in ipairs(sim:seatsOf(FOE)) do
              if f.b and f.b.mon.hp > 0 then target = f.slot; break end
            end
          end
          s:choose(seat.slot, { action = "fight", move = plan.move or 0, target = target })
        end
      end
    end
  end

  -- Pump a stubbed double the way the game does: the referee once a frame,
  -- the player's seats answered by `playerTurn`, until the outcome has come
  -- (then leave the screen, as A on the last line would).
  local function driveDouble(solo, plan, maxSteps)
    local last = solo.fight
    for _ = 1, maxSteps or 200 do
      solo:update(0.5, GAME)
      local s = solo.fight
      if not s then return true, last end
      last = s
      if s.outcome then
        solo:update(0.5, GAME)
        s:leave()
        return true, s
      end
      playerTurn(solo, plan)
    end
    return false, last
  end

  local function party2(a, b, more)
    local party = { a, b }
    for _, m in ipairs(more or {}) do party[#party + 1] = m end
    return party
  end
  local function strong(species, level, extra)
    local fields = { moves = { 10 }, pp = { 35 }, maxPp = { 35 } }
    for k, v in pairs(extra or {}) do fields[k] = v end
    return monOf(species, level, fields)
  end

  -- (a) the take-over decision, through the door -----------------------
  do
    newGame()
    SESSION.party = party2(monOf(4, 20), monOf(16, 20))
    local solo = newSolo()
    local made = #stubMade
    check(solo:fromGen3Trainer(GAME, 902, {}), "takes: two usable monsters, the row's own double flag")
    eq(#stubMade, made + 1, "takes: ...on the double screen")
    eq(getmetatable(solo.fight), Stub, "takes: ...not the single's MediatedBattle")
    eq(solo.gen3 and solo.gen3.double, true, "takes: the fight is marked a double")
    solo:reset()

    -- the flag on the opts alone (a trainerbattle type 4 / 6 / 8's own)
    newGame()
    SESSION.party = party2(monOf(4, 20), monOf(16, 20))
    local flagged = newSolo()
    check(flagged:fromGen3Trainer(GAME, { trainerId = 900 }, { trainerId = 900, double = true }),
          "takes: the opcode's own double flag on a single-row trainer")
    eq(flagged.sim and flagged.sim.double, true, "takes: ...a doubles referee")
    eq(flagged.fight and flagged.fight.opts.foeSeats, 1, "takes: ...with the trainer's one monster behind one seat")
    flagged:reset()

    -- leads: the first two monsters that can fight -- a fainted one and an egg are skipped
    newGame()
    local fainted = monOf(4, 20, { hp = 0 })
    local lead1 = monOf(4, 20)
    local egg = monOf(16, 20, { isEgg = true })
    local lead2 = monOf(151, 20)
    SESSION.party = { fainted, lead1, egg, lead2 }
    local leads = newSolo()
    check(leads:fromGen3Trainer(GAME, 902, {}), "leads: a party with a fainted lead and an egg is taken")
    local sim = leads.sim
    local seat1, seat2 = sim.byId[PLAYER], sim.byId[PLAYER2]
    eq(seat1.mons[seat1.active].slot, 1, "leads: seat 1 is the first monster that can fight (party member 2)")
    eq(seat2.mons[seat2.active].slot, 3, "leads: seat 2 the next one, past the egg (party member 4)")
    eq(Solo.secondMon3(sim, SESSION.party), lead2, "leads: secondMon3 finds seat 2's engine monster")
    eq(table.concat(leads.fight.ready.sides.a, ","), PLAYER .. "," .. PLAYER2, "leads: both seats are announced")
    leads:reset()

    -- badges (contract K1): the one entry behind both seats carries the
    -- save's badge numbers, and the screen's upload sent the same list; the
    -- shared team's sheets carry `traded` (K2), the trainer's do not
    newGame({ badges = { [5] = true, [7] = true } })
    SESSION.party = party2(monOf(4, 20), monOf(16, 20, { otId = 999 }))
    local Turn = need("BattleSim3/Turn")
    local realCreate = Turn.create
    local seen
    Turn.create = function(opts, ...)
      seen = opts
      return realCreate(opts, ...)
    end
    local badged = newSolo()
    local tookDouble = badged:fromGen3Trainer(GAME, 902, {})
    Turn.create = realCreate
    check(tookDouble, "badges: the double is taken")
    local entry = seen and seen.sides.a[1] or {}
    eq(entry.seats, 2, "badges: ...one entry, two seats")
    eq(table.concat(entry.badges or {}, ","), "5,7", "badges: the entry carries the save's badge numbers")
    local upload = stubMade[#stubMade] and stubMade[#stubMade].med
    eq(upload and upload.mode, "coop_npc", "badges: the double uploads as a trainer fight")
    eq(entry.mons and entry.mons[2].traded, true, "traded: the shared team's traded monster says so")
    eq(entry.mons and entry.mons[1].traded, nil, "traded: ...ANN's own does not")
    local foeMons = seen and seen.sides.b[1].mons or {}
    check(foeMons[1] and foeMons[1].traded == nil, "traded: the trainer's sheets never carry it")
    badged:reset()
  end

  -- (b) the hand-backs: the caller fights the cart's own battle ----------
  do
    local speciesEgg = monOf(16, 20)
    speciesEgg.species, speciesEgg.speciesId = 412, 412
    local cases = {
      { "a one-monster party", { monOf(4, 20) }, {} },
      { "one usable monster (the second has fainted)", { monOf(4, 20), monOf(16, 20, { hp = 0 }) }, {} },
      { "one usable monster (the second is an egg)", { monOf(4, 20), monOf(16, 20, { isEgg = true }) }, {} },
      { "one usable monster (the second is the egg species)", { monOf(4, 20), speciesEgg }, {} },
      { "one usable monster behind two fainted ones",
        { monOf(4, 20, { hp = 0 }), monOf(16, 20, { hp = 0 }), monOf(151, 20) }, {} },
      { "a second trainer", { monOf(4, 20), monOf(16, 20) }, { trainerIdB = 900 } },
      { "a second trainer behind the double flag", { monOf(4, 20), monOf(16, 20) }, { double = true, trainerIdB = 900 } },
      { "Steven's partner", { monOf(4, 20), monOf(16, 20) }, { partner = true } },
      { "two opponents", { monOf(4, 20), monOf(16, 20) }, { twoOpponents = true } },
    }
    for _, case in ipairs(cases) do
      newGame()
      SESSION.party = case[2]
      local solo = newSolo()
      local made, mark = #stubMade, #warns
      eq(solo:fromGen3Trainer(GAME, 902, case[3]), false, "handed back: " .. case[1])
      eq(solo:isRunning(), false, "handed back: nothing is running (" .. case[1] .. ")")
      eq(#stubMade, made, "handed back: no double screen was built (" .. case[1] .. ")")
      eq(Stack.depth(), 0, "handed back: nothing went onto the stack (" .. case[1] .. ")")
      eq(#bridgeCalls, 0, "handed back: the caller's own start is the cart's, not ours (" .. case[1] .. ")")
      eq(#warns, mark, "handed back: it is a decision, not a fault -- nothing logged (" .. case[1] .. ")")
      eq(encounterResets, 0, "handed back: the encounter cooldown was not spent (" .. case[1] .. ")")
    end
    -- the same two-monster party, a single trainer: the single's screen, no double
    newGame()
    SESSION.party = party2(monOf(4, 20), monOf(16, 20))
    local solo = newSolo()
    local made = #stubMade
    check(solo:fromGen3Trainer(GAME, 900, { trainerId = 900 }), "single: a plain trainer is still taken")
    eq(#stubMade, made, "single: ...on MediatedBattle, never the double screen")
    solo:reset()
  end

  -- (c) a FireRed double, won -------------------------------------------
  local winFight
  do
    newGame()
    brainViews, filedBy = {}, {}
    local a = strong(4, 8)
    local b = strong(151, 8, { moves = { 1 } })
    SESSION.party = party2(a, b)
    SESSION.money = 500
    local hpA, hpB = a.hp, b.hp
    local awardOpts
    local award = Prize.awardTrainerWin
    Prize.awardTrainerWin = function(s, id, o) awardOpts = o; return award(s, id, o) end
    local solo = newSolo()
    local result, calls = nil, 0
    local op = trainerOpcode()
    FakeVm.running = true
    local took = solo:fromGen3Trainer(GAME, 902, { trainerId = 902, double = true,
      done = function(r) result = r; calls = calls + 1; op.done(r) end })
    check(took, "double: a lone double with two usable monsters is taken")
    local s = solo.fight
    eq(getmetatable(s), Stub, "double: the screen is CoopBattle.newSoloDouble's")
    -- contract C3: what the screen was asked for
    local o = s.opts
    eq(o.selfId, PLAYER, "C3: selfId")
    eq(o.foeId, FOE, "C3: foeId")
    eq(o.foeSeats, 2, "C3: foeSeats 2 for a two-monster trainer")
    eq(o.mode, Config.SOLO_TRAINER_MODE, "C3: mode coop_npc")
    eq(#o.npcParty, 2, "C3: npcParty is the trainer's two sheets")
    -- No `doubleBattle` rides on the record: the screen's intro counts the
    -- monsters it sends out, the prize and the TV read the fight's own flag.
    eq(o.trainer and o.trainer.doubleBattle, nil, "C3: the trainer record carries no doubleBattle (nothing reads one)")
    eq(solo.gen3 and solo.gen3.double, true, "C3: ...the fight's own state says double")
    eq(o.trainer and o.trainer.trainerId, 902, "C3: ...and is the numeric trainer")
    eq(o.peerName, Solo.gen3FoeLabel(o.trainer), "C3: peerName is the label the single opens with")
    eq(o.battle, s.battle, "C3: the battle id")
    check(type(o.onDone) == "function" and type(o.transport) == "table", "C3: a transport and an onDone")
    check(Gen3Ui.has(s), "double: the screen is a game3 layer")
    -- contract C1: the seats the referee was built with
    local sides = s.ready and s.ready.sides
    eq(sides and table.concat(sides.a, ","), PLAYER .. "," .. PLAYER2, "onReady: both player seats, in slot order")
    eq(sides and table.concat(sides.b, ","), FOE .. "," .. FOE2, "onReady: both trainer seats")
    eq(s.ready and s.ready.mode, Config.SOLO_TRAINER_MODE, "onReady: the mode")
    local sim = solo.sim
    check(sim.double, "referee: a doubles fight")
    eq(#sim:seatsOf(PLAYER), 2, "referee: two player seats")
    eq(#sim:seatsOf(FOE), 2, "referee: two trainer seats")
    check(sim.byId[PLAYER].mons == sim.byId[PLAYER2].mons, "referee: the player's seats share one team")
    check(sim.byId[FOE].mons == sim.byId[FOE2].mons, "referee: ...and so do the trainer's")
    eq(sim.byId[PLAYER].owner, PLAYER, "referee: seat 1 is owned by the player")
    eq(sim.byId[PLAYER2].owner, PLAYER, "referee: ...and so is seat 2")
    eq(sim.byId[PLAYER].active, 1, "referee: seat 1 leads with the first monster")
    eq(sim.byId[PLAYER2].active, 2, "referee: seat 2 with the second")
    -- both seats out on both sides, at the cart's field slots
    local slots = {}
    for _, e in ipairs(eventsOf(s, "send")) do slots[#slots + 1] = tostring(e.slot) end
    table.sort(slots)
    eq(table.concat(slots, ","), "0,1,3,4", "both seats out on both sides (slots 0, 1, 3, 4)")
    instrument(solo)
    -- after the opening pump both trainer seats have answered, by the brain
    check(sim.byId[FOE].choice ~= nil and sim.byId[FOE2].choice ~= nil,
          "foe: both trainer seats answered the first turn before the player was asked")
    -- a trainer's RUN: parked, the turn unspent, the other seat still owing
    local turn = sim.turn
    check(s:choose(0, { action = "run" }), "run: a trainer RUN is taken (and parked)")
    solo:update(0.5, GAME)
    eq(sim.turn, turn, "run: the turn was not spent")
    check(sim.byId[PLAYER].choice == nil and sim.byId[PLAYER2].choice == nil, "run: neither seat's choice was filed")
    check(s:choose(1, { action = "run" }), "run: ...nor does mon 2's menu let a trainer fight be left (parked too)")
    solo:update(0.5, GAME)
    eq(sim.turn, turn, "run: ...the turn is still unspent")
    check(sim.byId[PLAYER].choice == nil and sim.byId[PLAYER2].choice == nil,
          "run: ...and nothing was filed for either seat")

    local ok = driveDouble(solo, { aim = { 3, 4 } })
    check(ok, "double: the fight ran to its end")
    eq(result, "win", "double: done('win')")
    eq(calls, 1, "double: done exactly once")
    check(op.flag, "double: the trainer's flag is set (the script's continuation)")
    eq(Gen3Ui.has(s), false, "double: the screen left the stack")
    check(not solo:isRunning(), "double: nothing is left running")

    -- two commands a turn, each filed under its own seat by the screen's `seat`
    local to1, to2, byTurn = 0, 0, {}
    for _, f in ipairs(filedBy) do
      if f.ok and f.id == PLAYER and f.seat == 0 then to1 = to1 + 1 end
      if f.ok and f.id == PLAYER2 and f.seat == 1 then to2 = to2 + 1 end
      if f.ok and (f.id == PLAYER or f.id == PLAYER2) and f.phase == "choice" then
        byTurn[f.turn] = byTurn[f.turn] or {}
        byTurn[f.turn][f.id] = true
      end
    end
    check(to1 > 0 and to2 > 0, "choices: slot 0 files under solo_player, slot 1 under solo_player#2 ("
          .. to1 .. " / " .. to2 .. ")")
    eq(to1, to2, "choices: one command per seat each turn")
    local both = true
    for _, seats in pairs(byTurn) do if not (seats[PLAYER] and seats[PLAYER2]) then both = false end end
    check(next(byTurn) ~= nil and both, "choices: every turn took a command from mon 1 and one from mon 2")

    -- the trainer's side: C2 views, both seats, every answer legal
    local sawSeats, sawFoes2, sawDouble = {}, false, true
    local answered = 0
    for _, v in ipairs(brainViews) do
      if not v.double then sawDouble = false end
      sawSeats[v.seat] = true
      if type(v.foes) == "table" and #v.foes == 2 then sawFoes2 = true end
      if type(v.answer) == "table" then answered = answered + 1 end
    end
    check(#brainViews >= 2 and sawDouble, "brain: every view it was shown is a double view")
    check(sawSeats[3] and sawSeats[4], "brain: asked for both trainer seats (3 and 4)")
    check(sawFoes2, "brain: shown both player battlers as its foes")
    eq(answered, #brainViews, "brain: answered every time it was asked")
    local foeFiled, refused = 0, 0
    for _, f in ipairs(filedBy) do
      if f.id == FOE or f.id == FOE2 then
        foeFiled = foeFiled + 1
        if not f.ok then refused = refused + 1 end
      end
    end
    check(foeFiled >= 1, "foe: the brain's answers were filed after the screen was up (" .. foeFiled .. ")")
    eq(refused, 0, "foe: the referee took every trainer answer (none illegal)")
    local aimedLegal, aimedAny = true, false
    for _, v in ipairs(brainViews) do
      local ans = v.answer
      if ans and ans.action == "fight" and ans.target ~= nil then
        aimedAny = true
        if not (ans.target == 0 or ans.target == 1) then aimedLegal = false end
      end
    end
    check(aimedAny and aimedLegal, "foe: FireRed's trainer aims at a player battler (slot 0 or 1), never its partner")
    local partnerSeen = false
    for _, v in ipairs(brainViews) do if v.partner and v.partner.slot ~= v.seat then partnerSeen = true end end
    check(partnerSeen, "brain: its partner is the trainer's other battler")

    -- the prize: the doubled one, through the engine's own formula
    eq(awardOpts and awardOpts.double, true, "prize: double = true reached Prize.awardTrainerWin")
    local single = Prize.calc(902, { lastLevel = 5, moneyMultiplier = 1 })
    local want = Prize.calc(902, { lastLevel = 5, moneyMultiplier = 1, double = true })
    check(single > 0, "prize: the engine prices this trainer")
    eq(want, 2 * single, "prize: a double pays twice the single")
    eq(SESSION.money, 500 + want, "prize: paid into the session")
    check(table.concat(s.lines, " | "):find("STRINGID_PLAYERGOTMONEY|" .. want, 1, true) ~= nil,
          "prize: the money line says the doubled amount")
    -- EXP: split among the participants, both monsters, once per knockout
    local exps, mons, faints = eventsOf(s, "exp"), {}, eventsOf(s, "faint", "b")
    local allTwo = true
    for _, e in ipairs(exps) do
      mons[e.mon] = true
      if e.participants ~= 2 then allTwo = false end
    end
    check(mons[0] and mons[1], "exp: both of the player's monsters are paid")
    check(#exps > 0 and allTwo, "exp: split between the two participants on every knockout")
    eq(#exps, 2 * #faints, "exp: two shares for each foe that fainted (" .. #faints .. " fainted)")
    -- the reconcile: the referee's HP and PP came home onto both session monsters
    check(a.hp < hpA or b.hp < hpB, "reconcile: damage came home (a " .. a.hp .. "/" .. hpA
          .. ", b " .. b.hp .. "/" .. hpB .. ")")
    local simA, simB = sim.byId[PLAYER].mons[1], sim.byId[PLAYER].mons[2]
    eq(a.hp, simA.hp, "reconcile: seat 1's monster has the referee's HP")
    eq(b.hp, simB.hp, "reconcile: seat 2's monster has the referee's HP")
    eq(a.pp[1], simA.moves[1].pp, "reconcile: seat 1's PP")
    eq(b.pp[1], simB.moves[1].pp, "reconcile: seat 2's PP")
    -- the quest log and battle.ended take one monster a side: the first seats'
    local ql = effectsOf("questlog")[1]
    eq(ql and ql[3].player and ql[3].player.mon, a, "quest log: seat 1's monster")
    eq(ql and ql[3].double, true, "quest log: a double battle")
    eq(ql and ql[3].player2 and ql[3].player2.mon, b, "quest log: ...with seat 2's monster beside it")
    local ended = effectsOf("emit")[1]
    eq(ended and ended[2], "battle.ended", "battle.ended is raised")
    eq(ended and ended[3].result, "win", "battle.ended: the result")
    eq(ended and ended[3].battle and ended[3].battle.player and ended[3].battle.player.mon, a,
       "battle.ended: the first seat's monster")
    Prize.awardTrainerWin = award
    winFight = s
  end

  -- (c0) the after-battle prompts reach the SECOND seat's monster: a level it
  --      gained and a move it was left asking about, once the screen is off
  do
    newGame()
    local a = strong(16, 8)
    local b = strong(4, 15)
    SESSION.party = party2(a, b)
    local solo = newSolo()
    local result, order = nil, {}
    check(solo:fromGen3Trainer(GAME, 902, { trainerId = 902,
      done = function(r) result = r; order[#order + 1] = "done" end }), "prompts: taken")
    local s = solo.fight
    -- what the real screen's knockouts do to the live monsters, done by hand
    b.level = 16
    s.toLearn = { { mon = b, move = 52 } }
    local realLearn = FakeLearn.begin
    FakeLearn.begin = function(opts) order[#order + 1] = "learn"; return realLearn(opts) end
    local realStart = FakeScene.start
    FakeScene.start = function(...) order[#order + 1] = "evolve"; return realStart(...) end
    check(driveDouble(solo, { aim = { 3, 4 } }), "prompts: the fight ran to its end")
    FakeLearn.begin, FakeScene.start = realLearn, realStart
    eq(result, "win", "prompts: done('win')")
    eq(#FakeLearn.begun, 1, "prompts: the unanswered move-learn prompt opened, once")
    eq(FakeLearn.begun[1] and FakeLearn.begun[1].mon, b, "prompts: ...for seat 2's monster")
    eq(FakeLearn.begun[1] and FakeLearn.begun[1].moveId, 52, "prompts: ...for the move it was left asking about")
    eq(#FakeScene.started, 1, "prompts: the cart's evolution scene opened, once")
    eq(FakeScene.started[1] and FakeScene.started[1].mon, b, "prompts: ...for the monster that levelled on seat 2")
    eq(FakeScene.started[1] and FakeScene.started[1].into, 5, "prompts: ...into what the cart says")
    eq(table.concat(order, ","), "learn,evolve,done", "prompts: the move, then the evolution, then done")
  end

  -- (c1) an Amulet Coin on EITHER seat's monster, either side, doubles the prize
  --      again (the cart sets the multiplier as its holder is sent in, whichever
  --      battler position that is)
  TRAINERS[910] = { class = 57, className = "TWINS", name = "GILT", pic = 6, gender = 1,
    encounterMusic = 130, lastLevel = 5, aiFlags = 1, items = { 0, 0, 0, 0 }, doubleBattle = true,
    party = { { species = 16, level = 5 }, { species = 16, level = 5, heldItem = 127 } } }
  do
    local function prizeOf(label, trainerId, holder)
      newGame()
      SESSION.party = party2(strong(4, 30), strong(151, 30, holder and { heldItem = 127, item = 127 } or nil))
      SESSION.money = 0
      local solo = newSolo()
      check(solo:fromGen3Trainer(GAME, trainerId, { trainerId = trainerId }), label .. ": taken")
      check(driveDouble(solo, { aim = { 3, 4 } }), label .. ": the fight ran to its end")
      return SESSION.money
    end
    local plain = Prize.calc(902, { lastLevel = 5, moneyMultiplier = 1, double = true })
    eq(prizeOf("amulet (none)", 902, false), plain, "amulet: no coin, the plain doubled prize")
    eq(prizeOf("amulet (seat 2)", 902, true),
       Prize.calc(902, { lastLevel = 5, moneyMultiplier = 2, double = true }),
       "amulet: the coin on seat 2's lead doubles it again")
    eq(prizeOf("amulet (their seat 2)", 910, false),
       Prize.calc(910, { lastLevel = 5, moneyMultiplier = 2, double = true }),
       "amulet: ...and so does one on the trainer's second seat (FireRed counts either side)")
  end

  -- (c2) the choice's seat: slot 0 -> solo_player, slot 1 -> solo_player#2 ---
  do
    newGame()
    SESSION.party = party2(strong(4, 8), strong(151, 8))
    local solo = newSolo()
    check(solo:fromGen3Trainer(GAME, 902, { trainerId = 902 }), "seat: taken")
    local sim = solo.sim
    eq(solo:_seat3({ seat = 0 }), PLAYER, "seat: field slot 0 is the first seat")
    eq(solo:_seat3({ seat = 1 }), PLAYER2, "seat: field slot 1 is the second")
    eq(solo:_seat3({}), PLAYER, "seat: no `seat` is the first")
    eq(solo:_seat3({ seat = 3 }), nil, "seat: a trainer's slot is no seat of ours")
    eq(solo:_seat3({ seat = 9 }), nil, "seat: nor is a slot nobody stands on")
    check(solo:_choose({ action = "fight", move = 0, target = 3, seat = 1 }), "seat: a command for slot 1 is taken")
    check(sim.byId[PLAYER2].choice ~= nil and sim.byId[PLAYER].choice == nil,
          "seat: ...and filed under the second seat only")
    eq(solo:_choose({ action = "fight", move = 0, target = 3, seat = 9 }), false,
       "seat: a command for a slot that is none of ours is refused (the menu stays open)")
    check(sim.byId[PLAYER].choice == nil, "seat: ...and filed nowhere")
    local turn = sim.turn
    check(solo:_choose({ action = "fight", move = 0, target = 4 }), "seat: a command with no `seat` is the first's")
    check(sim.turn > turn, "seat: ...filed under the first seat, which completed the turn")
    solo:reset()

    -- a single has one seat: a `seat` on its payload is not read
    newGame()
    SESSION.party = party2(strong(4, 8), strong(151, 8))
    local single = newSolo()
    check(single:fromGen3Trainer(GAME, 900, { trainerId = 900 }), "seat: a single is taken")
    eq(single:_seat3({ seat = 1 }), PLAYER, "seat: a single's only seat, whatever `seat` says")
    single:reset()
  end

  -- A double whose two trainer monsters are different species, for the TV's
  -- "last to faint" -- the second seat's monster is the one left standing.
  TRAINERS[911] = { class = 57, className = "TWINS", name = "MISMATCH", pic = 6, gender = 1,
    encounterMusic = 130, lastLevel = 5, aiFlags = 1, items = { 0, 0, 0, 0 }, doubleBattle = true,
    party = { { species = 16, level = 5 }, { species = 4, level = 5 } } }

  -- (d) Emerald: the TV's second monster, the doubled money table --------
  do
    newGame()
    PROFILE.family = "rse"
    PROFILE.rules.money = "rse"
    local a = strong(4, 30)
    local b = strong(151, 30, { moves = { 1 } })
    SESSION.party = party2(a, b)
    SESSION.money = 0
    local rseOpts
    local reward = Prize.rewardRse
    Prize.rewardRse = function(id, o) rseOpts = o; return reward(id, o) end
    local solo = newSolo()
    check(solo:fromGen3Trainer(GAME, 902, { trainerId = 902 }), "rse: the row's doubleBattle is taken")
    local ok = driveDouble(solo, { aim = { 3, 4 } })
    check(ok, "rse: the fight ran to its end")
    eq(rseOpts and rseOpts.double, true, "rse: Prize.rewardRse got double = true")
    eq(SESSION.money, Prize.calcRse(902, { double = true }), "rse: the doubled money")
    local single = Prize.calcRse(902, { double = false })
    check(single > 0 and SESSION.money == 2 * single, "rse: ...twice the single's (" .. SESSION.money .. " / " .. single .. ")")
    local tv
    for _, e in ipairs(effectsLog) do if e[1] == "rse" and e[2] == "tv" then tv = e end end
    local results = tv and tv[7]
    eq(results and results.playerMon1Species, 4, "tv: mon 1 is seat 1's monster")
    eq(results and results.playerMon2Species, 151, "tv: mon 2 is seat 2's (playerMon2Species)")
    eq(results and results.lastOpponentSpecies, 16, "tv: the trainer's monster that fainted last")
    eq(#effectsOf("questlog"), 0, "rse: no quest log on Emerald")
    Prize.rewardRse = reward
    PROFILE.family = "frlg"
    PROFILE.rules.money = "frlg"

    -- the monster that fainted LAST, whichever slot it stood on: both player
    -- monsters go for the first trainer seat, so the second seat's is the last
    newGame()
    PROFILE.family = "rse"
    PROFILE.rules.money = "rse"
    SESSION.party = party2(strong(4, 30), strong(151, 30, { moves = { 1 } }))
    local mixed = newSolo()
    check(mixed:fromGen3Trainer(GAME, 911, { trainerId = 911 }), "tv: a trainer with two kinds, taken")
    local ms = mixed.fight
    check(driveDouble(mixed, { aim = { 3, 3 } }), "tv: the fight ran to its end")
    PROFILE.family = "frlg"
    PROFILE.rules.money = "frlg"
    local faintsB = eventsOf(ms, "faint", "b")
    eq(#faintsB, 2, "tv: both of the trainer's monsters fainted")
    eq(faintsB[1] and faintsB[1].slot, 3, "tv: the first seat's went first")
    eq(faintsB[2] and faintsB[2].slot, 4, "tv: the second seat's last")
    local tvMixed
    for _, e in ipairs(effectsLog) do if e[1] == "rse" and e[2] == "tv" then tvMixed = e end end
    eq(tvMixed and tvMixed[7] and tvMixed[7].lastOpponentSpecies, 4,
       "tv: lastOpponentSpecies is the monster that fainted last (the second seat's), not the first seat's")

    -- a single's TV report has no second monster
    newGame()
    PROFILE.family = "rse"
    PROFILE.rules.money = "rse"
    SESSION.party = party2(strong(4, 30), strong(151, 30))
    local one = newSolo()
    check(one:fromGen3Trainer(GAME, 900, { trainerId = 900 }), "rse single: taken")
    drive(one, function(f) f:pickMove(1) end)
    PROFILE.family = "frlg"
    PROFILE.rules.money = "frlg"
    local tv1
    for _, e in ipairs(effectsLog) do if e[1] == "rse" and e[2] == "tv" then tv1 = e end end
    eq(tv1 and tv1[7] and tv1[7].playerMon2Species, 0, "rse single: the cart's playerMon2Species is 0 on a single")
  end

  -- (e) the trainer's refills -------------------------------------------
  do
    -- a three-mon trainer, both foes down in one turn, one on the bench: only
    -- the first seat refills, and the other stays empty for good
    newGame()
    SESSION.party = party2(strong(4, 40), strong(151, 40, { moves = { 1 } }))
    brainViews, filedBy = {}, {}
    local solo = newSolo()
    check(solo:fromGen3Trainer(GAME, 905, { trainerId = 905, double = true }), "trio: taken")
    instrument(solo)
    local s, sim = solo.fight, solo.sim
    playerTurn(solo, { aim = { 3, 4 } })
    for _ = 1, 4 do solo:update(0.5, GAME) end
    local faints, foeSends = eventsOf(s, "faint", "b"), eventsOf(s, "send", "b")
    eq(#faints, 2, "trio: both foes went down in the first turn")
    eq(#foeSends, 3, "trio: one refill only -- two knocked out, one on the bench")
    eq(foeSends[3] and foeSends[3].slot, 3, "trio: the first seat is the one refilled")
    eq(foeSends[3] and foeSends[3].mon, 2, "trio: ...with the one monster left")
    eq(sim.byId[FOE2].mustReplace, nil, "trio: the other seat stays empty, not owed")
    eq(sim.byId[FOE2].b, nil, "trio: ...with nothing standing on it")
    local asked = { [3] = 0, [4] = 0 }
    for _, v in ipairs(brainViews) do
      if v.mustReplace and asked[v.seat] ~= nil then asked[v.seat] = asked[v.seat] + 1 end
    end
    eq(asked[3], 1, "trio: the brain was asked once, for the send-out of the seat that is owed one")
    eq(asked[4], 0, "trio: ...and never for the seat that is not (no speculative call spends its items)")
    local ok = driveDouble(solo, { aim = { 3, 4 } })
    check(ok, "trio: the fight ran to its end")
    check(solo.gen3 == nil and not solo:isRunning(), "trio: and let go")

    -- a four-mon trainer: both refill, from the whole bench, and never the same monster
    newGame()
    SESSION.party = party2(strong(4, 40), strong(151, 40, { moves = { 1 } }))
    brainViews, filedBy = {}, {}
    local quad = newSolo()
    check(quad:fromGen3Trainer(GAME, 907, { trainerId = 907, double = true }), "quad: taken")
    instrument(quad)
    local qs = quad.fight
    playerTurn(quad, { aim = { 3, 4 } })
    for _ = 1, 4 do quad:update(0.5, GAME) end
    local qFaints, qSends = eventsOf(qs, "faint", "b"), eventsOf(qs, "send", "b")
    eq(#qFaints, 2, "quad: both foes went down in the first turn")
    eq(#qSends, 4, "quad: both seats refilled")
    check(qSends[3] and qSends[4] and qSends[3].mon ~= qSends[4].mon, "quad: ...with different monsters")
    check(qSends[3] and qSends[4] and qSends[3].mon >= 2 and qSends[4].mon >= 2,
          "quad: ...neither of them a fainted lead")
    local claimSeen = false
    for _, v in ipairs(brainViews) do
      if v.mustReplace and v.seat == 4 and next(v.claimed) ~= nil then claimSeen = true end
    end
    check(claimSeen, "quad: the second seat's send-out view carried the first seat's claim")
    for _, v in ipairs(brainViews) do
      if v.mustReplace then
        for idx in pairs(v.claimed) do
          check(not (type(v.answer) == "table" and v.answer.action == "switch"
                     and v.party[idx] and v.answer.slot == v.party[idx].slot),
                "quad: a send-out answer is never a monster the sibling claimed (party " .. idx .. ")")
        end
      end
    end
    check(driveDouble(quad, { aim = { 3, 4 } }), "quad: the fight ran to its end")
  end

  -- (e2) ONE brain answers both trainer seats: the four item slots are the
  --      trainer's, not a monster's -- one HYPER POTION is drunk once, whichever
  --      seat reaches for it first, though both monsters are under a quarter HP
  TRAINERS[912] = { class = 57, className = "TWINS", name = "POTS", pic = 6, gender = 1,
    encounterMusic = 130, lastLevel = 5, aiFlags = 1, items = { 21, 0, 0, 0 }, doubleBattle = true,
    party = { { species = 16, level = 5 }, { species = 16, level = 5 } } }
  do
    newGame()
    SESSION.party = party2(strong(4, 40), strong(151, 40, { moves = { 1 } }))
    local foes = Solo.gen3TrainerParty(FakeTrainers.foeFromId(912), 912)
    foes[1].hp, foes[2].hp = 2, 2
    brainViews, filedBy = {}, {}
    local solo = newSolo()
    check(solo:fromGen3Trainer(GAME, 912, { trainerId = 912, party = foes }), "items: taken")
    local sim = solo.sim
    local c1, c2 = sim.byId[FOE].choice, sim.byId[FOE2].choice
    eq(c1 and c1.action, "item", "items: the first seat drinks the potion")
    eq(c1 and c1.item, 21, "items: ...by its id")
    eq(c2 and c2.action, "fight", "items: the second seat, as low, does not -- the one potion is spent")
    check(driveDouble(solo, { aim = { 3, 4 } }), "items: the fight ran to its end")
    local drunk = 0
    for _, v in ipairs(brainViews) do
      if type(v.answer) == "table" and v.answer.action == "item" then drunk = drunk + 1 end
    end
    eq(drunk, 1, "items: one potion drunk in the whole fight, by either seat")
  end

  -- (f) the player's refills, from the shared bench ----------------------
  do
    -- two leads at 1 HP before a strong pair: both go down in the first turn,
    -- two monsters wait on the bench; either seat may take either of them, and
    -- the second seat is offered only what the first did not take
    local function refill(label, pick1, pick2, want0, want1)
      newGame()
      brainViews, filedBy = {}, {}
      local a = strong(4, 3, { hp = 1 })
      local b = strong(16, 3, { hp = 1 })
      local c = strong(151, 40)
      local d = strong(29, 40)
      SESSION.party = { a, b, c, d }
      local solo = newSolo()
      check(solo:fromGen3Trainer(GAME, 906, { trainerId = 906, double = true }), label .. ": taken")
      local s, sim = solo.fight, solo.sim
      instrument(solo)
      local seat1, seat2 = sim.byId[PLAYER], sim.byId[PLAYER2]
      playerTurn(solo, { aim = { 3, 4 } })
      for _ = 1, 4 do solo:update(0.5, GAME) end
      eq(sim.phase, "replace", label .. ": both leads fainted, a replacement is owed")
      check(sim:_owes(seat1) and sim:_owes(seat2), label .. ": both seats owe one")
      eq(#eventsOf(s, "faint", "a"), 2, label .. ": two faints on the player's side")
      eq(#sim:benchOf(seat1), 2, label .. ": the whole bench is open to seat 1 (two monsters)")
      eq(#sim:benchOf(seat2), 2, label .. ": ...and to seat 2")
      local sendsBefore = #eventsOf(s, "send", "a")
      local offered = {}
      playerTurn(solo, { pickBench = function(seat, bench)
        offered[seat.slot] = #bench
        return (seat.slot == 0 and pick1 or pick2)(bench)
      end })
      for _ = 1, 4 do solo:update(0.5, GAME) end
      eq(offered[0], 2, label .. ": seat 1 was offered both bench monsters")
      eq(offered[1], 1, label .. ": seat 2 was offered only the one seat 1 left")
      local sends = eventsOf(s, "send", "a")
      eq(#sends, sendsBefore + 2, label .. ": both seats refilled")
      local bySlot = {}
      for i = sendsBefore + 1, #sends do bySlot[sends[i].slot] = sends[i].mon end
      eq(bySlot[0], want0, label .. ": seat 1 sent out party member " .. (want0 + 1))
      eq(bySlot[1], want1, label .. ": seat 2 sent out party member " .. (want1 + 1))
      check(bySlot[0] ~= bySlot[1], label .. ": never the same monster on both seats")
      check(driveDouble(solo, { aim = { 3, 4 } }), label .. ": the fight ran to its end")
      local refused = 0
      for _, f in ipairs(filedBy) do
        if (f.id == PLAYER or f.id == PLAYER2) and not f.ok then refused = refused + 1 end
      end
      eq(refused, 0, label .. ": the referee took every one of the player's choices")
    end
    local first = function(bench) return bench[1] end
    local last = function(bench) return bench[#bench] end
    refill("refill (seat 1 the last)", last, first, 3, 2)
    refill("refill (seat 1 the first)", first, first, 2, 3)
  end

  do
    -- the same pair of faints with ONE monster on the bench: one seat refilled
    newGame()
    brainViews, filedBy = {}, {}
    local a = strong(4, 3, { hp = 1 })
    local b = strong(16, 3, { hp = 1 })
    local c = strong(151, 40)
    SESSION.party = { a, b, c }
    local solo = newSolo()
    check(solo:fromGen3Trainer(GAME, 906, { trainerId = 906, double = true }), "last: taken")
    local s, sim = solo.fight, solo.sim
    local seat1, seat2 = sim.byId[PLAYER], sim.byId[PLAYER2]
    playerTurn(solo, { aim = { 3, 4 } })
    for _ = 1, 4 do solo:update(0.5, GAME) end
    eq(sim.phase, "replace", "last: both leads fainted")
    check(sim:_owes(seat1), "last: seat 1 owes a monster")
    check(not sim:_owes(seat2), "last: seat 2 does not -- one monster, one slot")
    local before = #eventsOf(s, "send", "a")
    playerTurn(solo)
    for _ = 1, 4 do solo:update(0.5, GAME) end
    eq(#eventsOf(s, "send", "a"), before + 1, "last: the one monster came out, on one seat")
    local sent = eventsOf(s, "send", "a")[before + 1]
    eq(sent and sent.slot, 0, "last: ...on seat 1's slot")
    eq(sent and sent.mon, 2, "last: ...the bench monster")
    local fighters = 0
    for _, seat in ipairs(sim:seatsOf(PLAYER)) do
      if seat.b and seat.b.mon.hp > 0 then fighters = fighters + 1 end
    end
    eq(fighters, 1, "last: one battler of ours is standing")
    check(driveDouble(solo, { aim = { 3, 4 } }), "last: the fight ran to its end (a lone monster against two)")
  end

  -- (g) a double lost: the whiteout --------------------------------------
  do
    newGame()
    local a = strong(4, 5, { hp = 3 })
    local b = strong(16, 5, { hp = 3, moves = { 33 } })
    SESSION.party = party2(a, b)
    SESSION.money = 500
    local solo = newSolo()
    local result
    check(solo:fromGen3Trainer(GAME, 906, { trainerId = 906, double = true,
      done = function(r) result = r end }), "loss: taken")
    local ok, s = driveDouble(solo, nil)
    check(ok, "loss: the fight ran to its end")
    eq(result, "lose", "loss: done('lose')")
    eq(fieldCalls[1], "respawn", "loss: the whiteout's respawn (the warp, the heal)")
    eq(bridgeCalls[1] and bridgeCalls[1][1], "loss", "loss: the cart's money loss")
    eq(SESSION.money, 380, "loss: ...taken from the session")
    eq(a.hp, a.maxHp, "loss: the party was healed by the respawn (seat 1's monster)")
    eq(b.hp, b.maxHp, "loss: ...and seat 2's")
    local text = table.concat(s.lines, " | ")
    check(text:find("STRINGID_PLAYERLOSTAGAINSTENEMYTRAINER", 1, true) ~= nil, "loss: the cart's lost line")
    check(text:find("STRINGID_PLAYERGOTMONEY", 1, true) == nil, "loss: no prize")
  end

  -- (h) a standing double timeout draw halts the trainer script -----
  do
    newGame()
    SESSION.party = party2(strong(4, 30), strong(151, 30))
    SESSION.money = 500
    local solo = newSolo()
    local result, calls = nil, 0
    FakeVm.running = true
    check(solo:fromGen3Trainer(GAME, 902, { trainerId = 902, double = true,
      done = function(r) result = r; calls = calls + 1 end }), "draw: taken")
    local s = solo.fight
    solo.sim:_finish("draw", nil, nil, "timeout")
    solo:update(0.5, GAME)
    check(s.outcome ~= nil, "draw: the screen was told the outcome")
    s:leave()
    eq(calls, 0, "draw: the trainer opcode is not answered")
    eq(result, nil, "draw: the beaten trainer script does not run")
    eq(FakeVm.halted, 1, "draw: the waiting script is halted")
    eq(FakeVm.aborted, true, "draw: the script is aborted where it waits")
    eq(#fieldCalls, 0, "draw: nobody is whited out (the player stands)")
    eq(SESSION.money, 500, "draw: no prize")
    eq(SESSION.battleOutcome, FakeNatives.outcome_to_code("draw"), "draw: the save records DREW")
    eq(table.concat(s.lines, " | "):find("STRINGID_PLAYERGOTMONEY", 1, true), nil, "draw: no prize is announced")
  end

  -- (i) a move learned mid-fight reaches the second seat's battler ----------
  do
    newGame()
    SESSION.party = party2(strong(4, 30), strong(151, 30, { moves = { 1 } }))
    local solo = newSolo()
    check(solo:fromGen3Trainer(GAME, 902, { trainerId = 902, double = true }), "learn: taken")
    local sim = solo.sim
    local seat2 = sim.byId[PLAYER2]
    local mon = seat2.b.mon
    local nm = {}
    for k, v in pairs(mon.moves[1]) do nm[k] = v end
    local added = { id = "FIX_33", num = 33, pp = 35, maxPp = 35, power = 35, type = 0,
      accuracy = 95, effect = 0, chance = 0, target = 0, priority = 0, flags = 2 }
    check(solo.fight.transport:send(Wire.BATTLE_MOVESET,
      { battle = solo.fight.battle, mon = mon.slot, moves = { nm, added } }),
      "learn: the moveset reached the referee")
    eq(#seat2.b.moves, 2, "learn: seat 2's battler fights with the new list")
    eq(#sim.byId[PLAYER].b.moves, 1, "learn: ...and seat 1's is untouched")
    solo:reset()
  end

  -- (j) a one-monster "double" trainer: one trainer seat ----------------------
  do
    newGame()
    SESSION.party = party2(strong(4, 30), strong(151, 30, { moves = { 1 } }))
    SESSION.money = 500
    local solo = newSolo()
    local result
    check(solo:fromGen3Trainer(GAME, 908, { trainerId = 908, double = true,
      done = function(r) result = r end }), "one foe: taken")
    eq(solo.fight.opts.foeSeats, 1, "one foe: foeSeats 1 -- the cart's absent battler from the start")
    eq(table.concat(solo.fight.ready.sides.b, ","), FOE, "one foe: a single trainer seat is announced")
    eq(table.concat(solo.fight.ready.sides.a, ","), PLAYER .. "," .. PLAYER2, "one foe: ...against both of ours")
    eq(#solo.sim:seatsOf(FOE), 1, "one foe: the referee seated one")
    local ok = driveDouble(solo, nil)
    check(ok, "one foe: the fight ran to its end")
    eq(result, "win", "one foe: won")
    local want = Prize.calc(908, { lastLevel = 2, moneyMultiplier = 1, double = true })
    eq(SESSION.money, 500 + want, "one foe: the prize is still the double's -- the cart's flag is the battle's")
  end

  -- (k) the single is untouched --------------------------------------------
  do
    newGame()
    SESSION.party = party2(strong(4, 20), monOf(151, 20))
    SESSION.money = 500
    local awardOpts
    local award = Prize.awardTrainerWin
    Prize.awardTrainerWin = function(s, id, o) awardOpts = o; return award(s, id, o) end
    local solo = newSolo()
    local made = #stubMade
    check(solo:fromGen3Trainer(GAME, { trainerId = 900 }, { trainerId = 900 }), "single: taken")
    eq(getmetatable(solo.fight), Mediated, "single: MediatedBattle, one seat")
    eq(#stubMade, made, "single: no double screen")
    eq(solo.sim.double, false, "single: not a doubles referee")
    eq(#solo.sim:seatsOf(PLAYER), 1, "single: one player seat")
    eq(solo.fight.trainer.doubleBattle, nil, "single: no doubleBattle on the trainer record")
    eq(solo.gen3.double, nil, "single: no double on the fight's own state")
    eq(solo.gen3.partySnap, nil, "single: no party snapshot (its screen fights copies)")
    local ok = drive(solo, function(f) f:pickMove(1) end)
    check(ok, "single: the fight ran to its end")
    eq(awardOpts and awardOpts.double, false, "single: the prize is not doubled")
    Prize.awardTrainerWin = award
    -- the record carries no double flag of its own, whatever the row says
    eq(Solo.gen3TrainerRecord(FakeTrainers.foeFromId(902), 902, {}).doubleBattle, nil,
       "record: a lone double's trainer record carries no doubleBattle")
    eq(Solo.gen3TrainerRecord(FakeTrainers.foeFromId(900), 900, {}).doubleBattle, nil,
       "record: nor does a single's")
  end

  -- (l) the hand-backs mid-fight put the party back --------------------------
  do
    -- the stand-in screen leaves the live party alone, so what the real one
    -- does to it is done here: HP, a status, PP, a level, a key it adds, a
    -- moved member -- then the fight is let go.
    newGame()
    local a = strong(4, 20)
    local b = strong(16, 20)
    local c = monOf(29, 18)
    SESSION.party = { a, b, c }
    local before = {
      hp = { a.hp, b.hp, c.hp }, level = a.level, exp = a.exp, pp1 = a.pp[1], moves = a.moves,
      ppTable = a.pp, ivs = b.ivs, status = a.status, n = #SESSION.party,
    }
    local solo = newSolo()
    local result
    local fallbackSaw
    check(solo:fromGen3Trainer(GAME, 902, { trainerId = 902, double = true,
      done = function(r) result = r end,
      fallback = function()
        fallbackSaw = { hp = { a.hp, b.hp, c.hp }, n = #SESSION.party, status = a.status,
          pp = a.pp[1], extra = a.fightKey, first = SESSION.party[1] }
      end }), "restore: taken")
    check(solo.gen3.partySnap ~= nil, "restore: the party was recorded at the divert")
    a.hp, b.hp, c.hp = 1, 2, 3
    a.status = "PSN"
    a.pp[1] = 1
    a.level, a.exp = a.level + 1, a.exp + 500
    a.fightKey = "added by the fight"
    b.ivs.hp = 0
    SESSION.party[3] = nil
    SESSION.party[1], SESSION.party[2] = b, a
    solo:reset()
    check(not solo:isRunning(), "restore: the fight was let go")
    check(fallbackSaw ~= nil, "restore: the caller's fallback started the cart's battle")
    eq(fallbackSaw and fallbackSaw.hp[1], before.hp[1], "restore: ...from the party the fight found (seat 1's HP)")
    eq(fallbackSaw and fallbackSaw.hp[2], before.hp[2], "restore: ...seat 2's HP")
    eq(fallbackSaw and fallbackSaw.hp[3], before.hp[3], "restore: ...the bench's")
    eq(fallbackSaw and fallbackSaw.n, 3, "restore: ...the same size")
    eq(fallbackSaw and fallbackSaw.first, a, "restore: ...in the same order (a first)")
    eq(SESSION.party[2], b, "restore: ...b second")
    eq(SESSION.party[3], c, "restore: ...c third, put back")
    eq(a.level, before.level, "restore: a level the fight paid is taken back")
    eq(a.exp, before.exp, "restore: ...and the EXP")
    eq(a.status, before.status, "restore: ...and the status")
    eq(a.pp[1], before.pp1, "restore: ...and the PP")
    eq(a.fightKey, nil, "restore: a key the fight added is taken off again")
    check(a.moves == before.moves and a.pp == before.ppTable and b.ivs == before.ivs,
          "restore: nested tables are the very tables they were (restored in place)")
    eq(b.ivs.hp, 31, "restore: ...with their contents")
    eq(result, nil, "restore: done is the cart's battle's to call now")
  end

  do
    -- the engine's own start gets the double: the foe row says it, and so do the opts
    newGame()
    SESSION.party = party2(strong(4, 30), strong(151, 30))
    local solo = newSolo()
    local result
    check(solo:fromGen3Trainer(GAME, 902, { trainerId = 902, double = true,
      done = function(r) result = r end }), "fault: taken")
    local s = solo.fight
    local mark = #warns
    solo.sim.tick = function() error("boom") end
    for _ = 1, (Config.SOLO_FAULT_LIMIT or 3) + 1 do solo:update(0.5, GAME) end
    check(not solo:isRunning(), "fault: the fight was let go")
    eq(Gen3Ui.has(s), false, "fault: the double screen came off the stack")
    local start = bridgeCalls[#bridgeCalls]
    eq(start and start[1], "start", "fault: the engine's own trainer battle was started")
    eq(start and start[3] and start[3].double, true, "fault: ...as a double")
    eq(start and start[2] and start[2].doubleBattle, true, "fault: ...against the double's own foe row")
    eq(start and start[3] and start[3].trainerId, 902, "fault: ...against the same trainer")
    eq(result, nil, "fault: done is not ours to call (the engine's battle owns it now)")
    check(contains(warns, "referee stopped answering") or contains(warns, "could not keep this fight"),
          "fault: the log says why")
    dropWarnsSince(mark)

    -- a turn that throws half way through, the second seat's command being the
    -- one that resolves it: contained, then handed back, with the party put back
    newGame()
    local ha, hb = strong(4, 30), strong(151, 30)
    SESSION.party = party2(ha, hb)
    local hpBefore = ha.hp
    local stall = newSolo()
    local stalled
    check(stall:fromGen3Trainer(GAME, 902, { trainerId = 902, done = function(r) stalled = r end }),
          "stall: taken")
    local m3 = #warns
    stall.sim._resolveFights = function() error("a move this build cannot resolve") end
    ha.hp = 3
    local okPlay = pcall(playerTurn, stall, { aim = { 3, 4 } })
    check(okPlay, "stall: the throw stays out of the screen's menu code")
    for _ = 1, 80 do
      if not stall:isRunning() then break end
      stall:update(0.5, GAME)
    end
    eq(stall:isRunning(), false, "stall: the fight was let go")
    eq(stalled, nil, "stall: never scored -- not a draw, not a win")
    local startS = bridgeCalls[#bridgeCalls]
    eq(startS and startS[1], "start", "stall: the engine's own trainer battle starts in its place")
    eq(startS and startS[2] and startS[2].doubleBattle, true, "stall: ...against the double's foe row")
    eq(ha.hp, hpBefore, "stall: ...from the party the fight found")
    check(contains(warns, "part way through a turn"), "stall: the log says why")
    dropWarnsSince(m3)

    -- the row alone (no flag on the opts): the engine's foe row carries it
    newGame()
    SESSION.party = party2(strong(4, 30), strong(151, 30))
    local rowSolo = newSolo()
    check(rowSolo:fromGen3Trainer(GAME, 902, { trainerId = 902 }), "fault (row): taken")
    local m2 = #warns
    rowSolo.sim.tick = function() error("boom") end
    for _ = 1, (Config.SOLO_FAULT_LIMIT or 3) + 1 do rowSolo:update(0.5, GAME) end
    local start2 = bridgeCalls[#bridgeCalls]
    eq(start2 and start2[2] and start2[2].doubleBattle, true, "fault (row): the foe row is still a double")
    dropWarnsSince(m2)
  end

  -- (m) a double screen that cannot be had is a fight not taken ------------
  do
    local function opened(label, ctor)
      newGame()
      local a, b = strong(4, 20), strong(16, 20)
      SESSION.party = party2(a, b)
      local hpA = a.hp
      CoopBattle.newSoloDouble = ctor
      local solo = newSolo()
      local mark = #warns
      eq(solo:fromGen3Trainer(GAME, 902, { trainerId = 902 }), false, label .. ": the fight is not taken")
      eq(solo:isRunning(), false, label .. ": nothing is running")
      eq(solo.gen3, nil, label .. ": no half-built fight is left behind")
      eq(Stack.depth(), 0, label .. ": nothing went onto the stack")
      eq(a.hp, hpA, label .. ": the party is as it was")
      eq(encounterResets, 0, label .. ": the encounter cooldown was not spent")
      CoopBattle.newSoloDouble = stubScreen
      return mark
    end
    local mark = opened("no screen", function() return nil, "no party to fight with" end)
    check(contains(warns, "could not be opened"), "no screen: the log says why")
    dropWarnsSince(mark)
    mark = opened("a throwing screen", function() error("boom") end)
    check(contains(warns, "could not be opened"), "a throwing screen: the log says why")
    dropWarnsSince(mark)
    -- an upload that fails after the screen has touched the party: put back
    newGame()
    local a, b = strong(4, 20), strong(16, 20)
    SESSION.party = party2(a, b)
    local hpA = a.hp
    CoopBattle.newSoloDouble = function(game, opts)
      local s = stubScreen(game, opts)
      s.start = function() a.hp = 1; a.status = "PSN"; return false end
      return s
    end
    local failing = newSolo()
    local m3 = #warns
    eq(failing:fromGen3Trainer(GAME, 902, { trainerId = 902 }), false, "failed upload: the fight is not taken")
    eq(a.hp, hpA, "failed upload: what the screen touched is put back (HP)")
    eq(a.status, nil, "failed upload: ...and the status")
    eq(failing.generation, nil, "failed upload: the solo is not left claiming Gen 3")
    CoopBattle.newSoloDouble = stubScreen
    dropWarnsSince(m3)
    -- a screen the stack refuses
    newGame()
    SESSION.party = party2(strong(4, 20), strong(16, 20))
    local refusing = setmetatable({ pushState = function() return nil end }, { __index = UI })
    local solo = Solo.new(refusing, { enabled = function() return true end, seed = function() return 7 end })
    local m4 = #warns
    eq(solo:fromGen3Trainer(GAME, 902, { trainerId = 902 }), false, "refused by the stack: the fight is not taken")
    eq(solo:isRunning(), false, "refused by the stack: nothing is running")
    check(contains(warns, "could not be opened"), "refused by the stack: the log says why")
    dropWarnsSince(m4)
  end

  CoopBattle.newSoloDouble = realNewSoloDouble

  -- ======================= the real screen ==============================
  --
  -- CoopBattle.newSoloDouble itself, driven by key presses: the leads' EXP,
  -- the doubled prize and the party it fights on are the live ones.
  do
    local say = CoopBattle.say
    CoopBattle.say = function(self_, text)
      self_.textLog = self_.textLog or {}
      self_.textLog[#self_.textLog + 1] = tostring(text)
      return say(self_, text)
    end
  end

  local function keyInput(key)
    return { pressed = {}, wasPressed = function(_, k) return key ~= nil and k == key end,
             isDown = function() return false end }
  end

  -- One frame of the real screen: A on any open menu, aiming at a foe, and a
  -- replacement taken from the first monster offered.
  local function frame(solo)
    local fight = solo.fight
    if not fight then return false end
    local key
    local menu = (fight.phase == "choose" or fight.phase == "move" or fight.phase == "target")
    if (menu or fight.replacing) and not fight:boxLive() then
      key = "a"
      if fight.phase == "target" then
        local p = fight:targetChoices()[fight.targetIndex or 1]
        if p and not fight:foeSide(p.index) then key = "down" end
      end
    end
    GAME.input = keyInput(key)
    fight:update(key and (1 / 60) or 1.0)
    GAME.input = keyInput(nil)
    return true
  end

  local function deepCopy(v, seen)
    if type(v) ~= "table" then return v end
    seen = seen or {}
    if seen[v] then return seen[v] end
    local out = {}
    seen[v] = out
    for k, x in pairs(v) do out[k] = deepCopy(x, seen) end
    return out
  end

  local function deepDiff(a, b, path, diffs)
    path = path or "party"
    diffs = diffs or {}
    if type(a) ~= "table" or type(b) ~= "table" then
      if a ~= b then diffs[#diffs + 1] = path .. ": " .. tostring(a) .. " ~= " .. tostring(b) end
      return diffs
    end
    for k, v in pairs(a) do deepDiff(v, b[k], path .. "." .. tostring(k), diffs) end
    for k, v in pairs(b) do
      if a[k] == nil then diffs[#diffs + 1] = path .. "." .. tostring(k) .. ": nil ~= " .. tostring(v) end
    end
    return diffs
  end

  -- (n) a double won through the real screen --------------------------------
  do
    newGame()
    local a = strong(4, 8)
    local b = strong(16, 8)
    local c = monOf(29, 18)
    SESSION.party = { a, b, c }
    SESSION.money = 500
    local expA, expB, expC = a.exp, b.exp, c.exp
    local solo = newSolo()
    local result, calls = nil, 0
    local op = trainerOpcode()
    FakeVm.running = true
    local took = solo:fromGen3Trainer(GAME, 902, { trainerId = 902,
      done = function(r) result = r; calls = calls + 1; op.done(r) end })
    check(took, "real: the lone double is taken (" .. table.concat(warns, " / ") .. ")")
    local fight = solo.fight
    check(fight and fight.soloDouble, "real: on CoopBattle's solo double screen")
    eq(#solo.sim:seatsOf(PLAYER), 2, "real: two player seats on the referee")
    eq(#fight.sim.slots, 4, "real: four battlers on the screen")
    local sim = solo.sim
    local frames = 0
    for _ = 1, 6000 do
      if not solo.fight then break end
      frames = frames + 1
      solo:update(1 / 60, GAME)
      if not frame(solo) then break end
    end
    check(solo.fight == nil, "real: the fight ended and was let go (" .. frames .. " frames)")
    eq(result, "win", "real: done('win')")
    eq(calls, 1, "real: done exactly once")
    check(op.flag, "real: the trainer's flag is set")
    check(a.exp > expA and b.exp > expB, "real: both leads earned EXP")
    eq(c.exp, expC, "real: the monster that never left the bench did not")
    local want = Prize.calc(902, { lastLevel = 5, moneyMultiplier = 1, double = true })
    eq(SESSION.money, 500 + want, "real: the doubled prize was paid")
    check(a.hp < a.maxHp or b.hp < b.maxHp, "real: the damage the fight did is on the party")
    eq(a.hp, sim.byId[PLAYER].mons[1].hp, "real: seat 1's monster ends on the referee's HP")
    eq(b.hp, sim.byId[PLAYER].mons[2].hp, "real: seat 2's monster ends on the referee's HP")
    eq(Gen3Ui.has(fight), false, "real: the screen left the stack")
    local text = table.concat(fight.textLog or {}, " | ")
    check(text:find("STRINGID_PLAYERGOTMONEY|" .. want, 1, true) ~= nil, "real: the money line names the doubled prize")
    -- The lone double's opening is the cart's own STRINGID_INTROMSG now
    -- (sText_Trainer1WantsToBattle), read through this suite's text stub.
    check(text:find("STRINGID_INTROMSG||AMY", 1, true) ~= nil,
          "real: the trainer's challenge was said, in the cart's words")
  end

  -- (o) a lost double through the real screen ---------------------------------
  do
    newGame()
    local a = strong(4, 5, { hp = 3 })
    local b = strong(16, 5, { hp = 3 })
    SESSION.party = { a, b }
    SESSION.money = 500
    local solo = newSolo()
    local result
    check(solo:fromGen3Trainer(GAME, 906, { trainerId = 906, done = function(r) result = r end }),
          "real loss: taken")
    for _ = 1, 6000 do
      if not solo.fight then break end
      solo:update(1 / 60, GAME)
      if not frame(solo) then break end
    end
    check(solo.fight == nil, "real loss: the fight ended")
    eq(result, "lose", "real loss: done('lose')")
    eq(fieldCalls[1], "respawn", "real loss: the whiteout's respawn")
    eq(SESSION.money, 380, "real loss: the money loss")
  end

  -- (p) a trainer with one monster, through the real screen ------------------
  do
    newGame()
    local a = strong(4, 20)
    local b = strong(16, 20)
    SESSION.party = { a, b }
    local solo = newSolo()
    local result
    check(solo:fromGen3Trainer(GAME, 908, { trainerId = 908, done = function(r) result = r end }),
          "real one foe: taken")
    eq(#solo.fight.sim.slots, 3, "real one foe: three battlers on the screen -- two of ours, one of theirs")
    for _ = 1, 6000 do
      if not solo.fight then break end
      solo:update(1 / 60, GAME)
      if not frame(solo) then break end
    end
    check(solo.fight == nil, "real one foe: the fight ended")
    eq(result, "win", "real one foe: done('win')")
    check(a.exp > 0 and a.hp > 0 and b.hp > 0, "real one foe: both of ours came through")
  end

  -- (q) the hand-back after a real fight began: the party exactly as it was ---
  do
    newGame()
    local a = strong(4, 20)
    local b = strong(16, 20)
    local c = monOf(29, 18)
    SESSION.party = { a, b, c }
    local party = SESSION.party
    local before = deepCopy(party)
    local aMoves, aPp, bIvs = a.moves, a.pp, b.ivs
    local solo = newSolo()
    local result
    check(solo:fromGen3Trainer(GAME, 909, { trainerId = 909, done = function(r) result = r end }),
          "real hand-back: the lone double is taken")
    local fight = solo.fight
    check(fight and fight.soloDouble, "real hand-back: on the real solo double screen")
    check(solo.gen3 and solo.gen3.partySnap ~= nil, "real hand-back: the party was recorded at the divert")
    -- fight until the live party carries damage, a status and spent PP
    local hurt, poisoned, spent = false, false, false
    for _ = 1, 3000 do
      if not solo.fight then break end
      solo:update(1 / 60, GAME)
      if not frame(solo) then break end
      hurt = hurt or a.hp < before[1].hp or b.hp < before[2].hp
      poisoned = poisoned or a.status ~= nil or b.status ~= nil
      spent = spent or a.pp[1] < before[1].pp[1] or b.pp[1] < before[2].pp[1]
      if hurt and poisoned and spent then break end
    end
    check(solo.fight ~= nil, "real hand-back: the fight is still running")
    check(hurt, "real hand-back: the screen wrote damage onto the live party mid-fight")
    check(poisoned, "real hand-back: ...and a status")
    check(spent, "real hand-back: ...and spent PP")
    check(#deepDiff(before, party) > 0, "real hand-back: so the live party differs from the divert")
    -- a referee that throws every frame: the fault limit hands the fight back
    local screen = solo.fight
    local mark = #warns
    solo.sim.tick = function() error("boom") end
    for _ = 1, (Config.SOLO_FAULT_LIMIT or 3) + 1 do solo:update(1 / 60, GAME) end
    check(not solo:isRunning(), "real hand-back: the fight was let go")
    eq(Gen3Ui.has(screen), false, "real hand-back: the double screen came off the stack")
    local diffs = deepDiff(before, party)
    eq(#diffs, 0, "real hand-back: the party is exactly the divert's (" .. table.concat(diffs, "; ") .. ")")
    eq(party[1], a, "real hand-back: member 1 is the same monster table")
    eq(party[2], b, "real hand-back: member 2 is the same monster table")
    eq(party[3], c, "real hand-back: member 3 is the same monster table")
    check(a.moves == aMoves and a.pp == aPp and b.ivs == bIvs,
          "real hand-back: nested tables restored in place, not replaced")
    eq(a.status, nil, "real hand-back: no status left behind")
    local start = bridgeCalls[#bridgeCalls]
    eq(start and start[1], "start", "real hand-back: the engine's own battle was started")
    eq(start and start[2] and start[2].doubleBattle, true, "real hand-back: ...as a double (the foe row)")
    eq(start and start[3] and start[3].trainerId, 909, "real hand-back: ...against the same trainer")
    eq(result, nil, "real hand-back: done is the engine battle's now, not ours")
    dropWarnsSince(mark)
  end

  do
    -- EXP the fight paid mid-fight, rolled back too: the cart's battle pays it again
    newGame()
    local a = strong(4, 30)
    local b = strong(151, 30, { moves = { 1 } })
    SESSION.party = { a, b }
    local before = deepCopy(SESSION.party)
    local solo = newSolo()
    check(solo:fromGen3Trainer(GAME, 902, { trainerId = 902, double = true }), "real hand-back 2: taken")
    local expGained = false
    for _ = 1, 3000 do
      if not solo.fight then break end
      solo:update(1 / 60, GAME)
      if not frame(solo) then break end
      expGained = expGained or a.exp > before[1].exp or b.exp > before[2].exp
      if expGained then break end
    end
    check(solo.fight ~= nil and expGained, "real hand-back 2: EXP landed on the live party mid-fight")
    local mark = #warns
    solo.sim.tick = function() error("boom") end
    for _ = 1, (Config.SOLO_FAULT_LIMIT or 3) + 1 do solo:update(1 / 60, GAME) end
    local diffs = deepDiff(before, SESSION.party)
    eq(#diffs, 0, "real hand-back 2: EXP, HP and PP are all back (" .. table.concat(diffs, "; ") .. ")")
    local start = bridgeCalls[#bridgeCalls]
    eq(start and start[3] and start[3].double, true, "real hand-back 2: the engine's battle starts with double = true")
    dropWarnsSince(mark)
  end

  do
    -- the fight's own ending reconciles; the restore is the hand-back's only
    newGame()
    local a = strong(4, 20)
    local b = strong(16, 20)
    SESSION.party = { a, b }
    local solo = newSolo()
    local result
    check(solo:fromGen3Trainer(GAME, 909, { trainerId = 909, done = function(r) result = r end }),
          "real ending: taken")
    local sim = solo.sim
    for _ = 1, 6000 do
      if not solo.fight then break end
      solo:update(1 / 60, GAME)
      if not frame(solo) then break end
    end
    check(solo.fight == nil, "real ending: the fight ran to its end")
    check(result == "win" or result == "lose", "real ending: done(" .. tostring(result) .. ")")
    if result == "win" then
      local simA, simB = sim.byId[PLAYER].mons[1], sim.byId[PLAYER].mons[2]
      eq(a.hp, simA.hp, "real ending: seat 1's HP is the referee's (reconciled, not restored)")
      eq(b.hp, simB.hp, "real ending: seat 2's HP is the referee's")
      eq(a.pp[1], simA.moves[1].pp, "real ending: seat 1's PP is the referee's")
    end
  end

  -- The backstop for a seat the screen stops asking about (M:_backstop3: the
  -- referee waiting on one of our seats while the screen waits on the
  -- referee) never stepped into any of these real fights.
  check(not contains(warns, "double battle screen"),
        "real: the backstop never stepped in: " .. table.concat(warns, " / "))

  CoopBattle.newSoloDouble = realNewSoloDouble
end

-- ===================================================================
-- 4. SoloBattle, Gen 3: the fights a kind takes over
-- ===================================================================
--
-- docs/plans/gen3-solo-remaining-fights.md: the kind registry and its hooks
-- (contract C2), every computer seat on either side answered by its own
-- owner's brain or the referee (C4), the outcome word read off how the fight
-- ended and the cart's rules (C5), the parts of the engine's finish every
-- kind needs (the Birch / scripted-loss no-whiteout arms, the first battle's
-- saved song, the engine's own battle kinds for the reports, the battle's
-- song), the cart's wild move (`wildPick`), and the sheet fields the
-- families read.  The kinds here are the suite's own minimal ones: the
-- families themselves are wave 2's, with their own suites.

do
  local Turn3 = need("BattleSim3/Turn")
  local CoopBattle = need("CoopBattle")
  local FOE = "solo_foe"

  -- The engine's whole outcome vocabulary (scripting/natives.lua).
  local CODES = {
    win = 1, won = 1, lose = 2, lost = 2, whiteout = 2, draw = 3, run = 4,
    teleport_player = 5, player_teleported = 5, fled = 6, mon_fled = 6,
    caught = 7, catch = 7, no_safari_balls = 8, forfeited = 9, mon_teleported = 10,
  }
  local realCode = FakeNatives.outcome_to_code
  FakeNatives.outcome_to_code = function(r) return CODES[r] or 1 end
  FakeAudio.clearSavedSong = function() audioCalls[#audioCalls + 1] = { "clearSavedSong" } end

  -- What the referee and the screen are built with, captured on the way.
  local createdWith, screenedWith = nil, nil
  local realCreate, realNew = Turn3.create, Mediated.new
  Turn3.create = function(o) createdWith = o; return realCreate(o) end
  Mediated.new = function(o) screenedWith = o; return realNew(o) end

  local function audioNames(from)
    local out = {}
    for i = from or 1, #audioCalls do out[#out + 1] = audioCalls[i][1] end
    return out
  end
  local function indexOf(list, value)
    for i, v in ipairs(list) do if v == value then return i end end
    return nil
  end

  -- ------- (a) the registry
  do
    local ok1, why1 = Solo.registerKind3(nil, {})
    check(not ok1 and type(why1) == "string", "registry: a kind needs a name")
    check(not Solo.registerKind3("x", "nope"), "registry: a kind is a table of hooks")
    check(not Solo.registerKind3("x", { takes = 5 }), "registry: a hook must be a function")
    eq(Solo.KINDS3.x, nil, "registry: nothing is registered on a refusal")
    local k = { note = function() end }
    check(Solo.registerKind3("x", k), "registry: a table of hooks registers")
    eq(Solo.kind3("x"), k, "registry: ...and is found by name")
    Solo.unregisterKind3("x")
    eq(Solo.kind3("x"), nil, "registry: ...and is gone again")
    -- A family module is only read when it is on disk: this facade has no
    -- reader, and a reader that finds nothing loads nothing.
    eq(Solo.kind3("safari"), nil, "registry: no family module, no kind")
    stubMod.read = function() return nil end
    eq(Solo.kind3("roamer"), nil, "registry: a reader that finds no file loads nothing")
    stubMod.read = nil
    eq(type(Solo.loadKinds3()), "table", "registry: reading every family module finds none here, quietly")
    eq(Solo.KIND_FILES3.pair, "Solo3/Doubles", "registry: a pair's module is Solo3/Doubles")
    eq(Solo.KIND_FILES3.legendary, "Solo3/Legend", "registry: ...a legendary's Solo3/Legend")
  end

  -- ------- (b) a kind nobody registered is the cart's
  do
    newGame()
    SESSION.party = { monOf(4, 30), monOf(16, 20) }
    local solo = newSolo()
    for _, o in ipairs({
      { safari = true }, { legendary = true }, { specialWild = true }, { wildScripted = true },
      { ghost = true }, { oldManTutorial = true }, { tutorialKind = "wally" },
      { firstBattleKind = "birch" }, { stand3 = { kind3 = "roamer" } }, { kind3 = "tutorial" },
      { stand3 = { kind3 = "eReaderish" } },
    }) do
      local key = next(o)
      eq(solo:fromGen3Encounter(GAME, { species = 16, level = 5 }, o), false,
         "unclaimed: a wild '" .. tostring(key) .. "' is handed back")
    end
    eq(solo:fromGen3Encounter(GAME, { species = 16, level = 5, roamer = true, foe = {} }, {}), false,
       "unclaimed: a roamer encounter is handed back")
    for _, o in ipairs({
      { trainerId = 900, twoOpponents = true, trainerIdB = 905 }, { trainerId = 900, partner = true },
      { trainerId = 900, frontier = true, battleTower = true }, { trainerId = 900, firstBattle = true },
      { trainerId = 900, trainerTower = true }, { trainerId = 900, stand3 = { kind3 = "facility" } },
    }) do
      local key
      for k2 in pairs(o) do if k2 ~= "trainerId" then key = k2 end end
      eq(solo:fromGen3Trainer(GAME, 900, o), false, "unclaimed: a trainer '" .. tostring(key) .. "' is handed back")
    end
    eq(solo:isRunning(), false, "unclaimed: nothing is running")
    eq(Stack.depth(), 0, "unclaimed: nothing went onto the stack")
    eq(#bridgeCalls, 0, "unclaimed: nothing was started in its place (the caller starts the cart's)")
    -- A stand naming the ordinary kinds is this file's own fight.
    check(solo:fromGen3Encounter(GAME, { species = 16, level = 5 }, { stand3 = { kind3 = "wild" } }),
          "unclaimed: a stand that says 'wild' is fought")
    solo:reset()
    check(solo:fromGen3Trainer(GAME, 900, { trainerId = 900, stand3 = { kind3 = "trainer" } }),
          "unclaimed: ...and one that says 'trainer'")
    solo:reset()
  end

  -- ------- (c) a wild kind, hook by hook, and the cart's wild move
  do
    newGame()
    local lead = monOf(4, 30)
    SESSION.party = { lead }
    -- A species whose common and rare items are the same: held every time --
    -- except by a legendary, which rolls none (pret SetWildMonHeldItem).
    local meta = P3._speciesMeta[16]
    meta.itemCommon, meta.itemRare = 21, 21
    PROFILE.kinds = { firstBattle = "oak", tutorial = "oldman", ghost = true, pokedude = true }
    local log, notes, views = {}, {}, {}
    local function add(name) log[#log + 1] = name end
    local Legend = {
      takes = function(_, ctx)
        add("takes")
        views.takes = { name = ctx.name, kind = ctx.kind, stand = ctx.stand }
        ctx.noDexSeen = true
        return true
      end,
      screen = function(_, ctx, so)
        add("screen")
        views.screen = ctx.screen
        so.peerName = "LEGEND"
        return { legendTag = 7 }
      end,
      seat = function(_, ctx, create)
        add("seat")
        views.seatMode = create.mode
        return { rules = { exp = false } }
      end,
      brains = function(_, ctx, npcs)
        add("brains")
        views.npcs = npcs[FOE]
        views.sim = ctx.sim
      end,
      note = function(_, _, e) notes[#notes + 1] = e.t end,
      settle = function(_, ctx)
        add("settle")
        views.verdict = ctx.verdict
      end,
      word = function(_, _, outcome, ending)
        add("word")
        views.word = ending.result
        views.saveWord = ending.word
        views.outcome = outcome
      end,
      finish = function(_, _, _, ending)
        add("finish")
        views.finishWord = ending.result
        return function() add("after") end
      end,
    }
    check(Solo.registerKind3("legendary", Legend), "kind: a legendary kind registers")
    local solo = newSolo()
    local result
    local took = solo:fromGen3Encounter(GAME, { species = 16, level = 5 }, {
      legendary = true, song = 412,
      stand3 = { kind3 = "legendary" },
      done = function(r) add("done"); result = r end,
    })
    check(took, "kind: a registered kind's fight is taken")
    eq(views.takes and views.takes.name, "legendary", "kind: takes sees the kind's name")
    eq(views.takes and views.takes.kind, "wild", "kind: ...the entry's base kind")
    check(views.takes and views.takes.stand and views.takes.stand.kind3 == "legendary", "kind: ...and the stand")
    eq(views.screen, "single", "kind: the screen hook is told it is a single")
    eq(screenedWith and screenedWith.peerName, "LEGEND", "kind: the screen hook edits the screen's options")
    eq(screenedWith and screenedWith.legendTag, 7, "kind: ...and a returned table is set on them")
    eq(screenedWith and screenedWith.song, 412, "kind: opts.song reaches the screen (the battle theme)")
    eq(createdWith and createdWith.wildPick, "cart", "wildPick: a solo wild fight asks for the cart's wild move")
    eq(createdWith and type(createdWith.rules), "table", "kind: the seat hook's create keys reach the referee")
    eq(createdWith and createdWith.rules and createdWith.rules.exp, false, "kind: ...as given")
    eq(views.npcs, "referee", "kind: a wild seat is the referee's by default (autoPick: wildPick / ai)")
    eq(views.sim, solo.sim, "kind: brains sees the referee")
    eq(solo.wildMon and solo.wildMon.item, 0, "held: a legendary rolls no held item")
    local seen = false
    for _, s in ipairs(FakeDex.seen) do if s.species == 16 then seen = true end end
    check(not seen, "kind: a kind that says noDexSeen leaves the dex alone at the send-out")
    drive(solo, function(f) f:pickMove(1) end)
    eq(result, "win", "kind: done('win')")
    eq(table.concat(log, ","), "takes,screen,seat,brains,settle,word,finish,done,after",
       "kind: the hooks in order, the finish's tail after done")
    eq(views.verdict, "win", "kind: settle sees the verdict")
    eq(views.word, "win", "kind: word sees the core's word")
    eq(views.saveWord, "win", "kind: ...and the save's")
    check(type(views.outcome) == "table" and views.outcome.reason == "ko", "kind: ...and the referee's outcome")
    check(indexOf(notes, "send") ~= nil and indexOf(notes, "over") ~= nil, "kind: note sees every event")
    local ended = effectsOf("emit")[1]
    local st = ended and ended[3].battle
    eq(st and st.legendary, true, "kinds: battle.ended's state says legendary, as the engine's would")
    eq(st and st.kinds and st.kinds.legendary, true, "kinds: ...and so do its kinds (the engine's Kinds.fromOpts)")
    eq(st and st.kinds and st.kinds.wild, true, "kinds: ...a wild")
    eq(st and st.kinds and st.kinds.trainer, nil, "kinds: ...not a trainer")
    local ql = effectsOf("questlog")[1]
    eq(ql and ql[3].kinds and ql[3].kinds.legendary, true, "kinds: the quest log is handed them too")
    Solo.unregisterKind3("legendary")

    -- The same species with no kind and no legendary: held every time.
    newGame()
    SESSION.party = { monOf(4, 30) }
    local plain = newSolo()
    check(plain:fromGen3Encounter(GAME, { species = 16, level = 5 }, {}), "held: a plain wild is taken")
    eq(plain.wildMon and plain.wildMon.item, 21, "held: common == rare is held every time (FRLG)")
    plain:reset()
    meta.itemCommon, meta.itemRare = 0, 0
    PROFILE.kinds = nil

    -- ...and gets it: the wild seat's first pick over many seeds is the cart's
    -- `Random() & 3` (both of its moves turn up), where the trainer heuristic
    -- it had before answers one fixed move for one fixed field.
    local picked = {}
    for seed = 1, 40 do
      newGame()
      SESSION.party = { monOf(4, 30) }
      local w = newSolo(seed)
      check(w:fromGen3Encounter(GAME, { species = 151, level = 5, moves = { 300, 45 } }, {}),
            "wildPick: seed " .. seed .. " taken")
      local c = w.sim and w.sim.byId[FOE].choice
      if c and c.action == "fight" then picked[c.move] = true end
      w:reset()
    end
    check(picked[1] and picked[2], "wildPick: the wild monster's pick is the cart's random move")

    -- A trainer's seats never ask for the wild move.
    newGame()
    SESSION.party = { monOf(4, 30) }
    local t = newSolo()
    check(t:fromGen3Trainer(GAME, 900, { trainerId = 900 }), "wildPick: a trainer is taken")
    eq(createdWith and createdWith.wildPick, nil, "wildPick: ...and its create asks no wild move")
    t:reset()
  end

  -- ------- (d) a kind's no, a kind that throws
  do
    newGame()
    SESSION.party = { monOf(4, 30) }
    local solo = newSolo()
    Solo.registerKind3("scripted", { takes = function() return false, "not today" end })
    eq(solo:fromGen3Encounter(GAME, { species = 16, level = 5 }, { wildScripted = true }), false,
       "takes: a kind that says no hands the fight back")
    for _, hook in ipairs({ "takes", "screen", "seat", "brains" }) do
      local mark = #warns
      Solo.registerKind3("scripted", { [hook] = function() error("boom") end })
      eq(solo:fromGen3Encounter(GAME, { species = 16, level = 5 }, { wildScripted = true }), false,
         "throw: a kind whose " .. hook .. " throws hands the fight back")
      eq(solo:isRunning(), false, "throw: ...nothing running after " .. hook)
      eq(Stack.depth(), 0, "throw: ...and nothing on the stack after " .. hook)
      check(countIn(warns, "own rules failed at '" .. hook .. "'") == 1, "throw: ...said once (" .. hook .. ")")
      dropWarnsSince(mark)
    end
    -- A note / settle / word / finish that throws costs the kind's part only.
    local mark = #warns
    local result
    Solo.registerKind3("scripted", {
      note = function() error("n") end, settle = function() error("s") end,
      word = function() error("w") end, finish = function() error("f") end,
    })
    check(solo:fromGen3Encounter(GAME, { species = 16, level = 5 }, {
      wildScripted = true, done = function(r) result = r end,
    }), "throw: a kind with throwing tail hooks is taken")
    drive(solo, function(f) f:pickMove(1) end)
    eq(result, "win", "throw: ...and the fight still ends the ordinary way")
    check(countIn(warns, "own rules failed") >= 4, "throw: ...each said")
    dropWarnsSince(mark)
    Solo.unregisterKind3("scripted")
  end

  -- ------- (e) the computer's seats, on either side (C4)
  local DStub = {}
  DStub.__index = DStub
  local function dstub(game, opts)
    return setmetatable({ game = game, opts = opts, transport = opts.transport, battle = opts.battle,
      onDone = opts.onDone, events = {}, lines = {} }, DStub)
  end
  function DStub:start(game)
    self.med = realNew({ transport = self.transport, ui = UI, game = game,
      battle = self.battle, role = "host", mode = self.opts.mode,
      npcParty = self.opts.npcParty, trainer = self.opts.trainer, peerId = self.opts.foeId })
    return self.med:start(game)
  end
  function DStub:onReady(msg) self.ready = msg end
  function DStub:onEvent(e) self.events[#self.events + 1] = e end
  function DStub:onOutcome(o) self.outcome = o end
  function DStub:say(t) self.lines[#self.lines + 1] = tostring(t) end
  function DStub:update() end
  function DStub:draw() end
  function DStub:exit()
    local f = self.onDone
    self.onDone = nil
    if f then f("?", {}) end
  end
  local realDouble = CoopBattle.newSoloDouble

  -- Two trainers (a pair): side b is two one-seat fighters, each with its
  -- own party and its own brain.
  do
    newGame()
    SESSION.party = { monOf(4, 20), monOf(16, 20) }
    CoopBattle.newSoloDouble = dstub
    local asked = { A = {}, B = {} }
    local function brain(who, answer)
      return { choose = function(_, view)
        asked[who][#asked[who] + 1] = view
        return answer(view)
      end }
    end
    -- A switches its lead out on the first turn: the claim is its own party's.
    local brainA = brain("A", function(view)
      if view.mustReplace or #asked.A > 1 then return { action = "fight", move = 0 } end
      return { action = "switch", slot = 1 }
    end)
    local brainB = brain("B", function() return { action = "fight", move = 0 } end)
    local partyB
    Solo.registerKind3("pair", {
      takes = function(_, ctx)
        ctx.double, ctx.foeSeats = true, 1
        partyB = Solo.gen3TrainerParty(FakeTrainers.foeFromId(905), 905)
        ctx.parties.solo_foe_b = partyB
        return true
      end,
      seat = function(_, ctx)
        return nil, { b = { { playerId = "solo_foe_b", name = "TRIO", mons = Sheet3.mons(GAME, partyB, {}) } } }
      end,
      brains = function(_, _, npcs)
        eq(type(npcs[FOE]), "table", "pair: the default answers the first trainer with its SoloBrain")
        return { [FOE] = brainA, solo_foe_b = brainB }
      end,
    })
    local solo = newSolo()
    check(solo:fromGen3Trainer(GAME, 907, { trainerId = 907, twoOpponents = true, trainerIdB = 905 }),
          "pair: two trainers are taken by their kind")
    local sim = solo.sim
    eq(table.concat(Solo.sideIds3(sim, "b"), ","), "solo_foe,solo_foe_b", "pair: side b is the two trainers")
    eq(table.concat(Solo.sideIds3(sim, "a"), ","), "solo_player,solo_player#2", "pair: side a the player's two seats")
    local screen = solo.fight
    eq(screen and screen.ready and table.concat(screen.ready.sides.b, ","), "solo_foe,solo_foe_b",
       "pair: the screen is told every seat on side b")
    check(#asked.A >= 1 and #asked.B >= 1, "pair: each trainer's own brain was asked")
    local onlyOwn = true
    for _, v in ipairs(asked.A) do if v.fighter.owner ~= FOE then onlyOwn = false end end
    for _, v in ipairs(asked.B) do if v.fighter.owner ~= "solo_foe_b" then onlyOwn = false end end
    check(onlyOwn, "pair: ...and only for its own seat")
    local va, vb = asked.A[1], asked.B[1]
    eq(va.side, "b", "pair: A's view is on side b")
    eq(va.double, true, "pair: ...a double")
    eq(va.seat, 3, "pair: ...A on slot 3")
    eq(vb.seat, 4, "pair: ...B on slot 4")
    eq(va.partnerSlot, 4, "pair: A's partner is B's battler")
    eq(vb.partnerSlot, 3, "pair: ...and B's is A's")
    eq(#va.foes, 2, "pair: both of the player's battlers are the foes")
    eq(va.foes[1].slot, 0, "pair: ...the player's left first")
    eq(sim.byId[FOE].choice and sim.byId[FOE].choice.action, "switch", "pair: A filed its switch")
    eq(next(vb.claimed), nil, "pair: B's view claims nothing of A's party (a claim is per party)")
    solo:reset()
    Solo.unregisterKind3("pair")
    CoopBattle.newSoloDouble = realDouble
  end

  -- Steven beside you (a partner): side a's second fighter is an NPC with its
  -- own brain; the player's seat stays the screen's.
  do
    newGame()
    SESSION.party = { monOf(4, 20), monOf(16, 20) }
    CoopBattle.newSoloDouble = dstub
    local allyViews = {}
    local ally = function(view, seat)
      allyViews[#allyViews + 1] = { view = view, seat = seat }
      return { action = "fight", move = 0 }
    end
    Solo.registerKind3("partner", {
      takes = function(_, ctx) ctx.double, ctx.foeSeats = true, 2; return true end,
      seat = function(_, _, create)
        create.sides.a[1].seats = nil
        return nil, { a = { { playerId = "solo_ally", name = "STEVEN",
                              mons = Sheet3.mons(GAME, { monOf(5, 30) }, {}) } } }
      end,
      brains = function() return { solo_ally = ally } end,
    })
    local solo = newSolo()
    check(solo:fromGen3Trainer(GAME, 905, { trainerId = 905, partner = true }), "partner: Steven's fight is taken")
    local sim = solo.sim
    eq(table.concat(Solo.sideIds3(sim, "a"), ","), "solo_player,solo_ally", "partner: side a is the player and Steven")
    check(#allyViews >= 1, "partner: Steven's own brain was asked")
    local v = allyViews[1] and allyViews[1].view
    eq(v and v.side, "a", "partner: ...from side a")
    eq(v and v.seat, 1, "partner: ...on slot 1")
    eq(v and v.partnerSlot, 0, "partner: ...the player beside him")
    eq(v and #v.foes, 2, "partner: ...the trainer's two battlers across")
    eq(v and v.foes[1].slot, 3, "partner: ...by slot")
    eq(allyViews[1] and allyViews[1].seat and allyViews[1].seat.playerId, "solo_ally", "partner: ...and his seat")
    check(sim.byId.solo_ally.choice ~= nil, "partner: Steven's choice is filed")
    eq(sim.byId.solo_player.choice, nil, "partner: the player's own seat is left to the screen")
    eq(solo:_seat3({ seat = 1 }), nil, "partner: the player cannot command Steven's slot")
    eq(solo:_seat3({ seat = 0 }), "solo_player", "partner: ...only their own")
    solo:reset()
    Solo.unregisterKind3("partner")
    CoopBattle.newSoloDouble = realDouble
  end

  -- A scripted seat (a tutorial): `false` waits for its beat, and the kind
  -- may answer the player's own seat; `false` in the map is nobody.
  do
    newGame()
    SESSION.party = { monOf(4, 30) }
    local hold = 2
    Solo.registerKind3("tutorial", {
      brains = function(_, _, npcs)
        npcs.solo_player = function() return { action = "fight", move = 0 } end
        npcs[FOE] = function()
          if hold > 0 then hold = hold - 1; return false end
          return { action = "fight", move = 0 }
        end
      end,
    })
    local solo = newSolo()
    check(solo:fromGen3Encounter(GAME, { species = 16, level = 3 }, { tutorialKind = "wally" }),
          "scripted: a tutorial-shaped kind is taken")
    local sim = solo.sim
    eq(sim.turn, 1, "scripted: turn 1")
    check(sim.byId.solo_player.choice ~= nil, "scripted: the kind answered the player's own seat")
    eq(sim.byId[FOE].choice, nil, "scripted: a brain that says false is not answered for")
    solo:update(0.5, GAME)
    eq(sim.turn, 1, "scripted: ...and is asked again next frame, the turn still open")
    solo:update(0.5, GAME)
    check(sim.turn > 1 or sim:outcome() ~= nil, "scripted: its answer, once given, closes the turn")
    solo:reset()
    Solo.registerKind3("tutorial", { brains = function(_, _, npcs) npcs[FOE] = false end })
    local quiet = newSolo()
    check(quiet:fromGen3Encounter(GAME, { species = 16, level = 3 }, { tutorialKind = "wally" }),
          "scripted: taken again")
    quiet:update(0.5, GAME)
    eq(quiet.sim.byId[FOE].choice, nil, "scripted: an owner mapped to false is answered by nobody")
    quiet:reset()
    Solo.unregisterKind3("tutorial")
  end

  -- ------- (f) the outcome word (C5)
  do
    local function words(t) return table.concat({ Solo.gen3Words(t) }, "/") end
    eq(words({ verdict = "win", reason = "catch", how = "catch", by = "a" }), "caught/caught", "C5: a catch")
    eq(words({ verdict = "win", reason = "run", how = "flee", by = "b" }), "mon_fled/mon_fled",
       "C5: a wild seat's own RUN (a roamer, Birch's Zigzagoon) is MON_FLED")
    eq(words({ verdict = "loss", reason = "run", how = "run", by = "a" }), "run/run", "C5: the player's RUN")
    eq(words({ verdict = "win", reason = "run", how = "run", by = "a" }), "run/run",
       "C5: a POKe DOLL names us the winners and is still RAN")
    -- FireRed / LeafGreen: PLAYER_TELEPORTED whoever ended it.
    eq(words({ verdict = "loss", reason = "run", how = "roar", by = "a", teleportBySide = false }),
       "teleport_player/teleport_player", "C5 (FRLG): the player's WHIRLWIND on Mewtwo is 'ran from', never the catch path")
    eq(words({ verdict = "win", reason = "run", how = "teleport", by = "b", teleportBySide = false }),
       "teleport_player/teleport_player", "C5 (FRLG): the wild monster's TELEPORT is PLAYER_TELEPORTED too")
    -- Emerald: by the user's side.
    eq(words({ verdict = "win", reason = "run", how = "teleport", by = "b", teleportBySide = true }),
       "mon_teleported/mon_teleported", "C5 (EM): Mew's TELEPORT is MON_TELEPORTED -- FARAWAY ISLAND keeps the Mew")
    eq(words({ verdict = "loss", reason = "run", how = "teleport", by = "a", teleportBySide = true }),
       "teleport_player/teleport_player", "C5 (EM): the player's TELEPORT is PLAYER_TELEPORTED")
    eq(words({ verdict = "win", reason = "run", how = "roar", by = "b", teleportBySide = true }),
       "mon_teleported/mon_teleported", "C5 (EM): the wild monster's ROAR")
    eq(words({ verdict = "loss", reason = "run", how = "roar", by = "a", teleportBySide = true }),
       "teleport_player/teleport_player", "C5 (EM): the player's WHIRLWIND")
    eq(words({ verdict = "draw", reason = "balls", how = "balls" }), "no_safari_balls/no_safari_balls",
       "C5: out of Safari Balls")
    eq(words({ verdict = "loss", reason = "run", how = "forfeit", by = "a", kind = "trainer" }),
       "forfeited/forfeited", "C5: a forfeit")
    eq(words({ verdict = "win", reason = "ko", how = "judge", by = "a", kind = "trainer" }), "win/win",
       "C5: an Arena judgment won")
    eq(words({ verdict = "loss", reason = "ko", how = "judge", by = "b", kind = "trainer" }), "lose/lose",
       "C5: ...and lost")
    -- Both sides out at once: the player whites out (pret IsPlayerDefeated
    -- counts DREW) and `done` hears "lose", but the save keeps DREW --
    -- Cmd_checkteamslost ORs B_OUTCOME_LOST and B_OUTCOME_WON (W3-CORE).
    eq(words({ verdict = "draw", reason = "ko", how = "ko", whiteout = true, kind = "trainer" }), "lose/draw",
       "C5: a double-knockout whiteout is a defeat to the script, DREW to the save")
    eq(words({ verdict = "draw", reason = "ko", how = "ko", whiteout = true, kind = "wild" }), "lose/draw",
       "C5: ...a wild one too")
    eq(words({ verdict = "loss", reason = "ko", how = "ko", by = "b", whiteout = true, kind = "trainer" }),
       "lose/lose", "C5: a whiteout lost outright is LOST to both")
    eq(words({ verdict = "draw", reason = "ko", whiteout = true }), "lose/draw",
       "C5: ...and a referee with no `how` reads the same")
    eq(words({ verdict = "draw", reason = "timeout", kind = "trainer" }), "lose/draw",
       "C5: a trainer's draw is 'lose' to the opcode, DREW to the save")
    eq(words({ verdict = "draw", reason = "timeout", kind = "wild" }), "draw/draw", "C5: a wild draw")
    eq(words({ verdict = "win", reason = "run", ranSide = "b" }), "mon_fled/mon_fled",
       "C5: a referee with no `how` is read by the run's side")
    check(Solo.teleportBySide3({ rules = { teleportOutcome = "side" } }, "frlg"), "C5: the profile's rule decides")
    check(not Solo.teleportBySide3({ family = "frlg", rules = {} }), "C5: ...else FRLG says PLAYER_TELEPORTED")
    check(Solo.teleportBySide3({ family = "rse", rules = {} }), "C5: ...and Emerald by side")
    check(not Solo.teleportBySide3(nil, "frlg"), "C5: ...or the family when there is no profile")
    eq(Solo.ENGINE_RESULT3.mon_fled, "fled", "C5: battle.ended speaks the engine's 'fled'")

    -- Through a fight: Emerald's Mew teleports away.
    newGame()
    SESSION.party = { monOf(4, 30) }
    PROFILE.family = "rse"
    PROFILE.rules.teleportOutcome = "side"
    local solo = newSolo()
    local result
    check(solo:fromGen3Encounter(GAME, { species = 151, level = 30 }, { done = function(r) result = r end }),
          "C5 (EM): the wild fight is taken")
    solo.sim:_finish("win", { FOE }, { "solo_player" }, "run")
    solo.sim.result.how, solo.sim.result.by = "teleport", "b"
    drive(solo, function(f) f:pickMove(1) end)
    eq(result, "mon_teleported", "C5 (EM): done('mon_teleported')")
    eq(SESSION.battleOutcome, 10, "C5 (EM): ...B_OUTCOME_MON_TELEPORTED in the save")
    local tv = effectsOf("rse")[1]
    eq(tv and tv[8], 10, "C5 (EM): ...and to the TV")
    PROFILE.family = "frlg"
    PROFILE.rules.teleportOutcome = nil

    -- FireRed: the player's WHIRLWIND blows Mewtwo away.
    newGame()
    SESSION.party = { monOf(4, 30) }
    local fr = newSolo()
    check(fr:fromGen3Encounter(GAME, { species = 151, level = 30 }, { done = function(r) result = r end }),
          "C5 (FRLG): taken")
    fr.sim:_finish("win", { FOE }, { "solo_player" }, "run")
    fr.sim.result.how, fr.sim.result.by = "roar", "a"
    drive(fr, function(f) f:pickMove(1) end)
    eq(result, "teleport_player", "C5 (FRLG): done('teleport_player') -- 'ran from', the legend stays")
    eq(SESSION.battleOutcome, 5, "C5 (FRLG): ...B_OUTCOME_PLAYER_TELEPORTED")
    local ended = effectsOf("emit")[1]
    eq(ended and ended[3].result, "player_teleported", "C5 (FRLG): battle.ended in the engine's word")

    -- A wild seat's flee: MON_FLED, "fled" to battle.ended.
    newGame()
    SESSION.party = { monOf(4, 30) }
    local fl = newSolo()
    check(fl:fromGen3Encounter(GAME, { species = 16, level = 5 }, { done = function(r) result = r end }),
          "C5 (flee): taken")
    fl.sim:_finish("win", { "solo_player" }, { FOE }, "run")
    fl.sim.result.how, fl.sim.result.by = "flee", "b"
    drive(fl, function(f) f:pickMove(1) end)
    eq(result, "mon_fled", "C5 (flee): done('mon_fled')")
    eq(SESSION.battleOutcome, 6, "C5 (flee): ...B_OUTCOME_MON_FLED")
    eq(effectsOf("emit")[1] and effectsOf("emit")[1][3].result, "fled", "C5 (flee): battle.ended says 'fled'")

    -- Both sides out at once, on the referee's own outcome: the player's
    -- last monster uses an invented EXPLOSION (pret's EFFECT_EXPLOSION) on
    -- the wild one.  The cart whites the player out (IsPlayerDefeated counts
    -- DREW) and the script hears a defeat, but gBattleOutcome is DREW
    -- (Cmd_checkteamslost ORs LOST and WON) -- what a roamer's writeback and
    -- a post-battle script read.
    ROM[101] = { effect = E.EXPLOSION, power = 250, type = 0, accuracy = 100, pp = 5,
                 secondaryChance = 0, target = 0, priority = 0, flags = 2 }
    P3._moveNames[101] = "BLAST"
    newGame()
    SESSION.party = { monOf(4, 30, { moves = { 101 }, pp = { 5 }, maxPp = { 5 } }) }
    local dk = newSolo()
    local dkResult, dkCalls = nil, 0
    check(dk:fromGen3Encounter(GAME, { species = 16, level = 3 },
      { done = function(r) dkResult = r; dkCalls = dkCalls + 1 end }), "double KO: taken")
    local dkSim = dk.sim
    drive(dk, function(f) f:pickMove(1) end)
    local dkOut = dkSim and dkSim:outcome() or {}
    eq(dkOut.outcome, "draw", "double KO: the referee calls it a draw")
    eq(dkOut.how, "ko", "double KO: ...by knockout")
    eq(dk:isRunning(), false, "double KO: the fight is over")
    eq(dkResult, "lose", "double KO: done('lose') -- the player whited out")
    eq(dkCalls, 1, "double KO: ...once")
    eq(SESSION.battleOutcome, 3, "double KO: the save says B_OUTCOME_DREW, not LOST")
    eq(fieldCalls[1], "respawn", "double KO: the whiteout's respawn")

    -- The whole way through, on the referee's own outcome: a wild monster
    -- that knows only TELEPORT (an invented row on pret's EFFECT_TELEPORT)
    -- leaves on the cart's random wild move -- MON_TELEPORTED on Emerald,
    -- PLAYER_TELEPORTED on FireRed.
    ROM[100] = { effect = E.TELEPORT, power = 0, type = 14, accuracy = 0, pp = 20,
                 secondaryChance = 0, target = 16, priority = 0, flags = 0 }
    P3._moveNames[100] = "TELEPORT"
    for _, row in ipairs({ { "rse", "side", "mon_teleported", 10 }, { "frlg", nil, "teleport_player", 5 } }) do
      newGame()
      SESSION.party = { monOf(4, 30, { moves = { 45 }, pp = { 40 }, maxPp = { 40 } }) }
      PROFILE.family = row[1]
      PROFILE.rules.teleportOutcome = row[2]
      local tp = newSolo()
      local tr
      check(tp:fromGen3Encounter(GAME, { species = 151, level = 5, moves = { 100 } },
        { done = function(r) tr = r end }), "C5 (" .. row[1] .. ", TELEPORT): taken")
      drive(tp, function(f) f:pickMove(1) end)
      eq(tr, row[3], "C5 (" .. row[1] .. ", TELEPORT): the wild monster's TELEPORT is " .. row[3])
      eq(SESSION.battleOutcome, row[4], "C5 (" .. row[1] .. ", TELEPORT): ...code " .. row[4])
    end
    PROFILE.family = "frlg"
    PROFILE.rules.teleportOutcome = nil

    -- Facilities retain draws. A timeout is not a knockout, so a pair is
    -- not completed as a win: the kind's word is what the caller hears, and
    -- the save stays DREW.
    for _, row in ipairs({ { "facility", "draw" }, { "pair", "lose" } }) do
      newGame()
      SESSION.party = { monOf(4, 20, { moves = { 10 }, pp = { 35 }, maxPp = { 35 } }) }
      Solo.registerKind3(row[1], {
        takes = function(_, ctx) ctx.double = false; return true end,
        word = function(_, _, _, ending)
          if ending.word == "draw" then return row[2] end
        end,
      })
      local op = trainerOpcode()
      FakeVm.running = true
      local s = newSolo()
      local o = { trainerId = 900, done = op.done }
      o[row[1] == "facility" and "trainerHill" or "twoOpponents"] = true
      check(s:fromGen3Trainer(GAME, 900, o), "C5 (" .. row[1] .. "): taken")
      s.sim:_finish("draw", nil, nil, "timeout")
      drive(s, function(f) f:pickMove(1) end)
      eq(op.answered, row[2], "C5 (" .. row[1] .. "): the kind's word reaches its caller")
      eq(FakeVm.halted, 0, "C5 (" .. row[1] .. "): ...and nothing is halted")
      eq(SESSION.battleOutcome, 3, "C5 (" .. row[1] .. "): the save records DREW")
      Solo.unregisterKind3(row[1])
      FakeVm.running = false
    end
  end

  -- ------- (g) the finish every kind needs
  -- Emerald's first battle: never a whiteout, the saved song let go.
  do
    newGame()
    local lead = monOf(4, 5, { moves = { 10 }, pp = { 35 }, maxPp = { 35 }, hp = 3 })
    SESSION.party = { lead }
    SESSION.money = 500
    PROFILE.family = "rse"
    Solo.registerKind3("firstBattle", { takes = function() return true end })
    local solo = newSolo()
    local result
    check(solo:fromGen3Encounter(GAME, { species = 151, level = 70, moves = { 300 } },
      { wild = true, firstBattleKind = "birch", done = function(r) result = r end }), "birch: taken")
    local from = #audioCalls + 1
    local _, fight = drive(solo, function(f) f:pickMove(1) end)
    eq(result, "lose", "birch: a loss is still 'lose' to the script")
    eq(#fieldCalls, 0, "birch: no whiteout warp (CB2_EndFirstBattle)")
    eq(SESSION.money, 500, "birch: no money lost")
    eq(lead.hp, 0, "birch: and no heal -- the script heals the party itself")
    check(textOf(fight):find("STRINGID_PLAYERWHITEOUT", 1, true) ~= nil,
          "birch: the cart's lost lines are still said (BattleScript_LocalBattleLost)")
    local names = audioNames(from)
    local cleared = indexOf(names, "clearSavedSong")
    check(cleared ~= nil, "birch: the saved song is let go (Overworld_ClearSavedMusic)")
    local restored = nil
    for i = (cleared or 1) + 1, #names do if names[i] == "restoreMapSong" then restored = i end end
    check(restored ~= nil, "birch: ...and the map's own song restored after it")
    local tv = effectsOf("rse")[1]
    eq(tv and tv[9] and tv[9].firstBattle, true, "birch: the TV is told it was a first battle (never on air)")
    eq(tv and tv[9] and tv[9].trainer, false, "birch: ...a wild one")
    PROFILE.family = "frlg"
    Solo.unregisterKind3("firstBattle")
  end

  -- A scripted loss (Steven, the Frontier): no whiteout, no heal, and the
  -- caller is answered -- never the draw's halt.
  do
    newGame()
    local lead = monOf(4, 5, { moves = { 10 }, pp = { 35 }, maxPp = { 35 }, hp = 3 })
    SESSION.party = { lead }
    SESSION.money = 500
    local op = trainerOpcode()
    FakeVm.running = true
    local solo = newSolo()
    check(solo:fromGen3Trainer(GAME, 901, { trainerId = 901, scriptedLoss = true, done = op.done }),
          "scriptedLoss: taken")
    local _, fight = drive(solo, function(f) f:pickMove(1) end)
    eq(op.answered, "lose", "scriptedLoss: the script is answered 'lose'")
    eq(FakeVm.halted, 0, "scriptedLoss: ...not halted")
    eq(#fieldCalls, 0, "scriptedLoss: no whiteout warp")
    eq(SESSION.money, 500, "scriptedLoss: no money lost")
    eq(lead.hp, 0, "scriptedLoss: no heal")
    check(textOf(fight):find("STRINGID_PLAYERLOSTAGAINSTENEMYTRAINER", 1, true) ~= nil,
          "scriptedLoss: the lost lines are said")
    FakeVm.running = false

    -- noWhiteout with deferHeal (a Secret Base): no heal now either.
    newGame()
    local held = monOf(4, 5, { moves = { 10 }, pp = { 35 }, maxPp = { 35 }, hp = 3 })
    SESSION.party = { held }
    local d = newSolo()
    local dr
    check(d:fromGen3Trainer(GAME, 901, { trainerId = 901, noWhiteout = true, deferHeal = true,
      done = function(r) dr = r end }), "deferHeal: taken")
    drive(d, function(f) f:pickMove(1) end)
    eq(dr, "lose", "deferHeal: 'lose'")
    eq(#fieldCalls, 0, "deferHeal: no whiteout")
    eq(held.hp, 0, "deferHeal: the heal is the caller's, later")
  end

  -- ------- (h) a kind's own choices, flags and hand-back
  do
    newGame()
    local lead = monOf(4, 30)
    SESSION.party = { lead }
    local settledWhiteout = "unset"
    Solo.registerKind3("safari", {
      takes = function(_, ctx) ctx.lossless, ctx.noReconcile = true, true; return true end,
      choose = function(_, ctx, payload)
        if payload.action == "run" then ctx.solo:parkLine3("NOT YET"); return true, true end
      end,
      settle = function(_, ctx) settledWhiteout = ctx.whiteout end,
    })
    local solo = newSolo()
    local result
    check(solo:fromGen3Encounter(GAME, { species = 16, level = 5 }, { safari = true,
      done = function(r) result = r end }), "choose: taken")
    local f = toMenu(solo)
    local turn = solo.sim.turn
    f:sendChoice({ action = "run" })
    solo:update(0.5, GAME)
    for _ = 1, 40 do f:update(2.0); if f.phase == "choose" then break end end
    check(textOf(f):find("NOT YET", 1, true) ~= nil, "choose: the kind's line is said")
    eq(solo.sim.turn, turn, "choose: ...no turn spent")
    eq(f.phase, "choose", "choose: ...and the menu is back")
    -- Out of balls with nobody standing on side a: no defeat (lossless), and
    -- the party is not touched (noReconcile).
    solo.sim.byId.solo_player.mons[1].hp = 0
    solo.sim:_finish("draw", nil, nil, "balls")
    solo.sim.result.how = "balls"
    local _, sf = drive(solo, function(fx) fx:pickMove(1) end)
    eq(result, "no_safari_balls", "lossless: done('no_safari_balls')")
    eq(SESSION.battleOutcome, 8, "lossless: ...B_OUTCOME_NO_SAFARI_BALLS")
    eq(settledWhiteout, false, "lossless: nobody standing on side a is not a defeat")
    check(not textOf(sf):find("STRINGID_PLAYERWHITEOUT", 1, true), "lossless: ...and says no lost lines")
    eq(#fieldCalls, 0, "lossless: no whiteout")
    eq(lead.hp, lead.maxHp, "noReconcile: the party is not written")
    Solo.unregisterKind3("safari")

    -- handBack: the kind puts back what it took, and may start the cart's own.
    local handed = {}
    Solo.registerKind3("roamer", { handBack = function(_, ctx)
      handed[#handed + 1] = ctx.solo.handingBack3
      return #handed == 1
    end })
    newGame()
    SESSION.party = { monOf(4, 30) }
    local r1 = newSolo()
    check(r1:fromGen3Encounter(GAME, { species = 16, level = 5 }, { roamer = true }), "handBack: taken")
    r1:reset()
    eq(handed[1], true, "handBack: asked under the hand-back guard")
    eq(#bridgeCalls, 0, "handBack: a kind that started the cart's fight itself is not second-guessed")
    check(r1:fromGen3Encounter(GAME, { species = 16, level = 5 }, { roamer = true }), "handBack: taken again")
    r1:reset()
    eq(bridgeCalls[1] and bridgeCalls[1][1], "startWild", "handBack: ...else the core hands it back")
    Solo.unregisterKind3("roamer")
  end

  -- ------- (i) the stand door
  do
    newGame()
    SESSION.party = { monOf(4, 30) }
    local solo = newSolo()
    local lead = Solo.gen3FoeMon({ species = 16, level = 4 }, { wild = true })
    check(solo:fromGen3Stand(GAME, { kind = "wild", kind3 = "wild", enemyParty = { lead } }, {}),
          "stand: a stand with only its monsters is fought as an encounter")
    eq(solo.wildMon, lead, "stand: ...with the stand's own monster")
    eq(solo.gen3 and solo.gen3.stand and solo.gen3.stand.kind3, "wild", "stand: ...and the stand on the fight")
    solo:reset()
    check(solo:fromGen3Stand(GAME, { kind = "trainer", kind3 = "trainer", trainerId = 900 }, { trainerId = 900 }),
          "stand: a trainer stand is fought as the trainer")
    eq(solo.gen3 and solo.gen3.trainer and solo.gen3.trainer.trainerId, 900, "stand: ...that trainer")
    solo:reset()
    eq(solo:fromGen3Stand(GAME, { kind = "wild" }, {}), false, "stand: a stand with nothing to fight declines")
    eq(solo:fromGen3Stand(GAME, nil, {}), false, "stand: no stand declines")
  end

  -- ------- (j) the foe's held item and the sheet fields the families read
  do
    newGame()
    local meta = P3._speciesMeta[16]
    local function roll(common, rare, r)
      meta.itemCommon, meta.itemRare = common, rare
      local draws = 0
      local item = Solo.gen3WildItem(16, function() draws = draws + 1; return r end)
      return item, draws
    end
    eq(roll(21, 21, 0), 21, "held (FRLG): common == rare is held every time")
    eq(select(2, roll(0, 0, 0)), 1, "held (FRLG): one Random() is drawn whatever the species holds")
    eq(roll(21, 127, 44), 0, "held (FRLG): 0..44 holds nothing")
    eq(roll(21, 127, 45), 21, "held (FRLG): 45..94 the common item")
    eq(roll(21, 127, 94), 21, "held (FRLG): ...to 94")
    eq(roll(21, 127, 95), 127, "held (FRLG): 95..99 the rare one")
    eq(roll(21, 0, 95), 0, "held (FRLG): a species with only a common item holds nothing at 95")
    eq(roll(0, 127, 99), 127, "held (FRLG): ...and one with only a rare item holds it there")
    meta.itemCommon, meta.itemRare = 0, 0
    check(not Solo.gen3HeldRoll({ legendary = true }, {}), "heldRoll: not a legendary")
    check(not Solo.gen3HeldRoll({}, { specialWild = true }), "heldRoll: ...nor FRLG's special wild")
    check(not Solo.gen3HeldRoll({}, { ghostUnveiled = true }), "heldRoll: ...nor the scoped Marowak")
    check(not Solo.gen3HeldRoll({ pike = true }, {}), "heldRoll: ...nor a Pike wild")
    check(not Solo.gen3HeldRoll({ regi = true }, {}), "heldRoll: ...nor Emerald's legend kinds")
    check(Solo.gen3HeldRoll({ legendary = false }, {}), "heldRoll: a plain wild rolls")
    local fateful = Solo.gen3FoeMon({ species = 151, level = 30, fatefulEncounter = true }, { wild = true, heldRoll = false })
    eq(fateful and fateful.fatefulEncounter, true, "fateful: the event monster keeps its bit")

    -- safariFleeRate on a wild sheet, from the species row.
    meta.safariZoneFleeRate = 125
    local wildSheet = Sheet3.mon(SESSION, monOf(16, 5), 0, { wild = true })
    eq(wildSheet and wildSheet.safariFleeRate, 125, "sheet: a wild sheet carries the species' Safari flee rate")
    local ownSheet = Sheet3.mon(SESSION, monOf(16, 5), 0, { own = true })
    eq(ownSheet and ownSheet.safariFleeRate, nil, "sheet: ...no other sheet does")
    meta.safariZoneFleeRate = nil
    eq(Sheet3.mon(SESSION, monOf(16, 5), 0, { wild = true }).safariFleeRate, nil,
       "sheet: ...nor a species row without one")
    -- fateful: on the wild sheet, back onto a monster rebuilt from it.
    local mew = monOf(151, 30, { fatefulEncounter = true })
    local mewSheet = Sheet3.mon(SESSION, mew, 0, { wild = true })
    eq(mewSheet and mewSheet.fateful, true, "sheet: a fateful wild says so")
    eq(Sheet3.mon(SESSION, monOf(151, 30), 0, { wild = true }).fateful, nil, "sheet: ...an ordinary one does not")
    local rebuilt = Sheet3.monFromSheet(mewSheet, SESSION)
    eq(rebuilt and rebuilt.fatefulEncounter, true, "sheet: a catch rebuilt from it keeps the bit")

    -- arenaMind: the cart's mind ratings (synthetic here), move number + 1.
    local F2 = { arena = function() return { mindRatings = { [11] = 1, [46] = -1 } } end }
    stub("src.core.game3.rse.frontier.f2_data", F2)
    Sheet3.resetArenaMinds()
    local rows = Sheet3.moves(monOf(4, 5), { arena = true })
    eq(rows[1] and rows[1].arenaMind, 1, "arena: a move row carries its mind rating")
    eq(rows[2] and rows[2].arenaMind, -1, "arena: ...a PROTECT-like -1 too")
    eq(Sheet3.moves(monOf(4, 5))[1].arenaMind, nil, "arena: ...only when asked")
    local sheet = Sheet3.mon(SESSION, monOf(4, 5), 0, { arena = true })
    eq(sheet and sheet.moves[1].arenaMind, 1, "arena: ...through a whole sheet")
    local plainSheets = Sheet3.mons(GAME, { monOf(4, 5) }, {})
    eq(Sheet3.stampArenaMind(plainSheets), 2, "arena: a built party is stamped row by row")
    eq(plainSheets[1].moves[2].arenaMind, -1, "arena: ...as the cart rates it")
    F2.arena = function() error("frontier f2: missing from the cache") end
    Sheet3.resetArenaMinds()
    eq(Sheet3.arenaMind(10), nil, "arena: a cart without the table has no rating")
    eq(Sheet3.moves(monOf(4, 5), { arena = true })[1].arenaMind, nil, "arena: ...and no row says one")
    Sheet3.resetArenaMinds()
  end

  -- ------- (k) W3-CORE: SetWildMonHeldItem over a row's own item, the
  -- ALTERING CAVE, a caught monster's sleep counter
  do
    newGame()
    local meta = P3._speciesMeta[16]
    -- FireRed / LeafGreen (pokefirered pokemon.c:6032): whether the draw
    -- wrote the held item at all is the second answer.
    local function roll2(common, rare, r)
      meta.itemCommon, meta.itemRare = common, rare
      return Solo.gen3WildItem(16, function() return r end)
    end
    local function both(item, wrote) return tostring(item) .. "/" .. tostring(wrote) end
    eq(select(2, roll2(21, 127, 44)), false, "wrote (FRLG): 0..44 returns early, writing nothing")
    eq(select(2, roll2(21, 127, 45)), true, "wrote (FRLG): 45..94 writes the common item")
    eq(select(2, roll2(21, 127, 99)), true, "wrote (FRLG): 95..99 the rare one")
    eq(both(roll2(0, 0, 3)), "0/true",
       "wrote (FRLG): common == rare == ITEM_NONE writes ITEM_NONE, whatever the draw")
    eq(both(roll2(21, 0, 95)), "0/true", "wrote (FRLG): ...as does an empty rare slot at 95")

    -- A row's own item (setwildbattle's): rolled over whenever the draw
    -- writes (CB2_InitBattleInternal runs SetWildMonHeldItem after the
    -- script made the monster), kept when it returns early, and kept by a
    -- fight the roll is not for (a LEGENDARY).  The row fixes personality and
    -- IVs, so the item roll is the one Random() drawn.
    local realRandom = FakeRng.Random
    local function built(draw, row, opts)
      local draws = 0
      FakeRng.Random = function() draws = draws + 1; return draw end
      local base = { species = 16, level = 5, personality = 3,
                     ivs = { hp = 1, atk = 1, def = 1, spe = 1, spa = 1, spd = 1 } }
      for k, v in pairs(row or {}) do base[k] = v end
      local ok, mon = pcall(Solo.gen3FoeMon, base, opts)
      FakeRng.Random = realRandom
      return ok and mon or nil, draws
    end
    meta.itemCommon, meta.itemRare = 21, 127
    local over = built(50, { item = 13 }, { wild = true })
    eq(over and over.item, 21, "scripted item (FRLG): a draw that writes rolls over setwildbattle's item")
    eq(over and over.heldItem, 21, "scripted item (FRLG): ...both spellings")
    local kept, keptDraws = built(10, { item = 13 }, { wild = true })
    eq(kept and kept.item, 13, "scripted item (FRLG): a draw under 45 leaves it")
    eq(keptDraws, 1, "scripted item (FRLG): ...the Random() still drawn")
    local legend, legendDraws = built(50, { item = 13 }, { wild = true, heldRoll = false })
    eq(legend and legend.item, 13, "scripted item: a LEGENDARY fight keeps the script's item (no roll)")
    eq(legendDraws, 0, "scripted item: ...and draws nothing for it")
    meta.itemCommon, meta.itemRare = 0, 0
    local cleared = built(10, { item = 13 }, { wild = true })
    eq(cleared and cleared.item, 0, "scripted item (FRLG): an item-less species' roll writes ITEM_NONE over it")
    meta.itemCommon, meta.itemRare = 143, 143
    local snorlax = built(10, { item = 0 }, { wild = true })
    eq(snorlax and snorlax.item, 143, "scripted item (FRLG): common == rare is held over the script's ITEM_NONE "
       .. "(Route 12's SNORLAX and its LEFTOVERS)")
    local trainerMon = built(50, { item = 13 }, { wild = false })
    eq(trainerMon and trainerMon.item, 13, "scripted item: a trainer's monster is never rolled")
    meta.itemCommon, meta.itemRare = 0, 0

    -- Emerald: the engine's own roll (encounter_rules/rse.lua wildHeldItem):
    -- nil = returned early, a number = written; `alteringCave` its cave arm.
    newGame({ version = "emerald" })
    local realRules = FakeEncounters.rules
    local asks, answer = {}, nil
    FakeEncounters.rules = function()
      return { wildHeldItem = function(species, opts)
        asks[#asks + 1] = { species = species, opts = opts }
        return answer
      end }
    end
    answer = nil
    eq(both(Solo.gen3WildItem(16, function() return 0 end)), "0/false",
       "wrote (EM): the engine's nil is an early return")
    answer = 0
    eq(both(Solo.gen3WildItem(16, function() return 0 end)), "0/true",
       "wrote (EM): ...its 0 a written ITEM_NONE")
    answer = 21
    local emOver = built(50, { item = 13 }, { wild = true })
    eq(emOver and emOver.item, 21, "scripted item (EM): a written item rolls over setwildbattle's")
    answer = nil
    local emKept = built(50, { item = 13 }, { wild = true })
    eq(emKept and emKept.item, 13, "scripted item (EM): an early return leaves it")
    answer = 0
    local emClear = built(50, { item = 13 }, { wild = true })
    eq(emClear and emClear.item, 0, "scripted item (EM): a written ITEM_NONE clears it")
    eq(asks[#asks] and asks[#asks].opts and asks[#asks].opts.alteringCave, nil,
       "altering cave: not asked for off the cave")
    answer = 202
    local cave = built(50, nil, { wild = true, alteringCave = true })
    eq(cave and cave.item, 202, "altering cave: the builder holds what the cave's roll gave")
    eq(asks[#asks] and asks[#asks].opts and asks[#asks].opts.alteringCave, true,
       "altering cave: ...asked with the cave's arm on (pokeemerald pokemon.c:6692)")
    check(Solo.gen3AlteringCave("EM_ALTERING_CAVE"), "altering cave: Emerald's ALTERING CAVE")
    check(not Solo.gen3AlteringCave("FR_SIX_ISLAND_ALTERING_CAVE"), "altering cave: ...not FireRed's (no such arm)")
    check(not Solo.gen3AlteringCave(nil), "altering cave: ...nor no map")
    -- Through the door: the map the encounter was met on reaches the roll.
    for _, row in ipairs({ { "EM_ALTERING_CAVE", true }, { "EM_ROUTE_101", nil } }) do
      newGame({ version = "emerald" })
      SESSION.party = { monOf(4, 30) }
      asks, answer = {}, 202
      local ac = newSolo()
      check(ac:fromGen3Encounter(GAME, { species = 16, level = 5 }, { mapId = row[1] }),
            "altering cave (" .. row[1] .. "): taken")
      eq(#asks, 1, "altering cave (" .. row[1] .. "): the held item is rolled once")
      eq(asks[1] and asks[1].opts and asks[1].opts.alteringCave, row[2],
         "altering cave (" .. row[1] .. "): the roll is told whether this is the cave")
      eq(ac.wildMon and ac.wildMon.item, 202, "altering cave (" .. row[1] .. "): the wild monster holds it")
      ac:reset()
    end
    FakeEncounters.rules = realRules

    -- The sleep counter rides with SLP (pret STATUS1 bits 0-2).
    local sleeper = monOf(16, 5)
    Sheet3.applyToMon(sleeper, { hp = 10, status = "SLP", sleepTurns = 4 })
    eq(sleeper.status, "SLP", "sleep: asleep")
    eq(sleeper.sleep, 4, "sleep: ...for the turns the referee left it")
    Sheet3.applyToMon(sleeper, { hp = 10, status = "SLP" })
    eq(sleeper.sleep, 4, "sleep: a sheet that says no count leaves the one it has")
    Sheet3.applyToMon(sleeper, { hp = 10, status = "SLP", sleepTurns = 9 })
    eq(sleeper.sleep, 7, "sleep: ...a count past the cart's three bits is clamped to 7")
    Sheet3.applyToMon(sleeper, { hp = 10, status = "PAR", sleepTurns = 3 })
    eq(sleeper.sleep, nil, "sleep: awake, no counter")
    local rebuilt = Sheet3.monFromSheet({ speciesNum = 16, level = 5, personality = 2, hp = 9,
      status = "SLP", sleepTurns = 2, moves = { { num = 33, pp = 30, maxPp = 35 } } }, SESSION)
    eq(rebuilt and rebuilt.sleep, 2, "sleep: a caught sheet rebuilt into a monster keeps its turns")

    -- Through a fight: a wild monster caught asleep keeps its counter -- the
    -- monster Cmd_givecaughtmon copies whole.
    newGame()
    SESSION.party = { monOf(4, 30) }
    FakeBag.add(SESSION.bag, 1, 1)
    local cs = newSolo()
    local caughtResult
    check(cs:fromGen3Encounter(GAME, { species = 16, level = 5 }, { done = function(r) caughtResult = r end }),
          "sleep catch: taken")
    local foeSeat = cs.sim.byId[FOE]
    foeSeat.mons[1].status, foeSeat.mons[1].sleepTurns = "SLP", 4
    local wildMon = cs.wildMon
    local thrown = false
    drive(cs, function(f)
      if not thrown then
        thrown = true
        f.itemPick = { id = 1, effect = Sheet3.itemEffect(1) }
        f:commitItem(nil, nil)
      else
        f:pickMove(1)
      end
    end)
    eq(caughtResult, "caught", "sleep catch: caught")
    eq(wildMon and wildMon.status, "SLP", "sleep catch: the monster caught is asleep")
    eq(wildMon and wildMon.sleep, 4, "sleep catch: ...for the turns it had left (STATUS1 kept)")
    eq(SESSION.party[2] and SESSION.party[2].sleep, 4, "sleep catch: ...in the party too")
  end

  -- ------- (l) W3-CORE: a seat with no battler owes its choice in the
  -- choice phase only (the old man's, the Safari player's)
  do
    newGame()
    SESSION.party = { monOf(4, 30) }
    local s = newSolo()
    local filed, asked = {}, 0
    local fighter = { playerId = "solo_player", side = "a", slot = 0, noBattler = true, mons = {} }
    local fakeSim = {
      order = { fighter }, phase = "choice", turn = 1, bySide = { a = { fighter }, b = {} },
      submitChoice = function(_, id, choice)
        filed[#filed + 1] = { id = id, choice = choice }
        fighter.choice = choice
        return true
      end,
      autoPick = function() return false end,
    }
    s.sim = fakeSim
    s.gen3 = { npcs = { solo_player = function() asked = asked + 1; return { action = "run" } end } }
    check(s:_answerNpcs3(), "noBattler: its owner is asked in the choice phase")
    eq(asked, 1, "noBattler: ...once")
    eq(filed[1] and filed[1].choice.action, "run", "noBattler: ...and its answer filed")
    s:_answerNpcs3()
    eq(asked, 1, "noBattler: a seat that has chosen owes nothing")
    fighter.choice, fakeSim.phase = nil, "replace"
    fighter.mustReplace = true
    s:_answerNpcs3()
    eq(asked, 1, "noBattler: ...nor anything in the replace phase, mustReplace or not")
    fighter.mustReplace, fakeSim.phase = nil, "choice"
    local plain = { playerId = "solo_player", side = "a", slot = 0, mons = {} }
    fakeSim.order, fakeSim.bySide.a = { plain }, { plain }
    s:_answerNpcs3()
    eq(asked, 1, "noBattler: a battler seat with no monster out still owes nothing")
    s.sim, s.gen3 = nil, nil
  end

  -- ------- (m) W3-CORE: the family modules, read through the install's
  -- reader (Client.install calls loadKinds3 at boot)
  do
    local reads, asked = {}, {}
    local bodies = {
      ["src/Solo3/Legend.lua"] = "return { kinds3 = { roamer = { takes = function() return true end } }",
      ["src/Solo3/Facility.lua"] = "error('facility exploded at start')",
      ["src/Solo3/Doubles.lua"] = "return { kinds3 = { pair = { takes = function() return true end } } }",
      ["src/Solo3/First.lua"] = "local need = ...; need('SoloBattle').registerKind3('firstBattle', {})",
    }
    local facade = {}
    for k, v in pairs(stubMod) do facade[k] = v end
    facade.read = function(_, path)
      reads[#reads + 1] = path
      return bodies[path]
    end
    local fresh
    local cache = {}
    local function freshNeed(n)
      asked[#asked + 1] = n
      if cache[n] ~= nil then return cache[n] end
      local body = bodies["src/" .. n .. ".lua"]
      if not body then
        local h = assert(io.open(MOD_PATH .. "/src/" .. n .. ".lua", "rb"))
        body = h:read("*a")
        h:close()
      end
      local chunk = assert(loadstr(body, "@" .. n .. ".lua"))
      local value = chunk(freshNeed, facade)
      cache[n] = value == nil and true or value
      return cache[n]
    end
    fresh = freshNeed("SoloBattle")
    local before = #warns
    local okL, names = pcall(fresh.loadKinds3)
    check(okL, "boot: reading every family never raises (" .. tostring(names) .. ")")
    local said = table.concat(warns, " / ", before + 1)
    for _, file in pairs(fresh.KIND_FILES3) do
      check(contains(reads, "src/" .. file .. ".lua"), "boot: every family file is looked for: " .. file)
    end
    eq(fresh.KINDS3.pair ~= nil, true, "boot: a family that loads registers its kinds")
    eq(fresh.KINDS3.firstBattle ~= nil, true, "boot: ...and one that registers itself, too")
    eq(fresh.KINDS3.roamer, nil, "boot: a family that does not parse registers nothing")
    check(said:find("src/Solo3/Legend.lua", 1, true) ~= nil and said:find("reinstall", 1, true) ~= nil,
          "boot: ...and is said, by its file, with what to do: " .. said)
    local legendAsked = false
    for _, n in ipairs(asked) do if n == "Solo3/Legend" then legendAsked = true end end
    eq(legendAsked, false, "boot: ...without ever being handed to the resolver")
    eq(fresh.KINDS3.facility, nil, "boot: a family that fails at start registers nothing")
    check(said:find("src/Solo3/Facility.lua", 1, true) ~= nil, "boot: ...and is said by its file")
    check(not said:find("Solo3/Tutorial", 1, true), "boot: a family whose file is not there is skipped quietly")
    local readsBefore = #reads
    eq(fresh.kind3("roamer"), nil, "boot: a family read at boot is not read again at its first fight")
    eq(#reads, readsBefore, "boot: ...no second read")
    for i = #warns, before + 1, -1 do table.remove(warns, i) end
  end

  Turn3.create, Mediated.new = realCreate, realNew
  FakeNatives.outcome_to_code = realCode
end

-- ===================================================================
-- the Battle Arena's judged monsters, as the core reads them (pret
-- battle_script_commands.c:3534 Cmd_checkteamslost skips arenaLost*Mons; the
-- referee's `judged`, BattleSim3/Arena.lua)
-- ===================================================================

do
  -- gen3Standing: a judged monster is down, whatever HP it kept -- marked on
  -- the monster, or named by its party position (a save party never carries
  -- the mark).
  local party = { { species = 4, hp = 0 }, { species = 5, hp = 30 } }
  eq(Solo.gen3Standing(party), true, "judged: a party with HP left stands")
  party[2].judged = true
  eq(Solo.gen3Standing(party), false, "judged: ...not when the monster with HP was judged")
  party[2].judged = nil
  eq(Solo.gen3Standing(party, { [1] = true }), false, "judged: ...nor when the referee names its position")
  eq(Solo.gen3Standing(party, { [0] = true }), true, "judged: ...a fainted one named changes nothing")
  local slots = Solo.judgedSlots3({ mons = { sheet(), sheet({ slot = 3, judged = true }) } })
  check(slots[3] and not slots[0], "judged: the referee's judged sheets, by party position")
  eq(next(Solo.judgedSlots3(nil)), nil, "judged: ...none for no fighter")

  -- refusalText3: in the Arena a switch is the party menu's
  -- PARTY_ACTION_CANT_SWITCH (battle_main.c:4241), its line
  -- gText_PkmnCantSwitchOut; anywhere else, a free switch has no line.
  local function arenaField(rules)
    local battle = assert(Sim.Turn.create({
      id = "arena", mode = "coop_npc", seed = 3, typeTable = CHART, rules = rules,
      sides = {
        a = { { playerId = "p", name = "P", mons = { sheet(), sheet({ slot = 1 }) } } },
        b = { { playerId = "n", name = "N", mons = { sheet() } } },
      },
    }))
    battle:drainEvents()
    return battle
  end
  local arena = arenaField({ arena = true })
  local line = Solo.refusalText3(arena, "p", { action = "switch", slot = 1 })
  check(type(line) == "string" and line:find("gText_PkmnCantSwitchOut", 1, true) ~= nil,
        "arena refusal: a switch is the party menu's 'can't be switched out'")
  eq(Solo.refusalText3(arenaField(nil), "p", { action = "switch", slot = 1 }), nil,
     "arena refusal: ...outside the Arena a free switch has no refusal line")

  -- The ending: a trainer fight whose last monster of the player's the
  -- judge took (its HP kept) is a loss nobody is left standing in -- the
  -- whiteout, not the halt of a fight the player "still stands" in.
  newGame()
  local lead = monOf(4, 20, { moves = { 10 }, pp = { 35 }, maxPp = { 35 } })
  SESSION.party = { lead }
  SESSION.money = 500
  local solo = newSolo()
  local op = trainerOpcode()
  FakeVm.running = true
  check(solo:fromGen3Trainer(GAME, 900, { trainerId = 900, done = op.done }), "judged ending: taken")
  local sim = solo.sim
  sim.byId["solo_player"].mons[1].judged = true
  sim:_finish("win", sim:_sidePlayers("b"), sim:_sidePlayers("a"), "ko", "judge", "b")
  local ok = drive(solo, function(f) f:pickMove(1) end)
  check(ok, "judged ending: the fight ended")
  eq(op.answered, "lose", "judged ending: the trainer's script is answered 'lose'")
  eq(FakeVm.halted, 0, "judged ending: ...not halted")
  eq(fieldCalls[1], "respawn", "judged ending: nobody of the player's can fight -- the whiteout")
  FakeVm.running = false
end

-- ===================================================================
-- the single screen's refusal lines: the cart checks each command as it is
-- chosen and keeps that menu up with its line -- a move's limitation in the
-- battle box, the move list behind it (pret battle_main.c
-- HandleTurnActionSelectionState, TrySetCantSelectMoveBattleScript); a
-- switch the party menu refuses inside the party menu (party_menu.c
-- PARTY_ACTION_CANT_SWITCH gText_PkmnCantSwitchOut, ABILITY_PREVENTS
-- gText_PkmnsXPreventsSwitching).  Worded by the solo transport
-- (`transport.refusal`, refusalText3), said by MediatedBattle `sendChoice`.
-- ===================================================================

do
  local MOVES3 = { moves = { 10, 45, 33 }, pp = { 35, 40, 35 }, maxPp = { 35, 40, 35 } }
  -- A wild fight up to its first command menu: a three-move lead, one benched.
  local function refusalFight(wild, lead, items)
    newGame()
    SESSION.party = { monOf(4, 30, lead or MOVES3), monOf(5, 30) }
    if items then SESSION.bag.pockets.ITEMS = items end
    local solo = newSolo()
    check(solo:fromGen3Encounter(GAME, wild or { species = 16, level = 3 }, {}), "refusal: taken")
    local f = solo.fight
    for _ = 1, 40 do f:update(2.0); solo:update(0.5, GAME); if f.phase == "choose" then break end end
    eq(f.phase, "choose", "refusal: the command menu is up")
    local b = solo.sim.byId["solo_player"].b
    -- Every choice that reaches the referee, counted.
    local reached = 0
    local choose = solo._choose
    solo._choose = function(...) reached = reached + 1; return choose(...) end
    return solo, f, b, function() return reached end
  end
  local function count(f, needle)
    local n = 0
    for _, line in ipairs(f.textLog or {}) do
      if tostring(line):find(needle, 1, true) then n = n + 1 end
    end
    return n
  end
  -- Read the box out (big steps: the queue only), the menu it came from back.
  local function readOut(f)
    for _ = 1, 20 do
      f:update(2.0)
      if f.shown == nil and #f.lines == 0 then break end
    end
  end
  local function pressA(f)
    local saved = GAME.input
    GAME.input = { pressed = {}, wasPressed = function(_, k) return k == "a" end,
                   isDown = function() return false end }
    f:update(0)
    GAME.input = saved
  end

  -- A move the referee will not take: its line once, in the box, the move
  -- list behind it, the turn not spent.
  local moveCases = {
    { "disabled", "STRINGID_PKMNMOVEISDISABLED", 1, function(b) b.disabledNum = 10 end },
    { "torment", "STRINGID_PKMNCANTUSEMOVETORMENT", 1,
      function(b) b.tormented = true; b.lastMoveNum = 10 end },
    { "taunt", "STRINGID_PKMNCANTUSEMOVETAUNT", 2, function(b) b.tauntTurns = 2 end },
    { "imprison", "STRINGID_PKMNCANTUSEMOVESEALED", 3, function(b, sim)
        local foe = sim:foes(b)[1]
        foe.imprison = true
        foe.moves[#foe.moves + 1] = { num = 33, pp = 35, maxPp = 35, power = 40 }
      end },
    -- (the fixture's item 127 held, made to carry HOLD_EFFECT_CHOICE_BAND, the referee's 29)
    { "choice band", "STRINGID_ITEMALLOWSONLYYMOVE", 1, function(b)
        b.mon.heldItem, b.mon.holdEffect, b.choicedMove = 127, 29, 45
      end },
  }
  for _, case in ipairs(moveCases) do
    local name, key, index, set = case[1], case[2], case[3], case[4]
    local tag = "refusal (" .. name .. "): "
    local solo, f, b, reached = refusalFight()
    set(b, solo.sim)
    local turn = solo.sim.turn
    f:runCommand("FIGHT")
    eq(f.phase, "move", tag .. "FIGHT opens the moves")
    eq(f:pickMove(index), false, tag .. "the pick is refused")
    eq(reached(), 1, tag .. "...by the referee (the screen has no gate for it)")
    eq(f.phase, "move", tag .. "the move list stays up")
    eq(f.answeredTurn, false, tag .. "...the turn not answered")
    eq(count(f, key), 1, tag .. "the cart's line, once")
    eq(f.transport.refusal, nil, tag .. "...taken off the transport as it is said")
    f:update(2.0)
    -- (a long key wraps in the box: compared with its breaks taken out)
    check(tostring(f.shown):gsub("%s", ""):find(key, 1, true) ~= nil, tag .. "...in the box over the list")
    readOut(f)
    eq(f.phase, "move", tag .. "the list again once it is read (stateIdAfterSelScript)")
    eq(count(f, key), 1, tag .. "...nothing said twice")
    eq(solo.sim.turn, turn, tag .. "the turn not spent")
    solo:reset()
  end

  -- No PP: the screen's own gate answers first (nothing reaches the referee),
  -- in the cart's words, once.
  do
    local tag = "refusal (no PP): "
    local solo, f, _, reached = refusalFight(nil,
      { moves = { 10, 45, 33 }, pp = { 0, 40, 35 }, maxPp = { 35, 40, 35 } })
    f:runCommand("FIGHT")
    eq(f:pickMove(1), false, tag .. "refused")
    eq(reached(), 0, tag .. "...by the screen: nothing reached the referee")
    eq(count(f, "STRINGID_NOPPLEFT"), 1, tag .. "STRINGID_NOPPLEFT, once")
    readOut(f)
    eq(f.phase, "move", tag .. "the list stays")
    solo:reset()
  end

  -- A medicine that would do nothing (a HYPER POTION on a full monster): the
  -- Gen 3 screen has no gate of its own for it (`itemNoEffect` is Red's and
  -- Gold's), so the referee refuses it and the line is the bag's
  -- gText_WontHaveEffect, said once inside the party menu, which stays up.
  do
    local tag = "refusal (no effect): "
    local solo, f, _, reached = refusalFight(nil, nil, { { id = 21, qty = 1 } })
    f:runCommand("ITEM")
    eq(f.phase, "item", tag .. "ITEM opens the bag")
    local at = nil
    for i, row in ipairs(f:usableItems()) do if tonumber(row.id) == 21 then at = i end end
    check(at ~= nil, tag .. "...with the HYPER POTION in it")
    f.itemIndex = at or 1
    pressA(f)
    for _ = 1, 30 do if f.phase == "item_party" then break end; f:update(1 / 60) end
    eq(f.phase, "item_party", tag .. "it asks for a monster")
    f.switchIndex = 1
    pressA(f)
    eq(reached(), 1, tag .. "the use goes to the referee")
    eq(count(f, "gText_WontHaveEffect"), 1, tag .. "the bag's gText_WontHaveEffect, once")
    eq(f.phase, "item_party", tag .. "...the party menu still up")
    f:update(2.0)
    check(tostring(f.shown):gsub("%s", ""):find("gText_WontHaveEffect", 1, true) ~= nil,
          tag .. "...its line printed over it")
    eq(f.pendingItem, nil, tag .. "nothing spent")
    solo:reset()
  end

  -- A trapped monster's switch: refused inside the party menu, which stays.
  local trapCases = {
    { "wrapped", function(b) b.trapTurns = 3 end },
    { "mean look", function(b, sim) b.trappedBy = sim:foes(b)[1] end },
    { "ingrain", function(b) b.ingrain = true end },
  }
  for _, case in ipairs(trapCases) do
    local tag = "refusal (" .. case[1] .. "): "
    local solo, f, b, reached = refusalFight()
    case[2](b, solo.sim)
    local turn = solo.sim.turn
    f:runCommand("SWITCH")
    eq(f.phase, "switch", tag .. "SWITCH opens the party menu")
    pressA(f)
    eq(reached(), 1, tag .. "SHIFT goes to the referee")
    eq(count(f, "gText_PkmnCantSwitchOut"), 1, tag .. "gText_PkmnCantSwitchOut, once")
    eq(f.phase, "switch", tag .. "...the party menu still up")
    f:update(2.0)
    check(tostring(f.shown):find("gText_PkmnCantSwitchOut", 1, true) ~= nil,
          tag .. "...its line printed over it")
    eq(solo.sim.turn, turn, tag .. "the turn not spent")
    solo:reset()
  end

  -- A foe's SHADOW TAG: the ability's own line, inside the party menu.
  do
    local tag = "refusal (shadow tag): "
    local solo, f, _, reached = refusalFight({ species = 16, level = 3, ability = 23 })
    f:runCommand("SWITCH")
    pressA(f)
    eq(reached(), 1, tag .. "SHIFT goes to the referee")
    eq(count(f, "gText_PkmnsXPreventsSwitching"), 1, tag .. "gText_PkmnsXPreventsSwitching, once")
    eq(count(f, "gText_PkmnCantSwitchOut"), 0, tag .. "...not the trapped line")
    eq(f.phase, "switch", tag .. "the party menu stays")
    solo:reset()
  end

  -- A choice the fight's kind turned down is the kind's to word: no line of
  -- the referee's beside it.
  do
    local tag = "refusal (kind): "
    local solo, f, b = refusalFight()
    b.disabledNum = 10
    solo.gen3.hooks3 = { choose = function() return true, false end }
    f:runCommand("FIGHT")
    eq(f:pickMove(1), false, tag .. "refused by the kind")
    eq(count(f, "STRINGID_PKMNMOVEISDISABLED"), 0, tag .. "...and the referee's line is not said")
    eq(f.transport.refusal, nil, tag .. "...nor left on the transport")
    solo.gen3.hooks3 = nil
    solo:reset()
  end

  -- The transport, by generation: a single Gen 3 screen is handed the line,
  -- the lone double too (kind-refused or not, as before), Red and Gold never.
  do
    local Wire = need("Wire")
    local function transportOf(gen3, kindRefuses)
      local s = setmetatable({ generation = gen3 and 3 or 1, gen3 = gen3 }, { __index = Solo })
      s._choose = function(self)
        self.kindRefused3 = kindRefuses or nil
        return false
      end
      s._refusal3 = function() return "THE LINE" end
      local t = s:_transport({})
      t.refusal = "STALE"
      eq(t:send(Wire.BATTLE_CHOICE, { action = "fight", move = 0 }), false, "transport: refused")
      return t.refusal
    end
    eq(transportOf({}), "THE LINE", "transport: a single Gen 3 screen is handed the refusal line")
    eq(transportOf({}, true), nil, "transport: ...not when the kind refused it itself")
    eq(transportOf({ double = true }), "THE LINE", "transport: the lone double as before")
    eq(transportOf({ double = true }, true), "THE LINE", "transport: ...kind-refused too, as before")
    eq(transportOf(nil), nil, "transport: Red and Gold read no line (and a stale one is cleared)")
  end
end

-- Nothing of Gen 1's engine was reached on a Gen 3 boot.
check(package.loaded["src.battle.BattleState"] == nil, "no Gen 1 BattleState on a Gen 3 boot")
check(package.loaded["src.battle.TrainerAI"] == nil, "no Gen 1 TrainerAI on a Gen 3 boot")
check(not contains(warns, "ERROR"), "no error was logged: " .. table.concat(warns, " / "))
check(not contains(warns, "could not"), "no fallback warning fired: " .. table.concat(warns, " / "))

unstubAll()
T.finish("gen3_solo")
