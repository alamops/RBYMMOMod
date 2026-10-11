-- The headless rig the K-DBL suites share (tests/gen3_solo_pairs.lua,
-- tests/gen3_solo_first.lua): the fights of src/Solo3/Doubles.lua and
-- src/Solo3/First.lua taken through the real src/SoloBattle.lua core, the
-- real BattleSim3 referee, the real screens (MediatedBattle's single,
-- CoopBattle's solo double) and the real src/CoopField.lua stand-ins.
--
-- The shape tests/gen3_solo.lua and tests/gen3_solo_double.lua set: a Gen 3
-- boot (the stub facade says generation 3) over the engine SDK's own Gen 3
-- fixture (T.sdk.gen3Data, synthetic numbers), the engine modules that would
-- need an imported cache stood in by small fakes that record what they were
-- asked, and the engine's own *pure* modules run for real (the exp curve, the
-- game3 modal stack, the prize formula -- FireRed's and Emerald's).  The
-- facade can read the mod's files (`mod:read`), so a kind is found the way a
-- player's install finds it: SoloBattle.KIND_FILES3 names the module and the
-- core loads it at the first fight that asks.
--
-- Usage (from a suite in tests/):
--
--   local here = debug.getinfo(1, "S").source:sub(2):match("(.+)[/\\]") or "."
--   local R = dofile(here .. "/fixtures/gen3_solo_dbl_rig.lua")(T)
--
-- Kept under tests/fixtures/ (not tests/) so the engine's tier runner, which
-- runs every file directly under a mod's tests/, does not take it for a suite.
--
-- Legal: every species, move, trainer and item row is the SDK fixture's or
-- invented here with synthetic numbers; the only real values are pret enum
-- numbers the battle code branches on (TYPE_*, EFFECT_*, ABILITY_*,
-- HOLD_EFFECT_*, ITEM_* ids, AI_SCRIPT_* bit positions), the policy
-- docs/plans/gen3-battle-sheet.md states for the sim itself.

