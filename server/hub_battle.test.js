#!/usr/bin/env node
'use strict';

/*
 * Mediated battles on the Node hub (PROTOCOL 10).
 *
 * Pins the path the plan names for Wave 2: two dialed clients open a battle
 * session, upload a ruleset and parties, exchange choices, and receive a
 * single mmo.battle_outcome from the intermediator -- with no mmo.relay
 * lockstep and no dual mmo.result vote.
 *
 * Socket-free: Relay talks to peer handles, same idiom as sprite.test.js /
 * rank.test.js.
 *
 * Run: node server/hub_battle.test.js
 */

const { Relay, PROTOCOL, DEFAULT_SPRITE } = require('./lib/relay.js');
const { createLog } = require('./lib/log.js');

let passed = 0;
const ok = (cond, label) => {
  if (!cond) throw new Error('FAIL: ' + label);
  passed++;
};

const quiet = createLog({ level: 'error' });

function makeClock(start = 1_000_000) {
  let t = start;
  return { now: () => t, advance(ms) { t += ms; } };
}

function makeRelay(clock, opts) {
  const relay = new Relay(Object.assign(
    { maxPlayers: 8, log: quiet, now: clock.now }, opts || {}));
  // The seed is the intermediator's, so a suite that wants a reproducible fight
  // asks the relay rather than sending one in a ruleset -- which is exactly the
  // thing tryStartSim now refuses to read.
  relay.forceBattleSeed = 1;
  return relay;
}

function testPlayerId(seed) {
  const crypto = require('node:crypto');
  return crypto.createHash('sha256').update(String(seed)).digest('hex').slice(0, 32);
}

function dial(relay, name, opts) {
  const o = opts || {};
  const peer = { outbox: [], remoteAddress: '127.0.0.1' };
  peer.send = (msg) => peer.outbox.push(msg);
  peer.close = () => {};
  const id = relay.accept(peer);
  const playerId = o.playerId || testPlayerId(name);
  relay.handle(id, {
    type: 'mmo.hello',
    proto: PROTOCOL,
    name,
    sprite: o.sprite || DEFAULT_SPRITE,
    map: o.map === undefined ? 'PALLET' : o.map,
    x: o.x === undefined ? 1 : o.x,
    y: o.y === undefined ? 1 : o.y,
    facing: 'down',
    playerId,
  });
  // Wire id is the persistent playerId; ephemeral accept id still routes handle().
  return { id: playerId, peer, name, ephemeralId: id };
}

function take(player, type) {
  const index = player.peer.outbox.findIndex((m) => m.type === type);
  if (index < 0) return null;
  return player.peer.outbox.splice(index, 1)[0];
}

function takeAll(player, type) {
  const out = [];
  for (;;) {
    const msg = take(player, type);
    if (!msg) return out;
    out.push(msg);
  }
}

function mon(power, hp) {
  return {
    species: 'MONA',
    level: 50,
    hp: hp === undefined ? 100 : hp,
    maxHp: 100,
    stats: { atk: 120, def: 40, spd: 80, spc: 80 },
    moves: [{
      id: 'm1', pp: 15, power, accuracy: 255, type: 0, effect: 0, chance: 0,
    }],
  };
}

function openBattle(relay, a, b) {
  a.peer.outbox = [];
  b.peer.outbox = [];
  relay.handle(a.id, { type: 'mmo.request', to: b.id, kind: 'battle' });
  ok(take(b, 'mmo.request') !== null, 'guest sees the battle ask');
  relay.handle(b.id, {
    type: 'mmo.respond', to: a.id, kind: 'battle', accept: true,
  });
  const hostSess = take(a, 'mmo.session');
  const guestSess = take(b, 'mmo.session');
  ok(hostSess && hostSess.role === 'host' && hostSess.id,
    'asker is named host of a battle session');
  ok(guestSess && guestSess.role === 'guest' && guestSess.id === hostSess.id,
    'guest shares the same session id');
  ok(relay.battles.has(hostSess.id),
    'a mediated battle record exists for the session');
  ok(/^s\d+$/.test(hostSess.id),
    'a session id carries the letter that keeps it out of the co-op id space');
  return hostSess;
}

