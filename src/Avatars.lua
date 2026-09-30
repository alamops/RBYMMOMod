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
--
-- ------- Gen 3 (FireRed / LeafGreen / Emerald)
--
-- The same idea on a different engine, and with one more reach-around,
-- because the first rung is missing: the game3 WorldAPI has no spawnNpc
-- (src/world/game3/WorldAPI.lua answers "not supported on FireRed yet"), and
-- its removeNpc sets a template object's hide flag rather than removing
-- anything.  A remote player is therefore a real event object built the way
-- the engine builds its own -- Objects.spawnFromDefs, from a template
-- Gen.spawnObjDef describes -- and put into the live object list by hand
-- (Objects._byId / Objects._order).  From there the engine does all of it:
-- FieldView draws it with the cart's own overworld sheet, sorts it against
-- the player and the map's NPCs, and animates its step cycle.  The owner
-- chose this over drawing avatars ourselves (no depth) and over the Union
-- Room's VirtualObjects (no walk animation); the Lane B proposal asking
-- upstream for the missing seam is docs/upstream/gen3-spawn-npc.md.
--
-- What that costs, and how each cost is paid:
--
--   * Objects.loadMap wipes the list on every map load and every same-map
--     reload.  Each tick re-checks that the object in the list under an
--     avatar's localId is still the one this file put there, and puts it
--     back when it is not -- so a reload is healed on the very next tick,
--     with the avatar exactly where it stood.
--   * LocalIds are Config.GEN3_AVATAR_LOCAL_ID_BASE + n: past 0xFF, so no
--     script opcode (a byte) can address one and no seamless-edge carry id
--     (0xC0..0xFE) can collide with one.
--   * Steps are started with Objects.pushStep, which is the engine's own
--     "begin one step of N frames" with no movement track behind it.  A
--     track (startTrack) would work too, but Objects.carryOut carries every
--     object with a live track across a seamless map edge and renumbers it,
--     so an avatar mid-track while the local player crosses into the next
--     town would follow them there under a borrowed id.
--   * The object carries `passable`, the engine's own escape hatch in
--     Objects.blocks, so an avatar never stands in the local player's way.
--   * Its template carries a script key no map has (TALK_KEY): that is what
--     makes Field.interact raise the `world.talk` hook for it at all (the
--     hook only runs for an object with a script).  The hook link installed
--     below answers for an avatar by not calling next(), so the engine
--     neither freezes it nor tries to start a script that does not exist --
--     and Field.interact then emits world.interacted with the avatar's cell
--     and kind "npc", which is the event Client's facing-A listener already
--     turns into the ACTIONS menu on Gen 1 and Gen 2.
--   * A standing avatar's py sits AVATAR_DEPTH_NUDGE above its cell, the
--     Gen 1 rule: FieldView sorts equal draw priorities by py and then by
--     localId, and the player's actor has none -- so without it an avatar
--     standing on the player's tile would be drawn over them.  The sprite is
--     drawn from the unfloored py, and a hundredth of a pixel rasterises to
--     the same pixels; cellOf takes it back off.
--   * Pace: pushStep is told 16, 8 or 4 frames a tile.  `fast` (a sprint or a
--     bike, as the sender reports it) takes 8; an avatar that has fallen
--     behind catches up at 8 from two tiles and at 4 (Mach Bike pace) from
--     four, so a cyclist is followed rather than respawned.  The field is
--     frozen while any menu is up, avatars included; they finish the walk
--     when it closes.

local need, mod = ...
local Config = need("Config")
local Gen = need("Gen")
local Gen3 = need("Gen3")
local Chars = need("Chars")

local M = {}
M.__index = M

-- set by the end-to-end driver via the debug export; off in normal play
M.TRACE = false

-- ------- Gen 3 constants

-- The script key an avatar's template carries (see the header).  Not a key
-- any map's script bundle has, and never started: the world.talk link below
-- returns before the engine's talk would.
local TALK_KEY = "rby_mmo:avatar"

-- Frames per tile for a step, by how far behind the network's cell the
-- avatar is when it starts it.  16 is the engine's walk, 8 its run
-- (objects.lua RUN_FRAMES), 4 the Mach Bike; all three are rows of the
-- engine's STEP_PIXELS table, so each one moves in whole pixels.
local GEN3_WALK_FRAMES = 16
local GEN3_FAST_FRAMES = 8
local GEN3_RUSH_FRAMES = 4
local GEN3_FAST_LAG = 2
local GEN3_RUSH_LAG = 4

