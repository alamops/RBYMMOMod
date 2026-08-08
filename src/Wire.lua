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
-- COOP_WAIT carries { battle, label, map } -- the fight this player is
-- standing in front of.  COOP_CANCEL withdraws it and takes no fields: there
-- is only ever one offer per player, so naming which would be a second way to
-- be wrong.  COOP_JOIN answers somebody else's offer with { to, battle }.
--
-- **There is no "decline" going this way, and that is the design.**  A player
-- who says no to joining sends nothing at all, which is exactly what makes no
-- non-binding: no state is written anywhere, so the next time they walk into
-- the same fight the ask is simply made again.  A refusal that left a trace
-- would have to be cleared by something, and whatever cleared it would be the
-- thing that eventually got it wrong.
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
-- { from, name, battle, label, map }.  COOP_OFFER_END withdraws it, and
-- carries a reason so the partner's client can tell "they went in alone" from
-- "they walked away" -- two things that look identical from the outside and
-- read very differently to the person who was going to join.
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
--   * the slot **count**, because `buildField` only ever checked it on the
--     sending side -- so a modified host could send fifty and every client
--     would build fifty;
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
  if #raw.slots ~= Config.COOP_FIGHTERS then return nil end

  local slots = {}
  for i = 1, Config.COOP_FIGHTERS do
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

-- A co-op offer as it reaches the partner.  `label` is what the box calls the
-- fight ("BUG CATCHER") and is prose; `battle` is the key and is not.  A
-- missing label is fine and common -- a script-driven battle need not name its
-- trainer -- so it degrades to nil and the screen says "a battle" instead of
-- refusing the whole offer over a cosmetic field.
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
