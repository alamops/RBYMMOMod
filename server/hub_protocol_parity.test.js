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
    ...runFidelity(),
    ...runFamily2(),
    ...runGaps(),
    ...runWave4(),
    ...runWave5(),
    ...runWave6(),
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
// ignored rather than read -- on both hosting paths. The `stat` case's signed
// `stage` is the one Gen 3 field an older reader keeps (contract K10 of
// docs/plans/gen12-referee-gaps-fix.md). Since that plan's wave 5 a Gen 2 hub
// reads a Metronome pool row's `num` and a choice's `pass` as Gold's own (the
// Gen 2 pool case keeps its 7, the Gen 2 choice's "far" refuses it). Twin of
// gen12 in the Lua driver.
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

/*
 * The referee-fidelity wire (docs/plans/gen12-referee-fidelity.md K1-K3), each
 * input read by lib/sanitize under the reader's generation (the third field; a
 * mon is read with none): K1 `traded` on Gen 1 and Gen 2 sheets (true kept,
 * false and null absent, anything else refuses); K2 Gold's held-item data at
 * and past each bound, ignored on a Gen 1 sheet and never reaching a Gen 3 one;
 * K3 Gold's `held` event (id text, 0 / 1 amount, dropped fields keep the event),
 * refused by a Gen 1 reader, with Gen 3's `held` unchanged. Twin of fidelity()
 * in tests/drivers/hub_protocol_parity.lua -- same cases, same order.
 */
function sheet12(gen, extra) {
  const sheet = {
    species: 'ALPHA',
    level: 50,
    hp: 100,
    maxHp: 100,
    stats: gen === 2
      ? {
        atk: 90, def: 90, spe: 90, spa: 90, spd: 90,
      }
      : {
        atk: 90, def: 90, spd: 90, spc: 90,
      },
    moves: [{
      id: 'thump', pp: 20, power: 40, accuracy: 255, type: 0, effect: 0, chance: 0,
    }],
  };
  return { ...sheet, ...(extra || {}) };
}

function fidelity() {
  const held = {
    heldItem: 'LEFTOVERS', holdEffect: 'HELD_LEFTOVERS', holdParam: 10, itemName: 'LEFTOVERS',
  };
  const gen3Held = {
    battle: 'b1', seq: 80, t: 'held', slot: 3, side: 'b', mon: 0, amount: 139, holding: 0, text: 'ORAN BERRY',
  };
  const held2 = (extra) => ({
    battle: 'b1', seq: 60, t: 'held', slot: 0, side: 'a', mon: 0, text: 'LEFTOVERS', amount: 1, ...(extra || {}),
  });
  const gen3Extra = { ...mon3({ heldItem: 139, holdEffect: 1, holdEffectParam: 10 }), holdParam: 5, mail: true };
  return [
    // K1
    ['mon', sheet12(1, { traded: true })],
    ['mon', sheet12(1, { traded: false })],
    ['mon', sheet12(1, { traded: 'yes' })],
    ['mon', sheet12(1, { traded: 1 })],
    ['mon', sheet12(1, { traded: null })],
    ['mon', sheet12(1, { traded: true, unfateful: true })],
    ['mon', sheet12(1, { generation: 1, traded: true })],
    ['mon', sheet12(2, { traded: true })],
    ['mon', sheet12(2, { traded: false })],
    ['mon', sheet12(2, { traded: 'true' })],
    ['mon', sheet12(2, { traded: 0 })],
    ['mon', sheet12(2, { generation: 2, traded: true, unfateful: true })],
    ['party', { battle: 'b1', mons: [sheet12(1, { traded: true })] }, 1],
    ['party', { battle: 'b1', mons: [sheet12(1, { traded: 'yes' })] }, 1],
    ['party', { battle: 'b1', mons: [sheet12(2, { traded: true })] }, 2],
    // K2 on a Gold sheet
    ['mon', sheet12(2, held)],
    ['mon', sheet12(2, { ...held, mail: true })],
    ['mon', sheet12(2, { ...held, mail: false })],
    ['mon', sheet12(2, { ...held, mail: 'yes' })],
    ['mon', sheet12(2, { ...held, mail: 1 })],
    ['mon', sheet12(2, { ...held, mail: null })],
    ['mon', sheet12(2, { heldItem: 'POLKADOT_BOW', holdEffect: `HELD_${'X'.repeat(27)}` })],
    ['mon', sheet12(2, { holdEffect: `HELD_${'X'.repeat(28)}` })],
    ['mon', sheet12(2, { holdEffect: 'LEFTOVERS' })],
    ['mon', sheet12(2, { holdEffect: 'HELD_leftovers' })],
    ['mon', sheet12(2, { holdEffect: 'HELD_' })],
    ['mon', sheet12(2, { holdEffect: 'HELD_LEFT OVERS' })],
    ['mon', sheet12(2, { holdEffect: 7 })],
    ['mon', sheet12(2, { holdParam: 0 })],
    ['mon', sheet12(2, { holdParam: 255 })],
    ['mon', sheet12(2, { holdParam: 256 })],
    ['mon', sheet12(2, { holdParam: -1 })],
    ['mon', sheet12(2, { holdParam: '12' })],
    ['mon', sheet12(2, { holdParam: 3.7 })],
    ['mon', sheet12(2, { holdParam: true })],
    ['mon', sheet12(2, { holdParam: '' })],
    ['mon', sheet12(2, { itemName: 'MYSTERYBERRY' })],
    ['mon', sheet12(2, { itemName: 'KINGS ROCK OF OLD' })],
    ['mon', sheet12(2, { itemName: 'Pink*Bow' })],
    ['mon', sheet12(2, { itemName: '@@@' })],
    ['mon', sheet12(2, { itemName: 5 })],
    // K2 on a Gen 1 sheet: not its dialect, so ignored rather than refused
    ['mon', sheet12(1, { ...held, mail: true })],
    ['mon', sheet12(1, {
      holdEffect: 7, holdParam: 999, itemName: 5, mail: 'yes',
    })],
    ['mon', sheet12(1, { generation: 1, holdEffect: 'HELD_LEFTOVERS', mail: true })],
    // K2 never reaches a Gen 3 sheet
    ['mon', gen3Extra],
    ['mon', mon3({ holdEffect: 'HELD_LEFTOVERS' })],
    // K1 + K2 through a party, stamped by the hub's generation
    ['party', { battle: 'b1', mons: [sheet12(2, { ...held, traded: true, mail: true })] }, 2],
    ['party', { battle: 'b1', mons: [sheet12(2, { holdEffect: 'LEFTOVERS' })] }, 2],
    ['party', { battle: 'b1', mons: [sheet12(1, held)] }, 1],
    // K3
    ['event', held2(), 2],
    ['event', held2({ seq: 61, text: 'BERRY', amount: 0 }), 2],
    ['event', held2({ seq: 62, amount: 2 }), 2],
    ['event', held2({ seq: 63, amount: -1 }), 2],
    ['event', held2({ seq: 64, amount: '1' }), 2],
    ['event', held2({ seq: 65, amount: true }), 2],
    ['event', held2({ seq: 66, amount: 0.5 }), 2],
    ['event', held2({ seq: 67, text: 'bad id!' }), 2],
    ['event', held2({ seq: 68, text: 7 }), 2],
    ['event', held2({ seq: 69, text: 'GOLD BERRY' }), 2],
    ['event', held2({
      seq: 70, holding: 3, target: 1, mon: 6,
    }), 2],
    ['event', held2({ seq: 71 }), 1],
    ['event', gen3Held, 3],
    ['event', gen3Held],
    ['event', gen3Held, 2],
    ['event', {
      battle: 'b1', seq: 72, t: 'item', slot: 0, side: 'a', text: 'POTION', amount: 5,
    }, 2],
    ['event', {
      battle: 'b1', seq: 73, t: 'ability', slot: 0, side: 'a',
    }, 2],
  ];
}

function runFidelity() {
  return [
    {
      name: 'referee_fidelity_dialect',
      result: (() => {
        const cases = fidelity().map(([kind, input, gen]) => {
          let got;
          if (kind === 'mon') got = sanitize.cleanBattleMon(input);
          else if (kind === 'party') got = sanitize.cleanBattleParty(input, gen);
          else if (kind === 'event') got = sanitize.cleanBattleEvent(input, gen);
          return { kind, got: orNil(got) };
        });
        return { cases };
      })(),
    },
  ];
}

// Gold's cart lineage on a fighter entry (contract K6 of
// docs/plans/gen12-referee-fidelity.md). Twin of the Lua driver's
// gen2_cart_family_stamp; the argument is written there. The digest is the
// entries the referee is handed -- Turn.attempt here, Turn.create there.
function sheet2() {
  return {
    species: 'ALPHA',
    level: 50,
    hp: 300,
    maxHp: 300,
    stats: {
      atk: 100, def: 100, spe: 50, spa: 50, spd: 100,
    },
    moves: [{
      id: 'thump', pp: 20, power: 20, accuracy: 255, type: 0, effect: 0, chance: 0,
    }],
  };
}

function familyFight(generation, versions, mode) {
  const relay = makeGenRelay(makeClock(), generation);
  const seen = {};
  const real = relay.Turn;
  relay.Turn = Object.assign(Object.create(real), {
    attempt: (opts) => {
      seen.opts = opts;
      return real.attempt(opts);
    },
  });
  const ids = [ID_A, ID_B, ID_C, ID_D];
  const sprite = generation === 2 ? DEFAULT_SPRITE_GEN2 : DEFAULT_SPRITE;
  const players = versions.map((version, i) => dialAs(relay, `P${i + 1}`, ids[i], {
    generation, version: version !== '(none)' ? version : undefined, sprite,
  }));
  const memberIds = players.map((p) => p.id);
  const opts = { mode, hostId: memberIds[0] };
  if (mode === 'coop_pvp') {
    opts.sides = { a: [memberIds[0], memberIds[1]], b: [memberIds[2], memberIds[3]] };
  }
  relay.openCoopBattle('kf', memberIds, opts);
  const record = relay.battles.get('kf');
  const sheet = () => (generation === 2 ? sheet2() : mon());
  relay.handle(players[0].id, { type: 'mmo.battle_ruleset', battle: 'kf', chart: CHART });
  for (const p of players) {
    const msg = { type: 'mmo.battle_party', battle: 'kf', mons: [sheet()] };
    if (mode === 'coop_npc') msg.side = 'a';
    relay.handle(p.id, msg);
  }
  if (mode === 'coop_npc') {
    relay.handle(players[0].id, {
      type: 'mmo.battle_party', battle: 'kf', side: 'b', mons: [sheet(), sheet()],
    });
  }
  const npcIds = (record && record.npcIds) || [];
  const entries = [];
  for (const side of ['a', 'b']) {
    for (const entry of (seen.opts && seen.opts.sides[side]) || []) {
      entries.push({
        side,
        seat: npcIds.includes(entry.playerId) ? 'npc' : entry.playerId,
        family: entry.family === undefined || entry.family === null ? '(nil)' : entry.family,
      });
    }
  }
  return { opened: !!(record && record.sim), entries };
}

