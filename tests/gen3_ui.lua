-- rby_mmo's screens on a Gen 3 boot: src/Gen3Ui.lua (the mod.ui surface on the
-- game3 modal stack) and every src/Ui.lua screen built on it, as FireRed and
-- as Emerald.
--
-- The mod is loaded through the real headless loader with generation = 3 and
-- its modules resolved the way main.lua resolves them -- through the mod's own
-- sandbox env, so a cross-generation require still throws exactly as in game.
-- The stack is the engine's own src/ui/game3/stack.lua (pure Lua, loads
-- headless); the frame loop is hud.lua's order, spelled below: the top layer's
-- update(dt), then the top layer's handleInput(input) -- read again, because
-- update may have changed it.  love.graphics is a recording stub, so every
-- draw path runs and a throw in one fails the suite; there are no pixels
-- here and no ROM (the numbers are synthetic, T.sdk.gen3Data's fixture).
--
-- The game handed to every screen raises on `game.stack`: Game3 has none, and
-- a screen that reached for it would throw on a real boot.
--
-- Run from the engine checkout root:
--   luajit mods/rby_mmo/tests/gen3_ui.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local GameVersion = require("src.core.GameVersion")
local check, eq = T.check, T.eq

local MOD_PATH = "mods/rby_mmo"
do
  local src = debug.getinfo(1, "S").source
  if type(src) == "string" and src:sub(1, 1) == "@" then
    local dir = src:sub(2):match("(.+)[/\\]")
    if dir then
      local fallback = dir:gsub("[/\\]tests$", "")
      local handle = io.open(fallback .. "/src/Gen3Ui.lua", "rb")
      if handle then
        handle:close()
        MOD_PATH = fallback
      end
    end
  end
end
local makeRemapFs = dofile(MOD_PATH .. "/tests/mod_remap_fs.lua")

-- ------- love.graphics, recorded

local drawn = {}
local function recorder(name)
  return function(...)
    drawn[#drawn + 1] = { name, ... }
  end
end
local graphics = setmetatable({}, { __index = function(_, key) return recorder(key) end })
graphics.newQuad = function(x, y, w, h)
  return { getViewport = function() return x, y, w, h end }
end
graphics.getColor = function() return 1, 1, 1, 1 end
local previousLove = _G.love
_G.love = { graphics = graphics }

-- ------- the loader and the module graph

local function loadGen3(version)
  GameVersion.set(version)
  local opts = { generation = 3, data = T.sdk.gen3Data() }
  if MOD_PATH ~= "mods/rby_mmo" then opts.fs = makeRemapFs(T, MOD_PATH) end
  return T.sdk.loadMod("mods/rby_mmo", opts)
end

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

-- ------- input and the frame loop

local Input = {}
Input.__index = Input
function Input:wasPressed(btn) return self.pressed[btn] == true end
function Input:isDown(btn) return self.state[btn] == true end
local function newInput() return setmetatable({ pressed = {}, state = {} }, Input) end

local Stack = require("src.ui.game3.stack")

-- One fixed step: Input:step (a new `pressed` table), then hud.lua's order.
local function step(game, ...)
  local input = game.input
  input.pressed, input.state = {}, {}
  for _, btn in ipairs({ ... }) do
    input.pressed[btn] = true
    input.state[btn] = true
  end
  local top = Stack.top()
  if top and top.mod and type(top.mod.update) == "function" then top.mod.update(1 / 60) end
  top = Stack.top()
  if top and top.mod and type(top.mod.handleInput) == "function" then
    top.mod.handleInput(input)
  end
end

local function steps(game, n, ...)
  for _ = 1, n do step(game, ...) end
end

-- Every visible layer drawn bottom-up, the way ui_pass.lua does; false and
-- the error when one of them threw.
local function drawAll()
  drawn = {}
  for _, layer in ipairs(Stack.drawOrder()) do
    local ok, err = pcall(layer.mod.draw)
    if not ok then return false, err end
  end
  return true
end

local function labels(screen)
  local out = {}
  for _, item in ipairs((screen and screen.items) or {}) do out[#out + 1] = tostring(item.label) end
  return table.concat(out, ",")
end

local function topId()
  local top = Stack.top()
  return top and top.id
end

-- press down until the cursor is on `label`, then A -- mmo_util.selectLabel's
-- rule, on the driver contract (items[i].label, cursor)
local function select(game, label)
  local menu = Stack.top() and Stack.top().mod
  if not (menu and menu.items) then return false end
  local target
  for i, item in ipairs(menu.items) do
    if item.label == label then target = i break end
  end
  if not target then return false end
  local moves = (target - (menu.cursor or 1)) % #menu.items
  for _ = 1, moves do step(game, "down") end
  step(game, "a")
  return true
end

-- type `text` on a Gen3Ui naming grid by walking to each cell, the way a
-- driver does; flips the page when the character is on the other one
local function typeOn(game, screen, text)
  for i = 1, #text do
    local ch = text:sub(i, i)
    local found
    for pass = 1, 2 do
      for r, row in ipairs(screen:grid()) do
        for c, cell in ipairs(row) do
          if cell == ch and not found then found = { r, c } end
        end
      end
      if found then break end
      step(game, "select")
    end
    if not found then return false end
    screen.row, screen.col = found[1], found[2]
    step(game, "a")
  end
  return true
end

-- ------- a game with no stack, and a ctx for Ui

local function session3(version, map)
  return {
    engine = "game3", generation = 3, version = version,
    name = "ALEX", gender = 0, trainerId = 4321, secretId = 999, money = 3000,
    dex = { seen = {}, owned = {}, caught = {} },
    party = {
      { species = 4, level = 5, nickname = "" },
      { species = 7, level = 7, nickname = "BUBBLES" },
    },
    flags = {}, vars = {},
    map = map, x = 5, y = 6, facing = "down",
  }
end

local stackTouched = 0
local function newGame(run, session)
  local game = { generation = 3, phase = "field", session = session, data = run.data,
                 input = newInput() }
  setmetatable(game, { __index = function(_, key)
    if key == "stack" then stackTouched = stackTouched + 1 end
    return nil
  end })
  return game
end

local function newCtx(game, st)
  local ctx = { game = game }
  local function player(id)
    for _, p in ipairs(st.players or {}) do if p.id == id then return p end end
    return nil
  end
  ctx.client = {
    isHosting = function() return st.hosting == true end,
    isConnected = function() return st.connected == true end,
    playerName = function() return st.name or "ALEX" end,
    setPlayerName = function(_, n) st.name = n end,
    spriteChoice = function() return st.sprite or "OBJ_EVENT_GFX_RED_NORMAL" end,
    setSpriteChoice = function(_, id) st.sprite = id end,
    hostJoinCode = function() return st.code end,
    setHostJoinCode = function(_, c) st.code = c return c end,
    newJoinCode = function() return "A7K3P9" end,
    maxPlayers = function() return 8 end,
    setMaxPlayers = function(_, n) st.max = n end,
    host = function() st.hosted = true return true end,
    hostAddress = function() return "192.168.1.20:7788" end,
    joinAddress = function() return st.joinAddress end,
    setJoinAddress = function(_, a) st.joinAddress = a return a end,
    setJoinCode = function(_, a, c) st.joinCode = c end,
    connect = function() st.dialled = true return true end,
    leave = function() st.left = true end,
    ownCard = function()
      return { name = "ALEX", sprite = "OBJ_EVENT_GFX_RED_NORMAL", money = 3000, points = 12,
               profile = { idNo = 4321, playtime = 3723, badges = 2, seen = 10, owned = 4 } }
    end,
    ranking = function() return st.ranking or {}, true, true end,
    requestRanking = function() st.askedRanking = true end,
    say = function(_, scope, text, to) st.said = { scope = scope, text = text, to = to } end,
  }
  ctx.roster = {
    sorted = function() return st.players or {} end,
    get = function(_, id) return player(id) end,
  }
  ctx.party = {
    has = function() return st.inParty == true end,
    count = function() return 2 end,
    isPartner = function(_, id) return id == st.partner end,
    list = function() return {} end,
    isSelf = function() return false end,
    partnerName = function() return "BOB" end,
    leave = function() st.leftParty = true end,
    invite = function(_, p) st.invited = p.id end,
  }
  ctx.friends = {
    sorted = function() return st.friendRows or {} end,
    isFriend = function(_, name) return name == "BOB" end,
    ask = function() end,
    remove = function() end,
  }
  ctx.coop = {
    pendingOffer = function() return nil end,
    wantsWild = function() return true end,
    wantsNpc = function() return true end,
    setWantsWild = function() end,
    setWantsNpc = function() end,
  }
  ctx.chat = { markRead = function() end, recent = function() return st.chat or {} end }
  ctx.sessions = { request = function(_, p, kind) st.requested = kind end }
  local servers = {
    { key = "a", name = "HOME HUB", address = "192.168.1.20:7788", fav = true },
  }
  ctx.servers = {
    menuList = function() return servers end,
    menuGet = function(_, key) return servers[1].key == key and servers[1] or nil end,
    get = function(_, key) return servers[1].key == key and servers[1] or nil end,
    setAddress = function(_, key, text)
      if not text:find("%d") then return nil end
      servers[1].address = text
      return servers[1]
    end,
    isAutoJoin = function() return false end,
  }
  return ctx
end

-- ------------------------------------------------------------------
-- one boot
-- ------------------------------------------------------------------

local function run3(version)
  local L = version .. ": "
  local em = version == "emerald"
  local run = loadGen3(version)
  eq(run.mod and run.mod.state, "loaded", L .. "the mod loads")
  -- Ui:install registered its screens with Gen3Ui, not the gated registry
  for _, e in ipairs(run.errors) do
    check(not errorText(e):find("screens", 1, true),
      L .. "no screens-registry note in loader.errors (" .. errorText(e) .. ")")
  end

  local need = resolver(run)
  local Gen3Ui, Ui, Gen3 = need("Gen3Ui"), need("Ui"), need("Gen3")
  local session = session3(version, em and "EM_LITTLEROOT_TOWN" or "FR_OAKS_LAB")
  local game = newGame(run, session)
  run.loader.game = game
  Stack.clear()

  local st = {}
  local ctx = newCtx(game, st)
  local ui = Ui.new(ctx)
  check(pcall(function() ui:install() end), L .. "Ui:install on Gen 3")
  check(Gen3Ui.registered(Ui.SCREEN.MAIN) ~= nil, L .. "MAIN registered with Gen3Ui")

  check(Ui.isGen3(), L .. "Ui knows it is on Gen 3")
  eq(Gen3.stack(), Stack, L .. "Gen3Ui drives the engine's own stack module")

  -- ------- registry, push, ids, pop

  Gen3Ui.register("Probe", { new = function(g, opts)
    return Gen3Ui.Menu.new(g, opts.items, { onCancel = opts.onCancel })
  end })
  eq(Gen3Ui.push(game, "Nope"), nil, L .. "an unregistered id pushes nothing")
  local picked = {}
  local items = {
    { label = "ONE", onSelect = function() picked[#picked + 1] = "ONE" end },
    { label = "TWO", onSelect = function() picked[#picked + 1] = "TWO" end },
    { label = "THREE", onSelect = function() picked[#picked + 1] = "THREE" end },
  }
  local cancelled = 0
  local menu = Gen3Ui.push(game, "Probe", { items = items, onCancel = function() cancelled = cancelled + 1 end })
  check(menu ~= nil, L .. "a registered screen pushes")
  eq(topId(), "rby_mmo:Probe", L .. "layer id is rby_mmo:<ScreenId>")
  eq(Stack.top().mod, menu, L .. "the layer table is the screen itself")
  eq(Gen3Ui.top(), menu, L .. "Gen3Ui.top")
  eq(Ui.top(game), menu, L .. "Ui.top")
  eq(menu.cursor, 1, L .. "cursor starts on row 1")
  eq(labels(menu), "ONE,TWO,THREE", L .. "items[i].label")
  step(game, "down")
  eq(menu.cursor, 2, L .. "down moves the cursor")
  step(game, "up") step(game, "up")
  eq(menu.cursor, 3, L .. "up from the top wraps")
  step(game, "a")
  eq(picked[1], "THREE", L .. "A runs the row")
  eq(Stack.depth(), 0, L .. "and the menu popped itself first")

  -- B pops then runs onCancel
  menu = Gen3Ui.push(game, "Probe", { items = items, onCancel = function() cancelled = cancelled + 1 end })
  step(game, "b")
  eq(cancelled, 1, L .. "B runs onCancel")
  eq(Stack.depth(), 0, L .. "after popping")

  -- a second layer of the same id is not a replacement
  local first = Gen3Ui.push(game, "Probe", { items = items })
  local second = Gen3Ui.push(game, "Probe", { items = items })
  eq(Stack.depth(), 2, L .. "two layers of one id both stay up")
  eq(second.gen3Layer, "rby_mmo:Probe#2", L .. "the second gets #2")
  check(Gen3Ui.pop(game, first), L .. "a buried layer pops by identity")
  eq(Gen3Ui.top(), second, L .. "leaving the other on top")
  check(Gen3Ui.pop(game, "Probe"), L .. "pop by screen id finds the #2 layer")
  eq(Stack.depth(), 0, L .. "empty again")

  -- an engine layer is never popped by accident
  Stack.push("start", { draw = function() end })
  eq(Gen3Ui.pop(game), false, L .. "pop() leaves an engine layer alone")
  eq(Ui.popTop(game), false, L .. "Ui.popTop too")
  Stack.clear()

  -- the press that opened a layer is not also the layer's
  Gen3Ui.register("Opener", { new = function(g)
    local s = { kind = "opener" }
    function s.update()
      if g.input:wasPressed("a") then Ui.push(g, Ui.SCREEN.TEXT, { text = "Hello there." }) end
    end
    return s
  end })
  Gen3Ui.push(game, "Opener")
  step(game, "a")
  eq(Gen3Ui.top() and Gen3Ui.top().kind, "text",
     L .. "a box pushed from update is up after the same step's handleInput")
  eq(Gen3Ui.top().waiting, false, L .. "and that step's A did not touch it")
  Stack.clear()

  -- ------- TextBox

  local done = 0
  local box = ui:say(
    "This is a long line of text that the box has to wrap onto several pages to fit it in.",
    function() done = done + 1 end)
  eq(box.text:sub(1, 7), "This is", L .. "text layers expose .text")
  check(#box.pages >= 2, L .. "a long sentence pages")
  step(game) -- typing
  check(not box.waiting, L .. "still typing after a frame")
  step(game, "a")
  check(box.waiting, L .. "A finishes the page")
  step(game, "a")
  eq(box.page, 2, L .. "the next A turns the page")
  for _ = 1, #box.pages * 2 + 2 do step(game, "a") end
  eq(done, 1, L .. "onDone after the last page")
  eq(Stack.depth(), 0, L .. "the box is gone")

  local answer
  local ask = ui:confirm(game, "Trade with\nBOB?", function(yes) answer = yes end)
  eq(ask.items, nil, L .. "no YES/NO until the text has printed")
  steps(game, 200)
  eq(labels(ask), "YES,NO", L .. "the YES/NO rows are items once it has")
  eq(ask.cursor, 1, L .. "on YES")
  step(game, "down")
  eq(ask.cursor, 2, L .. "down to NO")
  step(game, "a")
  eq(answer, false, L .. "A on NO answers no")
  local ask2 = ui:confirm(game, "Really?", function(yes) answer = yes end,
                                                 { defaultNo = true })
  steps(game, 100)
  eq(ask2.cursor, 2, L .. "defaultNo opens on NO")
  step(game, "up") step(game, "a")
  eq(answer, true, L .. "A on YES answers yes")
  ui:confirm(game, "Leave?", function(yes) answer = yes end)
  steps(game, 100)
  step(game, "b")
  eq(answer, false, L .. "B is NO")
  eq(Stack.depth(), 0, L .. "confirm boxes are gone")

  -- CHOOSE: the sentence, then the rows, B is the last row
  local chose
  ui:choose(game, "Waiting for\nBOB...", {
    { label = "KEEP WAITING", onSelect = function() chose = "keep" end },
    { label = "CANCEL", onSelect = function() chose = "cancel" end },
  })
  steps(game, 100)
  step(game, "a")
  eq(topId(), "rby_mmo:RbyMmoChooseMenu", L .. "CHOOSE opens its menu after the text")
  eq(Gen3Ui.top().anchor3, "bottom", L .. "low and to the right, as on Gen 1")
  step(game, "b")
  eq(chose, "cancel", L .. "B runs the last row")

  -- ------- the MMO menu, offline

  Stack.clear()
  local main = Ui.push(game, Ui.SCREEN.MAIN)
  eq(topId(), "rby_mmo:RbyMmoMain", L .. "Ui.push(MAIN)")
  eq(labels(main), "SERVERS,HOST GAME,JOIN GAME,CHARACTER", L .. "offline rows")
  eq(main.anchor3, "top", L .. "MAIN hangs from the top, like START")
  local ok, err = drawAll()
  check(ok, L .. "MAIN draws (" .. tostring(err) .. ")")

  -- HOST GAME -> TRAINER -> HOST -> START -> HOSTINFO
  check(select(game, "HOST GAME"), L .. "HOST GAME row")
  eq(topId(), "rby_mmo:RbyMmoCharSetup", L .. "HOST GAME opens TRAINER")
  eq(labels(Gen3Ui.top()), "NAME,LOOK,HOST", L .. "TRAINER rows")
  check(select(game, "HOST"), L .. "HOST row")
  eq(topId(), "rby_mmo:RbyMmoHostSetup", L .. "HOST setup")
  local hostset = Gen3Ui.top()
  eq(hostset.items[2].right, "A7K3P9", L .. "the join code in the right column")
  ok, err = drawAll()
  check(ok, L .. "HOST setup draws (" .. tostring(err) .. ")")
  st.hosting = true
  check(select(game, "START"), L .. "START row")
  eq(topId(), "rby_mmo:RbyMmoHostInfo", L .. "hosting shows the address page")
  ok, err = drawAll()
  check(ok, L .. "HOSTINFO draws (" .. tostring(err) .. ")")
  local info = Gen3Ui.top()
  if info.qr then
    step(game, "a")
    eq(topId(), "rby_mmo:RbyMmoHostQr", L .. "A shows the QR")
    local qr = Gen3Ui.top()
    check(Gen3Ui.qrScale(#qr.qr, Gen3Ui.H - 4) >= 3, L .. "the pairing QR gets 3px modules")
    ok, err = drawAll()
    check(ok, L .. "HOSTQR draws (" .. tostring(err) .. ")")
    local rects = 0
    for _, call in ipairs(drawn) do if call[1] == "rectangle" then rects = rects + 1 end end
    check(rects > #qr.qr, L .. "and paints its modules")
    step(game, "b")
    eq(topId(), "rby_mmo:RbyMmoHostInfo", L .. "B back to the address page")
  end
  step(game, "b")
  eq(Stack.depth(), 0, L .. "B leaves the address page")
  st.hosting = false

  -- JOIN GAME -> TRAINER -> JOIN -> address grid -> code grid
  Ui.push(game, Ui.SCREEN.MAIN)
  select(game, "JOIN GAME")
  select(game, "JOIN")
  eq(topId(), "rby_mmo:RbyMmoJoinAddress", L .. "JOIN asks for the address")
  local grid = Gen3Ui.top()
  eq(grid.kind, "naming", L .. "on the mod's grid")
  eq(grid.maxLen, 32, L .. "32 characters of address")
  eq(grid:hint(), "B GOES BACK", L .. "an empty line says B leaves")
  check(typeOn(game, grid, "10.0.0.2:7788"), L .. "digits, dots and a colon are typeable")
  eq(table.concat(grid.glyphs), "10.0.0.2:7788", L .. "typed as asked")
  eq(grid:hint(), "B ERASES", L .. "and B erases once there is text")
  ok, err = drawAll()
  check(ok, L .. "the grid draws (" .. tostring(err) .. ")")
  step(game, "start")
  eq(st.joinAddress, "10.0.0.2:7788", L .. "START submits the address")
  eq(topId(), "rby_mmo:RbyMmoJoinCode", L .. "then asks for the code")
  local codeGrid = Gen3Ui.top()
  step(game, "start")
  eq(topId(), "rby_mmo:RbyMmoMain", L .. "START on an empty code line leaves to MAIN")
  step(game, "b")
  Stack.clear()
  Ui.push(game, Ui.SCREEN.JOINCODE, { connect = true })
  codeGrid = Gen3Ui.top()
  check(typeOn(game, codeGrid, "A7K3P9"), L .. "a code is typeable")
  step(game, "start")
  eq(st.joinCode, "A7K3P9", L .. "the code is filed")
  check(st.dialled, L .. "and the connection dials")
  Stack.clear()
  Ui.push(game, Ui.SCREEN.JOINCODE, {})
  step(game, "b")
  eq(topId(), "rby_mmo:RbyMmoMain", L .. "B on an empty code line goes back to MAIN")
  Stack.clear()

  -- CHARACTER: the list with its preview window
  Ui.push(game, Ui.SCREEN.CHARPICK, { backTo = Ui.SCREEN.MAIN })
  local pick = Gen3Ui.top()
  eq(pick.kind, "list", L .. "CHARACTER is a list")
  check(pick.panel ~= nil, L .. "with a preview panel")
  check(#pick.items >= 1, L .. "at least the player's own look")
  for _, item in ipairs(pick.items) do
    check(not item.label:find("^%s"), L .. "labels are plain: " .. item.label)
  end
  ok, err = drawAll()
  check(ok, L .. "CHARACTER draws (" .. tostring(err) .. ")")
  step(game, "a")
  eq(topId(), "rby_mmo:RbyMmoMain", L .. "A wears it and goes back")
  Stack.clear()

  -- ------- connected

  st.connected = true
  st.players = {
    { id = "bob", name = "BOB", map = em and "EM_OLDALE_TOWN" or "FR_PALLET_TOWN", x = 1, y = 1 },
    { id = "cal", name = "CAL", busy = true },
  }
  st.chat = {
    { scope = "global", name = "BOB",
      text = "hello there everyone this is a long chat line that has to wrap twice" },
  }
  st.ranking = {
    { name = "BOB", id = "b0b0", points = 1234, sprite = "OBJ_EVENT_GFX_RED_NORMAL" },
    { name = "CAL", id = "ca11", points = 9, sprite = "OBJ_EVENT_GFX_BRENDAN_NORMAL" },
    { name = "BOB", id = "b0b1", points = 5 },
  }
  main = Ui.push(game, Ui.SCREEN.MAIN)
  eq(labels(main), "PLAYERS,FRIENDS,CHAT,SAY,PARTY,MY PROFILE,RANK,CHARACTER,LEAVE",
     L .. "connected rows")
  ok, err = drawAll()
  check(ok, L .. "a scrolling MAIN draws (" .. tostring(err) .. ")")

  select(game, "PLAYERS")
  eq(topId(), "rby_mmo:RbyMmoRoster", L .. "PLAYERS opens the roster")
  local roster = Gen3Ui.top()
  eq(roster.items[1].label, "BOB", L .. "a friend's label stays plain")
  eq(roster.items[1].prefix, Ui.FRIEND_MARK, L .. "the mark rides in prefix")
  eq(roster.items[2].right, "BUSY", L .. "a busy player says so")
  local right = roster.items[1].right
  check(right == nil or Gen3Ui.Font.width(right) <= Gen3Ui.rightRoom("BOB", Ui.FRIEND_MARK),
    L .. "the place fits beside the name")
  ok, err = drawAll()
  check(ok, L .. "PLAYERS draws (" .. tostring(err) .. ")")
  step(game, "a")
  eq(topId(), "rby_mmo:RbyMmoActions", L .. "A opens the actions box")
  eq(labels(Gen3Ui.top()), "PROFILE,UNFRIEND,INVITE,TRADE,BATTLE,PARTY BATTLE,WHISPER",
     L .. "ACTIONS rows")
  eq(Gen3Ui.top().anchor3, "bottom", L .. "ACTIONS sits low")
  select(game, "PROFILE")
  eq(topId(), "rby_mmo:RbyMmoProfile", L .. "PROFILE is the card")
  ok, err = drawAll()
  check(ok, L .. "their card draws (" .. tostring(err) .. ")")
  step(game, "b")
  eq(topId(), "rby_mmo:RbyMmoActions", L .. "B back to ACTIONS")
  select(game, "TRADE")
  eq(st.requested, "trade", L .. "TRADE asks the session")
  Stack.clear()

  Ui.push(game, Ui.SCREEN.PROFILE, { own = true, onCancel = function() Ui.push(game, Ui.SCREEN.MAIN) end })
  local card = Gen3Ui.top()
  check(card.gen3, L .. "the card knows it is on Gen 3")
  ok, err = drawAll()
  check(ok, L .. "MY PROFILE draws (" .. tostring(err) .. ")")
  step(game, "a")
  eq(topId(), "rby_mmo:RbyMmoMain", L .. "and closes back to MAIN")
  Stack.clear()

  Ui.push(game, Ui.SCREEN.RANK, {})
  check(st.askedRanking, L .. "RANK asks the hub")
  ok, err = drawAll()
  check(ok, L .. "RANK draws (" .. tostring(err) .. ")")
  local label3 = Ui.rankLabel3("BOB", "b0b0", true, "1234")
  check(label3:find("(B0B0)", 1, true) ~= nil,
    L .. "a shared name carries its tag, in glyphs the cart has: " .. label3)
  check(Gen3Ui.Font.width(label3) <= 226 - Gen3Ui.Font.width("1234") - 6 - 58,
    L .. "and fits before the score")
  step(game, "b")
  eq(Stack.depth(), 0, L .. "B leaves RANK")

  Ui.push(game, Ui.SCREEN.CHATLOG)
  local log = Gen3Ui.top()
  check(#log.items >= 3, L .. "the long line wraps")
  eq(log.items[1].label, "(G)BOB:", L .. "the speaker row in parentheses, which the cart can print")
  local room = Gen3Ui.rightRoom("", nil)
  for _, item in ipairs(log.items) do
    check(Gen3Ui.Font.width(item.label) <= room + 1, L .. "each chat row fits: " .. item.label)
  end
  eq(log.cursor, #log.items, L .. "the log opens on its newest line")
  ok, err = drawAll()
  check(ok, L .. "CHAT draws (" .. tostring(err) .. ")")
  Stack.clear()

  Ui.push(game, Ui.SCREEN.SCOPE)
  select(game, "EVERYONE")
  eq(topId(), "rby_mmo:RbyMmoCompose", L .. "SAY opens the compose grid")
  typeOn(game, Gen3Ui.top(), "HI 2 U")
  step(game, "start")
  eq(st.said and st.said.text, "HI 2 U", L .. "and says what was typed")
  Stack.clear()

  -- ------- the trade picker, from the live party

  local pickedIndex = false
  ui:pickPartyMon(game, {
    canPick = function(_, i) return i ~= 2 end, reasons = { [2] = "egg" },
  }, function(i) pickedIndex = i end)
  local party = Gen3Ui.top()
  eq(party.title, "TRADE WHICH?", L .. "the picker")
  eq(party.items[1].label, Gen3.speciesName(4) or "4", L .. "an unnamed mon by its species")
  eq(party.items[1].right, "Lv5", L .. "with its level")
  eq(party.items[2].label, "BUBBLES", L .. "a nickname as itself")
  eq(party.items[2].right, "NO", L .. "a mon the other side cannot take says NO")
  ok, err = drawAll()
  check(ok, L .. "the picker draws (" .. tostring(err) .. ")")
  step(game, "down") step(game, "a")
  eq(pickedIndex, false, L .. "a blocked row cannot be picked")
  step(game, "up") step(game, "a")
  eq(pickedIndex, 1, L .. "a free one can")
  Stack.clear()

  -- ------- the doors: holds / unwindTo / pop / pushState

  local under = ui:say("Under.")
  local over = ui:say("Over.")
  eq(Ui.holds(game, under), true, L .. "Ui.holds a buried box")
  check(Ui.unwindTo(game, under, false), L .. "Ui.unwindTo")
  eq(Ui.top(game), under, L .. "down to it")
  eq(Ui.holds(game, over), false, L .. "the one above is gone")
  check(Ui.pop(game, under), L .. "Ui.pop by identity")
  eq(Ui.unwindTo(game, under, true), false, L .. "never hunts for a screen that left")

  local exited = 0
  local drewWide = {}
  local state = {
    game = game,
    update = function() end,
    draw = function(self) if self:drawsWidescreen() then return end end,
    drawsWidescreen = function() return true end,
    drawWidescreen = function(_, w, h) drewWide[#drewWide + 1] = { w, h } end,
    exit = function() exited = exited + 1 end,
  }
  local layer = ui:pushState(game, state)
  eq(layer, state, L .. "pushState puts the state itself up")
  local top = Stack.top()
  eq(top.fullscreen, true, L .. "fullscreen: the field is frozen and not drawn")
  eq(top.hideBelow, true, L .. "and nothing under it draws")
  local overBox = ui:say("Your POKeMON fainted!")
  local overDrawn = 0
  local baseDraw = overBox.draw
  overBox.draw = function(...) overDrawn = overDrawn + 1 return baseDraw(...) end
  check(Gen3Ui.drawWidescreen({ width = 1280, height = 720, gameX = 160, gameY = 0,
                                gameWidth = 960, gameHeight = 640, scale = 4 }),
    L .. "drawWidescreen paints the widescreen state")
  eq(drewWide[1] and drewWide[1][1], 1280, L .. "in window space")
  eq(overDrawn, 1, L .. "and the box above it at the game rect")
  Ui.pop(game, overBox)
  check(Ui.pop(game, state), L .. "Ui.pop takes a state down")
  eq(exited, 1, L .. "running its exit, as StateStack:pop does")
  eq(Gen3Ui.drawWidescreen({ width = 1, height = 1 }), false, L .. "nothing wide, nothing drawn")

  -- ------- the rest of the screens

  -- JOIN QR with no camera bridge: says so, and A / B leave
  Ui.push(game, Ui.SCREEN.JOINQR)
  eq(Gen3Ui.top().status, "QR UNAVAILABLE", L .. "JOIN QR without a camera says so")
  ok, err = drawAll()
  check(ok, L .. "JOIN QR draws (" .. tostring(err) .. ")")
  step(game, "a")
  eq(Stack.depth(), 0, L .. "and A leaves it")

  -- SERVERS -> the entry -> EDIT HOST, seeded with what is there
  Ui.push(game, Ui.SCREEN.SERVERS)
  eq(Gen3Ui.top().items[1].label, "HOME HUB", L .. "SERVERS lists the store")
  step(game, "a")
  eq(topId(), "rby_mmo:RbyMmoServerActions", L .. "A opens the entry")
  select(game, "EDIT HOST")
  eq(topId(), "rby_mmo:RbyMmoServerEdit", L .. "EDIT HOST is a grid")
  eq(table.concat(Gen3Ui.top().glyphs), "192.168.1.20:7788", L .. "seeded with the address")
  steps(game, 7, "b")   -- ":7788" and "20" off
  eq(table.concat(Gen3Ui.top().glyphs), "192.168.1.", L .. "B erases")
  typeOn(game, Gen3Ui.top(), "99")
  step(game, "start")
  eq(topId(), "rby_mmo:RbyMmoServerActions", L .. "a saved edit lands back on the entry")
  eq(ctx.servers.get(nil, "a").address, "192.168.1.99", L .. "with the new address")
  Stack.clear()

  -- HOST > JOIN CODE > the two rows
  Ui.push(game, Ui.SCREEN.HOSTCODE)
  eq(labels(Gen3Ui.top()), "NEW CODE,TYPE ONE", L .. "HOSTCODE rows")
  select(game, "NEW CODE")
  eq(topId(), "rby_mmo:RbyMmoText", L .. "a new code is read out")
  check(Gen3Ui.top().text:find("A7K3P9", 1, true) ~= nil, L .. "naming it")
  Stack.clear()

  -- the nickname a catch earns: the question first, NO keeps the name
  local named = "unset"
  local mon = { species = 25, level = 5, personality = 7, nickname = "" }
  check(ui:askNickname(game, mon, "PIKACHU", function(name) named = name end),
    L .. "askNickname puts the question up")
  eq(topId(), "rby_mmo:RbyMmoConfirm", L .. "as a confirm")
  steps(game, 300)
  step(game, "down") step(game, "a")
  eq(named, nil, L .. "NO answers with no name")
  eq(mon.nickname, "", L .. "and the mon keeps its species name")
  Stack.clear()

  -- a layer waits out the cart's own battle: not drawn while it runs
  local Battle = Gen3.engine("src.core.game3.battle")
  if type(Battle) == "table" and type(Battle.isActive) == "function" then
    local realActive = Battle.isActive
    ui:say("Later.")
    Battle.isActive = function() return true end
    drawAll()
    eq(#drawn, 0, L .. "nothing is drawn over the cart's battle")
    Battle.isActive = realActive
    drawAll()
    check(#drawn > 0, L .. "and the box draws once it is over")
    Stack.clear()
    local stateDrew = 0
    ui:pushState(game, { game = game, update = function() end,
                         draw = function() stateDrew = stateDrew + 1 end })
    Battle.isActive = function() return true end
    drawAll()
    Battle.isActive = realActive
    eq(stateDrew, 1, L .. "a pushed state is never hidden that way")
    Stack.clear()
  end

  -- ------- toolkit odds and ends

  local rows = { { id = "bag", label = "BAG" }, { id = "save", label = "SAVE" } }
  Gen3Ui.insertBefore(rows, "save", { id = "rby_mmo", label = "MMO" })
  eq(rows[2].id, "rby_mmo", L .. "insertBefore anchors on a row id")
  local Font = Gen3Ui.Font
  local fit = Font.fit("A VERY LONG NAME INDEED", 40)
  check(Font.width(fit) <= 40, L .. "Font.fit fits")
  for _, line in ipairs(Font.wrap("one two three four five six seven", 50)) do
    check(Font.width(line) <= 50, L .. "Font.wrap fits: " .. line)
  end
  eq(Font.width(Font.HOLLOW), 7, L .. "the friend mark has a width")
  local x0, cells, caret = Gen3Ui.fieldLayout(32, { "1", "2", "3" })
  eq(#cells, Gen3Ui.FIELD_SLOTS, L .. "a 32-long line gets every slot that fits")
  eq(cells[1], "1", L .. "and starts at the start while it fits")
  eq(caret, 4, L .. "the caret after what was typed")
  check(x0 >= 8, L .. "inside the margin")
  local long = {}
  for i = 1, 30 do long[i] = tostring(i % 10) end
  local _, tail = Gen3Ui.fieldLayout(32, long)
  eq(tail[#tail], long[30], L .. "a line longer than the window shows its end")

  eq(stackTouched, 0, L .. "nothing touched game.stack")
  Stack.clear()
  run.loader.game = nil
  run.release()
  GameVersion.set("red")
end

run3("firered")
run3("emerald")

-- ------------------------------------------------------------------
-- off Gen 3 nothing moves
-- ------------------------------------------------------------------

do
  local run = T.sdk.loadMod("mods/rby_mmo", MOD_PATH ~= "mods/rby_mmo"
    and { generation = 1, fs = makeRemapFs(T, MOD_PATH) } or { generation = 1 })
  eq(#run.errors, 0, "gen 1: loads clean")
  local seen = {}
  local inner = _G.require
  _G.require = function(name, ...)
    if type(name) == "string" and name:find("%.game3%.") then seen[#seen + 1] = name end
    return inner(name, ...)
  end
  local need = resolver(run)
  local Gen3Ui, Ui = need("Gen3Ui"), need("Ui")
  check(not Ui.isGen3(), "gen 1: Ui is not on Gen 3")
  Gen3Ui.register("Probe", { new = function(g) return Gen3Ui.Menu.new(g, {}) end })
  eq(Gen3Ui.push({}, "Probe"), nil, "gen 1: Gen3Ui pushes nothing (there is no game3 stack)")
  eq(Gen3Ui.top(), nil, "gen 1: and has no top")
  eq(Gen3Ui.drawWidescreen({ width = 1, height = 1 }), false, "gen 1: nor a widescreen pass")
  _G.require = inner
  eq(#seen, 0, "gen 1: no src.*.game3.* module was required")
  run.release()
end

_G.love = previousLove
T.finish("gen3_ui")
