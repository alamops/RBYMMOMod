-- The Battle Arena: Turn.create's `rules.arena = true` (contract C3 of
-- docs/plans/gen3-solo-remaining-fights.md, research §1.4; pokeemerald
-- BATTLE_TYPE_ARENA, the Fallarbor Battle Tent too).  A one-on-one trainer
-- fight (a single seat a side, never a wild one) with four rules of its own:
--
--   * No switching: the party menu refuses the swap (battle_main.c:4243,
--     PARTY_ACTION_CANT_SWITCH), Baton Pass and Roar / Whirlwind fail
--     (battle_scripts_1.s:1698 / :601), and the AI never switches
--     (battle_ai_switch_items.c:452).
--   * A battler down is replaced at once and in party order: the controllers
--     answer gBattlerPartyIndexes + 1 with no menu (battle_controller_
--     player.c:2672, battle_ai_switch_items.c:648), right after the action
--     that felled it (HandleAction_TryFinish -> HandleFaintedMonActions,
--     battle_util.c:638) or after the end of turn.  With nothing switching,
--     the mons go out in order, so "the next one" is the first living,
--     unjudged party member (`benchOf(...)[1]`).
--   * The judge (battle_util.c:1856, HandleWishPerishSongOnTurnEnd case 2):
--     at the end of the third turn of a pairing (gBattleStruct->
--     arenaTurnCounter == 2 -- 0 at the start, 0xFF at every switch-in, one
--     more as each turn passes, BattleTurnPassed battle_main.c:3998) with
--     both battlers standing, their multi-turn moves are cancelled and three
--     categories are scored (battle_arena.c:511 ShowJudgmentSprite): 2 points
--     to the better, 1 each on a tie --
--       Mind   the moves each battler used this pairing, by the cart's per-
--              move rating (sMindRatings, battle_arena.c:58: Sheet3 stamps
--              it on each move row as `arenaMind`; a row without it -- a
--              called move, Struggle -- takes the rule the table follows
--              exactly: a damaging move 1 but Counter / Mirror Coat / Bide 0
--              and Fake Out -1, a status move 0 but Protect / Detect / Endure
--              -1), added as the move action starts (battle_util.c:288);
--       Skill  the move results (BattleArena_AddSkillPoints, :588, at each
--              move script's Cmd_end, only when the move got past
--              obedience): an earlier "already <status>" attempt -2; a move
--              that missed, did not affect or failed -2 unless the foe
--              protected; super effective +2; not very effective -1; else
--              +1, unless the user protected itself; and -3 for every
--              ability line that stopped the user's move
--              (BattleArena_DeductSkillPoints, :624);
--       Body   HP left over HP at the pairing's start, as a percentage.
--     The higher total wins; the loser "faints" (battle_scripts_1.s:4472)
--     but keeps its HP and status in the party (VARIOUS_ARENA_*_MON_LOST
--     zero the battler alone, battle_script_commands.c:6409) and counts as
--     down for good (Cmd_checkteamslost skips it, :3557); a tie judges both.
--     A judgment that empties a side ends the fight `how = "judge"`.
--   * Points restart at every switch-in (BattleArena_InitPoints, battle_
--     script_commands.c:4697, from both battlers' HP then), and the referee
--     says "Commence battling!" when a pairing's first turn is about to open
--     (BattleScript_ArenaTurnBeginning: battle start, battle_main.c:3928,
--     and every counter wrap to 0, :4018).
--
-- Events: `arena` (events.lua) -- `start`; `judge`; `mind` / `skill` / `body`
-- for side a then side b, amount = 2 / 1 / 0; `win` (side) or `draw` -- then
-- the referee's result line (our `msg`) and the loser's `faint`.  The outcome
-- of a judged fight lists the judged mons by sheet slot: `judged = { a = {..},
-- b = {..} }`.
--
-- RNG: none.  Nothing here raises; no love, no engine modules, no mod facade.

local need = ...
local Effects = need("BattleSim3/Effects")

local M = {}

local floor, max = math.floor, math.max

local function int(value, fallback)
  local n = tonumber(value)
  if not n or n ~= n then return fallback end
  return floor(n)
end

local E = Effects.E

M.COUNTER_WRAP = 256   -- gBattleStruct->arenaTurnCounter is a u8
M.SWITCHED_IN = 0xFF   -- SwitchInClearSetData (battle_main.c:3258)
M.JUDGE_AT = 2         -- battle_util.c:1857
M.ALREADY_PENALTY = 2  -- battle_arena.c:598
M.DEDUCT = 3           -- battle_arena.c:649
M.REFILL_CAP = 12      -- replacement passes a resolution may run (a party of six, twice)
M.CATEGORIES = { "mind", "skill", "body" }

-- sMindRatings (battle_arena.c:58) for one move row: the cart's own rating
-- when the sheet stamped it, else the rule the table follows exactly.
function M.mindRating(row)
  if type(row) ~= "table" then return 0 end
  local stamped = int(row.arenaMind, nil)
  if stamped then return stamped end
  local eff, power = int(row.effect, 0), int(row.power, 0)
  if power ~= 0 then
    if eff == E.COUNTER or eff == E.MIRROR_COAT or eff == E.BIDE then return 0 end
    if eff == E.FAKE_OUT then return -1 end
    return 1
  end
  if eff == E.PROTECT or eff == E.ENDURE then return -1 end
  return 0
end

-- ShowJudgmentSprite's award for one side of one category.
function M.points(mine, theirs)
  if mine > theirs then return 2 end
  if mine == theirs then return 1 end
  return 0
end

-- BattleArena_AddSkillPoints' change for one finished move action (`act`:
-- the result the action's move contexts folded, `already` the battler's
-- alreadyStatusedMoveAttempt bit, `protected` its own Protect this turn).
function M.skillDelta(act, already, protected)
  if already then return -M.ALREADY_PENALTY end
  if act.noEffect then
    if act.protectedMiss then return 0 end
    return -2
  end
  if act.super and act.notVery then return 1 end
  if act.super then return 2 end
  if act.notVery then return -1 end
  if protected then return 0 end
  return 1
