'use strict';

/*
 * Gen 3 end of turn, battle start and switch-in effects.
 *
 * Node twin of src/BattleSim3/Residual.lua: engine residuals.lua
 * (`collectEvents`, `sortedBattlers` pokefirered/src/battle_util.c:484
 * ENDTURN_ORDER) and residual_handlers.lua (every phase, pret battle_util.c:453
 * DoFieldEndTurnEffects, :722 DoBattlerEndTurnEffects, :1064
 * HandleFaintedMonActions / Future Sight / Perish Song), plus engine.lua
 * `battleStartEffects` (battle_main.c:2856) and `switchInEffects`
 * (battle_script_commands.c:4960).
 *
 * Installed on Battle by Turn.js (`Residual.install(Battle)`), beside Move.js's
 * helper surface.
 *
 * `turnPriority` is a Map keyed by battler (the Lua keys a table by the
 * battler table itself; a JS object would stringify every key to the same
 * "[object Object]").
 *
 * Nothing here throws.
 */

const Damage = require('./Damage.js');
const Status = require('./Status.js');
const Abilities = require('./Abilities.js');
const Items = require('./Items.js');
const Field = require('./Field.js');
const Types = require('./Types.js');
const Move = require('./Move.js');
const { int, truthy, at } = require('./lua.js');

const M = {};

const Bm = {};

const WEATHER_START_TEXT = {
  RAIN: 'It is raining.',
  SUN: 'The sunlight is strong.',
  SAND: 'A sandstorm is raging.',
  HAIL: 'It is hailing.',
};

// ------------------------------------------------------------------
// speed and order
// ------------------------------------------------------------------

// The live wrappers over Field.speed / Field.sortRows (pure, vector-pinned).
Bm._speedOf = function _speedOf(b) {
  return Field.speed(b, this.weather(), this.randomTurnNumber);
};

Bm._orderRows = function _orderRows(rows) {
  return Field.sortRows(rows, this.rng, this.TIE_BREAK_ROLL);
};

// The standing battlers by speed (battle start, end of turn): `pri` is this
// turn's move priority for a battler that fought (ENDTURN_ORDER reads the
// chosen moves), 0 otherwise.
Bm._speedOrder = function _speedOrder(priorities) {
  const rows = [];
  const active = this.active();
  for (let i = 1; i <= active.length; i += 1) {
    const b = active[i - 1];
    let pri = 0;
    if (priorities) {
      const p = priorities.get(b);
      pri = truthy(p) ? p : 0;
    }
    rows.push({
      b, pri, spe: this._speedOf(b), order: i,
    });
  }
  this._orderRows(rows);
  const out = [];
  for (const r of rows) out.push(r.b);
  return out;
};

// ------------------------------------------------------------------
// switch-in (battle_script_commands.c:4960 switchineffects)
// ------------------------------------------------------------------

Bm.switchInEffects = function switchInEffects(b, optsIn) {
  const opts = optsIn || {};
  if (!b || truthy(this.result)) return false;
  if (truthy(opts.spikes)) {
    const layers = int(this.sides[b.side].spikes, 0);
    if (layers > 0 && !Abilities.isType(b, Types.ID.FLYING) && b.ability !== 'LEVITATE') {
      const denom = [8, 6, 4][Math.min(layers, 3) - 1];
      const dmg = Math.max(1, Math.floor(b.mon.maxHp / denom));
      this.loseHp(b, dmg);
      this.say(`${this.nameOf(b)} is hurt by SPIKES!`);
      if (b.mon.hp <= 0) {
        this._faintBattler(b);
        return true;
      }
    }
  }
  if (b.mon.hp <= 0) return false;
  if (b.ability === 'TRUANT') b.truantCounter = 1;
  let did = Abilities.switchIn(this, b);
  if (!truthy(did)) did = Items.onSwitchIn(this, b);
  if (!truthy(opts.deferIntimidate)) {
    for (let n = 1; n <= Move.PASS_CAP; n += 1) {
      if (!(truthy(Abilities.runIntimidate(this)) || truthy(Abilities.runTrace(this)))) break;
      did = true;
    }
  }
  return did;
};