function runFamily2() {
  return [
    {
      name: 'gen2_cart_family_stamp',
      result: {
        gold: familyFight(2, ['crystal', 'silver'], 'coop_npc'),
        bare: familyFight(2, ['gold', '(none)'], 'coop_npc'),
        spar: familyFight(2, ['crystal', 'gold', 'silver', 'crystal'], 'coop_pvp'),
        kanto: familyFight(1, ['red', 'yellow'], 'coop_npc'),
      },
    },
  ];
}

/*
 * The referee-gap wire (docs/plans/gen12-referee-gaps-fix.md K7-K11, K13),
 * each input read by lib/sanitize under the reader's generation (the third
 * field; a mon is read with none, as the hub reads a caught sheet): K7's
 * base / dvs / statExp blocks, K8's ppUps and Gold priority, K9's moveset
 * level / stats / maxHp, K10's signed stage for an older reader, K11's payDay
 * per reader (payEdges12) and on a run outcome, K13's 40-character id refusal
 * and its 64-character map-id twin, and K14's Gold happiness. Twin of gaps()
 * in tests/drivers/hub_protocol_parity.lua -- same cases, same order; the
 * argument for each is written there.
 */
function k7(gen) {
  if (gen === 2) {
    return {
      base: {
        hp: 41, atk: 52, def: 63, spe: 74, spa: 85, spd: 96,
      },
      dvs: {
        atk: 12, def: 7, spe: 15, spc: 3,
      },
      statExp: {
        hp: 1000, atk: 2000, def: 0, spe: 65535, spc: 7,
      },
    };
  }
  return {
    base: {
      hp: 41, atk: 52, def: 63, spd: 74, spc: 85,
    },
    dvs: {
      atk: 12, def: 7, spd: 15, spc: 3,
    },
    statExp: {
      hp: 1000, atk: 2000, def: 0, spd: 65535, spc: 7,
    },
  };
}

function row12(id, extra) {
  return {
    id, pp: 20, power: 40, accuracy: 255, type: 0, effect: 0, chance: 0, ...(extra || {}),
  };
}

const GROWN1 = {
  atk: 91, def: 92, spd: 93, spc: 94,
};
const GROWN2 = {
  atk: 91, def: 92, spe: 93, spa: 94, spd: 95,
};

function statEvent(seq, stage) {
  return {
    battle: 'b1', seq, t: 'stat', slot: 0, side: 'a', amount: 2, text: 'ATK fell', stage,
  };
}

function gaps() {
  const B1 = {
    hp: 41, atk: 52, def: 63, spd: 74, spc: 85,
  };
  const thump = row12('thump');
  return [
    // K7
    ['mon', sheet12(1, k7(1))],
    ['mon', sheet12(2, k7(2))],
    ['mon', sheet12(2, { ...k7(2), generation: 2 })],
    ['mon', sheet12(1, {
      base: {
        hp: 0, atk: 255, def: 1, spd: 2, spc: 3,
      },
    })],
    ['mon', sheet12(1, { base: { ...B1, atk: 256 } })],
    ['mon', sheet12(1, { base: { ...B1, hp: -1 } })],
    ['mon', sheet12(1, {
      base: {
        atk: 52, def: 63, spd: 74, spc: 85,
      },
    })],
    ['mon', sheet12(2, { base: B1 })],
    ['mon', sheet12(1, { base: [41, 52, 63, 74, 85] })],
    ['mon', sheet12(1, { base: '41' })],
    ['mon', sheet12(1, { base: null, dvs: null, statExp: null })],
    ['mon', sheet12(1, {
      dvs: {
        atk: 15, def: 0, spd: '7', spc: 3.9,
      },
    })],
    ['mon', sheet12(1, {
      dvs: {
        atk: 16, def: 0, spd: 7, spc: 3,
      },
    })],
    ['mon', sheet12(1, {
      dvs: {
        atk: true, def: 0, spd: 7, spc: 3,
      },
    })],
    ['mon', sheet12(1, {
      dvs: {
        atk: '0x10', def: 0, spd: 7, spc: 3,
      },
    })],
    ['mon', sheet12(1, {
      dvs: {
        atk: ' 9 ', def: 0, spd: 7, spc: 3,
      },
    })],
    ['mon', sheet12(2, {
      dvs: {
        atk: 1, def: 2, spd: 3, spc: 4,
      },
    })],
    ['mon', sheet12(2, {
      dvs: {
        atk: 1, def: 2, spe: 3, spc: 4, spa: 9, hp: 5,
      },
    })],
    ['mon', sheet12(2, {
      statExp: {
        hp: 1, atk: 2, def: 3, spe: 4, spa: 5, spd: 6,
      },
    })],
    ['mon', sheet12(1, {
      statExp: {
        hp: 65535, atk: 0, def: 1, spd: 2, spc: 3,
      },
    })],
    ['mon', sheet12(1, {
      statExp: {
        hp: 65536, atk: 0, def: 1, spd: 2, spc: 3,
      },
    })],
    ['mon', sheet12(1, {
      statExp: {
        atk: 0, def: 1, spd: 2, spc: 3,
      },
    })],
    ['mon', { ...sheet12(1, k7(2)), generation: 1 }],
    ['mon', { ...mon3(), ...k7(2) }],
    ['mon', {
      ...mon3(), base: 'x', dvs: 99, statExp: true,
    }],
    ['party', { battle: 'b1', mons: [sheet12(2, k7(2))] }, 2],
    ['party', { battle: 'b1', mons: [sheet12(1, k7(2))] }, 1],
    ['outcome', {
      battle: 'b1', outcome: 'win', reason: 'catch', caught: sheet12(1, k7(1)),
    }, 1],
    ['outcome', {
      battle: 'b1', outcome: 'win', reason: 'catch', caught: sheet12(1, { dvs: { atk: 99 } }),
    }, 1],
    // K8
    ['move', row12('m', { ppUps: 0 }), 1],
    ['move', row12('m', { ppUps: 3 }), 2],
    ['move', row12('m', { ppUps: 4 }), 1],
    ['move', row12('m', { ppUps: -1 }), 2],
    ['move', row12('m', { ppUps: '2' }), 1],
    ['move', row12('m', { ppUps: 1.5 }), 1],
    ['move', row12('m', { ppUps: true }), 1],
    ['move', row12('m', { ppUps: null }), 1],
    ['move', row12('m', { priority: 0 }), 2],
    ['move', row12('m', { priority: 255 }), 2],
    ['move', row12('m', { priority: 256 }), 2],
    ['move', row12('m', { priority: -1 }), 2],
    ['move', row12('m', { priority: 'fast' }), 2],
    ['move', row12('m', { priority: '3' }), 2],
    ['move', row12('m', { priority: 3 }), 1],
    ['move', row12('m', { priority: 'fast' }), 1],
    ['move', row12('m', { priority: 3, ppUps: 2 })],
    ['move', { ...move3(), ppUps: 3, priority: 2 }, 3],
    ['ruleset', { chart: CHART, metronomePool: [row12('m', { priority: 2, ppUps: 0 })] }, 2],
    ['ruleset', { chart: CHART, metronomePool: [row12('m', { priority: 2, ppUps: 0 })] }, 1],
    ['ruleset', { chart: CHART, metronomePool: [row12('m', { ppUps: 9 })] }, 2],
    ['event', {
      battle: 'b1', seq: 4, t: 'moves', slot: 0, side: 'a', moves: [row12('m', { priority: 3, ppUps: 1 })],
    }, 2],
    ['event', {
      battle: 'b1', seq: 5, t: 'moves', slot: 0, side: 'a', moves: [row12('m', { priority: 3, ppUps: 1 })],
    }, 1],
    ['mon', sheet12(2, { moves: [row12('m', { priority: 3, ppUps: 3 })] })],
    ['mon', sheet12(2, { moves: [row12('m', { priority: 300 })] })],
    ['mon', sheet12(1, { moves: [row12('m', { priority: 300 })] })],
    // K9
    ['moveset', {
      battle: 'b1', mon: 0, moves: [thump], level: 51, stats: GROWN1, maxHp: 140,
    }, 1],
    ['moveset', {
      battle: 'b1', mon: 1, moves: [thump], level: 51, stats: GROWN2, maxHp: 140,
    }, 2],
    ['moveset', {
      battle: 'b1', mon: 0, moves: [thump], stats: GROWN1,
    }, 2],
    ['moveset', {
      battle: 'b1', mon: 0, moves: [thump], level: 0,
    }, 1],
    ['moveset', {
      battle: 'b1', mon: 0, moves: [thump], level: 101,
    }, 1],
    ['moveset', {
      battle: 'b1', mon: 0, moves: [thump], level: '50',
    }, 1],
    ['moveset', {
      battle: 'b1', mon: 0, moves: [thump], level: true,
    }, 2],
    ['moveset', {
      battle: 'b1', mon: 0, moves: [thump], maxHp: 0,
    }, 1],
    ['moveset', {
      battle: 'b1', mon: 0, moves: [thump], maxHp: 1000,
    }, 2],
    ['moveset', {
      battle: 'b1', mon: 0, moves: [thump], stats: { atk: 91, def: 92, spd: 93 },
    }, 1],
    ['moveset', {
      battle: 'b1', mon: 0, moves: [thump], stats: { ...GROWN1, atk: 0 },
    }, 1],
    ['moveset', {
      battle: 'b1', mon: 0, moves: [thump], level: 51, stats: null, maxHp: null,
    }, 1],
    ['moveset', {
      battle: 'b1', mon: 0, moves: [move3()], level: 51, stats: GROWN2, maxHp: 140,
    }, 3],
    ['moveset', {
      battle: 'b1', mon: 0, moves: [thump], level: 51, stats: GROWN1, maxHp: 140,
    }],
    // K10
    ['event', statEvent(10, -6), 1],
    ['event', statEvent(11, 6), 1],
    ['event', statEvent(12, -7), 1],
    ['event', statEvent(13, 7), 2],
    ['event', statEvent(14, '-2'), 2],
    ['event', statEvent(15, true), 1],
    ['event', statEvent(16, 2.5), 1],
    ['event', statEvent(17, -1), 2],
    ['event', statEvent(18, -3), 3],
    ['event', statEvent(19, -3)],
    // K13
    ['id', 'i'.repeat(40)],
    ['id', 'i'.repeat(41)],
    ['id', 'i'.repeat(100)],
    ['id', 'a-b_C9'],
    ['id', ''],
    ['id', 'a b'],
    ['reconnect', { battle: 'b'.repeat(40) }],
    ['reconnect', { battle: 'b'.repeat(41) }],
    ['move', row12('m'.repeat(40)), 1],
    ['move', row12('m'.repeat(41)), 1],
    ['mon', sheet12(1, { speciesId: 'S'.repeat(41) })],
    ['mon', sheet12(2, { heldItem: 'H'.repeat(41) })],
    ['event', {
      battle: 'b1', seq: 20, t: 'item', slot: 0, side: 'a', text: 'I'.repeat(41),
    }, 1],
    ['choice', { battle: 'b1', action: 'item', item: 'I'.repeat(41) }, 1],
    ['outcome', { battle: 'b1', outcome: 'win', catcher: 'c'.repeat(41) }, 1],
    ['party', { battle: 'p'.repeat(41), mons: [sheet12(1)] }, 1],
    // K13's twin: a map id refused past 64 characters, never cut
    ['mapId', 'M'.repeat(64)],
    ['mapId', 'M'.repeat(65)],
    ['mapId', 'M'.repeat(200)],
    ['mapId', 'FR_PALLET_TOWN'],
    ['mapId', 'route-1.2'],
    ['mapId', ''],
    ['mapId', '../secret'],
    ['mapId', 'a b'],
    ['mapId', 64],
    // K14
    ['mon', sheet12(2, { happiness: 0 })],
    ['mon', sheet12(2, { happiness: 70 })],
    ['mon', sheet12(2, { happiness: 255 })],
    ['mon', sheet12(2, { happiness: 256 })],
    ['mon', sheet12(2, { happiness: -1 })],
    ['mon', sheet12(2, { happiness: '70' })],
    ['mon', sheet12(2, { happiness: 70.9 })],
    ['mon', sheet12(2, { happiness: ' 9 ' })],
    ['mon', sheet12(2, { happiness: '0x10' })],
    ['mon', sheet12(2, { happiness: true })],
    ['mon', sheet12(2, { happiness: 'fond' })],
    ['mon', sheet12(2, { happiness: [70] })],
    ['mon', sheet12(2, { happiness: null })],
    ['mon', sheet12(2, { ...k7(2), happiness: 200, generation: 2 })],
    ['mon', sheet12(1, { happiness: 70 })],
    ['mon', sheet12(1, { happiness: 'fond' })],
    ['mon', { ...mon3(), happiness: 70 }],
    ['party', { battle: 'b1', mons: [sheet12(2, { happiness: 200 })] }, 2],
    ['party', { battle: 'b1', mons: [sheet12(2, { happiness: 300 })] }, 2],
    ['outcome', {
      battle: 'b1', outcome: 'win', reason: 'catch', caught: sheet12(2, { happiness: 70 }),
    }, 2],
    // K11 on an escape: every reader keeps a run outcome's coins
    ['outcome', {
      battle: 'b1', outcome: 'win', winners: ['nw1a'], losers: [ID_A], reason: 'run', payDay: 350,
    }, 1],
    ['outcome', {
      battle: 'b1', outcome: 'win', winners: ['nw1a'], losers: [ID_A], reason: 'run', payDay: 350,
    }, 2],
    ['outcome', {
      battle: 'b1', outcome: 'win', winners: ['nw1a'], losers: [ID_A], reason: 'run', payDay: 350,
    }, 3],
    ['outcome', {
      battle: 'b1', outcome: 'win', winners: [ID_A], losers: ['nw1a'], reason: 'run', payDay: 350,
    }],
  ];
}

