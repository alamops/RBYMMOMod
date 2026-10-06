#!/usr/bin/env node
'use strict';

/*
 * lib/battle2/AiSwitch.js: the computer's switches and items on Gold / Silver /
 * Crystal (AI_SwitchOrTryItem, CheckAbleToSwitch,
 * FindMonInOTPartyToSwitchIntoBattle), routine by routine.
 *
 * The Node half of tests/battle_sim2_ai_switch.lua: the same scenarios, the
 * same scripted bytes, the same expectations, section for section -- a case
 * that passes on one side and fails on the other is the drift the twin rule
 * exists to catch. The Lua suite's header explains the fixtures; the
 * reasoning behind each expectation is cited in src/BattleSim2/AiSwitch.lua.
 *
 * Synthetic throughout: NORMAL / FIGHTING / GHOST (the names the Foresight
 * rows key on) and three invented types on an invented chart.
 *
 * Run: node --test server/battle2_ai_switch.test.js
 */

const test = require('node:test');
const assert = require('node:assert');

const Turn = require('./lib/battle2/Turn.js');
const Effects = require('./lib/battle2/Effects.js');
const A = require('./lib/battle2/AiSwitch.js');

const eq = (actual, expected, what) => assert.strictEqual(actual, expected, what);

function said(decision) {
  if (decision === null || decision === undefined) return 'nil';
  if (decision.action === 'switch') return `switch ${decision.slot}`;
  return `item ${decision.item} ${decision.trainerSlot}`;
}

// ------------------------------------------------------------------
// fixtures
// ------------------------------------------------------------------

const TYPE_IDS = ['NORMAL', 'FIGHTING', 'GHOST', 'ALPHA', 'BETA', 'GAMMA'];
const [N, F, G, AL, BE, GA] = [0, 1, 2, 3, 4, 5];

function chartOf(cells) {
  const rows = TYPE_IDS.map(() => TYPE_IDS.map(() => 100));
  for (const [atk, def, pct] of cells) rows[atk][def] = pct;
  return rows;
}

const CHART = chartOf([
  [AL, BE, 200], [AL, GA, 50], [AL, G, 0],
  [BE, AL, 200], [BE, GA, 50],
  [GA, BE, 200], [GA, AL, 50],
  [N, G, 0], [F, G, 0], [F, N, 200],
]);

function mv(o = {}) {
  return {
    id: o.id || 'hit', pp: 10, power: o.power !== undefined ? o.power : 40,
    accuracy: 255, type: o.type !== undefined ? o.type : N, effect: 0, chance: 0,
  };
}

function mn(o = {}) {
  return {
    species: o.species || 'Mon', level: o.level !== undefined ? o.level : 20,
    hp: o.hp, maxHp: o.maxHp !== undefined ? o.maxHp : 100, types: o.types || [N],
    status: o.status, statusTurns: o.statusTurns, confusion: o.confusion,
    stats: { atk: o.atk || 40, def: 40, spe: o.spe || 40, spa: 40, spd: 40 },
    moves: o.moves || [mv()],
  };
}

function fight(o) {
  const battle = Turn.create({
    id: 'ai', mode: o.mode || 'coop_npc', seed: 7, chart: o.chart || CHART,
    typeIds: TYPE_IDS,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', family: o.family || 'gs',
        mons: o.foe || [mn({ species: 'Foe', types: o.foeTypes || [N] })] }],
      b: [{ playerId: 'npc', name: 'LASS AMY', mons: o.npc || [mn()] }],
    },
  });
  if (!battle) throw new Error('fixture refused');
  battle.drainEvents();
  const npc = battle.byId.get('npc');
  const foe = battle.byId.get('p1');
  if (o.active) npc.active = o.active;
  for (const [k, v] of Object.entries(o.fields || {})) npc[k] = v;
  const mon = npc.mons[npc.active - 1];
  for (const [k, v] of Object.entries(o.mon || {})) mon[k] = v;
  const foeMon = foe.mons[foe.active - 1];
  for (const [k, v] of Object.entries(o.foeMon || {})) foeMon[k] = v;
  for (const [k, v] of Object.entries(o.battle || {})) battle[k] = v;
  const queue = [...(o.bytes || [])];
  const taken = { n: 0, over: false };
  battle.rng = {
    byte() {
      taken.n += 1;
      if (queue.length === 0) { taken.over = true; return 0; }
      return queue.shift();
    },
    state() { return 0; },
  };
  return { battle, npc, foe, mon, foeMon, taken };
}

const decide = (f) => A.switchOrTryItem(f.battle, f.npc, f.foe);
const viewOf = (f) => A.viewOf(f.battle, f.npc, f.foe);
const kinds = (events) => events.map((e) => e.t).join(',');

const LOW = { hp: 20 };

// ------------------------------------------------------------------
// 1. the guards before any check
// ------------------------------------------------------------------

