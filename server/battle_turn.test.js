#!/usr/bin/env node
'use strict';

/*
 * Cross-runtime parity suite for the turn machine: `lib/battle/Turn.js`.
 *
 * The sibling suite (battle.test.js) pins the *formulas* against a shared
 * vector pack. A vector cannot express what this file is for: the order the
 * questions get asked in, which of them are asked at all, and therefore how
 * many bytes come off the RNG before the next one. Two runtimes can agree on
 * every damage number and still fight two different battles from one seed if
 * one of them draws a crit byte for a move that missed.
 *
 * So the expected event streams are not written here and not computed here.
 * They come from luajit actually running src/BattleSim/Turn.lua over the same
 * scenarios, spawned by `tests/drivers/battle_turn_parity.lua`. When luajit is
 * not on PATH the same driver's committed output --
 * tests/fixtures/battle_turn_parity.json -- stands in, and when luajit *is*
 * present both are checked, so a fixture that drifted behind the Lua is a
 * failure rather than a suite that quietly stopped testing anything.
 *
 * The scenarios below are the JS half of that pair and have to stay a literal
 * mirror of the driver's: same seeds, same parties, same choices in the same
 * order. A change to one is a change to both, and regenerating the fixture is
 * the third step:
 *
 *   luajit tests/drivers/battle_turn_parity.lua . > tests/fixtures/battle_turn_parity.json
 *
 * Regenerate whenever RNG draw sites move — item use / catch rolls are the
 * usual suspects after BattleSim item work.
 *
 * ROM-free by construction: every species, move and item named here is
 * invented, and the type charts are two-by-two integers.
 *
 * Run: node --test server/battle_turn.test.js
 */

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const { Turn, events: Events } = require('./lib/battle');

const ROOT = path.join(__dirname, '..');
const DRIVER = path.join(ROOT, 'tests', 'drivers', 'battle_turn_parity.lua');
const FIXTURE = path.join(ROOT, 'tests', 'fixtures', 'battle_turn_parity.json');

// ------------------------------------------------------------------
// fixtures -- mirrored line for line from the Lua driver
// ------------------------------------------------------------------

function mv(id, power, accuracy, type, pp) {
  return { id, pp: pp === undefined ? 60 : pp, power, accuracy, type, effect: 0, chance: 0 };
}

function mn(o) {
  const out = {
    species: o.species,
    level: o.level === undefined ? 20 : o.level,
    hp: o.hp,
    maxHp: o.maxHp === undefined ? 100 : o.maxHp,
    status: o.status,
    statusTurns: o.statusTurns,
    confusion: o.confusion,
    toxicCounter: o.toxicCounter,
    types: o.types,
    stats: {
      atk: o.atk === undefined ? 40 : o.atk,
      def: o.def === undefined ? 40 : o.def,
      spd: o.spd === undefined ? 40 : o.spd,
      spc: o.spc === undefined ? 40 : o.spc,
    },
    moves: o.moves,
  };
  if (o.catchRate !== undefined) out.catchRate = o.catchRate;
  if (o.evs) out.evs = o.evs;
  return out;
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

const fightOrReplace = (battle, playerId) => {
  const snap = battle.snapshot();
  for (const f of snap.field || []) {
    if (f.playerId === playerId) {
      if (f.mustReplace) {
        let slot = null;
        for (let i = 0; i < (f.party || []).length; i += 1) {
          if ((f.party[i] || 0) > 0) { slot = i; break; }
        }
        if (slot !== null) {
          return battle.submitChoice(playerId, { action: 'switch', slot });
        }
        return false;
      }
      break;
    }
  }
  return battle.submitChoice(playerId, { action: 'fight', move: 0 });
};

// 1. a deterministic KO fight between two equally fast sides, so the speed
//    tie-break byte is spent on every turn and faint replacement runs.
scenario('ko', (events) => {
  const thump = () => mv('thump', 40, 255, 0);
  const battle = build({
    id: 'ko', mode: '1v1', seed: 4242, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 120, atk: 60, spd: 55, moves: [thump()] }),
        mn({ species: 'Gamma', maxHp: 90, moves: [thump()] }),
      ] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 120, atk: 58, spd: 55, moves: [thump()] }),
        mn({ species: 'Delta', maxHp: 90, moves: [thump()] }),
      ] }],
    },
  });
  drainInto(battle, events);
  for (let i = 0; i < 40; i += 1) {
    if (battle.outcome()) break;
    fightOrReplace(battle, 'p1');
    fightOrReplace(battle, 'p2');
    drainInto(battle, events);
  }
  return battle;
});

// 2. a side drops and the grace runs out: forfeit, no rolls at all.
scenario('forfeit', (events) => {
  const battle = build({
    id: 'ff', mode: '1v1', seed: 7, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', moves: [mv('thump', 40, 255, 0)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', moves: [mv('thump', 40, 255, 0)] })] }],
    },
  });
  drainInto(battle, events);
  battle.disconnect('p2');
  drainInto(battle, events);
  battle.tick(30);
  drainInto(battle, events);
  battle.tick(61);
  drainInto(battle, events);
  return battle;
});

// 3. a drop that comes back inside the window, and the fight carries on.
scenario('reconnect', (events) => {
  const battle = build({
    id: 'rc', mode: '1v1', seed: 11, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 200, spd: 60,
          moves: [mv('thump', 40, 255, 0)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 200, spd: 30,
          moves: [mv('thump', 40, 255, 0)] })] }],
    },
  });
  drainInto(battle, events);
  battle.disconnect('p1');
  battle.tick(30);
  battle.reconnect('p1');
  drainInto(battle, events);
  // Past the deadline the drop started, inside the one the return restarted:
  // nothing may fire here, which is the whole claim about a resumed clock.
  battle.tick(80);
  drainInto(battle, events);
  battle.tick(120);
  drainInto(battle, events);
  battle.submitChoice('p1', { action: 'fight', move: 0 });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  drainInto(battle, events);
  return battle;
});

// 4. the awkward turn: a burn residual, a paralysis gate, confusion, a type
//    chart with both directions on it, an item, a status move, a switch and a
//    deadline that expires with one side still owing a choice.
scenario('status', (events) => {
  const battle = build({
    id: 'st', mode: '1v1', seed: 99, choiceTimeout: 10, reconnectGrace: 60,
    chart: [[100, 200, 50], [50, 100, 200], [200, 50, 100]],
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', level: 25, maxHp: 160, atk: 70, def: 45,
          spd: 50, types: [0], status: 'BRN',
          moves: [mv('thump', 40, 255, 0), mv('hex', 0, 255, 1), mv('weak', 35, 200, 2)] }),
        mn({ species: 'Gamma', maxHp: 100, spd: 30, types: [2],
          moves: [mv('thump', 40, 255, 0)] }),
      ] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', level: 25, maxHp: 150, atk: 65, def: 50,
          spd: 50, types: [1], status: 'PAR', confusion: 3,
          moves: [mv('thump', 40, 255, 1)] }),
      ] }],
    },
  });
  drainInto(battle, events);

  battle.submitChoice('p1', { action: 'fight', move: 0 });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  drainInto(battle, events);

  battle.submitChoice('p1', { action: 'item', item: 'restore' });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  drainInto(battle, events);

  battle.submitChoice('p1', { action: 'fight', move: 1 });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  drainInto(battle, events);

  battle.submitChoice('p1', { action: 'fight', move: 2 });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  drainInto(battle, events);

  battle.submitChoice('p1', { action: 'switch', slot: 1 });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  drainInto(battle, events);

  // Only one side answers; the clock spends the other one's turn.
  battle.submitChoice('p1', { action: 'fight', move: 0 });
  battle.tick(1000);
  drainInto(battle, events);

  for (let i = 0; i < 25; i += 1) {
    if (battle.outcome()) break;
    battle.submitChoice('p1', { action: 'fight', move: 0 });
    battle.submitChoice('p2', { action: 'fight', move: 0 });
    drainInto(battle, events);
  }
  return battle;
});

