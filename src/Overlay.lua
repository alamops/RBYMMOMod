-- Nicknames over remote players' heads.
--
-- Names and nothing else.  Chat used to float over a head as a speech bubble
-- and does not any more: what somebody said is a toast in the corner now
-- (src/Toast.lua), where it is legible at any window size and does not
-- depend on the speaker being on screen.  What is left here is the one thing
-- that genuinely belongs in the world -- which of these characters is who.
--
-- This draws from the render.hud hook, which runs after the frame is
-- composited and before touch controls, and receives a window-space
-- viewport (gameX/gameY/gameWidth/gameHeight/scale).  Nameplates use the
-- same Rajdhani face as the corner toasts (src/Toast.lua), drawn in window
-- pixels so the type stays crisp at any letterbox scale.  Town-map portraits
-- still composite in the game's 160x144 space; only their labels follow the
-- toast face.
--
-- Screen position is derived from the same camera rule SpriteRenderer uses:
-- floor(px - camX), floor(py - camY) - 4, with Camera:follow parking the
-- local player at (64, 60).  The live overworld player's px/py is read for
-- the anchor so a label glides with a mid-step avatar instead of snapping
-- to integer cells.

local need, mod = ...
local Config = need("Config")
local World = need("World")
local Gen = need("Gen")
local Chars = need("Chars")
local Toast = need("Toast")

local M = {}
M.__index = M

-- Game Boy overworld geometry: 160x144 view, 16px walk cells, sprites
-- drawn four pixels above their cell (src/render/SpriteRenderer.lua).
local VIEW_W, VIEW_H = 160, 144
local CELL = 16
local CAM_X = VIEW_W / 2 - 16
local CAM_Y = VIEW_H / 2 - 8
local SPRITE_LIFT = 4
-- Top-left of a co-located 16x16 sprite; exported for tests and drivers.
local ANCHOR_X, ANCHOR_Y = CAM_X, CAM_Y - SPRITE_LIFT

local LABEL_GAP = 2
local SHADOW_DX, SHADOW_DY = 1, 1
-- Rajdhani at toast size: bright enough to read on pale tiles, deep enough
-- that white shadow still separates it from snow and indoor floors.
local PARTY_GREEN = { 0.42, 0.94, 0.52 }
local SELF_YELLOW = { 1.0, 0.92, 0.38 }
-- The same blue the corner draws a friend arriving in, taken from Config
-- rather than written out again: two copies of "smooth blue" would drift on
-- the first tweak, and the whole point of the colour is that the plate over
-- their head and the line announcing them are recognisably one thing.
local FRIEND_BLUE = Config.FRIEND_BLUE
local LABEL_WHITE = { 1, 1, 1 }
local TAIL = "..."

-- ------- the partner's "!"
--
-- When one party member walks into a trainer the engine plays its `!` emote
-- over that NPC's head -- on *their* screen.  The partner, who is about to be
-- pulled into the same fight without being asked (Coop:autoJoin), used to see
-- nothing at all: the world simply froze into a battle.  This draws the same
-- beat on their screen, so the fight is something they watched start rather
-- than something that happened to them.
--
-- **Over the waiting partner's own head, not the trainer's, and in both
-- modes.**  Mirroring the engine and marking the NPC is the obvious choice and
-- the wrong one: NPCs are ROM-derived, and two players on one hub are not
-- promised the same ROM.  The object the waiter walked into may be a different
-- trainer in the partner's map data, or absent from it, so a mark placed from
-- a locally resolved id can land on a stranger or on nothing at all -- and the
-- side that sent the offer can never see that it did.  The avatar is the one
-- anchor both copies already agree on, because this mod put it there itself
-- from presence it sent; it costs no ROM lookup and no map data, and it is the
-- same projection the nameplates use.  A wild fight has no NPC to argue about
-- and marks the same head, so there is one rule and no mode branch.
--
-- Original vector art, drawn from four love.graphics calls -- no ROM bytes and
-- no glyph from the extracted font, so it costs nothing legally and nothing at
-- the charmap (the party marker's lesson: a character the font cannot map
-- draws as a hole that every string assertion passes straight over).
--
-- Sizes are in the game's own 160x144 pixels and multiplied up by the
-- letterbox scale, unlike the nameplate face: the mark belongs to the world
-- and to a head in it, so it has to grow with the tiles rather than stay a
-- fixed number of window pixels the way a corner toast does.
local ALERT_W, ALERT_H = 11, 12       -- bubble body, game pixels
local ALERT_TAIL = 3                  -- the point under it, aimed at the head
local ALERT_GAP = 2                   -- air between the point and the sprite
local ALERT_BOUNCE = 2                -- travel of the bob, game pixels
local ALERT_PERIOD = 0.85             -- seconds for one rise and fall
-- Seconds the mark outlives the offer that raised it.  It has to outlive it:
-- Coop:autoJoin clears `offer` *before* it sends the join (so a second tick
-- cannot double-join), and the battle only reaches the screen a round trip
-- later -- so keying the mark strictly on a standing offer would show it for
-- zero frames in the one case the whole feature is for.
--
-- **This grace was never the fix for that, and read as though it were.**  It
-- decays a mark that already exists; it cannot raise one, and the set-and-
-- clear happens inside a single inbound handler with no tick in between, so
-- there was nothing for it to decay.  What raises the mark is Coop's latch
-- (`offerMarkFor`, read by M:offerMark) and what keeps it readable is
-- ALERT_MIN below.  This is now what it always actually was: the beat a mark
-- gets after a *standing* offer ends -- a partner who walked off, or a
-- five-minute timeout -- where a moment of stale `!` costs nothing.
local ALERT_HOLD = 1.2
-- Seconds the mark stands from the tick it went up, whatever happens to the
-- offer underneath it.  The grace above is measured from the offer ending and
-- so is worth nothing in the case that matters: an automatic join clears the
-- offer in the same handler that raised it, and the fight is a couple of relay
-- round trips behind -- measured at 0.05-0.5s of overworld, an order of
-- magnitude under anything a person can read.  A floor is the only thing that
-- turns that into a signal, and it is deliberately longer than one bob
-- (ALERT_PERIOD) so the thing the player sees is a bubble bouncing over a head
-- rather than a flicker they are not sure happened.
--
-- It is a floor and not a guarantee: the battle screen still ends it early
-- (M:update), because a mark anchored to a world nobody can see is not a
-- signal either.  What is owed past that point is a corner line, not a bubble.
local ALERT_MIN = 2.5
local ALERT_FILL = { 1, 1, 1 }
local ALERT_INK = { 0.11, 0.11, 0.16 }

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
-- two -- 48 pixels of plate against 56 for the same name.
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

