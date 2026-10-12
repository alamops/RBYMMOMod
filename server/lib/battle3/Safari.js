'use strict';

/*
 * The Safari Zone: Turn.create's `safari` mode (contract C3 of
 * docs/plans/gen3-solo-remaining-fights.md; research §1.2).
 *
 * Node twin of src/BattleSim3/Safari.lua, which carries the prose and every
 * pret anchor: FireRed / LeafGreen (pokefirered/src/battle_main.c:2282,
 * :4334-4429, battle_ai_script_commands.c:1713) and Emerald
 * (pokeemerald/src/battle_main.c:3113, battle_util.c:52-76 / :541-634,
 * battle_ai_script_commands.c:2029).
 *
 *   * side a fields NO battler (Turn.create's `noBattler`, implied);
 *   * the trainer files `{ action: 'safari', throw }` (M.THROWS per family) or
 *     `{ action: 'run' }`;
 *   * the wild monster's AI_Safari rolls roll(0,99) against the flee rate when
 *     each turn opens (`_safariDecide`) and flees or watches;
 *   * the turn runs in battler order: the player's action, then the monster's.
 *
 * Emerald's three tables (sGoNearCounterToCatchFactor, sGoNearCounterToEscape-
 * Factor, sPkblToEscapeFactor) are the cart's, handed to `create` as 0-based
 * arrays here (pret index i at [i]; the Lua's list[i + 1]); nothing here
 * carries their values.
 *
 * RNG: roll(0,99) when the turn opens; roll(0,4) for BAIT / ROCK, up to four
 * roll(0,65535) for a ball; nothing else.
 *
 * Events: a ball is `item` (amount = the SAFARI BALLS left) and `ball`; the
 * throws are `anim` BAIT_THROW / ROCK_THROW / POKEBLOCK_THROW; FireRed's
 * reaction is `anim` SAFARI_REACTION with amount 0 watching / 1 angry / 2
 * eating; a flee is the wild seat's ordinary `run`.
 *
 * Nothing here throws.
 */

const Catch = require('./Catch.js');
const { int, truthy, isTable, own } = require('./lua.js');

const M = {};

M.FAMILIES = { frlg: true, rse: true };

// What each cart's menu throws (battle_controller_safari.c
// HandleInputChooseAction); RUN is the plain `run` action.
M.THROWS = {
  frlg: { ball: true, bait: true, rock: true },
  rse: { ball: true, near: true, block: true },
};

// pokeemerald B_MSG_MON_CURIOUS / ENTHRALLED / IGNORED: a POKeBLOCK throw's
// `verdict`, 0..2, decided by the client (pokeblock.c:1264).
M.VERDICT_MAX = 2;

// pokefirered B_MSG_MON_WATCHING / ANGRY / EATING: SAFARI_REACTION's argument.
M.WATCHING = 0;
M.ANGRY = 1;
M.EATING = 2;

M.FACTOR_MAX = 20; // the catch / escape factor caps (battle_main.c:4408, battle_util.c:597)
M.COUNTER_MAX = 6; // the bait / rock counters' cap (battle_main.c:4388)
M.GO_NEAR_STEPS = 3; // go-near counter's last step (battle_util.c:604 `< 3`)
M.PKBL_STEPS = 3; // pokeblock counter's last step (battle_util.c:571 `< 3`)
M.PKBL_ROWS = 4; // sPkblToEscapeFactor rows the counter can reach (0..3)
M.EM_ESCAPE_FACTOR = 3; // pokeemerald/src/battle_main.c:3116 (a code constant)
M.BALLS_MAX = 255; // gNumSafariBalls is a u8
M.BLOCK_NAME_MAX = 32; // bytes of a POKeBLOCK's name the referee will print
M.BLOCK_DEFAULT = 'POKeBLOCK';

function clamp(v, lo, hi) {
  if (v < lo) return lo;
  if (v > hi) return hi;
  return v;
}

// ------------------------------------------------------------------
// the factors (pure; pinned by the `safari` vectors)
// ------------------------------------------------------------------

// pokefirered/src/battle_main.c:2284: the species' catch rate in twentieths.
M.catchFactor = function catchFactor(catchRate) {
  return Math.floor(clamp(int(catchRate, 0), 0, 255) * 100 / 1275);
};

// pokefirered/src/battle_main.c:2285: FireRed / LeafGreen's escape factor,
// never below 2.
M.escapeFactor = function escapeFactor(fleeRate) {
  let f = Math.floor(clamp(int(fleeRate, 0), 0, 255) * 100 / 1275);
  if (f <= 1) f = 2;
  return f;
};

// pokefirered/src/battle_script_commands.c:9496: a SAFARI BALL's catch rate,
// into a u8.
M.ballCatchRate = function ballCatchRate(factor) {
  return Math.floor(int(factor, 0) * 1275 / 100) % 256;
};

