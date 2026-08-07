-- Who else is online, and where.
--
-- Plain state with no engine or network dependency, so the suite can drive
-- it directly.  Everything stored here has already been through Wire, so
-- this module never re-validates.

local need = ...
local Config = need("Config")

local M = {}
M.__index = M

function M.new()
  return setmetatable({ selfId = nil, players = {}, count = 0 }, M)
end

function M:reset()
  self.players, self.count = {}, 0
end

function M:setSelf(id) self.selfId = id end

-- The hub echoes our own presence back in the welcome roster so a client
-- does not have to special-case the ordering; dropping it here is what
-- keeps the local player from being drawn as their own remote avatar.
function M:isSelf(id)
  return self.selfId ~= nil and id == self.selfId
end

function M:put(presence)
  if not presence or self:isSelf(presence.id) then return nil end
  if not self.players[presence.id] then self.count = self.count + 1 end
  self.players[presence.id] = presence
  return presence
end

-- A move carries only the fields that moved, so it merges rather than
-- replaces: a player who walks must not lose the name, sprite or trainer
-- card that arrived with their join.
--
-- `fast` rides here rather than getting a setter of its own like busy and
-- party did, and the difference is what the flag is *about*: busy and party
-- change while a player stands still, so they need a way in that does not
-- involve a cell.  Pace is a property of the step itself -- it is decided by
-- the same input and the same bike that moved them, it changes with the
-- movement, and every mmo.move already carries it -- so threading it through
-- the argument that delivers the step keeps the two from ever disagreeing.
-- A nil is a caller that predates the field, and leaves the stored value
-- alone: reading "no opinion" as "not fast" would have every old-shaped call
-- stop a runner mid-stride.
function M:move(id, map, x, y, facing, fast)
  local player = self.players[id]
  if not player then return nil end
  player.map, player.x, player.y = map, x, y
  player.facing = facing or player.facing
  if fast ~= nil then player.fast = fast and true or false end
  return player
end

-- A rating that moved while the player stood still.  Its own message rather
-- than part of a move, because a battle ends with both players out of the
-- world -- there is no cell to send with it.
function M:setPoints(id, points)
  local player = self.players[id]
  if player then player.points = points end
  return player
end

function M:setBusy(id, busy)
  local player = self.players[id]
  if player then player.busy = busy and true or false end
  return player
end

-- Whether this player is in a party.  Its own setter for the same reason
-- busy has one: a presence update merges rather than replaces, so a flag
-- that is not copied across explicitly is a flag that only ever has the
-- value it had at join time.
--
-- That was the bug.  A party formed after both players were already online
-- broadcast a presence saying so, the roster kept the join-time false, and
-- so the INVITE row went on being offered against somebody who could no
-- longer accept it -- and the PARTY column and the map marker never
-- appeared.  Nothing in the headless suite could see it: the hub sent the
-- right message and the client threw the field away.
--
-- Running is the flag that did *not* get one of these, for the reason spelled
-- out over M:move -- it belongs to a step, so it travels with the step.
function M:setParty(id, party)
  local player = self.players[id]
  if player then player.party = party and true or false end
  return player
end

-- The character somebody is wearing, changed mid-session.  The picker is
-- reachable from the connected menu now, so a face is one more thing that
-- moves while its player stands still, and the hub rebroadcasts the change
-- to everybody the way it does a rating.
--
-- A field write on the stored table, never `put()`.  Every setter above is
-- in place for the merge reason; this one has a second: an open trainer
-- card holds this exact table (Card.new keeps it as `self.player`), so
-- swapping the entry for a fresh one would leave that card drawing a
-- player nobody updates again -- the old portrait, on screen, while the
-- roster below it already knows better.
function M:setSprite(id, sprite)
  local player = self.players[id]
  if player then player.sprite = sprite end
  return player
end

function M:remove(id)
  if not self.players[id] then return nil end
  local gone = self.players[id]
  self.players[id] = nil
  self.count = self.count - 1
  return gone
end

function M:get(id) return self.players[id] end

-- Sorted by name so every list the player sees -- the roster screen, the
-- interact menu -- is stable between frames instead of reordering with
-- table iteration.
function M:sorted()
  local out = {}
  for _, player in pairs(self.players) do out[#out + 1] = player end
  table.sort(out, function(a, b)
    if a.name ~= b.name then return a.name < b.name end
    return a.id < b.id
  end)
  return out
end

function M:onMap(mapId)
  local out = {}
  if not mapId then return out end
  for _, player in ipairs(self:sorted()) do
    if player.map == mapId then out[#out + 1] = player end
  end
  return out
end

-- Chebyshev distance: the overworld is a grid the player walks in four
-- directions, so "within N tiles" means a square, not a circle.
function M.distance(a, b)
  return math.max(math.abs(a.x - b.x), math.abs(a.y - b.y))
end

function M:near(mapId, x, y, radius)
  local out = {}
  if not (mapId and x and y) then return out end
  local origin = { x = x, y = y }
  for _, player in ipairs(self:onMap(mapId)) do
    if M.distance(origin, player) <= (radius or Config.LOCAL_RADIUS) then
      out[#out + 1] = player
    end
  end
  return out
end

-- the player standing on, or directly in front of, a cell -- the lookup the
-- interact menu uses to decide who "talk to" means
function M:at(mapId, x, y)
  for _, player in ipairs(self:onMap(mapId)) do
    if player.x == x and player.y == y then return player end
  end
  return nil
end

return M
