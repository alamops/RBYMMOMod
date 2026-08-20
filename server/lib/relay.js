'use strict';

/*
 * The hub, as pure logic.
 *
 * This is what server/hub.js used to be, minus the socket. It owns who is
 * connected, where they last said they were, and which two players are
 * currently paired for a trade or a battle.
 *
 * It simulates exactly one thing, and only since PROTOCOL 10: a **mediated
 * battle**. A trade is still the engine's own state machine running inside
 * the two clients with mmo.relay payloads passing through unread, but a fight
 * this hub brokered is resolved here -- see the "mediated battles" section
 * below -- because a battle decided by one of the two players is a battle
 * decided by whichever of them modified their copy first. Every roll, the
 * turn order and the sole win/loss verdict live in lib/battle/Turn.js (Gen1)
 * or lib/battle2/Turn.js (Gen2), selected at construction from
 * `opts.generation`; this file owns the plumbing around it: who is in which
 * fight, whose party is still missing, and where the events go.
 *
 * **No sockets appear anywhere below.** Everything talks to *peer handles*
 * -- any object answering send(msg), close() and carrying a remoteAddress
 * string. lib/server.js supplies socket-backed ones; a suite supplies
 * fakes. That is the same split src/Hub.lua uses on the Lua side, and it
 * is what lets the cap, the scope routing and the session pairing be
 * tested without binding a port.
 *
 * Authentication is a *port*, not an implementation: `auth` is either null
 * (anyone may join, which is what a LAN game wants) or an object with
 * newNonce() and verify(nonce, response). The relay knows the shape of the
 * handshake and nothing about the cryptography behind it.
 *
 * Everything arriving here is untrusted -- it comes from another player's
 * process, and a modified one is a normal thing to meet -- so every field
 * is re-derived through lib/sanitize before it is believed.
 */

const {
  cleanText, cleanId, cleanSpriteId, cleanMapId, cleanInt, cleanHex,
  cleanProfile, cleanOutcome, cleanPoints, cleanPlayerId, payloadOk, FACINGS,
  KINDS, SCOPES, NAME_MAX, MESSAGE_MAX, MOTD_MAX, LOCAL_RADIUS,
  cleanBattleKey, cleanCoopReason, cleanCoopOfferMode, cleanLabel, cleanPartyEvent, PARTY_MAX,
  cleanBattleRuleset, cleanBattleParty, cleanBattleChoice, cleanBattleReconnect,
  BATTLE_MOVE_MAX,
} = require('./sanitize');
const {
  Board, keyOf, RANK_START, RANK_TOP, RANK_REPORT_GRACE_MS,
  RANK_QUERY_GATE_MS,
} = require('./rank');
const { createLog, safe } = require('./log');

const DEFAULT_PLAYERS = 4;
const DEFAULT_SPRITE = 'SPRITE_RED';
const DEFAULT_SPRITE_GEN2 = 'SPRITE_CHRIS';

function defaultSpriteFor(generation) {
  return Number(generation) === 2 ? DEFAULT_SPRITE_GEN2 : DEFAULT_SPRITE;
}
// The wire dialect this hub speaks, and the one number both suites greet
// with. 3 is where parties landed: nothing was removed, but an invite or a
// party chat line sent to a protocol-2 hub would meet a handler table that
// answers an unknown type with silence, and a player pressing INVITE and
// watching nothing happen is a worse sentence than a refusal that names both
// versions. 4 is ranked PVP, and moved for the same reason rather than a
// different one -- a protocol-3 hub has never heard of a battle result or a
// leaderboard request, so a newer client would report every match into
// silence. 5 was claimed twice, by two branches that had never met -- once
// for pace (the `fast` flag on mmo.move, which a protocol-4 hub's fixed
// field list drops without a word) and once for co-op battles (a protocol-4
// hub has never heard of mmo.coop_wait, so a player would press WAIT FOR
// <friend> while their partner is never told). Each 5 was a different
// vocabulary, so a client and hub that both said "5" could still be talking
// past each other. 6 is the first number that means both. And then 6 was
// claimed twice the same way, before it ever shipped: once by that union and
// once for the character a player is wearing -- settled at hello and never
// again until mmo.sprite, a type a hub that predates it answers with
// silence, so the player who picked somebody new would be the only one in
// the game who ever saw it. 7 is the first number that means all of it. 8 is
// mmo.party_event -- what the person a player is travelling with just did,
// fanned out from here to the party and to nobody else -- and a protocol-7 hub
// has never heard the type, so a player would watch their partner fight all
// evening and never be told a thing, which neither end can tell apart from an
// ordinary quiet route. 9 is mmo.request_cancel -- the asker withdrawing a
// trade/battle request before it is answered -- and a protocol-8 hub would
// clear the asker's local wait while still holding pendingTo, so the other
// player could accept into a session the asker thought they had left. 10 is the
// mediated battle -- mmo.battle_ruleset, _party, _ready, _choice, _event,
// _outcome and _reconnect, the seven types a fight uses once an intermediator
// owns the simulation rather than one of the two clients -- and it is the
// clearest bump of the list: a protocol-9 hub has never heard any of them, so a
// client would upload its party and its choices into silence and sit at a
// battle screen that never opens, while the hub it is talking to is still
// waiting for the two-client mmo.result vote that this path replaces. 11 is the
// mediated battle event `chose` -- a seat filed this turn's answer, so peers
// can keep the wait line accurate without an `act` fan-out -- and `unchose`,
// which clears that mark when a player cancels a choice they already submitted.
// A protocol-10 intermediator never emits either kind, so a newer client's
// wait line would name players who have already answered, or keep naming players
// who walked their answer back, and neither failure looks like lag -- both read
// as "still choosing". 12 adds `moves` for mid-fight move-list sync after
// Transform or Mimic. 13–15 extend ruleset / fight surface / bag proofs; 16 is
// persistent playerId seating (claim tickets gone). 17 is friends --
// mmo.friend_ask, mmo.friend_answer and mmo.friend_remove -- which landed as
// PROTOCOL 10 on the parallel main line while this branch claimed 10–16 for
// mediation; a protocol-16 intermediator answers all three with silence, and
// this is the one feature whose answer may legitimately arrive later (the hub
// holds an ask for a player who is offline), so "nothing has happened yet" is
// an ordinary state and a player would have no way at all to tell it from a
// hub that cannot do this. 18 is Party vs Wild: mode token `coop_wild` (two
// humans vs one wild NPC seat) and an optional `catcher` player id on
// mmo.battle_outcome so a successful ball names who keeps the mon. A
// protocol-17 hub's closed BATTLE_MODES set drops `coop_wild` opens, and its
// outcome cleaner strips an unknown `catcher` -- either way the partner never
// joins the grass fight, or both clients grant (or neither) because ownership
// was never named. 20 carries two features that both claimed 19 on parallel
// branches: (a) the generation lock on mmo.hello (`generation` 1|2; hub
// refuses a mismatch); (b) co-op invite-joiner rematch cleanup — optional
// overworld `npcId` and event-flag id on mmo.coop_wait / mmo.coop_offer /
// mmo.coop_battle (from the waiter's checkpointOrigin). A protocol-19 (or
// 18) hub that lacks either silently drops fields or skips the gen check.
// The rule every bump follows is unchanged: bump whenever a client can send
// something a hub silently ignores. Kept in step with Config.PROTOCOL on
// the mod side.
// 21: referee-emitted `exp` battle events (facts only) after faints in
// wild / coop_wild / coop_npc -- a 20-vocabulary client would drop them
// and silently never level from a fight its partner levelled from.
// 22: `speciesId` -- an optional registry id on mmo.battle_party's battler
// sheets, relayed back on the `send` / `switch` / `exp` events. Everything
// else on the wire names a monster by the token the fight is *narrated*
// under, which is the nickname when it has one, so the seat opposite had
// nothing to look a front pic, a level or an exp base rate up by: a peer's
// nicknamed monster drew as an empty box at Lv 1 and fell for no exp. A
// protocol-21 hub strips the field from the upload and states none on the
// events, which is exactly that failure -- and it is one no player can
// diagnose from inside the fight, since every other part of it works.
const PROTOCOL = 22;

// How long a four-way PARTY BATTLE ask waits for its three answers. Mirrors
// Config.COOP_ASK_TIMEOUT: every one of the four is looking at a box right
// now, and an ask that outlives the moment is one somebody answers yes to long
// after they stopped meaning it.
const COOP_ASK_TIMEOUT_MS = 60 * 1000;
// Mirrors Config.COOP_OFFER_TIMEOUT: how long a player may stand at a fight
// waiting for their partner before the hub stops brokering it. The partner's
// client already forgets a received offer on this clock, so without it the two
// ends disagreed about whether the fight was still joinable.
const COOP_OFFER_TIMEOUT_MS = 300 * 1000;
// How long a co-op battle's relay group may live unattended. The belt to
// mmo.coop_leave's braces: a client that crashes never says goodbye and never
// disconnects cleanly, and its group would otherwise sit here for the life of
// the process. Mirrors Config.COOP_BATTLE_MAX.
const COOP_BATTLE_MAX_MS = 3600 * 1000;
// A SHA-256 response is 64 hex characters; the slack is for a future digest,
// not for an unbounded field.
const RESPONSE_MAX = 128;

/*
 * The two clocks a mediated fight runs on, in **seconds** -- which is the unit
 * lib/battle/Turn.js counts in, and the reason every call into it goes through
 * battleSeconds() below rather than handing it a millisecond timestamp that
 * would make a sixty-second grace expire in sixty milliseconds.
 *
 * Mirrors Config.BATTLE_CHOICE_TIMEOUT, Config.BATTLE_RECONNECT_GRACE and
 * Config.BATTLE_RESOLVE_TIMEOUT.
 * Named here rather than imported from Turn's own defaults because they are a
 * *hub policy* -- the numbers a host could one day want to tune -- while
 * Turn's are the floor it falls back to when a caller says nothing.
 */
const BATTLE_CHOICE_TIMEOUT = 60;
const BATTLE_RECONNECT_GRACE = 60;
const BATTLE_RESOLVE_TIMEOUT = 30;

// How many fighters one side of a co-op field holds, which is Config.COOP_SIDE
// and is written as PARTY_MAX for that file's reason: two parties meet, so the
// day a party grows the side grows with it rather than a literal 2 having to be
// remembered here. It is also how many synthetic seats a coop_npc trainer takes.
const COOP_SIDE = PARTY_MAX;

// The seed range an authority client may propose, mirrored from sanitize's
// SEED_MAX so that a seed this hub deals itself is one a client's own
// sanitiser would have accepted from it.
const BATTLE_SEED_MAX = 1073741824;

// Milliseconds are what this hub's clock speaks and seconds are what the turn
// machine does. One conversion, in one place.
const battleSeconds = (ms) => Math.floor(ms / 1000);
// Smallest gap between two character changes from one player. The chat
// gate's window (500ms), for a sharper reason than scrollback: an avatar
// bakes its sheet when it spawns, so every other client in the game despawns
// and respawns this player to redraw them, and an ungated change is one
// client making everyone else's world flicker for free. A constant rather
// than a host setting like chatIntervalMs, because src/Hub.lua has to refuse
// at exactly the same moment for the same bytes -- one number moving would
// leave the two hosting paths gating differently.
const SPRITE_GATE_MS = 500;

// ------- friends
//
// Mirrors Config.FRIEND_HOLD and its two caps, and has to: the same client
// dials this hub and a game hosted from inside somebody's copy, so an ask that
// survives a week on one and an hour on the other is one feature behaving two
// ways. A week is longer than any "they'll be on later" and shorter than a
// season; the caps are ceilings on what a stranger can make a hub remember,
// not on how many friends anybody may have.
const FRIEND_HOLD_MS = 7 * 24 * 3600 * 1000;
const FRIEND_HOLD_PER_NAME = 8;
const FRIEND_HOLD_MAX = 1024;

// Trainer-name fold for friends (mirrors Wire.nameKey). Rank.keyOf is playerId
// only under PROTOCOL 16+; friendships are still keyed by the name you play as.
function nameKey(name) {
  const cleaned = cleanText(name, NAME_MAX);
  return cleaned ? cleaned.toUpperCase() : null;
}

// The name the hub itself speaks under. A message of the day and an
// operator's broadcast both arrive as ordinary chat with this name on them
// and no sender id, so the name is the only thing telling a player that the
// hub said it -- which is why no player may wear it (see the hello handler).
// Held as a board key, because that is the "same name" the rest of the hub
// already means: case folded, trimmed.
const HUB_NAME = 'HUB';
// What a kicked player is told when the operator did not say. Honest about
// who did it and short enough to fit the error box the client draws.
const KICK_REASON = 'An operator removed you from this hub.';

// A value that came off the wire and is about to be quoted back to its
// sender. Bounded because the sentence is the point, not a faithful echo of
// however many megabytes arrived.
function shortValue(value) {
  try {
    return String(value).slice(0, 16);
  } catch (err) {
    return '?';
  }
}

// Framing, kept here so the socket layer and any in-process peer split
// lines the same way. A malformed line is dropped, never fatal.
function parseLine(line) {
  if (typeof line !== 'string' || !line) return null;
  let msg;
  try {
    msg = JSON.parse(line);
  } catch (err) {
    return null;
  }
  if (!msg || typeof msg !== 'object') return null;
  if (typeof msg.type !== 'string') return null;
  return msg;
}

function presenceOf(client) {
  return {
    id: client.id,
    name: client.name,
    sprite: client.sprite,
    map: client.map,
    x: client.x,
    y: client.y,
    facing: client.facing,
    busy: Boolean(client.sessionId),
    // Whether they are in *a* party, never which one. It is the only thing
    // anyone outside that party needs -- it decides whether their menus
    // offer to invite this player -- and a party id on every presence would
    // let any client in the game map out who is travelling with whom.
    party: Boolean(client.partyId),
    // One question only: was that step a fast one. Not "why" -- a sprint on
    // foot and a bike both cover a tile in 8 frames, so both set this and
    // neither is told apart, which is all a watcher can draw anyway. Unlike
    // busy, this cannot be derived here: the hub never sees the B button or
    // the bike, so the client is the only authority on it and this is the
    // value it last reported.
    fast: Boolean(client.fast),
    // The trainer card the player shows others. Carried here because
    // src/Hub.lua does (Hub.lua:74): a player on a dedicated hub would
    // otherwise silently have no card, and the two hosting paths have to
    // stay interchangeable. Null is a peer on an older build with no card
    // to show, which the profile screen says plainly.
    profile: client.profile,
    // Ranked points ride with presence rather than with the trainer card,
    // because they are not a snapshot of who somebody was when they joined:
    // they move mid-session, and a card built from a stale hello would show
    // a rating the player has already changed.
    points: client.points || RANK_START,
    // No `admin` here, deliberately: presence is what every other player in
    // the game is told, and other players do not learn who holds power. The
    // flag goes to the operator's own client on welcome and to operator views
    // through roster(), and stops there.
  };
}

// ------------------------------------------------------------------ handlers
//
// Each takes (relay, client, msg). A handler that decides the message is
// not for it returns silently: an unknown or ill-formed message costs its
// sender nothing but the message, because the alternative is a hub that
// can be knocked over by anyone who mistypes.

const handlers = Object.create(null);

