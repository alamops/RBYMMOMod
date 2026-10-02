#!/usr/bin/env node
'use strict';

/*
 * Cross-runtime parity suite for the hub envelope: Hub.lua ↔ relay.js.
 *
 * BattleSim event streams stay in battle_turn.test.js. This file pins the
 * seats a client would notice if the two hosting paths drifted: admit under
 * playerId, duplicate-id refuse, protocol refuse wording, mediated KO /
 * disconnect-forfeit settlement keyed by playerId, the mmo.relay hard cut,
 * and the generation lock (PROTOCOL 30: one Gen 3 hub seats FireRed,
 * LeafGreen and Emerald and refuses Gen 1 / Gen 2, and the other way round).
 *
 * Expected digests come from luajit running
 * tests/drivers/hub_protocol_parity.lua. When luajit is not on PATH the
 * committed fixture stands in; when it is present both are checked.
 *
 * Regenerate:
 *   luajit tests/drivers/hub_protocol_parity.lua . > tests/fixtures/hub_protocol_parity.json
 *
 * Run: node --test server/hub_protocol_parity.test.js
 */

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const {
  Relay, PROTOCOL, DEFAULT_SPRITE, DEFAULT_SPRITE_GEN2,
} = require('./lib/relay.js');
const { createLog } = require('./lib/log.js');

const ROOT = path.join(__dirname, '..');
const DRIVER = path.join(ROOT, 'tests', 'drivers', 'hub_protocol_parity.lua');
const FIXTURE = path.join(ROOT, 'tests', 'fixtures', 'hub_protocol_parity.json');

const ID_A = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const ID_B = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const ID_C = 'cccccccccccccccccccccccccccccccc';
const ID_D = 'dddddddddddddddddddddddddddddddd';

const CHART = [[100, 100], [100, 100]];
const quiet = createLog({ level: 'error' });

function makeClock(start = 0) {
  let t = start;
  return {
    now: () => t,
    advance(ms) { t += ms; },
  };
}

