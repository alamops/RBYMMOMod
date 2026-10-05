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
 * The badge scenarios add one more referee rule both twins must apply alike:
 * an uploaded badge set counts only on side a of a fight against the computer
 * (Turn.BADGE_MODES), never in a link battle and never on side b -- and what it
 * does there is Crystal's: the stat boosts, Glacier's Sp. Def tail, the 999 cap
 * and DoBadgeTypeBoosts.
 * The fidelity scenarios (docs/plans/gen12-referee-fidelity.md) pin the
 * pokecrystal rules both twins now share: the stage-then-badge stat order, the
 * crit stage comparison, TruncateHL_BC's loop and link wrap, per-side screens,
 * the confusion self-hit's quirks, typeless Struggle, a Metronome call made
 * with the last PP, and the move-priority brackets; the held-item, obedience
 * and review-fix scenarios after them pin Gold's items, Thief's effectchance,
 * CheckTurn's gate order, Bide, Leech Seed and Rage.
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
    stages: o.stages,
    confusion: o.confusion,
    focusEnergy: o.focusEnergy,
    // What the held-item and obedience scenarios add (contracts K1 / K2); the
    // item is [id, HELD_* effect, parameter, name, mail], synthetic throughout.
    speciesId: o.speciesId,
    statusTurns: o.statusTurns,
    traded: o.traded,
    disable: o.disable,
    // What the review-fix scenarios add: a standing substitute, Bide, Leech
    // Seed, rage and Transform carried on the sheet.
    substitute: o.substitute,
    bide: o.bide,
    leechSeed: o.leechSeed,
    raging: o.raging,
    rageCounter: o.rageCounter,
    transformed: o.transformed,
    // What the side-effect scenarios add: a Mist the sheet carries.
    mist: o.mist,
    // What the R2b scenarios add: the K7 blocks a level-up reads.
    base: o.base,
    dvs: o.dvs,
    ...(o.item ? {
      heldItem: o.item[0],
      holdEffect: o.item[1],
      holdParam: o.item[2],
      itemName: o.item[3],
      mail: o.item[4],
    } : {}),
  };
}

// A full move for the held-item scenarios: an effect id and its chance.
function hm(id, power, type, effect, pp, chance) {
  return {
    id,
    pp: pp === undefined ? 60 : pp,
    power,
    accuracy: 255,
    type: type === undefined ? 0 : type,
    effect: effect === undefined ? 0 : effect,
    chance: chance === undefined ? 0 : chance,
  };
}

// A move with an effect id (lib/battle2/Effects.js numbering), which `mv`
// leaves at 0.
function fx(id, power, type, effect, pp) {
  return {
    id, pp: pp === undefined ? 60 : pp, power, accuracy: 255, type, effect, chance: 0,
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
    battle.submitChoice('a1', { action: 'fight', move: 0, target: 3 });
    battle.submitChoice('a2', { action: 'fight', move: 0, target: 3 });
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
    battle.submitChoice('a1', { action: 'fight', move: 0, target: 3 });
    battle.submitChoice('a2', { action: 'fight', move: 0, target: 3 });
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
  battle.submitChoice('fast', { action: 'fight', move: 0, target: 3 });
  battle.submitChoice('slow', { action: 'fight', move: 0, target: 3 });
  battle.submitChoice('foeA', { action: 'fight', move: 0, target: 0 });
  battle.submitChoice('foeB', { action: 'fight', move: 0, target: 0 });
  drainInto(battle, events);
  return battle;
});

// 5. a whole trapping chain, Gold's way. TrapTarget sets a 3..6 count;
//    HandleWrap ticks it at the end of every turn -- the one Wrap landed on
//    included -- for a sixteenth of max HP, and releases at 0. Nobody is
//    forced: the wrapped seat answers every turn, its switch is refused while
//    the count runs and taken once it is released, and the trapper picks its
//    own moves (a plain hit after the first turn).
scenario('trap_chain', (events) => {
  const wrap = () => ({ id: 'wrap', pp: 60, power: 5, accuracy: 255, type: 0,
    effect: 42, chance: 0 });
  const battle = build({
    id: 'trp', mode: '1v1', seed: 9999,
    choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 400, spe: 120, moves: [wrap(), mv('tap', 10, 255, 0)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 400, def: 200, spe: 1, moves: [mv('tap', 10, 255, 0)] }),
        mn({ species: 'Gamma', maxHp: 400, spe: 1, moves: [mv('tap', 10, 255, 0)] })] }],
    },
  });
  drainInto(battle, events);
  battle.submitChoice('p1', { action: 'fight', move: 0 });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  drainInto(battle, events);
  for (let i = 0; i < 6; i += 1) {
    if (!battle.submitChoice('p2', { action: 'switch', slot: 1 })) {
      battle.submitChoice('p2', { action: 'fight', move: 0 });
    }
    battle.submitChoice('p1', { action: 'fight', move: 1 });
    drainInto(battle, events);
  }
  return battle;
});

// the display name a sheet carries (PROTOCOL 26), and the id it falls back to
// when it carries none. The Gen 1 pair next door explains the shape; this is
// the Gen 2 twin of it, because BattleSim2 / lib/battle2 narrate a move from
// their own copies of the same five call sites.
scenario('move_names', (events) => {
  // `mv` writes effect=0, so the two effect moves are built by hand. 86 is
  // DISABLE_EFFECT and 82 is MIMIC_EFFECT (lib/battle2/Effects.js).
  const swipe = () => ({
    id: 'slow_swipe', name: 'SLOW SWIPE', pp: 60, power: 10,
    accuracy: 255, type: 0, effect: 0, chance: 0,
  });
  const lockdown = () => ({
    id: 'lock_down', name: 'LOCK DOWN', pp: 60, power: 0,
    accuracy: 255, type: 0, effect: 86, chance: 0,
  });
  const copycat = () => ({
    id: 'copy_cat', name: 'COPY CAT', pp: 60, power: 0,
    accuracy: 255, type: 0, effect: 82, chance: 0,
  });
  const thump = () => ({
    id: 'thump', name: 'THUMP HIT', pp: 60, power: 10,
    accuracy: 255, type: 0, effect: 0, chance: 0,
  });
  // No `name` at all: the protocol-25 sheet, narrated under its id.
  const nudge = () => mv('nudge', 10, 255, 0);
  const battle = build({
    id: 'mn', mode: '1v1', seed: 4242, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 400, spe: 90,
             moves: [swipe(), lockdown(), copycat()] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 400, spe: 10,
             moves: [thump(), nudge()] })] }],
    },
  });
  drainInto(battle, events);
  battle.submitChoice('p1', { action: 'fight', move: 0 });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  drainInto(battle, events);
  battle.submitChoice('p1', { action: 'fight', move: 1 });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  drainInto(battle, events);
  battle.submitChoice('p1', { action: 'fight', move: 2 });
  battle.submitChoice('p2', { action: 'fight', move: 1 });
  drainInto(battle, events);
  for (let i = 0; i < 5; i += 1) {
    battle.submitChoice('p1', { action: 'fight', move: 2 });
    battle.submitChoice('p2', { action: 'fight', move: 1 });
    drainInto(battle, events);
  }
  return battle;
});

// uploaded badge sets, and where the referee lets them count (Turn.BADGE_MODES
// / Turn.BADGE_SIDE: side a of a fight against the computer, never a link
// battle -- Crystal's BadgeStatBoosts returns early in one). Every seat holds
// all sixteen Gold badges and the ruleset names the types, so a leak would
// show as a stat boost or a type boost. Speeds sit a step apart so a PLAIN
// that leaked would reorder the field rather than merely move a damage number,
// and the npc fight carries a special move so GLACIER (Sp. Atk) and VOLCANO's
// type boost are both read. `badges_link` and `badges_coop_pvp` fight as
// though nobody held a badge; `badges_npc` boosts side a and ignores side b's
// upload; `badges_gold` drives the rules a plain fight never reaches -- the
// 999 cap, Glacier's Sp. Def tail, a type boost on a move with no stat badge
// behind it, and a confusion self-hit on boosted stats.
const allBadges = () => ({
  ZEPHYR: true, HIVE: true, PLAIN: true, FOG: true,
  MINERAL: true, STORM: true, GLACIER: true, RISING: true,
  BOULDER: true, CASCADE: true, THUNDER: true, RAINBOW: true,
  SOUL: true, MARSH: true, VOLCANO: true, EARTH: true,
});

// Chart index 0 is NORMAL (PLAIN's type), 1 FIRE (VOLCANO's, and Special),
// 2 BUG (HIVE's).
const TYPE_IDS = ['NORMAL', 'FIRE', 'BUG'];

scenario('badges_link', (events) => {
  const thump = () => mv('thump', 40, 255, 0);
  const battle = build({
    id: 'bl', mode: '1v1', seed: 2718, choiceTimeout: 60, reconnectGrace: 60,
    typeIds: TYPE_IDS,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', badges: allBadges(), mons: [
        mn({ species: 'Alpha', maxHp: 200, atk: 60, spe: 40, moves: [thump()] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 200, atk: 60, spe: 42, moves: [thump()] })] }],
    },
  });
  drainInto(battle, events);
  for (let i = 0; i < 3; i += 1) {
    battle.submitChoice('p1', { action: 'fight', move: 0 });
    battle.submitChoice('p2', { action: 'fight', move: 0 });
    drainInto(battle, events);
  }
  return battle;
});

scenario('badges_coop_pvp', (events) => {
  const thump = () => mv('thump', 40, 255, 0);
  const battle = build({
    id: 'bp', mode: 'coop_pvp', seed: 3141, choiceTimeout: 60, reconnectGrace: 60,
    typeIds: TYPE_IDS,
    sides: {
      a: [
        { playerId: 'a1', name: 'Ann', badges: allBadges(), mons: [
          mn({ species: 'Alpha', maxHp: 300, atk: 60, spe: 40, moves: [thump()] })] },
        { playerId: 'a2', name: 'Abe', badges: allBadges(), mons: [
          mn({ species: 'Gamma', maxHp: 300, atk: 55, spe: 30, moves: [thump()] })] },
      ],
      b: [
        { playerId: 'b1', name: 'Bob', badges: allBadges(), mons: [
          mn({ species: 'Beta', maxHp: 300, atk: 60, spe: 42, moves: [thump()] })] },
        { playerId: 'b2', name: 'Bea', badges: allBadges(), mons: [
          mn({ species: 'Delta', maxHp: 300, atk: 55, spe: 34, moves: [thump()] })] },
      ],
    },
  });
  drainInto(battle, events);
  for (let i = 0; i < 2; i += 1) {
    battle.submitChoice('a1', { action: 'fight', move: 0, target: 3 });
    battle.submitChoice('a2', { action: 'fight', move: 0, target: 4 });
    battle.submitChoice('b1', { action: 'fight', move: 0, target: 0 });
    battle.submitChoice('b2', { action: 'fight', move: 0, target: 1 });
    drainInto(battle, events);
  }
  return battle;
});

scenario('badges_npc', (events) => {
  const thump = () => mv('thump', 40, 255, 0);
  const zap = () => mv('zap', 40, 255, 1);
  const battle = build({
    id: 'bn', mode: 'coop_npc', seed: 1618, choiceTimeout: 60, reconnectGrace: 60,
    specialTypes: [1],
    typeIds: TYPE_IDS,
    sides: {
      a: [
        { playerId: 'a1', name: 'Ann', badges: allBadges(), mons: [
          mn({ species: 'Alpha', maxHp: 300, atk: 60, spe: 40, moves: [thump()] })] },
        { playerId: 'a2', name: 'Abe', badges: allBadges(), mons: [
          mn({ species: 'Gamma', maxHp: 300, spa: 60, spd: 50, spe: 30,
               moves: [zap()] })] },
      ],
      b: [
        { playerId: 'n1', name: 'NpcA', badges: allBadges(), mons: [
          mn({ species: 'Beta', maxHp: 300, atk: 60, spe: 42, moves: [thump()] })] },
        { playerId: 'n2', name: 'NpcB', badges: allBadges(), mons: [
          mn({ species: 'Delta', maxHp: 300, spa: 60, spd: 50, spe: 37,
               moves: [zap()] })] },
      ],
    },
  });
  drainInto(battle, events);
  for (let i = 0; i < 2; i += 1) {
    battle.submitChoice('a1', { action: 'fight', move: 0, target: 3 });
    battle.submitChoice('a2', { action: 'fight', move: 0, target: 4 });
    battle.submitChoice('n1', { action: 'fight', move: 0, target: 0 });
    battle.submitChoice('n2', { action: 'fight', move: 0, target: 1 });
    drainInto(battle, events);
  }
  return battle;
});

scenario('badges_gold', (events) => {
  const bite = () => mv('bite', 40, 255, 2);
  const thump = () => mv('thump', 40, 255, 0);
  const zap = () => mv('zap', 40, 255, 1);
  // Abe is confused, so his turns spend the confusion byte and, on this seed,
  // hit himself on MINERAL's boosted Defense.
  const abe = mn({ species: 'Gamma', maxHp: 300, atk: 50, def: 40,
    spa: 227, spd: 50, spe: 30, moves: [thump()] });
  abe.confusion = 4;
  const battle = build({
    id: 'bg', mode: 'coop_npc', seed: 2027, choiceTimeout: 60, reconnectGrace: 60,
    specialTypes: [1],
    typeIds: TYPE_IDS,
    sides: {
      a: [
        // 950 Attack under ZEPHYR is the 999 cap; HIVE type-boosts the BUG
        // move, which no stat badge stands behind.
        { playerId: 'a1', name: 'Ann', badges: { ZEPHYR: true, PLAIN: true, HIVE: true },
          mons: [mn({ species: 'Alpha', maxHp: 300, atk: 950, spe: 40,
            moves: [bite()] })] },
        // Sp. Atk 227 boosts to 255 under GLACIER, which Glacier's tail reads
        // as a Sp. Def boost too; MINERAL stands behind Defense.
        { playerId: 'a2', name: 'Abe', badges: { GLACIER: true, MINERAL: true },
          mons: [abe] },
      ],
      b: [
        { playerId: 'n1', name: 'NpcA', badges: allBadges(), mons: [
          mn({ species: 'Beta', maxHp: 400, spa: 70, spe: 42, moves: [zap()] })] },
        { playerId: 'n2', name: 'NpcB', badges: allBadges(), mons: [
          mn({ species: 'Delta', maxHp: 999, def: 600, atk: 70, spe: 37,
            moves: [thump()] })] },
      ],
    },
  });
  drainInto(battle, events);
  for (let i = 0; i < 3; i += 1) {
    battle.submitChoice('a1', { action: 'fight', move: 0, target: 4 });
    battle.submitChoice('a2', { action: 'fight', move: 0, target: 3 });
    battle.submitChoice('n1', { action: 'fight', move: 0, target: 1 });
    battle.submitChoice('n2', { action: 'fight', move: 0, target: 1 });
    drainInto(battle, events);
  }
  return battle;
});

// CalcPlayerStats' order: the stage, then the badge (see the driver).
scenario('stage_badge_order', (events) => {
  const slam = () => mv('slam', 100, 255, 0);
  const zap = () => mv('zap', 60, 255, 1);
  const battle = build({
    id: 'sb', mode: 'coop_npc', seed: 4096, choiceTimeout: 60, reconnectGrace: 60,
    // Index 0 names DARK, a type no held badge boosts, so PLAIN moves Speed
    // and nothing else.
    specialTypes: [1], typeIds: ['DARK', 'FIRE'],
    sides: {
      a: [
        { playerId: 'a1', name: 'Ann', badges: { ZEPHYR: true, PLAIN: true },
          mons: [mn({ species: 'Alpha', level: 50, maxHp: 400, atk: 100, spe: 100,
            types: [2], stages: { atk: -1, spe: -1 },
            moves: [slam()] })] },
        { playerId: 'a2', name: 'Abe', badges: { GLACIER: true },
          mons: [mn({ species: 'Gamma', level: 50, maxHp: 400, spa: 152, spd: 100,
            spe: 30, types: [2], stages: { spa: 1 },
            moves: [zap()] })] },
      ],
      b: [
        { playerId: 'n1', name: 'NpcA', mons: [
          mn({ species: 'Beta', level: 50, maxHp: 400, def: 20, spe: 73,
            types: [2], moves: [slam()] })] },
        { playerId: 'n2', name: 'NpcB', mons: [
          mn({ species: 'Delta', level: 50, maxHp: 400, spa: 120, spe: 20,
            types: [2], moves: [zap()] })] },
      ],
    },
  });
  drainInto(battle, events);
  battle.submitChoice('a1', { action: 'fight', move: 0, target: 3 });
  battle.submitChoice('a2', { action: 'fight', move: 0, target: 4 });
  battle.submitChoice('n1', { action: 'fight', move: 0, target: 0 });
  battle.submitChoice('n2', { action: 'fight', move: 0, target: 1 });
  drainInto(battle, events);
  return battle;
});

// CheckDamageStatsCritical, both ways (see the driver).
scenario('crit_stages', (events) => {
  const slash = () => {
    const m = mv('slash_hit', 70, 255, 0, 30);
    m.highCrit = true;
    return m;
  };
  const wall = () => fx('wall_up', 0, 1, 65, 20);
  const battle = build({
    id: 'cr', mode: '1v1', seed: 34, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', level: 30, maxHp: 400, atk: 80, def: 80, spe: 60,
          types: [2], stages: { atk: 1, def: 2 }, moves: [slash(), wall()] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', level: 30, maxHp: 400, atk: 80, def: 80, spe: 50,
          types: [2], focusEnergy: true, moves: [slash(), wall()] })] }],
    },
  });
  drainInto(battle, events);
  battle.submitChoice('p1', { action: 'fight', move: 1 });
  battle.submitChoice('p2', { action: 'fight', move: 1 });
  drainInto(battle, events);
  for (let i = 0; i < 3; i += 1) {
    battle.submitChoice('p1', { action: 'fight', move: 0 });
    battle.submitChoice('p2', { action: 'fight', move: 0 });
    drainInto(battle, events);
  }
  return battle;
});

// TruncateHL_BC by cart family, K6 (see the driver).
function truncation(mode, id, foeId, family) {
  return (events) => {
    const thump = () => mv('thump', 70, 255, 0);
    const wall = () => fx('wall_up', 0, 1, 65, 20);
    const battle = build({
      id, mode, seed: 31337, choiceTimeout: 60, reconnectGrace: 60,
      sides: {
        a: [{ playerId: 'p1', name: 'Ann', family, mons: [
          mn({ species: 'Alpha', level: 30, maxHp: 400, atk: 200, spe: 50,
            types: [2], moves: [thump()] })] }],
        b: [{ playerId: foeId, name: 'Bob', mons: [
          mn({ species: 'Beta', level: 30, maxHp: 400, def: 600, spe: 60,
            types: [2], moves: [wall(), thump()] })] }],
      },
    });
    drainInto(battle, events);
    battle.submitChoice('p1', { action: 'fight', move: 0 });
    battle.submitChoice(foeId, { action: 'fight', move: 0 });
    drainInto(battle, events);
    battle.submitChoice('p1', { action: 'fight', move: 0 });
    battle.submitChoice(foeId, { action: 'fight', move: 1 });
    drainInto(battle, events);
    return battle;
  };
}
scenario('truncate_wild', truncation('wild', 'tw', 'wild'));
scenario('truncate_link', truncation('1v1', 'tl', 'p2'));
scenario('truncate_crystal_wild', truncation('wild', 'tcw', 'wild', 'crystal'));
scenario('truncate_crystal_link', truncation('1v1', 'tcl', 'p2', 'crystal'));

// Screens belong to the SIDE (see the driver).
scenario('screens_side', (events) => {
  const thump = () => mv('thump', 50, 255, 0);
  const wall = () => fx('wall_up', 0, 1, 65, 20);
  const haze = () => fx('reset_fog', 0, 1, 25, 20);
  const battle = build({
    id: 'ss', mode: 'coop_pvp', seed: 8080, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [
        { playerId: 'a1', name: 'Ann', mons: [
          mn({ species: 'Alpha', maxHp: 999, spe: 90, types: [2],
            moves: [wall(), thump()] }),
          mn({ species: 'Gamma', maxHp: 999, spe: 85, types: [2],
            moves: [thump()] })] },
        { playerId: 'a2', name: 'Abe', mons: [
          mn({ species: 'Eta', maxHp: 999, spe: 80, types: [2],
            moves: [thump()] })] },
      ],
      b: [
        { playerId: 'b1', name: 'Bob', mons: [
          mn({ species: 'Beta', maxHp: 999, atk: 60, spe: 50, types: [2],
            moves: [thump(), haze()] })] },
        { playerId: 'b2', name: 'Bea', mons: [
          mn({ species: 'Delta', maxHp: 999, atk: 60, spe: 40, types: [2],
            moves: [thump()] })] },
      ],
    },
  });
  drainInto(battle, events);
  // Ann: Reflect, Reflect again, switch to Gamma, then Gamma's one hit. Bob:
  // a hit on Abe every turn but the fourth, which is Haze.
  for (let turn = 1; turn <= 6; turn += 1) {
    if (turn === 3) {
      battle.submitChoice('a1', { action: 'switch', slot: 1 });
    } else {
      battle.submitChoice('a1', { action: 'fight', move: 0, target: 3 });
    }
    battle.submitChoice('a2', { action: 'fight', move: 0, target: 4 });
    battle.submitChoice('b1', { action: 'fight', move: turn === 4 ? 1 : 0, target: 1 });
    battle.submitChoice('b2', { action: 'fight', move: 0, target: 0 });
    drainInto(battle, events);
  }
  return battle;
});

// HitConfusion on both sides (see the driver).
scenario('self_hit', (events) => {
  const thump = () => mv('thump', 40, 255, 0);
  const wall = () => fx('wall_up', 0, 1, 65, 20);
  const boom = () => fx('big_boom', 250, 0, 7, 5);
  const battle = build({
    id: 'sh', mode: 'coop_pvp', seed: 5, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [
        { playerId: 'a1', name: 'Ann', mons: [
          mn({ species: 'Alpha', maxHp: 300, atk: 60, def: 60, spe: 50,
            types: [2], confusion: 4, moves: [thump()] })] },
        { playerId: 'a2', name: 'Abe', mons: [
          mn({ species: 'Gamma', maxHp: 300, spe: 90, types: [2],
            moves: [wall()] })] },
      ],
      b: [
        { playerId: 'b1', name: 'Bob', mons: [
          mn({ species: 'Beta', maxHp: 300, atk: 60, def: 60, spe: 40,
            types: [2], confusion: 4, moves: [boom()] })] },
        { playerId: 'b2', name: 'Bea', mons: [
          mn({ species: 'Delta', maxHp: 300, spe: 30, types: [2],
            moves: [thump()] })] },
      ],
    },
  });
  drainInto(battle, events);
  battle.submitChoice('a1', { action: 'fight', move: 0, target: 3 });
  battle.submitChoice('a2', { action: 'fight', move: 0, target: 3 });
  battle.submitChoice('b1', { action: 'fight', move: 0, target: 0 });
  battle.submitChoice('b2', { action: 'fight', move: 0, target: 1 });
  drainInto(battle, events);
  return battle;
});

// Struggle is typeless (see the driver).
scenario('struggle_typeless', (events) => {
  const battle = build({
    id: 'st', mode: '1v1', seed: 5555, choiceTimeout: 60, reconnectGrace: 60,
    chart: [[100, 0], [100, 100]],
    typeIds: ['NORMAL', 'GHOST'],
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', level: 30, maxHp: 300, atk: 80, spe: 60,
          types: [0], moves: [mv('thump', 40, 255, 0, 0)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', level: 30, maxHp: 300, def: 60, spe: 50,
          types: [1], moves: [mv('haunt', 40, 255, 1)] })] }],
    },
  });
  drainInto(battle, events);
  for (let i = 0; i < 2; i += 1) {
    battle.submitChoice('p1', { action: 'fight', move: 0 });
    battle.submitChoice('p2', { action: 'fight', move: 0 });
    drainInto(battle, events);
  }
  return battle;
});

// Metronome with its last PP calls a plain hit, not Struggle (see the driver).
scenario('metronome_last_pp', (events) => {
  const battle = build({
    id: 'mt', mode: '1v1', seed: 6060, choiceTimeout: 60, reconnectGrace: 60,
    metronomePool: [mv('pool_hit', 60, 255, 1, 10)],
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', level: 30, maxHp: 300, atk: 80, spe: 60,
          types: [2], moves: [fx('wave_finger', 0, 0, 83, 1)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', level: 30, maxHp: 300, def: 60, spe: 50,
          types: [2], moves: [mv('thump', 40, 255, 0)] })] }],
    },
  });
  drainInto(battle, events);
  for (let i = 0; i < 2; i += 1) {
    battle.submitChoice('p1', { action: 'fight', move: 0 });
    battle.submitChoice('p2', { action: 'fight', move: 0 });
    drainInto(battle, events);
  }
  return battle;
});

// GetMovePriority's brackets on a four-seat field (see the driver).
scenario('priority', (events) => {
  const thump = () => mv('thump', 40, 255, 0);
  const battle = build({
    id: 'pr', mode: 'coop_pvp', seed: 9090, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [
        { playerId: 'a1', name: 'Ann', mons: [
          mn({ species: 'Alpha', maxHp: 300, spe: 10, types: [2],
            moves: [mv('QUICK_ATTACK', 40, 255, 0)] })] },
        { playerId: 'a2', name: 'Abe', mons: [
          mn({ species: 'Gamma', maxHp: 300, spe: 99, types: [2],
            moves: [fx('VITAL_THROW', 70, 0, 17), thump()] })] },
      ],
      b: [
        { playerId: 'b1', name: 'Bob', mons: [
          mn({ species: 'Beta', maxHp: 300, spe: 5, types: [2],
            moves: [mv('PROTECT', 0, 255, 0), mv('EXTREMESPEED', 80, 255, 0)] })] },
        { playerId: 'b2', name: 'Bea', mons: [
          mn({ species: 'Delta', maxHp: 300, spe: 50, types: [2],
            moves: [thump()] })] },
      ],
    },
  });
  drainInto(battle, events);
  battle.submitChoice('a1', { action: 'fight', move: 0, target: 3 });
  battle.submitChoice('a2', { action: 'fight', move: 0, target: 4 });
  battle.submitChoice('b1', { action: 'fight', move: 0, target: 0 });
  battle.submitChoice('b2', { action: 'fight', move: 0, target: 1 });
  drainInto(battle, events);
  battle.submitChoice('a1', { action: 'fight', move: 0, target: 3 });
  battle.submitChoice('a2', { action: 'fight', move: 1, target: 4 });
  battle.submitChoice('b1', { action: 'fight', move: 1, target: 0 });
  battle.submitChoice('b2', { action: 'fight', move: 0, target: 1 });
  drainInto(battle, events);
  return battle;
});

// ------------------------------------------------------------------
// Gold held items, obedience and the flinch reset (see the driver for what
// each scenario pins). Every parameter is synthetic.
// ------------------------------------------------------------------

// Build, drain, then play each round and drain after it.
function play(events, opts, rounds) {
  const battle = build(opts);
  drainInto(battle, events);
  for (const round of rounds) {
    if (battle.outcome()) break;
    round(battle);
    drainInto(battle, events);
  }
  return battle;
}

const repeat = (fn, n) => Array.from({ length: n }, () => fn);

