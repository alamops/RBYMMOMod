#!/usr/bin/env node
'use strict';

/*
 * Parity suite for the hub's battle formulas: `lib/battle/`.
 *
 * Every case here comes out of tests/fixtures/battle_sim_vectors.json, which
 * mods/rby_mmo/tests also drives against the Lua twin in src/BattleSim. That
 * shared file is the whole point. A mediated battle can be resolved by a
 * dedicated Node hub or by a LAN host running the Lua sim, and the same fight
 * has to come out the same way on both -- a hub that prices a hit at 47 while
 * the host prices it at 48 is not one game, it is two, and the losing player
 * has no way to find out which half was wrong.
 *
 * So the expected numbers are never computed here. They are read from the
 * fixture and compared field for field, intermediates included: when the two
 * runtimes do drift, the first intermediate that differs is the bug report.
 *
 * Beyond the fixture, two properties are swept rather than sampled -- the
 * damage roll band over all of 217..255, and the hit/crit thresholds over all
 * 256 roll values -- because off-by-one at a boundary is exactly the kind of
 * drift a table of hand-picked cases walks past.
 *
 * ROM-free by construction: no species, move or type-chart data appears in
 * the fixture or in the module under test. The caller supplies integers.
 *
 * Run: node --test server/battle.test.js   (or: node server/battle.test.js)
 */

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const { damage, accuracy, crit, status } = require('./lib/battle');

const FIXTURE = path.join(__dirname, '..', 'tests', 'fixtures', 'battle_sim_vectors.json');
const vectors = JSON.parse(fs.readFileSync(FIXTURE, 'utf8'));

// Compare only the fields the fixture states. A runtime may report more than
// the fixture pins (Damage always reports the roll band, for instance); it may
// never report one of these differently.
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
  assert.strictEqual(vectors.version, 1, 'fixture version bumped -- reread the notes before touching this');
  for (const group of ['damage', 'accuracy', 'crit', 'status']) {
    assert.ok(Array.isArray(vectors[group]) && vectors[group].length > 0, `${group} vectors present`);
  }
});

test('damage vectors', async (t) => {
  for (const v of vectors.damage) {
    await t.test(v.id, () => {
      const got = damage.compute(v.in);
      expectFields(got, v.out, v.id);

      // A named roll must land inside the band the same call reports.
      if (v.in.roll !== null && !v.out.immune) {
        assert.ok(
          got.damage >= got.minDamage && got.damage <= got.maxDamage,
          `${v.id}: damage ${got.damage} outside its own band ${got.minDamage}..${got.maxDamage}`,
        );
      }

      // Where the fixture states a band, hold it over every legal roll rather
      // than trusting the two endpoints.
      if (v.out.minDamage !== undefined) {
        for (let roll = damage.ROLL_MIN; roll <= damage.ROLL_MAX; roll++) {
          const d = damage.compute({ ...v.in, roll }).damage;
          assert.ok(
            d >= v.out.minDamage && d <= v.out.maxDamage,
            `${v.id}: roll ${roll} gave ${d}, outside ${v.out.minDamage}..${v.out.maxDamage}`,
          );
        }
      }

      // The fixture carries the types alongside the precomputed STAB flag;
      // if those two ever disagree, one of them is a typo.
      assert.strictEqual(
        damage.hasStab(v.in.moveType, v.in.attackerTypes),
        v.in.stab,
        `${v.id}: stab flag disagrees with the move/attacker types beside it`,
      );
    });
  }
});

test('damage is integer everywhere, never NaN', () => {
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
    stab: true, typeEffect: [200, 0, 200], crit: true, roll: 255,
  });
  assert.strictEqual(immune.immune, true, 'a 0% anywhere in the list is immunity');
  assert.strictEqual(immune.damage, 0, 'and the min-1 clamp does not rescue it');
  assert.strictEqual(immune.modified, 0, 'nothing after the 0% runs');
});

