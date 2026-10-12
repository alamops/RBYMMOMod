-- What a map id is called, in the words the player's own game uses.
--
-- The overworld addresses a place by its engine id -- PALLET_TOWN -- and
-- that is what rides the wire and what the roster stores.  A list of who is
-- online wants the name a player would say out loud, and the engine already
-- has it:
--
--   Gen 1: the extractor decodes town-map entries into game.data.field.townMap
--   Gen 2: map headers carry a landmark byte / LANDMARK_* id, and the names
--          live in game.data.gen2Landmarks (no data.field.townMap)
--   Gen 3: map headers carry a region-map section, named by the cart's own
--          section table (Gen3.mapName: map_sections_extract on FireRed and
--          LeafGreen, the rse mapsec pack on Emerald) -- the words the map
--          name popup shows
--
-- Gen 3 has one wrinkle the other two do not: a hub mixes carts, so a
-- FireRed player's roster can hold an Emerald player standing in an EM_* map
-- their own cart has no section for.  Gen3.mapName answers both -- this
-- cart's sections for its own family, and the id cleaned into words (prefix
-- off, CamelCase and digits split) for the other -- so a Hoenn town reads as
-- a Hoenn town on a Kanto screen rather than as a raw id.
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
-- raises -- including a Gen 2 boot whose game.data.field is nil.

local need = ...
-- Gen3 answers nothing off a Gen 3 boot (every function checks Gen3.active
-- first), so requiring it costs a Gen 1 / Gen 2 lookup nothing.
local Gen3 = type(need) == "function" and need("Gen3") or nil

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

-- Cart landmark names keep a town-map line break ("NEW BARK\nTOWN"); a roster
-- row wants one line.
local function tidyName(named)
  if type(named) ~= "string" or named == "" then return nil end
  local one = named:gsub("\n", " "):gsub("%s+", " ")
  one = one:match("^%s*(.-)%s*$") or one
  if one == "" then return nil end
  return one
end

-- A Gen 3 map id: FR_* (FireRed / LeafGreen), SEVII_* (the legacy Sevii
-- spelling the engine still accepts) or EM_* (Emerald).
local function gen3MapId(mapId)
  return mapId:find("^FR_") ~= nil or mapId:find("^EM_") ~= nil
    or mapId:find("^SEVII_") ~= nil
end

local function gen3Name(mapId)
  if not (type(Gen3) == "table" and type(Gen3.active) == "function"
          and Gen3.active() and gen3MapId(mapId)) then
    return nil
  end
  local ok, name = pcall(Gen3.mapName, mapId)
  if not ok then return nil end
  return tidyName(name)
end

-- Gen 2: map def.landmark is either a LANDMARK_* string or the cart byte
-- index; gen2Landmarks.landmarks holds the printable name.
local function gen2LandmarkName(game, mapId)
  local data = type(game) == "table" and game.data or nil
  if type(data) ~= "table" then return nil end

  local maps = data.maps
  local def = type(maps) == "table" and maps[mapId] or nil
  local landmarkRef = type(def) == "table" and def.landmark or nil
  if landmarkRef == nil then return nil end

  local bag = data.gen2Landmarks
  local entries = type(bag) == "table" and bag.landmarks or nil
  if type(entries) ~= "table" then return nil end

  local entry = entries[landmarkRef]
  if type(entry) ~= "table" and type(landmarkRef) == "number" then
    for _, row in pairs(entries) do
      if type(row) == "table" and row.index == landmarkRef then
        entry = row
        break
      end
    end
    if type(entry) ~= "table" and type(bag.order) == "table" then
      local id = bag.order[landmarkRef + 1]
      entry = id and entries[id] or nil
    end
  end
  if type(entry) ~= "table" then return nil end
  return tidyName(entry.name or entry.label)
end

-- nil for "no place to name" rather than a placeholder string: a player in
-- a battle or a menu has no map at all, and only the caller knows what its
-- screen shows for that.
function M.name(game, mapId)
  if type(mapId) ~= "string" or mapId == "" then return nil end

  -- Gen 3 first, and for either family's ids: a Gen 3 map id is never a
  -- town-map or landmark key, so the two lookups below could only miss.
  local gen3 = gen3Name(mapId)
  if gen3 then return gen3 end

  local entries = locations(game)
  local entry = type(entries) == "table" and entries[mapId] or nil
  if type(entry) == "table" then
    -- .label alongside .name for the same reason the engine reads both:
    -- which key an entry carries is the extractor's business, not ours.
    local named = tidyName(entry.name or entry.label)
    if named then return named end
  end

  local gen2 = gen2LandmarkName(game, mapId)
  if gen2 then return gen2 end

  -- A miss is ordinary, not a fault: interiors that the town map has no
  -- entry for are most of the map list, and REDS_HOUSE_1F reads well
  -- enough as words.  Gen 2 without landmarks.lua falls through here too.
  return (mapId:gsub("_", " "))
end

return M