// 5. an immunity row, a sleep counter that runs out, and toxic stacking until
//    it kills the side carrying it.
scenario('immune', (events) => {
  const battle = build({
    id: 'im', mode: '1v1', seed: 31, choiceTimeout: 60, reconnectGrace: 60,
    chart: [[100, 0], [100, 100]],
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 200, types: [0], status: 'SLP',
          statusTurns: 2, moves: [mv('thump', 40, 255, 0)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 200, spd: 5, types: [1], status: 'TOX',
          moves: [mv('thump', 40, 255, 0)] })] }],
    },
  });
  drainInto(battle, events);
  for (let i = 0; i < 20; i += 1) {
    if (battle.outcome()) break;
    battle.submitChoice('p1', { action: 'fight', move: 0 });
    battle.submitChoice('p2', { action: 'fight', move: 0 });
    drainInto(battle, events);
  }
  return battle;
});

// 6. running: one side concedes, and then a fixture where both do.
scenario('run_one', (events) => {
  const battle = build({
    id: 'r1', mode: '1v1', seed: 5, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', moves: [mv('thump', 40, 255, 0)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', moves: [mv('thump', 40, 255, 0)] })] }],
    },
  });
  drainInto(battle, events);
  battle.submitChoice('p1', { action: 'run' });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  drainInto(battle, events);
  return battle;
});

scenario('run_both', (events) => {
  const battle = build({
    id: 'r2', mode: '1v1', seed: 5, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', moves: [mv('thump', 40, 255, 0)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', moves: [mv('thump', 40, 255, 0)] })] }],
    },
  });
  drainInto(battle, events);
  battle.submitChoice('p1', { action: 'run' });
  battle.submitChoice('p2', { action: 'run' });
  drainInto(battle, events);
  return battle;
});

// 7. the tie-break byte at its boundary, from both sides of it. The two seeds
//    are chosen so the first draw of the battle -- which in a tied 1v1 is the
//    tie-break byte itself -- is 127 and then 128, the two values that decide
//    whether the group reverses. Without these a threshold that had drifted by
//    one would still agree with the Lua on every other fixture here.
const tie = (id, seed) => (events) => {
  const battle = build({
    id, mode: '1v1', seed, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 200, atk: 60, spd: 50,
          moves: [mv('thump', 40, 255, 0)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 200, atk: 45, spd: 50,
          moves: [mv('thump', 40, 255, 0)] })] }],
    },
  });
  drainInto(battle, events);
  battle.submitChoice('p1', { action: 'fight', move: 0 });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  drainInto(battle, events);
  return battle;
};

scenario('tie_low', tie('tl', 172)); // first byte 127: side a keeps the lead
scenario('tie_high', tie('th', 41)); // first byte 128: the group reverses

// 8. a residual on each side at once, which is the only way the end-of-turn
//    order is observable: residuals run in field order, not in the speed order
//    the moves used, and with one burn in the fixture that claim is untestable.
scenario('residual_both', (events) => {
  const battle = build({
    id: 'rb', mode: '1v1', seed: 23, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 160, spd: 40, status: 'BRN',
          moves: [mv('thump', 40, 255, 0)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 160, spd: 90, status: 'PSN',
          moves: [mv('thump', 40, 255, 0)] })] }],
    },
  });
  drainInto(battle, events);
  battle.submitChoice('p1', { action: 'fight', move: 0 });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  drainInto(battle, events);
  return battle;
});

// 9. a switch and an item in the same turn, on opposite sides. Both resolve
//    before any move and neither rolls, so the only thing this fixture states
//    is the order of the two passes -- which is the only thing about them that
//    the two runtimes could get differently.
scenario('switch_item', (events) => {
  const battle = build({
    id: 'si', mode: '1v1', seed: 13, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 200, moves: [mv('thump', 40, 255, 0)] }),
        mn({ species: 'Gamma', maxHp: 180, moves: [mv('thump', 40, 255, 0)] }),
      ] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 200, moves: [mv('thump', 40, 255, 0)] })] }],
    },
  });
  drainInto(battle, events);
  battle.submitChoice('p1', { action: 'switch', slot: 1 });
  battle.submitChoice('p2', { action: 'item', item: 'restore' });
  drainInto(battle, events);
  return battle;
});

// 10. sleep with no counter on it. A party can arrive carrying SLP and no
//     number, and the two runtimes have to invent the same length or one of
//     them spends a turn the other one does not -- so this fixture states the
//     default out loud rather than leaving it to the copy step's comment.
scenario('sleep_default', (events) => {
  const battle = build({
    id: 'sd', mode: '1v1', seed: 61, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 200, spd: 60, status: 'SLP',
          moves: [mv('thump', 40, 255, 0)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 200, spd: 10,
          moves: [mv('thump', 40, 255, 0)] })] }],
    },
  });
  drainInto(battle, events);
  for (let i = 0; i < 3; i += 1) {
    if (battle.outcome()) break;
    battle.submitChoice('p1', { action: 'fight', move: 0 });
    battle.submitChoice('p2', { action: 'fight', move: 0 });
    drainInto(battle, events);
  }
  return battle;
});

// 11. PP running out, on both of the paths that can happen down. Side a spends
//     its last PP on move one and the deadline then has to auto-pick move two;
//     side b starts with nothing left anywhere and every one of its turns falls
//     through to the first move on empty PP, because a turn that cannot pick
//     has to resolve rather than hang. A port that forgot to decrement would
//     keep picking side a's first move and agree with nothing here.
scenario('pp', (events) => {
  const battle = build({
    id: 'pp', mode: '1v1', seed: 88, choiceTimeout: 10, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 300, spd: 60, moves: [
          mv('last', 40, 255, 0, 1), mv('spare', 30, 255, 0, 5),
        ] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 300, spd: 10, moves: [
          mv('empty', 20, 255, 0, 0),
        ] })] }],
    },
  });
  drainInto(battle, events);
  let clock = 0;
  for (let i = 0; i < 3; i += 1) {
    if (battle.outcome()) break;
    battle.submitChoice('p1', { action: 'fight', move: 0 });
    battle.submitChoice('p2', { action: 'fight', move: 0 });
    clock += 20;
    battle.tick(clock);
    drainInto(battle, events);
  }
  return battle;
});

