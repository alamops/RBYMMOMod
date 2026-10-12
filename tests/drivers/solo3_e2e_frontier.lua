-- The Battle Frontier legs of the Gen 3 solo e2e (group "frontier"): every
-- hall SOLO BATTLES takes from the cart (src/Solo3/Facility.lua,
-- src/Solo3/FacilityMulti.lua; docs/plans/gen3-solo-remaining-fights.md),
-- each fought on the mod's screen from the hall's own reception.
--
-- Loaded by tests/drivers/solo_battle_e2e.lua's `familyLegs` (FAMILY_LEGS3):
-- this file returns `function(kit)`, the kit carrying the driver's readers and
-- pilots (game, H = mmo_util, U, the fight readers, settle, seed ...).
--
-- ------- what a leg proves
--
-- The challenge is the cart's: the player stands in the hall's lobby with a
-- party seeded through the engine (rse/frontier/trainers.lua createMon, the
-- engine's own Frontier builder), talks to the hall's attendant -- the cart's
-- reception script, found by its pret label in the cart's own script bundle --
-- and answers its menus (CHALLENGE, LV. 50, the party picked with the
-- engine's ChoosePartyForBattleFrontier menu, the save), walks the hall's
-- scripts to the battle room, and the hall's own battle special
-- (DoSpecialTrainerBattle / the Pyramid's and Pike's trainers) starts the
-- fight.  The mod's screen takes it (solo.fight up, the cart's battle never
-- active), the fight is played with real key presses to its end, and what
-- the cart leaves afterwards is read back through the engine's Frontier
-- modules: the streak and record, the challenge status, `lastFrontierBattle`
-- and the Tower interview, the Dome's last moves, the party the cart loads
-- back, the hall's next step (the next-opponent menu, the swap offer, the
-- tourney menu), and BP where the cart pays them.
--
-- Seeded through the engine, never typed into the cart's state by hand:
-- the party (createMon, with the engine's own setMoves / setEvs), the
-- Tower's challenge battle number (FRONTIER_DATA_BATTLE_NUM, as a paused
-- challenge resumes at it) so the seventh battle -- the one that pays BP --
-- is the first one fought, the Pike's hinted room (the hint the attendant
-- would have given, `pikeHintedRoomType`), the Pyramid lead's HP.
--
-- Legs (SOLO_LEGS names; the group is "frontier"):
--
--   frontier-tower           singles: the sixth and seventh battles of a
--                            round (battle number seeded), the next-opponent
--                            menu between them with no RECORD row, the round
--                            won -- streak, record, BP, interview, party
--   frontier-tower-multi     multis with an NPC partner from the partner room:
--                            the double screen, his back pic beside ours
--   frontier-tower-loss      a singles loss: the trainer's win words, no
--                            whiteout, the lobby's LOST path
--   frontier-tower-forfeit   RUN: the forfeit question answered NO (the menu
--                            back, nothing filed), then YES (forfeited)
--   frontier-dome            a Dome match: two of three picked before the
--                            round, the last moves, the tourney resolved
--   frontier-palace          singles: FIGHT is the nature's pick, no move list
--   frontier-palace-double   doubles on the double screen, the pick per seat
--   frontier-palace-cancel   B on the second seat takes the first seat's pick
--                            back; the re-pick is the same pick
--   frontier-arena           a three-turn judged match lost on the judge: the
--                            judgment window, the judged monster's HP kept
--   frontier-factory         rentals fought; the swap offered; the party back
--   frontier-pike            a single-battle room; the damage carried out
--   frontier-pike-double     the double-battle room: two trainers, one
--                            monster each, on the double screen
--   frontier-pyramid         a floor trainer fought with the Pyramid bag (a
--                            HYPER POTION spent and written back)
--
-- Emerald only: FireRed / LeafGreen have no Battle Frontier, so every leg
-- skips there.
--
-- Legal: no ROM value is named here.  Species, moves, items and maps are
-- looked up by pret name in the player's own cart; every number asserted is
-- read back from the engine or the save.

