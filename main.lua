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

return function(mod)
  local loadstr = loadstring or load
  local cache, loading, broken = {}, {}, {}
  local failed = false

  -- resolve a sibling module by name; returns nil once anything has failed
  -- so a partial wiring never half-installs.
  --
  -- `optional` (the Gen 3 solo family modules, src/Solo3/*) is the one
  -- exception: such a module is a feature the rest of the mod works without,
  -- read late (at boot's end or at its first fight), so its failure is kept
  -- to itself -- said once, remembered, and answered nil from then on --
  -- rather than switching off every module asked for after it.
  local function need(name, optional)
    if failed then return nil end
    local hit = cache[name]
    if hit ~= nil then return hit end
    if broken[name] then return nil end
    local function fail()
      loading[name] = nil
      if optional then broken[name] = true else failed = true end
      return nil
    end

    if loading[name] then
      mod.log:error(
        "circular dependency reaching %s%s.lua -- break the cycle by moving "
        .. "the shared value into Config.lua", MODULE_DIR, name)
      return fail()
    end
    loading[name] = true

    local path = MODULE_DIR .. name .. ".lua"
    local body = mod:read(path)
    if type(body) ~= "string" then
      mod.log:error(
        "missing %s -- the install is incomplete; reinstall the mod folder "
        .. "so every file under %s is present", path, MODULE_DIR)
      return fail()
    end

    local chunk, syntaxErr = loadstr(body, "@rby_mmo/" .. path)
    if not chunk then
      mod.log:error("%s failed to parse (%s) -- restore it from a clean "
        .. "copy of the mod", path, tostring(syntaxErr))
      return fail()
    end

    local ok, value = pcall(chunk, need, mod)
    if not ok then
      mod.log:error("%s failed to initialise (%s) -- report this with the "
        .. "line above", path, tostring(value))
      return fail()
    end

    loading[name] = nil
    cache[name] = value == nil and true or value
    return cache[name]
  end

  local Client = need("Client")
  if failed or type(Client) ~= "table" then
    mod.log:warn("multiplayer is disabled for this session; the single-player "
      .. "game is unaffected")
    return
  end

  Client.install()
end
