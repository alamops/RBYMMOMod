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

-- Effects for bag proofs: Gen1 default, Gen2 when hub generation is 2.
-- Lazy so a Gen1-only load never pulls BattleSim2.
local effectsByGen = {}
local function effectsFor(generation)
  local key = (generation == 2) and 2 or 1
  local cached = effectsByGen[key]
  if cached then return cached end
  local path = key == 2 and "BattleSim2/Effects" or "BattleSim/Effects"
  local Effects = need(path)
  effectsByGen[key] = Effects
  return Effects
end

-- client -> hub
M.HELLO         = "mmo.hello"
M.MOVE          = "mmo.move"
M.CHAT          = "mmo.chat"
M.REQUEST        = "mmo.request"
M.RESPOND        = "mmo.respond"
-- The asker takes back an unanswered trade/battle request.  One name for
-- both directions, the way PARTY_INVITE is: outbound it is empty (the hub
-- already knows who we asked), inbound it carries { from, name } so the
-- player holding the yes/no box can say who walked away.
M.REQUEST_CANCEL = "mmo.request_cancel"
M.RELAY          = "mmo.relay"
M.SESSION_LEAVE  = "mmo.session_leave"
M.PING          = "mmo.ping"
-- Parties.  PARTY_INVITE travels both ways, the way REQUEST does: the field
-- set says which direction it is going (`to` outbound, `from` inbound), and
-- one name for one idea is easier to follow across two hub implementations
-- than a matched pair that has to be kept in step.
M.PARTY_INVITE  = "mmo.party_invite"
M.PARTY_RESPOND = "mmo.party_respond"
M.PARTY_LEAVE   = "mmo.party_leave"
-- What just happened to the person you are travelling with: they beat a wild
-- POKeMON or a trainer, were beaten by one, or caught something.  One name
-- for both directions, the way CHAT and SPRITE are -- outbound it carries
-- { kind, species, level, trainer } and inbound the same plus { from, name }.
--
-- **The fighter never sends their own name and the hub never reads one.**  It
-- is stamped from the connection the message arrived on, because `name` is
-- the only identifying field here and the whole event is drawn as a sentence
-- about a named player: a client that supplied its own would be narrating
-- its partner's screen under somebody else's nick.
--
-- Fanned out to the rest of the party and to nobody else -- the fighter
-- included, since they watched the battle happen and their own client can
-- say so without a round trip.  The shape is M.partyEvent, below.
M.PARTY_EVENT   = "mmo.party_event"
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
-- Co-op battles.  Five going out, five coming back, and the asymmetry is the
-- same one PARTY_INVITE has: the hub is what turns "I am waiting" into "your
-- friend is waiting", because only the hub knows who is in the party.
--
-- COOP_WAIT carries { battle, label, map [, mode] [, npcId] [, event] } -- the
-- fight this player is standing in front of.  Optional `mode` is only
-- `"coop_wild"` (Party vs Wild auto-join); absent means the trainer WAIT/JOIN
-- invite path.  Optional `npcId` / `event` (PROTOCOL 20) are the waiter's
-- overworld NPC id and event-flag id from engine `checkpointOrigin`, so an
-- invite joiner with no local BattleState can still mark the trainer beaten.
-- COOP_CANCEL withdraws it with an optional reason (`alone` / `left` /
-- `timeout` from the waiter; `no` from the partner who declined the invite).
-- Naming which offer is unnecessary: there is only ever one per player.
-- COOP_JOIN answers somebody else's offer with { to, battle }.
--
-- A partner decline (`COOP_CANCEL` reason `no`) is forwarded to the waiter as
-- `COOP_DECLINE`, so they can leave the wait and fight the trainer alone.
M.COOP_WAIT      = "mmo.coop_wait"
M.COOP_CANCEL    = "mmo.coop_cancel"
M.COOP_JOIN      = "mmo.coop_join"
-- The four-way PARTY BATTLE: one party challenges another, { to }.  Answered
-- by the other three with COOP_ANSWER { accept }.
M.COOP_CHALLENGE = "mmo.coop_challenge"
M.COOP_ANSWER    = "mmo.coop_answer"
-- Battle traffic between the players in one co-op battle: { payload }.
--
-- Its own message rather than mmo.relay, and the difference is the whole
-- reason it exists: a relay goes to *the* session peer, and there are three of
-- them here.  The hub fans this out to everyone else in the same battle and
-- reads none of it, exactly as it does not read a relay payload.
M.COOP_RELAY     = "mmo.coop_relay"
-- Two kinds that ride *inside* a COOP_RELAY payload rather than beside it,
-- and they are named here because this file is where the vocabulary lives --
-- not because the hub has anything to do with them.
--
-- **Neither is a hub message and neither needs one.** A relay payload is
-- forwarded unread by both hubs (server/lib/relay.js and src/Hub.lua judge
-- its *shape* through payloadOk and nothing else), so a new kind inside the
-- envelope reaches the other three players with no hub change on either side
-- -- and a client built before these existed drops through its inbound
-- dispatch without a branch and ignores them, which is exactly the degrade a
-- mixed-version battle wants: the ask simply goes unanswered and the turn
-- deadline files it as a refusal.
--
--   run_ask     -- "I want us to run." Carries no fields at all: who asked is
--                  the `from` the hub stamps on the way out, and which slot
--                  that is is a fact the receiving client reads off its own
--                  copy of the field. A slot named in the payload would be a
--                  slot a modified client could claim.
--   run_answer  -- { ok } -- the partner's yes or no.
M.COOP_RUN_ASK    = "run_ask"
M.COOP_RUN_ANSWER = "run_answer"
-- "this co-op battle is over."  No fields: a player is only ever in one, and
-- naming which would be a second way to be wrong.
--
-- It exists because the hub otherwise has no idea a battle ended. A group is
-- opened when four players agree and was only ever closed when somebody
-- *disconnected*, so a hub that ran for a week accumulated one dead group per
-- battle ever fought, each still routing relays to players who had long since
-- walked away.
M.COOP_LEAVE     = "mmo.coop_leave"

-- ------- friends
--
-- Three types, all three travelling in both directions the way PARTY_INVITE
-- does -- the field set says which way it is going.
--
-- **They are addressed by *name*, not by connection id, everywhere except the
-- ask itself.**  A friendship outlives the connection that made it: the whole
-- feature is a list that still has somebody on it tomorrow, and an id is
-- minted per connection, so a name is the only handle that means the same
-- thing twice.  The ask is the exception because it can only ever be made
-- against somebody standing in front of you, so it names the id it is offered
-- to and the hub answers by name from there on.
--
--   FRIEND_ASK    -- outbound { to }, the id of the player being asked.
--                    Inbound { from, name } -- `from` is their id when they
--                    are still connected and absent when the hub is
--                    delivering an ask it held while this player was away,
--                    which is exactly the case the name exists for.
--   FRIEND_ANSWER -- outbound { toName, accept }, inbound { name, accept }.
--                    A yes from the asked side; a no is the same message with
--                    accept false, because "they said no" and "they have not
--                    answered yet" are the two things a player most needs
--                    told apart.
--   FRIEND_REMOVE -- outbound { toName }, inbound { name }.  Friendship is
--                    mutual or it is nothing: a removal that only took one
--                    side off would leave the other holding a row whose
--                    owner would be asked for consent all over again.
--
-- **Only the answer is checked by the hub, and it has to be.**  A client that
-- could send an answer to anybody could put itself on a stranger's friends
-- list without ever being agreed to, so the hub only passes one on when it is
-- holding a matching ask (see its friend handlers).  The removal needs no such
-- check: the hub stamps the sender's own name on it, so the worst a forged one
-- achieves is taking the sender off somebody's list, which is what the message
-- says on the tin.
M.FRIEND_ASK    = "mmo.friend_ask"
M.FRIEND_ANSWER = "mmo.friend_answer"
M.FRIEND_REMOVE = "mmo.friend_remove"

-- The character you are wearing, changed mid-session.  One name for both
-- directions, the way CHAT is: outbound it carries { sprite }, and the hub
-- answers everybody -- the sender included, the way RANK does -- with
-- { id, sprite }.  The field set says which direction it is going, and a
-- matched pair of names would have to be kept in step across two hub
-- implementations for no gain.
--
-- Sanitised with M.spriteId at every boundary and never M.text; the
-- underscore trap that makes that mandatory is written out above spriteId.
M.SPRITE        = "mmo.sprite"

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

