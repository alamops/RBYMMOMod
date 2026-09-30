-- Gen 3 guest e2e: join a FireRed / LeafGreen / Emerald in-game host, driven
-- end to end through the real menus.
--
-- Pair with mmo_host_gen3.lua via run-mmo-e2e-gen3.sh. Legs, in order, each
-- ending in a screenshot (g3-<game>-guest-<NN>-<leg>.png):
--
--   boot > START > MMO > JOIN GAME (trainer, the address grid, the code grid
--   typed on the d-pad) > the host on the roster, as an avatar object with a
--   nameplate > walk > the host's run seen here (moves, fast flag) > chat
--   (the host's line as a toast, SAY on the grid) > PLAYERS (place column) >
--   ACTIONS > PROFILE card > ADD FRIEND > FRIENDS > the friend mark on PLAYERS
--   > RANK > interact (A on the host's avatar) > TRADE (dex checked) > INVITE >
--   MEMBERS > the party list on the region map > PARTY > LEAVE > MAIN > LEAVE.
--
-- Battle, co-op and solo legs are appended in wave 5 between the trade and
-- the party legs; each leg is one block between two barrier pairs.
--
--   POKEPORT_VERSION=firered POKEPORT_IDENTITY=mmoguest-g3 \
--     POKEPORT_DRIVER=mods/rby_mmo/tests/drivers/mmo_join_gen3.lua love .

io.stdout:setvbuf("line")
io.stderr:setvbuf("line")
if os.getenv("MMO_SOUND") ~= "1" and love and love.audio then
  love.audio.setVolume(0)
end

return function(game)
  local H = dofile("mods/rby_mmo/tests/drivers/mmo_util.lua")
  local U = H.U
  local TAG = "MMO_JOIN:"
  local GAME = os.getenv("GEN3_GAME") or os.getenv("POKEPORT_VERSION") or "firered"
  local STAGE = H.G3_STAGE[GAME] or H.G3_STAGE.firered
  local ADDR_FILE = os.getenv("MMO_ADDR_FILE") or "/tmp/rby_mmo_gen3_addr.txt"
  local SHOT_DIR = os.getenv("SHOT_DIR") or "/tmp/rby_mmo_shots_gen3"
  local shot = H.g3Shooter(game, SHOT_DIR, GAME, "guest")

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

  local OWNED = {
    "g3_guest_walked", "g3_guest_baseline", "g3_guest_said", "g3_guest_asked_friend",
    "g3_guest_social_done", "g3_guest_trade_requested", "g3_guest_trade_done",
    "g3_guest_party_invited", "g3_guest_party_done", "g3_guest_left",
  }
  local function finish()
    for _, tag in ipairs(OWNED) do H.signal(tag) end
    U.wait(60)
    log("RESULT " .. failures .. " failure(s)")
    log("DONE")
    love.event.quit(failures > 0 and 1 or 0)
  end

  local function labelsOf(top)
    local labels = {}
    for _, item in ipairs((top and top.items) or {}) do labels[#labels + 1] = tostring(item.label) end
    return labels
  end
  local function has(labels, want)
    for _, label in ipairs(labels) do
      if H.labelMatches(label, want) then return true end
    end
    return false
  end

  -- ------- boot
  local booted = H.bootToPlay(game, {
    name = "GUESTY", gender = 0,
    map = STAGE.map, x = STAGE.guest[1], y = STAGE.guest[2], facing = STAGE.guest[3],
  })
  check(booted, "a new " .. GAME .. " game reaches the field")
  check(H.generation(game) == 3, "guest boots generation 3")
  check(H.g3Version(game) == GAME, "the cart is " .. GAME)

  local exports = H.requireMod(game, TAG)
  if not exports then
    failures = failures + 1
    return finish()
  end
  -- a src/ file that failed to parse leaves the mod "loaded" with its
  -- multiplayer client switched off (Client logs "multiplayer is disabled");
  -- say so here rather than as a driver error on the first export call
  if not check(type(exports.isConnected) == "function",
               "the mod's multiplayer client installed (else see [rby_mmo] errors in this log)") then
    return finish()
  end
  check(exports.isConnected() == false, "starts disconnected")

  local mine = H.seedParty(game, STAGE.guestMon, 30)
  H.g3GiveMon(game, STAGE.spare, 5)
  local MINE = H.g3Species(game, STAGE.guestMon)
  local THEIRS = H.g3Species(game, STAGE.hostMon)
  check(mine ~= nil and mine.species == MINE, "seeded a " .. STAGE.guestMon .. " to trade")
  check(not H.dexOwned(game, THEIRS), "the host's " .. STAGE.hostMon .. " is not in this dex yet")
  H.g3SetFlag(game, "FLAG_SYS_B_DASH", true)
  log("in the field as GUESTY with", table.concat(H.partySpecies(game), ","))

  local hostAddress, joinCode
  local ready = H.waitSeconds(game, function()
    local handle = io.open(ADDR_FILE, "r")
    if not handle then return false end
    hostAddress = handle:read("*l")
    local line = handle:read("*l")
    handle:close()
    joinCode = (line ~= nil and line ~= "") and line or nil
    return true
  end, 400, "the host to publish its address")
  if not check(ready, "the host came up") then return finish() end
  log("host at", tostring(hostAddress), "code", H.formatCode(joinCode))

  -- ------- JOIN GAME, all of it on the menus
  if not check(H.openMmo(game), "START > MMO opens the MMO menu") then return finish() end
  if not check(H.selectLabel(game, "JOIN GAME"), "JOIN GAME") then return finish() end
  U.wait(20)
  check(H.g3LayerId() == "rby_mmo:RbyMmoCharSetup", "the trainer screen opened")
  shot("charsetup")
  check(H.selectLabel(game, "JOIN"), "the trainer confirms")
  U.wait(40)
  local naming = H.addressGrid(game)
  check(naming ~= nil, "the address grid opened (" .. tostring(H.g3LayerId()) .. ")")
  if naming then
    check(naming.default ~= nil and tostring(naming.default):find(":", 1, true) ~= nil,
          "carrying the hub to dial as its default (" .. tostring(naming.default) .. ")")
    -- typed on the grid's digits page, so the leg proves "." and ":" are
    -- reachable -- then erased, and START submits the default
    check(H.typeOnGrid(game, "127.0.0.1:"), "the address grid types digits, '.' and ':'")
    shot("address-grid")
    check(H.clearGrid(game, naming), "B erases the address line")
  end
  U.tap(game, "start")
  U.wait(60)
  check(joinCode ~= nil, "the host published a join code with its address")
  if joinCode then
    check(H.waitFor(game, function() return H.codeGrid(game) ~= nil end, 240, "the join-code grid"),
          "the address screen hands straight over to the code grid")
    local grid = H.codeGrid(game)
    if grid then H.typeOnGrid(game, joinCode:sub(1, 3)) end
    shot("code-grid")
    if grid then H.clearGrid(game, grid) end
    check(H.enterJoinCode(game, joinCode), "the host's code can be typed on the grid")
    U.wait(60)
  end

  local connected = H.waitSeconds(game, function() return exports.isConnected() end, 60,
                                  "the connection to open")
  if not check(connected, "joined over a real socket") then
    shot("join-FAILED")
    return finish()
  end
  check(exports.isHosting() == false, "and is not the host")
  H.closeToOverworld(game)

  local host
  local sawHost = H.waitSeconds(game, function()
    host = exports.players()[1]
    return host ~= nil and host.map ~= nil
  end, 60, "the host to appear on the roster")
  if not check(sawHost, "the host appears on the guest's roster") then return finish() end
  check(host.name == "HOSTY", "named HOSTY")
  check(host.version == GAME, "on " .. GAME .. " (" .. tostring(host.version) .. ")")
  local spawned = H.waitSeconds(game, function()
    local row = H.avatarRow(exports, "HOSTY")
    return row ~= nil and row.spawned and H.g3AvatarObject(host.id) ~= nil
  end, 30, "the host's avatar")
  check(spawned, "the host stands on this map as an event object")
  local overlay = exports.overlayState()
  check(overlay.reached == "labels", "nameplates drawn (" .. tostring(overlay.reached) .. ")")
  -- the look chosen in options is the one the field draws (OwSprites'
  -- player graphic), not only the one the hub was told about
  local worn, look, gid = H.wornMatches(game, exports)
  check(worn, ("this player wears its chosen look %s (graphic %s)"):format(tostring(look), tostring(gid)))
  shot("sees-host")

  -- ------- walk, then watch the host run
  H.g3Walk(game, { "right", "up" }, false)
  log("walked")
  shot("after-walk")
  H.signal("g3_guest_walked")

  H.await(game, "g3_host_walk_start")
  local before = H.avatarRow(exports, "HOSTY")
  local fromX, fromY = before and before.rosterX, before and before.rosterY
  H.signal("g3_guest_baseline")
  local sawFast, sawWalk, midShot = false, false, false
  H.await(game, "g3_host_walk_done", nil, function()
    local row = H.avatarRow(exports, "HOSTY")
    if row and row.fast then sawFast = true end
    local eo = H.g3AvatarObject(host.id)
    if eo and eo.moving then
      sawWalk = true
      if not midShot then
        midShot = true
        shot("host-running")
      end
    end
  end)
  local moved = H.waitSeconds(game, function()
    local row = H.avatarRow(exports, "HOSTY")
    return row and (row.rosterX ~= fromX or row.rosterY ~= fromY)
  end, 45, "the host to move on this side")
  check(moved, "the host's movement reaches the guest")
  H.waitSeconds(game, function()
    local eo = H.g3AvatarObject(host.id)
    local row = H.avatarRow(exports, "HOSTY")
    return eo and row and not eo.moving and eo.cellX == row.rosterX and eo.cellY == row.rosterY
  end, 20, "the host's avatar to finish walking")
  check(sawWalk, "the host's avatar object walked (engine walk animation)")
  check(sawFast, "the host's roster row showed fast=true while B was held")
  do
    local eo = H.g3AvatarObject(host.id)
    local row = H.avatarRow(exports, "HOSTY")
    check(eo and row and eo.cellX == row.rosterX and eo.cellY == row.rosterY,
          "the avatar ended on the host's reported cell")
  end
  shot("host-walked")

  -- ------- chat
  H.await(game, "g3_host_said")
  local heard = H.waitSeconds(game, function() return H.chatHas(exports, "HELLO FROM HOST", "HOSTY") end,
                              60, "the host's chat line")
  check(heard, "the host's chat arrived")
  check(H.toastSays(exports, "HELLO FROM HOST"), "as a toast in the corner")
  shot("toast-chat")
  check(H.sayViaMenu(game, "EVERYONE", "HELLO FROM GUEST"), "typed HELLO FROM GUEST on the SAY grid")
  shot("say-typed")
  H.closeToOverworld(game)
  H.signal("g3_guest_said")

  -- ------- PLAYERS > ACTIONS > PROFILE > ADD FRIEND
  H.awaitToastsClear(game, exports)
  local asked = false
  if H.openMmo(game) and H.selectLabel(game, "PLAYERS") then
    U.wait(25)
    local row = H.menuRow(game, "HOSTY")
    check(row ~= nil, "PLAYERS lists the host")
    log("players row:", tostring(row and row.label), "right:", tostring(row and row.right))
    check(row and tostring(row.right or ""):find(STAGE.place, 1, true) ~= nil,
          "with their place (" .. tostring(row and row.right) .. ")")
    shot("players")
    if H.selectLabel(game, "HOSTY") then
      U.wait(25)
      local labels = labelsOf(H.top(game))
      log("actions:", table.concat(labels, ","))
      check(has(labels, "PROFILE") and has(labels, "ADD FRIEND") and has(labels, "TRADE")
            and has(labels, "BATTLE") and has(labels, "INVITE"),
            "ACTIONS offers PROFILE, ADD FRIEND, INVITE, TRADE and BATTLE")
      shot("actions")
      if H.selectLabel(game, "PROFILE") then
        U.wait(40)
        local card = H.top(game)
        check(card ~= nil and card.player ~= nil and card.player.name == "HOSTY",
              "the profile card shows the host")
        if card and card.player then
          log("card:", tostring(card.player.name), "look", tostring(card.player.sprite),
              "badges", tostring(card.player.profile and card.player.profile.badges))
          check(card.player.profile ~= nil, "with the trainer card they sent on joining")
        end
        shot("profile-card")
        U.tap(game, "b")
        U.wait(30)
        check(H.classify(H.top(game)) == "menu", "and B returns to ACTIONS")
      end
      if H.selectLabel(game, "ADD FRIEND") then
        asked = true
        U.wait(30)
        shot("friend-asked", true)
      end
    end
  end
  check(asked, "ADD FRIEND asked the host")
  H.closeToOverworld(game)
  H.signal("g3_guest_asked_friend")
  H.await(game, "g3_host_answered_friend")
  local landed = H.waitSeconds(game, function()
    local rows = exports.friends and exports.friends() or {}
    return #rows == 1 and rows[1].name == "HOSTY"
  end, 45, "the answer to reach this side")
  check(landed, "agreeing on the other machine writes the friendship here")
  H.closeToOverworld(game)
  H.awaitToastsClear(game, exports)

  if H.openMmo(game) then
    U.wait(10)
    if H.selectLabel(game, "FRIENDS") then
      U.wait(30)
      local first = (H.top(game) and H.top(game).items or {})[1]
      check(first ~= nil and tostring(first.label) == "HOSTY", "FRIENDS lists the friend just made")
      check(first ~= nil and tostring(first.right) ~= "OFFLINE", "as somebody who is here")
      shot("friends")
      U.tap(game, "b")
      U.wait(25)
    else
      check(false, "MMO > FRIENDS")
    end
    if H.selectLabel(game, "PLAYERS") then
      U.wait(25)
      local row = H.menuRow(game, "HOSTY")
      check(row ~= nil and row.prefix ~= nil and row.prefix ~= "",
            "the PLAYERS row now carries the friend mark (" .. tostring(row and row.prefix) .. ")")
      shot("players-friend")
      U.tap(game, "b")
      U.wait(25)
    end
    if H.selectLabel(game, "RANK") then
      U.wait(60)
      check(H.top(game) ~= nil, "the RANK screen opened")
      shot("rank")
      U.tap(game, "b")
      U.wait(25)
    else
      check(false, "MMO > RANK")
    end
  else
    check(false, "the MMO menu opens for the social screens")
  end
  H.closeToOverworld(game)
  H.signal("g3_guest_social_done")

  -- ------- interact: stand beside the host, press A, TRADE
  H.await(game, "g3_host_ready_for_interact")
  local hostRow = H.avatarRow(exports, "HOSTY")
  local opened = false
  if check(hostRow ~= nil and hostRow.rosterX ~= nil, "the host has a cell to stand next to") then
    H.teleport(game, hostRow.map or STAGE.map, hostRow.rosterX, hostRow.rosterY - 1, "down")
    U.wait(30)
    local eo = H.g3AvatarObject(host.id)
    check(eo ~= nil and eo.cellX == hostRow.rosterX and eo.cellY == hostRow.rosterY,
          "the host's avatar is right below us")
    shot("before-interact")
    U.tap(game, "a")
    U.wait(45)
    check(H.g3LayerId() == "rby_mmo:RbyMmoActions",
          "A on the host's avatar opens ACTIONS (" .. tostring(H.g3LayerId()) .. ")")
    local labels = labelsOf(H.top(game))
    log("interact menu:", table.concat(labels, ","))
    check(has(labels, "TRADE") and has(labels, "BATTLE"), "offering TRADE and BATTLE")
    shot("interact")
    opened = #labels > 0
  end
  local seen, prompts = {}, nil
  local recorder
  recorder, prompts = H.promptLog()
  local function record(kind, top)
    recorder(kind, top)
    local key = tostring((top and (top.title or H.textOf(top))) or kind):sub(1, 24)
    if not seen[key] and #prompts <= 8 then
      seen[key] = true
      shot("trade-" .. (kind or "step"), kind == "text")
    end
  end
  if opened and H.selectLabel(game, "TRADE") then
    log("asked to trade")
    H.signal("g3_guest_trade_requested")
    local traded, trail = H.drivePrompts(game, function()
      return H.partySpecies(game)[1] == tostring(THEIRS)
    end, 150, record)
    log("guest party now:", table.concat(H.partySpecies(game), ","))
    if not traded then
      log("trade stalled -- prompts answered:", trail == "" and "(none)" or trail)
      log("  boxes:", table.concat(prompts, " | "))
    end
    check(traded, "the guest received the host's " .. STAGE.hostMon)
    check(H.dexOwned(game, THEIRS), "the " .. STAGE.hostMon .. " is caught in the guest's dex")
    local got = H.partyMon(game, THEIRS)
    check(got ~= nil and got.otName == "HOSTY", "with the host as its OT (" .. tostring(got and got.otName) .. ")")
    H.closeToOverworld(game)
    shot("after-trade")
  else
    check(false, "TRADE from the interact menu")
    H.signal("g3_guest_trade_requested")
  end
  H.signal("g3_guest_trade_done")
  H.await(game, "g3_host_trade_done")

  -- ------- party: INVITE from the interact menu
  H.closeToOverworld(game)
  H.await(game, "g3_host_ready_for_party")
  H.waitSeconds(game, function()
    local row = H.avatarRow(exports, "HOSTY")
    return row ~= nil and not row.busy
  end, 30, "the host to be free")
  local invited = false
  U.tap(game, "a")
  U.wait(45)
  if H.g3LayerId() == "rby_mmo:RbyMmoActions" and H.selectLabel(game, "INVITE") then
    invited = true
  end
  check(invited, "INVITE from the interact menu asks the host to team up")
  H.signal("g3_guest_party_invited")
  local paired = H.drivePrompts(game, function() return #exports.party() == 2 end, 120)
  check(paired, "the party formed on the guest over the in-game hub")
  H.closeToOverworld(game)
  shot("party-formed")
  H.await(game, "g3_host_party_checked")

  if H.openMmo(game) and H.selectLabel(game, "PARTY") then
    U.wait(20)
    if H.selectLabel(game, "MEMBERS") then
      U.wait(25)
      local labels = table.concat(H.menuLabels(game), "|")
      log("members:", labels)
      check(labels:find("HOSTY", 1, true) ~= nil and labels:find("GUESTY", 1, true) ~= nil,
            "MEMBERS lists both of us")
      shot("party-members")
    else
      check(false, "PARTY > MEMBERS")
    end
  else
    check(false, "MMO > PARTY opens the party menu")
  end
  H.closeToOverworld(game)

  -- the party list over the region map
  local mapLayer = H.g3OpenRegionMap(game)
  check(mapLayer ~= nil, "the region map opened (" .. tostring(mapLayer) .. ")")
  if mapLayer then
    local drawn = H.waitFor(game, function()
      local st = exports.overlayState()
      return st.reached == "regionmap"
    end, 120, "the party list over the region map")
    local st = exports.overlayState()
    log("overlay on the map:", tostring(st.reached), table.concat(st.names or {}, ","))
    local named = false
    for _, n in ipairs(st.names or {}) do
      if tostring(n):find("HOSTY", 1, true) then named = true end
    end
    check(drawn and named, "the party list on the region map names the partner")
    shot("regionmap-party")
    H.g3CloseRegionMap(game)
  end

  -- PARTY > LEAVE
  local leftParty = false
  if H.openMmo(game) and H.selectLabel(game, "PARTY") then
    U.wait(20)
    if H.selectLabel(game, "LEAVE") then
      leftParty = H.drivePrompts(game, function() return #exports.party() == 0 end, 60)
    end
  end
  check(leftParty, "PARTY > LEAVE ends the party")
  H.closeToOverworld(game)
  shot("party-left")
  H.signal("g3_guest_party_done")

  -- ------- MAIN > LEAVE
  local left = false
  if H.openMmo(game) and H.selectLabel(game, "LEAVE") then
    U.wait(30)
    shot("left", true)
    left = H.waitSeconds(game, function() return not exports.isConnected() end, 20, "the disconnect")
  end
  check(left, "MAIN > LEAVE disconnects")
  H.closeToOverworld(game)
  check(H.g3AvatarObject(host.id) == nil, "the host's avatar goes with the connection")
  H.g3Walk(game, { "down" }, false)
  check(H.g3Idle(game), "and single-player carries straight on")
  H.signal("g3_guest_left")

  finish()
end
