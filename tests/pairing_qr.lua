-- Focused tests for the LAN QR bootstrap modules.
-- Run from a Gen1Recomp checkout with this mod under mods/rby_mmo, or directly
-- from this checkout with: lua tests/pairing_qr.lua

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local modRoot = source:match("^(.*)[/\\]tests[/\\][^/\\]+$") or "."
local cache = {}
local mod = {}
local function need(name)
  if cache[name] ~= nil then return cache[name] end
  local chunk = assert(loadfile(modRoot .. "/src/" .. name .. ".lua"))
  local value = chunk(need, mod)
  cache[name] = value == nil and true or value
  return cache[name]
end

local Pairing = need("Pairing")
local Qr = need("Qr")
local function check(condition, message)
  assert(condition, message)
end

local at = 1700000000
for _, address in ipairs({
  "10.0.0.1", "172.16.0.1", "172.31.255.254", "192.168.1.1",
}) do
  local payload, err = Pairing.new(address, 7788, "A7K3P9", at)
  check(payload ~= nil, address .. ": " .. tostring(err))
end
for _, address in ipairs({
  "9.0.0.1", "172.15.0.1", "172.32.0.1", "192.167.1.1",
  "010.0.0.1", "192.168.001.1", "192.168.1.999",
}) do
  check(Pairing.new(address, 7788, "A7K3P9", at) == nil,
    "public or non-canonical address accepted: " .. address)
end

local payload = assert(Pairing.new("192.168.1.217", 7788, "A7K3P9", at))
local encoded = assert(Pairing.encode(payload))
local decoded = assert(Pairing.decode(encoded, at))
check(decoded.address == payload.address and decoded.port == payload.port,
  "pairing round trip lost address or port")
check(decoded.code == payload.code and decoded.expires == payload.expires,
  "pairing round trip lost code or expiry")
check(Pairing.decode(encoded, at + Pairing.TTL + 1) == nil,
  "expired pairing was accepted")
check(Pairing.decode(encoded:gsub(":1:", ":2:", 1), at) == nil,
  "unsupported pairing version was accepted")

local matrix = assert(Qr.encode(encoded))
check(#matrix == 41 and #matrix[1] == 41, "unexpected QR matrix size")
for _, row in ipairs(matrix) do
  check(#row == 41, "QR rows are not square")
  for _, dark in ipairs(row) do
    check(type(dark) == "boolean", "QR matrix contains a non-boolean cell")
  end
end

print("pairing_qr: all checks passed")
