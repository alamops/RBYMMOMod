-- Toasts: the short-lived lines stacked in the corner of the screen.
--
-- Chat, arrivals and departures, and what your party member just fought are
-- all things that happen while the player is doing something else, so none
-- of them may take the screen.  A toast is the whole answer to that: it
-- appears without being asked for, it is readable from wherever the player
-- already is, and it goes away on its own.
--
-- Drawn in *window* space rather than the game's 160x144, which is the one
-- way this differs from src/Overlay.lua.  A nameplate belongs to a character
-- standing on a tile, so it has to live in the same coordinates that
-- character does; a toast belongs to nobody on the map.  Window space also
-- lets the face stay small and antialiased at any window size -- Rajdhani
-- has the lowercase and punctuation the ROM font does not, and it is meant
-- to be read at ~12px with a linear filter, not scaled up with the letterbox.
--
-- The queue is deliberately separable from the drawing: push/update/clear is
-- plain arithmetic on a list and is pinned by the headless suite, where
-- there is no love at all, and draw() is a no-op without a graphics context
-- rather than a crash.

local need, mod = ...
local Config = need("Config")
-- Only for a Gen 3 boot's draw (see "Gen 3" below): the adapter answers
-- false / nil everywhere else, and is the one place a src.ui.game3.* module
-- is reached from.
local Gen3 = need("Gen3")
-- The cart's charset (Gen3Ui.printable), so a toast and a screen print the
-- same line the same way.  Pure string work: nothing of the engine's is
-- touched by asking it, on any generation.
local Gen3Ui = need("Gen3Ui")

local M = {}
M.__index = M

