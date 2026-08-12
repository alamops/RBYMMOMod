-- Minimal Gold e2e smoke: assert Gen 2 + mod loaded; if already in free-roam,
-- open/close START once (stuck-menu regression). Never mash A through the
-- intro — that lands on PACK while StartMenu is open and looks like a flash
-- loop in the LOVE window.
--
--   POKEPORT_VERSION=gold POKEPORT_IDENTITY=... \
--     POKEPORT_DRIVER=mods/rby_mmo/tests/drivers/mmo_gold_smoke.lua love .

if os.getenv("MMO_SOUND") ~= "1" and love and love.audio then
  love.audio.setVolume(0)
end

return function(game)
  local H = dofile("mods/rby_mmo/tests/drivers/mmo_util.lua")
  local U = H.U
  local TAG = "GOLD_SMOKE:"
  local failures = 0
  local function check(ok, what)
    if ok then
      U.log(TAG, "ok", what)
    else
      failures = failures + 1
      U.log(TAG, "FAIL", what)
    end
    return ok
  end

  U.log(TAG, "boot")
  U.wait(45)

  local okHs, Handshake = pcall(require, "src.link.Handshake")
  local gen = 1
  if okHs and Handshake and type(Handshake.generation) == "function" then
    gen = tonumber(Handshake.generation(game)) or 1
  end
  check(gen == 2, "Gold smoke boots generation 2 (got " .. tostring(gen) .. ")")

  local exports = H.requireMod(game, TAG)
  check(exports ~= nil, "rby_mmo is loaded")

  -- Free-roam only: empty Gen 2 stack with a live world, or overworld on top.
  -- Do not tap A/START to reach it — A on an open StartMenu selects PACK.
  local top = game.stack and game.stack:top()
  local inWorld = (top == nil and game.world ~= nil)
    or (game.overworld and top == game.overworld)
  if inWorld then
    U.tap(game, "start")
    U.wait(16)
    top = game.stack and game.stack:top()
    check(top ~= nil and top.list ~= nil, "START opened Gen2StartMenu")
    U.tap(game, "start")
    U.wait(16)
    top = game.stack and game.stack:top()
    check(top == nil or top.list == nil,
      "START closed the Gen2 start menu (stuck-menu regression)")
  else
    U.log(TAG, "note: not in free-roam yet; skipped START open/close")
  end

  U.log(TAG, "RESULT", failures, "failure(s)")
  U.log(TAG, "DONE")
  love.event.quit(failures > 0 and 1 or 0)
end
