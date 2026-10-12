-- Headless Gen 3 doors (docs/plans/gen3-solo-remaining-fights.md C1): which
-- fights the mod's three Gen 3 doors build a stand-in for, what kind each one
-- is, who is offered it, and what each kind carries to the taker.
--
--   1. the two refusal lists (src/Config.lua): co-op's is the old list, word
--      for word; solo's is the link family and the e-Reader;
--   2. classification (CoopField.classify3): every kind the engine spells a
--      fight with, read where it spells it -- the start opts, the foe, the
--      encounter, the session (the Safari Zone) and the map (the POKeMON
--      TOWER);
--   3. who is offered it: with only co-op listening every kind co-op does
--      not fight is refused before a monster is rolled; with SOLO BATTLES on
--      the stand-in is built and carries why co-op may not have it; what stays
--      on the cart is refused for both;
--   4. each kind's stand-in: a roamer as its save describes it, a legend with
--      no held-item roll, the unveiled Marowak as the native fixed it, a
--      facility trainer built from its own record and monsters (no gTrainers
--      row, abilityNum and PP Ups kept, the AI flags pret gives), a pair with
--      both trainers (B through the `trainer.party` hook with B's own id),
--      Steven with his three lifted out of the player's party and put back on
--      a hand-back, Battle._nextFacility taken at the start and put back;
--   5. the start bookkeeping each kind replays (pret battle_setup.c);
--   6. the BattleBridge.start wrap with each listener, and a refused partner
--      handed back with the party it found;
--   7. the TEACHY TV wrap: install, the hand-back, the outcome codes, a stale
--      instance, another mod's wrapper on top, restore; 7b. the save-borrow
--      ledger (src/Borrow3.lua) and its save.write link, and the TEACHY TV's
--      party and bag through it (a demonstration whose screen dies mid-fight,
--      the next one after it, a decline with no second intro, a half swap);
--      7c. the cart's own start after a dead demonstration (the ledger
--      settled before it backs the bag up again), and the tutorials' bag
--      pockets beside the POKe DUDE's party and bag through save.write;
--   8. the client's routing through the real headless loader: a kind co-op
--      does not fight goes straight to solo with its stand-in (`opts.stand3`)
--      and never to co-op, a plain one is offered to co-op first, and the
--      cart keeps every one of them when SOLO BATTLES is off.
--
-- Legal: every species, move, trainer and item row below is the SDK
-- fixture's or invented here with synthetic numbers; the only real values are
-- pret enum numbers the code branches on (FLAG_SYS_SAFARI_MODE 0x800,
-- ITEM_SILPH_SCOPE 359, the STATUS1_* bits, the B_OUTCOME_* codes the TEACHY
-- TV reads).
--
-- Run from the engine checkout root:
--
--   luajit mods/rby_mmo/tests/gen3_doors.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local check, eq = T.check, T.eq

local MOD_PATH = "mods/rby_mmo"
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

-- ------------------------------------------------------------------
-- the facade and the module graph
-- ------------------------------------------------------------------

local warns = {}
local OPTIONS = {}
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
    save = { get = function() return nil end, set = function() end },
    events = { emit = function() end },
  }
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

local function stub(name, value) package.loaded[name] = value end

-- ------------------------------------------------------------------
-- the fixture, and the stand-in engine
-- ------------------------------------------------------------------

local DATA = T.sdk.gen3Data()
local P3 = DATA.gen3Pokemon
local ROM = DATA.gen3Moves._rom
-- Synthetic rows for the held-item rolls and an ability slot: species 16
-- holds item 13 (common) or 96 (rare) in the wild, species 29 has a second
-- ability (synthetic id 2).
P3._speciesMeta[16].itemCommon = 13
P3._speciesMeta[16].itemRare = 96
P3._abilities[29] = { 38, 2 }

local SESSION
local function newSession(extra)
  local s = {
    engine = "game3", generation = 3, version = "firered",
    name = "ANN", trainerId = 111, secretId = 222, gender = 0,
    party = {}, dex = { seen = {}, caught = {}, owned = {} },
    bag = { items = {} }, money = 1000, map = "FR_ROUTE_1",
  }
  for k, v in pairs(extra or {}) do s[k] = v end
  return s
end

local FakeBag = {}
function FakeBag.has(bag, id, qty) return (bag.items[tonumber(id)] or 0) >= (qty or 1) end