M.TALK_KEY = TALK_KEY
M.GEN3_WALK_FRAMES, M.GEN3_FAST_FRAMES, M.GEN3_RUSH_FRAMES =
  GEN3_WALK_FRAMES, GEN3_FAST_FRAMES, GEN3_RUSH_FRAMES
M.GEN3_FAST_LAG, M.GEN3_RUSH_LAG = GEN3_FAST_LAG, GEN3_RUSH_LAG

-- The engine's object module, or nil off Gen 3 / when it is missing.
local function objects3()
  return Gen3.engine("src.core.game3.objects")
end

-- Is this a Gen 3 boot?  The cheap test (a field read on the mod facade), so
-- the per-tick dispatch below costs Gen 1 and Gen 2 nothing.
local function onGen3()
  return Gen3.active()
end

-- An event object this file injected, whatever table it is handed.
local function isAvatar3(eo)
  if type(eo) ~= "table" then return false end
  if eo.mmoAvatar ~= nil then return true end
  local def = eo.def
  return type(def) == "table" and def.mmoAvatar ~= nil
end
M.isAvatar3 = isAvatar3

-- The Gen 3 seams this file needs from the engine, installed once per load.
--
-- world.talk is the A press on an event object that has a script.  An avatar
-- has one (TALK_KEY) precisely so the press reaches here; answering for it
-- means not calling next(), which is the hook's documented way to consume a
-- talk (docs/modding.md, `world.talk`).  Everything else falls through.
local installed3 = false
local function install3()
  if installed3 then return end
  installed3 = true
  if not (mod.hooks and type(mod.hooks.wrap) == "function") then return end
  mod.hooks:wrap("world.talk", function(nextFn, game, eo, ...)
    if isAvatar3(eo) then return end
    return nextFn(game, eo, ...)
  end)
end

local DELTA = {
  up    = { 0, -1 },
  down  = { 0, 1 },
  left  = { -1, 0 },
  right = { 1, 0 },
}

function M.new()
  -- The Gen 3 hook link goes in with the first instance, which Client makes
  -- while the entry chunk runs -- i.e. at load, where a hook belongs.
  if onGen3() then install3() end
  return setmetatable({
    spawned = {},   -- playerId -> { npcId, x, y, facing, npc } (Gen 3: { lid, eo, ... })
    mapId = nil,
    spriteWarned = {},
    lids = {},      -- Gen 3: localId -> playerId, for the ids in use
  }, M)
end

-- NPC.new asserts on a sprite the data catalog does not carry, and that
-- assert would fire inside the engine's own spawn path where this mod
-- cannot catch it.  Checking first turns an unknown sprite into a
-- documented fallback instead of a crash attributed to the overworld.
function M:spriteFor(requested)
  if onGen3() then return self:spriteFor3(requested) end
  local sprites = mod.content.sprites
  local resolved = Gen.resolveSprite(nil, requested, sprites)
  if requested and resolved and requested ~= resolved
     and not self.spriteWarned[requested] then
    self.spriteWarned[requested] = true
    mod.log:warn("sprite %s is not in this game's catalog; drawing that "
      .. "player as %s instead", tostring(requested), tostring(resolved))
  end
  if resolved and sprites and sprites:get(resolved) then return resolved end
  return nil
end

