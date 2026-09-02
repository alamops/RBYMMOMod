-- Driver: five guests, party-of-3 vs party-of-2 size mismatch.
--
-- Five instances under MMO_ROLE=a|b|c|d|e, launched by
-- tests/drivers/run-party-mismatch-e2e.sh (Node hub, all JOIN).
--
--   a ALPHA + b BETA + c CHARLIE  vs  d DELTA + e ECHO
--   ALPHA asks DELTA for PARTY BATTLE → spoken mismatch, ask cleared.

if os.getenv("MMO_SOUND") ~= "1" and love and love.audio then
  love.audio.setVolume(0)
end

local ROLES = {
  a = { name = "ALPHA",   species = "CHARIZARD", level = 45, side = 3, lead = true },
  b = { name = "BETA",    species = "PIKACHU",    level = 45, side = 3 },
  c = { name = "CHARLIE", species = "BLASTOISE",   level = 45, side = 3 },
  d = { name = "DELTA",   species = "VENUSAUR",   level = 45, side = 2, lead = true },
  e = { name = "ECHO",    species = "ALAKAZAM",  level = 45, side = 2 },
}
local ORDER = { "a", "b", "c", "d", "e" }

local ROLE = tostring(os.getenv("MMO_ROLE") or "a"):lower()
if not ROLES[ROLE] then ROLE = "a" end