-- Co-op, coming back.
--
-- COOP_OFFER is your partner's standing "I am waiting for you at this fight":
-- { from, name, battle, label, map [, mode] }.  Optional `mode` mirrors
-- COOP_WAIT (`coop_wild` only).  COOP_OFFER_END withdraws it, and carries a
-- reason so the partner's client can tell "they went in alone" from "they
-- walked away" -- two things that look identical from the outside and read
-- very differently to the person who was going to join.
M.COOP_OFFER     = "mmo.coop_offer"
M.COOP_OFFER_END = "mmo.coop_offer_end"
-- Somebody accepted yours: { id, name }.  This is the message that ends the
-- waiting, and the only one that does.
M.COOP_JOINED    = "mmo.coop_joined"
-- The four-way ask, as it reaches the three players who did not start it:
-- { id, from, name, side } -- who is asking, and which of the two sides this
-- recipient is on.
M.COOP_ASK       = "mmo.coop_ask"
-- The ask is off: { name, reason }.  Sent to everyone still holding it, so a
-- box that can no longer be answered comes down rather than being answered
-- into nothing.
M.COOP_DECLINE   = "mmo.coop_decline"
-- All four agreed: { id, side, allies, foes }, each a members list.  The hub
-- names the sides because it is the only party to the exchange that knows all
-- four are still connected at the moment it says so.
M.COOP_BATTLE    = "mmo.coop_battle"
-- One player's battle traffic, as it reaches the other three: { from, payload }.
M.COOP_MSG       = "mmo.coop_msg"

-- ------- mediated battles
--
-- Seven types, and they are grouped by feature rather than split across the
-- two direction headings above, because the whole point of them is the
-- *round trip*: an intermediator -- the dedicated hub, or a LAN host -- reads
-- three of these and answers with three others, and reading a choice next to
-- the event it produces is what makes the exchange legible.  Which way each
-- one travels is written beside it.
--
-- What changes here is not the vocabulary but who is trusted with the dice.
-- Everything above this block is relayed: both hubs forward a payload they
-- never read, and the arithmetic of a fight happens on one of the players'
-- clients (LinkBattle's lockstep for 1v1, the host client's CoopSim for 2v2).
-- These seven exist so that it does not: the intermediator owns hit, crit,
-- damage, status and the outcome, and a client sends a choice and draws what
-- it is told.  A modified client can still lie on the sheet it uploads before
-- the fight -- that is the accepted v1 surface -- but it can no longer decide
-- that a move hit, or for how much.
--
-- Nothing in here is ROM-derived and nothing may become so.  The numbers the
-- formulas need arrive from the player's *own* decoded copy, for that match
-- only: BATTLE_RULESET carries the type chart, and each move carries its own
-- power and accuracy on BATTLE_PARTY.  That is why there is no move table on
-- either intermediator, and why there must never be one.

-- The ephemeral rules for one match: { chart, seed }, from whichever client is
-- the authority for it (a LAN host, or the asker on a dedicated hub).  Sent
-- once, before any party, and never stored past the battle.
M.BATTLE_RULESET   = "mmo.battle_ruleset"
-- One combatant's team, as they claim it: { battle, side, mons, badges }.  Each
-- combatant sends their own -- and for a co-op fight against an NPC, the player
-- who walked into the trainer sends the trainer's too, because they are the
-- only one whose copy of the world has it.
M.BATTLE_PARTY     = "mmo.battle_party"
-- The field is assembled and the first turn is open: { battle, mode, sides }.
-- The one message that starts a mediated fight, and the only one -- a client
-- that has uploaded a party and not seen this has nothing to draw yet.
M.BATTLE_READY     = "mmo.battle_ready"
-- What this player wants to do this turn: { battle, action, slot, move, target,
-- item }.  A choice, never a result: the fields name an intent off a menu, and
-- what it costs is the intermediator's to decide.
M.BATTLE_CHOICE    = "mmo.battle_choice"
-- One thing to draw, in order: { battle, seq, t, ... }.  `seq` is what makes
-- the stream a stream -- a client applies events in that order and can tell a
-- gap from a pause, which is the whole difference between a battle that is
-- thinking and one that has lost messages.
M.BATTLE_EVENT     = "mmo.battle_event"
-- How it ended: { battle, outcome, winners, losers, reason }.
--
-- **The sole result, and that is the change.**  A ranked 1v1 used to be scored
-- only when both clients sent the same mmo.result, because neither could be
-- believed on its own; here the intermediator is the only party that rolled
-- anything, so it is the only party that says who won and the dual vote is
-- retired for these fights.
M.BATTLE_OUTCOME   = "mmo.battle_outcome"
-- "I dropped, and I am back": { battle }.  Carries the battle rather than
-- nothing, unlike COOP_LEAVE, precisely because the sender has been away: the
-- connection it is arriving on may be a new one, so the intermediator cannot
-- read which fight this is off a socket it has only just met.
M.BATTLE_RECONNECT = "mmo.battle_reconnect"

M.FACINGS = { up = true, down = true, left = true, right = true }
M.KINDS = { trade = true, battle = true }
-- What a client may claim about a battle it just finished.  "draw" is a real
-- answer and not a refusal to answer: a dropped link, a mutual run and a
-- desync all end that way, and all three score nothing.
--
-- "forfeit" is the fourth, and it only exists on the mediated path: a side that
-- dropped and did not come back inside BATTLE_RECONNECT_GRACE.  It is kept
-- distinct from "loss" rather than folded into it because the two read
-- differently to both players -- the one who stayed was not beaten on the
-- field, and the one who left is owed a sentence that says so rather than a
-- scoreline that implies they were outplayed.  A relayed fight can never
-- produce it: it is a verdict about *time*, and only the process holding the
-- clock is in a position to reach it.
M.OUTCOMES = { win = true, loss = true, draw = true, forfeit = true }

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

-- The same name, as the one string that decides whether two of them are the
-- same person.
--
-- Friendship and the rank board are both keyed on a trainer name rather than
-- on a connection id, because both have to mean the same thing on the next
-- visit -- and a name is typed, so "ANN" and "ann" are one player who shifted
-- on the shift key.  This is Rank.keyOf and server/lib/rank.js's keyOf spelled
-- once more at the wire boundary, and the three have to agree byte for byte:
-- a hub that folds case where a client does not is a hub that holds an ask
-- nobody can answer.
--
-- Sanitised first and folded second, never the other way round: upper-casing a
-- string the font cannot draw would produce a key for a name no screen could
-- ever show.
function M.nameKey(value)
  local name = M.name(value)
  if not name then return nil end
  return name:upper()
end

-- A sprite id is an engine identifier (SPRITE_RED), not prose.
--
-- Running one through M.text strips the underscore -- it is not a character
-- the font needs for chat -- and SPRITE_RED silently became SPRITERED,
-- which then missed the catalog lookup and drew *every* remote player as
-- the fallback sprite. The bug was invisible because the fallback works:
-- everyone just looked like RED. Identifiers get an identifier sanitiser.
--
-- Too long is refused rather than trimmed, so both hubs answer the same
-- bytes the same way: server/lib/sanitize.js's cleanSpriteId is
-- /^\w{1,40}$/ and drops anything past 40 outright, and a Lua side that
-- truncated instead would accept, store and re-broadcast an id the node hub
-- had already thrown away. Truncation buys nothing on its own terms either
-- -- a cut id matches no catalog entry, so all it can do is put a name
-- nobody can draw into a presence and onto the rank board, where it renders
-- as the fallback and looks like a bug in the catalog.
function M.spriteId(value)
  if type(value) ~= "string" then return nil end
  if not value:match("^[%w_]+$") then return nil end
  if #value > 40 then return nil end
  return value
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

-- Boot generation claimed on mmo.hello (PROTOCOL 20). Exactly 1 or 2; missing
-- or out of range defaults to 1 so a PROTOCOL-20 client that omits the field
-- still joins a Gen1 hub (legacy-shaped hello after the bump).
function M.generation(value)
  return M.int(value, 1, 2) or 1
end

function M.facing(value)
  if M.FACINGS[value] then return value end
  return nil
end

-- A yes/no off the wire, re-derived rather than trusted for its truthiness.
--
-- Lua calls everything except `false` and `nil` true, so a peer that sent the
-- string "false", the number 0 or an empty table would have all three read as
-- yes by a bare `if value then`. The one field this guards -- a partner's
-- consent to run, which ends a battle and books somebody a ranked loss -- is
-- exactly the one where "anything that is not literally false means yes" is
-- the wrong reading. Only a real boolean true is yes; everything else,
-- including a missing field, is no.
function M.flag(value)
  return value == true
