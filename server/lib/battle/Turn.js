'use strict';

/*
 * The turn machine: choices in, events out, and one party deciding.
 *
 * Node twin of src/BattleSim/Turn.lua, and the only file under lib/battle/ with
 * state. The formula modules beside it each answer a single question with no
 * memory; this owns the field, the clock, the RNG stream and the order the
 * questions get asked in. A battle brokered here is resolved by *one* process
 * -- this hub, or a LAN host running the Lua half -- and the clients receive an
 * ordered stream of events they draw. They are never asked what happened.
 *
 * **The RNG order is the contract.** The Lua twin has to consume draws at
 * exactly the same points or the same seed produces a different fight, so every
 * draw site is spelled out here and every one of them is conditional in a way
 * both runtimes can reproduce:
 *
 *   0. a coop_wild RUN's escape byte, before anything else in the turn
 *      (TryRunningFromBattle, `_tryRun`) -- none for a runner at least as
 *      fast as the wild monster, or past the odds; then the players'
 *      switches and items (a ball's catch bytes);
 *   0b. the computer's move choice, where MainInBattleLoop's
 *      `.selectEnemyMove` runs SelectEnemyMove (`_selectComputerMoves`), per
 *      computer seat in field order: `.chooseRandomMove`'s byte(s), redrawn
 *      past an empty or disabled slot -- after a trainer's AI layers
 *      (`_aiTrainerMoves`), which draw nothing -- and none at all for a
 *      forced turn, a monster asleep or frozen, or one knowing a single
 *      disabled move (STRUGGLE);
 *   1. a speed tie-break byte, one per group of actors in one priority
 *      bracket at one Speed -- and every battler on the field is an actor
 *      there, whatever its seat chose (a switch, an item, a recharge, a held
 *      monster's CANNOT_MOVE all take part in MainInBattleLoop's compare);
 *   1b. TrainerAI's `Random` byte, in a computer trainer seat's own slot of
 *      the order, before its move (`_trainerAi`) -- drawn while the seat's
 *      wAICount is not 0, GenericAI's included, and never for a wild monster
 *      or a link fight's seat; the class routine and the AI's item or switch
 *      draw nothing else;
 *   2. the gates (`_runGates`): sleep and freeze draw nothing; a confused
 *      monster draws its self-hit byte only when still confused after the
 *      counter's step (the snap-out turn draws none); paralysis its byte;
 *   3. a Bide store or unleash, and a trap's later turns, draw nothing; a
 *      thrash's last turn draws its confusion length;
 *   4. the obedience rolls of a traded monster over its trainer's badge cap
 *      (`_obey`, Status' obedience section: CheckForDisobedience's loops, the
 *      instead-move, nap and loaf draws) -- a fight with no traded monster on
 *      the player's side draws none of them;
 *   5. per move that is actually used, PlayerCalcMoveDamage's order:
 *      THRASH's or a trapping move's counter, then the crit byte (none at
 *      power 0), the damage roll -- only for a damage of 2 or more after the
 *      type chart (RandomizeDamage's `cp 2` / `ret c`: an immunity or a hit
 *      already at 0 or 1 draws none) -- and only then MoveHitTest's accuracy
 *      byte (none for DREAM EATER into a waking target, SWIFT, an
 *      invulnerable or a Misted target, X Accuracy; drawn for an immunity or a
 *      0.25x zero too), so a missed move has spent its crit byte and its roll;
 *      then, after the first hit, the two-to-five count byte(s)
 *      (TwoToFiveAttacksEffect: one, or two when the first is a 2 or 3; none
 *      when that hit broke a Substitute), then the side-chance byte (damaging
 *      hits only). An OHKO move into a faster target misses after its crit
 *      byte. COUNTER draws its crit byte, then -- when its conditions hold
 *      (`_counterDamage`) -- its accuracy byte. A power-0 move draws only what
 *      its own routine draws (Effects.statusPlan), its turn-aways before its
 *      accuracy byte. The
 *      side-chance byte is the effect's own pokered routine's, drawn where
 *      and when that routine draws it (Effects.applySide): never on a target
 *      that fainted or a Substitute the move broke, not by a poison / burn /
 *      freeze / paralysis / flinch / stat-drop routine whose target it
 *      already turned away (a Substitute, a status, a type), and behind the
 *      computer's extra stat-drop miss byte when the computer drops a stat.
 *
 * Nothing else rolls. Residuals, switches, items and the clock are all
 * deterministic, so a battle replays from its seed plus the choice log.
 *
 * **Policies chosen where Gen 1 had no answer** -- the whole list, and the
 * reasoning behind each, lives in the Lua header rather than being restated
 * here; what follows is only what the port has to keep true:
 *
 *   * *Turn order* is the priority bracket (Effects.movePriority: QUICK_ATTACK
 *     +1, COUNTER -1, off the selected move), then the stored Speed, then the
 *     tie-break (`_orderActors`); a player's switch and item resolve before
 *     any move but the seat still takes part in the compare, and the
 *     computer's item or switch is TrainerAI's, in its own slot of the order
 *     (`_trainerAi`), in the bracket of the move SelectEnemyMove picked --
 *     which an AI that acts skips.
 *   * *Speed ties* break on a single byte per tied group -- one bracket at one
 *     Speed -- below 128 leaving the side-a member first and otherwise
 *     reversing the group.
 *   * *Running* is mode-gated like Teleport: wild/coop_wild flee, 1v1/coop_pvp
 *     concede, coop_npc refuses the RUN at the menu (nothing filed, the turn
 *     unspent, the line the client's own). A coop_wild runner rolls
 *     TryRunningFromBattle's odds first (`_tryRun`, RUN_ROLL_MODES); solo's
 *     `wild` is rolled by its client before the run is filed.
 *   * *Items* apply a hand-authored Gen1 heal/status table (not engine
 *     ItemEffects); unknown ids say "It won't have any effect." and still
 *     spend the turn. A known item the cart's ItemUseFailed would hand back --
 *     no effect, or not the time -- is refused at the menu, unfiled, its bag
 *     stack and the turn kept (`_itemFails`).
 *     Bags are client claims (sheet trust locked). Forced lock-in (recharge,
 *     Rage, thrash, a charge's release) injects on openTurn (no menu) and
 *     plays in the monster's own slot, past the gates: a recharge
 *     (`_rechargeTurn`), a trap's later hit (`_trapTurn`), a held monster's
 *     silent CANNOT_MOVE; forced-only turns defer to the next tick. A
 *     player's Bide user, trapper or held monster gets the battle menu, and
 *     its FIGHT is the lock-in (`_menuFight`); the computer's are filled and
 *     re-pick once a player's switch or item let their trap go
 *     (`_reselectComputer`).
 *   * *Metronome* picks from host-uploaded metronomePool on the ruleset. A
 *     called move runs no gate and is never Struggle: a call made with the
 *     last PP takes no recoil.
 *   * *Obedience*: a `badgeRules` seat (side a of BADGE_MODES) runs
 *     CheckForDisobedience for a monster whose sheet says `traded`; link
 *     fights and side b never roll (`_obey`).
 *   * *The flinch reset* at a turn's open skips a `badgeRules` seat's own
 *     raging or recharging monster; everywhere else it is unconditional.
 *   * *Physical / Special* via host-uploaded specialTypes (Gen1 type categories).
 *   * A *faint with a living bench opens the `replace` phase*, between the turn
 *     it happened on and the next one: the turn number does not move, no other
 *     seat is asked, and nothing resolves until every owed send-out is in --
 *     then `_resolveSwitches` fields them (`switch` + `send`) and the next turn
 *     opens. It runs on the same clock as a choice window, so an unanswered
 *     replacement is auto-picked exactly like an unanswered move.
 *   * Solicitation for that phase is a `turn` event carrying the owing seat's
 *     field `slot`, one per seat. A `turn` with `slot` asks that seat for a
 *     replacement; a `turn` without one opens the ordinary choice window.
 *   * *Residuals* (HandlePoisonBurnLeechSeed) come at the end of each
 *     battler's own slot, in the turn's order (MainInBattleLoop, core.asm
 *     :413-467; `_resolveFights`, `_residualFor`), with no end-of-turn pass.
 *     One seat a side is the cart's exactly: a slot that knocked the foe out
 *     skips the knocker-out's residual, a monster its own slot or residual
 *     took down ends the turn before the slower battler moves, and either
 *     faint skips CheckNumAttacksLeft. A 2v2 keeps the Gold referee's policy
 *     (lib/battle2/Turn.js): each seat's residual right after its own slot,
 *     and every seat still acts after a faint.
 *   * The computer's MOVE is the cart's (`_computerChoice`): a wild monster's
 *     `.chooseRandomMove`, a trainer's AIEnemyTrainerChooseMoves over its
 *     seat's `aiMods`; its item and switch are TrainerAI's (contract K16,
 *     `_trainerAi`) over its seat's `aiClass` -- none is GenericAI -- and its
 *     send-out after a faint is EnemySendOut's, the first living monster in
 *     party order. The computer never files an item or a switch, and its bag
 *     is never read.
 *   * A *player's timeout* auto-picks with bag cures & heals (≤50% HP),
 *     X-items, SE damage, status / setup reading, and SE bench switches
 *     (`_autoChoice`: the mod's rule, not a cart behaviour) -- and the fight
 *     goes on.
 *   * The choice clock is *suspended while anybody is disconnected*.
 *     `submitChoice` also refuses a seat whose `connected` is false until
 *     `reconnect()`, because SESSION_LEAVE leaves the TCP up and would
 *     otherwise keep resolving turns through the pause. `_maybeResolve`
 *     waits on the same flag, so a leftover or forced fill cannot complete
 *     the turn while anyone is away; `reconnect()` asks it again.
 *   * *Battle stats are stored, not derived* (pokered's model): party,
 *     unmodified and battle (`cur`) stats per monster, loaded at switch-in,
 *     rebuilt per stage change through `Effects.changeStat` (both Gen 1
 *     glitches live there), read as-is by speed, damage and the self-hit; a
 *     crit reads the party stats and no screen.
 *   * *"The enemy" in a 2v2*: a move's stage change re-penalises the aimed
 *     seat, Rage the attacker, an X item and the self-hit's Reflect check the
 *     battler opposite (`_oppositeFoe`).
 *   * *One narrator, two screens* (contracts K17 / K18): a name the cart prints
 *     through <USER> / <TARGET> or an "Enemy @" line carries its side's mark
 *     (`named`, Events.named: `^a` / `^b`), a bare one stays bare; `\n` is the
 *     cart's `line` / `cont` / <SCROLL>, a `para` its own `msg`; any other
 *     event's `text` is the line read plain (Events.plain).
 *   * *A knockout faints after the move* (K19): the `faint` and all `_faint`
 *     does wait for the slot's end (`_reapKo`), where MainInBattleLoop tests
 *     the HP once Execute*Move has returned; two at once go side a first; a
 *     residual's knockout is its pass's own.
 *   * *A move's animation leads its used line* (the screen's order) and is
 *     taken back where the cart plays none (K20 / K22, `_dropMoveAnim`): a
 *     miss (EXPLODE_EFFECT excepted), a power-0 routine that failed, MIRROR
 *     MOVE, a Bide unleashed at 0. A charge turn plays ChargeEffect's
 *     (XSTATITEM_ANIM, FLY's TELEPORT, DIG's SLIDE_DOWN_ANIM), a Bide's first
 *     turn BideEffect's (XSTATITEM_ANIM). A move id played as a look only --
 *     the seeder's ABSORB, FLY's TELEPORT, a trap's later hit -- is `quiet`.
 *     A multi-hit move replays its animation before every hit after the
 *     first (`jp nz, GetPlayerAnimationType`); a thrash's first turn adds
 *     ThrashPetalDanceEffect's SHRINKING_SQUARE_ANIM between the used line
 *     and the move's animation, which moves behind it there; a
 *     side-effect status lands with its routine's ENEMY_HUD_SHAKE_ANIM or
 *     SHAKE_SCREEN_ANIM ahead of its line (`_applySide`).
 *   * *TrainerAI in a 2v2* (coop_npc): each of the trainer's seats is "the
 *     enemy" for its own slot -- its own `aiClass` copy, its own wAICount
 *     (`aiCount`, $ff at each of its send-outs), its own monster and its own
 *     dealt hand for AISwitchIfEnoughMons and EnemySendOut.
 *
 * Two shape differences from the Lua, both forced by the language:
 *
 *   * `Damage.compute` takes one flat object here and four positional tables
 *     there. Same arithmetic, same field names, different call.
 *   * `create` cannot return a value *and* a reason, so it returns the battle
 *     or null, and `attempt` returns { battle, reason } for the caller that has
 *     a client waiting to be told why.
 *
 * Nothing here throws. Bad input is refused with a reason from `attempt` or a
 * plain `false` from `submitChoice`: a fight that stops mid-turn is worse than
 * one that declines a malformed choice.
 */

const Damage = require('./Damage.js');
const Accuracy = require('./Accuracy.js');
const Crit = require('./Crit.js');
const Status = require('./Status.js');
const Effects = require('./Effects.js');
const Rng = require('./Rng.js');
const Events = require('./events.js');

const VERSION = 1;

// Mirrored from Config rather than required, for the reason in events.js: this
// directory runs where Config does not.
const MONS_PER_PARTY = 6; // Config.BATTLE_MON_MAX
const FIGHTERS_PER_SIDE = 3; // Config.COOP_SIDE
const CHOICE_TIMEOUT = 60; // Config.BATTLE_CHOICE_TIMEOUT
const RECONNECT_GRACE = 60; // Config.BATTLE_RECONNECT_GRACE
const RESOLVE_TIMEOUT = 30; // Config.BATTLE_RESOLVE_TIMEOUT

// Below this the side-a member of a tied group moves first.
const TIE_BREAK_ROLL = 128;

// Where the aim stream starts, relative to the battle's own seed. See
// `_autoTarget`: the referee's choice of *whom* to swing at is drawn from a
// second generator so that adding it moved no roll in the first one, and a
// second generator started on the same number would be the same sequence read
// twice -- every aim would echo a damage roll. The offset is arbitrary and
// load-bearing only in that both runtimes use it.
const AIM_SEED_OFFSET = 1597334677;

const MODES = {
  '1v1': true, coop_npc: true, coop_pvp: true, wild: true, coop_wild: true,
};
const SIDES = ['a', 'b'];

// The modes an uploaded `badges` set counts in, and the one side it counts on.
//
// The fights against the computer, on the player's seats, because that is the
// only place the cart applies the x9/8 boosts at all: pokered's
// ApplyBadgeStatBoosts (engine/battle/core.asm) returns before it reads a
// badge when wLinkState is LINK_STATE_BATTLING ("return if link battle"), and
// walks wBattleMon -- the player's monster -- and nothing else. 1v1 and
// coop_pvp are link battles in everything but the cable, so both sides fight
// them unboosted, as the engine's own cable battle does (it builds its
// battlers with save = nil, gen1recomp src/link/LinkBattle.lua:61-68). Side b
// of the other three is the synthetic wild / trainer seat (see EXP_MODES
// below), which no cart boosts, so a set uploaded for it is a confused or a
// hostile client and is dropped the same way.
//
// The referee is the gate rather than the client or the hub: a client can
// forge an upload and a hub passes `badges` through untouched, and this is the
// one place both hubs and solo share. It is applied once, in `attempt`, where a
// seat's set is copied -- every reader after that (`_speedOf`, both ends of the
// damage step) sees null and needs no gate of its own.
const BADGE_MODES = { wild: true, coop_wild: true, coop_npc: true };
const BADGE_SIDE = 'a';

// wTotalPayDayMoney is three BCD bytes, and AddBCD saturates at 999999
// (engine/math/bcd.asm). `_checkOver`.
const PAY_DAY_MAX = 999999;

// The modes whose RUN the referee rolls (`_tryRun`, TryRunningFromBattle).
// coop_wild only: a solo `wild` RUN is rolled by its client before it is
// filed (src/SoloBattle.lua `_escapes`, off this battle's own RNG), and a
// second roll here would halve the odds the cart gives.
const RUN_ROLL_MODES = { coop_wild: true };

// How many TypeEffects rows a ruleset's `chartOrder` may name (pokered's
// table has 82; a chart is at most 16 types wide, so 256 cells).
const CHART_ORDER_MAX = 256;

// The modes a faint pays experience in -- the ones vanilla awards it in. 1v1
// and coop_pvp never do; see `_awardExp` for why the gate is the mode rather
// than an owner flag. Side a is where the owners sit in all three; side b is
// the synthetic wild / trainer seat.
const EXP_MODES = { wild: true, coop_wild: true, coop_npc: true };
const EXP_OWNER_SIDE = 'a';

// Mirrored from Wire.LEVEL_MAX (the cart's MAX_LEVEL); `levelUp`'s ceiling.
const LEVEL_MAX = 100;
const LEVEL_UP_STAT_EXP_MAX = 65535;

// Participation: who fought the monster that fell.
//
// Vanilla does not pay whoever happened to be standing when the foe dropped --
// it pays every monster of yours that was ever in against *that* foe and is
// still alive, benched included. The engine keeps it as one bitfield per party
// (`wPartyGainExpFlags`), and gen1recomp's port of it is the reference the
// twins mirror line for line:
//
//   * set on send-out. `BattleState:markParticipant`
//     (src/battle/BattleState.lua:2332-2337) flags the player mon that is out;
//     called at battle start (:1681), on a voluntary switch (:2424), on a
//     post-faint replacement (:4214) and again when the enemy sends its next
//     one out (:3980) -- the standing mon re-joins the new foe's set.
//   * cleared when the foe changes. `awardExp` ends with
//     `self.participants = {}` (:3899), so the set is per enemy MONSTER, not
//     per battle; the SHIFT arm zeroes it explicitly at the moment the enemy is
//     replaced (:4020, quoting core.asm:1436-1443). Gen 1 has no voluntary
//     enemy switch to cite, and the shift arm is the one place the cart states
//     what a foe swap does to the flags -- so a foe seat changing its monster
//     resets that seat's set here and re-marks the standing opposition,
//     exactly as :4020-4021 does.
//   * dropped on its own faint. `onFaint` does
//     `self.participants[battler.mon] = nil` (:3721-3723,
//     RemoveFaintedPlayerMon), so a participant that died before the KO is
//     neither paid NOR counted in the divisor.
//   * ...and the send-out's own mark (:3980) lands a turn late here, because a
//     seat is *asked* for its replacement rather than just sending one. It is
//     taken at the faint, against the field the faint happened on, and held in
//     `fighter.pendingFought` until `_refield` fields the successor. See
//     `_faint`; `_unfield` reaches the held copy too.
//
// The set lives per seat because a mediated fight has up to FIGHTERS_PER_SIDE
// foe seats, each with its own current monster; `fighter.fought` holds the
// opposing (field slot, party index) pairs that have been in against *this*
// seat's current one. Keys are strings so the two runtimes agree on membership
// without agreeing on iteration order -- nothing walks this table, it is only
// asked.
function foughtKey(slot, index) {
  return `${slot}:${index}`;
}

// Roster cap per side. coop_wild is N vs 1 wild (humans on a, wild on b) -- not
// exactly 2v1; other modes keep a single per-side ceiling (1 for 1v1/wild,
// FIGHTERS_PER_SIDE otherwise).
function maxFighters(mode, side) {
  if (mode === 'coop_wild') {
    return side === 'a' ? FIGHTERS_PER_SIDE : 1;
  }
  if (mode === '1v1' || mode === 'wild') return 1;
  return FIGHTERS_PER_SIDE;
}

// The wild monster's seat. Wildlife is always the synthetic side-b seat of a
// mode whose name says "wild" (the seat `maxFighters` caps at one above and
// `_awardExp` pays the other side for), and wildlife carries no bag: a wild
// monster never uses an item, no matter who asks on its behalf. It is a seat
// of the computer's, so both askers are gated with every other one --
// `_normaliseChoice` refuses a submitted item, `_computerChoice` never picks
// one, and TrainerAI never runs for it (`_runsTrainerAi`: wIsInBattle 1).
const WILD_SIDE = 'b';

function isWildSeat(mode, fighter) {
  return !!fighter && fighter.side === WILD_SIDE && Effects.isWildMode(mode);
}

// The computer's own seat: side b of a fight against the computer, the one
// side BADGE_MODES never boosts. Where the cart runs one routine for the
// player and another for its AI -- a status cure is the case: ItemUseMedicine
// rewrites the battle stats, AICureStatus does not -- this is the seat that
// takes the AI's. Every other seat (side a there, both sides of a link fight)
// is a player on its own cartridge.
function isComputerSeat(mode, fighter) {
  return !!fighter && BADGE_MODES[mode] === true && fighter.side !== BADGE_SIDE;
}

// "The player", by the owner's rule (docs/plans/gen12-referee-gaps-fix.md):
// a cart rule that touches only the player's side applies to side a against
// the computer and to BOTH sides of a link fight (1v1, coop_pvp) -- each
// player's own cart running it for its own monster. Every seat that is not
// the computer's. (Obedience and the badges stay on `badgeRules`: the cart
// returns before both in a link battle.)
function isPlayerSeat(mode, fighter) {
  return !!fighter && !isComputerSeat(mode, fighter);
}

// Auto-pick priorities (twin of Turn.lua AUTO_* tables).
const AUTO_STATUS_PRI = {
  32: 4, // SLEEP_EFFECT
  67: 3, // PARALYZE_EFFECT
  66: 2, // POISON_EFFECT
  49: 1, // CONFUSION_EFFECT
  84: 1, // LEECH_SEED_EFFECT
};
const AUTO_SETUP = {
  10: 'atk', 11: 'def', 12: 'spd', 13: 'spc',
  50: 'atk', 51: 'def', 52: 'spd', 53: 'spc',
  47: true, // FOCUS_ENERGY
  64: true, // LIGHT_SCREEN
  65: true, // REFLECT
  79: true, // SUBSTITUTE
};
const AUTO_HEAL_PREF = [
  'FULL_RESTORE', 'MAX_POTION', 'HYPER_POTION', 'SUPER_POTION',
  'LEMONADE', 'SODA_POP', 'FRESH_WATER', 'POTION',
];
const AUTO_STATUS_CURE = {
  poison: ['FULL_RESTORE', 'FULL_HEAL', 'ANTIDOTE'],
  toxic: ['FULL_RESTORE', 'FULL_HEAL', 'ANTIDOTE'],
  burn: ['FULL_RESTORE', 'FULL_HEAL', 'BURN_HEAL'],
  freeze: ['FULL_RESTORE', 'FULL_HEAL', 'ICE_HEAL'],
  sleep: ['FULL_RESTORE', 'FULL_HEAL', 'AWAKENING'],
  paralysis: ['FULL_RESTORE', 'FULL_HEAL', 'PARLYZ_HEAL'],
};
const AUTO_X_ITEM = [
  { id: 'X_ATTACK', stat: 'atk' },
  { id: 'X_DEFEND', stat: 'def' },
  { id: 'X_SPEED', stat: 'spd' },
  { id: 'X_SPECIAL', stat: 'spc' },
  { id: 'DIRE_HIT', flag: 'focusEnergy' },
  { id: 'GUARD_SPEC', flag: 'mist' },
];

// Default kit kept as a named gym-style reference. Not auto-seeded onto
// unclaimed coop_npc seats: hosts upload the trainer's own items, and a
// Youngster with an empty kit must stay empty (seeding this made 2v2s look
// like eight healing items).
const DEFAULT_NPC_BAG = {
  POTION: 2, SUPER_POTION: 1, FULL_HEAL: 1, X_ATTACK: 1,
};

// Wire spells a condition as a three-letter token and Status.js spells it as a
// word. Both are accepted on the way in and the token is what goes back out on
// an event, so neither vocabulary leaks into the other's file.
const STATUS_FROM_WIRE = {
  SLP: 'sleep', PSN: 'poison', BRN: 'burn',
  FRZ: 'freeze', PAR: 'paralysis', TOX: 'toxic',
};
const STATUS_TO_WIRE = {
  sleep: 'SLP', poison: 'PSN', burn: 'BRN',
  freeze: 'FRZ', paralysis: 'PAR', toxic: 'TOX',
};

// The conditions that can stop a move before it happens. Confusion is not here
// because in Gen 1 it is a volatile, not a status -- it rides on its own
// counter and is gated separately, after this one.
const GATING = { sleep: true, freeze: true, paralysis: true };

const ACTIONS = {
  fight: true, item: true, switch: true, run: true, cancel: true,
};

// Synthetic move used when every slot is out of PP. Not in any move table.
const STRUGGLE = {
  id: 'STRUGGLE', power: 50, accuracy: 255,
  type: 0, effect: 0, chance: 0,
};

// The move a thrash's continuation animates (`.ThrashingAboutCheck` writes
// THRASH into wPlayerMoveNum, core.asm :3529-3530): the `anim` event's id,
// the move registry's own, as STRUGGLE's is above.
const THRASH_ANIM = 'THRASH';

// AIMoveChoiceModification1's StatusAilmentMoveEffects (trainer_ai.asm):
// EFFECT_01 (the unused sleep), SLEEP_EFFECT, POISON_EFFECT, PARALYZE_EFFECT.
const AI_STATUS_EFFECTS = { 1: true, 32: true, 66: true, 67: true };
// AIMoveChoiceModification3's `.betterMoveFound` effects: SUPER_FANG_EFFECT,
// SPECIAL_DAMAGE_EFFECT, FLY_EFFECT.
const AI_BETTER_EFFECTS = { 40: true, 41: true, 43: true };
// AIGetTypeEffectiveness' starting value, $10 (the cart's own comment: it
// should have been EFFECTIVE, 10): what no matching row leaves.
const AI_NEUTRAL = 16;

// wAICount's $ff, which InitBattle and EnemySendOutFirstMon write (core.asm
// :1306-1307, :6685-6686) and TrainerAI reads as "reload from the class's
// TrainerAIPointers byte" (`inc a / jr nz, .getpointer`) -- `_trainerAi`.
const AI_COUNT_RELOAD = 255;
// GenericAI's TrainerAIPointers byte (`dbw 3, GenericAI`, ai_pointers.asm):
// the class a trainer with no record of its own runs.
const AI_GENERIC_USES = 3;
// AIRecoverHP's `ld b, N` (trainer_ai.asm :487-503): POTION 20, SUPER
// POTION 50, HYPER POTION 200, added to the HP and held at the maximum.
const AI_HEAL = { POTION: 20, SUPER_POTION: 50, HYPER_POTION: 200 };
// AIIncreaseStat's StatModifierUpEffect (:685-725): the UP1 effect each X
// item writes into wEnemyMoveEffect, one stage.
const AI_X_STAT = { X_ATTACK: 'atk', X_DEFEND: 'def', X_SPEED: 'spd', X_SPECIAL: 'spc' };

// ChargeEffect's animation (effects.asm :998-1030), which a charge turn plays
// in place of the move's: XSTATITEM_ANIM -- the enemy's turn loads
// XSTATITEM_DUPLICATE_ANIM, the same picture, sent as XSTATITEM_ANIM (K20)
// -- TELEPORT's for FLY_EFFECT, and SLIDE_DOWN_ANIM for DIG, whose test is
// the move's own number and comes last (`cp DIG` on the move struct), so it
// wins. TELEPORT is a move id played as a look: `quiet` (K22). Returns the
// id and the flag.
function chargeAnim(effectId, move) {
  if (Effects.isDigMove(move)) return ['SLIDE_DOWN_ANIM', null];
  if (Effects.isFly(effectId)) return ['TELEPORT', true];
  return ['XSTATITEM_ANIM', null];
}

// The sentences `.monDoesNothing` prints (pokered data/text/text_2.asm
// _LoafingAroundText .. _IgnoredOrdersText), keyed by Status.LOAF_LINES, with
// the monster's name in front -- the cart's English, punctuation included,
// and its breaks (K18). The name is wBattleMonNick, printed bare: only the
// player's monster ever disobeys, so the cart has no "Enemy" form (K17).
const LOAF_TEXT = {
  loafing: ' is\nloafing around.',
  wont_obey: " won't\nobey!",
  turned_away: ' turned\naway!',
  ignored_orders: '\nignored orders!',
};

// ItemUseBall's misses by shake count (`.printMessage`, wPokeBallAnimData
// $20 / $61 / $62 / $63: ItemUseBallText01..04) -- the cart's "#MON" is its
// charmap's "POKé" ($54) and ends in the é ($BA) a Red `msg` now carries
// (sanitize cleanBattleText), so POKéMON is spelled as the cart prints it.
const BALL_MISS_TEXT = {
  0: 'You missed the\nPOKéMON!',
  1: 'Darn! The POKéMON\nbroke free!',
  2: 'Aww! It appeared\nto be caught!',
  3: 'Shoot! It was so\nclose too!',
};

// The party menu's line for a status cure, by item (ItemUseMedicine's
// `lb bc, <ITEM>_MSG, ...`, party_menu.asm's AntidoteText .. FullHealText),
// after the monster's name (wNameBuffer, the party menu's: bare, K17) and
// with the menu text's breaks (K18). FULL RESTORE at full HP is a FULL HEAL.
const CURE_TEXT = {
  ANTIDOTE: ' was\ncured of poison!',
  BURN_HEAL: "'s\nburn was healed!",
  ICE_HEAL: ' was\ndefrosted!',
  AWAKENING: '\nwoke up!',
  PARLYZ_HEAL: "'s\nrid of paralysis!",
  FULL_HEAL: "'s\nhealth returned!",
};

// An item's name in a sentence: its id's words, which are the cart's item
// names (data/items/names.asm) -- "POKé BALL", "POKé DOLL", "POKé FLUTE" with
// the é a Red `msg` carries (sanitize cleanBattleText), GUARD SPEC.'s stop.
function itemLabel(id) {
  let label = String(id === undefined || id === null ? 'ITEM' : id).replace(/_/g, ' ');
  label = label.replace(/^POKE /, 'POKé ');
  if (label === 'GUARD SPEC') label = 'GUARD SPEC.';
  return label;
}

// A battler's name the way the cart's <USER> / <TARGET> print it
// (PlaceMoveUsersName / PlaceMoveTargetsName): the seat's side mark, then the
// name (Events.named, contract K17). Every marked name in this file comes
// through here; a name the cart prints bare is `mon.species` as it is.
function named(fighter, mon) {
  return Events.named(fighter ? fighter.side : undefined, mon ? mon.species : 'POKéMON');
}

// ItemUseNoEffectText, "It won't have any\neffect." (text_6.asm).
const NO_EFFECT_TEXT = "It won't have any\neffect.";
// The X items' stat names (`_xStatItem`).
const X_STAT_LABEL = {
  atk: 'ATTACK', def: 'DEFENSE', spd: 'SPEED',
  spc: 'SPECIAL', acc: 'ACCURACY', eva: 'EVADE',
};
// HurtItselfText (text_2.asm), the confusion self-hit's and a disobedient
// monster's.
const HURT_ITSELF_TEXT = 'It hurt itself in\nits confusion!';

const own = (object, key) => Object.prototype.hasOwnProperty.call(object, key);

const has = (table, key) => typeof key === 'string' && own(table, key);

// ------------------------------------------------------------------
// coercion
// ------------------------------------------------------------------

const toNumber = Events.toNumber;

// Lua's `int(value, fallback)`. `fallback` is returned for anything tonumber()
// would refuse, which includes booleans -- Number(true) is 1 and would quietly
// invent a move index out of a flag.
function int(value, fallback) {
  const n = toNumber(value);
  if (n === null) return fallback;
  return Math.floor(n);
}

function str(value) {
  if (typeof value === 'string' && value !== '') return value;
  return null;
}

// Lua's `type(x) == "table"`: arrays included, null excluded.
const isTable = (value) => typeof value === 'object' && value !== null;

// Lua's `x or false`: a base PP, or false for none (`copyMove`, `stepPp`).
function orFalse(value) {
  return value === null || value === undefined ? false : value;
}

function copyMove(raw) {
  if (!isTable(raw)) return null;
  const pp = Math.max(0, int(raw.pp, 0));
  const ppUps = Math.max(0, Math.min(3, int(raw.ppUps, 0)));
  // The sheet's maximum as stated -- the cart's GetMaxPP over the move's base
  // PP and its PP Ups -- even below `pp`: a slot past DecrementPP's wrap holds
  // 63 PP over it, as the cart's byte does (the client uploads the byte the
  // save holds), and raising the maximum to meet it hid GetMaxPP from every
  // reader (Effects.restorePp's ETHER, the `moves` rows). A sheet that
  // states none keeps the old reading, its PP.
  const stated = int(raw.maxPp, null);
  const maxPp = Math.max(0, stated !== null ? stated : pp);
  return {
    id: str(raw.id) || 'move',
    // Optional (PROTOCOL 26), and absence is a real answer rather than a gap
    // to fill: a sheet from a protocol-25 client states no name, and the
    // sentences below fall back to the id exactly as they always did.
    name: str(raw.name),
    pp,
    maxPp,
    // ...and the base PP behind it, when the stated number is a GetMaxPP
    // (Effects.basePpOf): what `stepPp` re-reads the maximum over once a wrap
    // moves the PP Up bits. false -- read, and none -- keeps the stated
    // maximum fixed; undefined is a row nobody read yet (`stepPp` reads it).
    basePp: stated !== null ? orFalse(Effects.basePpOf(maxPp, ppUps)) : false,
    power: Math.max(0, int(raw.power, 0)),
    accuracy: Math.max(0, int(raw.accuracy, 255)),
    type: Math.max(0, int(raw.type, 0)),
    effect: Math.max(0, int(raw.effect, 0)),
    chance: Math.max(0, int(raw.chance, 0)),
    // Optional sheet flag. Absent is a protocol-era client; Slash then uses
    // ordinary odds. The hub has no move table to recover it from.
    highCrit: raw.highCrit === true,
    // K8: the PP Ups on the move, the top two bits of the cart's PP byte.
    // Read where the cart reads the raw byte -- AnyMoveToSelect's disabled
    // branch (`mustStruggle`) and DisableEffect's slot pick -- and nowhere
    // else; 0 when the sheet states none.
    ppUps,
  };
}

// A K7 block (cleanBattleMon's `base` / `dvs` / `statExp`), whole or null:
// every key a number, clamped to `lo..hi`. A block missing a key is a bug on
// the sending side, and half a block would silently zero the rest.
const K7_BASE_KEYS = ['hp', 'atk', 'def', 'spd', 'spc'];
const K7_DV_KEYS = ['atk', 'def', 'spd', 'spc'];
function copyBlock(raw, keys, lo, hi) {
  if (!isTable(raw)) return null;
  const out = {};
  for (const key of keys) {
    const n = int(raw[key], null);
    if (n === null) return null;
    out[key] = Math.max(lo, Math.min(hi, n));
  }
  return out;
}

/*
 * What a move is *called* in a sentence: the display name its sheet carried
 * (PROTOCOL 26), or its registry id when it carried none.
 *
 * Prose only. An `anim` event carries the **id** and has to keep carrying it --
 * that is what a client looks the move animation and the move-menu label up by
 * -- so the two spellings are never interchangeable, and every call here is a
 * line somebody reads rather than a key something indexes.
 */
function moveLabel(move, fallback) {
  const back = fallback || 'move';
  if (!isTable(move)) return back;
  return str(move.name) || str(move.id) || back;
}

// A defender with no stated types is type 0, which the chart lookup reads as
// "whatever the first row says" and, absent a chart, as neutral. That is the
// right default for a sim that must never refuse a party over a missing
// optional.
function copyTypes(raw) {
  if (!Array.isArray(raw)) return [0];
  const out = raw.map((value) => Math.max(0, int(value, 0)));
  if (out.length === 0) return [0];
  return out;
}

// Every monster is deep-copied on the way in, and that is load-bearing rather
// than tidy: the caller's object is usually a party the client still owns and
// redraws, and a sim that damaged it in place would make "run the same fixture
// twice" produce two different fights -- which is exactly the property the
// determinism suite is built to catch.
//
// `slot` is the *sender's* party position for this monster, zero-based, the way
// cleanBattleMon carries it -- and it is kept rather than dropped because a
// switch names it. The two numbers are the same only while every monster the
// client uploaded survived the copy and landed in the same order, and neither is
// guaranteed: a mon this file cannot describe is skipped, a party past
// MONS_PER_PARTY is cut short, and a coop_npc trainer's team is dealt across two
// seats before it ever gets here. In all three the array index has moved and the
// position on the player's own screen has not, so the position is what a choice
// is matched against. `fallback` is that index for a sender that stated none,
// which keeps an ordinary party numbered exactly as it always was.
function copyStages(raw) {
  const src = isTable(raw) ? raw : {};
  return {
    atk: Effects.clampStage(src.atk),
    def: Effects.clampStage(src.def),
    spd: Effects.clampStage(src.spd),
    spc: Effects.clampStage(src.spc),
    acc: Effects.clampStage(src.acc),
    eva: Effects.clampStage(src.eva),
  };
}

function copyMon(raw, fallback) {
  if (!isTable(raw)) return null;

  const stats = isTable(raw.stats) ? raw.stats : {};
  const maxHp = Math.max(1, int(raw.maxHp, 1));
  let hp = raw.hp === undefined || raw.hp === null
    ? maxHp
    : Math.max(0, int(raw.hp, 0));
  if (hp > maxHp) hp = maxHp;

  let status = str(raw.status);
  if (status) status = has(STATUS_FROM_WIRE, status) ? STATUS_FROM_WIRE[status] : status;
  if (status && !(has(GATING, status) || status === 'poison'
                  || status === 'burn' || status === 'toxic')) {
    status = null; // a token nothing branches on is noise
  }

  const moves = [];
  if (Array.isArray(raw.moves)) {
    for (const entry of raw.moves) {
      const move = copyMove(entry);
      if (move) moves.push(move);
    }
  }

  // Sleep with no counter is read as one turn left, so it still costs the turn
  // it wakes on rather than passing the gate as if healthy. Any other default
  // would be inventing a length; one is the shortest honest answer.
  let turns = Math.max(0, int(raw.statusTurns, 0));
  if (status === 'sleep' && turns === 0) turns = 1;

  const stages = copyStages(raw.stages);

  let disable = null;
  if (isTable(raw.disable)) {
    disable = {
      moveIndex: Math.max(0, int(raw.disable.moveIndex, 0)),
      turns: Math.max(0, int(raw.disable.turns, 0)),
    };
  }

  let charging = null;
  if (isTable(raw.charging)) {
    charging = {
      moveIndex: Math.max(1, int(raw.charging.moveIndex, 1)),
      effect: Math.max(0, int(raw.charging.effect, 0)),
      targetSlot: int(raw.charging.targetSlot, null),
      moveId: str(raw.charging.moveId),
    };
  }

  let trapped = null;
  if (isTable(raw.trapped)) {
    trapped = {
      turns: Math.max(0, int(raw.trapped.turns, 0)),
      damage: Math.max(0, int(raw.trapped.damage, 0)),
      fromSlot: int(raw.trapped.fromSlot, null),
    };
  }

  let thrashing = null;
  if (isTable(raw.thrashing)) {
    thrashing = {
      turns: Math.max(0, int(raw.thrashing.turns, 0)),
      moveIndex: Math.max(1, int(raw.thrashing.moveIndex, 1)),
    };
  }

  // `turns` is the cart's counter (wPlayerNumAttacksLeft): each forced turn
  // takes one off, and the turn it reaches 0 -- or a sheet's 0 -- unleashes.
  let bide = null;
  if (isTable(raw.bide)) {
    bide = {
      turns: Math.max(0, int(raw.bide.turns, 0)),
      stored: Math.max(0, int(raw.bide.stored, 0)),
      moveIndex: Math.max(1, int(raw.bide.moveIndex, 1)),
      targetSlot: int(raw.bide.targetSlot, null),
    };
  }

  let leechSeed = null;
  if (raw.leechSeed === true) {
    leechSeed = { fromSlot: null };
  } else if (isTable(raw.leechSeed)) {
    leechSeed = { fromSlot: int(raw.leechSeed.fromSlot, null) };
  }

  const out = {
    species: str(raw.species) || '?',
    // The pokedex id behind that prose name, when the sender stated one. Kept
    // rather than dropped for the same reason `slot` is: no formula here reads
    // it and there is no species table to read it against, but it is the only
    // thing on the sheet that lets the client *opposite* draw this monster and
    // price the exp it is worth, and the referee is the only party that can
    // hand it over. Absent stays absent -- written below rather than here, so
    // a sheet without one carries no key at all (the shape Lua produces, and
    // the one the determinism fixtures compare against).
    slot: Math.max(0, int(raw.slot, Math.max(0, int(fallback, 0)))),
    level: Math.max(1, int(raw.level, 1)),
    hp,
    maxHp,
    status,
    statusTurns: turns,
    toxicCounter: Math.max(1, int(raw.toxicCounter, 1)),
    confusion: Math.max(0, int(raw.confusion, 0)),
    stats: {
      atk: Math.max(1, int(stats.atk, 1)),
      def: Math.max(1, int(stats.def, 1)),
      spd: Math.max(1, int(stats.spd, 1)),
      spc: Math.max(1, int(stats.spc, 1)),
    },
    // The party struct beside the unmodified stats above, and the battle
    // stats (`cur`) seeded from both once the seat's badges are known
    // (`attempt`). Effects' "Stored battle stats" note says who writes which.
    partyStats: {
      atk: Math.max(1, int(stats.atk, 1)),
      def: Math.max(1, int(stats.def, 1)),
      spd: Math.max(1, int(stats.spd, 1)),
      spc: Math.max(1, int(stats.spc, 1)),
    },
    cur: null,
    types: copyTypes(raw.types),
    moves,
    stages,
    leechSeed,
    disable,
    flinch: raw.flinch === true,
    charging,
    invulnerable: raw.invulnerable === true,
    mustRecharge: raw.mustRecharge === true,
    trapped,
    trapping: null,
    thrashing,
    raging: raw.raging === true,
    rageMove: Math.max(0, int(raw.rageMove, 0)),
    bide,
    lastMoveIndex: Math.max(0, int(raw.lastMoveIndex, 0)),
    substitute: Math.max(0, int(raw.substitute, 0)),
    lightScreen: raw.lightScreen === true,
    reflect: raw.reflect === true,
    mist: raw.mist === true,
    focusEnergy: raw.focusEnergy === true,
    transformed: raw.transformed === true,
    xAccuracy: raw.xAccuracy === true,
    catchRate: Math.max(0, Math.min(255, int(raw.catchRate, 255))),
  };

  // Optional Stat Exp sheet (atk/def/spd/spc, optional hp).
  if (isTable(raw.evs)) {
    const evs = {};
    for (const key of ['hp', 'atk', 'def', 'spd', 'spc']) {
      if (raw.evs[key] !== undefined && raw.evs[key] !== null) {
        evs[key] = Math.max(0, Math.min(65535, int(raw.evs[key], 0)));
      }
    }
    out.evs = evs;
  }
  const speciesId = str(raw.speciesId);
  if (speciesId) out.speciesId = speciesId;
  // Species base Speed for Gen 1 crit. Optional: a sheet that omits it falls
  // back to battle Speed without the badge boost.
  if (raw.baseSpd !== undefined && raw.baseSpd !== null) {
    out.baseSpd = Math.max(0, Math.min(255, int(raw.baseSpd, 0)));
  }
  // K7 (docs/plans/gen12-referee-gaps-fix.md): the species' base stats, the
  // four DVs and the five stat-exp words, each whole or absent. The crit
  // rate's base Speed when `baseSpd` is absent, a transformed computer foe's
  // GetEnemyMonStat (`_critStat`), and a level-up the client stated no stats
  // for (`levelUp`). Transform copies `base` and `dvs` with the species.
  const base = copyBlock(raw.base, K7_BASE_KEYS, 0, 255);
  if (base) out.base = base;
  const dvs = copyBlock(raw.dvs, K7_DV_KEYS, 0, 15);
  if (dvs) out.dvs = dvs;
  const statExp = copyBlock(raw.statExp, K7_BASE_KEYS, 0, 65535);
  if (statExp) out.statExp = statExp;
  // K1: the monster's OT id is not its trainer's (stamped by the owner's
  // client, true or absent). Only `_obey` reads it, and only on a `badgeRules`
  // seat; anywhere else it rides along inert.
  if (raw.traded === true) out.traded = true;
  return out;
}

// ------------------------------------------------------------------
// the field
// ------------------------------------------------------------------
//
// Party indices stay 1-based throughout, the way the Lua holds them, and the
// array behind them is 0-based -- so every party lookup goes through `monAt`
// rather than open-coding the minus one at fifteen call sites.

// DecrementPP's `dec [hl]` and IncrementMovePP's `inc [hl]` on the whole PP
// byte: PP in the low six bits, the PP Ups (K8 `ppUps`) in the top two. So a
// slot at 0 PP borrows -- 63 PP and one PP Up fewer (none wraps to three) --
// and one at 63 carries the other way. A sheet past the cart's six bits
// (a modded move) is plain arithmetic, held at 0.
const PP_MASK = 63;
function stepPp(move, delta) {
  const pp = int(move.pp, 0);
  if (pp > PP_MASK) {
    move.pp = Math.max(0, pp + delta);
    return;
  }
  const ups = int(move.ppUps, 0) % 4;
  // A row `copyMove` never read -- one a learn laid in mid-fight (the hubs'
  // nextMoves12 take a new move's row whole from the client, with its
  // GetMaxPP and no base) -- has its base read off the maximum it states,
  // over the PP Ups it has BEFORE this step moves them; one that names no
  // GetMaxPP keeps its maximum (false, as `copyMove` marks it).
  if ((move.basePp === undefined || move.basePp === null)
      && move.maxPp !== undefined && move.maxPp !== null) {
    move.basePp = orFalse(Effects.basePpOf(Math.max(0, int(move.maxPp, 0)), ups));
  }
  const byte = ((ups * 64 + pp + delta) % 256 + 256) % 256;
  move.pp = byte % 64;
  move.ppUps = Math.floor(byte / 64);
  // ...and GetMaxPP reads those bits: a borrow or a carry moves the maximum
  // an ETHER caps at (Effects.getMaxPp; `copyMove`'s `basePp`).
  if (typeof move.basePp === 'number') {
    move.maxPp = Effects.getMaxPp(move.basePp, move.ppUps);
  }
}

// The monster's own move list, where the party struct keeps it: a
// TRANSFORMed monster's `preTransform` copy (DecrementPP never touches the
// party while TRANSFORMED is set), else the list it fights with. What
// ItemUsePPRestore restores and its move menu lists.
function ownMoves(mon) {
  const saved = mon.transformed ? mon.preTransform : null;
  if (saved && typeof saved === 'object' && Array.isArray(saved.moves)) return saved.moves;
  return Array.isArray(mon.moves) ? mon.moves : [];
}

// `.restorePP` on a scratch copy of a row: whether it would restore, without
// restoring.
function wouldRestorePp(move, amount) {
  if (!move || typeof move !== 'object') return false;
  return Effects.restorePp({ pp: move.pp, ppUps: move.ppUps, maxPp: move.maxPp }, amount);
}

// `mon.moves[slot]` in Lua's 1-based slot numbering.
function moveAt(mon, slot) {
  if (!mon || !Array.isArray(mon.moves)) return null;
  const i = int(slot, 0);
  if (i < 1 || i > mon.moves.length) return null;
  return mon.moves[i - 1] || null;
}

function monAt(fighter, index) {
  if (index === null || index === undefined) return null;
  return fighter.mons[index - 1] || null;
}

function firstLiving(mons, skip) {
  for (let i = 1; i <= mons.length; i += 1) {
    if (mons[i - 1].hp > 0 && i !== skip) return i;
  }
  return null;
}

function activeMon(fighter) {
  if (!fighter.active) return null;
  const mon = monAt(fighter, fighter.active);
  if (mon && mon.hp > 0) return mon;
  return null;
}

// Which of this party a zero-based wire slot means.
//
// Matched against the position each monster claims rather than counted off the
// array, for the reason copyMon gives -- and the array index is the fallback
// rather than the rule, so a sender whose party arrived intact is unaffected and
// one whose party was cut or dealt still switches to the monster it named.
function partyIndexOf(fighter, wireSlot) {
  for (let i = 1; i <= fighter.mons.length; i += 1) {
    if (fighter.mons[i - 1].slot === wireSlot) return i;
  }
  return wireSlot + 1;
}

// The chart index the ruleset's `typeIds` gives the type registry id `name`
// (zero-based, the axis every move and monster on the upload uses), or null
// when it names no such type -- or names none at all.
function typeIndexOf(typeIds, name) {
  if (!Array.isArray(typeIds)) return null;
  for (let i = 0; i < typeIds.length; i += 1) {
    if (typeIds[i] === name) return i;
  }
  return null;
}

// typeIndexOf for COUNTER's two types, with pokered's own index when the
// ruleset sent no axis at all (`attempt`'s note).
function counterType(typeIds, name, fallback) {
  if (!Array.isArray(typeIds)) return fallback;
  return typeIndexOf(typeIds, name);
}

// The TypeEffects rows of a ruleset's `chartOrder` (attempt's note), as
// [atk, def] pairs in order. All or nothing, as `typeIds` is: an odd length,
// an index that is not a whole number 0..255, or more than CHART_ORDER_MAX
// rows makes the whole order null -- a row dropped from the middle would move
// every later one up and change what the last row says. A row may repeat,
// since the cart would apply it twice.
function chartIndex(value) {
  if (typeof value !== 'number' || !Number.isInteger(value)) return null;
  if (value < 0 || value > 255) return null;
  return value;
}

function chartRowsOf(raw) {
  if (!Array.isArray(raw)) return null;
  const n = raw.length;
  if (n === 0 || n % 2 !== 0 || n > CHART_ORDER_MAX * 2) return null;
  const rows = [];
  for (let i = 0; i < n; i += 2) {
    const a = chartIndex(raw[i]);
    const d = chartIndex(raw[i + 1]);
    if (a === null || d === null) return null;
    rows.push([a, d]);
  }
  return rows;
}

function hasType(mon, typeId) {
  return mon.types.includes(typeId);
}

// DisplayEffectiveness (engine/battle/display_effectiveness.asm): the
// multiplier AdjustDamageForMoveType left -- the last row's with the order
// (`_typeRows`), else the product -- over EFFECTIVE is "It's super
// effective", under it "It's not very effective", and nothing at it.
function typeLine(percents, last) {
  let effectiveness = last;
  if (effectiveness === null || effectiveness === undefined) {
    effectiveness = 100;
    for (const pct of percents || []) effectiveness = effectiveness * pct / 100;
  }
  if (effectiveness > 100) return "It's super\neffective!";
  if (effectiveness < 100) return "It's not very\neffective...";
  return null;
}

function allPpEmpty(mon) {
  if (mon.moves.length === 0) return true;
  for (const m of mon.moves) {
    if (m.pp > 0) return false;
  }
  return true;
}

// AnyMoveToSelect (core.asm :2713-2753): whether the menu hands the player
// STRUGGLE. With no move disabled it ORs the four PP bytes and masks the PP
// bits off -- every slot at 0 PP is Struggle. With one disabled it skips that
// slot and ORs the others' RAW bytes, unmasked, so a 0-PP move that carries PP
// Ups (K8 `ppUps`) keeps STRUGGLE away -- and `.chooseMove` (:2640-2650),
// which masks, then refuses that move for its PP and the disabled one for
// being disabled: the cart's player can only switch or run.
function mustStruggle(mon) {
  if (mon.moves.length === 0) return true;
  const disabled = mon.disable && int(mon.disable.turns, 0) > 0
    ? mon.disable.moveIndex : null;
  if (disabled === null) return allPpEmpty(mon);
  for (let i = 1; i <= mon.moves.length; i += 1) {
    if (i !== disabled) {
      const m = mon.moves[i - 1];
      if (m.pp > 0 || int(m.ppUps, 0) > 0) return false;
    }
  }
  return true;
}

// SelectEnemyMove (core.asm :2915-3005) outside a link battle: the
// computer never reads its PP -- ExecuteEnemyMove never calls DecrementPP
// either, so it never runs out -- and STRUGGLE only when its monster knows
// one move (`wEnemyMonMoves + 1` is 0) and that move is disabled
// (`wEnemyDisabledMove` set). With two or more `.chooseRandomMove` redraws
// past the disabled slot. An empty sheet is STRUGGLE here too (the cart's
// loop would spin forever on it).
function computerMustStruggle(mon) {
  if (mon.moves.length === 0) return true;
  if (mon.moves.length > 1) return false;
  return !!mon.disable && int(mon.disable.turns, 0) > 0
    && int(mon.disable.moveIndex, 0) === 1;
}

function copyBadges(raw) {
  if (!isTable(raw)) return null;
  const out = Object.create(null);
  let any = false;
  for (const id of Object.keys(raw)) {
    if (raw[id]) {
      out[id] = true;
      any = true;
    }
  }
  if (!any) return null;
  return out;
}

// The badges a seat fights with: its own upload where the cart would have
// applied it (BADGE_MODES, BADGE_SIDE), and null everywhere else.
function seatBadges(mode, side, raw) {
  if (!has(BADGE_MODES, mode) || side !== BADGE_SIDE) return null;
  return copyBadges(raw);
}

// A trainer seat's move-choice layers, AIEnemyTrainerChooseMoves'
// TrainerClassMoveChoiceModifications row for its class: the numbers of the
// AIMoveChoiceModification routines it runs, in order (1..4; 4 does
// nothing). The client reads them off its own engine trainer record
// (`aiMods`, which the engine extracts from the player's ROM): the class ->
// layers table is the cart's data and the mod ships none of it, so a class
// number alone would name nothing here. Present and empty is a class with
// no layer (YOUNGSTER's `.useOriginalMoveSet`); a value off the cart's four
// pointers is dropped, and so is a list past MAX_AI_MODS.
const MAX_AI_MODS = 8;
function copyAiMods(raw) {
  if (!isTable(raw)) return null;
  const out = [];
  const list = Array.isArray(raw) ? raw : [];
  for (const value of list) {
    if (out.length >= MAX_AI_MODS) break;
    const n = int(value, null);
    if (n !== null && n >= 1 && n <= 4) out.push(n);
  }
  return out;
}

// A trainer seat's TrainerAI record (contract K16): the engine's
// `ai_classes` record for its class, which matches pokered's
// data/trainers/ai_pointers.asm and the class routines of
// engine/battle/trainer_ai.asm row for row -- `uses` (TrainerAIPointers'
// byte, the wAICount loaded for each monster), `chance` / `switchChance`
// (the routine's `cp N percent` against TrainerAI's byte, out of 256), `item`,
// `switch` (AISwitchIfEnoughMons is the routine), `onStatus` (BrockAI's
// status test), `hpBelow` / `switchBelow` (AICheckIfHPBelowFraction's
// divisors). Read field by field into an object of this seat's own -- the
// hub hands every seat of one trainer the same object -- and null, the
// caller's refusal, when a key it knows is present and unreadable
// (Wire.aiClass' posture: a record half-read is another class).
// `_trainerAi` reads it.
const AI_USES_MAX = 255;
const AI_CHANCE_MAX = 256;
const AI_DIVISOR_MAX = 255;
const AI_CLASS_INTS = [
  ['uses', 1, AI_USES_MAX],
  ['chance', 0, AI_CHANCE_MAX],
  ['switchChance', 0, AI_CHANCE_MAX],
  ['hpBelow', 1, AI_DIVISOR_MAX],
  ['switchBelow', 1, AI_DIVISOR_MAX],
];
const AI_CLASS_FLAGS = ['switch', 'onStatus'];

function copyAiClass(raw) {
  if (!isTable(raw) || raw.uses == null) return null;
  const out = {};
  for (const [key, lo, hi] of AI_CLASS_INTS) {
    if (raw[key] != null) {
      const n = int(raw[key], null);
      if (n === null || n < lo || n > hi) return null;
      out[key] = n;
    }
  }
  if (raw.item != null) {
    out.item = str(raw.item);
    if (out.item === null) return null;
  }
  for (const key of AI_CLASS_FLAGS) {
    if (raw[key] != null) {
      if (typeof raw[key] !== 'boolean') return null;
      if (raw[key]) out[key] = true;
    }
  }
  return out;
}

// Bag sheet for auto-pick / timeout item use (id → count). Accepts the same
// shapes Wire.bag does: a list of {id,count} or a map.
function copyBag(raw) {
  if (!isTable(raw)) return null;
  const out = Object.create(null);
  let any = false;
  const put = (id, count) => {
    if (typeof id !== 'string' || id === '') return;
    const n = int(count, 0);
    if (!n || n < 1) return;
    out[id] = (out[id] || 0) + n;
    any = true;
  };
  if (Array.isArray(raw)) {
    for (const entry of raw) {
      if (isTable(entry)) put(entry.id, entry.count);
    }
  } else {
    for (const id of Object.keys(raw)) put(id, raw[id]);
  }
  if (!any) return null;
  return out;
}

// Every forced fight carries the move it replays (`forcedMove`): the move its
// record kept, or the recording slot's own. The cart skips the move menu for
// all of them (MainInBattleLoop: CHARGING_UP / THRASHING_ABOUT, USING_RAGE,
// STORING_ENERGY), so wPlayerSelectedMove still names the move from the turn
// that started it -- the one MetronomePickMove / MirrorMoveCopyMove wrote
// there for a called move (core.asm :5013-5031, :4961-4986), which is why a
// METRONOME that called FLY lands FLY next turn rather than rolling METRONOME
// again. And since no menu is asked, nothing is ever Struggle here: RAGE at
// 0 PP stays RAGE. `called` marks a record holding a called move, whose
// selected move is not the slot's (`_useMove`'s disabled check).
function forcedMoveOf(mon, calledMove, slot) {
  if (calledMove) return { move: calledMove, called: true };
  return { move: mon.moves[slot - 1], called: null };
}

// A trap's continuation: the trapping move, at the monster it holds.
function trapChoice(mon) {
  const t = mon.trapping;
  const forced = forcedMoveOf(mon, t.move, t.moveIndex);
  return {
    action: 'fight',
    move: t.moveIndex,
    target: t.targetSlot,
    forcedMove: forced.move,
    called: forced.called,
    trapContinue: true,
  };
}

// ------------------------------------------------------------------
// the battle
// ------------------------------------------------------------------

class Battle {
  constructor(opts) {
    this.id = str(opts.id) || 'battle';
    this.mode = has(MODES, opts.mode) ? opts.mode : '1v1';
    this.seed = int(opts.seed, 0);
    this.rng = Rng.create(int(opts.seed, 0));
    this.aim = Rng.create(int(opts.seed, 0) + AIM_SEED_OFFSET);
    this.chart = isTable(opts.chart) ? opts.chart : null;
    this.chartRows = chartRowsOf(opts.chartOrder);
    this.specialTypes = null;
    // The two types a side effect's routine asks about by name (attempt).
    this.poisonType = typeIndexOf(opts.typeIds, 'POISON');
    this.fireType = typeIndexOf(opts.typeIds, 'FIRE');
    // ...and the three a primary's routine does: ParalyzeEffect_'s
    // `cp ELECTRIC` on the move and `cp GROUND` on the target, and
    // LeechSeedEffect_'s `cp GRASS` (`_statusMove`). null when the ruleset
    // named none, and then nothing is turned away for its type.
    this.electricType = typeIndexOf(opts.typeIds, 'ELECTRIC');
    this.groundType = typeIndexOf(opts.typeIds, 'GROUND');
    this.grassType = typeIndexOf(opts.typeIds, 'GRASS');
    // The two COUNTER answers (attempt).
    this.normalType = counterType(opts.typeIds, 'NORMAL', 0);
    this.fightingType = counterType(opts.typeIds, 'FIGHTING', 1);
    // wDamage: the one damage word both sides share on the cart, read by
    // COUNTER (`_counterDamage`). Written where the cart writes it -- a hit
    // (capped to the HP it took off a monster, whole against a doll), a miss
    // (MoveHitTest zeroes it), a drain (halved in place), a self-hit, a Bide
    // release, a trap's later hit -- and never by a residual, a recoil or a
    // status move that lands (CalculateDamage returns before writing on power
    // 0). 0 at the start: InitBattleVariables clears the battle variables.
    this.lastDamage = 0;
    // Pay Day's pile, per side of the field: PayDayEffect_ adds the user's
    // level x 2 to wTotalPayDayMoney on either side's turn, and EndOfBattle
    // pays the whole pile (`_checkOver`).
    this.payDay = { a: 0, b: 0 };
    // wBattleResult as the cart leaves it mid-fight, which is what EndOfBattle
    // reads before it pays that pile on an escape (`_payDayOn`): 0 at the
    // start, 1 from RemoveFaintedPlayerMon on ANY of the player's monsters
    // fainting (core.asm :1030-1031) -- a send-out follows and the fight goes
    // on with it still 1 -- and 0 again from FaintEnemyPokemon (:816-817)
    // whenever an enemy faints with a player's monster still standing.
    // "The player" is side a, the side a fight against the computer pays.
    this.battleResult = 0;
    if (Array.isArray(opts.specialTypes)) {
      const set = Object.create(null);
      for (const t of opts.specialTypes) set[Math.max(0, int(t, 0))] = true;
      this.specialTypes = set;
    }
    this.metronomePool = null;
    if (Array.isArray(opts.metronomePool)) {
      const pool = [];
      for (const entry of opts.metronomePool) {
        const move = copyMove(entry);
        if (move) pool.push(move);
      }
      if (pool.length > 0) this.metronomePool = pool;
    }
    this.choiceTimeout = Math.max(0, int(opts.choiceTimeout, CHOICE_TIMEOUT));
    this.reconnectGrace = Math.max(0, int(opts.reconnectGrace, RECONNECT_GRACE));
    this.resolveTimeout = Math.max(0, int(opts.resolveTimeout, RESOLVE_TIMEOUT));
    this.now = Math.max(0, int(opts.now, 0));
    this.phase = 'choice';
    this.turn = 1;
    this.seq = 0;
    this.deadline = null;
    this.resolveDeadline = null;
    this.buffer = [];
    this.fighters = [];
    // A Map, not an object: a playerId is attacker-supplied and "__proto__" is
    // a perfectly legal string.
    this.byId = new Map();
    this.bySide = { a: [], b: [] };
    // What the current action has knocked down and not paid for yet; see
    // `_drainExp`. A list, so the order faints happened in is the order their
    // spoils are announced in.
    this.pendingExp = [];
    // Every faint so far, counted: `_resolveFights` reads what one slot or
    // one residual added to it.
    this.faints = 0;
    // The move animation `_useMove` put out ahead of its used line, which a
    // miss or a failed routine takes back (`_dropMoveAnim`).
    this.moveAnim = null;
    this.result = null;
  }

  // ----------------------------------------------------------------
  // events
  // ----------------------------------------------------------------

  _emit(kind, fields) {
    const event = Events.build(kind, fields);
    if (!event) return null;
    this.seq += 1;
    event.battle = this.id;
    event.seq = this.seq;
    this.buffer.push(event);
    return event;
  }

  // partyIndex is 1-based into the fighter's party. Present on a PP
  // spend/restore so the client can write that sheet; absent on
  // Transform/Mimic so the overlay is not mistaken for the real set.
  _emitMoves(fighter, mon, partyIndex) {
    const moves = mon.moves.map((m) => ({
      id: m.id || 'move',
      pp: Math.max(0, int(m.pp, 0)),
      maxPp: Math.max(0, int(m.maxPp, m.pp)),
      power: Math.max(0, int(m.power, 0)),
      accuracy: Math.max(0, int(m.accuracy, 255)),
      type: Math.max(0, int(m.type, 0)),
      effect: Math.max(0, int(m.effect, 0)),
      chance: Math.max(0, int(m.chance, 0)),
      // K8's PP Ups beside the PP, the byte's top two bits as DecrementPP /
      // IncrementMovePP left them (`stepPp`): the client writes them to the
      // save as stated rather than inferring a wrap's borrow off the step
      // (MediatedBattle ppByteStep1).
      ppUps: Math.max(0, Math.min(3, int(m.ppUps, 0))),
    }));
    const fields = { slot: fighter.slot, side: fighter.side, moves };
    if (partyIndex != null) fields.mon = partyIndex - 1;
    return this._emit('moves', fields);
  }

  _say(text) {
    return this._emit('msg', { text });
  }

  // A status animation the cart plays from CheckPlayerStatusConditions /
  // CheckEnemyStatusConditions (the sleeping and the confused monster's), as an
  // `anim` event on the seat it plays over: its battle_anims id, the `_ANIM`
  // kind a client looks up the way it looks up the ball chain's. The cart
  // picks the PLAYER variant on the player's turn and the plain one on the
  // enemy's; "the player" is the owner's rule (`isPlayerSeat`), so in a link
  // fight each seat carries its own console's variant and the screen across
  // swaps it for a monster that is not its own.
  _statusAnim(fighter, id) {
    return this._emit('anim', { slot: fighter.slot, side: fighter.side, text: id });
  }

  // STATUS_AFFECTED_ANIM over the user (contract K20), wherever the cart plays
  // it: `.FlyOrChargeEffect` when a full paralysis or a confusion self-hit
  // ends the turn (`.MonHurtItselfOrFullyParalysed`, core.asm :3459-3476; the
  // enemy's, :5836-5853) and PlayerCheckIfFlyOrChargeEffect /
  // EnemyCheckIfFlyOrChargeEffect (:3184-3197, :5585-5599) on a move that missed
  // -- HandleIfPlayerMoveMissed's `jr` -- or that CalculateDamage found at power
  // 0. Each tests the move struct's effect, wPlayerMoveEffect /
  // wEnemyMoveEffect, for FLY_EFFECT or CHARGE_EFFECT (Effects.isCharge): the
  // cancelled FLY or charge. At a gate that is the struct as it stands
  // (`moveStruct`, before GetCurrentMove) -- the charging move's on its
  // release turn, the menu's pick on a player's fresh one; on a miss, the move
  // being used.
  _flyOrChargeAnim(fighter, effectId) {
    if (Effects.isCharge(effectId)) {
      this._statusAnim(fighter, 'STATUS_AFFECTED_ANIM');
    }
  }

  // The move's animation taken back out of the stream (K20 / K22).
  // `_useMove` emits it ahead of the used line (`moveAnim`, the header's
  // note) before the cart has decided whether to play it, and where the cart
  // plays none -- a move that missed (HandleIfPlayerMoveMissed, EXPLODE_EFFECT
  // excepted), a power-0 move whose routine failed, MIRROR MOVE's own -- it is
  // removed here, every later event of the action moving up one `seq`.
  // Nothing is drained in between: an action resolves inside one call, so the
  // event is still in the buffer; one that is not is left alone.
  _dropMoveAnim() {
    const event = this.moveAnim;
    this.moveAnim = null;
    if (!event) return;
    for (let i = this.buffer.length - 1; i >= 0; i -= 1) {
      if (this.buffer[i] === event) {
        this.buffer.splice(i, 1);
        for (let j = i; j < this.buffer.length; j += 1) this.buffer[j].seq -= 1;
        this.seq -= 1;
        return;
      }
    }
  }

  // The move's animation moved behind everything emitted since it
  // (`moveAnim` stays the same event, so a later miss still takes it back).
  // A thrash's first turn plays ThrashPetalDanceEffect's square between the
  // used line and the move's own animation (PlayerCanExecuteMove runs
  // SpecialEffectsCont before MoveHitTest and PlayPlayerMoveAnimation), so
  // the move's animation that `_useMove` put ahead of the used line goes
  // behind the square: the used line then shouts on its own and the
  // animation behind it lunges without a second shout (MediatedBattle's
  // `calloutLine`, CoopBattle's sentence-first order). Same buffer rule as
  // `_dropMoveAnim`.
  _trailMoveAnim() {
    const event = this.moveAnim;
    if (!event) return;
    for (let i = this.buffer.length - 1; i >= 0; i -= 1) {
      if (this.buffer[i] === event) {
        this.buffer.splice(i, 1);
        for (let j = i; j < this.buffer.length; j += 1) this.buffer[j].seq -= 1;
        event.seq = this.seq;
        this.buffer.push(event);
        return;
      }
    }
  }

  /*
   * Every seat's party roster, published when -- and only when -- it moved.
   *
   * **This is the only thing on the wire that describes a monster nobody has
   * seen.** A mediated fight tells each client about the field and nothing
   * else, which is right for every other event and wrong for exactly one
   * question: how many monsters is the other player still holding, and how many
   * of those are spent. Both clients uploaded a party to the referee and
   * neither uploaded one to the other, so the referee is the only party to the
   * fight that can answer it -- which is why this is an event and not something
   * a screen derives.
   *
   * What it carries is a ball row and no more (`Events.teamString`): a count
   * and three states. Not a species, not a level, not a move. That line is
   * where it is because it is where the original draws it -- the row a
   * trainer's intro puts on screen is exactly this much -- and because anything
   * past it is a team preview one player never agreed to give.
   *
   * Diffed rather than announced, so a fight that changes nothing costs
   * nothing. `fighter.team` starts null, so the first sync always publishes --
   * which is how the opening rosters reach a client (`_openTurn` runs at the
   * end of construction, behind the send-outs).
   */
  // `fainting` is the seat `_faint` is taking down: its roster goes with its
  // faint. Any other seat whose monster still stands at 0 HP -- a knockout
  // waiting for the action's end, K19's `_reapKo` -- is held back until its own
  // faint publishes it, so a double knockout darkens each ball with the faint it
  // belongs to rather than the first one's.
  _syncTeams(fainting) {
    for (const fighter of this.fighters) {
      const standing = fighter.active ? monAt(fighter, fighter.active) : null;
      const pending = fighter !== fainting && standing !== null && standing.hp <= 0;
      const roster = Events.teamString(fighter.mons);
      if (!pending && roster !== fighter.team) {
        fighter.team = roster;
        this._emit('team', {
          slot: fighter.slot, side: fighter.side, team: roster,
        });
      }
    }
  }

  /*
   * Everything since the last call, in order, and the buffer is emptied. A
   * caller that drops the returned list drops those events for good, which is
   * deliberate: the alternative -- a buffer that grows until somebody reads it
   * -- is a memory leak on a hub whose client has gone quiet.
   */
  drainEvents() {
    const out = this.buffer;
    this.buffer = [];
    return out;
  }

  // ----------------------------------------------------------------
  // the field
  // ----------------------------------------------------------------

  _foes(fighter) {
    return this.bySide[fighter.side === 'a' ? 'b' : 'a'];
  }

  _fighterAtSlot(slot) {
    for (const fighter of this.fighters) {
      if (fighter.slot === slot) return fighter;
    }
    return null;
  }

  _firstLivingFoe(fighter) {
    for (const foe of this._foes(fighter)) {
      if (activeMon(foe)) return foe;
    }
    return null;
  }

  // Which opposing seat an action *nobody chose* swings at.
  //
  // Every aim the referee files for itself comes through here: an NPC's pick,
  // the identical pick a human's timeout files, and the lock-in turns of
  // thrash / rage / bide, where nobody is asked for a target because the move
  // does not offer one.
  //
  // It used to be `_firstLivingFoe`, which answers "the lowest-numbered living
  // foe" -- the right answer to a question with one possible answer, and the
  // wrong one the moment a side holds two players. A coop_wild's wild monster
  // and *both* seats of a coop_npc trainer swung at seat 0 every turn of every
  // fight, so the second player on the side was never once attacked. Reported
  // from a real two-player game, and reproducible in one sitting: 18 damage
  // events, 18 of them on slot 0.
  //
  // So: uniform over the living opposing seats. Three properties make that
  // safe to add to a sim two runtimes have to agree on byte for byte.
  //
  //   * The draw is on `this.aim`, not `this.rng`. A draw on the battle's own
  //     generator would shift every roll after it and silently rewrite every
  //     recorded vector; this one cannot move a number that already exists.
  //   * One living foe is answered without drawing at all. A 1v1, and the lone
  //     wild seat of a wild / coop_wild fight, therefore consume nothing and
  //     replay exactly as they always did -- the aim stream in those fights is
  //     never even touched.
  //   * `byte()` is the draw, not `nextInt`. `nextInt` used to take the whole
  //     LCG state modulo the span, and this generator's bit 0 alternates every
  //     step, so a two-seat side would have got a perfect A-B-A-B rota rather
  //     than a spread. `byte()` reads bits 16..23, which is the reason Rng.js
  //     puts them there (since K12 `nextInt` reads the high bits too; the aim
  //     draw stays `byte()` so no recorded aim stream moves).
  //
  // Draw order is the parity contract, exactly as it is for `this.rng`: both
  // runtimes call this at the same points, in the same seat order, or their
  // aim streams part company. The turn-parity drivers are what hold that.
  _autoTarget(fighter) {
    const living = [];
    for (const foe of this._foes(fighter)) {
      if (activeMon(foe)) living.push(foe);
    }
    if (living.length === 0) return null;
    if (living.length === 1) return living[0];
    return living[this.aim.byte() % living.length];
  }

  // Which seat an action actually swings at, given the seat it was aimed at.
  //
  // A fight choice always names a living opposing seat when it is made:
  // `_normaliseChoice` refuses an empty one, and the replace phase means the
  // field is whole again before the next choice window opens.  **A mid-turn
  // faint is therefore the only way an aim can go stale** -- in a 2v2 the
  // faster ally KOs the seat the slower ally picked, and without this the
  // slower mon fizzles ("has no target") instead of swinging.
  //
  // Preference order:
  //   (a) whatever is standing in the SAME field position.  A seat *is* a
  //       field position here, so this also covers the case where the seat was
  //       emptied and refilled between choice and execution -- the aim the
  //       player made still points at a real monster and is honoured
  //       unchanged.
  //   (b) otherwise the NEAREST living opposing seat: smallest
  //       |seat.slot - aimedSlot| (both sit on the same side, so the side base
  //       cancels and this is seat-index distance), ties broken toward the
  //       lower seat index.  With two seats a side that is simply the adjacent
  //       seat; the rule is spelled out so a wider field could not make it
  //       ambiguous.
  //   (c) otherwise null -- the opposing side has nothing standing, the battle
  //       is ending, and the action is skipped.
  //
  // Only the opposing side is ever searched, so nothing here can redirect a
  // move onto the user or its ally; self-targeting and side-wide effects ride
  // the same opposing-seat aim they always did and are untouched.  The answer
  // is bound once per action in `_useMove`, so a multi-hit strike puts every
  // hit on the retargeted seat -- an action retargets, not each of its strikes.
  _retarget(fighter, slot) {
    const aimed = this._fighterAtSlot(slot);
    if (aimed && activeMon(aimed)) return aimed;

    let best = null;
    let bestDistance = null;
    for (const foe of this._foes(fighter)) {
      if (!activeMon(foe)) continue;
      const distance = Math.abs(foe.slot - slot);
      if (bestDistance === null || distance < bestDistance
          || (distance === bestDistance && foe.slot < best.slot)) {
        best = foe;
        bestDistance = distance;
      }
    }
    return best;
  }

  _sideAlive(side) {
    for (const fighter of this.bySide[side]) {
      if (firstLiving(fighter.mons)) return true;
    }
    return false;
  }

  _sidePlayers(side) {
    return this.bySide[side].map((fighter) => fighter.playerId);
  }

  // A fighter owes a choice when it has something standing, or when it must pick
  // a replacement after a faint. A player whose last monster fainted in a 2v2 is
  // a spectator for the rest of the fight, and waiting on them would hang the
  // turn. Multi-turn volatiles auto-fill before the player is asked.
  //
  // In the `replace` phase the only thing anybody owes is a replacement: the
  // seats that are still standing answered last turn and are not being asked
  // again, so their standing monster must not hold the phase open. Everything
  // that reads "who are we waiting on" -- `_anyoneOwes`, the timeout sweep in
  // `tick`, `snapshot().waiting` -- goes through here, which is why the phase
  // test lives in this one function rather than at each of those call sites.
  _owes(fighter) {
    if (fighter.choice !== null && fighter.choice !== undefined) return false;
    if (fighter.mustReplace) {
      return firstLiving(fighter.mons) !== null;
    }
    if (this.phase === 'replace') return false;
    if (activeMon(fighter) === null) return false;
    return true;
  }

  // Inject forced choices for charge release, recharge, thrash/rage repeat --
  // and, for the computer's seats, a Bide, a trap's continuation and the
  // monster it holds. The cart skips the move menu for all of them
  // (MainInBattleLoop :293-321, SelectEnemyMove :2938-2955), and the whole
  // battle menu for the first four (:293-303): a player's Bide user, trapper
  // or held monster is asked instead (`_menuFight`). Every one of them is
  // then the monster's own turn-order
  // slot: ExecutePlayerMove runs CheckPlayerStatusConditions over it, so the
  // sleep and freeze checks, the trapped check and the flinch come first, and
  // only a monster that gets past them recharges (`.HyperBeamCheck`), stores
  // its Bide, thrashes or keeps its trap going (`.MultiturnMoveCheck`).
  // Nothing is said here; the slot says it (`_rechargeTurn`, `_useMove`).
  _fileForced(fighter, choice) {
    fighter.forced = true;
    fighter.choice = choice;
    this._emit('chose', {
      slot: fighter.slot, side: fighter.side, text: fighter.name,
    });
  }

  _fillForcedChoices() {
    for (const fighter of this.fighters) {
      if (fighter.choice !== null && fighter.choice !== undefined) continue;
      const mon = activeMon(fighter);
      if (!mon) continue;

      // NEEDS_TO_RECHARGE: no menu (:293-295). The recharge itself is the
      // slot's (`_rechargeTurn`): a monster asleep or frozen there keeps the
      // bit, as the cart's sleep and freeze checks return before
      // `.HyperBeamCheck`. `skip` is the forced turn's kind, which
      // `_resolveFights` reads, as `_selectionOf` does for the selected move
      // the cart leaves standing.
      if (mon.mustRecharge) {
        this._fileForced(fighter, { action: 'skip', skip: 'recharge' });
        continue;
      }

      // Bide's forced turns are the monster's own turn-order slot on the cart
      // (CheckPlayerStatusConditions `.BideCheck`, core.asm :3482-3524): every
      // gate runs first, then the store takes wDamage and the counter a step,
      // and the turn it reaches 0 unleashes -- so each one is a forced fight
      // (`bideStore`), not a skip (`_useMove`'s Bide branch). The computer's
      // (SelectEnemyMove :2949-2950 keeps its selection); a player's seat gets
      // the battle menu first and is asked (`_menuFight`).
      if (mon.bide) {
        if (!isPlayerSeat(this.mode, fighter)) {
          const choice = this._bideChoice(fighter, mon);
          if (choice) this._fileForced(fighter, choice);
        }
        continue;
      }

      // USING_TRAPPING_MOVE: no move menu (:311-313), and the selection is
      // the trapping move still. `.MultiturnMoveCheck` hits again in the
      // trapper's slot, past every gate (`_trapTurn`) -- not a residual at
      // the turn's end, and not a re-rolled move. `trapContinue` says so; a
      // trap that a switch or a faint let go before the slot leaves the move
      // to run fresh, as the cart's stale selection does (`_useMove`) -- the
      // computer's re-picks instead (`_reselectComputer`). Filed for the
      // computer; a player's trapper gets the battle menu (`_menuFight`).
      if (mon.trapping && int(mon.trapping.turns, 0) > 0) {
        if (!isPlayerSeat(this.mode, fighter)) {
          this._fileForced(fighter, trapChoice(mon));
        }
        continue;
      }

      if (mon.charging) {
        const c = mon.charging;
        const forced = forcedMoveOf(mon, c.move, c.moveIndex);
        this._fileForced(fighter, {
          action: 'fight',
          move: c.moveIndex,
          target: c.targetSlot,
          forcedMove: forced.move,
          called: forced.called,
        });
        continue;
      }

      // "<MON>'s thrashing about!" is the slot's (`.ThrashingAboutCheck`,
      // past the gates), not the turn's opening.
      if (mon.thrashing && mon.thrashing.turns > 0) {
        const foe = this._autoTarget(fighter);
        if (foe) {
          const forced = forcedMoveOf(mon, mon.thrashing.move, mon.thrashing.moveIndex);
          this._fileForced(fighter, {
            action: 'fight',
            move: mon.thrashing.moveIndex,
            target: foe.slot,
            forcedMove: forced.move,
            called: forced.called,
          });
        }
        continue;
      }

      // No line here: `.RageCheck` (core.asm :3568-3579) only names the move
      // and goes to PlayerCanExecuteMove, whose "used RAGE!" `_useMove` says.
      // "<MON>'s RAGE is building!" is HandleBuildingRage's, at each build
      // (`_buildRage`).
      if (mon.raging && mon.rageMove && mon.rageMove > 0) {
        const foe = this._autoTarget(fighter);
        if (foe) {
          const forced = forcedMoveOf(mon, mon.rageCall, mon.rageMove);
          this._fileForced(fighter, {
            action: 'fight',
            move: mon.rageMove,
            target: foe.slot,
            forcedMove: forced.move,
            called: forced.called,
          });
          continue;
        }
      }

      // Held by a foe's trap: CANNOT_MOVE (MainInBattleLoop :316-321,
      // SelectEnemyMove :2953-2955), and ExecutePlayerMove's `inc a / jp z`
      // then skips the whole turn without a word -- no gate, no line. Only a
      // monster that reaches this point of the menu logic gets it: one asleep
      // or frozen jumps to `.selectEnemyMove` first (:308-310) and keeps its
      // selection and its menu, so its sleep ticks in its slot; and every
      // forced turn above was filed first, to meet `.HeldInPlaceCheck`'s
      // "can't move" there instead (`_runGates`). The computer's seat; a
      // player's held monster gets the battle menu first (`_menuFight`).
      if (this._isHeld(fighter, mon) && mon.status !== 'sleep' && mon.status !== 'freeze'
          && !isPlayerSeat(this.mode, fighter)) {
        this._fileForced(fighter, { action: 'skip', skip: 'trapped' });
      }
    }
  }

  // A Bide's forced turn. The store turns need no aim (`.BideCheck` only adds
  // wDamage), so the aim stream is asked -- as it always was -- only on the
  // turn whose step takes the counter to 0, the unleash. null when that turn
  // has nobody to unleash at.
  _bideChoice(fighter, mon) {
    const bide = mon.bide;
    let foe = null;
    if (int(bide.turns, 0) <= 1) {
      foe = this._autoTarget(fighter);
      if (!foe) return null;
    }
    let target = bide.targetSlot !== null && bide.targetSlot !== undefined
      ? bide.targetSlot : (foe ? foe.slot : null);
    if (target === null) {
      const first = this._firstLivingFoe(fighter);
      target = first ? first.slot : null;
    }
    const forced = forcedMoveOf(mon, bide.move, bide.moveIndex);
    return {
      action: 'fight',
      move: bide.moveIndex,
      target,
      bideStore: true,
      forcedMove: forced.move,
      called: forced.called,
    };
  }

  // What a player's FIGHT selects where the cart opens the battle menu but no
  // move menu behind it (MainInBattleLoop, core.asm :303-321): DisplayBattleMenu
  // has run -- a switch, an item or a RUN there is the seat's answer, taken as
  // on any turn -- and FIGHT returns to a loop that jumps to `.selectEnemyMove`
  // for a monster asleep or frozen (:308-310), one storing energy or using a
  // trapping move (:311-313), and writes CANNOT_MOVE for one a foe's trap holds
  // (:314-321). So the move index a client sends with it names nothing:
  //   * a Bide: its forced turn (`_bideChoice`, `.BideCheck` in its slot);
  //   * a trap of its own, its counter not spent: the continuation
  //     (`trapChoice`, `.MultiturnMoveCheck`);
  //   * held by a foe's trap and awake: CANNOT_MOVE, the turn gone in silence
  //     -- and decided now, against the trap standing at the menu, so a
  //     trapper that switches out later in the turn does not give it back.
  // null for every other monster. (Asleep or frozen, last turn's selection
  // stands and the gate stops the monster: `_normaliseChoice` takes any slot
  // that holds a move, with no PP or Disable test, since no menu applied one.)
  _menuFight(fighter, mon) {
    if (mon.bide) return this._bideChoice(fighter, mon);
    if (mon.trapping && int(mon.trapping.turns, 0) > 0) return trapChoice(mon);
    if (this._isHeld(fighter, mon) && mon.status !== 'sleep' && mon.status !== 'freeze') {
      return { action: 'skip', skip: 'trapped' };
    }
    return null;
  }

  // `.AnyMoveDisabledCheck` (core.asm :3394-3407): the Disable counter comes
  // down a step every time the monster gets past the sleep, freeze, trapped,
  // flinch and recharge checks -- in its own turn, not at the turn's end --
  // and the step that reaches 0 lifts it there and then ("<MON>'s disabled no
  // more!"), so that turn's move goes ahead even if it is the one that was
  // disabled. The 1..8 of DisableEffect counts these steps.
  _tickDisable(fighter, mon) {
    const d = mon.disable;
    if (!d || int(d.turns, 0) <= 0) return;
    d.turns -= 1;
    if (d.turns <= 0) {
      mon.disable = null;
      this._say(`${named(fighter, mon)}'s\ndisabled no more!`);
    }
  }

  _anyDisconnected() {
    return this.fighters.some((fighter) => !fighter.connected);
  }

  // ----------------------------------------------------------------
  // choices
  // ----------------------------------------------------------------
  //
  // Indices arrive zero-based, because that is how they ride on the wire:
  // `move` is 0..3 into the monster's moves, `slot` is 0..5 into the party, and
  // `target` is a 0..5 *field* slot. They are converted here, once, so nothing
  // downstream has to remember which of the three it is holding.

  _normaliseChoice(fighter, choice) {
    const action = choice.action;

    // Forced replacement: only a living bench switch is accepted. Fight / item /
    // run would spend a turn the seat does not have a mon for.
    if (fighter.mustReplace) {
      if (action !== 'switch') return null;
      const slot = int(choice.slot, null);
      if (slot === null) return null;
      const target = partyIndexOf(fighter, slot);
      const bench = monAt(fighter, target);
      if (!bench || bench.hp <= 0) return null;
      return { action: 'switch', slot: target };
    }

    const mon = activeMon(fighter);
    if (!mon) return null;

    // RUN in a trainer fight: TryRunningFromBattle's `.trainerBattle` prints
    // NoRunningText and leaves wActionResultOrTookBattleTurn at 0, so
    // BattleMenu_RunWasSelected goes back to DisplayBattleMenu (core.asm
    // :2446-2457) -- the turn is not spent and the menu asks again. So the
    // choice is refused here and the seat still owes one; the line is the
    // client's own, said where it declines to send the RUN (Effects.runEndsBattle).
    if (action === 'run') {
      if (!Effects.runEndsBattle(this.mode)) return null;
      return { action: 'run' };
    }

    if (action === 'item') {
      // The computer never files an item: a trainer's is TrainerAI's, in its
      // slot of the order (contract K16, `_trainerAi`), and wildlife has no
      // bag and no hands. Refused rather than ignored, so a seat of the
      // computer's that is somehow handed one never spends the turn on it.
      if (isComputerSeat(this.mode, fighter)) return null;
      const item = str(choice.item);
      if (!item) return null;
      // A fighter with a bag sheet must actually hold the stack.
      // Seats with no bag stay permissive so headless fixtures can still item.
      if (fighter.bag && !this._bagHas(fighter, item)) return null;
      const effect = Effects.itemEffect(item);
      const out = { action: 'item', item };
      if (choice.slot !== undefined && choice.slot !== null) {
        const slot = int(choice.slot, null);
        if (slot === null) return null;
        const target = partyIndexOf(fighter, slot);
        if (!monAt(fighter, target)) return null;
        out.slot = target;
      }
      if (choice.move !== undefined && choice.move !== null) {
        const move = int(choice.move, null);
        if (move === null) return null;
        out.move = move + 1;
      } else if (effect && effect.needsMove) {
        return null;
      }
      // Gen 1: Potion/Ether/status/vitamin on a KO, and Revive on a living
      // mon, never leave the picker. Refuse here so a submitted choice cannot
      // spend the bag or the turn.
      const targetMon = monAt(fighter, out.slot != null ? out.slot : fighter.active);
      if (targetMon) {
        if (effect && effect.faintedOnly && targetMon.hp > 0) return null;
        if (targetMon.hp <= 0 && Effects.itemFailsOnFainted(effect)) return null;
      }
      // ItemUseFailed (item_effects.asm :2316-2319): a use that does nothing
      // -- ItemUseNoEffect, from ItemUseMedicine's `.healingItemNoEffect` and
      // ItemUsePPRestore's `.noEffect` -- or that is not for now
      // (ItemUseNotTime) writes 0 to wActionResultOrTookBattleTurn and never
      // reaches RemoveUsedItem: the bag keeps the item, the turn is not
      // spent, and the battle menu asks again. So a player's such use is
      // refused here, before it is filed (`_itemFails`), as the fainted cases
      // above are -- the seat still owes its turn.
      if (this._itemFails(fighter, effect, out)) return null;
      return out;
    }

    if (action === 'switch') {
      // ...and never a voluntary switch: a trainer's is AISwitchIfEnoughMons'
      // (`_aiSwitch`), and its send-out after a faint is the replace branch
      // above.
      if (isComputerSeat(this.mode, fighter)) return null;
      const slot = int(choice.slot, null);
      if (slot === null) return null;
      const target = partyIndexOf(fighter, slot);
      const bench = monAt(fighter, target);
      if (!bench || bench.hp <= 0 || target === fighter.active) return null;
      return { action: 'switch', slot: target };
    }

    if (action === 'fight') {
      // FIGHT with no move menu behind it (`_menuFight`): the lock-in itself,
      // whatever slot -- or none -- came with it.
      const locked = this._menuFight(fighter, mon);
      if (locked) return locked;
      // Asleep or frozen, FIGHT opens no move menu either (MainInBattleLoop
      // :308-310): the slot is a placeholder the gate never gets past, so any
      // slot holding a move stands and none at all is the first.
      const asleep = mon.status === 'sleep' || mon.status === 'freeze';
      let index = int(choice.move, null);
      if (asleep && (index === null || !mon.moves[index])) index = 0;
      if (index === null) return null;
      const move = mon.moves[index];
      if (!move) return null;
      // Struggle (AnyMoveToSelect, `_struggles`) takes any index. Otherwise
      // `.chooseMove` refuses a slot whose PP -- masked, so PP Ups do not count
      // here -- is 0, and the disabled slot. The computer's SelectEnemyMove
      // refuses the disabled slot and never reads PP (`_hasPp`).
      if (!asleep && !this._struggles(fighter, mon)) {
        if (!this._hasPp(fighter, move)) return null;
        if (mon.disable && mon.disable.turns > 0
            && mon.disable.moveIndex === index + 1) {
          return null;
        }
      }

      let targetFighter;
      if (choice.target !== undefined && choice.target !== null) {
        targetFighter = this._fighterAtSlot(int(choice.target, -1));
        // A named target on the chooser's own side is refused. A seat mid-replace
        // (mustReplace, no active yet) is still a legal aim: switches resolve
        // before fights, so the mon will be out when the move lands.
        if (!targetFighter || targetFighter.side === fighter.side) {
          return null;
        }
        if (!activeMon(targetFighter) && !targetFighter.mustReplace) {
          return null;
        }
      } else {
        // Deliberately `_firstLivingFoe` and not `_autoTarget`: this is a
        // *player's* move with the aim left off, and the answer to that is a
        // predictable default the client can show, not a die roll. Only the
        // aims nobody chose spread.
        targetFighter = this._firstLivingFoe(fighter);
        if (!targetFighter) {
          for (const foe of this._foes(fighter)) {
            if (foe.mustReplace) { targetFighter = foe; break; }
          }
        }
        if (!targetFighter) {
          // Same leftover as `_autoChoiceOrSkip`: a living seat with nobody
          // across the field to aim at spends the turn rather than hanging
          // the window. Solo's choice clock is 0, so a refused FIGHT used
          // to mark the band answered and wait for WILD forever.
          return { action: 'skip' };
        }
      }
      const out = { action: 'fight', move: index + 1, target: targetFighter.slot };
      // Asleep or frozen, no move menu ran: the move this turn would use is
      // last turn's selection, at last turn's list index (`_useMove`, for a
      // monster a Fire hit thaws before its slot).
      if (asleep) out.stale = true;
      // MIMIC's pick, asked up front the way Gen 3 asks BATON PASS's
      // destination: the cart opens the foe's move list as the move runs
      // (MimicEffect `.letPlayerChooseMove`), which a mediated fight cannot do
      // mid-turn. Zero-based into the target's moves; `_mimicPick` reads it
      // only where the cart asks the player, and checks it against the moves
      // the target holds when MIMIC lands. Absent or malformed, the menu's
      // cursor answers (its first row).
      if (choice.mimic !== undefined && choice.mimic !== null) {
        const pick = int(choice.mimic, null);
        if (pick !== null && pick >= 0 && pick < 4) out.mimic = pick + 1;
      }
      return out;
    }

    return null;
  }

  /*
   * Returns true when the choice is now held for this turn, false otherwise.
   * False is the whole of the error report on purpose: the reasons a choice is
   * refused (wrong phase, unknown player, disconnected, already answered, an
   * index that names nothing) are all things the client can see for itself, and
   * a string here would be a second vocabulary to keep in step across two
   * runtimes.
   */
  submitChoice(playerId, choice) {
    if (this.phase !== 'choice' && this.phase !== 'replace') return false;
    if (!isTable(choice)) return false;

    const fighter = this.byId.get(str(playerId) || '');
    if (!fighter) return false;
    // disconnect() pauses the clock but used to keep taking answers from the
    // same socket (SESSION_LEAVE leaves TCP up). Refuse until reconnect().
    if (!fighter.connected) return false;
    if (!has(ACTIONS, choice.action)) return false;

    // The replace phase belongs to the seats that owe a send-out and to nobody
    // else: a standing seat's fight would be an answer to a turn that has not
    // opened yet, and taking it here would spend it before the player saw the
    // successor come out. Refused rather than queued, so the client asks again
    // on the `turn` that follows the send.
    if (this.phase === 'replace' && !this._owes(fighter)) return false;

    if (choice.action === 'cancel') {
      // A forced replacement is not a decision that can be taken back: the
      // field is a monster short until it is answered, so `unchose` here would
      // only hand the seat a second way to hold the fight open.
      if (this.phase === 'replace') return false;
      if (fighter.choice === null) return false;
      // A referee-filled answer is not the player's to take back. A recharge,
      // Rage, a thrash and a charge's release -- and the computer's Bide, trap
      // and hold -- fill the seat at `_openTurn`; on a turn where *every* seat
      // is forced `_openTurn` leaves no deadline, so a cleared choice would
      // hang the fight with nothing left to time it out. A player's own
      // lock-in -- the FIGHT it answers a Bide, a trap or a hold with
      // (`_menuFight`) -- is its answer like any other, and the cart's B backs
      // out of it too.
      if (fighter.forced) return false;
      this._emit('unchose', {
        slot: fighter.slot, side: fighter.side, text: fighter.name,
      });
      fighter.choice = null;
      return true;
    }

    if (fighter.choice !== null) return false; // one answer per turn
    if (fighter.mustReplace) {
      if (choice.action !== 'switch') return false;
    } else if (!activeMon(fighter)) {
      return false;
    }

    const normalised = this._normaliseChoice(fighter, choice);
    if (!normalised) return false;

    fighter.choice = normalised;
    // Peers need this for the wait line: without it, only the chooser's own
    // client knows they answered (there is no `act` fan-out on the mediated path).
    this._emit('chose', {
      slot: fighter.slot, side: fighter.side, text: fighter.name,
    });
    this._maybeResolve();
    return true;
  }

  _maybeResolve() {
    if (this.phase !== 'choice' && this.phase !== 'replace') return false;
    // A leftover or forced fill must not complete the turn while a seat is
    // away: the clock is paused for them, and resolving would spend it.
    // reconnect() calls this once everyone is back.
    if (this._anyDisconnected()) return false;
    for (const fighter of this.fighters) {
      if (this._owes(fighter)) return false;
    }
    if (this.phase === 'replace') {
      this._closeReplace();
      return true;
    }
    this._resolveTurn();
    return true;
  }

  // timeout/NPC pick: bag cures/heals/X-items when present, else SE / status /
  // setup / switch. Deterministic twin of src/BattleSim/Turn.lua — richer than
  // a strongest-move heuristic, still not a full TrainerAI port. For the
  // computer's seats only its item, its switch and its forced answers stand:
  // the move it would fight with is SelectEnemyMove's (`_computerChoice`).
  _effectivenessProduct(moveType, defender) {
    const percents = this._typePercents(moveType, defender);
    let eff = 1;
    for (const pct of percents) eff = (eff * pct) / 100;
    return eff;
  }

  _bagHas(fighter, itemId) {
    return !!(fighter.bag && (fighter.bag[itemId] || 0) > 0);
  }

  _spendBag(fighter, itemId) {
    if (!fighter.bag) return;
    const n = fighter.bag[itemId];
    if (!n) return;
    if (n <= 1) delete fighter.bag[itemId];
    else fighter.bag[itemId] = n - 1;
  }

  _bestSeBench(fighter, defender) {
    if (!defender) return null;
    let best = null;
    let bestEff = 1;
    for (let i = 1; i <= fighter.mons.length; i += 1) {
      if (i !== fighter.active) {
        const bench = fighter.mons[i - 1];
        if (bench && bench.hp > 0) {
          let maxEff = 1;
          for (let j = 0; j < bench.moves.length; j += 1) {
            const m = bench.moves[j];
            if (this._hasPp(fighter, m) && m.power > 0) {
              const eff = this._effectivenessProduct(m.type, defender);
              if (eff > maxEff) maxEff = eff;
            }
          }
          if (maxEff > 1) {
            if (!best || maxEff > bestEff || (maxEff === bestEff && i < best)) {
              best = i;
              bestEff = maxEff;
            }
          }
        }
      }
    }
    return best;
  }

  // Bag item for the active mon: cure → heal ≤50% → X-item while stages flat.
  // A player's (`_autoChoice`); the computer keeps no bag.
  _autoItemChoice(fighter, mon) {
    if (!fighter.bag) return null;

    if (mon.status) {
      const list = AUTO_STATUS_CURE[mon.status];
      if (list) {
        for (const id of list) {
          if (this._bagHas(fighter, id)) {
            return { action: 'item', item: id, slot: fighter.active };
          }
        }
      }
    }

    if (mon.hp < mon.maxHp && mon.hp * 2 <= mon.maxHp) {
      for (const id of AUTO_HEAL_PREF) {
        if (this._bagHas(fighter, id)) {
          const effect = Effects.itemEffect(id);
          if (effect && (effect.heal || effect.healFull || effect.clearAllStatus)) {
            return { action: 'item', item: id, slot: fighter.active };
          }
        }
      }
    }

    const stagesFlat = mon.stages.atk <= 0 && mon.stages.def <= 0
      && mon.stages.spd <= 0 && mon.stages.spc <= 0;
    if (stagesFlat && !mon.focusEnergy && !mon.mist) {
      for (const row of AUTO_X_ITEM) {
        if (this._bagHas(fighter, row.id)) {
          if (row.flag === 'focusEnergy' && !mon.focusEnergy) {
            return { action: 'item', item: row.id };
          }
          if (row.flag === 'mist' && !mon.mist) {
            return { action: 'item', item: row.id };
          }
          if (row.stat && (mon.stages[row.stat] || 0) <= 0) {
            return { action: 'item', item: row.id };
          }
        }
      }
    }

    return null;
  }

  // The forced turns, the same answers `_fillForcedChoices` files (that pass
  // runs first, so these are reached only when it could not file one) -- and
  // a player's Bide, trap and hold, which it leaves to the player: an
  // unanswered one is the FIGHT `_menuFight` would make of it. null for a
  // monster free to choose. Shared by a player's timeout (`_autoChoice`) and
  // the computer's answer (`_computerChoice`), so both draw the same aims for
  // them.
  _lockedChoice(fighter, mon) {
    if (mon.charging) {
      const c = mon.charging;
      const forced = forcedMoveOf(mon, c.move, c.moveIndex);
      return {
        action: 'fight', move: c.moveIndex, target: c.targetSlot,
        forcedMove: forced.move, called: forced.called,
      };
    }
    if (mon.mustRecharge) {
      return { action: 'skip', skip: 'recharge' };
    }
    if (mon.bide) {
      const choice = this._bideChoice(fighter, mon);
      if (choice) return choice;
    }
    if (mon.trapping && int(mon.trapping.turns, 0) > 0) {
      return trapChoice(mon);
    }
    if (this._isHeld(fighter, mon) && mon.status !== 'sleep' && mon.status !== 'freeze'
        && !(mon.thrashing && mon.thrashing.turns > 0)
        && !(mon.raging && mon.rageMove && mon.rageMove > 0)) {
      return { action: 'skip', skip: 'trapped' };
    }
    if (mon.thrashing && mon.thrashing.turns > 0) {
      const foe = this._autoTarget(fighter);
      if (foe) {
        const forced = forcedMoveOf(mon, mon.thrashing.move, mon.thrashing.moveIndex);
        return {
          action: 'fight',
          move: mon.thrashing.moveIndex,
          target: foe.slot,
          forcedMove: forced.move,
          called: forced.called,
        };
      }
    }
    if (mon.raging && mon.rageMove && mon.rageMove > 0) {
      const foe = this._autoTarget(fighter);
      if (foe) {
        const forced = forcedMoveOf(mon, mon.rageCall, mon.rageMove);
        return {
          action: 'fight', move: mon.rageMove, target: foe.slot,
          forcedMove: forced.move, called: forced.called,
        };
      }
    }
    return null;
  }

  // The seat an answer nobody chose is aimed at (`_autoTarget`), or one still
  // owing a send-out when nobody across stands.
  _autoFoe(fighter) {
    let foe = this._autoTarget(fighter);
    if (!foe) {
      for (const f of this._foes(fighter)) {
        if (f.mustReplace) { foe = f; break; }
      }
    }
    return foe;
  }

  _autoChoice(fighter) {
    if (fighter.mustReplace) {
      const foe = this._autoTarget(fighter);
      const defender = foe && activeMon(foe);
      const se = this._bestSeBench(fighter, defender);
      if (se) return { action: 'switch', slot: se };
      const next = firstLiving(fighter.mons);
      if (next) return { action: 'switch', slot: next };
      return null;
    }

    const mon = activeMon(fighter);
    if (!mon) return null;
    const locked = this._lockedChoice(fighter, mon);
    if (locked) return locked;

    const foe = this._autoFoe(fighter);
    if (!foe) return null;
    const defender = activeMon(foe);
    if (!defender) {
      let pick = 1;
      for (let i = 1; i <= mon.moves.length; i += 1) {
        if (this._hasPp(fighter, mon.moves[i - 1])) { pick = i; break; }
      }
      return { action: 'fight', move: pick, target: foe.slot };
    }

    const itemPick = this._autoItemChoice(fighter, mon);
    if (itemPick) return itemPick;

    const foeBoosted = (defender.stages.atk || 0) >= 2
      || (defender.stages.def || 0) >= 2
      || (defender.stages.spd || 0) >= 2
      || (defender.stages.spc || 0) >= 2
      || defender.focusEnergy;
    const foeSub = Effects.hasSubstitute(defender);
    const weSlower = this._speedOf(fighter, mon) < this._speedOf(foe, defender);

    // Critical HP: SE retreat (heal already tried via bag).
    if (mon.hp * 4 <= mon.maxHp) {
      const se = this._bestSeBench(fighter, defender);
      if (se) return { action: 'switch', slot: se };
    }

    // Behind a boosted / subbed foe at mid-low HP: prefer an SE bench mon.
    if ((foeBoosted || foeSub) && mon.hp * 2 <= mon.maxHp) {
      const se = this._bestSeBench(fighter, defender);
      if (se) return { action: 'switch', slot: se };
    }

    const disabled = (i) => mon.disable && mon.disable.turns > 0
      && mon.disable.moveIndex === i;

    let pick = null;
    let pickEff = -1;
    let pickPow = -1;
    for (let i = 1; i <= mon.moves.length; i += 1) {
      const m = mon.moves[i - 1];
      if (this._hasPp(fighter, m) && m.power > 0 && !disabled(i)) {
        const eff = this._effectivenessProduct(m.type, defender);
        if (!pick || eff > pickEff
            || (eff === pickEff && m.power > pickPow)
            || (eff === pickEff && m.power === pickPow && i < pick)) {
          pick = i;
          pickEff = eff;
          pickPow = m.power;
        }
      }
    }

    if (!pick || pickEff === 0) {
      const se = this._bestSeBench(fighter, defender);
      if (se) return { action: 'switch', slot: se };
    }

    if (pick && pickEff > 1) {
      return { action: 'fight', move: pick, target: foe.slot };
    }

    // Status fails against a Substitute; skip it and trade damage instead.
    if (!defender.status && !foeSub) {
      let statusPick = null;
      let statusPri = -1;
      for (let i = 1; i <= mon.moves.length; i += 1) {
        const m = mon.moves[i - 1];
        if (this._hasPp(fighter, m) && !disabled(i) && m.power === 0) {
          const pri = AUTO_STATUS_PRI[m.effect];
          if (pri !== undefined && (pri > statusPri
              || (pri === statusPri && (statusPick === null || i < statusPick)))) {
            statusPick = i;
            statusPri = pri;
          }
        }
      }
      if (statusPick !== null
          && (weSlower || foeBoosted || !pick || pickEff <= 1)) {
        return { action: 'fight', move: statusPick, target: foe.slot };
      }
    }

    const stagesFlat = mon.stages.atk <= 0 && mon.stages.def <= 0
      && mon.stages.spd <= 0 && mon.stages.spc <= 0;
    // Do not set up into a boosted foe, behind a substitute, or while slower
    // at mid-low HP — hit or switch instead.
    if (stagesFlat && !mon.focusEnergy && !foeBoosted && !foeSub
        && !(weSlower && mon.hp * 2 <= mon.maxHp)) {
      let setupPick = null;
      for (let i = 1; i <= mon.moves.length; i += 1) {
        const m = mon.moves[i - 1];
        if (this._hasPp(fighter, m) && !disabled(i) && m.power === 0) {
          const kind = AUTO_SETUP[m.effect];
          if (kind === true
              || (typeof kind === 'string' && (mon.stages[kind] || 0) <= 0)) {
            if (setupPick === null || i < setupPick) setupPick = i;
          }
        }
      }
      if (setupPick !== null) {
        return { action: 'fight', move: setupPick, target: foe.slot };
      }
    }

    if (!(pick && pickEff > 0)) {
      pick = null;
      pickPow = -1;
      for (let i = 1; i <= mon.moves.length; i += 1) {
        const m = mon.moves[i - 1];
        if (this._hasPp(fighter, m) && !disabled(i)) {
          if (!pick || m.power > pickPow
              || (m.power === pickPow && i < pick)) {
            pick = i;
            pickPow = m.power;
          }
        }
      }
    }

    if (pick === null) pick = 1;
    // An empty sheet is Struggle, not a hang: `_useMove` treats `mustStruggle`
    // (including `moves.length === 0`) as the synthetic STRUGGLE even with no slot.
    return { action: 'fight', move: pick, target: foe.slot };
  }

  /*
   * What autoPick / the timeout sweep files when `_autoChoice` has no answer.
   *
   * A living seat in the choice phase that `_autoChoice` cannot describe (empty
   * moves, nothing across the field to aim at) used to return null, so nothing
   * was filed. The hub then waited out BATTLE_CHOICE_TIMEOUT and retried the
   * same null (deadline pushed). Solo sets SOLO_CHOICE_TIMEOUT to 0, which this
   * file reads as "no deadline at all", so the NPC never files, the player has
   * already answered, and the band sits on "Waiting for X..." with RUN refused
   * in a trainer fight -- a battle with no way out.
   *
   * An empty sheet with a living foe is now a fight (`_autoChoice` names slot
   * 1; `_useMove` turns that into Struggle). Skip remains for the leftover
   * case: a living seat with nobody across the field to aim at. A mustReplace
   * seat with no living bench stays null: that seat cannot skip a send-out,
   * and `_checkOver` should have ended the fight.
   */
  _autoChoiceOrSkip(fighter) {
    let auto;
    if (isComputerSeat(this.mode, fighter)) {
      auto = this._computerChoice(fighter);
    } else {
      auto = this._autoChoice(fighter);
    }
    if (auto) return auto;
    if (this.phase === 'choice' && activeMon(fighter)) {
      return { action: 'skip' };
    }
    return null;
  }

  // The computer's answer, as SelectEnemyMove gives it (core.asm :2915-3005).
  // Its forced turns stand as `_lockedChoice` answers them -- SelectEnemyMove
  // returns before `.canSelectMove` for every one of them, drawing nothing.
  // Every other answer is a move chosen at `.canSelectMove`, which is not
  // chosen here: it is drawn from the battle's own stream where the cart
  // draws it, after the players' menus -- their RUN rolls, their switches,
  // their balls -- and before the speed compare (`_selectComputerMoves`), so
  // `cartPick` files the seat and names no slot yet. Its item and its switch
  // are never filed: TrainerAI decides them in the seat's slot of the order
  // (`_trainerAi`), the move SelectEnemyMove picked standing all the same.
  //
  // A send-out owed after a faint is EnemySendOut's (core.asm :1276-1341,
  // `.next` / `.next2`): `wWhichPokemon` walks the party from the top, past
  // wEnemyMonPartyPos and past every monster at 0 HP, and the first one left
  // comes out -- party order, the cart's only rule (a trainer has no say).
  _computerChoice(fighter) {
    if (fighter.mustReplace) {
      const next = firstLiving(fighter.mons, fighter.active);
      if (next) return { action: 'switch', slot: next };
      return null;
    }
    const mon = activeMon(fighter);
    if (!mon) return null;
    const locked = this._lockedChoice(fighter, mon);
    if (locked) return locked;
    const foe = this._autoFoe(fighter);
    if (!foe) return null;
    return { action: 'fight', target: foe.slot, cartPick: true };
  }

  /*
   * File that pick for a seat that has nobody to send one.
   *
   * The npc side of a coop_npc is seated like any other fighter and has no
   * connection behind it, so without this the referee would wait out the whole
   * choice deadline every turn and then auto-pick anyway -- a minute a turn, for
   * a decision nothing was ever going to make. It is deliberately the *same*
   * pick the timeout files rather than a second one (`_autoChoiceOrSkip`): the
   * cart's for the computer's seats (`_computerChoice`), the mod's heuristic
   * for a player's -- both runtimes reproduce it byte for byte.
   *
   * Returns true when a choice was actually filed, so a caller can loop until
   * the machine stops owing. Filing one may resolve the turn and open the next,
   * which is what makes that loop the thing that carries the fight forward.
   */
  autoPick(playerId) {
    if (this.phase !== 'choice' && this.phase !== 'replace') return false;
    const fighter = this.byId.get(str(playerId) || '');
    if (!fighter) return false;
    if (fighter.choice !== null && fighter.choice !== undefined) return false;
    // Same rule as a human's: in the replace phase only the seats that owe a
    // send-out may file, so an NPC that is still standing does not answer a
    // turn that has not opened. The hub's fillNpcChoices calls this in a loop
    // and stops when nothing files, so the false is how the loop learns to stop.
    if (this.phase === 'replace' && !this._owes(fighter)) return false;
    if (!fighter.mustReplace && !activeMon(fighter)) return false;

    const auto = this._autoChoiceOrSkip(fighter);
    if (!auto) return false;
    fighter.choice = auto;
    this._emit('chose', {
      slot: fighter.slot, side: fighter.side, text: fighter.name,
    });
    this._maybeResolve();
    return true;
  }

  // ----------------------------------------------------------------
  // resolution
  // ----------------------------------------------------------------

  _anyoneOwes() {
    for (const fighter of this.fighters) {
      if (this._owes(fighter)) return true;
    }
    return false;
  }

  _openTurn() {
    // A side that is already down must not be asked for a move. Without this,
    // a faint that left the field in `choice` (or `_closeReplace` after an
    // empty send-out) opened a window nobody across the field could answer,
    // and Solo's zero timeout left the band on "Waiting for WILD...".
    if (this._checkOver()) return;
    this.phase = 'choice';
    this.resolveDeadline = null;
    this.forcedPending = false;
    for (const fighter of this.fighters) {
      fighter.choice = null;
      fighter.forced = null;
      // (`cannotMove` stays: Haze's CANNOT_MOVE is the seat's selection until
      // a move menu writes another one -- `_selectsAnew`.)
      // MainInBattleLoop resets both FLINCHED bits as a turn opens
      // (core.asm :293-300), so a flinch landed on a monster that had already
      // moved dies here instead of costing it the NEXT turn -- unless the
      // player's monster is using Rage or must recharge, when the cart jumps
      // past the reset to `.selectEnemyMove`. A raging monster a slower foe
      // flinched therefore loses its next Rage to that flinch (`_runGates`).
      // (A flinch that lands runs ClearHyperBeam on its target, so a monster
      // flinched after its HYPER BEAM is no longer recharging here, and is
      // reset like any other.)
      //
      // "The player" is the owner's rule (`isPlayerSeat`): side a against the
      // computer, and BOTH sides of a link fight (1v1, coop_pvp), each as its
      // own console runs this for its own monster. There the skip is kept,
      // per seat, for that seat's own fielded monster -- a co-op side holds
      // two players, where the cart had one, and each one's rage protects
      // only its own flinch. The skip also spares the enemy's bit on the cart,
      // but in a one-on-one that bit is never set at this point (only the
      // player's own move can flinch the enemy, and a raging or recharging
      // player's last move was Rage or Hyper Beam, neither of which flinches),
      // so the computer's seats are reset like everyone else's rather than
      // inventing whose rage would guard them in a 2v2.
      const mon = activeMon(fighter);
      const kept = isPlayerSeat(this.mode, fighter) && mon && (mon.raging || mon.mustRecharge)
        ? mon : null;
      for (const each of fighter.mons) {
        if (each !== kept) each.flinch = false;
      }
    }
    this.deadline = this.choiceTimeout > 0 ? this.now + this.choiceTimeout : null;
    // Before the window opens, not after: a player deciding this turn is
    // looking at the rosters, and anything a status or a bench potion moved
    // last turn has to be on them by the time the menu is up. Faints are
    // already current -- `_faint` publishes inside its own batch -- so on most
    // turns this emits nothing at all.
    this._syncTeams();
    this._emit('turn', { amount: this.turn });
    this._fillForcedChoices();
    // When every living seat is forced, defer resolve to the next tick so
    // clients see a turn boundary before the chain continues.
    if (!this._anyoneOwes()) {
      this.forcedPending = true;
      this.deadline = null;
    }
  }

  // ----------------------------------------------------------------
  // the replace phase
  // ----------------------------------------------------------------
  //
  // A faint with a living bench used to be folded into the *next* choice
  // window: the referee incremented the turn, opened it, and the seat's
  // replacement rode in alongside everybody else's fight. That is one window
  // with an empty box in it -- the player picked a move at a foe that was not
  // on the field yet, and the successor only walked out when the turn after
  // that resolved. Vanilla never does this, and neither does the host sim
  // beside it: CoopSim's `announceFaint` sends an NPC's next monster out inside
  // the faint batch and asks a player's seat before the fight goes on.
  //
  // So the referee holds a phase of its own between the two turns. Nothing else
  // is asked for, nothing resolves, and the turn number does not move: the
  // fight is still on the turn whose faint opened this. When the last owed
  // replacement is in, `_resolveSwitches` fields them all (`switch` + `send`)
  // and only then does the next turn open. For a seat with no connection behind
  // it that whole phase closes inside one hub flush -- NPC choices are filled
  // before the drain -- so the client reads one batch: faint ... switch ...
  // send ... turn.

  _anyMustReplace() {
    for (const fighter of this.fighters) {
      if (fighter.mustReplace && firstLiving(fighter.mons) !== null) return true;
    }
    return false;
  }

  /*
   * Solicitation: one `turn` per owing seat, carrying the seat's **field slot**.
   *
   * That slot is the whole of the wire change, and it is the client contract:
   *   * `turn` WITH `slot` -- this seat is being asked for a replacement. Its
   *     own client opens the switch picker; everyone else holds on "X is
   *     choosing who to send out...".
   *   * `turn` WITHOUT `slot` -- the ordinary choice window is open (`_openTurn`).
   * No new kind, no new field: `slot` is already in the event whitelist and
   * already rides the wire sanitiser kind-agnostically, so a client built
   * before this ignores it and degrades to the old behaviour rather than
   * breaking.
   *
   * Seat order is `this.fighters`, which is side a then side b in seating order
   * -- ascending field slot, and the same order in both runtimes.
   */
  _openReplace() {
    this.phase = 'replace';
    this.resolveDeadline = null;
    this.forcedPending = false;
    for (const fighter of this.fighters) {
      fighter.choice = null;
      fighter.forced = null;
    }
    this.deadline = this.choiceTimeout > 0 ? this.now + this.choiceTimeout : null;
    // The other window a player answers from, and the same reason: whoever is
    // picking a replacement is picking it off the roster.
    this._syncTeams();
    for (const fighter of this.fighters) {
      if (this._owes(fighter)) {
        this._emit('turn', { amount: this.turn, slot: fighter.slot });
      }
    }
  }

  // Every replacement is in: field them, then open the turn they were owed for.
  _closeReplace() {
    this._resolveSwitches();
    this.turn += 1;
    this._openTurn();
  }

  // The battle Speed, as stored: the stage, the badge and a paralysis are
  // already in it (Effects' stored-stat note), so reading it is the whole rule
  // -- which is how the cart's turn order reads wBattleMonSpeed. `fighter` is
  // kept for the callers' shape.
  _speedOf(fighter, mon) {
    return mon.cur.spd;
  }

  // The bracket an action moves in: the selected move's (Effects.movePriority),
  // as `_selectionOf` names it. Read off the selection, as the cart reads
  // wPlayerSelectedMove before anything runs: a Metronome moves at
  // Metronome's priority whatever it calls, and a disobedient monster at the
  // priority of the move it was told to use, whatever it does instead. A
  // forced replay is the move it replays (`forcedMoveOf`), never Struggle. A
  // computer seat always selects a move (`_computerChoice`): the bracket its
  // slot moves in is that move's even when TrainerAI then spends the slot on
  // an item or a switch (`_trainerAi`).
  _priorityOf(fighter, mon) {
    return Effects.movePriority(fighter.selectedMove);
  }

  // Whether this seat's menu hands it STRUGGLE: the player's AnyMoveToSelect
  // (`mustStruggle`), or the computer's SelectEnemyMove, which never reads PP
  // (`computerMustStruggle`). A link foe is a player on its own cart and keeps
  // its PP.
  _struggles(fighter, mon) {
    if (isComputerSeat(this.mode, fighter)) return computerMustStruggle(mon);
    return mustStruggle(mon);
  }

  // A move the seat may pick for its PP: any, for the computer
  // (`computerMustStruggle`'s note); one with PP left for a player.
  _hasPp(fighter, move) {
    return isComputerSeat(this.mode, fighter) || int(move.pp, 0) > 0;
  }

  // What this turn leaves in wPlayerSelectedMove / wEnemySelectedMove, before
  // anything runs -- read for the priority bracket and by COUNTER
  // (`_counterDamage`). A forced replay's move; STRUGGLE when the menu would
  // hand it out (`_struggles`); else the chosen slot's. Two cart rules keep
  // LAST turn's selection standing instead, because no menu is opened:
  //   * asleep or frozen, MainInBattleLoop jumps past MoveSelectionMenu
  //     (core.asm :308-311) and SelectEnemyMove returns before writing
  //     (:2946-2948) -- so a sleeping monster's priority is last turn's move's;
  //   * a recharge, a Bide's store or a trap's continuation skips the menu
  //     the same way (:293-295, :311-313).
  // A monster held by a trap selects CANNOT_MOVE (:318-321, :2953-2955): null.
  // So does a seat whose CANNOT_MOVE Haze wrote and no menu has written over
  // since (`cannotMove`, `_selectsAnew`).
  // A player's seat that switched, used an item or ran selected nothing the
  // referee can name (the cart answers from its menu cursor): null. The
  // computer's seat never files either (`_computerChoice`): TrainerAI's item
  // or switch comes after SelectEnemyMove has selected the move named here.
  _selectionOf(fighter, mon) {
    const choice = fighter.choice;
    if (!choice || !mon) return null;
    if (fighter.cannotMove) return null;
    const last = fighter.selectedMove === undefined ? null : fighter.selectedMove;
    if (choice.action === 'skip') {
      if (choice.skip && choice.skip !== 'trapped') return last;
      return null;
    }
    if (choice.action !== 'fight') return null;
    if (choice.forcedMove) return choice.forcedMove;
    if (choice.stale || mon.status === 'sleep' || mon.status === 'freeze') return last;
    if (this._struggles(fighter, mon)) return STRUGGLE;
    const move = mon.moves[(choice.move || 0) - 1];
    return move === undefined ? null : move;
  }

  // Whether this turn writes a new selection over the seat's
  // wPlayerSelectedMove / wEnemySelectedMove -- the only thing that lifts the
  // CANNOT_MOVE HazeEffect_ wrote there (move_effects/haze.asm :24-31,
  // `cannotMove`). Nothing resets it at a turn's open, a send-out or a faint:
  // it is the side's selection byte, and it stands until
  //   * the player's MoveSelectionMenu runs -- an ordinary FIGHT of an awake
  //     monster (MainInBattleLoop `.selectPlayerMove`). A recharge, Rage, a
  //     thrash or a charge skips every menu (:293-303); asleep, frozen, a Bide
  //     or a trap of its own skips the move menu (:308-313); a held monster
  //     writes CANNOT_MOVE again (:314-321); a switch, an item or a RUN leaves
  //     the byte alone (`.selectPlayerMove`'s wActionResultOrTookBattleTurn);
  //   * the computer's SelectEnemyMove reaches `.canSelectMove`: none of its
  //     forced turns (:2938-2955, `_fillForcedChoices`) and not asleep or
  //     frozen (:2946-2948).
  // So a target Haze woke that then recharges, rages, thrashes, charges,
  // stores energy or keeps a trap going loses every one of those turns in
  // silence (`_resolveFights`) for as long as the state lasts -- the cart's
  // own lock, kept. Every side of a link fight is a player on its own cart.
  _selectsAnew(fighter, mon) {
    const choice = fighter.choice;
    if (!choice || !mon) return false;
    const asleep = mon.status === 'sleep' || mon.status === 'freeze';
    if (isComputerSeat(this.mode, fighter)) {
      return !fighter.forced && !asleep;
    }
    return choice.action === 'fight' && (choice.forcedMove === null || choice.forcedMove === undefined)
      && !asleep && !choice.stale;
  }

  // The battler opposite this one: the foe seat in the same position if it
  // stands, else the nearest standing foe -- `_retarget` aimed at the mirror
  // slot, which is battle3's oppositeFoe (src/BattleSim3/Move.lua:746-752) in
  // this referee's terms. Gen 1 has exactly one opponent, so a cart rule that
  // says "the enemy" with no target to read it off -- the Reflect the
  // confusion self-hit checks, the battler an X item's re-penalty lands on --
  // asks this in a 2v2. null when the other side has nobody standing.
  _oppositeFoe(fighter) {
    const other = fighter.side === 'a' ? 'b' : 'a';
    return this._retarget(fighter, Events.fieldSlot(other, fighter.index));
  }

  /*
   * chart[atkType][defType], one percent per defender type, because
   * Damage.compute applies them as separate truncating steps the way the
   * original does. A missing row, a missing cell or no chart at all reads as
   * neutral: a party naming a type this match's chart has no row for is a
   * well-formed party, and refusing it over a lookup would be worse than
   * fighting it straight.
   *
   * The Lua indexes this as chart[atkType + 1][defType + 1] because its arrays
   * start at one. Same chart, same cell -- a JSON type chart transfers between
   * the two runtimes unchanged.
   */
  _typePercents(moveType, defender) {
    const row = this.chart ? this.chart[moveType] : null;
    const out = [];
    for (const defType of defender.types) {
      let pct = 100;
      if (isTable(row)) {
        const cell = toNumber(row[defType]);
        if (cell !== null) pct = Math.floor(cell);
      }
      // The Lua's Damage.compute treats any percent <= 0 as immunity; this
      // one short-circuits on exactly 0. Folding a negative cell down to 0
      // here is how a chart nobody should have written still resolves the
      // same fight on both runtimes.
      out.push(pct < 0 ? 0 : pct);
    }
    if (out.length === 0) out.push(100);
    return out;
  }

  // AdjustDamageForMoveType's walk (core.asm :5121-5175), for a hit's damage
  // and its lines: the percents to apply, in order, and the percent the walk
  // leaves in wDamageMultipliers. With the ruleset's `chartOrder`
  // (`chartRows`) that is every TypeEffects row whose attacker is the move's
  // type and whose defender is either of the target's types -- once per row,
  // a mono type matching it once -- in table order, each row's multiplier its
  // `chart` cell, and the last one applied is the one left (EFFECTIVE, 100,
  // when no row matched). Without the order the chart's cells are applied per
  // defender type and the second value is null, which `typeLine` / the miss
  // text read as the product.
  _typeRows(moveType, defender) {
    if (!this.chartRows) return { percents: this._typePercents(moveType, defender), last: null };
    const row = this.chart ? this.chart[moveType] : null;
    const out = [];
    let last = 100;
    for (const pair of this.chartRows) {
      if (pair[0] === moveType && hasType(defender, pair[1])) {
        const cell = isTable(row) ? toNumber(row[pair[1]]) : null;
        // A negative cell is an immunity, as Damage.compute reads one.
        last = cell !== null ? Math.max(0, Math.floor(cell)) : 100;
        out.push(last);
      }
    }
    return { percents: out, last };
  }

  _resolveTurn() {
    this.phase = 'resolving';
    // Armed for the rare case resolution does not leave this phase in the same
    // call -- a throw mid-resolve used to leave the field wedged forever, and
    // the hub's handle() contains those throws so the clock has to finish the job.
    this.resolveDeadline = this.resolveTimeout > 0
      ? this.now + this.resolveTimeout : null;

    if (this._resolveRuns()) return;
    // The players' switches and items first (DisplayBattleMenu runs them
    // before the order is asked); the computer's wait for its own slot of the
    // order, inside `_resolveFights`. SelectEnemyMove runs after them, so it
    // sees what they did to a trap (`_reselectComputer`).
    this._resolveSwitches(true);
    this._resolveItems();
    if (!this.result) this._reselectComputer();
    if (!this.result) this._selectComputerMoves();
    // Each seat's residual comes at the end of its own slot, inside the order
    // (`_resolveFights`); there is no end-of-turn pass.
    const cut = this._resolveFights();
    // CheckNumAttacksLeft, the last thing a cart turn does (core.asm :409,
    // :460): a trap whose counter ran out lets go -- reached only when both
    // slots went by, so not on a turn a faint cut short (`cut`).
    if (!this.result && !cut) this._checkNumAttacksLeft();
    // Unconditional, because a queue nobody drains is exp that silently never
    // happened.
    this._drainExp();
    if (!this.result) this._checkOver();

    // A seat that fell with a bench left is asked before anything else happens;
    // see the replace-phase note above. The turn does not advance here: it
    // advances in `_closeReplace`, once the successor is actually on the field.
    if (!this.result && this._anyMustReplace()) {
      this._openReplace();
      return;
    }

    if (!this.result) {
      this.turn += 1;
      this._openTurn();
    }
  }

  // SelectEnemyMove (core.asm :2915-2955) runs after the player's menu, so
  // the computer's selection is made against the field the player's switch
  // and item left: a trap the computer was keeping going that a switch let go
  // (SendOutMon's `res USING_TRAPPING_MOVE` on the enemy, :1754-1755), and a
  // hold on it that the player's trapper switching out or spending its last
  // turn on an item let go (`_itemTrapStep`), both leave nothing for
  // `.noLinkBattle` to keep -- it reaches `.canSelectMove` and picks afresh.
  // The forced fill `_fillForcedChoices` made at the turn's open is replaced
  // by the computer's pick (`_autoChoiceOrSkip`, the same one `autoPick`
  // files) -- not the stale trapping move run fresh, which is the player's
  // cart's.
  _reselectComputer() {
    for (const fighter of this.fighters) {
      const choice = fighter.choice;
      const mon = activeMon(fighter);
      if (fighter.forced && choice && mon && isComputerSeat(this.mode, fighter)) {
        const released = (choice.trapContinue && !mon.trapping)
          || (choice.skip === 'trapped' && !this._isHeld(fighter, mon));
        if (released) {
          fighter.forced = null;
          fighter.choice = this._autoChoiceOrSkip(fighter);
        }
      }
    }
  }

  // SelectEnemyMove past its forced returns (core.asm :2956-3005), for every
  // computer seat `_computerChoice` filed, in field order, where the cart runs
  // it: `.selectEnemyMove`, after the players' menus and before the speed
  // compare. A monster asleep or frozen returns before `.canSelectMove`
  // (`and (1 << FRZ) | SLP_MASK / ret nz`) -- no draw, last turn's selection
  // stands (`stale`, `_selectionOf`) -- and so does one the players' items or
  // switches left there; every other one is picked (`_cartMovePick`).
  _selectComputerMoves() {
    for (const fighter of this.fighters) {
      const choice = fighter.choice;
      const mon = activeMon(fighter);
      if (choice && choice.cartPick && mon) {
        choice.cartPick = null;
        if (mon.status === 'sleep' || mon.status === 'freeze') {
          choice.stale = true;
          if (choice.move === undefined || choice.move === null) choice.move = 1;
        } else {
          this._cartMovePick(fighter, mon, choice);
        }
      }
    }
  }

  // `.canSelectMove` and `.chooseRandomMove` (core.asm :2956-3005). A monster
  // whose second slot is empty and whose one move is disabled selects STRUGGLE
  // with no draw (`computerMustStruggle`, read again by `_struggles`). A trainer
  // runs AIEnemyTrainerChooseMoves first (`_aiTrainerMoves`, its seat's
  // `aiMods`); a wild monster does not (`wIsInBattle` 1 jumps straight to
  // `.chooseRandomMove`). Then one BattleRandom byte per try names a slot --
  // below 25 percent (63) the first, below 50 percent (127) the second, below
  // 75 percent - 1 (190) the third, else the fourth -- and a try that lands on
  // the disabled slot (wEnemyDisabledMove's high nibble) or on an empty one
  // (no move there, or one the AI's list zeroed) draws again. PP is never read
  // (`computerMustStruggle`'s note). The slot is wEnemyMoveListIndex
  // (`moveListIndex`) and the fight's move -- the selection TrainerAI may then
  // spend the slot past (`_trainerAi`).
  _cartMovePick(fighter, mon, choice) {
    if (computerMustStruggle(mon)) {
      choice.move = 1;
      return;
    }
    let usable = null;
    if (fighter.aiMods && !isWildSeat(this.mode, fighter)) {
      usable = this._aiTrainerMoves(fighter, mon, choice);
    }
    const disabled = (mon.disable && int(mon.disable.turns, 0) > 0)
      ? int(mon.disable.moveIndex, 0) : 0;
    let slot = null;
    for (let i = 0; i < Effects.REDRAW_GUARD; i += 1) {
      const roll = this.rng.byte();
      let b = 4;
      if (roll < 63) b = 1;
      else if (roll < 127) b = 2;
      else if (roll < 190) b = 3;
      if (b !== disabled && moveAt(mon, b) && (usable === null || usable[b])) {
        slot = b;
        break;
      }
    }
    if (slot === null) slot = 1;
    fighter.moveListIndex = slot;
    choice.move = slot;
  }

  // AIGetTypeEffectiveness (core.asm): the FIRST TypeEffects row whose
  // attacker is the move's type and whose defender is either of the target's
  // types -- no product, no second row -- or $10 when none matches. With the
  // ruleset's `chartOrder` (`chartRows`) that is the cart's walk; without it
  // the order is unknowable, and the target's first type is asked before its
  // second. The cell's percent stands in for the row's 0 / 5 / 20: above 100
  // is super effective, below it not effective (an immunity included), and a
  // cell of 100 is no row at all. Answers above / below / at AI_NEUTRAL.
  _aiTypeEffectiveness(moveType, target) {
    const row = this.chart ? this.chart[int(moveType, 0)] : null;
    const cellOf = (defType) => {
      const cell = isTable(row) ? toNumber(row[defType]) : null;
      return cell !== null ? Math.floor(cell) : 100;
    };
    const judged = (cell) => {
      if (cell > 100) return AI_NEUTRAL + 1;
      if (cell < 100) return AI_NEUTRAL - 1;
      return AI_NEUTRAL;
    };
    if (this.chartRows) {
      for (const pair of this.chartRows) {
        if (pair[0] === int(moveType, 0) && hasType(target, pair[1])) {
          return judged(cellOf(pair[1]));
        }
      }
      return AI_NEUTRAL;
    }
    for (const defType of (target.types || [])) {
      const cell = cellOf(defType);
      if (cell !== 100) return judged(cell);
    }
    return AI_NEUTRAL;
  }

  // AIEnemyTrainerChooseMoves (engine/battle/trainer_ai.asm :3-115): every
  // move starts at 10, the disabled slot at $50; the seat's layers run in the
  // class's order, each over the moves in slot order --
  //   1: the target has a status: +5 to a power-0 StatusAilmentMoveEffects move;
  //   2: only while wAILayer2Encouragement is exactly 1 (`aiLayer2`, the second
  //      selection after a send-out): -1 to an effect from ATTACK_UP1_EFFECT up
  //      to BIDE_EFFECT, or from ATTACK_UP2_EFFECT up to POISON_EFFECT;
  //   3: -1 to a move whose type the target takes super-effectively
  //      (`_aiTypeEffectiveness`, power 0 included); +1 to one it takes not
  //      very effectively or not at all when the monster knows a "better move"
  //      -- SUPER FANG, a SPECIAL_DAMAGE move, FLY, or any damaging move of
  //      another type (the scan includes the move judged);
  //   4: nothing --
  // and the slots left at the lowest score are the ones `.chooseRandomMove` may
  // land on (the decrement loop and `.filterMinimalEntries` keep exactly the
  // minima). Each layer reads the moves it looks at with ReadMove, which
  // copies them over wEnemyMoveNum.., the computer's move struct: the last one
  // read is what COUNTER finds there until the monster's own move reloads it
  // (`moveStruct`, `_counterDamage`). "The target" is the seat the computer
  // is aimed at (Gen 1's one opponent).
  _aiTrainerMoves(fighter, mon, choice) {
    const moves = mon.moves || [];
    const n = Math.min(4, moves.length);
    const score = { };
    for (let i = 1; i <= n; i += 1) score[i] = 10;
    const disabled = (mon.disable && int(mon.disable.turns, 0) > 0)
      ? int(mon.disable.moveIndex, 0) : 0;
    if (disabled >= 1 && disabled <= n) score[disabled] = 0x50;
    let target = (choice.target !== undefined && choice.target !== null)
      ? this._retarget(fighter, choice.target) : null;
    if (!target) target = this._oppositeFoe(fighter);
    const targetMon = target ? activeMon(target) : null;
    let lastRead = null;
    for (const layer of (fighter.aiMods || [])) {
      if (layer === 1) {
        if (targetMon && targetMon.status) {
          for (let i = 1; i <= n; i += 1) {
            const m = moves[i - 1];
            lastRead = m;
            if (int(m.power, 0) === 0 && AI_STATUS_EFFECTS[int(m.effect, 0)]) {
              score[i] += 5;
            }
          }
        }
      } else if (layer === 2) {
        if (fighter.aiLayer2 === 1) {
          for (let i = 1; i <= n; i += 1) {
            const m = moves[i - 1];
            lastRead = m;
            const effect = int(m.effect, 0);
            if ((effect >= 10 && effect < 26) || (effect >= 50 && effect < 66)) {
              score[i] -= 1;
            }
          }
        }
      } else if (layer === 3) {
        for (let i = 1; i <= n; i += 1) {
          const m = moves[i - 1];
          lastRead = m;
          const eff = targetMon ? this._aiTypeEffectiveness(m.type, targetMon) : AI_NEUTRAL;
          if (eff > AI_NEUTRAL) {
            score[i] -= 1;
          } else if (eff < AI_NEUTRAL) {
            let better = false;
            for (let j = 1; j <= n; j += 1) {
              const other = moves[j - 1];
              lastRead = other;
              if (AI_BETTER_EFFECTS[int(other.effect, 0)]) { better = true; break; }
              if (int(other.type, 0) !== int(m.type, 0) && int(other.power, 0) > 0) {
                better = true;
                break;
              }
            }
            if (better) score[i] += 1;
          }
        }
      }
    }
    if (lastRead) {
      fighter.moveStruct = { power: int(lastRead.power, 0), type: int(lastRead.type, 0),
        effect: int(lastRead.effect, 0) };
    }
    let best = null;
    for (let i = 1; i <= n; i += 1) {
      if (best === null || score[i] < best) best = score[i];
    }
    const usable = {};
    for (let i = 1; i <= n; i += 1) {
      if (score[i] === best) usable[i] = true;
    }
    return usable;
  }

  // TryRunningFromBattle (core.asm :1496-1576), the wild arm, for a coop_wild
  // runner (RUN_ROLL_MODES): wNumRunAttempts counts every try -- each
  // player's own, as each console keeps its own -- and a runner at least as
  // fast as the wild monster gets away, as does one whose odds pass 255
  // (Effects.runOdds); otherwise one BattleRandom byte at or under the odds
  // does. "Got away safely!" or "Can't escape!" -- and a failed try has spent
  // the turn (wActionResultOrTookBattleTurn): the seat is in the order and
  // does nothing in its slot.
  _tryRun(fighter) {
    const mon = activeMon(fighter);
    const foe = this._oppositeFoe(fighter);
    const wild = foe ? activeMon(foe) : null;
    let escaped = true;
    if (mon && wild) {
      fighter.runAttempts = int(fighter.runAttempts, 0) + 1;
      const odds = Effects.runOdds(this._speedOf(fighter, mon), this._speedOf(foe, wild),
        fighter.runAttempts);
      if (odds !== null) escaped = this.rng.byte() <= odds;
    }
    if (escaped) {
      this._say('Got away safely!');
    } else {
      this._say("Can't escape!");
    }
    return escaped;
  }

  // Fleeing is a concession in 1v1/coop_pvp and a wild escape in *wild modes;
  // see Effects.runEndsBattle. A trainer fight never gets here: its RUN is
  // refused at the menu (`_normaliseChoice`), as the cart sends it back to
  // DisplayBattleMenu. A coop_wild runner rolls first (`_tryRun`), in field
  // order, and the first one to get away ends the fight.
  _resolveRuns() {
    let running = this.fighters.filter(
      (fighter) => fighter.choice && fighter.choice.action === 'run',
    );
    if (running.length === 0) return false;

    if (RUN_ROLL_MODES[this.mode]) {
      let away = null;
      for (const fighter of running) {
        if (this._tryRun(fighter)) { away = fighter; break; }
      }
      if (!away) return false;
      running = [away];
    }

    const sides = { a: false, b: false };
    for (const fighter of running) {
      sides[fighter.side] = true;
      this._emit('run', { slot: fighter.slot, side: fighter.side, text: fighter.name });
    }

    if (sides.a && sides.b) {
      this._finish('draw', null, null, 'run');
    } else if (sides.a) {
      this._finish('win', this._sidePlayers('b'), this._sidePlayers('a'), 'run');
    } else {
      this._finish('win', this._sidePlayers('a'), this._sidePlayers('b'), 'run');
    }
    return true;
  }

  // `inTurn` is the turn's own pass -- the players' switches, which
  // DisplayBattleMenu runs before the order is asked; the computer's voluntary
  // switch is TrainerAI's, in its slot (`_trainerAi`) -- and the replace phase
  // fields everybody's send-outs.
  _resolveSwitches(inTurn) {
    for (const fighter of this.fighters) {
      const choice = fighter.choice;
      if (choice && choice.action === 'switch') {
        // ReplaceFaintedEnemyMon zeroes wAILayer2Encouragement after the
        // send-out (core.asm :906-911); TrainerAI's own switch does not.
        if (!inTurn && fighter.mustReplace) fighter.aiLayer2 = 0;
        this._switchIn(fighter, choice.slot);
      }
    }
  }

  // One seat's switch-in: LoadBattleMonFromParty and the send-out around it.
  _switchIn(fighter, slot) {
    const mon = monAt(fighter, slot);
    if (!(mon && mon.hp > 0)) return;
    // The monster going back keeps nothing of the battle struct: a Transform
    // and a MIMIC are undone the moment it leaves (`Effects.restoreMoves`), so
    // a bench monster's moves, types and species are its own again. And a
    // TOXIC is plain poison on the bench: BADLY_POISONED is a BattleStatus3
    // bit, which the next send-out clears (SendOutMon, core.asm :1747-1752),
    // while the party's status byte only ever held PSN -- so it comes back
    // poisoned at a sixteenth a turn, its counter forgotten.
    const leaving = fighter.active ? monAt(fighter, fighter.active) : null;
    if (leaving && leaving !== mon) {
      Effects.restoreMoves(leaving);
      if (leaving.status === 'toxic') leaving.status = 'poison';
      leaving.toxicLinger = null;
    }
    fighter.active = slot;
    fighter.mustReplace = null;
    // EnemySendOutFirstMon's `dec a / ld [wAICount], a` (core.asm
    // :1306-1307): $ff, so TrainerAI reloads the class's uses for the
    // newcomer -- "number of times (per Pokémon)" (ai_pointers.asm). Only a
    // trainer seat ever reads it (`_trainerAi`).
    fighter.aiCount = AI_COUNT_RELOAD;
    // The seat's monster changed: its own participation set resets and the
    // standing opposition re-marks into it, while the incoming monster joins
    // the sets of the foes it is now in against.
    this._refield(fighter);
    // wPlayerUsedMove / wEnemyUsedMove, both zeroed at every send-out
    // (core.asm :767-769, :1303-1305, :1741-1743): MIRROR MOVE has nothing to
    // copy until somebody moves again.
    for (const seat of this.fighters) {
      for (const each of seat.mons) each.lastUsedMove = null;
    }
    Effects.restoreMoves(mon);
    mon.toxicLinger = null;
    mon.charging = null;
    mon.invulnerable = false;
    mon.thrashing = null;
    mon.raging = false;
    mon.rageMove = 0;
    mon.rageCall = null;
    mon.trapped = null;
    mon.trapping = null;
    mon.bide = null;
    mon.substitute = 0;
    mon.subAtZero = null;
    mon.lightScreen = false;
    mon.reflect = false;
    mon.mist = false;
    mon.focusEnergy = false;
    mon.transformed = false;
    mon.xAccuracy = false;
    mon.leechSeed = null;
    mon.disable = null;
    // SendOutMon / EnemySendOutFirstMon zero all three BattleStatus bytes
    // (`ld hl, wPlayerStatsToDouble` and four `ld [hli], a`, core.asm
    // :1744-1749; the enemy's :1292-1299), not only the bits above: CONFUSED
    // and FLINCHED (BattleStatus1) and NEEDS_TO_RECHARGE (BattleStatus2) go
    // too, so a monster that left confused comes back clear-headed.
    mon.confusion = 0;
    mon.flinch = false;
    mon.mustRecharge = false;
    // ...and BattleStatus3's BADLY_POISONED, so a monster a sheet sent in as
    // TOX from the bench is plainly poisoned, as the leaving one above is.
    if (mon.status === 'toxic') mon.status = 'poison';
    // LoadBattleMonFromParty: party stats -> unmodified -> battle, the
    // penalty, this seat's badges, and every stage back to neutral.
    Effects.loadBattleStats(mon, fighter.badges);
    this._clearTrapsFrom(fighter.slot);
    // `mon` is the index the referee just fielded -- `slot`, already
    // normalised to a party position by `_normaliseChoice`. This is the one
    // that matters most: a forced post-faint replacement lands here too, so
    // without it a seat holding two of a species re-fields the fallen copy on
    // the client while the referee holds the living one.
    this._emit('switch', {
      slot: fighter.slot, side: fighter.side, text: mon.species,
      speciesId: mon.speciesId, level: mon.level,
      mon: slot - 1,
    });
    this._emit('send', {
      slot: fighter.slot, side: fighter.side, hp: mon.hp, maxHp: mon.maxHp,
      text: mon.species,
      speciesId: mon.speciesId, level: mon.level,
      mon: slot - 1,
      // (No `confused`: the send-out above cleared it.)
      status: mon.status && has(STATUS_TO_WIRE, mon.status)
        ? STATUS_TO_WIRE[mon.status] : undefined,
    });
  }

  _clearTrapsFrom(slot) {
    for (const fighter of this.fighters) {
      const mon = activeMon(fighter);
      if (mon && mon.trapped && mon.trapped.fromSlot === slot) mon.trapped = null;
      if (mon && mon.trapping && mon.trapping.targetSlot === slot) mon.trapping = null;
    }
  }

  _resolveItems() {
    // Non-ball items keep Gen1 array order (heals, dolls, vitamins, …). Balls
    // resolve in a second pass ordered by active-mon speed (fight tie policy),
    // so the faster thrower spends first and a successful catch aborts the rest.
    // Only the players' items are here: the computer's are TrainerAI's, used
    // in its slot of the order (`_trainerAi`, `_resolveFights`).
    for (const fighter of this.fighters) {
      if (this.result) return;
      const choice = fighter.choice;
      if (choice && choice.action === 'item') {
        const effect = Effects.itemEffect(choice.item);
        if (!(effect && effect.ball)) {
          this._resolveOneItem(fighter);
          if (!this.result) this._itemTrapStep(fighter);
        }
      }
    }

    const balls = [];
    for (const fighter of this.fighters) {
      const choice = fighter.choice;
      if (choice && choice.action === 'item') {
        const effect = Effects.itemEffect(choice.item);
        if (effect && effect.ball) {
          const mon = activeMon(fighter);
          balls.push({
            fighter,
            speed: mon ? this._speedOf(fighter, mon) : 0,
            order: balls.length + 1,
          });
        }
      }
    }
    this._orderActors(balls);
    for (const actor of balls) {
      if (this.result) return;
      this._resolveOneItem(actor.fighter);
      if (!this.result) this._itemTrapStep(actor.fighter);
    }
  }

  // UseBagItem (core.asm :2261-2268): an item a player's trapper uses takes
  // the turn its trap would have hit in, and still spends a step of the trap's
  // counter (wPlayerNumAttacksLeft) -- the step that reaches 0 lets go there
  // and then, before SelectEnemyMove looks (`_reselectComputer`). The held
  // monster's mirror follows (`_trapTurn`'s). The computer's items are
  // TrainerAI's, which never touch the counter.
  _itemTrapStep(fighter) {
    const mon = activeMon(fighter);
    const trap = mon ? mon.trapping : null;
    if (!trap || int(trap.turns, 0) <= 0) return;
    trap.turns = int(trap.turns, 0) - 1;
    const held = this._fighterAtSlot(trap.targetSlot);
    const heldMon = held ? activeMon(held) : null;
    if (heldMon && heldMon.trapped && heldMon.trapped.fromSlot === fighter.slot) {
      heldMon.trapped.turns = trap.turns;
    }
    if (trap.turns <= 0) this._dropTrap(fighter, mon);
  }

  // Sort actors by priority bracket (desc), then active-mon speed (desc), then
  // field order; tied groups flip on one RNG byte >= TIE_BREAK_ROLL. Shared by
  // fights and ball throws -- a ball carries no `priority`, so every thrower
  // sits in one bracket and the order is Speed's, as it always was.
  //
  // pokered's MainInBattleLoop for two battlers (core.asm :369-412): a Quick
  // Attack on one side only moves first, a Counter on one side only moves
  // last, the same move on both sides goes to `.compareSpeed`, and a Speed tie
  // is the coin flip. battle2's `_orderActors` is the same machine with Gen
  // 2's table; a cart compare between two moves is a bracket compare between
  // two actors, so a field of any size sorts the same way.
  _orderActors(actors) {
    if (actors.length <= 1) return;

    actors.sort((x, y) => {
      const xp = x.priority || 0;
      const yp = y.priority || 0;
      if (xp !== yp) return yp - xp;
      if (x.speed !== y.speed) return y.speed - x.speed;
      return x.order - y.order; // field order: side a, then side b
    });

    // One byte per group of actors in one bracket at one Speed, spent only
    // when the group is actually tied, so an ordinary turn between two
    // different speeds costs no draw at all on either runtime.
    let i = 0;
    while (i < actors.length) {
      let j = i;
      while (j < actors.length - 1 && actors[j + 1].speed === actors[i].speed
             && (actors[j + 1].priority || 0) === (actors[i].priority || 0)) {
        j += 1;
      }
      if (j > i && this.rng.byte() >= TIE_BREAK_ROLL) {
        for (let lo = i, hi = j; lo < hi; lo += 1, hi -= 1) {
          const swap = actors[lo];
          actors[lo] = actors[hi];
          actors[hi] = swap;
        }
      }
      i = j + 1;
    }
  }

  // Whether a player's use of `effect` (a normalised item `choice`: party
  // `slot`, 1-based `move`) is one the cart's ItemUseFailed takes -- the item
  // kept, the turn not spent (`_normaliseChoice`). ItemUseNotTime: a POKé
  // DOLL outside a wild fight (ItemUsePokeDoll's `dec a / jp nz`), an X item
  // or another battle-only item aimed at a benched monster (the menu never
  // offers it). ItemUseNoEffect: a PP item whose `.restorePP` restores
  // nothing on the monster's own moves (`ownMoves`), and a medicine with
  // nothing to do -- no HP to restore (a FULL RESTORE at full HP still cures
  // a status, `.notFullHP`'s FULL_HEAL fallthrough) and no status it cures
  // (`.checkMonStatus`). The fainted cases are `_normaliseChoice`'s own. An
  // item with no table row, a ball, a vitamin and the POKé FLUTE are always
  // used (the flute's "Now, that's a catchy tune!" spends the turn).
  _itemFails(fighter, effect, choice) {
    if (!effect) return false;
    if (effect.pokeDoll) return !Effects.isWildMode(this.mode);
    if (effect.ball || effect.vitamin || effect.pokeFlute) return false;
    const partyIdx = choice.slot != null ? choice.slot : fighter.active;
    const mon = monAt(fighter, partyIdx);
    if (!mon) return true;
    if (effect.activeOnly && partyIdx !== fighter.active) return true;
    if (effect.xAccuracy || effect.focusEnergy || effect.mist || effect.stage
        || effect.revive) {
      return false;
    }
    if (effect.ppRestore) {
      return !wouldRestorePp(ownMoves(mon)[int(choice.move, 0) - 1], effect.ppRestore);
    }
    if (effect.ppRestoreAll) {
      for (const move of ownMoves(mon)) {
        if (wouldRestorePp(move, effect.ppRestoreAll)) return false;
      }
      return true;
    }
    const heals = Boolean(effect.healFull || (effect.heal && effect.heal > 0))
      && mon.hp < mon.maxHp;
    const cures = mon.status != null && Boolean(effect.clearAllStatus
      || (effect.clearStatuses && effect.clearStatuses[mon.status]));
    return !(heals || cures);
  }

  _resolveOneItem(fighter) {
    const choice = fighter.choice;
    if (!(choice && choice.action === 'item')) return;

    const effect = Effects.itemEffect(choice.item);
    // Vitamins apply before the `item` event so `amount=1` can mean
    // "Stat Exp writeback is owed"; a failed vitamin still spends the bag
    // stack (Gen1) but must not bump save.statExp on the client.
    let vitaminApplied = false;
    let vitaminMon = null;
    let vitaminResult = null;
    if (effect && effect.vitamin) {
      const partyIdx = choice.slot != null ? choice.slot : fighter.active;
      const mon = monAt(fighter, partyIdx);
      if (mon && mon.hp > 0) {
        const result = Effects.applyVitamin(mon, choice.item);
        if (result) {
          vitaminApplied = true;
          vitaminMon = mon;
          vitaminResult = result;
          // The fielded monster's battle stats are rebuilt the way a level-up
          // mid-fight rebuilds them (Effects.recalcBattleStats); a benched
          // one is rebuilt by its next switch-in anyway.
          if (partyIdx === fighter.active && result.stat !== 'hp') {
            Effects.recalcBattleStats(mon, fighter.badges);
          }
        }
      }
    }
    const itemEv = {
      slot: fighter.slot, side: fighter.side, text: choice.item,
    };
    if (vitaminApplied) itemEv.amount = 1;
    this._emit('item', itemEv);
    const label = itemLabel(choice.item);
    const wild = Effects.isWildMode(this.mode);
    // The line the use opens with -- a player's: the computer's items are
    // TrainerAI's (`_aiUseItem`). ItemUseText00, "<PLAYER> used <ITEM>!",
    // where its routine prints it: a ball (ItemUseBall, before the throw --
    // not in a trainer fight, which blocks the ball first), X ACCURACY, GUARD
    // SPEC., DIRE HIT, a POKé DOLL in a wild fight and the X stat items
    // (PrintItemUseTextAndRemoveItem). A medicine, a PP restorer and the POKé
    // FLUTE print only what they did. ItemUseText00 breaks at its
    // `text_low`, before the item (K18).
    if (effect && ((effect.ball && wild) || effect.xAccuracy || effect.mist
        || effect.focusEnergy || (effect.pokeDoll && wild) || effect.stage)) {
      this._say(`${fighter.name} used\n${label}!`);
    }
    // Spend after the announce (Gen1 bag stack). noConsume (Poké Flute) and
    // seats with no bag sheet are left alone, and so is a player's use the
    // cart's ItemUseFailed takes (`_itemFails`): `_normaliseChoice` refuses
    // one before it is filed, so only a field that moved under a filed choice
    // gets here with it -- and RemoveUsedItem is never reached then either.
    const fails = this._itemFails(fighter, effect, choice);
    if (!(effect && effect.noConsume) && !fails) {
      this._spendBag(fighter, choice.item);
    }
    if (!effect) {
      // An item the referee has no table row for: ItemUseNoEffect's line.
      this._say(NO_EFFECT_TEXT);
    } else if (effect.ball) {
      if (!wild) {
        // ThrowBallAtTrainerMon (item_effects.asm :2292-2303): the toss --
        // TOSS_ANIM whatever the ball, on the thrower's seat (K20), and
        // TossBallAnimation's `.BlockBall` (animations.asm) plays
        // BLOCKBALL_ANIM straight behind it, the trainer knocking it away --
        // then the lines, and the ball is gone.
        this._statusAnim(fighter, 'TOSS_ANIM');
        this._statusAnim(fighter, 'BLOCKBALL_ANIM');
        this._say('The trainer\nblocked the BALL!');
        this._say("Don't be a thief!");
      } else {
        // Wild modes seat exactly one monster on side b, so "the first
        // living foe" and "the only foe" are the same seat -- no aim to
        // spread.
        const foe = this._firstLivingFoe(fighter);
        const target = foe && activeMon(foe);
        if (!target) {
          this._say('But, it failed!');
        } else {
          const result = Effects.catchAttempt(choice.item, target, this.rng);
          // Gen1 TossBallAnimation chain before the catch text (engine ballChain).
          this._emitBallChain(fighter, choice.item, result.caught, result.shakes);
          // ItemUseBall's `.printMessage` off wPokeBallAnimData: the shake
          // count picks ItemUseBallText01..04; a catch is ItemUseBallText05.
          if (result.caught) {
            // ItemUseBallText05 names wEnemyMonNick bare (K17).
            this._say(`All right!\n${target.species} was\ncaught!`);
            const finish = this._finish(
              'win',
              this._sidePlayers(fighter.side),
              this._sidePlayers(fighter.side === 'a' ? 'b' : 'a'),
              'catch',
            );
            const sheet = Effects.caughtSheet(target);
            if (finish && sheet) finish.caught = sheet;
            if (finish) finish.catcher = fighter.playerId;
          } else {
            this._say(BALL_MISS_TEXT[int(result.shakes, 0)] || BALL_MISS_TEXT[0]);
          }
        }
      }
    } else if (effect.pokeDoll) {
      if (wild) {
        // wEscapedFromBattle, and the fight is over: no line past the use's.
        // A POKé DOLL escape leaves wBattleResult at 0 too: Pay Day is paid.
        this._payDayOn(this._finish(
          'win',
          this._sidePlayers(fighter.side),
          this._sidePlayers(fighter.side === 'a' ? 'b' : 'a'),
          'run',
        ));
      } else {
        // ItemUsePokeDoll outside a wild fight is ItemUseNotTime.
        this._say(`OAK: ${fighter.name}!\nThis isn't the\ntime to use that!`);
      }
    } else if (effect.vitamin) {
      if (!vitaminApplied) {
        this._say('But, it failed!');
      } else {
        const mon = vitaminMon;
        const result = vitaminResult;
        // VitaminStatRoseText, "<MON>'s <STAT> rose." -- the cart's line for a
        // vitamin, which it only takes outside a fight (ItemUseVitamin is
        // ItemUseNotTime in one); the referee lets it in and says the same.
        const statLabel = ({
          hp: 'HEALTH', atk: 'ATTACK', def: 'DEFENSE',
          spd: 'SPEED', spc: 'SPECIAL',
        })[result.stat] || 'STAT';
        if (result.stat === 'hp' && result.delta > 0) {
          this._emit('drain', {
            slot: fighter.slot, side: fighter.side,
            // ...and what the bar is now out of: an HP UP moves the maximum
            // itself, so a client told only the new HP would draw the rise
            // against the old ceiling.
            amount: result.delta, hp: mon.hp, maxHp: mon.maxHp,
          });
        } else if (result.delta > 0) {
          this._emit('stat', {
            slot: fighter.slot, side: fighter.side,
            amount: mon.stats[result.stat],
            text: `${mon.species}'s ${statLabel} rose.`,
          });
        }
        // (wNameBuffer, bare: K17.)
        this._say(`${mon.species}'s\n${statLabel} rose.`);
      }
    } else if (effect.pokeFlute) {
      let woke = false;
      for (const seat of this.fighters) {
        for (const mon of seat.mons || []) {
          if (mon && mon.status === 'sleep') {
            mon.status = null;
            mon.statusTurns = 0;
            woke = true;
            this._emit('status', {
              slot: seat.slot, side: seat.side,
              text: `${mon.species} woke up!`,
            });
          }
        }
      }
      // ItemUsePokeFlute's `.inBattle`: PlayedFluteHadEffectText then
      // FluteWokeUpText, or PlayedFluteNoEffectText (data/text/text_6.asm
      // "# FLUTE", "#MON woke up.": the charmap's POKé) -- whose `para` is a
      // second line of its own (K18).
      if (woke) {
        this._say(`${fighter.name} played the\nPOKé FLUTE.`);
        this._say('All sleeping\nPOKéMON woke up.');
      } else {
        this._say('Played the POKé\nFLUTE.');
        this._say("Now, that's a\ncatchy tune!");
      }
    } else {
      const partyIdx = choice.slot != null ? choice.slot : fighter.active;
      const mon = monAt(fighter, partyIdx);
      // ItemUseNoEffect, "It won't have any effect.", for every use the
      // party menu turns down (`.healingItemNoEffect` and the PP menus').
      const NO_EFFECT = NO_EFFECT_TEXT;
      if (!mon) {
        this._say(NO_EFFECT);
      } else if (effect.activeOnly && partyIdx !== fighter.active) {
        this._say(NO_EFFECT);
      } else if (effect.faintedOnly && mon.hp > 0) {
        this._say(NO_EFFECT);
      } else if (mon.hp <= 0 && Effects.itemFailsOnFainted(effect)) {
        this._say(NO_EFFECT);
      } else {
        // `said`: a PP item's own ItemUseNoEffect line is already out, so the
        // party menu's fallback below does not print it a second time (the
        // cart's `.noEffect` prints it once).
        let applied = false;
        let said = false;
        // X ACCURACY, DIRE HIT and GUARD SPEC. set their bit and say nothing
        // past the use's line (PrintItemUseTextAndRemoveItem; the AI's
        // AIPrintItemUse).
        if (effect.xAccuracy) {
          mon.xAccuracy = true;
          applied = true;
        }
        if (effect.focusEnergy) {
          mon.focusEnergy = true;
          applied = true;
        }
        if (effect.mist) {
          mon.mist = true;
          applied = true;
        }
        if (effect.stage) {
          // ItemUseXStat / AIIncreaseStat: `_xStatItem`.
          this._xStatItem(fighter, mon, effect.stage.stat, effect.stage.delta);
          applied = true;
        }
        if (effect.revive) {
          const amount = effect.revive;
          const hp = amount === 1 ? mon.maxHp
            : Math.max(1, Math.floor(mon.maxHp * amount));
          mon.hp = hp;
          mon.status = null;
          mon.statusTurns = 0;
          this._emit('drain', {
            slot: fighter.slot, side: fighter.side,
            amount: hp, hp: mon.hp,
          });
          this._say(`${mon.species}\nis revitalized!`);
          applied = true;
        }
        // ItemUsePPRestore works on the PARTY struct (wPartyMon1Moves /
        // MON_PP, GetMaxPP over the party's own move): a TRANSFORMed
        // monster's own moves, not the copies its battle struct holds
        // (`ownMoves`). Then, for the monster out, `.afterRestoringPP` copies
        // all four party PP bytes over wBattleMonPP (`syncCopies`), so a
        // transformed monster's copies take its own moves' PP -- and a slot it
        // knows no move in, 0: a DITTO's copies 2-4 are emptied.
        const rows = ownMoves(mon);
        const syncCopies = () => {
          if (partyIdx !== fighter.active || rows === mon.moves) return;
          for (let i = 0; i < mon.moves.length; i += 1) {
            const own = rows[i];
            mon.moves[i].pp = own ? Math.max(0, int(own.pp, 0)) : 0;
            mon.moves[i].ppUps = own ? int(own.ppUps, 0) % 4 : 0;
          }
        };
        if (effect.ppRestore) {
          // ItemUsePPRestore's move menu leaves wPlayerMoveListIndex at 0 --
          // `ld a, 0 / ld [wPlayerMoveListIndex], a` after MoveSelectionMenu
          // (item_effects.asm :1981-1984) -- whatever it restored: the first
          // slot is the one a later forced or stale turn pays from (`_listIndex`).
          fighter.moveListIndex = 1;
          const move = rows[choice.move - 1];
          if (!move) {
            this._say(NO_EFFECT);
            said = true;
          } else {
            // `.restorePP` against GetMaxPP (Effects.restorePp): a slot past
            // its wrap comes down to the maximum, and a MAX ETHER on a full
            // move with PP Ups still reads as restored -- both the cart's.
            if (Effects.restorePp(move, effect.ppRestore)) {
              syncCopies();
              this._say('PP was restored.');
              applied = true;
              // Fielded mon only: a bench Ether must not redraw FIGHT.
              if (partyIdx === fighter.active) this._emitMoves(fighter, mon, partyIdx);
            } else {
              this._say(NO_EFFECT);
              said = true;
            }
          }
        }
        if (effect.ppRestoreAll) {
          let any = false;
          for (const move of rows) {
            // `.elixirLoop`: `.restorePP` on every slot that holds a move.
            if (move && Effects.restorePp(move, effect.ppRestoreAll)) any = true;
          }
          if (any) {
            syncCopies();
            this._say('PP was restored.');
            applied = true;
            if (partyIdx === fighter.active) this._emitMoves(fighter, mon, partyIdx);
          } else {
            this._say(NO_EFFECT);
            said = true;
          }
        }
        let healed = false;
        let healedBy = 0;
        if (effect.healFull) {
          const before = mon.hp;
          mon.hp = mon.maxHp;
          if (mon.hp > before) {
            this._emit('drain', {
              slot: fighter.slot, side: fighter.side,
              amount: mon.hp - before, hp: mon.hp,
            });
            healed = true;
            healedBy = mon.hp - before;
          }
        } else if (effect.heal && effect.heal > 0 && mon.hp < mon.maxHp) {
          const before = mon.hp;
          this._heal(fighter, mon, effect.heal);
          healed = true;
          healedBy = mon.hp - before;
        }
        // No item cures confusion in Red: ItemUseMedicine and AICureStatus
        // write the status byte and BADLY_POISONED, never CONFUSED.
        const wasToxic = mon.status === 'toxic';
        let cleared = false;
        if (effect.clearAllStatus) {
          if (mon.status) {
            mon.status = null;
            mon.statusTurns = 0;
            cleared = true;
          }
        } else if (effect.clearStatuses && mon.status
                   && effect.clearStatuses[mon.status]) {
          mon.status = null;
          mon.statusTurns = 0;
          cleared = true;
        }
        // The Bad Poison bit goes with a cure (ItemUseMedicine's
        // `.cureStatusAilment` -- `res BADLY_POISONED`, item_effects.asm
        // :903-905), a lingering one included. The player's FULL RESTORE that restored HP takes the
        // `.healHP` branch instead (:1152-1176), which zeroes the status byte
        // and leaves BattleStatus3 alone: a TOXIC it cured lingers.
        const healBranch = !!effect.clearAllStatus && healed;
        if (cleared) {
          if (healBranch) {
            if (wasToxic) mon.toxicLinger = true;
          } else {
            mon.toxicLinger = null;
          }
        }
        // A cure on the player's fielded monster takes ItemUseMedicine's
        // .cureStatusAilment branch, which rewrites the battle stats from the
        // party (Effects.reloadPartyStats) -- lifting the stored penalty along
        // with every badge boost. A Full Restore that also restored HP takes
        // the .healHP branch instead (item_effects.asm :1152-1176): the status
        // goes, the stats stay as they were, penalty included; only at full HP
        // does it turn into a Full Heal (:976-990). (The computer's cure,
        // AICureStatus, never touches a stat: `_aiCureStatus`.)
        if (cleared && partyIdx === fighter.active && !healBranch) {
          Effects.reloadPartyStats(mon);
        }
        if (cleared) {
          this._emit('status', {
            slot: fighter.slot, side: fighter.side,
            text: `${mon.species} recovered`,
          });
        }
        // The party menu's message for the player's medicine
        // (engine/menus/party_menu.asm): PotionText's "<MON> recovered by <N>!"
        // for HP, the cure's own line for a status (FULL RESTORE at full HP is
        // a FULL HEAL), ItemUseNoEffect's when it did nothing.
        if (healed) {
          this._say(`${mon.species}\nrecovered by ${healedBy}!`);
        } else if (cleared) {
          this._say(`${mon.species}${has(CURE_TEXT, choice.item) ? CURE_TEXT[choice.item] : CURE_TEXT.FULL_HEAL}`);
        } else if (!applied && !said) {
          this._say(NO_EFFECT);
        }
      }
    }
  }

  // An X item's stat raise: StatModifierUpEffect run on the item user's own
  // turn -- ItemUseXStat (item_effects.asm :1638-1666) for the player's,
  // AIIncreaseStat (trainer_ai.asm) for the AI's -- so an X item is a stat-up
  // move in everything but the menu: the 999 wall, the badge re-run on the user
  // and the re-penalty on the battler opposite, who has no aimed seat to be read
  // off (`_oppositeFoe`). On a raise UpdateStatDone (effects.asm :457-485)
  // plays the move struct's animation over the user -- XSTATITEM_ANIM, which
  // ItemUseXStat wrote into wPlayerMoveNum (AIIncreaseStat writes
  // XSTATITEM_DUPLICATE_ANIM, the same picture on the enemy's half; contract
  // K20 sends both as XSTATITEM_ANIM) -- and then MonsStatsRoseText,
  // "<USER>'s\n<STAT> rose!" (an UP1 effect: never "greatly"). At +6 or at
  // 999 it is PrintNothingHappenedText and no animation. Returns
  // Effects.changeStat's outcome. The one door for both seats' X items: the
  // computer's TrainerAI calls it too.
  _xStatItem(fighter, mon, stat, delta) {
    const foe = this._oppositeFoe(fighter);
    const { outcome, stage } = Effects.changeStat({
      mon, fighter, stat,
      delta: int(delta, 1),
      mover: fighter, nonMover: foe ? activeMon(foe) : null,
    });
    if (outcome === 'rose') {
      this._statusAnim(fighter, 'XSTATITEM_ANIM');
      const line = `${named(fighter, mon)}'s\n${X_STAT_LABEL[stat] || 'STAT'} rose!`;
      this._say(line);
      this._emit('stat', {
        slot: fighter.slot, side: fighter.side,
        amount: stage, stage,
        text: Events.plain(line),
      });
    } else {
      this._say('Nothing happened!');
    }
    return outcome;
  }

  // Gen1 TossBallAnimation event stream (mirror BattleState:ballChain / tossAnimFor).
  // Clients pair AnimPlayer opts.ball from the preceding `item` event's text.
  _emitBallChain(fighter, ballId, caught, shakes) {
    const slot = fighter.slot;
    const side = fighter.side;
    const toss = ballId === 'POKE_BALL' ? 'TOSS_ANIM'
      : ballId === 'GREAT_BALL' ? 'GREATTOSS_ANIM'
      : 'ULTRATOSS_ANIM';
    const anim = (text, amount) => {
      const fields = { slot, side, text };
      if (amount !== undefined) fields.amount = amount;
      this._emit('anim', fields);
    };
    anim(toss);
    anim('POOF_ANIM');
    if (!caught && !(shakes > 0)) return;
    anim('HIDEPIC_ANIM');
    anim('SHAKE_ANIM', shakes || 0);
    if (!caught) {
      anim('POOF_ANIM');
      anim('SHOWPIC_ANIM');
    }
  }

  // ------------------------------------------------------------------
  // TrainerAI (contract K16): the computer's item and switch
  // ------------------------------------------------------------------
  //
  // pokered engine/battle/trainer_ai.asm, run where MainInBattleLoop runs it
  // (core.asm :413-460): at `.enemyMovesFirst` before ExecuteEnemyMove, and
  // at `.playerMovesFirst` once the player's move and
  // HandlePoisonBurnLeechSeed are done -- never when either knocked a monster
  // out (`jp z, Handle*MonFainted` leaves first; `_resolveFights` ends the
  // slot's turn, or skips the fallen actor). `jr c, .AIActionUsed*` skips
  // ExecuteEnemyMove when the AI acted, and the enemy's
  // HandlePoisonBurnLeechSeed follows either way. So in the computer seat's
  // own slot of the order: TrainerAI, then (unless it acted) the move
  // SelectEnemyMove picked -- its priority already counted in the order --
  // then the residual. The move's forced states are not looked at: a
  // recharge, a charge, a Bide, a thrash or a monster held in a trap still
  // meets TrainerAI first, and an item spent there leaves the state for the
  // next turn, as ExecuteEnemyMove never ran.

  // Whether TrainerAI runs for this seat at all: `dec a / ret z` on
  // wIsInBattle returns for a wild monster, `cp LINK_STATE_BATTLING / ret z`
  // for a link fight -- the computer's trainer seat of a coop_npc alone.
  _runsTrainerAi(fighter) {
    return isComputerSeat(this.mode, fighter) && !Effects.isWildMode(this.mode);
  }

  // TrainerAI (trainer_ai.asm :290-320) for one seat, in its slot. wAICount
  // at 0 returns without a draw (`and a / ret z`); $ff reloads it from the
  // class record's `uses` (GenericAI's 3 without one); then `call Random` --
  // one byte, every call, GenericAI included -- and the class routine, which
  // the record describes field by field (the engine's `ai_classes`, contract
  // K16):
  //   * `switchChance`: AgathaAI's `cp 8 percent / jp c,
  //     AISwitchIfEnoughMons`, ahead of her item roll -- a switch that cannot
  //     happen does nothing else (`and a / ret`);
  //   * `onStatus`: BrockAI -- no roll read; the item while wEnemyMonStatus
  //     holds anything;
  //   * `chance`: the routine's `cp N percent / ret nc` -- the byte must be
  //     below it (CooltrainerFAI has none: her `ret nc` is commented out);
  //   * `switch`: JugglerAI's AISwitchIfEnoughMons;
  //   * `hpBelow`: AICheckIfHPBelowFraction before the item -- and below it,
  //     `switchBelow` (CooltrainerFAI's 1/5) before her switch;
  //   * otherwise the item outright (BlaineAI's SUPER POTION, at any HP).
  // A record with no item and no switch has no routine: GenericAI's `and a /
  // ret`. Returns true when the AI acted -- an item (DecrementAICount) or a
  // switch (SwitchEnemyMon's `scf`, which spends no use) -- and the slot's
  // move is skipped.
  _trainerAi(fighter, mon) {
    if (!this._runsTrainerAi(fighter)) return false;
    const cls = fighter.aiClass;
    if (int(fighter.aiCount, 0) === 0) return false;
    if (fighter.aiCount === AI_COUNT_RELOAD) {
      fighter.aiCount = cls ? cls.uses : AI_GENERIC_USES;
    }
    const roll = this.rng.byte();
    if (!cls) return false;
    if (cls.switchChance != null && roll < cls.switchChance) {
      return this._aiSwitch(fighter, mon);
    }
    if (cls.onStatus) {
      if (!mon.status) return false;
      return this._aiUseItem(fighter, mon, cls.item);
    }
    if (cls.chance != null && roll >= cls.chance) return false;
    if (cls.switch) return this._aiSwitch(fighter, mon);
    if (cls.hpBelow != null) {
      if (this._aiHpBelow(mon, cls.hpBelow)) {
        return this._aiUseItem(fighter, mon, cls.item);
      }
      if (cls.switchBelow != null && this._aiHpBelow(mon, cls.switchBelow)) {
        return this._aiSwitch(fighter, mon);
      }
      return false;
    }
    return this._aiUseItem(fighter, mon, cls.item);
  }

  // AICheckIfHPBelowFraction (trainer_ai.asm :659-683): wEnemyMonMaxHP
  // divided by `a` (a 16-bit quotient), and carry when wEnemyMonHP is below
  // it.
  _aiHpBelow(mon, divisor) {
    return mon.hp < Math.floor(mon.maxHp / Math.max(1, int(divisor, 1)));
  }

  // AISwitchIfEnoughMons (trainer_ai.asm :554-582): two or more of the party
  // standing -- the active one counted, through its party copy, which is
  // never 0 while it stands -- or nothing at all. Then SwitchEnemyMon
  // (:584-613): AIBattleWithdrawText, "<TRAINER> with-" / line "drew <MON>!"
  // -- both names bare (text_ram wTrainerName, wEnemyMonNick: K17) -- and
  // EnemySendOut, whose walk sends the first monster in party order past
  // wEnemyMonPartyPos and the fainted (`_computerChoice`'s note);
  // EnemySendOutFirstMon puts wAICount back to $ff and clears what the
  // send-out clears (`_switchIn`). `scf / ret`: the AI acted, and no use is
  // spent.
  _aiSwitch(fighter, mon) {
    let standing = 0;
    for (const each of fighter.mons) {
      if (each.hp > 0) standing += 1;
    }
    if (standing < 2) return false;
    const next = firstLiving(fighter.mons, fighter.active);
    if (!next) return false;
    this._say(`${fighter.name} with-\ndrew ${mon.species}!`);
    this._switchIn(fighter, next);
    return true;
  }

  // AICureStatus (trainer_ai.asm :625-636): the status byte zeroed in the
  // party roster and on the battler, and BADLY_POISONED reset -- and nothing
  // else: the stats keep a paralysis' quartered Speed and a burn's halved
  // Attack (ItemUseMedicine's reload is the player's alone), and the toxic
  // counter is left as it is. Whether there was anything to cure.
  _aiCureStatus(mon) {
    const had = mon.status != null;
    mon.status = null;
    mon.statusTurns = 0;
    mon.toxicLinger = null;
    return had;
  }

  // The AI's item, the routine the record names (trainer_ai.asm :463-740),
  // after the `item` event the client draws the bag's look from:
  //   * AIPrintItemUse_'s AIBattleUseItemText, "<TRAINER>" / line "used
  //     <ITEM>" / cont "on <MON>!" -- the trainer's name and wEnemyMonNick
  //     both bare (text_ram, K17), the item by its cart name;
  //   * FULL RESTORE: AICureStatus, then the HP to its maximum
  //     (AIPrintItemUseAndUpdateHPBar: the line, then the bar);
  //   * POTION / SUPER POTION / HYPER POTION: AIRecoverHP's N, held at the
  //     maximum -- at full HP too (BlaineAI never looks);
  //   * FULL HEAL: AICureStatus;
  //   * X ATTACK / DEFEND / SPEED / SPECIAL: AIIncreaseStat -- the line, then
  //     StatModifierUpEffect over the user with XSTATITEM_DUPLICATE_ANIM in
  //     the move struct (`_xStatItem`: XSTATITEM_ANIM, K20, then the rose
  //     line; at the wall "Nothing happened!");
  //   * GUARD SPEC.: PROTECTED_BY_MIST; DIRE HIT (unreferenced on the cart):
  //     GETTING_PUMPED; X ACCURACY (unreferenced): USING_X_ACCURACY -- the
  //     line alone says so;
  //   * any other id: the line, and nothing it could do.
  // Every one ends in DecrementAICount. No bag is read or spent: the class
  // record is the whole of what the trainer may use. null names no routine.
  _aiUseItem(fighter, mon, item) {
    if (item == null) return false;
    this._emit('item', { slot: fighter.slot, side: fighter.side, text: item });
    this._say(`${fighter.name}\nused ${itemLabel(item)}\non ${mon.species}!`);
    let cured = false;
    if (item === 'FULL_RESTORE') {
      cured = this._aiCureStatus(mon);
      this._heal(fighter, mon, mon.maxHp);
    } else if (has(AI_HEAL, item)) {
      this._heal(fighter, mon, AI_HEAL[item]);
    } else if (item === 'FULL_HEAL') {
      cured = this._aiCureStatus(mon);
    } else if (has(AI_X_STAT, item)) {
      this._xStatItem(fighter, mon, AI_X_STAT[item], 1);
    } else if (item === 'GUARD_SPEC') {
      mon.mist = true;
    } else if (item === 'DIRE_HIT') {
      mon.focusEnergy = true;
    } else if (item === 'X_ACCURACY') {
      mon.xAccuracy = true;
    }
    if (cured) {
      this._emit('status', {
        slot: fighter.slot, side: fighter.side,
        text: `${mon.species} recovered`,
      });
    }
    fighter.aiCount = int(fighter.aiCount, 1) - 1;
    return true;
  }

  _resolveFights() {
    // Every battler on the field takes part in MainInBattleLoop's compare
    // (core.asm :369-412), whatever its seat chose: the cart reaches
    // `.compareSpeed` -- and on a tie draws the byte -- on a turn the player
    // switched or used an item (DisplayBattleMenu has run it, and the order is
    // still asked), on a recharge, a held monster's CANNOT_MOVE, and the
    // computer's TrainerAI turn alike. So every seat with a monster out and a
    // choice is an actor in the order (`_orderActors`), at the Speed it has
    // now -- a switch-in's own, an X SPEED's raised one -- and in the bracket
    // its selection names (`_priorityOf`: a switch, an item or a run name none
    // and sit in the base one). What an actor then does in its slot:
    //   * a computer trainer's seat: TrainerAI first (`_trainerAi`), whose
    //     item or switch, when it acts, is the whole of the slot;
    //   * a fight: the move (`_useMove`);
    //   * a recharge: the gates and "must recharge" (`_rechargeTurn`);
    //   * a held monster's CANNOT_MOVE, a player's switch or item (already
    //     done before the order: `_resolveSwitches`, `_resolveItems`), a run
    //     refused: nothing -- they were in the compare and nowhere else.
    // A ball that caught, or a POKé DOLL, ended the fight inside
    // DisplayBattleMenu: the order is never asked.
    if (this.result) return;
    const actors = [];
    for (const fighter of this.fighters) {
      const choice = fighter.choice;
      const mon = activeMon(fighter);
      // A move menu writes over a CANNOT_MOVE left from an earlier turn
      // (`_selectsAnew`); nothing else does.
      if (this._selectsAnew(fighter, mon)) {
        fighter.cannotMove = null;
        // A player's MoveSelectionMenu also leaves the move under its cursor
        // in wPlayerMoveListIndex (the slot DecrementPP spends and MIMIC
        // overwrites, `_listIndex`) and, through PrintMenuItem's
        // GetCurrentMove, in the move struct COUNTER reads (`moveStruct`).
        // STRUGGLE opens no menu (AnyMoveToSelect). The computer's index is
        // `.moveChosen`'s (`_cartMovePick` -- or the slot a solo trainer's
        // brain submitted); its struct is only ever the AI's and its own move's.
        if (choice.action === 'fight' && !this._struggles(fighter, mon)
            && moveAt(mon, choice.move)) {
          fighter.moveListIndex = choice.move;
          if (isPlayerSeat(this.mode, fighter)) {
            this._loadMoveStruct(fighter, moveAt(mon, choice.move));
          }
        }
      }
      // wEnemySelectedMove / wPlayerSelectedMove for this turn, which COUNTER
      // reads off the seat it strikes (`_counterDamage`) and the bracket reads
      // (`_priorityOf`): `_selectionOf`, rewritten by `_useMove` with a move
      // its METRONOME / MIRROR MOVE called or its disobedience picked instead.
      fighter.selectedMove = mon ? this._selectionOf(fighter, mon) : null;
      if (choice && mon) {
        actors.push({
          fighter,
          mon, // pinned: see the skip in the loop
          action: choice.action,
          priority: this._priorityOf(fighter, mon),
          speed: this._speedOf(fighter, mon),
          order: actors.length + 1,
        });
      }
    }
    if (actors.length === 0) return false;

    this._orderActors(actors);

    // The end of each battler's slot is MainInBattleLoop's (core.asm
    // :413-467): HandlePoisonBurnLeechSeed, the mover's own residual, right
    // after its own Execute*Move (or the computer's TrainerAI item or switch)
    // -- unless that slot knocked the foe out, when `ld a, b / and a / jp z,
    // Handle*MonFainted` leaves for the faint's handler first and the
    // knocker-out takes no residual that turn. The residual returns z on the
    // mover's own 0 HP, so a monster its own slot or its own residual took
    // down (EXPLOSION, recoil, STRUGGLE, a crash, a confusion self-hit, the
    // poison) ends the turn there too: the slower battler never moves. In a
    // fight of one seat a side -- the cart's own shape -- any faint in a slot
    // or a residual therefore ends the turn's moves and residuals, and
    // CheckNumAttacksLeft, which only the end of both slots reaches, is
    // skipped (the return value). A 2v2 has no single foe whose faint ends
    // the turn, so it keeps the Gold referee's policy (lib/battle2/Turn.js
    // header): each seat's residual right after its own slot, in the turn's
    // order, and every seat still acts and takes its residual after a faint.
    // The residual is the seat's monster out at its slot's end: the one the
    // computer's switch just sent out, or the one a player's switch fielded
    // before the order (SendOutMon, then ExecutePlayerMove's early return).
    const single = this.bySide.a.length === 1 && this.bySide.b.length === 1;
    for (const actor of actors) {
      if (this.result) break;
      const faintsBefore = this.faints;
      // The monster that chose is the only one allowed to act: if it fainted to
      // a faster attacker, the replacement that came in behind it does not
      // inherit the turn -- nor spend the AI's item or switch for it.
      const fighter = actor.fighter;
      // Every knockout the slot deals waits for its end (`_reapKo`, K19).
      this.koHeld = true;
      if (activeMon(fighter) === actor.mon) {
        const choice = fighter.choice;
        // TrainerAI at the computer trainer's slot (`_trainerAi`): an item or
        // a switch it makes is the slot (`jr c, .AIActionUsed*`), and the move
        // SelectEnemyMove picked is never run.
        const aiActed = this._trainerAi(fighter, actor.mon);
        // ExecuteEnemyMove's `inc [hl]` on wAILayer2Encouragement (core.asm
        // :5474), past its CANNOT_MOVE return and never reached when TrainerAI
        // spent the slot: every turn the computer's monster takes its slot to
        // move -- asleep, recharging or locked in included. A byte.
        if (isComputerSeat(this.mode, fighter) && !aiActed
            && !fighter.cannotMove
            && (actor.action === 'fight'
                || (actor.action === 'skip' && choice.skip === 'recharge'))) {
          fighter.aiLayer2 = (int(fighter.aiLayer2, 0) + 1) % 256;
        }
        if (aiActed) {
          // (the slot was the AI's item or switch)
        } else if (fighter.cannotMove) {
          // Haze's CANNOT_MOVE on a target it woke or thawed (ExecutePlayerMove's
          // `inc a / jp z, ExecutePlayerMoveDone`): the turn is gone, silently
          // -- a recharge's included, and every later turn's until a move menu
          // writes a new selection (`_selectsAnew`).
        } else if (actor.action === 'fight') {
          this._useMove(fighter, actor.mon);
        } else if (actor.action === 'skip' && choice.skip === 'recharge') {
          this._rechargeTurn(fighter, actor.mon);
        }
      }
      this._reapKo();
      // Finalize after each action (not inside `_faint`) so KO + recoil / explode
      // on the same move can still mutual-faint into a draw, while an empty-bench
      // KO still stops the slower seat from acting. The action's faint batch is
      // complete here, and that is the earliest moment its spoils can be counted
      // without paying a monster the same action was still killing (`_drainExp`).
      this._drainExp();
      if (!this.result) this._checkOver();
      if (single && this.faints > faintsBefore) return true;
      if (!this.result) {
        this._residualFor(fighter);
        this._drainExp();
        if (!this.result) this._checkOver();
        if (single && this.faints > faintsBefore) return true;
      }
    }
    return false;
  }

  // A recharge turn, in the monster's own slot: CheckPlayerStatusConditions
  // runs its sleep, freeze, trapped and flinch checks first (`_firstGates`) --
  // a monster stopped by one keeps NEEDS_TO_RECHARGE, and recharges on a
  // later turn -- and then `.HyperBeamCheck` spends the bit, "<MON> must
  // recharge". A bit that something cleared before this slot (a flinch, a
  // SLEEP move, a trap starting: ClearHyperBeam) leaves nothing to say.
  _rechargeTurn(fighter, mon) {
    if (!this._firstGates(fighter, mon)) return;
    if (mon.mustRecharge) {
      mon.mustRecharge = false;
      this._say(`${named(fighter, mon)}\nmust recharge!`);
    }
  }

  // Whether `move` is the one Disable holds. TriedToUseDisabledMoveCheck
  // (core.asm :3438-3447) compares wPlayerDisabledMoveNumber -- the move's id,
  // kept from when it was disabled -- with wPlayerSelectedMove, so a forced
  // replay of the same move (a called THRASH, a charge's release) is caught
  // too, and STRUGGLE never is.
  _isDisabledMove(mon, move) {
    const d = mon.disable;
    if (!d || int(d.turns, 0) <= 0 || !move || typeof move !== 'object' || move === STRUGGLE) {
      return false;
    }
    let id = d.moveId === undefined ? null : d.moveId;
    if (id === null) {
      const slotMove = mon.moves[d.moveIndex - 1];
      id = slotMove ? slotMove.id : null;
    }
    return id !== null && id !== undefined && move.id === id;
  }

  // `.MonHurtItselfOrFullyParalysed` (core.asm :3459-3474) on a full
  // paralysis: Bide, the thrash, the charge and the trap the monster held all
  // go (`and ~(STORING_ENERGY | THRASHING_ABOUT | CHARGING_UP |
  // USING_TRAPPING_MOVE)`) -- and INVULNERABLE stays, so a FLY or DIG user
  // paralysed on its release turn hangs out of reach until it switches out or
  // flies again: the cart's glitch, kept.
  _paralysisClears(fighter, mon) {
    mon.bide = null;
    mon.thrashing = null;
    mon.charging = null;
    this._dropTrap(fighter, mon);
  }

  // The trap this monster holds ends, and the one it held goes free.
  _dropTrap(fighter, mon) {
    if (mon.trapping) {
      const held = this._fighterAtSlot(mon.trapping.targetSlot);
      const heldMon = held ? activeMon(held) : null;
      if (heldMon && heldMon.trapped && heldMon.trapped.fromSlot === fighter.slot) {
        heldMon.trapped = null;
      }
      mon.trapping = null;
    }
  }

  // The seat and monster whose trap holds this one, or null. On the cart the
  // trap is the trapper's alone -- USING_TRAPPING_MOVE and its counter in the
  // trapper's battle struct; the held monster has no bit of its own, it is
  // "the enemy" of a trapper (HeldInPlaceCheck reads wEnemyBattleStatus1, and
  // MainInBattleLoop / SelectEnemyMove the other side's bit) -- so a hold is
  // real only while the seat it names still fields a monster trapping this
  // slot. A `trapped` record without one (a sheet's, or one a send-out
  // orphaned) holds nothing, and `_checkNumAttacksLeft` clears it.
  _trapperOf(fighter, mon) {
    const held = mon ? mon.trapped : null;
    if (!held || held.fromSlot === null || held.fromSlot === undefined) return null;
    const seat = this._fighterAtSlot(held.fromSlot);
    const trapperMon = seat ? activeMon(seat) : null;
    if (trapperMon && trapperMon.trapping
        && trapperMon.trapping.targetSlot === fighter.slot) {
      return { seat, mon: trapperMon };
    }
    return null;
  }

  _isHeld(fighter, mon) {
    return this._trapperOf(fighter, mon) !== null;
  }

  // CheckNumAttacksLeft (core.asm :683-697), after the turn's moves and
  // residuals: a trapper whose counter `.MultiturnMoveCheck` took to 0 lets
  // go now -- not on the hit that spent it, so the monster it held stays held
  // for the rest of that turn -- and a hold whose trapper is gone is let go
  // too.
  _checkNumAttacksLeft() {
    for (const fighter of this.fighters) {
      const mon = activeMon(fighter);
      if (mon && mon.trapping && int(mon.trapping.turns, 0) <= 0) {
        this._dropTrap(fighter, mon);
      }
    }
    for (const fighter of this.fighters) {
      const mon = activeMon(fighter);
      if (mon && mon.trapped && !this._isHeld(fighter, mon)) {
        mon.trapped = null;
      }
    }
  }

  // CheckPlayerStatusConditions up to `.HyperBeamCheck` (core.asm
  // :3328-3383) -- the part every turn of a monster on the field meets, a
  // recharge's too:
  //   * sleep (`.sleepDone`): the counter comes down a step and the turn is
  //     gone, "<MON> is fast asleep" or "woke up" -- the waking turn is lost
  //     too;
  //   * freeze (`.FrozenCheck`): "<MON> is frozen solid";
  //   * `.HeldInPlaceCheck`: a foe's trap holds it -- "<MON> can't move". The
  //     monster that chose CANNOT_MOVE never gets here (`_fillForcedChoices`);
  //     this is the one that chose before the trap began -- slower than the
  //     trapper on the trap's first turn -- or a forced turn (a recharge,
  //     Rage, a thrash, a charge, a Bide) the trap caught: none of their
  //     counters moves;
  //   * the flinch (`.FlinchedCheck`), which spends the bit.
  // Neither sleep nor freeze reads a byte (neither check calls BattleRandom),
  // and both zero wPlayerUsedMove / wEnemyUsedMove (`.sleepDone`,
  // `.FrozenCheck`), so MIRROR MOVE finds nothing to copy. Returns false when
  // one of them stopped the monster.
  _firstGates(fighter, mon) {
    if (mon.status === 'sleep' || mon.status === 'freeze') {
      const gate = Status.beforeMove(
        { status: mon.status, turnsRemaining: mon.statusTurns }, null,
      );
      if (gate) {
        mon.statusTurns = int(gate.turnsRemaining, mon.statusTurns);
        if (gate.wokeUp) {
          mon.status = null;
          mon.statusTurns = 0;
          // WokeUpText (core.asm :3346-3347), the line; the chip's cure rides
          // the `status` event.
          this._say(`${named(fighter, mon)}\nwoke up!`);
          this._emit('status', {
            slot: fighter.slot, side: fighter.side,
            text: `${mon.species} woke up!`,
          });
        } else if (mon.status === 'sleep') {
          // The sleeping monster's animation: SLP_PLAYER_ANIM ahead of
          // FastAsleepText on the player's turn (core.asm :3339-3344),
          // SLP_ANIM behind it on the enemy's (:5686-5691).
          const player = isPlayerSeat(this.mode, fighter);
          if (player) this._statusAnim(fighter, 'SLP_PLAYER_ANIM');
          this._say(`${named(fighter, mon)}\nis fast asleep!`);
          if (!player) this._statusAnim(fighter, 'SLP_ANIM');
        } else if (mon.status === 'freeze') {
          this._say(`${named(fighter, mon)}\nis frozen solid!`);
        }
        if (!gate.canMove) {
          mon.lastUsedMove = null;
          return false;
        }
      }
    }

    if (this._isHeld(fighter, mon)) {
      this._say(`${named(fighter, mon)}\ncan't move!`);
      return false;
    }

    if (mon.flinch) {
      mon.flinch = false;
      this._say(`${named(fighter, mon)}\nflinched!`);
      return false;
    }
    return true;
  }

  // CheckPlayerStatusConditions (core.asm :3328-3573), in its order: sleep,
  // freeze, held by a foe's trap, flinch [the recharge: `_rechargeTurn`], the
  // Disable step, confusion, the disabled move, paralysis. So a sleeping or
  // frozen monster's flinch is never reached (the bit waits for the turn's
  // reset), and confusion rolls before paralysis. `move` is the selected move
  // (the disabled-move check's). Returns false when a gate stopped the move.
  _runGates(fighter, mon, move) {
    if (!this._firstGates(fighter, mon)) return false;

    this._tickDisable(fighter, mon);

    if (mon.confusion > 0) {
      const hit = this._selfHitState(fighter, mon);
      // `.ConfusedCheck` takes the counter down first (`dec [hl] / jr nz`),
      // and only a monster still confused after it draws the self-hit byte:
      // the turn it snaps out on draws none. `.IsConfused` prints
      // IsConfusedText, "<MON> is confused!", every such turn, ahead of the
      // byte (core.asm :3418-3424), whether or not it then hurts itself.
      let roll = null;
      if (mon.confusion > 1) {
        this._say(`${named(fighter, mon)}\nis confused!`);
        // CONF_PLAYER_ANIM / CONF_ANIM behind IsConfusedText, before the
        // byte, on either side's turn (core.asm :3422-3426, :5762-5767).
        this._statusAnim(fighter, isPlayerSeat(this.mode, fighter)
          ? 'CONF_PLAYER_ANIM' : 'CONF_ANIM');
        roll = this.rng.byte();
      }
      const gate = Status.beforeMove({
        status: 'confusion',
        turnsRemaining: mon.confusion,
        level: hit.level,
        attack: hit.attack,
        defense: hit.defense,
      }, roll);
      if (gate) {
        mon.confusion = int(gate.turnsRemaining, 0);
        if (gate.snappedOut) {
          this._say(`${named(fighter, mon)}'s\nconfused no more!`);
          this._emit('status', {
            slot: fighter.slot, side: fighter.side, confused: 0,
            text: `${mon.species}'s confused no more!`,
          });
        } else if (gate.selfHit) {
          this._selfHitClears(fighter, mon);
          this._say(HURT_ITSELF_TEXT);
          this._selfHit(fighter, mon, gate.selfDamage || 0);
          // `.MonHurtItselfOrFullyParalysed`, after HandleSelfConfusionDamage.
          this._flyOrChargeAnim(fighter, fighter.moveStruct ? fighter.moveStruct.effect : undefined);
          return false;
        }
        if (!gate.canMove) return false;
      }
    }

    if (this._isDisabledMove(mon, move)) {
      // MoveIsDisabledText, "<USER>'s\n<MOVE> is\ndisabled!".
      this._say(`${named(fighter, mon)}'s\n${moveLabel(move)} is\ndisabled!`);
      return false;
    }

    if (mon.status === 'paralysis') {
      const gate = Status.beforeMove({ status: 'paralysis' }, this.rng.byte());
      if (gate && gate.fullyParalyzed) {
        this._say(`${named(fighter, mon)}'s\nfully paralyzed!`);
        this._paralysisClears(fighter, mon);
        this._flyOrChargeAnim(fighter, fighter.moveStruct ? fighter.moveStruct.effect : undefined);
        return false;
      }
    }

    return true;
  }

  // `.IsConfused` on a self-hit (core.asm :3420-3434): `and 1 << CONFUSED`
  // keeps the confusion and clears every other wPlayerBattleStatus1 bit
  // before HandleSelfConfusionDamage runs -- STORING_ENERGY (a Bide),
  // THRASHING_ABOUT, ATTACKING_MULTIPLE_TIMES, FLINCHED, CHARGING_UP,
  // USING_TRAPPING_MOVE and INVULNERABLE. So a confused monster that hurts
  // itself loses the Bide it was storing, the thrash it was in (no confusion
  // at its end, since it never ends), the charge it was about to release (and
  // the FLY / DIG vanish with it), and the trap it held, which frees the
  // monster it held. Rage is a wPlayerBattleStatus2 bit and stays. The
  // disobedience self-hit (CheckForDisobedience `.monHurtsItself`) calls
  // HandleSelfConfusionDamage directly and clears nothing.
  _selfHitClears(fighter, mon) {
    mon.bide = null;
    mon.thrashing = null;
    mon.flinch = false;
    mon.charging = null;
    mon.invulnerable = false;
    this._dropTrap(fighter, mon);
  }

  // Where a self-hit's damage goes (both callers: the confusion gate above and
  // the disobedient "won't obey"). HandleSelfConfusionDamage ends on
  // ApplyDamageToPlayerPokemon (core.asm :3714; the enemy's mirror, :5814),
  // and that routine's Substitute branch jumps to AttackSubstitute, which
  // picks the doll by hWhoseTurn -- the turn is the self-hitter's, so the doll
  // it picks is the OTHER side's ("damage will be applied to the other
  // player's Substitute", AttackSubstitute's own header, :4849-4856). A
  // monster behind its own doll therefore takes nothing and the opposing doll
  // takes the hit: it holds or breaks as under any attack. With no doll
  // across, the cart subtracts from the other side's stale doll byte, which
  // no field shows and the referee does not keep -- so nothing moves. Gen 1
  // has one opponent; in a 2v2 it is the battler opposite (`_oppositeFoe`),
  // the same battler whose Reflect the self-hit borrows. wDamage keeps the
  // self-hit's number either way (CalculateDamage wrote it; the doll never
  // rewrites it).
  _selfHit(fighter, mon, amount) {
    if (Effects.hasSubstitute(mon)) {
      const opposite = this._oppositeFoe(fighter);
      const foe = opposite ? activeMon(opposite) : null;
      if (foe && Effects.hasSubstitute(foe)) {
        this.lastDamage = this._damage(opposite, foe, amount, null);
      } else {
        this.lastDamage = Math.max(0, int(amount, 0));
      }
      return;
    }
    this.lastDamage = this._damage(fighter, mon, amount, null);
  }

  // What HandleSelfConfusionDamage hits with (core.asm :3672-3710), for both of
  // its callers: the confusion gate above and a disobedient "won't obey". It
  // reads the battle stats as stored: it puts wBattleMon's own Defense in the
  // enemy's slot and runs GetDamageVarsForPlayerAttack, so the Attack and
  // Defense are wBattleMon's -- stages, badges and a stored burn all in them
  // -- through the same scaling and 997 cap as any hit, with no crit and no
  // random factor (Status.selfHitDamage's fixed max roll). And the Reflect
  // check in there still reads the ENEMY's status byte, so it is the
  // opponent's Reflect that doubles the monster's own Defense -- the cart's
  // quirk, kept. Gen 1 has one opponent; in a 2v2 it is the battler opposite
  // (`_oppositeFoe`). The enemy's own self-hit is the mirror image
  // (:5774-5805), so this is both seats' rule.
  _selfHitState(fighter, mon) {
    const opposite = this._oppositeFoe(fighter);
    const opposed = opposite ? activeMon(opposite) : null;
    let defense = mon.cur.def;
    if (opposed && opposed.reflect) defense *= 2;
    return { level: mon.level, attack: mon.cur.atk, defense };
  }

  // CheckForDisobedience (core.asm :3830-4007), where ExecutePlayerMove calls
  // it: after the status gates and the disabled-move check, before anything
  // about the move itself. Only a `badgeRules` seat's traded monster gets here
  // (the caller's gate). Returns { goes: true } when the move goes ahead --
  // with `instead`, the slot of the move used instead, when the monster picked
  // its own (`.useRandomMove`) -- and { goes: false } when the turn is spent:
  //
  //   * "nap": `.monNaps` writes SLP and the 1..7 counter over the whole
  //     status byte -- a burn, a poison or a paralysis is simply gone -- and
  //     touches no stat, so a stored burn or paralysis penalty stays in the
  //     battle stats (nothing recomputes them; ItemUseMedicine is the only
  //     cure that does). The badly-poisoned flag lives in another byte on the
  //     cart and outlives the nap there; so it does here, as `toxicLinger`.
  //   * "selfhit": "won't obey!", then HandleSelfConfusionDamage itself --
  //     "hurt itself", the same stored-stat hit and borrowed Reflect as
  //     confusion's (`_selfHitState`).
  //   * "nothing": one of the four `.monDoesNothing` lines.
  //   * "random" with every `.useRandomMove` refusal hit falls to "nothing".
  _obey(fighter, mon, struggling) {
    const choice = fighter.choice;
    let verdict = Status.obedienceRoll(mon.level,
      Status.obedienceCap(fighter.badges), this.rng);
    if (verdict === 'obeys') return { goes: true, instead: null };
    if (verdict === 'random') {
      const disabled = !!(mon.disable && mon.disable.turns > 0);
      const slot = Status.disobedientMove(mon.moves, choice.move, disabled,
        struggling, this.rng);
      if (slot) return { goes: true, instead: slot };
      verdict = 'nothing';
    }

    if (verdict === 'nap') {
      // The badly-poisoned flag is BattleStatus3's, not the status byte's, so
      // it outlives the nap (`toxicLinger`): the counter keeps climbing under
      // a Leech Seed, and a later poison or burn ticks at the toxic rate
      // (`_residualFor`).
      if (mon.status === 'toxic') mon.toxicLinger = true;
      mon.status = 'sleep';
      mon.statusTurns = Status.napTurns(this.rng);
      // BeganToNapText over wBattleMonNick: bare (K17), "<MON> began\nto nap!".
      const text = `${mon.species} began\nto nap!`;
      this._say(text);
      this._emit('status', {
        slot: fighter.slot, side: fighter.side, status: STATUS_TO_WIRE.sleep,
        text: Events.plain(text),
      });
      return { goes: false, instead: null };
    }

    if (verdict === 'selfhit') {
      this._say(`${mon.species}${LOAF_TEXT.wont_obey}`);
      this._say(HURT_ITSELF_TEXT);
      this._selfHit(fighter, mon, Status.selfHitDamage(this._selfHitState(fighter, mon)));
      return { goes: false, instead: null };
    }

    this._say(`${mon.species}${LOAF_TEXT[Status.loafLine(this.rng)]}`);
    return { goes: false, instead: null };
  }

  // Every standing battler, { fighter, mon }, in field order: what HAZE
  // reaches -- the cart's two, all four of a 2v2.
  _standingField() {
    const field = [];
    for (const seat of this.fighters) {
      const standing = activeMon(seat);
      if (standing) field.push({ fighter: seat, mon: standing });
    }
    return field;
  }

  _applyPrimary(fighter, mon, targetFighter, targetMon, moveIndex, effectId, moveId, extra) {
    const x = extra || {};
    const result = Effects.applyPrimary({
      effectId,
      overwrite: x.overwrite === true,
      mimicSlot: x.mimicSlot,
      rng: this.rng,
      userMon: mon,
      targetMon,
      userFighter: fighter,
      targetFighter,
      moveIndex,
      moveId,
      field: this._standingField(),
      playerMover: isPlayerSeat(this.mode, fighter),
      unlimitedPp: isComputerSeat(this.mode, targetFighter),
      statusToWire: STATUS_TO_WIRE,
    });
    // Haze's CANNOT_MOVE: the target loses a move it has not used yet, and
    // its selection is gone with it (COUNTER reads nothing there).
    if (result.cannotMove) {
      targetFighter.cannotMove = true;
      targetFighter.selectedMove = null;
    }
    if (result.nothing) this._say('But nothing happened');
    for (const text of result.messages || []) this._say(text);
    for (const entry of result.events || []) {
      this._emit(entry.kind, entry.fields);
    }
    for (const heal of result.heals || []) {
      this._heal(fighter, mon, heal.amount);
    }
    for (const text of result.afterHeals || []) this._say(text);
    for (const cost of result.costs || []) {
      this._damage(fighter, mon, cost.amount, null);
    }
    for (const hit of result.directDamage || []) {
      this._emit('damage', {
        slot: fighter.slot,
        side: fighter.side,
        amount: hit.amount,
        hp: mon.hp,
      });
    }
    if (result.movesChanged) this._emitMoves(fighter, mon);
    // Whether the routine played the move's animation (Effects.applyPrimary's
    // `animates`): `_statusMove` takes the `anim` back when it did not.
    return result.animates === true;
  }

  // The move's side effect, after its last hit. `move` is the sheet move that
  // landed: its `chance` (an explicit override, or 0 for the cart's own odds)
  // and its type (FreezeBurnParalyzeEffect's same-type return, CheckDefrost's
  // Fire test) go to Effects.applySide with the two named types and whether
  // the move is the computer's -- StatModifierDownEffect draws its extra miss
  // on the enemy's turn outside a link battle, the seat isComputerSeat names
  // -- or the player's (a freeze clears the target's recharge only then,
  // isPlayerSeat).
  _applySide(fighter, mon, targetFighter, targetMon, effectId, move) {
    const result = Effects.applySide({
      effectId,
      chance: move.chance,
      moveType: move.type,
      poisonType: this.poisonType,
      fireType: this.fireType,
      computerMover: isComputerSeat(this.mode, fighter),
      playerMover: isPlayerSeat(this.mode, fighter),
      rng: this.rng,
      userMon: mon,
      targetMon,
      userFighter: fighter,
      targetFighter,
      statusToWire: STATUS_TO_WIRE,
    });
    // The routine's shake ahead of its line (Effects.applySide's `shake`):
    // ENEMY_HUD_SHAKE_ANIM is the target's HUD shaking, SHAKE_SCREEN_ANIM the
    // whole screen, both sent on the seat the status landed on.
    if (result.shake) this._statusAnim(targetFighter, result.shake);
    for (const text of result.messages || []) this._say(text);
    for (const entry of result.events || []) {
      this._emit(entry.kind, entry.fields);
    }
  }

  _markLastMove(mon, moveIndex) {
    if (moveIndex && moveIndex >= 1) mon.lastMoveIndex = moveIndex;
  }

  // wPlayerMoveListIndex / wEnemyMoveListIndex, 1-based: the slot the last
  // move menu (or `.moveChosen`) named (`_resolveFights`, `_cartMovePick`),
  // rewritten to the first by a player's TRANSFORM and a PP-restoring item's
  // menu, and never by a forced turn -- so a released trap's fresh run, a
  // stale selection and a disobedient monster's instead-move all pay from it.
  // The seat's own choice before any menu has named one.
  _listIndex(fighter, choice) {
    if (fighter.moveListIndex !== undefined && fighter.moveListIndex !== null) {
      return fighter.moveListIndex;
    }
    if (choice && choice.move !== undefined && choice.move !== null) return choice.move;
    return 1;
  }

  // The move struct COUNTER reads off the seat it strikes (wPlayerMoveNum ..
  // wPlayerMoveMaxPP / the enemy's): power and type of the move GetCurrentMove,
  // ReloadMoveData or the trainer AI's ReadMove last copied there -- and its
  // effect, which a gate's STATUS_AFFECTED_ANIM reads (`_flyOrChargeAnim`). One per
  // seat, as the cart keeps one per side; nothing clears it (a send-out zeroes
  // the number byte alone, which COUNTER never reads).
  _loadMoveStruct(fighter, move) {
    if (!move || typeof move !== 'object') return;
    fighter.moveStruct = { power: int(move.power, 0), type: int(move.type, 0),
      effect: int(move.effect, 0) };
  }

  // DecrementPP (engine/battle/decrement_pp.asm) on the list index's slot of the
  // battle struct, which is the party's own while the monster is itself; a
  // TRANSFORMed one's party copy is left alone (`ret nz` on TRANSFORMED) -- the
  // copies are the battle struct's alone (`preTransform` keeps the party's).
  _decrementPp(mon, index) {
    const move = moveAt(mon, index);
    if (move) stepPp(move, -1);
  }

  // IncrementMovePP (core.asm :5039-5066), ReloadMoveData's: the list index's
  // slot in the battle struct AND in the party struct, the latter even while
  // TRANSFORMed -- so a transformed monster's own move in that slot gains a PP
  // (`preTransform`) that DecrementPP never takes back. Either side's.
  _incrementPp(fighter, mon, index) {
    const move = moveAt(mon, index);
    if (move) stepPp(move, 1);
    const saved = mon.transformed ? mon.preTransform : null;
    const ownMove = saved && Array.isArray(saved.moves) ? moveAt(saved, index) : null;
    if (ownMove) stepPp(ownMove, 1);
  }

  // ExplodeEffect zeroes the user's HP word itself -- never its own doll.
  _faintUser(fighter, mon) {
    if (mon.hp > 0) this._damage(fighter, mon, mon.hp, null, true);
  }

  // The knockouts an action left, fainted where MainInBattleLoop looks for
  // them (contract K19): `ld a, b / and a / jp z, HandleEnemyMonFainted` -- or
  // HandlePlayerMonFainted -- once ExecutePlayerMove / ExecuteEnemyMove has
  // returned (core.asm :413-467), so after the move's whole tail: the drain,
  // the recoil, the Pay Day line, the hit count, the target's Rage, the side
  // effect, and an EXPLOSION's user taken to 0 (ExplodeEffect zeroes it among
  // the AlwaysHappen routines, without a word). Until then a monster at 0 HP
  // stays on the field, `activeMon` reading it as gone. Two at once -- a
  // knockout and the recoil or blast that took the user with it -- go in the
  // cart's order against the computer, the player's first: HandleEnemyMonFainted's
  // FaintEnemyPokemon calls RemoveFaintedPlayerMon (:806) before it prints the
  // enemy's line and writes wBattleResult 0 (:812-818), and HandlePlayerMonFainted
  // removes the player's (:969-972) before it reads the enemy's HP. So side a,
  // then side b, each in field order; a link fight -- whose consoles each put
  // their own first -- takes the same order. A residual's knockout keeps its
  // own point (`_residualFor`): this runs at the end of the slot, before it.
  _reapKo() {
    this.koHeld = null;
    for (const side of SIDES) {
      for (const fighter of this.bySide[side]) {
        const mon = fighter.active ? monAt(fighter, fighter.active) : null;
        if (mon && mon.hp <= 0) this._faint(fighter, mon);
      }
    }
  }

  // An Explosion / Self-Destruct that did not land. EXPLODE_EFFECT is the one
  // miss ExecutePlayerMove lets on to `.notDone` (core.asm :3222-3225; the
  // enemy's `.handleExplosionMiss`, :5622-5624), so the user still goes down
  // and HandleBuildingRage still runs on the target it missed -- which is
  // alive, so `ret z` lets it through. The rage is built before the faint the
  // cart only announces after the move, and the re-penalty it gives the
  // exploder is then wiped with the rest of its battle stats.
  _explodeMissed(fighter, mon, target, defender) {
    this._buildRage(target, defender, fighter);
    this._faintUser(fighter, mon);
  }

  // A move that did not land, after the caller has said why: MoveHitTest's
  // `.moveMissed` (core.asm :5328-5332) zeroes wDamage, as
  // AdjustDamageForMoveType's 0 does; an EXPLOSION still goes down
  // (`_explodeMissed`) and a JUMP KICK crashes. PrintMoveFailureText
  // (:3718-3768) takes the crash off a wDamage that is always 0 by then, so it
  // is 1 HP, and it goes through ApplyDamageToPlayerPokemon -- whose
  // Substitute branch, on the crasher's own turn, hits the OTHER side's doll
  // (AttackSubstitute) -- the self-hit's route (`_selfHit`).
  _moveMissed(fighter, mon, target, defender, effectId, usedSlot) {
    this.lastDamage = 0;
    // HandleIfPlayerMoveMissed (core.asm :3150-3156): "don't play any
    // animation if the move missed, unless it was EXPLODE_EFFECT" -- and a
    // power-0 routine's miss never reaches its own animation (K22's audit).
    if (!Effects.isExplode(effectId)) this._dropMoveAnim();
    if (Effects.isExplode(effectId)) this._explodeMissed(fighter, mon, target, defender);
    if (Effects.isJumpKick(effectId)) {
      this._say(`${named(fighter, mon)}\nkept going and\ncrashed!`);
      this._selfHit(fighter, mon, Effects.jumpKickCrash(this.lastDamage));
    }
    this._markLastMove(mon, usedSlot);
  }

  // What PrintMoveFailureText (core.asm :3718-3735) says for a damaging move
  // that missed, whichever test it was: wDamageMultipliers at 0 -- an
  // immunity -- is "It doesn't affect <TARGET>!"; else an OHKO's $ff in
  // wCriticalHitOrOHKO (a target faster than the user) is "<TARGET>'s
  // unaffected!"; else "<USER>'s attack missed!" -- the accuracy byte, DREAM
  // EATER's sleep check, an invulnerable or a Misted target, a 0.25x zero
  // all alike. With the cart's marks and breaks (K17 / K18):
  // DoesntAffectMonText, UnaffectedText, AttackMissedText.
  _damageMissText(fighter, mon, target, defender, immune, ohko) {
    if (immune) return `It doesn't affect\n${named(target, defender)}!`;
    if (ohko) return `${named(target, defender)}'s\nunaffected!`;
    return `${named(fighter, mon)}'s\nattack missed!`;
  }

  // MoveHitTest (core.asm :5228-5345) for a move that reaches it, in its
  // order: DREAM EATER against a target that is not asleep misses first
  // (`.dreamEaterCheck`), then an invulnerable target misses (bar SWIFT,
  // whose `ret z` comes first, Effects.hitsInvulnerable), a primary stat drop
  // into Mist misses, X Accuracy hits without drawing (`ret nz`), and only
  // then is the accuracy byte drawn. None of the four before it draws.
  // Returns { hit: true }, or { hit: false, why } with why 'dreameater',
  // 'invulnerable', 'mist' or 'accuracy'.
  _hitTest(mon, defender, move, effectId) {
    if (int(effectId, 0) === 8 && defender.status !== 'sleep') {
      return { hit: false, why: 'dreameater' };
    }
    if (defender.invulnerable) {
      let chargeMoveId = defender.charging ? defender.charging.moveId : null;
      if (!chargeMoveId && defender.charging) {
        const charged = defender.moves ? defender.moves[defender.charging.moveIndex - 1] : null;
        chargeMoveId = charged ? charged.id : null;
      }
      if (!Effects.hitsInvulnerable(chargeMoveId, move)) return { hit: false, why: 'invulnerable' };
    }
    if (Effects.mistBlocks(effectId, defender)) return { hit: false, why: 'mist' };
    if (Effects.isSwift(effectId) || mon.xAccuracy === true) return { hit: true, why: null };
    // CalcHitChance (core.asm :5348-5414) reads the target's evasion through
    // `c = 14 - EVASIONMOD`: the stage reflected over neutral, so a raised
    // evasion takes the lowered ratio (+1 reads 66/100) and a lowered one the
    // raised ratio -- an evasion boost makes the move miss more, not less.
    const shot = Accuracy.hit({
      accuracy: move.accuracy,
      roll: this.rng.byte(),
      accuracyMod: Effects.stageMult(mon.stages.acc),
      evasionMod: Effects.stageMult(-Effects.clampStage(defender.stages.eva)),
    });
    if (!shot.hit) return { hit: false, why: 'accuracy' };
    return { hit: true, why: null };
  }

  // HandleCounterMove (core.asm :4547-4610): COUNTER's damage, or null for a
  // miss. It reads the seat it strikes -- the one opponent on the cart, the
  // target here -- through two different things, and wDamage (`lastDamage`):
  //   * wEnemySelectedMove (`selectedMove`, `_resolveFights`): a target whose
  //     selection is COUNTER makes it miss. CANNOT_MOVE ($ff, a held or a
  //     Hazed seat: null) is not COUNTER, and neither is the nothing a player's
  //     switch, item or run named;
  //   * the target's move struct, wEnemyMovePower / wEnemyMoveType
  //     (`moveStruct`): power 0, or a type neither Normal nor Fighting, makes
  //     it miss. The struct is whatever was last copied there -- the move
  //     the target used this turn when it got past its gates, else an older
  //     one: last turn's, the one its player's move menu last pointed at, the
  //     last move a trainer AI layer read (`_aiTrainerMoves`), a Bide's power
  //     of 1 -- so a target that never moved this turn (held, fully
  //     paralysed, asleep, switched) is countered off that. Nothing loaded
  //     yet is power 0;
  //   * so does a wDamage of 0. wDamage is one word both sides share and
  //     nothing resets between turns, so it is the LAST damage anyone dealt
  //     -- usually the target's hit this turn, but a miss zeroed it and it may
  //     be the COUNTER user's own (the cart's comment says as much);
  //   * otherwise the damage is wDamage doubled, held at $ffff. It is not
  //     typed (it reaches a Ghost) and not rolled, and a hit test follows.
  _counterDamage(target) {
    if (!target) return null;
    const selected = target.selectedMove;
    if (selected && typeof selected === 'object' && Effects.isCounter(selected)) return null;
    const struct = target.moveStruct;
    if (!struct || typeof struct !== 'object' || int(struct.power, 0) <= 0) return null;
    const moveType = int(struct.type, -1);
    if (moveType !== this.normalType && moveType !== this.fightingType) return null;
    if (this.lastDamage <= 0) return null;
    return Math.min(65535, this.lastDamage * 2);
  }

  // A TELEPORT, ROAR or WHIRLWIND that ends a wild fight: either side's
  // (SwitchAndTeleportEffect sets wEscapedFromBattle and never writes
  // wBattleResult), so EndOfBattle pays the Pay Day pile while that is still
  // 0 (`_payDayOn`). `fighter` is the seat that LEAVES -- the `run` event's
  // and the outcome's runner: TELEPORT's user ("<USER> ran from battle!"),
  // ROAR's and WHIRLWIND's target ("<TARGET> ran away scared!" / "was blown
  // away!"), so the player's WHIRLWIND sends the wild monster off and the
  // wild ROAR sends the player's (`_switchAndTeleport`).
  _concedeRun(fighter) {
    this._emit('run', { slot: fighter.slot, side: fighter.side, text: fighter.name });
    let result;
    if (fighter.side === 'a') {
      result = this._finish('win', this._sidePlayers('b'), this._sidePlayers('a'), 'run');
    } else {
      result = this._finish('win', this._sidePlayers('a'), this._sidePlayers('b'), 'run');
    }
    this._payDayOn(result);
  }

  // SwitchAndTeleportEffect (effects.asm :810-911), either side's. Outside a
  // wild fight (wIsInBattle 2: a trainer or a link fight) it fails: TELEPORT
  // "But it failed!", ROAR / WHIRLWIND "<TARGET> is unaffected!". In one, the
  // level roll (Effects.teleportEscapes) -- a user at or above its target's
  // level always escapes -- and a roll that fails is TELEPORT's "But it
  // failed!" or the others' "It didn't affect <TARGET>!". An escape sets
  // wEscapedFromBattle and says TELEPORT's "<USER> ran from battle!", ROAR's
  // "<TARGET> ran away scared!" or WHIRLWIND's "<TARGET> was blown away!"
  // (`.playAnimAndPrintText`, keyed by the move id), and the fight is over
  // (`_concedeRun`, whose runner is TELEPORT's user and the others' target).
  // "Its target" is the monster the move was aimed at -- the cart's one
  // opponent -- on the seat `target`. Returns whether it escaped -- the one
  // outcome `.playAnimAndPrintText` animates.
  _switchAndTeleport(fighter, mon, target, defender, move) {
    const key = Effects.moveKey(move);
    const teleport = key === 'TELEPORT';
    if (!Effects.teleportRunAllowed(this.mode)) {
      if (teleport) {
        this._say('But, it failed!');
      } else {
        this._say(`${named(target, defender)}\nis unaffected!`);
      }
      return false;
    }
    if (!Effects.teleportEscapes(mon.level, defender.level, this.rng)) {
      if (teleport) {
        this._say('But, it failed!');
      } else {
        this._say(`It didn't affect\n${named(target, defender)}!`);
      }
      return false;
    }
    if (teleport) {
      this._say(`${named(fighter, mon)}\nran from battle!`);
    } else if (key === 'ROAR') {
      this._say(`${named(target, defender)}\nran away scared!`);
    } else {
      this._say(`${named(target, defender)}\nwas blown away!`);
    }
    this._concedeRun(teleport ? fighter : target);
    return true;
  }

  // MimicEffect's pick (effects.asm :1210-1259): the slot of the target's
  // move list it copies, 1-based. Outside a link battle the player's turn
  // opens that list (`.letPlayerChooseMove`): the seat's own pick
  // (`choice.mimic`, `_normaliseChoice`), and with none -- or one naming no
  // move the target holds now -- the row the menu's cursor starts on, the
  // first (`.selectedmoveknown`). The computer's turn, and both sides of a
  // link fight, take `.getRandomMove`: `BattleRandom & 3`, redrawn until the
  // slot holds a move. A target with no moves would spin the cart forever;
  // the referee fails it there, with no draw.
  _mimicPick(fighter, defender, choice) {
    const moves = Array.isArray(defender.moves) ? defender.moves : [];
    if (moves.length === 0) return null;
    if (isPlayerSeat(this.mode, fighter) && has(BADGE_MODES, this.mode)) {
      const pick = int(choice ? choice.mimic : null, null);
      if (pick !== null && pick >= 1 && moves[pick - 1] !== undefined) return pick;
      return 1;
    }
    for (let i = 0; i < Effects.REDRAW_GUARD; i += 1) {
      const slot = this.rng.byte() % 4 + 1;
      if (moves[slot - 1] !== undefined) return slot;
    }
    return 1;
  }

  // The stat a critical hit reads at one end (GetDamageVarsFor{Player,Enemy}
  // Attack, core.asm :4059-4072, :4091-4104): the player's party struct, and
  // for the computer's battler GetEnemyMonStat (:4258-4297) -- outside a link
  // battle a CalcStat over wEnemyMonSpecies and wEnemyMonDVs at its level with
  // no stat exp. For every foe the computer fields (they carry no stat exp)
  // that is its party stat, until it TRANSFORMs: the species byte and the DVs
  // are then the copied ones, so the crit stat is a CalcStat over the copied
  // species' base stats and DVs (K7 `base` / `dvs`, which Transform copies).
  // Without K7 on the sheet the referee cannot compute it and reads the party
  // stat, as it always did. A link fight reads the party struct on both ends.
  _critStat(fighter, mon, key) {
    if (mon.transformed && isComputerSeat(this.mode, fighter)
        && isTable(mon.base) && isTable(mon.dvs)) {
      return Effects.calcStat(mon.base[key], mon.dvs[key], mon.level, null, false);
    }
    return mon.partyStats[key];
  }

  // A Bide's forced turn, past every gate (`.BideCheck`, core.asm
  // :3482-3524): the store takes wDamage -- the shared word, whatever last
  // wrote it, not the HP this monster lost -- and the counter a step; the turn
  // it reaches 0 unleashes twice the store (two bytes, both wrapping),
  // skipping DecrementPP, the used-move line and MoveHitTest -- so it reaches
  // a FLY or DIG user -- and a store of 0 is "<MON>'s attack missed!". A store
  // turn says nothing at all: it jumps straight to ExecutePlayerMoveDone, and
  // SavingEnergyText (:3630) is never referenced.
  _bideTurn(fighter, mon, move, usedSlot) {
    const bide = mon.bide;
    bide.stored = (int(bide.stored, 0) + Math.max(0, int(this.lastDamage, 0))) % 65536;
    bide.turns = int(bide.turns, 0) - 1;
    if (bide.turns > 0) return;
    const stored = bide.stored;
    mon.bide = null;
    // `.UnleashEnergy` writes 1 into wPlayerMovePower (core.asm :3508-3509),
    // leaving the struct's type as GetCurrentMove last left it: a COUNTER can
    // answer a Bide.
    if (fighter.moveStruct && typeof fighter.moveStruct === 'object') fighter.moveStruct.power = 1;
    this._say(`${named(fighter, mon)}\nunleashed energy!`);
    const aim = fighter.choice.target;
    const target = aim !== null && aim !== undefined ? this._retarget(fighter, aim) : null;
    const defender = target ? activeMon(target) : null;
    if (!defender) {
      this._say(`${named(fighter, mon)} has no target`);
      return;
    }
    const damage = (2 * stored) % 65536;
    // `.UnleashEnergy` jumps to handleIfPlayerMoveMissed with wMoveMissed set
    // on a 0 (core.asm :3510-3524): no animation then (K22's audit).
    if (damage > 0) {
      this._emit('anim', { slot: fighter.slot, side: fighter.side, text: move.id });
    }
    if (damage <= 0) {
      this.lastDamage = 0;
      this._say(`${named(fighter, mon)}'s\nattack missed!`);
      this._markLastMove(mon, usedSlot);
      return;
    }
    this.lastDamage = this._damage(target, defender, damage, null);
    this._buildRage(target, defender, fighter);
    this._markLastMove(mon, usedSlot);
  }

  // A power-0 move (`_useMove` sends it here once Mirror Move and Metronome
  // have had their say): the cart never runs MoveHitTest for one on the way in
  // (CalculateDamage's power-0 return, core.asm :3145), so each effect's own
  // routine meets the hit test where it does (Effects.statusPlan) -- and one
  // that never does is not stopped by FLY or DIG and draws no accuracy byte.
  _statusMove(fighter, mon, target, defender, move, effectId, usedSlot, choice, recordMove) {
    // A power-0 move reaches HandleBuildingRage ahead of any hit test of its
    // own: CalculateDamage's `jp z` (core.asm :3145) goes round MoveHitTest,
    // so wMoveMissed is still clear when the no-op ApplyAttackToEnemyPokemon
    // (:4622) returns to the build. ResidualEffects1 / 2 and the two calls
    // have left by then (`Effects.skipsBuildingRage`); what is left in Red is
    // Disable, whose own MoveHitTest comes after. So a raging target builds
    // whether the Disable lands or not.
    if (!Effects.skipsBuildingRage(effectId)) {
      this._buildRage(target, defender, fighter);
    }

    const plan = Effects.statusPlan(effectId);
    // What a routine's checks hand on to its effect (Effects.applyPrimary):
    // SleepEffect's recharge overwrite, MimicEffect's pick.
    // Every routine plays the move's animation itself, where it succeeds and
    // nowhere it fails (PlayCurrentMoveAnimation / ...2 sit past each check):
    // a check below that turns the move away takes the `anim` `_useMove` put
    // ahead of the used line back out (`_dropMoveAnim`), as `_moveMissed` does
    // for a miss; Effects.applyPrimary says whether its part played it.
    let extra = null;
    if (plan === 'statdown') {
      // StatModifierDownEffect (effects.asm :539-562): outside a link battle
      // the computer's drop draws its extra 25% miss first, then a Substitute
      // misses, then MoveHitTest -- Mist inside it, before the byte -- and
      // every one of them is MoveMissed's "But it failed!".
      if (isComputerSeat(this.mode, fighter)
          && this.rng.byte() < Effects.COMPUTER_DROP_MISS) {
        this._say('But, it failed!');
        this._dropMoveAnim();
        this._markLastMove(mon, usedSlot);
        return;
      }
      if (Effects.hasSubstitute(defender)) {
        this._say('But, it failed!');
        this._dropMoveAnim();
        this._markLastMove(mon, usedSlot);
        return;
      }
      if (!this._hitTest(mon, defender, move, effectId).hit) {
        this._say('But, it failed!');
        this._moveMissed(fighter, mon, target, defender, effectId, usedSlot);
        return;
      }
    } else if (plan === 'poison') {
      // PoisonEffect (effects.asm :78-162): a doll, a status or a Poison type
      // turn it away before its MoveHitTest, and a miss says the same thing
      // -- "It didn't affect <TARGET>!" (`.noEffect` / `.didntAffect`).
      if (Effects.poisonTurnsAway(defender, this.poisonType)) {
        this._say(`It didn't affect\n${named(target, defender)}!`);
        this._dropMoveAnim();
        this._markLastMove(mon, usedSlot);
        return;
      }
      if (!this._hitTest(mon, defender, move, effectId).hit) {
        this._say(`It didn't affect\n${named(target, defender)}!`);
        this._moveMissed(fighter, mon, target, defender, effectId, usedSlot);
        return;
      }
    } else if (plan === 'disable') {
      // DisableEffect (effects.asm :1286-1293): its MoveHitTest first, and a
      // miss is "But it failed!" (`.moveMissed`).
      if (!this._hitTest(mon, defender, move, effectId).hit) {
        this._say('But, it failed!');
        this._moveMissed(fighter, mon, target, defender, effectId, usedSlot);
        return;
      }
    } else if (plan === 'sleep') {
      // SleepEffect (effects.asm :26-68). A target that must recharge loses
      // the recharge and falls asleep past every check -- no status check, no
      // MoveHitTest, no byte but the counter's (the cart's own comment: "all
      // hit tests will be skipped including the event where the target
      // already has another status"), so the counter overwrites whatever
      // status it had (`overwrite`). Otherwise "<TARGET>'s already asleep!",
      // then any other status, then MoveHitTest's miss -- both "It didn't
      // affect <TARGET>!" -- and no byte before the hit test's. No Substitute
      // check: SLEEP POWDER reaches the monster behind a doll.
      if (defender.mustRecharge) {
        defender.mustRecharge = false;
        extra = { overwrite: true };
      } else if (defender.status === 'sleep') {
        this._say(`${named(target, defender)}'s\nalready asleep!`);
        this._dropMoveAnim();
        this._markLastMove(mon, usedSlot);
        return;
      } else if (Effects.hasMajorStatus(defender)) {
        this._say(`It didn't affect\n${named(target, defender)}!`);
        this._dropMoveAnim();
        this._markLastMove(mon, usedSlot);
        return;
      } else if (!this._hitTest(mon, defender, move, effectId).hit) {
        this._say(`It didn't affect\n${named(target, defender)}!`);
        this._moveMissed(fighter, mon, target, defender, effectId, usedSlot);
        return;
      }
    } else if (plan === 'paralyze') {
      // ParalyzeEffect_ (move_effects/paralyze.asm): any status ("It didn't
      // affect"), then an ELECTRIC move into a GROUND type (`cp ELECTRIC` on
      // the move, `cp GROUND` on both target types: "It doesn't affect"),
      // both before MoveHitTest, whose miss is "It didn't affect" again. No
      // Substitute check: THUNDER WAVE reaches the monster behind a doll.
      if (Effects.hasMajorStatus(defender)) {
        this._say(`It didn't affect\n${named(target, defender)}!`);
        this._dropMoveAnim();
        this._markLastMove(mon, usedSlot);
        return;
      }
      if (this.electricType !== null && int(move.type, -1) === this.electricType
          && hasType(defender, this.groundType)) {
        this._say(`It doesn't affect\n${named(target, defender)}!`);
        this._dropMoveAnim();
        this._markLastMove(mon, usedSlot);
        return;
      }
      if (!this._hitTest(mon, defender, move, effectId).hit) {
        this._say(`It didn't affect\n${named(target, defender)}!`);
        this._moveMissed(fighter, mon, target, defender, effectId, usedSlot);
        return;
      }
    } else if (plan === 'confusion') {
      // ConfusionEffect (effects.asm :1120-1126): CheckTargetSubstitute, then
      // MoveHitTest -- either one ConfusionEffectFailed's "But it failed!" --
      // and an already confused target fails the same way (Effects).
      if (Effects.hasSubstitute(defender)) {
        this._say('But, it failed!');
        this._dropMoveAnim();
        this._markLastMove(mon, usedSlot);
        return;
      }
      if (!this._hitTest(mon, defender, move, effectId).hit) {
        this._say('But, it failed!');
        this._moveMissed(fighter, mon, target, defender, effectId, usedSlot);
        return;
      }
    } else if (plan === 'leechseed') {
      // LeechSeedEffect_ (move_effects/leech_seed.asm): MoveHitTest first,
      // then a GRASS type, then a target already SEEDED -- all three
      // "<TARGET> evaded attack!". No Substitute check: LEECH SEED reaches the
      // monster behind a doll.
      if (!this._hitTest(mon, defender, move, effectId).hit) {
        this._say(`${named(target, defender)}\nevaded attack!`);
        this._moveMissed(fighter, mon, target, defender, effectId, usedSlot);
        return;
      }
      if (hasType(defender, this.grassType) || defender.leechSeed) {
        this._say(`${named(target, defender)}\nevaded attack!`);
        this._dropMoveAnim();
        this._markLastMove(mon, usedSlot);
        return;
      }
    } else if (plan === 'mimic') {
      // MimicEffect (effects.asm :1203-1273): MoveHitTest, "But it failed!"
      // on a miss (its INVULNERABLE re-check after it can never fire), then
      // the pick (`_mimicPick`). No Substitute check.
      if (!this._hitTest(mon, defender, move, effectId).hit) {
        this._say('But, it failed!');
        this._moveMissed(fighter, mon, target, defender, effectId, usedSlot);
        return;
      }
      const pick = this._mimicPick(fighter, defender, choice);
      if (pick === null) {
        this._say('But, it failed!');
        this._dropMoveAnim();
        this._markLastMove(mon, usedSlot);
        return;
      }
      extra = { mimicSlot: pick };
    } else if (plan === 'conversion') {
      // ConversionEffect_'s own INVULNERABLE test on the target, no byte.
      if (defender.invulnerable) {
        this._say('But, it failed!');
        this._dropMoveAnim();
        this._markLastMove(mon, usedSlot);
        return;
      }
    }

    // `targetSlot` the seat actually swung at, which a Bide records.
    // BideEffect (effects.asm :764-789) sets STORING_ENERGY, draws its 2..3
    // and plays an animation: no line past "used BIDE!". Its animation is not
    // the move's: `add XSTATITEM_ANIM` on hWhoseTurn -- XSTATITEM_ANIM, or the
    // enemy's XSTATITEM_DUPLICATE_ANIM sent as the same id (K20) -- so the
    // `anim` ahead of the used line is that one (K22's audit).
    if (Effects.isBide(effectId) && !mon.bide) {
      mon.bide = {
        turns: Effects.bideTurns(this.rng),
        stored: 0,
        moveIndex: usedSlot,
        targetSlot: target.slot,
        move: recordMove,
      };
      if (this.moveAnim) this.moveAnim.text = 'XSTATITEM_ANIM';
      this._markLastMove(mon, usedSlot);
      return;
    }
    if (Effects.isSwitchAndTeleport(effectId)) {
      // `.playAnimAndPrintText` plays the move's animation for an escape alone.
      if (!this._switchAndTeleport(fighter, mon, target, defender, move)) {
        this._dropMoveAnim();
      }
      this._markLastMove(mon, usedSlot);
      return;
    }
    if (Effects.isNoOp(effectId)) {
      this._say('But nothing happened');
      this._dropMoveAnim();
      this._markLastMove(mon, usedSlot);
      return;
    }
    if (Effects.handlesPrimary(effectId)) {
      // TransformEffect_ on the player's turn writes `a` -- hWhoseTurn, 0 --
      // into wPlayerMoveListIndex before anything else (transform.asm :15),
      // whether the copy then lands or not: the first slot from here on.
      if (effectId === 57 && isPlayerSeat(this.mode, fighter)) {
        fighter.moveListIndex = 1;
      }
      // MIMIC overwrites the list index's slot (`.letPlayerChooseMove` reads
      // wPlayerMoveListIndex, effects.asm :1238).
      if (!this._applyPrimary(fighter, mon, target, defender, this._listIndex(fighter, choice),
        effectId, move.id, extra)) {
        this._dropMoveAnim();
      }
    } else {
      this._say('But nothing happened');
      this._dropMoveAnim();
    }
    this._markLastMove(mon, usedSlot);
  }

  // The trap a TRAPPING_EFFECT move starts. `count` is TrappingEffect's
  // counter (wPlayerNumAttacksLeft): the attacks after this one, which
  // `.MultiturnMoveCheck` spends one a turn in the trapper's slot
  // (`_trapTurn`) and CheckNumAttacksLeft ends on at 0
  // (`_checkNumAttacksLeft`) -- so a count of 1 is a two-turn Wrap. The trap
  // is the trapper's record; the held monster's mirrors it (`turns`,
  // `damage`) so a sheet reader sees the hold. `damage` is what each later
  // turn deals -- wDamage after the hit, the whole hit against a doll
  // (AttackSubstitute leaves wDamage alone), 0 after an immunity -- which the
  // caller writes once the hit is in.
  _startTrap(fighter, mon, target, defender, count, usedSlot, recordMove, damage) {
    defender.trapped = {
      turns: count,
      damage: Math.max(0, int(damage, 0)),
      fromSlot: fighter.slot,
    };
    mon.trapping = {
      turns: count,
      moveIndex: usedSlot,
      targetSlot: target.slot,
      move: recordMove,
      damage: Math.max(0, int(damage, 0)),
    };
  }

  // `.MultiturnMoveCheck` (core.asm :3549-3560) and where it jumps: "<MON>'s
  // attack continues!", the counter down a step, and GetPlayerAnimationType
  // -- the move's animation, then ApplyAttackToEnemyPokemon with wDamage as
  // the trap's first hit left it (AttackSubstitute against a doll), and
  // HandleBuildingRage on a target still standing. No "used" line, no
  // DecrementPP, no crit, roll or hit test, and nothing else is said: a hit
  // for 0 (an immunity's trap, a 0.25x zero) is the continues line and an
  // empty hit. It lands in the trapper's own slot of the turn order, after
  // the trapper's gates (`_runGates`: asleep, frozen, flinched, its WRAP
  // disabled -- none of them spends the counter, and the held monster stays
  // held; fully paralysed or hurting itself, the trap is gone).
  _trapTurn(fighter, mon, move, usedSlot) {
    const trap = mon.trapping;
    this._say(`${named(fighter, mon)}'s\nattack continues!`);
    trap.turns = Math.max(0, int(trap.turns, 0) - 1);
    const target = this._fighterAtSlot(trap.targetSlot);
    const defender = target ? activeMon(target) : null;
    const held = defender ? defender.trapped : null;
    if (held && held.fromSlot === fighter.slot) held.turns = trap.turns;
    // The move's animation again (GetPlayerAnimationType: wMoveMissed is
    // clear, no hit test ran), but no use of the move -- no used line, no
    // callout: `quiet` (K22's "a trap's per-turn hit").
    this._emit('anim', {
      slot: fighter.slot, side: fighter.side, text: move.id, quiet: true,
    });
    if (defender) {
      let damage = int(trap.damage, 0);
      if (held && held.fromSlot === fighter.slot) damage = int(held.damage, 0);
      this.lastDamage = this._damage(target, defender, Math.max(0, damage), null);
      this._buildRage(target, defender, fighter);
    }
    this._markLastMove(mon, usedSlot);
  }

  // "Hit the enemy N times!" (_MultiHitText, the player's) and "Hit N times!"
  // (_HitXTimesText, the enemy's), with the count TwoToFiveAttacksEffect drew
  // (wPlayerNumHits / wEnemyNumHits). "The player" is the owner's rule.
  _hitTimesText(fighter, hits) {
    if (isPlayerSeat(this.mode, fighter)) return `Hit the enemy\n${hits} times!`;
    return `Hit ${hits} times!`;
  }

  _useMove(fighter, mon, opts = {}) {
    const choice = fighter.choice;
    // No animation of this move is out yet (`moveAnim`): a gate that stops it
    // has nothing to take back, and a called move's is its own.
    this.moveAnim = null;
    // A move Metronome or Mirror Move called is not the turn's own move. The
    // gates and the obedience check already ran for the move that called it
    // -- MetronomePickMove and MirrorMoveCopyMove jump back to
    // CheckIfPlayerNeedsToChargeUp (core.asm :3206, :3211), past
    // CheckPlayerStatusConditions and CheckForDisobedience -- and it is never
    // Struggle, whatever PP the calling slot has left: Struggle is a move, not
    // a state of the user's PP, so the call that spent the last PP takes no
    // recoil.
    const called = opts.moveOverride !== undefined && opts.moveOverride !== null;
    // The move this action resolves to. A forced replay is the move it
    // replays (`_fillForcedChoices`), a called one included, and never
    // Struggle: no menu was opened to offer it. Otherwise the menu's own
    // answer (`mustStruggle`) -- an empty sheet (`moves.length === 0`)
    // included -- is the synthetic STRUGGLE; returning on the missing slot
    // used to eat that turn instead.
    // wPlayerMoveListIndex / wEnemyMoveListIndex (`_listIndex`): the slot
    // DecrementPP spends, IncrementMovePP refunds and MIMIC overwrites.
    const listIndex = this._listIndex(fighter, choice);
    // A monster asleep or frozen at the menu opened no move menu, so the move
    // its slot runs is wPlayerSelectedMove as last turn left it -- reached only
    // when a Fire hit thawed it before its slot (sleep's waking turn is lost).
    // That is the move last turn USED: the one a METRONOME or MIRROR MOVE
    // called, if it called one, and not the calling move.
    const stale = !called && !!choice.stale
      && (choice.forcedMove === undefined || choice.forcedMove === null)
      && !!fighter.selectedMove && typeof fighter.selectedMove === 'object';
    let move = opts.moveOverride;
    if (!called) {
      if (choice.forcedMove) {
        move = choice.forcedMove;
      } else if (stale) {
        move = fighter.selectedMove;
      } else if (this._struggles(fighter, mon)) {
        move = STRUGGLE;
      } else {
        move = mon.moves[choice.move - 1];
      }
    }
    if (!move) return;
    const struggling = move === STRUGGLE;
    // MetronomePickMove / MirrorMoveCopyMove write the called move into
    // wPlayerSelectedMove, where COUNTER reads it (`_counterDamage`).
    if (called) fighter.selectedMove = move;
    // The slot this action is *using*: the chosen one, or the one a
    // disobedient monster picked instead (below), carried into a Metronome /
    // Mirror Move call. Whatever the action records for a later turn -- a
    // charge, a thrash, a Rage, a trap, a Bide, the last move a Mirror Move
    // copies -- is recorded against it, because the cart overwrote
    // wPlayerSelectedMove with the move it used. Two things still answer to
    // the *chosen* slot, wPlayerMoveListIndex, which `.chooseMove` never
    // rewrites: the PP spent (DecrementPP) and the slot Mimic writes over
    // (`_applyPrimary`). A stale selection's slot is that index too.
    let usedSlot = opts.slot !== undefined && opts.slot !== null ? opts.slot
      : (stale ? listIndex : choice.move);
    // What a record this action starts keeps for its forced turns: the move
    // itself when it is a called one -- this call, or a forced replay of one
    // (`choice.called`), or a stale selection that is not its slot's own move
    // -- and nothing for the slot's own move, which the record's slot already
    // names.
    let recordMove = (called || choice.called) ? move : null;
    if (stale && move !== moveAt(mon, usedSlot)) recordMove = move;
    let disobedient = opts.disobedient === true;
    // ReloadMoveData (core.asm :4996-5010), on the way into the called move:
    // IncrementMovePP gives the list index's PP back -- "to prevent moves that
    // run another move within the same turn ... from losing 2 PP" -- before the
    // called move's own PlayerCanExecuteMove spends it again (below). A called
    // charge stops at ChargeEffect without that second DecrementPP, so its call
    // refunds the slot for the turn (the release pays it, `payIndex`). The
    // computer's slot is refunded too, and never spent: its PP climbs.
    if (called) {
      this._incrementPp(fighter, mon, listIndex);
      this._loadMoveStruct(fighter, move);
    }

    // The gates, the disabled-move check among them (`_runGates`).
    if (!called && !this._runGates(fighter, mon, move)) return;

    // Bide's forced turns end here, one way or the other (`_bideTurn`).
    if (!called && choice.bideStore && mon.bide) {
      this._bideTurn(fighter, mon, move, usedSlot);
      return;
    }

    // `.ThrashingAboutCheck` (core.asm :3526-3547), the turns after the first:
    // "<MON>'s thrashing about!", then the counter comes down a step past every
    // gate, and the step that takes it to 0 ends the thrash in confusion --
    // 2..5 turns, a draw, and not a word: `set CONFUSED` prints nothing there
    // (the `status` chip says it) -- and the move still lands this turn (`pop
    // hl` keeps PlayerCalcMoveDamage). These turns go straight to
    // PlayerCalcMoveDamage, past PlayerCanExecuteMove: no "used" line, no
    // DecrementPP, no DisplayUsedMoveText writing wPlayerUsedMove, and never a
    // new thrash.
    const thrashTurn = !called && !!choice.forcedMove && !!mon.thrashing;
    if (thrashTurn) {
      this._say(`${named(fighter, mon)}'s\nthrashing about!`);
      mon.thrashing.turns -= 1;
      if (mon.thrashing.turns <= 0) {
        mon.thrashing = null;
        mon.confusion = this.rng.byte() % 4 + 2;
        this._emit('status', {
          slot: fighter.slot, side: fighter.side, confused: 1,
          text: `${mon.species} became confused!`,
        });
      }
    }

    // `.MultiturnMoveCheck` (core.asm :3549-3560): a trap's later turns, past
    // every gate (`_trapTurn`). A trap a switch or a faint let go before this
    // slot has no bit left to find, and the selection the cart left standing
    // -- the trapping move -- runs fresh below: the used line, DecrementPP and
    // a new TrappingEffect, at whoever is there now (the link-battle glitch,
    // and what a released trapper does).
    if (!called && choice.trapContinue && mon.trapping) {
      this._trapTurn(fighter, mon, move, usedSlot);
      return;
    }

    // `.playerHasNoSpecialCondition`'s GetCurrentMove (core.asm :3095): the
    // selected move into the move struct, which COUNTER reads off this seat
    // (`_counterDamage`). A Bide's turns, a thrash's and a trap's
    // continuations and a Rage's (`.RageCheck` goes straight to
    // PlayerCanExecuteMove) leave CheckPlayerStatusConditions without it; a
    // called move loaded its own (ReloadMoveData, above).
    const rageTurn = !called && !!mon.raging && !!choice.forcedMove;
    if (!called && !thrashTurn && !rageTurn) {
      this._loadMoveStruct(fighter, move);
    }

    // CheckForDisobedience: a traded monster of the player's, on the turn's
    // own move. A forced action never asks -- Bide, a thrash, a Rage and a
    // charge's release all leave CheckPlayerStatusConditions (or the
    // CHARGING_UP branch) on a path that skips it -- and neither does a called
    // move (above).
    if (!called && fighter.badgeRules && mon.traded && !fighter.forced) {
      const verdict = this._obey(fighter, mon, struggling);
      if (!verdict.goes) return;
      if (verdict.instead) {
        usedSlot = verdict.instead;
        move = mon.moves[verdict.instead - 1];
        disobedient = true;
        fighter.selectedMove = move;
        // `.useRandomMove` ends on GetCurrentMove (core.asm :4000).
        this._loadMoveStruct(fighter, move);
      }
    }

    // Resolved once, here, and used for the whole action: see `_retarget`.
    const target = this._retarget(fighter, choice.target);
    const defender = target && activeMon(target);
    if (!defender) {
      this._say(`${named(fighter, mon)} has no target`);
      return;
    }

    const effectId = int(move.effect, 0);
    const releasing = mon.charging !== null && mon.charging !== undefined
      && Effects.isCharge(mon.charging.effect);
    const mirrorCopy = opts.mirrorCopy === true;
    // A charge's first turn: CheckIfPlayerNeedsToChargeUp jumps to
    // ChargeEffect (core.asm :3102-3109) ahead of PlayerCanExecuteMove, so it
    // prints no used line and spends no PP -- only the charge line and its
    // animation.
    const chargingUp = Effects.isCharge(effectId) && !mon.charging;

    // DecrementPP spends wPlayerMoveListIndex's PP -- the chosen slot -- even
    // when a disobedient monster used another move (`usedSlot` above). It
    // returns first while THRASHING_ABOUT or USING_RAGE is set
    // (engine/battle/decrement_pp.asm), so the turns after the first of a
    // thrash or a Rage spend nothing -- the thrash's own continuation even
    // skips the call (`.ThrashingAboutCheck` goes to PlayerCalcMoveDamage) --
    // and a Bide's unleash skips it too. A charge pays on its RELEASE:
    // PlayerCanExecuteChargingMove falls into PlayerCanExecuteMove
    // (:3111-3124), DisplayUsedMoveText and then DecrementPP, on the slot
    // wPlayerMoveListIndex still names -- the one chosen the turn it started
    // (`payIndex`), no menu having been opened since. So a METRONOME or MIRROR
    // MOVE that called a charge move pays its call's refund back there, and a
    // charge a full paralysis or a self-hit cancelled keeps it. A called move
    // that is not a charge pays the refund back at once: one PP a call, net.
    // The slot is the list index whatever move runs -- a stale selection's, a
    // released trap's fresh run, a disobedient monster's instead-move -- and
    // DecrementPP never looks at what is left: a slot at 0 wraps
    // (`_decrementPp`), to 63 PP and one PP Up fewer. The computer never pays
    // at all: ExecuteEnemyMove has no DecrementPP (core.asm :5510-5521), so
    // outside a link battle its PP never falls (`_hasPp`).
    let payIndex = listIndex;
    if (releasing) {
      payIndex = mon.charging.payIndex !== null && mon.charging.payIndex !== undefined
        ? mon.charging.payIndex : listIndex;
    }
    const paying = moveAt(mon, payIndex);
    if (paying && !struggling && !chargingUp
        && !thrashTurn && !mon.raging
        && !isComputerSeat(this.mode, fighter)) {
      this._decrementPp(mon, payIndex);
      // FIGHT reads the uploaded sheet: publish the spend. A called move's
      // spend only paid back the call's refund, so the list is as the
      // calling move left it (published there).
      if (!called) this._emitMoves(fighter, mon, fighter.active);
    } else if (called && chargingUp && paying && !isComputerSeat(this.mode, fighter)) {
      // The refund a called charge keeps for its charge turn.
      this._emitMoves(fighter, mon, fighter.active);
    }
    // The move's animation, ahead of its used line (the header's note), held
    // as `moveAnim` until the move shows whether the cart plays it: a miss, a
    // routine that fails or MIRROR MOVE take it back (`_dropMoveAnim`).
    // amount=1 is the charge/vanish setup beat (release omits it). The charge
    // turn's own is ChargeEffect's, not the move's (`chargeAnim`:
    // XSTATITEM_ANIM, FLY's TELEPORT -- `quiet` -- or DIG's SLIDE_DOWN_ANIM).
    // A thrash's continuation animates THRASH whatever the move:
    // `.ThrashingAboutCheck` writes THRASH into wPlayerMoveNum (core.asm
    // :3529-3530), the number PlayPlayerMoveAnimation plays -- so a PETAL
    // DANCE's later turns look like THRASH's.
    let animText = thrashTurn ? THRASH_ANIM : move.id;
    let animQuiet = null;
    if (chargingUp) [animText, animQuiet] = chargeAnim(effectId, move);
    this.moveAnim = this._emit('anim', {
      slot: fighter.slot, side: fighter.side,
      text: animText,
      amount: chargingUp ? 1 : undefined,
      quiet: animQuiet,
    });
    // DisplayUsedMoveText with wMonIsDisobedient set takes UsedMove2Text and
    // `.UsedInsteadText` (pokered engine/battle/used_move_text.asm; text_2.asm
    // _UsedInsteadText): "<MON> used instead, <MOVE>", in this file's shape of
    // the used line. A Metronome call keeps the flag (MetronomePickMove leaves
    // it), a Mirror Move copy clears it (MirrorMoveCheck's `xor a`), and the
    // calls below pass it on accordingly. A thrash's continuation never gets
    // to DisplayUsedMoveText (`.ThrashingAboutCheck` jumps to
    // PlayerCalcMoveDamage): its line was "thrashing about!" (above). Nor
    // does a charge's first turn (`chargingUp`): its line is the charge's.
    if (thrashTurn || chargingUp) {
      // nothing: see above
    } else if (disobedient) {
      // _ActorNameText's <USER>, _UsedMove2Text's `line`, _UsedInsteadText's
      // `cont` (K17 / K18).
      this._say(`${named(fighter, mon)}\nused instead,\n${moveLabel(move)}!`);
    } else {
      this._say(`${named(fighter, mon)}\nused ${moveLabel(move)}!`);
    }

    // Charge / Fly: first turn sets state and ends; second turn releases.
    if (chargingUp) {
      // `move` is kept when METRONOME / MIRROR MOVE called it: the release
      // replays it (`_fillForcedChoices`), not the calling slot. `payIndex`
      // is wPlayerMoveListIndex, which the release pays from (above).
      mon.charging = {
        moveIndex: usedSlot,
        payIndex: choice.move,
        effect: effectId,
        targetSlot: target.slot,
        moveId: move.id,
        move: recordMove,
      };
      if (Effects.vanishes(effectId, move)) mon.invulnerable = true;
      this._say(Effects.chargeMessage(mon, effectId, move.id, fighter.side));
      this._markLastMove(mon, usedSlot);
      return;
    }

    if (mon.charging && Effects.isCharge(mon.charging.effect)) {
      mon.charging = null;
      mon.invulnerable = false;
    }

    // DisplayUsedMoveText writes the move into wPlayerUsedMove /
    // wEnemyUsedMove (`.playerTurn`'s `ld [hl], a`), which is what a MIRROR
    // MOVE aimed at this monster copies (`lastUsedMove`): the move a METRONOME
    // or a MIRROR MOVE called, since the call prints its own line after the
    // caller's. A charge's first turn never runs it -- ChargeEffect is reached
    // from CheckIfPlayerNeedsToChargeUp, before PlayerCanExecuteMove, and
    // prints only "<MON> flew up high!" -- so a FLY in the air has not been
    // "used" yet; its release has. Nor does a thrash's continuation (above),
    // which leaves the first turn's THRASH there -- or the 0 a send-out wrote.
    if (!thrashTurn) mon.lastUsedMove = move;

    // SpecialEffectsCont (Effects.startsBeforeHit): PlayerCanExecuteMove runs
    // THRASH / PETAL DANCE's and the trapping moves' routines before damage
    // and every hit test. ThrashPetalDanceEffect sets THRASHING_ABOUT and its
    // 2..3 counter, so a thrash that misses still thrashes; TrappingEffect
    // (effects.asm :1080-1103) runs ClearHyperBeam on the target and draws its
    // counter, and only MoveHitTest's `.moveMissed` (`res
    // USING_TRAPPING_MOVE`) takes the trap back -- an immunity or a 0.25x
    // zero leaves it standing, doing 0 a turn, and a doll that holds keeps it
    // (`_startTrap`).
    // ThrashPetalDanceEffect ends on `add SHRINKING_SQUARE_ANIM` over
    // hWhoseTurn (effects.asm :791-808): SHRINKING_SQUARE_ANIM on the
    // player's turn, ANIM_B1 on the enemy's -- the same ShrinkingSquareAnim,
    // whose SUBANIMTYPE_ENEMY subanimation sits on the enemy's pic and is
    // flipped down onto the player's on the player's turn, so it plays over
    // the user either way; sent as SHRINKING_SQUARE_ANIM on the user's seat
    // (K20's normalisation). Its point is the routine's: after the used line
    // and before MoveHitTest, so ahead of the move's own animation -- which
    // moves behind it (`_trailMoveAnim`) -- and on a miss too.
    if (Effects.isThrash(effectId) && !mon.thrashing && !thrashTurn) {
      mon.thrashing = {
        turns: Effects.thrashTurns(this.rng),
        moveIndex: usedSlot,
        move: recordMove,
      };
      this._statusAnim(fighter, 'SHRINKING_SQUARE_ANIM');
      this._trailMoveAnim();
    }
    // TrappingEffect's counter, wPlayerNumAttacksLeft: the attacks after this
    // one, 1..4 (Effects.trapTurns is the 2..5 total).
    let trapCount = null;
    if (Effects.isTrapping(effectId) && !mon.trapping) {
      defender.mustRecharge = false;
      trapCount = Effects.trapTurns(this.rng) - 1;
    }

    if (Effects.isMirrorMove(effectId) && !mirrorCopy) {
      // MIRROR MOVE has no animation of its own on the cart:
      // MirrorMoveCopyMove plays none, and the copied move plays its own
      // (K22's audit).
      this._dropMoveAnim();
      // MirrorMoveCopyMove (core.asm :4960-4986) copies wEnemyUsedMove /
      // wPlayerUsedMove -- the move the target last printed a "used" line
      // for, so after its METRONOME called THRASH it is THRASH -- and fails
      // when there is none (zeroed at a send-out, a fast-asleep or a
      // frozen-solid turn) or it is MIRROR MOVE itself -- MirrorMoveFailedText,
      // "The MIRROR MOVE failed!" (`.mirrorMoveFailed`, :4983-4986).
      const last = defender.lastUsedMove;
      if (!isTable(last) || Effects.isMirrorMove(last.effect)) {
        this._say('The MIRROR MOVE\nfailed!');
        this._markLastMove(mon, usedSlot);
        return;
      }
      this._markLastMove(mon, usedSlot);
      this._useMove(fighter, mon, {
        moveOverride: copyMove(last),
        mirrorCopy: true,
        slot: usedSlot,
      });
      return;
    }

    const metronomeCall = opts.metronomeCall === true;
    if (Effects.isMetronome(effectId) && !metronomeCall) {
      const pool = this.metronomePool;
      if (!pool || pool.length === 0) {
        this._say('But nothing happened');
        this._markLastMove(mon, usedSlot);
        return;
      }
      const pick = this.rng.byte() % pool.length;
      this._markLastMove(mon, usedSlot);
      this._useMove(fighter, mon, {
        moveOverride: copyMove(pool[pick]),
        metronomeCall: true,
        slot: usedSlot,
        disobedient,
      });
      return;
    }

    // Which way the move goes: a hit (any power, the two-to-five pair at
    // power 0, the three set-damage / OHKO effects, COUNTER), or a power-0
    // move whose routine is its own (`_statusMove`).
    const isCounter = Effects.isCounter(move);
    const damaging = move.power > 0 || isCounter || Effects.isFixedDamage(effectId)
      || Effects.hitsAtPowerZero(effectId);
    if (!damaging) {
      // CalculateDamage's power-0 `jp z, PlayerCheckIfFlyOrChargeEffect`
      // (core.asm :3145): a FLY or charge move at power 0 -- on its release,
      // the charge turn having returned above -- shows STATUS_AFFECTED_ANIM
      // there (K20).
      this._flyOrChargeAnim(fighter, effectId);
      this._statusMove(fighter, mon, target, defender, move, effectId,
        usedSlot, choice, recordMove);
      return;
    }

    // An immunity or a 0.25x zero leaves a trap that already started standing
    // (above), at 0 a turn -- when MoveHitTest's own byte let it through.
    const trapAfterZero = () => {
      if (trapCount !== null) {
        this._startTrap(fighter, mon, target, defender, trapCount, usedSlot, recordMove, 0);
      }
    };

    // PlayerCalcMoveDamage / EnemyCalcMoveDamage (core.asm :3134-3149,
    // :5524-5542), in the cart's order -- the draws included:
    //   * SetDamageEffects (SUPER FANG, the SPECIAL_DAMAGE moves) jump straight
    //     to MoveHitTest: no crit byte, no chart, no roll -- only PSYWAVE's
    //     own loop, once the hit test passed (ApplyAttackToEnemyPokemon);
    //   * CriticalHitTest's byte (none at power 0: `ret z`), every other move,
    //     COUNTER and the OHKO moves included;
    //   * HandleCounterMove: COUNTER's conditions, then MoveHitTest, and
    //     nothing else (`_counterDamage`);
    //   * CalculateDamage -- for an OHKO move OneHitKOEffect_, which misses a
    //     faster target there and then (`jp z`: no chart, no roll, no hit
    //     test) -- AdjustDamageForMoveType (an immunity, or a 0.25x that leaves
    //     0, sets wMoveMissed and goes on), RandomizeDamage's roll (a 2 and
    //     up), and only then MoveHitTest: DREAM EATER's sleep check, SWIFT,
    //     INVULNERABLE, Mist and X Accuracy before its accuracy byte
    //     (`_hitTest`). So a move that misses has already drawn its crit byte
    //     and its roll, and an immune target still costs the accuracy byte.
    // A miss prints PrintMoveFailureText's line (`_damageMissText`).
    const isOhko = Effects.isOhko(effectId);
    let isCrit = false;
    let percents = null;
    let lastPct = null;
    let damage = 0;
    if (Effects.isSetDamage(effectId)) {
      if (!this._hitTest(mon, defender, move, effectId).hit) {
        this._flyOrChargeAnim(fighter, effectId);
        this._say(this._damageMissText(fighter, mon, target, defender, false, false));
        this._moveMissed(fighter, mon, target, defender, effectId, usedSlot);
        return;
      }
      damage = Effects.setDamage({
        effectId, moveId: move.id, userMon: mon, targetMon: defender,
        power: move.power, rng: this.rng,
        computerMover: isComputerSeat(this.mode, fighter),
      });
    } else {
      // Species base Speed, not battle Speed: paralysis and the Speed badge
      // must not change the crit rate. CriticalHitTest reads it off the
      // species byte, which TRANSFORM rewrites (Effects' Transform copies the
      // target's `baseSpd` / K7 `base.spd`). Absent both (old sheet) it falls
      // back to the unmodified stat, still without a stage, badge or penalty.
      // A power-0 hit (the two-to-five pair) draws no crit byte at all (`ret z`
      // on the power, :4501-4503). HighCriticalMoves is matched against
      // wPlayerMoveNum (`dec hl / ld c, [hl]`, :4503-4504), which a thrash's
      // continuation set to THRASH (`THRASH_ANIM`'s note) -- not on that table
      // -- so those turns crit at the ordinary rate whatever the move's own
      // flag says.
      if (move.power > 0) {
        let critSpd = mon.baseSpd !== undefined && mon.baseSpd !== null ? mon.baseSpd : null;
        if (critSpd === null && isTable(mon.base)) critSpd = mon.base.spd;
        if (critSpd === null || critSpd === undefined) critSpd = mon.stats.spd;
        isCrit = Crit.check({
          baseSpeed: critSpd,
          roll: this.rng.byte(),
          focusEnergy: mon.focusEnergy,
          highCritMove: move.highCrit === true && !thrashTurn,
        }).isCrit;
      }

      if (isCounter) {
        // HandleCounterMove (`_counterDamage`): a COUNTER whose conditions
        // fail misses there -- wMoveMissed set, no hit test, wDamage as it was
        // -- and one that passes takes MoveHitTest with its damage fixed. No
        // chart (it reaches a Ghost, says nothing of effectiveness), no roll.
        // The crit byte it drew still prints "Critical hit!" over the number
        // (PrintCriticalOHKOText), as the cart's does.
        const counter = this._counterDamage(target);
        if (!counter) {
          // wMoveMissed: no animation (HandleIfPlayerMoveMissed).
          this._dropMoveAnim();
          this._flyOrChargeAnim(fighter, effectId);
          this._say(`${named(fighter, mon)}'s\nattack missed!`);
          this._markLastMove(mon, usedSlot);
          return;
        }
        if (!this._hitTest(mon, defender, move, effectId).hit) {
          this._flyOrChargeAnim(fighter, effectId);
          this._say(this._damageMissText(fighter, mon, target, defender, false, false));
          this._moveMissed(fighter, mon, target, defender, effectId, usedSlot);
          return;
        }
        damage = counter;
      } else {
        ({ percents, last: lastPct } = this._typeRows(move.type, defender));
        let immune = false;
        let zeroed = false;
        if (isOhko) {
          // OneHitKOEffect_: a user slower than its target misses before the
          // chart and the hit test, and wCriticalHitOrOHKO's $ff makes it
          // "<TARGET>'s unaffected!". Otherwise 65535 goes through
          // AdjustDamageForMoveType -- an immunity zeroes it, no roll (`cp 2`)
          // -- and RandomizeDamage rolls over it (Effects.ohkoDamage): that
          // number, not the target's HP, is the hit's wDamage -- a doll breaks
          // outright on its high byte (AttackSubstitute) and keeps it for
          // COUNTER, and a monster takes its HP, which the overkill writes back.
          if (!Effects.ohkoLands(this._speedOf(fighter, mon), this._speedOf(target, defender))) {
            this._flyOrChargeAnim(fighter, effectId);
            this._say(this._damageMissText(fighter, mon, target, defender, false, true));
            this._moveMissed(fighter, mon, target, defender, effectId, usedSlot);
            return;
          }
          for (const pct of percents) {
            if (pct <= 0) { immune = true; break; }
          }
          if (!immune) {
            damage = Effects.ohkoDamage(hasType(mon, move.type), percents);
            if (damage <= 0) {
              zeroed = true;
            } else if (Damage.rolls(damage)) {
              damage = Damage.applyRoll(damage, this.rng.damageRoll());
            }
          }
        } else {
          // GetDamageVarsFor{Player,Enemy}Attack (core.asm :4030-4255). An
          // ordinary hit reads the stored battle stats -- stage, badges and a
          // burn already in them -- and a screen on the defender doubles its
          // stat (`sla c / rl b`, uncapped, so a big enough one wraps in the
          // scaling). A critical hit throws all of that away for the party
          // stats at both ends (`_critStat`): the player's party struct
          // (pre-Transform) and GetEnemyMonStat for the computer's. No stage,
          // no badge, no burn, no screen. The scaling, the Explosion halving
          // and the 997 cap are Damage.compute's.
          const isSpecial = Effects.isSpecialType(move.type, this.specialTypes);
          const atkKey = isSpecial ? 'spc' : 'atk';
          const defKey = isSpecial ? 'spc' : 'def';
          let attack;
          let defense;
          if (isCrit) {
            attack = this._critStat(fighter, mon, atkKey);
            defense = this._critStat(target, defender, defKey);
          } else {
            attack = mon.cur[atkKey];
            defense = defender.cur[defKey];
            if ((isSpecial && defender.lightScreen)
                || (!isSpecial && defender.reflect)) {
              defense *= 2;
            }
          }

          const result = Damage.compute({
            level: mon.level,
            attack,
            defense,
            power: move.power,
            crit: isCrit,
            stab: hasType(mon, move.type),
            typeEffect: percents,
            explode: Effects.isExplode(effectId),
          });

          // An immunity is a 0 (AdjustDamageForMoveType's multiply by 0), and
          // so is a 0.25x matchup that leaves a 2 or a 3 at 0 (:5173-5177):
          // both set wMoveMissed and draw no roll. RandomizeDamage draws only
          // for a 2 and up (`cp 2` / `ret c`): a hit already at 1 lands for 1.
          if (result.immune) {
            immune = true;
          } else if (result.modified <= 0) {
            zeroed = true;
          } else {
            damage = result.modified;
            if (result.rolls) damage = Damage.applyRoll(damage, this.rng.damageRoll());
          }
        }

        // MoveHitTest runs whatever AdjustDamageForMoveType decided -- it never
        // clears wMoveMissed, and its own miss is the only one that takes a
        // trap back (`.moveMissed`'s `res USING_TRAPPING_MOVE`). Which line the
        // miss gets is wDamageMultipliers' (PrintMoveFailureText): with the
        // chart's order, "doesn't affect" only when the LAST row the walk
        // applied was the 0 -- a dual type whose immunity row comes before
        // another row of the move's type is "<USER>'s attack missed!" -- and
        // without it, any immunity (`_typeRows`).
        const hit = this._hitTest(mon, defender, move, effectId).hit;
        if (immune || zeroed || !hit) {
          const noEffect = lastPct !== null ? lastPct === 0 : immune;
          // HandleIfPlayerMoveMissed's `jr PlayerCheckIfFlyOrChargeEffect`: a
          // released FLY or charge that missed shows STATUS_AFFECTED_ANIM
          // ahead of PrintMoveFailureText's line (K20).
          this._flyOrChargeAnim(fighter, effectId);
          this._say(this._damageMissText(fighter, mon, target, defender, noEffect, false));
          if (hit) trapAfterZero();
          this._moveMissed(fighter, mon, target, defender, effectId, usedSlot);
          return;
        }
      }
    }

    // PrintCriticalOHKOText and DisplayEffectiveness come after the hit is
    // applied (ExecutePlayerMove `.moveDidNotMiss`, core.asm :3226-3229), each
    // hit of a multi-hit move: wCriticalHitOrOHKO is cleared once printed, so
    // "Critical hit!" -- or a landed OHKO's "One-hit KO!", which
    // OneHitKOEffect_ wrote over the crit -- follows the first hit only, while
    // wDamageMultipliers stands for the whole move and its line follows every
    // hit (`typeLine`). A COUNTER, a set-damage move, a trap's later turns and
    // a Bide's unleash never ran AdjustDamageForMoveType that turn, so they
    // have no line.
    const effectLine = typeLine(percents, lastPct);

    // The trap, standing before the hit lands (a knockout's `_faint` takes it
    // back off the field).
    if (trapCount !== null) {
      this._startTrap(fighter, mon, target, defender, trapCount, usedSlot, recordMove, 0);
    }

    // The hits, each in the cart's order (ExecutePlayerMove :3226-3256):
    // ApplyAttackToEnemyPokemon, then the AlwaysHappenSideEffects routine at
    // `.notDone` (`_alwaysHappen`) -- before `ret z` on the target's HP, so a
    // knockout still runs it -- then HandleBuildingRage on a target still
    // standing, then the multi-hit test, which jumps back to
    // GetPlayerAnimationType with the same wDamage for the next hit.
    //
    // A hit that breaks a Substitute zeroes the move's effect
    // (AttackSubstitute `.nullifyEffect`, :4899): from that hit on no
    // AlwaysHappen routine runs and `.executeOtherEffects` finds nothing. So
    // no drain, no recoil, no Pay Day coins, no RAGE (the user never starts
    // raging), no EXPLOSION faint (the user survives), no HYPER BEAM recharge
    // and no side effect -- the hit itself and the target's Rage build stand.
    // A doll that holds zeroes nothing, and wDamage is then the whole hit
    // (AttackSubstitute takes it off the doll's own byte), so the drain, the
    // recoil -- STRUGGLE's half included -- the coins and the recharge all
    // happen.
    //
    // TwoToFiveAttacksEffect is an AlwaysHappen routine too, so the count is
    // drawn after the first hit (Effects.hitCount) -- a knockout included --
    // and never when that hit broke a doll, which leaves
    // ATTACKING_MULTIPLE_TIMES clear and ends the move there (the loop test,
    // :3245-3247, goes straight to `.executeOtherEffects`). A break on hit 2
    // or later finds the count set: the move goes on, the hits after it land
    // on the monster, the effect still gone. DOUBLE KICK (44) and TWINEEDLE
    // (77) are 2 without a draw. A count that ran out with the target standing
    // prints MultiHitText / HitXTimesText with it (`_hitTimesText`); a
    // knockout returned at `ret z` before the line.
    const multihit = Effects.isMultihit(effectId);
    let hits = 1;
    let counted = false;
    let totalDealt = 0;
    let effectLive = true;
    let h = 0;
    while (h < hits) {
      h += 1;
      if (defender.hp <= 0) break;
      // `jp nz, GetPlayerAnimationType` (core.asm :3245-3249): every hit
      // after the first replays the move's animation before it lands -- one
      // strike a hit, as the cart draws a DOUBLE KICK or a FURY ATTACK. The
      // first hit's is the one ahead of the used line (`moveAnim`).
      if (h > 1) {
        this._emit('anim', { slot: fighter.slot, side: fighter.side, text: animText });
      }
      const hpBefore = defender.hp;
      const subUp = Effects.hasSubstitute(defender);
      // A knockout keeps its 0 HP on the field until the move is over: its
      // `faint` is the action's end's (`_reapKo`, K19), after the lines below,
      // the AlwaysHappen routine's and the rest of the move's.
      this.lastDamage = this._damage(target, defender, damage, null);
      if (h === 1) {
        if (isOhko) {
          this._say('One-hit KO!');
        } else if (isCrit) {
          this._say('Critical hit!');
        }
      }
      if (effectLine) this._say(effectLine);
      totalDealt += hpBefore - defender.hp;
      if (subUp && !Effects.hasSubstitute(defender)) effectLive = false;
      if (effectLive) {
        if (h === 1 && multihit) {
          hits = Effects.hitCount(effectId, this.rng);
          counted = true;
        }
        this._alwaysHappen(fighter, mon, effectId, struggling, usedSlot, recordMove, defender, target);
      }
      if (defender.hp <= 0) break;
      this._buildRage(target, defender, fighter);
    }
    if (counted && defender.hp > 0) {
      this._say(this._hitTimesText(fighter, hits));
    }

    // What each later turn of a trap deals: wDamage now (`_trapTurn`).
    if (trapCount !== null && defender.trapped && defender.trapped.fromSlot === fighter.slot) {
      defender.trapped.damage = Math.max(0, int(this.lastDamage, 0));
      if (mon.trapping) mon.trapping.damage = defender.trapped.damage;
    }

    // `.executeOtherEffects` (core.asm :3258-3269) runs the side effect once,
    // after the last hit, and only if the move got that far: a hit that
    // knocked the target out returned at `ret z` (:3242), and a Substitute
    // this move broke -- on any hit -- zeroed the move's effect, so
    // TWINEEDLE's poison (`.twineedle` rewrote the effect to
    // POISON_SIDE_EFFECT1 on the first hit) is gone with it. A Substitute that
    // soaked every hit and still stands is the routine's to answer, so it is
    // passed through (Effects.applySide).
    if (defender.hp > 0 && effectLive) {
      this._applySide(fighter, mon, target, defender, effectId, move);
    }

    // A substitute absorbs HP (including the breaking hit), so totalDealt
    // stays 0. Do not then apply a foe primary onto the mon behind it. Nor onto
    // one the move knocked out: JumpMoveEffect at `.executeOtherEffects` is
    // past `ret z` on the target's HP (core.asm :3232-3242), and the
    // knockout's faint waits for the move's end now (K19), so the 0 HP is
    // what says so.
    if (Effects.handlesPrimary(effectId) && totalDealt > 0 && defender.hp > 0) {
      this._applyPrimary(fighter, mon, target, defender, this._listIndex(fighter, choice),
        effectId, move.id);
    }

    // HYPER_BEAM_EFFECT is one of `.executeOtherEffects`' (a knockout
    // returned before it, a broken doll zeroed it); a doll that held still
    // costs the recharge.
    if (Effects.isHyperBeam(effectId) && effectLive && defender.hp > 0) {
      mon.mustRecharge = true;
    }

    // ExplodeEffect ran with the AlwaysHappen routines (`_alwaysHappen`
    // notes it); its HP is taken here, after the target's Rage lines --
    // ExplodeEffect zeroes the HP without a word -- and "fainted!" comes once
    // the move is over (`_reapKo`). A doll the blast broke zeroed the effect
    // first: the user lives.
    if (Effects.isExplode(effectId) && effectLive) {
      this._faintUser(fighter, mon);
    }

    this._markLastMove(mon, usedSlot);
  }

  // AlwaysHappenSideEffects (data/battle/always_happen_effects.asm), the
  // routines `.notDone` jumps to after a hit lands, before HandleBuildingRage
  // and before the target's knockout is looked at: DRAIN_HP / DREAM_EATER,
  // PAY_DAY, RECOIL (and STRUGGLE, whose effect it is), RAGE, EXPLODE and the
  // multi-hit counts (`_useMove` draws those). One per move -- a move carries
  // one effect. `_useMove` skips this once a doll the move hit has broken.
  //   * DrainHPEffect_ halves wDamage in place (at least 1) and heals that.
  //   * PayDayEffect_ adds the user's level x 2 to the pile, on either side's
  //     turn (`_checkOver` pays it).
  //   * RecoilEffect_ costs a quarter of wDamage (a half for STRUGGLE), at
  //     least 1, straight off the user's HP -- never its own doll.
  //   * RageEffect sets USING_RAGE; `calledMove` is the move a METRONOME /
  //     MIRROR MOVE called, which the forced turns replay.
  //   * ExplodeEffect's faint is `_useMove`'s, said after the move.
  _alwaysHappen(fighter, mon, effectId, struggling, usedSlot, calledMove, defender, target) {
    if (Effects.isDrain(effectId)) {
      const heal = Effects.drainAmount(this.lastDamage);
      this.lastDamage = heal;
      this._heal(fighter, mon, heal);
      // DrainHPEffect_ ends on SuckedHealthText -- DreamWasEatenText for
      // DREAM EATER (move_effects/drain_hp.asm :85-96) -- full HP or not:
      // "Sucked health from\n<TARGET>!", "<TARGET>'s\ndream was eaten!".
      const name = named(target, defender);
      if (int(effectId, 0) === 8) {
        this._say(`${name}'s\ndream was eaten!`);
      } else {
        this._say(`Sucked health from\n${name}!`);
      }
    } else if (Effects.isPayDay(effectId)) {
      this.payDay[fighter.side] += Effects.payDayCoins(mon.level);
      this._say('Coins scattered\neverywhere!');
    } else if (struggling || Effects.isRecoil(effectId)) {
      const recoil = Effects.recoilAmount(this.lastDamage, struggling);
      this._say(`${named(fighter, mon)}'s\nhit with recoil!`);
      this._damage(fighter, mon, recoil, null, true);
    } else if (Effects.isRage(effectId)) {
      mon.raging = true;
      mon.rageMove = usedSlot;
      mon.rageCall = calledMove;
    }
  }

  // One place where HP comes off, so the faint that follows can never be
  // forgotten at one of the call sites. Rage is not built here: what builds
  // it is a move landing (`_buildRage`), not HP coming off.
  //
  // `direct` is HP the cart takes straight off the monster, past any doll:
  // HandlePoisonBurnLeechSeed_DecreaseOwnHP (a poison, burn or Leech Seed
  // tick), RecoilEffect_ and ExplodeEffect write the HP word themselves, and
  // only ApplyDamageTo*Pokemon -- a move's hit -- ever asks AttackSubstitute
  // (whose header says as much of recoil).
  //
  // Returns what wDamage holds after the hit, for COUNTER (`lastDamage`): the
  // whole amount against a doll -- AttackSubstitute takes it off the doll's
  // own byte and leaves wDamage alone -- and on a monster the HP it actually
  // took, ApplyDamageTo*Pokemon writing the old HP back over a knockout.
  _damage(fighter, mon, rawAmount, status, direct, holdFaint) {
    let amount = Math.max(0, int(rawAmount, 0));

    // (A Bide does not store here: `.BideCheck` adds wDamage on the storing
    // monster's own turn, `_bideTurn`.)

    // AttackSubstitute (core.asm :4849-4910): a hit over 255 breaks the doll
    // outright (`and a` on wDamage's high byte); otherwise `sub [hl]` /
    // `ret nc`, so a hit for exactly the doll's HP leaves it standing at 0
    // (`subAtZero`), and only a hit for more breaks it.
    if (amount > 0 && !direct && Effects.hasSubstitute(mon)) {
      // SubstituteTookDamageText first, every hit (AttackSubstitute's own
      // opening line, core.asm :4857-4858): <TARGET> is the doll's owner --
      // the other side's, on a self-hit or a crash -- then
      // SubstituteBrokeText if it went.
      this._say(`The SUBSTITUTE\ntook damage for\n${named(fighter, mon)}!`);
      const dollHp = Math.max(0, int(mon.substitute, 0));
      if (amount > 255 || amount > dollHp) {
        mon.substitute = 0;
        mon.subAtZero = null;
        this._say(`${named(fighter, mon)}'s\nSUBSTITUTE broke!`);
      } else {
        mon.substitute = dollHp - amount;
        mon.subAtZero = mon.substitute === 0 ? true : null;
      }
      this._emit('damage', {
        slot: fighter.slot,
        side: fighter.side,
        amount,
        hp: mon.hp,
        status: status && has(STATUS_TO_WIRE, status) ? STATUS_TO_WIRE[status] : undefined,
      });
      return amount;
    }

    if (amount > mon.hp) amount = mon.hp;

    mon.hp -= amount;

    this._emit('damage', {
      slot: fighter.slot,
      side: fighter.side,
      amount,
      hp: mon.hp,
      status: status && has(STATUS_TO_WIRE, status) ? STATUS_TO_WIRE[status] : undefined,
    });

    // `holdFaint`: the caller runs `_faint` itself, once its pass is done
    // (`_residualFor`). Inside an action (`koHeld`) the knockout waits for
    // the action's end, where MainInBattleLoop looks at the HP (`_reapKo`,
    // K19). Anywhere else it faints here.
    if (mon.hp <= 0 && !holdFaint && !this.koHeld) this._faint(fighter, mon);
    return amount;
  }

  // HandleBuildingRage (core.asm :4913-4950), for the monster `source`'s move
  // was just aimed at. The cart has two callers, ExecutePlayerMove (:3243)
  // and ExecuteEnemyMove (:5643), both after ApplyAttackTo*Pokemon and both
  // behind `ret z` on the target's HP -- so it runs once per hit of a move
  // that lands, never for a hit that knocked the target out, and never for HP
  // that no opponent's move took: a poison / burn / Leech Seed tick, a
  // confusion or disobedience self-hit, recoil, a crash. A Substitute that
  // soaked the hit does not stop it (AttackSubstitute returns to the same
  // caller, and the target's HP is untouched). The paths that reach it here:
  // every hit of the strike loop (fixed damage included), the Bide release
  // (`.UnleashEnergy` jumps to HandleIfPlayerMoveMissed), a trap's later
  // turns (`.MultiturnMoveCheck` jumps to GetPlayerAnimationType,
  // `_trapTurn` here), an Explosion that did not land (EXPLODE_EFFECT
  // is the one miss `.notDone` lets through), and a power-0 move outside both
  // ResidualEffects lists, which CalculateDamage sends past MoveHitTest to a
  // no-op ApplyAttack (Disable).
  //
  // It flips hWhoseTurn and runs StatModifierUpEffect, so the raging battler
  // is the "user": its own badges re-run (when it is the player's) and the
  // re-penalty lands on the battler whose turn it then is not -- the
  // attacker, `source`'s monster. At +6 the cart returns before saying
  // anything (`cp $0d` / `ret z`, ahead of the text), as this does; otherwise
  // it prints BuildingRageText, "<MON>'s RAGE is building!", and then whatever
  // StatModifierUpEffect prints -- "ATTACK rose!", or "Nothing happened!" off
  // a 999 Attack.
  _buildRage(fighter, mon, source) {
    if (!source || !mon || !mon.raging || mon.hp <= 0) return;
    if (Effects.clampStage(mon.stages ? mon.stages.atk : null) >= Effects.STAGE_MAX) return;
    this._say(`${named(fighter, mon)}'s\nRAGE is building!`);
    const { outcome, stage } = Effects.changeStat({
      mon, fighter, stat: 'atk', delta: 1,
      mover: fighter, nonMover: activeMon(source),
    });
    if (outcome === 'rose') {
      const line = `${named(fighter, mon)}'s\nATTACK rose!`;
      this._say(line);
      this._emit('stat', {
        slot: fighter.slot, side: fighter.side,
        amount: stage, stage, text: Events.plain(line),
      });
    } else if (outcome === 'stuck') {
      this._say('Nothing happened!');
    }
  }

  _heal(fighter, mon, amount) {
    let gained = Math.max(0, int(amount, 0));
    if (gained <= 0) return;
    const before = mon.hp;
    mon.hp = Math.min(mon.maxHp, mon.hp + gained);
    gained = mon.hp - before;
    if (gained <= 0) return;
    this._emit('drain', {
      slot: fighter.slot,
      side: fighter.side,
      amount: gained,
      hp: mon.hp,
    });
  }

  /**
   * This seat's monster just changed (battle start, switch, replacement).
   *
   * Its own set resets, then the currently standing opposition marks into it --
   * and the incoming monster marks into each of THEIR sets, which is the other
   * direction of BattleState.lua:2424: a switch-in joins the standing foe's
   * participants. A foe mid-replacement (nothing out) is neither read nor
   * written, the same way the engine has no enemy to mark against.
   */
  _refield(fighter) {
    fighter.fought = Object.create(null);
    const mine = activeMon(fighter) ? fighter.active : null;
    const foes = this.bySide[fighter.side === 'a' ? 'b' : 'a'];
    for (const foe of foes) {
      if (activeMon(foe)) {
        fighter.fought[foughtKey(foe.slot, foe.active)] = true;
        if (mine !== null) {
          if (!foe.fought) foe.fought = Object.create(null);
          foe.fought[foughtKey(fighter.slot, mine)] = true;
        }
      }
    }

    // ...and the mark the deferred send-out still owes (`_faint` explains why it
    // is held rather than taken here): whoever was standing when the monster
    // this one replaces went down was in against this one too, which is :3980
    // read for a seat that is asked for its replacement instead of just sending
    // it. Only this direction is owed -- the seat opposite re-derives its own
    // set the next time it refields, exactly as the engine keeps flags on one
    // side only. Consumed once: a seat that refields again later starts clean.
    const pending = fighter.pendingFought;
    fighter.pendingFought = null;
    if (pending) {
      for (const key of pending) fighter.fought[key] = true;
    }
  }

  /**
   * Who is standing opposite this seat right now, as participation keys, in
   * field order. A list rather than a set because it is walked: two runtimes
   * agreeing about a set they only ever ask is cheap, agreeing about one they
   * iterate is not.
   */
  _standingOpposition(fighter) {
    const keys = [];
    const foes = this.bySide[fighter.side === 'a' ? 'b' : 'a'];
    for (const foe of foes) {
      if (activeMon(foe)) keys.push(foughtKey(foe.slot, foe.active));
    }
    return keys;
  }

  /**
   * RemoveFaintedPlayerMon: a monster that faints stops being a participant
   * anywhere, so it neither collects nor counts.
   */
  _unfield(fighter, index) {
    const key = foughtKey(fighter.slot, index);
    for (const other of this.fighters) {
      if (other.fought) delete other.fought[key];
      // The held mark is reached too. A monster that fell while the seat
      // opposite was still choosing its replacement was never in against that
      // replacement, so it must not be sitting in the set the successor
      // inherits -- the same rule, one send-out earlier.
      const pending = other.pendingFought;
      if (pending) {
        for (let i = pending.length - 1; i >= 0; i -= 1) {
          if (pending[i] === key) pending.splice(i, 1);
        }
      }
    }
  }

  /**
   * What a faint pays, and to whom.
   *
   * **Facts, never an amount.** This referee holds no species table -- it never
   * has and, by the legal floor this whole server is built under, never will --
   * so it cannot compute a single point of experience. What it *can* do is
   * state the three things the formula needs and nothing else knows: which
   * monster fell, what level it was, and how many shares split it. Each client
   * then runs its own Experience over its own party, which is also the only
   * place the result can persist. Same shape as the vitamin writeback and the
   * catch grant: the authority announces, the owner applies.
   *
   * The mode gate is not a shortcut for the owner check, it is the rule. A
   * seated fighter here carries a playerId whether a connection is behind it or
   * a synthetic wild / trainer seat is, so "does this seat have an owner" is
   * not a question the turn machine can ask -- but the *mode* answers it,
   * because the hub only ever seats a synthetic opponent in these three, and
   * always on side b (`maxFighters` says the same thing about coop_wild's N-vs-1).
   * 1v1 and coop_pvp are left out deliberately rather than incidentally: paying
   * a player for beating another player is a farming loop, and it is not what
   * vanilla does with a link battle either.
   *
   * One event per PAID monster, in seat order and then party order -- the Lua
   * twin emits the same list in the same order, and a stream that differs by a
   * permutation is a parity failure with no symptom anyone could read. `bySide`
   * is built in roster index order and `fieldSlot` is monotonic in that index,
   * so the outer walk is a walk of slots; the inner one is the party array,
   * which is the order the engine's own party walk uses
   * (src/battle/BattleState.lua:3796).
   *
   * `slot` stays the owning FIGHTER's field slot -- that is the ownership gate,
   * and it is what a client checks before writing to its own save. `mon` says
   * which of that party banks the share, 0-based, because a benched participant
   * has no field slot to be named by.
   *
   * The divisor is the engine's: `participants` counts every member of the set,
   * `alive` is the subset still above zero HP, and only `alive` is paid
   * (BattleState.lua:3795-3801). The two agree in practice because a faint
   * already left the set (`_unfield`) -- mirrored rather than collapsed so the
   * shape stays comparable. The empty-set fallback is :3802-3804: with nothing
   * flagged, whoever is out gets it, which is also exactly what round 5 paid.
   *
   * No roll is drawn in here: the parity digest's rngState must not move
   * because a faint paid out.
   */
  _awardExp(fallen, mon) {
    if (!has(EXP_MODES, this.mode)) return;
    if (fallen.side === EXP_OWNER_SIDE) return;

    const fought = fallen.fought || Object.create(null);
    let participants = 0;
    const alive = [];
    for (const fighter of this.bySide[EXP_OWNER_SIDE]) {
      for (let index = 1; index <= fighter.mons.length; index += 1) {
        if (fought[foughtKey(fighter.slot, index)]) {
          participants += 1;
          if (fighter.mons[index - 1].hp > 0) alive.push({ fighter, index });
        }
      }
    }

    if (participants === 0) {
      for (const fighter of this.bySide[EXP_OWNER_SIDE]) {
        if (activeMon(fighter)) {
          participants += 1;
          alive.push({ fighter, index: fighter.active });
        }
      }
    }
    if (alive.length === 0) return;

    for (const winner of alive) {
      this._emit('exp', {
        slot: winner.fighter.slot,
        species: mon.species,
        speciesId: mon.speciesId,
        level: mon.level,
        participants,
        mon: winner.index - 1,
      });
    }
  }

  /**
   * Pay for everything the action just felled, in the order it fell.
   *
   * Split from `_faint` because the engine splits it: `onFaint` knocks a
   * monster *down* and clears its flag (BattleState.lua:3721-3723), and the
   * payout is queued behind that in `enemyMonFainted` -- so by the time anybody
   * is counted, every monster the action killed has already left the set.
   * Paying inside `_faint` instead put a self-KO'er in its own victim's payout:
   * an Explosion or a recoil that kills its user runs `_faintUser` *after* the
   * target's faint, so the user was still standing, still flagged, and still in
   * the divisor. CoopSim's `reapFaints` drops the whole batch before announcing
   * any of it for exactly this reason; this is that same batch, at the boundary
   * the turn machine already had.
   *
   * Draws nothing: the parity digest's rngState must not move because a faint
   * paid out, whenever it pays.
   */
  _drainExp() {
    const queue = this.pendingExp;
    if (queue.length === 0) return;
    this.pendingExp = [];
    for (const owed of queue) this._awardExp(owed.fallen, owed.mon);
  }

  _faint(fighter, mon) {
    this.faints += 1;
    // RemoveFaintedPlayerMon first (BattleState.lua:3721-3723 runs at the top
    // of onFaint): this one is out of every participation set before anything
    // below can pay anybody, so a mon that died on the way to the KO is not in
    // the divisor. Keyed off the seat's own party position rather than
    // `active`, which the recoil path has not cleared yet.
    for (let index = 1; index <= fighter.mons.length; index += 1) {
      if (fighter.mons[index - 1] === mon) { this._unfield(fighter, index); break; }
    }
    // wBattleResult (`_payDayOn`): RemoveFaintedPlayerMon's 1 for the player's
    // side, FaintEnemyPokemon's 0 for the other while the player still has a
    // monster standing (AnyPartyAlive; with none it returns before the write).
    if (fighter.side === EXP_OWNER_SIDE) {
      this.battleResult = 1;
    } else if (this._sideAlive(EXP_OWNER_SIDE)) {
      this.battleResult = 0;
    }
    // RemoveFaintedPlayerMon (core.asm :1003-1031) writes its 0 into
    // wBattleMonStatus, and ReadPlayerMonCurHPAndStatus copies it into the
    // party: the player's fallen monster carries no status, a Revive brings
    // it back clean. "The player" is the owner's rule (`isPlayerSeat`): side
    // a against the computer, both sides of a link fight -- each console for
    // its own monster. FaintEnemyPokemon (:732-830) zeroes the enemy's party
    // HP and leaves its status byte alone, so the computer's monster keeps the
    // status it fell with (the `team` row draws it down either way).
    if (isPlayerSeat(this.mode, fighter)) {
      mon.status = null;
      mon.statusTurns = 0;
    }
    mon.charging = null;
    mon.invulnerable = false;
    mon.mustRecharge = false;
    mon.thrashing = null;
    mon.raging = false;
    mon.rageMove = 0;
    mon.rageCall = null;
    mon.trapped = null;
    mon.trapping = null;
    mon.bide = null;
    mon.substitute = 0;
    mon.subAtZero = null;
    mon.lightScreen = false;
    mon.reflect = false;
    mon.mist = false;
    mon.focusEnergy = false;
    // A Transform goes with it too, and a MIMIC: a revived monster has its own
    // moves (`Effects.restoreMoves`).
    Effects.restoreMoves(mon);
    mon.toxicLinger = null;
    mon.xAccuracy = false;
    mon.leechSeed = null;
    mon.disable = null;
    // Stages and the battle stats go with it: a monster that comes back (a
    // Revive, then a switch-in) is loaded from its party stats like any other.
    Effects.loadBattleStats(mon, null);
    this._clearTrapsFrom(fighter.slot);

    // Living bench? Computed before clearing active; fainted mon already has hp 0.
    const next = firstLiving(fighter.mons);
    const faintEv = { slot: fighter.slot, side: fighter.side, text: mon.species };
    // amount=1 is the authoritative mustReplace signal (living bench). Clients
    // open the replace picker from this rather than guessing from local HP.
    if (next) faintEv.amount = 1;
    this._emit('faint', faintEv);
    // Immediately behind the faint line rather than at the next window, because
    // this is the one roster change a player is *watching* happen: the ball
    // goes dark in the same batch the monster goes down in, and a fight that
    // ends on this faint has no next window to have said it at.
    this._syncTeams(fighter);

    // Owed here, paid at the end of the action (`_drainExp`), with the fallen
    // sheet held in the queue so the payout still names the monster that fell
    // and the level it was. For an ordinary KO nothing moves: the faint, then
    // its spoils, and only then anything about what comes next -- the order
    // CoopSim announces in. What changes is the action that fells two: every
    // one of them is out of the sets before the first share is counted.
    this.pendingExp.push({ fallen: fighter, mon });

    fighter.active = null;
    if (next) {
      // Ask the seat for a switch on the next choice window; timeout / autoPick
      // still lands firstLiving (preferring an SE bench).
      fighter.mustReplace = true;
      // The successor's mark, taken now because the send-out is not now.
      //
      // Vanilla marks whoever is standing at the enemy's send-out
      // (BattleState.lua:3980), and the engine sends out inside the faint
      // itself, while the monster that landed the KO is still on the field --
      // which is also where CoopSim does it (`announceFaint` calls `sendOut`
      // for an NPC inside `reapFaints`). This referee cannot: it asks the seat,
      // and the answer arrives on the next choice window, by which time side
      // a's own switches have already resolved (`_resolveSwitches` walks side a
      // first). A player who swaps on that turn would hand the incoming foe a
      // set that never heard of the monster that beat the last one. So the
      // send-out's mark is taken here, against the field the faint actually
      // happened on, and held until `_refield` puts the successor out.
      fighter.pendingFought = this._standingOpposition(fighter);
    } else {
      fighter.mustReplace = null;
      fighter.pendingFought = null;
    }

    // While resolving, defer `_checkOver` to the caller (after the current move /
    // residual batch) so the same action can still faint the user (recoil,
    // explode) and land a draw. Outside resolve, end immediately -- and pay
    // first, because there is no action boundary out here to pay at.
    if (this.phase !== 'resolving') {
      this._drainExp();
      this._checkOver();
    }
  }

  // HandlePoisonBurnLeechSeed (core.asm :470-548) for one seat, at the end of
  // its slot (`_resolveFights`).
  _residualFor(fighter) {
    if (this.result) return;
    let mon = activeMon(fighter);
    // It takes the poison / burn tick and then the Leech Seed tick in one
    // pass, and looks at the HP only after both -- so a monster the poison or
    // burn knocks out still feeds its seeder. Read before the tick: `_faint`
    // clears `leechSeed`.
    const seeded = mon;
    const seed = mon ? mon.leechSeed : null;
    let poisonKo = false;
    // ...and the lingering Bad Poison bit, which `_faint` also clears.
    const lingered = !!mon && mon.toxicLinger === true;
    if (mon && mon.status) {
      let amount = Status.residual({
        status: mon.status, maxHp: mon.maxHp, toxicCounter: mon.toxicCounter,
      });
      if (amount !== null && amount !== undefined) {
        if (mon.status === 'toxic') {
          mon.toxicCounter += 1;
        } else if (mon.toxicLinger) {
          // HandlePoisonBurnLeechSeed_DecreaseOwnHP multiplies by the toxic
          // counter on the BADLY_POISONED bit alone, so a bit that outlived a
          // nap (`toxicLinger`) turns a later poison -- or a burn -- toxic.
          amount *= Math.max(1, int(mon.toxicCounter, 1));
          mon.toxicCounter = Math.max(1, int(mon.toxicCounter, 1)) + 1;
        }
        // HurtByBurnText for a burn, HurtByPoisonText for a poison --
        // PSN on the status byte, a toxic included (core.asm :484-489).
        if (mon.status === 'burn') {
          this._say(`${named(fighter, mon)}'s\nhurt by the burn!`);
        } else {
          this._say(`${named(fighter, mon)}'s\nhurt by poison!`);
        }
        // ...then BURN_PSN_ANIM, then the HP (:490-495).
        this._statusAnim(fighter, 'BURN_PSN_ANIM');
        // The knockout is the main loop's, once the whole pass is done
        // (`ret nz` on the HP, :526-528): its faint waits for the seed's tick.
        this._damage(fighter, mon, amount, mon.status, true, true);
        poisonKo = mon.hp <= 0;
      }
    }
    if (this.result) return;
    // The Leech Seed tick, on the monster seeded when the residual began: the
    // one still standing, or the one its own poison or burn just knocked out
    // (`poisonKo`). A trap's later hits are not part of this pass: they are
    // the trapper's own slot on the cart (`_trapTurn`).
    // HandlePoisonBurnLeechSeed_DecreaseOwnHP takes 1/16 of the max HP (at
    // least 1) and multiplies it by the toxic counter -- incremented again, so
    // a badly poisoned, seeded monster's counter climbs twice a turn (the
    // Leech Seed + Toxic glitch) -- whether or not the HP was there to take,
    // and _IncreaseEnemyHP hands the seeder that whole amount ("bc isn't
    // updated if HP subtracted was capped"). Read before the damage, since a
    // tick that knocks the seeded monster out runs `_faint`, which clears
    // `leechSeed`.
    mon = activeMon(fighter);
    if (seed && (mon === seeded || poisonKo)) {
      let amount = Math.max(1, Math.floor(seeded.maxHp / 16));
      if (seeded.status === 'toxic' || lingered) {
        amount *= Math.max(1, int(seeded.toxicCounter, 1));
        seeded.toxicCounter = Math.max(1, int(seeded.toxicCounter, 1)) + 1;
      }
      const from = seed.fromSlot;
      const seeder = from !== null && from !== undefined
        ? this._fighterAtSlot(from) : null;
      const sMon = seeder && activeMon(seeder);
      // ABSORB's animation first, played from the seeder's half: the cart
      // flips hWhoseTurn round PlayMoveAnimation (core.asm :506-516), so the
      // move id rides an `anim` on the SEEDER's seat (K20) -- the one standing
      // there now, which is also the one the HP goes to. Then the HP goes both
      // ways and HurtByLeechSeedText follows (:518-523), "LEECH SEED saps\n
      // <USER>!" -- <USER> the seeded monster, hWhoseTurn flipped back.
      // ABSORB is the seeder's look and not its move: `quiet` (K22).
      if (sMon && sMon.hp > 0) {
        this._emit('anim', {
          slot: seeder.slot, side: seeder.side, text: 'ABSORB', quiet: true,
        });
      }
      if (mon === seeded) this._damage(fighter, mon, amount, null, true, true);
      if (sMon && sMon.hp > 0) this._heal(seeder, sMon, amount);
      this._say(`LEECH SEED saps\n${named(fighter, seeded)}!`);
    }
    if (seeded && seeded.hp <= 0 && monAt(fighter, fighter.active) === seeded) {
      this._faint(fighter, seeded);
    }
    // (Disable does not count down here: its counter steps in the disabled
    // monster's own turn, `_tickDisable`.)
  }

  // ----------------------------------------------------------------
  // endings
  // ----------------------------------------------------------------

  // EndOfBattle (engine/battle/end_of_battle.asm): outside a link battle, a
  // fight that ends with wBattleResult 0 adds wTotalPayDayMoney to the
  // player's money, "<PLAYER> picked up ¥N!". That is a won fight, and also
  // an escape that never wrote the result -- a TELEPORT / ROAR / WHIRLWIND by
  // either side, a wild monster's flight, a POKé DOLL; the player's own RUN
  // writes 2 (TryRunningFromBattle) and a catch writes 2, so neither pays.
  // The pile is every PAY DAY that landed in the fight -- PayDayEffect_ adds
  // to it on either side's turn, so the computer's coins are the player's to
  // pick up too -- held at the 3-byte BCD's 999999 (AddBCD). Side a is the
  // player in the three fights against the computer; a link fight pays
  // nothing. The wallet (and Gold's Amulet Coin) is the client's (K11), on a
  // `ko` or a `run` outcome alike.
  //
  // An escape pays only while wBattleResult is still 0 (`battleResult`): any
  // of the player's monsters fainting wrote 1 (RemoveFaintedPlayerMon), and
  // nothing but an enemy's faint writes 0 back (FaintEnemyPokemon) -- so a
  // TELEPORT, a ROAR or a POKé DOLL after an earlier faint of the player's
  // picks up nothing, though the fight went on. A won fight always pays: the
  // enemy faint that won it wrote the 0, after any faint of the player's the
  // same action caused (FaintEnemyPokemon calls RemoveFaintedPlayerMon first).
  _payDayOn(result) {
    if (!result) return;
    if (result.reason === 'run' && this.battleResult !== 0) return;
    const coins = Math.min(PAY_DAY_MAX, this.payDay.a + this.payDay.b);
    if (EXP_MODES[this.mode] && coins > 0) result.payDay = coins;
  }

  _checkOver() {
    if (this.result) return true;
    const aliveA = this._sideAlive('a');
    const aliveB = this._sideAlive('b');
    if (aliveA && aliveB) return false;

    if (!aliveA && !aliveB) {
      // Both sides down at once. Against the computer the player blacks out,
      // whichever faint the cart finds first: HandleEnemyMonFainted runs
      // AnyPartyAlive straight after FaintEnemyPokemon and jumps to
      // HandlePlayerBlackOut on 0 (core.asm :699-705), and
      // HandlePlayerMonFainted does before it even reads the enemy's HP
      // (:969-975). So the computer wins -- no prize money, no Pay Day
      // (wBattleResult is RemoveFaintedPlayerMon's 1), and no exp:
      // FaintEnemyPokemon returns on that same AnyPartyAlive before
      // GainExperience (:802-806), as `_awardExp` finds no one standing. A
      // link fight's two carts each run that check on their own party and
      // each black out (LinkBattleLostText): nobody won, the draw.
      if (BADGE_MODES[this.mode]) {
        this._finish('win', this._sidePlayers('b'), this._sidePlayers('a'), 'ko');
      } else {
        this._finish('draw', null, null, 'ko');
      }
    } else if (aliveA) {
      const result = this._finish('win', this._sidePlayers('a'), this._sidePlayers('b'), 'ko');
      this._payDayOn(result);
    } else {
      this._finish('win', this._sidePlayers('b'), this._sidePlayers('a'), 'ko');
    }
    return true;
  }

  /*
   * `outcome` is stated from the *field's* point of view, not a recipient's:
   * "win" means the winners list won. The per-client rendering -- the "loss"
   * the loser's screen shows -- belongs to the session layer that addresses the
   * message, because it is the only party that knows who it is talking to.
   *
   * A draw carries no lists at all rather than two empty ones, because
   * Wire.battleOutcome refuses an empty id list: the absence is the statement.
   */
  _finish(outcome, winners, losers, reason) {
    if (this.result) return this.result;

    const result = { battle: this.id, outcome, reason };
    if (winners) result.winners = winners;
    if (losers) result.losers = losers;

    this.result = result;
    this.phase = 'over';
    this.deadline = null;
    this.resolveDeadline = null;
    this._emit('over', { text: reason });
    return this.result;
  }

  // null until the fight is done, so `if (battle.outcome())` is the whole test.
  outcome() {
    return this.result;
  }

  /*
   * Contract K9 (docs/plans/gen12-referee-gaps-fix.md): a mid-fight level-up,
   * as the hubs forward it from `mmo.battle_moveset` (Hub:applyBattleMoveset,
   * Relay.applyBattleMoveset). `monIndex` is 1-based into the seat's party;
   * `level`, `stats` (atk def spd spc) and `maxHp` are the client's claim.
   * Returns true when the referee took it, false otherwise -- and never
   * throws: a hub calls this from a message handler.
   *
   * The rebuild is experience.asm's (:150-245), after its CalcStats:
   *   * the party struct takes the new level and stats, and the current HP
   *     grows by what the max HP grew by;
   *   * the monster in battle copies the level, the max HP and the stats into
   *     its battle struct, and into its unmodified stats unless it is
   *     TRANSFORMed (whose copied ones stay), then runs CalculateModifiedStats
   *     (the stages), ApplyBurnAndParalysisPenaltiesToPlayer and
   *     ApplyBadgeStatBoosts -- Effects.recalcBattleStats, exactly;
   *   * a benched monster's party stats only (a switch-in reloads the rest).
   *
   * Plausibility, judged here because the hubs pass the claim through: only
   * side a of a fight against the computer earns experience (EXP_MODES, the
   * `exp` events), a fainted monster earns none, the level must go up (to at
   * most LEVEL_MAX), and no stat may go down (CalcStats is monotonic in the
   * level, and stat exp only grows) or past 999. With K7 on the sheet
   * (`base`, `dvs`, `statExp` -- the monster's own, pre-Transform) each stat
   * must also be at most what CalcStat gives at the new level with full stat
   * exp, and a claim that states no stats is computed from them with the
   * sheet's stat exp; without K7 and without stats only the level moves.
   */
  levelUp(playerId, monIndex, level, stats, maxHp) {
    try {
      return this._levelUp(playerId, monIndex, level, stats, maxHp) === true;
    } catch (err) {
      return false;
    }
  }

  _levelUp(playerId, monIndex, level, stats, maxHp) {
    if (this.result || !EXP_MODES[this.mode]) return false;
    const fighter = this.byId.get(str(playerId) || '');
    if (!fighter || fighter.side !== EXP_OWNER_SIDE) return false;
    const index = int(monIndex, null);
    const mon = index !== null ? monAt(fighter, index) : null;
    if (!mon || mon.hp <= 0) return false;
    const newLevel = int(level, null);
    if (newLevel === null || newLevel <= mon.level || newLevel > LEVEL_MAX) return false;

    // The monster's own species and DVs, not a Transform's copies.
    const own = mon.preTransform || mon;
    const base = own.base;
    const dvs = own.dvs;
    const statExp = mon.statExp;
    const k7 = isTable(base) && isTable(dvs);
    const exp = (key) => (isTable(statExp) ? int(statExp[key], 0) : 0);

    let newStats = null;
    if (isTable(stats)) {
      newStats = {};
      for (const key of Effects.BATTLE_STATS) {
        const n = int(stats[key], null);
        if (n === null) return false;
        newStats[key] = n;
      }
    } else if (stats !== null && stats !== undefined) {
      return false;
    } else if (k7) {
      newStats = {};
      for (const key of Effects.BATTLE_STATS) {
        newStats[key] = Effects.calcStat(base[key], dvs[key], newLevel, exp(key), false);
      }
    }
    let newMaxHp = null;
    if (maxHp !== null && maxHp !== undefined) {
      newMaxHp = int(maxHp, null);
      if (newMaxHp === null) return false;
    } else if (k7) {
      newMaxHp = Effects.calcStat(base.hp, Effects.hpDv(dvs), newLevel, exp('hp'), true);
    }

    if (newStats) {
      for (const key of Effects.BATTLE_STATS) {
        const n = newStats[key];
        if (n < int(mon.partyStats[key], 1) || n > Effects.MAX_STAT_VALUE) return false;
        if (k7 && n > Effects.calcStat(base[key], dvs[key], newLevel, LEVEL_UP_STAT_EXP_MAX, false)) {
          return false;
        }
      }
    }
    if (newMaxHp !== null) {
      if (newMaxHp < mon.maxHp || newMaxHp > Effects.MAX_STAT_VALUE) return false;
      if (k7 && newMaxHp > Effects.calcStat(base.hp, Effects.hpDv(dvs), newLevel,
        LEVEL_UP_STAT_EXP_MAX, true)) {
        return false;
      }
    }

    mon.level = newLevel;
    let grew = 0;
    if (newMaxHp !== null) {
      grew = newMaxHp - mon.maxHp;
      mon.maxHp = newMaxHp;
      mon.hp = Math.min(mon.maxHp, mon.hp + grew);
    }
    if (newStats) {
      for (const key of Effects.BATTLE_STATS) {
        mon.partyStats[key] = newStats[key];
        if (!mon.transformed) mon.stats[key] = newStats[key];
      }
    }
    if (fighter.active === index) {
      Effects.recalcBattleStats(mon, fighter.badges);
      // The HP bar the seat opposite draws: what it grew by, out of what.
      if (grew > 0) {
        this._emit('drain', {
          slot: fighter.slot, side: fighter.side,
          amount: grew, hp: mon.hp, maxHp: mon.maxHp,
        });
      }
    }
    return true;
  }

  // ----------------------------------------------------------------
  // the clock
  // ----------------------------------------------------------------

  disconnect(playerId) {
    const fighter = this.byId.get(str(playerId) || '');
    if (!fighter || !fighter.connected) return false;
    if (this.result) return false;

    fighter.connected = false;
    fighter.graceEndsAt = this.now + this.reconnectGrace;
    this._emit('wait', { side: fighter.side, text: fighter.name });
    return true;
  }

  // Back inside the window continues the fight from where it paused, and the
  // choice deadline restarts rather than resuming: the player who reconnects
  // with two seconds left on a clock they could not see would be choosing under
  // a timer the drop created.
  reconnect(playerId) {
    const fighter = this.byId.get(str(playerId) || '');
    if (!fighter || fighter.connected) return false;
    if (this.result) return false;
    if (fighter.graceEndsAt !== null && this.now >= fighter.graceEndsAt) return false;

    fighter.connected = true;
    fighter.graceEndsAt = null;
    this._emit('reconnect', { side: fighter.side, text: fighter.name });

    if ((this.phase === 'choice' || this.phase === 'replace')
        && !this._anyDisconnected() && this.choiceTimeout > 0) {
      this.deadline = this.now + this.choiceTimeout;
    }
    // A leftover or forced fill was held open by `_maybeResolve`'s disconnect
    // gate; close it now that everyone is back.
    this._maybeResolve();
    return true;
  }

  /*
   * Advances the wall clock and fires whatever it has passed. Returns true when
   * something actually happened, so a hub can skip a drain on a quiet tick.
   *
   * Time only moves forward: a caller handing back an earlier `now` -- two
   * sources of time on a hub, a clock that stepped -- must not un-expire a
   * grace period that already ran.
   */
  tick(nowSeconds) {
    const now = int(nowSeconds, this.now);
    if (now > this.now) this.now = now;
    if (this.result) return false;

    // A side that is already down must not sit out a choice window. Solo's
    // clock is 0, so a faint that left the field in `choice` used to wait
    // forever for an answer nobody can file -- the band on "Waiting for WILD...".
    if ((this.phase === 'choice' || this.phase === 'replace') && this._checkOver()) {
      return true;
    }

    // Forced-only turns opened by the previous resolve wait here so one drain
    // does not swallow a whole trap / recharge / thrash chain. Keep the flag
    // while a seat is away; reconnect()'s `_maybeResolve` closes the turn.
    if (this.forcedPending && this.phase === 'choice' && !this._anyDisconnected()) {
      this.forcedPending = false;
      if (!this._anyoneOwes()) {
        this._maybeResolve();
        return true;
      }
    }

    let expiredA = false;
    let expiredB = false;
    for (const fighter of this.fighters) {
      if (!fighter.connected && fighter.graceEndsAt !== null
          && this.now >= fighter.graceEndsAt) {
        if (fighter.side === 'a') expiredA = true; else expiredB = true;
      }
    }

    if (expiredA || expiredB) {
      if (expiredA && expiredB) {
        this._finish('draw', null, null, 'disconnect');
      } else if (expiredA) {
        this._finish('forfeit', this._sidePlayers('b'), this._sidePlayers('a'), 'disconnect');
      } else {
        this._finish('forfeit', this._sidePlayers('a'), this._sidePlayers('b'), 'disconnect');
      }
      return true;
    }

    // A turn left in `resolving` -- typically after a throw the hub contained --
    // has no player to wait on, so the ceiling is the only way out. `timeout` is
    // the existing reason: sanitize already phrases it, and a stuck resolve is not
    // something a screen can usefully distinguish from an unanswered turn.
    if (this.phase === 'resolving' && this.resolveDeadline !== null
        && this.now >= this.resolveDeadline) {
      this._finish('draw', null, null, 'timeout');
      return true;
    }

    // The choice clock is suspended while anybody is away; the grace above is
    // the only deadline running for them.
    //
    // The replace phase runs on the same clock, and has to: a seat that owes a
    // send-out and never answers would otherwise hold the field forever, with
    // no turn open for the deadline that used to cover it. `_autoChoice`
    // already answers a `mustReplace` seat with a bench switch (it is the
    // branch the NPC side takes), so the same sweep that fills an unanswered
    // move fills an unanswered replacement, `_maybeResolve` closes the phase,
    // and the fight carries on one monster down rather than wedging.
    if ((this.phase === 'choice' || this.phase === 'replace')
        && this.deadline !== null && this.now >= this.deadline
        && !this._anyDisconnected()) {
      for (const fighter of this.fighters) {
        if (this._owes(fighter)) {
          const auto = this._autoChoiceOrSkip(fighter);
          if (auto) {
            fighter.choice = auto;
            this._emit('chose', {
              slot: fighter.slot, side: fighter.side, text: fighter.name,
            });
            this._say(`${fighter.name} ran out of time`);
          }
        }
      }
      this._maybeResolve();
      // A fighter with nothing left to auto-pick would leave the turn open on a
      // deadline already in the past, and every later tick would announce the
      // timeout again. Push the clock instead: the fight waits one more window
      // rather than filling the log.
      if ((this.phase === 'choice' || this.phase === 'replace')
          && this.deadline !== null && this.now >= this.deadline) {
        this.deadline = this.now + this.choiceTimeout;
      }
      return true;
    }

    return false;
  }

  // ----------------------------------------------------------------
  // snapshot
  // ----------------------------------------------------------------
  //
  // For tests and for a log line, not for a client: a client is sent events.
  // Everything here is a copy, so a caller poking at it cannot reach into the
  // field.
  snapshot() {
    const field = [];
    const waiting = [];

    for (const fighter of this.fighters) {
      const mon = activeMon(fighter);

      field.push({
        slot: fighter.slot,
        side: fighter.side,
        playerId: fighter.playerId,
        name: fighter.name,
        connected: fighter.connected,
        graceEndsAt: fighter.graceEndsAt,
        chose: fighter.choice ? fighter.choice.action : null,
        mustReplace: fighter.mustReplace === true,
        species: mon ? mon.species : null,
        hp: mon ? mon.hp : 0,
        maxHp: mon ? mon.maxHp : 0,
        status: mon && mon.status && has(STATUS_TO_WIRE, mon.status)
          ? STATUS_TO_WIRE[mon.status] : null,
        party: fighter.mons.map((entry) => entry.hp),
      });
      if (this._owes(fighter)) waiting.push(fighter.playerId);
    }

    return {
      battle: this.id,
      mode: this.mode,
      phase: this.phase,
      turn: this.turn,
      seq: this.seq,
      now: this.now,
      deadline: this.deadline,
      resolveDeadline: this.resolveDeadline,
      over: this.result !== null,
      reason: this.result ? this.result.reason : null,
      rngState: this.rng.state(),
      field,
      waiting,
    };
  }
}

// ------------------------------------------------------------------
// construction
// ------------------------------------------------------------------

/*
 * attempt(opts) -> { battle, reason }
 *
 * opts:
 *   id, mode, seed, chart, chartOrder, specialTypes, typeIds, metronomePool,
 *   choiceTimeout, reconnectGrace, resolveTimeout, now
 *   sides = { a: [ { playerId, name, mons, bag, badges } ], b: [ ... ] }
 *   (a computer trainer seat's entry also carries `aiMods` and `aiClass`;
 *   the computer's `bag` is not kept)
 *
 * `typeIds` is the chart's axis by name (MediatedBattle.snapshotRuleset:
 * `typeIds[i]` names chart index i). Red's referee asks it four questions and
 * keeps only the answers: which index is POISON (PoisonEffect turns a
 * Poison-type target away), which is FIRE (CheckDefrost thaws on a Fire
 * move), and which are NORMAL and FIGHTING (HandleCounterMove strikes back
 * only at those two). Without it POISON and FIRE cannot be named -- a side
 * effect can poison a Poison-type monster and nothing thaws -- and NORMAL and
 * FIGHTING fall back to pokered's own indices, 0 and 1
 * (constants/type_constants.asm), the axis the synthetic STRUGGLE's type 0
 * already assumes.
 *
 * `chartOrder` is the type chart as the cart walks it: TypeEffects' rows in
 * table order, a flat list of chart-index pairs [atk1, def1, atk2, def2, ...]
 * (`chartRowsOf`), each row's multiplier the `chart` cell it names.
 * AdjustDamageForMoveType applies the matching rows in order, flooring after
 * each, and leaves the LAST one's multiplier in wDamageMultipliers -- what
 * DisplayEffectiveness and PrintMoveFailureText read (`_typeRows`). Absent or
 * unreadable it is null and the chart is read per defender type, the product
 * stated, as it always was.
 *
 * `badges` is kept only on side a of a BADGE_MODES fight and dropped
 * everywhere else, silently: a PvP upload that carries one is a well-formed
 * upload the cart would simply not have boosted.
 *
 * A reason and not a throw: the caller is a session handler that has a client
 * waiting to be told why. `create` is the same thing for a caller that only
 * wants the battle.
 */
function attempt(opts) {
  const refuse = (reason) => ({ battle: null, reason });

  if (!isTable(opts)) return refuse('battle needs an options table');

  const self = new Battle(opts);

  const sides = isTable(opts.sides) ? opts.sides : {};
  for (const side of SIDES) {
    const roster = Array.isArray(sides[side]) ? sides[side] : [];
    if (roster.length === 0) return refuse(`side ${side} has nobody on it`);
    const sideMax = maxFighters(self.mode, side);
    if (roster.length > sideMax) {
      return refuse(`side ${side} has more fighters than ${self.mode} allows`);
    }
    // Hub opens coop_wild for 2 or 3 humans; a lone human is a solo wild.
    if (self.mode === 'coop_wild' && side === 'a' && roster.length < 2) {
      return refuse('side a has fewer fighters than coop_wild allows');
    }
    for (let index = 1; index <= roster.length; index += 1) {
      const entry = roster[index - 1];
      if (!isTable(entry)) return refuse(`side ${side} has a malformed fighter`);

      const playerId = str(entry.playerId);
      if (!playerId) return refuse(`a fighter on side ${side} has no playerId`);
      if (self.byId.has(playerId)) return refuse(`duplicate playerId ${playerId}`);

      const mons = [];
      if (Array.isArray(entry.mons)) {
        for (const raw of entry.mons) {
          if (mons.length >= MONS_PER_PARTY) break;
          const mon = copyMon(raw, mons.length);
          if (mon) mons.push(mon);
        }
      }
      if (mons.length === 0) return refuse(`${playerId} brought no monsters`);

      // The cart's player in a fight against the computer, exactly as
      // battle3's `create` decides it: side a of a BADGE_MODES fight. Kept
      // beside `badges` because a player with no badges at all is the one
      // with the most to disobey.
      const badgeRules = side === BADGE_SIDE && has(BADGE_MODES, self.mode);
      // The computer's seat (`isComputerSeat`) and, of those, the trainer's
      // -- the seat TrainerAI runs for (`_runsTrainerAi`).
      const computer = isComputerSeat(self.mode, { side });
      const trainer = computer && !Effects.isWildMode(self.mode);
      // Its class record, copied (K16); an unreadable one refuses the fight,
      // as Wire refuses the party that carries it.
      let aiClass = null;
      if (trainer && entry.aiClass != null) {
        aiClass = copyAiClass(entry.aiClass);
        if (!aiClass) return refuse(`${playerId} brought an unreadable aiClass`);
      }
      const fighter = {
        playerId,
        name: str(entry.name) || playerId,
        side,
        index,
        slot: Events.fieldSlot(side, index),
        mons,
        badgeRules: badgeRules || null,
        badges: seatBadges(self.mode, side, entry.badges),
        // A player's bag; the computer's choices never read one (K16: its
        // items are TrainerAI's, a wild monster has none), so none is kept.
        bag: !computer ? copyBag(entry.bag) : null,
        active: firstLiving(mons),
        connected: true,
        graceEndsAt: null,
        choice: null,
        // The roster last published for this seat (`_syncTeams`). null rather
        // than the opening string, so the first sync always publishes.
        team: null,
        // Who has been in against THIS seat's current monster; see `_refield`.
        fought: Object.create(null),
        // The trainer's move-choice layers (`_cartMovePick`), the computer's
        // trainer seat only; null is no layer at all.
        aiMods: trainer ? copyAiMods(entry.aiMods) : null,
        // wAILayer2Encouragement (`_cartMovePick`, `_resolveFights`), the
        // computer's seats: 0 at InitBattleVariables.
        aiLayer2: 0,
        // The trainer's TrainerAI record (K16, `_trainerAi`), the trainer
        // seat only; null is GenericAI.
        aiClass,
        // wAICount: InitBattle's $ff (core.asm :6685-6686), reloaded from
        // the record at the first TrainerAI call and $ff again at each
        // send-out (`_switchIn`).
        aiCount: AI_COUNT_RELOAD,
      };
      // Every monster's battle stats, seeded the way LoadBattleMonFromParty
      // seeds them (the unmodified stats, the condition penalty, this seat's
      // badges), so a bench monster is as ready as the fielded one; a
      // switch-in re-runs the whole load anyway (`_resolveSwitches`).
      for (const mon of mons) Effects.recalcBattleStats(mon, fighter.badges);
      self.fighters.push(fighter);
      self.byId.set(playerId, fighter);
      self.bySide[side].push(fighter);
    }
  }

  // Everybody is fielded at once, so the opening participation sets are the
  // opening field. `_refield` re-adds the standing opposition every time it
  // runs, so walking the roster once is enough: a later seat's reset cannot
  // lose an earlier seat's entry, it re-derives it.
  for (const fighter of self.fighters) self._refield(fighter);

  // `mon` is the party index the referee itself fielded (here: `firstLiving`),
  // zero-based like the `exp` event's. A client cannot re-derive it from `text`:
  // a party may hold the same species twice, and resolving the name against the
  // party then picks whichever copy comes first -- which is how a fainted
  // duplicate came back onto the field. The index is unambiguous.
  for (const fighter of self.fighters) {
    const mon = activeMon(fighter);
    if (mon) {
      self._emit('send', {
        slot: fighter.slot, side: fighter.side, hp: mon.hp, maxHp: mon.maxHp,
        text: mon.species,
        speciesId: mon.speciesId, level: mon.level,
        mon: fighter.active - 1,
        status: mon.status && has(STATUS_TO_WIRE, mon.status)
          ? STATUS_TO_WIRE[mon.status] : undefined,
        confused: (mon.confusion && mon.confusion > 0) ? 1 : undefined,
      });
    }
  }

  self._openTurn();
  return { battle: self, reason: null };
}

// The battle, or null when it was refused. `attempt` carries the reason.
function create(opts) {
  return attempt(opts).battle;
}

module.exports = {
  VERSION,
  create,
  attempt,
  Battle,
  MONS_PER_PARTY,
  FIGHTERS_PER_SIDE,
  CHOICE_TIMEOUT,
  RECONNECT_GRACE,
  RESOLVE_TIMEOUT,
  TIE_BREAK_ROLL,
  AIM_SEED_OFFSET,
  DEFAULT_NPC_BAG,
  MODES,
  SIDES,
  BADGE_MODES,
  BADGE_SIDE,
  PAY_DAY_MAX,
  RUN_ROLL_MODES,
  CHART_ORDER_MAX,
  MAX_AI_MODS,
  AI_USES_MAX,
  AI_CHANCE_MAX,
  AI_DIVISOR_MAX,
  AI_COUNT_RELOAD,
  AI_GENERIC_USES,
  LEVEL_MAX,
  STATUS_FROM_WIRE,
  STATUS_TO_WIRE,
};
