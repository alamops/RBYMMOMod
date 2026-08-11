-- Friends: the people you keep between sessions, per hub.
--
-- A party is who you are travelling with right now and ends with the
-- connection (src/Party.lua).  This is the opposite kind of thing: a standing
-- list that is still there tomorrow, that carries people who are not online,
-- and that both sides had to agree to.
--
-- ------- what a friendship is, and what it is keyed on
--
-- **A pair of trainer names on one hub.**  Not a pair of connection ids: an
-- id is minted per connection and means nothing on the next visit, so a list
-- keyed on ids would be empty every time it was opened.  The name is what the
-- rank board already keys on for exactly the same reason, and it is claimable
-- there -- a hub hands the first player to use a name a ticket and asks for it
-- back on every later hello (src/Rank.lua) -- so "the same name" is as close
-- to "the same person" as a hub without accounts can get.  Be honest about
-- what that is worth: on a hub where a name has never been claimed, somebody
-- else typing it is somebody else wearing it, and your list would say friend.
--
-- **Per hub**, because the name is: ANN on one hub and ANN on another are two
-- people as far as anything here can tell, and merging their lists would put a
-- stranger on one of them.  The list is filed under the hub *and* the name
-- this copy plays as, so two people sharing a machine keep two lists.
--
-- ------- who stores it
--
-- This client does, in a file of its own, and deliberately not the hub.  The
-- alternative -- a friends table on the hub -- would work on a dedicated
-- server and lose every friendship on a game hosted from inside somebody's
-- copy, which has no disk to keep one on and exists for the length of one
-- session.  A list that survives on one of the two hosting paths and not the
-- other is not a feature, it is a bug with a schedule.
--
-- What the hub *does* own is the part that cannot be local: carrying an ask to
-- somebody, and holding it for them when they are not there.
--
-- ------- the handshake
--
--   1. ADD FRIEND sends mmo.friend_ask at a player standing in front of you.
--   2. The hub delivers it -- now if they are connected, on their next
--      welcome if they are not.  It keeps holding it until it is answered, so
--      a player who disconnects mid-prompt is asked again rather than never.
--   3. Their client prompts them, unless they are mid-battle or mid-trade, in
--      which case the prompt waits here until they are out of it.  A yes/no
--      box over a live fight is the thing this whole hold exists to avoid.
--   4. Their answer comes back as mmo.friend_answer -- to them now, or held
--      for them the same way if the asker has since gone offline.
--
-- Both sides write their own list, at the moment they consent: the asked side
-- when they press YES, the asker when the answer arrives.  Removal is sent on
-- (mmo.friend_remove) so the two lists cannot disagree about whether a
-- friendship exists -- one that only came off one side would leave the other
-- holding a row whose owner has to be asked for consent all over again.
--
-- Shaped like src/Party.lua for the protocol half (a transport and a ui handed
-- in, no engine modules, no love) and like src/Servers.lua for the storage
-- half (a file, mirrored into mod.save, both read through one sanitiser).
-- That is what lets the suite drive the whole handshake -- both sides of it --
-- and the persistence, under plain luajit.

local need, chunkMod = ...
local Config = need("Config")
local Wire = need("Wire")

local M = {}
M.__index = M

-- Where the mirror lives inside this mod's own save bucket.
local SAVE_KEY = "friends"

-- ------- where a list is filed
--
-- The hub half, normalised the way src/Client.lua's tokenAddr normalises it
-- and for the same reason: one hub typed two ways has to be one bucket, and
-- hosting has no address at all -- the local net is in-process -- so it falls
-- back to a fixed name.  A hosted game's list is as durable as any other: the
-- host is always "self" on their own copy, which is exactly the one hub they
-- can never mistype.
local function hubKey(address)
  if type(address) ~= "string" or address == "" then return "self" end
  local clean = address:lower():gsub("%s+", "")
  if clean == "" then return "self" end
  return clean
end

-- ...and the whole key, hub plus the name this copy is playing under.  Upper
-- cased through the same sanitiser the wire uses, so the bucket a list is
-- written to is the bucket the next session reads back.
local function bucketKey(address, name)
  local who = Wire.nameKey(name)
  if not who then return nil end
  return hubKey(address) .. "|" .. who
end

local function now()
  if type(os) ~= "table" or type(os.time) ~= "function" then return 0 end
  local ok, stamp = pcall(os.time)
  if ok and type(stamp) == "number" then return math.floor(stamp) end
  return 0
