'use strict';

/*
 * The Battle Palace: Turn.create's `rules.palace` (contract C3 of
 * docs/plans/gen3-solo-remaining-fights.md, research §1.4; pokeemerald
 * BATTLE_TYPE_PALACE, the Verdanturf Battle Tent too).
 *
 * Node twin of src/BattleSim3/Palace.lua, which carries the prose and every
 * pret anchor:
 *
 *   * the client's Palace pick (ChooseMoveAndTargetInBattlePalace,
 *     battle_gfx_sfx_util.c:109) arrives as an ordinary fight choice that may
 *     name a slot the move menu refuses, or as `{ action: 'fight', unable:
 *     true }` (the pick's own failure: slot 1, field slot 0);
 *   * the selection check (TrySetCantSelectMoveBattleScript's Palace arm,
 *     battle_util.c:975) marks the normalised choice `palace` = 'disabled' |
 *     'torment' | 'taunt' | 'sealed' | 'unable';
 *   * when its turn comes the failure runs instead of the move
 *     (HandleAction_UseMove, battle_util.c:263): the selection script's line,
 *     or palacetryescapestatus then "<X> appears incapable of using its
 *     power!" (`palace` event `unable`);
 *   * the half-HP line at each turn's end (VARIOUS_PALACE_FLAVOR_TEXT,
 *     battle_script_commands.c:6384), from the cart's flavor table handed in
 *     as `rules.palace.flavor` (`palace` event `flavor`, amount = the line);
 *   * a switch-in at or under half HP gets the bit silently (:4659),
 *     `palaceLow(slot)` reads it.
 *
 * The flavor table is a 0-based JS array here (nature n at [n]; the Lua's
 * list[n + 1]).
 *
 * RNG: a sleeper with no counter roll(0,3), a frozen battler roll(0,4), a
 * random-target move's target roll(0,n-1) -- nothing else.
 *
 * Nothing here throws.
 */

const Status = require('./Status.js');
const Abilities = require('./Abilities.js');
const Items = require('./Items.js');
const Move = require('./Move.js');
const {
  int, truthy, isTable, at, fmt,
} = require('./lua.js');

const M = {};

M.NATURES = 25; // pret NUM_NATURES
M.FLAVOR_MAX = 3; // gBattlePalaceFlavorTextTable holds four lines, 0..3
M.MOVE_STRUGGLE = 165; // pret MOVE_STRUGGLE (the Torment check skips it)

M.SCRIPTS = {
  disabled: true, torment: true, taunt: true, sealed: true,
};
M.TOKENS = {
  disabled: true, torment: true, taunt: true, sealed: true, unable: true,
};

// gBattlePalaceFlavorTextTable, by index (pokeemerald src/battle_message.c:
// 1383-1386), in our words; the screen speaks the cart's line for the index.
M.FLAVOR_TEXT = [
  "A glint appears in %s's eyes!",
  '%s is getting into position!',
  '%s began growling deeply!',
  '%s is eager for more!',
];

M.REFUSED = "rules.palace needs the cart's flavor table (25 natures)";

// `rules.palace` read -> [normalised, null], [null, null] (absent / false: no
// Palace) or [null, refusal].
M.options = function options(raw) {
  if (raw === undefined || raw === null || raw === false) return [null, null];
  if (!isTable(raw) || !isTable(raw.flavor)) return [null, M.REFUSED];
  const flavor = [];
  for (let i = 1; i <= M.NATURES; i += 1) {
    const v = at(raw.flavor, i);
    if (typeof v !== 'number' || v !== Math.floor(v) || v < 0 || v > M.FLAVOR_MAX) {
      return [null, M.REFUSED];
    }
    flavor.push(v);
  }
  return [{ flavor }, null];
};

// pokeemerald/src/battle_util.c:975 TrySetCantSelectMoveBattleScript, the
// BATTLE_TYPE_PALACE arm: the token a pick of `slot` fails with, or null.
M.selection = function selection(B, b, slot, unableIn) {
  let unable = unableIn;
  const mv = at(b.moves, slot);
  if (!truthy(mv)) return null;
  const n = int(mv.num, 0);
  let token = null;
  if (truthy(b.disabledNum) && n === b.disabledNum && n !== 0) token = 'disabled';
  if (truthy(b.tormented) && n === b.lastMoveNum && n !== M.MOVE_STRUGGLE) token = 'torment';
  if (int(b.tauntTurns, 0) > 0 && int(mv.power, 0) === 0) token = 'taunt';
  if (B.isImprisoned(b, n)) token = 'sealed';
  if (token !== null) return token;
  if (Items.of(b)[0] === Items.HOLD.CHOICE_BAND && truthy(b.choicedMove) && b.choicedMove !== n) {
    unable = true;
  }
  if (int(mv.pp, 0) <= 0) unable = true;
  if (unable) return 'unable';
  return null;
};

// The low-HP test the cart runs at a switch-in and at a turn's end:
// maxHP / 2 >= hp, hp != 0, not asleep.
function lowHp(b) {
  const { mon } = b;
  return mon.hp > 0 && Math.floor(mon.maxHp / 2) >= mon.hp && Status.normalise(mon.status) !== 'SLP';
}
M.lowHp = lowHp;

