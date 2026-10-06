-- The computer's switches and items on Gold / Silver / Crystal: the cart's
-- AI_SwitchOrTryItem (pokecrystal / pokegold engine/battle/ai/items.asm),
-- CheckAbleToSwitch and its helpers (engine/battle/ai/switch.asm) and
-- FindMonInOTPartyToSwitchIntoBattle (engine/battle/core.asm), as a pure
-- module over the referee's battle state (contract K16 of
-- docs/plans/gen12-referee-remaining-gaps.md).  Turn calls it where the cart
-- does; this file decides, draws and applies, and keeps no state of its own.
--
-- **Where the cart calls these.**  Battle_PlayerFirst and Battle_EnemyFirst
-- (core.asm) run `SetEnemyTurn / callfar AI_SwitchOrTryItem` right after
-- DetermineMoveOrder settled the order -- before the player's move in the
-- first, at the enemy's own slot in the second -- and a carry back (an item
-- used, a switch made) replaces the enemy's move for the turn.
-- FindMonInOTPartyToSwitchIntoBattle picks the computer's successor after a
-- faint (EnemyPartyMonEntrance -> EnemySwitch / EnemySwitch_SetMode ->
-- CheckWhetherSwitchmonIsPredetermined), outside a link battle.
--
-- **The quirks reproduced, each where its routine is:**
--
--   * "AI makes a false assumption about CheckTypeMatchup"
--     (docs/bugs_and_glitches.md): every type check in switch.asm loads a
--     move's or a monster's type into `a` and calls CheckTypeMatchup, which
--     overwrites `a` with BATTLE_VARS_MOVE_TYPE.  With hBattleTurn 1 (the
--     SetEnemyTurn above) that is the type in wEnemyMoveStruct -- the move
--     ParseEnemyAction loaded for this turn -- so every matchup the switch
--     logic reads is THAT type against some pair of defending types
--     (`M.typeMatchup` with `view.moveType`).  The Foresight rows read
--     BATTLE_VARS_SUBSTATUS1_OPP, the player's, whoever is defending.
--   * "AI might use its base reward value as an item": AI_TryItem's `de`
--     walks past wEnemyTrainerItem2 into wEnemyTrainerBaseReward (`tryItem`).
--   * "AI use of Full Heal or Full Restore does not cure Nightmare status",
--     "...does not cure Attack or Speed drops from burn or paralysis", "AI use
--     of Full Heal does not cure confusion status" (`healStatus`).
--   * FindEnemyMonsWithAtLeastQuarterMaxHP's "bc = [CurHP] * 4" is `srl c /
--     rl b` twice -- not a multiply (`quarterValue`).
--   * FindEnemyMonsWithASuperEffectiveMove never clears `e` between monsters.
--   * Gold's FindEnemyMonsThatResistPlayer starts at wOTPartyCount, not
--     wOTPartySpecies (pokegold switch.asm): the count byte is read as party
--     slot 1's species and every later slot is judged by the species before
--     it (`resistTypes`).  Its FindEnemyMonsWithAtLeastQuarterMaxHP walks the
--     same list only for the terminator: one pass late, past the party, a
--     bit the living mask drops.
--   * Gold's ScoreMonTypeMatchups `.loop5` redraws under PARTY_LENGTH, not
--     wOTPartyCount (an empty slot's HP is 0 -- ReadTrainerParty's ByteFill
--     -- so the draws it spends are the same).
--   * RaiseStat (the X items) fails on a wAttackMissed / wEffectFailed the
--     last move left standing (`battle.lastAttackMissed`, below).
--   * Crystal's AI_TryItem clears wLastEnemyCounterMove after an item;
--     Gold's does not.  Crystal's Battle Tower exits are never reached here.
--
-- **What the cart reads that the referee did not keep** -- each a field
-- the hook (Turn) maintains where the cart writes it, with the default this
-- file reads when it is absent:
--
--   fighter.trainerItems   wEnemyTrainerItem1 / 2 (K16): a list, cart slot
--                          order kept; an id, "NO_ITEM" / "" / false / 0 for
--                          an empty slot, or the item's number.  Absent: no
--                          item.  A used slot becomes "NO_ITEM".
--   fighter.baseReward     wEnemyTrainerBaseReward (K16), 0..255; default 0.
--                          The bug's third byte; set to 0 when it is "used".
--   fighter.itemSwitch     TRNATTR_AI_ITEM_SWITCH (K16): its low byte is what
--                          `bit` reads; default 0 (no switch, no flags).
--   fighter.aiMove         the move in wEnemyMoveStruct (ParseEnemyAction's
--                          UpdateMoveData): a sheet move row.  Absent: the
--                          normalised fight choice's move, then NORMAL.
--   mon.turnsTaken         wEnemyTurnsTaken of the computer's active monster
--                          (BattleCommand_DoTurn's `inc`, NewEnemyMonStatus's
--                          clear); default 0.
--   foeMon.usedMoves       wPlayerUsedMoves of the player's active monster
--                          (UpdateUsedMoves, `M.recordUsedMove`; cleared by
--                          NewBattleMonStatus): up to 4 move rows (or ids,
--                          read as AiMove reads them), oldest first; default
--                          none.  AiMove reads the same field.
--   fighter.countSpeciesTypes  Gold only: the base types of the species whose
--                          number is the seat's party count, which Gold's
--                          FindEnemyMonsThatResistPlayer reads for slot 1.
--                          Absent: slot 1's own types (Crystal's reading).
--   battle.lastAttackMissed / battle.lastEffectFailed
--                          wAttackMissed / wEffectFailed as the last move left
--                          them (CheckTurn clears both); default false.
--
-- Already the referee's: `mon.perish` (wEnemyPerishCount with
-- SUBSTATUS_PERISH), `mon.toxicCounter` (wEnemyToxicCount + 1: the referee
-- counts from 1 where BattleCommand_Poison's `.toxic` writes 0),
-- `mon.lastCounterMove` (wLastPlayerCounterMove on the player's monster),
-- `mon.identified`, `mon.trapped` (wEnemyWrapCount), the MEAN LOOK hold
-- (`battle:_heldBy`), the lock-ins of CheckEnemyLockedIn.
--
-- Draws come off `battle.rng` (`:byte()`), the referee's one stream, in the
-- cart's order: SwitchOften / Rarely / Sometimes' one `Random`, then
-- AI_TryItem's routines' own, then `.loop5`'s BattleRandom redraws.  Nothing
-- else here rolls.  Item numbers below are pret's constants/item_constants.asm
-- (Gold and Crystal agree), the precedent Turn.CART_TYPES set: the
-- base-reward bug compares a byte with them.
--
-- No love, no engine modules, no mod facade.

local need = ...

local Effects = need("BattleSim2/Effects")

local M = {}

local floor, max, min = math.floor, math.max, math.min

local function int(value, fallback)
  local n = tonumber(value)
  if not n or n ~= n then return fallback end
  return floor(n)
end

-- ------------------------------------------------------------------
-- the cart's constants
-- ------------------------------------------------------------------

-- constants/battle_constants.asm, data/types/type_matchups.asm
M.BASE_AI_SWITCH_SCORE = 10
M.EFFECTIVE = 10
M.SUPER_EFFECTIVE = 11           -- `cp EFFECTIVE + 1`
M.PARTY_LENGTH = 6
M.NUM_MOVES = 4

-- TRNATTR_AI_ITEM_SWITCH's bits (constants/trainer_data_constants.asm).
M.SWITCH_OFTEN = 0x01
M.SWITCH_RARELY = 0x02
M.SWITCH_SOMETIMES = 0x04
M.ALWAYS_USE = 0x10
M.UNKNOWN_USE = 0x20
M.CONTEXT_USE = 0x40

-- The `percent` macro (macros/data.asm: `* $ff / 100`, integer).
M.PERCENT_4 = 10                 -- 4 percent
M.PERCENT_8 = 20                 -- 8 percent
M.PERCENT_12 = 30                -- 12 percent
M.PERCENT_20_MINUS_1 = 50        -- 20 percent - 1
M.PERCENT_50_PLUS_1 = 128        -- 50 percent + 1
M.PERCENT_79_MINUS_1 = 200       -- 79 percent - 1

-- SwitchOften / SwitchRarely / SwitchSometimes, by wEnemySwitchMonParam's
-- high nybble: at $10 and $20 the switch is taken under the byte; at $30
-- (and anything past it) the byte is a chance to STAY.
M.SWITCH_ODDS = {
  often     = { M.PERCENT_50_PLUS_1, M.PERCENT_79_MINUS_1, M.PERCENT_4 },
  rarely    = { M.PERCENT_8, M.PERCENT_12, M.PERCENT_79_MINUS_1 },
  sometimes = { M.PERCENT_20_MINUS_1, M.PERCENT_50_PLUS_1, M.PERCENT_20_MINUS_1 },
}

-- `.StatusCheckContext`'s `cp 4`: a toxic count of four or more.
M.TOXIC_CONTEXT_COUNT = 4

-- The guard on `.loop5` (Turn.REDRAW_LIMIT's number): the cart redraws until
-- a living bench slot comes up; a referee must never hang on trusting that.
M.REDRAW_LIMIT = 1024

-- AI_Items, in the cart's order (items.asm), with each item's number
-- (constants/item_constants.asm) and what its EnemyUsed* routine does.
M.AI_ITEMS = {
  { id = "FULL_RESTORE", num = 0x0e, routine = "fullRestore", use = "fullRestore" },
  { id = "MAX_POTION",   num = 0x0f, routine = "healItem",    use = "maxPotion" },
  { id = "HYPER_POTION", num = 0x10, routine = "healItem",    use = "potion", heal = 200 },
  { id = "SUPER_POTION", num = 0x11, routine = "healItem",    use = "potion", heal = 50 },
  { id = "POTION",       num = 0x12, routine = "healItem",    use = "potion", heal = 20 },
  { id = "X_ACCURACY",   num = 0x21, routine = "xItem",       use = "flag", flag = "xAccuracy" },
  { id = "FULL_HEAL",    num = 0x26, routine = "status",      use = "fullHeal" },
  { id = "GUARD_SPEC",   num = 0x29, routine = "xItem",       use = "flag", flag = "mist" },
  { id = "DIRE_HIT",     num = 0x2c, routine = "xItem",       use = "flag", flag = "focusEnergy" },
  { id = "X_ATTACK",     num = 0x31, routine = "xItem",       use = "stat", stat = "atk" },
  { id = "X_DEFEND",     num = 0x33, routine = "xItem",       use = "stat", stat = "def" },
  { id = "X_SPEED",      num = 0x34, routine = "xItem",       use = "stat", stat = "spe" },
  { id = "X_SPECIAL",    num = 0x35, routine = "xItem",       use = "stat", stat = "spa" },
}

local BY_ID = {}
for _, entry in ipairs(M.AI_ITEMS) do BY_ID[entry.id] = entry end

-- What a trainer item slot holds, as AI_TryItem compares it: a byte.  NO_ITEM
-- is 0; an item AI_Items does not list is a byte that is not 0 and matches no
-- row (256 stands for it); a number is taken as the item's own.
local NOT_LISTED = 256
function M.itemByte(value)
  if value == nil or value == false or value == "" or value == "NO_ITEM" then return 0 end
  if type(value) == "number" then return int(value, 0) % 256 end
  if type(value) == "string" then
    local entry = BY_ID[value]
    return entry and entry.num or NOT_LISTED
  end
  return NOT_LISTED
end

-- The battle's mode guards: AI_SwitchOrTryItem's `ld a, [wBattleMode] /
-- dec a / ret z` and `ld a, [wLinkMode] / and a / ret nz`.  The link modes
-- are Turn.LINK_MODES (mirrored, not required: Turn requires this file).
local LINK_MODES = { ["1v1"] = true, coop_pvp = true }
local PLAYER_SIDE = "a"

-- ------------------------------------------------------------------
-- byte arithmetic (the registers the routines keep their masks in)
-- ------------------------------------------------------------------

local function hasBit(value, bitValue)
  return floor(value / bitValue) % 2 == 1
end

local function setBit(value, bitValue)
  if hasBit(value, bitValue) then return value end
  return value + bitValue
end

local function clearBit(value, bitValue)
  if hasBit(value, bitValue) then return value - bitValue end
  return value
end

local function band(a, b)
  local out, bitValue = 0, 1
  for _ = 1, 8 do
    if hasBit(a, bitValue) and hasBit(b, bitValue) then out = out + bitValue end
    bitValue = bitValue * 2
  end
  return out
end

-- `sla`: the byte shifted left, and the bit that fell out as the carry.
local function sla(value)
  return (value * 2) % 256, value >= 128
end

-- The party slot (0 for $20 .. 5 for $01) of a mask's highest bit: the
-- `sla b / sla b / ld c, $ff / .loop: inc c / sla b / jr nc` idiom.
local function slotOfHighest(mask)
  local value, slot = (mask * 4) % 256, -1
  local carry = false
  repeat
    slot = slot + 1
    value, carry = sla(value)
  until carry or slot > 7
  return slot
end

-- ------------------------------------------------------------------
-- reading the referee
-- ------------------------------------------------------------------

local function activeMon(fighter)
  if not fighter or not fighter.active then return nil end
  local mon = fighter.mons[fighter.active]
  if mon and (mon.hp > 0 or mon.standing) then return mon end
  return nil
end

local function hpOf(mon)
  if type(mon) ~= "table" then return 0 end
  return max(0, int(mon.hp, 0))
end

-- A move row's base power, as GetMoveAttr MOVE_POWER reads it.
local function powerOf(move)
  if type(move) ~= "table" then return 0 end
  return max(0, int(move.power, 0))
end

-- The chart index of a type registry id (Turn's typeIndexOf over the
-- battle's `typeIds`).
local function typeIndexOf(battle, id)
  local ids = battle.typeIds
  if type(ids) ~= "table" or type(id) ~= "string" then return nil end
  for i = 1, #ids do
    if ids[i] == id then return i - 1 end
  end
  return nil
end

-- A move row's type as its data/moves row has it: the sheet's chart index,
-- or -- Struggle's sentinel -- the index of the registry id it names.
local function moveTypeOf(battle, move)
  if type(move) ~= "table" then return nil end
  if type(move.typeId) == "string" then
    local index = typeIndexOf(battle, move.typeId)
    if index then return index end
  end
  return max(0, int(move.type, 0))
end
M.moveTypeOf = moveTypeOf

-- The two type bytes a CheckTypeMatchup reads at `hl` (a single-typed
-- monster's are the same one).
local function typePair(types)
  if type(types) ~= "table" then return 0, 0 end
  local t1 = max(0, int(types[1], 0))
  local t2 = types[2] ~= nil and max(0, int(types[2], t1)) or t1
  return t1, t2
end

-- GetBaseData's BASE_TYPES for a party monster's species: the sheet's
-- types as the referee keeps them past a CONVERSION (`homeTypes`).
local function baseTypes(mon)
  if type(mon) ~= "table" then return nil end
  return mon.homeTypes or mon.types
end

-- CheckTypeMatchup (effect_commands.asm): wTypeMatchup from EFFECTIVE, times
-- each chart row that matches the attacking type and either defending type
-- byte, /10 -- the referee's chart holds percents, so x pct / 100 -- and the
-- Foresight rows (NORMAL / FIGHTING into GHOST, after the `-2`) skipped while
-- `identified` (Turn `_matchupCell`).  The result is the quotient's low byte.
function M.typeMatchup(battle, attackType, types, identified)
  local t1, t2 = typePair(types)
  local defender = { identified = identified == true }
  local value = M.EFFECTIVE
  value = floor(value * battle:_matchupCell(attackType, t1, defender) / 100) % 256
  if t2 ~= t1 then
    value = floor(value * battle:_matchupCell(attackType, t2, defender) / 100) % 256
  end
  return value
end

-- The move in wEnemyMoveStruct when AI_SwitchOrTryItem runs: ParseEnemyAction
-- loaded it (UpdateMoveData) from the move the computer chose -- `aiMove`,
-- which the hook sets -- else the filed fight choice, Struggle's own row for
-- a Struggle; none known reads as NORMAL.
local STRUGGLE_ROW = { id = "STRUGGLE", power = 50, type = 0, typeId = "NORMAL" }

local function structMoveType(battle, fighter, mon)
  local move = fighter.aiMove
  if type(move) ~= "table" then
    move = nil
    local choice = fighter.choice
    if type(choice) == "table" and choice.action == "fight" and mon then
      if choice.struggle then
        move = STRUGGLE_ROW
      else
        move = mon.moves[int(choice.move, 0)]
      end
    end
  end
  local index = moveTypeOf(battle, move)
  if index ~= nil then return index end
  return typeIndexOf(battle, "NORMAL") or 0
end

-- The WRAM a routine reads, gathered once per call: the computer's party
-- (wOTPartyCount, wCurOTMon), its active monster, the player's, and the type
-- every CheckTypeMatchup here reads.
local function viewOf(battle, fighter, foe)
  local mon = activeMon(fighter)
  local foeMon = foe and activeMon(foe) or nil
  local view = {
    battle = battle,
    fighter = fighter,
    mons = fighter.mons,
    count = min(#fighter.mons, M.PARTY_LENGTH),
    cur = fighter.active,
    mon = mon,
    foeMon = foeMon,
    gold = battle.family ~= "crystal",
    -- SUBSTATUS_IDENTIFIED on the player: BATTLE_VARS_SUBSTATUS1_OPP with
    -- hBattleTurn 1, the one every CheckTypeMatchup here reads.
    identified = foeMon ~= nil and foeMon.identified == true,
    flags = max(0, int(fighter.itemSwitch, 0)) % 256,
    score = 0,                       -- wEnemyAISwitchScore
    param = 0,                       -- wEnemySwitchMonParam
  }
  view.moveType = structMoveType(battle, fighter, mon)
  return view
end
M.viewOf = viewOf

-- The bugged CheckTypeMatchup: the struct's move type against `types`.
local function aiMatchup(view, types)
  return M.typeMatchup(view.battle, view.moveType, types, view.identified)
end

local function foeTypes(view)
  return view.foeMon and view.foeMon.types or {}
end

local function draw(view)
  return view.battle.rng:byte()
end

-- ------------------------------------------------------------------
-- switch.asm
-- ------------------------------------------------------------------

-- One wPlayerUsedMoves entry as a move row, the shape AiMove reads it in
-- (`usedMove`): a row is itself; an id is the player's monster's move of that
-- id, or a row with no power; an empty id or none ends the list (the cart's 0).
local function usedMoveRow(foeMon, entry)
  if entry == nil or entry == false then return nil end
  if type(entry) == "table" then return entry end
  local key = Effects.moveKey(entry)
  if key == "" then return nil end
  local moves = (foeMon and type(foeMon.moves) == "table") and foeMon.moves or {}
  for _, row in ipairs(moves) do
    if type(row) == "table" and Effects.moveKey(row) == key then return row end
  end
  return { id = key, power = 0, type = 0 }
end

-- CheckPlayerMoveTypeMatchups: wEnemyAISwitchScore from BASE_AI_SWITCH_SCORE,
-- down for each sign the player's used moves beat the enemy's monster, up for
-- each that they don't; then `.CheckEnemyMoveMatchups` on the enemy's moves.
-- Every matchup is the struct's type (the false assumption), so the used
-- moves' own types never matter -- only whether they have power.
function M.checkPlayerMoveTypeMatchups(view)
  local score = M.BASE_AI_SWITCH_SCORE
  local used = (view.foeMon and type(view.foeMon.usedMoves) == "table")
    and view.foeMon.usedMoves or {}
  local selfTypes = view.mon and view.mon.types or {}
  if not usedMoveRow(view.foeMon, used[1]) then
    -- `.unknown_moves`: the player's type 1, then its type 2 when it differs
    -- (`cp b`), against the enemy's types -- the same check twice.
    local t1, t2 = typePair(foeTypes(view))
    if aiMatchup(view, selfTypes) >= M.SUPER_EFFECTIVE then score = score - 1 end
    if t2 ~= t1 and aiMatchup(view, selfTypes) >= M.SUPER_EFFECTIVE then
      score = score - 1
    end
  else
    local e, broke = 0, false
    for i = 1, M.NUM_MOVES do
      local move = usedMoveRow(view.foeMon, used[i])
      if not move then break end                 -- `and a / jr z, .exit`
      if powerOf(move) > 0 then
        local matchup = aiMatchup(view, selfTypes)
        if matchup >= M.SUPER_EFFECTIVE then
          score = score - 1                       -- `.super_effective`
          broke = true
          break
        elseif matchup == 0 then
          -- immune: `.next`
        elseif matchup >= M.EFFECTIVE then
          e = 2                                   -- `.neutral`
        elseif e < 1 then
          e = 1                                   -- not very effective
        end
      end
    end
    if not broke and e ~= 2 then
      score = score + 1
      if e == 0 then score = score + 1 end
    end
  end
  -- `.CheckEnemyMoveMatchups`: the enemy's battle moves (wEnemyMonMoves) up
  -- to the first empty slot, those with power, against the player's types.
  local c = 0
  local moves = view.mon and view.mon.moves or {}
  for i = 1, M.NUM_MOVES do
    local move = moves[i]
    if not move then break end
    if powerOf(move) > 0 then
      local matchup = aiMatchup(view, foeTypes(view))
      if matchup ~= 0 then
        c = c + 1                                 -- not very effective
        if matchup >= M.EFFECTIVE then
          c = c + 5                               -- neutral
          if matchup ~= M.EFFECTIVE then c = 100 end   -- super effective
        end
      end
    end
  end
  if c == 0 then
    score = score - 2                             -- `.doubledown`
  elseif c < 5 then
    score = score - 1
  elseif c >= 100 then
    score = score + 1
  end
  view.score = score % 256
  return view.score
end

-- FindAliveEnemyMons: the living party slots other than wCurOTMon, as a mask
-- ($20 slot 1 .. $01 slot 6), and the carry -- a party of one, or nobody.
function M.findAliveEnemyMons(view)
  if view.count < 2 then return 0, true end
  local b, c = 0x20, 0
  for slot = 1, view.count do
    if slot ~= view.cur and hpOf(view.mons[slot]) > 0 then c = setBit(c, b) end
    b = floor(b / 2)
  end
  return c, c == 0
end

-- FindEnemyMonsImmuneToLastCounterMove: wEnemyAISwitchScore becomes the mask
-- of the living bench monsters (not wCurOTMon) whose base types take 0 from
-- the struct's type -- asked only while the player's last counter move has
-- power.
function M.findEnemyMonsImmuneToLastCounterMove(view)
  local mask, c = 0, 0x20
  local last = view.foeMon and view.foeMon.lastCounterMove or nil
  for slot = 1, view.count do
    local mon = view.mons[slot]
    if slot ~= view.cur and hpOf(mon) > 0 and powerOf(last) > 0
       and aiMatchup(view, baseTypes(mon)) == 0 then
      mask = setBit(mask, c)
    end
    c = floor(c / 2)
  end
  view.score = mask
  return mask
end

-- FindEnemyMonsWithASuperEffectiveMove over the slots in `c`: each one's
-- party moves (wOTPartyMon1Moves) up to the first empty one, those with
-- power, against the player's types.  A super-effective one picks its slot at
-- once (e = 2); a neutral one marks the slot (`d`), and `e` -- never cleared
-- between monsters -- keeps marking every later slot in `c` (the score reads
-- the first mark, so only the `e` handed back shows it).  The score is the
-- first marked slot (0-based), or $ff with none.  Returns `e`.
function M.findEnemyMonsWithASuperEffectiveMove(view, c)
  view.score = 0xff
  local b, d, e = 0x20, 0, 0
  local hit = nil
  for slot = 1, M.PARTY_LENGTH do
    if band(b, c) ~= 0 then
      local mon = view.mons[slot]
      local moves = (type(mon) == "table" and mon.moves) or {}
      for k = 1, M.NUM_MOVES do
        local move = moves[k]
        if not move then break end                -- `.break3`
        if powerOf(move) > 0 then
          local matchup = aiMatchup(view, foeTypes(view))
          if matchup >= M.EFFECTIVE then
            e = 1
            if matchup >= M.SUPER_EFFECTIVE then
              e = 2
              break
            end
          end
        end
      end
      if e == 2 then
        hit = b
        break
      end
      if e == 1 then d = setBit(d, b) end
    end
    b = floor(b / 2)
  end
  if not hit then
    if d == 0 then return e end
    hit = d
  end
  view.score = slotOfHighest(hit)
  return e
end

-- FindAliveEnemyMonsWithASuperEffectiveMove: `c` and every living slot
-- (wCurOTMon's too), then the routine above.
function M.findAliveEnemyMonsWithASuperEffectiveMove(view, c)
  local alive, b = 0, 0x20
  for slot = 1, view.count do
    if hpOf(view.mons[slot]) > 0 then alive = setBit(alive, b) end
    b = floor(b / 2)
  end
  return M.findEnemyMonsWithASuperEffectiveMove(view, band(alive, c))
end

-- The base types FindEnemyMonsThatResistPlayer's GetBaseData reads for
-- iteration `i` (0-based).  Crystal walks wOTPartySpecies; Gold starts at
-- wOTPartyCount, so iteration 0 reads the count as a species
-- (`countSpeciesTypes`) and iteration i the species of slot i (1-based) --
-- one behind -- for count + 1 iterations.
local function resistTypes(view, i)
  if not view.gold then return baseTypes(view.mons[i + 1]) end
  if i == 0 then
    local stated = view.fighter.countSpeciesTypes
    if type(stated) == "table" then return stated end
    return baseTypes(view.mons[1])
  end
  return baseTypes(view.mons[i])
end

-- FindEnemyMonsThatResistPlayer: `c` and the slots whose base types the
-- struct's type is not super effective against.  Both arms -- the player's
-- last counter move when it has power, else the player's two types -- end in
-- the same CheckTypeMatchup (the false assumption), so they are one test.
function M.findEnemyMonsThatResistPlayer(view, c)
  local b, out = 0x20, 0
  local iterations = view.gold and view.count + 1 or view.count
  for i = 0, iterations - 1 do
    -- (Gold's seventh pass, at six, has shifted its bit away: `b` is 0.)
    if b > 0 and aiMatchup(view, resistTypes(view, i)) < M.SUPER_EFFECTIVE then
      out = setBit(out, b)
    end
    b = floor(b / 2)
  end
  return band(out, c)
end

-- FindEnemyMonsWithAtLeastQuarterMaxHP's comparison value: "bc = [CurHP] *
-- 4" is `srl c / rl b` twice -- the low byte shifted right, its low bits
-- rolled into the high byte -- and the slot counts when that is ABOVE its max
-- HP (`cp c / sbc b`, carry).
function M.quarterValue(hp)
  hp = max(0, int(hp, 0)) % 65536
  local hi, lo = floor(hp / 256), hp % 256
  local c1 = floor(lo / 2)
  local b1 = (hi * 2 + lo % 2) % 256
  local c2 = floor(c1 / 2)
  local b2 = (b1 * 2 + c1 % 2) % 256
  return b2 * 256 + c2
end

function M.findEnemyMonsWithAtLeastQuarterMaxHP(view, c)
  local b, out = 0x20, 0
  -- Gold reads its terminator one byte late (wOTPartyCount): one more slot,
  -- past the party, whose struct ReadTrainerParty zeroed -- or, at six, a
  -- bit already shifted away.
  local iterations = view.gold and view.count + 1 or view.count
  for i = 1, iterations do
    local mon = view.mons[i]
    local maxHp = (type(mon) == "table") and max(0, int(mon.maxHp, 0)) or 0
    if b > 0 and M.quarterValue(hpOf(mon)) > maxHp then out = setBit(out, b) end
    b = floor(b / 2)
  end
  return band(out, c)
end

-- The chain CheckAbleToSwitch runs twice: the living bench, at a quarter of
-- its HP by the bug's measure, resisting, with a super-effective (or neutral)
-- move.  Returns `e`; the slot is wEnemyAISwitchScore.
local function benchChain(view)
  local c = M.findAliveEnemyMons(view)
  c = M.findEnemyMonsWithAtLeastQuarterMaxHP(view, c)
  c = M.findEnemyMonsThatResistPlayer(view, c)
  return M.findAliveEnemyMonsWithASuperEffectiveMove(view, c)
end

-- CheckAbleToSwitch: wEnemySwitchMonParam, $10 / $20 / $30 in the high
-- nybble (how strongly) and the 0-based slot in the low one, or 0.
function M.checkAbleToSwitch(view)
  view.param = 0
  local _, only = M.findAliveEnemyMons(view)
  if only then return 0 end

  local mon = view.mon
  if mon and mon.perish ~= nil and int(mon.perish, 0) == 1 then
    -- The perish count is 1: the best of the bench at the maximum chance,
    -- else the first living one.
    local e = benchChain(view)
    if e == 2 then
      view.param = (view.score + 0x30) % 256
      return view.param
    end
    local c = M.findAliveEnemyMons(view)
    view.param = 0x30 + slotOfHighest(c)
    return view.param
  end

  M.checkPlayerMoveTypeMatchups(view)
  if view.score >= M.SUPER_EFFECTIVE then return 0 end

  local last = view.foeMon and view.foeMon.lastCounterMove or nil
  if last then
    M.findEnemyMonsImmuneToLastCounterMove(view)
    if view.score ~= 0 then
      local e = M.findEnemyMonsWithASuperEffectiveMove(view, view.score)
      if view.score == 0xff then return 0 end
      local b = view.score
      if e == 2 then
        -- `.not_2_again`
        local c = 0x10
        M.checkPlayerMoveTypeMatchups(view)
        if view.score < M.BASE_AI_SWITCH_SCORE then c = 0x20 end
        view.param = (b + c) % 256
        return view.param
      end
      M.checkPlayerMoveTypeMatchups(view)
      if view.score >= M.BASE_AI_SWITCH_SCORE then return 0 end
      view.param = (b + 0x10) % 256
      return view.param
    end
  end

  -- `.no_last_counter_move`
  M.checkPlayerMoveTypeMatchups(view)
  if view.score >= M.BASE_AI_SWITCH_SCORE then return 0 end
  local e = benchChain(view)
  if e ~= 2 then return 0 end
  view.param = (view.score + 0x10) % 256
  return view.param
end

-- ------------------------------------------------------------------
-- items.asm: the decision
-- ------------------------------------------------------------------

-- AICheckEnemyHalfHP / AICheckEnemyQuarterHP (engine/battle/ai/scoring.asm):
-- carry -- above the fraction -- when the max HP is under the HP doubled
-- (quadrupled), a 16-bit `sla c / rl b`.
local function aboveHalf(mon)
  return max(0, int(mon.maxHp, 0)) < (hpOf(mon) * 2) % 65536
end

local function aboveQuarter(mon)
  return max(0, int(mon.maxHp, 0)) < (hpOf(mon) * 4) % 65536
end

local function toxicBit(mon)
  return mon.status == "toxic" or mon.toxicLatent == true
end

-- wEnemyToxicCount: the referee counts the residual's multiplier from 1.
local function toxicCount(mon)
  return max(0, int(mon.toxicCounter, 1) - 1)
end

local ROUTINES = {}

-- `.Status`: a status on the monster, then CONTEXT_USE's toxic and
-- sleep / freeze reading, ALWAYS_USE, or a byte under 20 percent - 1.
function ROUTINES.status(view)
  local mon = view.mon
  if not mon.status then return false end
  if hasBit(view.flags, M.CONTEXT_USE) then
    -- `.StatusCheckContext`
    if toxicBit(mon) and toxicCount(mon) >= M.TOXIC_CONTEXT_COUNT then
      if draw(view) < M.PERCENT_50_PLUS_1 then return true end
    end
    -- `.FailToxicCheck`
    return mon.status == "freeze" or mon.status == "sleep"
  end
  if hasBit(view.flags, M.ALWAYS_USE) then return true end
  return draw(view) < M.PERCENT_20_MINUS_1
end

-- `.HealItem`
function ROUTINES.healItem(view)
  local mon = view.mon
  if hasBit(view.flags, M.CONTEXT_USE) then
    -- `.CheckHalfOrQuarterHP`
    if aboveHalf(mon) then return false end
    if not aboveQuarter(mon) then return true end
    return draw(view) < M.PERCENT_20_MINUS_1
  end
  if aboveHalf(mon) then return false end
  if hasBit(view.flags, M.UNKNOWN_USE) then
    -- `.CheckQuarterHP`
    if aboveQuarter(mon) then return false end
    return draw(view) >= M.PERCENT_20_MINUS_1
  end
  if not aboveQuarter(mon) then return true end
  return draw(view) < M.PERCENT_50_PLUS_1
end

-- `.FullRestore`: the heal reading, else -- with CONTEXT_USE -- the status one.
function ROUTINES.fullRestore(view)
  if ROUTINES.healItem(view) then return true end
  if not hasBit(view.flags, M.CONTEXT_USE) then return false end
  return ROUTINES.status(view)
end

-- `.XItem`: the monster's first turn out (wEnemyTurnsTaken 0) -- ALWAYS_USE,
-- or a byte at 50 percent + 1 and over, then CONTEXT_USE or a second such
-- byte; after it, ALWAYS_USE and a byte under 20 percent - 1.
function ROUTINES.xItem(view)
  local turns = max(0, int(view.mon.turnsTaken, 0))
  if turns == 0 then
    if hasBit(view.flags, M.ALWAYS_USE) then return true end
    if draw(view) < M.PERCENT_50_PLUS_1 then return false end
    if hasBit(view.flags, M.CONTEXT_USE) then return true end
    if draw(view) < M.PERCENT_50_PLUS_1 then return false end
    return true
  end
  if not hasBit(view.flags, M.ALWAYS_USE) then return false end
  return draw(view) < M.PERCENT_20_MINUS_1
end

-- `.IsHighestLevel`: wCurOTMon's level at or over every party level.
local function isHighestLevel(view)
  local top = 0
  for slot = 1, view.count do
    local level = max(0, int(view.mons[slot].level, 0))
    if level >= top then top = level end
  end
  local own = view.mons[view.cur]
  return own ~= nil and max(0, int(own.level, 0)) >= top
end

-- AI_TryItem.  `de` starts at wEnemyTrainerItem1 and, on a row that matches
-- item 2, stays on it -- a DontUse leaves it there, so the rows after compare
-- item 2 and the byte after it, wEnemyTrainerBaseReward ("AI might use its
-- base reward value as an item"), and item 1 is never looked at again.  The
-- byte after that is wEnemyTrainerAIFlags, never written (0: ClearBattleRAM
-- fills wBattle), so `de` goes no further.  Returns the decision or nil.
function M.tryItem(view)
  local fighter = view.fighter
  local items = type(fighter.trainerItems) == "table" and fighter.trainerItems or {}
  local bytes = {
    M.itemByte(items[1]), M.itemByte(items[2]),
    max(0, int(fighter.baseReward, 0)) % 256, 0,
  }
  if bytes[1] == 0 and bytes[2] == 0 then return nil end
  if not isHighestLevel(view) then return nil end
  local de = 1
  for _, entry in ipairs(M.AI_ITEMS) do
    local has = false
    if bytes[de] == entry.num then
      has = true
    else
      de = de + 1
      if bytes[de] == entry.num then has = true else de = de - 1 end
    end
    if has and ROUTINES[entry.routine](view) then
      return { action = "item", item = entry.id, trainerSlot = de }
    end
  end
  return nil
end

-- CheckEnemyLockedIn (core.asm): SUBSTATUS_RECHARGE, _CHARGED, _RAMPAGE,
-- _BIDE or _ROLLOUT -- the lock-ins Turn `_fillForcedChoices` fills.
local function lockedIn(mon)
  return mon.mustRecharge == true or mon.charging ~= nil or mon.bide ~= nil
    or (mon.thrashing ~= nil and int(mon.thrashing.turns, 0) > 0)
    or (mon.rollout ~= nil and mon.rollout.active == true)
end

-- AI_TrySwitch's `cp 2`: two living party monsters, the one out included.
local function canSwitch(view)
  local alive = 0
  for slot = 1, view.count do
    if hpOf(view.mons[slot]) > 0 then alive = alive + 1 end
  end
  return alive >= 2
end

-- AI_SwitchOrTryItem for the computer's seat `fighter` against the player's
-- seat `foe`.  Returns nil (the move goes ahead), a switch -- `slot` the
-- 1-based party index wEnemySwitchMonIndex names, the shape of a normalised
-- switch choice -- or an item: `item` its id and `trainerSlot` the byte
-- AI_TryItem cleared (1 / 2 the trainer items, 3 the base reward), for
-- `M.useItem`.
function M.switchOrTryItem(battle, fighter, foe)
  if type(battle) ~= "table" or type(fighter) ~= "table" then return nil end
  if Effects.isWildMode(battle.mode) then return nil end
  if LINK_MODES[battle.mode] or fighter.side == PLAYER_SIDE then return nil end
  local mon = activeMon(fighter)
  if not mon then return nil end
  if lockedIn(mon) then return nil end

  local view = viewOf(battle, fighter, foe)
  -- wPlayerSubStatus5's SUBSTATUS_CANT_RUN (the player's MEAN LOOK on this
  -- seat) or wEnemyWrapCount: `DontSwitch`, the item check alone.
  local wrapped = mon.trapped ~= nil and int(mon.trapped.turns, 0) > 0
  if wrapped or battle:_heldBy(fighter) then return M.tryItem(view) end

  local odds
  if hasBit(view.flags, M.SWITCH_OFTEN) then
    odds = M.SWITCH_ODDS.often
  elseif hasBit(view.flags, M.SWITCH_RARELY) then
    odds = M.SWITCH_ODDS.rarely
  elseif hasBit(view.flags, M.SWITCH_SOMETIMES) then
    odds = M.SWITCH_ODDS.sometimes
  else
    return M.tryItem(view)
  end

  M.checkAbleToSwitch(view)
  local strength = floor(view.param / 16)       -- `and $f0`
  if strength == 0 then return M.tryItem(view) end
  local byte = draw(view)
  local go
  if strength == 1 then
    go = byte < odds[1]
  elseif strength == 2 then
    go = byte < odds[2]
  else
    go = byte >= odds[3]
  end
  if not go then return M.tryItem(view) end

  -- `.switch`: wEnemySwitchMonIndex, then AI_TrySwitch -- whose refusal is
  -- the move, not the item check.
  if not canSwitch(view) then return nil end
  return { action = "switch", slot = view.param % 16 + 1 }
end

-- ------------------------------------------------------------------
-- items.asm: the effect
-- ------------------------------------------------------------------

-- GetItemName for the thirteen (data/items/names.asm): the id's words, and
-- GUARD SPEC.'s full stop (Turn's itemLabel rule).
local function itemName(id)
  local label = id:gsub("_", " ")
  if label == "GUARD SPEC" then label = "GUARD SPEC." end
  return label
end

-- _EnemyUsedOnText (data/text/common_1.asm): `text "<ENEMY>" / line "used @"
-- <item> / cont "on @" <wEnemyMonNickname> "!"`.  <ENEMY> is PlaceEnemysName,
-- the trainer's class and name (the seat's `name`), and the monster's name is
-- a bare text_ram -- neither is a battler's prefixing macro, so no K17 mark;
-- K18's breaks stand where `line` and `cont` are.
function M.usedOnLine(fighter, itemId, mon)
  return tostring(fighter.name) .. "\nused " .. itemName(itemId)
    .. "\non " .. tostring(mon.species) .. "!"
end

-- _EnemyWithdrewText: `text "<ENEMY>" / line "withdrew" / cont "@"
-- <wEnemyMonNickname> "!"` -- AI_Switch's line unless PursuitSwitch felled the
-- monster (`jr c, .skiptext`).
function M.withdrewLine(fighter, mon)
  return tostring(fighter.name) .. "\nwithdrew\n" .. tostring(mon.species) .. "!"
end

-- AI_HealStatus: the party and battle status bytes 0 and SUBSTATUS_TOXIC off --
-- with no CalcEnemyStats (a burn's Attack and a paralysis' Speed stay cut,
-- `setStatusOn`) and SUBSTATUS_NIGHTMARE left standing.  Returns whether a
-- status was there.
local function healStatus(fighter, mon)
  local had = mon.status ~= nil
  Effects.setStatusOn(mon, fighter, nil)
  mon.statusTurns = 0
  mon.toxicLatent = nil
  return had
end

local function itemEvent(battle, fighter, id)
  battle:_emit("item", { slot = fighter.slot, side = fighter.side, text = id })
end

local function recoveredEvent(battle, fighter, mon, confused)
  local fields = { slot = fighter.slot, side = fighter.side,
                   text = mon.species .. " recovered" }
  if confused then fields.confused = 0 end
  battle:_emit("status", fields)
end

-- The EnemyUsed* routine for a decision `M.switchOrTryItem` returned, then
-- AI_TryItem's "used item" tail.  The `item` event stands where the cart plays
-- SFX_FULL_HEAL (AIUsedItemSound) and, for the X stat items, which play
-- none, right after the line; `drain` is AnimateHPBar, `status` and `stat` the
-- HUD.  Returns whether the item was applied.
function M.useItem(battle, fighter, decision)
  if type(battle) ~= "table" or type(fighter) ~= "table" then return false end
  if type(decision) ~= "table" or decision.action ~= "item" then return false end
  local entry = BY_ID[decision.item]
  local mon = activeMon(fighter)
  if not entry or not mon then return false end
  local line = M.usedOnLine(fighter, entry.id, mon)

  if entry.use == "fullHeal" then
    -- EnemyUsedFullHeal: sound, AI_HealStatus, the line, the HUD.
    itemEvent(battle, fighter, entry.id)
    local had = healStatus(fighter, mon)
    battle:_say(line)
    if had then recoveredEvent(battle, fighter, mon, false) end
  elseif entry.use == "fullRestore" then
    -- EnemyUsedFullRestore: AI_HealStatus, SUBSTATUS_CONFUSED off and
    -- wEnemyConfuseCount 0 (FULL HEAL's path never does), the HP to max
    -- (FullRestoreContinue), then EnemyPotionFinish.
    local had = healStatus(fighter, mon)
    local confused = int(mon.confusion, 0) > 0
    mon.confusion = 0
    battle:_say(line)
    itemEvent(battle, fighter, entry.id)
    battle:_heal(fighter, mon, mon.maxHp - mon.hp)
    if had then recoveredEvent(battle, fighter, mon, false) end
    if confused then recoveredEvent(battle, fighter, mon, true) end
  elseif entry.use == "maxPotion" then
    battle:_say(line)
    itemEvent(battle, fighter, entry.id)
    battle:_heal(fighter, mon, mon.maxHp - mon.hp)
  elseif entry.use == "potion" then
    -- EnemyPotionContinue: HP + 200 / 50 / 20, held at the max.
    battle:_say(line)
    itemEvent(battle, fighter, entry.id)
    battle:_heal(fighter, mon, entry.heal)
  elseif entry.use == "flag" then
    -- EnemyUsedXAccuracy / GuardSpec / DireHit: sound, the SubStatus4 bit
    -- (_X_ACCURACY, _MIST, _FOCUS_ENERGY), the line.
    itemEvent(battle, fighter, entry.id)
    mon[entry.flag] = true
    battle:_say(line)
  elseif entry.use == "stat" then
    -- EnemyUsedXItem: the line, then RaiseStat with b = the stat (one
    -- stage), which says nothing either way.  It fails first on a
    -- wAttackMissed or wEffectFailed the last move left, then at +6
    -- (`.cant_raise_stat`) or on a stat already at 999 (`.stats_already_max`),
    -- each of those two setting wAttackMissed.
    battle:_say(line)
    itemEvent(battle, fighter, entry.id)
    if not (battle.lastAttackMissed == true or battle.lastEffectFailed == true) then
      local raised, after = Effects.raiseStat(mon, fighter.badges, entry.stat, 1)
      if raised then
        battle:_emit("stat", {
          slot = fighter.slot, side = fighter.side, amount = after, stage = after,
          text = Effects.statUpLine(mon, entry.stat, 1),
        })
      else
        battle.lastAttackMissed = true
      end
    end
  end

  -- AI_TryItem's tail: the slot `de` points at is cleared, wEnemyGoesFirst is
  -- set (Turn's action order: an item is taken before every move),
  -- SUBSTATUS_BIDE and _RAGE go, the Fury Cutter, Protect and Rage counts are
  -- 0, and -- Crystal only -- wLastEnemyCounterMove.
  local slot = int(decision.trainerSlot, 0)
  if slot == 1 or slot == 2 then
    if type(fighter.trainerItems) ~= "table" then fighter.trainerItems = {} end
    for i = 1, slot - 1 do
      if fighter.trainerItems[i] == nil then fighter.trainerItems[i] = "NO_ITEM" end
    end
    fighter.trainerItems[slot] = "NO_ITEM"
  elseif slot == 3 then
    fighter.baseReward = 0
  end
  mon.bide = nil
  mon.furyCutter = 0
  mon.protectCount = 0
  mon.rageCounter = 0
  mon.raging = false
  if battle.family == "crystal" then mon.lastCounterMove = nil end
  return true
end

-- UpdateUsedMoves (engine/battle/used_move_text.asm), for the hook to call
-- where the player's UsedMoveText runs: the move appended to the player's
-- monster's `usedMoves` unless its id is there already, the oldest dropped
-- when four are.
function M.recordUsedMove(mon, move)
  if type(mon) ~= "table" or type(move) ~= "table" then return end
  if type(mon.usedMoves) ~= "table" then mon.usedMoves = {} end
  local list = mon.usedMoves
  -- What the switch logic reads off it (a power) and the key it is kept by.
  local row = { id = move.id, power = move.power, type = move.type, typeId = move.typeId }
  for i = 1, M.NUM_MOVES do
    local seen = list[i]
    if not seen then
      list[i] = row
      return
    end
    if seen.id == row.id then return end
  end
  list[1], list[2], list[3], list[4] = list[2], list[3], list[4], row
end

-- ------------------------------------------------------------------
-- core.asm: the successor after a faint
-- ------------------------------------------------------------------

-- FindMonInOTPartyToSwitchIntoBattle and ScoreMonTypeMatchups.  Two byte
-- registers start at %1 and shift once a slot: a slot that is out, fainted
-- or wCurOTMon sets bit 0 of the player's (discouraged); otherwise
-- LookUpTheEffectivenessOfEveryMove sets the enemy's when any of its party
-- moves -- power or not -- is super effective against the player's types
-- (BattleCheckTypeMatchup on the enemy's turn: the move's own type, the
-- Foresight rows by the player's SUBSTATUS_IDENTIFIED), and
-- IsThePlayerMonTypesEffectiveAgainstOTMon tries the player's type 1 then type
-- 2 against the slot's base types (the enemy's substatus NewEnemyMonStatus
-- has just cleared, so no Foresight there): super effective cancels the
-- enemy's bit, or else sets the player's.  The first enemy bit wins; else the
-- first slot not discouraged; else BattleRandom & 7 until a living slot other
-- than wCurOTMon comes up (under wOTPartyCount on Crystal, PARTY_LENGTH on
-- Gold).
--
-- Returns a normalised switch choice -- `slot` the 1-based party index -- with
-- `playerMoveType`, the type the scoring left in wPlayerMoveStruct + MOVE_TYPE
-- (IsThePlayerMonTypesEffectiveAgainstOTMon writes the player's type there;
-- nil when no slot was scored): the next turn's locked-in player move (a
-- rampage, a charged move, ROLLOUT) runs on it, as ParsePlayerAction's
-- `.locked_in` reloads no move data.  nil with no living bench.
function M.replacement(battle, fighter, foe)
  if type(battle) ~= "table" or type(fighter) ~= "table" then return nil end
  local mons = fighter.mons
  local count = min(#mons, M.PARTY_LENGTH)
  local cur = fighter.active
  local foeMon = foe and activeMon(foe) or nil
  local playerTypes = foeMon and foeMon.types or {}
  local t1, t2 = typePair(playerTypes)
  local identified = foeMon ~= nil and foeMon.identified == true
  local gold = battle.family ~= "crystal"

  local enemyEff, playerEff = 1, 1
  local playerMoveType = nil
  local b = -1
  while true do
    enemyEff = sla(enemyEff)
    playerEff = sla(playerEff)
    b = b + 1
    if b == count then break end
    local mon = mons[b + 1]
    if b + 1 == cur or hpOf(mon) == 0 then
      playerEff = setBit(playerEff, 1)              -- `.discourage`
    else
      local moves = mon.moves or {}
      for k = 1, M.NUM_MOVES do
        local move = moves[k]
        if not move then break end
        if M.typeMatchup(battle, moveTypeOf(battle, move), playerTypes, identified)
           >= M.SUPER_EFFECTIVE then
          enemyEff = setBit(enemyEff, 1)
          break
        end
      end
      local home = baseTypes(mon)
      local superEffective = false
      playerMoveType = t1
      if M.typeMatchup(battle, t1, home, false) >= M.SUPER_EFFECTIVE then
        superEffective = true
      else
        playerMoveType = t2
        if M.typeMatchup(battle, t2, home, false) >= M.SUPER_EFFECTIVE then
          superEffective = true
        end
      end
      if superEffective then
        if hasBit(enemyEff, 1) then
          enemyEff = clearBit(enemyEff, 1)          -- `.reset`
        else
          playerEff = setBit(playerEff, 1)
        end
      end
    end
  end

  -- ScoreMonTypeMatchups `.loop1`: both shifted until the player's start bit
  -- falls out, which leaves slot 1 on bit 7.
  local carry = false
  repeat
    enemyEff = sla(enemyEff)
    playerEff, carry = sla(playerEff)
  until carry

  -- `.loop2`: is any slot not discouraged?
  local c, left = playerEff, count
  local allDiscouraged = false
  while true do
    local out
    c, out = sla(c)
    if not out then break end
    left = left - 1
    if left == 0 then
      allDiscouraged = true
      break
    end
  end

  local pick = nil
  if not allDiscouraged then
    local value, slot = (enemyEff ~= 0) and enemyEff or playerEff, -1
    local want = enemyEff ~= 0                      -- `.loop3`: a set bit; `.loop4`: a clear one
    repeat
      slot = slot + 1
      local bitOut
      value, bitOut = sla(value)
    until bitOut == want or slot > 7
    pick = slot
  else
    -- `.loop5`
    local limit = gold and M.PARTY_LENGTH or count
    for _ = 1, M.REDRAW_LIMIT do
      local a = battle.rng:byte() % 8
      if a < limit and a + 1 ~= cur and hpOf(mons[a + 1]) > 0 then
        pick = a
        break
      end
    end
    if pick == nil then
      for slot = 1, count do
        if slot ~= cur and hpOf(mons[slot]) > 0 then
          pick = slot - 1
          break
        end
      end
    end
  end
  if pick == nil then return nil end
  return { action = "switch", slot = pick + 1, playerMoveType = playerMoveType }
end

return M