test('AI_SwitchOrTryItem guards', () => {
  let f = fight({ mode: 'wild', npc: [mn({ hp: 20 })], fields: { trainerItems: ['POTION'] } });
  eq(said(decide(f)), 'nil', 'wild: no item');
  eq(f.taken.n, 0, '...and no byte');

  f = fight({ mode: '1v1', npc: [mn({ hp: 20 })], fields: { trainerItems: ['POTION'] } });
  eq(said(decide(f)), 'nil', 'link (1v1)');

  f = fight({ npc: [mn({ hp: 20 })], fields: { trainerItems: ['POTION'] } });
  eq(said(A.switchOrTryItem(f.battle, f.foe, f.npc)), 'nil', "the player's own seat");
  eq(said(decide(f)), 'item POTION 1', "...the computer's is");

  for (const [name, lock] of [
    ['SUBSTATUS_RECHARGE', { mustRecharge: true }],
    ['SUBSTATUS_CHARGED', { charging: { moveIndex: 1, effect: 0 } }],
    ['SUBSTATUS_BIDE', { bide: { turns: 1, stored: 0, moveIndex: 1 } }],
    ['SUBSTATUS_RAMPAGE', { thrashing: { turns: 1, moveIndex: 1 } }],
    ['SUBSTATUS_ROLLOUT', { rollout: { active: true, moveIndex: 1 } }],
  ]) {
    f = fight({ npc: [mn({ hp: 20 })], mon: lock, fields: { trainerItems: ['POTION'] } });
    eq(said(decide(f)), 'nil', `CheckEnemyLockedIn (${name})`);
  }

  f = fight({ npc: [mn({ hp: 20 })], fields: { trainerItems: ['POTION'] },
    mon: { thrashing: { turns: 0, moveIndex: 1 }, rollout: { active: false } } });
  eq(said(decide(f)), 'item POTION 1', 'a finished rampage or a stopped ROLLOUT is no lock-in');

  const perishParty = () => [mn({ species: 'Lead', hp: 20 }), mn({ species: 'Back' })];
  f = fight({ npc: perishParty(),
    fields: { trainerItems: ['POTION'], itemSwitch: A.SWITCH_OFTEN }, mon: { perish: 1 } });
  f.foeMon.meanLook = { slot: f.npc.slot };
  eq(said(decide(f)), 'item POTION 1', "held by the player's MEAN LOOK");
  eq(f.taken.n, 0, '...no switch byte');

  f = fight({ npc: perishParty(),
    fields: { trainerItems: ['POTION'], itemSwitch: A.SWITCH_OFTEN },
    mon: { perish: 1, trapped: { turns: 2 } } });
  eq(said(decide(f)), 'item POTION 1', 'wrapped');
  eq(f.taken.n, 0, '...no switch byte');

  f = fight({ npc: perishParty(), fields: { itemSwitch: A.SWITCH_OFTEN },
    mon: { perish: 1, trapped: { turns: 0 } }, bytes: [10] });
  eq(said(decide(f)), 'switch 2', 'a wrap count of 0 holds nothing');
});

// ------------------------------------------------------------------
// 2. CheckPlayerMoveTypeMatchups, and the false assumption under it
// ------------------------------------------------------------------

function score(o) {
  o.fields = o.fields || {};
  o.fields.aiMove = o.fields.aiMove || mv({ type: AL });
  const f = fight(o);
  return A.checkPlayerMoveTypeMatchups(viewOf(f));
}