scenario('quick_claw', (events) => {
  const claw = ['QUICK_CLAW', 'HELD_QUICK_CLAW', 100, 'QUICK CLAW'];
  const round = (b) => {
    b.submitChoice('a1', { action: 'fight', move: 0, target: 3 });
    b.submitChoice('a2', { action: 'fight', move: 0, target: 4 });
    b.submitChoice('b1', { action: 'fight', move: 0, target: 0 });
    b.submitChoice('b2', { action: 'fight', move: 0, target: 1 });
  };
  return play(events, {
    id: 'qc', mode: 'coop_pvp', seed: 4, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'a1', name: 'Ann', mons: [mn({ species: 'Alpha', maxHp: 999, spe: 10,
        item: claw, moves: [hm('thump', 10)] })] },
      { playerId: 'a2', name: 'Abe', mons: [mn({ species: 'Gamma', maxHp: 999, spe: 90,
        moves: [hm('thump', 10)] })] }],
      b: [{ playerId: 'b1', name: 'Bob', mons: [mn({ species: 'Beta', maxHp: 999, spe: 20,
        item: claw, moves: [hm('thump', 10)] })] },
      { playerId: 'b2', name: 'Bea', mons: [mn({ species: 'Delta', maxHp: 999, spe: 50,
        item: claw, moves: [hm('QUICK_ATTACK', 10)] })] }],
    },
  }, repeat(round, 4));
});

scenario('held_between_turns', (events) => {
  const round = (b) => {
    for (const id of ['a1', 'a2', 'a3']) b.submitChoice(id, { action: 'fight', move: 0, target: 3 });
    for (const id of ['b1', 'b2', 'b3']) b.submitChoice(id, { action: 'fight', move: 0, target: 1 });
  };
  return play(events, {
    id: 'bt', mode: 'coop_pvp', seed: 5, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'a1', name: 'Ann', mons: [mn({ species: 'Alpha', maxHp: 320, hp: 200, spe: 90,
        item: ['LEFTOVERS', 'HELD_LEFTOVERS', 0, 'LEFTOVERS'], moves: [hm('tap', 1)] })] },
      { playerId: 'a2', name: 'Abe', mons: [mn({ species: 'Gamma', maxHp: 400, spe: 80,
        item: ['MYSTERYBERRY', 'HELD_RESTORE_PP', 0, 'MYSTERYBERRY'],
        moves: [hm('tap', 1), hm('SKETCH', 0, 0, 0, 0), hm('spent', 40, 0, 0, 0)] })] },
      { playerId: 'a3', name: 'Cal', mons: [mn({ species: 'Eta', maxHp: 200, hp: 90, spe: 70,
        item: ['GOLD_BERRY', 'HELD_BERRY', 25, 'GOLD BERRY'], moves: [hm('tap', 1)] })] }],
      b: [{ playerId: 'b1', name: 'Bob', mons: [mn({ species: 'Beta', maxHp: 200, hp: 99, spe: 60,
        item: ['BERRY', 'HELD_BERRY', 12, 'BERRY'], moves: [hm('tap', 1)] })] },
      { playerId: 'b2', name: 'Bea', mons: [mn({ species: 'Delta', maxHp: 400, spe: 50,
        item: ['X_GEM', 'HELD_ATTACK_UP', 0, 'X GEM'], moves: [hm('tap', 1)] })] },
      { playerId: 'b3', name: 'Bo', mons: [mn({ species: 'Zeta', maxHp: 400, spe: 40,
        item: ['LEFTOVERS', 'HELD_LEFTOVERS', 0, 'LEFTOVERS'], moves: [hm('tap', 1)] })] }],
    },
  }, repeat(round, 2));
});

scenario('status_berries', (events) => {
  const round = (b) => {
    b.submitChoice('a1', { action: 'fight', move: 0, target: 3 });
    b.submitChoice('a2', { action: 'fight', move: 0, target: 4 });
    b.submitChoice('a3', { action: 'fight', move: 0, target: 5 });
    for (const id of ['b1', 'b2', 'b3']) b.submitChoice(id, { action: 'fight', move: 0, target: 0 });
  };
  return play(events, {
    id: 'sb', mode: 'coop_pvp', seed: 5, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'a1', name: 'Ann', mons: [mn({ species: 'Alpha', maxHp: 300, spe: 90, status: 'PSN',
        confusion: 3, item: ['MIRACLEBERRY', 'HELD_HEAL_STATUS', 0, 'MIRACLEBERRY'],
        moves: [hm('doze_dust', 0, 0, 32)] })] },
      { playerId: 'a2', name: 'Abe', mons: [mn({ species: 'Gamma', maxHp: 300, spe: 80,
        confusion: 4, item: ['BITTER_BERRY', 'HELD_HEAL_CONFUSION', 0, 'BITTER BERRY'],
        moves: [hm('venom_jab', 20, 0, 2, 60, 100)] })] },
      { playerId: 'a3', name: 'Cal', mons: [mn({ species: 'Eta', maxHp: 300, spe: 70, status: 'BRN',
        item: ['ICE_BERRY', 'HELD_HEAL_BURN', 0, 'ICE BERRY'], moves: [hm('daze_ray', 0, 0, 49)] })] }],
      b: [{ playerId: 'b1', name: 'Bob', mons: [mn({ species: 'Beta', maxHp: 300, spe: 60,
        item: ['MINT_BERRY', 'HELD_HEAL_SLEEP', 0, 'MINT BERRY'], moves: [hm('tap', 1)] })] },
      { playerId: 'b2', name: 'Bea', mons: [mn({ species: 'Delta', maxHp: 300, spe: 50,
        item: ['PSNCUREBERRY', 'HELD_HEAL_POISON', 0, 'PSNCUREBERRY'], moves: [hm('tap', 1)] })] },
      { playerId: 'b3', name: 'Bo', mons: [mn({ species: 'Zeta', maxHp: 300, spe: 40,
        item: ['BITTER_BERRY', 'HELD_HEAL_CONFUSION', 0, 'BITTER BERRY'], moves: [hm('tap', 1)] })] }],
    },
  }, repeat(round, 2));
});

scenario('focus_band', (events) => {
  const round = (b) => {
    b.submitChoice('p1', { action: 'fight', move: 0 });
    b.submitChoice('p2', { action: 'fight', move: 0 });
  };
  return play(events, {
    id: 'fb', mode: '1v1', seed: 11, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [mn({ species: 'Alpha', maxHp: 300, atk: 60, spe: 90,
        types: [2], moves: [hm('thump', 40)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [mn({ species: 'Beta', maxHp: 40, spe: 10, types: [2],
        item: ['FOCUS_BAND', 'HELD_FOCUS_BAND', 160, 'FOCUS BAND'], moves: [hm('tap', 1)] })] }],
    },
  }, repeat(round, 6));
});

scenario('kings_rock', (events) => {
  const rock = ['KINGS_ROCK', 'HELD_FLINCH', 200, "KING'S ROCK"];
  const rounds = [[0, 0], [1, 0], [2, 0], [0, 0]].map((picks) => (b) => {
    b.submitChoice('p1', { action: 'fight', move: picks[0] });
    b.submitChoice('p2', { action: 'fight', move: picks[1] });
  });
  return play(events, {
    id: 'kr', mode: '1v1', seed: 1, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [mn({ species: 'Alpha', maxHp: 999, spe: 90, types: [2],
        item: rock, moves: [hm('thump', 10), hm('THUNDER', 10, 0, 97), hm('ember_hit', 10, 0, 4)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [mn({ species: 'Beta', maxHp: 999, spe: 10, types: [2],
        item: rock, moves: [hm('thump', 10)] })] }],
    },
  }, rounds);
});

// Thief's row: its 100% effect chance (`percent 100`), which the script's
// `effectchance` rolls before the hit.
const thief = (power) => hm('THIEF', power, 0, 0, undefined, 100);

scenario('thief', (events) => {
  const round = (b) => {
    b.submitChoice('p1', { action: 'fight', move: 0 });
    b.submitChoice('wild', { action: 'fight', move: 0 });
  };
  return play(events, {
    id: 'th', mode: 'wild', seed: 3, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [mn({ species: 'Alpha', maxHp: 300, spe: 90, types: [2],
        moves: [thief(10)] })] }],
      b: [{ playerId: 'wild', name: 'Wild', mons: [mn({ species: 'Beta', maxHp: 320, spe: 10, types: [2],
        item: ['LEFTOVERS', 'HELD_LEFTOVERS', 0, 'LEFTOVERS'], moves: [thief(10)] })] }],
    },
  }, repeat(round, 2));
});

scenario('thief_refused', (events) => {
  const round = (b) => {
    b.submitChoice('a1', { action: 'fight', move: 0, target: 3 });
    b.submitChoice('a2', { action: 'fight', move: 0, target: 4 });
    b.submitChoice('a3', { action: 'fight', move: 0, target: 5 });
    for (const id of ['b1', 'b2', 'b3']) b.submitChoice(id, { action: 'fight', move: 0, target: 0 });
  };
  return play(events, {
    id: 'tr', mode: 'coop_pvp', seed: 3, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'a1', name: 'Ann', mons: [mn({ species: 'Alpha', maxHp: 300, spe: 90, types: [2],
        item: ['BERRY', 'HELD_BERRY', 12, 'BERRY'], moves: [thief(10)] })] },
      { playerId: 'a2', name: 'Abe', mons: [mn({ species: 'Gamma', maxHp: 300, spe: 80, types: [2],
        moves: [thief(10)] })] },
      { playerId: 'a3', name: 'Cal', mons: [mn({ species: 'Eta', maxHp: 300, atk: 200, spe: 70,
        types: [2], moves: [thief(60)] })] }],
      b: [{ playerId: 'b1', name: 'Bob', mons: [mn({ species: 'Beta', maxHp: 300, spe: 60, types: [2],
        item: ['CHARCOAL', 'HELD_FIRE_BOOST', 20, 'CHARCOAL'], moves: [hm('tap', 1)] })] },
      { playerId: 'b2', name: 'Bea', mons: [mn({ species: 'Delta', maxHp: 300, spe: 50, types: [2],
        item: ['FLOWER_MAIL', null, 0, 'FLOWER MAIL', true], moves: [hm('tap', 1)] })] },
      { playerId: 'b3', name: 'Bo', mons: [mn({ species: 'Zeta', maxHp: 5, spe: 40, types: [2],
        item: ['QUICK_CLAW', 'HELD_QUICK_CLAW', 100, 'QUICK CLAW'], moves: [hm('tap', 1)] })] }],
    },
  }, [round]);
});

scenario('berserk_gene', (events) => {
  const gene = ['BERSERK_GENE', null, 0, 'BERSERKGENE'];
  const rounds = [
    (b) => {
      b.submitChoice('p1', { action: 'fight', move: 0 });
      b.submitChoice('wild', { action: 'fight', move: 0 });
    },
    (b) => {
      b.submitChoice('p1', { action: 'switch', slot: 1 });
      b.submitChoice('wild', { action: 'fight', move: 1 });
    },
    (b) => {
      b.submitChoice('p1', { action: 'fight', move: 0 });
      b.submitChoice('wild', { action: 'fight', move: 1 });
    },
  ];
  return play(events, {
    id: 'bg2', mode: 'wild', seed: 2, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 300, spe: 90, types: [2], moves: [hm('tap', 1)] }),
        mn({ species: 'Gamma', maxHp: 300, spe: 80, types: [2], item: gene,
          moves: [hm('tap', 1)] })] }],
      b: [{ playerId: 'wild', name: 'Wild', mons: [mn({ species: 'Beta', maxHp: 300, spe: 10,
        types: [2], item: gene, moves: [hm('daze_ray', 0, 0, 49), hm('tap', 1)] })] }],
    },
  }, rounds);
});

scenario('metal_powder', (events) => {
  const powder = ['METAL_POWDER', 'HELD_METAL_POWDER', 0, 'METAL POWDER'];
  const round = (b) => {
    b.submitChoice('a1', { action: 'fight', move: 0, target: 3 });
    b.submitChoice('a2', { action: 'fight', move: 0, target: 4 });
    b.submitChoice('b1', { action: 'fight', move: 0, target: 0 });
    b.submitChoice('b2', { action: 'fight', move: 0, target: 1 });
  };
  return play(events, {
    id: 'mp', mode: 'coop_pvp', seed: 3, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'a1', name: 'Ann', family: 'crystal', mons: [mn({ species: 'Alpha', maxHp: 400,
        atk: 120, def: 200, spe: 90, types: [2], moves: [hm('thump', 40)] })] },
      { playerId: 'a2', name: 'Abe', mons: [mn({ species: 'Gamma', speciesId: 'DITTO', maxHp: 400,
        atk: 120, def: 60, spe: 80, types: [2], moves: [hm('thump', 40)] })] }],
      b: [{ playerId: 'b1', name: 'Bob', mons: [mn({ species: 'Beta', speciesId: 'DITTO', maxHp: 400,
        def: 60, spe: 60, types: [2], item: powder, moves: [hm('copycat', 0, 0, 57)] })] },
      { playerId: 'b2', name: 'Bea', mons: [mn({ species: 'Delta', speciesId: 'MEW', maxHp: 400,
        def: 60, spe: 50, types: [2], item: powder, moves: [hm('copycat', 0, 0, 57)] })] }],
    },
  }, repeat(round, 2));
});

scenario('species_items', (events) => {
  const rounds = [[0, 0], [1, 1]].map((picks) => (b) => {
    b.submitChoice('p1', { action: 'fight', move: picks[0] });
    b.submitChoice('p2', { action: 'fight', move: picks[1] });
  });
  return play(events, {
    id: 'si', mode: '1v1', seed: 3, choiceTimeout: 60, reconnectGrace: 60,
    specialTypes: [1],
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [mn({ species: 'Alpha', speciesId: 'PIKACHU', level: 30,
        maxHp: 600, atk: 100, spa: 100, def: 100, spd: 100, spe: 90, types: [2],
        item: ['LIGHT_BALL', null, 0, 'LIGHT BALL'], moves: [hm('zap', 40, 1), hm('thump', 40)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [mn({ species: 'Beta', speciesId: 'CUBONE', level: 30,
        maxHp: 600, atk: 600, spa: 100, def: 100, spd: 100, spe: 10, types: [2],
        item: ['THICK_CLUB', null, 0, 'THICK CLUB'], moves: [hm('thump', 40), hm('zap', 40, 1)] })] }],
    },
  }, rounds);
});

scenario('type_boost', (events) => {
  const round = (b) => {
    b.submitChoice('p1', { action: 'fight', move: 0 });
    b.submitChoice('p2', { action: 'fight', move: 0 });
  };
  return play(events, {
    id: 'tb', mode: '1v1', seed: 1, choiceTimeout: 60, reconnectGrace: 60,
    specialTypes: [1], typeIds: ['NORMAL', 'FIRE', 'WATER'],
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [mn({ species: 'Alpha', level: 30, maxHp: 600, atk: 100,
        spa: 100, def: 100, spd: 100, spe: 90, types: [2], confusion: 5,
        item: ['CHARCOAL', 'HELD_FIRE_BOOST', 20, 'CHARCOAL'], moves: [hm('ember_hit', 40, 1)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [mn({ species: 'Beta', level: 30, maxHp: 600, atk: 100,
        def: 100, spe: 10, types: [2], item: ['PINK_BOW', 'HELD_NORMAL_BOOST', 20, 'PINK BOW'],
        moves: [hm('thump', 40, 0, 0, 0)] })] }],
    },
  }, repeat(round, 3));
});

scenario('crit_items', (events) => {
  const round = (b) => {
    b.submitChoice('p1', { action: 'fight', move: 0 });
    b.submitChoice('p2', { action: 'fight', move: 0 });
  };
  const slash = hm('slash_hit', 20);
  slash.highCrit = true;
  return play(events, {
    id: 'ci', mode: '1v1', seed: 2, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [mn({ species: 'Alpha', speciesId: 'CHANSEY', maxHp: 900,
        spe: 90, types: [2], focusEnergy: true, item: ['LUCKY_PUNCH', null, 0, 'LUCKY PUNCH'],
        moves: [slash] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [mn({ species: 'Beta', maxHp: 900, spe: 10, types: [2],
        item: ['SCOPE_LENS', 'HELD_CRITICAL_UP', 0, 'SCOPE LENS'], moves: [hm('thump', 20)] })] }],
    },
  }, repeat(round, 6));
});

scenario('bright_powder', (events) => {
  const rounds = [1, 2, 3, 4, 5, 6].map((i) => (b) => {
    b.submitChoice('p1', { action: 'fight', move: i % 2 === 1 ? 0 : 1 });
    b.submitChoice('p2', { action: 'fight', move: 0 });
  });
  return play(events, {
    id: 'bp', mode: '1v1', seed: 1, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [mn({ species: 'Alpha', maxHp: 900, spe: 90, types: [2],
        moves: [hm('thump', 10), hm('star_dart', 10, 0, 17)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [mn({ species: 'Beta', maxHp: 900, spe: 10, types: [2],
        item: ['BRIGHTPOWDER', 'HELD_BRIGHTPOWDER', 120, 'BRIGHTPOWDER'], moves: [hm('tap', 1)] })] }],
    },
  }, rounds);
});

scenario('obey_traded', (events) => {
  const round = (b) => {
    b.submitChoice('p1', { action: 'fight', move: 0 });
    b.submitChoice('wild', { action: 'fight', move: 0 });
  };
  return play(events, {
    id: 'ob', mode: 'wild', seed: 660, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [mn({ species: 'Alpha', level: 80, maxHp: 900, atk: 60,
        def: 200, spe: 90, types: [2], traded: true,
        moves: [hm('thump', 10), hm('pound_two', 10), hm('pound_three', 10), hm('pound_four', 10)] })] }],
      b: [{ playerId: 'wild', name: 'Wild', mons: [mn({ species: 'Beta', level: 80, maxHp: 900, spe: 10,
        types: [2], moves: [hm('tap', 1)] })] }],
    },
  }, repeat(round, 8));
});

scenario('obey_asleep', (events) => {
  const round = (b) => {
    b.submitChoice('a1', { action: 'fight', move: 0, target: 3 });
    b.submitChoice('a2', { action: 'fight', move: 0, target: 3 });
    b.submitChoice('wild', { action: 'fight', move: 0, target: 0 });
  };
  return play(events, {
    id: 'oa', mode: 'coop_wild', seed: 5, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'a1', name: 'Ann', mons: [mn({ species: 'Alpha', level: 60, maxHp: 900, spe: 90,
        types: [2], status: 'SLP', statusTurns: 7, traded: true,
        moves: [hm('SNORE', 10), hm('thump', 10)] })] },
      { playerId: 'a2', name: 'Abe', mons: [mn({ species: 'Gamma', level: 60, maxHp: 900, spe: 80,
        types: [2], status: 'SLP', statusTurns: 7, traded: true,
        moves: [hm('SLEEP_TALK', 0), hm('thump', 10)] })] }],
      b: [{ playerId: 'wild', name: 'Wild', mons: [mn({ species: 'Beta', level: 60, maxHp: 900, spe: 10,
        types: [2], moves: [hm('tap', 1)] })] }],
    },
  }, repeat(round, 4));
});

scenario('obey_badges', (events) => {
  const round = (b) => {
    for (const id of ['a1', 'a2', 'a3']) b.submitChoice(id, { action: 'fight', move: 0, target: 3 });
    b.submitChoice('wild', { action: 'fight', move: 0, target: 0 });
  };
  const seat = (id, name, species, level, spe, badges) => ({
    playerId: id, name, badges, mons: [mn({ species, level,
      maxHp: 900, spe, types: [2], traded: true,
      moves: [hm('thump', 10), hm('pound_two', 10)] })],
  });
  return play(events, {
    id: 'obb', mode: 'coop_wild', seed: 1, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [seat('a1', 'Ann', 'Alpha', 100, 88, { RISING: true }),
        seat('a2', 'Abe', 'Gamma', 70, 90, { STORM: true, FOG: true, HIVE: true }),
        seat('a3', 'Cal', 'Eta', 75, 85, { STORM: true })],
      b: [{ playerId: 'wild', name: 'Wild', mons: [mn({ species: 'Beta', level: 50, maxHp: 900, spe: 10,
        types: [2], moves: [hm('tap', 1)] })] }],
    },
  }, repeat(round, 4));
});

scenario('obey_fallbacks', (events) => {
  const round = (b) => {
    for (const id of ['a1', 'a2', 'a3']) b.submitChoice(id, { action: 'fight', move: 0, target: 3 });
    b.submitChoice('wild', { action: 'fight', move: 0, target: 0 });
  };
  return play(events, {
    id: 'obf', mode: 'coop_wild', seed: 7, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'a1', name: 'Ann', mons: [mn({ species: 'Alpha', level: 80, maxHp: 900, spe: 90,
        types: [2], traded: true, moves: [hm('thump', 10)] })] },
      { playerId: 'a2', name: 'Abe', mons: [mn({ species: 'Gamma', level: 80, maxHp: 900, spe: 80,
        types: [2], traded: true, moves: [hm('thump', 10), hm('pound_two', 10, 0, 0, 0)] })] },
      { playerId: 'a3', name: 'Cal', mons: [mn({ species: 'Eta', level: 80, maxHp: 900, spe: 70,
        types: [2], traded: true, disable: { moveIndex: 2, turns: 9 },
        moves: [hm('thump', 10), hm('pound_two', 10)] })] }],
      b: [{ playerId: 'wild', name: 'Wild', mons: [mn({ species: 'Beta', level: 50, maxHp: 900, spe: 10,
        types: [2], moves: [hm('tap', 1)] })] }],
    },
  }, repeat(round, 6));
});

function obeyNever(mode, id) {
  return (events) => {
    const foe = mode === 'wild' ? 'wild' : 'p2';
    const round = (b) => {
      b.submitChoice('p1', { action: 'fight', move: 0 });
      b.submitChoice(foe, { action: 'fight', move: 0 });
    };
    return play(events, {
      id, mode, seed: 99, choiceTimeout: 60, reconnectGrace: 60,
      sides: {
        a: [{ playerId: 'p1', name: 'Ann', mons: [mn({ species: 'Alpha',
          level: mode === 'wild' ? 5 : 80, maxHp: 900, spe: 90, types: [2],
          traded: mode !== 'wild' ? true : undefined,
          moves: [hm('thump', 10), hm('pound_two', 10)] })] }],
        b: [{ playerId: foe, name: 'Bob', mons: [mn({ species: 'Beta', level: 80, maxHp: 900, spe: 10,
          types: [2], traded: true, moves: [hm('tap', 1), hm('pound_two', 1)] })] }],
      },
    }, repeat(round, 4));
  };
}
scenario('obey_link', obeyNever('1v1', 'ol'));
scenario('obey_side_b', obeyNever('wild', 'osb'));

// The review fixes (the Lua driver says what each one pins).
const duelRound = (foe) => (b) => {
  b.submitChoice('p1', { action: 'fight', move: 0 });
  b.submitChoice(foe, { action: 'fight', move: 0 });
};
const pick = (a, bMove) => (battle) => {
  battle.submitChoice('p1', { action: 'fight', move: a });
  battle.submitChoice('p2', { action: 'fight', move: bMove });
};

scenario('thief_substitute', (events) => play(events, {
  id: 'tsu', mode: 'wild', seed: 3, choiceTimeout: 60, reconnectGrace: 60,
  sides: {
    a: [{ playerId: 'p1', name: 'Ann', mons: [mn({ species: 'Alpha', maxHp: 300, spe: 90, types: [2],
      moves: [thief(10)] })] }],
    b: [{ playerId: 'wild', name: 'Wild', mons: [mn({ species: 'Beta', maxHp: 320, spe: 10, types: [2],
      substitute: 8, item: ['LEFTOVERS', 'HELD_LEFTOVERS', 0, 'LEFTOVERS'], moves: [hm('tap', 1)] })] }],
  },
}, repeat(duelRound('wild'), 4)));

scenario('thief_chance_miss', (events) => play(events, {
  id: 'tcm', mode: '1v1', seed: 153, choiceTimeout: 60, reconnectGrace: 60,
  sides: {
    a: [{ playerId: 'p1', name: 'Ann', mons: [mn({ species: 'Alpha', maxHp: 300, spe: 90, types: [2],
      moves: [thief(10)] })] }],
    b: [{ playerId: 'p2', name: 'Bob', mons: [mn({ species: 'Beta', maxHp: 400, spe: 10, types: [2],
      item: ['CHARCOAL', 'HELD_FIRE_BOOST', 20, 'CHARCOAL'], moves: [hm('tap', 1)] })] }],
  },
}, [duelRound('p2')]));

scenario('obey_bide', (events) => {
  const release = (b) => { b.submitChoice('wild', { action: 'fight', move: 0 }); };
  return play(events, {
    id: 'obb', mode: 'wild', seed: 2, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [mn({ species: 'Alpha', level: 80, maxHp: 900, spe: 90,
        types: [2], traded: true, bide: { turns: 0, stored: 40, moveIndex: 1, targetSlot: 3 },
        moves: [hm('BIDE', 0, 0, 26, 10), hm('tap', 10)] })] }],
      b: [{ playerId: 'wild', name: 'Wild', mons: [mn({ species: 'Beta', maxHp: 900, spe: 10, types: [2],
        moves: [hm('tap', 1)] })] }],
    },
  }, [release, duelRound('wild'), duelRound('wild')]);
});

scenario('bide_slot0', (events) => {
  const round = (b) => {
    b.submitChoice('a1', { action: 'fight', move: 0, target: 3 });
    b.submitChoice('a2', { action: 'fight', move: 0, target: 3 });
    b.submitChoice('b2', { action: 'fight', move: 0, target: 0 });
  };
  return play(events, {
    id: 'bs0', mode: 'coop_pvp', seed: 3, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'a1', name: 'Ann', mons: [mn({ species: 'Alpha', maxHp: 300, spe: 90, types: [2],
        moves: [hm('tap', 1)] })] },
      { playerId: 'a2', name: 'Abe', mons: [mn({ species: 'Gamma', maxHp: 300, spe: 80, types: [2],
        moves: [hm('tap', 1)] })] }],
      b: [{ playerId: 'b1', name: 'Bob', mons: [mn({ species: 'Beta', maxHp: 300, spe: 10, types: [2],
        bide: { turns: 0, stored: 30, moveIndex: 1, targetSlot: 0 },
        moves: [hm('BIDE', 0, 0, 26, 10), hm('tap', 1)] })] },
      { playerId: 'b2', name: 'Bea', mons: [mn({ species: 'Delta', maxHp: 300, spe: 20, types: [2],
        moves: [hm('tap', 1)] })] }],
    },
  }, [round]);
});

scenario('gate_para_confused', (events) => play(events, {
  id: 'gpc', mode: '1v1', seed: 5, choiceTimeout: 60, reconnectGrace: 60,
  sides: {
    a: [{ playerId: 'p1', name: 'Ann', mons: [mn({ species: 'Alpha', maxHp: 300, spe: 90, types: [2],
      status: 'PAR', confusion: 4, moves: [hm('thump', 10)] })] }],
    b: [{ playerId: 'p2', name: 'Bob', mons: [mn({ species: 'Beta', maxHp: 300, spe: 10, types: [2],
      moves: [hm('tap', 1)] })] }],
  },
}, repeat(duelRound('p2'), 4)));

scenario('gate_para_disabled', (events) => play(events, {
  id: 'gpd', mode: '1v1', seed: 9, choiceTimeout: 60, reconnectGrace: 60,
  sides: {
    a: [{ playerId: 'p1', name: 'Ann', mons: [mn({ species: 'Alpha', maxHp: 300, spe: 10, types: [2],
      status: 'PAR', moves: [hm('thump', 10), hm('pound_two', 10)] })] }],
    b: [{ playerId: 'p2', name: 'Bob', mons: [mn({ species: 'Beta', maxHp: 300, spe: 90, types: [2],
      moves: [hm('DISABLE', 0, 0, 86), hm('tap', 1)] })] }],
  },
}, [pick(0, 1), pick(0, 0), pick(1, 1)]));