const PAYDAY12_EDGES = [200, 0, 1, 65535, 65536, 999999, 1000000, -3, 1.5, '0x10', ' 7 ', '1e2',
  true, [3]];

function readGap(kind, input, gen) {
  if (kind === 'mon') return sanitize.cleanBattleMon(input);
  if (kind === 'party') return sanitize.cleanBattleParty(input, gen);
  if (kind === 'move') return sanitize.cleanBattleMove(input, gen);
  if (kind === 'ruleset') return sanitize.cleanBattleRuleset(input, gen);
  if (kind === 'event') return sanitize.cleanBattleEvent(input, gen);
  if (kind === 'moveset') return sanitize.cleanBattleMoveset(input, gen);
  if (kind === 'outcome') return sanitize.cleanBattleOutcome(input, gen);
  if (kind === 'choice') return sanitize.cleanBattleChoice(input, gen);
  if (kind === 'reconnect') return sanitize.cleanBattleReconnect(input);
  if (kind === 'id') return sanitize.cleanId(input);
  if (kind === 'mapId') return sanitize.cleanMapId(input);
  return undefined;
}

/*
 * A mid-fight level-up reaches the referee (contract K9), and a learn keeps
 * highCrit / PP Ups / Gold priority (K8): twin of levelFight / levelFight3 in
 * the Lua driver, whose header argues each step. The sim's levelUp is a stub
 * recording each call; the hub's own rows are set first so the digest never
 * leans on how either sim's copyMove spells a field it was not given.
 */
function slimMoves12(moves) {
  return (moves || []).map((m) => ({
    id: m.id,
    pp: orNil(m.pp),
    power: orNil(m.power),
    highCrit: orNil(m.highCrit),
    ppUps: orNil(m.ppUps),
    priority: orNil(m.priority),
  }));
}

function levelFight(generation) {
  const relay = makeGenRelay(makeClock(), generation);
  const sprite = generation === 2 ? DEFAULT_SPRITE_GEN2 : DEFAULT_SPRITE;
  const a = dialAs(relay, 'ANN', ID_A, { generation, sprite });
  const b = dialAs(relay, 'BOB', ID_B, { generation, sprite });
  const sess = openFight(relay, a, b);
  uploadReady(relay, a, b, sess.id, [sheet12(generation)], [sheet12(generation)]);
  const record = relay.battles.get(sess.id);
  if (!record || !record.sim) return { opened: false };
  const calls = [];
  record.sim.levelUp = (playerId, index, level, stats, maxHp) => {
    calls.push({
      playerId, index, level: orNil(level), stats: orNil(stats), maxHp: orNil(maxHp),
    });
  };
  const gold = generation === 2;
  const live = record.sim.byId.get(a.id).mons[0];
  live.moves = [
    row12('slash', {
      pp: 7, power: 70, highCrit: true, ppUps: 1, priority: gold ? 1 : undefined,
    }),
    row12('thump', { pp: 9, highCrit: false }),
  ];
  const steps = [];
  const send = (extra) => {
    relay.handle(a.id, {
      type: 'mmo.battle_moveset', battle: sess.id, mon: 0, ...extra,
    });
    steps.push({ calls: calls.length, moves: slimMoves12(live.moves) });
  };
  const four = [row12('slash'), row12('thump'), row12('swap'), row12('extra')];
  send({
    moves: [row12('slash', { pp: 99, power: 999 }), row12('thump')],
    level: 51,
    stats: gold ? GROWN2 : GROWN1,
    maxHp: 140,
  });
  send({
    moves: [row12('slash'), row12('thump'),
      row12('learnt', { ppUps: 2, priority: 3, highCrit: true })],
    level: 52,
  });
  send({ moves: [row12('slash'), row12('thump'), row12('swap', { ppUps: 0 })] });
  send({ moves: [row12('aaa'), row12('bbb'), row12('swap')], level: 53 });
  live.transformed = true;
  send({ moves: four, level: 54, maxHp: 150 });
  live.transformed = false;
  send({ moves: four, level: 0 });
  record.sim.levelUp = false;
  send({ moves: four, level: 55 });
  return { opened: true, calls, steps };
}

function levelFight3() {
  const relay = makeGenRelay(makeClock(), 3);
  const a = dialAs(relay, 'ANN', ID_A, {
    generation: 3, version: 'firered', sprite: 'OBJ_EVENT_GFX_RED_NORMAL', map: 'FR_PALLET_TOWN',
  });
  const b = dialAs(relay, 'BOB', ID_B, {
    generation: 3, version: 'emerald', sprite: 'OBJ_EVENT_GFX_MAY_NORMAL', map: 'EM_LITTLEROOT_TOWN',
  });
  const sess = openFight(relay, a, b);
  relay.handle(a.id, { type: 'mmo.battle_ruleset', battle: sess.id, typeTable: CHART3 });
  relay.handle(a.id, { type: 'mmo.battle_party', battle: sess.id, mons: [mon3()] });
  relay.handle(b.id, { type: 'mmo.battle_party', battle: sess.id, mons: [mon3()] });
  const record = relay.battles.get(sess.id);
  if (!record || !record.sim) return { opened: false };
  let calls = 0;
  record.sim.levelUp = () => { calls += 1; };
  relay.handle(a.id, {
    type: 'mmo.battle_moveset',
    battle: sess.id,
    mon: 0,
    moves: [move3(), move3({ id: 'NEW3', num: 44 })],
    level: 51,
    stats: GROWN2,
    maxHp: 140,
  });
  const ids = record.sim.byId.get(a.id).mons[0].moves.map((m) => m.id);
  return { opened: true, calls, moves: ids };
}

