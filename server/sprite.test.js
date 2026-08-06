#!/usr/bin/env node
'use strict';

/*
 * Unit tests for `mmo.sprite` on the node hub: the character a player is
 * wearing, changed mid-session, stored by `lib/relay.js` and broadcast the
 * same way `publishPoints` broadcasts a rating -- no exception, the subject
 * hears it too. See docs/plans/online-char-selection.md for the shape being
 * pinned, and src/rby_mmo_test.lua's mirrored section for the Lua half: both
 * suites drive the same cases, with the same assertion strings, because a
 * hub that stores or gates this differently from the other is a bug that
 * only shows up on one of the two hosting paths.
 *
 * Socket-free by construction, like rank.test.js: `Relay` talks to peer
 * handles, so the clients here are objects with a `send`, and the clock is
 * injected -- which is what lets the SPRITE_GATE_MS cases run without a real
 * sleep.
 *
 * `SPRITE_GATE_MS` and `DEFAULT_SPRITE` are imported from lib/relay.js
 * (which exports them the way lib/rank.js exports RANK_QUERY_GATE_MS), so
 * the gate cases here can never drift from the window the hub actually
 * enforces.
 *
 * Run: node server/sprite.test.js
 */

const { Relay, PROTOCOL, SPRITE_GATE_MS, DEFAULT_SPRITE } = require('./lib/relay.js');
const { createLog } = require('./lib/log.js');

let passed = 0;
const ok = (cond, label) => {
  if (!cond) throw new Error('FAIL: ' + label);
  passed++;
};

const quiet = createLog({ level: 'error' });


function makeClock(start = 1000) {
  let t = start;
  return { now: () => t, advance(ms) { t += ms; } };
}

function makeRelay(clock, opts) {
  return new Relay(Object.assign(
    { maxPlayers: 8, log: quiet, now: clock.now }, opts || {}));
}

/*
 * A player, dialed in through the same entry point a socket would use. Peers
 * keep an outbox instead of a socket; `take` pulls the first message of a
 * type so a later assertion is not confused by earlier traffic. Matches the
 * `dial`/`take` idiom rank.test.js already uses for the same reason.
 */
function dial(relay, name, opts) {
  const o = opts || {};
  const peer = { outbox: [], remoteAddress: '127.0.0.1' };
  peer.send = (msg) => peer.outbox.push(msg);
  peer.close = () => {};
  const id = relay.accept(peer);
  relay.handle(id, {
    type: 'mmo.hello',
    proto: PROTOCOL,
    name,
    sprite: o.sprite || DEFAULT_SPRITE,
    rankToken: o.token,
    map: o.map === undefined ? 'PALLET' : o.map,
    x: o.x === undefined ? 1 : o.x,
    y: o.y === undefined ? 1 : o.y,
    facing: 'down',
  });
  const welcome = peer.outbox.find((m) => m.type === 'mmo.welcome');
  return { id, peer, name, welcome };
}

// A connection that has connected but never said hello: accepted, never
// admitted, so it has no name and cannot be dialed through the helper above.
function connectSilently(relay) {
  const peer = { outbox: [], remoteAddress: '127.0.0.1' };
  peer.send = (msg) => peer.outbox.push(msg);
  peer.close = () => {};
  const id = relay.accept(peer);
  return { id, peer };
}

function take(player, type) {
  const index = player.peer.outbox.findIndex((m) => m.type === type);
  if (index < 0) return null;
  return player.peer.outbox.splice(index, 1)[0];
}

// ------------------------------------------------------------- store + fan-out

function testStoresAndBroadcastsToEveryone() {
  const clock = makeClock();
  const relay = makeRelay(clock);
  const one = dial(relay, 'ONE', { sprite: 'SPRITE_RED' });
  const two = dial(relay, 'TWO', { sprite: 'SPRITE_RED' });
  one.peer.outbox = [];
  two.peer.outbox = [];

  relay.handle(one.id, { type: 'mmo.sprite', sprite: 'SPRITE_BLUE' });

  const heardBySender = take(one, 'mmo.sprite');
  const heardByOther = take(two, 'mmo.sprite');
  ok(relay.get(one.id).sprite === 'SPRITE_BLUE'
    && heardBySender && heardBySender.sprite === 'SPRITE_BLUE'
    && heardBySender.id === one.id
    && heardByOther && heardByOther.sprite === 'SPRITE_BLUE'
    && heardByOther.id === one.id,
    'a sprite change is stored and broadcast to everyone, the sender too');
}