scenario('mysteryberry_transformed', (events) => play(events, {
  id: 'mbt', mode: 'wild', seed: 5, choiceTimeout: 60, reconnectGrace: 60,
  sides: {
    a: [{ playerId: 'p1', name: 'Ann', mons: [mn({ species: 'Ditto', speciesId: 'DITTO', maxHp: 300,
      spe: 90, types: [2], item: ['MYSTERYBERRY', 'HELD_RESTORE_PP', 0, 'MYSTERYBERRY'],
      moves: [hm('TRANSFORM', 0, 0, 57, 10)] })] }],
    b: [{ playerId: 'wild', name: 'Wild', mons: [mn({ species: 'Beta', maxHp: 300, spe: 10, types: [2],
      moves: [hm('tap', 1, 0, 0, 1)] })] }],
  },
}, repeat(duelRound('wild'), 3)));

scenario('leftovers_large', (events) => play(events, {
  id: 'lol', mode: '1v1', seed: 4, choiceTimeout: 60, reconnectGrace: 60,
  sides: {
    a: [{ playerId: 'p1', name: 'Ann', mons: [mn({ species: 'Alpha', maxHp: 1100, hp: 500, spe: 90,
      types: [2], item: ['LEFTOVERS', 'HELD_LEFTOVERS', 0, 'LEFTOVERS'], moves: [hm('tap', 1)] })] }],
    b: [{ playerId: 'p2', name: 'Bob', mons: [mn({ species: 'Beta', maxHp: 300, spe: 10, types: [2],
      moves: [hm('tap', 1)] })] }],
  },
}, [duelRound('p2')]));

scenario('leech_seed_ko', (events) => play(events, {
  id: 'lsk', mode: '1v1', seed: 3, choiceTimeout: 60, reconnectGrace: 60,
  sides: {
    a: [{ playerId: 'p1', name: 'Ann', mons: [mn({ species: 'Alpha', maxHp: 300, hp: 100, spe: 90,
      types: [2], moves: [hm('tap', 1)] })] }],
    b: [{ playerId: 'p2', name: 'Bob', mons: [mn({ species: 'Beta', maxHp: 320, hp: 10, spe: 10,
      types: [2], leechSeed: { fromSlot: 0 }, moves: [hm('tap', 1)] })] }],
  },
}, repeat(duelRound('p2'), 2)));

scenario('rage', (events) => play(events, {
  id: 'rg', mode: '1v1', seed: 11, choiceTimeout: 60, reconnectGrace: 60,
  sides: {
    a: [{ playerId: 'p1', name: 'Ann', mons: [mn({ species: 'Alpha', maxHp: 500, spe: 90, types: [2],
      moves: [hm('RAGE', 20, 0, 81), hm('tap', 1)] })] }],
    b: [{ playerId: 'p2', name: 'Bob', mons: [mn({ species: 'Beta', maxHp: 900, spe: 10, types: [2],
      moves: [hm('pelt', 5, 0, 29), hm('tap', 1)] })] }],
  },
}, [pick(0, 0), pick(0, 1), pick(1, 0), pick(0, 0)]));

scenario('rage_cap', (events) => play(events, {
  id: 'rgc', mode: '1v1', seed: 21, choiceTimeout: 60, reconnectGrace: 60,
  sides: {
    a: [{ playerId: 'p1', name: 'Ann', mons: [mn({ species: 'Alpha', maxHp: 500, spe: 10, types: [2],
      raging: true, rageCounter: 254, substitute: 30,
      moves: [hm('RAGE', 20, 0, 81), hm('tap', 1)] })] }],
    b: [{ playerId: 'p2', name: 'Bob', mons: [mn({ species: 'Beta', maxHp: 999, spe: 90, types: [2],
      moves: [hm('pelt', 5, 0, 29)] })] }],
  },
}, repeat(duelRound('p2'), 2)));

scenario('rage_sources', (events) => play(events, {
  id: 'rgs', mode: '1v1', seed: 1, choiceTimeout: 60, reconnectGrace: 60,
  sides: {
    a: [{ playerId: 'p1', name: 'Ann', mons: [mn({ species: 'Alpha', maxHp: 500, spe: 90, types: [2],
      status: 'PSN', confusion: 3, moves: [hm('RAGE', 20, 0, 81), hm('tap', 1)] })] }],
    b: [{ playerId: 'p2', name: 'Bob', mons: [mn({ species: 'Beta', maxHp: 900, spe: 10, types: [2],
      moves: [hm('thump', 10)] })] }],
  },
}, repeat(duelRound('p2'), 4)));

scenario('side_effect_ko', (events) => {
  const round = (b) => {
    b.submitChoice('a1', { action: 'fight', move: 0, target: 3 });
    b.submitChoice('a2', { action: 'fight', move: 0, target: 4 });
    b.submitChoice('b1', { action: 'fight', move: 0, target: 0 });
    b.submitChoice('b2', { action: 'fight', move: 0, target: 1 });
  };
  return play(events, {
    id: 'sko', mode: 'coop_pvp', seed: 6, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'a1', name: 'Ann', mons: [mn({ species: 'Alpha', maxHp: 300, spe: 90, types: [2],
        moves: [hm('ember_hit', 40, 0, 4, undefined, 100)] })] },
      { playerId: 'a2', name: 'Abe', mons: [mn({ species: 'Gamma', maxHp: 300, spe: 80, types: [2],
        moves: [hm('daze_hit', 40, 0, 76, undefined, 100)] })] }],
      b: [{ playerId: 'b1', name: 'Bob', mons: [mn({ species: 'Beta', maxHp: 300, hp: 2, spe: 10,
        types: [2], moves: [hm('tap', 1)] })] },
      { playerId: 'b2', name: 'Bea', mons: [mn({ species: 'Delta', maxHp: 300, hp: 2, spe: 20,
        types: [2], moves: [hm('tap', 1)] })] }],
    },
  }, [round]);
});

// The carts' side-effect conditions (FX6), on a named chart: NORMAL 0,
// FIRE 1, ICE 2, ELECTRIC 3, POISON 4, BUG 5, STEEL 6.
const SIDE_TYPES = ['NORMAL', 'FIRE', 'ICE', 'ELECTRIC', 'POISON', 'BUG', 'STEEL'];

// Type immunities at 100%: Ann's Fire hit never burns Bob (Fire), Abe's Ice
// hit never freezes Bea (Ice), Bob's Bug Twineedle poisons Ann (Steel), and
// Bea's Electric hit paralyses Abe (Electric).
scenario('side_immunity', (events) => {
  const round = (b) => {
    b.submitChoice('a1', { action: 'fight', move: 0, target: 3 });
    b.submitChoice('a2', { action: 'fight', move: 0, target: 4 });
    b.submitChoice('b1', { action: 'fight', move: 0, target: 0 });
    b.submitChoice('b2', { action: 'fight', move: 0, target: 1 });
  };
  return play(events, {
    id: 'sim', mode: 'coop_pvp', seed: 12, choiceTimeout: 60, reconnectGrace: 60,
    typeIds: SIDE_TYPES,
    sides: {
      a: [{ playerId: 'a1', name: 'Ann', mons: [mn({ species: 'Alpha', maxHp: 300, spe: 90, types: [6],
        moves: [hm('ember_hit', 10, 1, 4, undefined, 100)] })] },
      { playerId: 'a2', name: 'Abe', mons: [mn({ species: 'Gamma', maxHp: 300, spe: 80, types: [3],
        moves: [hm('chill_hit', 10, 2, 5, undefined, 100)] })] }],
      b: [{ playerId: 'b1', name: 'Bob', mons: [mn({ species: 'Beta', maxHp: 300, spe: 20, types: [1],
        moves: [hm('needles', 10, 5, 77, undefined, 100)] })] },
      { playerId: 'b2', name: 'Bea', mons: [mn({ species: 'Delta', maxHp: 300, spe: 10, types: [2],
        moves: [hm('spark_hit', 10, 3, 6, undefined, 100)] })] }],
    },
  }, [round, round]);
});

// BurnTarget's Defrost: Ann's 10% Fire hit thaws Bob whatever its chance byte
// says, and Bob then takes his turn.
scenario('side_defrost', (events) => play(events, {
  id: 'sdf', mode: '1v1', seed: 4, choiceTimeout: 60, reconnectGrace: 60,
  typeIds: SIDE_TYPES,
  sides: {
    a: [{ playerId: 'p1', name: 'Ann', mons: [mn({ species: 'Alpha', maxHp: 300, spe: 90, types: [0],
      moves: [hm('ember_hit', 10, 1, 4, undefined, 10)] })] }],
    b: [{ playerId: 'p2', name: 'Bob', mons: [mn({ species: 'Beta', maxHp: 300, spe: 10, types: [0],
      status: 'FRZ', moves: [hm('tap', 1)] })] }],
  },
}, [duelRound('p2'), duelRound('p2')]));

// FlinchTarget: Ann's 100% flinch hit sets nothing on sleeping Bob, so the
// turn he wakes he acts; once awake he flinches.
scenario('side_flinch_sleep', (events) => play(events, {
  id: 'sfs', mode: '1v1', seed: 6, choiceTimeout: 60, reconnectGrace: 60,
  typeIds: SIDE_TYPES,
  sides: {
    a: [{ playerId: 'p1', name: 'Ann', mons: [mn({ species: 'Alpha', maxHp: 300, spe: 90, types: [0],
      moves: [hm('bite_hit', 10, 0, 31, undefined, 100)] })] }],
    b: [{ playerId: 'p2', name: 'Bob', mons: [mn({ species: 'Beta', maxHp: 300, spe: 10, types: [0],
      status: 'SLP', statusTurns: 2, moves: [hm('tap', 1)] })] }],
  },
}, repeat(duelRound('p2'), 3)));

// BattleCommand_StatDown's `.ComputerMiss`, wild: into Ann's substitute, after
// it breaks, and for GROWL; from -6 the routine stops before the byte.
scenario('computer_drops', (events) => {
  const pickWild = (move) => (b) => {
    b.submitChoice('p1', { action: 'fight', move: 0 });
    b.submitChoice('wild', { action: 'fight', move });
  };
  return play(events, {
    id: 'cdr', mode: 'wild', seed: 3, choiceTimeout: 60, reconnectGrace: 60,
    typeIds: SIDE_TYPES,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [mn({ species: 'Alpha', maxHp: 400, spe: 10, types: [0],
        substitute: 6, stages: { atk: -5 }, moves: [hm('wait', 0, 0, 85)] })] }],
      b: [{ playerId: 'wild', name: 'Wild', mons: [mn({ species: 'Beta', maxHp: 400, spe: 90, types: [0],
        moves: [hm('aurora_hit', 10, 2, 68, undefined, 30), hm('growl', 0, 0, 18)] })] }],
    },
  }, [0, 1, 0, 0, 0, 1, 0, 0, 0, 1].map(pickWild));
});

// ...and coop_npc, after a miss: Ann is under Mist (no byte), Abe is not (the
// byte after the missed accuracy byte).
scenario('computer_growl_miss', (events) => {
  const round = (b) => {
    b.submitChoice('a1', { action: 'fight', move: 0, target: 3 });
    b.submitChoice('a2', { action: 'fight', move: 0, target: 4 });
    b.submitChoice('n1', { action: 'fight', move: 0, target: 0 });
    b.submitChoice('n2', { action: 'fight', move: 0, target: 1 });
  };
  const growl = () => ({ id: 'growl', pp: 30, power: 0, accuracy: 1, type: 0, effect: 18, chance: 0 });
  return play(events, {
    id: 'cgm', mode: 'coop_npc', seed: 9, choiceTimeout: 60, reconnectGrace: 60,
    typeIds: SIDE_TYPES,
    sides: {
      a: [{ playerId: 'a1', name: 'Ann', mons: [mn({ species: 'Alpha', maxHp: 300, spe: 10, types: [0],
        mist: true, moves: [hm('wait', 0, 0, 85)] })] },
      { playerId: 'a2', name: 'Abe', mons: [mn({ species: 'Gamma', maxHp: 300, spe: 20, types: [0],
        moves: [hm('wait', 0, 0, 85)] })] }],
      b: [{ playerId: 'n1', name: 'Foe', mons: [mn({ species: 'Beta', maxHp: 300, spe: 90, types: [0],
        moves: [growl()] })] },
      { playerId: 'n2', name: 'Fay', mons: [mn({ species: 'Delta', maxHp: 300, spe: 80, types: [0],
        moves: [growl()] })] }],
    },
  }, [round, round]);
});

// ------------------------------------------------------------------
// the referee-gaps run (docs/plans/gen12-referee-gaps-fix.md, R2a): mirrored
// line for line from the Lua driver, which carries the notes.
// ------------------------------------------------------------------

// One seat a side; `rounds` is a list of [playerId, choice] lists, each
// submitted in order -- or 'tick', one second on the clock.
const duo = (id, mode, seed, aMons, bMons, extra = {}) => ({
  id, mode, seed, choiceTimeout: 60, reconnectGrace: 60,
  sides: {
    a: [{ playerId: 'p1', name: 'Ann', mons: aMons }],
    b: [{ playerId: 'p2', name: 'Bob', mons: bMons }],
  },
  typeIds: extra.typeIds,
  metronomePool: extra.metronomePool,
});
// R2b's duo: a chart and side a's badges too.
const duo2 = (id, mode, seed, aMons, bMons, extra = {}) => {
  const o = duo(id, mode, seed, aMons, bMons, extra);
  o.chart = extra.chart;
  o.sides.a[0].badges = extra.badges;
  return o;
};
// A round is a list of [playerId, choice] pairs, 'tick', or a function of the
// battle (R2b: a level-up between turns).
const seq = (events, opts, rounds) => play(events, opts, rounds.map((list) => {
  if (typeof list === 'function') return (b) => list(b, events);
  if (list === 'tick') return (b) => { b.tick(b.now + 1); };
  return (b) => { for (const [id, choice] of list) b.submitChoice(id, choice); };
}));
const F = (i) => ({ action: 'fight', move: i });
const S = (slot) => ({ action: 'switch', slot });
const both = (a, b) => [['p1', a], ['p2', b]];

scenario('gold_stat_hits', (events) => seq(events, duo('gsh', 'wild', 501,
  [mn({ species: 'Alpha', maxHp: 400, def: 999, spe: 90, stages: { atk: 5 },
    moves: [hm('CRUNCH', 20, 0, 87, 60, 100), hm('METAL_CLAW', 20, 0, 89, 60, 100),
      hm('ANCIENTPOWER', 20, 0, 91, 60, 100), hm('STEEL_WING', 20, 0, 90, 60, 100)] })],
  [mn({ species: 'Beta', maxHp: 900, spe: 10, moves: [hm('MUD_SLAP', 5, 0, 88, 60, 100)] })]),
[both(F(0), F(0)), both(F(1), F(0)), both(F(2), F(0)), both(F(3), F(0))]));

scenario('flame_wheel_thaw', (events) => seq(events, duo('fwt', '1v1', 502,
  [mn({ species: 'Alpha', maxHp: 400, spe: 90, status: 'FRZ', types: [0],
    moves: [hm('FLAME_WHEEL', 30, 1, 92, 60, 100)] })],
  [mn({ species: 'Beta', maxHp: 400, spe: 10, status: 'FRZ', types: [0],
    moves: [hm('SACRED_FIRE', 30, 1, 93, 60, 100)] })],
  { typeIds: SIDE_TYPES }),
[both(F(0), F(0)), both(F(0), F(0))]));

scenario('stomp_minimize', (events) => seq(events, duo('stm', '1v1', 503,
  [mn({ species: 'Alpha', maxHp: 500, spe: 90, moves: [hm('MINIMIZE', 0, 0, 15)] }),
    mn({ species: 'Gamma', maxHp: 500, spe: 90, moves: [hm('tap', 1)] })],
  [mn({ species: 'Beta', maxHp: 500, spe: 10, moves: [hm('STOMP', 40, 0, 94, 60, 30)] })]),
[both(F(0), F(0)), both(F(0), F(0)), both(S(1), F(0))]));

scenario('twister_fly', (events) => seq(events, duo('twf', '1v1', 504,
  [mn({ species: 'Alpha', maxHp: 900, spe: 90,
    moves: [hm('FLY', 30, 0, 43), hm('DIG', 30, 0, 43)] })],
  [mn({ species: 'Beta', maxHp: 900, spe: 10,
    moves: [hm('TWISTER', 20, 0, 95, 60, 20), hm('GUST', 20, 0, 99),
      hm('EARTHQUAKE', 20, 0, 100), hm('THUNDER', 20, 0, 97, 60, 100)] })]),
[both(F(0), F(0)), both(F(0), F(1)), both(F(1), F(2)), both(F(1), F(1)),
  both(F(0), F(3))]));

scenario('snore_sky_attack', (events) => seq(events, duo('ssa', '1v1', 505,
  [mn({ species: 'Alpha', maxHp: 400, spe: 90, item: ['KINGS_ROCK', 'HELD_FLINCH', 30, "KING'S ROCK"],
    moves: [hm('SNORE', 20, 0, 96, 60, 30), hm('SKY_ATTACK', 40, 0, 101, 60, 30)] })],
  [mn({ species: 'Beta', maxHp: 900, spe: 10, moves: [hm('tap', 1)] })]),
[both(F(0), F(0)), both(F(1), F(0)), both(F(1), F(0)), both(F(0), F(0))]));

scenario('tri_attack', (events) => {
  const quiet = hm('wait', 0, 0, 85);
  return seq(events, duo('tri', '1v1', 506,
    [mn({ species: 'Alpha', maxHp: 400, spe: 90, types: [0],
      moves: [hm('TRI_ATTACK', 10, 0, 98, 60, 100)] })],
    [mn({ species: 'Beta', maxHp: 999, spe: 10, status: 'FRZ', types: [2], moves: [quiet] })],
    { typeIds: SIDE_TYPES }),
  [both(F(0), F(0)), both(F(0), F(0)), both(F(0), F(0)), both(F(0), F(0)),
    both(F(0), F(0)), both(F(0), F(0))]);
});

scenario('effectchance_miss', (events) => {
  const wild = { id: 'wild_flame', pp: 60, power: 40, accuracy: 1, type: 1, effect: 4, chance: 10 };
  return seq(events, duo('ecm', '1v1', 507,
    [mn({ species: 'Alpha', maxHp: 400, spe: 90, moves: [wild] })],
    [mn({ species: 'Beta', maxHp: 400, spe: 10,
      moves: [hm('wait', 0, 0, 85), hm('SUBSTITUTE', 0, 0, 79), hm('FLY', 30, 0, 43)] })]),
  [both(F(0), F(0)), both(F(0), F(2)), [['p1', F(0)]], both(F(0), F(1)), both(F(0), F(0))]);
});

scenario('multi_hit_draws', (events) => seq(events, duo('mhd', '1v1', 508,
  [mn({ species: 'Alpha', maxHp: 400, spe: 90, focusEnergy: true,
    moves: [hm('fury_hits', 15, 0, 29), hm('twin_hits', 25, 0, 44), hm('TWINEEDLE', 25, 0, 77, 60, 20)] })],
  [mn({ species: 'Beta', maxHp: 999, spe: 10, types: [0], moves: [hm('tap', 1)] })],
  { typeIds: SIDE_TYPES }),
[both(F(0), F(0)), both(F(0), F(0)), both(F(1), F(0)), both(F(2), F(0)), both(F(2), F(0))]));

scenario('multi_hit_first_ko', (events) => seq(events, duo('mfk', '1v1', 509,
  [mn({ species: 'Alpha', maxHp: 400, spe: 90, moves: [hm('fury_hits', 15, 0, 29)] })],
  [mn({ species: 'Beta', maxHp: 400, hp: 1, spe: 10, moves: [hm('tap', 1)] }),
    mn({ species: 'Delta', maxHp: 400, spe: 10, moves: [hm('tap', 1)] })]),
[both(F(0), F(0)), [['p2', S(1)]], both(F(0), F(0))]));

scenario('leech_seed_eighth', (events) => {
  const seeded = mn({ species: 'Beta', maxHp: 400, spe: 10, substitute: 50,
    leechSeed: { fromSlot: 0 }, moves: [hm('wait', 0, 0, 85)] });
  return seq(events, duo('lse', '1v1', 510,
    [mn({ species: 'Alpha', maxHp: 400, hp: 100, spe: 90, moves: [hm('wait', 0, 0, 85)] })],
    [seeded]),
  [both(F(0), F(0)), both(F(0), F(0))]);
});

scenario('no_999_cap', (events) => seq(events, duo('n9c', '1v1', 511,
  [mn({ species: 'Alpha', level: 100, maxHp: 9000, atk: 255, spe: 90, types: [0],
    moves: [hm('crush', 250, 0, 0)] })],
  [mn({ species: 'Beta', level: 100, maxHp: 9000, def: 1, spe: 10, types: [0],
    moves: [hm('BIDE', 0, 0, 26)] })]),
[both(F(0), F(0)), both(F(0), F(0)), both(F(0), F(0)), both(F(0), F(0))]));

scenario('recoil_substitute', (events) => seq(events, duo('rcs', '1v1', 512,
  [mn({ species: 'Alpha', maxHp: 400, spe: 90, substitute: 50,
    moves: [hm('TAKE_DOWN', 40, 0, 48)] })],
  [mn({ species: 'Beta', maxHp: 400, spe: 10, substitute: 200, moves: [hm('wait', 0, 0, 85)] })]),
[both(F(0), F(0)), both(F(0), F(0))]));

scenario('rampage_zero_pp', (events) => seq(events, duo('rzp', '1v1', 513,
  [mn({ species: 'Alpha', maxHp: 900, spe: 90, moves: [hm('THRASH', 20, 0, 27, 1)] }),
    mn({ species: 'Gamma', maxHp: 900, spe: 90, status: 'PAR', moves: [hm('THRASH', 20, 0, 27, 5)] })],
  [mn({ species: 'Beta', maxHp: 999, spe: 10, moves: [hm('tap', 1)] })]),
[both(F(0), F(0)), both(F(0), F(0)), both(F(0), F(0)), both(F(0), F(0)),
  both(S(1), F(0)), both(F(0), F(0)), both(F(0), F(0)), both(F(0), F(0))]));

scenario('mirror_move_last_used', (events) => seq(events, duo('mml', '1v1', 514,
  [mn({ species: 'Alpha', maxHp: 600, spe: 10, moves: [hm('MIRROR_MOVE', 0, 0, 9), hm('tap', 1)] })],
  [mn({ species: 'Beta', maxHp: 600, spe: 90, moves: [hm('METRONOME', 0, 0, 83), hm('tap', 1)] }),
    mn({ species: 'Delta', maxHp: 600, spe: 90, moves: [hm('tap', 1)] })],
  { metronomePool: [hm('pool_hit', 30, 0, 0)] }),
[both(F(0), F(0)), both(F(0), F(1)), both(F(0), S(1))]));

scenario('metronome_charge', (events) => seq(events, duo('mtc', '1v1', 515,
  [mn({ species: 'Alpha', maxHp: 600, spe: 90, moves: [hm('METRONOME', 0, 0, 83)] })],
  [mn({ species: 'Beta', maxHp: 600, spe: 10, moves: [hm('MIRROR_MOVE', 0, 0, 9)] })],
  { metronomePool: [hm('FLY', 30, 0, 43)] }),
[both(F(0), F(0)), 'tick', both(F(0), F(0))]));

scenario('metronome_bide', (events) => seq(events, duo('mtb', '1v1', 518,
  [mn({ species: 'Alpha', maxHp: 600, spe: 90, moves: [hm('METRONOME', 0, 0, 83)] })],
  [mn({ species: 'Beta', maxHp: 600, atk: 90, spe: 10, moves: [hm('thump', 40)] })],
  { metronomePool: [hm('BIDE', 0, 0, 26)] }),
[both(F(0), F(0)), [['p2', F(0)]], [['p2', F(0)]], [['p2', F(0)]], both(F(0), F(0))]));

const payDayFight = (id, mode) => (events) => seq(events, duo(id, mode, 516,
  [mn({ species: 'Alpha', level: 30, maxHp: 400, atk: 90, spe: 90, moves: [hm('PAY_DAY', 40, 0, 16)] })],
  [mn({ species: 'Beta', level: 140, maxHp: 60, spe: 10, moves: [hm('PAY_DAY', 1, 0, 16)] })]),
[both(F(0), F(0)), both(F(0), F(0)), both(F(0), F(0)), both(F(0), F(0))]);
scenario('pay_day_wild', payDayFight('pdw', 'wild'));
scenario('pay_day_link', payDayFight('pdl', '1v1'));

scenario('hyper_beam_recharge', (events) => seq(events, duo('hbr', '1v1', 517,
  [mn({ species: 'Alpha', maxHp: 600, atk: 90, spe: 90, moves: [hm('HYPER_BEAM', 150, 0, 80), hm('tap', 1)] })],
  [mn({ species: 'Beta', maxHp: 20, spe: 10, moves: [hm('tap', 1)] }),
    mn({ species: 'Delta', maxHp: 600, spe: 10, moves: [hm('SUBSTITUTE', 0, 0, 79), hm('wait', 0, 0, 85)] })]),
[both(F(0), F(0)), [['p2', S(1)]], [['p2', F(0)]], both(F(0), F(1)), [['p2', F(1)]]]));

// ------------------------------------------------------------------
// the referee-gaps run's wave 2 (R2b): mirrored line for line from the Lua
// driver, which carries the notes.
// ------------------------------------------------------------------

const R2B_TYPES = ['NORMAL', 'FIRE', 'ICE', 'ELECTRIC', 'POISON', 'GRASS', 'STEEL', 'GROUND'];
const R2B_CHART = [];
for (let i = 0; i < 8; i += 1) R2B_CHART.push([100, 100, 100, 100, 100, 100, 100, 100]);
R2B_CHART[4][6] = 0;
R2B_CHART[3][7] = 0;
const R2B = { typeIds: R2B_TYPES, chart: R2B_CHART };
const am = (id, power, type, effect, accuracy, chance, priority) => ({
  id, pp: 60, power, accuracy, type: type || 0, effect: effect || 0, chance: chance || 0, priority,
});

scenario('r2b_transform', (events) => seq(events, duo2('r2t', '1v1', 601,
  [mn({ species: 'Alpha', maxHp: 400, atk: 50, spe: 90, types: [0],
    moves: [hm('TRANSFORM', 0, 0, 57, 10), hm('tap', 1)] }),
  mn({ species: 'Gamma', maxHp: 400, spe: 20, moves: [hm('tap', 1)] })],
  [mn({ species: 'Beta', maxHp: 600, atk: 120, def: 70, spe: 60, types: [1],
    substitute: 40, stages: { atk: 2 },
    moves: [hm('SKETCH', 0, 0, 0), hm('slam', 40, 1, 0), hm('TRANSFORM', 0, 0, 57),
      hm('CONFUSE_RAY', 0, 0, 49)] })],
  R2B),
[both(F(0), F(3)), both(F(1), F(1)), both(S(1), F(1)), both(S(0), F(1)), both(F(0), F(2))]));

scenario('r2b_haze_2v2', (events) => {
  const staged = (name, spe, first) => mn({
    species: name, maxHp: 400, spe, stages: { atk: 2, def: -1 },
    moves: [first, hm('GROWTH', 0, 0, 10)],
  });
  const round = (i) => (b) => {
    b.submitChoice('a1', F(i)); b.submitChoice('a2', F(i));
    b.submitChoice('b1', F(i)); b.submitChoice('b2', F(i));
  };
  return play(events, {
    id: 'r2h', mode: 'coop_pvp', seed: 602, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'a1', name: 'Ann', mons: [staged('Alpha', 90, hm('HAZE', 0, 0, 25))] },
        { playerId: 'a2', name: 'Abe', mons: [staged('Gamma', 70, hm('wait', 0, 0, 85))] }],
      b: [{ playerId: 'b1', name: 'Bob', mons: [staged('Beta', 60, hm('wait', 0, 0, 85))] },
        { playerId: 'b2', name: 'Bea', mons: [staged('Delta', 50, hm('wait', 0, 0, 85))] }],
    },
  }, [round(0), round(1)]);
});

