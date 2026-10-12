'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { Turn } = require('./lib/battle3');
const { Relay } = require('./lib/relay');
const { cleanBattleMoveset } = require('./lib/sanitize');

const move = { id: 'TACKLE', num: 33, effect: 0, power: 1, accuracy: 100,
  pp: 20, maxPp: 20, type: 0, chance: 0, target: 0, priority: 0, flags: 0 };
const stats = { atk: 20, def: 110, spe: 20, spa: 20, spd: 110 };
const mon = () => ({ species: 'MON', speciesNum: 1, level: 10, hp: 30, maxHp: 30,
  stats: { atk: 10, def: 100, spe: 10, spa: 10, spd: 100 }, types: [0], ability: 0, moves: [move] });
function battle(mode = 'coop_npc', rules) {
  return Turn.create({ id: 'growth', mode, rules, seed: 1,
    sides: { a: [{ playerId: 'a', seats: 2, mons: [mon(), mon()] }],
      b: [{ playerId: 'b', mons: [mon()] }] } });
}
function payload() {
  return { battle: 'growth', mon: 0, moves: [move], level: 11, stats, maxHp: 35 };
}

test('Gen 3 wire growth reaches the real Node hub referee', () => {
  const relay = new Relay({ generation: 3 });
  const sim = battle();
  const f = sim.byId.get('a');
  f.mons[0].hp = 7;
  const clean = cleanBattleMoveset(payload(), 3);
  assert.deepEqual(clean.stats, stats);
  assert.equal(relay.applyBattleMoveset({ sim, mode: 'coop_npc' }, { id: 'a' }, clean), true);
  assert.equal(f.mons[0].level, 11);
  assert.equal(f.mons[0].hp, 12);
  assert.equal(f.mons[0].maxHp, 35);
  assert.equal(f.b.stats.atk, 20);
  assert.equal(f.b.moves[0].pp, 20);
  assert.equal(sim.levelUp('a', 2, 11, stats, 35), true);
  assert.equal(f.seats[1].b.stats.atk, 20);
});

test('growth preserves Transform copies, Mimic moves and battle stages', () => {
  const sim = battle();
  const f = sim.byId.get('a');
  f.b.transformed = true;
  f.b.overlay = true;
  f.b.stats = { atk: 120, def: 120, spe: 120, spa: 120, spd: 120 };
  f.b.stages.atk = 2;
  assert.equal(sim.levelUp('a', 1, 11, stats, 35), true);
  assert.equal(f.mons[0].stats.atk, 20);
  assert.equal(f.b.stats.atk, 120);
  assert.equal(f.b.stages.atk, 2);
  const other = f.seats[1].b;
  const copied = [{ ...move, id: 'COPIED', num: 45 }];
  other.overlay = true;
  other.moves = copied;
  assert.equal(sim.levelUp('a', 2, 11, stats, 35), true);
  assert.equal(other.stats.atk, 20);
  assert.equal(other.moves, copied);
});

test('invalid growth claims cannot mutate or heal a monster', () => {
  const sim = battle();
  const f = sim.byId.get('a');
  assert.equal(sim.levelUp('a', 1, 11, stats, 35), true);
  f.mons[0].hp = 7;
  assert.equal(sim.levelUp('a', 1, 11, stats, 35), false);
  assert.equal(f.mons[0].hp, 7);
  assert.equal(sim.levelUp('b', 1, 11, stats, 35), false);
  assert.equal(sim.levelUp('missing', 1, 11, stats, 35), false);
  assert.equal(sim.levelUp('a', 3, 11, stats, 35), false);
  const before = structuredClone(f.mons[1]);
  for (const [level, next, hp] of [[10, stats, 35], [101, stats, 35],
    [11, { atk: 20 }, 35], [11, { ...stats, atk: 1000 }, 35], [11, stats, 29]]) {
    assert.equal(sim.levelUp('a', 2, level, next, hp), false);
    assert.deepEqual(f.mons[1], before);
  }
  f.mons[1].hp = 0;
  assert.equal(sim.levelUp('a', 2, 11, stats, 35), false);
  assert.equal(battle('coop_npc', { exp: false }).levelUp('a', 1, 11, stats, 35), false);
});

test('PvP drops growth at both the hub and referee boundaries', () => {
  const sim = battle('coop_pvp');
  const relay = new Relay({ generation: 3 });
  assert.equal(sim.levelUp('a', 1, 11, stats, 35), false);
  assert.equal(relay.applyBattleMoveset({ sim, mode: 'coop_pvp' }, { id: 'a' }, payload()), false);
  assert.equal(sim.byId.get('a').mons[0].level, 10);
});

test('the Gen 3 sanitiser refuses incomplete and out-of-range growth', () => {
  for (const raw of [{ ...payload(), level: 0 }, { ...payload(), maxHp: 1000 },
    { ...payload(), stats: { atk: 10 } }, { ...payload(), stats: { ...stats, atk: 1000 } }]) {
    assert.equal(cleanBattleMoveset(raw, 3), null);
  }
});