function testBadSpriteIdCostsOnlyTheMessage() {
  const clock = makeClock();
  const relay = makeRelay(clock);
  const one = dial(relay, 'THREE', { sprite: 'SPRITE_RED' });
  const two = dial(relay, 'FOUR', { sprite: 'SPRITE_RED' });
  one.peer.outbox = [];
  two.peer.outbox = [];

  relay.handle(one.id, { type: 'mmo.sprite', sprite: 'not a sprite!' });
  ok(relay.has(one.id) && relay.get(one.id).ready === true,
    'sanity: the connection is untouched by a malformed sprite id');
  ok(relay.get(one.id).sprite === 'SPRITE_RED'
    && take(one, 'mmo.sprite') === null && take(two, 'mmo.sprite') === null,
    'a bad sprite id costs the sender nothing but the message');

  // Neither does a value that never had a shot at being an id at all.
  relay.handle(one.id, { type: 'mmo.sprite', sprite: 123 });
  relay.handle(one.id, { type: 'mmo.sprite', sprite: '' });
  relay.handle(one.id, { type: 'mmo.sprite' });
  ok(relay.has(one.id) && relay.get(one.id).sprite === 'SPRITE_RED',
    'and neither does a missing, empty, or non-string value');
}

function testUnchangedSpriteIsNotRebroadcast() {
  const clock = makeClock();
  const relay = makeRelay(clock);
  const one = dial(relay, 'FIVE', { sprite: 'SPRITE_RED' });
  const two = dial(relay, 'SIX', { sprite: 'SPRITE_RED' });
  one.peer.outbox = [];
  two.peer.outbox = [];

  relay.handle(one.id, { type: 'mmo.sprite', sprite: 'SPRITE_RED' });
  ok(take(one, 'mmo.sprite') === null && take(two, 'mmo.sprite') === null,
    'an unchanged sprite is not rebroadcast');

  // ...and does not arm the gate against the very next real change, which is
  // why the no-op check runs before the gate check in the handler.
  relay.handle(one.id, { type: 'mmo.sprite', sprite: 'SPRITE_BLUE' });
  ok(relay.get(one.id).sprite === 'SPRITE_BLUE' && take(one, 'mmo.sprite') !== null,
    'a same-sprite resend does not arm the gate against the next real change');
}

// ----------------------------------------------------------------- the gate

function testGateKeepsOnlyTheFirstChange() {
  const clock = makeClock();
  const relay = makeRelay(clock);
  const one = dial(relay, 'SEVEN', { sprite: 'SPRITE_RED' });
  const two = dial(relay, 'EIGHT', { sprite: 'SPRITE_RED' });
  one.peer.outbox = [];
  two.peer.outbox = [];

  relay.handle(one.id, { type: 'mmo.sprite', sprite: 'SPRITE_BLUE' });
  ok(take(one, 'mmo.sprite') !== null, 'sanity: the first change goes through');
  two.peer.outbox = [];

  clock.advance(SPRITE_GATE_MS - 50);
  relay.handle(one.id, { type: 'mmo.sprite', sprite: 'SPRITE_GREEN' });
  ok(relay.get(one.id).sprite === 'SPRITE_BLUE'
    && take(one, 'mmo.sprite') === null && take(two, 'mmo.sprite') === null,
    'two changes inside the gate keep only the first');
}

function testChangeAfterTheGateOpensGoesThrough() {
  const clock = makeClock();
  const relay = makeRelay(clock);
  const one = dial(relay, 'NINE', { sprite: 'SPRITE_RED' });
  const two = dial(relay, 'TEN', { sprite: 'SPRITE_RED' });
  one.peer.outbox = [];
  two.peer.outbox = [];

  relay.handle(one.id, { type: 'mmo.sprite', sprite: 'SPRITE_BLUE' });
  take(one, 'mmo.sprite');
  take(two, 'mmo.sprite');

  clock.advance(SPRITE_GATE_MS + 10);
  relay.handle(one.id, { type: 'mmo.sprite', sprite: 'SPRITE_GREEN' });
  const heard = take(two, 'mmo.sprite');
  ok(relay.get(one.id).sprite === 'SPRITE_GREEN' && heard && heard.sprite === 'SPRITE_GREEN',
    'a change after the gate opens goes through');
}

