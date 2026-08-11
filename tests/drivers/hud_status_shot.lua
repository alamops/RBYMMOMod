-- One-shot: mediated 1v1 HUD with PSN / SLP in the *classic engine* layout
-- (status replaces Lxx on the level row; full HP bar). Group / co-op status
-- on the bar is CoopBattle -- exercise that via hub/LAN e2e.
--
--   SHOT_DIR=/path/to/inspect \
--   POKEPORT_IDENTITY=hudstatus POKEPORT_TOUCH=0 \
--   POKEPORT_DRIVER=mods/rby_mmo/tests/drivers/hud_status_shot.lua \
--   love .
--
-- From the Gen1Recomp checkout root, with mods/rby_mmo → RBYMMOMod.

if os.getenv("MMO_SOUND") ~= "1" and love and love.audio then
  love.audio.setVolume(0)
end

return function(game)
  local U = require("tests.drivers.util")
  local TAG = "HUD_STATUS:"
  local function log(...)
    local parts = { TAG }
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    print(table.concat(parts, "\t"))
  end

  local SHOT_DIR = os.getenv("SHOT_DIR") or "/tmp/rby_mmo_status_shots"
  os.execute('mkdir -p "' .. SHOT_DIR .. '" 2>/dev/null')

  U.newGame(game)
  if game.save and game.save.player then
    game.save.player.name = "STATUS"
  end

  local stub = {
    id = "rby_mmo",
    path = "mods/rby_mmo",
    log = {
      info = function() end,
      warn = function(_, fmt, ...)
        log("warn", string.format(tostring(fmt), ...))
      end,
      error = function(_, fmt, ...)
        log("error", string.format(tostring(fmt), ...))
      end,
    },
    assets = {
      path = function(_, rel) return "mods/rby_mmo/" .. rel end,
    },
  }
  local cache = {}
  local function resolve(name)
    if cache[name] then return cache[name] end
    local chunk = assert(loadfile("mods/rby_mmo/src/" .. name .. ".lua"))
    cache[name] = chunk(resolve, stub)
    return cache[name]
  end
  local Mediated = resolve("MediatedBattle")

  local screen = Mediated.new({
    game = game,
    role = "host",
    peerName = "FOE",
    battle = "status-shot",
    transport = { send = function() return true end },
  })
  screen.phase = "choose"
  screen.uploaded = true
  screen.mine = {
    { species = "PIKACHU", level = 25, nickname = "SPARKY",
      hp = 40, stats = { hp = 55 },
      moves = { { id = "THUNDERBOLT", pp = 15, ppMax = 15 } } },
  }
  screen.active = 1
  -- Foe poisoned, ally asleep: both tags on the right of a shortened bar;
  -- Lxx stays on the meta row.
  screen.slots[screen:foeSlot()] = {
    species = "BULBASAUR", level = 18, hp = 32, maxHp = 45,
    status = "PSN",
  }
  screen.slots[screen:mySlot()] = {
    species = "PIKACHU", level = 25, hp = 40, maxHp = 55,
    status = "SLP",
  }

  game.stack:push(screen)
  U.wait(20)
  local path = SHOT_DIR .. "/mediated-status-psn-slp.png"
  if U.shot(game, path) then
    log("captured", path)
  end
  screen.slots[screen:mySlot()].status = nil
  U.wait(10)
  local path2 = SHOT_DIR .. "/mediated-status-foe-psn-only.png"
  if U.shot(game, path2) then
    log("captured", path2)
  end
  log("DONE")
  love.event.quit(0)
end