// 12. a 2v2 across four field slots with every actor at the same speed, so the
//     tie-break reverses a group of four rather than a pair.
scenario('coop', (events) => {
  const thump = () => mv('thump', 40, 255, 0);
  const battle = build({
    id: 'cc', mode: 'coop_pvp', seed: 777, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [
        { playerId: 'a1', name: 'Ann', mons: [
          mn({ species: 'Alpha', maxHp: 150, spd: 50, moves: [thump()] })] },
        { playerId: 'a2', name: 'Abe', mons: [
          mn({ species: 'Gamma', maxHp: 150, spd: 50, moves: [thump()] })] },
      ],
      b: [
        { playerId: 'b1', name: 'Bob', mons: [
          mn({ species: 'Beta', maxHp: 150, spd: 50, moves: [thump()] })] },
        { playerId: 'b2', name: 'Bea', mons: [
          mn({ species: 'Delta', maxHp: 150, spd: 50, moves: [thump()] })] },
      ],
    },
  });
  drainInto(battle, events);
  for (let i = 0; i < 4; i += 1) {
    if (battle.outcome()) break;
    battle.submitChoice('a1', { action: 'fight', move: 0 });
    battle.submitChoice('a2', { action: 'fight', move: 0, target: 3 });
    battle.submitChoice('b1', { action: 'fight', move: 0 });
    battle.submitChoice('b2', { action: 'fight', move: 0, target: 1 });
    drainInto(battle, events);
  }
  battle.disconnect('b1');
  battle.tick(1000);
  drainInto(battle, events);
  return battle;
});

// 13. wild catch: MASTER_BALL ends without catch rolls; still a new mode and
//     outcome.reason / caught digest the prior fixtures never touched.
scenario('wild_master', (events) => {
  const battle = build({
    id: 'wm', mode: 'wild', seed: 51, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 200, spd: 80,
          moves: [mv('splash', 0, 255, 0)] })] }],
      b: [{ playerId: 'p2', name: 'Wild', mons: [
        mn({ species: 'Beta', maxHp: 40, hp: 10, spd: 10, catchRate: 255,
          moves: [mv('splash', 0, 255, 0)] })] }],
    },
  });
  drainInto(battle, events);
  battle.submitChoice('p1', { action: 'item', item: 'MASTER_BALL' });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  drainInto(battle, events);
  return battle;
});

// 14. wild POKE_BALL: catchAttempt draws from the RNG. Regenerate the fixture
//     whenever catch/item draw sites move.
scenario('wild_ball', (events) => {
  const battle = build({
    id: 'wb', mode: 'wild', seed: 88, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 200, spd: 80,
          moves: [mv('splash', 0, 255, 0)] })] }],
      b: [{ playerId: 'p2', name: 'Wild', mons: [
        mn({ species: 'Beta', maxHp: 100, hp: 25, spd: 10, catchRate: 45,
          moves: [mv('splash', 0, 255, 0)] })] }],
    },
  });
  drainInto(battle, events);
  battle.submitChoice('p1', { action: 'item', item: 'POKE_BALL' });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  drainInto(battle, events);
  if (!battle.outcome()) {
    battle.submitChoice('p1', { action: 'item', item: 'MASTER_BALL' });
    battle.submitChoice('p2', { action: 'fight', move: 0 });
    drainInto(battle, events);
  }
  return battle;
});

// 15. vitamins: fight-local Stat Exp on the sheet (+2560); Gen1 stat delta.
scenario('vitamin', (events) => {
  const battle = build({
    id: 'vt', mode: '1v1', seed: 3, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', level: 100, maxHp: 200, spd: 80, atk: 40,
          moves: [mv('splash', 0, 255, 0)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 200, spd: 10,
          moves: [mv('splash', 0, 255, 0)] })] }],
    },
  });
  drainInto(battle, events);
  battle.submitChoice('p1', { action: 'item', item: 'PROTEIN' });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  drainInto(battle, events);
  return battle;
});

// 16. round 5: wild-mode KO. The faint on the synthetic side b is the one
//     `_awardExp` pays for -- one `exp` event for the sole owner-slot winner
//     (slot 0), split one way (participants = 1). Looped like `ko` rather
//     than aimed at an exact turn count, so the fixture survives a damage
//     formula tweak without a hand-tuned HP number going stale.
scenario('wild_ko', (events) => {
  const thump = () => mv('thump', 40, 255, 0);
  const battle = build({
    id: 'wk', mode: 'wild', seed: 5001, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 200, atk: 90, spd: 80, moves: [thump()] })] }],
      b: [{ playerId: 'wild', name: 'Wild', mons: [
        mn({ species: 'Beta', maxHp: 60, spd: 10, moves: [thump()] })] }],
    },
  });
  drainInto(battle, events);
  for (let i = 0; i < 10; i += 1) {
    if (battle.outcome()) break;
    battle.submitChoice('p1', { action: 'fight', move: 0 });
    battle.submitChoice('wild', { action: 'fight', move: 0 });
    drainInto(battle, events);
  }
  return battle;
});

// 17. round 5: coop_wild 2v1 KO. Both owner slots are standing when the
//     wild mon falls, so `_awardExp` walks bySide.a twice -- slot 0 (a1)
//     then slot 1 (a2), field-slot order -- and each event names
//     participants = 2, the share count the split is over.
scenario('coop_wild_ko', (events) => {
  const thump = () => mv('thump', 40, 255, 0);
  const battle = build({
    id: 'cwk', mode: 'coop_wild', seed: 5002, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [
        { playerId: 'a1', name: 'Ann', mons: [
          mn({ species: 'Alpha', maxHp: 200, atk: 90, spd: 80, moves: [thump()] })] },
        { playerId: 'a2', name: 'Abe', mons: [
          mn({ species: 'Gamma', maxHp: 200, atk: 90, spd: 70, moves: [thump()] })] },
      ],
      b: [{ playerId: 'wild', name: 'Wild', mons: [
        mn({ species: 'Beta', maxHp: 200, spd: 10, moves: [thump()] })] }],
    },
  });
  drainInto(battle, events);
  for (let i = 0; i < 10; i += 1) {
    if (battle.outcome()) break;
    battle.submitChoice('a1', { action: 'fight', move: 0 });
    battle.submitChoice('a2', { action: 'fight', move: 0 });
    battle.submitChoice('wild', { action: 'fight', move: 0 });
    drainInto(battle, events);
  }
  return battle;
});

// 18. round 6: participation KO. Mon A fights, switches out alive, and its
//     replacement (mon B) lands the KO. Vanilla still owes mon A a share --
//     it was in against this foe (`_refield` / `_awardExp`) -- so the
//     referee pays both, on the one seat that owns them, each event naming
//     which party index (`mon`, 0-based) is banking it: 0 for Alpha, 1 for
//     Gamma, both against a divisor of 2.
scenario('participation_ko', (events) => {
  const thump = () => mv('thump', 40, 255, 0);
  const tap = () => mv('tap', 5, 255, 0);
  const battle = build({
    id: 'pko', mode: 'wild', seed: 101, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 200, atk: 90, spd: 80, moves: [thump()] }),
        mn({ species: 'Gamma', maxHp: 200, atk: 90, spd: 80, moves: [thump()] }),
      ] }],
      b: [{ playerId: 'wild', name: 'Wild', mons: [
        mn({ species: 'Beta', maxHp: 90, spd: 10, moves: [tap()] })] }],
    },
  });
  drainInto(battle, events);
  battle.submitChoice('p1', { action: 'fight', move: 0 });
  battle.submitChoice('wild', { action: 'fight', move: 0 });
  drainInto(battle, events);
  battle.submitChoice('p1', { action: 'switch', slot: 1 });
  battle.submitChoice('wild', { action: 'fight', move: 0 });
  drainInto(battle, events);
  for (let i = 0; i < 10; i += 1) {
    if (battle.outcome()) break;
    battle.submitChoice('p1', { action: 'fight', move: 0 });
    battle.submitChoice('wild', { action: 'fight', move: 0 });
    drainInto(battle, events);
  }
  return battle;
});