// The flee chance in percent (Cmd_if_random_safari_flee).
M.fleeRate = function fleeRate(s) {
  const esc = int(s.escapeFactor, 0);
  if (s.family === 'rse') return esc * 5;
  let rate;
  if (int(s.rock, 0) !== 0) {
    rate = Math.min(M.FACTOR_MAX, esc * 2);
  } else if (int(s.bait, 0) !== 0) {
    rate = Math.floor(esc / 4);
    if (rate === 0) rate = 1;
  } else {
    rate = esc;
  }
  return rate * 5;
};

// pokefirered/src/battle_main.c:4381 HandleAction_ThrowBait (`roll` is the
// `Random() % 5` draw).
M.bait = function bait(s, roll) {
  s.bait = Math.min(M.COUNTER_MAX, int(s.bait, 0) + int(roll, 0) + 2);
  s.rock = 0;
  s.catchFactor = Math.floor(int(s.catchFactor, 0) / 2);
  if (s.catchFactor <= 2) s.catchFactor = 3;
};

// pokefirered/src/battle_main.c:4397 HandleAction_ThrowRock.
M.rock = function rock(s, roll) {
  s.rock = Math.min(M.COUNTER_MAX, int(s.rock, 0) + int(roll, 0) + 2);
  s.bait = 0;
  s.catchFactor = Math.min(M.FACTOR_MAX, int(s.catchFactor, 0) * 2);
};

// pokefirered/src/battle_main.c:4334 HandleAction_WatchesCarefully ->
// M.WATCHING / M.ANGRY / M.EATING.
M.watch = function watch(s) {
  if (int(s.rock, 0) !== 0) {
    s.rock = int(s.rock, 0) - 1;
    if (s.rock === 0) {
      s.catchFactor = int(s.baseCatchFactor, 0);
      return M.WATCHING;
    }
    return M.ANGRY;
  }
  if (int(s.bait, 0) !== 0) {
    s.bait = int(s.bait, 0) - 1;
    if (s.bait === 0) return M.WATCHING;
    return M.EATING;
  }
  return M.WATCHING;
};

// pokeemerald/src/battle_util.c:589 HandleAction_GoNear -> true "crept
// closer", false "can't get any closer" (the fourth step on).
M.goNear = function goNear(s) {
  const n = int(s.goNear, 0);
  const addCatch = int(s.goNearCatch ? s.goNearCatch[n] : null, 0);
  const addEscape = int(s.goNearEscape ? s.goNearEscape[n] : null, 0);
  s.catchFactor = Math.min(M.FACTOR_MAX, (int(s.catchFactor, 0) + addCatch) % 256);
  s.escapeFactor = Math.min(M.FACTOR_MAX, (int(s.escapeFactor, 0) + addEscape) % 256);
  if (n < M.GO_NEAR_STEPS) {
    s.goNear = n + 1;
    return true;
  }
  return false;
};

// pokeemerald/src/battle_util.c:561 HandleAction_ThrowPokeblock, the vanilla
// glitch kept (a factor EQUAL to the entry becomes 0).
M.block = function block(s, verdict) {
  s.pokeblockThrows = Math.min(255, int(s.pokeblockThrows, 0) + 1);
  if (int(s.pkblCounter, 0) < M.PKBL_STEPS) s.pkblCounter = int(s.pkblCounter, 0) + 1;
  const esc = int(s.escapeFactor, 0);
  if (esc > 1) {
    const row = s.pkblToEscape ? s.pkblToEscape[s.pkblCounter] : null;
    const d = int(row ? row[clamp(int(verdict, 0), 0, M.VERDICT_MAX)] : null, 0);
    if (esc < d) s.escapeFactor = 1; else s.escapeFactor = esc - d;
  }
};

// ------------------------------------------------------------------
// create
// ------------------------------------------------------------------

// An array of `n` bytes, or null when any is missing or not a number.
function byteList(raw, n) {
  if (!isTable(raw)) return null;
  const out = [];
  for (let i = 1; i <= n; i += 1) {
    const v = int(raw[i - 1], null);
    if (v == null) return null;
    out.push(clamp(v, 0, 255));
  }
  return out;
}

