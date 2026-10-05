-- Gold / Silver / Crystal held items: the static rules the referee keys on a
-- sheet's item.
--
-- docs/plans/gen12-referee-fidelity.md §1 item 9, decision 3.  The referee holds
-- no item table -- no price, no parameter, nothing read from a cart -- so a
-- monster's sheet carries what the engine's own item row says about the item it
-- holds (contract K2): `heldItem` (the id), `holdEffect` (pokecrystal's HELD_*
-- name for it), `holdParam` (the u8 beside it), `itemName` (what the box calls
-- it) and `mail`.  What lives here is the part that is code on the cart, not
-- data: which HELD_* name a rule answers to, the handful of rules the cart
-- writes against an item ID instead (Light Ball, Thick Club, Metal Powder, Lucky
-- Punch, Stick, Berserk Gene, the Mail items), and the arithmetic each one does
-- with the parameter it is handed.  Every rule below is identical between
-- pokecrystal and pokegold (each routine diffed; only Crystal's Battle Tower
-- exits differ), so none of it reads the fight's cart family.
--
-- Where each rule is asked, and in which order, is Turn's business -- the cart's
-- call sites are cited there.  Nothing here holds state or draws a byte: a
-- function that needs a roll is handed it.
--
-- No love, no engine modules, no mod facade.

local need = ...

local M = {}

local floor = math.floor

local function int(value, fallback)
  local n = tonumber(value)
  if not n or n ~= n then return fallback end
  return floor(n)
end

-- ------------------------------------------------------------------
-- the HELD_* names a rule answers to (constants/item_data_constants.asm)
-- ------------------------------------------------------------------

M.QUICK_CLAW     = "HELD_QUICK_CLAW"      -- DetermineMoveOrder .equal_priority
M.BRIGHTPOWDER   = "HELD_BRIGHTPOWDER"    -- BattleCommand_CheckHit .BrightPowder
M.CRITICAL_UP    = "HELD_CRITICAL_UP"     -- BattleCommand_Critical .ScopeLens
M.FOCUS_BAND     = "HELD_FOCUS_BAND"      -- BattleCommand_ApplyDamage .focus_band
M.FLINCH         = "HELD_FLINCH"          -- BattleCommand_HeldFlinch (kingsrock)
M.LEFTOVERS      = "HELD_LEFTOVERS"       -- HandleLeftovers
M.BERRY          = "HELD_BERRY"           -- HandleHPHealingItem
M.RESTORE_PP     = "HELD_RESTORE_PP"      -- HandleMysteryberry
M.HEAL_CONFUSION = "HELD_HEAL_CONFUSION"  -- UseConfusionHealingItem
M.HEAL_STATUS    = "HELD_HEAL_STATUS"     -- both status routines

-- data/types/type_boost_items.asm: the seventeen HELD_<TYPE>_BOOST names and
-- the type each one boosts, as the type's registry id (Psychic's is
-- PSYCHIC_TYPE, because PSYCHIC is a move).  Pink Bow and Polkadot Bow are
-- HELD_NORMAL_BOOST rows like any other; Dragon Fang carries HELD_NONE on the
-- cart (its documented bug), and since the effect comes off the player's own
-- item row, that is what reaches here.
M.TYPE_BOOST = {
  HELD_NORMAL_BOOST = "NORMAL",     HELD_FIGHTING_BOOST = "FIGHTING",
  HELD_FLYING_BOOST = "FLYING",     HELD_POISON_BOOST = "POISON",
  HELD_GROUND_BOOST = "GROUND",     HELD_ROCK_BOOST = "ROCK",
  HELD_BUG_BOOST = "BUG",           HELD_GHOST_BOOST = "GHOST",
  HELD_FIRE_BOOST = "FIRE",         HELD_WATER_BOOST = "WATER",
  HELD_GRASS_BOOST = "GRASS",       HELD_ELECTRIC_BOOST = "ELECTRIC",
  HELD_PSYCHIC_BOOST = "PSYCHIC_TYPE", HELD_ICE_BOOST = "ICE",
  HELD_DRAGON_BOOST = "DRAGON",     HELD_DARK_BOOST = "DARK",
  HELD_STEEL_BOOST = "STEEL",
}