// ------------------------------------------------------------------ ranking

function testImpostorCannotRepaintBoard() {
  const clock = makeClock();
  const relay = makeRelay(clock);
  const owner = dial(relay, 'ELEVEN', { sprite: 'SPRITE_RED' });
  ok(owner.welcome.ranked === true, 'sanity: a first hello under a free name is ranked');
  ok(relay.board.get('ELEVEN').sprite === 'SPRITE_RED',
    'sanity: the board learned the owner\'s hello sprite');

  const impostor = dial(relay, 'ELEVEN', { sprite: 'SPRITE_RED' });
  ok(impostor.welcome.ranked === false,
    'sanity: a second hello under a name that is live and ranked is an impostor');

  relay.handle(impostor.id, { type: 'mmo.sprite', sprite: 'SPRITE_GREEN' });
  ok(relay.get(impostor.id).sprite === 'SPRITE_GREEN',
    'sanity: the impostor\'s own presence still repaints -- only the board is guarded');
  ok(relay.board.get('ELEVEN').sprite === 'SPRITE_RED',
    'an impostor cannot repaint a ranked row\'s face');
}

function testRankedOwnerReseedsTheBoard() {
  const clock = makeClock();
  const relay = makeRelay(clock);
  const owner = dial(relay, 'TWELVE', { sprite: 'SPRITE_RED' });
  ok(owner.welcome.ranked === true, 'sanity: a first hello under a free name is ranked');
  ok(relay.board.get('TWELVE').sprite === 'SPRITE_RED',
    'sanity: the board learned the hello sprite');

  relay.handle(owner.id, { type: 'mmo.sprite', sprite: 'SPRITE_GREEN' });
  ok(relay.board.get('TWELVE').sprite === 'SPRITE_GREEN',
    'a ranked owner\'s change re-seeds the board\'s face');
}

/*
 * The announcement is not behind anything that can fail.
 *
 * Mirrors src/rby_mmo_test.lua's case of the same name, and pins the same
 * order for the same reason: the store at the top of the handler arms its own
 * no-op guard, so a throw between the store and the broadcast does not cost
 * one message -- it costs the session. The client re-sends the same id every
 * SPRITE_RETRY, each retry is eaten by `sprite === client.sprite`, and nobody
 * else in the game is ever told. The board is the call that could do it, so
 * the board goes last, and this drives it with one that throws.
 *
 * Worse on this hub than on the Lua one, which is why the case is worth
 * running on both: Relay.handle catches whatever a handler throws and writes
 * a line to its log. Nothing crashes, nothing disconnects, nobody is told --
 * the failure's only symptom would be one player's character never changing
 * for anyone else, for the rest of the session.
 */
function testABrokenBoardCannotSwallowTheAnnouncement() {
  const clock = makeClock();
  const relay = makeRelay(clock);
  const one = dial(relay, 'FOURTEEN', { sprite: 'SPRITE_RED' });
  const two = dial(relay, 'FIFTEEN', { sprite: 'SPRITE_RED' });
  ok(one.welcome.ranked === true,
    'sanity: the sender owns its name, so the board is in play');
  one.peer.outbox = [];
  two.peer.outbox = [];

  let reached = false;
  relay.board.seen = () => {
    reached = true;
    throw new Error('the board could not take that name');
  };

  relay.handle(one.id, { type: 'mmo.sprite', sprite: 'SPRITE_GREEN' });
  ok(reached, 'sanity: the board really was called, and really did throw');
  ok(take(two, 'mmo.sprite') !== null,
    'a board that fails does not cost everyone else the announcement');
  ok(take(one, 'mmo.sprite') !== null,
    'nor the sender their acknowledgement');
  ok(relay.get(one.id).sprite === 'SPRITE_GREEN',
    'and what the hub is holding is exactly what it announced -- never a '
    + 'value stored but never said, which the no-op guard would then eat '
    + 'every retry of');
}

// ------------------------------------------------------------------- guards

