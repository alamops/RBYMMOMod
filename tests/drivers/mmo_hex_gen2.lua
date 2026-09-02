-- Gen 2 hex driver: six Gold guests, two parties of three, one 3-on-3.
--
-- Pair with tests/drivers/run-hex-e2e-gen2.sh (Node hub, all JOIN).
--
--   POKEPORT_VERSION=gold MMO_ROLE=a POKEPORT_IDENTITY=mmohex-gold-a \
--     POKEPORT_DRIVER=mods/rby_mmo/tests/drivers/mmo_hex_gen2.lua love .

if os.getenv("MMO_SOUND") ~= "1" and love and love.audio then
  love.audio.setVolume(0)
end

local ROLES = {
  a = { name = "ALPHA",   species = "TYPHLOSION", level = 50, side = 1, lead = true },
  b = { name = "BETA",    species = "PIKACHU",     level = 50, side = 1 },
  c = { name = "CHARLIE", species = "FERALIGATR",  level = 50, side = 1 },
  d = { name = "DELTA",   species = "MEGANIUM",    level = 50, side = 2, lead = true },
  e = { name = "ECHO",    species = "AMPHAROS",    level = 50, side = 2 },
  f = { name = "FOXTROT", species = "SNORLAX",     level = 50, side = 2 },
}
local ORDER = { "a", "b", "c", "d", "e", "f" }

local ROLE = tostring(os.getenv("MMO_ROLE") or "a"):lower()
if not ROLES[ROLE] then ROLE = "a" end

