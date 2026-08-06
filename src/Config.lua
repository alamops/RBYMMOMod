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
-- 5 adds co-op battles, and the same argument decides it a third time.  A
-- protocol-4 hub has never heard of mmo.coop_wait: a player would press WAIT
-- FOR <friend>, stand there while their partner is never told, and eventually
-- give up on a feature that was working correctly on their side of the wire.
-- Silence is the failure mode this number exists to turn into a sentence.
M.PROTOCOL = 5

-- The port an in-game host binds, and the one a bare address is completed
-- with.
--
-- Overridable by environment, which is not only a test affordance: 7788 is a
-- guess, and a player whose router or another program already has it needs a
-- way out that is not editing the mod. It is also what lets two end-to-end
-- runs -- two agents, two worktrees -- host at the same time on one machine
-- instead of one silently joining the other's game.
--
-- Read once, at load, and validated: a junk value falls back rather than
-- producing an address nothing can dial.
local function portFromEnv(fallback)
  local raw = os.getenv and os.getenv("RBY_MMO_PORT")
  local n = tonumber(raw or "")
  if n and n == math.floor(n) and n > 0 and n < 65536 then return n end
  return fallback
end

M.DEFAULT_PORT = portFromEnv(7788)
M.DEFAULT_HUB = ("127.0.0.1:%d"):format(M.DEFAULT_PORT)

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

-- ------- co-op battles
--
-- Two players from one party fighting one battle together, and then four
-- players fighting each other.  Three files: src/Coop.lua is the agreement
-- (who is waiting, who may join, what a no costs), src/CoopSim.lua is the
-- four-slot field, and src/CoopBattle.lua is the screen it is drawn on.
--
-- The field is the mod's own, because the engine has none: BattleState carries
-- exactly one active battler per side and TurnOrder compares a pair.  What sits
-- *under* the field is still the engine's -- damage, crits, types, STAB, the
-- badge boosts, the status records -- so a mon hits for the same number here as
-- it does in a wild battle.
--
-- Four fighters, because two parties of PARTY_MAX meet.  It is written as a
-- product rather than as the literal 4 so that the day PARTY_MAX moves, the
-- side that has to move with it is not a number somebody has to remember.
M.COOP_SIDE = M.PARTY_MAX
M.COOP_FIGHTERS = M.PARTY_MAX * 2

-- What identifies "the same fight" to two different clients.
--
-- Two partners standing in front of one trainer have to agree they are
-- talking about *that* trainer and not merely about some battle, or a player
-- crossing a route would be asked to join a fight three screens away.  The key
-- is built by Coop.battleKey from the map and the trainer's own identifiers,
-- so it is derived on both sides from the world rather than passed around and
-- trusted.
-- How many badge ids a client may claim. Gen 1 has eight and only four of
-- them boost a stat, so this is a bound on a payload rather than a rule about
-- the game -- generous enough that a mod adding badges is not cut off.
-- The most POKeMON a slot may bring, which is Gen 1's party size.
--
-- A bound on a *relayed* list rather than a rule about the game: the field
-- description crosses the wire from another player's client, and a party
-- length nobody checked is a battle that never ends -- every faint answered by
-- another monster, for as many as the sender felt like sending.
M.COOP_TEAM_MAX = 6

M.COOP_BADGES_MAX = 32

M.COOP_KEY_MAX = 64

-- What a fight is *called*, as opposed to what identifies it.
--
-- Its own limit rather than NAME_MAX, and the difference is not cosmetic: a
-- trainer class is not a trainer name, and at ten characters "BUG CATCHER"
-- arrives as "BUG CATCHE" -- a box asking whether to join a friend against a
-- misspelt opponent. Sixteen is what the sentence has room for, since the
-- label shares a line with nothing (the box reads "Join ANN against" and then
-- the label on its own row, and a text box is eighteen columns).
M.COOP_LABEL_MAX = 16

-- How long an unanswered co-op offer stands before it is dropped.
--
-- Long, and deliberately so: the whole point of WAIT FOR <friend> is that a
-- player is prepared to stand still until their partner walks over, and a
-- partner crossing two maps is an ordinary three minutes.  It exists at all so
-- that an offer whose owner wandered off and forgot it cannot sit on the
-- partner's client forever -- not to hurry anybody.
M.COOP_OFFER_TIMEOUT = 300