handlers['mmo.hello'] = (relay, client, msg) => {
  if (client.ready) return;
  if (cleanInt(msg.proto, 0, 9999) !== relay.protocol) {
    // Same sentence as src/Hub.lua: a client must not tell which hosting path
    // refused it. Twin-checked by tests/fixtures/hub_protocol_parity.json.
    return relay.refuse(client, `This game speaks protocol ${relay.protocol}; yours `
      + `speaks ${shortValue(msg.proto)}.`);
  }
  // PROTOCOL 20: missing generation defaults to 1. Same sentence as Hub.lua.
  const generation = cleanInt(msg.generation, 1, 2) ?? 1;
  if (generation !== relay.generation) {
    return relay.refuse(client, `This hub is for generation ${relay.generation}; yours `
      + `is generation ${generation}.`);
  }
  const name = cleanText(msg.name, NAME_MAX);
  if (!name) return relay.refuse(client, "That trainer name can't be used here.");
  const playerId = cleanPlayerId(msg.playerId);
  if (!playerId) {
    return relay.refuse(client, "That player id can't be used here.");
  }

  // ...and one name is spoken for. The hub's own lines carry no sender id, so
  // a player wearing this name could put words in the hub's mouth and nothing
  // on the receiving side could tell the two apart.
  if (name.toUpperCase() === HUB_NAME) {
    return relay.refuse(client, 'That name belongs to the hub itself; ' +
      'pick another trainer name and connect again.');
  }

  // The seat is claimed here, by someone who has identified themselves.
  // Charging it on connect meant a peer that connected and said nothing
  // held a seat until it timed out, so four silent sockets could lock
  // everyone out of a four-player hub.
  if (relay.isFull()) {
    return relay.refuse(client, `This hub is full (${relay.maxPlayers} players).`);
  }

  // Held rather than applied: an unauthenticated peer must not appear in
  // anyone's roster, and it is not admitted until the challenge is answered.
  client.hello = {
    name,
    playerId,
    generation,
    sprite: cleanSpriteId(msg.sprite) || defaultSpriteFor(generation),
    profile: cleanProfile(msg.profile),
    map: cleanMapId(msg.map),
    x: cleanInt(msg.x, 0, 4096),
    y: cleanInt(msg.y, 0, 4096),
    facing: FACINGS.has(msg.facing) ? msg.facing : 'down',
  };

  if (!relay.auth) return relay.admit(client);

  // Challenging after hello rather than on connect keeps the client's
  // send-hello-immediately flow intact, and means no nonce is spent on a
  // peer whose protocol does not match anyway.
  let nonce;
  try {
    nonce = relay.auth.newNonce();
  } catch (err) {
    relay.log.error(`could not issue a nonce: ${safe(err.message)}`);
    return relay.refuse(client, 'This hub cannot accept players right now.');
  }
  client.nonce = nonce;
  relay.send(client, 'mmo.challenge', { nonce });
};

handlers['mmo.auth'] = (relay, client, msg) => {
  // Only valid while a challenge is outstanding, and the nonce is spent the
  // moment it is consumed -- pass or fail -- so a captured response cannot
  // be replayed against the connection that produced it.
  if (client.ready || !client.nonce) return;
  const nonce = client.nonce;
  client.nonce = null;

  const response = cleanHex(msg.response, RESPONSE_MAX);
  let verdict = null;
  if (response && relay.auth) {
    try {
      verdict = relay.auth.verify(nonce, response);
    } catch (err) {
      relay.log.error(`credential check failed: ${safe(err.message)}`);
    }
  }
  if (!verdict || !verdict.ok) {
    const reason = (verdict && verdict.reason) || 'no matching credential';
    relay.log.warn(`refused ${client.id} from ${safe(client.address)}: ` +
      `${safe(reason)}`);
    return relay.refuse(client, 'That join code was not accepted.');
  }
  client.credentialId = verdict.credentialId || null;
  // Set from the verdict and only from the verdict: the credential decides who
  // is an operator, so nothing in the message that got us here -- or in any
  // message this peer sends later -- can turn the flag on.
  client.admin = verdict.admin === true;
  relay.admit(client);
};

handlers['mmo.move'] = (relay, client, msg) => {
  if (!client.ready) return;
  // Where they were before this step, so the roster hook can be told about a
  // change of *place* and stay silent about a change of tile.
  const wasOn = client.map;
  const map = cleanMapId(msg.map);
  const x = cleanInt(msg.x, 0, 4096);
  const y = cleanInt(msg.y, 0, 4096);
  if (map !== null && x !== null && y !== null) {
    client.map = map;
    client.x = x;
    client.y = y;
  } else {
    // no cell means "not in the world right now" (a battle, a menu): the
    // player stays on the roster but stops being placeable
    client.map = null;
    client.x = null;
    client.y = null;
  }
  if (FACINGS.has(msg.facing)) client.facing = msg.facing;
  // Client-truth, and strict on purpose: only a literal boolean true counts
  // as a fast step -- a sprint or a bike, the sender's business which -- and
  // everything else -- absent, 0, "", "yes", null -- is walking pace. The
  // rule is strictness rather than coercion because this hub and the in-game
  // Lua hub (src/Hub.lua) have to broadcast the same thing for the same wire
  // bytes, and Lua and JS truthiness disagree on exactly the values a
  // malformed client sends: 0 and "" are false to Boolean() and true to
  // Lua's `and`. Comparing against true is the one test both languages
  // answer identically for every JSON value.
  client.fast = msg.fast === true;
  relay.broadcast('mmo.move', presenceOf(client), client.id);
  // Crossing into another map -- or out of the world entirely, into a battle
  // or a menu, which is what a null cell means -- is the only part of a step
  // an operator's list of places can see.
  if (client.map !== wasOn) relay.noteRosterChange();
};

/*
 * The character a player is wearing, changed mid-session.
 *
 * The one field of a presence that used to be settled at hello and never
 * again. It is stored here and said once; from then on presenceOf carries the
 * new value in every mmo.move, mmo.join and mmo.welcome by itself, so a
 * client that missed this message -- or joined after it -- is healed by the
 * player's next step rather than by anything extra sent from here.
 */
handlers['mmo.sprite'] = (relay, client, msg) => {
  if (!client.ready) return;
  // The identifier sanitiser, exactly as hello uses it (cleanSpriteId, never
  // cleanText -- prose rules eat the underscore). An id this hub cannot make
  // sense of costs its sender the message and nothing more.
  const sprite = cleanSpriteId(msg.sprite);
  if (!sprite || sprite === client.sprite) return;

  // Checked after the no-op above, so a client re-sending the character it is
  // already wearing does not arm the gate against the next real change.
  const now = relay.now();
  if (now - client.lastSprite < SPRITE_GATE_MS) return;
  client.lastSprite = now;

  client.sprite = sprite;
  // Broadcast with no exception, like publishPoints: the player it is about
  // hears it too. Their own presence is not in their own roster, so this is
  // the message that confirms the hub took the change.
  //
  // **Nothing fallible sits between the store above and this line, and the
  // announcement goes out before anything else that could throw.** The store
  // is what arms the no-op guard at the top of this handler, so a store that
  // was never announced is not a lost message -- it is a permanently lost
  // one: the client's reconcile loop (src/Client.lua's SPRITE_RETRY) re-sends
  // the same id for the rest of the session and every retry is eaten by
  // `sprite === client.sprite`, with nobody else ever told. Mirrored, line
  // for line, by src/Hub.lua's handler -- the two hosting paths must not
  // differ on which failures cost a player their announcement.
  relay.broadcast('mmo.sprite', { id: client.id, sprite });
  // The board learns the new face too, so an mmo.ranking answer given after
  // this draws the character the player is wearing now rather than the one
  // they greeted in. The same call admit() makes, under the same guard: a
  // player who does not own the name has no business writing to its row.
  // Last, because it is the one call here that reaches state this handler
  // does not own, and a leaderboard portrait is not worth anyone's
  // announcement.
  if (client.ranked) relay.board.seen(client.id, client.name, client.sprite);
};

handlers['mmo.chat'] = (relay, client, msg) => {
  if (!client.ready) return;
  const scope = SCOPES.has(msg.scope) ? msg.scope : null;
  const text = cleanText(msg.text, MESSAGE_MAX);
  if (!scope || !text) return;

  const now = relay.now();
  // A light flood gate. Not a moderation system -- just enough that one
  // client cannot fill every other client's scrollback faster than it can
  // be read.
  if (now - client.lastChat < relay.chatIntervalMs) return;
  client.lastChat = now;

  const payload = { from: client.id, name: client.name, scope, text };

  if (scope === 'private') {
    const target = relay.get(cleanId(msg.to));
    if (target && target.ready) relay.send(target, 'mmo.chat', payload);
    return;
  }

  // A party line reaches the party wherever they are: no radius, no map, no
  // target to type. A client that is not in one is dropped rather than
  // broadcast -- a scope that quietly widened to everybody would be the
  // worst possible failure for a message somebody meant privately.
  if (scope === 'party') {
    if (!client.partyId) return;
    for (const member of relay.partyMembers(client.partyId)) {
      if (member.id !== client.id) relay.send(member, 'mmo.chat', payload);
    }
    return;
  }

  if (scope === 'local') {
    if (!client.map) return;
    for (const other of relay.clients.values()) {
      if (other.id === client.id || !other.ready) continue;
      if (other.map !== client.map) continue;
      const distance = Math.max(
        Math.abs(other.x - client.x), Math.abs(other.y - client.y));
      if (distance <= LOCAL_RADIUS) relay.send(other, 'mmo.chat', payload);
    }
    return;
  }

  relay.broadcast('mmo.chat', payload, client.id);
};

handlers['mmo.request'] = (relay, client, msg) => {
  if (!client.ready || client.sessionId) return;
  const kind = KINDS.has(msg.kind) ? msg.kind : null;
  const target = relay.get(cleanId(msg.to));
  if (!kind || !target || !target.ready || target.id === client.id) return;

  if (target.sessionId) {
    return relay.send(client, 'mmo.decline', { name: target.name, kind });
  }
  client.pendingTo = target.id;
  relay.send(target, 'mmo.request', { from: client.id, name: client.name, kind });
};

handlers['mmo.respond'] = (relay, client, msg) => {
  if (!client.ready) return;
  const kind = KINDS.has(msg.kind) ? msg.kind : null;
  const asker = relay.get(cleanId(msg.to));
  if (!kind || !asker || !asker.ready) return;

  // only the player who was actually asked can answer, and only while the
  // ask is still outstanding
  if (asker.pendingTo !== client.id) return;
  asker.pendingTo = null;

  if (!msg.accept) {
    return relay.send(asker, 'mmo.decline', { name: client.name, kind });
  }
  if (client.sessionId || asker.sessionId) {
    return relay.send(asker, 'mmo.decline', { name: client.name, kind });
  }
  relay.startSession(asker, client, kind);
};

// The asker takes the request back before it is answered. Only they can:
// pendingTo lives on their connection, and a forged cancel from somebody
// else has nothing to clear. The player holding the yes/no box is told, so
// they are not left answering an ask nobody is waiting on any more.
handlers['mmo.request_cancel'] = (relay, client) => {
  if (!client.ready) return;
  const targetId = client.pendingTo;
  if (!targetId) return;
  client.pendingTo = null;
  const target = relay.clients.get(targetId);
  if (target && target.ready) {
    relay.send(target, 'mmo.request_cancel',
      { from: client.id, name: client.name });
  }
};

// The invite, and the two answers to it.
//
// Deliberately the same shape as mmo.request above -- one outstanding ask per
// client, only the player who was asked may answer it, and the ask is spent
// on the first answer -- because it is the same problem, and a second subtly
// different handshake beside the first would be two things to keep right.
//
// What is *not* shared is the state it guards: a party is independent of a
// session, so two friends may team up while one of them is mid-trade. Being
// busy stops you battling, not travelling together.
handlers['mmo.party_invite'] = (relay, client, msg) => {
  if (!client.ready || client.partyId) return;
  const target = relay.get(cleanId(msg.to));
  if (!target || !target.ready || target.id === client.id) return;
  // Answered here rather than forwarded: the asker learns at once that this
  // player is taken, instead of waiting on a prompt nobody will ever see.
  if (target.partyId) {
    return relay.send(client, 'mmo.party_decline',
      { name: target.name, reason: 'in_party' });
  }
  client.partyPendingTo = target.id;
  relay.send(target, 'mmo.party_invite',
    { from: client.id, name: client.name });
};

handlers['mmo.party_respond'] = (relay, client, msg) => {
  if (!client.ready) return;
  const asker = relay.get(cleanId(msg.to));
  if (!asker || !asker.ready) return;

  // only the player who was actually asked can answer, and only while the
  // ask is still outstanding
  if (asker.partyPendingTo !== client.id) return;
  asker.partyPendingTo = null;

  if (!msg.accept) {
    return relay.send(asker, 'mmo.party_decline',
      { name: client.name, reason: 'no' });
  }
  // Re-checked at the moment of forming, not only when the invite went out:
  // either of them could have joined somebody else's party while this one sat
  // on screen waiting for a human to read it.
  if (client.partyId || asker.partyId) {
    return relay.send(asker, 'mmo.party_decline',
      { name: client.name, reason: 'in_party' });
  }
  relay.startParty(asker, client);
};

handlers['mmo.party_leave'] = (relay, client) => {
  if (!client.ready) return;
  relay.endParty(client, 'peer_left');
};

/*
 * What just happened to somebody's travelling partner: they beat a wild
 * POKeMON or a trainer, were beaten by one, or caught something.
 *
 * Routed exactly the way the party chat scope is, and a player who is not in
 * a party is dropped rather than broadcast for the same reason: an audience
 * that quietly widened to the whole hub would turn a note meant for one
 * friend into everybody's business. The fighter is left out because they
 * watched the battle happen -- their own client narrates it without a round
 * trip, and a copy coming back off the wire would be a second, later line
 * about a fight they had already been shown.
 *
 * `name` is stamped from the connection and never read off the message. It is
 * the only identifying field in the event and the whole event is drawn as a
 * sentence about a named player, so a client that supplied its own would be
 * writing lines on its partner's screen under somebody else's nick.
 *
 * The hub reads `kind` -- unlike a relay payload -- because it is the thing
 * that decides which fields have to be there, and an event missing its
 * opponent is a sentence that stops mid-way on the receiving screen.
 */
handlers['mmo.party_event'] = (relay, client, msg) => {
  if (!client.ready || !client.partyId) return;
  const event = cleanPartyEvent(msg);
  if (!event) return;

  // The chat gate, on the chat interval, for the same reason chat has one:
  // this is prose appearing unasked-for in the corner of somebody else's
  // screen, and a modified client sending it in a loop is the whole attack.
  // The honest traffic is at most one per battle, so half a second costs a
  // legitimate partner nothing. src/Hub.lua gates it at the same moment.
  const now = relay.now();
  if (now - client.lastPartyEvent < relay.chatIntervalMs) return;
  client.lastPartyEvent = now;

  const payload = Object.assign({}, event,
    { from: client.id, name: client.name });
  for (const member of relay.partyMembers(client.partyId)) {
    if (member.id !== client.id) relay.send(member, 'mmo.party_event', payload);
  }
};

/*
 * ------- friends
 *
 * The hub owns exactly one part of this feature: carrying a friend ask to the
 * player it names, and *keeping* it when that player is not here. The lists
 * themselves live in the two clients (src/Friends.lua's header says why they
 * cannot live here), so nothing below records who is friends with whom -- it
 * records who still owes an answer to whom.
 *
 * Everything is keyed by trainer name rather than connection id, because a
 * friendship outlives the connection that made it and a held ask has, by
 * definition, no connection left to hang on. keyOf is the fold, the same one
 * the rank board uses, so "the same name" means one thing on this hub.
 *
 * Three handlers, and the asymmetry between them is the security model. The
 * ask is forwarded on the sender's say-so, because the worst it can do is put
 * a yes/no box in front of somebody who says no. The *answer* is not: a client
 * that could send one to anybody would be a client that adds itself to a
 * stranger's list without ever being agreed to, so it is only passed on when
 * this hub is holding the matching ask. The removal needs no check at all,
 * because the hub stamps the sender's own name on it -- the only thing a
 * forged one achieves is taking its sender off somebody's list, which is what
 * the message says it does.
 *
 * The Node half of src/Hub.lua's friend section, and it has to stay in step
 * with it for the reason the co-op section below gives.
 */

