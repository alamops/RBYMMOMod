-- Gen 3 generation-mismatch e2e: a client dials a hub locked to another
-- generation, through the real menus, and is refused -- with the reason on
-- screen.
--
-- Pair with tests/drivers/run-mismatch-e2e-gen3.sh, which starts two Node
-- hubs (one `--generation 1`, one `--generation 3`) and two games:
--
--   MMO_ROLE=fr   a FireRed (or GEN3_GAME) boot dialling the Gen 1 hub
--   MMO_ROLE=red  a Red boot dialling the Gen 3 hub
--
-- Each joins exactly the way a player does -- START > MMO > JOIN GAME > JOIN
-- > the address grid (its default is the hub the runner wrote into options)
-- > the join code on the grid -- and must end up NOT connected, with a box on
-- screen naming both generations (relay.js: "This hub is for generation N;
-- yours is generation M."). MMO_HUB_GEN / MMO_MY_GEN say which two numbers
-- to expect. Shots: g3-<game>-<role>-<NN>-<leg>.png.

io.stdout:setvbuf("line")
io.stderr:setvbuf("line")
if os.getenv("MMO_SOUND") ~= "1" and love and love.audio then
  love.audio.setVolume(0)
end

return function(game)
  local H = dofile("mods/rby_mmo/tests/drivers/mmo_util.lua")
  local U = H.U
  local ROLE = tostring(os.getenv("MMO_ROLE") or "fr"):lower()
  local TAG = "MMO_MISMATCH_" .. ROLE:upper() .. ":"
  local GAME = os.getenv("POKEPORT_VERSION") or "firered"
  local SHOT_DIR = os.getenv("SHOT_DIR") or "/tmp/rby_mmo_mismatch_gen3_shots"
  local RAW_CODE = os.getenv("MMO_HUB_CODE") or ""
  local HUB_GEN = tonumber(os.getenv("MMO_HUB_GEN") or "") or 1
  local MY_GEN = tonumber(os.getenv("MMO_MY_GEN") or "") or 3
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
  local function finish()
    H.signal("g3mismatch_" .. ROLE .. "_done")
    U.wait(30)
    log("RESULT " .. failures .. " failure(s)")
    log("DONE")
    love.event.quit(failures > 0 and 1 or 0)
  end

  local booted
  if H.isGen3(game) then
    local stage = H.G3_STAGE[GAME] or H.G3_STAGE.firered
    booted = H.bootToPlay(game, { name = "MISFIT", map = stage.map, x = stage.host[1],
                                  y = stage.host[2], facing = stage.host[3] })
  else
    booted = H.bootToPlay(game)
  end
  check(booted, "the " .. GAME .. " boot reaches the field")
  check(H.generation(game) == MY_GEN, ("this client is generation %d (%s)"):format(MY_GEN,
        tostring(H.generation(game))))
  local exports = H.requireMod(game, TAG)
  if not exports then
    failures = failures + 1
    return finish()
  end
  if not check(type(exports.isConnected) == "function",
               "the mod's multiplayer client installed (else see [rby_mmo] errors in this log)") then
    return finish()
  end

  local code = H.codeFrom(RAW_CODE)
  if not check(code ~= nil, "a join code was supplied") then return finish() end
  if not check(H.openMmo(game), "START > MMO") then return finish() end
  if not check(H.selectLabel(game, "JOIN GAME"), "JOIN GAME") then return finish() end
  U.wait(20)
  check(H.selectLabel(game, "JOIN"), "confirmed the trainer and moved on")
  U.wait(30)
  if not check(H.addressGrid(game) ~= nil, "the address grid opened") then return finish() end
  shot("address-grid")
  U.tap(game, "start")
  U.wait(60)
  check(H.enterJoinCode(game, code), "the hub's code can be typed on the grid")

  -- The refusal: a box on screen naming both generations, and no connection.
  local want = ("This hub is for generation %d"):format(HUB_GEN)
  local said
  local refused = H.waitSeconds(game, function()
    -- the box wraps its sentence over lines (Gen 1 pages hold 18
    -- columns), which textOf joins with spaces -- so compare words, not
    -- whitespace
    local text = H.textOf(H.top(game)):gsub("%s+", " ")
    if text:find("generation", 1, true) then
      said = text
      return true
    end
    return false
  end, 60, "the refusal on screen")
  log("on screen:", tostring(said))
  check(refused, "a refusal box came up")
  check(said ~= nil and said:find(want, 1, true) ~= nil
        and said:find(("yours is generation %d"):format(MY_GEN), 1, true) ~= nil,
        ("it names both generations (%d here, %d the hub's)"):format(MY_GEN, HUB_GEN))
  shot("refused", true)
  check(not exports.isConnected(), "and this client is not connected")
  check(#(exports.players() or {}) == 0, "with nobody on its roster")

  -- What comes after the box: whatever it leads to, the game has to be
  -- playable again once it is answered.
  H.closeToOverworld(game, 40)
  local after = H.top(game)
  log("after the refusal, up is:", H.stackNames(game))
  check(not exports.isConnected(), "still not connected after dismissing it")
  shot("after-refusal")
  if H.isGen3(game) then
    check(H.g3Idle(game), "the field is back")
  else
    check(after == nil or after == game.overworld or after.isOverworld, "the overworld is back")
  end

  finish()
end