test('CheckPlayerMoveTypeMatchups', () => {
  eq(score({ npc: [mn({ types: [BE] })], foeTypes: [N] }), 9, 'unknown moves, single-typed player');
  eq(score({ npc: [mn({ types: [BE] })], foeTypes: [N, F] }), 8, '...dual-typed: twice');
  eq(score({ npc: [mn({ types: [BE] })], foeTypes: [N], foeMon: { usedMoves: [mv({ type: N })] } }), 9,
    'used move, super effective');
  eq(score({ npc: [mn({ types: [N] })], foeTypes: [N], foeMon: { usedMoves: [mv({ type: BE })] } }), 10,
    'neutral; the used move type never read');
  eq(score({ npc: [mn({ types: [GA] })], foeTypes: [N], foeMon: { usedMoves: [mv()] } }), 11,
    'not very effective');
  eq(score({ npc: [mn({ types: [G] })], foeTypes: [N], foeMon: { usedMoves: [mv()] } }), 12, 'immune');
  eq(score({ npc: [mn({ types: [BE] })], foeTypes: [N],
    foeMon: { usedMoves: [mv({ power: 0 }), mv({ power: 0 })] } }), 12, 'no power at all');
  eq(score({ npc: [mn({ types: [BE] })], foeTypes: [N],
    foe: [mn({ types: [N], moves: [mv({ id: 'jab', power: 40 })] })],
    foeMon: { usedMoves: ['jab'] } }), 9, 'used move by id');
  eq(score({ npc: [mn({ types: [BE] })], foeTypes: [N], foeMon: { usedMoves: ['gone'] } }), 12,
    '...unknown id');
  eq(score({ npc: [mn({ types: [BE] })], foeTypes: [N, F], foeMon: { usedMoves: [''] } }), 8,
    '...empty id ends the list');
  eq(score({ npc: [mn({ types: [N], moves: [mv({ power: 0 })] })], foeTypes: [N] }), 8,
    'no damaging enemy move');
  eq(score({ npc: [mn({ types: [N] })], foeTypes: [GA] }), 9, 'enemy moves not very effective');
  eq(score({ npc: [mn({ types: [N] })], foeTypes: [BE] }), 11, 'enemy moves super effective');
  eq(score({ npc: [mn({ types: [N] })], foeTypes: [G] }), 8, 'player immune');

  eq(A.typeMatchup(fight({}).battle, N, [G], false), 0, 'NORMAL on GHOST');
  eq(A.typeMatchup(fight({}).battle, N, [G], true), 10, '...identified');
  eq(score({ npc: [mn({ types: [G] })], foeTypes: [N], fields: { aiMove: mv({ type: N }) },
    foeMon: { usedMoves: [mv()] } }), 12, 'NORMAL struct on GHOST');
  eq(score({ npc: [mn({ types: [G] })], foeTypes: [N], fields: { aiMove: mv({ type: N }) },
    foeMon: { usedMoves: [mv()], identified: true } }), 10, '...player identified');

  const f = fight({ npc: [mn({ moves: [mv({ type: GA }), mv({ type: BE })] })] });
  f.npc.choice = { action: 'fight', move: 2 };
  eq(viewOf(f).moveType, BE, 'no aiMove: the filed choice');
  f.npc.choice = { action: 'fight', move: 1, struggle: true };
  eq(viewOf(f).moveType, N, '...Struggle');
  f.npc.choice = null;
  eq(viewOf(f).moveType, N, '...nothing filed');
  f.npc.aiMove = mv({ type: GA });
  eq(viewOf(f).moveType, GA, 'aiMove wins');
});

// ------------------------------------------------------------------
// 3. the bench helpers
// ------------------------------------------------------------------

test('the bench helpers', () => {
  eq(A.quarterValue(100), 25, 'quarterValue(100)');
  eq(A.quarterValue(101), 537, 'quarterValue(101)');
  eq(A.quarterValue(102), 281, 'quarterValue(102)');
  eq(A.quarterValue(103), 793, 'quarterValue(103)');
  eq(A.quarterValue(256), 1024, 'quarterValue(256)');
  eq(A.quarterValue(0), 0, 'quarterValue(0)');

  let f = fight({ npc: [
    mn({ species: 'Lead' }),
    mn({ hp: 100, maxHp: 300 }),
    mn({ hp: 101, maxHp: 300 }),
    mn({ hp: 75, maxHp: 80 }),
    mn({ hp: 0, maxHp: 1 }),
  ] });
  eq(A.findEnemyMonsWithAtLeastQuarterMaxHP(viewOf(f), 0x3e), 0x08 + 0x04, 'by the bug value');
  f.battle.family = 'crystal';
  eq(A.findEnemyMonsWithAtLeastQuarterMaxHP(viewOf(f), 0x3e), 0x08 + 0x04, '...Crystal alike');

  const party = () => [mn({ types: [BE] }), mn({ types: [GA] }), mn({ types: [GA] })];
  f = fight({ npc: party(), family: 'crystal', fields: { aiMove: mv({ type: AL }) } });
  eq(A.findEnemyMonsThatResistPlayer(viewOf(f), 0x3f), 0x10 + 0x08, 'Crystal: own species');
  f = fight({ npc: party(), family: 'gs', fields: { aiMove: mv({ type: AL }) } });
  eq(A.findEnemyMonsThatResistPlayer(viewOf(f), 0x38), 0x08, 'Gold: one species behind');
  eq(A.findEnemyMonsThatResistPlayer(viewOf(f), 0x3f), 0x08 + 0x04, '...the pass past the party');
  f.npc.countSpeciesTypes = [GA];
  eq(A.findEnemyMonsThatResistPlayer(viewOf(f), 0x38), 0x20 + 0x08, '...slot 1 by countSpeciesTypes');
  f = fight({ npc: party(), family: 'crystal', fields: { aiMove: mv({ type: AL }) }, mon: { types: [GA] } });
  eq(A.findEnemyMonsThatResistPlayer(viewOf(f), 0x3f), 0x10 + 0x08, 'base types, not CONVERSION');

  const se = () => [mn(), mn({ moves: [mv({ power: 0 })] }), mn(), mn()];
  f = fight({ npc: se(), foeTypes: [BE], fields: { aiMove: mv({ type: AL }) } });
  let view = viewOf(f);
  eq(A.findEnemyMonsWithASuperEffectiveMove(view, 0x1c), 2, 'super effective: e = 2');
  eq(view.score, 2, '...first slot with power');
  f = fight({ npc: se(), foeTypes: [N], fields: { aiMove: mv({ type: AL }) } });
  view = viewOf(f);
  eq(A.findEnemyMonsWithASuperEffectiveMove(view, 0x1c), 1, 'neutral: e = 1');
  eq(view.score, 2, '...same slot');
  f = fight({ npc: se(), foeTypes: [GA], fields: { aiMove: mv({ type: AL }) } });
  view = viewOf(f);
  eq(A.findEnemyMonsWithASuperEffectiveMove(view, 0x1c), 0, 'not very effective: e = 0');
  eq(view.score, 0xff, '...$ff');
});

