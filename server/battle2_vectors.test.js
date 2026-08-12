#!/usr/bin/env node
'use strict';

/*
 * Parity suite for the hub's Gen2 battle formulas: `lib/battle2/`.
 *
 * Every case here comes out of tests/fixtures/battle_sim2_vectors.json, which
 * tests/battle_sim2_vectors.lua also drives against the Lua twin in
 * src/BattleSim2. That shared file is the whole point. A mediated Gen2 battle
 * can be resolved by a dedicated Node hub or by a LAN host running the Lua
 * sim, and the same fight has to come out the same way on both.
 *
 * So the expected numbers are never computed here. They are read from the
 * fixture and compared field for field, intermediates included.
 *
 * ROM-free by construction: no species, move or type-chart data appears in
 * the fixture or in the module under test. The caller supplies integers.
 *
 * Run: node --test server/battle2_vectors.test.js
 */

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const { damage, accuracy, crit, status, Rng } = require('./lib/battle2');

const FIXTURE = path.join(__dirname, '..', 'tests', 'fixtures', 'battle_sim2_vectors.json');
const vectors = JSON.parse(fs.readFileSync(FIXTURE, 'utf8'));

function expectFields(actual, expected, label) {
  for (const key of Object.keys(expected)) {
    assert.strictEqual(
      actual[key],
      expected[key],
      `${label}: ${key} expected ${JSON.stringify(expected[key])}, got ${JSON.stringify(actual[key])}`,
    );
  }
}

test('fixture pack is the one this suite was written against', () => {
  assert.strictEqual(vectors.version, 1, 'fixture version bumped — reread the notes before touching this');
  assert.strictEqual(vectors.generation, 2, 'this suite is Gen2-only');
  for (const group of ['damage', 'accuracy', 'crit', 'status']) {
    assert.ok(Array.isArray(vectors[group]) && vectors[group].length > 0, `${group} vectors present`);
  }
});

test('damage vectors', async (t) => {
  for (const v of vectors.damage) {
    await t.test(v.id, () => {
      const got = damage.compute(v.in);
      expectFields(got, v.out, v.id);

      if (v.in.roll !== null && v.in.roll !== undefined && !v.out.immune) {
        assert.ok(
          got.damage >= got.minDamage && got.damage <= got.maxDamage,
          `${v.id}: damage ${got.damage} outside its own band ${got.minDamage}..${got.maxDamage}`,
        );
      }

      if (v.out.minDamage !== undefined) {
        for (let roll = damage.ROLL_MIN; roll <= damage.ROLL_MAX; roll++) {
          const d = damage.compute({ ...v.in, roll }).damage;
          assert.ok(
            d >= v.out.minDamage && d <= v.out.maxDamage,
            `${v.id}: roll ${roll} gave ${d}, outside ${v.out.minDamage}..${v.out.maxDamage}`,
          );
        }
      }
    });
  }
});

test('damage is integer everywhere (or null band), never NaN', () => {
  for (const v of vectors.damage) {
    const got = damage.compute(v.in);
    for (const [key, value] of Object.entries(got)) {
      if (typeof value === 'number') {
        assert.ok(Number.isInteger(value), `${v.id}: ${key} is ${value}, not an integer`);
      }
    }
  }
});

test('immunity short-circuits before the random roll', () => {
  const immune = damage.compute({
    level: 100, power: 150, attack: 255, defense: 1,
    stab: true, typeEffect: [200, 0, 200], crit: true, roll: 100, physical: true,
  });
  assert.strictEqual(immune.immune, true, 'a 0% anywhere in the list is immunity');
  assert.strictEqual(immune.damage, 0, 'and the min-1 clamp does not rescue it');
  assert.strictEqual(immune.modified, 0, 'nothing after the 0% runs');
});

test('no Gen1 255-stat clamp', () => {
  const got = damage.compute({
    level: 50, power: 40, attack: 400, defense: 200,
    physical: true, stab: false, typeEffect: [100], crit: false, roll: 100,
  });
  assert.strictEqual(got.statClamped, false, 'Gen2 never quarters overflow stats');
  assert.strictEqual(got.attack, 400);
  assert.strictEqual(got.defense, 200);
});

test('accuracy vectors', async (t) => {
  for (const v of vectors.accuracy) {
    await t.test(v.id, () => {
      expectFields(accuracy.hit(v.in), v.out, v.id);
    });
  }
});

test('a 100% move hits every roll 0..99 (no Gen1 1/256 quirk)', () => {
  let hits = 0;
  for (let roll = 0; roll <= accuracy.ROLL_MAX; roll++) {
    if (accuracy.hit({
      accuracy: 100, accuracyStage: 0, evasionStage: 0, roll,
    }).hit) hits++;
  }
  assert.strictEqual(hits, 100, 'roll 0..99 all hit a neutral 100% move');

  let always = 0;
  for (let roll = 0; roll <= accuracy.ROLL_MAX; roll++) {
    if (accuracy.hit({ accuracy: 100, alwaysHits: true, roll }).hit) always++;
  }
  assert.strictEqual(always, 100, 'a move that cannot miss does not consult the roll');
});

test('accuracy clamps at both ends', () => {
  assert.strictEqual(accuracy.effective(100, 6, 0), 100, 'boosts cannot exceed 100');
  assert.strictEqual(accuracy.effective(10, -6, 6), 1, 'stacked drops floor at 1, never 0');
});

test('crit vectors', async (t) => {
  for (const v of vectors.crit) {
    await t.test(v.id, () => {
      expectFields(crit.check(v.in), v.out, v.id);
    });
  }
});

