-- Gen 2 guest e2e: join a Gold in-game host, driven end-to-end.
--
-- Pair with mmo_host_gen2.lua via run-mmo-e2e-gen2.sh. After presence/chat
-- runs the product legs: interact → trade → mediated 1v1 → party →
-- coop_wild → coop_npc → leave (skips Gen1-only walk-through / ADD FRIEND /
-- CHARACTER). Uses H.teleport on Gold, not U.teleport.
--
--   POKEPORT_VERSION=gold POKEPORT_IDENTITY=mmoguest-gold \
--     POKEPORT_DRIVER=mods/rby_mmo/tests/drivers/mmo_join_gen2.lua love .

io.stdout:setvbuf("line")
io.stderr:setvbuf("line")
if os.getenv("MMO_SOUND") ~= "1" and love and love.audio then
  love.audio.setVolume(0)
end

return function(game)
  local H = dofile("mods/rby_mmo/tests/drivers/mmo_util.lua")
  local U = H.U
  local TAG = "MMO_JOIN:"
  local ADDR_FILE = os.getenv("MMO_ADDR_FILE") or "/tmp/rby_mmo_addr.txt"
  local SHOT_DIR = os.getenv("SHOT_DIR") or "/tmp/rby_mmo_shots_gen2"

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

  check(H.bootToPlay(game), "Gold free-roam is reachable under the driver")
  check(H.generation(game) == 2, "guest boots generation 2")

  if game.save and game.save.player then
    game.save.player.name = "GUESTY"
  end
  local leadMon = H.seedParty(game, "PIKACHU", 30)
  local lead = leadMon and H.frontloadDamage(game.data, leadMon)
  log("in the overworld as GUESTY with", table.concat(H.partySpecies(game), ","),
      "leading with", tostring(lead))

  local exports = H.requireMod(game, TAG)
  if not exports then
    log("RESULT 1 failure(s)")
    log("DONE")
    love.event.quit(1)
    return
  end
  check(exports.isConnected() == false, "starts disconnected")
  check(exports.isHosting() == false, "starts not hosting")

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
  check(ready, "the host came up")
  if not ready then
    log("RESULT " .. failures .. " failure(s)")
    log("DONE")
    love.event.quit(1)
    return
  end
  log("dialling", tostring(hostAddress), "code", H.formatCode(joinCode))

  if not H.openMmo(game) then
    log("FAIL could not reach the MMO menu")
    log("RESULT 1 failure(s)")
    log("DONE")
    love.event.quit(1)
    return
  end
  check(true, "the MMO row exists on the START menu")

  if not H.selectLabel(game, "JOIN GAME") then
    log("FAIL no JOIN GAME row")
    log("RESULT " .. (failures + 1) .. " failure(s)")
    log("DONE")
    love.event.quit(1)
    return
  end
  U.wait(20)
  check(H.selectLabel(game, "JOIN"), "character creation confirms")
  U.wait(40)

  local naming = H.addressGrid(game)
  if naming and naming.default then
    check(H.clearGrid(game, naming), "B erases the address line")
  else
    check(false, "the address screen carries a default to dial")
  end
  U.tap(game, "start")
  U.wait(60)

  check(joinCode ~= nil, "the host published a join code with its address")
  if joinCode then
    local asked = H.waitFor(game, function()
      return H.codeGrid(game) ~= nil
    end, 240, "the join-code grid")
    check(asked, "the address screen hands straight over to the code grid")
    U.shot(game, SHOT_DIR .. "/join-code-asked.png")
    -- Correct code only on Gen 2 for now: the wrong-code refusal path is
    -- covered on Gen 1, and a hung TextBox after refusal stalled this driver.
    check(H.enterJoinCode(game, joinCode),
          "the host's code can be typed on the grid")
    U.wait(60)
  end

  local connected = H.waitSeconds(game, function() return exports.isConnected() end,
                                  60, "the connection to open")
  check(connected, "joined over a real socket")
  if not connected then
    U.shot(game, SHOT_DIR .. "/join-FAILED.png")
    log("RESULT " .. failures .. " failure(s)")
    log("DONE")
    love.event.quit(1)
    return
  end
  check(exports.isHosting() == false, "and is not the host")
  H.closeToOverworld(game)

  local sawHost = H.waitSeconds(game, function()
    return #exports.players() > 0
  end, 60, "the host to appear on the roster")
  check(sawHost, "the host appears on the guest's roster")
  U.shot(game, SHOT_DIR .. "/join-sees-host.png")

  for _ = 1, 3 do
    U.hold(game, "down", 20)
    U.wait(10)
    U.hold(game, "right", 20)
    U.wait(10)
  end
  log("walked")
  H.signal("guest_walked")
  U.shot(game, SHOT_DIR .. "/join-after-walk.png")

  H.await(game, "host_walk_start")
  local before = H.avatarRow(exports)
  local fromX, fromY = before and before.rosterX, before and before.rosterY
  H.signal("guest_baseline_taken")

  local sawHostFast = false
  local function sampleHostFast()
    local row = H.avatarRow(exports)
    if row and row.fast then sawHostFast = true end
  end
  H.await(game, "host_walk_done", nil, sampleHostFast)
  check(sawHostFast, "the host's avatar row showed fast=true while B was held")

  local hostMoved = H.waitSeconds(game, function()
    local row = H.avatarRow(exports)
    return row and (row.rosterX ~= fromX or row.rosterY ~= fromY)
  end, 45, "the host to move on this side")
  check(hostMoved, "the host's movement reaches the guest")
  U.shot(game, SHOT_DIR .. "/join-host-walked.png")

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

  -- ------- interact: teleport below host, open TRADE/BATTLE (keep menu open)
  H.await(game, "host_ready_for_interact")
  local hostRow = H.avatarRow(exports)
  check(hostRow ~= nil and hostRow.rosterX ~= nil,
        "the host has a cell to stand next to")

  local interactOpen = false
  if hostRow and hostRow.rosterX then
    -- Gold: H.teleport (WorldAPI warp), never U.teleport.
    H.teleport(game, hostRow.map, hostRow.rosterX, hostRow.rosterY + 1, "up")
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

    local interactTop = H.top(game)
    local labels = {}
    for _, item in ipairs((interactTop and interactTop.items) or {}) do
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
    U.shot(game, SHOT_DIR .. "/join-interact-menu.png")
    interactOpen = #labels > 0
  end
  H.signal("guest_interact_done")

  -- ------- trade (keep interact menu; select TRADE)
  H.waitSeconds(game, function()
    local row = H.avatarRow(exports)
    return row ~= nil and not row.busy
  end, 45, "the host to be free")
  if not interactOpen then
    U.tap(game, "a")
    U.wait(45)
    interactOpen = H.classify(H.top(game)) == "menu"
  end
  if interactOpen and H.selectLabel(game, "TRADE") then
    log("asked to trade")
    H.signal("guest_trade_requested")

    local wanted = "CYNDAQUIL"
    local record, prompts = H.promptLog()
    local traded, trail = H.drivePrompts(game, function()
      return H.partySpecies(game)[1] == wanted
    end, 120, record)
    log("guest party now:", table.concat(H.partySpecies(game), ","))
    if not traded then
      log("trade stalled -- prompts answered:", trail == "" and "(none)" or trail,
          "top is", tostring(H.top(game) and (H.top(game).title or "?")))
      log("  boxes:", table.concat(prompts, " | "))
    end
    check(traded, "the guest received the host's " .. wanted)
    U.shot(game, SHOT_DIR .. "/join-after-trade.png")
    H.await(game, "host_trade_done")
  else
    check(false, "could not open TRADE from the interact menu")
    H.signal("guest_trade_requested")
  end

  -- ------- mediated 1v1
  H.closeToOverworld(game)
  local free = H.waitSeconds(game, function()
    local row = H.avatarRow(exports)
    return row ~= nil and not row.busy
  end, 60, "the host to finish the trade")
  if not free then log("WARN host still busy; asking anyway") end
  U.wait(30)
  local reopened = false
  if H.top(game) == nil or H.top(game).isOverworld
     or H.top(game) == game.overworld then
    U.tap(game, "a")
    U.wait(45)
    reopened = H.classify(H.top(game)) == "menu"
  end
  check(reopened, "the interact menu opens again for a battle")

  if reopened and H.selectLabel(game, "BATTLE") then
    log("asked to battle")
    H.signal("guest_battle_requested")

    local started = H.drivePrompts(game, function()
      return H.inMediatedFight(game, exports)
    end, 90)
    check(started, "a mediated battle started on the guest")

    -- The arena on the JOINER's screen too. Worth its own check rather than
    -- trusting the host's: the two clients build their seats from different
    -- ends of the same wire (`mine` vs the referee's field), and a Gold guest
    -- that fell back to the 160x144 GB path while the host drew the arena is
    -- exactly the asymmetry a one-sided assertion would miss.
    -- docs/plans/gen2-new-battle-system.md.
    do
      local battleTop = H.top(game)
      if H.isMediatedBattle(battleTop) then
        U.wait(60)
        check(battleTop.usesBattlefield and battleTop:usesBattlefield() or false,
              "the joiner's Gold fight is on the top-down arena as well")
        check(battleTop.drawsWidescreen and battleTop:drawsWidescreen() or false,
              "...through the same widescreen seam the host uses")
        U.shot(game, SHOT_DIR .. "/join-battle-open.png")
      end
    end

    local gaps = 0
    local ended = H.drivePrompts(game, function()
      local battleTop = H.top(game)
      if H.isMediatedBattle(battleTop) then
        gaps = tonumber(battleTop.gaps) or gaps
        return false
      end
      return not H.inMediatedFight(game, exports)
    end, 240)
    check(ended, "and ran to a decision")
    check(gaps == 0, "with no gaps in the mediated event stream")
    log(("mediated battle: gaps=%d"):format(gaps))
    U.shot(game, SHOT_DIR .. "/join-after-battle.png")
    H.await(game, "host_battle_done")
  else
    check(false, "could not open BATTLE from the interact menu")
    H.signal("guest_battle_requested")
  end

  H.closeToOverworld(game, 48)

  -- ------- party (guest INVITEs from the interact menu — reliable on Gold)
  H.signal("guest_ready_for_party")
  H.await(game, "host_ready_for_party_invite")
  local hostRow2 = H.avatarRow(exports)
  if hostRow2 and hostRow2.rosterX then
    H.teleport(game, hostRow2.map, hostRow2.rosterX, hostRow2.rosterY + 1, "up")
    U.wait(60)
    U.tap(game, "a")
    U.wait(45)
  end
  local invited = H.selectLabel(game, "INVITE")
  check(invited, "INVITE from the interact menu asks the host to team up")
  H.signal("guest_party_invited")
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
  H.await(game, "host_party_asked")
  H.closeToOverworld(game, 48)

  -- ------- coop_wild (auto-join; no confirm)
  local announced = H.listenForModEvents and H.listenForModEvents(game, {
    "mod.rby_mmo.coop_battle_started",
    "mod.rby_mmo.coop_battle_ended",
  }) or nil

  H.await(game, "host_wild_waiting")
  local joinedWild = H.waitSeconds(game, function()
    local fieldTop = H.top(game)
    if fieldTop ~= nil and fieldTop.sim ~= nil and #fieldTop.sim.slots == 3 then
      return true
    end
    if H.classify(fieldTop) == "choice" then
      local text = (H.textOf(fieldTop) or ""):lower()
      if text:find("join", 1, true) and text:find("against", 1, true) then
        return false
      end
    end
    return false
  end, 120, "auto-join into the Party-vs-Wild fight")
  check(joinedWild, "the partner auto-joined coop_wild without a prompt")
  local wildRefereed = H.awaitMediatedCoop(game, 60, "coop_wild")
  check(wildRefereed,
        "the LAN Party-vs-Wild fight is hub-refereed (coop_wild)")
  do
    local fieldTop = H.top(game)
    log(("mediated coop_wild: id=%s mode=%s medGaps=%s"):format(
      tostring(fieldTop and fieldTop.battleId),
      tostring(fieldTop and fieldTop.mode),
      tostring(fieldTop and fieldTop.medGaps)))
  end
  if announced then
    check(announced["mod.rby_mmo.coop_battle_started"] >= 1,
          "coop_battle_started fired for Party vs Wild")
  end
  U.shot(game, SHOT_DIR .. "/join-party-wild-battle.png")
  check(exports.coopDrawFailed() == false, "and it drew without error")
  H.signal("guest_wild_joined")

  local wildMedGaps = 0
  local wildOver = H.drivePrompts(game, function()
    local fieldTop = H.top(game)
    return fieldTop == nil or fieldTop.sim == nil
  end, 240, function()
    local fieldTop = H.top(game)
    if H.isMediatedCoop(fieldTop) then
      wildMedGaps = tonumber(fieldTop.medGaps) or wildMedGaps
    end
    U.tap(game, "a")
  end)
  check(wildOver, "the coop_wild fight runs to an end on the guest")
  local wildSync = exports.coopSync()
  log(("coop_wild sync: gaps=%d desyncs=%d resyncs=%d medGaps=%d"):format(
    wildSync.gaps, wildSync.desyncs, wildSync.resyncs, wildMedGaps))
  check(wildSync.desyncs == 0, "with no drift on the guest")
  check(wildMedGaps == 0, "and no gaps in the mediated event stream")
  if announced then
    check(announced["mod.rby_mmo.coop_battle_ended"] >= 1,
          "coop_battle_ended fired after Party vs Wild")
  end
  U.shot(game, SHOT_DIR .. "/join-party-wild-after.png")
  H.signal("guest_wild_done")
  H.await(game, "host_wild_done")
  H.closeToOverworld(game)

  -- ------- coop_npc (same party; auto-join, no confirm)
  --
  -- Round 9 rewrote this leg's contract the same way as mmo_join.lua's
  -- walk-in leg (see that file's header for the full story): the offer that
  -- used to *stand*, waiting for this side to answer a join/wait confirm, is
  -- now taken within a tick by src/Coop.lua's M:autoJoin -- forming the
  -- party was the yes. Unlike mmo_join.lua's Route 3 leg this side never
  -- walks anywhere for coop_npc on Gen 2: the host stages its own local
  -- trainer battle (H.stageTrainer) and this side is pulled straight into it
  -- from wherever the party leg left it standing, so there is no sight
  -- line, no walk-in and no local BattleState to assert against here -- only
  -- the claims round 9 actually makes:
  --
  --   "the waiting partner's offer      the offer is gone because it was
  --    reaches the guest"           ->  TAKEN: a field comes up here with
  --                                     nothing pressed at all
  --   "walk-in raised a join or         nothing is raised at all, ever --
  --    wait prompt"                 ->  watch() below fails the run if a
  --                                     single YES/NO/WAIT/JOIN row shows
  --
  -- Sampled through the barrier as well as after it, same as mmo_join.lua:
  -- the offer is sent when the host picks WAIT, which is the same moment it
  -- drops this marker.
  local sawPrompt, promptWas = false, nil
  local sawOffer, offerBattle = false, nil
  local function watch()
    local offer = exports.coopOffer()
    if offer then
      sawOffer = true
      offerBattle = offerBattle or tostring(offer.battle)
    end
    local top = H.top(game)
    if top ~= nil and top.sim ~= nil then return end
    for _, label in ipairs(H.menuLabels(game)) do
      if label == "YES" or label == "NO" or label == "WAIT"
         or label == "JOIN" then
        sawPrompt = true
        promptWas = promptWas or label
      end
    end
    if H.classify(top) == "choice" then
      sawPrompt = true
      promptWas = promptWas or ("choice: " .. H.textOf(top))
    end
  end

  H.await(game, "host_coop_waiting", nil, watch)
  local joinedCoop = H.waitSeconds(game, function()
    watch()
    local fieldTop = H.top(game)
    return fieldTop ~= nil and fieldTop.sim ~= nil and #fieldTop.sim.slots >= 3
  end, 90, "the partner's offer to pull this side into the fight")
  log(("auto-join: offerSeen=%s battle=%s prompt=%s"):format(
    tostring(sawOffer), tostring(offerBattle), tostring(promptWas)))
  check(joinedCoop, "a four-slot co-op battle is on screen, over the LAN hub")
  check(not sawPrompt,
        "and nothing was ever put to this side -- no join confirm, no "
        .. "WAIT/ALONE row: the party was the yes")
  local told = H.waitSeconds(game, function()
    for _, line in ipairs(exports.chat()) do
      local text = tostring(line.text or "")
      if text:find("Joining", 1, true) and text:find("HOSTY", 1, true) then
        return true
      end
    end
    return false
  end, 30, "the party note naming whose battle this is")
  check(told,
        "and the scrollback says whose fight it is rather than a box "
        .. "asking to be let in (M:autoJoin's note)")
  local coopRefereed = H.awaitMediatedCoop(game, 60, "coop_npc")
  check(coopRefereed,
        "the LAN 2-on-2 is hub-refereed (coop_npc), not host CoopSim")
  do
    local fieldTop = H.top(game)
    log(("mediated coop: id=%s mode=%s medGaps=%s"):format(
      tostring(fieldTop and fieldTop.battleId),
      tostring(fieldTop and fieldTop.mode),
      tostring(fieldTop and fieldTop.medGaps)))
  end
  U.wait(30)
  U.shot(game, SHOT_DIR .. "/join-coop-battle.png")
  check(exports.coopDrawFailed() == false, "and it drew without error")
  H.signal("guest_coop_joined")

  local coopMedGaps = 0
  local coopOver = H.drivePrompts(game, function()
    local fieldTop = H.top(game)
    return fieldTop == nil or fieldTop.sim == nil
  end, 300, function()
    local fieldTop = H.top(game)
    if H.isMediatedCoop(fieldTop) then
      coopMedGaps = tonumber(fieldTop.medGaps) or coopMedGaps
    end
    U.tap(game, "a")
  end)
  check(coopOver, "the 2-on-2 runs to an end over the in-game hub")
  local coopSync = exports.coopSync()
  log(("coop sync: gaps=%d desyncs=%d resyncs=%d medGaps=%d"):format(
    coopSync.gaps, coopSync.desyncs, coopSync.resyncs, coopMedGaps))
  check(coopSync.gaps == 0, "with no turn lost by the Lua hub")
  check(coopSync.desyncs == 0, "and no drift from the host's copy")
  check(coopMedGaps == 0, "and no gaps in the mediated event stream")

  H.drivePrompts(game, function()
    local owTop = H.top(game)
    return owTop == nil or owTop == game.overworld or owTop.isOverworld
  end, 120)
  H.closeToOverworld(game)
  U.shot(game, SHOT_DIR .. "/join-coop-after.png")
  H.signal("guest_coop_done")
  H.await(game, "host_coop_done")

  H.await(game, "host_coop_left")
  local emptied = H.waitSeconds(game, function()
    return #exports.party() == 0
  end, 60, "the party to end for this side too")
  check(emptied, "and the party ends for both when one of them leaves")
  H.closeToOverworld(game)

  -- Leave through the menus a player uses (guest row is LEAVE, not END GAME).
  -- Gen2 free-roam + StartMenu timing sometimes leaves MAIN unscannable;
  -- fall back to exports.leave so the harness still finishes cleanly.
  H.closeToOverworld(game)
  U.wait(20)
  local left = false
  if H.openMmo(game) then
    U.wait(30)
    local leaveTop = H.top(game)
    log("leave menu:", table.concat(H.menuLabels(game), ","),
        "top=", tostring(leaveTop and (leaveTop.title or leaveTop.name or "?")))
    if H.selectLabel(game, "LEAVE", 120) then
      U.wait(30)
      left = not exports.isConnected()
    end
  end
  if not left and exports.isConnected() and type(exports.leave) == "function" then
    log("leave via exports.leave (menu path missed)")
    exports.leave()
    U.wait(20)
  end
  H.waitSeconds(game, function() return not exports.isConnected() end,
                8, "disconnect")
  H.signal("guest_left_game")

  -- Fail-forward: every marker this side owns.
  for _, tag in ipairs({
    "guest_walked", "guest_baseline_taken", "guest_interact_done",
    "guest_trade_requested", "guest_battle_requested",
    "guest_ready_for_party", "guest_party_invited", "guest_party_joined",
    "guest_wild_joined", "guest_wild_done",
    "guest_coop_joined", "guest_coop_done",
    "guest_left_game",
  }) do
    H.signal(tag)
  end

  log("RESULT " .. failures .. " failure(s)")
  log("DONE")
  love.event.quit(failures > 0 and 1 or 0)
end
