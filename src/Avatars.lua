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
    spawned = {},   -- playerId -> { npcId, x, y, facing, npc }
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

-- Applies the depth nudge below and then hands back whatever the wrapped
-- method returned.  The values arrive here as varargs, so the engine
-- method's own arity is forwarded whole -- NPC:update returns nothing today
-- and Player:update returns a value, so the contract is not one to guess --
-- and no table is allocated to do it, on a path that runs once per avatar
-- per frame.
local function nudged(self, ...)
  local py = self.py
  if py and py % 1 == 0 then
    self.py = py - Config.AVATAR_DEPTH_NUDGE
  end
  return ...
end

-- Avatars are scenery, not obstacles -- and they lose every tie for depth.
--
-- Both halves are written straight onto the live NPC, because neither has a
-- seam on the facade.  `passable` is the engine's own escape hatch:
-- Collision.occupied skips any entity carrying it, which is exactly how the
-- engine keeps its Pikachu follower out of the player's way.  Wrapping
-- movement.collision instead would not cover it -- ledge hops and boulder
-- landings ask Collision.occupied directly, so a wrapper would leave
-- avatars blocking the steps that hurt most, doors and map exits included.
--
-- Depth is the other half.  The overworld draws by sorting entities on py,
-- and that sort is unstable, so two characters standing on one tile trade
-- places from frame to frame; there is no z-order to ask for.  Lifting the
-- avatar by AVATAR_DEPTH_NUDGE loses it every tie against the player, whose
-- py is always a whole pixel.  It has to be applied *after* NPC:update
-- rather than from this mod's own tick: the engine recomputes py mid-step
-- -- and only while `moving` -- so a value written from the pump is
-- overwritten before the frame is drawn.  Hence a per-instance override
-- that runs the class method first, and the whole-pixel guard that keeps an
-- idle avatar from drifting a hundredth of a pixel every frame it stands
-- still.
--
-- But py is not only a sort key, and a hundredth of a pixel is not free
-- everywhere: SpriteRenderer floors `py - camY` and camY is whole, so a
-- sprite drawn straight off the nudged value sits a whole pixel high for as
-- long as it stands still.  So the nudge is confined to the sort.  A second
-- per-instance override on pose -- the one call both the flat and the
-- tilted draw path go through, seven values wide -- hands the renderer the
-- true pixel back, and cellOf does the same for anything reading a position
-- out of the avatar layer.  Shadowing a method on the instance is the
-- engine's own idiom here: its Pikachu follower does exactly this to
-- walkPhase.
--
-- Nothing is written until both class methods are in hand, because a
-- half-decorated NPC would be passable and marked, and the marker is what
-- stops advance from ever retrying it.
--
-- undecorate has to leave the table indistinguishable from a vanilla one.
-- The engine pools NPC tables, so a leftover `passable` would be born again
-- on some later ordinary NPC and quietly let the player walk through it.
-- Whatever was in the two slots beforehand goes back, rather than nil:
-- nothing promises they were empty.
function M.decorate(npc)
  if type(npc) ~= "table" or npc.mmoAvatar then return end

  -- resolves through the metatable to the engine's class methods -- unless
  -- something already shadowed one on this instance, in which case that is
  -- what gets wrapped and what has to be put back
  local baseUpdate, basePose = npc.update, npc.pose
  if type(baseUpdate) ~= "function" or type(basePose) ~= "function" then
    return
  end

  npc.mmoPrevUpdate = rawget(npc, "update")
  npc.mmoPrevPose = rawget(npc, "pose")
  npc.mmoAvatar = true
  npc.passable = true

  rawset(npc, "update", function(self, ...)
    -- arguments are evaluated first, so the base call has already
    -- recomputed py by the time the nudge is applied to it
    return nudged(self, baseUpdate(self, ...))
  end)

  rawset(npc, "pose", function(self, ...)
    -- NPC:pose -- sheet, px, py, facing, walk phase, step flip, hop flag
    local sprite, px, py, facing, phase, flip, hop = basePose(self, ...)
    if py then py = py + Config.AVATAR_DEPTH_NUDGE end
    return sprite, px, py, facing, phase, flip, hop
  end)