// ------------------------------------------------------------------
// 4. CheckAbleToSwitch
// ------------------------------------------------------------------

function param(o) {
  const f = fight(o);
  return A.checkAbleToSwitch(viewOf(f));
}

const NO_LAST = () => ({
  npc: [mn({ moves: [mv({ power: 0 })] }), mn({ hp: 101, maxHp: 300, types: [GA] })],
  foeTypes: [BE], fields: { aiMove: mv({ type: AL }) },
});

function immune(o) {
  o.npc = o.npc || [mn({ moves: [mv({ power: 0 })] }), mn({ types: [G], hp: 101, maxHp: 300 })];
  o.foeTypes = o.foeTypes || [BE];
  o.fields = { aiMove: mv({ type: AL }) };
  o.foeMon = o.foeMon || { lastCounterMove: mv() };
  return param(o);
}

test('CheckAbleToSwitch', () => {
  eq(param({ npc: [mn()], mon: { perish: 1 } }), 0, 'party of one');
  eq(param({ npc: [mn(), mn({ hp: 0 })], mon: { perish: 1 } }), 0, 'nobody living on the bench');
  eq(param({ npc: [mn(), mn({ hp: 0 }), mn()], mon: { perish: 1 } }), 0x32, 'perish 1, first living');
  eq(param({ npc: [mn({ types: [GA] }),
    mn({ hp: 101, maxHp: 300, types: [GA], moves: [mv({ power: 0 })] }),
    mn({ hp: 103, maxHp: 300, types: [GA] })],
  foeTypes: [BE], mon: { perish: 1 }, fields: { aiMove: mv({ type: AL }) } }), 0x32, 'perish 1, SE slot');
  eq(param({ npc: [mn({ types: [GA] }), mn({ hp: 101, maxHp: 300, types: [GA] }),
    mn({ hp: 103, maxHp: 300, types: [GA] })],
  foeTypes: [BE], mon: { perish: 2 }, fields: { aiMove: mv({ type: AL }) } }), 0, 'perish 2');
  eq(param({ npc: [mn(), mn()], foeTypes: [BE], fields: { aiMove: mv({ type: AL }) } }), 0, 'score 11');
  eq(param(NO_LAST()), 0x11, 'no last counter move: $11');
  eq(param({ npc: [mn({ moves: [mv({ power: 0 })] }), mn({ hp: 100, maxHp: 300, types: [GA] })],
    foeTypes: [BE], fields: { aiMove: mv({ type: AL }) } }), 0, '...100 HP fails the quarter test');

  eq(immune({}), 0x21, 'immune: $20');
  eq(immune({ npc: [mn({ types: [BE] }), mn({ types: [G] })] }), 0x11, '...recheck 10: $10');
  eq(immune({ npc: [mn({ types: [BE] }), mn({ types: [G] })], foeTypes: [N] }), 0x11, 'neutral, score 9');
  eq(immune({ npc: [mn(), mn({ types: [G] })], foeTypes: [N] }), 0, '...score 10');
  eq(immune({ npc: [mn(), mn({ types: [G] })], foeTypes: [GA] }), 0, '$ff');
  eq(immune({ foeMon: { lastCounterMove: mv({ power: 0 }) } }), 0x11, 'counter move with no power');
});

// ------------------------------------------------------------------
// 5. the switch bands
// ------------------------------------------------------------------

function band30(flags, byte) {
  const f = fight({ npc: [mn(), mn({ hp: 0 }), mn()], mon: { perish: 1 },
    fields: { itemSwitch: flags }, bytes: [byte] });
  return [said(decide(f)), f.taken.n];
}
function band10(flags, byte) {
  const o = NO_LAST();
  o.fields.itemSwitch = flags;
  o.bytes = [byte];
  const f = fight(o);
  return [said(decide(f)), f.taken.n];
}
function band20(flags, byte) {
  const f = fight({ npc: [mn({ moves: [mv({ power: 0 })] }), mn({ types: [G] })],
    foeTypes: [BE], foeMon: { lastCounterMove: mv() },
    fields: { aiMove: mv({ type: AL }), itemSwitch: flags }, bytes: [byte] });
  return [said(decide(f)), f.taken.n];
}