function M:isPartner(player)
  local party = self.ctx and self.ctx.party
  return party and party:isPartner(player.id) or false
end

-- Is this one of the people on your list for this hub?
--
-- By name, because that is what a friendship is keyed on (src/Friends.lua) --
-- the connection id over their head is minted for this session and means
-- nothing to a list that outlives it.
function M:isFriend(player)
  local friends = self.ctx and self.ctx.friends
  if not (friends and friends.isFriend) then return false end
  return friends:isFriend(player.name) and true or false
end

-- Which of the three a plate is drawn in, most specific first.
--
-- A party partner who is also a friend comes out green, and that is the right
-- way round: the party is the relationship that is true *right now* and the
-- one that changes what the player should do next, while being friends is a
-- standing fact that will still be there when the party ends.  Colouring it
-- the other way would take the marker off the person you are travelling with
-- exactly when you most need to pick them out of a crowd.
function M:labelColor(player)
  if self:isPartner(player) then return PARTY_GREEN end
  if self:isFriend(player) then return FRIEND_BLUE end
  return LABEL_WHITE
end

-- The name this client publishes.  The roster deliberately excludes self, so
-- the local player's plate is drawn from here rather than from onMap().
function M:selfName(game)
  local client = self.ctx and self.ctx.client
  if not (client and client.playerName) then return nil end
  return client.playerName(game)
end

-- Is the world still being drawn with the flat 2D projection this overlay
-- assumes -- player centred, sixteen pixels to a tile?
--
-- It is not whenever another mod owns the world pass. DramaticShapeVoxelMod
-- is the useful exception: it exports the camera projector intended for
-- companion overlays, so draw() uses that below. Other world pipelines still
-- fall back to the corner roster rather than guessing at their projection.
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

-- DramaticShapeVoxelMod deliberately exposes its module resolver to companion
-- mods.  Voxel3D.project is the same camera transform it gives the overworld
-- FX, and VoxelScene.groundAt is the height its character card stands on.
-- Keep this a soft integration: an older Voxel release, or another 3D world
-- mod, must leave the MMO usable with the corner roster rather than erroring.
function M:voxelApi(game)
  local exports = game and game.mods and game.mods.exports
  local handle = exports and exports.DRAMATIC_SHAPE
  local lib = handle and handle.lib
  if type(lib) ~= "table" or type(lib.require) ~= "function" then return nil end

  local ok3d, voxel3d = pcall(lib.require, "Voxel3D")
  if not (ok3d and type(voxel3d) == "table"
          and type(voxel3d.project) == "function"
          and type(voxel3d.size) == "function") then
    return nil
  end
  local okScene, scene = pcall(lib.require, "VoxelScene")
  return voxel3d, (okScene and type(scene) == "table") and scene or nil
end