scenario('r2b_switch_in_stats', (events) => seq(events, duo2('r2s', 'wild', 603,
  [mn({ species: 'Alpha', maxHp: 400, spe: 10, moves: [hm('tap', 1)] }),
    mn({ species: 'Gamma', maxHp: 400, spe: 15, status: 'PAR',
      moves: [hm('tap', 1), hm('GROWTH', 0, 0, 10)] })],
  [mn({ species: 'Beta', maxHp: 900, spe: 4, moves: [hm('tap', 1)] })],
  { badges: { PLAIN: true } }),
[both(S(1), F(0)), both(F(0), F(0)), both(F(1), F(0)), both(F(0), F(0)), both(F(0), F(0))]));

scenario('r2b_switch_in_computer', (events) => seq(events, duo2('r2c', 'coop_npc', 604,
  [mn({ species: 'Alpha', maxHp: 400, atk: 120, spe: 30, moves: [hm('slam', 40)] })],
  [mn({ species: 'Beta', maxHp: 400, hp: 1, spe: 10, moves: [hm('tap', 1)] }),
    mn({ species: 'Delta', maxHp: 400, spe: 80, status: 'PAR', moves: [hm('tap', 1)] })]),
[both(F(0), F(0)), [['p2', S(1)]], both(F(0), F(0)), both(F(0), F(0))]));

scenario('r2b_sleep_talk', (events) => seq(events, duo2('r2l', '1v1', 605,
  [mn({ species: 'Alpha', maxHp: 400, spe: 90, status: 'SLP', statusTurns: 6,
    disable: { moveIndex: 3, turns: 8 },
    moves: [hm('SLEEP_TALK', 0, 0, 102), hm('FLY', 30, 0, 43), hm('thump', 40), hm('kick', 20)] }),
  mn({ species: 'Gamma', maxHp: 400, spe: 90, moves: [hm('SLEEP_TALK', 0, 0, 102), hm('tap', 1)] }),
  mn({ species: 'Eps', maxHp: 400, spe: 90, status: 'SLP', statusTurns: 6,
    moves: [hm('SLEEP_TALK', 0, 0, 102)] })],
  [mn({ species: 'Beta', maxHp: 900, spe: 10, moves: [hm('tap', 1)] })]),
[both(F(0), F(0)), both(F(0), F(0)), both(S(1), F(0)), both(F(0), F(0)),
  both(S(2), F(0)), both(F(0), F(0))]));

scenario('r2b_snore_asleep', (events) => seq(events, duo2('r2n', '1v1', 606,
  [mn({ species: 'Alpha', maxHp: 400, spe: 90, status: 'SLP', statusTurns: 7,
    item: ['KINGS_ROCK', 'HELD_FLINCH', 128, "KING'S ROCK"],
    moves: [hm('SNORE', 20, 0, 96, 60, 30)] })],
  [mn({ species: 'Beta', maxHp: 900, spe: 10, moves: [hm('tap', 1)] })]),
[both(F(0), F(0)), both(F(0), F(0)), both(F(0), F(0)), both(F(0), F(0))]));

scenario('r2b_mysteryberry_party', (events) => seq(events, duo2('r2m', '1v1', 607,
  [mn({ species: 'Alpha', maxHp: 400, spe: 90,
    item: ['MYSTERYBERRY', 'HELD_RESTORE_PP', 5, 'MYSTERYBERRY'],
    moves: [hm('TRANSFORM', 0, 0, 57, 10), hm('tap', 1, 0, 0, 0)] }),
  mn({ species: 'Gamma', maxHp: 400, spe: 20, moves: [hm('tap', 1)] })],
  [mn({ species: 'Beta', maxHp: 600, spe: 60, moves: [hm('slam', 40, 0, 0, 30)] })]),
[both(F(0), F(0)), both(S(1), F(0)), both(S(0), F(0))]));

scenario('r2b_replace_items', (events) => seq(events, duo2('r2r', '1v1', 608,
  [mn({ species: 'Alpha', maxHp: 400, atk: 200, spe: 90, moves: [hm('slam', 80)] })],
  [mn({ species: 'Beta', maxHp: 400, hp: 5, spe: 10, moves: [hm('tap', 1)] }),
    mn({ species: 'Delta', maxHp: 400, hp: 40, spe: 10, status: 'FRZ',
      item: ['LEFTOVERS', 'HELD_LEFTOVERS', 0, 'LEFTOVERS'], moves: [hm('tap', 1)] })]),
[both(F(0), F(0)), [['p2', S(1)]], both(F(0), F(0)), both(F(0), F(0))]));

scenario('r2b_quick_claw_forced', (events) => seq(events, duo2('r2q', '1v1', 609,
  [mn({ species: 'Alpha', maxHp: 600, atk: 60, spe: 10,
    item: ['QUICK_CLAW', 'HELD_QUICK_CLAW', 200, 'QUICK CLAW'],
    moves: [hm('HYPER_BEAM', 150, 0, 80), hm('BIDE', 0, 0, 26)] })],
  [mn({ species: 'Beta', maxHp: 900, spe: 50, moves: [hm('tap', 1)] })]),
[both(F(0), F(0)), [['p2', F(0)]], both(F(1), F(0)), [['p2', F(0)]], [['p2', F(0)]],
  [['p2', F(0)]]]));

scenario('r2b_bright_powder', (events) => seq(events, duo2('r2p', '1v1', 610,
  [mn({ species: 'Alpha', level: 50, maxHp: 400, spe: 90,
    moves: [am('tap', 10, 0, 0, 100), am('GUILLOTINE', 0, 0, 38, 30)] })],
  [mn({ species: 'Beta', level: 40, maxHp: 900, spe: 10,
    item: ['BRIGHTPOWDER', 'HELD_BRIGHTPOWDER', 20, 'BRIGHTPOWDER'],
    moves: [am('tap', 1, 0, 0, 100), am('GUILLOTINE', 0, 0, 38, 30)] })]),
[both(F(0), F(0)), both(F(0), F(0)), both(F(0), F(0)), both(F(1), F(1)), both(F(1), F(1)),
  both(F(1), F(1)), both(F(1), F(1))]));

scenario('r2b_held_prevent', (events) => seq(events, duo2('r2v', '1v1', 611,
  [mn({ species: 'Alpha', maxHp: 400, spe: 90, types: [0],
    moves: [hm('HYPNOSIS', 0, 0, 32), hm('EMBER', 10, 1, 4, 60, 100), hm('CONFUSE_RAY', 0, 0, 49)] })],
  [mn({ species: 'Beta', maxHp: 400, spe: 10, item: ['GUARD_A', 'HELD_PREVENT_SLEEP', 0, 'GUARD A'],
    moves: [hm('tap', 1)] }),
  mn({ species: 'Delta', maxHp: 400, spe: 10, item: ['GUARD_B', 'HELD_PREVENT_BURN', 0, 'GUARD B'],
    moves: [hm('tap', 1)] }),
  mn({ species: 'Eps', maxHp: 400, spe: 10, item: ['GUARD_C', 'HELD_PREVENT_CONFUSE', 0, 'GUARD C'],
    moves: [hm('tap', 1)] })],
  R2B),
[both(F(0), F(0)), both(F(1), S(1)), both(F(2), S(2))]));

scenario('r2b_lock_on', (events) => seq(events, duo2('r2o', '1v1', 612,
  [mn({ species: 'Alpha', maxHp: 600, spe: 10,
    moves: [am('LOCK_ON', 0, 0, 103, 100), am('wild_hit', 20, 0, 0, 1),
      am('EARTHQUAKE', 30, 0, 100, 100), am('tap', 1, 0, 0, 100)] })],
  [mn({ species: 'Beta', maxHp: 900, spe: 90,
    moves: [hm('tap', 1), hm('FLY', 30, 0, 43), hm('SUBSTITUTE', 0, 0, 79)] })]),
[both(F(0), F(0)), both(F(1), F(0)), both(F(1), F(0)), both(F(0), F(0)), both(F(2), F(1)),
  [['p1', F(3)]], both(F(0), F(2))]));

scenario('r2b_safeguard', (events) => seq(events, duo2('r2g', '1v1', 613,
  [mn({ species: 'Alpha', maxHp: 600, spe: 90, types: [0],
    moves: [hm('SAFEGUARD', 0, 0, 104), hm('THRASH', 20, 0, 27), hm('tap', 1)] })],
  [mn({ species: 'Beta', maxHp: 900, spe: 10,
    moves: [hm('HYPNOSIS', 0, 0, 32), hm('EMBER', 10, 1, 4, 60, 100), hm('tap', 1)] })],
  R2B),
[both(F(0), F(0)), both(F(0), F(1)), both(F(1), F(2)), [['p2', F(2)]], [['p2', F(2)]],
  both(F(2), F(2)), both(F(2), F(0))]));

scenario('r2b_stat_down_lines', (events) => seq(events, duo2('r2d', '1v1', 614,
  [mn({ species: 'Alpha', maxHp: 400, spe: 90,
    moves: [am('GROWL', 0, 0, 18, 100), am('faint_growl', 0, 0, 18, 1)] })],
  [mn({ species: 'Beta', maxHp: 400, spe: 10, mist: true, moves: [hm('tap', 1)] }),
    mn({ species: 'Zeta', maxHp: 400, atk: 1, spe: 10, moves: [hm('tap', 1)] })]),
[both(F(0), F(0)), both(F(1), F(0)), both(F(0), S(1)), both(F(1), F(0))]));

scenario('r2b_stat_down_sub', (events) => seq(events, duo2('r2d2', '1v1', 624,
  [mn({ species: 'Alpha', maxHp: 400, spe: 90, moves: [am('GROWL', 0, 0, 18, 100)] })],
  [mn({ species: 'Delta', maxHp: 400, spe: 10, substitute: 50, moves: [hm('tap', 1)] })]),
[both(F(0), F(0))]));

scenario('r2b_stat_down_floor', (events) => seq(events, duo2('r2d3', '1v1', 625,
  [mn({ species: 'Alpha', maxHp: 400, spe: 90, moves: [am('GROWL', 0, 0, 18, 100)] })],
  [mn({ species: 'Eps', maxHp: 400, spe: 10, substitute: 50, stages: { atk: -6 },
    moves: [hm('tap', 1)] })]),
[both(F(0), F(0))]));

scenario('r2b_priority_sheet', (events) => seq(events, duo2('r2y', '1v1', 615,
  [mn({ species: 'Alpha', maxHp: 400, spe: 10,
    moves: [am('jab', 10, 0, 0, 100, 0, 2), am('QUICK_ATTACK', 10, 0, 0, 100, 0, 1)] })],
  [mn({ species: 'Beta', maxHp: 400, spe: 90, moves: [hm('tap', 1)] })]),
[both(F(0), F(0)), both(F(1), F(0))]));

scenario('r2b_level_up', (events) => {
  const up = (...args) => (b, list) => {
    const ok = b.levelUp(...args);
    list.push({ t: 'levelUp', text: String(ok) });
  };
  return seq(events, duo2('r2u', 'wild', 616,
    [mn({ species: 'Alpha', level: 20, maxHp: 100, hp: 60, spe: 40, moves: [hm('tap', 1)] }),
      mn({ species: 'Gamma', level: 10, maxHp: 50, spe: 5, moves: [hm('tap', 1)],
        base: { hp: 60, atk: 60, def: 60, spe: 90, spa: 60, spd: 60 },
        dvs: { atk: 15, def: 14, spe: 13, spc: 12 } })],
    [mn({ species: 'Beta', level: 20, maxHp: 900, spe: 50, moves: [hm('tap', 1)] })],
    { badges: { PLAIN: true } }),
  [both(F(0), F(0)), up('p1', 1, 21, { atk: 45, def: 45, spe: 60, spa: 45, spd: 45 }, 110),
    both(F(0), F(0)), up('p1', 2, 30), up('p1', 1, 5), both(S(1), F(0)), both(F(0), F(0))]);
});

scenario('r2b_defrost', (events) => seq(events, duo2('r2f', '1v1', 617,
  [mn({ species: 'Alpha', maxHp: 400, spe: 90, status: 'FRZ', types: [0], moves: [hm('tap', 1)] })],
  [mn({ species: 'Beta', maxHp: 900, spe: 10, moves: [hm('ice_hit', 5, 2, 5, 60, 100)] })],
  R2B),
Array.from({ length: 10 }, () => both(F(0), F(0)))));

scenario('r2b_drain', (events) => seq(events, duo2('r2e', '1v1', 618,
  [mn({ species: 'Alpha', maxHp: 400, hp: 100, spe: 90,
    moves: [hm('LEECH_LIFE', 20, 0, 3), hm('DREAM_EATER', 100, 0, 8)] })],
  [mn({ species: 'Beta', maxHp: 400, spe: 10, substitute: 100, moves: [hm('tap', 1)] }),
    mn({ species: 'Delta', maxHp: 400, hp: 1, spe: 10, moves: [hm('tap', 1)] })]),
[both(F(0), F(0)), both(F(1), F(0)), both(F(0), S(1))]));

scenario('r2b_toxic', (events) => seq(events, duo2('r2x', '1v1', 619,
  [mn({ species: 'Alpha', maxHp: 400, spe: 90, moves: [am('TOXIC', 0, 4, 105, 100)] })],
  [mn({ species: 'Beta', maxHp: 160, spe: 10, types: [0], moves: [hm('tap', 1)] }),
    mn({ species: 'Delta', maxHp: 400, spe: 10, types: [4], moves: [hm('tap', 1)] }),
    mn({ species: 'Eps', maxHp: 400, spe: 10, types: [6], moves: [hm('tap', 1)] })],
  R2B),
[both(F(0), F(0)), both(F(0), F(0)), both(F(0), S(1)), both(F(0), S(0)), both(F(0), S(2))]));

scenario('r2b_leech_grass', (events) => seq(events, duo2('r2s2', '1v1', 620,
  [mn({ species: 'Alpha', maxHp: 400, spe: 90, moves: [hm('LEECH_SEED', 0, 5, 84)] })],
  [mn({ species: 'Beta', maxHp: 400, spe: 10, types: [5], moves: [hm('tap', 1)] }),
    mn({ species: 'Delta', maxHp: 400, spe: 10, types: [0], moves: [hm('tap', 1)] })],
  R2B),
[both(F(0), F(0)), both(F(0), S(1))]));

scenario('r2b_stat_up_999', (events) => seq(events, duo2('r2z', '1v1', 621,
  [mn({ species: 'Alpha', maxHp: 400, atk: 999, spe: 90,
    moves: [hm('SWORDS_DANCE', 0, 0, 50), hm('MEDITATE', 0, 0, 10)] })],
  [mn({ species: 'Beta', maxHp: 400, spe: 10, moves: [hm('tap', 1)] })]),
[both(F(0), F(0)), both(F(1), F(0))]));

scenario('r2b_bide_gates', (events) => seq(events, duo2('r2b', '1v1', 622,
  [mn({ species: 'Alpha', maxHp: 600, spe: 90, moves: [hm('BIDE', 0, 0, 26)] })],
  [mn({ species: 'Beta', maxHp: 600, atk: 90, spe: 10,
    moves: [hm('thump', 40), hm('CONFUSE_RAY', 0, 0, 49)] })]),
[both(F(0), F(1)), [['p2', F(0)]], [['p2', F(0)]], both(F(0), F(0)), [['p2', F(0)]],
  [['p2', F(0)]]]));

scenario('r2b_hit_ko', (events) => seq(events, duo2('r2k', '1v1', 623,
  [mn({ species: 'Alpha', maxHp: 400, atk: 90, spe: 90, moves: [hm('DOUBLE_KICK', 30, 0, 44)] })],
  [mn({ species: 'Beta', maxHp: 400, hp: 30, spe: 10, moves: [hm('tap', 1)] }),
    mn({ species: 'Delta', maxHp: 400, spe: 10, moves: [hm('tap', 1)] })]),
[both(F(0), F(0)), [['p2', S(1)]], both(F(0), F(0))]));

scenario('r2b_metronome_known', (events) => seq(events, duo2('r2w', '1v1', 626,
  [mn({ species: 'Alpha', maxHp: 400, spe: 90, moves: [hm('METRONOME', 0, 0, 83), hm('tap', 1)] }),
    mn({ species: 'Gamma', maxHp: 400, spe: 90,
      moves: [hm('METRONOME', 0, 0, 83), hm('tap', 1), hm('kick', 20)] })],
  [mn({ species: 'Beta', maxHp: 900, spe: 10, moves: [hm('tap', 1)] })],
  { metronomePool: [hm('tap', 1), hm('kick', 20)] }),
[both(F(0), F(0)), both(F(0), F(0)), both(F(0), F(0)), both(S(1), F(0)), both(F(0), F(0))]));

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
  // Contract K11: Pay Day's coins on side a's win against the computer.
  if (out.payDay) slim.payDay = out.payDay;
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
  assert.strictEqual(jsRuns.length, 103, 'the JS half built every scenario');
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
  assert.strictEqual(solicit.slot, 3, 'naming the seat that owes');

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
  const replacement = run.events.find((e) => e.t === 'switch' && e.slot === 3);
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
  battle.submitChoice('a1', { action: 'fight', move: 0, target: 3 });
  battle.submitChoice('a2', { action: 'fight', move: 0, target: 3 });
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

test('autoPick Struggles rather than hanging when the NPC has no move', () => {
  const battle = build({
    id: 'emptymoves', mode: '1v1', seed: 3, choiceTimeout: 0, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 200, atk: 90, spe: 80,
          moves: [mv('thump', 40, 255, 0)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 200, spe: 10, moves: [] })] }],
    },
  });
  battle.drainEvents();
  assert.ok(battle.submitChoice('p1', { action: 'fight', move: 0 }), 'the player files');
  assert.ok(battle.autoPick('p2'), 'an empty-moves NPC still files');
  assert.ok(battle.drainEvents().some((event) => event.t === 'anim' && event.text === 'STRUGGLE'),
    'the empty sheet Struggles rather than skipping');
  assert.ok(battle.turn >= 2 || battle.outcome(),
    'the turn closed rather than sitting on an owed NPC');
});

test('timeout sweep Struggles an empty sheet instead of pushing the clock', () => {
  const battle = build({
    id: 'emptymoves-timeout', mode: '1v1', seed: 3, choiceTimeout: 10, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 200, atk: 90, spe: 80,
          moves: [mv('thump', 40, 255, 0)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 200, spe: 10, moves: [] })] }],
    },
  });
  battle.drainEvents();
  assert.strictEqual(battle.turn, 1, 'the opening window is turn 1');
  assert.strictEqual(battle.tick(9), false, 'inside the deadline the sweep does nothing');
  assert.strictEqual(battle.tick(11), true, 'past the deadline the sweep files');
  assert.ok(battle.drainEvents().some((event) => event.t === 'anim' && event.text === 'STRUGGLE'),
    'an unanswered empty sheet Struggles rather than pushing the clock');
  assert.ok(battle.turn >= 2 || battle.outcome(),
    'the timeout closed the turn instead of waiting another window');
});

test('a dead wild in the choice window ends the fight on tick', () => {
  const battle = build({
    id: 'deadwild-tick', mode: 'wild', seed: 3, choiceTimeout: 0, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 200, atk: 90, spe: 80,
          moves: [mv('thump', 40, 255, 0)] })] }],
      b: [{ playerId: 'p2', name: 'WILD', mons: [
        mn({ species: 'Beta', maxHp: 40, spe: 10,
          moves: [mv('nudge', 10, 255, 0)] })] }],
    },
  });
  battle.drainEvents();
  const foe = battle.byId.get('p2');
  foe.mons[0].hp = 0;
  foe.active = null;
  assert.strictEqual(battle.tick(0), true, 'gen2: one tick notices the empty side');
  const out = battle.outcome();
  assert.ok(out, 'gen2: and the fight ends rather than waiting for the wild');
  assert.strictEqual(out.reason, 'ko', 'gen2: as a knockout');
});

test('FIGHT with nobody to aim at is a skip that closes a dead wild', () => {
  const battle = build({
    id: 'deadwild-skip', mode: 'wild', seed: 3, choiceTimeout: 0, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 200, atk: 90, spe: 80,
          moves: [mv('thump', 40, 255, 0)] })] }],
      b: [{ playerId: 'p2', name: 'WILD', mons: [
        mn({ species: 'Beta', maxHp: 40, spe: 10,
          moves: [mv('nudge', 10, 255, 0)] })] }],
    },
  });
  battle.drainEvents();
  const foe = battle.byId.get('p2');
  foe.mons[0].hp = 0;
  foe.active = null;
  assert.ok(battle.submitChoice('p1', { action: 'fight', move: 0 }),
    'gen2: FIGHT with nobody to aim at is accepted as a skip');
  assert.ok(battle.outcome(), 'gen2: and the skip closes the fight');
});

test('every sentence about a move prints its name, and falls back to the id', () => {
  // Gen 2's own copies of the five call sites. Byte-shared with the Gen 1 pair
  // next door, and separate on purpose: BattleSim2 / lib/battle2 are a twin,
  // not an import, so a fix applied to one half of one generation is exactly
  // the drift this catches.
  const run = byName(jsRuns).get('move_names');
  const said = run.events.filter((event) => event.t === 'msg').map((event) => event.text);

  assert.ok(said.includes('Alpha used SLOW SWIPE'), 'an attack prints the display name');
  assert.ok(said.includes('THUMP HIT was disabled'), 'Disable landing names the move');
  assert.ok(said.includes('THUMP HIT is disabled'), 'and so does the refusal it causes');
  assert.ok(said.includes('THUMP HIT is no longer disabled'), 'and so does it wearing off');
  assert.ok(said.includes('Alpha learned THUMP HIT'), 'Mimic names what it copied');
  assert.ok(said.includes('Alpha used THUMP HIT'), 'and the copy keeps the name');
  assert.ok(said.includes('Beta used nudge'),
    'a move with no name -- a protocol-25 sheet -- is narrated under its id');

  const anims = run.events.filter((event) => event.t === 'anim').map((event) => event.text);
  assert.ok(anims.includes('slow_swipe'), 'the anim row still carries the registry id');
  assert.ok(!anims.includes('SLOW SWIPE'), 'and never the display name');
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
  battle.submitChoice('a1', { action: 'fight', move: 0, target: 3 });
  battle.submitChoice('a2', { action: 'fight', move: 0, target: 3 });
  battle.autoPick('npc');
  battle.drainEvents();
  assert.strictEqual(battle.snapshot().phase, 'replace');

  // Nobody answers. The clock is what has to carry it.
  assert.ok(battle.tick(battle.snapshot().now + 60),
    'the deadline passing is a tick that did something');
  assert.strictEqual(battle.snapshot().phase, 'choice',
    'the sweep filled the owed replacement and closed the phase');
  const sent = battle.drainEvents().filter((e) => e.t === 'send' && e.slot === 3);
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
  assert.ok(Events.SHAPES.send.status, '...and the condition a newcomer walked in with');
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

const wildBattle2 = (mode, id, bBag) => {
  const sideA = [{
    playerId: 'p1', name: 'Ann', bag: { POTION: 1 },
    mons: [mn({ species: 'Alpha', maxHp: 200, spe: 90, moves: [mv('thump', 40, 255, 0)] })],
  }];
  if (mode === 'coop_wild') {
    sideA.push({
      playerId: 'p2', name: 'Pat',
      mons: [mn({ species: 'Gamma', maxHp: 200, spe: 1, moves: [mv('thump', 1, 255, 0)] })],
    });
  }
  return build({
    id, mode, seed: 88010, choiceTimeout: 10, reconnectGrace: 60,
    sides: {
      a: sideA,
      b: [{
        playerId: 'wild', name: 'Wild', bag: bBag,
        mons: [mn({
          species: 'Beta', maxHp: 200, hp: 40, spe: 10, status: 'PSN',
          moves: [mv('thump', 40, 255, 0)],
        })],
      }],
    },
  });
};

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

test('Potion on a fainted party slot is refused', () => {
  const battle = build({
    id: 'potion-faint', mode: '1v1', seed: 88021,
    choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', bag: { POTION: 1 }, mons: [
        mn({ species: 'Alpha', maxHp: 100, hp: 50, spe: 90, moves: [mv('thump', 40, 255, 0)] }),
        mn({ species: 'Bench', maxHp: 100, hp: 0, spe: 1, moves: [mv('thump', 40, 255, 0)] }),
      ] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 200, spe: 10, moves: [mv('thump', 40, 255, 0)] })] }],
    },
  });
  battle.drainEvents();
  assert.strictEqual(
    battle.submitChoice('p1', { action: 'item', item: 'POTION', slot: 1 }), false,
    'Potion on a fainted party slot is refused',
  );
  assert.strictEqual(battle.byId.get('p1').bag.POTION, 1, 'and the bag is not spent');
  assert.strictEqual(battle.byId.get('p1').choice, null, 'and the turn is still owed');
});

test('a dropped seat cannot file a choice until reconnect()', () => {
  const battle = build({
    id: 'dropped-choice', mode: '1v1', seed: 2, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', moves: [mv('thump', 40, 255, 0)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', moves: [mv('thump', 40, 255, 0)] })] }],
    },
  });
  battle.drainEvents();
  battle.disconnect('p1');
  assert.strictEqual(battle.submitChoice('p1', { action: 'fight', move: 0 }), false,
    'a disconnected seat cannot file a choice');
  assert.strictEqual(battle.submitChoice('p2', { action: 'fight', move: 0 }), true,
    'the seat that stayed may still file');
  assert.strictEqual(battle.snapshot().turn, 1,
    'the turn does not resolve on the dropped seat\'s leftover');
  battle.reconnect('p1');
  assert.strictEqual(battle.submitChoice('p1', { action: 'fight', move: 0 }), true,
    'reconnect restores the right to choose');
  assert.strictEqual(battle.snapshot().turn, 2,
    'and the already-filed peer lets the turn complete');
});

test('a leftover choice does not resolve the turn until reconnect()', () => {
  const battle = build({
    id: 'leftover-choice', mode: '1v1', seed: 2, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', moves: [mv('thump', 40, 255, 0)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', moves: [mv('thump', 40, 255, 0)] })] }],
    },
  });
  battle.drainEvents();
  assert.strictEqual(battle.submitChoice('p1', { action: 'fight', move: 0 }), true,
    'a connected seat may file before it drops');
  battle.disconnect('p1');
  assert.strictEqual(battle.submitChoice('p2', { action: 'fight', move: 0 }), true,
    'the seat that stayed may still file after the drop');
  assert.strictEqual(battle.snapshot().turn, 1,
    'a leftover choice does not resolve the turn while a seat is away');
  battle.reconnect('p1');
  assert.strictEqual(battle.snapshot().turn, 2,
    'reconnect completes the already-answered turn without a second pick');
});

// ------------------------------------------------------------------
// badge rules: Crystal's, and against the computer only
// ------------------------------------------------------------------

// Twin of tests/battle_sim2_turn.lua's 7, same sheets and seed, so the numbers
// are the same numbers. Crystal boosts the player's monster and only outside a
// link battle (BadgeStatBoosts opens with `ld a, [wLinkMode] / and a / ret nz`),
// so the referee keeps an uploaded set on side a of wild / coop_wild / coop_npc
// and drops it in 1v1, coop_pvp and on side b. What a kept set does is Gold's,
// not Red's: the ids are Gold's (ZEPHYR ... EARTH), ZEPHYR / MINERAL / PLAIN /
// GLACIER boost Attack / Defense / Speed / Sp. Atk by an eighth up to 999,
// Sp. Def only through Glacier's buggy tail, and DoBadgeTypeBoosts adds an
// eighth to a move whose type's badge is held.