local FakePokemon = { NUMBERING_INTERNAL = "internal" }
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
-- Pokemon.gender's rule: the species' ratio against personality % 256
-- (the fixture's ratio is 31 for every species).
function FakePokemon.gender(sp, personality)
  local meta = P3._speciesMeta[tonumber(sp)] or {}
  local ratio = tonumber(meta.genderRatio)
  if ratio == nil or ratio == 255 then return "U" end
  if ratio == 0 then return "M" end
  if ratio == 254 then return "F" end
  return (ratio > (tonumber(personality) or 0) % 256) and "F" or "M"
end
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
  mon.maxHp = st.maxHp
  if mon.hp == nil or mon.hp > st.maxHp then mon.hp = st.maxHp end
  mon.attack, mon.defense, mon.speed = st.attack, st.defense, st.speed
  mon.spAtk, mon.spDef = st.spAtk, st.spDef
  return mon
end

-- An engine-built monster (createMon + applyStats), the shape the Frontier,
-- Steven's party and the POKe DUDE hand over.
local function builtMon(species, level, extra)
  local mon = {
    species = species, speciesId = species, level = level, nickname = "",
    moves = { 33 }, pp = { 35 }, maxPp = { 35 },
    personality = 0x1234, nature = 0x1234 % 25,
    ivs = { hp = 15, atk = 15, def = 15, spe = 15, spa = 15, spd = 15 },
    evs = { hp = 0, atk = 0, def = 0, spe = 0, spa = 0, spd = 0 },
    ability = 38, abilityId = 38, abilityNum = 0, gender = "M", friendship = 70,
    heldItem = 0, item = 0, otId = 42,
  }
  for k, v in pairs(extra or {}) do mon[k] = v end
  FakePokemon.applyStats(mon)
  return mon
end

local rngState = 12345
local FakeRng = {}
function FakeRng.Random()
  rngState = (rngState * 1103515245 + 12345) % 2147483648
  return math.floor(rngState / 65536) % 65536
end
function FakeRng.Random32() return FakeRng.Random() * 65536 + FakeRng.Random() end

local rec = {}
local function note(kind, ...) rec[#rec + 1] = { kind = kind, ... } end
local function recorded(kind)
  local n = 0
  for _, r in ipairs(rec) do if r.kind == kind then n = n + 1 end end
  return n
end
local function lastOf(kind)
  local got
  for _, r in ipairs(rec) do if r.kind == kind then got = r end end
  return got
end

local FakeBB = {}
function FakeBB.start(_, _, foe, opts)
  note("engineStart", foe, opts, SESSION and #SESSION.party or 0)
  return true
end
function FakeBB.startWild(modArg, game, enc, opts)
  opts = opts or {}
  opts.wild = true
  return FakeBB.start(modArg, game, enc, opts)
end
function FakeBB.applyLeagueFriendship() note("league") end

local FakeProfile = {}
function FakeProfile.get(session)
  local rse = session and session.version == "emerald"
  return {
    family = rse and "rse" or "frlg", safari = false,
    kinds = rse and { firstBattle = "birch", tutorial = "wally", twoOpponents = true }
      or { firstBattle = "oak", tutorial = "oldman", ghost = true, pokedude = true },
    aiFlagBits = { CHECK_BAD_MOVE = 0, TRY_TO_FAINT = 1, CHECK_VIABILITY = 2 },
  }
end
function FakeProfile.aiBit(p, name) return 2 ^ p.aiFlagBits[name] end

local STORE = { flags = {} }
local FakeFlags = {}
function FakeFlags.getFlag(store, _, id) return store.flags[id] end
local FakeSpace = { store = STORE }
function FakeSpace.getStore() return STORE end
function FakeSpace.returnToField() end

local TRAINERS = {
  [326] = { class = 81, className = "RIVAL", name = "TERRY", pic = 5, items = { 13, 0, 0, 0 },
            aiFlags = 1, party = { { species = 4, level = 5 } } },
  -- A pair's second trainer, four monsters deep: the cart fields three.
  [327] = { class = 81, className = "RIVAL", name = "GARY", pic = 6, items = { 0, 0, 0, 0 },
            aiFlags = 4, party = { { species = 16, level = 6 }, { species = 29, level = 6 },
                                   { species = 4, level = 6 }, { species = 5, level = 6 } } },
  [328] = { class = 81, className = "RIVAL", name = "MANY", pic = 7, items = { 0, 0, 0, 0 },
            aiFlags = 2, party = { { species = 16, level = 7 }, { species = 29, level = 7 },
                                   { species = 4, level = 7 }, { species = 5, level = 7 } } },
  -- Steven, as the partner's row.
  [900] = { class = 12, className = "PKMN TRAINER", name = "STEVEN", pic = 9,
            items = { 0, 0, 0, 0 }, aiFlags = 0, party = { { species = 151, level = 9 } } },
}
local infoAsked = {}
local FakeTrainers = {}
function FakeTrainers.info(id)
  infoAsked[#infoAsked + 1] = tonumber(id)
  local t = TRAINERS[tonumber(id)]
  if not t then return nil end
  local out = {}
  for k, v in pairs(t) do out[k] = v end
  return out
end
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
    party[i] = { species = m.species, level = m.level, trainerId = tonumber(id),
                 ivs = { hp = 0, atk = 0, def = 0, spa = 0, spd = 0, spe = 0 },
                 evs = { hp = 0, atk = 0, def = 0, spa = 0, spd = 0, spe = 0 } }
  end
  local lead = party[1]
  return { species = lead.species, level = lead.level, trainerId = tonumber(id),
           items = t.items, party = party, trainerName = t.name, trainerClass = t.class,
           trainerClassName = t.className, trainerPic = t.pic, aiFlags = t.aiFlags }
end
function FakeTrainers.pack() return { classNames = { [81] = "RIVAL", [60] = "COOLTRAINER" } } end

-- FireRed's Trainer Tower: facility class 3 is trainer class 60.
local FakeTower = { pack = function() return { facilityClassTrainerClass = { [3] = 60 } } end }

local battleActive = false
local FakeBattle = { isActive = function() return battleActive end }

-- The start bookkeeping a fight replays: Emerald's match call, its TV tally.
local FakeCaps = { gate = function(session, name)
  return name == "match_call" and session and session.version == "emerald"
end }
local FakeRematch = {
  onTrainerBattleStart = function() note("rematchTrainer") end,
  onWildBattleStart = function() note("rematchWild") end,
}
local FakeRse = { call = function(sys, fn) note("rse:" .. tostring(sys) .. "." .. tostring(fn)) end }

local FakeEncounters = { rules = function() return { wildHeldItem = function() return 0 end } end,
                         resetRateModifiers = function() note("encReset") end }
local FakeSafari = { isActive = function() return false end }
local FakeParty = { healAll = function() end }
local FakeNatives = { outcome_to_code = function(r)
  if r == "win" then return 1 elseif r == "lose" then return 2 elseif r == "draw" then return 3 end
  return 1
end }
local FakeAudio = setmetatable({}, { __index = function() return function() return true end end })

-- The TEACHY TV's POKe DUDE (battle/pokedude.lua), recording.
local FakePokedude = { OUTCOME = { WON = 1, LOST = 2, DREW = 3, RAN = 4, CAUGHT = 7 } }
function FakePokedude.build(scriptId)
  note("pokedudeBuild", scriptId)
  return { builtMon(16, 15, { personality = 1 }) }, { builtMon(29, 11, { personality = 2 }) }
end
function FakePokedude.startTeachyTvBattle(session, scriptId, opts)
  -- With what the cart's start finds: the party, the TEACHY TV on the stack,
  -- the bag menu.
  local S = package.loaded["src.ui.game3.stack"]
  local bagMenu = package.loaded["src.ui.game3.bag_menu"]
  note("pokedudeStart", session, scriptId, opts, {
    party = SESSION and SESSION.party, tv = S and S.has("teachy_tv"),
    bagOpen = type(bagMenu) == "table" and bagMenu.open or nil,
  })
  return true
end
local FakeTeachyTv = {}
function FakeTeachyTv.initPokedudeBag(session, scriptId)
  note("initBag", scriptId)
  session.teachyBagBackup = true
  return 1
end
function FakeTeachyTv.restorePlayerBag(session)
  note("restoreBag")
  if type(session) == "table" then session.teachyBagBackup = nil end
  return true
end
-- pret teachy_tv.c:1172: WHITE_BARS_FADE for the battle basics, SLICE for the
-- rest (the engine's TeachyTv.battleTransition; ids as the engine numbers them).
function FakeTeachyTv.battleTransition(scriptId) return tonumber(scriptId) == 0 and 9 or 8 end

-- The engine's battle transition (battle_transition.lua): recorded, its
-- `doneCb` run at once -- or held until the suite lets it finish.
local FakeTransition = { ID = { SLICE = 8 }, hold = false, held = nil }
function FakeTransition.start(id, opts, cb)
  note("transition", id, opts)
  if FakeTransition.hold then
    FakeTransition.held = cb
    return true
  end
  if cb then cb() end
  return true
end
function FakeTransition.release()
  local cb = FakeTransition.held
  FakeTransition.held = nil
  if cb then cb() end
end

local function installStubs()
  stub("src.core.game3.runtime", { getSession = function() return SESSION end, _mod = "ENGINE_MOD" })
  stub("src.core.game3.pokemon", FakePokemon)
  stub("src.core.game3.bag", FakeBag)
  stub("src.core.game3.rng", FakeRng)
  stub("src.core.game3.battle_bridge", FakeBB)
  stub("src.core.game3.battle", FakeBattle)
  stub("src.core.game3.battle.profile", FakeProfile)
  stub("src.core.game3.battle.pokedude", FakePokedude)
  stub("src.core.game3.teachy_tv", FakeTeachyTv)
  stub("src.core.game3.battle_transition", FakeTransition)
  stub("src.core.game3.trainer_tower", FakeTower)
  stub("src.core.game3.scripting.flags", FakeFlags)
  stub("src.core.game3.scripting.space", FakeSpace)
  stub("src.core.game3.scripting.trainers", FakeTrainers)
  stub("src.core.game3.scripting.natives", FakeNatives)
  stub("src.core.game3.capabilities", FakeCaps)
  stub("src.core.game3.rse.rematch", FakeRematch)
  stub("src.core.game3.rse.init", FakeRse)
  stub("src.core.game3.encounters", FakeEncounters)
  stub("src.core.game3.safari", FakeSafari)
  stub("src.core.game3.party", FakeParty)
  stub("src.core.game3.audio", FakeAudio)
end
installStubs()

local Stack = require("src.ui.game3.stack")

local need = newNeed(stubMod)
local Config = need("Config")
local CoopField = need("CoopField")
local Coop = need("Coop")
local Solo = need("SoloBattle")

local GAME
local function newGame(sessionExtra)
  SESSION = newSession(sessionExtra)
  GAME = { generation = 3, phase = "field", data = DATA, session = SESSION }
  stubMod.game = GAME
  Stack.clear()
  rec = {}
  infoAsked = {}
  STORE.flags = {}
  FakeBattle._nextFacility = nil
  battleActive = false
  return GAME
end

local function listOf(t)
  local out = {}
  for _, v in ipairs(t or {}) do out[#out + 1] = tostring(v) end
  return table.concat(out, ",")
end

-- ------------------------------------------------------------------
-- 1. the two lists
-- ------------------------------------------------------------------

do
  eq(listOf(Config.COOP_REFUSED_GEN3), table.concat({
    "safari", "roamer", "wildScripted", "legendary", "ghost", "ghostBattle",
    "kyogreGroudon", "regi", "groudon", "kyogre", "rayquaza",
    "firstBattle", "firstBattleKind", "oldManTutorial", "tutorialKind",
    "tutorial", "pokedude",
    "frontier", "dome", "palace", "arena", "factory", "pike", "pyramid",
    "battleTower", "trainerTower", "trainerHill", "secretBase", "eReader",
    "link", "multi", "unionRoom", "spectate", "recordedLink", "towerLinkMulti",
    "partner", "twoOpponents" }, ","),
    "co-op refuses every key it refused before solo took the rest (C1)")
  eq(listOf(Config.SOLO_REFUSED_GEN3),
    "link,multi,unionRoom,spectate,recordedLink,towerLinkMulti,eReader",
    "the cart keeps only the link family and the e-Reader")
  local coop = {}
  for _, k in ipairs(Config.COOP_REFUSED_GEN3) do coop[k] = true end
  for _, k in ipairs(Config.SOLO_REFUSED_GEN3) do
    check(coop[k], "whatever the cart keeps for solo it keeps for co-op too: " .. k)
  end
  eq(CoopField.refused3(Config.SOLO_REFUSED_GEN3, { legendary = true }, { link = true }), "link",
     "refused3 reads the list it is given, over every table")
  eq(CoopField.refused3(Config.COOP_REFUSED_GEN3, { firstBattle = false }), nil,
     "a key set to false refuses nothing (the trainer op's firstBattle = false)")
  eq(CoopField.refused3(nil, { link = true }), nil, "no list, no refusal")
end

-- ------------------------------------------------------------------
-- 2. classification
-- ------------------------------------------------------------------

do
  newGame()
  local function kind(wild, foe, opts, ctx)
    local c = CoopField.classify3(wild, foe or {}, opts, ctx)
    return c.kind3, c.facility3 or c.tutorial3 or c.firstBattle3 or c.ghost3
  end
  local foe = { species = 16, level = 3 }
  -- trainers
  eq(kind(false, foe, { trainerId = 326 }), "trainer", "a plain trainer")
  eq(kind(false, foe, { trainerId = 326, firstBattle = false }), "trainer",
     "firstBattle = false is an ordinary trainer")
  eq(kind(false, foe, { trainerId = 326, double = true }), "trainer", "a lone double is a trainer")
  eq(select(2, kind(false, foe, { trainerId = 326, earlyRival = true, firstBattle = true })), "oak",
     "Oak's lab is FireRed's first battle")
  eq(kind(false, foe, { trainerId = 326, trainerIdB = 327, twoOpponents = true, double = true }),
     "pair", "two trainers who spot you at once")
  eq(kind(false, foe, { trainerId = 326, trainerIdB = 327, twoOpponents = true, partner = true,
                        playerHalf = 3 }), "partner", "Steven beside you")
  local halls = {
    { { frontier = true, battleTower = true, tower = true }, "tower" },
    { { frontier = true, dome = true }, "dome" },
    { { frontier = true, palace = true }, "palace" },
    { { frontier = true, arena = true }, "arena" },
    { { frontier = true, factory = true }, "factory" },
    { { frontier = true, pike = true }, "pike" },
    { { frontier = true, pyramid = true }, "pyramid" },
    { { trainerHill = true }, "hill" },
    { { trainerId = 0, trainerTower = true }, "trainerTower" },
    { { trainerId = 1024, secretBase = true }, "secretBase" },
    { { trainerId = 0, eReader = true }, "eReader" },
    { { frontier = true }, "tower" },
  }
  for _, row in ipairs(halls) do
    local k, hall = kind(false, foe, row[1])
    eq(k, "facility", "facility: " .. row[2])
    eq(hall, row[2], "...in its own hall: " .. row[2])
  end
  eq(select(2, kind(false, foe, { frontier = true, battleTower = true, partner = true,
                                   twoOpponents = true, playerHalf = 3 })), "tower",
     "a Battle Tower multi is the Tower's, partner and all")
  eq(select(2, kind(false, foe, { frontier = true, pike = true, twoOpponents = true })), "pike",
     "the Pike double is the Pike's")
  -- tutorials
  eq(select(2, kind(true, { species = 13, level = 5, oldManTutorial = true },
                    { wild = true, oldManTutorial = true })), "oldMan", "the Viridian old man")
  eq(select(2, kind(true, foe, { wild = true, tutorialKind = "wally" })), "wally", "Wally's Ralts")
  eq(select(2, kind(true, foe, { wild = true, tutorialKind = "oldman" })), "oldMan",
     "the profile's spelling of the old man")
  eq(select(2, kind(true, foe, { wild = true, pokedude = true })), "pokedude", "the POKe DUDE")
  -- wild kinds
  eq(kind(true, foe, { wild = true }), "wild", "a plain wild")
  eq(kind(true, foe, nil), "wild", "a plain step encounter")
  eq(select(2, kind(true, foe, { wild = true, firstBattleKind = "birch" })), "birch",
     "Birch's Zigzagoon is Emerald's first battle")
  eq(kind(true, foe, { wild = true, safari = true }), "safari", "a Safari wild by its key")
  STORE.flags[0x800] = true  -- FLAG_SYS_SAFARI_MODE
  eq(kind(true, foe, nil), "safari", "a step encounter in the Safari Zone (the session says)")
  eq(kind(true, foe, { wild = true, wildScripted = true }), "scripted",
     "a scripted wild in the zone is still scripted (battle_bridge's standardWild)")
  STORE.flags[0x800] = nil
  eq(kind(true, { species = 243, level = 50, roamer = true, foe = { roamer = true } }), "roamer",
     "a roamer at the roll")
  eq(kind(true, foe, { wild = true, roamer = true }), "roamer", "a roamer at the start")
  eq(select(2, kind(true, foe, nil, { mapId = "FR_POKEMON_TOWER_3F" })), "veiled",
     "a POKeMON TOWER wild without the SILPH SCOPE is a veiled ghost")
  SESSION.bag.items[359] = 1
  eq(kind(true, foe, nil, { mapId = "FR_POKEMON_TOWER_3F" }), "wild", "and with it, a wild")
  SESSION.bag.items[359] = nil
  eq(select(2, kind(true, { species = 105, ghost = true, ghostUnveiled = true, wildScripted = true },
                    { wild = true, wildScripted = true })), "unveiled",
     "the Marowak with the scope is an unveiled ghost, not a scripted wild")
  eq(kind(true, { species = 16, ghost = false }, { wild = true }, { mapId = "FR_POKEMON_TOWER_3F" }),
     "wild", "an explicit ghost = false wins over the map")
  for _, key in ipairs({ "legendary", "regi", "kyogre", "groudon", "kyogreGroudon", "rayquaza" }) do
    eq(kind(true, foe, { wild = true, [key] = true }), "legendary", "a legend: " .. key)
  end
  eq(kind(true, { species = 151, legendary = true, specialWild = true }, { wild = true }), "legendary",
     "FireRed's legend, by its foe")
  eq(kind(true, foe, { wild = true, wildScripted = true }), "scripted", "a scripted wild")
  eq(kind(true, foe, { wild = true, pike = true, frontier = true, scriptedLoss = true }), "facility",
     "a Pike wild is the Pike's")
  newGame({ version = "emerald" })
  eq(select(2, kind(true, foe, { wild = true, tutorial = true })), "wally",
     "Emerald's profile names its own tutorial")
end

-- ------------------------------------------------------------------
-- 3. who is offered it
-- ------------------------------------------------------------------

do
  newGame()
  local base = { species = "PIDGEY", speciesId = 16, level = 3 }
  local function wild(enc, opts, solo, mapId)
    return CoopField.wildStand3(enc, { game = GAME, mapId = mapId or "FR_ROUTE_1", solo = solo }, opts)
  end
  local function trainer(opts, solo, foe)
    return CoopField.trainerStand3(foe or FakeTrainers.foeFromId(326), opts,
      { game = GAME, solo = solo })
  end
  -- a plain fight: offered to co-op either way
  local s = wild(base, nil, false)
  eq(s and s.kind3, "wild", "a plain wild is built for co-op")
  eq(s and s.coopRefused3, nil, "...and co-op may have it")
  s = wild(base, nil, true)
  eq(s and s.coopRefused3, nil, "with SOLO BATTLES on too")
  s = trainer({ trainerId = 326 }, false)
  eq(s and s.kind3, "trainer", "a plain trainer is built for co-op")
  eq(s and s.coopRefused3, nil, "...and co-op may have it")
  -- every kind co-op does not fight: refused with only co-op listening,
  -- built and marked with SOLO BATTLES on
  local wilds = {
    { "safari", base, { wild = true, safari = true } },
    { "roamer", { species = 243, speciesId = 243, level = 50, roamer = true,
                  foe = { species = 16, level = 50, roamer = true, hp = 10 } } },
    { "legendary", { species = 151, level = 50 }, { wild = true, legendary = true } },
    { "wildScripted", { species = 16, level = 30 }, { wild = true, wildScripted = true } },
    { "ghost", { species = 16, level = 30, ghost = true }, { wild = true } },
    { "firstBattleKind", { species = 16, level = 2, item = 0 }, { wild = true, firstBattleKind = "birch" } },
    { "oldManTutorial", { species = 16, level = 5, oldManTutorial = true }, { wild = true, oldManTutorial = true } },
    { "tutorialKind", { species = 29, level = 5, gender = "M" }, { wild = true, tutorialKind = "wally" } },
    -- the list names `frontier` before the hall
    { "frontier", { species = 29, level = 50 }, { wild = true, pike = true, frontier = true, scriptedLoss = true } },
  }
  for _, row in ipairs(wilds) do
    local why = select(2, wild(row[2], row[3], false))
    eq(why, row[1], "co-op alone: refused, " .. row[1])
    local stand = wild(row[2], row[3], true)
    check(stand ~= nil, "SOLO BATTLES on: built, " .. row[1])
    check(stand and stand.coopRefused3 ~= nil, "...and never co-op's: " .. row[1])
  end
  local ghostWhy = select(2, wild(base, nil, false, "FR_POKEMON_TOWER_3F"))
  eq(ghostWhy, "ghost", "co-op alone: the tower ghost is the cart's")
  STORE.flags[0x800] = true
  eq(select(2, wild(base, nil, false)), "safari", "co-op alone: the Safari Zone is the cart's")
  local saf = wild(base, nil, true)
  eq(saf and saf.kind3, "safari", "SOLO BATTLES on: a Safari stand-in")
  eq(saf and saf.safari, true, "...marked as one")
  STORE.flags[0x800] = nil
  local trainers = {
    { "firstBattle", { trainerId = 326, earlyRival = true, firstBattle = true } },
    { "twoOpponents", { trainerId = 326, trainerIdB = 327, twoOpponents = true, double = true } },
    { "partner", { trainerId = 326, trainerIdB = 327, twoOpponents = true, partner = true,
                   playerHalf = 1, partnerTrainerId = 900 } },
    { "trainerTower", { trainerId = 0, trainerTower = true } },
    { "secretBase", { trainerId = 1024, secretBase = true } },
    { "frontier", { frontier = true, palace = true } },
    { "trainerHill", { trainerHill = true } },
  }
  for _, row in ipairs(trainers) do
    local why = select(2, trainer(row[2], false))
    eq(why, row[1], "co-op alone: refused, " .. row[1])
  end
  -- what stays on the cart, for everybody
  for _, key in ipairs({ "multi", "unionRoom", "spectate", "recordedLink", "towerLinkMulti", "eReader" }) do
    eq(select(2, trainer({ trainerId = 326, [key] = true }, true)), key,
       "the cart keeps it even with SOLO BATTLES on: " .. key)
  end
  eq(select(2, trainer({ trainerId = 326, link = true }, true)), "link", "a link battle is the peer's")
  eq(select(2, wild(base, { wild = true, recordedLink = true }, true)), "recordedLink",
     "a recorded wild is the cart's replay")
  eq(select(2, wild({ speciesId = 16, level = 3, foe = { species = 16 } }, nil, true)), "foe",
     "an encounter carrying a foe record nobody knows is the cart's")
  eq(CoopField.trainerStand3({ species = 4, level = 5 }, {}, { game = GAME, solo = true }), nil,
     "a start with no trainer id and no facility is not a trainer")
  -- Coop's own refusal: no caller can seat a refused stand-in in a co-op 2v2.
  local refusedStand = wild(base, { wild = true, legendary = true }, true)
  eq(Coop.refusedKind3(refusedStand), true, "Coop.refusedKind3 reads the mark")
  eq(Coop.refusedKind3(wild(base, nil, true)), false, "and lets a plain wild through")
end

-- ------------------------------------------------------------------
-- 4. each kind's stand-in
-- ------------------------------------------------------------------

-- a roamer, as its save describes it (pret CreateRoamerMonInstance)
do
  newGame()
  local desc = { species = 16, speciesId = 16, level = 50, hp = 17, maxHp = 999,
                 status = 0, statusNum = 8, pid = 0x00ABCDEF,
                 ivs = { hp = 31, attack = 30, defense = 29, speed = 28, spAtk = 27, spDef = 26 },
                 moves = { 33 }, pp = { 35 }, roamer = true }
  local enc = { species = "PIDGEY", speciesId = 16, level = 50, roamer = true, foe = desc }
  local stand = CoopField.wildStand3(enc, { game = GAME, mapId = "FR_ROUTE_1", solo = true })
  local mon = stand and stand.enemyParty[1]
  eq(stand and stand.kind3, "roamer", "roamer: the stand-in's kind")
  eq(stand and stand.roamer, true, "roamer: marked")
  eq(stand and stand.roamerFoe, desc, "roamer: the save's descriptor rides along")
  eq(mon and mon.personality, 0x00ABCDEF, "roamer: FireRed's pid is the personality")
  eq(mon and mon.ivs.atk, 30, "roamer: attack IV under the battle's key")
  eq(mon and mon.ivs.spd, 26, "roamer: ...and spDef")
  eq(mon and mon.hp, 17, "roamer: the HP the save banked")
  eq(mon and mon.status, "PSN", "roamer: FireRed's status byte (STATUS1_POISON)")
  -- Emerald: the status byte is the status itself; a sleep counter in bits 0-2.
  local em = CoopField.foeMon3({ species = 16, level = 40, personality = 7, hp = 9,
                                 ivs = { hp = 1, atk = 2, def = 3, spe = 4, spa = 5, spd = 6 },
                                 status = 3, roamer = true }, { wild = true })
  eq(em.status, "SLP", "roamer (Emerald): a sleeping one")
  eq(em.sleep, 3, "...with its turns")
  eq(em.personality, 7, "...its own personality")
  eq(em.hp, 9, "...its banked HP")
  eq(select(1, CoopField.status3("PAR")), "PAR", "an engine status word passes")
  eq(select(1, CoopField.status3(64)), "PAR", "STATUS1_PARALYSIS")
  eq(select(1, CoopField.status3(128)), "TOX", "STATUS1_TOXIC_POISON")
  eq(select(1, CoopField.status3(0, 0)), nil, "no status")
end

-- the legends and the ghosts, as the natives fixed them
do
  newGame()
  local seen = 0
  for _ = 1, 20 do
    local legend = CoopField.wildStand3({ species = 16, level = 50 },
      { game = GAME, solo = true }, { wild = true, legendary = true })
    if (legend.enemyParty[1].heldItem or 0) ~= 0 then seen = seen + 1 end
  end
  eq(seen, 0, "a legend never rolls a wild held item (pret SetWildMonHeldItem: LEGENDARY)")
  local fateful = CoopField.wildStand3({ species = 151, level = 30, fatefulEncounter = true },
    { game = GAME, solo = true }, { wild = true, legendary = true })
  eq(fateful and fateful.enemyParty[1].fatefulEncounter, true,
     "a fateful encounter stays one (what lets Mew obey)")
  local exempt = 0
  for _ = 1, 20 do
    local ghostly = CoopField.wildStand3({ species = 16, level = 30, ghostUnveiled = true, ghost = true },
      { game = GAME, solo = true }, { wild = true })
    if (ghostly.enemyParty[1].heldItem or 0) ~= 0 then exempt = exempt + 1 end
  end
  eq(exempt, 0, "nor the unveiled GHOST (SoloBattle.gen3HeldRoll is the gate)")
  local rolled = 0
  for _ = 1, 40 do
    local scripted = CoopField.wildStand3({ species = 16, level = 30 },
      { game = GAME, solo = true }, { wild = true, wildScripted = true })
    if (scripted.enemyParty[1].heldItem or 0) ~= 0 then rolled = rolled + 1 end
  end
  check(rolled > 0, "a scripted wild rolls one, as any wild does")
  -- setwildbattle's own item: SetWildMonHeldItem runs after the script made
  -- the monster (CB2_InitBattleInternal), so a draw that writes rolls over
  -- it and one that returns early (FireRed: 0..44) leaves it (W3-CORE).
  local over, kept = 0, 0
  for _ = 1, 40 do
    local scripted = CoopField.wildStand3({ species = 16, level = 30, item = 77 },
      { game = GAME, solo = true }, { wild = true, wildScripted = true })
    local held = scripted.enemyParty[1].heldItem
    if held == 77 then kept = kept + 1 elseif held == 13 or held == 96 then over = over + 1 end
  end
  check(over > 0, "a scripted wild's own item is rolled over when the draw writes")
  check(kept > 0, "...and kept when it returns early")
  eq(over + kept, 40, "...nothing else")
  local legendKept = CoopField.wildStand3({ species = 16, level = 30, item = 77 },
    { game = GAME, solo = true }, { wild = true, legendary = true })
  eq(legendKept.enemyParty[1].heldItem, 77, "a legend keeps the script's item (no roll at all)")
  local marowak = CoopField.wildStand3({ species = 29, level = 30, ghost = true, ghostUnveiled = true,
    wildScripted = true, gender = "F", nature = 12,
    ivs = { hp = 31, atk = 31, def = 31, spe = 31, spa = 31, spd = 31 } },
    { game = GAME, solo = true }, { wild = true, wildScripted = true })
  local m = marowak and marowak.enemyParty[1]
  eq(marowak and marowak.ghost3, "unveiled", "the unveiled Marowak")
  eq(m and m.nature, 12, "...with the nature the native fixed")
  eq(m and m.gender, "F", "...the gender")
  eq(m and m.ivs.spe, 31, "...and the IVs")
  eq(m and m.heldItem, 0, "...and no held-item roll (GHOST_UNVEILED is the LEGENDARY bit)")
  eq(m and m.personality % 25, 12, "...a personality that is SERIOUS (CreateMonWithGenderNatureLetter)")
  eq(m and FakePokemon.gender(29, m.personality), "F", "...and female")
  local wally = CoopField.wildStand3({ species = 29, level = 5, gender = "M" },
    { game = GAME, solo = true }, { wild = true, tutorialKind = "wally" })
  eq(wally and wally.tutorial3, "wally", "Wally's lesson")
  eq(wally and wally.enemyParty[1].gender, "M", "...a male Ralts, as CreateMaleMon makes it")
  eq(wally and FakePokemon.gender(29, wally.enemyParty[1].personality), "M",
     "...whose personality is a male's")
  local birch = CoopField.wildStand3({ species = 16, level = 2, item = 0 },
    { game = GAME, solo = true }, { wild = true, firstBattleKind = "birch" })
  eq(birch and birch.firstBattle3, "birch", "Birch's rescue")
  eq(birch and birch.enemyParty[1].level, 2, "...at its own level")
  -- Its one SetWildMonHeldItem roll is the kind's (Solo3/First.lua, in
  -- `takes`): the stand-in keeps the start's zeroed item, never drawn twice.
  local birchHeld = 0
  for _ = 1, 20 do
    local b = CoopField.wildStand3({ species = 16, level = 2, item = 0 },
      { game = GAME, solo = true }, { wild = true, firstBattleKind = "birch" })
    if (b.enemyParty[1].heldItem or 0) ~= 0 then birchHeld = birchHeld + 1 end
  end
  eq(birchHeld, 0, "...built with the start's zeroed item, its roll left to the first-battle kind")
  local pyr = builtMon(29, 33, { personality = 99, ability = 2, abilityNum = 1 })
  local pyramid = CoopField.wildStand3(pyr, { game = GAME, solo = true },
    { wild = true, pyramid = true, frontier = true, scriptedLoss = true })
  local pm = pyramid and pyramid.enemyParty[1]
  eq(pyramid and pyramid.facility3, "pyramid", "a Pyramid wild")
  eq(pyramid and pyramid.scriptedLoss, true, "...its loss is the floor script's")
  check(pm ~= nil and pm ~= pyr, "...taken as the facility built it, in a copy of its own")
  eq(pm and pm.personality, 99, "...its personality")
  eq(pm and pm.ability, 2, "...its ability")
  eq(pm and pm.maxHp, pyr.maxHp, "...its stats")
end

-- Emerald's ALTERING CAVE (W3-CORE): a wild met there rolls the cave's own
-- held items (pret pokeemerald pokemon.c:6692, LAYOUT_ALTERING_CAVE) -- the
-- stand-in's roll is told so from the map, whichever builder it goes through.
do
  newGame({ version = "emerald" })
  local realRules = FakeEncounters.rules
  local asks, answer = {}, 21
  FakeEncounters.rules = function()
    return { wildHeldItem = function(species, opts)
      asks[#asks + 1] = { species = species, opts = opts or {} }
      return answer
    end }
  end
  local cave = CoopField.wildStand3({ species = 16, level = 20 },
    { game = GAME, solo = true, mapId = "EM_ALTERING_CAVE" })
  eq(asks[1] and asks[1].opts.alteringCave, true, "altering cave: the stand-in's roll asks the cave's arm")
  eq(cave and cave.enemyParty[1].heldItem, 21, "altering cave: ...and its monster holds what it gave")
  asks = {}
  CoopField.wildStand3({ species = 16, level = 20 }, { game = GAME, solo = true, mapId = "EM_ROUTE_101" })
  eq(#asks, 1, "altering cave: any other map rolls too")
  eq(asks[1] and asks[1].opts.alteringCave, nil, "altering cave: ...an ordinary roll")
  asks = {}
  CoopField.wildStand3({ species = 16, level = 20 }, { game = GAME, solo = true })
  eq(#asks, 1, "altering cave: a door that names no map rolls too")
  eq(asks[1] and asks[1].opts.alteringCave, nil, "altering cave: ...an ordinary roll")
  asks = {}
  CoopField.wildFoe3({ kind3 = "wild" }, { species = 16, level = 20 }, SESSION, {}, "EM_ALTERING_CAVE")
  eq(asks[1] and asks[1].opts.alteringCave, true, "altering cave: wildFoe3 forwards the map")
  asks = {}
  CoopField.foeMon3({ species = 16, level = 20 }, { wild = true, alteringCave = true })
  eq(asks[1] and asks[1].opts.alteringCave, true, "altering cave: foeMon3 forwards the flag")
  asks = {}
  CoopField.wildMon3({ species = 16, level = 20 }, SESSION, "EM_ALTERING_CAVE")
  eq(asks[1] and asks[1].opts.alteringCave, true, "altering cave: ...and wildMon3 the map")
  asks = {}
  CoopField.wildStand3({ species = 16, level = 20 }, { game = GAME, solo = true, mapId = "EM_ALTERING_CAVE" },
    { wild = true, legendary = true })
  eq(#asks, 0, "altering cave: a legend there still rolls nothing")
  check(CoopField.alteringCave3("EM_ALTERING_CAVE"), "altering cave: the map is Emerald's cave")
  check(not CoopField.alteringCave3("FR_SIX_ISLAND_ALTERING_CAVE"), "altering cave: ...not FireRed's")
  -- Emerald's roll writes ITEM_NONE over setwildbattle's item (the engine's
  -- 0 is a written item; its nil an early return that leaves it).
  answer = 0
  local cleared = CoopField.wildStand3({ species = 16, level = 30, item = 77 },
    { game = GAME, solo = true }, { wild = true, wildScripted = true })
  eq(cleared.enemyParty[1].heldItem, 0, "Emerald: a written ITEM_NONE clears the script's item")
  answer = nil
  local keptEm = CoopField.wildStand3({ species = 16, level = 30, item = 77 },
    { game = GAME, solo = true }, { wild = true, wildScripted = true })
  eq(keptEm.enemyParty[1].heldItem, 77, "Emerald: an early return keeps it")
  FakeEncounters.rules = realRules
end

-- a facility's trainer: no gTrainers row, its own monsters, pret's AI flags
do
  newGame()
  -- FireRed's Trainer Tower: battleTowerMon rows (trainer_tower.lua).
  local row = { species = 29, level = 40, heldItem = 13, moves = { 33, 52 }, ppBonuses = 3 + 2 * 4,
                iv = 20, ivs = { hp = 20, atk = 21, def = 22, spe = 23, spa = 24, spd = 25 },
                evs = { hp = 4, atk = 0, def = 0, spe = 0, spa = 0, spd = 0 },
                personality = 4, abilityNum = 1, friendship = 0, otId = 77, nickname = "TOWERMON",
                trainerId = 0 }
  local foe = { party = { row }, trainerId = 0, trainerName = "LIA", trainerClass = 3,
                trainerPicId = 31, species = 29, level = 40 }
  local stand = CoopField.trainerStand3(foe, { trainerId = 0, trainerTower = true, double = false,
    trainerName = "LIA", trainerPicId = 31, noWhiteout = true, done = function() end },
    { game = GAME, solo = true })
  local t = stand and stand.trainer
  local mon = stand and stand.enemyParty[1]
  eq(stand and stand.facility3, "trainerTower", "Trainer Tower: the hall")
  eq(#infoAsked, 0, "Trainer Tower: Trainers.info is never asked (no gTrainers row)")
  eq(t and t.name, "LIA", "Trainer Tower: the trainer's own name")
  eq(t and t.trainerClass, 60, "Trainer Tower: the facility class mapped to a trainer class")
  eq(t and t.className, "COOLTRAINER", "Trainer Tower: ...and named")
  eq(t and t.pic, 31, "Trainer Tower: its pic")
  eq(t and t.aiFlags, 7, "Trainer Tower: CHECK_BAD_MOVE | TRY_TO_FAINT | CHECK_VIABILITY")
  eq(listOf(t and t.items), "0,0,0,0", "Trainer Tower: no trainer items")
  eq(mon and mon.ability, 2, "Trainer Tower: abilityNum 1 is the second ability")
  eq(mon and mon.nickname, "TOWERMON", "Trainer Tower: the row's nickname")
  eq(mon and mon.friendship, 0, "Trainer Tower: its friendship, zero included")
  eq(mon and mon.otId, 77, "Trainer Tower: its OT")
  eq(mon and mon.heldItem, 13, "Trainer Tower: its held item")
  eq(mon and mon.ivs.spd, 25, "Trainer Tower: its IVs")
  eq(mon and mon.maxPp[1], 35 + 3 * 7, "Trainer Tower: PP Ups raise the maximum (CalculatePPWithBonus)")
  eq(mon and mon.maxPp[2], 25 + 2 * 5, "Trainer Tower: ...per slot")
  eq(mon and mon.pp[1], 35, "Trainer Tower: ...but the current PP stays the base (CreateBattleTowerMon)")
  -- Emerald's Frontier: finished monsters, a frontierTrainer record.
  newGame({ version = "emerald" })
  local a1, a2 = builtMon(29, 50, { personality = 11 }), builtMon(16, 50, { personality = 12 })
  local b1 = builtMon(4, 50, { personality = 13 })
  local ffoe = { party = { a1, a2, b1 }, trainerName = "ANNA", trainerClass = 44,
                 trainerClassName = "ACE TRAINER", trainerPicId = 20, frontierTrainerId = 101 }
  local nextFac = { rules = "palace" }
  FakeBattle._nextFacility = nextFac
  local fstand = CoopField.trainerStand3(ffoe, { wild = false, frontier = true, palace = true,
    aiFlags = 5, trainerItems = { 0, 0, 0, 0 }, scriptedLoss = true, defeatText = "Ah\\pwell",
    frontierTrainer = { class = 44, className = "ACE TRAINER", name = "ANNA", pic = 20 } },
    { game = GAME, solo = true })
  eq(fstand and fstand.facility3, "palace", "Frontier: the hall")
  eq(#infoAsked, 0, "Frontier: Trainers.info is never asked")
  eq(fstand and fstand.trainer.name, "ANNA", "Frontier: the frontierTrainer's name")
  eq(fstand and fstand.trainer.frontierTrainerId, 101, "Frontier: its facility id")
  eq(fstand and fstand.trainer.aiFlags, 5, "Frontier: the AI flags the facility passed")
  eq(fstand and fstand.scriptedLoss, true, "Frontier: a loss is the facility's")
  eq(fstand and #fstand.enemyParty, 3, "Frontier: every monster")
  check(fstand and fstand.enemyParty[1] ~= a1, "Frontier: copies, not the engine's own tables")
  eq(fstand and fstand.enemyParty[1].personality, 11, "Frontier: ...of the monsters as built")
  eq(fstand and fstand.enemyParty[2].attack, a2.attack, "Frontier: ...stats and all")
  eq(fstand and fstand.nextFacility3, nextFac, "Frontier: the hall's rules object is held")
  eq(FakeBattle._nextFacility, nextFac, "Frontier: ...but not taken before the fight begins")
  -- the Secret Base: pret's three flags where the start passes none
  local sb = CoopField.trainerStand3({ party = { builtMon(16, 20) }, trainerName = "MAY",
    trainerClass = 44, trainerClassName = "PKMN TRAINER", trainerPicId = 3 },
    { trainerId = 1024, secretBase = true, noWhiteout = true, deferHeal = true },
    { game = GAME, solo = true })
  eq(sb and sb.trainer.aiFlags, 7, "Secret Base: CHECK_BAD_MOVE | TRY_TO_FAINT | CHECK_VIABILITY")
  eq(sb and sb.trainer.name, "MAY", "Secret Base: the base owner's name")
  -- a facility pair: one party, A's half first
  local pike = CoopField.trainerStand3({ party = { a1, b1 }, trainerName = "ANNA" },
    { frontier = true, pike = true, double = true, twoOpponents = true, frontierFoeHalf = 1,
      frontierTrainer = { class = 44, name = "ANNA", pic = 20 },
      frontierTrainerB = { class = 45, name = "BEN", pic = 21 }, defeatTextB = "Oh\\pno",
      defeatText = "Ah\\pwon", victoryText = "A beat you" },
    { game = GAME, solo = true })
  eq(pike and pike.facility3, "pike", "Pike double: the Pike's")
  eq(pike and #pike.enemyParty, 1, "Pike double: A's half")
  eq(pike and pike.enemyPartyB and #pike.enemyPartyB, 1, "Pike double: B's half")
  eq(pike and pike.enemyPartyB[1].personality, 13, "Pike double: ...B's own monster")
  eq(pike and pike.trainerB and pike.trainerB.name, "BEN", "Pike double: the second trainer")
  eq(pike and pike.defeatTextB, "Oh\fno", "Pike double: B's defeat line, paged")
  eq(pike and pike.trainerB.defeatText, "Oh\n\nno", "Pike double: B's record carries B's line")
  eq(pike and pike.trainerB.victoryText, nil, "Pike double: ...and never A's")
  eq(pike and pike.trainer.defeatText, "Ah\n\nwon", "Pike double: A's record, A's line")
end

-- two trainers who spot you at once (pret battle_main.c:1977)
do
  newGame({ version = "emerald" })
  local hooked = {}
  local hookedFoe = Solo.gen3HookedFoe
  Solo.gen3HookedFoe = function(foe, tid) hooked[#hooked + 1] = tid; return hookedFoe(foe, tid) end
  local stand = CoopField.trainerStand3(FakeTrainers.foeFromId(328), {
    trainerId = 328, trainerIdB = 327, twoOpponents = true, double = true,
    defeatText = "A lost", defeatTextB = "B\\plost", done = function() end },
    { game = GAME, solo = true })
  Solo.gen3HookedFoe = hookedFoe
  eq(stand and stand.kind3, "pair", "pair: the kind")
  eq(stand and #stand.enemyParty, 3, "pair: A fields three of four")
  eq(stand and #stand.enemyPartyB, 3, "pair: B fields three of four")
  eq(stand and stand.enemyPartyB[1].species, 16, "pair: B's own lead")
  eq(stand and stand.trainerIdB, 327, "pair: B's id")
  eq(stand and stand.trainerB.name, "GARY", "pair: B's record")
  eq(stand and stand.defeatTextB, "B\flost", "pair: B's defeat line")
  eq(stand and stand.endBattleText, "A lost", "pair: A's")
  eq(stand and stand.double, true, "pair: a double")
  eq(listOf(hooked), "328,327", "pair: each party through the trainer.party hook with its own id")
  eq(select(2, CoopField.trainerStand3(FakeTrainers.foeFromId(326),
    { trainerId = 326, trainerIdB = 4444, twoOpponents = true }, { game = GAME, solo = true })),
    "no second trainer", "pair: a second trainer the cart has no row for is the cart's")
end

-- Steven: the partner's three lifted out, and put back on a hand-back
do
  newGame({ version = "emerald" })
  local p1, p2 = builtMon(4, 30, { personality = 1 }), builtMon(16, 30, { personality = 2 })
  local s1, s2, s3 = builtMon(151, 42, { stevenPartner = true }), builtMon(29, 43, { stevenPartner = true }),
    builtMon(5, 44, { stevenPartner = true })
  SESSION.party = { p1, p2, s1, s2, s3 }
  local started
  local stand = CoopField.trainerStand3(FakeTrainers.foeFromId(326), {
    trainerId = 326, trainerIdB = 327, twoOpponents = true, partner = true, playerHalf = 2,
    partnerTrainerId = 900, partnerBackPic = "steven", trainerItems = { 0, 0, 0, 0 },
    scriptedLoss = true, done = function() end },
    { game = GAME, solo = true, fightAlone = function() started = #SESSION.party end })
  eq(stand and stand.kind3, "partner", "Steven: the kind")
  eq(stand and stand.partner, true, "Steven: a partner fight")
  eq(stand and stand.playerHalf, 2, "Steven: where the player's half ends")
  eq(stand and stand.partnerTrainerId, 900, "Steven: his trainer id")
  eq(stand and stand.partnerBackPic, "steven", "Steven: his back pic")
  eq(stand and stand.partnerTrainer and stand.partnerTrainer.name, "STEVEN", "Steven: his record")
  eq(stand and stand.scriptedLoss, true, "Steven: a loss is the script's")
  eq(stand and stand.partnerParty and #stand.partnerParty, 3, "Steven: his three ride on the stand-in")
  eq(stand and stand.partnerParty and stand.partnerParty[1], s1, "Steven: ...as the engine built them")
  eq(#SESSION.party, 2, "Steven: the player's party is the player's alone")
  eq(SESSION.party[2], p2, "Steven: ...in its own order")
  eq(stand and stand.trainerIdB, 327, "Steven: the two trainers he fights beside you")
  stand:fightAlone()
  eq(started, 5, "Steven: handed back, the cart's start finds his three where it put them")
  eq(SESSION.party[3], s1, "Steven: ...after the player's half")
  eq(SESSION.party[5], s3, "Steven: ...in order")
  stand:fightAlone()
  eq(#SESSION.party, 5, "Steven: once")
end

-- ------------------------------------------------------------------
-- 5. the start bookkeeping each kind replays (pret battle_setup.c)
-- ------------------------------------------------------------------

do
  newGame({ version = "emerald" })
  local function begun(stand)
    rec = {}
    stand:begin3()
    return recorded("rematchTrainer"), recorded("rematchWild"),
      recorded("rse:tv.incrementDailyWildBattles")
  end
  local function w(opts, enc)
    return CoopField.wildStand3(enc or { species = 16, level = 3 }, { game = GAME, solo = true }, opts)
  end
  local function tr(opts, foe)
    return CoopField.trainerStand3(foe or FakeTrainers.foeFromId(326), opts, { game = GAME, solo = true })
  end
  local rt, rw, tv = begun(w(nil))
  eq(rw .. tv .. rt, "110", "a plain wild: the rematch clock and the TV tally")
  rt, rw, tv = begun(w({ wild = true, legendary = true }))
  eq(rw .. tv, "11", "a legend: the same (BattleSetup_StartLegendaryBattle)")
  rt, rw, tv = begun(w({ wild = true, safari = true }))
  eq(rw .. tv, "00", "a Safari wild: neither (DoSafariBattle)")
  rt, rw, tv = begun(w({ wild = true, tutorialKind = "wally" }))
  eq(rw .. tv, "00", "Wally's lesson: neither (StartWallyTutorialBattle)")
  rt, rw, tv = begun(w({ wild = true, firstBattleKind = "birch" }))
  eq(rw .. tv, "11", "Birch's rescue: both (CB2_StartFirstBattle)")
  rt = begun(tr({ trainerId = 326 }))
  eq(rt, 1, "a trainer ticks the clock (DoTrainerBattle)")
  rt = begun(tr({ trainerId = 326, trainerIdB = 327, twoOpponents = true, double = true }))
  eq(rt, 1, "two trainers too")
  rt = begun(tr({ trainerHill = true }, { party = { builtMon(16, 20) }, trainerName = "X" }))
  eq(rt, 1, "a Trainer Hill trainer too (DoBattlePyramidTrainerHillBattle)")
  rt = begun(tr({ frontier = true, palace = true }, { party = { builtMon(16, 20) }, trainerName = "X" }))
  eq(rt, 0, "a Frontier hall never (DoSpecialTrainerBattle)")
  SESSION.party = { builtMon(4, 30), builtMon(151, 40) }
  rt = begun(tr({ trainerId = 326, trainerIdB = 327, twoOpponents = true, partner = true,
                  playerHalf = 1, partnerTrainerId = 900 }))
  eq(rt, 0, "nor Steven's (SPECIAL_BATTLE_STEVEN)")
  eq(recorded("league"), 1, "the league friendship pass still runs (it asks the class)")
  -- Battle._nextFacility: taken when the mod's fight begins, back on a hand-back
  local fac = { rules = "arena" }
  FakeBattle._nextFacility = fac
  local arena = CoopField.trainerStand3({ party = { builtMon(16, 50) }, trainerName = "X" },
    { frontier = true, arena = true }, { game = GAME, solo = true, fightAlone = function()
      note("handedFacility", FakeBattle._nextFacility)
    end })
  arena:begin3()
  eq(FakeBattle._nextFacility, nil, "the hall's rules object is taken as the mod's fight begins")
  arena:fightAlone()
  eq(lastOf("handedFacility") and lastOf("handedFacility")[1], fac,
     "and is back on the engine before the cart's own start runs")
end

-- ------------------------------------------------------------------
-- 6. the BattleBridge.start wrap with each listener
-- ------------------------------------------------------------------

do
  newGame({ version = "emerald" })
  local original = FakeBB.start
  local want, decision, taken = true, false, {}
  local handler = {
    wants = function() return want end,
    skipWild = function() return false end,
    take = function(stand, foe, opts, kind)
      taken[#taken + 1] = { stand = stand, foe = foe, opts = opts, kind = kind,
                            party = #SESSION.party }
      return decision
    end,
  }
  eq(CoopField.installStart3(handler), true, "the wrap installs")
  -- only co-op listening: a legend is the cart's, never offered
  FakeBB.startWild("ENGINE_MOD", GAME, { species = 151, level = 50 }, { legendary = true })
  eq(#taken, 0, "co-op alone: a legend is never offered")
  eq(recorded("engineStart"), 1, "...and the cart fights it")
  -- SOLO BATTLES on: offered, with its kind and why co-op may not have it
  want = "solo"
  FakeBB.startWild("ENGINE_MOD", GAME, { species = 151, level = 50 }, { legendary = true })
  eq(taken[1] and taken[1].stand.kind3, "legendary", "SOLO BATTLES on: a legend is offered as one")
  eq(taken[1] and taken[1].stand.coopRefused3, "legendary", "...marked for solo alone")
  eq(recorded("engineStart"), 2, "declined, the cart fights it")
  -- a declined partner: the cart's start finds the party it built
  SESSION.party = { builtMon(4, 30), builtMon(151, 42), builtMon(29, 43), builtMon(5, 44) }
  taken = {}
  FakeBB.start("ENGINE_MOD", GAME, FakeTrainers.foeFromId(326), {
    trainerId = 326, trainerIdB = 327, twoOpponents = true, partner = true, playerHalf = 1,
    partnerTrainerId = 900, done = function() end })
  eq(taken[1] and taken[1].party, 1, "Steven offered: the taker sees the player's half alone")
  eq(lastOf("engineStart") and lastOf("engineStart")[3], 4,
     "declined: the cart's start sees all four again")
  -- a taker that throws: the same, and the cart's start still runs
  local throwing = handler.take
  handler.take = function() error("boom") end
  FakeBB.start("ENGINE_MOD", GAME, FakeTrainers.foeFromId(326), {
    trainerId = 326, trainerIdB = 327, twoOpponents = true, partner = true, playerHalf = 1,
    partnerTrainerId = 900, done = function() end })
  eq(lastOf("engineStart") and lastOf("engineStart")[3], 4,
     "a taker that throws: the party is whole for the cart's own start")
  handler.take = throwing
  -- what stays on the cart is never offered, whoever listens
  taken = {}
  FakeBB.start("ENGINE_MOD", GAME, FakeTrainers.foeFromId(326), { trainerId = 326, towerLinkMulti = true })
  eq(#taken, 0, "a link multi is never offered")
  eq(CoopField.restoreStart3(), true, "the wrap comes off")
  eq(FakeBB.start, original, "the engine's own start is back")
  rawset(FakeBB, "__rby_mmo_start", nil)
  rawset(FakeBB, "__rby_mmo_start:live", nil)
end

-- ------------------------------------------------------------------
-- 7. the TEACHY TV wrap
-- ------------------------------------------------------------------

do
  newGame()
  local Gen3 = need("Gen3")
  local original = FakePokedude.startTeachyTvBattle
  local want, decision, taken = false, true, {}
  -- What the taker finds when it is asked (the fight's screen would go onto
  -- the stack from here): the stack, the bag menu, the session's party.
  local atTake = {}
  local handler = {
    wants = function(kind) taken.asked = kind; return want end,
    take = function(stand)
      taken[#taken + 1] = stand
      atTake[#atTake + 1] = { depth = Stack.depth(), tv = Stack.has("teachy_tv"),
                              bagOpen = package.loaded["src.ui.game3.bag_menu"].open,
                              party = SESSION.party }
      return decision
    end,
  }
  -- The TEACHY TV on the stack and the bag it was opened from, open.
  local savedBagMenu = package.loaded["src.ui.game3.bag_menu"]
  local BagMenu = { open = true }
  package.loaded["src.ui.game3.bag_menu"] = BagMenu
  local function teachyUp()
    if not Stack.has("teachy_tv") then Stack.push("teachy_tv", {}, { hideBelow = true }) end
    BagMenu.open = true
  end
  teachyUp()
  local songs = {}
  local realSong = Gen3.audio.playSong
  Gen3.audio.playSong = function(name) songs[#songs + 1] = name; return true end
  local playerParty = { builtMon(4, 20, {}) }
  SESSION.party = playerParty
  eq(CoopField.installPokedude3(handler), true, "the TEACHY TV wrap installs")
  check(FakePokedude.startTeachyTvBattle ~= original, "the slot holds the wrapper")
  eq(rawget(FakePokedude, "__rby_mmo_pokedude"), original, "and the original is kept on the module")
  eq(CoopField.installPokedude3(handler), true, "installing again is a no-op")
  eq(rawget(FakePokedude, "__rby_mmo_pokedude"), original, "and never wraps the wrapper")
  eq(CoopField.originalPokedude3(), original, "the original is reachable")
  local codes = {}
  local tvOpts = { onDone = function(code) codes[#codes + 1] = code end }
  -- SOLO BATTLES off: the TEACHY TV plays its own
  eq(FakePokedude.startTeachyTvBattle(SESSION, 2, tvOpts), true, "solo off: the demonstration starts")
  eq(recorded("pokedudeStart"), 1, "...the cart's own")
  eq(#taken, 0, "...nobody offered it")
  eq(taken.asked, "tutorial", "(the listener was asked about a tutorial)")
  eq(#songs, 0, "solo off: no music of ours")
  eq(recorded("transition"), 0, "solo off: no transition of ours")
  -- SOLO BATTLES on: a tutorial stand-in, taken -- after the engine's own
  -- start's music and transition (battle/pokedude.lua startTeachyTvBattle;
  -- pret teachy_tv.c:1172 TeachyTvPrepBattle)
  want = true
  FakeTransition.hold = true
  eq(FakePokedude.startTeachyTvBattle(SESSION, 3, tvOpts), true, "solo on: the start answers as started")
  eq(table.concat(songs, ","), "MUS_VS_WILD", "solo on: the wild battle music (PlayMapChosenOrBattleBGM)")
  local tr = lastOf("transition")
  eq(tr and tr[1], 8, "solo on: the transition the cart picks for the program (SLICE)")
  eq(tr and tr[2] and tr[2].overUi, true, "solo on: ...over the TEACHY TV")
  eq(#taken, 0, "solo on: nothing offered until the transition has played")
  eq(SESSION.party, playerParty, "solo on: ...the player's party still the session's")
  check(Stack.has("teachy_tv"), "solo on: ...and the TEACHY TV still on the stack")
  FakeTransition.hold = false
  FakeTransition.release()
  eq(recorded("pokedudeStart"), 1, "...and the cart's own did not run")
  local stand = taken[1]
  local at = atTake[1]
  eq(at and at.depth, 0, "taken: the fight's screen goes onto an empty stack (TeachyTvFree)")
  eq(at and at.tv, false, "taken: ...the TEACHY TV lifted off")
  eq(at and at.bagOpen, false, "taken: ...the bag menu hidden")
  eq(at and at.party, stand and stand.playerParty, "taken: his party is the session's (InitPokedudePartyAndOpponent)")
  eq(stand and stand.kind3, "tutorial", "POKe DUDE: a tutorial")
  eq(stand and stand.tutorial3, "pokedude", "POKe DUDE: ...the POKe DUDE's")
  eq(stand and stand.pokedudeScript, 3, "POKe DUDE: the demonstration's number")
  eq(stand and stand.coopRefused3, "pokedude", "POKe DUDE: never co-op's")
  eq(stand and stand.playerParty and stand.playerParty[1].species, 16,
     "POKe DUDE: his own monsters on the player's side")
  eq(stand and stand.enemyParty[1].species, 29, "POKe DUDE: the demonstration's foe")
  eq(stand and stand.encounter.pokedude, true, "POKe DUDE: the encounter says so")
  eq(stand and stand.opts.pdScriptNum, 3, "POKe DUDE: the opts Battle.start would have had")
  eq(stand and stand.teachyOpts, tvOpts, "POKe DUDE: the TEACHY TV's own opts ride along")
  local onDoneSaw = nil
  local realOnDone = tvOpts.onDone
  tvOpts.onDone = function(code)
    onDoneSaw = { party = SESSION.party, tv = Stack.has("teachy_tv"), bagOpen = BagMenu.open }
    return realOnDone(code)
  end
  stand.doneFn("caught")
  tvOpts.onDone = realOnDone
  eq(codes[1], 7, "POKe DUDE: a catch answers B_OUTCOME_CAUGHT")
  eq(recorded("restoreBag"), 1, "POKe DUDE: ...after the player's bag is put back")
  eq(onDoneSaw and onDoneSaw.party, playerParty, "POKe DUDE: ...and the player's party (LoadPlayerParty first)")
  eq(onDoneSaw and onDoneSaw.tv, true, "POKe DUDE: ...and the TEACHY TV back on the stack")
  eq(onDoneSaw and onDoneSaw.bagOpen, true, "POKe DUDE: ...and the bag menu")
  eq(stand.partyBorrow3, nil, "POKe DUDE: nothing left borrowed")
  eq(CoopField.pokedudeCode3(FakePokedude, "draw"), 3, "a draw is DREW")
  eq(CoopField.pokedudeCode3(FakePokedude, "lose"), 2, "a loss is LOST")
  eq(CoopField.pokedudeCode3(FakePokedude, "run"), 4, "a run is RAN")
  eq(CoopField.pokedudeCode3(FakePokedude, "win"), 1, "a win is WON")
  -- handed back: the original, with the TEACHY TV's own arguments, once
  stand:fightAlone()
  local back = lastOf("pokedudeStart")
  eq(recorded("pokedudeStart"), 2, "handed back: the cart's demonstration starts")
  eq(back and back[1], SESSION, "...for the same session")
  eq(back and back[2], 3, "...the same demonstration")
  eq(back and back[3], tvOpts, "...with the TEACHY TV's own opts")
  eq(back and back[4] and back[4].party, playerParty, "...and the player's party in place")
  stand:fightAlone()
  eq(recorded("pokedudeStart"), 2, "once")
  -- declined: the original runs, with everything given back first
  teachyUp()
  decision = false
  FakePokedude.startTeachyTvBattle(SESSION, 0, { onDone = tvOpts.onDone })
  local sawAtFallback = lastOf("pokedudeStart") and lastOf("pokedudeStart")[4]
  eq(recorded("pokedudeStart"), 3, "declined: the cart's own demonstration")
  eq(lastOf("transition") and lastOf("transition")[1], 9,
     "declined: the battle basics' transition (WHITE_BARS_FADE) played first")
  eq(sawAtFallback and sawAtFallback.party, playerParty, "declined: ...with the player's party back")
  eq(sawAtFallback and sawAtFallback.tv, true, "declined: ...the TEACHY TV back on the stack")
  eq(sawAtFallback and sawAtFallback.bagOpen, true, "declined: ...and the bag menu")
  -- the TEACHY TV's own transition, when it names one
  decision = true
  FakePokedude.startTeachyTvBattle(SESSION, 1, { onDone = tvOpts.onDone, transition = 42 })
  eq(lastOf("transition") and lastOf("transition")[1], 42, "the TEACHY TV's own transition is played")
  local mid = taken[#taken]
  eq(SESSION.party, mid.playerParty, "mid-fight: his party in")
  local startsBefore = recorded("pokedudeStart")
  mid:fightAlone()
  local cart = lastOf("pokedudeStart")
  eq(recorded("pokedudeStart"), startsBefore + 1, "mid-fight hand-back: the cart's demonstration starts")
  eq(cart and cart[4] and cart[4].party, playerParty, "mid-fight hand-back: ...with the player's party back")
  eq(cart and cart[4] and cart[4].tv, true, "mid-fight hand-back: ...the TEACHY TV back on the stack")
  eq(cart and cart[4] and cart[4].bagOpen, true, "mid-fight hand-back: ...and the bag menu")
  eq(SESSION.party, playerParty, "mid-fight hand-back: the player's party stays")
  teachyUp()
  -- a battle already running: the engine's own refusal answers
  battleActive = true
  local before = #taken
  FakePokedude.startTeachyTvBattle(SESSION, 1, tvOpts)
  eq(#taken, before, "a battle already up: not offered")
  battleActive = false
  -- another instance of the mod loaded: vanilla
  local find = stubMod.find
  stubMod.find = function() return { exports = {} } end
  FakePokedude.startTeachyTvBattle(SESSION, 1, tvOpts)
  eq(#taken, before, "a wrapper left by an unloaded instance takes nothing")
  eq(recorded("pokedudeStart"), 6, "...and the cart's demonstration runs")
  stubMod.find = find
  eq(CoopField.restorePokedude3(), true, "the wrap comes off")
  eq(FakePokedude.startTeachyTvBattle, original, "the engine's own function is back")
  eq(rawget(FakePokedude, "__rby_mmo_pokedude"), nil, "with nothing left on the module")
  -- another mod's wrapper on top of ours
  eq(CoopField.installPokedude3(handler), true, "the wrap goes back in")
  local ours = FakePokedude.startTeachyTvBattle
  local otherCalls = 0
  local other = function(...) otherCalls = otherCalls + 1; return ours(...) end
  FakePokedude.startTeachyTvBattle = other
  before = #taken
  FakePokedude.startTeachyTvBattle(SESSION, 0, tvOpts)
  eq(otherCalls, 1, "the other mod still sees every demonstration")
  eq(#taken, before + 1, "and ours under it still diverts")
  eq(CoopField.restorePokedude3(), true, "taking ours off under somebody else's")
  eq(FakePokedude.startTeachyTvBattle, other, "leaves their wrapper where it is")
  local starts = recorded("pokedudeStart")
  FakePokedude.startTeachyTvBattle(SESSION, 0, tvOpts)
  eq(#taken, before + 1, "ours, retired in place, takes nothing")
  eq(recorded("pokedudeStart"), starts + 1, "and the cart's demonstration runs")
  FakePokedude.startTeachyTvBattle = original
  rawset(FakePokedude, "__rby_mmo_pokedude", nil)
  rawset(FakePokedude, "__rby_mmo_pokedude:live", nil)
  Gen3.audio.playSong = realSong
  package.loaded["src.ui.game3.bag_menu"] = savedBagMenu
end

-- ------------------------------------------------------------------
-- 7b. what a fight borrows from the save (src/Borrow3.lua), and the TEACHY
--     TV's borrows through it
-- ------------------------------------------------------------------

do
  newGame()
  local Gen3 = need("Gen3")
  local Borrow3 = need("Borrow3")
  local gave = {}
  local function giver(name) return function() gave[#gave + 1] = name end end
  -- hold / release
  eq(Borrow3.hold(SESSION, "t.a", giver("a"), function() return true end, "party"), true,
     "ledger: a borrow is held")
  eq(Borrow3.held(SESSION, "t.a"), true, "ledger: ...and says so")
  check(type(rawget(SESSION, Borrow3.KEY)) == "table", "ledger: kept on the session itself")
  eq(Borrow3.release(SESSION, "t.a"), true, "ledger: the owner's own return releases it")
  eq(Borrow3.held(SESSION, "t.a"), false, "ledger: ...forgotten")
  eq(rawget(SESSION, Borrow3.KEY), nil, "ledger: an empty ledger leaves the session")
  eq(#gave, 0, "ledger: a release gives nothing back (the owner already did)")
  eq(Borrow3.release(SESSION, "t.a"), false, "ledger: releasing twice is a no")
  -- settle: a dead borrow and one an earlier load made go back; a live one stays
  local liveNow = true
  Borrow3.hold(SESSION, "t.dead", giver("dead"), function() return false end)
  Borrow3.hold(SESSION, "t.live", giver("live"), function() return liveNow end, "bag")
  Borrow3.hold(SESSION, "t.throws", giver("throws"), function() error("boom") end)
  -- An earlier load of the mod (F5): the same file, a module graph of its own.
  local OldBorrow3 = newNeed(stubMod)("Borrow3")
  OldBorrow3.hold(SESSION, "t.old", giver("old"), function() return true end)
  local restored, live, labels = Borrow3.settle(SESSION)
  eq(restored, 3, "settle: the dead, the throwing and the old-epoch borrows go back")
  eq(listOf(gave), "dead,old,throws", "settle: ...each through its own giveBack")
  eq(listOf(live), "t.live", "settle: the one whose fight is running stays")
  eq(listOf(labels), "bag", "settle: ...named by its label")
  -- the save.write link
  local wrote = 0
  local function write(game) wrote = wrote + 1; check(game == GAME, "save.write: the game is passed on"); return true end
  local warnsBefore = #warns
  eq(Borrow3.beforeSave(write, GAME), false, "save.write: a live borrow vetoes the write")
  eq(wrote, 0, "save.write: ...nothing is written")
  check(#warns > warnsBefore and warns[#warns]:find("your bag", 1, true) ~= nil,
        "save.write: ...and the player is told what the battle holds")
  liveNow = false
  eq(Borrow3.beforeSave(write, GAME), true, "save.write: once that fight is over, the write goes on")
  eq(wrote, 1, "save.write: ...once")
  eq(gave[#gave], "live", "save.write: ...after the borrow is given back")
  eq(rawget(SESSION, Borrow3.KEY), nil, "save.write: nothing left on the session")
  -- no session (a title screen, Gen 1): straight through
  local savedSession = SESSION
  SESSION, stubMod.game = nil, nil
  eq(Gen3.session(), nil, "no session: (none)")
  eq(Borrow3.beforeSave(write, GAME), true, "no session: save.write passes straight through")
  eq(wrote, 2, "no session: ...and writes")
  SESSION, stubMod.game = savedSession, GAME
  -- install: one save.write link, through the facade
  local wrapped = {}
  stubMod.hooks = { wrap = function(_, name, fn) wrapped[#wrapped + 1] = { name, fn } end }
  eq(Borrow3.install(), true, "install: wraps through mod.hooks")
  eq(wrapped[1] and wrapped[1][1], "save.write", "install: ...the save.write hook")
  eq(wrapped[1] and wrapped[1][2], Borrow3.beforeSave, "install: ...with beforeSave")
  stubMod.hooks = nil

  -- Gen3.loaded: package.loaded only, behind Gen3.engine's gate
  local savedBagMenu = package.loaded["src.ui.game3.bag_menu"]
  local BagMenu = { open = true }
  package.loaded["src.ui.game3.bag_menu"] = BagMenu
  eq(Gen3.loaded("src.ui.game3.bag_menu"), BagMenu, "Gen3.loaded: a loaded game3 module")
  eq(Gen3.loaded("src.ui.game3.never_loaded_rby"), nil, "Gen3.loaded: one nobody loaded is nil")
  eq(package.loaded["src.ui.game3.never_loaded_rby"], nil, "Gen3.loaded: ...and is not loaded by asking")
  eq(Gen3.loaded("src.core.Game"), nil, "Gen3.loaded: never a module outside the game3 families")
  -- Inside the loader's sandbox `package` is LegacyCompat's shim, whose
  -- `loaded` is its own empty table: the ask goes through engine's require,
  -- which hands back the engine's cached module.
  do
    local realPackage = package
    _G.package = { path = "", cpath = "", preload = {}, loaded = {}, loaders = {} }
    local ok, menu = pcall(Gen3.loaded, "src.ui.game3.bag_menu")
    local okGame, game = pcall(Gen3.loaded, "src.core.Game")
    _G.package = realPackage
    check(ok and type(menu) == "table", "Gen3.loaded (sandboxed): the bag menu is still found")
    eq(okGame and game, nil, "Gen3.loaded (sandboxed): ...and the game3-only gate still holds")
  end

  -- ------- the TEACHY TV through the ledger
  local songs = {}
  local realSong = Gen3.audio.playSong
  Gen3.audio.playSong = function(name) songs[#songs + 1] = name; return true end
  local Gen3Ui = need("Gen3Ui")
  local decision = true
  local screens = {}
  local handler = {
    wants = function() return true end,
    -- The taker's screen goes on the (lifted) stack, as solo's does.
    take = function(stand)
      if not decision then return false end
      local screen = { draw = function() end }
      screens[stand] = screen
      Gen3Ui.pushScreen(GAME, "RbyMmoTeachyFight", screen)
      return true
    end,
    holds = function(stand) return screens[stand] end,
  }
  local function teachyUp()
    if not Stack.has("teachy_tv") then Stack.push("teachy_tv", {}, { hideBelow = true }) end
    BagMenu.open = true
  end
  local playerParty = { builtMon(4, 20, {}) }
  SESSION.party = playerParty
  teachyUp()
  eq(CoopField.installPokedude3(handler), true, "TEACHY ledger: the wrap installs")
  local codes = {}
  local tvOpts = { onDone = function(code) codes[#codes + 1] = code end }
  FakePokedude.startTeachyTvBattle(SESSION, 2, tvOpts)
  local stand = next(screens)
  check(stand ~= nil, "TEACHY ledger: the demonstration is taken")
  eq(SESSION.party, stand and stand.playerParty, "TEACHY ledger: his party is the session's")
  eq(Borrow3.held(SESSION, CoopField.BORROW_PARTY3), true, "TEACHY ledger: the party swap is recorded")
  eq(Borrow3.held(SESSION, CoopField.BORROW_BAG3), true, "TEACHY ledger: ...and the bag swap")
  eq(stand and stand:fightLive3(), true, "TEACHY ledger: the fight is live while its screen is up")
  wrote = 0
  eq(Borrow3.beforeSave(write, GAME), false, "TEACHY ledger: no save mid-demonstration")
  eq(SESSION.party, stand and stand.playerParty, "TEACHY ledger: ...and his party stays in for the fight")
  -- The fight's screen throws and is popped: no `done`, no hand-back.
  Gen3Ui.pop(GAME, screens[stand])
  eq(stand and stand:fightLive3(), false, "TEACHY ledger: a popped screen is no fight")
  eq(SESSION.party, stand and stand.playerParty, "TEACHY ledger: ...the swap is still in the session")
  local bagBacks = recorded("restoreBag")
  eq(Borrow3.beforeSave(write, GAME), true, "TEACHY ledger: the next save goes on")
  eq(wrote, 1, "TEACHY ledger: ...and is written")
  eq(SESSION.party, playerParty, "TEACHY ledger: ...with the player's own party back first")
  eq(recorded("restoreBag"), bagBacks + 1, "TEACHY ledger: ...and the player's bag (RestorePlayerBag)")
  eq(SESSION.teachyBagBackup, nil, "TEACHY ledger: ...no backup left over")
  eq(Borrow3.held(SESSION, CoopField.BORROW_PARTY3), false, "TEACHY ledger: nothing held")
  eq(stand and stand.teachyCover3, nil, "TEACHY ledger: the stale cover is forgotten, not restored")
  check(not Stack.has("teachy_tv"), "TEACHY ledger: ...no dead TEACHY TV put back over the field")
  -- A late end for that stand gives nothing back twice.
  stand.doneFn("win")
  eq(SESSION.party, playerParty, "TEACHY ledger: a late done leaves the player's party")

  -- A demonstration that died with no save since: the next one borrows from
  -- the player's own party, not from the dead one's swap.
  newGame()
  SESSION.party = playerParty
  screens = {}
  teachyUp()
  FakePokedude.startTeachyTvBattle(SESSION, 2, tvOpts)
  local dead = next(screens)
  Gen3Ui.pop(GAME, screens[dead])
  screens = {}
  teachyUp()
  FakePokedude.startTeachyTvBattle(SESSION, 3, tvOpts)
  local second = next(screens)
  check(second ~= nil and second ~= dead, "TEACHY ledger: a second demonstration is taken")
  eq(second and second.partyBorrow3 and second.partyBorrow3.party, playerParty,
     "TEACHY ledger: ...borrowing the player's own party (the dead swap was settled first)")
  second.doneFn("win")
  eq(SESSION.party, playerParty, "TEACHY ledger: ...and its end gives the player's party back")
  eq(rawget(SESSION, Borrow3.KEY), nil, "TEACHY ledger: ...with nothing left in the ledger")

  -- Declined after the intro: the cart's battle alone, no second intro.
  newGame()
  SESSION.party = playerParty
  teachyUp()
  songs = {}
  decision = false
  FakePokedude.startTeachyTvBattle(SESSION, 1, tvOpts)
  local fell = lastOf("pokedudeStart")
  eq(recorded("pokedudeStart"), 1, "declined: the cart's demonstration starts")
  eq(fell and fell[3] and fell[3].headless, true, "declined: ...asked for its battle alone (headless)")
  eq(fell and fell[3] and fell[3].onDone, tvOpts.onDone, "declined: ...with the TEACHY TV's onDone")
  eq(tvOpts.headless, nil, "declined: the TEACHY TV's own opts are not touched")
  eq(#songs, 1, "declined: the battle music played once")
  eq(recorded("transition"), 1, "declined: the transition played once")
  eq(fell and fell[4] and fell[4].party, playerParty, "declined: ...with the player's party back")
  eq(rawget(SESSION, Borrow3.KEY), nil, "declined: nothing left in the ledger")

  -- A bag swap that throws after BackUpPlayerBag: the player's bag is put
  -- back, and the cart's demonstration runs (once, headless).
  newGame()
  SESSION.party = playerParty
  teachyUp()
  decision = true
  screens = {}
  local realInit = FakeTeachyTv.initPokedudeBag
  FakeTeachyTv.initPokedudeBag = function(session)
    session.teachyBagBackup = true
    error("half a swap")
  end
  FakePokedude.startTeachyTvBattle(SESSION, 1, tvOpts)
  FakeTeachyTv.initPokedudeBag = realInit
  eq(next(screens), nil, "half a bag swap: not offered")
  eq(recorded("restoreBag"), 1, "half a bag swap: the player's bag is restored")
  eq(SESSION.teachyBagBackup, nil, "half a bag swap: ...no backup left")
  eq(recorded("pokedudeStart"), 1, "half a bag swap: the cart's demonstration runs")
  eq(lastOf("pokedudeStart")[3].headless, true, "half a bag swap: ...its battle alone")
  eq(SESSION.party, playerParty, "half a bag swap: the player's party stays")

  eq(CoopField.restorePokedude3(), true, "TEACHY ledger: the wrap comes off")
  FakePokedude.startTeachyTvBattle = rawget(FakePokedude, "__rby_mmo_pokedude") or FakePokedude.startTeachyTvBattle
  rawset(FakePokedude, "__rby_mmo_pokedude", nil)
  rawset(FakePokedude, "__rby_mmo_pokedude:live", nil)
  Gen3.audio.playSong = realSong
  package.loaded["src.ui.game3.bag_menu"] = savedBagMenu
end

-- ------------------------------------------------------------------
-- 7c. the bag the cart's own start backs up, and the tutorials' pockets
--     beside the POKe DUDE's on one ledger
-- ------------------------------------------------------------------

do
  newGame()
  local Gen3 = need("Gen3")
  local Gen3Ui = need("Gen3Ui")
  local Borrow3 = need("Borrow3")
  local Tut = need("Solo3/Tutorial")
  local songs = {}
  local realSong = Gen3.audio.playSong
  Gen3.audio.playSong = function(name) songs[#songs + 1] = name; return true end
  -- The engine's bag swap as it really is (teachy_tv.lua backUpPlayerBag /
  -- restorePlayerBag): the pockets go into a backup *written over whatever
  -- backup is there*, and come back out of it.
  local realInit, realRestore = FakeTeachyTv.initPokedudeBag, FakeTeachyTv.restorePlayerBag
  FakeTeachyTv.initPokedudeBag = function(session, scriptId)
    note("initBag", scriptId)
    session.teachyBagBackup = { ITEMS = session.bag.pockets.ITEMS }
    session.bag.pockets.ITEMS = { { id = 13, qty = 1, dude = true } }
    return 1
  end
  FakeTeachyTv.restorePlayerBag = function(session)
    note("restoreBag")
    local backup = type(session) == "table" and session.teachyBagBackup
    if not backup then return false end
    session.bag.pockets.ITEMS = backup.ITEMS
    session.teachyBagBackup = nil
    return true
  end
  -- The cart's own start with SOLO BATTLES off (battle/pokedude.lua
  -- startTeachyTvBattle): InitPokedudeBag, its battle, finish_battle.
  local fakeStart = FakePokedude.startTeachyTvBattle
  local sawItems
  FakePokedude.startTeachyTvBattle = function(session, scriptId)
    note("pokedudeStart", session, scriptId)
    FakeTeachyTv.initPokedudeBag(session, scriptId)
    sawItems = session.teachyBagBackup.ITEMS
    FakeTeachyTv.restorePlayerBag(session)
    return true
  end
  local BagMenu = { open = true }
  local savedBagMenu = package.loaded["src.ui.game3.bag_menu"]
  package.loaded["src.ui.game3.bag_menu"] = BagMenu
  local function teachyUp()
    if not Stack.has("teachy_tv") then Stack.push("teachy_tv", {}, { hideBelow = true }) end
    BagMenu.open = true
  end
  local want = true
  local screens = {}
  local handler = {
    wants = function() return want end,
    take = function(stand)
      local screen = { draw = function() end }
      screens[stand] = screen
      Gen3Ui.pushScreen(GAME, "RbyMmoTeachyFight", screen)
      return true
    end,
    holds = function(stand) return screens[stand] end,
  }
  local playerParty = { builtMon(4, 20, {}) }
  local function playerBag()
    local bag = { items = {}, pockets = {
      ITEMS = { { id = 2, qty = 3 } }, KEY_ITEMS = { { id = 259, qty = 1 } },
      POKE_BALLS = { { id = 4, qty = 5 } } } }
    SESSION.bag = bag
    return bag.pockets.ITEMS, bag.pockets.KEY_ITEMS, bag.pockets.POKE_BALLS
  end
  local function index(kind)
    for i, r in ipairs(rec) do if r.kind == kind then return i end end
    return nil
  end
  check(CoopField.installPokedude3(handler), "7c: the wrap installs over the cart's start")
  local tvOpts = { onDone = function() end }

  -- A demonstration that died mid-fight, then SOLO BATTLES turned off: the
  -- cart's own start backs the bag up again, so the dead swap is given back
  -- before it runs, not saved as the player's.
  SESSION.party = playerParty
  local myItems = playerBag()
  teachyUp()
  FakePokedude.startTeachyTvBattle(SESSION, 2, tvOpts)
  local dead = next(screens)
  check(dead ~= nil, "solo off after a dead demonstration: the first one was taken")
  Gen3Ui.pop(GAME, screens[dead])
  eq(Borrow3.held(SESSION, CoopField.BORROW_BAG3), true, "...its bag swap is left on the ledger")
  check(SESSION.bag.pockets.ITEMS ~= myItems, "...with the POKe DUDE's pocket in the bag")
  want, screens, rec = false, {}, {}
  teachyUp()
  FakePokedude.startTeachyTvBattle(SESSION, 3, tvOpts)
  eq(recorded("pokedudeStart"), 1, "solo off after a dead demonstration: the cart's own starts")
  check(index("restoreBag") ~= nil and index("restoreBag") < index("pokedudeStart"),
        "...after the dead swap was given back")
  eq(sawItems, myItems, "...so the cart backs up the player's own pocket")
  eq(SESSION.bag.pockets.ITEMS, myItems, "...and the player's pocket is the bag's after it")
  eq(SESSION.party, playerParty, "...with the player's party back too")
  eq(rawget(SESSION, Borrow3.KEY), nil, "...and nothing left on the ledger")

  -- The tutorials' pockets (src/Solo3/Tutorial.lua, M.BAG_BORROW) on the
  -- same ledger as the POKe DUDE's party and bag: the save.write link
  -- refuses while either fight is up, names what each holds, and gives each
  -- back as its fight goes -- the innermost first, as the swaps were made.
  local infos = {}
  local realInfo = stubMod.log.info
  stubMod.log.info = function(_, fmt, ...)
    local ok, line = pcall(string.format, fmt, ...)
    infos[#infos + 1] = ok and line or tostring(fmt)
  end
  local wrote = 0
  local function write() wrote = wrote + 1; return true end
  local function tutorialOver(onDemo)
    local ctx = { tut3 = { which = "oldMan" }, session = SESSION }
    local screen = { draw = function() end }
    ctx.solo = { gen3 = ctx, fight = screen }
    Gen3Ui.pushScreen(GAME, "RbyMmoTutorialFight", screen)
    check(Tut.borrowBag3(ctx), onDemo .. ": the tutorial's pockets are borrowed")
    return ctx, screen
  end
  local function demonstration(label)
    want, screens = true, {}
    teachyUp()
    FakePokedude.startTeachyTvBattle(SESSION, 2, tvOpts)
    local stand = next(screens)
    check(stand ~= nil, label .. ": the demonstration is taken")
    return stand
  end

  newGame()
  SESSION.party = playerParty
  local items, keys, balls = playerBag()
  local demo = demonstration("both on the ledger")
  local _, tutScreen = tutorialOver("both on the ledger")
  eq(Borrow3.held(SESSION, Tut.BAG_BORROW), true, "both on the ledger: the pockets are recorded")
  eq(Borrow3.held(SESSION, CoopField.BORROW_PARTY3), true, "both on the ledger: ...beside the party")
  local mark = #warns
  eq(Borrow3.beforeSave(write, GAME), false, "both live: the save is refused")
  eq(warns[#warns], "not saving while a battle still holds your bag pockets and bag and party; "
     .. "finish the battle, then save", "both live: ...naming each borrow by its label")
  eq(#warns, mark + 1, "both live: ...once")
  Gen3Ui.pop(GAME, tutScreen)
  infos = {}
  eq(Borrow3.beforeSave(write, GAME), false, "the tutorial's screen gone: still refused")
  eq(warns[#warns], "not saving while a battle still holds your bag and party; finish the "
     .. "battle, then save", "...for the demonstration's party and bag alone")
  eq(infos[#infos], "gave back 1 item(s) a finished battle had borrowed before saving",
     "...after the tutorial's pockets went back")
  eq(SESSION.bag.pockets.KEY_ITEMS, keys, "...the player's KEY ITEMS pocket")
  Gen3Ui.pop(GAME, screens[demo])
  eq(Borrow3.beforeSave(write, GAME), true, "the demonstration's gone too: the save goes on")
  eq(wrote, 1, "...written once")
  eq(infos[#infos], "gave back 2 item(s) a finished battle had borrowed before saving",
     "...after its party and bag went back")
  eq(SESSION.bag.pockets.ITEMS, items, "...the player's ITEMS pocket, not the POKe DUDE's")
  eq(SESSION.bag.pockets.KEY_ITEMS, keys, "...KEY ITEMS")
  eq(SESSION.bag.pockets.POKE_BALLS, balls, "...POKe BALLS")
  eq(SESSION.party, playerParty, "...and the player's party")
  eq(rawget(SESSION, Borrow3.KEY), nil, "...nothing left on the ledger")

  -- Both fights dead before any save: one settle gives all three back.
  newGame()
  SESSION.party = playerParty
  items, keys, balls = playerBag()
  demo = demonstration("both dead")
  _, tutScreen = tutorialOver("both dead")
  Gen3Ui.pop(GAME, tutScreen)
  Gen3Ui.pop(GAME, screens[demo])
  infos, wrote = {}, 0
  eq(Borrow3.beforeSave(write, GAME), true, "both dead: the save goes on")
  eq(infos[#infos], "gave back 3 item(s) a finished battle had borrowed before saving",
     "both dead: ...after the pockets, the bag and the party went back")
  eq(SESSION.bag.pockets.ITEMS, items, "both dead: the player's ITEMS pocket")
  eq(SESSION.bag.pockets.KEY_ITEMS, keys, "both dead: ...KEY ITEMS")
  eq(SESSION.bag.pockets.POKE_BALLS, balls, "both dead: ...POKe BALLS")
  eq(SESSION.party, playerParty, "both dead: ...and the party")
  eq(SESSION.teachyBagBackup, nil, "both dead: no backup left over")

  stubMod.log.info = realInfo
  eq(CoopField.restorePokedude3(), true, "7c: the wrap comes off")
  rawset(FakePokedude, "__rby_mmo_pokedude", nil)
  rawset(FakePokedude, "__rby_mmo_pokedude:live", nil)
  FakePokedude.startTeachyTvBattle = fakeStart
  FakeTeachyTv.initPokedudeBag, FakeTeachyTv.restorePlayerBag = realInit, realRestore
  Gen3.audio.playSong = realSong
  package.loaded["src.ui.game3.bag_menu"] = savedBagMenu
end

-- ------------------------------------------------------------------
-- 8. the client's routing, through the real headless loader
-- ------------------------------------------------------------------

local GameVersion = require("src.core.GameVersion")
local makeRemapFs = dofile(MOD_PATH .. "/tests/mod_remap_fs.lua")

local function loadAs(version)
  GameVersion.set(version)
  local opts = { generation = 3, data = T.sdk.gen3Data() }
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

for _, version in ipairs({ "firered", "emerald" }) do
  newGame({ version = version })
  SESSION.party = { builtMon(4, 10) }
  local run = loadAs(version)
  eq(run.mod and run.mod.state, "loaded", version .. ": the mod loads")
  local game = { generation = 3, phase = "field", session = SESSION, data = run.data }
  run.loader.game = game
  local exports = run.loader.exports and run.loader.exports.rby_mmo
  local ctx = exports and type(exports.players) == "function" and upvalue(exports.players, "ctx")
  check(ctx ~= nil and ctx.solo ~= nil and ctx.coop ~= nil, version .. ": the client's context")
  -- Every solo family read at boot (Client.install -> SoloBattle.loadKinds3,
  -- W3-CORE), before any fight has asked for one.
  local SoloM = ctx and getmetatable(ctx.solo)
  local bootKinds = { "roamer", "legendary", "scripted", "ghost", "facility", "pair", "partner",
                      "firstBattle" }
  -- The Safari family (wave 3) once its file is in the mod folder.
  local safariFile = io.open(MOD_PATH .. "/src/Solo3/Safari.lua", "rb")
  if safariFile then
    safariFile:close()
    bootKinds[#bootKinds + 1] = "safari"
  end
  for _, name in ipairs(bootKinds) do
    check(SoloM and type(SoloM.KINDS3) == "table" and SoloM.KINDS3[name] ~= nil,
          version .. ": the " .. name .. " kind was read at boot")
  end

  -- one field tick puts both wraps on
  local bbOriginal, pdOriginal = FakeBB.start, FakePokedude.startTeachyTvBattle
  run.loader.hooks:call("input.step", function() end, game, 1 / 60)
  check(FakeBB.start ~= bbOriginal, version .. ": the BattleBridge.start wrap is on")
  check(FakePokedude.startTeachyTvBattle ~= pdOriginal, version .. ": the TEACHY TV wrap is on")

  -- a partied, connected player
  ctx.client.transport.isReady = function() return true end
  ctx.party.has = function() return true end
  ctx.coop.wouldTakeWild = function() return true end
  ctx.coop.wantsNpc = function() return true end
  local coopAsked = {}
  ctx.coop.onWildEncounter = function(_, _, stand) coopAsked[#coopAsked + 1] = stand; return false end
  ctx.coop.onTrainerBattle = function(_, _, stand) coopAsked[#coopAsked + 1] = stand; return false end
  local soloGot, soloTakes = {}, true
  ctx.solo.fromGen3Encounter = function(_, g, enc, opts)
    soloGot[#soloGot + 1] = { enc = enc, opts = opts, kind = "wild" }
    return soloTakes
  end
  -- every cover the divert puts up (Stand:push -> the game3 stack)
  local covers = 0
  local stackPush = Stack.push
  Stack.push = function(...) covers = covers + 1; return stackPush(...) end
  ctx.solo.fromGen3Trainer = function(_, g, foe, opts)
    soloGot[#soloGot + 1] = { foe = foe, opts = opts, kind = "trainer" }
    return soloTakes
  end
  local function reset() coopAsked, soloGot, rec, covers = {}, {}, {}, 0 end

  -- SOLO BATTLES on
  run.loader.modOptions.rby_mmo = { solo = true }
  reset()
  FakeBB.start("ENGINE_MOD", game, FakeTrainers.foeFromId(326), { trainerId = 326, done = function() end })
  eq(#coopAsked, 1, version .. ": a plain trainer is offered to co-op first")
  eq(covers, 1, version .. ": ...under the stand-in's cover")
  eq(soloGot[1] and soloGot[1].opts.stand3.kind3, "trainer", version .. ": ...then to solo, as a trainer")
  reset()
  FakeBB.startWild("ENGINE_MOD", game, { species = 151, level = 50 }, { legendary = true, done = function() end })
  eq(#coopAsked, 0, version .. ": a legend is never put to co-op")
  local got = soloGot[1]
  eq(got and got.opts.stand3 and got.opts.stand3.kind3, "legendary", version .. ": solo gets it with its stand-in")
  eq(got and got.opts.stand3.coopRefused3, "legendary", version .. ": ...which says why co-op may not")
  eq(got and got.opts.party, got and got.opts.stand3.enemyParty, version .. ": ...and the monster it built")
  eq(got and got.enc.mon, got and got.opts.party[1], version .. ": ...as the encounter's mon too")
  eq(covers, 0, version .. ": no cover went up for a fight co-op will never wait on")
  eq(recorded("engineStart"), 0, version .. ": the cart's battle never started")
  reset()
  FakeBB.start("ENGINE_MOD", game, { party = { builtMon(16, 50) }, trainerName = "ANNA" },
    { frontier = true, palace = true, frontierTrainer = { class = 44, name = "ANNA", pic = 20 },
      done = function() end })
  eq(#coopAsked, 0, version .. ": a facility trainer is never put to co-op")
  eq(soloGot[1] and soloGot[1].opts.stand3.facility3, "palace", version .. ": solo gets it, hall and all")
  -- a roamer at the roll
  reset()
  local desc = { species = 16, level = 50, hp = 12, ivs = { hp = 31, atk = 31, def = 31, spe = 31,
                 spa = 31, spd = 31 }, personality = 5, roamer = true }
  local roamEnc = { species = "PIDGEY", speciesId = 16, level = 50, roamer = true, foe = desc }
  local rolled = run.loader.hooks:call("encounter.roll", function() return roamEnc end, {},
    { mapId = "FR_ROUTE_1" })
  eq(rolled, nil, version .. ": a roamer is diverted at the roll")
  eq(#coopAsked, 0, version .. ": ...never put to co-op")
  local rg = soloGot[1]
  eq(rg and rg.opts.stand3.kind3, "roamer", version .. ": ...solo's, as a roamer")
  eq(rg and rg.enc.roamer, true, version .. ": ...the encounter still says roamer")
  eq(rg and rg.enc.mon.hp, 12, version .. ": ...its monster carries the banked HP")
  -- handed back: the cart fights the roamer as one, the save's descriptor kept
  rg.opts.fallback()
  local handed = lastOf("engineStart")
  eq(handed and handed[1].roamer, true, version .. ": a roamer handed back is one")
  eq(handed and handed[1].foe, desc, version .. ": ...with the save's descriptor")
  eq(handed and handed[1].hp, 12, version .. ": ...and its HP")
  -- the Safari Zone, which says so only through the session
  reset()
  STORE.flags[0x800] = true
  run.loader.hooks:call("encounter.roll", function() return { species = "PIDGEY", speciesId = 16, level = 3 } end,
    {}, { mapId = "FR_ROUTE_1" })
  STORE.flags[0x800] = nil
  local sg = soloGot[1]
  eq(sg and sg.opts.stand3.kind3, "safari", version .. ": a Safari wild is solo's")
  eq(sg and sg.opts.safari, true, version .. ": ...told in the start's own word")
  eq(sg and sg.enc.safari, true, version .. ": ...on the encounter too")
  eq(#coopAsked, 0, version .. ": ...never co-op's")
  -- Emerald's ALTERING CAVE, through the roll: the map the client was told
  -- reaches the stand-in's held-item roll (W3-CORE).
  if version == "emerald" then
    reset()
    local realRules = FakeEncounters.rules
    local caveAsks = {}
    FakeEncounters.rules = function()
      return { wildHeldItem = function(_, o) caveAsks[#caveAsks + 1] = o or {}; return 21 end }
    end
    run.loader.hooks:call("encounter.roll", function() return { species = "PIDGEY", speciesId = 16, level = 3 } end,
      {}, { mapId = "EM_ALTERING_CAVE" })
    FakeEncounters.rules = realRules
    eq(caveAsks[1] and caveAsks[1].alteringCave, true, version .. ": a wild met in the ALTERING CAVE rolls the cave's items")
    eq(soloGot[1] and soloGot[1].enc.mon and soloGot[1].enc.mon.heldItem, 21,
       version .. ": ...and solo fights the monster holding it")
  end
  -- declined by solo: the encounter is the cart's again
  reset()
  soloTakes = false
  local plainEnc = { species = "PIDGEY", speciesId = 16, level = 3 }
  eq(run.loader.hooks:call("encounter.roll", function() return roamEnc end, {}, { mapId = "FR_ROUTE_1" }),
     roamEnc, version .. ": a roamer solo declines is the cart's encounter")
  soloTakes = true
  -- the POKe DUDE, through the client
  reset()
  local codes = {}
  FakePokedude.startTeachyTvBattle(SESSION, 2, { onDone = function(c) codes[#codes + 1] = c end })
  local pg = soloGot[1]
  eq(pg and pg.opts.stand3.tutorial3, "pokedude", version .. ": the POKe DUDE is solo's")
  eq(pg and pg.opts.pokedude, true, version .. ": ...told in Battle.start's words")
  eq(recorded("pokedudeStart"), 0, version .. ": ...and the TEACHY TV's battle did not start")
  pg.opts.done("win")
  eq(codes[1], 1, version .. ": its done answers the TEACHY TV")

  -- SOLO BATTLES off, still partied: the cart keeps every kind co-op refuses
  run.loader.modOptions.rby_mmo = { solo = false }
  reset()
  FakeBB.startWild("ENGINE_MOD", game, { species = 151, level = 50 }, { legendary = true })
  eq(#coopAsked + #soloGot, 0, version .. ": solo off: a legend is nobody's")
  eq(recorded("engineStart"), 1, version .. ": ...the cart fights it")
  reset()
  eq(run.loader.hooks:call("encounter.roll", function() return roamEnc end, {}, { mapId = "FR_ROUTE_1" }),
     roamEnc, version .. ": solo off: a roamer passes the roll untouched")
  eq(#coopAsked, 0, version .. ": ...nobody asked")
  reset()
  run.loader.hooks:call("encounter.roll", function() return plainEnc end, {}, { mapId = "FR_ROUTE_1" })
  eq(#coopAsked, 1, version .. ": solo off: a plain wild is still co-op's to take")
  reset()
  FakeBB.start("ENGINE_MOD", game, FakeTrainers.foeFromId(326),
    { trainerId = 326, trainerIdB = 327, twoOpponents = true, double = true })
  eq(#coopAsked + #soloGot, 0, version .. ": solo off: two trainers are nobody's")
  eq(recorded("engineStart"), 1, version .. ": ...the cart fights them")
  reset()
  FakePokedude.startTeachyTvBattle(SESSION, 2, { onDone = function() end })
  eq(recorded("pokedudeStart"), 1, version .. ": solo off: the TEACHY TV plays its own")
  eq(#soloGot, 0, version .. ": ...nobody asked")

  -- leave the engine functions as they were found
  Stack.push = stackPush
  FakeBB.start = rawget(FakeBB, "__rby_mmo_start") or bbOriginal
  rawset(FakeBB, "__rby_mmo_start", nil)
  rawset(FakeBB, "__rby_mmo_start:live", nil)
  FakePokedude.startTeachyTvBattle = rawget(FakePokedude, "__rby_mmo_pokedude") or pdOriginal
  rawset(FakePokedude, "__rby_mmo_pokedude", nil)
  rawset(FakePokedude, "__rby_mmo_pokedude:live", nil)
  run.release()
end

-- A family that does not load is said at boot, by its file, and costs only
-- its own fights (W3-CORE): the install's reader serves a src/Solo3/Legend.lua
-- that does not parse.  The mod still loads, every other family is read, and
-- the mod's resolver still answers afterwards -- a file that does not parse is
-- never handed to it (main.lua gives up on every later module once one
-- fails).
do
  newGame({ version = "emerald" })
  SESSION.party = { builtMon(4, 10) }
  GameVersion.set("emerald")
  local fs = makeRemapFs(T, MOD_PATH)
  local realRead = fs.read
  local broken = MOD_PATH ~= "mods/rby_mmo" and (MOD_PATH .. "/src/Solo3/Legend.lua") or nil
  fs.read = function(path)
    if path == "mods/rby_mmo/src/Solo3/Legend.lua" or path == broken then
      return "return { kinds3 = {"
    end
    return realRead(path)
  end
  local Logger = require("src.core.Logger")
  local realWarn, heard = Logger.warn, {}
  Logger.warn = function(fmt, ...)
    local ok, line = pcall(string.format, fmt, ...)
    heard[#heard + 1] = ok and line or tostring(fmt)
    return realWarn(fmt, ...)
  end
  local okLoad, run = pcall(T.sdk.loadMod, "mods/rby_mmo",
    { generation = 3, data = T.sdk.gen3Data(), fs = fs })
  Logger.warn = realWarn
  check(okLoad, "boot (broken family): loading never raises (" .. tostring(not okLoad and run or "") .. ")")
  if okLoad then
    eq(run.mod and run.mod.state, "loaded", "boot (broken family): the mod still loads")
    local said = table.concat(heard, " / ")
    check(said:find("src/Solo3/Legend.lua", 1, true) ~= nil and said:find("reinstall", 1, true) ~= nil,
          "boot (broken family): it is said at boot, by its file, with what to do: " .. said)
    local exports = run.loader.exports and run.loader.exports.rby_mmo
    local ctx = exports and type(exports.players) == "function" and upvalue(exports.players, "ctx")
    local SoloM = ctx and getmetatable(ctx.solo)
    eq(SoloM and SoloM.KINDS3.roamer, nil, "boot (broken family): its kinds are not registered (the cart's)")
    check(SoloM and SoloM.KINDS3.facility ~= nil and SoloM.KINDS3.pair ~= nil,
          "boot (broken family): ...every other family is")
    eq(SoloM and type(SoloM.turnFor(3)), "table",
       "boot (broken family): the mod's resolver still answers a module asked for later")
    run.release()
  end
end

-- ...and one that parses but throws while starting is kept to itself too:
-- main.lua's resolver asks for a family module as optional, so its failure
-- never switches off the modules asked for after it (a plain module's still
-- does, so a half-wired install never runs).
do
  newGame({ version = "emerald" })
  SESSION.party = { builtMon(4, 10) }
  GameVersion.set("emerald")
  local fs = makeRemapFs(T, MOD_PATH)
  local realRead = fs.read
  local broken = MOD_PATH ~= "mods/rby_mmo" and (MOD_PATH .. "/src/Solo3/Legend.lua") or nil
  fs.read = function(path)
    if path == "mods/rby_mmo/src/Solo3/Legend.lua" or path == broken then
      return "error('a family that throws at start')"
    end
    return realRead(path)
  end
  local okLoad, run = pcall(T.sdk.loadMod, "mods/rby_mmo",
    { generation = 3, data = T.sdk.gen3Data(), fs = fs })
  check(okLoad, "boot (throwing family): loading never raises (" .. tostring(not okLoad and run or "") .. ")")
  if okLoad then
    eq(run.mod and run.mod.state, "loaded", "boot (throwing family): the mod still loads")
    local exports = run.loader.exports and run.loader.exports.rby_mmo
    local ctx = exports and type(exports.players) == "function" and upvalue(exports.players, "ctx")
    local SoloM = ctx and getmetatable(ctx.solo)
    eq(SoloM and SoloM.KINDS3.roamer, nil, "boot (throwing family): its kinds are not registered")
    check(SoloM and SoloM.KINDS3.facility ~= nil and SoloM.KINDS3.pair ~= nil,
          "boot (throwing family): ...every other family is")
    eq(SoloM and type(SoloM.turnFor(3)), "table",
       "boot (throwing family): the resolver still answers a module asked for later")
    run.release()
  end
end
GameVersion.set("red")

T.finish("gen3_doors")
