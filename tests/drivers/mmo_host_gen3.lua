-- Gen 3 host e2e: in-game hosting on FireRed / LeafGreen / Emerald, driven
-- end to end through the real menus.
--
-- Pair with mmo_join_gen3.lua via run-mmo-e2e-gen3.sh. Same shape as the
-- Gen 1 and Gold hosts (a real socket, real menus, real avatars), on a Game3:
-- the START menu is the cart's own layer with this mod's MMO row in it, every
-- MMO screen is a Gen3Ui layer on the game3 stack, and the live state is the
-- runtime session rather than game.save. Legs, in order, each ending in a
-- screenshot (g3-<game>-host-<NN>-<leg>.png):
--
--   boot > START (the MMO row, before SAVE) > MAIN > HOST GAME (trainer, look,
--   players, a fresh code, START) > the guest arrives (roster, avatar object,
--   nameplate, arrival toast) > the host runs past the guest > chat (SAY on the
--   letter grid, the guest's line as a toast and in the CHAT log) > the guest's
--   friend ask answered > MY PROFILE > held still for the guest's interact +
--   trade (dex checked) > the guest's party invite answered > MEMBERS > the
--   guest leaves the party and the game.
--
-- Battle, co-op and solo legs are appended in wave 5: each leg below is one
-- block between two barrier pairs, so a new one slots in before the party leg
-- without renumbering anything (screenshots number themselves).
--
--   POKEPORT_VERSION=firered POKEPORT_IDENTITY=mmohost-g3 \
--     POKEPORT_DRIVER=mods/rby_mmo/tests/drivers/mmo_host_gen3.lua love .

io.stdout:setvbuf("line")
io.stderr:setvbuf("line")
if os.getenv("MMO_SOUND") ~= "1" and love and love.audio then
  love.audio.setVolume(0)
end

return function(game)
  local H = dofile("mods/rby_mmo/tests/drivers/mmo_util.lua")
  local U = H.U
  local TAG = "MMO_HOST:"
  local GAME = os.getenv("GEN3_GAME") or os.getenv("POKEPORT_VERSION") or "firered"
  local STAGE = H.G3_STAGE[GAME] or H.G3_STAGE.firered
  local ADDR_FILE = os.getenv("MMO_ADDR_FILE") or "/tmp/rby_mmo_gen3_addr.txt"
  local SHOT_DIR = os.getenv("SHOT_DIR") or "/tmp/rby_mmo_shots_gen3"
  local LIMIT = tonumber(os.getenv("MMO_LIMIT") or "") or 2
  local shot = H.g3Shooter(game, SHOT_DIR, GAME, "host")

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
    "g3_host_walk_start", "g3_host_walk_done", "g3_host_said",
    "g3_host_answered_friend", "g3_host_ready_for_interact", "g3_host_trade_done",
    "g3_host_ready_for_party", "g3_host_party_checked",
  }
  local function finish()
    -- fail-forward: every marker this side owns, so a mid-run abort does not
    -- leave the guest sitting on barriers for their full budget
    for _, tag in ipairs(OWNED) do H.signal(tag) end
    U.wait(60)
    log("RESULT " .. failures .. " failure(s)")
    log("DONE")
    love.event.quit(failures > 0 and 1 or 0)
  end

  os.remove(ADDR_FILE)
  os.remove(ADDR_FILE .. ".tmp")

  -- ------- boot
  local booted = H.bootToPlay(game, {
    name = "HOSTY", gender = 0,
    map = STAGE.map, x = STAGE.host[1], y = STAGE.host[2], facing = STAGE.host[3],
  })
  check(booted, "a new " .. GAME .. " game reaches the field")
  check(H.generation(game) == 3, "host boots generation 3")
  check(H.g3Version(game) == GAME, "the cart is " .. GAME .. " (" .. tostring(H.g3Version(game)) .. ")")
  local cell = H.playerCell(game)
  check(cell and cell.mapId == STAGE.map, "standing in " .. STAGE.map .. " (" .. tostring(cell and cell.mapId) .. ")")

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
  if exports.traceAvatars then exports.traceAvatars(true) end
  check(exports.isConnected() == false, "starts disconnected")
  check(exports.isHosting() == false, "starts not hosting")

  local mine = H.seedParty(game, STAGE.hostMon, 30)
  H.g3GiveMon(game, STAGE.spare, 5)
  local MINE = H.g3Species(game, STAGE.hostMon)
  local THEIRS = H.g3Species(game, STAGE.guestMon)
  check(mine ~= nil and mine.species == MINE, "seeded a " .. STAGE.hostMon .. " to trade")
  check(not H.dexOwned(game, THEIRS), "the guest's " .. STAGE.guestMon .. " is not in this dex yet")
  -- the running shoes the story hands over later, so B-running (and the
  -- `fast` flag it puts on presence) is available on a fresh save
  check(H.g3SetFlag(game, "FLAG_SYS_B_DASH", true), "running shoes (FLAG_SYS_B_DASH) on")
  log("in the field as HOSTY with", table.concat(H.partySpecies(game), ","))
  shot("field")

  -- ------- START: the cart's own menu, with the MMO row before SAVE
  check(H.g3OpenStart(game), "START opens the cart's start menu")
  do
    local SM = package.loaded["src.ui.game3.start_menu"]
    local ids, mmoAt, saveAt = {}, nil, nil
    for i, e in ipairs((SM and SM.ENTRIES) or {}) do
      ids[#ids + 1] = tostring(e.id) .. "=" .. tostring(e.label)
      if e.id == "rby_mmo" then mmoAt = i end
      if e.id == "save" then saveAt = i end
    end
    log("start rows", table.concat(ids, " "))
    check(mmoAt ~= nil, "the MMO row is on the START menu")
    check(mmoAt and saveAt and saveAt - mmoAt == 1, "MMO sits directly before SAVE")
    shot("start-menu")
  end
  U.tap(game, "b")
  U.wait(20)
  check(not H.g3Has("start"), "B closes START again")

  if not check(H.openMmo(game), "START > MMO opens the MMO menu") then return finish() end
  local offline = H.menuLabels(game)
  log("MAIN offline:", table.concat(offline, ","))
  check(H.menuRow(game, "HOST GAME") ~= nil and H.menuRow(game, "JOIN GAME") ~= nil,
        "MAIN offers HOST GAME and JOIN GAME")
  shot("main-menu")

  -- ------- HOST GAME
  if not check(H.selectLabel(game, "HOST GAME"), "HOST GAME") then return finish() end
  U.wait(20)
  check(H.g3LayerId() == "rby_mmo:RbyMmoCharSetup", "the trainer screen opened ("
        .. tostring(H.g3LayerId()) .. ")")
  check(H.menuRow(game, "NAME") and tostring(H.menuRow(game, "NAME").right) == "HOSTY",
        "it names the trainer from the save (HOSTY)")
  shot("charsetup")
  if H.selectLabel(game, "LOOK") then
    U.wait(20)
    check(H.classify(H.top(game)) == "menu", "the character picker opened")
    shot("charpick")
    U.tap(game, "b")
    U.wait(20)
  end
  check(H.selectLabel(game, "HOST"), "confirmed the trainer and moved on")
  U.wait(20)
  check(H.g3LayerId() == "rby_mmo:RbyMmoHostSetup" or H.classify(H.top(game)) == "menu",
        "the host setup menu opened (" .. tostring(H.g3LayerId()) .. ")")
  shot("host-setup")

  check(H.selectLabel(game, "PLAYERS"), "PLAYERS opens the size list")
  U.wait(20)
  check(H.selectLabel(game, ("%d PLAYERS"):format(LIMIT)), "chose " .. LIMIT .. " PLAYERS")
  U.wait(20)

  local minted = H.menuRow(game, "JOIN CODE")
  local joinCode = minted and H.codeFrom(tostring(minted.right))
  check(joinCode ~= nil, "the setup screen arrives with a code on its JOIN CODE row")
  if check(H.selectLabel(game, "JOIN CODE"), "JOIN CODE opens the lock menu") then
    U.wait(20)
    check(H.selectLabel(game, "NEW CODE"), "asked the game to make one")
    U.wait(30)
    local fresh = H.codeFrom(H.textOf(H.top(game)))
    check(fresh ~= nil, "the screen reads out a code")
    joinCode = fresh or joinCode
    shot("new-code", true)
    H.waitFor(game, function()
      local t = H.top(game)
      if t and type(t.items) == "table" and t.kind ~= "text" then return true end
      U.tap(game, "a")
      return false
    end, 240, "the setup menu after setting a code")
  end

  check(H.selectLabel(game, "START"), "START begins the game")
  U.wait(30)
  local hosting = H.waitFor(game, function() return exports.isHosting() end, 240,
                            "the listener to come up")
  if not check(hosting, "hosting started (a real socket is bound)") then return finish() end
  -- HOSTING is a drawn card, not a text box: nothing to wait out but a frame
  U.wait(10)
  shot("address")
  local address = exports.hostAddress and exports.hostAddress() or nil
  check(type(address) == "string" and address:find(":") ~= nil,
        "an address is published: " .. tostring(address))
  check(H.waitFor(game, function() return exports.isConnected() end, 240,
                  "the host to join its own game"),
        "the host joined its own game over loopback")
  H.closeToOverworld(game)

  local handle = io.open(ADDR_FILE .. ".tmp", "w")
  if handle then
    handle:write(tostring(address) .. "\n" .. (joinCode or "") .. "\n")
    handle:close()
    os.rename(ADDR_FILE .. ".tmp", ADDR_FILE)
  end
  log("hosting", tostring(address), "limit", LIMIT, "code " .. H.formatCode(joinCode))

  -- ------- the guest arrives
  local sawGuest = H.waitSeconds(game, function() return #exports.players() > 0 end,
                                 400, "the guest to connect")
  if not check(sawGuest, "a remote player joined over a real socket") then return finish() end
  local guest = exports.players()[1]
  log("guest is", tostring(guest.name), "on", tostring(guest.map), "version", tostring(guest.version),
      "sprite", tostring(guest.sprite))
  check(guest.name == "GUESTY", "guest trainer name is GUESTY")
  check(guest.version == GAME, "the roster carries the guest's cart (" .. tostring(guest.version) .. ")")
  local toasted = H.waitSeconds(game, function() return H.toastSays(exports, "GUESTY") end, 10,
                                "the arrival toast")
  check(toasted, "the arrival reached the corner as a toast")
  shot("toast-joined")

  H.await(game, "g3_guest_walked")
  local row = H.avatarRow(exports, "GUESTY")
  check(row ~= nil and row.spawned, "the guest has a spawned avatar on this map")
  local eo, localId = H.g3AvatarObject(guest.id)
  check(eo ~= nil, "the guest is a real event object in the engine's object list")
  if eo then
    log("guest avatar eo", localId, eo.cellX, eo.cellY, "gfx", eo.graphicsId, "passable", tostring(eo.passable))
    check(localId >= 0x1000, "under a mod localId")
    check(eo.passable == true, "passable (it never blocks the player)")
    check(row and eo.cellX == row.rosterX and eo.cellY == row.rosterY,
          "standing on the guest's reported cell")
  end
  local overlay = exports.overlayState()
  local named = false
  for _, n in ipairs(overlay.names or {}) do
    if tostring(n):find("GUESTY", 1, true) then named = true end
  end
  check(overlay.reached == "labels" and named,
        "the guest's nameplate is drawn (" .. tostring(overlay.reached) .. ")")
  shot("sees-guest")

  -- ------- the host runs past; the guest judges it
  H.signal("g3_host_walk_start")
  H.await(game, "g3_guest_baseline")
  local wasAt = H.playerCell(game)
  H.g3Walk(game, { "down", "down", "left" }, true)
  local nowAt = H.playerCell(game)
  check(nowAt and wasAt and (nowAt.x ~= wasAt.x or nowAt.y ~= wasAt.y),
        ("the host ran (%s,%s) -> (%s,%s)"):format(tostring(wasAt and wasAt.x), tostring(wasAt and wasAt.y),
          tostring(nowAt and nowAt.x), tostring(nowAt and nowAt.y)))
  H.signal("g3_host_walk_done")

  -- ------- chat: SAY on the grid; the guest's line as a toast and in CHAT
  check(H.sayViaMenu(game, "EVERYONE", "HELLO FROM HOST"), "typed HELLO FROM HOST on the SAY grid")
  check(H.waitSeconds(game, function() return H.chatHas(exports, "HELLO FROM HOST", "HOSTY") end, 20,
                      "the host's own line"),
        "the hub echoed the host's line into its chat")
  H.closeToOverworld(game)
  H.signal("g3_host_said")
  H.await(game, "g3_guest_said")
  local heard = H.waitSeconds(game, function() return H.chatHas(exports, "HELLO FROM GUEST", "GUESTY") end,
                              60, "the guest's chat line")
  check(heard, "the guest's chat reached the host")
  check(H.toastSays(exports, "HELLO FROM GUEST"), "and showed in the corner as a toast")
  shot("toast-chat")
  H.awaitToastsClear(game, exports)
  if H.openMmo(game) and H.selectLabel(game, "CHAT") then
    U.wait(20)
    local labels = table.concat(H.menuLabels(game), "|")
    log("chat log:", labels)
    check(labels:find("GUESTY", 1, true) ~= nil and labels:find("HELLO FROM GUEST", 1, true) ~= nil,
          "the CHAT log lists the guest's line")
    shot("chat-log")
  else
    check(false, "MMO > CHAT opens the chat log")
  end
  H.closeToOverworld(game)

  -- ------- the guest asks to be friends; answer it, then MY PROFILE
  H.await(game, "g3_guest_asked_friend")
  local askShot = false
  local befriended = H.drivePrompts(game, function()
    for _, f in ipairs((exports.friends and exports.friends()) or {}) do
      if f.name == "GUESTY" then return true end
    end
    return false
  end, 90, function(kind, top)
    if not askShot and kind ~= nil then
      askShot = true
      log("friend ask:", H.textOf(top))
      shot("friend-ask", true)
    end
  end)
  check(befriended, "agreeing to the guest's ADD FRIEND makes them a friend here")
  H.closeToOverworld(game)
  H.signal("g3_host_answered_friend")
  H.awaitToastsClear(game, exports)
  if H.openMmo(game) and H.selectLabel(game, "MY PROFILE") then
    U.wait(40)
    local card = H.top(game)
    check(card ~= nil and card.player ~= nil and card.player.name == "HOSTY",
          "MY PROFILE shows this trainer's own card")
    shot("my-profile")
  else
    check(false, "MMO > MY PROFILE opens the own card")
  end
  H.closeToOverworld(game)
  H.await(game, "g3_guest_social_done")

  -- ------- interact + trade: hold still; the guest walks up and asks
  H.closeToOverworld(game)
  H.signal("g3_host_ready_for_interact")
  H.await(game, "g3_guest_trade_requested")
  local seen, record = {}, nil
  local recorder, prompts = H.promptLog()
  record = function(kind, top)
    recorder(kind, top)
    local key = (top and (top.title or H.textOf(top))) or tostring(kind)
    key = tostring(key):sub(1, 24)
    if not seen[key] and #prompts <= 8 then
      seen[key] = true
      shot("trade-" .. (kind or "step"), kind == "text")
    end
  end
  local traded, trail = H.drivePrompts(game, function()
    return H.partySpecies(game)[1] == tostring(THEIRS)
  end, 150, record)
  log("host party now:", table.concat(H.partySpecies(game), ","))
  if not traded then
    log("trade stalled -- prompts answered:", trail == "" and "(none)" or trail)
    log("  boxes:", table.concat(prompts, " | "))
  end
  check(traded, "the host received the guest's " .. STAGE.guestMon)
  check(H.dexOwned(game, THEIRS), "the " .. STAGE.guestMon .. " is caught in the host's dex")
  local got = H.partyMon(game, THEIRS)
  check(got ~= nil and got.otName == "GUESTY", "with the guest as its OT (" .. tostring(got and got.otName) .. ")")
  H.closeToOverworld(game)
  shot("after-trade")
  H.signal("g3_host_trade_done")
  H.await(game, "g3_guest_trade_done")

  -- ------- party: the guest invites; answer, then MEMBERS
  H.closeToOverworld(game)
  H.signal("g3_host_ready_for_party")
  H.await(game, "g3_guest_party_invited")
  local asked = false
  local paired = H.drivePrompts(game, function() return #exports.party() == 2 end, 120,
    function(kind, top)
      if not asked and kind ~= nil then
        asked = true
        log("party ask:", H.textOf(top))
        shot("party-ask", true)
      end
    end)
  check(paired, "the party formed over the in-game hub")
  H.closeToOverworld(game)
  if H.openMmo(game) and H.selectLabel(game, "PARTY") then
    U.wait(20)
    log("PARTY menu:", table.concat(H.menuLabels(game), ","))
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
  H.signal("g3_host_party_checked")
  H.await(game, "g3_guest_party_done")
  check(H.waitSeconds(game, function() return #exports.party() == 0 end, 45, "the party to end"),
        "the guest leaving ends the party here too")

  -- ------- the guest leaves the game
  H.await(game, "g3_guest_left")
  local gone = H.waitSeconds(game, function() return #exports.players() == 0 end, 90,
                             "the guest to drop off the roster")
  check(gone, "a guest who leaves drops off the host's roster")
  check(H.g3AvatarObject(guest.id) == nil, "and their avatar object is gone from the map")
  check(exports.isHosting(), "and the host is still hosting afterwards")
  shot("guest-gone")

  finish()
end
