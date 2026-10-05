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

const {
  damage, accuracy, crit, status, Rng, Effects, Items,
} = require('./lib/battle2');

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
  for (const group of ['damage', 'accuracy', 'crit', 'status', 'badgeStats', 'badgeTypes',
    'stages', 'battleStats', 'truncate', 'items', 'gold']) {
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
  // compute() reads the pair it is handed; the cart's fold to a byte is
  // TruncateHL_BC, which the referee runs first (truncateStats; see the
  // truncate vectors below).
  const got = damage.compute({
    level: 50, power: 40, attack: 400, defense: 200,
    physical: true, stab: false, typeEffect: [100], crit: false, roll: 100,
  });
  assert.strictEqual(got.statClamped, false, 'compute() never quarters overflow stats itself');
  assert.strictEqual(got.attack, 400);
  assert.strictEqual(got.defense, 200);
});

test('accuracy vectors', async (t) => {
  for (const v of vectors.accuracy) {
    await t.test(v.id, () => {
      const got = accuracy.hit(v.in);
      got.draws = got.effectiveAccuracy === null ? undefined : accuracy.draws(got.effectiveAccuracy);
      expectFields(got, v.out, v.id);
    });
  }
});

test("a 255 byte hits every roll and draws none; any lower byte rolls (R2c's byte domain)", () => {
  let hits = 0;
  for (let roll = 0; roll <= 255; roll++) {
    if (accuracy.hit({ accuracy: 255, accuracyStage: 0, evasionStage: 0, roll }).hit) hits++;
  }
  assert.strictEqual(hits, 256, 'every byte hits a neutral 100% move');
  assert.strictEqual(accuracy.draws(255), false, '...and the cart draws no byte for it');
  assert.strictEqual(accuracy.draws(254), true, 'a byte of 254 is rolled');
  let always = 0;
  for (let roll = 0; roll <= 255; roll++) {
    if (accuracy.hit({ accuracy: 1, alwaysHits: true, roll }).hit) always++;
  }
  assert.strictEqual(always, 256, 'a move that cannot miss does not consult the roll');
});