return function(T)
  local R = {}
  local check = T.check

  local MOD_PATH = "mods/rby_mmo"
  do
    local src = debug.getinfo(1, "S").source
    if type(src) == "string" and src:sub(1, 1) == "@" then
      local dir = src:sub(2):match("(.+)[/\\]")
      if dir then
        local root = dir:gsub("[/\\]tests[/\\]fixtures$", "")
        local h = io.open(root .. "/src/SoloBattle.lua", "rb")
        if h then
          h:close()
          MOD_PATH = root
        end
      end
    end
  end
  R.MOD_PATH = MOD_PATH

  -- ------------------------------------------------------------------
  -- the facade and the module graph
  -- ------------------------------------------------------------------

  local warns = {}
  R.warns = warns
  local OPTIONS = { solo = true }
  R.OPTIONS = OPTIONS
  local reads = {}
  R.reads = reads
  local function readFile(path)
    local h = io.open(MOD_PATH .. "/" .. path, "rb")
    if not h then return nil end
    local body = h:read("*a")
    h:close()
    return body
  end
  local stubMod = {
    id = "rby_mmo",
    path = MOD_PATH,
    generation = 3,
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
    save = { get = function() return nil end, set = function() end },
    events = { emit = function() end },
    -- The install's own reader (the loader's mod:read): the kind registry
    -- finds src/Solo3/*.lua through it.
    read = function(_, path)
      reads[#reads + 1] = path
      return readFile(path)
    end,
  }
  stubMod.find = function() return { exports = stubMod.exports } end
  R.stubMod = stubMod

  local loadstr = loadstring or load
  local cache = {}
  local function need(n)
    if cache[n] ~= nil then return cache[n] end
    local body = readFile("src/" .. n .. ".lua")
    assert(body, "no src/" .. n .. ".lua under " .. MOD_PATH)
    local chunk = assert(loadstr(body, "@" .. n .. ".lua"))
    local value = chunk(need, stubMod)
    cache[n] = value == nil and true or value
    return cache[n]
  end
  R.need = need

  local function stub(name, value) package.loaded[name] = value end

  -- ------------------------------------------------------------------
  -- the fixture, extended
  -- ------------------------------------------------------------------

  local DATA = T.sdk.gen3Data()
  local P3 = DATA.gen3Pokemon
  local ROM = DATA.gen3Moves._rom
  local ITEMS = DATA.gen3Items._byId
  R.DATA, R.P3, R.ROM, R.ITEMS = DATA, P3, ROM, ITEMS

  -- GROWL (EFFECT_ATTACK_DOWN, 18): a move that never knocks anything out.
  ROM[45] = { effect = 18, power = 0, type = 0, accuracy = 100, pp = 40,
              secondaryChance = 0, target = 0, priority = 0, flags = 18 }
  P3._moveNames[45] = "GROWL"
  -- An invented sure-hit psychic move strong enough to end a fight in a turn.
  ROM[300] = { effect = 0, power = 250, type = 14, accuracy = 100, pp = 30,
               secondaryChance = 0, target = 0, priority = 0, flags = 2 }
  P3._moveNames[300] = "MINDBLAST"
  ROM[33].flags = 3
  -- A synthetic ZIGZAGOON (an invented species id and invented values): ORAN
  -- BERRY (pret ITEM_ORAN_BERRY) common, nothing rare.
  P3._names[263] = "ZIGZAGOON"
  P3._types[263] = { 0, 0 }
  P3._stats[263] = P3._stats[16]
  P3._speciesMeta[263] = { catchRate = 255, expYield = 56, growthRate = 0,
                           itemCommon = 139, itemRare = 0, genderRatio = 127 }
  P3._abilities[263] = { 53, 0 }
  P3._learnsets[263] = { { 1, 33 }, { 1, 45 } }
  P3._abilityNames[53] = "PICKUP"
  P3._abilityNames[71] = "ARENA TRAP"
  P3._abilityNames[50] = "RUN AWAY"
  ITEMS[1] = { name = "MASTER BALL", pocket = "POKE_BALLS", price = 0 }
  ITEMS[21] = { name = "HYPER POTION", pocket = "ITEMS", price = 1200 }
  ITEMS[139] = { name = "ORAN BERRY", pocket = "BERRY_POUCH", price = 20,
                 holdEffect = 1, holdEffectParam = 10 }
  -- pret ITEM_SMOKE_BALL (194), HOLD_EFFECT_CAN_ALWAYS_RUN (37).
  ITEMS[194] = { name = "SMOKE BALL", pocket = "ITEMS", price = 200, holdEffect = 37 }

  -- ------------------------------------------------------------------
  -- the stand-in engine modules
  -- ------------------------------------------------------------------

  local SESSION
  R.session = function() return SESSION end

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
  function FakeBag.has(bag, id, qty) return FakeBag.get(bag, id) >= (qty or 1) end
  function FakeBag.listPocket(bag, pocket)
    local rows = {}
    for _, slot in ipairs(bag.pockets[pocket] or {}) do
      rows[#rows + 1] = { id = slot.id, qty = slot.qty, name = (ITEMS[tonumber(slot.id)] or {}).name }
    end
    return rows
  end
  R.FakeBag = FakeBag

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
  function FakePokemon.types(sp) return P3._types[tonumber(sp)] end
  function FakePokemon.speciesOf(mon) return tonumber(mon and (mon.species or mon.speciesId)) end
  function FakePokemon.speciesFromName(name)
    for id, n in pairs(P3._names) do if n == name then return id end end
    return nil
  end
  function FakePokemon.abilities(sp) return P3._abilities[tonumber(sp)] or { 0, 0 } end
  function FakePokemon.abilityId(sp, personality)
    local pair = FakePokemon.abilities(sp)
    if pair[2] ~= 0 and (tonumber(personality) or 0) % 2 == 1 then return pair[2] end
    return pair[1]
  end
  function FakePokemon.natureId(personality) return (tonumber(personality) or 0) % 25 end
  function FakePokemon.gender() return "M" end
  function FakePokemon.isEgg(mon) return type(mon) == "table" and mon.isEgg == true end
  function FakePokemon.movePp(id) local row = ROM[tonumber(id)] return row and row.pp or 5 end
  function FakePokemon.movesAtLevel(sp, level)
    local moves = {}
    for _, row in ipairs(P3._learnsets[tonumber(sp)] or {}) do
      if row[1] <= level then
        moves[#moves + 1] = row[2]
        if #moves > 4 then table.remove(moves, 1) end
      end
    end
    local pp, maxPp = {}, {}
    for i, m in ipairs(moves) do pp[i] = FakePokemon.movePp(m); maxPp[i] = FakePokemon.movePp(m) end
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
  function FakePokemon.frontPic(sp) return { image = fakeImage("front" .. tostring(sp)), w = 64, h = 64 } end
  function FakePokemon.backPic(sp) return { image = fakeImage("back" .. tostring(sp)), w = 64, h = 64 } end
  function FakePokemon.monFrontPic(mon) return FakePokemon.frontPic(mon.species) end
  function FakePokemon.monBackPic(mon) return FakePokemon.backPic(mon.species) end
  function FakePokemon.icon(sp)
    return { image = fakeImage("icon" .. tostring(sp)), w = 32, h = 32, frames = 2, quads = {} }
  end
  function FakePokemon.monIcon(mon) return FakePokemon.icon(mon.species) end
  function FakePokemon.isShiny() return false end
  R.FakePokemon = FakePokemon

  local FakeDex = { seen = {} }
  function FakeDex.isCaught(dex, sp) return dex.caught[tonumber(sp)] == true end
  function FakeDex.registerCapture(dex, sp)
    local was = dex.caught[sp] == true
    dex.seen[sp], dex.caught[sp] = true, true
    return was
  end
  function FakeDex.handleSetPokedexFlag(dex, sp, caught, personality)
    dex.seen[sp] = true
    FakeDex.seen[#FakeDex.seen + 1] = { species = sp, caught = caught, personality = personality }
    if caught then dex.caught[sp] = true end
  end
  R.FakeDex = FakeDex

  local FakeLearn = {}
  function FakeLearn.begin(opts) if opts.onDone then opts.onDone(false) end end

  local audioCalls = {}
  R.audioCalls = audioCalls
  local FakeAudio = {}
  for _, name in ipairs({ "playSong", "playSe", "playCry", "restoreMapSong", "playFanfare",
                          "clearSavedSong" }) do
    FakeAudio[name] = function(...)
      audioCalls[#audioCalls + 1] = { name, ... }
      return true
    end
  end
  function FakeAudio.role() return nil end

  -- Deterministic engine RNG.
  local rngState = 12345
  local FakeRng = {}
  function FakeRng.Random()
    rngState = (rngState * 1103515245 + 12345) % 2147483648
    return math.floor(rngState / 65536) % 65536
  end
  function FakeRng.Random32() return FakeRng.Random() * 65536 + FakeRng.Random() end
  R.FakeRng = FakeRng

  local FakeDamage = {}
  function FakeDamage.ensureStats(mon, level)
    mon.level = level or mon.level
    FakePokemon.applyStats(mon)
    if not mon.ability then
      mon.ability = FakePokemon.abilityId(mon.species, mon.personality)
      mon.abilityId = mon.ability
    end
    return mon
  end

  -- The trainer book: invented rows.  Classes and the money table are
  -- synthetic; the engine's real Prize module reads them (Prize.rewardRse /
  -- calcRse over Trainers.pack().money, Prize.calc over its own class table).
  local TRAINERS = {}
  R.TRAINERS = TRAINERS
  local MONEY = { [57] = 4, [59] = 6, [81] = 4, [50] = 9, [51] = 7 }
  R.MONEY = MONEY
  local RIVAL_CLASSES = { [81] = true }
  local FakeTrainers = {}
  local function trainerView(id)
    local t = TRAINERS[tonumber(id)]
    if not t then return nil end
    local out = { id = tonumber(id), dialogs = { defeat = t.defeat or "I lost!",
                                                victory = t.victory } }
    for k, v in pairs(t) do out[k] = v end
    out.partySize = #(t.party or {})
    out.lastLevel = t.lastLevel or ((t.party and t.party[#t.party]) or {}).level
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
    for i = 1, #(t.party or {}) do out[i] = 0x80 + i * 256 end
    return out
  end
  function FakeTrainers.pack() return { money = MONEY, moneyDefault = 5 } end
  function FakeTrainers.getBattleMusicRole() return "battleTrainer", 297 end
  function FakeTrainers.getVictoryMusicRole() return "victoryTrainer", 310 end
  function FakeTrainers.getEncounterMusic() return nil end
  function FakeTrainers.foeFromId(id)
    local t = TRAINERS[tonumber(id)]
    if not (t and t.party and #t.party > 0) then return nil end
    local party = {}
    for _, m in ipairs(t.party) do
      local iv = m.iv or 0
      party[#party + 1] = { species = m.species, level = m.level, iv = iv,
        ivs = { hp = iv, atk = iv, def = iv, spa = iv, spd = iv, spe = iv },
        evs = { hp = 0, atk = 0, def = 0, spa = 0, spd = 0, spe = 0 },
        heldItem = m.heldItem, moves = m.moves, trainerId = tonumber(id) }
    end
    return { species = party[1].species, level = party[1].level, trainerId = tonumber(id),
             aiFlags = t.aiFlags, items = t.items, party = party, trainerName = t.name,
             trainerClass = t.class, trainerClassName = t.className, trainerPic = t.pic,
             gender = t.gender, doubleBattle = t.doubleBattle }
  end
  R.FakeTrainers = FakeTrainers

  -- The cart's battle text, stood in: `TEXT[id]` (a string or a function of
  -- the fill) wins; else, unless `R.textless`, the id with the fill's buffer
  -- and first trainer, so a line can be told apart.
  local TEXT = {}
  R.TEXT = TEXT
  local FakeBattleText = {}
  function FakeBattleText.get(id, fill)
    fill = fill or {}
    local own = TEXT[id]
    if type(own) == "function" then return own(fill) end
    if own ~= nil then return own end
    if R.textless then return nil end
    return id .. "|" .. tostring(fill.buff1 or "") .. "|" .. tostring(fill.trainer1Name or "")
  end

  -- Both carts' battle profiles, as far as these suites read them.
  local FRLG_BITS = { CHECK_BAD_MOVE = 0, CHECK_VIABILITY = 1, TRY_TO_FAINT = 2,
                      SETUP_FIRST_TURN = 3, RISKY = 4, PREFER_STRONGEST_MOVE = 5,
                      PREFER_BATON_PASS = 6, DOUBLE_BATTLE = 7, HP_AWARE = 8 }
  local EM_BITS = { CHECK_BAD_MOVE = 0, TRY_TO_FAINT = 1, CHECK_VIABILITY = 2, SETUP_FIRST_TURN = 3,
                    RISKY = 4, PREFER_POWER_EXTREMES = 5, PREFER_BATON_PASS = 6, DOUBLE_BATTLE = 7,
                    HP_AWARE = 8, TRY_SUNNY_DAY_START = 9, ROAMING = 29, SAFARI = 30,
                    FIRST_BATTLE = 31 }
  R.EM_BITS, R.FRLG_BITS = EM_BITS, FRLG_BITS
  local PROFILES = {
    frlg = {
      family = "frlg", aiVariant = "frlg", aiFlagBits = FRLG_BITS,
      kinds = { firstBattle = "oak", tutorial = "oldman", ghost = true, pokedude = true },
      rules = { money = "frlg", lostText = "frlg", pickup = "flat", amuletCoinPlayerOnly = false,
                critExclusions = {} },
    },
    rse = {
      family = "rse", aiVariant = "rse", aiFlagBits = EM_BITS,
      kinds = { firstBattle = "birch", tutorial = "wally", ghost = false, pokedude = false,
                twoOpponents = true },
      firstBattle = { species = "SPECIES_ZIGZAGOON", level = 2, cantRun = "STRINGID_DONTLEAVEBIRCH" },
      rules = { money = "rse", lostText = "rse", pickup = "flat", amuletCoinPlayerOnly = true,
                teleportOutcome = "side", critExclusions = { firstBattle = true } },
    },
  }
  R.PROFILES = PROFILES
  local FakeProfile = {}
  function FakeProfile.get(session)
    session = session or SESSION
    local rse = session and session.version == "emerald"
    return rse and PROFILES.rse or PROFILES.frlg
  end
  function FakeProfile.of() return FakeProfile.get(SESSION) end

  local bridgeCalls = {}
  R.bridgeCalls = function() return bridgeCalls end
  local FakeBridge = {}
  function FakeBridge.calcMoneyLossFrlg() return 120 end
  function FakeBridge.applyWhiteoutMoneyLoss(session)
    bridgeCalls[#bridgeCalls + 1] = { "loss" }
    local before = session.money
    session.money = math.max(0, before - 120)
    return before - session.money, session.money
  end
  function FakeBridge.applyLeagueFriendship() end
  function FakeBridge.start(_, _, foe, opts)
    bridgeCalls[#bridgeCalls + 1] = { "start", foe, opts }
    return true
  end
  function FakeBridge.startWild(_, _, foe, opts)
    bridgeCalls[#bridgeCalls + 1] = { "startWild", foe, opts }
    return true
  end

  local fieldCalls = {}
  R.fieldCalls = function() return fieldCalls end
  local FakeField = {}
  function FakeField.respawnAtHeal()
    fieldCalls[#fieldCalls + 1] = "respawn"
    for _, mon in ipairs(SESSION.party) do mon.hp = mon.maxHp; mon.status = nil end
  end
  local healCalls = 0
  R.healCalls = function() return healCalls end
  local FakeParty = { PLAYER_HAS_TWO_USABLE_MONS = 1 }
  function FakeParty.healAll(party)
    healCalls = healCalls + 1
    for _, mon in ipairs(party or {}) do mon.hp = mon.maxHp; mon.status = nil end
  end

  -- The engine's whole outcome vocabulary (scripting/natives.lua:198).
  local CODES = {
    win = 1, won = 1, lose = 2, lost = 2, whiteout = 2, draw = 3, run = 4,
    teleport_player = 5, player_teleported = 5, fled = 6, mon_fled = 6,
    caught = 7, catch = 7, no_safari_balls = 8, forfeited = 9, mon_teleported = 10,
  }
  R.CODES = CODES
  local FakeNatives = { outcome_to_code = function(r) return CODES[r] or 1 end }

  local spaceCalls = 0
  R.spaceCalls = function() return spaceCalls end
  local FakeVm = { running = false, halted = 0 }
  function FakeVm:isRunning() return self.running end
  function FakeVm:halt(aborted)
    self.halted = self.halted + 1
    self.running = false
    self.aborted = aborted
  end
  R.FakeVm = FakeVm
  -- The live flag store (Space.store): `badges` is what Flags.hasBadge reads.
  local STORE = { flags = {} }
  R.STORE = STORE
  local FakeSpace = { store = STORE, vm = FakeVm }
  function FakeSpace.getStore() return STORE end
  function FakeSpace.returnToField() spaceCalls = spaceCalls + 1 end

  -- The encounter rules' held-item roll (Emerald's encounter_rules/rse.lua
  -- wildHeldItem), recording each ask.  `heldQueue` answers in order; empty,
  -- nothing is held.
  local heldAsks = {}
  R.heldAsks = heldAsks
  R.heldQueue = {}
  local FakeEncounters = {
    resetRateModifiers = function() end,
    rules = function()
      return { wildHeldItem = function(species, opts)
        heldAsks[#heldAsks + 1] = { species = species, opts = opts }
        FakeRng.Random()
        local nextItem = table.remove(R.heldQueue, 1)
        return nextItem
      end }
    end,
  }

  -- What the ending does beyond the rewards (SoloBattle M:_finishEffects3).
  local effectsLog = {}
  R.effectsLog = function() return effectsLog end
  function FakePokemon.randomlyGivePartyPokerus(party, s) effectsLog[#effectsLog + 1] = { "pokerus.give", party, s } end
  function FakePokemon.partySpreadPokerus(party, s) effectsLog[#effectsLog + 1] = { "pokerus.spread", party, s } end
  local FakeFieldModules = { enabled = function(name) return name == "questLog" end }
  local FakeQuestLog = { battle = function(s, st) effectsLog[#effectsLog + 1] = { "questlog", s, st } end }
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
  local FakeWeather = { id = 0 }
  function FakeWeather.get() return FakeWeather.id end
  R.FakeWeather = FakeWeather
  local FakeFlags = {}
  function FakeFlags.hasBadge(store, n) return type(store.badges) == "table" and store.badges[n] == true end
  function FakeFlags.trainerFlagId(id) return 0x500 + tonumber(id) end
  function FakeFlags.setFlag(store, _, id, on) store.flags[id] = on end
  function FakeFlags.getFlag(store, _, id) return store.flags[id] end

  -- PROF. OAK's advice (battle/oak_advice.lua), one page per lesson key.
  local FakeOak = {}
  function FakeOak.pages(_, key) return { "OAK: " .. tostring(key) } end
  function FakeOak.screens(pages) return pages end

  -- Emerald's two facilities a pair may be met inside (rse/frontier/pyramid.lua
  -- Pyramid.inPyramid, rse/trainer_hill.lua Hill.inChallenge), read off the
  -- session here.
  local FakePyramid = { inPyramid = function(s) return type(s) == "table" and s.inPyramid == true end }
  local FakeHill = { inChallenge = function(s) return type(s) == "table" and s.inHill == true end }

  local FakeProtocol = {}
  function FakeProtocol.packMon3(mon) return { species = tonumber(mon.species), level = mon.level } end
  function FakeProtocol.unpackMon3() return nil, "unused" end

  stub("src.core.game3.runtime", { getSession = function() return SESSION end, _mod = "ENGINE_MOD" })
  stub("src.core.game3.pokemon", FakePokemon)
  stub("src.core.game3.bag", FakeBag)
  stub("src.core.game3.dex", FakeDex)
  stub("src.core.game3.evolution", { levelTarget = function() return nil end })
  stub("src.ui.game3.evolution_scene", { start = function() return false end })
  stub("src.core.game3.storage", { sendMonToPC = function(session, mon)
    session.pc = session.pc or {}
    session.pc[#session.pc + 1] = mon
    return true
  end, pcTransferMessage = function(_, name) return tostring(name) .. " was sent to the PC." end })
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
  stub("src.core.game3.battle.damage", FakeDamage)
  stub("src.core.game3.scripting.trainers", FakeTrainers)
  stub("src.core.game3.battle.battle_text", FakeBattleText)
  stub("src.core.game3.battle.profile", FakeProfile)
  stub("src.core.game3.battle_bridge", FakeBridge)
  stub("src.core.game3.field", FakeField)
  stub("src.core.game3.party", FakeParty)
  stub("src.core.game3.scripting.natives", FakeNatives)
  stub("src.core.game3.scripting.space", FakeSpace)
  stub("src.core.game3.scripting.flags", FakeFlags)
  stub("src.core.game3.encounters", FakeEncounters)
  stub("src.core.game3.field_modules", FakeFieldModules)
  stub("src.core.game3.quest_log_recorder", FakeQuestLog)
  stub("src.core.game3.rse.init", FakeRse)
  stub("src.mods.Runtime", FakeRuntime)
  stub("src.core.game3.weather", FakeWeather)
  stub("src.core.game3.battle.oak_advice", FakeOak)
  stub("src.core.game3.rse.frontier.pyramid", FakePyramid)
  stub("src.core.game3.rse.trainer_hill", FakeHill)
  stub("src.link.Protocol", FakeProtocol)
  stub("src.core.game3.safari", { isActive = function() return false end })
  stub("src.core.game3.capabilities", { gate = function() return false end })
  stub("src.core.game3.objects", { _byId = {}, _order = {} })
  stub("src.core.game3.trainer_sight", { getTrainerId = function(eo) return eo and tonumber(eo.trainerId) end })
  stub("src.core.game3.vs_seeker", { rematchTrainerId = function() return 0 end })

  -- The real pure engine modules, after the stand-ins they close over.
  local Experience = require("src.core.game3.battle.experience")
  local Prize = require("src.core.game3.battle.prize")
  local Stack = require("src.ui.game3.stack")
  check(type(Prize.rewardRse) == "function", "rig: the engine's Gen 3 prize formula loads headless")
  R.Experience, R.Prize, R.Stack = Experience, Prize, Stack

  local Gen3 = need("Gen3")
  local Gen3Ui = need("Gen3Ui")
  local Sheet3 = need("Sheet3")
  local Mediated = need("MediatedBattle")
  local CoopBattle = need("CoopBattle")
  local CoopField = need("CoopField")
  local Solo = need("SoloBattle")
  local Brain = need("SoloBrain")
  local Turn = need("BattleSim3/Turn")
  R.Gen3, R.Gen3Ui, R.Sheet3, R.Mediated = Gen3, Gen3Ui, Sheet3, Mediated
  R.CoopBattle, R.CoopField, R.Solo, R.Brain, R.Turn = CoopBattle, CoopField, Solo, Brain, Turn

  -- Every line either screen says, in order (a fight's own `textLog`).
  for _, Screen in ipairs({ Mediated, CoopBattle }) do
    local say = Screen.say
    Screen.say = function(self, text)
      self.textLog = self.textLog or {}
      self.textLog[#self.textLog + 1] = tostring(text)
      return say(self, text)
    end
  end

  -- What the referee was created with, and every screen's options.
  R.created, R.screened = {}, {}
  do
    local realCreate, realNew, realDouble = Turn.create, Mediated.new, CoopBattle.newSoloDouble
    Turn.create = function(o)
      if R.onCreate then R.onCreate(o) end
      R.created[#R.created + 1] = o
      return realCreate(o)
    end
    Mediated.new = function(o)
      R.screened[#R.screened + 1] = o
      return realNew(o)
    end
    CoopBattle.newSoloDouble = function(game, o)
      R.screened[#R.screened + 1] = o
      return realDouble(game, o)
    end
  end
  function R.lastCreate() return R.created[#R.created] end
  function R.lastScreen() return R.screened[#R.screened] end

  -- ------------------------------------------------------------------
  -- the game, the party, the solo fight
  -- ------------------------------------------------------------------

  local function fakeInput(key)
    return { pressed = {}, wasPressed = function(_, k) return key ~= nil and k == key end,
             isDown = function() return false end }
  end
  R.fakeInput = fakeInput

  local GAME
  R.game = function() return GAME end
  -- cart: "firered" | "emerald"
  function R.newGame(cart, extra)
    SESSION = {
      engine = "game3", generation = 3,
      name = "ANN", trainerId = 111, secretId = 222, gender = 0, version = cart or "firered",
      party = {}, dex = { seen = {}, caught = {}, owned = {} },
      bag = { pockets = { ITEMS = {}, KEY_ITEMS = {}, POKE_BALLS = {}, TM_CASE = {},
                          BERRY_POUCH = {} } },
      money = 1000,
    }
    for k, v in pairs(extra or {}) do SESSION[k] = v end
    GAME = { generation = 3, phase = "field", data = DATA, session = SESSION,
             save = { engine = "game3", generation = 3, money = SESSION.money },
             input = fakeInput() }
    stubMod.game = GAME
    Stack.clear()
    FakeDex.seen = {}
    bridgeCalls, fieldCalls, effectsLog = {}, {}, {}
    healCalls, spaceCalls = 0, 0
    for i = #audioCalls, 1, -1 do audioCalls[i] = nil end
    for i = #heldAsks, 1, -1 do heldAsks[i] = nil end
    R.heldQueue = {}
    R.created, R.screened = {}, {}
    R.onCreate = nil
    R.textless = false
    for k in pairs(TEXT) do TEXT[k] = nil end
    FakeWeather.id = 0
    FakeVm.running, FakeVm.halted, FakeVm.aborted = false, 0, nil
    STORE.flags, STORE.badges = {}, nil
    CoopField.resetDeferred3()
    return GAME
  end

  -- A party mon the way party.lua's giveMon leaves one; `moves` sets its PP.
  function R.mon(species, level, extra)
    extra = extra or {}
    local growth = P3._speciesMeta[species].growthRate
    local m = {
      species = species, speciesId = species, level = level, nickname = "",
      growthRate = growth, exp = Experience.expForLevel(growth, level),
      moves = { 10, 45 }, pp = { 35, 40 }, maxPp = { 35, 40 },
      personality = 8, nature = 8,
      ivs = { hp = 31, atk = 31, def = 31, spe = 31, spa = 31, spd = 31 },
      evs = { hp = 0, atk = 0, def = 0, spe = 0, spa = 0, spd = 0 },
      ability = P3._abilities[species][1], gender = "M", friendship = 70,
      heldItem = 0, item = 0, otId = 111, otName = "ANN",
    }
    for k, v in pairs(extra) do m[k] = v end
    if extra.moves and not extra.pp then
      m.pp, m.maxPp = {}, {}
      for i, id in ipairs(extra.moves) do m.pp[i], m.maxPp[i] = FakePokemon.movePp(id), FakePokemon.movePp(id) end
    end
    local hp = extra.hp
    m.hp = nil
    FakePokemon.applyStats(m)
    if hp then m.hp = hp end
    return m
  end

  local UI = {
    pushState = function(_, game, state) return Gen3Ui.pushState(game, state) end,
    say = function(_, _, cb) if cb then cb() end; return {} end,
    confirm = function(_, _, _, cb) if cb then cb(true) end; return {} end,
    askNickname = function() return true end,
  }
  R.UI = UI

  function R.newSolo(seed)
    return Solo.new(UI, {
      enabled = function() return OPTIONS.solo == true end,
      seed = function() return seed or 7 end,
    })
  end

  -- What src/Client.lua's offerFight3 hands solo for a stand-in: its monsters,
  -- the stand-in itself, `fallback` (the stand-in's fightAlone), `done`.
  function R.standOpts(stand, done)
    local opts = {}
    for k, v in pairs(stand.opts or {}) do opts[k] = v end
    opts.done = done
    opts.fallback = function() stand:fightAlone() end
    opts.party = stand.enemyParty
    opts.stand3 = stand
    return opts
  end

  -- ------------------------------------------------------------------
  -- driving a fight
  -- ------------------------------------------------------------------

  -- A single (MediatedBattle): the referee once a frame, the screen once a
  -- frame, `onChoose(fight)` at each command menu, until the ending has
  -- printed; then leave it.
  function R.drive(solo, onChoose, maxSteps)
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

  -- Pump a single until its command menu is up (nothing pressed).
  function R.untilChoose(solo, maxSteps)
    for _ = 1, maxSteps or 200 do
      solo:update(0.5, GAME)
      local fight = solo.fight
      if not fight then return false end
      fight:update(2.0)
      if fight.phase == "choose" and #fight.lines == 0 and not fight.shown then return true end
    end
    return false
  end

  -- A double (CoopBattle's solo double): one frame the way the game runs one
  -- -- the pump, then the screen, A on any open menu or picker (aiming at a
  -- foe, never the partner).
  function R.doubleFrame(solo, press)
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

  function R.playDouble(solo, limit)
    local frames, last = 0, solo.fight
    for _ = 1, limit or 6000 do
      if not solo.fight then break end
      last = solo.fight
      frames = frames + 1
      if not R.doubleFrame(solo, true) then break end
    end
    return frames, last
  end

  -- ------------------------------------------------------------------
  -- small helpers
  -- ------------------------------------------------------------------

  function R.contains(list, needle)
    for _, line in ipairs(list or {}) do
      if type(line) == "string" and line:find(needle, 1, true) then return true end
    end
    return false
  end
  function R.indexIn(list, needle, from)
    for i = from or 1, #(list or {}) do
      local line = list[i]
      if type(line) == "string" and line:find(needle, 1, true) then return i end
    end
    return nil
  end
  function R.countIn(list, needle)
    local n = 0
    for _, line in ipairs(list or {}) do
      if type(line) == "string" and line:find(needle, 1, true) then n = n + 1 end
    end
    return n
  end
  function R.dropWarnsSince(mark)
    for i = #warns, mark + 1, -1 do warns[i] = nil end
  end
  function R.audioNames()
    local out = {}
    for _, c in ipairs(audioCalls) do out[#out + 1] = c[1] end
    return out
  end
  function R.effectsOf(kind)
    local out = {}
    for _, e in ipairs(effectsLog) do if e[1] == kind then out[#out + 1] = e end end
    return out
  end
  -- One block of checks: an error raised inside it is a failure of its own.
  function R.block(name, fn)
    local ok, err = pcall(fn)
    if not ok then check(false, name .. ": the block raised -- " .. tostring(err)) end
  end

  return R
end