-- The window-space point just over an avatar's head in Voxel mode.  The
-- projector answers in its render canvas' pixels; AA can make that canvas
-- larger than the final window, so translate through both sizes instead of
-- assuming one canvas pixel is one screen pixel.
function M:voxelAnchor(game, overworld, worldX, worldY, windowW, windowH)
  local voxel3d, scene = self:voxelApi(game)
  if not voxel3d then return nil end

  local ground = 0
  local map = overworld and overworld.map
  if scene and type(scene.groundAt) == "function" and map then
    local ok, height = pcall(scene.groundAt, map,
                             math.floor(worldX / CELL), math.floor(worldY / CELL))
    if ok and type(height) == "number" then ground = height end
  end

  -- Characters are 16 world pixels tall and stand at the centre of a cell.
  -- Two pixels of air keeps the plate from touching hats and hair.
  local ok, x, y = pcall(voxel3d.project, worldX + CELL / 2, ground + CELL + LABEL_GAP,
                         worldY + CELL / 2)
  if not (ok and type(x) == "number" and type(y) == "number") then return nil end

  local canvasW, canvasH = voxel3d.size()
  canvasW, canvasH = tonumber(canvasW), tonumber(canvasH)
  windowW, windowH = tonumber(windowW), tonumber(windowH)
  if not (canvasW and canvasW > 0 and canvasH and canvasH > 0
          and windowW and windowW > 0 and windowH and windowH > 0) then
    return nil
  end
  return x * windowW / canvasW, y * windowH / canvasH
end

-- The fallback for a world this overlay cannot project into: name the
-- players on this map in a fixed corner list instead of floating a label
-- over each one. Their avatars are still drawn by whatever owns the world,
-- so the label remains available without inventing a position.

-- Screen centre-x and sprite-top-y for an avatar at world pixels (px, py)
-- relative to the local player at (playerPx, playerPy).  Matches
-- SpriteRenderer:draw and Camera:follow on a 160x144 view.
function M.screenOf(avatarPx, avatarPy, playerPx, playerPy)
  local left = math.floor(avatarPx - playerPx + CAM_X)
  local top = math.floor(avatarPy - playerPy + CAM_Y) - SPRITE_LIFT
  return left + CELL / 2, top
end

local function splitWidth(font, text, maxWidth)
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

local function fitWidth(font, text, maxWidth)
  if maxWidth <= 0 then return "" end
  if font:getWidth(text) <= maxWidth then return text end
  local budget = maxWidth - font:getWidth(TAIL)
  if budget <= 0 then return "" end
  local head = splitWidth(font, text, budget)
  if head == "" then return "" end
  return head .. TAIL
end

local function beginHud()
  local restore = {
    shader = love.graphics.getShader(),
    blend = love.graphics.getBlendMode(),
    font = love.graphics.getFont(),
  }
  love.graphics.setShader()
  love.graphics.setBlendMode("alpha")
  return restore
end

local function endHud(restore)
  love.graphics.setColor(1, 1, 1, 1)
  if not restore then return end
  if restore.font then love.graphics.setFont(restore.font) end
  love.graphics.setBlendMode(restore.blend)
  love.graphics.setShader(restore.shader)
end

local function printLabel(font, text, x, y, color)
  color = color or LABEL_WHITE
  love.graphics.setColor(0, 0, 0, 0.85)
  love.graphics.print(text, x + SHADOW_DX, y + SHADOW_DY)
  love.graphics.setColor(color[1], color[2], color[3], 1)
  love.graphics.print(text, x, y)
end

function M:drawRoster(font, here, scale, gameX, gameY, game)
  scale = tonumber(scale) or 1
  gameX, gameY = tonumber(gameX) or 0, tonumber(gameY) or 0
  local pad = Toast.PAD
  local rowH = font:getHeight() + pad * 2
  local step = rowH + Toast.ROW_GAP
  local x = gameX + 3 * scale
  local y = gameY + 2 * scale
  local maxWidth = VIEW_W * scale - 6 * scale

  local mine = self:selfName(game)
  if mine and mine ~= "" then
    printLabel(font, mine, x, y + pad, SELF_YELLOW)
    self:note(mine)
    y = y + step
  end

  for index, player in ipairs(here) do
    if index > 4 then break end
    local text = fitWidth(font, self:nameFor(player), maxWidth)
    if text ~= "" then
      printLabel(font, text, x, y + pad, self:labelColor(player))
      self:note(text)
    end
    y = y + step
  end
end

-- A label is only drawn when it is fully on screen; a half-clipped name at
-- the edge of the playfield reads as a rendering bug.
local function onScreenWindow(x, y, width, height, gameX, gameY, scale)
  local left = gameX
  local top = gameY
  local right = gameX + VIEW_W * scale
  local bottom = gameY + VIEW_H * scale
  return x >= left and y >= top and (x + width) <= right and (y + height) <= bottom
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

