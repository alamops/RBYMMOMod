#!/usr/bin/env node
'use strict';

/*
 * Parity suite for the hub's Gen 3 battle formulas: `lib/battle3/`.
 *
 * Every case comes out of tests/fixtures/battle_sim3_vectors.json, which
 * tests/battle_sim3_vectors.lua drives against the Lua twin in src/BattleSim3.
 * That shared file is the whole point: a mediated Gen 3 fight can be resolved
 * by a dedicated Node hub or by an in-game host running the Lua sim, and the
 * same fight has to come out the same way on both.
 *
 * The expected numbers are never computed here. They are read from the
 * fixture and compared key for key, exactly as the Lua runner does: only the
 * keys `out` states are asserted (an explicit null meaning "absent"), and
 * array-valued keys compare element by element. The section runners below are
 * a literal mirror of the Lua runner's `each(...)` blocks.
 *
 * ROM-free by construction: every stat, power and chart row is invented.
 *
 * Run: node --test server/battle3_vectors.test.js
 */

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const Sim = require('./lib/battle3');

const {
  Damage, Types, Crit, Accuracy, Status, Catch, Items, Field, Rng, Effects, Safari,
} = Sim;

const FIXTURE = path.join(__dirname, '..', 'tests', 'fixtures', 'battle_sim3_vectors.json');
const vectors = JSON.parse(fs.readFileSync(FIXTURE, 'utf8'));
const CHART = vectors.typeTable;

// null in the fixture means "absent", as NULL does in the Lua reader.
function orNil(value) {
  return value === null ? undefined : value;
}

// A fixture object with nulls stripped (Damage.battler reads a missing key as
// absent), recursively -- the Lua runner's `clean`.
function clean(value) {
  if (value === null || typeof value !== 'object') return orNil(value);
  if (Array.isArray(value)) return value.map((v) => clean(v));
  const out = {};
  for (const [k, v] of Object.entries(value)) {
    if (v !== null) out[k] = clean(v);
  }
  return out;
}

function same(expected, actual) {
  if (expected === null) return actual === null || actual === undefined;
  if (Array.isArray(expected)) {
    if (!Array.isArray(actual) || expected.length !== actual.length) return false;
    return expected.every((e, i) => same(e, actual[i]));
  }
  return expected === actual;
}

let checked = 0;

function match(id, out, actual) {
  for (const key of Object.keys(out).sort()) {
    checked += 1;
    assert.ok(
      same(out[key], actual[key]),
      `${id}: ${key} expected ${JSON.stringify(out[key])}, got ${JSON.stringify(actual[key])}`,
    );
  }
}

// One subtest per case, the way the Lua runner walks a section.
function section(name, run) {
  test(`${name} vectors`, async (t) => {
    const cases = vectors[name];
    assert.ok(Array.isArray(cases) && cases.length > 0, `${name}: no cases in the fixture`);
    for (const c of cases) {
      await t.test(c.id, () => {
        match(c.id, c.out, run(c.in, c.kind));
      });
    }
  });
}

test('fixture pack is the one this suite was written against', () => {
  assert.strictEqual(vectors.version, 1, 'fixture version bumped -- reread the notes before touching this');
  assert.strictEqual(vectors.generation, 3, 'this suite is Gen 3 only');
  assert.ok(Array.isArray(CHART) && CHART.length % 3 === 0, 'the ordered chart is a flat triple list');
});

section('rng', (input) => {
  const r = Rng.new(input.seed);
  const values = input.draws.map((d) => r.roll(d[0], d[1]));
  return { values, state: r.state(), count: r.draws };
});

section('types', (input) => {
  const [dmg, flags, product] = Types.typeCalc(CHART, input.atk, input.def1, orNil(input.def2),
    orNil(input.dmg), input.foresight);
  return {
    dmg, super: flags.super, notVery: flags.notVery, immune: flags.immune, product,
  };
});