-- How long the four-way PARTY BATTLE ask waits for its three answers.  Shorter
-- than an offer because every one of the four is looking at a box right now,
-- and an ask that outlives the moment it was made is an ask somebody answers
-- yes to long after they stopped meaning it.
M.COOP_ASK_TIMEOUT = 60

-- How much longer a *client* waits before giving up on an ask than the hub
-- does.
--
-- The two clocks used to be the same number, and the asker's starts when it
-- sends while the hub's starts a round trip later -- so the client reliably
-- expired first, cleared its own `ask`, and said "nobody answered". The hub
-- still held one. The player could then pick PARTY BATTLE again, the hub would
-- drop it as a duplicate, and they were left pressing a button that did
-- nothing until the hub's own clock caught up.
--
-- A margin rather than a smaller number, because the hub is the one that has
-- to speak: it tells all four. The client giving up first is the case worth
-- ruling out.
M.COOP_ASK_GRACE = 10

-- How long a co-op battle's relay group may live before the hub reclaims it.
--
-- The belt to mmo.coop_leave's braces. A client that crashes mid-battle never
-- sends the goodbye and never disconnects cleanly enough to be dropped, and
-- without this its group would sit in the table for the life of the process.
-- An hour is far longer than any battle and far shorter than an uptime.
M.COOP_BATTLE_MAX = 3600

-- How long the host waits on a player who is connected but silent.
--
-- Generous, because it is a human choosing a move and the whole battle stops
-- until they do -- but finite, because a connected client that has stopped
-- answering (a wedged game, a laptop lid) is indistinguishable from one
-- thinking, and the other three cannot be made to wait on it forever. A slot
-- that misses this forfeits, which is the same thing that happens when its
-- player disconnects outright.
-- How long the field waits for a player to send out their next POKeMON.
--
-- Half the turn clock, and deliberately not the same number. A player still
-- picking a *move* blocks one turn; a player who has not answered a faint
-- blocks **everything** -- the field refuses to resolve while any slot is
-- awaiting, so the other three are sitting in front of a battle that cannot
-- move at all. It is also the easier decision of the two: a short list, and
-- one button. So the pause that costs the most is given the least rope.
M.COOP_CHOICE_TIMEOUT = 30

-- How long a wait may look like nothing before it starts explaining itself.
--
-- Under this, nothing is drawn: an ordinary turn has all four players deciding
-- at once and a clock that flashed up every turn would be noise. Past it, the
-- box says who is being waited for and counts down, because the difference
-- between "somebody is thinking" and "this has hung" is the whole of what a
-- player cannot tell from an empty screen.
M.COOP_WAIT_HINT = 5

M.COOP_TURN_TIMEOUT = 60

-- How long a replayer waits on a silent host.
--
-- **Longer than the turn deadline, and that is the whole rule.** This clock
-- asks "has the client that decides everything said anything at all", and the
-- answer only means something once a healthy host would have had to speak. The
-- turn deadline is that guarantee: a turn opens, and within COOP_TURN_TIMEOUT
-- the host either resolves it or auto-picks for whoever is late and resolves it
-- anyway -- so a `res` lands inside 60 seconds of every turn opening. Silence
-- past that really is silence.
--
-- It used to be 30, which is *under* the turn budget, so a legitimately quiet
-- turn -- four players thinking, nobody late enough to be picked for -- tripped
-- every replayer into a warning and a resync as an **expected** state: a log
-- full of "the co-op battle has gone quiet" about a battle that was fine, and
-- three snapshot requests the host had to answer every slow turn.
--
-- The cost is honest and it is paid on the one path that matters: a host that
-- really has died is now declared after two expiries rather than one plus a
-- resync, so up to 150 seconds worst case (75 to ask, 75 to give up) instead of
-- 60. That is the right trade -- a dead host is rare and ends the battle either
-- way, while a quiet turn is ordinary and used to cost a false alarm every time.
M.COOP_STALL_TIMEOUT = 75


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
