-- Shared constants.  Anything two modules both need lives here, so the
-- resolver in main.lua never has to break a cycle.

local M = {}

M.MOD_ID = "rby_mmo"

-- Bumped when a wire change is not backward compatible.  The hub refuses a
-- client whose PROTOCOL differs, with a message naming both versions --
-- silently talking a different dialect is the worst failure mode here.
M.PROTOCOL = 2

M.DEFAULT_HUB = "127.0.0.1:7788"
M.DEFAULT_PORT = 7788

-- The player cap the host picks when starting a game.
--
-- 2 is the floor because a one-player multiplayer session is not a thing.
-- 64 is the ceiling, and it is enforced in three places on purpose: the
-- option row clamps what can be typed, Hub clamps what it is constructed
-- with, and hub.js clamps its env var. A limit that only the UI enforced
-- would be no limit at all against a modified client.
--
-- The host occupies a slot, so MAX_PLAYERS = 4 is the host plus three
-- friends.
M.MIN_PLAYERS = 2
M.MAX_PLAYERS = 64
M.DEFAULT_PLAYERS = 4

function M.clampPlayers(value)
  local n = tonumber(value)
  if not n or n ~= n then return M.DEFAULT_PLAYERS end
  n = math.floor(n)
  if n < M.MIN_PLAYERS then return M.MIN_PLAYERS end
  if n > M.MAX_PLAYERS then return M.MAX_PLAYERS end
  return n
end

-- How often presence is pushed while moving.  The overworld steps on a
-- fixed tick, and a tile takes 16 frames, so ~8 updates a second is two per
-- tile at walking pace: enough for remote avatars to look continuous
-- without turning every step into four packets.
M.PRESENCE_INTERVAL = 0.125

-- A remote avatar more than this many tiles from where the network says it
-- should be has lost the thread (packet loss, a warp we never saw, a long
-- stall).  Walking it back one tile at a time would take longer than the
-- drift lasts, so it is despawned and respawned at the true cell instead.
M.RESYNC_DISTANCE = 6

-- Chat
M.CHAT_SCOPES = { "global", "local", "private" }
M.LOCAL_RADIUS = 12          -- tiles, and same map
M.CHAT_HISTORY = 64          -- lines kept for the chat screen
M.BUBBLE_SECONDS = 5         -- how long a bubble floats over a head
M.MESSAGE_MAX = 60           -- longest message accepted off the wire
-- What the naming grid will let you type.  Shorter than MESSAGE_MAX on
-- purpose: the grid shows the line being typed on one 20-tile row, and a
-- bubble that overflows its box is worse than a message you have to split.
M.COMPOSE_MAX = 16

-- Presence liveness.  The hub drops a client that stops pinging; the client
-- gives up on a hub that stops answering.
M.PING_INTERVAL = 10
M.TIMEOUT = 30

-- Connections that have not said hello yet.
--
-- A peer gets a slot the moment its socket lands, before it has identified
-- itself. Counting those against the host's player cap let four idle TCP
-- connections lock everyone out of a 4-player game, so un-greeted peers get
-- their own, larger allowance and a deadline to introduce themselves.
M.MAX_PENDING = 8
-- **Ten seconds for the whole handshake, measured from when the connection
-- landed** -- hello, and on a coded hub the challenge and its answer too.
-- Not ten for hello plus another ten for the answer: server/lib/limits.js
-- anchors one 10s budget at register and never extends it for the challenge
-- leg, and the same client dialling the two hosting paths must not get two
-- different deadlines.  Ten is generous for the work involved -- a real
-- client sends hello the instant its socket opens and answers a challenge
-- with one HMAC over 32 bytes, which is milliseconds -- and a client that
-- has to stop and ask its player to type a code hangs up first rather than
-- holding the socket open (src/Client.lua's mmo.challenge handler), so
-- nothing legitimate is racing this.
M.HANDSHAKE_TIMEOUT = 10

-- Join codes.  Kept in lockstep with server/lib/auth.js -- both ends derive
-- the HMAC key from the same normalised bytes, so a drift here locks
-- players out with no error to read.
--
-- Crockford-style: I, L, O and U are gone, so nothing is mistyped off a
-- screenshot (1/I, 0/O) and no code spells anything.  The deeper reason the
-- alphabet is this and not base32 or hex is that every character here is on
-- the mod's own naming grid (src/Ui.lua:51-64), on both pages -- a code has
-- to be typeable with a d-pad, without a page flip.
M.CODE_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
M.CODE_LEN = 6              -- 6 symbols of 5 bits = 30 bits of secret
-- 30 bits is the whole of it, and it is a chosen trade: six characters, no
-- dashes (A7K3P9), is what a host can read out over voice once and a guest
-- can type on a d-pad without giving up.  Be honest about what that buys.
-- Online it is not the weak link: the hub rate limits connects (60 a minute
-- by default, server/lib/limits.js), so walking 2^30 codes past it takes
-- decades.  Offline it is: nothing here is under TLS, so anyone who can
-- capture one challenge and the response to it can grind the same 2^30
-- against that pair at their own speed, where no limit reaches them, and
-- recover the code.  A code is a door lock on a session, not a secret.
--
-- What the naming grid will let you type for a code: six characters plus
-- slop, because a player pasting from a chat message may bring spare
-- punctuation or spaces that normalisation drops anyway.
M.CODE_ENTRY_MAX = 12

-- The challenge nonce is 16 random bytes, lowercase hex on the wire...
M.NONCE_HEX = 32
-- ...and the answer is an HMAC-SHA256 digest, likewise lowercase hex.
M.DIGEST_HEX = 64

-- Relay payloads are forwarded unread, so their *shape* is all that can be
-- checked. A packed party is five or six levels deep; these leave enormous
-- headroom while refusing the nesting that breaks the encoder.
M.PAYLOAD_MAX_DEPTH = 32
M.PAYLOAD_MAX_NODES = 4096

-- Smallest gap between two chat messages from one player.  Not moderation
-- -- just enough that nobody can fill everyone else's scrollback faster
-- than it can be read.  Mirrors the 500ms gate in server/hub.js.
M.CHAT_GATE = 0.5

-- Avatar sprites offered in options, keyed to ids the engine's sprite table
-- always carries.  A player whose chosen sprite is absent from a modded
-- catalog falls back to the first entry rather than failing to spawn.
M.SPRITES = {
  { "RED", "SPRITE_RED" },
  { "BLUE", "SPRITE_BLUE" },
  { "YOUNGSTER", "SPRITE_YOUNGSTER" },
  { "LASS", "SPRITE_LITTLE_GIRL" },
  { "COOLTRAINER", "SPRITE_COOLTRAINER_M" },
}
M.DEFAULT_SPRITE = "SPRITE_RED"

M.NAME_MAX = 10

return M
