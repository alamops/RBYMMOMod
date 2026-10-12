'use strict';

/*
 * The Battle Arena: Turn.create's `rules.arena = true` (contract C3 of
 * docs/plans/gen3-solo-remaining-fights.md, research §1.4; pokeemerald
 * BATTLE_TYPE_ARENA, the Fallarbor Battle Tent too).
 *
 * Node twin of src/BattleSim3/Arena.lua, which carries the prose and every
 * pret anchor: one seat a side, a trainer fight; no switching (the swap is
 * refused, Baton Pass and Roar fail, the AI never switches); the fallen and
 * the judged replaced at once in party order (HandleAction_TryFinish /
 * BattleTurnPassed); the judge at the end of a pairing's third turn
 * (battle_util.c:1856) over Mind (sMindRatings: the row's `arenaMind`, else
 * the rule the table follows), Skill (BattleArena_AddSkillPoints /
 * DeductSkillPoints) and Body (HP left over HP at the start); the loser
 * "faints" keeping its HP and status in the party (`judged`); a judgment that
 * empties a side ends the fight `how: 'judge'`.
 *
 * Events: `arena` -- 'start', 'judge', 'mind' / 'skill' / 'body' per side
 * (amount 2 / 1 / 0), 'win' (side) or 'draw' -- then our result line and the
 * loser's `faint`. The outcome lists the judged by sheet slot: `judged: { a:
 * [...], b: [...] }`.
 *
 * RNG: none. Nothing here throws.
 */

const Effects = require('./Effects.js');
const { int, truthy } = require('./lua.js');

const M = {};

const E = Effects.E;

M.COUNTER_WRAP = 256; // gBattleStruct->arenaTurnCounter is a u8
M.SWITCHED_IN = 0xFF; // SwitchInClearSetData (battle_main.c:3258)
M.JUDGE_AT = 2; // battle_util.c:1857
M.ALREADY_PENALTY = 2; // battle_arena.c:598
M.DEDUCT = 3; // battle_arena.c:649
M.REFILL_CAP = 12; // replacement passes a resolution may run (a party of six, twice)
M.CATEGORIES = ['mind', 'skill', 'body'];

// sMindRatings (battle_arena.c:58) for one move row.
M.mindRating = function mindRating(row) {
  if (row === null || typeof row !== 'object') return 0;
  const stamped = int(row.arenaMind, null);
  if (stamped !== null) return stamped;
  const eff = int(row.effect, 0);
  const power = int(row.power, 0);
  if (power !== 0) {
    if (eff === E.COUNTER || eff === E.MIRROR_COAT || eff === E.BIDE) return 0;
    if (eff === E.FAKE_OUT) return -1;
    return 1;
  }
  if (eff === E.PROTECT || eff === E.ENDURE) return -1;
  return 0;
};

// ShowJudgmentSprite's award for one side of one category.
M.points = function points(mine, theirs) {
  if (mine > theirs) return 2;
  if (mine === theirs) return 1;
  return 0;
};

// BattleArena_AddSkillPoints' change for one finished move action.
M.skillDelta = function skillDelta(act, already, isProtected) {
  if (already) return -M.ALREADY_PENALTY;
  if (act.noEffect) {
    if (act.protectedMiss) return 0;
    return -2;
  }
  if (act.super && act.notVery) return 1;
  if (act.super) return 2;
  if (act.notVery) return -1;
  if (isProtected) return 0;
  return 1;
};

// ------------------------------------------------------------------
// the battle (installed)
// ------------------------------------------------------------------

const Ba = {};

function sideBattler(B, side) {
  const f = B.bySide[side][0];
  return f && f.b ? f.b : null;
}

Ba._arenaNew = function _arenaNew() {
  this.arenaState = {
    counter: 0,
    mind: { a: 0, b: 0 },
    skill: { a: 0, b: 0 },
    hpStart: { a: 0, b: 0 },
    already: {},
    judged: { a: [], b: [] },
  };
  this._arenaInitPoints();
};

// BattleArena_InitPoints: both sides' points to 0, HP at start from the
// battlers standing now (0 for a seat still empty).
Ba._arenaInitPoints = function _arenaInitPoints() {
  const st = this.arenaState;
  for (const side of ['a', 'b']) {
    const b = sideBattler(this, side);
    st.mind[side] = 0;
    st.skill[side] = 0;
    st.hpStart[side] = b ? b.mon.hp : 0;
  }
};

// Every switch-in (Turn.js `_switchIn`): the counter to 0xFF, points anew.
Ba._arenaSwitchedIn = function _arenaSwitchedIn() {
  const st = this.arenaState;
  if (!st) return;
  st.counter = M.SWITCHED_IN;
  this._arenaInitPoints();
};

// HandleAction_UseMove's Mind points and the action's result record.
Ba._arenaAct = function _arenaAct(user, row) {
  const st = this.arenaState;
  if (!st) return null;
  st.mind[user.side] += M.mindRating(row);
  const act = { user };
  this.arenaAct = act;
  return act;
};

// One move context's result, ORed into the action's.
Ba._arenaFold = function _arenaFold(C) {
  const act = this.arenaAct;
  if (!act) return;
  if (truthy(C.obeys)) act.obeys = true;
  if ((truthy(C.failed) || truthy(C.noEffect) || truthy(C.missed) || truthy(C.resMissed))
      && !truthy(C.resClear)) {
    act.noEffect = true;
  }
  if (truthy(C.resProtected)) act.protectedMiss = true;
  if (truthy(C.resSuper)) act.super = true;
  if (truthy(C.resNotVery)) act.notVery = true;
};

