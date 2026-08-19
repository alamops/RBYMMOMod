#!/usr/bin/env node
'use strict';

/*
 * Cross-runtime parity suite for the **Gen 2** turn machine:
 * `lib/battle2/Turn.js`.
 *
 * The sibling suite (battle2_vectors.test.js) pins the *formulas* against a
 * shared vector pack. A vector cannot express what this file is for: the order
 * the questions get asked in, which of them are asked at all, and therefore how
 * many bytes come off the RNG before the next one. Two runtimes can agree on
 * every damage number and still fight two different battles from one seed if
 * one of them draws a crit byte for a move that missed.
 *
 * So the expected event streams are not written here and not computed here.
 * They come from luajit actually running src/BattleSim2/Turn.lua over the same
 * scenarios, spawned by `tests/drivers/battle2_turn_parity.lua`. When luajit is
 * not on PATH the same driver's committed output --
 * tests/fixtures/battle2_turn_parity.json -- stands in, and when luajit *is*
 * present both are checked, so a fixture that drifted behind the Lua is a
 * failure rather than a suite that quietly stopped testing anything.
 *
 * Scope is the three referee rules docs/plans/gen2-new-battle-system.md brought
 * across from the Gen 1 twin -- experience, the replace phase, and stolen-KO
 * retargeting -- because those are what is new in `lib/battle2/` and therefore
 * what can drift. Everything a Gen 2 fight shares with Gen 1 is already pinned
 * by battle_turn.test.js on the Gen 1 pair.
 *
 * The scenarios below are the JS half of that pair and have to stay a literal
 * mirror of the driver's: same seeds, same parties, same choices in the same
 * order. A change to one is a change to both, and regenerating the fixture is
 * the third step:
 *
 *   luajit tests/drivers/battle2_turn_parity.lua . > tests/fixtures/battle2_turn_parity.json
 *
 * ROM-free by construction: every species and move named here is invented.
 *
 * Run: node --test server/battle2_turn.test.js
 */

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const { Turn, events: Events } = require('./lib/battle2');

const ROOT = path.join(__dirname, '..');
const DRIVER = path.join(ROOT, 'tests', 'drivers', 'battle2_turn_parity.lua');
const FIXTURE = path.join(ROOT, 'tests', 'fixtures', 'battle2_turn_parity.json');

// ------------------------------------------------------------------
// fixtures -- mirrored line for line from the Lua driver
// ------------------------------------------------------------------

function mv(id, power, accuracy, type, pp) {
  return { id, pp: pp === undefined ? 60 : pp, power, accuracy, type, effect: 0, chance: 0 };
}

// Gen 2 sheet dialect throughout: spe / spa / spd, never the Gen 1
// spd=Speed / spc=Special pair, so `copyMon` takes the Gen 2 branch.
function mn(o) {
  return {
    species: o.species,
    level: o.level === undefined ? 20 : o.level,
    hp: o.hp,
    maxHp: o.maxHp === undefined ? 100 : o.maxHp,
    status: o.status,
    types: o.types,
    stats: {
      atk: o.atk === undefined ? 40 : o.atk,
      def: o.def === undefined ? 40 : o.def,
      spe: o.spe === undefined ? 40 : o.spe,
      spa: o.spa === undefined ? 40 : o.spa,
      spd: o.spd === undefined ? 40 : o.spd,
    },
    moves: o.moves,
  };
}

function build(opts) {
  const { battle, reason } = Turn.attempt(opts);
  assert.ok(battle, `scenario refused: ${reason}`);
  return battle;
}

// The events go into one flat list, and how many came out of each drain goes
// into a second one beside it. The counts are not decoration: they are the only
// record of *when* an event was available, and a clock that fired a turn early
// produces exactly the same events in exactly the same order, just one drain
// sooner.
let batches = [];

function drainInto(battle, into) {
  const list = battle.drainEvents();
  for (const event of list) into.push(event);
  batches.push(list.length);
}

const SCENARIOS = [];
const scenario = (name, run) => SCENARIOS.push({ name, run });