// 19. an Explosion-style double-KO in coop_wild: a1's move fells the wild
//     mon AND a1 itself in the same action. `_faint`/`_unfield` take the
//     self-KO'er out of every participation set before `_drainExp` counts
//     anyone, so a1 is neither paid nor counted, and the wild mon's one exp
//     event names only a2, participants = 1.
scenario('explode_double_ko', (events) => {
  // This file's own `mv` always writes effect=0 (its pp default lives in
  // that slot instead) -- every other scenario here is fine with that, but
  // EXPLODE is effect 7 (lib/battle/effects.js's EXPLODE_EFFECT), so `boom`
  // is built by hand rather than through the shared helper.
  const boom = () => ({ id: 'boom', pp: 60, power: 250, accuracy: 255, type: 0,
    effect: 7, chance: 0 });
  const thump = () => mv('thump', 40, 255, 0);
  const battle = build({
    id: 'xa', mode: 'coop_wild', seed: 4242, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [
        { playerId: 'a1', name: 'Ann', mons: [
          mn({ species: 'Alpha', maxHp: 200, atk: 200, spd: 90, moves: [boom()] })] },
        { playerId: 'a2', name: 'Abe', mons: [
          mn({ species: 'Gamma', maxHp: 200, atk: 40, spd: 80, moves: [thump()] })] },
      ],
      b: [{ playerId: 'wild', name: 'Wild', mons: [
        mn({ species: 'Beta', maxHp: 60, spd: 10, moves: [thump()] })] }],
    },
  });
  drainInto(battle, events);
  battle.submitChoice('a1', { action: 'fight', move: 0 });
  battle.submitChoice('a2', { action: 'fight', move: 0 });
  battle.submitChoice('wild', { action: 'fight', move: 0 });
  drainInto(battle, events);
  return battle;
});

// 20. the replacement mark: a1 KOs b1, then on the very next turn a switches
//     to a2 (still alive, a1 was never fainted) the same turn b fields b2.
//     Vanilla still marks a1 -- it was standing when b1 fell -- and the
//     send-out's own mark lands on a2 too, so when a2 finishes off b2 both
//     a1 and a2 are paid, on the one seat, divisor 2.
scenario('replacement_mark', (events) => {
  const thump = () => mv('thump', 40, 255, 0);
  const tap = () => mv('tap', 5, 255, 0);
  const battle = build({
    id: 'xd', mode: 'coop_npc', seed: 101, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 300, atk: 200, spd: 80, moves: [thump()] }),
        mn({ species: 'Gamma', maxHp: 300, atk: 200, spd: 80, moves: [thump()] }),
      ] }],
      b: [{ playerId: 'npc', name: 'Rival', mons: [
        mn({ species: 'Beta', maxHp: 40, spd: 10, moves: [tap()] }),
        mn({ species: 'Delta', maxHp: 40, spd: 10, moves: [tap()] }),
      ] }],
    },
  });
  drainInto(battle, events);
  battle.submitChoice('p1', { action: 'fight', move: 0 });
  battle.submitChoice('npc', { action: 'fight', move: 0 });
  drainInto(battle, events);
  // npc's fallen b1 owes a replacement first -- close the replace phase
  // (b fields b2) -- THEN p1 files its voluntary switch to a2 on the
  // turn-2 window that the closed replace phase opens.
  battle.submitChoice('npc', { action: 'switch', slot: 1 });
  drainInto(battle, events);
  battle.submitChoice('p1', { action: 'switch', slot: 1 });
  drainInto(battle, events);
  for (let i = 0; i < 6; i += 1) {
    if (battle.outcome()) break;
    battle.submitChoice('p1', { action: 'fight', move: 0 });
    battle.submitChoice('npc', { action: 'fight', move: 0 });
    drainInto(battle, events);
  }
  return battle;
});

// 21. dead-target retargeting (U-wave): a faster ally KOs the seat a slower
//     ally aimed at, in the same turn. `_retarget` (Turn.js's twin of
//     Turn.lua:646-690) is the only reason the slower ally's action does not
//     fizzle -- it redraws no RNG of its own, but its target resolution runs
//     on every runtime and nothing here reached it before: U1 found no
//     existing scenario landed an action on a seat that died mid-turn, which
//     is why the bug (a fizzle, "has no target", where a real attack
//     belonged) lived undetected. The retargeted hit still draws the same
//     accuracy/damage/crit bytes a same-turn attack always would, so this
//     also exercises those draws from a target the choice never named.
scenario('retarget_ko', (events) => {
  const battle = build({
    id: 'rk', mode: 'coop_pvp', seed: 4242, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [
        { playerId: 'fast', name: 'Fast', mons: [
          mn({ species: 'Alpha', maxHp: 200, atk: 200, spd: 90,
               moves: [mv('bigsmash', 150, 255, 0)] })] },
        { playerId: 'slow', name: 'Slow', mons: [
          mn({ species: 'Gamma', maxHp: 200, atk: 60, spd: 10,
               moves: [mv('tap', 40, 255, 0)] })] },
      ],
      b: [
        { playerId: 'foeA', name: 'FoeA', mons: [
          mn({ species: 'Beta', maxHp: 12, spd: 5,
               moves: [mv('thump', 40, 255, 0)] })] },
        { playerId: 'foeB', name: 'FoeB', mons: [
          mn({ species: 'Delta', maxHp: 200, spd: 4,
               moves: [mv('thump', 40, 255, 0)] })] },
      ],
    },
  });
  drainInto(battle, events);
  // Both allies aim at foeA (slot 2). Fast (spd 90) KOs it; Slow (spd 10)
  // resolves after and must retarget onto foeB (slot 3) rather than fizzle.
  battle.submitChoice('fast', { action: 'fight', move: 0, target: 2 });
  battle.submitChoice('slow', { action: 'fight', move: 0, target: 2 });
  battle.submitChoice('foeA', { action: 'fight', move: 0, target: 0 });
  battle.submitChoice('foeB', { action: 'fight', move: 0, target: 0 });
  drainInto(battle, events);
  return battle;
});

