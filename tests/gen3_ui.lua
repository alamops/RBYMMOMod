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

-- Every `draw` of one image, as { x, y, sx, sy, quad } (g.draw(image, quad,
-- x, y, r, sx, sy) records { "draw", image, quad, x, y, r, sx, sy }).
local function drawsOf(image)
  local out = {}
  for _, call in ipairs(drawn) do
    if call[1] == "draw" and call[2] == image then
      out[#out + 1] = { x = call[4], y = call[5], sx = call[7], sy = call[8], quad = call[3] }
    end
  end
  return out
end

-- ------- what reaches the cart's font
--
-- Gen3Ui prints through src/ui/game3/frlg_font.lua.  Headless there are no
-- glyph sheets, so a character the cart cannot print would pass unseen --
-- wrapping FrlgFont.draw records every string a screen hands the cart, and
-- `unprintable` answers the first character frlg_font would draw blank
-- (glyph 0x00 for anything but a space) or read as markup ("{...}").
local FrlgFont = require("src.ui.game3.frlg_font")
local realFontDraw = FrlgFont.draw
local printed, allPrinted = {}, {}
FrlgFont.draw = function(text, ...)
  printed[#printed + 1] = tostring(text)
  allPrinted[#allPrinted + 1] = tostring(text)
  return realFontDraw(text, ...)
end

local function unprintable(text)
  for ch in FrlgFont.utf8Chars(tostring(text)) do
    if ch == "{" or ch == "}" then return ch end
    if ch ~= " " and ch ~= "\n" and FrlgFont.glyphId(ch) == 0 then return ch end
  end
  return nil
end

local function wasPrinted(text)
  for _, line in ipairs(printed) do
    if line == text then return true end
  end
  return false
end

-- ------- engine sheets, stood in
--
-- Headless there is no overworld cache, so OwSprites answers nothing and a
-- figure is never placed.  These stand in for the two sheets whose
-- *placement* the suite pins: a person (16x32, nine frames) and a 32x32
-- figure (BIG_GFX), and the party menu's held-item / mail marker.  Installed
-- per boot before the loader resolves them (Gen3.engine remembers modules).
local PERSON_IMG = { getDimensions = function() return 144, 32 end }
local BIG_IMG = { getDimensions = function() return 288, 32 end }
local HOLD_IMG = { getDimensions = function() return 8, 16 end }
local BIG_GFX = 999
local function fakeSheet(image, w, h)
  local quads = {}
  for f = 0, 8 do quads[f] = graphics.newQuad(f * w, 0, w, h) end
  return { image = image, quads = quads, width = w, height = h, frameCount = 9 }
end
local fakeOw = {
  getDraw = function(id)
    if id == BIG_GFX then return fakeSheet(BIG_IMG, 32, 32) end
    return fakeSheet(PERSON_IMG, 16, 32)
  end,
  pose = function() return 0, false end,
}
local fakePartyMenu = {
  heldItemSheet = function()
    return { image = HOLD_IMG, quads = { [0] = "itemQ", [1] = "mailQ" }, w = 8, h = 8 }
  end,
}
local stubbed = {}
local function stubEngine(name, value)
  if stubbed[name] == nil then stubbed[name] = package.loaded[name] or false end
  package.loaded[name] = value
end
local function unstubEngine()
  for name, original in pairs(stubbed) do package.loaded[name] = original or nil end
  stubbed = {}
end

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
  stubEngine("src.core.game3.ow_sprites", fakeOw)
  stubEngine("src.ui.game3.party_menu", fakePartyMenu)
  printed, allPrinted = {}, {}
  stackTouched = 0
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
  -- what this Ui instance's install adds to input.step / the save events (the
  -- loaded mod's own Ui installed its links already)
  local stepBefore, loadedBefore, createdBefore = {}, 0, 0
  for _, e in ipairs(run.loader.hooks.chains["input.step"] or {}) do stepBefore[e.callback] = true end
  loadedBefore = #(run.loader.events.listeners["save.loaded"] or {})
  createdBefore = #(run.loader.events.listeners["save.created"] or {})
  check(pcall(function() ui:install() end), L .. "Ui:install on Gen 3")
  local uiStep, uiStepAt, clientStepAt
  for i, e in ipairs(run.loader.hooks.chains["input.step"] or {}) do
    if not stepBefore[e.callback] then uiStep, uiStepAt = e.callback, i end
    if (e.priority or 0) == 0 and not clientStepAt then clientStepAt = i end
  end
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
    -- a figure wider than a person, for the card's placement
    { id = "big", name = "OLGA", sprite = BIG_GFX },
  }
  st.chat = {
    { scope = "global", name = "BOB",
      text = "hello there everyone this is a long chat line that has to wrap twice" },
    -- every character the cart's charmap lacks, and the font's own markup:
    -- Wire.text keeps them off the wire, but the screen must not depend on it
    { scope = "party", name = "ZED",
      text = "#1 [x] {COLOR RED} a*b @c ~d |e ^f `g \\h" },
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
  eq(log.items[1].label, "[G]BOB:", L .. "the speaker row's label is Gen 1's own")
  local room = Gen3Ui.rightRoom("", nil)
  for _, item in ipairs(log.items) do
    check(Gen3Ui.Font.width(item.label) <= room + 1, L .. "each chat row fits: " .. item.label)
  end
  eq(log.cursor, #log.items, L .. "the log opens on its newest line")
  log.index = 1
  printed = {}
  ok, err = drawAll()
  check(ok, L .. "CHAT draws (" .. tostring(err) .. ")")
  check(wasPrinted("(G)BOB:"), L .. "and prints it in the cart's parentheses")
  check(not wasPrinted("[G]BOB:"), L .. "never with the brackets the cart prints blank")
  log.index = #log.items
  printed = {}
  drawAll()
  local nasty
  for _, line in ipairs(printed) do
    if line:find("COLOR", 1, true) then nasty = line end
  end
  check(nasty ~= nil and nasty:find("(COLOR", 1, true) ~= nil,
    L .. "a brace is printed as a parenthesis, never read as the font's markup: " .. tostring(nasty))
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

  -- ...and from the trade's own rows when it has them (Trade3's entries):
  -- the cart's name, "EGG" with no level, the held-item / mail marker, and a
  -- blocked row greyed with the cart's reason on the title line under the
  -- cursor.  `canPick` is never asked when `entries` is there.
  local ONLY = "That's your only\nPOKéMON for battle."
  local EGG_NO = "An EGG can't be\ntraded now."
  local egg = { species = 412, level = 5, isEgg = true, nickname = "" }
  local rowsTrade = {
    entries = function()
      return {
        { index = 1, mon = session.party[1], name = "IVY", level = 5, heldItem = 13,
          heldItemName = "POTION", hasMail = false, isEgg = false, blocked = false, iconSpecies = 4 },
        { index = 2, mon = egg, name = "EGG", level = 5, heldItem = 0, isEgg = true,
          blocked = true, reason = EGG_NO, iconSpecies = 412 },
        { index = 3, mon = session.party[2], name = "BUBBLES", level = 7, heldItem = 121,
          hasMail = true, isEgg = false, blocked = false, iconSpecies = 7 },
        { index = 4, mon = { species = 16, level = 9 }, name = "PIDGEY", level = 9,
          heldItem = 0, isEgg = false, blocked = true, reason = ONLY, iconSpecies = 16 },
        { index = 5, mon = { species = 412, level = 5, isEgg = true }, name = "EGG", level = 5,
          heldItem = 0, isEgg = true, blocked = false, iconSpecies = 412 },
      }
    end,
    canPick = function() error("entries are the source when a trade has them") end,
  }
  local pickedRow = false
  ui:pickPartyMon(game, rowsTrade, function(i) pickedRow = i end)
  local rows = Gen3Ui.top()
  eq(rows.title, "TRADE WHICH?", L .. "the entries picker keeps its title")
  eq(labels(rows), "IVY,EGG,BUBBLES,PIDGEY,EGG", L .. "rows are the cart's names, an egg is EGG")
  eq(rows.items[1].right, "Lv5", L .. "a mon shows its level")
  eq(rows.items[5].right, nil, L .. "an egg shows none, as the party menu prints it")
  eq(rows.items[2].right, "NO", L .. "a blocked row says NO")
  eq(rows.items[2].blocked, true, L .. "and is greyed")
  eq(rows.items[2].reason, "An EGG can't be traded now.", L .. "its reason on one line")
  eq(rows.items[1].hold, "item", L .. "a held item is marked")
  eq(rows.items[3].hold, "mail", L .. "mail is marked as mail")
  eq(rows.items[4].hold, nil, L .. "an empty hand is not")
  printed = {}
  ok, err = drawAll()
  check(ok, L .. "the entries picker draws (" .. tostring(err) .. ")")
  check(wasPrinted("TRADE WHICH?"), L .. "the title line is the title on a free row")
  local marks = drawsOf(HOLD_IMG)
  eq(#marks, 2, L .. "two held-item markers drawn")
  local LIST = Gen3Ui.LIST
  local iconX = LIST.left * 8 + LIST.labelDX + 34 - 34
  local firstY = LIST.top * 8 + 2 - 11
  eq(marks[1] and marks[1].quad, "itemQ", L .. "row 1 wears the item frame")
  eq(marks[1] and marks[1].x, iconX + 16, L .. "16px right of its icon, as the party menu puts it")
  eq(marks[1] and marks[1].y, firstY + 22, L .. "and 22px down")
  eq(marks[2] and marks[2].quad, "mailQ", L .. "row 3 wears the mail frame")
  eq(marks[2] and marks[2].y, firstY + 2 * 18 + 22, L .. "on its own row")
  step(game, "down")
  printed = {}
  drawAll()
  check(wasPrinted("An EGG can't be traded now."), L .. "on the egg the title line says why")
  check(not wasPrinted("TRADE WHICH?"), L .. "in place of the title")
  step(game, "a")
  eq(pickedRow, false, L .. "and A on it picks nothing")
  eq(Gen3Ui.top(), rows, L .. "the picker stays up")
  step(game, "down") step(game, "down")
  printed = {}
  drawAll()
  check(wasPrinted("That's your only POKéMON for battle."), L .. "the last mon able to battle says so")
  step(game, "up")
  printed = {}
  drawAll()
  check(wasPrinted("TRADE WHICH?"), L .. "a free row puts the title back")
  step(game, "a")
  eq(pickedRow, 3, L .. "a free row picks its party slot")
  eq(Stack.depth(), 0, L .. "and the picker closes")
  ui:pickPartyMon(game, rowsTrade, function(i) pickedRow = i end)
  step(game, "b")
  eq(pickedRow, nil, L .. "B answers nil, as on Gen 1")
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

  -- ------- ui:say's onDone: exactly once, when the box is dismissed
  --
  -- Sessions leans on it twice -- reopening the picker after a refusal, and
  -- the trade evolution after "X was traded over!" -- so it must run once
  -- per box, on A or B, and never again for a press that lands after.
  Stack.clear()
  local dones = 0
  local said = ui:say("One line.", function() dones = dones + 1 end)
  check(type(said) == "table", L .. "say returns the box it put up")
  step(game, "a")                 -- finish printing
  eq(dones, 0, L .. "not while it is still being read")
  step(game, "a")                 -- dismiss
  eq(dones, 1, L .. "onDone once the box is dismissed")
  eq(Gen3Ui.has(said), false, L .. "and the box is gone first")
  steps(game, 4, "a")
  eq(dones, 1, L .. "a press after it is not a second dismissal")
  ui:say("By B.", function() dones = dones + 1 end)
  step(game, "b") step(game, "b")
  eq(dones, 2, L .. "B dismisses it the same way")
  local chain = {}
  ui:say("First.", function()
    chain[#chain + 1] = "first"
    ui:say("Second.", function() chain[#chain + 1] = "second" end)
  end)
  step(game, "a") step(game, "a")
  eq(table.concat(chain, ","), "first", L .. "a box opened from onDone")
  eq(Gen3Ui.top() and Gen3Ui.top().text, "Second.", L .. "is up")
  eq(Gen3Ui.top().waiting, false, L .. "and the press that closed the first did not touch it")
  step(game, "a") step(game, "a")
  eq(table.concat(chain, ","), "first,second", L .. "and answers once itself")
  local outside = 0
  local taken = ui:say("Taken down.", function() outside = outside + 1 end)
  Ui.pop(game, taken)
  steps(game, 3, "a")
  eq(outside, 0, L .. "a box taken down from outside never calls back (Gen 1's rule)")
  eq(Stack.depth(), 0, L .. "no box left")

  -- the trade's own continuation, through Sessions:tell on this Ui
  local Sessions = need("Sessions")
  local tellSessions = Sessions.new({ send = function() return true end,
                                      isReady = function() return true end }, ui)
  local evolvedN = 0
  local told = tellSessions:tell(game, "SPARKY was\ntraded over!", function() evolvedN = evolvedN + 1 end)
  check(type(told) == "table", L .. "tell puts the line up")
  eq(evolvedN, 0, L .. "the evolution waits for the line")
  step(game, "a") step(game, "a")
  eq(evolvedN, 1, L .. "and follows it, once")
  steps(game, 3, "a")
  eq(evolvedN, 1, L .. "only once")

  -- ------- figures stand by their real frame size
  local CARD_ART = Ui.CARD3_LAYOUT.art
  local sx, sy, sc = Gen3Ui.standIn(16, 32, CARD_ART)
  eq(("%d,%d,%d"):format(sx, sy, sc), "180,32,2", L .. "a 16x32 person stands at 2x, centred, feet on the floor")
  sx, sy, sc = Gen3Ui.standIn(32, 32, CARD_ART)
  eq(("%d,%d,%d"):format(sx, sy, sc), "180,64,1", L .. "a 32x32 figure fits only once, on the same floor")
  sx, sy, sc = Gen3Ui.standIn(16, 16, CARD_ART)
  eq(("%d,%d,%d"):format(sx, sy, sc), "180,64,2", L .. "a 16x16 frame is not stretched past 2x")
  drawn = {}
  local portraitDrawn = { Gen3Ui.drawSpriteIn({ image = PERSON_IMG, quad = "q", w = 16, h = 32 }, CARD_ART) }
  eq(portraitDrawn[3], 2, L .. "a Chars.portrait entry is placed by its own w / h")
  local p1 = drawsOf(PERSON_IMG)[1]
  eq(p1 and ("%d,%d,%d"):format(p1.x, p1.y, p1.sx), "180,32,2", L .. "at the card's spot")

  Ui.push(game, Ui.SCREEN.PROFILE, { own = true })
  drawAll()
  local fig = drawsOf(PERSON_IMG)[1]
  eq(fig and ("%d,%d,%d"):format(fig.x, fig.y, fig.sx), "180,32,2",
    L .. "the trainer card stands its person in the portrait window")
  Stack.clear()
  Ui.push(game, Ui.SCREEN.PROFILE, { playerId = "big" })
  drawAll()
  fig = drawsOf(BIG_IMG)[1]
  eq(fig and ("%d,%d,%d"):format(fig.x, fig.y, fig.sx), "180,64,1",
    L .. "and a 32x32 figure at 1x, not squeezed past the window")
  Stack.clear()
  Ui.push(game, Ui.SCREEN.CHARPICK, { backTo = Ui.SCREEN.MAIN })
  drawAll()
  fig = drawsOf(PERSON_IMG)[1]
  local PICK_ART = Ui.CHARPICK3_LAYOUT.art
  eq(fig and ("%d,%d,%d"):format(fig.x, fig.y, fig.sx),
    ("%d,%d,2"):format(PICK_ART.x + 12, PICK_ART.y + PICK_ART.h - 64),
    L .. "CHARACTER's preview stands the figure on the panel's floor")
  Stack.clear()

  -- ------- the cart's charset
  for ch, want in pairs(Gen3Ui.GLYPHS) do
    eq(Gen3Ui.Font.printable(ch), want, L .. "maps " .. ch)
    eq(unprintable(want), nil, L .. ch .. " -> " .. want .. " is a glyph the cart has")
    eq(FrlgFont.countChars(want), 1, L .. ch .. " stays one character (the typewriter counts them)")
  end
  eq(Gen3Ui.Font.printable("[G]BOB: #1 {X}"), "(G)BOB: \226\132\1501 (X)", L .. "a whole line maps")
  eq(Gen3Ui.Font.width("[G]"), Gen3Ui.Font.width("(G)"), L .. "and is measured as printed")
  eq(Gen3Ui.Font.printable("PLAIN TEXT, 12!"), "PLAIN TEXT, 12!", L .. "text with nothing to map is itself")

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

  -- Everything every screen above printed, through the cart's font: not one
  -- character it would draw blank or read as markup.
  local blanks = {}
  for _, text in ipairs(allPrinted) do
    local ch = unprintable(text)
    if ch then blanks[#blanks + 1] = ("%q in %q"):format(ch, text) end
  end
  check(#allPrinted > 100, L .. "the screens printed through the cart's font (" .. #allPrinted .. " strings)")
  check(#blanks == 0, L .. "every string a screen printed is in the cart's charset: "
    .. table.concat(blanks, "; "))

  -- ------- prompts wait while the cart has the screen (Ui.occupied)
  --
  -- After the stackTouched check: Sessions' own fight test reads game.stack
  -- (nil on Gen 3) on purpose.
  local noop = { draw = function() end }
  eq(Ui.occupied(game), false, L .. "free: in the field with nothing up")
  Stack.push("bag", noop)
  eq(Ui.occupied(game), true, L .. "the cart's BAG is up")
  ui:say("Over the bag.")
  eq(Ui.occupied(game), true, L .. "a mod box drawn over the BAG does not free the player of it")
  Stack.clear()
  Ui.push(game, Ui.SCREEN.MAIN)
  eq(Ui.occupied(game), false, L .. "a screen of this mod's own is not occupied")
  Stack.clear()
  for _, id in ipairs({ "start", "party", "pokedex", "naming", "summary" }) do
    Stack.push(id, noop)
    eq(Ui.occupied(game), true, L .. "the cart's " .. id .. " layer occupies the screen")
    Stack.clear()
  end
  game.phase = "boot"
  eq(Ui.occupied(game), true, L .. "so does anything but the field")
  game.phase = "field"
  -- the cart's own modules, in the state they are in when it is using the
  -- screen (the real tables Gen3.engine hands the mod, their fields set)
  local function withField(name, key, value, fn)
    local module = require(name)
    local real = module[key]
    module[key] = value
    local okF, errF = pcall(fn)
    module[key] = real
    if not okF then error(errF, 0) end
  end
  withField("src.ui.game3.message", "open", true, function()
    eq(Ui.occupied(game), true, L .. "an NPC's sentence is up")
    Ui.push(game, Ui.SCREEN.MAIN)
    eq(Ui.occupied(game), true, L .. "even under a mod screen")
    Stack.clear()
  end)
  withField("src.ui.game3.choice", "active", true, function()
    eq(Ui.occupied(game), true, L .. "the cart's YES / NO is up")
    Ui.push(game, Ui.SCREEN.MAIN)
    eq(Ui.occupied(game), true, L .. "even under a mod screen")
    Stack.clear()
  end)
  withField("src.core.game3.scripting.space", "vm", { isRunning = function() return true end }, function()
    eq(Ui.occupied(game), true, L .. "a script has the player")
  end)
  withField("src.core.game3.field", "locked", true, function()
    eq(Ui.occupied(game), true, L .. "a warp or field effect has the player")
  end)
  eq(Ui.occupied(game), false, L .. "and free again once all of that is gone")

  -- whenFree: at once when free, queued while not, one at a time in order
  local shown = {}
  local now = ui:whenFree(game, function() shown[#shown + 1] = "now" return ui:say("Now.") end)
  eq(shown[1], "now", L .. "a prompt while free goes up at once")
  eq(Gen3Ui.top(), now, L .. "and whenFree hands back its box")
  Stack.clear()
  shown = {}
  Stack.push("bag", noop)
  local h1 = ui:whenFree(game, function() shown[#shown + 1] = "one" return ui:say("One.") end)
  ui:whenFree(game, function() shown[#shown + 1] = "two" return ui:say("Two.") end)
  local withdrawn = false
  ui:whenFree(game, function() shown[#shown + 1] = "three" return ui:say("Three.") end,
    { alive = function() return not withdrawn end })
  check(type(h1) == "table" and h1.deferred == true, L .. "a held prompt answers a handle")
  eq(#shown, 0, L .. "nothing goes up over the BAG")
  ui:pumpDeferred(game)
  eq(#shown, 0, L .. "nor while it stays open")
  Stack.pop("bag")
  ui:pumpDeferred(game)
  eq(table.concat(shown, ","), "one", L .. "the first goes up once the BAG closes")
  ui:pumpDeferred(game)
  eq(table.concat(shown, ","), "one", L .. "the next waits for it to be dismissed")
  step(game, "a") step(game, "a")
  withdrawn = true
  ui:pumpDeferred(game)
  eq(table.concat(shown, ","), "one,two", L .. "then the second")
  step(game, "a") step(game, "a")
  ui:pumpDeferred(game)
  eq(table.concat(shown, ","), "one,two", L .. "and one withdrawn meanwhile never goes up")
  eq(#ui.deferred, 0, L .. "the queue is empty")
  local tag = {}
  Stack.push("bag", noop)
  ui:whenFree(game, function() shown[#shown + 1] = "tagged" end, { owner = tag })
  eq(ui:dropDeferred(tag), 1, L .. "an owner takes its own back")
  Stack.pop("bag")
  ui:pumpDeferred(game)
  eq(table.concat(shown, ","), "one,two", L .. "and it never shows")
  Stack.clear()

  -- Sessions: a request over the BAG is held, not refused, and asked on close
  local Wire = need("Wire")
  local sent, toasts = {}, {}
  local transport = {
    send = function(_, kind, body) sent[#sent + 1] = { kind = kind, body = body or {} } return true end,
    isReady = function() return true end,
  }
  local sessions = Sessions.new(transport, ui)
  sessions.toast = function(text) toasts[#toasts + 1] = text end
  Stack.push("bag", noop)
  sessions:onRequest(game, { from = "bob", name = "BOB", kind = "trade" })
  eq(#sent, 0, L .. "a request over the BAG is not refused")
  check(sessions.incoming and sessions.incoming.deferred, L .. "it is held")
  eq(sessions:busyReason(game), "asked", L .. "while it waits this player reads as asked")
  eq(topId(), "bag", L .. "and nothing went up over the BAG")
  sessions:update(game, 1 / 60)
  eq(topId(), "bag", L .. "not while the BAG stays open")
  Stack.pop("bag")
  sessions:update(game, 1 / 60)
  eq(topId(), "rby_mmo:RbyMmoConfirm", L .. "the ask goes up once the BAG closes")
  check((Gen3Ui.top().text or ""):find("BOB wants to", 1, true) ~= nil, L .. "naming who asked")
  eq(sessions.incoming and sessions.incoming.deferred, nil, L .. "no longer held")
  steps(game, 200)
  step(game, "a")
  eq(sent[1] and sent[1].kind, Wire.RESPOND, L .. "and the answer goes back")
  eq(sent[1] and sent[1].body.accept, true, L .. "as the player gave it")
  Stack.clear()

  -- withdrawn while it waited: dropped unseen; the corner says who asked
  Stack.push("bag", noop)
  sessions:onRequest(game, { from = "cal", name = "CAL", kind = "battle" })
  sessions:onCancel({ from = "cal", name = "CAL" })
  eq(sessions.incoming, nil, L .. "a cancel drops a held ask")
  eq(toasts[#toasts], "CAL asked to battle", L .. "with a line in the corner, not a box")
  Stack.pop("bag")
  sessions:update(game, 1 / 60)
  eq(Stack.depth(), 0, L .. "nothing goes up once the BAG closes")

  -- run out while it waited: answered no ("busy") and dropped
  Stack.push("bag", noop)
  local before = #sent
  sessions:onRequest(game, { from = "dee", name = "DEE", kind = "trade" })
  sessions:update(game, 60)
  eq(#sent, before, L .. "half the asker's patience is not the end of it")
  sessions:update(game, 61)
  eq(sent[#sent] and sent[#sent].body.accept, false, L .. "the asker's timeout answers it no")
  eq(sent[#sent] and sent[#sent].body.reason, "busy", L .. "saying this player was busy")
  eq(sessions.incoming, nil, L .. "and drops it")
  Stack.pop("bag")
  sessions:update(game, 1 / 60)
  eq(Stack.depth(), 0, L .. "so nothing goes up later")

  -- the answer to our own ask, while we are in the BAG
  sessions.outgoing = { to = "bob", kind = "trade", name = "BOB" }
  Stack.push("bag", noop)
  sessions:onDecline({ name = "BOB" })
  eq(topId(), "bag", L .. "a refusal waits for the BAG too")
  Stack.pop("bag")
  sessions:update(game, 1 / 60)
  eq(Gen3Ui.top() and Gen3Ui.top().text, "BOB said no.", L .. "and is read once it closes")
  Stack.clear()

  -- a (re)connection drops what was held from before it -- the ask and the
  -- plain lines -- but never the line a finished trade still owes
  Stack.push("bag", noop)
  sessions:onRequest(game, { from = "fay", name = "FAY", kind = "trade" })
  sessions:tell(game, "Old news.")
  local owed = 0
  sessions:tell(game, "KADABRA was\ntraded over!", function() owed = owed + 1 end)
  sessions:onTransportReady()
  eq(sessions.incoming, nil, L .. "a reconnect drops a held ask")
  Stack.pop("bag")
  sessions:update(game, 1 / 60)
  eq(Gen3Ui.top() and Gen3Ui.top().text, "KADABRA was\ntraded over!",
    L .. "the line a trade owes survives it")
  step(game, "a") step(game, "a")
  eq(owed, 1, L .. "and its evolution still follows")
  sessions:update(game, 1 / 60)
  eq(Stack.depth(), 0, L .. "nothing else from before the reconnect goes up")
  Stack.clear()

  -- Party: an invite over the dex is held; a second one meanwhile is declined
  local Party = need("Party")
  local psent = {}
  local party = Party.new({ send = function(_, kind, body) psent[#psent + 1] = { kind = kind, body = body or {} } return true end },
                          ui, { push = function() end })
  Stack.push("pokedex", noop)
  party:onInvite(game, { from = "bob", name = "BOB" })
  eq(topId(), "pokedex", L .. "an invite over the dex waits")
  check(party.incoming ~= nil, L .. "held as the incoming invite")
  party:onInvite(game, { from = "cal", name = "CAL" })
  eq(psent[#psent] and psent[#psent].body.to, "cal", L .. "a second invite meanwhile is declined")
  eq(psent[#psent] and psent[#psent].body.accept, false, L .. "as it is with the box up")
  Stack.pop("pokedex")
  ui:pumpDeferred(game)
  eq(topId(), "rby_mmo:RbyMmoConfirm", L .. "the invite goes up once the dex closes")
  steps(game, 200)
  step(game, "down") step(game, "a")
  eq(psent[#psent] and psent[#psent].kind, Wire.PARTY_RESPOND, L .. "and is answered")
  eq(psent[#psent] and psent[#psent].body.accept, false, L .. "with the player's no")
  Stack.clear()
  Stack.push("pokedex", noop)
  party:onInvite(game, { from = "eve", name = "EVE" })
  party:onPeerGone("eve")
  Stack.pop("pokedex")
  ui:pumpDeferred(game)
  eq(Stack.depth(), 0, L .. "an inviter who left while it waited is never asked about")
  party.outgoing = { to = "bob", name = "BOB" }
  Stack.push("pokedex", noop)
  party:onDecline({ name = "BOB" })
  party:reset()
  Stack.pop("pokedex")
  ui:pumpDeferred(game)
  eq(Stack.depth(), 0, L .. "a reset takes back the party's waiting lines")

  -- ------- Ui's own tick: the queue is pumped with no hub at all
  --
  -- Sessions:update (the hub tick) is not the only pump any more: Ui:install
  -- wraps input.step on Gen 3, outermost, so a line a finished trade owes --
  -- and the evolution behind it -- reaches the player after the hub drops.
  Stack.clear()
  check(uiStep ~= nil, L .. "Ui:install wraps input.step on Gen 3")
  check(uiStepAt ~= nil and clientStepAt ~= nil and uiStepAt < clientStepAt,
    L .. "outermost: ahead of the client's own tick")
  eq(#(run.loader.events.listeners["save.loaded"] or {}), loadedBefore + 1,
    L .. "and listens for save.loaded")
  eq(#(run.loader.events.listeners["save.created"] or {}), createdBefore + 1,
    L .. "and save.created")
  do
    -- without the link (an older Ui) the chain below it is all that runs --
    -- which is exactly the case these pin
    local uiStep = uiStep or function(next, g, dt) return next(g, dt) end
    local owed = 0
    Stack.push("bag", noop)
    ui:whenFree(game, function()
      return ui:say("KADABRA was\ntraded over!", function() owed = owed + 1 end)
    end)
    eq(topId(), "bag", L .. "the owed line waits for the BAG")
    Stack.pop("bag")
    eq(uiStep(function() return "stepped" end, game, 1 / 60), "stepped",
      L .. "the link hands back what the chain below it returned")
    eq(Gen3Ui.top() and Gen3Ui.top().text, "KADABRA was\ntraded over!",
      L .. "and the line goes up from Ui's own tick, no hub, no Sessions")
    steps(game, 200)
    step(game, "a")
    eq(owed, 1, L .. "and what hangs on it follows")
    Stack.clear()

    -- a prompt queued under one save never shows under another
    local shownStale = 0
    Stack.push("bag", noop)
    ui:whenFree(game, function() shownStale = shownStale + 1 return ui:say("From before.") end)
    local kept = game.session
    game.session = session3(version, em and "EM_LITTLEROOT_TOWN" or "FR_OAKS_LAB")
    Stack.pop("bag")
    uiStep(function() end, game, 1 / 60)
    eq(shownStale, 0, L .. "a line queued before another save was loaded is dropped unseen")
    eq(#ui.deferred, 0, L .. "and leaves the queue")
    eq(Stack.depth(), 0, L .. "nothing went up")
    game.session = kept
    Stack.push("bag", noop)
    ui:whenFree(game, function() shownStale = shownStale + 1 return ui:say("Mine.") end)
    local asked = 0
    ui:whenFree(game, function() asked = asked + 1 return ui:say("EVE wants to\nteam up!") end,
      { owner = "party" })
    game.session = nil
    eq(ui.dropStale and ui:dropStale(), 1, L .. "back at the title (no session) it is stale too")
    eq(#ui.deferred, 1, L .. "but an owned ask (about the hub, not the save) stays")
    game.session = session3(version, em and "EM_LITTLEROOT_TOWN" or "FR_OAKS_LAB")
    Stack.pop("bag")
    uiStep(function() end, game, 1 / 60)
    eq(asked, 1, L .. "and goes up under the next save")
    game.session = kept
    Stack.clear()
    ui.deferred, ui.deferredBox = {}, nil

    -- ------- a layer pushed ahead of the step does not take its press
    --
    -- Client's network tick runs inside input.step, before Input:step makes
    -- the step's presses: a box it pushes there was stamped with the step
    -- that had just ended, and took the A pressed while it was not yet up.
    local ran = {}
    local probeItems = { { label = "ONE", onSelect = function() ran[#ran + 1] = "ONE" end } }
    uiStep(function()
      Gen3Ui.push(game, "Probe", { items = probeItems })
    end, game, 1 / 60)
    eq(topId(), "rby_mmo:Probe", L .. "a menu the tick pushed is up")
    step(game, "a")
    eq(#ran, 0, L .. "the A of the step it went up ahead of is not its own")
    step(game, "a")
    eq(ran[1], "ONE", L .. "the next A is")
    Stack.clear()
    -- the same box pushed after Input:step (from handleInput) keeps the old
    -- stamp: the step after it is already its own
    Gen3Ui.register("Opener2", { new = function(g)
      local s = { kind = "opener" }
      function s.handleInput(_, input)
        if input:wasPressed("a") then Gen3Ui.push(g, "Probe", { items = probeItems }) end
      end
      return s
    end })
    Gen3Ui.push(game, "Opener2")
    step(game)
    step(game, "a")
    eq(topId(), "rby_mmo:Probe", L .. "a menu an A opened is up")
    step(game, "a")
    eq(#ran, 2, L .. "and the next step's A is its own")
    Stack.clear()
  end

  -- ------- the line a trade holds the screen with
  local hold = ui.holdScreen and ui:holdScreen(game, "Waiting for\nBOB...")
  check(hold ~= nil, L .. "holdScreen puts a line up")
  eq(topId(), "rby_mmo:RbyMmoHold", L .. "as its own screen")
  eq(hold and hold.kind, "hold", L .. "which says what it is")
  eq(hold and hold.text, "Waiting for\nBOB...", L .. "with its text")
  steps(game, 200)
  for _, button in ipairs({ "a", "b", "start", "select", "a" }) do step(game, button) end
  eq(Gen3Ui.top(), hold, L .. "no button dismisses it")
  local okHold, errHold = drawAll()
  check(okHold, L .. "it draws (" .. tostring(errHold) .. ")")
  eq(Ui.occupied(game), false, L .. "it is this mod's own, so the confirm can go up over it")
  local answer
  ui:confirm(game, "Trade for\nZAP?", function(yes) answer = yes end)
  steps(game, 200)
  step(game, "a")
  eq(answer, true, L .. "the confirm over it is answered")
  eq(Gen3Ui.top(), hold, L .. "and the hold is back on top")
  check(hold ~= nil and Ui.pop(game, hold), L .. "whoever put it up takes it down")
  Stack.clear()
  eq(Stack.depth(), 0, L .. "and it is gone")

  -- ------- a sprite name off the wire draws only when it is a look
  --
  -- gfxIdFor's last fallback (when neither the mod's characters nor the
  -- cart's link-player rule answered) resolved any name the cart has a
  -- graphic for -- a Cut tree, a boulder -- for a peer to be drawn as.
  do
    local realViewer, realGfx = Gen3.viewerGfxFor, Gen3.gfxId
    Gen3.viewerGfxFor = function() return nil end
    Gen3.gfxId = function(name) return type(name) == "string" and 77 or nil end
    eq(Gen3Ui.gfxIdFor(em and "OBJ_EVENT_GFX_CUTTABLE_TREE" or "OBJ_EVENT_GFX_CUT_TREE", {}), nil,
      L .. "a Cut tree named off the wire is never drawn")
    eq(Gen3Ui.gfxIdFor("OBJ_EVENT_GFX_PUSHABLE_BOULDER", {}), nil, L .. "nor a boulder")
    eq(Gen3Ui.gfxIdFor(em and "OBJ_EVENT_GFX_BRENDAN_NORMAL" or "OBJ_EVENT_GFX_RED_NORMAL", {}), 77,
      L .. "a player look still is")
    eq(Gen3Ui.gfxIdFor(12, {}), 12, L .. "and a number is the caller's own id")
    Gen3.viewerGfxFor, Gen3.gfxId = realViewer, realGfx
  end

  -- ------- measured once, not every frame
  local Font = Gen3Ui.Font
  local realFit, realWidth = Font.fit, Font.width
  local fits, widths = 0, 0
  Font.fit = function(...) fits = fits + 1 return realFit(...) end
  Font.width = function(...) widths = widths + 1 return realWidth(...) end
  local listItems = {
    { label = "A VERY LONG NAME THAT CANNOT FIT ON ONE ROW OF THIS LIST", right = "Lv50" },
    { label = "SHORT", right = "NO" },
  }
  local lm = Gen3Ui.ListMenu.new(game, "LIST", listItems, {
    caption = function() return "A CAPTION LONGER THAN THE TITLE WINDOW CAN HOLD AT ALL" end,
  })
  Gen3Ui.pushScreen(game, "ProbeList", lm)
  drawAll()
  check(fits > 0, L .. "a list's first frame fits its rows")
  fits, widths = 0, 0
  drawAll()
  drawAll()
  eq(fits, 0, L .. "later frames fit nothing again (" .. fits .. ")")
  eq(widths, 0, L .. "nor measure a right column again (" .. widths .. ")")
  listItems[2].label = "CHANGED"
  drawAll()
  eq(fits, 1, L .. "a row whose label changed is fitted again, once")
  Stack.clear()
  local menuItems = { { label = "ONE" }, { label = "TWO" } }
  Gen3Ui.pushScreen(game, "ProbeMenu", Gen3Ui.Menu.new(game, menuItems, {}))
  drawAll()
  widths = 0
  drawAll()
  drawAll()
  eq(widths, 0, L .. "a Menu measures its rows once (" .. widths .. ")")
  menuItems[1].label = "ONE MORE"
  drawAll()
  eq(widths, 2, L .. "and a changed row again")
  Stack.clear()
  Font.fit, Font.width = realFit, realWidth

  local realLabel, realCollisions = Ui.rankLabel3, Ui.nameCollisions
  local labelled, collided = 0, 0
  Ui.rankLabel3 = function(...) labelled = labelled + 1 return realLabel(...) end
  Ui.nameCollisions = function(...) collided = collided + 1 return realCollisions(...) end
  local keptRanking = st.ranking
  st.ranking = {
    { name = "BOB", id = "b0b0", points = 1234, sprite = "OBJ_EVENT_GFX_RED_NORMAL" },
    { name = "BOB", id = "c1c1", points = 99, sprite = "OBJ_EVENT_GFX_RED_NORMAL" },
    { name = "CAL", id = "d2d2", points = 5, sprite = "OBJ_EVENT_GFX_RED_NORMAL" },
  }
  Ui.push(game, Ui.SCREEN.RANK, {})
  printed = {}
  drawAll()
  drawAll()
  drawAll()
  eq(collided, 1, L .. "RANK works the duplicate names out once per answer")
  eq(labelled, 3, L .. "and each row's name once")
  check(wasPrinted(realLabel("BOB", "b0b0", true, "1234")), L .. "and still prints them")
  st.ranking = { { name = "DEE", id = "e3e3", points = 7, sprite = "OBJ_EVENT_GFX_RED_NORMAL" } }
  drawAll()
  eq(collided, 2, L .. "a new answer from the hub is worked out again")
  Ui.rankLabel3, Ui.nameCollisions = realLabel, realCollisions
  st.ranking = keptRanking
  Stack.clear()

  Stack.clear()
  run.loader.game = nil
  run.release()
  unstubEngine()
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
  eq(Gen3Ui.occupied(), false, "gen 1: Gen3Ui is never occupied")
  eq(Ui.occupied({}), false, "gen 1: Ui.occupied is always false")
  local ui1 = Ui.new({ game = {} })
  local ran = 0
  eq(ui1:whenFree({}, function() ran = ran + 1 return "box" end), "box",
    "gen 1: whenFree runs the prompt at once and hands back its box")
  eq(ran, 1, "gen 1: once")
  eq(ui1.deferred, nil, "gen 1: nothing is ever queued")
  eq(ui1:pumpDeferred({}), false, "gen 1: and the pump has nothing to do")
  check(ui1.holdScreen ~= nil and ui1:holdScreen({}, "Waiting...") == nil, "gen 1: holdScreen puts nothing up")
  check(ui1.dropStale ~= nil and ui1:dropStale() == 0, "gen 1: and nothing is ever stale")
  _G.require = inner
  eq(#seen, 0, "gen 1: no src.*.game3.* module was required")
  run.release()
end

_G.love = previousLove
T.finish("gen3_ui")
