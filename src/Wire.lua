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

-- Effects for bag proofs: Gen1 default, Gen2 when hub generation is 2, and
-- Gen 3's catalog when it is 3.  Gen 3 has no `Effects.itemEffect`: its bag is
-- BattleSim3/Items.BAG keyed by numeric pret item id (docs/plans/
-- gen3-battle-sheet.md §4), so it is put behind the same one-function shape
-- here rather than every caller learning a second one.
-- Lazy so a Gen1-only load never pulls BattleSim2 or BattleSim3.
local effectsByGen = {}
local function effectsFor(generation)
  local key = (generation == 2 or generation == 3) and generation or 1
  local cached = effectsByGen[key]
  if cached then return cached end
  local Effects
  if key == 3 then
    local Items = need("BattleSim3/Items")
    Effects = { itemEffect = function(id) return Items.bagEffect(id) end }
  else
    Effects = need(key == 2 and "BattleSim2/Effects" or "BattleSim/Effects")
  end
  effectsByGen[key] = Effects
  return Effects
end
M.effectsFor = effectsFor

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
-- `timeout` from the waiter; `no` from the partner who declined the invite;
-- `skip` from a partner who turned that kind of coop off -- does *not*
-- end the wait, so a remaining partner can still join).
-- Naming which offer is unnecessary: there is only ever one per player.
-- COOP_JOIN answers somebody else's offer with { to, battle }.
--
-- A partner decline (`COOP_CANCEL` reason `no`) is forwarded to the waiter as
-- `COOP_DECLINE`, so they can leave the wait and fight the trainer alone.
-- `skip` is recorded on the waiter's offer and is not a decline.
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
-- Somebody accepted yours: { id, name [, plan] [, allies] }.  This is the
-- message that ends the waiting, and the only one that does.  Optional
-- `allies` is the seated roster (host + joiner + anyone who did not skip);
-- absent on older hubs, where the host falls back to the whole party.
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
-- Mid-fight moveset for one of the sender's own party members: { battle, mon,
-- moves }. `mon` is the 0-based uploaded-sheet index, the same space `exp.mon`
-- and a switch `slot` already use. The referee holds no learnset, so a level-up
-- that teaches (or a forget that replaces) can only be applied by the client
-- that owns the save copy -- and without this type the FIGHT menu and the
-- hub's sheet stay on the upload forever. Who it is from is the connection;
-- a payload naming somebody else's seat is not a field this message has.
M.BATTLE_MOVESET = "mmo.battle_moveset"

M.FACINGS = { up = true, down = true, left = true, right = true }
M.KINDS = { trade = true, battle = true }

-- Why an invite came back refused, when the refusal was not a human pressing
-- NO.  A closed set rather than free text, for the reason COOP_REASONS is
-- one: every value picks a different sentence on the asker's screen, and an
-- unknown one has nothing to draw.
--
-- **Absent is the important value.** No reason means a person read the box
-- and said no, which is the only refusal that was ever worth the flat "X
-- refused to battle." Every other one is a fact about the moment -- they are
-- mid-fight, mid-trade, already holding somebody else's ask, or no longer
-- here -- and telling the asker which is the difference between a sentence
-- they can act on and one that reads as a snub.
--
--   fighting  -- a battle is on their screen (their own wild/trainer fight
--                counts: it is why this set exists)
--   busy      -- a trade or battle session, or an ask of their own out
--   asked     -- somebody else's invite is already on their screen
--   gone      -- the hub could not deliver it: they have left
M.DECLINE_REASONS = {
  fighting = true, busy = true, asked = true, gone = true,
}

function M.declineReason(value)
  if M.DECLINE_REASONS[value] then return value end
  return nil
end
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

-- A referee's battle line: M.text's set, plus the few glyphs the carts' own
-- battle text is spelled with (wave 6 of docs/plans/gen12-referee-gaps-fix.md).
--
--   é   POKéMON, POKé BALL, POKéMANIAC -- pokered charmap $BA, pokecrystal /
--       pokegold $EA.  The Gold referee prints "Both POKéMON will faint in 3
--       turns!" (PerishSongText) and "Enemy POKéMON's LIGHT SCREEN fell!"
--       (BattleText_MonsLightScreenFell); M.text cut them to "POKMON".
--   …   charmap $75 in both carts: Gold's "ignored orders…sleeping!"
--       (IgnoredSleepingText) and "It's not very effective…".
--   ♂ ♀ charmap $EF / $F5: the trainer classes the NPC seat's name carries
--       into the referee's AI item line (pokered TrainerNames "JR.TRAINER♂",
--       "COOLTRAINER♀"; Gold's "SWIMMER♂").
--   &   pokecrystal / pokegold $E9: a Gold trainer's own name ("TWINS AMY &
--       MAY", data/trainers/parties.asm) -- ASCII, and the one other glyph a
--       line can carry.  Red's charmap has no "&", and no Red name spells one.
--
-- A reader of its own rather than a wider M.text, because M.text is the
-- allowlist that keeps *player-typed* text -- chat, presence and friend names,
-- the rank board, room and server names -- inside the font, and none of those
-- gains anything from these glyphs while every one of them is a string
-- somebody else chose.  Only a line the referee composed, or the trainer name
-- it composes one from (M.npcName), reads through here.
--
-- Twin of lib/sanitize.js's cleanBattleText, **byte for byte on every input**,
-- which is why it walks bytes rather than using a pattern: a multi-byte glyph
-- is kept only as its whole UTF-8 sequence (C3 A9, E2 80 A6, E2 99 82,
-- E2 99 80) and every other byte at or past 0x80 is dropped alone.  Node
-- decodes an inbound line by the WHATWG rules, so a stray or truncated
-- sequence there is one U+FFFD per maximal subpart -- dropped -- and a lead
-- byte C3 / E2 can never be a continuation byte, so it always starts a fresh
-- character on that side too: the two twins keep the same glyphs at the same
-- places whatever bytes arrive.  The cut counts glyphs, not bytes (JS's
-- slice counts the one UTF-16 unit each of these is): `sub` would split
-- "POKéMON" inside the é and cut a byte-counted line short of a glyph-counted
-- one.  Spaces collapse and trim exactly as M.text's do.
M.BATTLE_GLYPHS = {
  ["\195\169"] = true,          -- é  U+00E9
  ["\226\128\166"] = true,      -- …  U+2026
  ["\226\153\130"] = true,      -- ♂  U+2642
  ["\226\153\128"] = true,      -- ♀  U+2640
}
local BATTLE_ASCII = "[A-Za-z0-9 %.,!%?'%-:;%(%)/&]"

-- A battle line's two marks of its own (contracts K17 / K18 of
-- docs/plans/gen12-referee-remaining-gaps.md), read by M.battleLine alone:
--
--   ^a ^b  a name mark: the referee writes it immediately before a battler's
--          name wherever the cart prints that name through a prefixing macro
--          (pokered <USER> / <TARGET> -- PlaceMoveUsersName /
--          PlaceMoveTargetsName -- and its "Enemy @" lines; pokecrystal
--          <USER> / <TARGET> / <ENEMY> -- PlaceBattlersName /
--          PlaceEnemysName), the letter naming the monster's side.  The
--          viewer prints "Enemy " / "Wild " or nothing for it, so a mark is
--          only ever a `^` with its side letter after it: a `^` followed by
--          anything else is dropped, alone, and the glyphs after it read as
--          they would have.
--   ^A ^B  a side-word mark (K17's wave-2 bullet): where the cart prints a
--          *side* word rather than a battler's name -- pokecrystal
--          HandleScreens' `.Your` / `.Enemy` ahead of "#MON's LIGHT SCREEN
--          fell!", and any other `Your@` / `Enemy@` pair of the Gold
--          referee's -- the capital names the side, and the viewer prints
--          "Your " for its own side and "Enemy " for the other.  Kept, cut
--          and dropped exactly as the lower-case pair is.
--   \n     the cart's `line` / `cont` inside one paragraph (a `para` is a
--          separate `msg`).  Held like a space -- never leading, trailing or
--          doubled -- and a space beside it collapses into it.
--
-- `^` is never a name glyph: M.text's set and this file's name readers
-- (M.name, M.npcName, M.moveName, M.label) have no `^`, and only the battle
-- line reads one -- so a player, nickname or trainer can never spell a mark.
M.BATTLE_MARK = "^"
M.BATTLE_MARK_SIDES = { a = true, b = true, A = true, B = true }