function testUngreetedClientCannotChangeSprite() {
  const clock = makeClock();
  const relay = makeRelay(clock);
  const bystander = dial(relay, 'THIRTEEN', { sprite: 'SPRITE_RED' });
  bystander.peer.outbox = [];
  const silent = connectSilently(relay);

  relay.handle(silent.id, { type: 'mmo.sprite', sprite: 'SPRITE_GREEN' });
  ok(relay.get(silent.id).ready === false, 'sanity: the connection never said hello');
  ok(relay.get(silent.id).sprite === DEFAULT_SPRITE,
    'a client that never said hello cannot change a sprite');
  ok(take(bystander, 'mmo.sprite') === null,
    'and nobody else hears about it either');
}

// -------------------------------------------------------- node-only: self-heal

/*
 * MOVE echoes `client.sprite` via presenceOf, and so does WELCOME's roster
 * snapshot -- so a joiner who arrives after the change is healed by the same
 * mechanism a joiner who missed the mmo.sprite broadcast entirely would be.
 * Node-only because it is the same claim T-A pins for src/Hub.lua's welcome
 * roster, but there is no shared string agreed for it -- it belongs to this
 * suite alone.
 */
function testLaterJoinerWelcomeCarriesTheChangedSprite() {
  const clock = makeClock();
  const relay = makeRelay(clock);
  const early = dial(relay, 'FOURTEEN', { sprite: 'SPRITE_RED' });
  relay.handle(early.id, { type: 'mmo.sprite', sprite: 'SPRITE_BLUE' });
  ok(relay.get(early.id).sprite === 'SPRITE_BLUE', 'sanity: the change landed');

  const late = dial(relay, 'FIFTEEN', { sprite: 'SPRITE_RED' });
  const row = late.welcome.players.find((p) => p.id === early.id);
  ok(row && row.sprite === 'SPRITE_BLUE',
    'a later joiner\'s welcome carries the changed sprite');
}

/*
 * Node-only: the protocol-mismatch refusal is built from `relay.protocol` --
 * which defaults to the imported `PROTOCOL` constant, not a number typed into
 * the handler -- so a bump to PROTOCOL changes what this message says without
 * anybody having to go find and edit a second copy of it.
 */
function testProtocolMismatchNamesBothVersionsFromTheConstant() {
  const clock = makeClock();
  const relay = makeRelay(clock);
  const silent = connectSilently(relay);
  const wrongProto = PROTOCOL - 1;

  relay.handle(silent.id, { type: 'mmo.hello', proto: wrongProto, name: 'SIXTEEN' });
  const refused = take(silent, 'mmo.error');
  ok(refused !== null, 'a protocol mismatch is refused');
  ok(refused.message.includes(String(PROTOCOL)),
    'the refusal names this hub\'s protocol, read from the imported PROTOCOL '
    + 'constant rather than a hardcoded number');
  ok(refused.message.includes(String(wrongProto)),
    'and it names the mismatched protocol the connecting client sent');

  // The same claim from the other direction: a Relay built with an explicit
  // `protocol` option (as lib/config.js can produce) refuses against *that*
  // number, not the module constant -- proof the message is not reading
  // PROTOCOL by accident while `relay.protocol` happens to equal it.
  const bumped = makeRelay(clock, { protocol: PROTOCOL + 1 });
  const other = connectSilently(bumped);
  bumped.handle(other.id, { type: 'mmo.hello', proto: PROTOCOL, name: 'SEVENTEEN' });
  const refusedAgain = take(other, 'mmo.error');
  ok(refusedAgain !== null && refusedAgain.message.includes(String(PROTOCOL + 1))
    && refusedAgain.message.includes(String(PROTOCOL)),
    'and it is relay.protocol, not the module constant, that the refusal quotes');
}

function main() {
  testStoresAndBroadcastsToEveryone();
  testBadSpriteIdCostsOnlyTheMessage();
  testUnchangedSpriteIsNotRebroadcast();
  testGateKeepsOnlyTheFirstChange();
  testChangeAfterTheGateOpensGoesThrough();
  testImpostorCannotRepaintBoard();
  testRankedOwnerReseedsTheBoard();
  testABrokenBoardCannotSwallowTheAnnouncement();
  testUngreetedClientCannotChangeSprite();
  testLaterJoinerWelcomeCarriesTheChangedSprite();
  testProtocolMismatchNamesBothVersionsFromTheConstant();

  console.log(`\n  ${passed}/${passed} checks passed  (sprite)\n`);
}

try {
  main();
} catch (err) {
  console.error('\n  ' + ((err && err.stack) || err) + '\n');
  process.exit(1);
}
