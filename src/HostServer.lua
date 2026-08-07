-- Hosting from inside the game: a non-blocking TCP listener that feeds Hub.
--
-- Everything socket-shaped lives here and nothing else does, so Hub stays
-- testable without luasocket. The framing is newline-delimited JSON --
-- byte-identical to what server/hub.js speaks and what src/link/Net.lua's
-- relay backend already parses -- so a joining client cannot tell whether
-- it reached a player's game or a dedicated Node hub, and does not care.
--
-- Blocking is the one thing that would be fatal here: this is pumped from
-- input.step, inside the game's own update, so every socket call is
-- settimeout(0) and every one is wrapped. A peer whose socket errors is
-- dropped; it must never propagate into the game loop.

local need, mod = ...
local Config = need("Config")
local Wire = need("Wire")
local Hub = need("Hub")

local M = {}
M.__index = M

local socketModule, socketTried
local jsonModule, jsonTried
local netModule, netTried

local function luasocket()
  if socketTried then return socketModule end
  socketTried = true
  local ok, module = pcall(require, "socket")
  if ok and type(module) == "table" then socketModule = module end
  return socketModule
end

-- src.link.Json is the encoder the engine's own relay backend uses, so
-- hosting and joining put identical bytes on the wire.
local function json()
  if jsonTried then return jsonModule end
  jsonTried = true
  local ok, module = pcall(require, "src.link.Json")
  if ok and type(module) == "table" then jsonModule = module end
  return jsonModule
end

local function linkNet()
  if netTried then return netModule end
  netTried = true
  local ok, module = pcall(require, "src.link.Net")
  if ok and type(module) == "table" then netModule = module end
  return netModule
end

function M.new()
  return setmetatable({
    hub = nil,
    server = nil,
    conns = {},      -- array of { sock, peer, client, rx, tx, dead }
    port = nil,
    running = false,
    error = nil,
  }, M)
end

-- ------- socket-backed peer handles

local Peer = {}
Peer.__index = Peer

local function newPeer(conn)
  return setmetatable({ conn = conn }, Peer)
end

function Peer:send(msg)
  local Json = json()
  local conn = self.conn
  if not Json or conn.dead then return end
  -- Encoding is guarded because it can genuinely fail: Json.decode tolerates
  -- input far deeper than Json.encode can re-emit, so a hostile relay
  -- payload used to throw here, escape into update()'s handler and stop
  -- hosting for everyone. One peer's message must never be able to end
  -- everybody's game -- so a message that will not encode kills that
  -- connection and nothing else.
  local ok, encoded = pcall(Json.encode, msg)
  if not ok then
    mod.log:warn("dropping a connection whose message could not be encoded "
      .. "(%s)", tostring(encoded))
    conn.dead = true
    return
  end
  conn.tx = conn.tx .. encoded .. "\n"
end

function Peer:close()
  -- flushed on the next pump, then reaped: a refusal has to reach the peer
  -- before the socket goes, or they see a silent drop instead of a reason
  self.conn.closing = true
end

-- ------- lifecycle

