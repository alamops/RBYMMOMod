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
-- refusal, and the toast geometry.  Numbers here are synthetic; nothing is
-- read from a ROM.
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
  local stepLink = run.loader.hooks.chains["input.step"][1].callback
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