function M:drawLabel(font, text, centreX, spriteTopY, scale, gameX, gameY, color)
  scale = tonumber(scale) or 1
  gameX, gameY = tonumber(gameX) or 0, tonumber(gameY) or 0

  local width = font:getWidth(text)
  local height = font:getHeight()
  local wx = gameX + centreX * scale
  local wy = gameY + (spriteTopY - LABEL_GAP) * scale - height

  local x = math.floor(wx - width / 2)
  local y = math.floor(wy)
  -- Noted only when it is actually drawn.  A label clipped at the edge of
  -- the playfield is a label the player cannot read, and a state seam that
  -- reported it anyway would be worse than none.
  if not onScreenWindow(x, y, width, height, gameX, gameY, scale) then return end

  printLabel(font, text, x, y, color or LABEL_WHITE)
  self:note(text)
end

-- Voxel's camera fills the real window rather than the Game Boy playfield,
-- so its projected coordinates cannot go through drawLabel's 160x144 clip
-- test.  This is the same plate, just bounded by the canvas Voxel presented.
function M:drawVoxelLabel(font, text, centreX, headY, windowW, windowH, color)
  local width, height = font:getWidth(text), font:getHeight()
  local x = math.floor(centreX - width / 2)
  local y = math.floor(headY - LABEL_GAP - height)
  if x < 0 or y < 0 or x + width > windowW or y + height > windowH then return false end
  printLabel(font, text, x, y, color or LABEL_WHITE)
  self:note(text)
  return true
end

function M:drawVoxelNameplate(font, game, overworld, player, worldX, worldY,
                               windowW, windowH, color)
  local x, y = self:voxelAnchor(game, overworld, worldX, worldY, windowW, windowH)
  if not x then return false end
  return self:drawVoxelLabel(font, player, x, y, windowW, windowH, color)
end

function M:drawSelfLabel(font, game, playerPx, playerPy, scale, gameX, gameY)
  local name = self:selfName(game)
  if not (name and name ~= "") then return end
  local centreX, spriteTop = M.screenOf(playerPx, playerPy, playerPx, playerPy)
  self:drawLabel(font, name, centreX, spriteTop, scale, gameX, gameY, SELF_YELLOW)
end

-- ------- the partner's "!"
--
-- What the standing offer asks this client to mark, or nil.
--
-- Read through Coop's own accessor rather than off its field, so the overlay
-- asks the same question the ACTIONS menu and the trainer trigger ask.  The
-- offer is read-only here: this module owns no part of the co-op handshake and
-- must never be the reason one resolves differently.
--
-- **It marks the waiting partner, never the trainer, and that is the whole
-- rule -- in both modes.**
--
-- The obvious placement is the NPC's head, because that is where the engine
-- plays its own emote.  It is the wrong one here: an NPC is ROM-derived, and
-- two players in one hub are not promised the same ROM.  The trainer the
-- waiter walked into may be a different object on the partner's map data, or
-- may not exist on it at all, so an id looked up locally can land the mark on
-- a stranger or on nothing -- and neither failure is visible from the side
-- that sent the offer.  The partner's own avatar is the one anchor both
-- clients already agree on: it is placed from presence this mod sent itself,
-- and it is the same projection the nameplates use.
--
-- A wild fight has no NPC to argue about and marks the same head for the same
-- reason, so there is one rule and no mode branch.
--
-- Read through Coop's own accessor rather than off its field, so the overlay
-- asks the same question the ACTIONS menu and the trainer trigger ask.  The
-- offer is read-only here: this module owns no part of the co-op handshake and
-- must never be the reason one resolves differently.
function M:offerMark()
  local coop = self.ctx and self.ctx.coop
  if not coop then return nil end
  local offer
  if type(coop.pendingOffer) == "function" then
    local ok, pending = pcall(coop.pendingOffer, coop)
    if ok and type(pending) == "table" then offer = pending end
  end
  -- ...and the latch, which is what actually raises this mark in the case it
  -- exists for.  A standing offer is the *rare* state: the common one is an
  -- offer that arrived, was accepted and was cleared inside a single inbound
  -- handler, before any tick of this loop could observe it (see Coop's
  -- `offerMarkFor`).  Reading the accessor alone meant polling a field that is
  -- never non-nil when it is looked at, which is a mark that never appears.
  --
  -- The accessor still comes first, so a live offer -- a busy or off-map
  -- partner, the one case where the two can disagree -- is answered by the
  -- same question the ACTIONS menu and the trainer trigger ask. The latch is
  -- read as a plain field because it is not part of the handshake at all: it
  -- is Coop's record of an arrival, kept for this renderer.
  if not offer and type(coop.offerMarkFor) == "table" then
    offer = coop.offerMarkFor
  end
  -- The offer's sender: the player who is standing at the fight waiting.
  local from = offer and (offer.from or offer.id)
  if not from then return nil end
  return {
    id = from,
    map = offer.map,
    battle = offer.battle,
    clock = 0,
    hold = ALERT_HOLD,
  }