// Who the referee swings at when nobody chose. A coop_npc trainer holds two
// seats with no connection behind them, so both file their own picks through
// `autoPick` -- and until the aim stream existed, both picked "the lowest
// living foe" and hammered seat 0 for the whole fight while the second player
// was never attacked once.
//
// Six turns is enough for the spread to show, and the fixture pins the aims
// themselves rather than merely "they were not all seat 0": the aim draw is a
// second generator, and a second generator is a second way for the runtimes to
// part company. The snapshot's `rngState` is the other half of the claim -- it
// must be exactly what it was before aims spread, because the draws come off
// `aim` and never off `rng`.
scenario('coop_npc_aim', (events) => {
  const battle = build({
    id: 'aim', mode: 'coop_npc', seed: 4242, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [
        { playerId: 'p1', name: 'One', mons: [
          mn({ species: 'Alpha', maxHp: 400, spd: 10,
               moves: [mv('tap', 40, 255, 0)] })] },
        { playerId: 'p2', name: 'Two', mons: [
          mn({ species: 'Gamma', maxHp: 400, spd: 10,
               moves: [mv('tap', 40, 255, 0)] })] },
      ],
      b: [
        { playerId: 'n1', name: 'NpcA', mons: [
          mn({ species: 'Beta', maxHp: 400, spd: 90,
               moves: [mv('thump', 40, 255, 0)] })] },
        { playerId: 'n2', name: 'NpcB', mons: [
          mn({ species: 'Delta', maxHp: 400, spd: 80,
               moves: [mv('thump', 40, 255, 0)] })] },
      ],
    },
  });
  drainInto(battle, events);
  for (let i = 0; i < 6; i += 1) {
    battle.submitChoice('p1', { action: 'fight', move: 0, target: 2 });
    battle.submitChoice('p2', { action: 'fight', move: 0, target: 3 });
    battle.autoPick('n1');
    battle.autoPick('n2');
    drainInto(battle, events);
  }
  return battle;
});

// ------------------------------------------------------------------
// running both halves
// ------------------------------------------------------------------

// The Lua driver's snapshot digest, rebuilt from this side. `rngState` is the
// load-bearing field: two runtimes that drew a different number of bytes
// disagree here even when every visible event happened to line up.
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
  const slim = {
    battle: out.battle,
    outcome: out.outcome,
    reason: out.reason,
  };
  if (out.winners) slim.winners = out.winners;
  if (out.losers) slim.losers = out.losers;
  if (out.caught) {
    slim.caught = {
      species: out.caught.species,
      level: out.caught.level,
      hp: out.caught.hp,
      maxHp: out.caught.maxHp,
    };
  }
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
  assert.ok(jsRuns.length >= 21, 'the JS half built every scenario');
  assert.ok(
    luaRuns || fixture,
    'neither luajit nor tests/fixtures/battle_turn_parity.json is available -- '
    + 'install luajit or regenerate the fixture with '
    + '`luajit tests/drivers/battle_turn_parity.lua . > tests/fixtures/battle_turn_parity.json`',
  );
});

test('JS matches the Lua turn machine, event for event', async (t) => {
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
      // that differs is the entire bug report -- a deep-equal on 95 events
      // prints all 95 and names none of them.
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
    'the fixture has drifted behind src/BattleSim/Turn.lua -- regenerate with '
    + '`luajit tests/drivers/battle_turn_parity.lua . > tests/fixtures/battle_turn_parity.json`',
  );
});

// ------------------------------------------------------------------
// the deterministic KO and the forfeit, stated as claims rather than diffs
// ------------------------------------------------------------------

test('the KO fight ends, and names who won', () => {
  const run = byName(jsRuns).get('ko');
  assert.deepStrictEqual(run.outcome, {
    battle: 'ko', outcome: 'win', reason: 'ko', winners: ['p1'], losers: ['p2'],
  });
  assert.strictEqual(run.snapshot.phase, 'over');
  assert.ok(
    run.events.some((event) => event.t === 'faint'),
    'a KO leaves a faint in the stream',
  );
  assert.strictEqual(
    run.events.filter((event) => event.t === 'over').length, 1,
    'and exactly one over',
  );
});

test('mid-turn-KO retargeting: the slower ally swings onto the survivor, not "has no target"', () => {
  const run = byName(jsRuns).get('retarget_ko');
  const events = run.events;

  const koIdx = events.findIndex((event) => event.t === 'faint' && event.text === 'Beta');
  assert.ok(koIdx > -1, "fast's hit really KO'd the aimed-at seat (foeA/Beta)");

  assert.ok(
    !events.some((event) => event.t === 'msg' && event.text && event.text.includes('has no target')),
    "slow's action never fizzles for the dead aim",
  );

  let sawSlowAnim = false;
  let landedOnSlot3 = false;
  for (let i = koIdx + 1; i < events.length; i += 1) {
    const event = events[i];
    if (event.t === 'anim' && event.side === 'a' && event.slot === 1) sawSlowAnim = true;
    if (sawSlowAnim && event.t === 'damage' && event.side === 'b' && event.slot === 3) {
      landedOnSlot3 = true;
      break;
    }
  }
  assert.ok(sawSlowAnim, "slow's move still plays its anim after the mid-turn KO");
  assert.ok(landedOnSlot3, 'slow’s attack lands as real damage on foeB (slot 3), the retargeted seat');

  assert.strictEqual(run.snapshot.field.find((f) => f.slot === 2).hp, 0,
    'foeA (the original, now-dead aim) stayed at 0 hp');
  assert.ok(run.snapshot.field.find((f) => f.slot === 3).hp < 200,
    'foeB (the retargeted seat) actually took the hit');
});

test('a coop_npc trainer spreads its aim across both players, not seat 0 every turn', () => {
  const run = byName(jsRuns).get('coop_npc_aim');
  const hits = run.events
    .filter((event) => event.t === 'damage' && event.side === 'a')
    .map((event) => event.slot);

  assert.strictEqual(hits.length, 12, 'two npc seats swung once each for six turns');
  assert.ok(hits.includes(0), 'the first player was attacked');
  assert.ok(hits.includes(1),
    'and so was the second -- the bug this pins is that slot 1 was never once hit');

  // Not merely "both appear": a rota would also satisfy that. The aim is drawn
  // per action, so the two seats of a single turn are free to agree or differ.
  const turns = [];
  for (let i = 0; i < hits.length; i += 2) turns.push([hits[i], hits[i + 1]]);
  assert.ok(turns.some(([x, y]) => x === y), 'some turns both npcs gang up on one player');
  assert.ok(turns.some(([x, y]) => x !== y), 'and on others they split -- it is a draw, not a rota');

  // The load-bearing half, asserted directly rather than inferred: an aim draw
  // must not spend a byte of the battle's own generator. One that did would
  // move every roll after it and silently rewrite the whole vector pack next
  // door -- a regression with no symptom a player could describe.
  const probe = build({
    id: 'probe', mode: 'coop_npc', seed: 4242, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [
        { playerId: 'p1', name: 'One', mons: [
          mn({ species: 'Alpha', maxHp: 400, spd: 10, moves: [mv('tap', 40, 255, 0)] })] },
        { playerId: 'p2', name: 'Two', mons: [
          mn({ species: 'Gamma', maxHp: 400, spd: 10, moves: [mv('tap', 40, 255, 0)] })] },
      ],
      b: [
        { playerId: 'n1', name: 'NpcA', mons: [
          mn({ species: 'Beta', maxHp: 400, spd: 90, moves: [mv('thump', 40, 255, 0)] })] },
        { playerId: 'n2', name: 'NpcB', mons: [
          mn({ species: 'Delta', maxHp: 400, spd: 80, moves: [mv('thump', 40, 255, 0)] })] },
      ],
    },
  });
  const before = probe.rng.state();
  const npc = probe.byId.get ? probe.byId.get('n1') : probe.byId.n1;
  const aims = new Set();
  for (let i = 0; i < 32; i += 1) aims.add(probe._autoTarget(npc).slot);
  assert.strictEqual(probe.rng.state(), before,
    'thirty-two aim draws later, the battle RNG has not moved');
  assert.deepStrictEqual([...aims].sort(), [0, 1],
    'and those draws did reach both player seats');
});