handlers['mmo.friend_ask'] = (relay, client, msg) => {
  if (!client.ready) return;
  const target = relay.clients.get(cleanId(msg.to));
  if (!target || !target.ready || target.id === client.id) return;

  const mine = nameKey(client.name);
  const theirs = nameKey(target.name);
  // Two connections wearing one name on a hub that never claimed it. There is
  // no friendship to form between a name and itself, and the hold table is
  // keyed by name -- so an ask filed here would be one this player could
  // answer on the asker's behalf.
  if (!mine || !theirs || mine === theirs) return;

  // Gated on the chat interval, for the reason mmo.party_event is: this puts
  // prose and a modal on somebody else's screen unasked, and a modified client
  // pressing it in a loop is the whole attack. Honest traffic is one ask per
  // friendship, so half a second costs nobody anything.
  const now = relay.now();
  if (now - client.lastFriendAsk < relay.chatIntervalMs) return;
  client.lastFriendAsk = now;

  relay.deliverFriend(theirs, 'ask', 'mmo.friend_ask',
    { from: client.id, name: client.name }, { kind: 'ask', name: client.name });
};

handlers['mmo.friend_answer'] = (relay, client, msg) => {
  if (!client.ready) return;
  const mine = nameKey(client.name);
  const asker = nameKey(msg.toName);
  if (!mine || !asker) return;

  // The gate: only somebody actually holding an ask from this name may answer
  // it, and the ask is spent on the first answer.
  if (!relay.takeFriendHold(mine, 'ask', asker)) return;

  const accept = msg.accept === true;
  relay.deliverFriend(asker, 'answer', 'mmo.friend_answer',
    { name: client.name, accept },
    { kind: 'answer', name: client.name, accept });
};

handlers['mmo.friend_remove'] = (relay, client, msg) => {
  if (!client.ready) return;
  const mine = nameKey(client.name);
  const theirs = nameKey(msg.toName);
  if (!mine || !theirs || mine === theirs) return;

  // Anything still outstanding between the two of them goes with it, in both
  // directions: an ask that outlived the friendship it was about is a box
  // somebody would be answering about a decision already made.
  relay.takeFriendHold(mine, 'ask', theirs);
  relay.takeFriendHold(theirs, 'ask', mine);

  relay.deliverFriend(theirs, 'remove', 'mmo.friend_remove',
    { name: client.name }, { kind: 'remove', name: client.name });
};

// ------- co-op battles
//
// The Node half of src/Hub.lua's co-op section, and it has to stay the Node
// half: the same client dials a dedicated hub and a game hosting from inside
// itself, so a rule only one of them enforces is a rule that holds on one of
// the two hosting paths and not the other.
//
// Two things live here and a third deliberately does not. The hub decides who
// may *hear* about an offer (only the one player its owner travels with -- a
// client choosing its own audience would be a client inviting strangers into
// its partner's fight) and whether all four *agreed*. It does not run the
// battle; it says who consented and stops, exactly as it does for a 1v1.

handlers['mmo.coop_wait'] = (relay, client, msg) => {
  if (!client.ready || !client.partyId) return;
  const battle = cleanBattleKey(msg.battle);
  if (!battle) return;
  const partner = relay.partnerOf(client);
  if (!partner) return;

  const label = cleanLabel(msg.label);
  const map = cleanMapId(msg.map);
  // Optional mode: only coop_wild is stored (Party vs Wild auto-join). Absent
  // keeps the trainer WAIT/JOIN invite path.
  const mode = cleanCoopOfferMode(msg.mode);
  // Optional overworld npcId / event (PROTOCOL 20): invite joiners need the
  // waiter's concrete trainer to mark beaten. Dropped when absent or wild.
  const npcId = !mode ? cleanId(msg.npcId) : null;
  const event = !mode ? cleanId(msg.event) : null;
  // startedAt so the sweep can expire it on the same clock the partner's
  // client already uses. Mirrors src/Hub.lua.
  client.coopOffer = { battle, label, map, mode, npcId, event, startedAt: relay.now() };
  const offer = { from: client.id, name: client.name, battle, label, map };
  if (mode) offer.mode = mode;
  if (npcId) offer.npcId = npcId;
  if (event) offer.event = event;
  relay.send(partner, 'mmo.coop_offer', offer);
};

handlers['mmo.coop_cancel'] = (relay, client, msg) => {
  if (!client.ready) return;
  const reason = cleanCoopReason(msg && msg.reason) || 'left';
  // Own standing offer withdrawn (STOP / ALONE / timeout).
  if (client.coopOffer) {
    relay.clearCoopOffer(client, reason);
    return;
  }
  // Partner declined our invite: clear the waiter's offer and tell them so
  // they can go in alone. Only `no` takes this path.
  if (reason === 'no') {
    const partner = relay.partnerOf(client);
    if (partner && partner.coopOffer) {
      partner.coopOffer = null;
      relay.send(partner, 'mmo.coop_decline', {
        name: client.name, reason: 'no',
      });
    }
  }
};

// "Yes, I'll join you." The one message that ends a wait.
//
// Every condition is re-derived here rather than taken on the client's word:
// that the two are in one party, that the offer still stands, and that it is
// the *same* fight. The last is what stops a modified client dragging its
// partner out of wherever they are into a battle they never walked up to.
handlers['mmo.coop_join'] = (relay, client, msg) => {
  if (!client.ready || !client.partyId) return;
  const host = relay.get(cleanId(msg.to));
  if (!host || !host.ready || host.id === client.id) return;
  if (host.partyId !== client.partyId) return;

  const battle = cleanBattleKey(msg.battle);
  const offer = host.coopOffer;
  if (!offer || !battle || offer.battle !== battle) {
    // Too late: the waiter already went in alone (or walked off). Tell the
    // joiner so a yes that raced a withdraw is not silence.
    relay.send(client, 'mmo.coop_offer_end', { reason: 'alone' });
    return;
  }

  // Taken off the table before either side is told, so a second join racing
  // this one finds nothing to accept rather than starting the fight twice.
  host.coopOffer = null;
  client.coopOffer = null;

  const members = relay.partyMembers(client.partyId)
    .map((m) => ({ id: m.id, name: m.name }));

  // Told differently on purpose: the player who was waiting learns *who*
  // joined -- it is the answer they have been standing there for -- and the
  // player who joined is handed the roster, because they never had one.
  // The pair get a fan-out group of their own, on the same footing as a
  // four-player one: from here on the battle traffic does not care which of the
  // two ways it was agreed.
  // The mode is taken from the offer when the waiter named one: coop_wild for
  // Party vs Wild (auto-join grass), otherwise coop_npc for the trainer path.
  // The four-way path below is the only one that makes a coop_pvp, because it
  // is the only one where both sides are players.
  // "c", for startSession's reason: sessions and co-op battles share the
  // `battles` map and are numbered by two counters that know nothing of each
  // other.
  const battleId = `c${relay.nextCoopAsk++}`;
  const mode = offer.mode === 'coop_wild' ? 'coop_wild' : 'coop_npc';
  relay.openCoopBattle(battleId, [host.id, client.id],
    { mode, hostId: host.id });

  // `plan` is the hub's mediated battle id (`c*`). Without it the waiting
  // host's CoopBattle has no battleId, uploadMediated is a no-op, and the
  // fight silently stays on host CoopSim while the joiner alone holds `c*`.
  // `id` remains the joiner (who joined), matching what clients already read.
  relay.send(host, 'mmo.coop_joined',
    { id: client.id, name: client.name, plan: battleId });
  // `host` names the client that simulates: the player who was already standing
  // at the fight, since they are the one guaranteed to have walked into the
  // encounter -- the joiner usually has too, but a join taken from the ACTIONS
  // menu never went near them. `mode` rides so the joiner's CoopBattle opens
  // as coop_wild without re-deriving from an offer that is already cleared.
  // `npcId` / `event` (PROTOCOL 20) ride so a menu joiner can finish the
  // trainer off without a local BattleState -- never fuzzy-matched by class.
  const battleMsg = {
    id: battleId, side: 'a', allies: members, battle, host: host.id, mode,
  };
  if (offer.npcId) battleMsg.npcId = offer.npcId;
  if (offer.event) battleMsg.event = offer.event;
  relay.send(client, 'mmo.coop_battle', battleMsg);
};

// Battle traffic, fanned out to everyone else in the same battle. The payload
// is forwarded unread exactly as mmo.relay's is -- the hub does not simulate a
// co-op battle any more than it does a 1v1 -- so its *shape* is the only thing
// that can be judged, and payloadOk is what judges it.
handlers['mmo.coop_relay'] = (relay, client, msg) => {
  if (!client.ready || !client.coopBattleId) return;

  /*
   * ...unless the hub is running this one, in which case the same cut
   * mmo.relay gets applies and for the same reason.
   *
   * **The cut engages when the sim does, not when the group opens**, and that
   * is the one place the co-op path deliberately differs from the 1v1. A group
   * exists from the moment two players agree; the fight only becomes mediated
   * when a ruleset and every party have arrived. Cutting at the group would
   * take the legacy CoopSim path away from a client that has not been rewritten
   * to upload one yet (that is Wave 3's I3c), and would take it away *silently*
   * -- a partner watching a battle screen that never advances. So the two paths
   * are allowed to coexist for exactly as long as it takes one fight to become
   * mediated, and no longer: the moment an intermediator owns the rolls, a
   * second set of them fanned out from a client is the desync it looks like.
   */
  const mediated = relay.battles.get(client.coopBattleId);
  if (mediated && mediated.sim) {
    return noteDrop(relay, client,
      'this co-op battle is mediated -- the battle_* types are the way in');
  }

  if (!payloadOk(msg.payload)) {
    return noteDrop(relay, client, 'the co-op payload is not a shape we forward');
  }
  const group = relay.coopBattles.get(client.coopBattleId);
  for (const memberId of (group && group.members) || []) {
    if (memberId === client.id) continue;
    const member = relay.clients.get(memberId);
    if (member && member.ready) {
      relay.send(member, 'mmo.coop_msg', { from: client.id, payload: msg.payload });
    }
  }
};

// A player says their co-op battle is finished. One goodbye closes the whole
// group rather than removing one member: a co-op battle ends for everybody at
// the same moment, so a group that outlived one of its players would be a
// group with nothing left to carry.
handlers['mmo.coop_leave'] = (relay, client) => {
  if (!client.ready || !client.coopBattleId) return;
  // ...except while the hub is refereeing it, where one player walking out is
  // a disconnection and not a verdict. The three left keep fighting, and the
  // leaver's grace decides whether they come back or forfeit -- ending the
  // whole thing on their say-so would hand any of the four a way to void a
  // battle they were losing.
  const record = relay.battles.get(client.coopBattleId);
  if (record && record.sim) {
    if (record.sim.disconnect(client.id)) relay.flushBattle(record);
    return;
  }
  relay.closeCoopBattle(client.coopBattleId);
};

handlers['mmo.coop_challenge'] = (relay, client, msg) => {
  if (!client.ready || !client.partyId || client.coopAskId) return;
  const target = relay.get(cleanId(msg.to));
  if (!target || !target.ready || target.id === client.id) return;
  // No party, or *our* party: a party cannot challenge itself. The client
  // refuses both with a sentence of its own; this is the hub declining to take
  // a modified one at its word.
  if (!target.partyId || target.partyId === client.partyId) return;
  if (target.coopAskId) return;

  const mine = relay.partyMembers(client.partyId);
  const theirs = relay.partyMembers(target.partyId);
  if (mine.length !== PARTY_MAX || theirs.length !== PARTY_MAX) return;

  const id = `c${relay.nextCoopAsk++}`;
  const sideA = mine.map((m) => m.id);
  const sideB = theirs.map((m) => m.id);
  const everyone = sideA.concat(sideB);

  relay.coopAsks.set(id, {
    asker: client.id,
    sideA,
    sideB,
    everyone,
    // The asker's own yes is implied by asking; the other three are counted.
    answers: new Set([client.id]),
    needed: everyone.length - 1,
    // relay.now(), not Date.now(): the suites drive this hub off an injected
    // clock, and an ask stamped from the wall clock could never be aged out
    // in a test that never advances one.
    startedAt: relay.now(),
  });
  // Swept here rather than on a timer, for the reason sweepMatches gives:
  // creating an ask is the only moment the table can grow, and there is no
  // interval to unref in this process.
  relay.sweepCoopAsks();
  for (const memberId of everyone) {
    const member = relay.clients.get(memberId);
    if (member) member.coopAskId = id;
  }
  for (const memberId of everyone) {
    if (memberId === client.id) continue;
    const member = relay.clients.get(memberId);
    const side = member.partyId === client.partyId ? 'a' : 'b';
    relay.send(member, 'mmo.coop_ask',
      { id, from: client.id, name: client.name, side });
  }
};

handlers['mmo.coop_answer'] = (relay, client, msg) => {
  if (!client.ready) return;
  const id = cleanId(msg.id);
  const ask = id && relay.coopAsks.get(id);
  if (!ask) return;
  // Only somebody actually in this ask can answer it, and the asker cannot
  // answer their own -- their yes was spent on asking.
  if (client.coopAskId !== id || client.id === ask.asker) return;

  if (!msg.accept) {
    relay.endCoopAsk(id, client.name, 'no');
    return;
  }
  // A Set, not a counter: a client that sends yes twice must not be able to
  // talk the hub into starting a battle its fourth player never agreed to.
  ask.answers.add(client.id);
  if (ask.answers.size > ask.needed) relay.startCoopBattle(id);
};

// A refused relay payload used to be four bare `return`s. Trade and battle
// ride that path and nothing else does, so a silent refusal there is a trade
// that half-happened: one side applied it, the other never heard. Logged once
// per connection -- enough to name a real fault, too little for a peer sending
// nothing but junk to flood the host's terminal.
function noteDrop(relay, client, reason) {
  client.relayDrops = (client.relayDrops || 0) + 1;
  if (client.relayDrops === 1) {
    relay.log.warn(`refused a relayed message from ${client.id}: ${reason}`);
  }
}

// ------- mediated battles
//
// The four things a client says during a fight this hub is running. What comes
// back -- mmo.battle_ready, mmo.battle_event, mmo.battle_outcome -- is sent
// from the Relay methods further down, because it is the sim's word rather
// than an answer to any one message.
//
// Every one of them finds its battle through `client.battleId` rather than
// through the id on the message. The id is still checked where the sanitiser
// carries one, but it is checked *against* the connection's own fight: a
// client naming somebody else's battle is naming a fight it is not in, and the
// alternative -- trusting the field -- would let a spectator file choices into
// a match they were never at.

// The fight this connection is in, when the hub is the one running it. Null
// for a player who is not fighting, and for a co-op group that is still on the
// legacy client-simulated path.
function mediatedOf(relay, client) {
  if (!client.ready || !client.battleId) return null;
  return relay.battles.get(client.battleId) || null;
}

/*
 * The ephemeral ruleset: the type chart this one match runs under.
 *
 * A `seed` still parses, because the field has ridden this message since the
 * lockstep days, but tryStartSim does not read it -- see the note there for why
 * the RNG is the intermediator's alone.
 *
 * The host's to upload and nobody else's -- the asker in a 1v1, the player who
 * was already standing at the trainer in a co-op fight. Not because a guest's
 * chart would be worse, but because two charts is a fight with no answer to
 * "which", and picking the second to arrive would let either side re-roll the
 * matchups by sending one late.
 */
handlers['mmo.battle_ruleset'] = (relay, client, msg) => {
  const record = mediatedOf(relay, client);
  if (!record || record.sim) return;
  if (client.id !== record.hostId) return;

  const ruleset = cleanBattleRuleset(msg);
  if (!ruleset) {
    return noteDrop(relay, client, 'the ruleset is not a shape we can fight under');
  }
  record.ruleset = ruleset;
  relay.tryStartSim(record);
};

