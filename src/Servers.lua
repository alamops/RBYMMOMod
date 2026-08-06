-- The hubs this copy has played on: the list behind START > MMO > SERVERS.
--
-- An entry is written by the one event that proves a hub is real -- a welcome
-- off a dialled address -- and never by a dial that was refused, so the list
-- is "places you have actually been" rather than "addresses you have typed".
-- Everything else it carries (a name, a favourite flag, a join code) is the
-- player's, and is why the list exists at all: retyping 192.168.1.20:7788 on
-- a d-pad is the friction this replaces.
--
-- Plain state with no engine dependency beyond the mod facade it is handed,
-- so the suite can drive it directly the way it drives Roster and Chat.
--
-- ------- where it is kept, and why in two places
--
-- Twice, for the reason the rank claim tickets are (src/Client.lua's token
-- store, which this copies): mod.save is RAM the engine happens to flush with
-- the rest of a save, nothing in connecting writes one, and CONTINUE replaces
-- the whole table with whatever was last written -- so a hub recorded this
-- session and never saved would be gone by the next launch, which is exactly
-- the case a recents list exists for. So the list is written to mod.save,
-- still, and to one file of this mod's own that a save reload cannot take
-- away. Reads prefer the file, because a save reload is precisely when
-- mod.save holds the older answer.
--
-- That also settles what the list *is*: machine-level state, shared by every
-- save slot on this copy, not a fact about one trainer's game.
--
-- love is absent under the headless test interpreter, and every path here
-- answers "no file" when it is -- which leaves the mod.save half as the whole
-- behaviour there rather than failing.

local need, chunkMod = ...
local Config = need("Config")
local Wire = need("Wire")

local M = {}
M.__index = M

-- Where the mirror lives inside this mod's own save bucket.
local SAVE_KEY = "servers"

-- ------- addresses

-- The same normalisation the connect path applies, deliberately duplicated
-- rather than shared: withPort and codeKey are locals inside src/Client.lua,
-- and exporting them to reach them here would widen that file's surface for
-- one caller. What matters is that the answer agrees -- the key a hub is
-- filed under has to be the key its join code is filed under, or a player
-- typing "mybox" and a player typing "mybox:7788" would keep two rows for one
-- hub and only one of them would connect.
--
-- Whitespace goes first so the port test sees the end of the address, then
-- the port is filled in (Net's own fallback is the relay's 7778, which is not
-- a port any hub of ours is listening on), and the key is the lower-cased
-- result: one hub, however it was typed, is one row.
local function normalize(address)
  if type(address) ~= "string" then return nil end
  local clean = address:gsub("%s+", "")
  if clean == "" then return nil end
  if not clean:match(":%d+$") then
    clean = ("%s:%d"):format(clean, Config.DEFAULT_PORT)
  end
  return clean
end

local function keyOf(address)
  local clean = normalize(address)
  if not clean then return nil end
  return clean:lower()
end

-- What a hub is called before anybody names it.
--
-- Its own address, which is the only thing known about it at record time and
-- the string the player was read out. It is run through the display
-- sanitiser like any typed name, so a hostname longer than the row has room
-- for arrives shortened rather than overflowing the menu -- and the full
-- address is still on the entry, which is what CONNECT dials.
local function defaultName(address)
  return Wire.text(address, Config.SERVER_NAME_MAX) or address
end

local function now()
  if type(os) ~= "table" or type(os.time) ~= "function" then return 0 end
  local ok, stamp = pcall(os.time)
  if ok and type(stamp) == "number" then return math.floor(stamp) end
  return 0
end

-- Everything that comes back off disk or out of a save has been outside this
-- process, so it is checked exactly as hard as a message off the wire: a
-- hand-edited file must not be able to put an unprintable name in a menu or a
-- half-code in a challenge answer.
local function sanitise(raw)
  if type(raw) ~= "table" then return nil end
  local clean = normalize(raw.address or raw.key)
  if not clean then return nil end
  local last = tonumber(raw.last)
  return {
    key = clean:lower(),
    address = clean,
    name = Wire.text(raw.name, Config.SERVER_NAME_MAX) or defaultName(clean),
    fav = raw.fav == true,
    code = Wire.code(raw.code),
    last = (last and last > 0) and math.floor(last) or 0,
  }