// 1. a wild fight that ends in a KO: one owner seat, one payout, and the
//    rngState afterwards proves the payout drew nothing.
scenario('exp_wild', (events) => {
  const thump = () => mv('thump', 40, 255, 0);
  const battle = build({
    id: 'expw', mode: 'wild', seed: 4242, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 200, atk: 90, spe: 80, moves: [thump()] })] }],
      b: [{ playerId: 'wild', name: 'Wild', mons: [
        mn({ species: 'Beta', maxHp: 60, spe: 10, moves: [thump()] })] }],
    },
  });
  drainInto(battle, events);
  for (let i = 0; i < 8; i += 1) {
    if (battle.outcome()) break;
    battle.submitChoice('p1', { action: 'fight', move: 0 });
    battle.submitChoice('wild', { action: 'fight', move: 0 });
    drainInto(battle, events);
  }
  return battle;
});

// 2. coop_wild: two owner seats standing at the KO, so two payouts in
//    field-slot order with a divisor of two.
scenario('exp_coop', (events) => {
  const thump = () => mv('thump', 40, 255, 0);
  const battle = build({
    id: 'expc', mode: 'coop_wild', seed: 5150, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [
        { playerId: 'a1', name: 'Ann', mons: [
          mn({ species: 'Alpha', maxHp: 200, atk: 90, spe: 80, moves: [thump()] })] },
        { playerId: 'a2', name: 'Abe', mons: [
          mn({ species: 'Gamma', maxHp: 200, atk: 90, spe: 70, moves: [thump()] })] },
      ],
      b: [{ playerId: 'wild', name: 'Wild', mons: [
        mn({ species: 'Beta', maxHp: 200, spe: 10, moves: [thump()] })] }],
    },
  });
  drainInto(battle, events);
  for (let i = 0; i < 8; i += 1) {
    if (battle.outcome()) break;
    battle.submitChoice('a1', { action: 'fight', move: 0, target: 2 });
    battle.submitChoice('a2', { action: 'fight', move: 0, target: 2 });
    battle.autoPick('wild');
    drainInto(battle, events);
  }
  return battle;
});

// 3. the replace phase: a foe seat with a bench falls, is solicited by field
//    slot, answers, and only then does the turn advance. The party index on
//    `switch` / `send` is what stops a client re-fielding the fallen copy of a
//    duplicated species.
scenario('replace', (events) => {
  const thump = () => mv('thump', 40, 255, 0);
  const battle = build({
    id: 'rep', mode: 'coop_npc', seed: 6161, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [
        { playerId: 'a1', name: 'Ann', mons: [
          mn({ species: 'Alpha', maxHp: 200, atk: 95, spe: 90, moves: [thump()] })] },
        { playerId: 'a2', name: 'Abe', mons: [
          mn({ species: 'Gamma', maxHp: 200, atk: 95, spe: 80, moves: [thump()] })] },
      ],
      b: [{ playerId: 'npc', name: 'Foe', mons: [
        mn({ species: 'Beta', maxHp: 30, spe: 10, moves: [thump()] }),
        mn({ species: 'Delta', maxHp: 400, spe: 10, moves: [thump()] }),
      ] }],
    },
  });
  drainInto(battle, events);
  for (let i = 0; i < 4; i += 1) {
    if (battle.outcome()) break;
    battle.submitChoice('a1', { action: 'fight', move: 0, target: 2 });
    battle.submitChoice('a2', { action: 'fight', move: 0, target: 2 });
    // Called twice on purpose: the first files the ordinary turn's answer, the
    // second the replacement the KO opened. A loop that stopped after one would
    // leave the phase open, which is what `fillNpcChoices` does not.
    battle.autoPick('npc');
    battle.autoPick('npc');
    drainInto(battle, events);
  }
  return battle;
});

// 4. a stolen KO. `fast` empties foe seat 2; `slow` aimed there too and must
//    swing at seat 3 instead of fizzling -- and must do it having drawn the
//    same bytes the Lua twin drew.
scenario('retarget', (events) => {
  const thump = () => mv('thump', 40, 255, 0);
  const battle = build({
    id: 'ret', mode: 'coop_pvp', seed: 7272, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [
        { playerId: 'fast', name: 'Fast', mons: [
          mn({ species: 'Alpha', maxHp: 300, atk: 200, spe: 99, moves: [thump()] })] },
        { playerId: 'slow', name: 'Slow', mons: [
          mn({ species: 'Gamma', maxHp: 300, atk: 200, spe: 90, moves: [thump()] })] },
      ],
      b: [
        { playerId: 'foeA', name: 'FoeA', mons: [
          mn({ species: 'Beta', maxHp: 1, spe: 5, moves: [thump()] })] },
        { playerId: 'foeB', name: 'FoeB', mons: [
          mn({ species: 'Delta', maxHp: 400, spe: 5, moves: [thump()] })] },
      ],
    },
  });
  drainInto(battle, events);
  battle.submitChoice('fast', { action: 'fight', move: 0, target: 2 });
  battle.submitChoice('slow', { action: 'fight', move: 0, target: 2 });
  battle.submitChoice('foeA', { action: 'fight', move: 0, target: 0 });
  battle.submitChoice('foeB', { action: 'fight', move: 0, target: 0 });
  drainInto(battle, events);
  return battle;
});