end

-- The waiter's cell, remembered rather than looked up when it is wanted.
--
-- **It has to be remembered, because the avatar is about to disappear.**  The
-- instant the fight covers the waiter's overworld their client publishes a
-- presence with no map -- pushPresence reads World.current, which is nil under
-- a battle -- and that lands within one PRESENCE_INTERVAL (0.125s).  The
-- roster then drops them off this map and Avatars:sync despawns them.  All of
-- that is right for a nameplate, which should not float over an empty tile for
-- somebody who is not in the world any more, and exactly wrong for this mark,
-- whose entire subject is the fight they just walked into.  Looked up live,
-- the bubble would appear for about two frames and vanish -- and it would do
-- it consistently enough to look like a rendering bug rather than a race.
--
-- They are standing still at the fight, so the last cell anybody saw them in
-- is not a stale guess: it is where they are.
function M:trackAnchor(alert)
  if not alert then return end
  local ctx = self.ctx
  local avatars = ctx and ctx.avatars
  if avatars and type(avatars.cellOf) == "function" then
    -- Two returns; see drawAlertLayer for what an `and` would do to them.
    local ax, ay = avatars:cellOf(alert.id)
    if ax and ay then
      alert.wx, alert.wy = ax * CELL, ay * CELL
      return
    end
  end
  if alert.wx then return end
  -- Nothing spawned yet.  The roster's cell is a frame or two older and is the
  -- same number; it covers an offer that lands in the gap between a partner
  -- arriving on this map and their avatar being built.
  local roster = ctx and ctx.roster
  local player = roster and type(roster.get) == "function" and roster:get(alert.id)
  if player and tonumber(player.x) and tonumber(player.y) then
    alert.wx, alert.wy = player.x * CELL, player.y * CELL
  end
end

-- The mark's life, on the fixed step rather than on drawn frames.
--
-- Drawn frames are the wrong clock for two reasons: the bob would run at
-- whatever frame rate the machine managed, and -- worse -- draw() bails at the
-- free-roam gate, so a partner sitting in a menu while the offer stands would
-- never age the mark at all and would meet a full-length one on closing it.
function M:update(dt)
  dt = tonumber(dt) or 0
  local coop = self.ctx and self.ctx.coop
  -- The fight is *on* the screen.  Not "the join landed": `running` is set at
  -- the handoff, two relay round trips before the battle state is pushed, and
  -- the overworld -- the only thing this mark can be drawn over -- is still
  -- what the player is looking at for the whole of that gap.  Killing the mark
  -- on `running` threw away its entire life, which is why it was never seen.
  --
  -- The state is the honest end: from here the world is covered, the mark has
  -- nothing left to annotate, and what the joiner is owed instead is a line in
  -- the corner that outlives the push (Coop:toastLine).
  if coop and coop.state ~= nil then
    self.alert = nil
    return
  end

  local fresh = self:offerMark()
  local alert = self.alert
  if fresh then
    -- A different fight replaces the mark outright; the same one keeps its
    -- clock, so the bob is continuous across the frame the offer clears in.
    if not (alert and alert.id == fresh.id and alert.battle == fresh.battle) then
      self.alert = fresh
      alert = fresh
    end
    alert.hold = ALERT_HOLD
  elseif alert then
    alert.hold = alert.hold - dt
    -- Two clocks, and the mark lives until both have run out: ALERT_HOLD from
    -- the last tick the offer stood, ALERT_MIN from the tick it was raised.
    -- The grace alone is reactive and gives a long-standing offer the beat it
    -- needs to fade; the floor is what makes a mark that was raised and taken
    -- in the same second legible at all, which is every automatic join.  A
    -- mark whose fight reaches the screen inside the floor is still cut off
    -- there by the state check above -- correctly, since the world it points
    -- at is gone -- and the corner line carries the rest.
    if alert.hold <= 0 and alert.clock >= ALERT_MIN then
      self.alert = nil
      return
    end
  else
    return
  end
  alert.clock = alert.clock + dt
  -- Every tick, including the ones where the world is not being drawn: this is
  -- the clock that is still running while the partner sits in a menu, and the
  -- avatar it is watching does not wait for them to close it.
  self:trackAnchor(alert)
end

-- How far above its resting place the bubble sits, in game pixels.
--
-- A pure function of the mark's own clock: no per-frame state, so the same
-- second of the same offer draws at the same height whatever the frame rate,
-- and the suite can pin the curve without a graphics context.  One smooth arch
-- per period rather than a sawtooth -- the engine's emote pops, and a mark that
-- is going to sit on screen for seconds at a time should not.
function M.alertLift(clock)
  clock = tonumber(clock) or 0
  local phase = (clock % ALERT_PERIOD) / ALERT_PERIOD
  return ALERT_BOUNCE * math.sin(phase * math.pi)