section('damage', (input) => {
  const opts = clean(input.opts);
  opts.typeTable = CHART;
  if (opts.rolls) opts.rng = Rng.scripted(opts.rolls);
  const [d, info] = Damage.calc(Damage.battler(clean(input.attacker)),
    Damage.battler(clean(input.defender)), clean(input.move), opts);
  return {
    damage: d,
    critical: info.critical === true,
    effectiveness: info.effectiveness,
    moveType: info.moveType,
    power: info.power,
    stab: info.stab === true,
    failed: info.failed,
    status: info.status,
  };
});

section('base', (input) => {
  const opts = clean(input.opts);
  if (opts.specialTypes) {
    const set = {};
    for (const [k, v] of Object.entries(opts.specialTypes)) set[Number(k)] = v;
    opts.specialTypes = set;
  }
  return {
    damage: Damage.base(Damage.battler(clean(input.attacker)),
      Damage.battler(clean(input.defender)), clean(input.move), opts),
  };
});

section('power', (input, kind) => {
  if (kind === 'hiddenPower') {
    const [power, type] = Damage.hiddenPower(input.ivs);
    return { power, type };
  }
  if (kind === 'flail') return { power: Damage.flailPower(input.hp, input.maxHp) };
  if (kind === 'lowKick') return { power: Damage.lowKickPower(input.weight) };
  if (kind === 'magnitude') {
    const [value, power] = Damage.magnitude(input.roll);
    return { value, power };
  }
  if (kind === 'psywave') return { damage: Damage.psywave(input.level, input.roll) };
  throw new Error(`unknown power kind ${kind}`);
});

section('crit', (input, kind) => {
  if (kind === 'stage') {
    const stage = Crit.stage(Damage.battler(clean(input.attacker)), clean(input.move));
    return { stage, chance: Crit.chance(stage) };
  }
  if (kind === 'check') {
    const [isCrit, chance] = Crit.check(input.stage, input.roll);
    return { isCrit, chance };
  }
  throw new Error(`unknown crit kind ${kind}`);
});

section('accuracy', (input) => {
  const o = clean(input);
  const calc = Accuracy.calc(o.accuracy, o);
  const [hit] = Accuracy.hit(calc, o.roll);
  return { calc, hit };
});

section('speed', (input) => ({
  speed: Field.speed(Damage.battler(clean(input.battler)), orNil(input.weather),
    orNil(input.quickClawNumber)),
}));

section('order', (input) => {
  const rows = input.rows.map((r, i) => ({ pri: r.pri, spe: r.spe, order: i + 1 }));
  const rng = Rng.scripted(input.rolls);
  Field.sortRows(rows, rng, 128);
  return { order: rows.map((r) => r.order), draws: rng.draws };
});

section('status', (input, kind) => {
  if (kind === 'chip') {
    const [amount, counter] = Status.chip(input.status, input.maxHp, input.toxicCounter);
    return { amount, counter };
  }
  if (kind === 'sleepTick') {
    const [left, woke] = Status.sleepTick(input.turns, input.earlyBird);
    return { left, woke };
  }
  if (kind === 'canApply') {
    const [ok, reason] = Status.canApply(Damage.battler(clean(input.battler)), input.status,
      clean(input.ctx));
    return { ok, reason };
  }
  throw new Error(`unknown status kind ${kind}`);
});

section('catch', (input, kind) => {
  if (kind === 'multiplier') return { multiplier: Catch.multiplier(input.ball, clean(input.ctx)) };
  if (kind === 'odds') {
    return {
      odds: Catch.odds(input.ball, input.catchRate, input.hp, input.maxHp,
        orNil(input.status), clean(input.ctx)),
    };
  }
  if (kind === 'threshold') return { threshold: Catch.shakeThreshold(input.odds) };
  if (kind === 'attempt') {
    const rng = Rng.scripted(input.rolls);
    const [caught, shakes, odds] = Catch.attempt(input.ball, { mon: clean(input.mon) }, rng,
      clean(input.ctx));
    return {
      caught, shakes, odds, draws: rng.draws,
    };
  }
  throw new Error(`unknown catch kind ${kind}`);
});