-- data/battle/held_heal_status.asm: what each status berry cures, in the
-- referee's spelling (PSN covers the badly-poisoned TOX, as `1 << PSN` covers
-- SUBSTATUS_TOXIC's bit on the cart).  HELD_HEAL_STATUS (MiracleBerry) is
-- ALL_STATUS, and UseHeldStatusHealingItem clears confusion with it too.
local ALL = {
  poison = true, toxic = true, burn = true, freeze = true, sleep = true, paralysis = true,
}
M.STATUS_CURE = {
  HELD_HEAL_POISON = { poison = true, toxic = true },
  HELD_HEAL_FREEZE = { freeze = true },
  HELD_HEAL_BURN = { burn = true },
  HELD_HEAL_SLEEP = { sleep = true },
  HELD_HEAL_PARALYZE = { paralysis = true },
  HELD_HEAL_STATUS = ALL,
}

-- data/battle/held_stat_up.asm, run by HandleStatBoostingHeldItems ("not used
-- in-game": no vanilla item row carries one, so only an item a ROM hack gave
-- one of these effects ever reaches the rule -- which is still the cart's).
M.STAT_UP = {
  HELD_ATTACK_UP = "atk", HELD_DEFENSE_UP = "def", HELD_SPEED_UP = "spe",
  HELD_SP_ATTACK_UP = "spa", HELD_SP_DEFENSE_UP = "spd",
  HELD_ACCURACY_UP = "acc", HELD_EVASION_UP = "eva",
}

-- ------------------------------------------------------------------
-- the rules the cart writes against an item ID
-- ------------------------------------------------------------------

-- HandleBerserkGene (engine/battle/core.asm): `sub BERSERK_GENE` on the item
-- byte.
M.BERSERK_GENE = "BERSERK_GENE"

-- DittoMetalPowder: `cp METAL_POWDER` on the defender's item, for a defender
-- whose PARTY species is DITTO.
M.METAL_POWDER = "METAL_POWDER"
M.DITTO = "DITTO"

-- ThickClubBoost / LightBallBoost through SpeciesItemBoost: the attacker's
-- PARTY species, its item id, and which half of the damage step calls it --
-- PlayerAttackDamage reaches ThickClubBoost on the physical path only and
-- LightBallBoost on the special path only.
M.SPECIES_ATTACK = {
  THICK_CLUB = { special = false, species = { CUBONE = true, MAROWAK = true } },
  LIGHT_BALL = { special = true, species = { PIKACHU = true } },
}

-- BattleCommand_Critical: Chansey with LUCKY_PUNCH, Farfetch'd with STICK --
-- read off the BATTLE species (wBattleMonSpecies, which Transform rewrites).
M.CRIT_ITEM = { LUCKY_PUNCH = "CHANSEY", STICK = "FARFETCH_D" }
M.CRIT_ITEM_LEVEL = 2

-- data/items/mail_items.asm, which ItemIsMail walks: BattleCommand_Thief
-- refuses to take any of these.
M.MAIL = {
  FLOWER_MAIL = true, SURF_MAIL = true, LITEBLUEMAIL = true, PORTRAITMAIL = true,
  LOVELY_MAIL = true, EON_MAIL = true, MORPH_MAIL = true, BLUESKY_MAIL = true,
  MUSIC_MAIL = true, MIRAGE_MAIL = true,
}

-- ------------------------------------------------------------------
-- move-keyed answers the item rules need
-- ------------------------------------------------------------------

-- CheckTurn's "Snore and Sleep Talk bypass sleep", and IgnoreSleepOnly's
-- `cp SNORE / cp SLEEP_TALK`: both compare the move id, and so does this --
-- EFFECT_SNORE has its own effect id now (Effects.SNORE, its flinch), but
-- EFFECT_SLEEP_TALK has none, and the cart asks the id either way.
M.SLEEP_BYPASS = { SNORE = true, SLEEP_TALK = true }

-- BattleCommand_Thief, the `thief` command in the Thief script.  Same reason:
-- EFFECT_THIEF has no Effects.idOf row, so the sheet carries the move id.
M.THIEF = "THIEF"

-- King's Rock (BattleCommand_HeldFlinch) only runs inside the move scripts
-- that hold a `kingsrock` command (data/moves/effects.asm, identical in
-- pokegold).  A Gold sheet numbers a move's effect through Effects.idOf, which
-- folds Crystal's EFFECT_* names onto this referee's 0..86 ids, gives the
-- Gold-native scripts their own (87..), and folds every name with no handler
-- onto 0, so the list is kept in those ids:
--
--    0 EFFECT_NORMAL_HIT (and every unmapped hit, below)   3 LEECH_HIT
--    7 SELFDESTRUCT   16 PAY_DAY        17 ALWAYS_HIT       26 BIDE
--   27 RAMPAGE        29 MULTI_HIT      39 RAZOR_WIND / SOLARBEAM /
--   SKULL_BASH                           40 SUPER_FANG       41 STATIC_DAMAGE /
--   LEVEL_DAMAGE / PSYWAVE               43 FLY              44 DOUBLE_HIT
--   45 JUMP_KICK      48 RECOIL_HIT     77 POISON_MULTI_HIT  81 RAGE
--   96 SNORE (`flinchtarget`, then `kingsrock`)              101 SKY_ATTACK
--
-- Every other mapped id is a script with no `kingsrock`: the status hits, the
-- stat-down hits, FLINCH_HIT, OHKO, TRAP_TARGET, HYPER_BEAM, DREAM_EATER, the
-- non-damaging effects, and the Gold-native SP. DEF / ACCURACY drop hits, the
-- stat-raising hits, FLAME WHEEL, SACRED FIRE, STOMP, TWISTER, THUNDER, TRI
-- ATTACK, GUST and EARTHQUAKE -- which used to fold to 0 and be named here by
-- move id.  Twineedle's and Skull Bash's scripts run `kingsrock` before their
-- last command rather than as it, which is still a run.  Id 0 is mixed on the
-- sheet: of the damaging moves whose effect still folds to it, FUTURE SIGHT
-- runs no `kingsrock` and is named by move id; every other one does (Thief,
-- Quick Attack, Rollout, Return, Hidden Power, Counter, Triple Kick, Beat Up
-- ...).
M.KINGS_ROCK_EFFECTS = {
  [0] = true, [3] = true, [7] = true, [16] = true, [17] = true, [26] = true,
  [27] = true, [29] = true, [39] = true, [40] = true, [41] = true, [43] = true,
  [44] = true, [45] = true, [48] = true, [77] = true, [81] = true,
  [96] = true, [101] = true,
}
M.KINGS_ROCK_FOLDED_EXCEPTIONS = {
  FUTURE_SIGHT = true,
}

-- ------------------------------------------------------------------
-- obedience (BattleCommand_CheckObedience)
-- ------------------------------------------------------------------

-- `.obeylevel`: the first of these Johto badges held sets the level a traded
-- monster obeys up to; none of them is 10.  RISING's MAX_LEVEL + 1 is "every
-- level".  Bare Gold ids, as a Gold client uploads them.
M.OBEDIENCE_CAPS = {
  { badge = "RISING", cap = 101 },
  { badge = "STORM", cap = 70 },
  { badge = "FOG", cap = 50 },
  { badge = "HIVE", cap = 30 },
}
M.OBEDIENCE_FLOOR = 10

function M.obedienceCap(badges)
  if type(badges) == "table" then
    for _, row in ipairs(M.OBEDIENCE_CAPS) do
      if badges[row.badge] then return row.cap end
    end
  end
  return M.OBEDIENCE_FLOOR
end

-- `swap a`: the cart's nibble swap of a random byte.
function M.swap(byte)
  local b = int(byte, 0) % 256
  return (b % 16) * 16 + floor(b / 16)
end

-- `.Nap`: BattleRandom, `add a`, `swap a`, `and SLP_MASK` -- 0 means draw again.
function M.napTurns(byte)
  return M.swap((int(byte, 0) * 2) % 256) % 8
end

-- ------------------------------------------------------------------
-- reading a sheet
-- ------------------------------------------------------------------

-- The hold effect and its parameter, or nil when the monster holds nothing or
-- holds an item whose row names no effect.
function M.effect(mon)
  if type(mon) ~= "table" or not mon.heldItem then return nil, 0 end
  return mon.holdEffect, int(mon.holdParam, 0)
end

function M.holds(mon, token)
  local effect = M.effect(mon)
  return effect ~= nil and effect == token
end

-- What a sentence calls the item: the sheet's display name, or its id.
function M.label(mon)
  if type(mon) ~= "table" then return "ITEM" end
  return mon.itemName or mon.heldItem or "ITEM"
end

function M.isMail(mon)
  if type(mon) ~= "table" or not mon.heldItem then return false end
  return mon.mail == true or M.MAIL[mon.heldItem] == true
end

-- The item as one record, so Thief can move it and a consumed one can be
-- cleared, field for field.
function M.take(mon)
  local item = {
    heldItem = mon.heldItem, holdEffect = mon.holdEffect, holdParam = mon.holdParam,
    itemName = mon.itemName, mail = mon.mail,
  }
  mon.heldItem, mon.holdEffect, mon.holdParam = nil, nil, nil
  mon.itemName, mon.mail = nil, nil
  return item
end

function M.give(mon, item)
  mon.heldItem, mon.holdEffect, mon.holdParam = item.heldItem, item.holdEffect, item.holdParam
  mon.itemName, mon.mail = item.itemName, item.mail
end

-- ------------------------------------------------------------------
-- the arithmetic
-- ------------------------------------------------------------------

-- DamageCalc .DoneItem: `ld a, c / add 100` is a byte, so the multiplier is
-- (100 + parameter) mod 256 out of 100.  Returned as the percent Damage.compute
-- adds to 100 (`itemBoostPercent`): 10 for every vanilla row, and nil when the
-- held effect is no type boost or boosts another type.
function M.typeBoostPercent(mon, typeId)
  local effect, param = M.effect(mon)
  local boosts = effect and M.TYPE_BOOST[effect]
  if not boosts or type(typeId) ~= "string" or boosts ~= typeId then return nil end
  return (100 + param) % 256 - 100
end

-- `.equal_priority`: BattleRandom against the parameter (60 -> 60/256).
function M.quickClawFires(param, byte)
  return int(byte, 255) < int(param, 0)
end

-- `.BrightPowder`, in the referee's percent domain.  The cart subtracts the
-- parameter from the 0..255 accuracy byte it already scaled by the stages and
-- rolls BattleRandom against what is left (0 -> always a miss; 255 -> the
-- `cp -1` that never misses).  Here the scaled accuracy is a percent and the
-- roll is 0..99, so the byte is rebuilt from the percent, the parameter comes
-- off it, and the percent the same roll is compared against is the smallest
-- one that hits exactly where `roll * 255 < byte * 100` does.
function M.brightPowder(effective, param)
  local percent = int(effective, 0)
  local byte = floor(percent * 255 / 100) - int(param, 0)
  if byte < 0 then byte = 0 end
  if byte >= 255 then return percent end
  return floor((byte * 100 + 254) / 255)
end

-- SpeciesItemBoost: `sla l / rl h`, the stat doubled as a 16-bit value (which
-- TruncateHL_BC may then wrap, the documented bug).  `special` is which half
-- of the damage step is asking.
function M.speciesAttack(mon, special, attack)
  if type(mon) ~= "table" or not mon.heldItem then return attack end
  local rule = M.SPECIES_ATTACK[mon.heldItem]
  if not rule or rule.special ~= (special == true) then return attack end
  if not (mon.speciesId and rule.species[mon.speciesId]) then return attack end
  return (int(attack, 0) * 2) % 65536
end

-- DittoMetalPowder on the folded pair (b = attack, c = defense): c gains half
-- of itself in a byte; when that overflows, the attack is halved (at least 1)
-- and the nine-bit sum is shifted back down -- so a boosted Defense past 170 can
-- leave the hit harder than no powder at all (docs/bugs_and_glitches.md).
function M.metalPowder(defender, attack, defense)
  if type(defender) ~= "table" or defender.heldItem ~= M.METAL_POWDER then
    return attack, defense
  end
  if defender.speciesId ~= M.DITTO then return attack, defense end
  local b, c = int(attack, 0), int(defense, 0)
  local sum = c + floor(c / 2)
  if sum < 256 then return b, sum end
  b = floor(b / 2)
  if b == 0 then b = 1 end
  return b, floor(sum / 2)
end

-- BattleCommand_Critical's `.Item` check on the battle species.
function M.critSpeciesItem(battleSpeciesId, itemId)
  if type(itemId) ~= "string" then return false end
  local species = M.CRIT_ITEM[itemId]
  return species ~= nil and species == battleSpeciesId
end

-- BattleCommand_FalseSwipe as Focus Band calls it: damage at or past the HP
-- left comes down to one short of it.  Returns the amount and whether it moved.
function M.focusBand(amount, hp)
  local a, h = int(amount, 0), int(hp, 0)
  if a < h then return a, false end
  local held = h - 1
  if held < 0 then held = 0 end
  return held, true
end

-- GetSixteenthMaxHP (core.asm:1831-1842) over GetQuarterMaxHP (:1858-1875),
-- register for register: the max HP in bc is shifted right twice as a 16-bit
-- pair (`srl b / rr c`), the "at least 1" tests the low byte c alone, then the
-- sixteenth shifts c alone right twice more -- b keeps the quarter's high byte
-- -- and bumps c to 1 again when it is 0.  RestoreHP adds the whole of bc.
-- Under 1024 HP that is max(1, floor(maxHp / 16)); from 1024 the high byte
-- rides through, so 1024 HP heals 257 (b = 1, c = 0 -> 1 -> 0 -> 1) and 1100
-- heals 260.  The max HP is the cart's 16-bit word.
function M.sixteenth(maxHp)
  local n = int(maxHp, 0)
  if n < 0 then n = 0 end
  local quarter = floor((n % 65536) / 4)
  local b, c = floor(quarter / 256), quarter % 256
  if c == 0 then c = 1 end
  c = floor(c / 4)
  if c == 0 then c = 1 end
  return b * 256 + c
end

-- GetEighthMaxHP (core.asm:1844-1856) over the same GetQuarterMaxHP: the
-- quarter's low byte c alone is halved -- "assumes nothing can have 1024 or
-- more hp" -- and bumped to 1 when it is 0, b riding through as above.  Under
-- 1024 HP that is max(1, floor(maxHp / 8)); from 1024 the high byte rides
-- through, so 1024 HP saps 257 (b = 1, c = 0 -> 1 -> 0 -> 1).  LEECH SEED's
-- sap (ResidualDamage) is this.
function M.eighth(maxHp)
  local n = int(maxHp, 0)
  if n < 0 then n = 0 end
  local quarter = floor((n % 65536) / 4)
  local b, c = floor(quarter / 256), quarter % 256
  if c == 0 then c = 1 end
  c = floor(c / 2)
  if c == 0 then c = 1 end
  return b * 256 + c
end

-- HandleHPHealingItem: "If, and only if, Pokemon's HP is less than half max".
function M.berryWants(hp, maxHp)
  return int(hp, 0) * 2 < int(maxHp, 0)
end

-- Whether King's Rock rolls after a move (see KINGS_ROCK_EFFECTS).
function M.kingsRockMove(effectId, moveId)
  local id = int(effectId, 0)
  if not M.KINGS_ROCK_EFFECTS[id] then return false end
  if id == 0 and type(moveId) == "string" and M.KINGS_ROCK_FOLDED_EXCEPTIONS[moveId] then
    return false
  end
  return true
end

return M
