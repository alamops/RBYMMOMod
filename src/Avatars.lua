-- Remote players as overworld NPCs.
--
-- Every other player on the local player's current map gets one runtime NPC
-- spawned through mod.world.  That is deliberately the whole trick: an NPC
-- already draws with the right sprite, sorts against the player by depth,
-- takes the map's palette, and animates a walk cycle.  Drawing avatars
-- ourselves would mean reimplementing all of it against engine internals
-- the mod API does not expose.
--
-- Movement starts a real animated step on the NPC, and this is the one
-- place the mod reaches past the WorldAPI facade -- deliberately, after the
-- supported route proved unusable.
--
-- The obvious primitive is Handle:scriptMove. It cannot be used here:
-- OverworldController gates the player's own controls on
-- `#self.scriptMoves > 0` (the `scripted` guard around handleInput),
-- because that queue exists for cutscenes, where freezing the player is the
-- *point*. Driving avatars through it locks the local player's input every
-- time a remote player takes a step -- on a busy map, permanently.
--
-- But the queue is only what *starts* a step. NPC:update owns the step
-- itself: given facing, targetX/targetY, moving and progress, it
-- interpolates px/py over 16 frames, lands on the target cell and flips the
-- walk frame, all from the overworld's ordinary per-frame NPC update. So
-- setting those five fields directly gets the full walk animation with none
-- of the input lock -- NPC:walkPhase() returns the standing frame whenever
-- `moving` is false, which is why simply placing the avatar left it sliding
-- between tiles without animating.
--
-- One tile is started per completed step, so an avatar walks the same way a
-- player does and catches up naturally: presence arrives at 8Hz and a step
-- takes 16 frames, so a remote player moving at walking pace stays in step.
-- When it falls further behind than RESYNC_DISTANCE (a warp we never saw, a
-- long stall), it is respawned rather than walked all the way.
--
-- A player moving at the fast pace is the same arithmetic with the 16
-- halved. NPC:update reads `stepFrames or 16` fresh every frame, so the
-- sixth field written below sets the pace of the step it starts:
-- FAST_STEP_FRAMES while the roster says that step was a fast one, and nil
-- -- back to the engine's own default -- the moment it says otherwise. At 8
-- frames a tile a fast avatar covers 0.133s per tile against a 0.125s
-- presence interval, still about one update per tile, so nothing about the
-- catch-up above needed rethinking.
--
-- One flag, two ways to earn it: a sprint and a bike both cost 8 frames a
-- tile, so cyclists ride at cycling pace here too. Before the wire carried
-- pace rather than "B is held", a remote cyclist stepped at 16 while their
-- real player covered tiles at 8, shed about 3.75 tiles a second and hit
-- RESYNC_DISTANCE over and over -- a despawn/respawn pop every couple of
-- seconds for the whole ride. That loop is closed: nothing a cyclist does
-- now outruns their own presence stream.
--
-- What the mod API is missing is a "step this NPC" primitive on Handle --
-- an upstream RFC, not something to fake with a cutscene queue.

local need, mod = ...
local Config = need("Config")

local M = {}
M.__index = M

-- set by the end-to-end driver via the debug export; off in normal play
M.TRACE = false

local DELTA = {
  up    = { 0, -1 },
  down  = { 0, 1 },
  left  = { -1, 0 },
  right = { 1, 0 },
}

local RANGE_OF = {
  up = "UP", down = "DOWN", left = "LEFT", right = "RIGHT",
}

function M.new()
  return setmetatable({
    spawned = {},   -- playerId -> { npcId, x, y, facing }
    mapId = nil,
    spriteWarned = {},
  }, M)
end

-- NPC.new asserts on a sprite the data catalog does not carry, and that
-- assert would fire inside the engine's own spawn path where this mod
-- cannot catch it.  Checking first turns an unknown sprite into a
-- documented fallback instead of a crash attributed to the overworld.
function M:spriteFor(requested)
  local sprites = mod.content.sprites
  if sprites and requested and sprites:get(requested) then return requested end
  if requested and not self.spriteWarned[requested] then
    self.spriteWarned[requested] = true
    mod.log:warn("sprite %s is not in this game's catalog; drawing that "
      .. "player as %s instead", tostring(requested), Config.DEFAULT_SPRITE)
  end
  if sprites and sprites:get(Config.DEFAULT_SPRITE) then
    return Config.DEFAULT_SPRITE
  end
  return nil
end

function M:handle(av)
  if not (av and av.npcId and self.mapId) then return nil end
  local handle = mod.world:npc(self.mapId, av.npcId)
  return handle
end

function M:spawn(player)
  if not (player.map and player.x and player.y) then return nil end
  local sprite = self:spriteFor(player.sprite)
  if not sprite then
    -- no usable sprite at all: stay silent per player, the warn above
    -- already named the cause once
    return nil
  end

  local npcId = mod.world:spawnNpc(player.map, {
    sprite = sprite,
    x = player.x,
    y = player.y,
    movement = "STAY",           -- never wander; the network is the authority
    range = RANGE_OF[player.facing] or "DOWN",
    name = "mmo_" .. player.id,
  })
  if not npcId then return nil end

  self.spawned[player.id] = {
    npcId = npcId,
    x = player.x,
    y = player.y,
    facing = player.facing,
  }
  return npcId
