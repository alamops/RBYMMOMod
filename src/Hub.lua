-- The hub, as pure logic.
--
-- This is the same relay `server/hub.js` implements, ported to Lua so a
-- player can host from inside the game. It owns who is connected, where
-- they last said they were, which two players are paired, and the player
-- cap the host chose. Trade still runs inside the two clients on the
-- engine's own link code, and its `mmo.relay` payloads pass through unread.
--
-- **Battle does not.** From PROTOCOL 10 a battle this hub brokers is
-- resolved *here*, by src/BattleSim/Turn.lua, and the clients receive an
-- ordered stream of events they draw rather than rolling their own. The
-- mediated-battles section below is that plumbing, and server/lib/relay.js
-- runs the same one over the same message types -- a client cannot tell
-- which of the two hosting paths refereed its fight.
--
-- **No sockets appear anywhere below.** Everything talks to *peer handles*
-- -- any table answering `:send(msg)` and `:close()`. `HostServer` supplies
-- socket-backed ones; the host's own client supplies an in-process one; the
-- suite supplies fakes. That is what lets the cap, the scope routing and
-- the session pairing be tested under plain luajit, which has no luasocket
-- and no LOVE.
--
-- Every hub carries a join code.  Hello is answered with a nonce and the
-- peer owes an HMAC of it keyed by the code (plan §3.2); the code itself
-- never crosses the wire, and a peer that has not answered is on nobody's
-- roster.  server/lib/relay.js runs the same handshake message for message,
-- so a joining client cannot tell the two hosting paths apart.
--
-- This file will still build a hub with no code, and that is on purpose:
-- it is pure logic, and the uncoded path is the only way the suite can
-- exercise admit-at-hello alongside admit-after-challenge under plain
-- luajit.  **Only the suite may make one.**  Every hub a player can reach
-- comes from HostServer:start, which refuses outright without a code, so
-- an uncoded hub means "a fixture", never "a LAN game left open" -- there
-- is no longer any way for a host to ask for one.
--
-- Everything arriving here is untrusted -- it comes from another player's
-- process, and a modified one is a normal thing to meet -- so every field
-- is re-derived through Wire before it is believed.

local need = ...
local Config = need("Config")
local Wire = need("Wire")
local Sha256 = need("Sha256")
local Rank = need("Rank")
-- The turn machine, and the one thing in this file that is not pure routing.
-- A battle this hub brokers is *resolved* here from PROTOCOL 10 onwards, so
-- the header's "it does not simulate anything" now holds for trade alone --
-- see the mediated-battles section below for what changed and why.
local Turn = need("BattleSim/Turn")
local Effects = need("BattleSim/Effects")

local M = {}
M.__index = M

-- ------- the entropy pool
--
-- Both credentials this mod mints are drawn from here: the challenge nonces
-- below, and the join code src/Client.lua offers on the HOST screen.  One
-- pool, because they are one process's worth of unpredictability and
-- splitting it would halve both.  It lives in this file rather than one of
-- its own because Client already reaches Hub (through HostServer) while Hub
-- must never reach Client -- this is the only side of that edge a shared
-- pool can sit on without a cycle.
--
-- **What it is.** A 256-bit SHA-256 state that varying material is folded
-- into over the whole session -- frame durations, os.clock() and its
-- deltas, live heap size, love.math.random() where it exists, the timing of
-- the player's own button presses -- plus a short burst of os.clock()
-- scheduling jitter taken at the moment of a draw.  Every draw hashes the
-- state with a counter and then ratchets the state forward, so no two draws
-- repeat and a leaked draw does not give up the state that made it.
--
-- **What it is not: a CSPRNG.** There is no such source reachable from a
-- mod that declares only `network` -- LOVE ships no randomBytes,
-- love.math.random is a seeded xorshift, and /dev/urandom would mean a
-- filesystem permission this mod does not have.  Honest numbers, since the
-- format of a join code implies 80 bits and this does not deliver them:
--
--   * Drawn cold, before anything has been stirred in, the pool holds only
--     an instantaneous sample -- heap size, a fresh table's address, the
--     wall clock to the second, the CPU clock.  That is roughly 35-45 bits
--     against someone who knows the machine and roughly when it started.
--   * Drawn from a game that has been playing for even a few seconds, the
--     pool has absorbed hundreds of frame-timing and clock samples whose
--     low microseconds are genuine scheduling noise.  The input entropy
--     there runs well past 80 bits; what we are willing to *claim* is 64,
--     because the per-sample jitter is an estimate rather than a
--     measurement and nothing here health-tests the pool.
--
-- So: substantially better than one os.time() sample, and still not what a
-- hub facing the open internet should rely on -- that one is the dedicated
-- server in server/, whose nonces come from crypto.randomBytes.

local Entropy = {}
Entropy.__index = Entropy

-- Samples are parked in a table that is allocated once and written in place
-- for the life of the process: stirring happens on the game's fixed step,
-- and a hot path that allocates every frame is exactly what the engine's
-- rules forbid.  Four numbers a stir, 96 slots, so the fold -- which does
-- allocate, and hashes -- runs once every 24 stirs rather than every frame.
local POOL_SLOTS = 96
local STIR_WIDTH = 4
-- %.17g, not tostring: tostring rounds a double to 14 significant digits
-- and the low digits of a clock sample are the whole point of taking it.
local FOLD_FORMAT = string.rep("%.17g|", POOL_SLOTS)
local unpack = unpack or table.unpack

-- How far the draw-time burst goes: stop after this many observed clock
-- ticks, and never spin longer than the cap regardless.  On a platform
-- whose os.clock() has microsecond resolution this is tens of
-- microseconds; on one with a 10ms tick it falls out at the cap having
-- learnt nothing, which is a shrug, not a hang.
local BURST_TICKS = 32
local BURST_SPINS = 20000