const { Effects } = require('./lib/battle2');

// Every Gold badge, Johto then Kanto.
const ALL_BADGES = {};
for (const row of Effects.BADGE_TYPE_BOOSTS) ALL_BADGES[row.badge] = true;

// The ruleset's type axis. Index 0 is a type no badge names, so a move of type
// 0 is never type-boosted; 1 is BUG (HIVE's), 2 is FIRE and Special.
const RULES = { typeIds: ['DARK', 'BUG', 'FIRE'], specialTypes: [2] };

// One exchange: Ann (side a) and Bob (side b) each swing once. `a` / `b`
// override the stats, the move's power and type, and carry each seat's upload
// (`a.pp = 0` empties Ann's one slot, so she Struggles); `rules` is the ruleset
// (typeIds, specialTypes). The default seed is the one the numbers below were
// pinned on, re-chosen (from 777001) when K12 moved the stream onto the RNG's
// high bits, so every exchange rolls what it did.
const exchange = (mode, a, b, rules = {}) => {
  const move = (power, type, pp = 20) => ({
    id: 'thump', pp, power, accuracy: 255, type, effect: 0, chance: 0,
  });
  const ann = {
    species: 'Alpha', level: 20, hp: 200, maxHp: 200,
    stats: { atk: a.atk || 88, def: a.def || 40, spe: a.spe || 40, spa: a.spa || 40, spd: 40 },
    moves: [move(50, a.type || 0, a.pp)],
  };
  if (a.confusion) ann.confusion = a.confusion;
  const battle = build({
    id: 'b1', mode, seed: a.seed || 777002, choiceTimeout: 60, reconnectGrace: 60,
    typeIds: rules.typeIds, specialTypes: rules.specialTypes,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', badges: a.badges, mons: [ann] }],
      b: [{ playerId: 'p2', name: 'Bob', badges: b.badges, mons: [{
        species: 'Beta', level: 20, hp: 200, maxHp: 200,
        stats: { atk: b.atk || 40, def: b.def || 80, spe: b.spe || 40, spa: b.spa || 40, spd: 40 },
        moves: [move(b.power || 1, b.type || 0)],
      }] }],
    },
  });
  battle.submitChoice('p1', { action: 'fight', move: 0 });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  return canonical(battle.drainEvents());
};
const hitOn = (events, slot) => {
  const hit = events.find((event) => event.t === 'damage' && event.slot === slot);
  return hit ? hit.amount : null;
};
const firstHit = (events) => {
  const hit = events.find((event) => event.t === 'damage');
  return hit ? hit.slot : null;
};
// What a confusion self-hit cost, or null when the seat did not hit itself.
const selfHit = (events) => {
  let hurt = false;
  for (const event of events) {
    if (event.t === 'msg' && typeof event.text === 'string'
        && event.text.includes('hurt itself')) {
      hurt = true;
    } else if (hurt && event.t === 'damage') {
      return event.amount;
    }
  }
  return null;
};

// A seed on which Ann hits herself on the first turn of a confusion.
let confusedSeed = null;
for (let seed = 1; seed <= 200; seed += 1) {
  if (selfHit(exchange('coop_npc', { seed, confusion: 3 }, {})) !== null) {
    confusedSeed = seed;
    break;
  }
}

test('badges count in the three fights against the computer, on side a', () => {
  assert.deepStrictEqual(Object.keys(Turn.BADGE_MODES).sort(),
    ['coop_npc', 'coop_wild', 'wild'], 'and in no other mode');
  assert.strictEqual(Turn.BADGE_SIDE, 'a', "and only on the player's side of them");
  assert.ok(confusedSeed !== null, 'found a seed where a confused Ann hits herself');
});

for (const mode of ['1v1', 'coop_pvp']) {
  test(`${mode}: a link battle ignores every uploaded badge`, () => {
    const bare = exchange(mode, {}, {});
    assert.strictEqual(hitOn(bare, 3), 18, 'the unbadged attack lands for 18');
    assert.strictEqual(hitOn(exchange(mode, { badges: { ZEPHYR: true } }, {}), 3), 18,
      'ZEPHYR does not raise the damage');
    // One seat at a time: both at once would cancel here (each attack is
    // boosted by the same eighth its target's defence is) and prove nothing.
    assert.deepStrictEqual(exchange(mode, { badges: ALL_BADGES }, {}), bare,
      'side a uploading every badge fights the unbadged fight');
    assert.deepStrictEqual(exchange(mode, {}, { badges: ALL_BADGES }), bare,
      'so does side b uploading every badge');
    assert.strictEqual(firstHit(exchange(mode, { spe: 40 }, { spe: 42 })), 0,
      'unbadged, Bob (42) outspeeds Ann (40)');
    assert.strictEqual(firstHit(exchange(mode, { spe: 40, badges: { PLAIN: true } }, { spe: 42 })), 0,
      'PLAIN does not let Ann overtake him');
    assert.strictEqual(hitOn(exchange(mode, { type: 1, badges: { HIVE: true } }, {}, RULES), 3), 12,
      'HIVE does not type-boost a BUG move either');
    const bareSelf = selfHit(exchange(mode, { seed: confusedSeed, confusion: 3 }, {}));
    assert.ok(bareSelf !== null, 'the confused Ann hits herself on this seed too');
    assert.strictEqual(
      selfHit(exchange(mode, { seed: confusedSeed, confusion: 3, badges: { ZEPHYR: true } }, {})),
      bareSelf, 'nor does ZEPHYR reach a confusion self-hit');
  });
}

for (const mode of ['coop_npc', 'wild']) {
  test(`${mode}: side a's badges follow Gold's rules against the computer`, () => {
    assert.strictEqual(hitOn(exchange(mode, {}, {}), 3), 18, 'unbadged, the same 18');
    // 88 -> 88 + floor(88 / 8) = 99 Attack; BattleSim2 reaches the same 20.
    assert.strictEqual(hitOn(exchange(mode, { badges: { ZEPHYR: true } }, {}), 3), 20,
      "ZEPHYR raises side a's physical damage to 20");
    assert.strictEqual(
      hitOn(exchange(mode, { badges: { BOULDER: true, BOULDERBADGE: true } }, {}), 3), 18,
      "BOULDER (Kanto) and BOULDERBADGE (Red's id) boost no stat on Gold");
    assert.strictEqual(firstHit(exchange(mode, { spe: 40 }, { spe: 42 })), 0,
      'unbadged, the foe (42) still goes first');
    assert.strictEqual(firstHit(exchange(mode, { spe: 40, badges: { PLAIN: true } }, { spe: 42 })), 3,
      'PLAIN (40 -> 45) puts side a in front');
    assert.strictEqual(hitOn(exchange(mode, {}, { power: 30 }), 0), 11,
      "Bob's 30-power hit on an unbadged Ann is 11");
    assert.strictEqual(hitOn(exchange(mode, { badges: { MINERAL: true } }, { power: 30 }), 0), 9,
      'MINERAL (Defense 40 -> 45) cuts it to 9');
    assert.strictEqual(hitOn(exchange(mode, { type: 2, spa: 88 }, {}, RULES), 3), 23,
      "Ann's Special hit, unbadged, is 23");
    assert.strictEqual(
      hitOn(exchange(mode, { type: 2, spa: 88, badges: { GLACIER: true } }, {}, RULES), 3), 25,
      'GLACIER (Sp. Atk 88 -> 99) raises it to 25');

    // Glacier's Sp. Def tail, both ways: Bob's Special hit on Ann. Sp. Atk 227
    // boosts to 255, which the tail reads as odd (Sp. Def boosted); 200 boosts
    // to 225, even, and Sp. Def stays as it was.
    const special = { power: 30, type: 2, spa: 60 };
    assert.strictEqual(hitOn(exchange(mode, { spa: 227 }, special, RULES), 0), 10,
      "Bob's Special hit on an unbadged Ann is 10");
    assert.strictEqual(
      hitOn(exchange(mode, { spa: 227, badges: { GLACIER: true } }, special, RULES), 0), 9,
      'GLACIER with Sp. Atk 227 (-> 255) boosts Sp. Def too: 9');
    assert.strictEqual(
      hitOn(exchange(mode, { spa: 200, badges: { GLACIER: true } }, special, RULES), 0), 10,
      'GLACIER with Sp. Atk 200 (-> 225) leaves Sp. Def alone: 10');

    // The 999 cap: 950 + floor(950 / 8) = 1068 is held at 999, so a badged 950
    // hits exactly as an unbadged 999 does, and harder than a bare 950.
    assert.strictEqual(hitOn(exchange(mode, { atk: 950 }, { def: 600 }), 3), 24,
      'an unbadged Attack of 950 hits for 24');
    assert.strictEqual(hitOn(exchange(mode, { atk: 999 }, { def: 600 }), 3), 26,
      'an unbadged Attack of 999 hits for 26');
    assert.strictEqual(
      hitOn(exchange(mode, { atk: 950, badges: { ZEPHYR: true } }, { def: 600 }), 3), 26,
      'ZEPHYR on 950 is capped at 999 and hits for the same 26');

    // DoBadgeTypeBoosts: Ann's BUG move (no STAB, so 12 bare) and HIVE.
    assert.strictEqual(hitOn(exchange(mode, { type: 1 }, {}, RULES), 3), 12,
      "Ann's BUG move, no badge, is 12");
    assert.strictEqual(hitOn(exchange(mode, { type: 1, badges: { HIVE: true } }, {}, RULES), 3), 13,
      'HIVE adds its eighth: 13');
    assert.strictEqual(hitOn(exchange(mode, { type: 1, badges: { FOG: true } }, {}, RULES), 3), 12,
      'a badge of another type adds nothing');
    assert.strictEqual(
      hitOn(exchange(mode, { type: 1, badges: { HIVE: true } }, {},
        { specialTypes: RULES.specialTypes }), 3), 12,
      "with no typeIds the move's type has no name, and nothing fires");
    assert.strictEqual(
      hitOn(exchange(mode, { badges: { HIVE: true } }, { power: 30, type: 1 }, RULES), 0),
      hitOn(exchange(mode, {}, { power: 30, type: 1 }, RULES), 0),
      "the foe's BUG move is not boosted by Ann's HIVE");

    // Struggle never is: pokecrystal BattleCommand_Stab returns for it
    // (`cp STRUGGLE / ret z`) before DoBadgeTypeBoosts. On a chart whose index
    // 0 is BUG, Ann's type-0 move takes HIVE's eighth; her Struggle, whose
    // placeholder type is that same 0, does not -- and takes no STAB either,
    // though Ann is type 0 (the same early return): 10 x 50 x 88 / 80 / 50 =
    // 11, +2 = 13, and the roll leaves 12, where STAB used to make it 19 and 18.
    const BUG_FIRST = { typeIds: ['BUG', 'DARK', 'FIRE'], specialTypes: [2] };
    assert.strictEqual(hitOn(exchange(mode, {}, {}, BUG_FIRST), 3), 18,
      "index 0 named BUG, Ann's type-0 move is 18 bare");
    assert.strictEqual(hitOn(exchange(mode, { badges: { HIVE: true } }, {}, BUG_FIRST), 3), 20,
      '...and HIVE type-boosts it to 20');
    const struggled = exchange(mode, { pp: 0 }, {}, BUG_FIRST);
    assert.ok(struggled.some((event) => event.t === 'anim' && event.text === 'STRUGGLE'),
      'with her one slot at 0 PP, Ann Struggles');
    assert.strictEqual(hitOn(struggled, 3), 12, 'her Struggle, no badge and no STAB, is 12');
    assert.strictEqual(
      hitOn(exchange(mode, { pp: 0, badges: { HIVE: true } }, {}, BUG_FIRST), 3), 12,
      'HIVE leaves her Struggle at 12 (type 0 is BUG here, and still nothing fires)');

    // HitConfusion reads the boosted Attack (ZEPHYR) like any other hit.
    const bareSelf = selfHit(exchange(mode, { seed: confusedSeed, confusion: 3 }, {}));
    const zephyrSelf = selfHit(exchange(mode,
      { seed: confusedSeed, confusion: 3, badges: { ZEPHYR: true } }, {}));
    assert.ok(bareSelf !== null && zephyrSelf !== null && zephyrSelf > bareSelf,
      'ZEPHYR raises a confusion self-hit too');
  });
}

test("coop_npc: side b's upload is ignored against the computer too", () => {
  // Each of these would have changed the fight had it counted: MINERAL would
  // cut Ann's hit, ZEPHYR would raise Bob's, and PLAIN (37 -> 41) would put
  // Bob ahead of Ann's 40.
  const bare = exchange('coop_npc', {}, { power: 30 });
  const hostile = exchange('coop_npc', {}, { badges: ALL_BADGES, power: 30 });
  assert.strictEqual(hitOn(hostile, 3), hitOn(bare, 3), "side b's MINERAL is ignored");
  assert.strictEqual(hitOn(hostile, 0), hitOn(bare, 0), "side b's ZEPHYR is ignored");
  assert.deepStrictEqual(hostile, bare, "side b's upload changes nothing at all");
  assert.strictEqual(firstHit(exchange('coop_npc', {}, { badges: ALL_BADGES, spe: 37 })), 3,
    "side b's PLAIN does not overtake side a");
  assert.deepStrictEqual(
    exchange('coop_npc', {}, { badges: ALL_BADGES, power: 30, type: 1 }, RULES),
    exchange('coop_npc', {}, { power: 30, type: 1 }, RULES),
    "side b's HIVE does not type-boost its BUG move");
});

// ------------------------------------------------------------------
// pokecrystal fidelity: stat order, crits, folding, screens, the self-hit,
// Struggle, a Metronome call and move priority
// ------------------------------------------------------------------
//
// Twin of tests/battle_sim2_turn.lua's section 8 (docs/plans/
// gen12-referee-fidelity.md, Gen 2): the same sheets, the same seeds and the
// same numbers, each worked from the cart's arithmetic there.

const { damage: Damage2 } = require('./lib/battle2');

// A sheet in one line: everything explicit, so the Lua twin builds the same.
function sheet(o) {
  return {
    species: o.species,
    level: o.level === undefined ? 20 : o.level,
    maxHp: o.maxHp === undefined ? 300 : o.maxHp,
    hp: o.hp,
    status: o.status,
    types: o.types === undefined ? [2] : o.types,
    stats: {
      atk: o.atk === undefined ? 40 : o.atk,
      def: o.def === undefined ? 40 : o.def,
      spe: o.spe === undefined ? 40 : o.spe,
      spa: o.spa === undefined ? 40 : o.spa,
      spd: o.spd === undefined ? 40 : o.spd,
    },
    stages: o.stages,
    confusion: o.confusion,
    substitute: o.substitute,
    moves: o.moves,
  };
}
const hit = (id, power, type, effect, pp) => ({
  id, pp: pp === undefined ? 30 : pp, power, accuracy: 255,
  type: type === undefined ? 0 : type, effect: effect === undefined ? 0 : effect, chance: 0,
});
const said = (events, text) => events.some((e) => e.t === 'msg' && e.text === text);
const damageOn = (events, slot) => {
  const event = events.find((e) => e.t === 'damage' && e.slot === slot);
  return event ? event.amount : null;
};
const animOrder = (events) => events.filter((e) => e.t === 'anim').map((e) => e.text).join(',');
function duel(o) {
  return build({
    id: 'b1', mode: o.mode || '1v1', seed: o.seed === undefined ? 4242 : o.seed,
    choiceTimeout: 60, reconnectGrace: 60,
    chart: o.chart, specialTypes: o.specialTypes, typeIds: o.typeIds,
    metronomePool: o.metronomePool,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', badges: o.badges, mons: o.a }],
      b: [{ playerId: 'p2', name: 'Bob', mons: o.b }],
    },
  });
}
function turnOf(battle, a, b) {
  battle.submitChoice('p1', a || { action: 'fight', move: 0 });
  battle.submitChoice('p2', b || { action: 'fight', move: 0 });
  return battle.drainEvents();
}

test('fidelity: CalcBattleStats, BadgeStatBoosts, TruncateHL_BC and GetMovePriority alone', () => {
  assert.strictEqual(Effects.applyStage(100, 1), 150, 'CalcBattleStats: 100 at +1 is 150');
  assert.strictEqual(Effects.applyStage(3, -6), 1, 'a quotient of 0 is raised to 1');
  assert.strictEqual(Effects.applyStage(700, 2), 999, 'one past MAX_STAT_VALUE is held at 999');

  const m = {
    stats: { atk: 100, def: 40, spe: 100, spa: 152, spd: 100 },
    stages: { atk: -1, spe: 2, spa: 1 },
  };
  assert.strictEqual(Effects.battleStat(m, 'atk', { ZEPHYR: true }), 74,
    "the stage first (66), then ZEPHYR's eighth: 74 -- badge-then-stage was 73");
  m.status = 'burn';
  assert.strictEqual(Effects.battleStat(m, 'atk', { ZEPHYR: true }), 37,
    'burn halves what the badge left: 37');
  m.status = 'paralysis';
  assert.strictEqual(Effects.battleStat(m, 'spe', { PLAIN: true }), 56,
    '200 at +2, 225 under PLAIN, quartered by paralysis: 56');
  assert.strictEqual(Effects.battleStat(m, 'spd', { GLACIER: true }), 112,
    "Glacier's tail reads the STAGED Sp. Atk: 228 boosts to 256, odd, so Sp. Def 100 -> 112");
  m.stages.spa = 0;
  assert.strictEqual(Effects.battleStat(m, 'spd', { GLACIER: true }), 100,
    'unstaged, 152 boosts to 171, even, and Sp. Def stays 100');

  const fold = (a, d, link) => {
    const out = Damage2.truncateStats(a, d, link);
    return `${out.attack}/${out.defense}`;
  };
  assert.strictEqual(fold(200, 100, false), '200/100', 'TruncateHL_BC leaves two bytes alone');
  assert.strictEqual(fold(950, 600, false), '237/150', 'folds both by four while either is past 255');
  assert.strictEqual(fold(200, 1200, false), '12/75', 'as often as it takes outside a link battle');
  assert.strictEqual(fold(200, 1200, true), '50/44', "once in one, keeping 300's low byte: the wrap");
  assert.strictEqual(fold(3, 1000, false), '1/250', 'a stat the shift empties becomes 1');
  assert.strictEqual(fold(1024, 50, true), '0/12', 'a wrapped attack stays 0 (DamageCalc only lifts defense)');

  const table = {
    PROTECT: 3, DETECT: 3, ENDURE: 3,
    QUICK_ATTACK: 2, MACH_PUNCH: 2, EXTREMESPEED: 2,
    ROAR: 0, WHIRLWIND: 0, COUNTER: 0, MIRROR_COAT: 0, VITAL_THROW: 0,
    STRUGGLE: 1, thump: 1,
  };
  for (const [id, want] of Object.entries(table)) {
    assert.strictEqual(Effects.movePriority(id), want, `GetMovePriority: ${id} is ${want}`);
  }
  assert.strictEqual(Effects.movePriority({ id: 'quick_attack' }), 2, 'a move record answers by its id, any case');
  assert.strictEqual(Effects.movePriority(null), Effects.BASE_PRIORITY, 'no move is BASE_PRIORITY');
});

test('fidelity: a crit keeps the staged pair only when the defender\'s stage is strictly lower', () => {
  const critHit = (atkStage, defStage) => {
    for (let seed = 1; seed <= 400; seed += 1) {
      const slash = hit('slash_hit', 40);
      slash.highCrit = true;
      const battle = duel({
        seed,
        a: [sheet({ species: 'Alpha', spe: 90, stages: { atk: atkStage }, moves: [slash] })],
        b: [sheet({ species: 'Beta', spe: 10, stages: { def: defStage }, moves: [hit('tap', 0, 0, 85)] })],
      });
      battle.drainEvents();
      const events = turnOf(battle);
      if (said(events, 'A critical hit')) return damageOn(events, 3);
    }
    return null;
  };
  // 10 x 40 x 40 / 40 / 50 = 8, x2 = 16, +2 = 18, then the roll.
  const plain = critHit(0, 6);
  assert.ok(plain !== null && plain >= 15 && plain <= 18,
    'a crit into Defense +6 reads the unmodified stats (15..18), not 160 Defense');
  // 10 x 40 x 160 / 60 / 50 = 21, x2 = 42, +2 = 44, then the roll.
  const staged = critHit(6, 1);
  assert.ok(staged !== null && staged >= 37 && staged <= 44,
    'a crit from Attack +6 into Defense +1 keeps both stages (37..44)');
});

test('fidelity: stages do not survive a switch-in or a faint', () => {
  const battle = duel({
    a: [
      sheet({ species: 'Alpha', spe: 90,
        moves: [hit('sharpen', 0, 0, Effects.idOf('ATTACK_UP2_EFFECT')), hit('thump', 60)] }),
      sheet({ species: 'Gamma', spe: 90, moves: [hit('thump', 10)] }),
    ],
    b: [sheet({ species: 'Beta', spe: 10, maxHp: 30, atk: 40,
      stages: { atk: 3, def: -2 }, moves: [hit('tap', 1)] })],
  });
  battle.drainEvents();
  turnOf(battle);
  assert.strictEqual(battle.byId.get('p1').mons[0].stages.atk, 2, 'the +2 lands on Alpha');
  turnOf(battle, { action: 'switch', slot: 1 });
  turnOf(battle, { action: 'switch', slot: 0 });
  assert.strictEqual(battle.byId.get('p1').mons[0].stages.atk, 0,
    'Alpha comes back in at 0: a send-out brings no stage (ResetPlayerStatLevels)');
  const beta = battle.byId.get('p2').mons[0];
  for (let i = 0; i < 6 && !battle.outcome(); i += 1) turnOf(battle, { action: 'fight', move: 1 });
  assert.strictEqual(beta.hp, 0, 'Beta goes down');
  assert.strictEqual(beta.stages.atk, 0, 'and its +3 Attack goes with it');
  assert.strictEqual(beta.stages.def, 0, 'and its -2 Defense');
});

test('fidelity: screens are per side, tick five times, fail on a recast and skip fixed damage', () => {
  // Seed 4243: Beta's zap does not crit (it does on 4242 since K12, and a crit
  // reads the unscreened Sp. Def -- CheckDamageStatsCritical).
  const battle = duel({
    specialTypes: [1], seed: 4243,
    a: [sheet({ species: 'Alpha', spe: 90, moves: [hit('glow_wall', 0, 1, 64, 20), hit('tap', 1)] })],
    b: [sheet({ species: 'Beta', spe: 10, spa: 60, moves: [hit('zap', 40, 1), hit('sonic_ping', 20, 0, 41)] })],
  });
  battle.drainEvents();
  const first = turnOf(battle);
  assert.strictEqual(battle.screens.a.lightScreen, 4, "Light Screen goes up at 5 and the turn's tick takes one");
  assert.strictEqual(battle.screens.b.lightScreen, 0, "on Ann's side only");
  const screened = damageOn(first, 0);
  assert.ok(screened !== null && screened >= 6 && screened <= 8,
    'a special hit into it reads Sp. Def doubled (6..8)');
  const again = turnOf(battle);
  assert.ok(said(again, 'But it failed'), 'a second Light Screen while one is up fails');
  assert.strictEqual(battle.screens.a.lightScreen, 3, 'and does not refresh the count');
  const fixed = turnOf(battle, { action: 'fight', move: 1 }, { action: 'fight', move: 1 });
  assert.strictEqual(damageOn(fixed, 0), 20, 'a fixed-damage hit is never screened: the post-hoc halving is gone');
  turnOf(battle, { action: 'fight', move: 1 });
  const fade = turnOf(battle, { action: 'fight', move: 1 });
  assert.ok(said(fade, "Ann's LIGHT SCREEN fell"), 'it falls at the end of its fifth turn');
  assert.strictEqual(battle.screens.a.lightScreen, 0, 'and is down');
  const bare = turnOf(battle, { action: 'fight', move: 1 });
  const unscreened = damageOn(bare, 0);
  assert.ok(unscreened !== null && unscreened >= 11 && unscreened <= 14,
    'the next special hit is whole again (11..14)');
});

test('fidelity: the confusion self-hit is DamageCalc alone, past the user\'s substitute', () => {
  const confusedFight = (seed) => duel({
    seed,
    a: [sheet({ species: 'Alpha', spe: 90, atk: 60, def: 60, confusion: 4,
      substitute: 50, moves: [hit('tap', 1)] })],
    b: [sheet({ species: 'Beta', spe: 10, moves: [hit('tap', 0, 0, 85)] })],
  });
  let found = null;
  for (let seed = 1; seed <= 200 && found === null; seed += 1) {
    const battle = confusedFight(seed);
    battle.drainEvents();
    if (said(turnOf(battle), 'Alpha hurt itself in confusion')) found = seed;
  }
  assert.ok(found !== null, 'a seed on which the confused Alpha hits itself');
  const battle = confusedFight(found);
  battle.drainEvents();
  const events = turnOf(battle);
  assert.strictEqual(damageOn(events, 0), 10, 'the self-hit is DamageCalc and nothing after: 10, every time');
  assert.strictEqual(battle.byId.get('p1').mons[0].hp, 290, 'and it comes off the HP');
  assert.strictEqual(battle.byId.get('p1').mons[0].substitute, 50,
    "past the user's own substitute (`ld c, TRUE`)");
});

test('fidelity: Struggle is typeless with a quarter recoil, and a last-PP Metronome call is not Struggle', () => {
  const GHOST_CHART = [[100, 0], [100, 100]];
  const vsGhost = (pp) => duel({
    chart: GHOST_CHART,
    a: [sheet({ species: 'Alpha', spe: 90, types: [0], moves: [hit('thump', 40, 0, 0, pp)] })],
    b: [sheet({ species: 'Beta', spe: 10, types: [1], moves: [hit('tap', 0, 0, 85)] })],
  });
  const normal = vsGhost(10);
  normal.drainEvents();
  assert.ok(said(turnOf(normal), "It doesn't affect Beta"), 'a NORMAL move cannot touch the GHOST on this chart');
  const struggle = vsGhost(0);
  struggle.drainEvents();
  const events = turnOf(struggle);
  const dealt = damageOn(events, 3);
  assert.ok(dealt !== null && dealt >= 10 && dealt <= 12,
    'Struggle hits the GHOST anyway, with no STAB (10..12)');
  assert.ok(!said(events, "It doesn't affect Beta"), 'and no matchup line at all');
  assert.strictEqual(damageOn(events, 0), Math.max(1, Math.floor(dealt / 4)),
    'recoil is a quarter of what it dealt');

  const feeble = duel({
    a: [sheet({ species: 'Alpha', spe: 90, atk: 1, moves: [hit('thump', 40, 0, 0, 0)] })],
    b: [sheet({ species: 'Beta', spe: 10, def: 255, moves: [hit('tap', 0, 0, 85)] })],
  });
  feeble.drainEvents();
  assert.strictEqual(damageOn(turnOf(feeble), 0), 1,
    "a Struggle that deals 1 still costs 1 (BattleCommand_Recoil's minimum)");

  const metronome = duel({
    metronomePool: [hit('pool_hit', 60, 1, 0, 10)],
    a: [sheet({ species: 'Alpha', spe: 90,
      moves: [hit('wave_finger', 0, 0, Effects.idOf('EFFECT_METRONOME'), 1)] })],
    b: [sheet({ species: 'Beta', spe: 10, moves: [hit('tap', 0, 0, 85)] })],
  });
  metronome.drainEvents();
  const called = turnOf(metronome);
  assert.ok(animOrder(called).includes('pool_hit'), 'the last PP calls the pool move');
  assert.ok(!said(called, 'Alpha is hit with recoil'), 'and the called move takes no Struggle recoil');
  const after = turnOf(metronome);
  assert.ok(animOrder(after).includes('STRUGGLE'), 'the turn after, every slot is empty: Struggle');
  assert.ok(said(after, 'Alpha is hit with recoil'), 'which does recoil');

  // ResetTurn re-enters DoMove past CheckTurn, so the called move is not gated
  // a second time: a confused caller spends one confusion turn, not two.
  const confusedCaller = (seed) => duel({
    seed, metronomePool: [hit('pool_hit', 60, 1, 0, 10)],
    a: [sheet({ species: 'Alpha', spe: 90, confusion: 5,
      moves: [hit('wave_finger', 0, 0, Effects.idOf('EFFECT_METRONOME'), 5)] })],
    b: [sheet({ species: 'Beta', spe: 10, moves: [hit('tap', 0, 0, 85)] })],
  });
  let clean = null;
  for (let seed = 1; seed <= 200 && clean === null; seed += 1) {
    const battle = confusedCaller(seed);
    battle.drainEvents();
    if (animOrder(turnOf(battle)).includes('pool_hit')) clean = battle;
  }
  assert.ok(clean !== null, 'a seed on which the confused caller gets its call off');
  assert.strictEqual(clean.byId.get('p1').mons[0].confusion, 4,
    'and the confusion counter ticked once: the called move ran no gate of its own');
});

