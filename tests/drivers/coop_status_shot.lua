-- Forced co-op HUD shot: PSN / SLP on the *right of the HP bar* (group layout).
-- 1v1 mediated stays classic (status replaces Lxx) — see hud_status_shot.lua.
--
--   SHOT_DIR=/path/to/inspect \
--   POKEPORT_IDENTITY=coopstatus POKEPORT_TOUCH=0 \
--   POKEPORT_DRIVER=mods/rby_mmo/tests/drivers/coop_status_shot.lua \
--   love .

if os.getenv("MMO_SOUND") ~= "1" and love and love.audio then
  love.audio.setVolume(0)
end

return function(game)
  local U = require("tests.drivers.util")
  local H = dofile("mods/rby_mmo/tests/drivers/mmo_util.lua")
  local Pokemon = require("src.pokemon.Pokemon")
  local TAG = "COOP_STATUS:"
  local function log(...)
    local parts = { TAG }
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    print(table.concat(parts, "\t"))
  end

  local SHOT_DIR = os.getenv("SHOT_DIR") or "/tmp/rby_mmo_coop_status"
  os.execute('mkdir -p "' .. SHOT_DIR .. '" 2>/dev/null')

  -- H.newGame, not U.newGame: the engine helper's A-tap budget is shorter
  -- than the intro and it reports nothing when it runs out, so a short run
  -- hands back a game still in Oak's speech and the shot is of the wrong
  -- screen. See the note above M.newGame in mmo_util.lua.
  if not H.newGame(game, TAG) then
    log("FAIL could not reach the overworld")
    return
  end
  if game.save and game.save.player then
    game.save.player.name = "HOSTY"
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
  local CoopBattle = resolve("CoopBattle")

  local function mon(id, level)
    return Pokemon.new(game.data, id, level)
  end

  local screen, err = CoopBattle.new(game, {
    mine = 1,
    host = true,
    mode = "coop_npc",
    battleId = "status-shot",
    selfId = "host",
    slots = {
      { side = "a", owner = "host", name = "HOSTY",
        party = { mon("CHARIZARD", 50) } },
      { side = "a", owner = "friend", name = "FRIEND",
        party = { mon("BLASTOISE", 50) } },
      { side = "b", owner = nil, name = "FOE",
        party = { mon("VENUSAUR", 50) } },
      { side = "b", owner = nil, name = "FOE",
        party = { mon("PIDGEOT", 45) } },
    },
  })
  if not screen then
    log("FAIL CoopBattle.new:", err)
    love.event.quit(1)
    return
  end

  -- Focus seats + choose phase so both HUD panels draw.
  screen.phase = "choose"
  screen.mediated = true
  screen.stageAlly = 1
  screen.stageFoe = 3
  -- Status on the focused ally + foe: bar shortens, Lxx stays.
  local ally = screen.sim:slot(1)
  local foe = screen.sim:slot(3)
  if ally and ally.battler and ally.battler.mon then
    ally.battler.mon.status = "SLP"
  end
  if foe and foe.battler and foe.battler.mon then
    foe.battler.mon.status = "PSN"
  end

  game.stack:push(screen)
  U.wait(30)
  local path = SHOT_DIR .. "/coop-status-psn-slp.png"
  if U.shot(game, path) then
    log("captured", path)
  end
  log("DONE")
  love.event.quit(0)
end