-- The instantaneous sample a pool starts from, and all a cold draw has.
local function coldSample()
  local parts = {
    tostring(collectgarbage("count")),   -- live heap, in KB with a fraction
    tostring({}),                        -- where a fresh table landed
  }
  if os then
    if os.time then parts[#parts + 1] = tostring(os.time()) end
    if os.clock then parts[#parts + 1] = string.format("%.17g", os.clock()) end
  end
  return table.concat(parts, "|")
end

-- Both arguments are for the suite, and the game passes neither: `seed`
-- starts two pools in the same state, and `clock` drives the draw-time
-- burst off something repeatable.  Together they make a pool a pure
-- function of what is stirred into it, which is what lets the suite prove
-- the stirred material is what makes two pools' draws differ -- the exact
-- property the one-instantaneous-sample code this replaced did not have.
function Entropy.new(seed, clock)
  local self = setmetatable({
    state = nil,
    samples = {},
    cursor = 0,
    stirs = 0,
    draws = 0,
    clockFn = type(clock) == "function" and clock or (os and os.clock),
  }, Entropy)
  for i = 1, POOL_SLOTS do self.samples[i] = 0 end
  self.state = Sha256.bytes("rby_mmo/entropy/1|"
    .. (type(seed) == "string" and seed or coldSample()))
  return self
end

-- Fold the parked samples into the state.  Slots untouched since the last
-- fold simply go round again; re-hashing a value cannot subtract from what
-- the state already knows.
function Entropy:fold()
  if type(self.state) ~= "string" then return end
  local mixed = Sha256.bytes(self.state
    .. string.format(FOLD_FORMAT, unpack(self.samples, 1, POOL_SLOTS)))
  if type(mixed) == "string" then self.state = mixed end
  self.cursor = 0
end

-- Four numbers, written in place.  Callers pass whatever varies cheaply
-- where they stand; nil counts as zero rather than being an error, because
-- a caller on a platform missing one of its sources should keep stirring
-- the others rather than stop.
function Entropy:stir(a, b, c, d)
  local samples, n = self.samples, self.cursor
  samples[n + 1] = tonumber(a) or 0
  samples[n + 2] = tonumber(b) or 0
  samples[n + 3] = tonumber(c) or 0
  samples[n + 4] = tonumber(d) or 0
  n = n + STIR_WIDTH
  self.stirs = self.stirs + 1
  if n >= POOL_SLOTS then self:fold() else self.cursor = n end
end

-- Spin on os.clock() until it moves, a bounded number of times, stirring in
-- how long each move took to arrive.  The gap between two clock ticks is
-- scheduler noise, which is the one genuinely unpredictable thing a process
-- with no random device can still observe about the machine it is on.
function Entropy:burst()
  local clock = self.clockFn
  if not clock then return end
  local previous, ticks, spins = clock(), 0, 0
  while ticks < BURST_TICKS and spins < BURST_SPINS do
    spins = spins + 1
    local now = clock()
    if now ~= previous then
      ticks = ticks + 1
      self:stir(now, spins, ticks, now - previous)
      previous = now
    end
  end
end

-- `count` raw bytes off the pool, or nil plus a reason -- never a raise, so
-- a caller inside a mod callback can log it and name a remediation.  32 is
-- the ceiling because one draw is one SHA-256 output; nothing here wants
-- more, and stretching would be inventing a KDF nobody asked for.
function Entropy:bytes(count)
  local n = tonumber(count)
  if not n or n < 1 or n > 32 or n ~= math.floor(n) then
    return nil, "entropy: 1..32 bytes, asked for " .. tostring(count)
  end
  self.draws = self.draws + 1
  self:burst()
  self:fold()
  if type(self.state) ~= "string" then
    return nil, "entropy: the pool has no state to draw from"
  end
  local out = Sha256.bytes(self.state .. "|draw|" .. self.draws)
  -- Ratchet: the state that produced `out` is destroyed in the same breath,
  -- so recovering one draw says nothing about the next.
  local moved = Sha256.bytes(self.state .. "|step|" .. self.draws)
  if type(out) ~= "string" or type(moved) ~= "string" then
    return nil, "entropy: the pool could not be hashed"
  end
  self.state = moved
  return out:sub(1, n)
end

-- A join code in normalised form (no dashes -- Wire.formatCode puts those
-- in for display).  256 is exactly 8 * 32, so folding a byte into the
-- alphabet is even and no character is likelier than another.
function Entropy:code()
  local raw, why = self:bytes(Config.CODE_LEN)
  if not raw then return nil, why end
  local alphabet, out = Config.CODE_ALPHABET, {}
  for i = 1, Config.CODE_LEN do
    local index = raw:byte(i) % #alphabet
    out[i] = alphabet:sub(index + 1, index + 1)
  end
  return table.concat(out)
end

-- One pool per process, which is the point of a pool.  Client stirs this
-- one on every fixed step and draws join codes from it; every hub that is
-- not handed its own draws its nonces from it.
Entropy.shared = Entropy.new()

M.Entropy = Entropy

function M.new(opts)
  opts = opts or {}
  return setmetatable({
    limit = Config.clampPlayers(opts.maxPlayers),
    -- Absent is nil, never "": a hub with no code admits anyone who says
    -- hello, which is a fixture, not a hosting mode -- see the header.
    -- Re-normalised on the way in because a code that does not survive
    -- normalisation is a code no player could type; Wire.code is
    -- idempotent, so a caller that already normalised loses nothing by it.
    joinCode = Wire.code(opts.joinCode),
    clients = {},     -- id -> client (greeted or not)
    count = 0,        -- connections
    players = 0,      -- of those, the ones that have been admitted
    sessions = {},    -- sessionId -> { a, b, kind }
    parties = {},     -- partyId -> { memberId, ... }
    -- Ranked PVP.  The board is what a rating *is* -- the hub owns it,
    -- because a client that owned its own score would simply write itself a
    -- better one -- and `matches` is the paperwork for one battle: who was
    -- in it and what each side has said about how it ended.  A caller may
    -- hand over a board that was loaded from somewhere (the dedicated hub
    -- does; a hosted game starts fresh each time it is opened).
    board = opts.board or Rank.newBoard(),
    matches = {},     -- sessionId -> { a, b, aName, bName, reports, endedAt }
    nextId = 1,
    nextSession = 1,
    nextParty = 1,
    -- The four-way PARTY BATTLE asks in flight: id -> { asker, sideA, sideB,
    -- everyone, answers, needed, startedAt }.  Kept here rather than on the
    -- asker because three other clients are holding a box for it, and a state
    -- four connections can invalidate belongs to the thing that outlives all
    -- four.
    coopAsks = {},
    -- id -> { clientId, ... }: who mmo.coop_relay fans out to. Separate from
    -- coopAsks because it starts where an ask *ends*, and outlives it.
    coopBattles = {},
    -- Paperwork for a party-vs-party co-op battle: id -> { pairs, reports,
    -- startedAt }. Kept apart from `matches` because a co-op battle is four
    -- reports rather than two, and folding them into one table would mean
    -- every settlement had to ask which shape it was looking at.
    coopMatches = {},
    -- The fights this hub is *running*: id -> the record openMediatedBattle
    -- builds. Keyed by the id the fight was already known under -- a session
    -- id for a 1v1, a co-op group id for a 2v2 -- rather than by an id of its
    -- own, because every message about a battle already carries one of those
    -- and a second numbering would be a mapping to keep in step for no gain.
    -- Those two numberings are minted by two counters that know nothing of each
    -- other, which is why each stamps a letter of its own on what it mints -- one
    -- table, two id spaces, and no way for the second "1" to land on the first's
    -- record.
    --
    -- A record exists from the moment the fight is agreed and holds nothing
    -- but a roster until a ruleset and every party arrive; `sim` is what says
    -- the hub has taken it over, and it is the flag every hard cut in this
    -- file is gated on.
    battles = {},
    -- Friend traffic the hub is holding for somebody who is not here.
    --
    -- nameKey -> { { kind, name, accept, at }, ... }, oldest first.  Keyed by
    -- *name* and not by connection, which is the whole reason this table
    -- exists: an ask whose target logs out before answering has to be asked
    -- again when they come back, and there is no connection left to hang it
    -- on.  See the friend handlers for what each kind is and why an answer is
    -- the only one the hub checks before passing on.
    friendHolds = {},
    friendHeld = 0,
    nextCoopAsk = 1,
    nextNonce = 0,
    -- The process-wide pool unless a caller hands over its own; only the
    -- suite does, so that two hubs can be started from identical pools and
    -- fed different material.
    entropy = opts.entropy or Entropy.shared,
    -- Optional. Called as onDrop(reason, clientId, total) the *first* time a
    -- relay payload is refused for a given connection, and never again for
    -- it. This file stays pure logic with no logger of its own, so the seam
    -- hands the fact to a caller inside a mod callback that can name a
    -- remediation -- and the once-per-connection rule is why it is safe to
    -- wire to a log at all: a peer that sends nothing but junk costs one
    -- line, not a flooded terminal.
    onDrop = opts.onDrop,
    -- Optional, same shape as onDrop: a handler that threw. Hub stays pure
    -- logic with no logger of its own, so the seam hands the fact to HostServer
    -- (or a suite) that can name a remediation. Mirror of relay.js handle()'s
    -- try/catch -- a Turn throw must not take the LAN host down with it.
    onHandlerError = opts.onHandlerError,
    clock = 0,
  }, M)
end

-- A refused relay payload used to be four bare `return`s. Trade and battle
-- ride that path and nothing else does, so a silent refusal there is a trade
-- that half-happened: one side applied it, the other never heard. Whatever
-- the cause turns out to be, it should never again be invisible.
local function noteDrop(self, client, reason)
  client.relayDrops = (client.relayDrops or 0) + 1
  if client.relayDrops == 1 and self.onDrop then
    self.onDrop(reason, client.id, client.relayDrops)
  end
end

-- Full means no room for another *player*. A connection that has not said
-- hello is not a player, and must not be able to hold a seat.
function M:isFull()
  return self.players >= self.limit
end

function M:pendingCount()
  return self.count - self.players
end

-- Is this playerId already seated on a ready connection?
function M:idInUse(playerId, except)
  if not playerId then return false end
  for id, other in pairs(self.clients) do
    if other ~= except and other.ready and other.id == playerId then
      return true
    end
  end
  return false
end

-- Rekey a pre-hello ephemeral id to the persistent playerId.
function M:rekeyClient(client, playerId)
  if not client or not playerId or client.id == playerId then return true end
  if self.clients[playerId] and self.clients[playerId] ~= client then
    return false
  end
  -- Keep the ephemeral accept-id as an alias index so callers that still hold
  -- the pre-hello id (HostServer) can find this client after rekey. Not stored
  -- in self.clients under both keys -- that would double-count.
  local oldId = client.id
  self.clients[oldId] = nil
  client.ephemeralId = oldId
  client.id = playerId
  self.clients[playerId] = client
  self.byEphemeral = self.byEphemeral or {}
  self.byEphemeral[oldId] = client
  return true
end

-- Resume a mediated fight paused in reconnect grace for this playerId.
function M:reattachBattle(client)
  if not client or not client.ready then return end
  for _, record in pairs(self.battles) do
    if record.sim and not record.settled then
      local member = false
      for _, mid in ipairs(record.memberIds or {}) do
        if mid == client.id then member = true; break end
      end
      if member and record.sim:reconnect(client.id) then
        client.battleId = record.id
        self:flushBattle(record)
        return
      end
    end
  end
end

-- Is this hub asking for a join code?  Unchanged in meaning, and still
-- asked rather than assumed, because a hub built without one is still a
-- thing this file can be handed -- by the suite, and by nobody else.  The
-- code itself stays here: nothing outside needs it, and the fewer places
-- hold it the fewer can leak it.
function M:requiresCode()
  return self.joinCode ~= nil
end

-- A fresh challenge nonce, 16 bytes as lowercase hex -- the same shape
-- server/lib/auth.js emits, so both hosting paths challenge identically.
--
-- The bytes come off the session's entropy pool (see its header for what
-- that is worth, and what it is not: it is not crypto.randomBytes, and the
-- comment above does not pretend otherwise).  The counter and the host's
-- uptime go in on top of the draw so that two nonces in one run cannot
-- collide even in the hypothetical where the pool repeats itself -- a
-- repeated nonce is the one failure that would reopen the replay window
-- this whole exchange exists to close.
function M:newNonce()
  self.nextNonce = self.nextNonce + 1
  local raw = self.entropy and self.entropy:bytes(Config.NONCE_HEX / 2)
  -- Both calls answer nil plus a reason rather than raising; the caller
  -- turns a nil nonce into a refusal the player can read.
  if type(raw) ~= "string" then return nil end
  local digest = Sha256.hex(raw .. "|" .. self.nextNonce .. "|" .. self.clock)
  if type(digest) ~= "string" then return nil end
  return digest:sub(1, Config.NONCE_HEX)
end

-- ------- plumbing

local function send(client, msgType, payload)
  if not client or not client.peer then return end
  local msg = {}
  if type(payload) == "table" then
    for k, v in pairs(payload) do msg[k] = v end
  end
  msg.type = msgType
  client.peer:send(msg)
end

local function presenceOf(client)
  return {
    id = client.id,
    name = client.name,
    sprite = client.sprite,
    map = client.map,
    x = client.x,
    y = client.y,
    facing = client.facing,
    busy = client.sessionId ~= nil,
    -- Whether, not which.  Everyone needs this -- it is what decides
    -- whether their menus offer to invite this player -- and nobody outside
    -- the party needs the id, so the id does not leave the hub.
    party = client.partyId ~= nil,
    -- One question only: was that step a fast one.  Not "why" -- a sprint on
    -- foot and a bike both cover a tile in 8 frames, so both set this and
    -- neither is told apart, which is all a watcher can draw anyway.  Unlike
    -- busy, this hub cannot work it out: it never sees the B button or the
    -- bike, so the client is the only authority and this is what it last
    -- reported.
    fast = client.fast == true,
    profile = client.profile,
    -- Carried with presence rather than with the card: a rating moves while
    -- the player is standing there, and the card is a snapshot of their
    -- hello. Every roster row and every trainer card reads this field.
    points = client.points or Config.RANK_START,
  }
end

function M:broadcast(msgType, payload, exceptId)
  for id, client in pairs(self.clients) do
    if id ~= exceptId and client.ready then send(client, msgType, payload) end
  end
end

-- One sentence, one place.  Both the courtesy refusal at hello and the
-- authoritative one in admit say it, and a player must not be able to tell
-- which of the two turned them away.
function M:fullMessage()
  return ("This hub is full (%d players)."):format(self.limit)
end

function M:refuse(peer, message)
  peer:send({ type = Wire.ERROR, message = message })
  peer:close()
end

-- Refuse someone who has a client record, and drop it in the same breath.
-- A connection turned away at hello will never become a player, so leaving
-- it in the table would hold a pending slot until the reaper came round.
function M:refuseClient(client, message)
  self:refuse(client.peer, message)
  self:drop(client)
end

-- ------- connection lifecycle

-- A peer that got this far has a socket (or a loopback) but has not said
-- hello yet, so it is not a player and does not appear on anyone's roster.
--
-- The player cap is therefore NOT applied here -- that is checked at hello.
-- Charging it on connect meant a peer that connected and said nothing held
-- a seat forever, so four silent sockets could lock everyone out of a
-- four-player game. What is bounded here is the number of un-greeted
-- connections, and update() reaps the ones that never introduce themselves.
--
-- `trusted` is the one exemption from the join code, and only HostServer's
-- in-process peer gets it: that handle is created inside this process and
-- cannot be reached from a socket, and challenging it would mean asking the
-- host to type the code they just chose in order to enter their own game.
function M:accept(peer, trusted)
  if self:pendingCount() >= Config.MAX_PENDING then
    self:refuse(peer, "Too many connections. Try again.")
    return nil
  end
  local client = {
    since = self.clock,
    id = tostring(self.nextId),
    peer = peer,
    trusted = trusted and true or false,
    ready = false,
    name = nil,
    sprite = Config.DEFAULT_SPRITE,
    map = nil, x = nil, y = nil, facing = "down",
    fast = false,     -- nobody arrives mid-stride; the first move says otherwise
    sessionId = nil,
    pendingTo = nil,
    partyId = nil,
    partyPendingTo = nil,   -- the invite this client is waiting on an answer to
    lastChat = -math.huge,
    -- gated on the chat window too: it is prose on a partner's screen
    lastPartyEvent = -math.huge,
    lastSprite = -math.huge,   -- last mid-session character change
    -- gated on the same window: a friend ask is a modal on somebody else's
    -- screen, so it is rationed like the other things that are
    lastFriendAsk = -math.huge,
    hello = nil,      -- what it said, held until it is admitted
    nonce = nil,      -- the challenge it still owes an answer to
  }
  self.nextId = self.nextId + 1
  self.clients[client.id] = client
  self.count = self.count + 1
  return client
end

-- Take the seat: publish the presence captured at hello and tell everyone.
--
-- Reached straight from hello on a hub with no code, and from a passing
-- mmo.auth on one with a code.  It is the only way onto the roster, which
-- is the point: a peer that still owes an answer must not be visible to,
-- or addressable by, the players already in the game.
--
-- **The cap is charged here, so it is checked here.** Checking it only at
-- hello held on a hub with no code, where hello admits in the same breath,
-- and failed on one with a code: every peer that greeted while there was
-- room passed a check nobody repeated, then all of them answered and all of
-- them were seated -- six players on a hub built for two.  The hello check
-- stays as a courtesy, so a peer arriving at an already-full hub hears so
-- at once instead of after a challenge round trip, but this is the gate.
-- server/lib/relay.js puts its check in the same place for the same reason.
--
-- Returns true when the client was seated.
function M:admit(client)
  if self:isFull() then
    self:refuseClient(client, self:fullMessage())
    return false
  end
  local hello = client.hello or {}
  local playerId = hello.playerId
  if not playerId then
    self:refuseClient(client, "That player id can't be used here.")
    return false
  end
  if self:idInUse(playerId, client) then
    self:refuseClient(client, "You're already connected.")
    return false
  end
  if not self:rekeyClient(client, playerId) then
    self:refuseClient(client, "You're already connected.")
    return false
  end

  client.name = hello.name
  client.sprite = hello.sprite or Config.DEFAULT_SPRITE
  client.profile = hello.profile
  client.map, client.x, client.y = hello.map, hello.x, hello.y
  client.facing = hello.facing or "down"
  client.hello, client.nonce = nil, nil
  client.ready = true
  -- PROTOCOL 16: playerId is the account-shaped identity. Everyone with a
  -- valid id scores; display name is cosmetic on the board.
  client.ranked = true
  client.mintedToken = nil
  self.board:seen(client.id, client.name, client.sprite)
  client.points = self.board:points(client.id)
  self.players = self.players + 1

  self:reattachBattle(client)

  local players = {}
  for id, other in pairs(self.clients) do
    if other.ready and id ~= client.id then
      players[#players + 1] = presenceOf(other)
    end
  end
  send(client, Wire.WELCOME, {
    id = client.id, players = players, points = client.points,
    ranked = true,
  })
  self:broadcast(Wire.JOIN, { player = presenceOf(client) }, client.id)
  -- Last, and after the welcome on purpose: a friend ask the hub has been
  -- holding is a box in front of this player, and a box needs a client that
  -- already knows who it is and which list it is answering from.  Also after
  -- the broadcast, so nothing that could throw sits between the join
  -- announcement and the rest of the game hearing it.
  self:flushFriendHolds(client)
  return true
end

function M:drop(client)
  if not client or not self.clients[client.id] then return false end
  self:endSession(client, "peer_left")
  -- Before endParty, deliberately: clearCoopOffer finds the partner *through*
  -- the party, so withdrawing after the party is gone would withdraw into
  -- nothing and leave the partner holding an offer for somebody who has left
  -- the game.
  self:clearCoopOffer(client, "gone")
  self:clearCoopAsks(client, "gone")
  -- A fight the hub is *running* does not end because one of its players
  -- vanished: it pauses on the reconnect grace and forfeits when that runs
  -- out.  leaveBattle answers true only in that case, and only then is the
  -- group left standing.  Everything else -- a fight still collecting parties,
  -- a co-op group on the legacy client-simulated path -- closes exactly as it
  -- always did, because the three left would otherwise keep relaying into an
  -- id that includes somebody who is not there.
  local fighting = self:leaveBattle(client)
  if client.coopBattleId and not fighting then
    self:closeCoopBattle(client.coopBattleId)
  end
  -- A party outlives a trade but not a connection: the other member is told
  -- while this one is still in the table, so the presence that goes out with
  -- it is the one where they are no longer in a party.
  self:endParty(client, "peer_left")
  self.clients[client.id] = nil
  if client.ephemeralId and self.byEphemeral then
    self.byEphemeral[client.ephemeralId] = nil
  end
  self.count = self.count - 1
  if client.ready then self.players = self.players - 1 end
  -- an outstanding request pointed at a player who just left would let the
  -- asker wait forever for an answer nobody can give
  for _, other in pairs(self.clients) do
    if other.pendingTo == client.id then other.pendingTo = nil end
    if other.partyPendingTo == client.id then other.partyPendingTo = nil end
  end
  if client.ready then
    self:broadcast(Wire.PART, { id = client.id }, client.id)
  end
  return true
end

-- ------- sessions

function M:peerOf(client)
  local session = client.sessionId and self.sessions[client.sessionId]
  if not session then return nil end
  local otherId = session.a == client.id and session.b or session.a
  return self.clients[otherId]
end

function M:endSession(client, reason)
  local id = client.sessionId
  if not id then return end
  -- Leaving the session is leaving the field, not conceding it. A mediated
  -- fight starts its reconnect grace here rather than ending on the spot, so
  -- a player who backed out by accident gets the same window a dropped
  -- socket does -- and a player who backed out on purpose still has to sit
  -- out the grace rather than voiding a battle they were losing.
  self:leaveBattle(client)
  local session = self.sessions[id]
  self.sessions[id] = nil
  client.sessionId = nil

  -- A battle's paperwork outlives its session, briefly.
  --
  -- The two players do not finish at the same instant -- each is reading
  -- its own end-of-battle messages -- and whichever leaves first takes the
  -- session down with it, so scoring only while the session is live would
  -- score nothing at all. The match therefore starts a clock here instead
  -- (Config.RANK_REPORT_GRACE) and update() reaps it.
  local match = self.matches[id]
  if match and not match.endedAt then match.endedAt = self.clock end

  if session then
    local otherId = session.a == client.id and session.b or session.a
    local other = self.clients[otherId]
    if other and other.sessionId == id then
      other.sessionId = nil
      send(other, Wire.SESSION_END, { reason = reason })
      self:broadcast(Wire.MOVE, presenceOf(other), other.id)
    end
  end
  if self.clients[client.id] then
    self:broadcast(Wire.MOVE, presenceOf(client), client.id)
  end
end

function M:startSession(a, b, kind)
  -- Prefixed, because two counters mint into one `battles` table.
  --
  -- A session and a co-op battle are numbered by two independent counters and
  -- both open a mediated record under their own id, so the plain "1" the second
  -- of them minted used to land on the first one's record -- a co-op fight
  -- inheriting a 1v1's parties, or a battle_choice from one filed into the
  -- other.  The letter is what keeps the two id spaces apart, and it is a letter
  -- rather than a colon because these ids cross the wire and Wire.id refuses
  -- anything outside [%w_-].
  local id = "s" .. tostring(self.nextSession)
  self.nextSession = self.nextSession + 1
  self.sessions[id] = { a = a.id, b = b.id, kind = kind }
  a.sessionId, b.sessionId = id, id

  -- Only a battle can be scored, so only a battle gets paperwork. The names
  -- are copied *now*, from what each player was admitted under, so the
  -- rating lands on whoever actually fought even if one of them is gone by
  -- the time the second report arrives.
  if kind == "battle" then
    self.matches[id] = {
      a = a.id, b = b.id, aName = a.name, bName = b.name,
      -- taken now, from the players in the battle: whether a result may
      -- touch the board is a fact about who they are, not about what they
      -- report afterwards
      aRanked = a.ranked ~= false, bRanked = b.ranked ~= false,
      reports = {}, startedAt = self.clock,
    }
  end

  -- The requester hosts. Someone has to deal the battle's shared RNG seed,
  -- and picking the side that asked keeps it deterministic rather than
  -- racing on who answers first.
  send(a, Wire.SESSION,
    { peer = b.id, peerName = b.name, kind = kind, role = "host", id = id })
  send(b, Wire.SESSION,
    { peer = a.id, peerName = a.name, kind = kind, role = "guest", id = id })

  self:broadcast(Wire.MOVE, presenceOf(a), a.id)
  self:broadcast(Wire.MOVE, presenceOf(b), b.id)

  -- A battle session is also a mediated fight from the moment it opens, and
  -- the requester is its authority for the reason they were made host above.
  -- Trade is untouched: there is no trade sim here and there is not going to
  -- be one.
  if kind == "battle" then
    self:openMediatedBattle(id, {
      mode = "1v1",
      hostId = a.id,
      memberIds = { a.id, b.id },
      sides = { a = { a.id }, b = { b.id } },
    })
  end
end

-- ------- parties
--
-- Membership lives here and only here.  A client is told the whole list
-- whenever it changes, which is what stops a client and the hub disagreeing
-- about who is in a party -- there is no delta to miss.

function M:partyMembers(partyId)
  local out = {}
  for _, id in ipairs(self.parties[partyId] or {}) do
    local member = self.clients[id]
    if member and member.ready then out[#out + 1] = member end
  end
  return out
end

function M:startParty(a, b)
  local id = tostring(self.nextParty)
  self.nextParty = self.nextParty + 1
  self.parties[id] = { a.id, b.id }
  a.partyId, b.partyId = id, id
  -- Neither of them can be waiting on another answer now, and an invite
  -- left armed would be answered by a player who is no longer free.
  a.partyPendingTo, b.partyPendingTo = nil, nil

  local members = {
    { id = a.id, name = a.name },
    { id = b.id, name = b.name },
  }
  send(a, Wire.PARTY, { id = id, members = members })
  send(b, Wire.PARTY, { id = id, members = members })

  -- ...and everyone else learns these two are spoken for, so the INVITE row
  -- stops being offered against them.  Same shape as startSession: presence
  -- changed, so presence goes out.
  self:broadcast(Wire.MOVE, presenceOf(a), a.id)
  self:broadcast(Wire.MOVE, presenceOf(b), b.id)
end

-- One member leaving ends it for both.  At two people there is no party left
-- to continue, and a "party" of one that still showed a PARTY row and a
-- party chat scope with nowhere to send would be worse than none.
function M:endParty(client, reason)
  local id = client.partyId
  if not id then return end
  -- Both offers go with the party, and while it still exists: an offer is only
  -- ever shown to a party member, so one that outlived its party would be a box
  -- on somebody's screen that nothing left alive could ever take down.
  self:clearCoopOffer(client, "gone")
  for _, member in ipairs(self:partyMembers(id)) do
    if member.id ~= client.id then self:clearCoopOffer(member, "gone") end
  end
  local memberIds = self.parties[id]
  self.parties[id] = nil
  client.partyId = nil

  for _, memberId in ipairs(memberIds or {}) do
    local other = self.clients[memberId]
    if other and other.id ~= client.id and other.partyId == id then
      other.partyId = nil
      send(other, Wire.PARTY_END, { reason = reason })
      self:broadcast(Wire.MOVE, presenceOf(other), other.id)
    end
  end
  -- The leaver is told too, so a client that did not initiate this locally
  -- -- one whose party ended because the hub said so -- still converges.
  -- Guarded the way endSession guards its own: on a drop there is nothing
  -- left to tell.
  if self.clients[client.id] then
    send(client, Wire.PARTY_END, { reason = "left" })
    self:broadcast(Wire.MOVE, presenceOf(client), client.id)
  end
end

-- ------- co-op battles
--
-- The hub owns two things here and deliberately not a third.
--
--   * **Who may hear about an offer.**  A co-op offer only ever reaches the
--     one player its owner is travelling with, because the hub is the only
--     party to the exchange that knows who that is.  A client asking to tell
--     "everyone at this fight" would be a client choosing its own audience.
--   * **Whether all four agreed.**  A PARTY BATTLE needs three yesses, and
--     collecting them anywhere else means one client deciding that the other
--     three consented.
--
-- What it does *not* own is the battle.  Nothing below simulates a turn; the
-- hub says who agreed and stops, exactly as it does for a 1v1 session.

-- The other member of this client's party, or nil.  At PARTY_MAX = 2 there is
-- at most one, which is what lets an offer be forwarded without naming a
-- recipient.
function M:partnerOf(client)
  if not client.partyId then return nil end
  for _, member in ipairs(self:partyMembers(client.partyId)) do
    if member.id ~= client.id then return member end
  end
  return nil
end

-- Drop this client's standing offer and tell whoever was being shown it.
--
-- Called from four places -- the client withdrawing, the offer being taken,
-- the party dissolving, the connection dropping -- because all four leave the
-- partner holding a box for a fight that is no longer on offer, and a box that
-- can only be answered into nothing is the failure this whole message exists
-- to prevent.
function M:clearCoopOffer(client, reason)
  if not client or not client.coopOffer then return false end
  client.coopOffer = nil
  local partner = self:partnerOf(client)
  if partner then
    send(partner, Wire.COOP_OFFER_END, { reason = reason or "left" })
  end
  return true
end

-- Every ask this client is part of is void.  A four-way that has lost a player
-- cannot be completed and must not be left to time out, because the other
-- three are looking at a box right now.
function M:clearCoopAsks(client, reason)
  local doomed
  for id, ask in pairs(self.coopAsks or {}) do
    for _, memberId in ipairs(ask.everyone) do
      if memberId == client.id then
        doomed = doomed or {}
        doomed[#doomed + 1] = id
        break
      end
    end
  end
  for _, id in ipairs(doomed or {}) do
    self:endCoopAsk(id, client.name, reason or "gone")
  end
end

function M:endCoopAsk(id, name, reason)
  local ask = self.coopAsks and self.coopAsks[id]
  if not ask then return false end
  self.coopAsks[id] = nil
  for _, memberId in ipairs(ask.everyone) do
    local member = self.clients[memberId]
    if member then
      member.coopAskId = nil
      send(member, Wire.COOP_DECLINE, { name = name, reason = reason })
    end
  end
  return true
end

-- Open a co-op battle's fan-out group.
--
-- One id, however the battle was agreed: two partners against an NPC pair use
-- it exactly as four players against each other do, so mmo.coop_relay has one
-- routing rule rather than two that have to be kept in step.
--
-- `plan` is what the mediated record is built from -- the mode, who the
-- authority is, and which side each member is on.  It is passed by the caller
-- rather than worked out here because only the caller knows: the four-way
-- knows its two parties from the ask it just settled, and the pair knows which
-- of them walked up to the trainer.  When it is absent the shape is inferred,
-- and openMediatedBattle says how.
function M:openCoopBattle(id, memberIds, plan)
  local members = {}
  for _, memberId in ipairs(memberIds or {}) do
    local member = self.clients[memberId]
    if member then
      members[#members + 1] = memberId
      member.coopBattleId = id
    end
  end
  self.coopBattles[id] = { members = members, startedAt = self.clock }
  -- ...and the hub's own record of the fight, on the same id.  Built even
  -- though nothing may ever arrive for it: a client that never uploads a
  -- ruleset simply leaves `sim` nil, which is exactly how the legacy
  -- client-simulated path stays open underneath this one.
  local shape = { memberIds = members }
  for key, value in pairs(plan or {}) do shape[key] = value end
  self:openMediatedBattle(id, shape)
  return id
end

-- Forget it, and let the members out.  A battle whose group survived its
-- players would keep forwarding into a set of ids that no longer connect.
function M:closeCoopBattle(id)
  local group = self.coopBattles[id]
  if not group then return false end
  self.coopBattles[id] = nil
  for _, memberId in ipairs(group.members or {}) do
    local member = self.clients[memberId]
    if member and member.coopBattleId == id then member.coopBattleId = nil end
  end
  -- The group and the fight are the same event seen from two sides, so they
  -- end together.  A sim still holding a field here is one whose players have
  -- all gone (the max-age sweep, a member dropping mid-setup); the fight is
  -- called off rather than left refereeing an empty room.
  local record = self.battles[id]
  if record then self:abortMediatedBattle(record, "gone") end
  return true
end

-- All four said yes.  Each is told its own side and both rosters, so no client
-- has to work out who its allies are from a list it was not given.
function M:startCoopBattle(id)
  local ask = self.coopAsks and self.coopAsks[id]
  if not ask then return false end
  self.coopAsks[id] = nil

  local function roster(ids)
    local out = {}
    for _, memberId in ipairs(ids) do
      local member = self.clients[memberId]
      if not member or not member.ready then return nil end
      out[#out + 1] = { id = member.id, name = member.name }
    end
    return out
  end

  local sideA, sideB = roster(ask.sideA), roster(ask.sideB)
  -- Re-checked at the moment of starting rather than only when the ask went
  -- out: somebody may have dropped between the third yes and this line, and
  -- four players agreeing is only worth anything if all four are still here.
  if not (sideA and sideB) then
    self.coopAsks[id] = ask
    return self:endCoopAsk(id, nil, "gone")
  end

  -- The membership outlives the ask, because the battle traffic is about to
  -- need it: mmo.coop_relay is fanned out to exactly these four and nobody
  -- else, and the hub is the only party that knows who they are.  The two
  -- sides go with it -- this is the moment they are known, and a mediated
  -- field cannot be assembled from a flat list of four.
  self:openCoopBattle(id, ask.everyone, {
    mode = "coop_pvp", hostId = ask.asker,
    sides = { a = ask.sideA, b = ask.sideB },
  })

  -- The paperwork for a ranked 2-on-2.
  --
  -- **Two sides, not two pairs.** A four-way is scored as one team match --
  -- each player against the other pair's combined strength -- because that is
  -- the match they played. See Rank.lua's `recordTeam` for why pairing them
  -- off by slot index was the wrong answer.
  local function side(ids)
    local out = {}
    for _, memberId in ipairs(ids) do
      local member = self.clients[memberId]
      if member then
        out[#out + 1] = { id = member.id, name = member.name,
                          ranked = member.ranked ~= false }
      end
    end
    return out
  end
  self.coopMatches[id] = {
    a = side(ask.sideA), b = side(ask.sideB),
    reports = {}, everyone = ask.everyone, startedAt = self.clock,
  }

  for _, memberId in ipairs(ask.sideA) do
    local member = self.clients[memberId]
    member.coopAskId = nil
    send(member, Wire.COOP_BATTLE,
      { id = id, side = "a", allies = sideA, foes = sideB, host = ask.asker })
  end
  for _, memberId in ipairs(ask.sideB) do
    local member = self.clients[memberId]
    member.coopAskId = nil
    send(member, Wire.COOP_BATTLE,
      { id = id, side = "b", allies = sideB, foes = sideA, host = ask.asker })
  end
  return true
end

-- ------- ranked PVP

-- Tell the whole hub what somebody is worth now.
--
-- Broadcast with no exception, so the player it is about hears it too: their
-- own score is not in their own roster (a client drops its own presence),
-- and a menu that only updated for other people would be the one place the
-- number was stale.
function M:publishPoints(clientId, points)
  local client = self.clients[clientId]
  if not client then return end
  client.points = points
  self:broadcast(Wire.RANK, { id = clientId, points = points })
end

-- Score a battle, but only once both sides have said the same thing about
-- it.
--
-- **This is the whole anti-cheat story, and it is deliberately small.** A
-- result is a claim by a stranger's process; the only cheap thing that makes
-- it worth more is a second, independent claim that agrees. So a lone report
-- scores nothing, two reports that disagree score nothing, and the first
-- answer from a given player is the one that counts -- otherwise a client
-- could keep re-reporting until its opponent's answer happened to match.
--
-- What that leaves open is stated rather than papered over: a player who
-- quits mid-battle is a draw for the side still standing (the engine's own
-- LinkBattle ends a dead link that way), so rage-quitting avoids the loss.
-- Deciding otherwise would mean believing one side alone, which is the
-- larger hole -- anyone could then mint wins against a player who never
-- connected.
function M:settleMatch(id)
  local match = self.matches[id]
  if not match then return nil end
  local first, second = match.reports[match.a], match.reports[match.b]
  if not (first and second) then return nil end

  -- One match, one settlement: the paperwork goes whatever the verdict is,
  -- so a pair cannot re-report their way to a second payout.
  self.matches[id] = nil

  local winner, loser
  if first == "win" and second == "loss" then
    winner, loser = match.aName, match.bName
  elseif first == "loss" and second == "win" then
    winner, loser = match.bName, match.aName
  else
    -- Agreed draw, or two clients telling different stories. Neither is
    -- worth points, and neither is worth a sentence on anybody's screen.
    return nil
  end

  -- A battle is only worth points when both players are who they say they
  -- are. One impostor and the whole match scores nothing: paying out half of
  -- it would move a rating that belongs to somebody who was not playing.
  if not (match.aRanked and match.bRanked) then return nil end

  local winnerId = (winner == match.aName) and match.a or match.b
  local loserId = (winnerId == match.a) and match.b or match.a
  local settled = self.board:record(winnerId, loserId, self.clock)
  if not settled then return nil end
  self.board:seen(winnerId, winner)
  self.board:seen(loserId, loser)
  self:publishPoints(winnerId, settled.winner.points)
  self:publishPoints(loserId, settled.loser.points)
  return settled
end

-- One player's report on a 2-on-2.
--
-- Same rule as a 1v1, one player wider: the first answer from each of the four
-- stands, and nothing is scored until all four have spoken and agree. A side
-- that cannot get its own two members to say the same thing has not won
-- anything.
function M:reportCoop(id, client, outcome)
  local match = self.coopMatches[id]
  if not match then return nil end
  local inIt = false
  for _, memberId in ipairs(match.everyone) do
    if memberId == client.id then inIt = true break end
  end
  if not inIt then return nil end
  if match.reports[client.id] then return nil end
  match.reports[client.id] = outcome

  for _, memberId in ipairs(match.everyone) do
    if not match.reports[memberId] then return nil end
  end
  return self:settleCoopMatch(id)
end

function M:settleCoopMatch(id)
  local match = self.coopMatches[id]
  if not match then return nil end
  -- One battle, one settlement, whatever the verdict.
  self.coopMatches[id] = nil

  -- What each side says happened, and it has to be unanimous *within* a side
  -- before it is worth reading across sides. Two team-mates who cannot agree
  -- whether they won have not won anything -- and neither has anybody else,
  -- because a four-way has one result and this is it.
  local function verdict(members)
    local said
    for _, member in ipairs(members) do
      local report = match.reports[member.id]
      if not report then return nil end
      if said == nil then said = report elseif said ~= report then return nil end
    end
    return said
  end

  local saidA, saidB = verdict(match.a), verdict(match.b)
  local winners, losers
  if saidA == "win" and saidB == "loss" then
    winners, losers = match.a, match.b
  elseif saidA == "loss" and saidB == "win" then
    winners, losers = match.b, match.a
  else
    -- An agreed draw, or four players telling two different stories. Neither
    -- is worth points and neither is worth a sentence on anybody's screen.
    return nil
  end

  -- One unclaimed name anywhere in the four and the whole battle scores
  -- nothing, for the reason a 1v1 does: paying out would move a rating that
  -- belongs to somebody who was not playing. All four or none -- paying out
  -- the half that is claimed would rate a team against opponents whose
  -- ratings are not moving.
  for _, member in ipairs(match.everyone) do
    local client = self.clients[member]
    if client and client.ranked == false then return nil end
  end

  local function ids(members)
    local out = {}
    for _, member in ipairs(members) do out[#out + 1] = member.id end
    return out
  end
  local settled = self.board:recordTeam(ids(winners), ids(losers), self.clock)
  if not settled then return nil end

  -- Everyone's new number goes out, winners and losers alike: four ratings
  -- moved, and a hub that announced two of them would leave two screens stale.
  local byKey = {}
  for _, row in ipairs(settled.winners) do byKey[row.key] = row.points end
  for _, row in ipairs(settled.losers) do byKey[row.key] = row.points end
  for _, member in ipairs(winners) do
    if byKey[member.id] then self:publishPoints(member.id, byKey[member.id]) end
  end
  for _, member in ipairs(losers) do
    if byKey[member.id] then self:publishPoints(member.id, byKey[member.id]) end
  end
  return settled
end

-- ------- mediated battles (BattleSim/Turn plumbing)
--
-- The hub referees.  A record exists for every battle it brokers from the
-- moment the fight is agreed, holding nothing but a roster; a ruleset and one
-- party per seat turn it into a running sim, and from that instant the hub is
-- the only party that rolls anything.  `record.sim` is the flag: every hard
-- cut below is gated on it and not on the record, because until the sim exists
-- the two clients are still on the engine's own lockstep path and taking that
-- away from a build that has not been rewritten yet would be a battle screen
-- that never advances.
--
-- server/lib/relay.js runs this same plumbing over the same message types, so
-- the two hosting paths referee a fight identically.  Keep them in step: a
-- difference here is one client's copy of the game disagreeing with another's
-- about a battle neither of them resolved.

-- The sim counts in whole seconds; this hub's clock is fractional seconds of
-- uptime.  One place to convert, so a deadline cannot be compared against a
-- different unit than it was set in.
local function battleSeconds(clock)
  return math.floor(tonumber(clock) or 0)
end

-- The fight this connection is in, when the hub is the one running it.  nil
-- for a player who is not fighting, and for a co-op group still on the legacy
-- client-simulated path.
--
-- Every battle_* handler finds its record through `client.battleId` rather
-- than through the id on the message.  The id is still checked where the
-- sanitiser carries one, but it is checked *against* the connection's own
-- fight: a client naming somebody else's battle is naming a fight it is not
-- in, and trusting the field would let a spectator file choices into a match
-- they were never at.
local function mediatedOf(self, client)
  if not client.ready or not client.battleId then return nil end
  return self.battles[client.battleId]
end

-- A seed for a fight whose ruleset did not name one.
--
-- Off the session's entropy pool, which is honest about being weaker than a
-- CSPRNG (see its header) and is far more than this needs: nobody is
-- predicting a damage roll for profit, and the property that matters is that
-- two fights in one session do not replay each other.  The clock is the
-- fallback for a pool that cannot answer, because a fight with a predictable
-- seed is still a fight and refusing to start one would be worse.
function M:battleSeed()
  local raw = self.entropy and self.entropy:bytes(4)
  if type(raw) == "string" and #raw == 4 then
    local n = 0
    for i = 1, 4 do n = n * 256 + raw:byte(i) end
    return (n % Wire.SEED_MAX) + 1
  end
  return (math.floor(self.clock * 1000) % Wire.SEED_MAX) + 1
end

-- Open the hub's record of a fight.  The sim is still nil: a ruleset and every
-- required party have to arrive before tryStartSim takes it over.
--
-- `npcIds` is set for coop_npc (**two** synthetic seats) and wild (**one**
-- seat). Coop_npc: two players meet two monsters. Wild: one player meets one
-- wild mon on a hub NPC seat (protocol-only — no overworld divert). The host
-- uploads the NPC team as side "b".
--
-- They are ids a client could in principle type, and that is safe rather than
-- sloppy: client ids are minted as decimal counters, these carry a letter and
-- the battle's own id, and nothing addresses a seat by name anyway -- a choice
-- is attributed to the connection it arrived on.  It has to be spellable,
-- because tryStartSim advertises them and Wire.id refuses a colon.
function M:openMediatedBattle(id, plan)
  plan = plan or {}
  local memberIds, seen = {}, {}
  for _, memberId in ipairs(plan.memberIds or {}) do
    if type(memberId) == "string" and not seen[memberId] then
      seen[memberId] = true
      memberIds[#memberIds + 1] = memberId
    end
  end
  if #memberIds == 0 then return nil end

  local mode = Turn.MODES[plan.mode] and plan.mode
    or ((#memberIds <= 2) and "1v1" or "coop_pvp")
  local hostId = plan.hostId or memberIds[1]
  local npcIds = nil
  if mode == "coop_npc" then
    npcIds = {}
    for i = 1, Config.COOP_SIDE do
      npcIds[i] = "n" .. tostring(id) .. string.char(96 + i)
    end
  elseif mode == "wild" then
    -- One human, one synthetic wild seat. Protocol-only: nothing here diverts
    -- an overworld encounter onto this path.
    npcIds = { "n" .. tostring(id) .. "a" }
  end

  local sides = type(plan.sides) == "table" and plan.sides or nil
  if not sides then
    if mode == "1v1" then
      sides = { a = { memberIds[1] }, b = { memberIds[2] or memberIds[1] } }
    elseif mode == "coop_npc" or mode == "wild" then
      sides = { a = memberIds, b = npcIds }
    else
      local mid = math.ceil(#memberIds / 2)
      local a, b = {}, {}
      for i, memberId in ipairs(memberIds) do
        if i <= mid then a[#a + 1] = memberId else b[#b + 1] = memberId end
      end
      sides = { a = a, b = b }
    end
  end

  -- Copied rather than referenced: `sides` here is usually the caller's own
  -- ask, which endCoopAsk is about to forget, and a record holding somebody
  -- else's table is a field that changes underneath the fight.
  local function copy(list)
    local out = {}
    for _, value in ipairs(list or {}) do out[#out + 1] = value end
    return out
  end

  local record = {
    id = id,
    mode = mode,
    hostId = hostId,
    memberIds = memberIds,
    sides = { a = copy(sides.a), b = copy(sides.b) },
    npcIds = npcIds,
    ruleset = nil,
    parties = {},      -- seat id -> the sanitised party that filled it
    bags = {},         -- player id -> { [itemId] = count } from party.bag
    bagHold = {},      -- player id -> itemId held until turn resolves
    sim = nil,
    settled = false,
  }
  self.battles[id] = record
  for _, memberId in ipairs(memberIds) do
    local member = self.clients[memberId]
    if member then member.battleId = id end
  end
  return record
end

-- Is this seat one of the trainer's rather than a player's?
function M:isNpcSeat(record, seat)
  for _, npcId in ipairs((record and record.npcIds) or {}) do
    if npcId == seat then return true end
  end
  return false
end

-- Which seat a party fills.  Normally the sender's own id.  For coop_npc the
-- host may also upload the trainer's party under side "b", which is dealt across
-- the synthetic npc seats rather than displacing their own team -- so this
-- answers the *first* of them, and `fillBattleParty` below is what does the
-- dealing.
function M:battleSeat(record, client, party)
  local member = false
  for _, memberId in ipairs(record.memberIds) do
    if memberId == client.id then member = true break end
  end
  if not member then return nil end
  if record.mode == "coop_npc" and party.side == "b"
     and client.id == record.hostId and record.npcIds then
    return record.npcIds[1]
  end
  if record.mode == "wild" and party.side == "b"
     and client.id == record.hostId and record.npcIds then
    return record.npcIds[1]
  end
  return client.id
end

-- Store an uploaded party against the seat or seats it fills.
--
-- The trainer's team arrives as one list, because that is what it is on the
-- host's screen -- src/CoopBattle.lua's `npcMons` re-interleaves the two
-- ownerless slots back into the order the trainer would send them out.  Two
-- seats fight it, so it is dealt back out here, alternately, which is the
-- inverse of that interleave: the deal src/Coop.lua made when it built the field
-- is the deal the field gets back.
--
-- A trainer with fewer monsters than seats leaves one empty, and an empty seat
-- is a field Turn.create refuses -- so the spare seat is given up instead and
-- the fight opens as the 2-on-1 the trainer actually brought.  Refusing would
-- mean a lone-monster trainer could not be fought at all.
function M:fillBattleParty(record, client, party)
  local seat = self:battleSeat(record, client, party)
  if not seat then return false end
  if not self:isNpcSeat(record, seat) then
    record.parties[seat] = party
    -- Bag always keys off the connection: a host uploading side b for an NPC
    -- never reaches this branch, so their own bag is not wiped by that upload.
    record.bags = record.bags or {}
    record.bags[client.id] = self:bagMap(party.bag)
    return true
  end

  local dealt = {}
  for index, mon in ipairs(party.mons) do
    local at = ((index - 1) % #record.npcIds) + 1
    dealt[at] = dealt[at] or {}
    local hand = dealt[at]
    hand[#hand + 1] = mon
  end

  local kept, dropped = {}, {}
  for at, npcId in ipairs(record.npcIds) do
    if dealt[at] and #dealt[at] > 0 then
      kept[#kept + 1] = npcId
      record.parties[npcId] = {
        battle = party.battle, side = party.side,
        badges = party.badges, mons = dealt[at],
      }
    else
      dropped[npcId] = true
      record.parties[npcId] = nil
    end
  end
  record.npcIds = kept
  -- Filtered rather than replaced: the side is the caller's description of the
  -- field and may hold more than these seats one day, so only the seats actually
  -- given up are taken out of it.
  local sideB = {}
  for _, seat in ipairs(record.sides.b) do
    if not dropped[seat] then sideB[#sideB + 1] = seat end
  end
  record.sides.b = sideB
  return true
end

-- List of `{id, count}` → lookup map. Empty / nil → empty map (no items).
function M:bagMap(entries)
  local map = {}
  for _, entry in ipairs(entries or {}) do
    if type(entry) == "table" and type(entry.id) == "string"
       and type(entry.count) == "number" and entry.count > 0 then
      map[entry.id] = entry.count
    end
  end
  return map
end

-- Shallow copy of an id→count bag map (or nil when empty / absent).
function M:cloneBagMap(src)
  if type(src) ~= "table" then return nil end
  local out, any = {}, false
  for id, count in pairs(src) do
    if type(id) == "string" and type(count) == "number" and count > 0 then
      out[id] = count
      any = true
    end
  end
  if not any then return nil end
  return out
end

-- Items proved present but never decremented (BattleSim noConsume, e.g. Poké Flute).
function M:canSpendBag(record, clientId, itemId)
  if type(itemId) ~= "string" then return false end
  local bag = record and record.bags and record.bags[clientId]
  if not bag then return false end
  return (bag[itemId] or 0) >= 1
end

function M:spendBag(record, clientId, itemId)
  if not self:canSpendBag(record, clientId, itemId) then return false end
  local effect = Effects.itemEffect(itemId)
  if effect and effect.noConsume then return true end
  local bag = record.bags[clientId]
  bag[itemId] = bag[itemId] - 1
  if bag[itemId] <= 0 then bag[itemId] = nil end
  return true
end

-- Item stacks are held on choice accept and spent only when the turn leaves
-- the choice phase — so cancel/unchose drops the hold and never refunds.
function M:commitBagHolds(record)
  local holds = record.bagHold
  if not holds then return end
  record.bagHold = {}
  for clientId, itemId in pairs(holds) do
    self:spendBag(record, clientId, itemId)
  end
end

-- After the sim leaves choice, fighter.bag is authoritative (auto-pick and
-- human items both spend there). Mirror it onto the hub sheet and drop holds
-- so we never double-spend with commitBagHolds.
function M:syncBagsFromSim(record)
  record.bagHold = {}
  if not (record and record.sim and record.bags) then return end
  for _, fighter in ipairs(record.sim.fighters or {}) do
    record.bags[fighter.playerId] = self:cloneBagMap(fighter.bag) or {}
  end
end

function M:clearBagHold(record, clientId)
  if not (record and record.bagHold) then return end
  record.bagHold[clientId] = nil
end

function M:holdBag(record, clientId, itemId)
  record.bagHold = record.bagHold or {}
  record.bagHold[clientId] = itemId
end

-- Every seat that owes a party before the fight can open.
function M:seatsNeeded(record)
  local seats = {}
  for _, memberId in ipairs(record.memberIds) do seats[#seats + 1] = memberId end
  for _, npcId in ipairs(record.npcIds or {}) do seats[#seats + 1] = npcId end
  return seats
end

-- The ruleset and every party are in: build the field and start refereeing.
--
-- Answers false and changes nothing when anything is still missing, so it is
-- safe to call from every message that could have been the last one needed.
function M:tryStartSim(record)
  if not record or record.sim or record.settled then return false end
  if not record.ruleset then return false end
  for _, seat in ipairs(self:seatsNeeded(record)) do
    if not record.parties[seat] then return false end
  end

  local function fighterOf(seat)
    local party = record.parties[seat]
    if not party then return nil end
    local client = self.clients[seat]
    -- Seed NPC seats with a gym-style kit when the host uploaded no bag.
    record.bags = record.bags or {}
    if not record.bags[seat] and self:isNpcSeat(record, seat) then
      record.bags[seat] = self:cloneBagMap(Turn.DEFAULT_NPC_BAG)
    end
    local bag = record.bags[seat]
    return {
      playerId = seat,
      name = (client and client.name)
        or (self:isNpcSeat(record, seat) and "TRAINER" or seat),
      mons = party.mons,
      badges = party.badges,
      bag = bag and self:cloneBagMap(bag) or nil,
    }
  end

  local function roster(seats)
    local out = {}
    for _, seat in ipairs(seats or {}) do
      local fighter = fighterOf(seat)
      if fighter then out[#out + 1] = fighter end
    end
    return out
  end

  -- The seed is the intermediator's and nobody else's.
  --
  -- A client may still *send* one -- the message has carried the field since the
  -- lockstep days and refusing it now would drop the whole ruleset over a value
  -- nothing reads -- but a fight whose seed came off the wire is a fight the
  -- authority can replay offline until it finds a run it likes, and then ask for
  -- that run.  Every roll in a mediated battle is drawn from this stream, so
  -- choosing it is the whole of what the intermediator is for.
  --
  -- `forceBattleSeed` is the one way in, and it is a *hub* field rather than a
  -- message: a suite that needs a reproducible fight sets it on the hub it
  -- constructed, which is not something a connection can reach.
  local seed = (type(self.forceBattleSeed) == "number")
    and self.forceBattleSeed or self:battleSeed()
  local battle, why = Turn.create({
    id = record.id,
    mode = record.mode,
    seed = seed,
    chart = record.ruleset.chart,
    specialTypes = record.ruleset.specialTypes,
    metronomePool = record.ruleset.metronomePool,
    choiceTimeout = Config.BATTLE_CHOICE_TIMEOUT,
    reconnectGrace = Config.BATTLE_RECONNECT_GRACE,
    resolveTimeout = Config.BATTLE_RESOLVE_TIMEOUT,
    now = battleSeconds(self.clock),
    sides = { a = roster(record.sides.a), b = roster(record.sides.b) },
  })
  if not battle then
    -- Turn.create answers a reason rather than raising, and this file owns no
    -- logger, so the refusal goes out the seam that already exists for "a
    -- message from this connection was not acted on" -- once per connection,
    -- charged to the authority whose ruleset and parties made the field.
    local host = self.clients[record.hostId]
    if host then
      noteDrop(self, host,
        "this battle could not be assembled: " .. tostring(why))
    end
    return false
  end
  record.sim = battle

  -- The npc seats are advertised under their own ids, not hidden behind the
  -- host's.
  --
  -- They used to be filtered out and the emptied side announced as the host,
  -- because the seat was not an id a client could address -- and src/CoopBattle's
  -- `medMap` then had to guess that an advertised id owning no slot on that side
  -- meant the ownerless ones.  Two seats is one guess too many: with both named,
  -- the map is a lookup again and the trainer's second box has a field slot
  -- rather than being drawn and never spoken about.  Nothing is opened up by
  -- naming them, because a choice is attributed to the connection it arrived on
  -- and no connection is either of these.
  local function advertise(seats)
    local out = {}
    for _, seat in ipairs(seats) do out[#out + 1] = seat end
    -- Wire.battleReady refuses an empty side, so a side that somehow lost every
    -- seat is announced as the host rather than as a message no client reads.
    if #out == 0 and record.hostId then out[1] = record.hostId end
    return out
  end
  self:broadcastBattle(record, Wire.BATTLE_READY, {
    battle = record.id,
    mode = record.mode,
    sides = { a = advertise(record.sides.a), b = advertise(record.sides.b) },
  })
  self:flushBattle(record)
  return true
end

-- Answer for the trainer, for as long as it owes an answer.
--
-- The npc seats have no connection to send mmo.battle_choice, so without this
-- every turn of a coop_npc would sit out BATTLE_CHOICE_TIMEOUT and then be
-- auto-picked anyway -- a minute a turn, which is not a battle.  The pick is the
-- turn machine's own (first move with PP, at the first living foe), so what
-- happens here is exactly what used to happen a minute later.
--
-- The loop is what carries the fight forward rather than a retry: filing the
-- last outstanding choice resolves the turn and opens the next one, where the
-- trainer owes again.  It is bounded because a machine that opened a turn it
-- cannot close is a hub that stops answering anything, and that is a worse
-- failure than a fight that pauses.
function M:fillNpcChoices(record)
  if not record or not record.sim or record.settled then return false end
  local seats = record.npcIds
  if not seats or #seats == 0 then return false end

  local filed = false
  for _ = 1, Config.BATTLE_MON_MAX * Config.COOP_FIGHTERS do
    local any = false
    for _, seat in ipairs(seats) do
      if record.sim:autoPick(seat) then any, filed = true, true end
    end
    if not any then break end
  end
  return filed
end

-- Everyone in the fight, and nobody else.  A member who has dropped is skipped
-- rather than removed: the sim is still holding their grace open.
function M:broadcastBattle(record, msgType, payload)
  for _, memberId in ipairs(record.memberIds) do
    local member = self.clients[memberId]
    if member and member.ready then send(member, msgType, payload) end
  end
end

-- Everything the sim has produced since the last look, then the verdict if it
-- has one.  Called after every message that can move the fight, because the
-- sim buffers and nothing else drains it.
function M:flushBattle(record)
  if not record or not record.sim or record.settled then return end
  -- Before the drain rather than after it: the trainer's answer can be the one
  -- that closes the turn, and the events that turn produced have to go out in
  -- this same pass or nothing else would send them until somebody else spoke.
  -- Nothing here calls back into this function, so the two cannot chase each
  -- other.
  self:fillNpcChoices(record)
  -- Fighter bags are authoritative after resolve (Turn spends on item use,
  -- including NPC auto-pick). Sync the hub sheet and drop holds so we never
  -- double-spend with commitBagHolds.
  if record.sim.phase ~= "choice" then
    self:syncBagsFromSim(record)
  end
  for _, event in ipairs(record.sim:drainEvents()) do
    self:broadcastBattle(record, Wire.BATTLE_EVENT, event)
  end
  local outcome = record.sim:outcome()
  if outcome then self:settleMediated(record, outcome) end
end

-- The clock, for every fight at once.
--
-- Called from update() below, so a host that already pumps the hub pumps the
-- battles too and there is nothing new for src/Client.lua to remember. This is
-- the only thing that fires a choice timeout or expires a reconnect grace: a
-- fight whose players have all gone quiet has no other source of time.
function M:tickBattles(now)
  local seconds = battleSeconds(now or self.clock)
  for _, record in pairs(self.battles) do
    if record.sim and not record.settled then
      record.sim:tick(seconds)
      self:flushBattle(record)
    end
  end
end

-- A connection left the field.  Answers true when a live sim started its
-- reconnect grace (the fight continues), false when the record was called off
-- or there was nothing to leave.
function M:leaveBattle(client)
  if not client or not client.battleId then return false end
  local record = self.battles[client.battleId]
  if not record then
    client.battleId = nil
    return false
  end
  if record.sim and not record.settled then
    if record.sim:disconnect(client.id) then self:flushBattle(record) end
    return true
  end
  -- Still collecting parties or a ruleset: there is no fight to pause, so the
  -- one that was being assembled is called off.
  self:abortMediatedBattle(record, "gone")
  return false
end

-- Call the fight off.  Everybody still owed a grace is disconnected and the
-- clock pushed past it, so the sim reaches its own verdict where it can --
-- a forfeit by the side that is still there beats a draw invented here.
function M:abortMediatedBattle(record, reason)
  if not record or record.settled then return end
  if record.sim then
    for _, memberId in ipairs(record.memberIds) do
      record.sim:disconnect(memberId)
    end
    record.sim:tick(battleSeconds(self.clock) + Config.BATTLE_RECONNECT_GRACE + 1)
    self:flushBattle(record)
    if record.settled then return end
  end
  record.settled = true
  -- No winners and no losers, spelled as their absence: Wire.battleOutcome
  -- refuses an empty id list, so two empty lists would be an outcome no client
  -- would read -- a battle screen with no way out.
  self:broadcastBattle(record, Wire.BATTLE_OUTCOME, {
    battle = record.id,
    outcome = "draw",
    reason = Wire.battleReason(reason) or "agree",
  })
  self:clearBattle(record)
end

-- The verdict, and the only account of the fight anybody gets.
--
-- **This replaces the two-client vote.** mmo.result exists because neither
-- peer in a relayed battle could be believed about its own win, so two
-- agreeing claims stood in for a witness.  Here there *is* a witness -- it did
-- every roll -- so the rating moves on its word alone and a client's report
-- about a mediated fight is ignored rather than weighed.
function M:settleMediated(record, outcome)
  if not record or record.settled then return nil end
  record.settled = true

  local payload = { battle = record.id, outcome = outcome.outcome }
  -- Present only when there is somebody in them, for the reason
  -- abortMediatedBattle gives: an empty list refuses the whole message.
  if outcome.winners and #outcome.winners > 0 then
    payload.winners = outcome.winners
  end
  if outcome.losers and #outcome.losers > 0 then
    payload.losers = outcome.losers
  end
  if outcome.reason then payload.reason = outcome.reason end
  if outcome.caught then payload.caught = outcome.caught end
  self:broadcastBattle(record, Wire.BATTLE_OUTCOME, payload)

  local match = self.matches[record.id]
  if match and record.mode == "1v1" then
    -- One battle, one settlement, whatever the verdict: the paperwork goes
    -- either way so nothing can be paid out twice.
    self.matches[record.id] = nil
    self:payMediated(match, payload)
  elseif record.mode == "coop_pvp" and self.coopMatches[record.id] then
    self:payMediatedCoop(self.coopMatches[record.id], record.id, payload)
  end

  self:clearBattle(record)
  return payload
end

-- Pay a 1v1 out of the intermediator's verdict.
--
-- The winners list is player ids and the board deals in names, so the two are
-- joined through the paperwork startSession copied at the first turn -- which
-- is also what makes a rating land on whoever actually fought even if one of
-- them has since left. Every guard settleMatch applies still applies: an
-- impostor anywhere voids the payout, and so does a claim that changed hands
-- between the first turn and this line.
function M:payMediated(match, payload)
  if payload.outcome ~= "win" and payload.outcome ~= "loss"
     and payload.outcome ~= "forfeit" then
    return nil
  end
  local winners, losers = payload.winners or {}, payload.losers or {}
  local winnerId, loserId
  if winners[1] == match.a then
    winnerId, loserId = match.a, match.b
  elseif winners[1] == match.b then
    winnerId, loserId = match.b, match.a
  elseif losers[1] == match.a then
    winnerId, loserId = match.b, match.a
  elseif losers[1] == match.b then
    winnerId, loserId = match.a, match.b
  end
  if not (winnerId and loserId) then return nil end
  if not (match.aRanked and match.bRanked) then return nil end

  local settled = self.board:record(winnerId, loserId, self.clock)
  if not settled then return nil end
  if winnerId == match.a then
    self.board:seen(winnerId, match.aName)
    self.board:seen(loserId, match.bName)
  else
    self.board:seen(winnerId, match.bName)
    self.board:seen(loserId, match.aName)
  end
  self:publishPoints(winnerId, settled.winner.points)
  self:publishPoints(loserId, settled.loser.points)
  return settled
end

-- ...and a 2-on-2, the same way.  The four reports the client-simulated path
-- collected are synthesised from the verdict instead, so settleCoopMatch --
-- which already knows how to rate two sides as teams -- is reached with the
-- unanimity it expects rather than being taught a second entry point.
function M:payMediatedCoop(coop, id, payload)
  if payload.outcome == "draw" then
    self.coopMatches[id] = nil
    return nil
  end
  local won = {}
  for _, memberId in ipairs(payload.winners or {}) do won[memberId] = true end
  for _, memberId in ipairs(coop.everyone or {}) do
    coop.reports[memberId] = won[memberId] and "win" or "loss"
  end
  return self:settleCoopMatch(id)
end

-- Forget the fight and let its players out of it.  A record that outlived its
-- battle would keep every member's battleId pointed at something settled, and
-- the next fight they were offered would find a seat already taken.
function M:clearBattle(record)
  if not record then return end
  for _, memberId in ipairs(record.memberIds) do
    local member = self.clients[memberId]
    if member and member.battleId == record.id then member.battleId = nil end
  end
  self.battles[record.id] = nil
end

-- ------- friends
--
-- The hub owns exactly one part of this feature: carrying a friend ask to the
-- player it names, and *keeping* it when that player is not here.  The lists
-- themselves live in the two clients (src/Friends.lua's header says why they
-- cannot live here), so nothing below records who is friends with whom -- it
-- records who still owes an answer to whom.
--
-- Everything is keyed by trainer name rather than connection id, because a
-- friendship outlives the connection that made it and a held ask has, by
-- definition, no connection left to hang on.  Wire.nameKey is the fold -- trainer names, upper-cased -- not
-- Rank.keyOf (playerId), because friendships are keyed by the name you play as, so "the same name" means one thing on this hub.
--
-- Kept in step with server/lib/relay.js, which does all of this over its own
-- client table: the same client dials a dedicated hub and a game hosted from
-- inside somebody's copy, so a rule only one of them enforces is a rule that
-- holds on one of the two hosting paths and not the other.

-- Whoever is connected under this name right now, or nil.
--
-- First match wins, and the iteration order of self.clients decides which --
-- which is fine and is why nothing here is drawn from it: two players wearing
-- one unclaimed name is a real state, and either of them is an equally correct
-- answer to "deliver this now rather than holding it".  A wrong guess costs a
-- misdelivered box, not a friendship: the receiving client answers under its
-- own name, and the answer is matched back against the hold by name.
function M:byName(nameKey)
  if not nameKey then return nil end
  for _, client in pairs(self.clients) do
    if client.ready and Wire.nameKey(client.name) == nameKey then return client end
  end
  return nil
end

-- Drop everything this hub has been holding for longer than a week.
--
-- Cheap and lazy: run when something is added rather than on the tick, because
-- the table is empty on nearly every hub and a sweep nobody needs is a sweep
-- that runs sixty times a second for an answer that has not changed.
function M:sweepFriendHolds()
  for key, holds in pairs(self.friendHolds) do
    local kept = {}
    for _, hold in ipairs(holds) do
      if (self.clock - (hold.at or 0)) <= Config.FRIEND_HOLD then
        kept[#kept + 1] = hold
      else
        self.friendHeld = self.friendHeld - 1
      end
    end
    self.friendHolds[key] = #kept > 0 and kept or nil
  end
end

-- Hold one notification for a name, replacing whatever it supersedes.
--
-- One entry per (kind, sender), because all three kinds are idempotent: asking
-- twice is one ask, and a second answer to a question already answered is not
-- a thing that exists.  Without that a client could stack a player's inbox
-- full of the same box by pressing one button repeatedly -- the caps below
-- would bound it, but the player would still be answering the same question
-- eight times.
--
-- Refused rather than trimmed at the global cap: dropping somebody else's
-- held ask to make room for this one would let a flood erase the one
-- notification that mattered.  Per name it is the oldest that goes, which is
-- the other way round on purpose -- eight unanswered asks in one inbox is one
-- player ignoring eight people, and the newest is the one still worth asking.
function M:holdFriend(nameKey, hold)
  if not nameKey then return false end
  self:sweepFriendHolds()
  local holds = self.friendHolds[nameKey]
  if not holds then
    if self.friendHeld >= Config.FRIEND_HOLD_MAX then return false end
    holds = {}
    self.friendHolds[nameKey] = holds
  end

  local fromKey = Wire.nameKey(hold.name)
  for index, held in ipairs(holds) do
    if held.kind == hold.kind and Wire.nameKey(held.name) == fromKey then
      table.remove(holds, index)
      self.friendHeld = self.friendHeld - 1
      break
    end
  end

  if #holds >= Config.FRIEND_HOLD_PER_NAME then
    table.remove(holds, 1)
    self.friendHeld = self.friendHeld - 1
  end
  if self.friendHeld >= Config.FRIEND_HOLD_MAX then return false end

  hold.at = self.clock
  holds[#holds + 1] = hold
  self.friendHeld = self.friendHeld + 1
  return true
end

-- Take one held notification off a name's list, and say whether there was one.
--
-- This is the check that makes an answer safe to forward: only the player an
-- ask was actually addressed to is holding it, so a client that answers a
-- question nobody asked it finds nothing here and is dropped.  Without it any
-- client could send "they said yes" about anybody and write itself onto a
-- stranger's friends list.
function M:takeFriendHold(nameKey, kind, fromKey)
  local holds = nameKey and self.friendHolds[nameKey]
  if not holds then return nil end
  for index, held in ipairs(holds) do
    if held.kind == kind and Wire.nameKey(held.name) == fromKey then
      table.remove(holds, index)
      self.friendHeld = self.friendHeld - 1
      if #holds == 0 then self.friendHolds[nameKey] = nil end
      return held
    end
  end
  return nil
end

-- Send one notification, or hold it for the next time that name is seen.
local function deliverFriend(self, nameKey, kind, payloadType, payload, hold)
  local target = self:byName(nameKey)
  if target then
    send(target, payloadType, payload)
    -- An ask stays held even when it was delivered: the player it reached may
    -- close the game without answering, and "asked once, into a session that
    -- ended" is exactly the case this whole table exists for.  Everything else
    -- is spent on delivery.
    if kind ~= "ask" then return true end
  end
  return self:holdFriend(nameKey, hold)
end

-- Everything this hub has been keeping for the player who just walked in.
--
-- Called from admit, after the welcome and the join broadcast: the client has
-- to have its own id and its roster before a box can be put in front of it,
-- and an ask arriving ahead of the welcome would reach a client with no
-- friends list open to answer from (src/Friends.lua's onAsk refuses one).
--
-- Asks are re-delivered and *kept*; answers and removals are spent.  That
-- asymmetry is the feature: an ask is outstanding until it is answered, so a
-- player who logs out mid-prompt is asked again next time, whereas an answer
-- is news that has now been delivered.
function M:flushFriendHolds(client)
  local key = Wire.nameKey(client.name)
  local holds = key and self.friendHolds[key]
  if not holds then return 0 end
  self:sweepFriendHolds()
  holds = self.friendHolds[key]
  if not holds then return 0 end

  local kept, sent = {}, 0
  for _, hold in ipairs(holds) do
    if hold.kind == "ask" then
      -- No `from` id: the asker may not be here, and inventing one would give
      -- the receiving client an id to answer to that means somebody else's
      -- connection.  The name is what the answer travels by anyway.
      local asker = self:byName(Wire.nameKey(hold.name))
      send(client, Wire.FRIEND_ASK,
        { from = asker and asker.id or nil, name = hold.name })
      kept[#kept + 1] = hold
    elseif hold.kind == "answer" then
      send(client, Wire.FRIEND_ANSWER,
        { name = hold.name, accept = hold.accept == true })
      self.friendHeld = self.friendHeld - 1
    else
      send(client, Wire.FRIEND_REMOVE, { name = hold.name })
      self.friendHeld = self.friendHeld - 1
    end
    sent = sent + 1
  end
  self.friendHolds[key] = #kept > 0 and kept or nil
  return sent
end

-- ------- handlers

local handlers = {}

handlers[Wire.HELLO] = function(self, client, msg)
  if client.ready then return end
  if Wire.int(msg.proto, 0, 9999) ~= Config.PROTOCOL then
    return self:refuseClient(client, ("This game speaks protocol %d; yours "
      .. "speaks %s."):format(Config.PROTOCOL, tostring(msg.proto)))
  end
  local name = Wire.name(msg.name)
  if not name then
    return self:refuseClient(client, "That trainer name can't be used here.")
  end
  local playerId = Wire.playerId(msg.playerId)
  if not playerId then
    return self:refuseClient(client, "That player id can't be used here.")
  end
  -- A courtesy, not the gate: admit() re-checks, because on a coded hub the
  -- seat is not charged until the challenge is answered and everything that
  -- greeted in between would otherwise sail past this.
  if self:isFull() then
    return self:refuseClient(client, self:fullMessage())
  end

  -- Held rather than applied: on a hub with a code this peer is not a
  -- player yet, and half-applied fields would be a player nobody admitted.
  client.hello = {
    name = name,
    playerId = playerId,
    sprite = Wire.spriteId(msg.sprite) or Config.DEFAULT_SPRITE,
    profile = Wire.profile(msg.profile),
    map = Wire.mapId(msg.map),
    x = Wire.int(msg.x, 0, 4096),
    y = Wire.int(msg.y, 0, 4096),
    facing = Wire.facing(msg.facing) or "down",
  }

  if client.trusted or not self:requiresCode() then
    return self:admit(client)
  end

  -- Challenging after hello rather than on connect keeps the client's
  -- send-hello-immediately flow intact, and spends no nonce on a peer whose
  -- protocol did not match anyway.
  local nonce = self:newNonce()
  if not nonce then
    return self:refuseClient(client, "This game can't take players right now.")
  end
  client.nonce = nonce
  send(client, Wire.CHALLENGE, { nonce = nonce })
end

handlers[Wire.AUTH] = function(self, client, msg)
  -- Only while a challenge is outstanding, and the nonce is spent the moment
  -- it is read -- pass or fail -- so neither a captured response nor a second
  -- guess can be tried against the same challenge.
  if client.ready or not client.nonce then return end
  local nonce = client.nonce
  client.nonce = nil

  local response = Wire.hex(msg.response, Config.DIGEST_HEX)
  local expected = self.joinCode and Sha256.hmacHex(self.joinCode, nonce)
  -- Sha256.equals, never ==: a plain compare on a digest returns as soon as
  -- two bytes differ, and a peer that can time this hub's answer recovers a
  -- valid response one byte at a time.
  if not (response and expected and Sha256.equals(expected, response)) then
    return self:refuseClient(client, "That join code was not accepted.")
  end
  self:admit(client)
end

handlers[Wire.MOVE] = function(self, client, msg)
  if not client.ready then return end
  local map = Wire.mapId(msg.map)
  local x, y = Wire.int(msg.x, 0, 4096), Wire.int(msg.y, 0, 4096)
  if map and x and y then
    client.map, client.x, client.y = map, x, y
  else
    -- no cell means "not in the world right now" (a battle, a menu): the
    -- player stays on the roster but stops being placeable
    client.map, client.x, client.y = nil, nil, nil
  end
  if Wire.facing(msg.facing) then client.facing = msg.facing end
  -- Client-truth, and strict on purpose: only a literal boolean true counts
  -- as a fast step -- a sprint or a bike, the sender's business which --
  -- and everything else -- absent, 0, "", "yes", null -- is walking pace.
  -- The rule is strictness rather than coercion because this hub and the
  -- Node hub (server/lib/relay.js) have to broadcast the same thing for the
  -- same wire bytes, and Lua and JS truthiness disagree on exactly the
  -- values a malformed client sends: 0 and "" are true to Lua's `and` and
  -- false to JS's Boolean().  Comparing against true is the one test both
  -- languages answer identically for every JSON value.
  client.fast = msg.fast == true
  self:broadcast(Wire.MOVE, presenceOf(client), client.id)
end

-- Smallest gap between two character changes from one player.  The chat
-- gate's window (Config.CHAT_GATE, half a second), for a sharper reason
-- than scrollback: an avatar bakes its sheet when it spawns, so every other
-- client in the game despawns and respawns this player to redraw them, and
-- an ungated change is one client making everyone else's world flicker for
-- free.  A literal rather than Config.CHAT_GATE itself, and fixed rather
-- than a host setting, because server/lib/relay.js has to refuse at exactly
-- the same moment for the same bytes -- one number moving would leave the
-- two hosting paths gating differently.
local SPRITE_GATE = 0.5

-- The character a player is wearing, changed mid-session.
--
-- The one field of a presence that used to be settled at hello and never
-- again.  It is stored here and said once; from then on presenceOf carries
-- the new value in every MOVE, JOIN and WELCOME by itself, so a client that
-- missed this message -- or joined after it -- is healed by the player's
-- next step rather than by anything extra sent from here.
handlers[Wire.SPRITE] = function(self, client, msg)
  if not client.ready then return end
  -- The identifier sanitiser, exactly as hello uses it (Wire.spriteId, never
  -- Wire.text -- prose rules eat the underscore).  An id this hub cannot
  -- make sense of costs its sender the message and nothing more.
  local sprite = Wire.spriteId(msg.sprite)
  if not sprite or sprite == client.sprite then return end

  -- Checked after the no-op above, so a client re-sending the character it
  -- is already wearing does not arm the gate against the next real change.
  if self.clock - client.lastSprite < SPRITE_GATE then return end
  client.lastSprite = self.clock

  client.sprite = sprite
  -- Broadcast with no exception, like publishPoints: the player it is about
  -- hears it too.  Their own presence is not in their own roster, so this is
  -- the message that confirms the hub took the change.
  --
  -- **Nothing fallible sits between the store above and this line, and the
  -- announcement goes out before anything else that could throw.** The store
  -- is what arms the no-op guard at the top of this handler, so a store that
  -- was never announced is not a lost message -- it is a permanently lost
  -- one: the client's reconcile loop (src/Client.lua's SPRITE_RETRY) re-sends
  -- the same id for the rest of the session and every retry is eaten by
  -- `sprite == client.sprite`, with nobody else ever told. That is a whole
  -- session's worth of silence bought by one throw, so the order is the
  -- invariant: say it, then do the rest.
  self:broadcast(Wire.SPRITE, { id = client.id, sprite = sprite })
  -- The board learns the new face too, so a RANKING answer given after this
  -- draws the character the player is wearing now rather than the one they
  -- greeted in.  The same call admit() makes, under the same guard: a player
  -- who does not own the name has no business writing to its row.  Last,
  -- because it is the one call here that reaches state this handler does not
  -- own, and a leaderboard portrait is not worth anyone's announcement.
  if client.ranked then self.board:seen(client.id, client.name, client.sprite) end
end

handlers[Wire.CHAT] = function(self, client, msg)
  if not client.ready then return end
  local scope = Wire.SCOPES[msg.scope] and msg.scope or nil
  local text = Wire.text(msg.text, Config.MESSAGE_MAX)
  if not (scope and text) then return end

  if self.clock - client.lastChat < Config.CHAT_GATE then return end
  client.lastChat = self.clock

  local payload = { from = client.id, name = client.name,
                    scope = scope, text = text }

  if scope == "private" then
    local target = self.clients[Wire.id(msg.to) or ""]
    if target and target.ready then send(target, Wire.CHAT, payload) end
    return
  end

  -- A party line reaches the party wherever they are: no radius, no map,
  -- no target to type.  A client that is not in one is dropped rather than
  -- broadcast -- a scope that quietly widened to everybody would be the
  -- worst possible failure for a message somebody meant privately.
  if scope == "party" then
    if not client.partyId then return end
    for _, member in ipairs(self:partyMembers(client.partyId)) do
      if member.id ~= client.id then send(member, Wire.CHAT, payload) end
    end
    return
  end

  if scope == "local" then
    if not client.map then return end
    for id, other in pairs(self.clients) do
      if id ~= client.id and other.ready and other.map == client.map then
        local distance = math.max(math.abs(other.x - client.x),
                                  math.abs(other.y - client.y))
        if distance <= Config.LOCAL_RADIUS then
          send(other, Wire.CHAT, payload)
        end
      end
    end
    return
  end

  self:broadcast(Wire.CHAT, payload, client.id)
end

handlers[Wire.REQUEST] = function(self, client, msg)
  if not client.ready or client.sessionId then return end
  local kind = Wire.KINDS[msg.kind] and msg.kind or nil
  local target = self.clients[Wire.id(msg.to) or ""]
  if not (kind and target and target.ready) or target.id == client.id then
    return
  end
  if target.sessionId then
    return send(client, Wire.DECLINE, { name = target.name, kind = kind })
  end
  client.pendingTo = target.id
  send(target, Wire.REQUEST,
    { from = client.id, name = client.name, kind = kind })
end

handlers[Wire.RESPOND] = function(self, client, msg)
  if not client.ready then return end
  local kind = Wire.KINDS[msg.kind] and msg.kind or nil
  local asker = self.clients[Wire.id(msg.to) or ""]
  if not (kind and asker and asker.ready) then return end

  -- only the player who was actually asked can answer, and only while the
  -- ask is still outstanding
  if asker.pendingTo ~= client.id then return end
  asker.pendingTo = nil

  if not msg.accept then
    return send(asker, Wire.DECLINE, { name = client.name, kind = kind })
  end
  if client.sessionId or asker.sessionId then
    return send(asker, Wire.DECLINE, { name = client.name, kind = kind })
  end
  self:startSession(asker, client, kind)
end

-- The asker takes the request back before it is answered.  Only they can:
-- pendingTo lives on their connection, and a forged cancel from somebody
-- else has nothing to clear.  The player holding the yes/no box is told,
-- so they are not left answering an ask nobody is waiting on any more.
handlers[Wire.REQUEST_CANCEL] = function(self, client)
  if not client.ready then return end
  local targetId = client.pendingTo
  if not targetId then return end
  client.pendingTo = nil
  local target = self.clients[targetId]
  if target and target.ready then
    send(target, Wire.REQUEST_CANCEL, { from = client.id, name = client.name })
  end
end

-- The invite, and the two answers to it.
--
-- Deliberately the same shape as the trade/battle request above -- one
-- outstanding ask per client, only the player who was asked may answer it,
-- and the ask is spent on the first answer -- because it is the same
-- problem, and a second, subtly different handshake living beside the first
-- would be two things to keep right instead of one.
--
-- What is *not* shared is the state it guards: a party is independent of a
-- session, so two friends may team up while one of them is mid-trade.  Being
-- busy stops you battling, not travelling together.
handlers[Wire.PARTY_INVITE] = function(self, client, msg)
  if not client.ready or client.partyId then return end
  local target = self.clients[Wire.id(msg.to) or ""]
  if not (target and target.ready) or target.id == client.id then return end
  -- Answered here rather than forwarded: the asker learns at once that this
  -- player is taken, instead of waiting on a prompt nobody will ever see.
  if target.partyId then
    return send(client, Wire.PARTY_DECLINE,
      { name = target.name, reason = "in_party" })
  end
  client.partyPendingTo = target.id
  send(target, Wire.PARTY_INVITE, { from = client.id, name = client.name })
end

handlers[Wire.PARTY_RESPOND] = function(self, client, msg)
  if not client.ready then return end
  local asker = self.clients[Wire.id(msg.to) or ""]
  if not (asker and asker.ready) then return end

  -- only the player who was actually asked can answer, and only while the
  -- ask is still outstanding
  if asker.partyPendingTo ~= client.id then return end
  asker.partyPendingTo = nil

  if not msg.accept then
    return send(asker, Wire.PARTY_DECLINE, { name = client.name, reason = "no" })
  end
  -- Re-checked at the moment of forming, not only when the invite went out:
  -- either of them could have joined somebody else's party while this one
  -- sat on screen waiting for a human to read it.
  if client.partyId or asker.partyId then
    return send(asker, Wire.PARTY_DECLINE,
      { name = client.name, reason = "in_party" })
  end
  self:startParty(asker, client)
end

handlers[Wire.PARTY_LEAVE] = function(self, client)
  if not client.ready then return end
  self:endParty(client, "peer_left")
end

-- What the person you are travelling with just did in a fight.  Party-only,
-- same fan-out as a party chat line: the sender already knows, so they are
-- not told again.  `name` is stamped from the connection -- a client that
-- supplied its own would be writing lines on its partner's screen under
-- somebody else's nick.  Kept in step with server/lib/relay.js.
handlers[Wire.PARTY_EVENT] = function(self, client, msg)
  if not client.ready or not client.partyId then return end
  local event = Wire.partyEvent({
    kind = msg.kind,
    species = msg.species,
    level = msg.level,
    trainer = msg.trainer,
    -- Wire.partyEvent requires name; stamp the real one before sanitising so
    -- a forged outbound name cannot pass validation and then get overwritten.
    name = client.name,
    from = client.id,
  })
  if not event then return end

  -- The chat gate, on the chat window, for the same reason chat has one:
  -- this is prose appearing unasked-for in the corner of somebody else's
  -- screen, and a modified client sending it in a loop is the whole attack.
  -- Honest traffic is at most one per battle, so half a second costs a
  -- legitimate partner nothing.  server/lib/relay.js gates it at the same
  -- moment, on the same interval.
  if self.clock - (client.lastPartyEvent or -math.huge) < Config.CHAT_GATE then
    return
  end
  client.lastPartyEvent = self.clock

  local payload = {
    kind = event.kind,
    species = event.species,
    level = event.level,
    trainer = event.trainer,
    from = client.id,
    -- The sanitised value, not the raw field it was stamped from: the two
    -- agree today, and reading the one Wire vouched for is what keeps them
    -- agreeing if the sanitiser ever normalises a name on the way through.
    name = event.name,
  }
  for _, member in ipairs(self:partyMembers(client.partyId)) do
    if member.id ~= client.id then send(member, Wire.PARTY_EVENT, payload) end
  end
end

-- ------- friends
--
-- Three handlers, and the asymmetry between them is the security model.  The
-- ask is forwarded on the sender's say-so, because the worst it can do is put
-- a yes/no box in front of somebody who says no.  The *answer* is not: a
-- client that could send one to anybody would be a client that adds itself to
-- a stranger's list without ever being agreed to, so it is only passed on when
-- this hub is holding the matching ask.  The removal needs no check at all,
-- because the hub stamps the sender's own name on it -- the only thing a
-- forged one achieves is taking its sender off somebody's list, which is what
-- the message says it does.

handlers[Wire.FRIEND_ASK] = function(self, client, msg)
  if not client.ready then return end
  local target = self.clients[Wire.id(msg.to) or ""]
  if not (target and target.ready) or target.id == client.id then return end

  local mine = Wire.nameKey(client.name)
  local theirs = Wire.nameKey(target.name)
  -- Two connections wearing one name on a hub that never claimed it.  There is
  -- no friendship to form between a name and itself, and the hold table is
  -- keyed by name, so an ask filed here would be one this player could answer
  -- on the asker's behalf.
  if not (mine and theirs) or mine == theirs then return end

  -- Gated on the chat window, for the reason mmo.party_event is: this puts
  -- prose and a modal on somebody else's screen unasked, and a modified client
  -- pressing it in a loop is the whole attack.  Honest traffic is one ask per
  -- friendship, so half a second costs nobody anything.
  if self.clock - (client.lastFriendAsk or -math.huge) < Config.CHAT_GATE then
    return
  end
  client.lastFriendAsk = self.clock

  deliverFriend(self, theirs, "ask", Wire.FRIEND_ASK,
    { from = client.id, name = client.name },
    { kind = "ask", name = client.name })
end

handlers[Wire.FRIEND_ANSWER] = function(self, client, msg)
  if not client.ready then return end
  local mine = Wire.nameKey(client.name)
  local asker = Wire.nameKey(msg.toName)
  if not (mine and asker) then return end

  -- The gate: only somebody who is actually holding an ask from this name may
  -- answer it, and the ask is spent on the first answer.
  if not self:takeFriendHold(mine, "ask", asker) then return end

  local accept = msg.accept == true
  deliverFriend(self, asker, "answer", Wire.FRIEND_ANSWER,
    { name = client.name, accept = accept },
    { kind = "answer", name = client.name, accept = accept })
end

handlers[Wire.FRIEND_REMOVE] = function(self, client, msg)
  if not client.ready then return end
  local mine = Wire.nameKey(client.name)
  local theirs = Wire.nameKey(msg.toName)
  if not (mine and theirs) or mine == theirs then return end

  -- Anything still outstanding between the two of them goes with it, in both
  -- directions: an ask that outlived the friendship it was about is a box
  -- somebody would be answering about a decision already made.
  self:takeFriendHold(mine, "ask", theirs)
  self:takeFriendHold(theirs, "ask", mine)

  deliverFriend(self, theirs, "remove", Wire.FRIEND_REMOVE,
    { name = client.name }, { kind = "remove", name = client.name })
end

-- ------- co-op

-- "I am standing at this fight, waiting."  Forwarded to exactly one player --
-- the one this client is travelling with -- and refused outright for a client
-- with no party, because an offer nobody can accept is a message with nowhere
-- to go.
handlers[Wire.COOP_WAIT] = function(self, client, msg)
  if not client.ready or not client.partyId then return end
  local battle = Wire.battleKey(msg.battle)
  if not battle then return end
  local partner = self:partnerOf(client)
  if not partner then return end

  client.coopOffer = {
    battle = battle,
    label = Wire.label(msg.label),
    map = Wire.mapId(msg.map),
    -- Stamped so the sweep can expire it on the same clock the partner's
    -- client already uses; without one the two ends disagreed about whether
    -- the fight was still joinable.
    startedAt = self.clock,
  }
  send(partner, Wire.COOP_OFFER, {
    from = client.id,
    name = client.name,
    battle = battle,
    label = client.coopOffer.label,
    map = client.coopOffer.map,
  })
end

handlers[Wire.COOP_CANCEL] = function(self, client, msg)
  if not client.ready then return end
  local reason = Wire.coopReason(msg and msg.reason) or "left"
  -- Own standing offer withdrawn (STOP / ALONE / timeout).
  if client.coopOffer then
    return self:clearCoopOffer(client, reason)
  end
  -- Partner declined our invite: clear the waiter's offer and tell them so
  -- they can go in alone. Only `no` takes this path -- other reasons without
  -- an own offer are noise from a client that is not waiting.
  if reason == "no" then
    local partner = self:partnerOf(client)
    if partner and partner.coopOffer then
      partner.coopOffer = nil
      send(partner, Wire.COOP_DECLINE, { name = client.name, reason = "no" })
    end
  end
end

-- "Yes, I'll join you."  The one message that ends a wait.
--
-- Every condition is re-checked here and not taken on the client's word: that
-- the two are actually in one party, that the offer still stands, and that it
-- is the *same* fight.  The last is what stops a modified client dragging its
-- partner out of wherever they are into a battle they never walked up to.
handlers[Wire.COOP_JOIN] = function(self, client, msg)
  if not client.ready or not client.partyId then return end
  local host = self.clients[Wire.id(msg.to) or ""]
  if not (host and host.ready) or host.id == client.id then return end
  if host.partyId ~= client.partyId then return end

  local offer = host.coopOffer
  local battle = Wire.battleKey(msg.battle)
  if not (offer and battle and offer.battle == battle) then
    -- Too late: the waiter already went in alone (or walked off). Tell the
    -- joiner so a yes that raced a withdraw is not silence -- same sentence
    -- their confirm would have gotten from onOfferEnd.
    send(client, Wire.COOP_OFFER_END, { reason = "alone" })
    return
  end

  -- Taken off the table before either side is told, so a second join racing
  -- this one finds nothing to accept rather than starting the fight twice.
  host.coopOffer = nil
  client.coopOffer = nil

  local members = {}
  for _, member in ipairs(self:partyMembers(client.partyId)) do
    members[#members + 1] = { id = member.id, name = member.name }
  end

  -- The two sides of one agreement, told differently on purpose: the player
  -- who was waiting learns *who* joined (it is the answer they have been
  -- standing there for), and the player who joined is handed the roster,
  -- because they never had one.
  -- The pair get a fan-out group of their own, on the same footing as a
  -- four-player one: from here on the battle traffic does not care which of
  -- the two ways it was agreed.
  --
  -- `coop_npc`, and it is the flow that decides it rather than a head count:
  -- this pair agreed by one of them standing in front of a trainer, so the
  -- other side of the field is that trainer -- an opponent with a party and no
  -- connection.  The four-way path is the only one that makes a `coop_pvp`,
  -- because it is the only one where both sides are players.
  -- "c", for startSession's reason: sessions and co-op battles share the
  -- `battles` table and are numbered by two counters that know nothing of each
  -- other.
  local id = "c" .. tostring(self.nextCoopAsk)
  self.nextCoopAsk = self.nextCoopAsk + 1
  self:openCoopBattle(id, { host.id, client.id },
    { mode = "coop_npc", hostId = host.id })

  -- `plan` is the hub's mediated battle id (`c*`). Without it the waiting
  -- host's CoopBattle has no battleId, uploadMediated is a no-op, and the
  -- fight silently stays on host CoopSim while the joiner alone holds `c*`.
  -- `id` remains the joiner (who joined), matching what clients already read.
  send(host, Wire.COOP_JOINED,
    { id = client.id, name = client.name, plan = id })
  -- `host` names the client that simulates. It is the player who was already
  -- standing at the fight, because they are the one *guaranteed* to have
  -- walked into the trainer -- the joiner usually has too, but a join taken
  -- from the ACTIONS menu never went near them.
  send(client, Wire.COOP_BATTLE,
    { id = id, side = "a", allies = members, battle = battle, host = host.id })
end

-- Battle traffic, fanned out to everyone else in the same battle.
--
-- The payload is forwarded unread, exactly as mmo.relay's is -- the hub does
-- not simulate a battle here any more than it does a 1v1 -- so its *shape* is
-- the only thing that can be judged, and Wire.payloadOk is what judges it.
handlers[Wire.COOP_RELAY] = function(self, client, msg)
  if not client.ready or not client.coopBattleId then return end

  -- ...unless the hub is running this one, in which case the same cut
  -- mmo.relay gets applies and for the same reason.
  --
  -- **The cut engages when the sim does, not when the group opens**, and that
  -- is the one place the co-op path deliberately differs from the 1v1.  A
  -- group exists from the moment two players agree; the fight only becomes
  -- mediated when a ruleset and every party have arrived.  Cutting at the
  -- group would take the client-simulated path away from a client that has
  -- not been rewritten to upload one yet, and would take it away *silently*
  -- -- a partner watching a battle screen that never advances.  So the two
  -- coexist for exactly as long as it takes one fight to become mediated, and
  -- no longer: the moment an intermediator owns the rolls, a second set of
  -- them fanned out from a client is the desync it looks like.
  local mediated = self.battles[client.coopBattleId]
  if mediated and mediated.sim then
    return noteDrop(self, client,
      "this co-op battle is mediated -- the battle_* types are the way in")
  end

  if not Wire.payloadOk(msg.payload) then
    return noteDrop(self, client, "the co-op payload is not a shape we forward")
  end
  local group = self.coopBattles[client.coopBattleId]
  for _, memberId in ipairs((group and group.members) or {}) do
    if memberId ~= client.id then
      local member = self.clients[memberId]
      if member and member.ready then
        send(member, Wire.COOP_MSG, { from = client.id, payload = msg.payload })
      end
    end
  end
end

-- The four-way ask.  Two parties, four players, and three answers to collect.
-- A player says their co-op battle is finished.
--
-- One goodbye closes the whole group rather than removing one member: a co-op
-- battle ends for everybody at the same moment, so a group that outlived one
-- of its players would be a group with nothing left to carry.
handlers[Wire.COOP_LEAVE] = function(self, client)
  if not client.ready or not client.coopBattleId then return end
  -- ...except while the hub is refereeing it, where one player walking out is
  -- a disconnection and not a verdict.  The others keep fighting, and the
  -- leaver's grace decides whether they come back or forfeit -- ending the
  -- whole thing on their say-so would hand any of the four a way to void a
  -- battle they were losing.
  local record = self.battles[client.coopBattleId]
  if record and record.sim then
    if record.sim:disconnect(client.id) then self:flushBattle(record) end
    return
  end
  self:closeCoopBattle(client.coopBattleId)
end

handlers[Wire.COOP_CHALLENGE] = function(self, client, msg)
  if not client.ready or not client.partyId then return end
  if client.coopAskId then return end
  local target = self.clients[Wire.id(msg.to) or ""]
  if not (target and target.ready) or target.id == client.id then return end
  -- Not in a party, or in *ours*: a party cannot challenge itself, and the
  -- client already refuses both with a sentence -- this is the hub declining
  -- to take a modified one at its word.
  if not target.partyId or target.partyId == client.partyId then return end
  if target.coopAskId then return end

  local mine = self:partyMembers(client.partyId)
  local theirs = self:partyMembers(target.partyId)
  if #mine ~= Config.PARTY_MAX or #theirs ~= Config.PARTY_MAX then return end

  local id = "c" .. tostring(self.nextCoopAsk)
  self.nextCoopAsk = self.nextCoopAsk + 1

  local sideA, sideB, everyone = {}, {}, {}
  for _, member in ipairs(mine) do
    sideA[#sideA + 1] = member.id
    everyone[#everyone + 1] = member.id
  end
  for _, member in ipairs(theirs) do
    sideB[#sideB + 1] = member.id
    everyone[#everyone + 1] = member.id
  end

  self.coopAsks[id] = {
    asker = client.id, name = client.name,
    sideA = sideA, sideB = sideB, everyone = everyone,
    -- The asker's own yes is implied by asking; the other three are counted.
    answers = { [client.id] = true },
    needed = #everyone - 1,
    startedAt = self.clock,
  }
  for _, memberId in ipairs(everyone) do
    local member = self.clients[memberId]
    if member then member.coopAskId = id end
  end

  for _, memberId in ipairs(everyone) do
    if memberId ~= client.id then
      local member = self.clients[memberId]
      local side = member.partyId == client.partyId and "a" or "b"
      send(member, Wire.COOP_ASK,
        { id = id, from = client.id, name = client.name, side = side })
    end
  end
end

handlers[Wire.COOP_ANSWER] = function(self, client, msg)
  if not client.ready then return end
  local id = Wire.id(msg.id)
  local ask = id and self.coopAsks[id]
  if not ask then return end
  -- Only somebody actually in this ask can answer it, and the asker cannot
  -- answer their own -- their yes was spent on asking.
  if client.coopAskId ~= id or client.id == ask.asker then return end

  if not msg.accept then
    return self:endCoopAsk(id, client.name, "no")
  end
  -- Counted rather than incremented, so a client that sends yes twice cannot
  -- talk the hub into starting a battle its fourth player never agreed to.
  if ask.answers[client.id] then return end
  ask.answers[client.id] = true

  local yes = 0
  for _ in pairs(ask.answers) do yes = yes + 1 end
  if yes > ask.needed then self:startCoopBattle(id) end
end

-- ------- the four things a client says during a fight the hub is running
--
-- What comes back -- mmo.battle_ready, mmo.battle_event, mmo.battle_outcome --
-- is sent from the methods above rather than from here, because it is the
-- sim's word rather than an answer to any one message.

-- The ephemeral ruleset: the type chart this one match runs under.
--
-- A `seed` still parses, because the field has ridden this message since the
-- lockstep days, but tryStartSim does not read it -- see the note there for why
-- the RNG is the intermediator's alone.
--
-- The authority's to upload and nobody else's -- the asker in a 1v1, the
-- player who was already standing at the trainer in a co-op fight.  Not
-- because a guest's chart would be worse, but because two charts is a fight
-- with no answer to "which", and taking the second to arrive would let either
-- side re-roll the matchups by sending one late.
handlers[Wire.BATTLE_RULESET] = function(self, client, msg)
  local record = mediatedOf(self, client)
  if not record or record.sim then return end
  if client.id ~= record.hostId then return end

  local ruleset = Wire.battleRuleset(msg)
  if not ruleset then
    return noteDrop(self, client,
      "the ruleset is not a shape we can fight under")
  end
  record.ruleset = ruleset
  self:tryStartSim(record)
end

-- One combatant's team.  Stored under the seat it belongs to -- normally the
-- sender's own -- and the fight opens on the message that completes the set.
handlers[Wire.BATTLE_PARTY] = function(self, client, msg)
  local record = mediatedOf(self, client)
  if not record or record.sim then return end

  local party = Wire.battleParty(msg)
  if not party then
    return noteDrop(self, client, "the party is not a shape we can fight with")
  end
  -- The battle it names has to be the one this connection is in.  A party for
  -- another fight is not a party that was mis-addressed, it is a sheet whose
  -- sender believes it is being used somewhere else.
  if party.battle ~= record.id then return end

  if not self:fillBattleParty(record, client, party) then return end
  self:tryStartSim(record)
end

-- One turn's intent.  Who it is from is the connection it arrived on and never
-- a field, so there is nothing here for a modified client to spend somebody
-- else's turn with.
handlers[Wire.BATTLE_CHOICE] = function(self, client, msg)
  local record = mediatedOf(self, client)
  if not record or not record.sim then return end

  local choice = Wire.battleChoice(msg)
  if not choice or choice.battle ~= record.id then return end
  -- Item choices are proved against the bag uploaded with the party
  -- (PROTOCOL 15). A missing stack costs the message and nothing else —
  -- same silence as a refused choice — so the turn clock keeps running.
  -- The stack is *held* until the turn resolves; cancel clears the hold.
  if choice.action == "item"
     and not self:canSpendBag(record, client.id, choice.item) then
    return
  end
  if not record.sim:submitChoice(client.id, choice) then return end
  if choice.action == "item" then
    self:holdBag(record, client.id, choice.item)
  elseif choice.action == "cancel" then
    self:clearBagHold(record, client.id)
  end
  self:flushBattle(record)
end

-- Back inside the grace.
--
-- What this covers is a client that left the *field* -- backed out to the
-- overworld, dropped its session, lost the battle screen to a crash it
-- recovered from -- and still holds the connection it was fighting on.  A peer
-- whose socket actually died cannot come back through here at all: identity on
-- this hub is the connection, so the returning process is a new client with a
-- new id and its fight forfeits when the grace runs out.
handlers[Wire.BATTLE_RECONNECT] = function(self, client, msg)
  local record = mediatedOf(self, client)
  if not record or not record.sim then return end
  local rejoin = Wire.battleReconnect(msg)
  if not rejoin or rejoin.battle ~= record.id then return end
  record.sim:reconnect(client.id)
  self:flushBattle(record)
end

handlers[Wire.RELAY] = function(self, client, msg)
  if not client.ready or not client.sessionId then
    return noteDrop(self, client, "sender is not in a session")
  end
  -- PROTOCOL 10's hard cut, and it is a cut rather than a preference.
  --
  -- A mediated battle exists for every battle session this hub brokers, so
  -- from here on the engine's lockstep vocabulary has nowhere to go: the two
  -- clients would agree a seed between themselves and fight a second,
  -- invisible battle beside the one the hub is resolving, and the first
  -- disagreement would be a player watching their own screen contradict the
  -- outcome they are about to be sent.  Trade sessions are untouched -- there
  -- is no trade sim here and there is not going to be one.
  if self.battles[client.sessionId] then
    return noteDrop(self, client,
      "this battle is mediated -- the battle_* types are the way in")
  end
  local peer = self:peerOf(client)
  if not peer then
    return noteDrop(self, client, "the session has no other side")
  end
  if Wire.id(msg.to) ~= peer.id then
    return noteDrop(self, client, "addressed to someone who is not the peer")
  end
  if not Wire.payloadOk(msg.payload) then
    return noteDrop(self, client, "payload is deeper or larger than the cap")
  end
  -- The hub does not read the payload. It is the engine's own link
  -- vocabulary, and interpreting it here would couple this to a protocol
  -- the game already owns.
  send(peer, Wire.RELAY, { from = client.id, payload = msg.payload })
end

handlers[Wire.SESSION_LEAVE] = function(self, client)
  self:endSession(client, "peer_left")
end

handlers[Wire.RESULT] = function(self, client, msg)
  if not client.ready then return end
  local id = Wire.id(msg.session)
  local outcome = Wire.outcome(msg.outcome)
  if not (id and outcome) then return end

  -- A fight the hub itself resolved has no use for a vote.  settleMediated
  -- paid out from the witness's verdict already; an honest report here is
  -- redundant and a dishonest one is the whole thing that path removes.
  --
  -- Gated on the sim rather than on the record, because a record exists for
  -- every battle session from the moment it opens.  Until a ruleset and both
  -- parties arrive the two clients are still on the lockstep path and their
  -- vote is still the only account of the fight there is.
  local mediated = self.battles[id]
  if mediated and mediated.sim then return end

  -- A co-op battle files under its own paperwork, because four players report
  -- one battle rather than two.
  if self.coopMatches[id] then
    return self:reportCoop(id, client, outcome)
  end

  local match = self.matches[id]
  -- No paperwork means the battle was never here, was scored already, or
  -- finished longer ago than the grace period. All three are the same
  -- answer: nothing happens, and nobody is told off for it.
  if not match then return end
  if client.id ~= match.a and client.id ~= match.b then return end
  -- First answer stands. A client that could revise its report could keep
  -- trying until it matched whatever its opponent said.
  if match.reports[client.id] then return end

  match.reports[client.id] = outcome
  self:settleMatch(id)
end

handlers[Wire.RANKS] = function(self, client)
  if not client.ready then return end
  -- Gated like chat: answering means sorting every rating this hub holds,
  -- and the screen that asks is one a player can sit on.
  if self.clock - (client.lastRanks or -math.huge) < Config.RANK_QUERY_GATE then
    return
  end
  client.lastRanks = self.clock
  send(client, Wire.RANKING, { entries = self.board:top(Config.RANK_TOP) })
end

handlers[Wire.PING] = function(self, client)
  send(client, Wire.PONG, {})
end

-- ------- entry points

function M:receive(client, msg)
  if not client then return end
  if not self.clients[client.id]
     and not (client.ephemeralId and self.byEphemeral
              and self.byEphemeral[client.ephemeralId] == client) then
    return
  end
  if type(msg) ~= "table" or type(msg.type) ~= "string" then return end
  local handler = handlers[msg.type]
  if not handler then return end
  -- Contained, matching server/lib/relay.js handle(): a Turn/Damage throw must
  -- not take the LAN host down. The next message still lands; the fight's own
  -- resolveDeadline is what finishes a wedge left mid-resolve.
  local ok, err = pcall(handler, self, client, msg)
  if not ok and self.onHandlerError then
    self.onHandlerError(msg.type, client.id, err)
  end
end

function M:update(dt)
  self.clock = self.clock + (dt or 0)

  -- Before the sweeps, deliberately: a fight that ends on this tick should be
  -- told to its players from the clock that ended it, not from whatever the
  -- next message to arrive happens to be. src/HostServer.lua already calls
  -- this every frame, so a host that pumps the hub pumps its battles too and
  -- there is nothing new for src/Client.lua to remember.
  self:tickBattles(self.clock)

  -- Reap connections that never finished introducing themselves. Without
  -- this a peer can hold a slot indefinitely simply by saying nothing.
  --
  -- **One budget for the whole handshake** (Config.HANDSHAKE_TIMEOUT, ten
  -- seconds), anchored at accept and never extended: being challenged buys
  -- a peer no extra time, so an unanswered challenge is exactly as reapable
  -- as an unspoken hello and re-sending hello for a fresh nonce cannot renew
  -- anything.  server/lib/limits.js measures the same ten seconds from the
  -- same moment, which is the point -- one client dialling the two hosting
  -- paths must not meet two different deadlines.
  local stale
  for _, client in pairs(self.clients) do
    if not client.ready
       and (self.clock - (client.since or 0)) > Config.HANDSHAKE_TIMEOUT then
      stale = stale or {}
      stale[#stale + 1] = client
    end
  end
  for _, client in ipairs(stale or {}) do
    if client.peer then
      client.peer:send({ type = Wire.ERROR, message = "Took too long to join." })
      client.peer:close()
    end
    self:drop(client)
  end

  -- Finished battles nobody ever agreed on. Dropped rather than guessed at:
  -- one report is not a result, and a hub that kept them would grow a table
  -- of unfinished arguments for as long as it ran.
  local expired
  for id, match in pairs(self.matches) do
    if match.endedAt
       and (self.clock - match.endedAt) > Config.RANK_REPORT_GRACE then
      expired = expired or {}
      expired[#expired + 1] = id
    end
  end
  for _, id in ipairs(expired or {}) do self.matches[id] = nil end

  -- Four-way asks nobody finished answering.  Reaped rather than left, because
  -- three players are holding a box for each one and coopAskId is what stops
  -- them being asked anything else -- an ask that never resolved would lock
  -- all four out of the feature for as long as the hub ran.
  local cold
  for id, ask in pairs(self.coopAsks) do
    if (self.clock - (ask.startedAt or 0)) > Config.COOP_ASK_TIMEOUT then
      cold = cold or {}
      cold[#cold + 1] = id
    end
  end
  for _, id in ipairs(cold or {}) do self:endCoopAsk(id, nil, "timeout") end

  -- Co-op battles nobody finished reporting, on the same grace the 1v1
  -- paperwork gets and for the same reason: an argument nobody settled is not
  -- a table the hub should carry for as long as it runs.
  local stale2
  for id, match in pairs(self.coopMatches) do
    if (self.clock - (match.startedAt or 0)) > Config.RANK_REPORT_GRACE then
      stale2 = stale2 or {}
      stale2[#stale2 + 1] = id
    end
  end
  for _, id in ipairs(stale2 or {}) do self.coopMatches[id] = nil end

  -- Relay groups whose battle never said goodbye -- a client that crashed
  -- rather than disconnected. Closed properly rather than dropped, so the
  -- members are let out of it too.
  local dead
  for id, group in pairs(self.coopBattles) do
    if (self.clock - (group.startedAt or 0)) > Config.COOP_BATTLE_MAX then
      dead = dead or {}
      dead[#dead + 1] = id
    end
  end
  for _, id in ipairs(dead or {}) do self:closeCoopBattle(id) end
end

-- Tell everyone the game is over, then forget them. Called when the host
-- stops hosting or leaves: there is no host migration, so the honest thing
-- is to say so rather than leave clients talking to a dead listener.
function M:shutdown(message)
  for _, client in pairs(self.clients) do
    if client.peer then
      client.peer:send({
        type = Wire.ERROR,
        message = message or "The host ended the game.",
      })
      client.peer:close()
    end
  end
  self.clients, self.count, self.players = {}, 0, 0
  self.sessions, self.parties = {}, {}
  -- The asks and the battles go with the connections they were between; there
  -- is nobody left to answer one or to fight the other.  A fight in progress
  -- does not survive the process that was refereeing it.
  self.coopAsks, self.coopBattles, self.coopMatches = {}, {}, {}
  self.battles = {}
  -- The board survives: it is the hub's record, not the connection's, and a
  -- host who stops and starts a game has not un-won anybody's battles. The
  -- half-reported matches do not -- their sessions are gone.
  self.matches = {}
end

M.presenceOf = presenceOf

return M