test('either stat over 255 quarters both', () => {
  const both = damage.clampStats(400, 200);
  assert.deepStrictEqual(
    both,
    { attack: 100, defense: 50, statClamped: true },
    'the stat that did not overflow is quartered too',
  );
  assert.strictEqual(damage.clampStats(255, 255).statClamped, false, '255 itself is under the cap');
  assert.strictEqual(damage.clampStats(256, 2).defense, 1, 'and a quartered stat floors at 1');
});

test('accuracy vectors', async (t) => {
  for (const v of vectors.accuracy) {
    await t.test(v.id, () => {
      expectFields(accuracy.hit(v.in), v.out, v.id);
    });
  }
});

test('a 255-accuracy move still misses once in 256', () => {
  let hits = 0;
  for (let roll = 0; roll <= 255; roll++) {
    if (accuracy.hit({ accuracy: 255, accuracyMod: 100, evasionMod: 100, roll }).hit) hits++;
  }
  assert.strictEqual(hits, 255, 'roll 255 is the Gen1 miss and it is kept');

  let always = 0;
  for (let roll = 0; roll <= 255; roll++) {
    if (accuracy.hit({ accuracy: 255, alwaysHits: true, roll }).hit) always++;
  }
  assert.strictEqual(always, 256, 'a move that cannot miss does not consult the roll');
});

test('accuracy clamps at both ends', () => {
  assert.strictEqual(accuracy.effective(255, 200, 100), 255, 'boosts cannot exceed the byte');
  assert.strictEqual(accuracy.effective(10, 33, 33), 1, 'and stacked drops floor at 1, never 0');
});

test('crit vectors', async (t) => {
  for (const v of vectors.crit) {
    await t.test(v.id, () => {
      expectFields(crit.check(v.in), v.out, v.id);
    });
  }
});

test('focus energy is kept as the bug it is', () => {
  const plain = crit.threshold(100, {});
  const focused = crit.threshold(100, { focusEnergy: true });
  assert.ok(focused < plain, 'Focus Energy makes crits rarer in Gen1');
  assert.strictEqual(
    crit.threshold(100, { focusEnergy: true, highCritMove: true }),
    96,
    'quartered first, multiplied after, clamped last',
  );
  assert.strictEqual(crit.threshold(1, {}), 0, 'a threshold of 0 can never beat a roll of 0');
});

