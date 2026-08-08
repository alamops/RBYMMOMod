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
-- 5 was claimed twice, by two branches that had never met: once for pace
-- (the `fast` flag on mmo.move -- "this step was taken at the fast pace",
-- set by a sprint *or* the bike, since both cost 8 frames a tile) and once
-- for co-op battles (a protocol-4 hub has never heard of mmo.coop_wait: a
-- player would press WAIT FOR <friend> and stand there while their partner
-- is never told).  Each 5 was a different vocabulary, so a client and hub
-- that both said "5" could still be talking past each other -- exactly the
-- silence this number exists to turn into a sentence.  6 is the first
-- number that means both.
--
-- And then 6 was claimed twice in exactly the same way, before it ever
-- shipped: once by that union, and once for changing character in the
-- middle of a game (mmo.sprite -- a hub that has never heard the type
-- answers it with silence, so the player who picked somebody new would be
-- the only person in the game who could see it).  7 is the first number
-- that means all of it.
--
-- 8 is mmo.party_event -- what the person you are travelling with just did,
-- fanned out by the hub to the party and to nobody else.  The rule that moved
-- every number above moves this one: a protocol-7 hub has never heard the
-- type, so its handler table answers it with silence, and a player would
-- watch their partner fight all evening and never be told a thing.  Neither
-- end could tell that from an ordinary quiet route, which is exactly the
-- silence this number exists to turn into a sentence.  This number lives here
-- and in server/lib/relay.js -- bump them together.
--
-- 9 is mmo.request_cancel -- the asker withdrawing a trade/battle request
-- before it is answered.  A protocol-8 hub has never heard the type, so
-- cancelling would clear the asker's local wait while the hub still held
-- pendingTo: the other player could still accept and pull them into a
-- session they thought they had walked away from.  Silence is worse than a
-- refusal that names both versions, so the number moved.
M.PROTOCOL = 9

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

-- How far an avatar is pushed up the draw order so the local player always
-- wins a shared tile.  The overworld sorts entities by their pixel `py`, and
-- that sort is unstable, so on a tie the two characters swap places from
-- frame to frame -- a hundredth of a pixel is the smallest thing that
-- decides it and the largest thing nobody can see.
--
-- It rests on two facts, and stops being safe without either.  Engine `py`
-- values are always whole pixels (a step's progress is floored and a landing
-- snaps to `cell * 16`), so any fraction at all breaks the tie in the
-- player's favour.  And the nudge is only ever applied when `py % 1 == 0`,
-- which is what keeps an avatar standing still from drifting up the screen
-- a hundredth of a pixel per frame.
--
-- "Nobody can see it" is only true because it never leaves the sort.  The
-- renderer floors `py - camY` against a whole camera, so a hundredth of a
-- pixel there is a whole pixel on screen -- so src/Avatars.lua adds this
-- back on the two ways out of the avatar layer, the pose the renderer draws
-- from and the cell cellOf reports.  Subtracting and re-adding it is exact
-- in doubles at overworld magnitudes, so a compensated position is equal to
-- the original, not merely close.
M.AVATAR_DEPTH_NUDGE = 0.01

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
M.MESSAGE_MAX = 60           -- longest message accepted off the wire
-- What the naming grid will let you type.  Shorter than MESSAGE_MAX on
-- purpose: the grid shows the line being typed on one 20-tile row, and a
-- line that has to be truncated to be shown is worse than one the player was
-- asked to split themselves.
M.COMPOSE_MAX = 16
-- A hub's message of the day: one line an operator writes once and every
-- arrival reads, delivered on the welcome and shown in the scrollback as a
-- HUB line.  Double a chat line's room because it is doing a different job
-- -- the house rules, where the Discord is, what time the hub goes down
-- tonight -- and none of those is a sentence that fits in sixty characters.
-- The hub cleans it to the same single-line charset chat uses
-- (server/lib/sanitize.js), so nothing can arrive here that a chat line
-- could not also carry; this number is the only thing that differs.
--
-- PROTOCOL did not move for it, and the rule at the top of this file is why:
-- a bump is for a *client* saying something an older hub answers with
-- silence.  This field only ever travels hub -> client, an older hub simply
-- never sends it, and an older client drops a key it has never heard of and
-- is exactly as connected as before.  Nothing goes unexplained on any
-- screen, so nothing is owed a refusal.
M.MOTD_MAX = 120

-- ------- toasts
--
-- The transient lines src/Toast.lua stacks in the corner: what somebody
-- said, who arrived, what your partner just beat.  Five seconds is long
-- enough to read a sentence while walking and short enough that a busy hub
-- does not leave a wall of text on screen; five lines is what the stack may
-- hold before the oldest is dropped, and dropping the oldest is right
-- because the newest line is the one the player has not read yet.
M.TOAST_SECONDS = 5
M.TOAST_MAX = 5

-- Rajdhani Regular, SIL Open Font License 1.1 (assets/fonts/OFL.txt).
--
-- Its own face rather than the game's, and that is the point: the ROM font
-- is extracted from the player's cartridge and carries no lowercase and
-- almost no punctuation, so a chat line drawn with it loses characters
-- silently.  A toast has to be able to show a sentence somebody typed.
--
-- Size is in window pixels and deliberately small -- toasts are read in
-- passing, not as a second HUD.  The path is relative to the mod root,
-- which is what mod.assets:path expects -- the same shape as OWN_CHARS'
-- `dir` above.
M.TOAST_FONT = "assets/fonts/Rajdhani-Regular.ttf"
M.TOAST_SIZE = 12

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