end

function M.undecorate(npc)
  -- a table this mod never decorated owns its own slots; leave them alone
  if type(npc) ~= "table" or not npc.mmoAvatar then return end
  local prevUpdate, prevPose = npc.mmoPrevUpdate, npc.mmoPrevPose
  npc.mmoAvatar = nil
  npc.passable = nil
  npc.mmoPrevUpdate = nil
  npc.mmoPrevPose = nil
  -- nil in the ordinary case, which is back to the class method via the
  -- metatable
  rawset(npc, "update", prevUpdate)
  rawset(npc, "pose", prevPose)
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

  -- A handle the engine will not hand over yet is not a failed spawn: the
  -- avatar is already on the map, and advance re-decorates on the next tick.
  local handle = self:handle(self.spawned[player.id])
  local npc = handle and handle.npc
  -- kept because despawn cannot ask for it again; see there
  self.spawned[player.id].npc = npc
  M.decorate(npc)
  return npcId
end

function M:despawn(playerId)
  local av = self.spawned[playerId]
  if not av then return false end
  self.spawned[playerId] = nil
  -- The table itself, held since it was decorated, because the handle is no
  -- use here: WorldAPI:npc answers nil the moment its map stops being the
  -- active one, or there is no overworld at all -- which is precisely the
  -- map change and the walk into a battle, the two paths that despawn every
  -- avatar at once.  Looking it up there would skip undecorate exactly when
  -- the most tables are going back in the pool.
  local npc = av.npc
  if not npc then
    local handle = self:handle(av)
    npc = handle and handle.npc
  end
  M.undecorate(npc)
  av.npc = nil
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
  if npc and npc.px and npc.py then
    -- with the depth nudge taken back off, the same way pose does it for
    -- the renderer: the lift is a tie-breaker for the draw sort and nothing
    -- else, and a caller comparing this against the roster's cell is
    -- entitled to the number the network agreed on.  A whole py is one the
    -- nudge has not been applied to yet (freshly decorated, not yet
    -- updated), so the fraction is the test.
    local py = npc.py
    if npc.mmoAvatar and py % 1 ~= 0 then
      py = py + Config.AVATAR_DEPTH_NUDGE
    end
    return npc.px / 16, py / 16
  end
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

-- A player who changed character while we were looking at them.
--
-- The sprite is read exactly once, in spawn: the sheet is baked into the
-- NPC at creation and neither advance nor sync ever consults player.sprite
-- again, so the only way to re-render an avatar is to build a new one.
-- resync is already that pair, written for the avatar that fell too far
-- behind, and it re-reads the roster entry the caller has just updated.
--
-- Only for a player who has an avatar up right now.  Somebody on another
-- map has none to rebuild and needs none: the next sync spawns them from
-- the same roster entry, wearing the new character on the way in.
--
-- sync opens with the world gate and calls itself the one gate for world
-- touches, but this is the other way in: refresh runs from the inbound
-- dispatch, in the client's tick, and reaches removeNpc/spawnNpc through
-- resync without passing sync at all.  So the same gates are repeated here
-- rather than inherited.  A nil mod.world would otherwise throw where the
-- tick's pcall turns it into a disconnect -- a cosmetic message costing the
-- player their session.
function M:refresh(player)
  if type(player) ~= "table" or player.id == nil then return nil end
  if not mod.world then return nil end
  if not self.spawned[player.id] then return nil end
  -- The roster entry can already have moved on: a [MOVE-to-another-map,
  -- SPRITE] batch updates the map before this runs, and respawning here
  -- would put an avatar on a map that is not the active one for sync to
  -- clean up on the next tick.  Nothing is lost by declining -- the same
  -- reasoning as above, they spawn as their new self when they come into
  -- view.
  if player.map ~= self.mapId then return nil end
  return self:resync(player)
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
  av.npc = npc

  -- Heals an avatar the engine rebuilt under us, and costs one comparison
  -- when it did not: decorate returns immediately on an already-marked NPC.
  M.decorate(npc)

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