// pokefirered/src/battle_main.c:2856 (after the opening send-outs)
Bm._battleStart = function _battleStart() {
  const w = Field.kind(this.initialWeather);
  if (w) {
    this.field.weather = w;
    this.field.weatherTurns = 0;
    this._emit('weather', { text: w, amount: 1 });
    this.say(WEATHER_START_TEXT[w]);
  }
  const order = this._speedOrder();
  for (const b of order) {
    if (!truthy(this.result)) Abilities.switchIn(this, b);
  }
  for (let n = 1; n <= Move.PASS_CAP; n += 1) {
    if (!(truthy(Abilities.runIntimidate(this)) || truthy(Abilities.runTrace(this)))) break;
  }
  for (const b of order) {
    if (b.mon.hp > 0) Items.onSwitchIn(this, b);
  }
  this._faintSweep();
};

// ------------------------------------------------------------------
// end of turn
// ------------------------------------------------------------------

const SIDE_TIMERS = [
  { key: 'reflectTurns', phase: 'reflect', name: 'REFLECT' },
  { key: 'lightScreenTurns', phase: 'light_screen', name: 'LIGHT SCREEN' },
  { key: 'mistTurns', phase: 'mist', name: 'MIST' },
  { key: 'safeguardTurns', phase: 'safeguard', name: 'SAFEGUARD' },
];

// The occupant of a field slot, standing, or null.
Bm._standingAt = function _standingAt(slot) {
  const f = this._fighterAtSlot(slot);
  const b = f ? f.b : null;
  if (b && b.mon.hp > 0) return b;
  return null;
};

// The battler a field slot holds as the cart's gBattleMons[position] does: the
// occupant whether standing or not, else the last battler that stood there (a
// seat emptied by a faint keeps its fainted mon's data until someone switches
// in). Never null for a seat that has fielded a battler.
Bm._occupantAt = function _occupantAt(slot) {
  const f = this._fighterAtSlot(slot);
  if (!f) return null;
  return f.b || f.lastB || null;
};

Bm._sideName = function _sideName(side) {
  const f = this.bySide[side] ? this.bySide[side][0] : null;
  return (f && truthy(f.name)) ? f.name : `side ${side}`;
};

// pokefirered/src/battle_util.c:505 (one timer, both sides, side a first)
Bm._tickSideTimer = function _tickSideTimer(row) {
  for (const side of ['a', 'b']) {
    const s = this.sides[side];
    if (int(s[row.key], 0) > 0) {
      s[row.key] -= 1;
      if (s[row.key] <= 0) {
        s[row.key] = 0;
        this.say(`${this._sideName(side)}'s ${row.name} wore off!`);
      }
    }
  }
};

// pokefirered/src/battle_util.c:603
Bm._tickWish = function _tickWish() {
  for (const side of ['a', 'b']) {
    const s = this.sides[side];
    const keep = [];
    for (const tok of s.wish) {
      tok.turns -= 1;
      if (tok.turns <= 0) {
        const b = this._standingAt(tok.slot);
        if (b) {
          // src/battle_script_commands.c:8916
          this.say(`${tok.wisher}'s WISH came true!`);
          if (b.mon.hp >= b.mon.maxHp) {
            this.say(`${this.nameOf(b)}'s HP is full!`);
          } else {
            let heal = Math.floor(b.mon.maxHp / 2);
            if (heal === 0) heal = 1;
            this.heal(b, heal);
            this.say(`${this.nameOf(b)} regained health!`);
          }
        }
      } else {
        keep.push(tok);
      }
    }
    s.wish = keep;
  }
};