test('SwitchOften / Rarely / Sometimes', () => {
  for (const [name, flags, run, take, stay] of [
    ['OFTEN', A.SWITCH_OFTEN, band10, 127, 128], ['OFTEN', A.SWITCH_OFTEN, band20, 199, 200],
    ['RARELY', A.SWITCH_RARELY, band10, 19, 20], ['RARELY', A.SWITCH_RARELY, band20, 29, 30],
    ['SOMETIMES', A.SWITCH_SOMETIMES, band10, 49, 50], ['SOMETIMES', A.SWITCH_SOMETIMES, band20, 127, 128],
  ]) {
    const [d, n] = run(flags, take);
    eq(d, 'switch 2', `${name}: byte ${take} switches`);
    eq(n, 1, '...one byte');
    eq(run(flags, stay)[0], 'nil', `${name}: byte ${stay} stays`);
  }
  for (const [name, flags, stay, take] of [
    ['OFTEN', A.SWITCH_OFTEN, 9, 10], ['RARELY', A.SWITCH_RARELY, 199, 200],
    ['SOMETIMES', A.SWITCH_SOMETIMES, 49, 50],
  ]) {
    eq(band30(flags, stay)[0], 'nil', `${name} $30: ${stay} stays`);
    eq(band30(flags, take)[0], 'switch 3', `${name} $30: ${take} switches`);
  }
  eq(band30(A.SWITCH_OFTEN + A.SWITCH_RARELY, 10)[0], 'switch 3', 'OFTEN before RARELY');
  eq(band30(A.SWITCH_RARELY + A.SWITCH_SOMETIMES, 50)[0], 'nil', 'RARELY before SOMETIMES');
  const [d, n] = band30(0x0100, 10);
  eq(d, 'nil', 'low byte only');
  eq(n, 0, '...no byte');

  const f = fight({ npc: [mn({ hp: 40 }), mn({ hp: 0 }), mn()], mon: { perish: 1 },
    fields: { itemSwitch: A.SWITCH_OFTEN, trainerItems: ['POTION'] }, bytes: [9, 127] });
  eq(said(decide(f)), 'item POTION 1', 'a stay goes on to the item check');
  eq(f.taken.n, 2, '...two bytes');
});

// ------------------------------------------------------------------
// 6. AI_TryItem
// ------------------------------------------------------------------

function item(o) {
  o.fields = o.fields || {};
  o.fields.trainerItems = o.fields.trainerItems || [o.id || 'POTION'];
  o.fields.itemSwitch = o.flags || 0;
  const f = fight(o);
  const d = decide(f);
  return [said(d), f.taken.n, f, d];
}
const heal = (flags, hp, bytes) => item({ flags, mon: { hp }, bytes });

