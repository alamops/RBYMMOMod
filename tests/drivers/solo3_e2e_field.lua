-- ROM-backed field-family coverage. Entry is through the engine's battle
-- bridge (or the TEACHY TV start), never SoloBattle's direct test entries.
-- Map walking and story prerequisites are seeded; every fight runs on the
-- real mod screen and checks the live session after the engine continuation.
return function(kit)
  local game, H, U, solo = kit.game, kit.H, kit.U, kit.solo
  local check, skip, session = kit.check, kit.skip, kit.session
  local legs = { "safari-run", "safari-ball", "roamer-flee", "roamer-catch",
    "legendary-win", "scripted-catch", "ghost-veiled", "ghost-unveiled",
    "first-battle", "tutorial-oldman", "tutorial-wally", "pokedude-battle",
    "pokedude-status", "pokedude-matchups", "pokedude-catching", "pokedude-quit" }
  local function wanted(name)
    return kit.legOn(name, "field") or kit.legOn(name, name:match("^(%a+)%-"))
  end
  local any = false
  for _, name in ipairs(legs) do if wanted(name) then any = true end end
  if not any then return end

  local Runtime = require("src.core.game3.runtime")
  local Bridge = require("src.core.game3.battle_bridge")
  local Battle = require("src.core.game3.battle")
  local Safari = require("src.core.game3.safari")
  local Roamer = require("src.core.game3.roamer")
  local Bag = require("src.core.game3.bag")
  local Natives = require("src.core.game3.scripting.natives")
  local Map = require("src.core.game3.map")
  local Party = require("src.core.game3.party")
  local function copy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = copy(v) end
    return out
  end
  local function equal(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do if not equal(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
  end
  local function item(name) return H.g3ItemId(game, name) end
  local function throwBall(ball)
    kit.command("ITEM")
    local f = kit.fight()
    if not (f and f.phase == "item") then return false end
    for i, row in ipairs(f:usableItems()) do
      if tonumber(row.id) == ball then f.itemIndex = i; U.tap(game, "a"); U.wait(10); return true end
    end
    check(false, "the seeded ball is available in the real bag menu")
    return false
  end
  local function prepare(name)
    check(kit.settle(), name .. ": field settled before staging")
    kit.setOption("solo", true)
    kit.setOption("classicui", true)
    H.g3Teleport(game, kit.GRASS_MAP, 1, 1, "down")
    local mon = kit.seed(kit.STARTER, 60)
    check(mon ~= nil, name .. ": a healthy party was seeded")
    session().roamer = nil
    Safari.exit(session())
    U.wait(20) -- install the real field diverts before the engine start
  end
  local function start(name, foe, opts, expected)
    opts = opts or {}
    local result = { calls = 0, map = Map.current }
    opts.done = function(word) result.word = word; result.calls = result.calls + 1 end
    kit.log(name .. ": engine BattleBridge.start, prerequisites seeded")
    Bridge.start(Runtime._mod, game, foe, opts)
    check(H.waitSeconds(game, function() return solo.fight ~= nil end, 30, name .. " divert"),
      name .. ": the engine start reached solo")
    check(solo.gen3 and solo.gen3.name == expected, name .. ": the correct fight family was selected")
    check(not Battle.isActive(), name .. ": the native battle did not also start")
    return result
  end
  local function finish(name, result, choose, word)
    check(kit.driveToEnd(choose or function(f) kit.fightWith(kit.bestMove(f)) end, 180),
      name .. ": the battle screen closed")
    check(kit.settle(), name .. ": post-battle flow completed")
    check(result.calls == 1, name .. ": the continuation ran exactly once", tostring(result.calls))
    if word then check(result.word == word, name .. ": the continuation received " .. word, tostring(result.word)) end
    if result.word then
      check(session().battleOutcome == Natives.outcome_to_code(result.word), name .. ": the save outcome matches")
    end
    check(not solo:isRunning() and not Battle.isActive(), name .. ": no battle remains running")
    check(H.g3Free(game), name .. ": the player can move again")
    kit.shot(name .. "-after")
  end
  local function leg(name, fn, available)
    if not wanted(name) then return end
    if available == false then skip(name, kit.VERSION .. " has no such fight") return end
    prepare(name)
    fn(name)
  end

  for _, name in ipairs({ "safari-run", "safari-ball" }) do
    leg(name, function(n)
      Safari.enter(session())
      local before = copy(session().party)
      local balls = Safari.balls(session())
      local result = start(n, kit.wildOf(kit.WILD, 3), { wild = true }, "safari")
      local thrown = false
      finish(n, result, function()
        if n == "safari-ball" and not thrown then thrown = true; kit.command("BALL")
        else kit.command("RUN") end
      end, n == "safari-run" and "run" or nil)
      check(Safari.balls(session()) == balls - (thrown and 1 or 0), n .. ": exactly the thrown balls were spent")
      -- A catch may append a monster, but Safari never damages the old party.
      for i, mon in ipairs(before) do check(equal(mon, session().party[i]), n .. ": existing party slot " .. i .. " unchanged") end
      Safari.exit(session())
    end)
  end

  for _, name in ipairs({ "roamer-flee", "roamer-catch" }) do
    leg(name, function(n)
      kit.seed(kit.STARTER, 5) -- the roamer must flee before our damaging move
      if kit.emerald then Roamer.initRse(session(), true) else Roamer.init(session(), 0) end
      local r = session().roamer
      check(r and r.active, n .. ": the engine created a roamer")
      if not r then return end
      local hp, pid = r.hp, r.personality or r.pid
      local foe = copy(r); foe.speciesId = r.species
      local ball = item("MASTER_BALL")
      if n == "roamer-catch" then Bag.add(session().bag, ball, 1) end
      local count = #session().party
      local result = start(n, { species = r.species, level = r.level, roamer = true, foe = foe },
        { wild = true, roamer = true }, "roamer")
      finish(n, result, function(f)
        if n == "roamer-catch" then throwBall(ball)
        else kit.fightWith(kit.bestMove(f)) end
      end, n == "roamer-catch" and "caught" or "mon_fled")
      check(r.active == (n == "roamer-flee"), n .. ": roamer activation matches the ending")
      if n == "roamer-flee" then
        check(r.hp == hp, n .. ": the fleeing roamer kept its HP")
      else
        local caught = session().party[count + 1]
        check(caught and (caught.personality or caught.pid) == pid, n .. ": the saved roamer personality was caught")
      end
    end)
  end

  leg("legendary-win", function(n)
    local species = kit.emerald and "RAYQUAZA" or "MEWTWO"
    local result = start(n, kit.wildOf(species, 5), { wild = true, legendary = true }, "legendary")
    finish(n, result, nil, "win")
  end)
  leg("scripted-catch", function(n)
    local ball = item("MASTER_BALL")
    Bag.add(session().bag, ball, 1)
    local count = #session().party
    local result = start(n, kit.wildOf(kit.WILD, 3), { wild = true, wildScripted = true }, "scripted")
    finish(n, result, function(f) throwBall(ball) end, "caught")
    check(#session().party == count + 1, n .. ": the scripted catch entered the party")
  end)
  for _, name in ipairs({ "ghost-veiled", "ghost-unveiled" }) do
    leg(name, function(n)
      local which = n == "ghost-veiled" and "veiled" or "unveiled"
      local result = start(n, kit.wildOf("MAROWAK", 5), { wild = true, ghost = true, ghostUnveiled = which == "unveiled" }, "ghost")
      finish(n, result, n == "ghost-veiled" and function() kit.command("RUN") end or nil,
        n == "ghost-veiled" and "run" or "win")
    end, not kit.emerald)
  end

  leg("first-battle", function(n)
    if kit.emerald then
      local result = { calls = 0 }
      Bridge.startFirstBattle(Runtime._mod, game, { done = function(word) result.word = word; result.calls = result.calls + 1 end })
      check(solo.gen3 and solo.gen3.name == "firstBattle", n .. ": Birch's native start diverted")
      finish(n, result, nil, "win")
    else
      local Trainers = require("src.core.game3.scripting.trainers")
      local pack = Trainers.pack() or {}
      local tid
      for id, row in pairs(pack.trainers or {}) do
        if type(row.party) == "table" and #row.party == 1 and (tonumber(row.party[1].level) or 99) <= 5 then
          if not tid or tonumber(id) < tid then tid = tonumber(id) end
        end
      end
      check(tid ~= nil, n .. ": a first-rival trainer was found in the ROM")
      if not tid then return end
      local result = start(n, Trainers.foeFromId(tid), { trainerId = tid, firstBattle = true }, "firstBattle")
      finish(n, result, nil, "win")
    end
  end)

  for _, name in ipairs({ "tutorial-oldman", "tutorial-wally" }) do
    leg(name, function(n)
      local old = n == "tutorial-oldman"
      -- Wally's native lends Zigzagoon before starting the tutorial. Reproduce
      -- that prerequisite; the real bridge and scripted tutorial then run.
      local original = session().party
      if not old then
        session().party = {}
        Party.giveMon(session(), H.g3Species(game, "ZIGZAGOON"), 7)
      end
      local before, bag = copy(session().party), copy(session().bag)
      local result = start(n, kit.wildOf(old and "WEEDLE" or "RALTS", 5),
        { wild = true, tutorialKind = old and "oldMan" or "wally", oldManTutorial = old or nil }, "tutorial")
      finish(n, result, function() kit.nudge() end, "caught")
      check(equal(before, session().party), n .. ": the forced catch left the demonstration party untouched")
      check(equal(bag, session().bag), n .. ": the player's bag was restored")
      session().party = original
    end, (name == "tutorial-wally") == kit.emerald)
  end

  local demos = { { "pokedude-battle", 0 }, { "pokedude-status", 1 },
    { "pokedude-matchups", 2 }, { "pokedude-catching", 3 }, { "pokedude-quit", 0 } }
  for _, demo in ipairs(demos) do
    leg(demo[1], function(n)
      local PD = require("src.core.game3.battle.pokedude")
      local before, bag = copy(session().party), copy(session().bag)
      local result = { calls = 0 }
      local started = PD.startTeachyTvBattle(session(), demo[2], { onDone = function(code)
        result.code = code; result.calls = result.calls + 1
      end })
      check(started == true, n .. ": the real TEACHY TV start accepted the demonstration")
      check(H.waitSeconds(game, function() return solo.fight ~= nil end, 30, n .. " divert"), n .. ": TEACHY TV reached solo")
      check(solo.gen3 and solo.gen3.tutorial3 == "pokedude", n .. ": the POKe DUDE tutorial was selected")
      if n == "pokedude-quit" then U.hold(game, "b", 40) end
      check(kit.driveToEnd(function() kit.nudge() end, 240), n .. ": the demonstration ended")
      check(kit.settle(), n .. ": the field resumed")
      check(result.calls == 1, n .. ": TEACHY TV was notified once", tostring(result.calls))
      local expected = n == "pokedude-quit" and PD.OUTCOME.DREW
        or (n == "pokedude-catching" and PD.OUTCOME.CAUGHT or PD.OUTCOME.WON)
      check(result.code == expected, n .. ": TEACHY TV received the proper outcome", tostring(result.code))
      check(equal(before, session().party), n .. ": the player's party was restored")
      check(equal(bag, session().bag), n .. ": the player's bag was restored")
      check(not Battle.isActive() and not solo:isRunning(), n .. ": no battle remains active")
      kit.shot(n .. "-after")
    end, not kit.emerald)
  end
end