end

-- The bubble itself: an ink silhouette with a white body inset inside it, so
-- the border is one shape rather than a stroke that has to be kept in step
-- with a fill.  `clearance` is window pixels of extra air -- the head this is
-- drawn over always carries a nameplate, and the mark has to clear it.
--
-- Returns false when the mark would be clipped by the playfield edge, which is
-- drawLabel's rule and for the same reason: half a bubble at the letterbox
-- reads as a rendering fault, and a mark nobody can read is worse than none.
function M:drawAlert(centreX, spriteTopY, lift, scale, gameX, gameY, clearance)
  scale = tonumber(scale) or 1
  gameX, gameY = tonumber(gameX) or 0, tonumber(gameY) or 0
  clearance = tonumber(clearance) or 0

  local w, h = ALERT_W * scale, ALERT_H * scale
  local tail = ALERT_TAIL * scale
  local cx = gameX + centreX * scale
  local bottom = gameY + (spriteTopY - ALERT_GAP) * scale
    - (tonumber(lift) or 0) * scale - clearance
  local x = math.floor(cx - w / 2)
  local y = math.floor(bottom - tail - h)
  if not onScreenWindow(x, y, w, h + tail, gameX, gameY, scale) then
    return false
  end
  cx = x + w / 2

  local line = math.max(1, math.floor(scale * 0.5 + 0.5))
  local radius = math.max(2, 3 * scale)

  -- A soft shadow under the whole shape: white on a snow tile or a Pokemon
  -- Center floor is otherwise a bubble with no edge on one side.
  love.graphics.setColor(0, 0, 0, 0.3)
  love.graphics.rectangle("fill", x + line, y + line, w, h, radius, radius)

  -- ink: body and point
  love.graphics.setColor(ALERT_INK[1], ALERT_INK[2], ALERT_INK[3], 1)
  love.graphics.rectangle("fill", x, y, w, h, radius, radius)
  love.graphics.polygon("fill", cx - tail, y + h - line, cx + tail, y + h - line,
                        cx, y + h + tail)

  -- white: the same two shapes, one border in from the edge
  love.graphics.setColor(ALERT_FILL[1], ALERT_FILL[2], ALERT_FILL[3], 1)
  love.graphics.rectangle("fill", x + line, y + line, w - line * 2, h - line * 2,
                          math.max(1, radius - line), math.max(1, radius - line))
  love.graphics.polygon("fill", cx - (tail - line), y + h - line * 2,
                        cx + (tail - line), y + h - line * 2,
                        cx, y + h + tail - line * 2)

  -- the glyph, as two strokes rather than a character: a bar and its dot.
  local barW = math.max(1, math.floor(2 * scale + 0.5))
  local barH = math.floor(h * 0.4)
  local gap = math.max(1, math.floor(scale * 0.7 + 0.5))
  local bx = math.floor(cx - barW / 2)
  local by = math.floor(y + h * 0.2)
  local nib = math.max(1, barW * 0.4)
  love.graphics.setColor(ALERT_INK[1], ALERT_INK[2], ALERT_INK[3], 1)
  love.graphics.rectangle("fill", bx, by, barW, barH, nib, nib)
  love.graphics.rectangle("fill", bx, by + barH + gap, barW, barW, nib, nib)
  return true
end

-- Put the live mark on screen, and say what became of it.
--
-- The answer is recorded on `last.alert` so an end-to-end driver can tell the
-- outcomes apart -- nothing standing (nil), the partner is a map away
-- (`off-map`), nobody ever saw them (`no-anchor`), the head is past the
-- letterbox (`off-screen`), another mod owns the projection (`not-flat`), and
-- drawn (`waiter`) -- none of which a screenshot distinguishes from "the
-- bubble is broken".
function M:drawAlertLayer(font, mapId, playerPx, playerPy, scale, gameX, gameY)
  local alert = self.alert
  if not alert then return nil end
  -- The partner is not on this screen, so there is no head to mark.  Asked of
  -- the offer rather than left to the avatar lookup because the two are
  -- different answers worth telling apart: "they are a map away" is the game
  -- working, "they are here and their avatar is not" is not.
  if alert.map and mapId and alert.map ~= mapId then return "off-map" end

  -- The waiter's avatar cell -- the same source drawLabel uses for their
  -- nameplate, so the mark and the name can never disagree about where they
  -- are standing, and the whole placement stays inside data this mod sent.
  --
  -- Refreshed here as well as on the step so a caller that only ever draws
  -- still gets a placed mark; trackAnchor is the one that makes it survive the
  -- avatar being despawned out from under it.
  self:trackAnchor(alert)
  -- Nobody has ever seen them: an offer for a map this client has no presence
  -- for yet.
  if not alert.wx then return "no-anchor" end

  -- They are wearing a nameplate, and the mark has to clear it.
  local clearance = font and (font:getHeight() + LABEL_GAP * scale) or 0

  local centreX, spriteTop = M.screenOf(alert.wx, alert.wy, playerPx, playerPy)
  if not self:drawAlert(centreX, spriteTop, M.alertLift(alert.clock),
                        scale, gameX, gameY, clearance) then
    return "off-screen"
  end
  return "waiter"
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