test('accuracy clamps at both ends', () => {
  assert.strictEqual(accuracy.effectiveByte(200, 6, 0), 255, 'a byte past $ff is held at $ff');
  assert.strictEqual(accuracy.effectiveByte(10, -6, 6), 1, 'stacked drops floor at 1, never 0');
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

// R2d: `.Tally` compares one BattleRandom byte with the level's
// CriticalHitChances row (`1 out_of N` = floor(256 / N)) -- the bytes under it
// crit, every other does not.
test('the bytes under the CriticalHitChances row are the crits', () => {
  for (let level = 0; level <= 6; level++) {
    const th = crit.threshold(level);
    assert.strictEqual(th, Math.floor(256 / crit.chance(level)), `level ${level}: 1 out_of N`);
    let crits = 0;
    for (let roll = 0; roll <= 255; roll++) {
      if (crit.check({ criticalLevel: level, roll }).isCrit) crits++;
    }
    assert.strictEqual(crits, th, `level ${level}: ${th} of the 256 bytes are a crit`);
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

test('freeze never thaws in CheckTurn; HandleDefrost thaws under 25', () => {
  let thaws = 0;
  for (let roll = 0; roll <= 255; roll++) {
    if (status.freezeTick(roll).thawed) thaws++;
  }
  assert.strictEqual(thaws, 0, 'the CheckTurn gate draws nothing and thaws nothing');
  let defrosts = 0;
  for (let byte = 0; byte <= 255; byte++) {
    if (status.defrosts(byte)) defrosts++;
  }
  assert.strictEqual(defrosts, status.DEFROST_BYTE, '`cp 10 percent`: 25 of 256');
});

test('paralysis stops on a byte under 63 (`cp 25 percent`)', () => {
  let stopped = 0;
  for (let roll = 0; roll <= 255; roll++) {
    if (status.paralysisTick(roll).fullyParalyzed) stopped++;
  }
  assert.strictEqual(stopped, 63, '63 of 256 bytes');
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

// Crystal's stat boosts (with Glacier's Sp. Def tail and the 999 cap) and the
// badge type boost's lookup, both checked against the Gold engine's own
// Battle.battleStat / badgeTypeBoost before they were written down.
test('badge stat vectors', async (t) => {
  for (const v of vectors.badgeStats) {
    await t.test(v.id, () => {
      const got = { value: Effects.badgeBoost(v.in.stat, v.in.key, v.in.badges, v.in.spa) };
      expectFields(got, v.out, v.id);
    });
  }
});

test('badge type vectors', async (t) => {
  for (const v of vectors.badgeTypes) {
    await t.test(v.id, () => {
      const got = { boosted: Effects.badgeTypeBoost(v.in.typeId, v.in.badges) };
      expectFields(got, v.out, v.id);
    });
  }
});

// The pokecrystal stat pipeline: CalcBattleStats' stage ratio and clamp,
// CalcPlayerStats' order (stage, badge, burn / paralysis), and the
// TruncateHL_BC fold the damage formula reads.
test('stage vectors', async (t) => {
  for (const v of vectors.stages) {
    await t.test(v.id, () => {
      expectFields({ value: Effects.applyStage(v.in.stat, v.in.stage) }, v.out, v.id);
    });
  }
});

test('battle stat vectors', async (t) => {
  for (const v of vectors.battleStats) {
    await t.test(v.id, () => {
      const mon = { stats: v.in.stats, stages: v.in.stages, status: v.in.status };
      expectFields({ value: Effects.battleStat(mon, v.in.key, v.in.badges) }, v.out, v.id);
    });
  }
});

test('truncate vectors', async (t) => {
  for (const v of vectors.truncate) {
    await t.test(v.id, () => {
      expectFields(damage.truncateStats(v.in.attack, v.in.defense, v.in.link), v.out, v.id);
    });
  }
});

// Gold held items and the obedience arithmetic (Items.js), one `kind` per rule
// -- the same dispatch tests/battle_sim2_vectors.lua runs.
const sheetOf = (input) => ({
  heldItem: input.heldItem, holdEffect: input.holdEffect,
  holdParam: input.holdParam, speciesId: input.speciesId,
});
const ITEM_RULES = {
  typeBoost: (input) => ({ percent: Items.typeBoostPercent(sheetOf(input), input.typeId) }),
  quickClaw: (input) => ({ fires: Items.quickClawFires(input.param, input.byte) }),
  brightPowder: (input) => ({ effective: Items.brightPowder(input.effective, input.param) }),
  speciesAttack: (input) => ({
    attack: Items.speciesAttack(sheetOf(input), input.special, input.attack),
  }),
  metalPowder: (input) => Items.metalPowder(sheetOf(input), input.attack, input.defense),
  focusBand: (input) => Items.focusBand(input.amount, input.hp),
  sixteenth: (input) => ({ value: Items.sixteenth(input.maxHp) }),
  // GetEighthMaxHP, LEECH SEED's sap: the same register walk, halved.
  eighth: (input) => ({ value: Items.eighth(input.maxHp) }),
  berryWants: (input) => ({ wants: Items.berryWants(input.hp, input.maxHp) }),
  obedienceCap: (input) => ({ cap: Items.obedienceCap(input.badges) }),
  swap: (input) => ({ value: Items.swap(input.byte) }),
  napTurns: (input) => ({ value: Items.napTurns(input.byte) }),
  kingsRockMove: (input) => ({ rolls: Items.kingsRockMove(input.effectId, input.moveId) }),
  critSpeciesItem: (input) => ({ set: Items.critSpeciesItem(input.species, input.itemId) }),
};

test('held item and obedience vectors', async (t) => {
  for (const v of vectors.items) {
    await t.test(v.id, () => {
      const rule = ITEM_RULES[v.in.kind];
      assert.ok(rule, `${v.id}: no handler for item rule ${v.in.kind}`);
      expectFields(rule(v.in), v.out, v.id);
    });
  }
});

// The wave-3 (R2c) Gold formulas, one `kind` per rule -- the same dispatch
// tests/battle_sim2_vectors.lua runs.
const byteStream = (list) => {
  let i = 0;
  return { byte: () => { i += 1; return list[i - 1] === undefined ? 0 : list[i - 1]; }, drawn: () => i };
};
const nul = (v) => (v === null || v === undefined ? undefined : v);
const GOLD_RULES = {
  happinessPower: (input) => ({ power: Effects.happinessPower(nul(input.happiness)) }),
  frustrationPower: (input) => ({ power: Effects.frustrationPower(nul(input.happiness)) }),
  hiddenPower: (input) => {
    const hp = Effects.hiddenPower(nul(input.dvs));
    return { power: hp ? hp.power : undefined, type: hp ? hp.type : undefined };
  },
  reversalPower: (input) => ({ power: Effects.reversalPower(input.hp, input.maxHp) }),
  magnitude: (input) => Effects.magnitude(input.byte),
  presentPower: (input) => ({ power: nul(Effects.presentPower(input.byte)) }),
  typeConstant: (input) => ({ value: Effects.typeConstant(nul(input.name)) }),
  protectChance: (input) => {
    const r = byteStream(input.bytes);
    return { ok: Effects.protectChance(r, input.count), drawn: r.drawn() };
  },
  tripleKickCount: (input) => {
    const r = byteStream(input.bytes);
    return { hits: Effects.tripleKickCount(r), drawn: r.drawn() };
  },
  psywave: (input) => {
    const r = byteStream(input.bytes);
    const damage = Effects.fixedDamage({ effectId: Effects.PSYWAVE, userMon: { level: input.level }, rng: r });
    return { damage, drawn: r.drawn() };
  },
  levelDamage: (input) => ({
    damage: Effects.fixedDamage({ effectId: Effects.LEVEL_DAMAGE, userMon: { level: input.level } }),
  }),
  weatherTenths: (input) => ({
    tenths: nul(Effects.weatherTenths(nul(input.weather), nul(input.typeName), input.effectId)),
  }),
  timeHealAmount: (input) => ({
    value: Effects.timeHealAmount(input.maxHp, input.timeMatches, nul(input.weather)),
  }),
  calc: (input) => ({
    damage: nul(damage.calc(input.level, input.power, input.attack, input.defense, {
      crit: input.crit, itemBoostPercent: nul(input.itemBoostPercent), carry: nul(input.carry),
    })),
  }),
  stab: (input) => {
    const got = damage.stab(input.damage, {
      weatherTenths: nul(input.weatherTenths), badgeTypeBoost: input.badgeTypeBoost,
      stab: input.stab, typeEffect: nul(input.typeEffect),
    });
    return { damage: got.damage, immune: got.immune, cReg: nul(got.cReg) };
  },
  multiply: (input) => ({ damage: damage.multiply(input.damage, input.times) }),
  doubleTimes: (input) => ({ damage: damage.doubleTimes(input.damage, input.count) }),
  applyRoll: (input) => ({
    damage: damage.applyRoll(input.damage, input.roll), varies: damage.varies(input.damage),
  }),
  quarter: (input) => ({ value: Items.quarter(input.maxHp) }),
  half: (input) => ({ value: Items.half(input.maxHp) }),
  sleepCount: (input) => {
    const r = byteStream(input.bytes);
    const target = { species: 'T', hp: 10, maxHp: 10, stages: {}, types: [0], substitute: 0 };
    Effects.applyPrimary({
      effectId: 32, rng: r, userMon: { species: 'U', maxHp: 10, stages: {} },
      targetMon: target, userFighter: { slot: 0, side: 'a' }, targetFighter: { slot: 3, side: 'b' },
    });
    return { turns: target.statusTurns, drawn: r.drawn() };
  },
  movePriority: (input) => ({
    priority: Effects.movePriority({ id: input.id, effect: input.effect, priority: nul(input.priority) }),
  }),
};

test('Gold move-effect formula vectors (R2c)', async (t) => {
  for (const v of vectors.gold) {
    await t.test(v.id, () => {
      const rule = GOLD_RULES[v.in.kind];
      assert.ok(rule, `${v.id}: no handler for gold rule ${v.in.kind}`);
      const got = rule(v.in);
      for (const key of Object.keys(v.out)) {
        const want = v.out[key];
        assert.strictEqual(got[key] === undefined ? null : got[key], want,
          `${v.id}: ${key} expected ${JSON.stringify(want)}, got ${JSON.stringify(got[key])}`);
      }
    });
  }
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

  // Contract K12: `below` and `nextInt` read the state's HIGH bits (its high
  // 16 bits modulo the span, Gen 1's rule too); the same four streams the Lua
  // vectors suite pins from the same seed.
  const stream = (seed, n, draw) => {
    const r = Rng.create(seed);
    const out = [];
    for (let i = 0; i < n; i++) out.push(draw(r));
    return out.join(',');
  };
  assert.strictEqual(stream(12345, 8, (r) => r.below(4)), '1,0,0,1,3,2,2,0', 'K12 below(4)');
  assert.strictEqual(stream(12345, 8, (r) => r.below(17)), '11,13,15,10,3,9,11,15', 'K12 below(17)');
  // R2d: DamageVariation's loop (a rotated byte, redrawn under 217).
  assert.strictEqual(stream(12345, 8, (r) => r.damageRoll()), '251,237,234,251,253,240,224,220',
    'K12 damage roll');
  assert.strictEqual(stream(12345, 8, (r) => r.nextInt(0, 99)), '37,84,96,9,39,70,98,36',
    'K12 accuracy roll');
  // The old low-bit draw: the state's two low bits cycle with period four.
  const probe = Rng.create(12345);
  const first = [];
  for (let i = 0; i < 4; i++) first.push(probe.next() % 4);
  for (let k = 0; k < 16; k++) {
    for (let i = 0; i < 4; i++) assert.strictEqual(probe.next() % 4, first[i], 'low bits cycle');
  }
});

function dummyMon2(o) {
  const opts = o || {};
  return {
    species: opts.species || 'Alpha',
    hp: opts.hp === undefined ? 100 : opts.hp,
    maxHp: opts.maxHp === undefined ? 100 : opts.maxHp,
    status: opts.status,
    types: opts.types || [0],
    stats: { atk: 40, def: 40, spe: 40, spa: 40, spd: 40 },
    stages: { atk: 0, def: 0, spe: 0, spa: 0, spd: 0, acc: 0, eva: 0 },
    moves: opts.moves || [{
      id: 'thump', name: 'THUMP', pp: 10, power: 40,
      accuracy: 255, type: 0, effect: 0, chance: 0,
    }],
    lastMoveIndex: opts.lastMoveIndex === undefined ? 1 : opts.lastMoveIndex,
    substitute: opts.substitute || 0,
  };
}

function applyPrimary2(effectId, user, target) {
  return Effects.applyPrimary({
    effectId,
    rng: { byte() { return 0; } },
    userMon: user,
    targetMon: target,
    userFighter: { slot: 1, side: 'a' },
    targetFighter: { slot: 2, side: 'b' },
    moveIndex: 1,
  });
}

test('gen2 applyPrimary fails foe-targeting effects through a substitute', () => {
  const target = dummyMon2({ species: 'Beta', substitute: 40 });
  const sleep = applyPrimary2(32, dummyMon2(), target);
  // R2d: SleepTarget's own line, DidntAffect1Text.
  assert.deepStrictEqual(sleep.messages, ["It didn't affect Beta!"], 'SLEEP_EFFECT vs substitute didn\'t affect');
  assert.strictEqual(target.status, undefined, 'SLEEP_EFFECT does not land through a substitute');

  const growlTarget = dummyMon2({ species: 'Beta', substitute: 40 });
  const growl = applyPrimary2(18, dummyMon2(), growlTarget);
  // BattleCommand_StatDown's `.DidntMiss`: a substitute is `.Failed`, whose
  // StatDownFailText is "But it failed!" (R2b), not "But nothing happened".
  assert.deepStrictEqual(growl.messages, ['But it failed'], 'Growl vs substitute fails');
  assert.strictEqual(growlTarget.stages.atk, 0, 'Growl does not drop atk behind a substitute');

  const swordsUser = dummyMon2();
  const swords = applyPrimary2(50, swordsUser, dummyMon2({ species: 'Beta', substitute: 40 }));
  assert.strictEqual(swords.nothing, false, 'Swords Dance is not nothing against a foe substitute');
  assert.strictEqual(swordsUser.stages.atk, 2, 'Swords Dance still raises the user');

  const transformUser = dummyMon2();
  const transform = applyPrimary2(57, transformUser, dummyMon2({ species: 'Beta', substitute: 40 }));
  // BattleCommand_Transform reads no substitute: only a transformed or hidden
  // target fails it (R2b).
  assert.strictEqual(transform.nothing, false, 'TRANSFORM_EFFECT copies through a substitute');
  assert.strictEqual(transformUser.transformed, true, '...and the user is transformed');

  const hazeUser = dummyMon2();
  hazeUser.stages.atk = 2;
  const hazeTarget = dummyMon2({ species: 'Beta', substitute: 40 });
  hazeTarget.stages.def = 2;
  const haze = applyPrimary2(25, hazeUser, hazeTarget);
  assert.strictEqual(haze.nothing, false, 'HAZE_EFFECT is not nothing against a substitute');
  assert.strictEqual(hazeUser.stages.atk, 0, 'HAZE_EFFECT still resets the user');
  assert.strictEqual(hazeTarget.stages.def, 0, 'HAZE_EFFECT still resets the foe');

  const exposed = dummyMon2({ species: 'Beta' });
  const lands = applyPrimary2(32, dummyMon2(), exposed);
  assert.strictEqual(lands.nothing, false, 'SLEEP_EFFECT still lands with no substitute');
  assert.strictEqual(exposed.status, 'sleep', 'SLEEP_EFFECT sets sleep when the target is exposed');
});