test('focus energy raises crit level (no Gen1 bug)', () => {
  assert.strictEqual(crit.level({}), 0);
  assert.strictEqual(crit.level({ focusEnergy: true }), 1);
  assert.strictEqual(crit.chance(0), 15);
  assert.strictEqual(crit.chance(1), 8);
  assert.strictEqual(
    crit.level({ focusEnergy: true, highCritMove: true, scopeLens: true }),
    4,
  );
});

test('crit roll 0 is the only crit in the ladder window', () => {
  for (let level = 0; level <= 6; level++) {
    const ch = crit.chance(level);
    let crits = 0;
    for (let roll = 0; roll < ch; roll++) {
      if (crit.check({ criticalLevel: level, roll }).isCrit) crits++;
    }
    assert.strictEqual(crits, 1, `level ${level}: exactly one of 0..${ch - 1} is a crit`);
  }
});

test('status vectors', async (t) => {
  for (const v of vectors.status) {
    await t.test(v.id, () => {
      const got = status.evaluate(v.in);
      assert.ok(got !== null, `${v.id}: no handler for status ${v.in.status}`);
      expectFields(got, v.out, v.id);
    });
  }
});

test('freeze thaws exactly when roll % 5 === 0', () => {
  let thaws = 0;
  for (let roll = 0; roll < 20; roll++) {
    if (status.freezeTick(roll).thawed) thaws++;
  }
  assert.strictEqual(thaws, 4, '0,5,10,15 of 0..19');
});

test('paralysis stops exactly when roll % 4 === 0', () => {
  let stopped = 0;
  for (let roll = 0; roll < 16; roll++) {
    if (status.paralysisTick(roll).fullyParalyzed) stopped++;
  }
  assert.strictEqual(stopped, 4, '0,4,8,12 of 0..15 — 1/4');
});

test('confusion self-hits exactly half the time and shares Gen2 damage', () => {
  const state = { turnsRemaining: 3, level: 50, attack: 100, defense: 100 };
  let selfHits = 0;
  for (let roll = 0; roll <= 255; roll++) {
    if (status.confusionTick(state, roll).selfHit) selfHits++;
  }
  assert.strictEqual(selfHits, status.CONFUSION_HIT_ROLL, '128/256');

  const viaStatus = status.confusionTick(state, 0).selfDamage;
  const viaDamage = damage.compute({
    level: 50, power: status.CONFUSION_POWER, attack: 100, defense: 100,
    stab: false, typeEffect: [100], crit: false, roll: damage.ROLL_MAX,
    physical: true,
  }).damage;
  assert.strictEqual(viaStatus, viaDamage, 'the self-hit is the ordinary Gen2 formula');
});

test('the turn a mon snaps out of confusion is a turn it acts', () => {
  const got = status.confusionTick({ turnsRemaining: 1, level: 50, attack: 100, defense: 100 }, 0);
  assert.strictEqual(got.snappedOut, true, 'counter hits zero');
  assert.strictEqual(got.canMove, true, 'and the turn is not also lost');
});

test('sleep wakes and can move on the same turn', () => {
  const got = status.sleepTick(1);
  assert.strictEqual(got.wokeUp, true);
  assert.strictEqual(got.canMove, true, 'Gen2 waking turn is free');
});

test('the before-move dispatcher answers only for statuses that gate a turn', () => {
  assert.strictEqual(status.beforeMove({ status: 'sleep', turnsRemaining: 2 }).status, 'sleep');
  assert.strictEqual(status.beforeMove({ status: 'burn' }, 0), null,
    'burn costs HP at end of turn, it does not gate the move');
  assert.strictEqual(status.residual({ status: 'paralysis', maxHp: 160 }), null,
    'and paralysis is the mirror case — a gate with no residual');
  assert.strictEqual(status.residual({ status: 'toxic', maxHp: 160, toxicCounter: 2 }), 20,
    'toxic multiplies maxHp by counter over 16');
  assert.strictEqual(status.residual({ status: 'burn', maxHp: 80 }), 10,
    'burn is 1/8 in Gen2');
});

test('Rng LCG matches the Lua twin for a known seed stream', () => {
  const rng = Rng.create(12345);
  // First five raw states from src/BattleSim2/Rng.lua with seed 12345
  // (same LCG as Gen1 BattleSim/Rng.lua).
  const expected = [87628868, 71072467, 2332836374, 2726892157, 3908547000];
  for (let i = 0; i < expected.length; i++) {
    assert.strictEqual(rng.next(), expected[i], `raw state #${i + 1}`);
  }
  const again = Rng.create(12345);
  const a = [again.byte(), again.byte(), again.byte()];
  const clone = Rng.create(12345);
  assert.deepStrictEqual([clone.byte(), clone.byte(), clone.byte()], a, 'same seed, same bytes');
  const band = Rng.create(99);
  for (let i = 0; i < 64; i++) {
    const r = band.damageRoll();
    assert.ok(r >= Rng.DAMAGE_ROLL_MIN && r <= Rng.DAMAGE_ROLL_MAX, `damage roll ${r} in band`);
  }
  const live = Rng.create(7);
  for (let i = 0; i < 10; i++) live.byte();
  const restored = Rng.create(0).setState(live.state());
  assert.strictEqual(live.byte(), restored.byte(), 'state restores');
  assert.strictEqual(Rng.create(1).below(1), 0, 'below(1) is 0');
  assert.ok(Rng.create(2).below(15) < 15, 'below(n) is in range');
});