test('a wild-mode faint pays exactly one exp event, after the faint and before over', () => {
  const run = byName(jsRuns).get('wild_ko');
  const kinds = run.events.map((event) => event.t);
  const expIdx = kinds.indexOf('exp');
  assert.ok(expIdx > -1, 'the fight paid an exp event');
  assert.strictEqual(kinds.filter((t) => t === 'exp').length, 1, 'exactly one -- one owner-slot winner');
  assert.ok(kinds.indexOf('faint') > -1 && kinds.indexOf('faint') < expIdx,
    'the faint precedes the exp event -- the sheet is still in hand when it is paid');
  assert.ok(kinds.indexOf('over') > expIdx, 'and the exp event precedes over');
  const exp = run.events.find((event) => event.t === 'exp');
  assert.strictEqual(exp.slot, 0, 'paid to the sole owner seat, field slot 0');
  assert.strictEqual(exp.species, 'Beta', 'naming the wild mon that fell');
  assert.strictEqual(exp.level, 20, 'and its level');
  assert.strictEqual(exp.participants, 1, 'split one way -- one standing winner');
});

test('a coop_wild 2v1 faint pays both owner seats, slot 0 then slot 1', () => {
  const run = byName(jsRuns).get('coop_wild_ko');
  const exps = run.events.filter((event) => event.t === 'exp');
  assert.strictEqual(exps.length, 2, 'one event per standing owner-slot winner');
  assert.deepStrictEqual(exps.map((event) => event.slot), [0, 1],
    'field-slot order -- a1 (slot 0) before a2 (slot 1)');
  for (const exp of exps) {
    assert.strictEqual(exp.species, 'Beta');
    assert.strictEqual(exp.level, 20);
    assert.strictEqual(exp.participants, 2, 'both winners were standing, so the split is two ways');
  }
});

test('a switch-out-alive participant is paid alongside its replacement, mon 0 then mon 1', () => {
  const run = byName(jsRuns).get('participation_ko');
  const exps = run.events.filter((event) => event.t === 'exp');
  assert.strictEqual(exps.length, 2, 'both the fighter and its replacement are paid');
  assert.deepStrictEqual(exps.map((event) => event.slot), [0, 0],
    'both events sit on the one seat that owns them');
  assert.deepStrictEqual(exps.map((event) => event.mon), [0, 1],
    'party index 0 (Alpha, switched out alive) then 1 (Gamma, the replacement)');
  for (const exp of exps) {
    assert.strictEqual(exp.species, 'Beta');
    assert.strictEqual(exp.participants, 2, 'the divisor counts both participants');
  }
});

test('a self-KO is neither paid nor counted -- the exploder drops out before the divisor is taken', () => {
  const run = byName(jsRuns).get('explode_double_ko');
  const kinds = run.events.map((event) => event.t);
  // Both faints land -- the wild mon's, then a1's own -- before the one exp
  // event the knockout funds, and that event is the only one this action pays.
  const faintIdx = [];
  kinds.forEach((t, i) => { if (t === 'faint') faintIdx.push(i); });
  assert.strictEqual(faintIdx.length, 2,
    "both the wild mon and the self-KO'er faint in this action");
  const expIdx = kinds.indexOf('exp');
  assert.ok(expIdx > faintIdx[1], 'the exp event comes after BOTH faints');
  assert.strictEqual(kinds.filter((t) => t === 'exp').length, 1,
    'exactly one exp event -- the exploder funds nothing of its own');
  const exp = run.events.find((event) => event.t === 'exp');
  assert.strictEqual(exp.slot, 1, "paid to a2's seat, not a1's");
  assert.strictEqual(exp.mon, 0, "a2's own party index");
  assert.strictEqual(exp.participants, 1,
    'divisor 1 -- a1 is dropped from the set, not merely unpaid');
});

test('the replacement mark: a switch-out survivor and its send-out both bank a KO against a new foe', () => {
  const run = byName(jsRuns).get('replacement_mark');
  const allExp = run.events.filter((event) => event.t === 'exp');
  // b1's own knockout pays one event (only a1 was ever in against it), and
  // b2's -- the one this test is about -- pays two.
  assert.strictEqual(allExp.length, 3, 'one event for b1, two for b2');
  assert.strictEqual(allExp[0].participants, 1, "b1's knockout: a1 alone, divisor 1");

  const exps = allExp.slice(1);
  assert.strictEqual(exps.length, 2, 'both a1 (standing when b1 fell) and a2 (the send-out) are paid');
  assert.deepStrictEqual(exps.map((event) => event.slot), [0, 0],
    'both events sit on the one seat that owns them');
  assert.deepStrictEqual(exps.map((event) => event.mon), [0, 1],
    'party index 0 (Alpha, standing at the first KO) then 1 (Gamma, the send-out)');
  for (const exp of exps) {
    assert.strictEqual(exp.participants, 2,
      'the deferred mark carried onto the SECOND foe -- divisor 2, not 1');
  }
});

test('1v1 and coop_pvp never emit exp -- the farming-loop gate', () => {
  const ko = byName(jsRuns).get('ko');
  assert.ok(ko.events.some((event) => event.t === 'faint'), 'ko: a faint really happened');
  for (const name of ['ko', 'coop']) {
    const run = byName(jsRuns).get(name);
    assert.ok(!run.events.some((event) => event.t === 'exp'),
      `${name}: a PvP-shaped mode must never pay exp -- that is a farming loop`);
  }
});

test('a side that drops past its grace forfeits, and rolls nothing doing it', () => {
  const run = byName(jsRuns).get('forfeit');
  assert.deepStrictEqual(run.outcome, {
    battle: 'ff', outcome: 'forfeit', reason: 'disconnect',
    winners: ['p1'], losers: ['p2'],
  });
  assert.strictEqual(
    run.snapshot.rngState, 7,
    'the seed is untouched -- a forfeit consults no roll on either runtime',
  );
  assert.deepStrictEqual(
    run.events.map((event) => event.t),
    ['send', 'send', 'turn', 'wait', 'over'],
  );
});

// The two fixtures above only pin the tie-break threshold if they really landed
// on either side of it. If a change to the draw order moves what the first byte
// is spent on, these stop being a boundary pair and start being one more pass
// -- so the ordering they were built to show is asserted directly.
test('the tie-break pair really straddles the threshold', () => {
  const runs = byName(jsRuns);
  const firstAttacker = (name) => runs.get(name).events
    .find((event) => event.t === 'anim').side;

  assert.strictEqual(firstAttacker('tie_low'), 'a', 'byte 127 leaves side a first');
  assert.strictEqual(firstAttacker('tie_high'), 'b', 'byte 128 reverses the group');
});

test('residuals tick in field order, not speed order', () => {
  const hurt = byName(jsRuns).get('residual_both').events
    .filter((event) => event.t === 'damage' && event.status)
    .map((event) => event.status);
  assert.deepStrictEqual(
    hurt, ['BRN', 'PSN'],
    "side a's burn ticks before side b's poison even though side b moved first",
  );
});

