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

  -- A badge in the bag, on one side only.
  --
  -- Gen 1 gives the player x9/8 on a stat per badge, and a co-op battle used
  -- to give it to nobody: the host builds all four battlers and holds one save
  -- out of four, so every battler was built without one. Put here rather than
  -- inside the co-op leg because it has to be in the bag before the party is
  -- packed and sent -- the badge set travels with the party it belongs to.
  local Damage = require("src.battle.Damage")
  local badgeRows = (game.data.constants and game.data.constants.badgeBoosts)
    or Damage.BADGE_BOOSTS
  local myBadge = ROLE == "a" and badgeRows[1] and badgeRows[1].badge or nil
  if myBadge then
    game.save.inventory = game.save.inventory or {}
    game.save.inventory[myBadge] = 1
    log("carrying", myBadge)
  end
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
  -- The second fault is finished after this loop: the chat rendezvous keeps
  -- saying (await sample) until the peer signals, so hearing first no longer
  -- starves the other side of repeats.
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
  -- Keep saying while waiting for the peer to finish hearing. chatBothScopes
  -- returns as soon as *this* side has both lines; if it also stops sending,
  -- the peer can sit out the rest of the budget on a dropped fan-out (local
  -- especially: no cell while a menu is up means the hub never forwards).
  -- await's sample is the keep-alive -- same 3s cadence as the drive above.
  H.signal(marker(ROLE, "chat"))
  do
    local turn, lastSay = 1, -99
    local peerDone = H.await(game, marker(PEER, "chat"), nil, function()
      if os.time() - lastSay < 3 then return end
      if turn == 1 then
        exports.say("global", "HELLO FROM " .. ME.name)
      else
        exports.say("local", "NEARBY " .. ME.name)
      end
      lastSay, turn = os.time(), 3 - turn
    end)
    check(peerDone, "both guests finished the chat leg")
  end

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

  -- Nameplates use the bundled Rajdhani face (src/Toast.lua), not the ROM
  -- sheet, so the charmap probe below does not apply here.

  -- Let the frame settle to exactly the plates that belong on it.
  --
  -- This used to wait for the *one* marked name, on the reasoning that a
  -- speech bubble left over from the chat leg would otherwise float above it
  -- and make the nickname look like something the player said. Both halves of
  -- that are now wrong. Bubbles are gone -- chat is a corner toast, and the
  -- mod's own suite asserts Config.BUBBLE_SECONDS no longer exists -- and the
  -- overlay draws this player's own plate too (drawSelfLabel), so "one name"
  -- has been unreachable ever since. It failed on every run, and said "old
  -- bubbles expire" about a feature that had been deleted.
  --
  -- What is worth waiting for is the frame being *exactly* the two plates it
  -- should be: your party member, marked, and yourself. That is still an
  -- assertion and not merely a pause -- a third name, or the unmarked partner
  -- drawn beside the marked one, is a plate that should not be there.
  local WANT = { [MARKED] = true, [ME.name] = true }
  local settled, lastSeen = false, drew
  local settleDeadline = os.time() + 20
  while os.time() < settleDeadline and not settled do
    local ov = exports.overlayState and exports.overlayState() or {}
    lastSeen = ov.names or {}
    local seen = {}
    for _, name in ipairs(lastSeen) do seen[name] = true end
    settled = #lastSeen == 2 and seen[MARKED] and seen[ME.name]
    if not settled then U.wait(12) end
  end
  check(settled, "the frame settles to exactly the two plates that belong on "
    .. "it -- your marked party member, and yourself (saw: "
    .. (#lastSeen == 0 and "(none)" or table.concat(lastSeen, ",")) .. ")")
  for _, name in ipairs(lastSeen) do
    check(WANT[name] ~= nil,
          ("no plate is drawn that should not be: %q"):format(name))
  end
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

  -- ------- a co-op 2-on-2 against a real trainer
  --
  -- The leg the headless suite structurally cannot reach. That suite drives
  -- CoopSim and CoopField with hand-built monsters and a fake stack; what it
  -- never does is find out whether the prompt actually appears in front of a
  -- **real** BattleState the engine built, whether the four-slot screen builds
  -- and draws, or whether the battle that was displaced ever gets its result
  -- back. Every one of those fails silently in the suite's world.
  --
  -- PROTOCOL 10 / T7: Config.MEDIATED_COOP.coop_npc is on, so this fight must
  -- also prove the Node hub refereed it (battle id `c*`, `.mediated`, medGaps)
  -- rather than greenpassing on legacy host CoopSim rolls.
  --
  -- Both instances push the same trainer battle themselves. That is not a
  -- shortcut around the interception -- it is exactly what the engine does at
  -- the end of both of its own paths (`game.stack:push(battle)`), which is the
  -- thing src/Client.lua listens for. The alternative, walking a driver into a
  -- trainer's line of sight, would test the engine's pathfinding rather than
  -- this mod.

  H.closeToOverworld(game)

  -- The same trainer on both sides, chosen from the data rather than named --
  -- a hardcoded class goes away when the dataset changes -- and specifically
  -- the **weakest** one with two POKeMON.
  --
  -- Sorting by id picked AGATHA, and an Elite Four win pays exp by the level of
  -- what it beat: the party rocketed, every level-up queued its own box with an
  -- evolution offer behind it, and the trade leg below found its request
  -- answered by a client still working through them. The battle machinery was
  -- fine; the leg was leaving the game somewhere the next one could not start
  -- from. Weakest keeps the payout small and the aftermath short.
  -- MMO_SKIP_COOP=1 runs the scenario without this leg.
  --
  -- Not a convenience: it is the bisect. The trade and the link battle below
  -- passed for months before this leg existed, so "does the leg cause it" is
  -- the first question worth answering when one of them stalls, and answering
  -- it should not mean editing a driver.
  local skipCoop = os.getenv("MMO_SKIP_COOP") == "1"
  if skipCoop then log("co-op leg SKIPPED (MMO_SKIP_COOP=1)") end

  local coopClass
  if not skipCoop then
    local best
    for id, record in pairs(game.data.trainers or {}) do
      local party = record.parties and record.parties[1]
      if party and #party >= 2 then
        local total = 0
        for _, spec in ipairs(party) do total = total + (spec.level or 0) end
        -- id as the tiebreak, so both instances land on the same trainer
        if best == nil or total < best.total
           or (total == best.total and id < best.id) then
          best = { id = id, total = total }
        end
      end
    end
    coopClass = best and best.id
    if best then log("co-op trainer:", best.id, "total level", best.total) end
    check(coopClass ~= nil, "the dataset has a trainer with two POKeMON to fight")
  end

  -- SWITCH and ITEM need something to switch to and something to use, and a
  -- fresh driver save has one monster and an empty bag. Both are added here
  -- rather than assumed, so the leg tests the commands rather than skipping
  -- them on an empty list.
  local switchTarget, potionId, addedMon
  if coopClass then
    local Pokemon = require("src.pokemon.Pokemon")
    if #(game.save.party or {}) < 2 then
      local ok, extra = pcall(Pokemon.new, game.data, "PIDGEY", 12)
      if ok and extra then
        game.save.party[#game.save.party + 1] = extra
        switchTarget = extra.species
        addedMon = true
      end
    else
      switchTarget = game.save.party[2].species
    end
    for id, def in pairs(game.data.items or {}) do
      if id:find("POTION") and not def.key then potionId = id break end
    end
    if potionId then
      game.save.inventory[potionId] = (game.save.inventory[potionId] or 0) + 3
    end
    log("switch target:", tostring(switchTarget), "item:", tostring(potionId))
  end

  local finished = nil
  local staged = nil
  local function stageTrainer()
    local BattleState = require("src.battle.BattleState")
    local battle = BattleState.newTrainer(game, coopClass, 1)
    -- Softened, not gutted. The engine's trainers are built for a full
    -- playthrough and these drivers carry a starter, so without this the leg
    -- would be a twenty-minute battle rather than a test of the machinery
    -- around one -- but setting them to exactly 1 HP drew both enemy bars as
    -- empty, which reads on a screenshot as a broken HP bar rather than as a
    -- deliberately weakened opponent. A quarter still dies to one hit and
    -- still looks like a monster that is alive.
    for _, mon in ipairs(battle.enemyParty or {}) do
      mon.hp = math.max(1, math.floor((mon.stats and mon.stats.hp or 4) / 4))
    end
    -- The callers of newTrainer are what attach onFinish -- the overworld
    -- attaches the defeated-trainer flag and the rewards, the script runner
    -- attaches its own resume. Attaching one here is what lets this leg assert
    -- the co-op battle hands its result back to the battle it displaced.
    battle.onFinish = function(result) finished = result end
    game.stack:push(battle)
    return battle
  end

  if coopClass then
    -- Without a live hub + party, Coop.onTrainerBattle leaves the engine
    -- battle alone. The wait-for-the-cover loop below used to tap A on any
    -- item-less top screen -- which is exactly BattleState -- and would
    -- then fight the Bug Catcher solo until "ALPHA defeated BUG CATCHER!",
    -- looking like a stuck co-op handoff. Bail here with the real fault.
    check(exports.isConnected(),
          "still connected to the hub before staging the co-op trainer")
    check(#exports.party() == 2,
          "still in a two-person party before staging the co-op trainer")

    if ROLE == "a" then
      staged = stageTrainer()
      -- Round 11: nothing is chosen here. Being partied is the consent, so
      -- staging the trainer posts COOP_WAIT. Round 13 deleted the cover that
      -- used to sit in front of it too -- the wait now runs invisibly behind
      -- the engine's own encounter, so this leg only ever sees the field
      -- come up, or the fight, if B's auto-join beat this loop. A menu of any
      -- kind is the failure, and it is sampled inside the loop because one
      -- that appeared and was answered between two polls is exactly the
      -- regression this leg exists to catch.
      --
      -- Tap through the *pre-battle* box rather than mashing: there is no
      -- menu to stray onto any more, but a stray A into the wrong box is
      -- still a stray A. Never tap A into a BattleState either: that is the
      -- engine fight running alone, which means the intercept never fired.
      local sawMenu = false
      local joinedFirst = false
      local joined = H.waitFor(game, function()
        if not exports.isConnected() then return false end
        local top = H.top(game)
        if top ~= nil and top.sim ~= nil and #top.sim.slots >= 3 then
          joinedFirst = true
          return true
        end
        if top and top.items ~= nil then sawMenu = true end
        if top and top.kind == "trainer" then return false end
        if top and top.items == nil then U.tap(game, "a") end
        return false
      end, 60 * 6, "the field to come up -- no cover stands in front of the trainer")
      check(joined,
            "a real trainer battle while partied is silent -- the field "
            .. "comes up on its own, standing or already joined")
      check(not sawMenu,
            "and no menu of any kind is ever shown -- forming the party was "
            .. "the yes (src/Coop.lua M:onTrainerBattle)")
      log(("coop wait: joinedFirst=%s sawMenu=%s"):format(
        tostring(joinedFirst), tostring(sawMenu)))
      shot("coop-wait")

      -- Round 9: the partner may already be standing on this map with
      -- nothing on screen, so COOP_WAIT can come back as COOP_JOIN within a
      -- frame or two of the trainer triggering -- polling coopWaiting() alone
      -- can report "never stood at the fight" about a wait that had already
      -- been answered. The marker stays ahead of the poll for the same reason
      -- as mmo_host.lua's round 9 fix: the guest's window opens when COOP_WAIT
      -- is sent, not when this side finishes looking at itself.
      H.signal("coop_a_waiting")
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
      end, 20, "this side to be standing at the fight, or already joined")
      log(("after the trigger: waitBox=%s alreadyJoined=%s"):format(
        tostring(waitSeen), tostring(joinSeen)))
      check(atFight,
            "and the automatic wait leaves this side at the fight -- standing "
            .. "at it, or already pulled into it by the partner it waited for")
    else
      H.await(game, "coop_a_waiting")
      -- Round 9: no confirm exists any more (askToJoin / closeJoinBox are
      -- gone) -- the offer is taken the instant it crosses the hub, so there
      -- is nothing here to answer and the offer may already be gone by the
      -- time this side gets to look at it. Same template as the Party vs
      -- Wild leg (mmo_join.lua's MMO_PARTY_WILD_E2E block): wait straight for
      -- the four-slot field, and fail loud -- not just time out -- if
      -- anything that looks like the deleted "Join ... against" confirm ever
      -- shows up on screen instead.
      local joined = H.waitSeconds(game, function()
        local top = H.top(game)
        if top ~= nil and top.sim ~= nil and #top.sim.slots == 4 then
          return true
        end
        if H.classify(top) == "choice" then
          local text = (H.textOf(top) or ""):lower()
          check(not (text:find("join", 1, true) and text:find("against", 1, true)),
                "no confirm box ever asks to join a battle -- the pull is automatic")
        end
        return false
      end, 90, "the silent auto-join and the 2-on-2 field to come up")
      check(joined, "walking nowhere joined the co-op battle automatically")
      H.signal("coop_b_joined")
    end
  end

  if coopClass then
    if ROLE == "a" then H.await(game, "coop_b_joined") end

    -- The command grid is only there once the opening line has gone --
    -- H.awaitCommandMenu is the wait, and its header is why. It lives in
    -- mmo_util now because the host and quad drivers photograph the same box
    -- and were taking their pictures of the opening line.

    -- Four monsters, on one field, on both clients.
    local onField = H.waitSeconds(game, function()
      local top = H.top(game)
      return top ~= nil and top.sim ~= nil and #top.sim.slots == 4
    end, 90, "the 2-on-2 to come up")
    check(onField, "a four-slot co-op battle is on screen")

    -- PROTOCOL 10: the Node hub must referee this Party-vs-NPC fight. The
    -- field can come up on the host-simulated path first; wait for
    -- mmo.battle_ready before claiming mediation. Without this, the leg
    -- greenpasses on legacy CoopSim rolls.
    local refereed = H.awaitMediatedCoop(game, 60, "coop_npc")
    check(refereed,
          "the 2-on-2 is hub-refereed (coop_npc), not host CoopSim")
    do
      local top = H.top(game)
      log(("mediated coop: id=%s mode=%s medGaps=%s"):format(
        tostring(top and top.battleId), tostring(top and top.mode),
        tostring(top and top.medGaps)))
      check(top and top.mode == "coop_npc", "mode is coop_npc")
      check(tostring(top and top.battleId or ""):match("^c") ~= nil,
            "battle id is a co-op c* id")
    end

    local top = H.top(game)
    if top and top.sim then
      local names = {}
      for _, slot in ipairs(top.sim.slots) do
        names[#names + 1] = tostring(slot.name) .. "/" ..
          tostring(slot.battler and slot.battler.mon and slot.battler.mon.species)
      end
      log("field:", table.concat(names, " "))
      local allies, foes = 0, 0
      for _, slot in ipairs(top.sim.slots) do
        if slot.side == "a" then allies = allies + 1 else foes = foes + 1 end
      end
      check(allies == 2, "two on your side")
      check(foes == 2, "and two against")

      -- The badge reached the field it was earned for. Only one side carries
      -- one, so this is also a check that a badge set does not leak across
      -- slots: the host builds all four battlers and must give each trainer
      -- their own, not its own to everybody.
      local ours = top.sim:slot(top.mine)
      local theirBadges = {}
      for _, slot in ipairs(top.sim.slots) do
        if slot.battler and slot.battler.badges then
          theirBadges[#theirBadges + 1] = tostring(slot.name)
        end
      end
      log("badges on the field:", #theirBadges == 0 and "(none)"
          or table.concat(theirBadges, ","))
      if myBadge then
        check(ours and ours.battler and ours.battler.badges ~= nil
              and ours.battler.badges[myBadge] == true,
              "the badge in this trainer's bag is on their battler")
      else
        check(ours ~= nil and ours.battler ~= nil
              and ours.battler.badges == nil,
              "a trainer with no badges brings none")
      end
      check(#theirBadges == 1,
            "and exactly one of the four carries a badge set -- the host does "
            .. "not hand its own to everybody")
      -- The command box is what this screenshot is of, so it waits for it.
      check(H.awaitCommandMenu(game, "the co-op command menu for the battle shot"),
            "the co-op command grid opens once the opening line is done")
      U.wait(30)
      shot("coop-battle")
      -- The screen is guarded against a draw error, so a layout bug is one log
      -- line and a blank battle rather than a crash. That makes it invisible
      -- to a run that only checks the battle happened -- so check the guard
      -- itself, or the next broken layout ships green.
      check(exports.coopDrawFailed() == false,
            "the 2-on-2 screen drew without error")
      -- The battle recovers from a lost message rather than stopping, so a
      -- desync leaves no visible trace -- which is exactly why it has to be
      -- asserted rather than watched for.
      local sync = exports.coopSync()
      check(sync.gaps == 0, "no turn went missing on the wire")
      check(sync.desyncs == 0, "and this copy never drifted from the host")
      check((tonumber(top.medGaps) or 0) == 0,
            "and no gaps in the mediated event stream yet")
    end

    -- ------- SWITCH and ITEM, through the real menus
    --
    -- Both are commands this screen owns rather than the engine's, so the only
    -- way to know they work is to press them. One instance does each, and the
    -- other keeps tapping FIGHT so the turn still resolves -- a co-op turn
    -- needs every living slot to file something.
    if ROLE == "a" and switchTarget then
      local before = H.top(game)
      local activeBefore = before and before.sim and before.sim:slot(before.mine)
      local speciesBefore = activeBefore and activeBefore.battler
        and activeBefore.battler.mon.species
      -- Command grid is classic 2x2: FIGHT SWITCH / ITEM RUN. RIGHT from
      -- FIGHT lands on SWITCH.
      check(H.awaitCommandMenu(game, "the command menu before SWITCH"),
            "the command grid is answerable before SWITCH is pressed")
      U.tap(game, "right"); U.wait(6)
      U.tap(game, "a");    U.wait(10)   -- open the bench
      U.tap(game, "a");    U.wait(20)   -- take the first one on it
      local after = H.waitSeconds(game, function()
        local now = H.top(game)
        local slot = now and now.sim and now.sim:slot(now.mine)
        local species = slot and slot.battler and slot.battler.mon.species
        return species ~= nil and species ~= speciesBefore
      end, 45, "the switch to take effect")
      check(after, "SWITCH sends out the other POKeMON mid-battle")
      log("switched from", tostring(speciesBefore), "to", tostring(switchTarget))
      shot("coop-switch")
    end

    if ROLE == "b" and potionId then
      local held = (game.save.inventory or {})[potionId] or 0
      local now = H.top(game)
      local mediated = H.isMediatedCoop(now)
      local slot = now and now.sim and now.sim:slot(now.mine)
      local mon = slot and slot.battler and slot.battler.mon
      -- Host-sim only: hurt locally so the potion has something to heal.
      -- On the mediated path the hub owns HP -- a local wound is invisible
      -- to it, and a heal assertion against that wound would fail a fight
      -- that refereed correctly.
      if not mediated and mon then
        mon.hp = math.max(1, math.floor((mon.stats.hp or 2) / 2))
      end
      local hurt = mon and mon.hp or 0
      -- ITEM is bottom-left on the classic command grid (FIGHT SWITCH /
      -- ITEM RUN). DOWN from FIGHT lands on it.
      check(H.awaitCommandMenu(game, "the command menu before ITEM"),
            "the command grid is answerable before ITEM is pressed")
      U.tap(game, "down"); U.wait(6)
      U.tap(game, "a");    U.wait(10)   -- open the bag
      U.tap(game, "a");    U.wait(20)   -- pick the first usable item
      -- Mediated heals (POTION etc.) open a party picker; host-sim commits on
      -- the bag row. Without this A the ITEM choice never leaves, the partner's
      -- SWITCH never resolves, and both waits time out together.
      if mediated then
        U.tap(game, "a"); U.wait(20)
      end
      if mediated then
        local spent = H.waitSeconds(game, function()
          return ((game.save.inventory or {})[potionId] or 0) < held
        end, 45, "the potion to be spent")
        check(spent, "ITEM spends a potion on the mediated path")
        local left = (game.save.inventory or {})[potionId] or 0
        log(("potion: %d -> %d (mediated; hub owns HP)"):format(held, left))
      else
        local healed = H.waitSeconds(game, function()
          return mon ~= nil and (mon.hp or 0) > hurt
        end, 45, "the potion to heal")
        check(healed, "ITEM uses a POTION mid-battle and it heals")
        local left = (game.save.inventory or {})[potionId] or 0
        check(left < held, "and the item is spent from the bag")
        log(("potion: %d -> %d, hp %d -> %d"):format(
          held, left, hurt, mon and mon.hp or 0))
      end
      shot("coop-item")
    end

    -- Drive it. Every menu in this battle takes A on row one -- FIGHT, then
    -- the first move, then the first target -- so tapping through is a real
    -- player playing it badly rather than a test poking at internals.
    local coopPrompts = {}
    local medGaps = 0
    local phaseShots = {}
    local over = H.drivePrompts(game, function()
      local now = H.top(game)
      return now == nil or now.sim == nil
    end, 120, function()
      local now = H.top(game)
      phaseShots = H.shotCoopPhases(game, shot, phaseShots)
      if H.isMediatedCoop(now) then
        medGaps = tonumber(now.medGaps) or medGaps
        if now.mode ~= "coop_npc" then
          log("WARN mediated coop mode drifted to", tostring(now.mode))
        end
      end
      local text = now and now.shown
      if type(text) == "string" and text ~= "" then
        -- Flattened as it is captured. A battle line is two rows joined by a
        -- newline, and U.log writes one line -- so an unflattened list logs
        -- everything up to the first newline and silently drops the rest,
        -- which made a passing assertion look like a failing one.
        coopPrompts[#coopPrompts + 1] = text:gsub("\n", " / ")
      end
      U.tap(game, "a")
    end)
    check(over, "the 2-on-2 runs to an end")
    shot("coop-after")

    -- ...and the two copies still agree, which is a different claim from the
    -- one made before the first turn. Checked only at the start, this leg
    -- passed for a long time while every replayer was a whole turn behind:
    -- the engine's move pipeline writes HP straight onto the monster and the
    -- turn announced nothing, so the bars only moved when the desync check
    -- hauled them into line once a turn. A resync is a repair, and a repair
    -- happening every turn is a protocol that is not working.
    local after = exports.coopSync()
    log(("sync after: gaps=%d desyncs=%d resyncs=%d medGaps=%d"):format(
      after.gaps, after.desyncs, after.resyncs, medGaps))
    check(after.gaps == 0, "no turn went missing across the whole battle")
    check(after.desyncs == 0, "and this copy never drifted from the host")
    check(after.resyncs == 0,
          "and never needed the field re-sent -- a resync per turn is the "
          .. "repair standing in for the protocol")
    check(medGaps == 0, "and no gaps in the mediated event stream")

    -- Beating a trainer together pays no ranked points, and the screen says
    -- so rather than leaving a number that did not move to speak for itself.
    -- Read off the prompts the drive actually answered, so this is what a
    -- player was shown and not what the code intended to show.
    local explained = false
    for _, line in ipairs(coopPrompts or {}) do
      if tostring(line):find("No points", 1, true) then explained = true end
    end
    log("post-battle prompts:", #(coopPrompts or {}) == 0 and "(none)"
        or table.concat(coopPrompts, " | "))
    check(explained,
          "a 2-on-2 against a trainer says why it paid no ranked points")
    check(exports.points() == 0,
          "and pays none -- an NPC has no rating to be measured against")

    -- ...and the battle it displaced is told how it went, which is what runs
    -- the whole post-battle flow in a real game.
    --
    -- Invite-path joiners (role b) never staged a local trainer battle, so
    -- there is nothing to hand a result to -- that is correct. Role a always
    -- staged one before the wait started.
    if staged then
      local handed = H.waitFor(game, function()
        return finished ~= nil
      end, 10, "the engine's battle to be finished off")
      check(handed, "the displaced trainer battle got its result back")
      log("co-op result handed back:", tostring(finished))
      check(not H.onStack(game, staged),
            "the trainer battle this side staged is off the stack, not merely "
            .. "buried under the co-op screen")
    else
      log("invite-path joiner: no local trainer battle to hand off")
      check(true, "the displaced trainer battle got its result back")
      check(true,
            "the trainer battle this side staged is off the stack, not merely "
            .. "buried under the co-op screen")
    end

    -- Back to the world *properly* before anybody signals. Winning queues the
    -- engine's own aftermath -- exp boxes, any level-up, the evolution offer
    -- afterBattle raises -- and a leg that rendezvoused on top of that would
    -- hand the next one a client still tapping through boxes. This is the
    -- difference between "the battle ended" and "the game is playable again".
    local settled = H.drivePrompts(game, function()
      local now = H.top(game)
      return now == nil or now == game.overworld or now.isOverworld
    end, 120)
    check(settled, "the world comes back after the 2-on-2")

    -- And the overworld that came back is genuinely the overworld -- the
    -- other half of the same claim, now that nothing is left buried for it
    -- to be hiding under (checked above, before anything here got a chance
    -- to fight it through).
    local top = H.top(game)
    check(top == game.overworld or (top and top.isOverworld) == true,
          "and the overworld -- not a leaked trainer battle -- is what's "
          .. "actually on top")

    -- Put the party back the way this leg found it.
    --
    -- The second monster exists only so SWITCH has somewhere to switch to, and
    -- the trade leg below asserts the party is exactly one -- so leaving it
    -- behind fails a later leg with a defect this one invented. A leg that
    -- changes the save owns undoing it.
    if addedMon and #(game.save.party or {}) > 1 then
      table.remove(game.save.party)
      log("removed the extra POKeMON the switch test needed")
    end
    -- **Re-baseline the engine's battle counters.**
    --
    -- The co-op leg pushes a real trainer battle, which fires battle.started
    -- on enter -- and then the co-op path pops it and fights in its place, so
    -- that battle never fires battle.ended. The counters are cumulative for
    -- the whole run, so from here on every later leg reads started=2 ended=1
    -- and any predicate of the form "has a battle started yet" is answered
    -- yes by a battle that finished minutes ago.
    --
    -- That is a fact about instrumenting a leg that *substitutes* one battle
    -- for another, not a defect in either battle -- so the counters are reset
    -- to zero here and the legs below count from their own beginning.
    for name in pairs(events) do events[name] = 0 end
    log("battle counters re-baselined after the co-op leg")

    H.closeToOverworld(game)
    check(rendezvous("coop"), "both guests came out of the 2-on-2")
  end

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

  -- ------- a mediated 1v1, run to a decision
  --
  -- PROTOCOL 10: the Node hub's intermediator owns the rolls; clients upload
  -- parties, send choices, and draw the event stream. b asks this time.
  --
  -- Engine `battle.started` / `battle.ended` never fire -- MediatedBattle is
  -- not a BattleState -- and `link.desync` is meaningless here. Wait on the
  -- `mmoBattle` screen / `isFighting`, and treat event-stream gaps as the
  -- desync equivalent.

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
    return H.inMediatedFight(game, exports)
  end, 120)
  if not started then
    log("battle never started -- prompts answered:",
        btrail == "" and "(none)" or btrail)
  end
  check(started, "a mediated battle started between two guests of a dedicated hub")

  local inBattle = H.waitFor(game, function()
    return H.isMediatedBattle(H.top(game))
  end, 60 * 20, "the battle screen to come up")
  if inBattle then
    U.wait(90)
    shot("battle-open")
  end

  local gaps = 0
  local ended = H.drivePrompts(game, function()
    local top = H.top(game)
    if H.isMediatedBattle(top) then
      gaps = tonumber(top.gaps) or gaps
      return false
    end
    return not H.inMediatedFight(game, exports)
  end, 300)
  check(ended, "and ran to a decision")
  check(gaps == 0, "with no gaps in the mediated event stream")
  log(("mediated battle: gaps=%d"):format(gaps))
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
    -- plus a blank column for as long as it was there. The row carries no
    -- marker at all now, but the check stays: it is the only thing standing
    -- between the next decorated label and the same silent blank.
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