// One combatant's team. Stored under the seat it belongs to -- normally the
// sender's own -- and the fight opens on the message that completes the set.
handlers['mmo.battle_party'] = (relay, client, msg) => {
  const record = mediatedOf(relay, client);
  if (!record || record.sim) return;

  const party = cleanBattleParty(msg, relay.generation);
  if (!party) {
    return noteDrop(relay, client, 'the party is not a shape we can fight with');
  }
  // The battle it names has to be the one this connection is in. A party for
  // another fight is not a party that was mis-addressed, it is a sheet its
  // sender believes is being used somewhere else.
  if (party.battle !== record.id) return;

  if (!relay.fillBattleParty(record, client, party)) return;
  relay.tryStartSim(record);
};

// One turn's intent. Who it is from is the connection it arrived on and never
// a field, so there is nothing here for a modified client to spend somebody
// else's turn with.
handlers['mmo.battle_choice'] = (relay, client, msg) => {
  const record = mediatedOf(relay, client);
  if (!record || !record.sim) return;

  const choice = cleanBattleChoice(msg);
  if (!choice || choice.battle !== record.id) return;
  // Item choices are proved against the bag uploaded with the party
  // (PROTOCOL 15). A missing stack costs the message and nothing else —
  // same silence as a refused choice — so the turn clock keeps running.
  // The stack is *held* until the turn resolves; cancel clears the hold.
  if (choice.action === 'item'
      && !relay.canSpendBag(record, client.id, choice.item)) {
    return;
  }
  if (!record.sim.submitChoice(client.id, choice)) return;
  if (choice.action === 'item') {
    relay.holdBag(record, client.id, choice.item);
  } else if (choice.action === 'cancel') {
    relay.clearBagHold(record, client.id);
  }
  relay.flushBattle(record);
};

/*
 * Back inside the grace.
 *
 * What this covers is a client that left the *field* -- backed out to the
 * overworld, dropped its session, lost the battle screen to a crash it
 * recovered from -- and still holds the connection it was fighting on. A peer
 * whose socket actually died cannot come back through here at all until they
 * greet again with the same playerId: identity on this hub is the persistent
 * id, so a returning process is rekeyed to it on admit and may reattach to a
 * fight still inside reconnect grace.
 */
handlers['mmo.battle_reconnect'] = (relay, client, msg) => {
  const record = mediatedOf(relay, client);
  if (!record || !record.sim) return;
  const rejoin = cleanBattleReconnect(msg);
  if (!rejoin || rejoin.battle !== record.id) return;
  record.sim.reconnect(client.id);
  relay.flushBattle(record);
};

handlers['mmo.relay'] = (relay, client, msg) => {
  if (!client.ready || !client.sessionId) {
    return noteDrop(relay, client, 'sender is not in a session');
  }
  /*
   * PROTOCOL 10's hard cut, and it is a cut rather than a preference.
   *
   * A mediated battle exists for every battle session this hub brokers, so
   * from here on the engine's lockstep vocabulary has nowhere to go: the two
   * clients would agree a seed between themselves and fight a second,
   * invisible battle beside the one the hub is resolving, and the first
   * disagreement would be a player watching their own screen contradict the
   * outcome they are about to be sent. Trade sessions are untouched -- there
   * is no trade sim here and there is not going to be one.
   */
  if (relay.battles.has(client.sessionId)) {
    return noteDrop(relay, client,
      'this battle is mediated -- the battle_* types are the way in');
  }
  const peer = relay.peerOf(client);
  if (!peer) return noteDrop(relay, client, 'the session has no other side');
  if (cleanId(msg.to) !== peer.id) {
    return noteDrop(relay, client, 'addressed to someone who is not the peer');
  }
  if (!payloadOk(msg.payload)) {
    return noteDrop(relay, client, 'payload is deeper or larger than the cap');
  }
  // The hub does not read the payload. It is the engine's own link
  // vocabulary, and interpreting it here would couple this process to a
  // protocol the game already owns.
  relay.send(peer, 'mmo.relay', { from: client.id, payload: msg.payload });
};

handlers['mmo.session_leave'] = (relay, client) => {
  relay.endSession(client, 'peer_left');
};

handlers['mmo.ping'] = (relay, client) => {
  relay.send(client, 'mmo.pong', {});
};

handlers['mmo.result'] = (relay, client, msg) => {
  if (!client.ready) return;
  const id = cleanId(msg.session);
  const outcome = cleanOutcome(msg.outcome);
  if (!id || !outcome) return;

  /*
   * A fight the hub itself resolved has no use for a vote.
   *
   * mmo.result exists because neither peer in a relayed battle could be
   * believed about its own win, so two agreeing claims stood in for a witness.
   * Here there *is* a witness -- it did every roll -- and settleMediated pays
   * out from its verdict alone. A client's report about a mediated fight is
   * ignored rather than weighed: honest ones are redundant and dishonest ones
   * are the whole thing this path removes.
   *
   * Gated on the sim rather than on the record, because a record exists for
   * every battle session from the moment it opens. Until a ruleset and both
   * parties arrive, the two clients are still on the legacy lockstep path and
   * their vote is still the only account of it there is.
   */
  const mediated = relay.battles.get(id);
  if (mediated && mediated.sim) return;

  // A co-op battle files under its own paperwork: four players report one
  // battle rather than two.
  if (relay.coopMatches.has(id)) {
    relay.reportCoop(id, client, outcome);
    return;
  }

  const match = relay.matches.get(id);
  // No paperwork means the battle was never here, was scored already, or
  // finished longer ago than the grace period. All three are the same
  // answer -- nothing happens -- and none of them is worth a log line, since
  // a late report is a normal thing for a slow connection to produce.
  if (!match) return;
  if (client.id !== match.a && client.id !== match.b) return;
  // First answer stands: a client that could revise its report could keep
  // trying until it matched whatever its opponent said.
  if (match.reports.has(client.id)) return;

  match.reports.set(client.id, outcome);
  relay.settleMatch(id);
};

handlers['mmo.ranks'] = (relay, client) => {
  if (!client.ready) return;
  // Gated like chat: answering means sorting every rating this hub holds,
  // and the screen that asks is one a player can sit on.
  const now = relay.now();
  if (now - client.lastRanks < RANK_QUERY_GATE_MS) return;
  client.lastRanks = now;
  relay.send(client, 'mmo.ranking', { entries: relay.leaderboard() });
};

// --------------------------------------------------------------------- relay

class Relay {
  constructor(options) {
    const opts = options || {};
    const cap = Math.floor(Number(opts.maxPlayers));
    // Clamping to the protocol's bounds is lib/config.js's job -- it is the
    // thing that reads a host's file. This only refuses to run on a value
    // that is not a number at all.
    this.maxPlayers = Number.isFinite(cap) ? cap : DEFAULT_PLAYERS;
    this.chatIntervalMs = Number.isFinite(Number(opts.chatIntervalMs))
      ? Number(opts.chatIntervalMs) : 500;
    this.protocol = Number.isFinite(Number(opts.protocol))
      ? Number(opts.protocol) : PROTOCOL;
    // PROTOCOL 20 generation lock. Default 1 when omitted so existing Gen1
    // deploys keep working; Gen2 hubs MUST set generation:2 (CLI / config —
    // twin of src/Hub.lua opts.generation).
    {
      const gen = cleanInt(opts.generation, 1, 2);
      this.generation = gen == null ? 1 : gen;
    }
    // Wave 2 T2d: mediated-battle twin at construction. Gen1 keeps lib/battle;
    // Gen2 never instantiates Gen1 Turn for refereeing.
    {
      const battle = this.generation === 2
        ? require('./battle2')
        : require('./battle');
      this.Turn = battle.Turn;
      this.Effects = battle.Effects;
    }
    this.auth = opts.auth || null;
    /*
     * The hub's message of the day, as the operator typed it. Held raw and
     * cleaned at admit-time on purpose: lib/server.js reassigns this field
     * when the config is re-read on SIGHUP, and a value folded into a
     * pre-built welcome payload here would go on greeting players with the
     * message the hub started with until somebody restarted it. Empty means
     * there is nothing to say, and the welcome then carries no field at all.
     */
    this.motd = typeof opts.motd === 'string' ? opts.motd : '';
    this.log = opts.log || createLog();
    this.now = typeof opts.now === 'function' ? opts.now : Date.now;

    /** id -> client */
    this.clients = new Map();
    /** sessionId -> { a, b, kind } */
    this.sessions = new Map();
    /** partyId -> [memberId, ...] */
    this.parties = new Map();
    /*
     * Ranked PVP. The board is what a rating *is* -- the hub owns it,
     * because a client that owned its own score would simply write itself a
     * better one -- and `matches` is the paperwork for one battle: who was
     * in it, and what each side has said about how it ended. A caller may
     * hand over a board it loaded from disk; lib/server.js does, and passes
     * onRankChange so the file follows the ratings.
     */
    this.board = opts.board || new Board();
    this.onRankChange = typeof opts.onRankChange === 'function'
      ? opts.onRankChange : null;
    /*
     * One settled battle, told once. Separate from onRankChange because it
     * answers a different question: onRankChange says "the board moved, write
     * it out" and fires for claims too, while this fires only for a battle
     * that actually scored and carries the whole result -- who fought, what
     * it cost, when it started. A hub that keeps no history simply passes
     * nothing and the record is never built.
     */
    this.onMatchSettled = typeof opts.onMatchSettled === 'function'
      ? opts.onMatchSettled : null;
    /*
     * The same arrangement one step out: whoever owns the files is told that
     * *who is here* changed, and decides for itself what that is worth.
     * lib/server.js passes this and writes the operator snapshot from
     * roster(); an embedded hub passes nothing and the roster stays in RAM.
     */
    this.onRosterChange = typeof opts.onRosterChange === 'function'
      ? opts.onRosterChange : null;
    /** sessionId -> { a, b, aName, bName, reports, endedAt } */
    this.matches = new Map();

    this.nextId = 1;
    this.nextSession = 1;
    this.nextParty = 1;
    // The four-way PARTY BATTLE asks in flight: id -> { asker, sideA, sideB,
    // everyone, answers, needed, startedAt }. Kept on the relay rather than on
    // the asker because three other clients are holding a box for each one,
    // and a state four connections can invalidate belongs to the thing that
    // outlives all four.
    this.coopAsks = new Map();
    // id -> [clientId]: who mmo.coop_relay fans out to. Separate from coopAsks
    // because it starts where an ask *ends*, and outlives it.
    this.coopBattles = new Map();
    // Paperwork for a party-vs-party co-op battle: four reports rather than
    // two, so it is kept apart from `matches` instead of folded in.
    this.coopMatches = new Map();
    /*
     * The fights this hub is *running*: id -> the record openMediatedBattle
     * builds. Keyed by the id the fight was already known under -- a session id
     * for a 1v1, a co-op group id for a 2v2 -- rather than by an id of its own,
     * because every message about a battle already carries one of those and a
     * second numbering would be a mapping to keep in step for no gain.
     *
     * A record exists from the moment the fight is agreed and holds nothing but
     * a roster until the ruleset and the parties arrive; `sim` is what says the
     * hub has taken it over, and it is the flag every hard cut in this file is
     * gated on.
     */
    this.battles = new Map();
    /*
     * Friend traffic this hub is holding for somebody who is not here:
     * nameKey -> [{ kind, name, accept, at }], oldest first.
     *
     * Keyed by *name* and not by connection, which is the whole reason it
     * exists: an ask whose target logs out before answering has to be asked
     * again when they come back, and there is no connection left to hang it
     * on. Mirrors src/Hub.lua's friendHolds.
     */
    this.friendHolds = new Map();
    this.friendHeld = 0;
    this.nextCoopAsk = 1;
    this.players = 0;
  }

  // ------- friends
  //
  // What the handlers above call. See their header for the security model and
  // for why the lists themselves are not here.

  /*
   * Whoever is connected under this name right now, or null.
   *
   * First match wins, and the client table's iteration order decides which --
   * which is fine, and is why nothing is *drawn* from it: two players wearing
   * one unclaimed name is a real state, and either is an equally correct
   * answer to "deliver this now rather than holding it". A wrong guess costs a
   * misdelivered box, never a friendship: the receiving client answers under
   * its own name, and the answer is matched back against the hold by name.
   */
  byName(key) {
    if (!key) return null;
    for (const client of this.clients.values()) {
      if (client.ready && nameKey(client.name) === key) return client;
    }
    return null;
  }

  /*
   * Drop everything held longer than FRIEND_HOLD_MS.
   *
   * Lazy, run when something is added rather than on a timer: the table is
   * empty on nearly every hub, and a sweep nobody needs is work done for an
   * answer that has not changed.
   */
  sweepFriendHolds() {
    const now = this.now();
    for (const [key, holds] of this.friendHolds) {
      const kept = holds.filter((hold) => now - hold.at <= FRIEND_HOLD_MS);
      this.friendHeld -= holds.length - kept.length;
      if (kept.length) this.friendHolds.set(key, kept);
      else this.friendHolds.delete(key);
    }
  }

  /*
   * Hold one notification for a name, replacing whatever it supersedes.
   *
   * One entry per (kind, sender), because all three kinds are idempotent:
   * asking twice is one ask, and a second answer to a question already
   * answered is not a thing that exists. Without that, one button held down
   * would stack a player's inbox with the same box -- the caps would bound it,
   * but they would still be answering one question eight times.
   *
   * Refused rather than trimmed at the global cap: dropping somebody else's
   * held ask to make room for this one would let a flood erase the one
   * notification that mattered. Per name it is the oldest that goes, which is
   * the other way round on purpose -- eight unanswered asks in one inbox is
   * one player ignoring eight people, and the newest is the one still worth
   * asking.
   */
  holdFriend(key, hold) {
    if (!key) return false;
    this.sweepFriendHolds();
    let holds = this.friendHolds.get(key);
    if (!holds) {
      if (this.friendHeld >= FRIEND_HOLD_MAX) return false;
      holds = [];
      this.friendHolds.set(key, holds);
    }

    const fromKey = nameKey(hold.name);
    const already = holds.findIndex(
      (held) => held.kind === hold.kind && nameKey(held.name) === fromKey);
    if (already >= 0) {
      holds.splice(already, 1);
      this.friendHeld -= 1;
    }
    if (holds.length >= FRIEND_HOLD_PER_NAME) {
      holds.shift();
      this.friendHeld -= 1;
    }
    if (this.friendHeld >= FRIEND_HOLD_MAX) {
      if (!holds.length) this.friendHolds.delete(key);
      return false;
    }

    holds.push(Object.assign({}, hold, { at: this.now() }));
    this.friendHeld += 1;
    return true;
  }

  /*
   * Take one held notification off a name's list, and say whether there was
   * one.
   *
   * This is the check that makes an answer safe to forward: only the player an
   * ask was actually addressed to is holding it, so a client answering a
   * question nobody asked it finds nothing here and is dropped.
   */
  takeFriendHold(key, kind, fromKey) {
    const holds = key ? this.friendHolds.get(key) : null;
    if (!holds) return null;
    const index = holds.findIndex(
      (held) => held.kind === kind && nameKey(held.name) === fromKey);
    if (index < 0) return null;
    const [held] = holds.splice(index, 1);
    this.friendHeld -= 1;
    if (!holds.length) this.friendHolds.delete(key);
    return held;
  }

  /** Send one notification now, or hold it until that name is next seen. */
  deliverFriend(key, kind, type, payload, hold) {
    const target = this.byName(key);
    if (target) {
      this.send(target, type, payload);
      // An ask stays held even when it was delivered: the player it reached
      // may close the game without answering, and "asked once, into a session
      // that ended" is exactly the case this table exists for. Everything else
      // is spent on delivery.
      if (kind !== 'ask') return true;
    }
    return this.holdFriend(key, hold);
  }