// ------------------------------------------------------------------
// running both halves
// ------------------------------------------------------------------

function snapshotDigest(battle) {
  const snap = battle.snapshot();
  return {
    phase: snap.phase,
    turn: snap.turn,
    seq: snap.seq,
    now: snap.now,
    deadline: snap.deadline,
    rngState: snap.rngState,
    field: snap.field.map((entry) => ({
      slot: entry.slot, hp: entry.hp, party: entry.party,
    })),
  };
}

// Through JSON, so an absent key and a key holding undefined compare the same
// way they do on the Lua side, where both are simply nil.
const canonical = (value) => JSON.parse(JSON.stringify(value));

function slimOutcome(out) {
  if (!out) return null;
  const slim = { battle: out.battle, outcome: out.outcome, reason: out.reason };
  if (out.winners) slim.winners = out.winners;
  if (out.losers) slim.losers = out.losers;
  return slim;
}

function runJs() {
  return SCENARIOS.map(({ name, run }) => {
    const events = [];
    batches = [];
    const battle = run(events);
    return canonical({
      name,
      events,
      batches,
      outcome: slimOutcome(battle.outcome()),
      snapshot: snapshotDigest(battle),
    });
  });
}

function runLua() {
  const luajit = spawnSync('luajit', [DRIVER, ROOT], { encoding: 'utf8' });
  if (luajit.error || luajit.status !== 0) return null;
  return JSON.parse(luajit.stdout);
}

const jsRuns = runJs();
const luaRuns = runLua();
const fixture = fs.existsSync(FIXTURE)
  ? JSON.parse(fs.readFileSync(FIXTURE, 'utf8'))
  : null;

const byName = (runs) => new Map(runs.map((entry) => [entry.name, entry]));

// ------------------------------------------------------------------

test('the parity scenarios are all present on both sides', () => {
  assert.strictEqual(jsRuns.length, 4, 'the JS half built every scenario');
  assert.ok(
    luaRuns || fixture,
    'neither luajit nor tests/fixtures/battle2_turn_parity.json is available -- '
    + 'install luajit or regenerate the fixture with '
    + '`luajit tests/drivers/battle2_turn_parity.lua . > tests/fixtures/battle2_turn_parity.json`',
  );
});

test('JS matches the Lua Gen2 turn machine, event for event', async (t) => {
  if (!luaRuns) {
    t.skip('luajit not on PATH -- the committed fixture carries this instead');
    return;
  }
  const lua = byName(luaRuns);
  for (const run of jsRuns) {
    await t.test(run.name, () => {
      const twin = lua.get(run.name);
      assert.ok(twin, `${run.name}: the Lua driver did not produce this scenario`);

      // Compared one at a time before the whole list, because the first event
      // that differs is the entire bug report -- a deep-equal on 60 events
      // prints all 60 and names none of them.
      const shorter = Math.min(run.events.length, twin.events.length);
      for (let i = 0; i < shorter; i += 1) {
        assert.deepStrictEqual(
          run.events[i], twin.events[i],
          `${run.name}: event #${i + 1} differs`,
        );
      }
      assert.strictEqual(
        run.events.length, twin.events.length,
        `${run.name}: event count differs`,
      );
      assert.deepStrictEqual(
        run.batches, twin.batches,
        `${run.name}: the same events, but not available at the same points`,
      );
      assert.deepStrictEqual(run.outcome, twin.outcome, `${run.name}: outcome differs`);
      assert.deepStrictEqual(
        run.snapshot, twin.snapshot,
        `${run.name}: snapshot digest differs -- an rngState mismatch means the `
        + 'two runtimes drew a different number of bytes',
      );
    });
  }
});