test('a switch resolves before an item, and neither spends a roll', () => {
  const run = byName(jsRuns).get('switch_item');
  assert.deepStrictEqual(
    run.events.map((event) => event.t),
    ['send', 'send', 'turn', 'chose', 'chose', 'switch', 'send', 'item', 'msg', 'msg', 'turn'],
  );
  // 'restore' is an unknown id: announce + "But it failed", still no RNG draw.
  assert.strictEqual(run.snapshot.rngState, 13, 'the seed is untouched');
});

test('sleep with no counter costs exactly the turn it wakes on', () => {
  const run = byName(jsRuns).get('sleep_default');
  const cleared = run.events.find((event) => event.t === 'status');
  assert.ok(cleared, 'the sleeper woke');
  assert.strictEqual(cleared.text, 'Alpha woke up');
  assert.strictEqual(cleared.status, undefined, 'a status event with no status means cleared');
  assert.ok(
    run.events.findIndex((event) => event.t === 'anim' && event.side === 'a')
      > run.events.indexOf(cleared),
    'and it did not also get to move on the turn it woke',
  );
});

test('a spent move is spent, and an empty one Struggles', () => {
  const used = byName(jsRuns).get('pp').events
    .filter((event) => event.t === 'anim')
    .map((event) => `${event.side}:${event.text}`);
  assert.deepStrictEqual(
    used,
    ['a:last', 'b:STRUGGLE', 'a:spare', 'b:STRUGGLE',
     'a:spare', 'b:STRUGGLE', 'a:spare', 'b:STRUGGLE'],
    'the last PP is spent once; an empty movepool Struggles thereafter',
  );
});

// ------------------------------------------------------------------
// properties a fixture cannot state
// ------------------------------------------------------------------

test('same seed and same choices replay identically', () => {
  const first = runJs();
  const second = runJs();
  assert.deepStrictEqual(second, first, 'a battle is a pure function of seed plus choices');
});

test('a different seed produces a different fight', () => {
  const play = (seed) => {
    const thump = () => mv('thump', 40, 255, 0);
    const battle = build({
      id: 'seedcheck', mode: '1v1', seed, choiceTimeout: 60, reconnectGrace: 60,
      sides: {
        a: [{ playerId: 'p1', name: 'Ann', mons: [
          mn({ species: 'Alpha', maxHp: 120, atk: 60, spd: 55, moves: [thump()] })] }],
        b: [{ playerId: 'p2', name: 'Bob', mons: [
          mn({ species: 'Beta', maxHp: 120, atk: 58, spd: 55, moves: [thump()] })] }],
      },
    });
    const events = [];
    drainInto(battle, events);
    for (let i = 0; i < 40; i += 1) {
      if (battle.outcome()) break;
      battle.submitChoice('p1', { action: 'fight', move: 0 });
      battle.submitChoice('p2', { action: 'fight', move: 0 });
      drainInto(battle, events);
    }
    return JSON.stringify(events);
  };
  assert.notStrictEqual(play(4242), play(9001));
});

test('the party the caller handed over is not the party that fights', () => {
  const party = [mn({ species: 'Alpha', maxHp: 200, hp: 200, moves: [mv('thump', 40, 255, 0)] })];
  const battle = build({
    id: 'copy', mode: '1v1', seed: 3, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: party }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 200, moves: [mv('thump', 40, 255, 0)] })] }],
    },
  });
  battle.drainEvents();
  battle.submitChoice('p1', { action: 'fight', move: 0 });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  battle.drainEvents();

  const mine = battle.snapshot().field.find((entry) => entry.playerId === 'p1');
  assert.ok(mine.hp < 200, 'the fight really happened');
  assert.strictEqual(party[0].hp, 200, "the caller's monster kept its HP");
  assert.strictEqual(party[0].moves[0].pp, 60, 'and its PP');
  assert.strictEqual(battle.drainEvents().length, 0, 'a drained buffer comes back empty');
});

// `text` is the token the fight is *narrated* under, and on a real upload that
// token is the player's nickname wherever their monster has one -- so it is the
// one thing on the event the client opposite cannot look anything up by.
// `speciesId` and `level` ride beside it for exactly that seat: without them it
// has no front pic to draw, no number for the level pill, and (on the faint) no
// base rate to price the award with. Both are pass-through -- no formula here
// reads either, and there is no species table to read them against.
test('a send states the registry id and the level, not just the narrated name', () => {
  const battle = build({
    id: 'sid', mode: '1v1', seed: 5, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [{
        ...mn({ species: 'Nickname', level: 33, moves: [mv('thump', 40, 255, 0)] }),
        speciesId: 'alpha',
      }] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', moves: [mv('thump', 40, 255, 0)] })] }],
    },
  });
  const sends = new Map();
  for (const event of battle.drainEvents()) {
    if (event.t === 'send') sends.set(event.slot, event);
  }
  assert.ok(sends.has(0) && sends.has(2), 'the opening fields both seats');
  assert.strictEqual(sends.get(0).text, 'Nickname', 'narrated under the uploaded token');
  assert.strictEqual(sends.get(0).speciesId, 'alpha', 'with the registry id beside it');
  assert.strictEqual(sends.get(0).level, 33, 'and the level nothing else on the wire says');
  assert.strictEqual(sends.get(2).speciesId, undefined, 'a sheet with no id produces no field');
  assert.strictEqual(sends.get(2).level, 20, 'though the level is always known');
  assert.ok(Events.check(sends.get(0))[0], "and it is an event Wire's whitelist accepts");
});

test('every event emitted is in the closed vocabulary, with contiguous seq', () => {
  let count = 0;
  for (const run of jsRuns) {
    const perBattle = new Map();
    for (const event of run.events) {
      count += 1;
      assert.ok(Events.KINDS[event.t], `${run.name}: unknown kind ${event.t}`);
      const [fine, why] = Events.check(event);
      assert.ok(fine, `${run.name}: ${event.t} is malformed -- ${why}`);

      const previous = perBattle.get(event.battle);
      if (previous !== undefined) {
        assert.strictEqual(
          event.seq, previous + 1,
          `${run.name}: seq jumped ${previous} -> ${event.seq}; a client reads a gap as lost messages`,
        );
      }
      perBattle.set(event.battle, event.seq);
    }
  }
  assert.ok(count > 100, 'the scenarios produced a real sample of events');
});

test('create refuses what it cannot fight, and says why', () => {
  const refused = (opts) => {
    const { battle, reason } = Turn.attempt(opts);
    assert.strictEqual(battle, null);
    assert.strictEqual(typeof reason, 'string');
    return reason;
  };
  const one = () => [mn({ species: 'Alpha', moves: [mv('thump', 40, 255, 0)] })];

  refused(null);
  refused({ sides: { a: [], b: [] } });
  refused({ sides: { a: [{ playerId: 'p1', mons: one() }] } });
  refused({ sides: { a: [{ playerId: 'p1', mons: one() }], b: [{ playerId: 'p1', mons: one() }] } });
  refused({ sides: { a: [{ playerId: 'p1', mons: [] }], b: [{ playerId: 'p2', mons: one() }] } });
  refused({
    mode: '1v1',
    sides: {
      a: [{ playerId: 'p1', mons: one() }, { playerId: 'p3', mons: one() }],
      b: [{ playerId: 'p2', mons: one() }],
    },
  });

  assert.strictEqual(Turn.create(null), null, 'create is the same refusal without the reason');
});

