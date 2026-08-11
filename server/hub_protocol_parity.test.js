#!/usr/bin/env node
'use strict';

/*
 * Cross-runtime parity suite for the hub envelope: Hub.lua ↔ relay.js.
 *
 * BattleSim event streams stay in battle_turn.test.js. This file pins the
 * seats a client would notice if the two hosting paths drifted: admit under
 * playerId, duplicate-id refuse, protocol refuse wording, mediated KO /
 * disconnect-forfeit settlement keyed by playerId, and the mmo.relay hard cut.
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

const { Relay, PROTOCOL, DEFAULT_SPRITE } = require('./lib/relay.js');
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
  assert.ok(jsRuns.length >= 11, 'the JS half built every scenario');
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
