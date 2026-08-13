-- Driver: host a game from inside the game, hosting side.
--
-- Pair with tests/drivers/mmo_join.lua in a second instance; the wrapper
-- script run-mmo-e2e.sh launches both and greps the MMO_HOST: / MMO_JOIN:
-- lines these print.
--
-- This is the half of the mod the headless suites structurally cannot
-- reach: a real luasocket listener, the real accept loop, the real menus
-- being navigated, and avatars spawned by an actual remote player. Every
-- assertion below is about something no unit test can see.
--
--   POKEPORT_IDENTITY=mmohost POKEPORT_DRIVER=mods/rby_mmo/tests/drivers/mmo_host.lua love .

-- Muted at load rather than in mmo_util, which is only reached once the game
-- is ready -- by then the title music is already playing. Nothing here ever
-- asserts on a sound, and two instances playing a battle at each other for
-- minutes is not something a background run should do to a room.
if os.getenv("MMO_SOUND") ~= "1" and love and love.audio then
  love.audio.setVolume(0)
end

return function(game)
  local H = dofile("mods/rby_mmo/tests/drivers/mmo_util.lua")
  local U = H.U
  local TAG = "MMO_HOST:"
  local ADDR_FILE = os.getenv("MMO_ADDR_FILE") or "/tmp/rby_mmo_addr.txt"
  local SHOT_DIR = os.getenv("SHOT_DIR") or "/tmp/rby_mmo_shots"
  local LIMIT = tonumber(os.getenv("MMO_LIMIT") or "") or 2
  -- There is no switch for the join code, and there deliberately is not one
  -- any more: HostServer:start refuses to bind a port without one, so a run
  -- with the code turned off would be testing a game that cannot be hosted.
  -- MMO_JOIN_CODE=0 used to select exactly that, and selecting an impossible
  -- configuration is worse than having no switch at all.

  local function log(...) U.log(TAG, ...) end
  local events = H.captureEvents({ "battle.started", "battle.ended", "link.desync" })
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

  os.remove(ADDR_FILE)
  os.remove(ADDR_FILE .. ".tmp")

  U.newGame(game)
  -- U.newGame mashes A through the naming grid, so both sides would
  -- otherwise be called AAAAAAA and no roster assertion could tell
  -- them apart. Name them here instead.
  if game.save and game.save.player then
    game.save.player.name = "HOSTY"
  end
  -- A trade needs something to trade. Distinct species per side is what
  -- makes "the trade happened" checkable rather than a matter of faith.
  local Pokemon = require("src.pokemon.Pokemon")
  game.save.party = { Pokemon.new(game.data, "CHARIZARD", 50) }
  -- so the driven battle actually resolves; see frontloadDamage
  local lead = H.frontloadDamage(game.data, game.save.party[1])
  log("in the overworld as HOSTY with", table.concat(H.partySpecies(game), ","),
      "leading with", tostring(lead))

  local exports = H.requireMod(game, TAG)
  if not exports then
    log("RESULT 1 failure(s)")
    return
  end
  if exports.traceAvatars then exports.traceAvatars(true) end
  check(exports.isConnected() == false, "starts disconnected")
  check(exports.isHosting() == false, "starts not hosting")

  -- ------- host, through the real menus

  if not H.openMmo(game) then
    log("FAIL could not reach the MMO menu")
    log("RESULT 1 failure(s)")
    return
  end
  check(true, "the MMO row exists on the START menu")

  if not H.selectLabel(game, "HOST GAME") then
    log("FAIL no HOST GAME row")
    log("RESULT " .. (failures + 1) .. " failure(s)")
    return
  end

  -- Character creation now sits between the menu and hosting: who you are
  -- online is asked once, before the room exists.
  U.wait(20)
  check(H.classify(H.top(game)) == "menu", "character creation opened")
  U.shot(game, SHOT_DIR .. "/host-charsetup.png")

  -- Open the character list, then back out of it. The run wears whatever
  -- MMO_HOST_SPRITE asked for, so this changes nothing -- it is here because
  -- the picker was the one screen in the flow nothing ever opened, which
  -- meant a mistake in it could only be found by hand.
  if H.selectLabel(game, "LOOK") then
    U.wait(20)
    check(H.classify(H.top(game)) == "menu", "the character picker opened")
    U.shot(game, SHOT_DIR .. "/host-charpick.png")
    U.tap(game, "b")
    U.wait(20)
    check(H.classify(H.top(game)) == "menu", "backed out to character creation")
  else
    check(false, "no LOOK row on character creation")
  end

  check(H.selectLabel(game, "HOST"), "confirmed the trainer and moved on")

  -- HOST GAME no longer opens the size list. The join code needed somewhere
  -- to live and a bare number box had no room for it, so both sit on a setup
  -- menu with START under them, and hosting begins when the host says so
  -- rather than the moment a size is picked.
  U.wait(20)
  check(H.classify(H.top(game)) == "menu", "the host setup menu opened")
  U.shot(game, SHOT_DIR .. "/host-setup.png")

  -- the size picker is a named list now, so the run picks its row by name
  check(H.selectLabel(game, "PLAYERS"), "PLAYERS opens the size list")
  U.wait(20)
  check(H.classify(H.top(game)) == "menu", "the limit picker opened")
  U.shot(game, SHOT_DIR .. "/host-limit.png")
  local picked = H.selectLabel(game, ("%d PLAYERS"):format(LIMIT))
  check(picked, "chose " .. LIMIT .. " PLAYERS")
  U.wait(20)
  -- picking a size is a setting, not a start: it comes back here
  check(H.classify(H.top(game)) == "menu", "and came back to the setup menu")

  -- ------- the join code, already set before anyone can knock
  --
  -- Read back off the screen rather than out of the mod: the code is
  -- deliberately absent from every log and every export, and a host who
  -- cannot read theirs has a game nobody can join -- so what the screen
  -- prints IS the feature.
  --
  -- Nothing here turns the code on any more. It is a requirement, so the
  -- setup screen mints one on the way in and the JOIN CODE row reads it out
  -- -- six characters a host can say down a phone, where that row used to
  -- say ON and send them somewhere else to find out what "on" meant. The run
  -- asserts the row arrives carrying a code, then changes it deliberately
  -- and asserts the row followed.

  local minted = H.menuRow(game, "JOIN CODE")
  local mintedCode = minted and H.codeFrom(tostring(minted.right))
  check(mintedCode ~= nil,
        "the setup screen arrives with a code on its JOIN CODE row: "
          .. tostring(minted and minted.right))

  local joinCode = mintedCode
  if check(H.selectLabel(game, "JOIN CODE"), "JOIN CODE opens the lock menu") then
    U.wait(20)
    check(H.classify(H.top(game)) == "menu", "the lock menu opened")
    U.shot(game, SHOT_DIR .. "/host-codemenu.png")

    -- The row that is gone. A game with no code is one any stranger who can
    -- reach the port walks into, and HostServer will not open a port without
    -- one -- so an escape hatch here would lead nowhere but a refusal at
    -- START, which is a worse way to learn it than not being offered.
    local labels = H.menuLabels(game)
    log("lock menu:", table.concat(labels, ","))
    local hasNoCode = false
    for _, label in ipairs(labels) do
      if label == "NO CODE" then hasNoCode = true end
    end
    check(not hasNoCode, "and offers no way to host without a code")

    check(H.selectLabel(game, "NEW CODE"), "asked the game to make one")
    U.wait(30)
    local shown = H.textOf(H.top(game))
    local fresh = H.codeFrom(shown)
    check(fresh ~= nil,
          "the screen reads out a code a friend could type: "
            .. H.formatCode(fresh or ""))
    -- and it is genuinely a new one: at 30 bits the odds of drawing the
    -- minted code again are about one in a billion, so a match here means
    -- NEW CODE showed the old one rather than minting anything
    check(fresh ~= nil and fresh ~= mintedCode,
          "and it is a different code from the one already set")
    -- printed, not merely open: the six characters are the entire content of
    -- this screen, and a capture taken while the typewriter is still on
    -- "Players will" shows none of them. H.shotPrinted waits for the box to
    -- say it has stopped typing rather than sleeping a guessed number of
    -- frames -- see M.printed in mmo_util.
    H.shotPrinted(game, SHOT_DIR .. "/host-newcode.png")
    joinCode = fresh or mintedCode

    -- The box's onDone puts the setup menu back. Frames: this is a local
    -- text box being dismissed by local button presses, with nothing on
    -- the wire and no second process involved.
    local back = H.waitFor(game, function()
      local top = H.top(game)
      if top and type(top.items) == "table" then return true end
      U.tap(game, "a")
      return false
    end, 240, "the setup menu after setting a code")
    check(back, "and setting one returns to the setup menu")

    -- the row carries the code itself, which is where a host reads it back
    -- without opening the code screen again
    local row = H.menuRow(game, "JOIN CODE")
    check(joinCode ~= nil and row ~= nil
          and tostring(row.right) == H.formatCode(joinCode),
          "the JOIN CODE row reads the code back: "
            .. tostring(row and row.right))
  end

  check(H.selectLabel(game, "START"), "START begins the game")
  U.wait(30)

  -- ------- the listener is real

  -- Frames, and deliberately: socket.bind either works on the step START ran
  -- on or does not work at all. Nothing outside this process is involved, so
  -- there is nothing here for the other window's frame rate to skew.
  local hosting = H.waitFor(game, function() return exports.isHosting() end,
                            240, "the listener to come up")
  check(hosting, "hosting started (a real socket is bound)")
  if not hosting then
    log("RESULT " .. failures .. " failure(s)")
    return
  end
  -- Same again, and the reason is sharper here: this box is three lines --
  -- "Tell your friends:", the address, then CODE: -- so the two lines that
  -- matter are the two that are only on screen once it has finished printing
  -- and scrolled.
  H.shotPrinted(game, SHOT_DIR .. "/host-address.png")

  local address = exports.hostAddress and exports.hostAddress() or nil
  check(type(address) == "string" and address:find(":"),
        "an address is published: " .. tostring(address))

  -- The host is a player on its own hub, over loopback. Frames: HostServer's
  -- localNet hands messages straight to Hub in-process, so this handshake
  -- completes in a fixed handful of steps with no second process in it.
  local joinedSelf = H.waitFor(game, function() return exports.isConnected() end,
                               240, "the host to join its own game")
  check(joinedSelf, "the host joined its own game over loopback")

  -- The chosen character has to change your own game too, not just what
  -- everyone else sees. Compare the live player's sheet against the one the
  -- catalog holds for the chosen id -- a look that only travelled over the
  -- wire would pass every roster assertion and still look wrong to you.
  local mine = exports.myLook and exports.myLook() or nil
  log("my look:", tostring(mine))
  local ow
  for i = #game.stack.states, 1, -1 do
    if game.stack.states[i].isOverworld then ow = game.stack.states[i] break end
  end
  local record = game.data.sprites[mine or ""]
  local worn = ow and ow.player and ow.player.sprite
  local wornImage = worn and (worn.def and worn.def.image or worn.image)
  log("wearing:", tostring(wornImage), "expected", tostring(record and record.image))
  check(record ~= nil and wornImage ~= nil
        and tostring(wornImage):find(tostring(record.image), 1, true) ~= nil,
        "the local player wears the chosen character")

  -- The character itself, stood in the world facing the camera. Taken here
  -- because the host is still alone in its own game -- once the guest
  -- arrives there is a nameplate across the picture.
  local shownLook = H.shotLook(game, SHOT_DIR .. "/host-overworld-look.png")
  log("overworld look:", tostring(shownLook))
  check(shownLook ~= nil, "the character is on screen in the overworld")

  -- The pic the trainer card draws you as, which is the front half of the
  -- same hook the battle back pic rides. A character the mod brought answers
  -- it with art of its own; a ROM character leaves the game's own pic alone,
  -- which is the behaviour worth pinning either way.
  local cardPic = H.shotTrainerCard(game, SHOT_DIR .. "/host-trainer-card.png")
  log("trainer card pic:", tostring(cardPic))
  check(type(cardPic) == "string" and cardPic ~= "",
        "the trainer card resolves a pic to draw")
  if tostring(mine):find("SPRITE_NIRE", 1, true) then
    check(tostring(cardPic):find("assets/chars/", 1, true) ~= nil,
          "and a character the mod brought draws its own")
  end

  -- close the menus so the overworld is on top when the guest arrives
  H.closeToOverworld(game)

  -- The guest connects to 127.0.0.1; the LAN address is what a human would
  -- read aloud, so publish both and let the joiner pick.
  --
  -- Second line: the join code, which is always there now -- a hosted game
  -- without one cannot exist. This is the channel the two processes already
  -- have -- the address travels it -- and a code is the other half of the
  -- same sentence a host reads out, so it belongs here rather than in a
  -- second file with its own race.
  --
  -- Written and renamed rather than written in place: the wrapper script and
  -- the guest both watch for this path to exist, and a two-line file caught
  -- mid-write would hand the guest an address and no code.
  local handle = io.open(ADDR_FILE .. ".tmp", "w")
  if handle then
    handle:write(tostring(address) .. "\n" .. (joinCode or "") .. "\n")
    handle:close()
    os.rename(ADDR_FILE .. ".tmp", ADDR_FILE)
  end
  log("hosting", tostring(address), "limit", LIMIT,
      "code " .. H.formatCode(joinCode))

  -- ------- a real remote player shows up

  -- Seconds: the guest is another process, walking its own intro at its own
  -- frame rate. See H.waitSeconds -- this is the wait that taught us why.
  local sawGuest = H.waitSeconds(game, function()
    return #exports.players() > 0
  end, 400, "the guest to connect")
  check(sawGuest, "a remote player joined over a real socket")

  if sawGuest then
    local guest = exports.players()[1]
    log("guest is", tostring(guest.name), "on", tostring(guest.map))
    check(type(guest.name) == "string" and guest.name ~= "",
          "the guest has a name on the roster")

    -- "Pick your look": the guest chose a sprite through the mod's option,
    -- and it has to survive the wire and reach the avatar. Asserting the
    -- roster value alone would not prove much -- an id that the catalog
    -- rejects falls back to the default, silently -- so the spawn is
    -- checked too.
    local wantSprite = os.getenv("MMO_EXPECT_GUEST_SPRITE")
    if wantSprite and wantSprite ~= "" then
      log("guest sprite:", tostring(guest.sprite), "expected", wantSprite)
      check(guest.sprite == wantSprite,
            "the guest's chosen sprite crossed the wire intact")
      local row = H.avatarRow(exports)
      check(row ~= nil and row.spawned,
            "and the avatar spawned with it (the catalog accepted the id)")
    end
    U.wait(120)
    U.shot(game, SHOT_DIR .. "/host-sees-guest.png")

    -- presence: the guest walks, and the host's roster follows
    local before = exports.players()[1]
    local startX, startY = before.x, before.y
    local moved = H.waitSeconds(game, function()
      local now = exports.players()[1]
      return now and (now.x ~= startX or now.y ~= startY)
    end, 45, "the guest to move")
    check(moved, "the guest's movement reaches the host")

    -- The roster moving proves the wire works. Whether the *avatar* moved
    -- is a separate question, and the one the screenshots answer badly --
    -- so read both and compare, rather than trusting a passing roster
    -- assertion to mean the world looks right.
    --
    -- Sampling starts immediately: the avatar catches up within a second,
    -- so any delay here lands entirely after it has arrived and the
    -- mid-step window is missed.
    -- cellOf reports pixel position in cells, so it is fractional mid-step;
    -- "arrived" is a tolerance, not equality
    local function at(a, b)
      return a ~= nil and b ~= nil and math.abs(a - b) < 0.01
    end

    -- Bounded by the clock, not by a sample count, for the same reason
    -- everything else here is: what it is waiting for is a remote player's
    -- step arriving, and 400 samples is however many seconds this window's
    -- frame rate says it is. The *sampling* stays fine-grained -- that part
    -- really is about frames.
    local followed, sawWalking, samples = false, false, 0
    local sampleUntil = os.time() + 60
    while os.time() < sampleUntil do
      local rows = exports.avatarState()
      local row = rows and rows[1]
      if row then
        if row.walking then sawWalking = true end
        samples = samples + 1
        if samples % 25 == 1 then
          log(("avatar: spawned=%s roster=(%s,%s) avatar=(%s,%s) walking=%s")
            :format(tostring(row.spawned), tostring(row.rosterX),
                    tostring(row.rosterY), tostring(row.avatarX),
                    tostring(row.avatarY), tostring(row.walking)))
        end
        if row.spawned and at(row.avatarX, row.rosterX)
           and at(row.avatarY, row.rosterY) then
          followed = true
        end
      end
      if followed and sawWalking then break end
      -- sampled finely: a step lasts 16 frames, so a coarse poll would
      -- miss the walking window entirely and report a false negative
      U.wait(4)
    end
    check(followed, "the avatar caught up to where the network says it is")
    check(sawWalking, "and was seen mid-step -- the walk actually animates")

    -- Say which way the overlay drew, so a run states the rendering path it
    -- exercised instead of leaving it to whatever happened to be installed.
    -- "labels" is the flat 2D projection; "roster" is the corner list for
    -- a world renderer that does not expose a compatible camera projection.
    local ov = exports.overlayState and exports.overlayState() or {}
    log(("overlay path: %s (derived-letterbox=%s)"):format(
      tostring(ov.reached), tostring(ov.derived or false)))
    check(ov.reached == "labels" or ov.reached == "roster",
          "the overlay drew something for the player on screen")
    U.shot(game, SHOT_DIR .. "/host-guest-moved.png")

    -- ------- 1b. coexistence with a mod that owns the world pass
    --
    -- Only runs when DramaticShapeVoxelMod is installed alongside. Turning
    -- its pipeline on is the only way to prove the plates use the 3D
    -- camera Voxel exposes to companion mods rather than the flat grid.
    local okPipes, Pipelines = pcall(require, "src.render.Pipelines")
    if okPipes and Pipelines and Pipelines.get and Pipelines.get("voxel") then
      log("voxel pipeline present; switching it on")
      Pipelines.setLevel("voxel", 1)
      U.wait(120)
      log(("voxel level=%s eligible=%s"):format(
        tostring(Pipelines.level("voxel")),
        tostring(Pipelines.eligible and Pipelines.eligible("voxel"))))
      local st = exports.overlayState and exports.overlayState() or {}
      log(("overlay: reached=%s here=%s gameX=%s scale=%s"):format(
        tostring(st.reached), tostring(st.here), tostring(st.gameX),
        tostring(st.scale)))
      check(st.reached == "voxel-labels",
            "Voxel projects the guest nickname above its 3D character")
      U.shot(game, SHOT_DIR .. "/host-voxel-nameplates.png")
      Pipelines.setLevel("voxel", 0)
      U.wait(60)
    else
      log("no voxel pipeline installed; skipping the coexistence shot")
    end

    -- ------- 2. the host's own movement reaches the guest
    --
    -- Only the guest can judge this, so the host walks between two markers
    -- and the guest asserts what it saw.

    H.signal("host_walk_start")
    -- Wait for the guest to take its baseline before moving. Signalling and
    -- walking immediately raced it: the guest could sample *after* the walk
    -- and then wait forever for a change that had already happened.
    H.await(game, "guest_baseline_taken")

    local wasAt = H.playerCell(game)
    -- left/right rather than down: Red's bedroom is small and a few tiles
    -- south runs into furniture, which would make "the host did not move"
    -- a map-geometry result rather than a networking one
    --
    -- B held throughout, which makes this walk do double duty: it is
    -- already the leg that proves the host's own movement reaches the
    -- guest, and holding B across every step of it is also this run's only
    -- exercise of hold-B running end to end -- see the guest's poll on
    -- "host_walk_done" for the other half. H.holdAll rather than U.hold:
    -- running needs the direction and B down at the same moment, which two
    -- sequential U.hold calls cannot express.
    for _ = 1, 2 do
      H.holdAll(game, { "left", "b" }, 22)
      U.wait(8)
    end
    H.holdAll(game, { "right", "b" }, 22)
    U.wait(8)
    local nowAt = H.playerCell(game)
    log(("host walked (%s,%s) -> (%s,%s)"):format(
      tostring(wasAt and wasAt.x), tostring(wasAt and wasAt.y),
      tostring(nowAt and nowAt.x), tostring(nowAt and nowAt.y)))
    check(nowAt and wasAt and (nowAt.x ~= wasAt.x or nowAt.y ~= wasAt.y),
          "the host's own player actually moved")
    H.signal("host_walk_done")

    -- ------- 3. chat both ways

    exports.say("global", "HELLO FROM HOST")
    log("said hello")
    local heardGuest = H.waitSeconds(game, function()
      for _, line in ipairs(exports.chat()) do
        if line.text == "HELLO FROM GUEST" then return true end
      end
      return false
    end, 120, "the guest's chat line")
    check(heardGuest, "the guest's chat reached the host")

    -- ------- invite refuse (focused e2e; see run-invite-refuse-e2e.sh)
    --
    -- A battle ask that arrives while this side is mid-trainer fight must
    -- be answered no immediately -- no confirm over the fight. The guest
    -- half asserts the refusal text; we assert nothing was held incoming.
    if os.getenv("MMO_INVITE_REFUSE_E2E") == "1" then
      local class = H.coopTrainer(game.data)
      check(class ~= nil, "found a trainer class to stage")
      local staged = class and H.stageTrainer(game, class)
      check(staged ~= nil, "staged a trainer battle on the host")
      local fighting = H.waitSeconds(game, function()
        return exports.isFighting and exports.isFighting()
      end, 15, "host to report isFighting")
      check(fighting, "host isFighting after staging a trainer")
      H.signal("host_in_fight")

      H.await(game, "guest_asked_battle_in_fight")
      -- Room for the request to land if auto-refuse ever fails to clear it.
      U.wait(45)
      check(not (exports.hasIncomingRequest and exports.hasIncomingRequest()),
            "no incoming invite held while fighting")
      local top = H.top(game)
      local text = (H.textOf(top) or ""):lower()
      check(not (text:find("wants", 1, true) and text:find("battle", 1, true)),
            "no battle confirm over the fight")
      check(exports.isFighting and exports.isFighting(),
            "host still in the fight after the ask")
      U.shot(game, SHOT_DIR .. "/host-invite-refused-while-fighting.png")

      H.await(game, "guest_saw_battle_refusal")
      H.closeToOverworld(game)
      log("DONE")
      return
    end

    -- ------- party wild (focused e2e; see run-party-wild-e2e.sh)
    --
    -- Form a party, stage a wild on the host, assert coop_wild divert and
    -- hub-refereed 2v1, throw MASTER_BALL, assert catcher grant. Skips trade,
    -- link battle, and the coop_npc trainer leg.
    if os.getenv("MMO_PARTY_WILD_E2E") == "1" then
      local WILD_SPECIES = "PIDGEY"
      local announced = H.listenForModEvents(game, {
        "mod.rby_mmo.coop_battle_started",
        "mod.rby_mmo.coop_battle_ended",
      })

      H.await(game, "guest_ready_for_party")
      if H.openMmo(game) and H.selectLabel(game, "PLAYERS") then
        U.wait(25)
        if H.selectLabel(game, "GUESTY") then
          U.wait(30)
          check(H.selectLabel(game, "INVITE"), "asked the guest to team up")
        else
          check(false, "found the guest on the PLAYERS list")
        end
      else
        check(false, "opened the PLAYERS list to invite from")
      end
      H.signal("host_party_asked")

      local paired = H.drivePrompts(game, function()
        return #exports.party() == 2
      end, 120)
      check(paired, "the party formed over the in-game hub")
      H.await(game, "guest_party_joined")
      H.closeToOverworld(game)

      -- Bag sheet is uploaded when the mediated fight starts; seed before divert.
      check(H.giveItem(game, "MASTER_BALL", 1), "seeded a MASTER_BALL for the catch")
      local partyBefore = H.partySpeciesCount(game)
      local speciesBefore = H.partySpeciesCount(game, WILD_SPECIES)
      local ballsBefore = (game.save.inventory and game.save.inventory.MASTER_BALL) or 0

      local wildFinished = nil
      local staged = H.stageWild(game, WILD_SPECIES, 5, function(result)
        wildFinished = result
      end)
      check(staged ~= nil, "staged a wild battle on the host")

      local waiting = H.waitSeconds(game, function()
        return exports.coopWaiting() ~= nil
      end, 60, "coop_wild wait after the wild divert")
      check(waiting, "the host diverted into coop_wild wait")
      -- Shot first: the partner often auto-joins within a frame, so the wait
      -- can already be over by the time we sample anything.
      U.shot(game, SHOT_DIR .. "/host-party-wild-wait.png")
      -- Round 13: the wait cover is deleted outright -- no box, no rows, on
      -- either mode. The engine's own wild encounter stays exactly on
      -- screen; the only exits are the field opening (partner joined) or
      -- SOLO_FALLBACK_AFTER's one-line fallback (nobody did).
      if exports.coopWaiting() ~= nil then
        check(H.menuRow(game, "ALONE") == nil and H.menuRow(game, "WAIT") == nil,
              "no cover -- no menu rows at all while the wait stands")
      else
        check(true, "no cover -- no menu rows at all while the wait stands")
        log("note: partner joined before the wait could be sampled")
      end
      H.signal("host_wild_waiting")

      H.await(game, "guest_wild_joined")
      local onField = H.waitSeconds(game, function()
        local top = H.top(game)
        return top ~= nil and top.sim ~= nil and #top.sim.slots == 3
      end, 120, "the Party-vs-Wild field to come up")
      check(onField, "a three-slot coop_wild battle is on screen")
      local refereed = H.awaitMediatedCoop(game, 60, "coop_wild")
      check(refereed,
            "the LAN Party-vs-Wild fight is hub-refereed (coop_wild)")
      do
        local top = H.top(game)
        log(("mediated coop_wild: id=%s mode=%s medGaps=%s"):format(
          tostring(top and top.battleId), tostring(top and top.mode),
          tostring(top and top.medGaps)))
      end
      check(announced["mod.rby_mmo.coop_battle_started"] >= 1,
            "coop_battle_started fired for Party vs Wild")

      check(H.awaitCommandMenu(game, "the command menu before MASTER_BALL"),
            "the coop_wild command grid opens")
      U.wait(30)
      U.shot(game, SHOT_DIR .. "/host-party-wild-battle.png")
      check(exports.coopDrawFailed() == false, "and it drew without error")
      check(H.throwBattleItem(game, "MASTER_BALL"),
            "filed MASTER_BALL from the ITEM menu")
      log("threw MASTER_BALL")

      local medGaps = 0
      local over = H.drivePrompts(game, function()
        local top = H.top(game)
        return top == nil or top.sim == nil
      end, 240, function()
        local top = H.top(game)
        if H.isMediatedCoop(top) then
          medGaps = tonumber(top.medGaps) or medGaps
        end
        U.tap(game, "a")
      end)
      check(over, "the coop_wild fight runs to an end")
      local sync = exports.coopSync()
      log(("coop_wild sync: gaps=%d desyncs=%d resyncs=%d medGaps=%d"):format(
        sync.gaps, sync.desyncs, sync.resyncs, medGaps))
      check(sync.gaps == 0, "with no turn lost by the Lua hub")
      check(sync.desyncs == 0, "and no drift between the two copies")
      check(medGaps == 0, "and no gaps in the mediated event stream")
      check(announced["mod.rby_mmo.coop_battle_ended"] >= 1,
            "coop_battle_ended fired after Party vs Wild")

      local ballsAfter = (game.save.inventory and game.save.inventory.MASTER_BALL) or 0
      check(ballsAfter < ballsBefore, "MASTER_BALL was spent on the catch")
      local partyAfter = H.partySpeciesCount(game)
      local speciesAfter = H.partySpeciesCount(game, WILD_SPECIES)
      check(partyAfter > partyBefore,
            "catcher party grew after the MASTER_BALL catch")
      check(speciesAfter > speciesBefore,
            ("caught %s was granted to the host party"):format(WILD_SPECIES))
      log(("catch grant: party %d -> %d, %s %d -> %d, balls %d -> %d"):format(
        partyBefore, partyAfter, WILD_SPECIES, speciesBefore, speciesAfter,
        ballsBefore, ballsAfter))
      log("engine wild result:", tostring(wildFinished))
      U.shot(game, SHOT_DIR .. "/host-party-wild-after.png")
      H.signal("host_wild_done")
      H.await(game, "guest_wild_done")
      H.closeToOverworld(game)
      log("DONE")
      return
    end

    -- ------- 1. the guest leaves the map, and comes back
    --
    -- A remote player on another map must not be drawn on this one; the
    -- roster keeps them, the avatar does not.

    H.await(game, "guest_left_map")
    local despawned = H.waitSeconds(game, function()
      local row = H.avatarRow(exports)
      return row ~= nil and row.spawned == false
    end, 45, "the avatar to despawn")
    check(despawned, "a player who leaves the map loses their avatar")
    local stillListed = #exports.players() > 0
    check(stillListed, "but stays on the roster")
    H.signal("host_saw_despawn")

    H.await(game, "guest_back_on_map")
    local respawned = H.waitSeconds(game, function()
      local row = H.avatarRow(exports)
      return row ~= nil and row.spawned == true
    end, 45, "the avatar to come back")
    check(respawned, "and gets it back on returning to the map")
    U.shot(game, SHOT_DIR .. "/host-guest-returned.png")

    -- ------- 4. hold still so the guest can interact
    --
    -- The guest teleports next to this cell and presses A; the host just
    -- has to be somewhere known and stay there.

    H.signal("host_ready_for_interact")

    -- ------- 4a. ...and answer the friend request that arrives while holding
    --
    -- The other half of the guest's ADD FRIEND leg. This side is standing
    -- still with nothing else on screen, which is exactly the state a friend
    -- ask is meant to be answerable in -- the client holds one until the
    -- player is out of a battle or a trade, and there is neither here.
    H.await(game, "guest_asked_friend")
    local befriended = H.drivePrompts(game, function()
      return #(exports.friends and exports.friends() or {}) == 1
    end, 90)
    check(befriended,
          "the ask arrives as a yes/no box, and agreeing writes the friendship")
    local made = (exports.friends and exports.friends() or {})[1]
    check(made ~= nil and made.name == "GUESTY", "under the asker's own name")
    log("friend made:", tostring(made and made.name))
    U.shot(game, SHOT_DIR .. "/host-friend-made.png")
    H.closeToOverworld(game)
    H.signal("host_answered_friend")
    H.await(game, "guest_friend_checked")

    H.await(game, "guest_interact_done")
    U.shot(game, SHOT_DIR .. "/host-after-interact.png")

    -- ------- 4b. change character mid-session, and the guest watches it land
    --
    -- The MMO menu's CHARACTER row now reaches the hub whether or not this
    -- copy started the game: a pick made here has to push mmo.sprite, and
    -- the guest's roster row and avatar have to follow it without either
    -- side reconnecting (docs/plans/online-char-selection.md). Placed here
    -- rather than earlier or later because both players are settled and
    -- nothing else is mid-flow -- the same reason "hold still" sits where
    -- it does.
    --
    -- The hosting menu carries ten rows now -- ADDRESS, PLAYERS, FRIENDS,
    -- CHAT, SAY, PARTY, MY PROFILE, RANK, CHARACTER, END GAME -- two past
    -- Menu's maxVisible of 8, so it scrolls. H.menuRow reads `items`, which
    -- the widget keeps whole regardless of the scroll offset, so finding END
    -- GAME there is what "still reachable past the scroll" means for a row
    -- this driver deliberately never presses A on -- doing that would open
    -- the END GAME confirm and tear the session down mid-run.
    check(H.openMmo(game), "the MMO menu reopens to change character")
    U.wait(20)
    local hostingLabels = H.menuLabels(game)
    log("hosting menu (connected):", table.concat(hostingLabels, ","))
    check(#hostingLabels == 10, "the hosting menu now carries all ten rows")
    local rankAt, charAt
    for i, label in ipairs(hostingLabels) do
      if label == "RANK" then rankAt = i end
      if label == "CHARACTER" then charAt = i end
    end
    check(rankAt ~= nil and charAt == (rankAt or 0) + 1,
          "CHARACTER sits right after RANK on the hosting menu")
    check(H.menuRow(game, "END GAME") ~= nil,
          "END GAME is still reachable past the first-ever scroll on this menu")
    U.shot(game, SHOT_DIR .. "/host-menu-10rows.png")

    -- NIRE, the same catalog entry mmo_join.lua's offline leg already proves
    -- is selectable, and guaranteed different from MMO_HOST_SPRITE's default
    -- (SPRITE_RED, see run-mmo-e2e.sh) -- so the switch below is provable
    -- rather than assumed.
    local beforeLook = exports.wornLook and exports.wornLook() or nil
    if check(H.selectLabel(game, "CHARACTER"),
             "CHARACTER opens the picker while hosting and connected") then
      U.wait(20)
      check(H.classify(H.top(game)) == "menu", "the picker opened")
      check(H.selectLabel(game, "NIRE"), "NIRE is a row in the connected picker too")
      U.wait(30)
      check(H.classify(H.top(game)) == "menu",
            "picking returns to the MMO menu, not a fresh setup screen")
    end
    H.closeToOverworld(game)

    local wornOk, wornLook = H.wornMatches(game, exports)
    log("host picked live:", tostring(beforeLook), "->", tostring(wornLook))
    check(wornLook ~= beforeLook,
          "the host's own worn look actually changed")
    check(wornOk and wornLook == "SPRITE_NIRE",
          "and it is exactly the character just picked")

    -- Signalled unconditionally: a failed pick above is already reported by
    -- the checks that just ran, and the guest is waiting on this marker
    -- regardless of how this leg went -- staying silent would only turn one
    -- honest failure here into a timeout over there.
    H.signal("host_char_changed")
    H.await(game, "guest_saw_char_change")

    -- ------- 5. a real trade, run to completion over the wire
    --
    -- The guest asks; this side gets "GUESTY wants to trade!", the party
    -- picker, and the confirm. Both sides answer whatever is in front of
    -- them until the party actually changes.

    H.await(game, "guest_trade_requested")
    local wanted = "PIKACHU"
    -- seconds; PHASE.host_trade_done is derived from this number
    local record, prompts = H.promptLog()
    local traded, trail = H.drivePrompts(game, function()
      return H.partySpecies(game)[1] == wanted
    end, 120, record)
    log("host party now:", table.concat(H.partySpecies(game), ","))
    if not traded then
      log("trade stalled -- prompts answered:", trail == "" and "(none)" or trail)
      log("  boxes:", table.concat(prompts, " | "))
    end
    check(traded, "the host received the guest's " .. wanted)
    U.shot(game, SHOT_DIR .. "/host-after-trade.png")
    H.signal("host_trade_done")

    -- ------- 6. a mediated 1v1, run to a decision
    --
    -- PROTOCOL 10: the in-game Hub intermediator owns the rolls; clients
    -- upload parties and draw the event stream. Engine `battle.started` /
    -- `battle.ended` never fire for MediatedBattle, and `link.desync` does
    -- not apply -- wait on `mmoBattle` / `isFighting`, and treat stream gaps
    -- as the desync equivalent.

    H.await(game, "guest_battle_requested")
    local started, btrail = H.drivePrompts(game, function()
      return H.inMediatedFight(game, exports)
    end, 90)
    if not started then
      log("battle never started -- prompts answered:",
          btrail == "" and "(none)" or btrail)
    end
    check(started, "a mediated battle started on the host")

    local inBattle = H.waitFor(game, function()
      return H.isMediatedBattle(H.top(game))
    end, 60 * 20, "the battle screen to come up")
    if inBattle then
      U.wait(90)
      local top = H.top(game)
      log(("mediated: peer=%s phase=%s"):format(
        tostring(top.peerName), tostring(top.phase)))
      U.shot(game, SHOT_DIR .. "/host-battle-open.png")
    end

    local gaps = 0
    local ended = H.drivePrompts(game, function()
      local top = H.top(game)
      if H.isMediatedBattle(top) then
        gaps = tonumber(top.gaps) or gaps
        return false
      end
      return not H.inMediatedFight(game, exports)
    end, 240)
    check(ended, "and ran to a decision")
    check(gaps == 0, "with no gaps in the mediated event stream")
    log(("mediated battle: gaps=%d"):format(gaps))
    U.shot(game, SHOT_DIR .. "/host-after-battle.png")
    H.signal("host_battle_done")

    -- ------- the battle was ranked, so the ranking moved
    --
    -- Both sides report how it ended and the hub scores it only when the two
    -- agree, so this is the one place the whole ranked path -- report, agree,
    -- settle, broadcast -- is exercised against a real battle rather than a
    -- fabricated result.
    H.closeToOverworld(game)
    H.rankAfterBattle(game, exports, check)

    -- ------- 6b. a co-op battle, over the *in-game* hub
    --
    -- **The other transport.** Everything above this point has a twin in
    -- run-hub-e2e.sh, which runs the same features against the dedicated Node
    -- hub. This leg has no twin: a co-op battle had only ever been carried by
    -- server/lib/relay.js. `src/Hub.lua` -- the hub that runs *inside* this
    -- very process when a player hosts from the game -- has co-op handlers
    -- with unit tests and had never relayed one turn of a real 2-on-2 between
    -- two real clients.
    --
    -- The two hubs are written to mirror each other, which is exactly the
    -- reason to check: a mirror is a claim, and the only thing that tests a
    -- claim is running both.

    H.closeToOverworld(game)

    -- A party first: a co-op battle is something a party does, and the LAN
    -- scenario had never formed one at all.
    --
    -- Only once the guest is standing still. It is coming off the RANK screen,
    -- and closeToOverworld gets out of a screen by pressing B -- so an invite
    -- that lands mid-close is answered "no" by the button that was closing
    -- something else, and the party never forms with nothing on screen to say
    -- why.
    H.await(game, "guest_ready_for_party")
    if H.openMmo(game) and H.selectLabel(game, "PLAYERS") then
      U.wait(25)
      if H.selectLabel(game, "GUESTY") then
        U.wait(30)
        check(H.selectLabel(game, "INVITE"), "asked the guest to team up")
      else
        check(false, "found the guest on the PLAYERS list")
      end
    else
      check(false, "opened the PLAYERS list to invite from")
    end
    H.signal("host_party_asked")

    local paired = H.drivePrompts(game, function()
      return #exports.party() == 2
    end, 120)
    check(paired, "the party formed over the in-game hub")
    H.await(game, "guest_party_joined")
    H.closeToOverworld(game)

    -- Sight-trainer walk-in (not stageTrainer): warp onto Route 3's first
    -- Bug Catcher line, show the "!", and the co-op wait starts by itself.
    -- Invite-path syntheticFinish stays covered by the Lua suite; this leg
    -- proves the overworld rematch Quarkst hit after a real engageTrainer.
    --
    -- Round 11: nothing is chosen here any more. Being partied is the consent
    -- (src/Coop.lua's header), so walking into the trainer posts COOP_WAIT.
    -- Round 13 went further and deleted the cover that used to sit in front
    -- of it too -- the wait now runs invisibly behind the engine's own
    -- encounter, and this leg asserts no menu of any kind ever appears.
    local SIGHT_MAP = "ROUTE_3"
    local sightObj = H.sightTrainerOn(game.data, SIGHT_MAP)
    check(sightObj ~= nil, "Route 3 has a sighted trainer with two POKeMON")
    local sightNpcId = H.sightNpcId(SIGHT_MAP, sightObj)
    log("sight trainer:", tostring(sightObj and sightObj.name),
        "npcId", tostring(sightNpcId),
        "class", tostring(sightObj and sightObj.trainerClass))
    H.signal("host_ready_for_sight")
    check(H.warpToSightLine(game, SIGHT_MAP, sightObj, {
          dist = 2, behind = 0, side = 1 }) ~= nil,
          "warped host beside the trainer sight line")
    check(H.awaitOnMap(game, SIGHT_MAP, 90), "host arrived on Route 3")
    H.await(game, "guest_on_sight_map")

    local coopFinished = nil
    -- The real BattleState engageTrainer pushed, held so it can be checked
    -- for gone-from-the-stack rather than merely told-its-result -- see the
    -- comment on the `handed`/onStack pair below for why both matter.
    local staged = nil
    -- **Caught the moment it exists, not once the dust has settled.**
    --
    -- This is the whole of what round 11 changed here, and it is a change to
    -- how the leg *watches* rather than to what it asserts. The staged battle
    -- is found by scanning the stack for a trainer BattleState
    -- (H.captureStagedTrainer), and src/Coop.lua's M:startBattle takes that
    -- state off the stack and holds it privately in `engineBattle` the instant
    -- the co-op screen goes up. So the stack only names it during the window
    -- between the engine pushing it and the partner's join landing -- and with
    -- the WAIT/ALONE ask deleted, nothing holds that window open any more: a
    -- fast auto-join closes it within a frame or two of the trainer
    -- triggering. Capturing after the poll loop below therefore captured
    -- nothing on exactly the runs where the join won the race (the loop's
    -- `joinedFirst` exit), `coopFinished` stayed nil for a handoff that had
    -- already happened, and the onStack check further down passed vacuously
    -- against a nil.
    --
    -- So it is caught from inside every wait between here and the fight, and
    -- latched: the first scan that sees it wraps its onFinish and the rest are
    -- free.
    local function catchStaged()
      if staged then return staged end
      staged = H.captureStagedTrainer(game)
      if staged then
        H.wrapBattleFinish(staged, function(result) coopFinished = result end)
      end
      return staged
    end
    check(H.walkIntoTrainerSight(game, sightObj, { dist = 2 }),
          "host walked into trainer sight")
    check(H.awaitTrainerBang(game, 20), "host saw the trainer ! bubble")
    -- Prefer a frame while the bubble is still up.
    do
      local deadline = os.time() + 3
      while os.time() < deadline do
        local ow = game.overworld
        catchStaged()
        if ow and ow.emote and ow.emote.npc then break end
        U.wait(2)
      end
    end
    catchStaged()
    U.shot(game, SHOT_DIR .. "/host-trainer-sight.png")
    -- Round 13 deleted the cover -- there is no box to land on any more, on
    -- either mode. A run sees whichever the network gave it: nothing at all
    -- (the engine's own pre-battle text, or a blank overworld-shaped wait)
    -- until the four-slot field comes up, silently, the instant the
    -- partner's auto-join lands.
    --
    -- `sawMenu` is the negative half, and it is sampled *inside* the loop
    -- rather than after it because the thing it is looking for would be
    -- transient: a menu that appeared and was answered between two polls is
    -- exactly the regression this leg exists to catch.
    --
    -- The A tap stays gated on `top.items == nil`: it advances the trainer's
    -- pre-battle text and, if the partner is ever slow enough for
    -- SOLO_FALLBACK_AFTER to fire, dismisses that one-line fallback too --
    -- both are plain text boxes now, not a menu with a row to stray onto.
    local sawMenu = false
    local joinedFirst = false
    local joined = H.waitFor(game, function()
      H.softenTopTrainer(game)
      -- Before either exit is read: on the frame the engine's trainer battle
      -- goes up this is the only place looking, and on the frame the join
      -- lands it is already too late (see catchStaged above).
      catchStaged()
      local top = H.top(game)
      if top ~= nil and top.sim ~= nil and #top.sim.slots >= 3 then
        joinedFirst = true
        return true
      end
      if top and top.items ~= nil then sawMenu = true end
      if top and top.items == nil then U.tap(game, "a") end
      return false
    end, 60 * 12, "the field to come up -- no cover stands in front of the trainer")
    check(joined,
          "walking into a real trainer while partied is silent -- the field "
          .. "comes up on its own, standing or already joined")
    check(not sawMenu,
          "and no menu of any kind is ever shown -- forming the party was "
          .. "the yes (src/Coop.lua M:onTrainerBattle)")
    log(("coop wait: joinedFirst=%s sawMenu=%s"):format(
      tostring(joinedFirst), tostring(sawMenu)))
    catchStaged()
    log("staged trainer captured:", tostring(staged ~= nil))
    H.softenTopTrainer(game)
    U.shot(game, SHOT_DIR .. "/host-coop-wait.png")

    -- Marker first, and then a predicate with two halves.
    --
    -- The partner is pulled in automatically (src/Coop.lua's M:autoJoin): they
    -- are already standing on this map with nothing on screen, so COOP_WAIT
    -- goes out, COOP_JOIN comes back, and the wait can be *over* within a
    -- frame or two of the trainer triggering. Polling `coopWaiting() ~= nil`
    -- for sixty seconds therefore reported "this side never stood at the
    -- fight" about a wait that had already been answered -- the opposite of
    -- the truth.
    --
    -- So what is asserted is the claim the wait actually makes: this side ends
    -- up at the fight. Standing at it and already joined are the two ways that
    -- can be true, and which one a run sees is a matter of milliseconds, so
    -- neither may fail it. The marker stays above the poll for the same
    -- reason -- the guest's window opens when COOP_WAIT is sent, not when this
    -- side finishes looking at itself.
    --
    -- 45s is a generous margin, not the clock: round 13's SOLO_FALLBACK_AFTER
    -- releases a wait nobody takes into the solo fight after six seconds, so
    -- both outcomes this leg cares about (still waiting, or already joined)
    -- are long since decided well inside it.
    H.signal("host_coop_waiting")
    local waitSeen, joinSeen = false, false
    local atFight = H.waitSeconds(game, function()
      if exports.coopWaiting() ~= nil then
        waitSeen = true
        return true
      end
      local top = H.top(game)
      if top ~= nil and top.sim ~= nil and #top.sim.slots >= 3 then
        joinSeen = true
        return true
      end
      return false
    end, 45, "this side to be standing at the fight, or already joined")
    log(("after the trigger: waitBox=%s alreadyJoined=%s"):format(
      tostring(waitSeen), tostring(joinSeen)))
    check(atFight,
          "and the automatic wait leaves this side at the fight -- standing "
          .. "at it, or already pulled into it by the partner it waited for")

    -- The guest joins, and four monsters come up on both screens.
    H.await(game, "guest_coop_joined")
    local onField = H.waitSeconds(game, function()
      local top = H.top(game)
      return top ~= nil and top.sim ~= nil and #top.sim.slots == 4
    end, 120, "the 2-on-2 to come up")
    check(onField, "a four-slot co-op battle is on screen, over the LAN hub")
    -- PROTOCOL 10: LAN Host intermediator must referee Party-vs-NPC too.
    local refereed = H.awaitMediatedCoop(game, 60, "coop_npc")
    check(refereed,
          "the LAN 2-on-2 is hub-refereed (coop_npc), not host CoopSim")
    do
      local top = H.top(game)
      log(("mediated coop: id=%s mode=%s medGaps=%s"):format(
        tostring(top and top.battleId), tostring(top and top.mode),
        tostring(top and top.medGaps)))
    end
    if onField then
      -- The command grid, not the opening line. This shot is the shipped
      -- evidence of the 2x2 layout, and a fixed wait was photographing "2 on
      -- 2 battle!" -- see H.awaitCommandMenu for why the box holds that long.
      check(H.awaitCommandMenu(game, "the command menu for the battle shot"),
            "the co-op command grid opens once the opening line is done")
      U.wait(30)
      U.shot(game, SHOT_DIR .. "/host-coop-battle.png")
      check(exports.coopDrawFailed() == false, "and it drew without error")
    end

    local medGaps = 0
    local over = H.drivePrompts(game, function()
      local top = H.top(game)
      return top == nil or top.sim == nil
    end, 300, function()
      local top = H.top(game)
      if H.isMediatedCoop(top) then
        medGaps = tonumber(top.medGaps) or medGaps
      end
      U.tap(game, "a")
    end)
    check(over, "the 2-on-2 runs to an end over the in-game hub")
    local sync = exports.coopSync()
    log(("coop sync: gaps=%d desyncs=%d resyncs=%d medGaps=%d"):format(
      sync.gaps, sync.desyncs, sync.resyncs, medGaps))
    check(sync.gaps == 0, "with no turn lost by the Lua hub")
    check(sync.desyncs == 0, "and no drift between the two copies")
    check(sync.resyncs == 0, "and never needing the field re-sent")
    check(medGaps == 0, "and no gaps in the mediated event stream")

    -- Frames, not seconds, and deliberately so -- this is not a wait on the
    -- guest the way a PHASE barrier is (see "phase barriers" in
    -- mmo_util.lua). CoopBattle:finish pops its own screen; StateStack:pop
    -- removes it and only then calls exit(), which is what reaches
    -- M:onBattleOver and, through M:consume, `engine.onFinish` -- all inside
    -- the one synchronous call that took the co-op screen off the stack. If
    -- `coopFinished` is ever going to be set, it already is by the time
    -- `over` above went true, so a 60-second budget here only meant a
    -- genuinely broken handoff took a minute to report as broken.
    --
    -- The precondition is asserted first and separately, because the two
    -- checks under it are both written against `staged` and both pass
    -- vacuously without one: a leg that never caught the engine's battle is
    -- reporting on its own eyesight, not on the mod, and it should say which.
    check(staged ~= nil,
          "this side's own trainer battle was caught before the co-op screen "
          .. "displaced it (H.captureStagedTrainer, latched per frame)")
    local handed = H.waitFor(game, function()
      return coopFinished ~= nil
    end, 10, "the engine's battle to be finished off")
    check(handed, "and the trainer battle it displaced got its result back")
    log("co-op result:", tostring(coopFinished))

    -- The bug this leg exists to catch, and why `handed` above is not enough
    -- by itself: CoopBattle:finish only ever pops its *own* screen. Before
    -- the fix, the trainer battle staged above was never unwound off the
    -- stack for the player who joined -- it sat there the whole fight,
    -- underneath the co-op screen, one slot down and invisible to a check
    -- that only ever asks what is on top. `coopFinished` could come back
    -- non-nil, a real handoff, while a second, real fight against the same
    -- trainer was still sitting on the stack waiting for input.
    --
    -- Checked here, before the drivePrompts below presses a single button:
    -- that drive answers whatever is on top with A, and a real trainer
    -- battle is itself a sequence of prompts -- FIGHT, a move, a target --
    -- so a leaked one would be fought through in total silence and still end
    -- up back in the overworld. That is exactly how this bug could pass a
    -- check that only looked at the end state.
    check(not H.onStack(game, staged),
          "the trainer battle this side staged is off the stack, not merely "
          .. "buried under the co-op screen")

    H.drivePrompts(game, function()
      local top = H.top(game)
      return top == nil or top == game.overworld or top.isOverworld
    end, 120)
    -- And the overworld that drive reached for is genuinely the overworld --
    -- the other half of the same claim, now that nothing is left buried for
    -- it to be hiding under (checked above, before anything here got a
    -- chance to fight it through).
    local top = H.top(game)
    check(top == game.overworld or (top and top.isOverworld) == true,
          "and the overworld -- not a leaked trainer battle -- is what's "
          .. "actually on top, over the in-game hub too")
    H.closeToOverworld(game)
    H.assertNoRematch(game, sightNpcId, 120, check)
    log("defeatedTrainers[" .. tostring(sightNpcId) .. "]="
        .. tostring(game.save.defeatedTrainers
                    and game.save.defeatedTrainers[sightNpcId]))
    U.shot(game, SHOT_DIR .. "/host-coop-after.png")
    H.signal("host_coop_done")
    H.await(game, "guest_coop_done")

    -- ...and out of the party, so the legs after this one see the world they
    -- expect rather than one this leg left half-arranged.
    if H.openMmo(game) and H.selectLabel(game, "PARTY") then
      U.wait(25)
      H.selectLabel(game, "LEAVE")
      H.drivePrompts(game, function()
        return #exports.party() == 0
      end, 60)
    end
    H.closeToOverworld(game)
    check(#exports.party() == 0, "and the party is left behind cleanly")
    H.signal("host_coop_left")
    if H.openMmo(game) then
      U.wait(25)
      H.shotRank(game, SHOT_DIR .. "/host-rank.png", check)
    end
    H.closeToOverworld(game)

    -- ------- 7. the address stays re-viewable for as long as the game is up
    --
    -- It is read out once when hosting starts and then scrolls away, so the
    -- only thing that matters is being able to get it back.

    H.closeToOverworld(game)
    local address = exports.hostAddress()
    local opened = H.openMmo(game)
    if opened then
      U.wait(25)
      U.shot(game, SHOT_DIR .. "/host-mmo-menu.png")
    end
    if opened and H.selectLabel(game, "ADDRESS") then
      U.wait(30)
      local shown = H.textOf(H.top(game))
      log("address screen reads:", shown)
      check(shown:find(tostring(address), 1, true) ~= nil,
            "the address can be re-viewed from the MMO menu")
      -- and the code with it: they are read out in the same breath, and a
      -- host who set one and cannot find it again has a locked game nobody
      -- can get into. Unconditional -- every hosted game has a code, so a
      -- screen without one on it is a fault rather than a configuration.
      check(joinCode ~= nil and H.codeFrom(shown) == joinCode,
            "and the join code is on the same screen")
      H.shotPrinted(game, SHOT_DIR .. "/host-address-recheck.png")
    else
      check(false, "no ADDRESS row while hosting")
    end
    H.closeToOverworld(game)
    H.signal("host_address_checked")

    -- ------- 8. and the guest leaving is seen here

    H.await(game, "guest_left_game")
    local gone = H.waitSeconds(game, function()
      return #exports.players() == 0
    end, 90, "the guest to drop off the roster")
    check(gone, "a guest who leaves drops off the host's roster")
    check(exports.isHosting(), "and the host is still hosting afterwards")
  end

  -- ------- teardown

  -- Every marker this side owns, dropped whatever happened above -- the same
  -- courtesy the guest does. A leg that gave up otherwise leaves the other
  -- instance sitting on the barriers after it for their full budget, and what
  -- gets reported is a wall of timeouts over there rather than the one real
  -- failure over here.
  for _, tag in ipairs({ "host_party_asked", "host_ready_for_sight",
                         "host_coop_waiting", "host_coop_done", "host_coop_left",
                         "host_wild_waiting", "host_wild_done",
                         "host_address_checked" }) do
    H.signal(tag)
  end

  U.wait(90)
  log("RESULT " .. failures .. " failure(s)")
  log("DONE")
end
