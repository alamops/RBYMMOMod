#!/usr/bin/env node
'use strict';

/*
 * Dig / Fly / charge-family semantics on the JS twins.
 * Mirrors tests/battle_sim_turn.lua and tests/battle_sim2_turn.lua.
 *
 * Run: node --test server/battle_charge.test.js
 */

const test = require('node:test');
const assert = require('node:assert');

const Battle1 = require('./lib/battle');
const Battle2 = require('./lib/battle2');

function mv(o) {
  return {
    id: o.id,
    pp: o.pp === undefined ? 10 : o.pp,
    power: o.power === undefined ? 60 : o.power,
    accuracy: o.accuracy === undefined ? 255 : o.accuracy,
    type: o.type || 0,
    effect: o.effect || 0,
    chance: 0,
  };
}

function fight(Turn, opts) {
  const { battle, reason } = Turn.attempt({
    id: opts.id || 'c1',
    mode: '1v1',
    seed: opts.seed || 4242,
    choiceTimeout: 60,
    reconnectGrace: 60,
    sides: opts.sides,
  });
  assert.ok(battle, `refused: ${reason}`);
  battle.drainEvents();
  return battle;
}

function gen1Sides(aMove, bMove) {
  return {
    a: [{
      playerId: 'p1', name: 'Ann',
      mons: [{
        species: 'Alpha', level: 40, maxHp: 200, hp: 200,
        stats: { atk: 80, def: 40, spd: 120, spc: 40 },
        moves: [aMove],
      }],
    }],
    b: [{
      playerId: 'p2', name: 'Bob',
      mons: [{
        species: 'Beta', level: 20, maxHp: 200, hp: 200,
        stats: { atk: 80, def: 40, spd: 1, spc: 40 },
        moves: [bMove],
      }],
    }],
  };
}

function gen2Sides(aMove, bMove) {
  return {
    a: [{
      playerId: 'p1', name: 'Ann',
      mons: [{
        species: 'Alpha', level: 40, maxHp: 200, hp: 200,
        stats: { atk: 80, def: 40, spe: 120, spa: 40, spd: 40 },
        moves: [aMove],
      }],
    }],
    b: [{
      playerId: 'p2', name: 'Bob',
      mons: [{
        species: 'Beta', level: 20, maxHp: 200, hp: 200,
        stats: { atk: 80, def: 40, spe: 1, spa: 40, spd: 40 },
        moves: [bMove],
      }],
    }],
  };
}

test('gen1 DIG: dug a hole, invulnerable, Earthquake fails', () => {
  const battle = fight(Battle1.Turn, {
    seed: 4242,
    sides: gen1Sides(
      mv({ id: 'DIG', effect: 39 }),
      mv({ id: 'EARTHQUAKE', power: 80 }),
    ),
  });
  battle.submitChoice('p1', { action: 'fight', move: 0 });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  const events = battle.drainEvents();
  assert.ok(events.some((e) => e.t === 'msg' && e.text.includes('dug a hole')));
  assert.ok(events.some((e) => e.t === 'anim' && e.text === 'DIG' && e.amount === 1));
  // MoveHitTest's INVULNERABLE miss is PrintMoveFailureText's "<USER>'s attack
  // missed!" (R1c), not "But it failed".
  assert.ok(events.some((e) => e.t === 'msg' && e.text === "Beta's attack missed!"));
  assert.ok(!events.some((e) => e.t === 'damage'));
  const p1 = battle.byId.get('p1');
  const alpha = p1.mons[p1.active - 1];
  assert.strictEqual(alpha.invulnerable, true);
});

// Red's MoveHitTest has no THUNDER exception: `bit INVULNERABLE / jp nz,
// .moveMissed` (core.asm :5258-5260), SWIFT's `ret z` alone comes before it.
// THUNDER reaching FLY is Gold's (R1c).
test('gen1 Thunder does not reach Fly', () => {
  const battle = fight(Battle1.Turn, {
    seed: 4343,
    sides: gen1Sides(
      mv({ id: 'FLY', power: 70, effect: 43 }),
      mv({ id: 'THUNDER', power: 80 }),
    ),
  });
  battle.submitChoice('p1', { action: 'fight', move: 0 });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  const events = battle.drainEvents();
  assert.ok(events.some((e) => e.t === 'msg' && e.text.includes('flew up high')));
  assert.ok(!events.some((e) => e.t === 'damage' && e.slot === 0));
  assert.ok(events.some((e) => e.t === 'msg' && e.text === "Beta's attack missed!"));
});

