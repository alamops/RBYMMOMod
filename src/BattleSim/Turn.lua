-- The turn machine: choices in, events out, and one party deciding.
--
-- The formula modules beside this one each answer a single question with no
-- memory.  This is the thing that holds the fight: it owns the field, the
-- clock, the RNG stream and the order the questions get asked in, and it is
-- the only file in src/BattleSim/ with state.  A battle brokered here is
-- resolved by *one* process -- the LAN host or the Node hub -- and the clients
-- receive an ordered stream of events they draw.  They are never asked what
-- happened, which is the whole reason a modified client cannot roll its own
-- damage any more.
--
-- **The RNG order is the contract.**  The twin under server/lib/battle/ has to
-- consume draws at exactly the same points or the same seed produces a
-- different fight, so every draw site is spelled out here and every one of
-- them is conditional in a way both runtimes can reproduce:
--
--   0. a coop_wild RUN's escape byte, before anything else in the turn
--      (TryRunningFromBattle runs in DisplayBattleMenu: `_tryRun`) -- none
--      for a runner at least as fast as the wild monster, or past the odds;
--      then the players' switches and items (a ball's catch bytes);
--   0b. the computer's move choice, where MainInBattleLoop's
--      `.selectEnemyMove` runs SelectEnemyMove (`_selectComputerMoves`), per
--      computer seat in field order: `.chooseRandomMove`'s byte(s), redrawn
--      past an empty or disabled slot -- after a trainer's AI layers
--      (`_aiTrainerMoves`), which draw nothing -- and none at all for a
--      forced turn, a monster asleep or frozen, or one knowing a single
--      disabled move (STRUGGLE);
--   1. a speed tie-break byte, one per group of actors in one priority
--      bracket at one Speed -- and every battler on the field is an actor
--      there, whatever its seat chose: a switch, an item, a recharge, a held
--      monster's CANNOT_MOVE all take part in MainInBattleLoop's compare
--      (`_resolveFights`), and the computer's item or switch is spent in its
--      slot (`_computerTurnAction`);
--   2. the gates, in CheckPlayerStatusConditions' order (`_runGates`): sleep
--      and freeze draw nothing (neither check calls BattleRandom), the
--      confusion check draws its self-hit byte only for a monster still
--      confused after the counter's step (the snap-out turn draws none), and
--      paralysis its byte;
--   3. a Bide store or unleash draws nothing; a thrash's last turn draws its
--      confusion length; a trap's later turns draw nothing (`_trapTurn`);
--   4. the obedience rolls of a traded monster over its trainer's badge cap
--      (`_obey`, Status' obedience section: CheckForDisobedience's loops, the
--      instead-move, nap and loaf draws) -- a fight with no traded monster on
--      the player's side draws none of them;
--   5. per move that is actually used, PlayerCalcMoveDamage's order:
--      THRASH's or a trapping move's counter (SpecialEffectsCont, before
--      anything else); then CriticalHitTest's byte (none at power 0); the
--      damage roll -- only for a damage of 2 or more after the type chart
--      (RandomizeDamage's `cp 2` / `ret c`: an immunity or a hit already at 0
--      or 1 draws none); and only then MoveHitTest's accuracy byte
--      (`_hitTest`: none for DREAM EATER into a waking target, SWIFT, an
--      invulnerable or a Misted target, X Accuracy) -- drawn for an immunity
--      or a 0.25x zero too, which AdjustDamageForMoveType only flags.  So a
--      move that misses has spent its crit byte and its roll.  Then, after the
--      first hit, the two-to-five count byte(s) (TwoToFiveAttacksEffect: one,
--      or two when the first is a 2 or 3; none when that hit broke a
--      Substitute), then the side-chance byte (damaging hits only).  An OHKO
--      move into a faster target misses after its crit byte and draws nothing
--      else (OneHitKOEffect_).  COUNTER draws its crit byte, then -- when its
--      conditions hold (`_counterDamage`) -- its accuracy byte; SUPER FANG and
--      the SPECIAL_DAMAGE moves draw the accuracy byte and nothing else but
--      PSYWAVE's loop.  A power-0 move draws only what its own routine draws
--      (`_statusMove`, Effects.statusPlan): most draw nothing at all, and
--      SleepEffect, ParalyzeEffect_, PoisonEffect and ConfusionEffect check
--      what turns a target away before their accuracy byte.  The
--      side-chance byte is the effect's own pokered routine's, drawn where
--      and when that routine draws it (Effects.applySide): never on a target
--      that fainted or a Substitute the move broke, not by a poison / burn /
--      freeze / paralysis / flinch / stat-drop routine whose target it
--      already turned away (a Substitute, a status, a type), and behind the
--      computer's extra stat-drop miss byte when the computer drops a stat.
--
-- Nothing else rolls.  Residuals, switches, items and the clock are all
-- deterministic, so a battle replays from its seed plus the choice log.
--
-- **Policies chosen where Gen 1 had no answer**, each one written down because
-- the two runtimes have to pick the same one:
--
--   * *Turn order* is pokered's MainInBattleLoop widened to a field: the
--     priority bracket first (Effects.movePriority: QUICK_ATTACK +1, COUNTER
--     -1, read off the *selected* move -- last turn's for a monster asleep or
--     frozen, `_selectionOf`), then Speed (the stored battle stat), then the
--     tie-break below (`_orderActors`).  The players' switches and items
--     resolve before any move, as DisplayBattleMenu runs them before the
--     order is even asked (a link fight's opponent switches at
--     `.selectEnemyMove`, before the moves too) -- but the seat still takes
--     part in the compare, at its monster's Speed then, in the base bracket
--     (its selection is the menu cursor's, which the referee cannot name).
--     The computer's item or switch is spent in its own slot of the order:
--     TrainerAI runs at `.enemyMovesFirst` / `.playerMovesFirst`, so it is an
--     actor there (`_computerTurnAction`), in the bracket of the move
--     SelectEnemyMove picked before TrainerAI threw it away (`picked`).
--   * *Speed ties* break on a single RNG byte per tied group: below 128 the
--     side-a member goes first, otherwise the group reverses.  One draw per
--     group rather than per pair, so a 2v2 with four equal speeds costs one
--     byte on both runtimes.  A group is one bracket at one Speed, so a fight
--     with no Quick Attack or Counter groups -- and draws -- exactly as Speed
--     alone.
--   * *Running* is mode-gated, the same way Teleport is.  wild / coop_wild
--     flee (the runner loses with reason `run`); 1v1 / coop_pvp is a
--     concession, same bookkeeping, and both sides running is a draw;
--     coop_npc -- and any other non-wild non-pvp mode -- refuses the RUN at
--     the menu, as the cart's `.trainerBattle` sends it back to
--     DisplayBattleMenu with the turn unspent: nothing is filed, the seat
--     still owes, and the NoRunningText line is the client's own
--     (`_normaliseChoice`).  Mirrored: the policy reads the same from either
--     seat.  A
--     coop_wild runner rolls TryRunningFromBattle's odds first (`_tryRun`,
--     M.RUN_ROLL_MODES): its own attempt counter, one byte, "Can't escape!"
--     and the turn spent on a miss.  Solo's `wild` is rolled by its client
--     (src/SoloBattle.lua `_escapes`) before the run is filed, so the
--     referee does not roll it a second time.
--   * *Items* apply a hand-authored Gen1 heal/status table by id (Potion,
--     Full Restore, Revive, Ether, …) — locked twin of public amounts, not a
--     port of engine ItemEffects. Unknown ids say ItemUseNoEffect's "It won't
--     have any effect." and still spend the turn.  A known item the cart's
--     ItemUseFailed would hand back -- no effect, or not the time -- is
--     refused at the menu, unfiled, its bag stack and the turn kept
--     (`_itemFails`).  Bags are client claims (sheet trust locked; hub
--     has no ROM inventory truth); PROTOCOL 15 holds/spends mid-fight only.
--   * *Forced lock-in* (recharge, Rage, thrash, a charge's release) fills
--     choices on `_openTurn` so the mediated path never opens a menu the
--     cartridge would withhold; a turn where *nobody* still owes waits for
--     the next `tick` before resolving so clients see a turn boundary for
--     wait-lines / anim pacing.  Each forced turn then plays in the monster's
--     own slot of the order, past the gates CheckPlayerStatusConditions puts
--     first: a recharge (`_rechargeTurn`), a trap's later hits (`_trapTurn`:
--     the first hit's wDamage again, no re-rolled `_useMove`), a held
--     monster's CANNOT_MOVE (nothing at all).  A Bide user, a trapper and a
--     held monster get the battle menu on the cart (MainInBattleLoop runs
--     DisplayBattleMenu before it looks at STORING_ENERGY, USING_TRAPPING_MOVE
--     or the foe's trap), so a *player's* seat is asked there like any other
--     and its FIGHT -- which opens no move menu -- is the lock-in
--     (`_menuFight`); a switch, an item or a RUN is taken as it would be on
--     any turn.  The computer's seats are filled, as SelectEnemyMove fills
--     them, and re-pick once a player's switch or item let their trap go
--     (`_reselectComputer`).
--   * *Status moves* run through Effects.lua. Metronome picks from host-uploaded
--     `metronomePool` on the ruleset (from MediatedBattle.snapshotRuleset);
--     without a pool it says "But nothing happened".
--   * *Physical / Special* follow Gen1 type categories via host-uploaded
--     `specialTypes` on the ruleset (indices into the uploaded chart). Absent
--     specialTypes keeps every damaging move on atk/def.
--   * A *faint with a living bench opens the `replace` phase*, between the turn
--     it happened on and the next one.  The turn number does not move, no other
--     seat is asked, and nothing resolves until every owed send-out is in --
--     then `_resolveSwitches` fields them (`switch` + `send`) and the next turn
--     opens.  The choice window never opens over an empty box, which is what
--     the original does and what `CoopSim.announceFaint` does beside this.  It
--     is a second kind of choice phase, so it runs on the *same* clock: the
--     timeout sweep in `tick` covers it, and an unanswered replacement is
--     auto-picked exactly like an unanswered move.
--   * Solicitation for that phase is a `turn` event carrying the owing seat's
--     field `slot`, one per seat.  A `turn` with `slot` asks that seat for a
--     replacement; a `turn` without one opens the ordinary choice window.  No
--     new kind and no new field, so a client that ignores `slot` degrades to
--     the old behaviour instead of breaking.
--   * *Residuals* (HandlePoisonBurnLeechSeed) come at the end of each
--     battler's own slot, in the turn's order -- MainInBattleLoop's, core.asm
--     :413-467 (`_resolveFights`, `_residualFor`) -- and there is no
--     end-of-turn pass.  In a fight of one seat a side that is the cart's
--     exactly: a slot that knocked the foe out leaves for the faint's handler
--     before the knocker-out's residual, a monster its own slot or residual
--     took down ends the turn before the slower battler moves, and either
--     faint skips the turn's CheckNumAttacksLeft.  A 2v2 has no analog and
--     keeps the Gold referee's policy (src/BattleSim2/Turn.lua header): each
--     seat's residual right after its own slot, and every seat still acts
--     and takes its residual after a faint.
--   * The computer's MOVE is the cart's (`_computerChoice`): a wild monster's
--     `.chooseRandomMove`, a trainer's AIEnemyTrainerChooseMoves over the
--     layers its seat's `aiMods` names (none: the original move set) -- the
--     referee holds no class table; the client sends the class's layers.
--     Its item or switch, and a player's timeout, stay the heuristic below.
--   * A *timeout* / NPC auto-picks with bag cures & heals (≤50% HP), X-items,
--     SE damage, status / setup reading, and SE bench switches (deterministic
--     heuristics — not a full TrainerAI port) -- and the fight continues.  It
--     does not end the battle -- the player who went to make a sandwich loses
--     a turn, not the match.
--   * *Struggle* when every move is out of PP: synthetic STRUGGLE (power 50,
--     type normal), no PP spent, recoil floor(damage/2) minimum 1 after a hit
--     (RecoilEffect_'s `cp STRUGGLE`: half where RECOIL_EFFECT takes a
--     quarter), off the user's HP and never its own doll.
--     Struggle is the move, not the state of the user's PP: a Metronome or
--     Mirror Move call made with the last PP is the called move, recoil-free.
--   * *Obedience* is the player's, in a fight against the computer: a seat
--     with `badgeRules` (side a of M.BADGE_MODES, set in `create` as
--     BattleSim3 sets it) runs CheckForDisobedience for a monster whose sheet
--     says `traded`.  A link fight returns before the check on the cart
--     (LINK_STATE_BATTLING) and side b is the computer's own party, so
--     neither ever rolls.  The lines are the cart's English (`_obey`).
--   * *The flinch reset* at a turn's open (MainInBattleLoop) is skipped while
--     the player's monster is raging or must recharge.  "The player" is the
--     owner's rule (`isPlayerSeat`): side a against the computer, both sides
--     of a link fight -- per seat, for its own monster; the computer's seats
--     are reset unconditionally (`_openTurn`).
--   * *Battle stats are stored, not derived* -- pokered's own model, kept so
--     its rounding, caps and glitches come out exact.  Each monster carries
--     its party stats, its unmodified stats and its battle stats (`cur`);
--     Effects.lua's "Stored battle stats" note says who writes which.  A
--     switch-in loads party -> burn/paralysis penalty -> badges and zeroes
--     every stage, as does a faint; a stage change rebuilds one stat; the
--     badge-stacking and re-penalty glitches ride `Effects.changeStat`, the
--     one door every stage change goes through.  Speed, damage and the
--     confusion self-hit read `cur` and add nothing at read time; a critical
--     hit reads the party stats at both ends and no screen.
--   * *"The enemy" in a 2v2.*  Gen 1 has one opponent, so where the cart
--     reads "the battler whose turn it is not" the referee names one: a
--     move's stage change re-penalises the seat the action was aimed at (for
--     a drop, the lowered monster itself), Rage the attacker, an X item and
--     the confusion self-hit's Reflect check the battler opposite
--     (`_oppositeFoe`: the same position across, else the nearest).
--   * *One narrator, two screens* (contracts K17 / K18).  Where the cart
--     prints a battler's name through <USER> / <TARGET> or an "Enemy @"
--     line, the `msg` carries the battler's side mark before the name
--     (`named`, Events.named: `^a` / `^b`), and each client prints nothing for
--     its own side and "Enemy " for the other; a name the cart prints bare
--     stays bare.  A `\n` is the cart's `line` / `cont` / <SCROLL>; a `para`
--     is a `msg` of its own.  Any other event's `text` is the line read plain
--     (Events.plain), as it always was.
--   * *A knockout faints after the move* (K19): HP reaches 0 where the cart
--     takes it, and the `faint` -- with everything `_faint` does: the exp
--     owed, wBattleResult, the unfielding -- waits for the end of the slot
--     (`_reapKo`), where MainInBattleLoop tests the HP once Execute*Move has
--     returned.  Two at once go side a first, the player's (FaintEnemyPokemon
--     removes the player's monster before its own line).  A residual's
--     knockout is its pass's own (`_residualFor`).
--   * The choice clock is *suspended while anybody is disconnected*, because
--     the grace timer is already counting for that player and two deadlines
--     racing would decide the match on whichever fired first.  `submitChoice`
--     also refuses a seat whose `connected` is false until `reconnect()`, so a
--     socket that is still delivering (SESSION_LEAVE) cannot resolve turns
--     through the pause.  `_maybeResolve` waits on the same flag, so a leftover
--     or forced fill from before the drop cannot complete the turn while anyone
--     is away; `reconnect()` asks it again.
--
-- Nothing here raises.  Bad input is refused with a nil-plus-reason from
-- `create` or a plain `false` from `submitChoice`, because every caller is
-- downstream of a mod callback where a bare error() is a loader rule
-- violation -- and a fight that stops mid-turn is worse than one that declines
-- a malformed choice.
--
-- No love, no engine modules, no mod facade.

local need = ...

local Damage   = need("BattleSim/Damage")
local Accuracy = need("BattleSim/Accuracy")
local Crit     = need("BattleSim/Crit")
local Status   = need("BattleSim/Status")
local Effects  = need("BattleSim/Effects")
local Rng      = need("BattleSim/Rng")
local Events   = need("BattleSim/events")

local M = {}

local floor, max, min = math.floor, math.max, math.min

M.VERSION = 1

-- Mirrored from Config rather than required, for the reason in events.lua:
-- this directory runs where Config does not.
M.MONS_PER_PARTY      = 6     -- Config.BATTLE_MON_MAX
M.FIGHTERS_PER_SIDE   = 3     -- Config.COOP_SIDE
M.CHOICE_TIMEOUT      = 60    -- Config.BATTLE_CHOICE_TIMEOUT
M.RECONNECT_GRACE     = 60    -- Config.BATTLE_RECONNECT_GRACE
M.RESOLVE_TIMEOUT     = 30    -- Config.BATTLE_RESOLVE_TIMEOUT

-- Below this the side-a member of a tied group moves first.
M.TIE_BREAK_ROLL = 128

-- Where the aim stream starts, relative to the battle's own seed.  See
-- `_autoTarget`: the referee's choice of *whom* to swing at is drawn from a
-- second generator so that adding it moved no roll in the first one, and a
-- second generator started on the same number would be the same sequence
-- read twice -- every aim would echo a damage roll.  The offset is arbitrary
-- and load-bearing only in that both runtimes use it.
M.AIM_SEED_OFFSET = 1597334677

M.MODES = {
  ["1v1"] = true, coop_npc = true, coop_pvp = true, wild = true, coop_wild = true,
}
M.SIDES = { "a", "b" }

-- The modes an uploaded `badges` set counts in, and the one side it counts on.
--
-- The fights against the computer, on the player's seats, because that is the
-- only place the cart applies the x9/8 boosts at all: pokered's
-- ApplyBadgeStatBoosts (engine/battle/core.asm) returns before it reads a
-- badge when wLinkState is LINK_STATE_BATTLING ("return if link battle"), and
-- walks wBattleMon -- the player's monster -- and nothing else.  1v1 and
-- coop_pvp are link battles in everything but the cable, so both sides fight
-- them unboosted, as the engine's own cable battle does (it builds its
-- battlers with save = nil, gen1recomp src/link/LinkBattle.lua:61-68).  Side b
-- of the other three is the synthetic wild / trainer seat (see EXP_MODES on
-- `_awardExp`), which no cart boosts, so a set uploaded for it is a confused
-- or a hostile client and is dropped the same way.
--
-- The referee is the gate rather than the client or the hub: a client can
-- forge an upload and a hub passes `badges` through untouched, and this is the
-- one place both hubs and solo share.  It is applied once, in `create`, where a
-- seat's set is copied -- every reader after that (`_speedOf`, both ends of the
-- damage step) sees nil and needs no gate of its own.
M.BADGE_MODES = { wild = true, coop_wild = true, coop_npc = true }
M.BADGE_SIDE = "a"

-- wTotalPayDayMoney is three BCD bytes, and AddBCD saturates at 999999
-- (engine/math/bcd.asm).  `_checkOver`.
M.PAY_DAY_MAX = 999999

-- The modes whose RUN the referee rolls (`_tryRun`, TryRunningFromBattle).
-- coop_wild only: a solo `wild` RUN is rolled by its client before it is
-- filed (src/SoloBattle.lua `_escapes`, off this battle's own RNG), and a
-- second roll here would halve the odds the cart gives.
M.RUN_ROLL_MODES = { coop_wild = true }

-- How many TypeEffects rows a ruleset's `chartOrder` may name (pokered's
-- table has 82; a chart is at most 16 types wide, so 256 cells).
M.CHART_ORDER_MAX = 256

-- Roster cap per side. coop_wild is humans vs one wild (up to FIGHTERS_PER_SIDE
-- humans on a, wild on b); other modes keep a single per-side ceiling
-- (1 for 1v1/wild, FIGHTERS_PER_SIDE otherwise).
local function maxFighters(mode, side)
  if mode == "coop_wild" then
    return (side == "a") and M.FIGHTERS_PER_SIDE or 1
  end
  if mode == "1v1" or mode == "wild" then return 1 end
  return M.FIGHTERS_PER_SIDE
end

-- The wild monster's seat.  Wildlife is always the synthetic side-b seat of a
-- mode whose name says "wild" (the seat `maxFighters` caps at one above and
-- `_awardExp` pays the other side for), and wildlife carries no bag: a wild
-- monster never uses an item, no matter who asks on its behalf.  Both askers
-- are gated -- `_normaliseChoice` refuses a submitted one, `_autoItemChoice`
-- never picks one -- because the seat can be driven from either end.
local WILD_SIDE = "b"

local function isWildSeat(mode, fighter)
  return fighter ~= nil and fighter.side == WILD_SIDE
    and Effects.isWildMode(mode)
end

-- The computer's own seat: side b of a fight against the computer, the one
-- side M.BADGE_MODES never boosts.  Where the cart runs one routine for the
-- player and another for its AI -- a status cure is the case: ItemUseMedicine
-- rewrites the battle stats, AICureStatus does not -- this is the seat that
-- takes the AI's.  Every other seat (side a there, both sides of a link
-- fight) is a player on its own cartridge.
local function isComputerSeat(mode, fighter)
  return fighter ~= nil and M.BADGE_MODES[mode] == true
    and fighter.side ~= M.BADGE_SIDE
end

-- "The player", by the owner's rule (docs/plans/gen12-referee-gaps-fix.md):
-- a cart rule that touches only the player's side applies to side a against
-- the computer and to BOTH sides of a link fight (1v1, coop_pvp) -- each
-- player's own cart running it for its own monster.  Every seat that is not
-- the computer's.  (Obedience and the badges stay on `badgeRules`: the cart
-- returns before both in a link battle.)
local function isPlayerSeat(mode, fighter)
  return fighter ~= nil and not isComputerSeat(mode, fighter)
end

-- Wire spells a condition as a three-letter token and Status.lua spells it as
-- a word.  Both are accepted on the way in and the token is what goes back out
-- on an event, so neither vocabulary leaks into the other's file.
M.STATUS_FROM_WIRE = {
  SLP = "sleep", PSN = "poison", BRN = "burn",
  FRZ = "freeze", PAR = "paralysis", TOX = "toxic",
}
M.STATUS_TO_WIRE = {
  sleep = "SLP", poison = "PSN", burn = "BRN",
  freeze = "FRZ", paralysis = "PAR", toxic = "TOX",
}

-- The conditions that can stop a move before it happens.  Confusion is not
-- here because in Gen 1 it is a volatile, not a status -- it rides on its own
-- counter and is gated separately, after this one.
local GATING = { sleep = true, freeze = true, paralysis = true }

local ACTIONS = {
  fight = true, item = true, switch = true, run = true, cancel = true,
}

-- Synthetic move used when every slot is out of PP.  Not in any move table.
local STRUGGLE = {
  id = "STRUGGLE", power = 50, accuracy = 255,
  type = 0, effect = 0, chance = 0,
}

-- The move a thrash's continuation animates (`.ThrashingAboutCheck` writes
-- THRASH into wPlayerMoveNum, core.asm :3529-3530): the `anim` event's id,
-- the move registry's own, as STRUGGLE's is above.
local THRASH_ANIM = "THRASH"

-- The sentences `.monDoesNothing` prints (pokered data/text/text_2.asm
-- _LoafingAroundText .. _IgnoredOrdersText), keyed by Status.LOAF_LINES, with
-- the monster's name in front -- the cart's English, punctuation included,
-- and its breaks (K18).  The name is wBattleMonNick, printed bare: only the
-- player's monster ever disobeys, so the cart has no "Enemy" form (K17).
local LOAF_TEXT = {
  loafing        = " is\nloafing around.",
  wont_obey      = " won't\nobey!",
  turned_away    = " turned\naway!",
  ignored_orders = "\nignored orders!",
}

-- ItemUseBall's misses by shake count (`.printMessage`, wPokeBallAnimData
-- $20 / $61 / $62 / $63: ItemUseBallText01..04) -- the cart's "#MON" is its
-- charmap's "POKé" ($54) and ends in the é ($BA) a Red `msg` now carries
-- (Wire.battleText), so POKéMON is spelled as the cart prints it.
local BALL_MISS_TEXT = {
  [0] = "You missed the\nPOKéMON!",
  [1] = "Darn! The POKéMON\nbroke free!",
  [2] = "Aww! It appeared\nto be caught!",
  [3] = "Shoot! It was so\nclose too!",
}

-- The party menu's line for a status cure, by item (ItemUseMedicine's
-- `lb bc, <ITEM>_MSG, ...`, party_menu.asm's AntidoteText .. FullHealText),
-- after the monster's name (wNameBuffer, the party menu's: bare, K17) and
-- with the menu text's breaks (K18).  FULL RESTORE at full HP is a FULL HEAL.
local CURE_TEXT = {
  ANTIDOTE    = " was\ncured of poison!",
  BURN_HEAL   = "'s\nburn was healed!",
  ICE_HEAL    = " was\ndefrosted!",
  AWAKENING   = "\nwoke up!",
  PARLYZ_HEAL = "'s\nrid of paralysis!",
  FULL_HEAL   = "'s\nhealth returned!",
}

-- An item's name in a sentence: its id's words, which are the cart's item
-- names (data/items/names.asm) -- "POKé BALL", "POKé DOLL", "POKé FLUTE" with
-- the é a Red `msg` carries (Wire.battleText), GUARD SPEC.'s stop.
local function itemLabel(id)
  local label = tostring(id or "ITEM"):gsub("_", " ")
  label = label:gsub("^POKE ", "POKé ")
  if label == "GUARD SPEC" then label = "GUARD SPEC." end
  return label
end

-- A battler's name the way the cart's <USER> / <TARGET> print it
-- (PlaceMoveUsersName / PlaceMoveTargetsName): the seat's side mark, then the
-- name (Events.named, contract K17).  Every marked name in this file comes
-- through here; a name the cart prints bare is `mon.species` as it is.
local function named(fighter, mon)
  return Events.named(fighter and fighter.side, mon and mon.species or "POKéMON")
end

-- ItemUseNoEffectText, "It won't have any\neffect." (text_6.asm).
local NO_EFFECT_TEXT = "It won't have any\neffect."
-- HurtItselfText (text_2.asm), the confusion self-hit's and a disobedient
-- monster's.
local HURT_ITSELF_TEXT = "It hurt itself in\nits confusion!"

-- ------------------------------------------------------------------
-- coercion
-- ------------------------------------------------------------------

local function int(value, fallback)
  local n = tonumber(value)
  if not n or n ~= n then return fallback end
  return floor(n)
end

local function str(value)
  if type(value) == "string" and value ~= "" then return value end
  return nil
end

