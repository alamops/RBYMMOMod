-- The turn machine (Gen 2 scaffold): choices in, events out, and one party deciding.
--
-- Light port of BattleSim/Turn.lua onto BattleSim2 formulas.  Public API matches
-- Gen1 Turn (`create`, `submitChoice`, `tick`, …).  Sheet stats are
-- atk/def/spe/spa/spd (Sp.Def); legacy spd+spc still accepted on ingest.
-- Damage/crit/accuracy/status draws use Gen2 rules.  Crystal EFFECT_* names
-- map onto the shared Gen1 effect-id handlers in Effects.idOf (so Leer /
-- Hypnosis / Screech actually resolve), and the Gold-native scripts -- the
-- SP. DEF / ACCURACY drop hits, the stat-raising hits, FLAME WHEEL, SACRED
-- FIRE, STOMP, TWISTER, SNORE's flinch, THUNDER, TRI ATTACK, GUST, EARTHQUAKE
-- and SKY ATTACK, then SLEEP TALK, LOCK-ON, SAFEGUARD and TOXIC -- have ids
-- of their own (Effects.lua 87..105); Thief is keyed
-- on its move id.  Traps, rampages, Pay Day, Mirror Move, Leech Seed and the
-- damage tail follow pokecrystal too (docs/plans/gen12-referee-gaps-fix.md).
--
-- Known gaps left for follow-up: weather inside Damage.compute from Turn
-- (THUNDER's rain / sun accuracy is unreachable without it), Gen2 sleep parity
-- tests, and Wire spa/spd event fields (T2c).  Badge boosts are not a gap: Crystal's stat and type
-- rules apply to side a against the computer (BADGE_MODES,
-- Effects.badgeBoost / badgeTypeBoost).  Nor is the damage step: the battle
-- stats (stage, badge, burn / paralysis), the crit stage rule, TruncateHL_BC
-- by cart family (K6), per-side screens, the confusion self-hit, typeless
-- Struggle and move priority all follow pokecrystal (docs/plans/
-- gen12-referee-fidelity.md); where the Gold engine port reads otherwise, the
-- cart wins.  Nor are held items (Items.lua: the static rules, keyed on the
-- sheet's hold effect), obedience (`_obey`) or the flinch reset (`_openTurn`),
-- nor Rage: Gold's is a counter built by the foe's hits and multiplied into
-- Rage's own damage (`_buildRage`, `_resetRage`, Damage `rageCount`), with no
-- lock-in and no Attack stage -- Gen 1's rule is not the cart's here.
--
-- The formula modules beside this one each answer a single question with no
-- memory.  This is the thing that holds the fight: it owns the field, the
-- clock, the RNG stream and the order the questions get asked in, and it is
-- the only file in src/BattleSim2/ with state.
--
-- **The RNG order is the contract.**  The twin under server/lib/battle/ has to
-- consume draws at exactly the same points or the same seed produces a
-- different fight, so every draw site is spelled out here and every one of
-- them is conditional in a way both runtimes can reproduce:
--
--   1. Quick Claw bytes: in each priority bracket two or more fighters share,
--      one byte per Quick Claw holder (side b's first, then side a's, each in
--      field order) until one fires, then
--      a speed tie-break byte, one per group of actors in the same priority
--      bracket, Quick Claw standing and speed -- a recharging seat and a
--      storing Bide among the actors (R2b: DetermineMoveOrder compares their
--      wCurPlayerMove);
--   2. the gate bytes of each actor, in CheckTurn's order (`_runGates`): one
--      for a sleeping monster (a frozen one draws none and never thaws
--      there), then one for a confused one, then one for a paralysed one --
--      each only when the monster has that status and no earlier gate (a
--      flinch, a self-hit, the disabled move) stopped it; a storing Bide runs
--      them too;
--   3. the obedience bytes of a traded monster over its badge cap, on a
--      `badgeRules` seat (`_obey`, BattleCommand_CheckObedience's own draws,
--      each only when reached);
--   4. per move that is actually used: METRONOME's pick (redrawn on a move
--      the user knows) and SLEEP TALK's slot bytes (redrawn on an excluded
--      one) ahead of the called move's own; a rampage's confusion byte (the
--      last of its turns, BattleCommand_CheckRampage, none under its own
--      side's SAFEGUARD) or THRASH's turn-count byte (its first turn, ahead
--      of `checkhit`, so on a miss too); the accuracy byte -- a BattleRandom
--      byte against a BRIGHTPOWDER and for a one-hit KO, the percent roll
--      otherwise, and none when `.DreamEater` / `.DrainSub` / `.FlyDigMoves`
--      or OHKO's level and matchup gates stopped the move first; the
--      `effectchance` byte, right after it and hit or miss, for a
--      script that runs one there and no substitute standing
--      (Effects.drawsEffectChance -- on a FLY / DIG miss too); then per hit
--      the crit byte, the damage roll (neither for a one-hit KO) and a Focus
--      Band byte on a holder,
--      MULTI_HIT's count byte (or two) after the first hit when the target
--      still stands; then the move's tail -- DEFENSE_DOWN_HIT's second
--      `effectchance` byte, the computer's StatDown byte, TRI ATTACK's own
--      `effectchance` byte and its loop's bytes, the confusion side effect's
--      turn byte, TRAP_TARGET's count byte -- and the King's Rock byte, in
--      that order, none of them drawn when an earlier step ended the move (a
--      missed move draws no crit byte; a knocked-out target no tail).  The
--      StatDown byte (BattleCommand_StatDown's `.ComputerMiss`,
--      Effects.statDownGate) is a side b seat's in a fight against the
--      computer, for a stat-down move but MUD-SLAP / OCTAZOOKA -- a primary
--      one right after its accuracy byte, hit or missed (`_statDownAfterMiss`),
--      a *DownHit in its tail, through a substitute too -- and never into Mist
--      or at -6.
--
-- Between turns, HandleDefrost draws one byte per frozen monster the freeze
-- did not land on that turn (`_heldDefrost`), after Mysteryberry -- for a
-- successor too, at the replace phase's close (`_closeReplace`).
--
-- Nothing else rolls.  Residuals, switches, the bag, the between-turn held
-- items, rage and the clock are all deterministic, so a battle replays from its
-- seed plus the choice log -- and a fight with no held item, no traded monster
-- and no priority move draws what it drew before any of them existed, but for
-- three changes the cart's order made on purpose: a flinched sleeping or
-- frozen monster now draws its status gate first (sleep and freeze come
-- before the flinch in CheckTurn); a move Metronome or Mirror Move called no
-- longer runs the gates a second time; and the paralysis byte now follows the
-- confusion byte and the disabled-move check (CheckTurn's last gate), so a
-- paralysed, confused monster draws them in the other order and draws no
-- paralysis byte on a self-hit or on its disabled move.  A Thief sheet with
-- its real 100% chance draws the side-chance byte it always drew; Thief now
-- obeys it.  The computer's stat-down moves draw the StatDown byte (item 4)
-- on top: only a fight against the computer whose side b uses one moves.
-- The referee-gaps run (docs/plans/gen12-referee-gaps-fix.md) moved more, each
-- the cart's: below / nextInt read the RNG's high bits (K12), `effectchance`
-- moved up to right after the accuracy byte and is drawn on a miss and at
-- chance 0 (EARTHQUAKE, SKY ATTACK), multi-hit moves draw their crit and roll
-- per hit and MULTI_HIT's count after the first, THRASH draws its count before
-- `checkhit` and its confusion on its last turn, a trap's count is 3..6, and
-- TRI ATTACK / DEFENSE_DOWN_HIT draw their own bytes.
--
-- **Policies chosen where Gen 1 had no answer**, each one written down because
-- the two runtimes have to pick the same one:
--
--   * *Turn order* is pokecrystal's DetermineMoveOrder widened to a field:
--     the priority bracket first (Effects.movePriority, GetMovePriority's
--     table), then a Quick Claw that fired in it (`.equal_priority`; at most
--     one per bracket, `_quickClaws`), then Speed (the battle stat: stage,
--     badge, paralysis), then the tie-break below.  Switches and items are not
--     in it -- they resolve before any move, as the cart's `.use_move` puts a
--     player who is not fighting first.  A recharging seat and a storing
--     Bide are (R2b): the cart orders them by the move they keep in
--     wCurPlayerMove, so they roll their Quick Claw and their speed tie.
--   * *Speed ties* break on a single RNG byte per tied group: below 128 the
--     side-a member goes first, otherwise the group reverses.  One draw per
--     group rather than per pair, so a 2v2 with four equal speeds costs one
--     byte on both runtimes.  A group is one bracket at one Speed, so a fight
--     with no priority move groups -- and draws -- exactly as Speed alone.
--   * *Running* is mode-gated, the same way Teleport is.  wild / coop_wild
--     flee (the runner loses with reason `run`); 1v1 / coop_pvp is a
--     concession, same bookkeeping, and both sides running is a draw;
--     coop_npc -- and any other non-wild non-pvp mode -- emits the trainer
--     refusal and does not finish, so a gym cannot be forfeited by pressing
--     RUN.  Mirrored: the policy reads the same from either seat.
--   * *Items* apply a hand-authored Gen1 heal/status table by id (Potion,
--     Full Restore, Revive, Ether, …) — locked twin of public amounts, not a
--     port of engine ItemEffects. Unknown ids announce "But it failed" and
--     still spend the turn. Bags are client claims (sheet trust locked; hub
--     has no ROM inventory truth); PROTOCOL 15 holds/spends mid-fight only.
--   * *Forced lock-in* (recharge, a charge's release, a rampage, Bide) fills
--     choices on `_openTurn` so the mediated path never opens a menu the
--     cartridge would withhold; a turn where *nobody* still owes waits for the
--     next `tick` before resolving so clients see a turn boundary for
--     wait-lines / anim pacing.  A trap is no lock-in on Gold: the wrapped seat
--     is asked (and refused a switch), the trapper is free, and HandleWrap's
--     sixteenth is the residual.
--   * *Status moves* run through Effects.lua. Metronome picks from host-uploaded
--     `metronomePool` on the ruleset (from MediatedBattle.snapshotRuleset);
--     without a pool it says "But nothing happened".
--   * *Physical / Special* follow Gen1 type categories via host-uploaded
--     `specialTypes` on the ruleset (indices into the uploaded chart). Absent
--     specialTypes keeps every damaging move on atk/def.
--   * *Type names* ride on the ruleset as `typeIds`, the chart's axis in
--     order (`typeIds[i + 1]` names type index i), because the badge type
--     boost is keyed by type and a move only carries an index; the side
--     effects read it too, for POISON (a Poison type is never poisoned by
--     one) and NORMAL (a Normal move's burn or freeze never meets the
--     same-type return).  Absent typeIds, no move's type can be named: no type
--     boost fires, a side effect poisons a Poison type, and burn and freeze
--     compare the move's type index with the target's alone.
--   * A *faint sends the next living monster in party order*, immediately and
--     without asking.  The original stops and asks; asking here would mean a
--     second kind of choice phase with its own deadline and its own forfeit
--     rule, and a fight that can hang between two turns is a worse v1 than one
--     that picks in party order.
--   * *Residuals* run in field order (side a, then side b), not in the speed
--     order the moves used.  Only the order two burns tick in is at stake, and
--     field order is the one both runtimes can reproduce without carrying the
--     turn's sort into the end-of-turn step.
--   * A *timeout* / NPC auto-picks with bag cures & heals (≤50% HP), X-items,
--     SE damage, status / setup reading, and SE bench switches (deterministic
--     heuristics — not a full TrainerAI port) -- and the fight continues.  It
--     does not end the battle -- the player who went to make a sandwich loses
--     a turn, not the match.
--   * *Struggle* when every move is out of PP: synthetic STRUGGLE (power 50),
--     no PP spent, recoil floor(damage/4) minimum 1 after a hit
--     (BattleCommand_Recoil), and typeless: pokecrystal BattleCommand_Stab
--     opens with `cp STRUGGLE / ret z`, so the weather step, DoBadgeTypeBoosts,
--     STAB and the whole matchup loop are skipped -- it hits a Ghost, takes no
--     STAB and no badge type boost, and says nothing about effectiveness.
--     Its row in data/moves/moves.asm is still NORMAL, which is the type
--     DamageCalc's type-boost item scan reads (STRUGGLE.typeId).  Struggle is
--     the move a top-level `_useMove` resolves to when every slot is empty; a
--     move Metronome or Mirror Move *calls* is never Struggle, so a call made
--     with the last PP takes no recoil.
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

local Damage   = need("BattleSim2/Damage")
local Accuracy = need("BattleSim2/Accuracy")
local Crit     = need("BattleSim2/Crit")
local Status   = need("BattleSim2/Status")
local Effects  = need("BattleSim2/Effects")
local Rng      = need("BattleSim2/Rng")
local Events   = need("BattleSim2/events")
local Items    = need("BattleSim2/Items")

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
-- only place the cart applies its badge boosts at all: pokecrystal's
-- BadgeStatBoosts (engine/battle/core.asm) opens with `ld a, [wLinkMode] /
-- and a / ret nz`, returning before it reads a badge in any link battle, and
-- raises wBattleMon -- the player's monster -- and nothing else; the engine's
-- port says the same (gen1recomp src/battle/gen2/Battle.lua:811-815, "never
-- the enemy and never in link"), and DoBadgeTypeBoosts (engine/battle/
-- misc.asm:146) boosts only the player's own move.  1v1 and coop_pvp are
-- link battles in everything but the cable, so both sides fight them
-- unboosted.  Side b of the other three is the synthetic wild / trainer seat
-- (see EXP_MODES on `_awardExp`), which no cart boosts, so a set uploaded
-- for it is a confused or a hostile client and is dropped the same way.
--
-- The referee is the gate rather than the client or the hub: a client can
-- forge an upload and a hub passes `badges` through untouched, and this is the
-- one place both hubs and solo share.  It is applied once, in `create`, where a
-- seat's set is copied -- every reader after that (`_speedOf`, both ends of the
-- damage step, the type boost, the confusion self-hit) sees nil and needs
-- no gate of its own.
M.BADGE_MODES = { wild = true, coop_wild = true, coop_npc = true }
M.BADGE_SIDE = "a"

-- The mod's link battles: the two modes where both seats are people, which
-- the cart would have fought over the cable.  Read where pokecrystal reads
-- `wLinkMode == LINK_COLOSSEUM` -- TruncateHL_BC's single pass
-- (Damage.truncateStats) -- and nowhere else yet.
M.LINK_MODES = { ["1v1"] = true, coop_pvp = true }

-- The cart lineages whose rules differ (contract K6): `family` on a side entry,
-- stamped by the hub from the hello `version` it admitted (gold / silver ->
-- "gs", crystal -> "crystal"; never read off the wire) and by solo from
-- Gen.family().  The fight reads it off side a's first fighter, and an absent
-- or unknown one is Gold / Silver's.  TruncateHL_BC is the rule that reads it
-- (`_onePassTruncate`): every held-item, obedience and flinch rule in this
-- file is the same routine on both carts (each one diffed against pokegold).
M.FAMILIES = { gs = true, crystal = true }
M.DEFAULT_FAMILY = "gs"

-- Berserk Gene's confusion when the seat's last confusion count ran out:
-- HandleBerserkGene sets SUBSTATUS_CONFUSED and never writes the count, and
-- CheckTurn's `dec [hl]` on a 0 count wraps to 255 -- 256 checks before it
-- snaps out (docs/bugs_and_glitches.md).
M.BERSERK_CONFUSION = 256

-- Guard on the cart's rejection-sampling loops (`.rand1`, `.rand2`,
-- `.RandomMove`, `.Nap`), which redraw until a byte lands in range.  Each is
-- won within a handful of draws; the guard only keeps a referee that must never
-- hang from trusting that, and both runtimes stop at the same count.
M.REDRAW_LIMIT = 1024

-- The highest level a K9 level-up may report (Wire.LEVEL_MAX, MAX_LEVEL).
M.LEVEL_MAX = 100

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
-- side M.BADGE_MODES never boosts -- the cart's enemy, whose turn is
-- `hBattleTurn` 1 with wLinkMode 0.  Where the cart gives the enemy a rule of
-- its own outside a link battle -- BattleCommand_StatDown's `.ComputerMiss`
-- is the case -- this is the seat that takes it.  Every other seat (side a
-- there, both sides of a link fight) is a player on its own cartridge.  The
-- Gen 1 twin keeps the same test.
local function isComputerSeat(mode, fighter)
  return fighter ~= nil and M.BADGE_MODES[mode] == true
    and fighter.side ~= M.BADGE_SIDE
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
-- `type = 0` is a placeholder index that nothing reads (Struggle is
-- typeless; see the policy note above); `typeId` is the cart row's NORMAL,
-- the registry id a held type-boost item is matched against in DamageCalc.
local STRUGGLE = {
  id = "STRUGGLE", power = 50, accuracy = 255,
  type = 0, effect = 0, chance = 0, typeId = "NORMAL",
}

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

-- An optional whole number in lo..hi, or nil -- a field the sheet may leave
-- out, whose absence is the answer (no clamp invents one).
local function optInt(value, lo, hi)
  local n = int(value, nil)
  if n == nil then return nil end
  return max(lo, min(hi, n))
end

local function copyMove(raw)
  if type(raw) ~= "table" then return nil end
  local pp = max(0, int(raw.pp, 0))
  local maxPp = max(pp, int(raw.maxPp, pp))
  return {
    id       = str(raw.id) or "move",
    -- Optional (PROTOCOL 26), and absence is a real answer rather than a gap
    -- to fill: a sheet from a protocol-25 client states no name, and the
    -- sentences below fall back to the id exactly as they always did.
    name     = str(raw.name),
    pp       = pp,
    maxPp    = maxPp,
    power    = max(0, int(raw.power, 0)),
    accuracy = max(0, int(raw.accuracy, 255)),
    type     = max(0, int(raw.type, 0)),
    effect   = max(0, int(raw.effect, 0)),
    chance   = max(0, int(raw.chance, 0)),
    highCrit = raw.highCrit == true,
    -- Contract K8: the cart's raw GetMovePriority number (0..255) the client
    -- stamps from the move's effect, which Effects.movePriority reads before
    -- its move-id table, and the slot's PP Ups (0..3; the bits the cart keeps
    -- in the PP byte).  Absent stays absent.
    priority = optInt(raw.priority, 0, 255),
    ppUps    = optInt(raw.ppUps, 0, 3),
  }
end

-- Contract K7 / K14 on a Gold sheet: the species' base stats, the four DVs,
-- the five stat-exp words and the happiness byte, each kept only when the
-- sender stated it (Wire's Gen 2 dialect keys).  Nothing here computes from
-- them but `levelUp`'s fallback (CalcMonStats when a level-up states no
-- stats); Transform copies the DVs, and wave 3's HIDDEN POWER, RETURN and
-- FRUSTRATION read them.
local SHEET_BLOCKS = {
  base = { keys = { "hp", "atk", "def", "spe", "spa", "spd" }, max = 255 },
  dvs = { keys = { "atk", "def", "spe", "spc" }, max = 15 },
  statExp = { keys = { "hp", "atk", "def", "spe", "spc" }, max = 65535 },
}
M.SHEET_BLOCKS = SHEET_BLOCKS