function uploadAndReady(relay, a, b, session, opts) {
  const o = opts || {};
  relay.handle(a.id, {
    type: 'mmo.battle_ruleset',
    chart: o.chart || [[100]],
  });
  relay.handle(a.id, {
    type: 'mmo.battle_party',
    battle: session.id,
    mons: o.aMons || [mon(90)],
  });
  relay.handle(b.id, {
    type: 'mmo.battle_party',
    battle: session.id,
    mons: o.bMons || [mon(20)],
  });
  const readyA = take(a, 'mmo.battle_ready');
  const readyB = take(b, 'mmo.battle_ready');
  ok(readyA && readyA.mode === '1v1' && readyB && readyB.battle === session.id,
    'both sides hear battle_ready once parties land');
  return readyA;
}

function testMediatedOneVOneKo() {
  const clock = makeClock();
  const relay = makeRelay(clock);
  const a = dial(relay, 'HOST');
  const b = dial(relay, 'GUEST');
  const session = openBattle(relay, a, b);
  a.peer.outbox = [];
  b.peer.outbox = [];
  uploadAndReady(relay, a, b, session);

  let outcome = null;
  for (let turn = 0; turn < 30; turn++) {
    takeAll(a, 'mmo.battle_event');
    takeAll(b, 'mmo.battle_event');
    if (!relay.battles.has(session.id)) break;
    relay.handle(a.id, {
      type: 'mmo.battle_choice', battle: session.id,
      action: 'fight', move: 0, target: 2,
    });
    relay.handle(b.id, {
      type: 'mmo.battle_choice', battle: session.id,
      action: 'fight', move: 0, target: 0,
    });
    outcome = take(a, 'mmo.battle_outcome') || take(b, 'mmo.battle_outcome');
    if (outcome) break;
  }
  ok(outcome && outcome.reason === 'ko',
    'intermediator ends the fight with a ko outcome');
  ok(Array.isArray(outcome.winners) && outcome.winners.length === 1,
    'outcome names a winner');
  ok(!relay.battles.has(session.id),
    'the mediated record is cleared after settle');
}

function testRelayHardCutDuringBattle() {
  const clock = makeClock();
  const relay = makeRelay(clock);
  const a = dial(relay, 'CUTA');
  const b = dial(relay, 'CUTB');
  const session = openBattle(relay, a, b);
  a.peer.outbox = [];
  b.peer.outbox = [];
  uploadAndReady(relay, a, b, session);
  a.peer.outbox = [];
  b.peer.outbox = [];
  relay.handle(a.id, {
    type: 'mmo.relay', to: b.id, payload: { type: 'action', move: 1 },
  });
  ok(take(b, 'mmo.relay') === null,
    'opaque mmo.relay is dropped once the battle is mediated');
}

function testDisconnectForfeitAfterGrace() {
  const clock = makeClock();
  const relay = makeRelay(clock);
  const a = dial(relay, 'STAYA');
  const b = dial(relay, 'DROPB');
  const session = openBattle(relay, a, b);
  a.peer.outbox = [];
  b.peer.outbox = [];
  uploadAndReady(relay, a, b, session, {
    aMons: [mon(40)],
    bMons: [mon(40)],
  });
  a.peer.outbox = [];
  b.peer.outbox = [];

  // Guest drops mid-fight; grace starts.
  ok(relay.leaveBattle(relay.get(b.id)) === true,
    'leaveBattle starts reconnect grace on a live sim');

  // Still within grace: no outcome yet.
  clock.advance(30_000);
  relay.tickBattles();
  ok(take(a, 'mmo.battle_outcome') === null,
    'no forfeit before the grace expires');

  // Past grace.
  clock.advance(40_000);
  relay.tickBattles();
  const outcome = take(a, 'mmo.battle_outcome');
  ok(outcome && outcome.outcome === 'forfeit',
    'past grace the missing side forfeits via intermediator outcome');
  ok(outcome.reason === 'disconnect', 'and the outcome says why');
  ok(outcome.winners.length === 1 && outcome.winners[0] === a.id,
    'naming the player who was still there as the winner');
  ok(outcome.losers.length === 1 && outcome.losers[0] === b.id,
    'and the one who left as the loser');
}