end

-- ------------------------------------------------------------------
-- the battle (installed)
-- ------------------------------------------------------------------

local Ba = {}

local function sideBattler(B, side)
  local f = B.bySide[side][1]
  return f and f.b or nil
end

function Ba:_arenaNew()
  self.arenaState = {
    counter = 0,
    mind = { a = 0, b = 0 }, skill = { a = 0, b = 0 }, hpStart = { a = 0, b = 0 },
    already = {}, judged = { a = {}, b = {} },
  }
  self:_arenaInitPoints()
end

-- BattleArena_InitPoints: both sides' points to 0, HP at start from the
-- battlers standing now (0 for a seat still empty).
function Ba:_arenaInitPoints()
  local st = self.arenaState
  for _, side in ipairs({ "a", "b" }) do
    local b = sideBattler(self, side)
    st.mind[side], st.skill[side] = 0, 0
    st.hpStart[side] = b and b.mon.hp or 0
  end
end

-- Every switch-in (Turn.lua `_switchIn`): the counter to 0xFF, points anew.
function Ba:_arenaSwitchedIn()
  local st = self.arenaState
  if not st then return end
  st.counter = M.SWITCHED_IN
  self:_arenaInitPoints()
end

-- HandleAction_UseMove's Mind points and the action's result record, opened
-- for the move contexts the action resolves to fold into (`_arenaFold`).
function Ba:_arenaAct(user, row)
  local st = self.arenaState
  if not st then return nil end
  st.mind[user.side] = st.mind[user.side] + M.mindRating(row)
  local act = { user = user }
  self.arenaAct = act
  return act
end

-- One move context's result, ORed into the action's (gMoveResultFlags is one
-- value for the whole action on the cart, called moves included).  The
-- referee's own failure marks stand for the cart's flags; `resMissed` /
-- `resProtected` add the ones it does not keep, `resClear` drops a failure
-- the cart leaves unflagged (Move.lua / Effects.lua name each site).
function Ba:_arenaFold(C)
  local act = self.arenaAct
  if not act then return end
  if C.obeys then act.obeys = true end
  if (C.failed or C.noEffect or C.missed or C.resMissed) and not C.resClear then
    act.noEffect = true
  end
  if C.resProtected then act.protectedMiss = true end
  if C.resSuper then act.super = true end
  if C.resNotVery then act.notVery = true end
end

-- Cmd_end: BattleArena_AddSkillPoints for the action's user (the attacker
-- the move end swapped back).
function Ba:_arenaSkill(act)
  if self.arenaAct == act then self.arenaAct = nil end
  local st = self.arenaState
  if not st or not act or not act.obeys then return end
  local side = act.user.side
  local already = st.already[side]
  st.already[side] = nil
  st.skill[side] = st.skill[side] + M.skillDelta(act, already, act.user.protected == true)
end

-- BattleArena_DeductSkillPoints: one of the nineteen ability lines printed
-- through this battler's controller (the attacker at the time).
function Ba:_arenaDeduct(b)
  local st = self.arenaState
  if not st or not b then return end
  st.skill[b.side] = st.skill[b.side] - M.DEDUCT
end

-- VARIOUS_SET_ALREADY_STATUS_MOVE_ATTEMPT (BS_ATTACKER).
function Ba:_arenaAlready(b)
  local st = self.arenaState
  if not st or not b then return end
  st.already[b.side] = true
end

