-- Headless Gen 3 solo battles: the two first battles, the `firstBattle` kind
-- of src/Solo3/First.lua (contract C2 of docs/plans/gen3-solo-remaining-
-- fights.md; research §1.5, §2.5), through the real src/SoloBattle.lua core,
-- the real BattleSim3 referee, MediatedBattle's real single screen and
-- src/CoopField.lua's real stand-ins.  The rig is
-- tests/fixtures/gen3_solo_dbl_rig.lua.
--
--   1. the registry: the kind is found through mod:read at the first fight
--      that asks (SoloBattle.KIND_FILES3);
--   2. PROF. OAK's lab (FireRed / LeafGreen): `firstBattle = "oak"` on the
--      referee and the screen, his voice-over, the win; the loss that heals
--      the party with no whiteout and no money lost, the rival's win text,
--      `done("lose")` and never a halt; the saved song let go;
--   3. PROF. BIRCH's rescue (Emerald): `firstBattle = "birch"` and the
--      ZIGZAGOON on AI_FirstBattle, its held item rolled the cart's way; the
--      refused RUN in the cart's words (the text pack's, else the fallback),
--      the turn unspent; a SMOKE BALL and RUN AWAY still get away; a trap
--      holds the runner with its own line first; the flee at 20%; the win
--      with EXP and no TV; the loss with no whiteout and no heal;
--   4. the other shapes of either (Oak's as a wild, Birch's as a trainer) are
--      the cart's.
--
-- Run from the engine checkout root:
--
--   luajit mods/rby_mmo/tests/gen3_solo_first.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local check, eq = T.check, T.eq

local here = (debug.getinfo(1, "S").source:sub(2):match("(.+)[/\\]")) or "."
local R = dofile(here .. "/fixtures/gen3_solo_dbl_rig.lua")(T)

local Solo, CoopField = R.Solo, R.CoopField
local TRAINERS = R.TRAINERS
local mon, block = R.mon, R.block
local warns = R.warns

-- ===================================================================
-- the fixtures
-- ===================================================================

-- The rival in the lab: a RIVAL-class row (its placeholder name answered with
-- the player's rival's, Trainers.info), one monster.
local RIVAL = 600
TRAINERS[RIVAL] = { class = 81, className = "RIVAL", name = "RIVAL", pic = 7, gender = 0,
                    aiFlags = 1, items = { 0, 0, 0, 0 }, defeat = "TERRY: What?",
                    party = { { species = 4, level = 5, moves = { 33 } } } }