test('fidelity: the priority bracket comes before the Speed', () => {
  const order = (aMove, aSpe, bMove, bSpe) => {
    const battle = duel({
      a: [sheet({ species: 'Alpha', spe: aSpe, moves: [aMove] })],
      b: [sheet({ species: 'Beta', spe: bSpe, moves: [bMove] })],
    });
    battle.drainEvents();
    return animOrder(turnOf(battle));
  };
  assert.strictEqual(order(hit('QUICK_ATTACK', 40), 10, hit('thump', 40), 99), 'QUICK_ATTACK,thump',
    'QUICK_ATTACK (2) beats a far faster plain hit (1)');
  assert.strictEqual(order(hit('QUICK_ATTACK', 40), 10, hit('EXTREMESPEED', 80), 99),
    'EXTREMESPEED,QUICK_ATTACK', "EXTREMESPEED shares QUICK_ATTACK's bracket, so Speed decides");
  assert.strictEqual(order(hit('thump', 40), 99, hit('PROTECT', 0), 1), 'PROTECT,thump',
    'PROTECT (3) moves first from the slowest seat');
  assert.strictEqual(order(hit('VITAL_THROW', 70, 0, 17), 99, hit('thump', 40), 1), 'thump,VITAL_THROW',
    'VITAL_THROW (0) moves last from the fastest seat');
  assert.strictEqual(order(hit('thump', 40, 0, 0, 0), 10, hit('VITAL_THROW', 70, 0, 17), 99),
    'STRUGGLE,VITAL_THROW', 'Struggle moves at BASE_PRIORITY, ahead of a bracket-0 move');
});

test('fidelity: an NPC never re-raises a screen that is already up', () => {
  const battle = build({
    id: 'b1', mode: 'coop_npc', seed: 77, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'a1', name: 'Ann', mons: [
        sheet({ species: 'Alpha', spe: 10, moves: [hit('tap', 1)] })] }],
      b: [{ playerId: 'npc', name: 'Foe', mons: [
        sheet({ species: 'Beta', spe: 90, moves: [hit('wall_up', 0, 1, 65, 20), hit('thump', 40)] })] }],
    },
  });
  battle.drainEvents();
  battle.submitChoice('a1', { action: 'fight', move: 0, target: 3 });
  battle.autoPick('npc');
  assert.ok(animOrder(battle.drainEvents()).includes('wall_up'), 'the NPC sets up Reflect on a level field');
  battle.submitChoice('a1', { action: 'fight', move: 0, target: 3 });
  battle.autoPick('npc');
  const second = animOrder(battle.drainEvents());
  assert.ok(!second.includes('wall_up'), 'and does not cast it again while it is up');
  assert.ok(second.includes('thump'), 'it attacks instead');
});

// ------------------------------------------------------------------
// Gold held items, obedience, the flinch reset and the cart family -- the
// same claims as section 9 of tests/battle_sim2_turn.lua, every parameter
// synthetic.
// ------------------------------------------------------------------

const { Items, crit: Crit2 } = require('./lib/battle2');

// A sheet with an item ([id, effect, param, name, mail]) and the obedience
// fields, on top of `sheet`.
function held(o) {
  const m = sheet(o);
  m.speciesId = o.speciesId;
  m.traded = o.traded;
  m.statusTurns = o.statusTurns;
  m.focusEnergy = o.focusEnergy;
  m.disable = o.disable;
  if (o.item) {
    [m.heldItem, m.holdEffect, m.holdParam, m.itemName, m.mail] = o.item;
  }
  return m;
}
function fight(o) {
  const foe = o.foe || ((o.mode === 'wild' || o.mode === 'coop_wild') ? 'wild' : 'p2');
  const battle = build({
    id: 'b1', mode: o.mode || '1v1', seed: o.seed === undefined ? 4242 : o.seed,
    choiceTimeout: 60, reconnectGrace: 60,
    typeIds: o.typeIds, specialTypes: o.specialTypes, chart: o.chart,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', badges: o.badges, family: o.family, mons: o.a }],
      b: [{ playerId: foe, name: 'Bob', mons: o.b }],
    },
  });
  return { battle, foe };
}
function roundOf(battle, foe, a, b) {
  battle.submitChoice('p1', a || { action: 'fight', move: 0 });
  battle.submitChoice(foe, b || { action: 'fight', move: 0 });
  return battle.drainEvents();
}
const heldEvents = (events) => events.filter((e) => e.t === 'held')
  .map((e) => `${e.text}:${e.amount}@${e.slot}`).join(',');
const sawHeld = (events) => events.some((e) => e.t === 'held');
const rngOf = (battle) => battle.snapshot().rngState;
const LEFTOVERS = ['LEFTOVERS', 'HELD_LEFTOVERS', 0, 'LEFTOVERS'];
const monOf = (battle, id, index = 0) => battle.byId.get(id).mons[index];

test('held items: the sheet keeps K1 / K2, and each seat its badge rules and family (K6)', () => {
  const battle = build({
    id: 'b1', mode: 'wild', seed: 1, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', family: 'crystal', mons: [
        held({ species: 'Alpha', traded: true, item: ['FLOWER_MAIL', null, 77, 'FLOWER MAIL', true],
          moves: [hit('tap', 1)] }),
        held({ species: 'Gamma', moves: [hit('tap', 1)] })] }],
      b: [{ playerId: 'wild', name: 'Wild', family: 'crystal', mons: [
        held({ species: 'Beta', item: ['LEFTOVERS', 'HELD_LEFTOVERS', 999, 'LEFTOVERS'],
          moves: [hit('tap', 1)] })] }],
    },
  });
  const alpha = monOf(battle, 'p1');
  assert.strictEqual(alpha.heldItem, 'FLOWER_MAIL');
  assert.strictEqual(alpha.holdParam, 77);
  assert.strictEqual(alpha.mail, true);
  assert.strictEqual(alpha.itemName, 'FLOWER MAIL');
  assert.strictEqual(alpha.traded, true);
  assert.strictEqual(monOf(battle, 'wild').holdParam, 255, 'a parameter past a byte is held at 255');
  assert.strictEqual(monOf(battle, 'p1', 1).heldItem, undefined, 'no item, none of the fields');
  assert.strictEqual(monOf(battle, 'p1', 1).traded, undefined);
  assert.strictEqual(battle.byId.get('p1').badgeRules, true);
  assert.strictEqual(battle.byId.get('wild').badgeRules, null, 'side b never plays by badge rules');
  assert.strictEqual(battle.family, 'crystal', "the fight's cart is side a's first seat's");
  const link = build({
    id: 'b1', mode: '1v1', seed: 1, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', family: 'silver', mons: [held({ species: 'Alpha', moves: [hit('tap', 1)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', family: 'crystal', mons: [held({ species: 'Beta', moves: [hit('tap', 1)] })] }],
    },
  });
  assert.strictEqual(link.byId.get('p1').badgeRules, null, 'a link battle has no badge-rules seat');
  assert.strictEqual(link.family, 'gs', "an unknown family on side a is Gold / Silver's");
  const orphan = held({ species: 'Alpha', moves: [hit('tap', 1)] });
  orphan.holdEffect = 'HELD_LEFTOVERS';
  const lone = build({
    id: 'b1', mode: '1v1', seed: 1, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [orphan] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [held({ species: 'Beta', moves: [hit('tap', 1)] })] }],
    },
  });
  assert.strictEqual(monOf(lone, 'p1').holdEffect, undefined, 'a hold effect with no item is nothing held');
});

test('K6: TruncateHL_BC folds once on Gold / Silver and in a link battle, loops on Crystal otherwise', () => {
  const onePass = (mode, family) => fight({
    mode, family,
    a: [held({ species: 'Alpha', moves: [hit('tap', 1)] })],
    b: [held({ species: 'Beta', moves: [hit('tap', 1)] })],
  }).battle._onePassTruncate();
  assert.strictEqual(onePass('wild', undefined), true);
  assert.strictEqual(onePass('wild', 'gs'), true);
  assert.strictEqual(onePass('wild', 'crystal'), false);
  assert.strictEqual(onePass('1v1', 'crystal'), true);
  assert.strictEqual(onePass('coop_pvp', 'gs'), true);
});

test('held items: Quick Claw rolls inside a bracket only, side b first, and a bracket of one draws nothing', () => {
  const claw = ['QUICK_CLAW', 'HELD_QUICK_CLAW', 255, 'QUICK CLAW'];
  const order = (item, bMove, seed = 3) => {
    const { battle, foe } = fight({
      seed,
      a: [held({ species: 'Alpha', spe: 10, item, moves: [hit('ann_hit', 10)] })],
      b: [held({ species: 'Beta', spe: 90, moves: [bMove || hit('bob_hit', 10)] })],
    });
    battle.drainEvents();
    return { order: animOrder(roundOf(battle, foe)), rng: rngOf(battle) };
  };
  assert.strictEqual(order(claw).order, 'ann_hit,bob_hit', 'a claw that fires puts the slower holder first');
  assert.strictEqual(order(undefined).order, 'bob_hit,ann_hit');
  assert.notStrictEqual(order(undefined).rng, order(claw).rng, 'its byte is a real draw');
  assert.strictEqual(order(claw, hit('QUICK_ATTACK', 10)).order, 'QUICK_ATTACK,ann_hit',
    'never past a higher bracket');
  assert.strictEqual(order(claw, hit('QUICK_ATTACK', 10), 9).rng,
    order(undefined, hit('QUICK_ATTACK', 10), 9).rng, 'a bracket of one draws nothing');
  const { battle, foe } = fight({
    seed: 3,
    a: [held({ species: 'Alpha', spe: 50, item: claw, moves: [hit('ann_hit', 10)] })],
    b: [held({ species: 'Beta', spe: 10, item: claw, moves: [hit('bob_hit', 10)] })],
  });
  battle.drainEvents();
  assert.strictEqual(animOrder(roundOf(battle, foe)), 'bob_hit,ann_hit', "side b's claw rolls first");
});

test('held items: Leftovers, a Berry eaten and gone, the strict half', () => {
  const { battle, foe } = fight({
    seed: 7,
    a: [held({ species: 'Alpha', maxHp: 320, hp: 100, spe: 90, item: LEFTOVERS, moves: [hit('tap', 1)] })],
    b: [held({ species: 'Beta', maxHp: 100, hp: 50, spe: 10, item: ['BERRY', 'HELD_BERRY', 12, 'BERRY'],
      moves: [hit('tap', 0, 0, 85)] })],
  });
  battle.drainEvents();
  const events = roundOf(battle, foe);
  assert.ok(said(events, 'Alpha recovered with LEFTOVERS.'));
  assert.strictEqual(monOf(battle, 'p1').heldItem, 'LEFTOVERS');
  assert.strictEqual(heldEvents(events), 'LEFTOVERS:1@0,BERRY:0@3');
  assert.ok(said(events, 'Beta recovered using a BERRY!'));
  assert.strictEqual(monOf(battle, foe).heldItem, null);
  assert.strictEqual(monOf(battle, foe).hp, 49 + 12);
  const quiet = fight({
    seed: 7,
    a: [held({ species: 'Alpha', spe: 90, moves: [hit('tap', 0, 0, 85)] })],
    b: [held({ species: 'Beta', maxHp: 100, hp: 50, spe: 10, item: ['BERRY', 'HELD_BERRY', 12, 'BERRY'],
      moves: [hit('tap', 0, 0, 85)] })],
  });
  quiet.battle.drainEvents();
  assert.ok(!sawHeld(roundOf(quiet.battle, quiet.foe)), 'at exactly half the Berry is kept');
  assert.strictEqual(Items.sixteenth(320), 20);
});

test('held items: a status berry right after infliction, and only the matching one', () => {
  const run = (item) => {
    const { battle, foe } = fight({
      seed: 11,
      a: [held({ species: 'Alpha', spe: 90, moves: [hit('doze_dust', 0, 0, 32)] })],
      b: [held({ species: 'Beta', spe: 10, item, moves: [hit('tap', 1)] })],
    });
    battle.drainEvents();
    return { events: roundOf(battle, foe), battle, foe };
  };
  const mint = run(['MINT_BERRY', 'HELD_HEAL_SLEEP', 0, 'MINT BERRY']);
  assert.ok(said(mint.events, 'Beta fell asleep'));
  assert.ok(said(mint.events, 'Beta recovered using a MINT BERRY!'));
  assert.strictEqual(monOf(mint.battle, mint.foe).status, null);
  assert.ok(said(mint.events, 'Beta used tap'), 'the target moves this very turn');
  const ice = run(['ICE_BERRY', 'HELD_HEAL_BURN', 0, 'ICE BERRY']);
  assert.ok(!sawHeld(ice.events), 'a berry for another status does nothing');
  assert.strictEqual(monOf(ice.battle, ice.foe).heldItem, 'ICE_BERRY');
});

test('held items: Focus Band rolls on every hit and holds a lethal one at 1', () => {
  const band = ['FOCUS_BAND', 'HELD_FOCUS_BAND', 255, 'FOCUS BAND'];
  const run = (item, hp) => {
    const { battle, foe } = fight({
      seed: 21,
      a: [held({ species: 'Alpha', atk: 200, spe: 90, moves: [hit('thump', 80)] })],
      b: [held({ species: 'Beta', maxHp: 400, hp, spe: 10, item, moves: [hit('tap', 0, 0, 85)] })],
    });
    battle.drainEvents();
    return { events: roundOf(battle, foe), battle, foe };
  };
  const lethal = run(band, 5);
  assert.strictEqual(monOf(lethal.battle, lethal.foe).hp, 1);
  assert.ok(said(lethal.events, 'Beta hung on with FOCUS BAND!'));
  assert.strictEqual(heldEvents(lethal.events), 'FOCUS_BAND:1@3');
  const bare = run(undefined, 400);
  const banded = run(band, 400);
  assert.notStrictEqual(rngOf(bare.battle), rngOf(banded.battle), 'a non-lethal hit still rolls');
  assert.ok(!sawHeld(banded.events), 'and says nothing');
});

test("held items: King's Rock -- eligible scripts only, never through a standing substitute", () => {
  const rock = ['KINGS_ROCK', 'HELD_FLINCH', 255, "KING'S ROCK"];
  const run = (move, item, b) => {
    const { battle, foe } = fight({
      seed: 3,
      a: [held({ species: 'Alpha', spe: 90, item, moves: [move] })],
      b: [b || held({ species: 'Beta', maxHp: 400, spe: 10, moves: [hit('tap', 1)] })],
    });
    battle.drainEvents();
    return { events: roundOf(battle, foe), battle };
  };
  assert.ok(said(run(hit('thump', 10), rock).events, 'Beta flinched'));
  assert.strictEqual(rngOf(run(hit('thump', 10)).battle), rngOf(run(hit('FUTURE_SIGHT', 10), rock).battle),
    'a folded-0 move without `kingsrock` draws nothing');
  // THUNDER has its own id now (Effects.THUNDER), whose script has no
  // `kingsrock`; SNORE's own id ends in it.
  assert.strictEqual(rngOf(run(hit('THUNDER', 10, 0, Effects.THUNDER)).battle),
    rngOf(run(hit('THUNDER', 10, 0, Effects.THUNDER), rock).battle),
    'nor does a Gold-native id whose script has none (THUNDER)');
  // SNORE needs a sleeping user (BattleCommand_Snore fails an awake one).
  const snoreRun = (item) => {
    const { battle, foe } = fight({
      seed: 3,
      a: [held({
        species: 'Alpha', spe: 90, item, status: 'SLP', statusTurns: 7,
        moves: [hit('SNORE', 10, 0, Effects.SNORE)],
      })],
      b: [held({ species: 'Beta', maxHp: 400, spe: 10, moves: [hit('tap', 1)] })],
    });
    battle.drainEvents();
    roundOf(battle, foe);
    return battle;
  };
  assert.notStrictEqual(rngOf(snoreRun()), rngOf(snoreRun(rock)),
    "SNORE's script ends in `kingsrock`, so its own id rolls it");
  assert.strictEqual(rngOf(run(hit('ember_hit', 10, 0, 4), rock).battle),
    rngOf(run(hit('ember_hit', 10, 0, 4)).battle), 'nor does a status hit');
  const subbed = () => held({ species: 'Beta', maxHp: 400, spe: 10, substitute: 300, moves: [hit('tap', 1)] });
  const sub = run(hit('thump', 10), rock, subbed());
  assert.ok(!said(sub.events, 'Beta flinched'));
  assert.strictEqual(rngOf(sub.battle), rngOf(run(hit('thump', 10), undefined, subbed()).battle));
  assert.strictEqual(Items.kingsRockMove(Effects.idOf('TWO_TO_FIVE_ATTACKS_EFFECT'), 'fury_hits'), true);
});

test('held items: Lucky Punch reads the battle species through Transform, Metal Powder the party one', () => {
  const { battle, foe } = fight({
    seed: 5,
    a: [held({ species: 'Alpha', speciesId: 'DITTO', spe: 90, item: ['LUCKY_PUNCH', null, 0, 'LUCKY PUNCH'],
      moves: [hit('copycat', 0, 0, 57)] })],
    b: [held({ species: 'Beta', speciesId: 'CHANSEY', spe: 10, moves: [hit('tap', 1)] })],
  });
  battle.drainEvents();
  roundOf(battle, foe);
  const alpha = monOf(battle, 'p1');
  assert.strictEqual(battle._battleSpecies(alpha), 'CHANSEY');
  assert.strictEqual(Items.critSpeciesItem(battle._battleSpecies(alpha), alpha.heldItem), true);
  assert.strictEqual(alpha.speciesId, 'DITTO');
  assert.deepStrictEqual(Items.metalPowder({ heldItem: 'METAL_POWDER', speciesId: alpha.speciesId }, 100, 100),
    { attack: 100, defense: 150 });
  assert.strictEqual(Crit2.level({ speciesItemBonus: true, focusEnergy: true, highCritMove: true, scopeLens: true }), 2);
});

test('held items: Thief both ways, never Mail, never into a full hand, never past effectchance', () => {
  // Thief's row: a 100% effect chance (`percent 100`, $ff on the cart).
  const thiefMove = () => ({ ...hit('THIEF', 10), chance: 100 });
  const run = (bItem, aItem, seed = 4, substitute = undefined) => {
    const b = held({ species: 'Beta', maxHp: 400, spe: 10, item: bItem, moves: [hit('tap', 1)] });
    b.substitute = substitute;
    const { battle, foe } = fight({
      seed,
      a: [held({ species: 'Alpha', spe: 90, item: aItem, moves: [thiefMove()] })],
      b: [b],
    });
    battle.drainEvents();
    return { events: roundOf(battle, foe), battle, foe };
  };
  const charcoal = ['CHARCOAL', 'HELD_FIRE_BOOST', 20, 'CHARCOAL'];
  const stolen = run(charcoal);
  assert.ok(said(stolen.events, 'Alpha stole CHARCOAL from its foe!'));
  assert.strictEqual(heldEvents(stolen.events), 'CHARCOAL:0@3,CHARCOAL:1@0');
  assert.strictEqual(monOf(stolen.battle, 'p1').holdEffect, 'HELD_FIRE_BOOST');
  assert.strictEqual(monOf(stolen.battle, stolen.foe).heldItem, null);
  assert.ok(!sawHeld(run(['FLOWER_MAIL', null, 0, 'FLOWER MAIL', true]).events), 'Mail by flag');
  assert.ok(!sawHeld(run(['SURF_MAIL', null, 0, 'SURF MAIL']).events), 'Mail by id');
  assert.ok(!sawHeld(run(charcoal, ['BERRY', 'HELD_BERRY', 12, 'BERRY']).events), 'a full hand');
  assert.ok(!sawHeld(run(undefined).events), 'an empty foe');
  const sub = run(charcoal, undefined, 4, 80);
  assert.ok(!sawHeld(sub.events), 'a substitute at effectchance keeps the item');
  assert.strictEqual(monOf(sub.battle, sub.foe).heldItem, 'CHARCOAL');
  assert.ok(said(sub.events, 'Alpha used THIEF'));
  const miss = run(charcoal, undefined, 153);
  assert.ok(!sawHeld(miss.events), 'the 1/256 byte of 255 against a 100% chance takes nothing');
  assert.strictEqual(monOf(miss.battle, miss.foe).heldItem, 'CHARCOAL');
  const zero = fight({
    seed: 4,
    a: [held({ species: 'Alpha', spe: 90, moves: [{ ...thiefMove(), chance: 0 }] })],
    b: [held({ species: 'Beta', maxHp: 400, spe: 10, item: charcoal, moves: [hit('tap', 1)] })],
  });
  zero.battle.drainEvents();
  assert.ok(!sawHeld(roundOf(zero.battle, zero.foe)), 'a sheet with a chance of 0 never steals');
  const { battle, foe } = fight({
    mode: 'wild', seed: 4,
    a: [held({ species: 'Alpha', spe: 90, item: LEFTOVERS, moves: [hit('tap', 0, 0, 85)] })],
    b: [held({ species: 'Beta', spe: 10, moves: [thiefMove()] })],
  });
  battle.drainEvents();
  assert.ok(said(roundOf(battle, foe), 'Beta stole LEFTOVERS from its foe!'), "the computer's Thief is not gated");
  assert.strictEqual(monOf(battle, 'p1').heldItem, null);
});

test('held items: Berserk Gene -- 256, an already-confused holder, Attack at +6', () => {
  const gene = ['BERSERK_GENE', null, 0, 'BERSERKGENE'];
  const { battle } = fight({
    a: [held({ species: 'Alpha', spe: 90, item: gene, moves: [hit('tap', 1)] })],
    b: [held({ species: 'Beta', spe: 10, moves: [hit('tap', 1)] })],
  });
  const events = battle.drainEvents();
  const alpha = monOf(battle, 'p1');
  assert.strictEqual(alpha.confusion, Turn.BERSERK_CONFUSION);
  assert.strictEqual(alpha.stages.atk, 2);
  assert.strictEqual(alpha.heldItem, null);
  assert.ok(said(events, "Alpha's BERSERKGENE activated!"));
  const geneAt = events.findIndex((e) => e.t === 'held');
  const turnAt = events.findIndex((e) => e.t === 'turn');
  assert.ok(geneAt >= 0 && geneAt < turnAt, 'before the turn opens');
  const maxed = held({ species: 'Alpha', spe: 90, item: gene, moves: [hit('tap', 1)] });
  maxed.stages = { atk: 6 };
  maxed.confusion = 3;
  const second = fight({ a: [maxed], b: [held({ species: 'Beta', spe: 10, moves: [hit('tap', 1)] })] });
  const events2 = second.battle.drainEvents();
  assert.strictEqual(monOf(second.battle, 'p1').confusion, 3);
  assert.ok(!said(events2, 'Alpha became confused'));
  assert.ok(!said(events2, "Alpha's ATTACK rose"));
});

test('obedience: who is asked, and when nothing is drawn', () => {
  const run = (o) => {
    const { battle, foe } = fight({
      mode: o.mode || 'wild', seed: o.seed === undefined ? 31 : o.seed, badges: o.badges,
      a: [held({ species: 'Alpha', level: o.level || 80, spe: 90, traded: o.traded,
        moves: [hit('thump', 10), hit('pound_two', 10)] })],
      b: [held({ species: 'Beta', level: 80, spe: 10, maxHp: 900, moves: [hit('tap', 1)] })],
    });
    battle.drainEvents();
    for (let i = 0; i < 4; i += 1) roundOf(battle, foe);
    return rngOf(battle);
  };
  const base = run({});
  assert.notStrictEqual(run({ traded: true }), base, 'a traded L80 monster with no badge is asked');
  assert.strictEqual(run({ traded: true, level: 10 }), run({ level: 10 }), 'at the cap: no draw');
  assert.strictEqual(run({ traded: true, badges: { RISING: true } }), base, 'RISING: no draw');
  assert.strictEqual(run({ traded: true, mode: '1v1' }), run({ mode: '1v1' }), 'a link battle never asks');
  // CheckUserIsCharging and CheckRampage skip the command.
  const locked = (traded, field, value) => {
    const mon = held({ species: 'Alpha', level: 80, spe: 90, traded,
      moves: [hit('beam_up', 60, 0, 39), hit('rampage', 60, 0, 27)] });
    mon[field] = value;
    const { battle, foe } = fight({
      mode: 'wild', seed: 31, a: [mon],
      b: [held({ species: 'Beta', level: 80, maxHp: 900, spe: 10, moves: [hit('tap', 1)] })],
    });
    battle.drainEvents();
    battle.tick(1);
    const events = battle.drainEvents().concat(roundOf(battle, foe));
    return { rng: rngOf(battle), events };
  };
  const charged = () => ({ moveIndex: 1, effect: 39, moveId: 'beam_up', targetSlot: 3 });
  const tradedCharge = locked(true, 'charging', charged());
  assert.strictEqual(tradedCharge.rng, locked(undefined, 'charging', charged()).rng,
    "a charged move's release is never asked");
  assert.ok(said(tradedCharge.events, 'Alpha used beam_up'), 'and goes off');
  assert.strictEqual(locked(true, 'thrashing', { turns: 1, moveIndex: 2 }).rng,
    locked(undefined, 'thrashing', { turns: 1, moveIndex: 2 }).rng, "nor is a rampage's continuation");
});

test('obedience: Snore / Sleep Talk pass the sleep gate, and a disobedient sleeper ignores orders', () => {
  const sleeper = (move, traded, seed) => {
    const { battle, foe } = fight({
      mode: 'wild', seed,
      a: [held({ species: 'Alpha', level: 80, spe: 90, status: 'SLP', statusTurns: 7, traded,
        moves: [move, hit('thump', 10)] })],
      b: [held({ species: 'Beta', level: 80, maxHp: 900, spe: 10, moves: [hit('tap', 1)] })],
    });
    battle.drainEvents();
    return roundOf(battle, foe);
  };
  const snore = sleeper(hit('SNORE', 10), undefined, 3);
  assert.ok(said(snore, 'Alpha is fast asleep') && said(snore, 'Alpha used SNORE'));
  const other = sleeper(hit('thump', 10), undefined, 3);
  assert.ok(said(other, 'Alpha is fast asleep') && !said(other, 'Alpha used thump'));
  let ignored = null;
  for (let seed = 1; seed <= 40 && !ignored; seed += 1) {
    const events = sleeper(hit('SLEEP_TALK', 0), true, seed);
    if (said(events, 'Alpha ignored orders...sleeping!')) ignored = events;
  }
  assert.ok(ignored, 'a disobedient sleeper using Sleep Talk ignores orders');
  assert.ok(!said(ignored, 'Alpha used SLEEP_TALK'));
});