end

function M:despawn(playerId)
  local av = self.spawned[playerId]
  if not av then return false end
  self.spawned[playerId] = nil
  mod.world:removeNpc(av.npcId)
  return true
end

function M:clear()
  for id in pairs(self.spawned) do self:despawn(id) end
  self.spawned = {}
end

-- where an avatar actually is right now, for the overlay's nameplate.  The
-- live NPC is the authority mid-step: self.spawned holds the cell the
-- network last confirmed, which is where the avatar is *going*.
function M:cellOf(playerId)
  local av = self.spawned[playerId]
  if not av then return nil end
  local handle = self:handle(av)
  local npc = handle and handle.npc
  -- Pixel position expressed in cells, so the nameplate glides with the
  -- sprite through a step instead of jumping a whole tile when it lands.
  if npc and npc.px and npc.py then return npc.px / 16, npc.py / 16 end
  if handle then
    local x, y = handle:position()
    if x and y then return x, y end
  end
  return av.x, av.y
end

-- whether the avatar is mid-step right now; the end-to-end driver asserts
-- this is ever true, which is what proves the walk actually animates
function M:isWalking(playerId)
  local av = self.spawned[playerId]
  if not av then return false end
  local handle = self:handle(av)
  local npc = handle and handle.npc
  return npc ~= nil and npc.moving == true
end

function M:resync(player)
  self:despawn(player.id)
  return self:spawn(player)
end

-- The next single tile to walk toward a destination, or nil when already
-- there.  Pure, so the routing is testable without an overworld: one axis
-- at a time, x first, because the grid has no diagonal step.
function M.stepToward(fromX, fromY, toX, toY)
  local dx, dy = toX - fromX, toY - fromY
  if dx == 0 and dy == 0 then return nil end
  if dx ~= 0 then
    local sign = dx > 0 and 1 or -1
    return (sign > 0 and "right" or "left"), fromX + sign, fromY
  end
  local sign = dy > 0 and 1 or -1
  return (sign > 0 and "down" or "up"), fromX, fromY + sign
end

function M:advance(av, player)
  -- av.x/av.y is the network's truth -- where the player *is*. The NPC's
  -- own cellX/cellY is where the avatar has walked to so far, and it is
  -- allowed to lag by a step or two while it catches up.
  av.x, av.y = player.x, player.y

  local handle = self:handle(av)
  local npc = handle and handle.npc
  if not npc then return self:resync(player) end

  -- mid-step: let NPC:update finish it. Interrupting would strand px/py
  -- between two cells.
  if npc.moving then return end

  local dir, tx, ty = M.stepToward(npc.cellX, npc.cellY, player.x, player.y)

  if not dir then
    if player.facing and npc.facing ~= player.facing then
      npc.facing = player.facing
      av.facing = player.facing
    end
    return
  end

  if M.TRACE then
    mod.log:info("step %s %s from (%d,%d) toward (%s,%s)", tostring(player.id),
      dir, npc.cellX, npc.cellY, tostring(player.x), tostring(player.y))
  end

  -- Too far behind to walk back: rebuild at the true cell rather than
  -- march the avatar across the map.
  if math.max(math.abs(player.x - npc.cellX),
              math.abs(player.y - npc.cellY)) > Config.RESYNC_DISTANCE then
    return self:resync(player)
  end

  -- The five fields NPC:update needs to animate a step itself, plus the one
  -- that decides how long it takes.
  npc.facing = dir
  npc.targetX, npc.targetY = tx, ty
  npc.moving = true
  npc.marching = false
  npc.progress = 0
  -- Set per step rather than once, because the flag is per step: clearing it
  -- to nil hands the pace back to NPC:update's own default instead of
  -- leaving the avatar sprinting after its player stopped.
  npc.stepFrames = player.fast and Config.FAST_STEP_FRAMES or nil
  av.facing = dir
  return true
end

-- One pass per tick.  `current` is mod.world:current() -- nil whenever
-- there is no overworld up (title screen, a battle), in which case every
-- avatar is dropped and rebuilt on the way back.
function M:sync(roster, current)
  -- mod.world materialises on first touch and answers nil until a Game
  -- exists; every method below goes through it, so this is the one gate
  if not mod.world then return end

  if not current or not current.mapId then
    if next(self.spawned) then self:clear() end
    self.mapId = nil
    return
  end

  -- A map change rebuilds from scratch: runtime objects belong to the map
  -- they were spawned on, and the engine only instantiates them while that
  -- map is the active one.
  if current.mapId ~= self.mapId then
    self:clear()
    self.mapId = current.mapId
  end

  local seen = {}
  for _, player in ipairs(roster:onMap(current.mapId)) do
    seen[player.id] = true
    local av = self.spawned[player.id]
    if av then self:advance(av, player) else self:spawn(player) end
  end

  for id in pairs(self.spawned) do
    if not seen[id] then self:despawn(id) end
  end
end

M.DELTA = DELTA

return M
