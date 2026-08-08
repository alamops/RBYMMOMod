#!/usr/bin/env node
'use strict';

/*
 * End-to-end test for the hub, over real TCP sockets.
 *
 * It starts hub.js as a child process on a scratch port and drives it with
 * two (and briefly three) clients speaking the same newline-JSON the mod
 * speaks. Nothing is stubbed: if the framing, the scope routing or the
 * session pairing is wrong, this fails.
 *
 * Run: node server/hub.test.js
 */

const net = require('net');
const { spawn } = require('child_process');
const path = require('path');
const assert = require('assert');

const PORT = 7801 + (process.pid % 200);
const HUB = path.join(__dirname, 'hub.js');
// Read from the relay rather than typed in, so a protocol bump is one edit
// in one file and not a hunt through two suites for the greeting that still
// says the old number.
const { PROTOCOL } = require('./lib/relay');

let passed = 0;
const ok = (cond, label) => {
  if (!cond) throw new Error('FAIL: ' + label);
  passed++;
};

class Client {
  constructor(port) {
    this.socket = net.createConnection({ port, host: '127.0.0.1' });
    this.socket.setEncoding('utf8');
    this.buffer = '';
    this.inbox = [];
    this.socket.on('data', (chunk) => {
      this.buffer += chunk;
      let i;
      while ((i = this.buffer.indexOf('\n')) >= 0) {
        const line = this.buffer.slice(0, i);
        this.buffer = this.buffer.slice(i + 1);
        if (line) this.inbox.push(JSON.parse(line));
      }
    });
  }
  ready() {
    return new Promise((resolve, reject) => {
      this.socket.once('connect', resolve);
      this.socket.once('error', reject);
    });
  }
  send(type, payload) {
    this.socket.write(JSON.stringify(Object.assign({}, payload, { type })) + '\n');
  }
  // wait for a message of `type`, or throw once the window closes
  async expect(type, timeoutMs = 1500) {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const index = this.inbox.findIndex((m) => m.type === type);
      if (index >= 0) return this.inbox.splice(index, 1)[0];
      await sleep(10);
    }
    throw new Error(`timed out waiting for ${type}; saw ` +
      JSON.stringify(this.inbox.map((m) => m.type)));
  }
  // assert nothing of this type shows up within the window
  async expectSilence(type, windowMs = 300) {
    const deadline = Date.now() + windowMs;
    while (Date.now() < deadline) {
      if (this.inbox.some((m) => m.type === type)) {
        throw new Error(`unexpectedly received ${type}`);
      }
      await sleep(10);
    }
    return true;
  }
  // Forget every queued message of a type, so the next expect() answers the
  // action about to be taken rather than one several steps back. Presence
  // needs this: mmo.move is broadcast by every session and party change, so
  // by the time a scenario cares about one field of it there are several
  // older ones in the inbox that would be found first.
  drain(type) {
    this.inbox = this.inbox.filter((m) => m.type !== type);
    return this;
  }
  close() { this.socket.destroy(); }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function startHub(port, env) {
  const hub = spawn(process.execPath, [HUB, String(port)],
    { stdio: 'pipe', env: Object.assign({}, process.env, env || {}) });
  hub.stderr.on('data', (d) => process.stderr.write('[hub] ' + d));

  // wait for the listening line before dialling in
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('hub never started')), 5000);
    hub.stdout.on('data', (d) => {
      if (String(d).includes('listening')) { clearTimeout(timer); resolve(); }
    });
  });
  return hub;
}

