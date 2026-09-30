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
--   trade (dex checked) > two mediated 1v1s > the guest's party invite
--   answered > MEMBERS > three co-op fights inside the party > the guest
--   leaves the party and the game.
--
-- The 1v1s (pvpLeg): the ARENA, the host asking through A on the guest's
-- avatar > ACTIONS > BATTLE, and CLASSIC BATTLE UI (the GBA page), the guest
-- asking.  Each seeds a lead per side, drives the fight with H.g3PilotFight
-- (one shot per moment: the ask, the opening line, the command menu, the move
-- list, a hit, a knockout, the result), and checks the link rules on what it
-- left behind -- HP / PP / EXP / items / status exactly as before, the
-- ranking moved, the two results mirror.
--
-- The co-op fights (inside the party): a wild one won on Route 1 / Route 101
-- grass (the walker's step encounter diverted at `encounter.roll`; EXP and a
-- level-up), a wild one caught with a MASTER BALL (the nickname grid), and an
-- NPC trainer walked into (the BattleBridge.start wrap; a POTION on a hurt
-- lead; the trainer's flag set on both carts, no rematch).  The host walks, the
-- guest stands beside and is auto-joined.
--
-- GEN3_LEGS (comma list; default all) narrows a run to some legs -- chat,
-- social, trade, battle, party, coop (which implies party) -- and both sides
-- read it, so a narrowed run narrows both alike.  Each leg is one block
-- between barrier pairs, so a new one slots in without renumbering anything
-- (screenshots number themselves).
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
  -- GEN3_LEGS (comma list) narrows a run to some legs; both sides read it
  local leg = H.g3Leg

  local function log(...) U.log(TAG, ...) end
  local failures = 0
  local function check(ok, what, detail)
    if detail ~= nil then what = what .. " [" .. tostring(detail) .. "]" end
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
    "g3_host_arena_ready", "g3_host_arena_done", "g3_host_classic_ready", "g3_host_classic_done",
    "g3_host_wild_ready", "g3_host_wild_done", "g3_host_trainer_ready", "g3_host_trainer_done",
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
  if leg("chat") then
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
  end

  -- ------- the guest asks to be friends; answer it, then MY PROFILE
  if leg("social") then
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
  end

  -- ------- interact + trade: hold still; the guest walks up and asks
  if leg("trade") then
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
  end

  -- ------- the two 1v1 fights on this room's own hub: the arena (the host asks)
  -- and the GBA page under CLASSIC BATTLE UI (the guest asks).  Each: both
  -- reseed a lead, the asker stands beside the other and opens ACTIONS >
  -- BATTLE, the other answers, both drive the fight to its result, and the
  -- link rules are checked on what it left behind (HP, PP, EXP and items are
  -- as they were -- the cart reloads the party after a Cable Club battle).
  local B = STAGE.battle
  local function hasLabel(labels, want)
    for _, label in ipairs(labels) do
      if H.labelMatches(label, want) then return true end
    end
    return false
  end

  local function pvpLeg(name, classic, hostAsks)
    H.closeToOverworld(game)
    H.g3SetOption(game, "classicui", classic)
    local lead = H.g3SeedLead(game, B.host, B.hostLevel)
    check(lead ~= nil and lead.level == B.hostLevel,
          ("%s: a level %d %s leads the host's party"):format(name, B.hostLevel, B.host))
    local before = H.g3PartyDigest(game)
    H.signal("g3_host_" .. name .. "_ready")
    H.await(game, "g3_guest_" .. name .. "_ready")

    if hostAsks then
      local row = H.g3StandBeside(game, exports, "GUESTY", "below")
      local eo = H.g3AvatarObject(guest.id)
      check(row ~= nil and eo ~= nil and eo.cellX == row.rosterX and eo.cellY == row.rosterY,
            name .. ": the guest's avatar is right above the host")
      U.tap(game, "a")
      U.wait(45)
      check(H.g3LayerId() == "rby_mmo:RbyMmoActions",
            name .. ": A on the guest's avatar opens ACTIONS (" .. tostring(H.g3LayerId()) .. ")")
      local labels = H.menuLabels(game)
      log("interact menu:", table.concat(labels, ","))
      check(hasLabel(labels, "BATTLE"), name .. ": ACTIONS offers BATTLE")
      shot(name .. "-actions")
      check(H.selectLabel(game, "BATTLE"), name .. ": BATTLE from the interact menu")
    end

    -- The asker only waits: its "Waiting for NAME..." box is a CANCEL row
    -- (and a confirm behind it), so mashing A there withdraws the ask before
    -- the other side has even seen it.  The one who is asked answers.
    local started, trail
    if hostAsks then
      U.wait(6)
      shot(name .. "-waiting")
      started, trail = H.waitSeconds(game, function() return H.g3Fight(game) ~= nil end, 150,
                                     "the asked player to accept"), ""
    else
      local askShot = false
      started, trail = H.drivePrompts(game, function() return H.g3Fight(game) ~= nil end, 150,
        function(kind, top)
          if not askShot and kind ~= nil then
            askShot = true
            log("battle ask:", H.textOf(top))
            shot(name .. "-ask", true)
          end
        end)
    end
    check(started, name .. ": a mediated battle started on the host (prompts: "
          .. (trail == "" and "none" or trail) .. ")")
    local res = H.g3PilotFight(game, { shot = shot, label = "pvp-" .. name, seconds = 300 })
    log(("pvp %s: kind=%s turns=%d result=%s gaps=%s lines=%d"):format(name, tostring(res.kind),
      res.turns, tostring(res.result), tostring(res.gaps), #res.said))
    log("lines:", (table.concat(res.said, " | "):gsub("%s+", " ")))
    check(res.kind == "1v1", name .. ": the fight is the 1v1 screen (" .. tostring(res.kind) .. ")")
    check(res.ended, name .. ": the fight ran to its end and its screen closed")
    check(res.gaps == 0, name .. ": no gaps in the mediated event stream")
    check(res.seen.command and res.seen.moves,
          name .. ": the command menu and the move list were on screen")
    check(res.seen.hit, name .. ": a damaging turn played (the HP bar moved)")
    check(res.seen.faint, name .. ": a knockout was narrated")
    check(res.result == "win" or res.result == "loss", name .. ": the fight has a winner ("
          .. tostring(res.result) .. ")")
    H.signal(("g3_host_%s_result_%s"):format(name, tostring(res.result)))

    H.closeToOverworld(game)
    H.g3Settle(game, 600)
    check(H.g3Idle(game), name .. ": back in the field")
    local after = H.g3PartyDigest(game)
    local diff = H.g3DigestDiff(before, after, { "species", "level", "hp", "maxHp", "exp", "item", "pp", "moves" })
    check(diff == nil, name .. ": the party is exactly as it was -- HP, PP, EXP, items "
          .. "(link battle: the cart reloads the party)", diff)
    local sdiff = H.g3DigestDiff(before, after, { "status" })
    check(sdiff == nil, name .. ": and no status is left behind (link battle: the cart reloads the party)",
          sdiff)
    shot(name .. "-after")
    if name == "arena" then H.rankAfterBattle(game, exports, check) end
    H.closeToOverworld(game)
    H.signal("g3_host_" .. name .. "_done")
    H.await(game, "g3_guest_" .. name .. "_done")
    local mine = res.result
    local other = (mine == "win" and "loss") or (mine == "loss" and "win") or tostring(mine)
    check(H.signaled(("g3_guest_%s_result_%s"):format(name, other)),
          ("%s: the guest's result is the mirror of ours (%s / %s)"):format(name, tostring(mine), other))
    return res
  end

  if leg("battle") then
    pvpLeg("arena", false, true)
    pvpLeg("classic", true, false)
    H.g3SetOption(game, "classicui", false)
  end

  -- ------- party: the guest invites; answer, then MEMBERS
  if leg("party") then
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

    -- ------- co-op inside the party (the block above formed it): two wild
    -- fights on Route 1 / Route 101 grass (one won, one caught with a MASTER
    -- BALL), then a trainer walked into on the next map.  The walker is the
    -- host; the guest stands beside and is auto-joined.  Every fight is
    -- refereed by this room's own hub (BattleSim3): the wild ones come in by
    -- the `encounter.roll` door, the trainer by the BattleBridge.start wrap.
    if leg("coop") then
      local function ppSum(row)
        local n = 0
        for v in tostring(row and row.pp or ""):gmatch("%d+") do n = n + tonumber(v) end
        return n
      end
      local function partnerOnMap()
        return H.waitSeconds(game, function()
          local row = H.avatarRow(exports, "GUESTY")
          return row ~= nil and row.spawned
        end, 60, "the guest on this map")
      end
      local function coopResult(name, res, mode, slots)
        log(("%s: kind=%s mode=%s slots=%s turns=%d result=%s gaps=%s lines=%d"):format(name,
          tostring(res.kind), tostring(res.mode), tostring(res.slots), res.turns, tostring(res.result),
          tostring(res.gaps), #res.said))
        log("lines:", (table.concat(res.said, " | "):gsub("%s+", " ")))
        check(res.kind == "coop", name .. ": the fight is the co-op screen (" .. tostring(res.kind) .. ")")
        check(res.mode == mode, name .. ": the hub refereed it as " .. mode .. " (" .. tostring(res.mode) .. ")")
        check(res.mediated == true, name .. ": hub-refereed (the screen only replays the referee's events)")
        check(res.slots == slots, ("%s: %d seats on the field (%s)"):format(name, slots, tostring(res.slots)))
        check(res.ended, name .. ": the fight ran to its end and its screen closed")
        check(res.gaps == 0, name .. ": no gaps in the mediated event stream")
        -- a catch is one throw from the ITEM menu: no move list, no knockout
        check(res.seen.command and (res.seen.moves or name == "catch"),
              name .. ": the command menu" .. (name == "catch" and "" or " and the move list") .. " were on screen")
        check(res.seen.hit or name == "catch", name .. ": a damaging turn played (the HP bar moved)")
        check(res.seen.faint or name == "catch", name .. ": a knockout was narrated")
        check(res.result == "win", name .. ": the party won (" .. tostring(res.result) .. ")")
      end

      -- --- a wild fight: `catching` throws a MASTER BALL instead of fighting
      local function wildFight(name, catching)
        H.closeToOverworld(game)
        H.g3SetOption(game, "classicui", false)
        local placed = true
        if not catching then
          local lead = H.g3SeedLead(game, B.coopHost, B.coopHostLevel, { levelUpNext = true })
          check(lead ~= nil, ("%s: a level %d %s leads, one point short of its next level")
                :format(name, B.coopHostLevel, B.coopHost))
          local cell = H.g3GrassCells(game, B.wildMap)
          check(cell ~= nil, name .. ": a patch of tall grass on " .. B.wildMap)
          placed = cell ~= nil and H.g3Teleport(game, B.wildMap, cell.x, cell.y, "down")
          check(placed, name .. ": standing in the grass on " .. B.wildMap)
        else
          check(H.g3GiveItem(game, "MASTER_BALL", 1), name .. ": a MASTER BALL in the bag")
        end
        local before = H.g3PartyDigest(game)
        local balls = H.g3BagCount(game, "MASTER_BALL")
        H.signal("g3_host_" .. name .. "_ready")
        H.await(game, "g3_guest_" .. name .. "_ready")
        check(partnerOnMap(), name .. ": the partner stands on the same map (roster + avatar)")
        shot(name .. "-grass")

        -- walk the grass the way a player does: up and down until a step rolls
        local i, coverShot = 0, false
        local met = placed and H.waitSeconds(game, function()
          if H.g3Fight(game) then return true end
          -- the cover: the divert's frozen field with the cart's own "Wild X
          -- appeared!" line, up for the moment the partner's join takes
          if not coverShot and H.g3Layer() ~= nil and not H.g3Free(game) then
            coverShot = true
            shot(name .. "-cover", false, true)
          end
          if not H.g3Free(game) then U.wait(2) return false end
          i = i + 1
          U.hold(game, (i % 2 == 0) and "up" or "down", 16)
          U.wait(2)
          return false
        end, 200, "a step encounter in the grass")
        check(met, name .. ": walking the grass raised an encounter and the co-op fight took it over")
        if met then
          local thrown = false
          local res = H.g3PilotFight(game, {
            shot = shot, label = name, seconds = 300,
            onChoose = function()
              if catching and not thrown then
                thrown = true
                check(H.throwBattleItem(game, "MASTER_BALL"), name .. ": MASTER BALL filed from the ITEM menu")
                return "skip"
              end
            end,
          })
          coopResult(name, res, "coop_wild", 3)
          H.closeToOverworld(game)
          H.g3Settle(game, 600)
          check(H.g3Free(game), name .. ": back in the field, free to walk")
          local after = H.g3PartyDigest(game)
          if catching then
            local said = table.concat(res.said, " ")
            check(said:find("Gotcha", 1, true) ~= nil or said:find("was caught", 1, true) ~= nil,
                  name .. ": the catch was narrated")
            check(#after == #before + 1, name .. ": the caught monster joined the party",
                  ("%d -> %d"):format(#before, #after))
            local session = H.g3Session(game)
            local caught = session and session.party and session.party[#session.party]
            check(caught ~= nil and (caught.otName == "HOSTY" or caught.ot == "HOSTY"),
                  name .. ": the catcher is its original trainer")
            check(caught ~= nil and H.dexOwned(game, caught.species), name .. ": the dex marks it caught")
            check(H.g3BagCount(game, "MASTER_BALL") == (balls or 1) - 1, name .. ": the MASTER BALL was spent",
                  ("%s -> %s"):format(tostring(balls), tostring(H.g3BagCount(game, "MASTER_BALL"))))
          else
            check(res.seen.exp, name .. ": the cart's 'gained EXP. Points' line was on screen")
            check(res.seen.levelup, name .. ": 'grew to Lv.' was on screen")
            check(after[1] ~= nil and after[1].level == before[1].level + 1,
                  name .. ": the knockout's EXP levelled the lead up",
                  ("%s -> %s"):format(tostring(before[1].level), tostring(after[1] and after[1].level)))
            check(after[1] ~= nil and after[1].exp > before[1].exp, name .. ": EXP was written home",
                  ("%s -> %s"):format(tostring(before[1].exp), tostring(after[1] and after[1].exp)))
            check(after[1] ~= nil and ppSum(after[1]) < ppSum(before[1]),
                  name .. ": the PP the fight spent came home",
                  ("%d -> %d"):format(ppSum(before[1]), ppSum(after[1])))
          end
          shot(name .. "-after")
        end
        H.signal("g3_host_" .. name .. "_done")
        H.await(game, "g3_guest_" .. name .. "_done")
      end
      wildFight("wild", false)
      wildFight("catch", true)

      -- --- the NPC trainer, with a POTION on a hurt lead in the middle of it
      do
        H.closeToOverworld(game)
        H.g3SetOption(game, "classicui", false)
        local lead = H.g3SeedLead(game, B.coopHost, B.coopHostLevel)
        check(lead ~= nil, "trainer: a level " .. B.coopHostLevel .. " " .. B.coopHost .. " leads")
        -- hurt, with a POTION to heal it: what the ITEM turn heals must be
        -- the HP the save holds afterwards
        lead.hp = math.max(1, math.floor(lead.maxHp * 0.3))
        check(H.g3GiveItem(game, "POTION", 1), "trainer: a POTION in the bag")
        local before = H.g3PartyDigest(game)
        H.g3Teleport(game, B.trainerMap, 1, 1, "down")
        local eo = H.g3ObjectById(B.trainerLid)
        local sx, sy, dir
        if eo then sx, sy, dir = H.g3SightApproach(eo) end
        check(sx ~= nil, "trainer: a trainer with a line of sight stands on " .. B.trainerMap)
        local tid = eo and H.g3TrainerId(eo)
        log("trainer:", tostring(B.trainerMap), "object", tostring(B.trainerLid), "id", tostring(tid),
            "walk", tostring(sx), tostring(sy), tostring(dir))
        if eo then H.g3ClearTrainer(eo) end
        check(eo ~= nil and H.g3TrainerDefeated(eo) == false, "trainer: not beaten yet")
        local placed = sx ~= nil and H.g3Teleport(game, B.trainerMap, sx, sy, dir)
        check(placed, "trainer: standing just outside the trainer's line of sight")
        H.signal("g3_host_trainer_ready")
        H.await(game, "g3_guest_trainer_ready")
        check(partnerOnMap(), "trainer: the partner stands on the same map (roster + avatar)")
        shot("trainer-approach")

        local noticed, kitChecked, healed = false, false, false
        local met = placed and H.waitSeconds(game, function()
          if H.g3Fight(game) then return true end
          -- the moment it sees us: the field is locked (the "!", the walk up)
          -- before its speech starts, with no layer or message of anyone's up
          if not noticed and not H.g3Free(game) and H.g3Layer() == nil
             and not (H.g3Top(game) and H.g3Top(game).g3Engine == "message") then
            noticed = true
            shot("trainer-noticed")
          end
          local top = H.g3Top(game)
          if type(top) == "table" and top.g3Engine == "message" and H.g3Layer() == nil then
            U.tap(game, "a")
            U.wait(6)
            return false
          end
          if not H.g3Free(game) then U.wait(4) return false end
          U.hold(game, dir, 16)   -- one step in
          U.wait(1)
          return false
        end, 180, "the trainer to see us and the co-op fight to open")
        check(met, "trainer: walking into sight raised the fight and the co-op screen took it over")
        if met then
          local res = H.g3PilotFight(game, {
            shot = shot, label = "trainer", seconds = 300,
            onChoose = function()
              if not kitChecked then
                kitChecked = true
                H.assertTrainerKit(game, check, log, { class = tid })
              end
              if not healed then
                healed = true
                check(H.throwBattleItem(game, "POTION"), "trainer: POTION filed on the lead from the ITEM menu")
                return "skip"
              end
            end,
          })
          coopResult("trainer", res, "coop_npc", 4)
          H.g3TalkUntilFree(game, 90)
          check(H.g3Free(game), "trainer: back in the field, free to walk")
          local beaten = H.waitSeconds(game, function()
            return H.g3TrainerDefeated(H.g3ObjectById(B.trainerLid)) == true
          end, 20, "the trainer's flag")
          check(beaten, "trainer: the cart marked the trainer beaten (its flag is set)")
          U.wait(120)
          check(H.g3Fight(game) == nil and H.g3Free(game), "trainer: no rematch -- the field stays the player's")
          local after = H.g3PartyDigest(game)
          check(after[1] ~= nil and after[1].exp > before[1].exp, "trainer: EXP was written home",
                ("%s -> %s"):format(tostring(before[1].exp), tostring(after[1] and after[1].exp)))
          check(H.g3BagCount(game, "POTION") == 0, "trainer: the POTION was spent (bag written home)")
          check(after[1] ~= nil and after[1].hp > before[1].hp, "trainer: the POTION's healing came home (HP)",
                ("%s -> %s"):format(tostring(before[1].hp), tostring(after[1] and after[1].hp)))
          shot("trainer-after")
        end
        H.signal("g3_host_trainer_done")
        H.await(game, "g3_guest_trainer_done")
      end
    end

    H.await(game, "g3_guest_party_done")
    check(H.waitSeconds(game, function() return #exports.party() == 0 end, 45, "the party to end"),
          "the guest leaving ends the party here too")
  end

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