end

-- One row, as it comes back off disk or out of a save.
--
-- Checked exactly as hard as anything off the wire, for the reason
-- Servers.sanitise gives: a hand-edited file must not be able to put a name
-- the font cannot draw into a menu, or a row with no name at all into a list
-- every screen indexes by one.
local function sanitise(raw)
  if type(raw) ~= "table" then return nil end
  local name = Wire.name(raw.name)
  if not name then return nil end
  local added = tonumber(raw.added)
  return {
    name = name,
    key = name:upper(),
    added = (added and added > 0) and math.floor(added) or 0,
  }
end

-- ------- the store

function M.new(transport, ui, opts)
  opts = opts or {}
  return setmetatable({
    transport = transport,
    ui = ui,
    -- The facade is taken from opts so the suite can drive this against its
    -- stub mod; the chunk's own is the fallback, and keeps a caller that
    -- passes nothing from turning the first log line into a crash.
    mod = opts.mod or chunkMod,
    -- Which list is open.  nil while offline, which is what makes every
    -- mutator below a no-op rather than a write into a bucket nobody named.
    bucket = nil,
    -- key -> { name, key, added }, for the open bucket only.
    entries = {},
    -- Names asked this session and not yet answered.  Only a guard against
    -- asking twice: the hub is the thing that actually holds an ask, and it
    -- holds it for a week (Config.FRIEND_HOLD), so this is cleared with the
    -- connection rather than kept.
    outgoing = {},
    -- Asks that arrived while this player was in a battle or a trade, oldest
    -- first.  Drained by update() the moment they are out of it.
    held = {},
    -- The name the box currently on screen is about, or nil.
    asking = nil,
    -- Set by src/Client.lua to "is this player mid-fight or mid-session".
    -- Absent means never busy, which is what the suite drives it as.
    busy = nil,
  }, M)
end

function M:_warn(fmt, ...)
  local log = self.mod and self.mod.log
  if log and type(log.warn) == "function" then log:warn(fmt, ...) end
end

-- ------- persistence
--
-- Two mirrors, for the reason src/Servers.lua carries two: mod.save is RAM the
-- engine happens to flush with the rest of a save, nothing in connecting
-- writes one, and CONTINUE replaces the whole table -- so a friend made this
-- session and never saved would be gone by the next launch, which is exactly
-- the case a friends list exists for.  Reads prefer the file, because a save
-- reload is precisely when mod.save holds the older answer.
--
-- love is absent under the headless test interpreter, and every path here
-- answers "no file" when it is, which leaves the mod.save half as the whole
-- behaviour there rather than failing.

local function filesystem()
  if type(love) ~= "table" then return nil end
  if type(love.filesystem) ~= "table" then return nil end
  return love.filesystem
end

-- src.link.Json is already this mod's encoder, so a file of our own is not a
-- reason to carry a second one.  Resolved once and remembered, the failure
-- included: under the headless interpreter there is no engine to require from,
-- and asking again on every write would be a pcall per keypress.
local jsonModule, jsonTried = nil, false
local function json()
  if jsonTried then return jsonModule end
  jsonTried = true
  local ok, module = pcall(require, "src.link.Json")
  if ok and type(module) == "table" then jsonModule = module end
  return jsonModule
end

-- The whole file -- every bucket, not only ours -- and second whether it is
-- *there and unreadable*, which love.filesystem.read cannot say on its own: a
-- missing file and a failed read are the same nil.  The two want opposite
-- things from the writer, and getting that backwards is how a list is lost:
-- there is nothing to lose by writing over a file that is not there, and every
-- other save slot's friends to lose by writing over one that is and would not
-- open.
function M:_read()
  local fs, Json = filesystem(), json()
  if not (fs and Json) then return nil, false end

  local ok, body = pcall(fs.read, Config.FRIENDS_FILE)
  if not ok or type(body) ~= "string" then
    local exists = false
    if type(fs.getInfo) == "function" then
      local asked, info = pcall(fs.getInfo, Config.FRIENDS_FILE)
      exists = asked and type(info) == "table"
    end
    return nil, exists
  end
  -- An empty file is readable and says nothing, which is the same as no file.
  if body == "" then return nil, false end

  local decoded = Json.decode(body)
  if type(decoded) ~= "table" then
    self:_warn("%s is not readable as JSON -- delete it from the game's save "
      .. "folder to reset this copy's friends lists", Config.FRIENDS_FILE)
    return nil, false
  end
  return decoded, false