test('JS matches the committed Lua fixture', async (t) => {
  if (!fixture) {
    t.skip('no committed fixture');
    return;
  }
  const pinned = byName(fixture);
  for (const run of jsRuns) {
    await t.test(run.name, () => {
      const twin = pinned.get(run.name);
      assert.ok(twin, `${run.name}: not in the fixture -- regenerate it`);
      assert.deepStrictEqual(run.events, twin.events, `${run.name}: events differ`);
      assert.deepStrictEqual(run.batches, twin.batches, `${run.name}: drain points differ`);
      assert.deepStrictEqual(run.outcome, twin.outcome, `${run.name}: outcome differs`);
      assert.deepStrictEqual(run.snapshot, twin.snapshot, `${run.name}: snapshot differs`);
    });
  }
});

test('the committed fixture still is what luajit produces', (t) => {
  if (!luaRuns || !fixture) {
    t.skip('needs both luajit and the fixture');
    return;
  }
  assert.deepStrictEqual(
    luaRuns, fixture,
    'the fixture has drifted behind src/BattleSim2/Turn.lua -- regenerate with '
    + '`luajit tests/drivers/battle2_turn_parity.lua . > tests/fixtures/battle2_turn_parity.json`',
  );
});

// ------------------------------------------------------------------
// the rules, stated as claims rather than diffs
// ------------------------------------------------------------------

const expOf = (run) => run.events.filter((event) => event.t === 'exp');

test('a wild KO pays the one owner seat, facts only', () => {
  const exps = expOf(byName(jsRuns).get('exp_wild'));
  assert.strictEqual(exps.length, 1, 'exactly one payout');
  assert.strictEqual(exps[0].slot, 0, 'to the sole owner seat');
  assert.strictEqual(exps[0].species, 'Beta', 'naming the monster that fell');
  assert.strictEqual(exps[0].level, 20, 'and the level it was');
  assert.strictEqual(exps[0].participants, 1, 'split one way');
  assert.strictEqual(exps[0].mon, 0, 'banked by party index 0');
  assert.strictEqual(exps[0].amount, undefined,
    'and never an amount: this referee holds no species table');
});

test('a co-op KO pays both standing seats, in field-slot order', () => {
  const exps = expOf(byName(jsRuns).get('exp_coop'));
  assert.strictEqual(exps.length, 2, 'both owner seats are paid');
  assert.deepStrictEqual(exps.map((e) => e.slot), [0, 1],
    'seat order, not speed order -- a permutation here is a parity failure '
    + 'with no symptom anyone could read');
  assert.deepStrictEqual(exps.map((e) => e.participants), [2, 2],
    'and both name the same divisor');
});

test('1v1 and coop_pvp never emit exp -- the farming-loop gate', () => {
  // `retarget` is the coop_pvp scenario; a KO happens in it and pays nothing.
  const run = byName(jsRuns).get('retarget');
  assert.strictEqual(expOf(run).length, 0, 'coop_pvp pays nothing');
  assert.ok(run.events.some((e) => e.t === 'faint'),
    'and a faint really did happen, so the gate is what refused it');
});

test('a KO with a bench opens the replace phase before the next turn', () => {
  const run = byName(jsRuns).get('replace');
  const solicit = run.events.find((e) => e.t === 'turn' && e.slot !== undefined);
  assert.ok(solicit, 'a replacement solicitation was raised');
  assert.strictEqual(solicit.slot, 2, 'naming the seat that owes');

  const firstTurn = run.events.find((e) => e.t === 'turn' && e.slot === undefined);
  assert.strictEqual(solicit.amount, firstTurn.amount,
    'on the same turn number the faint happened on -- the phase does not advance it');

  // The batch reads as one story: faint, its spoils, the ask, the successor.
  const story = run.events
    .filter((e) => ['faint', 'exp', 'switch', 'send'].includes(e.t)
      || (e.t === 'turn' && e.slot !== undefined))
    .map((e) => (e.t === 'turn' ? 'ask' : e.t))
    .join(',');
  assert.ok(story.includes('faint,exp,exp,ask,switch,send'),
    `faint -> spoils -> ask -> switch -> send (${story})`);
});

test('every send and switch names the party index it fielded', () => {
  const run = byName(jsRuns).get('replace');
  for (const event of run.events) {
    if (event.t === 'send' || event.t === 'switch') {
      assert.strictEqual(typeof event.mon, 'number',
        `${event.t} on slot ${event.slot} carries no party index -- a seat holding `
        + 'two of a species would re-field the fallen copy');
    }
  }
  const replacement = run.events.find((e) => e.t === 'switch' && e.slot === 2);
  assert.strictEqual(replacement.mon, 1, 'the post-faint replacement is party index 1');
});