return function(kit)
  local game, H, U = kit.game, kit.H, kit.U
  local log, check, skip = kit.log, kit.check, kit.skip
  local GROUP = "frontier"

  local LEGS = {
    "frontier-tower", "frontier-tower-multi", "frontier-tower-loss", "frontier-tower-forfeit",
    "frontier-dome", "frontier-palace", "frontier-palace-double", "frontier-palace-cancel",
    "frontier-arena", "frontier-factory", "frontier-pike", "frontier-pike-double",
    "frontier-pyramid",
  }
  local any = false
  for _, name in ipairs(LEGS) do
    if kit.legOn(name, GROUP) then any = true end
  end
  if not any then return end

  if not kit.emerald then
    for _, name in ipairs(LEGS) do
      if kit.legOn(name, GROUP) then
        skip(name, kit.VERSION .. " has no Battle Frontier (Emerald only)")
      end
    end
    return
  end

  local solo = kit.solo
  local session = kit.session
  local fight = kit.fight

  -- ------------------------------------------------------------------
  -- the engine, read-only
  -- ------------------------------------------------------------------

  local Battle = require("src.core.game3.battle")
  local Map = require("src.core.game3.map")
  local Objects = require("src.core.game3.objects")
  local Player = require("src.core.game3.player")
  local Space = require("src.core.game3.scripting.space")
  local Choice = require("src.ui.game3.choice")
  local Message = require("src.ui.game3.message")
  local PartyMenu = require("src.ui.game3.party_menu")
  local SaveMenu = require("src.ui.game3.save_menu")
  local Warp = require("src.core.game3.warp")
  local Natives = require("src.core.game3.scripting.natives")
  local Util = require("src.core.game3.rse.frontier.util")
  local D = require("src.core.game3.rse.frontier.trainers")
  local OUTCOME = Natives.B_OUTCOME or {}
  local MODE, LVL = D.MODE, D.LVL

  -- The engine's story helpers (tests/drivers/em_story_util.lua): the
  -- pathing and talking its own Frontier drivers walk these lobbies with.
  -- Read-only; nothing in it is changed or wrapped here.
  local okS, S = pcall(require, "tests.drivers.em_story_util")
  if not (okS and type(S) == "table") then
    for _, name in ipairs(LEGS) do
      if kit.legOn(name, GROUP) then
        skip(name, "the engine's tests/drivers/em_story_util.lua could not be loaded: " .. tostring(S))
      end
    end
    return
  end

  local function frontier() return Util.frontier(session()) end
  local function const(kind, name) return H.g3Const(game, kind, name) end
  local function species(name) return const("species", "SPECIES_" .. name) end
  local function move(name) return const("moves", "MOVE_" .. name) end
  local function item(name) return const("items", "ITEM_" .. name) end
  local function mapNow() local s = session() return s and s.map end
  local function now() return love.timer.getTime() end

  -- A var / flag in the live store the scripts read (em_story_util's own
  -- accessors, Emerald's ids).
  local function var(name) local ok, v = pcall(S.var, name) return ok and v or nil end

  -- The SOLO BATTLES row on: every leg here is the mod's fight.
  kit.setOption(kit.env.OPTION_KEY, true)
  check(solo:isOn(), "frontier: SOLO BATTLES is on for the Frontier legs")
  session().repelSteps = 0

  -- ------------------------------------------------------------------
  -- the party, built by the engine's Frontier builder
  -- ------------------------------------------------------------------

  -- One level-`level` monster of the cart's species `name`, every IV 31,
  -- with exactly `moves` (pret names) and the EV spread given (default the
  -- engine drivers' 252 HP / 252 Atk / 6 Def) -- rse/frontier/trainers.lua
  -- createMon / setMoves / setEvs, the engine's own.
  local function frontierMon(name, level, moves, opts)
    opts = opts or {}
    local s = session()
    local sp = species(name)
    if not sp then return nil, "no SPECIES_" .. name .. " in this cart" end
    local ids = {}
    for i, mv in ipairs(moves) do
      ids[i] = move(mv)
      if not ids[i] then return nil, "no MOVE_" .. mv .. " in this cart" end
    end
    local mon = D.createMon(sp, level, 31, opts.personality or 0, tonumber(s.trainerId) or 0,
      { otName = s.name, moves = {} })
    D.setMoves(mon, ids)
    D.setEvs(mon, opts.evs or { 252, 252, 6, 0, 0, 0 })
    mon.otId, mon.otName, mon.ot = s.trainerId, s.name, s.name
    return mon
  end

  -- The strong four the engine's own Frontier drivers fight with.
  local STRONG = {
    { "METAGROSS", { "METEOR_MASH", "PSYCHIC", "BRICK_BREAK", "SHADOW_BALL" } },
    { "SALAMENCE", { "DRAGON_CLAW", "FLAMETHROWER", "AERIAL_ACE", "CRUNCH" } },
    { "SWAMPERT", { "SURF", "ICE_BEAM", "BRICK_BREAK", "ROCK_SLIDE" } },
    { "LATIOS", { "PSYCHIC", "DRAGON_CLAW", "THUNDERBOLT", "ICE_BEAM" } },
  }

  -- `specs` = { { name, moves, opts? }, ... } -> the party, set on the live
  -- session, and its species in order.  nil + why when the cart lacks one.
  local function seedFrontierParty(specs, level)
    local out, order = {}, {}
    for i, spec in ipairs(specs) do
      local mon, why = frontierMon(spec[1], level or 50, spec[2], spec[3])
      if not mon then return nil, why end
      out[i] = mon
      order[i] = mon.species
    end
    session().party = out
    return out, order
  end

  local function partySpecies()
    local out = {}
    for i, mon in ipairs(session().party or {}) do out[i] = tonumber(mon.species) end
    return out
  end

  local function sameList(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
  end

  local function listText(list)
    local out = {}
    for i, v in ipairs(list or {}) do out[i] = tostring(v) end
    return table.concat(out, ",")
  end

  -- ------------------------------------------------------------------
  -- the cart's own scripts and objects
  -- ------------------------------------------------------------------

  -- The object whose script is pret's `label` on the current map.
  local function objectByScript(label)
    local want = Space.bundle and Space.bundle.labels and Space.bundle.labels[label]
    for _, lid in ipairs(Objects.listActive() or {}) do
      local eo = Objects.find(lid)
      local s = eo and (eo.scriptKey or (eo.def and (eo.def.script or eo.def.scriptKey)))
      if s ~= nil and (s == label or (want ~= nil and s == want)) then return eo end
    end
    return nil
  end

  local function vmRunning() return Space.vm ~= nil and Space.vm:isRunning() or false end

  local function busy()
    local ok, b = pcall(S.busy)
    return ok and b or vmRunning()
  end

  -- The text of the cart's message box, upper-cased.
  local function msgText()
    local ok, page = pcall(Message.currentPage)
    local t = ok and page or nil
    if type(t) == "table" then
      local okT, s = pcall(require("src.core.game3.scripting.text_ir").toAscii, t, {})
      t = okT and s or ""
    end
    return tostring(t or ""):upper()
  end

  local function optionTexts()
    local out = {}
    for i, o in ipairs(Choice.options or {}) do
      local t = type(o) == "table" and (o.text or o.label or o[1]) or o
      if type(t) == "table" then
        local okT, s = pcall(require("src.core.game3.scripting.text_ir").toAscii, t, {})
        t = okT and s or ""
      end
      out[i] = tostring(t or ""):upper():gsub("^%s+", ""):gsub("%s+$", "")
    end
    return out
  end

  local function optionIndex(texts, word, exact)
    for i, t in ipairs(texts) do
      if exact then
        if t == word then return i end
      elseif t:find(word, 1, true) then
        return i
      end
    end
    return nil
  end

  -- Walk the cart's choice cursor onto option `want` with the d-pad, then A
  -- (em_story_util's answerChoice, by keys).
  local function answerChoice(want)
    for _ = 1, 16 do
      if not Choice.isOpen() or Choice.cursor == want then break end
      local cols = Choice.cols or 1
      if cols > 1 and (Choice.cursor - 1) % cols ~= (want - 1) % cols then
        U.tap(game, ((Choice.cursor - 1) % cols < (want - 1) % cols) and "right" or "left")
      else
        U.tap(game, Choice.cursor < want and "down" or "up")
      end
      U.wait(3)
    end
    U.tap(game, "a")
    U.wait(6)
  end

  -- ------------------------------------------------------------------
  -- reading the mod's fight
  -- ------------------------------------------------------------------

  local function lineNow()
    local f = fight()
    local s = f and f.shown
    if type(s) == "table" then s = table.concat(s, " ") end
    if type(s) ~= "string" then return "" end
    return (s:gsub("%s*\n%s*", " "))
  end

  local function fighterOf(id)
    local sim = solo.sim
    return sim and sim.byId and sim.byId[id] or nil
  end

  -- The species on the field for a seat, from the referee (the last one the
  -- seat had out, fainted or not -- pret gBattlerPartyIndexes keeps it).
  local function seatSpecies(id)
    local ft = fighterOf(id)
    if not (ft and ft.active and ft.mons) then return nil end
    local mon = ft.mons[ft.active]
    return mon and tonumber(mon.speciesNum) or nil
  end

  -- ------------------------------------------------------------------
  -- driving the fight with the keys
  -- ------------------------------------------------------------------

  -- The strongest damaging move with PP, preferring one aimed at a chosen
  -- battler (a spread move would hit a partner too); a status move last.
  local function bestDoubleMove(moves)
    local best, bestScore = 1, -1
    for i, mv in ipairs(moves or {}) do
      if (tonumber(mv.pp) or 0) > 0 then
        local power = tonumber(mv.power) or 0
        local score = (power > 0) and (power + ((tonumber(mv.target) or 0) == 0 and 1000 or 0)) or 0
        if score > bestScore then best, bestScore = i, score end
      end
    end
    return best
  end

  local function pickCommand(f, name)
    for i, cmd in ipairs(f:commandList()) do
      if cmd == name then f.commandIndex = i end
    end
    U.tap(game, "a")
    U.wait(8)
  end

  -- One step of the single screen (MediatedBattle).
  local function singleStep(f, plan)
    local phase = f.phase
    if phase == "choose" and not f.result then
      if plan.onChoose and plan.onChoose(f) then return end
      if plan.palace then
        -- FIGHT is the nature's pick: no move list behind it.
        f.commandIndex = 1
        U.tap(game, "a")
        U.wait(4)
        local g = fight()
        if g and g.phase == "palace" then plan.sawPalacePhase = true end
        U.wait(12)
        return
      end
      local index = plan.move and plan.move(f) or kit.bestMove(f)
      kit.fightWith(index)
      return
    end
    if phase == "ask" then
      if plan.onAsk then plan.onAsk(f) return end
      U.tap(game, "b")
      U.wait(6)
      return
    end
    if phase == "move" then
      plan.sawMoveMenu = true
      U.tap(game, "b")
      U.wait(6)
      return
    end
    if phase == "item" or phase == "item_party" or phase == "item_move" or phase == "mimic"
        or (phase == "switch" and not f.replaceOnly) then
      if plan.onMenu and plan.onMenu(f) then return end
      U.tap(game, "b")
      U.wait(6)
      return
    end
    if phase == "palace" then
      plan.sawPalacePhase = true
      U.wait(2)
      return
    end
    kit.nudge()
  end

  -- One step of the double screen (CoopBattle's solo double).
  local function doubleStep(f, plan)
    if f.replacing and f.phase ~= "messages" then
      U.tap(game, "a")
      U.wait(8)
      return
    end
    if f.phase == "choose" and not f.result then
      if plan.onChoose and plan.onChoose(f) then return end
      pickCommand(f, "FIGHT")
      local g = fight()
      if not g then return end
      if plan.palace then
        if g.phase == "move" then plan.sawMoveMenu = true end
        return
      end
      if g.phase ~= "move" then return end
      local moves = g:liveMoves()
      local want = bestDoubleMove(moves)
      for _ = 1, #moves + 1 do
        if g.moveIndex == want then break end
        U.tap(game, "down")
        U.wait(4)
      end
      U.tap(game, "a")
      U.wait(8)
      g = fight()
      if g and g.phase == "target" then
        U.tap(game, "a")
        U.wait(8)
        g = fight()
        if g and g.phase == "target" then U.tap(game, "a") U.wait(8) end
      end
      return
    end
    if f.phase == "move" or f.phase == "target" or f.phase == "switch" then
      U.tap(game, "b")
      U.wait(6)
      return
    end
    kit.nudge()
  end

  local function fightStep(plan)
    local f = fight()
    if not f then return end
    plan.double = f.soloDouble == true or f.ownSlots ~= nil
    if plan.onFrame then plan.onFrame(f) end
    f = fight()
    if not f then return end
    -- the last battlers out, for the interview / lastFrontierBattle checks
    plan.lastMine = seatSpecies("solo_player") or plan.lastMine
    plan.lastFoe = seatSpecies("solo_foe") or plan.lastFoe
    local text = lineNow()
    if text ~= "" and plan.said[#plan.said] ~= text then plan.said[#plan.said + 1] = text end
    if plan.double then doubleStep(f, plan) else singleStep(f, plan) end
  end

  local function sawLine(plan, ...)
    for _, line in ipairs(plan.said) do
      local low = line:lower()
      local all = true
      for i = 1, select("#", ...) do
        if not low:find((select(i, ...)):lower(), 1, true) then all = false end
      end
      if all then return line end
    end
    return nil
  end

  -- ------------------------------------------------------------------
  -- the hall's flow: the cart's scripts, menus and the fights between them
  -- ------------------------------------------------------------------

  -- Drive whatever the cart or the mod has up until `o.until_()` holds:
  --   * the mod's fight -- `fightStep(o.plan)` (each fight a fresh record in
  --     o.fights, its `done` word captured);
  --   * the cart's own battle -- a failure: the hall's fight was not taken;
  --   * the cart's choice -- `o.answer(texts, msg)` (an index), else the
  --     default: YES to a yes / no (NO to RECORD / SWAP), READY in the Dome
  --     menu, else the first row;
  --   * the cart's message -- read through with A;
  --   * the engine's Frontier party menu -- `o.slots(n)` picked, confirmed;
  --   * the save menu -- A;
  --   * `o.ui()` for a hall's own screens (the Factory's, the Dome's).
  local function flow(o)
    o.fights = o.fights or {}
    local deadline = now() + (o.seconds or 300)
    local msgTicks = 0
    local inFight = nil
    local cartBattle = false
    while now() < deadline do
      if o.watch then o.watch() end
      if o.until_ and o.until_() then return true end
      if solo.fight then
        if not inFight then
          inFight = o.newPlan and o.newPlan(#o.fights + 1) or {}
          inFight.said = inFight.said or {}
          inFight.n = #o.fights + 1
          inFight.started = now()
          inFight.cartActive = false
          o.fights[#o.fights + 1] = inFight
          local ctx = solo.gen3
          inFight.ctx = ctx
          if ctx and type(ctx.done) == "function" and not ctx.e2eWrapped then
            local done = ctx.done
            ctx.e2eWrapped = true
            ctx.done = function(word, ...)
              inFight.word = word
              inFight.doneAt = now()
              return done(word, ...)
            end
          end
          if o.onFightStart then o.onFightStart(inFight) end
        end
        if Battle.isActive() then inFight.cartActive = true end
        fightStep(inFight)
      else
        if inFight then
          inFight.ended = now()
          inFight.partyAfter = {}
          for i, mon in ipairs(session().party or {}) do
            inFight.partyAfter[i] = { species = tonumber(mon.species), hp = tonumber(mon.hp),
              maxHp = tonumber(mon.maxHp), status = mon.status }
          end
          if o.onFightEnd then o.onFightEnd(inFight) end
          inFight = nil
        end
        if Battle.isActive() then
          if not cartBattle then
            cartBattle = true
            o.cartBattle = (o.cartBattle or 0) + 1
            log("frontier: the cart ran its own battle on " .. tostring(mapNow()))
          end
          pcall(require("src.core.game3.battle_bridge").finishPending, "run")
          U.wait(10)
        elseif Choice.isOpen() then
          cartBattle = false
          local texts, msg = optionTexts(), msgText()
          o.choices = o.choices or {}
          o.choices[#o.choices + 1] = { texts = table.concat(texts, "/"), msg = msg,
                                        fights = #o.fights, map = mapNow() }
          local want = o.answer and o.answer(texts, msg) or nil
          if not want then
            local yes, no = optionIndex(texts, "YES", true), optionIndex(texts, "NO", true)
            if yes and no then
              want = (msg:find("RECORD", 1, true) or msg:find("SWAP", 1, true)) and no or yes
            else
              want = optionIndex(texts, "READY") or 1
            end
          end
          answerChoice(want)
        elseif Message.isOpen() then
          cartBattle = false
          msgTicks = msgTicks + 1
          if Message.isTyping() then pcall(Message.skipReveal) end
          if o.onMessage then o.onMessage(msgText()) end
          if msgTicks % 4 == 0 then U.tap(game, "a") else U.wait(1) end
        elseif PartyMenu.isOpen() and PartyMenu.mode == "choose_multi" then
          o.partyMenus = (o.partyMenus or 0) + 1
          if o.onPartyMenu then o.onPartyMenu(o.partyMenus) end
          local slots = (o.slots and o.slots(o.partyMenus)) or { 1, 2, 3 }
          for _, slot in ipairs(slots) do
            PartyMenu.enterChosenMon(slot)
            U.wait(4)
          end
          PartyMenu.confirmChosenMons()
          U.wait(10)
        elseif SaveMenu.isOpen() then
          o.saves = (o.saves or 0) + 1
          U.tap(game, "a")
          U.wait(8)
        elseif o.ui and o.ui() then
          -- a hall's own screen, driven
        else
          U.wait(1)
        end
      end
      if not o.until_ and not solo.fight and not busy() then
        U.wait(3)
        if not busy() and not solo.fight then return true end
      end
    end
    log(("frontier: %s ran out of time on %s (vm %s)"):format(o.tag or "flow", tostring(mapNow()),
      tostring(pcall(S.vmWhere) and S.vmWhere() or "?")))
    return o.until_ and o.until_() or false
  end

  -- Stand in a lobby, the field quiet.
  local function toLobby(mapId, x, y)
    local ok = H.g3Teleport(game, mapId, x, y, "up")
    flow({ tag = "lobby settle", seconds = 20 })
    return ok and mapNow() == mapId
  end

  -- Talk to the hall's attendant (pret label `label`), the player walked up
  -- to them by the engine's own pathing.
  local function talkTo(label)
    local eo = objectByScript(label)
    if not eo then return false, "no object runs " .. label .. " on " .. tostring(mapNow()) end
    if S.talkTo(game, eo) then return true end
    return false, "could not reach the object running " .. label
  end

  -- Whatever a leg left behind (a fight still up, a script still talking) is
  -- played out so the next leg starts on a quiet field; a challenge still on
  -- the books is put down the way the cart's reset does.
  local function cleanUp()
    local deadline = now() + 60
    while now() < deadline do
      if solo.fight then
        fightStep({ said = {} })
      elseif Choice.isOpen() then
        answerChoice(optionIndex(optionTexts(), "NO", true) or 1)
      elseif Message.isOpen() then
        U.tap(game, "a")
        U.wait(4)
      elseif not busy() then
        break
      else
        U.wait(1)
      end
    end
    if vmRunning() then pcall(function() Space.vm:halt(true) end) end
    local f = frontier()
    if tonumber(f.challengeStatus) ~= 0 then f.challengeStatus = 0 end
  end

  local function bp() return tonumber(frontier().battlePoints) or 0 end

  -- The BP the cart's table pays for a round of `facility` in `mode` at
  -- `streak` (frontier_util.c:1853 GiveBattlePoints, the engine's
  -- Util.giveBattlePoints arithmetic over the engine's own award table).
  local function bpAward(facility, mode, streak)
    local stages = D.STAGES_PER_CHALLENGE or 7
    local challengeNum = math.floor(streak / stages)
    if challengeNum ~= 0 then challengeNum = challengeNum - 1 end
    local awards = D.manifest().battlePointAwards
    if challengeNum >= #awards then challengeNum = #awards - 1 end
    local row = awards[challengeNum + 1]
    return row and row[facility + 1] and tonumber(row[facility + 1][mode + 1]) or nil
  end

  local function runLeg(name, body)
    if not kit.legOn(name, GROUP) then return end
    log("frontier: --- " .. name)
    local ok, err = pcall(body)
    check(ok, name .. ": the leg ran to its end", tostring(err))
    cleanUp()
  end

  -- ==================================================================
  -- Battle Tower
  -- ==================================================================

  local TOWER_LOBBY = "EM_BATTLE_FRONTIER_BATTLE_TOWER_LOBBY"
  local TOWER_ROOM = "EM_BATTLE_FRONTIER_BATTLE_TOWER_BATTLE_ROOM"
  local TOWER_CORRIDOR = "EM_BATTLE_FRONTIER_BATTLE_TOWER_CORRIDOR"

  -- frontier-tower: battles six and seven of a singles round.
  runLeg("frontier-tower", function()
    local L = "frontier-tower"
    local party, order = seedFrontierParty({ STRONG[1], STRONG[2], STRONG[3], STRONG[4] })
    if not party then return skip(L, tostring(order)) end
    if not check(toLobby(TOWER_LOBBY, 6, 6), L .. ": standing in the Battle Tower lobby",
        tostring(mapNow())) then return end
    local f = frontier()
    local bpBefore = bp()
    local numWinsBefore = tonumber(f.towerNumWins) or 0
    kit.shot(L .. "-lobby")
    local ok, why = talkTo("BattleFrontier_BattleTowerLobby_EventScript_SinglesAttendant")
    if not check(ok, L .. ": the singles attendant's reception script runs", why) then return end
    local seeded, askedBetween, statusAtFight = false, nil, {}
    local o = {
      tag = L, seconds = 420,
      watch = function()
        -- A paused challenge resumes at its battle number; this one is put
        -- at the sixth battle once the reception has started it (tower_init
        -- zeroes it) and before the battle room reads it.
        if not seeded and (mapNow() == TOWER_CORRIDOR or mapNow() == TOWER_ROOM)
            and tonumber(f.challengeStatus) == Util.CHALLENGE_STATUS.SAVING then
          seeded = true
          f.curChallengeBattleNum = 5
          log(L .. ": challenge battle number seeded to 5 on " .. tostring(mapNow()))
        end
      end,
      until_ = function()
        return mapNow() == TOWER_LOBBY and not busy() and tonumber(f.challengeStatus) == 0
          and not solo.fight
      end,
      answer = function(texts, msg)
        -- between the two fights: the next-opponent menu
        if optionIndex(texts, "RETIRE") and optionIndex(texts, "REST") then
          if askedBetween == nil and #(statusAtFight) >= 1 then
            askedBetween = table.concat(texts, "/")
            kit.shot(L .. "-next-opponent")
          end
          return optionIndex(texts, "CONTINUE") or 1
        end
        return nil
      end,
      newPlan = function(n)
        return { onFrame = function(fl)
          if not fl.shotCommand and fl.phase == "choose" then
            fl.shotCommand = true
            kit.shot(L .. "-fight-" .. n)
          end
        end }
      end,
      onFightStart = function(rec)
        statusAtFight[#statusAtFight + 1] = tonumber(f.curChallengeBattleNum)
        rec.cartActiveAtStart = Battle.isActive()
        rec.hall = solo.gen3 and solo.gen3.facility3
        rec.kind3 = solo.gen3 and solo.gen3.stand and solo.gen3.stand.kind3
      end,
    }
    local reached = flow(o)
    check(o.partyMenus and o.partyMenus >= 1, L .. ": the reception opened the Frontier party menu "
      .. "(ChoosePartyForBattleFrontier)", tostring(o.partyMenus))
    check((o.saves or 0) >= 1, L .. ": the reception saved before the elevator (Common_EventScript_SaveGame)")
    check(seeded, L .. ": the challenge reached the corridor")
    check(#o.fights == 2, L .. ": two Tower battles were fought on the mod's screen", #o.fights)
    for i, rec in ipairs(o.fights) do
      check(rec.hall == "tower", L .. ": battle " .. i .. " is the Tower's facility fight", tostring(rec.hall))
      check(not rec.cartActive, L .. ": battle " .. i .. ": the cart's own battle never ran under it")
      check(rec.word == "win", L .. ": battle " .. i .. " ends in done('win')", tostring(rec.word))
    end
    check(askedBetween ~= nil and not askedBetween:find("RECORD", 1, true),
          L .. ": between the battles the next-opponent menu has no RECORD row (the mod's "
          .. "fight leaves disableRecordBattle set)", tostring(askedBetween))
    check(not o.cartBattle, L .. ": the cart never ran a battle of its own")
    check(reached, L .. ": the round won, back in the lobby with the challenge closed",
          tostring(mapNow()) .. " status " .. tostring(f.challengeStatus))
    -- what the cart leaves
    local streak = Util.get2(f.towerWinStreaks, MODE.SINGLES, LVL.L50)
    check(streak == 2, L .. ": the singles Lv.50 win streak counts both wins", streak)
    check(Util.get2(f.towerRecordWinStreaks, MODE.SINGLES, LVL.L50) >= 2,
          L .. ": the record streak is saved (tower_save 0)",
          Util.get2(f.towerRecordWinStreaks, MODE.SINGLES, LVL.L50))
    check((tonumber(f.towerNumWins) or 0) == numWinsBefore + 2, L .. ": towerNumWins +2",
          tostring(numWinsBefore) .. " -> " .. tostring(f.towerNumWins))
    local award = bpAward(D.FACILITY.TOWER, MODE.SINGLES, streak)
    check(award ~= nil and bp() == bpBefore + award, L .. ": the seventh win paid the cart's BP",
          ("%d -> %d (award %s)"):format(bpBefore, bp(), tostring(award)))
    local last = session().lastFrontierBattle or {}
    local rec = o.fights[#o.fights] or {}
    check(last.playerSpecies ~= nil and tonumber(last.playerSpecies) == rec.lastMine,
          L .. ": lastFrontierBattle names our last monster out",
          tostring(last.playerSpecies) .. " vs " .. tostring(rec.lastMine))
    check(last.opponentSpecies ~= nil and tonumber(last.opponentSpecies) == rec.lastFoe,
          L .. ": lastFrontierBattle names the foe's last monster out",
          tostring(last.opponentSpecies) .. " vs " .. tostring(rec.lastFoe))
    local iv = f.towerInterview or {}
    check(tonumber(iv.playerSpecies) == tonumber(last.playerSpecies)
          and tonumber(iv.opponentSpecies) == tonumber(last.opponentSpecies),
          L .. ": the Tower interview was written from this fight (tower_setinterviewdata)",
          tostring(iv.playerSpecies) .. "/" .. tostring(iv.opponentSpecies))
    check(tonumber(f.towerBattleOutcome) == OUTCOME.WON, L .. ": the interview's outcome is WON",
          tostring(f.towerBattleOutcome))
    check(tonumber(f.challengeStatus) == 0, L .. ": the challenge status is cleared", f.challengeStatus)
    check(sameList(partySpecies(), order), L .. ": LoadPlayerParty put the whole party back in order",
          listText(partySpecies()))
    kit.shot(L .. "-after")
  end)
end