// The `safari` create option before the sides are read -> [state, null] or
// [null, refusal]. `mode` is the create's.
M.options = function options(raw, mode) {
  if (!isTable(raw)) return [null, 'safari needs an options table'];
  if (mode !== 'wild') return [null, 'safari needs a one-on-one wild fight'];
  const { family } = raw;
  if (!(typeof family === 'string' && own(M.FAMILIES, family))) {
    return [null, 'safari needs a family (frlg or rse)'];
  }
  const balls = int(raw.balls, null);
  if (balls == null) return [null, 'safari needs its ball count'];
  const s = {
    family,
    balls: clamp(balls, 0, M.BALLS_MAX),
    catchFactor: 0,
    baseCatchFactor: 0,
    escapeFactor: 0,
    rock: 0,
    bait: 0,
    goNear: 0,
    pkblCounter: 0,
    pokeblockThrows: 0,
  };
  if (family === 'rse') {
    s.goNearCatch = byteList(raw.goNearCatch, M.GO_NEAR_STEPS + 1);
    s.goNearEscape = byteList(raw.goNearEscape, M.GO_NEAR_STEPS + 1);
    let rows = null;
    if (isTable(raw.pkblToEscape)) {
      rows = [];
      for (let r = 1; r <= M.PKBL_ROWS; r += 1) {
        const row = byteList(raw.pkblToEscape[r - 1], M.VERDICT_MAX + 1);
        if (!row) {
          rows = null;
          break;
        }
        rows.push(row);
      }
    }
    s.pkblToEscape = rows;
    if (!(s.goNearCatch && s.goNearEscape && s.pkblToEscape)) {
      return [null, "safari needs the cart's go-near and pokeblock tables"];
    }
  }
  return [s, null];
};

// The factors, once the wild monster is known -> [true, null] or [null, why].
M.seat = function seat(s, raw, wildMon) {
  const cf = int(raw.catchFactor, null);
  if (cf != null) {
    s.catchFactor = clamp(cf, 0, M.FACTOR_MAX);
  } else {
    s.catchFactor = M.catchFactor(wildMon ? wildMon.catchRate : null);
  }
  s.baseCatchFactor = s.catchFactor;
  const ef = int(raw.escapeFactor, null);
  if (ef != null) {
    s.escapeFactor = clamp(ef, 0, M.FACTOR_MAX);
  } else if (s.family === 'rse') {
    s.escapeFactor = M.EM_ESCAPE_FACTOR;
  } else if (wildMon && wildMon.safariFleeRate != null) {
    s.escapeFactor = M.escapeFactor(wildMon.safariFleeRate);
  } else {
    return [null, "safari needs the wild sheet's safariFleeRate"];
  }
  return [true, null];
};

// What `outcome().safari` carries.
M.summary = function summary(s) {
  return { balls: s.balls, pokeblockThrows: s.pokeblockThrows };
};

// ------------------------------------------------------------------
// the turn (installed on Turn's Battle)
// ------------------------------------------------------------------

const Sb = {};

const VERDICT_TEXT = {
  0: ' is curious about the ',
  1: ' is enthralled by the ',
  2: ' completely ignored the ',
};
const REACTION_TEXT = { 0: ' is watching carefully!', 1: ' is angry!', 2: ' is eating!' };

// The wild monster's action for the turn now opening (AI_Safari), filed like
// a lock-in.
Sb._safariDecide = function _safariDecide() {
  const wild = this.bySide.b[0];
  if (!wild || wild.choice != null || !(wild.b && wild.b.mon.hp > 0)) return;
  const rate = M.fleeRate(this.safari);
  let choice;
  if (this.roll(0, 99) < rate) {
    choice = { action: 'run', flee: true };
  } else {
    choice = { action: 'safari', watch: true };
  }
  wild.forced = true;
  wild.choice = choice;
  this._emit('chose', { slot: wild.slot, side: wild.side, text: wild.name });
};

// The trainer's choice under `safari`: RUN, or one throw of this cart's menu.
Sb._safariChoice = function _safariChoice(fighter, choice) {
  const s = this.safari;
  if (fighter.side !== 'a') return null;
  if (choice.action === 'run') return { action: 'run' };
  if (choice.action !== 'safari') return null;
  const { throw: thrown } = choice;
  if (!(typeof thrown === 'string' && own(M.THROWS[s.family], thrown))) return null;
  if (thrown === 'ball' && s.balls <= 0) return null;
  if (thrown !== 'block') return { action: 'safari', throw: thrown };
  const verdict = int(choice.verdict, null);
  if (verdict == null || verdict < 0 || verdict > M.VERDICT_MAX) return null;
  const out = { action: 'safari', throw: 'block', verdict };
  const name = choice.blockName;
  if (typeof name === 'string' && name !== '' && Buffer.byteLength(name, 'utf8') <= M.BLOCK_NAME_MAX) {
    out.blockName = name;
  }
  return out;
};