test('gen1 charge-family texts and DIG turn two', () => {
  const Effects = Battle1.Effects;
  assert.strictEqual(
    Effects.chargeMessage({ species: 'Alpha' }, 39, 'SOLARBEAM'),
    'Alpha took in sunlight!',
  );
  assert.strictEqual(
    Effects.chargeMessage({ species: 'Alpha' }, 39, 'SKULL_BASH'),
    'Alpha lowered its head!',
  );
  const battle = fight(Battle1.Turn, {
    seed: 4242,
    sides: gen1Sides(
      mv({ id: 'DIG', effect: 39 }),
      mv({ id: 'SPLASH', power: 0, effect: 85 }),
    ),
  });
  battle.submitChoice('p1', { action: 'fight', move: 0 });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  battle.drainEvents();
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  const turn2 = battle.drainEvents();
  assert.ok(turn2.some((e) => e.t === 'anim' && e.text === 'DIG' && e.amount == null));
  assert.ok(turn2.some((e) => e.t === 'damage'));
});

test('gen2 EFFECT_* aliases and Earthquake reaches Dig', () => {
  assert.strictEqual(Battle2.Effects.idOf('EFFECT_FLY'), 43);
  // The referee-gaps run's wave 3 (R2c): SOLARBEAM has its own id (its sun
  // skip and rain halving), still a charge move; RAZOR WIND keeps CHARGE.
  assert.strictEqual(Battle2.Effects.idOf('EFFECT_RAZOR_WIND'), 39);
  assert.strictEqual(Battle2.Effects.idOf('EFFECT_SOLARBEAM'), Battle2.Effects.SOLARBEAM);
  assert.ok(Battle2.Effects.isCharge(Battle2.Effects.SOLARBEAM));
  assert.strictEqual(Battle2.Effects.idOf('EFFECT_DEFENSE_DOWN'), 19);
  assert.strictEqual(Battle2.Effects.idOf('EFFECT_DEFENSE_DOWN_2'), 59);
  assert.strictEqual(Battle2.Effects.idOf('EFFECT_SLEEP'), 32);
  assert.strictEqual(Battle2.Effects.idOf('EFFECT_PARALYZE_HIT'), 6);
  assert.strictEqual(Battle2.Effects.idOf('EFFECT_METRONOME'), 83);
  // ...and PROTECT is handled (R2c's BattleCommand_Protect).
  assert.strictEqual(Battle2.Effects.idOf('EFFECT_PROTECT'), Battle2.Effects.PROTECT);
  const battle = fight(Battle2.Turn, {
    seed: 5151,
    sides: gen2Sides(
      mv({ id: 'DIG', effect: 39 }),
      mv({ id: 'EARTHQUAKE', power: 80 }),
    ),
  });
  battle.submitChoice('p1', { action: 'fight', move: 0 });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  const events = battle.drainEvents();
  assert.ok(events.some((e) => e.t === 'msg' && e.text.includes('dug a hole')));
  assert.ok(events.some((e) => e.t === 'damage' && e.slot === 0));
});

