-- The mod.ui surface this mod uses, built natively for a Gen 3 boot.
--
-- FireRed, LeafGreen and Emerald have no Gen 1 StateStack: Game3 carries no
-- `stack`, so mod.ui.push (Screens.push -> game.stack:push) throws there, and
-- the `screens` registry is one of the registries the loader gates on Gen 3
-- (a write is dropped with a warning in loader.errors).  What the cart has
-- instead is the game3 modal stack (src/ui/game3/stack.lua): layers keyed by a
-- string id, drawn with no arguments into the 240x160 UI canvas, the top one
-- alone getting update(dt) and handleInput(input), and the field frozen while
-- any layer is up.  This file puts the mod's screens on that stack, drawn with
-- the cart's own window frames (src/ui/game3/window.lua / chrome.lua) and the
-- cart's own glyphs (src/ui/game3/frlg_font.lua), so an MMO menu reads as a
-- FireRed or Emerald menu rather than a Game Boy one stretched.
--
-- src/Ui.lua keeps one screen table for all three generations: it registers
-- every screen with the engine registry on Gen 1 / Gen 2 and with M.register
-- here on Gen 3, and every push goes through Ui.push, which is mod.ui.push or
-- M.push depending on the boot.  Nothing here runs off Gen 3: every engine
-- module is reached through Gen3.engine, which answers nil unless this is a
-- Gen 3 boot (a src.ui.game3.* require on Gen 1 / Gen 2 is a hard loader
-- error -- cross-generation denial).
--
-- ------- the contract (C2, docs/plans/gen3-firered-emerald-support.md)
--
--   register(id, def)        def = { new = function(game, opts) ... end }
--   screens                  the same, as a registry-shaped object (:register / :get)
--   push(game, id, opts)     build the screen and put it on the stack; returns it
--   pushScreen(game, id, s)  put an already-built screen up
--   pushState(game, state)   a Gen 1 / Gen 2-style state as a layer (see below)
--   pop(game, target?)       target: the screen itself, a state, a layer id or a
--                            screen id; nil pops the top *mod* layer
--   top() topLayer() has(t) states() unwindTo(game, t, alsoPop)
--   drawWidescreen(viewport) the window-space pass render.hud calls
--   TextBox.new(game, text, onDone, opts)   opts.choice / opts.defaultNo
--   Menu.new(game, items, opts)             tx/ty/tw/maxVisible/onCancel/...
--   ListMenu.new(game, title, items, opts)  onChoose/onCancel/pageJump/wrap
--   NamingScreen.new(game, opts)            title/maxLen/default/onDone/pages
--   Font  Theme  insertBefore  insertAfter  removeLabel
--   frame  dialogueFrame  drawSprite  drawIcon  drawQr  stamped
--   printable(text) / GLYPHS                the cart's charset (every Font path)
--   spriteSize  standIn  drawSpriteIn       a figure placed by its real frame
--   drawHoldIcon(kind, iconX, iconY)        the party menu's item / mail marker
--   occupied()                              the cart is using the screen, so a
--                                           prompt nobody asked for must wait
--
-- Layer ids are Config.GEN3_LAYER_PREFIX .. <ScreenId> ("rby_mmo:RbyMmoMain").
-- The game3 stack *replaces* a same-id layer on push, which a Gen 1 stack
-- never does -- two "X said no." boxes arriving together stack there, and the
-- first one's onDone still runs when it is dismissed.  So a second layer of an
-- id already up is "rby_mmo:RbyMmoText#2", and nothing a caller pushed is ever
-- silently replaced.
--
-- ------- the driver contract
--
-- The layer table IS the screen: Stack.top().mod is the Menu / ListMenu /
-- TextBox / NamingScreen object.  A menu exposes `items[i].label` (plain text;
-- a decoration a row carries lives in `items[i].prefix`, never in the label)
-- and `cursor` (1-based, the selected row -- an alias of `index`, which Ui.lua
-- writes), and handles up / down / A / B exactly the way the Gen 1 Menu does:
-- A pops the menu *then* runs the row, B pops it then runs onCancel.  A text
-- box exposes `text` (the string it was given) and, while its YES / NO is
-- open, `items` + `cursor` as well, so the same selectLabel that picks a menu
-- row answers a question.  A naming screen exposes `glyphs`, `maxLen`,
-- `row` / `col` and `grid()`, the Gen 1 widget's own fields.
--
-- ------- how the engine calls a layer
--
-- ui_pass.lua calls `layer.mod.draw()` and hud.lua `top.mod.update(dt)` then
-- `top.mod.handleInput(input)` -- plain calls, no self.  A screen here is an
-- object with methods (Ui.lua wraps them `function(self, ...)`), so pushing
-- one binds those three entry points to it once (bind below): a bound entry
-- point called with the screen first behaves as a method call, and called
-- with anything else (nil, a dt, the Input) passes that on after the screen.
--
-- Input is read in handleInput only, never in update: hud.lua re-reads the
-- stack top between the two calls, so a screen that pushed another from its
-- update would hand the new top the same frame's press.  And every layer is
-- stamped with the Input's per-step `pressed` table at push time (Input:step
-- makes a new one each fixed step), and ignores input while that table is
-- still the current one -- a box that goes up because of an A press does not
-- also take that A press.
--
-- ------- while the cart's own battle runs
--
-- hud.lua gives a layer no input during an engine battle (only the evolution
-- scene and the naming grid are exempt), and the battle scene keeps running
-- underneath a layer regardless.  A mod box pushed then would sit inert over
-- the battle's own text for the whole fight, so a layer is neither drawn nor
-- answered while Gen3.inBattle() is true: it waits, whole, for the fight to
-- end -- the order a Gen 1 box would have reached the player in.  A pushed
-- state (pushState: the mod's own battles and scenes) is exempt, and so is a
-- screen that sets `drawsInBattle`.
--
-- ------- a Gen 1 / Gen 2-style state
--
-- pushState takes the objects Sessions / Coop build (update(dt) reading
-- self.game.input, draw(), optional enter / exit, and Gold's
-- drawsWidescreen() / drawWidescreen(w, h) pair) and puts the state itself up
-- as a fullscreen layer -- field frozen and not drawn.  Such a state reads its
-- own input in update, which the engine calls for the top layer even in
-- battle.  A widescreen state draws nothing into the 240x160 canvas; the
-- render.hud hook calls M.drawWidescreen(viewport), which paints it in window
-- space and then draws every layer above it (a box over the fight) at the
-- game rect, the way Game2:drawScene blits the stack over Gold's arena.  To
-- close a pushed state, pop it: M.pop(game, state) (Ui.pop) -- there is no
-- game.stack for it to pop itself from.

local need, mod = ...
local Config = need("Config")
local Gen3 = need("Gen3")
local Chars = need("Chars")

local M = {}

local W = Config.GEN3_SCREEN_W or 240
local H = Config.GEN3_SCREEN_H or 160
local TILE = 8
local PREFIX = Config.GEN3_LAYER_PREFIX or "rby_mmo:"
M.W, M.H, M.TILE, M.PREFIX = W, H, TILE, PREFIX

-- ------- engine access (Gen 3 boots only; nil everywhere else)

local function engine(name)
  return Gen3.engine(name)
end

local function Stack() return engine("src.ui.game3.stack") end
local function Window() return engine("src.ui.game3.window") end
local function Chrome() return engine("src.ui.game3.chrome") end
local function Glyphs() return engine("src.ui.game3.frlg_font") end

local function gfx()
  local l = rawget(_G, "love")
  return type(l) == "table" and l.graphics or nil
end

local warned = {}
local function warnOnce(key, fmt, ...)
  if warned[key] then return end
  warned[key] = true
  if mod and mod.log then mod.log:warn(fmt, ...) end
end

local function sfx(name)
  if Gen3.audio and Gen3.audio.playSe then Gen3.audio.playSe(name or "SE_SELECT") end
end

-- The cart's text-speed option (0 slow / 1 mid / 2 fast), as its own message
-- printer reads it (message.lua: Options.textSpeed on the live session).
local function textSpeed()
  local Options = engine("src.core.game3.options")
  local session = Gen3.session()
  if not (Options and session and type(Options.textSpeed) == "function") then return 1 end
  local ok, speed = pcall(Options.textSpeed, session)
  speed = ok and tonumber(speed) or 1
  if speed < 0 then speed = 0 elseif speed > 2 then speed = 2 end
  return speed
end

-- A line of the cart's own text (RomText), or the fallback when the text pack
-- is not there (a headless load).
local function romText(key, fallback)
  local RomText = engine("src.core.game3.rom_text")
  if RomText and type(RomText.plain) == "function" then
    local ok, text = pcall(RomText.plain, key)
    if ok and type(text) == "string" and text ~= "" then return text end
  end
  return fallback
end

-- ------- colours

local function palette(i)
  local F = Glyphs()
  local pal = F and F.STDPAL
  return type(pal) == "table" and pal[i] or nil
end

-- Named text colours: the cart's own three-slot sets (frlg_font COLOR) plus
-- MUTED, a greyed row that is still readable.
local function colorsOf(name)
  if type(name) == "table" then return name end
  local F = Glyphs()
  local C = F and F.COLOR
  if name == "MUTED" then
    return { fg = { 0.58, 0.58, 0.58, 1 }, shadow = (palette(3) or { 0.84, 0.84, 0.8, 1 }),
             bg = { 0, 0, 0, 0 } }
  end
  if type(C) ~= "table" then return nil end
  return C[name or "NORMAL"] or C.NORMAL
end
M.colors = colorsOf

-- ------- Font: the cart's glyphs, measured in pixels
--
-- Variable-width (pret latin_normal widths), 14px glyphs on a 15px line.  The
-- one addition is U+25B7 "▷": the mod's friend mark, which the cart's charmap
-- does not carry (frlg_font draws a glyph it cannot map as a space).  It is
-- drawn here as a hollow triangle of the same size as the "▶" cursor glyph,
-- in the text's own two tones, so a label keeps meaning what it means on
-- Gen 1.

local Font = {}
M.Font = Font
Font.LINE = 15
Font.HEIGHT = 14
Font.HOLLOW = "\226\150\183"   -- ▷
local AVG_ADVANCE = 6          -- a missing font's per-glyph guess
local HOLLOW_W = 7

-- ------- the cart's charset, as the mod's text meets it
--
-- The Gen 3 charmap (src/core/game3/scripting/text_ir.lua CHARMAP, plus the
-- extra symbols frlg_font maps) has round brackets and no square ones, no
-- "#", "*", "@", "~", "|", "^", "`" or backslash -- and frlg_font draws a
-- character it cannot map as a blank, so "[G]BOB:" printed " G BOB:".  Worse,
-- "{" is the font's own markup: "{" .. anything .. "}" is read as a control
-- tag ({COLOR RED}, {PLAYER}) and swallowed, and in a --developer run an
-- unknown one *throws* inside the draw.  So every string this toolkit prints
-- or measures passes through this one table first, and every screen gets the
-- same answer without having to know the charset: brackets and braces are
-- the cart's parentheses (src/Toast.lua's gen3Text maps those five the same
-- way), "#" is the cart's own "№" (0x108, the dex's number sign), and the
-- rest are the nearest glyph the cart does have.  One character for one
-- character, always: TextBox's typewriter counts characters, and a mapping
-- that changed a line's length would reveal it out of step with its text.
--
-- Wire.text strips all of these from anything a player sends, so in practice
-- this only ever meets the mod's own literals -- which is the point: a label
-- written once for all three generations reads right on this one too.
M.GLYPHS = {
  ["["] = "(", ["]"] = ")", ["{"] = "(", ["}"] = ")", ["\\"] = "/",
  ["#"] = "\226\132\150",       -- №
  ["*"] = "\195\151",           -- ×
  ["@"] = "a", ["~"] = "-", ["|"] = "/", ["^"] = "'", ["`"] = "'",
}
local GLYPH_CLASS = "[%[%]{}\\#%*@~|%^`]"