end

-- ------- the store

function M.new(ctx)
  return setmetatable({
    -- The facade is taken from ctx so the suite can drive this against its
    -- stub mod; the chunk's own is the fallback for a caller that passes
    -- nothing, and keeps a missing ctx from being a crash on the first log
    -- line.
    mod = (type(ctx) == "table" and ctx.mod) or chunkMod,
    entries = {},
    -- Keys this session removed on purpose -- evicted, or re-keyed by EDIT
    -- HOST. The write below folds in rows it finds on disk that it has never
    -- seen, and without this a row another copy still holds would walk back
    -- in the moment it was dropped here.
    dropped = {},
    loaded = false,
  }, M)
end

function M:_warn(fmt, ...)
  local log = self.mod and self.mod.log
  if log and type(log.warn) == "function" then log:warn(fmt, ...) end
end

-- ------- persistence

local function filesystem()
  if type(love) ~= "table" then return nil end
  if type(love.filesystem) ~= "table" then return nil end
  return love.filesystem
end

-- src.link.Json is already this mod's encoder, so a file of our own is not a
-- reason to carry a second one. Resolved once and remembered, including the
-- failure: under the headless interpreter there is no engine to require from
-- and asking again every write would be a pcall per keystroke.
local jsonModule, jsonTried = nil, false
local function json()
  if jsonTried then return jsonModule end
  jsonTried = true
  local ok, module = pcall(require, "src.link.Json")
  if ok and type(module) == "table" then jsonModule = module end
  return jsonModule
end

-- The file, and second whether it is *there and unreadable* -- which
-- love.filesystem.read cannot say on its own, because a missing file and a
-- failed read are the same nil. The two want opposite things from the writer:
-- there is nothing to lose by writing over a file that does not exist, and
-- everything to lose by writing over one that does and would not open.
--
-- A file that will not decode is a third case and is treated as empty, so the
-- next hub recorded rewrites it whole and repairs it. Refusing to remember
-- anything until the player deletes a file nobody told them about would be a
-- worse answer than losing a list of addresses.
function M:_read()
  local fs, Json = filesystem(), json()
  if not (fs and Json) then return nil, false end

  local ok, body = pcall(fs.read, Config.SERVERS_FILE)
  if not ok or type(body) ~= "string" then
    local exists = false
    if type(fs.getInfo) == "function" then
      local asked, info = pcall(fs.getInfo, Config.SERVERS_FILE)
      exists = asked and type(info) == "table"
    end
    return nil, exists
  end
  -- An empty file is readable and says nothing, which is the same as no file.
  if body == "" then return nil, false end

  local decoded = Json.decode(body)
  if type(decoded) ~= "table" then
    self:_warn("%s is not readable as JSON -- delete it from the game's save "
      .. "folder to reset this copy's server list", Config.SERVERS_FILE)
    return nil, false
  end
  return decoded, false
end

-- The rows the save mirror is holding, in the same shape the file uses so one
-- sanitiser covers both.
function M:_saved()
  local save = self.mod and self.mod.save
  if not save then return nil end
  local ok, rows = pcall(save.get, save, SAVE_KEY)
  if not (ok and type(rows) == "table") then return nil end
  return rows
end

-- Applies rows to the table, newest reader wins. `only` restricts it to keys
-- this session has neither seen nor deliberately dropped, which is what the
-- write path needs and the load path does not.
function M:_ingest(rows, only)
  for _, raw in ipairs(rows or {}) do
    local entry = sanitise(raw)
    if entry then
      local known = self.entries[entry.key] ~= nil or self.dropped[entry.key]
      if not (only and known) then self.entries[entry.key] = entry end
    end
  end
end

-- Read once a session. The save mirror goes in first and the file over the top
-- of it, key by key, because the file is the durable copy and mod.save is the
-- one a CONTINUE can rewind.
function M:_load()
  if self.loaded then return end
  self.loaded = true
  self:_ingest(self:_saved())
  local rows = self:_read()
  if rows then self:_ingest(rows) end
