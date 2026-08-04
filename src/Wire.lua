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
-- Parties.  PARTY_INVITE travels both ways, the way REQUEST does: the field
-- set says which direction it is going (`to` outbound, `from` inbound), and
-- one name for one idea is easier to follow across two hub implementations
-- than a matched pair that has to be kept in step.
M.PARTY_INVITE  = "mmo.party_invite"
M.PARTY_RESPOND = "mmo.party_respond"
M.PARTY_LEAVE   = "mmo.party_leave"
-- the answer to a challenge: { response }, an HMAC of the nonce keyed by
-- the join code.  The code itself never crosses the wire.
M.AUTH          = "mmo.auth"
-- How a link battle ended, as the side sending it saw it: { session,
-- outcome }.  One of these on its own scores nothing -- the hub waits for
-- both players to say the same thing before any rating moves -- so a client
-- cannot report itself a winner.
M.RESULT        = "mmo.result"
-- "send me the leaderboard": no fields.  A request rather than a push,
-- because the board changes for everybody on every match and nobody is
-- looking at it most of the time.
M.RANKS         = "mmo.ranks"

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
-- The party you are now in, with everyone in it.  Sent whole rather than as
-- a join delta: at two members the whole thing *is* the delta, and a client
-- that rebuilds its list from one authoritative message can never end up
-- holding a member the hub has already forgotten.
M.PARTY         = "mmo.party"
M.PARTY_END     = "mmo.party_end"
M.PARTY_DECLINE = "mmo.party_decline"
-- One player's rating changed: { id, points }.  Broadcast to everybody
-- including the player it is about, so a roster row, a trainer card and
-- your own MMO menu all move at the same moment.
M.RANK        = "mmo.rank"
-- The answer to mmo.ranks: { entries = { { name, sprite, points } } },
-- already sorted and already cut to the top ten by the hub -- the client
-- draws what it is given rather than deciding who is on the board.
M.RANKING     = "mmo.ranking"

M.FACINGS = { up = true, down = true, left = true, right = true }
M.KINDS = { trade = true, battle = true }
-- What a client may claim about a battle it just finished.  "draw" is a real
-- answer and not a refusal to answer: a dropped link, a mutual run and a
-- desync all end that way, and all three score nothing.
M.OUTCOMES = { win = true, loss = true, draw = true }

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

-- The secret that says a trainer name is yours on this hub.  Hex like a
-- nonce, and held to exactly the length the hub mints: a short "token" is a
-- truncated one, which would fail every check with nothing to read.
function M.token(value)
  local hex = M.hex(value, Config.RANK_TOKEN_HEX)
  if hex and #hex == Config.RANK_TOKEN_HEX then return hex end
  return nil
end

function M.outcome(value)
  if M.OUTCOMES[value] then return value end
  return nil
end

-- A rating, as it arrives from a hub.
--
-- Bounded rather than trusted even though the hub is the one that computes
-- it: the hub is another process, a modified one is a normal thing to meet,
-- and this number is drawn straight onto a trainer card. Out of range is
-- zero rather than nil -- a card row that says 0 is honest about a hub whose
-- answer we would not believe, whereas a missing row reads as "this build
-- has no ranking" and sends the player looking for a mod update.
function M.points(value)
  return M.int(value, 0, Config.RANK_MAX) or 0
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

-- One row of a party's members list: who they are, and nothing else.
--
-- Deliberately not a presence.  Where a member is standing changes several
-- times a second and already arrives as mmo.move, so carrying a stale copy
-- of it here would give the members screen a second, slower answer to a
-- question the roster already answers -- and the two would visibly
-- disagree.  Identity is the part that does not move.
function M.member(raw)
  if type(raw) ~= "table" then return nil end
  local id = M.id(raw.id)
  local name = M.name(raw.name)
  if not (id and name) then return nil end
  return { id = id, name = name }
end

-- The members of a party, in the order the hub listed them.  A list with a
-- bad row in it is refused whole rather than delivered short: a party you
-- are told has one member when it has two is worse than one you are told
-- nothing about, because the screens would draw the wrong thing confidently.
function M.members(raw)
  if type(raw) ~= "table" then return nil end
  local out = {}
  for _, entry in ipairs(raw) do
    local member = M.member(entry)
    if not member then return nil end
    if #out >= Config.PARTY_MAX then return nil end
    out[#out + 1] = member
  end
  if #out == 0 then return nil end
  return out
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
    -- Whether they are already in *a* party, never which one.  It is the
    -- only thing anyone outside that party needs -- it decides whether the
    -- INVITE row is offered -- and a party id on every presence would let
    -- any client in the game map out who is travelling with whom.
    party = raw.party and true or false,
    -- Whether their last step was taken at the fast pace -- sprinting on
    -- foot or riding the bike, which cost the same 8 frames a tile and so
    -- need no telling apart here.  Client truth, and the only kind
    -- available: nothing the hub can see says whether a player is holding B
    -- or sitting on a bike, so this is taken on the sender's word the same
    -- way `party` is -- the worst a liar buys is an avatar that walks at the
    -- wrong speed.
    --
    -- Strict rather than truthy, unlike the flags above it: this one value
    -- is re-derived by both hubs from the same wire bytes, and `raw.fast`
    -- reaching Lua as 0 or "" would be true here and false in JS.  Comparing
    -- against true is the one test both languages answer identically.
    fast = raw.fast == true,
    profile = M.profile(raw.profile),
    -- Ranked points ride with presence rather than with the trainer card,
    -- because they are not a snapshot of who somebody was when they joined:
    -- they move mid-session, and a card built from a stale hello would show
    -- a rating the player has already changed.
    points = M.points(raw.points),
  }
  if not (out.map and out.x and out.y) then
    out.map, out.x, out.y = nil, nil, nil
  end
  return out
end

-- A leaderboard, as the hub sent it.
--
-- Rows that will not sanitise are dropped rather than repaired: a nameless
-- row is not a player, and inventing "?" for one would put a ghost between
-- two real trainers. The order is the hub's -- it is the thing that knows
-- every rating, including the players who are offline -- but the *length* is
-- ours, because a hub that answered with ten thousand rows would otherwise
-- be a hub that decides how much memory this screen uses.
function M.ranking(raw)
  local out = {}
  if type(raw) ~= "table" then return out end
  for _, row in ipairs(raw) do
    if type(row) == "table" then
      local name = M.name(row.name)
      if name then
        out[#out + 1] = {
          name = name,
          sprite = M.spriteId(row.sprite) or Config.DEFAULT_SPRITE,
          points = M.points(row.points),
        }
      end
    end
    if #out >= Config.RANK_TOP then break end
  end
  return out
end

return M
