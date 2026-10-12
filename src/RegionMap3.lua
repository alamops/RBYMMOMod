-- Party positions in the cart's region-map grid. No remote save or live
-- player state is substituted into the engine to calculate these cells.
local need = ...
local Gen3 = need("Gen3")
local M = {}

local function call(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, a, b = pcall(fn, ...)
  if ok then return a, b end
end

local function scaled(value, size, span)
  local divisor = math.max(1, math.floor((tonumber(size) or 1) / span))
  return math.max(0, math.min(span - 1, math.floor((tonumber(value) or 0) / divisor)))
end

function M.view(layout)
  if layout == "frlg" then
    local RM = Gen3.engine("src.ui.game3.region_map")
    local state = RM and call(RM.state)
    if not state or (state.fade and state.fade.active) then return nil end
    if state.cb2 and state.cb2 ~= "main" then return nil end
    if state.task and state.mainTask and state.task ~= state.mainTask then return nil end
    return { layout = layout, region = state.selectedRegion or 0 }
  elseif layout == "rse" then
    local RM = Gen3.engine("src.ui.game3.rse.region_map")
    if not (RM and call(RM.active)) then return nil end
    return { layout = layout }
  elseif layout == "pokenav" then
    local Nav = Gen3.engine("src.ui.game3.rse.pokenav.init")
    local shell = Nav and call(Nav.active)
    local screen = shell and shell.screen
    if not (screen and screen.visible and not screen.zoomDisabled) then return nil end
    return { layout = layout, screen = screen }
  end
end

-- Same affine placement as NavMap.drawMap. The map image transforms during
-- zoom as well as while scrolling; figures stay 16 pixels tall like its icon.
function M.project(view, x, y)
  if view.layout == "frlg" then return x * 8 + 36, y * 8 + 36 end
  if view.layout ~= "pokenav" then return x * 8 + 4, y * 8 + 4 end
  local s = view.screen
  local zoom = 256 / math.max(1, tonumber(s.scale) or 256)
  local c, d = tonumber(s.c) or 0, tonumber(s.d) or 0
  return c + (x * 8 + 4 - (tonumber(s.scrollX) or 0) - c) * zoom,
    d + (y * 8 + 2 - (tonumber(s.scrollY) or 0) - d) * zoom + 2
end

function M.position(game, player, view)
  local maps = game and game.data and game.data.maps
  local def = maps and maps[player.map]
  local section = def and tonumber(def.regionMapSectionId or def.region_map_section_id or def.mapsec)
  if not section then return nil end
  local region = Gen3.region(player.map)
  local indoor = tonumber(def.mapType) == 4 or tonumber(def.mapType) == 7
    or tonumber(def.mapType) == 8 or tonumber(def.mapType) == 9
  local x, y
  if view.layout == "frlg" then
    if region ~= "kanto" and region ~= "sevii" then return nil end
    local Extract = Gen3.engine("src.import.gba.region_map_extract")
    local Position = Gen3.engine("src.ui.game3.region_map_position")
    local geometry = Extract and Extract.GEOMETRY
    local dims = geometry and geometry.dimensions and geometry.dimensions[section]
    local corner = geometry and geometry.topLeft and geometry.topLeft[section]
    if not (dims and corner and Position and Extract.LAYOUTS) then return nil end
    if call(Position.regionFor, section, Extract.LAYOUTS) ~= view.region then return nil end
    if not indoor then
      x, y = call(Position.playerCell, {
        map = player.map, x = player.x, y = player.y,
        def = function(id) return maps[id] end,
      }, geometry)
    end
    if not (tonumber(x) and tonumber(y)) then
      x = corner[1] + (indoor and math.floor((dims[1] - 1) / 2)
        or scaled(player.x, def.width, dims[1]))
      y = corner[2] + (indoor and math.floor((dims[2] - 1) / 2)
        or scaled(player.y, def.height, dims[2]))
    end
  else
    if region ~= "hoenn" then return nil end
    local Mapsec = Gen3.engine("src.ui.game3.rse.mapsec")
    local RM = Gen3.engine("src.ui.game3.rse.region_map")
    local manifest = RM and call(RM.manifest)
    if not manifest then return nil end
    for _, id in ipairs(manifest.offMap or {}) do if id == section then return nil end end
    -- Some caves use a fixed outdoor section; a moving Terra/Marine Cave
    -- requires the remote save's weather vars, which presence cannot supply.
    for _, id in ipairs(manifest.marineCaveMapSecIds or {}) do
      if id == section then return nil end
    end
    for _, pair in ipairs(manifest.specialPlaces or {}) do
      if pair[1] == (manifest.mapsecs or {}).NONE then break end
      if pair[1] == section then section = pair[2] break end
    end
    local entry = Mapsec and call(Mapsec.entry, section)
    if not entry then return nil end
    local w, h = tonumber(entry.width) or 0, tonumber(entry.height) or 0
    if w < 1 or h < 1 or not (tonumber(entry.x) and tonumber(entry.y)) then return nil end
    local sx = indoor and math.floor((w - 1) / 2) or scaled(player.x, def.width, w)
    local sy = indoor and math.floor((h - 1) / 2) or scaled(player.y, def.height, h)
    -- The cart's irregular route grids (region_map.c:1165).
    local ids = manifest.mapsecs or {}
    if not indoor then
      local px, py = tonumber(player.x) or 0, tonumber(player.y) or 0
      if section == ids.ROUTE_114 and sy ~= 0 then sx = 0 end
      if section == ids.ROUTE_126 or section == ids.UNDERWATER_126 then
        sx = (px > 32 and 1 or 0) + (px > 51 and 1 or 0)
        sy = (py > 37 and 1 or 0) + (py > 56 and 1 or 0)
      elseif section == ids.ROUTE_121 then
        sx = (px > 14 and 1 or 0) + (px > 28 and 1 or 0) + (px > 54 and 1 or 0)
      end
    end
    x, y = entry.x + sx + (RM.CURSOR_X_MIN or 1), entry.y + sy + (RM.CURSOR_Y_MIN or 2)
  end
  local px, py = M.project(view, x, y)
  if px < 8 or py < 8 or px > 232 or py > 152 then return nil end
  -- The PokéNav header, help bar and zoomed place-name panel cover the map.
  if view.layout == "pokenav" then
    if py < 40 or py > 136 then return nil end
    local s = view.screen
    if s.zoomed and px >= 136 and py >= 48 + (tonumber(s.bg1Y) or 0) then return nil end
  end
  return { x = px, y = py, cellX = x, cellY = y, region = region }
end

return M