/*
 * Pay Day on a Gen 1 / Gen 2 outcome (contract K11): the hubs copy the
 * referee's outcome().payDay onto the broadcast in the NPC modes alone, and
 * only a positive count -- and on an escape (reason `run`) only a Red hub does
 * (pokered pays after a Teleport / Whirlwind / Roar / POKE DOLL escape; Gold
 * calls every escape a draw and Gen 3 pays only on a win -- paysDay). The
 * referee's outcome is a stub; a stub run names the side that fled the loser.
 * Twin of paidFight in the Lua driver.
 */
function paidFight(generation, mode, coins, reason) {
  const relay = makeGenRelay(makeClock(), generation);
  let a;
  let b;
  if (generation === 3) {
    a = dialAs(relay, 'ANN', ID_A, {
      generation: 3, version: 'firered', sprite: 'OBJ_EVENT_GFX_RED_NORMAL', map: 'FR_PALLET_TOWN',
    });
    b = dialAs(relay, 'BOB', ID_B, {
      generation: 3, version: 'emerald', sprite: 'OBJ_EVENT_GFX_MAY_NORMAL', map: 'EM_LITTLEROOT_TOWN',
    });
  } else {
    const sprite = generation === 2 ? DEFAULT_SPRITE_GEN2 : DEFAULT_SPRITE;
    a = dialAs(relay, 'ANN', ID_A, { generation, sprite });
    b = dialAs(relay, 'BOB', ID_B, { generation, sprite });
  }
  const sheet = (extra) => (generation === 3 ? mon3(extra) : sheet12(generation, extra));
  let id;
  const solo = mode === 'wild';
  if (mode === '1v1') {
    id = openFight(relay, a, b).id;
    uploadReady(relay, a, b, id, [sheet12(generation)], [sheet12(generation)]);
  } else {
    id = 'w1';
    relay.openCoopBattle(id, solo ? [a.id] : [a.id, b.id], { mode, hostId: a.id });
    if (generation === 3) {
      relay.handle(a.id, { type: 'mmo.battle_ruleset', battle: id, typeTable: CHART3 });
    } else {
      relay.handle(a.id, { type: 'mmo.battle_ruleset', battle: id, chart: CHART });
    }
    relay.handle(a.id, {
      type: 'mmo.battle_party', battle: id, side: 'a', mons: [sheet()],
    });
    if (!solo) {
      relay.handle(b.id, {
        type: 'mmo.battle_party', battle: id, side: 'a', mons: [sheet()],
      });
    }
    relay.handle(a.id, {
      type: 'mmo.battle_party', battle: id, side: 'b', mons: [sheet({ catchRate: 45 })],
    });
  }
  const record = relay.battles.get(id);
  if (!record || !record.sim) return { opened: false };
  a.peer.outbox = [];
  b.peer.outbox = [];
  let verdict = {
    outcome: 'win', winners: [a.id], losers: [b.id], reason: 'ko', payDay: coins,
  };
  if (reason === 'run') {
    const wild = record.npcIds && record.npcIds[0];
    verdict = {
      outcome: 'win',
      winners: [wild || b.id],
      losers: mode === '1v1' || solo ? [a.id] : [a.id, b.id],
      reason: 'run',
      payDay: coins,
    };
  }
  record.sim.outcome = () => verdict;
  relay.flushBattle(record);
  const outcome = take(a, 'mmo.battle_outcome');
  return {
    opened: true,
    outcome: slimPaid(outcome),
    read1: slimPaid(outcome && sanitize.cleanBattleOutcome(outcome, 1)),
    read2: slimPaid(outcome && sanitize.cleanBattleOutcome(outcome, 2)),
    read3: slimPaid(outcome && sanitize.cleanBattleOutcome(outcome, 3)),
    readNone: slimPaid(outcome && sanitize.cleanBattleOutcome(outcome)),
    battleGone: !relay.battles.has(id),
  };
}

/*
 * K13's twin on the roster: a map id past 64 characters leaves its player
 * unplaced on both hubs, in a hello's welcome / join and on a step. Twin of
 * map_id_bound in the Lua driver.
 */
function slimStep(msg) {
  if (!msg) return '(nil)';
  return {
    id: msg.id, map: msg.map || '(none)', x: orNil(msg.x), y: orNil(msg.y),
  };
}

function mapIdBound() {
  const relay = makeGenRelay(makeClock(), 1);
  const edge = 'M'.repeat(64);
  const long = 'M'.repeat(65);
  const a = dialAs(relay, 'ANN', ID_A, { map: long, sprite: DEFAULT_SPRITE });
  const aWelcome = take(a, 'mmo.welcome');
  const b = dialAs(relay, 'BOB', ID_B, { map: edge, sprite: DEFAULT_SPRITE });
  const bWelcome = take(b, 'mmo.welcome');
  const joinAtA = take(a, 'mmo.join');
  const steps = [];
  for (const map of [edge, long, 'ROUTE_1', 'M'.repeat(200), '../secret']) {
    relay.handle(a.id, {
      type: 'mmo.move', map, x: 3, y: 4, facing: 'up',
    });
    steps.push(slimStep(take(b, 'mmo.move')));
  }
  return {
    aWelcomed: aWelcome !== null,
    bWelcomed: bWelcome !== null,
    bSees: slimRoster(bWelcome && bWelcome.players),
    aSeesJoin: slimPresence(joinAtA && joinAtA.player),
    steps,
  };
}

/*
 * A learn on a transformed battler (Red and Gold, real referees): written into
 * the party list put aside at Transform (`preTransform.moves`) so the
 * switch-out gives it back; Red also overwrites the copied moves (pokered
 * LearnMove), Gold leaves them (pokecrystal LearnMove). Twin of
 * transformLearn in the Lua driver.
 */
function slimRows(moves) {
  return (moves || []).map((m) => ({ id: m.id, pp: orNil(m.pp) }));
}

function transformLearn(generation) {
  const relay = makeGenRelay(makeClock(), generation);
  const sprite = generation === 2 ? DEFAULT_SPRITE_GEN2 : DEFAULT_SPRITE;
  const a = dialAs(relay, 'ANN', ID_A, { generation, sprite });
  const id = 't1';
  relay.openCoopBattle(id, [a.id], { mode: 'wild', hostId: a.id });
  relay.handle(a.id, { type: 'mmo.battle_ruleset', battle: id, chart: CHART });
  const mv = (moveId, effect, power) => row12(moveId, { pp: 10, power: power || 0, effect: effect || 0 });
  relay.handle(a.id, {
    type: 'mmo.battle_party',
    battle: id,
    side: 'a',
    mons: [
      sheet12(generation, { species: 'COPYCAT', moves: [mv('TRANSFORM', 57), mv('TACKLE', 0, 1)] }),
      sheet12(generation, { species: 'BENCH', moves: [mv('TACKLE', 0, 1)] }),
    ],
  });
  relay.handle(a.id, {
    type: 'mmo.battle_party',
    battle: id,
    side: 'b',
    mons: [sheet12(generation, { species: 'FOE', moves: [mv('GROWL'), mv('HUSH')] })],
  });
  const record = relay.battles.get(id);
  if (!record || !record.sim) return { opened: false };
  relay.handle(a.id, {
    type: 'mmo.battle_choice', battle: id, action: 'fight', move: 0,
  });
  const live = record.sim.byId.get(a.id).mons[0];
  const look = () => {
    const saved = live.preTransform;
    return {
      transformed: live.transformed === true,
      battle: slimRows(live.moves),
      party: saved ? slimRows(saved.moves) : '(none)',
      separate: saved && saved.moves ? saved.moves[0] !== live.moves[0] : '(n/a)',
    };
  };
  const steps = [look()];
  relay.handle(a.id, {
    type: 'mmo.battle_moveset',
    battle: id,
    mon: 0,
    moves: [mv('TRANSFORM', 57), mv('TACKLE', 0, 1), mv('LEARNT', 0, 40)],
  });
  steps.push(look());
  relay.handle(a.id, {
    type: 'mmo.battle_moveset', battle: id, mon: 0, moves: [mv('AAA'), mv('BBB'), mv('CCC')],
  });
  steps.push(look());
  relay.handle(a.id, {
    type: 'mmo.battle_choice', battle: id, action: 'switch', slot: 1,
  });
  steps.push(look());
  return { opened: true, steps };
}

function runGaps() {
  return [
    {
      name: 'referee_gaps_dialect',
      result: (() => {
        const cases = gaps().map(([kind, input, gen]) => ({ kind, got: orNil(readGap(kind, input, gen)) }));
        const payEdges12 = PAYDAY12_EDGES.map((v) => {
          const row = {};
          for (const reader of [1, 2, 3, 'none']) {
            const got = sanitize.cleanBattleOutcome({ battle: 'b1', outcome: 'win', payDay: v },
              reader !== 'none' ? reader : undefined);
            row[`r${reader}`] = orNil(got && got.payDay);
          }
          return row;
        });
        return { cases, payEdges12 };
      })(),
    },
    {
      name: 'levelup_moveset_forward',
      result: { red: levelFight(1), gold: levelFight(2), gen3: levelFight3() },
    },
    {
      name: 'gen12_payday_forward',
      result: {
        redWild: paidFight(1, 'coop_wild', 350),
        goldWild: paidFight(2, 'wild', 99999),
        goldNone: paidFight(2, 'coop_wild', 0),
        red1v1: paidFight(1, '1v1', 350),
        redWildRun: paidFight(1, 'wild', 350, 'run'),
        redCoopRun: paidFight(1, 'coop_wild', 350, 'run'),
        redRunNone: paidFight(1, 'wild', 0, 'run'),
        red1v1Run: paidFight(1, '1v1', 350, 'run'),
        goldWildRun: paidFight(2, 'wild', 350, 'run'),
        goldCoopRun: paidFight(2, 'coop_wild', 350, 'run'),
        gen3WildRun: paidFight(3, 'wild', 350, 'run'),
        gen3WildKo: paidFight(3, 'wild', 350),
      },
    },
    { name: 'map_id_bound', result: mapIdBound() },
    { name: 'transformed_learn', result: { red: transformLearn(1), gold: transformLearn(2) } },
  ];
}