test('AI_TryItem', () => {
  eq(item({ fields: { trainerItems: [] }, mon: LOW })[0], 'nil', 'no items');
  eq(item({ fields: { trainerItems: ['NO_ITEM', 'NO_ITEM'] }, mon: LOW })[0], 'nil', 'two NO_ITEMs');
  let [d, n] = item({ npc: [mn({ level: 20 }), mn({ level: 21 })], mon: LOW });
  eq(d, 'nil', 'not the highest level');
  eq(n, 0, '...no byte');
  eq(item({ npc: [mn({ level: 21 }), mn({ level: 21, hp: 0 })], mon: LOW })[0], 'item POTION 1', 'a tie');

  eq(heal(A.CONTEXT_USE, 51)[0], 'nil', 'CONTEXT above half');
  eq(heal(A.CONTEXT_USE, 50, [49])[0], 'item POTION 1', 'CONTEXT at half: 49');
  eq(heal(A.CONTEXT_USE, 40, [50])[0], 'nil', '...50');
  [d, n] = heal(A.CONTEXT_USE, 25);
  eq(d, 'item POTION 1', 'CONTEXT at a quarter');
  eq(n, 0, '...no byte');
  eq(heal(A.UNKNOWN_USE, 40)[0], 'nil', 'UNKNOWN above a quarter');
  eq(heal(A.UNKNOWN_USE, 25, [49])[0], 'nil', 'UNKNOWN: 49');
  eq(heal(A.UNKNOWN_USE, 25, [50])[0], 'item POTION 1', 'UNKNOWN: 50');
  eq(heal(0, 25)[0], 'item POTION 1', 'none at a quarter');
  eq(heal(0, 40, [127])[0], 'item POTION 1', 'none: 127');
  eq(heal(0, 40, [128])[0], 'nil', 'none: 128');
  eq(heal(0, 51)[0], 'nil', 'none above half');
  for (const id of ['MAX_POTION', 'HYPER_POTION', 'SUPER_POTION']) {
    eq(item({ id, mon: { hp: 25 } })[0], `item ${id} 1`, id);
  }

  eq(item({ id: 'FULL_RESTORE', mon: { hp: 25 } })[0], 'item FULL_RESTORE 1', 'FULL RESTORE heal');
  eq(item({ id: 'FULL_RESTORE', mon: { status: 'sleep' } })[0], 'nil', 'no CONTEXT: status not asked');
  eq(item({ id: 'FULL_RESTORE', flags: A.CONTEXT_USE, mon: { status: 'sleep', statusTurns: 2 } })[0],
    'item FULL_RESTORE 1', 'CONTEXT: sleep');
  eq(item({ id: 'FULL_RESTORE', flags: A.CONTEXT_USE, mon: { status: 'poison' } })[0], 'nil', 'poison');

  [d, n] = item({ id: 'FULL_HEAL', flags: A.ALWAYS_USE });
  eq(d, 'nil', 'FULL HEAL no status');
  eq(n, 0, '...no byte');
  eq(item({ id: 'FULL_HEAL', flags: A.ALWAYS_USE, mon: { status: 'poison' } })[0], 'item FULL_HEAL 1', 'ALWAYS');
  eq(item({ id: 'FULL_HEAL', mon: { status: 'burn' }, bytes: [49] })[0], 'item FULL_HEAL 1', 'none: 49');
  eq(item({ id: 'FULL_HEAL', mon: { status: 'burn' }, bytes: [50] })[0], 'nil', 'none: 50');
  eq(item({ id: 'FULL_HEAL', flags: A.CONTEXT_USE, mon: { status: 'freeze' } })[0], 'item FULL_HEAL 1', 'freeze');
  [d, n] = item({ id: 'FULL_HEAL', flags: A.CONTEXT_USE, mon: { status: 'toxic', toxicCounter: 4 } });
  eq(d, 'nil', 'toxic count 3');
  eq(n, 0, '...no byte');
  eq(item({ id: 'FULL_HEAL', flags: A.CONTEXT_USE, mon: { status: 'toxic', toxicCounter: 5 },
    bytes: [127] })[0], 'item FULL_HEAL 1', 'toxic count 4: 127');
  [d, n] = item({ id: 'FULL_HEAL', flags: A.CONTEXT_USE, mon: { status: 'toxic', toxicCounter: 5 },
    bytes: [128] });
  eq(d, 'nil', 'toxic count 4: 128');
  eq(n, 1, '...one byte');
  eq(item({ id: 'FULL_HEAL', flags: A.CONTEXT_USE,
    mon: { status: 'burn', toxicLatent: true, toxicCounter: 9 }, bytes: [0] })[0],
  'item FULL_HEAL 1', 'SUBSTATUS_TOXIC under a burn');

  for (const id of ['X_ACCURACY', 'GUARD_SPEC', 'DIRE_HIT', 'X_ATTACK', 'X_DEFEND', 'X_SPEED', 'X_SPECIAL']) {
    [d, n] = item({ id, flags: A.ALWAYS_USE });
    eq(d, `item ${id} 1`, `${id}: ALWAYS first turn`);
    eq(n, 0, '...no byte');
  }
  eq(item({ id: 'X_ATTACK', flags: A.CONTEXT_USE, bytes: [127] })[0], 'nil', 'CONTEXT: 127');
  [d, n] = item({ id: 'X_ATTACK', flags: A.CONTEXT_USE, bytes: [128] });
  eq(d, 'item X_ATTACK 1', 'CONTEXT: 128');
  eq(n, 1, '...one byte');
  [d, n] = item({ id: 'X_ATTACK', bytes: [128, 127] });
  eq(d, 'nil', 'none: 128, 127');
  eq(n, 2, '...two bytes');
  eq(item({ id: 'X_ATTACK', bytes: [128, 128] })[0], 'item X_ATTACK 1', 'none: 128, 128');
  [d, n] = item({ id: 'X_ATTACK', mon: { turnsTaken: 1 } });
  eq(d, 'nil', 'later turn without ALWAYS');
  eq(n, 0, '...no byte');
  eq(item({ id: 'X_ATTACK', flags: A.ALWAYS_USE, mon: { turnsTaken: 3 }, bytes: [49] })[0],
    'item X_ATTACK 1', 'later, ALWAYS: 49');
  eq(item({ id: 'X_ATTACK', flags: A.ALWAYS_USE, mon: { turnsTaken: 3 }, bytes: [50] })[0], 'nil', '...50');

  eq(item({ fields: { trainerItems: ['X_ATTACK', 'POTION'] }, flags: A.ALWAYS_USE, mon: LOW })[0],
    'item POTION 2', 'the table order');

  const [bug, , f, decision] = item({ fields: { trainerItems: ['NO_ITEM', 'POTION'], baseReward: 0x26 },
    flags: A.ALWAYS_USE, mon: { status: 'poison' } });
  eq(bug, 'item FULL_HEAL 3', 'the base reward read as FULL HEAL');
  A.useItem(f.battle, f.npc, decision);
  eq(f.npc.baseReward, 0, '...cleared');
  eq(f.npc.trainerItems[1], 'POTION', '...the POTION stays');
  eq(f.mon.status, null, '...the FULL HEAL works');
  eq(item({ fields: { trainerItems: ['FULL_HEAL', 'POTION'] }, flags: A.ALWAYS_USE,
    mon: { status: 'poison' } })[0], 'nil', 'item 1 never looked at again');
  eq(item({ fields: { trainerItems: ['POTION', 'FULL_HEAL'] }, flags: A.ALWAYS_USE,
    mon: { status: 'poison' } })[0], 'item FULL_HEAL 2', '...the other way round');
  eq(item({ fields: { trainerItems: ['NO_ITEM', 'MAX_POTION'], baseReward: 0x12 },
    flags: A.CONTEXT_USE, mon: { hp: 40 }, bytes: [50, 49] })[0], 'item POTION 3', 'base reward as POTION');
  eq(item({ fields: { trainerItems: [0x12] }, mon: LOW })[0], 'item POTION 1', 'by number');
  eq(A.itemByte('RARE_CANDY') !== 0, true, 'unlisted is not NO_ITEM');
  eq(item({ fields: { trainerItems: ['RARE_CANDY'], baseReward: 0x12 }, mon: LOW })[0], 'nil', '...no row');
});