const WEATHER_END_TEXT = {
  RAIN: 'The rain stopped.',
  SUN: 'The sunlight faded.',
  SAND: 'The sandstorm subsided.',
  HAIL: 'The hail stopped.',
};
const WEATHER_GOES_ON_TEXT = {
  RAIN: 'Rain continues to fall.',
  SUN: 'The sunlight is strong.',
  SAND: 'The sandstorm rages.',
  HAIL: 'Hail continues to fall.',
};

// pokefirered/src/battle_util.c:624 (weather continues / ends; sand and hail chip)
Bm._tickWeather = function _tickWeather(order) {
  const kind = Field.kind(this.field.weather);
  if (!kind) return;
  const turns = int(this.field.weatherTurns, 0);
  let ended = false;
  if (turns > 0) {
    this.field.weatherTurns = turns - 1;
    ended = this.field.weatherTurns <= 0;
  }
  if (ended) {
    this.field.weather = null;
    this.field.weatherTurns = 0;
    this._emit('weather', { text: kind, amount: 0 });
    this.say(WEATHER_END_TEXT[kind]);
    return;
  }
  this._emit('weather', { text: kind, amount: 2 });
  this.say(WEATHER_GOES_ON_TEXT[kind]);
  if (kind !== 'SAND' && kind !== 'HAIL') return;
  if (!truthy(this.weather())) return;
  for (const b of order) {
    if (b.mon.hp > 0 && !Field.weatherImmune(b, kind)) {
      this.say(this.nameOf(b) + (kind === 'SAND' ? ' is buffeted by the sandstorm!' : ' is pelted by HAIL!'));
      this.loseHp(b, Field.chip(b.mon.maxHp));
      this._faintSweep();
    }
  }
};

// The per-battler phases (battle_util.c:722). Returns nothing; faints are
// announced by the caller after each step.
const PHASE = {};

PHASE.ingrain = function ingrain(B, b) {
  if (!truthy(b.ingrain) || b.mon.hp >= b.mon.maxHp) return;
  let heal = Math.floor(b.mon.maxHp / 16);
  if (heal === 0) heal = 1;
  B.say(`${B.nameOf(b)} absorbed nutrients with its roots!`);
  B.heal(b, heal);
};

PHASE.abilities = function abilities(B, b) { Abilities.endTurn(B, b); };

PHASE.held_items = function heldItems(B, b) { Items.normal(B, b, false); };

// ENDTURN_ITEMS2 (battle_util.c:785): the moveTurn pass, per battler.
PHASE.held_items2 = function heldItems2(B, b) { Items.normal(B, b, true); };

// pokefirered/src/battle_util.c:789
PHASE.leech_seed = function leechSeed(B, b) {
  if (b.seededBy == null) return;
  const src = B._standingAt(b.seededBy);
  if (!src || b.mon.hp <= 0) return;
  let dmg = Math.floor(b.mon.maxHp / 8);
  if (dmg === 0) dmg = 1;
  const dealt = B.loseHp(b, dmg);
  if (b.ability === 'LIQUID_OOZE') {
    B.emitAbility(b);
    B.loseHp(src, dealt);
    B.say('It sucked up the liquid ooze!');
  } else {
    B.heal(src, dealt);
    B.say(`${B.nameOf(b)}'s health is sapped by LEECH SEED!`);
  }
};

// pokefirered/src/battle_util.c:805
PHASE.status_chip = function statusChip(B, b) {
  const s = Status.normalise(b.mon.status);
  if (!s) return;
  const [amount, counter] = Status.chip(s, b.mon.maxHp, b.toxicCounter);
  if (amount == null) return;
  if (counter != null) b.toxicCounter = counter;
  B.say(B.nameOf(b) + Status.CHIP_TEXT[s]);
  B.loseHp(b, amount, { status: s });
};