  /*
   * Everything this hub has been keeping for the player who just walked in.
   *
   * Called from admit(), after the welcome and the join broadcast: a box needs
   * a client that already knows who it is and which list it is answering from,
   * and an ask arriving ahead of the welcome would reach one with no friends
   * list open (src/Friends.lua's onAsk refuses it).
   *
   * Asks are re-delivered and *kept*; answers and removals are spent. That
   * asymmetry is the feature: an ask is outstanding until it is answered, so a
   * player who logs out mid-prompt is asked again next time, whereas an answer
   * is news that has now been delivered.
   */
  flushFriendHolds(client) {
    const key = nameKey(client.name);
    if (!key || !this.friendHolds.has(key)) return 0;
    this.sweepFriendHolds();
    const holds = this.friendHolds.get(key);
    if (!holds) return 0;

    const kept = [];
    for (const hold of holds) {
      if (hold.kind === 'ask') {
        // No `from` id: the asker may not be here, and inventing one would
        // give the receiving client an id to answer to that means somebody
        // else's connection. The name is what an answer travels by anyway.
        const asker = this.byName(nameKey(hold.name));
        this.send(client, 'mmo.friend_ask',
          { from: asker ? asker.id : undefined, name: hold.name });
        kept.push(hold);
      } else if (hold.kind === 'answer') {
        this.send(client, 'mmo.friend_answer',
          { name: hold.name, accept: hold.accept === true });
        this.friendHeld -= 1;
      } else {
        this.send(client, 'mmo.friend_remove', { name: hold.name });
        this.friendHeld -= 1;
      }
    }
    if (kept.length) this.friendHolds.set(key, kept);
    else this.friendHolds.delete(key);
    return holds.length;
  }

  // ------- roster

  // Full means no room for another *player*. A connection that has not said
  // hello is not a player and must not be able to hold a seat; how many of
  // those are tolerated at once is lib/limits.js's question, not this one.
  get playerCount() { return this.players; }

  get pendingCount() { return this.clients.size - this.players; }

  isFull() { return this.players >= this.maxPlayers; }

  has(id) { return this.get(id) != null; }

  get(id) {
    return this.clients.get(id)
      || (this.byEphemeral && this.byEphemeral.get(id))
      || null;
  }

  clientIds() { return Array.from(this.clients.keys()); }

  // Via get(), not clients.get(): after PROTOCOL 16 rekey the socket layer
  // still holds the ephemeral accept-id, and that id lives only in
  // byEphemeral. Looking in clients alone left every admitted player
  // looking ungreeted, so limits.sweep killed them with handshake_timeout
  // ten seconds later -- exactly the Node-hub LOVE mass-drop.
  greeted(id) {
    const client = this.get(id);
    return Boolean(client && client.ready);
  }

  /*
   * Who is on this hub, for somebody who is not in the game.
   *
   * The operator's view, not a player's: no client ids, no session or party
   * ids, no addresses, no token material. busy and party are the same
   * booleans presenceOf publishes and for the same reason -- the answer an
   * onlooker needs is "can this player be asked for a battle", never who
   * they are travelling with -- and a snapshot written to a file that
   * outlives the process is the last place an id worth guessing should
   * appear. Only ready clients: a socket that has not said hello is not a
   * player and is on nobody's roster, here least of all.
   */
  roster() {
    const out = [];
    for (const client of this.clients.values()) {
      if (!client.ready) continue;
      out.push({
        name: client.name,
        sprite: client.sprite,
        map: client.map,
        x: client.x,
        y: client.y,
        busy: Boolean(client.sessionId),
        party: Boolean(client.partyId),
        points: client.points,
        ranked: Boolean(client.ranked),
        // Operator surfaces may carry this -- status.json, `who`, the
        // `players --json` projection -- because they are already the view
        // for somebody outside the game. Whether any of them draws it is
        // their question; carrying it here is enough. Always a boolean, so a
        // row never has to be read as "absent means no".
        admin: Boolean(client.admin),
      });
    }
    return out;
  }

  /*
   * Somebody joined, left, sat down to a battle, teamed up, or was scored --
   * anything roster() would answer differently now. Told the same way a rank
   * change is (see noteRankChange): the hub is already correct in memory, so
   * a listener that throws is a full disk and not a lost player.
   *
   * Deliberately *not* fired for every step. A snapshot of where everyone is
   * standing is a list of places, and the writer behind this hook debounces
   * anyway -- but marking it dirty eight times a second while four people
   * walk around would turn an idle hub into a file the disk never stops
   * being asked about, for a value that did not change.
   */
  noteRosterChange() {
    if (!this.onRosterChange) return;
    try {
      this.onRosterChange();
    } catch (err) {
      this.log.warn(`could not record a roster change: ${safe(err.message)}`);
    }
  }

  /*
   * Is somebody else on this hub connected under this playerId right now?
   * Duplicate live connections with the same id are refused at admit.
   */
  idInUse(client, playerId) {
    const key = keyOf(playerId);
    if (!key) return false;
    for (const other of this.clients.values()) {
      if (other.id === client.id || !other.ready) continue;
      if (keyOf(other.id) === key) return true;
    }
    return false;
  }

  /*
   * Replace the ephemeral connection id with the persistent playerId. Every
   * reference the hub may already hold is rewritten so sessions and fights
   * stay coherent after admit.
   */
  rekeyClient(client, playerId) {
    const oldId = client.id;
    if (oldId === playerId) return;
    this.clients.delete(oldId);
    client.ephemeralId = oldId;
    client.id = playerId;
    this.clients.set(playerId, client);
    if (!this.byEphemeral) this.byEphemeral = new Map();
    this.byEphemeral.set(oldId, client);

    for (const other of this.clients.values()) {
      if (other === client) continue;
      if (other.pendingTo === oldId) other.pendingTo = playerId;
      if (other.partyPendingTo === oldId) other.partyPendingTo = playerId;
    }
    for (const session of this.sessions.values()) {
      if (session.a === oldId) session.a = playerId;
      if (session.b === oldId) session.b = playerId;
    }
    for (const match of this.matches.values()) {
      if (match.a === oldId) match.a = playerId;
      if (match.b === oldId) match.b = playerId;
    }
    for (const record of this.battles.values()) {
      record.memberIds = record.memberIds.map((id) => (id === oldId ? playerId : id));
      record.sides.a = record.sides.a.map((id) => (id === oldId ? playerId : id));
      record.sides.b = record.sides.b.map((id) => (id === oldId ? playerId : id));
      if (record.hostId === oldId) record.hostId = playerId;
    }
    for (const coop of this.coopMatches.values()) {
      coop.everyone = coop.everyone.map((id) => (id === oldId ? playerId : id));
      if (coop.reports.has(oldId)) {
        coop.reports.set(playerId, coop.reports.get(oldId));
        coop.reports.delete(oldId);
      }
      for (const side of ['a', 'b']) {
        coop[side] = coop[side].map((member) => {
          if (member.id === oldId) return Object.assign({}, member, { id: playerId });
          return member;
        });
      }
    }
  }

  /*
   * A player reconnected with the same playerId while a mediated fight is
   * still inside reconnect grace. Reattach them so choices and events flow
   * again without opening a second record.
   */
  reattachBattle(client) {
    for (const record of this.battles.values()) {
      if (!record.sim || record.settled) continue;
      if (!record.memberIds.includes(client.id)) continue;
      if (record.sim.reconnect(client.id)) {
        client.battleId = record.id;
        this.flushBattle(record);
        return true;
      }
    }
    return false;
  }

  // ------- connection lifecycle

  // A peer that got this far has a socket (or a loopback) but has not said
  // hello, so it is not a player and appears on nobody's roster.
  accept(peer) {
    const client = {
      id: String(this.nextId++),
      peer,
      address: (peer && peer.remoteAddress) || 'unknown',
      ready: false,
      name: null,
      sprite: defaultSpriteFor(this.generation),
      profile: null,
      map: null, x: null, y: null, facing: 'down',
      // nobody arrives mid-stride: the first mmo.move says otherwise or it
      // stays false
      fast: false,
      sessionId: null,
      pendingTo: null,
      partyId: null,
      partyPendingTo: null,
      // The mediated fight this connection is in, if any. Holds a session id
      // for a 1v1 and a co-op group id for a 2v2 -- see `battles`.
      battleId: null,
      // -Infinity, not 0: an injected clock that starts at zero would
      // otherwise gate the very first message a player ever sends.
      lastChat: -Infinity,
      // gated on the chat interval too: it is prose on a partner's screen
      lastPartyEvent: -Infinity,
      lastRanks: -Infinity,
      // last mid-session character change
      lastSprite: -Infinity,
      // gated on the chat interval too: a friend ask is a modal on somebody
      // else's screen, so it is rationed like the other things that are
      lastFriendAsk: -Infinity,
      points: RANK_START,
      // until hello says otherwise, nobody is scored: `ranked` is always true
      // once admitted under PROTOCOL 16
      ranked: false,
      hello: null,
      nonce: null,
      credentialId: null,
      // Nobody is an operator until a credential says so in mmo.auth. A hub
      // with auth off never sets this, which is the whole answer for an
      // unauthenticated hub: no credential, no admin.
      admin: false,
    };
    this.clients.set(client.id, client);
    this.log.debug(`accepted ${client.id} from ${safe(client.address)}`);
    return client.id;
  }

  // Mark ready, publish the presence captured at hello, and tell everyone.
  // Reached from hello directly when the hub is open, or from a passing
  // mmo.auth when it is not.
  //
  // **The seat is charged here, so the cap is checked here.** hello's own
  // isFull() check is a courtesy -- it turns someone away before a nonce is
  // spent on them -- but on a hub that challenges, an arbitrary number of
  // peers can pass that check while there is still room and only become
  // players later, when they answer. Every one of them arrives through this
  // method, so this is the one gate that cannot be walked around, and a
  // caller that has already checked simply never sees this branch.
  admit(client) {
    if (this.isFull()) {
      return this.refuse(client,
        `This hub is full (${this.maxPlayers} players).`);
    }

    const hello = client.hello || {};
    const playerId = hello.playerId;
    if (!playerId || !keyOf(playerId)) {
      return this.refuse(client, "That player id can't be used here.");
    }
    if (this.idInUse(client, playerId)) {
      return this.refuse(client, "You're already connected.");
    }

    client.name = hello.name;
    client.sprite = hello.sprite || defaultSpriteFor(this.generation);
    client.profile = hello.profile || null;
    client.map = hello.map === undefined ? null : hello.map;
    client.x = hello.x === undefined ? null : hello.x;
    client.y = hello.y === undefined ? null : hello.y;
    client.facing = hello.facing || 'down';
    client.hello = null;
    client.nonce = null;

    this.rekeyClient(client, playerId);
    client.ready = true;
    client.ranked = true;

    this.board.seen(client.id, client.name, client.sprite);
    client.points = this.board.points(client.id);
    this.reattachBattle(client);
    this.players += 1;

    const players = [];
    for (const other of this.clients.values()) {
      if (other.ready && other.id !== client.id) players.push(presenceOf(other));
    }
    const motd = cleanText(this.motd, MOTD_MAX);

    this.send(client, 'mmo.welcome', {
      id: client.id,
      players,
      points: client.points,
      ranked: client.ranked,
      motd: motd || undefined,
      admin: client.admin || undefined,
    });
    this.broadcast('mmo.join', { player: presenceOf(client) }, client.id);
    this.log.info(`+ ${safe(client.name)} (${client.id}) -- ` +
      `${this.players} online`);
    // Anything this hub has been holding for the name they walked in under: a
    // friend ask nobody was here to answer, an answer to one of theirs, a
    // friendship somebody ended while they were away. After the welcome,
    // because a box needs a client that knows who it is; after the broadcast,
    // so nothing sits between the arrival and the rest of the game hearing it.
    this.flushFriendHolds(client);
    this.noteRosterChange();
  }

  drop(id) {
    const client = this.get(id);
    if (!client) return false;
    this.endSession(client, 'peer_left');
    // Before endParty, deliberately: clearCoopOffer finds the partner *through*
    // the party, so withdrawing afterwards would withdraw into nothing and
    // leave the partner holding an offer from somebody who has left the game.
    this.clearCoopOffer(client, 'gone');
    this.clearCoopAsks(client, 'gone');
    /*
     * A fight the hub is running does not end because one of its players
     * vanished: it pauses, on the reconnect grace, and forfeits when that runs
     * out. leaveBattle answers true only in that case, and only then is the
     * group left standing -- everything else (a fight still collecting parties,
     * a co-op group on the legacy path) closes exactly as it always did, so the
     * three players left are never relaying into an id that includes somebody
     * who is not there.
     */
    const fighting = this.leaveBattle(client);
    if (client.coopBattleId && !fighting) this.closeCoopBattle(client.coopBattleId);
    // A party outlives a trade but not a connection: the other member is told
    // while this one is still in the table, so the presence that goes out
    // with it is the one where they are no longer in a party.
    this.endParty(client, 'peer_left');
    const playerId = client.id;
    this.clients.delete(playerId);
    if (client.ephemeralId && this.byEphemeral) {
      this.byEphemeral.delete(client.ephemeralId);
    }
    if (client.ready) this.players -= 1;
    // an outstanding request pointed at a player who just left would leave
    // the asker waiting forever for an answer nobody can give
    for (const other of this.clients.values()) {
      if (other.pendingTo === playerId) other.pendingTo = null;
      if (other.partyPendingTo === playerId) other.partyPendingTo = null;
    }
    if (client.ready) {
      this.broadcast('mmo.part', { id: playerId }, playerId);
      this.log.info(`- ${safe(client.name)} (${playerId}) -- ${this.players} online`);
      this.noteRosterChange();
    }
    return true;
  }

  // Tell everyone it is over, then forget them. There is no host migration,
  // so the honest thing is to say so rather than leave clients talking to a
  // dead listener.
  shutdown(message) {
    const text = message || 'The hub is shutting down.';
    for (const client of this.clients.values()) {
      this.send(client, 'mmo.error', { message: text });
      this.close(client);
    }
    this.clients.clear();
    this.sessions.clear();
    this.parties.clear();
    // A fight in progress does not survive the process that was refereeing it.
    this.battles.clear();
    this.players = 0;
    // The board survives a shutdown -- it is the hub's record, not the
    // connection's, and it is what lib/server.js writes to disk. The
    // half-reported matches do not: their sessions are gone.
    this.matches.clear();
  }

  // ------- parties
  //
  // Membership lives here and only here. A client is told the whole list
  // whenever it changes, which is what stops a client and the hub disagreeing
  // about who is in a party -- there is no delta to miss. Mirrors
  // src/Hub.lua's own party section message for message.

  partyMembers(partyId) {
    const out = [];
    for (const id of this.parties.get(partyId) || []) {
      const member = this.clients.get(id);
      if (member && member.ready) out.push(member);
    }
    return out;
  }

  startParty(a, b) {
    const id = String(this.nextParty++);
    this.parties.set(id, [a.id, b.id]);
    a.partyId = id;
    b.partyId = id;
    // Neither of them can be waiting on another answer now, and an invite
    // left armed would be answered by a player who is no longer free.
    a.partyPendingTo = null;
    b.partyPendingTo = null;

    const members = [
      { id: a.id, name: a.name },
      { id: b.id, name: b.name },
    ];
    this.send(a, 'mmo.party', { id, members });
    this.send(b, 'mmo.party', { id, members });

    // ...and everyone else learns these two are spoken for, so the INVITE row
    // stops being offered against them. Same shape as startSession: presence
    // changed, so presence goes out.
    this.broadcast('mmo.move', presenceOf(a), a.id);
    this.broadcast('mmo.move', presenceOf(b), b.id);
    this.noteRosterChange();
    this.log.info(`party ${id}: ${safe(a.name)} + ${safe(b.name)}`);
  }