/*
 * A fight nobody won, and the shape of saying so.
 *
 * cleanBattleOutcome refuses an empty id list, so a draw carrying two of them is
 * a message no client reads -- a battle screen with no way out. The absence is
 * the statement, which is what the Lua hub has always done and what this one used
 * to get wrong by sending `winners: []`.
 */
function testDrawCarriesNoLists() {
  const clock = makeClock();
  const relay = makeRelay(clock);
  const a = dial(relay, 'DRAWA');
  const b = dial(relay, 'DRAWB');
  const session = openBattle(relay, a, b);
  a.peer.outbox = [];
  b.peer.outbox = [];
  uploadAndReady(relay, a, b, session, { aMons: [mon(40)], bMons: [mon(40)] });
  a.peer.outbox = [];
  b.peer.outbox = [];

  // Both sides run, which the turn machine reads as a mutual concession.
  relay.handle(a.id, {
    type: 'mmo.battle_choice', battle: session.id, action: 'run',
  });
  relay.handle(b.id, {
    type: 'mmo.battle_choice', battle: session.id, action: 'run',
  });
  const outcome = take(a, 'mmo.battle_outcome');
  ok(outcome && outcome.outcome === 'draw', 'both running is a draw');
  ok(outcome.winners === undefined && outcome.losers === undefined,
    'carrying neither list rather than two empty ones');
  ok(outcome.reason === 'run', 'and still saying why it ended');
}

/*
 * Two players against a trainer, refereed.
 *
 * The two things coop_npc was waiting on: two seats for the trainer rather than
 * one, and something to answer for them. Nothing below advances the clock, so a
 * turn that needed the choice deadline to close would never close at all.
 */
function testCoopNpcMediated() {
  const clock = makeClock();
  const relay = makeRelay(clock);
  const a = dial(relay, 'NPCA');
  const b = dial(relay, 'NPCB');
  relay.openCoopBattle('c1', [a.id, b.id],
    { mode: 'coop_npc', hostId: a.id });
  const record = relay.battles.get('c1');
  ok(record && record.npcIds.length === 2,
    'a coop_npc seats the trainer twice, because the screen draws two of it');
  ok(record.npcIds[0] === 'nc1a' && record.npcIds[1] === 'nc1b',
    'under ids named off the battle and legal on the wire');
  a.peer.outbox = [];
  b.peer.outbox = [];

  relay.handle(a.id, { type: 'mmo.battle_ruleset', chart: [[100]] });
  relay.handle(a.id, {
    type: 'mmo.battle_party', battle: 'c1', side: 'a', mons: [mon(200)],
  });
  relay.handle(b.id, {
    type: 'mmo.battle_party', battle: 'c1', side: 'a', mons: [mon(200)],
  });
  ok(record.sim === null,
    'two players are not a field: the trainer owes a team too');

  relay.handle(a.id, {
    type: 'mmo.battle_party',
    battle: 'c1',
    side: 'b',
    mons: [mon(10, 1), mon(10, 1)],
  });
  ok(record.sim !== null,
    "the host's second party is what completes the set");
  ok(record.parties.get('nc1a').mons.length === 1
    && record.parties.get('nc1b').mons.length === 1,
    "and the trainer's team is dealt one to each seat");

  // A trainer seat the host uploaded no bag for is seeded with the gym kit, so
  // a gym leader can potion. testCoopWildCatchCatcher is the other half of this
  // claim: wildlife is never seeded, because a wild monster has no bag.
  ok(!relay.isWildSeat(record, 'nc1a'),
    'a coop_npc npc seat is a trainer, not wildlife');
  ok(record.bags.get('nc1a'), 'so it was seeded with a gym kit');
  ok(record.sim.byId.get('nc1a').bag.POTION === relay.Turn.DEFAULT_NPC_BAG.POTION,
    'the kit the sim actually fights with');

  const ready = take(a, 'mmo.battle_ready');
  ok(ready && ready.sides.b.length === 2,
    'both trainer seats are advertised on side b');
  ok(ready.sides.b[0] === 'nc1a',
    'under their own ids rather than behind the host, so the screen can map '
    + 'each of them onto a box it is already drawing');

  let outcome = null;
  for (let turn = 0; turn < 30; turn += 1) {
    takeAll(a, 'mmo.battle_event');
    takeAll(b, 'mmo.battle_event');
    if (!relay.battles.has('c1')) break;
    for (const player of [a, b]) {
      relay.handle(player.id, {
        type: 'mmo.battle_choice', battle: 'c1', action: 'fight', move: 0,
      });
    }
    outcome = take(a, 'mmo.battle_outcome') || take(b, 'mmo.battle_outcome');
    if (outcome) break;
  }
  ok(outcome && outcome.outcome === 'win',
    'the fight runs to an end with nobody waiting on a clock');
  ok(outcome.winners.includes(a.id) && outcome.winners.includes(b.id),
    'with the two players named as the winners');
  ok(outcome.losers.includes('nc1a'),
    "and the trainer's seats as the side that lost");
  ok(clock.now() === 1_000_000,
    'and no time passed at all -- the trainer answered in the same breath');
}