/*
 * Wave 4 of docs/plans/gen12-referee-gaps-fix.md, the wire: Red's MIMIC pick on
 * a Gen 1 choice (`mimic`) and Gold's wTimeOfDay on a Gen 2 ruleset
 * (`timeOfDay`). Twin of wave4 in the Lua driver.
 */
function wave4() {
  const fight = (extra) => ({ battle: 'b1', action: 'fight', move: 0, ...extra });
  const rules = (extra) => ({ chart: CHART, ...extra });
  return [
    ['choice', fight({ mimic: 0 }), 1],
    ['choice', fight({ mimic: 3 }), 1],
    ['choice', fight({ mimic: 4 }), 1],
    ['choice', fight({ mimic: -1 }), 1],
    ['choice', fight({ mimic: '2' }), 1],
    ['choice', fight({ mimic: ' 1 ' }), 1],
    ['choice', fight({ mimic: '0x1' }), 1],
    ['choice', fight({ mimic: 1.5 }), 1],
    ['choice', fight({ mimic: true }), 1],
    ['choice', fight({ mimic: 'one' }), 1],
    ['choice', fight({ mimic: [1] }), 1],
    ['choice', fight({ mimic: null }), 1],
    ['choice', {
      battle: 'b1', action: 'switch', slot: 1, mimic: 2,
    }, 1],
    ['choice', { battle: 'b1', action: 'run', mimic: 7 }, 1],
    ['choice', fight({ mimic: 2 }), 2],
    ['choice', fight({ mimic: 9 }), 2],
    ['choice', fight({ mimic: 2 }), 3],
    ['choice', fight({ mimic: 9 }), 3],
    ['choice', fight({ mimic: 2 })],
    ['choice', fight({ mimic: 9 })],
    ['ruleset', rules({ timeOfDay: 'morn' }), 2],
    ['ruleset', rules({ timeOfDay: 'day' }), 2],
    ['ruleset', rules({ timeOfDay: 'nite' }), 2],
    ['ruleset', rules({ timeOfDay: 'NITE' }), 2],
    ['ruleset', rules({ timeOfDay: 'night' }), 2],
    ['ruleset', rules({ timeOfDay: 'eve' }), 2],
    ['ruleset', rules({ timeOfDay: 'darkness' }), 2],
    ['ruleset', rules({ timeOfDay: '' }), 2],
    ['ruleset', rules({ timeOfDay: 2 }), 2],
    ['ruleset', rules({ timeOfDay: true }), 2],
    ['ruleset', rules({ timeOfDay: ['nite'] }), 2],
    ['ruleset', rules({ timeOfDay: null }), 2],
    ['ruleset', rules({ timeOfDay: 'day', metronomePool: [row12('m', { priority: 1 })] }), 2],
    ['ruleset', rules({ timeOfDay: 'nite' }), 1],
    ['ruleset', rules({ timeOfDay: 'evening' }), 1],
    ['ruleset', rules({ timeOfDay: 'nite' })],
    ['ruleset', rules({ timeOfDay: 'evening' })],
    ['ruleset', { typeTable: CHART3, timeOfDay: 'nite' }, 3],
    ['ruleset', { typeTable: CHART3, timeOfDay: 'evening' }, 3],
  ];
}

/*
 * Wave 4, the hubs and the real referees: a learn is judged against the PARTY
 * list and reaches the battle list only as the cart's LearnMove does
 * (learnTo); Red's MIMIC pick reaches the referee off the wire; Gold's
 * wTimeOfDay reaches its referee off a Gen 2 ruleset. Twin of
 * overlay_learn_and_time in the Lua driver, whose header argues each step.
 */
function overlayHub(generation, id, aMoves) {
  const relay = makeGenRelay(makeClock(), generation);
  const sprite = generation === 2 ? DEFAULT_SPRITE_GEN2 : DEFAULT_SPRITE;
  const a = dialAs(relay, 'ANN', ID_A, { generation, sprite });
  relay.openCoopBattle(id, [a.id], { mode: 'wild', hostId: a.id });
  relay.handle(a.id, { type: 'mmo.battle_ruleset', battle: id, chart: CHART });
  relay.handle(a.id, {
    type: 'mmo.battle_party',
    battle: id,
    side: 'a',
    mons: [
      sheet12(generation, { species: 'COPYCAT', moves: aMoves }),
      sheet12(generation, { species: 'BENCH', moves: [row12('TACKLE', { pp: 10, power: 1 })] }),
    ],
  });
  relay.handle(a.id, {
    type: 'mmo.battle_party',
    battle: id,
    side: 'b',
    mons: [sheet12(generation, {
      species: 'FOE',
      moves: [row12('GROWL', { pp: 10, power: 0 }), row12('HUSH', { pp: 10, power: 0 })],
    })],
  });
  return { relay, a, record: relay.battles.get(id) };
}

function ovMove(moveId, effect, power) {
  return row12(moveId, { pp: 10, power: power || 0, effect: effect || 0 });
}

function lookOverlay(live) {
  const saved = live.preTransform;
  const mimic = live.preMimic;
  const kept = [];
  if (mimic && typeof mimic === 'object') {
    for (let i = 1; i <= 4; i += 1) {
      if (mimic[i]) kept.push(`${i}:${mimic[i].id}`);
    }
  }
  return {
    transformed: live.transformed === true,
    battle: slimRows(live.moves),
    party: saved ? slimRows(saved.moves) : '(none)',
    mimic: kept,
  };
}

function mimicLearn(generation, pick) {
  const id = 'm1';
  const { relay, a, record } = overlayHub(generation, id,
    [ovMove('MIMIC', 82), ovMove('TACKLE', 0, 1)]);
  if (!record || !record.sim) return { opened: false };
  const choice = {
    type: 'mmo.battle_choice', battle: id, action: 'fight', move: 0,
  };
  if (pick !== undefined) choice.mimic = pick;
  relay.handle(a.id, choice);
  const live = record.sim.byId.get(a.id).mons[0];
  const steps = [lookOverlay(live)];
  const send = (moves) => {
    relay.handle(a.id, {
      type: 'mmo.battle_moveset', battle: id, mon: 0, moves,
    });
    steps.push(lookOverlay(live));
  };
  send([ovMove('MIMIC', 82), ovMove('TACKLE', 0, 1)]);
  send([ovMove(live.moves[0].id), ovMove('TACKLE', 0, 1), ovMove('LEARNT', 0, 40)]);
  send([ovMove('MIMIC', 82), ovMove('TACKLE', 0, 1), ovMove('LEARNT', 0, 40)]);
  relay.handle(a.id, {
    type: 'mmo.battle_choice', battle: id, action: 'switch', slot: 1,
  });
  steps.push(lookOverlay(live));
  return { opened: true, steps };
}

function transformResend(generation, mimicFirst) {
  const id = 't2';
  const moves = mimicFirst
    ? [ovMove('MIMIC', 82), ovMove('TRANSFORM', 57), ovMove('TACKLE', 0, 1)]
    : [ovMove('TRANSFORM', 57), ovMove('TACKLE', 0, 1)];
  const { relay, a, record } = overlayHub(generation, id, moves);
  if (!record || !record.sim) return { opened: false };
  if (mimicFirst) {
    relay.handle(a.id, {
      type: 'mmo.battle_choice', battle: id, action: 'fight', move: 0, mimic: 1,
    });
  }
  relay.handle(a.id, {
    type: 'mmo.battle_choice', battle: id, action: 'fight', move: mimicFirst ? 1 : 0,
  });
  const live = record.sim.byId.get(a.id).mons[0];
  const steps = [lookOverlay(live)];
  const own = [...moves];
  relay.handle(a.id, {
    type: 'mmo.battle_moveset', battle: id, mon: 0, moves: own,
  });
  steps.push(lookOverlay(live));
  own.push(ovMove('LEARNT', 0, 40));
  relay.handle(a.id, {
    type: 'mmo.battle_moveset', battle: id, mon: 0, moves: own,
  });
  steps.push(lookOverlay(live));
  relay.handle(a.id, {
    type: 'mmo.battle_choice', battle: id, action: 'switch', slot: 1,
  });
  steps.push(lookOverlay(live));
  return { opened: true, steps };
}

function synthLearn(generation, transformed) {
  const { learnTo } = require('./lib/relay.js');
  const mon = transformed
    ? {
      transformed: true,
      moves: [ovMove('COPY')],
      preTransform: { moves: [row12('HUSH', { pp: 4 }), ovMove('TACKLE', 0, 1)] },
    }
    : { moves: [row12('HUSH', { pp: 4 }), ovMove('TACKLE', 0, 1)] };
  mon.preMimic = { 1: ovMove('MIMIC', 82) };
  mon.preMimic[1].pp = 9;
  const steps = [];
  const tryLearn = (moves) => {
    steps.push({ applied: learnTo(generation, mon, moves), state: lookOverlay(mon) });
  };
  tryLearn([ovMove('MIMIC', 82), ovMove('TACKLE', 0, 1)]);
  tryLearn([ovMove('NEW'), ovMove('BBB')]);
  tryLearn([ovMove('MIMIC', 82), ovMove('TACKLE', 0, 1), ovMove('LEARNT', 0, 40)]);
  return steps;
}

