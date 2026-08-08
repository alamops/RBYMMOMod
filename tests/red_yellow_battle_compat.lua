-- Red vs Yellow link-battle compatibility, against real ROM extracts.
--
-- Driven by tests/drivers/run-red-yellow-battle-compat.sh, which builds the
-- link-surface slice of each ROM into a temp dir and passes the paths here.
-- Needs the engine checkout on package.path (run from its root).
--
-- What it pins:
--   * Sessions.canBattle allows the pairing when neither hello is
--     link-modified -- the MMO exception for cartridge mismatches.
--   * A link-modified hello on one side still refuses, and names the mod.
--
-- It also prints whether the fingerprints actually match.  Fingerprint.lua
-- deliberately drops catchRate so R/B/Y can agree; if they diverge here for
-- another field, that is worth knowing even when canBattle still says yes.

package.path = "./?.lua;./?/init.lua;" .. package.path

local redDir = arg[1] or os.getenv("RED_DATA_DIR")
local yelDir = arg[2] or os.getenv("YELLOW_DATA_DIR")
local modRoot = arg[3] or os.getenv("RBY_MMO_ROOT") or "mods/rby_mmo"

if not (redDir and yelDir) then
  io.stderr:write("usage: luajit tests/red_yellow_battle_compat.lua "
    .. "<red-data-dir> <yellow-data-dir> [mod-root]\n")
  os.exit(2)
end

local failures = 0
local function check(cond, msg)
  if cond then
    print("ok   " .. msg)
  else
    failures = failures + 1
    print("FAIL " .. msg)
  end
end
local function eq(got, want, msg)
  check(got == want, ("%s (got %s, want %s)"):format(
    msg, tostring(got), tostring(want)))
end

local Fingerprint = require("src.link.Fingerprint")
local Handshake = require("src.link.Handshake")
local Version = require("src.core.Version")

-- Minimal slice Fingerprint.surface reads from a ROM extract.  Statuses /
-- move_effects / link_fields are engine-side and identical across versions
-- when neither hello is link-modified, so leaving them absent keeps the
-- comparison about the cartridge.
local function loadSlice(dir)
  local function one(name)
    local path = dir .. "/" .. name .. ".lua"
    local chunk, err = loadfile(path)
    if not chunk then
      error(("missing %s (%s)"):format(path, tostring(err)))
    end
    return assert(chunk())
  end
  return {
    pokemon = one("pokemon"),
    moves = one("moves"),
    type_chart = one("type_chart"),
    constants = one("constants"),
  }
end

local function loadSessions()
  local path = modRoot .. "/src/Sessions.lua"
  local body, err = loadfile(path)
  if not body then
    -- Lua 5.1 loadfile returns nil, err; loadstring path for older shapes
    error(("cannot load %s (%s)"):format(path, tostring(err)))
  end
  local Wire = { id = function() end, name = function() end,
                 KINDS = { battle = true, trade = true } }
  local function need(name)
    if name == "Wire" then return Wire end
    if name == "SessionNet" then return { new = function() return {} end } end
    return {}
  end
  local mod = { log = { error = function() end, warn = function() end } }
  return body(need, mod)
end

local Sessions = loadSessions()

local mmoMods = {
  { id = "rby_mmo", version = "0.10.0", affectsLink = false },
}

local function hello(name, data)
  return {
    type = "hello",
    protocol = Handshake.PROTOCOL or Version.linkProtocol or 2,
    name = name,
    engineVersion = Version.engine,
    apiVersion = Version.modApi,
    fingerprint = Fingerprint.compute(data, mmoMods),
    linkModified = false,
    mods = mmoMods,
  }
end

print("-- loading Red extract from " .. redDir)
local redData = loadSlice(redDir)
print("-- loading Yellow extract from " .. yelDir)
local yelData = loadSlice(yelDir)

local redHello = hello("RED", redData)
local yelHello = hello("YELLOW", yelData)

print(("red fingerprint:    %s"):format(redHello.fingerprint))
print(("yellow fingerprint: %s"):format(yelHello.fingerprint))

local sameFp = redHello.fingerprint == yelHello.fingerprint
if sameFp then
  print("note: fingerprints match -- cable-club surface agrees across versions")
else
  print("note: fingerprints differ -- canBattle must still allow via the "
    .. "unmodified-link exception")
end

local verdict, reason = Handshake.checkCompat(redHello, yelHello)
-- checkCompat returns one or two values depending on path
if type(verdict) == "string" and reason == nil and verdict ~= "full"
    and verdict ~= "subset" and verdict ~= "refused" and verdict ~= "vanilla_peer" then
  -- older shape shouldn't happen; keep going
end
print(("checkCompat verdict: %s (%s)"):format(
  tostring(verdict), tostring(reason)))

if sameFp then
  eq(verdict, "full", "matching fingerprints are a full verdict")
else
  eq(verdict, "subset", "differing fingerprints are a subset verdict")
end

check(Sessions.canBattle(verdict, redHello, yelHello, Handshake),
      "Red vs Yellow is allowed when neither side touched link rules")
check(Sessions.canBattle(verdict, yelHello, redHello, Handshake),
      "and the same the other way around")

-- One side with a link-affecting mod still blocks, and the refusal names it.
local modded = {
  type = "hello",
  protocol = redHello.protocol,
  name = "YELLOW",
  engineVersion = redHello.engineVersion,
  apiVersion = redHello.apiVersion,
  fingerprint = "deadbeefdeadbeef",
  linkModified = true,
  mods = {
    { id = "rby_mmo", version = "0.10.0", affectsLink = false },
    { id = "stat_tweaks", version = "1.0.0", affectsLink = true },
  },
}
check(not Sessions.canBattle("subset", redHello, modded, Handshake),
      "a link-modified Yellow still cannot battle Red")
local msg = Sessions.battleBlockMessage(redHello, modded, "subset", Handshake)
check(type(msg) == "string" and msg:find("STAT_TWEAKS", 1, true) ~= nil,
      "the refusal names STAT_TWEAKS")

if failures > 0 then
  print(("%d failure(s)"):format(failures))
  os.exit(1)
end
print("all checks passed  (red_yellow_battle_compat)")