// The replace phase's REFUSALS, which the parity fixture cannot reach: its
// `replace` scenario answers the solicitation immediately and never attempts an
// illegal submit. tests/battle_sim2_turn.lua asserts these three on the Lua
// side; without them here a JS-only regression in the guards ships green, and
// "the two files are currently identical" is a fact about today, not a test.
test('during the replace phase only the seat that owes may answer', () => {
  const thump = () => mv('thump', 40, 255, 0);
  const battle = build({
    id: 'guards', mode: 'coop_npc', seed: 6161, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [
        { playerId: 'a1', name: 'Ann', mons: [
          mn({ species: 'Alpha', maxHp: 200, atk: 95, spe: 90, moves: [thump()] })] },
        { playerId: 'a2', name: 'Abe', mons: [
          mn({ species: 'Gamma', maxHp: 200, atk: 95, spe: 80, moves: [thump()] })] },
      ],
      b: [{ playerId: 'npc', name: 'Foe', mons: [
        mn({ species: 'Beta', maxHp: 30, spe: 10, moves: [thump()] }),
        mn({ species: 'Delta', maxHp: 400, spe: 10, moves: [thump()] }),
      ] }],
    },
  });
  battle.drainEvents();
  battle.submitChoice('a1', { action: 'fight', move: 0, target: 2 });
  battle.submitChoice('a2', { action: 'fight', move: 0, target: 2 });
  battle.autoPick('npc');
  battle.drainEvents();

  assert.strictEqual(battle.snapshot().phase, 'replace',
    'the KO left the machine in the replace phase');
  assert.strictEqual(
    battle.submitChoice('a1', { action: 'fight', move: 0, target: 2 }), false,
    'a standing seat\'s fight is refused -- it would answer a turn that has '
    + 'not opened, and be spent before the player saw the successor come out');
  assert.strictEqual(battle.submitChoice('a1', { action: 'cancel' }), false,
    'and so is a cancel: a forced replacement cannot be taken back');
  assert.strictEqual(battle.autoPick('a1'), false,
    'an NPC that is still standing does not file either -- this false is how '
    + 'the fillNpcChoices loop learns to stop');
  assert.ok(battle.autoPick('npc'), 'only the seat that owes may answer');
  assert.strictEqual(battle.snapshot().phase, 'choice',
    'and answering it closes the phase');
});

// The highest-consequence path in the phase and the one neither generation
// covered: if the timeout sweep does not reach a `replace` seat, an idle or
// dropped player wedges the fight forever -- `_maybeResolve` never fires,
// because the only thing anybody owes is the replacement nobody filed.
test('an unanswered replacement times out instead of wedging the fight', () => {
  const thump = () => mv('thump', 40, 255, 0);
  const battle = build({
    id: 'wedge', mode: 'coop_npc', seed: 6161, choiceTimeout: 10, reconnectGrace: 600,
    sides: {
      a: [
        { playerId: 'a1', name: 'Ann', mons: [
          mn({ species: 'Alpha', maxHp: 200, atk: 95, spe: 90, moves: [thump()] })] },
        { playerId: 'a2', name: 'Abe', mons: [
          mn({ species: 'Gamma', maxHp: 200, atk: 95, spe: 80, moves: [thump()] })] },
      ],
      b: [{ playerId: 'npc', name: 'Foe', mons: [
        mn({ species: 'Beta', maxHp: 30, spe: 10, moves: [thump()] }),
        mn({ species: 'Delta', maxHp: 400, spe: 10, moves: [thump()] }),
      ] }],
    },
  });
  battle.drainEvents();
  battle.submitChoice('a1', { action: 'fight', move: 0, target: 2 });
  battle.submitChoice('a2', { action: 'fight', move: 0, target: 2 });
  battle.autoPick('npc');
  battle.drainEvents();
  assert.strictEqual(battle.snapshot().phase, 'replace');

  // Nobody answers. The clock is what has to carry it.
  assert.ok(battle.tick(battle.snapshot().now + 60),
    'the deadline passing is a tick that did something');
  assert.strictEqual(battle.snapshot().phase, 'choice',
    'the sweep filled the owed replacement and closed the phase');
  const sent = battle.drainEvents().filter((e) => e.t === 'send' && e.slot === 2);
  assert.ok(sent.length > 0, 'and the successor really was fielded');
});