  // One member leaving ends it for both. At PARTY_MAX = 2 there is no party
  // left to continue, and a "party" of one that still showed a members list
  // and a chat scope with nowhere to send would be worse than none.
  endParty(client, reason) {
    const id = client.partyId;
    if (!id) return;
    // Both offers go with the party, and while it still exists: an offer is
    // only ever shown to a party member, so one that outlived its party would
    // be a box nothing left alive could take down.
    this.clearCoopOffer(client, 'gone');
    for (const member of this.partyMembers(id)) {
      if (member.id !== client.id) this.clearCoopOffer(member, 'gone');
    }
    const memberIds = this.parties.get(id) || [];
    this.parties.delete(id);
    client.partyId = null;

    for (const memberId of memberIds) {
      const other = this.clients.get(memberId);
      if (other && other.id !== client.id && other.partyId === id) {
        other.partyId = null;
        this.send(other, 'mmo.party_end', { reason });
        this.broadcast('mmo.move', presenceOf(other), other.id);
      }
    }
    // The leaver is told too, so a client whose party ended because the hub
    // said so still converges. Guarded the way endSession guards its own: on
    // a drop there is nothing left to tell.
    if (this.clients.has(client.id)) {
      this.send(client, 'mmo.party_end', { reason: 'left' });
      this.broadcast('mmo.move', presenceOf(client), client.id);
    }
    this.noteRosterChange();
  }

  // ------- co-op battles

  // The other member of this client's party, or null. At PARTY_MAX = 2 there
  // is at most one, which is what lets an offer be forwarded without the
  // sender naming a recipient.
  partnerOf(client) {
    if (!client.partyId) return null;
    for (const member of this.partyMembers(client.partyId)) {
      if (member.id !== client.id) return member;
    }
    return null;
  }

  // Drop this client's standing offer and tell whoever was being shown it.
  //
  // Four callers -- withdrawing, being taken up on, the party dissolving, the
  // connection dropping -- because all four otherwise leave the partner
  // holding a box for a fight that is no longer on offer, and a box that can
  // only be answered into nothing is what this message exists to prevent.
  clearCoopOffer(client, reason) {
    if (!client || !client.coopOffer) return false;
    client.coopOffer = null;
    const partner = this.partnerOf(client);
    if (partner) {
      this.send(partner, 'mmo.coop_offer_end', { reason: reason || 'left' });
    }
    return true;
  }

  // Every ask this client is part of is void. A four-way short a player cannot
  // complete and must not be left to time out: the other three are looking at
  // a box right now, and coopAskId is what stops them being asked anything
  // else in the meantime.
  clearCoopAsks(client, reason) {
    const doomed = [];
    for (const [id, ask] of this.coopAsks) {
      if (ask.everyone.includes(client.id)) doomed.push(id);
    }
    for (const id of doomed) {
      this.endCoopAsk(id, client.name, reason || 'gone');
    }
  }

  // Asks nobody finished answering. Every one of them is holding three
  // players' coopAskId, which is what stops them being asked anything else --
  // so an ask that never resolved would lock all four out of the feature for
  // as long as the hub ran.
  sweepCoopAsks() {
    const now = this.now();
    const cold = [];
    for (const [id, ask] of this.coopAsks) {
      if (now - (ask.startedAt || 0) > COOP_ASK_TIMEOUT_MS) cold.push(id);
    }
    for (const id of cold) this.endCoopAsk(id, null, 'timeout');

    // Offers nobody came to, on the clock the partner's client already uses.
    const lapsed = [];
    for (const client of this.clients.values()) {
      const offer = client.coopOffer;
      if (offer && now - (offer.startedAt || 0) > COOP_OFFER_TIMEOUT_MS) {
        lapsed.push(client);
      }
    }
    for (const client of lapsed) this.clearCoopOffer(client, 'timeout');

    // Co-op battles nobody finished reporting, on the same grace the 1v1
    // paperwork gets and for the same reason.
    for (const [id, match] of this.coopMatches) {
      if (now - (match.startedAt || 0) > RANK_REPORT_GRACE_MS) {
        this.coopMatches.delete(id);
      }
    }
  }

  /*
   * Open a co-op battle's fan-out group. One id however the battle was agreed,
   * so mmo.coop_relay has one routing rule rather than two to keep in step.
   *
   * `plan` is what the mediated record is built from -- the mode, who the
   * authority is, and which side each member is on. It is passed by the caller
   * rather than worked out here because only the caller knows: the four-way
   * knows its two parties from the ask it just settled, and the pair knows
   * which of them walked up to the trainer. When it is absent the shape is
   * inferred, and openMediatedBattle says how.
   */
  openCoopBattle(id, memberIds, plan) {
    const members = [];
    for (const memberId of memberIds || []) {
      const member = this.clients.get(memberId);
      if (!member) continue;
      members.push(memberId);
      member.coopBattleId = id;
    }
    // Reclaim any group whose battle never said goodbye -- a client that
    // crashed rather than disconnected. Swept here, where the table grows,
    // for the reason sweepMatches gives: there is no interval to unref.
    const now = this.now();
    for (const [old, group] of this.coopBattles) {
      if (now - (group.startedAt || 0) > COOP_BATTLE_MAX_MS) {
        this.closeCoopBattle(old);
      }
    }
    this.coopBattles.set(id, { members, startedAt: now });
    // ...and the hub's own record of the fight, on the same id. Built even
    // though nothing may ever arrive for it: a client that never uploads a
    // ruleset simply leaves `sim` null, which is exactly how the legacy path
    // stays open underneath this one.
    this.openMediatedBattle(id, Object.assign({ memberIds: members }, plan || {}));
    return id;
  }

  // Forget it, and let the members out. A group that survived its players would
  // keep forwarding into ids that no longer connect.
  closeCoopBattle(id) {
    const group = this.coopBattles.get(id);
    if (!group) return false;
    this.coopBattles.delete(id);
    for (const memberId of group.members || []) {
      const member = this.clients.get(memberId);
      if (member && member.coopBattleId === id) member.coopBattleId = null;
    }
    // The group and the fight are the same event seen from two sides, so they
    // end together. A sim still holding a field here is one whose players have
    // all gone (the max-age sweep, a member dropping mid-setup); the fight is
    // called off rather than left refereeing an empty room.
    const record = this.battles.get(id);
    if (record) this.abortMediatedBattle(record, 'gone');
    return true;
  }

  endCoopAsk(id, name, reason) {
    const ask = this.coopAsks.get(id);
    if (!ask) return false;
    this.coopAsks.delete(id);
    for (const memberId of ask.everyone) {
      const member = this.clients.get(memberId);
      if (!member) continue;
      member.coopAskId = null;
      this.send(member, 'mmo.coop_decline', { name, reason });
    }
    return true;
  }

  // All four said yes. Each is told its own side and both rosters, so no
  // client has to work out who its allies are from a list it was not given.
  startCoopBattle(id) {
    const ask = this.coopAsks.get(id);
    if (!ask) return false;
    this.coopAsks.delete(id);

    const roster = (ids) => {
      const out = [];
      for (const memberId of ids) {
        const member = this.clients.get(memberId);
        if (!member || !member.ready) return null;
        out.push({ id: member.id, name: member.name });
      }
      return out;
    };

    const sideA = roster(ask.sideA);
    const sideB = roster(ask.sideB);
    // Re-checked at the moment of starting, not only when the ask went out:
    // somebody may have dropped between the third yes and this line, and four
    // players agreeing is only worth something if all four are still here.
    if (!sideA || !sideB) {
      this.coopAsks.set(id, ask);
      return this.endCoopAsk(id, null, 'gone');
    }

    // The membership outlives the ask, because the battle traffic is about to
    // need it: mmo.coop_relay goes to exactly these four and nobody else, and
    // the hub is the only party that knows who they are. The two sides go with
    // it -- this is the moment they are known, and a mediated field cannot be
    // assembled from a flat list of four.
    this.openCoopBattle(id, ask.everyone, {
      mode: 'coop_pvp', hostId: ask.asker,
      sides: { a: ask.sideA.slice(), b: ask.sideB.slice() },
    });

    // **Two sides, not two pairs.** A four-way is scored as one team match --
    // each player against the other pair's combined strength -- because that
    // is the match they played. See rank.js's recordTeam for why pairing them
    // off by slot index was the wrong answer.
    const side = (ids) => {
      const out = [];
      for (const memberId of ids) {
        const member = this.clients.get(memberId);
        if (member) {
          out.push({ id: member.id, name: member.name,
                     ranked: member.ranked !== false });
        }
      }
      return out;
    };
    this.coopMatches.set(id, {
      a: side(ask.sideA), b: side(ask.sideB),
      reports: new Map(), everyone: ask.everyone, startedAt: this.now(),
    });

    for (const memberId of ask.sideA) {
      const member = this.clients.get(memberId);
      member.coopAskId = null;
      this.send(member, 'mmo.coop_battle',
        { id, side: 'a', allies: sideA, foes: sideB, host: ask.asker });
    }
    for (const memberId of ask.sideB) {
      const member = this.clients.get(memberId);
      member.coopAskId = null;
      this.send(member, 'mmo.coop_battle',
        { id, side: 'b', allies: sideB, foes: sideA, host: ask.asker });
    }
    return true;
  }

  /*
   * One player's report on a 2-on-2. Same rule as a 1v1, one player wider:
   * the first answer from each of the four stands, and nothing is scored
   * until all four have spoken and agree. A side whose own two members tell
   * different stories has not won anything.
   */
  reportCoop(id, client, outcome) {
    const match = this.coopMatches.get(id);
    if (!match) return null;
    if (!match.everyone.includes(client.id)) return null;
    if (match.reports.has(client.id)) return null;
    match.reports.set(client.id, outcome);
    for (const memberId of match.everyone) {
      if (!match.reports.has(memberId)) return null;
    }
    return this.settleCoopMatch(id);
  }

  settleCoopMatch(id) {
    const match = this.coopMatches.get(id);
    if (!match) return null;
    // One battle, one settlement, whatever the verdict.
    this.coopMatches.delete(id);

    // What each side says happened, and it has to be unanimous *within* a
    // side before it is worth reading across sides. Two team-mates who cannot
    // agree whether they won have not won anything -- and neither has anybody
    // else, because a four-way has one result and this is it.
    const verdict = (members) => {
      let said = null;
      for (const member of members) {
        const report = match.reports.get(member.id);
        if (!report) return null;
        if (said === null) said = report;
        else if (said !== report) return null;
      }
      return said;
    };

    const saidA = verdict(match.a);
    const saidB = verdict(match.b);
    let winners = null;
    let losers = null;
    if (saidA === 'win' && saidB === 'loss') {
      winners = match.a; losers = match.b;
    } else if (saidA === 'loss' && saidB === 'win') {
      winners = match.b; losers = match.a;
    } else {
      // An agreed draw, or four players telling two different stories.
      return null;
    }

    // One unclaimed name anywhere in the four and the whole battle scores
    // nothing: paying out the half that is claimed would rate a team against
    // opponents whose ratings are not moving.
    for (const member of [...match.a, ...match.b]) {
      if (!member.ranked) return null;
    }

    const names = (members) => members.map((member) => member.id);
    const settled = this.board.recordTeam(names(winners), names(losers),
                                          this.now());
    if (!settled) return null;

    const byKey = new Map();
    for (const row of settled.winners) byKey.set(row.key, row.points);
    for (const row of settled.losers) byKey.set(row.key, row.points);
    for (const member of [...winners, ...losers]) {
      if (byKey.has(member.id)) {
        this.publishPoints(member.id, byKey.get(member.id));
      }
    }
    return settled;
  }

  // ------- plumbing

  send(client, type, payload) {
    if (!client || !client.peer) return;
    const msg = Object.assign({}, payload, { type });
    try {
      client.peer.send(msg);
    } catch (err) {
      // A message that will not serialise, or a handle whose socket died
      // between the check and the write, costs that connection and nothing
      // else: one peer must never be able to take the hub down for everyone.
      this.log.warn(`dropping ${client.id}: ${safe(err.message)}`);
      this.close(client);
      this.drop(client.id);
    }
  }

  close(client) {
    if (!client || !client.peer) return;
    try {
      client.peer.close();
    } catch (err) {
      /* already gone; there is nothing left to close */
    }
  }

  // Refuse someone who has a client record, and forget them in the same
  // breath. A connection turned away at hello will never become a player,
  // so leaving it in the table would hold a pending slot until the socket
  // layer noticed the close.
  refuse(client, message) {
    this.send(client, 'mmo.error', { message });
    this.close(client);
    this.drop(client.id);
  }

  broadcast(type, payload, exceptId) {
    for (const client of this.clients.values()) {
      if (client.id !== exceptId && client.ready) this.send(client, type, payload);
    }
  }

  // ------- operator actions
  //
  // The two things somebody standing at the terminal can do to a running
  // hub. Both are plain methods rather than a channel of their own: whatever
  // carries the operator's request -- an admin socket today -- decides how it
  // is trusted, and the relay only decides what it means.

  /*
   * Remove everybody playing under a name.
   *
   * Everybody, not somebody: two copies with the same trainer name can both
   * be here as RED and an operator kicking RED means both. The count and
   * the names actually removed go back so the caller can say what happened
   * rather than assuming one.
   *
   * The targets are collected before any of them is touched, because refuse()
   * deletes clients from the very map being walked -- and the second match is
   * exactly the one that would quietly survive the kick.
   */
  kickByName(name, reason) {
    const target = cleanText(name, NAME_MAX);
    const out = { kicked: 0, names: [] };
    if (!target) return out;
    const targetKey = target.toUpperCase();
    // Capped like a chat line, and for the same reason: it is drawn in the
    // client's error box, which was never sized for an essay.
    const message = cleanText(reason, MESSAGE_MAX) || KICK_REASON;

    const targets = [];
    for (const client of this.clients.values()) {
      if (client.ready && client.name
          && client.name.toUpperCase() === targetKey) targets.push(client);
    }
    for (const client of targets) {
      // The same three steps a refused hello gets -- tell them why, close the
      // socket, forget them -- because a kick is the same event arriving
      // later: drop() alone would leave the peer holding an open connection
      // to a hub that no longer believes in it.
      out.names.push(client.name);
      out.kicked += 1;
      this.refuse(client, message);
    }
    if (out.kicked) {
      this.log.info(`kicked ${out.kicked} player(s) named ${safe(out.names[0])}`);
    }
    return out;
  }

  /*
   * Say something to everyone, as the hub.
   *
   * An ordinary mmo.chat line with the hub's name on it, deliberately with no
   * `from`: every client renders a chat line from name, text and scope, and
   * the only thing `from` feeds is the speech bubble over that player's head
   * -- which the hub does not have. An id here would either be a real
   * player's (words in their mouth) or a made-up one, and a made-up one is
   * stored against nobody and drawn nowhere. Leaving it out is the honest
   * spelling of "this did not come from a trainer", and it is what makes the
   * line safe on clients that predate this feature.
   */
  announce(text) {
    const clean = cleanText(text, MESSAGE_MAX);
    if (!clean) return { delivered: 0 };
    let delivered = 0;
    for (const client of this.clients.values()) {
      if (client.ready) delivered += 1;
    }
    // No exception: there is no player to leave out.
    this.broadcast('mmo.chat',
      { name: HUB_NAME, scope: 'global', text: clean });
    this.log.info(`announced to ${delivered} player(s): ${safe(clean)}`);
    return { delivered };
  }

  // ------- sessions

  peerOf(client) {
    if (!client.sessionId) return null;
    const session = this.sessions.get(client.sessionId);
    if (!session) return null;
    return this.clients.get(session.a === client.id ? session.b : session.a) || null;
  }