local function copyMove(raw)
  if type(raw) ~= "table" then return nil end
  local pp = max(0, int(raw.pp, 0))
  local ppUps = max(0, min(3, int(raw.ppUps, 0)))
  -- The sheet's maximum as stated -- the cart's GetMaxPP over the move's base
  -- PP and its PP Ups -- even below `pp`: a slot past DecrementPP's wrap holds
  -- 63 PP over it, as the cart's byte does (the client uploads the byte the
  -- save holds), and raising the maximum to meet it hid GetMaxPP from every
  -- reader (Effects.restorePp's ETHER, the `moves` rows).  A sheet that
  -- states none keeps the old reading, its PP.
  local stated = int(raw.maxPp, nil)
  local maxPp = max(0, stated or pp)
  return {
    id       = str(raw.id) or "move",
    -- Optional (PROTOCOL 26), and absence is a real answer rather than a gap
    -- to fill: a sheet from a protocol-25 client states no name, and the
    -- sentences below fall back to the id exactly as they always did.
    name     = str(raw.name),
    pp       = pp,
    maxPp    = maxPp,
    -- ...and the base PP behind it, when the stated number is a GetMaxPP
    -- (Effects.basePpOf): what `stepPp` re-reads the maximum over once a wrap
    -- moves the PP Up bits.  false -- read, and none -- keeps the stated
    -- maximum fixed; nil is a row nobody read yet (`stepPp` reads it).
    basePp   = stated and Effects.basePpOf(maxPp, ppUps) or false,
    power    = max(0, int(raw.power, 0)),
    accuracy = max(0, int(raw.accuracy, 255)),
    type     = max(0, int(raw.type, 0)),
    effect   = max(0, int(raw.effect, 0)),
    chance   = max(0, int(raw.chance, 0)),
    -- Optional sheet flag. Absent is a protocol-era client; Slash then uses
    -- ordinary odds. The hub has no move table to recover it from.
    highCrit = raw.highCrit == true,
    -- K8: the PP Ups on the move, the top two bits of the cart's PP byte.
    -- Read where the cart reads the raw byte -- AnyMoveToSelect's disabled
    -- branch (`mustStruggle`) and DisableEffect's slot pick -- and nowhere
    -- else; 0 when the sheet states none.
    ppUps = ppUps,
  }
end

-- A K7 block (Wire.battleMon's `base` / `dvs` / `statExp`), whole or nil:
-- every key a number, clamped to `lo..hi`.  A block missing a key is a bug
-- on the sending side, and half a block would silently zero the rest.
local K7_BASE_KEYS = { "hp", "atk", "def", "spd", "spc" }
local K7_DV_KEYS = { "atk", "def", "spd", "spc" }
local function copyBlock(raw, keys, lo, hi)
  if type(raw) ~= "table" then return nil end
  local out = {}
  for _, key in ipairs(keys) do
    local n = int(raw[key], nil)
    if n == nil then return nil end
    out[key] = max(lo, min(hi, n))
  end
  return out
end

-- What a move is *called* in a sentence: the display name its sheet carried
-- (PROTOCOL 26), or its registry id when it carried none.
--
-- Prose only.  An `anim` event carries the **id** and has to keep carrying it
-- -- that is what a client looks the move animation and the move-menu label up
-- by -- so the two spellings are never interchangeable, and every call here is
-- a line somebody reads rather than a key something indexes.
local function moveLabel(move, fallback)
  fallback = fallback or "move"
  if type(move) ~= "table" then return fallback end
  return str(move.name) or str(move.id) or fallback
end

-- A defender with no stated types is type 0, which the chart lookup reads as
-- "whatever row 1 says" and, absent a chart, as neutral.  That is the right
-- default for a sim that must never refuse a party over a missing optional.
local function copyTypes(raw)
  if type(raw) ~= "table" then return { 0 } end
  local out = {}
  for i = 1, #raw do out[i] = max(0, int(raw[i], 0)) end
  if #out == 0 then return { 0 } end
  return out
end

-- Every monster is deep-copied on the way in, and that is load-bearing rather
-- than tidy: the caller's table is usually a party the client still owns and
-- redraws, and a sim that damaged it in place would make "run the same fixture
-- twice" produce two different fights -- which is exactly the property the
-- determinism suite is built to catch.
--
-- `slot` is the *sender's* party position for this monster, zero-based, the way
-- Wire.battleMon carries it -- and it is kept rather than dropped because a
-- switch names it.  The two numbers are the same only while every monster the
-- client uploaded survived the copy and landed in the same order, and neither is
-- guaranteed: a mon this file cannot describe is skipped, a party past
-- MONS_PER_PARTY is cut short, and a coop_npc trainer's team is dealt across two
-- seats before it ever gets here.  In all three the array index has moved and the
-- position on the player's own screen has not, so the position is what a choice
-- is matched against.  `fallback` is that index for a sender that stated none,
-- which keeps an ordinary party numbered exactly as it always was.
local function copyMon(raw, fallback)
  if type(raw) ~= "table" then return nil end

  local stats = type(raw.stats) == "table" and raw.stats or {}
  local maxHp = max(1, int(raw.maxHp, 1))
  local hp = (raw.hp == nil) and maxHp or max(0, int(raw.hp, 0))
  if hp > maxHp then hp = maxHp end

  local status = str(raw.status)
  if status then status = M.STATUS_FROM_WIRE[status] or status end
  if status and not (GATING[status] or status == "poison"
                     or status == "burn" or status == "toxic") then
    status = nil                        -- a token nothing branches on is noise
  end

  local moves = {}
  if type(raw.moves) == "table" then
    for i = 1, #raw.moves do
      local move = copyMove(raw.moves[i])
      if move then moves[#moves + 1] = move end
    end
  end

  -- Sleep with no counter is read as one turn left, so it still costs the turn
  -- it wakes on rather than passing the gate as if healthy.  Any other default
  -- would be inventing a length; one is the shortest honest answer.
  local turns = max(0, int(raw.statusTurns, 0))
  if status == "sleep" and turns == 0 then turns = 1 end

  local stagesRaw = type(raw.stages) == "table" and raw.stages or {}
  local stages = {
    atk = Effects.clampStage(stagesRaw.atk),
    def = Effects.clampStage(stagesRaw.def),
    spd = Effects.clampStage(stagesRaw.spd),
    spc = Effects.clampStage(stagesRaw.spc),
    acc = Effects.clampStage(stagesRaw.acc),
    eva = Effects.clampStage(stagesRaw.eva),
  }

  local disable = nil
  if type(raw.disable) == "table" then
    disable = {
      moveIndex = max(0, int(raw.disable.moveIndex, 0)),
      turns = max(0, int(raw.disable.turns, 0)),
    }
  end

  local charging = nil
  if type(raw.charging) == "table" then
    charging = {
      moveIndex = max(1, int(raw.charging.moveIndex, 1)),
      effect = max(0, int(raw.charging.effect, 0)),
      targetSlot = int(raw.charging.targetSlot, nil),
      -- Dig vs Fly share an effect id in one gen; exceptions key off this.
      moveId = str(raw.charging.moveId),
    }
  end

  local trapped = nil
  if type(raw.trapped) == "table" then
    trapped = {
      turns = max(0, int(raw.trapped.turns, 0)),
      damage = max(0, int(raw.trapped.damage, 0)),
      fromSlot = int(raw.trapped.fromSlot, nil),
    }
  end

  local thrashing = nil
  if type(raw.thrashing) == "table" then
    thrashing = {
      turns = max(0, int(raw.thrashing.turns, 0)),
      moveIndex = max(1, int(raw.thrashing.moveIndex, 1)),
    }
  end

  -- `turns` is the cart's counter (wPlayerNumAttacksLeft): each forced turn
  -- takes one off, and the turn it reaches 0 -- or a sheet's 0 -- unleashes.
  local bide = nil
  if type(raw.bide) == "table" then
    bide = {
      turns = max(0, int(raw.bide.turns, 0)),
      stored = max(0, int(raw.bide.stored, 0)),
      moveIndex = max(1, int(raw.bide.moveIndex, 1)),
      targetSlot = int(raw.bide.targetSlot, nil),
    }
  end

  local leechSeed = nil
  if raw.leechSeed == true then
    leechSeed = { fromSlot = nil }
  elseif type(raw.leechSeed) == "table" then
    leechSeed = { fromSlot = int(raw.leechSeed.fromSlot, nil) }
  end

  local out = {
    species     = str(raw.species) or "?",
    -- The pokedex id behind that prose name, when the sender stated one.  Kept
    -- rather than dropped for the same reason `slot` is: it is not the sim's to
    -- use -- no formula here reads it, and there is no species table to read it
    -- against -- but it is the only thing on the sheet that lets the client
    -- *opposite* draw this monster and price the exp it is worth, and the
    -- referee is the only party that can hand it over.  Absent stays absent.
    speciesId   = str(raw.speciesId),
    slot        = max(0, int(raw.slot, max(0, int(fallback, 0)))),
    level       = max(1, int(raw.level, 1)),
    hp          = hp,
    maxHp       = maxHp,
    status      = status,
    statusTurns = turns,
    toxicCounter = max(1, int(raw.toxicCounter, 1)),
    confusion   = max(0, int(raw.confusion, 0)),
    stats = {
      atk = max(1, int(stats.atk, 1)),
      def = max(1, int(stats.def, 1)),
      spd = max(1, int(stats.spd, 1)),
      spc = max(1, int(stats.spc, 1)),
    },
    -- The party struct beside the unmodified stats above, and the battle
    -- stats (`cur`) seeded from both once the seat's badges are known
    -- (`create`).  Effects' "Stored battle stats" note says who writes which.
    partyStats = {
      atk = max(1, int(stats.atk, 1)),
      def = max(1, int(stats.def, 1)),
      spd = max(1, int(stats.spd, 1)),
      spc = max(1, int(stats.spc, 1)),
    },
    cur = nil,
    types = copyTypes(raw.types),
    moves = moves,
    stages = stages,
    leechSeed = leechSeed,
    disable = disable,
    flinch = raw.flinch == true,
    charging = charging,
    invulnerable = raw.invulnerable == true,
    mustRecharge = raw.mustRecharge == true,
    trapped = trapped,
    trapping = nil,
    thrashing = thrashing,
    raging = raw.raging == true,
    rageMove = max(0, int(raw.rageMove, 0)),
    bide = bide,
    lastMoveIndex = max(0, int(raw.lastMoveIndex, 0)),
    substitute = max(0, int(raw.substitute, 0)),
    lightScreen = raw.lightScreen == true,
    reflect = raw.reflect == true,
    mist = raw.mist == true,
    focusEnergy = raw.focusEnergy == true,
    transformed = raw.transformed == true,
    xAccuracy = raw.xAccuracy == true,
    catchRate = max(0, min(255, int(raw.catchRate, 255))),
    -- K1: the monster's OT id is not its trainer's (stamped by the owner's
    -- client, true or absent).  Only `_obey` reads it, and only on a
    -- `badgeRules` seat; anywhere else it rides along inert.
    traded = (raw.traded == true) or nil,
  }

  -- Species base Speed for Gen 1 crit (Crit.lua). Optional: a sheet that
  -- omits it falls back to battle Speed without the badge boost.
  if raw.baseSpd ~= nil then
    out.baseSpd = max(0, min(255, int(raw.baseSpd, 0)))
  end

  -- K7 (docs/plans/gen12-referee-gaps-fix.md): the species' base stats, the
  -- four DVs and the five stat-exp words, each whole or absent.  The crit
  -- rate's base Speed when `baseSpd` is absent, a transformed computer foe's
  -- GetEnemyMonStat (`_critStat`), and a level-up the client stated no stats
  -- for (`levelUp`).  Transform copies `base` and `dvs` with the species.
  out.base = copyBlock(raw.base, K7_BASE_KEYS, 0, 255)
  out.dvs = copyBlock(raw.dvs, K7_DV_KEYS, 0, 15)
  out.statExp = copyBlock(raw.statExp, K7_BASE_KEYS, 0, 65535)

  -- Optional Stat Exp sheet (atk/def/spd/spc, optional hp). Absent keys stay 0
  -- at vitamin time; present values are what HP_UP / PROTEIN / … mutate.
  if type(raw.evs) == "table" then
    local evs = {}
    for _, key in ipairs({ "hp", "atk", "def", "spd", "spc" }) do
      if raw.evs[key] ~= nil then
        evs[key] = max(0, min(65535, int(raw.evs[key], 0)))
      end
    end
    out.evs = evs
  end
  return out
end

local function copyBadges(raw)
  if type(raw) ~= "table" then return nil end
  local out, any = {}, false
  for id, held in pairs(raw) do
    if held and type(id) == "string" then out[id] = true; any = true end
  end
  if not any then return nil end
  return out
end

-- The badges a seat fights with: its own upload where the cart would have
-- applied it (M.BADGE_MODES, M.BADGE_SIDE), and nil everywhere else.
local function seatBadges(mode, side, raw)
  if not M.BADGE_MODES[mode] or side ~= M.BADGE_SIDE then return nil end
  return copyBadges(raw)
end

-- Bag sheet for auto-pick / timeout item use (id → count). Accepts the same
-- shapes Wire.bag does: a list of {id,count} or a map.
-- A trainer seat's move-choice layers, AIEnemyTrainerChooseMoves'
-- TrainerClassMoveChoiceModifications row for its class: the numbers of the
-- AIMoveChoiceModification routines it runs, in order (1..4; 4 does
-- nothing).  The client reads them off its own engine trainer record
-- (`aiMods`, which the engine extracts from the player's ROM): the class ->
-- layers table is the cart's data and the mod ships none of it, so a class
-- number alone would name nothing here.  Present and empty is a class with
-- no layer (YOUNGSTER's `.useOriginalMoveSet`); a value off the cart's four
-- pointers is dropped, and so is a list past MAX_AI_MODS.
M.MAX_AI_MODS = 8
local function copyAiMods(raw)
  if type(raw) ~= "table" then return nil end
  local out = {}
  for i = 1, #raw do
    if #out >= M.MAX_AI_MODS then break end
    local n = int(raw[i], nil)
    if n ~= nil and n >= 1 and n <= 4 then out[#out + 1] = n end
  end
  return out
end

local function copyBag(raw)
  if type(raw) ~= "table" then return nil end
  local out, any = {}, false
  local function put(id, count)
    if type(id) ~= "string" or id == "" then return end
    local n = int(count, 0)
    if not n or n < 1 then return end
    out[id] = (out[id] or 0) + n
    any = true
  end
  if #raw > 0 or raw[1] ~= nil then
    for _, entry in ipairs(raw) do
      if type(entry) == "table" then put(entry.id, entry.count) end
    end
  else
    for id, count in pairs(raw) do put(id, count) end
  end
  if not any then return nil end
  return out
end

-- Default kit kept as a named gym-style reference. Not auto-seeded onto
-- unclaimed coop_npc seats: hosts upload the trainer's own items, and a
-- Youngster with an empty kit must stay empty (seeding this made 2v2s look
-- like eight healing items).
M.DEFAULT_NPC_BAG = {
  POTION = 2, SUPER_POTION = 1, FULL_HEAL = 1, X_ATTACK = 1,
}

-- ------------------------------------------------------------------
-- the battle
-- ------------------------------------------------------------------

local Battle = {}
Battle.__index = Battle
M.Battle = Battle

local function firstLiving(mons, skip)
  for i = 1, #mons do
    if mons[i].hp > 0 and i ~= skip then return i end
  end
  return nil
end

local function allPpEmpty(mon)
  if #mon.moves == 0 then return true end
  for i = 1, #mon.moves do
    if mon.moves[i].pp > 0 then return false end
  end
  return true
end

-- AnyMoveToSelect (core.asm :2713-2753): whether the menu hands the player
-- STRUGGLE.  With no move disabled it ORs the four PP bytes and masks the PP
-- bits off -- every slot at 0 PP is Struggle.  With one disabled it skips
-- that slot and ORs the others' RAW bytes, unmasked, so a 0-PP move that
-- carries PP Ups (K8 `ppUps`) keeps STRUGGLE away -- and `.chooseMove`
-- (:2640-2650), which masks, then refuses that move for its PP and the
-- disabled one for being disabled: the cart's player can only switch or run.
local function mustStruggle(mon)
  if #mon.moves == 0 then return true end
  local disabled = mon.disable and int(mon.disable.turns, 0) > 0
    and mon.disable.moveIndex or nil
  if not disabled then return allPpEmpty(mon) end
  for i = 1, #mon.moves do
    if i ~= disabled then
      local m = mon.moves[i]
      if m.pp > 0 or int(m.ppUps, 0) > 0 then return false end
    end
  end
  return true
end

-- SelectEnemyMove (core.asm :2915-3005) outside a link battle: the
-- computer never reads its PP -- ExecuteEnemyMove never calls DecrementPP
-- either, so it never runs out -- and STRUGGLE only when its monster knows
-- one move (`wEnemyMonMoves + 1` is 0) and that move is disabled
-- (`wEnemyDisabledMove` set).  With two or more `.chooseRandomMove` redraws
-- past the disabled slot.  An empty sheet is STRUGGLE here too (the cart's
-- loop would spin forever on it).
local function computerMustStruggle(mon)
  if #mon.moves == 0 then return true end
  if #mon.moves > 1 then return false end
  return mon.disable ~= nil and int(mon.disable.turns, 0) > 0
    and int(mon.disable.moveIndex, 0) == 1
end

local function activeMon(fighter)
  if not fighter.active then return nil end
  local mon = fighter.mons[fighter.active]
  if mon and mon.hp > 0 then return mon end
  return nil
end

-- Which of this party a zero-based wire slot means.
--
-- Matched against the position each monster claims rather than counted off the
-- array, for the reason copyMon gives -- and the array index is the fallback
-- rather than the rule, so a sender whose party arrived intact is unaffected and
-- one whose party was cut or dealt still switches to the monster it named.
local function partyIndexOf(fighter, wireSlot)
  for i = 1, #fighter.mons do
    if fighter.mons[i].slot == wireSlot then return i end
  end
  return wireSlot + 1
end

-- The chart index the ruleset's `typeIds` gives the type registry id `name`
-- (zero-based, the axis every move and monster on the upload uses), or nil
-- when it names no such type -- or names none at all.
local function typeIndexOf(typeIds, name)
  if type(typeIds) ~= "table" then return nil end
  for i = 1, #typeIds do
    if typeIds[i] == name then return i - 1 end
  end
  return nil
end

-- typeIndexOf for COUNTER's two types, with pokered's own index when the
-- ruleset sent no axis at all (`create`'s note).
local function counterType(typeIds, name, fallback)
  if type(typeIds) ~= "table" then return fallback end
  return typeIndexOf(typeIds, name)
end

-- The TypeEffects rows of a ruleset's `chartOrder` (M.create's note), as
-- { atk, def } pairs in order.  All or nothing, as `typeIds` is: an odd
-- length, an index that is not a whole number 0..255, or more than
-- CHART_ORDER_MAX rows makes the whole order nil -- a row dropped from the
-- middle would move every later one up and change what the last row says.
-- A row may repeat, since the cart would apply it twice.
local function chartIndex(value)
  if type(value) ~= "number" or value ~= floor(value) then return nil end
  if value < 0 or value > 255 then return nil end
  return value
end

local function chartRowsOf(raw)
  if type(raw) ~= "table" then return nil end
  local n = #raw
  if n == 0 or n % 2 ~= 0 or n > M.CHART_ORDER_MAX * 2 then return nil end
  local rows = {}
  for i = 1, n, 2 do
    local a, d = chartIndex(raw[i]), chartIndex(raw[i + 1])
    if a == nil or d == nil then return nil end
    rows[#rows + 1] = { a, d }
  end
  return rows
end

-- opts:
--   id, mode, seed, chart, chartOrder, specialTypes, typeIds, metronomePool,
--   choiceTimeout, reconnectGrace, resolveTimeout, now
--   sides = { a = { { playerId, name, mons, bag, badges } }, b = { ... } }
--
-- `typeIds` is the chart's axis by name (MediatedBattle.snapshotRuleset:
-- `typeIds[i + 1]` names chart index i).  Red's referee asks it four questions
-- and keeps only the answers: which index is POISON (PoisonEffect turns a
-- Poison-type target away), which is FIRE (CheckDefrost thaws on a Fire
-- move), and which are NORMAL and FIGHTING (HandleCounterMove strikes back
-- only at those two).  Without it POISON and FIRE cannot be named -- a side
-- effect can poison a Poison-type monster and nothing thaws -- and NORMAL and
-- FIGHTING fall back to pokered's own indices, 0 and 1 (constants/type_constants.asm),
-- the axis the synthetic STRUGGLE's type 0 already assumes.
--
-- `chartOrder` is the type chart as the cart walks it: TypeEffects' rows in
-- table order, a flat list of chart-index pairs { atk1, def1, atk2, def2,
-- ... } (`chartRowsOf`), each row's multiplier the `chart` cell it names.
-- AdjustDamageForMoveType (core.asm :5121-5175) applies every row whose
-- attacker is the move's type and whose defender is either of the target's
-- types, one at a time, flooring after each -- so the order is the rounding
-- order -- and leaves the LAST row's multiplier in wDamageMultipliers, which
-- is what DisplayEffectiveness and PrintMoveFailureText read (`_typeRows`):
-- a dual type's "It's super effective" / "not very effective", and its
-- "doesn't affect" over "attack missed", are the last row's, not the
-- product's.  Absent or unreadable it is nil and the referee reads the chart
-- per defender type and states the product, as it always did.
--
-- `badges` is kept only on side a of a BADGE_MODES fight and dropped
-- everywhere else, silently: a PvP upload that carries one is a well-formed
-- upload the cart would simply not have boosted.  Each fighter keeps
-- `badgeRules` (true there, nil elsewhere): the seat is the cart's player in a
-- fight against the computer, which is what obedience and the flinch-reset
-- skip ask -- a question `badges` cannot answer, since a player with no
-- badges at all has the most to disobey.
--
-- Returns the battle, or nil plus a reason string.  A reason and not a raise:
-- the caller is a session handler that has a client waiting to be told why.
function M.create(opts)
  if type(opts) ~= "table" then return nil, "battle needs an options table" end

  local mode = M.MODES[opts.mode] and opts.mode or "1v1"

  local self = setmetatable({
    id             = str(opts.id) or "battle",
    mode           = mode,
    seed           = int(opts.seed, 0),
    rng            = Rng.new(int(opts.seed, 0)),
    aim            = Rng.new(int(opts.seed, 0) + M.AIM_SEED_OFFSET),
    chart          = type(opts.chart) == "table" and opts.chart or nil,
    chartRows      = chartRowsOf(opts.chartOrder),
    specialTypes   = nil,
    -- The two types a side effect's routine asks about by name (above).
    poisonType     = typeIndexOf(opts.typeIds, "POISON"),
    fireType       = typeIndexOf(opts.typeIds, "FIRE"),
    -- ...and the three a primary's routine does: ParalyzeEffect_'s
    -- `cp ELECTRIC` on the move and `cp GROUND` on the target, and
    -- LeechSeedEffect_'s `cp GRASS` (`_statusMove`).  nil when the ruleset
    -- named none, and then nothing is turned away for its type.
    electricType   = typeIndexOf(opts.typeIds, "ELECTRIC"),
    groundType     = typeIndexOf(opts.typeIds, "GROUND"),
    grassType      = typeIndexOf(opts.typeIds, "GRASS"),
    -- The two COUNTER answers (above).
    normalType     = counterType(opts.typeIds, "NORMAL", 0),
    fightingType   = counterType(opts.typeIds, "FIGHTING", 1),
    -- wDamage: the one damage word both sides share on the cart, read by
    -- COUNTER (`_counterDamage`).  Written where the cart writes it -- a hit
    -- (capped to the HP it took off a monster, whole against a doll), a miss
    -- (MoveHitTest zeroes it), a drain (halved in place), a self-hit, a Bide
    -- release, a trap's later hit -- and never by a residual, a recoil or a
    -- status move that lands (CalculateDamage returns before writing on power
    -- 0).  0 at the start: InitBattleVariables clears the battle variables.
    lastDamage     = 0,
    -- Pay Day's pile, per side of the field: PayDayEffect_ adds the user's
    -- level x 2 to wTotalPayDayMoney on either side's turn, and EndOfBattle
    -- pays the whole pile (`_checkOver`).
    payDay         = { a = 0, b = 0 },
    -- wBattleResult as the cart leaves it mid-fight, which is what EndOfBattle
    -- reads before it pays that pile on an escape (`_payDayOn`): 0 at the
    -- start, 1 from RemoveFaintedPlayerMon on ANY of the player's monsters
    -- fainting (core.asm :1030-1031) -- a send-out follows and the fight goes
    -- on with it still 1 -- and 0 again from FaintEnemyPokemon (:816-817)
    -- whenever an enemy faints with a player's monster still standing.
    -- "The player" is side a, the side a fight against the computer pays.
    battleResult   = 0,
    metronomePool  = nil,
    choiceTimeout  = max(0, int(opts.choiceTimeout, M.CHOICE_TIMEOUT)),
    reconnectGrace = max(0, int(opts.reconnectGrace, M.RECONNECT_GRACE)),
    resolveTimeout = max(0, int(opts.resolveTimeout, M.RESOLVE_TIMEOUT)),
    now            = max(0, int(opts.now, 0)),
    phase          = "choice",
    turn           = 1,
    seq            = 0,
    buffer         = {},
    fighters       = {},
    byId           = {},
    bySide         = { a = {}, b = {} },
    -- What the current action has knocked down and not paid for yet; see
    -- `_drainExp`.  A list, so the order faints happened in is the order their
    -- spoils are announced in.
    pendingExp     = {},
    -- Every faint so far, counted: `_resolveFights` reads what one slot or
    -- one residual added to it.
    faints         = 0,
    result         = nil,
    resolveDeadline = nil,
  }, Battle)

  if type(opts.specialTypes) == "table" then
    local set = {}
    for i = 1, #opts.specialTypes do
      set[max(0, int(opts.specialTypes[i], 0))] = true
    end
    self.specialTypes = set
  end
  if type(opts.metronomePool) == "table" then
    local pool = {}
    for i = 1, #opts.metronomePool do
      local move = copyMove(opts.metronomePool[i])
      if move then pool[#pool + 1] = move end
    end
    if #pool > 0 then self.metronomePool = pool end
  end

  local sides = type(opts.sides) == "table" and opts.sides or {}
  for _, side in ipairs(M.SIDES) do
    local roster = type(sides[side]) == "table" and sides[side] or {}
    if #roster == 0 then return nil, "side " .. side .. " has nobody on it" end
    local sideMax = maxFighters(mode, side)
    if #roster > sideMax then
      return nil, "side " .. side .. " has more fighters than " .. mode .. " allows"
    end
    -- Hub opens coop_wild for 2 or 3 humans; a lone human is a solo wild.
    if mode == "coop_wild" and side == "a" and #roster < 2 then
      return nil, "side a has fewer fighters than coop_wild allows"
    end
    for index = 1, #roster do
      local entry = roster[index]
      if type(entry) ~= "table" then return nil, "side " .. side .. " has a malformed fighter" end

      local playerId = str(entry.playerId)
      if not playerId then return nil, "a fighter on side " .. side .. " has no playerId" end
      if self.byId[playerId] then return nil, "duplicate playerId " .. playerId end

      local mons = {}
      if type(entry.mons) == "table" then
        for i = 1, #entry.mons do
          if #mons >= M.MONS_PER_PARTY then break end
          local mon = copyMon(entry.mons[i], #mons)
          if mon then mons[#mons + 1] = mon end
        end
      end
      if #mons == 0 then return nil, playerId .. " brought no monsters" end

      -- The cart's player in a fight against the computer, exactly as
      -- BattleSim3's `create` decides it: side a of a BADGE_MODES fight.
      local badgeRules = side == M.BADGE_SIDE and M.BADGE_MODES[mode] == true
      local fighter = {
        playerId  = playerId,
        name      = str(entry.name) or playerId,
        side      = side,
        index     = index,
        slot      = Events.fieldSlot(side, index),
        mons      = mons,
        badgeRules = badgeRules or nil,
        badges    = seatBadges(mode, side, entry.badges),
        bag       = copyBag(entry.bag),
        active    = firstLiving(mons),
        connected = true,
        graceEndsAt = nil,
        choice    = nil,
        -- The roster last published for this seat (`_syncTeams`).  nil rather
        -- than the opening string, so the first sync always publishes.
        team      = nil,
        -- Who has been in against THIS seat's current monster; see `_refield`.
        fought    = {},
        -- The trainer's move-choice layers (`_cartMovePick`), the computer's
        -- trainer seat only; nil is no layer at all.
        aiMods    = (isComputerSeat(mode, { side = side })
                     and not Effects.isWildMode(mode)) and copyAiMods(entry.aiMods) or nil,
        -- wAILayer2Encouragement (`_cartMovePick`, `_resolveFights`), the
        -- computer's seats: 0 at InitBattleVariables.
        aiLayer2  = 0,
      }
      -- Every monster's battle stats, seeded the way LoadBattleMonFromParty
      -- seeds them (the unmodified stats, the condition penalty, this seat's
      -- badges), so a bench monster is as ready as the fielded one; a switch-in
      -- re-runs the whole load anyway (`_resolveSwitches`).
      for i = 1, #mons do Effects.recalcBattleStats(mons[i], fighter.badges) end
      self.fighters[#self.fighters + 1] = fighter
      self.byId[playerId] = fighter
      local bucket = self.bySide[side]
      bucket[#bucket + 1] = fighter
    end
  end

  -- Everybody is fielded at once, so the opening participation sets are the
  -- opening field.  `_refield` re-adds the standing opposition every time it
  -- runs, so walking the roster once is enough: a later seat's reset cannot
  -- lose an earlier seat's entry, it re-derives it.
  for _, fighter in ipairs(self.fighters) do self:_refield(fighter) end

  -- `mon` is the party index the referee itself fielded (here: `firstLiving`),
  -- zero-based like the `exp` event's.  A client cannot re-derive it from
  -- `text`: a party may hold the same species twice, and resolving the name
  -- against the party then picks whichever copy comes first -- which is how a
  -- fainted duplicate came back onto the field.  The index is unambiguous.
  for _, fighter in ipairs(self.fighters) do
    local mon = activeMon(fighter)
    if mon then
      self:_emit("send", { slot = fighter.slot, side = fighter.side,
                           hp = mon.hp, maxHp = mon.maxHp,
                           text = mon.species,
                           speciesId = mon.speciesId, level = mon.level,
                           mon = fighter.active - 1,
                           status = mon.status and M.STATUS_TO_WIRE[mon.status] or nil,
                           confused = (mon.confusion and mon.confusion > 0) and 1 or nil })
    end
  end

  self:_openTurn()
  return self
end

-- ------------------------------------------------------------------
-- events
-- ------------------------------------------------------------------

function Battle:_emit(kind, fields)
  local event = Events.build(kind, fields)
  if not event then return nil end
  self.seq = self.seq + 1
  event.battle = self.id
  event.seq = self.seq
  self.buffer[#self.buffer + 1] = event
  return event
end

-- `partyIndex` is 1-based into the fighter's party. Present on a PP
-- spend/restore so the client can write that sheet; absent on
-- Transform/Mimic so the overlay is not mistaken for the real set.
function Battle:_emitMoves(fighter, mon, partyIndex)
  local moves = {}
  for i = 1, #mon.moves do
    local m = mon.moves[i]
    moves[#moves + 1] = {
      id = m.id or "move",
      pp = max(0, int(m.pp, 0)),
      maxPp = max(0, int(m.maxPp, m.pp)),
      power = max(0, int(m.power, 0)),
      accuracy = max(0, int(m.accuracy, 255)),
      type = max(0, int(m.type, 0)),
      effect = max(0, int(m.effect, 0)),
      chance = max(0, int(m.chance, 0)),
      -- K8's PP Ups beside the PP, the byte's top two bits as DecrementPP /
      -- IncrementMovePP left them (`stepPp`): the client writes them to the
      -- save as stated rather than inferring a wrap's borrow off the step
      -- (MediatedBattle ppByteStep1).
      ppUps = max(0, min(3, int(m.ppUps, 0))),
    }
  end
  local fields = { slot = fighter.slot, side = fighter.side, moves = moves }
  if partyIndex then fields.mon = partyIndex - 1 end
  return self:_emit("moves", fields)
end

function Battle:_say(text)
  return self:_emit("msg", { text = text })
end

-- A status animation the cart plays from CheckPlayerStatusConditions /
-- CheckEnemyStatusConditions (the sleeping and the confused monster's), as an
-- `anim` event on the seat it plays over: its battle_anims id, the
-- `_ANIM` kind a client looks up the way it looks up the ball chain's.  The
-- cart picks the PLAYER variant on the player's turn and the plain one on the
-- enemy's; "the player" is the owner's rule (`isPlayerSeat`), so in a link
-- fight each seat carries its own console's variant and the screen across
-- swaps it for a monster that is not its own.
function Battle:_statusAnim(fighter, id)
  return self:_emit("anim", { slot = fighter.slot, side = fighter.side, text = id })
end

-- STATUS_AFFECTED_ANIM over the user (contract K20), wherever the cart plays
-- it: `.FlyOrChargeEffect` when a full paralysis or a confusion self-hit
-- ends the turn (`.MonHurtItselfOrFullyParalysed`, core.asm :3459-3476; the
-- enemy's, :5836-5853) and PlayerCheckIfFlyOrChargeEffect /
-- EnemyCheckIfFlyOrChargeEffect (:3184-3197, :5585-5599) on a move that missed
-- -- HandleIfPlayerMoveMissed's `jr` -- or that CalculateDamage found at power
-- 0.  Each tests the move struct's effect, wPlayerMoveEffect /
-- wEnemyMoveEffect, for FLY_EFFECT or CHARGE_EFFECT (Effects.isCharge): the
-- cancelled FLY or charge.  At a gate that is the struct as it stands
-- (`moveStruct`, before GetCurrentMove) -- the charging move's on its
-- release turn, the menu's pick on a player's fresh one; on a miss, the move
-- being used.
function Battle:_flyOrChargeAnim(fighter, effectId)
  if Effects.isCharge(effectId) then
    self:_statusAnim(fighter, "STATUS_AFFECTED_ANIM")
  end
end

-- Every seat's party roster, published when -- and only when -- it moved.
--
-- **This is the only thing on the wire that describes a monster nobody has
-- seen.**  A mediated fight tells each client about the field and nothing else,
-- which is right for every other event and wrong for exactly one question: how
-- many monsters is the other player still holding, and how many of those are
-- spent.  Both clients uploaded a party to the referee and neither uploaded one
-- to the other, so the referee is the only party to the fight that can answer
-- it -- which is why this is an event and not something a screen derives.
--
-- What it carries is a ball row and no more (`Events.teamString`): a count and
-- three states.  Not a species, not a level, not a move.  That line is where it
-- is because it is where the original draws it -- the row a trainer's intro
-- puts on screen is exactly this much -- and because anything past it is a team
-- preview one player never agreed to give.
--
-- Diffed rather than announced, so a fight that changes nothing costs nothing:
-- a seat is re-published only when one of its monsters changed ball state.
-- `fighter.team` starts nil, so the first sync always publishes -- which is how
-- the opening rosters reach a client (`_openTurn` runs at the end of `create`,
-- behind the send-outs).
--
-- `fainting` is the seat `_faint` is taking down: its roster goes with its
-- faint.  Any other seat whose monster still stands at 0 HP -- a knockout
-- waiting for the action's end, K19's `_reapKo` -- is held back until its own
-- faint publishes it, so a double knockout darkens each ball with the faint it
-- belongs to rather than the first one's.
function Battle:_syncTeams(fainting)
  for _, fighter in ipairs(self.fighters) do
    local standing = fighter.active and fighter.mons[fighter.active]
    local pending = fighter ~= fainting and standing ~= nil and standing.hp <= 0
    local roster = Events.teamString(fighter.mons)
    if not pending and roster ~= fighter.team then
      fighter.team = roster
      self:_emit("team", {
        slot = fighter.slot, side = fighter.side, team = roster,
      })
    end
  end
end

-- Everything since the last call, in order, and the buffer is emptied.  A
-- caller that drops the returned list drops those events for good, which is
-- deliberate: the alternative -- a buffer that grows until somebody reads it --
-- is a memory leak on a hub whose client has gone quiet.
function Battle:drainEvents()
  local out = self.buffer
  self.buffer = {}
  return out
end

-- ------------------------------------------------------------------
-- the field
-- ------------------------------------------------------------------

function Battle:_foes(fighter)
  local other = (fighter.side == "a") and "b" or "a"
  return self.bySide[other]
end

function Battle:_fighterAtSlot(slot)
  for _, fighter in ipairs(self.fighters) do
    if fighter.slot == slot then return fighter end
  end
  return nil
end

function Battle:_firstLivingFoe(fighter)
  for _, foe in ipairs(self:_foes(fighter)) do
    if activeMon(foe) then return foe end
  end
  return nil
end

-- Which opposing seat an action *nobody chose* swings at.
--
-- Every aim the referee files for itself comes through here: an NPC's pick,
-- the identical pick a human's timeout files, and the lock-in turns of
-- thrash / rage / bide, where nobody is asked for a target because the move
-- does not offer one.
--
-- It used to be `_firstLivingFoe`, which answers "the lowest-numbered living
-- foe" -- the right answer to a question with one possible answer, and the
-- wrong one the moment a side holds two players.  A coop_wild's wild monster
-- and *both* seats of a coop_npc trainer swung at seat 0 every turn of every
-- fight, so the second player on the side was never once attacked.  Reported
-- from a real two-player game, and reproducible in one sitting: 18 damage
-- events, 18 of them on slot 0.
--
-- So: uniform over the living opposing seats.  Three properties make that
-- safe to add to a sim two runtimes have to agree on byte for byte.
--
--   * The draw is on `self.aim`, not `self.rng`.  A draw on the battle's own
--     generator would shift every roll after it and silently rewrite every
--     recorded vector; this one cannot move a number that already exists.
--   * One living foe is answered without drawing at all.  A 1v1, and the lone
--     wild seat of a wild / coop_wild fight, therefore consume nothing and
--     replay exactly as they always did -- the aim stream in those fights is
--     never even touched.
--   * `byte()` is the draw, not `nextInt`.  `nextInt` used to take the whole
--     LCG state modulo the span, and this generator's bit 0 alternates every
--     step, so a two-seat side would have got a perfect A-B-A-B rota rather
--     than a spread.  `byte()` reads bits 16..23, which is the reason
--     Rng.lua puts them there (since K12 `nextInt` reads the high bits too;
--     the aim draw stays `byte()` so no recorded aim stream moves).
--
-- Draw order is the parity contract, exactly as it is for `self.rng`: both
-- runtimes call this at the same points, in the same seat order, or their
-- aim streams part company.  tests/fixtures/battle_sim_vectors.json's
-- sibling drivers are what hold that.
function Battle:_autoTarget(fighter)
  local living = {}
  for _, foe in ipairs(self:_foes(fighter)) do
    if activeMon(foe) then living[#living + 1] = foe end
  end
  if #living == 0 then return nil end
  if #living == 1 then return living[1] end
  return living[(self.aim:byte() % #living) + 1]
end

-- Which seat an action actually swings at, given the seat it was aimed at.
--
-- A fight choice always names a living opposing seat when it is made:
-- `_normaliseChoice` refuses an empty one, and the replace phase means the
-- field is whole again before the next choice window opens.  **A mid-turn
-- faint is therefore the only way an aim can go stale** -- in a 2v2 the faster
-- ally KOs the seat the slower ally picked, and without this the slower mon
-- fizzles ("has no target") instead of swinging.
--
-- Preference order:
--   (a) whatever is standing in the SAME field position.  A seat *is* a field
--       position here, so this also covers the case where the seat was emptied
--       and refilled between choice and execution -- the aim the player made
--       still points at a real monster and is honoured unchanged.
--   (b) otherwise the NEAREST living opposing seat: smallest
--       |seat.slot - aimedSlot| (both sit on the same side, so the side base
--       cancels and this is seat-index distance), ties broken toward the lower
--       seat index.  With two seats a side that is simply the adjacent seat;
--       the rule is spelled out so a wider field could not make it ambiguous.
--   (c) otherwise nil -- the opposing side has nothing standing, the battle is
--       ending, and the action is skipped.
--
-- Only the opposing side is ever searched, so nothing here can redirect a move
-- onto the user or its ally; self-targeting and side-wide effects ride the
-- same opposing-seat aim they always did and are untouched.  The answer is
-- bound once per action in `_useMove`, so a multi-hit strike puts every hit on
-- the retargeted seat -- an action retargets, not each of its strikes.
function Battle:_retarget(fighter, slot)
  local aimed = self:_fighterAtSlot(slot)
  if aimed and activeMon(aimed) then return aimed end

  local best, bestDistance
  for _, foe in ipairs(self:_foes(fighter)) do
    if activeMon(foe) then
      local distance = foe.slot - slot
      if distance < 0 then distance = -distance end
      if bestDistance == nil or distance < bestDistance
         or (distance == bestDistance and foe.slot < best.slot) then
        best, bestDistance = foe, distance
      end
    end
  end
  return best
end

function Battle:_sideAlive(side)
  for _, fighter in ipairs(self.bySide[side]) do
    if firstLiving(fighter.mons) then return true end
  end
  return false
end

function Battle:_sidePlayers(side)
  local out = {}
  for _, fighter in ipairs(self.bySide[side]) do out[#out + 1] = fighter.playerId end
  return out
end

-- A fighter owes a choice when it has something standing, or when it must pick
-- a replacement after a faint.  A player whose last monster fainted in a 2v2 is
-- a spectator for the rest of the fight, and waiting on them would hang the
-- turn.  Multi-turn volatiles auto-fill before the player is asked.
--
-- In the `replace` phase the only thing anybody owes is a replacement: the
-- seats that are still standing answered last turn and are not being asked
-- again, so their standing monster must not hold the phase open.  Everything
-- that reads "who are we waiting on" -- `_anyoneOwes`, the timeout sweep in
-- `tick`, `snapshot().waiting` -- goes through here, which is why the phase
-- test lives in this one function rather than at each of those call sites.
function Battle:_owes(fighter)
  if fighter.choice ~= nil then return false end
  if fighter.mustReplace then
    return firstLiving(fighter.mons) ~= nil
  end
  if self.phase == "replace" then return false end
  if activeMon(fighter) == nil then return false end
  return true
end

-- Inject forced choices for charge release, recharge, thrash/rage repeat --
-- and, for the computer's seats, a Bide, a trap's continuation and the
-- monster it holds.  The cart skips the move menu for all of them
-- (MainInBattleLoop :293-321, SelectEnemyMove :2938-2955), and the whole
-- battle menu for the first four (:293-303): a player's Bide user, trapper
-- or held monster is asked instead (`_menuFight`).  Every one of them is
-- then the monster's own turn-order slot:
-- ExecutePlayerMove runs CheckPlayerStatusConditions over it, so the sleep
-- and freeze checks, the trapped check and the flinch come first, and only a
-- monster that gets past them recharges (`.HyperBeamCheck`), stores its Bide,
-- thrashes or keeps its trap going (`.MultiturnMoveCheck`).  Nothing is said
-- here; the slot says it (`_rechargeTurn`, `_useMove`).
-- Every forced fight carries the move it replays (`forcedMove`): the move its
-- record kept, or the recording slot's own.  wPlayerSelectedMove still names
-- the move from the turn that started it -- the one MetronomePickMove /
-- MirrorMoveCopyMove wrote there for a called move (core.asm :5013-5031,
-- :4961-4986), which is why a METRONOME that called FLY lands FLY next turn
-- rather than rolling METRONOME again.  And since no menu is asked, nothing
-- is ever Struggle here: RAGE at 0 PP stays RAGE.  `called` marks a record
-- holding a called move, whose selected move is not the slot's (`_useMove`'s
-- disabled check).
local function forcedMoveOf(mon, calledMove, slot)
  if calledMove then return calledMove, true end
  return mon.moves[slot], nil
end

-- A trap's continuation: the trapping move, at the monster it holds.
local function trapChoice(mon)
  local t = mon.trapping
  local forced, called = forcedMoveOf(mon, t.move, t.moveIndex)
  return {
    action = "fight",
    move = t.moveIndex,
    target = t.targetSlot,
    forcedMove = forced,
    called = called,
    trapContinue = true,
  }
end

function Battle:_fileForced(fighter, choice)
  fighter.forced = true
  fighter.choice = choice
  self:_emit("chose", {
    slot = fighter.slot, side = fighter.side, text = fighter.name,
  })
end

function Battle:_fillForcedChoices()
  for _, fighter in ipairs(self.fighters) do
    if fighter.choice ~= nil then goto continue end
    local mon = activeMon(fighter)
    if not mon then goto continue end

    -- NEEDS_TO_RECHARGE: no menu (:293-295).  The recharge itself is the
    -- slot's (`_rechargeTurn`): a monster asleep or frozen there keeps the
    -- bit, as the cart's sleep and freeze checks return before
    -- `.HyperBeamCheck`.  `skip` is the forced turn's kind, which
    -- `_resolveFights` reads, as `_selectionOf` does for the selected move
    -- the cart leaves standing.
    if mon.mustRecharge then
      self:_fileForced(fighter, { action = "skip", skip = "recharge" })
      goto continue
    end

    -- Bide's forced turns are the monster's own turn-order slot on the cart
    -- (CheckPlayerStatusConditions `.BideCheck`, core.asm :3482-3524): every
    -- gate runs first, then the store takes wDamage and the counter a step,
    -- and the turn it reaches 0 unleashes -- so each one is a forced fight
    -- (`bideStore`), not a skip (`_useMove`'s Bide branch).  The computer's
    -- (SelectEnemyMove :2949-2950 keeps its selection); a player's seat gets
    -- the battle menu first and is asked (`_menuFight`).
    if mon.bide then
      if not isPlayerSeat(self.mode, fighter) then
        local choice = self:_bideChoice(fighter, mon)
        if choice then self:_fileForced(fighter, choice) end
      end
      goto continue
    end

    -- USING_TRAPPING_MOVE: no move menu (:311-313), and the selection is the
    -- trapping move still.  `.MultiturnMoveCheck` hits again in the
    -- trapper's slot, past every gate (`_trapTurn`) -- not a residual at the
    -- turn's end, and not a re-rolled move.  `trapContinue` says so; a trap
    -- that a switch or a faint let go before the slot leaves the move to run
    -- fresh, as the cart's stale selection does (`_useMove`) -- the
    -- computer's re-picks instead (`_reselectComputer`).  Filed for the
    -- computer; a player's trapper gets the battle menu (`_menuFight`).
    if mon.trapping and int(mon.trapping.turns, 0) > 0 then
      if not isPlayerSeat(self.mode, fighter) then
        self:_fileForced(fighter, trapChoice(mon))
      end
      goto continue
    end

    if mon.charging then
      local c = mon.charging
      local forced, called = forcedMoveOf(mon, c.move, c.moveIndex)
      self:_fileForced(fighter, {
        action = "fight",
        move = c.moveIndex,
        target = c.targetSlot,
        forcedMove = forced,
        called = called,
      })
      goto continue
    end

    -- "<MON>'s thrashing about!" is the slot's (`.ThrashingAboutCheck`,
    -- past the gates), not the turn's opening.
    if mon.thrashing and mon.thrashing.turns > 0 then
      local foe = self:_autoTarget(fighter)
      if foe then
        local forced, called = forcedMoveOf(mon, mon.thrashing.move, mon.thrashing.moveIndex)
        self:_fileForced(fighter, {
          action = "fight",
          move = mon.thrashing.moveIndex,
          target = foe.slot,
          forcedMove = forced,
          called = called,
        })
      end
      goto continue
    end

    -- No line here: `.RageCheck` (core.asm :3568-3579) only names the move
    -- and goes to PlayerCanExecuteMove, whose "used RAGE!" `_useMove` says.
    -- "<MON>'s RAGE is building!" is HandleBuildingRage's, at each build
    -- (`_buildRage`).
    if mon.raging and mon.rageMove and mon.rageMove > 0 then
      local foe = self:_autoTarget(fighter)
      if foe then
        local forced, called = forcedMoveOf(mon, mon.rageCall, mon.rageMove)
        self:_fileForced(fighter, {
          action = "fight",
          move = mon.rageMove,
          target = foe.slot,
          forcedMove = forced,
          called = called,
        })
        goto continue
      end
    end

    -- Held by a foe's trap: CANNOT_MOVE (MainInBattleLoop :316-321,
    -- SelectEnemyMove :2953-2955), and ExecutePlayerMove's `inc a / jp z`
    -- then skips the whole turn without a word -- no gate, no line.  Only a
    -- monster that reaches this point of the menu logic gets it: one asleep
    -- or frozen jumps to `.selectEnemyMove` first (:308-310) and keeps its
    -- selection and its menu, so its sleep ticks in its slot; and every
    -- forced turn above was filed first, to meet `.HeldInPlaceCheck`'s
    -- "can't move" there instead (`_runGates`).  The computer's seat; a
    -- player's held monster gets the battle menu first (`_menuFight`).
    if self:_isHeld(fighter, mon) and mon.status ~= "sleep" and mon.status ~= "freeze"
       and not isPlayerSeat(self.mode, fighter) then
      self:_fileForced(fighter, { action = "skip", skip = "trapped" })
    end

    ::continue::
  end
end

-- A Bide's forced turn.  The store turns need no aim (`.BideCheck` only
-- adds wDamage), so the aim stream is asked -- as it always was -- only on
-- the turn whose step takes the counter to 0, the unleash.  nil when that
-- turn has nobody to unleash at.
function Battle:_bideChoice(fighter, mon)
  local bide = mon.bide
  local foe = nil
  if int(bide.turns, 0) <= 1 then
    foe = self:_autoTarget(fighter)
    if not foe then return nil end
  end
  local target = bide.targetSlot or (foe and foe.slot)
  if target == nil then
    local first = self:_firstLivingFoe(fighter)
    target = first and first.slot
  end
  local forced, called = forcedMoveOf(mon, bide.move, bide.moveIndex)
  return {
    action = "fight",
    move = bide.moveIndex,
    target = target,
    bideStore = true,
    forcedMove = forced,
    called = called,
  }
end

-- What a player's FIGHT selects where the cart opens the battle menu but no
-- move menu behind it (MainInBattleLoop, core.asm :303-321): DisplayBattleMenu
-- has run -- a switch, an item or a RUN there is the seat's answer, taken as
-- on any turn -- and FIGHT returns to a loop that jumps to `.selectEnemyMove`
-- for a monster asleep or frozen (:308-310), one storing energy or using a
-- trapping move (:311-313), and writes CANNOT_MOVE for one a foe's trap
-- holds (:314-321).  So the move index a client sends with it names nothing:
--   * a Bide: its forced turn (`_bideChoice`, `.BideCheck` in its slot);
--   * a trap of its own, its counter not spent: the continuation
--     (`trapChoice`, `.MultiturnMoveCheck`);
--   * held by a foe's trap and awake: CANNOT_MOVE, the turn gone in silence
--     -- and decided now, against the trap standing at the menu, so a
--     trapper that switches out later in the turn does not give it back.
-- nil for every other monster.  (Asleep or frozen, last turn's selection
-- stands and the gate stops the monster: `_normaliseChoice` takes any slot
-- that holds a move, with no PP or Disable test, since no menu applied one.)
function Battle:_menuFight(fighter, mon)
  if mon.bide then return self:_bideChoice(fighter, mon) end
  if mon.trapping and int(mon.trapping.turns, 0) > 0 then return trapChoice(mon) end
  if self:_isHeld(fighter, mon) and mon.status ~= "sleep" and mon.status ~= "freeze" then
    return { action = "skip", skip = "trapped" }
  end
  return nil
end

-- `.AnyMoveDisabledCheck` (core.asm :3394-3407): the Disable counter comes
-- down a step every time the monster gets past the sleep, freeze, trapped,
-- flinch and recharge checks -- in its own turn, not at the turn's end --
-- and the step that reaches 0 lifts it there and then ("<MON>'s disabled no
-- more!"), so that turn's move goes ahead even if it is the one that was
-- disabled.  The 1..8 of DisableEffect counts these steps.
function Battle:_tickDisable(fighter, mon)
  local d = mon.disable
  if not d or int(d.turns, 0) <= 0 then return end
  d.turns = d.turns - 1
  if d.turns <= 0 then
    mon.disable = nil
    self:_say(named(fighter, mon) .. "'s\ndisabled no more!")
  end
end

function Battle:_anyDisconnected()
  for _, fighter in ipairs(self.fighters) do
    if not fighter.connected then return true end
  end
  return false
end

-- ------------------------------------------------------------------
-- choices
-- ------------------------------------------------------------------
--
-- Indices arrive zero-based, because that is how they ride on the wire:
-- `move` is 0..3 into the monster's moves, `slot` is 0..5 into the party, and
-- `target` is a 0..3 *field* slot.  They are converted here, once, so nothing
-- downstream has to remember which of the three it is holding.

function Battle:_normaliseChoice(fighter, choice)
  local action = choice.action

  -- Forced replacement: only a living bench switch is accepted.  Fight / item /
  -- run would spend a turn the seat does not have a mon for.
  if fighter.mustReplace then
    if action ~= "switch" then return nil end
    local slot = int(choice.slot, nil)
    if slot == nil then return nil end
    local target = partyIndexOf(fighter, slot)
    local bench = fighter.mons[target]
    if not bench or bench.hp <= 0 then return nil end
    return { action = "switch", slot = target }
  end

  local mon = activeMon(fighter)
  if not mon then return nil end

  -- RUN in a trainer fight: TryRunningFromBattle's `.trainerBattle` prints
  -- NoRunningText and leaves wActionResultOrTookBattleTurn at 0, so
  -- BattleMenu_RunWasSelected goes back to DisplayBattleMenu (core.asm
  -- :2446-2457) -- the turn is not spent and the menu asks again.  So the
  -- choice is refused here and the seat still owes one; the line is the
  -- client's own, said where it declines to send the RUN (Effects.runEndsBattle).
  if action == "run" then
    if not Effects.runEndsBattle(self.mode) then return nil end
    return { action = "run" }
  end

  if action == "item" then
    local item = str(choice.item)
    if not item then return nil end
    -- Wildlife has no bag and no hands.  Refused rather than ignored so a wild
    -- seat that is somehow handed one never spends the turn on it either.
    if isWildSeat(self.mode, fighter) then return nil end
    -- A fighter with a bag sheet must actually hold the stack (hub/NPC auto).
    -- Seats with no bag stay permissive so headless fixtures can still item.
    if fighter.bag and not self:_bagHas(fighter, item) then return nil end
    local effect = Effects.itemEffect(item)
    local out = { action = "item", item = item }
    if choice.slot ~= nil then
      local slot = int(choice.slot, nil)
      if slot == nil then return nil end
      local target = partyIndexOf(fighter, slot)
      if not fighter.mons[target] then return nil end
      out.slot = target
    end
    if choice.move ~= nil then
      local move = int(choice.move, nil)
      if move == nil then return nil end
      out.move = move + 1
    elseif effect and effect.needsMove then
      return nil
    end
    -- Gen 1: Potion/Ether/status/vitamin on a KO, and Revive on a living
    -- mon, never leave the picker. Refuse here so a submitted choice cannot
    -- spend the bag or the turn.
    local targetMon = fighter.mons[out.slot or fighter.active]
    if targetMon then
      if effect and effect.faintedOnly and targetMon.hp > 0 then return nil end
      if targetMon.hp <= 0 and Effects.itemFailsOnFainted(effect) then return nil end
    end
    -- ItemUseFailed (item_effects.asm :2316-2319): a use that does nothing
    -- -- ItemUseNoEffect, from ItemUseMedicine's `.healingItemNoEffect` and
    -- ItemUsePPRestore's `.noEffect` -- or that is not for now
    -- (ItemUseNotTime) writes 0 to wActionResultOrTookBattleTurn and never
    -- reaches RemoveUsedItem: the bag keeps the item, the turn is not spent,
    -- and the battle menu asks again.  So a player's such use is refused
    -- here, before it is filed (`_itemFails`), as the fainted cases above
    -- are -- the seat still owes its turn.  The computer's AI items never
    -- take that path.
    if not isComputerSeat(self.mode, fighter) and self:_itemFails(fighter, effect, out) then
      return nil
    end
    return out
  end

  if action == "switch" then
    local slot = int(choice.slot, nil)
    if slot == nil then return nil end
    local target = partyIndexOf(fighter, slot)
    local bench = fighter.mons[target]
    if not bench or bench.hp <= 0 or target == fighter.active then return nil end
    return { action = "switch", slot = target }
  end

  if action == "fight" then
    -- FIGHT with no move menu behind it (`_menuFight`): the lock-in itself,
    -- whatever slot -- or none -- came with it.
    local locked = self:_menuFight(fighter, mon)
    if locked then return locked end
    -- Asleep or frozen, FIGHT opens no move menu either (MainInBattleLoop
    -- :308-310): the slot is a placeholder the gate never gets past, so any
    -- slot holding a move stands and none at all is the first.
    local asleep = mon.status == "sleep" or mon.status == "freeze"
    local index = int(choice.move, nil)
    if asleep and (index == nil or mon.moves[index + 1] == nil) then index = 0 end
    if index == nil then return nil end
    local move = mon.moves[index + 1]
    if not move then return nil end
    -- Struggle (AnyMoveToSelect, `_struggles`) takes any index.  Otherwise
    -- `.chooseMove` refuses a slot whose PP -- masked, so PP Ups do not count
    -- here -- is 0, and the disabled slot.  The computer's SelectEnemyMove
    -- refuses the disabled slot and never reads PP (`_hasPp`).
    if not asleep and not self:_struggles(fighter, mon) then
      if not self:_hasPp(fighter, move) then return nil end
      if mon.disable and mon.disable.turns > 0
         and mon.disable.moveIndex == index + 1 then
        return nil
      end
    end

    local targetFighter
    if choice.target ~= nil then
      targetFighter = self:_fighterAtSlot(int(choice.target, -1))
      -- A named target that is empty or on the chooser's own side is refused
      -- rather than redirected: redirecting would spend somebody's turn on a
      -- monster they did not pick, and the client can ask again.
      -- A seat mid-replace (mustReplace, no active yet) is still a legal aim:
      -- switches resolve before fights, so the mon will be out when the move
      -- lands.
      if not targetFighter or targetFighter.side == fighter.side then
        return nil
      end
      if not activeMon(targetFighter) and not targetFighter.mustReplace then
        return nil
      end
    else
      -- Deliberately `_firstLivingFoe` and not `_autoTarget`: this is a
      -- *player's* move with the aim left off, and the answer to that is a
      -- predictable default the client can show, not a die roll.  Only the
      -- aims nobody chose spread.
      targetFighter = self:_firstLivingFoe(fighter)
      if not targetFighter then
        for _, foe in ipairs(self:_foes(fighter)) do
          if foe.mustReplace then targetFighter = foe; break end
        end
      end
      if not targetFighter then
        -- Same leftover as `_autoChoiceOrSkip`: a living seat with nobody
        -- across the field to aim at spends the turn rather than hanging
        -- the window. Solo's choice clock is 0, so a refused FIGHT used
        -- to mark the band answered and wait for WILD forever.
        return { action = "skip" }
      end
    end
    local out = { action = "fight", move = index + 1, target = targetFighter.slot }
    -- Asleep or frozen, no move menu ran: the move this turn would use is
    -- last turn's selection, at last turn's list index (`_useMove`, for a
    -- monster a Fire hit thaws before its slot).
    if asleep then out.stale = true end
    -- MIMIC's pick, asked up front the way Gen 3 asks BATON PASS's
    -- destination: the cart opens the foe's move list as the move runs
    -- (MimicEffect `.letPlayerChooseMove`), which a mediated fight cannot do
    -- mid-turn.  Zero-based into the target's moves; `_mimicPick` reads it
    -- only where the cart asks the player, and checks it against the moves
    -- the target holds when MIMIC lands.  Absent or malformed, the menu's
    -- cursor answers (its first row).
    if choice.mimic ~= nil then
      local pick = int(choice.mimic, nil)
      if pick ~= nil and pick >= 0 and pick < 4 then out.mimic = pick + 1 end
    end
    return out
  end

  return nil
end

-- Returns true when the choice is now held for this turn, false otherwise.
-- False is the whole of the error report on purpose: the reasons a choice is
-- refused (wrong phase, unknown player, disconnected, already answered, an
-- index that names nothing) are all things the client can see for itself, and a
-- string here would be a second vocabulary to keep in step across two runtimes.
function Battle:submitChoice(playerId, choice)
  if self.phase ~= "choice" and self.phase ~= "replace" then return false end
  if type(choice) ~= "table" then return false end

  local fighter = self.byId[str(playerId) or ""]
  if not fighter then return false end
  -- disconnect() pauses the clock but used to keep taking answers from the
  -- same socket (SESSION_LEAVE leaves TCP up). Refuse until reconnect().
  if not fighter.connected then return false end
  if not ACTIONS[choice.action] then return false end

  -- The replace phase belongs to the seats that owe a send-out and to nobody
  -- else: a standing seat's fight would be an answer to a turn that has not
  -- opened yet, and taking it here would spend it before the player saw the
  -- successor come out.  Refused rather than queued, so the client asks again
  -- on the `turn` that follows the send.
  if self.phase == "replace" and not self:_owes(fighter) then return false end

  if choice.action == "cancel" then
    -- A forced replacement is not a decision that can be taken back: the field
    -- is a monster short until it is answered, so `unchose` here would only
    -- hand the seat a second way to hold the fight open.
    if self.phase == "replace" then return false end
    if fighter.choice == nil then return false end
    -- A referee-filled answer is not the player's to take back.  A recharge,
    -- Rage, a thrash and a charge's release -- and the computer's Bide, trap
    -- and hold -- fill the seat at `_openTurn`; on a turn where *every* seat
    -- is forced `_openTurn` leaves no deadline, so a cleared choice would hang
    -- the fight with nothing left to time it out.  A player's own lock-in --
    -- the FIGHT it answers a Bide, a trap or a hold with (`_menuFight`) -- is
    -- its answer like any other, and the cart's B backs out of it too.
    if fighter.forced then return false end
    self:_emit("unchose", {
      slot = fighter.slot, side = fighter.side, text = fighter.name,
    })
    fighter.choice = nil
    return true
  end

  if fighter.choice ~= nil then return false end   -- one answer per turn
  if fighter.mustReplace then
    if choice.action ~= "switch" then return false end
  elseif not activeMon(fighter) then
    return false
  end

  local normalised = self:_normaliseChoice(fighter, choice)
  if not normalised then return false end

  fighter.choice = normalised
  -- Peers need this for the wait line: without it, only the chooser's own
  -- client knows they answered (there is no `act` fan-out on the mediated path).
  self:_emit("chose", {
    slot = fighter.slot, side = fighter.side, text = fighter.name,
  })
  self:_maybeResolve()
  return true
end

function Battle:_anyoneOwes()
  for _, fighter in ipairs(self.fighters) do
    if self:_owes(fighter) then return true end
  end
  return false
end

function Battle:_maybeResolve()
  if self.phase ~= "choice" and self.phase ~= "replace" then return false end
  -- A leftover or forced fill must not complete the turn while a seat is
  -- away: the clock is paused for them, and resolving would spend it.
  -- reconnect() calls this once everyone is back.
  if self:_anyDisconnected() then return false end
  for _, fighter in ipairs(self.fighters) do
    if self:_owes(fighter) then return false end
  end
  if self.phase == "replace" then
    self:_closeReplace()
    return true
  end
  self:_resolveTurn()
  return true
end

-- timeout/NPC pick: bag cures/heals/X-items when present, else SE / status /
-- setup / switch. Deterministic twin of server/lib/battle/Turn.js — richer
-- than a strongest-move heuristic, still not a full TrainerAI port.  For the
-- computer's seats only its item, its switch and its forced answers stand:
-- the move it would fight with is SelectEnemyMove's (`_computerChoice`).
local AUTO_STATUS_PRI = {
  [32] = 4, -- SLEEP_EFFECT
  [67] = 3, -- PARALYZE_EFFECT
  [66] = 2, -- POISON_EFFECT
  [49] = 1, -- CONFUSION_EFFECT
  [84] = 1, -- LEECH_SEED_EFFECT
}
-- Self-boost / screen / substitute. Values are stage keys, or true for flags.
local AUTO_SETUP = {
  [10] = "atk", [11] = "def", [12] = "spd", [13] = "spc",
  [50] = "atk", [51] = "def", [52] = "spd", [53] = "spc",
  [47] = true, -- FOCUS_ENERGY
  [64] = true, -- LIGHT_SCREEN
  [65] = true, -- REFLECT
  [79] = true, -- SUBSTITUTE
}
-- Prefer stronger heals first (gym-AI style).
local AUTO_HEAL_PREF = {
  "FULL_RESTORE", "MAX_POTION", "HYPER_POTION", "SUPER_POTION",
  "LEMONADE", "SODA_POP", "FRESH_WATER", "POTION",
}
local AUTO_STATUS_CURE = {
  poison = { "FULL_RESTORE", "FULL_HEAL", "ANTIDOTE" },
  toxic = { "FULL_RESTORE", "FULL_HEAL", "ANTIDOTE" },
  burn = { "FULL_RESTORE", "FULL_HEAL", "BURN_HEAL" },
  freeze = { "FULL_RESTORE", "FULL_HEAL", "ICE_HEAL" },
  sleep = { "FULL_RESTORE", "FULL_HEAL", "AWAKENING" },
  paralysis = { "FULL_RESTORE", "FULL_HEAL", "PARLYZ_HEAL" },
}
local AUTO_X_ITEM = {
  { id = "X_ATTACK", stat = "atk" },
  { id = "X_DEFEND", stat = "def" },
  { id = "X_SPEED", stat = "spd" },
  { id = "X_SPECIAL", stat = "spc" },
  { id = "DIRE_HIT", flag = "focusEnergy" },
  { id = "GUARD_SPEC", flag = "mist" },
}

function Battle:_effectivenessProduct(moveType, defender)
  local percents = self:_typePercents(moveType, defender)
  local eff = 1
  for _, pct in ipairs(percents) do eff = eff * pct / 100 end
  return eff
end

function Battle:_bagHas(fighter, itemId)
  return fighter.bag and (fighter.bag[itemId] or 0) > 0
end

function Battle:_spendBag(fighter, itemId)
  if not fighter.bag then return end
  local n = fighter.bag[itemId]
  if not n then return end
  if n <= 1 then fighter.bag[itemId] = nil else fighter.bag[itemId] = n - 1 end
end

function Battle:_bestSeBench(fighter, defender)
  if not defender then return nil end
  local best, bestEff = nil, 1
  for i = 1, #fighter.mons do
    if i ~= fighter.active then
      local bench = fighter.mons[i]
      if bench and bench.hp > 0 then
        local maxEff = 1
        for j = 1, #bench.moves do
          local m = bench.moves[j]
          if self:_hasPp(fighter, m) and m.power > 0 then
            local eff = self:_effectivenessProduct(m.type, defender)
            if eff > maxEff then maxEff = eff end
          end
        end
        if maxEff > 1 then
          if not best or maxEff > bestEff or (maxEff == bestEff and i < best) then
            best, bestEff = i, maxEff
          end
        end
      end
    end
  end
  return best
end

-- Bag item for the active mon: cure → heal ≤50% → X-item while stages flat.
function Battle:_autoItemChoice(fighter, mon)
  if not fighter.bag then return nil end
  -- A wild monster is not a trainer: it never reaches into a bag, even when the
  -- hub seeded its seat with one.
  if isWildSeat(self.mode, fighter) then return nil end

  if mon.status then
    local list = AUTO_STATUS_CURE[mon.status]
    if list then
      for _, id in ipairs(list) do
        if self:_bagHas(fighter, id) then
          return { action = "item", item = id, slot = fighter.active }
        end
      end
    end
  end

  if mon.hp < mon.maxHp and mon.hp * 2 <= mon.maxHp then
    for _, id in ipairs(AUTO_HEAL_PREF) do
      if self:_bagHas(fighter, id) then
        local effect = Effects.itemEffect(id)
        if effect and (effect.heal or effect.healFull or effect.clearAllStatus) then
          return { action = "item", item = id, slot = fighter.active }
        end
      end
    end
  end

  local stagesFlat = mon.stages.atk <= 0 and mon.stages.def <= 0
    and mon.stages.spd <= 0 and mon.stages.spc <= 0
  if stagesFlat and not mon.focusEnergy and not mon.mist then
    for _, row in ipairs(AUTO_X_ITEM) do
      if self:_bagHas(fighter, row.id) then
        if row.flag == "focusEnergy" and not mon.focusEnergy then
          return { action = "item", item = row.id }
        elseif row.flag == "mist" and not mon.mist then
          return { action = "item", item = row.id }
        elseif row.stat and (mon.stages[row.stat] or 0) <= 0 then
          return { action = "item", item = row.id }
        end
      end
    end
  end

  return nil
end

function Battle:_autoChoice(fighter)
  if fighter.mustReplace then
    local foe = self:_autoTarget(fighter)
    local defender = foe and activeMon(foe)
    local se = self:_bestSeBench(fighter, defender)
    if se then return { action = "switch", slot = se } end
    local next_ = firstLiving(fighter.mons)
    if next_ then return { action = "switch", slot = next_ } end
    return nil
  end

  local mon = activeMon(fighter)
  if not mon then return nil end

  -- The forced turns, the same answers `_fillForcedChoices` files (that pass
  -- runs first, so these are reached only when it could not file one) -- and
  -- a player's Bide, trap and hold, which it leaves to the player: an
  -- unanswered one is the FIGHT `_menuFight` would make of it.
  if mon.charging then
    local c = mon.charging
    local forced, called = forcedMoveOf(mon, c.move, c.moveIndex)
    return { action = "fight", move = c.moveIndex, target = c.targetSlot,
             forcedMove = forced, called = called }
  end
  if mon.mustRecharge then
    return { action = "skip", skip = "recharge" }
  end
  if mon.bide then
    local choice = self:_bideChoice(fighter, mon)
    if choice then return choice end
  end
  if mon.trapping and int(mon.trapping.turns, 0) > 0 then
    return trapChoice(mon)
  end
  if self:_isHeld(fighter, mon) and mon.status ~= "sleep" and mon.status ~= "freeze"
     and not (mon.thrashing and mon.thrashing.turns > 0)
     and not (mon.raging and mon.rageMove and mon.rageMove > 0) then
    return { action = "skip", skip = "trapped" }
  end
  if mon.thrashing and mon.thrashing.turns > 0 then
    local foe = self:_autoTarget(fighter)
    if foe then
      local forced, called = forcedMoveOf(mon, mon.thrashing.move, mon.thrashing.moveIndex)
      return {
        action = "fight",
        move = mon.thrashing.moveIndex,
        target = foe.slot,
        forcedMove = forced,
        called = called,
      }
    end
  end
  if mon.raging and mon.rageMove and mon.rageMove > 0 then
    local foe = self:_autoTarget(fighter)
    if foe then
      local forced, called = forcedMoveOf(mon, mon.rageCall, mon.rageMove)
      return { action = "fight", move = mon.rageMove, target = foe.slot,
               forcedMove = forced, called = called }
    end
  end

  local foe = self:_autoTarget(fighter)
  if not foe then
    for _, f in ipairs(self:_foes(fighter)) do
      if f.mustReplace then foe = f; break end
    end
  end
  if not foe then return nil end
  local defender = activeMon(foe)
  if not defender then
    local pick = 1
    for i = 1, #mon.moves do
      if self:_hasPp(fighter, mon.moves[i]) then pick = i; break end
    end
    return { action = "fight", move = pick, target = foe.slot }
  end

  local itemPick = self:_autoItemChoice(fighter, mon)
  if itemPick then return itemPick end

  local foeBoosted = (defender.stages.atk or 0) >= 2
    or (defender.stages.def or 0) >= 2
    or (defender.stages.spd or 0) >= 2
    or (defender.stages.spc or 0) >= 2
    or defender.focusEnergy
  local foeSub = Effects.hasSubstitute(defender)
  local weSlower = self:_speedOf(fighter, mon) < self:_speedOf(foe, defender)

  -- Critical HP: SE retreat (heal already tried via bag).
  if mon.hp * 4 <= mon.maxHp then
    local se = self:_bestSeBench(fighter, defender)
    if se then return { action = "switch", slot = se } end
  end

  -- Behind a boosted / subbed foe at mid-low HP: prefer an SE bench mon.
  if (foeBoosted or foeSub) and mon.hp * 2 <= mon.maxHp then
    local se = self:_bestSeBench(fighter, defender)
    if se then return { action = "switch", slot = se } end
  end

  local function disabled(i)
    return mon.disable and mon.disable.turns > 0 and mon.disable.moveIndex == i
  end

  local pick, pickEff, pickPow = nil, -1, -1
  for i = 1, #mon.moves do
    local m = mon.moves[i]
    if self:_hasPp(fighter, m) and m.power > 0 and not disabled(i) then
      local eff = self:_effectivenessProduct(m.type, defender)
      if not pick or eff > pickEff
         or (eff == pickEff and m.power > pickPow)
         or (eff == pickEff and m.power == pickPow and i < pick) then
        pick, pickEff, pickPow = i, eff, m.power
      end
    end
  end

  if (not pick) or pickEff == 0 then
    local se = self:_bestSeBench(fighter, defender)
    if se then return { action = "switch", slot = se } end
  end

  if pick and pickEff > 1 then
    return { action = "fight", move = pick, target = foe.slot }
  end

  -- Status fails against a Substitute; skip it and trade damage instead.
  if not defender.status and not foeSub then
    local statusPick, statusPri = nil, -1
    for i = 1, #mon.moves do
      local m = mon.moves[i]
      if self:_hasPp(fighter, m) and not disabled(i) and m.power == 0 then
        local pri = AUTO_STATUS_PRI[m.effect]
        if pri and (pri > statusPri
                    or (pri == statusPri and (not statusPick or i < statusPick))) then
          statusPick, statusPri = i, pri
        end
      end
    end
    if statusPick and (weSlower or foeBoosted or not pick or pickEff <= 1) then
      return { action = "fight", move = statusPick, target = foe.slot }
    end
  end

  local stagesFlat = mon.stages.atk <= 0 and mon.stages.def <= 0
    and mon.stages.spd <= 0 and mon.stages.spc <= 0
  -- Do not set up into a boosted foe, behind a substitute, or while slower
  -- at mid-low HP — hit or switch instead.
  if stagesFlat and not mon.focusEnergy and not foeBoosted and not foeSub
     and not (weSlower and mon.hp * 2 <= mon.maxHp) then
    local setupPick = nil
    for i = 1, #mon.moves do
      local m = mon.moves[i]
      if self:_hasPp(fighter, m) and not disabled(i) and m.power == 0 then
        local kind = AUTO_SETUP[m.effect]
        if kind == true or (type(kind) == "string" and (mon.stages[kind] or 0) <= 0) then
          if not setupPick or i < setupPick then setupPick = i end
        end
      end
    end
    if setupPick then
      return { action = "fight", move = setupPick, target = foe.slot }
    end
  end

  if not (pick and pickEff > 0) then
    pick, pickPow = nil, -1
    for i = 1, #mon.moves do
      local m = mon.moves[i]
      if self:_hasPp(fighter, m) and not disabled(i) then
        if not pick or m.power > pickPow
           or (m.power == pickPow and i < pick) then
          pick, pickPow = i, m.power
        end
      end
    end
  end

  pick = pick or 1
  -- An empty sheet is Struggle, not a hang: `_useMove` treats `mustStruggle`
  -- (including `#moves == 0`) as the synthetic STRUGGLE even with no slot.
  return { action = "fight", move = pick, target = foe.slot }
end

-- The computer's answer, as SelectEnemyMove gives it (core.asm :2915-3005).
-- Its forced turns stand as `_autoChoice` filed them -- SelectEnemyMove
-- returns before `.canSelectMove` for every one of them, drawing nothing --
-- and so does a send-out owed after a faint.  Every other answer is a move
-- chosen at `.canSelectMove`, which is not chosen here: it is drawn from the
-- battle's own stream where the cart draws it, after the players' menus --
-- their RUN rolls, their switches, their balls -- and before the speed
-- compare (`_selectComputerMoves`), so `cartPick` files the seat and names no
-- slot yet.  The heuristic's item or switch (the stand-in for TrainerAI, which
-- the referee does not port: its class routine and uses are not on the
-- sheet) keeps its action and is marked the same way: on the cart the move is
-- selected first and TrainerAI then spends the turn on something else in the
-- seat's slot, so the draws -- and the selection the priority bracket and
-- COUNTER read -- happen all the same.
function Battle:_computerChoice(fighter, auto)
  if fighter.mustReplace then return auto end
  if auto.action == "fight" then
    if auto.forcedMove ~= nil or auto.bideStore or auto.trapContinue then return auto end
    return { action = "fight", target = auto.target, cartPick = true }
  end
  if auto.action == "item" or auto.action == "switch" then
    auto.cartPick = true
  end
  return auto
end

-- What autoPick / the timeout sweep files when `_autoChoice` has no answer.
--
-- A living seat in the choice phase that `_autoChoice` cannot describe (empty
-- moves, nothing across the field to aim at) used to return nil, so nothing
-- was filed. The hub then waited out BATTLE_CHOICE_TIMEOUT and retried the
-- same nil (deadline pushed). Solo sets SOLO_CHOICE_TIMEOUT to 0, which this
-- file reads as "no deadline at all", so the NPC never files, the player has
-- already answered, and the band sits on "Waiting for X..." with RUN refused
-- in a trainer fight -- a battle with no way out.
--
-- An empty sheet with a living foe is now a fight (`_autoChoice` names slot 1;
-- `_useMove` turns that into Struggle). Skip remains for the leftover case:
-- a living seat with nobody across the field to aim at. A mustReplace seat
-- with no living bench stays nil: that seat cannot skip a send-out, and
-- `_checkOver` should have ended the fight.
function Battle:_autoChoiceOrSkip(fighter)
  local auto = self:_autoChoice(fighter)
  if auto and isComputerSeat(self.mode, fighter) then
    auto = self:_computerChoice(fighter, auto)
  end
  if auto then return auto end
  if self.phase == "choice" and activeMon(fighter) then
    return { action = "skip" }
  end
  return nil
end

-- File that pick for a seat that has nobody to send one.
--
-- The npc side of a coop_npc is seated like any other fighter and has no
-- connection behind it, so without this the referee would wait out the whole
-- choice deadline every turn and then auto-pick anyway -- a minute a turn, for a
-- decision nothing was ever going to make.  It is deliberately the *same* pick
-- the timeout files rather than a second, cleverer one: both runtimes reproduce
-- it byte for byte (bag / SE / status / setup / switch heuristics above).
--
-- Answers true when a choice was actually filed, so a caller can loop until the
-- machine stops owing.  Filing one may resolve the turn and open the next, which
-- is what makes that loop the thing that carries the fight forward.
function Battle:autoPick(playerId)
  if self.phase ~= "choice" and self.phase ~= "replace" then return false end
  local fighter = self.byId[str(playerId) or ""]
  if not fighter then return false end
  if fighter.choice ~= nil then return false end
  -- Same rule as a human's: in the replace phase only the seats that owe a
  -- send-out may file, so an NPC that is still standing does not answer a turn
  -- that has not opened.  `Hub:fillNpcChoices` calls this in a loop and stops
  -- when nothing files, so the false is how the loop learns to stop.
  if self.phase == "replace" and not self:_owes(fighter) then return false end
  if not fighter.mustReplace and not activeMon(fighter) then return false end

  local auto = self:_autoChoiceOrSkip(fighter)
  if not auto then return false end
  fighter.choice = auto
  self:_emit("chose", {
    slot = fighter.slot, side = fighter.side, text = fighter.name,
  })
  self:_maybeResolve()
  return true
end

-- ------------------------------------------------------------------
-- resolution
-- ------------------------------------------------------------------

function Battle:_openTurn()
  -- A side that is already down must not be asked for a move. Without this,
  -- a faint that left the field in `choice` (or `_closeReplace` after an
  -- empty send-out) opened a window nobody across the field could answer,
  -- and Solo's zero timeout left the band on "Waiting for WILD...".
  if self:_checkOver() then return end
  self.phase = "choice"
  self.resolveDeadline = nil
  self.forcedPending = false
  for _, fighter in ipairs(self.fighters) do
    fighter.choice = nil
    fighter.forced = nil
    -- (`cannotMove` stays: Haze's CANNOT_MOVE is the seat's selection until
    -- a move menu writes another one -- `_selectsAnew`.)
    -- MainInBattleLoop resets both FLINCHED bits as a turn opens
    -- (core.asm :293-300), so a flinch landed on a monster that had already
    -- moved dies here instead of costing it the NEXT turn -- unless the
    -- player's monster is using Rage or must recharge, when the cart jumps
    -- past the reset to `.selectEnemyMove`.  A raging monster a slower foe
    -- flinched therefore loses its next Rage to that flinch (`_runGates`).
    -- (A flinch that lands runs ClearHyperBeam on its target, so a monster
    -- flinched after its HYPER BEAM is no longer recharging here, and is
    -- reset like any other.)
    --
    -- "The player" is the owner's rule (`isPlayerSeat`): side a against the
    -- computer, and BOTH sides of a link fight (1v1, coop_pvp), each as its
    -- own console runs this for its own monster.  There the skip is kept,
    -- per seat, for that seat's own fielded monster -- a co-op side holds two
    -- players, where the cart had one, and each one's rage protects only its
    -- own flinch.  The skip also spares the enemy's bit on the cart, but in a
    -- one-on-one that bit is never set at this point (only the player's own
    -- move can flinch the enemy, and a raging or recharging player's last move
    -- was Rage or Hyper Beam, neither of which flinches), so the computer's
    -- seats are reset like everyone else's rather than inventing whose rage
    -- would guard them in a 2v2.
    local mon = activeMon(fighter)
    local kept = nil
    if isPlayerSeat(self.mode, fighter) and mon and (mon.raging or mon.mustRecharge) then
      kept = mon
    end
    for i = 1, #fighter.mons do
      if fighter.mons[i] ~= kept then fighter.mons[i].flinch = false end
    end
  end
  self.deadline = (self.choiceTimeout > 0) and (self.now + self.choiceTimeout) or nil
  -- Before the window opens, not after: a player deciding this turn is looking
  -- at the rosters, and anything a status or a bench potion moved last turn has
  -- to be on them by the time the menu is up.  Faints are already current --
  -- `_faint` publishes inside its own batch -- so on most turns this emits
  -- nothing at all.
  self:_syncTeams()
  self:_emit("turn", { amount = self.turn })
  self:_fillForcedChoices()
  -- When every living seat is forced, do not resolve in this same call: the
  -- turn event has to reach clients before the next resolve dumps more events
  -- (wait lines and anim pacing). tick() advances the chain one step.
  if not self:_anyoneOwes() then
    self.forcedPending = true
    self.deadline = nil
  end
end

-- ------------------------------------------------------------------
-- the replace phase
-- ------------------------------------------------------------------
--
-- A faint with a living bench used to be folded into the *next* choice window:
-- the referee incremented the turn, opened it, and the seat's replacement rode
-- in alongside everybody else's fight.  That is one window with an empty box in
-- it -- the player picked a move at a foe that was not on the field yet, and
-- the successor only walked out when the turn after that resolved.  Vanilla
-- never does this, and neither does the host sim beside it: `CoopSim`'s
-- `announceFaint` sends an NPC's next monster out inside the faint batch and
-- asks a player's seat before the fight goes on.
--
-- So the referee holds a phase of its own between the two turns.  Nothing else
-- is asked for, nothing resolves, and the turn number does not move: the fight
-- is still on the turn whose faint opened this.  When the last owed replacement
-- is in, `_resolveSwitches` fields them all (`switch` + `send`) and only then
-- does the next turn open.  For a seat with no connection behind it that whole
-- phase closes inside one `Hub:flushBattle` -- `fillNpcChoices` runs before the
-- drain -- so the client reads one batch: faint ... switch ... send ... turn.

function Battle:_anyMustReplace()
  for _, fighter in ipairs(self.fighters) do
    if fighter.mustReplace and firstLiving(fighter.mons) ~= nil then return true end
  end
  return false
end

-- Solicitation: one `turn` per owing seat, carrying the seat's **field slot**.
--
-- That slot is the whole of the wire change, and it is the client contract:
--   * `turn` WITH `slot` -- this seat is being asked for a replacement.  Its
--     own client opens the switch picker; everyone else holds on "X is
--     choosing who to send out...".
--   * `turn` WITHOUT `slot` -- the ordinary choice window is open (`_openTurn`).
-- No new kind, no new field: `slot` is already in `events.FIELDS` and already
-- rides `Wire.battleEvent` kind-agnostically, so a client built before this
-- ignores it and degrades to the old behaviour rather than breaking.
--
-- Seat order is `self.fighters`, which is side a then side b in seating order
-- -- ascending field slot, and the same order in both runtimes.
function Battle:_openReplace()
  self.phase = "replace"
  self.resolveDeadline = nil
  self.forcedPending = false
  for _, fighter in ipairs(self.fighters) do
    fighter.choice = nil
    fighter.forced = nil
  end
  self.deadline = (self.choiceTimeout > 0) and (self.now + self.choiceTimeout) or nil
  -- The other window a player answers from, and the same reason: whoever is
  -- picking a replacement is picking it off the roster.
  self:_syncTeams()
  for _, fighter in ipairs(self.fighters) do
    if self:_owes(fighter) then
      self:_emit("turn", { amount = self.turn, slot = fighter.slot })
    end
  end
end

-- Every replacement is in: field them, then open the turn they were owed for.
function Battle:_closeReplace()
  self:_resolveSwitches()
  self.turn = self.turn + 1
  self:_openTurn()
end

-- The battle Speed, as stored: the stage, the badge and a paralysis are
-- already in it (Effects' stored-stat note), so reading it is the whole rule
-- -- which is how the cart's turn order reads wBattleMonSpeed.  `fighter` is
-- kept for the callers' shape.
function Battle:_speedOf(fighter, mon)
  return mon.cur.spd
end

-- The bracket an action moves in: the selected move's (Effects.movePriority),
-- as `_selectionOf` names it.  Read off the selection, as the cart reads
-- wPlayerSelectedMove before anything runs: a Metronome moves at
-- Metronome's priority whatever it calls, and a disobedient monster at the
-- priority of the move it was told to use, whatever it does instead.  A
-- forced replay is the move it replays (`forcedMoveOf`), never Struggle.
-- A computer seat's item or switch moves in the bracket of the move
-- SelectEnemyMove picked before TrainerAI threw it away (`picked`,
-- `_selectionOf`).
function Battle:_priorityOf(fighter, mon)
  return Effects.movePriority(fighter.selectedMove)
end

-- Whether this seat's menu hands it STRUGGLE: the player's AnyMoveToSelect
-- (`mustStruggle`), or the computer's SelectEnemyMove, which never reads PP
-- (`computerMustStruggle`).  A link foe is a player on its own cart and keeps
-- its PP.
function Battle:_struggles(fighter, mon)
  if isComputerSeat(self.mode, fighter) then return computerMustStruggle(mon) end
  return mustStruggle(mon)
end

-- A move the seat may pick for its PP: any, for the computer
-- (`computerMustStruggle`'s note); one with PP left for a player.
function Battle:_hasPp(fighter, move)
  return isComputerSeat(self.mode, fighter) or int(move.pp, 0) > 0
end

-- What this turn leaves in wPlayerSelectedMove / wEnemySelectedMove, before
-- anything runs -- read for the priority bracket and by COUNTER
-- (`_counterDamage`).  A forced replay's move; STRUGGLE when the menu would
-- hand it out (`_struggles`); else the chosen slot's.  Two cart rules keep
-- LAST turn's selection standing instead, because no menu is opened:
--   * asleep or frozen, MainInBattleLoop jumps past MoveSelectionMenu
--     (core.asm :308-311) and SelectEnemyMove returns before writing
--     (:2946-2948) -- so a sleeping monster's priority is last turn's move's;
--   * a recharge, a Bide's store or a trap's continuation skips the menu
--     the same way (:293-295, :311-313).
-- A monster held by a trap selects CANNOT_MOVE (:318-321, :2953-2955): nil.
-- So does a seat whose CANNOT_MOVE Haze wrote and no menu has written over
-- since (`cannotMove`, `_selectsAnew`).
-- A player's seat that switched, used an item or ran selected nothing the
-- referee can name (the cart answers from its menu cursor): nil.  The
-- computer's item or switch is TrainerAI's, made after SelectEnemyMove had
-- selected a move (`_cartMovePick`'s `picked`): that move.
function Battle:_selectionOf(fighter, mon)
  local choice = fighter.choice
  if not choice or not mon then return nil end
  if fighter.cannotMove then return nil end
  if choice.action == "skip" then
    if choice.skip and choice.skip ~= "trapped" then return fighter.selectedMove end
    return nil
  end
  if choice.action ~= "fight" then
    if choice.picked and isComputerSeat(self.mode, fighter) then
      if self:_struggles(fighter, mon) then return STRUGGLE end
      return mon.moves[choice.picked]
    end
    return nil
  end
  if choice.forcedMove then return choice.forcedMove end
  if choice.stale or mon.status == "sleep" or mon.status == "freeze" then
    return fighter.selectedMove
  end
  if self:_struggles(fighter, mon) then return STRUGGLE end
  return mon.moves[choice.move or 0]
end

-- Whether this turn writes a new selection over the seat's
-- wPlayerSelectedMove / wEnemySelectedMove -- the only thing that lifts the
-- CANNOT_MOVE HazeEffect_ wrote there (move_effects/haze.asm :24-31,
-- `cannotMove`).  Nothing resets it at a turn's open, a send-out or a faint:
-- it is the side's selection byte, and it stands until
--   * the player's MoveSelectionMenu runs -- an ordinary FIGHT of an awake
--     monster (MainInBattleLoop `.selectPlayerMove`).  A recharge, Rage, a
--     thrash or a charge skips every menu (:293-303); asleep, frozen, a Bide
--     or a trap of its own skips the move menu (:308-313); a held monster
--     writes CANNOT_MOVE again (:314-321); a switch, an item or a RUN leaves
--     the byte alone (`.selectPlayerMove`'s wActionResultOrTookBattleTurn);
--   * the computer's SelectEnemyMove reaches `.canSelectMove`: none of its
--     forced turns (:2938-2955, `_fillForcedChoices`) and not asleep or
--     frozen (:2946-2948).
-- So a target Haze woke that then recharges, rages, thrashes, charges,
-- stores energy or keeps a trap going loses every one of those turns in
-- silence (`_resolveFights`) for as long as the state lasts -- the cart's
-- own lock, kept.  Every side of a link fight is a player on its own cart.
function Battle:_selectsAnew(fighter, mon)
  local choice = fighter.choice
  if not choice or not mon then return false end
  local asleep = mon.status == "sleep" or mon.status == "freeze"
  if isComputerSeat(self.mode, fighter) then
    return not fighter.forced and not asleep
  end
  return choice.action == "fight" and choice.forcedMove == nil and not asleep
    and not choice.stale
end

-- The battler opposite this one: the foe seat in the same position if it
-- stands, else the nearest standing foe -- `_retarget` aimed at the mirror
-- slot, which is BattleSim3's oppositeFoe (Move.lua:746-752) in this
-- referee's terms.  Gen 1 has exactly one opponent, so a cart rule that says
-- "the enemy" with no target to read it off -- the Reflect the confusion
-- self-hit checks, the battler an X item's re-penalty lands on -- asks this
-- in a 2v2.  nil when the other side has nobody standing.
function Battle:_oppositeFoe(fighter)
  local other = (fighter.side == "a") and "b" or "a"
  return self:_retarget(fighter, Events.fieldSlot(other, fighter.index))
end

-- chart[atkType + 1][defType + 1], one percent per defender type, because
-- Damage.compute applies them as separate truncating steps the way the
-- original does.  A missing row, a missing cell or no chart at all reads as
-- neutral: a party naming a type this match's chart has no row for is a
-- well-formed party, and refusing it over a lookup would be worse than
-- fighting it straight.
function Battle:_typePercents(moveType, defender)
  local row = self.chart and self.chart[moveType + 1] or nil
  local out = {}
  for i = 1, #defender.types do
    local pct = 100
    if type(row) == "table" then
      local cell = tonumber(row[defender.types[i] + 1])
      if cell then pct = floor(cell) end
    end
    out[#out + 1] = pct
  end
  if #out == 0 then out[1] = 100 end
  return out
end

local function hasType(mon, typeId)
  for i = 1, #mon.types do
    if mon.types[i] == typeId then return true end
  end
  return false
end

-- AdjustDamageForMoveType's walk (core.asm :5121-5175), for a hit's damage
-- and its lines: the percents to apply, in order, and the percent the walk
-- leaves in wDamageMultipliers.  With the ruleset's `chartOrder` (`chartRows`)
-- that is every TypeEffects row whose attacker is the move's type and whose
-- defender is either of the target's types -- once per row, a mono type
-- matching it once -- in table order, each row's multiplier its `chart`
-- cell, and the last one applied is the one left (EFFECTIVE, 100, when no
-- row matched).  Without the order the cart's rounding order and its last
-- row are unknowable: the chart's cells are applied per defender type and
-- the second value is nil, which `_typeLine` / the miss text read as the
-- product -- the referee's reading before the order was uploaded.
function Battle:_typeRows(moveType, defender)
  if not self.chartRows then return self:_typePercents(moveType, defender), nil end
  local row = self.chart and self.chart[moveType + 1] or nil
  local out, last = {}, 100
  for _, pair in ipairs(self.chartRows) do
    if pair[1] == moveType and hasType(defender, pair[2]) then
      local cell = type(row) == "table" and tonumber(row[pair[2] + 1]) or nil
      -- A negative cell is an immunity, as Damage.compute reads one.
      last = cell and max(0, floor(cell)) or 100
      out[#out + 1] = last
    end
  end
  return out, last
end

-- DisplayEffectiveness (engine/battle/display_effectiveness.asm): the
-- multiplier AdjustDamageForMoveType left -- the last row's with the order
-- (`_typeRows`), else the product -- over EFFECTIVE is "It's super
-- effective", under it "It's not very effective", and nothing at it.
local function typeLine(percents, last)
  local effectiveness = last
  if effectiveness == nil then
    effectiveness = 100
    for _, pct in ipairs(percents or {}) do effectiveness = effectiveness * pct / 100 end
  end
  if effectiveness > 100 then return "It's super\neffective!" end
  if effectiveness < 100 then return "It's not very\neffective..." end
  return nil
end

function Battle:_resolveTurn()
  self.phase = "resolving"
  -- Armed for the rare case resolution does not leave this phase in the same
  -- call -- a throw mid-resolve used to leave the field wedged forever, and
  -- Hub.receive now contains those throws so the clock has to finish the job.
  self.resolveDeadline = (self.resolveTimeout > 0)
    and (self.now + self.resolveTimeout) or nil

  if self:_resolveRuns() then return end
  -- The players' switches and items first (DisplayBattleMenu runs them
  -- before the order is asked); the computer's wait for its own slot of the
  -- order, inside `_resolveFights`.  SelectEnemyMove runs after them, so it
  -- sees what they did to a trap (`_reselectComputer`).
  self:_resolveSwitches(true)
  self:_resolveItems()
  if not self.result then self:_reselectComputer() end
  if not self.result then self:_selectComputerMoves() end
  -- Each seat's residual comes at the end of its own slot, inside the order
  -- (`_resolveFights`); there is no end-of-turn pass.
  local cut = self:_resolveFights()
  -- CheckNumAttacksLeft, the last thing a cart turn does (core.asm :409,
  -- :460): a trap whose counter ran out lets go -- reached only when both
  -- slots went by, so not on a turn a faint cut short (`cut`).
  if not self.result and not cut then self:_checkNumAttacksLeft() end
  -- Unconditional, because a queue nobody drains is exp that silently never
  -- happened.
  self:_drainExp()
  if not self.result then self:_checkOver() end

  -- A seat that fell with a bench left is asked before anything else happens;
  -- see the replace-phase note above.  The turn does not advance here: it
  -- advances in `_closeReplace`, once the successor is actually on the field.
  if not self.result and self:_anyMustReplace() then
    self:_openReplace()
    return
  end

  if not self.result then
    self.turn = self.turn + 1
    self:_openTurn()
  end
end

-- SelectEnemyMove (core.asm :2915-2955) runs after the player's menu, so
-- the computer's selection is made against the field the player's switch
-- and item left: a trap the computer was keeping going that a switch let go
-- (SendOutMon's `res USING_TRAPPING_MOVE` on the enemy, :1754-1755), and a
-- hold on it that the player's trapper switching out or spending its last
-- turn on an item let go (`_itemTrapStep`), both leave nothing for
-- `.noLinkBattle` to keep -- it reaches `.canSelectMove` and picks afresh.
-- The forced fill `_fillForcedChoices` made at the turn's open is replaced
-- by the computer's pick (`_autoChoiceOrSkip`, the same one `autoPick` files)
-- -- not the stale trapping move run fresh, which is the player's cart's.
function Battle:_reselectComputer()
  for _, fighter in ipairs(self.fighters) do
    local choice = fighter.choice
    local mon = activeMon(fighter)
    if fighter.forced and choice and mon and isComputerSeat(self.mode, fighter) then
      local released = (choice.trapContinue and not mon.trapping)
        or (choice.skip == "trapped" and not self:_isHeld(fighter, mon))
      if released then
        fighter.forced = nil
        fighter.choice = self:_autoChoiceOrSkip(fighter)
      end
    end
  end
end

-- AIMoveChoiceModification1's StatusAilmentMoveEffects (trainer_ai.asm):
-- EFFECT_01 (the unused sleep), SLEEP_EFFECT, POISON_EFFECT, PARALYZE_EFFECT.
local AI_STATUS_EFFECTS = { [1] = true, [32] = true, [66] = true, [67] = true }
-- AIMoveChoiceModification3's `.betterMoveFound` effects: SUPER_FANG_EFFECT,
-- SPECIAL_DAMAGE_EFFECT, FLY_EFFECT.
local AI_BETTER_EFFECTS = { [40] = true, [41] = true, [43] = true }
-- AIGetTypeEffectiveness' starting value, $10 (the cart's own comment: it
-- should have been EFFECTIVE, 10): what no matching row leaves.
local AI_NEUTRAL = 16

-- SelectEnemyMove past its forced returns (core.asm :2956-3005), for every
-- computer seat `_computerChoice` filed, in field order, where the cart runs
-- it: `.selectEnemyMove`, after the players' menus and before the speed
-- compare.  A monster asleep or frozen returns before `.canSelectMove`
-- (`and (1 << FRZ) | SLP_MASK / ret nz`) -- no draw, last turn's selection
-- stands (`stale`, `_selectionOf`) -- and so does one the players' items or
-- switches left there; every other one is picked (`_cartMovePick`).
function Battle:_selectComputerMoves()
  for _, fighter in ipairs(self.fighters) do
    local choice = fighter.choice
    local mon = activeMon(fighter)
    if choice and choice.cartPick and mon then
      choice.cartPick = nil
      if mon.status == "sleep" or mon.status == "freeze" then
        if choice.action == "fight" then
          choice.stale = true
          choice.move = choice.move or 1
        end
      else
        self:_cartMovePick(fighter, mon, choice)
      end
    end
  end
end

-- `.canSelectMove` and `.chooseRandomMove` (core.asm :2956-3005).  A monster
-- whose second slot is empty and whose one move is disabled selects STRUGGLE
-- with no draw (`computerMustStruggle`, read again by `_struggles`).  A trainer
-- runs AIEnemyTrainerChooseMoves first (`_aiTrainerMoves`, its seat's
-- `aiMods`); a wild monster does not (`wIsInBattle` 1 jumps straight to
-- `.chooseRandomMove`).  Then one BattleRandom byte per try names a slot --
-- below 25 percent (63) the first, below 50 percent (127) the second, below
-- 75 percent - 1 (190) the third, else the fourth -- and a try that lands on
-- the disabled slot (wEnemyDisabledMove's high nibble) or on an empty one
-- (no move there, or one the AI's list zeroed) draws again.  PP is never read
-- (`computerMustStruggle`'s note).  The slot is wEnemyMoveListIndex
-- (`moveListIndex`); a fight takes it as its move, an item or a switch keeps
-- it as the selection TrainerAI then threw away (`picked`, `_selectionOf`).
function Battle:_cartMovePick(fighter, mon, choice)
  if computerMustStruggle(mon) then
    if choice.action == "fight" then choice.move = 1 else choice.picked = 1 end
    return
  end
  local usable = nil
  if fighter.aiMods and not isWildSeat(self.mode, fighter) then
    usable = self:_aiTrainerMoves(fighter, mon, choice)
  end
  local disabled = (mon.disable and int(mon.disable.turns, 0) > 0)
    and int(mon.disable.moveIndex, 0) or 0
  local slot = nil
  for _ = 1, Effects.REDRAW_GUARD do
    local roll = self.rng:byte()
    local b = (roll < 63 and 1) or (roll < 127 and 2) or (roll < 190 and 3) or 4
    if b ~= disabled and mon.moves[b] ~= nil and (usable == nil or usable[b]) then
      slot = b
      break
    end
  end
  slot = slot or 1
  fighter.moveListIndex = slot
  if choice.action == "fight" then
    choice.move = slot
  else
    choice.picked = slot
  end
end

-- AIGetTypeEffectiveness (core.asm): the FIRST TypeEffects row whose
-- attacker is the move's type and whose defender is either of the target's
-- types -- no product, no second row -- or $10 when none matches.  With the
-- ruleset's `chartOrder` (`chartRows`) that is the cart's walk; without it
-- the order is unknowable, and the target's first type is asked before its
-- second.  The cell's percent stands in for the row's 0 / 5 / 20: above 100
-- is super effective, below it not effective (an immunity included), and a
-- cell of 100 is no row at all.  Answers above / below / at AI_NEUTRAL.
function Battle:_aiTypeEffectiveness(moveType, target)
  local row = self.chart and self.chart[int(moveType, 0) + 1] or nil
  local function cellOf(defType)
    local cell = type(row) == "table" and tonumber(row[defType + 1]) or nil
    return cell and floor(cell) or 100
  end
  local function judged(cell)
    if cell > 100 then return AI_NEUTRAL + 1 end
    if cell < 100 then return AI_NEUTRAL - 1 end
    return AI_NEUTRAL
  end
  if self.chartRows then
    for _, pair in ipairs(self.chartRows) do
      if pair[1] == int(moveType, 0) and hasType(target, pair[2]) then
        return judged(cellOf(pair[2]))
      end
    end
    return AI_NEUTRAL
  end
  for i = 1, #(target.types or {}) do
    local cell = cellOf(target.types[i])
    if cell ~= 100 then return judged(cell) end
  end
  return AI_NEUTRAL
end

-- AIEnemyTrainerChooseMoves (engine/battle/trainer_ai.asm :3-115): every
-- move starts at 10, the disabled slot at $50; the seat's layers run in the
-- class's order, each over the moves in slot order --
--   1: the target has a status: +5 to a power-0 StatusAilmentMoveEffects move;
--   2: only while wAILayer2Encouragement is exactly 1 (`aiLayer2`, the second
--      selection after a send-out): -1 to an effect from ATTACK_UP1_EFFECT up
--      to BIDE_EFFECT, or from ATTACK_UP2_EFFECT up to POISON_EFFECT;
--   3: -1 to a move whose type the target takes super-effectively
--      (`_aiTypeEffectiveness`, power 0 included); +1 to one it takes not
--      very effectively or not at all when the monster knows a "better move"
--      -- SUPER FANG, a SPECIAL_DAMAGE move, FLY, or any damaging move of
--      another type (the scan includes the move judged);
--   4: nothing --
-- and the slots left at the lowest score are the ones `.chooseRandomMove` may
-- land on (the decrement loop and `.filterMinimalEntries` keep exactly the
-- minima).  Each layer reads the moves it looks at with ReadMove, which
-- copies them over wEnemyMoveNum.., the computer's move struct: the last one
-- read is what COUNTER finds there until the monster's own move reloads it
-- (`moveStruct`, `_counterDamage`).  "The target" is the seat the computer
-- is aimed at (Gen 1's one opponent).
function Battle:_aiTrainerMoves(fighter, mon, choice)
  local moves = mon.moves
  local n = min(4, #moves)
  local score = {}
  for i = 1, n do score[i] = 10 end
  local disabled = (mon.disable and int(mon.disable.turns, 0) > 0)
    and int(mon.disable.moveIndex, 0) or 0
  if disabled >= 1 and disabled <= n then score[disabled] = 0x50 end
  local target = choice.target ~= nil and self:_retarget(fighter, choice.target) or nil
  if not target then target = self:_oppositeFoe(fighter) end
  local targetMon = target and activeMon(target)
  local lastRead = nil
  for _, layer in ipairs(fighter.aiMods or {}) do
    if layer == 1 then
      if targetMon and targetMon.status then
        for i = 1, n do
          local m = moves[i]
          lastRead = m
          if int(m.power, 0) == 0 and AI_STATUS_EFFECTS[int(m.effect, 0)] then
            score[i] = score[i] + 5
          end
        end
      end
    elseif layer == 2 then
      if fighter.aiLayer2 == 1 then
        for i = 1, n do
          local m = moves[i]
          lastRead = m
          local effect = int(m.effect, 0)
          if (effect >= 10 and effect < 26) or (effect >= 50 and effect < 66) then
            score[i] = score[i] - 1
          end
        end
      end
    elseif layer == 3 then
      for i = 1, n do
        local m = moves[i]
        lastRead = m
        local eff = targetMon and self:_aiTypeEffectiveness(m.type, targetMon) or AI_NEUTRAL
        if eff > AI_NEUTRAL then
          score[i] = score[i] - 1
        elseif eff < AI_NEUTRAL then
          local better = false
          for j = 1, n do
            local other = moves[j]
            lastRead = other
            if AI_BETTER_EFFECTS[int(other.effect, 0)] then better = true; break end
            if int(other.type, 0) ~= int(m.type, 0) and int(other.power, 0) > 0 then
              better = true
              break
            end
          end
          if better then score[i] = score[i] + 1 end
        end
      end
    end
  end
  if lastRead then
    fighter.moveStruct = { power = int(lastRead.power, 0), type = int(lastRead.type, 0),
                           effect = int(lastRead.effect, 0) }
  end
  local best = nil
  for i = 1, n do
    if best == nil or score[i] < best then best = score[i] end
  end
  local usable = {}
  for i = 1, n do
    if score[i] == best then usable[i] = true end
  end
  return usable
end

-- TryRunningFromBattle (core.asm :1496-1576), the wild arm, for a coop_wild
-- runner (M.RUN_ROLL_MODES): wNumRunAttempts counts every try -- each
-- player's own, as each console keeps its own -- and a runner at least as
-- fast as the wild monster gets away, as does one whose odds pass 255
-- (Effects.runOdds); otherwise one BattleRandom byte at or under the odds
-- does.  "Got away safely!" or "Can't escape!" -- and a failed try has spent
-- the turn (wActionResultOrTookBattleTurn): the seat is in the order and
-- does nothing in its slot.
function Battle:_tryRun(fighter)
  local mon = activeMon(fighter)
  local foe = self:_oppositeFoe(fighter)
  local wild = foe and activeMon(foe)
  local escaped = true
  if mon and wild then
    fighter.runAttempts = int(fighter.runAttempts, 0) + 1
    local odds = Effects.runOdds(self:_speedOf(fighter, mon), self:_speedOf(foe, wild),
      fighter.runAttempts)
    if odds ~= nil then escaped = self.rng:byte() <= odds end
  end
  if escaped then
    self:_say("Got away safely!")
  else
    self:_say("Can't escape!")
  end
  return escaped
end

-- Fleeing is a concession in 1v1/coop_pvp and a wild escape in *wild modes;
-- see Effects.runEndsBattle.  A trainer fight never gets here: its RUN is
-- refused at the menu (`_normaliseChoice`), as the cart sends it back to
-- DisplayBattleMenu.  A coop_wild runner rolls first (`_tryRun`), in field
-- order, and the first one to get away ends the fight.
function Battle:_resolveRuns()
  local running = {}
  for _, fighter in ipairs(self.fighters) do
    if fighter.choice and fighter.choice.action == "run" then
      running[#running + 1] = fighter
    end
  end
  if #running == 0 then return false end

  if M.RUN_ROLL_MODES[self.mode] then
    local away = nil
    for _, fighter in ipairs(running) do
      if self:_tryRun(fighter) then away = fighter; break end
    end
    if not away then return false end
    running = { away }
  end

  local sides = {}
  for _, fighter in ipairs(running) do
    sides[fighter.side] = true
    self:_emit("run", { slot = fighter.slot, side = fighter.side, text = fighter.name })
  end

  if sides.a and sides.b then
    self:_finish("draw", nil, nil, "run")
  elseif sides.a then
    self:_finish("win", self:_sidePlayers("b"), self:_sidePlayers("a"), "run")
  else
    self:_finish("win", self:_sidePlayers("a"), self:_sidePlayers("b"), "run")
  end
  return true
end

-- Whether a choice is the computer's item or voluntary switch, which the cart
-- spends in its own slot of the turn order: MainInBattleLoop calls TrainerAI
-- at `.enemyMovesFirst` / after ExecutePlayerMove (core.asm :413-460), and
-- only a trainer's AI ever uses an item or switches (TrainerAI returns at
-- once in a wild or a link battle).  A send-out owed after a faint is not
-- the AI's and resolves with everybody's.
function Battle:_computerTurnAction(fighter)
  local choice = fighter.choice
  if not choice or fighter.mustReplace then return false end
  if choice.action ~= "item" and choice.action ~= "switch" then return false end
  return isComputerSeat(self.mode, fighter)
end

-- `inTurn` is the turn's own pass, which leaves the computer's voluntary
-- switches to their slot (`_computerTurnAction`); the replace phase fields
-- everybody's.
function Battle:_resolveSwitches(inTurn)
  for _, fighter in ipairs(self.fighters) do
    local choice = fighter.choice
    if choice and choice.action == "switch"
       and not (inTurn and self:_computerTurnAction(fighter)) then
      -- ReplaceFaintedEnemyMon zeroes wAILayer2Encouragement after the
      -- send-out (core.asm :906-911); TrainerAI's own switch does not.
      if not inTurn and fighter.mustReplace then fighter.aiLayer2 = 0 end
      self:_switchIn(fighter, choice.slot)
    end
  end
end

-- One seat's switch-in: LoadBattleMonFromParty and the send-out around it.
function Battle:_switchIn(fighter, slot)
  local mon = fighter.mons[slot]
  if not (mon and mon.hp > 0) then return end
  -- The monster going back keeps nothing of the battle struct: a Transform
  -- and a MIMIC are undone the moment it leaves (`Effects.restoreMoves`), so
  -- a bench monster's moves, types and species are its own again.  And a
  -- TOXIC is plain poison on the bench: BADLY_POISONED is a BattleStatus3
  -- bit, which the next send-out clears (SendOutMon, core.asm :1747-1752),
  -- while the party's status byte only ever held PSN -- so it comes back
  -- poisoned at a sixteenth a turn, its counter forgotten.
  local leaving = fighter.active and fighter.mons[fighter.active]
  if leaving and leaving ~= mon then
    Effects.restoreMoves(leaving)
    if leaving.status == "toxic" then leaving.status = "poison" end
    leaving.toxicLinger = nil
  end
  fighter.active = slot
  fighter.mustReplace = nil
  -- The seat's monster changed: its own participation set resets and the
  -- standing opposition re-marks into it, while the incoming monster joins
  -- the sets of the foes it is now in against.
  self:_refield(fighter)
  -- wPlayerUsedMove / wEnemyUsedMove, both zeroed at every send-out
  -- (core.asm :767-769, :1303-1305, :1741-1743): MIRROR MOVE has nothing to
  -- copy until somebody moves again.
  for _, seat in ipairs(self.fighters) do
    for i = 1, #seat.mons do seat.mons[i].lastUsedMove = nil end
  end
  Effects.restoreMoves(mon)
  mon.toxicLinger = nil
  mon.charging = nil
  mon.invulnerable = false
  mon.thrashing = nil
  mon.raging = false
  mon.rageMove = 0
  mon.rageCall = nil
  mon.trapped = nil
  mon.trapping = nil
  mon.bide = nil
  mon.substitute = 0
  mon.subAtZero = nil
  mon.lightScreen = false
  mon.reflect = false
  mon.mist = false
  mon.focusEnergy = false
  mon.transformed = false
  mon.xAccuracy = false
  mon.leechSeed = nil
  mon.disable = nil
  -- SendOutMon / EnemySendOutFirstMon zero all three BattleStatus bytes
  -- (`ld hl, wPlayerStatsToDouble` and four `ld [hli], a`, core.asm
  -- :1744-1749; the enemy's :1292-1299), not only the bits above: CONFUSED
  -- and FLINCHED (BattleStatus1) and NEEDS_TO_RECHARGE (BattleStatus2) go
  -- too, so a monster that left confused comes back clear-headed.
  mon.confusion = 0
  mon.flinch = false
  mon.mustRecharge = false
  -- ...and BattleStatus3's BADLY_POISONED, so a monster a sheet sent in as
  -- TOX from the bench is plainly poisoned, as the leaving one above is.
  if mon.status == "toxic" then mon.status = "poison" end
  -- LoadBattleMonFromParty: party stats -> unmodified -> battle, the
  -- penalty, this seat's badges, and every stage back to neutral.
  Effects.loadBattleStats(mon, fighter.badges)
  self:_clearTrapsFrom(fighter.slot)
  -- `mon` is the index the referee just fielded -- `slot`, already
  -- normalised to a party position by `_normaliseChoice`.  This is the one
  -- that matters most: a forced post-faint replacement lands here too, so
  -- without it a seat holding two of a species re-fields the fallen copy on
  -- the client while the referee holds the living one.
  self:_emit("switch", { slot = fighter.slot, side = fighter.side,
                         text = mon.species, speciesId = mon.speciesId,
                         level = mon.level, mon = slot - 1 })
  self:_emit("send", { slot = fighter.slot, side = fighter.side,
                       hp = mon.hp, maxHp = mon.maxHp,
                       text = mon.species,
                       speciesId = mon.speciesId, level = mon.level,
                       mon = slot - 1,
                       -- (No `confused`: the send-out above cleared it.)
                       status = mon.status and M.STATUS_TO_WIRE[mon.status] or nil })
end

function Battle:_clearTrapsFrom(slot)
  for _, fighter in ipairs(self.fighters) do
    local mon = activeMon(fighter)
    if mon and mon.trapped and mon.trapped.fromSlot == slot then
      mon.trapped = nil
    end
    if mon and mon.trapping and mon.trapping.targetSlot == slot then
      mon.trapping = nil
    end
  end
end

function Battle:_resolveItems()
  -- Non-ball items keep Gen1 array order (heals, dolls, vitamins, …). Balls
  -- resolve in a second pass ordered by active-mon speed (fight tie policy),
  -- so the faster thrower spends first and a successful catch aborts the rest.
  -- The computer's items are not here: they wait for its slot of the order
  -- (`_computerTurnAction`, `_resolveFights`).
  for _, fighter in ipairs(self.fighters) do
    if self.result then return end
    local choice = fighter.choice
    if choice and choice.action == "item" and not self:_computerTurnAction(fighter) then
      local effect = Effects.itemEffect(choice.item)
      if not (effect and effect.ball) then
        self:_resolveOneItem(fighter)
        if not self.result then self:_itemTrapStep(fighter) end
      end
    end
  end

  local balls = {}
  for _, fighter in ipairs(self.fighters) do
    local choice = fighter.choice
    if choice and choice.action == "item" and not self:_computerTurnAction(fighter) then
      local effect = Effects.itemEffect(choice.item)
      if effect and effect.ball then
        local mon = activeMon(fighter)
        balls[#balls + 1] = {
          fighter = fighter,
          speed = mon and self:_speedOf(fighter, mon) or 0,
          order = #balls + 1,
        }
      end
    end
  end
  self:_orderActors(balls)
  for _, actor in ipairs(balls) do
    if self.result then return end
    self:_resolveOneItem(actor.fighter)
    if not self.result then self:_itemTrapStep(actor.fighter) end
  end
end

-- UseBagItem (core.asm :2261-2268): an item a player's trapper uses takes
-- the turn its trap would have hit in, and still spends a step of the trap's
-- counter (wPlayerNumAttacksLeft) -- the step that reaches 0 lets go there
-- and then, before SelectEnemyMove looks (`_reselectComputer`).  The held
-- monster's mirror follows (`_trapTurn`'s).  The computer's items are
-- TrainerAI's, which never touch the counter.
function Battle:_itemTrapStep(fighter)
  local mon = activeMon(fighter)
  local trap = mon and mon.trapping
  if not trap or int(trap.turns, 0) <= 0 then return end
  trap.turns = int(trap.turns, 0) - 1
  local held = self:_fighterAtSlot(trap.targetSlot)
  local heldMon = held and activeMon(held)
  if heldMon and heldMon.trapped and heldMon.trapped.fromSlot == fighter.slot then
    heldMon.trapped.turns = trap.turns
  end
  if trap.turns <= 0 then self:_dropTrap(fighter, mon) end
end

-- Sort actors by priority bracket (desc), then active-mon speed (desc), then
-- field order; tied groups flip on one RNG byte >= TIE_BREAK_ROLL.  Shared by
-- fights and ball throws -- a ball carries no `priority`, so every thrower
-- sits in one bracket and the order is Speed's, as it always was.
--
-- pokered's MainInBattleLoop for two battlers (core.asm :369-412): a Quick
-- Attack on one side only moves first, a Counter on one side only moves last,
-- the same move on both sides goes to `.compareSpeed`, and a Speed tie is the
-- coin flip.  BattleSim2's `_orderActors` is the same machine with Gen 2's
-- table; a cart compare between two moves is a bracket compare between two
-- actors, so a field of any size sorts the same way.
function Battle:_orderActors(actors)
  if #actors <= 1 then return end

  table.sort(actors, function(x, y)
    local xp, yp = x.priority or 0, y.priority or 0
    if xp ~= yp then return xp > yp end
    if x.speed ~= y.speed then return x.speed > y.speed end
    return x.order < y.order          -- field order: side a, then side b
  end)

  -- One byte per group of actors in one bracket at one Speed, spent only when
  -- the group is actually tied, so an ordinary turn between two different
  -- speeds costs no draw at all on either runtime.
  local i = 1
  while i <= #actors do
    local j = i
    while j < #actors and actors[j + 1].speed == actors[i].speed
          and (actors[j + 1].priority or 0) == (actors[i].priority or 0) do
      j = j + 1
    end
    if j > i and self.rng:byte() >= M.TIE_BREAK_ROLL then
      for lo = i, i + floor((j - i) / 2) do
        local hi = j - (lo - i)
        actors[lo], actors[hi] = actors[hi], actors[lo]
      end
    end
    i = j + 1
  end
end

-- The monster's own move list, where the party struct keeps it: a
-- TRANSFORMed monster's `preTransform` copy (DecrementPP never touches the
-- party while TRANSFORMED is set), else the list it fights with.  What
-- ItemUsePPRestore restores and its move menu lists.
local function ownMoves(mon)
  local saved = mon.transformed and mon.preTransform
  if type(saved) == "table" and type(saved.moves) == "table" then return saved.moves end
  return mon.moves or {}
end

-- `.restorePP` on a scratch copy of a row: whether it would restore,
-- without restoring.
local function wouldRestorePp(move, amount)
  if type(move) ~= "table" then return false end
  return Effects.restorePp({ pp = move.pp, ppUps = move.ppUps, maxPp = move.maxPp }, amount)
end

-- Whether a player's use of `effect` (a normalised item `choice`: party
-- `slot`, 1-based `move`) is one the cart's ItemUseFailed takes -- the item
-- kept, the turn not spent (`_normaliseChoice`).  ItemUseNotTime: a POKé
-- DOLL outside a wild fight (ItemUsePokeDoll's `dec a / jp nz`), an X item
-- or another battle-only item aimed at a benched monster (the menu never
-- offers it).  ItemUseNoEffect: a PP item whose `.restorePP` restores
-- nothing on the monster's own moves (`ownMoves`), and a medicine with
-- nothing to do -- no HP to restore (a FULL RESTORE at full HP still cures
-- a status, `.notFullHP`'s FULL_HEAL fallthrough) and no status it cures
-- (`.checkMonStatus`).  The fainted cases are `_normaliseChoice`'s own.  An
-- item with no table row, a ball, a vitamin and the POKé FLUTE are always
-- used (the flute's "Now, that's a catchy tune!" spends the turn).
function Battle:_itemFails(fighter, effect, choice)
  if not effect then return false end
  if effect.pokeDoll then return not Effects.isWildMode(self.mode) end
  if effect.ball or effect.vitamin or effect.pokeFlute then return false end
  local partyIdx = choice.slot or fighter.active
  local mon = fighter.mons[partyIdx]
  if not mon then return true end
  if effect.activeOnly and partyIdx ~= fighter.active then return true end
  if effect.xAccuracy or effect.focusEnergy or effect.mist or effect.stage
     or effect.revive then
    return false
  end
  if effect.ppRestore then
    return not wouldRestorePp(ownMoves(mon)[int(choice.move, 0)], effect.ppRestore)
  end
  if effect.ppRestoreAll then
    for _, move in ipairs(ownMoves(mon)) do
      if wouldRestorePp(move, effect.ppRestoreAll) then return false end
    end
    return true
  end
  local heals = (effect.healFull or (effect.heal and effect.heal > 0))
    and mon.hp < mon.maxHp
  local cures = mon.status ~= nil and (effect.clearAllStatus
    or (effect.clearStatuses ~= nil and effect.clearStatuses[mon.status]))
  return not (heals or cures)
end

function Battle:_resolveOneItem(fighter)
  local choice = fighter.choice
  if not (choice and choice.action == "item") then return end

  local effect = Effects.itemEffect(choice.item)
  -- Vitamins apply before the `item` event so `amount=1` can mean "Stat Exp
  -- writeback is owed"; a failed vitamin still spends the bag stack (Gen1)
  -- but must not bump save.statExp on the client.
  local vitaminApplied, vitaminMon, vitaminResult = false, nil, nil
  if effect and effect.vitamin then
    local partyIdx = choice.slot or fighter.active
    local mon = fighter.mons[partyIdx]
    if mon and mon.hp > 0 then
      local result = Effects.applyVitamin(mon, choice.item)
      if result then
        vitaminApplied, vitaminMon, vitaminResult = true, mon, result
        -- The fielded monster's battle stats are rebuilt the way a level-up
        -- mid-fight rebuilds them (Effects.recalcBattleStats); a benched one
        -- is rebuilt by its next switch-in anyway.
        if partyIdx == fighter.active and result.stat ~= "hp" then
          Effects.recalcBattleStats(mon, fighter.badges)
        end
      end
    end
  end
  local itemEv = { slot = fighter.slot, side = fighter.side, text = choice.item }
  if vitaminApplied then itemEv.amount = 1 end
  self:_emit("item", itemEv)
  local label = itemLabel(choice.item)
  local computer = isComputerSeat(self.mode, fighter)
  local wild = Effects.isWildMode(self.mode)
  -- The line the use opens with.  The computer's every item is
  -- AIPrintItemUse's "<TRAINER> used <ITEM> on <MON>!" (trainer_ai.asm,
  -- _AIBattleUseItemText).  The player's is ItemUseText00, "<PLAYER> used
  -- <ITEM>!", where its routine prints it: a ball (ItemUseBall, before the
  -- throw -- not in a trainer fight, which blocks the ball first), X
  -- ACCURACY, GUARD SPEC., DIRE HIT, a POKé DOLL in a wild fight and the X
  -- stat items (PrintItemUseTextAndRemoveItem).  A medicine, a PP restorer
  -- and the POKé FLUTE print only what they did.  The AI's line breaks
  -- before "used" and "on" and names its monster by wEnemyMonNick, bare;
  -- ItemUseText00 breaks at its `text_low`, before the item (K17 / K18).
  if computer then
    local onMon = activeMon(fighter)
    self:_say(fighter.name .. "\nused " .. label .. "\non "
      .. (onMon and onMon.species or "POKéMON") .. "!")
  elseif effect and ((effect.ball and wild) or effect.xAccuracy or effect.mist
      or effect.focusEnergy or (effect.pokeDoll and wild) or effect.stage) then
    self:_say(fighter.name .. " used\n" .. label .. "!")
  end
  -- Spend after the announce (Gen1 bag stack). noConsume (Poké Flute) and
  -- seats with no bag sheet are left alone, and so is a player's use the
  -- cart's ItemUseFailed takes (`_itemFails`): `_normaliseChoice` refuses
  -- one before it is filed, so only a field that moved under a filed choice
  -- gets here with it -- and RemoveUsedItem is never reached then either.
  local fails = not computer and self:_itemFails(fighter, effect, choice)
  if not (effect and effect.noConsume) and not fails then
    self:_spendBag(fighter, choice.item)
  end
  if not effect then
    -- An item the referee has no table row for: ItemUseNoEffect's line.
    self:_say(NO_EFFECT_TEXT)
  elseif effect.ball then
    if not wild then
      -- ThrowBallAtTrainerMon (item_effects.asm :2292-2303): the toss --
      -- TOSS_ANIM whatever the ball, on the thrower's seat (K20) -- then
      -- the trainer knocks it away, and the ball is gone.
      self:_statusAnim(fighter, "TOSS_ANIM")
      self:_say("The trainer\nblocked the BALL!")
      self:_say("Don't be a thief!")
    else
      -- Wild modes seat exactly one monster on side b, so "the first living
      -- foe" and "the only foe" are the same seat -- no aim to spread.
      local foe = self:_firstLivingFoe(fighter)
      local target = foe and activeMon(foe)
      if not target then
        self:_say("But, it failed!")
      else
        local caught, shakes = Effects.catchAttempt(choice.item, target, self.rng)
        -- Gen1 TossBallAnimation chain before the catch text (engine ballChain).
        self:_emitBallChain(fighter, choice.item, caught, shakes)
        -- ItemUseBall's `.printMessage` off wPokeBallAnimData: the shake
        -- count picks ItemUseBallText01..04; a catch is ItemUseBallText05.
        if caught then
          -- ItemUseBallText05 names wEnemyMonNick bare (K17).
          self:_say("All right!\n" .. target.species .. " was\ncaught!")
          local finish = self:_finish("win", self:_sidePlayers(fighter.side),
            self:_sidePlayers(fighter.side == "a" and "b" or "a"), "catch")
          local sheet = Effects.caughtSheet(target)
          if finish and sheet then finish.caught = sheet end
          if finish then finish.catcher = fighter.playerId end
        else
          self:_say(BALL_MISS_TEXT[int(shakes, 0)] or BALL_MISS_TEXT[0])
        end
      end
    end
  elseif effect.pokeDoll then
    if wild then
      -- wEscapedFromBattle, and the fight is over: no line past the use's.
      -- A POKé DOLL escape leaves wBattleResult at 0 too: Pay Day is paid.
      self:_payDayOn(self:_finish("win", self:_sidePlayers(fighter.side),
        self:_sidePlayers(fighter.side == "a" and "b" or "a"), "run"))
    else
      -- ItemUsePokeDoll outside a wild fight is ItemUseNotTime.
      self:_say("OAK: " .. fighter.name .. "!\nThis isn't the\ntime to use that!")
    end
  elseif effect.vitamin then
    if not vitaminApplied then
      self:_say("But, it failed!")
    else
      local mon, result = vitaminMon, vitaminResult
      -- VitaminStatRoseText, "<MON>'s <STAT> rose." -- the cart's line for a
      -- vitamin, which it only takes outside a fight (ItemUseVitamin is
      -- ItemUseNotTime in one); the referee lets it in and says the same.
      local label = ({
        hp = "HEALTH", atk = "ATTACK", def = "DEFENSE",
        spd = "SPEED", spc = "SPECIAL",
      })[result.stat] or "STAT"
      if result.stat == "hp" and result.delta > 0 then
        self:_emit("drain", {
          slot = fighter.slot, side = fighter.side,
          -- ...and what the bar is now out of: an HP UP moves the maximum
          -- itself, so a client told only the new HP would draw the rise
          -- against the old ceiling.
          amount = result.delta, hp = mon.hp, maxHp = mon.maxHp,
        })
      elseif result.delta > 0 then
        self:_emit("stat", {
          slot = fighter.slot, side = fighter.side,
          amount = mon.stats[result.stat],
          text = mon.species .. "'s " .. label .. " rose.",
        })
      end
      -- (wNameBuffer, bare: K17.)
      self:_say(mon.species .. "'s\n" .. label .. " rose.")
    end
  elseif effect.pokeFlute then
    local woke = false
    for _, seat in ipairs(self.fighters) do
      for i = 1, #(seat.mons or {}) do
        local mon = seat.mons[i]
        if mon and mon.status == "sleep" then
          mon.status, mon.statusTurns = nil, 0
          woke = true
          self:_emit("status", {
            slot = seat.slot, side = seat.side,
            text = mon.species .. " woke up!",
          })
        end
      end
    end
    -- ItemUsePokeFlute's `.inBattle`: PlayedFluteHadEffectText then
    -- FluteWokeUpText, or PlayedFluteNoEffectText (data/text/text_6.asm
    -- "# FLUTE", "#MON woke up.": the charmap's POKé) -- whose `para` is a
    -- second line of its own (K18).
    if woke then
      self:_say(fighter.name .. " played the\nPOKé FLUTE.")
      self:_say("All sleeping\nPOKéMON woke up.")
    else
      self:_say("Played the POKé\nFLUTE.")
      self:_say("Now, that's a\ncatchy tune!")
    end
  else
    local partyIdx = choice.slot or fighter.active
    local mon = fighter.mons[partyIdx]
    -- ItemUseNoEffect, "It won't have any effect.", for every use the
    -- party menu turns down (`.healingItemNoEffect` and the PP menus').
    local NO_EFFECT = NO_EFFECT_TEXT
    if not mon then
      self:_say(NO_EFFECT)
    elseif effect.activeOnly and partyIdx ~= fighter.active then
      self:_say(NO_EFFECT)
    elseif effect.faintedOnly and mon.hp > 0 then
      self:_say(NO_EFFECT)
    elseif mon.hp <= 0 and Effects.itemFailsOnFainted(effect) then
      self:_say(NO_EFFECT)
    else
      -- `said`: a PP item's own ItemUseNoEffect line is already out, so the
      -- party menu's fallback below does not print it a second time (the
      -- cart's `.noEffect` prints it once).
      local applied, said = false, false
      -- X ACCURACY, DIRE HIT and GUARD SPEC. set their bit and say nothing
      -- past the use's line (PrintItemUseTextAndRemoveItem; the AI's
      -- AIPrintItemUse).
      if effect.xAccuracy then
        mon.xAccuracy = true
        applied = true
      end
      if effect.focusEnergy then
        mon.focusEnergy = true
        applied = true
      end
      if effect.mist then
        mon.mist = true
        applied = true
      end
      if effect.stage then
        -- ItemUseXStat / AIIncreaseStat: `_xStatItem`.
        self:_xStatItem(fighter, mon, effect.stage.stat, effect.stage.delta)
        applied = true
      end
      if effect.revive then
        local amount = effect.revive
        local hp = amount == 1 and mon.maxHp or max(1, floor(mon.maxHp * amount))
        mon.hp = hp
        mon.status, mon.statusTurns = nil, 0
        self:_emit("drain", {
          slot = fighter.slot, side = fighter.side,
          amount = hp, hp = mon.hp,
        })
        self:_say(mon.species .. "\nis revitalized!")
        applied = true
      end
      -- ItemUsePPRestore works on the PARTY struct (wPartyMon1Moves /
      -- MON_PP, GetMaxPP over the party's own move): a TRANSFORMed monster's
      -- own moves, not the copies its battle struct holds (`ownMoves`).
      -- Then, for the monster out, `.afterRestoringPP` copies all four party
      -- PP bytes over wBattleMonPP (`syncCopies`), so a transformed
      -- monster's copies take its own moves' PP -- and a slot it knows no
      -- move in, 0: a DITTO's copies 2-4 are emptied.
      local rows = ownMoves(mon)
      local function syncCopies()
        if partyIdx ~= fighter.active or rows == mon.moves then return end
        for i = 1, #mon.moves do
          local own = rows[i]
          mon.moves[i].pp = own and max(0, int(own.pp, 0)) or 0
          mon.moves[i].ppUps = own and int(own.ppUps, 0) % 4 or 0
        end
      end
      if effect.ppRestore then
        -- ItemUsePPRestore's move menu leaves wPlayerMoveListIndex at 0 --
        -- `ld a, 0 / ld [wPlayerMoveListIndex], a` after MoveSelectionMenu
        -- (item_effects.asm :1981-1984) -- whatever it restored: the first
        -- slot is the one a later forced or stale turn pays from (`_listIndex`).
        if not isComputerSeat(self.mode, fighter) then fighter.moveListIndex = 1 end
        local move = rows[choice.move]
        if not move then
          self:_say(NO_EFFECT)
          said = true
        else
          -- `.restorePP` against GetMaxPP (Effects.restorePp): a slot past
          -- its wrap comes down to the maximum, and a MAX ETHER on a full
          -- move with PP Ups still reads as restored -- both the cart's.
          if Effects.restorePp(move, effect.ppRestore) then
            syncCopies()
            self:_say("PP was restored.")
            applied = true
            -- Fielded mon only: a bench Ether must not redraw FIGHT.
            if partyIdx == fighter.active then
              self:_emitMoves(fighter, mon, partyIdx)
            end
          else
            self:_say(NO_EFFECT)
            said = true
          end
        end
      end
      if effect.ppRestoreAll then
        local any = false
        for i = 1, #rows do
          local move = rows[i]
          -- `.elixirLoop`: `.restorePP` on every slot that holds a move.
          if move and Effects.restorePp(move, effect.ppRestoreAll) then any = true end
        end
        if any then
          syncCopies()
          self:_say("PP was restored.")
          applied = true
          if partyIdx == fighter.active then
            self:_emitMoves(fighter, mon, partyIdx)
          end
        else
          self:_say(NO_EFFECT)
          said = true
        end
      end
      local healed, healedBy = false, 0
      if effect.healFull then
        local before = mon.hp
        mon.hp = mon.maxHp
        if mon.hp > before then
          self:_emit("drain", {
            slot = fighter.slot, side = fighter.side,
            amount = mon.hp - before, hp = mon.hp,
          })
          healed, healedBy = true, mon.hp - before
        end
      elseif effect.heal and effect.heal > 0 and mon.hp < mon.maxHp then
        local before = mon.hp
        self:_heal(fighter, mon, effect.heal)
        healed, healedBy = true, mon.hp - before
      end
      -- No item cures confusion in Red: ItemUseMedicine and AICureStatus
      -- write the status byte and BADLY_POISONED, never CONFUSED.
      local wasToxic = mon.status == "toxic"
      local cleared = false
      if effect.clearAllStatus then
        if mon.status then
          mon.status, mon.statusTurns = nil, 0
          cleared = true
        end
      elseif effect.clearStatuses and mon.status
         and effect.clearStatuses[mon.status] then
        mon.status, mon.statusTurns = nil, 0
        cleared = true
      end
      -- The Bad Poison bit goes with a cure (ItemUseMedicine's
      -- `.cureStatusAilment` -- `res BADLY_POISONED`, item_effects.asm
      -- :903-905 -- and AICureStatus, trainer_ai.asm :633-635), a lingering
      -- one included.  The player's FULL RESTORE that restored HP takes the
      -- `.healHP` branch instead (:1152-1176), which zeroes the status byte
      -- and leaves BattleStatus3 alone: a TOXIC it cured lingers.
      local healBranch = effect.clearAllStatus and healed and not computer
      if cleared then
        if healBranch then
          if wasToxic then mon.toxicLinger = true end
        else
          mon.toxicLinger = nil
        end
      end
      -- A cure on the player's fielded monster takes ItemUseMedicine's
      -- .cureStatusAilment branch, which rewrites the battle stats from the
      -- party (Effects.reloadPartyStats) -- lifting the stored penalty along
      -- with every badge boost.  A Full Restore that also restored HP takes
      -- the .healHP branch instead (item_effects.asm :1152-1176): the status
      -- goes, the stats stay as they were, penalty included; only at full HP
      -- does it turn into a Full Heal (:976-990).  The computer's cure
      -- (AICureStatus) never touches a stat.
      if cleared and partyIdx == fighter.active and not computer and not healBranch then
        Effects.reloadPartyStats(mon)
      end
      if cleared then
        self:_emit("status", {
          slot = fighter.slot, side = fighter.side,
          text = mon.species .. " recovered",
        })
      end
      -- The party menu's message for the player's medicine
      -- (engine/menus/party_menu.asm): PotionText's "<MON> recovered by <N>!"
      -- for HP, the cure's own line for a status (FULL RESTORE at full HP is
      -- a FULL HEAL), ItemUseNoEffect's when it did nothing.  The computer's
      -- AIPrintItemUse line is all it says.
      if not computer then
        if healed then
          self:_say(mon.species .. "\nrecovered by " .. healedBy .. "!")
        elseif cleared then
          self:_say(mon.species .. (CURE_TEXT[choice.item] or CURE_TEXT.FULL_HEAL))
        elseif not applied and not said then
          self:_say(NO_EFFECT)
        end
      end
    end
  end
end

-- An X item's stat raise: StatModifierUpEffect run on the item user's own
-- turn -- ItemUseXStat (item_effects.asm :1638-1666) for the player's,
-- AIIncreaseStat (trainer_ai.asm) for the AI's -- so an X item is a stat-up
-- move in everything but the menu: the 999 wall, the badge re-run on the user
-- and the re-penalty on the battler opposite, who has no aimed seat to be read
-- off (`_oppositeFoe`).  On a raise UpdateStatDone (effects.asm :457-485)
-- plays the move struct's animation over the user -- XSTATITEM_ANIM, which
-- ItemUseXStat wrote into wPlayerMoveNum (AIIncreaseStat writes
-- XSTATITEM_DUPLICATE_ANIM, the same picture on the enemy's half; contract
-- K20 sends both as XSTATITEM_ANIM) -- and then MonsStatsRoseText,
-- "<USER>'s\n<STAT> rose!" (an UP1 effect: never "greatly").  At +6 or at
-- 999 it is PrintNothingHappenedText and no animation.  Returns
-- Effects.changeStat's outcome.  The one door for both seats' X items: the
-- computer's TrainerAI calls it too.
local X_STAT_LABEL = {
  atk = "ATTACK", def = "DEFENSE", spd = "SPEED",
  spc = "SPECIAL", acc = "ACCURACY", eva = "EVADE",
}

function Battle:_xStatItem(fighter, mon, stat, delta)
  local foe = self:_oppositeFoe(fighter)
  local outcome, after = Effects.changeStat({
    mon = mon, fighter = fighter, stat = stat,
    delta = int(delta, 1),
    mover = fighter, nonMover = foe and activeMon(foe) or nil,
  })
  if outcome == "rose" then
    self:_statusAnim(fighter, "XSTATITEM_ANIM")
    local line = named(fighter, mon) .. "'s\n" .. (X_STAT_LABEL[stat] or "STAT") .. " rose!"
    self:_say(line)
    self:_emit("stat", {
      slot = fighter.slot, side = fighter.side,
      amount = after, stage = after,
      text = Events.plain(line),
    })
  else
    self:_say("Nothing happened!")
  end
  return outcome
end

-- Gen1 TossBallAnimation event stream (mirror BattleState:ballChain / tossAnimFor).
-- Clients pair AnimPlayer opts.ball from the preceding `item` event's text.
function Battle:_emitBallChain(fighter, ballId, caught, shakes)
  local slot, side = fighter.slot, fighter.side
  local toss = ballId == "POKE_BALL" and "TOSS_ANIM"
    or ballId == "GREAT_BALL" and "GREATTOSS_ANIM"
    or "ULTRATOSS_ANIM"
  local function anim(text, amount)
    local fields = { slot = slot, side = side, text = text }
    if amount ~= nil then fields.amount = amount end
    self:_emit("anim", fields)
  end
  anim(toss)
  anim("POOF_ANIM")
  if not caught and (not shakes or shakes == 0) then return end
  anim("HIDEPIC_ANIM")
  anim("SHAKE_ANIM", shakes or 0)
  if not caught then
    anim("POOF_ANIM")
    anim("SHOWPIC_ANIM")
  end
end

function Battle:_resolveFights()
  -- Every battler on the field takes part in MainInBattleLoop's compare
  -- (core.asm :369-412), whatever its seat chose: the cart reaches
  -- `.compareSpeed` -- and on a tie draws the byte -- on a turn the player
  -- switched or used an item (DisplayBattleMenu has run it, and the order is
  -- still asked), on a recharge, a held monster's CANNOT_MOVE, and the
  -- computer's TrainerAI turn alike.  So every seat with a monster out and a
  -- choice is an actor in the order (`_orderActors`), at the Speed it has now
  -- -- a switch-in's own, an X SPEED's raised one -- and in the bracket its
  -- selection names (`_priorityOf`: a switch, an item or a run name none and
  -- sit in the base one).  What an actor then does in its slot:
  --   * a fight: the move (`_useMove`);
  --   * the computer's item or switch: spent there (`_computerTurnAction`);
  --   * a recharge: the gates and "must recharge" (`_rechargeTurn`);
  --   * a held monster's CANNOT_MOVE, a player's switch or item (already
  --     done before the order: `_resolveSwitches`, `_resolveItems`), a run
  --     refused: nothing -- they were in the compare and nowhere else.
  -- A ball that caught, or a POKé DOLL, ended the fight inside
  -- DisplayBattleMenu: the order is never asked.
  if self.result then return end
  local actors = {}
  for _, fighter in ipairs(self.fighters) do
    local choice = fighter.choice
    local mon = activeMon(fighter)
    -- A move menu writes over a CANNOT_MOVE left from an earlier turn
    -- (`_selectsAnew`); nothing else does.
    if self:_selectsAnew(fighter, mon) then
      fighter.cannotMove = nil
      -- A player's MoveSelectionMenu also leaves the move under its cursor
      -- in wPlayerMoveListIndex (the slot DecrementPP spends and MIMIC
      -- overwrites, `_listIndex`) and, through PrintMenuItem's
      -- GetCurrentMove, in the move struct COUNTER reads (`moveStruct`).
      -- STRUGGLE opens no menu (AnyMoveToSelect).  The computer's index is
      -- `.moveChosen`'s (`_cartMovePick` -- or the slot a solo trainer's
      -- brain submitted); its struct is only ever the AI's and its own move's.
      if choice.action == "fight" and not self:_struggles(fighter, mon)
         and mon.moves[choice.move] then
        fighter.moveListIndex = choice.move
        if isPlayerSeat(self.mode, fighter) then
          self:_loadMoveStruct(fighter, mon.moves[choice.move])
        end
      end
    end
    -- wEnemySelectedMove / wPlayerSelectedMove for this turn, which COUNTER
    -- reads off the seat it strikes (`_counterDamage`) and the bracket reads
    -- (`_priorityOf`): `_selectionOf`, rewritten by `_useMove` with a move
    -- its METRONOME / MIRROR MOVE called or its disobedience picked instead.
    fighter.selectedMove = mon and self:_selectionOf(fighter, mon) or nil
    if choice and mon then
      actors[#actors + 1] = {
        fighter = fighter,
        mon = mon,                      -- pinned: see the skip in the loop
        action = choice.action,
        priority = self:_priorityOf(fighter, mon),
        speed = self:_speedOf(fighter, mon),
        order = #actors + 1,
      }
    end
  end
  if #actors == 0 then return false end

  self:_orderActors(actors)

  -- The end of each battler's slot is MainInBattleLoop's (core.asm
  -- :413-467): HandlePoisonBurnLeechSeed, the mover's own residual, right
  -- after its own Execute*Move (or the computer's TrainerAI item or switch)
  -- -- unless that slot knocked the foe out, when `ld a, b / and a / jp z,
  -- Handle*MonFainted` leaves for the faint's handler first and the
  -- knocker-out takes no residual that turn.  The residual returns z on the
  -- mover's own 0 HP, so a monster its own slot or its own residual took
  -- down (EXPLOSION, recoil, STRUGGLE, a crash, a confusion self-hit, the
  -- poison) ends the turn there too: the slower battler never moves.  In a
  -- fight of one seat a side -- the cart's own shape -- any faint in a slot
  -- or a residual therefore ends the turn's moves and residuals, and
  -- CheckNumAttacksLeft, which only the end of both slots reaches, is
  -- skipped (the return value).  A 2v2 has no single foe whose faint ends
  -- the turn, so it keeps the Gold referee's policy (src/BattleSim2/Turn.lua
  -- header): each seat's residual right after its own slot, in the turn's
  -- order, and every seat still acts and takes its residual after a faint.
  -- The residual is the seat's monster out at its slot's end: the one the
  -- computer's switch just sent out, or the one a player's switch fielded
  -- before the order (SendOutMon, then ExecutePlayerMove's early return).
  local single = #self.bySide.a == 1 and #self.bySide.b == 1
  for _, actor in ipairs(actors) do
    if self.result then break end
    local faintsBefore = self.faints
    -- The monster that chose is the only one allowed to act: if it fainted to
    -- a faster attacker, the replacement that came in behind it does not
    -- inherit the turn -- nor spend the AI's item or switch for it.
    local fighter = actor.fighter
    -- Every knockout the slot deals waits for its end (`_reapKo`, K19).
    self.koHeld = true
    if activeMon(fighter) == actor.mon then
      local choice = fighter.choice
      -- ExecuteEnemyMove's `inc [hl]` on wAILayer2Encouragement (core.asm
      -- :5474), past its CANNOT_MOVE return and never reached when TrainerAI
      -- spent the slot: every turn the computer's monster takes its slot to
      -- move -- asleep, recharging or locked in included.  A byte.
      if isComputerSeat(self.mode, fighter) and not self:_computerTurnAction(fighter)
         and not fighter.cannotMove
         and (actor.action == "fight"
              or (actor.action == "skip" and choice.skip == "recharge")) then
        fighter.aiLayer2 = (int(fighter.aiLayer2, 0) + 1) % 256
      end
      if self:_computerTurnAction(fighter) then
        if actor.action == "item" then
          self:_resolveOneItem(fighter)
        else
          self:_switchIn(fighter, choice.slot)
        end
      elseif fighter.cannotMove then
        -- Haze's CANNOT_MOVE on a target it woke or thawed (ExecutePlayerMove's
        -- `inc a / jp z, ExecutePlayerMoveDone`): the turn is gone, silently
        -- -- a recharge's included, and every later turn's until a move menu
        -- writes a new selection (`_selectsAnew`).
      elseif actor.action == "fight" then
        self:_useMove(fighter, actor.mon)
      elseif actor.action == "skip" and choice.skip == "recharge" then
        self:_rechargeTurn(fighter, actor.mon)
      end
    end
    self:_reapKo()
    -- Finalize after each action (not inside `_faint`) so KO + recoil / explode
    -- on the same move can still mutual-faint into a draw, while an empty-bench
    -- KO still stops the slower seat from acting.  The action's faint batch is
    -- complete here, and that is the earliest moment its spoils can be counted
    -- without paying a monster the same action was still killing (`_drainExp`).
    self:_drainExp()
    if not self.result then self:_checkOver() end
    if single and self.faints > faintsBefore then return true end
    if not self.result then
      self:_residualFor(fighter)
      self:_drainExp()
      if not self.result then self:_checkOver() end
      if single and self.faints > faintsBefore then return true end
    end
  end
  return false
end

-- A recharge turn, in the monster's own slot: CheckPlayerStatusConditions
-- runs its sleep, freeze, trapped and flinch checks first (`_firstGates`) --
-- a monster stopped by one keeps NEEDS_TO_RECHARGE, and recharges on a
-- later turn -- and then `.HyperBeamCheck` spends the bit, "<MON> must
-- recharge".  A bit that something cleared before this slot (a flinch, a
-- SLEEP move, a trap starting: ClearHyperBeam) leaves nothing to say.
function Battle:_rechargeTurn(fighter, mon)
  if not self:_firstGates(fighter, mon) then return end
  if mon.mustRecharge then
    mon.mustRecharge = false
    self:_say(named(fighter, mon) .. "\nmust recharge!")
  end
end

-- Whether `move` is the one Disable holds.  TriedToUseDisabledMoveCheck
-- (core.asm :3438-3447) compares wPlayerDisabledMoveNumber -- the move's id,
-- kept from when it was disabled -- with wPlayerSelectedMove, so a forced
-- replay of the same move (a called THRASH, a charge's release) is caught
-- too, and STRUGGLE never is.
function Battle:_isDisabledMove(mon, move)
  local d = mon.disable
  if not d or int(d.turns, 0) <= 0 or type(move) ~= "table" or move == STRUGGLE then
    return false
  end
  local id = d.moveId
  if id == nil then
    local slotMove = mon.moves[d.moveIndex]
    id = slotMove and slotMove.id
  end
  return id ~= nil and move.id == id
end

-- `.MonHurtItselfOrFullyParalysed` (core.asm :3459-3474) on a full
-- paralysis: Bide, the thrash, the charge and the trap the monster held all
-- go (`and ~(STORING_ENERGY | THRASHING_ABOUT | CHARGING_UP |
-- USING_TRAPPING_MOVE)`) -- and INVULNERABLE stays, so a FLY or DIG user
-- paralysed on its release turn hangs out of reach until it switches out or
-- flies again: the cart's glitch, kept.
function Battle:_paralysisClears(fighter, mon)
  mon.bide = nil
  mon.thrashing = nil
  mon.charging = nil
  self:_dropTrap(fighter, mon)
end

-- The seat and monster whose trap holds this one, or nil.  On the cart the
-- trap is the trapper's alone -- USING_TRAPPING_MOVE and its counter in the
-- trapper's battle struct; the held monster has no bit of its own, it is
-- "the enemy" of a trapper (HeldInPlaceCheck reads wEnemyBattleStatus1, and
-- MainInBattleLoop / SelectEnemyMove the other side's bit) -- so a hold is
-- real only while the seat it names still fields a monster trapping this
-- slot.  A `trapped` record without one (a sheet's, or one a send-out
-- orphaned) holds nothing, and `_checkNumAttacksLeft` clears it.
function Battle:_trapperOf(fighter, mon)
  local held = mon and mon.trapped
  if not held or held.fromSlot == nil then return nil end
  local seat = self:_fighterAtSlot(held.fromSlot)
  local trapperMon = seat and activeMon(seat)
  if trapperMon and trapperMon.trapping
     and trapperMon.trapping.targetSlot == fighter.slot then
    return seat, trapperMon
  end
  return nil
end

function Battle:_isHeld(fighter, mon)
  return self:_trapperOf(fighter, mon) ~= nil
end

-- CheckNumAttacksLeft (core.asm :683-697), after the turn's moves and
-- residuals: a trapper whose counter `.MultiturnMoveCheck` took to 0 lets go
-- now -- not on the hit that spent it, so the monster it held stays held for
-- the rest of that turn -- and a hold whose trapper is gone is let go too.
function Battle:_checkNumAttacksLeft()
  for _, fighter in ipairs(self.fighters) do
    local mon = activeMon(fighter)
    if mon and mon.trapping and int(mon.trapping.turns, 0) <= 0 then
      self:_dropTrap(fighter, mon)
    end
  end
  for _, fighter in ipairs(self.fighters) do
    local mon = activeMon(fighter)
    if mon and mon.trapped and not self:_isHeld(fighter, mon) then
      mon.trapped = nil
    end
  end
end

-- The trap this monster holds ends, and the one it held goes free.
function Battle:_dropTrap(fighter, mon)
  if mon.trapping then
    local held = self:_fighterAtSlot(mon.trapping.targetSlot)
    local heldMon = held and activeMon(held)
    if heldMon and heldMon.trapped and heldMon.trapped.fromSlot == fighter.slot then
      heldMon.trapped = nil
    end
    mon.trapping = nil
  end
end

-- CheckPlayerStatusConditions up to `.HyperBeamCheck` (core.asm
-- :3328-3383) -- the part every turn of a monster on the field meets, a
-- recharge's too:
--   * sleep (`.sleepDone`): the counter comes down a step and the turn is
--     gone, "<MON> is fast asleep" or "woke up" -- the waking turn is lost too;
--   * freeze (`.FrozenCheck`): "<MON> is frozen solid";
--   * `.HeldInPlaceCheck`: a foe's trap holds it -- "<MON> can't move".  The
--     monster that chose CANNOT_MOVE never gets here (`_fillForcedChoices`);
--     this is the one that chose before the trap began -- slower than the
--     trapper on the trap's first turn -- or a forced turn (a recharge, Rage,
--     a thrash, a charge, a Bide) the trap caught: none of their counters
--     moves;
--   * the flinch (`.FlinchedCheck`), which spends the bit.
-- Neither sleep nor freeze reads a byte (neither check calls BattleRandom),
-- and both zero wPlayerUsedMove / wEnemyUsedMove (`.sleepDone`,
-- `.FrozenCheck`), so MIRROR MOVE finds nothing to copy.  Returns false when
-- one of them stopped the monster.
function Battle:_firstGates(fighter, mon)
  if mon.status == "sleep" or mon.status == "freeze" then
    local gate = Status.beforeMove(
      { status = mon.status, turnsRemaining = mon.statusTurns }, nil)
    if gate then
      mon.statusTurns = int(gate.turnsRemaining, mon.statusTurns)
      if gate.wokeUp then
        mon.status, mon.statusTurns = nil, 0
        -- WokeUpText (core.asm :3346-3347), the line; the chip's cure rides
        -- the `status` event.
        self:_say(named(fighter, mon) .. "\nwoke up!")
        self:_emit("status", { slot = fighter.slot, side = fighter.side,
                               text = mon.species .. " woke up!" })
      elseif mon.status == "sleep" then
        -- The sleeping monster's animation: SLP_PLAYER_ANIM ahead of
        -- FastAsleepText on the player's turn (core.asm :3339-3344),
        -- SLP_ANIM behind it on the enemy's (:5686-5691).
        local player = isPlayerSeat(self.mode, fighter)
        if player then self:_statusAnim(fighter, "SLP_PLAYER_ANIM") end
        self:_say(named(fighter, mon) .. "\nis fast asleep!")
        if not player then self:_statusAnim(fighter, "SLP_ANIM") end
      elseif mon.status == "freeze" then
        self:_say(named(fighter, mon) .. "\nis frozen solid!")
      end
      if not gate.canMove then
        mon.lastUsedMove = nil
        return false
      end
    end
  end

  if self:_isHeld(fighter, mon) then
    self:_say(named(fighter, mon) .. "\ncan't move!")
    return false
  end

  if mon.flinch then
    mon.flinch = false
    self:_say(named(fighter, mon) .. "\nflinched!")
    return false
  end
  return true
end

-- CheckPlayerStatusConditions (core.asm :3328-3573), in its order: sleep,
-- freeze, held by a foe's trap, flinch [the recharge: `_rechargeTurn`], the
-- Disable step, confusion, the disabled move, paralysis.  So a sleeping or
-- frozen monster's flinch is never reached (the bit waits for the turn's
-- reset), and confusion rolls before paralysis.  `move` is the selected move
-- (the disabled-move check's).  Returns false when a gate stopped the move.
function Battle:_runGates(fighter, mon, move)
  if not self:_firstGates(fighter, mon) then return false end

  self:_tickDisable(fighter, mon)

  if mon.confusion > 0 then
    local hit = self:_selfHitState(fighter, mon)
    -- `.ConfusedCheck` takes the counter down first (`dec [hl] / jr nz`), and
    -- only a monster still confused after it draws the self-hit byte: the
    -- turn it snaps out on draws none.  `.IsConfused` prints IsConfusedText,
    -- "<MON> is confused!", every such turn, ahead of the byte (core.asm
    -- :3418-3424), whether or not it then hurts itself.
    local roll = nil
    if mon.confusion > 1 then
      self:_say(named(fighter, mon) .. "\nis confused!")
      -- CONF_PLAYER_ANIM / CONF_ANIM behind IsConfusedText, before the
      -- byte, on either side's turn (core.asm :3422-3426, :5762-5767).
      self:_statusAnim(fighter, isPlayerSeat(self.mode, fighter)
        and "CONF_PLAYER_ANIM" or "CONF_ANIM")
      roll = self.rng:byte()
    end
    local gate = Status.beforeMove({
      status = "confusion",
      turnsRemaining = mon.confusion,
      level = hit.level,
      attack = hit.attack,
      defense = hit.defense,
    }, roll)
    if gate then
      mon.confusion = int(gate.turnsRemaining, 0)
      if gate.snappedOut then
        self:_say(named(fighter, mon) .. "'s\nconfused no more!")
        self:_emit("status", {
          slot = fighter.slot, side = fighter.side, confused = 0,
          text = mon.species .. "'s confused no more!",
        })
      elseif gate.selfHit then
        self:_selfHitClears(fighter, mon)
        self:_say(HURT_ITSELF_TEXT)
        self:_selfHit(fighter, mon, gate.selfDamage or 0)
        -- `.MonHurtItselfOrFullyParalysed`, after HandleSelfConfusionDamage.
        self:_flyOrChargeAnim(fighter, fighter.moveStruct and fighter.moveStruct.effect)
        return false
      end
      if not gate.canMove then return false end
    end
  end

  if self:_isDisabledMove(mon, move) then
    -- MoveIsDisabledText, "<USER>'s\n<MOVE> is\ndisabled!".
    self:_say(named(fighter, mon) .. "'s\n" .. moveLabel(move) .. " is\ndisabled!")
    return false
  end

  if mon.status == "paralysis" then
    local gate = Status.beforeMove({ status = "paralysis" }, self.rng:byte())
    if gate and gate.fullyParalyzed then
      self:_say(named(fighter, mon) .. "'s\nfully paralyzed!")
      self:_paralysisClears(fighter, mon)
      self:_flyOrChargeAnim(fighter, fighter.moveStruct and fighter.moveStruct.effect)
      return false
    end
  end

  return true
end

-- `.IsConfused` on a self-hit (core.asm :3420-3434): `and 1 << CONFUSED`
-- keeps the confusion and clears every other wPlayerBattleStatus1 bit before
-- HandleSelfConfusionDamage runs -- STORING_ENERGY (a Bide), THRASHING_ABOUT,
-- ATTACKING_MULTIPLE_TIMES, FLINCHED, CHARGING_UP, USING_TRAPPING_MOVE and
-- INVULNERABLE.  So a confused monster that hurts itself loses the Bide it was
-- storing, the thrash it was in (no confusion at its end, since it never ends),
-- the charge it was about to release (and the FLY / DIG vanish with it), and
-- the trap it held, which frees the monster it held.  Rage is a
-- wPlayerBattleStatus2 bit and stays.  The disobedience self-hit
-- (CheckForDisobedience `.monHurtsItself`) calls HandleSelfConfusionDamage
-- directly and clears nothing.
function Battle:_selfHitClears(fighter, mon)
  mon.bide = nil
  mon.thrashing = nil
  mon.flinch = false
  mon.charging = nil
  mon.invulnerable = false
  self:_dropTrap(fighter, mon)
end

-- Where a self-hit's damage goes (both callers: the confusion gate above and
-- the disobedient "won't obey").  HandleSelfConfusionDamage ends on
-- ApplyDamageToPlayerPokemon (core.asm :3714; the enemy's mirror, :5814), and
-- that routine's Substitute branch jumps to AttackSubstitute, which picks the
-- doll by hWhoseTurn -- the turn is the self-hitter's, so the doll it picks
-- is the OTHER side's ("damage will be applied to the other player's
-- Substitute", AttackSubstitute's own header, :4849-4856).  A monster behind
-- its own doll therefore takes nothing and the opposing doll takes the hit:
-- it holds or breaks as under any attack.  With no doll across, the cart
-- subtracts from the other side's stale doll byte, which no field shows and
-- the referee does not keep -- so nothing moves.  Gen 1 has one opponent; in
-- a 2v2 it is the battler opposite (`_oppositeFoe`), the same battler whose
-- Reflect the self-hit borrows.  wDamage keeps the self-hit's number either
-- way (CalculateDamage wrote it; the doll never rewrites it).
function Battle:_selfHit(fighter, mon, amount)
  if Effects.hasSubstitute(mon) then
    local opposite = self:_oppositeFoe(fighter)
    local foe = opposite and activeMon(opposite)
    if foe and Effects.hasSubstitute(foe) then
      self.lastDamage = self:_damage(opposite, foe, amount, nil)
    else
      self.lastDamage = max(0, int(amount, 0))
    end
    return
  end
  self.lastDamage = self:_damage(fighter, mon, amount, nil)
end

-- What HandleSelfConfusionDamage hits with (core.asm :3672-3710), for both of
-- its callers: the confusion gate above and a disobedient "won't obey".  It
-- reads the battle stats as stored: it puts wBattleMon's own Defense in the
-- enemy's slot and runs GetDamageVarsForPlayerAttack, so the Attack and
-- Defense are wBattleMon's -- stages, badges and a stored burn all in them --
-- through the same scaling and 997 cap as any hit, with no crit and no random
-- factor (Status.selfHitDamage's fixed max roll).  And the Reflect check in
-- there still reads the ENEMY's status byte, so it is the opponent's Reflect
-- that doubles the monster's own Defense -- the cart's quirk, kept.  Gen 1 has
-- one opponent; in a 2v2 it is the battler opposite (`_oppositeFoe`).  The
-- enemy's own self-hit is the mirror image (:5774-5805), so this is both
-- seats' rule.
function Battle:_selfHitState(fighter, mon)
  local opposite = self:_oppositeFoe(fighter)
  local opposed = opposite and activeMon(opposite)
  local defense = mon.cur.def
  if opposed and opposed.reflect then defense = defense * 2 end
  return { level = mon.level, attack = mon.cur.atk, defense = defense }
end

-- CheckForDisobedience (core.asm :3830-4007), where ExecutePlayerMove calls it:
-- after the status gates and the disabled-move check, before anything about
-- the move itself.  Only a `badgeRules` seat's traded monster gets here (the
-- caller's gate).  Returns true when the move goes ahead -- with the slot of
-- the move used *instead* as a second value when the monster picked its own
-- (`.useRandomMove`) -- and false when the turn is spent:
--
--   * "nap": `.monNaps` writes SLP and the 1..7 counter over the whole status
--     byte -- a burn, a poison or a paralysis is simply gone -- and touches no
--     stat, so a stored burn or paralysis penalty stays in the battle stats
--     (nothing recomputes them; ItemUseMedicine is the only cure that does).
--     The badly-poisoned flag lives in another byte on the cart and outlives
--     the nap there; so it does here, as `toxicLinger`.
--   * "selfhit": "won't obey!", then HandleSelfConfusionDamage itself --
--     "hurt itself", the same stored-stat hit and borrowed Reflect as
--     confusion's (`_selfHitState`).
--   * "nothing": one of the four `.monDoesNothing` lines.
--   * "random" with every `.useRandomMove` refusal hit falls to "nothing".
function Battle:_obey(fighter, mon, struggling)
  local choice = fighter.choice
  local verdict = Status.obedienceRoll(mon.level,
    Status.obedienceCap(fighter.badges), self.rng)
  if verdict == "obeys" then return true end
  if verdict == "random" then
    local disabled = mon.disable ~= nil and mon.disable.turns > 0
    local slot = Status.disobedientMove(mon.moves, choice.move, disabled,
      struggling, self.rng)
    if slot then return true, slot end
    verdict = "nothing"
  end

  if verdict == "nap" then
    -- The badly-poisoned flag is BattleStatus3's, not the status byte's, so
    -- it outlives the nap (`toxicLinger`): the counter keeps climbing under a
    -- Leech Seed, and a later poison or burn ticks at the toxic rate
    -- (`_residualFor`).
    if mon.status == "toxic" then mon.toxicLinger = true end
    mon.status = "sleep"
    mon.statusTurns = Status.napTurns(self.rng)
    -- BeganToNapText over wBattleMonNick: bare (K17), "<MON> began\nto nap!".
    local text = mon.species .. " began\nto nap!"
    self:_say(text)
    self:_emit("status", { slot = fighter.slot, side = fighter.side,
                           status = M.STATUS_TO_WIRE.sleep, text = Events.plain(text) })
    return false
  end

  if verdict == "selfhit" then
    self:_say(mon.species .. LOAF_TEXT.wont_obey)
    self:_say(HURT_ITSELF_TEXT)
    self:_selfHit(fighter, mon, Status.selfHitDamage(self:_selfHitState(fighter, mon)))
    return false
  end

  self:_say(mon.species .. LOAF_TEXT[Status.loafLine(self.rng)])
  return false
end

-- Every standing battler, { fighter, mon }, in field order: what HAZE
-- reaches -- the cart's two, all four of a 2v2.
function Battle:_standingField()
  local field = {}
  for _, seat in ipairs(self.fighters) do
    local standing = activeMon(seat)
    if standing then field[#field + 1] = { fighter = seat, mon = standing } end
  end
  return field
end

function Battle:_applyPrimary(fighter, mon, targetFighter, targetMon, moveIndex, effectId, moveId, extra)
  extra = extra or {}
  local result = Effects.applyPrimary({
    effectId = effectId,
    overwrite = extra.overwrite == true,
    mimicSlot = extra.mimicSlot,
    rng = self.rng,
    userMon = mon,
    targetMon = targetMon,
    userFighter = fighter,
    targetFighter = targetFighter,
    moveIndex = moveIndex,
    moveId = moveId,
    field = self:_standingField(),
    playerMover = isPlayerSeat(self.mode, fighter),
    unlimitedPp = isComputerSeat(self.mode, targetFighter),
    statusToWire = M.STATUS_TO_WIRE,
  })
  -- Haze's CANNOT_MOVE: the target loses a move it has not used yet, and
  -- its selection is gone with it (COUNTER reads nothing there).
  if result.cannotMove then
    targetFighter.cannotMove = true
    targetFighter.selectedMove = nil
  end
  if result.nothing then self:_say("But nothing happened") end
  for _, text in ipairs(result.messages or {}) do self:_say(text) end
  for _, entry in ipairs(result.events or {}) do
    self:_emit(entry.kind, entry.fields)
  end
  for _, heal in ipairs(result.heals or {}) do
    self:_heal(fighter, mon, heal.amount)
  end
  for _, text in ipairs(result.afterHeals or {}) do self:_say(text) end
  for _, cost in ipairs(result.costs or {}) do
    self:_damage(fighter, mon, cost.amount, nil)
  end
  for _, hit in ipairs(result.directDamage or {}) do
    self:_emit("damage", {
      slot = fighter.slot, side = fighter.side,
      amount = hit.amount, hp = mon.hp,
    })
  end
  if result.movesChanged then self:_emitMoves(fighter, mon) end
end

-- The move's side effect, after its last hit.  `move` is the sheet move that
-- landed: its `chance` (an explicit override, or 0 for the cart's own odds) and
-- its type (FreezeBurnParalyzeEffect's same-type return, CheckDefrost's Fire
-- test) go to Effects.applySide with the two named types and whether the move
-- is the computer's -- StatModifierDownEffect draws its extra miss on the
-- enemy's turn outside a link battle, the seat isComputerSeat names -- or the
-- player's (a freeze clears the target's recharge only then, isPlayerSeat).
function Battle:_applySide(fighter, mon, targetFighter, targetMon, effectId, move)
  local result = Effects.applySide({
    effectId = effectId,
    chance = move.chance,
    moveType = move.type,
    poisonType = self.poisonType,
    fireType = self.fireType,
    computerMover = isComputerSeat(self.mode, fighter),
    playerMover = isPlayerSeat(self.mode, fighter),
    rng = self.rng,
    userMon = mon,
    targetMon = targetMon,
    userFighter = fighter,
    targetFighter = targetFighter,
    statusToWire = M.STATUS_TO_WIRE,
  })
  for _, text in ipairs(result.messages or {}) do self:_say(text) end
  for _, entry in ipairs(result.events or {}) do
    self:_emit(entry.kind, entry.fields)
  end
end

function Battle:_markLastMove(mon, moveIndex)
  if moveIndex and moveIndex >= 1 then mon.lastMoveIndex = moveIndex end
end

-- wPlayerMoveListIndex / wEnemyMoveListIndex, 1-based: the slot the last
-- move menu (or `.moveChosen`) named (`_resolveFights`, `_cartMovePick`),
-- rewritten to the first by a player's TRANSFORM and a PP-restoring item's
-- menu, and never by a forced turn -- so a released trap's fresh run, a
-- stale selection and a disobedient monster's instead-move all pay from it.
-- The seat's own choice before any menu has named one.
function Battle:_listIndex(fighter, choice)
  return fighter.moveListIndex or (choice and choice.move) or 1
end

-- The move struct COUNTER reads off the seat it strikes (wPlayerMoveNum ..
-- wPlayerMoveMaxPP / the enemy's): power and type of the move GetCurrentMove,
-- ReloadMoveData or the trainer AI's ReadMove last copied there -- and its
-- effect, which a gate's STATUS_AFFECTED_ANIM reads (`_flyOrChargeAnim`).  One per
-- seat, as the cart keeps one per side; nothing clears it (a send-out zeroes
-- the number byte alone, which COUNTER never reads).
function Battle:_loadMoveStruct(fighter, move)
  if type(move) ~= "table" then return end
  fighter.moveStruct = { power = int(move.power, 0), type = int(move.type, 0),
                         effect = int(move.effect, 0) }
end

-- DecrementPP's `dec [hl]` and IncrementMovePP's `inc [hl]` on the whole PP
-- byte: PP in the low six bits, the PP Ups (K8 `ppUps`) in the top two.  So a
-- slot at 0 PP borrows -- 63 PP and one PP Up fewer (none wraps to three) --
-- and one at 63 carries the other way.  A sheet past the cart's six bits
-- (a modded move) is plain arithmetic, held at 0.
local PP_MASK = 63
local function stepPp(move, delta)
  local pp = int(move.pp, 0)
  if pp > PP_MASK then
    move.pp = max(0, pp + delta)
    return
  end
  local ups = int(move.ppUps, 0) % 4
  -- A row `copyMove` never read -- one a learn laid in mid-fight (the hubs'
  -- nextMoves12 take a new move's row whole from the client, with its
  -- GetMaxPP and no base) -- has its base read off the maximum it states,
  -- over the PP Ups it has BEFORE this step moves them; one that names no
  -- GetMaxPP keeps its maximum (false, as `copyMove` marks it).
  if move.basePp == nil and move.maxPp ~= nil then
    move.basePp = Effects.basePpOf(max(0, int(move.maxPp, 0)), ups) or false
  end
  local byte = (ups * 64 + pp + delta) % 256
  move.pp = byte % 64
  move.ppUps = floor(byte / 64)
  -- ...and GetMaxPP reads those bits: a borrow or a carry moves the maximum
  -- an ETHER caps at (Effects.getMaxPp; `copyMove`'s `basePp`).
  if move.basePp then move.maxPp = Effects.getMaxPp(move.basePp, move.ppUps) end
end

-- DecrementPP (engine/battle/decrement_pp.asm) on the list index's slot of the
-- battle struct, which is the party's own while the monster is itself; a
-- TRANSFORMed one's party copy is left alone (`ret nz` on TRANSFORMED) -- the
-- copies are the battle struct's alone (`preTransform` keeps the party's).
function Battle:_decrementPp(mon, index)
  local move = mon.moves[index]
  if move then stepPp(move, -1) end
end

-- IncrementMovePP (core.asm :5039-5066), ReloadMoveData's: the list index's
-- slot in the battle struct AND in the party struct, the latter even while
-- TRANSFORMed -- so a transformed monster's own move in that slot gains a PP
-- (`preTransform`) that DecrementPP never takes back.  Either side's.
function Battle:_incrementPp(fighter, mon, index)
  local move = mon.moves[index]
  if move then stepPp(move, 1) end
  local saved = mon.transformed and mon.preTransform
  local own = saved and saved.moves and saved.moves[index]
  if own then stepPp(own, 1) end
end

-- ExplodeEffect zeroes the user's HP word itself -- never its own doll.
function Battle:_faintUser(fighter, mon)
  if mon.hp > 0 then self:_damage(fighter, mon, mon.hp, nil, true) end
end

-- The knockouts an action left, fainted where MainInBattleLoop looks for
-- them (contract K19): `ld a, b / and a / jp z, HandleEnemyMonFainted` -- or
-- HandlePlayerMonFainted -- once ExecutePlayerMove / ExecuteEnemyMove has
-- returned (core.asm :413-467), so after the move's whole tail: the drain,
-- the recoil, the Pay Day line, the hit count, the target's Rage, the side
-- effect, and an EXPLOSION's user taken to 0 (ExplodeEffect zeroes it among
-- the AlwaysHappen routines, without a word).  Until then a monster at 0 HP
-- stays on the field, `activeMon` reading it as gone.  Two at once -- a
-- knockout and the recoil or blast that took the user with it -- go in the
-- cart's order against the computer, the player's first: HandleEnemyMonFainted's
-- FaintEnemyPokemon calls RemoveFaintedPlayerMon (:806) before it prints the
-- enemy's line and writes wBattleResult 0 (:812-818), and HandlePlayerMonFainted
-- removes the player's (:969-972) before it reads the enemy's HP.  So side a,
-- then side b, each in field order; a link fight -- whose consoles each put
-- their own first -- takes the same order.  A residual's knockout keeps its
-- own point (`_residualFor`): this runs at the end of the slot, before it.
function Battle:_reapKo()
  self.koHeld = nil
  for _, side in ipairs(M.SIDES) do
    for _, fighter in ipairs(self.bySide[side]) do
      local mon = fighter.active and fighter.mons[fighter.active]
      if mon and mon.hp <= 0 then self:_faint(fighter, mon) end
    end
  end
end

-- An Explosion / Self-Destruct that did not land.  EXPLODE_EFFECT is the one
-- miss ExecutePlayerMove lets on to `.notDone` (core.asm :3222-3225; the
-- enemy's `.handleExplosionMiss`, :5622-5624), so the user still goes down and
-- HandleBuildingRage still runs on the target it missed -- which is alive, so
-- `ret z` lets it through.  The rage is built before the faint the cart only
-- announces after the move, and the re-penalty it gives the exploder is then
-- wiped with the rest of its battle stats.
function Battle:_explodeMissed(fighter, mon, target, defender)
  self:_buildRage(target, defender, fighter)
  self:_faintUser(fighter, mon)
end

-- A move that did not land, after the caller has said why: MoveHitTest's
-- `.moveMissed` (core.asm :5328-5332) zeroes wDamage, as AdjustDamageForMoveType's
-- 0 does; an EXPLOSION still goes down (`_explodeMissed`) and a JUMP KICK
-- crashes.  PrintMoveFailureText (:3718-3768) takes the crash off a wDamage
-- that is always 0 by then, so it is 1 HP, and it goes through
-- ApplyDamageToPlayerPokemon -- whose Substitute branch, on the crasher's own
-- turn, hits the OTHER side's doll (AttackSubstitute) -- the self-hit's
-- route (`_selfHit`).
function Battle:_moveMissed(fighter, mon, target, defender, effectId, usedSlot)
  self.lastDamage = 0
  if Effects.isExplode(effectId) then self:_explodeMissed(fighter, mon, target, defender) end
  if Effects.isJumpKick(effectId) then
    self:_say(named(fighter, mon) .. "\nkept going and\ncrashed!")
    self:_selfHit(fighter, mon, Effects.jumpKickCrash(self.lastDamage))
  end
  self:_markLastMove(mon, usedSlot)
end

-- What PrintMoveFailureText (core.asm :3718-3735) says for a damaging move
-- that missed, whichever test it was: wDamageMultipliers at 0 -- an immunity
-- -- is "It doesn't affect <TARGET>!"; else an OHKO's $ff in
-- wCriticalHitOrOHKO (a target faster than the user) is "<TARGET>'s
-- unaffected!"; else "<USER>'s attack missed!" -- the accuracy byte, DREAM
-- EATER's sleep check, an invulnerable or a Misted target, a 0.25x zero all
-- alike.  With the cart's marks and breaks (K17 / K18): DoesntAffectMonText,
-- UnaffectedText, AttackMissedText.
function Battle:_damageMissText(fighter, mon, target, defender, immune, ohko)
  if immune then return "It doesn't affect\n" .. named(target, defender) .. "!" end
  if ohko then return named(target, defender) .. "'s\nunaffected!" end
  return named(fighter, mon) .. "'s\nattack missed!"
end

-- MoveHitTest (core.asm :5228-5345) for a move that reaches it, in its
-- order: DREAM EATER against a target that is not asleep misses first
-- (`.dreamEaterCheck`), then an invulnerable target misses (bar SWIFT, whose
-- `ret z` comes first, Effects.hitsInvulnerable), a primary stat drop into
-- Mist misses, X Accuracy hits without drawing (`ret nz`), and only then is
-- the accuracy byte drawn.  None of the four before it draws.  Returns true,
-- or false and why: "dreameater", "invulnerable", "mist" or "accuracy".
function Battle:_hitTest(mon, defender, move, effectId)
  if int(effectId, 0) == 8 and defender.status ~= "sleep" then
    return false, "dreameater"
  end
  if defender.invulnerable then
    local chargeMoveId = defender.charging and defender.charging.moveId
    if not chargeMoveId and defender.charging then
      local charged = defender.moves and defender.moves[defender.charging.moveIndex]
      chargeMoveId = charged and charged.id or nil
    end
    if not Effects.hitsInvulnerable(chargeMoveId, move) then return false, "invulnerable" end
  end
  if Effects.mistBlocks(effectId, defender) then return false, "mist" end
  if Effects.isSwift(effectId) or mon.xAccuracy == true then return true end
  -- CalcHitChance (core.asm :5348-5414) reads the target's evasion through
  -- `c = 14 - EVASIONMOD`: the stage reflected over neutral, so a raised
  -- evasion takes the lowered ratio (+1 reads 66/100) and a lowered one the
  -- raised ratio -- an evasion boost makes the move miss more, not less.
  local hit = Accuracy.hit(move.accuracy, self.rng:byte(), {
    accuracyMod = Effects.stageMult(mon.stages.acc),
    evasionMod = Effects.stageMult(-Effects.clampStage(defender.stages.eva)),
  })
  if not hit then return false, "accuracy" end
  return true
end

-- HandleCounterMove (core.asm :4547-4610): COUNTER's damage, or nil for a
-- miss.  It reads the seat it strikes -- the one opponent on the cart, the
-- target here -- through two different things, and wDamage (`lastDamage`):
--   * wEnemySelectedMove (`selectedMove`, `_resolveFights`): a target whose
--     selection is COUNTER makes it miss.  CANNOT_MOVE ($ff, a held or a
--     Hazed seat: nil) is not COUNTER, and neither is the nothing a player's
--     switch, item or run named;
--   * the target's move struct, wEnemyMovePower / wEnemyMoveType
--     (`moveStruct`): power 0, or a type neither Normal nor Fighting, makes
--     it miss.  The struct is whatever was last copied there -- the move
--     the target used this turn when it got past its gates, else an older
--     one: last turn's, the one its player's move menu last pointed at, the
--     last move a trainer AI layer read (`_aiTrainerMoves`), a Bide's power
--     of 1 -- so a target that never moved this turn (held, fully
--     paralysed, asleep, switched) is countered off that.  Nothing loaded
--     yet is power 0;
--   * so does a wDamage of 0.  wDamage is one word both sides share and
--     nothing resets between turns, so it is the LAST damage anyone dealt --
--     usually the target's hit this turn, but a miss zeroed it and it may be
--     the COUNTER user's own (the cart's comment says as much);
--   * otherwise the damage is wDamage doubled, held at $ffff.  It is not
--     typed (it reaches a Ghost) and not rolled, and a hit test follows.
function Battle:_counterDamage(target)
  if not target then return nil end
  local selected = target.selectedMove
  if type(selected) == "table" and Effects.isCounter(selected) then return nil end
  local struct = target.moveStruct
  if type(struct) ~= "table" or int(struct.power, 0) <= 0 then return nil end
  local moveType = int(struct.type, -1)
  if moveType ~= self.normalType and moveType ~= self.fightingType then return nil end
  if self.lastDamage <= 0 then return nil end
  return min(65535, self.lastDamage * 2)
end

-- A TELEPORT, ROAR or WHIRLWIND that ends a wild fight: either side's
-- (SwitchAndTeleportEffect sets wEscapedFromBattle and never writes
-- wBattleResult), so EndOfBattle pays the Pay Day pile while that is still 0
-- (`_payDayOn`).  `fighter` is the seat that LEAVES -- the `run` event's and
-- the outcome's runner: TELEPORT's user ("<USER> ran from battle!"), ROAR's
-- and WHIRLWIND's target ("<TARGET> ran away scared!" / "was blown away!"),
-- so the player's WHIRLWIND sends the wild monster off and the wild ROAR
-- sends the player's (`_switchAndTeleport`).
function Battle:_concedeRun(fighter)
  self:_emit("run", { slot = fighter.slot, side = fighter.side, text = fighter.name })
  local result
  if fighter.side == "a" then
    result = self:_finish("win", self:_sidePlayers("b"), self:_sidePlayers("a"), "run")
  else
    result = self:_finish("win", self:_sidePlayers("a"), self:_sidePlayers("b"), "run")
  end
  self:_payDayOn(result)
end

-- SwitchAndTeleportEffect (effects.asm :810-911), either side's.  Outside a
-- wild fight (wIsInBattle 2: a trainer or a link fight) it fails: TELEPORT
-- "But it failed!", ROAR / WHIRLWIND "<TARGET> is unaffected!".  In one, the
-- level roll (Effects.teleportEscapes) -- a user at or above its target's
-- level always escapes -- and a roll that fails is TELEPORT's "But it
-- failed!" or the others' "It didn't affect <TARGET>!".  An escape sets
-- wEscapedFromBattle and says TELEPORT's "<USER> ran from battle!", ROAR's
-- "<TARGET> ran away scared!" or WHIRLWIND's "<TARGET> was blown away!"
-- (`.playAnimAndPrintText`, keyed by the move id), and the fight is over
-- (`_concedeRun`, whose runner is TELEPORT's user and the others' target).
-- "Its target" is the monster the move was aimed at -- the cart's one
-- opponent -- on the seat `target`.
function Battle:_switchAndTeleport(fighter, mon, target, defender, move)
  local key = Effects.moveKey(move)
  local teleport = key == "TELEPORT"
  if not Effects.teleportRunAllowed(self.mode) then
    if teleport then
      self:_say("But, it failed!")
    else
      self:_say(named(target, defender) .. "\nis unaffected!")
    end
    return
  end
  if not Effects.teleportEscapes(mon.level, defender.level, self.rng) then
    if teleport then
      self:_say("But, it failed!")
    else
      self:_say("It didn't affect\n" .. named(target, defender) .. "!")
    end
    return
  end
  if teleport then
    self:_say(named(fighter, mon) .. "\nran from battle!")
  elseif key == "ROAR" then
    self:_say(named(target, defender) .. "\nran away scared!")
  else
    self:_say(named(target, defender) .. "\nwas blown away!")
  end
  self:_concedeRun(teleport and fighter or target)
end

-- MimicEffect's pick (effects.asm :1210-1259): the slot of the target's
-- move list it copies, 1-based.  Outside a link battle the player's turn
-- opens that list (`.letPlayerChooseMove`): the seat's own pick
-- (`choice.mimic`, `_normaliseChoice`), and with none -- or one naming no
-- move the target holds now -- the row the menu's cursor starts on, the
-- first (`.selectedmoveknown`).  The computer's turn, and both sides of a
-- link fight, take `.getRandomMove`: `BattleRandom & 3`, redrawn until the
-- slot holds a move.  A target with no moves would spin the cart forever;
-- the referee fails it there, with no draw.
function Battle:_mimicPick(fighter, defender, choice)
  local moves = defender.moves or {}
  if #moves == 0 then return nil end
  if isPlayerSeat(self.mode, fighter) and M.BADGE_MODES[self.mode] then
    local pick = int(choice and choice.mimic, nil)
    if pick ~= nil and moves[pick] ~= nil then return pick end
    return 1
  end
  for _ = 1, Effects.REDRAW_GUARD do
    local slot = self.rng:byte() % 4 + 1
    if moves[slot] ~= nil then return slot end
  end
  return 1
end

-- The stat a critical hit reads at one end (GetDamageVarsFor{Player,Enemy}
-- Attack, core.asm :4059-4072, :4091-4104): the player's party struct, and
-- for the computer's battler GetEnemyMonStat (:4258-4297) -- outside a link
-- battle a CalcStat over wEnemyMonSpecies and wEnemyMonDVs at its level with
-- no stat exp.  For every foe the computer fields (they carry no stat exp)
-- that is its party stat, until it TRANSFORMs: the species byte and the DVs
-- are then the copied ones, so the crit stat is a CalcStat over the copied
-- species' base stats and DVs (K7 `base` / `dvs`, which Transform copies).
-- Without K7 on the sheet the referee cannot compute it and reads the party
-- stat, as it always did.  A link fight reads the party struct on both ends.
function Battle:_critStat(fighter, mon, key)
  if mon.transformed and isComputerSeat(self.mode, fighter)
     and type(mon.base) == "table" and type(mon.dvs) == "table" then
    return Effects.calcStat(mon.base[key], mon.dvs[key], mon.level, nil, false)
  end
  return mon.partyStats[key]
end

-- A Bide's forced turn, past every gate (`.BideCheck`, core.asm
-- :3482-3524): the store takes wDamage -- the shared word, whatever last
-- wrote it, not the HP this monster lost -- and the counter a step; the
-- turn it reaches 0 unleashes twice the store (two bytes, both wrapping),
-- skipping DecrementPP, the used-move line and MoveHitTest -- so it reaches
-- a FLY or DIG user -- and a store of 0 is "<MON>'s attack missed!".  A store
-- turn says nothing at all: it jumps straight to ExecutePlayerMoveDone, and
-- SavingEnergyText (:3630) is never referenced.
function Battle:_bideTurn(fighter, mon, move, usedSlot)
  local bide = mon.bide
  bide.stored = (int(bide.stored, 0) + max(0, int(self.lastDamage, 0))) % 65536
  bide.turns = int(bide.turns, 0) - 1
  if bide.turns > 0 then return end
  local stored = bide.stored
  mon.bide = nil
  -- `.UnleashEnergy` writes 1 into wPlayerMovePower (core.asm :3508-3509),
  -- leaving the struct's type as GetCurrentMove last left it: a COUNTER can
  -- answer a Bide.
  if type(fighter.moveStruct) == "table" then fighter.moveStruct.power = 1 end
  self:_say(named(fighter, mon) .. "\nunleashed energy!")
  local target = fighter.choice.target ~= nil and self:_retarget(fighter, fighter.choice.target) or nil
  local defender = target and activeMon(target)
  if not defender then
    self:_say(named(fighter, mon) .. " has no target")
    return
  end
  self:_emit("anim", { slot = fighter.slot, side = fighter.side, text = move.id })
  local damage = (2 * stored) % 65536
  if damage <= 0 then
    self.lastDamage = 0
    self:_say(named(fighter, mon) .. "'s\nattack missed!")
    self:_markLastMove(mon, usedSlot)
    return
  end
  self.lastDamage = self:_damage(target, defender, damage, nil)
  self:_buildRage(target, defender, fighter)
  self:_markLastMove(mon, usedSlot)
end

-- A power-0 move (`_useMove` sends it here once Mirror Move and Metronome
-- have had their say): the cart never runs MoveHitTest for one on the way in
-- (CalculateDamage's power-0 return, core.asm :3145), so each effect's own
-- routine meets the hit test where it does (Effects.statusPlan) -- and one
-- that never does is not stopped by FLY or DIG and draws no accuracy byte.
function Battle:_statusMove(fighter, mon, target, defender, move, effectId, usedSlot, choice, recordMove)
  -- A power-0 move reaches HandleBuildingRage ahead of any hit test of its
  -- own: CalculateDamage's `jp z` (core.asm :3145) goes round MoveHitTest, so
  -- wMoveMissed is still clear when the no-op ApplyAttackToEnemyPokemon
  -- (:4622) returns to the build.  ResidualEffects1 / 2 and the two calls have
  -- left by then (`Effects.skipsBuildingRage`); what is left in Red is
  -- Disable, whose own MoveHitTest comes after.  So a raging target builds
  -- whether the Disable lands or not.
  if not Effects.skipsBuildingRage(effectId) then
    self:_buildRage(target, defender, fighter)
  end

  local plan = Effects.statusPlan(effectId)
  -- What a routine's checks hand on to its effect (Effects.applyPrimary):
  -- SleepEffect's recharge overwrite, MimicEffect's pick.
  local extra = nil
  if plan == "statdown" then
    -- StatModifierDownEffect (effects.asm :539-562): outside a link battle the
    -- computer's drop draws its extra 25% miss first, then a Substitute
    -- misses, then MoveHitTest -- Mist inside it, before the byte -- and
    -- every one of them is MoveMissed's "But it failed!".
    if isComputerSeat(self.mode, fighter)
       and self.rng:byte() < Effects.COMPUTER_DROP_MISS then
      self:_say("But, it failed!")
      self:_markLastMove(mon, usedSlot)
      return
    end
    if Effects.hasSubstitute(defender) then
      self:_say("But, it failed!")
      self:_markLastMove(mon, usedSlot)
      return
    end
    if not self:_hitTest(mon, defender, move, effectId) then
      self:_say("But, it failed!")
      return self:_moveMissed(fighter, mon, target, defender, effectId, usedSlot)
    end
  elseif plan == "poison" then
    -- PoisonEffect (effects.asm :78-162): a doll, a status or a Poison type
    -- turn it away before its MoveHitTest, and a miss says the same thing --
    -- "It didn't affect <TARGET>!" (`.noEffect` / `.didntAffect`).
    if Effects.poisonTurnsAway(defender, self.poisonType) then
      self:_say("It didn't affect\n" .. named(target, defender) .. "!")
      self:_markLastMove(mon, usedSlot)
      return
    end
    if not self:_hitTest(mon, defender, move, effectId) then
      self:_say("It didn't affect\n" .. named(target, defender) .. "!")
      return self:_moveMissed(fighter, mon, target, defender, effectId, usedSlot)
    end
  elseif plan == "disable" then
    -- DisableEffect (effects.asm :1286-1293): its MoveHitTest first, and a
    -- miss is "But it failed!" (`.moveMissed`).
    if not self:_hitTest(mon, defender, move, effectId) then
      self:_say("But, it failed!")
      return self:_moveMissed(fighter, mon, target, defender, effectId, usedSlot)
    end
  elseif plan == "sleep" then
    -- SleepEffect (effects.asm :26-68).  A target that must recharge loses
    -- the recharge and falls asleep past every check -- no status check, no
    -- MoveHitTest, no byte but the counter's (the cart's own comment: "all
    -- hit tests will be skipped including the event where the target
    -- already has another status"), so the counter overwrites whatever
    -- status it had (`overwrite`).  Otherwise "<TARGET>'s already asleep!",
    -- then any other status, then MoveHitTest's miss -- both "It didn't
    -- affect <TARGET>!" -- and no byte before the hit test's.  No Substitute
    -- check: SLEEP POWDER reaches the monster behind a doll.
    if defender.mustRecharge then
      defender.mustRecharge = false
      extra = { overwrite = true }
    elseif defender.status == "sleep" then
      self:_say(named(target, defender) .. "'s\nalready asleep!")
      self:_markLastMove(mon, usedSlot)
      return
    elseif Effects.hasMajorStatus(defender) then
      self:_say("It didn't affect\n" .. named(target, defender) .. "!")
      self:_markLastMove(mon, usedSlot)
      return
    elseif not self:_hitTest(mon, defender, move, effectId) then
      self:_say("It didn't affect\n" .. named(target, defender) .. "!")
      return self:_moveMissed(fighter, mon, target, defender, effectId, usedSlot)
    end
  elseif plan == "paralyze" then
    -- ParalyzeEffect_ (move_effects/paralyze.asm): any status ("It didn't
    -- affect"), then an ELECTRIC move into a GROUND type (`cp ELECTRIC` on
    -- the move, `cp GROUND` on both target types: "It doesn't affect"), both
    -- before MoveHitTest, whose miss is "It didn't affect" again.  No
    -- Substitute check: THUNDER WAVE reaches the monster behind a doll.
    if Effects.hasMajorStatus(defender) then
      self:_say("It didn't affect\n" .. named(target, defender) .. "!")
      self:_markLastMove(mon, usedSlot)
      return
    end
    if self.electricType ~= nil and int(move.type, -1) == self.electricType
       and hasType(defender, self.groundType) then
      self:_say("It doesn't affect\n" .. named(target, defender) .. "!")
      self:_markLastMove(mon, usedSlot)
      return
    end
    if not self:_hitTest(mon, defender, move, effectId) then
      self:_say("It didn't affect\n" .. named(target, defender) .. "!")
      return self:_moveMissed(fighter, mon, target, defender, effectId, usedSlot)
    end
  elseif plan == "confusion" then
    -- ConfusionEffect (effects.asm :1120-1126): CheckTargetSubstitute, then
    -- MoveHitTest -- either one ConfusionEffectFailed's "But it failed!" --
    -- and an already confused target fails the same way (Effects).
    if Effects.hasSubstitute(defender) then
      self:_say("But, it failed!")
      self:_markLastMove(mon, usedSlot)
      return
    end
    if not self:_hitTest(mon, defender, move, effectId) then
      self:_say("But, it failed!")
      return self:_moveMissed(fighter, mon, target, defender, effectId, usedSlot)
    end
  elseif plan == "leechseed" then
    -- LeechSeedEffect_ (move_effects/leech_seed.asm): MoveHitTest first,
    -- then a GRASS type, then a target already SEEDED -- all three
    -- "<TARGET> evaded attack!".  No Substitute check: LEECH SEED reaches the
    -- monster behind a doll.
    if not self:_hitTest(mon, defender, move, effectId) then
      self:_say(named(target, defender) .. "\nevaded attack!")
      return self:_moveMissed(fighter, mon, target, defender, effectId, usedSlot)
    end
    if hasType(defender, self.grassType) or defender.leechSeed then
      self:_say(named(target, defender) .. "\nevaded attack!")
      self:_markLastMove(mon, usedSlot)
      return
    end
  elseif plan == "mimic" then
    -- MimicEffect (effects.asm :1203-1273): MoveHitTest, "But it failed!" on
    -- a miss (its INVULNERABLE re-check after it can never fire), then the
    -- pick (`_mimicPick`).  No Substitute check.
    if not self:_hitTest(mon, defender, move, effectId) then
      self:_say("But, it failed!")
      return self:_moveMissed(fighter, mon, target, defender, effectId, usedSlot)
    end
    local pick = self:_mimicPick(fighter, defender, choice)
    if not pick then
      self:_say("But, it failed!")
      self:_markLastMove(mon, usedSlot)
      return
    end
    extra = { mimicSlot = pick }
  elseif plan == "conversion" then
    -- ConversionEffect_'s own INVULNERABLE test on the target, no byte.
    if defender.invulnerable then
      self:_say("But, it failed!")
      self:_markLastMove(mon, usedSlot)
      return
    end
  end

  -- `targetSlot` the seat actually swung at, which a Bide records.
  -- BideEffect (effects.asm :764-789) sets STORING_ENERGY, draws its 2..3
  -- and plays an animation: no line past "used BIDE!".
  if Effects.isBide(effectId) and not mon.bide then
    mon.bide = {
      turns = Effects.bideTurns(self.rng),
      stored = 0,
      moveIndex = usedSlot,
      targetSlot = target.slot,
      move = recordMove,
    }
    self:_markLastMove(mon, usedSlot)
    return
  end
  if Effects.isSwitchAndTeleport(effectId) then
    self:_switchAndTeleport(fighter, mon, target, defender, move)
    self:_markLastMove(mon, usedSlot)
    return
  end
  if Effects.isNoOp(effectId) then
    self:_say("But nothing happened")
    self:_markLastMove(mon, usedSlot)
    return
  end
  if Effects.handlesPrimary(effectId) then
    -- TransformEffect_ on the player's turn writes `a` -- hWhoseTurn, 0 --
    -- into wPlayerMoveListIndex before anything else (transform.asm :15),
    -- whether the copy then lands or not: the first slot from here on.
    if effectId == 57 and isPlayerSeat(self.mode, fighter) then
      fighter.moveListIndex = 1
    end
    -- MIMIC overwrites the list index's slot (`.letPlayerChooseMove` reads
    -- wPlayerMoveListIndex, effects.asm :1238).
    self:_applyPrimary(fighter, mon, target, defender, self:_listIndex(fighter, choice),
      effectId, move.id, extra)
  else
    self:_say("But nothing happened")
  end
  self:_markLastMove(mon, usedSlot)
end

-- The trap a TRAPPING_EFFECT move starts.  `count` is TrappingEffect's
-- counter (wPlayerNumAttacksLeft): the attacks after this one, which
-- `.MultiturnMoveCheck` spends one a turn in the trapper's slot (`_trapTurn`)
-- and CheckNumAttacksLeft ends on at 0 (`_checkNumAttacksLeft`) -- so a
-- count of 1 is a two-turn Wrap.  The trap is the trapper's record; the held
-- monster's mirrors it (`turns`, `damage`) so a sheet reader sees the hold.
-- `damage` is what each later turn deals -- wDamage after the hit, the whole
-- hit against a doll (AttackSubstitute leaves wDamage alone), 0 after an
-- immunity -- which the caller writes once the hit is in.
function Battle:_startTrap(fighter, mon, target, defender, count, usedSlot, recordMove, damage)
  defender.trapped = {
    turns = count,
    damage = max(0, int(damage, 0)),
    fromSlot = fighter.slot,
  }
  mon.trapping = {
    turns = count,
    moveIndex = usedSlot,
    targetSlot = target.slot,
    move = recordMove,
    damage = max(0, int(damage, 0)),
  }
end

-- `.MultiturnMoveCheck` (core.asm :3549-3560) and where it jumps: "<MON>'s
-- attack continues!", the counter down a step, and GetPlayerAnimationType --
-- the move's animation, then ApplyAttackToEnemyPokemon with wDamage as the
-- trap's first hit left it (AttackSubstitute against a doll), and
-- HandleBuildingRage on a target still standing.  No "used" line, no
-- DecrementPP, no crit, roll or hit test, and nothing else is said: a hit for
-- 0 (an immunity's trap, a 0.25x zero) is the continues line and an empty
-- hit.  It lands in the trapper's own slot of the turn order, after the
-- trapper's gates (`_runGates`: asleep, frozen, flinched, its WRAP disabled
-- -- none of them spends the counter, and the held monster stays held; fully
-- paralysed or hurting itself, the trap is gone).
function Battle:_trapTurn(fighter, mon, move, usedSlot)
  local trap = mon.trapping
  self:_say(named(fighter, mon) .. "'s\nattack continues!")
  trap.turns = max(0, int(trap.turns, 0) - 1)
  local target = self:_fighterAtSlot(trap.targetSlot)
  local defender = target and activeMon(target)
  local held = defender and defender.trapped
  if held and held.fromSlot == fighter.slot then held.turns = trap.turns end
  self:_emit("anim", { slot = fighter.slot, side = fighter.side, text = move.id })
  if defender then
    local damage = int(trap.damage, 0)
    if held and held.fromSlot == fighter.slot then damage = int(held.damage, 0) end
    self.lastDamage = self:_damage(target, defender, max(0, damage), nil)
    self:_buildRage(target, defender, fighter)
  end
  self:_markLastMove(mon, usedSlot)
end

-- "Hit the enemy N times!" (_MultiHitText, the player's) and "Hit N times!"
-- (_HitXTimesText, the enemy's), with the count TwoToFiveAttacksEffect drew
-- (wPlayerNumHits / wEnemyNumHits).  "The player" is the owner's rule.
function Battle:_hitTimesText(fighter, hits)
  if isPlayerSeat(self.mode, fighter) then
    return "Hit the enemy\n" .. hits .. " times!"
  end
  return "Hit " .. hits .. " times!"
end

function Battle:_useMove(fighter, mon, opts)
  opts = opts or {}
  local choice = fighter.choice
  -- A move Metronome or Mirror Move called is not the turn's own move.  The
  -- gates and the obedience check already ran for the move that called it --
  -- MetronomePickMove and MirrorMoveCopyMove jump back to
  -- CheckIfPlayerNeedsToChargeUp (core.asm :3206, :3211), past
  -- CheckPlayerStatusConditions and CheckForDisobedience -- and it is never
  -- Struggle, whatever PP the calling slot has left: Struggle is a move, not
  -- a state of the user's PP, so the call that spent the last PP takes no
  -- recoil.
  local called = opts.moveOverride ~= nil
  -- The move this action resolves to.  A forced replay is the move it
  -- replays (`_fillForcedChoices`), a called one included, and never
  -- Struggle: no menu was opened to offer it.  Otherwise the menu's own
  -- answer (`mustStruggle`) -- an empty sheet (`#moves == 0`) included -- is
  -- the synthetic STRUGGLE; returning on the missing slot used to eat that
  -- turn instead.
  -- wPlayerMoveListIndex / wEnemyMoveListIndex (`_listIndex`): the slot
  -- DecrementPP spends, IncrementMovePP refunds and MIMIC overwrites.
  local listIndex = self:_listIndex(fighter, choice)
  -- A monster asleep or frozen at the menu opened no move menu, so the move
  -- its slot runs is wPlayerSelectedMove as last turn left it -- reached only
  -- when a Fire hit thawed it before its slot (sleep's waking turn is lost).
  -- That is the move last turn USED: the one a METRONOME or MIRROR MOVE
  -- called, if it called one, and not the calling move.
  local stale = not called and choice.stale and choice.forcedMove == nil
    and type(fighter.selectedMove) == "table"
  local move = opts.moveOverride
  if not called then
    if choice.forcedMove then
      move = choice.forcedMove
    elseif stale then
      move = fighter.selectedMove
    elseif self:_struggles(fighter, mon) then
      move = STRUGGLE
    else
      move = mon.moves[choice.move]
    end
  end
  if not move then return end
  local struggling = move == STRUGGLE
  -- MetronomePickMove / MirrorMoveCopyMove write the called move into
  -- wPlayerSelectedMove, where COUNTER reads it (`_counterDamage`).
  if called then fighter.selectedMove = move end
  -- The slot this action is *using*: the chosen one, or the one a disobedient
  -- monster picked instead (below), carried into a Metronome / Mirror Move
  -- call.  Whatever the action records for a later turn -- a charge, a
  -- thrash, a Rage, a trap, a Bide, the last move a Mirror Move copies -- is
  -- recorded against it, because the cart overwrote wPlayerSelectedMove with
  -- the move it used.  Two things still answer to the *chosen* slot,
  -- wPlayerMoveListIndex, which `.chooseMove` never rewrites: the PP spent
  -- (DecrementPP) and the slot Mimic writes over (`_applyPrimary`).  A stale
  -- selection's slot is that index too.
  local usedSlot = opts.slot or (stale and listIndex) or choice.move
  -- What a record this action starts keeps for its forced turns: the move
  -- itself when it is a called one -- this call, or a forced replay of one
  -- (`choice.called`), or a stale selection that is not its slot's own move
  -- -- and nothing for the slot's own move, which the record's slot already
  -- names.
  local recordMove = (called or choice.called) and move or nil
  if stale and move ~= mon.moves[usedSlot] then recordMove = move end
  local disobedient = opts.disobedient == true
  -- ReloadMoveData (core.asm :4996-5010), on the way into the called move:
  -- IncrementMovePP gives the list index's PP back -- "to prevent moves that
  -- run another move within the same turn ... from losing 2 PP" -- before the
  -- called move's own PlayerCanExecuteMove spends it again (below).  A called
  -- charge stops at ChargeEffect without that second DecrementPP, so its call
  -- refunds the slot for the turn (the release pays it, `payIndex`).  The
  -- computer's slot is refunded too, and never spent: its PP climbs.
  if called then
    self:_incrementPp(fighter, mon, listIndex)
    self:_loadMoveStruct(fighter, move)
  end

  -- The gates, the disabled-move check among them (`_runGates`).
  if not called and not self:_runGates(fighter, mon, move) then return end

  -- Bide's forced turns end here, one way or the other (`_bideTurn`).
  if not called and choice.bideStore and mon.bide then
    return self:_bideTurn(fighter, mon, move, usedSlot)
  end

  -- `.ThrashingAboutCheck` (core.asm :3526-3547), the turns after the first:
  -- "<MON>'s thrashing about!", then the counter comes down a step past every
  -- gate, and the step that takes it to 0 ends the thrash in confusion --
  -- 2..5 turns, a draw, and not a word: `set CONFUSED` prints nothing there
  -- (the `status` chip says it) -- and the move still lands this turn (`pop
  -- hl` keeps PlayerCalcMoveDamage).  These turns go straight to
  -- PlayerCalcMoveDamage, past PlayerCanExecuteMove: no "used" line, no
  -- DecrementPP, no DisplayUsedMoveText writing wPlayerUsedMove, and never a
  -- new thrash.
  local thrashTurn = not called and choice.forcedMove ~= nil and mon.thrashing ~= nil
  if thrashTurn then
    self:_say(named(fighter, mon) .. "'s\nthrashing about!")
    mon.thrashing.turns = mon.thrashing.turns - 1
    if mon.thrashing.turns <= 0 then
      mon.thrashing = nil
      mon.confusion = self.rng:byte() % 4 + 2
      self:_emit("status", {
        slot = fighter.slot, side = fighter.side, confused = 1,
        text = mon.species .. " became confused!",
      })
    end
  end

  -- `.MultiturnMoveCheck` (core.asm :3549-3560): a trap's later turns, past
  -- every gate (`_trapTurn`).  A trap a switch or a faint let go before this
  -- slot has no bit left to find, and the selection the cart left standing --
  -- the trapping move -- runs fresh below: the used line, DecrementPP and a
  -- new TrappingEffect, at whoever is there now (the link-battle glitch, and
  -- what a released trapper does).
  if not called and choice.trapContinue and mon.trapping then
    return self:_trapTurn(fighter, mon, move, usedSlot)
  end

  -- `.playerHasNoSpecialCondition`'s GetCurrentMove (core.asm :3095): the
  -- selected move into the move struct, which COUNTER reads off this seat
  -- (`_counterDamage`).  A Bide's turns, a thrash's and a trap's
  -- continuations and a Rage's (`.RageCheck` goes straight to
  -- PlayerCanExecuteMove) leave CheckPlayerStatusConditions without it; a
  -- called move loaded its own (ReloadMoveData, above).
  local rageTurn = not called and mon.raging and choice.forcedMove ~= nil
  if not called and not thrashTurn and not rageTurn then
    self:_loadMoveStruct(fighter, move)
  end

  -- CheckForDisobedience: a traded monster of the player's, on the turn's own
  -- move.  A forced action never asks -- Bide, a thrash, a Rage and a charge's
  -- release all leave CheckPlayerStatusConditions (or the CHARGING_UP branch)
  -- on a path that skips it -- and neither does a called move (above).
  if not called and fighter.badgeRules and mon.traded and not fighter.forced then
    local goes, instead = self:_obey(fighter, mon, struggling)
    if not goes then return end
    if instead then
      usedSlot, move, disobedient = instead, mon.moves[instead], true
      fighter.selectedMove = move
      -- `.useRandomMove` ends on GetCurrentMove (core.asm :4000).
      self:_loadMoveStruct(fighter, move)
    end
  end

  -- Resolved once, here, and used for the whole action: see `_retarget`.
  local target = self:_retarget(fighter, choice.target)
  local defender = target and activeMon(target)
  if not defender then
    self:_say(named(fighter, mon) .. " has no target")
    return
  end

  local effectId = int(move.effect, 0)
  local releasing = mon.charging ~= nil and Effects.isCharge(mon.charging.effect)
  local mirrorCopy = opts.mirrorCopy == true
  -- A charge's first turn: CheckIfPlayerNeedsToChargeUp jumps to ChargeEffect
  -- (core.asm :3102-3109) ahead of PlayerCanExecuteMove, so it prints no
  -- used line and spends no PP -- only the charge line and its animation.
  local chargingUp = Effects.isCharge(effectId) and not mon.charging

  -- DecrementPP spends wPlayerMoveListIndex's PP -- the chosen slot -- even
  -- when a disobedient monster used another move (`usedSlot` above).  It
  -- returns first while THRASHING_ABOUT or USING_RAGE is set
  -- (engine/battle/decrement_pp.asm), so the turns after the first of a
  -- thrash or a Rage spend nothing -- the thrash's own continuation even
  -- skips the call (`.ThrashingAboutCheck` goes to PlayerCalcMoveDamage) --
  -- and a Bide's unleash skips it too.  A charge pays on its RELEASE:
  -- PlayerCanExecuteChargingMove falls into PlayerCanExecuteMove
  -- (:3111-3124), DisplayUsedMoveText and then DecrementPP, on the slot
  -- wPlayerMoveListIndex still names -- the one chosen the turn it started
  -- (`payIndex`), no menu having been opened since.  So a METRONOME or MIRROR
  -- MOVE that called a charge move pays its call's refund back there, and a
  -- charge a full paralysis or a self-hit cancelled keeps it.  A called move
  -- that is not a charge pays the refund back at once: one PP a call, net.
  -- The slot is the list index whatever move runs -- a stale selection's, a
  -- released trap's fresh run, a disobedient monster's instead-move -- and
  -- DecrementPP never looks at what is left: a slot at 0 wraps
  -- (`_decrementPp`), to 63 PP and one PP Up fewer.  The computer never pays
  -- at all: ExecuteEnemyMove has no DecrementPP (core.asm :5510-5521), so
  -- outside a link battle its PP never falls (`_hasPp`).
  local payIndex = listIndex
  if releasing then payIndex = mon.charging.payIndex or listIndex end
  local paying = mon.moves[payIndex]
  if paying and not struggling and not chargingUp
     and not thrashTurn and not mon.raging
     and not isComputerSeat(self.mode, fighter) then
    self:_decrementPp(mon, payIndex)
    -- FIGHT reads the uploaded sheet: publish the spend.  A called move's
    -- spend only paid back the call's refund, so the list is as the
    -- calling move left it (published there).
    if not called then
      self:_emitMoves(fighter, mon, fighter.active)
    end
  elseif called and chargingUp and paying and not isComputerSeat(self.mode, fighter) then
    -- The refund a called charge keeps for its charge turn.
    self:_emitMoves(fighter, mon, fighter.active)
  end
  -- amount=1 is the charge/vanish setup beat (release omits it). SHAKE_ANIM
  -- already uses amount for rock count; DIG/FLY/SOLARBEAM are never shakes.
  -- A thrash's continuation animates THRASH whatever the move: the
  -- `.ThrashingAboutCheck` writes THRASH into wPlayerMoveNum (core.asm
  -- :3529-3530), the number PlayPlayerMoveAnimation plays -- so a PETAL
  -- DANCE's later turns look like THRASH's.
  self:_emit("anim", {
    slot = fighter.slot, side = fighter.side,
    text = thrashTurn and THRASH_ANIM or move.id,
    amount = chargingUp and 1 or nil,
  })
  -- DisplayUsedMoveText with wMonIsDisobedient set takes UsedMove2Text and
  -- `.UsedInsteadText` (pokered engine/battle/used_move_text.asm; text_2.asm
  -- _UsedInsteadText): "<MON> used instead, <MOVE>", in this file's shape of
  -- the used line.  A Metronome call keeps the flag (MetronomePickMove leaves
  -- it), a Mirror Move copy clears it (MirrorMoveCheck's `xor a`), and the
  -- calls below pass it on accordingly.  A thrash's continuation never gets
  -- to DisplayUsedMoveText (`.ThrashingAboutCheck` jumps to
  -- PlayerCalcMoveDamage): its line was "thrashing about!" (above).  Nor
  -- does a charge's first turn (`chargingUp`): its line is the charge's.
  if thrashTurn or chargingUp then
    -- nothing: see above
  elseif disobedient then
    -- _ActorNameText's <USER>, _UsedMove2Text's `line`, _UsedInsteadText's
    -- `cont` (K17 / K18).
    self:_say(named(fighter, mon) .. "\nused instead,\n" .. moveLabel(move) .. "!")
  else
    self:_say(named(fighter, mon) .. "\nused " .. moveLabel(move) .. "!")
  end

  if chargingUp then
    -- `move` is kept when METRONOME / MIRROR MOVE called it: the release
    -- replays it (`_fillForcedChoices`), not the calling slot.  `payIndex`
    -- is wPlayerMoveListIndex, which the release pays from (above).
    mon.charging = {
      moveIndex = usedSlot,
      payIndex = choice.move,
      effect = effectId,
      targetSlot = target.slot,
      moveId = move.id,
      move = recordMove,
    }
    if Effects.vanishes(effectId, move) then mon.invulnerable = true end
    self:_say(Effects.chargeMessage(mon, effectId, move.id, fighter.side))
    self:_markLastMove(mon, usedSlot)
    return
  end

  if mon.charging and Effects.isCharge(mon.charging.effect) then
    mon.charging = nil
    mon.invulnerable = false
  end

  -- DisplayUsedMoveText writes the move into wPlayerUsedMove /
  -- wEnemyUsedMove (`.playerTurn`'s `ld [hl], a`), which is what a MIRROR
  -- MOVE aimed at this monster copies (`lastUsedMove`): the move a METRONOME
  -- or a MIRROR MOVE called, since the call prints its own line after the
  -- caller's.  A charge's first turn never runs it -- ChargeEffect is reached
  -- from CheckIfPlayerNeedsToChargeUp, before PlayerCanExecuteMove, and
  -- prints only "<MON> flew up high!" -- so a FLY in the air has not been
  -- "used" yet; its release has.  Nor does a thrash's continuation (above),
  -- which leaves the first turn's THRASH there -- or the 0 a send-out wrote.
  if not thrashTurn then mon.lastUsedMove = move end

  -- SpecialEffectsCont (Effects.startsBeforeHit): PlayerCanExecuteMove runs
  -- THRASH / PETAL DANCE's and the trapping moves' routines before damage
  -- and every hit test.  ThrashPetalDanceEffect sets THRASHING_ABOUT and its
  -- 2..3 counter, so a thrash that misses still thrashes; TrappingEffect
  -- (effects.asm :1080-1103) runs ClearHyperBeam on the target and draws its
  -- counter, and only MoveHitTest's `.moveMissed` (`res USING_TRAPPING_MOVE`)
  -- takes the trap back -- an immunity or a 0.25x zero leaves it standing,
  -- doing 0 a turn, and a doll that holds keeps it (`_startTrap`).
  if Effects.isThrash(effectId) and not mon.thrashing and not thrashTurn then
    mon.thrashing = {
      turns = Effects.thrashTurns(self.rng),
      moveIndex = usedSlot,
      move = recordMove,
    }
  end
  -- TrappingEffect's counter, wPlayerNumAttacksLeft: the attacks after this
  -- one, 1..4 (Effects.trapTurns is the 2..5 total).
  local trapCount = nil
  if Effects.isTrapping(effectId) and not mon.trapping then
    defender.mustRecharge = false
    trapCount = Effects.trapTurns(self.rng) - 1
  end

  if Effects.isMirrorMove(effectId) and not mirrorCopy then
    -- MirrorMoveCopyMove (core.asm :4960-4986) copies wEnemyUsedMove /
    -- wPlayerUsedMove -- the move the target last printed a "used" line for,
    -- so after its METRONOME called THRASH it is THRASH -- and fails when
    -- there is none (zeroed at a send-out, a fast-asleep or a frozen-solid
    -- turn) or it is MIRROR MOVE itself -- MirrorMoveFailedText, "The MIRROR
    -- MOVE failed!" (`.mirrorMoveFailed`, :4983-4986).
    local last = defender.lastUsedMove
    if type(last) ~= "table" or Effects.isMirrorMove(last.effect) then
      self:_say("The MIRROR MOVE\nfailed!")
      self:_markLastMove(mon, usedSlot)
      return
    end
    self:_markLastMove(mon, usedSlot)
    self:_useMove(fighter, mon, {
      moveOverride = copyMove(last),
      mirrorCopy = true,
      slot = usedSlot,
    })
    return
  end

  local metronomeCall = opts.metronomeCall == true
  if Effects.isMetronome(effectId) and not metronomeCall then
    local pool = self.metronomePool
    if not pool or #pool == 0 then
      self:_say("But nothing happened")
      self:_markLastMove(mon, usedSlot)
      return
    end
    local pick = (self.rng:byte() % #pool) + 1
    self:_markLastMove(mon, usedSlot)
    self:_useMove(fighter, mon, {
      moveOverride = copyMove(pool[pick]),
      metronomeCall = true,
      slot = usedSlot,
      disobedient = disobedient,
    })
    return
  end

  -- Which way the move goes: a hit (any power, the two-to-five pair at power
  -- 0, the three set-damage / OHKO effects, COUNTER), or a power-0 move whose
  -- routine is its own (`_statusMove`).
  local isCounter = Effects.isCounter(move)
  local damaging = move.power > 0 or isCounter or Effects.isFixedDamage(effectId)
    or Effects.hitsAtPowerZero(effectId)
  if not damaging then
    -- CalculateDamage's power-0 `jp z, PlayerCheckIfFlyOrChargeEffect`
    -- (core.asm :3145): a FLY or charge move at power 0 -- on its release,
    -- the charge turn having returned above -- shows STATUS_AFFECTED_ANIM
    -- there (K20).
    self:_flyOrChargeAnim(fighter, effectId)
    return self:_statusMove(fighter, mon, target, defender, move, effectId,
      usedSlot, choice, recordMove)
  end

  -- An immunity or a 0.25x zero leaves a trap that already started standing
  -- (above), at 0 a turn -- when MoveHitTest's own byte let it through.
  local function trapAfterZero()
    if trapCount then
      self:_startTrap(fighter, mon, target, defender, trapCount, usedSlot, recordMove, 0)
    end
  end

  -- PlayerCalcMoveDamage / EnemyCalcMoveDamage (core.asm :3134-3149,
  -- :5524-5542), in the cart's order -- the draws included:
  --   * SetDamageEffects (SUPER FANG, the SPECIAL_DAMAGE moves) jump straight
  --     to MoveHitTest: no crit byte, no chart, no roll -- only PSYWAVE's
  --     own loop, once the hit test passed (ApplyAttackToEnemyPokemon);
  --   * CriticalHitTest's byte (none at power 0: `ret z`), every other move,
  --     COUNTER and the OHKO moves included;
  --   * HandleCounterMove: COUNTER's conditions, then MoveHitTest, and
  --     nothing else (`_counterDamage`);
  --   * CalculateDamage -- for an OHKO move OneHitKOEffect_, which misses a
  --     faster target there and then (`jp z`: no chart, no roll, no hit
  --     test) -- AdjustDamageForMoveType (an immunity, or a 0.25x that leaves
  --     0, sets wMoveMissed and goes on), RandomizeDamage's roll (a 2 and
  --     up), and only then MoveHitTest: DREAM EATER's sleep check, SWIFT,
  --     INVULNERABLE, Mist and X Accuracy before its accuracy byte
  --     (`_hitTest`).  So a move that misses has already drawn its crit byte
  --     and its roll, and an immune target still costs the accuracy byte.
  -- A miss prints PrintMoveFailureText's line (`_damageMissText`).
  local isOhko = Effects.isOhko(effectId)
  local isCrit, percents, lastPct = false, nil, nil
  local damage = 0
  if Effects.isSetDamage(effectId) then
    local hit = self:_hitTest(mon, defender, move, effectId)
    if not hit then
      self:_flyOrChargeAnim(fighter, effectId)
      self:_say(self:_damageMissText(fighter, mon, target, defender, false, false))
      return self:_moveMissed(fighter, mon, target, defender, effectId, usedSlot)
    end
    damage = Effects.setDamage({
      effectId = effectId, moveId = move.id, userMon = mon, targetMon = defender,
      power = move.power, rng = self.rng,
      computerMover = isComputerSeat(self.mode, fighter),
    })
  else
    -- Species base Speed, not battle Speed: paralysis and the Speed badge
    -- must not change the crit rate.  CriticalHitTest reads it off the
    -- species byte, which TRANSFORM rewrites (Effects' Transform copies the
    -- target's `baseSpd` / K7 `base.spd`).  Absent both (old sheet) it falls
    -- back to the unmodified stat, still without a stage, badge or penalty.
    -- A power-0 hit (the two-to-five pair) draws no crit byte at all
    -- (`ret z` on the power, :4501-4503).  HighCriticalMoves is matched
    -- against wPlayerMoveNum (`dec hl / ld c, [hl]`, :4503-4504), which a
    -- thrash's continuation set to THRASH (`THRASH_ANIM`'s note) -- not on
    -- that table -- so those turns crit at the ordinary rate whatever the
    -- move's own flag says.
    if move.power > 0 then
      local critSpd = mon.baseSpd
      if critSpd == nil and type(mon.base) == "table" then critSpd = mon.base.spd end
      if critSpd == nil then critSpd = mon.stats.spd end
      isCrit = Crit.check(critSpd, self.rng:byte(), {
        focusEnergy = mon.focusEnergy,
        highCritMove = move.highCrit == true and not thrashTurn,
      })
    end

    if isCounter then
      -- HandleCounterMove (`_counterDamage`): a COUNTER whose conditions
      -- fail misses there -- wMoveMissed set, no hit test, wDamage as it was
      -- -- and one that passes takes MoveHitTest with its damage fixed.  No
      -- chart (it reaches a Ghost, says nothing of effectiveness), no roll.
      -- The crit byte it drew still prints "Critical hit!" over the number
      -- (PrintCriticalOHKOText), as the cart's does.
      local counter = self:_counterDamage(target)
      if not counter then
        self:_flyOrChargeAnim(fighter, effectId)
        self:_say(named(fighter, mon) .. "'s\nattack missed!")
        self:_markLastMove(mon, usedSlot)
        return
      end
      if not self:_hitTest(mon, defender, move, effectId) then
        self:_flyOrChargeAnim(fighter, effectId)
        self:_say(self:_damageMissText(fighter, mon, target, defender, false, false))
        return self:_moveMissed(fighter, mon, target, defender, effectId, usedSlot)
      end
      damage = counter
    else
      percents, lastPct = self:_typeRows(move.type, defender)
      local immune, zeroed = false, false
      if isOhko then
        -- OneHitKOEffect_: a user slower than its target misses before the
        -- chart and the hit test, and wCriticalHitOrOHKO's $ff makes it
        -- "<TARGET>'s unaffected!".  Otherwise 65535 goes through
        -- AdjustDamageForMoveType -- an immunity zeroes it, no roll (`cp 2`)
        -- -- and RandomizeDamage rolls over it (Effects.ohkoDamage): that
        -- number, not the target's HP, is the hit's wDamage -- a doll breaks
        -- outright on its high byte (AttackSubstitute) and keeps it for
        -- COUNTER, and a monster takes its HP, which the overkill writes back.
        if not Effects.ohkoLands(self:_speedOf(fighter, mon), self:_speedOf(target, defender)) then
          self:_flyOrChargeAnim(fighter, effectId)
          self:_say(self:_damageMissText(fighter, mon, target, defender, false, true))
          return self:_moveMissed(fighter, mon, target, defender, effectId, usedSlot)
        end
        for _, pct in ipairs(percents) do
          if pct <= 0 then immune = true; break end
        end
        if not immune then
          damage = Effects.ohkoDamage(hasType(mon, move.type), percents)
          if damage <= 0 then
            zeroed = true
          elseif Damage.rolls(damage) then
            damage = Damage.applyRoll(damage, self.rng:damageRoll())
          end
        end
      else
        -- GetDamageVarsFor{Player,Enemy}Attack (core.asm :4030-4255).  An
        -- ordinary hit reads the stored battle stats -- stage, badges and a
        -- burn already in them -- and a screen on the defender doubles its
        -- stat (`sla c / rl b`, uncapped, so a big enough one wraps in the
        -- scaling).  A critical hit throws all of that away for the party
        -- stats at both ends (`_critStat`): the player's party struct
        -- (pre-Transform) and GetEnemyMonStat for the computer's.  No stage,
        -- no badge, no burn, no screen.  The scaling, the Explosion halving
        -- and the 997 cap are Damage.compute's.
        local isSpecial = Effects.isSpecialType(move.type, self.specialTypes)
        local atkKey = isSpecial and "spc" or "atk"
        local defKey = isSpecial and "spc" or "def"
        local attack, defense
        if isCrit then
          attack = self:_critStat(fighter, mon, atkKey)
          defense = self:_critStat(target, defender, defKey)
        else
          attack = mon.cur[atkKey]
          defense = defender.cur[defKey]
          if (isSpecial and defender.lightScreen)
             or ((not isSpecial) and defender.reflect) then
            defense = defense * 2
          end
        end

        local result = Damage.compute(
          { level = mon.level, attack = attack },
          { defense = defense },
          { power = move.power },
          {
            crit = isCrit,
            stab = hasType(mon, move.type),
            typeEffect = percents,
            explode = Effects.isExplode(effectId),
          })

        -- An immunity is a 0 (AdjustDamageForMoveType's multiply by 0), and
        -- so is a 0.25x matchup that leaves a 2 or a 3 at 0 (:5173-5177):
        -- both set wMoveMissed and draw no roll.  RandomizeDamage draws only
        -- for a 2 and up (`cp 2` / `ret c`): a hit already at 1 lands for 1.
        if result.immune then
          immune = true
        elseif result.modified <= 0 then
          zeroed = true
        else
          damage = result.modified
          if result.rolls then damage = Damage.applyRoll(damage, self.rng:damageRoll()) end
        end
      end

      -- MoveHitTest runs whatever AdjustDamageForMoveType decided -- it never
      -- clears wMoveMissed, and its own miss is the only one that takes a
      -- trap back (`.moveMissed`'s `res USING_TRAPPING_MOVE`).  Which line
      -- the miss gets is wDamageMultipliers' (PrintMoveFailureText): with the
      -- chart's order, "doesn't affect" only when the LAST row the walk
      -- applied was the 0 -- a dual type whose immunity row comes before
      -- another row of the move's type is "<USER>'s attack missed!" -- and
      -- without it, any immunity (`_typeRows`).
      local hit = self:_hitTest(mon, defender, move, effectId)
      if immune or zeroed or not hit then
        local noEffect = immune
        if lastPct ~= nil then noEffect = lastPct == 0 end
        -- HandleIfPlayerMoveMissed's `jr PlayerCheckIfFlyOrChargeEffect`: a
        -- released FLY or charge that missed shows STATUS_AFFECTED_ANIM
        -- ahead of PrintMoveFailureText's line (K20).
        self:_flyOrChargeAnim(fighter, effectId)
        self:_say(self:_damageMissText(fighter, mon, target, defender, noEffect, false))
        if hit then trapAfterZero() end
        return self:_moveMissed(fighter, mon, target, defender, effectId, usedSlot)
      end
    end
  end

  -- PrintCriticalOHKOText and DisplayEffectiveness come after the hit is
  -- applied (ExecutePlayerMove `.moveDidNotMiss`, core.asm :3226-3229), each
  -- hit of a multi-hit move: wCriticalHitOrOHKO is cleared once printed, so
  -- "Critical hit!" -- or a landed OHKO's "One-hit KO!", which OneHitKOEffect_
  -- wrote over the crit -- follows the first hit only, while wDamageMultipliers
  -- stands for the whole move and its line follows every hit (`typeLine`).
  -- A COUNTER, a set-damage move, a trap's later turns and a Bide's unleash
  -- never ran AdjustDamageForMoveType that turn, so they have no line.
  local effectLine = typeLine(percents, lastPct)

  -- The trap, standing before the hit lands (a knockout's `_faint` takes it
  -- back off the field).
  if trapCount then
    self:_startTrap(fighter, mon, target, defender, trapCount, usedSlot, recordMove, 0)
  end

  -- The hits, each in the cart's order (ExecutePlayerMove :3226-3256):
  -- ApplyAttackToEnemyPokemon, then the AlwaysHappenSideEffects routine at
  -- `.notDone` (`_alwaysHappen`) -- before `ret z` on the target's HP, so a
  -- knockout still runs it -- then HandleBuildingRage on a target still
  -- standing, then the multi-hit test, which jumps back to
  -- GetPlayerAnimationType with the same wDamage for the next hit.
  --
  -- A hit that breaks a Substitute zeroes the move's effect
  -- (AttackSubstitute `.nullifyEffect`, :4899): from that hit on no
  -- AlwaysHappen routine runs and `.executeOtherEffects` finds nothing.  So
  -- no drain, no recoil, no Pay Day coins, no RAGE (the user never starts
  -- raging), no EXPLOSION faint (the user survives), no HYPER BEAM recharge
  -- and no side effect -- the hit itself and the target's Rage build stand.
  -- A doll that holds zeroes nothing, and wDamage is then the whole hit
  -- (AttackSubstitute takes it off the doll's own byte), so the drain, the
  -- recoil -- STRUGGLE's half included -- the coins and the recharge all
  -- happen.
  --
  -- TwoToFiveAttacksEffect is an AlwaysHappen routine too, so the count is
  -- drawn after the first hit (Effects.hitCount) -- a knockout included --
  -- and never when that hit broke a doll, which leaves
  -- ATTACKING_MULTIPLE_TIMES clear and ends the move there (the loop test,
  -- :3245-3247, goes straight to `.executeOtherEffects`).  A break on hit 2
  -- or later finds the count set: the move goes on, the hits after it land on
  -- the monster, the effect still gone.  DOUBLE KICK (44) and TWINEEDLE (77)
  -- are 2 without a draw.  A count that ran out with the target standing
  -- prints MultiHitText / HitXTimesText with it (`_hitTimesText`); a
  -- knockout returned at `ret z` before the line.
  local multihit = Effects.isMultihit(effectId)
  local hits = 1
  local counted = false
  local totalDealt = 0
  local effectLive = true
  local h = 0
  while h < hits do
    h = h + 1
    if defender.hp <= 0 then break end
    local hpBefore = defender.hp
    local subUp = Effects.hasSubstitute(defender)
    -- A knockout keeps its 0 HP on the field until the move is over: its
    -- `faint` is the action's end's (`_reapKo`, K19), after the lines below,
    -- the AlwaysHappen routine's and the rest of the move's.
    self.lastDamage = self:_damage(target, defender, damage, nil)
    if h == 1 then
      if isOhko then
        self:_say("One-hit KO!")
      elseif isCrit then
        self:_say("Critical hit!")
      end
    end
    if effectLine then self:_say(effectLine) end
    totalDealt = totalDealt + (hpBefore - defender.hp)
    if subUp and not Effects.hasSubstitute(defender) then effectLive = false end
    if effectLive then
      if h == 1 and multihit then
        hits = Effects.hitCount(effectId, self.rng)
        counted = true
      end
      self:_alwaysHappen(fighter, mon, effectId, struggling, usedSlot, recordMove, defender, target)
    end
    if defender.hp <= 0 then break end
    self:_buildRage(target, defender, fighter)
  end
  if counted and defender.hp > 0 then
    self:_say(self:_hitTimesText(fighter, hits))
  end

  -- What each later turn of a trap deals: wDamage now (`_trapTurn`).
  if trapCount and defender.trapped and defender.trapped.fromSlot == fighter.slot then
    defender.trapped.damage = max(0, int(self.lastDamage, 0))
    if mon.trapping then mon.trapping.damage = defender.trapped.damage end
  end

  -- `.executeOtherEffects` (core.asm :3258-3269) runs the side effect once,
  -- after the last hit, and only if the move got that far: a hit that knocked
  -- the target out returned at `ret z` (:3242), and a Substitute this move
  -- broke -- on any hit -- zeroed the move's effect, so TWINEEDLE's poison
  -- (`.twineedle` rewrote the effect to POISON_SIDE_EFFECT1 on the first hit)
  -- is gone with it.  A Substitute that soaked every hit and still stands is
  -- the routine's to answer, so it is passed through (Effects.applySide).
  if defender.hp > 0 and effectLive then
    self:_applySide(fighter, mon, target, defender, effectId, move)
  end

  -- A substitute absorbs HP (including the breaking hit), so totalDealt stays
  -- 0. Do not then apply a foe primary onto the mon behind it.  Nor onto one
  -- the move knocked out: JumpMoveEffect at `.executeOtherEffects` is past
  -- `ret z` on the target's HP (core.asm :3232-3242), and the knockout's
  -- faint waits for the move's end now (K19), so the 0 HP is what says so.
  if Effects.handlesPrimary(effectId) and totalDealt > 0 and defender.hp > 0 then
    self:_applyPrimary(fighter, mon, target, defender, self:_listIndex(fighter, choice),
      effectId, move.id)
  end

  -- HYPER_BEAM_EFFECT is one of `.executeOtherEffects`' (a knockout returned
  -- before it, a broken doll zeroed it); a doll that held still costs the
  -- recharge.
  if Effects.isHyperBeam(effectId) and effectLive and defender.hp > 0 then
    mon.mustRecharge = true
  end

  -- ExplodeEffect ran with the AlwaysHappen routines (`_alwaysHappen` notes
  -- it); its HP is taken here, after the target's Rage lines -- ExplodeEffect
  -- zeroes the HP without a word -- and "fainted!" comes once the move is
  -- over (`_reapKo`).  A doll the blast broke zeroed the effect first: the
  -- user lives.
  if Effects.isExplode(effectId) and effectLive then
    self:_faintUser(fighter, mon)
  end

  self:_markLastMove(mon, usedSlot)
end

-- AlwaysHappenSideEffects (data/battle/always_happen_effects.asm), the
-- routines `.notDone` jumps to after a hit lands, before HandleBuildingRage
-- and before the target's knockout is looked at: DRAIN_HP / DREAM_EATER,
-- PAY_DAY, RECOIL (and STRUGGLE, whose effect it is), RAGE, EXPLODE and the
-- multi-hit counts (`_useMove` draws those).  One per move -- a move carries
-- one effect.  `_useMove` skips this once a doll the move hit has broken.
--   * DrainHPEffect_ halves wDamage in place (at least 1) and heals that.
--   * PayDayEffect_ adds the user's level x 2 to the pile, on either side's
--     turn (`_checkOver` pays it).
--   * RecoilEffect_ costs a quarter of wDamage (a half for STRUGGLE), at
--     least 1, straight off the user's HP -- never its own doll.
--   * RageEffect sets USING_RAGE; `calledMove` is the move a METRONOME /
--     MIRROR MOVE called, which the forced turns replay.
--   * ExplodeEffect's faint is `_useMove`'s, said after the move.
function Battle:_alwaysHappen(fighter, mon, effectId, struggling, usedSlot, calledMove, defender, target)
  if Effects.isDrain(effectId) then
    local heal = Effects.drainAmount(self.lastDamage)
    self.lastDamage = heal
    self:_heal(fighter, mon, heal)
    -- DrainHPEffect_ ends on SuckedHealthText -- DreamWasEatenText for
    -- DREAM EATER (move_effects/drain_hp.asm :85-96) -- full HP or not:
    -- "Sucked health from\n<TARGET>!", "<TARGET>'s\ndream was eaten!".
    local name = named(target, defender)
    if int(effectId, 0) == 8 then
      self:_say(name .. "'s\ndream was eaten!")
    else
      self:_say("Sucked health from\n" .. name .. "!")
    end
  elseif Effects.isPayDay(effectId) then
    self.payDay[fighter.side] = self.payDay[fighter.side] + Effects.payDayCoins(mon.level)
    self:_say("Coins scattered\neverywhere!")
  elseif struggling or Effects.isRecoil(effectId) then
    local recoil = Effects.recoilAmount(self.lastDamage, struggling)
    self:_say(named(fighter, mon) .. "'s\nhit with recoil!")
    self:_damage(fighter, mon, recoil, nil, true)
  elseif Effects.isRage(effectId) then
    mon.raging = true
    mon.rageMove = usedSlot
    mon.rageCall = calledMove
  end
end

-- One place where HP comes off, so the faint that follows can never be
-- forgotten at one of the call sites.  Rage is not built here: what builds it
-- is a move landing (`_buildRage`), not HP coming off.
--
-- `direct` is HP the cart takes straight off the monster, past any doll:
-- HandlePoisonBurnLeechSeed_DecreaseOwnHP (a poison, burn or Leech Seed
-- tick), RecoilEffect_ and ExplodeEffect write the HP word themselves, and
-- only ApplyDamageTo*Pokemon -- a move's hit -- ever asks AttackSubstitute
-- (whose header says as much of recoil).
--
-- Returns what wDamage holds after the hit, for COUNTER (`lastDamage`): the
-- whole amount against a doll -- AttackSubstitute takes it off the doll's
-- own byte and leaves wDamage alone -- and on a monster the HP it actually
-- took, ApplyDamageTo*Pokemon writing the old HP back over a knockout.
function Battle:_damage(fighter, mon, amount, status, direct, holdFaint)
  amount = max(0, int(amount, 0))

  -- (A Bide does not store here: `.BideCheck` adds wDamage on the storing
  -- monster's own turn, `_bideTurn`.)

  -- AttackSubstitute (core.asm :4849-4910): a hit over 255 breaks the doll
  -- outright (`and a` on wDamage's high byte); otherwise `sub [hl]` /
  -- `ret nc`, so a hit for exactly the doll's HP leaves it standing at 0
  -- (`subAtZero`), and only a hit for more breaks it.
  if amount > 0 and not direct and Effects.hasSubstitute(mon) then
    -- SubstituteTookDamageText first, every hit (AttackSubstitute's own
    -- opening line, core.asm :4857-4858): <TARGET> is the doll's owner --
    -- the other side's, on a self-hit or a crash -- then
    -- SubstituteBrokeText if it went.
    self:_say("The SUBSTITUTE\ntook damage for\n" .. named(fighter, mon) .. "!")
    local dollHp = max(0, int(mon.substitute, 0))
    if amount > 255 or amount > dollHp then
      mon.substitute = 0
      mon.subAtZero = nil
      self:_say(named(fighter, mon) .. "'s\nSUBSTITUTE broke!")
    else
      mon.substitute = dollHp - amount
      mon.subAtZero = (mon.substitute == 0) or nil
    end
    self:_emit("damage", {
      slot = fighter.slot, side = fighter.side,
      amount = amount, hp = mon.hp,
      status = status and M.STATUS_TO_WIRE[status] or nil,
    })
    return amount
  end

  if amount > mon.hp then amount = mon.hp end

  mon.hp = mon.hp - amount

  self:_emit("damage", {
    slot = fighter.slot, side = fighter.side,
    amount = amount, hp = mon.hp,
    status = status and M.STATUS_TO_WIRE[status] or nil,
  })

  -- `holdFaint`: the caller runs `_faint` itself, once its pass is done
  -- (`_residualFor`).  Inside an action (`koHeld`) the knockout waits for
  -- the action's end, where MainInBattleLoop looks at the HP (`_reapKo`,
  -- K19).  Anywhere else it faints here.
  if mon.hp <= 0 and not holdFaint and not self.koHeld then self:_faint(fighter, mon) end
  return amount
end

-- HandleBuildingRage (core.asm :4913-4950), for the monster `source`'s move
-- was just aimed at.  The cart has two callers, ExecutePlayerMove (:3243) and
-- ExecuteEnemyMove (:5643), both after ApplyAttackTo*Pokemon and both behind
-- `ret z` on the target's HP -- so it runs once per hit of a move that lands,
-- never for a hit that knocked the target out, and never for HP that no
-- opponent's move took: a poison / burn / Leech Seed tick, a confusion or
-- disobedience self-hit, recoil, a crash.  A Substitute that soaked the hit
-- does not stop it (AttackSubstitute returns to the same caller, and the
-- target's HP is untouched).  The paths that reach it here: every hit of the
-- strike loop (fixed damage included), the Bide release (`.UnleashEnergy`
-- jumps to HandleIfPlayerMoveMissed), a trap's later turns (`.MultiturnMoveCheck`
-- jumps to GetPlayerAnimationType, `_trapTurn` here), an Explosion
-- that did not land (EXPLODE_EFFECT is the one miss `.notDone` lets through),
-- and a power-0 move outside both ResidualEffects lists, which CalculateDamage
-- sends past MoveHitTest to a no-op ApplyAttack (Disable).
--
-- It flips hWhoseTurn and runs StatModifierUpEffect, so the raging battler is
-- the "user": its own badges re-run (when it is the player's) and the
-- re-penalty lands on the battler whose turn it then is not -- the attacker,
-- `source`'s monster.  At +6 the cart returns before saying anything (`cp
-- $0d` / `ret z`, ahead of the text), as this does; otherwise it prints
-- BuildingRageText, "<MON>'s RAGE is building!", and then whatever
-- StatModifierUpEffect prints -- "ATTACK rose!", or "Nothing happened!" off
-- a 999 Attack.
function Battle:_buildRage(fighter, mon, source)
  if not source or not mon or not mon.raging or mon.hp <= 0 then return end
  if Effects.clampStage(mon.stages and mon.stages.atk) >= Effects.STAGE_MAX then return end
  self:_say(named(fighter, mon) .. "'s\nRAGE is building!")
  local outcome, after = Effects.changeStat({
    mon = mon, fighter = fighter, stat = "atk", delta = 1,
    mover = fighter, nonMover = activeMon(source),
  })
  if outcome == "rose" then
    local line = named(fighter, mon) .. "'s\nATTACK rose!"
    self:_say(line)
    self:_emit("stat", {
      slot = fighter.slot, side = fighter.side,
      amount = after, stage = after, text = Events.plain(line),
    })
  elseif outcome == "stuck" then
    self:_say("Nothing happened!")
  end
end

function Battle:_heal(fighter, mon, amount)
  amount = max(0, int(amount, 0))
  if amount <= 0 then return end
  local before = mon.hp
  mon.hp = min(mon.maxHp, mon.hp + amount)
  local gained = mon.hp - before
  if gained <= 0 then return end
  self:_emit("drain", {
    slot = fighter.slot, side = fighter.side,
    amount = gained, hp = mon.hp,
  })
end

-- ------------------------------------------------------------------
-- participation (who fought the monster that fell)
-- ------------------------------------------------------------------
--
-- Vanilla does not pay whoever happened to be standing when the foe dropped --
-- it pays every monster of yours that was ever in against *that* foe and is
-- still alive, benched included.  The engine keeps it as one bitfield per party
-- (`wPartyGainExpFlags`), and gen1recomp's port of it is the reference this
-- mirrors line for line:
--
--   * set on send-out.  `BattleState:markParticipant`
--     (src/battle/BattleState.lua:2332-2337) flags the player mon that is out;
--     it is called at battle start (:1681), on a voluntary switch (:2424), on
--     a post-faint replacement (:4214) and again when the enemy sends its next
--     one out (:3980) -- the standing mon re-joins the new foe's set.
--   * cleared when the foe changes.  `awardExp` ends with
--     `self.participants = {}` (:3899), so the set is per enemy MONSTER, not
--     per battle; the SHIFT arm zeroes it explicitly at the same moment the
--     enemy is replaced (:4020, quoting core.asm:1436-1443).  Gen 1 has no
--     voluntary enemy switch to cite, and the shift arm is the one place the
--     cart states what a foe swap does to the flags -- so a foe seat changing
--     its monster resets that seat's set here, and the standing opposition is
--     re-marked, exactly as :4020-4021 does it.
--   * dropped on its own faint.  `onFaint` does
--     `self.participants[battler.mon] = nil` (:3721-3723, RemoveFaintedPlayerMon),
--     so a participant that died before the KO is neither paid NOR counted in
--     the divisor -- it leaves the set altogether.
--   * ...and the send-out's own mark (:3980) lands a turn late here, because a
--     seat is *asked* for its replacement rather than just sending one.  It is
--     taken at the faint, against the field the faint happened on, and held in
--     `fighter.pendingFought` until `_refield` fields the successor.  See
--     `_faint`; `_unfield` reaches the held copy too.
--
-- The set lives per seat because a mediated fight has up to two foe seats, each
-- with its own current monster; `fighter.fought` holds the opposing
-- (field slot, party index) pairs that have been in against *this* seat's
-- current one.  Keys are strings so the two runtimes agree on membership
-- without agreeing on table iteration order -- nothing ever walks this table,
-- it is only ever asked.
local function foughtKey(slot, index)
  return slot .. ":" .. index
end

-- This seat's monster just changed (battle start, switch, replacement).
--
-- Its own set resets, then the currently standing opposition marks into it --
-- and the incoming monster marks into each of THEIR sets, which is the other
-- direction of :2424: a switch-in joins the standing foe's participants.  A
-- foe of ours that is mid-replacement (nothing out) is neither read nor
-- written, the same way the engine has no enemy to mark against.
function Battle:_refield(fighter)
  fighter.fought = {}
  local mine = activeMon(fighter) and fighter.active or nil
  local foes = self.bySide[fighter.side == "a" and "b" or "a"]
  for _, foe in ipairs(foes) do
    if activeMon(foe) then
      fighter.fought[foughtKey(foe.slot, foe.active)] = true
      if mine then
        foe.fought = foe.fought or {}
        foe.fought[foughtKey(fighter.slot, mine)] = true
      end
    end
  end

  -- ...and the mark the deferred send-out still owes (`_faint` explains why it
  -- is held rather than taken here): whoever was standing when the monster this
  -- one replaces went down was in against this one too, which is :3980 read for
  -- a seat that is asked for its replacement instead of just sending it.  Only
  -- this direction is owed -- the seat opposite re-derives its own set the next
  -- time it refields, exactly as the engine keeps flags on one side only.
  -- Consumed once: a seat that refields again later starts clean.
  local pending = fighter.pendingFought
  fighter.pendingFought = nil
  if pending then
    for i = 1, #pending do fighter.fought[pending[i]] = true end
  end
end

-- Who is standing opposite this seat right now, as participation keys, in field
-- order.  A list rather than a set because it is walked: two runtimes agreeing
-- about a set they only ever ask is cheap, agreeing about one they iterate is
-- not.
function Battle:_standingOpposition(fighter)
  local keys = {}
  local foes = self.bySide[fighter.side == "a" and "b" or "a"]
  for _, foe in ipairs(foes) do
    if activeMon(foe) then keys[#keys + 1] = foughtKey(foe.slot, foe.active) end
  end
  return keys
end

-- RemoveFaintedPlayerMon: a monster that faints stops being a participant
-- anywhere, so it neither collects nor counts.
function Battle:_unfield(fighter, index)
  local key = foughtKey(fighter.slot, index)
  for _, other in ipairs(self.fighters) do
    if other.fought then other.fought[key] = nil end
    -- The held mark is reached too.  A monster that fell while the seat
    -- opposite was still choosing its replacement was never in against that
    -- replacement, so it must not be sitting in the set the successor inherits
    -- -- the same rule, one send-out earlier.
    local pending = other.pendingFought
    if pending then
      for i = #pending, 1, -1 do
        if pending[i] == key then table.remove(pending, i) end
      end
    end
  end
end

-- What a faint pays, and to whom.
--
-- **Facts, never an amount.**  This referee holds no species table -- it never
-- has and, by the legal floor this whole server is built under, never will --
-- so it cannot compute a single point of experience.  What it *can* do is state
-- the three things the formula needs and nothing else knows: which monster
-- fell, what level it was, and how many shares split it.  Each client then runs
-- its own Experience over its own party, which is also the only place the
-- result can persist.  This is the same shape as the vitamin writeback and the
-- catch grant: the authority announces, the owner applies.
--
-- The mode gate is not a shortcut for the owner check, it is the rule.  A
-- seated fighter here carries a playerId whether a connection is behind it or a
-- synthetic wild / trainer seat is, so "does this seat have an owner" is not a
-- question the turn machine can ask -- but the *mode* answers it, because the
-- hub only ever seats a synthetic opponent in these three, and always on side
-- b (`maxFighters` above says the same thing about coop_wild's humans-vs-one-
-- wild).  1v1 and coop_pvp are left out deliberately rather than incidentally:
-- paying a player for beating another player is a farming loop, and it is not
-- what vanilla does with a link battle either.
local EXP_MODES = { wild = true, coop_wild = true, coop_npc = true }
-- The side the owners sit on in those modes; side b is the synthetic seat.
local EXP_OWNER_SIDE = "a"

-- One event per PAID monster, in seat order and then party order.
--
-- Order is load-bearing twice over: the JS twin emits the same list in the same
-- order, and a stream that differs by a permutation is a parity failure with no
-- symptom anyone could read.  `bySide` is built in roster index order and
-- `fieldSlot` is monotonic in that index, so the outer walk is a walk of slots;
-- the inner one is the party array, which is the order the engine's own
-- `for _, mon in ipairs(self.game.save.party)` walk uses
-- (src/battle/BattleState.lua:3796).
--
-- `slot` stays the owning FIGHTER's field slot -- that is the ownership gate,
-- and it is what a client checks before writing to its own save.  `mon` says
-- which of that party banks the share, 0-based, because a benched participant
-- has no field slot to be named by.
--
-- The divisor is the engine's: `participants` counts every member of the set,
-- `alive` is the subset still above zero HP, and only `alive` is paid
-- (BattleState.lua:3795-3801).  The two numbers agree in practice because a
-- faint already left the set (`_unfield`), which is exactly why the engine can
-- write it as two loops over one flag and not care -- mirrored rather than
-- collapsed so the shape stays comparable.
--
-- The empty-set fallback is :3802-3804: with nothing flagged, the monster that
-- is out gets the whole thing.  Two seats can be out here where the engine has
-- one, so all of the standing ones share it -- which is also, exactly, what
-- round 5 paid in every case.
--
-- No roll is drawn anywhere in here: the parity digest's rngState must not move
-- because a faint paid out.
function Battle:_awardExp(fallen, mon)
  if not EXP_MODES[self.mode] then return end
  if fallen.side == EXP_OWNER_SIDE then return end

  local fought = fallen.fought or {}
  local participants, alive = 0, {}
  for _, fighter in ipairs(self.bySide[EXP_OWNER_SIDE]) do
    for index = 1, #fighter.mons do
      if fought[foughtKey(fighter.slot, index)] then
        participants = participants + 1
        if fighter.mons[index].hp > 0 then
          alive[#alive + 1] = { fighter = fighter, index = index }
        end
      end
    end
  end

  if participants == 0 then
    for _, fighter in ipairs(self.bySide[EXP_OWNER_SIDE]) do
      if activeMon(fighter) then
        participants = participants + 1
        alive[#alive + 1] = { fighter = fighter, index = fighter.active }
      end
    end
  end
  if #alive == 0 then return end

  for _, winner in ipairs(alive) do
    self:_emit("exp", {
      slot = winner.fighter.slot,
      species = mon.species,
      speciesId = mon.speciesId,
      level = mon.level,
      participants = participants,
      mon = winner.index - 1,
    })
  end
end

-- Pay for everything the action just felled, in the order it fell.
--
-- Split from `_faint` because the engine splits it: `onFaint` knocks a monster
-- *down* and clears its flag (BattleState.lua:3721-3723), and the payout is
-- queued behind that in `enemyMonFainted` -- so by the time anybody is counted,
-- every monster the action killed has already left the set.  Paying inside
-- `_faint` instead put a self-KO'er in its own victim's payout: an Explosion or
-- a recoil that kills its user runs `_faintUser` *after* the target's faint, so
-- the user was still standing, still flagged, and still in the divisor.
-- CoopSim's `reapFaints` drops the whole batch before announcing any of it for
-- exactly this reason; this is that same batch, at the boundary the turn
-- machine already had.
--
-- Draws nothing: the parity digest's rngState must not move because a faint
-- paid out, whenever it pays.
function Battle:_drainExp()
  local queue = self.pendingExp
  if #queue == 0 then return end
  self.pendingExp = {}
  for i = 1, #queue do self:_awardExp(queue[i].fallen, queue[i].mon) end
end

function Battle:_faint(fighter, mon)
  self.faints = self.faints + 1
  -- RemoveFaintedPlayerMon first (BattleState.lua:3721-3723 runs at the top of
  -- onFaint): this one is out of every participation set before anything below
  -- can pay anybody, so a mon that died on the way to the KO is not in the
  -- divisor.  Keyed off the seat's own party position rather than `active`,
  -- which the recoil path has not cleared yet.
  for index = 1, #fighter.mons do
    if fighter.mons[index] == mon then self:_unfield(fighter, index); break end
  end
  -- wBattleResult (`_payDayOn`): RemoveFaintedPlayerMon's 1 for the player's
  -- side, FaintEnemyPokemon's 0 for the other while the player still has a
  -- monster standing (AnyPartyAlive; with none it returns before the write).
  if fighter.side == EXP_OWNER_SIDE then
    self.battleResult = 1
  elseif self:_sideAlive(EXP_OWNER_SIDE) then
    self.battleResult = 0
  end
  mon.charging = nil
  mon.invulnerable = false
  mon.mustRecharge = false
  mon.thrashing = nil
  mon.raging = false
  mon.rageMove = 0
  mon.rageCall = nil
  mon.trapped = nil
  mon.trapping = nil
  mon.bide = nil
  mon.substitute = 0
  mon.subAtZero = nil
  mon.lightScreen = false
  mon.reflect = false
  mon.mist = false
  mon.focusEnergy = false
  -- A Transform goes with it too, and a MIMIC: a revived monster has its own
  -- moves (`Effects.restoreMoves`).
  Effects.restoreMoves(mon)
  mon.toxicLinger = nil
  mon.xAccuracy = false
  mon.leechSeed = nil
  mon.disable = nil
  -- Stages and the battle stats go with it: a monster that comes back (a
  -- Revive, then a switch-in) is loaded from its party stats like any other.
  Effects.loadBattleStats(mon, nil)
  self:_clearTrapsFrom(fighter.slot)

  -- Living bench? Computed before clearing active; fainted mon already has hp 0.
  local next_ = firstLiving(fighter.mons)
  self:_emit("faint", {
    slot = fighter.slot, side = fighter.side, text = mon.species,
    -- amount=1 is the authoritative mustReplace signal (living bench). Clients
    -- open the replace picker from this rather than guessing from local HP.
    -- Omitted when the seat is out of mons so empty-bench never arms a picker.
    amount = next_ and 1 or nil,
  })
  -- Immediately behind the faint line rather than at the next window, because
  -- this is the one roster change a player is *watching* happen: the ball goes
  -- dark in the same batch the monster goes down in, and a fight that ends on
  -- this faint has no next window to have said it at.
  self:_syncTeams(fighter)

  -- Owed here, paid at the end of the action (`_drainExp`), with the fallen
  -- sheet held in the queue so the payout still names the monster that fell and
  -- the level it was.  For an ordinary KO nothing moves: the faint, then its
  -- spoils, and only then anything about what comes next -- the order CoopSim
  -- announces in.  What changes is the action that fells two: every one of them
  -- is out of the sets before the first share is counted.
  self.pendingExp[#self.pendingExp + 1] = { fallen = fighter, mon = mon }

  fighter.active = nil
  if next_ then
    -- Ask the seat for a switch on the next choice window; timeout / autoPick
    -- still lands firstLiving (preferring an SE bench). No PROTOCOL bump —
    -- same `switch` + `turn`/`chose` vocabulary; amount rides an existing field.
    fighter.mustReplace = true
    -- The successor's mark, taken now because the send-out is not now.
    --
    -- Vanilla marks whoever is standing at the enemy's send-out
    -- (BattleState.lua:3980), and the engine sends out inside the faint itself,
    -- while the monster that landed the KO is still on the field -- which is
    -- also where CoopSim does it (`announceFaint` calls `sendOut` for an NPC
    -- inside `reapFaints`).  This referee cannot: it asks the seat, and the
    -- answer arrives on the next choice window, by which time side a's own
    -- switches have already resolved (`_resolveSwitches` walks side a first).
    -- A player who swaps on that turn would hand the incoming foe a set that
    -- never heard of the monster that beat the last one.  So the send-out's
    -- mark is taken here, against the field the faint actually happened on, and
    -- held until `_refield` puts the successor out.
    fighter.pendingFought = self:_standingOpposition(fighter)
  else
    fighter.mustReplace = nil
    fighter.pendingFought = nil
  end

  -- While resolving, defer `_checkOver` to the caller (after the current move /
  -- residual batch) so the same action can still faint the user (recoil,
  -- explode) and land a draw. Outside resolve, end immediately -- and pay
  -- first, because there is no action boundary out here to pay at.
  if self.phase ~= "resolving" then
    self:_drainExp()
    self:_checkOver()
  end
end

-- HandlePoisonBurnLeechSeed (core.asm :470-548) for one seat, at the end
-- of its slot (`_resolveFights`).
function Battle:_residualFor(fighter)
  if self.result then return end
  local mon = activeMon(fighter)
  -- It takes the poison / burn tick and then the Leech Seed tick in one
  -- pass, and looks at the HP only after both -- so a monster the poison or
  -- burn knocks out still feeds its seeder.  Read before the tick: `_faint`
  -- clears `leechSeed`.
  local seeded, seed, poisonKo = mon, mon and mon.leechSeed, false
  -- ...and the lingering Bad Poison bit, which `_faint` also clears.
  local lingered = mon ~= nil and mon.toxicLinger == true
  if mon and mon.status then
    local amount = Status.residual({
      status = mon.status, maxHp = mon.maxHp, toxicCounter = mon.toxicCounter,
    })
    if amount then
      if mon.status == "toxic" then
        mon.toxicCounter = mon.toxicCounter + 1
      elseif mon.toxicLinger then
        -- HandlePoisonBurnLeechSeed_DecreaseOwnHP multiplies by the toxic
        -- counter on the BADLY_POISONED bit alone, so a bit that outlived a
        -- nap (`toxicLinger`) turns a later poison -- or a burn -- toxic.
        amount = amount * max(1, int(mon.toxicCounter, 1))
        mon.toxicCounter = max(1, int(mon.toxicCounter, 1)) + 1
      end
      -- HurtByBurnText for a burn, HurtByPoisonText for a poison --
      -- PSN on the status byte, a toxic included (core.asm :484-489).
      if mon.status == "burn" then
        self:_say(named(fighter, mon) .. "'s\nhurt by the burn!")
      else
        self:_say(named(fighter, mon) .. "'s\nhurt by poison!")
      end
      -- ...then BURN_PSN_ANIM, then the HP (:490-495).
      self:_statusAnim(fighter, "BURN_PSN_ANIM")
      -- The knockout is the main loop's, once the whole pass is done
      -- (`ret nz` on the HP, :526-528): its faint waits for the seed's tick.
      self:_damage(fighter, mon, amount, mon.status, true, true)
      poisonKo = mon.hp <= 0
    end
  end
  if self.result then return end
  -- The Leech Seed tick, on the monster seeded when the residual began: the
  -- one still standing, or the one its own poison or burn just knocked out
  -- (`poisonKo`).  A trap's later hits are not part of this pass: they are
  -- the trapper's own slot on the cart (`_trapTurn`).
  -- HandlePoisonBurnLeechSeed_DecreaseOwnHP takes 1/16 of the max HP (at
  -- least 1) and multiplies it by the toxic counter -- incremented again,
  -- so a badly poisoned, seeded monster's counter climbs twice a turn (the
  -- Leech Seed + Toxic glitch) -- whether or not the HP was there to take,
  -- and _IncreaseEnemyHP hands the seeder that whole amount ("bc isn't
  -- updated if HP subtracted was capped").  Read before the damage, since a
  -- tick that knocks the seeded monster out runs `_faint`, which clears
  -- `leechSeed`.
  mon = activeMon(fighter)
  if seed and (mon == seeded or poisonKo) then
    local amount = max(1, floor(seeded.maxHp / 16))
    if seeded.status == "toxic" or lingered then
      amount = amount * max(1, int(seeded.toxicCounter, 1))
      seeded.toxicCounter = max(1, int(seeded.toxicCounter, 1)) + 1
    end
    local from = seed.fromSlot
    local seeder = from and self:_fighterAtSlot(from)
    local sMon = seeder and activeMon(seeder)
    -- ABSORB's animation first, played from the seeder's half: the cart
    -- flips hWhoseTurn round PlayMoveAnimation (core.asm :506-516), so the
    -- move id rides an `anim` on the SEEDER's seat (K20) -- the one standing
    -- there now, which is also the one the HP goes to.  Then the HP goes both
    -- ways and HurtByLeechSeedText follows (:518-523), "LEECH SEED saps\n
    -- <USER>!" -- <USER> the seeded monster, hWhoseTurn flipped back.
    if sMon and sMon.hp > 0 then
      self:_emit("anim", { slot = seeder.slot, side = seeder.side, text = "ABSORB" })
    end
    if mon == seeded then self:_damage(fighter, mon, amount, nil, true, true) end
    if sMon and sMon.hp > 0 then self:_heal(seeder, sMon, amount) end
    self:_say("LEECH SEED saps\n" .. named(fighter, seeded) .. "!")
  end
  if seeded and seeded.hp <= 0 and fighter.mons[fighter.active] == seeded then
    self:_faint(fighter, seeded)
  end
  -- (Disable does not count down here: its counter steps in the disabled
  -- monster's own turn, `_tickDisable`.)
end

-- ------------------------------------------------------------------
-- endings
-- ------------------------------------------------------------------

-- EndOfBattle (engine/battle/end_of_battle.asm): outside a link battle, a
-- fight that ends with wBattleResult 0 adds wTotalPayDayMoney to the
-- player's money, "<PLAYER> picked up ¥N!".  That is a won fight, and also
-- an escape that never wrote the result -- a TELEPORT / ROAR / WHIRLWIND by
-- either side, a wild monster's flight, a POKé DOLL; the player's own RUN
-- writes 2 (TryRunningFromBattle) and a catch writes 2, so neither pays.
-- The pile is every PAY DAY that landed in the fight -- PayDayEffect_ adds to
-- it on either side's turn, so the computer's coins are the player's to pick
-- up too -- held at the 3-byte BCD's 999999 (AddBCD).  Side a is the player
-- in the three fights against the computer; a link fight pays nothing.  The
-- wallet (and Gold's Amulet Coin) is the client's (K11), on a `ko` or a
-- `run` outcome alike.
--
-- An escape pays only while wBattleResult is still 0 (`battleResult`): any
-- of the player's monsters fainting wrote 1 (RemoveFaintedPlayerMon), and
-- nothing but an enemy's faint writes 0 back (FaintEnemyPokemon) -- so a
-- TELEPORT, a ROAR or a POKé DOLL after an earlier faint of the player's
-- picks up nothing, though the fight went on.  A won fight always pays: the
-- enemy faint that won it wrote the 0, after any faint of the player's the
-- same action caused (FaintEnemyPokemon calls RemoveFaintedPlayerMon first).
function Battle:_payDayOn(result)
  if not result then return end
  if result.reason == "run" and self.battleResult ~= 0 then return end
  local coins = min(M.PAY_DAY_MAX, self.payDay.a + self.payDay.b)
  if EXP_MODES[self.mode] and coins > 0 then result.payDay = coins end
end

function Battle:_checkOver()
  if self.result then return true end
  local aliveA, aliveB = self:_sideAlive("a"), self:_sideAlive("b")
  if aliveA and aliveB then return false end

  if not aliveA and not aliveB then
    -- Both sides down at once.  Against the computer the player blacks out,
    -- whichever faint the cart finds first: HandleEnemyMonFainted runs
    -- AnyPartyAlive straight after FaintEnemyPokemon and jumps to
    -- HandlePlayerBlackOut on 0 (core.asm :699-705), and
    -- HandlePlayerMonFainted does before it even reads the enemy's HP
    -- (:969-975).  So the computer wins -- no prize money, no Pay Day
    -- (wBattleResult is RemoveFaintedPlayerMon's 1), and no exp:
    -- FaintEnemyPokemon returns on that same AnyPartyAlive before
    -- GainExperience (:802-806), as `_awardExp` finds no one standing.  A
    -- link fight's two carts each run that check on their own party and
    -- each black out (LinkBattleLostText): nobody won, the draw.
    if M.BADGE_MODES[self.mode] then
      self:_finish("win", self:_sidePlayers("b"), self:_sidePlayers("a"), "ko")
    else
      self:_finish("draw", nil, nil, "ko")
    end
  elseif aliveA then
    local result = self:_finish("win", self:_sidePlayers("a"), self:_sidePlayers("b"), "ko")
    self:_payDayOn(result)
  else
    self:_finish("win", self:_sidePlayers("b"), self:_sidePlayers("a"), "ko")
  end
  return true
end

-- `outcome` is stated from the *field's* point of view, not a recipient's:
-- "win" means the winners list won.  The per-client rendering -- the "loss"
-- the loser's screen shows -- belongs to the session layer that addresses the
-- message, because it is the only party that knows who it is talking to.
--
-- A draw carries no lists at all rather than two empty ones, because
-- Wire.battleOutcome refuses an empty id list: the absence is the statement.
function Battle:_finish(outcome, winners, losers, reason)
  if self.result then return self.result end

  self.result = {
    battle = self.id,
    outcome = outcome,
    winners = winners,
    losers = losers,
    reason = reason,
  }
  self.phase = "over"
  self.deadline = nil
  self.resolveDeadline = nil
  self:_emit("over", { text = reason })
  return self.result
end

-- nil until the fight is done, so `if battle:outcome() then` is the whole test.
function Battle:outcome()
  return self.result
end

-- Mirrored from Wire.LEVEL_MAX (the cart's MAX_LEVEL).
M.LEVEL_MAX = 100

-- Contract K9 (docs/plans/gen12-referee-gaps-fix.md): a mid-fight level-up,
-- as the hubs forward it from `mmo.battle_moveset` (Hub:applyBattleMoveset,
-- Relay.applyBattleMoveset).  `monIndex` is 1-based into the seat's party;
-- `level`, `stats` (atk def spd spc) and `maxHp` are the client's claim.
-- Returns true when the referee took it, false otherwise -- and never
-- raises: a hub calls this from a message handler.
--
-- The rebuild is experience.asm's (:150-245), after its CalcStats:
--   * the party struct takes the new level and stats, and the current HP
--     grows by what the max HP grew by;
--   * the monster in battle copies the level, the max HP and the stats into
--     its battle struct, and into its unmodified stats unless it is
--     TRANSFORMed (whose copied ones stay), then runs CalculateModifiedStats
--     (the stages), ApplyBurnAndParalysisPenaltiesToPlayer and
--     ApplyBadgeStatBoosts -- Effects.recalcBattleStats, exactly;
--   * a benched monster's party stats only (a switch-in reloads the rest).
--
-- Plausibility, judged here because the hubs pass the claim through: only
-- side a of a fight against the computer earns experience (EXP_MODES, the
-- `exp` events), a fainted monster earns none, the level must go up (to at
-- most LEVEL_MAX), and no stat may go down (CalcStats is monotonic in the
-- level, and stat exp only grows) or past 999.  With K7 on the sheet
-- (`base`, `dvs`, `statExp` -- the monster's own, pre-Transform) each stat
-- must also be at most what CalcStat gives at the new level with full stat
-- exp, and a claim that states no stats is computed from them with the
-- sheet's stat exp; without K7 and without stats only the level moves.
function Battle:levelUp(playerId, monIndex, level, stats, maxHp)
  local ok, applied = pcall(self._levelUp, self, playerId, monIndex, level, stats, maxHp)
  return ok and applied == true
end

local LEVEL_UP_STAT_EXP_MAX = 65535

function Battle:_levelUp(playerId, monIndex, level, stats, maxHp)
  if self.result or not EXP_MODES[self.mode] then return false end
  local fighter = self.byId[str(playerId) or ""]
  if not fighter or fighter.side ~= EXP_OWNER_SIDE then return false end
  local index = int(monIndex, nil)
  local mon = index and fighter.mons[index] or nil
  if not mon or mon.hp <= 0 then return false end
  local newLevel = int(level, nil)
  if newLevel == nil or newLevel <= mon.level or newLevel > M.LEVEL_MAX then return false end

  -- The monster's own species and DVs, not a Transform's copies.
  local own = mon.preTransform or mon
  local base, dvs, statExp = own.base, own.dvs, mon.statExp
  local k7 = type(base) == "table" and type(dvs) == "table"
  local function exp(key)
    return type(statExp) == "table" and int(statExp[key], 0) or 0
  end

  local newStats = nil
  if type(stats) == "table" then
    newStats = {}
    for _, key in ipairs(Effects.BATTLE_STATS) do
      local n = int(stats[key], nil)
      if n == nil then return false end
      newStats[key] = n
    end
  elseif stats ~= nil then
    return false
  elseif k7 then
    newStats = {}
    for _, key in ipairs(Effects.BATTLE_STATS) do
      newStats[key] = Effects.calcStat(base[key], dvs[key], newLevel, exp(key), false)
    end
  end
  local newMaxHp = nil
  if maxHp ~= nil then
    newMaxHp = int(maxHp, nil)
    if newMaxHp == nil then return false end
  elseif k7 then
    newMaxHp = Effects.calcStat(base.hp, Effects.hpDv(dvs), newLevel, exp("hp"), true)
  end

  if newStats then
    for _, key in ipairs(Effects.BATTLE_STATS) do
      local n = newStats[key]
      if n < int(mon.partyStats[key], 1) or n > Effects.MAX_STAT_VALUE then return false end
      if k7 and n > Effects.calcStat(base[key], dvs[key], newLevel, LEVEL_UP_STAT_EXP_MAX, false) then
        return false
      end
    end
  end
  if newMaxHp then
    if newMaxHp < mon.maxHp or newMaxHp > Effects.MAX_STAT_VALUE then return false end
    if k7 and newMaxHp > Effects.calcStat(base.hp, Effects.hpDv(dvs), newLevel,
                                          LEVEL_UP_STAT_EXP_MAX, true) then
      return false
    end
  end

  mon.level = newLevel
  local grew = 0
  if newMaxHp then
    grew = newMaxHp - mon.maxHp
    mon.maxHp = newMaxHp
    mon.hp = min(mon.maxHp, mon.hp + grew)
  end
  if newStats then
    for _, key in ipairs(Effects.BATTLE_STATS) do
      mon.partyStats[key] = newStats[key]
      if not mon.transformed then mon.stats[key] = newStats[key] end
    end
  end
  if fighter.active == index then
    Effects.recalcBattleStats(mon, fighter.badges)
    -- The HP bar the seat opposite draws: what it grew by, out of what.
    if grew > 0 then
      self:_emit("drain", {
        slot = fighter.slot, side = fighter.side,
        amount = grew, hp = mon.hp, maxHp = mon.maxHp,
      })
    end
  end
  return true
end

-- ------------------------------------------------------------------
-- the clock
-- ------------------------------------------------------------------

function Battle:disconnect(playerId)
  local fighter = self.byId[str(playerId) or ""]
  if not fighter or not fighter.connected then return false end
  if self.result then return false end

  fighter.connected = false
  fighter.graceEndsAt = self.now + self.reconnectGrace
  self:_emit("wait", { side = fighter.side, text = fighter.name })
  return true
end

-- Back inside the window continues the fight from where it paused, and the
-- choice deadline restarts rather than resuming: the player who reconnects
-- with two seconds left on a clock they could not see would be choosing under
-- a timer the drop created.
function Battle:reconnect(playerId)
  local fighter = self.byId[str(playerId) or ""]
  if not fighter or fighter.connected then return false end
  if self.result then return false end
  if fighter.graceEndsAt and self.now >= fighter.graceEndsAt then return false end

  fighter.connected = true
  fighter.graceEndsAt = nil
  self:_emit("reconnect", { side = fighter.side, text = fighter.name })

  if (self.phase == "choice" or self.phase == "replace")
     and not self:_anyDisconnected() and self.choiceTimeout > 0 then
    self.deadline = self.now + self.choiceTimeout
  end
  -- A leftover or forced fill was held open by `_maybeResolve`'s disconnect
  -- gate; close it now that everyone is back.
  self:_maybeResolve()
  return true
end

-- Advances the wall clock and fires whatever it has passed.  Returns true when
-- something actually happened, so a hub can skip a drain on a quiet tick.
--
-- Time only moves forward: a caller handing back an earlier `now` -- two
-- sources of time on a hub, a clock that stepped -- must not un-expire a grace
-- period that already ran.
function Battle:tick(nowSeconds)
  local now = int(nowSeconds, self.now)
  if now > self.now then self.now = now end
  if self.result then return false end

  -- A side that is already down must not sit out a choice window. Solo's
  -- clock is 0, so a faint that left the field in `choice` used to wait
  -- forever for an answer nobody can file -- the band on "Waiting for WILD...".
  if (self.phase == "choice" or self.phase == "replace") and self:_checkOver() then
    return true
  end

  -- Forced-only turns opened by the previous resolve wait here so one drain
  -- does not swallow a whole trap / recharge / thrash chain. Keep the flag
  -- while a seat is away; reconnect()'s `_maybeResolve` closes the turn.
  if self.forcedPending and self.phase == "choice" and not self:_anyDisconnected() then
    self.forcedPending = false
    if not self:_anyoneOwes() then
      self:_maybeResolve()
      return true
    end
  end

  local expiredA, expiredB = false, false
  for _, fighter in ipairs(self.fighters) do
    if not fighter.connected and fighter.graceEndsAt and self.now >= fighter.graceEndsAt then
      if fighter.side == "a" then expiredA = true else expiredB = true end
    end
  end

  if expiredA or expiredB then
    if expiredA and expiredB then
      self:_finish("draw", nil, nil, "disconnect")
    elseif expiredA then
      self:_finish("forfeit", self:_sidePlayers("b"), self:_sidePlayers("a"), "disconnect")
    else
      self:_finish("forfeit", self:_sidePlayers("a"), self:_sidePlayers("b"), "disconnect")
    end
    return true
  end

  -- A turn left in `resolving` -- typically after a throw the hub contained --
  -- has no player to wait on, so the ceiling is the only way out. `timeout` is
  -- the existing reason: Wire already phrases it, and a stuck resolve is not
  -- something a screen can usefully distinguish from an unanswered turn.
  if self.phase == "resolving" and self.resolveDeadline
     and self.now >= self.resolveDeadline then
    self:_finish("draw", nil, nil, "timeout")
    return true
  end

  -- The choice clock is suspended while anybody is away; the grace above is
  -- the only deadline running for them.
  --
  -- The replace phase runs on the same clock, and has to: a seat that owes a
  -- send-out and never answers would otherwise hold the field forever, with no
  -- turn open for the deadline that used to cover it.  `_autoChoice` already
  -- answers a `mustReplace` seat with a bench switch (it is the branch the NPC
  -- side takes), so the same sweep that fills an unanswered move fills an
  -- unanswered replacement, `_maybeResolve` closes the phase, and the fight
  -- carries on one monster down rather than wedging.
  if (self.phase == "choice" or self.phase == "replace")
     and self.deadline and self.now >= self.deadline
     and not self:_anyDisconnected() then
    for _, fighter in ipairs(self.fighters) do
      if self:_owes(fighter) then
        local auto = self:_autoChoiceOrSkip(fighter)
        if auto then
          fighter.choice = auto
          self:_emit("chose", {
            slot = fighter.slot, side = fighter.side, text = fighter.name,
          })
          self:_say(fighter.name .. " ran out of time")
        end
      end
    end
    self:_maybeResolve()
    -- A fighter with nothing left to auto-pick would leave the turn open on a
    -- deadline already in the past, and every later tick would announce the
    -- timeout again.  Push the clock instead: the fight waits one more window
    -- rather than filling the log.
    if (self.phase == "choice" or self.phase == "replace")
       and self.deadline and self.now >= self.deadline then
      self.deadline = self.now + self.choiceTimeout
    end
    return true
  end

  return false
end

-- ------------------------------------------------------------------
-- snapshot
-- ------------------------------------------------------------------
--
-- For tests and for a log line, not for a client: a client is sent events.
-- Everything here is a copy, so a caller poking at it cannot reach into the
-- field.
function Battle:snapshot()
  local field, waiting = {}, {}

  for _, fighter in ipairs(self.fighters) do
    local mon = activeMon(fighter)
    local party = {}
    for i = 1, #fighter.mons do party[i] = fighter.mons[i].hp end

    field[#field + 1] = {
      slot = fighter.slot,
      side = fighter.side,
      playerId = fighter.playerId,
      name = fighter.name,
      connected = fighter.connected,
      graceEndsAt = fighter.graceEndsAt,
      chose = fighter.choice ~= nil and fighter.choice.action or nil,
      mustReplace = fighter.mustReplace == true,
      species = mon and mon.species or nil,
      hp = mon and mon.hp or 0,
      maxHp = mon and mon.maxHp or 0,
      status = mon and mon.status and M.STATUS_TO_WIRE[mon.status] or nil,
      party = party,
    }
    if self:_owes(fighter) then waiting[#waiting + 1] = fighter.playerId end
  end

  return {
    battle = self.id,
    mode = self.mode,
    phase = self.phase,
    turn = self.turn,
    seq = self.seq,
    now = self.now,
    deadline = self.deadline,
    resolveDeadline = self.resolveDeadline,
    over = self.result ~= nil,
    reason = self.result and self.result.reason or nil,
    rngState = self.rng:state(),
    field = field,
    waiting = waiting,
  }
end

return M