function testTradeRelayStillWorks() {
  const clock = makeClock();
  const relay = makeRelay(clock);
  const a = dial(relay, 'TRADA');
  const b = dial(relay, 'TRADB');
  a.peer.outbox = [];
  b.peer.outbox = [];
  relay.handle(a.id, { type: 'mmo.request', to: b.id, kind: 'trade' });
  relay.handle(b.id, {
    type: 'mmo.respond', to: a.id, kind: 'trade', accept: true,
  });
  const session = take(a, 'mmo.session');
  ok(session && session.kind === 'trade', 'trade session opens');
  ok(!relay.battles.has(session.id),
    'a trade does not open a mediated battle record');
  a.peer.outbox = [];
  b.peer.outbox = [];
  relay.handle(a.id, {
    type: 'mmo.relay', to: b.id, payload: { type: 'hello', x: 1 },
  });
  const relayed = take(b, 'mmo.relay');
  ok(relayed && relayed.payload && relayed.payload.type === 'hello',
    'trade mmo.relay still forwards unread');
}

function testCoopWildSeating() {
  const clock = makeClock();
  const relay = makeRelay(clock);
  const a = dial(relay, 'CWILDA');
  const b = dial(relay, 'CWILDB');

  const record = relay.openMediatedBattle('cw-1', {
    mode: 'coop_wild',
    hostId: a.id,
    memberIds: [a.id, b.id],
  });
  ok(record && record.npcIds.length === 1,
    'coop_wild opens with one synthetic wild seat');
  ok(record.sides.a.length === 2 && record.sides.b.length === 1,
    'side a is two humans and side b is the wild seat');
  ok(record.sides.b[0] === record.npcIds[0],
    'side b names the wild seat');
  ok(relay.battleSeat(record, relay.get(a.id), { side: 'b' }) === record.npcIds[0],
    "the host's side-b upload fills the wild seat");

  const solo = relay.openMediatedBattle('cw-2', {
    mode: 'coop_wild',
    hostId: a.id,
    memberIds: [a.id],
  });
  ok(solo === null, 'coop_wild refuses without exactly two humans');

  const c = dial(relay, 'CWILDC');
  const crowd = relay.openMediatedBattle('cw-3', {
    mode: 'coop_wild',
    hostId: a.id,
    memberIds: [a.id, b.id, c.id],
  });
  ok(crowd === null, 'coop_wild refuses with three humans');
}