-- Game Boy geometry, for the case where the viewport arrives without a
-- usable scale (another mod owning the world pass -- see Overlay's draw).
local VIEW_W, VIEW_H = 160, 144

-- Layout in *window* pixels.  Kept small on purpose: a toast is a glance,
-- not a second HUD, and growing with the letterbox scale made the old
-- pixel face dominate the corner on any window larger than 1x.
local PAD = 3                       -- plate margin around the text
local INSET = 6                     -- gap between the plate and the corner
local ROW_GAP = 2                   -- air between stacked rows

-- What a line is drawn in when it did not ask for anything else.  A table
-- rather than three arguments so the "did this entry name a colour" test below
-- is one field read on the hot path.
local WHITE = { 1, 1, 1 }

function M.new(ctx)
  return setmetatable({ ctx = ctx, queue = {}, rev = 0 }, M)
end

-- ------- the queue

-- Oldest first, which is the order they are drawn and the order they
-- expire.  An overflowing stack drops from the front: the line the player
-- has not read yet is the newest one, so it is the oldest that can go.
--
-- `color` is optional and almost always absent.  White is what a notification
-- is; a colour is reserved for the one class of line that is *about somebody
-- the player chose* -- a friend arriving, drawn in the same blue their
-- nameplate is (Config.FRIEND_BLUE) -- so the corner keeps meaning one thing
-- and the exception keeps meaning something.  A caller passing nothing gets
-- exactly the toast it always got.
function M:push(text, color)
  if type(text) ~= "string" or text == "" then return nil end
  local entry = { text = text, age = 0, color = color }
  self.queue[#self.queue + 1] = entry
  while #self.queue > Config.TOAST_MAX do table.remove(self.queue, 1) end
  -- the Gen 3 corner's row memo is keyed on this (see rows3)
  self.rev = (self.rev or 0) + 1
  return entry
end

function M:update(dt)
  -- On Gen 3 the clock stops while the corner waits for the field to come
  -- back (M.gen3Held): a line held behind a menu still gets its full five
  -- seconds once it can be read, rather than running out unseen.  The
  -- queue is looked at first so the idle tick asks the engine nothing.
  if #self.queue > 0 and M.gen3Held() then return end
  dt = tonumber(dt) or 0
  local index = 1
  while index <= #self.queue do
    local entry = self.queue[index]
    entry.age = entry.age + dt
    if entry.age >= Config.TOAST_SECONDS then
      table.remove(self.queue, index)
      self.rev = (self.rev or 0) + 1
    else
      index = index + 1
    end
  end
end

function M:clear()
  self.queue = {}
  self.rev = (self.rev or 0) + 1
end

-- A copy, not the live list: this is what mod.exports hands a driver, and a
-- driver holding the queue itself could age or empty it by accident.
function M:list()
  local out = {}
  for index, entry in ipairs(self.queue) do
    out[index] = { text = entry.text, age = entry.age, color = entry.color }
  end
  return out
end

-- What the last draw decided, so a driver can ask why nothing appeared
-- instead of inferring it from a screenshot -- the same seam Overlay:state
-- exists for.
function M:state()
  return {
    count = #self.queue,
    lines = self:list(),
    last = self.last or { reached = "never" },
  }
end

-- ------- the sentences
--
-- Every line a toast ever shows is built here, and that is deliberate: the
-- wire carries *what happened* -- a kind, a species, a level -- and never the
-- prose for it.  Prose on the wire would have to be written twice, once in
-- each hub (server/lib/relay.js and src/Hub.lua), and the two would drift;
-- worse, it would be a stranger's process choosing the words that appear on
-- this player's screen.  So the hub relays fields and this file decides how
-- they read.
--
-- Every one of these answers nil rather than a half-built sentence, and
-- push() ignores a nil, so a caller can hand a formatter straight to it
-- without a branch in between.

-- What somebody said, as it appears in the corner.
--
-- No scope tag, unlike the chat screen's own line (Chat:line).  The
-- scrollback is a log being read deliberately, where "was that whispered or
-- global" is worth a column of its own; a toast is read in passing, and the
-- only two questions it has room to answer are who spoke and what they said.
function M.chatLine(name, text)
  if type(name) ~= "string" or type(text) ~= "string" then return nil end
  return ("[%s]: %s"):format(name, text)
end

-- Arrivals and departures.  Everyone on the hub sees these, which is what
-- makes "the server" the right word for where somebody went: it is the whole
-- population being told, not the map.
function M.joinLine(name)
  if type(name) ~= "string" then return nil end
  return ("%s joined the server"):format(name)
end

function M.partLine(name)
  if type(name) ~= "string" then return nil end
  return ("%s left the server"):format(name)
end

-- Self-connect status.  Constant because the player already knows who they
-- are; unlike joinLine there is no name to fill in, only the fact of being
-- on the hub.
function M.connectedLine()
  return "You're connected"
end

-- The colour an arrival is drawn in.
--
-- The same sentence either way -- a friend arriving is still somebody joining
-- the server, and rewording it would make the two look like different events
-- -- and the only difference is the blue.  That is the whole design: on a busy
-- hub the corner is a stream of names, and the one thing a player wants out of
-- it at a glance is "was that anybody I know".  A second sentence would have
-- to be read; a colour does not.
--
-- nil for everybody else, which push() reads as "the ordinary white", so the
-- caller needs no branch of its own.
function M.joinColor(isFriend)
  if isFriend then return Config.FRIEND_BLUE end
  return nil
end

-- One party event as a sentence.
--
-- Split the way Wire.PARTY_EVENTS splits it -- a kind either needs a species
-- and a level or it needs a trainer -- so that the two files disagree loudly
-- (an unknown kind draws nothing) rather than quietly (a sentence with a nil
-- in the middle of it).  A kind this build has never heard of has no
-- sentence to put it in, which is exactly why that set is closed.
local MON_LINE = {
  defeat_wild      = "%s defeated %s lv %d",
  defeated_by_wild = "%s was defeated by %s lv %d",
  capture          = "%s captured %s lv %d",
}

local TRAINER_LINE = {
  defeat_trainer      = "%s defeated %s",
  defeated_by_trainer = "%s was defeated by %s",
}

function M.partyLine(event)
  if type(event) ~= "table" then return nil end
  local name = event.name
  if type(name) ~= "string" then return nil end

  local mon = MON_LINE[event.kind]
  if mon then
    if not (event.species and event.level) then return nil end
    return mon:format(name, event.species, event.level)
  end

  local trainer = TRAINER_LINE[event.kind]
  if not (trainer and event.trainer) then return nil end
  return trainer:format(name, event.trainer)
end

-- ------- drawing

-- One font per size, because the size follows the window: resizing the
-- window asks for a new one, and going back asks for the first again.
local fonts = {}
local warned = false

local function assetFont(size)
  local path
  local assets = mod and mod.assets
  if assets and assets.path then
    local ok, resolved = pcall(function() return assets:path(Config.TOAST_FONT) end)
    if ok and type(resolved) == "string" and resolved ~= "" then path = resolved end
  end
  if not path then return nil end
  local ok, font = pcall(love.graphics.newFont, path, size)
  if ok then return font end
  return nil
end

-- The bundled face, or LOVE's own if it cannot be loaded.  A missing font
-- costs the toasts their look, never the message: the fallback is drawn at
-- the same place with the same plate, only in a face nobody chose.
function M.font(size)
  local hit = fonts[size]
  if hit then return hit end
  if not (love and love.graphics and love.graphics.newFont) then return nil end

  local font = assetFont(size)
  if not font then
    if not warned then
      warned = true
      if mod and mod.log then
        mod.log:warn("could not load %s; notifications fall back to the "
          .. "engine's default font -- reinstall the mod folder so "
          .. "assets/fonts is present", tostring(Config.TOAST_FONT))
      end
    end
    local ok, made = pcall(love.graphics.newFont, size)
    if not ok then return nil end
    font = made
  end

  -- Linear: this is a smooth HUD face at a small size, not a pixel sheet.
  pcall(font.setFilter, font, "linear", "linear")
  fonts[size] = font
  return font
end

-- Point size for the toast face.  Anchored in window pixels so a 4x window
-- does not get four times the type -- that was the whole complaint about
-- the previous face.  A tiny bump above 2x keeps it readable on a big
-- monitor without ever looking like a banner.
local function toastSize(scale)
  local base = tonumber(Config.TOAST_SIZE) or 12
  scale = tonumber(scale) or 1
  if scale >= 4 then return base + 2 end
  if scale >= 3 then return base + 1 end
  return base
end

-- The longest prefix of `text` that fits, and whatever is left of it.
--
-- Measured with the font rather than counted, because this face is bundled
-- and the fallback is not: the two do not agree on how wide anything is, and
-- a column count that fits one overflows the other.  The walk steps whole
-- UTF-8 sequences so a break can never hand the renderer half a glyph --
-- names are sanitised, but the party marker upstream is already three bytes
-- and nothing here should be the thing that assumes otherwise.
local TAIL = "..."

local function split(font, text, maxWidth)
  local cut, index = 0, 1
  while index <= #text do
    local byte = text:byte(index)
    local size = 1
    if byte >= 0xF0 then size = 4
    elseif byte >= 0xE0 then size = 3
    elseif byte >= 0xC0 then size = 2 end
    local stop = index + size - 1
    if font:getWidth(text:sub(1, stop)) > maxWidth then break end
    cut, index = stop, stop + 1
  end
  return text:sub(1, cut), text:sub(cut + 1)
end

-- Cut a line to what the plate has room for, with an ellipsis to say so.
-- Only ever reached for the last row of an entry that wrapped past its cap.
local function fit(font, text, maxWidth)
  if maxWidth <= 0 then return "" end
  if font:getWidth(text) <= maxWidth then return text end
  local budget = maxWidth - font:getWidth(TAIL)
  if budget <= 0 then return "" end
  local head = split(font, text, budget)
  if head == "" then return "" end
  return head .. TAIL
end

-- How many rows one queue entry may grow to.
--
-- A wrapped entry is still one entry against Config.TOAST_MAX -- it has to
-- be, or a chatty friend would push an arrival off the stack twice as fast
-- as a quiet one -- so the bound on how much screen the stack can eat has to
-- live here instead.  Three rows times five entries is fifteen, which is the
-- most the corner will ever hold, and a sentence that needs a fourth is the
-- one case still worth an ellipsis.
local WRAP_MAX = 3

-- Break a line into rows the plate has room for, on word boundaries.
--
-- Wrapping rather than cutting is the whole point: a chat line or a capture
-- sentence is longer than a nameplate-width plate, and a sentence broken
-- between words is read at a glance where the same sentence cut mid-way is
-- not read at all.
--
-- A single word too long for a row of its own is broken mid-word, because a
-- name or a species with no space in it must not be the thing that decides
-- how wide the plate is.
local function wrap(font, text, maxWidth)
  if maxWidth <= 0 then return {} end

  local words = {}
  for word in text:gmatch("%S+") do words[#words + 1] = word end

  local rows, line, index = {}, "", 1
  while index <= #words do
    local word = words[index]
    local candidate = line == "" and word or (line .. " " .. word)
    if font:getWidth(candidate) <= maxWidth then
      line, index = candidate, index + 1
    elseif line ~= "" then
      rows[#rows + 1] = line
      line = ""
    else
      local head, tail = split(font, word, maxWidth)
      -- Not even one glyph fits: there is no row to put anything on, and
      -- looping would spin forever on a word that never shrinks.
      if head == "" then return rows end
      rows[#rows + 1] = head
      words[index] = tail
    end
  end
  if line ~= "" then rows[#rows + 1] = line end

  if #rows > WRAP_MAX then
    -- Everything past the cap is folded back onto the last row it fits on,
    -- so the ellipsis lands where the sentence actually stops rather than at
    -- a word boundary the reader cannot see.
    local overflow = fit(font, table.concat(rows, " ", WRAP_MAX, #rows), maxWidth)
    for n = #rows, WRAP_MAX, -1 do rows[n] = nil end
    if overflow ~= "" then rows[WRAP_MAX] = overflow end
  end
  return rows
end

-- The letterbox, or the window when the viewport does not describe one.
-- Same fallback as Overlay's draw and for the same reason: with another
-- mod's pipeline owning the frame, scale can arrive unusable, and bailing
-- there would mean the toasts silently never appeared.
local function geometry(viewport)
  local scale = viewport and tonumber(viewport.scale) or nil
  local x = viewport and tonumber(viewport.gameX) or 0
  local y = viewport and tonumber(viewport.gameY) or 0
  local width = viewport and tonumber(viewport.gameWidth) or nil
  local derived = false

  if not scale or scale <= 0 then
    local windowW, windowH = love.graphics.getDimensions()
    scale = math.max(1, math.floor(math.min(windowW / VIEW_W, windowH / VIEW_H)))
    x = math.floor((windowW - VIEW_W * scale) / 2)
    y = math.floor((windowH - VIEW_H * scale) / 2)
    width = VIEW_W * scale
    derived = true
  end
  if not width or width <= 0 then width = VIEW_W * scale end
  return scale, x, y, width, derived
end

-- How wide one row of a toast may be, in window pixels.
--
-- Deliberately not the playfield.  A nameplate belongs to a character
-- standing on a tile and is therefore bounded by the tiles; a toast belongs
-- to nobody on the map and is drawn in window space, so the room it may use
-- is the room actually to its right -- which on any window worth playing on
-- is a good deal more than the 160 game pixels the letterbox is.
--
-- Capped at half again the playfield all the same: a maximised window would
-- otherwise let one chat line run the width of the desktop, and a toast that
-- has to be tracked across a monitor is no longer something read in passing.
local WIDE = 1.5

local function budgetWidth(viewport, scale, x, gameWidth)
  local room = gameWidth * WIDE
  local windowW = viewport and tonumber(viewport.width)
  if not (windowW and windowW > 0) then
    windowW = love.graphics.getWidth and love.graphics.getWidth() or nil
  end
  if windowW and windowW > 0 then
    room = math.min(room, windowW - x - INSET)
  end
  return math.max(0, room - PAD * 2)
end

-- Reset the graphics state before drawing and put it back after.
--
-- push() saves the transform and nothing else, so a shader or blend mode
-- left bound by whoever composited the frame is still active here -- which
-- is how Overlay's labels once drew every frame and appeared nowhere.  The
-- transform itself is untouched: this draws in window pixels, which is what
-- render.hud already hands us.
local function beginFrame(into)
  local restore = into or {}
  restore.shader = love.graphics.getShader()
  restore.blend = love.graphics.getBlendMode()
  restore.font = love.graphics.getFont()
  love.graphics.setShader()
  love.graphics.setBlendMode("alpha")
  return restore
end

local function endFrame(restore)
  love.graphics.setColor(1, 1, 1, 1)
  if not restore then return end
  if restore.font then love.graphics.setFont(restore.font) end
  love.graphics.setBlendMode(restore.blend)
  love.graphics.setShader(restore.shader)
end

-- The two verdicts that cost nothing to reach, answered from a shared table
-- rather than a fresh one.  draw() runs every frame and the queue is empty on
-- nearly all of them, so building a diagnostic nobody asked for on the idle
-- path is the allocation the engine's hot-path rule is about.  Read by
-- M:state and never written by it.
local EMPTY = { reached = "empty", drawn = 0 }
local NO_GRAPHICS = { reached = "no-graphics", drawn = 0 }

-- ------- Gen 3
--
-- On a FireRed / LeafGreen / Emerald boot the corner is drawn *inside* the
-- 240x160 game rect, in the cart's own font, rather than in window space in
-- Rajdhani.  The Game Boy's 160x144 is small enough that a smooth HUD face
-- over it reads as an overlay; the GBA screen is not, and its own font --
-- which has the lowercase and the punctuation the Game Boy's lacked, drawn
-- from the player's own cache -- is what every other line on that screen is
-- printed in.  So a toast there looks like the cart's own text on a dark
-- plate, scaled with the letterbox exactly as the cart's text is.
--
-- Where it sits is decided by the one thing on that screen that shares the
-- corner: the map-name popup.  Both carts slide it down into the top-left on
-- a map change -- FireRed's is a 24px banner, Emerald's a 40px sign -- which
-- is exactly the moment an arrival or a chat line is most likely.  The stack
-- starts below that band instead of on top of it, and keeps to the left of
-- the player: the camera holds the player at the centre column (x 112..128
-- of 240), and the cart's own font is a 14px face on a 160px screen, so a
-- plate as wide as a Game Boy toast would sit on the player's head (the first
-- live FireRed run drew exactly that).  So a row is at most GEN3.WIDTH wide,
-- which also keeps it clear of the START menu's column on the right, and the
-- stack is at most GEN3.MAX_ROWS rows and never reaches the dialogue frame at
-- the bottom (GEN3.FLOOR): a toast over an NPC's words is the one overlap
-- that costs the player something they were reading.  When the queue has
-- more rows than that, the *oldest* rows give way -- the newest line is the
-- one the player has not read yet, the same rule push() drops by.
local GEN3 = {
  INSET = 4,          -- gap from the screen edge
  PAD_X = 3,          -- plate margin left and right of the text
  PAD_Y = 1,          -- ...and above and below it: a 14px glyph on a 16px
                      -- plate, one tile, the pitch the cart's own menus use
  ROW_GAP = 1,        -- air between stacked plates
  WIDTH = 104,        -- widest a plate may be, in GBA pixels: INSET + 104
                      -- stops short of the player's column at x = 112
  MAX_ROWS = 4,       -- the most rows the corner holds at once
  FLOOR = 112,        -- the top of the cart's dialogue frame (tiles 14..19)
  -- the popup's height per family (src/ui/game3/map_name_popup.lua: the
  -- FireRed banner is Chrome.mapPopupFrame at 24px; Emerald's sign is five
  -- tiles, Rse.OFFSCREEN_Y = 40)
  BAND = { frlg = 24, rse = 40 },
}
M.GEN3 = GEN3

-- When the corner waits.
--
-- A toast annotates the field, and the column it lives in is only clear
-- while the field is what the player is looking at.  The mod's full-screen
-- screens (PLAYERS, CHAT, the trainer card, the letter grid, a trade, the
-- arena) and the cart's own (BAG, POKéMON, the dex, the region map, the
-- PokéNav) all start at the top-left tile, so the stack -- in the cart's
-- font, scaled with the letterbox -- lands on their title and first rows:
-- exactly the words the player opened the screen to read.  The cart's
-- battle puts the foe's HP box in that corner too.
--
-- So on Gen 3 the corner is held, not drawn and not aged, while any of:
--   * the field is not running (the title, the boot menus, the FRLG recap);
--   * the cart's battle is;
--   * something on the stack covers the field (Stack.fullscreen -- every
--     layer above that asks for it, the mod's own opaque screens included:
--     Gen3Ui.pushScreen passes isOpaque through as `fullscreen`);
--   * one of this mod's boxes reaches into the column (a Menu sized by a
--     long label -- the ones today sit against the right edge, clear of it).
-- START, a mod menu against the right edge and a text box along the bottom
-- leave the column alone, which is what the corner's geometry above was
-- drawn around, so the corner stays up over those exactly as before.  The
-- lines wait and appear, each with its full time, the moment the player is
-- back in the field -- the newest TOAST_MAX of them, by push()'s own rule.
-- False on Gen 1 and Gen 2, whose corner is untouched.
local function gen3ColumnCovered(Stack)
  if type(Stack.drawOrder) ~= "function" then return false end
  local ok, order = pcall(Stack.drawOrder)
  if not (ok and type(order) == "table") then return false end
  local band = GEN3.BAND[Gen3.family()] or GEN3.BAND.frlg
  local colLeft, colRight = GEN3.INSET, GEN3.INSET + GEN3.WIDTH
  local colTop, colBottom = band + GEN3.INSET, GEN3.FLOOR
  for _, layer in ipairs(order) do
    local box = type(layer) == "table" and layer.mod or nil
    if Gen3Ui.isModLayer(layer) and type(box) == "table"
        and type(box.geometry) == "function" then
      local okG, geo = pcall(box.geometry, box)
      if okG and type(geo) == "table" and tonumber(geo.left) and tonumber(geo.w) then
        -- the content rect in tiles; the frame is drawn one tile outside it
        local x0, x1 = (geo.left - 1) * 8, (geo.left + geo.w + 1) * 8
        local y0, y1 = ((tonumber(geo.top) or 0) - 1) * 8,
                       ((tonumber(geo.top) or 0) + (tonumber(geo.h) or 0) + 1) * 8
        if x0 < colRight and x1 > colLeft and y0 < colBottom and y1 > colTop then
          return true
        end
      end
    end
  end
  return false
end

function M.gen3Held()
  if not Gen3.active() then return false end
  if not Gen3.inField() then return true end
  if Gen3.inBattle() then return true end
  local Stack = Gen3.stack()
  if type(Stack) ~= "table" then return false end
  -- Nothing on the stack covers nothing.  Asked first because it is the
  -- free-roam answer, i.e. nearly every frame with a line in the corner, and
  -- the two questions below both build the stack's draw order -- a fresh
  -- table per call, even for an empty stack.
  if type(Stack.depth) == "function" then
    local ok, depth = pcall(Stack.depth)
    if ok and depth == 0 then return false end
  end
  if type(Stack.fullscreen) == "function" then
    local ok, full = pcall(Stack.fullscreen)
    if ok and full then return true end
  end
  return gen3ColumnCovered(Stack)
end

-- What state() reports while the corner is held: shared, like EMPTY above,
-- because a held frame is every frame of a menu the player is sitting in.
local HELD = { reached = "held", drawn = 0, gen3 = true }

-- The 240x160 rect of the window this frame, and its two scale factors.
--
-- The viewport Game3 hands render.hud (Display.fit) carries the rect and a
-- scale but no scaleY; gameHeight is 160 * scaleY, so that is where the
-- vertical factor is read from.  With no usable viewport the rect is derived
-- from the window the way the Gen 1 / Gen 2 fallback does, at 240x160.
--
-- `out`, when given, is filled and returned instead of a new table (the
-- per-frame caller passes one it keeps).
function M.gen3Frame(viewport, windowW, windowH, out)
  local W, H = Config.GEN3_SCREEN_W, Config.GEN3_SCREEN_H
  local frame = out or {}
  local scale = viewport and tonumber(viewport.scale) or nil
  if scale and scale > 0 then
    local height = tonumber(viewport.gameHeight)
    frame.x = tonumber(viewport.gameX) or 0
    frame.y = tonumber(viewport.gameY) or 0
    frame.sx = scale
    frame.sy = (height and height > 0) and height / H or scale
    frame.derived = false
    return frame
  end
  windowW, windowH = tonumber(windowW) or W, tonumber(windowH) or H
  scale = math.max(1, math.floor(math.min(windowW / W, windowH / H)))
  frame.x = math.floor((windowW - W * scale) / 2)
  frame.y = math.floor((windowH - H * scale) / 2)
  frame.sx, frame.sy, frame.derived = scale, scale, true
  return frame
end

-- Where the stack may live, in GBA pixels: its left edge, the first row's
-- top (below the popup band for this family), the widest a line may be, and
-- how many rows fit above the dialogue frame at `rowH` a row.
function M.gen3Box(family, rowH)
  local band = GEN3.BAND[family] or GEN3.BAND.frlg
  local top = band + GEN3.INSET
  local step = rowH + GEN3.ROW_GAP
  local rows = math.max(1, math.floor((GEN3.FLOOR - top + GEN3.ROW_GAP) / step))
  rows = math.min(rows, GEN3.MAX_ROWS)
  return {
    left = GEN3.INSET,
    top = top,
    textWidth = GEN3.WIDTH - GEN3.PAD_X * 2,
    rows = rows,
    step = step,
  }
end

-- The cart's charset has round brackets and no square ones, and no "#",
-- "*", "@", "~", "|", "^" or "`" either (src/core/game3/scripting/text_ir.lua
-- CHARMAP): the font draws a character it cannot map as a blank, so
-- "[ANN]" would print as " ANN ".  Braces are the font's own control syntax
-- ({PLAYER}, {COLOR ...}), which Wire keeps off the wire anyway.  Every one
-- of them is mapped by Gen3Ui.printable, the table every Gen 3 screen prints
-- through, so a sentence reads the same in the corner as in the CHAT log --
-- one table, not two that drift.  The queue keeps the text as it was pushed:
-- this is how it is *drawn*.
function M.gen3Text(text)
  return Gen3Ui.printable(text)
end

-- Every row the queue would draw, oldest first, each { text, color }, cut to
-- the newest `maxRows`.
--
-- `measure(text)` and `wrap(text, width)` are the font's (injected, so the
-- suite can drive this with no glyphs at all).  An entry keeps at most
-- WRAP_MAX rows, the last one ending in the cart's own ellipsis when it had
-- to be cut, exactly as the Gen 1 / Gen 2 corner caps a sentence.
local GEN3_TAIL = "…"

local function fitRow(measure, text, width)
  if measure(text) <= width then return text end
  local budget = width - measure(GEN3_TAIL)
  local cut = text
  while #cut > 0 and measure(cut) > budget do
    -- step back one whole UTF-8 sequence, never half a glyph
    local stop = #cut
    repeat stop = stop - 1 until stop == 0 or cut:byte(stop + 1) < 0x80 or cut:byte(stop + 1) >= 0xC0
    cut = cut:sub(1, stop)
  end
  return cut .. GEN3_TAIL
end

function M.gen3Rows(queue, measure, wrapText, width, maxRows)
  local all = {}
  for _, entry in ipairs(queue or {}) do
    local text = M.gen3Text(entry.text)
    local wrapped = wrapText(text, width) or text
    local rows = {}
    for line in (tostring(wrapped) .. "\n"):gmatch("(.-)\n") do
      if line ~= "" then rows[#rows + 1] = line end
    end
    if #rows > WRAP_MAX then
      local rest = table.concat(rows, " ", WRAP_MAX, #rows)
      for n = #rows, WRAP_MAX, -1 do rows[n] = nil end
      rows[WRAP_MAX] = fitRow(measure, rest, width)
    end
    for _, row in ipairs(rows) do
      all[#all + 1] = { text = fitRow(measure, row, width), color = entry.color }
    end
  end
  local drop = #all - (tonumber(maxRows) or #all)
  if drop > 0 then
    local kept = {}
    for i = drop + 1, #all do kept[#kept + 1] = all[i] end
    all = kept
  end
  return all
end

-- The cart's font for this version (src/ui/game3/font.lua picks the
-- implementation per profile), or nil.
local function gen3Font()
  local Font = Gen3.engine("src.ui.game3.font")
  if not (Font and type(Font.active) == "function") then return nil end
  local ok, impl = pcall(Font.active)
  if ok and type(impl) == "table" and type(impl.draw) == "function"
      and type(impl.measure) == "function" then
    return impl
  end
  return nil
end

-- White text with the cart's dark-grey shadow (the colours the party menu
-- and battle text print white in); a friend's blue keeps that shadow so the
-- two read as the same kind of line in two colours.
local function gen3Colors(font, tint)
  local base = type(font.COLOR) == "table" and font.COLOR.WHITE or nil
  local shadow = base and base.shadow or { 0.38, 0.38, 0.38, 1 }
  local fg = (type(tint) == "table" and { tint[1] or 1, tint[2] or 1, tint[3] or 1, 1 })
    or (base and base.fg) or { 1, 1, 1, 1 }
  return { fg = fg, shadow = shadow, bg = { 0, 0, 0, 0 } }
end

-- ------- the Gen 3 draw, allocation-free while the queue stands still
--
-- The corner draws every frame a line is up, and on Gen 3 building its rows
-- is real work: the charset mapping, the font's wrap, the ellipsis cut, a
-- table per row and per row's colours.  None of it changes until the queue
-- does, so it is built once per queue revision (M:push / M:update / M:clear
-- bump `rev`) and per font and box, and every frame between just draws it.
-- What the frame itself needs -- the rect, the restore record, the state
-- seam's table -- is reused rather than rebuilt.

-- The font the rows are measured and wrapped with, for the two functions
-- below: module state rather than two closures made per frame.
local g3font
local function g3measure(text)
  local ok, w = pcall(g3font.measure, text)
  return ok and tonumber(w) or (#text * 6)
end
local function g3wrap(text, width)
  if type(g3font.wrap) ~= "function" then return text end
  local ok, out = pcall(g3font.wrap, text, width)
  return ok and out or text
end

-- The box per family and row height (pure, so one table each is enough).
local boxes3 = {}
local function box3(family, rowH)
  local byFamily = boxes3[family]
  if not byFamily then
    byFamily = {}
    boxes3[family] = byFamily
  end
  local box = byFamily[rowH]
  if not box then
    box = M.gen3Box(family, rowH)
    byFamily[rowH] = box
  end
  return box
end

-- The rows to draw, each with its plate width and its draw options already
-- built; rebuilt only when something they depend on moved.  The queue's
-- identity and length are checked beside `rev` so a queue somebody replaced
-- by hand is still noticed.
local function rows3(self, font, box)
  local queue = self.queue
  local c = self.rowMemo3
  if c and c.rev == (self.rev or 0) and c.queue == queue and c.count == #queue
      and c.font == font and c.box == box then
    return c.rows
  end
  g3font = font
  local rows = M.gen3Rows(queue, g3measure, g3wrap, box.textWidth, box.rows)
  for _, row in ipairs(rows) do
    row.plateW = g3measure(row.text) + GEN3.PAD_X * 2
    row.opts = { colors = gen3Colors(font, row.color), maxWidth = box.textWidth }
  end
  self.rowMemo3 = {
    rev = self.rev or 0, queue = queue, count = #queue, font = font, box = box,
    rows = rows,
  }
  return rows
end

local restore3 = {}
local frame3 = {}

function M:drawGen3(viewport)
  -- One state table per toast, reset in place: state() hands it out as the
  -- last frame's verdict and it is only ever read between frames.
  local last = self.last3
  if not last then
    last = { lines = {} }
    self.last3 = last
  end
  local lines = last.lines
  for i = #lines, 1, -1 do lines[i] = nil end
  last.reached, last.drawn, last.gen3 = "entered", 0, true
  last.top, last.maxRows = nil, nil
  self.last = last

  local font = gen3Font()
  if not font then last.reached = "no-font" return end

  local windowW, windowH = love.graphics.getDimensions()
  local frame = M.gen3Frame(viewport, windowW, windowH, frame3)
  last.scale, last.gameX, last.gameY, last.derived = frame.sx, frame.x, frame.y, frame.derived

  local glyphH = tonumber(font.GLYPH_HEIGHT) or 14
  local rowH = glyphH + GEN3.PAD_Y * 2
  local box = box3(Gen3.family() or "frlg", rowH)
  local rows = rows3(self, font, box)
  last.top, last.maxRows = box.top, box.rows

  local restore = beginFrame(restore3)
  love.graphics.push()
  love.graphics.translate(frame.x, frame.y)
  love.graphics.scale(frame.sx, frame.sy)
  local y = box.top
  for i = 1, #rows do
    local row = rows[i]
    love.graphics.setColor(0, 0, 0, 0.65)
    love.graphics.rectangle("fill", box.left, y, row.plateW, rowH)
    local ok = pcall(font.draw, row.text, box.left + GEN3.PAD_X, y + GEN3.PAD_Y, row.opts)
    if ok then
      last.drawn = last.drawn + 1
      lines[#lines + 1] = row.text
    end
    y = y + box.step
  end
  love.graphics.pop()
  endFrame(restore)
  last.reached = "drawn"
end

function M:draw(viewport)
  if not (love and love.graphics) then self.last = NO_GRAPHICS return end
  if #self.queue == 0 then self.last = EMPTY return end
  if Gen3.active() then
    if M.gen3Held() then self.last = HELD return end
    return self:drawGen3(viewport)
  end

  local last = { reached = "entered", drawn = 0 }
  self.last = last

  local scale, gameX, gameY, gameWidth, derived = geometry(viewport)
  last.scale, last.gameX, last.gameY, last.derived = scale, gameX, gameY, derived

  local font = M.font(toastSize(scale))
  if not font then last.reached = "no-font" return end

  local rowH = font:getHeight() + PAD * 2
  local step = rowH + ROW_GAP
  local x = gameX + INSET
  local maxWidth = budgetWidth(viewport, scale, x, gameWidth)
  local restore = beginFrame()
  love.graphics.setFont(font)

  -- One entry, one or more rows.  Each row gets a plate of its own, sized to
  -- its own text, so a wrapped sentence reads as a block in the corner rather
  -- than as one plate with a ragged line in it.
  local y = gameY + INSET
  for _, entry in ipairs(self.queue) do
    -- White unless the line said otherwise, and every row of a wrapped entry
    -- takes the same colour: a sentence that changed shade half way through
    -- would read as two notifications.
    local tint = type(entry.color) == "table" and entry.color or WHITE
    for _, row in ipairs(wrap(font, entry.text, maxWidth)) do
      love.graphics.setColor(0, 0, 0, 0.65)
      love.graphics.rectangle("fill", x, y,
        font:getWidth(row) + PAD * 2, rowH)
      love.graphics.setColor(tint[1] or 1, tint[2] or 1, tint[3] or 1, 1)
      love.graphics.print(row, x + PAD, y + PAD)
      last.drawn = last.drawn + 1
      last.lines = last.lines or {}
      last.lines[#last.lines + 1] = row
      y = y + step
    end
  end

  endFrame(restore)
  last.reached = "drawn"
end

M.PAD, M.INSET, M.ROW_GAP = PAD, INSET, ROW_GAP
M.VIEW_W, M.VIEW_H, M.WRAP_MAX = VIEW_W, VIEW_H, WRAP_MAX
M.toastSize = toastSize

return M
