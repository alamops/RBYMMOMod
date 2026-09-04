-- Classic 160×144 battle chrome screenshots (CLASSIC BATTLE UI on).
--
-- One LOVE instance, real ROM HUD tiles / party icons / battle pics.
-- Captures 1v1, 2x2, and 3x3 so a reviewer can see field scale, side-strip
-- bag icons, and HUD chrome without a two-client fight.
--
--   SHOT_DIR=/path/to/inspect \
--   POKEPORT_IDENTITY=classicui POKEPORT_TOUCH=0 \
--   POKEPORT_DRIVER=mods/rby_mmo/tests/drivers/classic_battle_shot.lua \
--   love .
--
-- Wrapped by tests/drivers/run-classic-battle-e2e.sh.

if os.getenv("MMO_SOUND") ~= "1" and love and love.audio then
  love.audio.setVolume(0)
end

return function(game)
  local U = require("tests.drivers.util")
  local H = dofile("mods/rby_mmo/tests/drivers/mmo_util.lua")
  local Pokemon = require("src.pokemon.Pokemon")
  local TAG = "CLASSIC_SHOT:"
  local function log(...)
    local parts = { TAG }
    for i = 1, select("#", ...) do
      parts[#parts + 1] = tostring(select(i, ...))
    end
    print(table.concat(parts, "\t"))
  end

  local SHOT_DIR = os.getenv("SHOT_DIR") or "/tmp/rby_mmo_classic_shots"
  os.execute('mkdir -p "' .. SHOT_DIR .. '" 2>/dev/null')

  if not H.newGame(game, TAG) then
    log("FAIL could not reach the overworld")
    love.event.quit(1)
    return
  end
  if game.save and game.save.player then
    game.save.player.name = "CLASSIC"
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
    options = {
      get = function(_, key) return key == "classicui" end,
    },
  }
  local cache = {}
  local function resolve(name)
    if cache[name] then return cache[name] end
    local chunk = assert(loadfile("mods/rby_mmo/src/" .. name .. ".lua"))
    cache[name] = chunk(resolve, stub)
    return cache[name]
  end

  local pass, fail = 0, 0
  local function check(cond, label, detail)
    if cond then
      pass = pass + 1
      log("PASS", label, detail or "")
    else
      fail = fail + 1
      log("FAIL", label, detail or "")
    end
  end

  local function shot(name)
    local path = SHOT_DIR .. "/" .. name
    if U.shot(game, path) then
      log("captured", path)
      return path
    end
    log("FAIL", "screenshot missed", path)
    fail = fail + 1
    return nil
  end

  local function skipIntro(screen)
    screen.introHide = nil
    screen.introBalls = nil
    screen.messages = {}
    screen.shown = nil
    screen.phase = "choose"
  end

  local pokedex = (game.data and game.data.pokemon) or {}
  local function firstPresent(...)
    for _, key in ipairs({ ... }) do
      if type(pokedex[key]) == "table" then return key end
    end
    return nil
  end
  local function mon(id, level)
    return Pokemon.new(game.data, id, level)
  end

  -- --------------------------------------------------------- 1v1 classic
  local Mediated = resolve("MediatedBattle")
  local one = Mediated.new({
    game = game,
    role = "host",
    peerName = "FOE",
    battle = "classic-1v1",
    transport = { send = function() return true end },
    classicUi = true,
  })
  check(one.classicUi == true, "1v1 latched classicUi")
  check(one:usesBattlefield() == false, "1v1 usesBattlefield is false")
  local mineSp = firstPresent("PIKACHU", "SQUIRTLE", "CHARMANDER") or "PIKACHU"
  local foeSp = firstPresent("BULBASAUR", "PIDGEY", "RATTATA") or "BULBASAUR"
  one.phase = "choose"
  one.uploaded = true
  one.mine = {
    { species = mineSp, level = 25, nickname = "SPARKY",
      hp = 40, stats = { hp = 55 },
      moves = { { id = "THUNDERBOLT", pp = 15, maxPp = 15 } } },
  }
  one.active = 1
  one.slots[one:foeSlot()] = {
    species = foeSp, level = 18, hp = 32, maxHp = 45,
  }
  one.slots[one:mySlot()] = {
    species = mineSp, level = 25, hp = 40, maxHp = 55,
    shownExpFrac = 0.45,
  }
  game.stack:push(one)
  U.wait(8)
  pcall(function() one:refreshSlotSprite(one:foeSlot(), false) end)
  pcall(function() one:refreshSlotSprite(one:mySlot(), true) end)
  skipIntro(one)
  one.phase = "choose"
  U.wait(20)
  local mineSlot = one.slots[one:mySlot()]
  local foeSlot = one.slots[one:foeSlot()]
  check(mineSlot and mineSlot.sprite ~= nil, "1v1 ally back sprite loaded",
    mineSp)
  check(foeSlot and foeSlot.sprite ~= nil, "1v1 foe front sprite loaded",
    foeSp)
  if mineSlot and mineSlot.sprite then
    local ok, w, h = pcall(mineSlot.sprite.getDimensions, mineSlot.sprite)
    local _, _, scale = one:playerPicXY(mineSlot.sprite)
    log("1v1 ally pic", tostring(w) .. "x" .. tostring(h),
      "scale=" .. tostring(scale))
    check(type(scale) == "number" and scale % 1 == 0,
      "1v1 ally scale is integer", tostring(scale))
    check(scale >= 1, "1v1 ally scale is not a shrink", tostring(scale))
  end
  shot("classic-1v1-choose.png")
  pcall(function() game.stack:pop() end)
  U.wait(4)

  -- --------------------------------------------------------- 2x2 / 3x3
  local CoopBattle = resolve("CoopBattle")

  local function buildCoop(slots, label)
    local screen, err = CoopBattle.new(game, {
      mine = 1,
      host = true,
      mode = "coop_npc",
      battleId = "classic-" .. label,
      selfId = "host",
      classicUi = true,
      slots = slots,
    })
    if not screen then
      log("FAIL CoopBattle.new", label, tostring(err))
      fail = fail + 1
      return nil
    end
    check(screen.classicUi == true, label .. " latched classicUi")
    check(screen:usesBattlefield() == false,
      label .. " usesBattlefield is false")
    return screen
  end

  local function afterPush(screen, label)
    local keepPhase = screen.phase
    skipIntro(screen)
    if keepPhase == "target" or keepPhase == "move" then
      screen.phase = keepPhase
    end
    screen.mediated = true
    local mine = screen.sim and screen.sim:slot(1)
    if mine and mine.battler then mine.battler.shownExpFrac = 0.45 end
    U.wait(16)
    local extrasAlly = CoopBattle.stripSeats(screen, false)
    local extrasFoe = CoopBattle.stripSeats(screen, true)
    log(label, "strip seats ally=" .. tostring(#(extrasAlly or {})),
      "foe=" .. tostring(#(extrasFoe or {})))
    local allyIdx = screen:desiredAllyFocus()
    local battler = allyIdx and screen:shownBattlerAt(allyIdx)
    local sprite = battler and battler.sprite
    if sprite then
      local x, y, scale = screen:picOriginFor(allyIdx, sprite)
      local ok, w, h = pcall(sprite.getDimensions, sprite)
      log(label, "ally field", tostring(w) .. "x" .. tostring(h),
        "scale=" .. tostring(scale), "xy=" .. tostring(x) .. "," .. tostring(y))
      check(type(scale) == "number" and scale % 1 == 0,
        label .. " ally field scale is integer", tostring(scale))
      check(scale >= 1, label .. " ally field is not shrunk", tostring(scale))
    else
      log("warn", label, "no ally sprite to measure")
    end
    for _, idx in ipairs(extrasAlly or {}) do
      local icon = screen:stripIconImage(idx)
      local shown = screen:shownBattlerAt(idx)
      local usedSprite = icon == nil and shown and shown.sprite ~= nil
      check(not usedSprite,
        label .. " strip " .. tostring(idx) .. " is not the stage pic")
    end
  end

  local two = buildCoop({
    { side = "a", owner = "host", name = "CLASSIC",
      party = { mon(firstPresent("CHARIZARD", "CHARMANDER") or "CHARMANDER", 50) } },
    { side = "a", owner = "friend", name = "FRIEND",
      party = { mon(firstPresent("BLASTOISE", "SQUIRTLE") or "SQUIRTLE", 50) } },
    { side = "b", owner = nil, name = "FOE",
      party = { mon(firstPresent("VENUSAUR", "BULBASAUR") or "BULBASAUR", 50) } },
    { side = "b", owner = nil, name = "FOE2",
      party = { mon(firstPresent("PIDGEOT", "PIDGEY") or "PIDGEY", 45) } },
  }, "2x2")
  if two then
    game.stack:push(two)
    U.wait(8)
    afterPush(two, "2x2")
    two.phase = "choose"
    U.wait(10)
    shot("classic-2x2-choose.png")
    two.phase = "target"
    two.targetIndex = 1
    two.stageFoe = nil
    two.slideFoe = nil
    two:beginFocusSlides()
    U.wait(10)
    afterPush(two, "2x2-target")
    shot("classic-2x2-target.png")
    two.targetIndex = 2
    two:beginFocusSlides()
    U.wait(6)
    shot("classic-2x2-target-slide.png")
    U.wait(10)
    afterPush(two, "2x2-target2")
    shot("classic-2x2-target2.png")
    pcall(function() game.stack:pop() end)
    U.wait(4)
  end

  local hex = buildCoop({
    { side = "a", owner = "host", name = "CLASSIC",
      party = { mon(firstPresent("CHARIZARD", "CHARMANDER") or "CHARMANDER", 50) } },
    { side = "a", owner = "friend", name = "FRIEND",
      party = { mon(firstPresent("BLASTOISE", "SQUIRTLE") or "SQUIRTLE", 50) } },
    { side = "a", owner = "third", name = "THIRD",
      party = { mon(firstPresent("NIDOKING", "NIDORINO") or "RATTATA", 48) } },
    { side = "b", owner = nil, name = "FOE",
      party = { mon(firstPresent("VENUSAUR", "BULBASAUR") or "BULBASAUR", 50) } },
    { side = "b", owner = nil, name = "FOE2",
      party = { mon(firstPresent("PIDGEOT", "PIDGEY") or "PIDGEY", 45) } },
    { side = "b", owner = nil, name = "FOE3",
      party = { mon(firstPresent("ARCANINE", "GROWLITHE") or "SPEAROW", 44) } },
  }, "3x3")
  if hex then
    game.stack:push(hex)
    U.wait(8)
    afterPush(hex, "3x3")
    hex.phase = "choose"
    U.wait(10)
    shot("classic-3x3-choose.png")
    hex.phase = "target"
    hex.targetIndex = 1
    hex.stageFoe = nil
    hex.slideFoe = nil
    hex:beginFocusSlides()
    U.wait(10)
    afterPush(hex, "3x3-target")
    shot("classic-3x3-target.png")
    hex.targetIndex = 2
    hex:beginFocusSlides()
    U.wait(6)
    shot("classic-3x3-target-slide.png")
    U.wait(10)
    afterPush(hex, "3x3-target2")
    shot("classic-3x3-target2.png")
    pcall(function() game.stack:pop() end)
  end

  log("GAPS:" .. tostring(fail))
  log("DONE", pass .. " pass", fail .. " fail")
  love.event.quit(fail == 0 and 0 or 1)
end