end

-- Persistent player identity (PROTOCOL 16): exactly PLAYER_ID_HEX lowercase
-- hex. Not an opaque id — wrong length must not round-trip through M.id's
-- 40-cap and look valid.
function M.playerId(value)
  local hex = M.hex(value, Config.PLAYER_ID_HEX)
  if hex and #hex == Config.PLAYER_ID_HEX then return hex end
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

-- Overworld NPC id (`ROUTE_3_obj_2`) or an event-flag id from a trainer
-- header. Same shape as M.id (opaque engine key), and the same 40-cap: map
-- object ids and EVENT_* names fit, and borrowing mapId's 64 would let a
-- peer send a key longer than defeatedTrainers ever uses.
function M.npcId(value)
  return M.id(value)
end

-- Event-flag id off a trainer header / checkpointOrigin.event. Same sanitiser
-- as npcId on purpose -- both are save.flags / defeatedTrainers keys.
function M.eventFlag(value)
  return M.id(value)
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

-- The five things worth telling a partner about, and what each one needs in
-- order to say it: "mon" is a species and a level, "trainer" is the name the
-- game shows on the opponent.
--
-- A closed set rather than free text for the reason COOP_REASONS is one:
-- every kind picks a different sentence on screen, so an unknown kind has
-- nothing to draw and is refused rather than printed raw.
--
-- The required fields are part of the kind rather than a check beside it,
-- because a half-filled event is the one failure that reaches a player --
-- "ANN defeated" with nothing after it is a sentence that stops mid-way, and
-- there is no sensible thing to put there after the fact.
M.PARTY_EVENTS = {
  defeat_wild         = "mon",
  defeated_by_wild    = "mon",
  capture             = "mon",
  defeat_trainer      = "trainer",
  defeated_by_trainer = "trainer",
}

-- The highest level a party event may claim.  Gen 1's cap, and a bound on a
-- number that is about to be printed on somebody else's screen rather than a
-- rule about the game.
M.LEVEL_MAX = 100

-- One thing that happened to a party member, as it reaches the other one.
--
-- Returns a rebuilt table carrying only the fields the kind names, so a wild
-- event can never arrive with a trainer on it: the formatter picks its
-- sentence off `kind`, and a stray field would be one more thing that could
-- disagree with the sentence being drawn.
--
-- `name` is required and `from` is not.  The name is what every one of the
-- five sentences is about, so an event without one is not something any
-- screen can show; the id is only there because the other party messages
-- carry one, and at PARTY_MAX = 2 there is exactly one player it could name.
function M.partyEvent(raw)
  if type(raw) ~= "table" then return nil end
  local needs = M.PARTY_EVENTS[raw.kind]
  if not needs then return nil end

  local name = M.name(raw.name)
  if not name then return nil end

  local out = { kind = raw.kind, name = name, from = M.id(raw.from) }
  if needs == "mon" then
    -- A species name is prose on its way into a line, and it borrows M.name
    -- rather than M.label because a species and a trainer nick have the same
    -- room on screen -- ten characters is what the longest one needs.
    out.species = M.name(raw.species)
    out.level = M.int(raw.level, 1, M.LEVEL_MAX)
    if not (out.species and out.level) then return nil end
  else
    -- ...and a trainer is M.label rather than M.name, because what arrives
    -- here is the class the game shows and NAME_MAX cuts "BUG CATCHER" to
    -- "BUG CATCHE" -- a line about a misspelt opponent.
    out.trainer = M.label(raw.trainer)
    if not out.trainer then return nil end
  end
  return out
end

-- ------- co-op

-- Which of the two sides of a co-op battle somebody is on.
M.SIDES = { a = true, b = true }

function M.side(value)
  if M.SIDES[value] then return value end
  return nil
end

-- Why an offer or an ask ended.  A closed set rather than free text, because
-- every one of these picks a different sentence on screen and an unknown
-- reason has to degrade to the vague one rather than being printed raw.
--
--   alone     -- they got tired of waiting and went in by themselves
--   left      -- they walked away from the fight without starting it
--   started   -- the battle is already running, which is the one refusal the
--                player cannot do anything about
--   no        -- somebody in the four said no
--   gone      -- somebody dropped
--   timeout   -- nobody answered in time
M.COOP_REASONS = {
  alone = true, left = true, started = true,
  no = true, gone = true, timeout = true,
}

function M.coopReason(value)
  if M.COOP_REASONS[value] then return value end
  return nil
end

-- The identity of one fight, as two clients standing in front of it derive it.
--
-- Not prose and not an id: it is built by Coop.battleKey by joining a map id
-- to the trainer's own identifiers, so it carries the separator those ids are
-- joined with.  Running it through M.text would strip that separator and turn
-- two different trainers on one map into the same key -- which is the failure
-- that matters here, because the whole job of this value is to tell one fight
-- from another.
-- What a fight is called.  Prose, so it borrows M.text -- but with its own
-- limit, because a trainer class is not a player name and NAME_MAX cuts "BUG
-- CATCHER" to "BUG CATCHE".
function M.label(value)
  return M.text(value, Config.COOP_LABEL_MAX)
end

-- The badges a player brings to a co-op battle, as a set.
--
-- Sent as a list and rebuilt as a set here, because a set arriving off the
-- wire is a table with arbitrary keys and this one is about to be indexed by
-- the engine. Every id is re-derived through M.id and the list is bounded;
-- an id that is not one the badge rows name is inert anyway -- `makeBattler`
-- walks the rows and asks the set, never the other way round -- so the bound
-- is about payload size rather than about what a lie could achieve.
--
-- Returns nil for anything that is not a list, which is the same answer as
-- "no badges" and is treated the same everywhere.
function M.badges(value)
  if type(value) ~= "table" then return nil end
  local out, count = {}, 0
  for _, raw in ipairs(value) do
    local id = M.id(raw)
    if id and not out[id] then
      out[id] = true
      count = count + 1
      if count >= Config.COOP_BADGES_MAX then break end
    end
  end
  if count == 0 then return nil end
  return out
end

