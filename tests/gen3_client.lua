-- rby_mmo on a Gen 3 boot: the client wiring (src/Client.lua) and the corner
-- (src/Toast.lua) as FireRed and as Emerald.
--
-- Two halves, the way tests/rby_mmo_test.lua is split.  The first drives the
-- *real* headless loader with generation = 3 and asserts what the loader
-- captured: the START row the ui.start_menu.items link adds, the render.hud
-- link's viewport, the options schema.  The second builds a second module
-- graph on the same loader facade -- the resolver main.lua uses, through the
-- mod's own sandbox env, so a cross-generation require still throws exactly
-- as in game -- and calls the Client functions a hook would: the hello, the
-- trainer card, the party narration, the pace flag, the official-server
-- refusal, the toast geometry, the corner's charset and the screens it waits
-- behind, a friend ask waiting out the cart's own menus (Ui:whenFree), and
-- the cart's battle text cleaned of its printer codes.  Numbers here are
-- synthetic; nothing is read from a ROM.
--
-- Run from the engine checkout root:
--   luajit mods/rby_mmo/tests/gen3_client.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local GameVersion = require("src.core.GameVersion")
local check, eq = T.check, T.eq

local MOD_PATH = "mods/rby_mmo"
-- An out-of-tree checkout (an agetor worktree) whose engine symlink points
-- elsewhere: load the files this suite was read from, as the main suite does.
do
  local src = debug.getinfo(1, "S").source
  if type(src) == "string" and src:sub(1, 1) == "@" then
    local dir = src:sub(2):match("(.+)[/\\]")
    if dir then
      local fallback = dir:gsub("[/\\]tests$", "")
      local handle = io.open(fallback .. "/src/Gen.lua", "rb")
      if handle then
        handle:close()
        MOD_PATH = fallback
      end
    end
  end
end
local makeRemapFs = dofile(MOD_PATH .. "/tests/mod_remap_fs.lua")

local GATED = "registry has no Gen 3 target"

local function loadGen3(version)
  GameVersion.set(version)
  local opts = { generation = 3, data = T.sdk.gen3Data() }
  if MOD_PATH ~= "mods/rby_mmo" then opts.fs = makeRemapFs(T, MOD_PATH) end
  return T.sdk.loadMod("mods/rby_mmo", opts)
end

-- The mod's modules through its own sandbox env and the real facade, the way
-- main.lua resolves them -- but a graph of their own, so Client's locals
-- (transport, ui, party) are reachable and nothing is installed twice.
local function resolver(run)
  local api = run.loader:_api(run.mod)
  local env = run.loader:_modEnv(run.mod)
  local cache = {}
  local function need(name)
    if cache[name] ~= nil then return cache[name] end
    local body = api:read("src/" .. name .. ".lua")
    local chunk = assert(env.loadstring(body, "@rby_mmo/src/" .. name .. ".lua"))
    local value = chunk(need, api)
    cache[name] = value == nil and true or value
    return cache[name]
  end
  return need
end

local function errorText(e)
  return tostring(type(e) == "table" and (e.message or e.msg or e[1]) or e)
end

-- A Gen 3 session the way Schema.newGame shapes one, with synthetic numbers.
local function session3(version, map)
  return {
    engine = "game3", generation = 3, version = version,
    name = "ALEX", gender = 0, trainerId = 4321, secretId = 999, money = 3000,
    dex = { seen = {}, owned = {}, caught = {} }, party = {},
    flags = {}, vars = {},
    playtime = { hours = 1, minutes = 2, seconds = 3 },
    map = map, x = 5, y = 6, facing = "down",
  }
end

-- ------------------------------------------------------------------
-- 1. through the real loader
-- ------------------------------------------------------------------