test('gen2 2v2 Crystal status names actually apply', () => {
  const leer = Battle2.Effects.idOf('EFFECT_DEFENSE_DOWN');
  const sleep = Battle2.Effects.idOf('EFFECT_SLEEP');
  const { battle, reason } = Battle2.Turn.attempt({
    id: 's1',
    mode: 'coop_pvp',
    seed: 4242,
    choiceTimeout: 60,
    reconnectGrace: 60,
    sides: {
      a: [
        {
          playerId: 'a1', name: 'Ann',
          mons: [{
            species: 'Alpha', level: 20, maxHp: 200, hp: 200,
            stats: { atk: 40, def: 40, spe: 90, spa: 40, spd: 40 },
            // The wire's accuracy byte: 255 never draws (R2c's CheckHit); 0
            // was the old percent domain's "never misses".
            moves: [mv({ id: 'leer', power: 0, accuracy: 255, effect: leer })],
          }],
        },
        {
          playerId: 'a2', name: 'Abe',
          mons: [{
            species: 'Gamma', level: 20, maxHp: 200, hp: 200,
            stats: { atk: 40, def: 40, spe: 80, spa: 40, spd: 40 },
            moves: [mv({ id: 'hypno', power: 0, accuracy: 255, effect: sleep })],
          }],
        },
      ],
      b: [
        {
          playerId: 'b1', name: 'Bob',
          mons: [{
            species: 'Beta', level: 20, maxHp: 200, hp: 200,
            stats: { atk: 40, def: 80, spe: 5, spa: 40, spd: 40 },
            moves: [mv({ id: 'thump', power: 1 })],
          }],
        },
        {
          playerId: 'b2', name: 'Bea',
          mons: [{
            species: 'Delta', level: 20, maxHp: 200, hp: 200,
            stats: { atk: 40, def: 40, spe: 5, spa: 40, spd: 40 },
            moves: [mv({ id: 'thump', power: 1 })],
          }],
        },
      ],
    },
  });
  assert.ok(battle, `refused: ${reason}`);
  battle.drainEvents();
  battle.submitChoice('a1', { action: 'fight', move: 0, target: 3 });
  battle.submitChoice('a2', { action: 'fight', move: 0, target: 4 });
  battle.submitChoice('b1', { action: 'fight', move: 0, target: 0 });
  battle.submitChoice('b2', { action: 'fight', move: 0, target: 0 });
  const events = battle.drainEvents();
  assert.ok(!events.some((e) => e.t === 'msg' && String(e.text).includes('nothing happened')),
    'status moves do not no-op');
  assert.ok(events.some((e) => e.t === 'msg' && String(e.text).includes('DEFENSE fell')),
    'Leer drops Defense');
  assert.ok(events.some((e) => e.t === 'msg' && String(e.text).includes('fell asleep')),
    'Hypnosis inflicts sleep');
  assert.strictEqual(battle.byId.get('b1').mons[0].stages.def, -1);
  assert.strictEqual(battle.byId.get('b2').mons[0].status, 'sleep');
});

test('gen2 2v2 Metronome calls a move from the uploaded pool', () => {
  const metro = Battle2.Effects.idOf('EFFECT_METRONOME');
  const { battle, reason } = Battle2.Turn.attempt({
    id: 'm1',
    mode: 'coop_pvp',
    seed: 7,
    choiceTimeout: 60,
    reconnectGrace: 60,
    metronomePool: [mv({ id: 'pool-thump', power: 60, accuracy: 255 })],
    sides: {
      a: [
        {
          playerId: 'a1', name: 'Ann',
          mons: [{
            species: 'Alpha', level: 50, maxHp: 200, hp: 200,
            stats: { atk: 100, def: 40, spe: 120, spa: 40, spd: 40 },
            moves: [mv({ id: 'metronome', power: 0, accuracy: 0, effect: metro })],
          }],
        },
        {
          playerId: 'a2', name: 'Abe',
          mons: [{
            species: 'Gamma', level: 20, maxHp: 200, hp: 200,
            stats: { atk: 40, def: 40, spe: 80, spa: 40, spd: 40 },
            moves: [mv({ id: 'thump', power: 1 })],
          }],
        },
      ],
      b: [
        {
          playerId: 'b1', name: 'Bob',
          mons: [{
            species: 'Beta', level: 20, maxHp: 200, hp: 200,
            stats: { atk: 40, def: 40, spe: 5, spa: 40, spd: 40 },
            moves: [mv({ id: 'thump', power: 1 })],
          }],
        },
        {
          playerId: 'b2', name: 'Bea',
          mons: [{
            species: 'Delta', level: 20, maxHp: 200, hp: 200,
            stats: { atk: 40, def: 40, spe: 5, spa: 40, spd: 40 },
            moves: [mv({ id: 'thump', power: 1 })],
          }],
        },
      ],
    },
  });
  assert.ok(battle, `refused: ${reason}`);
  battle.drainEvents();
  const hpBefore = battle.byId.get('b1').mons[0].hp;
  battle.submitChoice('a1', { action: 'fight', move: 0, target: 3 });
  battle.submitChoice('a2', { action: 'fight', move: 0, target: 3 });
  battle.submitChoice('b1', { action: 'fight', move: 0, target: 0 });
  battle.submitChoice('b2', { action: 'fight', move: 0, target: 0 });
  const events = battle.drainEvents();
  assert.ok(events.some((e) => e.t === 'anim' && e.text === 'pool-thump'));
  assert.ok(battle.byId.get('b1').mons[0].hp < hpBefore);
});