// ------------------------------------------------------------------
// the battle (installed)
// ------------------------------------------------------------------

const Bp = {};

// pokeemerald/src/battle_script_commands.c:4659: a switch-in at or under half
// HP sets its bit silently.
Bp._palaceSwitchIn = function _palaceSwitchIn(nb) {
  if (truthy(this.rules.palace) && truthy(nb) && lowHp(nb)) nb.palaceLow = true;
};

// Whether the battler on this field slot has its Palace bit.
Bp.palaceLow = function palaceLow(slot) {
  const f = this._fighterAtSlot(int(slot, -1));
  const b = f ? f.b : null;
  return b != null && b.palaceLow === true;
};

// pokeemerald/src/battle_script_commands.c:6384 VARIOUS_PALACE_FLAVOR_TEXT,
// every battler in battler order.
Bp._palaceFlavor = function _palaceFlavor() {
  const { palace } = this.rules;
  if (!truthy(palace)) return;
  for (const f of this.order) {
    const { b } = f;
    if (b && !truthy(b.palaceLow) && lowHp(b)) {
      b.palaceLow = true;
      const nature = int(b.mon.nature, 0);
      const id = truthy(at(palace.flavor, nature + 1)) ? at(palace.flavor, nature + 1) : 0;
      this._emit('palace', {
        slot: b.slot, side: b.side, text: 'flavor', amount: id,
      });
      const line = truthy(M.FLAVOR_TEXT[id]) ? M.FLAVOR_TEXT[id] : M.FLAVOR_TEXT[0];
      this.say(fmt(line, this.nameOf(b)));
    }
  }
};

// pokeemerald/src/battle_util2.c:126 BattlePalace_TryEscapeStatus, through
// the canceller's own sleep and freeze steps. True when the battler is still
// asleep or frozen: the action ends there.
Bp._palaceEscapeStatus = function _palaceEscapeStatus(user) {
  const nm = this.nameOf(user);
  if (Status.normalise(user.mon.status) === 'SLP') {
    if (truthy(this.uproarActive()) && user.ability !== 'SOUNDPROOF') {
      delete user.nightmare;
      this.cure(user, `${nm} woke up in the UPROAR!`);
    } else {
      let turns = int(user.mon.sleepTurns, 0);
      if (turns <= 0) turns = Status.sleepTurns(this.rng);
      const [left, woke] = Status.sleepTick(turns, user.ability === 'EARLY_BIRD');
      user.mon.sleepTurns = left;
      if (!woke) {
        this.say(`${nm} is fast asleep.`);
        return true;
      }
      delete user.nightmare;
      this.cure(user, `${nm} woke up!`);
    }
    return false;
  }
  if (Status.normalise(user.mon.status) === 'FRZ') {
    if (this.roll(0, Status.THAW_ROLL_MAX) !== 0) {
      this.say(`${nm} is frozen solid!`);
      return true;
    }
    this.cure(user, `${nm} was defrosted!`);
  }
  return false;
};

// A Palace pick that failed at selection, when its turn comes.
Bp._palaceUnable = function _palaceUnable(fighter, choice) {
  const user = fighter.b;
  if (!user || user.mon.hp <= 0) return undefined;
  const token = choice.palace;
  // gCurrentMove: the slot's move, an Encore that came since overriding it
  // (battle_util.c:112).
  let row = truthy(at(user.moves, choice.move)) ? at(user.moves, choice.move) : Move.STRUGGLE;
  if (int(user.encoreTurns, 0) > 0 && truthy(user.encoreNum)) {
    const s = this.slotOfNum(user, user.encoreNum);
    if (truthy(s)) row = at(user.moves, s);
  }
  // HandleAction_UseMove picks a random-target move's target before it fails
  // (battle_util.c:221): the draw, nothing aimed.
  if (int(row.target, 0) === Move.TARGET.RANDOM) this._pickTarget(user, row, null, false, false);
  user.movedThisTurn = true;
  const nm = this.nameOf(user);
  if (token === 'torment') {
    // battle_util.c:1001: the Torment arm cancels the multi-turn state.
    this.cancelMultiTurn(user);
    this.say(`${nm} can't use the same move in a row due to the TORMENT!`);
  } else if (token === 'disabled') {
    this.say(`${nm}'s ${this.moveLabel(row)} is disabled!`);
  } else if (token === 'taunt') {
    this.say(`${nm} can't use ${this.moveLabel(row)} after the TAUNT!`);
  } else if (token === 'sealed') {
    this.say(`${nm} can't use the sealed ${this.moveLabel(row)}!`);
  } else if (!this._palaceEscapeStatus(user)) {
    this._emit('palace', { slot: user.slot, side: user.side, text: 'unable' });
    this.say(`${nm} appears incapable of using its power!`);
  }
  // No OBEYS: MOVEEND_UPDATE_LAST_MOVES stores MOVE_UNAVAILABLE, and the move
  // end runs as after a canceller stop (Move.js moveEndLite).
  delete user.lastMoveNum;
  delete user.lastResultingNum;
  Abilities.immunityCure(this);
  Items.moveEnd(this);
  return undefined;
};

M.install = function install(Battle) {
  for (const k of Object.keys(Bp)) Battle.prototype[k] = Bp[k];
};

module.exports = M;