// The player cap is exercised on its own hub below. This one gets headroom
// so the functional scenario is testing chat and sessions rather than
// racing the limit: it briefly holds five sockets (three players plus two
// that are refused and dropped), and a reaped socket is not guaranteed to
// be out of the table before the next one dials in.
async function main() {
  const hub = await startHub(PORT, { RBY_MMO_MAX: '8' });

  try {
    // ------- handshake and roster

    const ann = new Client(PORT);
    await ann.ready();
    ann.send('mmo.hello', {
      proto: PROTOCOL, name: 'ANN', sprite: 'SPRITE_RED',
      map: 'PALLET', x: 5, y: 5, facing: 'down',
    });
    const annWelcome = await ann.expect('mmo.welcome');
    ok(typeof annWelcome.id === 'string', 'welcome carries an id');
    ok(annWelcome.players.length === 0, 'first player sees an empty roster');

    const bob = new Client(PORT);
    await bob.ready();
    bob.send('mmo.hello', {
      proto: PROTOCOL, name: 'BOB', sprite: 'SPRITE_BLUE',
      map: 'PALLET', x: 6, y: 5, facing: 'up',
    });
    const bobWelcome = await bob.expect('mmo.welcome');
    ok(bobWelcome.players.length === 1, 'second player sees the first');
    ok(bobWelcome.players[0].name === 'ANN', 'and by name');

    const joined = await ann.expect('mmo.join');
    ok(joined.player.name === 'BOB', 'the first player is told about the second');

    // ------- protocol gate

    const wrong = new Client(PORT);
    await wrong.ready();
    wrong.send('mmo.hello', { proto: 99, name: 'OLD' });
    const refused = await wrong.expect('mmo.error');
    ok(/protocol/i.test(refused.message), 'a version mismatch is refused clearly');
    wrong.close();

    // a name that sanitises to nothing cannot be used to join
    const nameless = new Client(PORT);
    await nameless.ready();
    nameless.send('mmo.hello', { proto: PROTOCOL, name: '\0\0' });
    await nameless.expect('mmo.error');
    ok(true, 'an unusable name is refused');
    nameless.close();

    // ------- movement

    bob.send('mmo.move', { map: 'PALLET', x: 7, y: 5, facing: 'right' });
    const moved = await ann.expect('mmo.move');
    ok(moved.x === 7 && moved.facing === 'right', 'movement is broadcast');
    ok(moved.id === bobWelcome.id, 'attributed to the right player');

    // leaving the world (a battle, a menu) keeps you on the roster but
    // takes away your cell
    bob.send('mmo.move', {});
    const gone = await ann.expect('mmo.move');
    ok(gone.map === null && gone.x === null, 'an absent cell clears position');
    bob.send('mmo.move', { map: 'PALLET', x: 7, y: 5, facing: 'right' });
    await ann.expect('mmo.move');

    // ------- pace
    //
    // Client-truth: only the sender knows whether B is held or a bike is
    // under them, so the hub's whole job is coercing whatever rides along
    // and relaying it -- the same whitelist-and-coerce shape as `party`
    // above. One flag for both, because a sprint and a bike are the same 8
    // frames a tile.

    bob.send('mmo.move', { map: 'PALLET', x: 8, y: 5, facing: 'right', fast: true });
    const sprinting = await ann.expect('mmo.move');
    ok(sprinting.fast === true, 'a fast move broadcasts fast: true');

    // the next move omits the field entirely -- an absent field is not a
    // literal true, so the strict rule reads it as walking, not "unchanged"
    bob.send('mmo.move', { map: 'PALLET', x: 9, y: 5, facing: 'right' });
    const walking = await ann.expect('mmo.move');
    ok(walking.fast === false, 'an absent field is broadcast as walking pace');

    // strict: only a literal boolean true is fast. A truthy junk value is
    // not trusted -- and it must not be, because the same bytes reaching the
    // in-game Lua hub have to produce the same broadcast, and Lua and JS
    // truthiness part ways on exactly this kind of value.
    bob.send('mmo.move', { map: 'PALLET', x: 10, y: 5, facing: 'right', fast: 'yes' });
    const junk = await ann.expect('mmo.move');
    ok(junk.fast === false, 'a junk value is never trusted as fast');
    ok(typeof junk.fast === 'boolean', 'and is never echoed back raw');

    // leave bob moving fast, so the welcome-roster snapshot below has
    // something to report
    bob.send('mmo.move', { map: 'PALLET', x: 10, y: 5, facing: 'right', fast: true });
    await ann.expect('mmo.move');

    // a fresh player's welcome roster is built from presenceOf same as any
    // broadcast, so a player already crossing the map fast should show it
    const dan = new Client(PORT);
    await dan.ready();
    dan.send('mmo.hello', { proto: PROTOCOL, name: 'DAN', map: 'PALLET', x: 1, y: 1 });
    const danWelcome = await dan.expect('mmo.welcome');
    const bobRow = danWelcome.players.find((p) => p.name === 'BOB');
    ok(!!bobRow, 'the roster snapshot includes the fast-moving player');
    ok(bobRow.fast === true, 'and its pace flag');
    dan.close();
    // consumed here, not left in ann's inbox, where the party teardown much
    // later expects the very next mmo.part to be CAL's departure
    const danParted = await ann.expect('mmo.part');
    ok(danParted.id === danWelcome.id, 'and DAN leaving the roster is its own event');

    // ------- chat scopes

    ann.send('mmo.chat', { scope: 'global', text: 'hello world' });
    const globalMsg = await bob.expect('mmo.chat');
    ok(globalMsg.text === 'hello world', 'global chat reaches everyone');
    ok(globalMsg.name === 'ANN', 'tagged with the sender');

    await sleep(600); // clear the flood gate
    ann.send('mmo.chat', { scope: 'local', text: 'nearby only' });
    const localMsg = await bob.expect('mmo.chat');
    ok(localMsg.scope === 'local', 'local chat reaches a nearby player');

    // move Bob far away on the same map: local must stop reaching him
    bob.send('mmo.move', { map: 'PALLET', x: 90, y: 90, facing: 'down' });
    await ann.expect('mmo.move');
    await sleep(600);
    ann.send('mmo.chat', { scope: 'local', text: 'still nearby?' });
    await bob.expectSilence('mmo.chat');
    ok(true, 'local chat does not reach a distant player');

    // ...but global still does
    await sleep(600);
    ann.send('mmo.chat', { scope: 'global', text: 'shout' });
    const shout = await bob.expect('mmo.chat');
    ok(shout.text === 'shout', 'global ignores distance');

    // whisper goes to exactly one person
    await sleep(600);
    ann.send('mmo.chat', { scope: 'private', to: bobWelcome.id, text: 'psst' });
    const whisper = await bob.expect('mmo.chat');
    ok(whisper.scope === 'private', 'a whisper arrives as private');

    // The flood gate actually gates -- and it is per sender, not per scope,
    // so the window has to be allowed to lapse after the whisper above
    // before this pair means anything.
    await sleep(600);
    ann.send('mmo.chat', { scope: 'global', text: 'spam one' });
    ann.send('mmo.chat', { scope: 'global', text: 'spam two' });
    await bob.expect('mmo.chat');
    await bob.expectSilence('mmo.chat', 250);
    ok(true, 'a second message inside the gate window is dropped');

    // ------- trade/battle request and session

    bob.send('mmo.move', { map: 'PALLET', x: 6, y: 5, facing: 'up' });
    await ann.expect('mmo.move');

    ann.send('mmo.request', { to: bobWelcome.id, kind: 'trade' });
    const request = await bob.expect('mmo.request');
    ok(request.kind === 'trade' && request.name === 'ANN', 'a request is forwarded');

    // a third party must not be able to answer on Bob's behalf
    const cal = new Client(PORT);
    await cal.ready();
    cal.send('mmo.hello', { proto: PROTOCOL, name: 'CAL', map: 'PALLET', x: 1, y: 1 });
    const calWelcome = await cal.expect('mmo.welcome');
    cal.send('mmo.respond', { to: annWelcome.id, kind: 'trade', accept: true });
    await ann.expectSilence('mmo.session');
    ok(true, 'only the player who was asked can accept');

    bob.send('mmo.respond', { to: annWelcome.id, kind: 'trade', accept: true });
    const annSession = await ann.expect('mmo.session');
    const bobSession = await bob.expect('mmo.session');
    ok(annSession.role === 'host', 'the asker hosts');
    ok(bobSession.role === 'guest', 'the answerer joins');
    ok(annSession.id === bobSession.id, 'both sides share a session id');
    ok(annSession.peer === bobWelcome.id, 'and know who they are paired with');

    // ------- relay carries the engine's own vocabulary untouched

    ann.send('mmo.relay', {
      to: bobWelcome.id,
      payload: { type: 'party', mons: [{ species: 'PIKACHU', level: 5 }] },
    });
    const relayed = await bob.expect('mmo.relay');
    ok(relayed.payload.type === 'party', 'the payload type survives');
    ok(relayed.payload.mons[0].species === 'PIKACHU', 'and its contents');
    ok(relayed.from === annWelcome.id, 'stamped with the sender');

    // a relay aimed at a real player you are not paired with goes nowhere
    ann.send('mmo.relay', { to: calWelcome.id, payload: { type: 'party' } });
    await cal.expectSilence('mmo.relay');
    ok(true, 'a relay outside your session is refused');

    // busy players cannot be pulled into a second session
    cal.send('mmo.request', { to: bobWelcome.id, kind: 'battle' });
    const declined = await cal.expect('mmo.decline');
    ok(declined.name === 'BOB', 'a busy player auto-declines');

    // ------- teardown of the live session, then cancel an unanswered ask
    //
    // The asker takes a fresh request back before Bob answers. pendingTo
    // clears on the hub, Bob is told, and a late accept must not open a
    // session.

    ann.send('mmo.session_leave', {});
    const ended = await bob.expect('mmo.session_end');
    ok(ended.reason === 'peer_left', 'leaving ends the session for both');

    ann.send('mmo.request', { to: bobWelcome.id, kind: 'battle' });
    const battleAsk = await bob.expect('mmo.request');
    ok(battleAsk.kind === 'battle' && battleAsk.name === 'ANN',
      'a battle request is forwarded');

    ann.send('mmo.request_cancel', {});
    const cancelled = await bob.expect('mmo.request_cancel');
    ok(cancelled.from === annWelcome.id, 'cancel names the asker');
    ok(cancelled.name === 'ANN', 'by the nick on their connection');

    bob.send('mmo.respond', { to: annWelcome.id, kind: 'battle', accept: true });
    await ann.expectSilence('mmo.session');
    ok(true, 'accepting a cancelled ask starts no session');

    // ------- parties
    //
    // The same behaviours src/Hub.lua's own party section pins on the Lua
    // side. Two implementations of one protocol only stay honest if both are
    // tested, and this half is the one a dedicated hub actually runs.

    cal.drain('mmo.move');
    ann.send('mmo.party_invite', { to: bobWelcome.id });
    const invite = await bob.expect('mmo.party_invite');
    ok(invite.name === 'ANN', 'an invite is forwarded with the asker on it');
    ok(invite.from === annWelcome.id, 'and an id to answer to');

    // only the player who was asked may answer it
    cal.send('mmo.party_respond', { to: annWelcome.id, accept: true });
    await ann.expectSilence('mmo.party');
    ok(true, 'a third party cannot accept an invite for somebody else');

    bob.send('mmo.party_respond', { to: annWelcome.id, accept: true });
    const annParty = await ann.expect('mmo.party');
    const bobParty = await bob.expect('mmo.party');
    ok(annParty.id === bobParty.id, 'accepting forms one party for both');
    ok(annParty.members.length === 2, 'carrying the whole membership');
    ok(annParty.members.some((m) => m.name === 'BOB'), 'by name');

    // everyone else is told, because the flag is what gates their INVITE row
    const flagged = await cal.expect('mmo.move');
    ok(flagged.party === true, 'the rest of the hub sees them as spoken for');

    // somebody already in a party is refused before a prompt is ever shown
    cal.send('mmo.party_invite', { to: bobWelcome.id });
    const taken = await cal.expect('mmo.party_decline');
    ok(taken.reason === 'in_party', 'inviting a taken player is declined at once');
    await bob.expectSilence('mmo.party_invite');
    ok(true, 'and never reaches them');

    // party chat reaches the party and stops there
    ann.send('mmo.chat', { scope: 'party', text: 'this way' });
    const partyLine = await bob.expect('mmo.chat');
    ok(partyLine.scope === 'party', 'a party line reaches the other member');
    await cal.expectSilence('mmo.chat');
    ok(true, 'and nobody outside the party');

    // a party line from somebody with no party is dropped, never widened
    cal.send('mmo.chat', { scope: 'party', text: 'anyone?' });
    await ann.expectSilence('mmo.chat');
    ok(true, 'party chat with no party goes nowhere at all');

    // ------- party events
    //
    // What just happened to a travelling partner -- a wild POKeMON beaten,
    // here -- fanned out to the party and stopping there. `name` is the field
    // a forged client would most want to control, since it is the only
    // identity on the message and the whole thing is read as a sentence about
    // a named player, so it is stamped from the connection and never off the
    // wire: ANN's message below carries a different name and BOB must never
    // see it.

    ann.send('mmo.party_event',
      { kind: 'defeat_wild', species: 'RATTATA', level: 3, name: 'NOTANN' });
    const partyEvent = await bob.expect('mmo.party_event');
    ok(partyEvent.kind === 'defeat_wild', 'the event kind survives the trip');
    ok(partyEvent.species === 'RATTATA' && partyEvent.level === 3,
       'and the mon it names');
    ok(partyEvent.name === 'ANN', "stamped from ANN's own connection");
    ok(partyEvent.name !== 'NOTANN',
       'never the forged name the message carried');

    // the fighter watched their own battle happen and needs no round trip
    await ann.expectSilence('mmo.party_event');
    ok(true, 'the sender is not sent a copy of their own event');

    // a player with no party cannot make an event appear on anybody's screen
    cal.send('mmo.party_event',
      { kind: 'defeat_wild', species: 'PIDGEY', level: 2 });
    await bob.expectSilence('mmo.party_event');
    await ann.expectSilence('mmo.party_event');
    ok(true, 'party_event with no party goes nowhere at all -- the hub drops it');

    // leaving ends it for both, and frees them in everyone else's eyes
    cal.drain('mmo.move');
    ann.send('mmo.party_leave', {});
    const bobEnd = await bob.expect('mmo.party_end');
    ok(bobEnd.reason === 'peer_left', 'leaving ends the party for the other');
    const annEnd = await ann.expect('mmo.party_end');
    ok(annEnd.reason === 'left', 'and the leaver is told, so a client converges');
    const freed = await cal.expect('mmo.move');
    ok(freed.party === false, 'everyone sees them free to be asked again');

    // ------- co-op battles
    //
    // The rules here are the same ones src/Hub.lua's suite asserts, driven
    // over real sockets against the Node hub -- because "both hosting paths
    // behave identically" is a claim about two implementations, and only
    // testing each of them separately can support it.
    //
    // The scenario above ends by dissolving ANN and BOB's party, so it is
    // formed again here rather than assumed -- an offer is only ever forwarded
    // inside a party, and a co-op block running against no party would pass
    // its silence checks for entirely the wrong reason.
    ann.send('mmo.party_invite', { to: bobWelcome.id });
    await bob.expect('mmo.party_invite');
    bob.send('mmo.party_respond', { to: annWelcome.id, accept: true });
    await ann.expect('mmo.party');
    await bob.expect('mmo.party');
    ok(true, 'ANN and BOB team up again for the co-op scenario');

    const FIGHT = 'PALLET|OPP_BUG_CATCHER|1';

    ann.send('mmo.coop_wait',
      { battle: FIGHT, label: 'BUG CATCHER', map: 'PALLET' });
    const offer = await bob.expect('mmo.coop_offer');
    ok(offer.battle === FIGHT, 'an offer reaches the partner, keyed to the fight');
    ok(offer.from === annWelcome.id, 'naming who is waiting');
    ok(offer.label === 'BUG CATCHER',
       'with the trainer name intact -- not cut to a player name length');
    await cal.expectSilence('mmo.coop_offer');
    ok(true, 'and reaches nobody outside the party');

    // a join for a *different* fight is not this fight
    bob.send('mmo.coop_join', { to: annWelcome.id, battle: 'PALLET|OPP_LASS|2' });
    await ann.expectSilence('mmo.coop_joined');
    ok(true, 'joining names the fight, and the wrong one is refused');

    // ...and somebody outside the party cannot take it at all
    cal.send('mmo.coop_join', { to: annWelcome.id, battle: FIGHT });
    await ann.expectSilence('mmo.coop_joined');
    ok(true, 'nor can a player outside the party join their fight');

    bob.send('mmo.coop_join', { to: annWelcome.id, battle: FIGHT });
    const joinerPlan = await bob.expect('mmo.coop_battle');
    ok(joinerPlan.allies.length === 2, 'the joiner is handed both allies');
    const told = await ann.expect('mmo.coop_joined');
    ok(told.id === bobWelcome.id, 'and the waiting player learns who joined');

    // the offer is spent: a second join finds nothing left to take
    bob.send('mmo.coop_join', { to: annWelcome.id, battle: FIGHT });
    await ann.expectSilence('mmo.coop_joined');
    ok(true, 'an offer is taken exactly once');

    // withdrawing tells the partner, with a reason they can act on
    ann.send('mmo.coop_wait', { battle: FIGHT, label: 'BUG CATCHER' });
    await bob.expect('mmo.coop_offer');
    ann.send('mmo.coop_cancel', { reason: 'alone' });
    const withdrawn = await bob.expect('mmo.coop_offer_end');
    ok(withdrawn.reason === 'alone',
       'withdrawing says whether they went in alone or walked away');

    // a challenge against somebody with no party forms nothing
    ann.send('mmo.coop_challenge', { to: calWelcome.id });
    await cal.expectSilence('mmo.coop_ask');
    ok(true, 'a party cannot challenge a player who has none');

    // ...and the offer dies with the party rather than outliving it
    ann.send('mmo.coop_wait', { battle: FIGHT, label: 'BUG CATCHER' });
    await bob.expect('mmo.coop_offer');
    ann.send('mmo.party_leave', {});
    const orphaned = await bob.expect('mmo.coop_offer_end');
    ok(orphaned.reason === 'gone',
       'the party ending takes the standing offer down with it');
    await ann.expect('mmo.party_end');
    await bob.expect('mmo.party_end');
    // ANN has to be unattached again for the scenario below, which is about
    // a party formed with CAL and then dropped.
    ann.drain('mmo.move');

    // a party does not survive the connection that made it
    ann.send('mmo.party_invite', { to: calWelcome.id });
    await cal.expect('mmo.party_invite');
    cal.send('mmo.party_respond', { to: annWelcome.id, accept: true });
    await cal.expect('mmo.party');
    cal.close();
    const dropEnd = await ann.expect('mmo.party_end');
    ok(dropEnd.reason === 'peer_left', 'a member disconnecting ends the party');
    // ...and consumed here rather than left in the inbox, where the teardown
    // below would find CAL's departure and read it as BOB's
    const calParted = await ann.expect('mmo.part');
    ok(calParted.id === calWelcome.id, 'and drops them from the roster');

    bob.close();
    const parted = await ann.expect('mmo.part');
    ok(parted.id === bobWelcome.id, 'a dropped socket removes the player');

    ann.close();
    cal.close();
  } finally {
    hub.kill('SIGTERM');
  }

  await capTest();
  await clampTest();
  await coopRelayTest();
  await coopRankTest();
  coopRankMathTest();
  console.log(`\n  ${passed}/${passed} checks passed  (hub)\n`);
}