local function copyBlock(raw, spec)
  if type(raw) ~= "table" then return nil end
  local out, any = {}, false
  for _, key in ipairs(spec.keys) do
    local n = optInt(raw[key], 0, spec.max)
    if n ~= nil then out[key] = n; any = true end
  end
  if not any then return nil end
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
  -- Gen2 stages: spe (Speed), spa, spd (Sp.Def). Legacy Gen1: spd=Speed, spc=Special.
  local gen2shaped = stagesRaw.spe ~= nil or stagesRaw.spa ~= nil
    or stagesRaw.speed ~= nil
  local speStage = stagesRaw.spe
  if speStage == nil then speStage = stagesRaw.speed end
  if speStage == nil and not gen2shaped then speStage = stagesRaw.spd end
  local spaStage = stagesRaw.spa
  if spaStage == nil then spaStage = stagesRaw.spc end
  local spdStage = nil
  if gen2shaped then
    spdStage = stagesRaw.spd
  else
    spdStage = stagesRaw.spc
  end
  local stages = {
    atk = Effects.clampStage(stagesRaw.atk),
    def = Effects.clampStage(stagesRaw.def),
    spe = Effects.clampStage(speStage),
    spa = Effects.clampStage(spaStage),
    spd = Effects.clampStage(spdStage),
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
      moveId = str(raw.charging.moveId),
    }
  end

  -- A wrap the sheet carries: its HandleWrap count and its trapper's seat.
  local trapped = nil
  if type(raw.trapped) == "table" then
    trapped = {
      turns = max(0, int(raw.trapped.turns, 0)),
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
    stats = (function()
      -- Gen2 sheet: spa/spd (Sp.Def) + spe (Speed). Legacy Gen1: spd=Speed, spc=both specials.
      local atk = max(1, int(stats.atk, 1))
      local def = max(1, int(stats.def, 1))
      local spe, spa, spDef
      if stats.spa ~= nil or stats.spe ~= nil or stats.speed ~= nil then
        spe = max(1, int(stats.spe or stats.speed or 1, 1))
        spa = max(1, int(stats.spa or stats.spc or 1, 1))
        spDef = max(1, int(stats.spd or stats.spc or spa, 1))
      else
        spe = max(1, int(stats.spd, 1))
        spa = max(1, int(stats.spc, 1))
        spDef = spa
      end
      return { atk = atk, def = def, spe = spe, spa = spa, spd = spDef }
    end)(),
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
    thrashing = thrashing,
    raging = raw.raging == true,
    rageCounter = max(0, min(255, int(raw.rageCounter, 0))),
    bide = bide,
    lastMoveIndex = max(0, int(raw.lastMoveIndex, 0)),
    substitute = max(0, int(raw.substitute, 0)),
    mist = raw.mist == true,
    focusEnergy = raw.focusEnergy == true,
    transformed = raw.transformed == true,
    xAccuracy = raw.xAccuracy == true,
    catchRate = max(0, min(255, int(raw.catchRate, 255))),
  }

  -- The Gold held item and what the engine's item row says about it (contract
  -- K2): the id, its HELD_* effect and parameter, the name a sentence calls it
  -- and whether it is Mail.  Kept only alongside an item -- an effect with no
  -- item is nothing held -- and the referee's copy is the one that changes: a
  -- berry eaten or an item stolen is gone from it for the rest of the fight
  -- (Items.take / Items.give), and the `held` event tells the owner.
  local heldItem = str(raw.heldItem)
  if heldItem then
    out.heldItem = heldItem
    out.holdEffect = str(raw.holdEffect)
    out.holdParam = max(0, min(255, int(raw.holdParam, 0)))
    out.itemName = str(raw.itemName)
    if raw.mail == true then out.mail = true end
  end
  -- The obedience check's one fact about the monster (contract K1): its OT is
  -- not the player.  Only `true` counts; `_obey` asks it on `badgeRules` seats.
  if raw.traded == true then out.traded = true end
  for name, spec in pairs(SHEET_BLOCKS) do
    local block = copyBlock(raw[name], spec)
    if block then out[name] = block end
  end
  local happiness = optInt(raw.happiness, 0, 255)
  if happiness ~= nil then out.happiness = happiness end

  -- Optional Stat Exp sheet (atk/def/spe/spa/spd, optional hp). Absent keys stay 0
  -- at vitamin time; present values are what HP_UP / PROTEIN / … mutate.
  if type(raw.evs) == "table" then
    local evs = {}
    for _, key in ipairs({ "hp", "atk", "def", "spe", "spa", "spd" }) do
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

-- The ruleset's type registry ids in chart-axis order, so `typeIds[i + 1]`
-- names the type a move or a monster calls `i` (MediatedBattle.typeOrder
-- builds that axis).  Kept dense: an entry that is not a string reads as
-- false, a type with no name, rather than shifting every index after it.
local function copyTypeIds(raw)
  if type(raw) ~= "table" then return nil end
  local out, any = {}, false
  for i = 1, #raw do
    local id = raw[i]
    if type(id) == "string" and id ~= "" then
      out[i] = id
      any = true
    else
      out[i] = false
    end
  end
  if not any then return nil end
  return out
end

-- The chart index `typeIds` (copied, above) gives the type registry id
-- `name`: zero-based, the axis every move and monster on the upload uses; nil
-- when it names no such type, or names none at all.  The side effects ask it
-- for POISON (CheckIfTargetIsPoisonType) and NORMAL (CheckMoveTypeMatchesTarget's
-- exemption), the way BattleSim's twin asks for POISON and FIRE.
local function typeIndexOf(typeIds, name)
  if type(typeIds) ~= "table" then return nil end
  for i = 1, #typeIds do
    if typeIds[i] == name then return i - 1 end
  end
  return nil
end

-- Bag sheet for auto-pick / timeout item use (id → count). Accepts the same
-- shapes Wire.bag does: a list of {id,count} or a map.
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

