-- Driver: a guest on a dedicated hub. Two of these, and nothing else.
--
-- Pair with a second instance of *this same file* under MMO_ROLE=b, launched
-- by tests/drivers/run-hub-e2e.sh, which starts server/bin/rby-mmo-hub.js
-- first and points both instances at it.
--
-- This is the scenario tests/drivers/run-mmo-e2e.sh cannot reach, because
-- that one always has an in-game host: here **neither instance hosts**. The
-- hub is a Node process, and everything the two games say to each other --
-- presence, chat, a trade, a lockstep battle -- is relayed by software
-- written in another language that no LOVE client had ever spoken to before
-- this file existed.
--
-- The single most valuable assertion below is the join code. src/Sha256.lua
-- is pinned against fixtures generated from Node and server/lib/auth.js is
-- pinned against node:crypto, so both ends agree on the *arithmetic* -- but
-- until a real client answered a real hub's real challenge, nothing proved
-- they agreed on the *wiring*: which field carries the nonce, whether the
-- client normalises before hashing, whether the hub's nonce shape is what
-- Wire.hex accepts. Get any of that wrong and every player on a dedicated
-- hub sees "wrong join code" while every unit test stays green. So one side
-- gets it wrong on purpose first, and then right.
--
-- One driver, parameterised by role, because neither instance is special.
-- The roles differ only in who asks for what:
--
--   a  ALPHA, CHARIZARD, walks, asks for the TRADE, leaves first
--   b  BETA,  PIKACHU,   watches the walk, asks for the BATTLE, leaves second
--
-- Trade and battle are asked for from opposite sides on purpose: the hub
-- makes the *requester* the session host for the RNG seed
-- (server/lib/relay.js:518-535), so one of each runs on each instance.
--
--   MMO_ROLE=a POKEPORT_IDENTITY=mmohub-a \
--     POKEPORT_DRIVER=mods/rby_mmo/tests/drivers/mmo_guest.lua love .

-- Muted at load rather than in mmo_util, which is only reached once the game
-- is ready -- by then the title music is already playing. Nothing here ever
-- asserts on a sound, and two instances playing a battle at each other for
-- minutes is not something a background run should do to a room.
if os.getenv("MMO_SOUND") ~= "1" and love and love.audio then
  love.audio.setVolume(0)
end

-- Who this instance is. Everything role-shaped is decided here and read as
-- data below, so the two halves of a run cannot disagree about which of them
-- is expected to do what.
local ROLES = {
  a = { name = "ALPHA", species = "CHARIZARD", level = 50 },
  b = { name = "BETA",  species = "PIKACHU",   level = 30 },
}

local ROLE = tostring(os.getenv("MMO_ROLE") or "a"):lower()
if not ROLES[ROLE] then ROLE = "a" end
local PEER = (ROLE == "a") and "b" or "a"

