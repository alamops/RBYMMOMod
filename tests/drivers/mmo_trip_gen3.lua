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
-- National Dex) -- with each side's dex updated. Shots:
-- g3-<game>-<role>-<NN>-<leg>.png. Co-op / battle legs join in wave 5.

if os.getenv("MMO_SOUND") ~= "1" and love and love.audio then
  love.audio.setVolume(0)
end

local ROLES = {
  a = { name = "ALPHA",   mon = "PIKACHU",    spare = "RATTATA",   trades = "c" },
  b = { name = "BETA",    mon = "CHARMANDER", spare = "RATTATA" },
  c = { name = "CHARLIE", mon = "GEODUDE",    spare = "ZIGZAGOON", trades = "a" },
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
  local function check(ok, what)
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
  local TAGS = { "ready", "seen", "presence", "chat", "traded", "left" }
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
