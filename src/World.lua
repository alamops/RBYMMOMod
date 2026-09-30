-- A guarded read of where the local player is.
--
-- mod.world materialises on first touch and answers nil until a Game
-- exists -- during a headless load, and on the title screen before a save
-- is up.  WorldAPI:current() then answers nil again whenever no overworld
-- is on the stack (a battle, a menu).
--
-- Every caller wants the same answer for both cases: "not in the world
-- right now."  Collapsing them here means no call site has to remember the
-- first one, and forgetting it would be an index-a-nil crash inside a hook.
--
-- ------- Gen 3
--
-- The game3 WorldAPI (src/world/game3/WorldAPI.lua) answers while the field
-- phase runs, and hands back one field more than the other two: `gen1MapId`,
-- the FR_-stripped spelling Gen3Compat uses to pretend FireRed's Pallet Town
-- is Red's.  This file keeps the raw `mapId` and drops that one.  The raw
-- prefix -- FR_* / SEVII_* for FireRed and LeafGreen, EM_* for Emerald -- is
-- what keeps Kanto and Hoenn apart on a hub that admits all three carts (the
-- hub scopes presence by exact map id, and no FR_ id is ever an EM_ id); the
-- stripped one would put a FireRed player's "PALLET_TOWN" on the same map as
-- a Red player's, and an Emerald id would be left half-translated beside it.
--
-- The answer is rebuilt as exactly { mapId, x, y, facing } so a caller that
-- serialises it (presence) ships only those, and it is nil unless all four
-- are sane: a Gen 3 read that throws, or comes back without a cell, is "not
-- in the world right now" like every other miss here.  Gen 1 and Gen 2 are
-- passed through untouched.

local need, mod = ...
local Gen3 = need("Gen3")

local M = {}

local FACINGS = { up = true, down = true, left = true, right = true }

local function current3(world)
  local ok, here = pcall(world.current, world)
  if not (ok and type(here) == "table") then return nil end
  local mapId = here.mapId
  local x, y = tonumber(here.x), tonumber(here.y)
  if type(mapId) ~= "string" or mapId == "" or not (x and y) then return nil end
  local facing = FACINGS[here.facing] and here.facing or "down"
  return { mapId = mapId, x = x, y = y, facing = facing }
end

function M.current()
  local world = mod.world
  if not world then return nil end
  if Gen3.active() then return current3(world) end
  return world:current()
end

return M