  endSession(client, reason) {
    const id = client.sessionId;
    if (!id) return;
    // Leaving the session is leaving the field. A mediated fight starts its
    // reconnect grace here rather than ending on the spot, so a player who
    // backed out by accident has the same window a dropped socket gets.
    this.leaveBattle(client);
    const session = this.sessions.get(id);
    this.sessions.delete(id);
    client.sessionId = null;

    /*
     * A battle's paperwork outlives its session, briefly.
     *
     * The two players do not finish at the same instant -- each is reading
     * its own end-of-battle messages -- and whichever leaves first takes the
     * session down with it, so scoring only while the session was live would
     * score nothing at all. The match starts a clock here instead, and
     * sweepMatches() reaps it.
     */
    const match = this.matches.get(id);
    if (match && !match.endedAt) match.endedAt = this.now();

    if (session) {
      const otherId = session.a === client.id ? session.b : session.a;
      const other = this.clients.get(otherId);
      if (other && other.sessionId === id) {
        other.sessionId = null;
        this.send(other, 'mmo.session_end', { reason });
        this.broadcast('mmo.move', presenceOf(other), other.id);
      }
    }
    if (this.clients.has(client.id)) {
      this.broadcast('mmo.move', presenceOf(client), client.id);
    }
    this.noteRosterChange();
  }

  startSession(a, b, kind) {
    /*
     * Prefixed, because two counters mint into one `battles` map.
     *
     * A session and a co-op battle are numbered independently and both open a
     * mediated record under their own id, so the plain "1" the second of them
     * minted used to land on the first one's record -- a co-op fight inheriting
     * a 1v1's parties, or a battle_choice from one filed into the other. The
     * letter keeps the two id spaces apart, and it is a letter rather than a
     * colon because these ids cross the wire and cleanId refuses anything
     * outside [\w-].
     */
    const id = `s${this.nextSession++}`;
    this.sessions.set(id, { a: a.id, b: b.id, kind });
    a.sessionId = id;
    b.sessionId = id;

    // Only a battle can be scored, so only a battle gets paperwork. The
    // names are copied now, from what each player was admitted under, so the
    // rating lands on whoever actually fought even if one of them is gone by
    // the time the second report arrives.
    if (kind === 'battle') {
      this.matches.set(id, {
        a: a.id, b: b.id, aName: a.name, bName: b.name,
        aRanked: a.ranked !== false, bRanked: b.ranked !== false,
        reports: new Map(), startedAt: this.now(), endedAt: null,
      });
      this.sweepMatches();
    }

    // The requester hosts. Someone has to deal the battle's shared RNG seed,
    // and picking the side that asked keeps it deterministic rather than
    // racing on who answers first.
    this.send(a, 'mmo.session',
      { peer: b.id, peerName: b.name, kind, role: 'host', id });
    this.send(b, 'mmo.session',
      { peer: a.id, peerName: a.name, kind, role: 'guest', id });

    this.broadcast('mmo.move', presenceOf(a), a.id);
    this.broadcast('mmo.move', presenceOf(b), b.id);
    this.noteRosterChange();
    this.log.info(`session ${id}: ${safe(a.name)} <-> ${safe(b.name)} (${kind})`);

    // A battle session is also a mediated fight from the moment it opens.
    // Trade is untouched: there is no trade sim here.
    if (kind === 'battle') {
      this.openMediatedBattle(id, {
        mode: '1v1',
        hostId: a.id,
        memberIds: [a.id, b.id],
        sides: { a: [a.id], b: [b.id] },
      });
    }
  }

  // ------- mediated battles (Turn.js plumbing)

  /*
   * Open the hub's record of a fight. The sim is still null: a ruleset and
   * every required party have to arrive before tryStartSim takes it over.
   *
   * `npcIds` is set for coop_npc (two synthetic seats) and for wild /
   * coop_wild (one seat). Coop_npc: two players meet two monsters. Wild: one
   * player meets one wild mon on a hub NPC seat (protocol-only — no overworld
   * divert). Coop_wild: two humans on side a, one wild seat on side b
   * (overworld divert is client-side). The host uploads the NPC / wild team
   * as side "b".
   *
   * They are ids a client could in principle type, and that is safe rather than
   * sloppy: client ids are minted as decimal counters, these carry a letter and
   * the battle's own id, and nothing addresses a seat by name anyway -- a choice
   * is attributed to the connection it arrived on. It has to be spellable,
   * because tryStartSim advertises them and cleanId refuses a colon.
   */
  openMediatedBattle(id, plan) {
    const p = plan || {};
    const memberIds = [];
    for (const memberId of p.memberIds || []) {
      if (typeof memberId === 'string' && memberIds.indexOf(memberId) < 0) {
        memberIds.push(memberId);
      }
    }
    if (!memberIds.length) return null;

    let mode = p.mode;
    if (mode !== '1v1' && mode !== 'coop_npc' && mode !== 'coop_pvp'
        && mode !== 'wild' && mode !== 'coop_wild') {
      mode = memberIds.length <= 2 ? '1v1' : 'coop_pvp';
    }
    // coop_wild is a 2v1 contract (exactly two humans vs one wild seat).
    if (mode === 'coop_wild' && memberIds.length !== 2) return null;

    const hostId = p.hostId || memberIds[0];
    let npcIds = null;
    if (mode === 'coop_npc') {
      npcIds = [];
      for (let i = 0; i < COOP_SIDE; i += 1) {
        npcIds.push(`n${id}${String.fromCharCode(97 + i)}`);
      }
    } else if (mode === 'wild' || mode === 'coop_wild') {
      // One synthetic wild seat. Wild: one human. Coop_wild: two humans.
      // Protocol-only here — overworld divert for coop_wild is client-side.
      npcIds = [`n${id}a`];
    }

    let sides = p.sides;
    if (!sides || typeof sides !== 'object') {
      if (mode === '1v1') {
        sides = { a: [memberIds[0]], b: [memberIds[1] || memberIds[0]] };
      } else if (mode === 'coop_npc' || mode === 'wild' || mode === 'coop_wild') {
        sides = { a: memberIds.slice(), b: npcIds.slice() };
      } else {
        const mid = Math.ceil(memberIds.length / 2);
        sides = { a: memberIds.slice(0, mid), b: memberIds.slice(mid) };
      }
    }

    const record = {
      id,
      mode,
      hostId,
      memberIds,
      sides: {
        a: (sides.a || []).slice(),
        b: (sides.b || []).slice(),
      },
      npcIds,
      ruleset: null,
      parties: new Map(),
      bags: new Map(),
      bagHold: Object.create(null),
      sim: null,
      settled: false,
    };
    this.battles.set(id, record);
    for (const memberId of memberIds) {
      const member = this.clients.get(memberId);
      if (member) member.battleId = id;
    }
    return record;
  }

  // Is this seat one of the trainer's rather than a player's?
  isNpcSeat(record, seat) {
    return !!(record && record.npcIds && record.npcIds.includes(seat));
  }

  /*
   * Is this seat wildlife rather than a trainer? Wild / coop_wild seat their one
   * synthetic fighter with a wild monster, and a wild monster carries no bag --
   * so it is never handed the gym kit tryStartSim seeds a trainer seat with.
   * The turn machine refuses an item from that seat as well (isWildSeat in
   * lib/battle/Turn.js): this only keeps the bag from existing in the first
   * place.
   */
  isWildSeat(record, seat) {
    if (!record) return false;
    if (record.mode !== 'wild' && record.mode !== 'coop_wild') return false;
    return this.isNpcSeat(record, seat);
  }

  /*
   * Which seat a party fills. Normally the sender's own id. For coop_npc the
   * host may also upload the trainer party under side "b", which is dealt across
   * the synthetic npc seats rather than displacing their own team -- so this
   * answers the *first* of them, and fillBattleParty below does the dealing.
   */
  battleSeat(record, client, party) {
    if (!record.memberIds.includes(client.id)) return null;
    if (record.mode === 'coop_npc' && party.side === 'b'
        && client.id === record.hostId && record.npcIds) {
      return record.npcIds[0];
    }
    if ((record.mode === 'wild' || record.mode === 'coop_wild') && party.side === 'b'
        && client.id === record.hostId && record.npcIds) {
      return record.npcIds[0];
    }
    return client.id;
  }

  /*
   * Store an uploaded party against the seat or seats it fills.
   *
   * The trainer's team arrives as one list, because that is what it is on the
   * host's screen -- CoopBattle's `npcMons` re-interleaves the two ownerless
   * slots back into the order the trainer would send them out. Two seats fight
   * it, so it is dealt back out here, alternately, which is the inverse of that
   * interleave: the deal Coop.lua made when it built the field is the deal the
   * field gets back.
   *
   * A trainer with fewer monsters than seats leaves one empty, and an empty seat
   * is a field Turn.attempt refuses -- so the spare seat is given up instead and
   * the fight opens as the 2-on-1 the trainer actually brought. Refusing would
   * mean a lone-monster trainer could not be fought at all.
   */
  fillBattleParty(record, client, party) {
    const seat = this.battleSeat(record, client, party);
    if (!seat) return false;
    if (!this.isNpcSeat(record, seat)) {
      record.parties.set(seat, party);
      // Bag always keys off the connection: a host uploading side b for an NPC
      // never reaches this branch, so their own bag is not wiped by that upload.
      if (!record.bags) record.bags = new Map();
      record.bags.set(client.id, this.bagMap(party.bag));
      return true;
    }

    const dealt = record.npcIds.map(() => []);
    party.mons.forEach((mon, index) => {
      dealt[index % record.npcIds.length].push(mon);
    });

    const kept = [];
    const dropped = new Set();
    record.npcIds.forEach((npcId, at) => {
      if (dealt[at].length) {
        kept.push(npcId);
        record.parties.set(npcId, {
          battle: party.battle,
          side: party.side,
          badges: party.badges,
          mons: dealt[at],
        });
      } else {
        dropped.add(npcId);
        record.parties.delete(npcId);
      }
    });
    record.npcIds = kept;
    // Filtered rather than replaced: the side is the caller's description of the
    // field and may hold more than these seats one day, so only the seats
    // actually given up are taken out of it.
    record.sides.b = record.sides.b.filter((s) => !dropped.has(s));
    return true;
  }

  // List of `{id, count}` → lookup map. Empty / null → empty map (no items).
  bagMap(entries) {
    const map = Object.create(null);
    for (const entry of entries || []) {
      if (entry && typeof entry.id === 'string'
          && typeof entry.count === 'number' && entry.count > 0) {
        map[entry.id] = entry.count;
      }
    }
    return map;
  }

  // Shallow copy of an id→count bag map (null when empty / absent).
  cloneBagMap(src) {
    if (!src || typeof src !== 'object') return null;
    const out = Object.create(null);
    let any = false;
    for (const id of Object.keys(src)) {
      const count = src[id];
      if (typeof id === 'string' && typeof count === 'number' && count > 0) {
        out[id] = count;
        any = true;
      }
    }
    return any ? out : null;
  }

  canSpendBag(record, clientId, itemId) {
    if (typeof itemId !== 'string') return false;
    const bag = record && record.bags && record.bags.get(clientId);
    if (!bag) return false;
    return (bag[itemId] || 0) >= 1;
  }

  spendBag(record, clientId, itemId) {
    if (!this.canSpendBag(record, clientId, itemId)) return false;
    const effect = this.Effects.itemEffect(itemId);
    if (effect && effect.noConsume) return true;
    const bag = record.bags.get(clientId);
    bag[itemId] -= 1;
    if (bag[itemId] <= 0) delete bag[itemId];
    return true;
  }

  // Item stacks are held on choice accept and spent only when the turn leaves
  // the choice phase — so cancel/unchose drops the hold and never refunds.
  commitBagHolds(record) {
    const holds = record.bagHold;
    if (!holds) return;
    record.bagHold = Object.create(null);
    for (const clientId of Object.keys(holds)) {
      this.spendBag(record, clientId, holds[clientId]);
    }
  }

  // After the sim leaves choice, fighter.bag is authoritative (auto-pick and
  // human items both spend there). Mirror it onto the hub sheet and drop holds
  // so we never double-spend with commitBagHolds.
  syncBagsFromSim(record) {
    record.bagHold = Object.create(null);
    if (!record || !record.sim || !record.bags) return;
    for (const fighter of record.sim.fighters || []) {
      record.bags.set(fighter.playerId, this.cloneBagMap(fighter.bag) || Object.create(null));
    }
  }

  clearBagHold(record, clientId) {
    if (record && record.bagHold) delete record.bagHold[clientId];
  }

  holdBag(record, clientId, itemId) {
    if (!record.bagHold) record.bagHold = Object.create(null);
    record.bagHold[clientId] = itemId;
  }

  seatsNeeded(record) {
    const seats = record.memberIds.slice();
    for (const npcId of record.npcIds || []) seats.push(npcId);
    return seats;
  }

  tryStartSim(record) {
    if (!record || record.sim || record.settled) return false;
    if (!record.ruleset) return false;
    for (const seat of this.seatsNeeded(record)) {
      if (!record.parties.has(seat)) return false;
    }

    const fighterOf = (seat) => {
      const party = record.parties.get(seat);
      if (!party) return null;
      const client = this.clients.get(seat);
      // Seed trainer NPC seats with a gym-style kit when the host uploaded no
      // bag. A wild seat is skipped: wildlife does not carry items.
      if (!record.bags) record.bags = new Map();
      if (!record.bags.has(seat) && this.isNpcSeat(record, seat)
          && !this.isWildSeat(record, seat)) {
        record.bags.set(seat, this.cloneBagMap(this.Turn.DEFAULT_NPC_BAG));
      }
      const bag = record.bags.get(seat);
      const bagCopy = this.cloneBagMap(bag);
      return {
        playerId: seat,
        name: (client && client.name)
          || (this.isNpcSeat(record, seat) ? 'TRAINER' : seat),
        mons: party.mons,
        badges: party.badges,
        bag: bagCopy || undefined,
      };
    };

    const sideRoster = (keys) => {
      const out = [];
      for (const seat of keys || []) {
        const fighter = fighterOf(seat);
        if (fighter) out.push(fighter);
      }
      return out;
    };

    /*
     * The seed is the intermediator's and nobody else's.
     *
     * A client may still *send* one -- the message has carried the field since
     * the lockstep days and refusing it now would drop the whole ruleset over a
     * value nothing reads -- but a fight whose seed came off the wire is a fight
     * the authority can replay offline until it finds a run it likes, and then
     * ask for that run. Every roll in a mediated battle is drawn from this
     * stream, so choosing it is the whole of what the intermediator is for.
     *
     * `forceBattleSeed` is the one way in, and it is a *relay* field rather than
     * a message: a suite that needs a reproducible fight sets it on the relay it
     * constructed, which is not something a connection can reach.
     */
    const seed = typeof this.forceBattleSeed === 'number'
      ? this.forceBattleSeed
      : (1 + Math.floor(Math.random() * BATTLE_SEED_MAX));
    const created = this.Turn.attempt({
      id: record.id,
      mode: record.mode,
      seed,
      chart: record.ruleset.chart,
      specialTypes: record.ruleset.specialTypes,
      metronomePool: record.ruleset.metronomePool,
      choiceTimeout: BATTLE_CHOICE_TIMEOUT,
      reconnectGrace: BATTLE_RECONNECT_GRACE,
      resolveTimeout: BATTLE_RESOLVE_TIMEOUT,
      now: battleSeconds(this.now()),
      sides: {
        a: sideRoster(record.sides.a),
        b: sideRoster(record.sides.b),
      },
    });
    if (!created.battle) {
      this.log.warn(`mediated battle ${record.id} refused: ${safe(created.reason)}`);
      return false;
    }
    record.sim = created.battle;

    /*
     * The npc seats are advertised under their own ids, not hidden behind the
     * host's.
     *
     * They used to be filtered out and the emptied side announced as the host,
     * because the seat was not an id a client could address -- and CoopBattle's
     * `medMap` then had to guess that an advertised id owning no slot on that
     * side meant the ownerless ones. Two seats is one guess too many: with both
     * named, the map is a lookup again and the trainer's second box has a field
     * slot rather than being drawn and never spoken about. Nothing is opened up
     * by naming them, because a choice is attributed to the connection it
     * arrived on and no connection is either of these.
     */
    const ready = {
      battle: record.id,
      mode: record.mode,
      sides: { a: record.sides.a.slice(), b: record.sides.b.slice() },
    };
    // cleanBattleReady refuses an empty side, so a side that somehow lost every
    // seat is announced as the host rather than as a message no client reads.
    if (!ready.sides.b.length && record.hostId) {
      ready.sides.b = [record.hostId];
    }
    if (!ready.sides.a.length && record.hostId) {
      ready.sides.a = [record.hostId];
    }
    this.broadcastBattle(record, 'mmo.battle_ready', ready);
    this.flushBattle(record);
    this.log.info(`mediated battle ${record.id} started (${record.mode})`);
    return true;
  }