function timeHeal(generation, timeOfDay) {
  const relay = makeGenRelay(makeClock(), generation);
  const sprite = generation === 2 ? DEFAULT_SPRITE_GEN2 : DEFAULT_SPRITE;
  const a = dialAs(relay, 'ANN', ID_A, { generation, sprite });
  const id = 'h1';
  relay.openCoopBattle(id, [a.id], { mode: 'wild', hostId: a.id });
  relay.handle(a.id, {
    type: 'mmo.battle_ruleset', battle: id, chart: CHART, timeOfDay,
  });
  const record = relay.battles.get(id);
  const kept = record && record.ruleset ? orNil(record.ruleset.timeOfDay) : '(no ruleset)';
  relay.handle(a.id, {
    type: 'mmo.battle_party',
    battle: id,
    side: 'a',
    mons: [sheet12(generation, { species: 'MOTH', hp: 40, moves: [ovMove('MOONLIGHT', 130)] })],
  });
  relay.handle(a.id, {
    type: 'mmo.battle_party',
    battle: id,
    side: 'b',
    mons: [sheet12(generation, { species: 'FOE', moves: [ovMove('HUSH')] })],
  });
  if (!record || !record.sim) return { opened: false, kept };
  relay.handle(a.id, {
    type: 'mmo.battle_choice', battle: id, action: 'fight', move: 0,
  });
  return {
    opened: true,
    kept,
    simTime: orNil(record.sim.timeOfDay),
    hp: record.sim.byId.get(a.id).mons[0].hp,
  };
}

function runWave4() {
  return [
    {
      name: 'referee_gaps_wave4_dialect',
      result: wave4().map(([kind, input, gen]) => ({ kind, got: orNil(readGap(kind, input, gen)) })),
    },
    {
      name: 'overlay_learn_and_time',
      result: {
        redMimicPick: mimicLearn(1, 1),
        redMimicNone: mimicLearn(1, undefined),
        goldMimic: mimicLearn(2, 1),
        redTransform: transformResend(1, false),
        goldTransform: transformResend(2, false),
        redMimicTransform: transformResend(1, true),
        redSynth: synthLearn(1, false),
        goldSynth: synthLearn(2, false),
        redSynthT: synthLearn(1, true),
        goldSynthT: synthLearn(2, true),
        goldNite: timeHeal(2, 'nite'),
        goldDay: timeHeal(2, 'day'),
        goldMorn: timeHeal(2, 'morn'),
        goldNone: timeHeal(2, undefined),
        goldBad: timeHeal(2, 'evening'),
        redNite: timeHeal(1, 'nite'),
        redBad: timeHeal(1, 'evening'),
      },
    },
  ];
}

// ------------------------------------------------------------------
// Wave 5 of docs/plans/gen12-referee-gaps-fix.md, the wire: Red's `chartOrder`
// on a Gen 1 ruleset, Gold's K15 `base.gender`, Gold's BATON PASS `pass` on a
// Gen 2 choice, a Gold Metronome pool row's `num`. Twin of
// referee_gaps_wave5_dialect in the Lua driver, whose header argues each case;
// the Lua driver's NULL is a real null here, and `orderLen` reports a long
// list by its length.
// ------------------------------------------------------------------

function wave5() {
  const rules = (extra) => ({ chart: CHART, ...extra });
  const fight = (extra) => ({
    battle: 'b1', action: 'fight', move: 0, ...extra,
  });
  const B2 = {
    hp: 41, atk: 52, def: 63, spe: 74, spa: 85, spd: 96,
  };
  const B1 = {
    hp: 41, atk: 52, def: 63, spd: 74, spc: 85,
  };
  const gold = (gender) => sheet12(2, { base: { ...B2, gender } });
  const pooled = (extra) => rules({ metronomePool: [row12('m', extra)] });
  const long = [];
  for (let i = 1; i <= 514; i += 1) long.push(i % 20);
  const first = (n) => long.slice(0, n);
  return [
    // chartOrder
    ['ruleset', rules({ chartOrder: [0, 1, 1, 0] }), 1],
    ['ruleset', rules({ chartOrder: [19, 19] }), 1],
    ['ruleset', rules({ chartOrder: [1, 0, 1, 0] }), 1],
    ['ruleset', rules({ chartOrder: [20, 0] }), 1],
    ['ruleset', rules({ chartOrder: [-1, 0] }), 1],
    ['ruleset', rules({ chartOrder: [0, 1, 1] }), 1],
    ['ruleset', rules({ chartOrder: [] }), 1],
    ['ruleset', rules({ chartOrder: [0, null, 1] }), 1],
    ['ruleset', rules({ chartOrder: [0, null, 1, 1] }), 1],
    ['ruleset', rules({ chartOrder: [null, null] }), 1],
    ['ruleset', rules({ chartOrder: ['1', 0] }), 1],
    ['ruleset', rules({ chartOrder: [' 1 ', 0] }), 1],
    ['ruleset', rules({ chartOrder: ['0x1', 0] }), 1],
    ['ruleset', rules({ chartOrder: [1.5, 0] }), 1],
    ['ruleset', rules({ chartOrder: [true, 0] }), 1],
    ['ruleset', rules({ chartOrder: ['one', 0] }), 1],
    ['ruleset', rules({ chartOrder: [[1], 0] }), 1],
    ['ruleset', rules({ chartOrder: { a: 1 } }), 1],
    ['ruleset', rules({ chartOrder: '0,1' }), 1],
    ['ruleset', rules({ chartOrder: 7 }), 1],
    ['ruleset', rules({ chartOrder: null }), 1],
    ['ruleset', rules({
      chartOrder: [0, 1], metronomePool: [row12('m', { num: 7 })], typeIds: ['NORMAL', 'FIGHTING'],
    }), 1],
    ['ruleset', rules({ chartOrder: [0, 1] }), 2],
    ['ruleset', rules({ chartOrder: [0, 1, 1] }), 2],
    ['ruleset', rules({ chartOrder: [0, 1] })],
    ['ruleset', rules({ chartOrder: 'bad' })],
    ['ruleset', { typeTable: CHART3, chartOrder: [0, 1] }, 3],
    ['ruleset', { typeTable: CHART3, chartOrder: 'bad' }, 3],
    ['orderLen', rules({ chartOrder: first(512) }), 1],
    ['orderLen', rules({ chartOrder: first(513) }), 1],
    ['orderLen', rules({ chartOrder: first(514) }), 1],
    ['orderLen', rules({ chartOrder: first(164) }), 1],
    // K15 base.gender
    ['mon', gold(0)],
    ['mon', gold(127)],
    ['mon', gold(254)],
    ['mon', gold(255)],
    ['mon', gold(256)],
    ['mon', gold(-1)],
    ['mon', gold('31')],
    ['mon', gold(' 9 ')],
    ['mon', gold('0x1f')],
    ['mon', gold(31.9)],
    ['mon', gold(true)],
    ['mon', gold('male')],
    ['mon', gold([31])],
    ['mon', gold(null)],
    ['mon', sheet12(2, { ...k7(2), base: { ...B2, gender: 31 }, generation: 2 })],
    ['mon', sheet12(2, { base: { gender: 31 } })],
    ['mon', sheet12(1, { base: { ...B1, gender: 254 } })],
    ['mon', sheet12(1, { base: { ...B1, gender: 'male' } })],
    ['mon', { ...mon3(), base: { ...B2, gender: 31 } }],
    ['party', { battle: 'b1', mons: [gold(31)] }, 2],
    ['party', { battle: 'b1', mons: [gold(300)] }, 2],
    ['outcome', {
      battle: 'b1', outcome: 'win', reason: 'catch', caught: gold(31),
    }, 2],
    // Gold's BATON PASS successor
    ['choice', fight({ pass: 0 }), 2],
    ['choice', fight({ pass: 5 }), 2],
    ['choice', fight({ pass: 6 }), 2],
    ['choice', fight({ pass: -1 }), 2],
    ['choice', fight({ pass: '2' }), 2],
    ['choice', fight({ pass: ' 1 ' }), 2],
    ['choice', fight({ pass: 1.5 }), 2],
    ['choice', fight({ pass: true }), 2],
    ['choice', fight({ pass: 'two' }), 2],
    ['choice', fight({ pass: [1] }), 2],
    ['choice', fight({ pass: null }), 2],
    ['choice', fight({ pass: 2, dexCaught: true }), 2],
    ['choice', {
      battle: 'b1', action: 'switch', slot: 1, pass: 2,
    }, 2],
    ['choice', fight({ pass: 2 }), 1],
    ['choice', fight({ pass: 9 }), 1],
    ['choice', fight({ pass: 2, mimic: 1 }), 1],
    ['choice', fight({ pass: 2 }), 3],
    ['choice', fight({ pass: 9 }), 3],
    ['choice', fight({ pass: 2 })],
    ['choice', fight({ pass: 9 })],
    // Gold Metronome pool `num`
    ['ruleset', pooled({ num: 1 }), 2],
    ['ruleset', pooled({ num: 251 }), 2],
    ['ruleset', pooled({ num: 252 }), 2],
    ['ruleset', pooled({ num: 0 }), 2],
    ['ruleset', pooled({ num: -1 }), 2],
    ['ruleset', pooled({ num: '7' }), 2],
    ['ruleset', pooled({ num: 7.5 }), 2],
    ['ruleset', pooled({ num: true }), 2],
    ['ruleset', pooled({ num: 'x' }), 2],
    ['ruleset', pooled({ num: [7] }), 2],
    ['ruleset', pooled({ num: null }), 2],
    ['ruleset', pooled({ num: 7, priority: 2, ppUps: 1 }), 2],
    ['ruleset', rules({ metronomePool: [row12('a', { num: 3 }), row12('b')] }), 2],
    ['ruleset', pooled({ num: 7 }), 1],
    ['ruleset', pooled({ num: 999 }), 1],
    ['ruleset', pooled({ num: 7 })],
    ['ruleset', pooled({ num: 999 })],
    // the Gen 1 / Gen 2 pool read as a list on both twins
    ['ruleset', rules({ metronomePool: [row12('a', { num: 3 }), null, row12('b')] }), 2],
    ['ruleset', rules({ metronomePool: [null] }), 1],
    ['ruleset', rules({ metronomePool: [] }), 1],
    ['ruleset', rules({ metronomePool: { a: row12('a') } }), 2],
    ['ruleset', rules({ metronomePool: 'rows' }), 1],
  ];
}

function readWave5(kind, input, gen) {
  if (kind === 'orderLen') {
    const read = sanitize.cleanBattleRuleset(input, gen);
    if (!read) return '(refused)';
    return read.chartOrder ? read.chartOrder.length : '(no order)';
  }
  return readGap(kind, input, gen);
}

