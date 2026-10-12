-- SOLO BATTLES e2e legs for the Gen 3 facilities and doubles the cart used to
-- keep (docs/plans/gen3-solo-remaining-fights.md, research Part 1 §1.4 /
-- §1.5): FireRed / LeafGreen's Trainer Tower, Emerald's Trainer Hill, Battle
-- Tents and Secret Bases, two-trainer pairs and Steven's multi battle.
--
-- Loaded by tests/drivers/solo_battle_e2e.lua (`familyLegs`, FAMILY_LEGS3) and
-- called with its `kit`.  SOLO_LEGS names a group or one leg:
--
--   tower  (FR / LG) the Seven Island Trainer Tower
--     tower-single  the lobby's own counter script starts a SINGLE challenge,
--                   1F's floor trigger walks the trainer up and its
--                   `ttower_dobattle` meets the mod's screen; won; the after:
--                   1F cleared (TrainerTower_EventScript_SetFloorCleared), the
--                   challenge clock still running, no prize money, no EXP
--     tower-double  the same with the DOUBLE challenge: 1F's fight is the
--                   lone double on the double screen
--     tower-roof    the roof owner at the top (every floor marked cleared
--                   through the record the cart keeps -- see the leg): the
--                   prize, the clock stopped, the best time recorded
--   hill   (EM) Trainer Hill
--   tent   (EM) a Battle Tent through its reception
--   base   (EM) a Secret Base owner
--   pairs  (EM) two trainers at once, Steven's multi, a pair lost
--
-- Every leg says how the fight was met: the cart's own script / trigger /
-- sight (a warp onto the map, the state the script reads seeded through the
-- engine), or an engine start function where the real door cannot be reached
-- in a test (named in the leg and in its log line).
--
-- Legal: nothing here names a ROM value it asserts on.  Species, moves, items,
-- flags and vars are looked up by pret name in the player's own cart; every
-- number compared is read from the live session or the engine's own formula.