test('what a choice may say', () => {
  const battle = build({
    id: 'choices', mode: '1v1', seed: 17, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', moves: [mv('thump', 40, 255, 0), mv('empty', 40, 255, 0, 0)] }),
        mn({ species: 'Gamma', moves: [mv('thump', 40, 255, 0)] }),
        mn({ species: 'Down', hp: 0, moves: [mv('thump', 40, 255, 0)] }),
      ] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', moves: [mv('thump', 40, 255, 0)] })] }],
    },
  });
  battle.drainEvents();

  const no = (playerId, choice, what) => assert.strictEqual(
    battle.submitChoice(playerId, choice), false, what,
  );

  no('ghost', { action: 'fight', move: 0 }, 'an unknown player is refused');
  no('p1', { action: 'wander' }, 'an action outside the vocabulary is refused');
  no('p1', { action: 'fight' }, 'fight with no move is refused');
  no('p1', { action: 'fight', move: 7 }, 'a move index that names nothing is refused');
  no('p1', { action: 'fight', move: 1 }, 'a move with no PP left is refused');
  no('p1', { action: 'switch', slot: 2 }, 'switching to a fainted monster is refused');
  no('p1', { action: 'switch', slot: 0 }, 'switching to the monster already out is refused');
  no('p1', { action: 'item' }, 'an item choice with no item is refused');
  no('p1', { action: 'fight', move: 0, target: 1 }, 'a target nobody occupies is refused');
  no('p1', { action: 'fight', move: 0, target: 0 }, 'and so is aiming at your own slot');
  no('p1', { action: 'cancel' }, 'cancelling nothing is refused');
  no('p1', { action: 'fight', move: true }, 'a boolean is not a move index');

  assert.strictEqual(
    battle.submitChoice('p1', { action: 'fight', move: 0, target: 2 }), true,
    'a well-formed choice is accepted',
  );
  no('p1', { action: 'fight', move: 0 }, 'a second choice in the same turn is refused');
  assert.strictEqual(
    battle.submitChoice('p1', { action: 'cancel' }), true,
    'but the first one can be taken back',
  );
  assert.strictEqual(
    battle.submitChoice('p1', { action: 'switch', slot: 1 }), true, 'and replaced',
  );

  battle.submitChoice('p2', { action: 'fight', move: 0 });
  const drained = battle.drainEvents();
  assert.strictEqual(drained.filter((event) => event.t === 'switch').length, 1, 'the switch resolved');
  const mine = battle.snapshot().field.find((entry) => entry.playerId === 'p1');
  assert.strictEqual(mine.species, 'Gamma', 'with the new monster out');
});

test('a playerId that is also an Object key is just a playerId', () => {
  const battle = build({
    id: 'proto', mode: '1v1', seed: 1, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: '__proto__', name: 'Ann', mons: [
        mn({ species: 'Alpha', moves: [mv('thump', 40, 255, 0)] })] }],
      b: [{ playerId: 'constructor', name: 'Bob', mons: [
        mn({ species: 'Beta', moves: [mv('thump', 40, 255, 0)] })] }],
    },
  });
  battle.drainEvents();
  assert.strictEqual(battle.submitChoice('toString', { action: 'run' }), false,
    'a name nobody registered is still an unknown player');
  assert.strictEqual(battle.submitChoice('__proto__', { action: 'fight', move: 0 }), true);
  assert.strictEqual(battle.submitChoice('constructor', { action: 'fight', move: 0 }), true);
  assert.strictEqual(battle.snapshot().turn, 2, 'and the turn resolved between them');
});

test('the choice clock is suspended while anybody is away', () => {
  const battle = build({
    id: 'paused', mode: '1v1', seed: 2, choiceTimeout: 10, reconnectGrace: 600,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', moves: [mv('thump', 40, 255, 0)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', moves: [mv('thump', 40, 255, 0)] })] }],
    },
  });
  battle.drainEvents();
  assert.strictEqual(battle.snapshot().deadline, 10, 'creating the battle armed the clock');
  battle.disconnect('p2');
  battle.tick(120);
  assert.strictEqual(battle.snapshot().turn, 1, 'the turn did not resolve behind their back');
  assert.strictEqual(battle.outcome(), null, 'and the grace has not run out either');
});

test('a zero-length grace still expires', () => {
  const battle = build({
    id: 'nograce', mode: '1v1', seed: 2, choiceTimeout: 0, reconnectGrace: 0,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', moves: [mv('thump', 40, 255, 0)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', moves: [mv('thump', 40, 255, 0)] })] }],
    },
  });
  battle.drainEvents();
  battle.disconnect('p2');
  assert.strictEqual(battle.tick(0), true, 'a graceEndsAt of 0 is a deadline, not an absence');
  assert.strictEqual(battle.outcome().outcome, 'forfeit');
});

test('a wedged resolve aborts on the wall-clock ceiling', () => {
  const battle = build({
    id: 'stuck', mode: '1v1', seed: 3, choiceTimeout: 60, reconnectGrace: 60,
    resolveTimeout: 30,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', moves: [mv('thump', 40, 255, 0)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', moves: [mv('thump', 40, 255, 0)] })] }],
    },
  });
  battle.drainEvents();
  battle.phase = 'resolving';
  battle.resolveDeadline = battle.now - 1;
  assert.strictEqual(battle.tick(battle.now), true, 'a past resolveDeadline is a tick that acted');
  const out = battle.outcome();
  assert.ok(out, 'the ceiling ends the fight');
  assert.strictEqual(out.outcome, 'draw', 'as a draw -- nobody won a stuck resolve');
  assert.strictEqual(out.reason, 'timeout', 'under the existing timeout reason');
  assert.strictEqual(battle.snapshot().phase, 'over');
  assert.strictEqual(battle.snapshot().resolveDeadline, null);
});

// ------------------------------------------------------------------
// wildlife never uses an item, from either end
// ------------------------------------------------------------------
//
// Twin of tests/battle_sim_turn.lua's 12f3. A wild monster has no bag and no
// hands, and its seat is driven from two ends -- the hub auto-picks for it, and
// a submitted choice can arrive addressed to it -- so both are pinned. The wild
// seat is handed a bag on purpose: even a seat that HAS one must never spend
// it, so a hub seeding the wrong kit (which is what `wild` did with
// DEFAULT_NPC_BAG) cannot put a Potion in a wild monster's mouth.

const wildBattle = (mode, id, bBag) => build({
  id, mode, seed: 88010, choiceTimeout: 10, reconnectGrace: 60,
  sides: {
    a: [{
      playerId: 'p1', name: 'Ann', bag: { POTION: 1 },
      mons: [mn({ species: 'Alpha', maxHp: 200, spd: 90, moves: [mv('thump', 40, 255, 0)] })],
    }],
    b: [{
      playerId: 'wild', name: 'Wild', bag: bBag,
      // Hurt below half and poisoned: a trainer seat heals or cures here.
      mons: [mn({
        species: 'Beta', maxHp: 200, hp: 40, spd: 10, status: 'PSN',
        moves: [mv('thump', 40, 255, 0)],
      })],
    }],
  },
});

for (const mode of ['wild', 'coop_wild']) {
  test(`${mode}: auto-pick never reaches the wild seat's bag`, () => {
    const battle = wildBattle(mode, 'wa', { POTION: 2, FULL_HEAL: 1, X_ATTACK: 1 });
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
    const battle = wildBattle(mode, 'wb', { POTION: 1 });
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