return function(game)
  local H = dofile("mods/rby_mmo/tests/drivers/mmo_util.lua")
  local U = H.U
  local TAG = "MMO_GUEST_" .. ROLE:upper() .. ":"
  local ME, THEM = ROLES[ROLE], ROLES[PEER]
  local SHOT_DIR = os.getenv("SHOT_DIR") or "/tmp/rby_mmo_hub_shots"
  local HUB_ADDRESS = os.getenv("MMO_JOIN_ADDRESS") or "127.0.0.1:7788"
  -- The passcode as the hub's own CLI printed it -- six characters, the form
  -- a host reads out to a friend. Nothing here reaches into the mod for it.
  local RAW_CODE = os.getenv("MMO_HUB_CODE") or ""
  local PEER_SPRITE = os.getenv("MMO_PEER_SPRITE")

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

  local function shot(name)
    U.shot(game, ("%s/hub-%s-%s.png"):format(SHOT_DIR, ROLE, name))
  end

  -- ------- meeting the other instance
  --
  -- Symmetric drivers, so every barrier comes in an a/b pair: signal mine,
  -- wait for theirs. Patience lives in mmo_util's PHASE table next to the
  -- work it was derived from -- see the rule above "phase barriers" there,
  -- and never spell a budget at a call site.
  local function marker(side, tag) return ("hub_%s_%s"):format(side, tag) end

  local function rendezvous(tag)
    H.signal(marker(ROLE, tag))
    return H.await(game, marker(PEER, tag))
  end

  -- Give up in a way that lets the other side give up too.
  --
  -- A driver that dies quietly leaves its partner sitting on every remaining
  -- barrier for the full budget, and what gets reported then is a cascade of
  -- timeouts on the healthy instance rather than the one real failure over
  -- here. Dropping every marker this side owns lets the peer walk its own
  -- assertions and fail honestly, in seconds.
  local function abandon()
    for _, tag in ipairs({ "ready", "walk", "chat", "party", "partyleft",
                           "trade", "battle", "left" }) do
      H.signal(marker(ROLE, tag))
    end
    if ROLE == "a" then
      H.signal("hub_a_walk_start")
      H.signal("hub_a_walk_done")
      H.signal("hub_a_party_asked")
      H.signal("hub_a_trade_asked")
    else
      H.signal("hub_b_baseline")
      H.signal("hub_b_battle_asked")
    end
  end

  local function bail(extra)
    abandon()
    log("RESULT " .. (failures + (extra or 0)) .. " failure(s)")
  end

  -- ------- a fresh game, with something to trade

  U.newGame(game)
  -- U.newGame mashes A through the naming grid, so both sides would
  -- otherwise be called AAAAAAA and no roster assertion could tell them
  -- apart. Name them here instead.
  if game.save and game.save.player then
    game.save.player.name = ME.name
  end
  -- Distinct species per side is what makes "the trade happened" checkable
  -- rather than a matter of faith -- and, after the trade, what makes a
  -- duplicate visible from either seat.
  local Pokemon = require("src.pokemon.Pokemon")
  game.save.party = { Pokemon.new(game.data, ME.species, ME.level) }
  -- so the driven battle actually resolves; see frontloadDamage
  local lead = H.frontloadDamage(game.data, game.save.party[1])
  log("in the overworld as", ME.name, "with",
      table.concat(H.partySpecies(game), ","), "leading with", tostring(lead))

  local exports = H.requireMod(game, TAG)
  if not exports then
    bail(1)
    return
  end
  if exports.traceAvatars then exports.traceAvatars(true) end
  check(exports.isConnected() == false, "starts disconnected")
  check(exports.isHosting() == false, "starts not hosting")

  local code = H.codeFrom(RAW_CODE)
  check(code ~= nil, "the hub's CLI handed out a code this game can read")
  if not code then
    log("MMO_HUB_CODE was", '"' .. RAW_CODE .. '"')
    bail()
    return
  end
  log("dialling", HUB_ADDRESS, "with the hub's code")

  -- ------- join, through the real menus
  --
  -- Exactly the path a player takes: START > MMO > JOIN GAME, character
  -- creation, then the address screen. No HOST GAME anywhere in this file.

  if not H.openMmo(game) then
    log("FAIL could not reach the MMO menu")
    bail(1)
    return
  end
  check(true, "the MMO row exists on the START menu")

  if not H.selectLabel(game, "JOIN GAME") then
    log("FAIL no JOIN GAME row")
    bail(1)
    return
  end

  U.wait(20)
  check(H.classify(H.top(game)) == "menu", "character creation opened")
  check(H.selectLabel(game, "JOIN"), "confirmed the trainer and moved on")

  -- The naming screen carries the saved address -- which the wrapper wrote
  -- into this instance's options.lua -- as its `default`, and START submits
  -- that when nothing has been typed. `default`, not `glyphs`: the grid opens
  -- empty (NamingScreen uses the default as the *answer*, not as prefilled
  -- text), so reading the glyphs says nothing about where this run is about
  -- to dial. Asserting the default is what proves it is the Node hub and not
  -- the mod's built-in 127.0.0.1:7788, which is the port an in-game host
  -- binds -- a run that quietly joined a leftover LAN window would otherwise
  -- pass while testing the wrong thing entirely.
  --
  -- Identified by title, not merely by "a grid is up": the code screen is
  -- also a naming screen and is now one keypress away, so the two have to be
  -- told apart or a run could submit its address on the wrong one.
  U.wait(20)
  local naming = H.addressGrid(game)
  if naming then
    log("address screen: typed", '"' .. table.concat(naming.glyphs) .. '"',
        "default", '"' .. tostring(naming.default) .. '"')
    check(naming.default == HUB_ADDRESS,
          "the address screen will submit the dedicated hub's address")
  else
    log("WARN the top state is not the address screen:",
        tostring(H.top(game) and (H.top(game).title or "?")))
    check(false, "the address screen opened")
  end
  shot("address")
  U.tap(game, "start")
  U.wait(60)

  -- ------- the cross-language handshake
  --
  -- The hub is Node; this is Lua. It sends a nonce, this side answers
  -- HMAC-SHA256(joinCode, nonce) with the nonce as its lowercase-hex
  -- *string*, and neither half of that contract has ever been checked
  -- against the other half in a running game before this file.
  --
  -- The code is typed before the socket opens: JOIN GAME asks for the
  -- address and then the passcode, and only then dials. So this first wait
  -- is in FRAMES and not seconds -- the grid is pushed by the address
  -- screen's own onDone, inside this process, with nothing yet on the wire.
  -- What is still measured in seconds, and must be, is the hub's answer to
  -- what gets sent: the refusal below, and the connection after it.

  local asked = H.waitFor(game, function()
    return H.codeGrid(game) ~= nil
  end, 240, "the join-code grid")
  check(asked, "the address screen hands straight over to the code grid")
  check(exports.isConnected() == false,
        "and nothing is dialled until the code is answered")
  shot("code-asked")

  -- The wrong code first, on one side, because the refusal path is where a
  -- player ends up when they mistype -- and because a refusal proves the hub
  -- is really checking rather than waving everybody through. Role b skips it
  -- so the run also covers the straight-in case.
  if ROLE == "a" then
    local wrong = H.wrongCode(code)
    check(H.enterJoinCode(game, wrong), "a wrong code can be typed on the grid")
    local refused = H.waitSeconds(game, function()
      local top = H.top(game)
      return top ~= nil and H.textOf(top):find("not accepted", 1, true) ~= nil
    end, 90, "the hub's refusal")
    check(refused,
          "a wrong join code is refused by the Node hub, in words the game shows")
    check(exports.isConnected() == false, "and leaves us outside")
    -- printed rather than merely open: what makes this capture worth having
    -- is the Node hub's own sentence, and a frame taken as the box opens
    -- carries three words of it (see H.printed)
    H.awaitPrinted(game)
    shot("code-refused")
  end

  check(H.enterJoinCode(game, code), "the hub's own code can be typed on the grid")
  U.wait(60)

  local connected = H.waitSeconds(game, function() return exports.isConnected() end,
                                  90, "the connection to open")
  check(connected,
        "the Lua client's answer satisfied the Node hub's challenge")
  if not connected then
    -- Transport puts a player-facing sentence in the box on failure, so the
    -- screenshot is the diagnosis: a refused code, a bad address, or a
    -- naming screen that never confirmed at all
    shot("join-FAILED")
    log("top state after the attempt:",
        tostring(H.top(game) and (H.top(game).title or "?")))
    bail()
    return
  end

  -- The point of the whole scenario, stated as plainly as it can be.
  check(exports.isHosting() == false, "and this copy is not hosting")
  local published = exports.hostAddress and exports.hostAddress() or nil
  check(not published, "so it publishes no address of its own")

  H.closeToOverworld(game)
  check(rendezvous("ready"), "the other guest reached the hub too")

  -- ------- both of us are on it, and only us

  local sawPeer = H.waitSeconds(game, function()
    return #exports.players() > 0
  end, 90, "the other guest to appear on the roster")
  check(sawPeer, "the other guest appears on this side's roster")

  local peer = exports.players()[1]
  if peer then
    log("peer is", tostring(peer.name), "sprite", tostring(peer.sprite),
        "on", tostring(peer.map))
    check(peer.name == THEM.name, "under the name they chose")
    if PEER_SPRITE and PEER_SPRITE ~= "" then
      check(peer.sprite == PEER_SPRITE,
            "wearing the character they chose (" .. PEER_SPRITE .. ")")
    end
    -- Neither of us is also a server, so the hub holds exactly two clients
    -- and each of us sees exactly one other. A host's own loopback client
    -- would show up here as a third.
    check(#exports.players() == 1, "and is the only other player on the hub")
    local row = H.avatarRow(exports)
    check(row ~= nil and row.spawned,
          "their avatar spawned (the catalog accepted the sprite id)")
  end
  U.wait(60)
  shot("roster")

  -- ------- movement, one way
  --
  -- Only the watching side can judge this, so a walks between two markers
  -- and b asserts what it saw. a waits for b's baseline before moving:
  -- signalling and walking immediately races it, and b would then sample
  -- after the walk and wait forever for a change that already happened.

  if ROLE == "a" then
    H.signal("hub_a_walk_start")
    H.await(game, "hub_b_baseline")
    local wasAt = H.playerCell(game)
    -- left/right rather than down: Red's bedroom is small and a few tiles
    -- south runs into furniture, which would make "nobody moved" a
    -- map-geometry result rather than a networking one
    for _ = 1, 2 do
      U.hold(game, "left", 22)
      U.wait(8)
    end
    U.hold(game, "right", 22)
    U.wait(8)
    local nowAt = H.playerCell(game)
    log(("walked (%s,%s) -> (%s,%s)"):format(
      tostring(wasAt and wasAt.x), tostring(wasAt and wasAt.y),
      tostring(nowAt and nowAt.x), tostring(nowAt and nowAt.y)))
    check(nowAt and wasAt and (nowAt.x ~= wasAt.x or nowAt.y ~= wasAt.y),
          "this side's own player actually moved")
    H.signal("hub_a_walk_done")
  else
    H.await(game, "hub_a_walk_start")
    local before = H.avatarRow(exports)
    local fromX, fromY = before and before.rosterX, before and before.rosterY
    log(("peer baseline (%s,%s)"):format(tostring(fromX), tostring(fromY)))
    H.signal("hub_b_baseline")
    H.await(game, "hub_a_walk_done")

    local moved = H.waitSeconds(game, function()
      local row = H.avatarRow(exports)
      return row and (row.rosterX ~= fromX or row.rosterY ~= fromY)
    end, 60, "the other guest to move on this side")
    check(moved, "one guest's movement reaches the other through the Node hub")

    -- The roster moving proves the wire works. Whether the *avatar* moved is
    -- a separate question, and the one a screenshot answers badly -- so read
    -- both and compare.
    local followed = H.waitSeconds(game, function()
      local row = H.avatarRow(exports)
      return row and row.spawned
        and math.abs((row.avatarX or -99) - row.rosterX) < 0.01
        and math.abs((row.avatarY or -99) - row.rosterY) < 0.01
    end, 60, "their avatar to catch up")
    check(followed, "and their avatar walks to where the hub says they are")
    shot("peer-walked")
  end
  check(rendezvous("walk"), "both guests finished the movement leg")

  -- ------- chat, in two scopes
  --
  -- Both scopes in ONE loop, both lines repeated until both of theirs have
  -- been heard. Two separate say-and-wait loops read better and were wrong
  -- twice over, and the first run of this file found both faults at once:
  --
  --   * a loop that checks before it sends can satisfy itself on a line that
  --     arrived while the previous phase was still winding down, and return
  --     without ever having said anything -- leaving the peer waiting 120s
  --     for a line nobody sent;
  --   * and the side that hears first advances to the next scope, stopping
  --     the repeat of the line the other side is still waiting for. Neither
  --     shows up as "chat is broken"; both show up as one instance timing
  --     out while the other passes, which reads like a transport fault.
  --
  -- A line is fan-out, not delivery: the hub forwards it to whoever is ready
  -- at that instant and never retries, and `local` additionally needs the
  -- listener to have a cell on the hub -- which a player standing in a menu
  -- does not. So repeating is not belt-and-braces here, it is the mechanism.
  --
  -- The two scopes alternate rather than going out together: the hub drops a
  -- second message from the same client inside limits.chatIntervalMs (500ms
  -- by default), silently, so a back-to-back pair would always lose one half.
  -- One line per turn, turns 3 seconds apart, is comfortably clear of it
  -- without needing sub-second timing in a frame-stepped driver.

  local function chatBothScopes(seconds)
    local turns = {
      { scope = "global", mine = "HELLO FROM " .. ME.name,
        theirs = "HELLO FROM " .. THEM.name, heard = false },
      { scope = "local",  mine = "NEARBY " .. ME.name,
        theirs = "NEARBY " .. THEM.name,     heard = false },
    }
    local deadline = os.time() + seconds
    local turn, last = 1, -99
    while os.time() < deadline do
      if os.time() - last >= 3 then
        exports.say(turns[turn].scope, turns[turn].mine)
        last, turn = os.time(), 3 - turn
      end
      for _, line in ipairs(exports.chat()) do
        for _, want in ipairs(turns) do
          if line.text == want.theirs then want.heard = true end
        end
      end
      if turns[1].heard and turns[2].heard then break end
      U.wait(6)
    end
    for _, want in ipairs(turns) do
      if not want.heard then
        U.log(("TIMEOUT waiting %ds for the other guest's %s line")
          :format(seconds, want.scope))
      end
    end
    return turns[1].heard, turns[2].heard
  end

  H.closeToOverworld(game)
  local heardGlobal, heardLocal = chatBothScopes(150)
  check(heardGlobal, "global chat crosses the hub between two guests")
  check(heardLocal, "and so does nearby chat, which the hub scopes by map and distance")
  shot("chat")
  check(rendezvous("chat"), "both guests finished the chat leg")

  -- Two legs landed here in the same merge, both reached from the end of
  -- the chat leg, and both are kept: MY PROFILE reads nothing but the local
  -- save and pairs with nobody, so it runs first and unpaired; the party
  -- leg below is the one with barriers in it.

  -- ------- your own card
  --
  -- Both roles walk this: it reads nothing but the local save, so there is
  -- no barrier to pair and no reason for only one side to prove it. The
  -- assertion that matters is `money` -- Wire.profile refuses to carry it,
  -- so a card holding one cannot have come off the wire, which is what
  -- makes this the local player's card and not a peer's.

  H.closeToOverworld(game)
  if check(H.openMmo(game), "the MMO menu opens for MY PROFILE") then
    if H.selectLabel(game, "MY PROFILE") then
      U.wait(40)
      local mine = H.top(game)
      check(mine ~= nil and mine.player ~= nil, "MY PROFILE opened a card")
      if mine and mine.player then
        log("own card", tostring(mine.player.name),
            "look", tostring(mine.player.sprite),
            "money", tostring(mine.player.money))
        check(mine.player.name == ME.name, "showing this guest's own trainer")
        check(mine.player.money ~= nil,
              "with the money row only your own card carries")
        check(mine.player.profile ~= nil,
              "and the same fields the peers were sent")
        -- Deliberately only a presence check, and named as one. Each run
        -- gets its own LOVE identity (mmohub-a-$$), so the save is always
        -- minutes old and TIME reads 0:00 -- which the *old* save.playtime
        -- bug produced too. Nothing here can tell them apart; the value
        -- itself is pinned headless against a save with a real playTime.
        check(mine.player.profile and type(mine.player.profile.playtime) == "number",
              "playtime is a number on it (its value is pinned headless)")
      end
      shot("my-profile")
      U.tap(game, "b")
      U.wait(30)
      check(H.classify(H.top(game)) == "menu", "and B returns to the MMO menu")
    else
      check(false, "no MY PROFILE row on the MMO menu while connected")
    end
  end


  -- ------- a party, formed and then left
  --
  -- The half of parties the headless suite structurally cannot reach. That
  -- suite pins the protocol with fake peers on both sides; what it never
  -- does is open the real ACTIONS menu and find out whether INVITE is on it,
  -- whether the box that appears says the right thing, or whether the party
  -- screens the mod registers actually build. Every one of those is a
  -- registration or a menu-geometry question, and every one of them fails
  -- silently -- the party still forms, the player just cannot reach it.
  --
  -- Run before the trade on purpose: the last assertion here is that being
  -- in a party does not stop the two of them trading, and the trade leg
  -- immediately below is what proves it.

  H.closeToOverworld(game)
  if ROLE == "a" then
    check(H.openMmo(game), "the MMO menu opens before inviting")
    U.wait(25)
    check(H.menuRow(game, "PARTY") ~= nil,
          "the MMO menu carries a PARTY row while connected")
    if H.selectLabel(game, "PLAYERS") then
      U.wait(25)
      check(H.selectLabel(game, THEM.name), "the other guest is on the PLAYERS list")
      U.wait(30)
      local labels = H.menuLabels(game)
      log("actions menu:", table.concat(labels, ","))
      local hasInvite = false
      for _, label in ipairs(labels) do
        if label == "INVITE" then hasInvite = true end
      end
      check(hasInvite, "INVITE is offered against a player who is unattached")
      shot("invite-menu")
      check(H.selectLabel(game, "INVITE"), "asked the other guest to team up")
    else
      check(false, "no PLAYERS row to invite from")
    end
    H.signal("hub_a_party_asked")
  else
    H.await(game, "hub_a_party_asked")
  end

  -- b answers the box; a is already past its own "Asked BETA to team up."
  -- text box. drivePrompts answers a choice with YES, which is what the
  -- invited side is being asked, and taps through a's text box on the other.
  local inParty = H.drivePrompts(game, function()
    return #exports.party() == 2
  end, 90)
  check(inParty, "the party formed on this side")
  local members = {}
  for _, member in ipairs(exports.party()) do
    members[#members + 1] = tostring(member.name)
  end
  log("party members:", table.concat(members, ","))
  check(#members == 2, "with exactly two members")
  local sawPartner = false
  for _, name in ipairs(members) do
    if name == THEM.name then sawPartner = true end
  end
  check(sawPartner, "the other guest among them")

  -- Their presence now says so, which is what gates everyone else's INVITE
  -- row -- and the roster screen's PARTY column, and the map marker.
  local flagged = H.waitSeconds(game, function()
    local peerRow = exports.players()[1]
    return peerRow ~= nil and peerRow.party == true
  end, 60, "the party flag to reach this side's roster")
  check(flagged, "the other guest's presence carries the party flag")

  -- ------- your party member, on the actual map
  --
  -- What a party looks like in the world: their character standing there,
  -- with the nickname they chose over its head. Nothing decorative -- being
  -- in a party is said by PLAYERS and the PARTY screen, not by the plate.
  --
  -- Nothing headless can make this assertion. The mod's own suite stubs the
  -- world entirely: no avatar is ever spawned and no frame is ever drawn, so
  -- "their character is there, named" is only answerable by a real client
  -- looking at a real frame. Both guests have been standing in the same room
  -- since the walk leg, so the avatar is on screen and its plate is being
  -- drawn every frame.

  H.closeToOverworld(game)

  -- Their character, spawned as a real overworld NPC at the cell the network
  -- says they are on -- the half a nameplate cannot tell you about.
  local row = H.avatarRow(exports, THEM.name)
  check(row ~= nil and row.spawned,
        "the party member's character is on the map as a real NPC")
  if row then
    log(("their avatar: map=%s roster=(%s,%s) avatar=(%s,%s)"):format(
      tostring(row.map), tostring(row.rosterX), tostring(row.rosterY),
      tostring(row.avatarX), tostring(row.avatarY)))
    check(row.avatarX == row.rosterX and row.avatarY == row.rosterY,
          "standing where the network says they are")
  end

  -- ...and the plate over it, carrying the party marker so they can be told
  -- apart from anyone else standing on the same map. exports.overlayState()
  -- reports what the last frame actually committed, so this reads the real
  -- text off a real frame rather than inferring it from a screenshot.
  -- The marker as the renderer spells it: U+25B6, three bytes. Written as
  -- escapes rather than pasted so this file stays plain ASCII and cannot be
  -- broken by an editor that re-encodes it.
  local MARKED = "\226\150\182" .. THEM.name
  local named, drew = false, {}
  local nameDeadline = os.time() + 60
  while os.time() < nameDeadline and not named do
    local ov = exports.overlayState and exports.overlayState() or {}
    drew = ov.names or {}
    for _, name in ipairs(drew) do
      if name == MARKED then named = true end
    end
    if not named then U.wait(6) end
  end
  log("nameplates drawn:", #drew == 0 and "(none)" or table.concat(drew, ","))
  check(named, "their nickname is drawn over their head, marked as party")

  -- ...and it is a marker, not an extra label: the plain plate is replaced,
  -- not accompanied.
  local plainToo = false
  for _, name in ipairs(drew) do
    if name == THEM.name then plainToo = true end
  end
  check(not plainToo, "replacing the unmarked plate rather than adding to it")

  -- Every glyph of it is one the font can actually draw.
  --
  -- Not paranoia: this leg first shipped with a `*` marker on the plate, and
  -- **the font has no asterisk**. Font.draw draws nothing for a character it
  -- cannot map while Font.width still advances eight pixels for it, so the
  -- plate came out a glyph too wide with a blank hole in it -- and the
  -- string check above passed the whole time, because the overlay had
  -- honestly *requested* text it could not render. The marker is gone; the
  -- trap is not, and it belongs to anything that ever reaches a plate.
  local unpaintable = {}
  for _, plate in ipairs(drew) do
    -- H.undrawable answers with a comma-joined string, "" when every glyph
    -- renders -- the shape main's copy of this helper published, and the one
    -- the merge settled on for both.
    local missing = H.undrawable(game, plate)
    if missing ~= "" then unpaintable[#unpaintable + 1] = missing end
  end
  check(#unpaintable == 0, "every glyph the overlay drew is one the font has"
    .. (#unpaintable > 0
        and (" -- missing: " .. table.concat(unpaintable, " ")) or ""))

  -- Let the chat leg's last bubble expire before the shot.
  --
  -- Two things at once. The screenshot is a README image, and a bubble left
  -- over from a previous leg floating above the nameplate makes it look like
  -- the name is something the player said. And waiting for it is an
  -- assertion in its own right: Config.BUBBLE_SECONDS is 5, so a plate that
  -- has not settled to the name alone well past that is a bubble that never
  -- expired -- which would be a leak nothing else here would notice.
  local settled, lastSeen = false, drew
  local settleDeadline = os.time() + 20
  while os.time() < settleDeadline and not settled do
    local ov = exports.overlayState and exports.overlayState() or {}
    lastSeen = ov.names or {}
    settled = #lastSeen == 1 and lastSeen[1] == MARKED
    if not settled then U.wait(12) end
  end
  check(settled, "the plate settles to the marked name alone -- old bubbles "
    .. "expire (saw: "
    .. (#lastSeen == 0 and "(none)" or table.concat(lastSeen, ",")) .. ")")
  shot("party-map")

  -- ------- your party member on the TOWN MAP
  --
  -- The full Kanto map, with your friend's character standing at the city
  -- they are actually in and their nickname over it. The overworld can only
  -- ever show the room you are in; this is the screen that answers "where
  -- are they".
  --
  -- Pushed directly rather than opened from the bag, because the driver's
  -- fresh save has no TOWN MAP item and buying one is a different test. How
  -- the screen got opened is the engine's business; what this leg is about
  -- is what the mod draws once it is.
  --
  -- Both guests are in Red's bedroom, so both resolve to PALLET TOWN -- the
  -- screen's own index points an interior at its town's square, which is
  -- exactly the case worth seeing drawn.

  H.closeToOverworld(game)
  local okTown, TownMapUi = pcall(require, "src.ui.TownMap")
  if okTown and TownMapUi and TownMapUi.new then
    local built, screen = pcall(TownMapUi.new, game, {})
    if built and screen then
      game.stack:push(screen)
      U.wait(30)
      local ov = exports.overlayState and exports.overlayState() or {}
      log(("town map: reached=%s drawn=%s names=%s"):format(
        tostring(ov.reached), tostring(ov.drawn),
        (ov.names and #ov.names > 0) and table.concat(ov.names, ",") or "(none)"))
      check(ov.reached == "townmap",
            "the overlay recognises the TOWN MAP and draws on it")
      check((ov.drawn or 0) >= 1,
            "your party member is placed on it")
      local namedThere = false
      for _, name in ipairs(ov.names or {}) do
        if name == THEM.name then namedThere = true end
      end
      check(namedThere, "with their nickname over their character")
      shot("party-townmap")
      U.tap(game, "b")
      U.wait(25)
      H.closeToOverworld(game)
    else
      check(false, "could not build a TOWN MAP to draw on")
    end
  else
    check(false, "the engine's TOWN MAP screen could not be reached")
  end

  -- The screens the PARTY row leads to actually build. A screen that failed
  -- to register throws on push and takes the frame with it, so reaching the
  -- members list at all is most of the assertion.
  H.closeToOverworld(game)
  check(H.openMmo(game), "the MMO menu re-opens")
  if H.selectLabel(game, "PARTY") then
    U.wait(25)
    check(H.selectLabel(game, "MEMBERS"), "the party menu opens the members list")
    U.wait(30)
    local rows = H.menuLabels(game)
    log("members screen:", table.concat(rows, ","))
    check(#rows == 2, "which lists both of you")
    shot("party-members")
    U.tap(game, "b")
    U.wait(25)
  else
    check(false, "no PARTY row to open once in a party")
  end
  H.closeToOverworld(game)
  -- Synced here rather than the moment the party formed: the exchange below
  -- is two sides shouting at each other for a bounded window, and a side
  -- that started 60 seconds ahead of its partner would spend most of that
  -- window talking to somebody still walking a menu.
  check(rendezvous("party"), "both guests are in the party")

  -- Party chat: no radius, no name to type, and it reaches them wherever
  -- they are. Both sides say their line and wait to hear the other's, the
  -- way the chat leg above does -- a one-sided assertion cannot tell "sent"
  -- from "delivered".
  -- Repeated until heard, for the same reason the chat leg above repeats: a
  -- line is fan-out and never retried, so the side that gets there first
  -- would otherwise stop saying the line the other is still waiting on.
  local mine, theirs = "PARTY " .. ME.name, "PARTY " .. THEM.name
  local heardParty = false
  local partyDeadline, lastSaid = os.time() + 90, -99
  while os.time() < partyDeadline and not heardParty do
    if os.time() - lastSaid >= 3 then
      exports.say("party", mine)
      lastSaid = os.time()
    end
    for _, line in ipairs(exports.chat()) do
      if line.text == theirs and line.scope == "party" then heardParty = true end
    end
    U.wait(6)
  end
  check(heardParty, "a party line from the other guest arrived, tagged party")

  -- ...and being in one does not stop them trading, which the leg below is
  -- about to demonstrate for real.
  check(#exports.party() == 2, "the party survives everything above it")

  -- ------- a real trade, run to completion
  --
  -- Reached from START > MMO > PLAYERS rather than by walking up and
  -- pressing A. Both are real routes to the same screen; this one does not
  -- need the two players to be standing on adjacent cells, which in a
  -- symmetric scenario is a whole race that buys nothing.
  --
  -- Everything past the request is the engine's own Protocol.TradeSession,
  -- driven over SessionNet, relayed by Node. Nothing about the trade itself
  -- is this mod's code.

  H.closeToOverworld(game)
  if ROLE == "a" then
    check(H.openMmo(game), "the MMO menu opens while connected")
    if H.selectLabel(game, "PLAYERS") then
      U.wait(25)
      check(H.selectLabel(game, THEM.name), "the other guest is on the PLAYERS list")
      U.wait(30)

      local top = H.top(game)
      local labels = {}
      for _, item in ipairs((top and top.items) or {}) do
        labels[#labels + 1] = tostring(item.label)
      end
      log("actions menu:", table.concat(labels, ","))
      check(#labels > 0, "picking them opens the actions menu")
      shot("actions")

      -- The card: their name and the trainer stats they sent on joining.
      if H.selectLabel(game, "PROFILE") then
        U.wait(40)
        local card = H.top(game)
        check(card ~= nil and card.player ~= nil, "the profile card opened")
        if card and card.player then
          log("card for", tostring(card.player.name),
              "look", tostring(card.player.sprite))
          check(card.player.name == THEM.name, "showing the right trainer")
          check(card.player.profile ~= nil,
                "with the trainer card they sent on joining")
        end
        shot("profile")
        U.tap(game, "b")
        U.wait(30)
        check(H.classify(H.top(game)) == "menu", "and B returns to the actions menu")
      else
        check(false, "could not open PROFILE")
      end

      check(H.selectLabel(game, "TRADE"), "asked the other guest to trade")
    else
      check(false, "no PLAYERS row on the MMO menu while connected")
    end
    H.signal("hub_a_trade_asked")
  else
    H.await(game, "hub_a_trade_asked")
  end

  local wanted = THEM.species
  -- Seconds, and it must be: a trade only finishes when the other process
  -- answers its half, so this is a wait on the peer wearing the clothes of a
  -- work loop. PHASE.hub_*_trade is derived from this number.
  local record, prompts = H.promptLog()
  local traded, trail = H.drivePrompts(game, function()
    return H.partySpecies(game)[1] == wanted
  end, 180, record)
  log("party now:", table.concat(H.partySpecies(game), ","))
  if not traded then
    log("trade stalled -- prompts answered:", trail == "" and "(none)" or trail,
        "top is", tostring(H.top(game) and (H.top(game).title or "?")))
    log("  boxes:", table.concat(prompts, " | "))
  end
  check(traded, "received the other guest's " .. wanted)

  -- The census, from this seat. A trade race here duplicated a mon until a
  -- fix in src/Sessions.lua, and the shape of that bug is exactly what a
  -- one-sided "did I get theirs?" assertion cannot see: the duplicate lives
  -- on whichever side applied first and kept its own. So count what is here,
  -- and say what is not. The other instance asserts the mirror image, and
  -- between the two logs there is exactly one of each mon.
  local after = H.partySpecies(game)
  check(#after == 1, "and the party is still exactly one mon -- nothing duplicated")
  check(after[1] == wanted, "which is theirs")
  local keptMine = false
  for _, species in ipairs(after) do
    if species == ME.species then keptMine = true end
  end
  check(not keptMine, "and our own " .. ME.species .. " is gone from this side")
  shot("after-trade")
  check(rendezvous("trade"), "both guests finished their half of the trade")

  -- ------- a real link battle, run to a decision
  --
  -- The engine's own LinkBattle -- the lockstep simulation a cable link runs
  -- -- carried between two peers by a relay neither of them is running. b
  -- asks this time, so the requester (and therefore the session host that
  -- deals the shared RNG seed) is the other instance from the trade's.
  --
  -- The assertions are on engine events rather than on anything this mod
  -- reports, and link.desync is the one that matters: two games disagreeing
  -- mid-battle is exactly what lockstep exists to prevent.

  H.closeToOverworld(game)
  if ROLE == "b" then
    -- Sessions:onRequest answers immediately with a decline when the target
    -- is already in one, so a battle asked for while the trade is still
    -- tearing down is refused and the run then waits for a battle that was
    -- never going to start. The roster carries their busy flag; wait on it.
    local free = H.waitSeconds(game, function()
      local row = H.avatarRow(exports)
      return row ~= nil and not row.busy
    end, 90, "the other guest to finish the trade")
    if not free then log("WARN peer still busy; asking anyway") end
    U.wait(30)

    check(H.openMmo(game), "the MMO menu opens again after a trade")
    if H.selectLabel(game, "PLAYERS") then
      U.wait(25)
      check(H.selectLabel(game, THEM.name), "the other guest is still listed")
      U.wait(30)
      check(H.selectLabel(game, "BATTLE"), "asked the other guest to battle")
    else
      check(false, "no PLAYERS row before the battle")
    end
    H.signal("hub_b_battle_asked")
  else
    H.await(game, "hub_b_battle_asked")
  end

  local started, btrail = H.drivePrompts(game, function()
    return events["battle.started"] > 0
  end, 120)
  if not started then
    log("battle never started -- prompts answered:",
        btrail == "" and "(none)" or btrail)
  end
  check(started, "a link battle started between two guests of a dedicated hub")

  -- Frames, and this one genuinely is: a battle transition is a fixed number
  -- of drawn frames on this machine alone. The peer already did its part --
  -- battle.started has fired -- so nothing here waits on it.
  local inBattle = H.waitFor(game, function()
    local top = H.top(game)
    return top ~= nil and top.enemy ~= nil
  end, 60 * 20, "the battle screen to come up")
  if inBattle then
    U.wait(90)
    shot("battle-open")
  end

  local ended = H.drivePrompts(game, function()
    return events["battle.ended"] > 0
  end, 300)
  check(ended, "and ran to a decision")
  check(events["link.desync"] == 0, "with no desync reported")
  log(("battle events: started=%d ended=%d desync=%d"):format(
    events["battle.started"], events["battle.ended"], events["link.desync"]))
  shot("after-battle")
  check(rendezvous("battle"), "both guests came out of the battle")

  -- ------- the ranking a dedicated hub keeps
  --
  -- Same settlement as the in-game host run, through the Node hub instead:
  -- two reports, one result, and a leaderboard that comes back over the
  -- wire. The two hubs price a win identically, and this is where that stops
  -- being a claim about two files and starts being a claim about two
  -- programs.
  H.closeToOverworld(game)
  H.rankAfterBattle(game, exports, check)
  if H.openMmo(game) then
    U.wait(25)
    H.shotRank(game, ("%s/hub-%s-rank.png"):format(SHOT_DIR, ROLE), check)
  end
  H.closeToOverworld(game)

  -- ------- leaving the party
  --
  -- One member leaves and it ends for both: at two people there is no party
  -- left to continue. Only b presses the button, and *a* is where the
  -- assertion that matters lives -- a never touched a menu, so a party that
  -- emptied on this side proves the hub told it rather than that it decided
  -- for itself.

  H.closeToOverworld(game)
  if ROLE == "b" then
    check(#exports.party() == 2, "still in the party after the battle")
    if check(H.openMmo(game), "the MMO menu opens to leave the party") then
      U.wait(25)
      if H.selectLabel(game, "PARTY") then
        U.wait(25)
        check(H.selectLabel(game, "LEAVE"), "the party menu offers a way out")
        -- the confirm box, and then "You left the party."
        H.drivePrompts(game, function() return #exports.party() == 0 end, 60)
      else
        check(false, "no PARTY row to leave from")
      end
    end
    check(#exports.party() == 0, "leaving empties the party on the leaver's side")
  end
  H.closeToOverworld(game)
  check(rendezvous("partyleft"), "both guests reached the end of the party")

  local emptied = H.waitSeconds(game, function()
    return #exports.party() == 0
  end, 90, "the party to end on this side")
  check(emptied, "one member leaving ends the party for both")

  -- ...and each of them is free to be asked again, which is the flag the
  -- INVITE row is gated on.
  local freed = H.waitSeconds(game, function()
    local peerRow = exports.players()[1]
    return peerRow ~= nil and peerRow.party == false
  end, 90, "the party flag to clear on the other guest's presence")
  check(freed, "and clears the party flag everyone else reads")

  -- ------- leaving
  --
  -- a goes first so b can watch it drop off the roster; then b goes, and
  -- each side proves single-player carries straight on. Walking out of
  -- somebody else's world is not quitting: the save, the world and the
  -- (now traded) party are untouched.

  H.closeToOverworld(game)
  if ROLE == "b" then
    H.await(game, "hub_a_left")
    local gone = H.waitSeconds(game, function()
      return #exports.players() == 0
    end, 120, "the other guest to drop off the roster")
    check(gone, "a guest who leaves drops off the other guest's roster")
  end

  local menuLabels = {}
  if check(H.openMmo(game), "the MMO menu opens after the battle") then
    U.wait(25)
    for _, item in ipairs((H.top(game) or {}).items or {}) do
      menuLabels[#menuLabels + 1] = tostring(item.label)
    end
    log("MMO menu rows:", table.concat(menuLabels, ","))
    -- Through the shared matcher, not a copy of it: this used to spell the
    -- unread marker as a trailing "*" itself, and went on passing until the
    -- marker moved to a leading one -- then reported "no chat row" about a
    -- menu that had one.
    local function has(want)
      for _, label in ipairs(menuLabels) do
        if H.labelMatches(label, want) then return true end
      end
      return false
    end
    -- Both of these are the topology assertion in menu form: ADDRESS and
    -- END GAME are the rows a hosting copy gets, and neither copy here is
    -- one. A run where the mod quietly started a listener would fail here
    -- long before it failed anywhere subtle.
    check(not has("ADDRESS"), "with no ADDRESS row -- we host nothing")
    check(not has("END GAME"), "and no END GAME row either")
    check(has("LEAVE"), "just LEAVE")
    check(has("CHAT"), "and the chat log")

    -- Every row is drawable, not merely correct as a string. has("CHAT")
    -- above passes for "CHAT*" too, and that spelling rendered as CHAT
    -- plus a blank column for as long as it was there -- the marker is a
    -- triangle now precisely because the font has no asterisk.
    for _, label in ipairs(H.menuLabels(game)) do
      local missing = H.undrawable(game, label)
      check(missing == "",
            ("every glyph in %q is on the font sheet%s"):format(label,
              missing == "" and "" or " -- missing " .. missing))
    end
    shot("mmo-menu")

    if H.selectLabel(game, "CHAT") then
      U.wait(35)
      shot("chat-log")
      U.tap(game, "b")   -- CHAT's onCancel puts the MMO menu back
      U.wait(25)
    end

    if H.selectLabel(game, "LEAVE") then
      H.drivePrompts(game, function() return not exports.isConnected() end, 60)
      check(not exports.isConnected(), "LEAVE disconnects this guest")
      check(not exports.isHosting(), "which never was the host")
      check(#exports.players() == 0, "and clears the roster")
    else
      check(false, "no LEAVE row while connected as a guest")
    end
  end

  if ROLE == "a" then
    H.signal("hub_a_left")
    H.await(game, "hub_b_left")
  else
    H.signal("hub_b_left")
  end

  -- ------- and the game is still a game

  H.closeToOverworld(game)
  U.wait(20)
  local before = H.playerCell(game)
  for _, dir in ipairs({ "left", "right", "up", "down" }) do
    U.hold(game, dir, 22)
    U.wait(8)
    local now = H.playerCell(game)
    if now and before and (now.x ~= before.x or now.y ~= before.y) then
      break
    end
  end
  local afterCell = H.playerCell(game)
  log(("after leaving: (%s,%s) -> (%s,%s)"):format(
    tostring(before and before.x), tostring(before and before.y),
    tostring(afterCell and afterCell.x), tostring(afterCell and afterCell.y)))
  check(afterCell and before
        and (afterCell.x ~= before.x or afterCell.y ~= before.y),
        "and the world is still playable afterwards")
  check(H.partySpecies(game)[1] == THEM.species,
        "still holding the mon we traded for")
  shot("after-leaving")

  U.wait(60)
  log("RESULT " .. failures .. " failure(s)")
  log("DONE")
end