// ------------------------------------------------------------------
// 7. the effect
// ------------------------------------------------------------------

function use(o) {
  const [, , f, d] = item(o);
  f.battle.drainEvents();
  const applied = A.useItem(f.battle, f.npc, d);
  return [f, f.battle.drainEvents(), applied];
}

test('EnemyUsed* and the tail', () => {
  let [f, events, applied] = use({ npc: [mn({ species: 'Ace', hp: 10 })] });
  eq(applied, true, 'applies');
  eq(kinds(events), 'msg,item,drain', 'POTION');
  eq(events[0].text, 'LASS AMY\nused POTION\non Ace!', 'the line');
  eq(events[2].amount, 20, '...20 HP');
  eq(f.mon.hp, 30, '...on the monster');
  eq(f.npc.trainerItems[0], 'NO_ITEM', '...slot cleared');

  [f, events] = use({ id: 'HYPER_POTION', mon: { hp: 25 } });
  eq(f.mon.hp, 100, 'HYPER POTION');
  eq(events[2].amount, 75, '...what it healed');
  [f] = use({ id: 'SUPER_POTION', mon: { hp: 10 } });
  eq(f.mon.hp, 60, 'SUPER POTION');
  [f, events] = use({ id: 'MAX_POTION', mon: { hp: 1 } });
  eq(f.mon.hp, 100, 'MAX POTION');
  eq(kinds(events), 'msg,item,drain', '...the same three');

  f = fight({ npc: [mn({ species: 'Ace', hp: 25, status: 'BRN', confusion: 3 })],
    fields: { trainerItems: ['FULL_RESTORE'] } });
  f.mon.nightmare = true;
  const burnt = Effects.currentStats(f.mon, null).atk;
  let d = decide(f);
  f.battle.drainEvents();
  A.useItem(f.battle, f.npc, d);
  events = f.battle.drainEvents();
  eq(kinds(events), 'msg,item,drain,status,status', 'FULL RESTORE');
  eq(events[4].confused, 0, '...confusion');
  eq(f.mon.hp, 100, '...HP');
  eq(f.mon.status, null, '...burn gone');
  eq(f.mon.confusion, 0, '...confusion gone');
  eq(Effects.currentStats(f.mon, null).atk, burnt, '...Attack cut stays');
  eq(f.mon.nightmare, true, '...nightmare stays');

  f = fight({ npc: [mn({ species: 'Ace', status: 'PAR', confusion: 2, spe: 80 })],
    fields: { trainerItems: ['FULL_HEAL'], itemSwitch: A.ALWAYS_USE } });
  f.mon.toxicLatent = true;
  const slow = Effects.currentStats(f.mon, null).spe;
  d = decide(f);
  f.battle.drainEvents();
  A.useItem(f.battle, f.npc, d);
  events = f.battle.drainEvents();
  eq(kinds(events), 'item,msg,status', 'FULL HEAL');
  eq(events[1].text, 'LASS AMY\nused FULL HEAL\non Ace!', '...line');
  eq(f.mon.status, null, '...paralysis gone');
  eq(f.mon.toxicLatent, null, '...SUBSTATUS_TOXIC off');
  eq(f.mon.confusion, 2, '...confusion left');
  eq(Effects.currentStats(f.mon, null).spe, slow, '...Speed cut stays');

  for (const [id, flag, label] of [['X_ACCURACY', 'xAccuracy', 'X ACCURACY'],
    ['GUARD_SPEC', 'mist', 'GUARD SPEC.'], ['DIRE_HIT', 'focusEnergy', 'DIRE HIT']]) {
    [f, events] = use({ id, flags: A.ALWAYS_USE, npc: [mn({ species: 'Ace' })] });
    eq(kinds(events), 'item,msg', `${id}: sound, line`);
    eq(events[1].text, `LASS AMY\nused ${label}\non Ace!`, `...${label}`);
    eq(f.mon[flag], true, '...its bit');
  }

  [f, events] = use({ id: 'X_SPECIAL', flags: A.ALWAYS_USE });
  eq(kinds(events), 'msg,item,stat', 'X SPECIAL');
  eq(f.mon.stages.spa, 1, '...SP_ATTACK');
  eq(events[2].stage, 1, '...stage');
  [f] = use({ id: 'X_SPEED', flags: A.ALWAYS_USE, mon: {} });
  eq(f.mon.stages.spe, 1, 'X SPEED');
  [f] = use({ id: 'X_DEFEND', flags: A.ALWAYS_USE });
  eq(f.mon.stages.def, 1, 'X DEFEND');

  const [, , g, xd] = item({ id: 'X_ATTACK', flags: A.ALWAYS_USE });
  g.mon.stages.atk = 6;
  g.battle.drainEvents();
  A.useItem(g.battle, g.npc, xd);
  events = g.battle.drainEvents();
  eq(kinds(events), 'msg,item', 'X ATTACK at +6');
  eq(g.mon.stages.atk, 6, '...stays');
  eq(g.battle.lastAttackMissed, true, '...wAttackMissed');

  for (const flag of ['lastAttackMissed', 'lastEffectFailed']) {
    [f, events] = use({ id: 'X_ATTACK', flags: A.ALWAYS_USE, battle: { [flag]: true } });
    eq(f.mon.stages.atk, 0, `${flag}: no raise`);
    eq(kinds(events), 'msg,item', '...nothing more');
  }

  for (const family of ['gs', 'crystal']) {
    [f] = use({ family, mon: { hp: 10, furyCutter: 3, protectCount: 2, rageCounter: 2,
      raging: true, lastCounterMove: mv({ id: 'last' }) } });
    eq(f.mon.furyCutter, 0, `${family}: Fury Cutter`);
    eq(f.mon.protectCount, 0, `${family}: Protect`);
    eq(f.mon.rageCounter, 0, `${family}: Rage count`);
    eq(f.mon.raging, false, `${family}: SUBSTATUS_RAGE`);
    if (family === 'crystal') {
      eq(f.mon.lastCounterMove, null, 'crystal clears wLastEnemyCounterMove');
    } else {
      eq(f.mon.lastCounterMove !== null && f.mon.lastCounterMove !== undefined, true, 'gs keeps it');
    }
  }

  f = fight({});
  eq(A.useItem(f.battle, f.npc, { action: 'item', item: 'RARE_CANDY' }), false, 'unlisted id');
  eq(A.useItem(f.battle, f.npc, null), false, 'no decision');
  eq(A.withdrewLine(f.npc, f.mon), 'LASS AMY\nwithdrew\nMon!', '_EnemyWithdrewText');
});

