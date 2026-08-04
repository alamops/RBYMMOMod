-- Nicknames and speech bubbles over remote players' heads.
--
-- This draws from the render.hud hook, which runs after the frame is
-- composited and before touch controls, and receives a window-space
-- viewport (gameX/gameY/gameWidth/gameHeight/scale).  Pushing that
-- transform puts drawing back into the game's own 160x144 space, so the
-- engine's font renders at its native size instead of one window pixel per
-- glyph pixel.
--
-- Positioning note, and the one real limitation here.  The mod API exposes
-- where the player and each avatar *are* (World.current(), and the NPC
-- handle's :position()), but not where the camera is.  So a remote player's
-- screen position is derived from its tile offset to the local player,
-- which assumes the player is drawn at the centre of the view.  That holds
-- while the camera is following normally and goes wrong by exactly the
-- camera's clamp when the player walks into a map edge smaller than the
-- screen, where the view stops scrolling but the player keeps moving.  A
-- label can sit a tile or two off in those corners.  Fixing it properly
-- needs a camera-position seam the mod API does not have yet, which is an
-- upstream RFC, not something to paper over with a private require.

local need, mod = ...
local Config = need("Config")
local World = need("World")
local Chars = need("Chars")

local M = {}
M.__index = M

-- Game Boy overworld geometry: a 160x144 view, 16px cells, and a 16px
-- player sprite parked in the middle of it.
local VIEW_W, VIEW_H = 160, 144
local CELL = 16
local ANCHOR_X = (VIEW_W - CELL) / 2
local ANCHOR_Y = (VIEW_H - CELL) / 2

function M.new(ctx)
  return setmetatable({ ctx = ctx }, M)
end

-- The name as it appears over a head, with the party marker on it.
--
-- Brackets around your party member's nickname, so that on a map with
-- several players standing on it "which of these is my friend" is answerable
-- without opening a menu.  Everybody else is drawn under their own name.
--
-- **The arrow, and not an asterisk, because the font has no asterisk.** The
-- charmap is extracted from the ROM and its whole punctuation set is
-- `! " ' ( ) , - . / : ; ? [ ]` plus a handful of symbols -- no `*`, `+` or
-- `#`.  Font.draw draws *nothing* for a character it cannot map while
-- Font.width still advances eight pixels for it, so the first version of
-- this marker rendered as a plate one glyph too wide with a blank hole at
-- the front: invisible in game, and invisible to every assertion that read
-- the string instead of the pixels.  It survived a fully green end-to-end
-- run.
--
-- `▶` is the game's own cursor glyph (0xED), so it already means *this one*
-- to anyone who has used a menu, and it costs one glyph where brackets cost
-- two -- 48 pixels of plate against 56 for the same name.  Not a colour: a
-- nameplate has to stay legible over whatever palette the map is drawn in.
--
-- **It is three bytes of UTF-8, and that matters here.**  Every length in
-- this file that is measured for the screen has to be measured in glyphs,
-- not bytes: `#name` over-counts it by two and `name:sub()` can cut it in
-- half and leave a broken sequence for the renderer.  drawRoster's width cap
-- is the one place that did, and it now cuts on span boundaries.
--
-- Anything ever put here has to exist in `data.font.charmap`, and only a
-- real run can check that -- the committed fixture font carries letters and
-- digits and would reject a glyph the game draws happily -- so the
-- two-instance driver asks it of every plate the overlay commits.
--
-- The TOWN MAP layer deliberately does *not* use this: the only people drawn
-- on that screen are party members, so a marker there would mark everything.
function M:nameFor(player)
  local party = self.ctx.party
  if party and party:isPartner(player.id) then
    return M.PARTY_MARK .. player.name
  end
  return player.name
end

-- Is the world still being drawn with the flat 2D projection this overlay
-- assumes -- player centred, sixteen pixels to a tile?
--
-- It is not, whenever another mod owns the world pass. DramaticShapeVoxelMod
-- registers a "voxel" pipeline with drawWorld that replaces the overworld
-- with a 3D diorama; under it a nameplate placed by tile offset would float
-- somewhere unrelated to the character it names, which looks far worse than
-- no nameplate at all.
--
-- The registry says which pipelines replace the world (drawWorld); the
-- engine says which are switched on.
--
-- The level is read from src/render/Pipelines, not from
-- save.options.pipelines, because the options bucket is only written when
-- something syncs it -- Pipelines.setLevel alone does not. Reading the
-- bucket looked permission-free and self-evidently correct, and it was
-- neither: with the voxel pipeline genuinely on, the stale bucket still
-- said "flat" and the fallback never engaged. The save bucket is kept as a
-- second source for builds where the module cannot be reached at all.
--
-- This is why the manifest declares engine_internals: a read-only question
-- about how the world is being drawn, which the mod API has no other way
-- to answer.
local pipelinesModule, pipelinesTried

local function enginePipelines()
  if pipelinesTried then return pipelinesModule end
  pipelinesTried = true
  local ok, module = pcall(require, "src.render.Pipelines")
  if ok and type(module) == "table" and module.level then
    pipelinesModule = module
  end
  return pipelinesModule
end

function M:worldIsFlat(game)
  local registry = mod.content and mod.content.render_pipelines
  if not registry then return true end

  local Pipelines = enginePipelines()
  local levels = game and game.save and game.save.options
    and game.save.options.pipelines

  local ok, flat = pcall(function()
    for id, def in registry:each() do
      if type(def) == "table" and def.drawWorld then
        -- Either source saying "on" is enough. The engine's level is the
        -- live truth; the saved bucket can be stale in one direction only
        -- (it lags a change), so trusting whichever says the world is not
        -- flat costs at most the fallback rendering, while trusting only
        -- one of them can miss the case entirely.
        local level = 0
        if Pipelines then
          level = math.max(level, tonumber(Pipelines.level(id)) or 0)
        end
        if type(levels) == "table" then
          level = math.max(level, tonumber(levels[id]) or 0)
        end
        if level > 0 then return false end
      end
    end
    return true
  end)
  -- an unreadable registry means "assume vanilla", which is the case that
  -- draws correctly
  if not ok then return true end
  return flat
end

-- The fallback for a world this overlay cannot project into: name the
-- players on this map in a fixed corner list instead of floating a label
-- over each one. Their avatars are still drawn by whatever owns the world
-- -- the voxel mod draws them as voxel characters -- so what is missing is
-- only the labelling, and a corner list restores that without inventing
-- positions it cannot compute.
-- Cut a line to a number of *glyphs*, never bytes.
--
-- The screen is 20 tiles wide, so the cap has always meant glyphs -- but it
-- was written as `#text` and `text:sub()`, which are bytes, and that was
-- indistinguishable from correct for as long as every name was ASCII. The
-- party marker is `▶`, three bytes for one glyph: byte length over-counts a
-- marked name by two, so a line gets trimmed before it needs to be, and a
-- cut can land inside the sequence and hand the renderer a broken glyph.
--
-- Font.split is the renderer's own greedy, multi-byte-aware pass, so cutting
-- on its span boundaries cuts where the font would. The byte path stays as
-- the fallback for a build where split is unavailable; it is wrong in the
-- same small way it always was rather than newly wrong.
local ROSTER_COLS = 19

local function clipToGlyphs(Font, text, columns)
  if type(Font.split) ~= "function" then
    if #text > columns then return text:sub(1, columns) end
    return text
  end
  local ok, spans = pcall(Font.split, text)
  if not (ok and type(spans) == "table") then return text end
  if #spans <= columns then return text end
  local last = spans[columns]
  return text:sub(1, (last and last.to) or columns)
end

function M:drawRoster(Font, here)
  local y = 2
  for index, player in ipairs(here) do
    if index > 4 then break end
    local name = self:nameFor(player)
    local bubble = self.ctx.chat:bubbleFor(player.id)
    local text = clipToGlyphs(Font, bubble and (name .. ": " .. bubble) or name,
                              ROSTER_COLS)
    local width = Font.width(text)
    love.graphics.setColor(0, 0, 0, 0.65)
    love.graphics.rectangle("fill", 1, y - 1, width + 4, 10)
    love.graphics.setColor(1, 1, 1, 1)
    Font.draw(text, 3, y)
    self:note(text)
    y = y + 10
  end
end

-- A label is only drawn when it is fully on screen; a half-clipped name at
-- the edge of the playfield reads as a rendering bug.
local function onScreen(x, y, width)
  return x >= 0 and y >= 0 and (x + width) <= VIEW_W and y + 8 <= VIEW_H
end

-- Record a label this draw actually committed to the screen.
--
-- `reached` says which path the overlay took; this says what came out of it.
-- The difference matters for anything carried *in* the text -- the party
-- marker is one glyph on a nameplate, so "reached == labels" is true whether
-- or not it was there, and only the string can tell the two apart. Without
-- this the marker is unassertable: a driver would be left inferring it from
-- a screenshot, which is exactly what src/Overlay's state seam exists to
-- avoid.
--
-- Bounded by the players on this map, and only ever appended to the table
-- this draw already allocated for `last`, so it costs no allocation the
-- frame was not making anyway.
function M:note(text)
  local last = self.last
  if not last then return end
  last.names = last.names or {}
  last.names[#last.names + 1] = text
end

function M:drawLabel(Font, text, centreX, topY)
  local width = Font.width(text)
  local x = math.floor(centreX - width / 2)
  local y = math.floor(topY)
  -- Noted only when it is actually drawn.  A label clipped at the edge of
  -- the playfield is a label the player cannot read, and a state seam that
  -- reported it anyway would be worse than none.
  if not onScreen(x, y, width) then return end

  -- a one-pixel dark plate behind the glyphs: the font is drawn in the
  -- text colour and would vanish over a dark tile without it
  love.graphics.setColor(0, 0, 0, 0.65)
  love.graphics.rectangle("fill", x - 2, y - 1, width + 4, 10)
  love.graphics.setColor(1, 1, 1, 1)
  Font.draw(text, x, y)
  self:note(text)
end

-- ------- drawing in the game's own 160x144 space
--
-- Reset the graphics state before drawing, and put it back after.
--
-- love.graphics.push() saves the transform and nothing else, so a shader or
-- blend mode left bound by whoever drew the frame is still active here. With
-- DramaticShapeVoxelMod's pipeline on, the labels drew through its shader and
-- simply did not appear -- the overlay looked broken when it was in fact
-- drawing every frame. The TOWN MAP has its own version of the same hazard:
-- that screen composites through an SGB shade-remap shader that keys only on
-- the red channel, so anything drawn under it comes out recoloured.
--
-- Paired: every beginFrame is matched by exactly one endFrame, and both
-- branches of draw() go through them rather than each unwinding by hand --
-- which is what the world path used to do, in two places, one of which had
-- to remember to restore three things in the right order.
function M:beginFrame(scale, gameX, gameY)
  local restore = {
    shader = love.graphics.getShader(),
    blend = love.graphics.getBlendMode(),
  }
  love.graphics.setShader()
  love.graphics.setBlendMode("alpha")
  love.graphics.push()
  love.graphics.translate(gameX, gameY)
  love.graphics.scale(scale)
  return restore
end

function M:endFrame(restore)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.pop()
  if not restore then return end
  love.graphics.setBlendMode(restore.blend)
  love.graphics.setShader(restore.shader)
end

-- ------- the TOWN MAP
--
-- Where in Kanto your friend actually is.
--
-- The overworld tells you about the players standing in the room with you.
-- The one thing a party wants that it cannot answer is the other question --
-- *where are they* -- and Kanto already has a screen for exactly that. So
-- when the TOWN MAP is open, the party member is drawn on it: their
-- character at their city, with their nickname above it. Not a dot and not
-- an icon; the same person you would see if you walked there.
--
-- Party only, and deliberately. Every player on a busy hub drawn at once
-- would bury the map under characters, and the map is 20x18 tiles with a
-- 16x16 character on it. At PARTY_MAX = 2 there is exactly one to draw.
--
-- Identifying the screen needs `engine_internals`, which this mod already
-- declares: the mod API has no "what state is this" seam, and duck-typing on
-- field names would silently start drawing over some other mod's screen that
-- happened to have a `byMap`. The require is read-only and the failure is
-- soft -- no TownMap module means the layer simply never draws.
local townMapModule, townMapTried

local function engineTownMap()
  if townMapTried then return townMapModule end
  townMapTried = true
  local ok, module = pcall(require, "src.ui.TownMap")
  if ok and type(module) == "table" then townMapModule = module end
  return townMapModule
end

-- The live TOWN MAP state, or nil if that is not what is on top.
function M:townMapState(top)
  if type(top) ~= "table" then return nil end
  local TownMap = engineTownMap()
  if not TownMap then return nil end
  if getmetatable(top) ~= TownMap then return nil end
  -- `byMap` is the mapId -> {name, x, y} index the screen builds for
  -- itself. Absent on the list-mode fallback (a build with no town-map
  -- coordinates), where there is no cell to draw anybody at.
  if type(top.byMap) ~= "table" then return nil end
  if top.mode ~= "grid" then return nil end
  -- The Pokedex AREA screen is the same class with nestSpecies set, and it
  -- is asking a different question -- where does this species live -- which
  -- a friend's face standing in the middle of does not help answer. The FLY
  -- picker is deliberately *not* excluded: knowing where they are is useful
  -- precisely while choosing where to go.
  if top.nestSpecies ~= nil then return nil end
  return top
end

-- TownMapCoordsToOAMCoords: the 16x16 nybble grid sits two tiles in and one
-- tile down on the 20x18 screen. Kept in step with TownMap's own markerXY --
-- if that moves, a party member drifts off their city.
local function cellXY(loc)
  return loc.x * 8 + 16, loc.y * 8 + 8
end

-- Row 0 is the screen's own name banner, redrawn every frame under whatever
-- this puts there, so a label placed in it is a label nobody can read.
local BANNER_H = 8

-- Who goes where on the town map: one mark per party member whose current
-- map resolves to a city on it.
--
-- Separated from the drawing on purpose. *Which* member lands on *which*
-- city is the whole of the logic here and all of it can be got wrong --
-- a member who is not on the roster, one standing in a map the town map has
-- no square for, yourself -- while the drawing is four love.graphics calls.
-- Split this way the logic is answerable under plain luajit, where there is
-- no love at all, and the suite pins it directly.
--
-- Returns a list, newest concerns first: `sprite` is the character to draw,
-- `name` the nickname to put over it, and `x`/`y` the cell's screen pixels.
function M:townMapMarks(state)
  local out = {}
  local ctx = self.ctx
  local party = ctx and ctx.party
  if not (party and party:has()) then return out end
  if type(state) ~= "table" or type(state.byMap) ~= "table" then return out end

  for _, member in ipairs(party:list()) do
    -- Not you. Your own location already blinks on this screen, drawn by
    -- the screen itself, and a second marker on the same city would read as
    -- two people standing there.
    if not party:isSelf(member.id) then
      local player = ctx.roster:get(member.id)
      -- No cell means they are in a battle or a menu, and a map the town map
      -- has no square for -- an interior the extractor never indexed, or a
      -- map from a mod this copy does not have -- simply is not placeable.
      -- Either way they are left off rather than guessed at.
      local loc = player and player.map and state.byMap[player.map]
      if loc and tonumber(loc.x) and tonumber(loc.y) then
        local x, y = cellXY(loc)
        out[#out + 1] = {
          id = member.id, name = member.name,
          sprite = player.sprite, place = loc.name,
          x = x, y = y,
        }
      end
    end
  end
  return out
end

function M:drawTownMap(Font, state)
  local marks = self:townMapMarks(state)
  self.last.drawn = #marks
  if #marks == 0 then
    self.last.reached = "townmap-nobody"
    return
  end

  for _, mark in ipairs(marks) do
    -- The character, centred on the cell rather than hung off its top-left:
    -- the cell is 8x8 and the sprite is 16x16, so drawing at the corner
    -- would sit them a whole city up and to the left.
    local art = Chars.portrait(mark.sprite)
    if art then
      love.graphics.setColor(1, 1, 1, 1)
      love.graphics.draw(art.image, art.quad, mark.x - 4, mark.y - 4)
    end
    -- ...and the nickname over their head, flipping under the sprite when
    -- the city is high enough that the label would land in the banner. A
    -- name half-inside the banner reads as a rendering fault.
    local labelY = mark.y - 14
    if labelY < BANNER_H then labelY = mark.y + 14 end
    self:drawLabel(Font, mark.name, mark.x + 4, labelY)
  end
end

-- what the last draw decided, so a driver can ask why nothing appeared
-- instead of inferring it from a screenshot
function M:state()
  return self.last or { reached = "never" }
end

function M:draw(game, viewport)
  local ctx = self.ctx
  self.last = { reached = "entered" }
  local last = self.last
  if not (ctx.client and ctx.client:isConnected()) then last.reached = "not-connected" return end
  -- Derive the letterbox when the viewport does not carry a usable one.
  --
  -- render.hud is documented as receiving gameX/gameY/scale, and under the
  -- vanilla renderer it does. With DramaticShapeVoxelMod's pipeline owning
  -- the frame it arrived without a usable scale, and bailing on that meant
  -- the overlay silently drew nothing at all in voxel mode -- which looked
  -- like a positioning bug and was actually a missing guard. Falling back
  -- to the window's own dimensions keeps this working whoever draws the
  -- world.
  local scale = viewport and tonumber(viewport.scale) or nil
  local gameX = viewport and tonumber(viewport.gameX) or 0
  local gameY = viewport and tonumber(viewport.gameY) or 0
  if not scale or scale <= 0 then
    local w, h = love.graphics.getDimensions()
    scale = math.max(1, math.floor(math.min(w / VIEW_W, h / VIEW_H)))
    gameX = math.floor((w - VIEW_W * scale) / 2)
    gameY = math.floor((h - VIEW_H * scale) / 2)
    last.derived = true
  end
  last.scale, last.gameX, last.gameY = scale, gameX, gameY

  -- render.hud composites over the *finished* frame -- menus and text boxes
  -- included -- so a nameplate drawn unconditionally lands on top of
  -- whatever UI is open. These labels annotate the world, so they are drawn
  -- only while the world is what the player is actually looking at.
  local top = game and game.stack and game.stack:top()

  local Font = mod.ui.Font
  if not (Font and Font.draw and Font.width) then
    last.reached = "no-font"
    return
  end

  -- The TOWN MAP is the one screen other than the world this overlay draws
  -- on, and for the opposite reason: there it says who is standing next to
  -- you, here it says where your friend is in Kanto.
  local townMap = self:townMapState(top)
  if townMap then
    last.reached = "townmap"
    local restore = self:beginFrame(scale, gameX, gameY)
    self:drawTownMap(Font, townMap)
    self:endFrame(restore)
    return
  end

  -- render.hud composites over the *finished* frame -- menus and text boxes
  -- included -- so a nameplate drawn unconditionally lands on top of
  -- whatever UI is open. These labels annotate the world, so they are drawn
  -- only while the world is what the player is actually looking at.
  local overworld = mod.world and mod.world:overworld()
  if not (top and overworld and top == overworld) then
    last.reached = "not-overworld"
    return
  end

  local current = World.current()
  if not (current and current.mapId and current.x and current.y) then
    last.reached = "no-cell"
    return
  end

  local here = ctx.roster:onMap(current.mapId)
  last.here = #here
  if #here == 0 then last.reached = "nobody-here" return end

  local restore = self:beginFrame(scale, gameX, gameY)

  -- another mod owns the world pass: label from a corner rather than
  -- guessing at positions in a projection this does not know
  if not self:worldIsFlat(game) then
    last.reached = "roster"
    self:drawRoster(Font, here)
    self:endFrame(restore)
    return
  end

  last.reached = "labels"
  for _, player in ipairs(here) do
    -- the live avatar cell, which is where the sprite actually is mid-step
    local ax, ay = ctx.avatars:cellOf(player.id)
    if ax and ay then
      local screenX = ANCHOR_X + (ax - current.x) * CELL
      local screenY = ANCHOR_Y + (ay - current.y) * CELL

      local name = self:nameFor(player)
      local bubble = ctx.chat:bubbleFor(player.id)
      if bubble then
        -- the bubble takes the slot above the head and pushes the name up
        self:drawLabel(Font, bubble, screenX + CELL / 2, screenY - 20)
        self:drawLabel(Font, name, screenX + CELL / 2, screenY - 10)
      else
        self:drawLabel(Font, name, screenX + CELL / 2, screenY - 10)
      end
    end
  end

  self:endFrame(restore)
end

-- The party marker: the game's own cursor glyph, 0xED, as its three UTF-8
-- bytes.  Exported so the suite and the end-to-end driver build the expected
-- nameplate from the same source the renderer uses rather than each spelling
-- it out and drifting -- and spelling it out is exactly what a multi-byte
-- glyph makes easy to get subtly wrong.
M.PARTY_MARK = "\226\150\182"   -- U+25B6 BLACK RIGHT-POINTING TRIANGLE

M.VIEW_W, M.VIEW_H, M.CELL = VIEW_W, VIEW_H, CELL
M.ANCHOR_X, M.ANCHOR_Y = ANCHOR_X, ANCHOR_Y
M.LOCAL_RADIUS = Config.LOCAL_RADIUS

return M
