-- Shared constants.  Anything two modules both need lives here, so the
-- resolver in main.lua never has to break a cycle.

local M = {}

M.MOD_ID = "rby_mmo"

-- Bumped when a wire change is not backward compatible.  The hub refuses a
-- client whose PROTOCOL differs, with a message naming both versions --
-- silently talking a different dialect is the worst failure mode here.
--
-- 3 added parties.  Nothing was removed, so an older client's messages would
-- all still parse -- but the failure that mattered is the other direction:
-- against a protocol-2 hub, an invite and a party chat line are message
-- types and a scope that hub has never heard of, and its handler table
-- answers an unknown type with silence.  The player would press INVITE and
-- watch nothing happen, forever, with nothing on screen to act on.  A
-- refusal that names both versions is the better sentence, so the number
-- moved.
--
-- 4 adds ranked PVP, and moved for the same reason rather than a different
-- one: a protocol-3 hub has never heard of a battle result or a leaderboard
-- request, so a newer client would report every match into silence and open
-- a RANK screen that never fills.  This number lives here and in
-- server/lib/relay.js -- bump them together.
--
-- 5 adds pace, and it moves for the third time on the same rule: a
-- protocol-4 hub rebuilds every broadcast from its own fixed field list, so
-- the pace flag on mmo.move is not misread, it is dropped without a word.
-- The fast player would see themselves move and everyone else would watch
-- them walk, with nothing anywhere to explain the difference -- so a refusal
-- naming both versions is again the better sentence.
--
-- The field is `fast`, not `running`: it means "this step was taken at the
-- fast pace" and is set by a sprint *or* by the bike, since both cost 8
-- frames a tile and one boolean carries them.  It was called `running`
-- during 0.5.0's development and renamed before release -- 5 has never
-- shipped, so no hub and no client anywhere speaks the old name and the
-- rename cost nothing.  This number lives here and in server/lib/relay.js --
-- bump them together.
M.PROTOCOL = 5

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

-- Running: hold B on foot and a tile takes half as long.
--
-- A divisor rather than a frame count, because the walk speed it divides is
-- not ours to know: 16 is vanilla, but a data pack may say otherwise, and
-- hardcoding 8 here would quietly *slow a modded runner down*.  Two is the
-- Gen 3+ figure -- running is bike-fast, which is what makes the bike still
-- worth getting on for its own reasons rather than for its speed.
M.RUN_DIVISOR = 2

-- What a remote avatar moving at the fast pace has its npc.stepFrames set
-- to.  One number for two ways of getting there: a sprinter and a cyclist
-- both cover a tile in 8 frames, so the wire says "fast" rather than "which"
-- and this count serves both.
--
-- NPCs get no movement.speed hook to divide: their pace is a field read
-- fresh each frame, and its unset default is NPC.lua's hardcoded
-- STEP_FRAMES = 16 -- the engine's NPC walk default, *not* the player's walk
-- speed, which the divisor above is deliberately never told.  So the count
-- is derived from that 16 rather than written out beside it: tuning
-- RUN_DIVISOR then moves the local runner and the remote avatar together,
-- and one speed stays one speed.  Two independent numbers would drift apart
-- on the first tune, and avatars pacing faster than the presence stream
-- describes strobe past RESYNC_DISTANCE -- which is exactly what remote
-- cyclists did for as long as the wire had no way to say they were fast.
M.FAST_STEP_FRAMES = math.max(1, math.floor(16 / M.RUN_DIVISOR))

-- Parties: you and one friend, travelling together.
--
-- Two is the whole design, not a first step towards six.  A party here is a
-- standing pair -- one marker over one head, one extra chat scope, one
-- members list that fits in a command box -- and every rule that makes it
-- feel solid follows from the pair: an invite is only offered when *both*
-- sides are unattached, and either member leaving ends it for both, because
-- with two people "the party continues without you" is not a thing that
-- exists.  Raising this number would not widen the feature, it would make
-- all three of those rules wrong at once.
M.PARTY_MAX = 2

-- Chat.  "party" is delivered to the other member wherever they are, so it
-- is the one scope with neither a radius nor a name to type.
M.CHAT_SCOPES = { "global", "local", "private", "party" }
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

-- ------- ranked PVP
--
-- The arithmetic these feed is in src/Rank.lua, and the reasoning about what
-- the numbers buy is in its header rather than here -- this is the dial
-- board, that is the argument. Every one of them is mirrored in
-- server/lib/rank.js: two hubs that price a win differently are two
-- rankings, so they move together or not at all.

-- The most one match can move a rating, before the rematch discount. 32 is
-- Elo's usual figure for a pool that turns over, and at RANK_START = 0 it
-- means an even first match is worth 16 -- enough that one win puts you on
-- the board, small enough that ten do not decide the season.
M.RANK_K = 32
-- The rating gap at which a win is worth roughly a tenth of RANK_K. Elo's
-- 400 again: it is the number the curve was drawn for.
M.RANK_SCALE = 400
-- Everybody starts unranked, and the board only lists points > 0, so a
-- player appears on it by winning rather than by connecting.
M.RANK_START = 0
-- Four digits is what a trainer-card row has room for beside the badge
-- count, and no realistic season reaches it.
M.RANK_MAX = 9999
-- How many rows the RANK screen asks for, and the brief's number.
M.RANK_TOP = 10
-- A claim token, lowercase hex on the wire: 16 bytes, the same shape and the
-- same source as a challenge nonce. It says "this name is mine" and nothing
-- else -- see src/Rank.lua's header for what that is worth, and what it is
-- not. The hub keeps only its SHA-256.
M.RANK_TOKEN_HEX = 32
-- How long a pairing stays "recently played" for the rematch discount, and
-- how many meetings inside it take a win to nothing (halving each time, so
-- the sixth rematch in the window is already worth zero).
M.RANK_REPEAT_WINDOW = 3600
M.RANK_REPEAT_FADE = 6
-- Smallest gap between two leaderboard requests from one player. Answering
-- one means sorting every rating the hub holds, and a screen that asks on
-- open is a screen somebody can hold open -- so it is gated like chat is.
M.RANK_QUERY_GATE = 1
-- When the per-pair table is bigger than this, expired pairings are swept.
-- A ceiling on bookkeeping, not on play: nothing is refused when it is hit.
M.RANK_PAIRS_MAX = 512
-- How long a finished battle stays reportable after the hub tears its
-- session down. Both players must report before anything is scored, and
-- their two reports are separated by however long each side spends on the
-- end-of-battle messages -- plus a hub round trip. Sixty seconds is far more
-- than that gap and far less than a session.
M.RANK_REPORT_GRACE = 60

return M