test('obedience: `.UseInstead` spends the other move and forgets the last move', () => {
  let found = null;
  for (let seed = 1; seed <= 400 && !found; seed += 1) {
    const { battle, foe } = fight({
      mode: 'wild', seed,
      a: [held({ species: 'Alpha', level: 80, spe: 90, traded: true,
        moves: [hit('thump', 10), hit('pound_two', 10)] })],
      b: [held({ species: 'Beta', level: 80, maxHp: 900, spe: 10, moves: [hit('tap', 1)] })],
    });
    battle.drainEvents();
    if (said(roundOf(battle, foe), 'Alpha used instead, pound_two')) found = battle;
  }
  assert.ok(found);
  const alpha = monOf(found, 'p1');
  assert.strictEqual(alpha.moves[1].pp, 29);
  assert.strictEqual(alpha.moves[0].pp, 30);
  assert.strictEqual(alpha.lastMoveIndex, 0);
});

test('the flinch reset at turn open, and the recharge exception', () => {
  const rock = ['KINGS_ROCK', 'HELD_FLINCH', 255, "KING'S ROCK"];
  const { battle, foe } = fight({
    mode: 'wild', seed: 3,
    a: [held({ species: 'Alpha', spe: 90, moves: [hit('tap', 1)] })],
    b: [held({ species: 'Beta', spe: 10, item: rock, moves: [hit('thump', 10)] })],
  });
  battle.drainEvents();
  const orig = Turn.Battle.prototype._openTurn;
  let seen = null;
  Turn.Battle.prototype._openTurn = function patched() {
    seen = this.byId.get('p1').mons[0].flinch;
    return orig.call(this);
  };
  try {
    roundOf(battle, foe);
  } finally {
    Turn.Battle.prototype._openTurn = orig;
  }
  assert.strictEqual(seen, true, "the slower holder's roll lands on a target that already moved");
  assert.strictEqual(monOf(battle, 'p1').flinch, false, "the turn's open clears it");
  assert.ok(said(roundOf(battle, foe), 'Alpha used tap'));
  const kept = fight({
    mode: 'wild', seed: 3,
    a: [held({ species: 'Alpha', spe: 90, moves: [hit('tap', 1)] })],
    b: [held({ species: 'Beta', spe: 10, moves: [hit('tap', 1)] })],
  }).battle;
  const alpha = monOf(kept, 'p1');
  alpha.flinch = true;
  alpha.mustRecharge = true;
  monOf(kept, 'wild').flinch = true;
  kept._openTurn();
  assert.strictEqual(alpha.flinch, true, "the player's recharging monster keeps its flag");
  assert.strictEqual(monOf(kept, 'wild').flinch, false);
  const linked = fight({
    mode: '1v1', seed: 3,
    a: [held({ species: 'Alpha', spe: 90, moves: [hit('tap', 1)] })],
    b: [held({ species: 'Beta', spe: 10, moves: [hit('tap', 1)] })],
  }).battle;
  const lalpha = monOf(linked, 'p1');
  lalpha.flinch = true;
  lalpha.mustRecharge = true;
  linked._openTurn();
  assert.strictEqual(lalpha.flinch, false, 'a link battle resets every flag');
});

test('held items: Mysteryberry, the stat-up items, and the held vocabulary', () => {
  const { battle, foe } = fight({
    seed: 2,
    a: [held({ species: 'Alpha', spe: 90, item: ['MYSTERYBERRY', 'HELD_RESTORE_PP', 0, 'MYSTERYBERRY'],
      moves: [hit('tap', 1), hit('spent', 40, 0, 0, 0)] })],
    b: [held({ species: 'Beta', spe: 10, item: ['X_GEM', 'HELD_SPEED_UP', 0, 'X GEM'], moves: [hit('tap', 1)] })],
  });
  const events = battle.drainEvents().concat(roundOf(battle, foe));
  assert.strictEqual(monOf(battle, 'p1').moves[1].pp, 5);
  assert.ok(said(events, 'Alpha recovered PP using MYSTERYBERRY.'));
  assert.strictEqual(monOf(battle, foe).stages.spe, 1);
  assert.ok(said(events, "Beta's X GEM activated!"));
  const topped = held({ species: 'Beta', spe: 10, item: ['X_GEM', 'HELD_SPEED_UP', 0, 'X GEM'], moves: [hit('tap', 1)] });
  topped.stages = { spe: 6 };
  const full = fight({ seed: 2, a: [held({ species: 'Alpha', spe: 90, moves: [hit('tap', 1)] })], b: [topped] });
  full.battle.drainEvents();
  assert.ok(!sawHeld(roundOf(full.battle, full.foe)), 'not past +6, where the item is kept');
  for (const e of events) {
    const [fine, why] = Events.check(e);
    assert.ok(fine, `held vocabulary: ${why}`);
  }
  assert.strictEqual(Events.KINDS.held, true);
});

// The wave-2 review fixes (docs/plans/gen12-referee-fidelity.md); the Lua
// twin's block (p) cites the cart for each.
test('review fixes: Bide release, CheckTurn order, Mysteryberry, sixteenth, Leech Seed KO, Rage', () => {
  const countSaid = (events, text) => events.filter((e) => e.t === 'msg' && e.text === text).length;

  // A Bide's release skips checkobedience.
  const bideRelease = (traded) => {
    const alpha = held({ species: 'Alpha', level: 80, maxHp: 900, spe: 90, traded,
      moves: [hit('BIDE', 0, 0, 26, 10), hit('tap', 10)] });
    alpha.bide = { turns: 0, stored: 40, moveIndex: 1, targetSlot: 3 };
    const { battle, foe } = fight({ mode: 'wild', seed: 2, a: [alpha],
      b: [held({ species: 'Beta', maxHp: 900, spe: 10, moves: [hit('tap', 1)] })] });
    battle.drainEvents();
    battle.submitChoice(foe, { action: 'fight', move: 0 });
    return { events: battle.drainEvents(), battle };
  };
  const traded = bideRelease(true);
  // StoreEnergy's release: "unleashed energy", no `usedmovetext` (R2b).
  assert.ok(said(traded.events, 'Alpha unleashed energy') && !said(traded.events, 'Alpha used BIDE'));
  assert.strictEqual(damageOn(traded.events, 3), 80);
  assert.strictEqual(rngOf(traded.battle), rngOf(bideRelease(undefined).battle), 'no obedience byte');

  // CheckTurn: confusion, then the disabled move, then paralysis.
  const confusedFight = (status) => {
    const { battle, foe } = fight({ seed: 8,
      a: [held({ species: 'Alpha', spe: 90, status, confusion: 4, moves: [hit('thump', 10)] })],
      b: [held({ species: 'Beta', spe: 10, moves: [hit('tap', 1)] })] });
    battle.drainEvents();
    return { events: roundOf(battle, foe), battle };
  };
  const pc = confusedFight('PAR');
  assert.ok(said(pc.events, 'Alpha hurt itself in confusion'));
  assert.strictEqual(rngOf(pc.battle), rngOf(confusedFight(undefined).battle), 'no paralysis byte after a self-hit');
  const disabledFight = (status) => {
    const alpha = held({ species: 'Alpha', spe: 10, status, moves: [hit('thump', 10), hit('pound_two', 10)] });
    alpha.lastMoveIndex = 1;
    const { battle, foe } = fight({ seed: 9, a: [alpha],
      b: [held({ species: 'Beta', spe: 90, moves: [hit('DISABLE', 0, 0, 86), hit('tap', 1)] })] });
    battle.drainEvents();
    return { events: roundOf(battle, foe), battle };
  };
  const pd = disabledFight('PAR');
  assert.ok(said(pd.events, 'thump is disabled'));
  assert.ok(!said(pd.events, 'Alpha is fully paralyzed'));
  assert.strictEqual(rngOf(pd.battle), rngOf(disabledFight(undefined).battle), 'no paralysis byte for a disabled move');

  // A transformed Mysteryberry holder keeps the berry.
  const copy = held({ species: 'Alpha', spe: 90, item: ['MYSTERYBERRY', 'HELD_RESTORE_PP', 0, 'MYSTERYBERRY'],
    moves: [hit('tap', 1), hit('spent', 40, 0, 0, 0)] });
  copy.transformed = true;
  const berry = fight({ seed: 2, a: [copy], b: [held({ species: 'Beta', spe: 10, moves: [hit('tap', 1)] })] });
  berry.battle.drainEvents();
  const berryEvents = roundOf(berry.battle, berry.foe);
  assert.strictEqual(monOf(berry.battle, 'p1').heldItem, 'MYSTERYBERRY');
  assert.strictEqual(monOf(berry.battle, 'p1').moves[1].pp, 0);
  assert.ok(!sawHeld(berryEvents));

  // GetSixteenthMaxHP over GetQuarterMaxHP.
  assert.strictEqual(Items.sixteenth(1024), 257);
  assert.strictEqual(Items.sixteenth(1100), 260);
  assert.strictEqual(Items.sixteenth(999), 62);
  assert.strictEqual(Items.sixteenth(15), 1);

  // A Leech Seed sap that knocks the seeded monster out.
  const seeded = held({ species: 'Beta', maxHp: 320, hp: 10, spe: 10, moves: [hit('tap', 1)] });
  seeded.leechSeed = { fromSlot: 0 };
  const leech = fight({ seed: 3, b: [seeded],
    a: [held({ species: 'Alpha', maxHp: 300, hp: 100, spe: 90, moves: [hit('tap', 1)] })] });
  leech.battle.drainEvents();
  const leechEvents = roundOf(leech.battle, leech.foe);
  assert.ok(said(leechEvents, 'Beta is seeded'));
  // GetEighthMaxHP of 320 is 40, but SubtractHP hands back the 9 HP Beta had
  // left, and that is what RestoreHP gives the seeder.
  assert.strictEqual(monOf(leech.battle, 'p1').hp, 108, 'the seeder is healed the HP taken');
  assert.strictEqual(leech.battle.outcome().reason, 'ko');

  // Gold / Crystal Rage.
  const rageFight = (o) => {
    const alpha = held({ species: 'Alpha', maxHp: 500, spe: o.aSpe || 90, status: o.status,
      confusion: o.confusion, moves: [hit('RAGE', 20, 0, 81), hit('tap', 1)] });
    alpha.substitute = o.substitute;
    alpha.raging = o.raging;
    alpha.rageCounter = o.rageCounter;
    return fight({ seed: o.seed, a: [alpha],
      b: [held({ species: 'Beta', maxHp: o.bHp || 900, spe: o.bSpe || 10,
        moves: [hit(o.bMove || 'pelt', 5, 0, o.bEffect === undefined ? 29 : o.bEffect), hit('tap', 1)] })] });
  };
  const r = rageFight({ seed: 11 });
  r.battle.drainEvents();
  const r1 = roundOf(r.battle, r.foe);
  const ralpha = monOf(r.battle, 'p1');
  const built = countSaid(r1, "Alpha's RAGE is building!");
  assert.ok(built >= 2);
  assert.strictEqual(ralpha.rageCounter, built);
  assert.strictEqual(ralpha.stages.atk, 0);
  assert.strictEqual(ralpha.raging, true);
  assert.strictEqual(r.battle.byId.get('p1').choice, null, 'no lock-in');
  assert.ok(!said(r1, "Alpha's RAGE is building"));
  roundOf(r.battle, r.foe, { action: 'fight', move: 1 }, { action: 'fight', move: 1 });
  assert.strictEqual(ralpha.raging, false);
  assert.strictEqual(ralpha.rageCounter, 0);
  const plain = { level: 20, attack: 40, defense: 40, power: 20, roll: 100 };
  assert.strictEqual(Damage2.compute({ ...plain, rageCount: 4 }).damage, 5 * Damage2.compute(plain).damage);
  assert.strictEqual(Damage2.compute({ ...plain, rageCount: 255 }).damage,
    256 * Damage2.compute(plain).damage, 'x256 at 255, with no 999 tail after it');
  assert.strictEqual(Damage2.compute({
    level: 100, attack: 255, defense: 1, power: 250, roll: 100, rageCount: 255,
  }).damage, 65535, 'pinned at $ffff when the sum carries');
  const src = rageFight({ seed: 1, status: 'PSN', confusion: 3, bMove: 'thump', bEffect: 0 });
  src.battle.drainEvents();
  roundOf(src.battle, src.foe);
  assert.ok(said(roundOf(src.battle, src.foe), 'Alpha hurt itself in confusion'));
  assert.strictEqual(monOf(src.battle, 'p1').rageCounter, 2, 'self-hits and poison build nothing');
  const cap = rageFight({ seed: 21, aSpe: 10, bSpe: 90, bHp: 999, raging: true, rageCounter: 254, substitute: 30 });
  cap.battle.drainEvents();
  assert.strictEqual(countSaid(roundOf(cap.battle, cap.foe), "Alpha's RAGE is building!"), 1);
  assert.strictEqual(monOf(cap.battle, 'p1').rageCounter, 255);
});

// ------------------------------------------------------------------
// Gold side effects: the carts' conditions (FX6) -- the same claims as
// section 10 of tests/battle_sim2_turn.lua: the type immunities, BurnTarget's
// Defrost, FlinchTarget's sleeping / frozen return, and
// BattleCommand_StatDown's `.ComputerMiss` byte with the side effect's silent
// failures.
// ------------------------------------------------------------------

test('side effects: the carts\' type immunities, Defrost, the flinch return and the computer\'s StatDown byte', () => {
  const [NORMAL, FIRE, ICE, ELECTRIC, POISON, BUG, STEEL] = [0, 1, 2, 3, 4, 5, 6];
  const TYPE_IDS = ['NORMAL', 'FIRE', 'ICE', 'ELECTRIC', 'POISON', 'BUG', 'STEEL'];
  const WIRE = { poison: 'PSN', burn: 'BRN', freeze: 'FRZ', paralysis: 'PAR' };
  const bytes = (list) => {
    const r = { drawn: 0 };
    r.byte = () => { r.drawn += 1; return list[r.drawn - 1] === undefined ? 0 : list[r.drawn - 1]; };
    return r;
  };
  const tgt = (o = {}) => ({
    species: 'Tgt', types: o.types || [NORMAL], status: o.status, statusTurns: 0,
    substitute: o.substitute || 0, mist: o.mist, confusion: o.confusion || 0,
    invulnerable: o.invulnerable,
    // TryLowerStat reads the battle stat (a stat already at 1 is not lowered).
    stats: { atk: 50, def: 50, spe: 50, spa: 50, spd: 50 },
    stages: { atk: o.atk || 0, def: 0, spe: 0, spa: 0, spd: 0, acc: 0, eva: 0 },
  });
  const side = (effectId, target, o = {}) => Effects.applySide({
    effectId, hit: o.hit !== false, rng: o.rng || bytes([]), targetMon: target,
    targetFighter: { slot: 3, side: 'b' }, userFighter: { slot: 0, side: 'a' },
    statusToWire: WIRE, moveType: o.moveType, poisonType: o.poisonType,
    normalType: o.normalType, computerMover: o.computer,
  });
  const primary = (effectId, target, o = {}) => Effects.applyPrimary({
    effectId, rng: o.rng || bytes([]), targetMon: target,
    userMon: tgt(), targetFighter: { slot: 3, side: 'b' }, userFighter: { slot: 0, side: 'a' },
    statusToWire: WIRE, computerMover: o.computer,
  });
  const noStatus = (t) => t.status === undefined || t.status === null;

  // (a) PoisonTarget: CheckIfTargetIsPoisonType, POISON alone.
  let t = tgt({ types: [POISON] });
  side(2, t, { moveType: POISON, poisonType: POISON });
  assert.ok(noStatus(t), 'a POISON-type target is never poisoned by a side effect');
  t = tgt({ types: [BUG, POISON] });
  side(77, t, { moveType: BUG, poisonType: POISON });
  assert.ok(noStatus(t), 'its second type counts');
  t = tgt({ types: [STEEL] });
  let out = side(77, t, { moveType: BUG, poisonType: POISON });
  assert.strictEqual(t.status, 'poison', 'a STEEL type a Bug move reaches is poisoned');
  assert.strictEqual(out.events[0].fields.status, 'PSN');
  t = tgt({ types: [POISON] });
  side(2, t, { moveType: POISON });
  assert.strictEqual(t.status, 'poison', 'no typeIds: POISON cannot be told');

  // (b) CheckMoveTypeMatchesTarget for burn and freeze; none for paralysis.
  t = tgt({ types: [FIRE] });
  side(4, t, { moveType: FIRE, normalType: NORMAL });
  assert.ok(noStatus(t), 'a Fire move never burns a Fire type');
  t = tgt({ types: [NORMAL, FIRE] });
  side(4, t, { moveType: FIRE, normalType: NORMAL });
  assert.ok(noStatus(t), 'nor a dual type whose second type is Fire');
  t = tgt({ types: [NORMAL] });
  side(4, t, { moveType: FIRE, normalType: NORMAL });
  assert.strictEqual(t.status, 'burn');
  t = tgt({ types: [NORMAL] });
  side(4, t, { moveType: NORMAL, normalType: NORMAL });
  assert.strictEqual(t.status, 'burn', 'a NORMAL move never matches');
  t = tgt({ types: [NORMAL] });
  side(4, t, { moveType: NORMAL });
  assert.ok(noStatus(t), 'without typeIds the indices alone decide');
  t = tgt({ types: [ICE] });
  side(5, t, { moveType: ICE, normalType: NORMAL });
  assert.ok(noStatus(t), 'an Ice move never freezes an Ice type');
  t = tgt({ types: [FIRE] });
  side(5, t, { moveType: ICE, normalType: NORMAL });
  assert.strictEqual(t.status, 'freeze');
  t = tgt({ types: [ELECTRIC] });
  side(6, t, { moveType: ELECTRIC, normalType: NORMAL });
  assert.strictEqual(t.status, 'paralysis', 'ParalyzeTarget asks no type');
  t = tgt({ types: [NORMAL] });
  side(36, t, { moveType: NORMAL, normalType: NORMAL });
  assert.strictEqual(t.status, 'paralysis');
  for (const id of [2, 4, 5, 6]) {
    t = tgt({ types: [BUG], substitute: 10 });
    side(id, t, { moveType: NORMAL, normalType: NORMAL, poisonType: POISON });
    assert.ok(noStatus(t), `effect ${id}: a standing substitute stops it`);
  }

  // (c) BurnTarget's Defrost, ahead of wEffectFailed.
  t = tgt({ status: 'freeze' });
  out = side(4, t, { hit: false, moveType: FIRE, normalType: NORMAL });
  assert.ok(noStatus(t), 'a burn-family hit thaws whatever its chance byte said');
  assert.strictEqual(out.messages[0], 'Tgt was defrosted');
  assert.strictEqual(out.events[0].fields.status, undefined, 'a cure: no token');
  t = tgt({ status: 'freeze', types: [FIRE] });
  side(4, t, { hit: true, moveType: FIRE, normalType: NORMAL });
  assert.ok(noStatus(t), 'Defrost comes before the type check');
  t = tgt({ status: 'freeze', substitute: 10 });
  side(4, t, { hit: true, moveType: FIRE, normalType: NORMAL });
  assert.strictEqual(t.status, 'freeze', 'a standing substitute returns before Defrost');
  t = tgt({ status: 'paralysis' });
  out = side(4, t, { hit: true, moveType: FIRE, normalType: NORMAL });
  assert.strictEqual(t.status, 'paralysis');
  assert.strictEqual(out.messages.length, 0);
  t = tgt({ status: 'freeze' });
  side(5, t, { hit: true, moveType: ICE, normalType: NORMAL });
  assert.strictEqual(t.status, 'freeze', 'only BurnTarget thaws');

  // (d) FlinchTarget: `and 1 << FRZ | SLP_MASK / ret nz`.
  t = tgt({ status: 'sleep' });
  side(31, t);
  assert.strictEqual(t.flinch, undefined, 'a sleeping target is never flinched');
  t = tgt({ status: 'freeze' });
  side(37, t);
  assert.strictEqual(t.flinch, undefined, 'nor a frozen one');
  t = tgt({ status: 'paralysis' });
  side(31, t);
  assert.strictEqual(t.flinch, true);
  t = tgt({ substitute: 5 });
  side(31, t);
  assert.strictEqual(t.flinch, undefined, 'nothing behind a substitute');

  // (e) BattleCommand_StatDown for a side effect.
  assert.strictEqual(Effects.COMPUTER_DROP_MISS, 64);
  let r = bytes([63]);
  t = tgt();
  out = side(68, t, { rng: r, computer: true });
  assert.strictEqual(r.drawn, 1);
  assert.strictEqual(t.stages.atk, 0);
  assert.strictEqual(out.messages.length, 0);
  r = bytes([64]);
  t = tgt();
  out = side(68, t, { rng: r, computer: true });
  assert.strictEqual(t.stages.atk, -1);
  assert.strictEqual(out.messages[0], "Tgt's ATTACK fell");
  r = bytes([200]);
  t = tgt();
  side(70, t, { rng: r, computer: true, hit: false });
  assert.strictEqual(r.drawn, 1, 'drawn even when the chance byte failed');
  assert.strictEqual(t.stages.spe, 0);
  r = bytes([200]);
  t = tgt({ substitute: 10 });
  side(68, t, { rng: r, computer: true });
  assert.strictEqual(r.drawn, 1, 'and for a hit into a substitute');
  assert.strictEqual(t.stages.atk, 0);
  r = bytes([200]);
  t = tgt({ mist: true });
  out = side(68, t, { rng: r, computer: true });
  assert.strictEqual(r.drawn, 0);
  assert.strictEqual(out.messages.length, 0, 'Mist fails a side effect silently');
  r = bytes([200]);
  t = tgt({ atk: -6 });
  out = side(68, t, { rng: r, computer: true });
  assert.strictEqual(r.drawn, 0);
  assert.strictEqual(out.messages.length, 0, '-6 fails a side effect silently');
  r = bytes([]);
  t = tgt();
  side(68, t, { rng: r });
  assert.strictEqual(r.drawn, 0, "a player's drop draws no byte");
  assert.strictEqual(t.stages.atk, -1);
  // DefenseDownHit's second `effectchance`: drawn in the tail against the
  // substitute standing then, and its verdict is the one StatDown reads.
  const sideAt = (target, rng, hit) => Effects.applySide({
    effectId: 69, hit, chance: 30, rng, targetMon: target,
    targetFighter: { slot: 3, side: 'b' }, statusToWire: WIRE,
  });
  r = bytes([10]);
  t = tgt();
  sideAt(t, r, false);
  assert.strictEqual(r.drawn, 1, 'DEFENSE_DOWN_HIT draws its second effectchance byte');
  assert.strictEqual(t.stages.def, -1, 'a landed second byte lowers Defense whatever the first said');
  r = bytes([200]);
  t = tgt();
  sideAt(t, r, true);
  assert.strictEqual(t.stages.def, 0, 'a failed one stops it whatever the first said');
  r = bytes([10]);
  t = tgt({ substitute: 10 });
  sideAt(t, r, true);
  assert.strictEqual(r.drawn, 0, 'a substitute still standing skips it, byte and all');
  t = tgt({ invulnerable: true });
  side(68, t);
  assert.strictEqual(t.stages.atk, 0, 'CheckHiddenOpponent');
  r = bytes([0]);
  t = tgt({ substitute: 10 });
  side(76, t, { rng: r });
  assert.strictEqual(r.drawn, 0, 'ConfuseTarget: a substitute returns before the turn byte');
  assert.strictEqual(t.confusion, 0);

  // (f) ...and for a primary stat-down move.
  assert.strictEqual(Effects.primaryStatDown(18), 'atk');
  assert.strictEqual(Effects.primaryStatDown(62), 'acc');
  assert.strictEqual(Effects.primaryStatDown(10), null);
  assert.strictEqual(Effects.primaryStatDown(68), null);
  r = bytes([10]);
  t = tgt();
  out = primary(18, t, { rng: r, computer: true });
  assert.strictEqual(out.messages[0], 'But it failed');
  assert.strictEqual(t.stages.atk, 0);
  r = bytes([64]);
  t = tgt();
  primary(18, t, { rng: r, computer: true });
  assert.strictEqual(t.stages.atk, -1);
  r = bytes([64]);
  t = tgt({ substitute: 10 });
  out = primary(18, t, { rng: r, computer: true });
  assert.strictEqual(r.drawn, 1, 'the byte comes before the substitute');
  assert.strictEqual(out.messages[0], 'But it failed', '...which then stops the move (`.Failed`, R2b)');
  r = bytes([64]);
  t = tgt({ mist: true });
  out = primary(18, t, { rng: r, computer: true });
  assert.strictEqual(r.drawn, 0);
  assert.strictEqual(out.messages[0], "Tgt's protected by MIST.", "the cart's Mist line (R2b)");
  r = bytes([64]);
  t = tgt({ atk: -6 });
  out = primary(18, t, { rng: r, computer: true });
  assert.strictEqual(r.drawn, 0);
  assert.strictEqual(out.messages[0], "Tgt's ATTACK won't drop anymore!", 'WontDropAnymoreText (R2b)');
  r = bytes([64]);
  t = tgt({ atk: -5 });
  primary(58, t, { rng: r, computer: true });
  assert.strictEqual(r.drawn, 1);
  assert.strictEqual(t.stages.atk, -6);
  t = tgt({ mist: true, substitute: 10 });
  out = primary(18, t);
  assert.strictEqual(out.messages[0], "Tgt's protected by MIST.", 'Mist before the substitute');
  assert.strictEqual(out.nothing, false);

  // (g) Through the turn machine.
  const duelOf = (mode, bMove, o = {}) => {
    const { battle, foe } = fight({ mode, seed: o.seed === undefined ? 5 : o.seed, typeIds: TYPE_IDS,
      a: [held({ species: 'Alpha', maxHp: 300, spe: o.aSpe || 10, types: [NORMAL],
        status: o.aStatus, statusTurns: o.aTurns, moves: [o.aMove || hit('wait', 0, 0, 85)] })],
      b: [held({ species: 'Beta', maxHp: 300, hp: o.bHp, spe: o.bSpe || 90, types: o.bTypes || [NORMAL],
        status: o.bStatus, statusTurns: o.bTurns, item: o.bItem, moves: [bMove] })] });
    if (o.aSub) monOf(battle, 'p1').substitute = o.aSub;
    if (o.aAway) monOf(battle, 'p1').invulnerable = true;
    battle.drainEvents();
    return { battle, events: roundOf(battle, foe) };
  };
  const oneByteAhead = (link, wild, what) => {
    const probe = link.rng.clone();
    probe.byte();
    assert.strictEqual(wild.rng.state(), probe.state(), what);
  };
  const growl = { id: 'growl', pp: 30, power: 0, accuracy: 100, type: 0, effect: 18, chance: 0 };
  const wildG = duelOf('wild', growl);
  oneByteAhead(duelOf('1v1', growl).battle, wildG.battle, "the computer's GROWL draws one more byte");
  assert.ok(said(wildG.events, 'Beta used growl'));
  const miss = { id: 'growl', pp: 30, power: 0, accuracy: 1, type: 0, effect: 18, chance: 0 };
  const linkM = duelOf('1v1', miss);
  // StatDownFailText's line, not a miss line (R2b).
  assert.ok(said(linkM.events, 'But it failed') && !said(linkM.events, 'Beta missed'));
  oneByteAhead(linkM.battle, duelOf('wild', miss).battle, 'and after a miss');
  const linkF = duelOf('1v1', growl, { aAway: true });
  assert.ok(said(linkF.events, 'But it failed'), 'a GROWL at a target in the sky fails');
  oneByteAhead(linkF.battle, duelOf('wild', growl, { aAway: true }).battle, 'and the computer draws there too');
  const aurora = { id: 'aurora', pp: 30, power: 10, accuracy: 100, type: 2, effect: 68, chance: 10 };
  const wildS = duelOf('wild', aurora, { aSub: 250 });
  oneByteAhead(duelOf('1v1', aurora, { aSub: 250 }).battle, wildS.battle, 'and into a substitute');
  assert.strictEqual(monOf(wildS.battle, 'p1').stages.atk, 0);
  assert.ok(!said(wildS.events, 'But it failed'));

  const bite = { id: 'bite', pp: 30, power: 10, accuracy: 100, type: 0, effect: 31, chance: 100 };
  const biteRun = duelOf('1v1', hit('tap', 1), { aMove: bite, aSpe: 90, bSpe: 10, bStatus: 'SLP', bTurns: 1 });
  assert.ok(!said(biteRun.events, 'Beta flinched'), 'a sleeping target is not flinched');
  assert.ok(said(biteRun.events, 'Beta used tap'), 'so it wakes and acts');

  const ember = { id: 'ember', pp: 30, power: 10, accuracy: 100, type: FIRE, effect: 4, chance: 100 };
  const emberRun = duelOf('1v1', hit('tap', 1), { aMove: ember, aSpe: 90, bSpe: 10, bTypes: [FIRE] });
  assert.ok(noStatus(monOf(emberRun.battle, 'p2')), 'a Fire move at 100% never burns a Fire type');
  assert.ok(!said(emberRun.events, 'Beta was burned'));

  const ember10 = { id: 'ember', pp: 30, power: 10, accuracy: 100, type: FIRE, effect: 4, chance: 10 };
  const thaw = duelOf('1v1', hit('tap', 1), { aMove: ember10, aSpe: 90, bSpe: 10, bStatus: 'FRZ' });
  assert.ok(said(thaw.events, 'Beta was defrosted'));
  assert.ok(noStatus(monOf(thaw.battle, 'p2')));
  assert.ok(said(thaw.events, 'Beta used tap'));

  // A Focus Band holder at 1 HP takes the hit for 0 and is still burned.
  const band = ['FOCUS_BAND', 'HELD_FOCUS_BAND', 255, 'FOCUS BAND'];
  const banded = duelOf('1v1', hit('tap', 1), { aMove: ember, aSpe: 90, bSpe: 10, bHp: 1, bItem: band });
  assert.ok(said(banded.events, 'Beta hung on with FOCUS BAND!'));
  assert.strictEqual(monOf(banded.battle, 'p2').status, 'burn', 'the chance byte still draws');
});