-- joinCode is required, and this is the layer that enforces it.
--
-- Hub is deliberately left able to run without one: it is pure logic, the
-- suite builds it directly, and both halves of the handshake -- challenged
-- and unchallenged -- have to stay exercisable under plain luajit.  This
-- file is the only thing in the mod that opens a socket, so it is the only
-- place where "no code" would mean a game a stranger can walk into.  Putting
-- the invariant here makes it true of every hub anyone can actually reach,
-- without making Hub untestable.
--
-- Absent and unusable are told apart because the remedies differ: one is
-- "choose a code", the other "that one won't do".  Both are returned rather
-- than raised -- the caller is inside a mod callback and has a screen to put
-- the sentence on.  The code itself never reaches self.error and never
-- reaches mod.log: an error string is read out on screen, and a log line
-- outlives the game that wrote it.
function M:start(port, maxPlayers, joinCode)
  if self.running then return false, "already hosting" end

  if type(joinCode) ~= "string" or joinCode == "" then
    self.error = "hosting needs a join code; set one from HOST > JOIN CODE"
    return false, self.error
  end
  local code = Wire.code(joinCode)
  if not code then
    self.error = "that join code can't be used; pick another"
    return false, self.error
  end

  local socket = luasocket()
  if not socket then
    self.error = "hosting needs luasocket (run the game with LOVE)"
    return false, self.error
  end
  if not json() then
    self.error = "hosting needs the engine's link modules"
    return false, self.error
  end

  port = tonumber(port) or Config.DEFAULT_PORT
  local server, err = socket.bind("*", port)
  if not server then
    self.error = ("can't open port %d (%s)"):format(port, tostring(err))
    return false, self.error
  end
  server:settimeout(0)

  self.server = server
  self.port = port
  -- Hub is pure logic and owns no logger; this is where a refused relay
  -- payload becomes something a host can actually see. Trade and battle are
  -- the only traffic on that path, so one of these lines is the difference
  -- between "the trade half-happened" and knowing why. Hub only calls this
  -- once per connection, so a peer sending nothing but junk cannot flood it.
  self.hub = Hub.new({
    maxPlayers = maxPlayers,
    joinCode = code,
    onDrop = function(reason, clientId)
      mod.log:warn("refused a relayed message from player %s (%s); "
        .. "if a trade or battle stalled, this is why -- ask them to "
        .. "reconnect, and report it if it repeats",
        tostring(clientId), tostring(reason))
    end,
    -- The other half of the same seam: a name changing hands, or a result
    -- refused because one did. server/lib/relay.js writes these to its own
    -- log, and a host running the game version could not see them at all.
    onClaim = function(what, name, clientId)
      if what == "taken" then
        mod.log:info("%s (player %s) took over an unconfirmed claim on that "
          .. "name -- nothing had scored under it, so a fresh ticket went out "
          .. "with the welcome", tostring(name), tostring(clientId))
      elseif what == "unscored" then
        mod.log:info("%s (player %s) joined without the claim token for that "
          .. "name, so their battles will not be scored -- if that is really "
          .. "them, ask them to pick another name for now",
          tostring(name), tostring(clientId))
      elseif what == "mid_battle" then
        mod.log:warn("a claim changed hands mid-battle (%s, player %s), so "
          .. "that result was not scored -- ask both sides to rematch",
          tostring(name), tostring(clientId))
      end
    end,
  })
  self.conns = {}
  self.running = true
  self.error = nil
  return true
end

function M:stop(message)
  if not self.running then return false end
  if self.hub then self.hub:shutdown(message) end
  -- shutdown queued a goodbye on every peer; push it out before the
  -- sockets close, so clients get a reason rather than a dead connection
  self:flush()
  for _, conn in ipairs(self.conns) do
    pcall(function() conn.sock:close() end)
  end
  self.conns = {}
  if self.server then pcall(function() self.server:close() end) end
  self.server, self.hub, self.running = nil, nil, false
  return true
end

-- players, not connections: a socket that has not said hello is not someone
-- you are playing with
function M:playerCount()
  return self.hub and self.hub.players or 0
end

function M:limit()
  return self.hub and self.hub.limit or Config.DEFAULT_PLAYERS
end

-- What the host reads out to their friends.  Net.lanIP() picks the
-- outbound interface without sending a packet; a host who is behind a
-- router still has to forward the port, which the README says plainly.
function M:address()
  if not self.running then return nil end
  local Net = linkNet()
  local ip = Net and Net.lanIP and Net.lanIP() or nil
  return ("%s:%d"):format(ip or "?", self.port)
end