// pokefirered/src/battle_util.c:841
PHASE.nightmare = function nightmare(B, b) {
  if (!truthy(b.nightmare) || b.mon.hp <= 0) return;
  if (Status.normalise(b.mon.status) !== 'SLP') {
    delete b.nightmare;
    return;
  }
  let dmg = Math.floor(b.mon.maxHp / 4);
  if (dmg === 0) dmg = 1;
  B.say(`${B.nameOf(b)} is locked in a NIGHTMARE!`);
  B.loseHp(b, dmg);
};

// pokefirered/src/battle_util.c:861
PHASE.curse = function curse(B, b) {
  if (!truthy(b.cursed) || b.mon.hp <= 0) return;
  let dmg = Math.floor(b.mon.maxHp / 4);
  if (dmg === 0) dmg = 1;
  B.say(`${B.nameOf(b)} is afflicted by the CURSE!`);
  B.loseHp(b, dmg);
};

// pokefirered/src/battle_util.c:872
PHASE.partial_trap = function partialTrap(B, b) {
  if (int(b.trapTurns, 0) <= 0 || b.mon.hp <= 0) return;
  b.trapTurns -= 1;
  const label = B.moveLabelByNum(b.trapMove);
  if (b.trapTurns > 0) {
    B._emit('anim', { slot: b.slot, side: b.side, text: 'TURN_TRAP' });
    B.say(`${B.nameOf(b)} is hurt by ${label}!`);
    B.loseHp(b, Field.chip(b.mon.maxHp, Field.TRAP_CHIP_DENOM));
  } else {
    delete b.trapTurns;
    delete b.trapMove;
    delete b.trapSource;
    B.say(`${B.nameOf(b)} was freed from ${label}!`);
  }
};

// pokefirered/src/battle_util.c:904
PHASE.uproar = function uproar(B, b) {
  if (int(b.uproarTurns, 0) <= 0) return;
  for (const other of B.active()) {
    if (Status.normalise(other.mon.status) === 'SLP' && other.ability !== 'SOUNDPROOF') {
      delete other.nightmare;
      B.cure(other, `${B.nameOf(other)} woke up in the UPROAR!`);
    }
  }
  b.uproarTurns -= 1;
  if (truthy(b.unableToMove)) {
    B.cancelMultiTurn(b);
    B.say(`${B.nameOf(b)} calmed down.`);
  } else if (b.uproarTurns > 0) {
    B.say(`${B.nameOf(b)} is making an UPROAR!`);
  } else {
    B.cancelMultiTurn(b);
    B.say(`${B.nameOf(b)} calmed down.`);
  }
};

// pokefirered/src/battle_util.c:953
PHASE.thrash = function thrash(B, b) {
  if (int(b.rampageTurns, 0) <= 0) return;
  b.rampageTurns -= 1;
  if (truthy(b.unableToMove)) {
    B.cancelMultiTurn(b);
  } else if (b.rampageTurns <= 0 && truthy(b.lockedNum)) {
    delete b.lockedNum;
    delete b.lockedSlot;
    delete b.lockedTarget;
    delete b.rampageTurns;
    if (int(b.confusion, 0) <= 0 && b.ability !== 'OWN_TEMPO') {
      b.confusion = B.roll(0, 3) + 2;
      const text = `${B.nameOf(b)} became confused due to fatigue!`;
      B._emit('status', {
        slot: b.slot, side: b.side, confused: 1, text,
      });
      B.say(text);
    }
  }
};

// pokefirered/src/battle_util.c:975
PHASE.disable = function disable(B, b) {
  if (!truthy(b.disabledNum)) return;
  if (!truthy(B.slotOfNum(b, b.disabledNum))) {
    delete b.disabledNum;
    delete b.disableTurns;
    return;
  }
  b.disableTurns = int(b.disableTurns, 1) - 1;
  if (b.disableTurns <= 0) {
    delete b.disabledNum;
    delete b.disableTurns;
    B.say(`${B.nameOf(b)} is disabled no more!`);
  }
};