// ------- an out-of-range env value is clamped, not obeyed

async function clampTest() {
  const port = PORT + 2;
  const hub = await startHub(port, { RBY_MMO_MAX: '1' }); // below the floor
  const joined = [];
  try {
    for (let i = 0; i < 2; i++) {
      const player = new Client(port);
      await player.ready();
      player.send('mmo.hello', { proto: PROTOCOL, name: 'C' + i });
      await player.expect('mmo.welcome');
      joined.push(player);
    }
    ok(joined.length === 2, 'a sub-floor limit is raised to two players');

    const third = new Client(port);
    await third.ready();
    const refused = await third.expect('mmo.error');
    ok(/2 players/.test(refused.message), 'and the clamped value is enforced');
    third.close();
  } finally {
    for (const player of joined) player.close();
    hub.kill('SIGTERM');
  }
}

// ------- the shipped default: four players, and the fifth is turned away

async function capTest() {
  const hub = await startHub(PORT + 1); // no RBY_MMO_MAX: the real default
  const joined = [];
  try {
    for (let i = 0; i < 4; i++) {
      const player = new Client(PORT + 1);
      await player.ready();
      player.send('mmo.hello', {
        proto: PROTOCOL, name: 'P' + i, map: 'PALLET', x: i, y: 1, facing: 'down',
      });
      await player.expect('mmo.welcome');
      joined.push(player);
    }
    ok(joined.length === 4, 'four players fit on a default hub');

    // drop the joins P0 collected while the room filled, so the silence
    // check below is about the fifth player and not about them
    joined[0].inbox.length = 0;

    const fifth = new Client(PORT + 1);
    await fifth.ready();
    const refused = await fifth.expect('mmo.error');
    ok(/full/i.test(refused.message), 'the fifth player is refused');
    ok(/4/.test(refused.message), 'and the message names the limit');

    // refusal happens on connect, before hello, so nobody already playing
    // hears about it
    await joined[0].expectSilence('mmo.join');
    ok(true, 'a refused connection never joins the roster');
    fifth.close();

    // and the seat frees up again when someone leaves
    joined[3].close();
    await sleep(200);
    const late = new Client(PORT + 1);
    await late.ready();
    late.send('mmo.hello', { proto: PROTOCOL, name: 'LATE', map: 'PALLET', x: 9, y: 9 });
    await late.expect('mmo.welcome');
    ok(true, 'a freed seat lets the next player in');
    late.close();
  } finally {
    for (const player of joined) player.close();
    hub.kill('SIGTERM');
  }
}

