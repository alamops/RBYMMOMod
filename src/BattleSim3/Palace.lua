-- The Battle Palace: Turn.create's `rules.palace` (contract C3 of
-- docs/plans/gen3-solo-remaining-fights.md, research §1.4; pokeemerald
-- BATTLE_TYPE_PALACE, the Verdanturf Battle Tent too).
--
-- On the cart neither trainer picks a move: FIGHT skips the move menu and each
-- battler's controller runs ChooseMoveAndTargetInBattlePalace (pokeemerald/
-- src/battle_gfx_sfx_util.c:109) -- a move group drawn by nature from the
-- cart's gBattlePalaceNatureToMoveGroupLikelihood, the AI scoring inside it,
-- a random fallback out of it that fails half the time, GetBattlePalaceTarget
-- in a double.  That pick is the client's (K-FAC2, the player's cart's tables
-- through the engine); it reaches the referee as an ordinary fight choice:
--
--   { action = "fight", move = <slot, 0-based>, target = <field slot>? }
--       the pick -- accepted even when the slot is one the move menu would
--       refuse (disabled, tormented, taunted, sealed, Choice-locked, out of
--       PP): the cart lets the nature land on it and fail at selection by
--       TrySetCantSelectMoveBattleScript's Palace arm (battle_util.c:975)
--   { action = "fight", unable = true }
--       the controller's own failure: the out-of-group fallback whose
--       `Random() % 100 >= 50` failed (battle_gfx_sfx_util.c:255), or every
--       move unusable (:260 -- out of reach: AreAllMovesUnusable files
--       Struggle first, battle_main.c:4184).  It returns chosen move 0 and
--       target 0, so the referee files slot 1 aimed at field slot 0, and
--       the selection check still reads slot 1's move.
--
-- Struggle and an Encore come first, as on the cart (the controller is never
-- asked: battle_main.c:4184-4197); a lock-in never chooses at all.
--
-- A pick the selection check fails carries `palace` on the normalised choice:
-- the selection script it set (`disabled`, `torment`, `taunt`, `sealed` -- the
-- last of the four that applies, as each one overwrites gPalaceSelection-
-- BattleScripts) or `unable` (palaceUnableToUseMove with no script: the
-- client's own failure, a Choice lock, an empty slot's PP).  When its turn
-- comes HandleAction_UseMove (battle_util.c:263) runs the failure instead of
-- the move -- no canceller (no sleep or freeze roll of the ordinary kind, no
-- flinch, confusion, paralysis, love or Truant), no PP, no OBEYS:
--   a selection script prints its line ("<X>'s <move> is disabled!", ...)
--     and the move end (battle_scripts_1.s:3368 / :3572 / :3585 / :3658);
--   `unable` runs BattleScript_MoveUsedLoafingAround's Palace arm (:4232):
--     palacetryescapestatus (battle_util2.c:126 -- a sleeper's counter ticks
--     and it stays asleep, "is fast asleep", or wakes, "woke up!"; a frozen
--     battler thaws one time in five, Random() % 5, or stays "frozen solid";
--     a battler still asleep or frozen ends there), then "<X> appears
--     incapable of using its power!" (B_MSG_INCAPABLE_OF_POWER) -- the
--     `palace` event `unable` and our `msg`.
-- Pursuit on a switching foe is the one move that still runs: HandleAction_
-- Switch reads only the chosen move (battle_script_commands.c:8740).
--
-- The half-HP line (VARIOUS_PALACE_FLAVOR_TEXT, battle_script_commands.c:
-- 6384), once a battler's stay on the field: at every turn's end
-- (BattleTurnPassed, battle_main.c:4015 -- after the replacements, never
-- before turn 1), in battler order, a battler at or under half its max HP,
-- not asleep and not yet flagged gets its bit (gBattleStruct->palaceFlags) and
-- the line its nature names: sBattlePalaceNatureToFlavorTextId is the cart's,
-- handed in as `rules.palace.flavor` (25 entries, nature 0..24 in order, each
-- 0..3 -- the engine's f2_data.palace().flavorTextId); the `palace` event
-- `flavor` carries the line's index (gBattlePalaceFlavorTextTable) and our
-- `msg` follows.  A battler that switches in already at or under half (not
-- asleep) gets the bit silently (switchindataupdate, :4659) -- the bit picks
-- the low-HP half of the cart's move-group table, so the client reads it
-- through `Battle:palaceLow(slot)`.
--
-- RNG: palacetryescapestatus's draws only, as the canceller's -- a sleeper
-- with no counter roll(0,3), a frozen battler roll(0,4) -- plus a random-
-- target move's roll(0,n-1) over two or more foes, which HandleAction_UseMove
-- draws before it fails (battle_util.c:177 / :221).
--
-- Nothing here raises; no love, no engine modules, no mod facade.

local need = ...
local Status    = need("BattleSim3/Status")
local Abilities = need("BattleSim3/Abilities")
local Items     = need("BattleSim3/Items")
local Move      = need("BattleSim3/Move")

local M = {}

local floor = math.floor

local function int(value, fallback)
  local n = tonumber(value)
  if not n or n ~= n then return fallback end
  return floor(n)
end

M.NATURES = 25         -- pret NUM_NATURES
M.FLAVOR_MAX = 3       -- gBattlePalaceFlavorTextTable holds four lines, 0..3
M.MOVE_STRUGGLE = 165  -- pret MOVE_STRUGGLE (the Torment check skips it)

-- The selection scripts' tokens, in TrySetCantSelectMoveBattleScript's order.
M.SCRIPTS = { disabled = true, torment = true, taunt = true, sealed = true }
-- What a normalised Palace choice may carry in `palace`.
M.TOKENS = { disabled = true, torment = true, taunt = true, sealed = true, unable = true }

-- gBattlePalaceFlavorTextTable, by index (pokeemerald src/battle_message.c:
-- 1383-1386: B_MSG_GLINT_IN_EYE, GETTING_IN_POS, GROWL_DEEPLY, EAGER_FOR_MORE),
-- in our words; the screen speaks the cart's line for the index.
M.FLAVOR_TEXT = {
  [0] = "A glint appears in %s's eyes!",
  [1] = "%s is getting into position!",
  [2] = "%s began growling deeply!",
  [3] = "%s is eager for more!",
}

M.REFUSED = "rules.palace needs the cart's flavor table (25 natures)"

-- `rules.palace` read: { flavor = { 25 integers 0..3 } } -> the normalised
-- table, nil (absent / false: no Palace), or nil plus the refusal.
function M.options(raw)
  if raw == nil or raw == false then return nil end
  if type(raw) ~= "table" or type(raw.flavor) ~= "table" then return nil, M.REFUSED end
  local flavor = {}
  for i = 1, M.NATURES do
    local v = raw.flavor[i]
    if type(v) ~= "number" or v ~= floor(v) or v < 0 or v > M.FLAVOR_MAX then
      return nil, M.REFUSED
    end
    flavor[i] = v
  end
  return { flavor = flavor }
end

-- pokeemerald/src/battle_util.c:975 TrySetCantSelectMoveBattleScript, the
-- BATTLE_TYPE_PALACE arm: the token a pick of `slot` fails with, or nil.
-- `unable` is the controller's own failure (the choice's `unable`).
function M.selection(B, b, slot, unable)
  local mv = b.moves[slot]
  if not mv then return nil end
  local n = int(mv.num, 0)
  local token = nil
  if b.disabledNum and n == b.disabledNum and n ~= 0 then token = "disabled" end
  if b.tormented and n == b.lastMoveNum and n ~= M.MOVE_STRUGGLE then token = "torment" end
  if int(b.tauntTurns, 0) > 0 and int(mv.power, 0) == 0 then token = "taunt" end
  if B:isImprisoned(b, n) then token = "sealed" end
  if token then return token end
  if Items.of(b) == Items.HOLD.CHOICE_BAND and b.choicedMove and b.choicedMove ~= n then
    unable = true
  end
  if int(mv.pp, 0) <= 0 then unable = true end
  if unable then return "unable" end
  return nil
