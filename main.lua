-- RBY MMO: shared-overworld multiplayer for Gen1Recomp.
--
-- The mod is split across src/*.lua, which are loaded through mod:read and
-- an internal resolver rather than the global require.  That keeps every
-- file inside the mod's own sandbox: nothing lands in package.loaded, the
-- dev-mode permissions tripwire sees only the src.link.* requires this mod
-- actually declares network permission for, and the headless loader used by
-- `modkit validate` walks the same path the game does.
--
-- Nothing here raises.  A missing or malformed module disables the feature
-- set with an attributed log line and leaves the vanilla game untouched --
-- the mod being broken must never be the reason a player cannot play.

local MODULE_DIR = "src/"
local EDITOR_CONTENT = "maps/content_editor.lua"

return function(mod)
  local loadstr = loadstring or load
  local cache, loading = {}, {}
  local failed = false

  -- resolve a sibling module by name; returns nil once anything has failed
  -- so a partial wiring never half-installs
  local function need(name)
    if failed then return nil end
    local hit = cache[name]
    if hit ~= nil then return hit end

    if loading[name] then
      mod.log:error(
        "circular dependency reaching %s%s.lua -- break the cycle by moving "
        .. "the shared value into Config.lua", MODULE_DIR, name)
      failed = true
      return nil
    end
    loading[name] = true

    local path = MODULE_DIR .. name .. ".lua"
    local body = mod:read(path)
    if type(body) ~= "string" then
      mod.log:error(
        "missing %s -- the install is incomplete; reinstall the mod folder "
        .. "so every file under %s is present", path, MODULE_DIR)
      failed = true
      return nil
    end

    local chunk, syntaxErr = loadstr(body, "@rby_mmo/" .. path)
    if not chunk then
      mod.log:error("%s failed to parse (%s) -- restore it from a clean "
        .. "copy of the mod", path, tostring(syntaxErr))
      failed = true
      return nil
    end

    local ok, value = pcall(chunk, need, mod)
    if not ok then
      mod.log:error("%s failed to initialise (%s) -- report this with the "
        .. "line above", path, tostring(value))
      failed = true
      return nil
    end

    loading[name] = nil
    cache[name] = value == nil and true or value
    return cache[name]
  end

  local source = mod:read(EDITOR_CONTENT)
  if not source then
    mod.log:error("%s is missing", EDITOR_CONTENT)
  else
    local chunk, err = loadstr(source, "@rby_mmo/" .. EDITOR_CONTENT)
    if not chunk then
      mod.log:error("%s did not compile: %s", EDITOR_CONTENT, tostring(err))
    else
      local ok, apply = pcall(chunk)
      if not ok or type(apply) ~= "function" then
        mod.log:error("%s must return function(mod)", EDITOR_CONTENT)
      else
        apply(mod)
      end
    end
  end

  local Client = need("Client")
  if failed or type(Client) ~= "table" then
    mod.log:warn("multiplayer is disabled for this session; the single-player "
      .. "game is unaffected")
    return
  end

  Client.install()
end