// ------------------------------------------------------------------
// 8. FindMonInOTPartyToSwitchIntoBattle
// ------------------------------------------------------------------

function successor(o) {
  o.foeTypes = o.foeTypes || [BE];
  const f = fight(o);
  f.mon.hp = 0;
  const r = A.replacement(f.battle, f.npc, f.foe);
  return [r ? r.slot : null, f.taken.n, r];
}

test('FindMonInOTPartyToSwitchIntoBattle', () => {
  const [slot, n, r] = successor({ npc: [mn(), mn({ types: [AL] }),
    mn({ types: [GA], moves: [mv({ type: GA })] })] });
  eq(slot, 3, 'enemy SE move wins');
  eq(n, 0, '...no byte');
  eq(r.action, 'switch', '...a switch choice');
  eq(r.playerMoveType, BE, '...wPlayerMoveStruct type');
  eq(successor({ npc: [mn(), mn({ types: [AL], moves: [mv({ type: AL })] }),
    mn({ types: [GA], moves: [mv({ type: GA })] })] })[0], 3, 'cancelled loses');
  eq(successor({ npc: [mn(), mn({ types: [AL], moves: [mv({ type: AL })] }), mn()] })[0], 2,
    'cancelled reads neutral');
  eq(successor({ npc: [mn(), mn({ types: [AL] }), mn({ types: [N] })] })[0], 3, 'first not discouraged');
  eq(successor({ npc: [mn(), mn(), mn({ moves: [mv({ type: GA, power: 0 })] })] })[0], 3, 'no power still counts');
  for (const family of ['crystal', 'gs']) {
    const [s, k] = successor({ family, npc: [mn(), mn({ types: [AL] }), mn({ types: [AL] })], bytes: [11, 8, 10] });
    eq(s, 3, `${family}: random`);
    eq(k, 3, `${family}: three bytes`);
  }
  const f = fight({ npc: [mn(), mn({ types: [BE] })], foe: [mn({ types: [AL, GA] })] });
  f.mon.hp = 0;
  eq(A.replacement(f.battle, f.npc, f.foe).playerMoveType, AL, 'type 1 SE stops there');
  eq(successor({ npc: [mn(), mn({ hp: 0 })] })[0], null, 'no living bench');
});

// ------------------------------------------------------------------
// 9. UpdateUsedMoves
// ------------------------------------------------------------------

test('UpdateUsedMoves', () => {
  const mon = {};
  for (const id of ['a', 'b', 'a', 'c', 'd']) A.recordUsedMove(mon, mv({ id }));
  eq(mon.usedMoves.map((row) => row.id).join(','), 'a,b,c,d', 'once each');
  A.recordUsedMove(mon, mv({ id: 'e' }));
  eq(mon.usedMoves.map((row) => row.id).join(','), 'b,c,d,e', 'shift');
  A.recordUsedMove(mon, mv({ id: 'c' }));
  eq(mon.usedMoves.length, 4, 'already there');
});
