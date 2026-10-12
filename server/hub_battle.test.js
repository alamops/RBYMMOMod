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

const { Relay, PROTOCOL, DEFAULT_SPRITE, presenceOf } = require('./lib/relay.js');
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

function partyForm(relay, asker, invitee) {
  relay.handle(asker.id, { type: 'mmo.party_invite', to: invitee.id });
  take(invitee, 'mmo.party_invite');
  relay.handle(invitee.id, {
    type: 'mmo.party_respond', to: asker.id, accept: true,
  });
}

function coopAskCount(relay) {
  return relay.coopAsks.size;
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

// ANN alone against the hub's wild seat: a fight against the computer, the
// only kind a mid-fight learn or level-up (`mmo.battle_moveset`) is heard in --
// no cart levels or learns in a link battle (relay LEARN_MODES). Twin of
// openWildFight in tests/hub_battle.lua.
function openWild(relay, a, aMons, bMons) {
  const id = 'wl';
  relay.openCoopBattle(id, [a.id], { mode: 'wild', hostId: a.id });
  relay.handle(a.id, { type: 'mmo.battle_ruleset', battle: id, chart: [[100]] });
  relay.handle(a.id, {
    type: 'mmo.battle_party', battle: id, side: 'a', mons: aMons || [mon(90)],
  });
  relay.handle(a.id, {
    type: 'mmo.battle_party', battle: id, side: 'b', mons: bMons || [mon(20)],
  });
  return { id };
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
      action: 'fight', move: 0, target: 3,
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

// A nicknamed monster, all the way across the hub.
//
// `species` on the wire is the token the fight is *narrated* under, which is
// the nickname wherever the player set one -- so it is the one name the client
// opposite cannot resolve to anything. Its seat had no front pic to draw, no
// number for its level pill and no base rate to price an award with: the peer's
// monster came up as a blank box at Lv 1. The id has to survive the sanitiser
// on the way in and be stated on the `send` on the way out, and this asserts
// both ends of that at once.
function testNicknamedMonKeepsItsId() {
  const clock = makeClock();
  const relay = makeRelay(clock);
  const a = dial(relay, 'NICKA');
  const b = dial(relay, 'NICKB');
  const session = openBattle(relay, a, b);
  a.peer.outbox = [];
  b.peer.outbox = [];
  const nicknamed = { ...mon(90), species: 'MALBABISCO', speciesId: 'SQUIRTLE', level: 8 };
  uploadAndReady(relay, a, b, session, { aMons: [nicknamed] });

  const sends = takeAll(b, 'mmo.battle_event').filter((e) => e.t === 'send');
  const foe = sends.find((e) => e.slot === 0);
  ok(foe != null, "the guest is told about the host's send-out");
  ok(foe.text === 'MALBABISCO', 'narrated under the nickname, as it always was');
  ok(foe.speciesId === 'SQUIRTLE',
    'and the registry id rides along, which is the only thing art resolves by');
  ok(foe.level === 8, 'as does the level the pill prints');

  // The other half of the sanitiser's contract: an id that is not id-shaped
  // refuses the battler outright rather than arriving as prose.
  const relay2 = makeRelay(makeClock());
  const c = dial(relay2, 'BADIDA');
  const d = dial(relay2, 'BADIDB');
  const session2 = openBattle(relay2, c, d);
  c.peer.outbox = [];
  d.peer.outbox = [];
  relay2.handle(c.id, { type: 'mmo.battle_ruleset', chart: [[100]] });
  relay2.handle(c.id, {
    type: 'mmo.battle_party',
    battle: session2.id,
    mons: [{ ...mon(90), speciesId: 'not an id!' }],
  });
  relay2.handle(d.id, {
    type: 'mmo.battle_party', battle: session2.id, mons: [mon(20)],
  });
  const record = relay2.battles.get(session2.id);
  ok(record && !record.sim,
    'a battler with an unreadable id is refused, so the fight never starts');
  ok(take(c, 'mmo.battle_ready') === null && take(d, 'mmo.battle_ready') === null,
    '...and neither side is told to open a battle screen');
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
 * SESSION_LEAVE of a live fight starts reconnect grace and clears sessionId
 * while keeping battleId. REQUEST / startSession used to look only at
 * sessionId, so the same connection could open a new pairing and
 * openMediatedBattle would overwrite member.battleId, leaving the old sim
 * ticking toward a forfeit beside the new match.
 */
function testSessionLeaveCannotStartSecondFight() {
  const clock = makeClock();
  const relay = makeRelay(clock);
  const a = dial(relay, 'STAYA');
  const b = dial(relay, 'LEAVEB');
  const c = dial(relay, 'CAL');
  const session = openBattle(relay, a, b);
  a.peer.outbox = [];
  b.peer.outbox = [];
  uploadAndReady(relay, a, b, session, {
    aMons: [mon(40)],
    bMons: [mon(40)],
  });
  a.peer.outbox = [];
  b.peer.outbox = [];
  c.peer.outbox = [];

  relay.handle(b.id, { type: 'mmo.session_leave' });
  const bob = relay.get(b.id);
  ok(bob.sessionId == null, 'the session is gone');
  ok(bob.battleId === session.id, 'but grace still binds them to the fight');
  ok(relay.battles.has(session.id), 'and the original record is still standing');

  b.peer.outbox = [];
  relay.handle(b.id, { type: 'mmo.request', to: c.id, kind: 'duel' });
  ok(take(b, 'mmo.decline') === null,
    'a request with no valid kind earns no reply');

  relay.handle(b.id, { type: 'mmo.request', to: c.id, kind: 'battle' });
  ok(take(c, 'mmo.request') === null,
    'the leaver cannot open a second pairing while grace runs');
  const selfBusy = take(b, 'mmo.decline');
  ok(selfBusy && selfBusy.reason === 'busy' && selfBusy.kind === 'battle',
    'the leaver is told busy so their outgoing ask clears');

  relay.handle(c.id, { type: 'mmo.request', to: b.id, kind: 'battle' });
  const declined = take(c, 'mmo.decline');
  ok(declined && declined.reason === 'busy',
    'asking them is a busy, not a new fight');

  relay.startSession(bob, relay.get(c.id), 'battle');
  ok(relay.get(c.id).sessionId == null,
    'startSession itself refuses while they are bound');
  ok(relay.openMediatedBattle('s999', { memberIds: [b.id] }) == null,
    'openMediatedBattle will not overwrite an unsettled battleId');
  ok(bob.battleId === session.id, 'so they stay on the original fight');
  ok(relay.battles.has(session.id), 'which is still the one record');

  clock.advance((60 + 2) * 1000);
  relay.tickBattles();
  ok(!relay.battles.has(session.id), 'past grace the original fight settles');
  ok(bob.battleId == null, 'and they are let out of it');
  c.peer.outbox = [];
  relay.handle(b.id, { type: 'mmo.request', to: c.id, kind: 'battle' });
  ok(take(c, 'mmo.request') !== null,
    'past grace a new ask is forwarded');
}

/*
 * A stolen battleId is a drop of that seat, not a wipe of the field.
 * Abort (and closeCoopBattle) only when no connected member still points here.
 */
function testOrphanSweepDisconnectsStolenSeat() {
  const clock = makeClock();
  const relay = makeRelay(clock);
  const a = dial(relay, 'KEEPA');
  const b = dial(relay, 'STEALB');
  const session = openBattle(relay, a, b);
  a.peer.outbox = [];
  b.peer.outbox = [];
  uploadAndReady(relay, a, b, session, {
    aMons: [mon(40)],
    bMons: [mon(40)],
  });

  const bob = relay.get(b.id);
  const ann = relay.get(a.id);
  bob.battleId = 'stolen';
  relay.tickBattles();
  ok(relay.battles.has(session.id),
    'a stolen seat does not abort the partner still bound');
  ok(ann.battleId === session.id, 'the partner stays on the original fight');
  ok(bob.battleId == null, 'and the stolen pointer is forgotten');

  ann.battleId = 'stolen2';
  relay.tickBattles();
  ok(!relay.battles.has(session.id),
    'when no connected member still points at it, the record is aborted');
  ok(ann.battleId == null, 'and the second stolen pointer is forgotten');
}

function testOrphanSweepClosesCoopGroup() {
  const clock = makeClock();
  const relay = makeRelay(clock);
  const a = dial(relay, 'COOPA');
  const b = dial(relay, 'COOPB');
  relay.openCoopBattle('c-orphan', [a.id, b.id],
    { mode: 'coop_npc', hostId: a.id });
  ok(relay.coopBattles.has('c-orphan'), 'a coop group opens with the fight');

  const ann = relay.get(a.id);
  const bob = relay.get(b.id);
  ann.battleId = 'stolen';
  bob.battleId = 'stolen2';
  relay.tickBattles();
  ok(!relay.battles.has('c-orphan'), 'the fight is gone');
  ok(!relay.coopBattles.has('c-orphan'),
    'and the fan-out group closes with it');
  ok(ann.coopBattleId == null && bob.coopBattleId == null,
    'so neither member is still filed under the dead group');
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

  // A trainer seat the host uploaded no bag for stays empty. The gym kit
  // used to be seeded onto *each* NPC seat, so a 2v2 looked like eight
  // healing items and every Youngster drank potions. Hosts now upload the
  // trainer's own kit with the side-"b" party; nothing here invents one.
  ok(!relay.isWildSeat(record, 'nc1a'),
    'a coop_npc npc seat is a trainer, not wildlife');
  ok(!record.sim.byId.get('nc1a').bag,
    'no uploaded bag means no gym kit');
  ok(!record.sim.byId.get('nc1b').bag,
    '...on either seat');

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

// One trainer, two seats (K16 of docs/plans/gen12-referee-remaining-gaps.md):
// Red's computer items are its class's TrainerAI record (`aiClass`), not a
// bag, so the referee keeps no NPC bag -- even one an older client still
// uploads. The record rides onto both seats, each its own copy (battle Turn
// `copyAiClass`): it is only read, and what TrainerAI spends is the seat's own
// wAICount. Gold's shared kit is testK16GoldTrainerKit. Twin of the same block
// in tests/hub_battle.lua.
function testCoopNpcTrainerBagShared() {
  const clock = makeClock();
  const relay = makeRelay(clock);
  const a = dial(relay, 'BAGA');
  const b = dial(relay, 'BAGB');
  relay.openCoopBattle('c-bag', [a.id, b.id],
    { mode: 'coop_npc', hostId: a.id });
  const record = relay.battles.get('c-bag');
  relay.handle(a.id, { type: 'mmo.battle_ruleset', chart: [[100]] });
  relay.handle(a.id, {
    type: 'mmo.battle_party', battle: 'c-bag', side: 'a', mons: [mon(200)],
  });
  relay.handle(b.id, {
    type: 'mmo.battle_party', battle: 'c-bag', side: 'a', mons: [mon(200)],
  });
  relay.handle(a.id, {
    type: 'mmo.battle_party',
    battle: 'c-bag',
    side: 'b',
    mons: [mon(10, 1), mon(10, 1)],
    aiClass: { uses: 1, item: 'POTION', hpBelow: 5 },
    bag: [{ id: 'POTION', count: 1 }],
  });
  ok(record.sim !== null, "the fight opens with the trainer's class record");
  const seatA = record.sim.byId.get(record.npcIds[0]);
  const seatB = record.sim.byId.get(record.npcIds[1]);
  ok(seatA.bag == null, 'K16: an uploaded NPC bag reaches no seat -- the computer keeps none');
  ok(seatB.bag == null, 'K16: ...on either seat');
  const classA = seatA.aiClass;
  const classB = seatB.aiClass;
  ok(classA && classA.item === 'POTION', "K16: the first seat holds the trainer's TrainerAI record");
  ok(classB && classB.item === 'POTION', 'K16: ...and so does the second');
  ok(classB && classB.hpBelow === 5, 'K16: ...field for field');
  ok(classA && classA !== classB, "K16: each seat's record is its own copy, not one aliased object");
  ok(classA && classA !== record.parties.get(record.npcIds[0]).aiClass,
    "K16: ...nor the hub's own sheet");
}

function testCoopNpcGuestSideBRefused() {
  const clock = makeClock();
  const relay = makeRelay(clock);
  const a = dial(relay, 'HOSTA');
  const b = dial(relay, 'GUESTB');
  relay.openCoopBattle('c-guestb', [a.id, b.id],
    { mode: 'coop_npc', hostId: a.id });
  const record = relay.battles.get('c-guestb');
  relay.handle(a.id, { type: 'mmo.battle_ruleset', chart: [[100]] });
  relay.handle(a.id, {
    type: 'mmo.battle_party', battle: 'c-guestb', side: 'a', mons: [mon(200)],
  });
  relay.handle(b.id, {
    type: 'mmo.battle_party', battle: 'c-guestb', side: 'a', mons: [mon(200)],
  });
  relay.handle(b.id, {
    type: 'mmo.battle_party',
    battle: 'c-guestb',
    side: 'b',
    mons: [mon(10, 1), mon(10, 1)],
    aiClass: { uses: 9, item: 'FULL_HEAL' },
  });
  ok(record.sim === null, 'a guest side-b does not open the fight');
  ok(record.parties.get(b.id) && record.parties.get(b.id).mons[0].hp === 100,
    "and does not replace the guest's own party");
  relay.handle(a.id, {
    type: 'mmo.battle_party',
    battle: 'c-guestb',
    side: 'b',
    mons: [mon(10, 1), mon(10, 1)],
    aiClass: { uses: 1, item: 'POTION' },
  });
  ok(record.sim !== null, "the initiator's side-b is what seats the trainer");
  // On Red the trainer's kit is its class record (K16).
  const kit = record.sim.byId.get(record.npcIds[0]).aiClass;
  ok(kit && kit.item === 'POTION', "with the initiator's kit, not the guest's");
  ok(kit && kit.uses === 1, '...its uses too');
}

function testCoopNpcBagDump() {
  const fs = require('node:fs');
  const os = require('node:os');
  const path = require('node:path');
  const dest = path.join(
    fs.mkdtempSync(path.join(os.tmpdir(), 'npc-bags-')),
    'npc_bags.txt');
  const clock = makeClock();
  const relay = makeRelay(clock, { dumpNpcBags: dest });
  const a = dial(relay, 'DUMPA');
  const b = dial(relay, 'DUMPB');
  relay.openCoopBattle('c-dump', [a.id, b.id],
    { mode: 'coop_npc', hostId: a.id });
  relay.handle(a.id, { type: 'mmo.battle_ruleset', chart: [[100]] });
  relay.handle(a.id, {
    type: 'mmo.battle_party', battle: 'c-dump', side: 'a', mons: [mon(200)],
  });
  relay.handle(b.id, {
    type: 'mmo.battle_party', battle: 'c-dump', side: 'a', mons: [mon(200)],
  });
  relay.handle(a.id, {
    type: 'mmo.battle_party',
    battle: 'c-dump',
    side: 'b',
    mons: [mon(10, 1), mon(10, 1)],
    bag: [{ id: 'POTION', count: 1 }],
  });
  const record = relay.battles.get('c-dump');
  const text = fs.readFileSync(dest, 'utf8');
  const lines = text.trimEnd().split('\n');
  ok(lines[0] === 'coop_npc\t1\t2',
    'dump header is mode, shared, seat count');
  // K16 (docs/plans/gen12-referee-remaining-gaps.md): the Red / Gold referee
  // keeps no NPC bag -- the computer's items are its class record / trainer
  // items -- so the bag an older client still uploads reaches neither seat.
  ok(lines[1] === `${record.npcIds[0]}\tempty=1\tgym=0\theal=0`,
    'first seat holds no bag: the uploaded one is not the computer\'s (K16)');
  ok(lines[2] === `${record.npcIds[1]}\tempty=1\tgym=0\theal=0`,
    'second seat the same');
  ok(text.indexOf('POTION') < 0 && text.indexOf('SUPER_POTION') < 0,
    'item ids never leave the hub (player game sheet stays in the client)');
  ok(text.indexOf('FULL_HEAL') < 0 && text.indexOf('X_ATTACK') < 0,
    'and neither do other stacks from that same sheet');
}

function testCoopNpcBagDumpStaysOutOfTree() {
  const fs = require('node:fs');
  const path = require('node:path');
  const dest = path.join(process.cwd(), 'npc_bags_refuse_test.txt');
  try { fs.unlinkSync(dest); } catch (_) {}
  const clock = makeClock();
  const relay = makeRelay(clock, { dumpNpcBags: dest });
  const a = dial(relay, 'TREESA');
  const b = dial(relay, 'TREESB');
  relay.openCoopBattle('c-tree', [a.id, b.id],
    { mode: 'coop_npc', hostId: a.id });
  relay.handle(a.id, { type: 'mmo.battle_ruleset', chart: [[100]] });
  relay.handle(a.id, {
    type: 'mmo.battle_party', battle: 'c-tree', side: 'a', mons: [mon(200)],
  });
  relay.handle(b.id, {
    type: 'mmo.battle_party', battle: 'c-tree', side: 'a', mons: [mon(200)],
  });
  relay.handle(a.id, {
    type: 'mmo.battle_party',
    battle: 'c-tree',
    side: 'b',
    mons: [mon(10, 1), mon(10, 1)],
    bag: [{ id: 'POTION', count: 1 }],
  });
  ok(!fs.existsSync(dest),
    'a dump path inside the working tree is refused');
}

function testNpcBagHealCountsGymKitOnly() {
  const clock = makeClock();
  const relay = makeRelay(clock);
  const flags = relay.npcBagFlags({ HYPER_POTION: 8, POTION: 1 });
  ok(flags.heal === 1,
    'heal counts gym-kit POTION, not a HYPER_POTION substring match');
  ok(flags.gym === false, 'HYPER_POTION extra keeps gym=false');
  const gym = relay.npcBagFlags({
    POTION: 2, SUPER_POTION: 1, FULL_HEAL: 1, X_ATTACK: 1,
  });
  ok(gym.heal === 4, 'one gym kit is 2+1+1 heals (X_ATTACK is not a heal)');
  ok(gym.gym === true, '...and matches the former seed');
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

  relay.abortMediatedBattle(record, 'gone');
  const solo = relay.openMediatedBattle('cw-2', {
    mode: 'coop_wild',
    hostId: a.id,
    memberIds: [a.id],
  });
  ok(solo === null, 'coop_wild refuses with one human');

  const c = dial(relay, 'CWILDC');
  const trio = relay.openMediatedBattle('cw-3', {
    mode: 'coop_wild',
    hostId: a.id,
    memberIds: [a.id, b.id, c.id],
  });
  ok(trio && trio.npcIds.length === 1,
    'coop_wild with three humans still has one wild seat');
  ok(trio.sides.a.length === 3 && trio.sides.b.length === 1,
    'side a is three humans and side b is the wild seat');
  ok(relay.seatsNeeded(trio).length === 4,
    'four seats owe a party');
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

function testCoopNpcThreeHumans() {
  const clock = makeClock();
  const relay = makeRelay(clock);
  const a = dial(relay, 'NPC3A');
  const b = dial(relay, 'NPC3B');
  const c = dial(relay, 'NPC3C');
  const record = relay.openMediatedBattle('npc-3h', {
    mode: 'coop_npc',
    hostId: a.id,
    memberIds: [a.id, b.id, c.id],
  });
  ok(record && record.npcIds.length === 3,
    'coop_npc with three humans seats three trainer slots');
  ok(record.sides.a.length === 3 && record.sides.b.length === 3,
    'three humans face three foe seats');
  ok(relay.seatsNeeded(record).length === 6,
    'six seats owe a party');
}

function testPartyGrowLeave() {
  const clock = makeClock();
  const relay = makeRelay(clock);
  const ann = dial(relay, 'PGROWA');
  const bob = dial(relay, 'PGROWB');
  const cal = dial(relay, 'PGROWC');
  const dee = dial(relay, 'PGROWD');

  partyForm(relay, ann, bob);
  const pair = take(ann, 'mmo.party');
  take(bob, 'mmo.party');
  ok(pair.members.length === 2, 'a new party starts with two members');

  partyForm(relay, ann, cal);
  const trioAnn = take(ann, 'mmo.party');
  take(bob, 'mmo.party');
  take(cal, 'mmo.party');
  ok(trioAnn.members.length === 3, 'inviting a third carries the full roster');

  relay.handle(ann.id, { type: 'mmo.party_invite', to: dee.id });
  ok(take(dee, 'mmo.party_invite') === null,
    'a full party never forwards a fourth invite');

  relay.handle(cal.id, { type: 'mmo.party_leave' });
  const duoAnn = take(ann, 'mmo.party');
  take(bob, 'mmo.party');
  ok(duoAnn.members.length === 2, 'two remain after one of three leaves');
  ok(take(ann, 'mmo.party_end') === null,
    'survivors are not told the party ended');
  ok(take(bob, 'mmo.party_end') === null,
    'survivors are not told the party ended');
  const calEnd = take(cal, 'mmo.party_end');
  ok(calEnd && calEnd.reason === 'left',
    'only the leaver hears party_end with reason left');
}

function testCoopChallengeMismatch() {
  const clock = makeClock();
  const relay = makeRelay(clock);
  const ann = dial(relay, 'MISMA');
  const bob = dial(relay, 'MISMB');
  const cal = dial(relay, 'MISMC');
  const dee = dial(relay, 'MISMD');
  const eve = dial(relay, 'MISME');

  partyForm(relay, ann, bob);
  take(ann, 'mmo.party');
  take(bob, 'mmo.party');
  partyForm(relay, ann, cal);
  take(ann, 'mmo.party');
  take(bob, 'mmo.party');
  take(cal, 'mmo.party');

  partyForm(relay, dee, eve);
  take(dee, 'mmo.party');
  take(eve, 'mmo.party');

  relay.handle(ann.id, { type: 'mmo.coop_challenge', to: dee.id });
  const decline = take(ann, 'mmo.coop_decline');
  ok(decline && decline.reason === 'mismatch',
    '3v2 challenge declines on the asker with reason mismatch');
  ok(coopAskCount(relay) === 0, 'and no ask is created');
  ok(take(bob, 'mmo.coop_ask') === null,
    'no partner is asked on mismatch');
}

function testCoopChallengeSquare() {
  const clock = makeClock();
  const relay = makeRelay(clock);
  const ann = dial(relay, 'SQ2A');
  const bob = dial(relay, 'SQ2B');
  const eve = dial(relay, 'SQ2E');
  const fay = dial(relay, 'SQ2F');

  partyForm(relay, ann, bob);
  take(ann, 'mmo.party');
  take(bob, 'mmo.party');
  partyForm(relay, eve, fay);
  take(eve, 'mmo.party');
  take(fay, 'mmo.party');

  relay.handle(ann.id, { type: 'mmo.coop_challenge', to: eve.id });
  ok(take(ann, 'mmo.coop_decline') === null, '2v2 challenge is not declined');
  ok(coopAskCount(relay) === 1, '2v2 opens one ask');
  ok(take(bob, 'mmo.coop_ask') !== null, 'the asker\'s partner is asked');
  ok(take(eve, 'mmo.coop_ask') !== null, 'the challenged party is asked');

  // 3v3 is its own hub, matching the Lua twin: six more seats on this
  // relay would overflow maxPlayers (the 2v2 four are still online).
  const clock3 = makeClock();
  const relay3 = makeRelay(clock3);
  const ann3 = dial(relay3, 'SQ3A');
  const bob3 = dial(relay3, 'SQ3B');
  const cal3 = dial(relay3, 'SQ3C');
  const dee3 = dial(relay3, 'SQ3D');
  const eve3 = dial(relay3, 'SQ3E');
  const fay3 = dial(relay3, 'SQ3F');

  partyForm(relay3, ann3, bob3);
  take(ann3, 'mmo.party');
  take(bob3, 'mmo.party');
  partyForm(relay3, ann3, cal3);
  take(ann3, 'mmo.party');
  take(bob3, 'mmo.party');
  take(cal3, 'mmo.party');

  partyForm(relay3, dee3, eve3);
  take(dee3, 'mmo.party');
  take(eve3, 'mmo.party');
  partyForm(relay3, dee3, fay3);
  take(dee3, 'mmo.party');
  take(eve3, 'mmo.party');
  take(fay3, 'mmo.party');

  relay3.handle(ann3.id, { type: 'mmo.coop_challenge', to: dee3.id });
  ok(take(ann3, 'mmo.coop_decline') === null, '3v3 challenge is not declined');
  ok(coopAskCount(relay3) === 1, '3v3 opens one ask');
  ok(take(bob3, 'mmo.coop_ask') !== null, 'every asker-side member is asked');
  ok(take(cal3, 'mmo.coop_ask') !== null, 'including the third traveller');
  ok(take(dee3, 'mmo.coop_ask') !== null, 'the challenged side is asked too');
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
    mons: [mon(40, 60)],
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
testNicknamedMonKeepsItsId();
testRelayHardCutDuringBattle();
testDisconnectForfeitAfterGrace();
testSessionLeaveCannotStartSecondFight();
testOrphanSweepDisconnectsStolenSeat();
testOrphanSweepClosesCoopGroup();
testDrawCarriesNoLists();
testCoopNpcMediated();
testCoopNpcTrainerBagShared();
testCoopNpcGuestSideBRefused();
testCoopNpcBagDump();
testCoopNpcBagDumpStaysOutOfTree();
testNpcBagHealCountsGymKitOnly();
testCoopWildSeating();
testCoopWildCatchCatcher();
testCoopNpcThreeHumans();
testPartyGrowLeave();
testCoopChallengeMismatch();
testCoopChallengeSquare();
testTradeRelayStillWorks();
// PROTOCOL 28: a mid-fight learn replaces the live sheet so the next
// fight choice executes the new move, not the uploaded one.
function testMidFightMoveset() {
  const clock = makeClock();
  const relay = makeRelay(clock);
  const a = dial(relay, 'LEARNA');
  const learner = {
    ...mon(40),
    moves: [
      { id: 'OLD', pp: 10, power: 40, accuracy: 255, type: 0, effect: 0, chance: 0 },
    ],
  };
  const session = openWild(relay, a, [learner]);
  const record = relay.battles.get(session.id);
  ok(record && record.sim, 'the fight is live before the learn');
  const sheet = (moves) => ({
    type: 'mmo.battle_moveset', battle: session.id, mon: 0, moves,
  });
  const oldSlot = {
    id: 'OLD', pp: 99, power: 999, accuracy: 255, type: 0, effect: 0, chance: 0,
  };
  const newSlot = {
    id: 'NEW', pp: 20, power: 80, accuracy: 255, type: 0, effect: 0, chance: 0,
    name: 'New Move',
  };
  relay.handle(a.id, sheet([oldSlot, newSlot]));
  const live = record.sim.byId.get(a.id).mons[0];
  ok(live.moves.length === 2 && live.moves[1].id === 'NEW',
    'the referee holds the learned move');
  ok(live.moves[0].pp === 10,
    'an unchanged slot keeps the hub PP, not a free refill');
  ok(live.moves[0].power === 40,
    'and the hub power, not a live rewrite of the same id');

  relay.handle(a.id, sheet([
    { id: 'AAA', pp: 20, power: 80, accuracy: 255, type: 0, effect: 0, chance: 0 },
    { id: 'BBB', pp: 20, power: 80, accuracy: 255, type: 0, effect: 0, chance: 0 },
  ]));
  ok(live.moves[0].id === 'OLD' && live.moves[1].id === 'NEW',
    'rewriting two slots is refused');

  const swapped = {
    id: 'SWAP', pp: 15, power: 60, accuracy: 255, type: 0, effect: 0, chance: 0,
    name: 'Swap',
  };
  relay.handle(a.id, sheet([
    { id: 'OLD', pp: 10, power: 40, accuracy: 255, type: 0, effect: 0, chance: 0 },
    swapped,
  ]));
  ok(live.moves[1].id === 'SWAP',
    'replacing exactly one id is the forget case');

  live.transformed = true;
  const before = live.moves[1].id;
  relay.handle(a.id, sheet([
    { id: 'OLD', pp: 10, power: 40, accuracy: 255, type: 0, effect: 0, chance: 0 },
    swapped,
    newSlot,
  ]));
  ok(live.transformed && live.moves[1].id === before,
    'a transformed battler is left alone');
}

// ...and none of it in a fight between players. No cart learns a move in a
// link battle (pokered GainExperience returns on LINK_STATE_BATTLING,
// pokecrystal GiveExperiencePoints on wLinkMode, pokeemerald Cmd_getexp under
// BATTLE_TYPE_LINK), so the PROTOCOL 28 learn a 1v1 used to take is a one-slot
// rewrite of a monster the other player is fighting: the hub drops the message
// whole (relay LEARN_MODES). Twin of the "pvp learn" block in
// tests/hub_battle.lua.
function testPvpMovesetDropped() {
  const relay = makeRelay(makeClock());
  const a = dial(relay, 'LEARNA');
  const b = dial(relay, 'LEARNB');
  const session = openBattle(relay, a, b);
  uploadAndReady(relay, a, b, session);
  const record = relay.battles.get(session.id);
  const live = record.sim.byId.get(a.id).mons[0];
  const before = live.moves;
  relay.handle(a.id, {
    type: 'mmo.battle_moveset',
    battle: session.id,
    mon: 0,
    moves: [{ id: 'SWAP', pp: 20, power: 250, accuracy: 255, type: 0, effect: 0, chance: 0 }],
  });
  ok(live.moves[0].id === 'm1', 'pvp learn: a one-id replace off the wire reaches nothing');
  ok(relay.applyBattleMoveset(record, relay.get(a.id), {
    mon: 0,
    moves: [mon(90).moves[0], {
      id: 'NEW', pp: 20, power: 250, accuracy: 255, type: 0, effect: 0, chance: 0,
    }],
  }) === false, 'pvp learn: a one-slot learn in a 1v1 is refused');
  ok(live.moves === before && live.moves.length === 1,
    "pvp learn: ...and the referee's list is the one it had");
}

/*
 * Co-op mediated fights set battleId / coopBattleId, not sessionId. Treating
 * only sessionId as hub-busy published those players as free and delivered a
 * second ask a modified client could accept.
 */
function testBusyNowMediatedFight() {
  const clock = makeClock();
  const relay = makeRelay(clock);
  const host = dial(relay, 'HOST');
  const ally = dial(relay, 'ALLY');
  const asker = dial(relay, 'ASKER');
  take(host, 'mmo.welcome'); take(ally, 'mmo.welcome'); take(asker, 'mmo.welcome');
  host.peer.outbox = []; ally.peer.outbox = []; asker.peer.outbox = [];

  relay.handle(asker.id, { type: 'mmo.request', to: ally.id, kind: 'trade' });
  ok(take(ally, 'mmo.request') !== null, 'the ask lands while they are free');

  relay.openCoopBattle('c-busy', [host.id, ally.id],
    { mode: 'coop_npc', hostId: host.id });
  const fighter = relay.get(ally.id);
  ok(!fighter.sessionId, 'co-op does not take a sessionId');
  ok(fighter.battleId && fighter.coopBattleId,
    'it takes a battleId and a coopBattleId');
  const opened = take(asker, 'mmo.move');
  ok(opened && opened.busy === true,
    'the hub publishes them busy without anyone stepping');

  asker.peer.outbox = []; ally.peer.outbox = [];
  relay.handle(ally.id, {
    type: 'mmo.respond', to: asker.id, kind: 'trade', accept: true,
  });
  const stacked = take(asker, 'mmo.decline');
  ok(stacked && stacked.reason === 'busy',
    'accepting after the fight opened is refused as busy');
  ok(take(ally, 'mmo.session') === null && take(asker, 'mmo.session') === null,
    'and starts no second session');

  asker.peer.outbox = []; ally.peer.outbox = [];
  relay.handle(asker.id, { type: 'mmo.request', to: ally.id, kind: 'battle' });
  const midFight = take(asker, 'mmo.decline');
  ok(midFight && midFight.reason === 'busy',
    'asking a fighter is declined at the hub');
  ok(take(ally, 'mmo.request') === null, 'and never reaches them');

  asker.peer.outbox = []; ally.peer.outbox = [];
  relay.handle(ally.id, { type: 'mmo.request', to: asker.id, kind: 'trade' });
  ok(take(asker, 'mmo.request') === null,
    "a fighter's own ask is dropped rather than forwarded");

  asker.peer.outbox = [];
  relay.closeCoopBattle('c-busy');
  const closed = take(asker, 'mmo.move');
  ok(closed && closed.busy === false,
    'and publishing them free when the fight ends');
}

function testHubBusyFields() {
  const clock = makeClock();
  const relay = makeRelay(clock);
  const ally = dial(relay, 'ALLY');
  const asker = dial(relay, 'ASKER');
  take(ally, 'mmo.welcome'); take(asker, 'mmo.welcome');
  const fighter = relay.get(ally.id);

  // A live unsettled record, not a dangling pointer: unsettledBattle heals
  // a stale battleId rather than treating it as occupancy.
  relay.battles.set('c-only', { id: 'c-only', settled: false, memberIds: [ally.id] });
  fighter.battleId = 'c-only';
  fighter.coopBattleId = null;
  ok(presenceOf(fighter, relay).busy === true, 'battleId alone is hub-busy');
  asker.peer.outbox = []; ally.peer.outbox = [];
  relay.handle(asker.id, { type: 'mmo.request', to: ally.id, kind: 'battle' });
  const byBattle = take(asker, 'mmo.decline');
  ok(byBattle && byBattle.reason === 'busy', 'and declines a request');
  ok(take(ally, 'mmo.request') === null);

  fighter.battleId = null;
  fighter.coopBattleId = 'c-group';
  ok(presenceOf(fighter, relay).busy === true, 'coopBattleId alone is hub-busy');
  asker.peer.outbox = []; ally.peer.outbox = [];
  relay.handle(asker.id, { type: 'mmo.request', to: ally.id, kind: 'battle' });
  const byCoop = take(asker, 'mmo.decline');
  ok(byCoop && byCoop.reason === 'busy', 'and declines a request');
  ok(take(ally, 'mmo.request') === null);
}

// Parties + ruleset arrived, but Turn.attempt still refuses the field.
// Leaving the record in battles with sim = null kept every player marked
// in a pairing that never sent battle_ready.
function testUnfightableFieldAborts() {
  const clock = makeClock();
  const relay = makeRelay(clock);
  const a = dial(relay, 'ANN');
  const b = dial(relay, 'BOB');
  const c = dial(relay, 'CAL');
  const record = relay.openMediatedBattle('bad-1', {
    mode: '1v1', hostId: a.id,
    memberIds: [a.id, b.id, c.id],
    sides: { a: [a.id, b.id], b: [c.id] },
  });
  record.ruleset = { chart: [[100]], seed: 7 };
  for (const player of [a, b, c]) {
    record.parties.set(player.id, { battle: 'bad-1', mons: [mon(90)] });
  }
  a.peer.outbox = [];
  b.peer.outbox = [];
  c.peer.outbox = [];
  ok(relay.clients.get(a.id).battleId === 'bad-1',
    'the seats were marked before assembly');
  ok(relay.tryStartSim(record) === false, 'an unfightable field opens no sim');
  ok(!relay.battles.has('bad-1'),
    'the record is cleared rather than left half-open');
  ok(relay.clients.get(a.id).battleId == null, 'and the host is unmarked');
  ok(relay.clients.get(b.id).battleId == null, 'and so is the guest');
  ok(relay.clients.get(c.id).battleId == null, 'and the third seat too');
  const outcome = take(a, 'mmo.battle_outcome');
  ok(outcome && outcome.outcome === 'draw' && outcome.reason === 'agree',
    'players hear it called off rather than waiting for battle_ready');
  const bobOut = take(b, 'mmo.battle_outcome');
  ok(bobOut && bobOut.reason === 'agree', 'both sides hear the abort');
  const calOut = take(c, 'mmo.battle_outcome');
  ok(calOut && calOut.reason === 'agree', 'every marked seat hears it');
}

// A REQUEST/RESPOND 1v1 still holds sessionId after abortMediatedBattle.
// Assembly failure has to drop that too, or busyNow keeps the pairing stuck.
function testUnfightableSessionReleasesPairing() {
  const clock = makeClock();
  const relay = makeRelay(clock);
  const a = dial(relay, 'ANN');
  const b = dial(relay, 'BOB');
  const session = openBattle(relay, a, b);
  const record = relay.battles.get(session.id);
  record.ruleset = { chart: [[100]] };
  record.parties.set(a.id, { battle: session.id, mons: [] });
  record.parties.set(b.id, { battle: session.id, mons: [mon(90)] });
  a.peer.outbox = [];
  b.peer.outbox = [];
  ok(relay.clients.get(a.id).sessionId === session.id, 'the pairing is live');
  ok(relay.matches.has(session.id), 'ranked paperwork existed for the pairing');
  ok(relay.tryStartSim(record) === false, 'an empty party opens no sim');
  ok(relay.clients.get(a.id).sessionId == null, 'the host is off the pairing');
  ok(relay.clients.get(b.id).sessionId == null, 'and so is the guest');
  ok(relay.clients.get(a.id).battleId == null, 'and unmarked for the fight');
  ok(!relay.matches.has(session.id), 'and the settlement record is dropped');
  relay.handle(a.id, { type: 'mmo.result', session: session.id, outcome: 'win' });
  relay.handle(b.id, { type: 'mmo.result', session: session.id, outcome: 'loss' });
  ok(!relay.matches.has(session.id), 'a leftover vote cannot resurrect it');
  const outcome = take(a, 'mmo.battle_outcome');
  ok(outcome && outcome.reason === 'agree', 'they hear it called off');
  ok(take(b, 'mmo.session_end') != null, 'the guest hears the pairing end');
}

// Same for a co-op group: abort alone left coopBattleId set.
function testUnfightableCoopReleasesGroup() {
  const clock = makeClock();
  const relay = makeRelay(clock);
  const a = dial(relay, 'ANN');
  const b = dial(relay, 'BOB');
  const id = relay.openCoopBattle('c-bad', [a.id, b.id],
    { mode: 'coop_npc', hostId: a.id });
  const record = relay.battles.get(id);
  record.ruleset = { chart: [[100]] };
  for (const seat of relay.seatsNeeded(record)) {
    record.parties.set(seat, { battle: id, mons: [mon(90)] });
  }
  record.parties.set(record.npcIds[0], { battle: id, mons: [] });
  relay.coopMatches.set(id, {
    a: [], b: [], reports: new Map(), everyone: [a.id, b.id],
    startedAt: clock.now(),
  });
  a.peer.outbox = [];
  ok(relay.clients.get(a.id).coopBattleId === id, 'the co-op group is live');
  ok(relay.tryStartSim(record) === false, 'an empty npc seat opens no sim');
  ok(relay.clients.get(a.id).coopBattleId == null, 'the group is released');
  ok(relay.clients.get(b.id).coopBattleId == null, 'both members');
  ok(!relay.coopBattles.has(id), 'and forgotten');
  ok(!relay.coopMatches.has(id), 'and the settlement record is dropped');
  const outcome = take(a, 'mmo.battle_outcome');
  ok(outcome && outcome.reason === 'agree', 'they hear it called off');
}

// A refused open must not leave a group, seat marks, or ranked paperwork.
function testRefusedCoopOpenLeavesNoPaperwork() {
  const clock = makeClock();
  const relay = makeRelay(clock);
  const a = dial(relay, 'ANN');
  const b = dial(relay, 'BOB');
  const c = dial(relay, 'CAL');
  const d = dial(relay, 'DEE');
  ok(relay.openCoopBattle('c-none', [], { mode: 'coop_pvp' }) == null,
    'an empty roster opens nothing');
  ok(!relay.coopBattles.has('c-none'), 'and leaves no group');
  ok(relay.clients.get(a.id).coopBattleId == null, 'and marks no seat');
  ok(!relay.coopMatches.has('c-none'), 'and files no paperwork');

  relay.coopAsks.set('c-miss', {
    asker: a.id,
    sideA: [a.id, b.id],
    sideB: [c.id, d.id],
    everyone: [],
    answers: new Set(),
    needed: 3,
    startedAt: clock.now(),
  });
  relay.startCoopBattle('c-miss');
  ok(!relay.coopMatches.has('c-miss'), 'a refused start files no settlement record');
  ok(!relay.coopBattles.has('c-miss'), 'and leaves no group');
  ok(!relay.battles.has('c-miss'), 'and opens no fight');
  ok(!relay.coopAsks.has('c-miss'), 'and the ask is torn down');
}

testBagProofs();
testMidFightMoveset();
testPvpMovesetDropped();
testBusyNowMediatedFight();
testHubBusyFields();
testUnfightableFieldAborts();
testUnfightableSessionReleasesPairing();
testUnfightableCoopReleasesGroup();
testRefusedCoopOpenLeavesNoPaperwork();

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

/*
 * Gen 1 / Gen 2 read paths are what they were before Gen 3. Gen 3 added a move
 * row keyed on `num` and two choice fields (`pass`, `dexCaught`); neither may
 * reach an older read. A stray `num` on a Gen 1 / Gen 2 row is ignored as it
 * always was -- rather than sending the row to the Gen 3 reader, which refuses
 * it for want of target / priority / flags -- and a stray `pass` on an older
 * choice is ignored rather than refusing the turn. Since wave 5 of
 * docs/plans/gen12-referee-gaps-fix.md a Gen 2 Metronome pool row's `num` (the
 * cart's move number, 1..NUM_ATTACKS2) and a Gen 2 choice's `pass` (Gold's
 * BATON PASS successor, read as Gen 3's) are read on Gold; a sheet's own rows
 * still leave `num` behind and Red ignores both. Twin of the same section in
 * tests/hub_battle.lua.
 */
function testGen12ReadPathsUnchanged() {
  const sanitize = require('./lib/sanitize.js');
  const sheet = mon(40);
  sheet.moves[0].num = 7;
  const clean = sanitize.cleanBattleMon(sheet);
  ok(clean, 'a Gen 1 sheet whose row carries a stray num still reads');
  ok(clean && clean.moves[0].id === 'm1', 'as the older row');
  ok(clean && clean.moves[0].num === undefined, 'with the stray field left behind');
  const gold = mon(40);
  gold.stats = { atk: 120, def: 40, spe: 80, spa: 80, spd: 80 };
  gold.moves[0].num = 7;
  const goldClean = sanitize.cleanBattleMon(gold);
  ok(goldClean && goldClean.generation === 2, 'a Gen 2 sheet with the same row reads too');
  ok(goldClean && goldClean.moves[0].num === undefined, 'in the older dialect');
  ok(sanitize.cleanBattleParty({ battle: 'b1', mons: [sheet] }, 1),
    'and a Gen 1 hub takes the party it sits in');
  const rules1 = sanitize.cleanBattleRuleset({ chart: [[100]], metronomePool: [sheet.moves[0]] }, 1);
  ok(rules1, 'a Gen 1 metronome pool row with a stray num reads');
  ok(rules1 && rules1.metronomePool[0].num === undefined, 'as the older row on Gen 1');
  const rules2 = sanitize.cleanBattleRuleset({ chart: [[100]], metronomePool: [sheet.moves[0]] }, 2);
  ok(rules2, 'a Gen 2 metronome pool row with a num reads');
  ok(rules2 && rules2.metronomePool[0].num === 7,
    "wave 5: ...and keeps it on Gen 2 (the cart's move number METRONOME's byte names)");
  const rulesNone = sanitize.cleanBattleRuleset({ chart: [[100]], metronomePool: [sheet.moves[0]] });
  ok(rulesNone, 'and on a ruleset that names no hub generation');
  ok(rulesNone && rulesNone.metronomePool[0].num === undefined, '...which reads it as the older row');

  const asked = {
    battle: 'b1', action: 'fight', move: 0, pass: 'far', dexCaught: 1,
  };
  for (const gen of [1, undefined]) {
    const c = sanitize.cleanBattleChoice(asked, gen);
    ok(c, `a choice with Gen 3 fields in it is still a choice (${gen})`);
    ok(c && c.pass === undefined, `whose stray pass is not read (${gen})`);
    ok(c && c.dexCaught === undefined, `nor its dex word (${gen})`);
  }
  ok(sanitize.cleanBattleChoice(asked, 2) === null,
    "wave 5: a Gen 2 hub reads Gold's BATON PASS `pass`, so an unreadable one refuses the choice");
  const passed = sanitize.cleanBattleChoice({
    battle: 'b1', action: 'fight', move: 0, pass: 2, dexCaught: 1,
  }, 2);
  ok(passed && passed.pass === 2, 'wave 5: ...a readable one is kept on Gen 2');
  ok(passed && passed.dexCaught === undefined, "wave 5: ...while the dex word stays Gen 3's");
  ok(sanitize.cleanBattleChoice(asked, 3) === null,
    'while a Gen 3 hub refuses the same fields unread');

  // On the hub: a Gen 1 fight files a turn whose choice carries a stray pass.
  const clock = makeClock();
  const relay = makeRelay(clock);
  const a = dial(relay, 'OLDA');
  const b = dial(relay, 'OLDB');
  const session = openBattle(relay, a, b);
  uploadAndReady(relay, a, b, session);
  relay.handle(a.id, {
    type: 'mmo.battle_choice', battle: session.id, action: 'fight', move: 0, pass: 'far',
  });
  ok(relay.battles.get(session.id).sim.byId.get(a.id).choice, 'a Gen 1 hub files that turn');

  // Events, when the reader names its generation.
  ok(sanitize.cleanBattleEvent({ battle: 'b1', seq: 1, t: 'ability' }, 1) === null,
    'a Gen 1 reader has no ability kind');
  ok(sanitize.cleanBattleEvent({ battle: 'b1', seq: 1, t: 'ability' }),
    '(which a reader naming none still draws)');
  const ev = sanitize.cleanBattleEvent({
    battle: 'b1', seq: 2, t: 'stat', slot: 0, side: 'a', target: 2, stage: 1, delta: 1, holding: 3,
  }, 2);
  ok(ev && ev.target === undefined && ev.delta === undefined
    && ev.holding === undefined, "a Gen 2 reader keeps none of Gen 3's other event fields");
  // ...but `stage` it reads now: a `stat` event's signed stage is the older
  // dialect's too (contract K10 of docs/plans/gen12-referee-gaps-fix.md).
  ok(ev.stage === 1, 'a Gen 2 reader keeps the signed stage (K10)');
  const mv = sanitize.cleanBattleEvent({
    battle: 'b1', seq: 3, t: 'moves', slot: 0, side: 'a', moves: [sheet.moves[0]],
  }, 1);
  ok(mv && mv.moves && mv.moves[0].id === 'm1', 'and reads a moves row in the older dialect');
}

testGen12ReadPathsUnchanged();

// ---------------------------------------------------------------------------
// Gen 3 (PROTOCOL 30): the hub referees on lib/battle3
// ---------------------------------------------------------------------------
//
// One Gen 3 hub seats FireRed, LeafGreen and Emerald, and a fight it brokers is
// resolved by lib/battle3 against the Gen 3 dialect of every upload
// (docs/plans/gen3-battle-sheet.md, contract C4): the ordered type table and
// the packed move pool, sheets with abilities and held items, bags keyed by
// numeric pret item id. tests/hub_battle.lua pins the same fights on the Lua
// hub, message for message. Every number is synthetic except the pret enum
// values the sheet contract names.

const sanitize = require('./lib/sanitize.js');

const CHART3 = [10, 12, 20, 11, 10, 20, 12, 11, 20, -1, -1, 0, 0, 7, 0];
const POOL3 = ['33:0:40:0:100:35:0:0:0:51:POOL_TAP', '52:4:40:10:100:25:10:0:0:18:POOL_SPARK'];

function move3(o) {
  const p = o || {};
  const row = {
    id: p.id || 'TAP3',
    num: p.num === undefined ? 33 : p.num,
    pp: p.pp === undefined ? 20 : p.pp,
    maxPp: p.maxPp === undefined ? 20 : p.maxPp,
    power: p.power === undefined ? 90 : p.power,
    type: p.type || 0,
    accuracy: p.accuracy === undefined ? 100 : p.accuracy,
    effect: p.effect || 0,
    chance: p.chance || 0,
    target: p.target || 0,
    priority: p.priority || 0,
    flags: p.flags === undefined ? 51 : p.flags,
  };
  if (p.name) row.name = p.name;
  return row;
}

function mon3(o) {
  const p = o || {};
  const sheet = {
    generation: 3,
    species: p.species || 'GAMMA',
    speciesNum: p.speciesNum || 1,
    level: p.level || 50,
    hp: p.hp === undefined ? 150 : p.hp,
    maxHp: p.maxHp || p.hp || 150,
    stats: {
      atk: p.atk || 120, def: p.def || 80, spe: p.spe || 90, spa: p.spa || 80, spd: p.spd || 80,
    },
    types: p.types || [0],
    ability: p.ability || 0,
    heldItem: p.heldItem || 0,
    holdEffect: p.holdEffect || 0,
    holdEffectParam: p.holdEffectParam || 0,
    gender: p.gender || 'M',
    friendship: 70,
    weight: 300,
    nature: 0,
    hiddenPower: { type: 1, power: 50 },
    beatUp: { atk: 60, def: 60 },
    moves: p.moves || [move3()],
  };
  if (p.catchRate !== undefined) sheet.catchRate = p.catchRate;
  return sheet;
}

const bruiser3 = () => mon3({
  atk: 400, def: 400, spe: 300, moves: [move3({ power: 200 })],
});
const glassjaw3 = () => mon3({
  species: 'DELTA', hp: 1, def: 5, atk: 10, spe: 1, moves: [move3({ power: 10 })],
});

function dial3(relay, name, version) {
  return dialGen3(relay, name, version || 'firered');
}

// dial() with a Gen 3 hello: a Gen 3 hub refuses a hello with no generation
// (missing is 1).
function dialGen3(relay, name, version) {
  const peer = { outbox: [], remoteAddress: '127.0.0.1' };
  peer.send = (msg) => peer.outbox.push(msg);
  peer.close = () => {};
  const id = relay.accept(peer);
  const playerId = testPlayerId(name);
  relay.handle(id, {
    type: 'mmo.hello',
    proto: PROTOCOL,
    name,
    sprite: 'OBJ_EVENT_GFX_RED_NORMAL',
    map: 'FR_PALLET_TOWN',
    x: 5,
    y: 5,
    facing: 'down',
    generation: 3,
    version,
    playerId,
  });
  return { id: playerId, peer, name, ephemeralId: id };
}

function eventText(player, needle) {
  return player.peer.outbox.some((m) => m.type === 'mmo.battle_event'
    && typeof m.text === 'string' && m.text.includes(needle));
}

// The Node half of the Lua fightItOut: answer every open turn from both seats.
function fightOut(relay, battle, players, limit) {
  for (let turn = 0; turn < (limit || 20); turn += 1) {
    for (const p of players) {
      relay.handle(p.id, {
        type: 'mmo.battle_choice', battle, action: 'fight', move: 0,
      });
    }
    if (!relay.battles.has(battle)) return true;
  }
  return false;
}

function testGen3SimSelection() {
  const battle3 = require('./lib/battle3');
  ok(battle3.GENERATION === 3, 'battle3 index GENERATION===3');
  const relay = new Relay({ generation: 3, maxPlayers: 8, log: quiet });
  ok(relay.generation === 3, 'generation:3 is stored');
  ok(relay.Turn === battle3.Turn, 'generation 3 loads lib/battle3 Turn');
  ok(relay.Effects === sanitize.effectsFor(3),
    "and proves bags against sanitize's Gen 3 catalog");
  ok(relay.Effects.itemEffect('13') != null, 'a numeric-string id reads the catalog');
  ok(relay.Effects.itemEffect(350).noConsume === true, 'Poke Flute is never spent');
  ok(relay.Effects.itemEffect(5) == null, 'the Safari Ball is not a mediated item');
}

function testGen3OneVOne() {
  const clock = makeClock();
  const relay = makeRelay(clock, { generation: 3 });
  relay.forceBattleSeed = 7;
  const a = dial3(relay, 'ANN', 'firered');
  const b = dial3(relay, 'BOB', 'emerald');
  ok(take(a, 'mmo.welcome') && take(b, 'mmo.welcome'),
    'FireRed and Emerald meet on one Gen 3 hub');
  relay.handle(a.id, { type: 'mmo.request', to: b.id, kind: 'battle' });
  relay.handle(b.id, {
    type: 'mmo.respond', to: a.id, kind: 'battle', accept: true,
  });
  const session = take(a, 'mmo.session');
  ok(session && relay.battles.has(session.id), 'the battle session opens a mediated record');
  const id = session.id;
  const record = relay.battles.get(id);

  relay.handle(a.id, { type: 'mmo.battle_ruleset', chart: [[100]] });
  ok(!record.ruleset || !record.ruleset.typeTable,
    'a percent chart carries no ordered table on a Gen 3 hub');
  relay.handle(a.id, { type: 'mmo.battle_ruleset', typeTable: [10, 12] });
  ok(!record.ruleset || !record.ruleset.typeTable, 'a triple list cut mid-row is refused');
  relay.handle(a.id, {
    type: 'mmo.battle_ruleset', generation: 3, typeTable: CHART3, movePool: POOL3,
  });
  ok(record.ruleset && record.ruleset.typeTable.length === CHART3.length,
    'the ordered chart lands whole');
  ok(record.ruleset.movePool[0] === POOL3[0], 'and the packed pool survives canonical');

  relay.handle(a.id, {
    type: 'mmo.battle_party', battle: id, mons: [bruiser3()], bag: [{ id: 5, count: 1 }],
  });
  ok(!record.parties.has(a.id), 'a bag naming an unmediated item refuses the party');
  const hurt = bruiser3();
  hurt.hp = 100;
  relay.handle(a.id, {
    type: 'mmo.battle_party',
    battle: id,
    mons: [hurt],
    bag: [{ id: 13, count: 2, name: 'TONIC' }, { id: '350', count: 1 }],
  });
  const noWeight = glassjaw3();
  delete noWeight.weight;
  relay.handle(b.id, { type: 'mmo.battle_party', battle: id, mons: [noWeight] });
  ok(!record.parties.has(b.id), 'an upload missing a Gen 3 formula input is refused');
  relay.handle(b.id, { type: 'mmo.battle_party', battle: id, mons: [glassjaw3()] });

  ok(record.sim, 'the message that completes the set opens a Gen 3 fight');
  ok(record.bags.get(a.id)['13'] === 2, 'the hub holds the bag keyed as a choice spells it');
  ok(record.sim.byId.get(a.id).bag[13] === 2, 'and the sim holds it by numeric id');
  const ready = take(a, 'mmo.battle_ready');
  ok(ready && sanitize.cleanBattleReady(ready), 'battle_ready goes out');
  const opening = a.peer.outbox.filter((m) => m.type === 'mmo.battle_event');
  ok(opening.every((m) => sanitize.cleanBattleEvent(m)),
    'every opening event survives the client sanitiser');
  ok(opening.some((m) => m.t === 'send'), 'and the opening sends are among them');

  relay.handle(b.id, {
    type: 'mmo.battle_choice', battle: id, action: 'item', item: '13',
  });
  ok(!record.sim.byId.get(b.id).choice, 'an item with no stack is refused');
  relay.handle(a.id, {
    type: 'mmo.battle_choice', battle: id, action: 'item', item: '13', slot: 0,
  });
  ok(record.sim.byId.get(a.id).choice, 'a proved Gen 3 potion is filed');
  ok(record.bagHold[a.id] === '13', 'and held, not spent');
  relay.handle(a.id, { type: 'mmo.battle_choice', battle: id, action: 'cancel' });
  ok(record.bagHold[a.id] === undefined, 'cancel drops the hold');
  ok(record.bags.get(a.id)['13'] === 2, 'without spending');
  relay.handle(a.id, {
    type: 'mmo.battle_choice', battle: id, action: 'item', item: '13', slot: 0,
  });
  a.peer.outbox = [];
  relay.handle(b.id, {
    type: 'mmo.battle_choice', battle: id, action: 'fight', move: 0,
  });
  ok(record.bags.get(a.id)['13'] === 1, 'the turn resolves and one potion is gone');
  ok(eventText(a, 'ANN used TONIC!'), 'narrated under the name the bag uploaded');

  if (record.sim && record.sim.phase === 'choice') {
    relay.handle(a.id, {
      type: 'mmo.battle_choice', battle: id, action: 'item', item: '350',
    });
    ok(record.sim.byId.get(a.id).choice, 'the flute is proved present');
    relay.handle(b.id, {
      type: 'mmo.battle_choice', battle: id, action: 'fight', move: 0,
    });
    ok(record.bags.get(a.id)['350'] === 1, 'and is still in the bag after the turn');
  }

  ok(fightOut(relay, id, [a, b]), 'the fight reaches an end');
  const outcome = take(a, 'mmo.battle_outcome');
  ok(outcome && sanitize.cleanBattleOutcome(outcome), 'the outcome goes out, sanitisable');
  ok(outcome.reason === 'ko', 'a KO');
  ok(outcome.winners[0] === a.id, 'for the side that hit');
  ok(take(b, 'mmo.battle_outcome'), 'and the loser hears it');
  ok(!relay.battles.has(id), 'the record is settled and forgotten');
}

function testGen3CoopNpc() {
  const clock = makeClock();
  const relay = makeRelay(clock, { generation: 3 });
  relay.forceBattleSeed = 3;
  const a = dial3(relay, 'ANN');
  const b = dial3(relay, 'BOB', 'leafgreen');
  relay.openCoopBattle('g3c', [a.id, b.id], { mode: 'coop_npc', hostId: a.id });
  const record = relay.battles.get('g3c');
  relay.handle(a.id, { type: 'mmo.battle_ruleset', typeTable: CHART3 });
  relay.handle(a.id, {
    type: 'mmo.battle_party', battle: 'g3c', side: 'a', mons: [bruiser3()],
  });
  relay.handle(b.id, {
    type: 'mmo.battle_party', battle: 'g3c', side: 'a', mons: [bruiser3()],
  });
  ok(record.sim === null, 'the trainer still owes a team');
  relay.handle(a.id, {
    type: 'mmo.battle_party',
    battle: 'g3c',
    side: 'b',
    mons: [glassjaw3(), glassjaw3()],
    bag: [{ id: 22, count: 1, name: 'KIT TONIC' }],
  });
  ok(record.sim, 'the host\'s side b completes the Gen 3 field');
  const bagA = record.sim.byId.get(record.npcIds[0]).bag;
  const bagB = record.sim.byId.get(record.npcIds[1]).bag;
  ok(bagA && bagA[22] === 1, "the trainer's one potion, by numeric id");
  ok(bagA === bagB, 'one table on both seats: spending it once spends it');
  ok(record.bags.get(record.npcIds[1])['22'] === 1, 'and the hub sheet aliases it too');
  // The kit's names travel with the shared bag: only the first seat was handed
  // it, so the second used to open with no names and narrate "used an item!".
  const second = record.sim.byId.get(record.npcIds[1]);
  ok(second.bagNames === record.sim.byId.get(record.npcIds[0]).bagNames,
    "the second seat shares the first seat's bag names");
  ok(second.bagNames[22] === 'KIT TONIC', 'so it knows the potion by the uploaded name');
  record.sim.drainEvents();
  second.choice = { action: 'item', item: 22 };
  record.sim._useItem(second);
  ok(record.sim.drainEvents().some((event) => typeof event.text === 'string'
    && event.text.includes('TRAINER used KIT TONIC!')),
  'and a potion drunk from the second seat is narrated by name');
  second.choice = null;

  a.peer.outbox = [];
  ok(fightOut(relay, 'g3c', [a, b]), 'the trainer answers at once and the fight runs out');
  const outcome = take(a, 'mmo.battle_outcome');
  ok(outcome && sanitize.cleanBattleOutcome(outcome), 'outcome sanitisable');
  ok(outcome.outcome === 'win', 'the two players win');
  ok(outcome.losers[0] === record.npcIds[0], "over the trainer's seats");
}

function testGen3WildCatch() {
  const clock = makeClock();
  const relay = makeRelay(clock, { generation: 3 });
  relay.forceBattleSeed = 11;
  const a = dial3(relay, 'ANN', 'emerald');
  const record = relay.openMediatedBattle('g3w', {
    mode: 'wild', hostId: a.id, memberIds: [a.id],
  });
  ok(record, 'a Gen 3 wild record opens');
  relay.handle(a.id, {
    type: 'mmo.battle_ruleset', typeTable: CHART3, weather: 'RAIN', terrain: 3, underwater: true,
  });
  ok(record.ruleset && record.ruleset.weather === 'RAIN' && record.ruleset.underwater,
    'a wild ruleset keeps its weather and field');
  relay.handle(a.id, {
    type: 'mmo.battle_party', battle: 'g3w', side: 'a', mons: [mon3()], bag: [{ id: 1, count: 1 }],
  });
  relay.handle(a.id, {
    type: 'mmo.battle_party',
    battle: 'g3w',
    side: 'b',
    mons: [mon3({ species: 'EPSILON', catchRate: 45 })],
  });
  ok(record.sim, 'the wild fight opens');
  ok(record.sim.field.weather === 'RAIN', "under the overworld's rain");
  ok(!record.sim.byId.get(record.npcIds[0]).bag, 'wildlife carries no bag');
  a.peer.outbox = [];
  relay.handle(a.id, {
    type: 'mmo.battle_choice', battle: 'g3w', action: 'item', item: '1', dexCaught: false,
  });
  const ball = a.peer.outbox.find((m) => m.type === 'mmo.battle_event' && m.t === 'ball');
  ok(ball && sanitize.cleanBattleEvent(ball) && ball.amount === 4 && ball.text === '1',
    'one ball event: four shakes, the ball named by its id');
  const outcome = take(a, 'mmo.battle_outcome');
  const clean = outcome && sanitize.cleanBattleOutcome(outcome);
  ok(clean, 'the catch outcome survives the client sanitiser');
  ok(clean.reason === 'catch', 'reason catch');
  ok(clean.catcher === a.id, 'caught by the thrower');
  ok(clean.caught && clean.caught.species === 'EPSILON', 'the wild sheet rides along');
  ok(clean.caught.ball === 1, 'with the ball it went into');
  ok(clean.caught.generation === 3, 'read in the Gen 3 dialect');
}

// A wild fight: the only kind a learn is heard in (relay LEARN_MODES --
// pokeemerald / pokefirered Cmd_getexp gives no experience under
// BATTLE_TYPE_LINK, so no Gen 3 cart learns in a link battle either).
function testGen3MidFightMoveset() {
  const clock = makeClock();
  const relay = makeRelay(clock, { generation: 3 });
  const a = dial3(relay, 'ANN');
  const id = 'g3l';
  relay.openCoopBattle(id, [a.id], { mode: 'wild', hostId: a.id });
  relay.handle(a.id, { type: 'mmo.battle_ruleset', battle: id, typeTable: CHART3 });
  relay.handle(a.id, {
    type: 'mmo.battle_party', battle: id, side: 'a', mons: [mon3()],
  });
  relay.handle(a.id, {
    type: 'mmo.battle_party', battle: id, side: 'b', mons: [mon3()],
  });
  const record = relay.battles.get(id);
  const fighter = record.sim.byId.get(a.id);
  const learned = move3({
    id: 'SHIELD3', num: 182, power: 0, accuracy: 0, effect: 111, target: 16, priority: 3, flags: 0,
  });
  relay.handle(a.id, {
    type: 'mmo.battle_moveset', battle: id, mon: 0, moves: [move3(), learned],
  });
  const row = fighter.mons[0].moves[1];
  ok(row && row.num === 182, 'the learned row keeps its move number');
  ok(row.priority === 3, 'its priority');
  ok(row.target === 16, 'and its target');
  ok(fighter.b.moves === fighter.mons[0].moves, 'the active battler fights with the new list');
  ok(fighter.mons[0].moves[0].pp === 20, "the unchanged slot keeps the hub's PP");
}

// ...while a Gen 3 1v1 hears none: a one-slot "learn" there would be any row
// the sender liked (moveRow3 takes a new id's row whole) against another
// player's monster.
function testGen3PvpMovesetDropped() {
  const relay = makeRelay(makeClock(), { generation: 3 });
  const a = dial3(relay, 'ANN');
  const b = dial3(relay, 'BOB');
  relay.handle(a.id, { type: 'mmo.request', to: b.id, kind: 'battle' });
  relay.handle(b.id, {
    type: 'mmo.respond', to: a.id, kind: 'battle', accept: true,
  });
  const { id } = take(a, 'mmo.session');
  relay.handle(a.id, { type: 'mmo.battle_ruleset', battle: id, typeTable: CHART3 });
  relay.handle(a.id, { type: 'mmo.battle_party', battle: id, mons: [mon3()] });
  relay.handle(b.id, { type: 'mmo.battle_party', battle: id, mons: [mon3()] });
  const record = relay.battles.get(id);
  const fighter = record.sim.byId.get(a.id);
  const before = fighter.mons[0].moves;
  relay.handle(a.id, {
    type: 'mmo.battle_moveset',
    battle: id,
    mon: 0,
    moves: [move3(), move3({
      id: 'NUKE3', num: 120, power: 250, priority: 5,
    })],
  });
  ok(fighter.mons[0].moves === before && before.length === 1, 'gen 3 pvp: a 1v1 learn reaches nothing');
  ok(fighter.b.moves === before, 'gen 3 pvp: ...and the battler fights with the list it brought');
}

function testGen3DialectAndLimits() {
  // A worst-case ruleset: the full ordered table and a full pool of long ids.
  const tt = [];
  for (let i = 1; i <= sanitize.BATTLE_TYPE_TABLE3_MAX; i += 1) tt.push(i % 18, (i * 7) % 18, 20);
  const pool = [];
  for (let i = 1; i <= sanitize.BATTLE_MOVE_POOL3_MAX; i += 1) {
    pool.push([(i % 354) + 1, 213, 255, 17, 100, 99, 100, 255, -7, 63,
      'X'.repeat(36) + String(i).padStart(4, '0')].join(':'));
  }
  const rules = {
    type: 'mmo.battle_ruleset',
    battle: 'b1',
    generation: 3,
    typeTable: tt,
    movePool: pool,
    terrain: 9,
    weather: 'HAIL',
  };
  ok(sanitize.payloadOk(rules), 'a full Gen 3 ruleset is inside PAYLOAD_MAX_NODES');
  const line = JSON.stringify(rules).length;
  ok(line < sanitize.MAX_LINE, `and one line of it (${line} bytes) is inside MAX_LINE`);
  const clean = sanitize.cleanBattleRuleset(rules, 3);
  ok(clean && clean.movePool.length === sanitize.BATTLE_MOVE_POOL3_MAX,
    'and the sanitiser takes it whole');
  ok(sanitize.cleanBattleRuleset({ typeTable: tt, movePool: pool.concat([pool[0]]) }, 3)
    .movePool.length === sanitize.BATTLE_MOVE_POOL3_MAX, 'a pool past the cap keeps the cap');
  ok(sanitize.cleanBattleRuleset({
    typeTable: new Array(3 * (sanitize.BATTLE_TYPE_TABLE3_MAX + 1)).fill(0),
  }, 3) === null, 'a table past its cap is refused');
  ok(sanitize.cleanBattleRuleset({ typeTable: [0, -1, 10] }, 3) === null,
    'half a sentinel is refused');
  ok(sanitize.cleanBattleRuleset({ typeTable: CHART3, movePool: ['1:2:3'] }, 3) === null,
    'a pool entry that does not parse refuses the ruleset');
  ok(sanitize.cleanBattleRuleset({ typeTable: CHART3, weather: 'FOG' }, 3) === null,
    'an unknown weather refuses it');
  ok(sanitize.cleanBattleRuleset({
    generation: 3, typeTable: CHART3, movePool: ['+7:0:40:0:100:10:0:0:-0:3:X'],
  }) === null, "a signed-plus integer is not the sim's grammar");
  ok(sanitize.cleanBattleRuleset({
    generation: 3, movePool: ['7:0:40:0:100:10:0:0:-0:3:X'],
  }).movePool[0] === '7:0:40:0:100:10:0:0:0:3:X', 'and -0 is written back as 0');

  const mons = [];
  for (let i = 1; i <= 6; i += 1) {
    const m = mon3({
      moves: [move3(), move3({ id: 'B' }), move3({ id: 'C' }), move3({ id: 'D' })],
    });
    m.speciesId = String(i);
    m.slot = i - 1;
    m.abilityName = 'ABILITYNAME';
    m.itemName = 'ITEMNAME';
    m.ivs = {
      hp: 31, atk: 31, def: 31, spe: 31, spa: 31, spd: 31,
    };
    m.evs = {
      hp: 255, atk: 255, def: 0, spe: 0, spa: 0, spd: 0,
    };
    m.personality = 4294967295;
    m.otId = 12345;
    mons.push(m);
  }
  const ids = [1, 2, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23,
    24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41];
  const bag = ids.map((n) => ({ id: n, count: 99, name: `ITEM${n}` }));
  const party = {
    type: 'mmo.battle_party', battle: 'b1', generation: 3, mons, bag,
  };
  ok(sanitize.payloadOk(party), 'a full Gen 3 party is inside PAYLOAD_MAX_NODES');
  ok(JSON.stringify(party).length < sanitize.MAX_LINE, 'and inside MAX_LINE');
  const cp = sanitize.cleanBattleParty(party, 3);
  ok(cp && cp.mons.length === 6 && cp.bag.length === ids.length, 'and sanitises whole');

  const noAbility = mon3();
  delete noAbility.ability;
  ok(sanitize.cleanBattleMon(noAbility) === null, 'a Gen 3 sheet without an ability is refused');
  const badGender = mon3();
  badGender.gender = 'X';
  ok(sanitize.cleanBattleMon(badGender) === null, 'a gender outside M/F/U is refused');
  const caught = mon3();
  delete caught.weight;
  delete caught.hiddenPower;
  delete caught.beatUp;
  ok(sanitize.cleanBattleMon(caught), 'a caught sheet without the upload-only inputs still reads');
  ok(sanitize.cleanBattleParty({ battle: 'b1', mons: [caught] }, 3) === null,
    'but an upload without them does not');
  ok(sanitize.cleanBattleParty({ battle: 'b1', mons: [mon3()], generation: 2 }, 3) === null,
    'a party claiming another generation is refused on a Gen 3 hub');
  const mixed = {
    generation: 2,
    species: 'OLDER',
    level: 50,
    hp: 100,
    maxHp: 100,
    stats: {
      atk: 50, def: 50, spe: 50, spa: 50, spd: 50,
    },
    moves: [{
      id: 'thump', pp: 20, power: 200, accuracy: 255, type: 0, effect: 0, chance: 0,
    }],
  };
  ok(sanitize.cleanBattleMon(mixed), '(a well-formed Gen 2 sheet on its own)');
  ok(sanitize.cleanBattleParty({ battle: 'b1', generation: 3, mons: [mon3(), mixed] }) === null,
    'and a Gen 3 party with a Gen 2 sheet in it is refused');
  ok(sanitize.cleanBattleBag({ 13: 2, 22: 1 }, 3)[0].id === 13,
    'the map form reads numeric-string keys');
  ok(sanitize.cleanBattleBag([{ id: '0x0D', count: 1 }], 3) === null, 'a hex id is not an item id');
  ok(sanitize.cleanBattleBag([{ id: 13, count: 1 }, { id: '13', count: 1 }], 3) === null,
    'the same item twice is refused');

  // Gen 3's two choice fields are read on a Gen 3 hub.
  const c = sanitize.cleanBattleChoice({
    battle: 'b1', action: 'fight', move: 0, pass: 2,
  }, 3);
  ok(c && c.pass === 2, 'a Baton Pass destination rides the fight choice');
  ok(sanitize.cleanBattleChoice({
    battle: 'b1', action: 'fight', move: 0, pass: 6,
  }, 3) === null, 'outside the party it is refused');
  const ic = sanitize.cleanBattleChoice({
    battle: 'b1', action: 'item', item: '9', dexCaught: true,
  }, 3);
  ok(ic && ic.dexCaught === true, "Repeat Ball's dex word rides the item choice");
  ok(sanitize.cleanBattleChoice({
    battle: 'b1', action: 'item', item: '9', dexCaught: 1,
  }, 3) === null, 'and only as a boolean');
  const ev = sanitize.cleanBattleEvent({
    battle: 'b1', seq: 3, t: 'stat', slot: 0, side: 'a', text: 'ATK fell', stat: 'atk', stage: -2, delta: -2,
  });
  ok(ev && ev.stat === 'atk' && ev.stage === -2 && ev.delta === -2,
    'a Gen 3 stat event keeps its signed stage and delta');
  const held = sanitize.cleanBattleEvent({
    battle: 'b1', seq: 4, t: 'held', slot: 3, side: 'b', mon: 0, amount: 139, holding: 0, text: 'BERRY',
  });
  ok(held && held.holding === 0 && held.amount === 139, 'a held event keeps what is left held');
  const anim = sanitize.cleanBattleEvent({
    battle: 'b1', seq: 5, t: 'anim', slot: 0, side: 'a', text: 'SWEEP', target: 4, spread: 1,
  });
  ok(anim && anim.target === 4 && anim.spread === 1, 'an anim keeps its target and spread');
  const ball = sanitize.cleanBattleEvent({
    battle: 'b1', seq: 6, t: 'ball', slot: 0, side: 'a', target: 3, amount: 2, text: '4',
  });
  ok(ball && ball.text === '4', 'a ball names its id like an item does');
  for (const kind of ['ability', 'weather', 'form', 'sub']) {
    ok(sanitize.cleanBattleEvent({ battle: 'b1', seq: 7, t: kind }), `kind ${kind} is in the vocabulary`);
  }
  const mv = sanitize.cleanBattleEvent({
    battle: 'b1', seq: 8, t: 'moves', slot: 0, side: 'a', moves: [move3()],
  });
  ok(mv && mv.moves && mv.moves[0].num === 33, "a Gen 3 moves event keeps its rows' numbers");

  // Wire.int's reading, spelled out: LuaJIT's tonumber, not JS's Number.
  const { luaNumber, luaInt, luaList } = sanitize;
  ok(luaNumber('-0x1') === -1 && luaNumber('+0x10') === 16, 'a sign leads a hex number, as in LuaJIT');
  ok(luaNumber('0x1.8p1') === 3 && luaNumber('0b11') === 3, 'hex fractions and binary read as LuaJIT reads them');
  ok(luaNumber('\u00a012') === null && luaNumber('12\u00a0') === null,
    'a no-break space is not whitespace to Lua');
  ok(luaNumber(' \t12\n') === 12, 'ASCII whitespace is');
  ok(luaNumber('1e-9999999') === null, 'a written exponent past 2^20 is no number at all');
  ok(luaInt(true, 0, 5) === null && luaInt('', 0, 5) === null && luaInt([3], 0, 5) === null,
    'true, the empty string and a list are not integers');
  ok(sanitize.cleanBattleChoice({ battle: 'b1', action: 'fight', move: 0, pass: true }, 3) === null,
    'so a Gen 3 pass of true is refused, as the Lua hub refuses it');

  // Lists as the Lua hub is handed them: the engine's Json.decode closes a null
  // element up and stores nothing for a null value.
  const closed = luaList([10, null, 12]);
  ok(closed && closed.length === 2 && closed[1] === 12, 'a null element is closed up');
  ok(luaList({}).length === 0 && luaList({ a: null }).length === 0, 'an empty (or all-null) object is the empty list');
  ok(luaList({ a: 1 }) === null, 'any other object is not a list');
  const hole = sanitize.cleanBattleRuleset(
    JSON.parse('{"typeTable":[10,12,20,null,11,10,20,12,11,20,-1,-1,0,0,7,0]}'), 3,
  );
  ok(hole && hole.typeTable.length === CHART3.length, 'a null between rows leaves the rows around it');
  ok(sanitize.cleanBattleRuleset(
    JSON.parse('{"typeTable":[10,12,null,11,10,20,12,11,20,-1,-1,0,0,7,0]}'), 3,
  ) === null, 'and a null in place of a cell refuses the chart');
  const nullBag = sanitize.cleanBattleBag(JSON.parse('{"13":2,"22":null}'), 3);
  ok(nullBag && nullBag.length === 1, 'a null count in a map bag is no entry at all');
  ok(sanitize.cleanBattleRuleset({ typeTable: CHART3, specialTypes: { a: 1 } }, 3) === null,
    'an object where the special-type list belongs is refused');
  ok(sanitize.cleanBattleRuleset({ typeTable: CHART3, specialTypes: {} }, 3),
    'while the empty object is the empty list, as it is to the Lua hub');
}

/*
 * Gen 3 Pay Day and the holders-only exp fact (sheet doc §1, §7.1). A 2v2
 * against a trainer: ANN's PAYER scatters coins every turn; BOB's BOOMER blows
 * itself up to take the first trainer mon with it, so BOB's seat fought that
 * knockout with nobody left standing who did -- the holders-only fact
 * (`participants` 0, no `mon`) goes to it, while ANN's fighter is paid as the
 * one participant. BOB sends his second mon, PAYER finishes the second trainer
 * mon, and the outcome carries the coins of all three Pay Days to both players.
 * Twin of the block in tests/hub_battle.lua.
 */
const IDLE3 = {
  id: 'IDLE', num: 150, effect: 85, power: 0, target: 16, flags: 0,
};

function testGen3PayDayAndHoldersOnly() {
  const clock = makeClock();
  const relay = makeRelay(clock, { generation: 3 });
  relay.forceBattleSeed = 1;
  const a = dial3(relay, 'ANN');
  const b = dial3(relay, 'BOB', 'emerald');
  relay.openCoopBattle('g3pay', [a.id, b.id], { mode: 'coop_npc', hostId: a.id });
  const record = relay.battles.get('g3pay');
  relay.handle(a.id, { type: 'mmo.battle_ruleset', battle: 'g3pay', typeTable: CHART3 });
  relay.handle(a.id, {
    type: 'mmo.battle_party',
    battle: 'g3pay',
    side: 'a',
    mons: [mon3({
      species: 'PAYER',
      level: 40,
      spe: 300,
      atk: 50,
      moves: [move3({
        id: 'COINS', num: 6, effect: 34, power: 20, chance: 100,
      })],
    })],
  });
  relay.handle(b.id, {
    type: 'mmo.battle_party',
    battle: 'g3pay',
    side: 'a',
    mons: [
      mon3({
        species: 'BOOMER',
        spe: 200,
        atk: 999,
        moves: [move3({
          id: 'BLAST', num: 153, effect: 7, power: 250,
        })],
      }),
      mon3({
        species: 'SHARER', heldItem: 182, holdEffect: 25, moves: [move3(IDLE3)],
      }),
    ],
  });
  relay.handle(a.id, {
    type: 'mmo.battle_party',
    battle: 'g3pay',
    side: 'b',
    mons: [
      mon3({
        species: 'TRAINEE', def: 5, spe: 1, moves: [move3(IDLE3)],
      }),
      mon3({
        species: 'TRAINEE', def: 5, spe: 1, moves: [move3(IDLE3)],
      }),
    ],
  });
  ok(record.sim, 'pay day: the Gen 3 coop_npc field opens');
  a.peer.outbox = [];
  b.peer.outbox = [];

  const exps = [];
  let outcome = null;
  for (let turn = 0; turn < 8; turn += 1) {
    if (!relay.battles.has('g3pay')) break;
    if (record.sim.byId.get(b.id).mustReplace) {
      relay.handle(b.id, {
        type: 'mmo.battle_choice', battle: 'g3pay', action: 'switch', slot: 1,
      });
    }
    relay.handle(a.id, {
      type: 'mmo.battle_choice', battle: 'g3pay', action: 'fight', move: 0,
    });
    relay.handle(b.id, {
      type: 'mmo.battle_choice', battle: 'g3pay', action: 'fight', move: 0,
    });
    for (const msg of takeAll(a, 'mmo.battle_event')) {
      if (msg.t === 'exp') exps.push(msg);
    }
    outcome = take(a, 'mmo.battle_outcome');
    if (outcome) break;
  }

  const first = exps.find((e) => e.slot === 0);
  const holders = exps.find((e) => e.slot === 1 && e.participants === 0);
  ok(first && first.participants === 1, 'pay day: the fighter still standing is the one participant');
  ok(first.mon === 0, 'pay day: ...and names its party index');
  ok(holders, 'pay day: the seat whose fighter fell gets the holders-only fact');
  ok(holders.mon === undefined, 'pay day: ...with no mon (nobody of it that fought stands)');
  const clean = sanitize.cleanBattleEvent(holders, 3);
  ok(clean && clean.participants === 0, 'pay day: a Gen 3 reader keeps the zero');
  ok(clean.mon === undefined, 'pay day: ...and still no mon');
  const older = sanitize.cleanBattleEvent(holders, 2);
  ok(older && older.participants === undefined,
    'pay day: a Gen 2 reader drops the zero, as it always has');

  ok(outcome, "pay day: the trainer's side falls");
  ok(outcome.outcome === 'win', 'pay day: the players win');
  ok(outcome.reason === 'ko', 'pay day: by knockout');
  ok(outcome.payDay === 600, 'pay day: three Pay Days at level 40 is 3 x 200 coins');
  const atBob = take(b, 'mmo.battle_outcome');
  ok(atBob && atBob.payDay === 600, 'pay day: both players on side a hear the coins');
  const read = sanitize.cleanBattleOutcome(outcome, 3);
  ok(read && read.payDay === 600, 'pay day: the Gen 3 outcome reader keeps it');
  // An older reader reads it too since contract K11 (Red and Gold report their
  // own Pay Day coins), under its own cart's PAYDAY12_MAX bound.
  ok(sanitize.cleanBattleOutcome(outcome, 1).payDay === 600,
    'pay day: a Gen 1 reader reads it too (K11)');
  ok(!relay.battles.has('g3pay'), 'pay day: the record settles and clears');
}

// ...and a fight between players pays nobody: the coins are counted, the
// outcome carries none (link rules), and neither does a Gen 1 hub's.
function testGen3PvpPaysNoPayDay() {
  const clock = makeClock();
  const relay = makeRelay(clock, { generation: 3 });
  relay.forceBattleSeed = 1;
  const a = dial3(relay, 'ANN');
  const b = dial3(relay, 'BOB', 'leafgreen');
  const session = openBattle(relay, a, b);
  relay.handle(a.id, { type: 'mmo.battle_ruleset', battle: session.id, typeTable: CHART3 });
  relay.handle(a.id, {
    type: 'mmo.battle_party',
    battle: session.id,
    mons: [mon3({
      species: 'PAYER',
      level: 40,
      spe: 300,
      atk: 400,
      moves: [move3({
        id: 'COINS', num: 6, effect: 34, power: 60, chance: 100,
      })],
    })],
  });
  relay.handle(b.id, {
    type: 'mmo.battle_party',
    battle: session.id,
    mons: [mon3({
      species: 'DELTA', def: 5, spe: 1, moves: [move3(IDLE3)],
    })],
  });
  const record = relay.battles.get(session.id);
  let outcome = null;
  for (let turn = 0; turn < 6; turn += 1) {
    if (!relay.battles.has(session.id)) break;
    relay.handle(a.id, {
      type: 'mmo.battle_choice', battle: session.id, action: 'fight', move: 0,
    });
    relay.handle(b.id, {
      type: 'mmo.battle_choice', battle: session.id, action: 'fight', move: 0,
    });
    outcome = take(a, 'mmo.battle_outcome') || take(b, 'mmo.battle_outcome');
    if (outcome) break;
  }
  ok(record.sim.snapshot().payDay.a > 0, 'pvp pay day: the referee counted the coins');
  ok(outcome && outcome.outcome === 'win', 'pvp pay day: the fight ends');
  ok(outcome.payDay === undefined, 'pvp pay day: and the outcome pays nobody');

  const gen1 = makeRelay(makeClock());
  const a1 = dial(gen1, 'ANN');
  const b1 = dial(gen1, 'BOB');
  gen1.openCoopBattle('g1c', [a1.id, b1.id], { mode: 'coop_npc', hostId: a1.id });
  gen1.handle(a1.id, { type: 'mmo.battle_ruleset', chart: [[100]] });
  gen1.handle(a1.id, {
    type: 'mmo.battle_party', battle: 'g1c', side: 'a', mons: [mon(200)],
  });
  gen1.handle(b1.id, {
    type: 'mmo.battle_party', battle: 'g1c', side: 'a', mons: [mon(200)],
  });
  gen1.handle(a1.id, {
    type: 'mmo.battle_party', battle: 'g1c', side: 'b', mons: [mon(10, 1), mon(10, 1)],
  });
  let g1 = null;
  for (let turn = 0; turn < 30 && !g1; turn += 1) {
    if (!gen1.battles.has('g1c')) break;
    for (const player of [a1, b1]) {
      gen1.handle(player.id, {
        type: 'mmo.battle_choice', battle: 'g1c', action: 'fight', move: 0,
      });
    }
    g1 = take(a1, 'mmo.battle_outcome') || take(b1, 'mmo.battle_outcome');
  }
  ok(g1 && g1.outcome === 'win', 'gen 1 coop_npc: the players win');
  ok(Object.keys(g1).sort().join(',') === 'battle,losers,outcome,reason,type,winners',
    'gen 1 coop_npc: the outcome is the fields it always was, no payDay');
}

// Whose cart: each human seat's `family` is the hub's word, from its hello.
//
// Obedience has one rule that differs by cart (docs/plans/gen3-badge-rules.md
// §1.2): Focus Punch skips the random-move branch on FireRed / LeafGreen and
// not on Emerald, so the referee reads a fighter entry's `family`. One Gen 3
// hub seats both carts, and a hub that left the field off played every Emerald
// mon by FireRed's rule. The hub stamps each human seat with the cart its own
// hello named; a party claiming a family is not read; an NPC seat gets none; a
// link fight's referee drops it with the badges; a Gen 1 hub never writes the
// field. tests/hub_battle.lua pins the same on the Lua twin.

// Turn.attempt's options as the hub assembled them, the field still built by
// the real referee: the fighter entries are what these tests look at.
function spyAttempt(relay) {
  const real = relay.Turn;
  const seen = { opts: null };
  relay.Turn = Object.assign(Object.create(real), {
    attempt: (opts) => {
      seen.opts = opts;
      return real.attempt(opts);
    },
  });
  return seen;
}

function entryOf(seen, side, playerId) {
  return ((seen.opts && seen.opts.sides[side]) || []).find((e) => e.playerId === playerId) || null;
}

const has = (obj, key) => Object.prototype.hasOwnProperty.call(obj, key);

const FOCUS3 = {
  id: 'FOCUS3', num: 264, effect: 170, power: 150, type: 1, priority: -3, flags: 35,
};

// A level-100 mon from another trainer: over the no-badge cap of 10, so every
// move it is told to use asks the obedience roll first.
function tradee3() {
  const m = mon3({ species: 'TRADEE', level: 100, moves: [move3(FOCUS3), move3()] });
  m.traded = true;
  return m;
}

// Emerald and FireRed side by side against a trainer.
function testGen3FamilyMixedCarts() {
  const clock = makeClock();
  const relay = makeRelay(clock, { generation: 3 });
  relay.forceBattleSeed = 3;
  const seen = spyAttempt(relay);
  const a = dial3(relay, 'ANN', 'emerald');
  const b = dial3(relay, 'BOB', 'firered');
  relay.openCoopBattle('g3f', [a.id, b.id], { mode: 'coop_npc', hostId: a.id });
  const record = relay.battles.get('g3f');
  relay.handle(a.id, { type: 'mmo.battle_ruleset', typeTable: CHART3 });
  const annMon = tradee3();
  annMon.unfateful = true;
  // Each upload claims the other cart's family: no party field decides it.
  relay.handle(a.id, {
    type: 'mmo.battle_party',
    battle: 'g3f',
    side: 'a',
    family: 'frlg',
    badges: ['1', '3'],
    mons: [annMon],
  });
  relay.handle(b.id, {
    type: 'mmo.battle_party', battle: 'g3f', side: 'a', family: 'rse', mons: [bruiser3()],
  });
  relay.handle(a.id, {
    type: 'mmo.battle_party', battle: 'g3f', side: 'b', mons: [glassjaw3(), glassjaw3()],
  });
  ok(record.sim, 'family: the mixed-cart coop_npc field opens');
  const annEntry = entryOf(seen, 'a', a.id);
  const bobEntry = entryOf(seen, 'a', b.id);
  ok(annEntry && annEntry.family === 'rse', "family: the Emerald player's entry is rse");
  ok(bobEntry && bobEntry.family === 'frlg', "family: the FireRed player's entry is frlg");
  for (const npcId of record.npcIds) {
    const npc = entryOf(seen, 'b', npcId);
    ok(npc && !has(npc, 'family'), `family: an NPC seat's entry has none (${npcId})`);
  }
  // What the hub was handed reaches the entry unchanged: the badges as the set
  // the sanitiser rebuilt, the sheet's traded / unfateful on the mon itself.
  ok(annEntry.badges && annEntry.badges['1'] === true && annEntry.badges['3'] === true,
    'family: the uploaded badges ride the entry');
  ok(annEntry.mons[0].traded === true, "family: the mon's traded flag rides the entry");
  ok(annEntry.mons[0].unfateful === true, 'family: and its unfateful flag');
  const annFighter = record.sim.byId.get(a.id);
  const bobFighter = record.sim.byId.get(b.id);
  ok(annFighter.family === 'rse', "family: the referee plays Emerald's rule for ANN");
  ok(bobFighter.family === 'frlg', "family: and FireRed's for BOB");
  ok(annFighter.badgeRules === true, 'family: against the computer, badge rules apply');
  ok(annFighter.badges && annFighter.badges[1] && annFighter.badges[3] && !annFighter.badges[2],
    "family: with ANN's own badges 1 and 3");
  ok(bobFighter.badges == null, 'family: and none for BOB, who brought none');
  ok(annFighter.mons[0].traded === true, "family: the referee's mon is still traded");
}

// The rule it decides, end to end: the same fight, the same seed, only ANN's
// cart differs. Her traded Focus Punch user disobeys on the first turn, and the
// second roll lands under the cap -- Emerald answers with another move,
// FireRed's exemption skips that branch and she naps instead. Seed 10 was found
// by a probe; the Lua twin draws the same.
function focusPunchObey(version) {
  const relay = makeRelay(makeClock(), { generation: 3 });
  relay.forceBattleSeed = 10;
  const a = dial3(relay, 'ANN', version);
  const b = dial3(relay, 'BOB', 'firered');
  relay.openCoopBattle('g3o', [a.id, b.id], { mode: 'coop_npc', hostId: a.id });
  relay.handle(a.id, { type: 'mmo.battle_ruleset', typeTable: CHART3 });
  relay.handle(a.id, {
    type: 'mmo.battle_party', battle: 'g3o', side: 'a', mons: [tradee3()],
  });
  relay.handle(b.id, {
    type: 'mmo.battle_party', battle: 'g3o', side: 'a', mons: [mon3({ moves: [move3(IDLE3)] })],
  });
  const wall = () => mon3({ species: 'TRAINEE', hp: 900, moves: [move3(IDLE3)] });
  relay.handle(a.id, {
    type: 'mmo.battle_party', battle: 'g3o', side: 'b', mons: [wall(), wall()],
  });
  if (!relay.battles.get('g3o').sim) return null;
  a.peer.outbox = [];
  relay.handle(a.id, {
    type: 'mmo.battle_choice', battle: 'g3o', action: 'fight', move: 0,
  });
  relay.handle(b.id, {
    type: 'mmo.battle_choice', battle: 'g3o', action: 'fight', move: 0,
  });
  return a.peer.outbox
    .filter((m) => m.type === 'mmo.battle_event' && m.t === 'obey' && m.side === 'a')
    .map((m) => m.text)
    .join(',');
}

function testGen3FamilyFocusPunch() {
  ok(focusPunchObey('emerald') === 'uses_random_move',
    "family: an Emerald mon's Focus Punch can be swapped for another move");
  ok(focusPunchObey('firered') === 'falls_asleep',
    "family: a FireRed mon's is exempt from that branch, same seed");
}

// A link fight: the entries still say whose cart, and the referee reads none
// of it -- no badge rules, no badges, no family, and nobody disobeys.
function testGen3FamilyLinkRules() {
  const relay = makeRelay(makeClock(), { generation: 3 });
  relay.forceBattleSeed = 10;
  const seen = spyAttempt(relay);
  const a = dial3(relay, 'ANN', 'emerald');
  const b = dial3(relay, 'BOB', 'firered');
  const c = dial3(relay, 'CAL', 'leafgreen');
  const d = dial3(relay, 'DEE', 'emerald');
  relay.openCoopBattle('g3p', [a.id, b.id, c.id, d.id], { mode: 'coop_pvp', hostId: a.id });
  const record = relay.battles.get('g3p');
  ok(record && record.mode === 'coop_pvp', 'family pvp: a four-player link fight opens');
  relay.handle(a.id, { type: 'mmo.battle_ruleset', typeTable: CHART3 });
  relay.handle(a.id, {
    type: 'mmo.battle_party', battle: 'g3p', badges: ['1', '2', '3'], mons: [tradee3()],
  });
  for (const who of [b, c, d]) {
    relay.handle(who.id, {
      type: 'mmo.battle_party',
      battle: 'g3p',
      badges: ['8'],
      mons: [mon3({ hp: 900, moves: [move3(IDLE3)] })],
    });
  }
  ok(record.sim, 'family pvp: the field opens');
  ok(entryOf(seen, 'a', a.id).family === 'rse', "family pvp: the entry still names ANN's cart");
  ok(entryOf(seen, 'b', c.id).family === 'frlg', 'family pvp: on either side');
  for (const who of [a, b, c, d]) {
    const fighter = record.sim.byId.get(who.id);
    ok(fighter.badgeRules == null && fighter.badges == null && fighter.family == null,
      `family pvp: the referee plays link rules for ${who.name}`);
  }
  a.peer.outbox = [];
  for (const who of [a, b, c, d]) {
    relay.handle(who.id, {
      type: 'mmo.battle_choice', battle: 'g3p', action: 'fight', move: 0,
    });
  }
  const events = a.peer.outbox.filter((m) => m.type === 'mmo.battle_event');
  ok(events.length > 0, 'family pvp: the turn resolves');
  ok(events.filter((m) => m.t === 'obey').length === 0,
    'family pvp: and the over-cap traded mon is not asked to obey');
}

// Gen 1: no field at all -- it is Gen 2's and Gen 3's (no Kanto rule reads one).
function testGen1NoFamily() {
  const relay = makeRelay(makeClock());
  const seen = spyAttempt(relay);
  const peer = { outbox: [], remoteAddress: '127.0.0.1' };
  peer.send = (msg) => peer.outbox.push(msg);
  peer.close = () => {};
  const annId = testPlayerId('ANN');
  relay.handle(relay.accept(peer), {
    type: 'mmo.hello',
    proto: PROTOCOL,
    name: 'ANN',
    sprite: DEFAULT_SPRITE,
    map: 'PALLET',
    x: 5,
    y: 5,
    facing: 'down',
    version: 'red',
    playerId: annId,
  });
  const a = { id: annId, peer, name: 'ANN' };
  const b = dial(relay, 'BOB');
  ok(relay.clients.get(a.id).version === 'red', "family gen 1: the hello's cart is recorded");
  relay.openCoopBattle('g1f', [a.id, b.id], { mode: 'coop_npc', hostId: a.id });
  relay.handle(a.id, { type: 'mmo.battle_ruleset', chart: [[100]] });
  relay.handle(a.id, {
    type: 'mmo.battle_party', battle: 'g1f', side: 'a', mons: [mon(200)],
  });
  relay.handle(b.id, {
    type: 'mmo.battle_party', battle: 'g1f', side: 'a', mons: [mon(200)],
  });
  relay.handle(a.id, {
    type: 'mmo.battle_party', battle: 'g1f', side: 'b', mons: [mon(10, 1), mon(10, 1)],
  });
  ok(relay.battles.get('g1f').sim, 'family gen 1: the coop_npc field opens');
  let entries = 0;
  for (const side of ['a', 'b']) {
    for (const entry of seen.opts.sides[side]) {
      entries += 1;
      ok(!has(entry, 'family'), `family gen 1: no entry carries one (${entry.playerId})`);
    }
  }
  ok(entries === 4, 'family gen 1: all four seats were looked at');
}

// Gold's badge type boost: the ruleset's `typeIds` reaches the referee.
//
// lib/battle2 ports DoBadgeTypeBoosts (keyed by type), but a move row carries
// only its chart index; the ruleset's typeIds -- MediatedBattle.snapshotRuleset's
// chart axis by name -- is what names it. The hub hands it to Turn.attempt, so a
// HIVE owner's BUG move hits harder in coop_npc; a badge for another type does
// nothing to it, and with no typeIds nothing can be named and nothing fires.
// tests/hub_battle.lua pins the same on the Lua twin.
function dial2(relay, name) {
  const peer = { outbox: [], remoteAddress: '127.0.0.1' };
  peer.send = (msg) => peer.outbox.push(msg);
  peer.close = () => {};
  const id = relay.accept(peer);
  const playerId = testPlayerId(name);
  relay.handle(id, {
    type: 'mmo.hello',
    proto: PROTOCOL,
    name,
    map: 'NEW_BARK_TOWN',
    x: 5,
    y: 5,
    facing: 'down',
    generation: 2,
    version: 'gold',
    playerId,
  });
  return { id: playerId, peer, name, ephemeralId: id };
}

// The type axis: 0 is a type no badge names, 1 is BUG (HIVE's), 2 is FIRE.
const CHART2 = [[100, 100, 100], [100, 100, 100], [100, 100, 100]];
const TYPE_IDS2 = ['DARK', 'BUG', 'FIRE'];

function sheet2(o) {
  return {
    species: o.species || 'ALPHA',
    level: 50,
    hp: o.hp || 300,
    maxHp: o.hp || 300,
    stats: {
      atk: o.atk || 100, def: o.def || 100, spe: o.spe || 50, spa: 50, spd: 100,
    },
    moves: [{
      id: o.move || 'thump', pp: 20, power: o.power || 1, accuracy: 255, type: o.type || 0, effect: 0, chance: 0,
    }],
  };
}

// What ANN's BUG move dealt the NPC at field 3, the ruleset and her badges as
// given. BOB aims at the other NPC, so field 3's only hit is hers.
function bugHit(badges, typeIds) {
  const relay = makeRelay(makeClock(), { generation: 2 });
  relay.forceBattleSeed = 5;
  const seen = spyAttempt(relay);
  const a = dial2(relay, 'ANN');
  const b = dial2(relay, 'BOB');
  relay.openCoopBattle('g2t', [a.id, b.id], { mode: 'coop_npc', hostId: a.id });
  const record = relay.battles.get('g2t');
  relay.handle(a.id, {
    type: 'mmo.battle_ruleset', battle: 'g2t', chart: CHART2, typeIds, specialTypes: [2],
  });
  relay.handle(a.id, {
    type: 'mmo.battle_party',
    battle: 'g2t',
    side: 'a',
    badges,
    mons: [sheet2({
      spe: 200, power: 50, type: 1, move: 'bugbite',
    })],
  });
  relay.handle(b.id, {
    type: 'mmo.battle_party', battle: 'g2t', side: 'a', mons: [sheet2({ spe: 100 })],
  });
  relay.handle(a.id, {
    type: 'mmo.battle_party',
    battle: 'g2t',
    side: 'b',
    mons: [sheet2({ species: 'WALL', hp: 900, spe: 1 }), sheet2({ species: 'WALL', hp: 900, spe: 1 })],
  });
  if (!record.sim) return { hit: null, record, seen };
  a.peer.outbox = [];
  relay.handle(a.id, {
    type: 'mmo.battle_choice', battle: 'g2t', action: 'fight', move: 0, target: 3,
  });
  relay.handle(b.id, {
    type: 'mmo.battle_choice', battle: 'g2t', action: 'fight', move: 0, target: 4,
  });
  const hit = a.peer.outbox.find((m) => m.type === 'mmo.battle_event' && m.t === 'damage' && m.slot === 3);
  return { hit: hit ? hit.amount : false, record, seen };
}

function testGen2TypeIdsBoost() {
  const boosted = bugHit(['HIVE'], TYPE_IDS2);
  ok(boosted.record && boosted.record.sim, 'typeIds: the Gen 2 coop_npc field opens');
  ok((boosted.seen.opts && boosted.seen.opts.typeIds || []).join(',') === 'DARK,BUG,FIRE',
    'typeIds: the hub hands the uploaded axis to Turn.attempt');
  ok((boosted.record.sim.typeIds || []).join(',') === 'DARK,BUG,FIRE', 'typeIds: and the referee keeps it');
  const annFighter = boosted.record.sim.byId.get(testPlayerId('ANN'));
  ok(annFighter && annFighter.badges && annFighter.badges.HIVE === true, "typeIds: ANN's fighter holds HIVE");
  const plain = bugHit(undefined, TYPE_IDS2).hit;
  ok(typeof boosted.hit === 'number' && typeof plain === 'number', "typeIds: ANN's BUG move lands on field 3");
  ok(boosted.hit > plain, `typeIds: HIVE boosts a BUG move (${boosted.hit} > ${plain})`);
  // FOG: GHOST's type badge, and none of Gold's stat badges (ZEPHYR would raise
  // Attack, BadgeStatBoosts).
  ok(bugHit(['FOG'], TYPE_IDS2).hit === plain, 'typeIds: a badge for another type does nothing to it');
  ok(bugHit(['HIVE'], undefined).hit === plain,
    "typeIds: with no typeIds the move's type has no name, and nothing fires");
  // An axis the hub cannot read -- a content mod's type id off the wire's id
  // alphabet, since a registry id is any non-empty string -- is dropped, not
  // refused: the ruleset stands, the field opens, and it plays exactly as one
  // uploaded with no typeIds at all.
  const modded = bugHit(['HIVE'], ['DARK', 'mymod.BUG', 'FIRE']);
  ok(modded.record && modded.record.sim, 'typeIds (unreadable): the field still opens');
  ok(modded.seen.opts && modded.seen.opts.typeIds == null,
    'typeIds (unreadable): ...and Turn.attempt is handed no axis');
  ok(modded.seen.opts && modded.seen.opts.chart && modded.seen.opts.specialTypes.length === 1,
    'typeIds (unreadable): ...but the rest of the ruleset');
  ok(modded.hit === plain, 'typeIds (unreadable): ...so nothing fires');
  // A JSON null inside the list is closed up first, as Lua's decoder does
  // before Wire.lua sees it: the hub reads the axis that is left.
  const holed = bugHit(['HIVE'], ['DARK', 'BUG', 'FIRE', null]);
  ok((holed.record.sim && holed.record.sim.typeIds || []).join(',') === 'DARK,BUG,FIRE',
    'typeIds (null-holed): the nulls are closed up, as on the Lua hub');
  ok(holed.hit === boosted.hit, 'typeIds (null-holed): ...and HIVE still boosts the BUG move');
}

// Gold's cart lineage on a fighter entry (contract K6).
//
// docs/plans/gen12-referee-fidelity.md: lib/battle2 reads side a's first
// fighter's `family` for the rule Gold / Silver and Crystal disagree on
// (TruncateHL_BC loops on Crystal outside a link battle, one pass on Gold /
// Silver), so a Gen 2 hub stamps each human seat the way a Gen 3 hub does --
// from the hello it admitted, never off the party -- gold / silver -> gs,
// crystal -> crystal. An NPC seat gets none. The K1 / K2 fields a Gold sheet
// carries ride the entry through the sanitiser, and a Gold `held` event goes
// out to every member as the referee wrote it. tests/hub_battle.lua pins the
// same on the Lua twin.
function dial2v(relay, name, version) {
  const peer = { outbox: [], remoteAddress: '127.0.0.1' };
  peer.send = (msg) => peer.outbox.push(msg);
  peer.close = () => {};
  const id = relay.accept(peer);
  const playerId = testPlayerId(name);
  const hello = {
    type: 'mmo.hello',
    proto: PROTOCOL,
    name,
    map: 'NEW_BARK_TOWN',
    x: 5,
    y: 5,
    facing: 'down',
    generation: 2,
    playerId,
  };
  if (version) hello.version = version;
  relay.handle(id, hello);
  return { id: playerId, peer, name, ephemeralId: id };
}

function testGen2Family() {
  const relay = makeRelay(makeClock(), { generation: 2 });
  relay.forceBattleSeed = 5;
  const seen = spyAttempt(relay);
  const a = dial2v(relay, 'ANN', 'crystal');
  const b = dial2v(relay, 'BOB', 'silver');
  ok(relay.clients.get(a.id).version === 'crystal', "family gen 2: the hello's cart is recorded");
  relay.openCoopBattle('g2f', [a.id, b.id], { mode: 'coop_npc', hostId: a.id });
  const record = relay.battles.get('g2f');
  relay.handle(a.id, {
    type: 'mmo.battle_ruleset', battle: 'g2f', chart: CHART2, typeIds: TYPE_IDS2, specialTypes: [2],
  });
  const held = sheet2({ spe: 200 });
  Object.assign(held, {
    heldItem: 'LEFTOVERS', holdEffect: 'HELD_LEFTOVERS', holdParam: 6, itemName: 'LEFTOVERS', traded: true,
  });
  // The upload claims the other cart's family: no party field decides it.
  relay.handle(a.id, {
    type: 'mmo.battle_party', battle: 'g2f', side: 'a', family: 'gs', generation: 2, mons: [held],
  });
  relay.handle(b.id, {
    type: 'mmo.battle_party', battle: 'g2f', side: 'a', family: 'crystal', generation: 2,
    mons: [sheet2({ spe: 100 })],
  });
  relay.handle(a.id, {
    type: 'mmo.battle_party',
    battle: 'g2f',
    side: 'b',
    generation: 2,
    mons: [sheet2({ species: 'WALL', hp: 900, spe: 1 }), sheet2({ species: 'WALL', hp: 900, spe: 1 })],
  });
  ok(record && record.sim, 'family gen 2: the coop_npc field opens');
  const annEntry = entryOf(seen, 'a', a.id);
  const bobEntry = entryOf(seen, 'a', b.id);
  ok(annEntry && annEntry.family === 'crystal', "family gen 2: the Crystal player's entry is crystal");
  ok(bobEntry && bobEntry.family === 'gs', "family gen 2: the Silver player's entry is gs");
  for (const npcId of (record && record.npcIds) || []) {
    const npc = entryOf(seen, 'b', npcId);
    ok(npc && !has(npc, 'family'), `family gen 2: an NPC seat's entry has none (${npcId})`);
  }
  const annMon = annEntry && annEntry.mons[0];
  ok(annMon && annMon.traded === true, 'gen 2 sheet: traded rides the entry (K1)');
  ok(annMon && annMon.heldItem === 'LEFTOVERS', 'gen 2 sheet: the item rides the entry');
  ok(annMon && annMon.holdEffect === 'HELD_LEFTOVERS', 'gen 2 sheet: ...with its hold effect (K2)');
  ok(annMon && annMon.holdParam === 6, 'gen 2 sheet: ...its parameter');
  ok(annMon && annMon.itemName === 'LEFTOVERS', 'gen 2 sheet: ...and its name');

  // A Gold `held` the referee writes goes out to every member untouched: put
  // straight into the referee's own event buffer, so what is pinned here is
  // the hub's pass-through and not the referee's vocabulary.
  if (record && record.sim) {
    a.peer.outbox = [];
    record.sim.buffer.push({
      battle: 'g2f', seq: 9000, t: 'held', slot: 0, side: 'a', mon: 0, text: 'LEFTOVERS', amount: 1,
    });
    relay.flushBattle(record);
    const out = a.peer.outbox.find((m) => m.type === 'mmo.battle_event' && m.t === 'held');
    ok(out && out.text === 'LEFTOVERS', "gen 2 held: the hub passes the referee's event through");
    ok(out && out.amount === 1, 'gen 2 held: ...amount and all');
    const sanitize = require('./lib/sanitize.js');
    const clean = out && sanitize.cleanBattleEvent(out, 2);
    ok(clean && clean.text === 'LEFTOVERS', "gen 2 held: ...and a Gold client's sanitiser keeps it");
  }
}

// Gold alone, and a hello with no cart: no family -- the referee plays gs.
function testGen2FamilyGoldAndNone() {
  const relay = makeRelay(makeClock(), { generation: 2 });
  relay.forceBattleSeed = 5;
  const seen = spyAttempt(relay);
  const gold = dial2v(relay, 'GOLDY', 'gold');
  const bare = dial2v(relay, 'BARE', undefined);
  relay.openCoopBattle('g2n', [gold.id, bare.id], { mode: 'coop_npc', hostId: gold.id });
  relay.handle(gold.id, { type: 'mmo.battle_ruleset', battle: 'g2n', chart: CHART2 });
  relay.handle(gold.id, {
    type: 'mmo.battle_party', battle: 'g2n', side: 'a', mons: [sheet2({ spe: 200 })],
  });
  relay.handle(bare.id, {
    type: 'mmo.battle_party', battle: 'g2n', side: 'a', mons: [sheet2({ spe: 100 })],
  });
  relay.handle(gold.id, {
    type: 'mmo.battle_party',
    battle: 'g2n',
    side: 'b',
    mons: [sheet2({ species: 'WALL', hp: 900, spe: 1 }), sheet2({ species: 'WALL', hp: 900, spe: 1 })],
  });
  ok(relay.battles.get('g2n') && relay.battles.get('g2n').sim, 'family gen 2 (gold): the field opens');
  const goldEntry = entryOf(seen, 'a', gold.id);
  ok(goldEntry && goldEntry.family === 'gs', "family gen 2 (gold): a Gold player's entry is gs");
  const bareEntry = entryOf(seen, 'a', bare.id);
  ok(bareEntry && !has(bareEntry, 'family'),
    'family gen 2 (no cart): a hello naming no cart leaves the field off');
}

// A four-player Gold spar: the entries still say whose cart (the referee reads
// side a's; a link fight plays one pass whoever's it is).
function testGen2FamilyPvp() {
  const relay = makeRelay(makeClock(), { generation: 2 });
  relay.forceBattleSeed = 5;
  const seen = spyAttempt(relay);
  const who = [dial2v(relay, 'ANN', 'crystal'), dial2v(relay, 'BOB', 'gold'),
    dial2v(relay, 'CAL', 'silver'), dial2v(relay, 'DEE', 'crystal')];
  const ids = who.map((c) => c.id);
  relay.openCoopBattle('g2p', ids, {
    mode: 'coop_pvp', hostId: ids[0], sides: { a: [ids[0], ids[1]], b: [ids[2], ids[3]] },
  });
  relay.handle(ids[0], { type: 'mmo.battle_ruleset', battle: 'g2p', chart: CHART2 });
  who.forEach((c, i) => {
    relay.handle(c.id, { type: 'mmo.battle_party', battle: 'g2p', mons: [sheet2({ spe: 10 * (i + 1) })] });
  });
  ok(relay.battles.get('g2p') && relay.battles.get('g2p').sim, 'family gen 2 pvp: the spar opens');
  ok(entryOf(seen, 'a', ids[0]).family === 'crystal', "family gen 2 pvp: ANN's entry names her cart");
  ok(entryOf(seen, 'a', ids[1]).family === 'gs', "family gen 2 pvp: BOB's");
  ok(entryOf(seen, 'b', ids[2]).family === 'gs', 'family gen 2 pvp: on either side');
  ok(entryOf(seen, 'b', ids[3]).family === 'crystal', "family gen 2 pvp: DEE's");
}

// ---------------------------------------------------------------------------
// The referee-gap contracts on the hub (docs/plans/gen12-referee-gaps-fix.md).
// Twin of the same block in tests/hub_battle.lua, which argues each case;
// tests/fixtures/hub_protocol_parity.json holds the two hubs to one digest.
// ---------------------------------------------------------------------------

function row12(id, o) {
  return {
    id, pp: 20, power: 40, accuracy: 255, type: 0, effect: 0, chance: 0, ...(o || {}),
  };
}

// K9: a mid-fight level-up rides mmo.battle_moveset and the hub forwards its
// level / stats / maxHp to the referee's levelUp(playerId, monIndex, level,
// stats, maxHp) -- 1-based index -- whatever became of the move list, only when
// the referee has the method, and only in a fight against the computer (a wild
// fight here; a link fight hears none, testPvpForgery). K8: a learn keeps an
// unchanged row's highCrit / PP Ups and takes a new row's.
function testGen12LevelUpForward() {
  const relay = makeRelay(makeClock());
  const a = dial(relay, 'LVLA');
  const session = openWild(relay, a);
  const record = relay.battles.get(session.id);
  ok(record && record.sim, 'level-up: the fight is live');
  const client = relay.get(a.id);
  const calls = [];
  record.sim.levelUp = function levelUp(playerId, index, level, stats, maxHp) {
    calls.push({
      self: this, playerId, index, level, stats, maxHp,
    });
  };
  const live = record.sim.byId.get(a.id).mons[0];
  live.moves = [row12('OLD', { pp: 10, highCrit: true, ppUps: 1 })];

  ok(relay.applyBattleMoveset(record, client, {
    mon: 0, moves: [row12('OLD', { pp: 99 })], level: 51, stats: { atk: 1, def: 2, spd: 3, spc: 4 }, maxHp: 310,
  }), "level-up: the hub's own moves with a level reach the referee");
  ok(calls.length === 1, 'level-up: one call');
  ok(calls[0].self === record.sim, 'level-up: called as a method on the referee');
  ok(calls[0].playerId === a.id, "level-up: for the sender's seat");
  ok(calls[0].index === 1, 'level-up: the 1-based party index (wire mon 0)');
  ok(calls[0].level === 51, 'level-up: the new level');
  ok(calls[0].stats && calls[0].stats.spc === 4, 'level-up: the new stats');
  ok(calls[0].maxHp === 310, 'level-up: the new max HP');
  ok(live.moves[0].pp === 10, "level-up: the unchanged row keeps the hub's PP");
  ok(live.moves[0].highCrit === true, 'level-up: ...and its high-crit flag (K8: the rebuild used to drop it)');
  ok(live.moves[0].ppUps === 1, 'level-up: ...and its PP Ups');

  relay.handle(a.id, {
    type: 'mmo.battle_moveset', battle: session.id, mon: 0, moves: [row12('OLD')], level: '52',
    stats: { atk: 5, def: 6, spd: 7, spc: 8 },
  });
  ok(calls.length === 2, 'level-up: the wire path forwards too');
  ok(calls[1].level === 52, 'level-up: ...the sanitised level');
  ok(calls[1].maxHp === undefined, 'level-up: ...and no max HP when none was stated');
  relay.handle(a.id, {
    type: 'mmo.battle_moveset', battle: session.id, mon: 0, moves: [row12('OLD')], level: 0,
  });
  ok(calls.length === 2, 'level-up: a mangled level refuses the whole message');

  ok(relay.applyBattleMoveset(record, client, {
    mon: 0, moves: [row12('OLD'), row12('NEW', { ppUps: 2, highCrit: true })],
  }), 'level-up: a learn with no level is applied');
  ok(calls.length === 2, 'level-up: ...and calls nothing');
  ok(live.moves[1] && live.moves[1].ppUps === 2, 'level-up: the learned row keeps its PP Ups');
  ok(live.moves[1].highCrit === true, 'level-up: ...and its high-crit flag');
  ok(live.moves[1].priority === undefined, 'level-up: a Gen 1 row has no priority');

  ok(relay.applyBattleMoveset(record, client, {
    mon: 0, moves: [row12('AAA'), row12('BBB')], level: 53,
  }), 'level-up: a refused rewrite still forwards its level');
  ok(calls.length === 3, 'level-up: ...one more call');
  ok(live.moves[0].id === 'OLD', 'level-up: ...and the list is untouched');

  live.transformed = true;
  ok(relay.applyBattleMoveset(record, client, {
    mon: 0, moves: [row12('OLD'), row12('NEW'), row12('THIRD')], level: 54, maxHp: 320,
  }), 'level-up: a transformed battler still grows');
  ok(calls.length === 4, 'level-up: ...the referee hears it');
  ok(live.moves.length === 2, 'level-up: ...and only its move list is protected');
  ok(relay.applyBattleMoveset(record, client, {
    mon: 0, moves: [row12('OLD'), row12('NEW'), row12('THIRD')],
  }) === false, 'level-up: moves alone on a transformed battler reach nothing');
  live.transformed = false;

  ok(relay.applyBattleMoveset(record, client, { mon: 5, moves: [row12('OLD')], level: 55 }) === false,
    'level-up: a party index with no mon is refused');
  ok(calls.length === 4, 'level-up: ...and forwards nothing');

  record.sim.levelUp = false;
  ok(relay.applyBattleMoveset(record, client, {
    mon: 0, moves: [row12('AAA'), row12('BBB')], level: 56,
  }) === false, 'level-up: a referee with no K9 method is not called');
  ok(relay.applyBattleMoveset(record, client, {
    mon: 0, moves: [row12('OLD'), row12('NEW'), row12('THIRD')], level: 56,
  }), 'level-up: ...and a learn still lands without it');
  ok(live.moves.length === 3, 'level-up: ...three moves now');
}

// The two learn rules are exported (twin of Hub.lua's, which the solo path's
// referee uses).
function testLearnRulesExported() {
  const { movesetDeltaOk, nextMoves12 } = require('./lib/relay.js');
  ok(movesetDeltaOk([row12('A')], [row12('A'), row12('B')]) === true, 'export: an append is a learn');
  ok(movesetDeltaOk([row12('A'), row12('B')], [row12('C'), row12('D')]) === false, 'export: a rewrite is not');
  const next12 = nextMoves12([row12('A', { pp: 3, highCrit: true })],
    [row12('A', { pp: 99 }), row12('B', { ppUps: 1 })]);
  ok(next12[0].pp === 3, 'export: an unchanged row keeps the old PP');
  ok(next12[0].highCrit === true, 'export: ...and its high-crit flag');
  ok(next12[1].ppUps === 1, 'export: a new row takes its own PP Ups');
  const based = nextMoves12([row12('A', { maxPp: 42, ppUps: 1, basePp: 35 })],
    [row12('A', { pp: 99, basePp: 9 }), row12('B', { basePp: 9 })]);
  ok(based[0].basePp === 35,
    "export: an unchanged row keeps the referee's base PP (Red's stepPp re-reads GetMaxPP over it)");
  ok(based[1].basePp === undefined, 'export: ...and a new row never takes one off the wire');
  const { learnTo } = require('./lib/relay.js');
  const held = { transformed: true, moves: [row12('COPY')], preTransform: { moves: [row12('A')] } };
  ok(learnTo(2, held, [row12('A'), row12('B')]) === true, 'export: learnTo lands a learn');
  ok(held.preTransform.moves.length === 2, 'export: ...in the list a Transform put aside');
  ok(held.moves[0].id === 'COPY', "export: ...leaving Gold's copied moves be");
  ok(learnTo(2, { transformed: true, moves: [row12('COPY')] }, [row12('COPY'), row12('B')]) === false,
    'export: a transformed battler with nothing put aside is left alone');
}

// Gold: the learn keeps the cart's priority byte (K8), and a Gold sheet's K7
// blocks ride the hub's stored party into the referee's hands.
// A wild fight, the kind a learn and a level-up are heard in (relay
// LEARN_MODES); the sheet's K7 / K8 blocks are stored whatever the mode.
function testGen2LevelUpAndSheet() {
  const relay = makeRelay(makeClock(), { generation: 2 });
  const a = dial2(relay, 'ANN');
  const id = 'g2k';
  relay.openCoopBattle(id, [a.id], { mode: 'wild', hostId: a.id });
  const gold = sheet2({});
  gold.base = {
    hp: 41, atk: 52, def: 63, spe: 74, spa: 85, spd: 96,
  };
  gold.dvs = {
    atk: 12, def: 7, spe: 15, spc: 3,
  };
  gold.statExp = {
    hp: 1, atk: 2, def: 3, spe: 4, spc: 5,
  };
  gold.happiness = 200;
  gold.moves[0].priority = 2;
  gold.moves[0].ppUps = 3;
  relay.handle(a.id, { type: 'mmo.battle_ruleset', battle: id, chart: CHART2 });
  relay.handle(a.id, {
    type: 'mmo.battle_party', battle: id, side: 'a', mons: [gold],
  });
  relay.handle(a.id, {
    type: 'mmo.battle_party', battle: id, side: 'b', mons: [sheet2({})],
  });
  const record = relay.battles.get(id);
  ok(record && record.sim, 'gold K7/K8: the fight opens on a sheet carrying them');
  const parties = record.parties;
  const party = parties && (typeof parties.get === 'function' ? parties.get(a.id) : parties[a.id]);
  const stored = party && party.mons[0];
  ok(stored && stored.dvs && stored.dvs.spc === 3, "gold K7: the stored sheet keeps the cart's DVs");
  ok(stored.base && stored.base.spd === 96, 'gold K7: ...the species base stats');
  ok(stored.statExp && stored.statExp.spc === 5, 'gold K7: ...and the stat exp');
  ok(stored.happiness === 200, 'gold K14: ...and the happiness RETURN reads');
  ok(stored.moves[0].priority === 2, "gold K8: ...and the move's priority byte");
  ok(stored.moves[0].ppUps === 3, 'gold K8: ...and its PP Ups');
  const live = record.sim.byId.get(a.id).mons[0];
  live.moves = [row12('thump', { priority: 1 })];
  relay.handle(a.id, {
    type: 'mmo.battle_moveset',
    battle: id,
    mon: 0,
    moves: [row12('thump', { priority: 3 }), row12('quick', { priority: 2 })],
  });
  ok(live.moves[0].priority === 1, "gold K8: an unchanged row keeps the hub's priority");
  ok(live.moves[1] && live.moves[1].priority === 2, 'gold K8: a learned row takes its own');
  let calls = 0;
  record.sim.levelUp = () => { calls += 1; };
  relay.handle(a.id, {
    type: 'mmo.battle_moveset',
    battle: id,
    mon: 0,
    moves: [row12('thump'), row12('quick')],
    level: 51,
    stats: {
      atk: 1, def: 2, spe: 3, spa: 4, spd: 5,
    },
    maxHp: 140,
  });
  ok(calls === 1, 'gold K9: a Gold level-up reaches the referee');
  relay.handle(a.id, {
    type: 'mmo.battle_moveset',
    battle: id,
    mon: 0,
    moves: [row12('thump'), row12('quick')],
    level: 52,
    stats: {
      atk: 1, def: 2, spd: 3, spc: 4,
    },
  });
  ok(calls === 1, 'gold K9: Kanto-keyed stats refuse a Gold moveset');
}

// K9 and the PROTOCOL 28 learn in a fight between players, on the real
// referees (the review's probe, RV-C probe_k9_pvp): a Gold 1v1 took a moveset
// carrying 999 stats and a 999 max HP -- re-sendable every turn -- straight
// into lib/battle2's levelUp, which judges no claim, and both referees took a
// one-slot "learn" of any row. No cart levels or learns in a link battle
// (pokered GainExperience returns on LINK_STATE_BATTLING, pokecrystal /
// pokegold GiveExperiencePoints on wLinkMode), so the hubs drop the message
// whole in a 1v1 and a coop_pvp (relay LEARN_MODES). Twin of pvpForgery in
// tests/hub_battle.lua.
function pvpForgery(generation, mode) {
  const relay = makeRelay(makeClock(), { generation });
  const join = (name) => (generation === 2 ? dial2(relay, name) : dial(relay, name));
  const sheet = () => (generation === 2 ? sheet2({}) : {
    species: 'ALPHA',
    level: 50,
    hp: 300,
    maxHp: 300,
    stats: {
      atk: 100, def: 100, spd: 50, spc: 50,
    },
    moves: [{
      id: 'thump', pp: 20, power: 200, accuracy: 255, type: 0, effect: 0, chance: 0,
    }],
  });
  const chart = generation === 2 ? CHART2 : [[100, 100], [100, 100]];
  const a = join('ANN');
  const b = join('BOB');
  let id;
  if (mode === '1v1') {
    relay.handle(a.id, { type: 'mmo.request', to: b.id, kind: 'battle' });
    relay.handle(b.id, {
      type: 'mmo.respond', to: a.id, kind: 'battle', accept: true,
    });
    id = take(a, 'mmo.session').id;
    relay.handle(a.id, { type: 'mmo.battle_ruleset', battle: id, chart });
    relay.handle(a.id, { type: 'mmo.battle_party', battle: id, mons: [sheet()] });
    relay.handle(b.id, { type: 'mmo.battle_party', battle: id, mons: [sheet()] });
  } else {
    const c = join('CAL');
    const d = join('DEE');
    id = 'pf';
    relay.openCoopBattle(id, [a.id, b.id, c.id, d.id], {
      mode: 'coop_pvp', hostId: a.id, sides: { a: [a.id, b.id], b: [c.id, d.id] },
    });
    relay.handle(a.id, { type: 'mmo.battle_ruleset', battle: id, chart });
    for (const who of [a, b, c, d]) {
      relay.handle(who.id, { type: 'mmo.battle_party', battle: id, mons: [sheet()] });
    }
  }
  const record = relay.battles.get(id);
  if (!record || !record.sim) return null;
  const live = record.sim.byId.get(a.id).mons[0];
  const snap = () => {
    const parts = [live.level, live.hp, live.maxHp];
    for (const k of Object.keys(live.stats).sort()) parts.push(`${k}=${live.stats[k]}`);
    for (const m of live.moves) parts.push(`${m.id}:${m.power}`);
    return parts.join(',');
  };
  const forged = generation === 2
    ? {
      atk: 999, def: 999, spe: 999, spa: 999, spd: 999,
    }
    : {
      atk: 999, def: 999, spd: 999, spc: 999,
    };
  const own = {
    id: 'thump', pp: 20, power: generation === 2 ? 1 : 200, accuracy: 255, type: 0, effect: 0, chance: 0,
  };
  const nuke = {
    id: 'NUKE', pp: 20, power: 250, accuracy: 255, type: 0, effect: 0, chance: 0,
  };
  const seen = { mode: record.mode, before: snap() };
  relay.handle(a.id, {
    type: 'mmo.battle_moveset', battle: id, mon: 0, moves: [own], stats: forged, maxHp: 999,
  });
  seen.stats = snap();
  relay.handle(a.id, {
    type: 'mmo.battle_moveset', battle: id, mon: 0, moves: [own], level: 100, stats: forged, maxHp: 999,
  });
  seen.level = snap();
  relay.handle(a.id, {
    type: 'mmo.battle_moveset', battle: id, mon: 0, moves: [own, nuke],
  });
  seen.learn = snap();
  seen.applied = relay.applyBattleMoveset(record, relay.get(a.id), {
    mon: 0, moves: [own, nuke], level: 100, stats: forged, maxHp: 999,
  });
  seen.after = snap();
  return seen;
}

function testPvpForgery() {
  for (const generation of [2, 1]) {
    for (const mode of ['1v1', 'coop_pvp']) {
      const label = `${generation === 2 ? 'gold' : 'red'} ${mode}`;
      const seen = pvpForgery(generation, mode);
      ok(seen !== null, `k9 pvp (${label}): the fight opens`);
      ok(seen.mode === mode, `k9 pvp (${label}): ...in that mode`);
      ok(seen.stats === seen.before, `k9 pvp (${label}): 999 stats and max HP reach nothing`);
      ok(seen.level === seen.before, `k9 pvp (${label}): ...nor with a level 100 claim`);
      ok(seen.learn === seen.before, `k9 pvp (${label}): a one-slot learn reaches nothing`);
      ok(seen.applied === false, `k9 pvp (${label}): applyBattleMoveset refuses all of it`);
      ok(seen.after === seen.before, `k9 pvp (${label}): ...and the monster is the one it was given`);
    }
  }
}

// The Red referee's own `basePp` (copyMove reads it out of a stated maximum,
// lib/battle Effects.basePpOf) survives a level-up's re-send and a learn on the
// real referee: the kept rows are the hub's, and `basePp` is one of their
// fields, never the wire's. Twin of the "base pp" block in tests/hub_battle.lua.
function testBasePpKept() {
  const relay = makeRelay(makeClock(), { generation: 1 });
  const a = dial(relay, 'ANN');
  const stated = row12('thump', { pp: 35, maxPp: 42, ppUps: 1 });
  const session = openWild(relay, a, [{ ...mon(40), moves: [stated] }]);
  const record = relay.battles.get(session.id);
  ok(record && record.sim, 'base pp: a Red wild fight opens');
  const live = record.sim.byId.get(a.id).mons[0];
  ok(live.moves[0].basePp === 35, 'base pp: the referee read the base out of the stated maximum');
  relay.handle(a.id, {
    type: 'mmo.battle_moveset', battle: session.id, mon: 0, moves: [stated], level: 51,
  });
  ok(live.level === 51, 'base pp: the level-up reached the referee');
  ok(live.moves[0].basePp === 35, 'base pp: ...and its re-sent row kept the base');
  relay.handle(a.id, {
    type: 'mmo.battle_moveset',
    battle: session.id,
    mon: 0,
    moves: [row12('thump'), row12('NEW', { pp: 10 })],
  });
  ok(live.moves[1] && live.moves[1].id === 'NEW', 'base pp: a learn lands');
  ok(live.moves[0].basePp === 35, 'base pp: ...and the unchanged row keeps the base');
  ok(live.moves[0].maxPp === 42, 'base pp: ...and its stated maximum');
}

// A learn on a transformed battler, real referees: written into the party list
// put aside at Transform (`preTransform.moves`) so the switch-out gives it back;
// Gold leaves the copied moves (pokecrystal LearnMove), Red overwrites them with
// a copy of its own (pokered LearnMove). Twin of transformLearn in
// tests/hub_battle.lua.
function transformLearn12(generation) {
  const relay = makeRelay(makeClock(), { generation });
  const a = generation === 2 ? dial2(relay, 'ANN') : dial(relay, 'ANN');
  const id = 'tl';
  relay.openCoopBattle(id, [a.id], { mode: 'wild', hostId: a.id });
  relay.handle(a.id, {
    type: 'mmo.battle_ruleset', battle: id, chart: generation === 2 ? CHART2 : [[100, 100], [100, 100]],
  });
  const sheet = (species, moves) => ({
    ...(generation === 2 ? sheet2({ species }) : { ...mon(1), species }), moves,
  });
  const mv = (moveId, effect, power) => row12(moveId, { pp: 10, power: power || 0, effect: effect || 0 });
  relay.handle(a.id, {
    type: 'mmo.battle_party',
    battle: id,
    side: 'a',
    mons: [sheet('COPYCAT', [mv('TRANSFORM', 57), mv('TACKLE', 0, 1)]), sheet('BENCH', [mv('TACKLE', 0, 1)])],
  });
  relay.handle(a.id, {
    type: 'mmo.battle_party', battle: id, side: 'b', mons: [sheet('FOE', [mv('GROWL'), mv('HUSH')])],
  });
  const record = relay.battles.get(id);
  if (!record || !record.sim) return null;
  relay.handle(a.id, {
    type: 'mmo.battle_choice', battle: id, action: 'fight', move: 0,
  });
  const live = record.sim.byId.get(a.id).mons[0];
  const client = relay.clients.get(a.id);
  const seen = { transformed: live.transformed === true, put: !!live.preTransform };
  seen.learnt = relay.applyBattleMoveset(record, client, {
    mon: 0, moves: [mv('TRANSFORM', 57), mv('TACKLE', 0, 1), mv('LEARNT', 0, 40)],
  });
  seen.battle = live.moves[0] && live.moves[0].id;
  seen.battleCount = live.moves.length;
  seen.party = live.preTransform && live.preTransform.moves.length;
  seen.partyPp = live.preTransform && live.preTransform.moves[0].pp;
  seen.separate = live.preTransform && live.preTransform.moves[0] !== live.moves[0];
  seen.rewrite = relay.applyBattleMoveset(record, client, {
    mon: 0, moves: [mv('AAA'), mv('BBB'), mv('CCC')],
  });
  relay.handle(a.id, {
    type: 'mmo.battle_choice', battle: id, action: 'switch', slot: 1,
  });
  seen.after = live.transformed === true;
  seen.restored = live.moves.map((m) => m.id).join(',');
  return seen;
}

function testTransformedLearn() {
  const gold = transformLearn12(2);
  ok(gold, 'transformed learn: a Gold wild fight opens');
  ok(gold.transformed && gold.put, 'transformed learn (gold): TRANSFORM put the party list aside');
  ok(gold.learnt === true, 'transformed learn (gold): the learn is applied');
  ok(gold.party === 3, 'transformed learn (gold): ...to the list put aside');
  ok(gold.partyPp === 9, "transformed learn (gold): ...which keeps the party's PP");
  ok(gold.battle === 'GROWL', 'transformed learn (gold): the copied moves stay in the fight');
  ok(gold.battleCount === 2, 'transformed learn (gold): ...all of them (pokecrystal LearnMove)');
  ok(gold.rewrite === false, 'transformed learn (gold): a rewrite is still refused');
  ok(gold.after === false, 'transformed learn (gold): the switch-out undoes the Transform');
  ok(gold.restored === 'TRANSFORM,TACKLE,LEARNT', 'transformed learn (gold): ...and gives back the learned list');
  const red = transformLearn12(1);
  ok(red, 'transformed learn: a Red wild fight opens');
  ok(red.transformed && red.put, 'transformed learn (red): TRANSFORM put the party list aside');
  ok(red.learnt === true, 'transformed learn (red): the learn is applied');
  ok(red.party === 3, 'transformed learn (red): ...to the list put aside');
  ok(red.battle === 'TRANSFORM', "transformed learn (red): the fight's moves become its own (pokered LearnMove)");
  ok(red.battleCount === 3, 'transformed learn (red): ...the learned move among them');
  ok(red.separate === true, "transformed learn (red): ...as a copy the fight's PP cannot reach the party through");
  ok(red.rewrite === false, 'transformed learn (red): a rewrite is still refused');
  ok(red.after === false, 'transformed learn (red): the switch-out undoes the Transform');
  ok(red.restored === 'TRANSFORM,TACKLE,LEARNT', 'transformed learn (red): ...and gives back the learned list');
}

// ---------------------------------------------------------------------------
// Wave 4 of docs/plans/gen12-referee-gaps-fix.md: a learn is judged against the
// PARTY list (a Transform's list put aside, a MIMIC's slots given back) and
// reaches the battle list only as the cart's LearnMove does -- for a new move
// alone, on Red whatever the Transform, on Gold only untransformed. Twin of the
// same block in tests/hub_battle.lua, which argues each case.
// ---------------------------------------------------------------------------

function testLearnUnderOverlays() {
  const { learnTo } = require('./lib/relay.js');
  const red = {
    transformed: true,
    moves: [row12('COPY1', { pp: 5 }), row12('COPY2', { pp: 5 })],
    preTransform: { moves: [row12('A', { pp: 7 }), row12('B')] },
  };
  ok(learnTo(1, red, [row12('A', { pp: 99 }), row12('B')]) === true, 'wave 4: a Red re-send while transformed is taken');
  ok(red.moves[0].id === 'COPY1', 'wave 4: ...and the copied moves stay in the fight');
  ok(red.moves.length === 2, 'wave 4: ...all of them');
  ok(red.preTransform.moves[0].pp === 7, 'wave 4: ...the list put aside keeps its PP');
  ok(learnTo(1, red, [row12('A'), row12('B'), row12('C')]) === true, 'wave 4: a Red learn while transformed');
  ok(red.moves[2] && red.moves[2].id === 'C',
    'wave 4: ...copies the party list over the copies (pokered LearnMove)');
  ok(red.moves[0].pp === 7, "wave 4: ...with the party's PP");
  ok(red.moves[0] !== red.preTransform.moves[0], 'wave 4: ...as a list of its own');

  const mimicked = (copyPp) => ({
    moves: [row12('HUSH', { pp: copyPp }), row12('B')],
    preMimic: { 1: row12('MIMIC', { pp: 9, effect: 82 }) },
  });
  const m = mimicked(6);
  ok(learnTo(1, m, [row12('MIMIC'), row12('B')]) === true, 'wave 4: a re-send under MIMIC is taken');
  ok(m.moves[0].id === 'HUSH', 'wave 4: ...and the copy stays in the fight');
  ok(m.preMimic && m.preMimic[1] && m.preMimic[1].id === 'MIMIC',
    'wave 4: ...its saved row kept for the switch-out');
  ok(learnTo(1, m, [row12('HUSH'), row12('B'), row12('C')]) === false,
    'wave 4: the battle list is not the party list -- the copy sent back as a learn is refused');
  ok(learnTo(1, m, [row12('MIMIC'), row12('B'), row12('C')]) === true,
    'wave 4: a learn under MIMIC is judged against the party list (it used to be refused)');
  ok(m.moves[0].id === 'MIMIC', "wave 4: ...Red's LearnMove copies the party list over the copy");
  ok(m.moves[0].pp === 6, "wave 4: ...MIMIC at the slot's PP (DecrementPP wrote both)");
  ok(m.moves[2] && m.moves[2].id === 'C', 'wave 4: ...the learned move among them');
  ok(m.preMimic === null, 'wave 4: ...and no saved row is left to give back over the learned list');
  const forget = mimicked(6);
  ok(learnTo(1, forget, [row12('NEW'), row12('B')]) === true, 'wave 4: forgetting MIMIC itself for a new move');
  ok(forget.moves[0].id === 'NEW', 'wave 4: ...lands in its slot');
  ok(forget.preMimic === null, 'wave 4: ...and the saved MIMIC goes with it');
  ok(learnTo(1, mimicked(6), [row12('X'), row12('Y')]) === false, 'wave 4: a rewrite under MIMIC is refused');

  const g = mimicked(5);
  ok(learnTo(2, g, [row12('MIMIC'), row12('B')]) === true, 'wave 4 (gold): a re-send under MIMIC is taken');
  ok(g.moves[0].id === 'HUSH', 'wave 4 (gold): ...and the copy stays');
  ok(learnTo(2, g, [row12('MIMIC'), row12('B'), row12('C')]) === true, 'wave 4 (gold): a learn under MIMIC');
  ok(g.moves[0].id === 'MIMIC', 'wave 4 (gold): ...pokecrystal LearnMove copies the party list over the copy');
  ok(g.moves[0].pp === 9, "wave 4 (gold): ...MIMIC at the party's own PP");
  ok(g.preMimic === null, 'wave 4 (gold): ...nothing left to give back');

  const both = (copyPp) => ({
    transformed: true,
    moves: [row12('COPY', { pp: 5 })],
    preTransform: { moves: [row12('HUSH', { pp: copyPp }), row12('B')] },
    preMimic: { 1: row12('MIMIC', { pp: 9 }) },
  });
  const gt = both(4);
  ok(learnTo(2, gt, [row12('MIMIC'), row12('B'), row12('C')]) === true,
    'wave 4 (gold): a learn under MIMIC and Transform');
  ok(gt.moves[0].id === 'COPY', 'wave 4 (gold): ...leaves the copied moves in the fight');
  ok(gt.preTransform.moves[0].id === 'MIMIC', 'wave 4 (gold): ...writes the party list put aside');
  ok(gt.preTransform.moves[0].pp === 9, "wave 4 (gold): ...MIMIC at the party's PP");
  ok(gt.preTransform.moves.length === 3, 'wave 4 (gold): ...with the learned move');
  ok(gt.preMimic === null, 'wave 4 (gold): ...and folds the saved row into it');
  const rt = both(4);
  ok(learnTo(1, rt, [row12('MIMIC'), row12('B')]) === true, 'wave 4: a Red re-send under MIMIC and Transform');
  ok(rt.moves[0].id === 'COPY', 'wave 4: ...leaves the copied moves');
  ok(rt.preTransform.moves[0].id === 'MIMIC', 'wave 4: ...the saved row folded into the list put aside');
  ok(rt.preTransform.moves[0].pp === 4, 'wave 4: ...at the PP the slot shared with the party');
  ok(rt.preMimic === null, 'wave 4: ...so the switch-out has one list to give back');
}

// The same on the real Red referee, MIMIC's pick off the wire.
function mimicLearn12(pick) {
  const relay = makeRelay(makeClock(), { generation: 1 });
  const a = dial(relay, 'ANN');
  const id = 'ml';
  relay.openCoopBattle(id, [a.id], { mode: 'wild', hostId: a.id });
  relay.handle(a.id, { type: 'mmo.battle_ruleset', battle: id, chart: [[100, 100], [100, 100]] });
  const mv = (moveId, effect, power) => row12(moveId, { pp: 10, power: power || 0, effect: effect || 0 });
  const sheet = (species, moves) => ({ ...mon(1), species, moves });
  relay.handle(a.id, {
    type: 'mmo.battle_party',
    battle: id,
    side: 'a',
    mons: [sheet('COPYCAT', [mv('MIMIC', 82), mv('TACKLE', 0, 1)]), sheet('BENCH', [mv('TACKLE', 0, 1)])],
  });
  relay.handle(a.id, {
    type: 'mmo.battle_party', battle: id, side: 'b', mons: [sheet('FOE', [mv('GROWL'), mv('HUSH')])],
  });
  const record = relay.battles.get(id);
  if (!record || !record.sim) return null;
  const choice = {
    type: 'mmo.battle_choice', battle: id, action: 'fight', move: 0,
  };
  if (pick !== undefined) choice.mimic = pick;
  relay.handle(a.id, choice);
  const live = record.sim.byId.get(a.id).mons[0];
  const client = relay.clients.get(a.id);
  const seen = {
    copy: live.moves[0].id,
    copyPp: live.moves[0].pp,
    saved: live.preMimic && live.preMimic[1] && live.preMimic[1].id,
  };
  seen.resend = relay.applyBattleMoveset(record, client, { mon: 0, moves: [mv('MIMIC', 82), mv('TACKLE', 0, 1)] });
  seen.afterResend = live.moves[0].id;
  seen.copyBack = relay.applyBattleMoveset(record, client, {
    mon: 0, moves: [mv(live.moves[0].id), mv('TACKLE', 0, 1), mv('LEARNT', 0, 40)],
  });
  seen.learnt = relay.applyBattleMoveset(record, client, {
    mon: 0, moves: [mv('MIMIC', 82), mv('TACKLE', 0, 1), mv('LEARNT', 0, 40)],
  });
  seen.battle = live.moves.map((m) => `${m.id}:${m.pp}`).join(',');
  seen.savedAfter = live.preMimic;
  relay.handle(a.id, {
    type: 'mmo.battle_choice', battle: id, action: 'switch', slot: 1,
  });
  seen.restored = live.moves.map((m) => m.id).join(',');
  return seen;
}

function testMimicLearnRealReferee() {
  const picked = mimicLearn12(1);
  ok(picked, 'wave 4 mimic: a Red wild fight opens');
  ok(picked.copy === 'HUSH', "wave 4 mimic: the wire's pick reaches the referee (the foe's second move)");
  ok(picked.copyPp === 9, "wave 4 mimic: ...in MIMIC's slot, at its PP");
  ok(picked.saved === 'MIMIC', "wave 4 mimic: ...the party's MIMIC saved");
  ok(picked.resend === true, "wave 4 mimic: a re-send of the party's ids is taken");
  ok(picked.afterResend === 'HUSH', 'wave 4 mimic: ...and leaves the copy in the fight');
  ok(picked.copyBack === false, 'wave 4 mimic: the copy sent back as a learn is refused');
  ok(picked.learnt === true, 'wave 4 mimic: a learn under MIMIC lands');
  ok(picked.battle === 'MIMIC:9,TACKLE:10,LEARNT:10',
    'wave 4 mimic: ...the party list over the copy, MIMIC at the PP it shared');
  ok(picked.savedAfter == null, 'wave 4 mimic: ...no saved row left');
  ok(picked.restored === 'MIMIC,TACKLE,LEARNT', 'wave 4 mimic: the switch-out keeps the learned list');
  const unpicked = mimicLearn12(undefined);
  ok(unpicked && unpicked.copy === 'GROWL', "wave 4 mimic: no pick on the wire is the menu's first row");
}

// A transformed battler's re-send on the real referees: the copies stay on both
// carts (Red's used to be replaced by its own list).
function transformResend12(generation) {
  const relay = makeRelay(makeClock(), { generation });
  const a = generation === 2 ? dial2(relay, 'ANN') : dial(relay, 'ANN');
  const id = 'tr';
  relay.openCoopBattle(id, [a.id], { mode: 'wild', hostId: a.id });
  relay.handle(a.id, {
    type: 'mmo.battle_ruleset', battle: id, chart: generation === 2 ? CHART2 : [[100, 100], [100, 100]],
  });
  const sheet = (species, moves) => ({
    ...(generation === 2 ? sheet2({ species }) : { ...mon(1), species }), moves,
  });
  const mv = (moveId, effect, power) => row12(moveId, { pp: 10, power: power || 0, effect: effect || 0 });
  relay.handle(a.id, {
    type: 'mmo.battle_party',
    battle: id,
    side: 'a',
    mons: [sheet('COPYCAT', [mv('TRANSFORM', 57), mv('TACKLE', 0, 1)]), sheet('BENCH', [mv('TACKLE', 0, 1)])],
  });
  relay.handle(a.id, {
    type: 'mmo.battle_party', battle: id, side: 'b', mons: [sheet('FOE', [mv('GROWL'), mv('HUSH')])],
  });
  const record = relay.battles.get(id);
  if (!record || !record.sim) return null;
  relay.handle(a.id, {
    type: 'mmo.battle_choice', battle: id, action: 'fight', move: 0,
  });
  const live = record.sim.byId.get(a.id).mons[0];
  const client = relay.clients.get(a.id);
  const seen = { transformed: live.transformed === true };
  seen.resend = relay.applyBattleMoveset(record, client, {
    mon: 0, moves: [mv('TRANSFORM', 57), mv('TACKLE', 0, 1)], level: 51,
  });
  seen.battle = live.moves[0] && live.moves[0].id;
  seen.battlePp = live.moves[0] && live.moves[0].pp;
  seen.party = live.preTransform && live.preTransform.moves[0].id;
  return seen;
}

function testTransformResend() {
  for (const generation of [1, 2]) {
    const label = generation === 2 ? 'gold' : 'red';
    const seen = transformResend12(generation);
    ok(seen && seen.transformed, `wave 4 resend (${label}): TRANSFORM lands`);
    ok(seen.resend === true, `wave 4 resend (${label}): a level-up re-sending the same ids is taken`);
    ok(seen.battle === 'GROWL', `wave 4 resend (${label}): ...and the copied moves stay in the fight`);
    ok(seen.battlePp === 5, `wave 4 resend (${label}): ...at their 5 PP`);
    ok(seen.party === 'TRANSFORM', `wave 4 resend (${label}): ...the party list put aside unchanged`);
  }
}

// Gold's wTimeOfDay off a Gen 2 ruleset: kept, handed to the referee's create,
// and MOONLIGHT heals by it; an unknown one refuses the ruleset; a Red hub reads
// none. Twin of `moonlight` in tests/hub_battle.lua.
function moonlight12(generation, timeOfDay) {
  const relay = makeRelay(makeClock(), { generation });
  const a = generation === 2 ? dial2(relay, 'ANN') : dial(relay, 'ANN');
  const id = 'tod';
  relay.openCoopBattle(id, [a.id], { mode: 'wild', hostId: a.id });
  relay.handle(a.id, {
    type: 'mmo.battle_ruleset',
    battle: id,
    chart: generation === 2 ? CHART2 : [[100, 100], [100, 100]],
    timeOfDay,
  });
  const record = relay.battles.get(id);
  const seen = {
    ruleset: !!(record && record.ruleset),
    kept: record && record.ruleset ? record.ruleset.timeOfDay : undefined,
  };
  const sheet = (species, moves, hp) => {
    const out = generation === 2 ? sheet2({ species, hp: 100 }) : { ...mon(1, 100), species };
    out.hp = hp || out.hp;
    out.moves = moves;
    return out;
  };
  const mv = (moveId, effect) => row12(moveId, { pp: 10, power: 0, effect: effect || 0 });
  relay.handle(a.id, {
    type: 'mmo.battle_party', battle: id, side: 'a', mons: [sheet('MOTH', [mv('MOONLIGHT', 130)], 40)],
  });
  relay.handle(a.id, {
    type: 'mmo.battle_party', battle: id, side: 'b', mons: [sheet('FOE', [mv('HUSH')])],
  });
  seen.opened = !!(record && record.sim);
  if (!seen.opened) return seen;
  seen.simTime = record.sim.timeOfDay;
  relay.handle(a.id, {
    type: 'mmo.battle_choice', battle: id, action: 'fight', move: 0,
  });
  seen.hp = record.sim.byId.get(a.id).mons[0].hp;
  return seen;
}

function testTimeOfDay() {
  const nite = moonlight12(2, 'nite');
  ok(nite.kept === 'nite', 'time of day: a Gold ruleset keeps it');
  ok(nite.simTime === 'nite', 'time of day: ...and the referee is created with it');
  ok(nite.hp === 90, 'time of day: MOONLIGHT at night heals half (BattleCommand_HealNite)');
  const day = moonlight12(2, 'day');
  ok(day.simTime === 'day', 'time of day: day reaches the referee');
  ok(day.hp === 65, 'time of day: ...and MOONLIGHT by day heals a quarter');
  ok(moonlight12(2, 'morn').hp === 65, 'time of day: ...in the morning too');
  const none = moonlight12(2, undefined);
  ok(none.simTime == null, 'time of day: none stated is none');
  ok(none.hp === 90, 'time of day: ...the link reading (half)');
  const bad = moonlight12(2, 'evening');
  ok(bad.ruleset === false, 'time of day: an unknown time refuses the Gold ruleset');
  ok(bad.opened === false, 'time of day: ...so no fight is assembled on it');
  ok(moonlight12(2, 'NITE').ruleset === false, "time of day: ...the spelling is the referee's, lower case");
  const red = moonlight12(1, 'nite');
  ok(red.ruleset && red.kept === undefined, 'time of day: a Red ruleset neither keeps one');
  ok(moonlight12(1, 'evening').ruleset, 'time of day: ...nor refuses one');
  ok(red.simTime == null, 'time of day: ...and the Red referee is created without it');
}

// Red's MIMIC pick on a choice: read on a Gen 1 hub, ignored on Gold's.
function testMimicChoiceGen1Only() {
  const { cleanBattleChoice } = require('./lib/sanitize.js');
  const fight = (mimic) => ({
    battle: 'b1', action: 'fight', move: 0, mimic,
  });
  ok(cleanBattleChoice(fight(2), 1).mimic === 2, 'mimic: a Gen 1 choice carries the pick');
  ok(cleanBattleChoice(fight(3), 1).mimic === 3, 'mimic: ...up to the fourth move');
  ok(cleanBattleChoice(fight(4), 1) === null, 'mimic: past the fourth move refuses the choice');
  ok(cleanBattleChoice(fight(-1), 1) === null, 'mimic: ...as does a negative pick');
  ok(cleanBattleChoice(fight(true), 1) === null, 'mimic: ...or one that is no number');
  const gold = cleanBattleChoice(fight(9), 2);
  ok(gold && gold.mimic === undefined, 'mimic: Gold ignores it, whatever it holds');
  const gen3 = cleanBattleChoice(fight(9), 3);
  ok(gen3 && gen3.mimic === undefined, 'mimic: ...as does Gen 3');
  const none = cleanBattleChoice(fight(9));
  ok(none && none.mimic === undefined, 'mimic: ...and a caller naming no generation');
}

// Gen 3 growth is read through the real wire handler and applied by the referee.
function testGen3LevelUpRead() {
  const relay = makeRelay(makeClock(), { generation: 3 });
  const a = dial3(relay, 'ANN');
  const id = 'g3w';
  relay.openCoopBattle(id, [a.id], { mode: 'wild', hostId: a.id });
  relay.handle(a.id, { type: 'mmo.battle_ruleset', battle: id, typeTable: CHART3 });
  relay.handle(a.id, {
    type: 'mmo.battle_party', battle: id, side: 'a', mons: [mon3()],
  });
  relay.handle(a.id, {
    type: 'mmo.battle_party', battle: id, side: 'b', mons: [mon3()],
  });
  const record = relay.battles.get(id);
  relay.handle(a.id, {
    type: 'mmo.battle_moveset',
    battle: id,
    mon: 0,
    moves: [move3(), move3({ id: 'NEW3', num: 44 })],
    level: 51,
    stats: {
      atk: 130, def: 90, spe: 100, spa: 90, spd: 90,
    },
    maxHp: 160,
  });
  const live = record.sim.byId.get(a.id);
  ok(live.mons[0].level === 51, 'gen 3: the level reaches the referee');
  ok(live.mons[0].maxHp === 160 && live.mons[0].hp === 160, 'gen 3: the HP delta reaches the referee');
  ok(live.b.stats.atk === 130, 'gen 3: the battler uses the new stats');
  ok(record.sim.byId.get(a.id).mons[0].moves.length === 2, 'gen 3: ...while the learn lands as before');
}

// K11: the hubs copy a Gen 1 / Gen 2 referee's Pay Day coins onto the outcome in
// the NPC modes alone, and only a positive count. The referee's outcome is a stub.
function paid12(mode, coins) {
  const relay = makeRelay(makeClock());
  const a = dial(relay, 'PAYA');
  const b = dial(relay, 'PAYB');
  let id;
  if (mode === '1v1') {
    id = openBattle(relay, a, b).id;
    uploadAndReady(relay, a, b, { id });
  } else {
    id = 'pw';
    relay.openCoopBattle(id, [a.id], { mode: 'wild', hostId: a.id });
    relay.handle(a.id, { type: 'mmo.battle_ruleset', battle: id, chart: [[100]] });
    relay.handle(a.id, {
      type: 'mmo.battle_party', battle: id, side: 'a', mons: [mon(90)],
    });
    relay.handle(a.id, {
      type: 'mmo.battle_party', battle: id, side: 'b', mons: [mon(20)],
    });
  }
  const record = relay.battles.get(id);
  if (!record || !record.sim) return false;
  a.peer.outbox = [];
  record.sim.outcome = () => ({
    outcome: 'win', winners: [a.id], losers: [b.id], reason: 'ko', payDay: coins,
  });
  relay.flushBattle(record);
  return take(a, 'mmo.battle_outcome');
}

function testGen12PayDayForward() {
  const wild = paid12('wild', 350);
  ok(wild, "pay day 1/2: a wild fight settles on the referee's outcome");
  ok(wild.payDay === 350, 'pay day 1/2: the coins ride the outcome of a fight against the computer');
  ok(sanitize.cleanBattleOutcome(wild, 1).payDay === 350, 'pay day 1/2: and a Gen 1 reader keeps them');
  const link = paid12('1v1', 350);
  ok(link, 'pay day 1/2: a 1v1 settles too');
  ok(link.payDay === undefined, 'pay day 1/2: a fight between players carries none');
  const none = paid12('wild', 0);
  ok(none, 'pay day 1/2: a fight with no coins settles');
  ok(none.payDay === undefined, "pay day 1/2: a 0 is the field's absence, as on the Lua twin");
}

// K11 on an escape: pokered pays wTotalPayDayMoney after a Teleport / Whirlwind
// / Roar / POKE DOLL escape (wBattleResult left at 0, EndOfBattle), so Red's
// coins ride a `run` outcome; Gold calls every escape a DRAW and Gen 3 pays only
// from HandleEndTurn_BattleWon, so those hubs keep the field off a run even when
// the (stubbed) referee carries one. The stub names side a the losers, as a
// referee does when the players fled. Twin of fled() in tests/hub_battle.lua.
function fled12(generation, mode, coins, reason) {
  const relay = makeRelay(makeClock(), { generation });
  let dialAs = (r, name) => dial(r, name);
  if (generation === 2) dialAs = dial2;
  if (generation === 3) dialAs = (r, name) => dial3(r, name);
  const a = dialAs(relay, 'ANN');
  const b = dialAs(relay, 'BOB');
  const sheet = () => {
    if (generation === 2) return sheet2({});
    if (generation === 3) return mon3();
    return mon(90);
  };
  const members = mode === 'coop_wild' ? [a.id, b.id] : [a.id];
  const id = 'fw';
  relay.openCoopBattle(id, members, { mode, hostId: a.id });
  if (generation === 3) {
    relay.handle(a.id, { type: 'mmo.battle_ruleset', battle: id, typeTable: CHART3 });
  } else {
    relay.handle(a.id, {
      type: 'mmo.battle_ruleset', battle: id, chart: generation === 2 ? CHART2 : [[100]],
    });
  }
  relay.handle(a.id, {
    type: 'mmo.battle_party', battle: id, side: 'a', mons: [sheet()],
  });
  if (mode === 'coop_wild') {
    relay.handle(b.id, {
      type: 'mmo.battle_party', battle: id, side: 'a', mons: [sheet()],
    });
  }
  relay.handle(a.id, {
    type: 'mmo.battle_party', battle: id, side: 'b', mons: [sheet()],
  });
  const record = relay.battles.get(id);
  if (!record || !record.sim) return [null, null];
  a.peer.outbox = [];
  b.peer.outbox = [];
  const wild = record.npcIds[0];
  record.sim.outcome = () => (reason === 'ko'
    ? {
      outcome: 'win', winners: members, losers: [wild], reason: 'ko', payDay: coins,
    }
    : {
      outcome: 'win', winners: [wild], losers: members, reason: 'run', payDay: coins,
    });
  relay.flushBattle(record);
  return [take(a, 'mmo.battle_outcome'), take(b, 'mmo.battle_outcome')];
}

function testGen12PayDayOnRun() {
  const [red] = fled12(1, 'wild', 350);
  ok(red, 'pay day on a run: a Red wild escape settles');
  ok(red.reason === 'run', 'pay day on a run: ...as a run');
  ok(red.winners && red.winners[0] === 'nfwa', 'pay day on a run: ...the wild seat named the winner');
  ok(red.losers && red.losers.length === 1, 'pay day on a run: ...and the player who fled the loser');
  ok(red.payDay === 350, "pay day on a run: Red's coins ride the escape (pokered EndOfBattle)");
  ok(sanitize.cleanBattleOutcome(red, 1).payDay === 350, 'pay day on a run: ...and a Gen 1 reader keeps them');
  const [atA, atB] = fled12(1, 'coop_wild', 350);
  ok(atA && atA.payDay === 350, 'pay day on a run: a Red co-op escape pays the first player');
  ok(atB && atB.payDay === 350, 'pay day on a run: ...and the second (both seats on side a)');
  ok((fled12(1, 'wild', 0)[0] || {}).payDay === undefined, "pay day on a run: a 0 is still the field's absence");
  const [gold] = fled12(2, 'wild', 350);
  ok(gold, 'pay day on a run: a Gold wild escape settles');
  ok(gold.payDay === undefined, 'pay day on a run: Gold pays none (every escape is a DRAW)');
  const [gold2] = fled12(2, 'coop_wild', 350);
  ok(gold2 && gold2.payDay === undefined, 'pay day on a run: ...in co-op neither');
  ok((fled12(2, 'wild', 350, 'ko')[0] || {}).payDay === 350, "pay day on a run: Gold's knockout still pays");
  const [g3] = fled12(3, 'wild', 350);
  ok(g3, 'pay day on a run: a Gen 3 wild escape settles');
  ok(g3.payDay === undefined, 'pay day on a run: Gen 3 pays none (HandleEndTurn_BattleWon only)');
  ok((fled12(3, 'wild', 350, 'ko')[0] || {}).payDay === 350, "pay day on a run: Gen 3's knockout still pays");
}

// K13: an id is refused past 40 characters on both twins.
function testIdRefusedPastForty() {
  ok(sanitize.cleanId('i'.repeat(40)) === 'i'.repeat(40), 'id: 40 characters is an id');
  ok(sanitize.cleanId('i'.repeat(41)) === null, 'id: 41 is refused, not cut to 40');
  ok(sanitize.cleanBattleReconnect({ battle: 'b'.repeat(41) }) === null,
    'id: a long battle id refuses the message');
  const long = mon(40);
  long.moves[0].id = 'm'.repeat(41);
  ok(sanitize.cleanBattleMon(long) === null, 'id: a long move id refuses the monster');
}

// K13's twin: a map id is refused past 64 characters (cleanMapId always has;
// Wire.mapId now does too), so a step there leaves its player unplaced.
function testMapIdRefusedPastSixtyFour() {
  ok(sanitize.cleanMapId('M'.repeat(64)) === 'M'.repeat(64), 'map id: 64 characters is a map id');
  ok(sanitize.cleanMapId('M'.repeat(65)) === null, 'map id: 65 is refused, not cut to 64');
  const relay = makeRelay(makeClock());
  const a = dial(relay, 'ANN');
  const b = dial(relay, 'BOB');
  b.peer.outbox = [];
  relay.handle(a.id, {
    type: 'mmo.move', map: 'M'.repeat(65), x: 3, y: 4, facing: 'up',
  });
  let step = take(b, 'mmo.move');
  ok(step, 'map id: a step with a long map still reaches the room');
  ok(step && step.map == null, 'map id: ...with its player unplaced');
  ok(relay.clients.get(a.id).map == null, "map id: ...and nowhere on the hub's own roster");
  relay.handle(a.id, {
    type: 'mmo.move', map: 'M'.repeat(64), x: 3, y: 4, facing: 'up',
  });
  step = take(b, 'mmo.move');
  ok(step && step.map === 'M'.repeat(64), 'map id: a 64-character map places them');
  ok(relay.clients.get(b.id).map === 'PALLET', '(the onlooker stays where it was)');
}

// K14: Gold's happiness rides a Gen 2 sheet; a Gen 1 reader neither copies nor
// refuses one, and a Gen 2 sheet with an unreadable one is refused whole.
function testHappinessGen2Only() {
  const red = { ...mon(40), happiness: 70 };
  const read = sanitize.cleanBattleMon(red);
  ok(read, 'happiness: a Red sheet stating one is still read');
  ok(read && read.happiness === undefined, 'happiness: ...without it (Red has no happiness byte)');
  ok((sanitize.cleanBattleMon({ ...sheet2({}), happiness: 255 }) || {}).happiness === 255,
    'happiness: a Gold sheet carries it');
  ok(sanitize.cleanBattleMon({ ...sheet2({}), happiness: 256 }) === null,
    'happiness: past one byte refuses the Gold sheet');
}

// ---------------------------------------------------------------------------
// Wave 5 of docs/plans/gen12-referee-gaps-fix.md: the four new wire fields reach
// their referees through the hub and change the fight the cart's way -- Red's
// `chartOrder`, Gold's BATON PASS `pass`, Gold's K15 `base.gender` and a Gold
// pool row's `num`. Twin of the same block in tests/hub_battle.lua, which
// argues each case.
// ---------------------------------------------------------------------------

function msgTexts5(player) {
  return takeAll(player, 'mmo.battle_event').filter((msg) => msg.t === 'msg').map((msg) => msg.text);
}

function wave5Fight(generation, rules, aMons, bMons, choice) {
  const relay = makeRelay(makeClock(), { generation });
  const a = generation === 2 ? dial2(relay, 'ANN') : dial(relay, 'ANN');
  const id = 'w5';
  relay.openCoopBattle(id, [a.id], { mode: 'wild', hostId: a.id });
  relay.handle(a.id, { type: 'mmo.battle_ruleset', battle: id, ...rules });
  relay.handle(a.id, {
    type: 'mmo.battle_party', battle: id, side: 'a', mons: aMons,
  });
  relay.handle(a.id, {
    type: 'mmo.battle_party', battle: id, side: 'b', mons: bMons,
  });
  const record = relay.battles.get(id);
  if (!record || !record.sim) return { opened: false, record };
  a.peer.outbox.length = 0;
  relay.handle(a.id, {
    type: 'mmo.battle_choice', battle: id, action: 'fight', move: 0, ...(choice || {}),
  });
  const fighter = record.sim.byId.get(a.id);
  return {
    opened: true, record, fighter, texts: msgTexts5(a),
  };
}

function sheetOf(generation, species, moves, extra) {
  const base = generation === 2 ? sheet2({ species }) : { ...mon(1), species };
  return { ...base, moves, ...(extra || {}) };
}

const activeSpecies = (run) => run.fighter.mons[run.fighter.active - 1].species;
// A line containing `part` (the wording is the referee's; which line it is, is
// what these checks are about), read the way every matcher reads a battle line:
// without its name marks (K17) or the cart's breaks (K18) -- "It doesn't
// affect" / line "^bDUO!" is "It doesn't affect DUO!".
const hasPart = (texts, part) => (texts || []).some((text) => sanitize.plainBattleLine(text).includes(part));

function orderFight(generation, order) {
  return wave5Fight(generation, { chart: [[0, 200], [100, 100]], chartOrder: order },
    [sheetOf(generation, 'TAPPER', [row12('TAP', { pp: 10, power: 40 })])],
    [sheetOf(generation, 'DUO', [row12('HUSH', { pp: 10, power: 0 })], { types: [0, 1] })]);
}

function testWave5ChartOrder() {
  const immuneLast = orderFight(1, [0, 1, 0, 0]);
  ok(immuneLast.opened, 'wave 5 chartOrder: a Red fight opens on an ordered ruleset');
  const rows = immuneLast.opened && immuneLast.record.sim.chartRows;
  ok(rows && rows.length === 2, 'wave 5 chartOrder: ...the referee holds its two rows');
  ok(hasPart(immuneLast.texts, 'affect DUO'),
    'wave 5 chartOrder: the immunity row last -- "It doesn\'t affect" (PrintMoveFailureText)');
  const superLast = orderFight(1, [0, 0, 0, 1]);
  ok(hasPart(superLast.texts, 'missed'),
    'wave 5 chartOrder: the super-effective row last -- "<USER>\'s attack missed!", the same immunity');
  ok(!hasPart(superLast.texts, 'affect DUO'), 'wave 5 chartOrder: ...and not "doesn\'t affect"');
  const unordered = orderFight(1, undefined);
  ok(hasPart(unordered.texts, 'affect DUO'), 'wave 5 chartOrder: no order is the product, an immunity');
  ok(unordered.opened && unordered.record.sim.chartRows == null, 'wave 5 chartOrder: ...with no rows held');
  const broken = orderFight(1, [0, 0, 0]);
  ok(broken.opened === false, 'wave 5 chartOrder: an odd-length order refuses the ruleset, so nothing opens');
  ok(broken.record && broken.record.ruleset == null, 'wave 5 chartOrder: ...and no ruleset is kept');
  const gold = orderFight(2, [0, 0, 0, 1]);
  ok(gold.opened, 'wave 5 chartOrder: a Gold hub takes the same ruleset');
  ok(gold.opened && gold.record.ruleset.chartOrder === undefined,
    "wave 5 chartOrder: ...without the order (Red's alone)");
}

function passFight(pass) {
  return wave5Fight(2, { chart: CHART2 }, [
    sheetOf(2, 'PASSER', [row12('BATON_PASS', { pp: 10, power: 0, effect: 134 })]),
    sheetOf(2, 'BENCH1', [row12('TAP', { pp: 10, power: 1 })]),
    sheetOf(2, 'BENCH2', [row12('TAP', { pp: 10, power: 1 })]),
  ], [sheetOf(2, 'FOE', [row12('HUSH', { pp: 10, power: 0 })])], { pass });
}

function testWave5BatonPass() {
  const named = passFight(2);
  ok(named.opened, 'wave 5 pass: a Gold wild fight opens');
  ok(named.opened && activeSpecies(named) === 'BENCH2',
    "wave 5 pass: the wire's successor comes in (BattleCommand_BatonPass's menu pick)");
  ok(named.opened && named.record.sim.turn === 2, 'wave 5 pass: ...and the turn resolved');
  ok(hasPart(named.texts, 'BATON_PASS'), 'wave 5 pass: ...after BATON PASS was used');
  const unnamed = passFight(undefined);
  ok(unnamed.opened && activeSpecies(unnamed) === 'BENCH1', "wave 5 pass: none named is the referee's pick");
  for (const pass of [4, 6]) {
    const refused = passFight(pass);
    ok(refused.opened && refused.record.sim.turn === 1, `wave 5 pass: pass ${pass} files no turn`);
    ok(refused.opened && activeSpecies(refused) === 'PASSER', `wave 5 pass: ...and PASSER stays out (${pass})`);
    ok(refused.opened && refused.fighter.choice == null, `wave 5 pass: ...with no choice held (${pass})`);
  }
}

function attractFight(mine, theirs) {
  const charm = (species, gender, moves) => ({
    ...sheetOf(2, species, moves),
    base: {
      hp: 41, atk: 52, def: 63, spe: 74, spa: 85, spd: 96, gender,
    },
    dvs: {
      atk: 12, def: 7, spe: 15, spc: 3,
    },
  });
  return wave5Fight(2, { chart: CHART2 },
    [charm('CHARMER', mine, [row12('ATTRACT', { pp: 15, power: 0, effect: 133 })])],
    [charm('FOE', theirs, [row12('HUSH', { pp: 10, power: 0 })])]);
}

function testWave5Gender() {
  const lands = attractFight(0, 254);
  ok(lands.opened, 'wave 5 gender: a Gold fight with a ratio on both sheets opens');
  ok(lands.opened && lands.fighter.mons[0].base.gender === 0, 'wave 5 gender: ...the ratio reaches the referee');
  ok(hasPart(lands.texts, 'fell in love'), 'wave 5 gender: ATTRACT lands, male into female');
  ok(hasPart(attractFight(0, 0).texts, 'failed'), 'wave 5 gender: ...fails male into male');
  const none = attractFight(undefined, undefined);
  ok(none.opened && none.fighter.mons[0].base.gender === undefined, 'wave 5 gender: a sheet with no ratio has none');
  ok(hasPart(none.texts, 'failed'), 'wave 5 gender: ...and ATTRACT fails (genderless)');
  ok(attractFight(300, 254).opened === false,
    'wave 5 gender: a ratio past a byte refuses the party, so nothing opens');
}

function metronomeFight(generation, numbered) {
  const poolRow = (moveId, num) => row12(moveId, { pp: 10, power: 0, num: numbered ? num : undefined });
  return wave5Fight(generation, {
    chart: generation === 2 ? CHART2 : [[100, 100], [100, 100]],
    metronomePool: [poolRow('CALLED_A', 200), poolRow('CALLED_B', 7)],
  }, [sheetOf(generation, 'WAGGLER', [row12('METRONOME', { pp: 10, power: 0, effect: 83 })])],
  [sheetOf(generation, 'FOE', [row12('HUSH', { pp: 10, power: 0 })])]);
}

function testWave5PoolNum() {
  const numbered = metronomeFight(2, true);
  ok(numbered.opened, 'wave 5 num: a Gold fight opens on a numbered pool');
  ok(numbered.opened && numbered.record.sim.metronomePool[0].num === 200,
    'wave 5 num: ...the number reaches the referee');
  const placed = metronomeFight(2, false);
  ok(placed.opened && placed.record.sim.metronomePool[0].num == null, 'wave 5 num: an unnumbered pool has none');
  // "^aWAGGLER" / line "used CALLED_A!" on the wire (K17 / K18), read plain.
  const called = (run) => {
    for (const text of run.texts || []) {
      const m = /^WAGGLER used (CALLED_[A-Z])/.exec(sanitize.plainBattleLine(text));
      if (m) return m[1];
    }
    return null;
  };
  ok(called(numbered) && called(placed), 'wave 5 num: METRONOME calls a pool move both ways');
  ok(called(numbered) !== called(placed), 'wave 5 num: ...a different one once the rows state their numbers');
  const red = metronomeFight(1, true);
  ok(red.opened, 'wave 5 num: a Red hub takes a numbered pool');
  ok(red.opened && red.record.ruleset.metronomePool[0].num === undefined, 'wave 5 num: ...without the numbers');
}

// The line budget with the new fields at every cap (twin of the same block in
// tests/hub_battle.lua): a worst-case Red ruleset with a full CHART_ORDER_MAX
// order and a worst-case Gold one with `priority` and `num` on every pool row
// stay inside MAX_LINE and sanitise whole.
function wave5Worst(generation) {
  const chart = [];
  const ids = [];
  for (let a = 1; a <= sanitize.BATTLE_TYPE_MAX; a += 1) {
    chart.push(new Array(sanitize.BATTLE_TYPE_MAX).fill(400));
    ids.push('T'.repeat(38) + String(a).padStart(2, '0'));
  }
  const order = [];
  for (let i = 1; i <= sanitize.CHART_ORDER_MAX; i += 1) order.push(10 + (i % 10));
  const pool = [];
  for (let i = 1; i <= sanitize.METRONOME_POOL_MAX; i += 1) {
    const entry = {
      id: 'M'.repeat(37) + String(i).padStart(3, '0'),
      name: 'N'.repeat(16),
      pp: 99,
      maxPp: 99,
      power: 999,
      accuracy: 255,
      type: 31,
      effect: 255,
      chance: 100,
      ppUps: 3,
      highCrit: true,
    };
    if (generation === 2) {
      entry.priority = 255;
      entry.num = 100 + (i % 152);
    }
    pool.push(entry);
  }
  const rules = {
    type: 'mmo.battle_ruleset',
    battle: 'b'.repeat(40),
    seed: 1073741824,
    chart,
    typeIds: ids,
    specialTypes: [10, 11, 12, 13, 14, 15, 16, 17, 18, 19],
    metronomePool: pool,
  };
  if (generation === 1) rules.chartOrder = order;
  else rules.timeOfDay = 'nite';
  return rules;
}

function testWave5LineBudget() {
  for (const generation of [1, 2]) {
    const line = JSON.stringify(wave5Worst(generation));
    ok(line.length < sanitize.MAX_LINE,
      `wave 5 size: a worst-case Gen ${generation} ruleset is one line inside MAX_LINE (${line.length} bytes)`);
    const clean = sanitize.cleanBattleRuleset(JSON.parse(line), generation);
    ok(clean && clean.metronomePool.length === sanitize.METRONOME_POOL_MAX,
      `wave 5 size: ...and reads back with its whole pool (Gen ${generation})`);
    if (generation === 1) {
      ok(clean.chartOrder.length === sanitize.CHART_ORDER_MAX, 'wave 5 size: ...and its whole chartOrder');
    } else {
      ok(clean.metronomePool[0].num === 101, 'wave 5 size: ...each row with its number');
    }
  }
}

// ------------------------------------------------------------------
// Wave 6 of docs/plans/gen12-referee-gaps-fix.md, through the hub: an NPC
// party's display `name` (Red and Gold) names every seat the trainer is dealt
// across and its Red `aiMods` ride on those seats alone; the referee's AI item
// line carries the name -- in the carts' three rows (K18), with no K17 mark
// (neither name goes through a battler's prefixing macro) -- and a Red / Gold
// client reads it whole (é … ♂ ♀ &); the item is
// the computer's own since K16 (Red's `aiClass`, Gold's `trainerItems` through
// `itemSwitch`, no NPC bag); a JSON null in a ruleset's chart or specialTypes
// is closed up as the Lua hub's decoder closes it. Twin of the wave 6 block in
// tests/hub_battle.lua.
// ------------------------------------------------------------------

function npcFight6(generation, npc, humans = 1, own) {
  const relay = makeRelay(makeClock(), { generation });
  const joiner = generation === 2 ? dial2 : dial;
  const a = joiner(relay, 'ANN');
  const members = [a.id];
  const b = humans === 2 ? joiner(relay, 'BOB') : null;
  if (b) members.push(b.id);
  const id = 'w6';
  relay.openCoopBattle(id, members, { mode: 'coop_npc', hostId: a.id });
  relay.handle(a.id, { type: 'mmo.battle_ruleset', battle: id, chart: [[100, 100], [100, 100]] });
  const sheet = (species) => (generation === 2 ? sheet2({ species }) : { ...mon(40), species });
  relay.handle(a.id, {
    type: 'mmo.battle_party', battle: id, side: 'a', mons: [sheet('HERO')], ...(own || {}),
  });
  if (b) {
    relay.handle(b.id, {
      type: 'mmo.battle_party', battle: id, side: 'a', mons: [sheet('HERO')],
    });
  }
  relay.handle(a.id, {
    type: 'mmo.battle_party', battle: id, side: 'b', mons: [sheet('FOE'), sheet('FOE')], ...(npc || {}),
  });
  const record = relay.battles.get(id);
  if (!record || !record.sim) return { opened: false, record };
  const seats = record.npcIds.map((npcId) => record.sim.byId.get(npcId));
  const out = {
    opened: true, record, seats, ann: record.sim.byId.get(a.id), lines: [],
  };
  if (humans !== 2) {
    a.peer.outbox.length = 0;
    relay.handle(a.id, {
      type: 'mmo.battle_choice', battle: id, action: 'fight', move: 0,
    });
    out.lines = takeAll(a, 'mmo.battle_event').filter((msg) => msg.t === 'msg').map((msg) => {
      const read = sanitize.cleanBattleEvent(msg, generation);
      return { sent: msg.text, read: read ? read.text : undefined };
    });
  }
  return out;
}

// The line whose plain reading (sanitize.plainBattleLine: no K17 marks, K18's
// breaks as spaces) contains `part`.
const lineWith6 = (lines, part) => (lines || []).find((l) => sanitize.plainBattleLine(l.sent).includes(part));

function testWave6NpcSeat() {
  // K16: the computer's X ATTACK is its class record's, not a bag's. TrainerAI
  // draws its byte every turn and `chance` 256 is over any byte, so the item
  // comes on turn 1 -- in the computer's slot, after HERO's move.
  const xClass = { uses: 2, chance: 256, item: 'X_ATTACK' };
  const named = npcFight6(1, { name: 'COOLTRAINER♂', aiMods: [1, 3], aiClass: xClass });
  ok(named.opened, 'wave 6: a Red trainer naming itself opens');
  ok(named.seats[0].name === 'COOLTRAINER♂', 'wave 6: the NPC seat is the trainer\'s name');
  ok(JSON.stringify(named.seats[0].aiMods) === '[1,3]', 'wave 6: ...and the referee holds its Red layers');
  ok(named.seats[0].aiClass && named.seats[0].aiClass.item === 'X_ATTACK',
    'wave 6: ...and its TrainerAI record (K16)');
  ok(named.ann.name === 'ANN', 'wave 6: a human seat is still its connection\'s name');
  ok(!named.ann.aiMods, 'wave 6: ...with no layers');
  const used = lineWith6(named.lines, ' used X ATTACK on ');
  ok(used && used.sent === 'COOLTRAINER♂\nused X ATTACK\non FOE!',
    'wave 6: the referee prints the cart\'s AI item line with the trainer\'s name');
  ok(used && used.read === used.sent, 'wave 6: ...and a Red client reads the line whole, ♂ and all');

  const plain = npcFight6(1, { aiClass: xClass });
  ok(plain.seats[0].name === 'TRAINER', 'wave 6: a trainer naming nothing is TRAINER, as before');
  ok(!plain.seats[0].aiMods, 'wave 6: ...and brings no layers');
  const bad = npcFight6(1, { name: 42, aiMods: [] });
  ok(bad.seats[0].name === 'TRAINER', 'wave 6: a name that does not read is dropped, not fatal');
  ok(Array.isArray(bad.seats[0].aiMods) && bad.seats[0].aiMods.length === 0,
    'wave 6: an empty layer list is a class with no layer (YOUNGSTER)');
  const refused = npcFight6(1, { name: 'LASS', aiMods: [9] });
  ok(!refused.opened, 'wave 6: a layer off the cart\'s four refuses the trainer\'s party');
  ok(!refused.record.parties.has(refused.record.npcIds[0]), 'wave 6: ...so no NPC seat is filled');

  const two = npcFight6(1, { name: 'LASS', aiMods: [2] }, 2);
  ok(two.opened && two.seats.length === 2, 'wave 6: a 2v2 trainer is dealt across two seats');
  for (const seat of two.seats) {
    ok(seat.name === 'LASS' && seat.aiMods[0] === 2, 'wave 6: ...each named the trainer, each with its layers');
  }

  const claims = npcFight6(1, { name: 'LASS' }, 1,
    { name: 'MALLORY', aiMods: [2], aiClass: { uses: 1, item: 'POTION' } });
  ok(claims.ann.name === 'ANN', 'wave 6: a human\'s party cannot rename its own seat');
  ok(!claims.ann.aiMods, 'wave 6: ...nor hand it layers');
  ok(claims.ann.aiClass == null, 'wave 6: ...nor a TrainerAI record (K16)');

  // K16 on Gold: wEnemyTrainerItem1 is X ATTACK and TRNATTR_AI_ITEM_SWITCH has
  // ALWAYS_USE (0x10) and no SWITCH_* bit, so AI_SwitchOrTryItem goes straight
  // to AI_TryItem, and `.XItem` on the monster's first turn out
  // (wEnemyTurnsTaken 0) uses it with no draw -- turn 1, before HERO moves.
  const gold = npcFight6(2, {
    name: 'TWINS AMY & MAY', aiMods: [1], trainerItems: ['X_ATTACK'], itemSwitch: 0x10,
  });
  ok(gold.seats[0].name === 'TWINS AMY & MAY', 'wave 6: a Gold trainer\'s "<CLASS> <NAME>" names its seat');
  ok(!gold.seats[0].aiMods, 'wave 6: ...and Gold reads no Red layers');
  ok(gold.seats[0].itemSwitch === 0x10, 'wave 6: ...but its item / switch flags (K16)');
  const goldLine = lineWith6(gold.lines, 'TWINS AMY & MAY');
  ok(goldLine && goldLine.sent === 'TWINS AMY & MAY\nused X ATTACK\non FOE!',
    'wave 6: the Gold referee prints the trainer\'s name in its item line');
  ok(goldLine && goldLine.read === goldLine.sent, 'wave 6: a Gold client reads the & whole');

  const perish = sanitize.cleanBattleEvent({
    battle: 'b', seq: 1, t: 'msg', text: 'Both POKéMON will faint in 3 turns!',
  }, 2);
  ok(perish.text === 'Both POKéMON will faint in 3 turns!', 'wave 6: PerishSongText keeps its é on a Gold reader');
  ok(sanitize.cleanText('Both POKéMON', 60) === 'Both POKMON', 'wave 6: player-typed text stays inside the old set');
}

function testWave6RulesetNulls() {
  const rulesetOf = (rules) => {
    const relay = makeRelay(makeClock());
    const a = dial(relay, 'ANN');
    relay.openCoopBattle('w6r', [a.id], { mode: 'wild', hostId: a.id });
    relay.handle(a.id, { type: 'mmo.battle_ruleset', battle: 'w6r', ...rules });
    const record = relay.battles.get('w6r');
    return record && record.ruleset;
  };
  // The line a client sends, through JSON.parse as the hub reads it.
  const parsed = rulesetOf(JSON.parse('{"chart":[[100,null,100],null,[100,100]],"specialTypes":[1,null,0]}'));
  ok(parsed && parsed.chart.length === 2, 'wave 6: a null chart row is closed up, as the Lua decoder does');
  ok(parsed && parsed.chart[0].join(',') === '100,100', 'wave 6: ...and a null cell (it used to read as 0)');
  ok(parsed && parsed.specialTypes.join(',') === '1,0', 'wave 6: ...and a null index (it used to read as type 0)');
  ok(!rulesetOf({ chart: [[100, 100], [100, 100]], specialTypes: { a: 1 } }),
    'wave 6: an object where specialTypes\' list belongs refuses the ruleset, as on the Lua hub');
  const empty = rulesetOf({ chart: [[100, 100], [100, 100]], specialTypes: {} });
  ok(empty && empty.specialTypes.length === 0, 'wave 6: an empty object is the empty list, as Lua decodes it');
  const line = sanitize.cleanBattleEvent(JSON.parse(
    '{"battle":"b","seq":1,"t":"msg","text":"POK\\u00e9MON \\u2026 \\u2642\\u2640 &"}',
  ), 1);
  ok(line.text === 'POKéMON … ♂♀ &', 'wave 6: \\u escapes decode to the glyphs a Red reader keeps');
}

// ------------------------------------------------------------------
// K16 of docs/plans/gen12-referee-remaining-gaps.md, through the hub: one Gold
// trainer's kit across a 2v2. Its TrainerClassAttributes facts (`trainerItems`,
// `aiFlags`, `itemSwitch`, `baseReward`) ride the side-"b" upload onto every
// seat the trainer is dealt across, each seat's entry carrying the SAME
// `trainerItems` object -- how the referee knows the seats are one trainer.
// The referee keeps one kit for it (battle2 Turn `trainerKitOf`): an item
// either seat uses is gone for both; `aiFlags` / `itemSwitch` are read, never
// spent, and stay per seat. A human's party hands its own seat none of them.
// Twin of the K16 block in tests/hub_battle.lua.
// ------------------------------------------------------------------

// ANN and BOB against one Gold trainer of two FOEs, each at a fifth of its HP
// (`npc` merged into the side-"b" upload, `own` into ANN's), through turn 1:
// the entries the hub handed Turn.attempt, the seats, and ANN's lines read plain.
function kitFight16(npc, own) {
  const relay = makeRelay(makeClock(), { generation: 2 });
  const seen = spyAttempt(relay);
  const a = dial2(relay, 'ANN');
  const b = dial2(relay, 'BOB');
  const id = 'k16';
  relay.openCoopBattle(id, [a.id, b.id], { mode: 'coop_npc', hostId: a.id });
  relay.handle(a.id, { type: 'mmo.battle_ruleset', battle: id, chart: CHART2 });
  relay.handle(a.id, {
    type: 'mmo.battle_party', battle: id, side: 'a', mons: [sheet2({ species: 'HERO' })], ...(own || {}),
  });
  relay.handle(b.id, {
    type: 'mmo.battle_party', battle: id, side: 'a', mons: [sheet2({ species: 'HERO' })],
  });
  const weak = () => ({ ...sheet2({ species: 'FOE', hp: 100 }), hp: 20 });
  relay.handle(a.id, {
    type: 'mmo.battle_party', battle: id, side: 'b', mons: [weak(), weak()], ...(npc || {}),
  });
  const record = relay.battles.get(id);
  if (!record || !record.sim) return { opened: false, record };
  const out = {
    opened: true,
    record,
    ann: record.sim.byId.get(a.id),
    annEntry: entryOf(seen, 'a', a.id),
    seats: record.npcIds.map((npcId) => record.sim.byId.get(npcId)),
    entries: record.npcIds.map((npcId) => entryOf(seen, 'b', npcId)),
    lines: [],
  };
  a.peer.outbox.length = 0;
  relay.handle(a.id, {
    type: 'mmo.battle_choice', battle: id, action: 'fight', move: 0, target: 3,
  });
  relay.handle(b.id, {
    type: 'mmo.battle_choice', battle: id, action: 'fight', move: 0, target: 4,
  });
  out.lines = takeAll(a, 'mmo.battle_event').filter((msg) => msg.t === 'msg')
    .map((msg) => sanitize.plainBattleLine(msg.text));
  return out;
}

const countPart16 = (lines, part) => (lines || []).filter((line) => line.includes(part)).length;

function testK16GoldTrainerKit() {
  // Both FOEs at a fifth of their HP: AI_TryItem's `.HealItem` (no CONTEXT_USE
  // / UNKNOWN_USE) uses a POTION outright at or under a quarter, no draw -- so
  // each seat, asked on its own, would drink one. ALWAYS_USE carries no
  // SWITCH_* bit: AI_SwitchOrTryItem goes to the item check alone.
  const kit = kitFight16({
    name: 'TWINS AMY & MAY', trainerItems: ['POTION'], aiFlags: 1, itemSwitch: 0x10, baseReward: 7,
  });
  ok(kit.opened, 'K16: a Gold 2v2 against one trainer opens');
  ok(kit.opened && kit.seats.length === 2, 'K16: ...dealt across two seats');
  for (let i = 0; i < 2; i += 1) {
    const entry = kit.opened && kit.entries[i];
    ok(entry && entry.trainerItems && entry.trainerItems.join(',') === 'POTION',
      `K16: the hub hands seat ${i + 1} the trainer's items`);
    ok(entry && entry.baseReward === 7, `K16: ...and its base reward (${i + 1})`);
    ok(kit.opened && kit.seats[i].aiFlags === 1, `K16: the referee holds its AI flags (${i + 1})`);
    ok(kit.opened && kit.seats[i].itemSwitch === 0x10, `K16: ...its item / switch flags (${i + 1})`);
    ok(kit.opened && kit.seats[i].bag == null, `K16: ...and no bag (${i + 1})`);
  }
  ok(kit.opened && kit.entries[0].trainerItems === kit.entries[1].trainerItems,
    "K16: one trainer, one item list -- the same object on both seats' entries");
  ok(countPart16(kit.lines, 'TWINS AMY & MAY used POTION on FOE!') === 1,
    'K16: one POTION is one use -- the second seat finds wEnemyTrainerItem1 spent');

  // The same fight with a POTION in both slots: each seat drinks one, so the
  // single use above is the shared kit and not the second seat declining.
  const pair = kitFight16({ name: 'TWINS AMY & MAY', trainerItems: ['POTION', 'POTION'], itemSwitch: 0x10 });
  ok(countPart16(pair.lines, 'TWINS AMY & MAY used POTION on FOE!') === 2,
    'K16: two POTIONs are two uses, one a seat');

  // A human's party names none of it for its own seat.
  const claims = kitFight16({ trainerItems: ['POTION'] },
    {
      trainerItems: ['POTION'], aiFlags: 1, itemSwitch: 0x10, baseReward: 7,
    });
  ok(claims.opened && claims.annEntry && claims.annEntry.trainerItems == null,
    "K16: a human's party cannot hand its seat trainer items");
  ok(claims.opened && claims.annEntry && claims.annEntry.baseReward == null, 'K16: ...nor a base reward');
  ok(claims.opened && claims.ann.aiFlags == null, 'K16: ...nor AI flags');
  ok(claims.opened && claims.ann.itemSwitch == null, 'K16: ...nor item / switch flags');
}

testGen3SimSelection();
testGen3OneVOne();
testGen3CoopNpc();
testGen3WildCatch();
testGen3MidFightMoveset();
testGen3PvpMovesetDropped();
testGen3DialectAndLimits();
testGen3PayDayAndHoldersOnly();
testGen3PvpPaysNoPayDay();
testGen3FamilyMixedCarts();
testGen3FamilyFocusPunch();
testGen3FamilyLinkRules();
testGen1NoFamily();
testGen2TypeIdsBoost();
testGen2Family();
testGen2FamilyGoldAndNone();
testGen2FamilyPvp();
testGen12LevelUpForward();
testLearnRulesExported();
testGen2LevelUpAndSheet();
testPvpForgery();
testBasePpKept();
testTransformedLearn();
testLearnUnderOverlays();
testMimicLearnRealReferee();
testTransformResend();
testTimeOfDay();
testMimicChoiceGen1Only();
testGen3LevelUpRead();
testGen12PayDayForward();
testGen12PayDayOnRun();
testIdRefusedPastForty();
testMapIdRefusedPastSixtyFour();
testHappinessGen2Only();
testWave5ChartOrder();
testWave5BatonPass();
testWave5Gender();
testWave5PoolNum();
testWave5LineBudget();
testWave6NpcSeat();
testWave6RulesetNulls();
testK16GoldTrainerKit();

console.log(`hub_battle: ${passed} checks passed`);