  broadcastBattle(record, type, payload) {
    for (const memberId of record.memberIds) {
      const member = this.clients.get(memberId);
      if (member && member.ready) this.send(member, type, payload);
    }
  }

  /*
   * Answer for the trainer, for as long as it owes an answer.
   *
   * The npc seats have no connection to send mmo.battle_choice, so without this
   * every turn of a coop_npc would sit out BATTLE_CHOICE_TIMEOUT and then be
   * auto-picked anyway -- a minute a turn, which is not a battle. The pick is the
   * turn machine's own (first move with PP, at the first living foe), so what
   * happens here is exactly what used to happen a minute later.
   *
   * The loop is what carries the fight forward rather than a retry: filing the
   * last outstanding choice resolves the turn and opens the next one, where the
   * trainer owes again. It is bounded because a machine that opened a turn it
   * cannot close is a hub that stops answering anything, and that is a worse
   * failure than a fight that pauses.
   */
  fillNpcChoices(record) {
    if (!record || !record.sim || record.settled) return false;
    const seats = record.npcIds;
    if (!seats || !seats.length) return false;

    let filed = false;
    const bound = this.Turn.MONS_PER_PARTY * COOP_SIDE * 2;
    for (let pass = 0; pass < bound; pass += 1) {
      let any = false;
      for (const seat of seats) {
        if (record.sim.autoPick(seat)) { any = true; filed = true; }
      }
      if (!any) break;
    }
    return filed;
  }

  flushBattle(record) {
    if (!record || !record.sim || record.settled) return;
    // Before the drain rather than after it: the trainer's answer can be the one
    // that closes the turn, and the events that turn produced have to go out in
    // this same pass or nothing else would send them until somebody else spoke.
    // Nothing here calls back into this function, so the two cannot chase each
    // other.
    this.fillNpcChoices(record);
    // Fighter bags are authoritative after resolve (Turn spends on item use,
    // including NPC auto-pick). Sync the hub sheet and drop holds so we never
    // double-spend with commitBagHolds.
    if (record.sim.phase !== 'choice') {
      this.syncBagsFromSim(record);
    }
    const events = record.sim.drainEvents();
    for (const event of events) {
      this.broadcastBattle(record, 'mmo.battle_event', event);
    }
    const outcome = record.sim.outcome();
    if (outcome) this.settleMediated(record, outcome);
  }

  tickBattles(nowMs) {
    const now = battleSeconds(
      typeof nowMs === 'number' ? nowMs : this.now());
    for (const record of this.battles.values()) {
      if (!record.sim || record.settled) continue;
      record.sim.tick(now);
      this.flushBattle(record);
    }
  }

  /*
   * A connection left the field. Returns true when a live sim started its
   * reconnect grace (the fight continues); false when the record was aborted
   * or there was nothing to leave.
   */
  leaveBattle(client) {
    if (!client || !client.battleId) return false;
    const record = this.battles.get(client.battleId);
    if (!record) {
      client.battleId = null;
      return false;
    }
    if (record.sim && !record.settled) {
      if (record.sim.disconnect(client.id)) this.flushBattle(record);
      return true;
    }
    // Still collecting parties / ruleset: call the fight off.
    this.abortMediatedBattle(record, 'gone');
    return false;
  }

  abortMediatedBattle(record, reason) {
    if (!record || record.settled) return;
    if (record.sim) {
      // Force a draw-ish end by disconnecting everyone still owed a grace.
      for (const memberId of record.memberIds) {
        record.sim.disconnect(memberId);
      }
      // Expire grace immediately.
      record.sim.tick(battleSeconds(this.now()) + BATTLE_RECONNECT_GRACE + 1);
      this.flushBattle(record);
      if (record.settled) return;
    }
    record.settled = true;
    // Omit empty winners/losers: Wire.battleOutcome refuses an empty id list,
    // and a refused outcome would leave the client with no way out.
    const abortPayload = {
      battle: record.id,
      outcome: 'draw',
      reason: reason || 'gone',
    };
    this.broadcastBattle(record, 'mmo.battle_outcome', abortPayload);
    this.clearBattle(record);
  }

  settleMediated(record, outcome) {
    if (!record || record.settled) return null;
    record.settled = true;
    /*
     * Present only when there is somebody in them, which is the same rule
     * abortMediatedBattle follows and for the same reason: cleanBattleOutcome
     * refuses an empty id list, so a draw carrying two of them is a message no
     * client reads -- a battle screen with no way out. A null `reason` is
     * omitted on the same grounds.
     */
    const payload = { battle: record.id, outcome: outcome.outcome };
    if (outcome.winners && outcome.winners.length) {
      payload.winners = outcome.winners;
    }
    if (outcome.losers && outcome.losers.length) {
      payload.losers = outcome.losers;
    }
    if (outcome.reason) payload.reason = outcome.reason;
    if (outcome.caught) payload.caught = outcome.caught;
    if (outcome.catcher) payload.catcher = outcome.catcher;
    this.broadcastBattle(record, 'mmo.battle_outcome', payload);

    // Rank from the intermediator alone -- no dual mmo.result vote.
    const match = this.matches.get(record.id);
    if (match && record.mode === '1v1') {
      this.matches.delete(record.id);
      const winners = payload.winners || [];
      const losers = payload.losers || [];
      if (payload.outcome === 'win' || payload.outcome === 'loss'
          || payload.outcome === 'forfeit') {
        let winnerId = null;
        let loserId = null;
        if (winners[0] === match.a) {
          winnerId = match.a;
          loserId = match.b;
        } else if (winners[0] === match.b) {
          winnerId = match.b;
          loserId = match.a;
        } else if (losers[0] === match.a) {
          loserId = match.a;
          winnerId = match.b;
        } else if (losers[0] === match.b) {
          loserId = match.b;
          winnerId = match.a;
        }
        if (winnerId && loserId && match.aRanked && match.bRanked) {
          const settled = this.board.record(winnerId, loserId, this.now());
          if (settled) {
            this.publishPoints(winnerId, settled.winner.points);
            this.publishPoints(loserId, settled.loser.points);
            this.noteRankChange(settled);
            // The intermediator's settle. `at` is the settlement instant and
            // not `match.endedAt`: a refereed outcome routinely arrives while
            // both players are still in the session, so endedAt is usually
            // unset here -- and where it IS set, the referee's verdict is the
            // moment that matters, not whenever somebody's socket went.
            this.noteMatchSettled(match, settled, this.now());
          }
        }
      }
    } else if (this.coopMatches.has(record.id) && record.mode === 'coop_pvp') {
      // Trust intermediator for team settle: synthesise unanimous reports.
      const coop = this.coopMatches.get(record.id);
      if (coop) {
        const winSet = new Set(payload.winners || []);
        for (const memberId of coop.everyone) {
          coop.reports.set(memberId,
            winSet.has(memberId) ? 'win' : 'loss');
        }
        // If draw/forfeit unclear, leave reports alone and drop paperwork.
        if (payload.outcome === 'draw') {
          this.coopMatches.delete(record.id);
        } else {
          this.settleCoopMatch(record.id);
        }
      }
    }

    this.clearBattle(record);
    return payload;
  }

  clearBattle(record) {
    if (!record) return;
    for (const memberId of record.memberIds) {
      const member = this.clients.get(memberId);
      if (member && member.battleId === record.id) member.battleId = null;
    }
    this.battles.delete(record.id);
  }

  // ------- ranked PVP

  /*
   * Finished battles nobody ever agreed on. Dropped rather than guessed at:
   * one report is not a result, and a hub that kept them would grow a table
   * of unfinished arguments for as long as it ran. Swept when a new battle
   * starts rather than on a timer, because that is the only moment the table
   * can grow and there is no interval to unref here.
   */
  sweepMatches() {
    const now = this.now();
    for (const [id, match] of this.matches) {
      if (match.endedAt && now - match.endedAt > RANK_REPORT_GRACE_MS) {
        this.matches.delete(id);
      }
    }
  }

  /*
   * Tell the whole hub what somebody is worth now. Broadcast with no
   * exception, so the player it is about hears it too: their own score is
   * not in their own roster, and a menu that only updated for other people
   * would be the one place the number was stale.
   */
  publishPoints(clientId, points) {
    const client = this.clients.get(clientId);
    if (!client) return;
    client.points = points;
    this.broadcast('mmo.rank', { id: clientId, points: cleanPoints(points) });
    this.noteRosterChange();
  }

  /*
   * Score a battle, but only once both sides have said the same thing about
   * it.
   *
   * **This is the whole anti-cheat story, and it is deliberately small.** A
   * result is a claim by a stranger's process; the only cheap thing that
   * makes it worth more is a second, independent claim that agrees. So a
   * lone report scores nothing and two reports that disagree score nothing.
   *
   * What that leaves open is stated rather than papered over: a ranked
   * mid-battle drop after reconnect grace is a forfeit loss scored via the
   * intermediator (settleMediated), not a dual-report draw. A link battle
   * still draws when the connection dies with no witness -- paying for one
   * would pay for pulling the cable out.
   */
  settleMatch(id) {
    const match = this.matches.get(id);
    if (!match) return null;
    const first = match.reports.get(match.a);
    const second = match.reports.get(match.b);
    if (!first || !second) return null;

    this.matches.delete(id);

    let winner = null;
    let loser = null;
    if (first === 'win' && second === 'loss') {
      winner = match.a;
      loser = match.b;
    } else if (first === 'loss' && second === 'win') {
      winner = match.b;
      loser = match.a;
    } else {
      return null;
    }

    if (!match.aRanked || !match.bRanked) return null;

    const settled = this.board.record(winner, loser, this.now());
    if (!settled) return null;

    this.publishPoints(winner, settled.winner.points);
    this.publishPoints(loser, settled.loser.points);
    this.log.info(`ranked: ${safe(settled.winner.name)} ` +
      `${settled.winner.points} (+${settled.winner.gained}) beat ` +
      `${safe(settled.loser.name)} ${settled.loser.points} ` +
      `(-${settled.loser.lost})`);
    this.noteRankChange(settled);
    // One of the two points a result is known to be real: both sides agreed
    // and both were ranked. `settleMediated` is the other -- the referee said
    // so -- and both hand the ledger its line through `noteMatchSettled`,
    // which owns the shape so the two can never write different records.
    // When it ended: the moment the session came down, or -- for a pair that
    // both reported before either left the session, which is a normal race and
    // not an error -- the moment it settled, which is now. Never null: a
    // history line whose timestamp is missing is a line no reader can sort or
    // print.
    this.noteMatchSettled(match, settled, match.endedAt || this.now());
    return settled;
  }

  /*
   * The board moved: a rating changed. Whoever owns the file is told, and
   * whatever they do about it is their business -- the board in memory is
   * already correct, so a hook that throws is a full disk and not a lost
   * result.
   *
   * `settled` is the match that moved the ratings, or null when only the
   * board was touched without a finished fight.
   */
  noteRankChange(settled) {
    if (!this.onRankChange) return;
    try {
      this.onRankChange(settled || null);
    } catch (err) {
      // Persistence is somebody else's problem and must not cost the
      // players their result: the ratings are already correct in memory.
      this.log.warn(`could not record a rank change: ${safe(err.message)}`);
    }
  }

  /*
   * A battle finished and was paid. Guarded exactly like noteRankChange, and
   * for exactly the same reason: the ratings are already correct in memory
   * and the players have already been told, so a listener that throws is a
   * line missing from a log file, never a lost result.
   */
  noteMatchSettled(match, settled, at) {
    if (!this.onMatchSettled) return;
    /*
     * **The one definition of a history line, and the reason this builds it
     * rather than taking one.**
     *
     * Two call sites reach the ledger -- `settleMediated` (the referee said
     * so) and `settleMatch` (both sides agreed) -- and each used to spell the
     * record out itself, byte-identical apart from the timestamp. Only one of
     * the two was ever under test, so a field added or dropped on that side
     * alone would have gone out silently and the ledger would have carried two
     * shapes.
     *
     * That is not a hypothetical about a private object: `history.jsonl` is
     * append-only, operator-facing, and read back by `lib/cli.js:historyRecord`
     * -- which renders `NAME #abcd` from `id` (PROTOCOL 16) so two players
     * called ASH are told apart. A path that stopped emitting `id` would not
     * write a tidier line, it would write an ambiguous one, and only for
     * battles settled that particular way.
     *
     * `at` stays a parameter because the two sites genuinely disagree about it
     * and both are right; everything else is fixed here. Nothing else is
     * added: this file is persisted, so `key`, internals and whole battler
     * sheets stay out of it. `rank.test.js` and `server.test.js` both pin the
     * exact key set.
     */
    const side = (entry, movedKey, moved) => ({
      id: entry.key,
      name: entry.name,
      points: entry.points,
      [movedKey]: moved,
    });
    const record = {
      at,
      startedAt: match.startedAt,
      repeats: settled.repeats,
      winner: side(settled.winner, 'gained', settled.winner.gained),
      loser: side(settled.loser, 'lost', settled.loser.lost),
    };
    try {
      this.onMatchSettled(record);
    } catch (err) {
      this.log.warn(`could not record a settled match: ${safe(err.message)}`);
    }
  }

  /*
   * The top ten, as the hub ranks them. Every row goes out through the same
   * sanitisers a client will read it with, so a name or a sprite that would
   * not survive the trip is fixed here rather than silently dropped there.
   */
  leaderboard() {
    return this.board.top(RANK_TOP).map((row) => {
      const out = {
        name: row.name,
        sprite: cleanSpriteId(row.sprite) || defaultSpriteFor(this.generation),
        points: cleanPoints(row.points),
      };
      const id = cleanPlayerId(row.id);
      if (id) out.id = id;
      return out;
    });
  }

  // ------- entry point

  handle(id, msg) {
    const client = this.get(id);
    if (!client) return;
    if (!msg || typeof msg !== 'object' || typeof msg.type !== 'string') return;
    const handler = handlers[msg.type];
    if (!handler) return;
    try {
      handler(this, client, msg);
    } catch (err) {
      this.log.warn(`handler ${safe(msg.type)} failed for ${id}: ` +
        `${safe(err.message)}`);
    }
  }
}

// PROTOCOL is exported so the suites speak the current dialect by naming it
// rather than by carrying a hardcoded number that has to be found and edited
// in six places every time it moves.
module.exports = {
  Relay, parseLine, presenceOf, PROTOCOL, SPRITE_GATE_MS, DEFAULT_SPRITE,
  DEFAULT_SPRITE_GEN2, defaultSpriteFor,
  FRIEND_HOLD_MS, FRIEND_HOLD_PER_NAME, FRIEND_HOLD_MAX,
};