-- The assembled field, as it reaches the other three clients.
--
-- **This is the one payload that used to be taken on trust**, and it is the
-- least defensible one to trust: the "host" is another player's client, not a
-- server, and this table decides how many monsters are on the field, whose
-- they are, and what is drawn over them. Everything else inbound passes
-- through this file; this did not.
--
-- Four things are checked, and each was reachable:
--
--   * the slot **count** (3‥COOP_FIGHTERS), because `buildField` only ever
--     checked it on the sending side -- so a modified host could send fifty
--     and every client would build fifty. Three is a real shape: two players
--     against a one-monster trainer;
--   * the **side**, because `targetsFor` reads it as one of two values and an
--     arbitrary third makes "who may I attack" incoherent;
--   * the **name**, because it is drawn on screen and interpolated into
--     messages and the events other mods listen to;
--   * the **party length**, because `unpackParty` iterates whatever it is
--     given and payloadOk's node budget permits a few hundred -- a battle
--     that never ends.
--
-- Returns a rebuilt table rather than the original: what is passed on is only
-- the fields named here, in the shapes named here.
function M.coopField(raw)
  if type(raw) ~= "table" or type(raw.slots) ~= "table" then return nil end
  local n = #raw.slots
  -- Floor is three: a co-op party needs two humans, and an NPC fight needs at
  -- least one foe seat. Cap is the full four-fighter field (two parties, or a
  -- trainer with enough monsters to fill both foe seats).
  if n < 3 or n > Config.COOP_FIGHTERS then return nil end

  local slots = {}
  for i = 1, n do
    local slot = raw.slots[i]
    if type(slot) ~= "table" then return nil end
    local side = M.side(slot.side)
    if not side then return nil end

    -- An NPC slot has no owner, which is a real answer; a *malformed* owner is
    -- not, and the two are told apart rather than both waved through.
    local owner = nil
    if slot.owner ~= nil then
      owner = M.id(slot.owner)
      if not owner then return nil end
    end

    -- Wide enough for a trainer class ("BUG CATCHER"), which is what an NPC
    -- slot carries, and cleaned like any other text that reaches a screen.
    local name = M.label(slot.name)
    if not name then return nil end

    if type(slot.party) ~= "table" then return nil end
    local party = {}
    for _, mon in ipairs(slot.party) do
      if type(mon) ~= "table" then return nil end
      if #party >= Config.COOP_TEAM_MAX then return nil end
      party[#party + 1] = mon
    end
    if #party == 0 then return nil end

    slots[i] = { side = side, owner = owner, name = name, party = party,
                 badges = M.badges(slot.badges) }
  end

  return { slots = slots, host = M.id(raw.host),
           trainer = M.id(raw.trainer) }
end

function M.battleKey(value)
  if type(value) ~= "string" then return nil end
  if not value:match("^[%w_%.%-:|]+$") then return nil end
  if #value > Config.COOP_KEY_MAX then return nil end
  return value
end

-- Optional wait/offer mode. Only `coop_wild` is meaningful; anything else
-- (including absent) is nil so the trainer invite path stays the default.
function M.coopOfferMode(value)
  if value == "coop_wild" then return "coop_wild" end
  return nil
end

-- A co-op offer as it reaches the partner.  `label` is what the box calls the
-- fight ("BUG CATCHER") and is prose; `battle` is the key and is not.  A
-- missing label is fine and common -- a script-driven battle need not name its
-- trainer -- so it degrades to nil and the screen says "a battle" instead of
-- refusing the whole offer over a cosmetic field.  Optional `mode` is only
-- `coop_wild` (auto-join Party vs Wild); unknown values are dropped, not a
-- refuse of the whole offer.  Optional `npcId` / `event` (PROTOCOL 20) name the
-- waiter's overworld trainer so a menu joiner can finish the fight off without
-- a local BattleState; absent on older hubs and on coop_wild.
function M.coopOffer(raw)
  if type(raw) ~= "table" then return nil end
  local from = M.id(raw.from)
  local name = M.name(raw.name)
  local battle = M.battleKey(raw.battle)
  if not (from and name and battle) then return nil end
  return {
    from = from,
    name = name,
    battle = battle,
    label = M.label(raw.label),
    map = M.mapId(raw.map),
    mode = M.coopOfferMode(raw.mode),
    npcId = M.npcId(raw.npcId),
    event = M.eventFlag(raw.event),
  }
end

-- Presence as it appears in a welcome roster, a join, or a move.  Position
-- is optional so a player sitting in a menu or a battle can still be listed
-- without claiming a cell in the world.
-- Optional `generation` (1|2) picks the missing-sprite fallback (Red vs Chris).
function M.presence(raw, generation)
  if type(raw) ~= "table" then return nil end
  local id = M.id(raw.id)
  local name = M.name(raw.name)
  if not id or not name then return nil end
  local out = {
    id = id,
    name = name,
    sprite = M.spriteId(raw.sprite) or Config.defaultSpriteFor(generation),
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
        local entry = {
          name = name,
          sprite = M.spriteId(row.sprite) or Config.defaultSpriteFor(nil),
          points = M.points(row.points),
        }
        -- Optional: older hubs omit id; PROTOCOL 16 boards always send it.
        local id = M.playerId(row.id)
        if id then entry.id = id end
        out[#out + 1] = entry
      end
    end
    if #out >= Config.RANK_TOP then break end
  end
  return out
end

-- ------- mediated battles
--
-- The shapes the seven mmo.battle_* types carry.  They are sanitised on the
-- same rule as everything above -- rebuild the table, refuse the half-formed --
-- but the reason bites harder here, and it is worth saying once: these tables
-- are the **inputs to arithmetic**, not fields on a screen.
--
-- A bad name draws wrong and a bad map id places nothing; a bad `accuracy` is a
-- comparison against an RNG roll, and a party length nobody counted is a battle
-- with no last monster in it.  So nothing here is clamped into something
-- plausible and then used -- an out-of-range number is never rounded into range,
-- because the alternative is an intermediator resolving a fight from figures it
-- made up.
--
-- A field that is present and unreadable takes its whole message with it almost
-- everywhere here.  The one exception is BATTLE_EVENT, whose optional fields are
-- dropped instead, and the argument for that is written where it happens.
--
-- Four of these are read by the intermediator (RULESET, PARTY, CHOICE,
-- RECONNECT) and three by clients (READY, EVENT, OUTCOME), and both ends run
-- *this* file or its JS twin in server/lib/sanitize.js.  **The twins have to
-- accept and refuse the same bytes**, which is the tightest constraint in this
-- section: a party the hub took and the client threw away is a fight one end
-- thinks is running, and it fails with both processes behaving correctly.  Every
-- bound below has a named counterpart there -- so a rule added to one, however
-- prudent on its own, is a divergence until it is added to both.

-- The largest value one type-effectiveness cell may hold, as integer percent.
--
-- Percent rather than a float, because this number crosses a JSON boundary into
-- two languages and is then multiplied into a damage figure: 0.5 and 2 survive
-- that trip, but a chart that carried 0.1 would round differently on the two
-- ends and the same attack would do different damage depending on who was
-- hosting.  Integers multiply and divide identically everywhere.
M.CHART_MAX = 400

-- The six multipliers a Gen 1 chart is built out of.
--
-- **Not a gate.**  chartOf bounds a cell and does not check membership here, and
-- the reason is the legal posture rather than laziness: the chart arrives from a
-- player's own decoded data, a pack may legitimately rebalance a matchup to 75,
-- and refusing it would drop a coherent modded ruleset in the name of catching a
-- malformed one.  Gen 1's own cells only ever hold 0, 50, 100 or 200 -- the
-- quarter and the quadruple come out of *composing* two of them against a dual
-- type, in the sim, not out of the chart.
--
-- It is here for the sim and the fixtures to read, which is the same thing the
-- JS twin exports it for.  A checker that existed on only one of the two ends
-- would be a chart the hub refuses and a LAN host fights.
M.EFF_NEUTRAL = 100
M.EFF_MULTS = {
  [0] = true, [25] = true, [50] = true,
  [M.EFF_NEUTRAL] = true, [200] = true, [M.CHART_MAX] = true,
}

-- The seed the intermediator may be handed to run a match from.
--
-- 2^30, which is the width src/link's own shared seeds use, and a positive
-- lower bound because 0 is the value a missing field arrives as once something
-- upstream has helpfully defaulted it -- a "seed" every battle shares is the
-- one seed worth refusing outright.
M.SEED_MAX = 1073741824

-- What an event's `amount` may say: damage off a bar, or the size of a stat
-- change.  Unsigned, because which direction a stat moved is the event's kind
-- and its sentence rather than the sign of this field.
M.AMOUNT_MAX = 9999

-- How many shares an `exp` event may say a faint was split between.
--
-- A ceiling on a *divisor* a stranger sent, which is why it has a floor of one
-- as well: zero shares is not a smaller award, it is a division by zero inside
-- the client's own Experience formula.  Twelve rather than BATTLE_MON_MAX
-- because vanilla pays every mon that was ever in against the fallen foe and is
-- still alive, benched included -- so a co-op faint can be split across two
-- full parties: BATTLE_MON_MAX (6) * COOP_SIDE (2) = 12.  One number that
-- covers both shapes beats two that have to be kept in step; it bounds a
-- foreign value before it enters a formula, it does not restate a game rule.
M.PARTICIPANTS_MAX = 12

-- How long a reason token this build has never heard of may be.  Refused past it
-- rather than trimmed -- a cut token matches nothing and is a value nobody sent.
M.REASON_MAX = 32

-- The three indices in this vocabulary, and the widths that tell them apart.
--
--   SLOT_MAX   a *party* index -- which of your six.  What `mon.slot` and
--              `choice.slot` are bounded by.
--   FIELD_MAX  a position *on the field* -- four, because a party is a pair and
--              two parties meet.  What `choice.target` and `event.slot` are
--              bounded by: an event is about somebody who is out, not about a
--              bench position.
--
-- Written as offsets from Config's own numbers rather than as literals, so the
-- day PARTY_MAX moves the field moves with it instead of being a number
-- somebody has to remember.
--
-- **All of them are zero-based**, which is the one thing they do share, and it
-- is worth stating because guessing produces an off-by-one that silently spends
-- the wrong turn.
M.SLOT_MAX = Config.BATTLE_MON_MAX - 1
M.FIELD_MAX = Config.COOP_FIGHTERS - 1

-- The most HP, and the most of any single stat, a submitted battler may claim.
--
-- Named rather than written out at each of the four call sites: hp, maxHp and
-- the `hp` on a damage event are the same quantity seen from two ends of the
-- wire, and three literals that were meant to be one number are three chances
-- for the client to refuse what the intermediator sent.
--
-- Both are far above anything Gen 1 reaches (a level-100 CHANSEY tops out
-- around 700 HP), because the job here is bounding a stranger's number before
-- it enters a formula, not restating the game's own ceilings.
M.HP_MAX = 999
M.STAT_MAX = 999

-- Gen 1's status conditions, as three-letter tokens.
--
-- A closed set for the reason every closed set in this file is one: the sim
-- branches on it -- a sleeping battler does not move, a frozen one does not
-- thaw on its own, a burned one hits for half -- so a token nothing branches on
-- has no behaviour to give, and inventing one would be inventing a rule.
--
-- TOX is here alongside PSN because Gen 1 really does distinguish them (the
-- doubling toxic counter), even though both read as PSN on the status box.
M.STATUSES = {
  SLP = true, PSN = true, BRN = true, FRZ = true, PAR = true, TOX = true,
}

-- A battler's condition, where "healthy" is a real answer and so is "no".
--
-- **Three answers, and callers have to check for all three.**  nil for healthy,
-- the token itself when it is one, and `false` for a value that is present and
-- unrecognised.  nil and the empty string both mean healthy, because that is how
-- a client keeping no status field and one keeping a cleared field each spell it,
-- and neither is wrong.
--
-- The `false` is what earns the extra state.  Waving an unknown token through as
-- healthy would hand the sim a battler whose owner believes it is asleep and
-- whose intermediator believes it is fine, and the first turn would visibly
-- disagree with the box the player is looking at.
function M.battleStatus(value)
  if value == nil or value == "" then return nil end
  if M.STATUSES[value] then return value end
  return false
end

-- The type chart for one match: rows of integer-percent cells, rebuilt cell by
-- cell rather than measured and passed on.
--
-- Uniform rows, with both axes bounded by BATTLE_TYPE_MAX.  A ragged chart is the
-- failure that would not announce itself: the sim would read nothing out of the
-- short row and treat a super-effective matchup as neutral, in one direction
-- only.
--
-- Squareness is *not* checked, even though a chart is indexed
-- attacker-by-defender out of one type space.  What a type with no row means is a
-- question the sim has to answer regardless -- a move may name a type past the
-- chart's width, and reading that gap as neutral is its call -- so a rectangle of
-- numbers in range is what this function owes, and it is what makes the table
-- safe to walk at all.
local function chartOf(raw)
  if type(raw) ~= "table" then return nil end
  local rows, width = {}, nil
  for _, row in ipairs(raw) do
    if type(row) ~= "table" then return nil end
    if #rows >= Config.BATTLE_TYPE_MAX then return nil end
    local cells = {}
    for _, cell in ipairs(row) do
      if #cells >= Config.BATTLE_TYPE_MAX then return nil end
      local n = M.int(cell, 0, M.CHART_MAX)
      if not n then return nil end
      cells[#cells + 1] = n
    end
    if #cells == 0 then return nil end
    if width == nil then
      width = #cells
    elseif #cells ~= width then
      return nil
    end
    rows[#rows + 1] = cells
  end
  if #rows == 0 then return nil end
  return rows
end

-- The rules one mediated fight runs under: { chart, seed }.
--
-- Ephemeral, and that word is the legal posture rather than a performance note.
-- Nothing in this repo ships a type chart; it arrives from the authority
-- client's own decoded copy for this match and is thrown away with the battle.
--
-- The chart is the message; a seed is an offer.
--
-- `seed` is optional because the intermediator is the only party that rolls
-- anything and can perfectly well pick its own -- unlike the old lockstep pair,
-- there is no agreement about randomness here to get wrong.  But a seed that is
-- *present and unreadable* takes the message with it rather than being dropped: a
-- test or a replay sends one precisely because it needs that seed and no other,
-- so quietly substituting a different one would answer the request with a run
-- that looks right and reproduces nothing.
function M.battleRuleset(raw)
  if type(raw) ~= "table" then return nil end
  local chart = chartOf(raw.chart)
  if not chart then return nil end
  local out = { chart = chart }
  if raw.seed ~= nil then
    out.seed = M.int(raw.seed, 1, M.SEED_MAX)
    if out.seed == nil then return nil end
  end
  -- Optional Gen1 Special-type indices (0-based chart axis). Absent = all
  -- Physical. Present-but-unreadable refuses the ruleset rather than silently
  -- falling back to atk/def for a host that meant to upload the split.
  if raw.specialTypes ~= nil then
    if type(raw.specialTypes) ~= "table" then return nil end
    local special = {}
    for _, entry in ipairs(raw.specialTypes) do
      local t = M.int(entry, 0, Config.BATTLE_TYPE_MAX - 1)
      if t == nil then return nil end
      special[#special + 1] = t
    end
    out.specialTypes = special
  end
  -- Optional Metronome pick pool: full move sheets from the host's decode.
  if raw.metronomePool ~= nil then
    if type(raw.metronomePool) ~= "table" then return nil end
    local pool = {}
    for _, entry in ipairs(raw.metronomePool) do
      if #pool >= Config.BATTLE_METRONOME_POOL_MAX then break end
      local move = M.battleMove(entry)
      if not move then return nil end
      pool[#pool + 1] = move
    end
    out.metronomePool = pool
  end
  return out
end

-- One move, carrying everything needed to resolve it.
--
-- **There is no move table on either intermediator, and that is deliberate.**
-- Power, accuracy, type, effect and effect chance ride with the move rather
-- than being looked up by id, because a lookup table would be the ROM extract
-- this repo may not contain -- and because it is what lets a data pack's
-- rebalanced move resolve correctly on a hub that has never heard of it.  `id`
-- is along for narration and logs only; nothing branches on it.
--
-- Every field is required, and none of them defaults.  A move with no accuracy
-- is not a move that always hits, it is a move the sim cannot roll -- and the
-- difference between those two readings is a coin flip decided by whichever
-- one the twin happened to pick.  So the missing field refuses the move, the
-- move refuses the battler, and the battler refuses the party: one loud
-- failure at the boundary instead of a quiet one three formulas in.
--
-- `accuracy` is a byte because Gen 1's is: it is compared against a 0-255 roll,
-- which is the whole mechanism behind the 1-in-256 miss.  `type` is bounded
-- generously and independently of BATTLE_TYPE_MAX, so a party naming a type the
-- uploaded chart has no row for is still a well-formed party -- the sim reads
-- that gap as neutral, which is a far better answer than refusing somebody's
-- whole team over one mismatched index.
function M.battleMove(raw)
  if type(raw) ~= "table" then return nil end
  local out = {
    id = M.id(raw.id),
    pp = M.int(raw.pp, 0, 99),
    power = M.int(raw.power, 0, 999),
    accuracy = M.int(raw.accuracy, 0, 255),
    type = M.int(raw.type, 0, 31),
    effect = M.int(raw.effect, 0, 255),
    chance = M.int(raw.chance, 0, 100),
  }
  -- 0 is truthy in Lua, so this reads "present" and not "non-zero" -- which is
  -- the whole point, since 0 power and 0 chance are ordinary answers.
  if not (out.id and out.pp and out.power and out.accuracy and out.type
          and out.effect and out.chance) then
    return nil
  end
  if raw.maxPp ~= nil then
    out.maxPp = M.int(raw.maxPp, 0, 99)
    if out.maxPp == nil then return nil end
  end
  return out
end

-- Battle-stat keys on the sheet.  Gen 1 keeps one Special (`spc`) with Speed
-- as `spd`.  Gen 2 splits Special into Sp.Atk / Sp.Def (`spa` / `spd`) and
-- renames Speed to `spe` — so `spd` means different things in each dialect.
-- Both shapes are first-class; a classic four-key Gen 1 table must still
-- sanitise, and a Gen 2 spa/spd sheet must not be refused as "wrong game".
local STAT_KEYS_GEN1 = { "atk", "def", "spd", "spc" }
local STAT_KEYS_GEN2 = { "atk", "def", "spe", "spa", "spd" }

-- Which dialect a stats / ivs / evs block is in.
--
-- Prefer an explicit `generation` (1|2) on the mon (or stamped from the party
-- message).  Else sniff: `spa` or `spe` marks Gen 2; everything else — including
-- a classic atk/def/spd/spc table — is Gen 1.  Gen 1's `spd` (Speed) alone is
-- never enough to claim Gen 2, because that key is the Gen 1 name for Speed.
local function statsGeneration(raw, hint)
  local gen = M.int(hint, 1, 2)
  if gen then return gen end
  if type(raw) ~= "table" then return 1 end
  if raw.spa ~= nil or raw.spe ~= nil then return 2 end
  return 1
end

-- A full set for the dialect, or nothing.  Partial is refused rather than
-- filled in: every key is a multiplicand in the damage formula, and a
-- defaulted Defence is a made-up number that reads as a real one.
local function statsOf(raw, min, max, generation)
  if type(raw) ~= "table" then return nil end
  local keys = statsGeneration(raw, generation) == 2 and STAT_KEYS_GEN2
    or STAT_KEYS_GEN1
  local out = {}
  for _, key in ipairs(keys) do
    local n = M.int(raw[key], min, max)
    if not n then return nil end
    out[key] = n
  end
  return out
end

-- One battler, as its owner claims it.
--
-- **Sheet trust is a locked decision**, not a v1 TODO. A modified client can
-- send a level-100 team with 999 in every stat and the intermediator will
-- fight it.  What sanitising buys is not honesty, it is coherence -- every
-- number is a number, in a range the formulas survive, and the fight resolves
-- and ends.  Mid-fight cheating is what the intermediator removes; the
-- pre-fight sheet stays a client claim because the hub holds no ROM species
-- table and never will (legal floor / no ROM bytes).
--
-- **Bags (PROTOCOL 15).** The party message may carry an optional `bag` — a
-- list of `{id, count}` stacks. The hub stores it under the connection, holds
-- a stack when an `item` choice is accepted, and decrements only when the turn
-- resolves (so `cancel`/`unchose` never needs a refund). Entries must be ids
-- BattleSim knows (`itemEffect`), including vitamins (fight-local Stat Exp;
-- client writebacks `save.statExp` on confirm). Counts and battler sheets
-- remain a **claim**: a modified client can still invent 99 POTION or a god
-- team on upload. That is the accepted bound — mid-fight free heals without a
-- matching stack are what the bag removes. Absent `bag` means empty.
--
-- `hp` above `maxHp` is refused even though both are individually in range,
-- because it is the one incoherence that reaches arithmetic rather than a screen:
-- the HP bar and several formulas divide by maxHp, and a battler at 300/100 draws
-- a bar past its own box and starts the fight already impossible to describe.
-- `maxHp` therefore starts at 1 while `hp` starts at 0 -- a fainted monster is
-- ordinary, a monster with no capacity is not.
--
-- `slot`, `ivs` and `evs` are optional wholesale but not piecemeal, and an
-- unreadable one refuses the battler rather than being dropped: a snapshot from a
-- client that does not track EVs is fine and common, while a snapshot with two of
-- the four (or five) is a bug on the sending side that accepting would silently
-- zero the rest of.
--
-- Optional `generation` (1|2) selects the stats dialect; absent falls back to
-- shape sniff on `stats` (see statsGeneration). Optional `heldItem` is a Gen 2
-- item id string — cleaned like any other id, dropped when absent.
function M.battleMon(raw)
  if type(raw) ~= "table" then return nil end

  local generation = M.int(raw.generation, 1, 2)
  local stats = statsOf(raw.stats, 1, M.STAT_MAX, generation)
  if not stats then return nil end
  -- Dialect actually used (explicit or sniffed) — stamp so downstream sees it.
  if not generation then
    generation = stats.spa ~= nil and 2 or 1
  end

  local status = M.battleStatus(raw.status)
  if status == false then return nil end

  local out = {
    species = M.name(raw.species),
    level = M.int(raw.level, 1, M.LEVEL_MAX),
    hp = M.int(raw.hp, 0, M.HP_MAX),
    maxHp = M.int(raw.maxHp, 1, M.HP_MAX),
    stats = stats,
    status = status,
    generation = generation,
  }
  -- hp may be 0 (fainted); only nil means the field failed to sanitise.  In Lua
  -- 0 is truthy, but spell the check with `== nil` anyway so a reader coming
  -- from JS does not "fix" a working gate into a gate that refuses fainted mons.
  if out.species == nil or out.level == nil or out.hp == nil or out.maxHp == nil then
    return nil
  end
  if out.hp > out.maxHp then return nil end

  if raw.slot ~= nil then
    out.slot = M.int(raw.slot, 0, M.SLOT_MAX)
    if out.slot == nil then return nil end
  end
  if raw.ivs ~= nil then
    out.ivs = statsOf(raw.ivs, 0, 15, generation)
    if not out.ivs then return nil end
  end
  if raw.evs ~= nil then
    out.evs = statsOf(raw.evs, 0, 65535, generation)
    if not out.evs then return nil end
    -- Optional HP Stat Exp for HP_UP (battle-stat keys stay required).
    if raw.evs.hp ~= nil then
      out.evs.hp = M.int(raw.evs.hp, 0, 65535)
      if out.evs.hp == nil then return nil end
    end
  end

  if type(raw.moves) ~= "table" then return nil end
  local moves = {}
  for _, entry in ipairs(raw.moves) do
    if #moves >= Config.BATTLE_MOVE_MAX then return nil end
    local move = M.battleMove(entry)
    if not move then return nil end
    moves[#moves + 1] = move
  end
  if #moves == 0 then return nil end
  out.moves = moves

  -- Optional defender types as chart indices. Absent means the sim treats the
  -- mon as type 0 (neutral against an empty chart row). Present-but-unreadable
  -- refuses the mon, for the same reason a half-filled EV block does.
  if raw.types ~= nil then
    if type(raw.types) ~= "table" then return nil end
    local types = {}
    for _, entry in ipairs(raw.types) do
      if #types >= 2 then break end
      local t = M.int(entry, 0, Config.BATTLE_TYPE_MAX - 1)
      if t == nil then return nil end
      types[#types + 1] = t
    end
    if #types == 0 then return nil end
    out.types = types
  end

  -- Optional species catch rate for wild mediated balls (0-255).
  if raw.catchRate ~= nil then
    out.catchRate = M.int(raw.catchRate, 0, 255)
    if out.catchRate == nil then return nil end
  end

  -- Optional Gen 2 held item id. Absent is fine; present-but-unreadable
  -- refuses, same posture as a mangled types list.
  if raw.heldItem ~= nil then
    out.heldItem = M.id(raw.heldItem)
    if not out.heldItem then return nil end
  end

  return out
end

-- One combatant's team for one battle: { battle, side, mons, badges }.
--
-- The list is bounded and refused whole rather than delivered short, which is
-- M.members' rule for M.members' reason turned up a notch: a team the
-- intermediator quietly shortened is a fight the owner loses to a monster they
-- were told they had.
--
-- `side` is optional because a 1v1 has none to name -- there are two combatants
-- and the intermediator knows which is which from the session it brokered.  It is
-- required in practice for the two co-op modes, and that is the intermediator's
-- check to make rather than this one's: it is the only party that knows which
-- mode this battle is.  Present-and-malformed is still refused, because a side
-- nobody can read is not the same thing as a side nobody stated.
--
-- `bag` is optional: absent means an empty sheet (PROTOCOL 15). Present-but
-- unreadable refuses the party — a half-parsed bag would let the hub prove the
-- wrong inventory.
--
-- Optional `generation` (1|2) selects BattleSim vs BattleSim2 Effects for
-- itemEffect; omitted → Gen 1 (compat).
function M.battleBag(raw, generation)
  if raw == nil then return {} end
  if type(raw) ~= "table" then return nil end

  local Effects = effectsFor(generation)
  local out, seen = {}, {}
  -- Array form: [{id, count}, ...]. Map form (id -> count) is also accepted so
  -- a client that already holds inventory as a dict does not have to rebuild.
  local function push(id, count)
    if seen[id] then return false end
    if #out >= Config.BATTLE_BAG_MAX then return false end
    -- Only BattleSim-known battle items (vitamins included — fight-local EV).
    local effect = Effects.itemEffect(id)
    if not effect then return false end
    seen[id] = true
    out[#out + 1] = { id = id, count = count }
    return true
  end

  if #raw > 0 or raw[1] ~= nil then
    for _, entry in ipairs(raw) do
      if type(entry) ~= "table" then return nil end
      local id = M.id(entry.id)
      local count = M.int(entry.count, 1, Config.BATTLE_BAG_COUNT_MAX)
      if not id or count == nil then return nil end
      if not push(id, count) then return nil end
    end
  else
    for key, value in pairs(raw) do
      local id = M.id(key)
      local count = M.int(value, 1, Config.BATTLE_BAG_COUNT_MAX)
      if not id or count == nil then return nil end
      if not push(id, count) then return nil end
    end
  end

  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

function M.battleParty(raw, generation)
  if type(raw) ~= "table" then return nil end
  local battle = M.id(raw.battle)
  if not battle then return nil end

  local out = { battle = battle, badges = M.badges(raw.badges) }

  -- Hub generation (second arg) is authoritative when provided: stamp
  -- party.generation from it, and refuse a mon/party whose explicit
  -- generation disagrees.
  local hubGen = nil
  if generation ~= nil then
    hubGen = M.int(generation, 1, 2)
    if not hubGen then return nil end
  end

  local partyGen = nil
  if raw.generation ~= nil then
    partyGen = M.int(raw.generation, 1, 2)
    if not partyGen then return nil end
    if hubGen and partyGen ~= hubGen then return nil end
  end
  if hubGen then
    out.generation = hubGen
    partyGen = hubGen
  elseif partyGen then
    out.generation = partyGen
  end

  if raw.side ~= nil then
    out.side = M.side(raw.side)
    if not out.side then return nil end
  end

  if type(raw.mons) ~= "table" then return nil end
  local mons = {}
  for _, entry in ipairs(raw.mons) do
    if #mons >= Config.BATTLE_MON_MAX then return nil end
    local hadExplicit = type(entry) == "table" and entry.generation ~= nil
    if hubGen and hadExplicit then
      local monGen = M.int(entry.generation, 1, 2)
      if not monGen or monGen ~= hubGen then return nil end
    end
    local sheet = entry
    if partyGen and type(entry) == "table" and entry.generation == nil then
      sheet = {}
      for k, v in pairs(entry) do sheet[k] = v end
      sheet.generation = partyGen
    end
    local mon = M.battleMon(sheet)
    if not mon then return nil end
    if hubGen and hadExplicit and mon.generation ~= hubGen then return nil end
    mons[#mons + 1] = mon
  end
  if #mons == 0 then return nil end
  out.mons = mons

  local bag = M.battleBag(raw.bag, partyGen or hubGen)
  if not bag then return nil end
  out.bag = bag

  return out
end

-- What a player may ask for on their turn, and which field each ask needs in
-- order to mean anything.  `true` means the action is complete on its own.
--
-- Required-field-per-action rather than a check beside it, exactly as
-- M.PARTY_EVENTS is shaped and for the same reason: the incomplete case is the
-- one that reaches a player.  A `fight` with no move index is not a defaultable
-- choice -- picking a move for somebody would be choosing their turn for them,
-- and doing nothing would stall a clock that forfeits.
--
-- `cancel` is a real action rather than the absence of one: a player backing out
-- of a choice they already submitted is something the turn machine has to be
-- told about, because it is holding a deadline open on their behalf.
M.BATTLE_ACTIONS = {
  fight  = "move",
  item   = "item",
  switch = "slot",
  run    = true,
  cancel = true,
}

-- One player's intent for one turn.  A choice and never a result: nothing here
-- says what happened, only what was pressed.
--
-- Note what is absent: there is no "who am I" field.  Which combatant this is
-- comes from the connection it arrived on, the same way PARTY_EVENT's name does,
-- because an id in the payload is an id a modified client could set to somebody
-- else's and spend their turn.
--
-- The three indices are all zero-based and all differently bounded -- see the
-- note at M.SLOT_MAX for which is which.  A present-but-out-of-range one refuses
-- the choice rather than being dropped, because dropping it would turn a `fight`
-- into an action with no move and stall a clock that forfeits.
function M.battleChoice(raw)
  if type(raw) ~= "table" then return nil end
  local needs = M.BATTLE_ACTIONS[raw.action]
  if not needs then return nil end
  local battle = M.id(raw.battle)
  if not battle then return nil end

  local out = { battle = battle, action = raw.action }

  if raw.slot ~= nil then
    out.slot = M.int(raw.slot, 0, M.SLOT_MAX)
    if out.slot == nil then return nil end
  end
  if raw.move ~= nil then
    out.move = M.int(raw.move, 0, Config.BATTLE_MOVE_MAX - 1)
    if out.move == nil then return nil end
  end
  if raw.target ~= nil then
    out.target = M.int(raw.target, 0, M.FIELD_MAX)
    if out.target == nil then return nil end
  end
  if raw.item ~= nil then
    out.item = M.id(raw.item)
    if not out.item then return nil end
  end

  if needs ~= true and out[needs] == nil then return nil end
  return out
end

-- Everything a mediated fight can tell a client to draw.
--
-- A closed set, and the vocabulary is the contract between the intermediator's
-- turn machine and the screen: an unknown kind has no animation, no sentence
-- and no state change to apply, so it is refused rather than logged and
-- ignored -- an event nothing draws is a turn the two players saw differently.
--
--   msg        -- a line of text for the box
--   anim       -- play a move's animation
--   damage     -- HP came off a slot
--   drain      -- ...and some of it went onto another one
--   faint      -- a slot is out
--   send       -- a slot's next monster is on the field
--   status     -- a condition was inflicted or cleared
--   stat       -- a stat stage moved
--   switch     -- a voluntary swap resolved
--   item       -- a bag item was used
--   run        -- somebody fled, or tried
--   turn       -- a new turn is open; choices are wanted
--   over       -- the field is done; an OUTCOME is coming
--   wait       -- the fight is paused on somebody, and who
--   reconnect  -- a side that had dropped is back
--   chose      -- a seat filed this turn's answer (wait-line peer accuracy)
--   unchose    -- cancel cleared a filed answer
--   moves      -- mid-fight move-list sync after Transform/Mimic
--   exp        -- a faint's spoils, as facts: who fell (species, level), how
--                 many shares split it, and which of the paid side's six is
--                 banking this share (`mon`, optional).  Not an amount: the hub
--                 holds no species table and can never compute one, so the
--                 referee states the facts and each client runs its own
--                 Experience formula over its own party.
M.BATTLE_EVENTS = {
  msg = true, anim = true, damage = true, drain = true, faint = true,
  send = true, status = true, stat = true, switch = true, item = true,
  run = true, turn = true, over = true, wait = true, reconnect = true,
  chose = true, unchose = true, moves = true, exp = true,
}

-- One thing to draw.
--
-- Optional fields here are **dropped rather than fatal**, which is the one place
-- in this section that bends its own rule -- so here is why.  Every other
-- sanitised message is a fact some module stores; an event is an instruction in
-- an ordered stream, and `seq` is what makes the stream readable.  Refusing an
-- event over a mangled `text` would put a hole in that sequence, and a hole is
-- exactly what a client is built to read as lost messages: it would ask for a
-- resync over a cosmetic field.  A blank in a sentence costs one line; a false
-- gap costs the battle a round trip and a warning about a hub that is fine.
--
-- Unknown keys are dropped by construction -- the table is rebuilt from the
-- whitelist, so a field the intermediator invents next version arrives at a
-- client that never sees it.  That is deliberate: a whitelist is a vocabulary
-- both twins can mirror exactly, whereas passing an opaque blob through would
-- be handing a screen fields nothing had checked.
--
-- `text` borrows MESSAGE_MAX: it lands in the same box a chat line does and is
-- drawn by the same code, even though an intermediator wrote it rather than a
-- player.
--
-- `seq` has a floor and no ceiling.  It is only ever compared, never sized, so an
-- absurdly large one sorts late and does nothing else -- whereas a cap would be a
-- battle length nobody chose.
function M.battleEvent(raw)
  if type(raw) ~= "table" then return nil end
  if not M.BATTLE_EVENTS[raw.t] then return nil end
  local battle = M.id(raw.battle)
  local seq = M.int(raw.seq, 0)
  if not (battle and seq) then return nil end

  local out = { battle = battle, seq = seq, t = raw.t }
  -- Item / anim `text` is an id (POKE_BALL, TOSS_ANIM, move id) — M.text strips `_`.
  if raw.text ~= nil then
    if raw.t == "item" or raw.t == "anim" then
      out.text = M.id(raw.text)
    else
      out.text = M.text(raw.text, Config.MESSAGE_MAX)
    end
  end
  if raw.amount ~= nil then out.amount = M.int(raw.amount, 0, M.AMOUNT_MAX) end
  -- A field slot here, unlike the party index a choice carries under the same
  -- name: an event is about somebody who is out, not about a bench position.
  if raw.slot ~= nil then out.slot = M.int(raw.slot, 0, M.FIELD_MAX) end
  if raw.hp ~= nil then out.hp = M.int(raw.hp, 0, M.HP_MAX) end
  -- `exp` carries the facts a client needs to run its own award: which monster
  -- fell and how many shares split it.  Same sanitisers a battler's own fields
  -- get (M.name / M.int over LEVEL_MAX), because they are the same quantities
  -- read off the same monster -- an event is not a second dialect for them.
  if raw.species ~= nil then out.species = M.name(raw.species) end
  if raw.level ~= nil then out.level = M.int(raw.level, 1, M.LEVEL_MAX) end
  if raw.participants ~= nil then
    -- Deliberately not `winners`: an OUTCOME's winners is a list of player ids,
    -- and one name over two shapes is the sanitiser bug that reads a count as a
    -- roster.  This one is a count, and it divides.
    out.participants = M.int(raw.participants, 1, M.PARTICIPANTS_MAX)
  end
  -- Which of the winner's six the award is *for* -- a **party** index, bounded
  -- by SLOT_MAX, and so the one field on an event that is not about the field.
  -- It has to be: vanilla pays every mon that fought the fallen foe and lived,
  -- and a benched one has no field slot to name.  `slot` above still carries
  -- the owning fighter's seat, which is what gates the award to a player;
  -- `mon` says which of that player's monsters banks it.
  --
  -- Optional, and its absence is meaningful rather than a defect: a PROTOCOL 21
  -- referee that predates this field pays the mon that was standing at the
  -- faint, so a client that gets no `mon` falls back to the active one.
  if raw.mon ~= nil then out.mon = M.int(raw.mon, 0, M.SLOT_MAX) end
  if raw.side ~= nil then out.side = M.side(raw.side) end
  if raw.status ~= nil then
    -- battleStatus answers `false` for present-but-unknown, which is not a
    -- status and must not be stored as one.
    out.status = M.battleStatus(raw.status) or nil
  end
  if type(raw.moves) == "table" then
    local moves = {}
    for _, entry in ipairs(raw.moves) do
      if #moves >= Config.BATTLE_MOVE_MAX then break end
      local move = M.battleMove(entry)
      if move then moves[#moves + 1] = move end
    end
    if #moves > 0 then out.moves = moves end
  end
  return out
end

-- The reasons a mediated fight ends that a screen currently has a sentence for.
--
--   timeout    -- nobody answered inside BATTLE_CHOICE_TIMEOUT
--   disconnect -- a side dropped and BATTLE_RECONNECT_GRACE ran out
--   run        -- somebody fled
--   ko         -- the ordinary one: a side has nothing left standing
--   agree      -- both sides called it
--   forfeit    -- a side gave up on purpose
--
M.BATTLE_REASONS = {
  timeout = true, disconnect = true, run = true,
  ko = true, agree = true, forfeit = true, catch = true,
}

-- The reason, with room for one this build has never heard of.
--
-- The closed set first, then a short bare token as a fallback -- and the fallback
-- is the design, not laziness.  A reason is *narration*: it picks which sentence
-- the end-of-battle box shows and nothing else.  If a newer intermediator names a
-- reason this build cannot phrase, refusing the whole outcome would leave the
-- battle open forever on a screen with no way out, over a field that was only
-- ever a caption.  So an unknown reason survives as a token the box quietly
-- declines to print, and the result -- the part that matters -- still lands.
--
-- Refused rather than trimmed past 32, on M.spriteId's argument: a cut token
-- matches nothing and is a value nobody sent.
function M.battleReason(value)
  if M.BATTLE_REASONS[value] then return value end
  if type(value) ~= "string" then return nil end
  if #value > M.REASON_MAX then return nil end
  return M.id(value)
end

-- A short list of player ids: who is on a side, who won, who lost.
--
-- Refused whole rather than filtered -- the opposite of how badges are treated,
-- deliberately.  A badge that fails to clean is inert, because the boost table
-- walks its own rows and asks the set, so a dropped entry costs one stat
-- multiplier.  A roster is who receives events and whose rating moves, so a name
-- that fails to clean or a list longer than a side can hold is a message that
-- would put a fight on the field with the wrong people in it -- a winners list
-- missing a name is a fight somebody won and was not told about.  Refusing is
-- loud, and loud is the failure to prefer.
local function idList(raw, max)
  if type(raw) ~= "table" then return nil end
  if #raw < 1 or #raw > max then return nil end
  local out = {}
  for _, entry in ipairs(raw) do
    local id = M.id(entry)
    if not id then return nil end
    out[#out + 1] = id
  end
  return out
end

-- How the fight ended, from the only party that knows.
--
-- **This replaces the two-client vote.**  mmo.result exists because neither
-- peer in a relayed battle could be believed about its own win, so the hub
-- scored nothing until both said the same thing.  Here the intermediator did
-- every roll, so it is the only party with an opinion worth having -- and a
-- client's mmo.result about a mediated fight is ignored rather than weighed.
--
-- `winners` and `losers` are optional because a 1v1 does not need them: the
-- outcome is stated from the recipient's own point of view and there is exactly
-- one other player.  A 2v2 does need them, since "loss" alone does not say which
-- pair, and a rank settle has four ids to move.  Present-and-malformed refuses
-- the message: these are the names a rating moves for.
function M.battleOutcome(raw)
  if type(raw) ~= "table" then return nil end
  local battle = M.id(raw.battle)
  local outcome = M.outcome(raw.outcome)
  if not (battle and outcome) then return nil end

  local out = { battle = battle, outcome = outcome }
  if raw.winners ~= nil then
    out.winners = idList(raw.winners, Config.COOP_FIGHTERS)
    if not out.winners then return nil end
  end
  if raw.losers ~= nil then
    out.losers = idList(raw.losers, Config.COOP_FIGHTERS)
    if not out.losers then return nil end
  end
  if raw.reason ~= nil then
    out.reason = M.battleReason(raw.reason)
    if not out.reason then return nil end
  end
  -- Optional catch sheet: battleMon-shaped snapshot for clients that did not
  -- keep the wild mon locally. Absent is fine; present-and-bad refuses.
  if raw.caught ~= nil then
    out.caught = M.battleMon(raw.caught)
    if not out.caught then return nil end
  end
  -- Optional catcher: who keeps the mon on a coop_wild catch. Absent is fine
  -- (solo wild / KO outcomes need no thrower); present-and-bad refuses the
  -- whole outcome -- same posture as winners/losers, since this is the name
  -- a grant moves for.
  if raw.catcher ~= nil then
    out.catcher = M.id(raw.catcher)
    if not out.catcher then return nil end
  end
  return out
end

-- "I dropped, and I am back": { battle }.
--
-- It names the fight even though a player is only ever in one -- the opposite
-- of COOP_LEAVE's argument, and for a reason that only applies to this message.
-- The sender has been *away*, possibly on a new socket, so the intermediator
-- cannot read which battle this is off a connection it has only just met.  The
-- one field is what turns a stranger's reconnect into a resume.
function M.battleReconnect(raw)
  if type(raw) ~= "table" then return nil end
  local battle = M.id(raw.battle)
  if not battle then return nil end
  return { battle = battle }
end

-- The shapes a mediated fight comes in.
--
--   1v1       -- two players, one monster each
--   coop_npc  -- a party of two against a trainer somebody walked into
--   coop_pvp  -- two parties against each other
--   wild      -- one player against one hub NPC seat (catch/run legal;
--               protocol-only; no overworld divert)
--   coop_wild -- two humans vs one wild NPC seat (catch/run legal; overworld
--               divert when partied + same map — seating lands in a later wave)
--
-- Named on the wire rather than inferred from how many ids arrived, because the
-- two co-op modes have the same four field slots and differ only in whether one
-- side has an owner -- and "guess the mode from the roster" is the kind of
-- inference that is right until an NPC battle happens to have a spectatorless
-- second slot.
M.BATTLE_MODES = {
  ["1v1"] = true, coop_npc = true, coop_pvp = true, wild = true, coop_wild = true,
}

function M.battleMode(value)
  if M.BATTLE_MODES[value] then return value end
  return nil
end

-- The field is assembled and the first turn is open.
--
-- The sides are named by the intermediator because it is the only party to the
-- exchange that knows every combatant uploaded a party and is still connected
-- at the moment it says so -- M.COOP_BATTLE's argument, now made by a process
-- that is not also one of the players.
--
-- Both sides are required, even in a coop_npc fight where one of them is a
-- trainer with no player behind it: the ids on that side are whoever submitted
-- it, which is who a choice for those slots may arrive from.
function M.battleReady(raw)
  if type(raw) ~= "table" then return nil end
  local battle = M.id(raw.battle)
  local mode = M.battleMode(raw.mode)
  if not (battle and mode) then return nil end
  if type(raw.sides) ~= "table" then return nil end
  local a = idList(raw.sides.a, Config.COOP_SIDE)
  local b = idList(raw.sides.b, Config.COOP_SIDE)
  if not (a and b) then return nil end
  return { battle = battle, mode = mode, sides = { a = a, b = b } }
end

return M