-- HandleFaintedMonActions' replacements, in party order, every seat owed one
-- in battler order, until none is (a newcomer felled by Spikes is owed again).
function Ba:_arenaRefill()
  if not self.arenaState then return end
  for _ = 1, M.REFILL_CAP do
    local did = false
    for _, fighter in ipairs(self.order) do
      if self.result then return end
      if fighter.mustReplace then
        local index = self:benchOf(fighter)[1]
        if index then
          did = true
          -- battle_script_commands.c:5261: the replacement for a judged loser
          -- keeps a Truant counter of 0 (truantSwitchInHack).
          local hack = fighter.truantHack
          fighter.truantHack = nil
          local nb = self:_switchIn(fighter, index)
          self:switchInEffects(nb, { spikes = true, noTruant = hack })
          self:_faintSweep()
          self:_drainExp()
          if not self.result then self:_checkOver() end
        end
      end
    end
    if not did then return end
  end
end

-- The end of a turn (BattleTurnPassed): the replacements, a delayed hit that
-- waited for one, then the judge (HandleWishPerishSongOnTurnEnd case 2) and
-- the judged losers' replacements.
function Ba:_arenaTurnEnd()
  if not self.arenaState or self.result then return end
  self:_arenaRefill()
  if not self.result then self:_landPendingFutureSight() end
  if not self.result then self:_arenaJudge() end
  if not self.result then self:_arenaRefill() end
end

-- One category's points, side a's then side b's.
function Ba:_arenaCategory(cat)
  local st = self.arenaState
  if cat == "body" then
    local a, b = sideBattler(self, "a"), sideBattler(self, "b")
    local pa = floor(a.mon.hp * 100 / max(1, st.hpStart.a))
    local pb = floor(b.mon.hp * 100 / max(1, st.hpStart.b))
    return pa, pb
  end
  return st[cat].a, st[cat].b
end

-- pokeemerald/src/battle_util.c:1856 and BattleScript_ArenaDoJudgment.
function Ba:_arenaJudge()
  local st = self.arenaState
  if not st or st.counter ~= M.JUDGE_AT then return end
  local fa, fb = self.bySide.a[1], self.bySide.b[1]
  local a, b = fa.b, fb.b
  if not (a and a.mon.hp > 0 and b and b.mon.hp > 0) then return end
  self:cancelMultiTurn(a)
  self:cancelMultiTurn(b)
  self:_emit("arena", { text = "judge" })
  local ta, tb = 0, 0
  for _, cat in ipairs(M.CATEGORIES) do
    local pa, pb = self:_arenaCategory(cat)
    local sa, sb = M.points(pa, pb), M.points(pb, pa)
    ta, tb = ta + sa, tb + sb
    self:_emit("arena", { text = cat, side = "a", slot = fa.slot, amount = sa })
    self:_emit("arena", { text = cat, side = "b", slot = fb.slot, amount = sb })
  end
  local an, bn = a.mon.species, b.mon.species
  local losers
  if ta > tb then
    self:_emit("arena", { text = "win", side = "a", slot = fa.slot })
    self:say(an .. " defeated the opponent " .. bn .. " in a REFEREE's decision!")
    losers = { b }
  elseif ta < tb then
    self:_emit("arena", { text = "win", side = "b", slot = fb.slot })
    self:say(an .. " lost to the opponent " .. bn .. " in a REFEREE's decision!")
    losers = { a }
  else
    self:_emit("arena", { text = "draw" })
    self:say(an .. " tied the opponent " .. bn .. " in a REFEREE's decision!")
    losers = { a, b }
  end
  for _, loser in ipairs(losers) do
    local list = st.judged[loser.side]
    list[#list + 1] = int(loser.mon.slot, 0)
    self:_faintBattler(loser, true)
  end
  self.judgeEnding = true
  self:_checkOver()
  self.judgeEnding = nil
end

-- BattleTurnPassed's counter (battle_main.c:3998) and "Commence battling!"
-- when it wraps to 0 (:4018).
function Ba:_arenaTurnPassed()
  local st = self.arenaState
  if not st then return end
  st.counter = (st.counter + 1) % M.COUNTER_WRAP
  if st.counter == 0 then self:_emit("arena", { text = "start" }) end
end

-- The outcome's `judged`, side by side, only for a side that lost one.
function Ba:_arenaJudged()
  local st = self.arenaState
  if not st then return nil end
  local out, any = {}, false
  for _, side in ipairs({ "a", "b" }) do
    if #st.judged[side] > 0 then
      local list = {}
      for i, v in ipairs(st.judged[side]) do list[i] = v end
      out[side] = list
      any = true
    end
  end
  if any then return out end
  return nil
end

function M.install(Battle)
  for k, v in pairs(Ba) do Battle[k] = v end
end

return M