// pokefirered/src/battle_util.c:998
PHASE.encore = function encore(B, b) {
  if (int(b.encoreTurns, 0) <= 0) return;
  const slot = b.encoreSlot;
  if (!truthy(slot) || !truthy(at(b.moves, slot)) || int(at(b.moves, slot).num, 0) !== b.encoreNum) {
    delete b.encoreNum;
    delete b.encoreTurns;
    delete b.encoreSlot;
    return;
  }
  b.encoreTurns -= 1;
  if (b.encoreTurns <= 0 || int(at(b.moves, slot).pp, 0) <= 0) {
    delete b.encoreNum;
    delete b.encoreTurns;
    delete b.encoreSlot;
    B.say(`${B.nameOf(b)}'s ENCORE ended!`);
  }
};

PHASE.lock_on = function lockOn(B, b) {
  if (int(b.lockedOnTurns, 0) > 0) {
    b.lockedOnTurns -= 1;
    if (b.lockedOnTurns <= 0) {
      delete b.lockedOnTurns;
      delete b.lockedOnBy;
    }
  }
};

PHASE.charge = function charge(B, b) {
  if (int(b.charged, 0) > 0) {
    b.charged -= 1;
    if (b.charged <= 0) delete b.charged;
  }
};

PHASE.taunt = function taunt(B, b) {
  if (int(b.tauntTurns, 0) > 0) {
    b.tauntTurns -= 1;
    if (b.tauntTurns <= 0) delete b.tauntTurns;
  }
};

// pokefirered/src/battle_util.c:1032
PHASE.yawn = function yawn(B, b) {
  if (int(b.yawnTurns, 0) <= 0) return;
  b.yawnTurns -= 1;
  if (b.yawnTurns > 0) return;
  delete b.yawnTurns;
  const ab = b.ability;
  if (truthy(Status.normalise(b.mon.status)) || ab === 'VITAL_SPIRIT' || ab === 'INSOMNIA') return;
  if (truthy(B.uproarActive()) && ab !== 'SOUNDPROOF') return;
  B.cancelMultiTurn(b);
  B.inflict(b, 'SLP', { source: b });
};

PHASE.volatiles = function volatiles(B, b) {
  delete b.unableToMove;
};

M.PHASE = PHASE;

// pokefirered/data/battle_scripts_1.s:3461 (the delayed hit lands). The damage
// was fixed at use from the user's stats and level (Effects.js FUTURE_SIGHT);
// the attacker here is only the seat, as pret's gBattlerAttacker =
// futureSightAttacker[target] is a battler position (battle_util.c:1093): its
// present occupant, or -- when the user fainted and nobody has replaced it (the
// replace phase comes after the end of turn, or the bench is empty) -- the
// fainted user itself, which still lands the hit.
Bm._futureSightHit = function _futureSightHit(tok, target) {
  const attacker = this._occupantAt(tok.attackerSlot);
  this.say(`${this.nameOf(target)} took the ${this.moveLabel(tok.move)} attack!`);
  const C = Move.newCtx(this, attacker, target, tok.move, null, { futureSight: true });
  C.accOverride = int(tok.move.accuracy, 90);
  if (!truthy(C.accuracyCheck('normal', false))) {
    this.say('But it failed!');
    return;
  }
  let dmg = int(tok.damage, 1);
  dmg = Math.floor(dmg * this.roll(Damage.ROLL_MIN, Damage.ROLL_MAX) / 100);
  if (dmg === 0) dmg = 1;
  let hung;
  [dmg, hung] = this._adjustDamage(C, target, dmg);
  this._emit('anim', {
    slot: target.slot,
    side: target.side,
    text: truthy(tok.doom) ? 'DOOM_DESIRE_HIT' : 'FUTURE_SIGHT_HIT',
  });
  this._dealDamage(C, dmg, { physical: false });
  if (hung === 'endured') {
    this.say(`${this.nameOf(target)} endured the hit!`);
  } else if (hung === 'hung') {
    Items.focusBandMessage(this, target);
  }
};

