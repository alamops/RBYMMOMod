-- What a map id is called, in the words the player's own game uses.
--
-- The overworld addresses a place by its engine id -- PALLET_TOWN -- and
-- that is what rides the wire and what the roster stores.  A list of who is
-- online wants the name a player would say out loud, and the engine already
-- has it: the extractor decodes the town-map entries out of the ROM the
-- player supplied into game.data.field.townMap, so every copy has the names
-- at runtime.
--
-- That is also the only place they may come from.  A committed id -> name
-- table would be ROM-derived data sitting in this repo, which this mod may
-- not ship; the fallback below is a transform of the id string, which is
-- data the wire handed us.  It is the engine's own list-mode fallback too
-- (src/ui/TownMap.lua:38-41), so a copy without town-map data shows the
-- same words the TOWN MAP screen would.
--
-- Pure, and defensive to the point of dullness: this is called once per row
-- while a screen is being built, from inside a mod callback, so an
-- unexpected shape has to cost a nice name and nothing else.  Nothing here
-- raises.

local M = {}

-- The per-map entries, whichever of the two shapes the extractor settled
-- on.  The engine tolerates both (src/ui/TownMap.lua:51-58): the table is
-- either the mapId -> entry index itself, or carries it under .locations.
local function locations(game)
  local data = type(game) == "table" and game.data or nil
  local field = type(data) == "table" and data.field or nil
  local townMap = type(field) == "table" and field.townMap or nil
  if type(townMap) ~= "table" then return nil end
  if type(townMap.locations) == "table" then return townMap.locations end
  return townMap
end

-- nil for "no place to name" rather than a placeholder string: a player in
-- a battle or a menu has no map at all, and only the caller knows what its
-- screen shows for that.
function M.name(game, mapId)
  if type(mapId) ~= "string" or mapId == "" then return nil end

  local entries = locations(game)
  local entry = type(entries) == "table" and entries[mapId] or nil
  if type(entry) == "table" then
    -- .label alongside .name for the same reason the engine reads both:
    -- which key an entry carries is the extractor's business, not ours.
    local named = entry.name or entry.label
    if type(named) == "string" and named ~= "" then return named end
  end

  -- A miss is ordinary, not a fault: interiors that the town map has no
  -- entry for are most of the map list, and REDS_HOUSE_1F reads well
  -- enough as words.
  return (mapId:gsub("_", " "))
end

return M