-- Gen 2 WorldAPI:npc matches def.name / def.index only (not npc.id). Prefer
-- the spawn name, then the returned npcId, then the _obj_N index parsed out
-- of that id so a rebuilt pool still resolves.
function M:handle(av)
  if not (av and self.mapId and mod.world) then return nil end
  local name = av.name or (av.id and Gen.avatarName(av.id))
  if name then
    local handle = mod.world:npc(self.mapId, name)
    if handle then return handle end
  end
  if av.npcId then
    local handle = mod.world:npc(self.mapId, av.npcId)
    if handle then return handle end
    local index = tostring(av.npcId):match("_obj_(%d+)$")
    if index then
      handle = mod.world:npc(self.mapId, tonumber(index))
      if handle then return handle end
    end
  end
  return nil
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
  if onGen3() then return self:spawn3(player) end
  if not (player.map and player.x and player.y) then return nil end
  local sprite = self:spriteFor(player.sprite)
  if not sprite then
    -- no usable sprite at all: stay silent per player, the warn above
    -- already named the cause once
    return nil
  end

  -- Gen.spawnObjDef picks STAY+range (Gen 1) or numeric STANDING_* (Gen 2);
  -- the network is still the authority either way -- never wander.
  local name = Gen.avatarName(player.id)
  local npcId = mod.world:spawnNpc(player.map, Gen.spawnObjDef(player, sprite, mod.game))
  if not npcId then return nil end

  self.spawned[player.id] = {
    npcId = npcId,
    name = name,
    id = player.id,
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
  if onGen3() then return self:despawn3(playerId) end
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
  if onGen3() then return self:cellOf3(playerId) end
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
  if onGen3() then return self:isWalking3(playerId) end
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
  -- Gen 3 touches the engine's object list, not mod.world, so its gate is
  -- that module being there (refresh3); the rest of the rule is the same.
  if onGen3() then return self:refresh3(player) end
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
  if onGen3() then return self:advance3(av, player) end
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
  if onGen3() then return self:sync3(roster, current) end
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

-- ------- the Gen 3 arm
--
-- Same contract as everything above -- spawned[playerId] is the avatar, sync
-- is the one per-tick pass, cellOf / isWalking answer the overlay and the
-- drivers -- over the engine's event objects instead of mod.world's NPCs.
-- See the Gen 3 part of the header for why each piece is the way it is.

-- The map def the engine built this map's objects from.
local function mapDef3(mapId)
  local ok, def = pcall(function()
    local game = mod.game
    local maps = game and game.data and game.data.maps
    return type(maps) == "table" and maps[mapId] or nil
  end)
  if ok and type(def) == "table" then return def end
  return nil
end

-- Put an avatar's object into the live list (again).  O(1) when it is
-- already there, which is every tick but the first after a load.
local function inject3(Objects, av)
  local byId, order = Objects._byId, Objects._order
  if type(byId) ~= "table" or type(order) ~= "table" then return false end
  if byId[av.lid] == av.eo then return true end
  byId[av.lid] = av.eo
  for i = 1, #order do
    if order[i] == av.lid then return true end
  end
  order[#order + 1] = av.lid
  return true
end

-- ...and take it out.  Only ever *this* object: after a map load the slot
-- is empty and the order list is a new one, and there is nothing to undo.
-- Not called from inside Objects.update (sync runs from the input pump,
-- before the field tick), so the removal cannot disturb the engine's walk
-- over the list.
local function extract3(Objects, av)
  local byId, order = Objects._byId, Objects._order
  if type(byId) == "table" and byId[av.lid] == av.eo then byId[av.lid] = nil end
  if type(order) == "table" then
    for i = #order, 1, -1 do
      if order[i] == av.lid then table.remove(order, i) end
    end
  end
  if type(Objects._tracks) == "table" then Objects._tracks[av.lid] = nil end
end

-- The depth nudge, for a standing avatar on a whole pixel.  A moving one is
-- left alone: tickMotion rewrites py from the cell every frame of a step.
function M.nudge3(eo)
  if type(eo) ~= "table" or eo.moving then return end
  local py = tonumber(eo.py)
  if py and py % 1 == 0 then eo.py = py - Config.AVATAR_DEPTH_NUDGE end
end

-- Snap an avatar to a cell with no animation: the resync for a player too
-- far gone to walk after (a warp within the map, a long stall).  The same
-- fields finishStep leaves behind, so the engine sees an object that simply
-- stands there.
function M.placeAt3(eo, x, y, facing)
  eo.cellX, eo.cellY = x, y
  eo.targetX, eo.targetY = x, y
  eo.homeX, eo.homeY = x, y
  eo.px, eo.py = x * 16, y * 16
  eo.moving, eo.progress = false, 0
  if type(eo.def) == "table" then eo.def.x, eo.def.y = x, y end
  if DELTA[facing] then eo.facing = facing end
  local Objects = objects3()
  if Objects and type(Objects.updateElevation) == "function" then
    pcall(Objects.updateElevation, eo)
  end
end

-- Frames per tile for the step an avatar is about to take.  Pure; see the
-- header for the numbers.  `lag` counts the step being started.
function M.stepFrames3(lag, fast)
  lag = tonumber(lag) or 0
  if lag >= GEN3_RUSH_LAG then return GEN3_RUSH_FRAMES end
  if fast or lag >= GEN3_FAST_LAG then return GEN3_FAST_FRAMES end
  return GEN3_WALK_FRAMES
end

-- Is the *local* player moving at the fast pace right now?  The movement.speed
-- hook Gen 1 and Gen 2 learn this from never fires on Gen 3 (the carts have
-- running shoes and bikes of their own), so the engine's player is read
-- directly: running, on a bike, or mid-step at anything under the walk.
-- The value Client's presence `fast` flag wants on a Gen 3 boot.
function M.localFast3()
  local P = Gen3.engine("src.core.game3.player")
  if type(P) ~= "table" then return false end
  if P.biking == true or P.running == true then return true end
  local frames = tonumber(P.stepFrames)
  return P.moving == true and frames ~= nil and frames < GEN3_WALK_FRAMES
end

function M:allocLid3(playerId)
  local base = Config.GEN3_AVATAR_LOCAL_ID_BASE
  for n = 0, 0xFF do
    local lid = base + n
    if self.lids[lid] == nil then
      self.lids[lid] = playerId
      return lid
    end
  end
  return nil
end

function M:freeLid3(lid)
  if lid ~= nil then self.lids[lid] = nil end
end

-- The graphic a remote player is drawn with on this cart: (id, name).
--
-- `sprite` is a graphic name on the *sender's* cart (contract C3) and their
-- version rides beside it, so Chars.gfxForViewer is the whole answer --
-- the look table for a look both families have, the carts' link rule for the
-- rest.  A name nothing recognises (neither a look, nor a graphic here, nor
-- the hub's sprite-less token) is worth one line in the log: it is a
-- sender this cart cannot draw faithfully, and it is drawn as the link rule
-- says instead.
function M:spriteFor3(requested, player)
  local version = type(player) == "table" and player.version or nil
  local gender = type(player) == "table" and tonumber(player.gender) or nil
  local id, name = Chars.gfxForViewer(requested, version, gender)
  if not id then
    local s = Gen3.session()
    name = Gen3.playerGfxName(s and s.gender)
    id = name and Gen3.gfxId(name) or nil
  end
  if type(requested) == "string" and requested ~= Config.DEFAULT_SPRITE_GEN3
      and not Chars.look(requested) and not Gen3.gfxId(requested)
      and not self.spriteWarned[requested] then
    self.spriteWarned[requested] = true
    mod.log:warn("sprite %s is not a look this cart knows; drawing that "
      .. "player as %s instead", tostring(requested), tostring(name))
  end
  return id, name
end

function M:spawn3(player)
  if not (type(player) == "table" and player.id ~= nil and player.map
          and tonumber(player.x) and tonumber(player.y)) then
    return nil
  end
  local Objects = objects3()
  if not (Objects and type(Objects.spawnFromDefs) == "function") then return nil end
  local gfx, gfxName = self:spriteFor3(player.sprite, player)
  if not gfx then return nil end
  local lid = self:allocLid3(player.id)
  if not lid then return nil end

  -- Gen.spawnObjDef's Gen 3 template: cell, facing, graphic, MOVEMENT_TYPE_NONE
  -- (stands where it is put, turns only when driven).  The rest is this
  -- file's: the localId, and the three fields that make it an avatar.
  local def = Gen.spawnObjDef(player, gfx, mod.game)
  def.localId = lid
  def.graphicsId = gfx
  def.mapId = player.map
  def.passable = true
  def.scriptKey = TALK_KEY
  def.mmoAvatar = player.id

  local ok, pool = pcall(Objects.spawnFromDefs, { def }, mapDef3(player.map), player.map)
  local eo = ok and type(pool) == "table" and type(pool.byId) == "table"
    and pool.byId[lid] or nil
  if type(eo) ~= "table" then
    self:freeLid3(lid)
    if not self.spawnWarned then
      self.spawnWarned = true
      mod.log:warn("could not place another player on this map (%s); they "
        .. "stay on the roster and appear on the next map you enter -- report "
        .. "this with the line above if it keeps happening",
        tostring(ok and "no object" or pool))
    end
    return nil
  end
  -- Written on the object as well as carried on its template: the engine
  -- reads `passable` off the object, and the marker is what the world.talk
  -- link tests.
  eo.passable = true
  eo.mmoAvatar = player.id

  local av = {
    id = player.id, lid = lid, eo = eo, name = def.name,
    x = player.x, y = player.y, facing = eo.facing,
    gfx = gfx, gfxName = gfxName, sprite = player.sprite,
  }
  self.spawned[player.id] = av
  inject3(Objects, av)
  M.nudge3(eo)
  return lid
end

function M:despawn3(playerId)
  local av = self.spawned[playerId]
  if not av then return false end
  self.spawned[playerId] = nil
  local Objects = objects3()
  if Objects then extract3(Objects, av) end
  self:freeLid3(av.lid)
  return true
end

-- Where the avatar is right now, in cells: its cell while it stands (the
-- nudge is a draw-order tie-break and nothing else), its pixel position
-- mid-step so a nameplate glides with it.
function M:cellOf3(playerId)
  local av = self.spawned[playerId]
  if not av then return nil end
  local eo = av.eo
  if type(eo) == "table" then
    if not eo.moving and eo.cellX and eo.cellY then return eo.cellX, eo.cellY end
    if eo.px and eo.py then return eo.px / 16, eo.py / 16 end
  end
  return av.x, av.y
end

function M:isWalking3(playerId)
  local av = self.spawned[playerId]
  return av ~= nil and type(av.eo) == "table" and av.eo.moving == true
end

-- A new character on an avatar that is up: the graphic is swapped on the
-- live object, which keeps its cell and any step in flight -- a Gen 3 object
-- draws from its graphicsId every frame, so there is nothing to rebuild.
-- The template gets it too, because Objects.refreshGraphics re-reads it.
function M:refresh3(player)
  if not objects3() then return nil end
  local av = self.spawned[player.id]
  if not av then return nil end
  if player.map ~= self.mapId then return nil end
  local gfx, gfxName = self:spriteFor3(player.sprite, player)
  if not gfx then return nil end
  av.eo.graphicsId = gfx
  if type(av.eo.def) == "table" then av.eo.def.graphicsId = gfx end
  av.gfx, av.gfxName, av.sprite = gfx, gfxName, player.sprite
  return av.lid
end

function M:advance3(av, player)
  av.x, av.y = player.x, player.y
  local Objects = objects3()
  if not Objects then return nil end
  local eo = av.eo

  -- A reload wiped the list under us: the same object goes straight back,
  -- where it stood.
  if type(Objects._byId) == "table" and Objects._byId[av.lid] ~= eo then
    inject3(Objects, av)
  end

  -- mid-step: tickMotion finishes it
  if eo.moving then return nil end

  local dir = M.stepToward(eo.cellX, eo.cellY, player.x, player.y)
  if not dir then
    if DELTA[player.facing] and eo.facing ~= player.facing then
      eo.facing = player.facing
      av.facing = player.facing
    end
    M.nudge3(eo)
    return nil
  end

  local lag = math.max(math.abs(player.x - eo.cellX), math.abs(player.y - eo.cellY))
  if lag > Config.RESYNC_DISTANCE then
    M.placeAt3(eo, player.x, player.y, player.facing)
    av.facing = eo.facing
    M.nudge3(eo)
    return true
  end

  if M.TRACE then
    mod.log:info("step %s %s from (%d,%d) toward (%s,%s)", tostring(player.id),
      dir, eo.cellX, eo.cellY, tostring(player.x), tostring(player.y))
  end

  local frames = M.stepFrames3(lag, player.fast)
  local ok, started = pcall(Objects.pushStep, eo, dir, frames)
  if not (ok and started) then return nil end
  av.facing = dir
  return true
end

function M:sync3(roster, current)
  local Objects = objects3()
  if not Objects then return end

  if not (current and current.mapId) then
    if next(self.spawned) then self:clear() end
    self.mapId = nil
    return
  end

  if current.mapId ~= self.mapId then
    self:clear()
    self.mapId = current.mapId
  end

  -- For a moment during a warp the engine's list still belongs to the map
  -- being left (the fade runs before Objects.loadMap).  Nothing is put into
  -- a list about to be wiped; the next tick after the load does it.
  if Objects._mapId ~= nil and Objects._mapId ~= current.mapId then return end

  local seen = {}
  for _, player in ipairs(roster:onMap(current.mapId)) do
    seen[player.id] = true
    local av = self.spawned[player.id]
    if av then self:advance3(av, player) else self:spawn3(player) end
  end

  for id in pairs(self.spawned) do
    if not seen[id] then self:despawn3(id) end
  end
end

M.DELTA = DELTA

return M
