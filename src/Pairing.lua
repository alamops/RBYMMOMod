-- RBY MMO's LAN join QR payload.
--
-- This is a bootstrap convenience, not a replacement for the hub handshake:
-- the join code is carried so scanning is one step, but the client still
-- proves it with the normal mmo.challenge/mmo.auth exchange. The payload is
-- LAN-only because an address that is useful outside the local network needs
-- a different security and NAT story than this QR can provide.

local need, mod = ...
local Config = need("Config")
local Wire = need("Wire")

local M = {}
M.MAGIC = "rby-mmo"
M.VERSION = 1
M.TTL = 120

local function now()
  return os.time()
end

local function privateIPv4(value)
  local a, b, c, d = tostring(value or ""):match(
    "^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
  if not a or a > 255 or b > 255 or c > 255 or d > 255 then return false end
  return a == 10 or (a == 172 and b >= 16 and b <= 31)
    or (a == 192 and b == 168)
end

local function nonce()
  local random = love and love.math and love.math.random
  if random then
    return ("%08x%08x"):format(random(0, 0x7fffffff),
                                  random(0, 0x7fffffff))
  end
  local stamp = now()
  return ("%08x%08x"):format(stamp % 0x100000000,
                                math.floor((stamp * 1103515245) % 0x100000000))
end

local function validPort(value)
  local port = tonumber(value)
  if not port or port ~= math.floor(port) or port < 1 or port > 65535 then
    return nil
  end
  return port
end

function M.new(address, port, code, at)
  if not privateIPv4(address) then return nil, "host has no LAN address" end
  port = validPort(port)
  code = Wire.code(code)
  if not port then return nil, "invalid host port" end
  if not code then return nil, "host has no usable join code" end
  at = tonumber(at) or now()
  return {
    magic = M.MAGIC, version = M.VERSION, address = address, port = port,
    code = code, expires = at + M.TTL, nonce = nonce(),
  }
end

function M.encode(value)
  if type(value) ~= "table" then return nil, "invalid pairing" end
  return ("%s:%d:%s:%d:%d:%s:%s"):format(
    M.MAGIC, tonumber(value.version) or 0, value.address, value.port,
    value.expires, value.code, value.nonce)
end

function M.decode(text, at)
  if type(text) ~= "string" or #text > 256 then
    return nil, "malformed join QR"
  end
  local version, address, port, expires, code, pairNonce = text:match(
    "^rby%-mmo:(%d+):([%d%.]+):(%d+):(%d+):([%w]+):([%w]+)$")
  if not version then return nil, "not an RBY MMO QR" end
  if tonumber(version) ~= M.VERSION then return nil, "unsupported join QR" end
  if not privateIPv4(address) then return nil, "QR address is not LAN-safe" end
  port = validPort(port)
  if not port then return nil, "invalid QR port" end
  code = Wire.code(code)
  if not code then return nil, "QR has no usable join code" end
  expires = tonumber(expires)
  if not expires or expires < (tonumber(at) or now()) then
    return nil, "join QR expired"
  end
  if #pairNonce < 8 or #pairNonce > 64 then
    return nil, "invalid join QR nonce"
  end
  return { magic = M.MAGIC, version = M.VERSION, address = address,
           port = port, code = code, expires = expires, nonce = pairNonce }
end

return M