local function realLoad(version)
  local label = version
  local em = version == "emerald"
  local run = loadGen3(version)
  eq(run.mod and run.mod.state, "loaded", label .. ": the mod loads on a Gen 3 boot")
  for _, e in ipairs(run.errors) do
    local text = errorText(e)
    check(text:find(GATED, 1, true) ~= nil,
      label .. ": the only load errors are gated-registry notes, not " .. text)
  end

  local Config = resolver(run)("Config")
  local session = session3(version, em and "EM_LITTLEROOT_TOWN" or "FR_PALLET_TOWN")
  local game = { generation = 3, phase = "field", session = session, data = run.data }
  run.loader.game = game

  -- ------- the seams, and the one row the options drop
  for _, hook in ipairs({ "input.step", "render.hud", "ui.start_menu.items" }) do
    local chain = run.loader.hooks.chains[hook]
    check(chain ~= nil and #chain > 0, label .. ": wraps " .. hook)
  end
  for _, name in ipairs({ "save.loaded", "save.created", "map.entered",
                          "battle.ended", "pokemon.caught", "world.interacted" }) do
    local listeners = run.loader.events.listeners[name]
    check(listeners ~= nil and #listeners > 0, label .. ": listens for " .. name)
  end
  local keys = {}
  for _, row in ipairs(run.loader.optionSchemas["rby_mmo"] or {}) do keys[row.key] = true end
  check(keys.maxplayers and keys.hub and keys.sprite,
    label .. ": the options schema is defined")
  check(not keys.run, label .. ": no B TO RUN row -- the cart runs on its own")

  -- ------- the START row
  local startLink = run.loader.hooks.chains["ui.start_menu.items"][1].callback
  local function passthrough(_, items) return items end
  local function rows(...)
    local out = {}
    for _, id in ipairs({ ... }) do out[#out + 1] = { id = id, label = id:upper() } end
    return out
  end
  local out = startLink(passthrough, game, rows("bag", "trainer", "save", "option", "exit"))
  eq(#out, 6, label .. ": one row is added to the field menu")
  eq(out[3] and out[3].id, Config.GEN3_START_ROW_ID, label .. ": the MMO row's id")
  eq(out[3] and out[3].label, "MMO", label .. ": ...and its label")
  eq(out[4] and out[4].id, Config.GEN3_START_ANCHOR_ID,
    label .. ": it sits directly before SAVE (anchored on the id)")
  check(type(out[3] and out[3].onSelect) == "function",
    label .. ": the row carries its own onSelect, which start_menu.lua dispatches")
  eq(#startLink(passthrough, game, out), 6, label .. ": a second pass adds no second row")
  local union = startLink(passthrough, game, rows("pokemon", "bag", "trainer", "option", "exit"))
  eq(#union, 5, label .. ": a menu with no SAVE row (union room, safari) gets no MMO row")
  local StartMenu = require("src.ui.game3.start_menu")
  StartMenu._tutorial = true
  eq(#startLink(passthrough, game, rows("bag", "trainer", "save", "option", "exit")), 5,
    label .. ": a tutorial menu, which hands the script a cursor index, is left alone")
  StartMenu._tutorial = false

  -- onSelect: START comes down and MAIN goes up, as the top layer.
  local Stack = require("src.ui.game3.stack")
  Stack.clear()
  StartMenu.open = true
  Stack.push("start", StartMenu, { hideBelow = true })
  out[3].onSelect(game, session)
  check(not Stack.has("start"), label .. ": selecting MMO takes the START layer down")
  eq(StartMenu.open, false, label .. ": ...through the start menu's own close")
  local top = Stack.top()
  local topId = type(top) == "table" and top.id or ""
  eq(topId:sub(1, #Config.GEN3_LAYER_PREFIX), Config.GEN3_LAYER_PREFIX,
    label .. ": and an MMO layer is on top of the game3 stack (got " .. topId .. ")")
  Stack.clear()

  -- ------- render.hud: the viewport Game3 builds has no dpi
  local hudLink = run.loader.hooks.chains["render.hud"][1].callback
  local viewport = { width = 800, height = 600, gameX = 40, gameY = 60,
                     gameWidth = 720, gameHeight = 480, scale = 3 }
  local answer = hudLink(function() return "vanilla" end, game, viewport)
  eq(answer, "vanilla", label .. ": render.hud hands back what the chain drew")
  eq(viewport.dpiX, 1, label .. ": dpiX is filled in for the overlay")
  eq(viewport.dpiY, 1, label .. ": ...and dpiY")

  -- ------- input.step runs on every phase, the title included
  -- Client's tick is the priority-0 link: Ui adds its own outer input.step
  -- link at priority 10 on Gen 3 (the offline prompt pump), which sorts first
  -- and would otherwise be the one this exercises.
  local stepLink
  for _, entry in ipairs(run.loader.hooks.chains["input.step"]) do
    if (entry.priority or 0) == 0 then stepLink = entry.callback end
  end
  check(stepLink ~= nil, label .. ": Client's input.step link is on the chain")
  check(#run.loader.hooks.chains["input.step"] >= 2,
    label .. ": ...beside Ui's own pump link")
  stepLink = stepLink or function(nxt) return nxt() end
  game.phase = "boot"
  eq(stepLink(function() return "stepped" end, game, 1 / 60), "stepped",
    label .. ": the tick passes the title screen's step through")
  game.phase = "field"

  run.loader.game = nil
  return run
end

-- ------------------------------------------------------------------
-- 2. the Client functions a hook would call
-- ------------------------------------------------------------------

local function clientGraph(run, version)
  local label = version .. " client"
  local em = version == "emerald"
  local need = resolver(run)
  local Config, Wire, Gen3 = need("Config"), need("Wire"), need("Gen3")
  local Ui = need("Ui")
  local Client = need("Client")
  local Toast = need("Toast")

  local session = session3(version, em and "EM_LITTLEROOT_TOWN" or "FR_PALLET_TOWN")
  local game = { generation = 3, phase = "field", session = session, data = run.data }
  game.save = { engine = "game3", generation = 3, version = version, money = 1,
                dex = session.dex, playTime = { hours = 0, minutes = 0, seconds = 0 } }
  run.loader.game = game

  -- ------- the trainer card: every number off the live session
  Gen3.dexMark(4, true, true)
  Gen3.dexMark(16, true, false)
  session.flags[tostring(em and 0x867 or 0x820)] = true
  local profile = Client.profile(game)
  check(profile ~= nil, label .. ": a card is built from a Gen 3 session")
  eq(profile and profile.idNo, 4321, label .. ": the id is session.trainerId")
  eq(profile and profile.badges, 1, label .. ": badges are the cart's badge flags")
  eq(profile and profile.seen, 2, label .. ": seen is counted from the session's dex")
  eq(profile and profile.owned, 1, label .. ": ...and caught")
  eq(profile and profile.playtime, 3723, label .. ": play time is { h, m, s } in seconds")
  session.trainerId = 70000
  eq(Client.profile(game).idNo, 70000 % 65536, label .. ": only the visible 16 bits ride")
  session.trainerId = 4321
  eq(Client.playerName(game), "ALEX", label .. ": the save name is session.name")
  eq(Client.ownCard(game).money, 3000, label .. ": the wallet is the session's, not the snapshot's")

  -- ------- the hello
  local sent = {}
  Client.transport.send = function(_, kind, fields)
    sent[#sent + 1] = { kind = kind, fields = fields }
  end
  Client.sendHello(game)
  local hello = sent[#sent]
  eq(hello and hello.kind, Wire.HELLO, label .. ": sendHello sends mmo.hello")
  eq(hello and hello.fields.generation, 3, label .. ": ...claiming generation 3")
  eq(hello and hello.fields.version, version, label .. ": ...and the cart it is")
  eq(hello and hello.fields.name, "ALEX", label .. ": ...under the save's name")
  eq(hello and hello.fields.profile and hello.fields.profile.idNo, 4321,
    label .. ": ...with the Gen 3 card")
  check(Wire.version(hello and hello.fields.version, 3) ~= nil,
    label .. ": and the version is one a Gen 3 hub keeps")

  -- ------- telling a partner what you fought
  Client.transport.isReady = function() return true end
  local party = Client.ctx.party
  party.has = function() return true end
  party.partner = function() return { id = "p2", name = "PAL" } end
  local function lastEvent()
    local msg = sent[#sent]
    return msg and msg.kind == Wire.PARTY_EVENT and msg.fields or nil
  end
  local before = #sent
  check(Client.narrateBattle({ wild = true, enemy = { mon = { species = 16, level = 3 } } }, "win"),
    label .. ": a won wild fight is narrated")
  local ev = lastEvent()
  eq(ev and ev.kind, "defeat_wild", label .. ": as defeat_wild")
  eq(ev and ev.species, "PIDGEY", label .. ": naming the species, not its number")
  eq(ev and ev.level, 3, label .. ": at its level")
  check(Client.narrateBattle({ wild = true, enemy = { mon = { species = 4, level = 7,
    nickname = "BOB" } } }, "lose"), label .. ": a lost wild fight is narrated")
  eq(lastEvent().kind, "defeated_by_wild", label .. ": as defeated_by_wild")
  eq(lastEvent().species, "CHARMANDER", label .. ": by species, never the nickname")
  check(Client.narrateBattle({ wild = false, trainerClassName = "LEADER",
    trainerName = "BROCK", enemy = { mon = { species = 4, level = 12 } } }, "win"),
    label .. ": a trainer win is narrated")
  eq(lastEvent().kind, "defeat_trainer", label .. ": as defeat_trainer")
  eq(lastEvent().trainer, "LEADER BROCK", label .. ": class and name, as the cart says it")
  Client.narrateBattle({ trainerClassName = "TEAM ROCKET", trainerName = "GRUNT" }, "lose")
  eq(lastEvent().kind, "defeated_by_trainer", label .. ": a trainer loss")
  eq(lastEvent().trainer, "GRUNT", label .. ": the name alone when both overrun the label")
  Client.narrateBattle({ trainerClassName = "YOUNGSTER" }, "win")
  eq(lastEvent().trainer, "YOUNGSTER", label .. ": the class alone for a nameless trainer")
  local count = #sent
  eq(Client.narrateBattle({ link = true, enemy = { mon = { species = 4, level = 5 } } }, "win"),
    false, label .. ": a link battle is Sessions', never narrated")
  eq(Client.narrateBattle({ wild = true, pokedude = true,
    enemy = { mon = { species = 16, level = 3 } } }, "win"), false,
    label .. ": nor the POKe DUDE's demonstration")
  eq(Client.narrateBattle({ wild = true, enemy = { mon = { species = 16, level = 3 } } }, "run"),
    false, label .. ": a run is silent")
  eq(Client.narrateBattle({ wild = true, enemy = { mon = { species = 16, level = 3 } } }, "catch"),
    false, label .. ": a catch is left to pokemon.caught")
  eq(#sent, count, label .. ": and none of those sent anything")
  -- pokemon.caught (battle/catching.lua emit_caught): the key name and the id
  check(Client.narrateCatch({ battle = { wild = true }, mon = { species = 29, level = 4 },
    species = "NIDORAN_F", speciesId = 29 }), label .. ": a capture is narrated")
  eq(lastEvent().kind, "capture", label .. ": as capture")
  eq(lastEvent().species, Gen3.speciesName(29), label .. ": the display name, from the id")
  local relayed = Wire.partyEvent({ kind = "capture", name = "ALEX",
    species = lastEvent().species, level = lastEvent().level })
  check(relayed ~= nil and relayed.species == "NIDORAN",
    label .. ": which the hub's sanitiser carries (the glyph the font lacks dropped)")
  eq(lastEvent().level, 4, label .. ": at the caught mon's level")
  Client.narrateCatch({ battle = { wild = true }, mon = { level = 9 }, species = "MEWTWO" })
  eq(lastEvent().species, "MEWTWO", label .. ": the payload's key name is the fallback")
  eq(Client.narrateCatch({ battle = { link = true }, mon = { species = 4, level = 5 },
    speciesId = 4 }), false, label .. ": nothing is caught in a link battle")
  check(#sent > before, label .. ": the narration went out as party events")

  -- ------- the pace flag, off the step in flight
  eq(Client.gen3StepPace({ moving = true, stepFrames = 16 }), false, label .. ": a walk is not fast")
  eq(Client.gen3StepPace({ moving = true, running = true, stepFrames = 8 }), true,
    label .. ": a run is fast")
  eq(Client.gen3StepPace({ moving = true, biking = true, running = false, stepFrames = 4 }), true,
    label .. ": a bike step is fast (Emerald's bikeStep clears `running`)")
  eq(Client.gen3StepPace({ moving = true, stepFrames = 8 }), true,
    label .. ": a short step is fast whatever set it")
  eq(Client.gen3StepPace({ moving = true, jumping = true, stepFrames = 32 }), false,
    label .. ": a ledge hop is not")
  eq(Client.gen3StepPace({ moving = true, surfing = true, stepFrames = 16 }), false,
    label .. ": surfing is a walk")
  eq(Client.gen3StepPace({ moving = false, running = true }), nil,
    label .. ": no step, no opinion -- the last step's pace stands")
  local Player = require("src.core.game3.player")
  local saved = { Player.moving, Player.running, Player.biking, Player.stepFrames,
                  Player.jumping, Player.surfing }
  Client.fastNow = false
  Player.moving, Player.running, Player.biking, Player.stepFrames = true, true, false, 8
  Player.jumping, Player.surfing = false, false
  Client.sampleGen3Pace()
  eq(Client.fastNow, true, label .. ": a running step sets the flag the presence sends")
  Player.moving, Player.running = false, false
  Client.sampleGen3Pace()
  eq(Client.fastNow, true, label .. ": standing still after it keeps the last step's pace")
  Player.moving, Player.stepFrames = true, 16
  Client.sampleGen3Pace()
  eq(Client.fastNow, false, label .. ": the next walked step clears it")
  game.phase = "boot"
  Player.running, Player.stepFrames = true, 8
  Client.sampleGen3Pace()
  eq(Client.fastNow, false, label .. ": nothing is read off the player off the field")
  game.phase = "field"
  Player.moving, Player.running, Player.biking, Player.stepFrames,
    Player.jumping, Player.surfing = saved[1], saved[2], saved[3], saved[4], saved[5], saved[6]
  Client.fastNow = false

  -- ------- the official hubs, refused in a sentence a FireRed player can use
  local said
  Client.ctx.ui.say = function(_, text) said = text end
  Client.transport.isOpen = function() return false end
  eq(Client.connect(game, Config.FEATURED_SERVERS[2].host), false,
    label .. ": the GSC official is not dialled from a Gen 3 boot")
  check(type(said) == "string" and said:find("Gen 3", 1, true) ~= nil,
    label .. ": the refusal speaks of Gen 3 (got " .. tostring(said) .. ")")
  check(type(said) == "string" and not said:find("Gold", 1, true),
    label .. ": and never tells a FireRed player to play Gold")
  said = nil
  eq(Client.connect(game, Config.FEATURED_SERVER_HOST), false,
    label .. ": nor the RBY official")
  check(type(said) == "string" and not said:find("Red, Blue", 1, true),
    label .. ": nor to play Red")

  -- ------- START > MMO, as a unit: close the start layer, push MAIN
  local Stack = require("src.ui.game3.stack")
  local StartMenu = require("src.ui.game3.start_menu")
  local pushed = {}
  local realPush = Ui.push
  Ui.push = function(g, id, opts) pushed[#pushed + 1] = { game = g, id = id, opts = opts } end
  Stack.clear()
  StartMenu.open = true
  Stack.push("start", StartMenu, { hideBelow = true })
  eq(Client.openFromStartMenu(game), true, label .. ": the row's action reports success")
  check(not Stack.has("start"), label .. ": START is off the stack")
  eq(#pushed, 1, label .. ": one screen is pushed")
  eq(pushed[1] and pushed[1].id, Ui.SCREEN.MAIN, label .. ": ...and it is MAIN")
  eq(pushed[1] and pushed[1].game, game, label .. ": ...for the game START was opened in")
  Ui.push = realPush
  Stack.clear()

  -- ------- friend asks wait while the cart's own screen is up
  local friends = Client.friends()
  eq(friends.busy(game), false, label .. ": free roam takes a friend ask")
  Stack.push("bag", { draw = function() end })
  eq(friends.busy(game), true, label .. ": the cart's bag holds it")
  Stack.push(Config.GEN3_LAYER_PREFIX .. "RbyMmoMain", { draw = function() end })
  eq(friends.busy(game), false, label .. ": the mod's own menu on top does not")
  Stack.clear()

  -- ------- the corner, inside the 240x160 rect
  local frame = Toast.gen3Frame({ gameX = 40, gameY = 60, gameWidth = 720,
                                  gameHeight = 480, scale = 3 })
  eq(frame.x, 40, label .. ": toast frame x is the game rect's")
  eq(frame.y, 60, label .. ": toast frame y is the game rect's")
  eq(frame.sx, 3, label .. ": scaled with the letterbox")
  eq(frame.sy, 3, label .. ": ...both ways (gameHeight / 160)")
  eq(Toast.gen3Frame({ gameX = 0, gameY = 0, gameWidth = 480, gameHeight = 480, scale = 2 }).sy, 3,
    label .. ": a stretched height scales on its own axis")
  local derived = Toast.gen3Frame(nil, 800, 600)
  eq(derived.sx, 3, label .. ": no viewport: the largest whole scale that fits")
  eq(derived.x, 40, label .. ": ...centred across")
  eq(derived.y, 60, label .. ": ...and down")
  local family = em and "rse" or "frlg"
  local box = Toast.gen3Box(family, 16)
  eq(box.top, (em and 40 or 24) + Toast.GEN3.INSET,
    label .. ": the stack starts below the cart's map-name popup")
  check(box.top + box.rows * box.step - Toast.GEN3.ROW_GAP <= Toast.GEN3.FLOOR,
    label .. ": and never reaches the dialogue frame")
  check(box.left + box.textWidth + Toast.GEN3.PAD_X * 2 < 112,
    label .. ": nor the player's column at the centre of the screen")
  check(box.rows <= Toast.GEN3.MAX_ROWS, label .. ": and holds at most MAX_ROWS rows")
  eq(Toast.gen3Text("[ANN]: {hi}"), "(ANN): (hi)",
    label .. ": square brackets and braces become the round ones the charset has")
  local function measure(text) return #text * 6 end
  local function wrap(text, width)
    local lines, line = {}, ""
    for word in text:gmatch("%S+") do
      local candidate = line == "" and word or (line .. " " .. word)
      if #candidate * 6 <= width then line = candidate
      else lines[#lines + 1] = line; line = word end
    end
    if line ~= "" then lines[#lines + 1] = line end
    return table.concat(lines, "\n")
  end
  local queue = {
    { text = "OLD joined the server" },
    { text = "[BOB]: " .. ("word "):rep(40) },
    { text = "NEW joined the server", color = Config.FRIEND_BLUE },
  }
  local cut = Toast.gen3Rows(queue, measure, wrap, 132, 4)
  eq(#cut, 4, label .. ": rows are capped to the room there is")
  eq(cut[#cut].text, "NEW joined the server", label .. ": ...keeping the newest")
  eq(cut[1].text:sub(1, 6), "(BOB):", label .. ": ...and dropping the oldest")
  eq(cut[#cut].color, Config.FRIEND_BLUE, label .. ": a friend's line keeps its blue")
  local all = Toast.gen3Rows(queue, measure, wrap, 132, 99)
  local bobRows = 0
  for _, row in ipairs(all) do
    check(measure(row.text) <= 132, label .. ": every row fits the plate: " .. row.text)
    if row.text:find("word", 1, true) and not row.text:find("NEW", 1, true) then
      bobRows = bobRows + 1
    end
  end
  check(bobRows <= 3, label .. ": a long line wraps to at most three rows")
  eq(all[2] and all[2].text:sub(1, 6), "(BOB):", label .. ": the chat line's brackets are mapped")
  eq(all[4] and all[4].text:sub(-3), "…", label .. ": and its last row ends in the ellipsis")

  -- One real draw, with a stand-in font in the engine's slot and the
  -- transform recorded, so the whole path is exercised headless.
  local drawn, rects, moves = {}, {}, {}
  local fakeFont = {
    GLYPH_HEIGHT = 14,
    COLOR = { WHITE = { fg = { 1, 1, 1, 1 }, shadow = { 0.4, 0.4, 0.4, 1 } } },
    measure = function(text) return #text * 6 end,
    wrap = function(text, width) return wrap(text, width) end,
    draw = function(text, x, y, opts) drawn[#drawn + 1] = { text = text, x = x, y = y, opts = opts } end,
    active = nil,
  }
  local fontSlot = { active = function() return fakeFont end }
  local savedFont = package.loaded["src.ui.game3.font"]
  package.loaded["src.ui.game3.font"] = fontSlot
  local g = love.graphics
  local savedFns = { translate = g.translate, scale = g.scale, rectangle = g.rectangle }
  g.translate = function(x, y) moves[#moves + 1] = { "translate", x, y } end
  g.scale = function(x, y) moves[#moves + 1] = { "scale", x, y } end
  g.rectangle = function(mode, x, y, w, h) rects[#rects + 1] = { x = x, y = y, w = w, h = h } end
  local toast = Toast.new({})
  toast:push("[ANN]: hi there")
  toast:push("BOB is here", Config.FRIEND_BLUE)
  toast:draw({ width = 800, height = 600, gameX = 40, gameY = 60,
               gameWidth = 720, gameHeight = 480, scale = 3 })
  g.translate, g.scale, g.rectangle = savedFns.translate, savedFns.scale, savedFns.rectangle
  package.loaded["src.ui.game3.font"] = savedFont
  local state = toast:state()
  eq(state.last.reached, "drawn", label .. ": the Gen 3 corner draws")
  eq(state.last.gen3, true, label .. ": ...on the Gen 3 path")
  eq(#drawn, 2, label .. ": one row per short line")
  eq(drawn[1] and drawn[1].text, "(ANN): hi there", label .. ": in the cart's charset")
  eq(moves[1] and moves[1][2], 40, label .. ": translated to the game rect")
  eq(moves[1] and moves[1][3], 60, label .. ": ...both ways")
  eq(moves[2] and moves[2][2], 3, label .. ": and scaled by the letterbox")
  for _, r in ipairs(rects) do
    check(r.x >= 0 and r.y >= box.top and r.x + r.w <= 240 and r.y + r.h <= Toast.GEN3.FLOOR,
      label .. ": every plate is inside the 240x160 rect, below the popup and above the "
      .. "dialogue frame")
  end
  local blue = drawn[2] and drawn[2].opts and drawn[2].opts.colors
  eq(blue and blue.fg[3], Config.FRIEND_BLUE[3], label .. ": a friend arrives in blue")

  -- ------- the corner prints the cart's charset, the way every screen does
  local Gen3Ui = need("Gen3Ui")
  local odd = "#1 *@~|^` [x] {y}\\"
  eq(Toast.gen3Text(odd), Gen3Ui.printable(odd),
    label .. ": a toast maps a line exactly as Gen3Ui's screens do")
  check(not Toast.gen3Text(odd):find("[#%*@~|%^`%[%]{}\\]"),
    label .. ": no character the cart's font draws as a blank is left")
  eq(Toast.gen3Text("#"), "\226\132\150", label .. ": '#' is the cart's own number sign")
  eq(Toast.gen3Text("@PAL"), "aPAL", label .. ": '@' is the nearest glyph the cart has")
  eq(Toast.gen3Text("PLAIN LINE"), "PLAIN LINE", label .. ": a line with nothing to map is untouched")

  -- ------- the corner waits while something covers the field
  --
  -- A mod full-screen list (Gen3Ui passes isOpaque through as the layer's
  -- `fullscreen`), the cart's own BAG, its battle, and a mod box that reaches
  -- into the column all hold it: not drawn, not aged, not dropped.  START, a
  -- mod menu against the right edge and a text box leave it up, as before.
  local viewport = { width = 800, height = 600, gameX = 40, gameY = 60,
                     gameWidth = 720, gameHeight = 480, scale = 3 }
  local prefix = Config.GEN3_LAYER_PREFIX
  package.loaded["src.ui.game3.font"] = fontSlot
  g.translate, g.scale, g.rectangle = function() end, function() end, function() end
  for i = #drawn, 1, -1 do drawn[i] = nil end
  local corner = Toast.new({})
  corner:push("#1 @PAL here")
  Stack.clear()
  eq(Toast.gen3Held(), false, label .. ": free roam: the corner is up")

  Stack.push(prefix .. "RbyMmoPlayers", { draw = function() end }, { fullscreen = true })
  eq(Toast.gen3Held(), true, label .. ": a full-screen MMO list (PLAYERS) holds the corner")
  corner:update(3)
  eq(corner:list()[1].age, 0, label .. ": ...its clock stops while held")
  corner:draw(viewport)
  eq(corner:state().last.reached, "held", label .. ": ...nothing is drawn over the list")
  eq(#drawn, 0, label .. ": ...not one row")
  eq(corner:state().count, 1, label .. ": ...and the line is kept for later")
  -- a box of the mod's over that list: the list is still drawn, still held
  Stack.push(prefix .. "RbyMmoText", { draw = function() end }, { hideBelow = false })
  eq(Toast.gen3Held(), true, label .. ": a text box over the list keeps it held")
  Stack.clear()

  Stack.push("bag", { draw = function() end }, { hideBelow = true, fullscreen = true })
  eq(Toast.gen3Held(), true, label .. ": the cart's BAG holds it")
  Stack.clear()
  Stack.push(em and "rse_pokenav" or "region_map", { draw = function() end },
             { hideBelow = true, fullscreen = true })
  eq(Toast.gen3Held(), true, label .. ": so does the cart's map")
  Stack.clear()

  Stack.push("start", { draw = function() end }, { hideBelow = false })
  eq(Toast.gen3Held(), false, label .. ": START leaves the corner up (it was drawn around it)")
  Stack.clear()
  local narrow = Gen3Ui.Menu.new(game, { { label = "PROFILE" }, { label = "TRADE" } }, { tx = 11 })
  Stack.push(prefix .. "RbyMmoActions", narrow, { hideBelow = false })
  eq(Toast.gen3Held(), false, label .. ": a mod menu against the right edge leaves it up")
  Stack.clear()
  local long = ("W"):rep(40)
  local wide = Gen3Ui.Menu.new(game, { { label = long }, { label = long }, { label = long },
                                       { label = long }, { label = long } }, {})
  Stack.push(prefix .. "RbyMmoWide", wide, { hideBelow = false })
  eq(Toast.gen3Held(), true, label .. ": a mod menu wide enough to reach the column holds it")
  Stack.clear()

  local Battle = require("src.core.game3.battle")
  local isActive = Battle.isActive
  Battle.isActive = function() return true end
  eq(Toast.gen3Held(), true, label .. ": the cart's battle holds it (the foe's HP box is there)")
  Battle.isActive = isActive
  game.phase = "boot"
  eq(Toast.gen3Held(), true, label .. ": off the field it is held")
  game.phase = "field"

  eq(Toast.gen3Held(), false, label .. ": back in the field it is not")
  corner:draw(viewport)
  eq(corner:state().last.reached, "drawn", label .. ": ...the held line is drawn")
  eq(drawn[1] and drawn[1].text, "\226\132\150" .. "1 aPAL here",
    label .. ": ...in the cart's charset")
  eq(corner:list()[1].text, "#1 @PAL here", label .. ": ...while the queue keeps it as pushed")
  corner:update(Config.TOAST_SECONDS - 1)
  eq(corner:state().count, 1, label .. ": ...with its full time still to run")
  corner:update(1)
  eq(corner:state().count, 0, label .. ": ...and it goes once that has")

  -- ------- a standing corner costs nothing per frame
  --
  -- The rows (charset mapping, wrap, ellipsis, colours, draw options) are
  -- built once per queue change and only drawn after that, and the frame's
  -- own tables are reused: 300 frames of the same two lines -- aged, held
  -- checked and drawn, as Client's tick and render.hud do -- allocate nothing.
  local quiet = {
    GLYPH_HEIGHT = 14,
    COLOR = fakeFont.COLOR,
    measure = function(text) return #text * 6 end,
    wrap = function(text, width) return wrap(text, width) end,
    draw = function() end,
  }
  local activeWas = fontSlot.active
  fontSlot.active = function() return quiet end
  local steady = Toast.new({})
  steady:push("[ANN]: a line long enough to wrap " .. ("word "):rep(8))
  steady:push("BOB is here", Config.FRIEND_BLUE)
  Stack.clear()
  steady:draw(viewport)
  eq(steady:state().last.reached, "drawn", label .. ": a standing corner draws")
  local rowsDrawn = steady:state().last.drawn
  -- the stub love's push / setColor record into tables of their own, which
  -- is the stub's allocation and not the corner's: quiet ones for the count
  local stubFns = { push = g.push, pop = g.pop, setColor = g.setColor }
  g.push, g.pop, g.setColor = function() end, function() end, function() end
  -- measured with the JIT off: a trace's own bookkeeping counts as garbage,
  -- and allocation sinking would hide exactly the tables this looks for
  local jitWas = jit and jit.status and jit.status()
  if jit then jit.off(); jit.flush() end
  collectgarbage("collect")
  collectgarbage("stop")
  local before = collectgarbage("count")
  for _ = 1, 300 do
    steady:update(0.001)
    steady:draw(viewport)
  end
  local grew = collectgarbage("count") - before
  collectgarbage("restart")
  if jit and jitWas then jit.on() end
  g.push, g.pop, g.setColor = stubFns.push, stubFns.pop, stubFns.setColor
  check(grew < 4, label .. ": 300 frames of a standing corner allocate nothing ("
    .. math.floor(grew * 1024) .. " bytes)")
  eq(steady:state().last.drawn, rowsDrawn, label .. ": ...drawing the same rows every frame")
  steady:push("NEW line")
  steady:draw(viewport)
  local lines = steady:state().last.lines or {}
  eq(lines[#lines], "NEW line", label .. ": a pushed line is drawn on the very next frame")
  steady:clear()
  steady:push("ONLY line")
  steady:draw(viewport)
  lines = steady:state().last.lines or {}
  eq(#lines, 1, label .. ": a cleared corner rebuilds from nothing")
  eq(lines[1], "ONLY line", label .. ": ...with just the new line")
  fontSlot.active = activeWas

  g.translate, g.scale, g.rectangle = savedFns.translate, savedFns.scale, savedFns.rectangle
  package.loaded["src.ui.game3.font"] = savedFont

  -- ------- a friend ask waits for the cart's own menus (Ui:whenFree)
  --
  -- A Friends with no session `busy` (that is Client's, and it is covered
  -- above), so what holds the box here is the screen alone: the real Ui's
  -- whenFree / pumpDeferred / Ui.occupied, with only the two boxes stubbed.
  local Friends = need("Friends")
  local shown = {}
  local ui = Ui.new({ game = game })
  ui.confirm = function(_, _, text, onChoose)
    shown[#shown + 1] = { kind = "confirm", text = text, onChoose = onChoose }
    return nil
  end
  ui.say = function(_, text)
    shown[#shown + 1] = { kind = "say", text = text }
    return nil
  end
  local wire = {}
  local pal = Friends.new({
    send = function(_, kind, fields) wire[#wire + 1] = { kind = kind, fields = fields } end,
    isReady = function() return true end,
  }, ui)
  pal:setHub("127.0.0.1:7788", "ALEX")
  Stack.clear()
  Stack.push("bag", { draw = function() end }, { hideBelow = true, fullscreen = true })
  eq(Ui.occupied(game), true, label .. ": the BAG open is the cart using the screen")
  pal:onAsk(game, { name = "PAL" })
  eq(#shown, 0, label .. ": a friend ask does not go up over the BAG")
  eq(pal.asking, "PAL", label .. ": ...it is taken, and waits")
  pal:onAsk(game, { name = "PAL" })
  pal:update(game, 1)
  ui:pumpDeferred(game)
  eq(#shown, 0, label .. ": ...a second delivery of it does not stack a box")
  Stack.clear()
  ui:pumpDeferred(game)
  eq(#shown, 1, label .. ": the BAG closed: the ask goes up")
  eq(shown[1] and shown[1].text, "PAL wants to be\nfriends!", label .. ": ...as the same question")
  if shown[1] and shown[1].onChoose then shown[1].onChoose(true) end
  eq(pal.asking, nil, label .. ": answering clears it")
  eq(pal:isFriend("PAL"), true, label .. ": YES still makes the friend")
  eq(wire[#wire] and wire[#wire].kind, Wire.FRIEND_ANSWER, label .. ": ...and still answers the hub")
  eq(wire[#wire] and wire[#wire].fields.accept, true, label .. ": ...with a yes")

  -- the answer to our own ask, landing while the BAG is open: the line waits too
  Stack.push("bag", { draw = function() end }, { hideBelow = true, fullscreen = true })
  pal.outgoing.BOB = true
  pal:onAnswer({ name = "BOB", accept = false })
  eq(#shown, 1, label .. ": 'said no' does not go up over the BAG")
  Stack.clear()
  ui:pumpDeferred(game)
  eq(shown[2] and shown[2].text, "BOB said no.", label .. ": ...it does once the BAG closes")

  -- a waiting ask belongs to its connection
  Stack.push("bag", { draw = function() end }, { hideBelow = true, fullscreen = true })
  pal:onAsk(game, { name = "CAL" })
  eq(pal.asking, "CAL", label .. ": another ask waits behind the BAG")
  pal:reset()
  Stack.clear()
  ui:pumpDeferred(game)
  eq(#shown, 2, label .. ": a reset drops it unseen (the hub asks again on the next welcome)")
  eq(ui.deferred and #ui.deferred or 0, 0, label .. ": ...and leaves nothing queued")

  -- nothing up at all: exactly the old path, at once
  pal:setHub("127.0.0.1:7788", "ALEX")
  pal:onAsk(game, { name = "DEE" })
  eq(#shown, 3, label .. ": in free roam an ask goes up at once")
  eq(shown[3] and shown[3].kind, "confirm", label .. ": ...as the yes / no box")
  if shown[3] and shown[3].onChoose then shown[3].onChoose(false) end
  eq(pal:isFriend("DEE"), false, label .. ": NO makes no friend")
  eq(wire[#wire] and wire[#wire].fields.accept, false, label .. ": ...and answers no")
  Stack.clear()

  -- ------- the cart's battle text, cleaned for a mod box
  eq(Gen3.cleanText("Give a nickname to the\ncaptured PIDGEY?\\p"),
    "Give a nickname to the\ncaptured PIDGEY?", label .. ": a trailing page break goes")
  eq(Gen3.cleanText("One\\pTwo\\lthree\\nfour"), "One\n\nTwo\nthree\nfour",
    label .. ": \\p is a blank line, \\l and \\n a line break")
  eq(Gen3.cleanText(Gen3.cleanText("One\\pTwo\\l")), "One\n\nTwo", label .. ": and cleaning is idempotent")
  eq(Gen3.cleanText(nil), nil, label .. ": a nil stays nil")
  local BT = "src.core.game3.battle.battle_text"
  local savedBT = package.loaded[BT]
  local pack = {
    get = function(_, fill)
      return ("Give a nickname to the\ncaptured %s?\\p"):format(tostring(fill.opponentMon1))
    end,
  }
  package.loaded[BT] = pack
  -- a graph of its own, so Gen3's module cache meets the stand-in text pack
  local fresh = resolver(run)
  local Gen3b, Genb = fresh("Gen3"), fresh("Gen")
  local prompt = Genb.nicknamePromptText(game, "PIDGEY")
  eq(prompt, "Give a nickname to the\ncaptured PIDGEY?",
    label .. ": the nickname prompt reaches the box without the printer's \\p")
  check(type(prompt) == "string" and not prompt:find("\\", 1, true),
    label .. ": no printer code is left in it")
  pack.get = function() return "One page\\pand the next\\lscrolled\\p" end
  local paged = Gen3b.battleText("STRINGID_TEST")
  eq(paged, "One page\n\nand the next\nscrolled", label .. ": battleText returns the cleaned line")
  eq(#Gen3Ui.paginate(paged), 2, label .. ": ...whose page break the Gen 3 text box pages on")
  pack.get = function() return "\\p" end
  eq(Gen3b.battleText("STRINGID_TEST"), nil, label .. ": a line that is only codes is no line")
  package.loaded[BT] = savedBT

  -- ------- your own look: no renderer to swap, Cast's graphic wrap on / off
  eq(Client.syncLook(), false, label .. ": nobody chosen, nothing worn")
  eq(Client.wornLook(), nil, label .. ": ...so wornLook is nil")
  eq(Client.applyLook(game), true, label .. ": wearing wakes Cast's player-graphic wrap")
  eq(Client.wornLook(), Client.spriteChoice(), label .. ": ...and wornLook reports the choice")
  Client.restoreLook()
  eq(Client.wornLook(), nil, label .. ": restoring takes it off")
  eq(Client.applyLook(game), true, label .. ": and a retired wrap can be worn again")
  Client.restoreLook()

  run.loader.game = nil
end

-- ------------------------------------------------------------------
-- 3. Gen 1 is untouched
-- ------------------------------------------------------------------

local function gen1Load()
  GameVersion.set("red")
  local opts = { generation = 1 }
  if MOD_PATH ~= "mods/rby_mmo" then opts.fs = makeRemapFs(T, MOD_PATH) end
  local run = T.sdk.loadMod("mods/rby_mmo", opts)
  eq(#run.errors, 0, "gen 1: loads clean")
  local keys = {}
  for _, row in ipairs(run.loader.optionSchemas["rby_mmo"] or {}) do keys[row.key] = true end
  check(keys.run, "gen 1: B TO RUN is still offered")
  local chain = run.loader.hooks.chains["world.talk"]
  eq(chain and #chain or 0, 0, "gen 1: no world.talk link is added off Gen 3")
  local startLink = run.loader.hooks.chains["ui.start_menu.items"][1].callback
  local out = startLink(function(_, items) return items end, nil, {
    { label = "POKeMON" }, { label = "ITEM" }, { label = "SAVE" }, { label = "OPTION" },
  })
  eq(out[3] and out[3].label, "MMO", "gen 1: MMO still goes in before SAVE by label")
  T.same(out[3] and out[3].desc, { "Play with", "friends" }, "gen 1: with its Gen 2 desc")

  -- the corner never waits, and a friend ask goes up at once, through the
  -- same Ui:whenFree a Gen 3 boot queues in
  local need = resolver(run)
  local Toast, Ui, Friends = need("Toast"), need("Ui"), need("Friends")
  eq(Toast.gen3Held(), false, "gen 1: the corner is never held")
  local corner = Toast.new({})
  corner:push("#1 @PAL")
  corner:update(1)
  eq(corner:list()[1].age, 1, "gen 1: the corner ages as it always has")
  eq(corner:list()[1].text, "#1 @PAL", "gen 1: and its text is its own")
  local shown = {}
  local ui = Ui.new({ game = { generation = 1 } })
  ui.confirm = function(_, _, text) shown[#shown + 1] = text end
  local pal = Friends.new({ send = function() end, isReady = function() return true end }, ui)
  pal:setHub("127.0.0.1:7788", "ASH")
  pal:onAsk({ generation = 1 }, { name = "PAL" })
  eq(shown[1], "PAL wants to be\nfriends!", "gen 1: a friend ask goes up at once")
  eq(ui.deferred and #ui.deferred or 0, 0, "gen 1: nothing is ever queued")
  run.release()
end

for _, version in ipairs({ "firered", "emerald" }) do
  local run = realLoad(version)
  clientGraph(run, version)
  run.release()
end
GameVersion.set("red")
gen1Load()

T.finish("gen3_client")
