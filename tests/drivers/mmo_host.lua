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
    -- "labels" is the flat 2D projection; "roster" is the corner list used
    -- when another mod owns the world pass.
    local ov = exports.overlayState and exports.overlayState() or {}
    log(("overlay path: %s (derived-letterbox=%s)"):format(
      tostring(ov.reached), tostring(ov.derived or false)))
    check(ov.reached == "labels" or ov.reached == "roster",
          "the overlay drew something for the player on screen")
    U.shot(game, SHOT_DIR .. "/host-guest-moved.png")

    -- ------- 1b. coexistence with a mod that owns the world pass
    --
    -- Only runs when DramaticShapeVoxelMod is installed alongside. Turning
    -- its pipeline on is the only way to see what this mod does when the
    -- overworld is no longer a flat 2D grid -- the nameplates cannot be
    -- projected, so the overlay should fall back to a corner roster rather
    -- than float labels at meaningless positions.
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
      U.shot(game, SHOT_DIR .. "/host-voxel-roster.png")
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
    H.await(game, "guest_interact_done")
    U.shot(game, SHOT_DIR .. "/host-after-interact.png")

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

    -- ------- 6. a real link battle, run to a decision
    --
    -- This is the engine's own LinkBattle -- the lockstep simulation a
    -- cable link runs -- carried over this mod's hub by SessionNet. The
    -- assertions are on engine events rather than on anything this mod
    -- reports, and link.desync is the one that matters: two games
    -- disagreeing mid-battle is exactly what lockstep exists to prevent.

    H.await(game, "guest_battle_requested")
    local started, btrail = H.drivePrompts(game, function()
      return events["battle.started"] > 0
    end, 90)
    if not started then
      log("battle never started -- prompts answered:",
          btrail == "" and "(none)" or btrail)
    end
    check(started, "a link battle started on the host")

    -- What does a link battle actually show? The chosen character is an
    -- overworld sheet; a battle draws trainer *pics*, different assets
    -- entirely. Capture it rather than reason about it -- but wait for the
    -- battle state to be on top first: battle.started fires before the
    -- transition finishes, and a shot taken then is still the overworld.
    --
    -- Frames, and this one genuinely is: a battle transition is a fixed
    -- number of drawn frames on this machine alone. The peer already did its
    -- part -- battle.started has fired -- so nothing here waits on it.
    local inBattle = H.waitFor(game, function()
      local top = H.top(game)
      return top ~= nil and top.enemy ~= nil
    end, 60 * 20, "the battle screen to come up")
    if inBattle then
      U.wait(90)
      local top = H.top(game)
      log(("battle pics: enemyTrainer=%s myBack=%s"):format(
        tostring(top.trainerPic), tostring(top.playerBackPic)))
      U.shot(game, SHOT_DIR .. "/host-battle-open.png")
    end

    local ended = H.drivePrompts(game, function()
      return events["battle.ended"] > 0
    end, 240)
    check(ended, "and ran to a decision")
    check(events["link.desync"] == 0, "with no desync reported")
    log(("battle events: started=%d ended=%d desync=%d"):format(
      events["battle.started"], events["battle.ended"], events["link.desync"]))
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
    local coopClass, coopLevel = H.coopTrainer(game.data)
    check(coopClass ~= nil, "the dataset has a trainer with two POKeMON")
    log("co-op trainer:", tostring(coopClass), "total level", tostring(coopLevel))

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

    -- Walk into the trainer, and wait rather than fight alone.
    local coopFinished = nil
    -- The real BattleState this side staged, held onto (not just the result
    -- callback above) so it can be checked for gone-from-the-stack rather
    -- than merely told-its-result once the co-op leg is over -- see the
    -- comment on the `handed`/onStack pair below for why both matter.
    local staged = nil
    if coopClass then
      staged = H.stageTrainer(game, coopClass, function(result) coopFinished = result end)
      local asked = H.waitFor(game, function()
        for _, label in ipairs(H.menuLabels(game)) do
          if label == "WAIT" then return true end
        end
        local top = H.top(game)
        if top and top.items == nil then U.tap(game, "a") end
        return false
      end, 60 * 6, "the co-op prompt in front of the trainer")
      check(asked, "the co-op prompt appears in front of a real trainer battle")
      U.shot(game, SHOT_DIR .. "/host-coop-prompt.png")
      check(H.selectLabel(game, "WAIT"), "chose to wait for the party member")
      local waiting = H.waitSeconds(game, function()
        return exports.coopWaiting() ~= nil
      end, 60, "this side to be standing at the fight")
      check(waiting, "and this side is standing at the fight, waiting")
    end
    H.signal("host_coop_waiting")

    -- The guest joins, and four monsters come up on both screens.
    H.await(game, "guest_coop_joined")
    local onField = H.waitSeconds(game, function()
      local top = H.top(game)
      return top ~= nil and top.sim ~= nil and #top.sim.slots == 4
    end, 120, "the 2-on-2 to come up")
    check(onField, "a four-slot co-op battle is on screen, over the LAN hub")
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

    local over = H.drivePrompts(game, function()
      local top = H.top(game)
      return top == nil or top.sim == nil
    end, 300, function() U.tap(game, "a") end)
    check(over, "the 2-on-2 runs to an end over the in-game hub")
    local sync = exports.coopSync()
    log(("coop sync: gaps=%d desyncs=%d resyncs=%d"):format(
      sync.gaps, sync.desyncs, sync.resyncs))
    check(sync.gaps == 0, "with no turn lost by the Lua hub")
    check(sync.desyncs == 0, "and no drift between the two copies")
    check(sync.resyncs == 0, "and never needing the field re-sent")

    -- Frames, not seconds, and deliberately so -- this is not a wait on the
    -- guest the way a PHASE barrier is (see "phase barriers" in
    -- mmo_util.lua). CoopBattle:finish pops its own screen; StateStack:pop
    -- removes it and only then calls exit(), which is what reaches
    -- M:onBattleOver and, through M:consume, `engine.onFinish` -- all inside
    -- the one synchronous call that took the co-op screen off the stack. If
    -- `coopFinished` is ever going to be set, it already is by the time
    -- `over` above went true, so a 60-second budget here only meant a
    -- genuinely broken handoff took a minute to report as broken.
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
  for _, tag in ipairs({ "host_party_asked", "host_coop_waiting",
                         "host_coop_done", "host_coop_left",
                         "host_address_checked" }) do
    H.signal(tag)
  end

  U.wait(90)
  log("RESULT " .. failures .. " failure(s)")
  log("DONE")
end
