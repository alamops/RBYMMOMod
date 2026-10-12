-- The two first battles, fought by SOLO BATTLES (contract C2 of
-- docs/plans/gen3-solo-remaining-fights.md, research §1.5 / §2.5):
--
--   oak    FireRed / LeafGreen: the rival in PROF. OAK's lab
--          (trainerbattle_earlyrival with RIVAL_BATTLE_TUTORIAL, which ORs
--          BATTLE_TYPE_FIRST_BATTLE in -- pokefirered battle_setup.c:899 --
--          fought under the Oak / Old Man controller); the engine's trainer op
--          hands `firstBattle`, `earlyRival`, `rivalFlags`, `noWhiteout`.
--   birch  Emerald: the wild ZIGZAGOON chasing PROF. BIRCH (pokeemerald
--          battle_setup.c:930 CB2_StartFirstBattle, BATTLE_TYPE_FIRST_BATTLE);
--          the engine's BattleBridge.startFirstBattle hands `firstBattleKind =
--          "birch"` and a foe with `item = 0`.
--
-- Both are the core's own single fight (src/SoloBattle.lua) with the cart's
-- first-battle rules switched on where they live:
--   * the referee (BattleSim3 Turn.create `firstBattle`): Oak's sure-hits and
--     voided crits until his lessons, his `lesson` events; Birch's no crits and
--     the refused RUN; Birch's ZIGZAGOON on AI_FirstBattle (the wild entry's
--     `ai = "firstBattle"`: flee at 20% of the player's HP or under);
--   * the screen (MediatedBattle `firstBattle`): Oak's voice-over;
--   * here: Birch's refused RUN in the cart's words, and the ZIGZAGOON's held
--     item (pret rolls one; the engine's start zeroes it, below).
-- What the core already does for a first battle and needs nothing here: the
-- loss that is no whiteout (Oak's RIVAL_BATTLE_HEAL_AFTER -- `noWhiteout` --
-- heals the party, no money lost; Birch's CB2_EndFirstBattle -- `scriptedLoss`
-- arm), EXP (FIRST_BATTLE is no exclusion in Cmd_getexp), the TV left out
-- (BattleBridge.tvBattleEnd's `firstBattle` exclusion, read off the kinds),
-- and the saved song let go (CB2_EndFirstBattle's Overworld_ClearSavedMusic).
--
-- Loaded lazily by src/SoloBattle.lua (KIND_FILES3: firstBattle ->
-- "Solo3/First").

local need = ...
local Gen3 = need("Gen3")
local Solo = need("SoloBattle")

local M = {}

local floor = math.floor

M.KINDS = { oak = true, birch = true }

-- src/SoloBattle.lua's PLAYER_SEAT: a single's one seat of ours.
M.PLAYER = "solo_player"

-- pret STRINGID_DONTLEAVEBIRCH (pokeemerald battle_main.c:4080,
-- B_MSG_DONT_LEAVE_BIRCH) when the player's text pack cannot say it.
M.DONT_LEAVE_BIRCH = "STRINGID_DONTLEAVEBIRCH"
M.DONT_LEAVE_BIRCH_TEXT = "PROF. BIRCH: Don't leave me like this!"

local function int(v, fallback)
  local n = tonumber(v)
  if n == nil then return fallback end
  return floor(n)
end

local function try(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, value = pcall(fn, ...)
  if ok then return value end
  return nil
end

local function profile()
  local BP = Gen3.engine("src.core.game3.battle.profile")
  local bp = BP and try(BP.get, Gen3.session()) or nil
  return type(bp) == "table" and bp or nil
end

-- Which first battle this is: the stand-in's (src/CoopField.lua classify3:
-- `firstBattleKind`, else the cart's battle profile's own), else the same
-- reading of the engine's opts -- `firstBattleKind`, the profile's
-- `kinds.firstBattle`, and failing both the shape (a wild fight is Birch's,
-- a trainer Oak's).  nil for anything else.
function M.which(ctx)
  local named = ctx.firstBattle3
  if M.KINDS[named] then return named end
  local opts = type(ctx.opts) == "table" and ctx.opts or {}
  if M.KINDS[opts.firstBattleKind] then return opts.firstBattleKind end
  local bp = profile()
  local own = bp and type(bp.kinds) == "table" and bp.kinds.firstBattle or nil
  if M.KINDS[own] then return own end
  return (ctx.kind == "wild") and "birch" or "oak"
end

-- ------------------------------------------------------------------
-- Birch's ZIGZAGOON
-- ------------------------------------------------------------------

-- The monster the fight is about to be seated with: the stand-in's (its cover
-- announced it), else the caller's, else built here the engine's way from the
-- encounter row (the item the start fixed, kept: rolled below).
local function wildMonOf(ctx)
  local opts = type(ctx.opts) == "table" and ctx.opts or {}
  for _, list in ipairs({ ctx.party, opts.party }) do
    local mon = type(list) == "table" and list[1] or nil
    if type(mon) == "table" and int(mon.species, 0) > 0 and type(mon.moves) == "table"
       and #mon.moves > 0 then
      return mon
    end
  end
  local enc = type(ctx.foe) == "table" and ctx.foe or nil
  if enc and type(enc.mon) == "table" and int(enc.mon.species, 0) > 0 then return enc.mon end
  if not enc then return nil end
  return Solo.gen3FoeMon(enc, { wild = true, heldRoll = false })
end

-- The held item pret gives it: SetUpBattleVarsAndBirchZigzagoon zeroes the
-- ZIGZAGOON's item (pokeemerald battle_controllers.c:70), then
-- CB2_InitBattleInternal runs SetWildMonHeldItem over gEnemyParty[0] whatever
-- the fight (battle_main.c:700: FIRST_BATTLE is not among its LEGENDARY |
-- TRAINER | PYRAMID | PIKE exemptions, pokemon.c:6678) -- one Random()
-- % 100 against the species' common / rare items, Compound Eyes in the lead
-- widening it.  The engine's own battle does the same at its start
-- (battle/init.lua's wildHeldItem pass); the stand-in builds the monster from
-- the start's `item = 0` and so never rolls -- so it is rolled here, through
-- the one statement of the roll (SoloBattle.gen3WildItem, the engine's
-- encounter rules on Emerald), once, on a monster still holding nothing.
-- -> the item (0 for none), or nil when nothing was rolled.
function M.rollHeldItem(ctx, mon)
  if type(mon) ~= "table" then return nil end
  if int(mon.item, 0) ~= 0 or int(mon.heldItem, 0) ~= 0 then return nil end
  if not Solo.gen3HeldRoll(ctx.opts, ctx.foe) then return nil end
  local species = int(mon.species, nil) or int(mon.speciesId, nil)
  if not species then return nil end
  local Rng = Gen3.engine("src.core.game3.rng")
  local function random16()
    local v = int(Rng and try(Rng.Random), nil)
    if v then return v % 65536 end
    return math.random(0, 65535)
  end
  local item = int(try(Solo.gen3WildItem, species, random16), 0)
  mon.item, mon.heldItem = item, item
  return item
end

-- The line a refused RUN prints: the cart's own (the battle profile names it,
-- profiles/emerald/battle.lua `firstBattle.cantRun`), out of the player's
-- text pack, else the fallback.
function M.cantRunText()
  local bp = profile()
  local fb = bp and type(bp.firstBattle) == "table" and bp.firstBattle or nil
  local id = (fb and type(fb.cantRun) == "string" and fb.cantRun ~= "") and fb.cantRun
    or M.DONT_LEAVE_BIRCH
  return Gen3.battleText(id) or M.DONT_LEAVE_BIRCH_TEXT
end

-- ------------------------------------------------------------------
-- the kind
-- ------------------------------------------------------------------

local First = {}

-- Oak's is a trainer fight, Birch's a wild one; the other shape of either is
-- no first battle the carts have, and is handed back.
function First:takes(ctx)
  local which = M.which(ctx)
  if which == "oak" then
    if ctx.kind ~= "trainer" then return false, "PROF. OAK's lab is a trainer battle" end
  elseif which == "birch" then
    if ctx.kind ~= "wild" then return false, "PROF. BIRCH's rescue is a wild battle" end
    local mon = wildMonOf(ctx)
    if not mon then return false, "no ZIGZAGOON" end
    M.rollHeldItem(ctx, mon)
    ctx.wildMon = mon
    ctx.party = { mon }
  else
    return false, "no such first battle"
  end
  ctx.firstBattle3 = which
  return true
end

function First:screen(ctx, screenOpts)
  screenOpts.firstBattle = ctx.firstBattle3
end

-- The referee's first-battle rules, and Birch's ZIGZAGOON on AI_FirstBattle
-- (pokeemerald battle_ai_script_commands.c:365, data/battle_ai_scripts.s
-- AI_FirstBattle).
function First:seat(ctx, create)
  if ctx.firstBattle3 == "birch" then
    local foe = create.sides.b[1]
    if foe then foe.ai = "firstBattle" end
  end
  return { firstBattle = ctx.firstBattle3 }
end

-- Birch's RUN, in pret IsRunningFromBattleImpossible's order (pokeemerald
-- battle_main.c:4021): a SMOKE BALL or RUN AWAY gets away (the referee takes
-- it); a trap holds the runner with its own line (the core's, below); and
-- otherwise FIRST_BATTLE refuses it with "Don't leave me like this!" -- the
-- action menu back, nothing spent.
function First:choose(ctx, payload, seat)
  if ctx.firstBattle3 ~= "birch" or type(payload) ~= "table" or payload.action ~= "run" then
    return false
  end
  local solo, sim = ctx.solo, ctx.sim
  if not (solo and sim) then return false end
  if solo:file3(payload, seat) then return true, true end
  local fighter = type(sim.byId) == "table" and sim.byId[seat or M.PLAYER] or nil
  local b = fighter and fighter.b
  if b and type(sim.isTrapped) == "function" and try(sim.isTrapped, sim, b) == true then
    return false
  end
  local okA, Abilities = pcall(need, "BattleSim3/Abilities")
  if b and okA and type(Abilities) == "table" and type(Abilities.escapeBlocker) == "function"
     and try(Abilities.escapeBlocker, sim, b) ~= nil then
    return false
  end
  solo:parkLine3(M.cantRunText())
  return true, true
end

M.First = First
M.kinds3 = { firstBattle = First }

return M