// pokefirered/src/battle_util.c:1083.  On the cart the fainted-mon handling
// (HandleFaintedMonActions) sends every replacement in BEFORE this step, so a
// hit due at a seat emptied this turn lands on the newcomer.  Here the replace
// phase follows the end of turn, so such a token waits at 0 (`pending`) and
// `_landPendingFutureSight` fires it once the seat is filled.  A seat left
// empty (no living bench: pret's absent battler, skipped) drops it; one a
// Revive re-armed this turn is owed a mon again (Turn.js `_refreshVacant`),
// so its hit waits too.
Bm._tickFutureSight = function _tickFutureSight() {
  for (const f of this.order) {
    const side = this.sides[f.side];
    const keep = [];
    for (const tok of side.futureSight) {
      if (tok.targetSlot === f.slot) {
        tok.turns -= 1;
        if (tok.turns <= 0) {
          const target = this._standingAt(f.slot);
          if (target) {
            this._futureSightHit(tok, target);
          } else if (truthy(f.mustReplace)) {
            tok.turns = 0;
            keep.push(tok);
          }
        } else {
          keep.push(tok);
        }
      } else {
        keep.push(tok);
      }
    }
    side.futureSight = keep;
    this._faintSweep();
  }
};

// The due hits that waited for a replacement (above), after the replace
// phase's switch-ins; one that still finds its seat empty keeps waiting only
// while that seat is owed a mon.
Bm._landPendingFutureSight = function _landPendingFutureSight() {
  for (const f of this.order) {
    if (truthy(this.result)) return;
    const side = this.sides[f.side];
    const keep = [];
    let any = false;
    for (const tok of side.futureSight) {
      if (tok.targetSlot === f.slot && tok.turns <= 0) {
        const target = this._standingAt(f.slot);
        if (target) {
          any = true;
          this._futureSightHit(tok, target);
        } else if (truthy(f.mustReplace)) {
          keep.push(tok);
        }
      } else {
        keep.push(tok);
      }
    }
    side.futureSight = keep;
    if (any) this._faintSweep();
  }
};

// pokefirered/src/battle_util.c:1116
Bm._tickPerishSong = function _tickPerishSong(order) {
  for (const b of order) {
    if (b.perishTurns != null && b.mon.hp > 0) {
      const n = b.perishTurns;
      this.say(`${this.nameOf(b)}'s PERISH count fell to ${n}!`);
      if (n <= 0) {
        delete b.perishTurns;
        this.loseHp(b, b.mon.hp);
        this._faintSweep();
      } else {
        b.perishTurns = n - 1;
      }
    }
  }
};

// The whole end of turn (engine residuals.lua collectEvents).
Bm._endTurn = function _endTurn() {
  if (truthy(this.result)) return;
  // pokefirered/src/battle_main.c:2957
  for (const b of this.active()) {
    delete b.protected;
    delete b.enduring;
  }
  const order = this._speedOrder(this.turnPriority);

  for (const row of SIDE_TIMERS) this._tickSideTimer(row);
  this._tickWish();
  this._tickWeather(order);

  for (const b of order) {
    for (const phase of Field.BATTLER_PHASES) {
      if (b.mon.hp <= 0 || b.fighter.b !== b) break;
      PHASE[phase](this, b);
      const fainted = b.mon.hp <= 0;
      this._faintSweep();
      if (fainted && Field.FAINT_HALT[phase]) break;
    }
  }

  this._afterAction();
  this._faintSweep();
  this._tickFutureSight();
  this._tickPerishSong(order);
  this._faintSweep();
};

M.install = function install(Battle) {
  for (const k of Object.keys(Bm)) Battle.prototype[k] = Bm[k];
};

module.exports = M;