-- What the trainerbattle opcode hands the start for Oak's lab
-- (trainerbattle_earlyrival, RIVAL_BATTLE_TUTORIAL = 3: heal-after and the
-- tutorial bit; ops_a.lua's `firstBattle = tutorialBattle`).
local function oakOpts(extra)
  local o = { wild = false, trainerId = RIVAL, earlyRival = true, rivalFlags = 3,
              firstBattle = true, noWhiteout = true,
              defeatText = "TERRY: What?", victoryText = "TERRY: Yeah! Am I great or what?" }
  for k, v in pairs(extra or {}) do o[k] = v end
  return o
end

-- The trainerbattle opcode's continuation (ops_a.lua): the early rival's
-- VAR_RESULT (1 on a loss), the flag on anything else; whether the script
-- ran on after it.
local function opcode()
  local op = { heard = {} }
  function op.done(result)
    op.heard[#op.heard + 1] = result
    local lost = result == "lose" or result == "whiteout" or result == "blackout"
    op.varResult = lost and 1 or 0
    op.flag = not lost
    op.ranOn = R.FakeVm.halted == 0
  end
  return op
end

local function oakStand(opts)
  local foe = R.FakeTrainers.foeFromId(RIVAL)
  local stand, why = CoopField.trainerStand3(foe, opts, { game = R.game(), solo = true })
  return stand, foe, why
end

-- BattleBridge.startFirstBattle's foe and opts: a level-2 ZIGZAGOON with its
-- item zeroed (pret SetUpBattleVarsAndBirchZigzagoon), `firstBattleKind`.
local ZIGZAGOON = 263
local function birchStand(foeRow, done, extraOpts)
  local foe = { species = ZIGZAGOON, level = 2, item = 0 }
  for k, v in pairs(foeRow or {}) do foe[k] = v end
  local opts = { wild = true, firstBattleKind = "birch", done = done }
  for k, v in pairs(extraOpts or {}) do opts[k] = v end
  local stand, why = CoopField.wildStand3(foe, { game = R.game(), solo = true }, opts)
  return stand, foe, why
end

local function birchDone()
  local rec = { heard = {} }
  function rec.done(result) rec.heard[#rec.heard + 1] = result end
  return rec
end

-- A wild fight through the door: what src/Client.lua's offerFight3 hands solo
-- (the encounter carrying the stand-in's monster).
local function takeWild(solo, stand, foe, done)
  local enc = {}
  for k, v in pairs(foe) do enc[k] = v end
  enc.mon = stand.enemyParty[1]
  return solo:fromGen3Encounter(R.game(), enc, R.standOpts(stand, done))
end

local function said(fight, needle) return R.contains(fight and fight.textLog or {}, needle) end

-- ===================================================================
-- 1. the registry
-- ===================================================================

block("registry", function()
  eq(Solo.KIND_FILES3.firstBattle, "Solo3/First", "registry: the first battles' module is Solo3/First")
  local kind = Solo.kind3("firstBattle")
  check(type(kind) == "table", "registry: the kind is found through mod:read")
  check(R.contains(R.reads, "src/Solo3/First.lua"), "registry: ...by reading src/Solo3/First.lua")
  local First = R.need("Solo3/First")
  eq(kind, First.First, "registry: the kind is First.First")
  for name, fn in pairs(kind) do
    local known = false
    for _, hook in ipairs(Solo.KIND_HOOKS3) do if hook == name then known = true end end
    check(known and type(fn) == "function", "registry: '" .. tostring(name) .. "' is a hook the core calls")
  end
end)

-- ===================================================================
-- 2. PROF. OAK's lab
-- ===================================================================

block("Oak seated and won", function()
  R.newGame("firered", { rivalName = "TERRY" })
  local lead = mon(4, 5, { moves = { 300 } })
  R.session().party = { lead }
  local money = R.session().money
  local stand, foe, why = oakStand(oakOpts())
  check(stand ~= nil, "Oak: the stand-in is built (" .. tostring(why) .. ")")
  eq(stand and stand.kind3, "firstBattle", "Oak: ...a first battle")
  eq(stand and stand.firstBattle3, "oak", "Oak: ...Oak's")
  local solo = R.newSolo()
  local op = opcode()
  check(solo:fromGen3Trainer(R.game(), foe, R.standOpts(stand, op.done)),
        "Oak: solo takes the lab battle (" .. table.concat(warns, " / ") .. ")")
  local create, so = R.lastCreate(), R.lastScreen()
  eq(create and create.firstBattle, "oak", "Oak: the referee plays Oak's rules (firstBattle = 'oak')")
  eq(solo.sim and solo.sim.firstBattle, "oak", "Oak: ...and holds them")
  eq(so and so.firstBattle, "oak", "Oak: the screen is told (his voice-over)")
  local fight = solo.fight
  eq(fight and fight.firstBattle, "oak", "Oak: ...and the screen took it")
  eq(create and create.wildPick, nil, "Oak: a trainer's seat asks no wild move")
  local exp0 = lead.exp
  check(R.drive(solo, function(f) f:pickMove(1) end), "Oak: fought to the end")
  eq(table.concat(op.heard, ","), "win", "Oak: the opcode hears 'win'")
  eq(op.varResult, 0, "Oak: ...VAR_RESULT FALSE (the script reads nothing)")
  check(R.session().money > money, "Oak: the rival's prize is paid")
  check(lead.exp > exp0, "Oak: EXP")
  check(said(fight, "OAK: forPetesSake"), "Oak: his opening lesson")
  local log = fight.textLog
  local prize = R.indexIn(log, "STRINGID_PLAYERGOTMONEY|")
  local win = R.indexIn(log, "OAK: winEarnsPrize")
  check(win ~= nil, "Oak: his 'win' lesson")
  check(prize == nil or (win and win > prize), "Oak: ...after the prize line")
  local names = R.audioNames()
  local cleared = R.indexIn(names, "clearSavedSong")
  check(cleared ~= nil, "Oak: the saved song is let go (CB2_EndFirstBattle's Overworld_ClearSavedMusic)")
  check(cleared and R.indexIn(names, "restoreMapSong", cleared) ~= nil, "Oak: ...and the map's own plays")
  eq(R.FakeVm.halted, 0, "Oak: no script halted")
end)

block("Oak lost", function()
  R.newGame("firered", { rivalName = "TERRY" })
  local lead = mon(4, 5, { moves = { 45 } })
  R.session().party = { lead }
  local savedParty = TRAINERS[RIVAL].party
  TRAINERS[RIVAL].party = { { species = 151, level = 40, moves = { 300 } } }
  local money = R.session().money
  local stand, foe = oakStand(oakOpts())
  TRAINERS[RIVAL].party = savedParty
  local solo = R.newSolo()
  local op = opcode()
  check(solo:fromGen3Trainer(R.game(), foe, R.standOpts(stand, op.done)), "Oak lost: taken")
  local fight = solo.fight
  check(R.drive(solo, function(f) f:pickMove(1) end), "Oak lost: fought to the end")
  eq(table.concat(op.heard, ","), "lose", "Oak lost: the opcode hears 'lose' (VAR_RESULT TRUE)")
  eq(op.ranOn, true, "Oak lost: ...and the script runs on (never halted)")
  eq(R.FakeVm.halted, 0, "Oak lost: no halt")
  check(not R.contains(R.fieldCalls(), "respawn"), "Oak lost: no whiteout")
  eq(R.session().money, money, "Oak lost: no money lost")
  check(R.healCalls() >= 1, "Oak lost: the party is healed (RIVAL_BATTLE_HEAL_AFTER)")
  eq(lead.hp, lead.maxHp, "Oak lost: ...back to full")
  local victory = R.indexIn(fight.textLog, "TERRY: Yeah! Am I great or what?")
  check(victory ~= nil, "Oak lost: the rival's win text")
  local lose = R.indexIn(fight.textLog, "OAK: howDisappointing")
  check(lose ~= nil and victory ~= nil and lose > victory, "Oak lost: ...then Oak's 'lose' lesson")
  eq(R.countIn(fight.textLog, "STRINGID_PLAYERWHITEOUT"), 0, "Oak lost: no whiteout lines")
  check(R.contains(R.audioNames(), "clearSavedSong"), "Oak lost: the saved song is let go")
end)

-- ===================================================================
-- 3. PROF. BIRCH's rescue
-- ===================================================================

block("Birch seated", function()
  R.newGame("emerald")
  R.session().party = { mon(4, 5, { moves = { 300 } }) }
  R.heldQueue = { 139 }
  local stand, foe, why = birchStand(nil, nil)
  check(stand ~= nil, "Birch: the stand-in is built (" .. tostring(why) .. ")")
  eq(stand and stand.kind3, "firstBattle", "Birch: ...a first battle")
  eq(stand and stand.firstBattle3, "birch", "Birch: ...Birch's")
  local zig = stand.enemyParty[1]
  eq(zig.item, 0, "Birch: the stand-in built the ZIGZAGOON with the start's zeroed item")
  local solo = R.newSolo()
  local rec = birchDone()
  check(takeWild(solo, stand, foe, rec.done), "Birch: solo takes it (" .. table.concat(warns, " / ") .. ")")
  eq(#R.heldAsks, 1, "Birch: the held item is rolled once (pret SetWildMonHeldItem)")
  eq(R.heldAsks[1] and R.heldAsks[1].species, ZIGZAGOON, "Birch: ...for the ZIGZAGOON")
  eq(zig.item, 139, "Birch: ...and it holds what the roll gave")
  eq(zig.heldItem, 139, "Birch: ...both spellings")
  eq(solo.wildMon, zig, "Birch: the monster fought is the stand-in's own")
  local sheet = solo.sim.byId.solo_foe.mons[1]
  eq(sheet.heldItem, 139, "Birch: the referee's ZIGZAGOON holds it")
  local create, so = R.lastCreate(), R.lastScreen()
  eq(create and create.firstBattle, "birch", "Birch: the referee plays Birch's rules")
  eq(create and create.sides.b[1].ai, "firstBattle", "Birch: the ZIGZAGOON is on AI_FirstBattle")
  eq(solo.sim.byId.solo_foe.ai, "firstBattle", "Birch: ...and the referee keeps it on its seat")
  eq(create and create.wildPick, "cart", "Birch: a wild fight (its own `ai` preferred over the cart's wild move)")
  eq(so and so.firstBattle, "birch", "Birch: the screen is told")
  solo:reset()

  -- A monster that already holds something is not rolled again.
  R.newGame("emerald")
  R.session().party = { mon(4, 5, { moves = { 300 } }) }
  local stand2, foe2 = birchStand({ item = 21 }, nil)
  local solo2 = R.newSolo()
  check(takeWild(solo2, stand2, foe2, function() end), "Birch held: taken")
  eq(#R.heldAsks, 0, "Birch held: a held item is kept, not rolled over")
  eq(stand2.enemyParty[1].item, 21, "Birch held: ...the one it had")
  solo2:reset()

  -- No stand-in: the engine's own opts and foe are enough.
  R.newGame("emerald")
  R.session().party = { mon(4, 5, { moves = { 300 } }) }
  R.heldQueue = { 139 }
  local bare = R.newSolo()
  check(bare:fromGen3Encounter(R.game(), { species = ZIGZAGOON, level = 2, item = 0 },
    { wild = true, firstBattleKind = "birch", done = function() end }), "Birch bare: taken")
  eq(bare.wildMon and bare.wildMon.item, 139, "Birch bare: the ZIGZAGOON rolled its item")
  eq(#R.heldAsks, 1, "Birch bare: ...once")
  bare:reset()
end)

-- RUN at Birch's ZIGZAGOON, from the screen's own RUN command.
local function runAt(solo)
  local fight = solo.fight
  local turn = solo.sim.turn
  fight:runCommand("RUN")
  for _ = 1, 20 do
    solo:update(0.5, R.game())
    if not solo.fight then break end
    fight:update(2.0)
    if fight.phase == "choose" and #fight.lines == 0 and not fight.shown then break end
  end
  return fight, turn
end

block("Birch RUN refused", function()
  for _, case in ipairs({
    { "the cart's line", "PROF. BIRCH: DON'T LEAVE ME!", "PROF. BIRCH: DON'T LEAVE ME!" },
    { "the fallback", nil, "PROF. BIRCH: Don't leave me like this!" },
  }) do
    R.newGame("emerald")
    if case[2] then R.TEXT.STRINGID_DONTLEAVEBIRCH = case[2] else R.textless = true end
    R.session().party = { mon(4, 5, { moves = { 300 } }) }
    local stand, foe = birchStand(nil, nil)
    local solo = R.newSolo()
    local rec = birchDone()
    check(takeWild(solo, stand, foe, rec.done), "Birch RUN: taken (" .. case[1] .. ")")
    check(R.untilChoose(solo), "Birch RUN: the menu (" .. case[1] .. ")")
    local fight, turn = runAt(solo)
    check(said(fight, case[3]), "Birch RUN: refused with " .. case[1] .. ": " .. case[3])
    eq(solo.sim and solo.sim.turn, turn, "Birch RUN: ...the turn unspent (" .. case[1] .. ")")
    eq(solo.sim and solo.sim.byId.solo_player.choice, nil, "Birch RUN: ...nothing filed (" .. case[1] .. ")")
    eq(fight.phase, "choose", "Birch RUN: ...the menu back (" .. case[1] .. ")")
    eq(#rec.heard, 0, "Birch RUN: ...and the fight goes on (" .. case[1] .. ")")
    check(not said(fight, "Can't escape"), "Birch RUN: ...never the trap line (" .. case[1] .. ")")
    solo:reset()
  end
end)

block("Birch RUN that gets away", function()
  for _, case in ipairs({
    { "a SMOKE BALL", { heldItem = 194, item = 194 } },
    { "RUN AWAY", { ability = 50, abilityId = 50 } },
  }) do
    R.newGame("emerald")
    local extra = { moves = { 45 } }
    for k, v in pairs(case[2]) do extra[k] = v end
    R.session().party = { mon(4, 5, extra) }
    local stand, foe = birchStand(nil, nil)
    local solo = R.newSolo()
    local rec = birchDone()
    check(takeWild(solo, stand, foe, rec.done), "Birch away: taken (" .. case[1] .. ")")
    check(R.untilChoose(solo), "Birch away: the menu (" .. case[1] .. ")")
    local fight = runAt(solo)
    check(R.drive(solo, function(f) f:pickMove(1) end), "Birch away: the fight ends (" .. case[1] .. ")")
    eq(table.concat(rec.heard, ","), "run", "Birch away: " .. case[1] .. " still escapes ('run')")
    check(not said(fight, "Don't leave me"), "Birch away: ...without Birch's plea (" .. case[1] .. ")")
  end
end)

block("Birch RUN held by a trap", function()
  R.newGame("emerald")
  R.textless = true
  R.session().party = { mon(4, 5, { moves = { 45 } }) }
  local stand, foe = birchStand({ ability = 71, abilityId = 71 }, nil)
  stand.enemyParty[1].ability, stand.enemyParty[1].abilityId = 71, 71
  local solo = R.newSolo()
  check(takeWild(solo, stand, foe, function() end), "Birch trap: taken")
  check(R.untilChoose(solo), "Birch trap: the menu")
  local fight, turn = runAt(solo)
  check(said(fight, "prevents") and said(fight, "escape"),
        "Birch trap: ARENA TRAP holds the runner with its own line (pret: traps before FIRST_BATTLE)")
  check(not said(fight, "Don't leave me"), "Birch trap: ...not Birch's")
  eq(solo.sim.turn, turn, "Birch trap: ...the turn unspent")
  solo:reset()

  -- Wrapped (STATUS2_WRAPPED): B_MSG_CANT_ESCAPE, before FIRST_BATTLE's.
  R.newGame("emerald")
  R.textless = true
  R.session().party = { mon(4, 5, { moves = { 45 } }) }
  local stand2, foe2 = birchStand(nil, nil)
  local solo2 = R.newSolo()
  check(takeWild(solo2, stand2, foe2, function() end), "Birch wrapped: taken")
  check(R.untilChoose(solo2), "Birch wrapped: the menu")
  solo2.sim.byId.solo_player.b.trapTurns = 3
  local fight2 = runAt(solo2)
  check(said(fight2, "Can't escape!"), "Birch wrapped: a wrapped runner is held with 'Can't escape!'")
  check(not said(fight2, "Don't leave me"), "Birch wrapped: ...not Birch's plea")
  solo2:reset()
end)

block("Birch ZIGZAGOON flees", function()
  R.newGame("emerald")
  -- 2 HP of the lead's maximum: at or under 20%, AI_FirstBattle runs.
  local lead = mon(4, 10, { moves = { 45 } })
  lead.hp = math.max(1, math.floor(lead.maxHp / 5))
  R.session().party = { lead }
  local stand, foe = birchStand(nil, nil)
  local solo = R.newSolo()
  local rec = birchDone()
  check(takeWild(solo, stand, foe, rec.done), "Birch flees: taken")
  local _, fight = R.drive(solo, function(f) f:pickMove(1) end)
  eq(table.concat(rec.heard, ","), "mon_fled", "Birch flees: the ZIGZAGOON ran (MON_FLED)")
  eq(R.session().battleOutcome, 6, "Birch flees: ...B_OUTCOME_MON_FLED")
  check(said(fight, "fled"), "Birch flees: 'Wild ZIGZAGOON fled!'")
end)

block("Birch won", function()
  R.newGame("emerald")
  local lead = mon(4, 5, { moves = { 300 } })
  R.session().party = { lead }
  local exp0 = lead.exp
  local stand, foe = birchStand(nil, nil)
  local solo = R.newSolo()
  local rec = birchDone()
  check(takeWild(solo, stand, foe, rec.done), "Birch won: taken")
  local _, fight = R.drive(solo, function(f) f:pickMove(1) end)
  eq(table.concat(rec.heard, ","), "win", "Birch won: 'win'")
  check(lead.exp > exp0, "Birch won: EXP is given (FIRST_BATTLE is no Cmd_getexp exclusion)")
  local tv = nil
  for _, e in ipairs(R.effectsOf("rse")) do if e[2] == "tv" then tv = e end end
  check(tv ~= nil, "Birch won: the TV is asked, the way the engine's own end asks it")
  eq(tv and tv[9] and tv[9].firstBattle, true, "Birch won: ...told it was a first battle (never on air)")
  check(R.contains(R.audioNames(), "clearSavedSong"), "Birch won: the saved song is let go")
  check(not R.contains(R.fieldCalls(), "respawn"), "Birch won: no whiteout")
  check(fight ~= nil, "Birch won: the screen was up")
end)

block("Birch lost", function()
  R.newGame("emerald")
  local lead = mon(4, 2, { moves = { 45 } })
  R.session().party = { lead }
  local money = R.session().money
  -- A ZIGZAGOON that knocks the lead out in one blow, the lead never under
  -- 20% before it does (so AI_FirstBattle never flees).
  local stand, foe = birchStand({ level = 40, moves = { 300 } }, nil)
  local solo = R.newSolo()
  local rec = birchDone()
  check(takeWild(solo, stand, foe, rec.done), "Birch lost: taken")
  local _, fight = R.drive(solo, function(f) f:pickMove(1) end)
  eq(table.concat(rec.heard, ","), "lose", "Birch lost: 'lose'")
  check(not R.contains(R.fieldCalls(), "respawn"), "Birch lost: no whiteout (CB2_EndFirstBattle)")
  eq(R.session().money, money, "Birch lost: no money lost")
  eq(R.healCalls(), 0, "Birch lost: no heal either")
  eq(lead.hp, 0, "Birch lost: ...the lead stays fainted")
  check(said(fight, "STRINGID_PLAYERWHITEOUT|"), "Birch lost: the cart still prints its whiteout lines")
  eq(R.FakeVm.halted, 0, "Birch lost: nothing halted")
end)

-- ===================================================================
-- 4. the other shapes
-- ===================================================================

block("first battles of the wrong shape", function()
  R.newGame("firered")
  R.session().party = { mon(4, 5, { moves = { 300 } }) }
  local solo = R.newSolo()
  eq(solo:fromGen3Encounter(R.game(), { species = 16, level = 3 },
       { wild = true, stand3 = { kind3 = "firstBattle", firstBattle3 = "oak" }, done = function() end }),
     false, "shape: Oak's lab as a wild fight is the cart's")
  R.newGame("emerald")
  R.session().party = { mon(4, 5, { moves = { 300 } }) }
  local solo2 = R.newSolo()
  eq(solo2:fromGen3Trainer(R.game(), RIVAL,
       { trainerId = RIVAL, stand3 = { kind3 = "firstBattle", firstBattle3 = "birch" }, done = function() end }),
     false, "shape: Birch's rescue as a trainer fight is the cart's")
  eq(R.Stack.depth(), 0, "shape: nothing went onto the stack")
  local First = R.need("Solo3/First")
  eq(First.which({ firstBattle3 = "oak" }), "oak", "which: the stand-in's word first")
  eq(First.which({ opts = { firstBattleKind = "birch" } }), "birch", "which: ...else the engine's opts")
  eq(First.which({ kind = "trainer", opts = { firstBattle = true } }), "birch",
     "which: ...else the cart's profile (Emerald's is Birch's)")
end)

eq(#warns, 0, "nothing warned that a scenario did not ask for: " .. table.concat(warns, " / "))

T.finish("gen3_solo_first")