function makeRelay(clock) {
  const relay = new Relay({
    maxPlayers: 8,
    log: quiet,
    now: clock.now,
  });
  relay.forceBattleSeed = 1;
  return relay;
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

function mon(o) {
  const opts = o || {};
  return {
    species: opts.species || 'ALPHA',
    level: opts.level === undefined ? 50 : opts.level,
    hp: opts.hp === undefined ? 300 : opts.hp,
    maxHp: opts.maxHp === undefined ? (opts.hp === undefined ? 300 : opts.hp) : opts.maxHp,
    stats: {
      atk: opts.atk === undefined ? 200 : opts.atk,
      def: opts.def === undefined ? 200 : opts.def,
      spd: opts.spd === undefined ? 100 : opts.spd,
      spc: opts.spc === undefined ? 100 : opts.spc,
    },
    moves: [{
      id: 'thump',
      pp: 20,
      power: opts.power === undefined ? 200 : opts.power,
      accuracy: 255,
      type: 0,
      effect: 0,
      chance: 0,
    }],
  };
}

function bruiser() {
  return mon({ atk: 999, spd: 999, power: 200 });
}

function glassjaw() {
  return mon({ species: 'BETA', hp: 1, def: 1, spd: 1, power: 20 });
}

function dial(relay, name, playerId) {
  const peer = { outbox: [], closed: false, remoteAddress: '127.0.0.1' };
  peer.send = (msg) => peer.outbox.push(msg);
  peer.close = () => { peer.closed = true; };
  const ephemeral = relay.accept(peer);
  relay.handle(ephemeral, {
    type: 'mmo.hello',
    proto: PROTOCOL,
    name,
    sprite: DEFAULT_SPRITE,
    map: 'PALLET',
    x: 5,
    y: 5,
    facing: 'down',
    playerId,
  });
  return { peer, id: playerId, name, ephemeral };
}

function slimOutcome(msg) {
  if (!msg) return null;
  return {
    outcome: msg.outcome,
    reason: msg.reason,
    winners: msg.winners,
    losers: msg.losers,
  };
}

function slimBoard(relay) {
  return relay.board.export().map((row) => ({
    id: row.id,
    name: row.name,
    points: row.points,
    played: row.played,
    won: row.won,
  }));
}

function slimWelcome(msg) {
  if (!msg) return null;
  const out = {
    id: msg.id,
    ranked: msg.ranked === true,
    points: msg.points,
  };
  if (msg.claim !== undefined) out.claim = msg.claim;
  if (msg.ticket !== undefined) out.ticket = msg.ticket;
  return out;
}

function slimRefuse(msg) {
  if (!msg) return null;
  return { message: msg.message };
}

// The reason is normalised to a sentinel rather than left absent: a nil field
// vanishes from a Lua table, and "no key" and "null" are not the same value
// to the comparison against it.
function slimDecline(msg) {
  if (!msg) return { absent: true };
  return {
    kind: msg.kind,
    reason: msg.reason || '(none)',
    named: msg.name !== undefined && msg.name !== null,
  };
}

function openFight(relay, a, b) {
  relay.handle(a.id, { type: 'mmo.request', to: b.id, kind: 'battle' });
  relay.handle(b.id, {
    type: 'mmo.respond', to: a.id, kind: 'battle', accept: true,
  });
  const hostSess = take(a, 'mmo.session');
  const guestSess = take(b, 'mmo.session');
  return {
    id: hostSess && hostSess.id,
    hostRole: hostSess && hostSess.role,
    guestRole: guestSess && guestSess.role,
  };
}

function uploadReady(relay, a, b, battleId, aMons, bMons) {
  relay.handle(a.id, {
    type: 'mmo.battle_ruleset', battle: battleId, chart: CHART,
  });
  relay.handle(a.id, {
    type: 'mmo.battle_party', battle: battleId, mons: aMons || [bruiser()],
  });
  relay.handle(b.id, {
    type: 'mmo.battle_party', battle: battleId, mons: bMons || [glassjaw()],
  });
  take(a, 'mmo.battle_ready');
  take(b, 'mmo.battle_ready');
}

function fightItOut(relay, a, b, battleId) {
  let outcome = null;
  for (let turn = 0; turn < 30; turn += 1) {
    if (!relay.battles.has(battleId)) break;
    takeAll(a, 'mmo.battle_event');
    takeAll(b, 'mmo.battle_event');
    relay.handle(a.id, {
      type: 'mmo.battle_choice', battle: battleId, action: 'fight', move: 0,
    });
    relay.handle(b.id, {
      type: 'mmo.battle_choice', battle: battleId, action: 'fight', move: 0,
    });
    outcome = take(a, 'mmo.battle_outcome') || take(b, 'mmo.battle_outcome');
    if (outcome) break;
  }
  return outcome;
}

// ------------------------------------------------------------------
// generation lock (PROTOCOL 20, widened to 3 by PROTOCOL 30)
// ------------------------------------------------------------------
//
// Twins of the Lua driver's generation helpers; the argument for each is
// written there. Map ids and sprite names are synthetic engine-shaped
// strings -- nothing here is read off a cart.

const ID_E = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';
const ID_F = 'ffffffffffffffffffffffffffffffff';

function makeGenRelay(clock, generation) {
  const relay = new Relay({
    maxPlayers: 8,
    log: quiet,
    now: clock.now,
    generation,
  });
  relay.forceBattleSeed = 1;
  return relay;
}

// `generation` and `version` pass through untouched -- undefined stays
// absent, which is how the Lua side's nil reaches the hub.
function dialAs(relay, name, playerId, o) {
  const peer = { outbox: [], closed: false, remoteAddress: '127.0.0.1' };
  peer.send = (msg) => peer.outbox.push(msg);
  peer.close = () => { peer.closed = true; };
  const ephemeral = relay.accept(peer);
  relay.handle(ephemeral, {
    type: 'mmo.hello',
    proto: PROTOCOL,
    name,
    map: o.map || 'PALLET',
    x: 5,
    y: 5,
    facing: 'down',
    playerId,
    sprite: o.sprite,
    generation: o.generation,
    version: o.version,
  });
  return { peer, id: playerId, name, ephemeral };
}

function slimPresence(p) {
  if (!p) return { absent: true };
  return {
    id: p.id,
    name: p.name,
    sprite: p.sprite || '(none)',
    version: p.version || '(none)',
    map: p.map || '(none)',
  };
}

function slimRoster(players) {
  return (players || []).map(slimPresence)
    .sort((x, y) => (x.id < y.id ? -1 : x.id > y.id ? 1 : 0));
}

function outcomeOf(side) {
  const refuse = take(side, 'mmo.error');
  const welcome = take(side, 'mmo.welcome');
  return {
    admitted: welcome !== null,
    refuse: refuse ? refuse.message : '(none)',
    closed: side.peer.closed === true,
  };
}

function runGeneration() {
  return [
    {
      name: 'generation_gen3_hub_seats_every_gen3_cart',
      result: (() => {
        const relay = makeGenRelay(makeClock(), 3);
        const fr = dialAs(relay, 'LEAF', ID_A, {
          generation: 3, version: 'firered',
          sprite: 'OBJ_EVENT_GFX_GREEN_NORMAL', map: 'FR_PALLET_TOWN',
        });
        const frWelcome = take(fr, 'mmo.welcome');
        const em = dialAs(relay, 'MAY', ID_B, {
          generation: 3, version: 'emerald',
          sprite: 'OBJ_EVENT_GFX_MAY_NORMAL', map: 'EM_LITTLEROOT_TOWN',
        });
        const emWelcome = take(em, 'mmo.welcome');
        const joinAtFr = take(fr, 'mmo.join');
        const lg = dialAs(relay, 'GREEN', ID_C, {
          generation: 3, version: 'leafgreen', map: 'FR_VIRIDIAN_CITY',
        });
        const lgWelcome = take(lg, 'mmo.welcome');
        const liar = dialAs(relay, 'LIAR', ID_D, {
          generation: 3, version: 'red',
          sprite: 'OBJ_EVENT_GFX_RED_NORMAL', map: 'FR_PALLET_TOWN',
        });
        const liarWelcome = take(liar, 'mmo.welcome');
        const laterAtEm = takeAll(em, 'mmo.join').map((msg) => msg.player);
        return {
          generation: relay.generation,
          frWelcomed: frWelcome !== null,
          emWelcomed: emWelcome !== null,
          lgWelcomed: lgWelcome !== null,
          liarWelcomed: liarWelcome !== null,
          emSees: slimRoster(emWelcome && emWelcome.players),
          frSeesJoin: slimPresence(joinAtFr && joinAtFr.player),
          emSeesLater: slimRoster(laterAtEm),
          liarSees: slimRoster(liarWelcome && liarWelcome.players),
          players: relay.playerCount,
        };
      })(),
    },
    {
      name: 'generation_gen3_refused_by_gen1_and_gen2_hubs',
      result: (() => {
        const gen1 = makeGenRelay(makeClock(), 1);
        const atGen1 = outcomeOf(dialAs(gen1, 'LEAF', ID_A, {
          generation: 3, version: 'firered', sprite: 'OBJ_EVENT_GFX_GREEN_NORMAL',
        }));
        const gen2 = makeGenRelay(makeClock(), 2);
        const atGen2 = outcomeOf(dialAs(gen2, 'MAY', ID_B, {
          generation: 3, version: 'emerald', sprite: 'OBJ_EVENT_GFX_MAY_NORMAL',
        }));
        return {
          atGen1, gen1Players: gen1.playerCount,
          atGen2, gen2Players: gen2.playerCount,
        };
      })(),
    },
    {
      name: 'generation_gen1_and_gen2_refused_by_gen3_hub',
      result: (() => {
        const relay = makeGenRelay(makeClock(), 3);
        const red = outcomeOf(dialAs(relay, 'RED', ID_A, {
          generation: 1, version: 'red', sprite: DEFAULT_SPRITE,
        }));
        const legacy = outcomeOf(dialAs(relay, 'OLD', ID_B, {
          sprite: DEFAULT_SPRITE,
        }));
        const gold = outcomeOf(dialAs(relay, 'GOLD', ID_C, {
          generation: 2, version: 'gold', sprite: DEFAULT_SPRITE_GEN2,
        }));
        return { red, legacy, gold, players: relay.playerCount };
      })(),
    },
    {
      name: 'generation_unknown_refused_missing_is_gen1',
      result: (() => {
        const relay = makeGenRelay(makeClock(), 1);
        const four = outcomeOf(dialAs(relay, 'FOUR', ID_A, { generation: 4 }));
        const zero = outcomeOf(dialAs(relay, 'ZERO', ID_B, { generation: 0 }));
        const text = outcomeOf(dialAs(relay, 'TEXT', ID_C, { generation: '1' }));
        const yes = outcomeOf(dialAs(relay, 'YES', ID_D, { generation: true }));
        const legacy = dialAs(relay, 'OLD', ID_E, { sprite: DEFAULT_SPRITE });
        const legacyOutcome = outcomeOf(legacy);
        const yellow = dialAs(relay, 'YELLOW', ID_F, {
          generation: 1, version: 'yellow', sprite: DEFAULT_SPRITE,
        });
        const yellowWelcome = take(yellow, 'mmo.welcome');
        const mixed = dialAs(relay, 'MIXED', ID_A, {
          generation: 1, version: 'emerald', sprite: DEFAULT_SPRITE,
        });
        const mixedWelcome = take(mixed, 'mmo.welcome');
        const joinsAtLegacy = takeAll(legacy, 'mmo.join').map((msg) => msg.player);
        return {
          four, zero, text, yes,
          legacy: legacyOutcome,
          yellowWelcomed: yellowWelcome !== null,
          mixedWelcomed: mixedWelcome !== null,
          legacySees: slimRoster(joinsAtLegacy),
          players: relay.playerCount,
        };
      })(),
    },
  ];
}

function runJs() {
  return [
    {
      name: 'admit_welcome',
      result: (() => {
        const clock = makeClock();
        const relay = makeRelay(clock);
        const a = dial(relay, 'ANN', ID_A);
        return {
          welcome: slimWelcome(take(a, 'mmo.welcome')),
          clientId: a.id,
          board: slimBoard(relay),
        };
      })(),
    },
    {
      name: 'refuse_duplicate_id',
      result: (() => {
        const clock = makeClock();
        const relay = makeRelay(clock);
        dial(relay, 'ANN', ID_A);
        const peer = { outbox: [], closed: false, remoteAddress: '127.0.0.1' };
        peer.send = (msg) => peer.outbox.push(msg);
        peer.close = () => { peer.closed = true; };
        const ephemeral = relay.accept(peer);
        relay.handle(ephemeral, {
          type: 'mmo.hello',
          proto: PROTOCOL,
          name: 'ANN2',
          sprite: DEFAULT_SPRITE,
          map: 'PALLET',
          x: 1,
          y: 1,
          facing: 'down',
          playerId: ID_A,
        });
        const player = { peer };
        return {
          refuse: slimRefuse(take(player, 'mmo.error')),
          closed: peer.closed === true,
        };
      })(),
    },
    {
      name: 'refuse_wrong_proto',
      result: (() => {
        const clock = makeClock();
        const relay = makeRelay(clock);
        const peer = { outbox: [], closed: false, remoteAddress: '127.0.0.1' };
        peer.send = (msg) => peer.outbox.push(msg);
        peer.close = () => { peer.closed = true; };
        const ephemeral = relay.accept(peer);
        relay.handle(ephemeral, {
          type: 'mmo.hello',
          proto: PROTOCOL - 1,
          name: 'OLD',
          sprite: DEFAULT_SPRITE,
          map: 'PALLET',
          x: 1,
          y: 1,
          facing: 'down',
          playerId: ID_C,
        });
        const player = { peer };
        return {
          refuse: slimRefuse(take(player, 'mmo.error')),
          protocol: PROTOCOL,
        };
      })(),
    },
    {
      // The invite, end to end: the busy a roster row is drawn from, the
      // reason a refusal carries, and two asks that crossed. Every field is
      // one a client reads to decide whether to *offer* a battle or what to
      // say when one comes back, so a one-sided drift is a refusal that
      // reads correctly on one hosting path and as a snub on the other.
      name: 'invite_busy_reason_and_cross',
      result: (() => {
        const clock = makeClock();
        const relay = makeRelay(clock);
        const a = dial(relay, 'ASKER', ID_A);
        const b = dial(relay, 'ASKED', ID_B);
        take(a, 'mmo.welcome'); take(b, 'mmo.welcome');
        takeAll(a, 'mmo.join'); takeAll(b, 'mmo.join');
        a.peer.outbox = []; b.peer.outbox = [];

        // A client's own word on being mid-fight, which no hub can see itself
        relay.handle(b.id, {
          type: 'mmo.move', map: 'PALLET', x: 6, y: 5, facing: 'down', busy: true,
        });
        const busyMove = take(a, 'mmo.move');
        relay.handle(b.id, {
          type: 'mmo.move', map: 'PALLET', x: 6, y: 5, facing: 'down', busy: 'yes',
        });
        const looseMove = take(a, 'mmo.move');
        a.peer.outbox = []; b.peer.outbox = [];

        // An ask nobody is there to answer
        relay.handle(a.id, {
          type: 'mmo.request', to: 'nobodyatall', kind: 'battle',
        });
        const gone = slimDecline(take(a, 'mmo.decline'));
        a.peer.outbox = []; b.peer.outbox = [];

        // A refusal that carries why, and one that made its reason up
        relay.handle(a.id, { type: 'mmo.request', to: b.id, kind: 'battle' });
        take(b, 'mmo.request');
        relay.handle(b.id, {
          type: 'mmo.respond', to: a.id, kind: 'battle', accept: false,
          reason: 'fighting',
        });
        const reasoned = slimDecline(take(a, 'mmo.decline'));

        relay.handle(a.id, { type: 'mmo.request', to: b.id, kind: 'battle' });
        take(b, 'mmo.request');
        relay.handle(b.id, {
          type: 'mmo.respond', to: a.id, kind: 'battle', accept: false,
          reason: 'your mother',
        });
        const forged = slimDecline(take(a, 'mmo.decline'));
        a.peer.outbox = []; b.peer.outbox = [];

        // Two invites that crossed are an agreement, not a collision
        relay.handle(a.id, { type: 'mmo.request', to: b.id, kind: 'battle' });
        relay.handle(b.id, { type: 'mmo.request', to: a.id, kind: 'battle' });
        const crossA = take(a, 'mmo.session');
        const crossB = take(b, 'mmo.session');
        const crossed = {
          id: (crossA && crossA.id) || '(none)',
          askerRole: (crossA && crossA.role) || '(none)',
          answererRole: (crossB && crossB.role) || '(none)',
          refusals: takeAll(a, 'mmo.decline').length
            + takeAll(b, 'mmo.decline').length,
        };

        return {
          busy: Boolean(busyMove && busyMove.busy === true),
          looseBusy: Boolean(looseMove && looseMove.busy === true),
          gone,
          reasoned,
          forged,
          crossed,
        };
      })(),
    },
    {
      name: 'invite_busy_mediated_fight',
      result: (() => {
        const clock = makeClock();
        const relay = makeRelay(clock);
        const a = dial(relay, 'HOST', ID_A);
        const b = dial(relay, 'ALLY', ID_B);
        const c = dial(relay, 'ASKER', ID_C);
        take(a, 'mmo.welcome'); take(b, 'mmo.welcome'); take(c, 'mmo.welcome');
        takeAll(a, 'mmo.join'); takeAll(b, 'mmo.join'); takeAll(c, 'mmo.join');
        a.peer.outbox = []; b.peer.outbox = []; c.peer.outbox = [];

        relay.handle(c.id, { type: 'mmo.request', to: b.id, kind: 'trade' });
        take(b, 'mmo.request');
        a.peer.outbox = []; b.peer.outbox = []; c.peer.outbox = [];
        relay.openCoopBattle('c-busy', [a.id, b.id],
          { mode: 'coop_npc', hostId: a.id });
        const published = take(c, 'mmo.move');
        b.peer.outbox = []; c.peer.outbox = [];
        relay.handle(b.id, {
          type: 'mmo.respond', to: c.id, kind: 'trade', accept: true,
        });
        const stacked = slimDecline(take(c, 'mmo.decline'));
        const stackedSession = take(c, 'mmo.session') || take(b, 'mmo.session');
        c.peer.outbox = []; b.peer.outbox = [];
        relay.handle(c.id, { type: 'mmo.request', to: b.id, kind: 'battle' });
        const midFight = slimDecline(take(c, 'mmo.decline'));
        const reached = take(b, 'mmo.request');
        b.peer.outbox = []; c.peer.outbox = [];
        relay.handle(b.id, { type: 'mmo.request', to: c.id, kind: 'trade' });
        const fromFighter = take(c, 'mmo.request');
        return {
          hadSession: Boolean(relay.get(b.id) && relay.get(b.id).sessionId),
          publishedBusy: Boolean(published && published.busy === true),
          stacked,
          stackedSession: stackedSession != null,
          midFight,
          reachedFighter: reached != null,
          fromFighter: fromFighter != null,
        };
      })(),
    },
    {
      name: 'mediated_ko_settle',
      result: (() => {
        const clock = makeClock();
        const relay = makeRelay(clock);
        const a = dial(relay, 'HOST', ID_A);
        const b = dial(relay, 'GUEST', ID_B);
        take(a, 'mmo.welcome');
        take(b, 'mmo.welcome');
        takeAll(a, 'mmo.join');
        takeAll(b, 'mmo.join');
        const sess = openFight(relay, a, b);
        a.peer.outbox = [];
        b.peer.outbox = [];
        uploadReady(relay, a, b, sess.id);
        a.peer.outbox = [];
        b.peer.outbox = [];
        const outcome = fightItOut(relay, a, b, sess.id);
        return {
          session: sess,
          outcome: slimOutcome(outcome),
          board: slimBoard(relay),
          battleGone: !relay.battles.has(sess.id),
        };
      })(),
    },
    {
      name: 'mediated_forfeit_disconnect',
      result: (() => {
        const clock = makeClock();
        const relay = makeRelay(clock);
        const a = dial(relay, 'STAYA', ID_A);
        const b = dial(relay, 'DROPB', ID_B);
        take(a, 'mmo.welcome');
        take(b, 'mmo.welcome');
        takeAll(a, 'mmo.join');
        takeAll(b, 'mmo.join');
        const sess = openFight(relay, a, b);
        a.peer.outbox = [];
        b.peer.outbox = [];
        uploadReady(relay, a, b, sess.id, [
          mon({ atk: 40, def: 40, spd: 40, power: 40, hp: 100 }),
        ], [
          mon({ species: 'BETA', atk: 40, def: 40, spd: 40, power: 40, hp: 100 }),
        ]);
        a.peer.outbox = [];
        b.peer.outbox = [];
        // Mirror Hub:drop(client) — leaveBattle / reconnect grace / tick past grace.
        // drop() keys by playerId (string), not the client object.
        assert.ok(relay.drop(b.id), 'drop starts reconnect grace on a live sim');
        clock.advance((60 + 2) * 1000);
        relay.tickBattles();
        const outcome = take(a, 'mmo.battle_outcome');
        return {
          session: sess,
          outcome: slimOutcome(outcome),
          board: slimBoard(relay),
          battleGone: !relay.battles.has(sess.id),
        };
      })(),
    },
    {
      name: 'relay_hard_cut_in_battle',
      result: (() => {
        const clock = makeClock();
        const relay = makeRelay(clock);
        const a = dial(relay, 'HOST', ID_A);
        const b = dial(relay, 'GUEST', ID_B);
        take(a, 'mmo.welcome');
        take(b, 'mmo.welcome');
        takeAll(a, 'mmo.join');
        takeAll(b, 'mmo.join');
        const sess = openFight(relay, a, b);
        a.peer.outbox = [];
        b.peer.outbox = [];
        uploadReady(relay, a, b, sess.id);
        a.peer.outbox = [];
        b.peer.outbox = [];
        const before = (relay.get(a.id) && relay.get(a.id).relayDrops) || 0;
        relay.handle(a.id, {
          type: 'mmo.relay', to: b.id, payload: { hello: 1 },
        });
        const after = (relay.get(a.id) && relay.get(a.id).relayDrops) || 0;
        return {
          session: sess,
          guestRelay: take(b, 'mmo.relay') !== null,
          hostRelayDrops: after - before || after,
        };
      })(),
    },
    {
      name: 'ranking_carries_player_id',
      result: (() => {
        const clock = makeClock();
        const relay = makeRelay(clock);
        const a = dial(relay, 'HOST', ID_A);
        const b = dial(relay, 'GUEST', ID_B);
        take(a, 'mmo.welcome');
        take(b, 'mmo.welcome');
        takeAll(a, 'mmo.join');
        takeAll(b, 'mmo.join');
        const sess = openFight(relay, a, b);
        a.peer.outbox = [];
        b.peer.outbox = [];
        uploadReady(relay, a, b, sess.id);
        a.peer.outbox = [];
        b.peer.outbox = [];
        fightItOut(relay, a, b, sess.id);
        a.peer.outbox = [];
        relay.handle(a.id, { type: 'mmo.ranks' });
        const ranking = take(a, 'mmo.ranking');
        const entries = ((ranking && ranking.entries) || []).map((row) => ({
          id: row.id, name: row.name, points: row.points,
        }));
        return { entries };
      })(),
    },
    {
      name: 'bag_proof_hold_and_cancel',
      result: (() => {
        const clock = makeClock();
        const relay = makeRelay(clock);
        const a = dial(relay, 'ANN', ID_A);
        const b = dial(relay, 'BOB', ID_B);
        take(a, 'mmo.welcome');
        take(b, 'mmo.welcome');
        takeAll(a, 'mmo.join');
        takeAll(b, 'mmo.join');
        const sess = openFight(relay, a, b);
        a.peer.outbox = [];
        b.peer.outbox = [];
        relay.handle(a.id, {
          type: 'mmo.battle_ruleset', battle: sess.id, chart: CHART,
        });
        relay.handle(a.id, {
          type: 'mmo.battle_party', battle: sess.id,
          mons: [mon({ hp: 40, maxHp: 100, power: 40 })],
          bag: [{ id: 'NOT_A_REAL_ITEM', count: 1 }],
        });
        const record = relay.battles.get(sess.id);
        const unknownRefused = !record.parties.has(a.id);
        relay.handle(a.id, {
          type: 'mmo.battle_party', battle: sess.id,
          mons: [mon({ hp: 40, maxHp: 100, power: 40 })],
          bag: [{ id: 'POTION', count: 1 }],
        });
        relay.handle(b.id, {
          type: 'mmo.battle_party', battle: sess.id,
          mons: [mon({ species: 'BETA', hp: 100, power: 40 })],
        });
        relay.handle(a.id, {
          type: 'mmo.battle_choice', battle: sess.id,
          action: 'item', item: 'POTION',
        });
        const bag = record.bags.get(a.id) || {};
        const held = record.bagHold[a.id] === 'POTION' && bag.POTION === 1;
        relay.handle(a.id, {
          type: 'mmo.battle_choice', battle: sess.id, action: 'cancel',
        });
        const bagAfter = record.bags.get(a.id) || {};
        return {
          unknownRefused,
          heldThenCancelled: held
            && record.bagHold[a.id] == null
            && bagAfter.POTION === 1,
          simOpen: !!record.sim,
        };
      })(),
    },
    {
      name: 'sprite_and_chat_gates',
      result: (() => {
        const clock = makeClock();
        const relay = makeRelay(clock);
        const a = dial(relay, 'ANN', ID_A);
        const b = dial(relay, 'BOB', ID_B);
        take(a, 'mmo.welcome');
        take(b, 'mmo.welcome');
        takeAll(a, 'mmo.join');
        takeAll(b, 'mmo.join');
        a.peer.outbox = [];
        b.peer.outbox = [];
        relay.handle(a.id, { type: 'mmo.sprite', sprite: 'SPRITE_BLUE' });
        const firstSprite = relay.get(a.id).sprite;
        relay.handle(a.id, { type: 'mmo.sprite', sprite: 'SPRITE_YELLOW' });
        const gatedSprite = relay.get(a.id).sprite;
        relay.handle(a.id, {
          type: 'mmo.chat', scope: 'local', text: 'hello once',
        });
        const firstChat = take(b, 'mmo.chat') !== null;
        relay.handle(a.id, {
          type: 'mmo.chat', scope: 'local', text: 'hello twice',
        });
        const gatedChat = take(b, 'mmo.chat') === null;
        clock.advance(600);
        relay.handle(a.id, { type: 'mmo.sprite', sprite: 'SPRITE_YELLOW' });
        const afterGraceSprite = relay.get(a.id).sprite;
        return {
          firstSprite,
          gatedSprite,
          firstChat,
          gatedChat,
          afterGraceSprite,
        };
      })(),
    },
    {
      name: 'coop_pvp_team_settle',
      result: (() => {
        const clock = makeClock();
        const relay = makeRelay(clock);
        const a = dial(relay, 'A1', ID_A);
        const b = dial(relay, 'A2', ID_B);
        const c = dial(relay, 'B1', ID_C);
        const d = dial(relay, 'B2', ID_D);
        takeAll(a, 'mmo.welcome');
        takeAll(b, 'mmo.welcome');
        takeAll(c, 'mmo.welcome');
        takeAll(d, 'mmo.welcome');
        takeAll(a, 'mmo.join');
        takeAll(b, 'mmo.join');
        takeAll(c, 'mmo.join');
        takeAll(d, 'mmo.join');
        const id = 'c1';
        relay.openCoopBattle(id, [a.id, b.id, c.id, d.id], {
          mode: 'coop_pvp', hostId: a.id,
          sides: { a: [a.id, b.id], b: [c.id, d.id] },
        });
        const side = (players) => players.map((p) => ({
          id: p.id, name: p.name, ranked: true,
        }));
        relay.coopMatches.set(id, {
          a: side([a, b]), b: side([c, d]),
          reports: new Map(),
          everyone: [a.id, b.id, c.id, d.id],
          startedAt: clock.now(),
        });
        relay.handle(a.id, {
          type: 'mmo.battle_ruleset', battle: id, chart: CHART,
        });
        for (const p of [a, b]) {
          relay.handle(p.id, {
            type: 'mmo.battle_party', battle: id, mons: [bruiser()],
          });
        }
        for (const p of [c, d]) {
          relay.handle(p.id, {
            type: 'mmo.battle_party', battle: id, mons: [glassjaw()],
          });
        }
        const seats = [a, b, c, d];
        for (const p of seats) p.peer.outbox = [];
        let outcome = null;
        for (let turn = 0; turn < 30; turn += 1) {
          if (!relay.battles.has(id)) break;
          for (const p of seats) {
            takeAll(p, 'mmo.battle_event');
            relay.handle(p.id, {
              type: 'mmo.battle_choice', battle: id, action: 'fight', move: 0,
            });
          }
          outcome = take(a, 'mmo.battle_outcome') || take(b, 'mmo.battle_outcome');
          if (outcome) break;
        }
        return {
          outcome: slimOutcome(outcome),
          board: slimBoard(relay),
          battleGone: !relay.battles.has(id),
          mode: 'coop_pvp',
        };
      })(),
    },
    {
      name: 'coop_npc_team_settle',
      result: (() => {
        const clock = makeClock();
        const relay = makeRelay(clock);
        const a = dial(relay, 'NPCA', ID_A);
        const b = dial(relay, 'NPCB', ID_B);
        takeAll(a, 'mmo.welcome');
        takeAll(b, 'mmo.welcome');
        takeAll(a, 'mmo.join');
        takeAll(b, 'mmo.join');
        const id = 'c1';
        relay.openCoopBattle(id, [a.id, b.id], {
          mode: 'coop_npc', hostId: a.id,
        });
        const record = relay.battles.get(id);
        const npcIds = (record && record.npcIds) || [];
        relay.handle(a.id, {
          type: 'mmo.battle_ruleset', battle: id, chart: CHART,
        });
        relay.handle(a.id, {
          type: 'mmo.battle_party', battle: id, side: 'a', mons: [bruiser()],
        });
        relay.handle(b.id, {
          type: 'mmo.battle_party', battle: id, side: 'a', mons: [bruiser()],
        });
        relay.handle(a.id, {
          type: 'mmo.battle_party', battle: id, side: 'b',
          mons: [glassjaw(), glassjaw()],
        });
        a.peer.outbox = [];
        b.peer.outbox = [];
        let outcome = null;
        for (let turn = 0; turn < 30; turn += 1) {
          if (!relay.battles.has(id)) break;
          takeAll(a, 'mmo.battle_event');
          takeAll(b, 'mmo.battle_event');
          for (const p of [a, b]) {
            relay.handle(p.id, {
              type: 'mmo.battle_choice', battle: id, action: 'fight', move: 0,
            });
          }
          outcome = take(a, 'mmo.battle_outcome') || take(b, 'mmo.battle_outcome');
          if (outcome) break;
        }
        return {
          outcome: slimOutcome(outcome),
          battleGone: !relay.battles.has(id),
          mode: 'coop_npc',
          npcSeats: npcIds.length,
          npcA: npcIds[0],
          npcB: npcIds[1],
        };
      })(),
    },
    ...runGeneration(),
    ...runGen3(),
    ...runPayDay3(),
  ];
}

// ------------------------------------------------------------------
// Gen 3 (PROTOCOL 30): twins of the Lua driver's gen3_* scenarios -- a
// mediated fight on lib/battle3, its opening event stream, and the Gen 3
// dialect read by lib/sanitize. Absent values are the "(nil)" sentinel on both
// sides, because a nil vanishes from a Lua table where JSON keeps a null.
// ------------------------------------------------------------------

const sanitize = require('./lib/sanitize.js');

const CHART3 = [10, 12, 20, 11, 10, 20, 12, 11, 20, -1, -1, 0, 0, 7, 0];
const POOL3 = ['33:0:40:0:100:35:0:0:0:51:POOL_TAP', '52:4:40:10:100:25:10:0:0:18:POOL_SPARK'];

function move3(o) {
  const p = o || {};
  const row = {
    id: p.id || 'TAP3',
    num: p.num || 33,
    pp: p.pp || 20,
    maxPp: p.maxPp || 20,
    power: p.power || 90,
    type: p.type || 0,
    accuracy: p.accuracy || 100,
    effect: p.effect || 0,
    chance: p.chance || 0,
    target: p.target || 0,
    priority: p.priority || 0,
    flags: p.flags || 51,
  };
  // Lua's `o.x or default` keeps an explicit 0 only where 0 is not falsy in
  // Lua -- which is everywhere; mirror that for the fields set to 0 below.
  for (const key of ['power', 'accuracy', 'flags']) {
    if (p[key] === 0) row[key] = 0;
  }
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
    hp: p.hp || 150,
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

const orNil = (v) => (v === undefined || v === null ? '(nil)' : v);

const EVENT_KEYS = ['t', 'text', 'amount', 'hp', 'maxHp', 'slot', 'side', 'status',
  'mon', 'target', 'spread', 'stat', 'stage', 'delta', 'holding', 'confused', 'team'];

function slimEvent(e) {
  const out = {};
  for (const k of EVENT_KEYS) out[k] = orNil(e[k]);
  out.moves = Array.isArray(e.moves) ? e.moves.length : 0;
  return out;
}

function dialect3() {
  const caught = mon3({ species: 'CAUGHT' });
  delete caught.weight;
  delete caught.hiddenPower;
  delete caught.beatUp;
  caught.ball = 4;
  caught.personality = 305419896;
  caught.otId = 4660;
  caught.ivs = {
    hp: 31, atk: 0, def: 1, spe: 2, spa: 3, spd: 4,
  };
  const noAbility = mon3();
  delete noAbility.ability;
  const badGender = mon3();
  badGender.gender = 'X';
  const named = mon3({
    moves: [move3({ name: 'Tap Three' }), move3({
      id: 'B', num: 182, power: 0, accuracy: 0, effect: 111, target: 16, priority: 3, flags: 0,
    })],
  });
  named.abilityName = 'BLAZE';
  named.itemName = 'ORAN';
  named.sleepTurns = 3;
  named.status = 'SLP';
  return [
    ['ruleset', {
      generation: 3,
      typeTable: CHART3,
      movePool: POOL3,
      terrain: 9,
      weather: 'SAND',
      underwater: false,
      seed: 99,
      specialTypes: [10, 11],
    }],
    ['ruleset', {
      typeTable: CHART3,
      movePool: ['7:0:40:0:100:10:0:0:-0:3:X', {
        id: 'ROW',
        num: 12,
        pp: 5,
        power: 0,
        accuracy: 0,
        type: 0,
        effect: 38,
        chance: 0,
        target: 0,
        priority: 0,
        flags: 2,
      }],
    }],
    ['ruleset', { typeTable: [0, -1, 10] }],
    ['ruleset', { typeTable: CHART3, movePool: ['+7:0:40:0:100:10:0:0:0:3:X'] }],
    ['ruleset', { typeTable: CHART3, weather: 'FOG' }],
    ['ruleset', { typeTable: CHART3, underwater: 'yes' }],
    ['ruleset', { movePool: ['999:0:40:0:100:10:0:0:0:3:X'] }],
    ['mon', named],
    ['mon', caught],
    ['mon', noAbility],
    ['mon', badGender],
    ['party', { battle: 'b1', mons: [named] }],
    ['party', { battle: 'b1', mons: [caught] }],
    ['bag', [{ id: 13, count: 2, name: 'TONIC' }, { id: '1', count: 1 }, { id: 350, count: 1 }]],
    ['bag', { 13: 2, 22: 1 }],
    ['bag', [{ id: '0x0D', count: 1 }]],
    ['bag', [{ id: 5, count: 1 }]],
    ['bag', [{ id: 13, count: 1 }, { id: '13', count: 1 }]],
    ['choice', {
      battle: 'b1', action: 'fight', move: 1, target: 4, pass: 2,
    }],
    ['choice', {
      battle: 'b1', action: 'item', item: '9', dexCaught: true, slot: 0,
    }],
    ['choice', {
      battle: 'b1', action: 'item', item: '9', dexCaught: 1,
    }],
    ['event', {
      battle: 'b1', seq: 3, t: 'stat', slot: 0, side: 'a', text: 'ATK fell', stat: 'atk', stage: -2, delta: -2, amount: 2,
    }],
    ['event', {
      battle: 'b1', seq: 4, t: 'held', slot: 3, side: 'b', mon: 0, amount: 139, holding: 0, text: 'ORAN BERRY',
    }],
    ['event', {
      battle: 'b1', seq: 5, t: 'ball', slot: 0, side: 'a', target: 3, amount: 4, text: '4',
    }],
    ['event', {
      battle: 'b1',
      seq: 6,
      t: 'anim',
      slot: 1,
      side: 'a',
      text: 'SWEEP',
      target: 4,
      spread: 1,
      stat: 'hp',
      stage: 9,
      delta: -20,
      holding: 999,
    }],
    ['event', {
      battle: 'b1', seq: 7, t: 'weather', text: 'RAIN', amount: 1,
    }],
    ['event', {
      battle: 'b1',
      seq: 8,
      t: 'moves',
      slot: 0,
      side: 'a',
      moves: [move3(), {
        id: 'OLD', pp: 1, power: 1, accuracy: 1, type: 0, effect: 0, chance: 0,
      }],
    }],
    ['moveset', { battle: 'b1', mon: 0, moves: [move3(), move3({ id: 'NEW', num: 44 })] }],
  ];
}

/*
 * The Gen 3 dialect at the edges where the two twins used to read one message
 * two ways: a list that is an object, a number LuaJIT's tonumber reads and JS's
 * Number does not (or the reverse), a choice index that is `true`. The nulls
 * here are real: the Lua driver spells each as NULL and closes it up the way
 * src/link/Json.lua's decoder does, because that is all the Lua hub is ever
 * handed of one. Twin of edges3 in tests/drivers/hub_protocol_parity.lua.
 */
function edges3() {
  const chartHole = [10, 12, 20, null, 11, 10, 20, 12, 11, 20, -1, -1, 0, 0, 7, 0];
  const chartGap = [10, 12, null, 11, 10, 20, 12, 11, 20, -1, -1, 0, 0, 7, 0];
  return [
    ['ruleset', { typeTable: chartHole }],
    ['ruleset', { typeTable: chartGap }],
    ['ruleset', { typeTable: CHART3, specialTypes: [10, null, 11] }],
    ['ruleset', { typeTable: CHART3, movePool: [null, POOL3[0]] }],
    ['ruleset', { typeTable: CHART3, specialTypes: { a: 1 } }],
    ['ruleset', { typeTable: CHART3, movePool: { a: 'x' } }],
    ['ruleset', { typeTable: CHART3, specialTypes: {} }],
    ['ruleset', { typeTable: CHART3, movePool: { a: null } }],
    ['ruleset', { typeTable: { a: 10 } }],
    ['mon', mon3({ types: [null, 10] })],
    ['mon', mon3({ moves: [move3(), null] })],
    ['mon', mon3({ heldItem: '1e-9999999' })],
    ['mon', mon3({ level: '\u00a050' })],
    ['mon', mon3({ level: ' \t50\n' })],
    ['mon', mon3({ moves: [move3({ priority: '-0x1' })] })],
    ['mon', mon3({ ability: '0x1.8p1', holdEffect: '0b11' })],
    ['party', { battle: 'b1', mons: [mon3(), null] }],
    ['party', { battle: 'b1', generation: [3], mons: [mon3()] }],
    ['bag', [{ id: 13, count: 2 }, null]],
    ['bag', { 13: 2, 22: null }],
    ['bag', { 13: null }],
    ['choice', {
      battle: 'b1', action: 'fight', move: 0, pass: true,
    }],
    ['choice', {
      battle: 'b1', action: 'fight', move: 0, pass: '',
    }],
    ['choice', {
      battle: 'b1', action: 'fight', move: 0, pass: [3],
    }],
    ['choice', { battle: 'b1', action: 'switch', slot: true }],
    ['choice', {
      battle: 'b1', action: 'fight', move: '0x0', pass: ' 2 ',
    }],
    ['moveset', { battle: 'b1', mon: 0, moves: [null, move3()] }],
    ['moveset', { battle: 'b1', mon: true, moves: [move3()] }],
    ['event', {
      battle: 'b1',
      seq: 9,
      t: 'anim',
      slot: 0,
      side: 'a',
      text: 'SWEEP',
      target: true,
      spread: '',
      stage: [1],
      holding: '0x10',
    }],
  ];
}

// Gen 1 / Gen 2 read paths, as they were before Gen 3 had a dialect: a stray
// `num` on an older row, and Gen 3's choice fields on an older choice, are
// ignored rather than read -- on both hosting paths. Twin of gen12 in the Lua
// driver.
function gen12() {
  const stray = {
    id: 'thump', pp: 20, power: 40, accuracy: 255, type: 0, effect: 0, chance: 0, num: 7,
  };
  const sheet = {
    species: 'ALPHA',
    level: 50,
    hp: 100,
    maxHp: 100,
    stats: {
      atk: 90, def: 90, spd: 90, spc: 90,
    },
    moves: [stray],
  };
  const asked = {
    battle: 'b1', action: 'fight', move: 0, pass: 'far', dexCaught: 1,
  };
  return [
    ['mon', sheet],
    ['party', { battle: 'b1', mons: [sheet] }, 1],
    ['ruleset', { chart: CHART, metronomePool: [stray] }, 1],
    ['ruleset', { chart: CHART, metronomePool: [stray] }, 2],
    ['ruleset', { chart: CHART, metronomePool: [stray] }],
    ['choice', asked, 1],
    ['choice', asked, 2],
    ['choice', asked],
    ['event', { battle: 'b1', seq: 1, t: 'ability' }, 1],
    ['event', {
      battle: 'b1', seq: 2, t: 'stat', slot: 0, side: 'a', target: 2, stage: 1, delta: 1, holding: 3,
    }, 2],
    ['event', {
      battle: 'b1', seq: 3, t: 'moves', slot: 0, side: 'a', moves: [stray],
    }, 1],
    ['moveset', { battle: 'b1', mon: 0, moves: [stray] }, 1],
  ];
}

/*
 * The badge rules' wire (docs/plans/gen3-badge-rules.md K1-K3), each input read
 * by lib/sanitize under the reader's generation (the third field): a Gen 3
 * party's badge numbers, a Gen 3 sheet's traded / unfateful (and the retired
 * fateful, neither copied nor read), the `obey` event and its eight tokens, a
 * Gold party's badge names, and the Gen 1 / Gen 2 ruleset's typeIds -- an
 * unreadable list dropped with the ruleset kept, a JSON null closed up first
 * (the Lua driver spells it NULL). Twin of badgeRules in
 * tests/drivers/hub_protocol_parity.lua.
 */
const OBEY_TOKENS = ['ignores_asleep', 'uses_random_move', 'falls_asleep', 'hits_itself',
  'loafing', 'wont_obey', 'turned_away', 'pretend_not_notice'];

function badgeRules() {
  const flagged = (traded, unfateful) => {
    const sheet = mon3({ species: 'MEW', speciesNum: 151 });
    if (traded !== undefined) sheet.traded = traded;
    if (unfateful !== undefined) sheet.unfateful = unfateful;
    return sheet;
  };
  const retired = (fateful) => {
    const sheet = mon3({ species: 'MEW', speciesNum: 151 });
    sheet.fateful = fateful;
    return sheet;
  };
  const gold = {
    species: 'ALPHA',
    level: 50,
    hp: 100,
    maxHp: 100,
    stats: {
      atk: 90, def: 90, spe: 90, spa: 90, spd: 90,
    },
    moves: [{
      id: 'thump', pp: 20, power: 40, accuracy: 255, type: 0, effect: 0, chance: 0,
    }],
  };
  const wide = [];
  for (let i = 1; i <= sanitize.BATTLE_TYPE_MAX + 1; i += 1) wide.push(`T${i}`);
  const full = wide.slice(0, sanitize.BATTLE_TYPE_MAX);
  const cases = [
    ['party', { battle: 'b1', mons: [mon3()], badges: ['1', '3', '8'] }, 3],
    ['party', {
      battle: 'b1', mons: [mon3()], badges: ['1', '3', '8', '3', '9', 'bad id!', 5, true, ''],
    }, 3],
    ['party', { battle: 'b1', mons: [mon3()], badges: ['bad id!', 7] }, 3],
    ['party', { battle: 'b1', mons: [flagged(true, true)], badges: ['2'] }, 3],
    ['mon', flagged(true, true)],
    ['mon', flagged(false, false)],
    ['mon', flagged(true, undefined)],
    ['mon', flagged('yes', undefined)],
    ['mon', flagged(undefined, 1)],
    ['mon', flagged(undefined, true)],
    ['mon', retired(true)],
    ['mon', retired(1)],
    ['party', {
      battle: 'b1', mons: [gold], badges: ['ZEPHYR', 'MINERAL', 'RISING', 'BOULDER', 'EARTH'],
    }, 2],
    ['party', { battle: 'b1', mons: [gold], badges: ['ZEPHYR', 'ZEPHYR', 'bad id!'] }, 2],
    ['ruleset', { chart: CHART, typeIds: ['NORMAL', 'FIRE'] }, 2],
    ['ruleset', { chart: CHART, typeIds: ['NORMAL', 'PSYCHIC_TYPE'], specialTypes: [1] }, 1],
    ['ruleset', { chart: CHART, typeIds: full }, 2],
    ['ruleset', { chart: CHART, typeIds: wide }, 2],
    ['ruleset', { chart: CHART, typeIds: ['NORMAL', 7] }, 2],
    ['ruleset', { chart: CHART, typeIds: ['NORMAL', 'BAD TYPE'] }, 2],
    ['ruleset', { chart: CHART, typeIds: ['NORMAL', 'X'.repeat(41)] }, 2],
    ['ruleset', { chart: CHART, typeIds: [] }, 2],
    ['ruleset', { chart: CHART, typeIds: 'NORMAL' }, 2],
    ['ruleset', { chart: CHART, typeIds: ['NORMAL', 'mymod.FAIRY'], specialTypes: [1] }, 2],
    ['ruleset', { chart: CHART, typeIds: ['NORMAL', null, 'FIRE'] }, 2],
    ['ruleset', { chart: CHART, typeIds: [null, null] }, 2],
    ['ruleset', { chart: CHART, typeIds: ['NORMAL', null, 'BAD TYPE'] }, 2],
    ['ruleset', { chart: CHART, specialTypes: [1] }, 1],
    ['ruleset', { chart: CHART }, 2],
    ['ruleset', { typeTable: CHART3, typeIds: ['NORMAL'] }, 3],
  ];
  OBEY_TOKENS.forEach((token, i) => {
    cases.push(['event', {
      battle: 'b1', seq: 21 + i, t: 'obey', slot: 0, side: 'a', text: token,
    }, 3]);
  });
  ['LOAFING', 'loafing around', '', 7].forEach((text, i) => {
    cases.push(['event', {
      battle: 'b1', seq: 41 + i, t: 'obey', slot: 1, side: 'a', text,
    }, 3]);
  });
  cases.push(['event', {
    battle: 'b1', seq: 50, t: 'obey', slot: 0, side: 'a',
  }, 3]);
  cases.push(['event', {
    battle: 'b1', seq: 51, t: 'obey', slot: 0, side: 'a', text: 'loafing',
  }, 2]);
  return cases;
}

/*
 * Gen 3 Pay Day coins and the holders-only exp fact, through the hub (sheet
 * doc §1 outcome, §7.1 exp). Twins of gen3_coop_wild_payday and
 * gen3_pvp_payday_absent in the Lua driver: a coop_wild field where ANN's
 * PAYER scatters coins and BOB's BOOMER takes the wild mon down with it, so
 * BOB's seat gets the holders-only fact and the outcome carries side a's coins;
 * then the same Pay Day in a 1v1, which pays nobody.
 */
const IDLE3 = {
  id: 'IDLE', num: 150, effect: 85, power: 0, target: 16, flags: 0,
};

function slimExp(e) {
  if (!e) return '(nil)';
  return {
    slot: orNil(e.slot),
    participants: orNil(e.participants),
    mon: orNil(e.mon),
    level: orNil(e.level),
    species: orNil(e.species),
  };
}

function slimPaid(msg) {
  if (!msg) return '(nil)';
  return {
    outcome: msg.outcome,
    reason: orNil(msg.reason),
    winners: orNil(msg.winners),
    losers: orNil(msg.losers),
    payDay: orNil(msg.payDay),
  };
}

const PAYDAY_EDGES = [200, 0, 1, 65535, 65536, -3, 1.5, '0x10', ' 7 ', '1e2', true, [3]];
const PARTICIPANT_EDGES = [0, '0', -1, 1.9, 12, 13, ' 0 '];

function runPayDay3() {
  return [
    {
      name: 'gen3_coop_wild_payday',
      result: (() => {
        const relay = makeGenRelay(makeClock(), 3);
        const a = dialAs(relay, 'ANN', ID_A, {
          generation: 3, version: 'firered', sprite: 'OBJ_EVENT_GFX_RED_NORMAL', map: 'FR_PALLET_TOWN',
        });
        const b = dialAs(relay, 'BOB', ID_B, {
          generation: 3, version: 'emerald', sprite: 'OBJ_EVENT_GFX_MAY_NORMAL', map: 'EM_LITTLEROOT_TOWN',
        });
        const id = 'c1';
        const opened = relay.openCoopBattle(id, [a.id, b.id], {
          mode: 'coop_wild', hostId: a.id,
        }) != null;
        relay.handle(a.id, { type: 'mmo.battle_ruleset', battle: id, typeTable: CHART3 });
        relay.handle(a.id, {
          type: 'mmo.battle_party',
          battle: id,
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
          battle: id,
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
          battle: id,
          side: 'b',
          mons: [mon3({
            species: 'WILDLING', def: 5, spe: 1, catchRate: 45, moves: [move3(IDLE3)],
          })],
        });
        const record = relay.battles.get(id);
        const simOpen = !!(record && record.sim);
        a.peer.outbox = [];
        b.peer.outbox = [];
        const exps = [];
        let outcome = null;
        for (let turn = 0; turn < 6; turn += 1) {
          if (!relay.battles.has(id)) break;
          relay.handle(a.id, {
            type: 'mmo.battle_choice', battle: id, action: 'fight', move: 0,
          });
          relay.handle(b.id, {
            type: 'mmo.battle_choice', battle: id, action: 'fight', move: 0,
          });
          for (const msg of takeAll(a, 'mmo.battle_event')) {
            if (msg.t === 'exp') exps.push(msg);
          }
          outcome = take(a, 'mmo.battle_outcome');
          if (outcome) break;
        }
        const atBob = take(b, 'mmo.battle_outcome');
        const payEdges = PAYDAY_EDGES.map((v) => {
          const got = sanitize.cleanBattleOutcome({ battle: 'b1', outcome: 'win', payDay: v }, 3);
          return { kept: got !== null, payDay: orNil(got && got.payDay) };
        });
        const partEdges = PARTICIPANT_EDGES.map((v, i) => {
          const e = {
            battle: 'b1', seq: i + 1, t: 'exp', slot: 0, level: 5, participants: v,
          };
          return {
            gen3: orNil((sanitize.cleanBattleEvent(e, 3) || {}).participants),
            none: orNil((sanitize.cleanBattleEvent(e) || {}).participants),
          };
        });
        return {
          opened,
          simOpen,
          exp: exps.map(slimExp),
          expRead3: exps.map((e) => slimExp(sanitize.cleanBattleEvent(e, 3))),
          expRead2: exps.map((e) => slimExp(sanitize.cleanBattleEvent(e, 2))),
          expRead1: exps.map((e) => slimExp(sanitize.cleanBattleEvent(e, 1))),
          outcome: slimPaid(outcome),
          outcomeAtBob: slimPaid(atBob),
          read3: slimPaid(outcome && sanitize.cleanBattleOutcome(outcome, 3)),
          readNone: slimPaid(outcome && sanitize.cleanBattleOutcome(outcome)),
          read2: slimPaid(outcome && sanitize.cleanBattleOutcome(outcome, 2)),
          read1: slimPaid(outcome && sanitize.cleanBattleOutcome(outcome, 1)),
          payEdges,
          partEdges,
          battleGone: !relay.battles.has(id),
        };
      })(),
    },
    {
      name: 'gen3_pvp_payday_absent',
      result: (() => {
        const relay = makeGenRelay(makeClock(), 3);
        const a = dialAs(relay, 'ANN', ID_A, {
          generation: 3, version: 'firered', sprite: 'OBJ_EVENT_GFX_RED_NORMAL', map: 'FR_PALLET_TOWN',
        });
        const b = dialAs(relay, 'BOB', ID_B, {
          generation: 3, version: 'leafgreen', sprite: 'OBJ_EVENT_GFX_RED_NORMAL', map: 'FR_PALLET_TOWN',
        });
        const sess = openFight(relay, a, b);
        relay.handle(a.id, { type: 'mmo.battle_ruleset', battle: sess.id, typeTable: CHART3 });
        relay.handle(a.id, {
          type: 'mmo.battle_party',
          battle: sess.id,
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
          battle: sess.id,
          mons: [mon3({
            species: 'DELTA', hp: 150, def: 5, spe: 1, moves: [move3(IDLE3)],
          })],
        });
        const record = relay.battles.get(sess.id);
        let outcome = null;
        for (let turn = 0; turn < 6; turn += 1) {
          if (!relay.battles.has(sess.id)) break;
          relay.handle(a.id, {
            type: 'mmo.battle_choice', battle: sess.id, action: 'fight', move: 0,
          });
          relay.handle(b.id, {
            type: 'mmo.battle_choice', battle: sess.id, action: 'fight', move: 0,
          });
          outcome = take(a, 'mmo.battle_outcome') || take(b, 'mmo.battle_outcome');
          if (outcome) break;
        }
        const tally = record && record.sim && record.sim.snapshot().payDay;
        return {
          counted: orNil(tally && tally.a),
          outcome: slimPaid(outcome),
          battleGone: !relay.battles.has(sess.id),
        };
      })(),
    },
  ];
}

function runGen3() {
  return [
    {
      name: 'gen3_mediated_fight',
      result: (() => {
        const clock = makeClock();
        const relay = makeGenRelay(clock, 3);
        const a = dialAs(relay, 'ANN', ID_A, {
          generation: 3, version: 'firered', sprite: 'OBJ_EVENT_GFX_RED_NORMAL', map: 'FR_PALLET_TOWN',
        });
        const b = dialAs(relay, 'BOB', ID_B, {
          generation: 3, version: 'emerald', sprite: 'OBJ_EVENT_GFX_MAY_NORMAL', map: 'EM_LITTLEROOT_TOWN',
        });
        take(a, 'mmo.welcome');
        take(b, 'mmo.welcome');
        takeAll(a, 'mmo.join');
        takeAll(b, 'mmo.join');
        const sess = openFight(relay, a, b);
        a.peer.outbox = [];
        b.peer.outbox = [];
        relay.handle(a.id, {
          type: 'mmo.battle_ruleset',
          battle: sess.id,
          generation: 3,
          typeTable: CHART3,
          movePool: POOL3,
          terrain: 3,
        });
        const hurt = mon3({
          atk: 400, def: 400, spe: 300, hp: 100, maxHp: 150, moves: [move3({ power: 200 })],
        });
        relay.handle(a.id, {
          type: 'mmo.battle_party',
          battle: sess.id,
          mons: [hurt],
          bag: [{ id: 13, count: 2, name: 'TONIC' }, { id: '350', count: 1 }],
        });
        relay.handle(b.id, {
          type: 'mmo.battle_party',
          battle: sess.id,
          mons: [mon3({
            species: 'DELTA', hp: 1, def: 5, atk: 10, spe: 1, moves: [move3({ power: 10 })],
          })],
        });
        const record = relay.battles.get(sess.id);
        const opened = !!record.sim;
        relay.handle(a.id, {
          type: 'mmo.battle_choice', battle: sess.id, action: 'item', item: '13', slot: 0,
        });
        const held = record.bagHold[a.id];
        relay.handle(b.id, {
          type: 'mmo.battle_choice', battle: sess.id, action: 'fight', move: 0,
        });
        const bagAfter = {
          potion: orNil(record.bags.get(a.id)['13']),
          flute: orNil(record.bags.get(a.id)['350']),
        };
        const outcome = fightItOut(relay, a, b, sess.id);
        return {
          opened,
          ruleset: {
            triples: record.ruleset.typeTable.length / 3,
            pool: record.ruleset.movePool,
            terrain: record.ruleset.terrain,
          },
          held: orNil(held),
          bagAfter,
          outcome: slimOutcome(outcome),
          battleGone: !relay.battles.has(sess.id),
        };
      })(),
    },
    {
      name: 'gen3_event_stream',
      result: (() => {
        const clock = makeClock();
        const relay = makeGenRelay(clock, 3);
        const a = dialAs(relay, 'ANN', ID_A, {
          generation: 3, version: 'leafgreen', sprite: 'OBJ_EVENT_GFX_RED_NORMAL', map: 'FR_PALLET_TOWN',
        });
        const b = dialAs(relay, 'BOB', ID_B, {
          generation: 3, version: 'firered', sprite: 'OBJ_EVENT_GFX_RED_NORMAL', map: 'FR_PALLET_TOWN',
        });
        const sess = openFight(relay, a, b);
        relay.handle(a.id, { type: 'mmo.battle_ruleset', battle: sess.id, typeTable: CHART3 });
        relay.handle(a.id, {
          type: 'mmo.battle_party',
          battle: sess.id,
          mons: [
            mon3({
              ability: 22, types: [10], moves: [move3({ type: 10, effect: 4, chance: 100 })],
            }),
            mon3({ species: 'ZETA', ability: 2, types: [11] }),
          ],
        });
        relay.handle(b.id, {
          type: 'mmo.battle_party',
          battle: sess.id,
          mons: [mon3({
            species: 'ETA', ability: 45, types: [12], heldItem: 139, holdEffect: 1, holdEffectParam: 10,
          })],
        });
        const events = [];
        for (let i = 0; i < 3; i += 1) {
          if (!relay.battles.has(sess.id)) break;
          for (const msg of takeAll(a, 'mmo.battle_event')) events.push(slimEvent(msg));
          relay.handle(a.id, {
            type: 'mmo.battle_choice', battle: sess.id, action: 'fight', move: 0,
          });
          relay.handle(b.id, {
            type: 'mmo.battle_choice', battle: sess.id, action: 'fight', move: 0,
          });
        }
        for (const msg of takeAll(a, 'mmo.battle_event')) events.push(slimEvent(msg));
        return { events, count: events.length };
      })(),
    },
    {
      name: 'gen3_dialect',
      result: (() => {
        const cases = dialect3().map(([kind, input]) => {
          let got;
          if (kind === 'ruleset') got = sanitize.cleanBattleRuleset(input, 3);
          else if (kind === 'mon') got = sanitize.cleanBattleMon(input);
          else if (kind === 'party') got = sanitize.cleanBattleParty(input, 3);
          else if (kind === 'bag') got = sanitize.cleanBattleBag(input, 3);
          else if (kind === 'choice') got = sanitize.cleanBattleChoice(input, 3);
          else if (kind === 'event') got = sanitize.cleanBattleEvent(input);
          else if (kind === 'moveset') got = sanitize.cleanBattleMoveset(input, 3);
          return { kind, got: orNil(got) };
        });
        return { cases };
      })(),
    },
    {
      name: 'gen3_wire_edges',
      result: (() => {
        const cases = edges3().map(([kind, input]) => {
          let got;
          if (kind === 'ruleset') got = sanitize.cleanBattleRuleset(input, 3);
          else if (kind === 'mon') got = sanitize.cleanBattleMon(input);
          else if (kind === 'party') got = sanitize.cleanBattleParty(input, 3);
          else if (kind === 'bag') got = sanitize.cleanBattleBag(input, 3);
          else if (kind === 'choice') got = sanitize.cleanBattleChoice(input, 3);
          else if (kind === 'event') got = sanitize.cleanBattleEvent(input);
          else if (kind === 'moveset') got = sanitize.cleanBattleMoveset(input, 3);
          return { kind, got: orNil(got) };
        });
        return { cases };
      })(),
    },
    {
      name: 'gen12_read_paths',
      result: (() => {
        const cases = gen12().map(([kind, input, gen]) => {
          let got;
          if (kind === 'ruleset') got = sanitize.cleanBattleRuleset(input, gen);
          else if (kind === 'mon') got = sanitize.cleanBattleMon(input);
          else if (kind === 'party') got = sanitize.cleanBattleParty(input, gen);
          else if (kind === 'choice') got = sanitize.cleanBattleChoice(input, gen);
          else if (kind === 'event') got = sanitize.cleanBattleEvent(input, gen);
          else if (kind === 'moveset') got = sanitize.cleanBattleMoveset(input, gen);
          return { kind, got: orNil(got) };
        });
        return { cases };
      })(),
    },
    {
      name: 'badge_rules_dialect',
      result: (() => {
        const cases = badgeRules().map(([kind, input, gen]) => {
          let got;
          if (kind === 'ruleset') got = sanitize.cleanBattleRuleset(input, gen);
          else if (kind === 'mon') got = sanitize.cleanBattleMon(input);
          else if (kind === 'party') got = sanitize.cleanBattleParty(input, gen);
          else if (kind === 'event') got = sanitize.cleanBattleEvent(input, gen);
          return { kind, got: orNil(got) };
        });
        return { cases };
      })(),
    },
  ];
}

function runLua() {
  const luajit = spawnSync('luajit', [DRIVER, ROOT], { encoding: 'utf8' });
  if (luajit.error || luajit.status !== 0) return null;
  return JSON.parse(luajit.stdout);
}

function canonical(value) {
  return JSON.parse(JSON.stringify(value));
}

const jsRuns = canonical(runJs());
const luaRuns = runLua();
const fixture = fs.existsSync(FIXTURE)
  ? JSON.parse(fs.readFileSync(FIXTURE, 'utf8'))
  : null;

const byName = (runs) => new Map(runs.map((entry) => [entry.name, entry]));

test('the hub parity scenarios are all present on both sides', () => {
  assert.ok(jsRuns.length >= 17, 'the JS half built every scenario');
  assert.ok(
    luaRuns || fixture,
    'neither luajit nor tests/fixtures/hub_protocol_parity.json is available -- '
    + 'install luajit or regenerate the fixture with '
    + '`luajit tests/drivers/hub_protocol_parity.lua . > tests/fixtures/hub_protocol_parity.json`',
  );
});

test('JS hub matches the Lua hub, scenario for scenario', async (t) => {
  if (!luaRuns) {
    t.skip('luajit not on PATH -- the committed fixture carries this instead');
    return;
  }
  const lua = byName(luaRuns);
  for (const run of jsRuns) {
    await t.test(run.name, () => {
      const twin = lua.get(run.name);
      assert.ok(twin, `${run.name}: the Lua driver did not produce this scenario`);
      assert.deepStrictEqual(
        run.result, twin.result,
        `${run.name}: hub digest differs`,
      );
    });
  }
});

test('JS hub matches the committed Lua fixture', async (t) => {
  if (!fixture) {
    t.skip('no committed fixture');
    return;
  }
  const pinned = byName(fixture);
  for (const run of jsRuns) {
    await t.test(run.name, () => {
      const twin = pinned.get(run.name);
      assert.ok(twin, `${run.name}: not in the fixture -- regenerate it`);
      assert.deepStrictEqual(run.result, twin.result, `${run.name}: digest differs`);
    });
  }
});

test('the committed hub fixture still is what luajit produces', (t) => {
  if (!luaRuns || !fixture) {
    t.skip('need both luajit and the committed fixture');
    return;
  }
  assert.deepStrictEqual(
    luaRuns, fixture,
    'fixture drifted behind Lua -- regenerate with '
    + '`luajit tests/drivers/hub_protocol_parity.lua . > tests/fixtures/hub_protocol_parity.json`',
  );
});