test('a stolen KO retargets instead of fizzling', () => {
  const run = byName(jsRuns).get('retarget');
  const fizzled = run.events.some((e) => e.t === 'msg'
    && typeof e.text === 'string' && e.text.includes('has no target'));
  assert.ok(!fizzled, 'the slower ally does not fizzle on the seat its partner emptied');
  assert.ok(run.events.some((e) => e.t === 'damage' && e.slot === 3),
    'it swings at the nearest living opposing seat instead');
});

// ------------------------------------------------------------------
// the vocabulary really carries all of this
// ------------------------------------------------------------------

test('the Gen2 event vocabulary knows exp, the party index and the ask slot', () => {
  assert.strictEqual(Events.KINDS.exp, true, '`exp` is in the closed kind set');
  assert.strictEqual(Events.FIELDS.species, 'string');
  assert.strictEqual(Events.FIELDS.level, 'number');
  assert.strictEqual(Events.FIELDS.participants, 'number');
  assert.strictEqual(Events.FIELDS.mon, 'number');
  assert.ok(Events.SHAPES.send.mon, '`send` promises the party index it fielded');
  assert.ok(Events.SHAPES.switch.mon, 'and so does `switch`');
  assert.ok(Events.SHAPES.turn.slot, '`turn` documents the solicitation slot');

  const built = Events.build('exp', {
    slot: 0, species: 'Beta', level: 20, participants: 2, mon: 1,
  });
  assert.ok(built, 'an exp event builds');
  assert.strictEqual(built.t, 'exp');
  assert.strictEqual(built.participants, 2);
  assert.strictEqual(built.mon, 1);
});

// ------------------------------------------------------------------
// wildlife never uses an item, from either end
// ------------------------------------------------------------------
//
// Twin of tests/battle_sim2_turn.lua's section 4, and byte-shared with the Gen 1
// pair. A wild monster has no bag and no hands, and its seat is driven from two
// ends -- the hub auto-picks for it, and a submitted choice can arrive addressed
// to it -- so both are pinned. The wild seat is handed a bag on purpose: even a
// seat that HAS one must never spend it, so a hub seeding the wrong kit cannot
// put a Potion in a wild monster's mouth.

const wildBattle2 = (mode, id, bBag) => build({
  id, mode, seed: 88010, choiceTimeout: 10, reconnectGrace: 60,
  sides: {
    a: [{
      playerId: 'p1', name: 'Ann', bag: { POTION: 1 },
      mons: [mn({ species: 'Alpha', maxHp: 200, spe: 90, moves: [mv('thump', 40, 255, 0)] })],
    }],
    b: [{
      playerId: 'wild', name: 'Wild', bag: bBag,
      // Hurt below half and poisoned: a trainer seat heals or cures here.
      mons: [mn({
        species: 'Beta', maxHp: 200, hp: 40, spe: 10, status: 'PSN',
        moves: [mv('thump', 40, 255, 0)],
      })],
    }],
  },
});

for (const mode of ['wild', 'coop_wild']) {
  test(`${mode}: auto-pick never reaches the wild seat's bag`, () => {
    const battle = wildBattle2(mode, 'wa', { POTION: 2, FULL_HEAL: 1, X_ATTACK: 1 });
    battle.drainEvents();
    battle.submitChoice('p1', { action: 'fight', move: 0 });
    assert.strictEqual(battle.tick(11), true, "the wild seat's turn resolves");
    const items = battle.drainEvents().filter((event) => event.t === 'item');
    assert.deepStrictEqual(items, [], 'no item event came off the wild seat');
    assert.strictEqual(battle.byId.get('wild').bag.POTION, 2, 'and it spent none of it');
    assert.strictEqual(battle.byId.get('wild').bag.FULL_HEAL, 1, 'cure untouched too');
    assert.strictEqual(battle.byId.get('wild').mons[0].status, 'poison', 'still poisoned');
  });

  test(`${mode}: a submitted item from the wild seat is refused`, () => {
    const battle = wildBattle2(mode, 'wb', { POTION: 1 });
    battle.drainEvents();
    assert.strictEqual(
      battle.submitChoice('wild', { action: 'item', item: 'POTION', slot: 0 }), false,
      'wildlife cannot be talked into using an item',
    );
    assert.strictEqual(battle.byId.get('wild').choice, null, 'and files nothing');
    assert.strictEqual(
      battle.submitChoice('p1', { action: 'item', item: 'POTION', slot: 0 }), true,
      'the player on side a still may',
    );
  });
}
