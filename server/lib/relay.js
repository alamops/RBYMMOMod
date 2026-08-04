'use strict';

/*
 * The hub, as pure logic.
 *
 * This is what server/hub.js used to be, minus the socket. It owns who is
 * connected, where they last said they were, and which two players are
 * currently paired for a trade or a battle. It never simulates anything:
 * the trade state machine and the lockstep battle run inside the two game
 * clients on the engine's own link code, and mmo.relay payloads pass
 * through unread.
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
  cleanProfile, cleanOutcome, cleanPoints, cleanToken, payloadOk, FACINGS,
  KINDS, SCOPES, NAME_MAX, MESSAGE_MAX, LOCAL_RADIUS,
} = require('./sanitize');
const {
  Board, mintToken, RANK_START, RANK_TOP, RANK_REPORT_GRACE_MS,
  RANK_QUERY_GATE_MS,
} = require('./rank');
const { createLog, safe } = require('./log');

const DEFAULT_PLAYERS = 4;
const DEFAULT_SPRITE = 'SPRITE_RED';
// The wire dialect this hub speaks, and the one number both suites greet
// with. 3 is where parties landed: nothing was removed, but an invite or a
// party chat line sent to a protocol-2 hub would meet a handler table that
// answers an unknown type with silence, and a player pressing INVITE and
// watching nothing happen is a worse sentence than a refusal that names both
// versions. 4 is ranked PVP, and moved for the same reason rather than a
// different one -- a protocol-3 hub has never heard of a battle result or a
// leaderboard request, so a newer client would report every match into
// silence. Kept in step with Config.PROTOCOL on the mod side.
const PROTOCOL = 4;
// A SHA-256 response is 64 hex characters; the slack is for a future digest,
// not for an unbounded field.
const RESPONSE_MAX = 128;

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
    return relay.refuse(client, `This hub speaks protocol ${relay.protocol}; ` +
      `your mod speaks ${shortValue(msg.proto)}.`);
  }
  const name = cleanText(msg.name, NAME_MAX);
  if (!name) return relay.refuse(client, 'That trainer name cannot be used here.');

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
    // the ticket that says this name is theirs, if they have been here
    // before; absent on a first visit and on a copy that lost its save
    token: cleanToken(msg.rankToken),
    sprite: cleanSpriteId(msg.sprite) || DEFAULT_SPRITE,
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
  relay.admit(client);
};

handlers['mmo.move'] = (relay, client, msg) => {
  if (!client.ready) return;
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
  relay.broadcast('mmo.move', presenceOf(client), client.id);
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
    const target = relay.clients.get(cleanId(msg.to));
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
  const target = relay.clients.get(cleanId(msg.to));
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
  const asker = relay.clients.get(cleanId(msg.to));
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
  const target = relay.clients.get(cleanId(msg.to));
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
  const asker = relay.clients.get(cleanId(msg.to));
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

handlers['mmo.relay'] = (relay, client, msg) => {
  if (!client.ready || !client.sessionId) {
    return noteDrop(relay, client, 'sender is not in a session');
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
    this.auth = opts.auth || null;
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
    /** sessionId -> { a, b, aName, bName, reports, endedAt } */
    this.matches = new Map();

    this.nextId = 1;
    this.nextSession = 1;
    this.nextParty = 1;
    this.players = 0;
  }

  // ------- roster

  // Full means no room for another *player*. A connection that has not said
  // hello is not a player and must not be able to hold a seat; how many of
  // those are tolerated at once is lib/limits.js's question, not this one.
  get playerCount() { return this.players; }

  get pendingCount() { return this.clients.size - this.players; }

  isFull() { return this.players >= this.maxPlayers; }

  has(id) { return this.clients.has(id); }

  get(id) { return this.clients.get(id) || null; }

  clientIds() { return Array.from(this.clients.keys()); }

  greeted(id) {
    const client = this.clients.get(id);
    return Boolean(client && client.ready);
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
      sprite: DEFAULT_SPRITE,
      profile: null,
      map: null, x: null, y: null, facing: 'down',
      sessionId: null,
      pendingTo: null,
      partyId: null,
      partyPendingTo: null,
      // -Infinity, not 0: an injected clock that starts at zero would
      // otherwise gate the very first message a player ever sends.
      lastChat: -Infinity,
      lastRanks: -Infinity,
      points: RANK_START,
      // until a hello says otherwise, nobody is scored: `ranked` is decided
      // in admit(), where the name is claimed
      ranked: false,
      hello: null,
      nonce: null,
      credentialId: null,
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
    client.name = hello.name;
    client.sprite = hello.sprite || DEFAULT_SPRITE;
    client.profile = hello.profile || null;
    client.map = hello.map === undefined ? null : hello.map;
    client.x = hello.x === undefined ? null : hello.x;
    client.y = hello.y === undefined ? null : hello.y;
    client.facing = hello.facing || 'down';
    client.hello = null;
    client.nonce = null;
    client.ready = true;
    /*
     * Who is behind the name.
     *
     * A first visit claims it and is handed the ticket to come back with; a
     * returning player presents theirs and gets their rating; anybody else
     * typing that name plays as normal and scores nothing. `minted` goes out
     * in the welcome and is then forgotten -- only the digest is kept, so
     * this is the one moment the token exists on the hub.
     */
    const minted = mintToken();
    const verdict = this.board.claim(client.name, hello.token, minted);
    client.ranked = verdict !== 'impostor';
    if (verdict === 'impostor') {
      this.log.info(`${safe(client.name)} (${client.id}) joined without the ` +
        'claim token for that name, so their battles will not be scored');
    }

    // The rating this name already carries on this hub, and the character it
    // is wearing today -- so the leaderboard can draw a portrait for a
    // player who is offline, and a returning player is not silently zeroed.
    // An unranked player shows as zero rather than wearing the rating of the
    // name they typed: it is not theirs.
    this.board.seen(client.name, client.sprite);
    client.points = client.ranked ? this.board.points(client.name) : RANK_START;
    this.players += 1;

    const players = [];
    for (const other of this.clients.values()) {
      if (other.ready && other.id !== client.id) players.push(presenceOf(other));
    }
    // `points` is this player's own rating, spelled out rather than left to
    // be fished out of the roster: the roster a client keeps deliberately
    // has no entry for itself, so the welcome is the only place your own
    // score can arrive from.
    this.send(client, 'mmo.welcome', {
      id: client.id,
      players,
      points: client.points,
      // Sent exactly once, on the visit that claimed the name. Nothing
      // re-sends it: a hub that handed the ticket to whoever asked would not
      // be checking anything.
      rankToken: verdict === 'claimed' ? minted : undefined,
      // Said out loud rather than left to be inferred from a zero: "your
      // battles will not score here" is something a player can act on.
      ranked: client.ranked,
    });
    this.broadcast('mmo.join', { player: presenceOf(client) }, client.id);
    this.log.info(`+ ${safe(client.name)} (${client.id}) -- ` +
      `${this.players} online`);
  }

  drop(id) {
    const client = this.clients.get(id);
    if (!client) return false;
    this.endSession(client, 'peer_left');
    // A party outlives a trade but not a connection: the other member is told
    // while this one is still in the table, so the presence that goes out
    // with it is the one where they are no longer in a party.
    this.endParty(client, 'peer_left');
    this.clients.delete(id);
    if (client.ready) this.players -= 1;
    // an outstanding request pointed at a player who just left would leave
    // the asker waiting forever for an answer nobody can give
    for (const other of this.clients.values()) {
      if (other.pendingTo === id) other.pendingTo = null;
      if (other.partyPendingTo === id) other.partyPendingTo = null;
    }
    if (client.ready) {
      this.broadcast('mmo.part', { id }, id);
      this.log.info(`- ${safe(client.name)} (${id}) -- ${this.players} online`);
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
    this.log.info(`party ${id}: ${safe(a.name)} + ${safe(b.name)}`);
  }

  // One member leaving ends it for both. At PARTY_MAX = 2 there is no party
  // left to continue, and a "party" of one that still showed a members list
  // and a chat scope with nowhere to send would be worse than none.
  endParty(client, reason) {
    const id = client.partyId;
    if (!id) return;
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
  }

  startSession(a, b, kind) {
    const id = String(this.nextSession++);
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
        // taken now, from the players in the battle: whether a result may
        // touch the board is a fact about who they are, not about what they
        // report afterwards
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
    this.log.info(`session ${id}: ${safe(a.name)} <-> ${safe(b.name)} (${kind})`);
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
   * What that leaves open is stated rather than papered over: a player who
   * quits mid-battle is a draw for the side still standing (the engine's own
   * LinkBattle ends a dead link that way), so rage-quitting avoids the loss.
   * Deciding otherwise would mean believing one side alone, which is the
   * larger hole -- anyone could then mint wins against a player who never
   * connected.
   */
  settleMatch(id) {
    const match = this.matches.get(id);
    if (!match) return null;
    const first = match.reports.get(match.a);
    const second = match.reports.get(match.b);
    if (!first || !second) return null;

    // One match, one settlement: the paperwork goes whatever the verdict is,
    // so a pair cannot re-report their way to a second payout.
    this.matches.delete(id);

    let winner = null;
    let loser = null;
    if (first === 'win' && second === 'loss') {
      winner = match.aName;
      loser = match.bName;
    } else if (first === 'loss' && second === 'win') {
      winner = match.bName;
      loser = match.aName;
    } else {
      // An agreed draw, or two clients telling different stories. Neither is
      // worth points, and neither is worth a sentence on anybody's screen.
      return null;
    }

    // A battle is only worth points when both players are who they say they
    // are. One impostor and the whole match scores nothing: paying out half
    // of it would move a rating belonging to somebody who was not playing.
    if (!match.aRanked || !match.bRanked) return null;

    const settled = this.board.record(winner, loser, this.now());
    if (!settled) return null;

    const winnerId = winner === match.aName ? match.a : match.b;
    const loserId = winnerId === match.a ? match.b : match.a;
    this.publishPoints(winnerId, settled.winner.points);
    this.publishPoints(loserId, settled.loser.points);
    this.log.info(`ranked: ${safe(settled.winner.name)} ` +
      `${settled.winner.points} (+${settled.winner.gained}) beat ` +
      `${safe(settled.loser.name)} ${settled.loser.points} ` +
      `(-${settled.loser.lost})`);
    if (this.onRankChange) {
      try {
        this.onRankChange(settled);
      } catch (err) {
        // Persistence is somebody else's problem and must not cost the
        // players their result: the ratings are already correct in memory.
        this.log.warn(`could not record a rank change: ${safe(err.message)}`);
      }
    }
    return settled;
  }

  /*
   * The top ten, as the hub ranks them. Every row goes out through the same
   * sanitisers a client will read it with, so a name or a sprite that would
   * not survive the trip is fixed here rather than silently dropped there.
   */
  leaderboard() {
    return this.board.top(RANK_TOP).map((row) => ({
      name: row.name,
      sprite: cleanSpriteId(row.sprite) || DEFAULT_SPRITE,
      points: cleanPoints(row.points),
    }));
  }

  // ------- entry point

  handle(id, msg) {
    const client = this.clients.get(id);
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
module.exports = { Relay, parseLine, presenceOf, PROTOCOL };
