-- Headless loader filesystem that can remap mods/rby_mmo onto an absolute
-- out-of-tree checkout (agetor worktrees whose engine symlink points elsewhere).
-- Kept out of rby_mmo_test.lua so the suite stays under LuaJIT's 200-local
-- main-chunk limit.
--
-- Usage (from engine root):
--   local make = dofile(modRoot .. "/tests/mod_remap_fs.lua")
--   local fs = make(T, modRoot, { pinEnabled = true })

return function(T, modRoot, opts)
  opts = opts or {}
  local logical = "mods/rby_mmo"
  local remap = (modRoot ~= logical)
  local inner = T.fs.new(".")
  local OPTIONS = "options.lua"
  local pinBody = opts.pinEnabled
    and "return { mods = { rby_mmo = true } }"
    or nil
  local loadstr = loadstring or load
  local fs = { root = inner.root }

  local function resolve(path)
    if not remap or type(path) ~= "string" then return path, false end
    if path == logical then return modRoot, true end
    local prefix = logical .. "/"
    if path:sub(1, #prefix) == prefix then
      return modRoot .. "/" .. path:sub(#prefix + 1), true
    end
    return path, false
  end

  function fs.read(path)
    if pinBody and path == OPTIONS then return pinBody end
    local real, external = resolve(path)
    if external then
      local handle = io.open(real, "rb")
      if not handle then return nil, "nofile" end
      local body = handle:read("*a")
      handle:close()
      return body
    end
    return inner.read(real)
  end

  function fs.load(path)
    if pinBody and path == OPTIONS then return loadstr(pinBody, OPTIONS) end
    local real, external = resolve(path)
    if external then return loadfile(real) end
    return inner.load(real)
  end

  function fs.getInfo(path)
    if pinBody and path == OPTIONS then return { type = "file" } end
    local real, external = resolve(path)
    if external then
      local handle = io.open(real, "rb")
      if handle then
        local probe = handle:read(1)
        handle:close()
        if probe ~= nil then return { type = "file" } end
      end
      local ok = os.execute("test -d '" .. real:gsub("'", "'\\''") .. "'")
      if ok == true or ok == 0 then return { type = "directory" } end
      return nil
    end
    return inner.getInfo(real)
  end

  function fs.getDirectoryItems(path)
    if path == "mods" then return { "rby_mmo" } end
    local real, external = resolve(path)
    if external then
      local items = {}
      local pipe = io.popen("ls -1 '" .. real:gsub("'", "'\\''") .. "' 2>/dev/null")
      if pipe then
        for line in pipe:lines() do
          if line ~= "" then items[#items + 1] = line end
        end
        pipe:close()
      end
      table.sort(items)
      return items
    end
    return inner.getDirectoryItems(real)
  end

  return fs
end
