-- SHA-256 and HMAC-SHA256, hand-written, because the hub's join-code
-- challenge has to be answered by code that runs in two places which do not
-- share a runtime.
--
-- love.data.hash("sha256", ...) works in game, but love.data is not stubbed
-- in the engine's tests/love_stub.lua -- the stub the mod's headless suite
-- installs -- so any path reaching for it crashes under luajit.  Stubbing it
-- would itself need a real SHA-256 to produce matching values, which
-- relocates the work rather than avoiding it.  Writing it once here means
-- the game and the suite run byte-identical code, the same reasoning
-- src/link/Fingerprint.lua gives for why that digest avoids love too.
--
-- 32-bit work goes through LuaJIT's bit library when it is present and falls
-- back to arithmetic peeling over nibble lookup tables when it is not, in
-- the style of Fingerprint.lua.  Doing both means this file loads under
-- LuaJIT in game, under LuaJIT in the suite, and under plain Lua 5.4 if
-- anything ever picks it up.  Lua 5.1 dialect throughout: no //, no ~ as an
-- operator, no << / >>, no goto.
--
-- Nothing here raises.  A bad argument returns nil plus a reason string,
-- because a bare error() on a path reachable from a mod callback is a loader
-- rule violation; the caller logs the reason and names a remediation.
--
-- The wire contract this exists to satisfy, mirrored by server/lib/auth.js:
-- the HMAC key is the normalised join code as ASCII bytes, the message is
-- the nonce as its lowercase-hex ASCII *string* (never the decoded bytes, so
-- Lua never has to hex-decode), and the output is 64 lowercase hex chars.
--
-- No love, no engine modules, no mod facade: dependency-free on purpose.

local need = ...            -- entry-chunk shape; this module resolves nothing

local M = {}

local floor = math.floor
local char, byte = string.char, string.byte
local format, rep = string.format, string.rep

local TWO32 = 4294967296

local POW2 = {}
for i = 0, 32 do POW2[i] = 2 ^ i end

-- ------- 32-bit primitives

-- Every operator below takes and returns an *unsigned* value in [0, 2^32),
-- so the two backends are drop-in interchangeable and the compression loop
-- never has to know which one it got.  bit.* hands back signed 32-bit
-- numbers, which is what the trailing % TWO32 is normalising away.
local band, bor, bxor, bnot, rshift, rotr

local hasBit, bitlib = pcall(require, "bit")

if hasBit and type(bitlib) == "table" and type(bitlib.bxor) == "function" then
  local _band, _bor, _bxor = bitlib.band, bitlib.bor, bitlib.bxor
  local _bnot, _rshift, _ror = bitlib.bnot, bitlib.rshift, bitlib.ror

  band = function(a, b) return _band(a, b) % TWO32 end
  bor = function(a, b) return _bor(a, b) % TWO32 end
  bxor = function(a, b) return _bxor(a, b) % TWO32 end
  bnot = function(a) return _bnot(a) % TWO32 end
  rshift = function(a, n) return _rshift(a, n) % TWO32 end
  rotr = function(a, n) return _ror(a, n) % TWO32 end
else
  -- 4-bit tables rather than peeling one bit at a time: 256 entries per
  -- operator is built once at load, and it turns a 32-bit logical op into
  -- eight table lookups instead of thirty-two divisions.
  local AND4, OR4, XOR4 = {}, {}, {}
  for a = 0, 15 do
    AND4[a], OR4[a], XOR4[a] = {}, {}, {}
    for b = 0, 15 do
      local x, y = a, b
      local andBits, orBits, xorBits = 0, 0, 0
      for place = 0, 3 do
        local xb, yb = x % 2, y % 2
        local weight = POW2[place]
        if xb == 1 and yb == 1 then andBits = andBits + weight end
        if xb == 1 or yb == 1 then orBits = orBits + weight end
        if xb ~= yb then xorBits = xorBits + weight end
        x, y = floor(x / 2), floor(y / 2)
      end
      AND4[a][b], OR4[a][b], XOR4[a][b] = andBits, orBits, xorBits
    end
  end

  local function nibblewise(TABLE)
    return function(a, b)
      local out, place = 0, 1
      for _ = 1, 8 do
        out = out + TABLE[a % 16][b % 16] * place
        a, b = floor(a / 16), floor(b / 16)
        place = place * 16
      end
      return out
    end
  end

  band, bor, bxor = nibblewise(AND4), nibblewise(OR4), nibblewise(XOR4)
  bnot = function(a) return 4294967295 - a end
  rshift = function(a, n) return floor(a / POW2[n]) end
  rotr = function(a, n)
    local low = a % POW2[n]
    return (a - low) / POW2[n] + low * POW2[32 - n]
  end
end

-- ------- the digest

local K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
  0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
  0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
  0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
  0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local INIT = {
  0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
  0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
}

-- FIPS 180-4 padding: one 0x80 byte, zeros up to the 56-byte mark of a
-- block, then the message length in *bits* as a 64-bit big-endian count.
-- Lua numbers here are doubles, so the high and low words are derived
-- separately -- len * 8 would lose precision long before a 64-bit integer
-- would, and this dialect has no 64-bit integer to fall back on.
local function pad(message)
  local len = #message
  local zeros = (56 - (len + 1) % 64) % 64
  local high = floor(len / 536870912)             -- len * 8 / 2^32
  local low = (len % 536870912) * 8               -- len * 8 mod 2^32
  return message .. "\128" .. rep("\0", zeros) .. char(
    floor(high / 16777216) % 256, floor(high / 65536) % 256,
    floor(high / 256) % 256, high % 256,
    floor(low / 16777216) % 256, floor(low / 65536) % 256,
    floor(low / 256) % 256, low % 256)