section('items', (input, kind) => {
  if (kind === 'flavor') return { relation: Items.flavorRelation(input.nature, input.flavor) };
  throw new Error(`unknown items kind ${kind}`);
});

section('badges', (input) => {
  const set = Damage.badgeSet(clean(input.raw));
  if (!set) return { held: null };
  const held = [];
  for (let n = 1; n <= 8; n += 1) {
    if (set[n] === true) held.push(n);
  }
  return { held };
});

section('effects', (input, kind) => {
  if (kind === 'forbidden') return { forbidden: Effects.forbidden(input.num, input.stopAtSentinel) };
  if (kind === 'handles') {
    const handled = [];
    for (let id = input.from; id <= input.to; id += 1) handled.push(Effects.handles(id));
    return { handled };
  }
  throw new Error(`unknown effects kind ${kind}`);
});

section('safari', (input, kind) => {
  if (kind === 'catchFactor') return { factor: Safari.catchFactor(input.catchRate) };
  if (kind === 'escapeFactor') return { factor: Safari.escapeFactor(input.fleeRate) };
  if (kind === 'ballCatchRate') return { catchRate: Safari.ballCatchRate(input.factor) };
  if (kind === 'fleeRate') return { rate: Safari.fleeRate(clean(input.state)) };
  if (kind === 'bait' || kind === 'rock') {
    const s = clean(input.state);
    Safari[kind](s, input.roll);
    return { bait: s.bait, rock: s.rock, catchFactor: s.catchFactor };
  }
  if (kind === 'watch') {
    const s = clean(input.state);
    const reaction = Safari.watch(s);
    return {
      reaction, rock: s.rock, bait: s.bait, catchFactor: s.catchFactor,
    };
  }
  if (kind === 'goNear') {
    const s = clean(input.state);
    const closer = Safari.goNear(s);
    return {
      closer, goNear: s.goNear, catchFactor: s.catchFactor, escapeFactor: s.escapeFactor,
    };
  }
  if (kind === 'block') {
    const s = clean(input.state);
    Safari.block(s, input.verdict);
    return { escapeFactor: s.escapeFactor, pkblCounter: s.pkblCounter, pokeblockThrows: s.pokeblockThrows };
  }
  throw new Error(`unknown safari kind ${kind}`);
});

// ------------------------------------------------------------------
// Rng properties the fixture cannot state as values (the Lua runner's four)
// ------------------------------------------------------------------

test('rng: same seed, same stream', () => {
  const a = Rng.new(12345);
  const b = Rng.new(12345);
  for (let i = 0; i < 64; i += 1) assert.strictEqual(a.roll(0, 255), b.roll(0, 255));
});

test('rng: the damage roll stays in its band', () => {
  const e = Rng.new(99);
  for (let i = 0; i < 512; i += 1) {
    const r = e.damageRoll();
    assert.ok(r >= Damage.ROLL_MIN && r <= Damage.ROLL_MAX, `roll ${r} outside 85..100`);
  }
});

test('rng: state restores', () => {
  const live = Rng.new(7);
  for (let i = 0; i < 10; i += 1) live.roll(0, 99);
  const restored = Rng.new(0).setState(live.state());
  assert.strictEqual(live.roll(0, 65535), restored.roll(0, 65535));
});

test('rng: a coin is not a rota', () => {
  const c = Rng.new(1);
  let prev = null;
  let runs = 0;
  for (let i = 0; i < 256; i += 1) {
    const v = c.roll(0, 1);
    if (v === prev) runs += 1;
    prev = v;
  }
  assert.ok(runs > 64, `only ${runs} repeats in 256 flips`);
});

test('every stated key was checked', () => {
  let expected = 0;
  for (const name of ['rng', 'types', 'damage', 'base', 'power', 'crit', 'accuracy', 'speed',
    'order', 'status', 'catch', 'items', 'badges', 'effects', 'safari']) {
    for (const c of vectors[name]) expected += Object.keys(c.out).length;
  }
  assert.strictEqual(checked, expected, 'a section skipped some of its cases');
});