end

-- The low-HP test the cart runs at a switch-in and at a turn's end:
-- maxHP / 2 >= hp, hp != 0, not asleep.
local function lowHp(b)
  local mon = b.mon
  return mon.hp > 0 and floor(mon.maxHp / 2) >= mon.hp and Status.normalise(mon.status) ~= "SLP"
end
M.lowHp = lowHp

-- ------------------------------------------------------------------
-- the battle (installed)
-- ------------------------------------------------------------------

local Bp = {}

-- pokeemerald/src/battle_script_commands.c:4659: a switch-in at or under half
-- HP sets its bit silently (SwitchInClearSetData cleared it, battle_main.c:
-- 3240 -- a fresh battler table here).
function Bp:_palaceSwitchIn(nb)
  if self.rules.palace and nb and lowHp(nb) then nb.palaceLow = true end
end

-- Whether the battler on this field slot has its Palace bit (the low-HP half
-- of the cart's move-group table): the client's pick reads it.
function Bp:palaceLow(slot)
  local f = self:_fighterAtSlot(int(slot, -1))
  local b = f and f.b
  return b ~= nil and b.palaceLow == true
end

-- pokeemerald/src/battle_script_commands.c:6384 VARIOUS_PALACE_FLAVOR_TEXT,
-- every battler in battler order (BattleScript_PalacePrintFlavorText).
function Bp:_palaceFlavor()
  local palace = self.rules.palace
  if not palace then return end
  for _, f in ipairs(self.order) do
    local b = f.b
    if b and not b.palaceLow and lowHp(b) then
      b.palaceLow = true
      local nature = int(b.mon.nature, 0)
      local id = palace.flavor[nature + 1] or 0
      self:_emit("palace", { slot = b.slot, side = b.side, text = "flavor", amount = id })
      self:say((M.FLAVOR_TEXT[id] or M.FLAVOR_TEXT[0]):format(self:nameOf(b)))
    end
  end
end

-- pokeemerald/src/battle_util2.c:126 BattlePalace_TryEscapeStatus, through
-- the canceller's own sleep and freeze steps (Move.lua canceller).  True when
-- the battler is still asleep or frozen: the action ends there.
function Bp:_palaceEscapeStatus(user)
  local nm = self:nameOf(user)
  if Status.normalise(user.mon.status) == "SLP" then
    if self:uproarActive() and user.ability ~= "SOUNDPROOF" then
      user.nightmare = nil
      self:cure(user, nm .. " woke up in the UPROAR!")
    else
      local turns = int(user.mon.sleepTurns, 0)
      if turns <= 0 then turns = Status.sleepTurns(self.rng) end
      local left, woke = Status.sleepTick(turns, user.ability == "EARLY_BIRD")
      user.mon.sleepTurns = left
      if not woke then
        self:say(nm .. " is fast asleep.")
        return true
      end
      user.nightmare = nil
      self:cure(user, nm .. " woke up!")
    end
    return false
  end
  if Status.normalise(user.mon.status) == "FRZ" then
    if self:roll(0, Status.THAW_ROLL_MAX) ~= 0 then
      self:say(nm .. " is frozen solid!")
      return true
    end
    self:cure(user, nm .. " was defrosted!")
  end
  return false
end

-- A Palace pick that failed at selection, when its turn comes (header).
function Bp:_palaceUnable(fighter, choice)
  local user = fighter.b
  if not user or user.mon.hp <= 0 then return end
  local token = choice.palace
  -- gCurrentMove: the slot's move, an Encore that came since overriding it
  -- (battle_util.c:112), for the selection scripts' B_CURRENT_MOVE.
  local row = user.moves[choice.move] or Move.STRUGGLE
  if int(user.encoreTurns, 0) > 0 and user.encoreNum then
    local s = self:slotOfNum(user, user.encoreNum)
    if s then row = user.moves[s] end
  end
  -- HandleAction_UseMove picks a random-target move's target before it fails
  -- (battle_util.c:221): the draw, nothing aimed.
  if int(row.target, 0) == Move.TARGET.RANDOM then self:_pickTarget(user, row, nil, false, false) end
  user.movedThisTurn = true
  local nm = self:nameOf(user)
  if token == "torment" then
    -- battle_util.c:1001: the Torment arm cancels the multi-turn state as it
    -- sets the script.
    self:cancelMultiTurn(user)
    self:say(nm .. " can't use the same move in a row due to the TORMENT!")
  elseif token == "disabled" then
    self:say(nm .. "'s " .. self:moveLabel(row) .. " is disabled!")
  elseif token == "taunt" then
    self:say(nm .. " can't use " .. self:moveLabel(row) .. " after the TAUNT!")
  elseif token == "sealed" then
    self:say(nm .. " can't use the sealed " .. self:moveLabel(row) .. "!")
  elseif not self:_palaceEscapeStatus(user) then
    self:_emit("palace", { slot = user.slot, side = user.side, text = "unable" })
    self:say(nm .. " appears incapable of using its power!")
  end
  -- No OBEYS: MOVEEND_UPDATE_LAST_MOVES stores MOVE_UNAVAILABLE, and the move
  -- end runs as after a canceller stop (Move.lua moveEndLite).
  user.lastMoveNum = nil
  user.lastResultingNum = nil
  Abilities.immunityCure(self)
  Items.moveEnd(self)
end

function M.install(Battle)
  for k, v in pairs(Bp) do Battle[k] = v end
end

return M
