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
  assert.ok(events.some((e) => e.t === 'msg' && e.text.includes('But it failed')));
  assert.ok(!events.some((e) => e.t === 'damage'));
  const p1 = battle.byId.get('p1');
  const alpha = p1.mons[p1.active - 1];
  assert.strictEqual(alpha.invulnerable, true);
});

test('gen1 Thunder reaches Fly', () => {
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
  assert.ok(events.some((e) => e.t === 'damage' && e.slot === 0));
  assert.ok(!events.some((e) => e.t === 'msg' && e.text.includes('But it failed')));
});

test('gen1 charge-family texts and DIG turn two', () => {
  const Effects = Battle1.Effects;
  assert.strictEqual(
    Effects.chargeMessage({ species: 'Alpha' }, 39, 'SOLARBEAM'),
    'Alpha took in sunlight',
  );
  assert.strictEqual(
    Effects.chargeMessage({ species: 'Alpha' }, 39, 'SKULL_BASH'),
    'Alpha lowered its head',
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
  assert.strictEqual(Battle2.Effects.idOf('EFFECT_SOLARBEAM'), 39);
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
