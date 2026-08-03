-- The wire vocabulary, and the sanitisers every inbound field goes through.
--
-- Two rules hold everywhere below.
--
-- 1. Every message type is prefixed "mmo.".  src/link/Net.lua intercepts
--    four unprefixed control types on a relay connection -- "hosted",
--    "paired", "join_error" and "peer_gone" -- and swallows them before
--    they reach the inbox.  Staying in our own namespace means the hub can
--    never accidentally drive Net's 1v1 pairing state machine.
--
-- 2. Nothing that arrives off the network is trusted.  Every field is
--    re-derived here into a known type and range before any other module
--    sees it, because the peer on the other end is a stranger's process,
--    not our own code.  A field that fails to sanitise takes its whole
--    message with it (nil) rather than arriving half-formed.
--
-- Pure data and string handling: no love, no engine modules, so the suite
-- can drive the whole protocol headlessly.

local need = ...
local Config = need("Config")

local M = {}

-- client -> hub
M.HELLO         = "mmo.hello"
M.MOVE          = "mmo.move"
M.CHAT          = "mmo.chat"
M.REQUEST       = "mmo.request"
M.RESPOND       = "mmo.respond"
M.RELAY         = "mmo.relay"
M.SESSION_LEAVE = "mmo.session_leave"
M.PING          = "mmo.ping"
-- the answer to a challenge: { response }, an HMAC of the nonce keyed by
-- the join code.  The code itself never crosses the wire.
M.AUTH          = "mmo.auth"

-- hub -> client
M.WELCOME     = "mmo.welcome"
-- { nonce }, sent after hello and only when the hub wants a join code.  A
-- hub with no code configured never sends it, so the exchange stays exactly
-- what it was.
M.CHALLENGE   = "mmo.challenge"
M.JOIN        = "mmo.join"
M.PART        = "mmo.part"
M.DECLINE     = "mmo.decline"
M.SESSION     = "mmo.session"
M.SESSION_END = "mmo.session_end"
M.ERROR       = "mmo.error"
M.PONG        = "mmo.pong"

M.FACINGS = { up = true, down = true, left = true, right = true }
M.KINDS = { trade = true, battle = true }

local SCOPES = {}
for _, scope in ipairs(Config.CHAT_SCOPES) do SCOPES[scope] = true end
M.SCOPES = SCOPES

-- The engine's font covers upper and lower case, digits, and a short
-- punctuation set.  Anything else -- control bytes, a multi-byte sequence,
-- an emoji someone pasted -- would draw as garbage or index past the glyph
-- table, so it is dropped at the boundary rather than at draw time.
local ALLOWED = "[^A-Za-z0-9 %.,!%?'%-:;%(%)/]"

function M.text(value, limit)
  if type(value) ~= "string" then return nil end
  local clean = value:gsub(ALLOWED, "")
  clean = clean:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
  if clean == "" then return nil end
  return clean:sub(1, limit or Config.MESSAGE_MAX)
end

function M.name(value)
  return M.text(value, Config.NAME_MAX)
end

-- A sprite id is an engine identifier (SPRITE_RED), not prose.
--
-- Running one through M.text strips the underscore -- it is not a character
-- the font needs for chat -- and SPRITE_RED silently became SPRITERED,
-- which then missed the catalog lookup and drew *every* remote player as
-- the fallback sprite. The bug was invisible because the fallback works:
-- everyone just looked like RED. Identifiers get an identifier sanitiser.
function M.spriteId(value)
  if type(value) ~= "string" then return nil end
  if not value:match("^[%w_]+$") then return nil end
  return value:sub(1, 40)
end

-- an id is opaque to us; it only ever has to round-trip and index a table
function M.id(value)
  if type(value) ~= "string" then return nil end
  if not value:match("^[%w_%-]+$") then return nil end
  return value:sub(1, 40)
end

-- A nonce or a digest.  Hex is not an id, and cannot borrow M.id.
--
-- M.id caps at 40 characters and a SHA-256 response is 64, so a digest run
-- through M.id would come back truncated -- every valid answer silently
-- rejected, with a sanitiser that looked like it had done its job.  Nor can
-- it borrow M.text: the allowlist there is prose, and it drops nothing a
-- digest carries only because a digest happens to be alphanumeric.
--
-- Lowercase only.  Both ends emit lowercase hex, and the thing this feeds
-- is a byte compare, so accepting two spellings of the same value would
-- mean a correct answer that fails to match.
function M.hex(value, maxLen)
  if type(value) ~= "string" then return nil end
  if not value:match("^[0-9a-f]+$") then return nil end
  if #value > (maxLen or Config.DIGEST_HEX) then return nil end
  return value
end

local CODE_SET = {}
for i = 1, #Config.CODE_ALPHABET do
  CODE_SET[Config.CODE_ALPHABET:sub(i, i)] = true
end