// One Safari turn: the trainer's action, then -- unless that ended it -- the
// monster's. RUN always gets away (HandleAction_SafariZoneRun).
Sb._safariTurn = function _safariTurn() {
  const trainer = this.bySide.a[0];
  const wild = this.bySide.b[0];
  const { choice } = trainer;
  if (choice && choice.action === 'run') {
    trainer.acted = true;
    this.say('Got away safely!');
    this._emit('run', { slot: trainer.slot, side: trainer.side, text: trainer.name });
    this._finish('win', this._sidePlayers('b'), this._sidePlayers('a'), 'run', 'run', 'a');
    return;
  }
  if (choice && choice.action === 'safari') {
    trainer.acted = true;
    this._safariThrow(trainer, wild, choice);
  }
  if (truthy(this.result)) return;
  const wc = wild.choice;
  if (wc && wild.b && wild.b.mon.hp > 0) {
    wild.acted = true;
    if (truthy(wc.flee)) {
      this._wildFlee(wild);
    } else if (truthy(wc.watch)) {
      this._safariWatch(wild);
    }
  }
};

Sb._safariThrow = function _safariThrow(trainer, wild, choice) {
  const s = this.safari;
  const target = wild.b;
  const who = trainer.name;
  const it = this.nameOf(target);
  const thrown = choice.throw;
  if (thrown === 'ball') {
    // HandleAction_SafariZoneBallThrow: the ball leaves the count first.
    s.balls -= 1;
    this._emit('item', {
      slot: trainer.slot, side: trainer.side, text: String(Catch.SAFARI), amount: s.balls,
    });
    this.say(`${who} used SAFARI BALL!`);
    const { mon } = target;
    const [caught, shakes] = Catch.attempt(Catch.SAFARI, {
      mon: {
        catchRate: M.ballCatchRate(s.catchFactor), hp: mon.hp, maxHp: mon.maxHp, status: mon.status,
      },
    }, this.rng, {});
    this._emit('ball', {
      slot: trainer.slot,
      side: trainer.side,
      target: wild.slot,
      amount: caught ? 4 : shakes,
      text: String(Catch.SAFARI),
    });
    if (caught) {
      this.say(`Gotcha! ${it} was caught!`);
      const finish = this._finish('win', this._sidePlayers('a'), this._sidePlayers('b'), 'catch',
        'catch', 'a');
      if (finish) {
        finish.caught = this._caughtSheet(target, Catch.SAFARI);
        finish.catcher = trainer.owner;
      }
      return;
    }
    this.say(Catch.SHAKE_TEXT[shakes] != null ? Catch.SHAKE_TEXT[shakes] : Catch.SHAKE_TEXT[0]);
    if (s.balls <= 0) {
      // BattleScript_ShakeBallThrow: B_OUTCOME_NO_SAFARI_BALLS, before the
      // monster acts.
      this.say("ANNOUNCER: You're out of SAFARI BALLS! Game over!");
      this._finish('win', this._sidePlayers('b'), this._sidePlayers('a'), 'run', 'balls', 'a');
    }
    return;
  }
  if (thrown === 'bait') {
    M.bait(s, this.roll(0, 4));
    this.say(`${who} threw some BAIT at the ${it}!`);
    this._emit('anim', {
      slot: trainer.slot, side: trainer.side, target: wild.slot, text: 'BAIT_THROW',
    });
  } else if (thrown === 'rock') {
    M.rock(s, this.roll(0, 4));
    this.say(`${who} threw a ROCK at the ${it}!`);
    this._emit('anim', {
      slot: trainer.slot, side: trainer.side, target: wild.slot, text: 'ROCK_THROW',
    });
  } else if (thrown === 'near') {
    // BattleScript_ActionGetNear: a line, no animation.
    if (M.goNear(s)) {
      this.say(`${who} crept closer to ${it}!`);
    } else {
      this.say(`${who} can't get any closer!`);
    }
  } else if (thrown === 'block') {
    // BattleScript_ActionThrowPokeblock: the throw line, the animation, the
    // verdict line.
    M.block(s, choice.verdict);
    this.say(`${who} threw a POKeBLOCK at the ${it}!`);
    this._emit('anim', {
      slot: trainer.slot, side: trainer.side, target: wild.slot, text: 'POKEBLOCK_THROW',
    });
    const name = truthy(choice.blockName) ? choice.blockName : M.BLOCK_DEFAULT;
    this.say(`${it}${VERDICT_TEXT[choice.verdict]}${name}!`);
  }
};

// The monster's watching turn: FireRed / LeafGreen spend a rock or bait turn
// and show the reaction; Emerald only watches.
Sb._safariWatch = function _safariWatch(wild) {
  const s = this.safari;
  const it = this.nameOf(wild.b);
  if (s.family === 'rse') {
    this.say(`${it}${REACTION_TEXT[M.WATCHING]}`);
    return;
  }
  const reaction = M.watch(s);
  this.say(`${it}${REACTION_TEXT[reaction]}`);
  this._emit('anim', {
    slot: wild.slot, side: wild.side, text: 'SAFARI_REACTION', amount: reaction,
  });
};

M.install = function install(Battle) {
  for (const k of Object.keys(Sb)) Battle.prototype[k] = Sb[k];
};

module.exports = M;
