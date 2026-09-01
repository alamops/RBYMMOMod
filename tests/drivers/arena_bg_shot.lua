-- Capture the three README arena backgrounds: route grass, indoor house,
-- and gym sheet. Warps, reloads the arena, pushes a mediated idle, shots.
--
--   SHOT_DIR=/path/to/inspect \
--   POKEPORT_IDENTITY=bfe2e POKEPORT_TOUCH=0 \
--   POKEPORT_DRIVER=mods/rby_mmo/tests/drivers/arena_bg_shot.lua \
--   love .
--
-- From the Gen1Recomp checkout root, with mods/rby_mmo -> this repo.

if os.getenv("MMO_SOUND") ~= "1" and love and love.audio then
  love.audio.setVolume(0)
end

return function(game)
  local U = require("tests.drivers.util")
  local H = dofile("mods/rby_mmo/tests/drivers/mmo_util.lua")
  local TAG = "ARENA_BG:"
  local function log(...)
    local parts = { TAG }
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    print(table.concat(parts, "\t"))
  end

  local SHOT_DIR = os.getenv("SHOT_DIR") or "/tmp/rby_mmo_arena_bg"
  os.execute('mkdir -p "' .. SHOT_DIR .. '" 2>/dev/null')

  H.bootToPlay(game)
  if game.save and game.save.player then
    game.save.player.name = "RED"
  end

  local PEER_ID = "arena-bg-peer"
  local saveData = { sprite = "SPRITE_RED" }
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
    save = {
      get = function(_, key) return saveData[key] end,
      set = function(_, key, value) saveData[key] = value; return true end,
    },
    options = { get = function() return nil end },
    exports = {
      players = function()
        return { { id = PEER_ID, name = "BLUE", sprite = "SPRITE_BLUE" } }
      end,
    },
    content = { sprites = { register = function() end, get = function() end } },
  }
  local cache = {}
  local function resolve(name)
    if cache[name] then return cache[name] end
    local chunk = assert(loadfile("mods/rby_mmo/src/" .. name .. ".lua"))
    cache[name] = chunk(resolve, stub)
    return cache[name]
  end
  local Mediated = resolve("MediatedBattle")
  local Battlefield = resolve("Battlefield")

  local function makeScreen()
    local screen = Mediated.new({
      game = game,
      role = "host",
      peerId = PEER_ID,
      peerName = "BLUE",
      battle = "arena-bg",
      transport = { send = function() return true end },
    })
    screen.phase = "choose"
    screen.uploaded = true
    screen.mine = {
      { species = "PIKACHU", level = 25, nickname = "SPARKY",
        hp = 40, stats = { hp = 55 },
        moves = { { id = "THUNDERBOLT", pp = 15, maxPp = 15 } } },
    }
    screen.active = 1
    screen.slots[screen:foeSlot()] = {
      species = "BULBASAUR", level = 18, hp = 32, maxHp = 45,
    }
    screen.slots[screen:mySlot()] = {
      species = "PIKACHU", level = 25, hp = 40, maxHp = 55,
    }
    screen.teams[screen:mySlot()] = "oosx"
    screen.teams[screen:foeSlot()] = "oox"
    return screen
  end

  local function liveTileset()
    local ow = game.overworld
    local map = ow and ow.map
    local def = map and map.def
    return (def and def.tileset) or (map and map.tileset) or "?"
  end

  local shots = {
    { name = "arena-route", map = "ROUTE_1", x = 10, y = 6, facing = "down" },
    { name = "arena-house", map = "REDS_HOUSE_2F", x = 3, y = 6, facing = "down" },
    { name = "arena-gym", map = "PEWTER_GYM", x = 4, y = 3, facing = "up" },
  }

  local captured = 0
  for _, spec in ipairs(shots) do
    -- Teleport rebuilds the overworld from an empty stack, so any prior
    -- battle screen is gone before the next compose reads the map.
    H.teleport(game, spec.map, spec.x, spec.y, spec.facing)
    H.waitFor(game, function()
      local ow = game.overworld
      return ow and ow.map and ow.map.id == spec.map and not ow.transitioning
    end, 180, spec.map)
    local tileset = liveTileset()
    log("warped", spec.map, "tileset=" .. tostring(tileset),
        spec.x .. "," .. spec.y)
    Battlefield.reloadArena()
    local screen = makeScreen()
    game.stack:push(screen)
    U.wait(24)
    local path = SHOT_DIR .. "/" .. spec.name .. ".png"
    if U.shot(game, path) then
      captured = captured + 1
      log("captured", path, "tileset=" .. tostring(tileset))
    else
      log("FAIL", "screenshot missed", path)
    end
  end

  log("DONE", captured .. "/" .. #shots)
  love.event.quit(captured == #shots and 0 or 1)
end
