-- Gen 3 trip driver: three guests on one Node hub locked to generation 3 --
-- FireRed ALPHA and BETA in Pallet Town, Emerald CHARLIE in Littleroot Town.
--
-- Pair with tests/drivers/run-trip-e2e-gen3.sh (Node hub `--generation 3`,
-- everybody JOINs through the real menus). What it proves is the part of the
-- Gen 3 design that only a mixed room can: one hub admits FireRed and
-- Emerald together, overworld presence stays per region (FR_* and EM_* maps
-- never share a map id, so CHARLIE is on everybody's roster but on nobody's
-- map), every roster names each player's place from their own region, chat
-- crosses carts, and a FireRed <-> Emerald trade goes through once each cart
-- has what its own trade rule asks for (the region-link progress flag and the
-- National Dex) -- with each side's dex updated; and (wave 5) a 1v1 between
-- the two carts through the real ACTIONS menu -- ALPHA's FireRed CHARMANDER
-- against CHARLIE's Emerald PIKACHU, refereed by the Node hub's BattleSim3 --
-- with the arena on both screens (each showing the other cart's monster),
-- a result that mirrors on both sides, and both parties exactly as they were
-- afterwards (the cart reloads the party after a link battle). BETA looks on.
-- Shots: g3-<game>-<role>-<NN>-<leg>.png. GEN3_LEGS narrows a run (chat,
-- trade, battle), as in run-mmo-e2e-gen3.sh.

if os.getenv("MMO_SOUND") ~= "1" and love and love.audio then
  love.audio.setVolume(0)
end

-- `fights`: the lead each cart's fighter brings to the cross-cart 1v1 -- the
-- FireRed side the stronger, so the weaker side still lands a blow.
local ROLES = {
  a = { name = "ALPHA",   mon = "PIKACHU",    spare = "RATTATA",   trades = "c",
        fights = { "CHARMANDER", 30 } },
  b = { name = "BETA",    mon = "CHARMANDER", spare = "RATTATA" },
  c = { name = "CHARLIE", mon = "GEODUDE",    spare = "ZIGZAGOON", trades = "a",
        fights = { "PIKACHU", 20 } },
}
local ORDER = { "a", "b", "c" }
-- where each stands: two FireRed players side by side in Pallet, the Emerald
-- one in Littleroot (region-disjoint map ids)
local SPOT = {
  a = { "FR_PALLET_TOWN", 12, 10, "down" },
  b = { "FR_PALLET_TOWN", 10, 12, "up" },
  c = { "EM_LITTLEROOT_TOWN", 9, 9, "down" },
}

local ROLE = tostring(os.getenv("MMO_ROLE") or "a"):lower()
if not ROLES[ROLE] then ROLE = "a" end

return function(game)
  local H = dofile("mods/rby_mmo/tests/drivers/mmo_util.lua")
  local U = H.U
  local TAG = "MMO_TRIP_" .. ROLE:upper() .. ":"
  local ME = ROLES[ROLE]
  local GAME = os.getenv("POKEPORT_VERSION") or "firered"
  local SHOT_DIR = os.getenv("SHOT_DIR") or "/tmp/rby_mmo_trip_gen3_shots"
  local RAW_CODE = os.getenv("MMO_HUB_CODE") or ""
  local shot = H.g3Shooter(game, SHOT_DIR, GAME, ROLE)

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

  local function marker(side, tag) return ("g3trip_%s_%s"):format(side, tag) end
  local function rendezvous(tag)
    H.signal(marker(ROLE, tag))
    local ok = true
    for _, side in ipairs(ORDER) do
      if side ~= ROLE and not H.await(game, marker(side, tag)) then ok = false end
    end
    return ok
  end
  local TAGS = { "ready", "seen", "presence", "chat", "traded", "fightready", "fought", "left" }
  local function finish()
    for _, tag in ipairs(TAGS) do H.signal(marker(ROLE, tag)) end
    U.wait(30)
    log(("RESULT %d failure(s)"):format(failures))
    log("DONE")
    love.event.quit(failures > 0 and 1 or 0)
  end

  local spot = SPOT[ROLE]
  check(H.bootToPlay(game, { name = ME.name, gender = 0, map = spot[1], x = spot[2], y = spot[3],
                             facing = spot[4] }),
        "a new " .. GAME .. " game reaches " .. spot[1])
  check(H.generation(game) == 3, "this instance boots generation 3")
  check(H.g3Version(game) == GAME, "on " .. GAME)

  local exports = H.requireMod(game, TAG)
  if not exports then
    failures = failures + 1
    return finish()
  end
  if not check(type(exports.isConnected) == "function",
               "the mod's multiplayer client installed (else see [rby_mmo] errors in this log)") then
    return finish()
  end

  local mon = H.seedParty(game, ME.mon, 25)
  H.g3GiveMon(game, ME.spare, 5)
  check(mon ~= nil, "seeded " .. ME.mon)
  if ME.trades then
    -- the story's own gates for a trade with the other region, set the way a
    -- driver seeds a party (FLAG_SYS_CAN_LINK_WITH_RS / FLAG_IS_CHAMPION +
    -- the National Dex)
    check(H.g3AllowCrossRegionTrade(game), "this cart may now trade with the other region")
  end
  shot("field")

  -- ------- JOIN through the menus
  local code = H.codeFrom(RAW_CODE)
  if not check(code ~= nil, "a join code was supplied") then return finish() end
  if not check(H.openMmo(game), "START > MMO") then return finish() end
  if not check(H.selectLabel(game, "JOIN GAME"), "JOIN GAME") then return finish() end
  U.wait(20)
  check(H.selectLabel(game, "JOIN"), "confirmed the trainer and moved on")
  U.wait(30)
  if not check(H.addressGrid(game) ~= nil, "the address grid opened") then return finish() end
  U.tap(game, "start")
  U.wait(60)
  check(H.enterJoinCode(game, code), "the hub's code can be typed on the grid")
  U.wait(60)
  local connected = H.waitSeconds(game, function() return exports.isConnected() end, 120,
                                  "the connection to open")
  if not check(connected, "connected to the Gen 3 Node hub") then
    shot("join-FAILED")
    return finish()
  end
  H.closeToOverworld(game)
  rendezvous("ready")

  local function playerNamed(name)
    for _, p in ipairs(exports.players() or {}) do
      if p.name == name then return p end
    end
    return nil
  end
  check(H.waitSeconds(game, function()
    for _, side in ipairs(ORDER) do
      local p = side ~= ROLE and playerNamed(ROLES[side].name) or true
      if not p or (p ~= true and p.map == nil) then return false end
    end
    return true
  end, 120, "the other two on the roster"), "both other players are on the roster")
  rendezvous("seen")

  -- ------- region-scoped presence + PLAYERS
  local others = {}
  for _, side in ipairs(ORDER) do
    if side ~= ROLE then others[#others + 1] = side end
  end
  for _, side in ipairs(others) do
    local who = ROLES[side]
    local p = playerNamed(who.name)
    local sameRegion = SPOT[side][1] == spot[1]
    check(p ~= nil and p.map == SPOT[side][1],
          who.name .. " is on the roster at " .. SPOT[side][1] .. " (" .. tostring(p and p.map) .. ")")
    check(p ~= nil and p.version == (side == "c" and "emerald" or "firered"),
          "carrying their cart (" .. tostring(p and p.version) .. ")")
    if sameRegion then
      local spawned = H.waitSeconds(game, function()
        local row = H.avatarRow(exports, who.name)
        return row ~= nil and row.spawned and p and H.g3AvatarObject(p.id) ~= nil
      end, 30, who.name .. "'s avatar")
      check(spawned, who.name .. " (same map) stands here as an event object")
    else
      U.wait(30)
      local row = H.avatarRow(exports, who.name)
      check(row ~= nil and not row.spawned and (p == nil or H.g3AvatarObject(p.id) == nil),
            who.name .. " (the other region) is on the roster but not on this map")
    end
  end
  local st = exports.overlayState()
  log("overlay:", tostring(st.reached), table.concat(st.names or {}, ","))
  shot("presence")

  H.awaitToastsClear(game, exports)
  if H.openMmo(game) and H.selectLabel(game, "PLAYERS") then
    U.wait(25)
    for _, side in ipairs(others) do
      local who = ROLES[side]
      local row = H.menuRow(game, who.name)
      local want = side == "c" and "LITTLEROOT" or "PALLET"
      log("players row:", who.name, "->", tostring(row and row.right))
      check(row ~= nil and tostring(row.right or ""):find(want, 1, true) ~= nil,
            "PLAYERS names " .. who.name .. "'s place in their own region (" .. tostring(row and row.right) .. ")")
    end
    shot("players")
  else
    check(false, "MMO > PLAYERS")
  end
  H.closeToOverworld(game)
  rendezvous("presence")

  -- ------- cross-version chat
  -- each under Config.COMPOSE_MAX (16), the SAY grid's own limit
  local LINES = { a = "HI FROM ALPHA", c = "HI FROM CHARLIE" }
  if LINES[ROLE] then
    check(H.sayViaMenu(game, "EVERYONE", LINES[ROLE]), "typed " .. LINES[ROLE] .. " on the SAY grid")
    H.closeToOverworld(game)
  end
  for side, line in pairs(LINES) do
    local heard = H.waitSeconds(game, function() return H.chatHas(exports, line, ROLES[side].name) end,
                                90, line)
    check(heard, line .. " reached " .. ME.name .. " (" .. (side == "c" and "Emerald" or "FireRed")
          .. " -> " .. GAME .. ")")
  end
  shot("chat-toast")
  H.awaitToastsClear(game, exports)
  if H.openMmo(game) and H.selectLabel(game, "CHAT") then
    U.wait(20)
    shot("chat-log")
  end
  H.closeToOverworld(game)
  rendezvous("chat")

  -- ------- FireRed <-> Emerald trade (ALPHA asks CHARLIE)
  if ME.trades then
    local partner = ROLES[ME.trades]
    local theirs = H.g3Species(game, partner.mon)
    check(not H.dexOwned(game, theirs), partner.mon .. " is not in this dex yet")
    local seen, recorder, prompts = {}, H.promptLog()
    local function record(kind, top)
      recorder(kind, top)
      local key = tostring((top and (top.title or H.textOf(top))) or kind):sub(1, 24)
      if not seen[key] and #prompts <= 8 then
        seen[key] = true
        shot("trade-" .. (kind or "step"), kind == "text")
      end
    end
    if ROLE == "a" then
      local asked = false
      if H.openMmo(game) and H.selectLabel(game, "PLAYERS") then
        U.wait(25)
        if H.selectLabel(game, partner.name) then
          U.wait(25)
          shot("actions")
          asked = H.selectLabel(game, "TRADE")
        end
      end
      check(asked, "PLAYERS > " .. partner.name .. " > TRADE asks the Emerald player")
    end
    local traded, trail = H.drivePrompts(game, function()
      return H.partySpecies(game)[1] == tostring(theirs)
    end, 180, record)
    log("party now:", table.concat(H.partySpecies(game), ","))
    if not traded then
      log("trade stalled -- prompts answered:", trail == "" and "(none)" or trail)
      log("  boxes:", table.concat(prompts, " | "))
    end
    check(traded, ME.name .. " received " .. partner.name .. "'s " .. partner.mon .. " across carts")
    check(H.dexOwned(game, theirs), "and it is caught in this cart's dex")
    local got = H.partyMon(game, theirs)
    check(got ~= nil and got.otName == partner.name, "with " .. partner.name .. " as its OT ("
          .. tostring(got and got.otName) .. ")")
    H.closeToOverworld(game)
    shot("after-trade")
  end
  rendezvous("traded")

  -- ------- FireRed <-> Emerald 1v1 (ALPHA asks CHARLIE)
  --
  -- Both fighters reseed a lead and say so; ALPHA opens ACTIONS on CHARLIE
  -- through PLAYERS (they are two regions apart -- no avatar to stand beside)
  -- and picks BATTLE; CHARLIE answers; both drive the fight; BETA looks on.
  -- The asker only waits (its "Waiting for..." box is a CANCEL row), the asked
  -- one answers.
  if H.g3Leg("battle") then
    local fighter = ME.fights ~= nil
    local before
    if fighter then
      H.closeToOverworld(game)
      H.g3SetOption(game, "classicui", false)
      local lead = H.g3SeedLead(game, ME.fights[1], ME.fights[2])
      check(lead ~= nil and lead.level == ME.fights[2],
            ("a level %d %s leads the party"):format(ME.fights[2], ME.fights[1]))
      before = H.g3PartyDigest(game)
    end
    rendezvous("fightready")

    if fighter then
      local foe = ROLES[ME.trades].name
      local foeSide = ME.trades
      local started, trail
      if ROLE == "a" then
        local asked = false
        if H.openMmo(game) and H.selectLabel(game, "PLAYERS") then
          U.wait(25)
          if H.selectLabel(game, foe) then
            U.wait(25)
            shot("xcart-actions")
            asked = H.selectLabel(game, "BATTLE")
          end
        end
        check(asked, "PLAYERS > " .. foe .. " > BATTLE asks the " .. (foeSide == "c" and "Emerald" or "FireRed")
              .. " player")
        U.wait(6)
        shot("xcart-waiting")
        started = H.waitSeconds(game, function() return H.g3Fight(game) ~= nil end, 150,
                                "the asked player to accept")
      else
        local askShot = false
        started, trail = H.drivePrompts(game, function() return H.g3Fight(game) ~= nil end, 150,
          function(kind, top)
            if not askShot and kind ~= nil then
              askShot = true
              log("battle ask:", H.textOf(top))
              shot("xcart-ask", true)
            end
          end)
      end
      check(started, "the cross-cart battle started (prompts: " .. ((trail or "") == "" and "none" or trail) .. ")")
      local res = H.g3PilotFight(game, { shot = shot, label = "xcart", seconds = 300 })
      log(("xcart: kind=%s turns=%d result=%s gaps=%s"):format(tostring(res.kind), res.turns,
        tostring(res.result), tostring(res.gaps)))
      log("lines:", (table.concat(res.said, " | "):gsub("%s+", " ")))
      check(res.kind == "1v1", "the fight is the 1v1 screen (" .. tostring(res.kind) .. ")")
      check(res.ended, "the fight ran to its end and its screen closed")
      check(res.gaps == 0, "no gaps in the mediated event stream")
      check(res.seen.command and res.seen.moves, "the command menu and the move list were on screen")
      check(res.seen.hit, "a damaging turn played (the HP bar moved)")
      check(res.seen.faint, "a knockout was narrated")
      check(res.result == "win" or res.result == "loss", "the fight has a winner (" .. tostring(res.result) .. ")")
      H.signal(("g3trip_%s_result_%s"):format(ROLE, tostring(res.result)))
      H.closeToOverworld(game)
      H.g3Settle(game, 600)
      check(H.g3Idle(game), "back in the field")
      local diff = H.g3DigestDiff(before, H.g3PartyDigest(game),
        { "species", "level", "hp", "maxHp", "exp", "item", "pp", "moves" })
      check(diff == nil, "the party is exactly as it was -- HP, PP, EXP, items (link battle)", diff)
      shot("xcart-after")
      ME.result = res.result
    else
      -- BETA: on the roster of both, watching two players go busy and come back
      H.awaitToastsClear(game, exports)
      shot("xcart-onlooker")
    end
    rendezvous("fought")
    if fighter then
      local mine = ME.result
      local other = (mine == "win" and "loss") or (mine == "loss" and "win") or tostring(mine)
      local foeSide = ME.trades
      check(H.signaled(("g3trip_%s_result_%s"):format(foeSide, other)),
            ("the other cart's result is the mirror of ours (%s / %s)"):format(tostring(mine), other))
    end
  end

  -- ------- leave
  local left = false
  if H.openMmo(game) and H.selectLabel(game, "LEAVE") then
    left = H.waitSeconds(game, function() return not exports.isConnected() end, 20, "the disconnect")
  end
  check(left, "MAIN > LEAVE disconnects")
  H.closeToOverworld(game)
  rendezvous("left")
  finish()
end