// Cmd_end: BattleArena_AddSkillPoints for the action's user.
Ba._arenaSkill = function _arenaSkill(act) {
  if (this.arenaAct === act) this.arenaAct = null;
  const st = this.arenaState;
  if (!st || !act || !act.obeys) return;
  const { side } = act.user;
  const already = st.already[side] === true;
  delete st.already[side];
  st.skill[side] += M.skillDelta(act, already, act.user.protected === true);
};

// BattleArena_DeductSkillPoints: one of the nineteen ability lines printed
// through this battler's controller.
Ba._arenaDeduct = function _arenaDeduct(b) {
  const st = this.arenaState;
  if (!st || !b) return;
  st.skill[b.side] -= M.DEDUCT;
};

// VARIOUS_SET_ALREADY_STATUS_MOVE_ATTEMPT (BS_ATTACKER).
Ba._arenaAlready = function _arenaAlready(b) {
  const st = this.arenaState;
  if (!st || !b) return;
  st.already[b.side] = true;
};

// HandleFaintedMonActions' replacements, in party order.
Ba._arenaRefill = function _arenaRefill() {
  if (!this.arenaState) return;
  for (let pass = 1; pass <= M.REFILL_CAP; pass += 1) {
    let did = false;
    for (const fighter of this.order) {
      if (this.result) return;
      if (truthy(fighter.mustReplace)) {
        const index = this.benchOf(fighter)[0];
        if (index !== undefined) {
          did = true;
          // battle_script_commands.c:5261: truantSwitchInHack.
          const hack = fighter.truantHack;
          delete fighter.truantHack;
          const nb = this._switchIn(fighter, index);
          this.switchInEffects(nb, { spikes: true, noTruant: hack });
          this._faintSweep();
          this._drainExp();
          if (!this.result) this._checkOver();
        }
      }
    }
    if (!did) return;
  }
};

// The end of a turn: the replacements, a delayed hit that waited for one, the
// judge and the judged losers' replacements.
Ba._arenaTurnEnd = function _arenaTurnEnd() {
  if (!this.arenaState || this.result) return;
  this._arenaRefill();
  if (!this.result) this._landPendingFutureSight();
  if (!this.result) this._arenaJudge();
  if (!this.result) this._arenaRefill();
};

// One category's points, side a's then side b's.
Ba._arenaCategory = function _arenaCategory(cat) {
  const st = this.arenaState;
  if (cat === 'body') {
    const a = sideBattler(this, 'a');
    const b = sideBattler(this, 'b');
    const pa = Math.floor((a.mon.hp * 100) / Math.max(1, st.hpStart.a));
    const pb = Math.floor((b.mon.hp * 100) / Math.max(1, st.hpStart.b));
    return [pa, pb];
  }
  return [st[cat].a, st[cat].b];
};

// pokeemerald/src/battle_util.c:1856 and BattleScript_ArenaDoJudgment.
Ba._arenaJudge = function _arenaJudge() {
  const st = this.arenaState;
  if (!st || st.counter !== M.JUDGE_AT) return;
  const fa = this.bySide.a[0];
  const fb = this.bySide.b[0];
  const a = fa.b;
  const b = fb.b;
  if (!(a && a.mon.hp > 0 && b && b.mon.hp > 0)) return;
  this.cancelMultiTurn(a);
  this.cancelMultiTurn(b);
  this._emit('arena', { text: 'judge' });
  let ta = 0;
  let tb = 0;
  for (const cat of M.CATEGORIES) {
    const [pa, pb] = this._arenaCategory(cat);
    const sa = M.points(pa, pb);
    const sb = M.points(pb, pa);
    ta += sa;
    tb += sb;
    this._emit('arena', {
      text: cat, side: 'a', slot: fa.slot, amount: sa,
    });
    this._emit('arena', {
      text: cat, side: 'b', slot: fb.slot, amount: sb,
    });
  }
  const an = a.mon.species;
  const bn = b.mon.species;
  let losers;
  if (ta > tb) {
    this._emit('arena', { text: 'win', side: 'a', slot: fa.slot });
    this.say(`${an} defeated the opponent ${bn} in a REFEREE's decision!`);
    losers = [b];
  } else if (ta < tb) {
    this._emit('arena', { text: 'win', side: 'b', slot: fb.slot });
    this.say(`${an} lost to the opponent ${bn} in a REFEREE's decision!`);
    losers = [a];
  } else {
    this._emit('arena', { text: 'draw' });
    this.say(`${an} tied the opponent ${bn} in a REFEREE's decision!`);
    losers = [a, b];
  }
  for (const loser of losers) {
    st.judged[loser.side].push(int(loser.mon.slot, 0));
    this._faintBattler(loser, true);
  }
  this.judgeEnding = true;
  this._checkOver();
  this.judgeEnding = null;
};

// BattleTurnPassed's counter and "Commence battling!" when it wraps to 0.
Ba._arenaTurnPassed = function _arenaTurnPassed() {
  const st = this.arenaState;
  if (!st) return;
  st.counter = (st.counter + 1) % M.COUNTER_WRAP;
  if (st.counter === 0) this._emit('arena', { text: 'start' });
};

// The outcome's `judged`, side by side, only for a side that lost one.
Ba._arenaJudged = function _arenaJudged() {
  const st = this.arenaState;
  if (!st) return null;
  const out = {};
  let any = false;
  for (const side of ['a', 'b']) {
    if (st.judged[side].length > 0) {
      out[side] = st.judged[side].slice();
      any = true;
    }
  }
  return any ? out : null;
};

M.install = function install(Battle) {
  for (const k of Object.keys(Ba)) Battle.prototype[k] = Ba[k];
};

module.exports = M;