-- opts:
--   id, mode, seed, chart, specialTypes, typeIds, metronomePool,
--   choiceTimeout, reconnectGrace, resolveTimeout, now
--   sides = { a = { { playerId, name, mons, bag, badges, family } }, b = { ... } }
--
-- `badges` is kept only on side a of a BADGE_MODES fight and dropped
-- everywhere else, silently: a PvP upload that carries one is a well-formed
-- upload the cart would simply not have boosted.
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
    specialTypes   = nil,
    typeIds        = copyTypeIds(opts.typeIds),
    poisonType     = typeIndexOf(opts.typeIds, "POISON"),
    normalType     = typeIndexOf(opts.typeIds, "NORMAL"),
    -- BattleCommand_LeechSeed's `cp GRASS` (a Grass type is never seeded).
    grassType      = typeIndexOf(opts.typeIds, "GRASS"),
    metronomePool  = nil,
    choiceTimeout  = max(0, int(opts.choiceTimeout, M.CHOICE_TIMEOUT)),
    reconnectGrace = max(0, int(opts.reconnectGrace, M.RECONNECT_GRACE)),
    resolveTimeout = max(0, int(opts.resolveTimeout, M.RESOLVE_TIMEOUT)),
    now            = max(0, int(opts.now, 0)),
    phase          = "choice",
    turn           = 1,
    seq            = 0,
    buffer         = {},
    -- What the current action has knocked down and not paid for yet; see
    -- `_drainExp`.  A list, so the order faints happened in is the order their
    -- spoils are announced in.
    pendingExp     = {},
    fighters       = {},
    byId           = {},
    bySide         = { a = {}, b = {} },
    -- Reflect / Light Screen and Safeguard, held per SIDE as pokecrystal
    -- holds them (wPlayerScreens / wEnemyScreens and their counts): turns
    -- left, 0 when down.  A side's seats share them, a switch or a faint
    -- leaves them up, Haze does not touch them, and only the between-turn
    -- ticks (`_tickSafeguard`, `_tickScreens`) take them down.
    screens        = { a = { lightScreen = 0, reflect = 0, safeguard = 0 },
                       b = { lightScreen = 0, reflect = 0, safeguard = 0 } },
    -- wPayDayMoney: the coins every PAY DAY that landed scattered, whoever
    -- used it (BattleCommand_PayDay); see `_payDayOutcome`.
    payDay         = 0,
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

      local fighter = {
        playerId  = playerId,
        name      = str(entry.name) or playerId,
        side      = side,
        index     = index,
        slot      = Events.fieldSlot(side, index),
        mons      = mons,
        badges    = seatBadges(mode, side, entry.badges),
        -- The cart's player in a fight against the computer, as BattleSim3
        -- keeps it: side a of M.BADGE_MODES.  Obedience and the flinch-reset
        -- exception ask this, which `badges` cannot answer -- a player with no
        -- badge at all has the most to disobey.
        badgeRules = (side == M.BADGE_SIDE and M.BADGE_MODES[mode]) and true or nil,
        -- Contract K6, validated the way BattleSim3 keeps its own `family`;
        -- the fight reads side a's first seat's (`self.family` below).
        family    = M.FAMILIES[entry.family] and entry.family or M.DEFAULT_FAMILY,
        -- wPlayerConfuseCount for this field position: what the last confusion
        -- here left behind, which a switch-in does not reset and Berserk
        -- Gene's confusion inherits (`_berserkGene`).
        confuseCount = 0,
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
      }
      self.fighters[#self.fighters + 1] = fighter
      self.byId[playerId] = fighter
      local bucket = self.bySide[side]
      bucket[#bucket + 1] = fighter
    end
  end

  -- The fight's cart (K6): side a's first seat speaks for it, as the hub's
  -- host seat does for the whole fight.
  self.family = self.bySide.a[1] and self.bySide.a[1].family or M.DEFAULT_FAMILY

  -- The opening field's battle stats, each lead loaded the way its seat's
  -- cart loads it (`_switchInStats`).
  for _, fighter in ipairs(self.fighters) do
    local mon = activeMon(fighter)
    if mon then self:_switchInStats(fighter, mon) end
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
    }
  end
  local fields = { slot = fighter.slot, side = fighter.side, moves = moves }
  if partyIndex then fields.mon = partyIndex - 1 end
  return self:_emit("moves", fields)
end

function Battle:_say(text)
  return self:_emit("msg", { text = text })
end

-- Every seat's party roster, published when -- and only when -- it moved.
--
-- Gen 2's twin of `BattleSim/Turn.lua:_syncTeams`; read that one's header for
-- why the referee is the only party to a mediated fight that can say this, and
-- why it says a ball row and never a sheet.  Same three tokens, same diff, same
-- three call sites, in the same order -- the roster chip does not know which
-- generation drew it.
function Battle:_syncTeams()
  for _, fighter in ipairs(self.fighters) do
    local roster = Events.teamString(fighter.mons)
    if roster ~= fighter.team then
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
--   * `byte()` is the draw, not `nextInt`.  `nextInt` takes the whole LCG
--     state modulo the span, and this generator's bit 0 alternates every
--     step, so a two-seat side would have got a perfect A-B-A-B rota rather
--     than a spread.  `byte()` reads bits 16..23, which is the reason
--     Rng.lua puts them there.
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
--
-- Byte-identical to the Gen 1 twin (src/BattleSim/Turn.lua): a stolen KO is a
-- field-geometry rule, and the field has the same shape in both games.
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

-- The forced answer for a recharging or biding seat, or nil.  A recharge is
-- a turn with no move (`recharge`): its seat still takes its place in the
-- turn order -- DetermineMoveOrder compares wCurPlayerMove, the Hyper Beam it
-- used, so it rolls its Quick Claw and its speed tie -- and CheckTurn says
-- "must recharge" when its slot comes (`_rechargeTurn`).  A Bide is a move
-- that is used every turn (wCurPlayerMove stays BIDE): storing (`bideStore`)
-- until its count runs out, then released (`bideRelease`) -- each turn
-- through CheckTurn's gates, so a sleeping, frozen, flinched, confused or
-- paralysed biding monster's CantMove ends it.
function Battle:_lockedChoice(fighter, mon)
  if mon.mustRecharge then
    return { action = "skip", recharge = true }
  end
  if mon.bide then
    -- A storing turn reads no target (StoreEnergy ends the move before one
    -- is), so none is picked for it; the release swings at the seat the Bide
    -- began on, or the one the referee picks when that seat is empty.
    if mon.bide.turns > 0 then
      return { action = "fight", move = mon.bide.moveIndex,
               target = mon.bide.targetSlot, bideStore = true }
    end
    local foe = self:_autoTarget(fighter)
    if not foe then return nil end
    return {
      action = "fight",
      move = mon.bide.moveIndex,
      target = mon.bide.targetSlot or foe.slot,
      bideRelease = true,
    }
  end
  return nil
end

-- Inject forced choices for charge release, recharge skip, Bide and the
-- rampage's next turns (CheckPlayerLockedIn).  A trap is not one on Gold: a
-- wrapped monster picks its moves (wPlayerWrapCount only closes switching and
-- running, `_normaliseChoice`) and its trapper is free -- Red's lock-in on
-- both seats is not the cart's here (`_residualDamage` holds HandleWrap).
function Battle:_fillForcedChoices()
  for _, fighter in ipairs(self.fighters) do
    if fighter.choice ~= nil then goto continue end
    local mon = activeMon(fighter)
    if not mon then goto continue end

    if mon.mustRecharge or mon.bide then
      local locked = self:_lockedChoice(fighter, mon)
      if locked then
        fighter.forced = true
        fighter.choice = locked
        self:_emit("chose", {
          slot = fighter.slot, side = fighter.side, text = fighter.name,
        })
      end
      goto continue
    end

    if mon.charging then
      local c = mon.charging
      fighter.forced = true
      fighter.choice = {
        action = "fight",
        move = c.moveIndex,
        target = c.targetSlot,
      }
      self:_emit("chose", {
        slot = fighter.slot, side = fighter.side, text = fighter.name,
      })
      goto continue
    end

    if mon.thrashing and mon.thrashing.turns > 0 then
      local foe = self:_autoTarget(fighter)
      if foe then
        self:_say(mon.species .. " thrashing about")
        fighter.forced = true
        fighter.choice = {
          action = "fight",
          move = mon.thrashing.moveIndex,
          target = foe.slot,
        }
        self:_emit("chose", {
          slot = fighter.slot, side = fighter.side, text = fighter.name,
        })
      end
      goto continue
    end

    -- Rage is not a lock-in on Gold / Crystal: the seat is asked like any
    -- other, and `_resetRage` ends the rage when it picks anything else.

    ::continue::
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
  -- wPlayerWrapCount: a monster a trapping move holds can be neither recalled
  -- (BattleMenu_PKMN's `.check_trapped`, "can't be recalled") nor run from a
  -- wild fight (TryToRunAway's `.cant_escape`).  Refused rather than filed, as
  -- the menu refuses it; conceding a link fight is the mod's, not a run.
  local wrapped = mon.trapped ~= nil and mon.trapped.turns > 0

  if action == "run" then
    if wrapped and Effects.teleportRunAllowed(self.mode) then return nil end
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
    return out
  end

  if action == "switch" then
    if wrapped then return nil end
    local slot = int(choice.slot, nil)
    if slot == nil then return nil end
    local target = partyIndexOf(fighter, slot)
    local bench = fighter.mons[target]
    if not bench or bench.hp <= 0 or target == fighter.active then return nil end
    return { action = "switch", slot = target }
  end

  if action == "fight" then
    local index = int(choice.move, nil)
    if index == nil then return nil end
    local move = mon.moves[index + 1]
    if not move then return nil end
    -- One empty slot is refused; every slot empty means Struggle on any index.
    if move.pp <= 0 and not allPpEmpty(mon) then return nil end
    if mon.disable and mon.disable.turns > 0
       and mon.disable.moveIndex == index + 1 then
      return nil
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
    return { action = "fight", move = index + 1, target = targetFighter.slot }
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
    -- A referee-filled answer is not the player's to take back.  Recharge,
    -- Bide, a rampage and a charge release all fill the seat at `_openTurn`;
    -- without this a client could cancel out of a lock-in, and on a turn
    -- where *every* seat is forced `_openTurn` left no deadline, so the
    -- cleared choice would hang the fight with nothing left to time it out.
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
-- than a strongest-move heuristic, still not a full TrainerAI port.
local AUTO_STATUS_PRI = {
  [32] = 4, -- SLEEP_EFFECT
  [67] = 3, -- PARALYZE_EFFECT
  [66] = 2, -- POISON_EFFECT
  [49] = 1, -- CONFUSION_EFFECT
  [84] = 1, -- LEECH_SEED_EFFECT
}
-- Self-boost / screen / substitute. Values are stage keys, or true for flags.
local AUTO_SETUP = {
  [10] = "atk", [11] = "def", [12] = "spe", [13] = "spa",
  [50] = "atk", [51] = "def", [52] = "spe", [53] = "spa",
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
  { id = "X_SPEED", stat = "spe" },
  { id = "X_SPECIAL", stat = "spa" },
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
          if m.pp > 0 and m.power > 0 then
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
    and mon.stages.spe <= 0 and mon.stages.spa <= 0
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

  if mon.charging then
    local c = mon.charging
    return { action = "fight", move = c.moveIndex, target = c.targetSlot }
  end
  if mon.mustRecharge or mon.bide then
    local locked = self:_lockedChoice(fighter, mon)
    if locked then return locked end
  end
  -- A wrapped monster fights on but cannot switch (`_normaliseChoice`), so
  -- none of the retreats below is open to it.
  local canSwitch = not (mon.trapped and mon.trapped.turns > 0)
  if mon.thrashing and mon.thrashing.turns > 0 then
    local foe = self:_autoTarget(fighter)
    if foe then
      return {
        action = "fight",
        move = mon.thrashing.moveIndex,
        target = foe.slot,
      }
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
      if mon.moves[i].pp > 0 then pick = i; break end
    end
    return { action = "fight", move = pick, target = foe.slot }
  end

  local itemPick = self:_autoItemChoice(fighter, mon)
  if itemPick then return itemPick end

  local foeBoosted = (defender.stages.atk or 0) >= 2
    or (defender.stages.def or 0) >= 2
    or (defender.stages.spe or 0) >= 2
    or (defender.stages.spa or 0) >= 2
    or defender.focusEnergy
  local foeSub = (defender.substitute or 0) > 0
  local weSlower = self:_speedOf(fighter, mon) < self:_speedOf(foe, defender)

  -- Critical HP: SE retreat (heal already tried via bag).
  if canSwitch and mon.hp * 4 <= mon.maxHp then
    local se = self:_bestSeBench(fighter, defender)
    if se then return { action = "switch", slot = se } end
  end

  -- Behind a boosted / subbed foe at mid-low HP: prefer an SE bench mon.
  if canSwitch and (foeBoosted or foeSub) and mon.hp * 2 <= mon.maxHp then
    local se = self:_bestSeBench(fighter, defender)
    if se then return { action = "switch", slot = se } end
  end

  local function disabled(i)
    return mon.disable and mon.disable.turns > 0 and mon.disable.moveIndex == i
  end

  local pick, pickEff, pickPow = nil, -1, -1
  for i = 1, #mon.moves do
    local m = mon.moves[i]
    if m.pp > 0 and m.power > 0 and not disabled(i) then
      local eff = self:_effectivenessProduct(m.type, defender)
      if not pick or eff > pickEff
         or (eff == pickEff and m.power > pickPow)
         or (eff == pickEff and m.power == pickPow and i < pick) then
        pick, pickEff, pickPow = i, eff, m.power
      end
    end
  end

  if canSwitch and ((not pick) or pickEff == 0) then
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
      if m.pp > 0 and not disabled(i) and m.power == 0 then
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
    and mon.stages.spe <= 0 and mon.stages.spa <= 0
  -- Do not set up into a boosted foe, behind a substitute, or while slower
  -- at mid-low HP — hit or switch instead.
  if stagesFlat and not mon.focusEnergy and not foeBoosted and not foeSub
     and not (weSlower and mon.hp * 2 <= mon.maxHp) then
    local setupPick = nil
    for i = 1, #mon.moves do
      local m = mon.moves[i]
      if m.pp > 0 and not disabled(i) and m.power == 0 then
        local kind = AUTO_SETUP[m.effect]
        -- A screen already up on this side would only fail (BattleCommand_
        -- Screen's second cast), so it is no setup at all.
        if (m.effect == 64 and self.screens[fighter.side].lightScreen > 0)
           or (m.effect == 65 and self.screens[fighter.side].reflect > 0) then
          kind = nil
        end
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
      if m.pp > 0 and not disabled(i) then
        if not pick or m.power > pickPow
           or (m.power == pickPow and i < pick) then
          pick, pickPow = i, m.power
        end
      end
    end
  end

  pick = pick or 1
  -- An empty sheet is Struggle, not a hang: `_useMove` treats allPpEmpty
  -- (including `#moves == 0`) as the synthetic STRUGGLE even with no slot.
  return { action = "fight", move = pick, target = foe.slot }
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
    -- CheckPlayerLockedIn resets both SUBSTATUS_FLINCHED bits as the player
    -- is asked for a move (pokecrystal engine/battle/core.asm:581-604,
    -- pokegold the same), so a flinch landed on a monster that had already
    -- moved -- King's Rock asks nobody whether the target went first -- dies
    -- here instead of costing it the next turn.  The cart's one exception:
    -- the check returns before the reset while the player's monster must
    -- recharge.  "The player" is a `badgeRules` seat, and there the skip is
    -- kept per seat for its own fielded monster, as the Gen 1 twin keeps
    -- pokered's; the enemy's bit the skip would also spare is never set at
    -- that point (the move that left the player recharging was Hyper Beam,
    -- which runs no `kingsrock` and flinches nothing).  A link fight has no
    -- single player, so there the reset is unconditional.  The flag a skip
    -- keeps is never read: CheckTurn asks about recharging before flinching,
    -- and the next turn's reset takes it.
    local mon = activeMon(fighter)
    local kept = nil
    if fighter.badgeRules and mon and mon.mustRecharge then kept = mon end
    for i = 1, #fighter.mons do
      if fighter.mons[i] ~= kept then fighter.mons[i].flinch = false end
      -- BattleTurn's top clears wPlayerJustGotFrozen / wEnemyJustGotFrozen.
      fighter.mons[i].justFrozen = nil
    end
  end
  -- HandleBerserkGene, at the head of BattleTurn's loop -- before the menu,
  -- so its lines come before the `turn` that opens it.
  self:_berserkGene()
  self.deadline = (self.choiceTimeout > 0) and (self.now + self.choiceTimeout) or nil
  -- Before the window opens: a player deciding this turn is looking at the
  -- rosters, and anything a status or a bench potion moved last turn has to be
  -- on them by the time the menu is up.
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
--
-- Ported from the Gen 1 twin unchanged: the pacing complaint it answers is
-- about the *referee's* turn structure, which both generations share.

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
  -- The other window a player answers from, and the same reason.
  self:_syncTeams()
  for _, fighter in ipairs(self.fighters) do
    if self:_owes(fighter) then
      self:_emit("turn", { amount = self.turn, slot = fighter.slot })
    end
  end
end

-- Every replacement is in: field them, give them this turn's between-turn
-- held items, then open the turn they were owed for.
--
-- On the cart a monster that faints mid-turn is replaced at once (HandleEnemy
-- MonFaint / HandlePlayerMonFaint, from the faint checks after each move and
-- in HandleBetweenTurnEffects' first block), so its successor is on the field
-- for `.NoMoreFaintingConditions`: Leftovers, Mysteryberry, Defrost, the
-- stat-boosting and the healing items (engine/battle/core.asm:276-286).  This
-- referee asks for the successor after the turn instead (the replace phase),
-- so those routines run here for the seats that were just filled -- and only
-- them, the rest of the field already had theirs.  Safeguard and the screens
-- are a side's and ticked already.
function Battle:_closeReplace()
  local filled = {}
  for _, fighter in ipairs(self.fighters) do
    local choice = fighter.choice
    if fighter.mustReplace and choice and choice.action == "switch" then
      filled[fighter] = true
    end
  end
  self:_resolveSwitches()
  self:_heldLeftovers(filled)
  self:_heldMysteryberry(filled)
  self:_heldDefrost(filled)
  self:_heldStatBoosts(filled)
  self:_heldHealing(filled)
  self.turn = self.turn + 1
  self:_openTurn()
end

-- The battle stat a hit or the turn order reads: wBattleMonStats as the cart
-- last left it (Effects.storedStat -- CalcPlayerStats's stage, badge, status
-- unless a switch-in, Transform or a level-up left another order standing),
-- with the seat's own badges -- nil wherever the cart would not have boosted
-- (BADGE_MODES).
function Battle:_battleStat(fighter, mon, key)
  return Effects.storedStat(mon, key, fighter.badges)
end

-- The battle stats a monster comes onto the field with, from its unmodified
-- stats and the levels it brings (none, at a send-out): InitBattleMon, the
-- player's -- the status penalty and THEN the badge boost (engine/battle/
-- core.asm:3904-3906), a link fight's foe the same with no badge
-- (InitEnemyMon) -- or, for the computer's seat outside a link fight,
-- LoadEnemyMon's: the party stats with no status penalty at all, until its
-- next rebuild (docs/bugs_and_glitches.md, "PRZ and BRN stat reductions don't
-- apply to switched Pokemon").
function Battle:_switchInStats(fighter, mon)
  local order = isComputerSeat(self.mode, fighter) and "load" or "init"
  Effects.snapStats(mon, fighter.badges, Effects.calcStats(mon, fighter.badges, order))
end

function Battle:_speedOf(fighter, mon)
  return self:_battleStat(fighter, mon, "spe")
end

-- The bracket an action moves in: the selected move's (Effects.movePriority),
-- the move `_useMove` will resolve to -- a lock-in's (`_lockedMove`, a called
-- charge's release included, as GetMovePriority reads wCurPlayerMove), then
-- Struggle's when every slot is empty -- and the slot's own otherwise, so a
-- Metronome moves at Metronome's priority whatever it calls.  A recharging
-- seat's is the move that left it recharging (`rechargeMove`, its
-- wCurPlayerMove), and a Bide's BIDE's (`_lockedMove`).
function Battle:_priorityOf(fighter, mon)
  local choice = fighter.choice
  if choice and choice.recharge then
    return Effects.movePriority(mon.rechargeMove)
  end
  local locked = self:_lockedMove(fighter, mon)
  if locked then return Effects.movePriority(locked) end
  if allPpEmpty(mon) then return Effects.movePriority(STRUGGLE) end
  return Effects.movePriority(mon.moves[choice and choice.move or 0])
end

-- Whether the screen that guards against this kind of hit is up on `side`.
function Battle:_screenUp(side, isSpecial)
  local screens = self.screens[side]
  if not screens then return false end
  if isSpecial then return screens.lightScreen > 0 end
  return screens.reflect > 0
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

-- The registry id of chart index `typeIndex` (`typeIds`), or nil when the
-- ruleset named none or this index is past its end.
function Battle:_typeIdOf(typeIndex)
  local ids = self.typeIds
  if not ids then return nil end
  return ids[int(typeIndex, -1) + 1] or nil
end

local function hasType(mon, typeId)
  for i = 1, #mon.types do
    if mon.types[i] == typeId then return true end
  end
  return false
end

-- ------------------------------------------------------------------
-- held items (Items.lua holds the rules; these are the cart's call sites)
-- ------------------------------------------------------------------

-- K6: TruncateHL_BC folds once in a link battle on either cart, and once in
-- every battle on Gold / Silver, whose routine has no loop (pokegold
-- engine/battle/effect_commands.asm:2625); only Crystal outside a link battle
-- loops until both values fit.
function Battle:_onePassTruncate()
  return M.LINK_MODES[self.mode] == true or self.family ~= "crystal"
end

-- Which of this seat's party a monster is, 1-based -- by identity, because a
-- monster an action just felled has already left `fighter.active`.
function Battle:_partyIndex(fighter, mon)
  for i = 1, #fighter.mons do
    if fighter.mons[i] == mon then return i end
  end
  return nil
end

-- The `held` event (contract K3): whose item acted, which item, and whether
-- the monster still holds it (1) or holds nothing now (0).  The caller says
-- the cart's sentence right after it.
function Battle:_emitHeld(fighter, mon, itemId, amount)
  local index = self:_partyIndex(fighter, mon)
  self:_emit("held", {
    slot = fighter.slot, side = fighter.side,
    mon = index and (index - 1) or nil,
    text = itemId, amount = amount,
  })
end

-- The registry id of a move's type, as DamageCalc's type-boost scan reads
-- BATTLE_VARS_MOVE_TYPE: Struggle's row says NORMAL (`STRUGGLE.typeId`).
function Battle:_moveTypeId(move)
  if type(move) ~= "table" then return nil end
  return move.typeId or self:_typeIdOf(move.type)
end

-- The attacker's type-boost item for this move, as Damage.compute's
-- `itemBoostPercent` (nil when it holds none, or one for another type).
function Battle:_typeBoostOf(mon, move)
  return Items.typeBoostPercent(mon, self:_moveTypeId(move))
end

-- wBattleMonSpecies: what BattleCommand_Critical's Lucky Punch / Stick check
-- reads, which Transform rewrites (Effects' TRANSFORM_EFFECT records it).
function Battle:_battleSpecies(mon)
  if mon.transformed then return mon.transformSpecies end
  return mon.speciesId
end

-- HandleBerserkGene (pokecrystal engine/battle/core.asm:348-423, pokegold the
-- same), player then enemy -- every seat in field order.  Keyed on the item ID
-- (`sub BERSERK_GENE`).  The item is gone first, then the monster is confused
-- WITHOUT a count being written (the documented bug: it inherits whatever this
-- field position's last confusion left -- `fighter.confuseCount` -- or, from 0,
-- wraps to 256 checks), its Attack goes up two stages (AttackUp2, which says
-- nothing when Attack is already at +6), and only a monster that was not
-- confused already is told it became confused.
function Battle:_berserkGene()
  for _, fighter in ipairs(self.fighters) do
    local mon = activeMon(fighter)
    if mon and mon.heldItem == Items.BERSERK_GENE then
      local name = Items.label(mon)
      local item = Items.take(mon)
      local wasConfused = mon.confusion > 0
      if not wasConfused then
        local count = int(fighter.confuseCount, 0)
        mon.confusion = (count > 0) and count or M.BERSERK_CONFUSION
      end
      self:_emitHeld(fighter, mon, item.heldItem, 0)
      self:_say(mon.species .. "'s " .. name .. " activated!")
      local before = Effects.clampStage(mon.stages.atk)
      local after = Effects.clampStage(before + 2)
      if after ~= before then
        mon.stages.atk = after
        Effects.dropSnap(mon)
        local text = mon.species .. "'s ATTACK rose"
        self:_say(text)
        self:_emit("stat", { slot = fighter.slot, side = fighter.side,
                             amount = after, stage = after, text = text })
      end
      if not wasConfused then
        local text = mon.species .. " became confused"
        self:_say(text)
        self:_emit("status", { slot = fighter.slot, side = fighter.side,
                               confused = 1, text = text })
      end
    end
  end
end

-- DetermineMoveOrder's `.equal_priority`, widened to a field.  The cart asks
-- only when two battlers share a bracket, and draws for a Quick Claw holder
-- whatever the Speeds say: one holder, one BattleRandom against its parameter;
-- both, the enemy's first (`.both_have_quick_claw`, non-link) and the player's
-- only if that one missed.  So here: in every bracket two or more actors share
-- -- brackets highest first -- the holders draw in that order, side b's seats
-- then side a's, each in field order, until one fires; the one that fired
-- moves first in its bracket and the rest keep their Speed order.  A bracket
-- with one actor, and an actor holding no claw, draws nothing.  `clawParam` is
-- set only by `_resolveFights`, so a ball throw never rolls.
function Battle:_quickClaws(actors)
  local counts, brackets = {}, {}
  for _, actor in ipairs(actors) do
    local p = actor.priority or 0
    if not counts[p] then counts[p] = 0; brackets[#brackets + 1] = p end
    counts[p] = counts[p] + 1
  end
  table.sort(brackets, function(x, y) return x > y end)
  for _, p in ipairs(brackets) do
    if counts[p] >= 2 then
      local holders = {}
      for _, actor in ipairs(actors) do
        if (actor.priority or 0) == p and actor.clawParam ~= nil then
          holders[#holders + 1] = actor
        end
      end
      table.sort(holders, function(x, y)
        local xs, ys = x.fighter.side == "b" and 0 or 1, y.fighter.side == "b" and 0 or 1
        if xs ~= ys then return xs < ys end
        return x.order < y.order
      end)
      for _, holder in ipairs(holders) do
        if Items.quickClawFires(holder.clawParam, self.rng:byte()) then
          holder.claw = true
          break
        end
      end
    end
  end
end

-- One hit's HP off the defender, through BattleCommand_ApplyDamage's Focus
-- Band arm (effect_commands.asm:2107-2195): a holder rolls BattleRandom
-- against the parameter on EVERY hit that reaches it -- lethal or not, through
-- a substitute or not -- and when the roll lands and the hit would take the
-- last of its HP, FalseSwipe leaves it one (the substitute quirk included: the
-- clamp reads the monster's HP, and the line is said either way).  Only a
-- clamp says anything; the band is never used up.
--
-- ApplyDamage's `.update_damage_taken` sits between the band and the HP: a
-- biding monster with no substitute of its own adds the hit's whole wCurDamage
-- -- the band's clamp applied, its HP not yet -- to the damage BIDE releases,
-- a 16-bit sum whose carry pins $ffff.  Only a move's hit gets here: a
-- residual, a recoil or a confusion self-hit is no ApplyDamage.
function Battle:_strike(fighter, mon, amount)
  local banded = false
  local effect, param = Items.effect(mon)
  if effect == Items.FOCUS_BAND and mon.hp > 0 then
    if self.rng:byte() < param then
      amount, banded = Items.focusBand(amount, mon.hp)
    end
  end
  if mon.bide and int(mon.substitute, 0) <= 0 then
    mon.bide.stored = min(Damage.WORD_MAX, mon.bide.stored + max(0, int(amount, 0)))
  end
  self:_damage(fighter, mon, amount, nil)
  if banded then
    self:_emitHeld(fighter, mon, mon.heldItem, 1)
    self:_say(mon.species .. " hung on with " .. Items.label(mon) .. "!")
  end
end

-- BattleCommand_Thief (engine/battle/move_effects/thief.asm, identical in
-- pokegold), both ways and in every mode: the cart's player branch steals from
-- a wild monster too (its link check only bars a wild fight over a cable), and
-- the enemy branch has no gate at all -- an item the computer takes is gone.
-- The user must hold nothing, the target must hold something, and Mail is
-- never taken (ItemIsMail).  Both branches then return on wEffectFailed, which
-- the script's `effectchance` (ahead of applydamage) sets when the target has
-- a substitute up (CheckSubstituteOpp, before any byte is drawn) or when
-- BattleRandom is not under the chance byte -- the 1/256 miss of a 100% move,
-- docs/bugs_and_glitches.md.  That byte is the side-chance byte `_useMove`
-- already draws for the hit, so the caller asks this only when it landed with
-- no substitute standing; nothing is drawn here.  The command sits after
-- applydamage and before checkfaint, so a foe the hit knocked out is still
-- robbed.
function Battle:_thief(fighter, mon, target, defender)
  if mon.heldItem or not defender.heldItem then return end
  if Items.isMail(defender) then return end
  local item = Items.take(defender)
  Items.give(mon, item)
  self:_emitHeld(target, defender, item.heldItem, 0)
  self:_emitHeld(fighter, mon, item.heldItem, 1)
  self:_say(mon.species .. " stole " .. Items.label(mon) .. " from its foe!")
end

-- BattleCommand_BuildOpponentRage (effect_commands.asm:2422-2449, pokegold
-- the same), in every damaging move script right after `checkfaint`: a target
-- still standing that is raging gains a step of rage -- the counter
-- BattleCommand_RageDamage multiplies its own Rage by -- and the cart says so.
-- A hit into its substitute counts (it did not miss); a missed or immune move
-- never gets here, and nothing else builds rage: no residual, no confusion
-- self-hit, no recoil.  At 255 the `inc a / ret z` leaves the counter where it
-- is and says nothing.
function Battle:_buildRage(defender)
  if defender.hp <= 0 or not defender.raging then return end
  if defender.rageCounter >= 255 then return end
  defender.rageCounter = defender.rageCounter + 1
  self:_say(defender.species .. "'s RAGE is building!")
end

-- BattleCommand_HeldFlinch, the `kingsrock` command at the end of the move
-- scripts Items.kingsRockMove lists: the attacker's HELD_FLINCH, a hit that
-- did not miss (every early return above is one), a target with no substitute
-- standing, and BattleRandom under the parameter -- then the target's
-- recharge is cancelled (EndRechargeOpp) and it flinches.  Nobody asks whether
-- the target already moved; the flag that lands on one that did is what the
-- next turn's reset clears (`_openTurn`).  A target the hit knocked out is out
-- of reach: checkfaint ends the script before `kingsrock` runs.  The cart
-- prints nothing.
function Battle:_kingsRock(mon, move, effectId, defender)
  local effect, param = Items.effect(mon)
  if effect ~= Items.FLINCH then return end
  if not Items.kingsRockMove(effectId, Effects.moveKey(move)) then return end
  if defender.hp <= 0 or (defender.substitute or 0) > 0 then return end
  if self.rng:byte() < param then
    defender.flinch = true
    defender.mustRecharge = false
  end
end

-- UseHeldStatusHealingItem (core.asm:4383-4437): a status berry whose cure
-- covers the status the monster has takes it off -- MiracleBerry (ALL_STATUS)
-- confusion too -- and is eaten.  Asked right after a status lands (the
-- `farcall` at the end of every status-inflicting command) and again between
-- turns (HandleHealingItems).  Returns true when it acted.
function Battle:_statusBerry(fighter, mon)
  local effect = Items.effect(mon)
  local cures = effect and Items.STATUS_CURE[effect]
  if not cures or not mon.status or not cures[mon.status] then return false end
  local name = Items.label(mon)
  local text = mon.species .. " recovered using a " .. name .. "!"
  mon.status, mon.statusTurns = nil, 0
  self:_emit("status", { slot = fighter.slot, side = fighter.side, text = text })
  if effect == Items.HEAL_STATUS and mon.confusion > 0 then
    mon.confusion = 0
    self:_emit("status", { slot = fighter.slot, side = fighter.side,
                           confused = 0, text = text })
  end
  local item = Items.take(mon)
  self:_emitHeld(fighter, mon, item.heldItem, 0)
  self:_say(text)
  return true
end

-- UseConfusionHealingItem (core.asm:4439-4478): Bitter Berry, or MiracleBerry,
-- on a confused monster.  Asked right after confusion lands (BattleCommand_
-- FinishConfusingTarget) and between turns.
function Battle:_confusionBerry(fighter, mon)
  if not (mon.confusion > 0) then return false end
  local effect = Items.effect(mon)
  if effect ~= Items.HEAL_CONFUSION and effect ~= Items.HEAL_STATUS then return false end
  local text = "A " .. Items.label(mon) .. " rid " .. mon.species .. " of its confusion."
  mon.confusion = 0
  self:_emit("status", { slot = fighter.slot, side = fighter.side,
                         confused = 0, text = text })
  local item = Items.take(mon)
  self:_emitHeld(fighter, mon, item.heldItem, 0)
  self:_say(text)
  return true
end

-- HandleHPHealingItem (core.asm:4272-4353): Berry, Gold Berry, Berry Juice
-- (HELD_BERRY) restore their parameter once the holder is under half its
-- maximum -- strictly: at exactly half the cart keeps the berry -- and are
-- eaten (ConsumeHeldItem).
function Battle:_hpBerry(fighter, mon)
  local effect, param = Items.effect(mon)
  if effect ~= Items.BERRY or not Items.berryWants(mon.hp, mon.maxHp) then return false end
  local name = Items.label(mon)
  self:_heal(fighter, mon, param)
  local item = Items.take(mon)
  self:_emitHeld(fighter, mon, item.heldItem, 0)
  self:_say(mon.species .. " recovered using a " .. name .. "!")
  return true
end

-- The between-turn held-item routines below take `only`, a set of seats:
-- nil is the whole field, a set is the successors `_closeReplace` fielded.
local function inSet(only, fighter)
  return only == nil or only[fighter] == true
end

-- HandleLeftovers (core.asm:1279-1326): player then enemy, a sixteenth of the
-- maximum to a holder that is not already full.  Kept.
function Battle:_heldLeftovers(only)
  for _, fighter in ipairs(self.fighters) do
    local mon = inSet(only, fighter) and activeMon(fighter)
    if mon and Items.holds(mon, Items.LEFTOVERS) and mon.hp < mon.maxHp then
      self:_heal(fighter, mon, Items.sixteenth(mon.maxHp))
      self:_emitHeld(fighter, mon, mon.heldItem, 1)
      self:_say(mon.species .. " recovered with " .. Items.label(mon) .. ".")
    end
  end
end

-- HandleMysteryberry (core.asm:1328-1464): player then enemy.  The first move
-- slot with no PP gets 5 back (1 for Sketch, the cart's "lousy hack") and the
-- berry is eaten; a holder with PP in every slot keeps it.  The cart scans the
-- PARTY moves and PP (wPartyMon1PP / wOTPartyMon1PP / wWildMonPP), and only
-- tops up the battle copy when the monster is not transformed.  A transformed
-- monster's moves are the battle struct's copies -- the PP it spends comes off
-- them, never off the party (BattleCommand_DoTurn's SUBSTATUS_TRANSFORMED
-- check) -- so for one the scan is of the party list Transform put aside
-- (`preTransform.moves`), the restore lands there, and the copies are not
-- touched; its owner is told once Transform is undone (`_resolveSwitches`).
-- A sheet that arrived transformed carries no party list: there the routine
-- is skipped and the berry kept.
function Battle:_heldMysteryberry(only)
  for _, fighter in ipairs(self.fighters) do
    local mon = inSet(only, fighter) and activeMon(fighter)
    local saved = mon and mon.transformed and mon.preTransform or nil
    if mon and (saved or not mon.transformed) and Items.holds(mon, Items.RESTORE_PP) then
      local party = saved and saved.moves or mon.moves
      local slot = nil
      for i = 1, #party do
        if party[i].pp <= 0 then slot = i; break end
      end
      if slot then
        local move = party[slot]
        move.pp = move.pp + ((Effects.moveKey(move) == "SKETCH") and 1 or 5)
        if int(move.maxPp, 0) < move.pp then move.maxPp = move.pp end
        if saved then
          saved.ppTouched = true
        else
          self:_emitMoves(fighter, mon, fighter.active)
        end
        local name = Items.label(mon)
        local item = Items.take(mon)
        self:_emitHeld(fighter, mon, item.heldItem, 0)
        self:_say(mon.species .. " recovered PP using " .. name .. ".")
      end
    end
  end
end

-- HandleStatBoostingHeldItems (core.asm:4480-4548): player then enemy, a
-- HELD_<STAT>_UP item raises its stat one stage and is used up -- unless the
-- stat is already as high as it goes, when nothing happens and the item stays.
function Battle:_heldStatBoosts(only)
  for _, fighter in ipairs(self.fighters) do
    local mon = inSet(only, fighter) and activeMon(fighter)
    local effect = mon and Items.effect(mon)
    local stat = effect and Items.STAT_UP[effect]
    if stat then
      local before = Effects.clampStage(mon.stages[stat])
      local after = Effects.clampStage(before + 1)
      if after ~= before then
        local name = Items.label(mon)
        local item = Items.take(mon)
        mon.stages[stat] = after
        Effects.dropSnap(mon)
        self:_emitHeld(fighter, mon, item.heldItem, 0)
        self:_say(mon.species .. "'s " .. name .. " activated!")
        local text = mon.species .. "'s " .. (Effects.STAT_LABELS[stat] or stat) .. " rose"
        self:_say(text)
        self:_emit("stat", { slot = fighter.slot, side = fighter.side,
                             amount = after, stage = after, text = text })
      end
    end
  end
end

-- HandleHealingItems (core.asm:4249-4270).  Each of its three routines works on
-- the battler OPPOSITE hBattleTurn, and the non-link order sets the player's
-- turn first -- so the enemy's items go first here: side b's seats, then side
-- a's, each asked HP berry, then status berry, then confusion berry.
function Battle:_heldHealing(only)
  for _, side in ipairs({ "b", "a" }) do
    for _, fighter in ipairs(self.bySide[side]) do
      local mon = inSet(only, fighter) and activeMon(fighter)
      if mon then
        self:_hpBerry(fighter, mon)
        self:_statusBerry(fighter, mon)
        self:_confusionBerry(fighter, mon)
      end
    end
  end
end

-- ------------------------------------------------------------------
-- obedience (pokecrystal BattleCommand_CheckObedience, effect_commands.asm:
-- 631-938; pokegold's is the same routine without the Battle Tower exit)
-- ------------------------------------------------------------------
--
-- Asked by `_useMove` after the gates, for the move the monster chose.  Only
-- on a `badgeRules` seat (the cart returns for the enemy's turn and in a link
-- battle), only for a `traded` monster (its OT id is not the player's), and
-- never for a charged move's release (CheckUserIsCharging), a rampage's
-- continuation (CheckRampage skips past the command) or a Bide's release
-- (BattleCommand_StoreEnergy, the command ahead of it in Bide's script, ends
-- with `ld b, unleashenergy_command / jp SkipToBattleCommand`; a storing turn
-- ends in EndMoveEffect before it -- the referee's forced skip -- so only
-- Bide's first use is ever checked).  Returns nil when the
-- monster obeys, "stop" when the action is spent, or the 1-based slot of the
-- move it uses instead.  Every draw is the cart's, in its order, and each is
-- drawn only when reached: a monster at or under its cap draws nothing.

-- `.rand1` / `.rand2`: BattleRandom (nibble-swapped for `.rand1`) until it is
-- under the cap plus the level.
function Battle:_obeyDraw(span, swapped)
  local r = 0
  for _ = 1, M.REDRAW_LIMIT do
    r = self.rng:byte()
    if swapped then r = Items.swap(r) end
    if r < span then return r end
  end
  return r % span
end

-- `.UseInstead`: no other move when the monster knows one, when any move is
-- disabled, or when the chosen move holds every PP the monster has left;
-- otherwise BattleRandom & 3 until it names another known move with PP.
function Battle:_obeyInstead(mon, selected)
  if #mon.moves <= 1 then return nil end
  if mon.disable and mon.disable.turns > 0 then return nil end
  local total = 0
  for i = 1, #mon.moves do total = total + max(0, int(mon.moves[i].pp, 0)) end
  local chosen = mon.moves[selected or 0]
  if (chosen and chosen.pp or 0) == total then return nil end
  local rows = min(4, #mon.moves)
  for _ = 1, M.REDRAW_LIMIT do
    local r = self.rng:byte() % 4
    if r < rows and (r + 1) ~= selected and mon.moves[r + 1].pp > 0 then return r + 1 end
  end
  return nil
end

-- `.EndDisobedience`: wLastPlayerMove and wLastPlayerCounterMove -- the move
-- a foe's Mirror Move would copy -- are forgotten.
function Battle:_disobeyed(fighter, mon)
  mon.lastMoveIndex = 0
  mon.lastCounterMove = nil
  return "stop"
end

-- `.DoNothing`: BattleRandom & 3 picks the line.
local LOAF_LINES = { " is loafing around.", " won't obey!", " turned away!", " ignored orders!" }
M.LOAF_LINES = LOAF_LINES

function Battle:_loaf(fighter, mon)
  self:_say(mon.species .. LOAF_LINES[(self.rng:byte() % 4) + 1])
  return self:_disobeyed(fighter, mon)
end

function Battle:_obey(fighter, mon, move)
  if not fighter.badgeRules or mon.traded ~= true then return nil end
  if fighter.choice and fighter.choice.bideRelease then return nil end
  if mon.charging and Effects.isCharge(mon.charging.effect) then return nil end
  if mon.thrashing then return nil end
  local cap = Items.obedienceCap(fighter.badges)
  local level = mon.level
  if cap >= level then return nil end
  local span = min(255, cap + level)
  if self:_obeyDraw(span, true) < cap then return nil end

  -- IgnoreSleepOnly: Snore or Sleep Talk, chosen while asleep.  The cart's
  -- line has its one-glyph ellipsis; the wire's alphabet (Wire.text) has no
  -- such glyph, so it is spelled with three dots.
  if mon.status == "sleep" and Items.SLEEP_BYPASS[Effects.moveKey(move)] then
    self:_say(mon.species .. " ignored orders...sleeping!")
    return "stop"
  end

  if self:_obeyDraw(span, false) < cap then
    local slot = self:_obeyInstead(mon, fighter.choice and fighter.choice.move)
    if slot then return slot end
    return self:_loaf(fighter, mon)
  end

  local over = level - cap
  local r = Items.swap(self.rng:byte())
  if r < over then
    -- `.Nap`: the status byte is overwritten, whatever it held.
    local turns = 0
    for _ = 1, M.REDRAW_LIMIT do
      turns = Items.napTurns(self.rng:byte())
      if turns ~= 0 then break end
    end
    if turns == 0 then turns = 1 end
    Effects.setStatusOn(mon, fighter, "sleep")
    mon.statusTurns = turns
    local text = mon.species .. " began to nap!"
    self:_say(text)
    self:_emit("status", { slot = fighter.slot, side = fighter.side,
                           status = M.STATUS_TO_WIRE.sleep, text = text })
    return self:_disobeyed(fighter, mon)
  end
  if r - over >= over then return self:_loaf(fighter, mon) end

  -- "won't obey!" and HitConfusion: the same self-hit the confusion gate
  -- deals (`_selfHitStats`, the selected move's Explosion halving and
  -- type-boost item included), past the monster's own substitute.
  self:_say(mon.species .. " won't obey!")
  local attack, defense = self:_selfHitStats(fighter, mon, move)
  local damage = Status.selfHitDamage({
    level = mon.level, attack = attack, defense = defense,
    itemBoostPercent = self:_typeBoostOf(mon, move),
  })
  self:_say(mon.species .. " hurt itself in confusion")
  self:_damage(fighter, mon, damage, nil, true)
  return self:_disobeyed(fighter, mon)
end

-- ParsePlayerAction / ParseEnemyAction (pokecrystal engine/battle/core.asm:
-- 606-700 and the enemy's `.raging` / ResetVarsForSubstatusRage, :5795-5934;
-- pokegold the same), as the turn's actions are read and before any of them
-- runs: SUBSTATUS_RAGE and the rage counter survive only on a seat whose
-- chosen move is Rage again.  Switching, an item, running, a lock-in
-- (CheckPlayerLockedIn's recharge / charge / rampage, a Bide, the referee's
-- other forced fills) and any other move -- Struggle, Metronome, Mirror Move
-- included, since UpdateMoveData reads the selected move -- end both.
function Battle:_resetRage()
  for _, fighter in ipairs(self.fighters) do
    local mon = activeMon(fighter)
    if mon and (mon.raging or mon.rageCounter > 0) then
      local choice = fighter.choice
      local keep = false
      if choice and choice.action == "fight" and not fighter.forced
         and not allPpEmpty(mon) then
        local move = mon.moves[choice.move]
        keep = move ~= nil and Effects.isRage(move.effect)
      end
      if not keep then
        mon.raging = false
        mon.rageCounter = 0
      end
    end
  end
end

function Battle:_resolveTurn()
  self.phase = "resolving"
  -- Armed for the rare case resolution does not leave this phase in the same
  -- call -- a throw mid-resolve used to leave the field wedged forever, and
  -- Hub.receive now contains those throws so the clock has to finish the job.
  self.resolveDeadline = (self.resolveTimeout > 0)
    and (self.now + self.resolveTimeout) or nil

  self:_resetRage()
  if self:_resolveRuns() then return end
  self:_resolveSwitches()
  self:_resolveItems()
  self:_resolveFights()
  if not self.result then self:_resolveResiduals() end
  -- The residual batch settles the same way an action's does: every flag is off
  -- before the first share is counted.  Unconditional, because a queue nobody
  -- drains is exp that silently never happened.
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

-- Fleeing is a concession in 1v1/coop_pvp, a wild escape in *wild modes,
-- and a trainer refusal (no finish) everywhere else; see Effects.runEndsBattle.
function Battle:_resolveRuns()
  local running = {}
  for _, fighter in ipairs(self.fighters) do
    if fighter.choice and fighter.choice.action == "run" then
      running[#running + 1] = fighter
    end
  end
  if #running == 0 then return false end

  if not Effects.runEndsBattle(self.mode) then
    self:_say("No! There's no running from a trainer battle!")
    return false
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

-- Transform undone (BattleCommand_Transform never wrote the party, and a
-- send-out reloads the battle struct from there -- InitBattleMon): what the
-- monster was (`preTransform`, Effects.applyPrimary) comes back -- its
-- unmodified stats, types, moves with the PP the party kept (which
-- HandleMysteryberry may have raised meanwhile) and DVs -- and its battle
-- species.  Returns whether a berry restored party PP while it was
-- transformed, which its owner is told once the overlay is gone.
function Battle:_undoTransform(mon)
  local saved = mon.preTransform
  mon.transformed = false
  mon.transformSpecies = nil
  if not saved then return false end
  mon.preTransform = nil
  mon.stats = saved.stats
  mon.types = saved.types
  mon.moves = saved.moves
  mon.dvs = saved.dvs
  Effects.dropSnap(mon)
  return saved.ppTouched == true
end

-- What NewBattleMonStatus / NewEnemyMonStatus clear (engine/battle/
-- core.asm:4082-4108, 3600-3621) that this referee keeps on the monster
-- rather than on the field position, done to the one leaving as well as to
-- the one arriving: the whole substatus -- Transform (`_undoTransform`),
-- SUBSTATUS_CONFUSED (the switch ends a confusion; the position's
-- wPlayerConfuseCount stays for Berserk Gene), SUBSTATUS_TOXIC (badly
-- poisoned is plain poison again: the status byte keeps PSN), and the
-- lock-on a foe put on it.  Returns `_undoTransform`'s answer.
function Battle:_clearSubstatus(mon)
  mon.confusion = 0
  if mon.status == "toxic" then mon.status = "poison" end
  mon.lockOn = nil
  mon.justFrozen = nil
  return self:_undoTransform(mon)
end

function Battle:_resolveSwitches()
  for _, fighter in ipairs(self.fighters) do
    local choice = fighter.choice
    if choice and choice.action == "switch" then
      local mon = fighter.mons[choice.slot]
      if mon and mon.hp > 0 then
        local outIndex = fighter.active
        local outgoing = outIndex and fighter.mons[outIndex] or nil
        local touched = false
        if outgoing and outgoing ~= mon then touched = self:_clearSubstatus(outgoing) end
        fighter.active = choice.slot
        fighter.mustReplace = nil
        -- The seat's monster changed: its own participation set resets and the
        -- standing opposition re-marks into it, while the incoming monster
        -- joins the sets of the foes it is now in against.
        self:_refield(fighter)
        -- A send-out brings no stage with it (ResetPlayerStatLevels): the
        -- levels belong to the side's field position on the cart, and a
        -- monster coming back in must not find the ones it left with.
        Effects.resetStages(mon)
        mon.charging = nil
        mon.invulnerable = false
        mon.thrashing = nil
        mon.raging = false
        mon.rageCounter = 0
        mon.trapped = nil
        mon.bide = nil
        mon.substitute = 0
        mon.mist = false
        mon.focusEnergy = false
        mon.xAccuracy = false
        mon.leechSeed = nil
        mon.disable = nil
        mon.minimized = false
        self:_clearSubstatus(mon)
        -- NewBattleMonStatus / NewEnemyMonStatus: a send-out clears BOTH
        -- sides' last counter moves, so neither seat's MIRROR MOVE copies a
        -- move from before it.
        mon.lastCounterMove = nil
        self:_forgetFoesLastMoves(fighter)
        self:_clearTrapsFrom(fighter.slot)
        self:_switchInStats(fighter, mon)
        -- `mon` is the index the referee just fielded -- `choice.slot`, already
        -- normalised to a party position by `_normaliseChoice`.  This is the
        -- one that matters most: a forced post-faint replacement lands here
        -- too, so without it a seat holding two of a species re-fields the
        -- fallen copy on the client while the referee holds the living one.
        self:_emit("switch", { slot = fighter.slot, side = fighter.side,
                               text = mon.species, speciesId = mon.speciesId,
                               level = mon.level, mon = choice.slot - 1 })
        self:_emit("send", { slot = fighter.slot, side = fighter.side,
                             hp = mon.hp, maxHp = mon.maxHp,
                             text = mon.species,
                             speciesId = mon.speciesId, level = mon.level,
                             mon = choice.slot - 1,
                             status = mon.status and M.STATUS_TO_WIRE[mon.status] or nil,
                           confused = (mon.confusion and mon.confusion > 0) and 1 or nil })
        -- The party PP a Mysteryberry restored under Transform, now that the
        -- overlay it could not be written through is gone (`_heldMysteryberry`).
        if touched then self:_emitMoves(fighter, outgoing, outIndex) end
      end
    end
  end
end

-- A send-out or a faint at `slot` ends the wraps its monster held: the cart
-- clears both wrap counts at every send-out (NewBattleMonStatus /
-- NewEnemyMonStatus, SendOutPlayerMon), so a monster whose trapper left the
-- field is free.  A monster at `slot` that was itself wrapped is gone, and its
-- own record went with it.
function Battle:_clearTrapsFrom(slot)
  for _, fighter in ipairs(self.fighters) do
    local mon = activeMon(fighter)
    if mon and mon.trapped and mon.trapped.fromSlot == slot then
      mon.trapped = nil
    end
  end
end

-- The other half of that send-out: the seats across the field forget what
-- they last used (wLastEnemyCounterMove / wLastPlayerCounterMove).
function Battle:_forgetFoesLastMoves(fighter)
  for _, foe in ipairs(self:_foes(fighter)) do
    local mon = activeMon(foe)
    if mon then mon.lastCounterMove = nil end
  end
end

function Battle:_resolveItems()
  -- Non-ball items keep Gen1 array order (heals, dolls, vitamins, …). Balls
  -- resolve in a second pass ordered by active-mon speed (fight tie policy),
  -- so the faster thrower spends first and a successful catch aborts the rest.
  for _, fighter in ipairs(self.fighters) do
    if self.result then return end
    local choice = fighter.choice
    if choice and choice.action == "item" then
      local effect = Effects.itemEffect(choice.item)
      if not (effect and effect.ball) then
        self:_resolveOneItem(fighter)
      end
    end
  end

  local balls = {}
  for _, fighter in ipairs(self.fighters) do
    local choice = fighter.choice
    if choice and choice.action == "item" then
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
  end
end

-- Sort actors by priority bracket (desc), then a Quick Claw that fired, then
-- active-mon speed (desc), then field order; tied groups flip on one RNG byte
-- >= TIE_BREAK_ROLL.  Shared by fights and ball throws -- a ball carries no
-- `priority` and no `clawParam`, so every thrower sits in one bracket, rolls
-- no claw, and the order is Speed's, as it always was.
--
-- pokecrystal's DetermineMoveOrder for two battlers: CompareMovePriority,
-- then (`.equal_priority`) each side's Quick Claw roll, then the Speed
-- compare, then the coin flip.  A Quick Claw is a roll *inside* a bracket, so
-- it sits between the bracket key and the Speed key here, drawn before the
-- tie-break bytes (`_quickClaws`).
function Battle:_orderActors(actors)
  if #actors <= 1 then return end

  self:_quickClaws(actors)

  table.sort(actors, function(x, y)
    local xp, yp = x.priority or 0, y.priority or 0
    if xp ~= yp then return xp > yp end
    local xc, yc = x.claw and 1 or 0, y.claw and 1 or 0
    if xc ~= yc then return xc > yc end
    if x.speed ~= y.speed then return x.speed > y.speed end
    return x.order < y.order          -- field order: side a, then side b
  end)

  -- One byte per group of actors in one bracket, of one Quick Claw standing,
  -- at one Speed, spent only when the group is actually tied, so an ordinary
  -- turn between two different speeds costs no draw at all on either runtime.
  local i = 1
  while i <= #actors do
    local j = i
    while j < #actors and actors[j + 1].speed == actors[i].speed
          and (actors[j + 1].priority or 0) == (actors[i].priority or 0)
          and (actors[j + 1].claw and true or false) == (actors[i].claw and true or false) do
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
      end
    end
  end
  local itemEv = { slot = fighter.slot, side = fighter.side, text = choice.item }
  if vitaminApplied then itemEv.amount = 1 end
  self:_emit("item", itemEv)
  self:_say(fighter.name .. " used an item")
  -- Spend after the announce, win or fail (Gen1 bag stack). noConsume
  -- (Poké Flute) and seats with no bag sheet are left alone.
  if not (effect and effect.noConsume) then
    self:_spendBag(fighter, choice.item)
  end
  if not effect then
    self:_say("But it failed")
  elseif effect.ball then
    if not Effects.isWildMode(self.mode) then
      self:_say("But it failed")
    else
      -- Wild modes seat exactly one monster on side b, so "the first living
      -- foe" and "the only foe" are the same seat -- no aim to spread.
      local foe = self:_firstLivingFoe(fighter)
      local target = foe and activeMon(foe)
      if not target then
        self:_say("But it failed")
      else
        local caught, shakes = Effects.catchAttempt(choice.item, target, self.rng)
        -- Gen1 TossBallAnimation chain before the catch text (engine ballChain).
        self:_emitBallChain(fighter, choice.item, caught, shakes)
        if shakes and shakes > 0 and not caught then
          self:_say("The ball shook")
        end
        if caught then
          self:_say("Gotcha")
          local finish = self:_finish("win", self:_sidePlayers(fighter.side),
            self:_sidePlayers(fighter.side == "a" and "b" or "a"), "catch")
          local sheet = Effects.caughtSheet(target)
          if finish and sheet then finish.caught = sheet end
          if finish then finish.catcher = fighter.playerId end
          if fighter.side == M.BADGE_SIDE then self:_payDayOutcome(finish) end
        else
          self:_say("It broke free")
        end
      end
    end
  elseif effect.pokeDoll then
    if Effects.isWildMode(self.mode) then
      self:_say("The wild pokemon ran away")
      self:_finish("win", self:_sidePlayers(fighter.side),
        self:_sidePlayers(fighter.side == "a" and "b" or "a"), "run")
    else
      self:_say("But it failed")
    end
  elseif effect.vitamin then
    if not vitaminApplied then
      self:_say("But it failed")
    else
      local mon, result = vitaminMon, vitaminResult
      local label = ({
        hp = "HEALTH POINTS", atk = "ATTACK", def = "DEFENSE",
        spe = "SPEED", spa = "SP.ATK", spd = "SP.DEF",
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
          text = mon.species .. "'s " .. label .. " rose",
        })
      end
      self:_say(mon.species .. "'s " .. label .. " rose")
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
            text = mon.species .. " woke up",
          })
        end
      end
    end
    if woke then
      self:_say("All sleeping POKeMON woke up")
    else
      self:_say("Now, that's a catchy tune")
    end
  else
    local partyIdx = choice.slot or fighter.active
    local mon = fighter.mons[partyIdx]
    if not mon then
      self:_say("But it failed")
    elseif effect.activeOnly and partyIdx ~= fighter.active then
      self:_say("But it failed")
    elseif effect.faintedOnly and mon.hp > 0 then
      self:_say("But it failed")
    elseif mon.hp <= 0 and Effects.itemFailsOnFainted(effect) then
      self:_say("But it failed")
    else
      local applied = false
      if effect.xAccuracy then
        mon.xAccuracy = true
        self:_say(mon.species .. "'s hits will never miss")
        applied = true
      end
      if effect.focusEnergy then
        mon.focusEnergy = true
        self:_say(mon.species .. " is getting pumped")
        applied = true
      end
      if effect.mist then
        mon.mist = true
        self:_say(mon.species .. " is protected against stat changes")
        applied = true
      end
      if effect.stage then
        local stat = effect.stage.stat
        local before = Effects.clampStage(mon.stages[stat])
        if before >= Effects.STAGE_MAX then
          self:_say("Nothing happened")
        else
          local after = Effects.clampStage(before + int(effect.stage.delta, 1))
          mon.stages[stat] = after
          Effects.dropSnap(mon)
          local label = ({
            atk = "ATTACK", def = "DEFENSE", spe = "SPEED",
            spa = "SP.ATK", spd = "SP.DEF", acc = "ACCURACY", eva = "EVASION",
          })[stat] or "STAT"
          self:_say(mon.species .. "'s " .. label .. " rose")
          self:_emit("stat", {
            slot = fighter.slot, side = fighter.side,
            amount = after, stage = after,
            text = mon.species .. "'s " .. label .. " rose",
          })
        end
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
        self:_say(mon.species .. " was revived")
        applied = true
      end
      if effect.ppRestore then
        local move = mon.moves[choice.move]
        if not move then
          self:_say("But it failed")
        else
          local maxPp = max(int(move.maxPp, move.pp), move.pp, 1)
          local before = move.pp
          if effect.ppRestore == true then
            move.pp = maxPp
          else
            move.pp = min(maxPp, move.pp + int(effect.ppRestore, 0))
          end
          if move.pp > before then
            self:_say(mon.species .. "'s PP was restored")
            applied = true
            -- Fielded mon only: a bench Ether must not redraw FIGHT.
            if partyIdx == fighter.active then
              self:_emitMoves(fighter, mon, partyIdx)
            end
          else
            self:_say("But it failed")
          end
        end
      end
      if effect.ppRestoreAll then
        local any = false
        for i = 1, #(mon.moves or {}) do
          local move = mon.moves[i]
          if move then
            local maxPp = max(int(move.maxPp, move.pp), move.pp, 1)
            local before = move.pp
            if effect.ppRestoreAll == true then
              move.pp = maxPp
            else
              move.pp = min(maxPp, move.pp + int(effect.ppRestoreAll, 0))
            end
            if move.pp > before then any = true end
          end
        end
        if any then
          self:_say(mon.species .. "'s PP was restored")
          applied = true
          if partyIdx == fighter.active then
            self:_emitMoves(fighter, mon, partyIdx)
          end
        else
          self:_say("But it failed")
        end
      end
      local healed = false
      if effect.healFull then
        local before = mon.hp
        mon.hp = mon.maxHp
        if mon.hp > before then
          self:_emit("drain", {
            slot = fighter.slot, side = fighter.side,
            amount = mon.hp - before, hp = mon.hp,
          })
          healed = true
        end
      elseif effect.heal and effect.heal > 0 and mon.hp < mon.maxHp then
        self:_heal(fighter, mon, effect.heal)
        healed = true
      end
      local cleared = false
      local clearedConfusion = false
      if effect.clearAllStatus then
        if mon.status then
          mon.status, mon.statusTurns = nil, 0
          cleared = true
        end
        if mon.confusion and mon.confusion > 0 then
          mon.confusion = 0
          clearedConfusion = true
        end
      elseif effect.clearStatuses and mon.status
         and effect.clearStatuses[mon.status] then
        mon.status, mon.statusTurns = nil, 0
        cleared = true
      end
      if cleared then
        self:_emit("status", {
          slot = fighter.slot, side = fighter.side,
          text = mon.species .. " recovered",
        })
      end
      if clearedConfusion then
        self:_emit("status", {
          slot = fighter.slot, side = fighter.side, confused = 0,
          text = mon.species .. " recovered",
        })
      end
      if not applied and not healed and not cleared and not clearedConfusion then
        self:_say("But it failed")
      end
    end
  end
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

-- A recharging seat's turn (CheckTurn's first test, effect_commands.asm:
-- 136-146): "must recharge", the bit cleared, CantMove.  When a flinch or a
-- freeze cancelled the recharge before this slot came (EndRechargeOpp), the
-- gates run instead, and the flinch or the freeze that cancelled it is what
-- stops the move.
function Battle:_rechargeTurn(fighter, mon)
  if mon.mustRecharge then
    mon.mustRecharge = false
    self:_say(mon.species .. " must recharge")
    self:_cantMove(mon)
    return
  end
  if not self:_runGates(fighter, mon, mon.rechargeMove) then self:_cantMove(mon) end
end

function Battle:_resolveFights()
  local actors = {}
  for _, fighter in ipairs(self.fighters) do
    local choice = fighter.choice
    local mon = activeMon(fighter)
    -- A recharge is an actor too (`_lockedChoice`): it takes a place in the
    -- order and rolls its Quick Claw, and its turn is `_rechargeTurn`.
    if choice and (choice.action == "fight" or choice.recharge) and mon then
      local effect, param = Items.effect(mon)
      actors[#actors + 1] = {
        fighter = fighter,
        mon = mon,                      -- pinned: see the skip in the loop
        priority = self:_priorityOf(fighter, mon),
        speed = self:_speedOf(fighter, mon),
        order = #actors + 1,
        -- A Quick Claw holder's parameter, for `_quickClaws`; nil otherwise.
        clawParam = (effect == Items.QUICK_CLAW) and param or nil,
      }
    end
  end
  if #actors == 0 then return end

  self:_orderActors(actors)

  for _, actor in ipairs(actors) do
    if self.result then break end
    -- The monster that chose is the only one allowed to act: if it fainted to
    -- a faster attacker, the replacement that came in behind it does not
    -- inherit the turn.
    if activeMon(actor.fighter) == actor.mon then
      if actor.fighter.choice.recharge then
        self:_rechargeTurn(actor.fighter, actor.mon)
      else
        self:_useMove(actor.fighter, actor.mon)
      end
    end
    -- Finalize after each action (not inside `_faint`) so KO + recoil / explode
    -- on the same move can still mutual-faint into a draw, while an empty-bench
    -- KO still stops the slower seat from acting.  The action's faint batch is
    -- complete here, and that is the earliest moment its spoils can be counted
    -- without paying a monster the same action was still killing (`_drainExp`).
    self:_drainExp()
    if not self.result then self:_checkOver() end
  end
end

-- HitSelfInConfusion (pokecrystal engine/battle/effect_commands.asm:
-- 2864-2898) and the head of the BattleCommand_DamageCalc it falls into
-- (:2900-2915): the confused monster's own battle Attack against its own
-- battle Defense -- stage, badge and burn, as any hit reads them -- that
-- Defense doubled by its OWN side's Reflect, both folded by TruncateHL_BC,
-- and the Defense halved again when the move it SELECTED is Explosion /
-- Self-Destruct, because DamageCalc's EFFECT_SELFDESTRUCT check reads
-- BATTLE_VARS_MOVE_EFFECT and that is still the selected move (a cart bug,
-- docs/bugs_and_glitches.md, kept).  No crit: HitConfusion clears
-- wCriticalHit before it calls in.  Returns attack, defense.
function Battle:_selfHitStats(fighter, mon, selected)
  local attack = self:_battleStat(fighter, mon, "atk")
  local defense = self:_battleStat(fighter, mon, "def")
  if self:_screenUp(fighter.side, false) then defense = defense * 2 end
  attack, defense = Damage.truncateStats(attack, defense, self:_onePassTruncate())
  if selected and Effects.isExplode(selected.effect) then
    defense = max(1, floor(defense / 2))
  end
  return attack, defense
end

-- One status gate (Status.beforeMove: its byte, its line, the counter it
-- ticks).  Returns whether the monster may move past it.  A freeze is no
-- gate with a byte: CheckTurn's `.not_asleep` (effect_commands.asm:186-202)
-- says "frozen solid" and stops the move, drawing nothing and thawing
-- nothing -- HandleDefrost thaws between turns (`_heldDefrost`).  A wake-up
-- writes the status byte with no rebuild (Effects.setStatusOn).
function Battle:_statusGate(fighter, mon)
  if mon.status == "freeze" then
    self:_say(mon.species .. " is frozen solid")
    return false
  end
  local gate = Status.beforeMove(
    { status = mon.status, turnsRemaining = mon.statusTurns }, self.rng:byte())
  if not gate then return true end
  mon.statusTurns = int(gate.turnsRemaining, mon.statusTurns)
  if gate.wokeUp then
    Effects.setStatusOn(mon, fighter, nil)
    mon.statusTurns = 0
    self:_emit("status", { slot = fighter.slot, side = fighter.side,
                           text = mon.species .. " woke up" })
  elseif gate.fullyParalyzed then
    self:_say(mon.species .. " is fully paralyzed")
  elseif mon.status == "sleep" then
    self:_say(mon.species .. " is fast asleep")
  end
  return gate.canMove
end

-- Returns false when a gate stopped the move (the caller runs CantMove,
-- `_cantMove`).  `selected` is the move the monster is about to use (Struggle
-- when every slot is empty, a lock-in's move when it is locked in): the sleep
-- gate's Snore / Sleep Talk exception, the freeze gate's Flame Wheel / Sacred
-- Fire one, the confusion self-hit and the disabled-move check read it the way
-- the cart's CheckTurn and DamageCalc do.
--
-- CheckTurn's order (pokecrystal engine/battle/effect_commands.asm:110-331,
-- pokegold the same): recharge (the referee's forced skip), sleep, freeze,
-- then SUBSTATUS_FLINCHED -- read and cleared at `.not_frozen` -- so a sleeping
-- or frozen monster spends its turn on its status, ticking its counter,
-- whatever flinched it; then confusion, then the disabled move (`.not_
-- infatuated`: the selected move is wDisabledMove), and paralysis LAST
-- (`.no_disabled_move`), so a confused paralysed monster rolls its confusion
-- first and draws no paralysis byte on a self-hit, and one that chose its
-- disabled move is stopped before any paralysis byte.  Attract is not in this
-- referee, and the referee ticks the Disable counter between turns rather
-- than here.
function Battle:_runGates(fighter, mon, selected)
  -- CheckTurn's `.not_asleep`: "Flame Wheel and Sacred Fire thaw the user"
  -- -- a frozen monster that selected either (`cp FLAME_WHEEL / cp
  -- SACRED_FIRE`, by move id) skips the freeze check, no byte and no line,
  -- and the move's own `defrost` thaws it after its hit (`_useMove`).
  local thawing = mon.status == "freeze" and selected ~= nil
    and Effects.FREEZE_BYPASS[Effects.moveKey(selected)] == true
  if (mon.status == "sleep" or mon.status == "freeze") and not thawing then
    local asleep = mon.status == "sleep"
    if not self:_statusGate(fighter, mon) then
      -- "Snore and Sleep Talk bypass sleep": the monster is still told it is
      -- fast asleep, and the move goes on (to obedience, and then itself).
      if not (asleep and mon.status == "sleep" and selected
              and Items.SLEEP_BYPASS[Effects.moveKey(selected)]) then
        return false
      end
    end
  end

  if mon.flinch then
    mon.flinch = false
    self:_say(mon.species .. " flinched")
    return false
  end

  if mon.confusion > 0 then
    -- The self-hit's stats (`_selfHitStats`), built whether or not this
    -- turn's byte lands on a self-hit: they draw nothing.  Status.confusionTick
    -- also takes `itemBoostPercent` -- DamageCalc's type-boost item scan, run
    -- for the SELECTED move's type (STRUGGLE.typeId for Struggle), the other
    -- cart bug.
    local attack, defense = self:_selfHitStats(fighter, mon, selected)
    local gate = Status.beforeMove({
      status = "confusion",
      turnsRemaining = mon.confusion,
      level = mon.level,
      attack = attack,
      defense = defense,
      itemBoostPercent = self:_typeBoostOf(mon, selected),
    }, self.rng:byte())
    if gate then
      mon.confusion = int(gate.turnsRemaining, 0)
      -- CheckTurn's `dec [hl]` on wPlayerConfuseCount: what this field
      -- position's count now holds (`_berserkGene` inherits it).
      fighter.confuseCount = mon.confusion
      if gate.snappedOut then
        self:_say(mon.species .. " snapped out of confusion")
        self:_emit("status", {
          slot = fighter.slot, side = fighter.side, confused = 0,
          text = mon.species .. " snapped out of confusion",
        })
      elseif gate.selfHit then
        self:_say(mon.species .. " hurt itself in confusion")
        -- `ld c, TRUE / call DoPlayerDamage`: the self-hit skips the user's
        -- own substitute and comes off its HP.
        self:_damage(fighter, mon, gate.selfDamage or 0, nil, true)
        return false
      end
      if not gate.canMove then return false end
    end
  end

  -- MoveDisabled: Struggle is no slot, so it is never the disabled move.
  local choice = fighter.choice
  if selected ~= STRUGGLE and choice and mon.disable and mon.disable.turns > 0
     and mon.disable.moveIndex == choice.move then
    self:_say(moveLabel(mon.moves[choice.move]) .. " is disabled")
    return false
  end

  if mon.status == "paralysis" then
    if not self:_statusGate(fighter, mon) then return false end
  end

  return true
end

-- A status or a confusion this move's effect just put on `targetMon`, and
-- the held item the cart asks about it straight away: UseHeldStatusHealingItem
-- at the end of every status-inflicting command (SleepTarget, PoisonTarget,
-- Poison, BurnTarget, FreezeTarget, ParalyzeTarget, Paralyze) and
-- UseConfusionHealingItem at the end of FinishConfusingTarget.  `before` is
-- what the target carried going in.  A confusion that lands also becomes this
-- field position's confuse count (BattleCommand_Confuse writes
-- wEnemyConfuseCount / wPlayerConfuseCount).
function Battle:_afterInfliction(targetFighter, targetMon, before)
  if not (targetFighter and targetMon) or targetMon.hp <= 0 then return end
  if targetMon.status and not before.status then
    self:_statusBerry(targetFighter, targetMon)
  end
  if targetMon.confusion > 0 and before.confusion == 0 then
    targetFighter.confuseCount = targetMon.confusion
    self:_confusionBerry(targetFighter, targetMon)
  end
end

-- Every monster on the field, in field order (Haze's reach).
function Battle:_fieldMons()
  local out = {}
  for _, fighter in ipairs(self.fighters) do
    local mon = activeMon(fighter)
    if mon then out[#out + 1] = mon end
  end
  return out
end

-- Whether a move's matchup against `defender` is 0 -- `stab`'s wTypeModifier,
-- which BattleCommand_Poison and _Paralyze read.  Struggle is typeless.
function Battle:_immuneTo(move, defender)
  if move == STRUGGLE then return false end
  for _, pct in ipairs(self:_typePercents(move.type, defender)) do
    if pct <= 0 then return true end
  end
  return false
end

-- `move` is the sheet move in use: its id is MinimizeDropSub's `cp MINIMIZE`.
-- Returns Effects.applyPrimary's result.
function Battle:_applyPrimary(fighter, mon, targetFighter, targetMon, moveIndex, effectId, move)
  local before = { status = targetMon.status, confusion = targetMon.confusion }
  local result = Effects.applyPrimary({
    effectId = effectId,
    rng = self.rng,
    userMon = mon,
    targetMon = targetMon,
    userFighter = fighter,
    targetFighter = targetFighter,
    moveIndex = moveIndex,
    statusToWire = M.STATUS_TO_WIRE,
    userScreens = self.screens[fighter.side],
    computerMover = isComputerSeat(self.mode, fighter),
    moveKey = Effects.moveKey(move),
    moveImmune = self:_immuneTo(move, targetMon),
    poisonType = self.poisonType,
    grassType = self.grassType,
    fieldMons = self:_fieldMons(),
  })
  if result.nothing then self:_say("But nothing happened") end
  for _, text in ipairs(result.messages or {}) do self:_say(text) end
  for _, entry in ipairs(result.events or {}) do
    self:_emit(entry.kind, entry.fields)
  end
  for _, heal in ipairs(result.heals or {}) do
    self:_heal(fighter, mon, heal.amount)
  end
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
  self:_afterInfliction(targetFighter, targetMon, before)
  return result
end

-- A primary stat-down move whose `checkhit` missed -- its accuracy byte, or a
-- target out of reach in the sky or underground (`.FlyDigMoves`) -- still
-- runs its `attackdown`: the status scripts (AttackDown and the rest, data/
-- moves/effects.asm) have no `failuretext` between the two, and checkhit only
-- sets wAttackMissed, which BattleCommand_StatDown reads at `.DidntMiss`,
-- after its `.ComputerMiss` byte.  So the computer draws that byte for a
-- missed stat-down move too, unless Mist or a stage at -6 stopped the routine
-- first (Effects.statDownGate).  Its verdict changes nothing -- the move has
-- failed either way -- and the line stays the one the caller said.  A *DownHit
-- that misses never gets here: its `failuretext` ends the script first.
--
-- Returns the line StatDownFailText ends the move on (Effects.statDownMissLine:
-- Mist's, the -6 floor's, or "But it failed") for a primary stat-down move,
-- nil for any other.  The target's lock-on is read as `.ComputerMiss` reads
-- the player's SUBSTATUS_LOCK_ON: still set only when the check stopped
-- before `.LockOn`.
function Battle:_statDownAfterMiss(fighter, defender, effectId)
  local stat = Effects.primaryStatDown(effectId)
  if not stat then return nil end
  local line = Effects.statDownMissLine(defender, stat)
  if isComputerSeat(self.mode, fighter) then
    Effects.statDownGate(self.rng, defender, stat, true, effectId, defender.lockOn == true)
  end
  return line
end

-- The secondary effect of a damaging move whose `effectchance` byte has
-- already been drawn (`hit`, see `_useMove`).  `move` is the sheet move that
-- landed: its type goes to Effects.applySide with the two named types
-- (CheckIfTargetIsPoisonType's POISON, CheckMoveTypeMatchesTarget's NORMAL
-- exemption) and whether the move is the computer's -- BattleCommand_StatDown
-- draws its extra miss on the enemy's turn outside a link battle, the seat
-- isComputerSeat names -- and its chance, for the bytes the effect draws
-- itself (TRI ATTACK's `tristatuschance`, DEFENSE_DOWN_HIT's second
-- `effectchance`).  The user's seat badges go too: RaiseStat's 999 test reads
-- the battle stat they boost.
function Battle:_applySide(fighter, mon, targetFighter, targetMon, effectId, hit, move)
  local before = { status = targetMon.status, confusion = targetMon.confusion }
  local result = Effects.applySide({
    effectId = effectId,
    hit = hit == true,
    rng = self.rng,
    userMon = mon,
    targetMon = targetMon,
    userFighter = fighter,
    targetFighter = targetFighter,
    statusToWire = M.STATUS_TO_WIRE,
    moveType = move and move.type,
    poisonType = self.poisonType,
    normalType = self.normalType,
    computerMover = isComputerSeat(self.mode, fighter),
    chance = move and move.chance,
    userBadges = fighter.badges,
    targetSafeguard = self:_safeguarded(targetFighter),
  })
  for _, text in ipairs(result.messages or {}) do self:_say(text) end
  for _, entry in ipairs(result.events or {}) do
    self:_emit(entry.kind, entry.fields)
  end
  self:_afterInfliction(targetFighter, targetMon, before)
  -- BattleCommand_FreezeTarget's tail, once UseHeldStatusHealingItem left the
  -- freeze standing (`ret nz` on a cure): OpponentCantMove -- the frozen
  -- monster's own gate does the same when its slot comes -- EndRechargeOpp,
  -- and wEnemyJustGotFrozen, which keeps this turn's HandleDefrost off it.
  if targetMon.hp > 0 and targetMon.status == "freeze" and before.status ~= "freeze" then
    targetMon.mustRecharge = false
    targetMon.justFrozen = true
  end
end

-- SafeCheckSafeguard / BattleCommand_CheckSafeguard: whether the side a seat
-- sits on has SAFEGUARD up.
function Battle:_safeguarded(fighter)
  local screens = fighter and self.screens[fighter.side]
  return screens ~= nil and int(screens.safeguard, 0) > 0
end

function Battle:_markLastMove(mon, moveIndex)
  if moveIndex and moveIndex >= 1 then mon.lastMoveIndex = moveIndex end
end

function Battle:_faintUser(fighter, mon)
  if mon.hp > 0 then self:_damage(fighter, mon, mon.hp, nil) end
end

function Battle:_concedeRun(fighter)
  self:_emit("run", { slot = fighter.slot, side = fighter.side, text = fighter.name })
  if fighter.side == "a" then
    self:_finish("win", self:_sidePlayers("b"), self:_sidePlayers("a"), "run")
  else
    self:_finish("win", self:_sidePlayers("a"), self:_sidePlayers("b"), "run")
  end
end

-- usedmovetext (engine/battle/used_move_text.asm, UsedMoveText): the move an
-- action is now using becomes its user's BATTLE_VARS_LAST_MOVE and
-- LAST_COUNTER_MOVE -- what a foe's MIRROR MOVE copies.  A called move runs
-- its own script's `usedmovetext`, so a METRONOME leaves the move it called;
-- Struggle is kept as the STRUGGLE sentinel itself, so a copy of it is still
-- typeless and still recoils.  Cleared by ClearLastMove (MIRROR MOVE and
-- METRONOME clear their user's before they call), `.EndDisobedience`
-- (`_disobeyed`), and every send-out (NewBattleMonStatus / NewEnemyMonStatus
-- clear both sides': `_resolveSwitches`, `_faint`).  `lastMoveIndex` stays the
-- slot DISABLE and MIMIC read.
function Battle:_recordLastMove(mon, move)
  if move == STRUGGLE then
    mon.lastCounterMove = STRUGGLE
  else
    mon.lastCounterMove = copyMove(move)
  end
end

-- CheckUserMove: whether the user already knows a move, by id.
local function knowsMove(mon, move)
  local key = Effects.moveKey(move)
  for i = 1, #mon.moves do
    if Effects.moveKey(mon.moves[i]) == key then return true end
  end
  return false
end

-- The move a lock-in resolves to (CheckPlayerLockedIn's `.quit`): a charge
-- being released (SUBSTATUS_CHARGED) and a rampage going on
-- (SUBSTATUS_RAMPAGE) re-use the move that started them -- wCurPlayerMove never
-- left it, and when METRONOME or MIRROR MOVE called that move it is the
-- called one (BattleCommand_Metronome / MirrorMove write it into
-- BATTLE_VARS_MOVE), which the record keeps as `move` -- and never Struggle,
-- whatever PP is left: the menu that would offer Struggle is never opened.
-- nil when the seat is not locked in.
function Battle:_lockedMove(fighter, mon)
  -- A Bide's storing and release turns use BIDE (wCurPlayerMove never left
  -- it): the record a METRONOME / MIRROR MOVE called keeps it as `move`, and
  -- the slot's own Bide is that slot -- never Struggle, whatever PP is left.
  local choice = fighter.choice
  if mon.bide and choice and (choice.bideRelease or choice.bideStore) then
    return mon.bide.move or mon.moves[mon.bide.moveIndex]
  end
  local charge = mon.charging
  if charge and Effects.isCharge(charge.effect) then
    return charge.move or mon.moves[charge.moveIndex]
  end
  local rampage = mon.thrashing
  if rampage and rampage.turns > 0 then
    return rampage.move or mon.moves[rampage.moveIndex]
  end
  return nil
end

-- CantMove (pokecrystal engine/battle/effect_commands.asm:333-357), run by
-- every CheckTurn stop -- asleep, frozen, flinched, a confusion self-hit, the
-- disabled move, full paralysis: SUBSTATUS_BIDE, _RAMPAGE and _CHARGED are
-- cleared, and a FLY / DIG user comes back down.  The Bide, the rampage and
-- the charge are over, and the next turn asks for a move.
function Battle:_cantMove(mon)
  mon.bide = nil
  mon.thrashing = nil
  if mon.charging and Effects.isCharge(mon.charging.effect) then
    mon.charging = nil
    mon.invulnerable = false
  end
end

-- The move a vanished monster is charging, upper-cased: "FLY" or "DIG" is
-- SUBSTATUS_FLYING / _UNDERGROUND (BattleCommand_Charge sets them by move id),
-- and the key CheckHit's `.FlyDigMoves` exceptions are listed under.  nil
-- when it is on the field.
function Battle:_vanishedInto(mon)
  if not mon.invulnerable or not mon.charging then return nil end
  local charge = mon.charging
  local id = charge.moveId
  if not id and charge.move then id = charge.move.id end
  if not id then
    local slot = mon.moves and mon.moves[charge.moveIndex]
    id = slot and slot.id or nil
  end
  return Effects.moveKey(id)
end

-- Whether this hit's doubling command fires (Effects.DOUBLE_VS_*): TWISTER /
-- GUST on a target in the sky, EARTHQUAKE on one underground, STOMP on one
-- whose MINIMIZE went up (wEnemyMinimized, Effects.applyPrimary).
function Battle:_doublesDamage(effectId, defender)
  if Effects.DOUBLE_VS_MINIMIZED[effectId] then return defender.minimized == true end
  if Effects.DOUBLE_VS_FLYING[effectId] then return self:_vanishedInto(defender) == "FLY" end
  if Effects.DOUBLE_VS_UNDERGROUND[effectId] then
    return self:_vanishedInto(defender) == "DIG"
  end
  return false
end

-- BattleCommand_EffectChance where the script has one right after `checkhit`
-- (Effects.drawsEffectChance): drawn hit or miss -- failuretext ends a missed
-- move only after it -- and skipped, with no byte, by a substitute standing
-- before the hit (CheckSubstituteOpp).  Returns whether wEffectFailed stayed
-- clear; a script without the command answers false and draws nothing.
function Battle:_effectChance(move, effectId, behindSub)
  if not Effects.drawsEffectChance(effectId, move) then return false end
  return Effects.effectChance(self.rng, move.chance, behindSub) == true
end

-- TrapTarget's line, by the trapping move's id (`.Traps`); a move the table
-- does not name gets FIRE SPIN's.
local function trapLine(move, user, target)
  local key = Effects.moveKey(move)
  if key == "BIND" then return user.species .. " used BIND on " .. target.species end
  if key == "WRAP" then return target.species .. " was WRAPPED by " .. user.species end
  if key == "CLAMP" then return target.species .. " was CLAMPED by " .. user.species end
  return target.species .. " was trapped"
end

-- One pass of the damage commands -- `critical`, `damagestats`, `damagecalc`,
-- `stab`, `damagevariation` and the doubling after it -- the pass MultiHit,
-- DoubleHit and PoisonMultiHit run again for every hit (BattleCommand_EndLoop
-- loops back to `critical`; `checkhit`, and TWINEEDLE's `effectchance`, stand
-- before it and run once).  Draws the crit byte and then the damage roll,
-- exactly one each whatever the outcome.  Returns { damage, crit, percents,
-- immune, failed }: `immune` a matchup of 0, `failed` a fixed-damage move that
-- could not (Effects.fixedDamage's nil).
function Battle:_hitDamage(fighter, mon, target, defender, move, effectId, struggling, isFixed)
  -- Gen 2 crit ladder (not Gen 1 base-Speed threshold), with the attacker's
  -- item: Scope Lens (HELD_CRITICAL_UP) adds a level, and Chansey's Lucky
  -- Punch / Farfetch'd's Stick -- by item ID, on the battle species -- set it
  -- to 2 outright (Crit.level).
  local critOpts = {
    focusEnergy = mon.focusEnergy,
    highCritMove = move.highCrit == true,
    scopeLens = Items.holds(mon, Items.CRITICAL_UP),
    speciesItemBonus = Items.critSpeciesItem(self:_battleSpecies(mon), mon.heldItem),
  }
  local critLevel = Crit.level(critOpts)
  local critChance = Crit.chance(critLevel)
  local isCrit = select(1, Crit.check(critLevel, self.rng:below(critChance)))
  -- Struggle skips BattleCommand_Stab's matchup loop with the rest of it, so
  -- it is neutral against everything, a Ghost included.
  local percents = struggling and { 100 } or self:_typePercents(move.type, defender)
  local out = { damage = 0, crit = isCrit, percents = percents }

  local immune = false
  for _, pct in ipairs(percents) do
    if pct <= 0 then immune = true; break end
  end

  if isFixed then
    self.rng:damageRoll()
    if immune then out.immune = true; return out end
    local fixed = Effects.fixedDamage({
      effectId = effectId,
      userMon = mon,
      targetMon = defender,
      power = move.power,
    })
    if fixed == nil then out.failed = true; return out end
    out.damage = fixed
    return out
  end

  local isSpecial = Effects.isSpecialType(move.type, self.specialTypes)
  local atkKey = isSpecial and "spa" or "atk"
  local defKey = isSpecial and "spd" or "def"

  -- PlayerAttackDamage / EnemyAttackDamage (pokecrystal engine/battle/
  -- effect_commands.asm:2532-2612, 2777-2855), in the cart's order.
  --
  -- 1. The defender's battle stat (stage, its seat's badge), doubled when
  --    its SIDE has the screen up -- Reflect for a physical hit, Light
  --    Screen for a special one -- as a 16-bit value, before any fold.
  local defense = self:_battleStat(target, defender, defKey)
  if self:_screenUp(target.side, isSpecial) then defense = defense * 2 end
  -- 2. The attacker's battle stat: stage, its seat's badge, burn.
  local attack = self:_battleStat(fighter, mon, atkKey)
  -- 3. CheckDamageStatsCritical (:2660-2700): a crit keeps the pair above
  --    only when the defender's stage is strictly LOWER than the
  --    attacker's; otherwise it reads the unmodified stats -- no stage, no
  --    badge, no burn and no screen.
  if isCrit and not (Effects.clampStage(defender.stages[defKey])
                     < Effects.clampStage(mon.stages[atkKey])) then
    attack = max(1, int(mon.stats[atkKey], 1))
    defense = max(1, int(defender.stats[defKey], 1))
  end
  -- 4. ThickClubBoost (physical) / LightBallBoost (special) double the
  --    attack here, still 16-bit, which is why they can wrap past 1024 when
  --    the fold below makes one pass (Items.speciesAttack).
  attack = Items.speciesAttack(mon, isSpecial, attack)
  -- 5. TruncateHL_BC: both folded into a byte -- one pass in a link battle
  --    and on Gold / Silver, a loop on Crystal otherwise (K6).
  attack, defense = Damage.truncateStats(attack, defense, self:_onePassTruncate())
  -- 6. DittoMetalPowder on the folded pair (Items.metalPowder), and then
  --    BattleCommand_DamageCalc halves the defense for Explosion /
  --    Self-Destruct, at least 1 (:2904-2913).
  attack, defense = Items.metalPowder(defender, attack, defense)
  if Effects.isExplode(effectId) then
    defense = max(1, floor(defense / 2))
  end

  local result = Damage.compute(
    { level = mon.level, attack = attack, spa = attack },
    { defense = defense, spd = defense },
    { power = move.power },
    {
      crit = isCrit,
      -- Struggle takes none of BattleCommand_Stab: no STAB, no badge type
      -- boost (its `cp STRUGGLE / ret z` comes before DoBadgeTypeBoosts),
      -- and the neutral `percents` above.
      stab = not struggling and hasType(mon, move.type),
      typeEffect = percents,
      roll = self.rng:damageRoll(),
      physical = not isSpecial,
      -- DamageCalc's type-boost item scan, ahead of the crit x2: the
      -- attacker's HELD_<TYPE>_BOOST against the move's type -- NORMAL for
      -- Struggle, whose row still says so, so a Pink / Polkadot Bow counts.
      itemBoostPercent = self:_typeBoostOf(mon, move),
      --
      -- The attacker's own badges: a foe seat holds none (BADGE_SIDE), so
      -- this is the cart's "player's turn only" without asking whose turn.
      badgeTypeBoost = not struggling
        and Effects.badgeTypeBoost(self:_typeIdOf(move.type), fighter.badges),
      -- BattleCommand_RageDamage, Rage's own `ragedamage`: the user's rage
      -- counter (`_buildRage`) multiplies the damage, after STAB and
      -- before the variation.
      rageCount = Effects.isRage(effectId) and mon.rageCounter or 0,
    })

  if result.immune then out.immune = true; return out end
  local damage = result.damage or 0
  -- The doubling commands sit after `damagevariation` in their scripts.
  if self:_doublesDamage(effectId, defender) then damage = Damage.double(damage) end
  out.damage = damage
  return out
end

-- BattleCommand_CheckHit (pokecrystal engine/battle/effect_commands.asm:
-- 1546-1623, pokegold the same) up to its roll, in the cart's order:
--
--   1. `.DreamEater`: DREAM EATER against a target that is not asleep, and
--      `.DrainSub`: a draining move (LEECH LIFE's LEECH_HIT, DREAM EATER)
--      against a substitute -- misses before anything is read or drawn.
--      (`.Protect` sits between the two: wave 3.)
--   2. `.LockOn`: the target's SUBSTATUS_LOCK_ON (LOCK-ON / MIND READER) is
--      read and cleared; while it held, the move hits -- unless the target is
--      in the sky and the move is EARTHQUAKE, FISSURE or MAGNITUDE, which go
--      on to `.FlyDigMoves` and miss (docs/bugs_and_glitches.md, "Lock-On and
--      Mind Reader don't always bypass Fly and Dig").  Only a script that
--      runs `checkhit` (or OHKO's call of it) clears it
--      (Effects.NO_CHECKHIT).
--   3. `.FlyDigMoves`: a target in the sky or underground that the move
--      cannot reach -- "vanished", no accuracy draw.
--   4. (`.ThunderRain`: wave 3.)  X Accuracy, EFFECT_ALWAYS_HIT and an
--      accuracy of 0 hit; otherwise the roll.
--
-- The roll is the one draw this referee always spends at step 4 (a hit that
-- needs none still spends it, as it always did): the percent roll, or --
-- against a BRIGHTPOWDER, and for a one-hit KO move (`ohkoByte`, the byte
-- BattleCommand_OHKO raised) -- a BattleRandom byte against the cart's
-- accuracy byte (Accuracy.hitBytes).  Returns "hit", "miss" or "vanished".
function Battle:_checkHit(mon, defender, move, effectId, ohkoByte)
  if effectId == Effects.idOf("DREAM_EATER_EFFECT") and defender.status ~= "sleep" then
    return "miss"
  end
  if Effects.isDrain(effectId) and int(defender.substitute, 0) > 0 then return "miss" end

  local lockedOn = false
  if defender.lockOn and not Effects.NO_CHECKHIT[effectId] then
    defender.lockOn = nil
    lockedOn = not (self:_vanishedInto(defender) == "FLY"
                    and Effects.LOCK_ON_SKY_MISS[Effects.moveKey(move)] == true)
  end

  if not lockedOn and defender.invulnerable
     and not Effects.hitsInvulnerable(self:_vanishedInto(defender), move) then
    return "vanished"
  end

  local alwaysHits = lockedOn or effectId == Effects.idOf("SWIFT_EFFECT")
    or mon.xAccuracy == true
  local powderEffect, powderParam = Items.effect(defender)
  local powder = (powderEffect == Items.BRIGHTPOWDER) and powderParam or nil
  local stages = { accuracyStage = mon.stages.acc, evasionStage = defender.stages.eva,
                   brightPowder = powder }
  if ohkoByte ~= nil then
    local roll = self.rng:byte()
    if alwaysHits then return "hit" end
    return Accuracy.hitBytes(ohkoByte, roll, stages) and "hit" or "miss"
  end
  -- Gen 2 rolls in the percent domain (0..99 vs 1..100) but against a
  -- BRIGHTPOWDER, which is the byte's (above).  A move sheet that still
  -- carries a Gen 1 accuracy byte (1..255) is scaled down for the percent.
  local acc = max(0, int(move.accuracy, 100))
  local roll
  if powder ~= nil then
    roll = self.rng:byte()
  else
    if acc > 100 then acc = max(1, floor(acc * 100 / 255)) end
    roll = self.rng:nextInt(0, Accuracy.ROLL_MAX)
  end
  stages.alwaysHits = alwaysHits or acc <= 0
  return Accuracy.hit(acc, roll, stages) and "hit" or "miss"
end

-- BattleCommand_SleepTalk (move_effects/sleep_talk.asm, pokegold the same)
-- after its ClearLastMove: it fails on a user that is not asleep, on one whose
-- second move slot is empty, and on one with no move it may call
-- (`.check_has_usable_move`, the slots in order to the first empty one);
-- otherwise BattleRandom & 3 picks a slot, drawn again while it is empty,
-- SLEEP TALK itself (BATTLE_VARS_MOVE_ANIM, by id), the disabled move
-- (wDisabledMove, by id) or a two-turn move (`.check_two_turn_move`:
-- SKULL BASH, RAZOR WIND, SKY ATTACK, SOLARBEAM, FLY / DIG, BIDE --
-- Effects.SLEEP_TALK_EXCLUDED).  PP is never asked: a slot with none is
-- called all the same.  The battle moves are read -- a transformed user's
-- copies.  Returns the move, or nil when it fails.
function Battle:_sleepTalkPick(mon, using)
  if mon.status ~= "sleep" then return nil end
  local moves = mon.moves
  if not moves[2] then return nil end
  local disabledKey = nil
  if mon.disable and mon.disable.turns > 0 and moves[mon.disable.moveIndex] then
    disabledKey = Effects.moveKey(moves[mon.disable.moveIndex])
  end
  local usingKey = Effects.moveKey(using)
  local function callable(m)
    local key = Effects.moveKey(m)
    if key == usingKey or key == disabledKey then return false end
    return not Effects.SLEEP_TALK_EXCLUDED[int(m.effect, 0)]
  end
  local usable = false
  for i = 1, min(4, #moves) do
    if callable(moves[i]) then usable = true; break end
  end
  if not usable then return nil end
  for _ = 1, M.REDRAW_LIMIT do
    local m = moves[(self.rng:byte() % 4) + 1]
    if m and callable(m) then return m end
  end
  return nil
end

function Battle:_useMove(fighter, mon, opts)
  opts = opts or {}
  local choice = fighter.choice
  -- A move Metronome or Mirror Move called is not the turn's own move.  The
  -- gates already ran for the move that called it -- BattleCommand_Metronome
  -- ends in ResetTurn, which re-enters DoMove past CheckTurn -- and it is
  -- never Struggle, whatever PP the calling slot has left: Struggle is a
  -- move, not a state of the user's PP, so the call that spent the last PP
  -- takes no recoil.
  local called = opts.moveOverride ~= nil
  -- The move this action resolves to: a lock-in's (`_lockedMove`: a charge's
  -- release, a rampage's next turn, a Bide), else the synthetic STRUGGLE when
  -- every slot is empty -- an empty sheet (`#moves == 0`) included; returning
  -- on the missing slot used to eat that turn instead -- else the chosen slot.
  local move = opts.moveOverride
  local locked = nil
  if not called then
    locked = self:_lockedMove(fighter, mon)
    if locked then
      move = locked
    elseif allPpEmpty(mon) then
      move = STRUGGLE
    else
      move = mon.moves[choice.move]
    end
  end
  if not move then return end
  local struggling = move == STRUGGLE

  -- A move used in place of a disobeyed one runs no CheckTurn of its own: the
  -- cart calls DoMove for it from inside the check (`.UseInstead`).  A stop
  -- is CantMove's (`_cantMove`).  A Bide's storing turn runs CheckTurn too:
  -- DoTurn calls it for every move, BIDE included, so a storing Bide that a
  -- gate stops is over.
  local disobeyed = opts.disobeyed == true
  if not called and not disobeyed and not self:_runGates(fighter, mon, move) then
    self:_cantMove(mon)
    return
  end

  -- BattleCommand_StoreEnergy (move_effects/bide.asm), the first command of
  -- BIDE's script, ahead of `checkobedience` and `usedmovetext`: on a storing
  -- turn the line, and EndMoveEffect -- no obedience, no PP, no target.
  if choice.bideStore then
    self:_say(mon.species .. " is storing energy")
    return
  end

  -- `checkobedience`, the first command of every move script, for the move
  -- the monster chose (`_obey`).  A move it uses instead is that move used
  -- in full -- its own PP, its own effect -- under "used instead,", and then
  -- the cart's `.EndDisobedience` forgets it as the last move.
  if not called and not disobeyed then
    local verdict = self:_obey(fighter, mon, move)
    if verdict == "stop" then return end
    if type(verdict) == "number" then
      local saved = fighter.choice
      fighter.choice = { action = "fight", move = verdict, target = saved.target }
      self:_useMove(fighter, mon, { disobeyed = true })
      fighter.choice = saved
      mon.lastMoveIndex = 0
      mon.lastCounterMove = nil
      return
    end
  end

  -- Resolved once, here, and used for the whole action: see `_retarget`.
  local target = self:_retarget(fighter, choice.target)
  local defender = target and activeMon(target)
  if not defender then
    self:_say(mon.species .. " has no target")
    return
  end
  -- The seat actually swung at.  Anything this action *records* for a later
  -- turn (a charge's aim, a Bide's aim) records this and not `choice.target`,
  -- so the release lands where the action went rather than on the seat that
  -- was already empty when it started.
  local targetSlot = target.slot

  local effectId = int(move.effect, 0)
  local releasing = mon.charging ~= nil and Effects.isCharge(mon.charging.effect)
  -- A rampage's next turn (SUBSTATUS_RAMPAGE): the locked move again, no PP
  -- (BattleCommand_DoTurn returns before .consume_pp under the rampage bit).
  local rampaging = locked ~= nil and not releasing and mon.thrashing ~= nil
  local mirrorCopy = opts.mirrorCopy == true

  if not struggling and move.pp > 0 and not releasing and not rampaging
     and not choice.bideRelease then
    move.pp = move.pp - 1
    -- FIGHT reads the uploaded sheet. Publish whenever PP actually moved
    -- (Transform/Mimic already emit via movesChanged). Skip an override
    -- copy -- Metronome/Mirror already spent the real slot on the first call.
    if not opts.moveOverride then
      self:_emitMoves(fighter, mon, fighter.active)
    end
  end

  -- BattleCommand_CheckRampage (effect_commands.asm:4888-4921), the first
  -- command of THRASH's script on a rampage's next turn: the count goes down,
  -- and when it runs out the rampage ends and the user is confused for 2-3
  -- turns (Effects.rampageConfusion; the cart says nothing, the status event
  -- carries the chip) -- before the move it still makes this turn -- unless
  -- its own side's SAFEGUARD is up (SafeCheckSafeguard, after a SwitchTurn:
  -- the user's side), which spares it the confusion and its byte.
  if rampaging then
    local rampage = mon.thrashing
    rampage.turns = rampage.turns - 1
    if rampage.turns <= 0 then
      mon.thrashing = nil
      if not self:_safeguarded(fighter) then
        local turns = Effects.rampageConfusion(self.rng)
        mon.confusion = turns
        fighter.confuseCount = turns
        self:_say(mon.species .. " became confused")
        self:_emit("status", {
          slot = fighter.slot, side = fighter.side, confused = 1,
          text = mon.species .. " became confused",
        })
      end
    end
  end

  local chargingUp = Effects.isCharge(effectId) and not mon.charging
  self:_emit("anim", {
    slot = fighter.slot, side = fighter.side, text = move.id,
    amount = chargingUp and 1 or nil,
  })
  if choice.bideRelease and mon.bide then
    -- StoreEnergy's release: "unleashed energy!", then SkipToBattleCommand
    -- past `unleashenergy` -- no `usedmovetext`, so the last move stays what
    -- it was.
    self:_say(mon.species .. " unleashed energy")
  else
    self:_say(mon.species .. (disobeyed and " used instead, " or " used ") .. moveLabel(move))
    self:_recordLastMove(mon, move)
  end

  if choice.bideRelease and mon.bide then
    local stored = mon.bide.stored
    mon.bide = nil
    if stored <= 0 then
      self:_say("But it failed")
      self:_markLastMove(mon, choice.move)
      return
    end
    -- BattleCommand_StoreEnergy's release: the damage taken doubled as a
    -- 16-bit pair, a carry pinning $ffff.  Bide's script releases it through
    -- applydamage, so a Focus Band answers it, then `checkfaint`,
    -- `buildopponentrage` and `kingsrock`.
    self:_strike(target, defender, min(Damage.WORD_MAX, 2 * stored))
    self:_buildRage(defender)
    self:_kingsRock(mon, move, effectId, defender)
    self:_markLastMove(mon, choice.move)
    return
  end

  -- BattleCommand_MirrorMove (move_effects/mirror_move.asm): ClearLastMove
  -- first, then the opponent's LAST_COUNTER_MOVE -- the move it last used
  -- (`_recordLastMove`), the one its METRONOME called included -- which
  -- fails when there is none or when the user already knows it
  -- (CheckUserMove), with the cart's own MirrorMoveFailedText, and otherwise
  -- is used in full through ResetTurn: its own script, its own `checkhit`
  -- against a target in the sky.
  if Effects.isMirrorMove(effectId) and not mirrorCopy then
    mon.lastCounterMove = nil
    local copied = defender.lastCounterMove
    if not copied or knowsMove(mon, copied) then
      self:_say("The MIRROR MOVE failed!")
      self:_markLastMove(mon, choice.move)
      return
    end
    self:_markLastMove(mon, choice.move)
    self:_useMove(fighter, mon, {
      moveOverride = (copied == STRUGGLE) and STRUGGLE or copyMove(copied),
      mirrorCopy = true,
    })
    return
  end

  -- BattleCommand_Metronome: ClearLastMove, then the pick (the client's
  -- pool; see the policy note above), used through ResetTurn.  `.GetMove`
  -- draws again for a move the user already knows (CheckUserMove), so a pick
  -- it knows is redrawn here too; a pool the user knows whole -- where the
  -- cart's loop would never end -- is "But nothing happened", as no pool is.
  local metronomeCall = opts.metronomeCall == true
  if Effects.isMetronome(effectId) and not metronomeCall then
    mon.lastCounterMove = nil
    local pool = self.metronomePool
    local open = false
    for _, entry in ipairs(pool or {}) do
      if not knowsMove(mon, entry) then open = true; break end
    end
    local pick = nil
    if open then
      for _ = 1, M.REDRAW_LIMIT do
        local entry = pool[(self.rng:byte() % #pool) + 1]
        if not knowsMove(mon, entry) then pick = entry; break end
      end
    end
    self:_markLastMove(mon, choice.move)
    if not pick then
      self:_say("But nothing happened")
      return
    end
    self:_useMove(fighter, mon, {
      moveOverride = copyMove(pick),
      metronomeCall = true,
    })
    return
  end

  -- BattleCommand_SleepTalk: ClearLastMove, the pick (`_sleepTalkPick`, "But
  -- it failed" when there is none), and the picked move used through
  -- ResetTurn like a METRONOME call -- no PP of its own, no second CheckTurn.
  -- Its script has no `checkhit`.
  if effectId == Effects.SLEEP_TALK and not opts.sleepTalkCall then
    mon.lastCounterMove = nil
    local pick = self:_sleepTalkPick(mon, move)
    self:_markLastMove(mon, choice.move)
    if not pick then
      self:_say("But it failed")
      return
    end
    self:_useMove(fighter, mon, {
      moveOverride = copyMove(pick),
      sleepTalkCall = true,
    })
    return
  end

  if Effects.isCharge(effectId) and not mon.charging then
    mon.charging = {
      moveIndex = choice.move,
      effect = effectId,
      targetSlot = targetSlot,
      moveId = move.id,
      -- The move a METRONOME or MIRROR MOVE called: the release next turn
      -- is that move (`_lockedMove`), not a second call.
      move = called and copyMove(move) or nil,
    }
    if Effects.vanishes(effectId, move) then mon.invulnerable = true end
    self:_say(Effects.chargeMessage(mon, effectId, move.id))
    self:_markLastMove(mon, choice.move)
    return
  end

  if mon.charging and Effects.isCharge(mon.charging.effect) then
    mon.charging = nil
    mon.invulnerable = false
  end

  -- BattleCommand_Rampage (effect_commands.asm:4923-4945), THRASH's
  -- `rampage` on its first turn, ahead of `checkhit` -- so a rampage starts
  -- on a miss too: 1-2 more turns (Effects.rampageTurns), the called move
  -- kept when METRONOME or MIRROR MOVE called it.  "No rampage during Sleep
  -- Talk": a sleeping user starts none.
  if Effects.isThrash(effectId) and not mon.thrashing and not rampaging
     and mon.status ~= "sleep" then
    mon.thrashing = {
      turns = Effects.rampageTurns(self.rng),
      moveIndex = choice.move,
      move = called and copyMove(move) or nil,
    }
  end

  -- `effectchance` reads the target's substitute before the hit can break it
  -- (CheckSubstituteOpp).
  local subAtChance = (defender.substitute or 0) > 0

  -- BattleCommand_OHKO (effect_commands.asm:5420-5462), the OHKO script's
  -- only accuracy check -- it has no `checkhit` of its own, and no
  -- `critical` or `damagevariation`: a matchup of 0 ("doesn't affect") and a
  -- user below the target's level ("<TARGET>'s unaffected!", wCriticalHit
  -- $ff) miss with nothing drawn; otherwise the move's accuracy byte gains
  -- twice the level gap, held at $ff, and CheckHit rolls against that byte.
  -- A hit is $ffff damage (`_strike` stops it at the HP, or the doll's).
  local isOhko = Effects.isOhko(effectId)
  local ohkoByte = nil
  if isOhko then
    if self:_immuneTo(move, defender) then
      self:_say("It doesn't affect " .. defender.species)
      self:_markLastMove(mon, choice.move)
      return
    end
    if mon.level < defender.level then
      self:_say(defender.species .. "'s unaffected!")
      self:_markLastMove(mon, choice.move)
      return
    end
    ohkoByte = min(255, Accuracy.moveByte(move.accuracy) + 2 * (mon.level - defender.level))
  end

  local verdict = self:_checkHit(mon, defender, move, effectId, ohkoByte)
  -- The script's `effectchance`, right after `checkhit` and drawn hit or miss
  -- (`_effectChance`) -- on a `.FlyDigMoves` miss too.  What it decides is
  -- read further down, where the scripts put the secondary effect.
  local effectHit = self:_effectChance(move, effectId, subAtChance)

  -- BattleCommand_Snore (move_effects/snore.asm), after `checkhit` and
  -- `effectchance` and before `failuretext`: a user that is not asleep fails
  -- the move ("But it failed!", FailMove) whether or not it would have hit.
  if effectId == Effects.SNORE and mon.status ~= "sleep" then
    self:_say("But it failed")
    self:_markLastMove(mon, choice.move)
    return
  end

  -- BattleCommand_CheckSafeguard, the `checksafeguard` after `checkhit` in
  -- the sleep, poison, TOXIC, paralysis and confusion scripts: the target's
  -- side has SAFEGUARD up -- "<TARGET> is protected by SAFEGUARD!" and
  -- EndMoveEffect, a miss or not.
  if Effects.CHECKS_SAFEGUARD[effectId] and self:_safeguarded(target) then
    self:_say(defender.species .. " is protected by SAFEGUARD!")
    self:_markLastMove(mon, choice.move)
    return
  end

  if verdict ~= "hit" then
    -- The line a miss ends on: LOCK-ON's own (PrintDidntAffect, its command
    -- still runs on wAttackMissed), a primary stat-down's StatDownFailText
    -- after the computer's `.ComputerMiss` byte (`_statDownAfterMiss`), and
    -- otherwise this referee's: "But it failed" for a vanished target,
    -- "<MON> missed" for the rest.
    local line
    if effectId == Effects.LOCK_ON then
      line = Effects.didntAffectLine(defender)
    else
      line = self:_statDownAfterMiss(fighter, defender, effectId)
    end
    if not line then
      line = (verdict == "vanished") and "But it failed" or (mon.species .. " missed")
    end
    self:_say(line)
    if Effects.isExplode(effectId) then self:_faintUser(fighter, mon) end
    if Effects.isJumpKick(effectId) then
      self:_damage(fighter, mon, Effects.jumpKickCrash(mon.maxHp), nil)
    end
    self:_markLastMove(mon, choice.move)
    return
  end

  local isFixed = Effects.isFixedDamage(effectId)

  if move.power <= 0 and not isFixed then
    if Effects.isBide(effectId) and not mon.bide then
      mon.bide = {
        turns = Effects.bideTurns(self.rng),
        stored = 0,
        moveIndex = choice.move,
        targetSlot = targetSlot,
        -- A called BIDE releases as BIDE, not as a second call (`_lockedMove`).
        move = called and copyMove(move) or nil,
      }
      self:_say(mon.species .. " began storing energy")
      self:_markLastMove(mon, choice.move)
      return
    end
    if Effects.isSwitchAndTeleport(effectId) then
      if Effects.teleportRunAllowed(self.mode) then
        self:_concedeRun(fighter)
      else
        self:_say("But it failed")
      end
      self:_markLastMove(mon, choice.move)
      return
    end
    if Effects.isNoOp(effectId) then
      self:_say("But nothing happened")
      self:_markLastMove(mon, choice.move)
      return
    end
    local cleared = false
    if Effects.handlesPrimary(effectId) then
      local result = self:_applyPrimary(fighter, mon, target, defender, choice.move, effectId, move)
      cleared = result.clearLastMove == true
    else
      self:_say("But nothing happened")
    end
    -- Transform's ClearLastMove forgets the slot as well (DISABLE and MIMIC
    -- read wLastPlayerMove).
    if cleared then mon.lastMoveIndex = 0 else self:_markLastMove(mon, choice.move) end
    return
  end

  -- The first pass of the damage commands (`_hitDamage`); MultiHit, DoubleHit
  -- and PoisonMultiHit run another for each hit after it.  A one-hit KO runs
  -- none: its damage is $ffff, no crit byte and no roll.
  local struck
  if isOhko then
    struck = { damage = Damage.WORD_MAX, crit = false,
               percents = self:_typePercents(move.type, defender) }
  else
    struck = self:_hitDamage(fighter, mon, target, defender, move, effectId,
      struggling, isFixed)
  end
  if struck.immune then
    self:_say("It doesn't affect " .. defender.species)
    if Effects.isExplode(effectId) then self:_faintUser(fighter, mon) end
    if Effects.isJumpKick(effectId) then
      self:_damage(fighter, mon, Effects.jumpKickCrash(mon.maxHp), nil)
    end
    self:_markLastMove(mon, choice.move)
    return
  end
  if struck.failed then
    self:_say("But it failed")
    if Effects.isExplode(effectId) then self:_faintUser(fighter, mon) end
    self:_markLastMove(mon, choice.move)
    return
  end

  local effectiveness = 1
  for _, pct in ipairs(struck.percents) do effectiveness = effectiveness * pct / 100 end

  -- The hits.  Every one is its own `critical` / `damagevariation`
  -- (`_hitDamage` again from the second on), its own Focus Band roll
  -- (`_strike`), `checkfaint` -- a target that went down ends the move -- and
  -- `buildopponentrage`; MULTI_HIT's count is drawn at the first EndLoop,
  -- after the first hit, and only when the target is still standing
  -- (Effects.multiHitCount).  `curDamage` is wCurDamage after the hit's
  -- `applydamage`: the HP it took -- 0 when a substitute took it
  -- (DoSubstituteDamage's ResetDamage) -- which RECOIL reads.
  local multihit = Effects.isMultihit(effectId)
  local hits = Effects.fixedHits(effectId)
  local totalDealt, curDamage = 0, 0
  local index = 1
  while index <= hits do
    if index > 1 then
      if defender.hp <= 0 then break end
      struck = self:_hitDamage(fighter, mon, target, defender, move, effectId,
        struggling, isFixed)
    end
    if struck.crit and not isFixed then self:_say("A critical hit") end
    if index == 1 then
      -- OneHitKOText: criticaltext with wCriticalHit 2.
      if isOhko then self:_say("It's a one-hit KO!") end
      if effectiveness > 1 then
        self:_say("It's super effective")
      elseif effectiveness < 1 then
        self:_say("It's not very effective")
      end
    end
    local hpBefore = defender.hp
    self:_strike(target, defender, struck.damage)
    curDamage = hpBefore - defender.hp
    totalDealt = totalDealt + curDamage
    if multihit then self:_buildRage(defender) end
    if index == 1 and effectId == 29 and defender.hp > 0 then
      hits = Effects.multiHitCount(self.rng)
    end
    index = index + 1
  end

  -- BattleCommand_EndLoop's `.done_loop` (effect_commands.asm:5296-5320):
  -- when the loop runs out with the target standing, "Hit N times!"
  -- (PlayerHitTimesText, wPlayerDamageTaken the hits made).  A hit that
  -- knocked the target out ended the move at `checkfaint`, before it.
  if multihit and defender.hp > 0 then
    self:_say("Hit " .. (index - 1) .. " times!")
  end

  -- FLAME WHEEL's and SACRED FIRE's `defrost`, after the damage and before
  -- `checkfaint` (BattleCommand_Defrost): a frozen user thaws -- CheckTurn
  -- let it through the freeze for these two (`_runGates`).  The status byte
  -- goes with no rebuild.
  if Effects.DEFROSTS_USER[effectId] and mon.status == "freeze" then
    Effects.setStatusOn(mon, fighter, nil)
    mon.statusTurns = 0
    local text = mon.species .. " was defrosted"
    self:_say(text)
    -- No token: a `status` event without one is a cure (events.lua).
    self:_emit("status", { slot = fighter.slot, side = fighter.side, text = text })
  end

  -- SapHealth (effect_commands.asm:3837-3928), DrainTarget's and EatDream's:
  -- half of wCurDamage, at least 1 -- a hit that reached this far took HP
  -- (`.DrainSub` missed a substitute before it).
  if Effects.isDrain(effectId) then
    self:_heal(fighter, mon, max(1, Effects.drainAmount(totalDealt)))
  end

  -- BattleCommand_PayDay, after the damage on every hit that did not miss --
  -- a substitute's included -- for whoever used it (Effects.payDayCoins): the
  -- fight's one pot, which `_payDayOutcome` reports.
  if Effects.isPayDay(effectId) then
    self.payDay = self.payDay + Effects.payDayCoins(mon.level)
    self:_say("Coins scattered")
  end

  -- The Thief script's `thief`, right after the damage (a Gold sheet names
  -- the move, not EFFECT_THIEF; Items.THIEF), when its `effectchance` left
  -- wEffectFailed clear: the chance byte landed and no substitute stood.
  if Effects.moveKey(move) == Items.THIEF and effectHit and not subAtChance then
    self:_thief(fighter, mon, target, defender)
  end

  -- BattleCommand_Recoil, on every hit that did not miss: a quarter of
  -- wCurDamage, at least 1 (Effects.recoilAmount) -- so 1 when a substitute
  -- took the hit -- straight off the user's HP, past its own substitute.
  if struggling or Effects.isRecoil(effectId) then
    local recoil = Effects.recoilAmount(curDamage)
    self:_say(mon.species .. " is hit with recoil")
    self:_damage(fighter, mon, recoil, nil, true)
  end

  if not multihit then self:_buildRage(defender) end

  -- The secondary effect, which every *Hit script puts after `checkfaint`:
  -- a target the hit knocked out has ended the script there, so it is never
  -- burned, poisoned or confused (nor its confusion's turns drawn).
  -- `checkfaint` reads the monster's HP and not its substitute's, so a hit the
  -- substitute took goes on to the effect command, which asks about the
  -- substitute itself (Effects.applySide) -- after BattleCommand_StatDown's
  -- `.ComputerMiss` byte, and after BattleCommand_BurnTarget's Defrost of a
  -- target whose substitute this hit broke.
  if defender.hp > 0 then
    self:_applySide(fighter, mon, target, defender, effectId, effectHit, move)
  end

  -- A substitute absorbs HP (including the breaking hit), so totalDealt stays
  -- 0. Do not then apply a foe primary onto the mon behind it.
  if Effects.handlesPrimary(effectId) and totalDealt > 0 then
    self:_applyPrimary(fighter, mon, target, defender, choice.move, effectId, move)
  end

  -- BattleCommand_Rage (move_effects/rage.asm): SUBSTATUS_RAGE on the user of
  -- a Rage that connected (`rage` sits after `failuretext`).  No lock-in: it
  -- lasts while the seat keeps choosing Rage (`_resetRage`).
  if Effects.isRage(effectId) then
    mon.raging = true
  end

  -- BattleCommand_TrapTarget (effect_commands.asm:5612-5650), after
  -- `checkfaint`: a target that already has a wrap count, or a substitute
  -- standing now, is not trapped; otherwise the count (Effects.wrapCount)
  -- and the move's name, for HandleWrap (`_residualDamage`), and the cart's
  -- line.  Gold traps nothing else: the target picks its moves as before --
  -- only switching and running are closed to it (`_normaliseChoice`) -- and
  -- the user is free.
  if Effects.isTrapping(effectId) and defender.hp > 0 and not defender.trapped
     and int(defender.substitute, 0) <= 0 then
    defender.trapped = {
      turns = Effects.wrapCount(self.rng),
      fromSlot = fighter.slot,
      label = moveLabel(move, "the trap"),
    }
    self:_say(trapLine(move, mon, defender))
  end

  -- BattleCommand_RechargeNextTurn, before `checkfaint` in HYPER BEAM's
  -- script: every hit that did not miss -- a knockout and a substitute's
  -- included -- costs the user its next turn on Gold.  The move stays its
  -- wCurPlayerMove, the priority that next turn's slot is ordered by
  -- (`_priorityOf`).
  if Effects.isHyperBeam(effectId) then
    mon.mustRecharge = true
    mon.rechargeMove = move
  end

  if Effects.isExplode(effectId) then
    self:_faintUser(fighter, mon)
  end

  -- `kingsrock`, the last command of the scripts that hold one.
  self:_kingsRock(mon, move, effectId, defender)

  self:_markLastMove(mon, choice.move)
end

-- One place where HP comes off, so the faint that follows can never be
-- forgotten at one of the call sites.  `ignoreSubstitute` is the cart's
-- DoPlayerDamage / DoEnemyDamage `c` flag: the confusion self-hit sets it, so
-- the damage reaches the HP behind the user's own substitute -- and so does
-- every SubtractHPFromUser (recoil, poison, burn, LEECH SEED, a wrap), which
-- never looks at one.  Bide's store is `_strike`'s: only a move's hit feeds it.
function Battle:_damage(fighter, mon, amount, status, ignoreSubstitute)
  amount = max(0, int(amount, 0))

  if amount > 0 and not ignoreSubstitute and mon.substitute and mon.substitute > 0 then
    if amount >= mon.substitute then
      mon.substitute = 0
      self:_say(mon.species .. "'s substitute broke")
    else
      mon.substitute = mon.substitute - amount
    end
    self:_emit("damage", {
      slot = fighter.slot, side = fighter.side,
      amount = amount, hp = mon.hp,
      status = status and M.STATUS_TO_WIRE[status] or nil,
    })
    return
  end

  if amount > mon.hp then amount = mon.hp end

  mon.hp = mon.hp - amount

  self:_emit("damage", {
    slot = fighter.slot, side = fighter.side,
    amount = amount, hp = mon.hp,
    status = status and M.STATUS_TO_WIRE[status] or nil,
  })

  if mon.hp <= 0 then self:_faint(fighter, mon) end
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
-- Ported from the Gen 1 twin (src/BattleSim/Turn.lua), which mirrors
-- gen1recomp's own `BattleState:markParticipant` / `awardExp`.  Gen 2 keeps the
-- same bookkeeping -- `wPartyGainExpFlags` survives into Gold unchanged and
-- `src/battle/gen2/Battle.lua:awardExperience` walks the same set -- so this is
-- the Gen 1 machinery verbatim rather than a second derivation.  Where Gen 2
-- genuinely differs is in what a *share is worth* (its own stat exp, the Exp
-- Share halved pass, the traded and Lucky Egg boosts), and none of that is here:
-- the referee announces facts, the client prices them.
--
--   * set on send-out -- battle start, a voluntary switch, a post-faint
--     replacement, and again when the seat opposite sends its next one out.
--   * cleared when the foe changes: the set is per enemy MONSTER, not per
--     battle.
--   * dropped on its own faint (`_unfield`), so a participant that died before
--     the KO is neither paid NOR counted in the divisor.
--   * ...and the send-out's own mark lands a turn late here, because a seat is
--     *asked* for its replacement rather than just sending one.  It is taken at
--     the faint, against the field the faint happened on, and held in
--     `fighter.pendingFought` until `_refield` fields the successor.
--
-- Keys are strings so the two runtimes agree on membership without agreeing on
-- table iteration order -- nothing ever walks this table, it is only ever asked.
local function foughtKey(slot, index)
  return slot .. ":" .. index
end

-- This seat's monster just changed (battle start, switch, replacement).
--
-- Its own set resets, then the currently standing opposition marks into it --
-- and the incoming monster marks into each of THEIR sets: a switch-in joins the
-- standing foe's participants.  A foe of ours that is mid-replacement (nothing
-- out) is neither read nor written, the same way the engine has no enemy to
-- mark against.
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
  -- one replaces went down was in against this one too.  Only this direction is
  -- owed -- the seat opposite re-derives its own set the next time it refields,
  -- exactly as the engine keeps flags on one side only.  Consumed once: a seat
  -- that refields again later starts clean.
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
-- its own generation's Experience over its own party, which is also the only
-- place the result can persist.  This is the same shape as the vitamin
-- writeback and the catch grant: the authority announces, the owner applies.
--
-- The mode gate is not a shortcut for the owner check, it is the rule.  A
-- seated fighter here carries a playerId whether a connection is behind it or a
-- synthetic wild / trainer seat is, so "does this seat have an owner" is not a
-- question the turn machine can ask -- but the *mode* answers it, because the
-- hub only ever seats a synthetic opponent in these three, and always on side
-- b.  1v1 and coop_pvp are left out deliberately rather than incidentally:
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
-- the inner one is the party array.
--
-- `slot` stays the owning FIGHTER's field slot -- that is the ownership gate,
-- and it is what a client checks before writing to its own save.  `mon` says
-- which of that party banks the share, 0-based, because a benched participant
-- has no field slot to be named by.
--
-- The divisor is the engine's: `participants` counts every member of the set,
-- `alive` is the subset still above zero HP, and only `alive` is paid.  The two
-- numbers agree in practice because a faint already left the set (`_unfield`)
-- -- mirrored rather than collapsed so the shape stays comparable.
--
-- The empty-set fallback: with nothing flagged, the monster that is out gets
-- the whole thing.  Two seats can be out here where the engine has one, so all
-- of the standing ones share it.
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
-- Split from `_faint` because the engine splits it: knocking a monster *down*
-- clears its flag, and the payout is queued behind that -- so by the time
-- anybody is counted, every monster the action killed has already left the set.
-- Paying inside `_faint` instead put a self-KO'er in its own victim's payout: an
-- Explosion or a recoil that kills its user runs `_faintUser` *after* the
-- target's faint, so the user was still standing, still flagged, and still in
-- the divisor.
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
  -- RemoveFaintedPlayerMon first: this one is out of every participation set
  -- before anything below can pay anybody, so a mon that died on the way to the
  -- KO is not in the divisor.  Keyed off the seat's own party position rather
  -- than `active`, which the recoil path has not cleared yet.
  for index = 1, #fighter.mons do
    if fighter.mons[index] == mon then self:_unfield(fighter, index); break end
  end
  mon.charging = nil
  mon.invulnerable = false
  mon.mustRecharge = false
  mon.thrashing = nil
  mon.raging = false
  mon.rageCounter = 0
  mon.trapped = nil
  mon.bide = nil
  mon.substitute = 0
  mon.minimized = false
  mon.lastCounterMove = nil
  mon.mist = false
  mon.focusEnergy = false
  mon.xAccuracy = false
  mon.leechSeed = nil
  mon.disable = nil
  -- The fallen monster's substatus and Transform go with it -- the party
  -- copy it is again (`_clearSubstatus`).
  self:_clearSubstatus(mon)
  -- The fallen monster's stages go with it; the side's screens stay up.
  Effects.resetStages(mon)
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
  -- Inside the faint batch, so the ball goes dark in the same beat the monster
  -- goes down -- and so a fight that ends here still said it.
  self:_syncTeams()

  -- Owed here, paid at the end of the action (`_drainExp`), with the fallen
  -- sheet held in the queue so the payout still names the monster that fell and
  -- the level it was.  For an ordinary KO nothing moves: the faint, then its
  -- spoils, and only then anything about what comes next.  What changes is the
  -- action that fells two: every one of them is out of the sets before the
  -- first share is counted.
  self.pendingExp[#self.pendingExp + 1] = { fallen = fighter, mon = mon }

  fighter.active = nil
  if next_ then
    -- Ask the seat for a switch on the next choice window; timeout / autoPick
    -- still lands firstLiving (preferring an SE bench). No PROTOCOL bump —
    -- same `switch` + `turn`/`chose` vocabulary; amount rides an existing field.
    fighter.mustReplace = true
    -- The successor's mark, taken now because the send-out is not now.
    --
    -- Vanilla marks whoever is standing at the enemy's send-out, and the engine
    -- sends out inside the faint itself, while the monster that landed the KO is
    -- still on the field.  This referee cannot: it asks the seat, and the answer
    -- arrives on the next choice window, by which time side a's own switches
    -- have already resolved (`_resolveSwitches` walks side a first).  A player
    -- who swaps on that turn would hand the incoming foe a set that never heard
    -- of the monster that beat the last one.  So the send-out's mark is taken
    -- here, against the field the faint actually happened on, and held until
    -- `_refield` puts the successor out.
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

-- The end of the turn.  pokecrystal's HandleBetweenTurnEffects (engine/
-- battle/core.asm:250-296, pokegold the same) runs, after its faint-checked
-- block (Future Sight, weather, Wrap, Perish Song): Leftovers, Mysteryberry,
-- Defrost, Safeguard, HandleScreens, the stat-boosting held items, the healing
-- held items, then Encore.  This referee's per-seat residual walk
-- (`_residualDamage`) stands where that first block and the cart's per-move
-- ResidualDamage stand, and the rest follows in the cart's order -- Encore
-- is not in this referee yet.  A seat that fainted this turn is replaced
-- after all of it (the replace phase), where the cart sends its successor out
-- first, so the successor's share of the block -- its held items and its
-- defrost -- runs when the replace phase closes (`_closeReplace`).
function Battle:_resolveResiduals()
  self:_residualDamage()
  if self.result then return end
  self:_heldLeftovers()
  self:_heldMysteryberry()
  self:_heldDefrost()
  self:_tickSafeguard()
  self:_tickScreens()
  self:_heldStatBoosts()
  self:_heldHealing()
end

-- HandleDefrost (engine/battle/core.asm:1524-1581): player then enemy --
-- every seat in field order -- a frozen monster the freeze did not land on
-- this turn (wPlayerJustGotFrozen, `justFrozen`) draws one BattleRandom and
-- thaws under 10 percent (Status.defrosts): "<MON> was defrosted!"
-- (DefrostedOpponentText).  The status byte goes with no rebuild.  CheckTurn
-- never thaws (`_statusGate`): this is the only thaw but a fire move's.
function Battle:_heldDefrost(only)
  for _, fighter in ipairs(self.fighters) do
    local mon = inSet(only, fighter) and activeMon(fighter)
    if mon and mon.status == "freeze" and not mon.justFrozen
       and Status.defrosts(self.rng:byte()) then
      Effects.setStatusOn(mon, fighter, nil)
      mon.statusTurns = 0
      local text = mon.species .. " was defrosted"
      self:_say(text)
      -- No token: a `status` event without one is a cure (events.lua).
      self:_emit("status", { slot = fighter.slot, side = fighter.side, text = text })
    end
  end
end

-- HandleSafeguard (core.asm:1583-1618): side a then side b (the non-link
-- `.CheckPlayer` first), a turn off each SAFEGUARD that is up, and the cart's
-- line when one runs out.  The side is named by its first seat, as the
-- screens' lines name it.
function Battle:_tickSafeguard()
  for _, side in ipairs(M.SIDES) do
    local screens = self.screens[side]
    if screens.safeguard > 0 then
      screens.safeguard = screens.safeguard - 1
      if screens.safeguard == 0 then
        local first = self.bySide[side][1]
        local name = first and first.name or ("side " .. side)
        self:_say(name .. "'s SAFEGUARD faded!")
      end
    end
  end
end

-- HandleScreens (core.asm:1620-1680): side a then side b (the non-link
-- order: `.CheckPlayer`, then `.CheckEnemy`), Light Screen before Reflect
-- within a side, one turn off each screen that is up, and the cart's line when
-- one runs out.  The side is named by its first seat, as BattleSim3 names it.
function Battle:_tickScreens()
  for _, side in ipairs(M.SIDES) do
    local screens = self.screens[side]
    local first = self.bySide[side][1]
    local name = first and first.name or ("side " .. side)
    if screens.lightScreen > 0 then
      screens.lightScreen = screens.lightScreen - 1
      if screens.lightScreen == 0 then self:_say(name .. "'s LIGHT SCREEN fell") end
    end
    if screens.reflect > 0 then
      screens.reflect = screens.reflect - 1
      if screens.reflect == 0 then self:_say(name .. "'s REFLECT faded") end
    end
  end
end

-- Per seat, in field order: ResidualDamage's poison / burn and LEECH SEED
-- (core.asm:1005-1110) and HandleWrap (:1210-1270), each a
-- SubtractHPFromUser -- straight off the HP, a substitute never asked -- and
-- the Bide and Disable counters.
function Battle:_residualDamage()
  for _, fighter in ipairs(self.fighters) do
    if self.result then return end
    local mon = activeMon(fighter)
    if mon and mon.status then
      local amount = Status.residual({
        status = mon.status, maxHp = mon.maxHp, toxicCounter = mon.toxicCounter,
      })
      if amount then
        -- HurtByPoisonText for PSN and badly poisoned alike.
        local label = mon.status == "toxic" and "poison" or mon.status
        if mon.status == "toxic" then mon.toxicCounter = mon.toxicCounter + 1 end
        self:_say(mon.species .. " is hurt by its " .. label)
        self:_damage(fighter, mon, amount, mon.status, true)
      end
    end
    if self.result then return end
    -- HandleWrap: a wrapped monster with no substitute of its own (`ret nz`
    -- before the count moves) loses a turn off the count; at 0 it is
    -- released, otherwise it takes a sixteenth of its max HP
    -- (GetSixteenthMaxHP, Items.sixteenth), under the trapping move's name.
    -- The count began at 3..6 (Effects.wrapCount) and its first tick is the
    -- end of the turn the trap landed on.
    mon = activeMon(fighter)
    if mon and mon.trapped and mon.trapped.turns > 0 and int(mon.substitute, 0) <= 0 then
      local trap = mon.trapped
      local label = trap.label or "the trap"
      trap.turns = trap.turns - 1
      if trap.turns <= 0 then
        mon.trapped = nil
        self:_say(mon.species .. " was released from " .. label)
      else
        self:_say(mon.species .. " is hurt by " .. label)
        self:_damage(fighter, mon, Items.sixteenth(mon.maxHp), nil, true)
      end
    end
    mon = activeMon(fighter)
    if mon and mon.bide and mon.bide.turns > 0 then
      mon.bide.turns = mon.bide.turns - 1
    end
    if self.result then return end
    mon = activeMon(fighter)
    if mon and mon.leechSeed then
      -- GetEighthMaxHP (Items.eighth) through SubtractHPFromUser, then
      -- RestoreHP on the seat opposite with the bc SubtractHP hands back: the
      -- whole eighth, or -- when it outran the HP left -- just that HP
      -- (SubtractHP's underflow reloads bc with what the HP held).  The
      -- seeder's seat is read before the sap: a sap that knocks the seeded
      -- monster out faints it, and `_faint` clears its leechSeed.  The seeder
      -- is still healed (ResidualDamage's RestoreHP comes before its
      -- HasUserFainted check).
      local amount = Items.eighth(mon.maxHp)
      local taken = min(amount, mon.hp)
      local from = mon.leechSeed.fromSlot
      self:_say(mon.species .. " is seeded")
      self:_damage(fighter, mon, amount, nil, true)
      local seeder = from and self:_fighterAtSlot(from)
      local sMon = seeder and activeMon(seeder)
      if sMon and sMon.hp > 0 then self:_heal(seeder, sMon, taken) end
    end
    if self.result then return end
    mon = activeMon(fighter)
    if mon and mon.disable and mon.disable.turns > 0 then
      mon.disable.turns = mon.disable.turns - 1
      if mon.disable.turns <= 0 then
        local idx = mon.disable.moveIndex
        local cleared = mon.moves[idx]
        mon.disable = nil
        if cleared and cleared.id then
          self:_say(moveLabel(cleared) .. " is no longer disabled")
        end
      end
    end
  end
end

-- ------------------------------------------------------------------
-- endings
-- ------------------------------------------------------------------

function Battle:_checkOver()
  if self.result then return true end
  local aliveA, aliveB = self:_sideAlive("a"), self:_sideAlive("b")
  if aliveA and aliveB then return false end

  if not aliveA and not aliveB then
    self:_finish("draw", nil, nil, "ko")
  elseif aliveA then
    self:_payDayOutcome(self:_finish("win", self:_sidePlayers("a"), self:_sidePlayers("b"), "ko"))
  else
    self:_finish("win", self:_sidePlayers("b"), self:_sidePlayers("a"), "ko")
  end
  return true
end

-- CheckPayDay (pokecrystal engine/battle/core.asm:8326-8360, pokegold the
-- same), which `.HandleEndOfBattle` runs only outside a link battle and only
-- on a WIN -- a knockout, or a catch, which leaves wBattleResult there (a flee
-- and a Poke Doll are a DRAW): the fight's one wPayDayMoney is the player's,
-- the coins the computer's own PAY DAY scattered included.  Contract K11: it
-- rides the outcome as `payDay` on side a's win against the computer
-- (BADGE_MODES), never in a link fight; the Amulet Coin doubling and the
-- wallet are the client's.
function Battle:_payDayOutcome(result)
  if type(result) ~= "table" or not M.BADGE_MODES[self.mode] then return end
  if self.payDay > 0 then result.payDay = self.payDay end
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

-- ------------------------------------------------------------------
-- a level gained mid-fight (contract K9)
-- ------------------------------------------------------------------
--
-- `levelUp(playerId, monIndex, level, stats, maxHp)`: a monster of the seat's
-- party (1-based `monIndex`, the hubs' `payload.mon + 1`) grew, as the client
-- that owns it reports with `mmo.battle_moveset` -- `stats` the engine's
-- unboosted party stats in the Gold dialect (atk def spe spa spd), `maxHp` the
-- new maximum, `level` the new level, each optional.  Rebuilt as
-- GiveExperiencePoints does it in battle (pokecrystal engine/battle/
-- core.asm:7186-7300):
--
--   * the party's stats become the new ones -- CalcMonStats (Effects.
--     calcMonStats over the sheet's K7 blocks) when the report states a
--     level and no stats -- and the party HP rises by the max-HP step (it can
--     fall with a smaller max, never below 1; a fainted monster stays down);
--   * the fielded monster's battle HP and max HP are the party's (the
--     referee holds one), its level the new one, and its battle stats are
--     rebuilt in the routine's order: ApplyStatLevelMultiplierOnAllStats over
--     wPlayerStats, then ApplyStatusEffectOnPlayerStats, then BadgeStatBoosts
--     (Effects.calcStats "init").  A transformed monster keeps the copied
--     wPlayerStats -- the routine skips that copy under SUBSTATUS_TRANSFORMED
--     -- so its party stats change behind the Transform (`preTransform`) and
--     its battle stats are rebuilt from the copied ones;
--   * a benched monster changes in its party stats alone, which its next
--     send-out loads.
--
-- The claim is the client's; the referee only refuses what cannot be a
-- level-up: an unknown seat or monster, a level below the current one or
-- past LEVEL_MAX, a malformed stat block, a finished fight, or a report that
-- changes nothing.  Never raises; returns whether anything changed.
function Battle:levelUp(playerId, monIndex, level, stats, maxHp)
  if self.result then return false end
  local fighter = self.byId[str(playerId) or ""]
  if not fighter then return false end
  local index = int(monIndex, nil)
  local mon = index and fighter.mons[index] or nil
  if not mon then return false end

  local newLevel = mon.level
  if level ~= nil then
    newLevel = int(level, nil)
    if newLevel == nil or newLevel < mon.level or newLevel > M.LEVEL_MAX then return false end
  end
  local partyStats = nil
  if stats ~= nil then
    if type(stats) ~= "table" then return false end
    partyStats = {}
    for _, key in ipairs(Effects.STAT_KEYS) do
      local value = int(stats[key], nil)
      if value == nil then return false end
      partyStats[key] = max(1, min(Effects.MAX_STAT_VALUE, value))
    end
  end
  local newMax = nil
  if maxHp ~= nil then
    newMax = int(maxHp, nil)
    if newMax == nil then return false end
    newMax = max(1, min(Damage.WORD_MAX, newMax))
  end
  if not partyStats and level ~= nil then
    local saved = mon.preTransform
    local computed = Effects.calcMonStats(mon.base, saved and saved.dvs or mon.dvs,
      mon.statExp, newLevel)
    if computed then
      partyStats = computed.stats
      newMax = newMax or computed.maxHp
    end
  end
  if newLevel == mon.level and not partyStats and newMax == nil then return false end

  mon.level = newLevel
  if partyStats then
    if mon.transformed and mon.preTransform then
      mon.preTransform.stats = partyStats
    elseif not mon.transformed then
      mon.stats = partyStats
    end
  end
  if newMax ~= nil then
    local step = newMax - mon.maxHp
    mon.maxHp = newMax
    if mon.hp > 0 then mon.hp = max(1, min(newMax, mon.hp + step)) end
  end
  if activeMon(fighter) == mon then
    Effects.snapStats(mon, fighter.badges, Effects.calcStats(mon, fighter.badges, "init"))
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
  -- does not swallow a whole recharge / rampage / charge chain. Keep the flag
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
  -- The same sweep covers the replace phase: `_autoChoice` answers a
  -- `mustReplace` seat with a bench switch (it is the branch the NPC side
  -- takes), so an unanswered replacement fills like an unanswered move,
  -- `_maybeResolve` closes the phase, and the fight carries on one monster down
  -- rather than wedging.
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