// The referee-gaps run (docs/plans/gen12-referee-gaps-fix.md, R2a): the claims
// the parity scenarios pin only as streams. Twin of the Lua suite's block.
test('referee gaps: the Gold-native effects, effectchance, multi-hit, rampage, recoil, Pay Day', () => {
  const Rng2 = require('./lib/battle2/Rng');
  const bytes = (list) => {
    const r = { drawn: 0 };
    r.byte = () => { r.drawn += 1; return list[r.drawn - 1] || 0; };
    return r;
  };
  const withMove = (m, o = {}) => {
    const { battle } = fight({ seed: o.seed === undefined ? 5 : o.seed, mode: o.mode,
      a: [held({ species: 'Alpha', maxHp: 400, spe: 90, status: o.status, moves: [m] })],
      b: [held({ species: 'Beta', maxHp: 900, spe: 10, substitute: o.substitute,
        moves: [hit('wait', 0, 0, 85)] })] });
    battle.drainEvents();
    return battle;
  };

  // (a) the Gold-native ids, under the cart's own names
  const names = {
    EFFECT_SP_DEF_DOWN_HIT: 87, EFFECT_ACCURACY_DOWN_HIT: 88, EFFECT_ATTACK_UP_HIT: 89,
    EFFECT_DEFENSE_UP_HIT: 90, EFFECT_ALL_UP_HIT: 91, EFFECT_FLAME_WHEEL: 92,
    EFFECT_SACRED_FIRE: 93, EFFECT_STOMP: 94, EFFECT_TWISTER: 95, EFFECT_SNORE: 96,
    EFFECT_THUNDER: 97, EFFECT_TRI_ATTACK: 98, EFFECT_GUST: 99, EFFECT_EARTHQUAKE: 100,
    EFFECT_SKY_ATTACK: 101,
    // R2b's: the commands the referee runs now, and TOXIC off POISON's id.
    EFFECT_SLEEP_TALK: 102, EFFECT_LOCK_ON: 103, EFFECT_SAFEGUARD: 104, EFFECT_TOXIC: 105,
  };
  for (const [name, id] of Object.entries(names)) {
    assert.strictEqual(Effects.idOf(name), id, `${name} has its own id`);
    assert.strictEqual(Effects.nameOf(id), name);
  }
  assert.strictEqual(Effects.MAX_EFFECT_ID, 105);
  assert.strictEqual(Effects.nameOf(106), null);
  assert.strictEqual(Effects.category(101), 'charge');
  assert.ok(Effects.isCharge(Effects.SKY_ATTACK));
  assert.strictEqual(Effects.idOf('EFFECT_SOLARBEAM'), 39);

  // (b) BattleCommand_EffectChance
  let r = bytes([254]);
  assert.strictEqual(Effects.effectChance(r, 100, false), true);
  r = bytes([255]);
  assert.strictEqual(Effects.effectChance(r, 100, false), false, 'the 1/256 miss');
  r = bytes([0]);
  assert.strictEqual(Effects.effectChance(r, 0, false), false);
  assert.strictEqual(r.drawn, 1, 'a 0% chance draws its byte');
  r = bytes([0]);
  assert.strictEqual(Effects.effectChance(r, 100, true), false);
  assert.strictEqual(r.drawn, 0, 'a substitute fails it before any byte');
  assert.ok(Effects.drawsEffectChance(4, hit('ember', 40, 1, 4)));
  assert.ok(Effects.drawsEffectChance(Effects.EARTHQUAKE, hit('EARTHQUAKE', 40, 0, 100)));
  assert.ok(!Effects.drawsEffectChance(Effects.TRI_ATTACK, hit('TRI_ATTACK', 40)));
  assert.ok(!Effects.drawsEffectChance(Effects.GUST, hit('GUST', 40)));
  assert.ok(!Effects.drawsEffectChance(0, hit('thump', 40)));
  assert.ok(Effects.drawsEffectChance(0, { ...hit('THIEF', 40), chance: 100 }));

  // ...and on a miss
  const wild = (effect) => ({ id: 'wild', pp: 60, power: 40, accuracy: 1, type: 0, effect,
    chance: effect === 0 ? 0 : 10 });
  let missSeed = null;
  for (let seed = 1; seed <= 400; seed += 1) {
    const b = withMove(wild(0), { seed });
    if (said(roundOf(b, 'p2'), 'Alpha missed')) { missSeed = seed; break; }
  }
  assert.ok(missSeed !== null);
  const plainMiss = withMove(wild(0), { seed: missSeed });
  const burnMiss = withMove(wild(4), { seed: missSeed });
  roundOf(plainMiss, 'p2');
  roundOf(burnMiss, 'p2');
  const probe = Rng2.create(0).setState(rngOf(plainMiss));
  probe.next();
  assert.strictEqual(rngOf(burnMiss), probe.state(),
    'a missed burn hit draws exactly one more byte: its `effectchance`');
  const subMiss = withMove(wild(4), { seed: missSeed, substitute: 50 });
  const subPlain = withMove(wild(0), { seed: missSeed, substitute: 50 });
  roundOf(subMiss, 'p2');
  roundOf(subPlain, 'p2');
  assert.strictEqual(rngOf(subMiss), rngOf(subPlain), 'none behind a substitute');

  // (c) MULTI_HIT's count
  const tally = [0, 0, 0, 0, 0, 0];
  for (let first = 0; first < 4; first += 1) {
    for (let second = 0; second < 4; second += 1) {
      tally[Effects.multiHitCount(bytes([first, second]))] += 1;
    }
  }
  assert.strictEqual(tally.slice(2).join(','), '6,6,2,2', '2 and 3 at 3/8, 4 and 5 at 1/8');
  r = bytes([1]);
  assert.strictEqual(Effects.multiHitCount(r), 3);
  assert.strictEqual(r.drawn, 1);
  assert.strictEqual(Effects.fixedHits(29), 1);
  assert.strictEqual(Effects.fixedHits(44), 2);
  assert.strictEqual(Effects.fixedHits(77), 2);

  // (d) the counts the carts draw
  assert.strictEqual(Effects.wrapCount(bytes([0])), 3);
  assert.strictEqual(Effects.wrapCount(bytes([7])), 6);
  assert.strictEqual(`${Effects.rampageTurns(bytes([0]))}/${Effects.rampageTurns(bytes([1]))}`, '1/2');
  assert.strictEqual(`${Effects.rampageConfusion(bytes([0]))}/${Effects.rampageConfusion(bytes([1]))}`, '2/3');
  assert.strictEqual(Effects.payDayCoins(30), 60);
  assert.strictEqual(Effects.payDayCoins(140), 24, 'the carry lost');

  // (e) StatDown's `.ComputerMiss` exemption for ACCURACY_DOWN_HIT
  r = bytes([0]);
  const target = { species: 'Tgt', stages: { atk: 0, def: 0, spe: 0, spa: 0, spd: 0, acc: 0, eva: 0 } };
  assert.strictEqual(Effects.statDownGate(r, target, 'acc', true, Effects.ACCURACY_DOWN_HIT), null);
  assert.strictEqual(r.drawn, 0);
  assert.strictEqual(Effects.statDownGate(r, target, 'atk', true, 68), 'missed');

  // (f) RaiseStat on the user
  const user = held({ species: 'Alpha', def: 999, moves: [hit('tap', 1)] });
  user.stages = { atk: 6, def: 0, spe: 0, spa: 0, spd: 0, acc: 0, eva: 0 };
  const out = Effects.applySide({ effectId: Effects.ALL_UP_HIT, hit: true, rng: bytes([]),
    targetMon: { species: 'Tgt', stages: target.stages, substitute: 0 },
    userMon: user, userFighter: { slot: 0, side: 'a' }, targetFighter: { slot: 3, side: 'b' } });
  assert.strictEqual(`${user.stages.atk}/${user.stages.def}/${user.stages.spe}`, '6/0/1');
  assert.strictEqual(out.messages.length, 3);
  user.stages.spe = 0;
  Effects.applySide({ effectId: Effects.ATTACK_UP_HIT, hit: false, rng: bytes([]),
    targetMon: { species: 'Tgt', stages: target.stages, substitute: 0 },
    userMon: user, userFighter: { slot: 0, side: 'a' }, targetFighter: { slot: 3, side: 'b' } });
  assert.strictEqual(user.stages.spe, 0);

  // (g) CantMove
  const thrasher = withMove(hit('THRASH', 20, 0, 27, 10), { seed: 7 });
  roundOf(thrasher, 'p2');
  const alpha = monOf(thrasher, 'p1');
  assert.ok(alpha.thrashing);
  alpha.status = 'paralysis';
  let stopped = false;
  for (let i = 0; i < 30; i += 1) {
    if (!alpha.thrashing) break;
    if (said(roundOf(thrasher, 'p2'), 'Alpha is fully paralyzed')) { stopped = true; break; }
  }
  assert.ok(stopped, 'seed 7: a full paralysis lands while the rampage runs');
  assert.strictEqual(alpha.thrashing, null, 'CantMove ends the rampage');
  assert.strictEqual(alpha.confusion, 0);
  const flier = withMove(hit('FLY', 30, 0, 43), { seed: 3 });
  roundOf(flier, 'p2');
  const fa = monOf(flier, 'p1');
  assert.ok(fa.charging && fa.invulnerable);
  fa.flinch = true;
  assert.ok(said(roundOf(flier, 'p2'), 'Alpha flinched'));
  assert.strictEqual(fa.charging, null, 'CantMove ends the charge');
  assert.strictEqual(fa.invulnerable, false);

  // (h) THRASH with its last PP
  const last = withMove(hit('THRASH', 20, 0, 27, 1), { seed: 9 });
  roundOf(last, 'p2');
  const la = monOf(last, 'p1');
  assert.strictEqual(la.moves[0].pp, 0);
  const nextTurn = roundOf(last, 'p2');
  assert.ok(said(nextTurn, 'Alpha used THRASH'));
  assert.ok(!said(nextTurn, 'Alpha used STRUGGLE'));
  assert.strictEqual(la.moves[0].pp, 0);

  // (i) HYPER BEAM into a substitute
  const beam = withMove(hit('HYPER_BEAM', 150, 0, 80), { seed: 4, substitute: 400 });
  const beamTurn = roundOf(beam, 'p2');
  assert.strictEqual(monOf(beam, 'p2').hp, 900);
  // The recharge is the next turn's, said at its slot there (R2b).
  assert.ok(!said(beamTurn, 'Alpha must recharge'));
  assert.ok(said(roundOf(beam, 'p2'), 'Alpha must recharge'));

  // (j) PAY DAY
  const payFight = (mode) => {
    const { battle, foe } = fight({ mode, seed: 6,
      a: [held({ species: 'Alpha', level: 30, maxHp: 400, atk: 90, spe: 90,
        moves: [hit('PAY_DAY', 40, 0, 16)] })],
      b: [held({ species: 'Beta', maxHp: 30, spe: 10, moves: [hit('wait', 0, 0, 85)] })] });
    battle.drainEvents();
    for (let i = 0; i < 6 && !battle.outcome(); i += 1) roundOf(battle, foe);
    return battle.outcome();
  };
  const won = payFight('wild');
  assert.ok(won && won.outcome === 'win' && won.payDay && won.payDay % 60 === 0);
  assert.strictEqual(payFight('1v1').payDay, undefined, 'a link fight reports none');
  const { battle: catcher } = fight({ mode: 'wild', seed: 6,
    a: [held({ species: 'Alpha', level: 30, maxHp: 400, atk: 1, spe: 90,
      moves: [hit('PAY_DAY', 1, 0, 16)] })],
    b: [held({ species: 'Beta', maxHp: 900, spe: 10, moves: [hit('wait', 0, 0, 85)] })] });
  catcher.drainEvents();
  roundOf(catcher, 'wild');
  catcher.submitChoice('p1', { action: 'item', item: 'MASTER_BALL' });
  catcher.submitChoice('wild', { action: 'fight', move: 0 });
  catcher.drainEvents();
  assert.strictEqual(catcher.outcome().reason, 'catch');
  assert.strictEqual(catcher.outcome().payDay, 60, 'a catch is a WIN: the pot is paid');
});

// The referee-gaps run's wave 2 (docs/plans/gen12-referee-gaps-fix.md, R2b):
// the rules the `r2b_*` parity scenarios pin as streams. Twin of the Lua
// suite's block.
test('R2b: the sheet keeps K8 / K7 / K14, and a `stat` event its signed stage (K10)', () => {
  const { battle: b } = fight({ seed: 1,
    a: [held({ species: 'Alpha', moves: [{ id: 'jab', pp: 5, power: 10, accuracy: 100,
      priority: 2, ppUps: 3 }, hit('tap', 1)] })],
    b: [held({ species: 'Beta', moves: [hit('tap', 1)] })] });
  const m = monOf(b, 'p1');
  assert.strictEqual(m.moves[0].priority, 2);
  assert.strictEqual(m.moves[0].ppUps, 3);
  assert.strictEqual(m.moves[1].priority, null, 'absent stays absent');
  const raw = held({ species: 'Gamma', moves: [hit('tap', 1)] });
  raw.base = { hp: 50, atk: 60, def: 70, spe: 80, spa: 90, spd: 100 };
  raw.dvs = { atk: 15, def: 0, spe: 7, spc: 99 };
  raw.statExp = { hp: 1000 };
  raw.happiness = 300;
  const { battle: c } = fight({ seed: 1, a: [raw], b: [held({ species: 'Beta', moves: [hit('tap', 1)] })] });
  const g = monOf(c, 'p1');
  assert.strictEqual(g.base.spd, 100);
  assert.strictEqual(g.dvs.spc, 15, 'a DV is held to 0..15');
  assert.strictEqual(g.statExp.hp, 1000);
  assert.strictEqual(g.statExp.atk, undefined);
  assert.strictEqual(g.happiness, 255);
  assert.strictEqual(m.dvs, undefined);

  const { battle: s } = fight({ seed: 2,
    a: [held({ species: 'Alpha', spe: 90, moves: [hit('GROWL', 0, 0, 18)] })],
    b: [held({ species: 'Beta', spe: 10, moves: [hit('tap', 1)] })] });
  s.drainEvents();
  const stat = roundOf(s, 'p2').find((e) => e.t === 'stat');
  assert.strictEqual(stat.stage, -1, "a lowered stat's event says stage -1");
  assert.ok(Events.check(stat)[0]);
  assert.strictEqual(Events.FIELDS.stage, 'number');
});

test('R2b: CalcMonStatC, the switch-in order and K9 levelUp', () => {
  const s = Effects.calcMonStats({ hp: 100, atk: 100, def: 100, spe: 100, spa: 100, spd: 100 },
    { atk: 15, def: 15, spe: 15, spc: 15 }, { atk: 65535 }, 50);
  assert.strictEqual(s.stats.def, 120);
  assert.strictEqual(s.stats.atk, 151);
  assert.strictEqual(s.maxHp, 175);
  assert.strictEqual(Effects.calcMonStats(null, {}, null, 50), null);
  const cap = Effects.calcMonStats({ hp: 255, atk: 255, def: 1, spe: 1, spa: 1, spd: 1 },
    { atk: 15, def: 0, spe: 0, spc: 0 }, { atk: 65535 }, 255);
  assert.strictEqual(cap.stats.atk, 999);

  const { battle: b } = fight({ mode: 'wild', seed: 3, badges: { PLAIN: true },
    a: [held({ species: 'Alpha', spe: 10, moves: [hit('tap', 1)] }),
      held({ species: 'Gamma', spe: 15, status: 'PAR', moves: [hit('tap', 1)] })],
    b: [held({ species: 'Beta', spe: 4, moves: [hit('tap', 1)] })] });
  b.drainEvents();
  roundOf(b, 'wild', { action: 'switch', slot: 1 });
  const fa = b.byId.get('p1');
  const g = monOf(b, 'p1', 1);
  assert.strictEqual(b._speedOf(fa, g), 3, 'boost(quarter(15))');
  assert.strictEqual(Effects.battleStat(g, 'spe', fa.badges), 4);
  g.stages.atk = 1;
  assert.strictEqual(b._speedOf(fa, g), 4, 'a stage change rebuilds it');
  g.stages.atk = 0;
  assert.strictEqual(b._speedOf(fa, g), 4);
  const swapIn = (mode) => {
    const { battle } = fight({ mode, seed: 3,
      a: [held({ species: 'Alpha', atk: 200, spe: 30, moves: [hit('slam', 40)] })],
      b: [held({ species: 'Beta', hp: 1, spe: 10, moves: [hit('tap', 1)] }),
        held({ species: 'Delta', spe: 80, status: 'PAR', moves: [hit('tap', 1)] })] });
    battle.drainEvents();
    roundOf(battle, 'p2');
    battle.submitChoice('p2', { action: 'switch', slot: 1 });
    return battle._speedOf(battle.byId.get('p2'), monOf(battle, 'p2', 1));
  };
  assert.strictEqual(swapIn('coop_npc'), 80, "the computer's paralysed switch-in keeps its Speed");
  assert.strictEqual(swapIn('1v1'), 20, "a link fight's foe is quartered");

  const { battle: u } = fight({ mode: 'wild', seed: 4,
    a: [held({ species: 'Alpha', level: 20, maxHp: 100, hp: 60, spe: 40, moves: [hit('tap', 1)] }),
      held({ species: 'Gamma', level: 10, maxHp: 50, spe: 5, moves: [hit('tap', 1)] })],
    b: [held({ species: 'Beta', level: 20, maxHp: 900, spe: 50, moves: [hit('tap', 1)] })] });
  u.drainEvents();
  const stats = { atk: 45, def: 45, spe: 60, spa: 45, spd: 45 };
  assert.strictEqual(u.levelUp('nobody', 1, 21), false);
  assert.strictEqual(u.levelUp('p1', 9, 21), false);
  assert.strictEqual(u.levelUp('p1', 1, 19), false);
  assert.strictEqual(u.levelUp('p1', 1, 101), false);
  assert.strictEqual(u.levelUp('p1', 1, 21, { atk: 45 }), false);
  assert.strictEqual(u.levelUp('p1', 1, 20), false);
  assert.strictEqual(u.levelUp('p1', 1, 21, stats, 110), true);
  const a = monOf(u, 'p1');
  assert.deepStrictEqual([a.level, a.maxHp, a.hp, a.stats.spe], [21, 110, 70, 60]);
  assert.strictEqual(u._speedOf(u.byId.get('p1'), a), 60);
  assert.strictEqual(u.levelUp('p1', 2, 11, stats, 60), true);
  assert.strictEqual(monOf(u, 'p1', 1).stats.spe, 60);
  assert.ok(!monOf(u, 'p1', 1).statSnap);
});

test('R2b: Transform undone, SLEEP TALK, LOCK-ON, a recharge actor, Haze, TOXIC, the freeze', () => {
  const { battle: t } = fight({ seed: 5,
    a: [held({ species: 'Alpha', spe: 90, types: [1], moves: [hit('TRANSFORM', 0, 0, 57, 10)] }),
      held({ species: 'Gamma', spe: 20, moves: [hit('tap', 1)] })],
    b: [held({ species: 'Beta', atk: 120, spe: 60, types: [3],
      moves: [hit('SKETCH', 0), hit('slam', 40, 0, 0, 30)] })] });
  t.drainEvents();
  roundOf(t, 'p2');
  const x = monOf(t, 'p1');
  assert.ok(x.transformed);
  assert.deepStrictEqual([x.moves[0].pp, x.moves[1].pp, x.types[0], x.stats.atk], [1, 5, 3, 120]);
  roundOf(t, 'p2', { action: 'switch', slot: 1 });
  assert.ok(!x.transformed);
  assert.deepStrictEqual([x.moves[0].id, x.moves[0].pp, x.types[0], x.stats.atk],
    ['TRANSFORM', 9, 1, 40]);

  const { battle: st } = fight({ seed: 6,
    a: [held({ species: 'Alpha', status: 'SLP', statusTurns: 7, spe: 90,
      moves: [hit('SLEEP_TALK', 0, 0, 102), hit('SKULL_BASH', 50, 0, 39), hit('BIDE', 0, 0, 26),
        hit('kick', 20, 0, 0, 0)] })],
    b: [held({ species: 'Beta', maxHp: 900, spe: 10, moves: [hit('tap', 1)] })] });
  st.drainEvents();
  const sa = monOf(st, 'p1');
  for (let i = 0; i < 4; i += 1) assert.strictEqual(st._sleepTalkPick(sa, sa.moves[0]).id, 'kick');
  sa.status = null;
  assert.strictEqual(st._sleepTalkPick(sa, sa.moves[0]), null);

  const { battle: lo } = fight({ seed: 7,
    a: [held({ species: 'Alpha', spe: 90, moves: [hit('SWORDS_DANCE', 0, 0, 50), hit('tap', 1)] })],
    b: [held({ species: 'Beta', spe: 10, moves: [hit('tap', 1)] })] });
  lo.drainEvents();
  const beta = monOf(lo, 'p2');
  beta.lockOn = true;
  roundOf(lo, 'p2');
  assert.strictEqual(beta.lockOn, true, 'SWORDS DANCE leaves it');
  roundOf(lo, 'p2', { action: 'fight', move: 1 });
  assert.ok(!beta.lockOn, 'a hit spends it');
  let drawn = 0;
  const r = { byte() { drawn += 1; return 0; } };
  assert.strictEqual(Effects.statDownGate(r, { mist: false, stages: { atk: 0 } }, 'atk', true, 18, true), null);
  assert.strictEqual(drawn, 0);

  const Rng2 = require('./lib/battle2/Rng');
  const steps = (from, to) => {
    const g = Rng2.create(0).setState(from);
    for (let n = 0; n <= 64; n += 1) {
      if (g.state() === to) return n;
      g.next();
    }
    return null;
  };
  const beam = (item) => {
    const { battle } = fight({ seed: 8,
      a: [held({ species: 'Alpha', spe: 10, item, moves: [hit('HYPER_BEAM', 150, 0, 80)] })],
      b: [held({ species: 'Beta', maxHp: 900, spe: 50, moves: [hit('tap', 1)] })] });
    battle.drainEvents();
    roundOf(battle, 'p2');
    const before = rngOf(battle);
    battle.submitChoice('p2', { action: 'fight', move: 0 });
    const events = battle.drainEvents();
    return { n: steps(before, rngOf(battle)), events };
  };
  const bare = beam();
  const clawed = beam(['QUICK_CLAW', 'HELD_QUICK_CLAW', 255, 'QUICK CLAW']);
  assert.strictEqual(clawed.n, bare.n + 1, "the recharging seat's claw rolls");
  assert.ok(said(clawed.events, 'Alpha must recharge'));
  assert.strictEqual(clawed.events[clawed.events.length - 1].t, 'turn');

  const mons = [1, 2, 3, 4].map((i) => ({
    species: `M${i}`, stages: { atk: 2, def: 0, spe: 0, spa: 0, spd: 0, acc: 0, eva: 0 },
  }));
  Effects.applyPrimary({ effectId: 25, userMon: mons[0], targetMon: mons[2],
    userFighter: { slot: 0, side: 'a' }, targetFighter: { slot: 3, side: 'b' }, fieldMons: mons });
  assert.deepStrictEqual(mons.map((m) => m.stages.atk), [0, 0, 0, 0], 'Haze resets all four');

  const { battle: tx } = fight({ seed: 9,
    a: [held({ species: 'Alpha', spe: 90, moves: [hit('TOXIC', 0, 0, 105)] })],
    b: [held({ species: 'Beta', maxHp: 160, spe: 10, moves: [hit('tap', 1)] }),
      held({ species: 'Delta', maxHp: 160, spe: 10, moves: [hit('tap', 1)] })] });
  tx.drainEvents();
  const first = roundOf(tx, 'p2');
  assert.ok(said(first, "Beta's badly poisoned!"));
  assert.strictEqual(damageOn(first, 3), 10);
  assert.strictEqual(damageOn(roundOf(tx, 'p2'), 3), 20);
  roundOf(tx, 'p2', undefined, { action: 'switch', slot: 1 });
  assert.strictEqual(monOf(tx, 'p2').status, 'poison', 'the switch-out leaves plain poison');

  const { battle: fz } = fight({ seed: 10,
    a: [held({ species: 'Alpha', spe: 90, status: 'FRZ', moves: [hit('tap', 1)] })],
    b: [held({ species: 'Beta', maxHp: 900, spe: 10, moves: [hit('wait', 0, 0, 85)] })] });
  fz.drainEvents();
  const fa = monOf(fz, 'p1');
  fa.justFrozen = true;
  const before = rngOf(fz);
  fz._runGates(fz.byId.get('p1'), fa, fa.moves[0]);
  assert.strictEqual(rngOf(fz), before, 'the frozen gate draws nothing');
  fz._heldDefrost();
  assert.strictEqual(rngOf(fz), before, 'nor the defrost on the turn the freeze landed');
  fa.justFrozen = null;
  fz._heldDefrost();
  assert.notStrictEqual(rngOf(fz), before, "the next turn's defrost rolls");
});