/*
 * Wave 5, the hubs and the real referees: Red's chartOrder decides "doesn't
 * affect" vs "missed" (a Gen 2 hub keeps none), Gold's `pass` picks BATON
 * PASS's successor, K15's gender decides ATTRACT, and a pool row's `num`
 * decides what METRONOME calls. Twin of wave5_hub_fields in the Lua driver,
 * whose header argues each step.
 */
function wave5Hub(generation, id, rules, aMons, bMons) {
  const relay = makeGenRelay(makeClock(), generation);
  const sprite = generation === 2 ? DEFAULT_SPRITE_GEN2 : DEFAULT_SPRITE;
  const a = dialAs(relay, 'ANN', ID_A, { generation, sprite });
  relay.openCoopBattle(id, [a.id], { mode: 'wild', hostId: a.id });
  relay.handle(a.id, { type: 'mmo.battle_ruleset', battle: id, ...rules });
  relay.handle(a.id, {
    type: 'mmo.battle_party', battle: id, side: 'a', mons: aMons,
  });
  relay.handle(a.id, {
    type: 'mmo.battle_party', battle: id, side: 'b', mons: bMons,
  });
  a.peer.outbox.length = 0;
  return { relay, a, record: relay.battles.get(id) };
}

// The lines of `user`'s own move, from its "<USER> used" line up to the next
// "used" line (the Lua driver's msgTexts).
function msgTexts(player, user) {
  const out = [];
  let on = false;
  for (const msg of takeAll(player, 'mmo.battle_event')) {
    if (msg.t === 'msg') {
      if (msg.text.includes(' used ')) on = msg.text.startsWith(`${user} `);
      if (on) out.push(msg.text);
    }
  }
  return out;
}

const IMMUNE_CHART = [[0, 200], [100, 100]];

function foeHp(sim) {
  for (const fighter of sim.fighters) {
    if (fighter.side === 'b') {
      const live = fighter.active ? fighter.mons[fighter.active - 1] : null;
      return orNil(live && live.hp);
    }
  }
  return '(no foe)';
}

function redOrder(generation, order) {
  const id = 'co';
  const { relay, a, record } = wave5Hub(generation, id, { chart: IMMUNE_CHART, chartOrder: order }, [
    sheet12(generation, { species: 'TAPPER', moves: [row12('TAP', { pp: 10, power: 40 })] }),
  ], [
    sheet12(generation, { species: 'DUO', types: [0, 1], moves: [row12('HUSH', { pp: 10, power: 0 })] }),
  ]);
  const kept = record && record.ruleset ? orNil(record.ruleset.chartOrder) : '(no ruleset)';
  if (!record || !record.sim) return { opened: false, kept };
  const rows = record.sim.chartRows ? record.sim.chartRows.length : 0;
  relay.handle(a.id, {
    type: 'mmo.battle_choice', battle: id, action: 'fight', move: 0,
  });
  return {
    opened: true, kept, rows, texts: msgTexts(a, 'TAPPER'), foeHp: foeHp(record.sim),
  };
}

function goldPass(pass) {
  const id = 'bp';
  const sheet = (species, moves) => sheet12(2, { species, moves });
  const { relay, a, record } = wave5Hub(2, id, { chart: CHART }, [
    sheet('PASSER', [row12('BATON_PASS', { pp: 10, power: 0, effect: 134 })]),
    sheet('BENCH1', [row12('TAP', { pp: 10, power: 1 })]),
    sheet('BENCH2', [row12('TAP', { pp: 10, power: 1 })]),
  ], [sheet('FOE', [row12('HUSH', { pp: 10, power: 0 })])]);
  if (!record || !record.sim) return { opened: false };
  relay.handle(a.id, {
    type: 'mmo.battle_choice', battle: id, action: 'fight', move: 0, pass,
  });
  const fighter = record.sim.byId.get(a.id);
  return {
    opened: true,
    turn: record.sim.turn,
    active: fighter.mons[fighter.active - 1].species,
    texts: msgTexts(a, 'PASSER'),
  };
}

function goldAttract(mine, theirs) {
  const id = 'at';
  const sheet = (species, gender, moves) => {
    const extra = k7(2);
    if (gender !== undefined) extra.base = { ...extra.base, gender };
    return sheet12(2, { ...extra, species, moves });
  };
  const { relay, a, record } = wave5Hub(2, id, { chart: CHART }, [
    sheet('CHARMER', mine, [row12('ATTRACT', { pp: 15, power: 0, effect: 133 })]),
  ], [sheet('FOE', theirs, [row12('HUSH', { pp: 10, power: 0 })])]);
  if (!record || !record.sim) return { opened: false };
  const live = record.sim.byId.get(a.id).mons[0];
  const held = live.base ? orNil(live.base.gender) : '(no base)';
  relay.handle(a.id, {
    type: 'mmo.battle_choice', battle: id, action: 'fight', move: 0,
  });
  return { opened: true, gender: held, texts: msgTexts(a, 'CHARMER') };
}

function goldMetronome(numbered) {
  const id = 'mt';
  const poolRow = (moveId, num) => row12(moveId, { pp: 10, power: 0, num: numbered ? num : undefined });
  const { relay, a, record } = wave5Hub(2, id, {
    chart: CHART,
    metronomePool: [poolRow('CALLED_A', 200), poolRow('CALLED_B', 7)],
  }, [
    sheet12(2, { species: 'WAGGLER', moves: [row12('METRONOME', { pp: 10, power: 0, effect: 83 })] }),
  ], [
    sheet12(2, { species: 'FOE', moves: [row12('HUSH', { pp: 10, power: 0 })] }),
  ]);
  if (!record || !record.sim) return { opened: false };
  const nums = (record.ruleset.metronomePool || []).map((entry) => orNil(entry.num));
  relay.handle(a.id, {
    type: 'mmo.battle_choice', battle: id, action: 'fight', move: 0,
  });
  return { opened: true, nums, texts: msgTexts(a, 'WAGGLER') };
}

function runWave5() {
  return [
    {
      name: 'referee_gaps_wave5_dialect',
      result: wave5().map(([kind, input, gen]) => ({ kind, got: orNil(readWave5(kind, input, gen)) })),
    },
    {
      name: 'wave5_hub_fields',
      result: {
        redImmuneLast: redOrder(1, [0, 1, 0, 0]),
        redSuperLast: redOrder(1, [0, 0, 0, 1]),
        redNoOrder: redOrder(1, undefined),
        redBadOrder: redOrder(1, [0, 0, 0]),
        goldOrderIgnored: redOrder(2, [0, 0, 0, 1]),
        goldPassBench2: goldPass(2),
        goldPassNone: goldPass(undefined),
        goldPassNobody: goldPass(4),
        goldPassPastMax: goldPass(6),
        goldAttractMF: goldAttract(0, 254),
        goldAttractMM: goldAttract(0, 0),
        goldAttractNone: goldAttract(undefined, undefined),
        goldMetronomeNum: goldMetronome(true),
        goldMetronomePlace: goldMetronome(false),
      },
    },
  ];
}

// ------------------------------------------------------------------
// Wave 6 of docs/plans/gen12-referee-gaps-fix.md, the wire: a Red / Gold
// reader's `msg` with the carts' battle glyphs (cleanBattleText), `ppUps` on
// an older `moves` event's rows, chart / specialTypes nulls closed up, and an
// NPC party's Red `aiMods` and Red / Gold `name`. Twin of
// referee_gaps_wave6_dialect in the Lua driver, whose header argues each case.
// The Lua driver's strings are the bytes a hub is handed; each one here is what
// Node's UTF-8 decoding makes of those bytes (`dec` for the ones that are not
// valid UTF-8, where a stray sequence becomes U+FFFD), so each row pins one
// byte stream through both readers. NULL there is a real null here.
// ------------------------------------------------------------------

const dec = (hex) => Buffer.from(hex, 'hex').toString('utf8');