// ------- mmo.coop_relay: who a co-op battle's traffic reaches
//
// The whole of a 2-on-2 rides this one message. The hub never reads a byte of
// it -- it is the mod's own battle vocabulary and interpreting it here would
// couple the server to a protocol the game owns -- so the only thing the hub
// is responsible for is *routing*, and routing is exactly what this asserts.
//
// It matters more than a fan-out usually would. `mmo.relay` has one correct
// destination and gets it wrong loudly; this one has three, and every way of
// getting it wrong is quiet. Forward to too few and one player's screen
// silently stops matching the battle. Forward to too many and somebody outside
// the fight is fed turns for a battle they are not in. Echo it back to the
// sender and every client applies its own turn twice. None of those close a
// socket or log an error.
//
// Driven the long way round -- two real parties, a real four-way ask, real
// agreement -- because the group this fans out to is built by that flow, and a
// group assembled by hand would be a test of a table rather than of the hub.

async function coopRelayTest() {
  // Its own port and its own hub: this one needs five players at once, and
  // borrowing the functional hub would leave four of them mid-battle for
  // whatever ran next. PORT + 2 belongs to clampTest.
  const port = PORT + 3;
  const hub = await startHub(port, { RBY_MMO_MAX: '8' });
  const clients = [];

  const join = async (name) => {
    const client = new Client(port);
    await client.ready();
    client.send('mmo.hello', {
      proto: PROTOCOL, name, sprite: 'SPRITE_RED',
      map: 'PALLET', x: 5, y: 5, facing: 'down',
    });
    client.id = (await client.expect('mmo.welcome')).id;
    client.label = name;
    clients.push(client);
    return client;
  };

  const party = async (asker, invitee) => {
    asker.send('mmo.party_invite', { to: invitee.id });
    await invitee.expect('mmo.party_invite');
    invitee.send('mmo.party_respond', { to: asker.id, accept: true });
    await asker.expect('mmo.party');
    await invitee.expect('mmo.party');
  };

  try {
    const ann = await join('ANN');
    const bob = await join('BOB');
    const cal = await join('CAL');
    const dee = await join('DEE');
    // Connected, on the roster, and in nothing. Present for one assertion and
    // it is the one a fan-out bug is most likely to fail: a battle's traffic
    // must not reach somebody who is merely online.
    const eve = await join('EVE');

    await party(ann, bob);
    await party(cal, dee);
    ok(true, 'two parties of two form on one hub');

    // ------- the four-way ask, over sockets

    ann.send('mmo.coop_challenge', { to: cal.id });
    const asked = await bob.expect('mmo.coop_ask');
    ok(asked.name === 'ANN', 'the ask names who wants the battle');
    ok(asked.side === 'a', "and tells a partner they are on the asker's side");
    const askedCal = await cal.expect('mmo.coop_ask');
    ok(askedCal.side === 'b', 'and tells the other party they are the other side');
    await dee.expect('mmo.coop_ask');
    await ann.expectSilence('mmo.coop_ask');
    ok(true, 'the player who asked is not asked again');
    await eve.expectSilence('mmo.coop_ask');
    ok(true, 'and nobody outside the two parties is asked at all');

    for (const member of [bob, cal, dee]) {
      member.send('mmo.coop_answer', { id: asked.id, accept: true });
    }

    const started = await ann.expect('mmo.coop_battle');
    ok(started.side === 'a', 'the asker is on side a');
    ok(started.host === ann.id, 'and is named as the client that simulates');
    const calStarted = await cal.expect('mmo.coop_battle');
    ok(calStarted.side === 'b', 'the challenged party is side b');
    ok(calStarted.allies.length === 2 && calStarted.foes.length === 2,
       'and each side is handed two allies and two foes');
    await bob.expect('mmo.coop_battle');
    await dee.expect('mmo.coop_battle');
    await eve.expectSilence('mmo.coop_battle');
    ok(true, 'four agreements start one battle, for exactly those four');

    // ------- the fan-out itself

    const turn = { t: 'res', seq: 1, sig: '1:1:90:0|2:1:90:0', events: [
      { kind: 'msg', text: 'ANN used TACKLE!' },
      { kind: 'damage', slot: 3, amount: 12, hp: 78 },
    ] };
    ann.send('mmo.coop_relay', { payload: turn });

    for (const member of [bob, cal, dee]) {
      const got = await member.expect('mmo.coop_msg');
      ok(got.from === ann.id, `${member.label} is told who sent the turn`);
      // Deep-compared rather than spot-checked: the hub forwards the payload
      // unread, so "unread" is the claim, and a hub that rebuilt the object --
      // dropping a field it did not recognise, coercing a number -- would pass
      // any check that only looked at the parts this test happened to name.
      assert.deepStrictEqual(got.payload, turn,
        'the payload is forwarded byte for byte');
      passed++;
    }
    ok(true, 'a turn reaches all three of the other players');

    await ann.expectSilence('mmo.coop_msg');
    ok(true, 'and never comes back to the client that sent it');
    await eve.expectSilence('mmo.coop_msg');
    ok(true, 'and never reaches a player who is not in the battle');

    // Every member is a sender, not just the host: a replayer asks for the
    // field, a player files an action, somebody forfeits.
    dee.send('mmo.coop_relay', { payload: { t: 'resync' } });
    const asking = await ann.expect('mmo.coop_msg');
    ok(asking.from === dee.id && asking.payload.t === 'resync',
       'the fan-out is symmetric -- any member can reach the other three');
    await bob.expect('mmo.coop_msg');
    await cal.expect('mmo.coop_msg');
    ok(true, 'including across the party line, in both directions');

    // ------- what is refused

    eve.send('mmo.coop_relay', { payload: { t: 'res', seq: 99 } });
    for (const member of [ann, bob, cal, dee]) {
      await member.expectSilence('mmo.coop_msg', 150);
    }
    ok(true, 'a player in no battle cannot inject a turn into one');

    // A payload deeper than the cap. Not a malicious client so much as a
    // broken one, and the hub must drop it rather than forward something it
    // has not been able to judge the shape of.
    let deep = { end: true };
    for (let i = 0; i < 40; i++) deep = { next: deep };
    ann.send('mmo.coop_relay', { payload: deep });
    for (const member of [bob, cal, dee]) {
      await member.expectSilence('mmo.coop_msg', 150);
    }
    ok(true, 'a payload deeper than the cap is dropped, not forwarded');

    // ...and the connection survives it: a dropped payload is a dropped
    // payload, not a dropped player.
    ann.send('mmo.coop_relay', { payload: { t: 'res', seq: 2 } });
    const after = await bob.expect('mmo.coop_msg');
    ok(after.payload.seq === 2,
       'and the sender is still in the battle afterwards');
    bob.drain('mmo.coop_msg');
    cal.drain('mmo.coop_msg');
    dee.drain('mmo.coop_msg');

    // ------- and the group closes for everybody at once

    dee.send('mmo.coop_leave', {});
    await sleep(150);
    ann.send('mmo.coop_relay', { payload: { t: 'res', seq: 3 } });
    for (const member of [bob, cal, dee]) {
      await member.expectSilence('mmo.coop_msg', 150);
    }
    ok(true, 'one goodbye closes the group -- a co-op battle ends for all four');

    // ...and it really is closed rather than merely quiet: the same four can
    // agree to a new one, which they could not do while still marked as being
    // in a battle.
    ann.send('mmo.coop_challenge', { to: cal.id });
    const again = await bob.expect('mmo.coop_ask');
    ok(again.id !== asked.id, 'and the four can start a fresh battle afterwards');

    // ------- the other way a group is made: two players against an NPC
    //
    // A pair that agreed by walking up to each other gets a fan-out group on
    // exactly the same footing as a four-player one. That is the point of
    // there being one routing rule, and it is worth checking rather than
    // assuming, because the two flows build the group in different places.
    for (const member of [bob, cal, dee]) {
      member.send('mmo.coop_answer', { id: again.id, accept: false });
    }
    await sleep(150);
    for (const member of [ann, bob, cal, dee, eve]) member.drain('mmo.coop_msg');

    ann.send('mmo.coop_wait', { battle: 'PALLET:7', label: 'BUG CATCHER',
                                map: 'PALLET' });
    const offer = await bob.expect('mmo.coop_offer');
    ok(offer.battle === 'PALLET:7', 'a partner is offered the fight by key');

    // The key is not free-form: `#` is outside the charset cleanBattleKey
    // accepts, and a key it rejects means no offer at all rather than an offer
    // nobody can match. Worth pinning, because the failure is silence.
    ann.send('mmo.coop_wait', { battle: 'PALLET#8', map: 'PALLET' });
    await bob.expectSilence('mmo.coop_offer', 150);
    ok(true, 'a battle key outside the accepted charset offers nothing');
    bob.send('mmo.coop_join', { to: ann.id, battle: 'PALLET:7' });
    await ann.expect('mmo.coop_joined');
    await bob.expect('mmo.coop_battle');

    ann.send('mmo.coop_relay', { payload: { t: 'res', seq: 1 } });
    const pairMsg = await bob.expect('mmo.coop_msg');
    ok(pairMsg.from === ann.id, 'a two-player group fans out the same way');
    for (const member of [cal, dee, eve]) {
      await member.expectSilence('mmo.coop_msg', 150);
    }
    ok(true, 'and reaches nobody outside the pair');
  } finally {
    for (const client of clients) client.close();
    hub.kill('SIGTERM');
  }
}