test('crit threshold matches its own roll sweep', () => {
  for (const v of vectors.crit) {
    const t = crit.check(v.in).threshold;
    let crits = 0;
    for (let roll = 0; roll <= 255; roll++) {
      if (crit.check({ ...v.in, roll }).isCrit) crits++;
    }
    assert.strictEqual(crits, t, `${v.id}: threshold ${t} should crit on exactly ${t} of 256 rolls`);
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

test('freeze never self-thaws at any roll', () => {
  for (let roll = 0; roll <= 255; roll++) {
    const got = status.freezeTick(roll);
    assert.strictEqual(got.thawed, false, `roll ${roll} must not thaw`);
    assert.strictEqual(got.canMove, false, `roll ${roll} must not act`);
  }
});

test('paralysis stops exactly 63 of 256 turns', () => {
  let stopped = 0;
  for (let roll = 0; roll <= 255; roll++) {
    if (status.paralysisTick(roll).fullyParalyzed) stopped++;
  }
  assert.strictEqual(stopped, status.PARALYSIS_STOP_ROLL, 'not a quarter -- 63/256');
});

test('confusion self-hits exactly half the time and shares the damage formula', () => {
  const state = { turnsRemaining: 3, level: 50, attack: 100, defense: 100 };
  let selfHits = 0;
  for (let roll = 0; roll <= 255; roll++) {
    if (status.confusionTick(state, roll).selfHit) selfHits++;
  }
  assert.strictEqual(selfHits, status.CONFUSION_HIT_ROLL, '128/256');

  const viaStatus = status.confusionTick(state, 0).selfDamage;
  const viaDamage = damage.compute({
    level: 50, power: status.CONFUSION_POWER, attack: 100, defense: 100,
    stab: false, typeEffect: [100], crit: false, roll: 255,
  }).damage;
  assert.strictEqual(viaStatus, viaDamage, 'the self-hit is the ordinary formula, not a second one');
});

test('the turn a mon snaps out of confusion is a turn it acts', () => {
  const got = status.confusionTick({ turnsRemaining: 1, level: 50, attack: 100, defense: 100 }, 0);
  assert.strictEqual(got.snappedOut, true, 'counter hits zero');
  assert.strictEqual(got.canMove, true, 'and the turn is not also lost');
});

test('the before-move dispatcher answers only for statuses that gate a turn', () => {
  assert.strictEqual(status.beforeMove({ status: 'sleep', turnsRemaining: 2 }).status, 'sleep',
    'the gate reports which status closed it');
  assert.strictEqual(status.beforeMove({ status: 'burn' }, 0), null,
    'burn costs HP at end of turn, it does not gate the move');
  assert.strictEqual(status.residual({ status: 'paralysis', maxHp: 160 }), null,
    'and paralysis is the mirror case -- a gate with no residual');
  assert.strictEqual(status.residual({ status: 'toxic', maxHp: 160, toxicCounter: 2 }), 20,
    'toxic multiplies the same sixteenth by its counter');
});

test('Rng LCG matches the Lua twin for a known seed stream', () => {
  const { Rng } = require('./lib/battle');
  const rng = Rng.create(12345);
  // First five raw states from src/BattleSim/Rng.lua with seed 12345
  // (luajit: Rng.new(12345); r:next() × 5).
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
});

test('JS formula edge inputs match Lua coercion', () => {
  // Damage: bare typeEffect, atk/def aliases, missing level → 1 (not NaN).
  const bare = damage.compute({
    level: 50, power: 40, atk: 100, def: 100,
    stab: false, typeEffect: 100, crit: false, roll: 255,
  });
  assert.ok(Number.isInteger(bare.damage), 'bare typeEffect percent still deals an integer');
  assert.strictEqual(bare.immune, false);

  const alias = damage.compute({
    power: 40, atk: 100, def: 100,
    stab: false, typeEff: [100], crit: false, roll: 255,
  });
  assert.ok(Number.isInteger(alias.levelTerm), 'missing level clamps to 1');
  assert.ok(Number.isInteger(alias.damage), 'atk/def/typeEff aliases compute');
  assert.ok(!Number.isNaN(alias.damage), 'and never NaN');

  // Accuracy: missing accuracy → 255; missing roll → 0 → hit.
  const missAcc = accuracy.hit({ accuracyMod: 100, evasionMod: 100, roll: 0 });
  assert.strictEqual(missAcc.effectiveAccuracy, 255, 'missing accuracy defaults to 255');
  assert.strictEqual(missAcc.hit, true, 'roll 0 hits a default accuracy');
  const missRoll = accuracy.hit({ accuracy: 255, accuracyMod: 100, evasionMod: 100 });
  assert.strictEqual(missRoll.hit, true, 'missing roll defaults to 0 and hits');

  // Crit: missing roll → 255 → almost never a crit.
  const noRoll = crit.check({ baseSpeed: 100, roll: undefined });
  assert.strictEqual(noRoll.isCrit, false, 'missing crit roll defaults to 255');

  // Status: paralysisStop(undefined) → false (255 < 63), not true.
  assert.strictEqual(status.paralysisStop(undefined), false,
    'undefined paralysis roll coerces to 255 → not stopped');
  assert.strictEqual(status.paralysisStop(null), false,
    'null paralysis roll coerces the same way');

  // confusionTick forwards atk/def aliases into Damage.compute.
  const selfHit = status.confusionTick(
    { turnsRemaining: 3, level: 50, atk: 100, def: 100 },
    0,
  );
  assert.strictEqual(selfHit.selfHit, true, 'roll 0 self-hits');
  assert.ok(selfHit.selfDamage > 0, 'atk/def aliases produce self-hit damage');
});