function testCoopWildCatchCatcher() {
  const clock = makeClock();
  const relay = makeRelay(clock);
  const a = dial(relay, 'CATCHA');
  const b = dial(relay, 'CATCHB');
  relay.openCoopBattle('cw-catch', [a.id, b.id],
    { mode: 'coop_wild', hostId: a.id });
  const record = relay.battles.get('cw-catch');
  a.peer.outbox = [];
  b.peer.outbox = [];

  relay.handle(a.id, { type: 'mmo.battle_ruleset', chart: [[100]] });
  relay.handle(a.id, {
    type: 'mmo.battle_party',
    battle: 'cw-catch',
    side: 'a',
    mons: [mon(90)],
    bag: [{ id: 'MASTER_BALL', count: 1 }],
  });
  relay.handle(b.id, {
    type: 'mmo.battle_party',
    battle: 'cw-catch',
    side: 'a',
    mons: [mon(90)],
  });
  relay.handle(a.id, {
    type: 'mmo.battle_party',
    battle: 'cw-catch',
    side: 'b',
    mons: [{
      species: 'PIDGEY',
      level: 50,
      hp: 100,
      maxHp: 100,
      catchRate: 255,
      stats: { atk: 40, def: 40, spd: 40, spc: 40 },
      moves: [{
        id: 'm1', pp: 15, power: 0, accuracy: 255, type: 0, effect: 0, chance: 0,
      }],
    }],
  });
  ok(record && record.sim, 'coop_wild sim starts with two humans and a wild party');

  // Wildlife carries no bag. The seat is synthetic exactly as a coop_npc
  // trainer seat is, and it used to be seeded with the same gym kit -- which is
  // how a wild monster ended up drinking a Potion mid-fight. The turn machine
  // refuses an item from the seat as well; this is the bag never existing.
  const wildSeat = record.npcIds[0];
  ok(relay.isNpcSeat(record, wildSeat), 'the wild seat is a synthetic seat');
  ok(relay.isWildSeat(record, wildSeat), 'and it is wildlife, not a trainer');
  ok(!record.bags.get(wildSeat), 'so no gym kit was seeded onto it');
  ok(!record.sim.byId.get(wildSeat).bag, 'and it fights with no bag at all');
  take(a, 'mmo.battle_ready');
  take(b, 'mmo.battle_ready');
  a.peer.outbox = [];
  b.peer.outbox = [];

  let outcome = null;
  for (let turn = 0; turn < 20; turn += 1) {
    takeAll(a, 'mmo.battle_event');
    takeAll(b, 'mmo.battle_event');
    if (!relay.battles.has('cw-catch')) break;
    relay.handle(a.id, {
      type: 'mmo.battle_choice', battle: 'cw-catch',
      action: 'item', item: 'MASTER_BALL',
    });
    relay.handle(b.id, {
      type: 'mmo.battle_choice', battle: 'cw-catch',
      action: 'fight', move: 0,
    });
    outcome = take(a, 'mmo.battle_outcome') || take(b, 'mmo.battle_outcome');
    if (outcome) break;
  }
  ok(outcome && outcome.reason === 'catch',
    'catch success reasons the outcome as catch');
  ok(outcome.catcher === a.id, 'catcher names the thrower');
  ok(take(a, 'mmo.battle_outcome') || take(b, 'mmo.battle_outcome'),
    'both players hear the outcome');
  ok(!relay.battles.has('cw-catch'),
    'the record is cleared like any other settlement');
}