-- ------- the host's own client, with no socket in the way
--
-- Returns a Net-shaped object (send/poll/update/close/.closed) that
-- Transport:attach takes as-is, so the host joins its own game through
-- exactly the same client code path a remote player uses.
function M:localNet()
  if not self.running then return nil, "not hosting" end
  local Json = json()
  if not Json then return nil, "no encoder" end

  local net = { closed = false, inbox = {} }
  local client

  local peer = {
    send = function(_, msg)
      -- Round-tripped through the encoder on purpose, exactly as
      -- Net.loopbackPair does: the host must see the same normalisation a
      -- remote sees, or a bug that only bites guests hides behind a host
      -- that works.
      --
      -- Guarded for the same reason Peer:send above is, and for one more
      -- that only applies here: this handle sits in the middle of Hub's
      -- broadcast fan-out, which visits clients in table order.  A throw
      -- here would abandon that loop, so the host's own copy of a message
      -- could cost every *other* player theirs -- and the hub would be left
      -- holding state it had already committed but never finished
      -- announcing.  A message the host cannot read is the host's problem
      -- alone.
      local ok, decoded = pcall(function()
        return Json.decode(Json.encode(msg))
      end)
      if not ok then
        mod.log:warn("could not deliver a message to your own game (%s); "
          .. "everyone else still got it -- report it if your own screen "
          .. "stops keeping up", tostring(decoded))
        return
      end
      if decoded and not net.closed then
        net.inbox[#net.inbox + 1] = decoded
      end
    end,
    close = function() net.closed = true end,
  }

  -- Trusted, and only this one is: the handle above never leaves this
  -- process, so nothing off the network can obtain it -- and a join code is
  -- for keeping strangers out, not for making the host type their own code
  -- to walk into the game they just started.  This is what keeps the code
  -- being mandatory from locking the host out of their own hub: start()
  -- refuses to run uncoded, and the host still walks in without typing it.
  client = self.hub:accept(peer, true)
  if not client then return nil, "the game is full" end

  net.send = function(_, msg)
    if net.closed then return end
    local decoded = Json.decode(Json.encode(msg))
    if decoded then self.hub:receive(client, decoded) end
  end
  net.poll = function(_)
    local msgs = net.inbox
    net.inbox = {}
    return msgs
  end
  net.update = function() end
  net.close = function(_)
    if net.closed then return end
    net.closed = true
    if self.hub then self.hub:drop(client) end
  end

  self.localClient = client
  return net
end

-- ------- the pump

function M:accept()
  while true do
    local sock = self.server:accept()
    if not sock then break end
    sock:settimeout(0)
    -- nagle off keeps a one-line message from waiting on a partner; not
    -- every platform's luasocket build accepts the option, and a hosted
    -- game must not fail to accept a player over a tuning hint
    pcall(function() sock:setoption("tcp-nodelay", true) end)

    local conn = { sock = sock, rx = "", tx = "", dead = false, closing = false }
    conn.peer = newPeer(conn)
    -- Hub refuses over the cap: it queues the reason on the peer and marks
    -- it closing, so the connection still gets flushed and reaped below
    conn.client = self.hub:accept(conn.peer)
    self.conns[#self.conns + 1] = conn
  end
end

local function drainLines(self, conn)
  local Json = json()
  while true do
    local nl = conn.rx:find("\n", 1, true)
    if not nl then break end
    local line = conn.rx:sub(1, nl - 1)
    conn.rx = conn.rx:sub(nl + 1)
    if #line > 0 and conn.client then
      local msg = Json.decode(line)
      -- a line that will not decode is dropped, not fatal: one bad frame
      -- from one peer must not take the game down for everyone
      if msg then
        -- and neither must one that decodes but then misbehaves: the
        -- blast radius of anything this peer sends is this peer
        local ok, err = pcall(self.hub.receive, self.hub, conn.client, msg)
        if not ok then
          mod.log:warn("dropping a connection whose message failed (%s)",
            tostring(err))
          conn.dead = true
          return
        end
      end
    end
  end
end

function M:flush()
  for _, conn in ipairs(self.conns) do
    if not conn.dead and #conn.tx > 0 then
      local ok, sent, err, lastByte = pcall(function()
        return conn.sock:send(conn.tx)
      end)
      if not ok then
        conn.dead = true
      elseif sent then
        conn.tx = ""
      elseif err == "timeout" then
        conn.tx = conn.tx:sub((lastByte or 0) + 1)
      else
        conn.dead = true
      end
    end
  end
end

function M:read(conn)
  while true do
    local ok, data, err, partial = pcall(function()
      return conn.sock:receive(8192)
    end)
    if not ok then
      conn.dead = true
      return
    end
    local chunk = data or partial or ""
    if #chunk > 0 then conn.rx = conn.rx .. chunk end
    if err == "closed" then
      conn.dead = true
      return
    elseif err and err ~= "timeout" then
      conn.dead = true
      return
    end
    -- guard against one peer monopolising the tick with a flood
    if #conn.rx > 64 * 1024 then
      conn.dead = true
      return
    end
    if not data then break end
  end
  drainLines(self, conn)
end

function M:update(dt)
  if not self.running then return end

  local ok, err = pcall(function()
    self.hub:update(dt)
    self:accept()
    for _, conn in ipairs(self.conns) do
      if not conn.dead then self:read(conn) end
    end
    self:flush()

    -- reap: a peer that errored, or one we refused and have now told why
    for i = #self.conns, 1, -1 do
      local conn = self.conns[i]
      if conn.dead or (conn.closing and #conn.tx == 0) then
        if conn.client then self.hub:drop(conn.client) end
        pcall(function() conn.sock:close() end)
        table.remove(self.conns, i)
      end
    end
  end)

  if not ok then
    mod.log:error("the hosted game hit an error (%s); it has been stopped so "
      .. "the game keeps running -- start it again from START > MMO",
      tostring(err))
    pcall(function() self:stop("The host hit an error.") end)
  end
end

return M