end

-- Sorted the way the menu draws them, so the array is also what gets written:
-- favourites first, and within each group the address descending. Descending
-- because that is what was asked for; the keys are unique, so there are no
-- ties to break.
function M:_rows()
  local out = {}
  for _, entry in pairs(self.entries) do out[#out + 1] = entry end
  table.sort(out, function(a, b)
    if a.fav ~= b.fav then return a.fav end
    return a.key > b.key
  end)
  return out
end

-- The cap, applied by throwing away the hub you have not been to in longest.
--
-- A favourite is never a candidate: marking one is the player saying "keep
-- this", and a list that dropped it anyway would make the flag a decoration.
-- That means a player with SERVER_LIST_MAX favourites has a list that grows
-- past the cap, which is the right way round -- the cap exists to stop a
-- forgotten address accumulating forever, not to refuse the player a hub.
--
-- `keep` is the row the caller is in the middle of returning: the entry just
-- recorded is the newest of them all and cannot be the eviction, except in the
-- one case where every other row is a favourite and it is the only candidate.
local function evict(self, keep)
  local count = 0
  for _ in pairs(self.entries) do count = count + 1 end
  while count > Config.SERVER_LIST_MAX do
    local oldestKey, oldest = nil, nil
    for key, entry in pairs(self.entries) do
      if not entry.fav and key ~= keep then
        -- The key breaks a tie, so two rows recorded in the same second are
        -- resolved the same way on every copy rather than by table order.
        if not oldest or entry.last < oldest.last
          or (entry.last == oldest.last and key > oldestKey) then
          oldestKey, oldest = key, entry
        end
      end
    end
    if not oldestKey then return end
    self.entries[oldestKey] = nil
    self.dropped[oldestKey] = true
    count = count - 1
  end
end

-- Write both halves, and in that order: the mirror always, the file
-- best-effort.
--
-- The file is re-read first, because another save slot -- or a second copy of
-- the game running under the same LOVE identity -- may have recorded a hub
-- since we last looked, and writing our cached table back over it would drop
-- theirs. Rows this session dropped on purpose are not folded back in.
--
-- **The one thing this must never do is turn a read failure into a wipe.** The
-- write is the whole list, so a file that exists and would not open is left
-- exactly as it is: the mirror still took the change, and the file repairs
-- itself the next time it reads.
function M:_persist()
  local rows, unreadable = self:_read()
  if rows then
    self:_ingest(rows, true)
    evict(self)
  end

  local list = self:_rows()
  local save = self.mod and self.mod.save
  if save then pcall(save.set, save, SAVE_KEY, list) end

  local fs, Json = filesystem(), json()
  if not (fs and Json) then return false end
  if unreadable then
    self:_warn("%s could not be read, so this session's server list was not "
      .. "written to it and nothing in it was overwritten -- the list still "
      .. "works for this game; delete the file from the game's save folder if "
      .. "this repeats", Config.SERVERS_FILE)
    return false
  end

  local ok, encoded = pcall(Json.encode, list)
  if not (ok and type(encoded) == "string") then
    self:_warn("could not encode %s (%s) -- the server list will not survive a "
      .. "relaunch; delete the file from the game's save folder if this "
      .. "repeats", Config.SERVERS_FILE, tostring(encoded))
    return false
  end

  local called, wrote, why = pcall(fs.write, Config.SERVERS_FILE, encoded)
  if not (called and wrote) then
    self:_warn("could not write %s (%s) -- hubs you connect to will be "
      .. "forgotten on relaunch unless the game is saved while connected",
      Config.SERVERS_FILE, tostring(called and why or wrote))
    return false
  end
  return true
end

-- ------- the API the menus and Client use

function M:list()
  self:_load()
  return self:_rows()
end

-- Takes a key or an address, because they normalise to the same string and a
-- caller holding one should not have to know which it is.
function M:get(key)
  self:_load()
  local id = keyOf(key)
  if not id then return nil end
  return self.entries[id]
end

-- A hub answered our welcome, so it goes on the list.
--
-- Create or refresh: the player's own name and favourite flag survive a
-- reconnect untouched, because they are the two things on the row that were
-- never ours to write. The code is taken when there is one and left alone
-- when there is not -- a hub that dropped its code this session must not
-- erase the one the player typed.
function M:record(address, code)
  self:_load()
  local clean = normalize(address)
  if not clean then
    self:_warn("could not remember a hub with no address -- reconnect from "
      .. "START > MMO > JOIN GAME and it will be listed then")
    return nil
  end

  local key = clean:lower()
  local entry = self.entries[key]
  if not entry then
    entry = { key = key, address = clean, name = defaultName(clean),
              fav = false, code = nil, last = 0 }
    self.entries[key] = entry
  end
  entry.address = clean
  entry.last = now()
  entry.code = Wire.code(code) or entry.code
  self.dropped[key] = nil

  evict(self, key)
  self:_persist()
  return entry
end

-- What the row is called. Sanitised like any other text the player types, and
-- refused when nothing printable survives -- a blank row is a row nobody can
-- tell from the one above it.
function M:rename(key, name)
  local entry = self:get(key)
  if not entry then
    self:_warn("no server is stored for %s, so it cannot be renamed -- connect "
      .. "to it once from START > MMO > JOIN GAME", tostring(key))
    return nil
  end
  local clean = Wire.text(name, Config.SERVER_NAME_MAX)
  if not clean then
    self:_warn("that name has nothing in it the game can draw -- type letters "
      .. "or digits, or leave the name as it is")
    return nil
  end
  entry.name = clean
  self:_persist()
  return entry
end

function M:setFavorite(key, fav)
  local entry = self:get(key)
  if not entry then
    self:_warn("no server is stored for %s, so it cannot be favourited -- "
      .. "connect to it once from START > MMO > JOIN GAME", tostring(key))
    return nil
  end
  entry.fav = fav and true or false
  self:_persist()
  return entry
end

-- The hub moved -- a new IP, a new port, a name instead of an address.
--
-- The row is re-keyed rather than copied, so everything the player put on it
-- travels: a favourite hub that changed address is still favourite, still
-- named what they called it, and still holds the code they typed. A row
-- already sitting at the new address is replaced by this one, which is the
-- only answer that leaves one row per hub -- and the alternative, refusing the
-- edit, would strand the player with two rows and no way to merge them.
function M:setAddress(key, newAddress)
  local entry = self:get(key)
  if not entry then
    self:_warn("no server is stored for %s, so its address cannot be changed "
      .. "-- connect to it once from START > MMO > JOIN GAME", tostring(key))
    return nil
  end
  local clean = normalize(newAddress)
  if not clean then
    self:_warn("that is not an address this game can dial -- type it as an IP "
      .. "or a host name, with an optional :port")
    return nil
  end

  local id = clean:lower()
  if id ~= entry.key then
    self.entries[entry.key] = nil
    self.dropped[entry.key] = true
    self.entries[id] = entry
    self.dropped[id] = nil
    entry.key = id
  end
  entry.address = clean
  self:_persist()
  return entry
end

-- The join code this hub asks for, kept on the row so it survives a save-slot
-- change the way the address does. Client keeps its own copy under a per-hub
-- key and that is still what the challenge is answered from; this is the copy
-- that can be handed back to it on CONNECT.
--
-- Refused unless it is a whole code: a half-code stored here would be written
-- through to the connect path and fail every challenge silently, which is the
-- failure this validation exists to turn into a sentence.
function M:setCode(key, code)
  local entry = self:get(key)
  if not entry then
    self:_warn("no server is stored for %s, so its join code cannot be set -- "
      .. "connect to it once from START > MMO > JOIN GAME", tostring(key))
    return nil
  end
  local clean = Wire.code(code)
  if not clean then
    self:_warn("that is not a join code -- it is %d characters from the code "
      .. "alphabet, as read out by whoever is hosting", Config.CODE_LEN)
    return nil
  end
  entry.code = clean
  self:_persist()
  return entry
end

return M