-- ------- the characters this mod brings of its own
--
-- The dial board for src/Cast.lua; the argument for every number is in that
-- file's header.  These are the only sprite ids in this file that the
-- engine's catalog does *not* already carry -- Cast registers them, which is
-- why they can be offered in the options row above alongside ids the ROM
-- guarantees.
--
-- `dir` holds three files, all original art shaped like the engine's own:
-- walk.png (16x96, six 16x16 frames), front.png (56x56, the trainer-card and
-- intro pic) and back.png (48x48, the battle back pic).
--
-- backScale is what a 48x48 back pic has to draw at, and it has to be a whole
-- number.  The plain battle view hands the registered scale to the draw call
-- verbatim, onto a nearest-neighbour canvas: at a fractional scale a source
-- pixel lands on one destination pixel in some columns and two in others, so
-- the sprite comes out visibly uneven rather than merely smaller or larger.
-- This mod shipped exactly that bug -- 64/48, chosen so 48x48 art would keep
-- the 64-pixel footprint the engine's own 32x32 back pics get from their
-- default 2x, because a taller trainer stands in the text box.  The footprint
-- was right and every third column was a pixel wide twice over.
--
-- 1 is the only whole number that works at this art size.  The feet sit on
-- the text-box top at every scale and the pic grows upward from there, so at
-- 2 it is 96 pixels tall and covers the whole field above the text box,
-- enemy pic and status boxes included; at 1 it is 48, the size a back pic
-- can actually be.  It also settles a disagreement between the two
-- battle views: the alternate 3D view already rounds every battle scale to
-- the nearest integer before drawing, so it has been showing these back pics
-- at 1x all along.  Both views now draw the same pic at the same size.
M.OWN_CHARS = {
  { id = "SPRITE_NIRE", label = "NIRE",
    dir = "assets/chars/nire", backScale = 1 },
  { id = "SPRITE_NIRE_HOOD", label = "NIRE HOOD",
    dir = "assets/chars/nire_hood", backScale = 1 },
}

-- Offered in the options row like any other character.  Built from the table
-- above rather than written out twice: a character added there and forgotten
-- here would be wearable from the CHARACTER screen and invisible in options,
-- which is the kind of split nobody notices until a player reports it.
for _, char in ipairs(M.OWN_CHARS) do
  M.SPRITES[#M.SPRITES + 1] = { char.label, char.id }
end

-- Six 16x16 frames, the shape SpriteRenderer reads an overworld sheet in.
M.CHAR_FRAMES = 6

-- Mod art may opt into a ROM sprite's Advanced-mode OBJ palette assignment
-- without claiming the pixels came from the ROM (sprites.paletteSource).
-- Index 0 of the sprite-sheet table is the player's own, which is the one
-- these characters are drawn to wear -- and the palette the sheets they came
-- from were coloured with.
M.CHAR_PALETTE_SOURCE = "ROM:SpriteSheetPointerTable[0]"

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
-- Where claim tickets are kept, in the LOVE save directory, next to the
-- engine's own save files.
--
-- They are written to mod.save as well, but mod.save is RAM the engine
-- happens to flush with the rest of a save: nothing in connecting or
-- disconnecting reaches disk, and CONTINUE replaces the whole table with
-- whatever was last written. A ticket minted this session and never saved is
-- gone by the next connect -- and the hub, which has not forgotten, then
-- answers the name's rightful owner as an impostor. This file is what a save
-- reload cannot take away. One flat JSON object; the key format and why it
-- carries the trainer name are in src/Client.lua.
M.RANK_TOKEN_FILE = "rby_mmo_rank_tokens.json"
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

-- ------- the hubs you have played on
--
-- src/Servers.lua keeps the list behind START > MMO > SERVERS; the argument
-- for what it is and where it is written is in that file's header.

-- The product-owned row at the top of that list. Its port is explicit rather
-- than derived from DEFAULT_PORT: changing the port used by a local host must
-- not quietly point the official row at a different service. Servers projects
-- this into the menu without putting it in either persistence mirror.
M.FEATURED_SERVER_NAME = "RBY MMO OFFICIAL"
M.FEATURED_SERVER_HOST = "play.rbymmo.com:7788"
M.FEATURED_SERVER_CODE = "QG0251"

-- How long a row's name may be. Sixteen is what the list menu has room for
-- beside its favourite marker at Game Boy width, and it is COMPOSE_MAX's
-- number for the same reason -- a label that overflows its row is worse than
-- one the player has to shorten themselves.
M.SERVER_NAME_MAX = 16
-- How many hubs are remembered before the least recently connected
-- non-favourite is dropped. A ceiling on a convenience list, not on play:
-- sixteen is twice the menu's visible rows, so a player who scrolls one screen
-- has not yet reached the end of what is kept, and nobody realistically plays
-- on more hubs than that without favouriting the ones they mean to keep.
M.SERVER_LIST_MAX = 16
-- Where the list is kept, in the LOVE save directory beside the rank tickets
-- and the engine's own save files. Its own file rather than a corner of
-- mod.save because a server list is machine-level state: it must survive
-- CONTINUE, and it belongs to every save slot on this copy at once.
M.SERVERS_FILE = "rby_mmo_servers.json"

return M