return function(game)
  local H = dofile("mods/rby_mmo/tests/drivers/mmo_util.lua")
  local U = H.U
  local TAG = "MMO_HEX_" .. ROLE:upper() .. ":"
  local ME = ROLES[ROLE]
  local SHOT_DIR = os.getenv("SHOT_DIR") or "/tmp/rby_mmo_hex_gen2_shots"
  local RAW_CODE = os.getenv("MMO_HUB_CODE") or ""

  local function log(...) U.log(TAG, ...) end
  local events = H.captureEvents({ "battle.started", "battle.ended",
                                   "link.desync" })
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
    U.shot(game, ("%s/hex-g2-%s-%s.png"):format(SHOT_DIR, ROLE, name))
  end

  local function marker(side, tag) return ("hex_%s_%s"):format(side, tag) end

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

  local TAGS = { "ready", "seen", "spread", "side1", "paired", "agreed", "fought", "ranked", "left" }
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

  local announced = H.listenForModEvents(game, {
    "mod.rby_mmo.coop_battle_started", "mod.rby_mmo.coop_battle_ended",
  })

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
  log("in the overworld as", ME.name, "with",
      table.concat(H.partySpecies(game), ","))

  local code = H.codeFrom(RAW_CODE)
  if not code then bail("a join code was supplied to this instance") return end

  if not H.openMmo(game) then bail("the MMO menu opens") return end
  if not H.selectLabel(game, "JOIN GAME") then bail("JOIN GAME is on the menu") return end
  U.wait(20)
  check(H.selectLabel(game, "JOIN"), "confirmed the trainer and moved on")
  U.wait(20)
  if H.addressGrid(game) == nil then bail("the address screen opened") return end
  U.tap(game, "start")
  U.wait(60)

  check(H.waitFor(game, function() return H.codeGrid(game) ~= nil end,
                  240, "the join-code grid"), "the join-code grid opened")
  check(H.enterJoinCode(game, code), "the hub's code can be typed on the grid")
  U.wait(60)

  local connected = H.waitSeconds(game, function() return exports.isConnected() end,
                                  120, "the connection to open")
  if not connected then
    shot("join-FAILED")
    bail("connected to the dedicated hub")
    return
  end
  check(connected, "connected to the dedicated hub")
  H.closeToOverworld(game)
  H.signal(marker(ROLE, "ready"))
  for _, side in ipairs(ORDER) do
    if side ~= ROLE then H.await(game, marker(side, "ready")) end
  end

  check(H.waitSeconds(game, function() return #exports.players() >= 5 end,
                      120, "the other five to appear on the roster"),
        "all five other guests are on the roster")
  H.closeToOverworld(game)
  shot("roster")
  rendezvous("seen")

  -- Walk, don't warp: warpTo does not publish presence, so roster tiles
  -- stay stacked at spawn and interact INVITE hits the wrong trainer.
  -- Unique paths so six avatars are not two-to-a-tile.
  local WALKS = {
    b = { "left" },
    c = { "right" },
    d = { "down" },
    e = { "up" },
    f = { "left", "down" },
  }
  for _, dir in ipairs(WALKS[ROLE] or {}) do
    U.hold(game, dir, 24)
  end
  -- A facing change is enough for presenceChanged to send MOVE.
  U.tap(game, "up")
  U.wait(45)
  rendezvous("spread")

  -- Gold's MMO > PLAYERS row is often unscannable after JOIN (mmo_join_gen2
  -- uses interact INVITE for the same reason).
  local function hasLabel(label)
    for _, item in ipairs(H.menuLabels(game)) do
      if item == label then return true end
    end
    return false
  end

  local function interactFor(name, label)
    H.closeToOverworld(game, 48)
    local row = H.avatarRow(exports, name)
    if not (row and row.rosterX) then return false end
    local tries = {
      { 0, 1, "up" }, { 1, 0, "left" }, { -1, 0, "right" }, { 0, -1, "down" },
    }
    for _, t in ipairs(tries) do
      H.teleport(game, row.map, row.rosterX + t[1], row.rosterY + t[2], t[3])
      U.wait(40)
      U.tap(game, "a")
      U.wait(40)
      if hasLabel(label) then return H.selectLabel(game, label) end
      H.closeToOverworld(game, 24)
    end
    return false
  end

  local function invite(name)
    return interactFor(name, "INVITE")
  end

  local function formParty(first, second)
    check(invite(first), "first invite from this party's lead")
    check(H.waitSeconds(game, function() return #exports.party() >= 2 end, 120,
                        "the second member to join"),
          "the second member joined")
    check(invite(second), "second invite completes the party of three")
  end

  -- Party 1 first, then party 2. Simultaneous invites raced the stacked
  -- avatars; ALPHA's party formed and DELTA's first INVITE was declined.
  if ME.side == 1 then
    if ME.lead then formParty(ROLES.b.name, ROLES.c.name) end
    check(H.drivePrompts(game, function() return #exports.party() == 3 end, 180),
          "the party formed with three members")
  else
    check(H.waitSeconds(game, function()
      local n = 0
      for _, row in ipairs(exports.players()) do
        if row.party then n = n + 1 end
      end
      return n >= 3
    end, 180, "the first party of three to form"),
          "the other party formed first")
  end
  rendezvous("side1")

  if ME.side == 2 then
    if ME.lead then formParty(ROLES.e.name, ROLES.f.name) end
    check(H.drivePrompts(game, function() return #exports.party() == 3 end, 180),
          "the party formed with three members")
  end
  check(H.waitSeconds(game, function()
    local inParties = 0
    for _, row in ipairs(exports.players()) do
      if row.party then inParties = inParties + 1 end
    end
    return inParties >= 5
  end, 120, "everyone else's party flag to arrive"),
        "all five other guests read as being in a party")
  H.closeToOverworld(game)
  rendezvous("paired")

  -- Gold's MMO > PLAYERS row is often unscannable after JOIN; challenge
  -- DELTA from the overworld interact menu (PARTY BATTLE sits under BATTLE).
  if ROLE == "a" then
    check(interactFor(ROLES.d.name, "PARTY BATTLE"),
          "asked the other party for a 3-on-3")
  end

  if ROLE ~= "a" then
    check(H.waitSeconds(game, function() return exports.coopAsk() ~= nil end,
                        90, "the six-way ask to arrive"),
          "the ask reached this instance")
  end

  check(H.drivePrompts(game, function()
    local top = H.top(game)
    return top ~= nil and top.sim ~= nil and #top.sim.slots == 6
  end, 300), "six yesses put a six-slot battle on screen")

  local top = H.top(game)
  if not (top and top.sim) then bail("the party-versus-party battle came up") return end

  local owned, mine, theirs = 0, 0, 0
  for _, slot in ipairs(top.sim.slots) do
    if slot.owner then owned = owned + 1 end
    if slot.side == "a" then mine = mine + 1 else theirs = theirs + 1 end
  end
  check(owned == 6, "every slot belongs to a real player")
  check(mine == 3 and theirs == 3, "three a side")
  check(H.awaitCommandMenu(game, "the command menu for the battle shot"),
        "the co-op command grid opens")
  U.wait(30)
  shot("hex-battle")
  check(exports.coopDrawFailed() == false, "the 3-on-3 screen drew without error")
  rendezvous("agreed")

  check(H.drivePrompts(game, function()
    local now = H.top(game)
    return now == nil or now.sim == nil
  end, 300, function() U.tap(game, "a") end),
        "the party-versus-party battle runs to an end")
  check(events["link.desync"] == 0, "no desync was reported")
  check(announced["mod.rby_mmo.coop_battle_started"] >= 1,
        "coop_battle_started fired")
  check(announced["mod.rby_mmo.coop_battle_ended"] >= 1,
        "coop_battle_ended fired")
  local said = announced.payloads["mod.rby_mmo.coop_battle_started"]
  if said then
    check(said.kind == "party", "announced as a party battle")
    check(said.humans == 6, "with six people")
    check(said.ranked == true, "and worth points")
  end
  H.closeToOverworld(game)
  rendezvous("fought")

  H.rankAfterBattle(game, exports, check, 120)
  rendezvous("ranked")

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