// ------- a 2-on-2 is rated as a team battle, and scored over real sockets
//
// The hub used to pair a four-way off by slot index -- first against first,
// second against second -- which reused the 1v1 machinery unchanged and was
// arbitrary in the way that matters: nothing about a four-way says who fought
// whom. Both players attack both opponents, a move redirects across the pair
// when a target falls, and the side loses together. It is one team match, and
// this drives it end to end: four players agree, fight, report, and are rated.

async function coopRankTest() {
  const port = PORT + 4;
  const hub = await startHub(port, { RBY_MMO_MAX: '8' });
  const clients = [];

  const join = async (name) => {
    const client = new Client(port);
    await client.ready();
    client.send('mmo.hello', {
      proto: PROTOCOL, name, sprite: 'SPRITE_RED',
      map: 'PALLET', x: 5, y: 5, facing: 'down',
    });
    client.id = (await client.expect('mmo.welcome')).id;
    client.label = name;
    clients.push(client);
    return client;
  };
  const party = async (asker, invitee) => {
    asker.send('mmo.party_invite', { to: invitee.id });
    await invitee.expect('mmo.party_invite');
    invitee.send('mmo.party_respond', { to: asker.id, accept: true });
    await asker.expect('mmo.party');
    await invitee.expect('mmo.party');
  };

  try {
    const ann = await join('ANN');
    const bob = await join('BOB');
    const cal = await join('CAL');
    const dee = await join('DEE');
    await party(ann, bob);
    await party(cal, dee);

    ann.send('mmo.coop_challenge', { to: cal.id });
    const ask = await bob.expect('mmo.coop_ask');
    await cal.expect('mmo.coop_ask');
    await dee.expect('mmo.coop_ask');
    for (const member of [bob, cal, dee]) {
      member.send('mmo.coop_answer', { id: ask.id, accept: true });
    }
    const battle = await ann.expect('mmo.coop_battle');
    for (const member of [bob, cal, dee]) await member.expect('mmo.coop_battle');
    for (const member of [ann, bob, cal, dee]) member.drain('mmo.rank');

    // Three reports settle nothing: a four-way has one result, and it is not
    // one until all four have said the same thing about it.
    ann.send('mmo.result', { session: battle.id, outcome: 'win' });
    bob.send('mmo.result', { session: battle.id, outcome: 'win' });
    cal.send('mmo.result', { session: battle.id, outcome: 'loss' });
    await ann.expectSilence('mmo.rank', 300);
    ok(true, 'three reports out of four score nothing');

    dee.send('mmo.result', { session: battle.id, outcome: 'loss' });

    // Four ratings moved, so four announcements go out -- a hub that told the
    // winners and left the losers' screens stale would be wrong on two of the
    // four machines.
    const scores = new Map();
    const deadline = Date.now() + 2000;
    while (scores.size < 4 && Date.now() < deadline) {
      const row = await ann.expect('mmo.rank');
      scores.set(row.id, row.points);
    }
    ok(scores.size === 4, 'all four ratings are published, not just the winners');
    ok(scores.get(ann.id) > 0 && scores.get(bob.id) > 0,
       'both winners gained points');
    ok(scores.get(ann.id) === scores.get(bob.id),
       'team-mates who went in level come out level -- one team, one result');
    ok(scores.get(cal.id) === scores.get(dee.id),
       'and so do the two who lost');
    ok(scores.get(cal.id) < scores.get(ann.id), 'the losing side is below the winning one');

    // Reported again, and it is over: one battle, one settlement.
    ann.drain('mmo.rank');
    ann.send('mmo.result', { session: battle.id, outcome: 'win' });
    await ann.expectSilence('mmo.rank', 300);
    ok(true, 'a late report after settlement pays nothing');
  } finally {
    for (const client of clients) client.close();
    hub.kill('SIGTERM');
  }
}