-- `text` as the cart can print it (see above).  Pure, and cheap when there is
-- nothing to map.
function Font.printable(text)
  local s = tostring(text or "")
  if not s:find(GLYPH_CLASS) then return s end
  return (s:gsub(GLYPH_CLASS, M.GLYPHS))
end
M.printable = Font.printable

local function utf8Chars(text)
  local out = {}
  local s = tostring(text or "")
  local i, n = 1, #s
  while i <= n do
    local b = s:byte(i)
    local len = 1
    if b >= 0xF0 then len = 4 elseif b >= 0xE0 then len = 3 elseif b >= 0xC0 then len = 2 end
    if i + len - 1 > n then len = 1 end
    out[#out + 1] = { from = i, to = i + len - 1, ch = s:sub(i, i + len - 1) }
    i = i + len
  end
  return out
end

-- Text split into plain runs and hollow marks, in order.
local function segments(text)
  local s = tostring(text or "")
  if not s:find(Font.HOLLOW, 1, true) then return { { text = s } } end
  local out, pos = {}, 1
  while true do
    local a, b = s:find(Font.HOLLOW, pos, true)
    if not a then
      if pos <= #s then out[#out + 1] = { text = s:sub(pos) } end
      break
    end
    if a > pos then out[#out + 1] = { text = s:sub(pos, a - 1) } end
    out[#out + 1] = { hollow = true }
    pos = b + 1
  end
  return out
end

local function measureRun(run, opts)
  if run == "" then return 0 end
  local F = Glyphs()
  if F and type(F.measure) == "function" then
    local ok, w = pcall(F.measure, run, opts and { small = opts.small } or nil)
    if ok and tonumber(w) then return tonumber(w) end
  end
  return #utf8Chars(run) * AVG_ADVANCE
end

function Font.width(text, opts)
  local total = 0
  for _, seg in ipairs(segments(Font.printable(text))) do
    if seg.hollow then total = total + HOLLOW_W else total = total + measureRun(seg.text, opts) end
  end
  return total
end

-- The widest line of a multi-line string.
function Font.measure(text, opts)
  local widest = 0
  for line in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
    local w = Font.width(line, opts)
    if w > widest then widest = w end
  end
  return widest
end

-- The friend mark: rows 2..10 of the glyph cell, a vertical edge and two
-- diagonals meeting at x+4, shadow one pixel down-right like every glyph.
local function drawHollow(x, y, colors)
  local g = gfx()
  if not g then return end
  local function plot(c, dx, dy)
    if type(c) ~= "table" or (c[4] ~= nil and c[4] <= 0) then return end
    g.setColor(c[1] or 0, c[2] or 0, c[3] or 0, c[4] or 1)
    for r = 0, 8 do
      local d = math.min(r, 8 - r)
      g.rectangle("fill", x + dx, y + 2 + r + dy, 1, 1)
      if d > 0 then g.rectangle("fill", x + d + dx, y + 2 + r + dy, 1, 1) end
    end
  end
  plot(colors and colors.shadow, 1, 1)
  plot(colors and colors.fg, 0, 0)
  g.setColor(1, 1, 1, 1)
end

-- Draw at pixel (x, y) in the 240x160 canvas.  opts.color / opts.colors
-- ("NORMAL", "WHITE", "BLUE", "RED", "MUTED" or a three-slot table),
-- opts.maxWidth (clip), opts.small.  Returns the width drawn.  The text is
-- mapped onto the cart's charset first (Font.printable), so no glyph prints
-- blank and nothing is read as markup.
function Font.draw(text, x, y, opts)
  opts = opts or {}
  local F = Glyphs()
  local colors = colorsOf(opts.colors or opts.color or "NORMAL")
  local pen = x
  local maxW = tonumber(opts.maxWidth)
  for _, seg in ipairs(segments(Font.printable(text))) do
    local room = maxW and (maxW - (pen - x)) or nil
    if room and room <= 0 then break end
    if seg.hollow then
      drawHollow(pen, y, colors)
      pen = pen + HOLLOW_W
    elseif seg.text ~= "" then
      if F and type(F.draw) == "function" then
        pcall(F.draw, seg.text, pen, y, {
          colors = colors, maxWidth = room or W, small = opts.small, linePitch = opts.linePitch,
        })
      end
      pen = pen + measureRun(seg.text, opts)
    end
  end
  local g = gfx()
  if g then g.setColor(1, 1, 1, 1) end
  return pen - x
end

-- Right-aligned so the text *ends* at x.
function Font.drawRight(text, x, y, opts)
  return Font.draw(text, x - Font.width(text, opts), y, opts)
end

function Font.drawCentered(text, cx, y, opts)
  return Font.draw(text, math.floor(cx - Font.width(text, opts) / 2), y, opts)
end

-- UTF-8 spans, the shape src/render/Font.split hands back ({ from, to }), so
-- a caller that clips on a span boundary works on either font.
function Font.split(text)
  local out = {}
  for _, c in ipairs(utf8Chars(text)) do out[#out + 1] = { from = c.from, to = c.to } end
  return out
end

-- The longest prefix that fits `px`, cut on a whole character.
function Font.fit(text, px, opts)
  text = tostring(text or "")
  if Font.width(text, opts) <= px then return text end
  local chars = utf8Chars(text)
  local lo, hi = 0, #chars
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    local cut = text:sub(1, chars[mid].to)
    if Font.width(cut, opts) <= px then lo = mid else hi = mid - 1 end
  end
  if lo == 0 then return "" end
  return text:sub(1, chars[lo].to)
end

-- Word-wrap to `px`; a word longer than the line is cut on characters.
function Font.wrap(text, px, opts)
  local lines = {}
  for raw in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
    local line = ""
    for word in raw:gmatch("%S+") do
      local candidate = line == "" and word or (line .. " " .. word)
      if Font.width(candidate, opts) <= px then
        line = candidate
      else
        if line ~= "" then lines[#lines + 1] = line end
        while Font.width(word, opts) > px do
          local head = Font.fit(word, px, opts)
          if head == "" then break end
          lines[#lines + 1] = head
          word = word:sub(#head + 1)
        end
        line = word
      end
    end
    lines[#lines + 1] = line
  end
  -- the trailing "\n" sentinel's empty line is not a line
  if #lines > 1 and lines[#lines] == "" then lines[#lines] = nil end
  return lines
end

-- ------- frames and furniture

-- The cart's std 9-slice around a content rect in tiles (Window.stdFrame on a
-- WindowTemplate: the border sits one tile outside it).
function M.frame(left, top, w, h)
  local Win = Window()
  if Win then
    local ok = pcall(function() Win.stdFrame(Win.template(left, top, w, h)) end)
    if ok then return true end
  end
  local g = gfx()
  if not g then return false end
  g.setColor(98 / 255, 115 / 255, 123 / 255, 1)
  g.rectangle("fill", (left - 1) * TILE, (top - 1) * TILE, (w + 2) * TILE, (h + 2) * TILE)
  g.setColor(1, 1, 1, 1)
  g.rectangle("fill", left * TILE - 6, top * TILE - 6, (w + 2) * TILE - 4, (h + 2) * TILE - 4)
  return true
end

-- Gen 1 Font.drawBox semantics (the outer box, border included, in tiles), so
-- a screen written against a bordered-box grid can say the same thing here.
function Font.drawBox(tx, ty, tw, th)
  return M.frame(tx + 1, ty + 1, tw - 2, th - 2)
end

-- The dialogue window's content rect in tiles (FRLG 2,15 26x4).
function M.dialogueWindow()
  local C = Chrome()
  if C and type(C.dialogueWindow) == "function" then
    local ok, l, t, w, h = pcall(C.dialogueWindow)
    if ok and tonumber(l) then return l, t, w, h end
  end
  return 2, 15, 26, 4
end

function M.dialogueFrame()
  local C = Chrome()
  if C and type(C.dialogueFrame) == "function" and pcall(C.dialogueFrame) then return true end
  local l, t, w, h = M.dialogueWindow()
  return M.frame(l, t, w, h)
end

function M.cursor(x, y)
  local Win = Window()
  if Win and type(Win.cursorPx) == "function" and pcall(Win.cursorPx, x, y) then return end
  Font.draw("\226\150\182", x, y)   -- ▶
end

-- Scroll arrows over a content template (tiles), the list_menu.lua ones.
local arrowTick = 0
function M.scrollArrows(left, top, w, h, up, down)
  if not (up or down) then return end
  arrowTick = (arrowTick + 1) % 256
  local LM = engine("src.ui.game3.list_menu")
  if LM and type(LM.drawScrollArrows) == "function" then
    local ok = pcall(LM.drawScrollArrows, { left = left, top = top, w = w, h = h }, up, down, arrowTick)
    if ok then return end
  end
  local cx = (left + w / 2) * TILE
  if up then Font.drawCentered("\226\150\178", cx, top * TILE - 10) end
  if down then Font.drawCentered("\226\150\188", cx, (top + h) * TILE - 6) end
end

-- ------- overworld sprites, party icons, QR codes

-- An avatar's graphic on *this* cart: a Gen 3 OBJ_EVENT_GFX_* name from any
-- version, the Config token, or a number.  opts.version / opts.gender are the
-- owner's (presence carries both).  Mapped by Chars.gfxForViewer -- the look
-- table first (a FireRed RED_NORMAL and an Emerald RED are one boy), then the
-- carts' own Cable Club rule -- which is the rule src/Avatars.lua walks the
-- same player with, so a card, a rank row and the figure in the field never
-- disagree about who somebody looks like.
local function gfxIdFor(sprite, opts)
  opts = opts or {}
  if type(sprite) == "number" then return sprite end
  local id = Chars.gfxForViewer(sprite, opts.version, opts.gender)
  if tonumber(id) then return tonumber(id) end
  id = Gen3.viewerGfxFor(sprite, opts.version, opts.gender)
  if tonumber(id) then return tonumber(id) end
  return Gen3.gfxId(sprite)
end
M.gfxIdFor = gfxIdFor

local subQuads = {}
local function spriteQuad(spr, frame, clipTop, clipH)
  local q = spr.quads and spr.quads[frame]
  if not q then return nil end
  if not (clipTop or clipH) then return q, spr.width, spr.height end
  local key = tostring(spr) .. ":" .. frame .. ":" .. tostring(clipTop) .. ":" .. tostring(clipH)
  local hit = subQuads[key]
  if hit then return hit.q, hit.w, hit.h end
  local g = gfx()
  if not (g and q.getViewport and spr.image and spr.image.getDimensions) then return q, spr.width, spr.height end
  local qx, qy, qw, qh = q:getViewport()
  local top = math.max(0, math.min(qh - 1, clipTop or 0))
  local hh = math.max(1, math.min(qh - top, clipH or (qh - top)))
  local iw, ih = spr.image:getDimensions()
  local sub = g.newQuad(qx, qy + top, qw, hh, iw, ih)
  subQuads[key] = { q = sub, w = qw, h = hh }
  return sub, qw, hh
end

-- The engine's sheet for `sprite` on this cart (OwSprites.getDraw: a palette
-- override the cart applied is honoured), and its module.  nil when there is
-- no such graphic.
local function sheetFor(sprite, opts)
  local Ow = engine("src.core.game3.ow_sprites")
  local gid = gfxIdFor(sprite, opts or {})
  if not (Ow and gid) then return nil end
  local okS, spr = pcall(Ow.getDraw or Ow.get, gid)
  if not (okS and type(spr) == "table" and spr.image) then return nil end
  return spr, Ow
end

-- A frame's size in pixels: a figure's sheet frame (16x32 for a person, 32x32
-- for the bigger graphics), or a Chars.portrait entry's own w / h.  nil, nil
-- when there is nothing to draw.
function M.spriteSize(sprite, opts)
  if type(sprite) == "table" and sprite.image then
    local w, h = tonumber(sprite.w), tonumber(sprite.h)
    if w and h then return w, h end
    local q = sprite.quad
    if q and q.getViewport then
      local _, _, qw, qh = q:getViewport()
      return qw, qh
    end
    return nil, nil
  end
  local spr = sheetFor(sprite, opts)
  if not spr then return nil, nil end
  return tonumber(spr.width) or 16, tonumber(spr.height) or 32
end

-- Where a w x h frame stands in a box: the largest whole-number scale that
-- fits (capped at opts.maxScale, default 2 -- a GBA menu never draws a person
-- bigger than twice the size the field does), centred across and feet on the
-- box's bottom edge, the way the cart stands a trainer on its card.  Pure, so
-- the suite pins the arithmetic without a sheet.  -> x, y, scale
function M.standIn(w, h, box, opts)
  opts = opts or {}
  w, h = tonumber(w) or 16, tonumber(h) or 32
  local bw, bh = tonumber(box.w) or w, tonumber(box.h) or h
  local maxScale = math.max(1, math.floor(tonumber(opts.maxScale) or 2))
  local scale = math.min(maxScale, math.floor(bw / w), math.floor(bh / h))
  if scale < 1 then scale = 1 end
  local x = (tonumber(box.x) or 0) + math.floor((bw - w * scale) / 2)
  local y = (tonumber(box.y) or 0) + bh - h * scale
  return x, y, scale
end

-- Stand `sprite` in `box` ({ x, y, w, h } px) by its real frame size (see
-- M.standIn), whatever that is -- a person's 16x32, a 32x32 figure, or a
-- Chars.portrait entry ({ image, quad, w, h }).  The pose options are
-- M.drawSprite's.  Returns the drawn width, height and scale, or nil.
function M.drawSpriteIn(sprite, box, opts)
  opts = opts or {}
  local w, h = M.spriteSize(sprite, opts)
  if not (w and h) then return nil end
  local x, y, scale = M.standIn(w, h, box, opts)
  if type(sprite) == "table" and sprite.image then
    local g = gfx()
    if not g then return nil end
    g.setColor(1, 1, 1, 1)
    if sprite.quad then
      g.draw(sprite.image, sprite.quad, x, y, 0, scale, scale)
    else
      g.draw(sprite.image, x, y, 0, scale, scale)
    end
    return w * scale, h * scale, scale
  end
  local drawOpts = {}
  for k, v in pairs(opts) do drawOpts[k] = v end
  drawOpts.scale = scale
  local dw, dh = M.drawSprite(sprite, x, y, drawOpts)
  if not dw then return nil end
  return dw, dh, scale
end

-- Draw one frame of an overworld sprite with its top-left at (x, y).
-- opts.frame (default 0, stand facing down) or opts.facing + opts.walk /
-- opts.step (OwSprites.pose), opts.scale, opts.clipTop / opts.clipH (a crop
-- of the frame, for a bust on a list row).  Returns the drawn width and
-- height, or nil when there is no such graphic on this cart.
function M.drawSprite(sprite, x, y, opts)
  opts = opts or {}
  local g = gfx()
  if not g then return nil end
  local spr, Ow = sheetFor(sprite, opts)
  if not spr then return nil end
  local frame = tonumber(opts.frame)
  local flip = false
  if not frame then
    if type(Ow.pose) == "function" and (opts.facing or opts.walk) then
      local okP, f, fl = pcall(Ow.pose, spr, opts.facing or "down", opts.walk and 1 or 0, opts.step)
      frame, flip = okP and f or 0, okP and fl or false
    else
      frame = 0
    end
  end
  local q, w, h = spriteQuad(spr, frame, opts.clipTop, opts.clipH)
  if not q then return nil end
  local scale = tonumber(opts.scale) or 1
  g.setColor(1, 1, 1, 1)
  if flip then
    g.draw(spr.image, q, x + w * scale, y, 0, -scale, scale)
  else
    g.draw(spr.image, q, x, y, 0, scale, scale)
  end
  return w * scale, h * scale
end

-- A party icon (32x32, two frames) for a mon table or a species id.
function M.drawIcon(subject, x, y, frame)
  local g = gfx()
  local icon = Gen3.icon(subject)
  if not (g and type(icon) == "table" and icon.image) then return false end
  local frames = tonumber(icon.frames) or 1
  local q = icon.quads and icon.quads[(tonumber(frame) or 0) % math.max(frames, 1)]
  g.setColor(1, 1, 1, 1)
  if q then g.draw(icon.image, q, x, y) else g.draw(icon.image, x, y) end
  return true
end

-- The party menu's 8x8 held-item marker beside a party icon: frame 0 an item,
-- frame 1 mail (pokefirered/src/party_menu.c:2743 UpdatePartyMonHeldItemSprite,
-- the sheet src/ui/game3/party_menu.lua heldItemSheet decodes).  The cart
-- puts it 16 right and 22 down from the icon's top-left (its sprite centres
-- in sSpriteCoords, 104,18 -> 108,28), so that is what `iconX, iconY` are.
-- Asked of the engine once: a cache without the sheet answers false for the
-- rest of the run instead of throwing every frame.
local holdSheet
function M.drawHoldIcon(kind, iconX, iconY)
  if kind ~= "item" and kind ~= "mail" then return false end
  local g = gfx()
  if not g then return false end
  if holdSheet == nil then
    holdSheet = false
    local PartyMenu = engine("src.ui.game3.party_menu")
    if PartyMenu and type(PartyMenu.heldItemSheet) == "function" then
      local ok, sheet = pcall(PartyMenu.heldItemSheet)
      if ok and type(sheet) == "table" and sheet.image and type(sheet.quads) == "table" then
        holdSheet = sheet
      end
    end
  end
  if not holdSheet then return false end
  local q = holdSheet.quads[kind == "mail" and 1 or 0]
  if not q then return false end
  g.setColor(1, 1, 1, 1)
  g.draw(holdSheet.image, q, iconX + 16, iconY + 22)
  return true
end

-- A QR matrix (rows of booleans) at an integer module size, with the four-
-- module quiet zone readers need, fitted into `box` px.  Returns the square's
-- outer size, or nil when there is nothing to draw.
function M.qrScale(size, box)
  size = tonumber(size) or 0
  if size <= 0 then return nil end
  return math.max(1, math.floor((tonumber(box) or H) / (size + 8)))
end

function M.drawQr(matrix, x, y, box)
  local g = gfx()
  if not (g and type(matrix) == "table" and #matrix > 0) then return nil end
  local size = #matrix
  local scale = M.qrScale(size, box)
  local quiet = scale * 4
  local outer = size * scale + quiet * 2
  g.setColor(1, 1, 1, 1)
  g.rectangle("fill", x, y, outer, outer)
  g.setColor(0, 0, 0, 1)
  for row, cells in ipairs(matrix) do
    for col, dark in ipairs(cells) do
      if dark then
        g.rectangle("fill", x + quiet + (col - 1) * scale, y + quiet + (row - 1) * scale, scale, scale)
      end
    end
  end
  g.setColor(1, 1, 1, 1)
  return outer
end

-- ------- Theme, and the menu-injection helpers

M.Theme = {
  W = W, H = H, TILE = TILE, LINE = Font.LINE,
  cursor = "\226\150\182",        -- ▶ (charmap 0xEF, gText_SelectorArrow2)
  cursorHollow = Font.HOLLOW,     -- ▷ (drawn by Font; see above)
  moreArrow = "\226\150\188",     -- ▼ (CHAR_DOWN_ARROW)
  upArrow = "\226\150\178",       -- ▲ (CHAR_UP_ARROW)
  colors = colorsOf,
}

-- Gen 3 START rows carry an id and a label that is the cart's own text
-- (RomText), so the anchor is tried as an id first and a label second.
local function anchorIndex(items, anchor)
  for i, item in ipairs(items or {}) do
    if type(item) == "table" and item.id == anchor then return i end
  end
  for i, item in ipairs(items or {}) do
    if type(item) == "table" and item.label == anchor then return i end
  end
  return nil
end

function M.insertBefore(items, anchor, item)
  if type(items) ~= "table" then return items end
  local i = anchorIndex(items, anchor)
  table.insert(items, i or (#items + 1), item)
  return items
end

function M.insertAfter(items, anchor, item)
  if type(items) ~= "table" then return items end
  local i = anchorIndex(items, anchor)
  table.insert(items, i and (i + 1) or (#items + 1), item)
  return items
end

function M.removeLabel(items, label)
  if type(items) ~= "table" then return items end
  for i = #items, 1, -1 do
    if type(items[i]) == "table" and (items[i].label == label or items[i].id == label) then
      table.remove(items, i)
    end
  end
  return items
end

-- ------- the registry

local registry = {}

function M.register(id, def)
  if type(id) ~= "string" or type(def) ~= "table" or type(def.new) ~= "function" then
    warnOnce("register:" .. tostring(id), "a Gen 3 screen was registered without a "
      .. "`new` constructor (%s) -- register { new = function(game, opts) ... end }",
      tostring(id))
    return false
  end
  registry[id] = def
  return true
end

function M.registered(id)
  return registry[id]
end

-- Registry-shaped, so Ui:install can say `screens:register(id, def)` to
-- either this or mod.content.screens.
M.screens = {
  register = function(_, id, def) return M.register(id, def) end,
  get = function(_, id) return registry[id] end,
}

-- ------- the stack

local function layerList()
  local S = Stack()
  local L = S and rawget(S, "_layers")
  return type(L) == "table" and L or {}
end

local function isModLayer(layer)
  return type(layer) == "table" and type(layer.id) == "string"
    and layer.id:sub(1, #PREFIX) == PREFIX
end
M.isModLayer = isModLayer

local function escapePattern(s)
  return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

local function idMatches(layerId, target)
  if layerId == target then return true end
  local full = target:sub(1, #PREFIX) == PREFIX and target or (PREFIX .. target)
  if layerId == full then return true end
  return layerId:find("^" .. escapePattern(full) .. "#%d+$") ~= nil
end

-- Topmost layer matching `target` (a screen / state object, a layer id, a
-- screen id); nil target is the top layer.  -> index, layer
local function findLayer(target)
  local L = layerList()
  for i = #L, 1, -1 do
    local layer = L[i]
    if target == nil then return i, layer end
    if type(target) == "string" then
      if type(layer.id) == "string" and idMatches(layer.id, target) then return i, layer end
    elseif layer.mod == target then
      return i, layer
    end
  end
  return nil
end

local function uniqueId(base)
  local S = Stack()
  if not (S and type(S.has) == "function" and S.has(base)) then return base end
  local n = 2
  while S.has(base .. "#" .. n) do n = n + 1 end
  return base .. "#" .. n
end

-- Bind a screen's three engine entry points to it (see the header).
local ENTRY = { "draw", "update", "handleInput" }
local function bind(screen)
  if rawget(screen, "__g3bound") then return screen end
  for _, name in ipairs(ENTRY) do
    local fn = screen[name]
    if type(fn) == "function" then
      if name == "draw" then
        screen[name] = function(first, ...)
          -- a box waits out the cart's battle; a pushed state (the mod's own
          -- fight or scene) is never hidden, and neither is a screen that
          -- says drawsInBattle
          if Gen3.inBattle() and not rawget(screen, "drawsInBattle")
              and not rawget(screen, "__g3State") then
            return
          end
          if first == screen then return fn(screen, ...) end
          return fn(screen, first, ...)
        end
      else
        screen[name] = function(first, ...)
          if first == screen then return fn(screen, ...) end
          return fn(screen, first, ...)
        end
      end
    end
  end
  rawset(screen, "__g3bound", true)
  return screen
end

-- True while `input` is still the step this screen was pushed in.
function M.stamped(screen, input)
  if type(screen) ~= "table" or type(input) ~= "table" then return false end
  local stamp = rawget(screen, "_g3Stamp")
  return stamp ~= nil and input.pressed == stamp
end

local function stamp(screen, game)
  local input = type(game) == "table" and game.input or nil
  local pressed = type(input) == "table" and input.pressed or nil
  rawset(screen, "_g3Stamp", pressed)
end

function M.pushScreen(game, id, screen, opts)
  if type(screen) ~= "table" then return nil end
  local S = Stack()
  if not (S and type(S.push) == "function") then
    warnOnce("nostack", "the Gen 3 modal stack (src/ui/game3/stack.lua) is not "
      .. "reachable, so the MMO screens cannot open -- update the mod for this "
      .. "engine build")
    return nil
  end
  opts = opts or {}
  bind(screen)
  local layerId = uniqueId(PREFIX .. tostring(id or screen.screenId or "Screen"))
  rawset(screen, "gen3Layer", layerId)
  if rawget(screen, "screenId") == nil then rawset(screen, "screenId", id) end
  if screen.game == nil then screen.game = game end
  stamp(screen, game)
  local isState = rawget(screen, "__g3State") == true
  local opaque = screen.isOpaque == true
  local hideBelow = opts.hideBelow
  if hideBelow == nil then hideBelow = isState or opaque or screen.hideBelow == true end
  local fullscreen = opts.fullscreen
  if fullscreen == nil then
    if isState then fullscreen = screen.fullscreen ~= false
    else fullscreen = opaque or screen.fullscreen == true end
  end
  local ok, err = pcall(S.push, layerId, screen, { hideBelow = hideBelow, fullscreen = fullscreen })
  if not ok then
    mod.log:warn("could not put the %s screen on the Gen 3 stack (%s) -- update "
      .. "the mod for this engine build", tostring(id), tostring(err))
    return nil
  end
  local enter = screen.enter
  if type(enter) == "function" then
    local okE, errE = pcall(enter, screen)
    if not okE then
      mod.log:warn("the %s screen failed while opening (%s) -- report this with "
        .. "the line above", tostring(id), tostring(errE))
    end
  end
  return screen
end

function M.push(game, id, opts, ...)
  local def = registry[id]
  if not def then
    mod.log:warn("there is no Gen 3 screen called %s -- Ui:install registers "
      .. "every screen; update the mod", tostring(id))
    return nil
  end
  local ok, screen = pcall(def.new, game, opts, ...)
  if not ok then
    mod.log:warn("the %s screen failed to open (%s) -- report this with the "
      .. "line above", tostring(id), tostring(screen))
    return nil
  end
  if type(screen) ~= "table" then return nil end
  return M.pushScreen(game, id, screen)
end

-- Mark a Gen 1 / Gen 2-style state for pushScreen (fullscreen, hide below).
function M.asState(state)
  if type(state) ~= "table" then return nil end
  rawset(state, "__g3State", true)
  return state
end

function M.pushState(game, state)
  if type(state) ~= "table" then return nil end
  return M.pushScreen(game, "RbyMmoState", M.asState(state))
end

-- Take a layer down.  `target` is the screen / state itself, a layer id or a
-- screen id; nil means the top layer, and only when it is one of this mod's --
-- an engine layer (START, the naming grid) is never taken down by accident.
function M.pop(game, target)
  local S = Stack()
  if not S then return false end
  local _, layer = findLayer(target)
  if not layer then return false end
  if target == nil and not isModLayer(layer) then return false end
  local ok, removed
  if isModLayer(layer) then
    ok, removed = pcall(S.pop, layer.id)
  else
    -- an engine layer asked for by name or identity: its own dismiss when it
    -- has one, so its module state does not outlive the layer
    local dismissed = false
    if layer.id == "naming" then
      local Naming = engine("src.ui.game3.naming")
      if Naming and type(Naming.dismiss) == "function" then
        dismissed = pcall(Naming.dismiss)
      end
    elseif layer.id == "start" then
      local StartMenu = engine("src.ui.game3.start_menu")
      if StartMenu and type(StartMenu.close) == "function" then
        dismissed = pcall(StartMenu.close, true)
      end
    end
    if dismissed then
      ok, removed = true, true
    else
      ok, removed = pcall(S.pop, layer.id)
    end
  end
  if not (ok and removed) then return false end
  local screen = layer.mod
  local exit = type(screen) == "table" and screen.exit or nil
  if type(exit) == "function" and isModLayer(layer) then
    local okE, errE = pcall(exit, screen)
    if not okE then
      mod.log:warn("a Gen 3 screen failed while closing (%s) -- report this with "
        .. "the line above", tostring(errE))
    end
  end
  return true
end

function M.topLayer()
  local S = Stack()
  local ok, top = pcall(function() return S and S.top() end)
  return ok and type(top) == "table" and top or nil
end

function M.top()
  local top = M.topLayer()
  return top and top.mod or nil
end

function M.has(target)
  if target == nil then return false end
  return findLayer(target) ~= nil
end

-- Every layer's screen, bottom to top.
function M.states()
  local out = {}
  for _, layer in ipairs(layerList()) do out[#out + 1] = layer.mod end
  return out
end

-- ------- is the cart using the screen
--
-- A prompt this mod raises unasked -- somebody's trade or battle request, a
-- party invite, the answer to an ask the player made and walked away from --
-- used to go straight onto the stack whatever was there: over the BAG, the
-- POKéMON list, the dex, an NPC's sentence, START, the naming grid.  The
-- field freezes under a layer, but the cart's own menu underneath is left
-- holding a half-finished action with a mod box drawn through it.  This is
-- the one statement of "not now" those prompts wait on (Ui.occupied /
-- Ui:whenFree): the moment the player could press START again is the moment
-- they are free, which is the cart's own rule for when a menu may open
-- (hud.lua start_button_allowed + Hud.busy).
--
-- Occupied, then, while any of:
--   * the field is not running (title, the boot menus, the FRLG recap), or
--     the cart's battle is;
--   * a layer on the stack is the cart's own -- START, BAG, POKéMON, the
--     dex, the naming grid, the PC, a shop, an evolution ... every one of
--     them is a stack layer (src/ui/game3/*.lua Stack.push), so a layer of
--     this mod's sitting over one does not make the player free of it;
--   * the cart's message box, yes / no, a fade or a script's wait-for-button
--     is up (Hud.busy's half that is not the stack);
--   * a script is running, or a warp / forced move / field effect has the
--     player locked.
-- A layer of this mod's own on top of nothing of the cart's is *not*
-- occupied: a request landing while the player browses PLAYERS goes up over
-- it exactly as it does on Gen 1.  False off Gen 3.
-- Every one of these is loaded by the time the field runs (hud.lua requires
-- them), so asking costs a cached lookup; the mod sandbox has no `package`
-- to peek into instead.
local function loaded(name)
  return engine(name)
end

local function call(t, name, ...)
  local fn = type(t) == "table" and t[name] or nil
  if type(fn) ~= "function" then return nil end
  local ok, value = pcall(fn, ...)
  return ok and value or nil
end

local function cartDialogueOpen()
  local Message = loaded("src.ui.game3.message")
  if Message and call(Message, "isOpen") then return true end
  local Choice = loaded("src.ui.game3.choice")
  if type(Choice) == "table" and Choice.active == true then return true end
  local Fade = loaded("src.ui.game3.fade")
  if Fade and call(Fade, "isActive") then return true end
  local Hud = loaded("src.ui.game3.hud")
  if type(Hud) == "table" and Hud._waitButton ~= nil then return true end
  return false
end

local function fieldLocked()
  local Space = loaded("src.core.game3.scripting.space")
  local vm = type(Space) == "table" and Space.vm or nil
  if type(vm) == "table" and type(vm.isRunning) == "function" then
    local ok, running = pcall(vm.isRunning, vm)
    if ok and running then return true end
  end
  local Field = loaded("src.core.game3.field")
  if type(Field) == "table" and Field.locked then return true end
  local Forced = loaded("src.core.game3.forced_movement")
  if Forced and call(Forced, "isForced") then return true end
  local Warp = loaded("src.core.game3.warp")
  if Warp and call(Warp, "isBusy") then return true end
  local P = loaded("src.core.game3.player")
  if type(P) == "table" and P.boulderPush ~= nil then return true end
  return false
end

function M.occupied()
  if not Gen3.active() then return false end
  if not Gen3.inField() then return true end
  if Gen3.inBattle() then return true end
  local mine = false
  for _, layer in ipairs(layerList()) do
    if not isModLayer(layer) then return true end
    mine = true
  end
  -- With nothing of this mod's up, the engine's own answer covers anything
  -- the list above does not name (Hud.busy: the stack is empty here, so it is
  -- the cart's dialogue, fades and waits).  With a layer of ours up it cannot
  -- be asked -- it would count that layer -- so the dialogue half is read
  -- directly.
  if not mine and Gen3.busy() then return true end
  if cartDialogueOpen() then return true end
  return fieldLocked()
end

-- Everything above `target` off the stack, and `target` too with alsoPop.
-- False (and nothing touched) when `target` is not on it -- the same guard
-- Coop.unwindStackTo keeps against hunting for a state that already left.
function M.unwindTo(game, target, alsoPop)
  if target == nil or not M.has(target) then return false end
  local guard = 0
  while guard < 32 do
    guard = guard + 1
    local layer = M.topLayer()
    if not layer then break end
    if layer.mod == target or (type(target) == "string" and idMatches(tostring(layer.id), target)) then
      if alsoPop then M.pop(game, layer.mod) end
      return true
    end
    if not M.pop(game, layer.mod) then return false end
  end
  return false
end

local function drawsWide(state)
  if type(state) ~= "table" or type(state.drawsWidescreen) ~= "function"
     or type(state.drawWidescreen) ~= "function" then
    return false
  end
  local ok, wide = pcall(state.drawsWidescreen, state)
  return ok and wide == true
end

-- The window-space pass (render.hud).  Paints the topmost visible widescreen
-- state edge to edge, then every visible layer above it at the game rect.
-- True when it drew.
function M.drawWidescreen(viewport)
  if type(viewport) ~= "table" then return false end
  local S = Stack()
  local g = gfx()
  if not (S and g and type(S.drawOrder) == "function") then return false end
  local okO, order = pcall(S.drawOrder)
  if not (okO and type(order) == "table") then return false end
  local wideAt
  for i = #order, 1, -1 do
    local m = order[i].mod
    if type(m) == "table" and rawget(m, "__g3State") and drawsWide(m) then
      wideAt = i
      break
    end
  end
  if not wideAt then return false end
  local state = order[wideAt].mod
  local w = tonumber(viewport.width) or W
  local h = tonumber(viewport.height) or H
  local okW, errW = pcall(state.drawWidescreen, state, w, h)
  if not okW then
    warnOnce("wide:" .. tostring(state), "a widescreen battle screen failed to draw "
      .. "(%s) -- report this with the line above", tostring(errW))
  end
  if wideAt < #order then
    local sx = (tonumber(viewport.gameWidth) or (W * (tonumber(viewport.scale) or 1))) / W
    local sy = (tonumber(viewport.gameHeight) or (H * (tonumber(viewport.scale) or 1))) / H
    g.push()
    g.translate(tonumber(viewport.gameX) or 0, tonumber(viewport.gameY) or 0)
    g.scale(sx, sy)
    for i = wideAt + 1, #order do
      local m = order[i].mod
      if type(m) == "table" and type(m.draw) == "function" then pcall(m.draw) end
    end
    g.pop()
  end
  return true
end

-- ------- widgets: shared pieces

local function closeSelf(self)
  return M.pop(self.game, self)
end

-- A class whose `cursor` reads its `index`: Ui.lua (and the Gen 1 code it
-- shares with Gold) writes `menu.index`; the driver contract reads `cursor`.
local function class(methods)
  methods.__index = function(t, k)
    if k == "cursor" then return rawget(t, "index") end
    return methods[k]
  end
  return methods
end

local function pressed(input, btn)
  return type(input) == "table" and type(input.wasPressed) == "function"
    and input:wasPressed(btn) == true
end

local function held(input, btn)
  return type(input) == "table" and type(input.isDown) == "function"
    and input:isDown(btn) == true
end

-- ------- Menu: the START-submenu command box
--
-- The FRLG start menu's shape (start_menu.lua): a std frame against the right
-- edge, rows 15px apart, "▶" in an 8px column, labels after it.  Sized to its
-- widest label, and capped at maxVisible rows with the list_menu arrows when
-- there are more.  Gen 1's tx / ty place a box on a 20x18 grid that does not
-- exist here, so they are read for intent only: a box Gen 1 puts low and to
-- the right (tx >= 11 -- ACTIONS, SERVERACT, the CHOOSE rows, all "clear of
-- the characters this is about") sits against the bottom; the others hang
-- from the top, where START does.  opts.anchor3 ("top" | "bottom") overrides.

local Menu = class({})
M.Menu = Menu

local MENU_PITCH = 15
local MENU_MAX_ROWS = 9      -- 9 x 15px = 135px: rows 1..18 of a 20-row screen

function Menu.new(game, items, opts)
  opts = opts or {}
  local self = setmetatable({}, Menu)
  self.game = game
  self.items = type(items) == "table" and items or {}
  self.index = 1
  self.scroll = 0
  self.kind = "menu"
  self.maxVisible = math.min(tonumber(opts.maxVisible) or MENU_MAX_ROWS, MENU_MAX_ROWS)
  self.cancelable = opts.cancelable ~= false
  self.keepOnCancel = opts.keepOnCancel or false
  self.noWrap = opts.noWrap or false
  self.startCloses = opts.startCloses or false
  self.onCancel = opts.onCancel
  self.noSound = opts.noSound or false
  self.anchor3 = opts.anchor3 or (((tonumber(opts.tx) or 0) >= 11) and "bottom" or "top")
  self.minW = tonumber(opts.minW3) or 6
  self:clampScroll()
  return self
end

function Menu:visibleCount()
  return math.min(self.maxVisible, #self.items)
end

function Menu:clampScroll()
  local vis = self:visibleCount()
  if #self.items <= vis then
    self.scroll = 0
    return
  end
  if self.index - self.scroll > vis then
    self.scroll = self.index - vis
  elseif self.index - self.scroll < 1 then
    self.scroll = self.index - 1
  end
end

-- Content rect in tiles: { left, top, w, h }.
function Menu:geometry()
  local widest = 0
  for _, item in ipairs(self.items) do
    local w = Font.width(item.prefix or "") + Font.width(item.label or "")
    if w > widest then widest = w end
  end
  local w = math.max(self.minW, math.ceil((8 + widest + 6) / TILE))
  w = math.min(w, 28)
  local h = math.max(2, math.ceil((self:visibleCount() * MENU_PITCH) / TILE))
  local left = 29 - w
  local top = self.anchor3 == "bottom" and (19 - h) or 1
  return { left = left, top = top, w = w, h = h }
end

function Menu:update() end

function Menu:handleInput(input)
  if M.stamped(self, input) or self.frozen then return end
  local n = #self.items
  if n == 0 then
    if pressed(input, "a") or pressed(input, "b") then
      closeSelf(self)
      if self.onCancel then self.onCancel() end
    end
    return
  end
  if pressed(input, "up") then
    local before = self.index
    self.index = self.index > 1 and self.index - 1 or (self.noWrap and 1 or n)
    if self.index ~= before and not self.noSound then sfx() end
  elseif pressed(input, "down") then
    local before = self.index
    self.index = self.index < n and self.index + 1 or (self.noWrap and n or 1)
    if self.index ~= before and not self.noSound then sfx() end
  elseif pressed(input, "a") then
    if not self.noSound then sfx() end
    local item = self.items[self.index]
    if not item then return end
    if not item.keepOpen then closeSelf(self) end
    if item.onSelect then item.onSelect() end
  elseif self.cancelable and (pressed(input, "b")
      or (self.startCloses and pressed(input, "start"))) then
    if pressed(input, "b") and not self.noSound then sfx() end
    if not self.keepOnCancel then closeSelf(self) end
    if self.onCancel then self.onCancel() end
  end
  self:clampScroll()
end

function Menu:draw()
  self:clampScroll()
  local geo = self:geometry()
  M.frame(geo.left, geo.top, geo.w, geo.h)
  local leftPx, topPx = geo.left * TILE, geo.top * TILE
  local vis = self:visibleCount()
  for row = 1, vis do
    local item = self.items[self.scroll + row]
    if not item then break end
    local y = topPx + (row - 1) * MENU_PITCH
    local x = leftPx + 8
    if item.prefix then x = x + Font.draw(item.prefix, x, y) end
    Font.draw(item.label or "", x, y, {
      color = (item.muted or item.blocked) and "MUTED" or "NORMAL",
      maxWidth = geo.w * TILE - (x - leftPx),
    })
  end
  local cursorRow = self.index - self.scroll
  if cursorRow >= 1 and cursorRow <= vis then
    M.cursor(leftPx, topPx + (cursorRow - 1) * MENU_PITCH)
  end
  if #self.items > vis then
    M.scrollArrows(geo.left, geo.top, geo.w, geo.h, self.scroll > 0,
      self.scroll + vis < #self.items)
  end
end

-- ------- ListMenu: the full-screen list (PLAYERS, SERVERS, CHAT, ...)
--
-- A title window across the top and the list window under it, the way the
-- cart's bag and PC lists are framed.  Rows are 16px (seven on screen, as on
-- Gen 1), the label after an 8px cursor column, `right` right-aligned against
-- the frame, and a label that would run into its right column cut on a whole
-- glyph.  opts.rowH / opts.listW (content tiles) / opts.panel(menu) /
-- opts.decorate(item, x, y, selected, menu) / opts.indent let a screen give a
-- row a picture or the window a side panel (CHARACTER, TRADE WHICH?).
-- opts.caption(menu) -> text[, colour] puts a line of its own in the title
-- window in place of the title while it answers one -- the prompt line the
-- cart's own pickers use to say why a row cannot be chosen; `title` itself
-- (what a driver reads) never changes.

local ListMenu = class({})
M.ListMenu = ListMenu

ListMenu.isOpaque = true

-- geometry, exported so a screen that sizes a right-hand column can ask
M.LIST = {
  left = 1, top = 5, w = 28, h = 14,     -- content tiles
  titleLeft = 1, titleTop = 1, titleW = 28, titleH = 2,
  rowH = 16, cursorDX = 2, labelDX = 10, rightPad = 4, gap = 6,
}

local REPEAT_DELAY, REPEAT_RATE = 16, 4

function ListMenu.new(game, title, items, opts)
  opts = opts or {}
  local L = M.LIST
  local self = setmetatable({}, ListMenu)
  self.game = game
  self.title = title
  self.kind = "list"
  self.items = type(items) == "table" and items or {}
  self.index = 1
  self.scroll = 0
  self.onChoose = opts.onChoose
  self.onCancel = opts.onCancel
  self.pageJump = opts.pageJump
  self.wrap = opts.wrap
  self.keyRepeat = opts.keyRepeat ~= false
  self.onSelectKey = opts.onSelectKey
  self.noSound = opts.noSound or false
  self.rowH = tonumber(opts.rowH) or L.rowH
  self.listW = tonumber(opts.listW) or L.w
  self.indent = tonumber(opts.indent) or 0
  self.panel = opts.panel
  self.decorate = opts.decorate
  self.caption = opts.caption
  self.rows = tonumber(opts.rows) or math.floor((L.h * TILE) / self.rowH)
  self.holdDir, self.holdFrames = nil, 0
  self.anim = 0
  return self
end

-- Where a row's label starts and where its right column ends, in px.
function ListMenu:columns()
  local L = M.LIST
  local left = L.left * TILE
  return left + L.labelDX + self.indent, (L.left + self.listW) * TILE - L.rightPad
end

-- How many px a right-hand column has beside `label` (with its prefix).
function M.rightRoom(label, prefix, menu)
  local labelX, rightX
  if menu then
    labelX, rightX = menu:columns()
  else
    local L = M.LIST
    labelX = L.left * TILE + L.labelDX
    rightX = (L.left + L.w) * TILE - L.rightPad
  end
  local used = Font.width(prefix or "") + Font.width(label or "")
  return math.max(0, rightX - labelX - used - M.LIST.gap)
end

local function moveIndex(self, delta)
  local n = #self.items
  if n == 0 then return false end
  local nextIndex = self.index + delta
  if self.wrap then
    nextIndex = ((nextIndex - 1) % n) + 1
  else
    nextIndex = math.max(1, math.min(n, nextIndex))
  end
  local moved = nextIndex ~= self.index
  self.index = nextIndex
  return moved
end

function ListMenu:syncScroll()
  local n = #self.items
  if self.index > n then self.index = math.max(1, n) end
  if self.index < 1 then self.index = 1 end
  if self.index - self.scroll > self.rows then self.scroll = self.index - self.rows end
  if self.index - self.scroll < 1 then self.scroll = self.index - 1 end
  local maxScroll = math.max(0, n - self.rows)
  if self.scroll > maxScroll then self.scroll = maxScroll end
  if self.scroll < 0 then self.scroll = 0 end
end

local DIRS = { up = -1, down = 1 }
local PAGE_DIRS = { left = -1, right = 1 }

function ListMenu:update(dt)
  self.anim = (self.anim or 0) + 1
end

function ListMenu:handleInput(input)
  if M.stamped(self, input) then return end
  if #self.items == 0 then
    if pressed(input, "a") or pressed(input, "b") then
      if not self.noSound then sfx() end
      closeSelf(self)
      if self.onCancel then self.onCancel() end
    end
    return
  end
  local delta
  for dir, d in pairs(DIRS) do
    if pressed(input, dir) then delta = d; self.holdDir, self.holdFrames = dir, 0 end
  end
  if self.pageJump then
    for dir, d in pairs(PAGE_DIRS) do
      if pressed(input, dir) then delta = d * self.rows; self.holdDir, self.holdFrames = dir, 0 end
    end
  end
  if not delta and self.keyRepeat and self.holdDir and held(input, self.holdDir) then
    self.holdFrames = self.holdFrames + 1
    if self.holdFrames >= REPEAT_DELAY and (self.holdFrames - REPEAT_DELAY) % REPEAT_RATE == 0 then
      local d = DIRS[self.holdDir] or (self.pageJump and PAGE_DIRS[self.holdDir] and PAGE_DIRS[self.holdDir] * self.rows)
      delta = d
    end
  elseif not delta then
    self.holdDir = nil
  end
  if delta then
    if moveIndex(self, delta) and not self.noSound then sfx() end
    self:syncScroll()
    return
  end
  if self.onSelectKey and pressed(input, "select") then
    self.onSelectKey(self.items[self.index], self)
  elseif pressed(input, "b") then
    if not self.noSound then sfx() end
    closeSelf(self)
    if self.onCancel then self.onCancel() end
  elseif pressed(input, "a") then
    if not self.noSound then sfx() end
    local item = self.items[self.index]
    if self.onChoose then self.onChoose(item, self) end
  end
end

-- remove current item (e.g. consumed); keeps cursor valid
function ListMenu:removeCurrent()
  table.remove(self.items, self.index)
  self.index = math.max(1, math.min(self.index, #self.items))
end

-- Gen 1's ListMenu:close: down only if it is still the top.
function ListMenu:close()
  if M.top() == self then closeSelf(self) end
end

function ListMenu:draw()
  local L = M.LIST
  self:syncScroll()
  M.frame(L.titleLeft, L.titleTop, L.titleW, L.titleH)
  local caption, captionColor
  if self.caption then
    local ok, text, color = pcall(self.caption, self)
    if ok and type(text) == "string" and text ~= "" then caption, captionColor = text, color end
  end
  if caption then
    Font.draw(Font.fit(caption, L.titleW * TILE - 8), L.titleLeft * TILE + 4,
      L.titleTop * TILE + 1, { color = captionColor or "NORMAL" })
  else
    Font.draw(tostring(self.title or ""), L.titleLeft * TILE + 4, L.titleTop * TILE + 1)
    if type(self.titleRight) == "string" then
      Font.drawRight(self.titleRight, (L.titleLeft + L.titleW) * TILE - 4, L.titleTop * TILE + 1)
    end
  end
  M.frame(L.left, L.top, self.listW, L.h)
  local topPx = L.top * TILE
  local labelX, rightX = self:columns()
  if #self.items == 0 then
    Font.draw("Nothing here.", labelX, topPx + 17)
  end
  local pad = math.max(0, math.floor((self.rowH - Font.HEIGHT) / 2))
  for row = 1, self.rows do
    local i = self.scroll + row
    local item = self.items[i]
    if not item then break end
    local y = topPx + (row - 1) * self.rowH + pad
    local x = labelX
    if item.prefix then x = x + Font.draw(item.prefix, x, y) end
    local budget = rightX - x
    if item.right then budget = budget - Font.width(item.right) - L.gap end
    local color = (item.muted or item.blocked) and "MUTED" or "NORMAL"
    Font.draw(Font.fit(item.label or "", math.max(0, budget)), x, y, { color = color })
    if item.right then Font.drawRight(item.right, rightX, y, { color = color }) end
    if self.decorate then pcall(self.decorate, item, labelX, y, i == self.index, self) end
    if i == self.index then M.cursor(L.left * TILE + L.cursorDX, y) end
  end
  if #self.items > self.rows then
    M.scrollArrows(L.left, L.top, self.listW, L.h, self.scroll > 0,
      self.scroll + self.rows < #self.items)
  end
  if self.panel then
    local ok, err = pcall(self.panel, self)
    if not ok then warnOnce("panel:" .. tostring(self.title), "a Gen 3 list panel "
      .. "failed to draw (%s) -- report this with the line above", tostring(err)) end
  end
end

-- ------- TextBox: the cart's dialogue window
--
-- The field message window (Chrome.dialogueFrame), two lines a page, the
-- typewriter at the player's own text speed, the bouncing prompt arrow, A/B to
-- finish a page / turn it / close.  The mod's sentences are written with line
-- breaks for an 18-column Game Boy box; the GBA window is 208px, so the lines
-- of a paragraph are rejoined and re-wrapped to it (a blank line, or \f,
-- still starts a new page) -- the text reads the way the cart's own does
-- instead of in short Game Boy lines with half a window of air beside them.
--
-- opts.choice(yes) opens the cart's YES / NO box over the still-visible text
-- once the last page has printed (B answers NO), in place of onDone;
-- opts.defaultNo puts the cursor on NO.

local TextBox = class({})
M.TextBox = TextBox

local SPEED_DELAYS = { 8, 4, 1 }

function M.paginate(text, maxW)
  maxW = tonumber(maxW) or 208
  local s = tostring(text or ""):gsub("\r", ""):gsub("\f", "\n\n")
  local pages = {}
  for para in (s .. "\n\n"):gmatch("(.-)\n\n+") do
    local flat = para:gsub("\n", " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    if flat ~= "" then
      local lines = Font.wrap(flat, maxW)
      for i = 1, #lines, 2 do
        pages[#pages + 1] = { lines[i], lines[i + 1] }
      end
    end
  end
  if #pages == 0 then pages[1] = { "" } end
  return pages
end

local function pageChars(page)
  local n = 0
  for _, line in ipairs(page) do n = n + #utf8Chars(line) end
  return n + math.max(0, #page - 1)
end

function TextBox.new(game, text, onDone, opts)
  opts = opts or {}
  local self = setmetatable({}, TextBox)
  self.game = game
  self.kind = "text"
  self.text = tostring(text or "")
  self.onDone = onDone
  self.choice = opts.choice
  self.defaultNo = opts.defaultNo == true
  local _, _, dw = M.dialogueWindow()
  self.pages = M.paginate(self.text, (tonumber(dw) or 26) * TILE)
  self.page = 1
  self.revealed = 0
  self.delay = 0
  self.acc = 0
  self.arrowTicks = 0
  self.waiting = false
  self.choosing = false
  self.speed = textSpeed()
  self:beginPage()
  return self
end

function TextBox:beginPage()
  self.total = pageChars(self.pages[self.page] or {})
  self.revealed = 0
  self.delay = 0
  self.waiting = self.total == 0
  self.arrowTicks = 0
  if self.waiting then self:onPageDone() end
end

function TextBox:onPageDone()
  if self.page >= #self.pages and self.choice and not self.choosing then
    self.choosing = true
    self.index = self.defaultNo and 2 or 1
    self.items = {
      { label = romText("gText_Yes", "YES"), value = true },
      { label = romText("gText_No", "NO"), value = false },
    }
  end
end

function TextBox:skip()
  self.revealed = self.total
  self.waiting = true
  self:onPageDone()
end

function TextBox:tick()
  if self.waiting then
    self.arrowTicks = self.arrowTicks + 1
    return
  end
  if self.speedUp then self.delay = 0 end
  if self.delay > 0 then
    self.delay = self.delay - 1
    return
  end
  self.revealed = self.revealed + 1
  if self.revealed >= self.total then
    self:skip()
    return
  end
  local d = (SPEED_DELAYS[(self.speed or 1) + 1] or 4) - 1
  self.delay = self.speedUp and 0 or math.max(0, d)
end

function TextBox:update(dt)
  self.acc = math.min((self.acc or 0) + (tonumber(dt) or (1 / 60)), 8 / 60)
  while self.acc >= 1 / 60 - 1e-9 do
    self.acc = self.acc - 1 / 60
    self:tick()
  end
end

function TextBox:answer(yes)
  self.choosing = false
  closeSelf(self)
  if self.choice then self.choice(yes and true or false) end
end

function TextBox:handleInput(input)
  if M.stamped(self, input) then return end
  if self.choosing then
    if pressed(input, "up") or pressed(input, "down") then
      self.index = self.index == 1 and 2 or 1
      sfx()
    elseif pressed(input, "a") then
      sfx()
      self:answer(self.index == 1)
    elseif pressed(input, "b") then
      sfx()
      self:answer(false)
    end
    return
  end
  self.speedUp = held(input, "a") or held(input, "b")
  if not (pressed(input, "a") or pressed(input, "b")) then return end
  if not self.waiting then
    self:skip()
    return
  end
  if self.page < #self.pages then
    self.page = self.page + 1
    self:beginPage()
    return
  end
  if self.choice then return end
  sfx()
  closeSelf(self)
  if self.onDone then self.onDone() end
end

function TextBox:draw()
  M.dialogueFrame()
  local l, t, w = M.dialogueWindow()
  local baseX, baseY, maxW = l * TILE, t * TILE + 1, w * TILE
  local page = self.pages[self.page] or {}
  local F = Glyphs()
  local endX, endY = baseX, baseY
  local left = self.revealed
  for i, line in ipairs(page) do
    local chars = utf8Chars(line)
    local n = math.min(#chars, left)
    local shown = n > 0 and line:sub(1, chars[n].to) or ""
    local y = baseY + (i - 1) * 16
    if shown ~= "" then Font.draw(shown, baseX, y, { maxWidth = maxW }) end
    endX, endY = baseX + Font.width(shown), y
    left = left - n - 1
    if left < 0 then break end
  end
  if self.waiting and not self.choosing and F then
    local C = Chrome()
    if C and type(C.promptArrow) == "function" then
      local frame = ({ 0, 1, 2, 3, 2, 1 })[1 + (math.floor(self.arrowTicks / 8) % 6)] or 0
      local ax = math.min(endX + 2, baseX + maxW - 10)
      pcall(C.promptArrow, ax, endY, frame)
    end
  end
  if self.choosing and self.items then
    -- pokefirered/src/menu.c:531 via choice.lua: template (21, 9, 6, 4)
    local L, Tp = 21, 9
    M.frame(L, Tp, 6, 4)
    for i, item in ipairs(self.items) do
      local rowPx = Tp * TILE + 2 + (i - 1) * 14
      if i == self.index then M.cursor(L * TILE, rowPx) end
      Font.draw(item.label, L * TILE + 8, rowPx)
    end
  end
end

-- ------- NamingScreen: the letter grid
--
-- The cart's own grid (src/ui/game3/naming.lua) is not what this mod's text
-- entry needs, for three reasons found reading it: its OTHERS page has the
-- digits but no ":" (so "192.168.1.20:7788" cannot be typed), its typed line
-- is `maxLen` 8px slots centred on the screen (an address is 32, which starts
-- the line off the left edge), and its B is only ever a backspace on a
-- module-level singleton that pops itself -- no way out of a screen opened
-- without the answer to hand.  So this is a mod-drawn grid in the cart's
-- chrome with the Gen 1 widget's contract: `glyphs` typed so far, `maxLen`,
-- `row` / `col`, `lower` (the second page), `grid()`, `confirm()` (pops, then
-- onDone(name, true); an empty line answers `default` or ""), A types / runs a
-- cell, B erases, START confirms, SELECT flips the page.  The pages are the
-- caller's (Ui.lua hands it the same LETTERS / DIGITS grids the Gen 1 hook
-- swaps in), each a list of rows, one row holding a single page-flip cell
-- ("123" / "ABC") and one cell "ED" (drawn OK, as the cart labels it).
-- `hint(self)` is what the banner says about B.

local NamingScreen = class({})
M.NamingScreen = NamingScreen
NamingScreen.isOpaque = true

M.NAMING_PAGES = {
  {
    { "A", "B", "C", "D", "E", "F", "G", "H", "I" },
    { "J", "K", "L", "M", "N", "O", "P", "Q", "R" },
    { "S", "T", "U", "V", "W", "X", "Y", "Z", " " },
    { "-", "?", "!", ",", ".", ":", ";", "/", "ED" },
    { "123" },
  },
  {
    { "1", "2", "3", "4", "5", "6", "7", "8", "9" },
    { "0", ".", ":", "-", "/", "(", ")", ";", "," },
    { "?", "!", " ", "ED" },
    { "ABC" },
  },
}

local FLIP_CELLS = { ["123"] = true, ["ABC"] = true, ["lower"] = true, ["UPPER"] = true,
  ["lower case"] = true, ["UPPER CASE"] = true }

-- The typed line: as many 8px slots as fit between the margins, centred, and
-- -- once the text is longer than that -- its *last* characters, because the
-- ones just typed are the ones being checked (Ui.fieldLayout's rule, at the
-- GBA's width).  Pure: -> x of the first slot, the cells, the caret slot.
M.FIELD_SLOTS = math.floor((W - 32) / 8)

function M.fieldLayout(maxLen, glyphs)
  maxLen = math.max(tonumber(maxLen) or 0, 0)
  glyphs = type(glyphs) == "table" and glyphs or {}
  local slots = math.min(maxLen, M.FIELD_SLOTS)
  local skip = math.max(#glyphs - slots, 0)
  local cells = {}
  for i = 1, slots do cells[i] = glyphs[skip + i] or false end
  local caret = math.min(#glyphs - skip + 1, slots)
  return math.floor((W - slots * 8) / 2), cells, caret
end

local function findMeta(grid)
  local caseRow, edRow, edCol = #grid, #grid - 1, 1
  for r, row in ipairs(grid) do
    if #row == 1 and FLIP_CELLS[row[1]] then caseRow = r end
    for c, cell in ipairs(row) do
      if cell == "ED" then edRow, edCol = r, c end
    end
  end
  return caseRow, edRow, edCol
end

function NamingScreen.new(game, opts)
  opts = opts or {}
  local self = setmetatable({}, NamingScreen)
  self.game = game
  self.kind = "naming"
  self.title = opts.title or "NAME?"
  self.maxLen = tonumber(opts.maxLen) or 7
  self.default = opts.default
  self.onDone = opts.onDone
  self.pages = type(opts.pages) == "table" and opts.pages or M.NAMING_PAGES
  self.glyphs = {}
  self.row, self.col = 1, 1
  self.lower = false
  self.blink = 0
  return self
end

function NamingScreen:grid()
  return self.pages[self.lower and 2 or 1] or self.pages[1]
end

function NamingScreen:jumpToEnd()
  local _, edRow, edCol = findMeta(self:grid())
  self.row, self.col = edRow, edCol
end

function NamingScreen:flip()
  self.lower = not self.lower
  local grid = self:grid()
  if self.row > #grid then self.row = #grid end
  self.col = math.min(self.col, #grid[self.row])
  sfx()
end

function NamingScreen:confirm()
  local name = table.concat(self.glyphs)
  if name == "" then name = self.default or "" end
  sfx()
  closeSelf(self)
  if self.onDone then self.onDone(name, true) end
end

function NamingScreen:update(dt)
  self.blink = (self.blink or 0) + (tonumber(dt) or (1 / 60))
end

function NamingScreen:handleInput(input)
  if M.stamped(self, input) then return end
  local grid = self:grid()
  local caseRow, edRow, edCol = findMeta(grid)
  if pressed(input, "start") then
    self:confirm()
    return
  end
  if pressed(input, "select") then
    self:flip()
    return
  end
  if pressed(input, "up") then
    self.row = self.row > 1 and self.row - 1 or caseRow
    self.col = math.min(self.col, #grid[self.row])
  elseif pressed(input, "down") then
    self.row = self.row < #grid and self.row + 1 or 1
    self.col = math.min(self.col, #grid[self.row])
  elseif pressed(input, "left") then
    if self.row ~= caseRow then
      self.col = self.col > 1 and self.col - 1 or #grid[self.row]
    end
  elseif pressed(input, "right") then
    if self.row ~= caseRow then
      self.col = self.col < #grid[self.row] and self.col + 1 or 1
    end
  else
    local a, b = pressed(input, "a"), pressed(input, "b")
    if a and b then b = false end
    if b then
      if #self.glyphs > 0 then sfx() end
      table.remove(self.glyphs)
    elseif a then
      if self.row == edRow and self.col == edCol then
        self:confirm()
        return
      end
      if self.row == caseRow then
        self:flip()
        return
      end
      if #self.glyphs < self.maxLen then
        sfx()
        table.insert(self.glyphs, grid[self.row][self.col])
        if #self.glyphs >= self.maxLen then self:jumpToEnd() end
      end
    end
  end
end

-- Layout, px: the banner 0..16, the entry window content 24..40, the grid
-- window content 56..144 (five 16px rows of nine 24px cells).
local NAMING = { gridTop = 58, rowH = 16, cellW = 24, gridLeft = 12, entryY = 25 }
M.NAMING_LAYOUT = NAMING

function NamingScreen:hint()
  return #self.glyphs > 0 and "B ERASES" or ""
end

function NamingScreen:draw()
  local g = gfx()
  if not g then return end
  -- banner: pret PrintControls' WIN_BANNER blue (naming.lua bannerR/G/B)
  g.setColor(1, 1, 1, 1)
  g.rectangle("fill", 0, 0, W, H)
  g.setColor(0, 123 / 255, 197 / 255, 1)
  g.rectangle("fill", 0, 0, W, 16)
  Font.draw(tostring(self.title or ""), 8, 1, { color = "WHITE", maxWidth = 120 })
  local hint = type(self.hint) == "function" and self:hint() or nil
  if type(hint) == "string" and hint ~= "" then
    Font.drawRight(hint, W - 8, 1, { color = "WHITE" })
  end

  -- the typed line
  M.frame(1, 3, 28, 2)
  local x0, cells, caret = M.fieldLayout(self.maxLen, self.glyphs)
  local dark = palette(2) or { 0.38, 0.38, 0.38, 1 }
  for i, ch in ipairs(cells) do
    local x = x0 + (i - 1) * 8
    if ch then
      local w = Font.width(ch)
      Font.draw(ch, x + math.floor((8 - w) / 2), NAMING.entryY)
    end
    local bob = 0
    if i == caret and #self.glyphs < self.maxLen then
      bob = ({ 0, 1, 0, -1 })[1 + (math.floor(self.blink * 8) % 4)] or 0
    end
    g.setColor(dark[1], dark[2], dark[3], 1)
    g.rectangle("fill", x + 1, 38 + bob, 6, 1)
  end
  g.setColor(1, 1, 1, 1)

  -- the grid
  M.frame(1, 7, 28, 11)
  local grid = self:grid()
  local light = palette(9) or { 164 / 255, 197 / 255, 246 / 255, 1 }
  for r, row in ipairs(grid) do
    local y = NAMING.gridTop + (r - 1) * NAMING.rowH
    for c, cell in ipairs(row) do
      local x = NAMING.gridLeft + (c - 1) * NAMING.cellW
      local label = cell == "ED" and "OK" or cell
      local cw = (#row == 1) and (NAMING.cellW * 2) or NAMING.cellW
      if r == self.row and c == self.col then
        g.setColor(light[1], light[2], light[3], 1)
        g.rectangle("fill", x + 1, y - 1, cw - 2, NAMING.rowH)
        g.setColor(1, 1, 1, 1)
      end
      Font.drawCentered(label, x + cw / 2, y, { color = (cell == "ED" or #row == 1) and "BLUE" or "NORMAL" })
    end
  end
end

return M