return function(game)
  local H = dofile("mods/rby_mmo/tests/drivers/mmo_util.lua")
  local U = H.U
  local TAG = "MMO_MISMATCH_" .. ROLE:upper() .. ":"
  local ME = ROLES[ROLE]
  local SHOT_DIR = os.getenv("SHOT_DIR") or "/tmp/rby_mmo_mismatch_shots"
  local RAW_CODE = os.getenv("MMO_HUB_CODE") or ""

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
  local function shot(name)
    U.shot(game, ("%s/mismatch-%s-%s.png"):format(SHOT_DIR, ROLE, name))
  end

  local function marker(side, tag) return ("mismatch_%s_%s"):format(side, tag) end

  local function rendezvous(tag)
    H.signal(marker(ROLE, tag))
    local ok = true
    for _, side in ipairs(ORDER) do
      if side ~= ROLE then
        if not H.await(game, marker(side, tag)) then ok = false end
      end
    end
    return ok
  end

  local TAGS = { "ready", "seen", "paired", "challenged", "cleared", "left" }
  local function abandon()
    for _, tag in ipairs(TAGS) do H.signal(marker(ROLE, tag)) end
  end

  local function bail(what)
    check(false, what)
    abandon()
    log(("RESULT %d failure(s)"):format(failures))
    log("DONE")
    U.wait(30)
    love.event.quit()
  end

  if not H.newGame(game, TAG) then
    log("RESULT 1 failure(s)")
    return
  end
  if game.save and game.save.player then
    game.save.player.name = ME.name
  end

  local exports = H.requireMod(game, TAG)
  if not exports then
    abandon()
    log("RESULT 1 failure(s)")
    log("DONE")
    return
  end

  local Pokemon = require("src.pokemon.Pokemon")
  game.save.party = { Pokemon.new(game.data, ME.species, ME.level) }

  local code = H.codeFrom(RAW_CODE)
  if not code then bail("a join code was supplied") return end

  if not H.openMmo(game) then bail("the MMO menu opens") return end
  if not H.selectLabel(game, "JOIN GAME") then bail("JOIN GAME is on the menu") return end
  U.wait(20)
  check(H.selectLabel(game, "JOIN"), "confirmed the trainer and moved on")
  U.wait(20)
  if H.addressGrid(game) == nil then bail("the address screen opened") return end
  U.tap(game, "start")
  U.wait(60)
  check(H.enterJoinCode(game, code), "the hub's code can be typed on the grid")
  U.wait(60)

  local connected = H.waitSeconds(game, function() return exports.isConnected() end,
                                  120, "the connection to open")
  if not connected then bail("connected to the dedicated hub") return end
  check(connected, "connected to the dedicated hub")
  H.closeToOverworld(game)
  H.signal(marker(ROLE, "ready"))
  for _, side in ipairs(ORDER) do
    if side ~= ROLE then H.await(game, marker(side, "ready")) end
  end

  check(H.waitSeconds(game, function() return #exports.players() >= 4 end, 120,
                      "the other four to appear on the roster"),
        "all four other guests are on the roster")
  rendezvous("seen")

  local function invite(name)
    H.closeToOverworld(game)
    if H.openMmo(game) and H.selectLabel(game, "PLAYERS") then
      U.wait(25)
      if H.selectLabel(game, name) then
        U.wait(30)
        return H.selectLabel(game, "INVITE")
      end
    end
    return false
  end

  local targetSize = ME.side == 3 and 3 or 2
  if ME.lead then
    if ME.side == 3 then
      check(invite(ROLES.b.name), "invited the second member")
      check(H.waitSeconds(game, function() return #exports.party() >= 2 end, 90,
                          "the second member to join"),
            "the second member joined")
      check(invite(ROLES.c.name), "invited the third member")
    else
      check(invite(ROLES.e.name), "invited the partner")
    end
  end

  check(H.drivePrompts(game, function() return #exports.party() == targetSize end, 120),
        ("the party formed with %d members"):format(targetSize))
  H.closeToOverworld(game)
  rendezvous("paired")

  if ROLE == "a" then
    local sawMismatch = ""
    if H.openMmo(game) and H.selectLabel(game, "PLAYERS")
        and H.selectLabel(game, ROLES.d.name) then
      U.wait(30)
      check(H.selectLabel(game, "PARTY BATTLE"),
            "asked a smaller party for PARTY BATTLE")
      local declined = H.waitSeconds(game, function()
        local text = H.textOf(H.top(game)) or ""
        if text ~= "" then sawMismatch = text end
        if text:find("Party sizes", 1, true)
           or text:find("don't match", 1, true)
           or text:find("don\'t match", 1, true) then
          return true
        end
        for _, line in ipairs(exports.chat() or {}) do
          local row = tostring(line.text or "")
          if row:find("Party sizes", 1, true)
             or row:find("don't match", 1, true)
             or row:find("don\'t match", 1, true) then
            sawMismatch = row
            return true
          end
        end
        return false
      end, 90, "the mismatch refusal on the asker")
      check(declined, "the asker saw the party-size mismatch")
      log("mismatch text:", sawMismatch == "" and "(sampled)" or sawMismatch)
      check(sawMismatch:find("Party sizes", 1, true) ~= nil
            or sawMismatch:find("match", 1, true) ~= nil,
            "and the copy names a size mismatch")
      U.wait(30)
      shot("mismatch-box")
    else
      check(false, "opened PLAYERS to challenge DELTA")
    end
    H.drivePrompts(game, function()
      return exports.coopAsk() == nil
    end, 60)
    check(exports.coopAsk() == nil, "the outgoing ask cleared on the asker")
    check(exports.coopPlan() == nil, "and no battle was planned behind it")
    H.closeToOverworld(game)
    check(H.openMmo(game) and H.selectLabel(game, "PLAYERS")
          and H.selectLabel(game, ROLES.d.name),
          "can open PLAYERS against DELTA again after the refusal")
    local labels = H.menuLabels(game)
    local canAskAgain = false
    for _, label in ipairs(labels) do
      if label == "PARTY BATTLE" then canAskAgain = true end
    end
    check(canAskAgain, "PARTY BATTLE is offered again -- no hanging ask")
    H.closeToOverworld(game)
  end

  rendezvous("challenged")

  local top = H.top(game)
  check(top == nil or top.sim == nil,
        "no battle started on this instance after the mismatch")
  check(exports.coopAsk() == nil, "coopAsk is clear on every instance")
  check(exports.coopPlan() == nil, "coopPlan is clear on every instance")
  rendezvous("cleared")

  for _ = 1, 3 do
    if not exports.isConnected() then break end
    H.closeToOverworld(game)
    if H.openMmo(game) and H.selectLabel(game, "LEAVE") then
      U.wait(45)
      if H.waitSeconds(game, function() return not exports.isConnected() end, 30,
                       "this instance to leave") then
        break
      end
    end
    U.wait(30)
  end
  check(H.waitSeconds(game, function() return not exports.isConnected() end, 30,
                      "this instance to leave"),
        "LEAVE disconnects this guest")
  H.signal(marker(ROLE, "left"))

  log(("RESULT %d failure(s)"):format(failures))
  log("DONE")
  U.wait(60)
  love.event.quit()
end