// ------- ...and the arithmetic underneath it, without the sockets
//
// The claim the socket test cannot make cheaply: that the *order the hub
// listed the four players in* changes nothing. That is the whole of what was
// wrong with pairing by slot, and it only shows up with a lopsided side --
// under slot pairing, whether the strong player faced the strong or the weak
// opponent decided what the battle was worth.

function coopRankMathTest() {
  const { Board, teamPoints } = require('./lib/rank');

  // The two opponents must be *differently* rated and only one side's order
  // may change, or slot pairing would happen to match the same people up
  // anyway and the test would pass under the design it is supposed to reject.
  // Under slot pairing this exact swap moved three of the four ratings.
  const NAMES = ['STRONG', 'WEAK', 'RIVAL', 'ROOKIE'];
  const played = (winners, losers) => {
    const board = new Board();
    for (let i = 0; i < 6; i += 1) board.record('STRONG', 'PADDING', 0);
    for (let i = 0; i < 3; i += 1) board.record('RIVAL', 'PADDING2', 0);
    board.recordTeam(winners, losers, 500);
    const out = {};
    for (const name of NAMES) out[name] = board.points(name);
    return out;
  };
  assert.deepStrictEqual(
    played(['STRONG', 'WEAK'], ['ROOKIE', 'RIVAL']),
    played(['STRONG', 'WEAK'], ['RIVAL', 'ROOKIE']),
    'the seat a player is listed in changes no rating at all');
  passed++;

  // The side's strength is the pair's, not one member's.
  const carried = new Board();
  for (let i = 0; i < 4; i += 1) carried.record('CARRY', 'FODDER', 0);
  const beatCarried = carried.recordTeam(['R1', 'R2'], ['CARRY', 'FODDER'], 100);
  const beatUnknowns = new Board().recordTeam(['R1', 'R2'], ['P1', 'P2'], 100);
  ok(beatCarried.loserSide > beatUnknowns.loserSide,
     'a pair carrying a rated player is worth more than a pair of unknowns');
  ok(beatCarried.winners[0].gained > beatUnknowns.winners[0].gained,
     'and beating them pays more');

  // Farming a 2-on-2 is discounted exactly as farming a 1v1 is.
  const afternoon = new Board();
  const paid = [];
  for (let i = 1; i <= 5; i += 1) {
    paid.push(afternoon.recordTeam(['P1', 'P2'], ['P3', 'P4'], 10 * i)
      .winners[0].gained);
  }
  ok(paid[0] > 0 && paid[1] < paid[0] && paid[4] === 0,
     'running the same party battle all afternoon stops paying');

  // ...and one new face makes it worth playing again.
  const fresh = new Board();
  for (let i = 0; i < 3; i += 1) fresh.recordTeam(['R1', 'R2'], ['R3', 'R4'], 0);
  const stale = fresh.recordTeam(['R1', 'R2'], ['R3', 'R4'], 1);
  const newcomer = fresh.recordTeam(['R1', 'R2'], ['R3', 'NEWBIE'], 2);
  ok(newcomer.winners[0].gained > stale.winners[0].gained,
     'a new opponent on the other side is not somebody you have been farming');

  ok(new Board().recordTeam(['X', 'Y'], ['Y', 'Z'], 0) === null,
     'a player on both sides is not a battle between four people');
  ok(new Board().recordTeam(['X', 'X'], ['Y', 'Z'], 0) === null,
     'and neither is the same name twice on one side');
  ok(new Board().recordTeam([], ['Y', 'Z'], 0) === null, 'an empty side is not a side');
  ok(teamPoints([{ points: 100 }, { points: 200 }]) === 150,
     'a side is worth the average of its members');
  ok(teamPoints([]) === 0, 'and an empty one is worth nothing');
}

main().catch((err) => {
  console.error('\n  ' + err.message + '\n');
  process.exit(1);
});