-- ------- the TOWN MAP (Gen 1) / POKeGEAR MAP (Gen 2)
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
-- Gen 2's MAP card is src.ui.gen2.Pokegear, not TownMap: different
-- coordinates (landmark index, Johto/Kanto regions) and no `byMap`. Soft
-- degrade -- recognise the screen and skip party portraits rather than
-- guessing cells or crashing on a missing Gen 1 TownMap module.
--
-- Identifying either screen needs `engine_internals`, which this mod already
-- declares: the mod API has no "what state is this" seam, and duck-typing on
-- field names would silently start drawing over some other mod's screen that
-- happened to have a `byMap`. The require is read-only and the failure is
-- soft -- no TownMap / Pokegear module means the layer simply never draws.
local townMapModule, townMapTried
local pokegearModule, pokegearTried

local function engineTownMap()
  if townMapTried then return townMapModule end
  townMapTried = true
  local ok, module = pcall(require, "src.ui.TownMap")
  if ok and type(module) == "table" then townMapModule = module end
  return townMapModule
end

local function enginePokegear()
  if pokegearTried then return pokegearModule end
  pokegearTried = true
  local ok, module = pcall(require, "src.ui.gen2.Pokegear")
  if ok and type(module) == "table" then pokegearModule = module end
  return pokegearModule
end

-- The live Gen 2 POKeGEAR (or Fly map) state, or nil. Soft-degrade only:
-- party marks are not drawn on this screen yet.
function M:pokegearState(top)
  if type(top) ~= "table" then return nil end
  local Pokegear = enginePokegear()
  if not Pokegear then return nil end
  if getmetatable(top) ~= Pokegear then return nil end
  return top
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

function M:drawTownMapSprites(state)
  local marks = self:townMapMarks(state)
  self.last.drawn = #marks
  if #marks == 0 then
    self.last.reached = "townmap-nobody"
    return marks
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
  end
  return marks
end