-- A join code the way a player actually types or pastes one.
--
-- Normalisation is total and symmetric with normalizeCode in
-- server/lib/auth.js: upper-case first, then drop every character outside
-- the alphabet.  Spaces, lower case off a chat message, a dash someone
-- added out of habit and whatever punctuation came with it all fall away,
-- so both ends key the HMAC off the same bytes however the code was
-- entered.  Asymmetry here would lock a player out with nothing to read but
-- "wrong code".
--
-- Exactly Config.CODE_LEN symbols survive or nothing does: a short code is
-- a typo, not a shorter key.
function M.code(value)
  if type(value) ~= "string" then return nil end
  local upper = value:upper()
  local kept = {}
  for i = 1, #upper do
    local c = upper:sub(i, i)
    if CODE_SET[c] then kept[#kept + 1] = c end
  end
  local code = table.concat(kept)
  if #code ~= Config.CODE_LEN then return nil end
  return code
end

-- The display form of a normalised code.
--
-- At six characters there is nothing to group -- A7K3P9 is already the way
-- it is read out -- so this is a passthrough.  It is kept rather than
-- deleted because the screens and the e2e drivers call it, and because it
-- is still the one place that decides how a code is shown: if a display
-- form ever comes back, it comes back here and every caller follows.
function M.formatCode(normalized)
  if type(normalized) ~= "string" then return nil end
  return normalized
end

function M.int(value, min, max)
  local n = tonumber(value)
  if type(n) ~= "number" or n ~= n or n == math.huge or n == -math.huge then
    return nil
  end
  n = math.floor(n)
  if min and n < min then return nil end
  if max and n > max then return nil end
  return n
end

function M.facing(value)
  if M.FACINGS[value] then return value end
  return nil
end

-- A map id reaches Data.maps as a table key, so it is held to the same
-- shape the engine's own ids use.  An unknown-but-well-formed id is fine:
-- the avatar layer simply never places it, which is what a modded map the
-- local player does not have should do.
function M.mapId(value)
  if type(value) ~= "string" then return nil end
  if not value:match("^[%w_%.%-]+$") then return nil end
  return value:sub(1, 64)
end

-- Is this relay payload a shape we are willing to pass on?
--
-- The hub never reads a relay payload -- it is the engine's link vocabulary
-- -- so depth and size are the only things it can judge. They are worth
-- judging: src/link/Json.lua decodes inside a pcall and so tolerates very
-- deep input, but *re-encoding* that same value on the way out throws
-- around 6000 levels, and that throw reaches the host's error handler and
-- stops the game for everybody. A ~12KB line from one player could end
-- everyone else's session.
--
-- Rejects rather than trims: a silently truncated trade payload is worse
-- than a dropped message.
--
-- Walks with an explicit stack, never recursion -- a recursive validator
-- would blow the very stack it exists to protect.
function M.payloadOk(value, maxDepth, maxNodes)
  if type(value) ~= "table" then return false end
  maxDepth = maxDepth or Config.PAYLOAD_MAX_DEPTH
  maxNodes = maxNodes or Config.PAYLOAD_MAX_NODES

  local stack, top, nodes = { { value, 1 } }, 1, 0
  while top > 0 do
    local entry = stack[top]
    stack[top] = nil
    top = top - 1
    local node, depth = entry[1], entry[2]
    if depth > maxDepth then return false end
    for _, v in pairs(node) do
      nodes = nodes + 1
      if nodes > maxNodes then return false end
      if type(v) == "table" then
        top = top + 1
        stack[top] = { v, depth + 1 }
      end
    end
  end
  return true
end

-- The trainer-card fields a player shows other players.
--
-- Every one is re-derived like anything else off the wire: these are drawn
-- straight onto a card, so a hostile client could otherwise put arbitrary
-- text or a wild number in front of somebody. Missing is fine -- a peer on
-- an older build simply has no card to show, which the profile screen says
-- plainly rather than rendering zeros as though they were real.
function M.profile(raw)
  if type(raw) ~= "table" then return nil end
  -- money is deliberately absent: the card never shows it, so a peer that
  -- sends one is simply ignored rather than having it stored and forwarded
  return {
    idNo = M.int(raw.idNo, 0, 65535),
    badges = M.int(raw.badges, 0, 99),
    seen = M.int(raw.seen, 0, 9999),
    owned = M.int(raw.owned, 0, 9999),
    playtime = M.int(raw.playtime, 0, 999 * 3600),
  }
end

-- Presence as it appears in a welcome roster, a join, or a move.  Position
-- is optional so a player sitting in a menu or a battle can still be listed
-- without claiming a cell in the world.
function M.presence(raw)
  if type(raw) ~= "table" then return nil end
  local id = M.id(raw.id)
  local name = M.name(raw.name)
  if not id or not name then return nil end
  local out = {
    id = id,
    name = name,
    sprite = M.spriteId(raw.sprite) or Config.DEFAULT_SPRITE,
    map = M.mapId(raw.map),
    x = M.int(raw.x, 0, 4096),
    y = M.int(raw.y, 0, 4096),
    facing = M.facing(raw.facing) or "down",
    busy = raw.busy and true or false,
    profile = M.profile(raw.profile),
  }
  if not (out.map and out.x and out.y) then
    out.map, out.x, out.y = nil, nil, nil
  end
  return out
end

return M
