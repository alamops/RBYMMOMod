-- The hub, as pure logic.
--
-- This is the same relay `server/hub.js` implements, ported to Lua so a
-- player can host from inside the game. It owns who is connected, where
-- they last said they were, which two players are paired, and the player
-- cap the host chose. It does not simulate anything: trade and battle run
-- inside the two clients on the engine's own link code, and `mmo.relay`
-- payloads pass through unread.
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
    nextId = 1,
    nextSession = 1,
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
    profile = client.profile,
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
    sessionId = nil,
    pendingTo = nil,
    lastChat = -math.huge,
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
  client.name = hello.name
  client.sprite = hello.sprite or Config.DEFAULT_SPRITE
  client.profile = hello.profile
  client.map, client.x, client.y = hello.map, hello.x, hello.y
  client.facing = hello.facing or "down"
  client.hello, client.nonce = nil, nil
  client.ready = true
  self.players = self.players + 1

  local players = {}
  for id, other in pairs(self.clients) do
    if other.ready and id ~= client.id then
      players[#players + 1] = presenceOf(other)
    end
  end
  send(client, Wire.WELCOME, { id = client.id, players = players })
  self:broadcast(Wire.JOIN, { player = presenceOf(client) }, client.id)
  return true
end

function M:drop(client)
  if not client or not self.clients[client.id] then return false end
  self:endSession(client, "peer_left")
  self.clients[client.id] = nil
  self.count = self.count - 1
  if client.ready then self.players = self.players - 1 end
  -- an outstanding request pointed at a player who just left would let the
  -- asker wait forever for an answer nobody can give
  for _, other in pairs(self.clients) do
    if other.pendingTo == client.id then other.pendingTo = nil end
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
  local session = self.sessions[id]
  self.sessions[id] = nil
  client.sessionId = nil

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
  local id = tostring(self.nextSession)
  self.nextSession = self.nextSession + 1
  self.sessions[id] = { a = a.id, b = b.id, kind = kind }
  a.sessionId, b.sessionId = id, id

  -- The requester hosts. Someone has to deal the battle's shared RNG seed,
  -- and picking the side that asked keeps it deterministic rather than
  -- racing on who answers first.
  send(a, Wire.SESSION,
    { peer = b.id, peerName = b.name, kind = kind, role = "host", id = id })
  send(b, Wire.SESSION,
    { peer = a.id, peerName = a.name, kind = kind, role = "guest", id = id })

  self:broadcast(Wire.MOVE, presenceOf(a), a.id)
  self:broadcast(Wire.MOVE, presenceOf(b), b.id)
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
  self:broadcast(Wire.MOVE, presenceOf(client), client.id)
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

handlers[Wire.RELAY] = function(self, client, msg)
  if not client.ready or not client.sessionId then
    return noteDrop(self, client, "sender is not in a session")
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

handlers[Wire.PING] = function(self, client)
  send(client, Wire.PONG, {})
end

-- ------- entry points

function M:receive(client, msg)
  if not (client and self.clients[client.id]) then return end
  if type(msg) ~= "table" or type(msg.type) ~= "string" then return end
  local handler = handlers[msg.type]
  if handler then handler(self, client, msg) end
end

function M:update(dt)
  self.clock = self.clock + (dt or 0)

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
  self.clients, self.count, self.players, self.sessions = {}, 0, 0, {}
end

M.presenceOf = presenceOf

return M