function M:drawTownMapLabels(font, marks, scale, gameX, gameY)
  for _, mark in ipairs(marks) do
    -- Nickname over their head, flipping under the sprite when the city is
    -- high enough that the label would land in the banner.
    local spriteTop = mark.y - 4
    if spriteTop - LABEL_GAP - font:getHeight() / scale < BANNER_H then
      spriteTop = mark.y + 12
    end
    self:drawLabel(font, mark.name, mark.x + 4, spriteTop, scale, gameX, gameY,
                   PARTY_GREEN)
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

  local labelFont = Toast.font(Toast.toastSize(scale))
  if not labelFont then
    last.reached = "no-font"
    return
  end

  -- Gen 2 POKeGEAR MAP: soft degrade. Landmark coordinates are not the Gen 1
  -- byMap grid; leave the gear unobstructed rather than guessing.
  if self:pokegearState(top) then
    last.reached = "pokegear-skip"
    return
  end

  -- The TOWN MAP is the one Gen 1 screen other than the world this overlay
  -- draws on, and for the opposite reason: there it says who is standing
  -- next to you, here it says where your friend is in Kanto.
  local townMap = self:townMapState(top)
  if townMap then
    last.reached = "townmap"
    local restore = self:beginFrame(scale, gameX, gameY)
    local marks = self:drawTownMapSprites(townMap)
    self:endFrame(restore)
    if marks and #marks > 0 then
      local hudRestore = beginHud()
      love.graphics.setFont(labelFont)
      self:drawTownMapLabels(labelFont, marks, scale, gameX, gameY)
      endHud(hudRestore)
    end
    return
  end


  -- render.hud composites over the *finished* frame -- menus and text boxes
  -- included -- so a nameplate drawn unconditionally lands on top of
  -- whatever UI is open. These labels annotate the world, so they are drawn
  -- only while the world is what the player is actually looking at.
  -- Gen 2 free-roam is an empty stack (top nil) with a live world.map; Gen 1
  -- still requires the overworld state itself to be on top.
  local world = mod.world
  local overworld = world and type(world.overworld) == "function" and world:overworld() or nil
  if not Gen.freeRoam(game, top) then
    last.reached = "not-overworld"
    return
  end
  if not overworld then
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

  local owPlayer = overworld.player
  local playerPx = owPlayer and owPlayer.px or (current.x * CELL)
  local playerPy = owPlayer and owPlayer.py or (current.y * CELL)

  local hudRestore = beginHud()
  love.graphics.setFont(labelFont)

  -- A Voxel world exports its own camera transform, so the plates can stay
  -- attached to heads. Other renderers still receive the safe corner list.
  if not self:worldIsFlat(game) then
    local windowW, windowH = love.graphics.getDimensions()
    local voxel = self:voxelApi(game)
    if voxel then
      local drew = false
      for _, player in ipairs(here) do
        local ax, ay = ctx.avatars:cellOf(player.id)
        if ax and ay then
          drew = self:drawVoxelNameplate(labelFont, game, overworld,
                                         self:nameFor(player), ax * CELL, ay * CELL,
                                         windowW, windowH, self:labelColor(player)) or drew
        end
      end
      if self:selfName(game) then
        drew = self:drawVoxelNameplate(labelFont, game, overworld,
                                       self:selfName(game), playerPx, playerPy,
                                       windowW, windowH, SELF_YELLOW) or drew
      end
      if drew then
        last.reached = "voxel-labels"
        endHud(hudRestore)
        return
      end
    end
    last.reached = "roster"
    -- The mark is placed by the flat camera's grid, the same as a nameplate,
    -- so a world drawn by somebody else's projection gets the corner list and
    -- no bubble rather than a bubble over the wrong tile.
    if self.alert then last.alert = "not-flat" end
    self:drawRoster(labelFont, here, scale, gameX, gameY, game)
    endHud(hudRestore)
    return
  end

  if #here == 0 and not self:selfName(game) then
    last.reached = "nobody-here"
    -- Still marked, and this is the branch that needs it most: the waiter's
    -- presence goes blank the moment their fight covers their world, so the
    -- roster reports nobody on this map at exactly the moment the mark is
    -- standing over the cell they were last seen in (see trackAnchor).
    last.alert = self:drawAlertLayer(labelFont, current.mapId, playerPx,
                                     playerPy, scale, gameX, gameY)
    endHud(hudRestore)
    return
  end

  last.reached = "labels"
  for _, player in ipairs(here) do
    -- the live avatar cell, which is where the sprite actually is mid-step
    local ax, ay = ctx.avatars:cellOf(player.id)
    if ax and ay then
      local centreX, spriteTop = M.screenOf(ax * CELL, ay * CELL,
                                            playerPx, playerPy)
      self:drawLabel(labelFont, self:nameFor(player), centreX, spriteTop,
                     scale, gameX, gameY, self:labelColor(player))
    end
  end
  self:drawSelfLabel(labelFont, game, playerPx, playerPy, scale, gameX, gameY)

  -- After the plates, so a bubble that lands on the waiter's own nameplate is
  -- over it rather than under it.  It is already lifted clear of one (see
  -- drawAlertLayer); this is the tie-break for the crowded case.
  last.alert = self:drawAlertLayer(labelFont, current.mapId, playerPx, playerPy,
                                   scale, gameX, gameY)

  endHud(hudRestore)
end

-- The party marker: the game's own cursor glyph, 0xED, as its three UTF-8
-- bytes.  Exported so the suite and the end-to-end driver build the expected
-- nameplate from the same source the renderer uses rather than each spelling
-- it out and drifting -- and spelling it out is exactly what a multi-byte
-- glyph makes easy to get subtly wrong.
M.PARTY_MARK = "\226\150\182"   -- U+25B6 BLACK RIGHT-POINTING TRIANGLE

M.VIEW_W, M.VIEW_H, M.CELL = VIEW_W, VIEW_H, CELL
M.ANCHOR_X, M.ANCHOR_Y = ANCHOR_X, ANCHOR_Y
M.CAM_X, M.CAM_Y, M.SPRITE_LIFT = CAM_X, CAM_Y, SPRITE_LIFT
M.PARTY_GREEN = PARTY_GREEN
M.SELF_YELLOW = SELF_YELLOW
M.FRIEND_BLUE = FRIEND_BLUE
-- Exported with the other two so the suite can name the *default* as well as
-- the exceptions: "everybody else is white" is the half of labelColor that
-- would otherwise only be assertable as "not one of the colours we know".
M.LABEL_WHITE = LABEL_WHITE
M.LOCAL_RADIUS = Config.LOCAL_RADIUS
-- The partner's "!": exported so the suite pins the bob and the grace against
-- the numbers the renderer actually uses rather than against its own copies.
M.ALERT_HOLD, M.ALERT_PERIOD, M.ALERT_BOUNCE = ALERT_HOLD, ALERT_PERIOD, ALERT_BOUNCE
M.ALERT_MIN = ALERT_MIN
M.ALERT_W, M.ALERT_H, M.ALERT_TAIL, M.ALERT_GAP = ALERT_W, ALERT_H, ALERT_TAIL, ALERT_GAP
M.ALERT_INK, M.ALERT_FILL = ALERT_INK, ALERT_FILL

return M
