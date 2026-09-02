-- Gen 2 trip driver: three Gold guests, party of three, coop_npc + coop_wild.
--
-- Pair with tests/drivers/run-trip-e2e-gen2.sh (Node hub, all JOIN).

if os.getenv("MMO_SOUND") ~= "1" and love and love.audio then
  love.audio.setVolume(0)
end

local ROLES = {
  a = { name = "ALPHA",   species = "TYPHLOSION", level = 45, lead = true },
  b = { name = "BETA",    species = "PIKACHU",     level = 45 },
  c = { name = "CHARLIE", species = "FERALIGATR",  level = 45 },
}
local ORDER = { "a", "b", "c" }

local ROLE = tostring(os.getenv("MMO_ROLE") or "a"):lower()
if not ROLES[ROLE] then ROLE = "a" end

return function(game)
  local H = dofile("mods/rby_mmo/tests/drivers/mmo_util.lua")
  local U = H.U
  local TAG = "MMO_TRIP_" .. ROLE:upper() .. ":"
  local ME = ROLES[ROLE]
  local SHOT_DIR = os.getenv("SHOT_DIR") or "/tmp/rby_mmo_trip_gen2_shots"
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
    U.shot(game, ("%s/trip-g2-%s-%s.png"):format(SHOT_DIR, ROLE, name))
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

  local TAGS = { "ready", "seen", "spread", "party", "npc", "wild", "left" }
  local function abandon()
    for _, tag in ipairs(TAGS) do H.signal(marker(ROLE, tag)) end
  end

  local function bail(what)
    check(false, what)
    abandon()
    log(("RESULT %d failure(s)"):format(failures))
    log("DONE")
    U.wait(30)
    love.event.quit(failures > 0 and 1 or 0)
  end

  check(H.bootToPlay(game), "Gold free-roam is reachable under the driver")
  check(H.generation(game) == 2, "this instance boots generation 2")

  if game.save and game.save.player then
    game.save.player.name = ME.name
  end

  local exports = H.requireMod(game, TAG)
  if not exports then
    abandon()
    log("RESULT 1 failure(s)")
    log("DONE")
    love.event.quit(1)
    return
  end

  local mon = H.seedParty(game, ME.species, ME.level)
  if mon then H.frontloadDamage(game.data, mon) end

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

  -- Same tile after JOIN; interact INVITE hits whoever is stacked. Offset
  -- BETA and CHARLIE so the lead can face each of them in turn.
  local SPREAD = { b = "left", c = "right" }
  if SPREAD[ROLE] then U.hold(game, SPREAD[ROLE], 22) end
  U.wait(30)
  rendezvous("spread")

  -- Gold's MMO > PLAYERS row is often unscannable after JOIN (mmo_join_gen2
  -- uses interact INVITE for the same reason).
  local function invite(name)
    H.closeToOverworld(game, 48)
    local row = H.avatarRow(exports, name)
    if not (row and row.rosterX) then return false end
    H.teleport(game, row.map, row.rosterX, row.rosterY + 1, "up")
    U.wait(60)
    U.tap(game, "a")
    U.wait(45)
    return H.selectLabel(game, "INVITE")
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

  local function countAllyHumans(top)
    if not (top and top.sim) then return 0 end
    local n = 0
    for _, slot in ipairs(top.sim.slots) do
      if slot.side == "a" and slot.owner then n = n + 1 end
    end
    return n
  end

  if ROLE == "a" then
    local coopClass = H.coopTrainer(game.data)
    check(coopClass ~= nil, "picked a trainer class to stage")
    check(H.stageTrainer(game, coopClass, function() end) ~= nil,
          "staged a trainer battle on the party lead")
    H.softenTopTrainer(game)
    H.signal(marker(ROLE, "npc_start"))
  else
    H.await(game, marker("a", "npc_start"))
  end

  check(H.waitSeconds(game, function()
    local top = H.top(game)
    return top ~= nil and top.sim ~= nil and countAllyHumans(top) >= 3
  end, 180, "the coop_npc field with three ally seats"),
        "a three-wide coop_npc battle is on screen")
  local topNpc = H.top(game)
  check(topNpc and topNpc.mode == "coop_npc", "mode is coop_npc")
  check(H.awaitMediatedCoop(game, 60, "coop_npc"),
        "the Party-vs-NPC fight is hub-refereed")
  check(H.awaitCommandMenu(game, "the coop_npc command menu"),
        "the coop_npc command grid opens")
  U.wait(20)
  shot("coop-npc")
  check(exports.coopDrawFailed() == false, "coop_npc drew without error")
  check(H.drivePrompts(game, function()
    local top = H.top(game)
    return top == nil or top.sim == nil
  end, 240, function() U.tap(game, "a") end),
        "the coop_npc fight runs to an end")
  H.closeToOverworld(game)
  rendezvous("npc")

  local WILD_SPECIES = "PIDGEY"
  if ROLE == "a" then
    check(H.giveItem(game, "MASTER_BALL", 1), "seeded a MASTER_BALL for the catch")
    check(H.stageWild(game, WILD_SPECIES, 5, function() end) ~= nil,
          "staged a wild battle on the party lead")
    H.signal(marker(ROLE, "wild_start"))
  else
    H.await(game, marker("a", "wild_start"))
  end

  check(H.waitSeconds(game, function()
    local top = H.top(game)
    return top ~= nil and top.sim ~= nil and #top.sim.slots >= 4
      and countAllyHumans(top) >= 3
  end, 180, "the coop_wild field with three humans and one wild"),
        "a four-slot coop_wild battle is on screen")
  check(H.top(game).mode == "coop_wild", "mode is coop_wild")
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
  check(H.drivePrompts(game, function()
    local top = H.top(game)
    return top == nil or top.sim == nil
  end, 240, function() U.tap(game, "a") end),
        "the coop_wild fight runs to an end")
  H.closeToOverworld(game)
  rendezvous("wild")

  -- Gold StartMenu is often unscannable after a fight (mmo_join_gen2). Try
  -- the LEAVE row, then exports.leave so the harness still finishes cleanly.
  local left = not exports.isConnected()
  if not left then
    H.closeToOverworld(game)
    U.wait(20)
    if H.openMmo(game) then
      U.wait(30)
      if H.selectLabel(game, "LEAVE", 120) then
        U.wait(30)
        left = not exports.isConnected()
      end
    end
  end
  if not left and exports.isConnected() and type(exports.leave) == "function" then
    log("leave via exports.leave (menu path missed)")
    exports.leave()
    U.wait(20)
  end
  check(H.waitSeconds(game, function() return not exports.isConnected() end, 30,
                      "this instance to leave"),
        "LEAVE disconnects this guest")
  H.signal(marker(ROLE, "left"))

  log(("RESULT %d failure(s)"):format(failures))
  log("DONE")
  U.wait(60)
  love.event.quit(failures > 0 and 1 or 0)
end
