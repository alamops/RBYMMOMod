-- Driver: three guests, one party of three, coop_npc then coop_wild.
--
-- Three instances under MMO_ROLE=a|b|c, launched by
-- tests/drivers/run-trip-e2e.sh (Node hub, all JOIN).
--
-- Minimum contract: party of 3, coop_npc field with three ally seats,
-- coop_wild field with three humans and one wild, then DONE.

if os.getenv("MMO_SOUND") ~= "1" and love and love.audio then
  love.audio.setVolume(0)
end

local ROLES = {
  a = { name = "ALPHA",   species = "CHARIZARD", level = 45, lead = true },
  b = { name = "BETA",    species = "PIKACHU",    level = 45 },
  c = { name = "CHARLIE", species = "BLASTOISE",   level = 45 },
}
local ORDER = { "a", "b", "c" }

local ROLE = tostring(os.getenv("MMO_ROLE") or "a"):lower()
if not ROLES[ROLE] then ROLE = "a" end

return function(game)
  local H = dofile("mods/rby_mmo/tests/drivers/mmo_util.lua")
  local U = H.U
  local TAG = "MMO_TRIP_" .. ROLE:upper() .. ":"
  local ME = ROLES[ROLE]
  local SHOT_DIR = os.getenv("SHOT_DIR") or "/tmp/rby_mmo_trip_shots"
  local RAW_CODE = os.getenv("MMO_HUB_CODE") or ""

  local function log(...) U.log(TAG, ...) end
  local failures = 0
  local function check(ok, what)
    if ok then
      log("ok " .. what)
    else
      failures = failures + 1
      log("FAIL " .. what)
    end
    return ok
  end
  local function shot(name)
    U.shot(game, ("%s/trip-%s-%s.png"):format(SHOT_DIR, ROLE, name))
  end

  local function marker(side, tag) return ("trip_%s_%s"):format(side, tag) end

  local function rendezvous(tag)
    H.signal(marker(ROLE, tag))
    local ok = true
    for _, side in ipairs(ORDER) do
      if side ~= ROLE then
        if not H.await(game, marker(side, tag)) then ok = false end
      end
    end
    return ok
  end

  local TAGS = { "ready", "seen", "party", "npc", "wild", "left" }
  local function abandon()
    for _, tag in ipairs(TAGS) do H.signal(marker(ROLE, tag)) end
  end

  local function bail(what)
    check(false, what)
    abandon()
    log(("RESULT %d failure(s)"):format(failures))
    log("DONE")
    U.wait(30)
    love.event.quit()
  end

  if not H.newGame(game, TAG) then
    log("RESULT 1 failure(s)")
    return
  end
  if game.save and game.save.player then
    game.save.player.name = ME.name
  end

  local exports = H.requireMod(game, TAG)
  if not exports then
    abandon()
    log("RESULT 1 failure(s)")
    log("DONE")
    return
  end

  local Pokemon = require("src.pokemon.Pokemon")
  game.save.party = { Pokemon.new(game.data, ME.species, ME.level) }
  H.frontloadDamage(game.data, game.save.party[1])

  local code = H.codeFrom(RAW_CODE)
  if not code then bail("a join code was supplied") return end

  if not H.openMmo(game) then bail("the MMO menu opens") return end
  if not H.selectLabel(game, "JOIN GAME") then bail("JOIN GAME is on the menu") return end
  U.wait(20)
  check(H.selectLabel(game, "JOIN"), "confirmed the trainer and moved on")
  U.wait(20)
  if H.addressGrid(game) == nil then bail("the address screen opened") return end
  U.tap(game, "start")
  U.wait(60)
  check(H.enterJoinCode(game, code), "the hub's code can be typed on the grid")
  U.wait(60)

  local connected = H.waitSeconds(game, function() return exports.isConnected() end,
                                  120, "the connection to open")
  if not connected then bail("connected to the dedicated hub") return end
  check(connected, "connected to the dedicated hub")
  H.closeToOverworld(game)
  H.signal(marker(ROLE, "ready"))
  for _, side in ipairs(ORDER) do
    if side ~= ROLE then H.await(game, marker(side, "ready")) end
  end

  check(H.waitSeconds(game, function() return #exports.players() >= 2 end, 120,
                      "the other two to appear on the roster"),
        "both other guests are on the roster")
  rendezvous("seen")

  local function invite(name)
    H.closeToOverworld(game)
    if H.openMmo(game) and H.selectLabel(game, "PLAYERS") then
      U.wait(25)
      if H.selectLabel(game, name) then
        U.wait(30)
        return H.selectLabel(game, "INVITE")
      end
    end
    return false
  end

  if ME.lead then
    check(invite(ROLES.b.name), "invited BETA")
    -- The lead must not mash A here: drivePrompts walks START into JOIN
    -- and lands on the code grid, so the second openMmo never sees MMO.
    check(H.waitSeconds(game, function() return #exports.party() >= 2 end, 90,
                        "BETA to join the party"),
          "BETA joined")
    check(invite(ROLES.c.name), "invited CHARLIE")
  end
  check(H.drivePrompts(game, function() return #exports.party() == 3 end, 120),
        "the party formed with three members")
  H.closeToOverworld(game)
  rendezvous("party")

  -- ------- coop_npc (party vs trainer)
  if ROLE == "a" then
    local coopClass = H.coopTrainer(game.data)
    check(coopClass ~= nil, "picked a trainer class to stage")
    local staged = H.stageTrainer(game, coopClass, function() end)
    check(staged ~= nil, "staged a trainer battle on the party lead")
    H.softenTopTrainer(game)
    H.signal(marker(ROLE, "npc_start"))
  else
    H.await(game, marker("a", "npc_start"))
  end

  local function countAllyHumans(top)
    if not (top and top.sim) then return 0 end
    local n = 0
    for _, slot in ipairs(top.sim.slots) do
      if slot.side == "a" and slot.owner then n = n + 1 end
    end
    return n
  end

  local onNpc = H.waitSeconds(game, function()
    local top = H.top(game)
    return top ~= nil and top.sim ~= nil and countAllyHumans(top) >= 3
  end, 180, "the coop_npc field with three ally seats")
  check(onNpc, "a three-wide coop_npc battle is on screen")
  local topNpc = H.top(game)
  check(topNpc and topNpc.mode == "coop_npc", "mode is coop_npc")
  check(H.awaitMediatedCoop(game, 60, "coop_npc"),
        "the Party-vs-NPC fight is hub-refereed")
  check(H.awaitCommandMenu(game, "the coop_npc command menu"),
        "the coop_npc command grid opens")
  U.wait(20)
  shot("coop-npc")
  check(exports.coopDrawFailed() == false, "coop_npc drew without error")

  local npcDone = H.drivePrompts(game, function()
    local top = H.top(game)
    return top == nil or top.sim == nil
  end, 240, function() U.tap(game, "a") end)
  check(npcDone, "the coop_npc fight runs to an end")
  H.closeToOverworld(game)
  rendezvous("npc")

  -- ------- coop_wild (party vs one wild)
  local WILD_SPECIES = "PIDGEY"
  if ROLE == "a" then
    check(H.giveItem(game, "MASTER_BALL", 1), "seeded a MASTER_BALL for the catch")
    local stagedWild = H.stageWild(game, WILD_SPECIES, 5, function() end)
    check(stagedWild ~= nil, "staged a wild battle on the party lead")
    H.signal(marker(ROLE, "wild_start"))
  else
    H.await(game, marker("a", "wild_start"))
  end

  local onWild = H.waitSeconds(game, function()
    local top = H.top(game)
    return top ~= nil and top.sim ~= nil and #top.sim.slots >= 4
      and countAllyHumans(top) >= 3
  end, 180, "the coop_wild field with three humans and one wild")
  check(onWild, "a four-slot coop_wild battle is on screen")
  local topWild = H.top(game)
  check(topWild and topWild.mode == "coop_wild", "mode is coop_wild")
  check(H.awaitMediatedCoop(game, 60, "coop_wild"),
        "the Party-vs-Wild fight is hub-refereed")

  if ROLE == "a" then
    check(H.awaitCommandMenu(game, "the command menu before MASTER_BALL"),
          "the coop_wild command grid opens")
    check(H.throwBattleItem(game, "MASTER_BALL"),
          "filed MASTER_BALL from the ITEM menu")
  end

  U.wait(20)
  shot("coop-wild")
  check(exports.coopDrawFailed() == false, "coop_wild drew without error")

  local wildDone = H.drivePrompts(game, function()
    local top = H.top(game)
    return top == nil or top.sim == nil
  end, 240, function() U.tap(game, "a") end)
  check(wildDone, "the coop_wild fight runs to an end")
  H.closeToOverworld(game)
  rendezvous("wild")

  for _ = 1, 3 do
    if not exports.isConnected() then break end
    H.closeToOverworld(game)
    if H.openMmo(game) and H.selectLabel(game, "LEAVE") then
      U.wait(45)
      if H.waitSeconds(game, function() return not exports.isConnected() end, 30,
                       "this instance to leave") then
        break
      end
    end
    U.wait(30)
  end
  check(H.waitSeconds(game, function() return not exports.isConnected() end, 30,
                      "this instance to leave"),
        "LEAVE disconnects this guest")
  H.signal(marker(ROLE, "left"))

  log(("RESULT %d failure(s)"):format(failures))
  log("DONE")
  U.wait(60)
  love.event.quit()
end
