-- Dependency-free QR Model 2 encoder for the RBY MMO host screen.
-- Kept inside the mod so host QR generation does not depend on the optional
-- native camera bridge; guests still use that bridge for scanning.

local M = {}

local function bxor(a, b)
  local out, bit = 0, 1
  while a > 0 or b > 0 do
    if (a % 2) ~= (b % 2) then out = out + bit end
    a, b, bit = math.floor(a / 2), math.floor(b / 2), bit * 2
  end
  return out
end

-- QR Code Model 2, byte mode, version 6, error correction L.  This is kept
-- dependency-free so desktop, iOS, Android, and handheld builds share it.
local EXP, LOG = {}, {}
do
  local x = 1
  for i = 0, 254 do EXP[i] = x; LOG[x] = i; x = x * 2; if x >= 256 then x = bxor(x, 0x11d) end end
  for i = 255, 511 do EXP[i] = EXP[i - 255] end
end

local function gfMul(a, b)
  return (a == 0 or b == 0) and 0 or EXP[LOG[a] + LOG[b]]
end

local function ecCodewords(data, count)
  local gen = { 1 }
  for i = 1, count do
    local nextGen = {}
    for j = 1, #gen + 1 do nextGen[j] = 0 end
    for j, v in ipairs(gen) do
      nextGen[j] = bxor(nextGen[j], v)
      nextGen[j + 1] = bxor(nextGen[j + 1], gfMul(v, EXP[i - 1]))
    end
    gen = nextGen
  end
  local rem = {}
  for i = 1, count do rem[i] = 0 end
  for _, byte in ipairs(data) do
    local factor = bxor(byte, rem[1])
    table.remove(rem, 1); rem[#rem + 1] = 0
    for j = 1, count do rem[j] = bxor(rem[j], gfMul(gen[j + 1], factor)) end
  end
  return rem
end

local function dataCodewords(payload)
  local bits = {}
  local function put(value, count)
    for i = count - 1, 0, -1 do bits[#bits + 1] = math.floor(value / 2 ^ i) % 2 end
  end
  put(4, 4); put(#payload, 8)
  for i = 1, #payload do put(payload:byte(i), 8) end
  local dataCount = 136
  if #bits > dataCount * 8 then return nil, "pairing QR payload is too long" end
  local terminator = math.min(4, dataCount * 8 - #bits)
  for _ = 1, terminator do bits[#bits + 1] = 0 end
  local remaining = dataCount * 8 - #bits
  local padBits = remaining > 0 and math.min(8 - (#bits % 8), remaining) or 0
  for _ = 1, padBits do bits[#bits + 1] = 0 end
  local bytes = {}
  for i = 1, #bits, 8 do
    local n = 0; for j = 0, 7 do n = n * 2 + bits[i + j] end
    bytes[#bytes + 1] = n
  end
  local pads = { 0xec, 0x11 }
  local i = 1
  while #bytes < dataCount do bytes[#bytes + 1] = pads[i]; i = 3 - i end
  return bytes
end

local function finalCodewords(data)
  -- Version 6-L is two data blocks of 68 codewords, with 18 EC codewords
  -- generated per block. QR readers expect the data blocks and then the EC
  -- blocks to be interleaved; treating the full 136 bytes as one Reed-Solomon
  -- block makes a matrix that looks like QR geometry but decodes empty.
  local blockCount, dataPerBlock, ecPerBlock = 2, 68, 18
  local blocks, ecs = {}, {}
  for block = 1, blockCount do
    local start = (block - 1) * dataPerBlock + 1
    blocks[block] = {}
    for i = 0, dataPerBlock - 1 do blocks[block][i + 1] = data[start + i] end
    ecs[block] = ecCodewords(blocks[block], ecPerBlock)
  end

  local out = {}
  for i = 1, dataPerBlock do
    for block = 1, blockCount do out[#out + 1] = blocks[block][i] end
  end
  for i = 1, ecPerBlock do
    for block = 1, blockCount do out[#out + 1] = ecs[block][i] end
  end
  return out
end

local function bch(value, poly)
  local degree = 0; local p = poly
  while p > 0 do degree = degree + 1; p = math.floor(p / 2) end
  local v = value * 2 ^ (degree - 1)
  while true do
    local shift = 0; p = v
    while p >= poly do p = math.floor(p / 2); shift = shift + 1 end
    if shift == 0 then return v end
    v = bxor(v, poly * 2 ^ shift)
  end
end

function M.encode(text)
  local data, err = dataCodewords(text)
  if not data then return nil, err end
  local bytes = finalCodewords(data)
  local size, m = 41, {}
  for y = 1, size do m[y] = {}; for x = 1, size do m[y][x] = nil end end
  local function set(x, y, value) if x >= 1 and x <= size and y >= 1 and y <= size then m[y][x] = value and true or false end end
  local function set0(x, y, value) set(x + 1, y + 1, value) end
  local function finder(x0, y0)
    for dy = -1, 7 do for dx = -1, 7 do
      local dark = dx >= 0 and dx <= 6 and dy >= 0 and dy <= 6
        and (dx == 0 or dx == 6 or dy == 0 or dy == 6 or (dx >= 2 and dx <= 4 and dy >= 2 and dy <= 4))
      set(x0 + dx, y0 + dy, dark)
    end end
  end
  finder(1, 1); finder(size - 6, 1); finder(1, size - 6)
  for _, p in ipairs({ 6, 34 }) do for _, q in ipairs({ 6, 34 }) do
    if not m[q + 1][p + 1] then
      for dy = -2, 2 do for dx = -2, 2 do set(p + dx + 1, q + dy + 1, math.max(math.abs(dx), math.abs(dy)) ~= 1) end end
    end
  end end
  for i = 9, size - 8 do if m[7][i] == nil then set(i, 7, i % 2 == 1) end; if m[i][7] == nil then set(7, i, i % 2 == 1) end end
  set0(8, size - 8, true)
  -- Format bits: error-correction L (`01`) and mask 0 (`000`).
  local formatData = 0x08
  local format = bxor(formatData * 2 ^ 10 + bch(formatData, 0x537), 0x5412)
  for i = 0, 14 do
    local bit = math.floor(format / 2 ^ i) % 2 == 1
    if i <= 5 then
      set0(8, i, bit)
    elseif i == 6 then
      set0(8, 7, bit)
    elseif i == 7 then
      set0(8, 8, bit)
    elseif i == 8 then
      set0(7, 8, bit)
    else
      set0(14 - i, 8, bit)
    end

    if i <= 7 then
      set0(size - 1 - i, 8, bit)
    else
      set0(8, size - 15 + i, bit)
    end
  end
  local dataBits = {}; for _, byte in ipairs(bytes) do for i = 7, 0, -1 do dataBits[#dataBits + 1] = math.floor(byte / 2 ^ i) % 2 end end
  local bitIndex = 1
  for right = size - 1, 1, -2 do -- 0-based column index for the right column of the pair
    local r = right
    if r <= 6 then r = r - 1 end -- skip the vertical timing column
    for vertical = 0, size - 1 do
      for z = 0, 1 do
        local j = r - z
        local upward = math.floor(r / 2) % 2 == 0
        if j < 6 then upward = not upward end
        local i = upward and (size - 1 - vertical) or vertical
        local x, y = j + 1, i + 1
        if m[y][x] == nil then
          local bit = dataBits[bitIndex] or 0; bitIndex = bitIndex + 1
          if ((x + y) % 2 == 0) then bit = 1 - bit end -- mask 0, equivalent to 0-based (j+i)%2
          m[y][x] = bit == 1
        end
      end
    end
  end
  return m
end


return M
