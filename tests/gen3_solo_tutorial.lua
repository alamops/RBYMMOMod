-- Headless Gen 3 solo battles: the three tutorials, the `tutorial` kind of
-- src/Solo3/Tutorial.lua (wave 4 K-TUT of docs/plans/gen3-solo-remaining-
-- fights.md; research §1.5, §2.2, §3.1, §3.4), through the real
-- src/SoloBattle.lua core, the real BattleSim3 referee, MediatedBattle's real
-- single screen and src/CoopField.lua's real stand-ins -- the old man's and
-- WALLY's from the wild door (wildStand3), the POKe DUDE's from the TEACHY
-- TV's (pokedudeStand3).  The screen's three tutorial methods (UM4's
-- `autoplay3`, `sayTutorial3`, `wallyThrow3`) are stood in here: each
-- records what it was asked, `autoplay3` files the choice through the
-- screen's own `sendChoice` at once.  The rig is
-- tests/fixtures/gen3_solo_dbl_rig.lua.
--
--   1. the registry, and the pure helpers: which tutorial, the trainer's name
--      out of the cart's text, the bags, the POKe DUDE's input scripts (the
--      STATUS script running on into the MATCHUPS and CATCHING rows) and his
--      text-script matcher;
--   2. the old man: side a fields nothing and holds his bag; his one input,
--      the ball, on turn 1 when the menu is up; the forced catch that gives
--      nothing; "The old man used ..."; done("caught"); the player's party
--      and bag untouched (the bag swapped for his while the fight runs); no
--      dex "seen"; a choice that is not the script's refused;
--   3. WALLY: his ZIGZAGOON (the session's party, as the script leaves it)
--      TACKLEs twice, the foe acting both turns; the throw turn played
--      (`wallyThrow3`) before the ball is walked; the foe does not act that
--      turn; the forced catch, nothing given; the dex sees the RALTS;
--   4. the POKe DUDE: his party as the session's for the fight and back
--      after, EXP into his monsters only; both sides from the scripts; every
--      voice-over at its point, in order (BATTLE, STATUS with the lit
--      healthbox and the ANTIDOTE, CATCHING with "catch" and the TEACHY TV's
--      CAUGHT); the TEACHY TV's bag in and back; the MATCHUPS switch;
--   5. the hand-backs: a referee hand-back and a divert that fails after the
--      party went in both leave the player's party and bag where the cart's
--      own start expects them; a screen without `autoplay3` still gets the
--      scripted inputs.
--
-- Legal: every species, move and party below is invented with synthetic
-- numbers (the POKe DUDE's demonstration parties included); the only real
-- values are pret enum numbers the battle code branches on (ITEM_*, EFFECT_*,
-- TTVSCR_*), pret's string ids and text keys, and the cursor / slot columns
-- of pret's input scripts the module states.
--
-- Run from the engine checkout root:
--
--   luajit mods/rby_mmo/tests/gen3_solo_tutorial.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local check, eq = T.check, T.eq

local here = (debug.getinfo(1, "S").source:sub(2):match("(.+)[/\\]")) or "."
local R = dofile(here .. "/fixtures/gen3_solo_dbl_rig.lua")(T)

local Solo, CoopField, Mediated, Gen3 = R.Solo, R.CoopField, R.Mediated, R.Gen3
local mon, block = R.mon, R.block
local warns = R.warns
local P3, ROM, ITEMS = R.P3, R.ROM, R.ITEMS

-- ===================================================================
-- the fixtures
-- ===================================================================

-- The items the tutorials' bags hold (pret ITEM_* numbers; names invented
-- where the SDK fixture has none).
ITEMS[3] = { name = "GREAT BALL", pocket = "POKE_BALLS", price = 600 }
ITEMS[8] = { name = "NEST BALL", pocket = "POKE_BALLS", price = 1000 }
ITEMS[14] = { name = "ANTIDOTE", pocket = "ITEMS", price = 100 }
ITEMS[366] = { name = "TEACHY TV", pocket = "KEY_ITEMS", price = 0 }

-- Synthetic moves: a fixed-damage hit (EFFECT_LEVEL_DAMAGE, 87: damage =
-- the user's level, so a fight runs to a known number of turns), a sleep
-- move (EFFECT_SLEEP, 1) and a poison move (EFFECT_POISON, 66).
ROM[351] = { effect = 87, power = 1, type = 0, accuracy = 100, pp = 20,
             secondaryChance = 0, target = 0, priority = 0, flags = 3 }
P3._moveNames[351] = "LEVELHIT"
ROM[352] = { effect = 1, power = 0, type = 0, accuracy = 75, pp = 15,
             secondaryChance = 0, target = 0, priority = 0, flags = 18 }
P3._moveNames[352] = "SNOOZE"
ROM[353] = { effect = 66, power = 0, type = 3, accuracy = 75, pp = 35,
             secondaryChance = 0, target = 0, priority = 0, flags = 18 }
P3._moveNames[353] = "TOXDUST"

local function base(hp, atk, def, spe, spa, spd)
  return { hp = hp, atk = atk, def = def, spe = spe, spa = spa, spd = spd }
end
local function addSpecies(id, name, stats, learn)
  P3._names[id] = name
  P3._types[id] = { 0, 0 }
  P3._stats[id] = stats
  P3._speciesMeta[id] = { catchRate = 255, expYield = 60, growthRate = 0, genderRatio = 127,
                          itemCommon = 0, itemRare = 0, friendship = 70 }
  P3._abilities[id] = { 0, 0 }
  P3._learnsets[id] = learn or { { 1, 33 } }
end
-- Invented ids inside the referee's species range (Config.GEN3_SPECIES_MAX).
local OLDBUG, WALLYFOE = 301, 302
local PDRAT, PDBIRD, PDFLY, PDPUFF, PDODD, PDPOL = 303, 304, 305, 306, 307, 308
addSpecies(OLDBUG, "OLDBUG", base(40, 35, 30, 50, 20, 20), { { 1, 33 } })
-- WALLY's foe: a wall that knows only GROWL (its moves never hurt).
addSpecies(WALLYFOE, "WALLYFOE", base(250, 25, 200, 40, 45, 35), { { 1, 45 } })
addSpecies(PDRAT, "PDRAT", base(40, 56, 35, 100, 25, 35))
addSpecies(PDBIRD, "PDBIRD", base(20, 45, 40, 10, 35, 35))
addSpecies(PDFLY, "PDFLY", base(60, 45, 50, 100, 80, 80))
addSpecies(PDPUFF, "PDPUFF", base(250, 45, 20, 5, 45, 25))
addSpecies(PDODD, "PDODD", base(20, 50, 55, 10, 75, 65))
addSpecies(PDPOL, "PDPOL", base(40, 50, 40, 90, 40, 40))

local ZERO = { hp = 0, atk = 0, def = 0, spe = 0, spa = 0, spd = 0 }
local function pdMon(species, level, moves)
  return mon(species, level, { moves = moves, ivs = ZERO, otId = 0, otName = "" })
end

-- ------------------------------------------------------------------
-- the engine's TEACHY TV and POKe DUDE, stood in
-- ------------------------------------------------------------------

-- battle/pokedude.lua: the demonstrations' parties (invented), the outcome
-- codes, the back pic, the text-script headers as the engine states pret's
-- sPokedudeTextScripts_* (cmd / side / string id / callback), and the text
-- keys (one invented key per line).
local function vo(cmd, side, stringId, kind)
  return { cmd = cmd, side = side, stringId = stringId, kind = kind }
end
local FakePokedude = {
  OUTCOME = { WON = 1, LOST = 2, DREW = 3, RAN = 4, CAUGHT = 7 },
  BACK_PIC = 4,
  TEXT_SCRIPTS = {
    [0] = {
      vo("chooseaction", 0, nil, "voiceover"),
      vo("printstring", 1, "STRINGID_USEDMOVE", "voiceover"),
      vo("chooseaction", 0, nil, "voiceover"),
      vo("printstring", 0, "STRINGID_PKMNGAINEDEXP", "voiceover"),
    },
    [1] = {
      vo("chooseaction", 0, nil, nil),
      vo("chooseaction", 0, nil, "healthbox"),
      vo("openbag", 0, nil, "voiceover"),
      vo("printstring", 1, "STRINGID_USEDMOVE", "voiceover"),
      vo("printstring", 0, "STRINGID_PKMNGAINEDEXP", "voiceover"),
    },
    [2] = {
      vo("printstring", 1, "STRINGID_USEDMOVE", "voiceover"),
      vo("chooseaction", 0, nil, "voiceover"),
      vo("choosepokemon", 0, nil, "voiceover"),
      vo("printstring", 1, "STRINGID_USEDMOVE", "voiceover"),
      vo("chooseaction", 0, nil, "voiceover"),
      vo("choosemove", 0, nil, "voiceover"),
      vo("printstring", 0, "STRINGID_PKMNGAINEDEXP", "voiceover"),
    },
    [3] = {
      vo("chooseaction", 0, nil, "voiceover"),
      vo("chooseaction", 0, nil, nil),
      vo("chooseaction", 0, nil, "voiceover"),
      vo("printstring", 1, "STRINGID_PKMNFASTASLEEP", "voiceover"),
      vo("openbag", 0, nil, "voiceover"),
      vo("endlinkbattle", 0, nil, "voiceover"),
    },
  },
}
local builds = {}
function FakePokedude.build(script)
  script = tonumber(script)
  builds[#builds + 1] = script
  if script == 0 then
    return { pdMon(PDRAT, 15, { 33, 45, 351, 1 }) }, { pdMon(PDBIRD, 5, { 33, 45, 351, 1 }) }
  elseif script == 1 then
    return { pdMon(PDRAT, 15, { 33, 45, 351, 1 }) }, { pdMon(PDODD, 5, { 33, 45, 353 }) }
  elseif script == 2 then
    return { pdMon(PDPOL, 15, { 33, 45, 1 }), pdMon(PDFLY, 15, { 351, 45, 1, 33 }) },
           { pdMon(PDODD, 30, { 45, 45, 45 }) }
  end
  return { pdMon(PDFLY, 15, { 33, 45, 352, 1 }) }, { pdMon(PDPUFF, 11, { 45, 45, 1 }) }
end
function FakePokedude.textKey(script, index0) return ("PDTEXT_%d_%d"):format(script, index0) end
-- The cart's own demonstration start (what the TEACHY TV wrap wraps):
-- recorded with what it finds -- the session's party, the TEACHY TV on the
-- stack, the bag menu.
local cartStarts = {}
function FakePokedude.startTeachyTvBattle(session, script, opts)
  local bagMenu = package.loaded["src.ui.game3.bag_menu"]
  cartStarts[#cartStarts + 1] = { session = session, script = script, opts = opts,
    party = R.session() and R.session().party, tv = R.Stack.has("teachy_tv"),
    bagOpen = type(bagMenu) == "table" and bagMenu.open or nil,
    backup = R.session() and R.session().teachyBagBackup }
  return true
end
package.loaded["src.core.game3.battle.pokedude"] = FakePokedude

-- teachy_tv.lua: the POKe DUDE's bag (pret InitPokedudeBag's items) swapped
-- into the session's pockets and back, recorded.
local teachyLog = {}
local FakeTeachyTv = {
  POKEDUDE_BAG = {
    { id = 13, qty = 1 }, { id = 14, qty = 1 }, { id = 366, qty = 1 }, { id = 4, qty = 5 },
    { id = 3, qty = 1 }, { id = 8, qty = 1 },
  },
}
local function copyPockets(p)
  local out = {}
  for k, slots in pairs(p) do
    out[k] = {}
    for i, s in ipairs(slots) do out[k][i] = { id = s.id, qty = s.qty } end
  end
  return out
end
function FakeTeachyTv.initPokedudeBag(session, script)
  teachyLog[#teachyLog + 1] = { "init", script }
  session.teachyBagBackup = { pockets = session.bag.pockets }
  local fresh = { ITEMS = {}, KEY_ITEMS = {}, POKE_BALLS = {}, TM_CASE = {}, BERRY_POUCH = {} }
  session.bag.pockets = fresh
  for _, e in ipairs(FakeTeachyTv.POKEDUDE_BAG) do R.FakeBag.add(session.bag, e.id, e.qty) end
  return 1
end
function FakeTeachyTv.restorePlayerBag(session)
  teachyLog[#teachyLog + 1] = { "restore" }
  local backup = session.teachyBagBackup
  if not backup then return false end
  session.bag.pockets = backup.pockets
  session.teachyBagBackup = nil
  return true
end
-- pret teachy_tv.c:1172: WHITE_BARS_FADE for the battle basics, SLICE for the
-- rest (the engine numbers them 9 and 8).
function FakeTeachyTv.battleTransition(script) return tonumber(script) == 0 and 9 or 8 end
package.loaded["src.core.game3.teachy_tv"] = FakeTeachyTv

-- battle_transition.lua: recorded; its `doneCb` run at once, or held.
local FakeTransition = { ID = { SLICE = 8 }, log = {}, hold = false, held = nil }
function FakeTransition.start(id, opts, cb)
  FakeTransition.log[#FakeTransition.log + 1] = { id = id, opts = opts }
  if FakeTransition.hold then FakeTransition.held = cb; return true end
  if cb then cb() end
  return true
end
package.loaded["src.core.game3.battle_transition"] = FakeTransition

-- The bag the TEACHY TV was opened from (bag_menu.lua's `open`), and the
-- songs played by name.
local BagMenu = { open = false }
package.loaded["src.ui.game3.bag_menu"] = BagMenu
local songs = {}
do
  local realSong = Gen3.audio.playSong
  Gen3.audio.playSong = function(name, ...)
    songs[#songs + 1] = name
    return realSong(name, ...)
  end
end

-- ------------------------------------------------------------------
-- the screen's tutorial methods, stood in
-- ------------------------------------------------------------------

-- The screen's own, whatever this checkout's MediatedBattle has (UM4 / SCR):
-- the real-screen block (6) runs them.
local REAL = {
  autoplay3 = Mediated.autoplay3, sayTutorial3 = Mediated.sayTutorial3,
  wallyThrow3 = Mediated.wallyThrow3, tutorialIdle3 = Mediated.tutorialIdle3,
}

-- Every call, in order, across the methods: { "say", text, opts } /
-- { "auto", choice, turn, opts } / { "after" } / { "wally" }.  `HOLD` books a
-- walk without filing it (the walk still running).
local tut = { log = {}, HOLD = false, held = nil }
local function tutLog(kind)
  local out = {}
  for _, e in ipairs(tut.log) do if e[1] == kind then out[#out + 1] = e end end
  return out
end
local function sayTutorial3(self, text, opts)
  tut.log[#tut.log + 1] = { "say", text, opts }
  self:say("VO:" .. tostring(text))
  return true
end
-- The commands whose sub-menu opens after the walk picks them (contract C-V:
-- `afterCommand` runs there; not for RUN or WALLY's throw).
local SUBMENU = { fight = true, item = true, switch = true }
local function autoplay3(self, choice, onFiled, opts)
  local copy = {}
  for k, v in pairs(choice) do copy[k] = v end
  tut.log[#tut.log + 1] = { "auto", copy, tut.sim and tut.sim.turn or nil, opts }
  if tut.HOLD then
    tut.held = { screen = self, choice = copy, onFiled = onFiled, opts = opts }
    return true
  end
  if type(opts) == "table" and type(opts.afterCommand) == "function" and SUBMENU[copy.action] then
    tut.log[#tut.log + 1] = { "after" }
    opts.afterCommand(self)
  end
  local sent = self:sendChoice(copy)
  if onFiled then onFiled(sent, copy) end
  return true
end
local function wallyThrow3()
  tut.log[#tut.log + 1] = { "wally", tut.sim and tut.sim.turn or nil }
  return true
end
local function tutorialIdle3() return true end
local function installScreen()
  Mediated.sayTutorial3, Mediated.autoplay3, Mediated.wallyThrow3 = sayTutorial3, autoplay3, wallyThrow3
  Mediated.tutorialIdle3 = tutorialIdle3
end
installScreen()

local function resetTut()
  tut.log, tut.HOLD, tut.held, tut.sim = {}, false, nil, nil
  teachyLog = {}
  builds = {}
  cartStarts = {}
  songs = {}
  FakeTransition.log, FakeTransition.hold, FakeTransition.held = {}, false, nil
  BagMenu.open = false
end

-- ------------------------------------------------------------------
-- the doors
-- ------------------------------------------------------------------

-- The wild door's stand-in and what src/Client.lua's offerFight3 hands solo:
-- the encounter carrying the stand-in's monster.
local function wildDoor(solo, foeRow, opts, done)
  local stand, why = CoopField.wildStand3(foeRow, { game = R.game(), solo = true }, opts)
  if not stand then return nil, why end
  local enc = {}
  for k, v in pairs(foeRow) do enc[k] = v end
  enc.mon = stand.enemyParty[1]
  local taken = solo:fromGen3Encounter(R.game(), enc, R.standOpts(stand, done))
  tut.sim = solo.sim
  return stand, taken
end

-- The TEACHY TV's door, the real one: CoopField's wrap of the POKe DUDE's
-- start (divertPokedude -- the music, the transition, the TEACHY TV off the
-- stack, his bag and party in), with src/Client.lua's pokedudeHandler3 shape
-- for a handler (solo's, through the encounter entry, the stand-in's own
-- `done` and hand-back).  The TEACHY TV is on the stack and its bag open when
-- the program starts.
local door = {}
local doorHandler = {
  wants = function() return R.OPTIONS.solo == true end,
  game = function() return R.game() end,
  take = function(stand)
    door.stand = stand
    local enc = {}
    for k, v in pairs(stand.encounter or {}) do enc[k] = v end
    enc.mon = stand.enemyParty[1]
    door.atTake = { party = R.session().party, tv = R.Stack.has("teachy_tv"), bagOpen = BagMenu.open,
                    depth = R.Stack.depth() }
    local taken = door.solo:fromGen3Encounter(R.game(), enc, R.standOpts(stand, stand.doneFn)) == true
    if taken then pcall(stand.begin3, stand) end
    tut.sim = door.solo.sim
    door.taken = taken
    return taken
  end,
}
check(CoopField.installPokedude3(doorHandler), "rig: the TEACHY TV wrap installs over the stand-in POKe DUDE")
local function teachyUp()
  if not R.Stack.has("teachy_tv") then R.Stack.push("teachy_tv", {}, { hideBelow = true, fullscreen = true }) end
  BagMenu.open = true
end
local function teachyDoor(solo, script, onDone, extra)
  door.solo, door.stand, door.taken, door.atTake = solo, nil, nil, nil
  teachyUp()
  local opts = { onDone = onDone }
  for k, v in pairs(extra or {}) do opts[k] = v end
  local started = FakePokedude.startTeachyTvBattle(R.session(), script, opts)
  return door.stand, door.taken, started
end

local function textIdx(fight, needle, from) return R.indexIn(fight and fight.textLog or {}, needle, from) end

local function lastScreenTutorial() local so = R.lastScreen() return so and so.tutorial end

local Tut

-- ===================================================================
-- 1. the registry, and the pure helpers
-- ===================================================================

block("registry", function()
  eq(Solo.KIND_FILES3.tutorial, "Solo3/Tutorial", "registry: the tutorials' module is Solo3/Tutorial")
  local kind = Solo.kind3("tutorial")
  check(type(kind) == "table", "registry: the kind is found through mod:read")
  check(R.contains(R.reads, "src/Solo3/Tutorial.lua"), "registry: ...by reading src/Solo3/Tutorial.lua")
  Tut = R.need("Solo3/Tutorial")
  eq(kind, Tut.Tutorial, "registry: the kind is Tutorial.Tutorial")
  for name, fn in pairs(kind) do
    local known = false
    for _, hook in ipairs(Solo.KIND_HOOKS3) do if hook == name then known = true end end
    check(known and type(fn) == "function", "registry: '" .. tostring(name) .. "' is a hook the core calls")
  end
  eq(Gen3.engine("src.core.game3.battle.pokedude"), FakePokedude, "rig: the POKe DUDE stand-in is the engine's")
end)

block("which tutorial", function()
  R.newGame("firered")
  eq(Tut.which3({ tutorial3 = "oldMan" }), "oldMan", "which: the stand's")
  eq(Tut.which3({ tutorial3 = "pokedude" }), "pokedude", "which: ...the POKe DUDE")
  eq(Tut.which3({ opts = { oldManTutorial = true } }), "oldMan", "which: the old man's engine key")
  eq(Tut.which3({ foe = { oldManTutorial = true } }), "oldMan", "which: ...on the foe")
  eq(Tut.which3({ opts = { tutorialKind = "wally" } }), "wally", "which: WALLY's")
  eq(Tut.which3({ opts = { pokedude = true, wild = true } }), "pokedude", "which: the TEACHY TV's")
  eq(Tut.which3({ opts = { kinds = { tutorial = "oldman" } } }), "oldMan", "which: the profile's spelling")
  eq(Tut.which3({ opts = { wild = true } }), nil, "which: none")
end)

block("the trainer's name", function()
  R.newGame("firered")
  eq(Tut.seatName3("oldMan"), "The old man", "name: without the cart's line, pret's subject")
  eq(Tut.seatName3("wally"), "WALLY", "name: WALLY's")
  eq(Tut.seatName3("pokedude"), "The POKé DUDE", "name: the POKe DUDE's")
  R.TEXT.STRINGID_OLDMANUSEDITEM = function(fill)
    return "The OLD-TIMER used\n" .. tostring(fill.lastItem) .. "!"
  end
  eq(Tut.seatName3("oldMan"), "The OLD-TIMER", "name: the subject of the cart's own line")
end)

block("the bags", function()
  R.newGame("firered")
  local old = Tut.bag3("oldMan")
  eq(#old, 2, "bags: the old man's holds two items (InitOldManBag)")
  eq(old[1] and old[1].id, 13, "bags: ...a POTION")
  eq(old[2] and old[2].id, 4, "bags: ...and a POKé BALL")
  eq(old[2] and old[2].count, 1, "bags: ...one")
  check(old[2] and type(old[2].name) == "string" and old[2].name:find("BALL") ~= nil,
        "bags: ...named the cart's way")
  local pd = Tut.bag3("pokedude")
  local ids = {}
  for _, e in ipairs(pd) do ids[#ids + 1] = e.id .. "x" .. e.count end
  eq(table.concat(ids, ","), "13x1,14x1,4x5,3x1,8x1",
     "bags: the POKe DUDE's is the engine's InitPokedudeBag list, battle items only")
end)

block("the POKe DUDE's input scripts", function()
  local function run(script, side, n)
    local pd = Tut.pdNewState3(script)
    local out = {}
    for _ = 1, n do out[#out + 1] = Tut.pdTakeAction3(pd, side) end
    return table.concat(out, "")
  end
  local function moves(script, side, n)
    local pd = Tut.pdNewState3(script)
    local out = {}
    for _ = 1, n do out[#out + 1] = Tut.pdTakeMove3(pd, side) end
    return table.concat(out, "")
  end
  eq(run(0, 0, 5), "00000", "scripts: BATTLE -- FIGHT every turn (the 4 row starts it over)")
  eq(run(0, 1, 5), "00000", "scripts: ...and the foe's")
  eq(run(1, 0, 10), "0100200010",
     "scripts: STATUS -- FIGHT, BAG, FIGHT, then on into the MATCHUPS and CATCHING rows; FIGHT past them")
  eq(run(2, 0, 4), "0200", "scripts: MATCHUPS -- FIGHT, POKéMON, FIGHT, then the CATCHING rows")
  eq(run(3, 0, 3), "001", "scripts: CATCHING -- FIGHT, FIGHT, BAG")
  eq(run(3, 1, 3), "000", "scripts: ...the foe FIGHTs")
  eq(moves(0, 0, 3), "222", "scripts: BATTLE's moves -- slot 2, over and over")
  eq(moves(1, 1, 4), "2002", "scripts: STATUS's foe -- slot 2, 0, 0, then over")
  eq(moves(2, 0, 4), "2002", "scripts: MATCHUPS -- slot 2, 0, 0, then over")
  eq(moves(3, 0, 3), "020", "scripts: CATCHING -- slot 0, then 2, then over")
  eq(moves(3, 1, 2), "22", "scripts: ...its foe slot 2")
end)

block("the POKe DUDE's text scripts", function()
  local pd = Tut.pdNewState3(3)
  local headers = FakePokedude.TEXT_SCRIPTS[3]
  local due = Tut.pdEvent3(pd, headers, "chooseaction", 0)
  eq(#due, 1, "matcher: CATCHING's first prompt -- one voice-over")
  eq(due[1] and due[1].index0, 0, "matcher: ...line 0")
  eq(pd.messageNo, 2, "matcher: ...and the NULL header behind it passed over at the same prompt")
  eq(#Tut.pdEvent3(pd, headers, "printstring", 1, "STRINGID_USEDMOVE"), 0,
     "matcher: a command the next header does not name moves nothing")
  eq(pd.messageNo, 2, "matcher: ...still")
  local second = Tut.pdEvent3(pd, headers, "chooseaction", 0)
  eq(second[1] and second[1].index0, 2, "matcher: the next prompt -- line 2")
  eq(#Tut.pdEvent3(pd, headers, "printstring", 1, "STRINGID_USEDMOVE"), 0,
     "matcher: a PRINTSTRING of another string id is not FASTASLEEP's")
  eq(#Tut.pdEvent3(pd, headers, "printstring", 0, "STRINGID_PKMNFASTASLEEP"), 0,
     "matcher: ...nor one to the other battler")
  eq(Tut.pdEvent3(pd, headers, "printstring", 1, "STRINGID_PKMNFASTASLEEP")[1].index0, 3,
     "matcher: the foe's FASTASLEEP -- line 3")
  local status = Tut.pdNewState3(1)
  eq(#Tut.pdEvent3(status, FakePokedude.TEXT_SCRIPTS[1], "chooseaction", 0), 0,
     "matcher: STATUS's first prompt is NULL -- no line, and the prompt goes on")
  local lit = Tut.pdEvent3(status, FakePokedude.TEXT_SCRIPTS[1], "chooseaction", 0)
  eq(lit[1] and lit[1].kind, "healthbox", "matcher: ...its second, the healthbox line")

  -- The stream is read once the turn has resolved: a foe that fainted later
  -- in the same turn still owns its "used" line.
  R.newGame("firered")
  local said = {}
  local ctx = {
    tut3 = { pd = Tut.pdNewState3(0), headers = FakePokedude.TEXT_SCRIPTS[0] },
    sim = { byId = {
      solo_foe = { active = nil, mons = { { species = "PDBIRD" } } },
      solo_player = { active = 1, mons = { { species = "PDRAT" } } },
    } },
    fight = { sayTutorial3 = function(_, text) said[#said + 1] = text end },
  }
  Tut.pdEvent3(ctx.tut3.pd, ctx.tut3.headers, "chooseaction", 0)
  Tut.pdNote3(ctx, { t = "msg", text = "PDRAT used LEVELHIT!" })
  eq(#said, 0, "stream: side a's own move line is not the foe's")
  Tut.pdNote3(ctx, { t = "msg", text = "PDBIRD used LEVELHIT!" })
  eq(#said, 1, "stream: the fainted foe's move line is")
  eq(said[1], "PDTEXT_0_1||", "stream: ...line 1 (the text pack's words for its key)")
end)

-- ===================================================================
-- 2. the old man
-- ===================================================================

local function oldManDoor(solo, done)
  return wildDoor(solo, { species = OLDBUG, level = 5, oldManTutorial = true },
    { wild = true, oldManTutorial = true }, done)
end

block("the old man", function()
  R.newGame("firered")
  resetTut()
  local lead = mon(4, 20, { moves = { 33 } })
  R.session().party = { lead }
  local hp0 = lead.hp
  R.FakeBag.add(R.session().bag, 4, 3)
  R.FakeBag.add(R.session().bag, 21, 2)
  local myBalls = R.session().bag.pockets.POKE_BALLS
  local heard = {}
  local solo = R.newSolo()
  local stand, taken = oldManDoor(solo, function(w) heard[#heard + 1] = w end)
  check(stand ~= nil, "old man: the door builds the stand-in")
  eq(stand and stand.kind3, "tutorial", "old man: ...a tutorial")
  eq(stand and stand.tutorial3, "oldMan", "old man: ...the old man's")
  check(taken, "old man: solo takes it (" .. table.concat(warns, " / ") .. ")")
  local create, so = R.lastCreate(), R.lastScreen()
  eq(create and create.tutorial, "oldMan", "old man: the referee plays BATTLE_TYPE_OLD_MAN_TUTORIAL")
  eq(create and create.catch, "forced", "old man: ...a forced catch")
  eq(create and create.wildPick, "cart", "old man: ...his WEEDLE on the cart's wild move")
  local a = create and create.sides.a[1]
  eq(a and a.noBattler, true, "old man: side a fields no battler")
  eq(a and a.mons, nil, "old man: ...and brings no monsters")
  eq(a and a.name, "The old man", "old man: ...under his name")
  eq(a and a.bag and #a.bag, 2, "old man: ...with his bag (a POTION and a POKé BALL)")
  eq(a and a.bag and a.bag[2] and a.bag[2].id, 4, "old man: ...the POKé BALL")
  local t = so and so.tutorial
  eq(t and t.kind, "oldMan", "old man: the screen is told which tutorial")
  eq(t and t.name, "The old man", "old man: ...whose name")
  eq(t and t.backPic, "TRAINER_BACK_PIC_OLD_MAN", "old man: ...his back pic")
  eq(t and t.prompt, "gText_WhatWillOldManDo", "old man: ...the cart's prompt")
  eq(so and so.noOwnBattler, true, "old man: ...that he fields nothing")
  eq(so and so.bag and #so.bag, 2, "old man: ...and his bag")
  local sim = solo.sim
  eq(sim and sim.byId.solo_player.noBattler, true, "old man: the referee seats him with no battler")
  eq(sim and sim.forcedCatch, true, "old man: ...and a forced catch")
  check(R.drive(solo), "old man: played to the end with nobody pressing anything")
  local autos = tutLog("auto")
  eq(#autos, 1, "old man: one scripted input")
  eq(autos[1] and autos[1][2].action, "item", "old man: ...BAG")
  eq(autos[1] and tonumber(autos[1][2].item), 4, "old man: ...the POKé BALL")
  eq(autos[1] and autos[1][3], 1, "old man: ...on turn 1")
  eq(#tutLog("say"), 0, "old man: no voice-over")
  eq(#tutLog("wally"), 0, "old man: no throw turn")
  local o = sim:outcome()
  eq(o and o.how, "catch", "old man: the WEEDLE is caught")
  eq(o and o.given, false, "old man: ...and given to nobody")
  eq(table.concat(heard, ","), "caught", "old man: done('caught') -- pret B_OUTCOME_CAUGHT")
  eq(solo.fight, nil, "old man: the fight is over")
  eq(#R.session().party, 1, "old man: nothing joins the party")
  eq(lead.hp, hp0, "old man: the player's monster never fought")
  eq(R.session().bag.pockets.POKE_BALLS, myBalls, "old man: the player's POKé BALLS pocket is back")
  eq(R.FakeBag.get(R.session().bag, 4), 3, "old man: ...with all three of the player's balls")
  eq(R.FakeBag.get(R.session().bag, 21), 2, "old man: ...and the rest of the bag")
  for _, s in ipairs(R.FakeDex.seen) do
    check(s.species ~= OLDBUG, "old man: the WEEDLE is not marked seen (OLD_MAN_TUTORIAL)")
  end
  check(not R.contains(R.fieldCalls(), "respawn"), "old man: no whiteout")
  eq(R.FakeVm.halted, 0, "old man: no script halted")
end)

block("the old man's words and turn", function()
  R.newGame("firered")
  resetTut()
  R.session().party = { mon(4, 20, { moves = { 33 } }) }
  local solo = R.newSolo()
  local _, taken = oldManDoor(solo, function() end)
  check(taken, "old man (words): taken")
  local fight = solo.fight
  local sim = solo.sim
  -- His bag is in while the fight runs (pret InitOldManBag after
  -- BackUpPlayerBag), once the referee's first frame has been pumped.
  check(R.untilChoose(solo), "old man (words): the menu comes up")
  check(R.drive(solo), "old man (words): played out")
  check(textIdx(fight, "The old man used") ~= nil, "old man (words): 'The old man used ...' -- the cart's line")
  check(textIdx(fight, "Gotcha!") ~= nil, "old man (words): the forced catch's 'Gotcha!'")
  eq(sim.turn, 1, "old man (words): over on turn 1, his WEEDLE never acting")
end)

block("the old man's bag while the fight runs", function()
  R.newGame("firered")
  resetTut()
  R.session().party = { mon(4, 20, { moves = { 33 } }) }
  R.FakeBag.add(R.session().bag, 4, 3)
  tut.HOLD = true
  local solo = R.newSolo()
  local _, taken = oldManDoor(solo, function() end)
  check(taken, "old man (bag): taken")
  for _ = 1, 10 do
    solo:update(0.5, R.game())
    solo.fight:update(2.0)
    if tut.held then break end
  end
  check(tut.held ~= nil, "old man (bag): the walk is booked")
  eq(R.FakeBag.get(R.session().bag, 4), 1, "old man (bag): his bag is the session's -- one POKé BALL")
  eq(R.FakeBag.get(R.session().bag, 13), 1, "old man (bag): ...and a POTION")
  -- Anything the screen files that is not the script's is refused.
  local fight = solo.fight
  eq(fight:sendChoice({ action = "run" }), false, "old man (bag): a RUN is not his input")
  eq(solo.sim.byId.solo_player.choice, nil, "old man (bag): ...nothing filed")
  eq(fight:sendChoice({ action = "item", item = "13" }), false, "old man (bag): nor the POTION")
  -- The booked walk files.
  local h = tut.held
  tut.held, tut.HOLD = nil, false
  local sent = h.screen:sendChoice(h.choice)
  check(sent, "old man (bag): the scripted ball is taken")
  if h.onFiled then h.onFiled(sent, h.choice) end
  check(R.drive(solo), "old man (bag): played out")
  eq(R.FakeBag.get(R.session().bag, 4), 3, "old man (bag): the player's balls are back")
  eq(R.FakeBag.get(R.session().bag, 13), 0, "old man (bag): ...and his POTION gone with his bag")
  local Borrow3 = R.need("Borrow3")
  eq(Borrow3.held(R.session(), Tut.BAG_BORROW), false,
     "old man (bag): the fight's own end released the save ledger's record")
  eq(rawget(R.session(), Borrow3.KEY), nil, "old man (bag): ...and left no ledger on the session")
end)

-- The borrow on the save ledger (src/Borrow3.lua): a save while the old man's
-- fight runs is refused; a fight that dies without its own end (its screen
-- thrown off the stack, the core never told) has its pockets given back by
-- the `save.write` link before the save is written; an F5 hot reload's new
-- load gives back an old load's borrow whatever its screen says; and a
-- hand-back releases the record as it puts the pockets back.
block("the old man's bag on the save ledger", function()
  local Borrow3 = R.need("Borrow3")
  local function heldWalk(solo)
    for _ = 1, 10 do
      solo:update(0.5, R.game())
      solo.fight:update(2.0)
      if tut.held then break end
    end
    return tut.held ~= nil
  end
  local wrote = 0
  local function writeLink() wrote = wrote + 1; return true end

  -- A screen that dies mid-tutorial.
  R.newGame("firered")
  resetTut()
  R.session().party = { mon(4, 20, { moves = { 33 } }) }
  R.FakeBag.add(R.session().bag, 4, 3)
  local myBalls = R.session().bag.pockets.POKE_BALLS
  tut.HOLD = true
  local solo = R.newSolo()
  local _, taken = oldManDoor(solo, function() end)
  check(taken, "ledger: taken")
  check(heldWalk(solo), "ledger: the walk is booked (his bag is in)")
  eq(R.FakeBag.get(R.session().bag, 4), 1, "ledger: his one POKé BALL is the session's")
  eq(Borrow3.held(R.session(), Tut.BAG_BORROW), true, "ledger: the borrow is recorded")
  local mark = #warns
  eq(Borrow3.beforeSave(writeLink, R.game()), false, "ledger: no save while his fight runs")
  eq(wrote, 0, "ledger: ...the write never reached")
  check(#warns > mark, "ledger: ...and the player is told why")
  R.dropWarnsSince(mark)
  eq(R.FakeBag.get(R.session().bag, 4), 1, "ledger: ...his bag stays in for the running fight")
  local fight = solo.fight
  fight.onDone = nil
  check(R.Gen3Ui.pop(R.game(), fight), "ledger: the screen is thrown off the stack")
  eq(solo.gen3 ~= nil, true, "ledger: ...the core never told")
  eq(Borrow3.beforeSave(writeLink, R.game()), true, "ledger: a dead fight's borrow does not block the save")
  eq(wrote, 1, "ledger: ...the save is written")
  eq(R.session().bag.pockets.POKE_BALLS, myBalls, "ledger: ...after the player's POKé BALLS pocket came back")
  eq(R.FakeBag.get(R.session().bag, 4), 3, "ledger: ...all three of the player's balls")
  eq(R.FakeBag.get(R.session().bag, 13), 0, "ledger: ...and none of his POTION")
  eq(Borrow3.held(R.session(), Tut.BAG_BORROW), false, "ledger: the record is settled")
  eq(Tut.returnBag3(solo.gen3), false, "ledger: a late end of the fight puts nothing back twice")
  eq(R.session().bag.pockets.POKE_BALLS, myBalls, "ledger: ...the player's pocket untouched")
  solo:_clear3()

  -- A second tutorial after a dead one, with no save between: its borrow
  -- settles the dead one first, so what it keeps aside is the player's.
  R.newGame("firered")
  resetTut()
  R.session().party = { mon(4, 20, { moves = { 33 } }) }
  R.FakeBag.add(R.session().bag, 4, 3)
  tut.HOLD = true
  local dead = R.newSolo()
  local _, takenDead = oldManDoor(dead, function() end)
  check(takenDead and heldWalk(dead), "ledger (again): the first tutorial's bag is in")
  dead.fight.onDone = nil
  check(R.Gen3Ui.pop(R.game(), dead.fight), "ledger (again): its screen is thrown off the stack")
  dead:_clear3()
  resetTut()
  tut.HOLD = true
  local again = R.newSolo()
  local _, takenAgain = oldManDoor(again, function() end)
  check(takenAgain and heldWalk(again), "ledger (again): the second tutorial's bag is in")
  eq(R.FakeBag.get(R.session().bag, 4), 1, "ledger (again): ...his one POKé BALL, not two")
  check(Tut.returnBag3(again.gen3), "ledger (again): the second tutorial gives its bag back")
  eq(R.FakeBag.get(R.session().bag, 4), 3, "ledger (again): the player's three balls are back")
  eq(R.FakeBag.get(R.session().bag, 13), 0, "ledger (again): ...and none of his POTION")
  eq(Borrow3.held(R.session(), Tut.BAG_BORROW), false, "ledger (again): nothing left on the ledger")
  if again.fight then
    again.fight.onDone = nil
    pcall(R.Gen3Ui.pop, R.game(), again.fight)
  end
  again:_clear3()

  -- An F5 hot reload mid-tutorial: the new load's ledger reads the old
  -- load's record as stale, whatever its screen says.
  R.newGame("firered")
  resetTut()
  R.session().party = { mon(4, 20, { moves = { 33 } }) }
  R.FakeBag.add(R.session().bag, 4, 3)
  tut.HOLD = true
  local reloaded = R.newSolo()
  local _, taken2 = oldManDoor(reloaded, function() end)
  check(taken2 and heldWalk(reloaded), "ledger (F5): his bag is in")
  local chunk = assert(loadfile(here .. "/../src/Borrow3.lua"))
  local nextLoad = chunk(R.need, R.stubMod)
  local restored, live = nextLoad.settle(R.session())
  eq(restored, 1, "ledger (F5): the next load gives the old load's borrow back")
  eq(#live, 0, "ledger (F5): ...holding nothing live")
  eq(R.FakeBag.get(R.session().bag, 4), 3, "ledger (F5): the player's balls are back")
  eq(R.FakeBag.get(R.session().bag, 13), 0, "ledger (F5): ...and his POTION gone")
  if reloaded.fight then
    reloaded.fight.onDone = nil
    pcall(R.Gen3Ui.pop, R.game(), reloaded.fight)
  end
  reloaded:_clear3()

  -- A hand-back puts the pockets back itself and releases the record.
  R.newGame("firered")
  resetTut()
  R.session().party = { mon(4, 20, { moves = { 33 } }) }
  R.FakeBag.add(R.session().bag, 4, 3)
  tut.HOLD = true
  local handed = R.newSolo()
  local _, taken3 = oldManDoor(handed, function() end)
  check(taken3 and heldWalk(handed), "ledger (hand-back): his bag is in")
  eq(Borrow3.held(R.session(), Tut.BAG_BORROW), true, "ledger (hand-back): recorded")
  tut.HOLD, tut.held = false, nil
  handed:reset()
  eq(Borrow3.held(R.session(), Tut.BAG_BORROW), false, "ledger (hand-back): released")
  eq(R.FakeBag.get(R.session().bag, 4), 3, "ledger (hand-back): the player's balls are back")
  resetTut()
end)

-- ===================================================================
-- 3. WALLY
-- ===================================================================

local function wallyDoor(solo, done)
  return wildDoor(solo, { species = WALLYFOE, level = 5 }, { wild = true, tutorialKind = "wally" }, done)
end

block("WALLY", function()
  R.newGame("emerald")
  resetTut()
  -- The script's LoadWallyZigzagoon leaves his ZIGZAGOON as gPlayerParty[0].
  local zig = mon(263, 7, { moves = { 33 } })
  R.session().party = { zig }
  R.FakeBag.add(R.session().bag, 4, 2)
  local heard = {}
  local solo = R.newSolo()
  local stand, taken = wallyDoor(solo, function(w) heard[#heard + 1] = w end)
  eq(stand and stand.tutorial3, "wally", "WALLY: the stand-in says WALLY's")
  check(taken, "WALLY: solo takes it (" .. table.concat(warns, " / ") .. ")")
  local create = R.lastCreate()
  eq(create and create.tutorial, "wally", "WALLY: the referee plays BATTLE_TYPE_WALLY_TUTORIAL")
  local a = create and create.sides.a[1]
  eq(a and a.name, "WALLY", "WALLY: side a is WALLY's")
  eq(a and a.noBattler, nil, "WALLY: ...with a battler")
  eq(a and a.mons and #a.mons, 1, "WALLY: ...his ZIGZAGOON")
  eq(a and a.mons and a.mons[1].species, "ZIGZAGOON", "WALLY: ...that one")
  eq(a and a.bag and #a.bag, 2, "WALLY: ...and his bag")
  local t = lastScreenTutorial()
  eq(t and t.kind, "wally", "WALLY: the screen is told")
  eq(t and t.backPic, "wally", "WALLY: ...his back pic by the engine's profile key")
  eq(t and t.prompt, "gText_WhatWillWallyDo", "WALLY: ...his prompt")
  eq(R.lastScreen().noOwnBattler, nil, "WALLY: ...and his ZIGZAGOON fights")
  local sim = solo.sim
  local fight = solo.fight
  check(R.drive(solo), "WALLY: played to the end with nobody pressing anything")
  -- The kind's half of contract C-W (WallyHandleActions): FIGHT, FIGHT, the
  -- throw -- its own action -- on turn 3, the ball on turn 4.  Whether the
  -- referee takes `wallyThrow` is BattleSim3's (wave 4b R4); a referee that
  -- refuses it gets FIGHT for the turn instead, and the ball still comes on
  -- turn 4.
  local autos = tutLog("auto")
  eq(autos[1] and autos[1][2].action, "fight", "WALLY: turn 1 FIGHT")
  eq(autos[1] and autos[1][2].move, 0, "WALLY: ...move slot 0 (TACKLE)")
  eq(autos[2] and autos[2][2].action, "fight", "WALLY: turn 2 FIGHT")
  eq(autos[2] and autos[2][3], 2, "WALLY: ...on turn 2")
  eq(autos[3] and autos[3][2].action, "wallyThrow", "WALLY: turn 3 the throw, its own action (B_ACTION_WALLY_THROW)")
  eq(autos[3] and autos[3][3], 3, "WALLY: ...on turn 3")
  local last = autos[#autos]
  eq(last and last[2].action, "item", "WALLY: then the ball")
  eq(last and tonumber(last[2].item), 4, "WALLY: ...a POKé BALL")
  eq(last and last[3], 4, "WALLY: ...on turn 4")
  eq(#tutLog("wally"), 0, "WALLY: the screen's own wallyThrow3 is not called (the referee's event plays it)")
  for _, e in ipairs(autos) do
    check(not (e[4] and e[4].afterCommand), "WALLY: no sub-menu voice-over rides his walk")
  end
  local o = sim:outcome()
  eq(o and o.how, "catch", "WALLY: the RALTS is caught")
  eq(o and o.given, false, "WALLY: ...and given to nobody")
  eq(table.concat(heard, ","), "caught", "WALLY: done('caught')")
  check(R.countIn(fight.textLog, "WALLYFOE used GROWL") >= 2, "WALLY: the foe acts on turns 1 and 2")
  check(R.countIn(fight.textLog, "ZIGZAGOON used TACKLE") >= 2, "WALLY: ...his two TACKLEs")
  check(textIdx(fight, "WALLY used") ~= nil, "WALLY: 'WALLY used ...'")
  eq(R.FakeBag.get(R.session().bag, 4), 2, "WALLY: the player's balls are untouched")
  eq(#R.session().party, 1, "WALLY: nothing joins the party")
  local seen = false
  for _, s in ipairs(R.FakeDex.seen) do if s.species == WALLYFOE then seen = true end end
  check(seen, "WALLY: Emerald marks the RALTS seen (no WALLY_TUTORIAL exclusion)")
  check(not R.contains(R.fieldCalls(), "respawn"), "WALLY: no whiteout")
end)

-- ===================================================================
-- 4. the POKe DUDE
-- ===================================================================

local function pdTexts(script, n)
  for i = 0, n - 1 do R.TEXT[("PDTEXT_%d_%d"):format(script, i)] = ("PD%d LINE %d"):format(script, i) end
end

block("the POKe DUDE: BATTLE", function()
  R.newGame("firered")
  resetTut()
  pdTexts(0, 4)
  local mine = mon(4, 20, { moves = { 33 } })
  local playerParty = { mine }
  R.session().party = playerParty
  local exp0, hp0 = mine.exp, mine.hp
  R.FakeBag.add(R.session().bag, 4, 2)
  local codes = {}
  local solo = R.newSolo()
  local stand, taken = teachyDoor(solo, 0, function(code) codes[#codes + 1] = code end)
  check(stand ~= nil and taken, "BATTLE: the TEACHY TV's demonstration is taken ("
    .. table.concat(warns, " / ") .. ")")
  eq(stand and stand.tutorial3, "pokedude", "BATTLE: the POKe DUDE's")
  -- The door, as the engine's own start: the music, the transition, then the
  -- TEACHY TV off the stack and his bag and party in before solo is asked.
  eq(songs[1], "MUS_VS_WILD", "BATTLE: the wild battle music first (PlayMapChosenOrBattleBGM)")
  eq(FakeTransition.log[1] and FakeTransition.log[1].id, 9,
     "BATTLE: the battle basics' transition, WHITE_BARS_FADE (pret teachy_tv.c:1172)")
  eq(FakeTransition.log[1] and FakeTransition.log[1].opts.overUi, true, "BATTLE: ...over the TEACHY TV")
  eq(door.atTake and door.atTake.depth, 0, "BATTLE: solo is asked over an empty stack (TeachyTvFree)")
  eq(door.atTake and door.atTake.tv, false, "BATTLE: ...the TEACHY TV lifted off")
  eq(door.atTake and door.atTake.bagOpen, false, "BATTLE: ...the bag menu hidden")
  eq(door.atTake and door.atTake.party, stand.playerParty, "BATTLE: ...his party in")
  check(R.Gen3Ui.has(solo.fight), "BATTLE: the fight's screen is the stack's")
  eq(R.Stack.depth(), 1, "BATTLE: ...and the only layer on it")
  local dude = stand.playerParty[1]
  local foe = stand.enemyParty[1]
  local dudeExp0 = dude.exp
  local create = R.lastCreate()
  eq(create and create.tutorial, "pokedude", "BATTLE: the referee plays BATTLE_TYPE_POKEDUDE")
  local a = create and create.sides.a[1]
  eq(a and a.name, "The POKé DUDE", "BATTLE: side a is the POKe DUDE's")
  eq(a and a.mons and a.mons[1] and a.mons[1].species, "PDRAT", "BATTLE: ...with his monster, not the player's")
  eq(R.session().party, stand.playerParty, "BATTLE: his party is the session's while the fight runs")
  local t = lastScreenTutorial()
  eq(t and t.kind, "pokedude", "BATTLE: the screen is told")
  eq(t and t.backPic, "TRAINER_BACK_PIC_POKEDUDE", "BATTLE: ...his back pic")
  eq(t and t.prompt, "gText_WhatWillPkmnDo", "BATTLE: ...the ordinary prompt")
  eq(solo.fight.mine and solo.fight.mine[1] and solo.fight.mine[1].species, "PDRAT",
     "BATTLE: the screen's own party is his")
  local sim = solo.sim
  local fight = solo.fight
  check(R.drive(solo), "BATTLE: played to the end with nobody pressing anything")
  local autos = tutLog("auto")
  eq(#autos, 2, "BATTLE: two turns")
  for i = 1, #autos do
    eq(autos[i][2].action, "fight", "BATTLE: turn " .. i .. " FIGHT")
    eq(autos[i][2].move, 2, "BATTLE: ...move slot 2 (sInputScripts_ChooseMove_Battle)")
  end
  local log = fight.textLog
  local v0, v1, v2, v3 = textIdx(fight, "VO:PD0 LINE 0"), textIdx(fight, "VO:PD0 LINE 1"),
    textIdx(fight, "VO:PD0 LINE 2"), textIdx(fight, "VO:PD0 LINE 3")
  local foeUsed = textIdx(fight, "PDBIRD used LEVELHIT")
  check(v0 and v1 and v2 and v3, "BATTLE: all four voice-overs")
  check(v0 and foeUsed and v0 < foeUsed, "BATTLE: line 0 at the first menu")
  check(v1 and foeUsed and v1 + 1 == foeUsed, "BATTLE: line 1 right before the foe's first move line")
  check(v2 and v1 and v2 > v1, "BATTLE: line 2 at the second menu")
  local gained = R.indexIn(log, "gained", v2)
  check(v3 and v3 > v2 and (gained == nil or v3 < gained), "BATTLE: line 3 before the EXP line")
  eq(R.countIn(log, "PDBIRD used LEVELHIT"), 1, "BATTLE: the foe moves once (its slot 2)")
  eq(sim:outcome() and sim:outcome().how, "ko", "BATTLE: the POKe DUDE wins")
  eq(table.concat(codes, ","), "1", "BATTLE: the TEACHY TV hears WON")
  eq(R.session().party, playerParty, "BATTLE: the player's party is back")
  eq(mine.exp, exp0, "BATTLE: ...no EXP of the demonstration's")
  eq(mine.hp, hp0, "BATTLE: ...and untouched")
  check(dude.exp > dudeExp0, "BATTLE: the EXP went to his monster (pret Cmd_getexp on gPlayerParty)")
  eq(foe.species, PDBIRD, "BATTLE: the foe is the demonstration's")
  eq(R.FakeBag.get(R.session().bag, 4), 2, "BATTLE: the player's bag is back")
  eq(R.session().teachyBagBackup, nil, "BATTLE: ...and the TEACHY TV's backup let go")
  eq(teachyLog[1] and teachyLog[1][1], "init", "BATTLE: his bag went in (InitPokedudeBag)")
  eq(teachyLog[1] and teachyLog[1][2], 0, "BATTLE: ...for this demonstration")
  for _, s in ipairs(R.FakeDex.seen) do
    check(s.species ~= PDBIRD, "BATTLE: the foe is not marked seen (POKEDUDE)")
  end
  check(not R.contains(R.fieldCalls(), "respawn"), "BATTLE: no whiteout")
  check(R.Stack.has("teachy_tv"), "BATTLE: the TEACHY TV is back on the stack")
  eq(BagMenu.open, true, "BATTLE: ...and its bag menu")
  eq(R.spaceCalls(), 0, "BATTLE: no map resume scripts (back to the TEACHY TV, not the field)")
  eq(#R.effectsOf("questlog"), 0, "BATTLE: no quest-log scene (pret quest_log_battle.c:14)")
  eq(#cartStarts, 0, "BATTLE: the cart's own demonstration never ran")
end)

block("the POKe DUDE: STATUS", function()
  R.newGame("firered")
  resetTut()
  pdTexts(1, 5)
  R.session().party = { mon(4, 20, { moves = { 33 } }) }
  local codes = {}
  local solo = R.newSolo()
  local stand, taken = teachyDoor(solo, 1, function(code) codes[#codes + 1] = code end)
  check(stand ~= nil and taken, "STATUS: taken (" .. table.concat(warns, " / ") .. ")")
  local fight = solo.fight
  check(R.drive(solo), "STATUS: played out")
  local autos = tutLog("auto")
  eq(autos[1] and autos[1][2].action, "fight", "STATUS: turn 1 FIGHT")
  eq(autos[2] and autos[2][2].action, "item", "STATUS: turn 2 BAG")
  eq(autos[2] and tonumber(autos[2][2].item), 14, "STATUS: ...the ANTIDOTE (Task_Bag_TeachyTvStatus)")
  eq(autos[2] and autos[2][2].slot, 0, "STATUS: ...on the battler out")
  eq(autos[3] and autos[3][2].action, "fight", "STATUS: turn 3 FIGHT")
  local says = tutLog("say")
  eq(#says, 4, "STATUS: four lines (the first prompt's header is NULL)")
  eq(says[1] and says[1][2], "PD1 LINE 1", "STATUS: line 1 first")
  eq(says[1] and says[1][3] and says[1][3].lit, "ally", "STATUS: ...with the player's healthbox lit")
  eq(says[2] and says[2][2], "PD1 LINE 2", "STATUS: line 2 (the bag)")
  eq(says[3] and says[3][2], "PD1 LINE 3", "STATUS: line 3")
  eq(says[4] and says[4][2], "PD1 LINE 4", "STATUS: line 4 (the win)")
  local v3 = textIdx(fight, "VO:PD1 LINE 3")
  local foeUsed = R.indexIn(fight.textLog, "PDODD used TACKLE")
  check(v3 and foeUsed and v3 + 1 == foeUsed, "STATUS: line 3 right before the foe's move after the ANTIDOTE")
  local poisoned = R.indexIn(fight.textLog, "PDODD used TOXDUST")
  check(poisoned ~= nil and poisoned < (v3 or 0), "STATUS: the foe's TOXDUST first (slot 2), no line for it")
  eq(table.concat(codes, ","), "1", "STATUS: WON")
end)

block("the POKe DUDE: CATCHING", function()
  R.newGame("firered")
  resetTut()
  pdTexts(3, 6)
  local playerParty = { mon(4, 20, { moves = { 33 } }) }
  R.session().party = playerParty
  R.FakeBag.add(R.session().bag, 4, 1)
  local codes = {}
  local solo = R.newSolo()
  local stand, taken = teachyDoor(solo, 3, function(code) codes[#codes + 1] = code end)
  check(stand ~= nil and taken, "CATCHING: taken (" .. table.concat(warns, " / ") .. ")")
  local sim, fight = solo.sim, solo.fight
  check(R.drive(solo), "CATCHING: played out")
  local autos = tutLog("auto")
  eq(#autos, 3, "CATCHING: three turns")
  eq(autos[1] and autos[1][2].move, 0, "CATCHING: turn 1 move slot 0")
  eq(autos[2] and autos[2][2].move, 2, "CATCHING: turn 2 move slot 2 (the sleep move)")
  eq(autos[3] and autos[3][2].action, "item", "CATCHING: turn 3 BAG")
  eq(autos[3] and tonumber(autos[3][2].item), 4, "CATCHING: ...the POKé BALL (Task_Bag_TeachyTvCatching)")
  eq(autos[3] and autos[3][2].slot, nil, "CATCHING: ...thrown, not used on a monster")
  local seq = {}
  for _, e in ipairs(tutLog("say")) do seq[#seq + 1] = e[2]:match("LINE (%d)") end
  eq(table.concat(seq, ","), "0,2,3,4,5", "CATCHING: lines 0, 2, 3, 4, 5 (line 1's header is NULL)")
  local asleep = R.indexIn(fight.textLog, "PDPUFF is fast asleep")
  local v3 = textIdx(fight, "VO:PD3 LINE 3")
  check(v3 and asleep and v3 + 1 == asleep, "CATCHING: line 3 right before 'is fast asleep'")
  local gotcha = R.indexIn(fight.textLog, "Gotcha!")
  local v5 = textIdx(fight, "VO:PD3 LINE 5")
  check(v5 and gotcha and v5 > gotcha, "CATCHING: line 5 after 'Gotcha!' (endlinkbattle)")
  local o = sim:outcome()
  eq(o and o.how, "catch", "CATCHING: the forced catch")
  eq(o and o.given, false, "CATCHING: ...nothing given")
  eq(table.concat(codes, ","), "7", "CATCHING: the TEACHY TV hears CAUGHT (the done word 'catch')")
  eq(R.session().party, playerParty, "CATCHING: the player's party is back")
  eq(#playerParty, 1, "CATCHING: ...nothing joined it")
  eq(R.FakeBag.get(R.session().bag, 4), 1, "CATCHING: the player's ball is untouched")
end)

block("the POKe DUDE: the done word", function()
  R.newGame("firered")
  resetTut()
  R.session().party = { mon(4, 20, { moves = { 33 } }) }
  local heard = {}
  local solo = R.newSolo()
  local stand = CoopField.pokedudeStand3(R.session(), 3, { onDone = function() end }, { game = R.game() })
  local enc = {}
  for k, v in pairs(stand.encounter) do enc[k] = v end
  enc.mon = stand.enemyParty[1]
  -- A stand whose party nobody put in place is no demonstration of solo's.
  eq(solo:fromGen3Encounter(R.game(), enc, R.standOpts(stand, function() end)), false,
     "door: a POKe DUDE stand without his party in place is the cart's")
  check(stand:borrowParty3(stand.playerParty), "done word: his party in, as the door puts it")
  check(solo:fromGen3Encounter(R.game(), enc, R.standOpts(stand, function(w) heard[#heard + 1] = w end)),
        "done word: taken")
  tut.sim = solo.sim
  check(R.drive(solo), "done word: played out")
  eq(table.concat(heard, ","), "catch", "done word: the catching demo's `done` hears 'catch'")
  stand:giveBack3()
end)

block("the POKe DUDE: a failed borrow falls back", function()
  R.newGame("firered")
  resetTut()
  local playerParty = { mon(4, 20, { moves = { 33 } }) }
  R.session().party = playerParty
  -- A bag already swapped (borrowTeachyBag3 refuses) must not start the
  -- demonstration against the player's own party.
  R.session().teachyBagBackup = { pockets = R.session().bag.pockets }
  local before = #cartStarts
  local stand, taken = teachyDoor(R.newSolo(), 3, function() end)
  eq(stand, nil, "borrow fail: the demonstration is not taken")
  eq(taken, nil, "borrow fail: ...and is not offered")
  check(#cartStarts == before + 1, "borrow fail: the cart's own demonstration runs")
  eq(R.session().party, playerParty, "borrow fail: the player's party stays")
  eq(cartStarts[#cartStarts].party, playerParty, "borrow fail: the cart sees the player's party")
  R.session().teachyBagBackup = nil
end)

-- Contract C-V: the CHOOSEMOVE / OPENBAG / CHOOSEPOKEMON voice-overs between
-- the command and its sub-menu, when the screen can hold its walk for them
-- (`afterCommand`, `tutorialIdle3`); before the walk when it cannot.
block("the POKe DUDE: the sub-menu voice-overs", function()
  R.newGame("firered")
  resetTut()
  pdTexts(1, 5)
  R.session().party = { mon(4, 20, { moves = { 33 } }) }
  local solo = R.newSolo()
  local _, taken = teachyDoor(solo, 1, function() end)
  check(taken, "C-V: taken")
  check(R.drive(solo), "C-V: played out")
  -- STATUS turn 2: line 1 (CHOOSEACTION, the lit healthbox) before the walk,
  -- line 2 (OPENBAG) once BAG is picked, before the bag opens.
  local seq = {}
  for _, e in ipairs(tut.log) do
    if e[1] == "say" then seq[#seq + 1] = "say" .. e[2]:match("LINE (%d)")
    elseif e[1] == "auto" then seq[#seq + 1] = "auto:" .. e[2].action
    elseif e[1] == "after" then seq[#seq + 1] = "after" end
  end
  local joined = table.concat(seq, ",")
  check(joined:find("say1,auto:item,after,say2", 1, true) ~= nil,
        "C-V: the OPENBAG line rides the walk, after BAG is picked (" .. joined .. ")")
  local fightAutos = 0
  for _, e in ipairs(tutLog("auto")) do
    if e[2].action == "fight" then
      fightAutos = fightAutos + 1
      check(e[4] == nil or e[4].afterCommand == nil, "C-V: no CHOOSEMOVE line due, no afterCommand")
    end
  end
  check(fightAutos >= 2, "C-V: ...on the FIGHT turns either")

  -- A screen that cannot hold its walk hears the line before it.
  R.newGame("firered")
  resetTut()
  pdTexts(1, 5)
  R.session().party = { mon(4, 20, { moves = { 33 } }) }
  Mediated.tutorialIdle3 = nil
  local plain = R.newSolo()
  local _, taken2 = teachyDoor(plain, 1, function() end)
  check(taken2, "C-V fallback: taken")
  check(R.drive(plain), "C-V fallback: played out")
  seq = {}
  for _, e in ipairs(tut.log) do
    if e[1] == "say" then seq[#seq + 1] = "say" .. e[2]:match("LINE (%d)")
    elseif e[1] == "auto" then seq[#seq + 1] = "auto:" .. e[2].action
    elseif e[1] == "after" then seq[#seq + 1] = "after" end
  end
  joined = table.concat(seq, ",")
  check(joined:find("say1,say2,auto:item", 1, true) ~= nil,
        "C-V fallback: both lines before the walk, in order (" .. joined .. ")")
  check(not joined:find("after", 1, true), "C-V fallback: no afterCommand asked of it")
  installScreen()
end)

-- Contract C-Q: B held quits a demonstration on the spot as DREW.
block("the POKe DUDE: quit", function()
  R.newGame("firered")
  resetTut()
  pdTexts(0, 4)
  local mine = mon(4, 20, { moves = { 33 } })
  local playerParty = { mine }
  R.session().party = playerParty
  R.FakeBag.add(R.session().bag, 4, 2)
  local codes = {}
  local solo = R.newSolo()
  local stand, taken = teachyDoor(solo, 0, function(code)
    codes[#codes + 1] = { code = code, party = R.session().party, tv = R.Stack.has("teachy_tv"),
                          balls = R.FakeBag.get(R.session().bag, 4) }
  end)
  check(taken, "quit: taken")
  local t = lastScreenTutorial()
  check(t and type(t.quit) == "function", "quit: the screen is handed `tutorial.quit` for the POKe DUDE")
  check(R.untilChoose(solo), "quit: the menu comes up")
  local sim, fight = solo.sim, solo.fight
  local turn, phase = sim.turn, sim.phase
  local dude = stand.playerParty[1]
  local dudeHp = dude.hp
  t.quit("battle")
  eq(solo.fight, nil, "quit: the fight is over at once")
  eq(sim.turn, turn, "quit: no further turn")
  eq(sim.phase, phase, "quit: ...the referee left where it stood")
  eq(R.Gen3Ui.has(fight), false, "quit: the screen is off")
  eq(#codes, 1, "quit: the TEACHY TV is answered once")
  eq(codes[1] and codes[1].code, 3, "quit: ...with B_OUTCOME_DREW (back to its program list)")
  eq(codes[1] and codes[1].party, playerParty, "quit: ...the player's party back first")
  eq(codes[1] and codes[1].tv, true, "quit: ...the TEACHY TV back on the stack")
  eq(codes[1] and codes[1].balls, 2, "quit: ...and the player's bag")
  eq(R.session().battleOutcome, R.CODES.draw, "quit: gBattleOutcome = B_OUTCOME_DREW")
  eq(dude.hp, dudeHp, "quit: nothing written back")
  eq(#R.effectsOf("questlog"), 0, "quit: no quest log")
  eq(#R.effectsOf("emit"), 0, "quit: no battle.ended")
  eq(R.spaceCalls(), 0, "quit: no map resume scripts")
  for _, sseen in ipairs(R.FakeDex.seen) do check(sseen.species ~= PDBIRD, "quit: no dex") end
  t.quit("battle")
  eq(#codes, 1, "quit: a second quit does nothing")
  -- B in his bag or party menu: the same way out, gBattleOutcome left alone.
  R.newGame("firered")
  resetTut()
  R.session().party = playerParty
  R.session().battleOutcome = 99
  codes = {}
  local menuSolo = R.newSolo()
  local _, taken2 = teachyDoor(menuSolo, 1, function(code) codes[#codes + 1] = { code = code } end)
  check(taken2, "quit (menu): taken")
  check(R.untilChoose(menuSolo), "quit (menu): the menu comes up")
  lastScreenTutorial().quit("bag")
  eq(menuSolo.fight, nil, "quit (menu): over at once")
  eq(codes[1] and codes[1].code, 3, "quit (menu): the TEACHY TV hears DREW (its resume to the list)")
  eq(R.session().battleOutcome, 99, "quit (menu): gBattleOutcome left alone")
  eq(R.session().party, playerParty, "quit (menu): the player's party back")
  -- Only the POKe DUDE's demonstrations can be quit.
  R.newGame("firered")
  resetTut()
  R.session().party = { mon(4, 20, { moves = { 33 } }) }
  local old = R.newSolo()
  oldManDoor(old, function() end)
  eq(lastScreenTutorial() and lastScreenTutorial().quit, nil, "quit: the old man's tutorial has no quit")
  old:reset()
end)

block("the POKe DUDE: MATCHUPS", function()
  R.newGame("firered")
  resetTut()
  pdTexts(2, 7)
  R.session().party = { mon(4, 20, { moves = { 33 } }) }
  local solo = R.newSolo()
  local stand, taken = teachyDoor(solo, 2, function() end)
  check(stand ~= nil and taken, "MATCHUPS: taken (" .. table.concat(warns, " / ") .. ")")
  local fight = solo.fight
  for _ = 1, 400 do
    solo:update(0.5, R.game())
    if not solo.fight then break end
    solo.fight:update(2.0)
    if #tutLog("auto") >= 3 then break end
  end
  local autos = tutLog("auto")
  eq(autos[1] and autos[1][2].action, "fight", "MATCHUPS: turn 1 FIGHT")
  eq(autos[1] and autos[1][2].move, 2, "MATCHUPS: ...slot 2")
  eq(autos[2] and autos[2][2].action, "switch", "MATCHUPS: turn 2 POKéMON")
  eq(autos[2] and autos[2][2].slot, 1, "MATCHUPS: ...SHIFT to the second row (Task_PartyMenu_PokedudeStep)")
  eq(autos[3] and autos[3][2].action, "fight", "MATCHUPS: turn 3 FIGHT")
  eq(autos[3] and autos[3][2].move, 0, "MATCHUPS: ...slot 0")
  local seq = {}
  for _, e in ipairs(tutLog("say")) do seq[#seq + 1] = e[2]:match("LINE (%d)") end
  eq(table.concat(seq, ",", 1, math.min(#seq, 6)), "0,1,2,3,4,5",
     "MATCHUPS: lines 0..5 in order (the foe's move, the prompt, the party, the foe's, the prompt, the moves)")
  local v0 = textIdx(fight, "VO:PD2 LINE 0")
  local foeUsed = R.indexIn(fight.textLog, "PDODD used")
  check(v0 and foeUsed and v0 + 1 == foeUsed, "MATCHUPS: line 0 right before the foe's first move")
  eq(solo.sim and solo.sim.byId.solo_player.active, 2, "MATCHUPS: the second monster is out")
  solo:reset()
end)

-- ===================================================================
-- 5. the hand-backs
-- ===================================================================

block("a hand-back", function()
  R.newGame("firered")
  resetTut()
  local playerParty = { mon(4, 20, { moves = { 33 } }) }
  R.session().party = playerParty
  R.FakeBag.add(R.session().bag, 4, 2)
  local solo = R.newSolo()
  local stand, taken = teachyDoor(solo, 0, function() end)
  check(taken, "hand-back: taken")
  check(R.untilChoose(solo), "hand-back: the menu comes up")
  eq(R.session().party, stand.playerParty, "hand-back: his party is in")
  solo:reset()
  local cart = cartStarts[1]
  check(cart ~= nil, "hand-back: the TEACHY TV's own start is called")
  eq(cart and cart.script, 0, "hand-back: ...for the same demonstration")
  eq(cart and cart.party, playerParty, "hand-back: ...with the player's party back")
  eq(cart and cart.tv, true, "hand-back: ...the TEACHY TV back on the stack")
  eq(cart and cart.bagOpen, true, "hand-back: ...and its bag menu")
  eq(cart and cart.backup, nil, "hand-back: ...nothing left swapped for the cart to swap again")
  eq(R.FakeBag.get(R.session().bag, 4), 2, "hand-back: the player's bag")
  eq(stand.partyBorrow3, nil, "hand-back: nothing left borrowed")
end)

block("a divert that fails after the party went in", function()
  R.newGame("firered")
  resetTut()
  local playerParty = { mon(4, 20, { moves = { 33 } }) }
  R.session().party = playerParty
  local solo = R.newSolo()
  local partyAtCreate = nil
  R.onCreate = function()
    partyAtCreate = R.session().party
    error("synthetic referee failure", 0)
  end
  local stand, taken, started = teachyDoor(solo, 0, function() end)
  R.onCreate = nil
  eq(started, true, "failed divert: the start answers as started (the engine's own does)")
  check(not taken, "failed divert: not taken")
  eq(partyAtCreate, stand and stand.playerParty, "failed divert: his party had gone in before the referee was built")
  eq(R.session().party, playerParty, "failed divert: Stand:giveBack3 puts the player's party back")
  local cart = cartStarts[1]
  eq(cart and cart.party, playerParty, "failed divert: the cart's demonstration starts on the player's party")
  eq(cart and cart.tv, true, "failed divert: ...with the TEACHY TV back on the stack")
  check(R.contains(warns, "TEACHY TV divert failed"), "failed divert: said once")
  solo:reset()
end)

block("a screen without the tutorial walk", function()
  R.newGame("firered")
  resetTut()
  R.session().party = { mon(4, 20, { moves = { 33 } }) }
  Mediated.autoplay3 = nil
  local heard = {}
  local solo = R.newSolo()
  local _, taken = oldManDoor(solo, function(w) heard[#heard + 1] = w end)
  check(taken, "no walk: taken")
  check(R.drive(solo), "no walk: played out, the choice filed straight through the screen")
  eq(table.concat(heard, ","), "caught", "no walk: the WEEDLE caught")
  installScreen()
end)

block("a refused input is replanned", function()
  R.newGame("emerald")
  resetTut()
  R.session().party = { mon(263, 7, { moves = { 33 } }) }
  -- The screen files nothing on the first walk and says so.
  local refusedOnce = false
  Mediated.autoplay3 = function(self, choice, onFiled)
    local copy = {}
    for k, v in pairs(choice) do copy[k] = v end
    tut.log[#tut.log + 1] = { "auto", copy, tut.sim and tut.sim.turn or nil }
    if not refusedOnce then
      refusedOnce = true
      if onFiled then onFiled(false, copy) end
      return true
    end
    local sent = self:sendChoice(copy)
    if onFiled then onFiled(sent, copy) end
    return true
  end
  local solo = R.newSolo()
  local _, taken = wallyDoor(solo, function() end)
  check(taken, "replan: taken")
  check(R.drive(solo), "replan: played out")
  local autos = tutLog("auto")
  check(#autos >= 2 and autos[2][3] == 1, "replan: the refused turn is walked again on the same turn")
  eq(autos[2] and autos[2][2].action, "fight", "replan: ...as FIGHT")
  eq(autos[2] and autos[2][2].move, 0, "replan: ...with the first move that has PP")
  eq(#tutLog("wally"), 0, "replan: the screen's wallyThrow3 is never the kind's to call")
  local throws = 0
  for _, e in ipairs(autos) do if e[2].action == "wallyThrow" then throws = throws + 1 end end
  check(throws >= 1, "replan: the throw is still walked on its turn")
  installScreen()

  -- The old man has only his ball: a refused one is his RUN, which a seat
  -- with no battler always gets away with -- the fight never freezes.
  R.newGame("firered")
  resetTut()
  R.session().party = { mon(4, 20, { moves = { 33 } }) }
  Mediated.autoplay3 = function(self, choice, onFiled)
    local copy = {}
    for k, v in pairs(choice) do copy[k] = v end
    tut.log[#tut.log + 1] = { "auto", copy, tut.sim and tut.sim.turn or nil }
    if copy.action == "item" then
      if onFiled then onFiled(false, copy) end
      return true
    end
    local sent = self:sendChoice(copy)
    if onFiled then onFiled(sent, copy) end
    return true
  end
  local heard = {}
  local old = R.newSolo()
  local _, taken2 = oldManDoor(old, function(w) heard[#heard + 1] = w end)
  check(taken2, "replan (old man): taken")
  check(R.drive(old), "replan (old man): played out")
  local autos2 = tutLog("auto")
  eq(autos2[2] and autos2[2][2].action, "run", "replan (old man): his refused ball becomes his RUN")
  eq(table.concat(heard, ","), "run", "replan (old man): done('run')")
  installScreen()
end)

-- ===================================================================
-- 6. the real screen
-- ===================================================================
--
-- Every tutorial fight driven to its end through MediatedBattle's own
-- tutorial methods (UM4 / wave 4b SCR: `autoplay3` with `opts.instant`, the
-- POKe DUDE's voice-over box, WALLY's recall on the referee's `wallyThrow`
-- event, the B-held fade and `tutorial.quit`) over the referee's own WALLY
-- throw (wave 4b R4).  Red here says which half is missing, by name.

local function realScreen()
  Mediated.sayTutorial3 = function(self, text, opts)
    tut.log[#tut.log + 1] = { "say", text, opts }
    return REAL.sayTutorial3(self, text, opts)
  end
  Mediated.autoplay3 = function(self, choice, onFiled, opts)
    local copy = {}
    for k, v in pairs(choice) do copy[k] = v end
    tut.log[#tut.log + 1] = { "auto", copy, tut.sim and tut.sim.turn or nil, opts }
    local o = {}
    for k, v in pairs(opts or {}) do o[k] = v end
    o.instant = true
    return REAL.autoplay3(self, choice, onFiled, o)
  end
  Mediated.wallyThrow3, Mediated.tutorialIdle3 = REAL.wallyThrow3, REAL.tutorialIdle3
end

local eventsSeen = {}
do
  local realOnEvent = Mediated.onEvent
  Mediated.onEvent = function(self, msg)
    if type(msg) == "table" then eventsSeen[#eventsSeen + 1] = msg.t end
    return realOnEvent(self, msg)
  end
end
local function sawEvent(t)
  for _, e in ipairs(eventsSeen) do if e == t then return true end end
  return false
end

local function realDrive(solo) return R.drive(solo, nil, 3000) end

block("real screen: the methods are there", function()
  check(type(REAL.autoplay3) == "function", "real screen: MediatedBattle:autoplay3 (UM4)")
  check(type(REAL.sayTutorial3) == "function", "real screen: MediatedBattle:sayTutorial3 (UM4)")
  check(type(REAL.tutorialIdle3) == "function", "real screen: MediatedBattle:tutorialIdle3 (wave 4b SCR, C-V)")
end)

if type(REAL.autoplay3) == "function" then
  block("real screen: the old man", function()
    R.newGame("firered")
    resetTut()
    realScreen()
    R.session().party = { mon(4, 20, { moves = { 33 } }) }
    local heard = {}
    local solo = R.newSolo()
    local _, taken = oldManDoor(solo, function(w) heard[#heard + 1] = w end)
    check(taken, "real old man: taken")
    check(realDrive(solo), "real old man: played to the end")
    eq(table.concat(heard, ","), "caught", "real old man: done('caught')")
    installScreen()
  end)

  -- WALLY's throw turn both ways of the speed order (C-W): a slower RALTS
  -- never acts on turn 3 (its action is the cancelled second one); a faster
  -- one acts first, then the throw.
  for _, case in ipairs({ { label = "ZIGZAGOON first", spe = 40, growls = 2 },
                          { label = "RALTS first", spe = 250, growls = 3 } }) do
    block("real screen: WALLY, " .. case.label, function()
      R.newGame("emerald")
      resetTut()
      eventsSeen = {}
      realScreen()
      P3._stats[WALLYFOE] = base(250, 25, 200, case.spe, 45, 35)
      R.session().party = { mon(263, 7, { moves = { 33 } }) }
      local heard = {}
      local solo = R.newSolo()
      local _, taken = wallyDoor(solo, function(w) heard[#heard + 1] = w end)
      check(taken, "real WALLY (" .. case.label .. "): taken")
      local fight = solo.fight
      check(realDrive(solo), "real WALLY (" .. case.label .. "): played to the end")
      eq(table.concat(heard, ","), "caught", "real WALLY (" .. case.label .. "): done('caught')")
      check(sawEvent("wallyThrow"), "real WALLY (" .. case.label .. "): the referee's `wallyThrow` event (wave 4b R4)")
      eq(R.countIn(fight.textLog, "WALLYFOE used GROWL"), case.growls,
         "real WALLY (" .. case.label .. "): the RALTS acts " .. case.growls .. " times (the throw cancels the second action)")
      local autos = tutLog("auto")
      local refused = false
      for _, w in ipairs(warns) do if w:find("would not have been understood", 1, true) then refused = true end end
      check(not refused, "real WALLY (" .. case.label .. "): the wire takes `wallyThrow` (wave 4b R4)")
      eq(#autos, 4, "real WALLY (" .. case.label .. "): four walks, no replan")
      check(R.contains(fight.textLog, "STRINGID_YOUTHROWABALLNOWRIGHT"),
            "real WALLY (" .. case.label .. "): the recall's line is played off the event (wave 4b SCR)")
      P3._stats[WALLYFOE] = base(250, 25, 200, 40, 45, 35)
      installScreen()
    end)
  end

  for _, demo in ipairs({ { script = 0, label = "BATTLE", code = 1, lines = 4 },
                          { script = 1, label = "STATUS", code = 1, lines = 4 },
                          { script = 2, label = "MATCHUPS", code = 1, lines = 6 },
                          { script = 3, label = "CATCHING", code = 7, lines = 5 } }) do
    block("real screen: the POKe DUDE's " .. demo.label, function()
      R.newGame("firered")
      resetTut()
      realScreen()
      pdTexts(demo.script, 7)
      local playerParty = { mon(4, 20, { moves = { 33 } }) }
      R.session().party = playerParty
      local codes = {}
      local solo = R.newSolo()
      local _, taken = teachyDoor(solo, demo.script, function(code) codes[#codes + 1] = code end)
      check(taken, "real " .. demo.label .. ": taken")
      local sim = solo.sim
      check(realDrive(solo), "real " .. demo.label .. ": played to the end")
      eq(table.concat(codes, ","), tostring(demo.code), "real " .. demo.label .. ": the TEACHY TV hears its code")
      check(#tutLog("say") >= demo.lines, "real " .. demo.label .. ": the voice-overs were said")
      if demo.script == 2 then
        local switched = false
        for _, e in ipairs(tutLog("auto")) do if e[2].action == "switch" then switched = true end end
        check(switched, "real MATCHUPS: the switch is walked")
        local out = sim.byId.solo_player
        check(out and out.active == 2, "real MATCHUPS: ...and the second monster came in")
      end
      eq(R.session().party, playerParty, "real " .. demo.label .. ": the player's party is back")
      installScreen()
    end)
  end

  block("real screen: the POKe DUDE's B", function()
    R.newGame("firered")
    resetTut()
    realScreen()
    pdTexts(0, 4)
    local playerParty = { mon(4, 20, { moves = { 33 } }) }
    R.session().party = playerParty
    local codes = {}
    local solo = R.newSolo()
    local _, taken = teachyDoor(solo, 0, function(code) codes[#codes + 1] = code end)
    check(taken, "real B: taken")
    local sim = solo.sim
    local held = { pressed = {}, wasPressed = function(_, k) return k == "b" end,
                   isDown = function(_, k) return k == "b" end }
    local game = R.game()
    for _ = 1, 600 do
      if not solo.fight then break end
      solo:update(1 / 60, game)
      local f = solo.fight
      if not f then break end
      game.input = held
      f:update(1 / 60)
      game.input = R.fakeInput()
    end
    eq(solo.fight, nil, "real B: holding B ends the demonstration (wave 4b SCR, C-Q)")
    eq(table.concat(codes, ","), "3", "real B: ...as B_OUTCOME_DREW")
    eq(sim:outcome(), nil, "real B: ...the referee never ending it itself")
    eq(R.session().party, playerParty, "real B: the player's party is back")
    installScreen()
  end)
end

T.finish("gen3_solo_tutorial")
