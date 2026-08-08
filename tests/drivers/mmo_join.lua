-- Driver: join a hosted game, joining side.
--
-- Pair with tests/drivers/mmo_host.lua in a second instance. Waits for the
-- host to publish its address, then joins over a real socket, walks around
-- so the host has movement to observe, and checks the host shows up on this
-- side's roster too.
--
--   POKEPORT_IDENTITY=mmoguest POKEPORT_DRIVER=mods/rby_mmo/tests/drivers/mmo_join.lua love .

local function mod_current(game)
  local ow
  for i = #game.stack.states, 1, -1 do
    if game.stack.states[i].isOverworld then ow = game.stack.states[i] break end
  end
  ow = ow or game.overworld
  return { mapId = ow.map.id, x = ow.player.cellX, y = ow.player.cellY }
end

-- Muted at load, for the reason given at the top of mmo_host.lua.
if os.getenv("MMO_SOUND") ~= "1" and love and love.audio then
  love.audio.setVolume(0)
end

return function(game)
  local H = dofile("mods/rby_mmo/tests/drivers/mmo_util.lua")
  local U = H.U
  local TAG = "MMO_JOIN:"
  local ADDR_FILE = os.getenv("MMO_ADDR_FILE") or "/tmp/rby_mmo_addr.txt"
  local SHOT_DIR = os.getenv("SHOT_DIR") or "/tmp/rby_mmo_shots"

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

  U.newGame(game)
  -- U.newGame mashes A through the naming grid, so both sides would
  -- otherwise be called AAAAAAA and no roster assertion could tell
  -- them apart. Name them here instead.
  if game.save and game.save.player then
    game.save.player.name = "GUESTY"
  end
  local Pokemon = require("src.pokemon.Pokemon")
  game.save.party = { Pokemon.new(game.data, "PIKACHU", 30) }
  -- so the driven battle actually resolves; see frontloadDamage
  local lead = H.frontloadDamage(game.data, game.save.party[1])
  log("in the overworld as GUESTY with", table.concat(H.partySpecies(game), ","),
      "leading with", tostring(lead))

  local exports = H.requireMod(game, TAG)
  if not exports then
    log("RESULT 1 failure(s)")
    return
  end

  -- What this player is drawn with, before anything is dialled -- no longer
  -- guaranteed to be the vanilla trainer the way it was before leaving
  -- stopped restoring it. MMO_GUEST_SPRITE is an explicit choice
  -- (SPRITE_COOLTRAINER_M, never RED -- see Client.explicitChoice), and the
  -- widened refreshLook wears an explicit choice on the very first
  -- map.entered (src/Client.lua's refreshLook), which already fired, more
  -- than once, during U.newGame's walk through the intro. So this may
  -- already be a mod-built renderer for the chosen character rather than
  -- the engine's own -- kept only to prove *something* is drawn at all.
  -- Every check below asks which character the sheet draws from, not
  -- whether it is this same object (see H.wornMatches).
  local ownSheet = H.playerSheet(game)
  check(ownSheet ~= nil, "the player is drawn with something to begin with")

  -- The host writes its address once the listener is up; that file is the
  -- start gun. This side dials the default the wrapper stored, which is
  -- 127.0.0.1 on the port the host actually bound -- both instances are on one
  -- machine, but the port is chosen per run so two runs do not join each
  -- other, and a default left at the old fixed 7788 points at nothing.
  --
  -- Its second line is the join code, which the host always has: hosting
  -- without one is refused at the socket. Taking it off the file rather than
  -- off an env flag of this side's own is still the right shape -- two
  -- drivers reading the same switch and disagreeing about it is a whole
  -- class of confusing failure that never has to exist -- and it now doubles
  -- as the check that the host really did publish one.
  local hostAddress, joinCode
  local ready = H.waitSeconds(game, function()
    local handle = io.open(ADDR_FILE, "r")
    if not handle then return false end
    hostAddress = handle:read("*l")
    local line = handle:read("*l")
    handle:close()
    joinCode = (line ~= nil and line ~= "") and line or nil
    return true
  end, 240, "the host to publish its address")
  check(ready, "the host came up")
  if not ready then
    log("RESULT " .. failures .. " failure(s)")
    return
  end
  log("host published", tostring(hostAddress),
      joinCode and ("code " .. H.formatCode(joinCode)) or "with NO CODE")

  -- ------- join, through the real menus

  if not H.openMmo(game) then
    log("FAIL could not reach the MMO menu")
    log("RESULT " .. (failures + 1) .. " failure(s)")
    return
  end

  if not H.selectLabel(game, "JOIN GAME") then
    log("FAIL no JOIN GAME row")
    log("RESULT " .. (failures + 1) .. " failure(s)")
    return
  end

  U.wait(20)
  check(H.classify(H.top(game)) == "menu", "character creation opened")
  check(H.selectLabel(game, "JOIN"), "confirmed the trainer and moved on")

  -- The naming screen carries the saved address as its `default`, and START
  -- submits that when nothing has been typed. That it has a default at all
  -- is the point: the vanilla grid has no digits, so a default that already
  -- reads 127.0.0.1:7788 is what makes this reachable without typing.
  --
  -- Identified by title, not merely by "a grid is up": the code screen is
  -- also a naming screen and is one keypress away, so the two have to be
  -- told apart or a run could type its address into the wrong one.
  U.wait(20)
  local naming = H.addressGrid(game)
  if naming then
    log("address screen: typed", '"' .. table.concat(naming.glyphs) .. '"',
        "default", '"' .. tostring(naming.default) .. '"')
  else
    log("WARN the top state is not the address screen:",
        tostring(H.top(game) and (H.top(game).title or "?")))
  end
  check(naming ~= nil, "the address screen opened")

  -- Type the address out on the grid, and then take it back off again.
  --
  -- Two things come out of this that nothing else covers. The first is the
  -- claim src/Ui.lua makes for this screen and never checks: that an address
  -- is *typeable* at all. The vanilla grid has no digits, so "127.0.0.1:7788"
  -- is untypeable on it; the mod's digits page is what makes this screen
  -- answerable by somebody whose friend read them a number, and the only
  -- proof of that is putting one in through the d-pad. The second is B as an
  -- eraser, which is the other half of the rule the screen prints under
  -- itself ("B ERASES" with a character on the line, "B GOES BACK" without).
  --
  -- Then it is cleared, deliberately, so what follows is unchanged: START on
  -- an *empty* line is what submits the stored default, and that is the path
  -- a player who was never told an address takes. Erasing to empty rather
  -- than submitting the typed copy keeps that path the one this run drives.
  if naming and type(naming.default) == "string" and naming.default ~= "" then
    local typed = H.typeOnGrid(game, naming.default)
    check(typed, "the address grid takes a full address: " .. naming.default)
    check(typed and table.concat(naming.glyphs) == naming.default,
          "and the line reads back what was typed: "
            .. table.concat(naming.glyphs))
    -- What is on the line has to be what is on the screen, which is not the
    -- same claim. NamingScreen draws its field from a fixed x=56 in 8px
    -- cells, so only 13 fit across a 160px screen while this screen's maxLen
    -- is 32: "127.0.0.1:7788" is 14 characters and used to lose its last one
    -- -- part of the port, the half a player most needs to check -- off the
    -- right edge, with the rest pushed hard against that edge rather than
    -- centred. src/Ui.lua repaints the row now (M.fieldLayout), so 18 cells
    -- fit between the margins and this is a real check rather than the WARN
    -- it was while the bug belonged to a screen nothing here owned.
    --
    -- The port, specifically, is what is asserted. "Everything fits" would
    -- be the wrong claim: maxLen is 32 precisely so a hostname can be typed,
    -- and "mybox.example.com:7788" is 22 -- longer than the window on
    -- purpose. What the fix guarantees for *any* length is that the window
    -- holds the end of the line, so the port never scrolls away.
    local VISIBLE_CELLS = 18
    local shown = naming.default:sub(-VISIBLE_CELLS)
    local port = naming.default:match(":(%d+)$")
    check(port ~= nil and shown:find(":" .. port, 1, true) ~= nil,
          ("the port is on screen, not cut off the right edge: %q shows as %q")
            :format(naming.default, shown))
    check(H.clearGrid(game, naming), "B erases it back to an empty line")

    -- The other thing this field takes, and the one that fits: a hostname.
    -- src/Ui.lua sizes the field for "mybox.example.com:7788" precisely
    -- because a name is what somebody on a LAN reads out, and no other test
    -- puts a letter on this grid. It is typed, photographed and erased -- the
    -- run still dials the default below, untouched.
    local HOSTNAME = "MYPC.LAN:7788"
    check(H.typeOnGrid(game, HOSTNAME) and
          table.concat(naming.glyphs) == HOSTNAME,
          "and a hostname, across both pages, just as well: " .. HOSTNAME)
    U.shot(game, SHOT_DIR .. "/join-address.png")
    check(H.clearGrid(game, naming), "erased again, so START submits the default")
  else
    check(false, "the address screen carries a default to dial")
    U.shot(game, SHOT_DIR .. "/join-address.png")
  end

  U.tap(game, "start")
  U.wait(60)

  -- ------- the join code, asked for before anything is dialled
  --
  -- The one path no other suite can reach. tests/rby_mmo_test.lua drives Hub
  -- with fake peers, so it can prove the HMAC is checked but never that a
  -- player can answer a challenge: the answer has to be typed on a d-pad
  -- grid with no digits on its first page, and every part of that is UI.
  --
  -- The order changed with the six-character passcode. It used to be
  -- address, dial, and then a challenge from the hub pushing a text box over
  -- a handshake that was already spending its ten-second budget; now the
  -- address screen hands straight over to the code grid and the socket is
  -- not opened until both have been answered. The challenge path still
  -- exists and is still driven below -- it is what a *wrong* code lands back
  -- on, which is why the wrong one goes first: that is where a player ends
  -- up when they mistype, and a refusal that leaves them staring at a dead
  -- screen with no way back is worse than one that never came.
  check(joinCode ~= nil, "the host published a join code with its address")
  if joinCode then
    -- Frames, and only here: the grid is pushed by the address screen's own
    -- onDone, inside this process, with nothing yet on the wire -- which is
    -- exactly what the assertion under it says.
    local asked = H.waitFor(game, function()
      return H.codeGrid(game) ~= nil
    end, 240, "the join-code grid")
    check(asked, "the address screen hands straight over to the code grid")
    check(exports.isConnected() == false,
          "and nothing is dialled until the code is answered")
    U.shot(game, SHOT_DIR .. "/join-code-asked.png")

    -- The same screen with something on its line, which is what it looks like
    -- to somebody halfway through reading a code off a phone -- and the one
    -- frame where the hint under the grid reads B ERASES rather than B GOES
    -- BACK. Erased again straight after, so the entry below still starts from
    -- an empty line the way a real attempt does.
    local codeScreen = H.codeGrid(game)
    if codeScreen then
      check(H.typeOnGrid(game, joinCode:sub(1, 3)),
            "the code grid takes characters mid-entry")
      U.shot(game, SHOT_DIR .. "/join-code-typing.png")
      check(H.clearGrid(game, codeScreen), "and B erases them again")
    end

    local wrong = H.wrongCode(joinCode)
    check(H.enterJoinCode(game, wrong),
          "a wrong code can be typed on the grid")
    local refused = H.waitSeconds(game, function()
      local top = H.top(game)
      return top ~= nil and H.textOf(top):find("not accepted", 1, true) ~= nil
    end, 60, "the refusal")
    check(refused, "a wrong join code is refused, and says so on screen")
    check(exports.isConnected() == false, "and leaves us outside")
    -- printed: the refusal's whole value as a picture is the sentence the
    -- hub sent, and the frame after the box opens carries three words of it
    H.shotPrinted(game, SHOT_DIR .. "/join-code-refused.png")

    check(H.enterJoinCode(game, joinCode),
          "and the host's code can be typed on the same grid")
    U.wait(60)
  end

  -- the hub has to accept, challenge and welcome, so: seconds
  local connected = H.waitSeconds(game, function() return exports.isConnected() end,
                                  60, "the connection to open")
  check(connected, "joined over a real socket")
  if not connected then
    -- Transport puts a player-facing sentence in the box on failure, so the
    -- screenshot is the diagnosis: "can't reach ...", a bad address, or a
    -- naming screen that never confirmed at all
    U.shot(game, SHOT_DIR .. "/join-FAILED.png")
    log("top state after the attempt:",
        tostring(H.top(game) and (H.top(game).title or "?")))
  end
  check(exports.isHosting() == false, "and is not the host")
  -- A first visit claims this trainer name and is handed the ticket to come
  -- back with; the reconnect at the end of the run is where that ticket is
  -- actually put to the test.
  if connected then
    check(exports.isRanked(), "and is scored under this trainer name")
  end
  if not connected then
    log("RESULT " .. failures .. " failure(s)")
    return
  end

  H.closeToOverworld(game)

  -- ------- the host is a player over here too

  local sawHost = H.waitSeconds(game, function()
    return #exports.players() > 0
  end, 60, "the host to appear on the roster")
  check(sawHost, "the host appears on the guest's roster")
  if sawHost then
    log("host is", tostring(exports.players()[1].name))
  end
  U.wait(90)
  U.shot(game, SHOT_DIR .. "/join-sees-host.png")

  -- ------- walk, so the host has movement to observe
  --
  -- This is the avatar path end to end: these steps become presence
  -- messages, and the host turns them into scriptMove on a spawned NPC.

  for _ = 1, 3 do
    U.hold(game, "down", 20)
    U.wait(10)
    U.hold(game, "right", 20)
    U.wait(10)
  end
  log("walked")
  U.shot(game, SHOT_DIR .. "/join-after-walk.png")

  -- ------- 2. the host's movement reaches this side
  --
  -- The mirror of the host's own check: the host is a player here like any
  -- other, and its avatar has to walk here too.

  H.await(game, "host_walk_start")
  local before = H.avatarRow(exports)
  local fromX, fromY = before and before.rosterX, before and before.rosterY
  log(("host baseline (%s,%s)"):format(tostring(fromX), tostring(fromY)))
  H.signal("guest_baseline_taken")

  -- ------- 2b. the pace flag reaches this side too
  --
  -- The host holds B for every step of the walk it is about to do (see
  -- mmo_host.lua), so this side's copy of its roster row should say
  -- fast=true for at least part of that window. Sampled here rather than
  -- after the fact: the flag is "my last committed step was a fast one"
  -- (src/Client.lua), so it is only ever true while a fast step is actually
  -- in flight and clears on the very next ordinary step -- there is no
  -- lingering copy to check once the barrier below has already cleared.
  --
  -- Held B is only one of the two ways to earn the flag; the bike is the
  -- other, and it is covered at the unit tier rather than here, where
  -- getting a bicycle into the bag would be most of the run.
  --
  -- Deliberately not a speed measurement: this only asks whether the flag
  -- crossed the wire at all, not how fast the avatar moved while it was up.
  local sawHostFast = false
  local runSamples = 0
  local function sampleHostFast()
    local row = H.avatarRow(exports)
    if row == nil then return end
    runSamples = runSamples + 1
    if row.fast then sawHostFast = true end
  end
  H.await(game, "host_walk_done", nil, sampleHostFast)
  check(sawHostFast,
        ("the host's avatar row showed fast=true while B was held "
          .. "(%d sample(s) taken)"):format(runSamples))

  local hostMoved = H.waitSeconds(game, function()
    local row = H.avatarRow(exports)
    return row and (row.rosterX ~= fromX or row.rosterY ~= fromY)
  end, 45, "the host to move on this side")
  check(hostMoved, "the host's movement reaches the guest")

  local hostAvatarFollowed = H.waitSeconds(game, function()
    local row = H.avatarRow(exports)
    return row and row.spawned
      and math.abs((row.avatarX or -99) - row.rosterX) < 0.01
      and math.abs((row.avatarY or -99) - row.rosterY) < 0.01
  end, 45, "the host's avatar to catch up")
  check(hostAvatarFollowed, "and its avatar walks to where the host is")
  U.shot(game, SHOT_DIR .. "/join-host-walked.png")

  -- ------- 3. chat crosses the wire in both directions

  local heardHost = H.waitSeconds(game, function()
    for _, line in ipairs(exports.chat()) do
      if line.text == "HELLO FROM HOST" then return true end
    end
    return false
  end, 90, "the host's chat line")
  check(heardHost, "the host's chat arrived")

  exports.say("global", "HELLO FROM GUEST")
  log("said hello")
  U.wait(60)

  -- Joining changes what *this* player sees too, not just what the host
  -- sees. Checked before the map change below so the leave check at the
  -- end cannot pass vacuously on a look that was never worn.
  --
  -- Not an identity check against ownSheet any more: connect() calls
  -- applyLook unconditionally (src/Client.lua's connect), which always
  -- builds a fresh SpriteRenderer, so a plain `~= ownSheet` would be true
  -- here even if joining changed nothing -- and now that an explicit choice
  -- is worn offline too, ownSheet was already this same character before
  -- dialling. What says the join genuinely worked is the sheet still
  -- matching the chosen id, not merely being a different table.
  local wornOk, wornLook, wornImage = H.wornMatches(game, exports)
  log("worn after joining:", tostring(wornLook), tostring(wornImage))
  check(wornOk,
        "joining leaves the player genuinely drawn as their chosen character")

  -- ------- invite refuse (focused e2e; see run-invite-refuse-e2e.sh)
  --
  -- Host stages a trainer battle first; we ask via PLAYERS > BATTLE. Do
  -- not drivePrompts across the waiting box -- its only row is CANCEL and
  -- would take the ask back before the host's auto-refuse can answer.
  if os.getenv("MMO_INVITE_REFUSE_E2E") == "1" then
    H.await(game, "host_in_fight")
    local asked = false
    if H.openMmo(game) and H.selectLabel(game, "PLAYERS") then
      if H.selectLabel(game, "HOSTY") then
        asked = H.selectLabel(game, "BATTLE") and true or false
        check(asked, "asked HOSTY to battle while they fight")
      else
        check(false, "found HOSTY on the PLAYERS list")
      end
    else
      check(false, "opened PLAYERS to ask for a battle")
    end
    if asked then
      H.signal("guest_asked_battle_in_fight")
      local refused = H.waitSeconds(game, function()
        local text = (H.textOf(H.top(game)) or ""):lower()
        return text:find("refused", 1, true) ~= nil
      end, 60, "HOSTY refused to battle")
      check(refused, "saw the battle refusal after asking mid-fight")
      check(not (exports.isSessionBusy and exports.isSessionBusy()),
            "the outgoing ask is cleared after the refusal")
      U.shot(game, SHOT_DIR .. "/join-invite-refused.png")
      H.signal("guest_saw_battle_refusal")
    else
      H.signal("guest_asked_battle_in_fight")
      H.signal("guest_saw_battle_refusal")
    end
    H.closeToOverworld(game)
    log("DONE")
    return
  end

  -- ------- 1. leave the map and come back

  local home = mod_current(game)
  U.teleport(game, "PALLET_TOWN", 5, 6, "down")
  U.wait(60)
  log("left for PALLET_TOWN")
  H.signal("guest_left_map")

  H.await(game, "host_saw_despawn")
  U.teleport(game, home.mapId, home.x, home.y, "down")
  U.wait(60)
  log("back on " .. tostring(home.mapId))

  -- A map change re-wears the look, and the overworld usually hands back the
  -- same player object when it does. That is where the trainer sheet used to
  -- be lost: it was replaced with the mod's own renderer, and leaving then
  -- "restored" the player to the character they picked for the hub.
  --
  -- Object-identity-free for the same reason as the join check above: a
  -- rewear rebuilds the renderer regardless of whether the character
  -- changed, so what a map change has to leave intact is which character
  -- the sheet draws from, not the table it happens to live in this frame.
  local stillOk, stillLook, stillImage = H.wornMatches(game, exports)
  log("worn after the map change:", tostring(stillLook), tostring(stillImage))
  check(stillOk, "still wearing the chosen character after a map change")

  -- The guest's own character, in the world, facing the camera. Here for the
  -- same reason the host's is where it is: the guest has just teleported
  -- home, so the host is not on this map and no nameplate is over it.
  local shownLook = H.shotLook(game, SHOT_DIR .. "/join-overworld-look.png")
  log("overworld look:", tostring(shownLook))
  check(shownLook ~= nil, "the character is on screen in the overworld")

  -- Same check the host makes, from the other side: the front pic, which no
  -- screen in either flow used to open. Here rather than earlier because the
  -- look has just survived a map change, so the pic is being read at the
  -- point the sprite has already proved it is still worn.
  local guestCard = H.shotTrainerCard(game, SHOT_DIR .. "/join-trainer-card.png")
  local wearing = exports.wornLook and exports.wornLook() or nil
  log("trainer card pic:", tostring(guestCard), "wearing", tostring(wearing))
  check(type(guestCard) == "string" and guestCard ~= "",
        "the trainer card resolves a pic to draw")
  if tostring(wearing):find("SPRITE_NIRE", 1, true) then
    check(tostring(guestCard):find("assets/chars/", 1, true) ~= nil,
          "and a character the mod brought draws its own")
  end

  H.signal("guest_back_on_map")

  -- ------- 4. interact with the host, and get the trade/battle menu

  H.await(game, "host_ready_for_interact")
  local hostRow = H.avatarRow(exports)
  check(hostRow ~= nil and hostRow.rosterX ~= nil,
        "the host has a cell to stand next to")

  -- ------- non-blocking avatars: walk straight through the host's own tile
  --
  -- The host is stood still for the whole interact leg below -- it is
  -- blocked on H.await("guest_interact_done") the entire time -- which
  -- makes this the one place in the flow where a "the stander never moves"
  -- assumption is actually true rather than merely likely. Section 2 above
  -- already proved this exact row walkable end to end: the host held here
  -- after two lefts and a right along it, each one a real keypress the
  -- engine's own collision accepted. Putting the walker on one proven-clear
  -- tile and stepping it across the host's cell to the next isolates
  -- exactly the one variable this driver can reach: whether an avatar
  -- sitting on a tile refuses the step onto it. Pre-fix, Collision.canMove
  -- answers "entity" and the walker never arrives; post-fix it crosses like
  -- any other floor tile, the same mechanism a door tile reduces to.
  --
  -- The crossing runs west, because that is the direction the host's own
  -- walk actually proved: its two lefts covered spawn->spawn-1 and
  -- spawn-1->spawn-2 leftward, so both tile *pairs* on this path have
  -- passed the engine's real collision in the direction used here. The
  -- eastward pair past the stander never was, and in practice something
  -- east of it refuses the step -- tile pairs are directional (ledges),
  -- so a row proven one way is only proven that way.
  if hostRow and hostRow.rosterX then
    local standerX, standerY = hostRow.rosterX, hostRow.rosterY
    U.teleport(game, hostRow.map, standerX + 1, standerY, "left")
    U.wait(30)
    local walkerStart = H.playerCell(game)
    check(walkerStart ~= nil and walkerStart.x == standerX + 1
          and walkerStart.y == standerY,
          "walker starts one tile short of the stander")

    U.hold(game, "left", 22)
    U.wait(8)
    local onStander = H.waitSeconds(game, function()
      local cell = H.playerCell(game)
      return cell ~= nil and cell.x == standerX and cell.y == standerY
    end, 20, "the walker to step onto the stander's own tile")
    check(onStander,
          "the walker's own position reached the tile the stander occupies")

    U.hold(game, "left", 22)
    U.wait(8)
    -- "at or beyond", not "exactly at": a 22-frame hold can land two steps,
    -- and a poll that demands one transient cell misses the crossing it is
    -- there to prove. Ending further west is stronger evidence, not a miss.
    local pastStander = H.waitSeconds(game, function()
      local cell = H.playerCell(game)
      return cell ~= nil and cell.x <= standerX - 1 and cell.y == standerY
    end, 20, "the walker to continue past the stander's tile")
    check(pastStander,
          "and kept walking through it rather than stopping on it")

    local walkerEnd = H.playerCell(game)
    log(("walk-through: stander at (%s,%s), walker (%s,%s) -> (%s,%s)"):format(
      tostring(standerX), tostring(standerY),
      tostring(walkerStart and walkerStart.x), tostring(walkerStart and walkerStart.y),
      tostring(walkerEnd and walkerEnd.x), tostring(walkerEnd and walkerEnd.y)))

    local standerAfter = H.avatarRow(exports)
    check(standerAfter ~= nil and standerAfter.rosterX == standerX
          and standerAfter.rosterY == standerY,
          "the walk-through left the stander's avatar exactly where it stood")
    U.shot(game, SHOT_DIR .. "/join-walked-through-host.png")
  end

  if hostRow and hostRow.rosterX then
    -- stand directly below the host and face up at them
    U.teleport(game, hostRow.map, hostRow.rosterX, hostRow.rosterY + 1, "up")
    U.wait(90)

    local facing = H.waitSeconds(game, function()
      local row = H.avatarRow(exports)
      return row and row.spawned
        and math.abs((row.avatarX or -99) - hostRow.rosterX) < 0.01
        and math.abs((row.avatarY or -99) - hostRow.rosterY) < 0.01
    end, 60, "the host's avatar to settle on its cell")
    check(facing, "the host's avatar is on the cell we are facing")

    U.shot(game, SHOT_DIR .. "/join-before-interact.png")
    U.tap(game, "a")
    U.wait(60)

    local top = H.top(game)
    local labels = {}
    for _, item in ipairs((top and top.items) or {}) do
      labels[#labels + 1] = tostring(item.label)
    end
    log("interact menu:", table.concat(labels, ","))

    local function has(want)
      for _, label in ipairs(labels) do
        if label == want then return true end
      end
      return false
    end

    check(#labels > 0, "pressing A on another player opens a menu")
    check(has("TRADE"), "the menu offers TRADE")
    check(has("BATTLE"), "the menu offers BATTLE")
    check(has("PROFILE"), "and PROFILE, on top")
    U.shot(game, SHOT_DIR .. "/join-interact-menu.png")

    -- The card: their name and their trainer stats, sent when they joined.
    if H.selectLabel(game, "PROFILE") then
      U.wait(40)
      local card = H.top(game)
      check(card ~= nil and card.player ~= nil, "the profile card opened")
      if card and card.player then
        log("card for", tostring(card.player.name),
            "look", tostring(card.player.sprite),
            "badges", tostring(card.player.profile and card.player.profile.badges))
        check(card.player.name == "HOSTY", "showing the right trainer")
        check(card.player.profile ~= nil,
              "with the trainer card they sent on joining")
      end
      U.shot(game, SHOT_DIR .. "/join-profile-card.png")
      H.assertPortraitColors(game, SHOT_DIR .. "/join-profile-card.png",
        116, 52, 32, 32, check,
        "the remote trainer card portrait is palette-correct")
      U.tap(game, "b")     -- back to the interact menu
      U.wait(30)
      check(H.classify(H.top(game)) == "menu", "and B returns to the menu")
    else
      check(false, "could not open PROFILE")
    end

    -- ------- 4b. the host changes character mid-session; watch it land here
    --
    -- The mirror of mmo_host.lua's own leg of the same name: it waits on
    -- `guest_interact_done` (signalled just below) before touching its
    -- menu, then signals `host_char_changed` once its own worn look proves
    -- the pick landed, and waits on `guest_saw_char_change` before moving
    -- on to the trade.
    --
    -- **The baseline is read before the barrier, not after it, and the poll
    -- is for the id rather than for "different".** This is the one "did the
    -- peer's change reach me" check in this file where the barrier cannot be
    -- a fence: mmo.sprite goes out at the instant the host's own look moves,
    -- so it is already on this side's roster by the time
    -- `host_char_changed` -- which the host writes a second later, after
    -- closing its menus -- shows up here. A baseline sampled after that
    -- barrier is the *new* value, and "wait for it to differ from itself"
    -- can only ever time out. So the sample is taken on the way in, a
    -- second before the host is even told it may pick, and the assertion
    -- names SPRITE_NIRE outright: an absolute answer cannot be raced, and
    -- the baseline's job shrinks to proving there was something to change
    -- from.
    local function watchHostCharChange(before)
      local beforeSprite = before and before.sprite
      check(beforeSprite ~= nil and beforeSprite ~= "SPRITE_NIRE",
            "the host is on the roster as somebody other than NIRE to begin with")

      H.await(game, "host_char_changed")

      local sawRoster, sawAvatar = false, false
      H.waitSeconds(game, function()
        local player = exports.players()[1]
        local avatar = H.avatarRow(exports)
        sawRoster = player ~= nil and player.sprite == "SPRITE_NIRE"
        sawAvatar = avatar ~= nil and avatar.sprite == "SPRITE_NIRE"
        return sawRoster and sawAvatar
      end, 45, "the host's character change to reach the guest")

      check(sawRoster, "the host's roster row picked up the character they chose")
      check(sawAvatar,
            "and the respawned avatar row shows that character too")
      if sawRoster and sawAvatar then
        U.shot(game, SHOT_DIR .. "/join-host-recharacter.png")
      end

      H.signal("guest_saw_char_change")
    end

    -- ------- 5. take the menu up on it: a real trade, end to end
    --
    -- Everything past here runs the engine's own TradeSession over the
    -- hub: the party goes on the wire, both sides pick and confirm, and
    -- TradeSession:apply files the received mon. Nothing about the trade
    -- itself is this mod's code.

    -- Sampled here, one line above the barrier that lets the host start
    -- picking, and never after it: see watchHostCharChange's header for why
    -- a baseline read on the far side of `host_char_changed` is already the
    -- answer it is supposed to be measured against.
    local hostCharBefore = H.avatarRow(exports)
    H.signal("guest_interact_done")
    watchHostCharChange(hostCharBefore)
    -- likewise: never ask somebody who is mid-session
    H.waitSeconds(game, function()
      local row = H.avatarRow(exports)
      return row ~= nil and not row.busy
    end, 45, "the host to be free")
    if H.selectLabel(game, "TRADE") then
      log("asked to trade")
      H.signal("guest_trade_requested")

      local wanted = "CHARIZARD"
      -- seconds, and it must match the host's own trade budget: the two are
      -- driving one flow, and whichever gives up first abandons the other
      local record, prompts = H.promptLog()
      local traded, trail = H.drivePrompts(game, function()
        return H.partySpecies(game)[1] == wanted
      end, 120, record)
      log("guest party now:", table.concat(H.partySpecies(game), ","))
      if not traded then
        -- the same diagnosis the host prints, which this side was missing:
        -- "the trade did not happen" cannot distinguish a prompt that never
        -- arrived from one that was answered and went nowhere
        log("trade stalled -- prompts answered:", trail == "" and "(none)" or trail,
            "top is", tostring(H.top(game) and (H.top(game).title or "?")))
        log("  boxes:", table.concat(prompts, " | "))
      end
      check(traded, "the guest received the host's " .. wanted)
      U.shot(game, SHOT_DIR .. "/join-after-trade.png")
      H.await(game, "host_trade_done")

      -- ------- 6. and a real link battle, to a decision
      --
      -- Both sides now hold the mon the other traded over, so the battle
      -- also proves the traded party is what actually fights.

      H.closeToOverworld(game)

      -- Wait for the other side to be free before asking again.
      --
      -- Sessions:onRequest answers immediately with a decline when the
      -- target is already in one -- correct behaviour, since a prompt that
      -- surfaced minutes later over whatever they were doing is worse. But
      -- it means a battle asked for while the trade is still tearing down
      -- is refused, and the run then waits for a battle that was never
      -- going to start. The roster carries their busy flag, so wait on it
      -- rather than on a guessed interval.
      local free = H.waitSeconds(game, function()
        local row = H.avatarRow(exports)
        return row ~= nil and not row.busy
      end, 60, "the host to finish the trade")
      if not free then log("WARN host still busy; asking anyway") end
      U.wait(30)
      local reopened = false
      if H.top(game) == nil or H.top(game).isOverworld
         or H.top(game) == game.overworld then
        U.tap(game, "a")   -- still facing the host's avatar
        U.wait(45)
        reopened = H.classify(H.top(game)) == "menu"
      end
      check(reopened, "the interact menu opens again for a battle")

      if reopened and H.selectLabel(game, "BATTLE") then
        log("asked to battle")
        H.signal("guest_battle_requested")

        local started = H.drivePrompts(game, function()
          return events["battle.started"] > 0
        end, 90)
        check(started, "a link battle started on the guest")

        local ended = H.drivePrompts(game, function()
          return events["battle.ended"] > 0
        end, 240)
        check(ended, "and ran to a decision")
        check(events["link.desync"] == 0, "with no desync reported")
        log(("battle events: started=%d ended=%d desync=%d"):format(
          events["battle.started"], events["battle.ended"],
          events["link.desync"]))
        U.shot(game, SHOT_DIR .. "/join-after-battle.png")
        H.await(game, "host_battle_done")

        -- ------- and the ranking moved with it
        --
        -- The guest sees the same settlement the host does: whoever won,
        -- the hub told both sides, and the leaderboard has the winner on
        -- it. Which of the two it is, is the engine's business.
        H.closeToOverworld(game)
        H.rankAfterBattle(game, exports, check)
        if H.openMmo(game) then
          U.wait(25)
          H.shotRank(game, SHOT_DIR .. "/join-rank.png", check)
        end
        H.closeToOverworld(game)

        -- ------- 6b. a co-op battle, over the *in-game* hub
        --
        -- The guest's half. See the host driver's matching leg for why this
        -- one is worth having at all: every co-op battle ever fought had been
        -- relayed by server/lib/relay.js, and `src/Hub.lua` -- running inside
        -- the other game -- had never carried one.

        -- Standing still, and *then* the host may ask.
        --
        -- closeToOverworld gets out of a screen by pressing B, and an invite
        -- that arrives while it is doing that is a box in the way -- so B
        -- answers it, which on a confirm means no. The invite went out, the
        -- guest declined it a frame later without anybody seeing the box, and
        -- the party simply never formed. A barrier rather than a longer wait,
        -- because the race is about order and not about speed.
        H.signal("guest_ready_for_party")
        H.await(game, "host_party_asked")
        local paired = H.drivePrompts(game, function()
          return #exports.party() == 2
        end, 120)
        check(paired, "the party formed on the guest over the in-game hub")
        local members = {}
        for _, member in ipairs(exports.party()) do
          members[#members + 1] = tostring(member.name)
        end
        log("party members:", table.concat(members, ","))
        H.signal("guest_party_joined")

        -- The same trainer, staged here too: the offer names a *fight*, and
        -- joining one you are not standing at is exactly what the hub refuses.
        local coopClass = H.coopTrainer(game.data)
        local coopFinished = nil
        -- The real BattleState this side staged, held onto (not just the
        -- result callback above) so it can be checked for gone-from-the-stack
        -- rather than merely told-its-result once the co-op leg is over --
        -- see the comment on the `handed`/onStack pair below for why both
        -- matter. This is the joining side, the role the leaked-screen bug
        -- actually hit: `self.encounter` for a join never carried this
        -- battle's engine reference until the fix, so this is the instance
        -- that would have caught it.
        local staged = nil
        H.await(game, "host_coop_waiting")
        if coopClass then
          staged = H.stageTrainer(game, coopClass,
                                   function(result) coopFinished = result end)
          -- Walking into the same trainer is how the offer is met: the prompt
          -- this side gets is the join, not the wait/alone.
          local offered = H.waitSeconds(game, function()
            return exports.coopOffer() ~= nil
          end, 90, "the partner's offer to reach this side")
          check(offered, "the waiting partner's offer reaches the guest")
          local offer = exports.coopOffer()
          if offer then log("offer from:", tostring(offer.name),
                            "battle:", tostring(offer.battle)) end
        end

        -- Say yes to whatever is in front of us until four monsters are up.
        local joined = H.drivePrompts(game, function()
          local top = H.top(game)
          return top ~= nil and top.sim ~= nil and #top.sim.slots == 4
        end, 180)
        check(joined, "a four-slot co-op battle is on screen, over the LAN hub")
        U.wait(30)
        U.shot(game, SHOT_DIR .. "/join-coop-battle.png")
        check(exports.coopDrawFailed() == false, "and it drew without error")
        H.signal("guest_coop_joined")

        local over = H.drivePrompts(game, function()
          local top = H.top(game)
          return top == nil or top.sim == nil
        end, 300, function() U.tap(game, "a") end)
        check(over, "the 2-on-2 runs to an end over the in-game hub")
        local sync = exports.coopSync()
        log(("coop sync: gaps=%d desyncs=%d resyncs=%d"):format(
          sync.gaps, sync.desyncs, sync.resyncs))
        check(sync.gaps == 0, "with no turn lost by the Lua hub")
        check(sync.desyncs == 0, "and no drift from the host's copy")
        check(sync.resyncs == 0, "and never needing the field re-sent")

        -- Frames, not seconds, and deliberately so -- this is not a wait on
        -- the host the way a PHASE barrier is (see "phase barriers" in
        -- mmo_util.lua). CoopBattle:finish pops its own screen; StateStack:pop
        -- removes it and only then calls exit(), which is what reaches
        -- M:onBattleOver and, through M:consume, `engine.onFinish` -- all
        -- inside the one synchronous call that took the co-op screen off the
        -- stack. If `coopFinished` is ever going to be set, it already is by
        -- the time `over` above went true, so a 60-second budget here only
        -- meant a genuinely broken handoff took a minute to report as broken.
        local handed = H.waitFor(game, function()
          return coopFinished ~= nil
        end, 10, "the engine's battle to be finished off")
        check(handed, "and the trainer battle it displaced got its result back")
        log("co-op result:", tostring(coopFinished))

        -- The bug this leg exists to catch, and why `handed` above is not
        -- enough by itself: CoopBattle:finish only ever pops its *own*
        -- screen. Before the fix, the trainer battle staged above -- this is
        -- the joining side, exactly the role the bug hit -- was never
        -- unwound off the stack. It sat there the whole fight, underneath
        -- the co-op screen, one slot down and invisible to a check that only
        -- ever asks what is on top. `coopFinished` could come back non-nil,
        -- a real handoff, while a second, real fight against the same
        -- trainer was still sitting on the stack waiting for input.
        --
        -- Checked here, before the drivePrompts below presses a single
        -- button: that drive answers whatever is on top with A, and a real
        -- trainer battle is itself a sequence of prompts -- FIGHT, a move, a
        -- target -- so a leaked one would be fought through in total silence
        -- and still end up back in the overworld. That is exactly how this
        -- bug could pass a check that only looked at the end state.
        check(not H.onStack(game, staged),
              "the trainer battle this side staged is off the stack, not "
              .. "merely buried under the co-op screen")

        H.drivePrompts(game, function()
          local top = H.top(game)
          return top == nil or top == game.overworld or top.isOverworld
        end, 120)
        -- And the overworld that drive reached for is genuinely the
        -- overworld -- the other half of the same claim, now that nothing is
        -- left buried for it to be hiding under (checked above, before
        -- anything here got a chance to fight it through).
        local top = H.top(game)
        check(top == game.overworld or (top and top.isOverworld) == true,
              "and the overworld -- not a leaked trainer battle -- is what's "
              .. "actually on top, over the in-game hub too")
        H.closeToOverworld(game)
        U.shot(game, SHOT_DIR .. "/join-coop-after.png")
        H.signal("guest_coop_done")
        H.await(game, "host_coop_done")

        -- One member leaving ends the party for both, so this side only has
        -- to watch it empty.
        H.await(game, "host_coop_left")
        local emptied = H.waitSeconds(game, function()
          return #exports.party() == 0
        end, 60, "the party to end for this side too")
        check(emptied, "and the party ends for both when one of them leaves")
        H.closeToOverworld(game)

        -- ------- 7. leave the game and keep playing
        --
        -- Walking out of someone else's game is not quitting: the save,
        -- the world and the party are untouched, so single-player carries
        -- straight on. That last part is the whole point of the check --
        -- disconnecting cleanly is easy, staying playable afterwards is
        -- where a teardown bug would show.

        H.await(game, "host_address_checked")
        H.closeToOverworld(game)
        local opened = H.openMmo(game)
        if opened then
          U.wait(25)
          U.shot(game, SHOT_DIR .. "/join-mmo-menu.png")
          if H.selectLabel(game, "CHAT") then
            U.wait(35)
            U.shot(game, SHOT_DIR .. "/join-chat-log.png")
            U.tap(game, "b")   -- CHAT's onCancel puts the MMO menu back
            U.wait(25)
          end
        end
        -- Read *before* the LEAVE, and that is the whole point of where it
        -- sits: disconnecting clears the rating off this player's own screen
        -- deliberately -- a rating is a fact about a hub, and there is no hub
        -- to have one on once you have left -- so a copy taken afterwards is
        -- always zero and would compare a rejoining player against nothing.
        local pointsBefore = exports.points()
        log("points while still in the game:", tostring(pointsBefore))

        if opened and H.selectLabel(game, "LEAVE") then
          H.drivePrompts(game, function()
            return not exports.isConnected()
          end, 60)
          check(not exports.isConnected(), "LEAVE disconnects the guest")
          check(not exports.isHosting(), "without it having been the host")
          check(#exports.players() == 0, "and clears the roster")

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
          local after = H.playerCell(game)
          log(("after leaving: (%s,%s) -> (%s,%s)"):format(
            tostring(before and before.x), tostring(before and before.y),
            tostring(after and after.x), tostring(after and after.y)))
          check(after and before
                and (after.x ~= before.x or after.y ~= before.y),
                "and the world is still playable afterwards")
          check(#H.partySpecies(game) > 0, "with the party intact")
          -- The new contract: leaving keeps the standing choice worn
          -- rather than handing the vanilla trainer back. disconnect() now
          -- calls syncLook(), not restoreLook() (src/Client.lua's
          -- disconnect), so a player with an explicit choice -- this
          -- guest's MMO_GUEST_SPRITE, never RED -- wears it forever, in or
          -- out of a game. What proves that: wornLook() still names the
          -- same chosen sprite it did right after joining, and the sheet on
          -- screen still draws it -- not by identity, since syncLook's
          -- applyLook builds a new renderer on the way out exactly as it
          -- did on the way in.
          local afterLeaveOk, afterLeaveLook, afterLeaveImage =
            H.wornMatches(game, exports)
          log("worn after leaving:", tostring(afterLeaveLook),
              tostring(afterLeaveImage))
          check(afterLeaveLook == wornLook,
                "wornLook() still reports the same standing choice after "
                  .. "leaving")
          check(afterLeaveOk,
                "and the rendered sheet still matches it, not merely "
                  .. "undressed")
          U.shot(game, SHOT_DIR .. "/join-after-leaving.png")

          -- ------- 8. and back again, as the same player
          --
          -- The claim ticket, end to end and through the real menus, which
          -- is the only place it can be seen working.
          --
          -- A rating is filed under a trainer name, so the hub minted a
          -- secret the first time it saw this one, sent it once in the
          -- welcome, and kept only its hash. Every link after that lives in
          -- a different file: the client had to store it under the address
          -- it dialled, read it back for the *same* address, put it on the
          -- next hello, and the hub had to match it against a digest it
          -- loaded rather than the token it minted.
          --
          -- Break any one of those and nothing errors -- the player is
          -- simply not scored any more, quietly, under their own name. So
          -- what is asserted is `isRanked` on the *second* connection: the
          -- name is claimed by then, and the only thing that can produce a
          -- true there is a ticket that survived the whole round trip.
          check(exports.points() == 0,
                "leaving takes the rating off this player's own screen")

          if H.rejoin(game, exports, joinCode, check, log) then
            check(exports.isRanked(),
                  "reconnecting under a claimed name is recognised as the "
                  .. "same player -- the ticket made the round trip")
            check(exports.points() == pointsBefore,
                  ("and the rating came back with them (%s)")
                    :format(tostring(exports.points())))
            U.shot(game, SHOT_DIR .. "/join-reconnected.png")

            -- ...and out again, so the host's own teardown checks see the
            -- roster empty exactly as they did before this leg existed.
            H.closeToOverworld(game)
            if H.openMmo(game) and H.selectLabel(game, "LEAVE") then
              H.drivePrompts(game, function()
                return not exports.isConnected()
              end, 60)
            end
            check(not exports.isConnected(), "and left again cleanly")
            H.closeToOverworld(game)

            -- ------- 9. and back a THIRD time, through SERVERS
            --
            -- The row this whole leg exists to prove: the hub this player
            -- was just welcomed by twice is now on START > MMO > SERVERS,
            -- named after its own address (src/Servers.lua's default), and
            -- CONNECT on its submenu is the whole join -- CHARSET to confirm
            -- who is connecting, then a dial with the address and code
            -- already filled in from the entry, no grids in between. Same
            -- assertions H.rejoin's second connection made: a claimed name
            -- is recognised again, and the rating is still attached to it.
            --
            -- The list this leg is about to walk, read off the store first.
            -- Two welcomes off one address are one row, and that row's
            -- `address` is the whole dialable string whatever the row is
            -- *named* -- the name has the standard port left off, which is
            -- what H.serverLabel reconstructs below. A second row here would
            -- mean the same hub was filed under two keys.
            check(type(exports.servers) == "function",
                  "the mod publishes its server list to other mods")
            local stored = (type(exports.servers) == "function"
                            and exports.servers()) or {}
            check(#stored == 1,
                  ("two connections to one hub leave exactly one SERVERS row "
                   .. "(got %d)"):format(#stored))

            -- What this player actually dialled, which is *not* what the host
            -- published: the host reads its LAN IP out (HostServer:address),
            -- while this side has been dialling the loopback address the
            -- wrapper wrote into its options, both times. Only asserted when
            -- the wrapper is the one running this -- a hand-driven run sets no
            -- such variable, and the row itself is then the only witness of
            -- what was dialled.
            local wrapperDialled = os.getenv("MMO_JOIN_ADDRESS")
            if wrapperDialled then
              check(stored[1] and stored[1].address == wrapperDialled,
                    ("and it holds the address that was dialled -- %s (row "
                     .. "says %s)"):format(tostring(wrapperDialled),
                                    tostring(stored[1] and stored[1].address)))
            end
            local dialled = wrapperDialled
              or (stored[1] and stored[1].address) or hostAddress
            log("SERVERS row", tostring(stored[1] and stored[1].name),
                "at", tostring(stored[1] and stored[1].address),
                "dialled", tostring(dialled))

            if H.reconnectViaServers(game, exports, dialled, joinCode,
                                      check, log, SHOT_DIR) then
              check(exports.isRanked(),
                    "reconnecting through SERVERS is recognised as the "
                    .. "same player too")
              check(exports.points() == pointsBefore,
                    ("and the rating comes back with them again (%s)")
                      :format(tostring(exports.points())))
              U.shot(game, SHOT_DIR .. "/join-servers-reconnected.png")

              H.closeToOverworld(game)
              if H.openMmo(game) and H.selectLabel(game, "LEAVE") then
                H.drivePrompts(game, function()
                  return not exports.isConnected()
                end, 60)
              end
              check(not exports.isConnected(), "and left a third time cleanly")
              H.closeToOverworld(game)

              -- ------- 10. DELETE, behind a yes/no confirm
              --
              -- The same row the SERVERS leg above just dialled through,
              -- but this pass is destructive on purpose: reopen it, pick
              -- the entry, DELETE it, answer CONFIRM's box YES, and check
              -- both halves of what that promises -- the saved-history side
              -- (mod.exports.servers() empty) and the menu side (SERVERS
              -- stays reachable, with only the product-owned official row
              -- left behind). The featured row is deliberately outside the
              -- exported recents, so these two answers are meant to differ.
              local deleteLabel = H.serverLabel(exports, dialled)
              if H.openMmo(game) and H.selectLabel(game, "SERVERS")
                 and H.selectLabel(game, deleteLabel) then
                U.wait(20)
                if H.selectLabel(game, "DELETE") then
                  -- The text prints first and the choice box comes up
                  -- under it -- CONFIRM's own rhythm (src/Ui.lua's
                  -- SCREEN.CONFIRM). Wait for the box itself, not just
                  -- "a screen changed", so the photograph below is the
                  -- box and not the sentence still printing above it.
                  local confirmUp = H.waitFor(game, function()
                    return H.classify(H.top(game)) == "choice"
                  end, 90, "the DELETE confirm box")
                  check(confirmUp, "DELETE opens the yes/no confirm")
                  if confirmUp then
                    U.shot(game, SHOT_DIR .. "/servers-confirm.png")
                    -- YES is index 1 -- the same rule drivePrompts walks
                    -- the cursor to for every other choice box in this
                    -- suite (see M.drivePrompts above); walked by hand
                    -- here rather than through drivePrompts so the box
                    -- can be photographed before it is answered.
                    local box = H.top(game)
                    local guard = 0
                    while (H.top(game) == box) and (box.index or 1) > 1
                          and guard < 4 do
                      U.tap(game, "up")
                      U.wait(3)
                      guard = guard + 1
                    end
                    U.tap(game, "a")
                    U.wait(20)
                  end

                  local afterDelete = (type(exports.servers) == "function"
                                        and exports.servers()) or nil
                  check(type(afterDelete) == "table" and #afterDelete == 0,
                        "DELETE, confirmed, empties the saved server list "
                          .. ("(got %d row(s))")
                            :format(type(afterDelete) == "table"
                                    and #afterDelete or -1))

                  H.closeToOverworld(game)
                  if H.openMmo(game) then
                    local stillThere = false
                    for _, l in ipairs(H.menuLabels(game)) do
                      if H.labelMatches(l, "SERVERS") then stillThere = true end
                    end
                    check(stillThere,
                          "and the MMO menu still offers SERVERS after the "
                            .. "last saved server is deleted")
                    if stillThere then
                      local reachable = H.selectLabel(game, "SERVERS")
                      check(reachable,
                            "and that SERVERS row remains reachable")
                      if reachable then
                        local remaining = H.menuLabels(game)
                        check(#remaining == 1
                              and H.labelMatches(remaining[1],
                                                 "RBY MMO OFFICIAL"),
                              "with only RBY MMO OFFICIAL left at the top")
                      end
                    end
                  end
                  H.closeToOverworld(game)
                else
                  check(false, "DELETE is on the entry's own submenu")
                end
              else
                check(false, "SERVERS still opens, with the entry still on "
                               .. "it, after the third reconnect, for the "
                               .. "DELETE leg")
              end
            end
          end
        else
          check(false, "no LEAVE row while connected as a guest")
        end
        H.signal("guest_left_game")
      else
        check(false, "could not select BATTLE")
        H.signal("guest_battle_requested")
      end
    else
      check(false, "could not select TRADE")
      H.signal("guest_trade_requested")
    end
  else
    H.signal("guest_interact_done")
    -- No hostRow to stand next to, so nothing here can watch the host's
    -- character change land -- but the host is waiting on
    -- guest_saw_char_change regardless, and staying silent would only
    -- relocate this leg's failure onto a timeout over there instead of the
    -- "no interact target" failure this branch already means.
    H.signal("guest_saw_char_change")
    H.signal("guest_trade_requested")
  end

  -- ------- 9. the offline picker, fully disconnected
  --
  -- Everything above proves a chosen character survives a session; this
  -- proves there does not have to be one at all. The CHARACTER row is the
  -- fourth one on the offline MMO menu, after the always-available SERVERS
  -- row, reachable only while disconnected
  -- (src/Ui.lua's comment on the row explains why: the hub only learns a
  -- sprite at hello, so a mid-game swap would show everyone else the old
  -- one) -- and picking a character through it has to apply immediately,
  -- with no socket open anywhere.
  --
  -- Guarded rather than assumed: an earlier leg above may have left this
  -- guest connected (a failed TRADE/BATTLE select, say), and this leg would
  -- otherwise not find the row it is looking for and fail for a confusing
  -- reason. Forcing the disconnect here keeps the failure, if there is one,
  -- about the picker rather than about state this leg did not create.
  if exports.isConnected() or exports.isHosting() then
    H.closeToOverworld(game)
    if H.openMmo(game) and H.selectLabel(game, "LEAVE") then
      H.drivePrompts(game, function() return not exports.isConnected() end, 60)
    end
  end
  check(not exports.isConnected() and not exports.isHosting(),
        "fully offline before driving the picker")

  if H.openMmo(game) then
    U.wait(20)
    local labels = H.menuLabels(game)
    log("offline MMO menu:", table.concat(labels, ","))
    check(labels[1] == "SERVERS" and labels[2] == "HOST GAME"
          and labels[3] == "JOIN GAME" and labels[4] == "CHARACTER",
          "the offline menu offers SERVERS, HOST GAME, JOIN GAME, then CHARACTER")
    U.shot(game, SHOT_DIR .. "/join-mmo-menu-offline.png")

    -- Cancelling out of the picker without choosing has to return to this
    -- menu, not the TRAINER screen the HOST/JOIN flows share -- CHARPICK's
    -- `backTo` opt is what tells the two doors apart (src/Ui.lua's CHARPICK
    -- screen), and this is the one driver exchange that opened it directly
    -- rather than through CHARSET.
    if check(H.selectLabel(game, "CHARACTER"), "CHARACTER opens the picker") then
      U.wait(20)
      check(H.classify(H.top(game)) == "menu", "the character picker opened")
      U.shot(game, SHOT_DIR .. "/join-charpick.png")
      U.tap(game, "b")
      U.wait(20)
      local backLabels = H.menuLabels(game)
      check(backLabels[1] == "SERVERS",
            "cancelling the picker returns to the MMO menu, not TRAINER")

      -- Now actually choose one -- NIRE, not the guest's own
      -- MMO_GUEST_SPRITE choice, so the sheet is provably a different
      -- character afterwards rather than the same one picked again.
      local beforeLook = exports.wornLook and exports.wornLook() or nil
      if check(H.selectLabel(game, "CHARACTER"),
               "CHARACTER opens the picker again") then
        U.wait(20)
        local picked = H.selectLabel(game, "NIRE")
        check(picked, "NIRE is a row in the offline picker")
        U.wait(20)
        check(H.classify(H.top(game)) == "menu"
              and H.menuLabels(game)[1] == "SERVERS",
              "choosing a character returns to the MMO menu")

        local afterLook = exports.wornLook and exports.wornLook() or nil
        log("offline pick:", tostring(beforeLook), "->", tostring(afterLook))
        check(afterLook == "SPRITE_NIRE",
              "the offline pick is worn as the standing choice immediately")

        local pickOk, pickLook, pickImage = H.wornMatches(game, exports)
        log("worn after the offline pick:", tostring(pickLook),
            tostring(pickImage))
        check(pickOk and pickLook ~= beforeLook,
              "and the rendered sheet actually changed, with no connection "
                .. "open")
      end
    end
  else
    check(false, "could not reach the MMO menu offline")
  end
  H.closeToOverworld(game)

  -- Every marker this side owns, dropped whatever happened above.
  --
  -- A leg that gave up leaves the host sitting on the barriers after it for
  -- their full budget, and what gets reported then is a wall of timeouts over
  -- there rather than the one real failure over here. Signalling a marker
  -- twice is harmless -- the file is written, not counted -- so this is
  -- unconditional rather than guarded by whether the leg ran.
  for _, tag in ipairs({ "guest_saw_char_change",
                         "guest_ready_for_party", "guest_party_joined",
                         "guest_coop_joined",
                         "guest_coop_done", "guest_left_game" }) do
    H.signal(tag)
  end

  U.wait(60)
  log("RESULT " .. failures .. " failure(s)")
  log("DONE")
end