function testBagProofs() {
  const clock = makeClock();
  const relay = makeRelay(clock);
  const a = dial(relay, 'BAGA');
  const b = dial(relay, 'BAGB');
  const session = openBattle(relay, a, b);
  a.peer.outbox = [];
  b.peer.outbox = [];

  relay.handle(a.id, {
    type: 'mmo.battle_ruleset', chart: [[100]],
  });
  relay.handle(a.id, {
    type: 'mmo.battle_party',
    battle: session.id,
    mons: [mon(40)],
    bag: [{ id: 'NOT_A_REAL_ITEM', count: 1 }],
  });
  ok(!relay.battles.get(session.id).parties.has(a.id),
    'unknown bag id refuses the party');
  relay.handle(a.id, {
    type: 'mmo.battle_party',
    battle: session.id,
    mons: [mon(40)],
    bag: [{ id: 'POTION', count: 1 }, { id: 'POKE_FLUTE', count: 1 }],
  });
  relay.handle(b.id, {
    type: 'mmo.battle_party',
    battle: session.id,
    mons: [mon(100)],
  });
  const record = relay.battles.get(session.id);
  ok(record && record.sim, 'fight opens with bag sheets');
  ok(record.bags.get(a.id).POTION === 1, "host's bag holds one potion");
  ok(!record.bags.get(b.id).POTION, 'guest empty bag has no potion');

  relay.handle(b.id, {
    type: 'mmo.battle_choice', battle: session.id,
    action: 'item', item: 'POTION',
  });
  ok(record.sim.byId.get(b.id).choice == null,
    'item without a bag stack is refused');

  relay.handle(a.id, {
    type: 'mmo.battle_choice', battle: session.id,
    action: 'item', item: 'POTION',
  });
  ok(record.sim.byId.get(a.id).choice != null, 'proved potion accepted');
  ok(record.bags.get(a.id).POTION === 1, 'stack held until resolve');
  ok(record.bagHold[a.id] === 'POTION', 'hold names the pending item');

  relay.handle(a.id, {
    type: 'mmo.battle_choice', battle: session.id, action: 'cancel',
  });
  ok(record.sim.byId.get(a.id).choice == null, 'cancel clears the choice');
  ok(record.bagHold[a.id] === undefined, 'and drops the bag hold');
  ok(record.bags.get(a.id).POTION === 1, 'without decrementing');

  relay.handle(a.id, {
    type: 'mmo.battle_choice', battle: session.id,
    action: 'item', item: 'POTION',
  });
  relay.handle(b.id, {
    type: 'mmo.battle_choice', battle: session.id,
    action: 'fight', move: 0,
  });
  ok(record.bags.get(a.id).POTION === undefined, 'resolve spends the hold');

  if (record.sim && record.sim.phase === 'choice') {
    relay.handle(a.id, {
      type: 'mmo.battle_choice', battle: session.id,
      action: 'item', item: 'POTION',
    });
    ok(record.sim.byId.get(a.id).choice == null,
      'overdrawn potion refused');
    relay.handle(a.id, {
      type: 'mmo.battle_choice', battle: session.id,
      action: 'item', item: 'POKE_FLUTE',
    });
    ok(record.sim.byId.get(a.id).choice != null, 'Poké Flute proved');
    ok(record.bags.get(a.id).POKE_FLUTE === 1,
      'Poké Flute not decremented');
  }
}

testMediatedOneVOneKo();
testRelayHardCutDuringBattle();
testDisconnectForfeitAfterGrace();
testDrawCarriesNoLists();
testCoopNpcMediated();
testCoopWildSeating();
testCoopWildCatchCatcher();
testTradeRelayStillWorks();
testBagProofs();

// Wave 2 T2d: hub generation selects battle vs battle2 at construction.
{
  const battle1 = require('./lib/battle');
  const battle2 = require('./lib/battle2');
  ok(battle2.GENERATION === 2, 'battle2 index GENERATION===2');
  const gen1 = new Relay({ maxPlayers: 8, log: quiet });
  ok(gen1.generation === 1, 'omitted generation defaults to 1');
  ok(gen1.Turn === battle1.Turn, 'generation 1 loads lib/battle Turn');
  ok(gen1.Effects === battle1.Effects, 'generation 1 loads lib/battle Effects');
  const gen2 = new Relay({ generation: 2, maxPlayers: 8, log: quiet });
  ok(gen2.generation === 2, 'generation:2 is stored');
  ok(gen2.Turn === battle2.Turn, 'generation 2 loads lib/battle2 Turn');
  ok(gen2.Effects === battle2.Effects, 'generation 2 loads lib/battle2 Effects');
  ok(gen2.Turn !== battle1.Turn, 'Gen2 hub never holds Gen1 Turn');
}

console.log(`hub_battle: ${passed} checks passed`);