end

-- One schedule table, reused for every block of every call.  Allocating it
-- per block would mean a garbage 64-entry table per 64 bytes hashed; nothing
-- here reenters (Lua is single-threaded and hmacHex's two digests run one
-- after the other), so a shared buffer is safe.
local schedule = {}

local function compress(message)
  local block = pad(message)
  local total = #block
  local h1, h2, h3, h4 = INIT[1], INIT[2], INIT[3], INIT[4]
  local h5, h6, h7, h8 = INIT[5], INIT[6], INIT[7], INIT[8]
  local pos = 1

  while pos <= total do
    for i = 1, 16 do
      local b1, b2, b3, b4 = byte(block, pos, pos + 3)
      schedule[i] = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
      pos = pos + 4
    end
    for i = 17, 64 do
      local x = schedule[i - 15]
      local s0 = bxor(bxor(rotr(x, 7), rotr(x, 18)), rshift(x, 3))
      local y = schedule[i - 2]
      local s1 = bxor(bxor(rotr(y, 17), rotr(y, 19)), rshift(y, 10))
      -- four unsigned 32-bit terms sum below 2^34, still exact in a double
      schedule[i] = (schedule[i - 16] + s0 + schedule[i - 7] + s1) % TWO32
    end

    local a, b, c, d = h1, h2, h3, h4
    local e, f, g, h = h5, h6, h7, h8
    for i = 1, 64 do
      local S1 = bxor(bxor(rotr(e, 6), rotr(e, 11)), rotr(e, 25))
      local ch = bxor(band(e, f), band(bnot(e), g))
      local t1 = (h + S1 + ch + K[i] + schedule[i]) % TWO32
      local S0 = bxor(bxor(rotr(a, 2), rotr(a, 13)), rotr(a, 22))
      local maj = bxor(bxor(band(a, b), band(a, c)), band(b, c))
      local t2 = (S0 + maj) % TWO32
      h, g, f = g, f, e
      e = (d + t1) % TWO32
      d, c, b = c, b, a
      a = (t1 + t2) % TWO32
    end

    h1, h2, h3, h4 = (h1 + a) % TWO32, (h2 + b) % TWO32,
                     (h3 + c) % TWO32, (h4 + d) % TWO32
    h5, h6, h7, h8 = (h5 + e) % TWO32, (h6 + f) % TWO32,
                     (h7 + g) % TWO32, (h8 + h) % TWO32
  end

  return h1, h2, h3, h4, h5, h6, h7, h8
end

local function word(value)
  return char(floor(value / 16777216) % 256, floor(value / 65536) % 256,
              floor(value / 256) % 256, value % 256)
end

local HEX8 = rep("%08x", 8)

-- SHA-256 of an arbitrary Lua string as 64 lowercase hex characters.
-- Embedded \0 and any other byte are fine: #s is the length, never a
-- NUL-terminated read.
function M.hex(message)
  if type(message) ~= "string" then
    return nil, "sha256: message must be a string, got " .. type(message)
  end
  return format(HEX8, compress(message))
end

-- The same digest as its raw 32 bytes.  HMAC needs it in this form; it is
-- exported anyway so a caller that wants to feed one digest into another
-- does not have to hex round-trip.
function M.bytes(message)
  if type(message) ~= "string" then
    return nil, "sha256: message must be a string, got " .. type(message)
  end
  local h1, h2, h3, h4, h5, h6, h7, h8 = compress(message)
  return word(h1) .. word(h2) .. word(h3) .. word(h4)
      .. word(h5) .. word(h6) .. word(h7) .. word(h8)
end

local BLOCK = 64

-- HMAC-SHA256, RFC 2104: a key longer than the 64-byte block is hashed
-- first, a shorter one is zero-padded to it, and the padded key is xored
-- with 0x36 for the inner pass and 0x5c for the outer.
function M.hmacHex(key, message)
  if type(key) ~= "string" then
    return nil, "hmac: key must be a string, got " .. type(key)
  end
  if type(message) ~= "string" then
    return nil, "hmac: message must be a string, got " .. type(message)
  end

  if #key > BLOCK then key = M.bytes(key) end

  local inner, outer = {}, {}
  local keyLen = #key
  for i = 1, BLOCK do
    local k = i <= keyLen and byte(key, i) or 0
    inner[i] = char(bxor(k, 0x36))
    outer[i] = char(bxor(k, 0x5c))
  end

  local digest = M.bytes(table.concat(inner) .. message)
  return format(HEX8, compress(table.concat(outer) .. digest))
end

-- Constant-time string compare.  Neither LOVE nor Lua ships one, and a plain
-- == on a digest leaks where the first differing byte is: an attacker who can
-- time the hub's answer recovers a valid response one byte at a time.  The
-- difference is accumulated across the whole string and only tested at the
-- end.  A length mismatch does return early -- lengths are not the secret
-- here, the contents are, and both sides are fixed-width hex anyway.
function M.equals(a, b)
  if type(a) ~= "string" or type(b) ~= "string" then return false end
  local len = #a
  if len ~= #b then return false end
  local diff = 0
  for i = 1, len do
    diff = bor(diff, bxor(byte(a, i), byte(b, i)))
  end
  return diff == 0
end

return M