end

function M:_saved()
  local save = self.mod and self.mod.save
  if not save then return nil end
  local ok, buckets = pcall(save.get, save, SAVE_KEY)
  if not (ok and type(buckets) == "table") then return nil end
  return buckets
end

-- Our bucket's rows, in the order they are written and drawn: newest friend
-- first, ties broken by name so two copies of the same list never disagree
-- about the order.
function M:_rows()
  local out = {}
  for _, entry in pairs(self.entries) do out[#out + 1] = entry end
  table.sort(out, function(a, b)
    if a.added ~= b.added then return a.added > b.added end
    return a.key < b.key
  end)
  return out
end

-- Replace our bucket in both mirrors, and only ours.
--
-- The file is re-read first, because it holds every hub this copy plays on and
-- every trainer name it plays them under -- and a write of our cached table
-- alone would be a write that forgot all of them.
--
-- **The one thing this must never do is turn a read failure into a wipe.**  A
-- file that exists and would not open is left exactly as it is: the mirror
-- still took the change, and the file repairs itself the next time it reads.
function M:_persist()
  if not self.bucket then return false end
  local rows = self:_rows()

  local save = self.mod and self.mod.save
  if save then
    local buckets = self:_saved() or {}
    buckets[self.bucket] = rows
    pcall(save.set, save, SAVE_KEY, buckets)
  end

  local fs, Json = filesystem(), json()
  if not (fs and Json) then return false end

  local stored, unreadable = self:_read()
  if unreadable then
    self:_warn("%s could not be read, so this session's friends were not "
      .. "written to it and nothing in it was overwritten -- the list still "
      .. "works for this game; delete the file from the game's save folder if "
      .. "this repeats", Config.FRIENDS_FILE)
    return false
  end

  local out = {}
  if type(stored) == "table" then
    for key, value in pairs(stored) do
      if type(key) == "string" and type(value) == "table" then out[key] = value end
    end
  end
  out[self.bucket] = rows

  local ok, encoded = pcall(Json.encode, out)
  if not (ok and type(encoded) == "string") then
    self:_warn("could not encode %s (%s) -- friends made this session will "
      .. "not survive a relaunch; delete the file from the game's save folder "
      .. "if this repeats", Config.FRIENDS_FILE, tostring(encoded))
    return false
  end

  local called, wrote, why = pcall(fs.write, Config.FRIENDS_FILE, encoded)
  if not (called and wrote) then
    self:_warn("could not write %s (%s) -- friends made this session will be "
      .. "forgotten on relaunch unless the game is saved while connected",
      Config.FRIENDS_FILE, tostring(called and why or wrote))
    return false
  end
  return true
end

-- ------- opening and closing a list

-- The welcome landed: this is the hub, and this is who we are on it.
--
-- Read here rather than lazily, because every question the screens ask is
-- about *this* bucket and there is exactly one moment at which the bucket is
-- decided.  The save mirror goes in first and the file over the top of it, key
-- by key, because the file is the durable copy and mod.save is the one a
-- CONTINUE can rewind.
function M:setHub(address, name)
  self:reset()
  local bucket = bucketKey(address, name)
  if not bucket then
    self:_warn("could not work out which friends list belongs to this game, "
      .. "so START > MMO > FRIENDS will be empty here -- set a trainer name "
      .. "from START > MMO > CHARACTER and reconnect")
    return nil
  end
  self.bucket = bucket

  local function ingest(buckets)
    local rows = type(buckets) == "table" and buckets[bucket] or nil
    if type(rows) ~= "table" then return end
    for _, raw in ipairs(rows) do
      local entry = sanitise(raw)
      if entry and self:count() < Config.FRIENDS_MAX then
        self.entries[entry.key] = entry
      end
    end
  end

  ingest(self:_saved())
  ingest((self:_read()))
  return bucket
end

-- Everything goes, including a half-finished ask: a prompt left armed across a
-- disconnect would answer to a hub that is no longer listening, and an
-- outgoing name held past the connection would refuse the next session's first
-- ask with "you already asked them".
function M:reset()
  self.bucket, self.entries = nil, {}
  self.outgoing, self.held, self.asking = {}, {}, nil
end

-- ------- reading the list

function M:isOpen() return self.bucket ~= nil end

function M:count()
  local n = 0
  for _ in pairs(self.entries) do n = n + 1 end
  return n
end

function M:isFriend(name)
  local key = Wire.nameKey(name)
  return key ~= nil and self.entries[key] ~= nil
end

-- A copy, newest first, so a screen holding the list across a frame cannot be
-- surprised by a friendship that ended underneath it.
function M:list()
  local out = {}
  for index, entry in ipairs(self:_rows()) do
    out[index] = { name = entry.name, added = entry.added }
  end
  return out
end

-- The list as the FRIENDS screen draws it: everybody who is online first, then
-- everybody who is not, each group newest friend first.
--
-- Both halves matter and they answer different questions.  Newest first is
-- what makes a friend you just made the row you land on rather than one you
-- scroll to.  Online first is what makes the screen worth opening at all: the
-- list is mostly people who are not there, and a friend who *is* there is the
-- only row that leads anywhere -- pressing A on them opens the same menu
-- walking up to them does.
--
-- `roster` is the live one; the player it belongs to is deliberately not in it
-- (Roster:isSelf), which costs nothing here because nobody is their own
-- friend.  Pure apart from that, so the ordering is pinned by the suite rather
-- than by looking at a screenshot.
function M:sorted(roster)
  local online = {}
  if roster and roster.sorted then
    for _, player in ipairs(roster:sorted()) do
      local key = Wire.nameKey(player.name)
      -- First writer wins: two strangers wearing one name on a hub that never
      -- claimed it is a real state, and picking the same one of them every
      -- frame is what keeps the row from flickering between the two.  The
      -- roster is sorted by name and then id, so "the same one" is stable.
      if key and not online[key] then online[key] = player end
    end
  end

  local out = {}
  for _, entry in ipairs(self:_rows()) do
    out[#out + 1] = {
      name = entry.name,
      added = entry.added,
      player = online[entry.key],
    }
  end
  table.sort(out, function(a, b)
    local aOn, bOn = a.player ~= nil, b.player ~= nil
    if aOn ~= bOn then return aOn end
    if a.added ~= b.added then return a.added > b.added end
    return a.name:upper() < b.name:upper()
  end)
  return out
end

-- ------- writing the list

-- Add somebody, both halves of which are one moment: the row and the file.
--
-- Bounded by Config.FRIENDS_MAX, and refused rather than trimmed when it is
-- reached -- dropping the oldest friend to make room for a new one would be
-- this mod deciding who somebody has stopped being friends with.
function M:_add(name)
  local clean = Wire.name(name)
  if not (self.bucket and clean) then return nil end
  local key = clean:upper()
  local held = self.entries[key]
  if held then return held end
  if self:count() >= Config.FRIENDS_MAX then return nil end
  local entry = { name = clean, key = key, added = now() }
  self.entries[key] = entry
  self:_persist()
  return entry
end

function M:_drop(name)
  local key = Wire.nameKey(name)
  if not (self.bucket and key) then return nil end
  local gone = self.entries[key]
  if not gone then return nil end
  self.entries[key] = nil
  self:_persist()
  return gone
end

-- ------- asking

-- ADD FRIEND, against a player who is standing in front of you.
--
-- Every refusal here is one the menu could not see, so each says which it is:
-- a list that is full, a friendship that already exists, and an ask already in
-- flight are three different things to do next about.
function M:ask(peer)
  if not (peer and peer.id and peer.name) then return false end
  if not self.bucket then
    self.ui:say("You're not in\na game.")
    return false
  end
  local key = Wire.nameKey(peer.name)
  if not key then return false end
  if self.entries[key] then
    self.ui:say(("You're already\nfriends with %s."):format(peer.name))
    return false
  end
  if self:count() >= Config.FRIENDS_MAX then
    self.ui:say(("Your friends list\nis full (%d)."):format(Config.FRIENDS_MAX))
    return false
  end
  if self.outgoing[key] then
    self.ui:say(("You already asked\n%s."):format(peer.name))
    return false
  end

  self.outgoing[key] = true
  self.transport:send(Wire.FRIEND_ASK, { to = peer.id })
  -- Said out loud, and said this way on purpose: the hub holds the ask for a
  -- player who logs out before answering, so "they will be asked" is the true
  -- sentence and "waiting for an answer" would be a promise about a round trip
  -- that may not happen today.
  self.ui:say(("Asked %s to be\nfriends."):format(peer.name))
  return true
end

-- REMOVE FRIEND.  Local first, then told: pressing it has to work on a
-- connection that is already dying, which is the same rule Party:leave
-- follows.  Their copy comes off when the hub delivers the message -- now, or
-- on their next welcome.
function M:remove(name)
  local gone = self:_drop(name)
  if not gone then return false end
  self.outgoing[gone.key] = nil
  if self.transport and self.transport.isReady and self.transport:isReady() then
    self.transport:send(Wire.FRIEND_REMOVE, { toName = gone.name })
  end
  return true
end

-- ------- answering

-- Somebody wants to be friends -- now, or a week ago, if the hub has been
-- holding this while we were away.
--
-- Three answers, and only one of them is a question.  Already friends is
-- answered yes without asking anybody: consent was given once and the two
-- lists have simply drifted (their answer never reached us, or a hub restarted
-- holding it), so re-asking the player to agree to a friendship they already
-- have would be the mod admitting it lost something.  A full list is answered
-- no, because there is nowhere to put them.  Everything else is the box.
function M:onAsk(game, msg)
  local name = Wire.name(msg.name)
  if not name then return end
  local key = name:upper()

  if not self.bucket then
    -- No list open means no welcome yet, which the hub does not deliver
    -- before; nothing sensible to answer with, and answering no would file a
    -- refusal nobody made.
    return
  end

  if self.entries[key] then
    self:_answer(name, true)
    return
  end
  if self:count() >= Config.FRIENDS_MAX then
    self:_answer(name, false)
    self.ui:say(("%s asked to be\nfriends, but your\nlist is full."):format(name))
    return
  end
  -- Already asked, or already queued: one ask per name, so a hub re-delivering
  -- one it is still holding cannot stack two boxes about the same person.
  if self.asking == key then return end
  for _, held in ipairs(self.held) do
    if held.key == key then return end
  end

  self.held[#self.held + 1] = { key = key, name = name }
  self:_drain(game)
end

-- Put the next held ask on screen, if there is one and this is a moment for
-- it.
--
-- The wait is the whole reason the queue exists: a yes/no box over a live
-- battle or a trade is the failure src/Sessions.lua already refuses invites to
-- avoid, and a friend request is the one ask here that can afford to wait --
-- the hub is holding it, so nothing is lost by asking in a minute.
function M:_drain(game)
  if self.asking or #self.held == 0 then return false end
  if self.busy and self.busy(game) then return false end

  local ask = table.remove(self.held, 1)
  self.asking = ask.key
  self.ui:confirm(game, ("%s wants to be\nfriends!"):format(ask.name),
    function(yes)
      self.asking = nil
      if yes then self:_add(ask.name) end
      self:_answer(ask.name, yes and true or false)
    end)
  return true
end

function M:_answer(name, accept)
  if not (self.transport and self.transport.isReady
          and self.transport:isReady()) then
    return false
  end
  self.transport:send(Wire.FRIEND_ANSWER, { toName = name, accept = accept })
  return true
end

-- The answer to an ask of ours.
--
-- The hub only forwards one it was actually holding, so arriving at all is the
-- proof that this is an answer to a question we asked -- which is what keeps a
-- modified client from adding itself to a stranger's list.
function M:onAnswer(msg)
  local name = Wire.name(msg.name)
  if not (name and self.bucket) then return end
  local key = name:upper()
  self.outgoing[key] = nil

  if msg.accept ~= true then
    self.ui:say(("%s said no."):format(name))
    return
  end
  if self.entries[key] then return end
  if not self:_add(name) then
    self.ui:say(("Your friends list\nis full (%d)."):format(Config.FRIENDS_MAX))
    return
  end
  self.ui:say(("%s is now your\nfriend!"):format(name))
end

-- They took us off their list.
--
-- Silent, and deliberately: there is nothing here for the player to do about
-- it, and a box announcing it -- possibly a week late, over whatever they are
-- doing -- would be the mod going out of its way to deliver bad news nobody
-- asked for.  The row simply is not there the next time they look.
function M:onRemoved(msg)
  local name = Wire.name(msg.name)
  if not (name and self.bucket) then return end
  self.outgoing[name:upper()] = nil
  self:_drop(name)
end

-- A player left the game.  Nothing to undo: the hub holds an unanswered ask
-- rather than dropping it, so an ask pointed at somebody who logs out is
-- answered when they come back -- which is the whole difference between this
-- and a party invite (src/Party.lua's onPeerGone, which has to clear one).
-- The name stays in `outgoing` for the same reason: it is still outstanding.

function M:update(game, dt)  -- luacheck: ignore dt
  self:_drain(game)
end

return M
