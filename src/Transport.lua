-- The hub connection.
--
-- This is the one place the mod touches the wire, and it does so through
-- src/link/Net.lua rather than opening its own socket.  Net's relay backend
-- is already a newline-delimited JSON framer over luasocket TCP with a
-- non-blocking pump, which is exactly the transport this needs, and
-- src.link.* is the module family the loader's permission model governs
-- with `network` -- the permission this mod declares.  Reimplementing the
-- framing would mean reimplementing its partial-line handling too.
--
-- What is NOT reused is Net's pairing state machine.  That machine is 1v1
-- by construction: the relay answers a third participant with
-- join_error/full, and the ENet backend disconnects a second peer outright.
-- A shared overworld needs N players, so this mod ships its own hub and
-- speaks its own "mmo."-prefixed vocabulary over Net's framing.

local need, mod = ...
local Config = need("Config")
local Wire = need("Wire")

local M = {}
M.__index = M

-- Deferred so a headless load (modkit validate) never pays for the link
-- stack, and so a build without luasocket degrades to "cannot connect"
-- instead of failing to load the mod at all.
local netModule, netTried

local function linkNet()
  if netTried then return netModule end
  netTried = true
  local ok, module = pcall(require, "src.link.Net")
  if ok and type(module) == "table" then
    netModule = module
  else
    mod.log:error("the engine's link transport is unavailable (%s) -- "
      .. "multiplayer needs a build of the game that ships src/link/",
      tostring(module))
  end
  return netModule
end

function M.new()
  return setmetatable({
    net = nil,
    state = "idle", -- idle | connecting | ready | closed
    error = nil,
    lastPing = 0,
    lastHeard = 0,
    clock = 0,
  }, M)
end

-- Attach an already-built transport instead of dialling one.
--
-- Any table answering send/poll/update/close with a .closed field stands in
-- for the real Net. Two callers use it: the suite, which drives the
-- protocol with a fake and no socket, and -- more importantly -- a player
-- hosting, whose own client attaches HostServer:localNet() and reaches the
-- hub in-process. That is why the host runs the same client code as
-- everyone else rather than a special case: from here down, hosting and
-- joining are indistinguishable.
function M:attach(net)
  self.net = net
  self.state = "connecting"
  self.error = nil
  self.clock, self.lastHeard, self.lastPing = 0, 0, 0
  return true
end

function M:connect(address)
  local Net = linkNet()
  if not Net then
    self.error = "link transport unavailable"
    self.state = "closed"
    return false, self.error
  end

  local net = Net.new()
  local ok = net:connectTCP(address or Config.DEFAULT_HUB)
  if not ok then
    -- Net puts a player-facing sentence in .error; keep it, it already
    -- names the address that failed
    self.error = net.error or ("could not reach " .. tostring(address))
    self.state = "closed"
    return false, self.error
  end

  self.net = net
  self.state = "connecting"
  self.error = nil
  self.clock, self.lastHeard, self.lastPing = 0, 0, 0
  return true
end

function M:isOpen()
  return self.net ~= nil and not self.net.closed
    and (self.state == "connecting" or self.state == "ready")
end

function M:isReady()
  return self.state == "ready" and self:isOpen()
end

function M:send(msgType, payload)
  if not self:isOpen() then return false end
  local msg = {}
  if type(payload) == "table" then
    for k, v in pairs(payload) do msg[k] = v end
  end
  msg.type = msgType
  self.net:send(msg)
  return true
end

function M:fail(reason)
  self.error = reason
  self.state = "closed"
  if self.net then
    pcall(function() self.net:close() end)
  end
end

-- Pumps the socket and hands back this tick's messages, already sanitised.
-- Anything that fails sanitisation is dropped here with a log line rather
-- than being passed on half-formed.
function M:update(dt)
  if not self:isOpen() then return {} end
  self.clock = self.clock + (dt or 0)

  local ok, err = pcall(function() self.net:update() end)
  if not ok then
    self:fail("connection error: " .. tostring(err))
    return {}
  end

  if self.net.error and self.state ~= "closed" then
    self:fail(tostring(self.net.error))
    return {}
  end

  local raw = self.net:poll()
  local out = {}
  for _, msg in ipairs(raw or {}) do
    if type(msg) == "table" and type(msg.type) == "string" then
      self.lastHeard = self.clock
      if msg.type == Wire.PONG then
        -- liveness only; nothing downstream cares
      else
        out[#out + 1] = msg
      end
    else
      mod.log:warn("dropped a malformed message from the hub")
    end
  end

  if self.clock - self.lastPing >= Config.PING_INTERVAL then
    self.lastPing = self.clock
    self:send(Wire.PING, {})
  end

  if self.state == "ready" and self.clock - self.lastHeard > Config.TIMEOUT then
    self:fail("the hub stopped responding -- reconnect from START > MMO")
  end

  -- The handshake's own deadline, which the ready-state timeout above cannot
  -- cover: it measures silence since the last message, and a connection that
  -- has never been welcomed has never had one.
  --
  -- Both hubs already hold a client to this same budget from their side
  -- (src/Hub.lua's sweep and server/lib/limits.js, both Config.HANDSHAKE_TIMEOUT
  -- seconds), so this is not a new rule -- it is the rule applied by the one
  -- party that can still see the socket when the other end is not a hub of
  -- ours at all. Without it a listener that accepts and never answers -- a
  -- stale port forward, some unrelated service on 7788, a wedged third-party
  -- build -- leaves this side in `connecting` forever: no connection, no
  -- error, and nothing for a caller to report. That is invisible on a dial
  -- the player pressed, and completely silent on one they did not (see
  -- src/Client.lua's auto-join).
  --
  -- Measured from `clock`, which both connect() and attach() reset to zero,
  -- so it covers a hosting copy's own loopback attach as well as a dial.
  if self.state == "connecting" and self.clock > Config.HANDSHAKE_TIMEOUT then
    self:fail("the hub never finished connecting -- it may not be a hub, or "
      .. "may be running a different build")
  end

  if self.net.closed and self.state ~= "closed" then
    self:fail(self.error or "the hub closed the connection")
  end

  return out
end

function M:markReady()
  self.state = "ready"
  self.lastHeard = self.clock
end

function M:close()
  if self.net then
    pcall(function() self.net:close() end)
  end
  self.net = nil
  self.state = "closed"
end

return M