return function(kit)
  local game, H, U = kit.game, kit.H, kit.U
  local log, check, skip = kit.log, kit.check, kit.skip

  local GROUPS = {
    { "tower", { "tower-single", "tower-double", "tower-roof" } },
    { "hill", { "hill-floor", "hill-double", "hill-after" } },
    { "tent", { "tent-palace" } },
    { "base", { "base-owner" } },
    { "pairs", { "pairs-win", "pairs-steven", "pairs-lose" } },
  }
  local function wants(name) return kit.legOn(name, name:match("^(%a+)%-")) end
  local wanted = {}
  local any = false
  for _, row in ipairs(GROUPS) do
    for _, name in ipairs(row[2]) do
      if wants(name) then wanted[name], any = true, true end
    end
  end
  if not any then return end

  local Battle = require("src.core.game3.battle")
  local Map = require("src.core.game3.map")
  local Player = require("src.core.game3.player")
  local Objects = require("src.core.game3.objects")
  local Space = require("src.core.game3.scripting.space")
  local Flags = require("src.core.game3.scripting.flags")
  local Message = require("src.ui.game3.message")
  local Choice = require("src.ui.game3.choice")
  local PartyMenu = require("src.ui.game3.party_menu")
  local SaveMenu = require("src.ui.game3.save_menu")
  local Collision = require("src.core.game3.collision")
  local Natives = require("src.core.game3.scripting.natives")
  local OUTCOME = Natives.B_OUTCOME or {}

  local solo = kit.solo
  local fight, session, settle = kit.fight, kit.session, kit.settle

  -- ------------------------------------------------------------------
  -- the cart's flags and vars, by pret name
  -- ------------------------------------------------------------------

  local function names() return Flags.forVersion(kit.VERSION) or {} end
  local function flagId(name) return (names().IDS or {})[name] end
  local function varId(name)
    if type(name) == "number" then return name end
    return (names().VAR_IDS or {})[name]
  end
  local function vmCtx() return Space.vm and Space.vm.ctx or nil end
  local function getFlag(name)
    local id = flagId(name)
    if not id then return nil end
    local ok, on = pcall(Flags.getFlag, Space.store, nil, id)
    return ok and on == true
  end
  local function setFlag(name, on)
    local id = flagId(name)
    if not id then return false end
    return pcall(Flags.setFlag, Space.store, nil, id, on ~= false)
  end
  local function getVar(name)
    local id = varId(name)
    if not id then return nil end
    local ok, v = pcall(Flags.getVar, Space.store, vmCtx(), id)
    return ok and (tonumber(v) or 0) or nil
  end
  local function setVar(name, value)
    local id = varId(name)
    if not id then return false end
    return pcall(Flags.setVar, Space.store, nil, id, value)
  end
  local VAR_RESULT = 0x800D -- pret include/constants/vars.h gSpecialVar_Result

  local function money() return tonumber(session().money) or 0 end
  local function trainerBeaten(tid)
    local ok, on = pcall(Flags.getFlag, Space.store, nil, Flags.trainerFlagId(tid))
    return ok and on == true
  end

  -- ------------------------------------------------------------------
  -- the field: walking, talking, the cart's boxes
  -- ------------------------------------------------------------------

  -- The engine's own field-walking helpers (tests/drivers/em_story_util.lua:
  -- a BFS over the live collision, a step that waits the walk out, facing),
  -- generic Game3 code despite the name; nil when that checkout has none.
  local okS, S = pcall(require, "tests.drivers.em_story_util")
  if not (okS and type(S) == "table" and type(S.goTo) == "function") then S = nil end

  local function mapNow() local s = session() return s and s.map end

  -- Stand next to (x, y) and face it, walking there for real.
  local function walkBeside(x, y)
    if not S then return false end
    local ok = pcall(S.adjacentTo, game, x, y)
    return ok and math.abs(Player.cellX - x) + math.abs(Player.cellY - y) == 1
  end

  local function walkTo(x, y)
    if not S then return false end
    local ok, reached = pcall(S.goTo, game, { x, y })
    return ok and reached == true
  end

  -- What the cart said, page by page, for the leg's assertions and the log.
  local spoken = {}
  local function notePage()
    local ok, page = pcall(Message.currentPage)
    if ok and type(page) == "table" then page = table.concat(page, " ") end
    if ok and type(page) == "string" and page ~= "" and spoken[#spoken] ~= page then
      spoken[#spoken + 1] = page
    end
  end
  local function heard(needle)
    needle = needle:lower()
    for _, page in ipairs(spoken) do
      if page:lower():find(needle, 1, true) then return page end
    end
    return nil
  end

  -- The cart's menu: walk the cursor to `want` (an index), then A.
  local function pick(want)
    for _ = 1, 16 do
      if not Choice.active or Choice.cursor == want then break end
      local cols = tonumber(Choice.cols) or 1
      if cols > 1 and (Choice.cursor - 1) % cols ~= (want - 1) % cols then
        U.tap(game, ((Choice.cursor - 1) % cols < (want - 1) % cols) and "right" or "left")
      else
        U.tap(game, Choice.cursor < want and "down" or "up")
      end
      U.wait(4)
    end
    U.tap(game, "a")
    U.wait(8)
  end

  local function optionText(o)
    if type(o) == "table" then o = o.text or o.label or o[1] end
    return tostring(o or "")
  end
  local function optionIndex(options, needle)
    for i, o in ipairs(options or {}) do
      if optionText(o):upper():find(needle:upper(), 1, true) then return i end
    end
    return nil
  end

  -- The cart's party picker for a three-monster entry (ChooseHalfPartyForBattle,
  -- pokefirered party_menu.c:3760 CursorCB_Enter): the cursor onto each slot,
  -- A for the actions, A on ENTER; START jumps to CONFIRM (:1133), A.  The
  -- menu's own entry points finish it when the keys did not.
  local picked = nil
  local function pickParty(slots)
    slots = slots or { 1, 2, 3 }
    for _, slot in ipairs(slots) do
      for _ = 1, 8 do
        if PartyMenu.cursor == slot then break end
        U.tap(game, "down")
        U.wait(4)
      end
      U.tap(game, "a"); U.wait(10)
      U.tap(game, "a"); U.wait(10)
    end
    U.tap(game, "start"); U.wait(8)
    U.tap(game, "a"); U.wait(30)
    picked = "keys"
    if PartyMenu.isOpen() and PartyMenu.mode == "choose_multi" then
      picked = "api"
      local order = PartyMenu.chosenOrder and PartyMenu.chosenOrder() or {}
      if #order < #slots then
        for _, slot in ipairs(slots) do pcall(PartyMenu.enterChosenMon, slot) U.wait(4) end
      end
      pcall(PartyMenu.confirmChosenMons)
      U.wait(10)
    end
  end

  -- Talk the cart's talk until `done()`: A on its text, `opts.answer(options,
  -- kind)` on its menus (an index, a label, "yes" / "no"; default the first
  -- row), its party picker answered with `opts.party`, its save prompt saved.
  local saved = false
  local function converse(done, opts)
    opts = opts or {}
    return H.waitSeconds(game, function()
      if opts.watch then opts.watch() end
      if done() then return true end
      if Choice.active then
        local want = opts.answer and opts.answer(Choice.options, Choice.kind) or 1
        if want == "yes" then want = 1 elseif want == "no" then want = 2 end
        if type(want) == "string" then want = optionIndex(Choice.options, want) or 1 end
        U.wait(4)
        pick(want)
        return false
      end
      if PartyMenu.isOpen() and PartyMenu.mode == "choose_multi" then
        U.wait(10)
        if opts.onParty then opts.onParty() end
        pickParty(opts.party)
        return false
      end
      if SaveMenu.isOpen() then
        saved = true
        U.tap(game, "a")
        U.wait(10)
        return false
      end
      if Message.isOpen() then
        notePage()
        if Message.isTyping and Message.isTyping() then pcall(Message.skipReveal) end
        U.wait(4)
        U.tap(game, "a")
        U.wait(4)
        return false
      end
      if opts.idle then opts.idle() end
      U.wait(2)
      return false
    end, opts.seconds or 120, opts.what or "the cart's script")
  end

  -- The player is the field's again: no box, no script, no warp, no battle.
  local function backOnField(seconds)
    return converse(function()
      return fight() == nil and not Battle.isActive() and H.g3Free(game)
    end, { seconds = seconds or 90, what = "the field after the fight" })
  end

  -- ------------------------------------------------------------------
  -- the fight: who took it, how it looked, how it ended
  -- ------------------------------------------------------------------

  local seen
  local function newSeen() seen = { lines = {}, turns = 0 } return seen end

  local function watchFight()
    local f = fight()
    if not f then return end
    seen.up = true
    if Battle.isActive() then seen.cartBattle = true end
    seen.soloDouble = seen.soloDouble or f.soloDouble == true
    local g = solo.gen3
    if type(g) == "table" then
      seen.kind3 = g.kind3 or g.name or seen.kind3
      seen.facility3 = g.facility3 or seen.facility3
      seen.verdict = g.verdict or seen.verdict
      seen.outcome = g.outcome or seen.outcome
      seen.rules = g.facilityRules3 or seen.rules
      if type(g.dbl) == "table" then seen.dbl = g.dbl end
      seen.prize = g.prize or seen.prize
    end
    local s = f.shown
    if type(s) == "table" then s = table.concat(s, " ") end
    if type(s) == "string" and s ~= "" then
      s = s:gsub("%s*\n%s*", " ")
      if seen.lines[#seen.lines] ~= s then seen.lines[#seen.lines + 1] = s end
    end
  end

  local function said(needle)
    needle = needle:lower()
    for _, line in ipairs(seen.lines) do
      if line:lower():find(needle, 1, true) then return line end
    end
    return nil
  end

  -- Walk / talk until the mod's screen is up (or the cart's battle, which is
  -- a failure the leg reports).
  local function meet(opts)
    opts = opts or {}
    newSeen()
    local met = converse(function()
      return fight() ~= nil or Battle.isActive()
    end, { answer = opts.answer, party = opts.party, idle = opts.idle, seconds = opts.seconds or 120,
           what = opts.what or "the fight to start", onParty = opts.onParty })
    watchFight()
    return met and fight() ~= nil
  end

  -- The first command menu of the fight, shot once.
  local function awaitMenu(leg, seconds)
    local up = H.waitSeconds(game, function()
      watchFight()
      local f = fight()
      if not f then return true end
      if f.phase == "choose" and not f.result then return true end
      if f.phase == "messages" or f.phase == "intro" then U.tap(game, "a") U.wait(4) end
      return false
    end, seconds or 60, "the fight's first command menu")
    if up and fight() then
      U.wait(6)
      kit.shot(leg .. "-menu")
    end
    return up and fight() ~= nil
  end

  -- A single, to its end: `how` = "win" (the strongest move), "forfeit" (RUN,
  -- then YES to the cart's "forfeit the match?"), or "weak" (the weakest
  -- damaging move: a fight meant to be lost).
  local function weakestMove(f)
    local mine = f.mine and f.mine[f.active or 1]
    local best, power = 1, math.huge
    for i, mv in ipairs((mine and mine.moves) or {}) do
      local p = tonumber(mv.power) or 0
      if (tonumber(mv.pp) or 0) > 0 and p < power then best, power = i, p end
    end
    return best
  end
  local function driveSingle(how, seconds)
    local asked = false
    return H.waitSeconds(game, function()
      watchFight()
      local f = fight()
      if not f then return true end
      if f.phase == "ask" then
        asked = true
        U.tap(game, "up"); U.wait(4)
        U.tap(game, "a"); U.wait(8)
      elseif f.phase == "choose" and not f.result then
        seen.turns = seen.turns + 1
        if how == "forfeit" and not seen.forfeited then
          seen.forfeited = true
          kit.command("RUN")
        else
          kit.fightWith(how == "weak" and weakestMove(f) or kit.bestMove(f))
        end
      elseif f.phase == "move" or f.phase == "target" or f.phase == "switch" or f.phase == "item" then
        U.tap(game, "b"); U.wait(6)
      else
        kit.nudge()
      end
      seen.asked = seen.asked or asked
      return fight() == nil
    end, seconds or 300, "the solo fight to end")
  end

  -- A double on the double screen (CoopBattle.newSoloDouble), seat by seat
  -- with the real keys: FIGHT, the move (the strongest damaging one, or the
  -- weakest for a fight meant to be lost), the first foe the picker offers;
  -- a replacement takes the first monster the bench lists.
  local function driveDouble(how, seconds)
    local function moveFor(moves)
      local best, score = 1, nil
      for i, mv in ipairs(moves or {}) do
        if (tonumber(mv.pp) or 0) > 0 then
          local p = tonumber(mv.power) or 0
          local s = (how == "weak") and -p or p
          if score == nil or s > score then best, score = i, s end
        end
      end
      return best
    end
    return H.waitSeconds(game, function()
      watchFight()
      local f = fight()
      if not f then return true end
      if f.replacing and f.phase ~= "messages" then
        U.tap(game, "a"); U.wait(8)
      elseif f.phase == "choose" and not f.result and not f.replacing then
        seen.turns = seen.turns + 1
        for i, c in ipairs(f:commandList()) do
          if c == "FIGHT" then f.commandIndex = i end
        end
        U.tap(game, "a"); U.wait(8)
        f = fight()
        if f and f.phase == "move" then
          local want = moveFor(f:liveMoves())
          for _ = 1, 6 do
            if f.moveIndex == want then break end
            U.tap(game, "down"); U.wait(4)
          end
          U.tap(game, "a"); U.wait(8)
        end
        f = fight()
        if f and f.phase == "target" then
          local targets = f:targetChoices()
          local at = nil
          for i, e in ipairs(targets) do
            if not at and f:foeSide(e.index) then at = i end
          end
          for _ = 1, #targets * 2 do
            if f.targetIndex == (at or f.targetIndex) then break end
            U.tap(game, "right"); U.wait(4)
          end
          U.tap(game, "a"); U.wait(8)
        end
      elseif f.phase == "move" or f.phase == "target" or f.phase == "switch" then
        U.tap(game, "b"); U.wait(6)
      else
        kit.nudge()
      end
      return fight() == nil
    end, seconds or 360, "the solo double to end")
  end

  -- What every leg asserts once the mod's screen is up.
  local function assertTaken(leg, kind3, facility3)
    check(fight() ~= nil, leg .. ": SOLO BATTLES took the fight (its screen is up)")
    check(not seen.cartBattle and not Battle.isActive(), leg .. ": the cart's own battle did not start")
    if kind3 then
      check(seen.kind3 == kind3, leg .. ": fought as the `" .. kind3 .. "` kind", tostring(seen.kind3))
    end
    if facility3 then
      check(seen.facility3 == facility3, leg .. ": in the hall `" .. facility3 .. "`", tostring(seen.facility3))
    end
  end

  -- Nothing of the fight left drawn or running under the field.
  local function assertClean(leg)
    check(fight() == nil and not Battle.isActive(), leg .. ": no fight left on screen, neither ours nor the cart's")
    check(H.g3Free(game) and H.g3Idle(game), leg .. ": the field is the player's again (no box, no script, no warp)")
  end

  -- A party built for the leg: `{ species, level, hp?, moves? }` rows,
  -- healthy, the strongest damaging move first unless `moves` pins them.
  local Moves = require("src.core.game3.battle.moves")
  local function moveId(name) return H.g3Const(game, "moves", name) end
  local function pinMoves(mon, list)
    local ids, pp = {}, {}
    for i, name in ipairs(list) do
      local id = moveId(name)
      local okM, row = pcall(Moves.get, id)
      ids[i], pp[i] = id, (okM and type(row) == "table" and tonumber(row.pp)) or 10
    end
    mon.moves, mon.pp, mon.maxPp = ids, pp, { unpack(pp) }
  end
  local function seedTeam(rows)
    local team = {}
    for i, row in ipairs(rows) do
      local mon = (i == 1) and H.g3SeedParty(game, row.species, row.level)
        or H.g3GiveMon(game, row.species, row.level)
      if mon then
        if row.moves then pinMoves(mon, row.moves) else H.g3FrontloadDamage(mon) end
        mon.hp = row.hp or mon.maxHp
        mon.status = nil
      end
      team[i] = mon
    end
    return team
  end
  local function expOf(i) local m = session().party[i] return tonumber(m and m.exp) or 0 end

  local function onSolo(classic)
    kit.setOption(kit.env.OPTION_KEY, true)
    kit.setOption("classicui", classic == true)
  end

  -- Run one leg, and whatever happens leave the field clean for the next.
  local function leg(name, fn)
    if not wanted[name] then return end
    log(name .. ": start")
    spoken, saved, picked = {}, false, nil
    local ok, err = pcall(fn)
    check(ok, name .. ": the leg ran to its end", tostring(err))
    if fight() then
      if fight().soloDouble then driveDouble("win", 240) else driveSingle("win", 240) end
    end
    backOnField(60)
    settle()
  end

  local function cartOnly(names, why)
    for _, name in ipairs(names) do
      if wanted[name] then skip(name, why) end
    end
  end

  -- ==================================================================
  -- tower: FireRed / LeafGreen's Trainer Tower (Seven Island)
  -- ==================================================================
  --
  -- The door is the cart's own (pokefirered data/maps/TrainerTower_Lobby/
  -- scripts.inc, data/scripts/trainer_tower.inc): the lobby's counter trigger
  -- asks the challenge and the mode, StartTrainerTowerChallenge
  -- (trainer_tower.c:769) zeroes the record and starts the clock; on 1F the
  -- floor's ON_FRAME / coord trigger walks the trainer up and
  -- `ttower_dobattle` (DoTrainerTowerBattle, :735, BATTLE_TYPE_TRAINER_TOWER)
  -- starts the fight the mod takes.  A win: BattleScript_BattleTowerTrainer-
  -- BattleWon (no money, battle_scripts_1.s:2991; no EXP, battle_script_
  -- commands.c:3130), then TrainerTower_EventScript_SetFloorCleared bumps
  -- floorsCleared.  The only shortcut: the walk from the lobby to 1F (the
  -- elevator / stair warp) is a warp onto 1F's foot, as the engine's own
  -- game3_tower_run driver does.

  local function towerLegs()
    local Tower = require("src.core.game3.trainer_tower")
    local LOBBY, FLOOR1, ROOF = "FR_TRAINER_TOWER_LOBBY", "FR_TRAINER_TOWER_1F", "FR_TRAINER_TOWER_ROOF"
    if not Tower.floors(Tower.CHALLENGE_TYPE.SINGLE) then
      cartOnly({ "tower-single", "tower-double", "tower-roof" },
        "this cart's cache carries no gTrainerTowerFloors (reimport the ROM)")
      return
    end
    -- pokefirered data/maps/PalletTown_ProfessorOaksLab/scripts.inc:1120 --
    -- the flag the engine's own tower driver sets (the field's party gate).
    local function partyGate() setFlag("FLAG_SYS_POKEMON_GET", true) end

    -- The lobby counter: the challenge question, the mode (SINGLE, DOUBLE,
    -- KNOCKOUT, MIXED, EXIT), the receptionist's goodbye.
    local function startChallenge(modeIndex, leg)
      H.g3Teleport(game, LOBBY, 9, 12, "up")
      local started = false
      for _ = 1, 8 do
        if Player.cellY <= 7 or H.g3ScriptRunning() or Message.isOpen() then break end
        U.hold(game, "up", 20)
        U.wait(8)
      end
      local modes = nil
      converse(function()
        return not H.g3ScriptRunning() and not Message.isOpen() and not Choice.active and H.g3Free(game)
      end, {
        answer = function(options)
          if #(options or {}) >= 5 then
            modes = #options
            kit.shot(leg .. "-modes")
            return modeIndex
          end
          return 1
        end,
        seconds = 60, what = "the lobby counter's script",
      })
      started = Tower.isTimerRunning(session())
      return started, modes
    end

    local function floorFight(leg, modeIndex, modeId, double)
      partyGate()
      local team = seedTeam({
        { species = kit.STARTER, level = 50 }, { species = "PIKACHU", level = 50 },
        { species = kit.WILD, level = 45 },
      })
      check(#session().party == 3 and team[1] and team[2], leg .. ": a party of three was seeded")
      onSolo(double)
      local started, modes = startChallenge(modeIndex, leg)
      check(modes ~= nil, leg .. ": the lobby counter asked the challenge's mode (its own list)", tostring(modes))
      check(Tower.getChallengeId(session()) == modeId,
            leg .. ": StartTrainerTowerChallenge recorded the mode asked", tostring(Tower.getChallengeId(session())))
      check(started, leg .. ": the challenge clock started (trainer_tower.c:769)")
      local rec = Tower.record(session())
      check(rec.floorsCleared == 0, leg .. ": no floor cleared yet", tostring(rec.floorsCleared))
      local moneyBefore, exp1 = money(), expOf(1)

      -- 1F's foot (the elevator / stairs' landing; the engine's own driver's
      -- cell), then up into the floor trigger.
      H.g3Teleport(game, FLOOR1, 10, 14, "up")
      check(mapNow() == FLOOR1, leg .. ": on 1F with the challenge running")
      local t0 = Tower.record(session()).timer
      local met = meet({
        idle = function()
          if H.g3Free(game) then U.hold(game, "up", 16) end
        end,
        seconds = 90, what = "1F's trainer to walk up and the fight to start",
      })
      if not check(met, leg .. ": 1F's trigger walked the trainer up and the fight began") then return end
      assertTaken(leg, "facility", "trainerTower")
      check(seen.soloDouble == (double == true),
            leg .. (double and ": a double, on the double screen" or ": a single, on the single screen"))
      check(type(seen.rules) == "table" and seen.rules.exp == false and seen.rules.forfeit == nil,
            leg .. ": the Trainer Tower's rules -- no EXP, RUN refused like any trainer's (not a forfeit)")
      awaitMenu(leg)
      if double then driveDouble("win") else driveSingle("win") end
      check(fight() == nil, leg .. ": the fight ended")
      check(seen.verdict == "win", leg .. ": won", tostring(seen.verdict))
      backOnField(90)
      kit.shot(leg .. "-after")
      rec = Tower.record(session())
      check(rec.floorsCleared == 1, leg .. ": the floor is cleared (TrainerTower_EventScript_SetFloorCleared)",
            tostring(rec.floorsCleared))
      check(Tower.isTimerRunning(session()) and (tonumber(rec.timer) or 0) > (tonumber(t0) or 0),
            leg .. ": the challenge clock keeps running", ("%s -> %s"):format(tostring(t0), tostring(rec.timer)))
      check(money() == moneyBefore, leg .. ": no prize money (BattleScript_BattleTowerTrainerBattleWon)",
            ("%d -> %d"):format(moneyBefore, money()))
      check(expOf(1) == exp1, leg .. ": no EXP (battle_script_commands.c:3130)")
      check(session().battleOutcome == OUTCOME.WON, leg .. ": the save's outcome is a win",
            tostring(session().battleOutcome))
      assertClean(leg)
    end

    leg("tower-single", function()
      floorFight("tower-single", 1, Tower.CHALLENGE_TYPE.SINGLE, false)
    end)
    leg("tower-double", function()
      floorFight("tower-double", 2, Tower.CHALLENGE_TYPE.DOUBLE, true)
    end)
  end

  -- ==================================================================
  -- the run
  -- ==================================================================

  if kit.emerald then
    cartOnly({ "tower-single", "tower-double", "tower-roof" },
      "FireRed / LeafGreen only: Emerald has no Trainer Tower (its Trainer Hill is the hill group)")
  else
    towerLegs()
    cartOnly({ "hill-floor", "hill-double", "hill-after", "tent-palace", "base-owner",
               "pairs-win", "pairs-steven", "pairs-lose" },
      "Emerald only: FireRed / LeafGreen have no Trainer Hill, Battle Tents, Secret Bases, "
      .. "two-trainer pairs or partner battles")
  end
end
