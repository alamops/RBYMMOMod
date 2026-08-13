-- Gen 2 host e2e: in-game hosting on Gold, driven end-to-end.
--
-- Pair with mmo_join_gen2.lua via run-mmo-e2e-gen2.sh. Same shape as
-- mmo_host.lua (real socket, real menus, real avatars) but boots Gold
-- free-roam without mashing through Oak. After presence/chat it runs the
-- product legs: interact → trade → mediated 1v1 → party → coop_wild →
-- coop_npc → leave (skips Gen1-only walk-through / ADD FRIEND / CHARACTER).
--
--   POKEPORT_VERSION=gold POKEPORT_IDENTITY=mmohost-gold \
--     POKEPORT_DRIVER=mods/rby_mmo/tests/drivers/mmo_host_gen2.lua love .

io.stdout:setvbuf("line")
io.stderr:setvbuf("line")
if os.getenv("MMO_SOUND") ~= "1" and love and love.audio then
  love.audio.setVolume(0)
end

return function(game)
  local H = dofile("mods/rby_mmo/tests/drivers/mmo_util.lua")
  local U = H.U
  local TAG = "MMO_HOST:"
  local ADDR_FILE = os.getenv("MMO_ADDR_FILE") or "/tmp/rby_mmo_addr.txt"
  local SHOT_DIR = os.getenv("SHOT_DIR") or "/tmp/rby_mmo_shots_gen2"
  local LIMIT = tonumber(os.getenv("MMO_LIMIT") or "") or 2

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

  os.remove(ADDR_FILE)
  os.remove(ADDR_FILE .. ".tmp")

  check(H.bootToPlay(game), "Gold free-roam is reachable under the driver")
  check(H.generation(game) == 2, "host boots generation 2")

  if game.save and game.save.player then
    game.save.player.name = "HOSTY"
  end
  local leadMon = H.seedParty(game, "CYNDAQUIL", 50)
  local lead = leadMon and H.frontloadDamage(game.data, leadMon)
  log("in the overworld as HOSTY with", table.concat(H.partySpecies(game), ","),
      "leading with", tostring(lead))

  local exports = H.requireMod(game, TAG)
  if not exports then
    log("RESULT 1 failure(s)")
    log("DONE")
    love.event.quit(1)
    return
  end
  if exports.traceAvatars then exports.traceAvatars(true) end
  check(exports.isConnected() == false, "starts disconnected")
  check(exports.isHosting() == false, "starts not hosting")

  -- START open/close before menus (stuck-menu regression on Gen2StartMenu).
  U.tap(game, "start")
  U.wait(16)
  local top = H.top(game)
  check(top ~= nil and top.list ~= nil, "START opened Gen2StartMenu")
  U.tap(game, "start")
  U.wait(16)
  top = H.top(game)
  check(top == nil or top.list == nil, "START closed Gen2StartMenu")

  if not H.openMmo(game) then
    log("FAIL could not reach the MMO menu")
    log("RESULT 1 failure(s)")
    log("DONE")
    love.event.quit(1)
    return
  end
  check(true, "the MMO row exists on the START menu")

  if not H.selectLabel(game, "HOST GAME") then
    log("FAIL no HOST GAME row")
    log("RESULT " .. (failures + 1) .. " failure(s)")
    log("DONE")
    love.event.quit(1)
    return
  end

  U.wait(20)
  check(H.classify(H.top(game)) == "menu", "character creation opened")
  U.shot(game, SHOT_DIR .. "/host-charsetup.png")

  if H.selectLabel(game, "LOOK") then
    U.wait(20)
    check(H.classify(H.top(game)) == "menu", "the character picker opened")
    U.shot(game, SHOT_DIR .. "/host-charpick.png")
    U.tap(game, "b")
    U.wait(20)
  end

  check(H.selectLabel(game, "HOST"), "confirmed the trainer and moved on")
  U.wait(20)
  check(H.classify(H.top(game)) == "menu", "the host setup menu opened")
  U.shot(game, SHOT_DIR .. "/host-setup.png")

  check(H.selectLabel(game, "PLAYERS"), "PLAYERS opens the size list")
  U.wait(20)
  local picked = H.selectLabel(game, ("%d PLAYERS"):format(LIMIT))
  check(picked, "chose " .. LIMIT .. " PLAYERS")
  U.wait(20)

  local minted = H.menuRow(game, "JOIN CODE")
  local mintedCode = minted and H.codeFrom(tostring(minted.right))
  check(mintedCode ~= nil,
        "the setup screen arrives with a code on its JOIN CODE row")
  local joinCode = mintedCode
  if check(H.selectLabel(game, "JOIN CODE"), "JOIN CODE opens the lock menu") then
    U.wait(20)
    check(H.selectLabel(game, "NEW CODE"), "asked the game to make one")
    U.wait(30)
    local fresh = H.codeFrom(H.textOf(H.top(game)))
    check(fresh ~= nil, "the screen reads out a code")
    joinCode = fresh or mintedCode
    H.shotPrinted(game, SHOT_DIR .. "/host-newcode.png")
    H.waitFor(game, function()
      local t = H.top(game)
      if t and type(t.items) == "table" then return true end
      U.tap(game, "a")
      return false
    end, 240, "the setup menu after setting a code")
  end

  check(H.selectLabel(game, "START"), "START begins the game")
  U.wait(30)

  local hosting = H.waitFor(game, function() return exports.isHosting() end,
                            240, "the listener to come up")
  check(hosting, "hosting started (a real socket is bound)")
  if not hosting then
    log("RESULT " .. failures .. " failure(s)")
    log("DONE")
    love.event.quit(failures > 0 and 1 or 0)
    return
  end
  H.shotPrinted(game, SHOT_DIR .. "/host-address.png")

  local address = exports.hostAddress and exports.hostAddress() or nil
  check(type(address) == "string" and address:find(":"),
        "an address is published: " .. tostring(address))

  local joinedSelf = H.waitFor(game, function() return exports.isConnected() end,
                               240, "the host to join its own game")
  check(joinedSelf, "the host joined its own game over loopback")

  H.closeToOverworld(game)

  local handle = io.open(ADDR_FILE .. ".tmp", "w")
  if handle then
    handle:write(tostring(address) .. "\n" .. (joinCode or "") .. "\n")
    handle:close()
    os.rename(ADDR_FILE .. ".tmp", ADDR_FILE)
  end
  log("hosting", tostring(address), "limit", LIMIT,
      "code " .. H.formatCode(joinCode))

  local sawGuest = H.waitSeconds(game, function()
    return #exports.players() > 0
  end, 400, "the guest to connect")
  check(sawGuest, "a remote player joined over a real socket")

  if sawGuest then
    local guest = exports.players()[1]
    log("guest is", tostring(guest.name), "on", tostring(guest.map))
    check(type(guest.name) == "string" and guest.name ~= "",
          "the guest has a name on the roster")
    check(guest.name == "GUESTY", "guest trainer name is GUESTY")

    H.await(game, "guest_walked")
    local row = H.avatarRow(exports, "GUESTY") or H.avatarRow(exports)
    check(row ~= nil and row.spawned,
          "the guest has a spawned avatar on this map")
    U.shot(game, SHOT_DIR .. "/host-sees-guest.png")

    H.signal("host_walk_start")
    H.await(game, "guest_baseline_taken")
    local wasAt = H.playerCell(game)
    -- Gold's bedroom is tighter than Red's: left/right from the spawn often
    -- hits furniture. Prefer down/right (same path the guest already walks).
    for _ = 1, 2 do
      H.holdAll(game, { "down", "b" }, 22)
      U.wait(8)
    end
    for _ = 1, 2 do
      H.holdAll(game, { "right", "b" }, 22)
      U.wait(8)
    end
    local nowAt = H.playerCell(game)
    local moved = nowAt and wasAt and (nowAt.x ~= wasAt.x or nowAt.y ~= wasAt.y)
    if not moved then
      -- Walls ate the step; the guest still asserts the presence stream below.
      log(("host walk cells (%s,%s) -> (%s,%s) -- walls; guest checks the wire")
        :format(tostring(wasAt and wasAt.x), tostring(wasAt and wasAt.y),
                tostring(nowAt and nowAt.x), tostring(nowAt and nowAt.y)))
    end
    check(true, "the host walked (guest asserts presence)")
    H.signal("host_walk_done")

    exports.say("global", "HELLO FROM HOST")
    local heardGuest = H.waitSeconds(game, function()
      for _, line in ipairs(exports.chat()) do
        if line.text == "HELLO FROM GUEST" then return true end
      end
      return false
    end, 120, "the guest's chat line")
    check(heardGuest, "the guest's chat reached the host")

    -- ------- interact: hold still so the guest can open TRADE/BATTLE
    H.closeToOverworld(game)
    H.signal("host_ready_for_interact")
    H.await(game, "guest_interact_done")
    U.shot(game, SHOT_DIR .. "/host-after-interact.png")

    -- ------- trade (guest asks; host receives PIKACHU)
    H.await(game, "guest_trade_requested")
    local wanted = "PIKACHU"
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

    -- ------- mediated 1v1
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
      local battleTop = H.top(game)
      log(("mediated: peer=%s phase=%s"):format(
        tostring(battleTop.peerName), tostring(battleTop.phase)))
      U.shot(game, SHOT_DIR .. "/host-battle-open.png")
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
    U.shot(game, SHOT_DIR .. "/host-after-battle.png")
    H.signal("host_battle_done")

    H.closeToOverworld(game)
    if type(H.rankAfterBattle) == "function" then
      H.rankAfterBattle(game, exports, check)
    else
      log("note: H.rankAfterBattle missing; skipping rank settle check")
    end

    -- ------- party invite (guest INVITEs via interact — Gen2 MMO/PLAYERS
    -- after a mediated fight often leaves MAIN unscannable; interact works).
    H.await(game, "guest_ready_for_party")
    H.closeToOverworld(game, 48)
    for _ = 1, 16 do
      local t = H.top(game)
      if t == nil or t.isOverworld or t == game.overworld then break end
      U.tap(game, "b")
      U.wait(6)
    end
    U.wait(20)
    H.signal("host_ready_for_party_invite")
    H.await(game, "guest_party_invited")
    local paired = H.drivePrompts(game, function()
      return #exports.party() == 2
    end, 120)
    check(paired, "the party formed over the in-game hub")
    H.signal("host_party_asked")
    H.await(game, "guest_party_joined")
    H.closeToOverworld(game, 48)

    -- ------- coop_wild
    local announced = H.listenForModEvents and H.listenForModEvents(game, {
      "mod.rby_mmo.coop_battle_started",
      "mod.rby_mmo.coop_battle_ended",
    }) or nil
    check(H.giveItem(game, "MASTER_BALL", 1), "seeded a MASTER_BALL for the catch")
    local WILD_SPECIES = "SENTRET"
    local wildFinished = nil
    local staged = H.stageWild(game, WILD_SPECIES, 5, function(result)
      wildFinished = result
    end)
    if staged == nil then
      WILD_SPECIES = "PIDGEY"
      staged = H.stageWild(game, WILD_SPECIES, 5, function(result)
        wildFinished = result
      end)
      log("SENTRET stageWild nil; fell back to", WILD_SPECIES)
    end
    check(staged ~= nil, "staged a wild battle on the host")
    log("wild species:", WILD_SPECIES)

    local waiting = H.waitSeconds(game, function()
      return exports.coopWaiting() ~= nil
    end, 60, "coop_wild wait after the wild divert")
    check(waiting, "the host diverted into coop_wild wait")
    U.shot(game, SHOT_DIR .. "/host-party-wild-wait.png")
    -- Round 13: the wait cover is deleted outright -- no box, no rows, on
    -- either mode. The engine's own wild encounter stays exactly on screen;
    -- the only exits are the field opening (partner joined) or
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
      local fieldTop = H.top(game)
      return fieldTop ~= nil and fieldTop.sim ~= nil and #fieldTop.sim.slots == 3
    end, 120, "the Party-vs-Wild field to come up")
    check(onField, "a three-slot coop_wild battle is on screen")
    local refereed = H.awaitMediatedCoop(game, 60, "coop_wild")
    check(refereed,
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
      local fieldTop = H.top(game)
      return fieldTop == nil or fieldTop.sim == nil
    end, 240, function()
      local fieldTop = H.top(game)
      if H.isMediatedCoop(fieldTop) then
        medGaps = tonumber(fieldTop.medGaps) or medGaps
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
    if announced then
      check(announced["mod.rby_mmo.coop_battle_ended"] >= 1,
            "coop_battle_ended fired after Party vs Wild")
    end
    log("engine wild result:", tostring(wildFinished))
    U.shot(game, SHOT_DIR .. "/host-party-wild-after.png")
    H.signal("host_wild_done")
    H.await(game, "guest_wild_done")
    H.closeToOverworld(game)

    -- ------- coop_npc (same party)
    local coopClass, coopLevel = H.coopTrainer(game.data)
    check(coopClass ~= nil, "the dataset has a trainer with two POKeMON")
    log("co-op trainer:", tostring(coopClass), "total level", tostring(coopLevel))

    local coopFinished = nil
    local stagedTrainer = nil
    if coopClass then
      stagedTrainer = H.stageTrainer(game, coopClass, function(result)
        coopFinished = result
      end)
      -- Round 11: no ask. Staging the trainer while partied posts COOP_WAIT.
      -- Round 13 deleted the cover that used to sit in front of it too -- the
      -- wait now runs invisibly behind the engine's own encounter, so this
      -- waits for the field itself and fails on any menu at all. Ported from
      -- mmo_host.lua's sight-walk-in leg; see the comments there for why
      -- sawMenu is sampled inside the loop and why the A tap stays gated on
      -- `items == nil`.
      local sawMenu = false
      local joinedFirst = false
      local joined = H.waitFor(game, function()
        local promptTop = H.top(game)
        if promptTop ~= nil and promptTop.sim ~= nil
            and #promptTop.sim.slots >= 3 then
          joinedFirst = true
          return true
        end
        if promptTop and promptTop.items ~= nil then sawMenu = true end
        if promptTop and promptTop.items == nil then U.tap(game, "a") end
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
      U.shot(game, SHOT_DIR .. "/host-coop-wait.png")

      -- Marker first, and then a predicate with two halves -- the round 9
      -- change on this side, ported from mmo_host.lua.
      --
      -- The partner is pulled in automatically (src/Coop.lua's M:autoJoin):
      -- they are already standing on this map with nothing on screen, so
      -- COOP_WAIT goes out, COOP_JOIN comes back, and the wait can be *over*
      -- within a frame or two of the trainer triggering. Polling
      -- `coopWaiting() ~= nil` alone can therefore report "this side never
      -- stood at the fight" about a wait that had already been answered.
      --
      -- So what is asserted is the claim the wait actually makes: this side
      -- ends up at the fight. Standing at it and already joined are the two
      -- ways that can be true, and which one a run sees is a matter of
      -- milliseconds, so neither may fail it. The marker stays above the poll
      -- for the same reason -- the guest's window opens when COOP_WAIT is
      -- sent, not when this side finishes looking at itself.
      --
      -- 45s is a generous margin, not the clock: round 13's
      -- SOLO_FALLBACK_AFTER releases a wait nobody takes into the solo fight
      -- after six seconds, so both outcomes this leg cares about (still
      -- waiting, or already joined) are long since decided well inside it.
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
    else
      H.signal("host_coop_waiting")
    end

    H.await(game, "guest_coop_joined")
    local onCoopField = H.waitSeconds(game, function()
      local fieldTop = H.top(game)
      return fieldTop ~= nil and fieldTop.sim ~= nil and #fieldTop.sim.slots == 4
    end, 120, "the 2-on-2 to come up")
    check(onCoopField, "a four-slot co-op battle is on screen, over the LAN hub")
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
    if onCoopField then
      check(H.awaitCommandMenu(game, "the command menu for the battle shot"),
            "the co-op command grid opens once the opening line is done")
      U.wait(30)
      U.shot(game, SHOT_DIR .. "/host-coop-battle.png")
      check(exports.coopDrawFailed() == false, "and it drew without error")
    end

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
    check(coopSync.desyncs == 0, "and no drift between the two copies")
    check(coopMedGaps == 0, "and no gaps in the mediated event stream")
    log("co-op result:", tostring(coopFinished))
    if stagedTrainer then
      check(not H.onStack(game, stagedTrainer),
            "the trainer battle this side staged is off the stack")
    end

    H.drivePrompts(game, function()
      local owTop = H.top(game)
      return owTop == nil or owTop == game.overworld or owTop.isOverworld
    end, 120)
    H.closeToOverworld(game)
    U.shot(game, SHOT_DIR .. "/host-coop-after.png")
    H.signal("host_coop_done")
    H.await(game, "guest_coop_done")

    -- Prefer the real menu path; Gen2 after a long coop stack often leaves
    -- MAIN unscannable (PARTY row never appears under selectLabel). Fall
    -- back to exports.leaveParty so the guest's party-end wait still closes.
    local leftParty = false
    if H.openMmo(game) then
      U.wait(20)
      log("party leave menu:", table.concat(H.menuLabels(game), ","))
      if H.selectLabel(game, "PARTY", 120) then
        U.wait(25)
        if H.selectLabel(game, "LEAVE") then
          leftParty = H.drivePrompts(game, function()
            return #exports.party() == 0
          end, 60)
        end
      end
    end
    if not leftParty and #exports.party() > 0
       and type(exports.leaveParty) == "function" then
      log("party leave via exports.leaveParty (menu path missed)")
      exports.leaveParty()
      H.drivePrompts(game, function()
        return #exports.party() == 0
      end, 60)
    end
    H.closeToOverworld(game)
    check(#exports.party() == 0, "and the party is left behind cleanly")
    H.signal("host_coop_left")

    H.await(game, "guest_left_game")
    local gone = H.waitSeconds(game, function()
      return #exports.players() == 0
    end, 90, "the guest to drop off the roster")
    check(gone, "a guest who leaves drops off the host's roster")
    check(exports.isHosting(), "and the host is still hosting afterwards")
  end

  -- Fail-forward: every marker this side owns, so a mid-run abort does not
  -- leave the guest sitting on barriers for their full budget.
  for _, tag in ipairs({
    "host_ready_for_interact", "host_trade_done", "host_battle_done",
    "host_ready_for_party_invite", "host_party_asked",
    "host_wild_waiting", "host_wild_done",
    "host_coop_waiting", "host_coop_done", "host_coop_left",
  }) do
    H.signal(tag)
  end

  U.wait(90)
  log("RESULT " .. failures .. " failure(s)")
  log("DONE")
  love.event.quit(failures > 0 and 1 or 0)
end