function wave6() {
  const line = (text, t) => ({
    battle: 'b1', seq: 1, t: t || 'msg', text,
  });
  const rules = (extra) => ({ chart: CHART, ...extra });
  const party = (extra, gen) => ({ battle: 'b1', mons: [sheet12(gen || 1)], ...extra });
  const movesEvent = (rows) => ({
    battle: 'b1', seq: 2, t: 'moves', slot: 0, side: 'a', mon: 0, moves: rows,
  });
  const texts = [
    'Both POKéMON will faint in 3 turns!',
    'Enemy POKéMON\'s LIGHT SCREEN fell!',
    'ALPHA ignored orders…sleeping!',
    'COOLTRAINER♂ used X ATTACK on JR.TRAINER♀!',
    'TWINS AMY & MAY used an item',
    '  POKé  …\té  ',
    dec('e2c3a958'),
    dec('e280c3a9'),
    dec('c345a9'),
    `${dec('f09f9880')} HI`,
    'POKÉMON',
    'POKèMON',
    'é'.repeat(70),
    `${'A'.repeat(59)}éB`,
    '#MON <PKMN> @ \\ _ ~ ¥',
  ];
  const cases = [];
  for (const gen of [1, 2, 3, undefined]) {
    for (const text of texts) cases.push(['event', line(text), gen]);
  }
  return [
    ...cases,
    // other kinds keep cleanText
    ['event', line('COOLTRAINER♂', 'chose'), 1],
    ['event', line('POKéMON', 'send'), 2],
    ['event', line('Wild POKéMON fled!', 'run'), 2],
    // ppUps on the older `moves` event
    ['event', movesEvent([row12('TAP', { pp: 0, maxPp: 35, ppUps: 3 }),
      row12('HUSH', { ppUps: 4 }), row12('ZAP', { ppUps: '2' }),
      row12('NAP', { ppUps: null })]), 1],
    ['event', movesEvent([row12('TAP', {
      pp: 0, maxPp: 35, ppUps: 3, priority: 2,
    }), row12('HUSH', { ppUps: -1 })]), 2],
    // chart nulls (rows and cells)
    ['ruleset', { chart: [[100, null, 50], [0, 200]] }, 1],
    ['ruleset', { chart: [null, [100, 50], [0, 200]] }, 2],
    ['ruleset', { chart: [[100, 50], null] }],
    ['ruleset', { chart: [[null, null]] }, 1],
    ['ruleset', { chart: [null] }, 1],
    ['ruleset', { chart: [[100, 50], { a: 1 }] }, 1],
    ['ruleset', { chart: { a: [100] } }, 2],
    ['ruleset', { chart: [[true, 100]] }, 1],
    ['ruleset', { chart: [['100', ' 50 ']] }, 2],
    ['ruleset', { chart: [['', 50]] }, 1],
    ['ruleset', { chart: [[[100], 50]] }, 1],
    ['ruleset', { chart: [['0x10', 50]] }, 1],
    // specialTypes nulls
    ['ruleset', rules({ specialTypes: [1, null, 0] }), 1],
    ['ruleset', rules({ specialTypes: [null] }), 2],
    ['ruleset', rules({ specialTypes: [] }), 1],
    ['ruleset', rules({ specialTypes: {} }), 2],
    ['ruleset', rules({ specialTypes: { a: 1 } }), 1],
    ['ruleset', rules({ specialTypes: { a: null } }), 2],
    ['ruleset', rules({ specialTypes: [true] }), 1],
    ['ruleset', rules({ specialTypes: [[1]] }), 2],
    ['ruleset', rules({ specialTypes: [''] }), 1],
    ['ruleset', rules({ specialTypes: ['1', ' 0 '] }), 2],
    ['ruleset', rules({ specialTypes: '1' }), 1],
    ['ruleset', rules({ specialTypes: [1, null, 0] })],
    // Red aiMods
    ['npc', party({ aiMods: [1, 2, 3] }), 1],
    ['npc', party({ aiMods: [] }), 1],
    ['npc', party({ aiMods: [1, null, 3] }), 1],
    ['npc', party({ aiMods: [null] }), 1],
    ['npc', party({ aiMods: [4, 4] }), 1],
    ['npc', party({ aiMods: [0] }), 1],
    ['npc', party({ aiMods: [5] }), 1],
    ['npc', party({ aiMods: [-1] }), 1],
    ['npc', party({ aiMods: ['2', ' 3 '] }), 1],
    ['npc', party({ aiMods: ['0x2'] }), 1],
    ['npc', party({ aiMods: [1.5] }), 1],
    ['npc', party({ aiMods: [true] }), 1],
    ['npc', party({ aiMods: [[1]] }), 1],
    ['npc', party({ aiMods: [''] }), 1],
    ['npc', party({ aiMods: [1, 2, 3, 4, 1, 2, 3, 4] }), 1],
    ['npc', party({ aiMods: [1, 2, 3, 4, 1, 2, 3, 4, 1] }), 1],
    ['npc', party({ aiMods: [1, 2, 3, 4, null, 1, 2, 3, 4] }), 1],
    ['npc', party({ aiMods: { a: 1 } }), 1],
    ['npc', party({ aiMods: { a: null } }), 1],
    ['npc', party({ aiMods: '1,2' }), 1],
    ['npc', party({ aiMods: 3 }), 1],
    ['npc', party({ aiMods: null }), 1],
    ['npc', party({ aiMods: [1, 2], generation: 1 })],
    ['npc', party({ aiMods: [9], generation: 1 })],
    ['npc', party({ aiMods: [1, 2] })],
    ['npc', party({ aiMods: [9] })],
    ['npc', party({ aiMods: [1, 2] }, 2), 2],
    ['npc', party({ aiMods: [9] }, 2), 2],
    ['npc', { battle: 'b1', mons: [mon3()], aiMods: [1] }, 3],
    ['npc', { battle: 'b1', mons: [mon3()], aiMods: [9] }, 3],
    // the NPC seat's display name
    ['npc', party({ name: 'COOLTRAINER♂' }), 1],
    ['npc', party({ name: 'POKéMANIAC', aiMods: [1] }), 1],
    ['npc', party({ name: 'JR.TRAINER♀' }), 1],
    ['npc', party({ name: 'FIREBREATHER WALT' }, 2), 2],
    ['npc', party({ name: 'TWINS AMY & MAY' }, 2), 2],
    ['npc', party({ name: 'SWIMMER♂ HAROLD' }, 2), 2],
    ['npc', party({ name: 'FIREBREATHER ABCDEFGHIJ' }, 2), 2],
    ['npc', party({ name: 'FIREBREATHER ABCDEFGHIJK' }, 2), 2],
    ['npc', party({ name: 'é'.repeat(30) }, 2), 2],
    ['npc', party({ name: '  RIVAL   BLUE  ' }), 1],
    ['npc', party({ name: 'BUG_CATCHER<PK>#' }), 1],
    ['npc', party({ name: '' }), 1],
    ['npc', party({ name: '   ' }), 1],
    ['npc', party({ name: dec('f09f9880') }), 1],
    ['npc', party({ name: dec('c3') }), 1],
    ['npc', party({ name: 42 }), 1],
    ['npc', party({ name: ['A'] }), 1],
    ['npc', party({ name: true }), 1],
    ['npc', party({ name: null }), 1],
    ['npc', party({ name: 'ROCKET', generation: 2 }, 2)],
    ['npc', party({ name: 'ROCKET' })],
    ['npc', { battle: 'b1', mons: [mon3()], name: 'LEADER' }, 3],
  ];
}

function readWave6(kind, input, gen) {
  if (kind === 'event') return sanitize.cleanBattleEvent(input, gen);
  if (kind === 'ruleset') return sanitize.cleanBattleRuleset(input, gen);
  if (kind === 'npc') {
    const read = sanitize.cleanBattleParty(input, gen);
    if (!read) return '(refused)';
    return { name: orNil(read.name), aiMods: orNil(read.aiMods) };
  }
  return undefined;
}

/*
 * Wave 6, the hubs and the real referees: an NPC party's `name` and Red
 * `aiMods` reach the referee on every seat the trainer is dealt across and
 * nowhere else, and the trainer's opening X item prints the cart's AI item line
 * with the seat's name in it, read whole by a Red / Gold client. Twin of
 * wave6_hub_fields in the Lua driver, whose header argues each fight.
 */
function npcFight(generation, mode, sideB, sideA, humans = 1) {
  const relay = makeGenRelay(makeClock(), generation);
  const seen = {};
  const real = relay.Turn;
  relay.Turn = Object.assign(Object.create(real), {
    attempt: (opts) => {
      seen.opts = opts;
      return real.attempt(opts);
    },
  });
  const sprite = generation === 2 ? DEFAULT_SPRITE_GEN2 : DEFAULT_SPRITE;
  const ids = [ID_A, ID_B];
  const names = ['ANN', 'BOB'];
  const players = [];
  for (let i = 0; i < humans; i += 1) {
    players.push(dialAs(relay, names[i], ids[i], { generation, sprite }));
  }
  const memberIds = players.map((p) => p.id);
  const id = 'nf';
  relay.openCoopBattle(id, memberIds, { mode, hostId: memberIds[0] });
  relay.handle(players[0].id, { type: 'mmo.battle_ruleset', battle: id, chart: CHART });
  for (const p of players) {
    relay.handle(p.id, {
      type: 'mmo.battle_party',
      battle: id,
      side: 'a',
      mons: [sheet12(generation, { species: 'HERO' })],
      ...(sideA || {}),
    });
  }
  relay.handle(players[0].id, {
    type: 'mmo.battle_party',
    battle: id,
    side: 'b',
    mons: [sheet12(generation, { species: 'FOE' }), sheet12(generation, { species: 'FOE' })],
    ...(sideB || {}),
  });
  const record = relay.battles.get(id);
  const npcIds = (record && record.npcIds) || [];
  const entries = [];
  for (const side of ['a', 'b']) {
    for (const entry of (seen.opts && seen.opts.sides[side]) || []) {
      const fighter = record && record.sim ? record.sim.byId.get(entry.playerId) : null;
      entries.push({
        side,
        seat: npcIds.includes(entry.playerId) ? 'npc' : entry.playerId,
        name: orNil(entry.name),
        aiMods: orNil(entry.aiMods),
        simName: fighter ? orNil(fighter.name) : '(no sim)',
        simAiMods: fighter ? orNil(fighter.aiMods) : '(no sim)',
      });
    }
  }
  const out = { opened: !!(record && record.sim), entries };
  if (out.opened && humans === 1) {
    players[0].peer.outbox.length = 0;
    relay.handle(players[0].id, {
      type: 'mmo.battle_choice', battle: id, action: 'fight', move: 0,
    });
    out.lines = takeAll(players[0], 'mmo.battle_event')
      .filter((msg) => msg.t === 'msg' && msg.text.includes(' used ') && !msg.text.startsWith('HERO'))
      .map((msg) => {
        const read = sanitize.cleanBattleEvent(msg, generation);
        return { sent: msg.text, read: read ? orNil(read.text) : '(refused)' };
      });
  }
  return out;
}

function runWave6() {
  const xItem = [{ id: 'X_ATTACK', count: 1 }];
  return [
    {
      name: 'referee_gaps_wave6_dialect',
      result: wave6().map(([kind, input, gen]) => ({ kind, got: orNil(readWave6(kind, input, gen)) })),
    },
    {
      name: 'wave6_hub_fields',
      result: {
        redNamed: npcFight(1, 'coop_npc', { name: 'COOLTRAINER♂', aiMods: [1, 3], bag: xItem }),
        redUnnamed: npcFight(1, 'coop_npc', { bag: xItem }),
        redBadName: npcFight(1, 'coop_npc', { name: 42, aiMods: [], bag: xItem }),
        redBadMods: npcFight(1, 'coop_npc', { name: 'LASS', aiMods: [9] }),
        redTwoSeats: npcFight(1, 'coop_npc', { name: 'JR.TRAINER♀', aiMods: [1] }, undefined, 2),
        redHumanClaims: npcFight(1, 'coop_npc', { name: 'LASS' }, { name: 'MALLORY', aiMods: [2] }),
        redWild: npcFight(1, 'wild', { name: 'WILD', aiMods: [1] }),
        goldNamed: npcFight(2, 'coop_npc', { name: 'TWINS AMY & MAY', aiMods: [1], bag: xItem }),
      },
    },
  ];
}

function runLua() {
  const luajit = spawnSync('luajit', [DRIVER, ROOT],
    { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
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