-- The walker both readers share.  `line` reads the two marks above; without
-- it, it is M.battleText exactly as it was.  A line cut at `cap` loses what
-- would hang off its end -- a space or break the cut glyph was waiting for, a
-- `^` whose letter fell past the cut, a mark whose name did -- so a cut line
-- still holds only marks with a side and breaks between words.
local function battleGlyphs(value, cap, line)
  if type(value) ~= "string" then return nil end
  local glyphs, gap = {}, nil
  local i, n = 1, #value
  while i <= n do
    local byte, glyph, step = value:byte(i), nil, 1
    if byte < 128 then
      local c = value:sub(i, i)
      if c:find(BATTLE_ASCII) then
        glyph = c
      elseif line and c == "\n" then
        glyph = c
      elseif line and c == M.BATTLE_MARK and M.BATTLE_MARK_SIDES[value:sub(i + 1, i + 1)] then
        glyph = c
      end
    elseif M.BATTLE_GLYPHS[value:sub(i, i + 1)] then
      glyph, step = value:sub(i, i + 1), 2
    elseif M.BATTLE_GLYPHS[value:sub(i, i + 2)] then
      glyph, step = value:sub(i, i + 2), 3
    end
    i = i + step
    -- A space or a break is held until a glyph follows it: a run collapses to
    -- one -- a break when the run holds one -- and none is written at either end.
    if glyph == " " or glyph == "\n" then
      if #glyphs > 0 and gap ~= "\n" then gap = glyph end
    elseif glyph then
      if gap then glyphs[#glyphs + 1] = gap end
      gap = nil
      glyphs[#glyphs + 1] = glyph
    end
  end
  if #glyphs == 0 then return nil end
  if #glyphs > cap then
    for k = #glyphs, cap + 1, -1 do glyphs[k] = nil end
    while line and #glyphs > 0 do
      local last = glyphs[#glyphs]
      if last == " " or last == "\n" or last == M.BATTLE_MARK then
        glyphs[#glyphs] = nil
      elseif glyphs[#glyphs - 1] == M.BATTLE_MARK then
        glyphs[#glyphs], glyphs[#glyphs - 1] = nil, nil
      else
        break
      end
    end
    if #glyphs == 0 then return nil end
  end
  return table.concat(glyphs)
end

function M.battleText(value, limit)
  return battleGlyphs(value, limit or Config.MESSAGE_MAX, false)
end

-- A Red / Gold referee's battle line (K17 / K18): M.battleText's glyphs, its
-- name marks and its breaks, cut at BATTLE_LINE_MAX glyphs -- a mark is two of
-- them and a break one.  The reader of an older `msg` event's text
-- (M.battleEvent) and of nothing else: no name and no Gen 3 line reads marks.
-- Twin of lib/sanitize.js's cleanBattleLine, byte for byte on every input.
function M.battleLine(value, limit)
  return battleGlyphs(value, limit or Config.BATTLE_LINE_MAX, true)
end

-- The same line as one plain sentence: each mark gone -- a name mark and a
-- side-word mark alike (`^a` `^b` `^A` `^B`) -- and each break a space, or
-- nothing after a hyphen, the word the cart split over two rows
-- (pokecrystal's "It's super-" / line "effective!") -- for whatever reads a
-- line's words rather than drawing it: a matcher that asks "is this the
-- weather line?", a driver, a test.  Anything that is not a string comes back
-- as it went in.  Twin of lib/sanitize.js's plainBattleLine.
function M.plainBattleLine(text)
  if type(text) ~= "string" then return text end
  local plain = text:gsub("%^[abAB]", ""):gsub("%-\n", "-"):gsub("\n", " ")
  return plain
end

-- The trainer an NPC seat is (wave 6): the name the cart's own lines print for
-- the computer, which the client sends with the side-"b" party (M.battleParty,
-- `name`) and the hub hands the referee as that seat's `name` -- pokered's
-- AIBattleUseItemText prints wTrainerName ("<TRAINER> used <ITEM> on <MON>!").
-- Read as a battle line's glyphs (M.battleText) because it is printed inside
-- one, and capped at NPC_NAME_MAX rather than NAME_MAX: a player's ten
-- characters cut "COOLTRAINER♂" (pokered TRAINER_NAME_LENGTH 13, so twelve) and
-- every Gold "<CLASS> <NAME>" (PlaceEnemysName: wOTClassName, a space, then the
-- trainer's name -- TRAINER_CLASS_NAME_LENGTH 13 and NAME_LENGTH 11, so
-- 12 + 1 + 10 = 23).  Twin of lib/sanitize.js's cleanNpcName / NPC_NAME_MAX.
M.NPC_NAME_MAX = 23

function M.npcName(value)
  return M.battleText(value, M.NPC_NAME_MAX)
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

-- What a move is *called*, as opposed to what identifies it.
--
-- Prose, so it borrows M.text -- but with MOVE_NAME_MAX rather than NAME_MAX,
-- because a move name is not a player name and ten characters cuts
-- "THUNDERSHOCK" to "THUNDERSHO".  The id beside it stays M.id: the two are
-- different fields doing different jobs (see M.battleMove).
function M.moveName(value)
  return M.text(value, Config.MOVE_NAME_MAX)
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
--
-- Refused past 40 characters, never cut (contract K13 of
-- docs/plans/gen12-referee-gaps-fix.md): server/lib/sanitize.js's cleanId is
-- /^[\w-]{1,40}$/ and has always thrown a longer one away, and a Lua side that
-- truncated instead accepted, stored and re-broadcast an id the node hub had
-- refused -- one party fought on the LAN host and refused on the dedicated
-- hub.  A cut id is no id anyway: it indexes no table the full one was a key
-- of (a move's animation, an item's record, a defeat flag), so all the cut
-- ever bought was a key that looked right and matched nothing.  M.spriteId's
-- argument, made for every id.
function M.id(value)
  if type(value) ~= "string" then return nil end
  if #value > 40 then return nil end
  if not value:match("^[%w_%-]+$") then return nil end
  return value
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

-- Boot generation claimed on mmo.hello (PROTOCOL 20; 3 from PROTOCOL 30).
--
-- 1, 2 or 3.  **Missing is 1**: that is the one-release compat reading
-- PROTOCOL 20 made so a legacy-shaped hello still joins a Gen 1 hub, and it
-- stays -- Wire.lua cannot tell an old client from a new one that forgot, and
-- a Gen 1 player is the one who must not be locked out by it.
--
-- **Present but unknown is nil, never 1.**  4, 0, "gen3", a table: none of
-- them is a generation, and reading one as Gen 1 is exactly how a FireRed
-- client -- whose 3 was out of the old 1..2 range -- was *admitted* into a
-- Red room under PROTOCOL 29 instead of refused.  A hub that guesses a
-- generation it does not know repeats that for whichever one comes next, so
-- the hello handler refuses nil with the same sentence it refuses a mismatch.
--
-- A JSON number only, the way server/lib/sanitize.js cleanGeneration reads
-- the same bytes.  Every client sends a number, and the looser readings are
-- where two languages part: JavaScript's Number(true) is 1 and Number([2])
-- is 2, where Lua's tonumber says nil to both, and a string is a number to
-- either only by its own rules ("0b11" is 3 to LuaJIT's tonumber) -- one
-- hello, admitted by one hub and refused by its twin.
M.GENERATION_MAX = 3

function M.generation(value)
  if value == nil then return 1 end
  if type(value) ~= "number" then return nil end
  return M.int(value, 1, M.GENERATION_MAX)
end

-- The cart a hello was sent from (PROTOCOL 30), and the generation each one
-- belongs to.  GameVersion's own ids, lower case, and a closed set on both
-- hubs (server/lib/sanitize.js VERSIONS) for the reason every vocabulary here
-- is one: a viewer does something different for each value, and an unknown
-- one has nothing to do.
--
-- It exists for Gen 3.  One Gen 3 hub seats FireRed, LeafGreen and Emerald
-- together, and their overworld graphics share no player name -- FireRed
-- draws its hero as OBJ_EVENT_GFX_RED_NORMAL, Emerald has no such name -- so
-- a viewer maps a partner's sprite through the cart it came from
-- (Gen3.viewerGfxFor), the way the carts' own Cable Club does.  Gen 1 and
-- Gen 2 carts may send theirs too; it costs nothing and names the cart on a
-- card.
--
-- Keys rather than a list so a lookup is the whole check, and never a string
-- compared with == (modkit MK409 reads that as a version allow-list).
M.VERSIONS = {
  red = 1, blue = 1, yellow = 1,
  gold = 2, silver = 2, crystal = 2,
  firered = 3, leafgreen = 3, emerald = 3,
}

-- A version off the wire, or nil.  With `generation`, only a version of that
-- generation survives: a hub that admitted a client as Gen 3 relays no
-- "red" for it, because a viewer handed a version that contradicts the room
-- would map the sprite for a cart nobody in it is playing.  Nil is always an
-- acceptable answer -- the field is optional, and a viewer without it falls
-- back to the sprite name alone.
function M.version(value, generation)
  if type(value) ~= "string" then return nil end
  local gen = rawget(M.VERSIONS, value)
  if gen == nil then return nil end
  if generation ~= nil and gen ~= generation then return nil end
  return value
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
--
-- Refused past 64 characters, never cut -- M.id's K13 argument, made for the
-- map (docs/plans/gen12-referee-gaps-fix.md, K13's twin): lib/sanitize.js's
-- cleanMapId is /^[\w.-]{1,64}$/ and has always thrown a longer one away, so
-- a player the node hub left unplaced stood on a map here -- one whose name
-- was the first 64 characters of theirs, which is no map they are on.  Every
-- caller (a hello, a step, a presence, a co-op offer, the client's inbound
-- step) already reads nil as "not in the world" or "no map", so a refused id
-- costs the player their cell and nothing else -- what it cost on Node.
function M.mapId(value)
  if type(value) ~= "string" then return nil end
  if #value > 64 then return nil end
  if not value:match("^[%w_%.%-]+$") then return nil end
  return value
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
-- carry one, and at PARTY_MAX there is room for every other member the party
-- may name (one at size 2, two at size 3).
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
--   mismatch  -- party-vs-party size not equal / not 2-or-3 (hub refuse; T7 phrases)
--   skip      -- a partner turned this kind of coop off; does not end the wait
M.COOP_REASONS = {
  alone = true, left = true, started = true,
  no = true, gone = true, timeout = true, mismatch = true, skip = true,
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

-- The assembled field, as it reaches the other clients in the fight.
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
--     against a one-monster trainer (and still valid for a 2v1 wild);
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
  -- Floor is three: a co-op party needs two humans, and an NPC / wild fight
  -- needs at least one foe seat. Cap is COOP_FIGHTERS (two parties of
  -- PARTY_MAX, or a trainer filling every foe seat the side width allows).
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
-- Optional `generation` (1|2|3) picks the missing-sprite fallback (Red,
-- Chris, or the Gen 3 token each viewer resolves on its own cart).
function M.presence(raw, generation)
  if type(raw) ~= "table" then return nil end
  local id = M.id(raw.id)
  local name = M.name(raw.name)
  if not id or not name then return nil end
  local out = {
    id = id,
    name = name,
    sprite = M.spriteId(raw.sprite) or Config.defaultSpriteFor(generation),
    -- The cart they are playing (PROTOCOL 30), which is what a Gen 3 viewer
    -- reads `sprite` against: a FireRed RED_NORMAL and an Emerald
    -- BRENDAN_NORMAL are names from two different graphics tables.  Nil from
    -- an older hub, or a client that did not say -- a viewer then goes by the
    -- sprite name alone.  Unchecked against `generation` here: the hub that
    -- relayed it already kept only a version of the room's generation.
    version = M.version(raw.version),
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
-- full parties: BATTLE_MON_MAX * COOP_SIDE. One number that covers both shapes
-- beats two that have to be kept in step. It bounds a foreign value before it
-- enters a formula, it does not restate a game rule.
--
-- **Gen 3 reads a zero**, and only Gen 3 (M.battleEvent's `generation`): the
-- holders-only fact (docs/plans/gen3-battle-sheet.md §7.1) -- a seat whose
-- fighters all fell still pays its Exp. Share holders, the way pret
-- Cmd_getexp does with `viaSentIn` 0 behind a SAFE_DIV.  The Gen 3 formula
-- (src/Exp3.lua split) never divides by this field, so the zero is a fact
-- there rather than a divisor; the older readings keep the floor of one.
M.PARTICIPANTS_MAX = Config.BATTLE_MON_MAX * Config.COOP_SIDE

-- The most Pay Day coins an outcome may say side a picked up, read by a Gen 3
-- reader (or one that names none; M.battleOutcome).  pret's gPaydayMoney is a
-- u16 that saturates, so this is the cart's own ceiling rather than a guess;
-- the Amulet Coin doubling is the client's, applied after the read.
M.PAYDAY3_MAX = 65535
-- The same, read by a Gen 1 / Gen 2 reader (contract K11 of
-- docs/plans/gen12-referee-gaps-fix.md).  pokered's wTotalPayDayMoney is three
-- BCD bytes and AddBCD fills it with $99 on a carry, so Red saturates at
-- 999999; pokecrystal's wPayDayMoney is a three-byte binary counter
-- (BattleCommand_PayDay), but the wallet it is paid into is clamped to
-- MAX_MONEY 999999 (AddBattleMoneyToAccount), so no larger count could ever
-- be paid.  Gold's Amulet Coin doubling (CheckPayDay) is the client's, after
-- the read, as on Gen 3.
M.PAYDAY12_MAX = 999999

-- How long a reason token this build has never heard of may be.  Refused past it
-- rather than trimmed -- a cut token matches nothing and is a value nobody sent.
M.REASON_MAX = 32

-- The three indices in this vocabulary, and the widths that tell them apart.
--
--   SLOT_MAX   a *party* index -- which of your six.  What `mon.slot` and
--              `choice.slot` are bounded by.
--   FIELD_MAX  a position *on the field* -- COOP_FIGHTERS seats (two parties
--              of PARTY_MAX), zero-based so FIELD_MAX = COOP_FIGHTERS - 1.
--              What `choice.target` and `event.slot` are bounded by: an event
--              is about somebody who is out, not about a bench position.
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

-- The Gen 3 dialect's bounds (docs/plans/gen3-battle-sheet.md §2-§4, contract
-- C4).  A Gen 3 sheet carries what Gen 1 / Gen 2 never needed -- an ability, a
-- held item with its hold effect, a gender, a nature, a move's priority, target
-- and flags -- because the hub holds no ROM tables and the sim branches on all
-- of them.  The ranges are pret's (the enum widths, u8 fields, the signed
-- priority), the id caps are Config's GEN3_* numbers; the move type keeps the
-- generous 0..31 the older dialects use, for the same reason (a type past the
-- chart is a neutral matchup, not a malformed party).
M.MOVE_TYPE_MAX = 31
M.POWER3_MAX = 255
M.ACCURACY3_MAX = 100         -- percent in Gen 3, not a 0..255 byte
M.EFFECT3_MAX = 213           -- EFFECT_* 0..213 (battle_move_effects.h)
M.TARGET3_MAX = 255           -- MOVE_TARGET_* bitmask
M.PRIORITY3_MAX = 7           -- signed: -7..7
M.FLAGS3_MAX = 63             -- FLAG_* bits (contact .. King's Rock)
M.HOLD_EFFECT3_MAX = 66       -- HOLD_EFFECT_* (hold_effects.h)
M.HOLD_PARAM3_MAX = 255
M.WEIGHT3_MAX = 9999          -- hectograms
M.SLEEP3_MAX = 7
M.U32_MAX = 4294967295        -- personality / OT id passthrough
M.GENDERS3 = { M = true, F = true, U = true }
-- The type-table cell a Gen 3 ruleset may hold: a type id or the Foresight
-- sentinel -1, and a multiplier in tenths up to the same 4x CHART_MAX allows
-- a Gen 1 cell (400 percent is 40 tenths).
M.TYPE_CELL3_MIN = -1
M.TYPE_MULT3_MAX = 40
M.TERRAIN3_MAX = 9            -- BATTLE_TERRAIN_*
M.WEATHERS3 = { RAIN = true, SUN = true, SAND = true, HAIL = true }
-- A packed move-pool entry is ten small integers, ten colons and an id of at
-- most 40: 128 is room for every honest one and a ceiling on the rest.
M.POOL_ENTRY3_MAX = 128
-- The stat names a Gen 3 `stat` event states, and how far a stage can sit or
-- move: a stage is -6..6, and one change can cross the whole range at most
-- (Belly Drum from -6, Haze's reset from +6 reads as its own delta).
M.EVENT_STATS3 = { atk = true, def = true, spe = true, spa = true, spd = true, acc = true, eva = true }
M.STAGE3_MAX = 6
M.DELTA3_MAX = 12
-- The outcome an `obey` event names (contract K3, docs/plans/gen3-battle-sheet.md
-- §7.2.1): one per branch of the engine's `disobedient` (battle/engine.lua:1291,
-- pret IsMonDisobedient), the four loaf lines among them in the cart's
-- gInobedientStringIds order.  A closed set because the screens look each one
-- up as a line of the cart's (MediatedBattle.OBEY_STRINGS3); prose in its
-- place would be a sentence no text pack holds.
M.OBEY_TOKENS3 = {
  ignores_asleep = true, uses_random_move = true, falls_asleep = true, hits_itself = true,
  loafing = true, wont_obey = true, turned_away = true, pretend_not_notice = true,
}
-- What a `palace` event (the Battle Palace, contract C6 wave 3 of
-- docs/plans/gen3-solo-remaining-fights.md) and an `arena` event (the Battle
-- Arena referee) name: closed sets for M.OBEY_TOKENS3's reason -- each is a
-- line or a step of the cart's (B_MSG_INCAPABLE_OF_POWER and
-- gBattlePalaceFlavorTextTable; gRefereeStringsTable and the judgment
-- window), which the screens look up rather than phrase.
M.PALACE_TOKENS3 = { unable = true, flavor = true }
M.ARENA_TOKENS3 = {
  start = true, judge = true, mind = true, skill = true, body = true, win = true, draw = true,
}

-- The Gold sheet's held-item fields (contract K2 of
-- docs/plans/gen12-referee-fidelity.md).  pokecrystal *names* its hold effects
-- where pret's Gen 3 numbers them, and the engine's item rows carry that name
-- (HELD_LEFTOVERS), so the Gen 2 effect is an identifier with a fixed prefix
-- and the cart's own alphabet, bounded by length rather than by an enum width;
-- the parameter is the u8 beside it in the cart's item attributes, and the
-- display name is the cart's item name (ITEM_NAME_LENGTH 13, terminator
-- included).  The hub holds no item table and never will -- the referee's
-- rules key on the token, never on a value read from the player's ROM.
M.HOLD_EFFECT2_MAX = 32       -- characters in a HELD_* token
M.HOLD_PARAM2_MAX = 255
M.ITEM_NAME2_MAX = 12

-- The referee-gap additions' bounds (contracts K7-K10 of
-- docs/plans/gen12-referee-gaps-fix.md), Gen 1 / Gen 2 dialect only -- each
-- the width the carts store the number in, so an honest sheet always fits:
--
--   BASE_STAT_MAX  a species base stat: one byte in both carts' base-stats
--                  rows (pokered / pokecrystal data/pokemon/base_stats).
--                  `baseSpd`'s 0..255, for the whole block.
--   DV_MAX         a DV: one nibble of MON_DVS (the `ivs` block's 15).
--   STAT_EXP_MAX   a stat-exp word: MON_STAT_EXP holds five big-endian
--                  words (the `evs` block's 65535).
--   PP_UPS_MAX     the PP Ups used on a move: the top two bits of its PP byte
--                  (PP_UP_MASK %11000000, PP_MASK %00111111), so 0..3.
--   PRIORITY2_MAX  Gold's raw GetMovePriority byte: VITAL_THROW 0, the
--                  MoveEffectPriorities rows 0 / 2 / 3, BASE_PRIORITY 1 for
--                  the rest.  Unsigned, unlike Gen 3's -7..7, and bounded by
--                  the byte rather than by today's table so a content mod's
--                  own number fits.
--   STAGE12_MAX    a `stat` event's signed stage (K10): a stat level is 1..13
--                  around 7 on both carts (wPlayerMonStatMods), so -6..6 --
--                  Gen 3's STAGE3_MAX, named for the older dialect.
--   HAPPINESS2_MAX a Gold monster's happiness (K14, added after wave 1): the
--                  one byte MON_HAPPINESS (pokecrystal constants/
--                  pokemon_data_constants.asm) that BattleCommand_HappinessPower
--                  / _FrustrationPower read through w*MonHappiness.  Gold
--                  only -- Red has no such byte.
M.BASE_STAT_MAX = 255
M.DV_MAX = 15
M.STAT_EXP_MAX = 65535
M.PP_UPS_MAX = 3
M.PRIORITY2_MAX = 255
M.STAGE12_MAX = 6
M.HAPPINESS2_MAX = 255

-- Wave 5 of docs/plans/gen12-referee-gaps-fix.md, Gen 1 / Gen 2 only:
--
--   CHART_ORDER_MAX  integers in a Red ruleset's `chartOrder`: pokered's
--                    TypeEffects (data/types/type_matchups.asm) as chart-index
--                    pairs in table order, two per row.  The Red referee
--                    takes at most its CHART_ORDER_MAX rows (BattleSim Turn,
--                    256: a 16-type chart's every cell), so twice that.  The
--                    cart's table is 82 rows -- 164 integers.
--   NUM_ATTACKS2     a Gold Metronome pool row's `num`: pokecrystal /
--                    pokegold constants/move_constants.asm NUM_ATTACKS, the
--                    251 BattleCommand_Metronome's `.GetMove` compares its
--                    byte with (`cp NUM_ATTACKS + 1` / `jr nc, .GetMove`) --
--                    a number past it is never picked, so a row naming one
--                    is not a row the cart could call.  The Gold referee's
--                    Turn.NUM_ATTACKS.
--
-- K15's `base.gender` (pokecrystal BASE_GENDER) is a byte of the same
-- base-stats row as the K7 `base` block, so BASE_STAT_MAX bounds it.
M.CHART_ORDER_MAX = 512
M.NUM_ATTACKS2 = 251

-- Contract K21 of docs/plans/gen12-referee-remaining-gaps.md, Gold only -- the
-- two facts the LURE BALL and the HEAVY BALL read (pokecrystal / pokegold
-- engine/items/item_effects.asm LureBallMultiplier, HeavyBallMultiplier):
--
--   WEIGHT2_MAX       a Gen 2 sheet's `weight`: the species' Pokedex weight
--                     word (data/pokemon/dex_entries, `dw` after the height),
--                     which HeavyBallMultiplier reads through GetFarWord.
--   BATTLE_TYPE2_MAX  a Gen 2 ruleset's `battleType`: wBattleType, one byte
--                     (constants/battle_constants.asm BATTLETYPE_*), which
--                     LureBallMultiplier compares with BATTLETYPE_FISH.
M.WEIGHT2_MAX = 65535
M.BATTLE_TYPE2_MAX = 255

-- Gold's wTimeOfDay as a Gen 2 ruleset spells it (`timeOfDay`, wave 4 of
-- docs/plans/gen12-referee-gaps-fix.md): pokecrystal / pokegold
-- constants/ram_constants.asm `shift_const MORN / DAY / NITE` -- MORN_F 0,
-- DAY_F 1, NITE_F 2 -- the three readings BattleCommand_HealMorn /
-- _HealDay / _HealNite compare it with (`ld b, MORN_F` ... `cp b`).
-- GetTimeOfDay (engine/rtc/rtc.asm) writes wTimeOfDay from its TimesOfDay
-- table, which holds those three alone; DARKNESS_F only ever names a palette
-- (DARKNESS_PALSET, a dark map's), so it is not one of them.  Spelled as the
-- Gold referee's `Turn.TIMES` keys (src/BattleSim2/Turn.lua, lib/battle2
-- Turn.js), which `create` reads as `opts.timeOfDay`.  A closed set, like
-- Gen 3's WEATHERS3.
M.TIMES_OF_DAY2 = { morn = true, day = true, nite = true }

-- One Gen 2 hold effect, or nil.  Refused rather than trimmed past
-- HOLD_EFFECT2_MAX, on M.spriteId's argument: a cut token names no rule, and
-- the referee looks its rule up by the whole token.  The prefix is part of the
-- shape -- a bare LEFTOVERS or an item id in this field is a sheet built from
-- the wrong column, and reading it as a rule's name would be guessing.
function M.holdEffect2(value)
  if type(value) ~= "string" then return nil end
  if #value > M.HOLD_EFFECT2_MAX then return nil end
  if not value:match("^HELD_[A-Z0-9_]+$") then return nil end
  return value
end

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
--
-- A JSON null row or cell never reaches here: the engine's decoder closes it
-- up, so `[[100, null, 50]]` is the one-row chart `{ { 100, 50 } }`.  Since
-- wave 6 of docs/plans/gen12-referee-gaps-fix.md lib/sanitize.js's cleanChart
-- closes both up the same way (luaList) and reads each cell as Wire.int does
-- (luaInt), where it used to refuse the chart over a null -- one chart on
-- both hosting paths.
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

-- A Gen 3 list, as src/link/Json.lua's encoder tells one from an object: a
-- sequence (`#t > 0`) or the empty table.  ipairs over an object reads
-- nothing, so without this `{ a = 1 }` passed as the empty list where
-- lib/sanitize.js -- which has JSON's arrays and objects to go on -- refused
-- it.  The empty table is the one shape this side cannot tell apart (`{}` and
-- `[]` decode alike), so the JS twin takes an empty object as the empty list
-- too.
--
-- A JSON null *inside* a list never reaches this file at all: the engine's
-- Json.decode appends nothing for it (`arr[#arr + 1] = nil`), so
-- `[10, null, 12]` arrives as `{ 10, 12 }`.  Nothing here can see the hole, so
-- the JS twin closes its lists up the same way (luaList) before reading them
-- -- the two then judge one list, and refuse or keep it whole alike.
local function isList(t)
  return type(t) == "table" and (#t > 0 or next(t) == nil)
end

-- Gen 3's chart: the cart's ORDERED triples (atk, def, mult in tenths), the
-- Foresight sentinel -1, -1, 0 in place (docs/plans/gen3-battle-sheet.md
-- §3.1).  Rebuilt cell by cell like chartOf, and refused whole rather than
-- trimmed: a triple list cut mid-row shifts every later row by one and silently
-- rewrites the chart, and a sentinel with a real type on one side is a row the
-- sim cannot read as either.
local function typeTable3(raw)
  if not isList(raw) then return nil end
  local n = #raw
  if n == 0 or n % 3 ~= 0 or n > Config.BATTLE_TYPE_TABLE3_MAX * 3 then return nil end
  local out = {}
  for i = 1, n, 3 do
    local a = M.int(raw[i], M.TYPE_CELL3_MIN, M.MOVE_TYPE_MAX)
    local d = M.int(raw[i + 1], M.TYPE_CELL3_MIN, M.MOVE_TYPE_MAX)
    local m = M.int(raw[i + 2], 0, M.TYPE_MULT3_MAX)
    if a == nil or d == nil or m == nil then return nil end
    if (a == M.TYPE_CELL3_MIN) ~= (d == M.TYPE_CELL3_MIN) then return nil end
    out[i], out[i + 1], out[i + 2] = a, d, m
  end
  return out
end

-- One Gen 3 move-pool entry (§3.3): the packed
-- "num:effect:power:type:accuracy:pp:chance:target:priority:flags:id" string,
-- or a move row.  A string is parsed with the grammar the sim uses (eleven
-- fields, ten plain integers, an id) and bounded like a sheet's move row, then
-- written back canonically -- "05" and "-0" are canonicalised ("5", "0") on
-- both twins, and a leading "+" is refused as the grammar has no sign but
-- "-", so what the sim parses is what was checked.  An id past 40 is refused
-- rather than cut, as the sim refuses it.  A row table is a move row.
local function poolEntry3(raw)
  if type(raw) == "table" then return M.battleMove(raw, 3) end
  if type(raw) ~= "string" or #raw > M.POOL_ENTRY3_MAX then return nil end
  local parts = {}
  for piece in (raw .. ":"):gmatch("([^:]*):") do parts[#parts + 1] = piece end
  if #parts ~= 11 then return nil end
  local n = {}
  for i = 1, 10 do
    if not parts[i]:match("^%-?%d+$") then return nil end
    -- `+ 0` folds "-0" into 0, so the canonical string is the same bytes JS writes.
    n[i] = tonumber(parts[i]) + 0
  end
  local row = M.battleMove({
    num = n[1], effect = n[2], power = n[3], type = n[4], accuracy = n[5], pp = n[6],
    chance = n[7], target = n[8], priority = n[9], flags = n[10], id = parts[11],
  }, 3)
  if not row or row.id ~= parts[11] then return nil end
  return table.concat({ row.num, row.effect, row.power, row.type, row.accuracy, row.pp,
    row.chance, row.target, row.priority, row.flags, row.id }, ":")
end

-- Which dialect a ruleset is in.  The hub's own generation decides when it is
-- given (a Gen 1 / Gen 2 hub reads every ruleset exactly as it always did);
-- otherwise the message's `generation`, and a `typeTable` with neither is
-- Gen 3's shape.
local function rulesetIsGen3(raw, generation)
  local hub = M.int(generation, 1, M.GENERATION_MAX)
  if hub then return hub == 3 end
  local own = M.int(raw.generation, 1, M.GENERATION_MAX)
  if own then return own == 3 end
  return raw.typeTable ~= nil
end

-- The Gen 3 ruleset: { generation = 3, typeTable?, seed?, specialTypes?,
-- movePool?, terrain?, weather?, underwater? } (§3, and Turn.create's options).
--
-- `typeTable` is optional here where Gen 1's `chart` is the message: the sim
-- reads its absence as every matchup neutral, and src/Sheet3.lua sends none
-- (with a warning naming the remediation) when a cart's chart cannot be read,
-- rather than leaving the players with no fight at all.  Present-but-unreadable
-- still refuses the whole ruleset, as every optional field below does -- a
-- ruleset half-understood is a different fight from the one uploaded.  The pool
-- is capped (the tail is dropped, as Gen 1's metronomePool is) and an entry
-- that does not parse refuses it.
local function battleRuleset3(raw)
  local out = { generation = 3 }
  if raw.typeTable ~= nil then
    out.typeTable = typeTable3(raw.typeTable)
    if not out.typeTable then return nil end
  end
  if raw.seed ~= nil then
    out.seed = M.int(raw.seed, 1, M.SEED_MAX)
    if out.seed == nil then return nil end
  end
  if raw.specialTypes ~= nil then
    if not isList(raw.specialTypes) then return nil end
    local special = {}
    for _, entry in ipairs(raw.specialTypes) do
      local t = M.int(entry, 0, Config.BATTLE_TYPE_MAX - 1)
      if t == nil then return nil end
      special[#special + 1] = t
    end
    out.specialTypes = special
  end
  if raw.movePool ~= nil then
    if not isList(raw.movePool) then return nil end
    local pool = {}
    for _, entry in ipairs(raw.movePool) do
      if #pool >= Config.BATTLE_MOVE_POOL3_MAX then break end
      local clean = poolEntry3(entry)
      if not clean then return nil end
      pool[#pool + 1] = clean
    end
    out.movePool = pool
  end
  if raw.terrain ~= nil then
    out.terrain = M.int(raw.terrain, 0, M.TERRAIN3_MAX)
    if out.terrain == nil then return nil end
  end
  if raw.weather ~= nil then
    if not M.WEATHERS3[raw.weather] then return nil end
    out.weather = raw.weather
  end
  if raw.underwater ~= nil then
    if type(raw.underwater) ~= "boolean" then return nil end
    if raw.underwater then out.underwater = true end
  end
  return out
end

-- The chart's axis by name (Gen 1 / Gen 2 `typeIds`): the type registry id of
-- each chart index in order (MediatedBattle.typeOrder's).  A move row carries
-- only the index, so this is how a referee names a type: BattleSim2 for Gold's
-- badge type boost (DoBadgeTypeBoosts is keyed by type) and its side effects'
-- type checks, BattleSim for Red's (PoisonEffect turns a POISON type away, a
-- FIRE move thaws -- `typeIndexOf`).  All or nothing: one
-- unreadable entry makes the whole list nil, since a stray entry would name the
-- wrong type at its index.  Never longer than a chart may be wide
-- (BATTLE_TYPE_MAX, the width `chartOf` refuses past), and an id past 40
-- characters is refused rather than cut -- the reading lib/sanitize.js's
-- cleanId has, so the two twins answer one list the same way.  Exported as
-- M.typeIds so the uploading client asks the very question the hub will.
local function typeIdsOf(raw)
  if type(raw) ~= "table" then return nil end
  local n = #raw
  if n < 1 or n > Config.BATTLE_TYPE_MAX then return nil end
  local out = {}
  for i = 1, n do
    local entry = raw[i]
    if type(entry) ~= "string" or #entry > 40 then return nil end
    local id = M.id(entry)
    if not id then return nil end
    out[i] = id
  end
  return out
end
M.typeIds = typeIdsOf

-- Red's type chart as the cart walks it (`chartOrder`, wave 5 of
-- docs/plans/gen12-referee-gaps-fix.md): pokered's TypeEffects rows
-- (data/types/type_matchups.asm) in table order, each row's attacker and
-- defender as chart indices -- a flat { atk1, def1, atk2, def2, ... }, the
-- shape the Red referee's `chartRowsOf` reads (BattleSim Turn.create's
-- `opts.chartOrder`).  AdjustDamageForMoveType (engine/battle/core.asm) walks
-- the table top to bottom, applying every row whose attacker is the move's
-- type and whose defender is either of the target's, and leaves the LAST
-- row's multiplier in wDamageMultipliers -- which DisplayEffectiveness and
-- PrintMoveFailureText read -- so the order is a rule, not a layout: it is
-- what makes a dual type's immunity "It doesn't affect" or "<USER>'s attack
-- missed!".
--
-- Read as typeTable3 reads Gen 3's ordered chart, and refused WHOLE rather
-- than trimmed: a list (isList), of an even, non-zero length no longer than
-- CHART_ORDER_MAX, each entry a chart index 0..BATTLE_TYPE_MAX - 1 (the
-- width `chartOf` refuses past).  A row dropped from the middle moves every
-- later row up and changes which one is last; a cut pair pairs every later
-- attacker with the wrong defender; and an empty list names no row, which
-- the referee reads as no order at all -- so each is a different chart from
-- the one uploaded, not a shorter copy of it.  A row may repeat, as the cart
-- would apply it twice.  A JSON null inside the list never reaches here (the
-- engine's decoder closes it up), and lib/sanitize.js closes its list the
-- same way first (luaList), so both twins judge one list.
local function chartOrderOf(raw)
  if not isList(raw) then return nil end
  local n = #raw
  if n == 0 or n % 2 ~= 0 or n > M.CHART_ORDER_MAX then return nil end
  local out = {}
  for i = 1, n do
    local index = M.int(raw[i], 0, Config.BATTLE_TYPE_MAX - 1)
    if index == nil then return nil end
    out[i] = index
  end
  return out
end

-- `generation` (optional) is the hub's; see rulesetIsGen3.  Gen 1 / Gen 2
-- rulesets are read exactly as before.
function M.battleRuleset(raw, generation)
  if type(raw) ~= "table" then return nil end
  if rulesetIsGen3(raw, generation) then return battleRuleset3(raw) end
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
  --
  -- Read as a list (isList, wave 6 of docs/plans/gen12-referee-gaps-fix.md),
  -- the twin of lib/sanitize.js: a non-empty object where the list belongs is
  -- refused there, where ipairs here used to read it as "no Special type" --
  -- every type Physical, the opposite split from the host's.  A JSON null
  -- inside the list never reaches this line (the engine's decoder closes it
  -- up), and lib/sanitize.js now closes it up the same way (luaList) where it
  -- used to refuse the ruleset over it.
  if raw.specialTypes ~= nil then
    if not isList(raw.specialTypes) then return nil end
    local special = {}
    for _, entry in ipairs(raw.specialTypes) do
      local t = M.int(entry, 0, Config.BATTLE_TYPE_MAX - 1)
      if t == nil then return nil end
      special[#special + 1] = t
    end
    out.specialTypes = special
  end
  -- Optional chart axis by name (typeIdsOf).  Absent = no move's type can be
  -- named: no badge type boost fires (BattleSim2 Turn.lua `_typeIdOf`), and no
  -- side-effect rule that asks a type by name applies (Red's POISON immunity
  -- and FIRE thaw, Gold's type checks).  Unreadable is DROPPED, not refused,
  -- unlike `specialTypes`: the list only names types, the chart and every
  -- index on the upload stand without it, and a content mod's type id need not
  -- fit the wire's id alphabet (a registry id is any non-empty string --
  -- "mymod.FAIRY") -- so refusing would cost a modded install every refereed
  -- fight to keep those few rules.  The fight goes on without them, which is
  -- the absent reading.
  if raw.typeIds ~= nil then
    out.typeIds = typeIdsOf(raw.typeIds)
  end
  -- Optional Metronome pick pool: full move sheets from the host's decode.
  -- Read in the older dialect by name, never by sniffing a row's `num`: this
  -- is a Gen 1 / Gen 2 ruleset, and a stray `num` on one of its rows is
  -- ignored exactly as it was before Gen 3 had a row of its own.
  --
  -- A Gold row may state its cart move number (`num`, wave 5): pokecrystal's
  -- BattleCommand_Metronome draws a BattleRandom byte that IS a move number
  -- (`.GetMove`: redrawn past NUM_ATTACKS, on MetronomeExcepts, on a move the
  -- user knows), and the Gold referee looks the pick up by it (BattleSim2
  -- Turn `byNumber[entry.num or i]`) -- without it, by the row's place in the
  -- pool, which is the cart's number only while the pool skips nothing.
  -- 1..NUM_ATTACKS2: 0 is NO_MOVE, which `.GetMove` never keeps, and a number
  -- past NUM_ATTACKS is one it redraws.  Read on a Gen 2 hub alone, by the
  -- hub's generation as the rows' dialect is: the Red referee picks a pool
  -- row by its place (BattleSim Turn, `rng:byte() % #pool`) and reads no
  -- number, so a Gen 1 reader neither copies nor refuses one.  Optional,
  -- and refused with the ruleset when present and unreadable -- K8's posture
  -- for a row field, and a pool row that does not read already refuses it: a
  -- dropped number would have METRONOME call a different move than the
  -- host's cart.  Read the way Wire.int reads it on both twins (luaInt).
  -- The pool itself is read as a list (isList, wave 5): a non-empty object
  -- where the list belongs is refused, as lib/sanitize.js always refused it,
  -- where ipairs used to read it as the empty pool; and lib/sanitize.js closes a
  -- JSON null row up first (luaList), as the engine's decoder does before
  -- this line ever sees the list -- so the twins judge one pool.
  if raw.metronomePool ~= nil then
    if not isList(raw.metronomePool) then return nil end
    local rowGeneration = M.int(generation, 1, 2) or 1
    local pool = {}
    for _, entry in ipairs(raw.metronomePool) do
      if #pool >= Config.BATTLE_METRONOME_POOL_MAX then break end
      local move = M.battleMove(entry, rowGeneration)
      if not move then return nil end
      if rowGeneration == 2 and entry.num ~= nil then
        move.num = M.int(entry.num, 1, M.NUM_ATTACKS2)
        if move.num == nil then return nil end
      end
      pool[#pool + 1] = move
    end
    out.metronomePool = pool
  end
  -- Red's TypeEffects order (chartOrderOf), which decides a dual type's
  -- effectiveness line and its "doesn't affect" / "missed" (the last row
  -- AdjustDamageForMoveType applied).  Read on a Gen 1 hub alone, by the
  -- hub's generation as `mimic` is: Gold's walk (pokegold / pokecrystal
  -- effect_commands.asm BattleCommand_Stab) sets wAttackMissed on any
  -- immunity row and its `.end` writes BattleCheckTypeMatchup's product over
  -- wTypeModifier, so no row is "the last" there, and Gen 3 uploads its
  -- ordered chart as `typeTable` -- a Gen 2 / Gen 3 reader (or a caller
  -- naming no generation) neither copies nor refuses one.  Present and
  -- unreadable refuses the ruleset, as `specialTypes` and Gen 3's
  -- `typeTable` do: an order half-read is a different chart, and a dropped
  -- one would have the referee read the product where the host's cart reads
  -- the last row.  Absent stays absent -- the referee's product reading.
  if M.int(generation, 1, 1) and raw.chartOrder ~= nil then
    out.chartOrder = chartOrderOf(raw.chartOrder)
    if out.chartOrder == nil then return nil end
  end
  -- Gold's wTimeOfDay (wave 4 of docs/plans/gen12-referee-gaps-fix.md), which
  -- MORNING SUN / SYNTHESIS / MOONLIGHT compare (BattleCommand_HealMorn /
  -- _HealDay / _HealNite: double the heal when it is the move's own time) --
  -- the host's cart clock, which only the host can state.  Read on a Gen 2
  -- hub alone, by the hub's generation as `metronomePool`'s rows are: Red has
  -- no clock, so a Gen 1 reader (or a caller naming no generation) neither
  -- copies nor refuses one, the posture K14's happiness takes.  One of
  -- TIMES_OF_DAY2 or the ruleset is refused, as Gen 3's `weather` is: it is
  -- an input to a heal, and a dropped one would have the referee read the
  -- move's own time (its link reading) where the host's cart reads another.
  -- Absent stays absent -- the referee's link reading.
  if M.int(generation, 2, 2) and raw.timeOfDay ~= nil then
    if not M.TIMES_OF_DAY2[raw.timeOfDay] then return nil end
    out.timeOfDay = raw.timeOfDay
  end
  -- Gold's wBattleType (contract K21 of
  -- docs/plans/gen12-referee-remaining-gaps.md), the engine battle's own id,
  -- which the LURE BALL compares with BATTLETYPE_FISH (LureBallMultiplier) --
  -- the hubs hand it to the Gold referee's `opts.battleType`.  Read on a Gen 2
  -- hub alone, by the hub's generation as `timeOfDay` is: a Gen 1 reader (or a
  -- caller naming none) neither copies nor refuses one.  0..BATTLE_TYPE2_MAX,
  -- read as Wire.int reads it on both twins (lib/sanitize's luaInt), or the
  -- ruleset is refused -- `timeOfDay`'s posture for an input to a catch rate.
  -- Absent stays absent: the referee then reads no fishing fight.
  if M.int(generation, 2, 2) and raw.battleType ~= nil then
    out.battleType = M.int(raw.battleType, 0, M.BATTLE_TYPE2_MAX)
    if out.battleType == nil then return nil end
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
--
-- `name` (PROTOCOL 26) is the one exception to "every field is required", and
-- it is optional for the same reason `maxPp` is: absence is a real answer.  It
-- is what the referee narrates the move under -- an intermediator holds no move
-- table to look one up in and never will -- and a sender that states none is a
-- protocol-25 client, whose fight narrates under the id exactly as it always
-- did.  Present-but-unreadable is refused rather than dropped, on this
-- function's own rule: a field that arrived and did not survive is the sending
-- side being wrong about something, and quietly narrating under the id would
-- hide it.
-- The Gen 3 move row (docs/plans/gen3-battle-sheet.md §2, "Move row"): the
-- older dialect's fields at Gen 3's widths (power a u8, accuracy a percent,
-- EFFECT_* up to 213), plus the four the Gen 3 sim branches on -- `num` (pret
-- MOVE_* number: Struggle, Curse, the two-turn and sound-move lists ...),
-- `target` (MOVE_TARGET_* bitmask), `priority` (signed) and `flags` (contact,
-- Protect, Magic Coat, Snatch, Mirror Move, King's Rock).  Every one required,
-- on this function's rule; `maxPp` and `name` optional as before.  No
-- `highCrit`: Gen 3's high-crit moves are an effect (§5.2), not a flag.
-- M.id, refusing rather than cutting past 40 characters -- the reading
-- lib/sanitize.js's cleanId has always had.  The Gen 3 dialect took it from
-- the start; since K13 (docs/plans/gen12-referee-gaps-fix.md) M.id itself
-- refuses, so this is M.id under the name the Gen 3 readers call it by.
local function id3(value)
  return M.id(value)
end

local function battleMove3(raw)
  local out = {
    id = id3(raw.id),
    num = M.int(raw.num, 1, Config.GEN3_MOVE_MAX),
    pp = M.int(raw.pp, 0, 99),
    power = M.int(raw.power, 0, M.POWER3_MAX),
    accuracy = M.int(raw.accuracy, 0, M.ACCURACY3_MAX),
    type = M.int(raw.type, 0, M.MOVE_TYPE_MAX),
    effect = M.int(raw.effect, 0, M.EFFECT3_MAX),
    chance = M.int(raw.chance, 0, 100),
    target = M.int(raw.target, 0, M.TARGET3_MAX),
    priority = M.int(raw.priority, -M.PRIORITY3_MAX, M.PRIORITY3_MAX),
    flags = M.int(raw.flags, 0, M.FLAGS3_MAX),
  }
  if not (out.id and out.num and out.pp and out.power and out.accuracy and out.type
          and out.effect and out.chance and out.target and out.priority and out.flags) then
    return nil
  end
  if raw.maxPp ~= nil then
    out.maxPp = M.int(raw.maxPp, 0, 99)
    if out.maxPp == nil then return nil end
  end
  if raw.name ~= nil then
    out.name = M.moveName(raw.name)
    if out.name == nil then return nil end
  end
  return out
end

-- `generation` (optional): 3 reads the Gen 3 row, 1 or 2 the older row
-- whatever else it carries.  Absent, a row that states a `num` is a Gen 3 row
-- (no Gen 1 / Gen 2 sheet has ever carried one), which is how a client
-- sanitising a `moves` event from a Gen 3 referee keeps the fields it needs
-- without learning the hub's generation.  Every reader that *knows* its
-- generation passes it -- a Gen 1 / Gen 2 sheet or ruleset never takes the
-- Gen 3 reader by sniffing, which is what kept those read paths as they were.
function M.battleMove(raw, generation)
  if type(raw) ~= "table" then return nil end
  local gen = M.int(generation, 1, M.GENERATION_MAX)
  if gen == 3 or (gen == nil and raw.num ~= nil) then return battleMove3(raw) end
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
  if raw.name ~= nil then
    out.name = M.moveName(raw.name)
    if out.name == nil then return nil end
  end
  -- Optional high-crit flag. The hub has no move table, so Slash / Karate
  -- Chop / Razor Leaf / Crabhammer have to state this on the sheet. Absent
  -- is a protocol-era client (ordinary odds). Present-but-unreadable refuses,
  -- same posture as a mangled name.
  if raw.highCrit ~= nil then
    if raw.highCrit ~= true and raw.highCrit ~= false then return nil end
    if raw.highCrit == true then out.highCrit = true end
  end
  -- Contract K8 (docs/plans/gen12-referee-gaps-fix.md), optional like
  -- `highCrit` and refused like it when present and unreadable:
  --
  --   ppUps     Gen 1 and Gen 2: the PP Ups used on the move, the top two
  --             bits of its PP byte (PP_UP_MASK).  The cart's move pick reads
  --             that raw byte, so a move at 0 PP that has PP Ups is still
  --             selectable (pokered `.chooseMove`) -- the referee needs the
  --             count to see it.
  --   priority  Gen 2 only: the cart's raw GetMovePriority byte for this move
  --             (0..255).  The referee's priority table is keyed by vanilla
  --             move id, so a content mod's move with a priority effect moved
  --             at base priority; a row that states its own number is read
  --             before the table.  A Gen 1 row never carries one (Red has no
  --             move priority), and its reader neither copies nor refuses it --
  --             the posture a Gen 1 sheet takes to Gold's held-item fields.
  --
  -- `gen` is the caller's dialect: a sheet's resolved generation, a ruleset's
  -- (default 1), or the reader's own on an event or a moveset.  A caller that
  -- names none reads the older row without `priority`, since it cannot say
  -- the row is Gold's.  Read the way the Gen 3 fields are (M.int on both
  -- twins: lib/sanitize's luaInt), because the readings are new on both.
  if raw.ppUps ~= nil then
    out.ppUps = M.int(raw.ppUps, 0, M.PP_UPS_MAX)
    if out.ppUps == nil then return nil end
  end
  if gen == 2 and raw.priority ~= nil then
    out.priority = M.int(raw.priority, 0, M.PRIORITY2_MAX)
    if out.priority == nil then return nil end
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

-- Contract K7's three blocks (see M.battleMon), per dialect: `base` keyed like
-- `stats` plus `hp`; `dvs` the cart's four DVs; `statExp` the cart's five
-- stat-exp words.  Twin of lib/sanitize.js K7_KEYS1 / K7_KEYS2.
local K7_KEYS1 = {
  base = { "hp", "atk", "def", "spd", "spc" },
  dvs = { "atk", "def", "spd", "spc" },
  statExp = { "hp", "atk", "def", "spd", "spc" },
}
local K7_KEYS2 = {
  base = { "hp", "atk", "def", "spe", "spa", "spd" },
  dvs = { "atk", "def", "spe", "spc" },
  statExp = { "hp", "atk", "def", "spe", "spc" },
}
M.K7_KEYS1, M.K7_KEYS2 = K7_KEYS1, K7_KEYS2

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
-- list of `{id, count}` stacks. The hub stores it on the fight record, holds
-- a stack when an `item` choice is accepted, and decrements only when the turn
-- resolves (so `cancel`/`unchose` never needs a refund). The record dies with
-- the fight: this is not a hub inventory. Who sends what:
--
--   * 1v1 / 2v2 (coop_pvp): each human uploads their own bag with their party.
--   * 1xNPC / 2xNPC: each human still uploads their own bag; the initiator
--     (host) also uploads the NPC party as side "b", with that NPC's items
--     from *their* game data (trainer class kit, or none for wild). Nobody
--     else may fill side "b". The hub has no ROM item table and never will.
--
-- Entries must be ids BattleSim knows (`itemEffect`), including vitamins
-- (fight-local Stat Exp; client writebacks `save.statExp` on confirm). Counts
-- and battler sheets remain a **claim**: a modified client can still invent
-- 99 POTION or a god team on upload. That is the accepted bound — mid-fight
-- free heals without a matching stack are what the bag removes. Absent `bag`
-- means empty.
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
--
-- The referee-fidelity additions (docs/plans/gen12-referee-fidelity.md), each
-- optional, so a sheet that carries none of them reads byte for byte as it did
-- before they existed:
--
--   K1  `traded` (Gen 1 and Gen 2): the obedience check's one fact about a
--       player's own monster -- its OT id is not the player's.  Gen 3's
--       reading: `true` kept, `false` kept as absent, anything else refuses.
--   K2  the Gold held item's data, next to `heldItem` (Gen 2 only -- a Gen 1
--       sheet never carries an item, so a Gen 1 reader never copies these):
--       `holdEffect` (a HELD_* token, M.holdEffect2), `holdParam` (0..255),
--       `itemName` (display text, ITEM_NAME2_MAX) and `mail` (`true` or
--       absent).  Each refuses the mon when present and unreadable, the
--       posture `heldItem` and Gen 3's hold effect already have.
--
-- A Gen 3 stat-like block: every key of `keys` at the caller's width, and
-- nothing else.  Refused whole when one is missing, for statsOf's reason.
local function block3(raw, keys, min, max)
  if type(raw) ~= "table" then return nil end
  local out = {}
  for _, key in ipairs(keys) do
    local n = M.int(raw[key], min, max)
    if n == nil then return nil end
    out[key] = n
  end
  return out
end

local IV_KEYS3 = { "hp", "atk", "def", "spe", "spa", "spd" }

-- One Gen 3 battler (docs/plans/gen3-battle-sheet.md §2, contract C4).
--
-- The Gen 2 stat keys (final stats: nature, IVs and EVs are already folded in
-- by the client's own Pokemon.calcStats), plus what the Gen 3 sim reads off a
-- sheet because the hub has no species, item or ability table: `speciesNum`
-- (Light Ball, Thick Club, Soul Dew, Castform ... branch on it), `types`,
-- `ability`, `heldItem` with its `holdEffect` / `holdEffectParam`, `gender`
-- (Attract, Cute Charm), `friendship` (Return), `nature` (confusion-berry
-- dislikes).  All of those are required: a missing one is not a neutral value,
-- it is a mon whose owner sees a different fight from the referee.
--
-- Optional here, and each refused when present and unreadable: the display
-- names, `slot`, `status` / `sleepTurns`, `catchRate` (the wild seat), the
-- passthrough `ivs` / `evs` / `personality` / `otId` (never read by a formula;
-- copied onto a caught sheet so the catcher rebuilds the exact mon), `ball`
-- (the caught sheet's), the obedience check's `traded` / `unfateful` (booleans,
-- a player's own sheet only), and the three formula inputs the sim's own caught
-- sheet does not restate -- `weight`, `hiddenPower`, `beatUp`.  Those three
-- ARE required on an upload: M.battleParty checks them, because an outcome's
-- caught sheet goes through this same function and must not be refused for
-- leaving out a Low Kick weight the catcher never needs.
local function battleMon3(raw)
  local stats = block3(raw.stats, STAT_KEYS_GEN2, 1, M.STAT_MAX)
  if not stats then return nil end
  local status = M.battleStatus(raw.status)
  if status == false then return nil end

  local out = {
    generation = 3,
    species = M.name(raw.species),
    speciesNum = M.int(raw.speciesNum, 1, Config.GEN3_SPECIES_MAX),
    level = M.int(raw.level, 1, M.LEVEL_MAX),
    hp = M.int(raw.hp, 0, M.HP_MAX),
    maxHp = M.int(raw.maxHp, 1, M.HP_MAX),
    stats = stats,
    status = status,
    ability = M.int(raw.ability, 0, Config.GEN3_ABILITY_MAX),
    heldItem = M.int(raw.heldItem, 0, Config.GEN3_ITEM_MAX),
    holdEffect = M.int(raw.holdEffect, 0, M.HOLD_EFFECT3_MAX),
    holdEffectParam = M.int(raw.holdEffectParam, 0, M.HOLD_PARAM3_MAX),
    gender = M.GENDERS3[raw.gender] and raw.gender or nil,
    friendship = M.int(raw.friendship, 0, 255),
    nature = M.int(raw.nature, 0, Config.GEN3_NATURE_COUNT - 1),
  }
  if out.species == nil or out.speciesNum == nil or out.level == nil or out.hp == nil
     or out.maxHp == nil or out.ability == nil or out.heldItem == nil
     or out.holdEffect == nil or out.holdEffectParam == nil or out.gender == nil
     or out.friendship == nil or out.nature == nil then
    return nil
  end
  if out.hp > out.maxHp then return nil end

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

  if type(raw.moves) ~= "table" then return nil end
  local moves = {}
  for _, entry in ipairs(raw.moves) do
    if #moves >= Config.BATTLE_MOVE_MAX then return nil end
    local move = M.battleMove(entry, 3)
    if not move then return nil end
    moves[#moves + 1] = move
  end
  if #moves == 0 then return nil end
  out.moves = moves

  if raw.speciesId ~= nil then
    out.speciesId = id3(raw.speciesId)
    if not out.speciesId then return nil end
  end
  if raw.slot ~= nil then
    out.slot = M.int(raw.slot, 0, M.SLOT_MAX)
    if out.slot == nil then return nil end
  end
  if raw.abilityName ~= nil then
    out.abilityName = M.moveName(raw.abilityName)
    if not out.abilityName then return nil end
  end
  if raw.itemName ~= nil then
    out.itemName = M.moveName(raw.itemName)
    if not out.itemName then return nil end
  end
  if raw.weight ~= nil then
    out.weight = M.int(raw.weight, 0, M.WEIGHT3_MAX)
    if out.weight == nil then return nil end
  end
  if raw.hiddenPower ~= nil then
    if type(raw.hiddenPower) ~= "table" then return nil end
    local t = M.int(raw.hiddenPower.type, 0, M.MOVE_TYPE_MAX)
    local p = M.int(raw.hiddenPower.power, 0, M.POWER3_MAX)
    if t == nil or p == nil then return nil end
    out.hiddenPower = { type = t, power = p }
  end
  if raw.beatUp ~= nil then
    if type(raw.beatUp) ~= "table" then return nil end
    local a = M.int(raw.beatUp.atk, 1, 255)
    local d = M.int(raw.beatUp.def, 1, 255)
    if a == nil or d == nil then return nil end
    out.beatUp = { atk = a, def = d }
  end
  if raw.sleepTurns ~= nil then
    out.sleepTurns = M.int(raw.sleepTurns, 0, M.SLEEP3_MAX)
    if out.sleepTurns == nil then return nil end
  end
  if raw.catchRate ~= nil then
    out.catchRate = M.int(raw.catchRate, 0, 255)
    if out.catchRate == nil then return nil end
  end
  if raw.ivs ~= nil then
    out.ivs = block3(raw.ivs, IV_KEYS3, 0, Config.GEN3_IV_MAX)
    if not out.ivs then return nil end
  end
  if raw.evs ~= nil then
    out.evs = block3(raw.evs, IV_KEYS3, 0, Config.GEN3_EV_MAX)
    if not out.evs then return nil end
  end
  if raw.personality ~= nil then
    out.personality = M.int(raw.personality, 0, M.U32_MAX)
    if out.personality == nil then return nil end
  end
  if raw.otId ~= nil then
    out.otId = M.int(raw.otId, 0, M.U32_MAX)
    if out.otId == nil then return nil end
  end
  if raw.ball ~= nil then
    out.ball = M.int(raw.ball, 0, Config.GEN3_ITEM_MAX)
    if out.ball == nil then return nil end
  end
  -- The obedience check's facts about a player's own monster (contract K2,
  -- docs/plans/gen3-badge-rules.md): `true` or absent, so a `false` is kept as
  -- absent and anything that is not a boolean refuses the mon -- the same
  -- posture as the ruleset's `underwater`.  `unfateful` names a Mew / Deoxys
  -- whose fateful-encounter bit is explicitly clear (the engine's
  -- `fatefulEncounter == false`); its absence is the ordinary rules, so the
  -- retired `fateful` is not copied and a sheet still carrying one fights as
  -- if it said nothing.  `unfateful` is Gen 3's alone (neither Kanto nor Johto
  -- cart has an event-Mew rule): the Gen 1 / Gen 2 reader below builds its
  -- sheet field by field and never copies it.  `traded` it does copy, in this
  -- same reading (contract K1 of docs/plans/gen12-referee-fidelity.md).
  if raw.traded ~= nil then
    if type(raw.traded) ~= "boolean" then return nil end
    if raw.traded then out.traded = true end
  end
  if raw.unfateful ~= nil then
    if type(raw.unfateful) ~= "boolean" then return nil end
    if raw.unfateful then out.unfateful = true end
  end
  return out
end

-- `generation` 3 on the sheet selects the Gen 3 dialect above (M.battleParty
-- stamps it from the hub's generation); 1 / 2 / absent is the older dialect
-- below -- as it read before Gen 3 had one, plus the optional K1 / K2 fields
-- (see the header above block3), so a sheet that states none of them reads
-- exactly as it always did.
function M.battleMon(raw)
  if type(raw) ~= "table" then return nil end
  if M.int(raw.generation, 3, 3) then return battleMon3(raw) end

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
    -- This sheet's own dialect (1 or 2, stamped above), so a stray `num` on a
    -- row is ignored rather than sending the row to the Gen 3 reader.
    local move = M.battleMove(entry, generation)
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

  -- What the Gold referee reads off that item (contract K2): the hub holds no
  -- item table, so the effect token, its parameter, the name the box narrates
  -- under and whether it is Mail (which Thief cannot take) ride the sheet the
  -- way Gen 3's holdEffect / holdEffectParam do.  Absent when nothing is held.
  -- Gen 2 only, by the dialect this sheet resolved to: a Gen 1 sheet has no
  -- item to describe, and its reader copies none of these -- the field-by-field
  -- whitelist that keeps Gen 3's `unfateful` off it.  Present and unreadable
  -- refuses the mon, `heldItem`'s posture one field up: a hold effect the
  -- referee cannot read is an item that silently does nothing on one side of
  -- a fight its owner watches it work in.  `mail` is a boolean read the way
  -- `traded` is (below): `true` kept, `false` kept as absent.
  if generation == 2 then
    if raw.holdEffect ~= nil then
      out.holdEffect = M.holdEffect2(raw.holdEffect)
      if not out.holdEffect then return nil end
    end
    if raw.holdParam ~= nil then
      out.holdParam = M.int(raw.holdParam, 0, M.HOLD_PARAM2_MAX)
      if out.holdParam == nil then return nil end
    end
    if raw.itemName ~= nil then
      out.itemName = M.text(raw.itemName, M.ITEM_NAME2_MAX)
      if not out.itemName then return nil end
    end
    if raw.mail ~= nil then
      if type(raw.mail) ~= "boolean" then return nil end
      if raw.mail then out.mail = true end
    end
  end

  -- Optional registry id for the species, alongside the prose `species` above.
  --
  -- `species` is what the fight is *narrated* under, which is the nickname when
  -- the monster has one -- so it is the one field that cannot be resolved back
  -- to a pokedex row, and a nicknamed monster arrived on the other player's
  -- screen as a blank seat with no front pic and no level.  The id is what art,
  -- types and the exp base rate are actually looked up by, so it travels as its
  -- own id-shaped field rather than overloading the prose one (the same rule
  -- the sanitiser's own header states).
  --
  -- Optional both ways: a PROTOCOL 21 client sends none, and a client that
  -- cannot describe the species (an id its own pokedex has no row for) is no
  -- worse off than it was.  Present-but-unreadable refuses the battler, the
  -- posture every other id-shaped field on this sheet gets.
  if raw.speciesId ~= nil then
    out.speciesId = M.id(raw.speciesId)
    if not out.speciesId then return nil end
  end

  -- Optional species base Speed for Gen 1 crit. The hub has no species table,
  -- so this has to ride the sheet; Crit.check must not see battle Speed or the
  -- Speed badge. Absent is a protocol-era client (sim falls back to stats.spd
  -- without a badge boost). Present-but-unreadable refuses the battler.
  if raw.baseSpd ~= nil then
    out.baseSpd = M.int(raw.baseSpd, 0, 255)
    if out.baseSpd == nil then return nil end
  end

  -- The obedience check's one fact about a player's own monster (contract K1):
  -- its 16-bit OT id is not the player's, so its badge cap applies.  Gen 1 and
  -- Gen 2 alike, read exactly as battleMon3 reads Gen 3's -- `true` kept,
  -- `false` kept as absent, anything that is not a boolean refuses the mon --
  -- because the client stamps it the same way on all three and a hub that
  -- read one generation's loosely would let the same typo fight on one cart
  -- and refuse on the next.  No `unfateful` here: that is a Gen 3 rule.
  if raw.traded ~= nil then
    if type(raw.traded) ~= "boolean" then return nil end
    if raw.traded then out.traded = true end
  end

  -- Contract K7 (docs/plans/gen12-referee-gaps-fix.md): what the cart computes
  -- a monster's stats *from*, so the referee can compute one itself -- a
  -- transformed computer foe's crit stat (GetEnemyMonStat runs CalcMonStat
  -- over the copied species with the foe's own DVs), the copied species' base
  -- Speed for the crit rate, and the rebuild after a mid-fight level-up (K9)
  -- when the client states no new stats.  The hub holds no species table and
  -- never will, so these ride the sheet the way `baseSpd` does.  Each block
  -- is optional and whole-or-refused, block3's reading and `ivs` / `evs`'
  -- posture: a block with three of its five numbers is a bug on the sending
  -- side that accepting would silently zero the rest of.
  --
  --   base     the species' base stats, keyed like `stats` plus `hp` --
  --            Gen 1 hp atk def spd spc, Gen 2 hp atk def spe spa spd
  --            (Gold splits Special) -- each 0..BASE_STAT_MAX, a byte.
  --   dvs      the four DVs the cart stores, 0..DV_MAX -- Gen 1 atk def spd
  --            spc, Gen 2 atk def spe spc (one Special DV feeds both of
  --            Gold's special stats).  The HP DV is derived from these, so it
  --            is never a key.
  --   statExp  the cart's five stat-exp words, 0..STAT_EXP_MAX -- `hp` and
  --            the `dvs` keys (Gold keeps one Special word for both special
  --            stats, CalcMonStatC).  The cart's shape rather than `stats`',
  --            so a sheet cannot state two Special values that disagree.
  --
  -- Gen 1 / Gen 2 only: battleMon3 builds its sheet field by field and reads
  -- none of them.  `ivs` / `evs` above are the older blocks keyed like
  -- `stats` (the vitamin store reads `evs`); these are the cart's.
  local keys = generation == 2 and K7_KEYS2 or K7_KEYS1
  if raw.base ~= nil then
    out.base = block3(raw.base, keys.base, 0, M.BASE_STAT_MAX)
    if not out.base then return nil end
    -- Contract K15 (wave 5): Gold's `base` block may carry the species'
    -- BASE_GENDER byte (`gender`) -- a byte of the same base-stats row
    -- (pokecrystal / pokegold data/pokemon/base_stats/*.asm `db GENDER_*`),
    -- which GetGender (engine/pokemon/mon_stats.asm) compares with the
    -- Attack and Speed DVs: GENDER_F0 0 always male, GENDER_F100 254 always
    -- female, GENDER_UNKNOWN 255 genderless.  ATTRACT's CheckOppositeGender
    -- reads it (BattleSim2 Effects.gender, `mon.base.gender`), and the hub
    -- holds no species table, so it rides the sheet as the base stats do.
    -- Not a K7 key: a block stating the base stats and no ratio is the K7
    -- sheet the client already sends, read as before (the referee then
    -- places no gender, so ATTRACT fails -- `.genderless_samegender`).
    -- Present and unreadable refuses the sheet, K7's posture for its own
    -- fields: a dropped ratio would make a monster genderless that the cart
    -- calls male or female.  Gen 2 only, by the dialect this sheet resolved
    -- to: Red has no genders, so a Gen 1 reader neither copies nor refuses
    -- one (block3 keeps only its keys).  Read the way Wire.int reads it on
    -- both twins (lib/sanitize's luaInt).
    if generation == 2 and raw.base.gender ~= nil then
      out.base.gender = M.int(raw.base.gender, 0, M.BASE_STAT_MAX)
      if out.base.gender == nil then return nil end
    end
  end
  if raw.dvs ~= nil then
    out.dvs = block3(raw.dvs, keys.dvs, 0, M.DV_MAX)
    if not out.dvs then return nil end
  end
  if raw.statExp ~= nil then
    out.statExp = block3(raw.statExp, keys.statExp, 0, M.STAT_EXP_MAX)
    if not out.statExp then return nil end
  end

  -- Contract K14 (docs/plans/gen12-referee-gaps-fix.md, added after wave 1):
  -- the monster's happiness, 0..HAPPINESS2_MAX, which Gold's RETURN and
  -- FRUSTRATION turn into power (pokecrystal BattleCommand_HappinessPower /
  -- _FrustrationPower read wBattleMonHappiness or wEnemyMonHappiness, never
  -- a species value) -- so it rides the sheet, as nothing else could tell
  -- the hub.  Gen 2 only, by the dialect this sheet resolved to: Red has no
  -- happiness byte, so a Gen 1 reader neither copies nor refuses one (the
  -- posture it takes to Gold's held-item fields above), and battleMon3
  -- builds Gen 3's sheet field by field with its own `friendship`.
  --
  -- Optional, and **refused with the sheet** when present and unreadable --
  -- K7's posture and `holdParam`'s (the other Gold byte on this sheet), for
  -- their reason: it is an input to a damage formula, and a dropped one
  -- would have the referee fight with a number the owner never had, so the
  -- same RETURN would hit for one amount on the cart and another here.  The
  -- refusal lands at the party upload, before any turn is played; K11's coin
  -- count is dropped instead only because it arrives after the last one.
  -- Read the way Wire.int reads it on both twins (lib/sanitize's luaInt),
  -- new on both like the K7 blocks.
  if generation == 2 and raw.happiness ~= nil then
    out.happiness = M.int(raw.happiness, 0, M.HAPPINESS2_MAX)
    if out.happiness == nil then return nil end
  end

  -- Contract K21 of docs/plans/gen12-referee-remaining-gaps.md: the species'
  -- Pokedex weight word, 0..WEIGHT2_MAX, which the HEAVY BALL reads
  -- (pokecrystal HeavyBallMultiplier, GetFarWord on the dex entry) -- the
  -- Gold referee's copyMon keeps it as the monster's `weight`.  The hub holds
  -- no dex and never will, so it rides the sheet as Gen 3's does.  Gen 2 only,
  -- by the dialect this sheet resolved to (Red's balls read no weight, so a
  -- Gen 1 reader neither copies nor refuses one), and refused with the sheet
  -- when present and unreadable, K14's posture for an input to a formula.
  if generation == 2 and raw.weight ~= nil then
    out.weight = M.int(raw.weight, 0, M.WEIGHT2_MAX)
    if out.weight == nil then return nil end
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
-- A Gen 3 bag id: a pret item number, as a JSON number or the numeric string a
-- map key (or a choice) spells it as.  Nothing else -- no "0x0D", no " 13 ":
-- the JS twin reads these same bytes and the two must agree on every one.
local function itemId3(value)
  if type(value) == "string" then
    if not value:match("^%d+$") then return nil end
  elseif type(value) ~= "number" then
    return nil
  end
  local n = tonumber(value)
  if n ~= math.floor(n) then return nil end
  return M.int(n, 1, Config.GEN3_ITEM_MAX)
end
M.itemId3 = itemId3

-- The Gen 3 bag (docs/plans/gen3-battle-sheet.md §4): `{ { id, count, name? } }`
-- or `{ [id] = count }`, numeric pret ids restricted to BattleSim3's catalog.
-- Out: `{ { id = <number>, count, name? } }` sorted by id.  `name` is the
-- client's display name for "Ann used POTION!" and is optional; present and
-- unreadable refuses, like every optional field in this section.
local function battleBag3(raw)
  local Effects = effectsFor(3)
  local out, seen = {}, {}
  local function push(id, count, name)
    if not id or count == nil then return false end
    if seen[id] then return false end
    if #out >= Config.BATTLE_BAG_MAX then return false end
    if not Effects.itemEffect(id) then return false end
    seen[id] = true
    out[#out + 1] = { id = id, count = count, name = name }
    return true
  end
  if #raw > 0 or raw[1] ~= nil then
    for _, entry in ipairs(raw) do
      if type(entry) ~= "table" then return nil end
      local name = nil
      if entry.name ~= nil then
        name = M.moveName(entry.name)
        if not name then return nil end
      end
      if not push(itemId3(entry.id), M.int(entry.count, 1, Config.BATTLE_BAG_COUNT_MAX), name) then
        return nil
      end
    end
  else
    for key, value in pairs(raw) do
      if not push(itemId3(key), M.int(value, 1, Config.BATTLE_BAG_COUNT_MAX)) then return nil end
    end
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

function M.battleBag(raw, generation)
  if raw == nil then return {} end
  if type(raw) ~= "table" then return nil end
  if generation == 3 then return battleBag3(raw) end

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

-- The three formula inputs a Gen 3 *upload* must carry even though an
-- outcome's caught sheet may leave them out (see battleMon3).
local function uploadComplete3(mon)
  return mon.weight ~= nil and mon.hiddenPower ~= nil and mon.beatUp ~= nil
end

-- A Red trainer's move-choice layers (`aiMods`, wave 6 of
-- docs/plans/gen12-referee-gaps-fix.md): pokered AIEnemyTrainerChooseMoves
-- runs its class's TrainerClassMoveChoiceModifications row
-- (data/trainers/move_choices.asm), a list of AIMoveChoiceModification
-- numbers -- 1..4, where 4 is the routine that does nothing -- and the Red
-- referee layers exactly that list (BattleSim Turn `_aiTrainerMoves`,
-- `fighter.aiMods`).  The client reads the row off its own engine trainer
-- record (the engine extracts it from the player's ROM; the mod ships none of
-- it), so the hub can only pass on what the host's cart says.
--
--   AI_MOD_MAX    the cart's four AIMoveChoiceModification pointers
--   AI_MODS_MAX   layers in one list: the Red referee's MAX_AI_MODS (8)
--
-- Present and empty is a real answer (YOUNGSTER's `.useOriginalMoveSet`: no
-- layer at all), so the list is read as a list (isList; lib/sanitize.js
-- closes a JSON null up first, as the engine's decoder does) and refused
-- WHOLE rather than trimmed: a dropped layer, a value off the four pointers
-- or a list past the cap is a different trainer from the one the host's cart
-- fights with.  Each entry is read the way Wire.int reads it on both twins
-- (lib/sanitize's luaInt).  Twin of lib/sanitize.js's cleanAiMods.
M.AI_MOD_MAX = 4
M.AI_MODS_MAX = 8

local function aiModsOf(raw)
  if not isList(raw) then return nil end
  local n = #raw
  if n > M.AI_MODS_MAX then return nil end
  local out = {}
  for i = 1, n do
    local layer = M.int(raw[i], 1, M.AI_MOD_MAX)
    if layer == nil then return nil end
    out[i] = layer
  end
  return out
end
M.aiMods = aiModsOf

-- The computer's own choices (contract K16 of
-- docs/plans/gen12-referee-remaining-gaps.md): the trainer facts an NPC party
-- carries beside `aiMods` / `name`, which the referees' item / switch AI reads
-- off the seat (`fighter`).  The client reads each off its own engine
-- trainer (extracted from the player's ROM; the mod ships none of it), so the
-- hub passes on only what the host's cart says.
--
-- Red, `aiClass`: the engine's `ai_classes` record for the trainer's class
-- (TrainerAI.classFor), which matches pokered's data/trainers/ai_pointers.asm
-- and the class routines of engine/battle/trainer_ai.asm row for row:
--
--   uses         TrainerAIPointers' first byte, the wAICount TrainerAI loads
--                for each monster -- 1..AI_USES_MAX, and the one key a record
--                cannot do without (a class with no record runs GenericAI)
--   chance       the routine's `cp N percent` against TrainerAI's Random
--                byte, out of 256 -- 0..AI_CHANCE_MAX
--   switchChance AgathaAI's switch roll before her item roll, the same scale
--   item         the item the routine uses (AIUseXAttack, AIUseFullHeal ...),
--                an item id read as every Gen 1 bag id is (M.id)
--   switch       true: the routine is AISwitchIfEnoughMons (JugglerAI)
--   onStatus     true: BrockAI's "only while the active monster has a status"
--   hpBelow      AICheckIfHPBelowFraction's divisor for the item -- 1..
--                AI_DIVISOR_MAX (a byte: `ld a, 10`)
--   switchBelow  CooltrainerFAI's second divisor, for the switch
--
-- Read field by field, so an unknown key is dropped, and refused WHOLE when a
-- key it knows is present and unreadable -- the party with it, `aiMods`'
-- posture: a record half-read is a different class from the one the host's
-- cart fights with.  The booleans read the way `traded` does (`true` kept,
-- `false` kept as absent, anything else refused); every number as Wire.int
-- reads it on both twins (lib/sanitize's luaInt).  Twin of lib/sanitize.js's
-- cleanAiClass.
M.AI_USES_MAX = 255
M.AI_CHANCE_MAX = 256
M.AI_DIVISOR_MAX = 255

local AI_CLASS_INTS = {
  { "uses", 1, M.AI_USES_MAX },
  { "chance", 0, M.AI_CHANCE_MAX },
  { "switchChance", 0, M.AI_CHANCE_MAX },
  { "hpBelow", 1, M.AI_DIVISOR_MAX },
  { "switchBelow", 1, M.AI_DIVISOR_MAX },
}
local AI_CLASS_FLAGS = { "switch", "onStatus" }

local function aiClassOf(raw)
  if type(raw) ~= "table" then return nil end
  if raw.uses == nil then return nil end
  local out = {}
  for _, field in ipairs(AI_CLASS_INTS) do
    local key = field[1]
    if raw[key] ~= nil then
      out[key] = M.int(raw[key], field[2], field[3])
      if out[key] == nil then return nil end
    end
  end
  if raw.item ~= nil then
    out.item = M.id(raw.item)
    if out.item == nil then return nil end
  end
  for _, key in ipairs(AI_CLASS_FLAGS) do
    if raw[key] ~= nil then
      if type(raw[key]) ~= "boolean" then return nil end
      if raw[key] then out[key] = true end
    end
  end
  return out
end
M.aiClass = aiClassOf

-- Gold, four bytes of the class's TrainerClassAttributes
-- (pokecrystal / pokegold data/trainers/attributes.asm; the engine's
-- `attributes[1..7]`), which AI_SwitchOrTryItem, AI_TryItem and AIChooseMove
-- read (engine/battle/ai/items.asm, move.asm):
--
--   trainerItems  TRNATTR_ITEM1 / ITEM2, which LoadEnemyMon copies into
--                 wEnemyTrainerItem1 / 2: an ordered list of 0..TRAINER_ITEMS2_MAX
--                 item ids (M.id, every Gold bag id's reading), the cart's
--                 slot order kept -- AI_TryItem walks item 1 then item 2, and
--                 its base-reward bug reads past whichever slot matched
--   aiFlags       TRNATTR_AI_MOVE_WEIGHTS, the AIChooseMove layer word
--   itemSwitch    TRNATTR_AI_ITEM_SWITCH, the item-use and switch flags
--   baseReward    TRNATTR_BASEMONEY, the wEnemyTrainerBaseReward byte
--                 AI_TryItem's bug reads as an item ("AI might use its base
--                 reward value as an item", docs/bugs_and_glitches.md)
--
-- Each present-and-unreadable one refuses the party (aiClass' posture); a
-- list past its two slots, or with an entry that is not an id, is refused
-- whole.  Twin of lib/sanitize.js's cleanTrainerItems / the Gold bounds.
M.TRAINER_ITEMS2_MAX = 2
M.AI_FLAGS2_MAX = 65535
M.BASE_REWARD2_MAX = 255

local function trainerItemsOf(raw)
  if not isList(raw) then return nil end
  local n = #raw
  if n > M.TRAINER_ITEMS2_MAX then return nil end
  local out = {}
  for i = 1, n do
    local id = M.id(raw[i])
    if id == nil then return nil end
    out[i] = id
  end
  return out
end
M.trainerItems = trainerItemsOf

-- Gold's slot-1 resist reading (contract K23 of
-- docs/plans/gen12-referee-remaining-gaps.md).  pokegold
-- FindEnemyMonsThatResistPlayer (engine/battle/ai/switch.asm) walks from
-- wOTPartyCount rather than wOTPartySpecies, so its first GetBaseData reads
-- the party *count* as a species -- BaseData[count], the species whose
-- number is the party's size -- and every later pass the slot before the one
-- its bit names (pokecrystal fixed the walk).  The hub holds no species
-- table, so the client states that species' two type bytes on a Gold NPC
-- party, as the chart indices a sheet's `types` are: 1..COUNT_SPECIES_TYPES2_MAX
-- of them, each 0..BATTLE_TYPE_MAX - 1.  Refused whole -- and the party with it,
-- K16's posture for an input to the computer's choice -- when it is not such a
-- list: a third entry is no species' base types, and a type list half-read is
-- a different matchup from the one the host's cart computes.  Twin of
-- lib/sanitize.js's cleanCountSpeciesTypes.
M.COUNT_SPECIES_TYPES2_MAX = 2

local function countSpeciesTypesOf(raw)
  if not isList(raw) then return nil end
  local n = #raw
  if n < 1 or n > M.COUNT_SPECIES_TYPES2_MAX then return nil end
  local out = {}
  for i = 1, n do
    local t = M.int(raw[i], 0, Config.BATTLE_TYPE_MAX - 1)
    if t == nil then return nil end
    out[i] = t
  end
  return out
end
M.countSpeciesTypes = countSpeciesTypesOf

function M.battleParty(raw, generation)
  if type(raw) ~= "table" then return nil end
  local battle = M.id(raw.battle)
  if not battle then return nil end

  local out = { battle = battle, badges = M.badges(raw.badges) }

  -- Hub generation (second arg) is authoritative when provided: stamp
  -- party.generation from it, and refuse a mon/party whose explicit
  -- generation disagrees.  1..GENERATION_MAX: a Gen 3 hub (PROTOCOL 30) reads
  -- its parties in the Gen 3 dialect (battleMon3, battleBag3).
  local hubGen = nil
  if generation ~= nil then
    hubGen = M.int(generation, 1, M.GENERATION_MAX)
    if not hubGen then return nil end
  end

  local partyGen = nil
  if raw.generation ~= nil then
    partyGen = M.int(raw.generation, 1, M.GENERATION_MAX)
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

  -- Wave 6 of docs/plans/gen12-referee-gaps-fix.md: the two facts an NPC
  -- party carries about the trainer rather than its monsters.  Read off any
  -- party (the wire cannot tell an NPC upload from a human's -- the hub can,
  -- and copies them onto the NPC seats alone: Hub:fillBattleParty,
  -- tryStartSim), by the dialect this party resolved to:
  --
  --   aiMods  Red only (aiModsOf): the class's move-choice layers.  Gold's
  --           AI is not the layer list (pokecrystal's AIChooseMove scores by
  --           the trainer's AI flags), so a Gen 2 / Gen 3 reader -- or one
  --           naming no generation -- neither copies nor refuses one.
  --           Present and unreadable refuses the party, K7's posture: the
  --           layers decide the computer's pick.
  --   name    Red and Gold (M.npcName): the trainer's display name, which the
  --           referee prints as the seat's name (Red's AI item line; Gold's
  --           "<NAME> used an item").  Cosmetic, so an unreadable one is
  --           dropped -- the hub then names the seat "TRAINER" as it always
  --           has -- rather than costing the fight.  Gen 3's referee names
  --           its trainer from its own sheet, so a Gen 3 reader ignores it.
  if partyGen == 1 and raw.aiMods ~= nil then
    out.aiMods = aiModsOf(raw.aiMods)
    if out.aiMods == nil then return nil end
  end
  if (partyGen == 1 or partyGen == 2) and raw.name ~= nil then
    out.name = M.npcName(raw.name)
  end
  -- K16 of docs/plans/gen12-referee-remaining-gaps.md: the computer's item /
  -- switch facts, by the same dialect gate (copied onto the NPC seats alone
  -- by the hubs, as `aiMods` is).  Each one decides the computer's choice, so
  -- each present-and-unreadable one refuses the party, `aiMods`' posture; a
  -- reader of another generation -- or of none -- neither copies nor refuses
  -- one.
  --
  --   aiClass       Red only (aiClassOf): the class's TrainerAI record.
  --   trainerItems  Gold only (trainerItemsOf): wEnemyTrainerItem1 / 2.
  --   aiFlags       Gold only: TRNATTR_AI_MOVE_WEIGHTS, 0..AI_FLAGS2_MAX.
  --   itemSwitch    Gold only: TRNATTR_AI_ITEM_SWITCH, 0..AI_FLAGS2_MAX.
  --   baseReward    Gold only: TRNATTR_BASEMONEY, 0..BASE_REWARD2_MAX.
  --   countSpeciesTypes  Gold only (K23, countSpeciesTypesOf): the base types
  --                 of the species numbered the party's size, which Gold's
  --                 FindEnemyMonsThatResistPlayer reads for its first pass.
  if partyGen == 1 and raw.aiClass ~= nil then
    out.aiClass = aiClassOf(raw.aiClass)
    if out.aiClass == nil then return nil end
  end
  if partyGen == 2 then
    if raw.trainerItems ~= nil then
      out.trainerItems = trainerItemsOf(raw.trainerItems)
      if out.trainerItems == nil then return nil end
    end
    if raw.aiFlags ~= nil then
      out.aiFlags = M.int(raw.aiFlags, 0, M.AI_FLAGS2_MAX)
      if out.aiFlags == nil then return nil end
    end
    if raw.itemSwitch ~= nil then
      out.itemSwitch = M.int(raw.itemSwitch, 0, M.AI_FLAGS2_MAX)
      if out.itemSwitch == nil then return nil end
    end
    if raw.baseReward ~= nil then
      out.baseReward = M.int(raw.baseReward, 0, M.BASE_REWARD2_MAX)
      if out.baseReward == nil then return nil end
    end
    if raw.countSpeciesTypes ~= nil then
      out.countSpeciesTypes = countSpeciesTypesOf(raw.countSpeciesTypes)
      if out.countSpeciesTypes == nil then return nil end
    end
  end

  if type(raw.mons) ~= "table" then return nil end
  local mons = {}
  for _, entry in ipairs(raw.mons) do
    if #mons >= Config.BATTLE_MON_MAX then return nil end
    -- A sheet's own `generation`, when it states one, is a generation or the
    -- party is refused -- with or without a hub generation to hold it to.
    -- Without one this used to let an unreadable tag (6, -6, "day") fall
    -- through to battleMon's sniff of the stat keys, where sanitize.js
    -- refused the party: one upload, two answers (the review's differential
    -- fuzzer).  Every hub passes its generation, so no caller read the
    -- fallback; the stricter reading is the twins' one now.
    local hadExplicit = type(entry) == "table" and entry.generation ~= nil
    if hadExplicit then
      local monGen = M.int(entry.generation, 1, M.GENERATION_MAX)
      if not monGen or (hubGen and monGen ~= hubGen) then return nil end
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
    -- A Gen 3 sheet read as Gen 3 has to be complete as an upload, and a
    -- Gen 3 party has no Gen 1 / Gen 2 mon in it (a sheet whose own tag the
    -- stamp did not reach -- an explicit 2 on a party that said 3 -- is
    -- refused above; this closes the mixed party with no hub generation).
    if mon.generation == 3 and not uploadComplete3(mon) then return nil end
    if (partyGen == 3) ~= (mon.generation == 3) then return nil end
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

-- Gen 3's own actions (contract C6 of docs/plans/gen3-solo-remaining-fights.md),
-- in a table of their own for M.BATTLE_EVENTS3's reason: the five above are every
-- generation's, and a Red / Gold reader -- or a caller naming no generation --
-- must go on refusing an action its cart has no menu for.  M.battleChoice reads
-- them for a generation 3 reader only.
--
--   safari  -- one Safari Zone command, `throw` saying which (M.SAFARI_THROWS3).
--              The cart swaps the whole action menu for the safari controller's
--              (pret src/battle_controller_safari.c HandleInputChooseAction:
--              B_ACTION_SAFARI_BALL / _BAIT or _POKEBLOCK / _GO_NEAR / _RUN), and
--              none of the four is a FIGHT, an ITEM or a SWITCH -- so one action
--              with a required `throw` rather than four more rows.  The menu's
--              RUN is the ordinary `run` above (HandleAction_SafariZoneRun is the
--              escape that always works, which is a referee's rule, not a word).
--
--   wallyThrow -- WALLY's turn-3 command in Emerald's catching tutorial
--              (wave 4b's contract C-W): pokeemerald src/battle_controller_
--              wally.c WallyHandleActions files B_ACTION_WALLY_THROW with no
--              cursor move and no data (BtlController_EmitTwoReturnValues(...,
--              B_ACTION_WALLY_THROW, 0)) -- the recall and "You throw a BALL
--              now, right?" turn, which is neither a FIGHT, an ITEM nor a
--              SWITCH.  It needs nothing, as `run` needs nothing; only a
--              `tutorial = "wally"` referee takes it, from WALLY's seat alone
--              -- side a's first (BattleSim3 `_normaliseChoice`).
--
-- No PROTOCOL bump: no hub seats a Safari fight or a tutorial -- only solo's
-- local referee does -- so a hub never needs to hear either.  A Gen 3 hub that
-- is sent one anyway reads it here and its referee refuses it (BattleSim3
-- `_normaliseChoice`, every mode a hub seats), the way it refuses any action
-- its fight has no arm for.
M.BATTLE_ACTIONS3 = {
  safari = "throw",
  wallyThrow = true,
}

-- The five things a Safari turn can throw, each one pret action handler
-- (src/battle_main.c sTurnActionsFuncsTable):
--
--   ball   -- HandleAction_SafariZoneBallThrow      (both carts)
--   bait   -- HandleAction_ThrowBait                (FR / LG: B_ACTION_SAFARI_BAIT)
--   rock   -- HandleAction_ThrowRock                (FR / LG: B_ACTION_SAFARI_GO_NEAR)
--   near   -- HandleAction_GoNear                   (Emerald: B_ACTION_SAFARI_GO_NEAR)
--   block  -- HandleAction_ThrowPokeblock           (Emerald: B_ACTION_SAFARI_POKEBLOCK)
--
-- One closed set for both carts: which family has which throw is the
-- referee's to refuse (it knows the cart; the wire does not), exactly as a
-- `fight`'s move index is checked against the moves the seat holds there and
-- not here.  B_ACTION_SAFARI_WATCH_CAREFULLY is the wild monster's, never the
-- player's, so it is no word on a choice.
M.SAFARI_THROWS3 = { ball = true, bait = true, rock = true, near = true, block = true }

-- The most blocks Emerald's POKéBLOCK case holds (pokeemerald
-- include/constants/global.h POKEBLOCKS_COUNT).  A `block` throw's `block` is
-- one of the case's slots, 1-based as a Lua list is -- the cart's own
-- gSpecialVar_ItemId plus one (src/battle_controller_safari.c
-- CompleteWhenChosePokeblock hands the case's index to the engine).
M.POKEBLOCK3_MAX = 40

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
--
-- `generation` (optional) is the hub's.  Only 3 reads Gen 3's two extra fields
-- below; a Gen 1 / Gen 2 hub -- and a caller that names none -- reads a choice
-- exactly as it did before Gen 3 existed, ignoring them whatever they hold.
-- Likewise only 1 reads Gen 1's `mimic` (wave 4), ignored everywhere else,
-- and since wave 5 a Gen 2 hub reads `pass` too (Gold's BATON PASS).  Only 3
-- reads an action from M.BATTLE_ACTIONS3 (`safari`, contract C6; `wallyThrow`,
-- contract C-W): any other reader refuses it whole, as it refuses every action
-- it has no row for.
function M.battleChoice(raw, generation)
  if type(raw) ~= "table" then return nil end
  local needs = M.BATTLE_ACTIONS[raw.action]
    or (M.int(generation, 3, 3) and M.BATTLE_ACTIONS3[raw.action])
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
  -- Gen 3 (docs/plans/gen3-battle-sheet.md §1.2).  `pass` is Baton Pass's
  -- destination -- a *party* index, asked up front because a mediated fight
  -- cannot open the party menu mid-move -- and `dexCaught` is the thrower's
  -- word that its dex already has the wild species caught (Repeat Ball).  A
  -- Gen 3 item rides in `item` as its numeric pret id spelled as a string
  -- ("13"), which M.id already takes.  Neither field exists in Gen 1, so
  -- neither is read there: a stray `pass` on a Gen 1 choice is ignored, as
  -- it always was, rather than refusing the turn.
  --
  -- Gold has BATON PASS too (wave 5 of docs/plans/gen12-referee-gaps-fix.md):
  -- pokecrystal / pokegold BattleCommand_BatonPass opens the party menu
  -- mid-move (`ForcePickSwitchMonInBattle`), so its successor is asked up
  -- front exactly as Gen 3's is -- the same zero-based party index, the same
  -- bounds, refused when out of range -- and the Gold referee reads it where
  -- the cart asks the player (BattleSim2 Turn `_batonPass`, after
  -- `_normaliseChoice` maps it to its party place).  `dexCaught` stays Gen
  -- 3's: Gold has no Repeat Ball.  Red has no BATON PASS, so a Gen 1 hub --
  -- and a caller naming no generation -- still ignores a `pass`.
  if M.int(generation, 2, 3) and raw.pass ~= nil then
    out.pass = M.int(raw.pass, 0, M.SLOT_MAX)
    if out.pass == nil then return nil end
  end
  if M.int(generation, 3, 3) then
    if raw.dexCaught ~= nil then
      if type(raw.dexCaught) ~= "boolean" then return nil end
      out.dexCaught = raw.dexCaught
    end
    -- A Safari command (contract C6): `throw` is required and one of the
    -- closed five -- an unknown one refuses the choice, because the nearest
    -- known throw would be a different turn (a BALL spent for a BAIT).  A
    -- `block` throw may name its case slot, 1..POKEBLOCK3_MAX; present and out
    -- of range refuses, `pass`'s posture (a dropped index would be some other
    -- block, or none).  `block` on any other throw is a stray field and
    -- ignored, as a Gen 1 `pass` is.  Nothing of either is read on any other
    -- action.
    if raw.action == "safari" then
      if not M.SAFARI_THROWS3[raw.throw] then return nil end
      out.throw = raw.throw
      if raw.throw == "block" and raw.block ~= nil then
        out.block = M.int(raw.block, 1, M.POKEBLOCK3_MAX)
        if out.block == nil then return nil end
      end
    end
  end
  -- Gen 1 (wave 4 of docs/plans/gen12-referee-gaps-fix.md): MIMIC's pick --
  -- the 0-based index into the TARGET's move list -- asked up front, as
  -- `pass` is above, because pokered MimicEffect opens the foe's move menu
  -- mid-move (`.letPlayerChooseMove`), which a mediated fight cannot.  The
  -- Red referee reads it where the cart asks the player (BattleSim Turn
  -- `_mimicPick`, a player seat against the computer) and checks it against
  -- the moves the target holds when MIMIC lands.  Bounded by the move list's
  -- own width, as `move` is.  Gold's MIMIC copies the target's last move with
  -- no menu (BattleCommand_Mimic) and Gen 3's has none either, so only a
  -- Gen 1 hub reads it -- a caller naming no generation reads a choice as it
  -- always did -- and a stray one elsewhere is ignored rather than refusing
  -- the turn.  Present and out of range refuses the choice, `pass`'s
  -- posture: a dropped pick would be the menu's first row, a different move.
  if M.int(generation, 1, 1) and raw.mimic ~= nil then
    out.mimic = M.int(raw.mimic, 0, Config.BATTLE_MOVE_MAX - 1)
    if out.mimic == nil then return nil end
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
--   moves      -- mid-fight move-list sync: `mon` (party index) on a PP
--                 spend/restore; absent on Transform/Mimic (overlay only)
--   exp        -- a faint's spoils, as facts: who fell (species, level), how
--                 many shares split it, and which of the paid side's six is
--                 banking this share (`mon`, optional).  Not an amount: the hub
--                 holds no species table and can never compute one, so the
--                 referee states the facts and each client runs its own
--                 Experience formula over its own party.  Gen 3 adds the
--                 holders-only fact: `participants` 0 and no `mon`.
M.BATTLE_EVENTS = {
  msg = true, anim = true, damage = true, drain = true, faint = true,
  send = true, status = true, stat = true, switch = true, item = true,
  run = true, turn = true, over = true, wait = true, reconnect = true,
  chose = true, unchose = true, moves = true, exp = true, team = true,
}

-- Gen 3's eight kinds (docs/plans/gen3-battle-sheet.md §7.2, contract C5; `obey`
-- is contract K3 of docs/plans/gen3-badge-rules.md; `lesson` is contract C6 of
-- docs/plans/gen3-solo-remaining-fights.md).
--
-- A table of their own rather than eight more rows above, because
-- src/BattleSim/events.lua mirrors M.BATTLE_EVENTS *exactly* (its suite holds
-- the two equal), and a Gen 1 referee has no ability, weather or held item to
-- speak of.  M.battleEvent accepts a kind from either table -- a client
-- sanitises whichever generation's stream it is drawing -- and BattleSim3's own
-- vocabulary is the union of the two (server/twin_parity.test.js).  Gold's
-- `held` is M.BATTLE_EVENTS2 below: the same word, a different event.
--
--   ability    -- an ability visibly acted (amount = ability id, text = name)
--   weather    -- weather started (1), continues (2) or ended (0); text = kind
--   held       -- a held item acted; `holding` is what the mon holds after
--   form       -- the picture changed: Castform's form, or Transform's species
--   sub        -- the substitute doll went up (1) or faded (0)
--   ball       -- one throw: target = wild slot, amount = shakes (4 = caught),
--                 text = the ball's item id
--   obey       -- a player's mon disobeyed: a traded one over its badge cap, or
--                 a Mew / Deoxys whose sheet says `unfateful` (cap 0, whatever
--                 the badges) -- text = the branch token, gen3-battle-sheet.md
--                 §7.2.1; the referee's own `msg` sentence follows it
--   lesson     -- Oak's lab (contract C6 of docs/plans/gen3-solo-remaining-fights.md):
--                 one of the professor's teaching moments just came true --
--                 text = the lesson's id (`damage`: the foe's HP bar first
--                 moved, pokefirered src/battle_controller_opponent.c
--                 CompleteOnHealthbarDone, state-2 flag 1; `stat`: a foe's
--                 stat first fell, src/battle_controller_oak_old_man.c on
--                 STRINGID_DEFENDERSSTATFELL, FIRST_BATTLE_MSG_FLAG_STAT_CHG),
--                 read as an `item`'s id is.  The screen says Oak's page for it; the referee's
--                 rule it flips (no misses, no crits until then) is the
--                 referee's own.  No PROTOCOL bump: only solo's local
--                 referee seats a first battle, so no hub ever emits one.
--   palace     -- the Battle Palace (wave 3): text = M.PALACE_TOKENS3 --
--                 `unable` ("<X> appears incapable of using its power!",
--                 pokeemerald battle_util.c:263) or `flavor` (the half-HP
--                 line, battle_script_commands.c:6384) with amount = its
--                 gBattlePalaceFlavorTextTable index; the referee's `msg`
--                 follows either.
--   arena      -- the Battle Arena referee (wave 3): text = M.ARENA_TOKENS3 --
--                 `start` (Commence battling!), `judge` (That's it!), `mind` /
--                 `skill` / `body` per side with amount = the points awarded
--                 (2 / 1 / 0), then `win` (side) or `draw`.  Neither kind has
--                 a PROTOCOL bump: only solo's local referee seats a Frontier
--                 hall, so no hub ever emits one.
--   wallyThrow -- WALLY's recall-and-throw turn ran, in its turn order (wave
--                 4b's contract C-W; pokeemerald src/battle_util.c
--                 HandleAction_WallyBallThrow): `slot` / `side` name WALLY's
--                 field slot (side a's first seat, the only one the referee
--                 lets throw, so no seat id rides).  No `msg` follows --
--                 the recall and "You throw a BALL now, right?" are the
--                 screen's.  No PROTOCOL bump: only solo's local referee
--                 seats Emerald's catching tutorial.
M.BATTLE_EVENTS3 = {
  ability = true, weather = true, held = true, form = true, sub = true, ball = true,
  obey = true, lesson = true, palace = true, arena = true, wallyThrow = true,
}

-- Gold's one kind of its own (contract K3 of docs/plans/gen12-referee-fidelity.md),
-- in a table of its own for M.BATTLE_EVENTS3's reason: the Gen 1 sim's
-- vocabulary is held equal to M.BATTLE_EVENTS, and a Kanto cart has no held
-- item to speak of.  M.battleEvent accepts it for a generation 2 reader only;
-- a Gen 3 reader keeps reading its own `held` (BATTLE_EVENTS3) as before.
--
--   held  -- a held item acted: `slot` / `side` / `mon` say whose, `text` is
--            the item's id (an M.id, like an `item` event's -- not prose: the
--            client matches it against the save's own held item), `amount`
--            is 1 when the mon still holds it afterwards and 0 when it is gone
--            (eaten, or taken by Thief).  The referee's own `msg` sentence
--            follows it, so the screen never phrases one.
M.BATTLE_EVENTS2 = {
  held = true,
}

-- The three ball states a roster is spelled in, and the most of them a seat may
-- claim.  Mirrored from src/BattleSim/events.lua rather than required from it,
-- for the reason that file's header gives: the sim runs with no Config.
--
--   o  standing, nothing wrong with it
--   s  standing, carrying a status
--   x  down
--
-- No token for an empty slot.  An empty slot is not a party member -- the
-- roster says that by being short, and its length is therefore the party size,
-- which is half of what the event is for.
M.TEAM_TOKENS = { o = true, s = true, x = true }

-- A seat's roster.
--
-- **Refused whole rather than trimmed to the part that parses**, which is the
-- opposite of what `M.text` does one function down, and the difference is what
-- the value is for.  A truncated sentence is a shorter sentence; a truncated
-- roster is a *different party* -- three balls where the seat holds five -- and
-- a client would draw the other player as two monsters closer to beaten than
-- they are.  There is no partially-correct reading of this field, so a
-- malformed one is dropped and the chip keeps the last roster it was told.
--
-- Bounded by BATTLE_MON_MAX because that is the rule the referee builds parties
-- under (`Turn.MONS_PER_PARTY`), and empty is refused because a seat with no
-- monsters is not a seat that is in the fight.
function M.battleTeam(value)
  if type(value) ~= "string" then return nil end
  local n = #value
  if n < 1 or n > Config.BATTLE_MON_MAX then return nil end
  for i = 1, n do
    if not M.TEAM_TOKENS[value:sub(i, i)] then return nil end
  end
  return value
end

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
-- player.  A Red / Gold `msg` is the one exception (BATTLE_LINE_MAX, below).
--
-- `seq` has a floor and no ceiling.  It is only ever compared, never sized, so an
-- absurdly large one sorts late and does nothing else -- whereas a cap would be a
-- battle length nobody chose.
--
-- `generation` (optional) is the reader's own.  1 or 2 reads an event as it
-- did before Gen 3 had a stream: the older vocabulary only (none of Gen 3's
-- kinds), none of its six fields (target, spread, stat, stage, delta,
-- holding), and `moves` rows in the older dialect whatever `num` they carry.
-- The one addition since is Gold's own `held` (M.BATTLE_EVENTS2, contract
-- K3), which a generation 2 reader alone accepts -- a Gen 1 reader's
-- vocabulary is unchanged, and every event a Gold reader already accepted
-- reads exactly as before.  3, or none named, reads the union of the older
-- vocabulary and Gen 3's -- which is what a caller that does not say needs in
-- order to draw a Gen 3 referee's stream, and so its `held` is Gen 3's.
function M.battleEvent(raw, generation)
  if type(raw) ~= "table" then return nil end
  local gen = M.int(generation, 1, M.GENERATION_MAX)
  local older = gen == 1 or gen == 2
  local gold = gen == 2
  if not (M.BATTLE_EVENTS[raw.t] or (not older and M.BATTLE_EVENTS3[raw.t])
          or (gold and M.BATTLE_EVENTS2[raw.t])) then
    return nil
  end
  local battle = M.id(raw.battle)
  local seq = M.int(raw.seq, 0)
  if not (battle and seq) then return nil end

  local out = { battle = battle, seq = seq, t = raw.t }
  -- A Gold `held` is the one kind whose shape depends on who reads it.
  local held2 = gold and raw.t == "held"
  -- Item / anim `text` is an id (POKE_BALL, TOSS_ANIM, move id) — M.text strips `_`.
  -- A Gen 3 `ball` names its ball the way `item` does (the numeric id, "4"),
  -- and so does a Gold `held` (LEFTOVERS): the client matches it against the
  -- item its own save holds, where Gen 3's `held` text is the name it prints.
  -- An `obey`'s is one of the eight outcome tokens (M.OBEY_TOKENS3) or nothing:
  -- dropped like any mangled field, so the screen falls back to the referee's
  -- own sentence that follows it rather than phrasing a token it has no line for.
  -- A Red / Gold reader's `msg` is the referee's own line in the cart's
  -- English (wave 6 of docs/plans/gen12-referee-gaps-fix.md), so it reads the
  -- carts' battle glyphs too -- é, …, ♂, ♀, & -- and, since K17 / K18 of
  -- docs/plans/gen12-referee-remaining-gaps.md, the line's `^a` / `^b` name
  -- marks and its `\n` breaks (M.battleLine), cut at BATTLE_LINE_MAX glyphs
  -- rather than chat's MESSAGE_MAX.  Every other kind's text -- a `run`'s or a
  -- `send`'s is a name, which never reads a mark -- and a Gen 3 (or unnamed)
  -- reader's `msg`, reads exactly as before.  A Gen 3 `lesson`'s text is the
  -- lesson's id (contract C6), an id like an `item`'s: never prose, so a
  -- mangled one is dropped rather than cleaned into a word nobody sent.
  if raw.text ~= nil then
    if raw.t == "item" or raw.t == "anim" or raw.t == "ball" or raw.t == "lesson" or held2 then
      out.text = M.id(raw.text)
    elseif raw.t == "obey" then
      out.text = M.OBEY_TOKENS3[raw.text] and raw.text or nil
    elseif raw.t == "palace" then
      out.text = M.PALACE_TOKENS3[raw.text] and raw.text or nil
    elseif raw.t == "arena" then
      out.text = M.ARENA_TOKENS3[raw.text] and raw.text or nil
    elseif older and raw.t == "msg" then
      out.text = M.battleLine(raw.text)
    else
      out.text = M.text(raw.text, Config.MESSAGE_MAX)
    end
  end
  -- A Gold `held`'s `amount` is a flag, not a quantity: 1 the mon still holds
  -- the item, 0 it is gone.  Anything else is dropped like any mangled field --
  -- and a `held` with no `amount` changes nothing a client keeps, which is the
  -- safe reading of an item nobody can say the fate of.  Read the way the
  -- Gen 3 fields are (M.int on both twins: lib/sanitize's luaInt), because the
  -- reading is new on both.
  if raw.amount ~= nil then
    if held2 then
      out.amount = M.int(raw.amount, 0, 1)
    else
      out.amount = M.int(raw.amount, 0, M.AMOUNT_MAX)
    end
  end
  -- A field slot here, unlike the party index a choice carries under the same
  -- name: an event is about somebody who is out, not about a bench position.
  if raw.slot ~= nil then out.slot = M.int(raw.slot, 0, M.FIELD_MAX) end
  if raw.hp ~= nil then out.hp = M.int(raw.hp, 0, M.HP_MAX) end
  -- What that HP is out of, on the events that can move it: `send` states it
  -- for the monster walking on, and a `drain` states it when an HP UP raised
  -- the ceiling itself.  Optional, and its absence is not a zero: a client
  -- that is told none falls back to the oldest reading of this wire -- the
  -- largest HP it has ever seen on the seat -- which is right for a monster
  -- that came out whole and wrong for one that came out hurt.  Floored at 1
  -- for the reason M.battleMon floors it there: the bar divides by it.
  if raw.maxHp ~= nil then out.maxHp = M.int(raw.maxHp, 1, M.HP_MAX) end
  -- `exp` carries the facts a client needs to run its own award: which monster
  -- fell and how many shares split it.  Same sanitisers a battler's own fields
  -- get (M.name / M.int over LEVEL_MAX), because they are the same quantities
  -- read off the same monster -- an event is not a second dialect for them.
  if raw.species ~= nil then out.species = M.name(raw.species) end
  -- The same monster's registry id, and the reason it is a second field rather
  -- than a spelling of the one above: `species` is prose (a nickname when the
  -- monster has one), and prose resolves back to a pokedex row only by luck.
  -- `send` / `switch` carry it so the seat opposite can draw a front pic and an
  -- exp award can price a nicknamed monster; `exp` carries it for the award.
  -- Optional -- an intermediator that predates it sends none, and every reader
  -- falls back to matching the prose name exactly as it did before.
  if raw.speciesId ~= nil then out.speciesId = M.id(raw.speciesId) end
  if raw.level ~= nil then out.level = M.int(raw.level, 1, M.LEVEL_MAX) end
  if raw.participants ~= nil then
    -- Deliberately not `winners`: an OUTCOME's winners is a list of player ids,
    -- and one name over two shapes is the sanitiser bug that reads a count as a
    -- roster.  This one is a count, and on Gen 1 / Gen 2 it divides.
    --
    -- Gen 3 (or none named) also reads 0: BattleSim3's holders-only fact
    -- (sheet doc §7.1), which carries no `mon` -- see M.PARTICIPANTS_MAX.
    out.participants = M.int(raw.participants, older and 1 or 0, M.PARTICIPANTS_MAX)
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
  -- The `team` event's roster (PROTOCOL 24), and the one field here that is
  -- neither a number nor prose: a fixed alphabet, one character per party
  -- member.  Dropped rather than trimmed when it does not parse -- see
  -- `M.battleTeam`, where a short roster is a different party rather than a
  -- shorter sentence.  A `team` event that loses its roster is an event with
  -- nothing in it, which is exactly what a client ignores.
  if raw.team ~= nil then out.team = M.battleTeam(raw.team) end
  if raw.side ~= nil then out.side = M.side(raw.side) end
  if raw.status ~= nil then
    -- battleStatus answers `false` for present-but-unknown, which is not a
    -- status and must not be stored as one.
    out.status = M.battleStatus(raw.status) or nil
  end
  -- Fight-local volatile, not a standing status: 1 confused, 0 snapped out.
  -- Absent means "do not touch the chip". Never a party-sheet field.
  if raw.confused ~= nil then out.confused = M.int(raw.confused, 0, 1) end
  -- Gen 3's six fields (§7.3), each dropped rather than fatal like the rest:
  --   target   the field slot a move (anim) or a ball is aimed at
  --   spread   1 when one move animation covers several targets
  --   stat     which stat a `stat` event moved (atk def spe spa spd acc eva)
  --   stage    the stage it now sits at, -6..6
  --   delta    the change actually applied, signed -- Gen 3 states it here
  --            rather than in `amount`, which is unsigned on every kind
  --   holding  the item id a `held` event leaves the mon holding (0 = none)
  if not older then
    if raw.target ~= nil then out.target = M.int(raw.target, 0, M.FIELD_MAX) end
    if raw.spread ~= nil then out.spread = M.int(raw.spread, 0, 1) end
    if raw.stat ~= nil and M.EVENT_STATS3[raw.stat] then out.stat = raw.stat end
    if raw.stage ~= nil then out.stage = M.int(raw.stage, -M.STAGE3_MAX, M.STAGE3_MAX) end
    if raw.delta ~= nil then out.delta = M.int(raw.delta, -M.DELTA3_MAX, M.DELTA3_MAX) end
    if raw.holding ~= nil then out.holding = M.int(raw.holding, 0, Config.GEN3_ITEM_MAX) end
  end
  -- The one Gen 3 field the older dialect now reads too (contract K10 of
  -- docs/plans/gen12-referee-gaps-fix.md): a `stat` event's signed stage,
  -- -6..6, where the stat now sits.  `amount` stays what it was -- unsigned,
  -- so a stage below zero never fit in it and a lowered stat reached the
  -- screen with no number at all.  Dropped like every mangled field here.
  if older and raw.stage ~= nil then
    out.stage = M.int(raw.stage, -M.STAGE12_MAX, M.STAGE12_MAX)
  end
  -- Contract K22 of docs/plans/gen12-referee-remaining-gaps.md: an `anim`
  -- whose move id is not its user's own use of the move -- Leech Seed's ABSORB
  -- on the seeder's seat (pokered HandlePoisonBurnLeechSeed), FLY's charge
  -- turn played as TELEPORT (pokered ChargeEffect), a trap's per-turn hit, a
  -- weather turn -- says so with `quiet = true`, and the screen plays the
  -- look alone: no trainer callout, no lunge.  Red / Gold readers only, on
  -- `anim` only (Gen 3's stream has its own vocabulary and no such beat).
  -- `true` is kept and anything else dropped, never refused -- this
  -- section's rule for an optional field (an event is never refused over
  -- one), and `false` is the absence it would mean anyway.
  if older and raw.t == "anim" and raw.quiet == true then out.quiet = true end
  if type(raw.moves) == "table" then
    local moves = {}
    for _, entry in ipairs(raw.moves) do
      if #moves >= Config.BATTLE_MOVE_MAX then break end
      local move = M.battleMove(entry, gen)
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
--
-- `generation` (optional) is the reader's own, M.battleEvent's convention.
-- Every reader reads `payDay` (Gen 1 / Gen 2 from contract K11 of
-- docs/plans/gen12-referee-gaps-fix.md); the bound is the reader's cart's --
-- PAYDAY12_MAX for 1 or 2, PAYDAY3_MAX for 3 or none named, exactly as
-- before.
function M.battleOutcome(raw, generation)
  if type(raw) ~= "table" then return nil end
  local gen = M.int(generation, 1, M.GENERATION_MAX)
  local older = gen == 1 or gen == 2
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
  -- Pay Day coins (Gen 3: sheet doc §1, §6; Gen 1 / Gen 2: contract K11):
  -- side a's total, present only on a knockout win in a wild / coop_wild /
  -- coop_npc fight -- and, on Red alone, on a wild fight that ended in an
  -- escape (reason `run`): pokered's EndOfBattle pays wTotalPayDayMoney
  -- whenever wBattleResult is still 0, and a Teleport / Whirlwind / Roar /
  -- POKE DOLL escape never writes it.  Gold's every escape is a DRAW
  -- (SetBattleDraw, WildFled_EnemyFled_LinkBattleCanceled, the run command)
  -- and ExitBattle skips CheckPayDay on one; Gen 3 pays only from
  -- HandleEndTurn_BattleWon -- so both hubs keep the field off a Gold or
  -- Gen 3 run (Hub:settleMediated, Relay.settleMediated).  This reader reads
  -- it on every outcome alike, whatever the reason: which endings pay is the
  -- referee's to say and the hub's to forward, and on a run the payees are
  -- side a's players whichever list names them.
  --
  -- **Dropped rather than fatal**, unlike the fields above, and the
  -- difference is who a bad value can hurt.  A wrong winner or catcher moves
  -- a rating or a monster to the wrong player, so refusing is the safe
  -- failure; a mangled coin count has no recipient of its own (side a of a
  -- fight against the computer is every player in it), and refusing the
  -- whole outcome over it would leave a finished fight on a screen with no
  -- way out -- M.battleReason's argument -- to protect a bonus.  The Amulet
  -- Coin doubling is the reader's, never the wire's.  A zero is no coins,
  -- read as absent on every cart.
  if raw.payDay ~= nil then
    out.payDay = M.int(raw.payDay, 1, older and M.PAYDAY12_MAX or M.PAYDAY3_MAX)
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

-- mmo.battle_moveset. One of the sender's own party members, as they now
-- claim its moves. Bounded numbers, 1..BATTLE_MOVE_MAX long; a missing field
-- refuses the message rather than applying a half-sheet over a live battler.
-- The hub then allows only an append of one slot or a single-id replace.
--
-- `generation` (optional) is the hub's, and picks the move-row dialect the way
-- M.battleMove documents (absent: a row stating `num` is Gen 3's).
--
-- A mid-fight level-up rides here too (contract K9 of
-- docs/plans/gen12-referee-gaps-fix.md) -- no new message type: the client
-- that owns the save copy is the only party that ran the Exp award, so it is
-- the only one that knows the monster grew.  Generation 1 or 2 only (Gen 3's
-- referee rebuilds nothing from it, and its reader reads none of it), each
-- optional, present-and-unreadable refusing the message like a mangled move:
--
--   level   the new level, 1..LEVEL_MAX
--   stats   the new stats, the sheet's `stats` block in the hub's dialect
--   maxHp   the new max HP, 1..HP_MAX -- the sheet keeps it beside `stats`
--           rather than in it, and the cart raises current HP by the same
--           step it raises the maximum (pokered / pokecrystal
--           GainExperience), so the referee needs it as much as the stats
--
-- A payload whose moves are the hub's own with any of these is a level-up
-- that taught nothing, and is as valid as a learn.  This reader checks shape
-- and bounds alone and judges no claim.  The hub decides whether the message
-- is heard at all (only in a fight against the computer -- no cart levels or
-- learns in a link battle, Hub LEARN_MODES) and what a move list may change
-- (Hub learnTo); the referee's levelUp decides what a level claim rebuilds
-- and which claims it refuses (Hub M:applyBattleMoveset has the layers).
function M.battleMoveset(raw, generation)
  if type(raw) ~= "table" then return nil end
  local battle = M.id(raw.battle)
  local mon = M.int(raw.mon, 0, Config.BATTLE_MON_MAX - 1)
  if not battle or mon == nil then return nil end
  if type(raw.moves) ~= "table" then return nil end
  local moves = {}
  for _, entry in ipairs(raw.moves) do
    if #moves >= Config.BATTLE_MOVE_MAX then return nil end
    local move = M.battleMove(entry, generation)
    if not move then return nil end
    moves[#moves + 1] = move
  end
  if #moves == 0 then return nil end
  local out = { battle = battle, mon = mon, moves = moves }
  local gen = M.int(generation, 1, M.GENERATION_MAX)
  if gen == 1 or gen == 2 then
    if raw.level ~= nil then
      out.level = M.int(raw.level, 1, M.LEVEL_MAX)
      if out.level == nil then return nil end
    end
    if raw.stats ~= nil then
      -- The dialect's keys whole, as statsOf reads a sheet's -- through
      -- block3 so both twins read the numbers alike (luaInt there).
      out.stats = block3(raw.stats, gen == 2 and STAT_KEYS_GEN2 or STAT_KEYS_GEN1, 1, M.STAT_MAX)
      if not out.stats then return nil end
    end
    if raw.maxHp ~= nil then
      out.maxHp = M.int(raw.maxHp, 1, M.HP_MAX)
      if out.maxHp == nil then return nil end
    end
  end
  return out
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
