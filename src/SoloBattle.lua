-- The mod's own battle system, for a player with nobody to play with.
--
-- Everything else this mod does is an addition: a nameplate over a stranger, a
-- bubble, a trade with somebody three routes away, a partner in a fight that
-- could not otherwise exist. This is the one thing it *substitutes*. With the
-- SOLO BATTLES row on, an ordinary wild encounter and every trainer in the game
-- are fought on `src/MediatedBattle.lua`'s screen, refereed by
-- `src/BattleSim/`, instead of on the engine's own `BattleState` -- and with it
-- off, or on a battle kind this file declines, the vanilla battle runs and none
-- of this is reachable at all.
--
-- ------- why a solo fight does not go near the wire
--
-- The obvious way to build this was to open a one-member battle on the hub and
-- let the existing mediated path do the rest. It does not work, and the reasons
-- are worth writing down because they are the whole shape of this file:
--
--   * A hub battle with one member seats the *same* client id on both sides
--     (`Hub.lua:1307`) with no npc seats, so nothing ever answers side b. The
--     fight opens and then hangs, forever, looking healthy.
--   * `Hub:openMediatedBattle` deals an NPC party round-robin across every
--     `Config.COOP_SIDE` seat before it reads the plan's sides, so narrowing
--     side b to one fighter silently orphans monsters -- a three-mon trainer
--     arrives on the field two mons deep.
--   * And it would put a socket, a protocol version and a Node twin between a
--     single-player game and its own battles.
--
-- So this file *is* the referee. It builds a `Turn` in this process, pumps it
-- once a frame, and feeds the events it produces to a `MediatedBattle` screen
-- through a transport that is a plain table. Nothing here sends a message,
-- bumps `Config.PROTOCOL`, adds a `Wire` type, touches `server/`, or asks the
-- turn machine for a new mode. `src/BattleSim/Turn.lua` has a JavaScript twin
-- with parity fixtures over it; the single most important property of this
-- feature is that it did not need that file to move a byte.
--
-- ------- what the screen is, and what it is not
--
-- `MediatedBattle` is a *client* of a referee it does not run. From its side
-- there is no difference between a referee across a wire and one on the other
-- side of this table: it uploads what it is bringing, receives an ordered event
-- stream, and files choices. That is why it is reused whole rather than forked
-- -- and it is also why the fake transport below is the only seam this file
-- needs. Choices arrive as `Wire.BATTLE_CHOICE` payloads and go into the local
-- `Turn`; events come back out of the `Turn` and go into `fight:onEvent`.
--
-- ------- the two seatings, and why they are different
--
-- A wild fight is seated `Config.SOLO_WILD_MODE` ("wild") and a trainer fight
-- `Config.SOLO_TRAINER_MODE` ("coop_npc"), one fighter per side either way with
-- the trainer's whole bench carried on that single fighter. The difference is
-- mechanical rather than descriptive: `Effects.isWildMode` gates catching and
-- fleeing on `mode:find("wild")`, so a trainer fight seated as `wild` is a
-- fight where a Poke Ball lands on BROCK's ONIX and keeps it. Under `coop_npc`
-- the same throw hits the referee's own refusal instead, and that refusal
-- *costs* what Gen 1 costs -- the ball is gone and the turn is spent, exactly
-- as `BattleState:throwBall`'s non-wild arm charges for it -- without a line of
-- the referee moving. It does not *say* what Gen 1 says: the cart prints "The
-- trainer blocked the BALL!" and "Don't be a thief!", the referee prints "used
-- an item" and "But it failed". Right price, wrong words, and worth knowing
-- which half is which. See Config's solo section for the rest of that
-- argument, including why it is not `1v1`.
--
-- ------- who writes what to the save, which is the part to get right
--
-- A solo battle writes to the player's real party, and there is no commit
-- boundary anywhere in it. **Almost none of that writing happens in this
-- file**, and finding that out was the point:
--
--   * **Experience, levels and the moves a level teaches** are applied by
--     `MediatedBattle:gainExp` as the `exp` events arrive, through the engine's
--     own `Experience.apply` / `src/Exp2.lua`, onto `game.save.party`.
--   * **A caught monster** is added by `MediatedBattle:grantCatch`, through
--     `Party.add` and then `Boxes.deposit`.
--   * **Bag items** -- balls included -- are debited from `game.save.inventory`
--     by `MediatedBattle:confirmPendingItem` when the referee confirms the use,
--     and a vitamin's Stat Exp is written back there too.
--   * **Prize money, the defeated-trainer flag, badges, TMs, the script that
--     was waiting in front of the trainer and the blackout** are the buried
--     engine battle's, and are run by the `src/Coop.lua` statics that were
--     lifted out of the co-op path for exactly this caller.
--
-- What is left -- the *only* reconciliation this file performs -- is **HP, PP
-- and status**. Those live on the referee's private copy of the party and
-- nothing else brings them home: an online mediated fight deliberately leaves
-- them there (a duel with a stranger does not cost you a potion), and a solo
-- fight is the one place that would be wrong. Adding a second exp path or a
-- second catch path here would corrupt saves, so this file does neither.
--
-- ------- ordering, at the end
--
-- The party is reconciled *first*, before anything else in the ending runs,
-- and that is load-bearing rather than tidy. `Coop.blacksOut` decides a
-- whiteout by asking whether anything in `game.save.party` is still standing --
-- and until the fight's damage has landed on those monsters the answer is
-- always "yes, all of them". Reconcile after, and a player whose team was wiped
-- walks out of the fight healthy.
--
-- Shaped like Coop and Sessions -- a ui handed in at construction, no engine
-- modules and no love at file scope -- which is what lets a headless suite
-- drive a whole fight under plain luajit.
--
-- ------- Gen 3 (FireRed / LeafGreen / Emerald), which has no buried battle
--
-- Everything above describes a divert: the engine pushes its own battle, the
-- `screen.pushed` listener sees it, and this file slides its screen over the
-- top and later hands the frozen battle its result.  A Gen 3 boot has no
-- such moment -- the game3 engine fires no `screen.pushed`, keeps no
-- game.stack, and its battle is a module-level singleton (battle/init.lua)
-- that is either running or not.  So on Gen 3 the fight is *taken before it
-- starts*: src/Client.lua cancels the engine's own (a wild encounter at
-- `encounter.roll`, a trainer at the script's `trainerbattle`) and calls
--
--   solo:fromGen3Encounter(game, encounter, opts)
--   solo:fromGen3Trainer(game, foe, opts)
--
-- (see their own headers below for the exact inputs).  True means this file
-- owns the fight and will call `opts.done(result)` at most once when it is
-- over, in the engine's own vocabulary (never for a trainer drawn with the
-- player still standing: that script is halted -- see M:_ended3); false
-- means it declined and nothing
-- at all has happened.  With no buried battle to finish, the rewards the
-- engine's battle would have paid are paid here, the cart's way: the prize
-- (battle/prize.lua), Pickup, the whiteout (battle_bridge's money loss and
-- Field.respawnAtHeal), the after-battle evolutions (EvolutionScene), and
-- what the engine does as its own battle ends (Emerald's Pokérus and TV,
-- FireRed's quest log, `battle.ended` -- M:_finishEffects3).  Exp, Pay Day,
-- a level's moves, the catch and the bag are still the screen's, on its Gen 3
-- arm, exactly as the header says for Gen 1.  The referee is
-- src/BattleSim3, the sheets src/Sheet3.lua's; the arena / classic GBA page
-- and the music are MediatedBattle's Gen 3 arm unchanged.  A lone trainer
-- double (one trainer sending out two) is the one Gen 3 fight with a second
-- screen: two seats a side over one shared team each on the referee, and
-- CoopBattle's solo double in front of it (M:_doubleScreen3) -- see
-- docs/plans/gen3-solo-doubles.md.  Every other fight the carts start (the
-- Safari Zone, roamers and legendaries, the ghosts, the facilities, two
-- trainers, Steven, the first battles, the tutorials) is this same fight
-- with a few rules moved, and each family's rules are a *kind* registered
-- from src/Solo3/ (M.registerKind3, contract C2 of
-- docs/plans/gen3-solo-remaining-fights.md): hooks the core calls at its
-- own points, every computer seat on either side answered by its owner's
-- brain (M:_answerNpcs3), and the engine's outcome word read off how the
-- referee says the fight ended (M.gen3Words).  A fight whose kind nobody
-- registered stays the cart's.

local need, mod = ...
local Config = need("Config")
local Wire = need("Wire")
local Gen = need("Gen")
local Coop = need("Coop")
local CoopField = need("CoopField")
local EvolveFx = need("EvolveFx")
local MediatedBattle = need("MediatedBattle")
local SoloBrain = need("SoloBrain")
-- The Gen 3 adapters (lazy and guarded: nothing of src.core.game3.* is reached
-- off a Gen 3 boot), the Gen 3 sheet builder and the learn prompt.
local Gen3 = need("Gen3")
local Gen3Ui = need("Gen3Ui")
local Sheet3 = need("Sheet3")
local LearnMove = need("LearnMove")

local M = {}
M.__index = M

local floor, max, min = math.floor, math.max, math.min

-- The mod-manager row this file is gated on.
--
-- Named here rather than in Config because it is a *key*, not a number the
-- referee or its twin could ever read -- and because src/Client.lua, which
-- defines the row, and this file, which reads it, are the only two things that
-- need to agree on the spelling. Exported so they agree by construction.
M.OPTION = "solo"
M.OPTION_LABEL = "SOLO BATTLES"

-- The two seats, as ids the referee can hold.
--
-- Word characters only: a choice leaves the screen through
-- `MediatedBattle.submitChoice`, which runs it past `Wire.battleChoice` before
-- handing it to the transport, and a battle id with punctuation in it would be
-- refused there -- by a sanitiser guarding a wire this fight never touches.
local PLAYER_SEAT = "solo_player"
local FOE_SEAT = "solo_foe"

-- ------------------------------------------------------------------
-- the referee, per generation
-- ------------------------------------------------------------------
--
-- `Hub.battleSimFor`'s rule, and for its reason: Gold's turn machine is a
-- separate twin under src/BattleSim2/, and a Gen 2 fight refereed by the Gen 1
-- one would be a Gold battle fought under Red's rules. Resolved per fight
-- rather than at load, because `Gen.generation` is a property of the game that
-- is running and a build may hold both.
local function turnFor(generation)
  if generation == 3 then return need("BattleSim3/Turn") end
  if generation == 2 then return need("BattleSim2/Turn") end
  return need("BattleSim/Turn")
end
M.turnFor = turnFor

-- ------------------------------------------------------------------
-- reading the state the engine just pushed
-- ------------------------------------------------------------------

-- Which kind of fight this is, in both generations' spellings.
--
-- Gen 1's `BattleState` says so outright. Gen 2's is a shell around a
-- `gen2.Battle` and says nothing at all: the fight's nature is `battle.wild` or
-- `battle.trainer` one level down. The same aliasing `Coop:onTrainerBattle` and
-- `Coop:onWildEncounter` do, in one place, because a third caller getting it
-- half right would divert Gold's wild encounters and none of its trainers.
--
-- A link battle, a co-op screen and this mod's own mediated screen all answer
-- nil, which is how the whitelist stays a whitelist: this file takes `wild` and
-- `trainer` and nothing else, so a battle kind that has not been thought about
-- is declined by not being named rather than by being remembered.
function M.kindOf(state)
  if type(state) ~= "table" then return nil end
  local kind = state.kind
  if kind == "wild" or kind == "trainer" then return kind end
  if kind ~= nil then return nil end
  local inner = state.battle
  if type(inner) ~= "table" then return nil end
  if inner.wild then return "wild" end
  if inner.trainer then return "trainer" end
  return nil
end

-- The fights inside that whitelist which are handed straight back.
--
-- Safari, the Marowak ghost and the Viridian old man's demonstration are all
-- spelled as ordinary encounters and then mutated into something `BattleSim`
-- has no model for -- a BALL / BAIT / ROCK / RUN menu over a step and ball
-- budget, an opponent that cannot be hit or caught until the Silph Scope, a
-- scripted throw that is meant to land on cue. Running one of them through a
-- referee that models none of it would not be a worse battle, it would be a
-- wrong one. See Config.SOLO_REFUSED.
--
-- Checked one level down as well, for the same reason M.kindOf is: a Gen 2
-- state that ever carries one of these carries it on the inner battle -- and
-- Gold does carry them. It carries them under its own names (`contest` for the
-- Bug-Catching Contest, `tutorial` for the DUDE's demonstration, `roaming` for
-- a beast), which is why the list in Config has a Gen 2 half; and it carries
-- two of them as a *number* on `battleType` rather than as a field at all,
-- which is why there is a second, value-keyed set beside it. A number is truthy
-- whatever it is, so a name loop asked about `battleType` would refuse every
-- Gen 2 battle ever fought.
--
-- Both spellings are checked at both levels. The state and its inner battle
-- disagree about where each of these lives depending on which layer set it --
-- `contest` and `tutorial` are the screen's, `roaming` and `battleType` are the
-- battle's -- and asking all four questions is cheaper than remembering which.
function M.refused(state)
  if type(state) ~= "table" then return false end
  local inner = type(state.battle) == "table" and state.battle or nil
  for _, field in ipairs(Config.SOLO_REFUSED) do
    if state[field] then return true end
    if inner and inner[field] then return true end
  end
  local byValue = Config.SOLO_REFUSED_BATTLE_TYPES
  if type(byValue) == "table" then
    local outer = tonumber(state.battleType)
    if outer and byValue[outer] then return true end
    local within = inner and tonumber(inner.battleType) or nil
    if within and byValue[within] then return true end
  end
  return false
end

-- Whose party side a is. Cosmetic -- the referee narrates a seat by this name
-- -- but a fight where the box says "solo_player used TACKLE" is not a fight
-- anybody would ship, and both generations keep the name in the same place.
local function playerName(game)
  local save = game and game.save
  local name = save and (save.playerName or (save.player and save.player.name))
  if type(name) == "string" and name ~= "" then return name end
  return "PLAYER"
end

-- The trainer's party, wherever this generation keeps it. `Coop.wildMonOf` is
-- the wild half's twin and is used as-is.
local function enemyPartyOf(state)
  if type(state) ~= "table" then return nil end
  local party = state.enemyParty
  if type(party) == "table" and #party > 0 then return party end
  local inner = state.battle
  if type(inner) == "table" and type(inner.enemyParty) == "table"
     and #inner.enemyParty > 0 then
    return inner.enemyParty
  end
  return nil
end

-- What to call the thing on the other side of the field.
--
-- The class id with its OPP_ prefix and its underscores taken off, which is
-- what `Coop:onTrainerBattle` builds its label from and what the screen prints
-- in "X wants to fight!". A script-driven battle need not name a class, and
-- "TRAINER" is a better answer than refusing the whole divert over a caption.
local function foeName(state)
  local trainer = SoloBrain.trainerOf(state)
  local class = state.oppClass
    or (trainer and (trainer.classId or trainer.class))
  local label = Wire.label(tostring(class or ""):gsub("^OPP_", ""):gsub("_", " "))
  if type(label) == "string" and label ~= "" then return label end
  return "TRAINER"
end

-- The referee spells a condition as a word ("sleep") and the engine spells it
-- as the three-letter token the wire also uses ("SLP"). One table, inverted
-- from the referee's own, so neither vocabulary is written out twice.
local STATUS_TOKEN = {
  sleep = "SLP", poison = "PSN", burn = "BRN",
  freeze = "FRZ", paralysis = "PAR", toxic = "TOX",
}

local function statusToken(status)
  if type(status) ~= "string" or status == "" then return nil end
  return STATUS_TOKEN[status] or status
end

-- ------------------------------------------------------------------
-- small helpers over a fighter
-- ------------------------------------------------------------------
--
-- Three predicates the turn machine keeps to itself (`Battle:_owes`,
-- `firstLiving`, `activeMon`), restated here rather than reached for. They are
-- read-only questions about a table this file already holds, and the
-- alternative -- calling a private method across a module boundary -- is a
-- dependency on an implementation detail of the one file in this repo that is
-- not allowed to change.

-- ...including a Gold monster `standing` at 0 HP (BattleSim2 Turn's
-- `activeMon`, wave 5): one SPIKES or PERISH SONG left at 0 has not fainted
-- until the cart's next faint check finds it, and until then it is asked for
-- a choice and acts -- so the trainer's seat is answered for it too
-- (`autoPick`: Gold builds no brain), or a solo fight with no choice deadline
-- (SOLO_CHOICE_TIMEOUT) waits on it forever.
local function activeOf(fighter)
  local mon = fighter and fighter.mons and fighter.mons[fighter.active]
  if mon and ((tonumber(mon.hp) or 0) > 0 or mon.standing == true) then return mon end
  return nil
end

-- A monster that can still fight for its side.  A Battle Arena loser the
-- judge "fainted" keeps its HP and is down all the same (pret
-- battle_script_commands.c:3534 Cmd_checkteamslost skips arenaLost*Mons;
-- the referee's `judged`, BattleSim3/Arena.lua).
local function hasLiving(fighter)
  for _, mon in ipairs((fighter and fighter.mons) or {}) do
    if (tonumber(mon.hp) or 0) > 0 and not mon.judged then return true end
  end
  return false
end

-- Does this seat owe the referee an answer right now?
--
-- Asked before the seat is answered, and that is the whole reason it exists:
-- a brain built in `src/SoloBrain.lua` keeps state a speculative call would
-- move -- Gen 3's spends the trainer's item slots (ShouldUseItem) and draws
-- from the RNG, a registered Red brain draws and counts the monster's turns --
-- so asking it on a turn nobody owes spends a gym leader's FULL RESTORE on
-- nothing. `Turn:autoPick` refuses politely when a seat owes nothing; a brain
-- has no way to know.
-- A shared team's emptied seat (BattleSim3's `seats = 2`, a Gen 3 double) is
-- owed a monster only while the bench still holds one after every sibling
-- *ahead* of it that is owed one too -- `Battle:_canRefill`, restated like the
-- three above (pret HandleFaintedMonActions walks the battlers in order), over
-- the referee's public `benchOf`, which already leaves out the partner's
-- active monster and its claim.  Both seats down and one monster left: only
-- the first is asked.
local function canRefill(sim, fighter)
  local ok, bench = pcall(sim.benchOf, sim, fighter)
  if not (ok and type(bench) == "table") then return hasLiving(fighter) end
  local n = #bench
  for _, seat in ipairs(fighter.seats) do
    if seat == fighter then break end
    if seat.mustReplace and seat.choice == nil then n = n - 1 end
  end
  return n > 0
end

local function owes(sim, fighter)
  if not (sim and fighter) then return false end
  if fighter.choice ~= nil then return false end
  -- A seat with no battler (the referee's side-entry `noBattler`: the old
  -- man's, Wally's, the Safari player's) has nothing on the field to replace
  -- and no monster to ask about: it owes its choice -- a throw, a RUN, the
  -- tutorial's scripted input -- in the choice phase and nothing else
  -- (BattleSim3 Turn:autoPick / _autoChoiceOrSkip: the same rule).
  if fighter.noBattler then return sim.phase == "choice" end
  if fighter.mustReplace then
    if type(fighter.seats) == "table" and #fighter.seats > 1 then
      return canRefill(sim, fighter)
    end
    return hasLiving(fighter)
  end
  if sim.phase == "replace" then return false end
  if sim.phase ~= "choice" then return false end
  return activeOf(fighter) ~= nil
end

-- ------------------------------------------------------------------
-- construction
-- ------------------------------------------------------------------

-- opts:
--   enabled  function() -> boolean; whether the SOLO BATTLES row is on. The
--            default reads the row itself, at the encounter rather than at
--            install, so a player who flips it mid-session gets it on the next
--            battle and not on the next launch.
--   seed     function() -> integer, for a suite that wants a reproducible
--            fight. The default is the same love-then-math roll SoloBrain uses.
--   random   function() -> 0..255, the byte source for the rolls the cart
--            makes outside the referee (Gold's wild held item). Same default.
function M.new(ui, opts)
  opts = opts or {}
  return setmetatable({
    ui = ui,
    enabled = opts.enabled,
    seedFn = opts.seed,
    randomFn = opts.random,

    -- The live fight, or nothing. All five are set together and cleared
    -- together: half of a solo battle is not a state this file can be in.
    fight = nil,      -- the MediatedBattle screen
    sim = nil,        -- the Turn refereeing it
    brain = nil,      -- SoloBrain: a Gen 3 trainer's, or a Red trainer's registered `brain`
    engine = nil,     -- the frozen engine BattleState buried underneath
    game = nil,

    kind = nil,       -- "wild" | "trainer"
    generation = nil, -- 1 or 2, for the arithmetic that differs between them
    mapId = nil,      -- where it was walked into, for a caller that asks
    reason = nil,     -- the referee's own word for how it ended
    wildMon = nil,    -- the engine's wild monster, for the catch grant
    settled = false,  -- the outcome has been handed to the screen
    refuseRun = nil,  -- a RUN the trainer path declined, owed a fresh menu
    failedRun = nil,  -- a wild RUN the escape roll refused, owed a spent turn
    runAttempts = 0,  -- escape attempts this fight; the odds climb with it
    faults = 0,       -- consecutive frames the referee threw in -- see M:_pump
    counter = 0,      -- battle ids, so two fights in a session never collide
    clock = 0,        -- seconds since this fight opened; the referee's `now`
    seq = 0,          -- our own event numbering -- see M:_feed

    -- Level per save-party monster as the fight opened, so what levelled can
    -- be handed to the engine's evolution check. See M.levelledSince.
    levels = nil,
    -- The save table this fight belongs to, so a load mid-battle cannot make
    -- us write one playthrough's damage onto another's party.
    save = nil,

    -- Coop.blackout parks its deferred warp here and Coop.pumpBlackout takes
    -- it from here. Ours to own, because a holder that never pumps leaves the
    -- player healed, taxed and standing where they lost.
    pendingWarp = nil,

    -- One warning per fight per reason: this runs inside a per-frame pump, and
    -- a log line a frame describes one fact several hundred times.
    warned = nil,

    -- Gen 3 only: everything a fight with no buried battle has to remember
    -- about itself (the caller's `done`, the foe it was given, the session it
    -- opened against, the verdict and what it costs).  See M:_begin3.
    gen3 = nil,
    cantEscape = nil, -- a trapped Gen 3 RUN's line, owed a fresh menu
    -- Set only while M:_handBack3 is starting the engine's own battle: that
    -- start goes back through src/Client.lua's divert, which would offer the
    -- very fight being handed back to this file again (and again).
    handingBack3 = false,
  }, M)
end

function M:isRunning() return self.fight ~= nil end

-- Whether the row is on. Read through a function so the suite can drive both
-- answers without a mod facade, and defaulted to the row itself so a caller
-- that hands in nothing still gets the player's own setting.
function M:isOn()
  local ask = self.enabled
  if type(ask) == "function" then
    local ok, on = pcall(ask)
    return ok and on == true
  end
  local ok, on = pcall(function() return mod.options:get(M.OPTION) end)
  return ok and on == true
end

function M:warn(key, message, ...)
  self.warned = self.warned or {}
  if self.warned[key] then return false end
  self.warned[key] = true
  mod.log:warn(message, ...)
  return true
end

-- ------------------------------------------------------------------
-- the divert
-- ------------------------------------------------------------------
--
-- Called from src/Client.lua's `screen.pushed` listener, after co-op has had
-- its turn: co-op keeps priority wherever it applies, and this only ever sees
-- an encounter it declined.
--
-- **False is silent, always.** A player who has this off, or who walked into a
-- Safari fight, or whose party could not be described, is told nothing at all,
-- because from where they are standing nothing happened -- the engine's own
-- battle is on screen and about to be fought exactly as it always was. The one
-- thing that is never acceptable here is a refusal the player has to read.

function M:onWildEncounter(game, state, mapId)
  return self:_divert(game, state, mapId, "wild")
end

function M:onTrainerBattle(game, state, mapId)
  return self:_divert(game, state, mapId, "trainer")
end

function M:_divert(game, state, mapId, wanted)
  if not self:isOn() then return false end
  -- One fight at a time. A second divert while one is running would put two
  -- screens over one buried battle and hand it two results.
  if self.fight then return false end
  if not (game and type(state) == "table") then return false end
  if M.kindOf(state) ~= wanted then return false end
  if M.refused(state) then return false end
  -- Something else is already a fight on this stack -- a co-op screen, a link
  -- battle, a mediated 1v1 an invite opened. The just-pushed encounter is
  -- excluded, since it is the reason we are being asked.
  if Coop.stackHasFightExcept(game, state) then return false end
  -- Gen 3 is never diverted from here: its engine raises no `screen.pushed`
  -- (a game3 battle is a module, not a pushed state), so src/Client.lua takes
  -- a Gen 3 fight where it starts and hands it to `fromGen3Encounter` /
  -- `fromGen3Trainer` instead.  Whatever reaches this with a Gen 3 game is
  -- declined, silently, like any other fight this file does not model.
  if Gen.generation(game) == 3 then return false end
  return self:_begin(game, state, mapId, wanted)
end

-- ------------------------------------------------------------------
-- building the fight
-- ------------------------------------------------------------------

function M:_seed()
  local pick = self.seedFn
  if type(pick) == "function" then
    local ok, value = pcall(pick)
    local n = ok and tonumber(value)
    if n then return floor(n) end
  end
  local love_ = rawget(_G, "love")
  local roll = love_ and love_.math and love_.math.random or math.random
  local ok, value = pcall(roll, 0, 2147483647)
  if ok and tonumber(value) then return floor(value) end
  return 0
end

-- One byte (0..255) for a roll the cart makes outside the referee -- today
-- Gold's wild held item (MediatedBattle.rollWildItem2).  The suite's `random`
-- when it handed one in; otherwise the love-then-math roll `_seed` uses.  Never
-- the referee's own stream, which belongs to the fight -- and, sharing that
-- roll with `_seed`, drawn only after the fight's seed (M:_begin), so no byte
-- from here moves it.
function M:_randomByte()
  local pick = self.randomFn
  if type(pick) == "function" then
    local ok, value = pcall(pick)
    local n = ok and tonumber(value)
    if n and n == n then return floor(n) % 256 end
  end
  local love_ = rawget(_G, "love")
  local roll = love_ and love_.math and love_.math.random or math.random
  local ok, value = pcall(roll, 0, 255)
  if ok and tonumber(value) then return floor(value) % 256 end
  return 0
end

-- Gold's wBattleType as the engine battle underneath holds it (`battleType`
-- on the gen2 Battle, src/battle/gen2/Battle.lua -- the shell BattleState
-- carries the battle as `state.battle`), or the state's own; nil without one.
local function engineBattleType(state)
  if type(state) ~= "table" then return nil end
  local inner = type(state.battle) == "table" and state.battle or nil
  return tonumber(inner and inner.battleType) or tonumber(state.battleType)
end

function M:_begin(game, state, mapId, kind)
  local generation = Gen.generation(game)
  local Turn = turnFor(generation)
  if type(Turn) ~= "table" or type(Turn.create) ~= "function" then
    self:warn("noturn", "the mod's battle referee could not be loaded, so "
      .. "this fight runs on the ordinary battle system; solo battles will "
      .. "keep falling back until the mod is reinstalled")
    return false
  end

  -- What the other side is bringing, described the same way a party is
  -- described for a hub -- move records, type indices, stats and all. The
  -- monsters themselves are the engine's own: `enemyParty` for a trainer,
  -- `enemy.mon` for a wild, both already rolled and built by the battle
  -- sitting underneath us.
  local wildMon, enemySheets
  -- Gold's wild monster comes out of the engine holding nothing (its Mon.lua
  -- does not roll one), so the cart's own roll is made here, onto the engine
  -- monster -- the one a catch keeps -- before its sheet is cut
  -- (MediatedBattle.rollWildItem2, pokecrystal LoadEnemyMon `.WildItem`).  Off
  -- this file's own byte source (M:_randomByte), never the referee's stream --
  -- and only once the fight's seed is drawn: with no suite hooks in,
  -- `_randomByte` and `_seed` both draw love.math.random, so a roll ahead of
  -- the seed would move it by one or two draws whenever the species has item
  -- slots.  Drawn first (`seed`, handed to the referee below), it is the same
  -- draw with slots or without.  Every other fight draws it where it always
  -- has, at the referee.  The roll is undone if the divert declines after
  -- all, so the engine's own battle starts exactly as the engine built it --
  -- "false means nothing at all has happened".
  local seed
  local rolledItem, itemBefore = false, nil
  local function undoRoll()
    if rolledItem and wildMon then wildMon.item = itemBefore end
    rolledItem = false
  end
  if kind == "wild" then
    wildMon = Coop.wildMonOf(state)
    if not wildMon then return false end
    if generation == 2 then
      seed = self:_seed()
      itemBefore = wildMon.item
      local inner = type(state.battle) == "table" and state.battle or nil
      MediatedBattle.rollWildItem2(game, wildMon, {
        battleType = (inner and inner.battleType) or state.battleType,
        random = function() return self:_randomByte() end,
      })
      rolledItem = wildMon.item ~= itemBefore
    end
    -- With Gold's dex weight on it (contract K21, HEAVY BALL).
    enemySheets = MediatedBattle.snapshotWild(game, wildMon)
  else
    local party = enemyPartyOf(state)
    if not party then return false end
    enemySheets = MediatedBattle.snapshotMons(game, party)
  end
  if type(enemySheets) ~= "table" or #enemySheets == 0 then
    undoRoll()
    self:warn("nofoe", "the opponent in this battle could not be described "
      .. "for the mod's battle system, so it is fought the ordinary way; "
      .. "report this with the trainer or the species you met")
    return false
  end

  self.counter = self.counter + 1
  local battleId = ("solo_%d"):format(self.counter)
  local mode = (kind == "wild") and Config.SOLO_WILD_MODE
    or Config.SOLO_TRAINER_MODE

  -- The screen, and the transport that is a table.
  --
  -- Built before the referee, because the referee is built out of what the
  -- screen uploads: `MediatedBattle:start` describes the player's party, bag
  -- and badges exactly as it would for a hub, and taking side a from that
  -- upload rather than snapshotting the party a second time is what guarantees
  -- the sheets the referee is fighting with are the same tables the screen
  -- holds in `mine`. Two snapshots would agree today and drift the first time
  -- one of them learned to skip something the other did not -- and the index
  -- they disagreed about is the one exp is paid on.
  local pending = {}
  local fight = MediatedBattle.new({
    transport = self:_transport(pending),
    ui = self.ui,
    game = game,
    battle = battleId,
    role = "host",
    -- A wild fight leaves peerId unset on purpose: `MediatedBattle:onReady`
    -- fills it from the announced side b, which is the path the wild screen
    -- was written for. A trainer fight names the seat, because that is what
    -- `resultFor` reads the verdict against.
    --
    -- Spelled with a branch rather than `x and nil or y`, which is the one
    -- ternary Lua does not have: `true and nil` is nil and `nil or y` is y, so
    -- that idiom hands back the *false* arm on both sides of the test and this
    -- line quietly named the seat on the wild path it was written to leave
    -- empty. Harmless as it turned out -- `onReady` sets the same value one
    -- call later -- but see the bag below, where the same shape was not.
    peerId = (kind ~= "wild") and FOE_SEAT or nil,
    peerName = (kind == "wild") and "WILD" or foeName(state),
    -- The NPC record, so the arena can stand them on the foe edge.
    --
    -- The screen reads it for one thing -- `Gen.trainerWalkSpriteId`, the same
    -- class-to-walk-sheet resolution `CoopBattle:battlefieldFoeHumans` does --
    -- and without it a solo trainer fight drew the placeholder silhouette
    -- there, because the only other figure a `coop_npc` seat could name is a
    -- peer and a solo fight has none. Nil on a wild fight, where the foe edge
    -- is correctly empty.
    trainer = (kind ~= "wild") and SoloBrain.trainerOf(state) or nil,
    npcParty = (kind ~= "wild") and enemySheets or nil,
    mode = mode,
    wildParty = (kind == "wild") and enemySheets or nil,
    wildCatchMon = wildMon,
    -- Gold's wBattleType off the engine battle underneath (contract K21),
    -- which the screen states on its ruleset: LURE BALL reads it.
    battleType = (generation == 2) and engineBattleType(state) or nil,
    onDone = function(result, toLearn) self:_ended(result, toLearn) end,
  })

  local started = fight:start(game)
  local mine = pending.party
  if not (started and type(mine) == "table" and type(mine.mons) == "table"
          and #mine.mons > 0) then
    -- `start` already said why (an empty or undescribable party) and finished
    -- the screen it never pushed. Nothing has been taken over, so the engine's
    -- own battle is still on the stack and still about to run.
    undoRoll()
    return false
  end

  local sides = {
    a = { {
      playerId = PLAYER_SEAT,
      name = playerName(game),
      mons = mine.mons,
      bag = mine.bag,
      -- **Rebuilt as a set, not passed on as the list it was uploaded as.**
      -- On the online path the badges cross `Wire.badges`, which turns the
      -- list into the set `Turn.copyBadges` indexes; skipping the wire skips
      -- that conversion, and a list arrives at `copyBadges` as integer keys
      -- and is dropped whole. The symptom would have been every badge boost
      -- silently missing from every solo fight -- a fight that runs, and runs
      -- wrong.
      badges = Wire.badges(mine.badges),
      -- Gold's cart lineage (contract K6 of docs/plans/gen12-referee-fidelity
      -- .md): the referee reads side a's first fighter for the rules Gold /
      -- Silver and Crystal disagree on (TruncateHL_BC's loop).  A hub stamps it
      -- from the hello it admitted; with no hub, this file is the one that
      -- knows which cart is running.  Gen 1 carries none, and Gen 3 never
      -- reaches this table (M:_begin3).
      family = (generation == 2) and Gen.family(game) or nil,
    } },
    b = { {
      playerId = FOE_SEAT,
      -- A trainer is named as the cart's lines name it -- the record's own
      -- name, which the screen's NPC upload carries (MediatedBattle.npcSeat:
      -- pokered's wTrainerName, a rival's chosen name included; Gold's
      -- "YOUNGSTER JOEY") -- the class label without one.
      name = (kind == "wild") and (enemySheets[1].species or "WILD")
        or (pending.wild and type(pending.wild.name) == "string" and pending.wild.name)
        or foeName(state),
      mons = enemySheets,
      -- No bag: Red and Gold upload no NPC kit (contract K16,
      -- MediatedBattle.trainerBagEntries) -- their referees run the cart's
      -- item AI off the class data below and read no bag for it.
      -- Red's trainer move-choice layers, off the same upload: the referee
      -- runs them for every pick it makes for this seat (`autoPick` ->
      -- `_computerChoice`), which is every pick there is unless a mod
      -- registered a `brain` for the trainer (src/SoloBrain.lua) -- the
      -- path a hub's coop_npc computer seat takes.
      aiMods = (kind ~= "wild" and pending.wild) and pending.wild.aiMods or nil,
      -- ...and the class's own data (contract K16, MediatedBattle.npcSeat),
      -- which the referee runs the cart's item and switch AI from at the
      -- cart's point in the turn: Red's ai_classes record, Gold's class
      -- attributes.  What a hub copies onto the NPC seat, copied here.
      aiClass = (kind ~= "wild" and pending.wild) and pending.wild.aiClass or nil,
      trainerItems = (kind ~= "wild" and pending.wild) and pending.wild.trainerItems or nil,
      aiFlags = (kind ~= "wild" and pending.wild) and pending.wild.aiFlags or nil,
      itemSwitch = (kind ~= "wild" and pending.wild) and pending.wild.itemSwitch or nil,
      baseReward = (kind ~= "wild" and pending.wild) and pending.wild.baseReward or nil,
      -- Gold / Silver's count-as-species types (contract K23,
      -- MediatedBattle.countSpeciesTypes2): the types of the species numbered
      -- the party's size, which pokegold's FindEnemyMonsThatResistPlayer reads
      -- for its first pass.  The one seat holds the whole party here, so it
      -- is the count the upload stated it for.
      countSpeciesTypes = (kind ~= "wild" and pending.wild) and pending.wild.countSpeciesTypes or nil,
    } },
  }

  local ruleset = pending.ruleset or {}
  local sim, why = Turn.create({
    id = battleId,
    mode = mode,
    -- A Gold wild fight's was drawn ahead of its item roll (above).
    seed = seed or self:_seed(),
    chart = ruleset.chart,
    specialTypes = ruleset.specialTypes,
    -- The chart's axis by name (MediatedBattle.snapshotRuleset), which the
    -- referee names a move's type through: Gold's badge type boost and
    -- side-effect type checks (BattleSim2 `_typeIdOf`), Red's POISON immunity
    -- and FIRE thaw (BattleSim `typeIndexOf`).
    typeIds = ruleset.typeIds,
    metronomePool = ruleset.metronomePool,
    -- Red's TypeEffects order (MediatedBattle.snapshotRuleset's `chartOrder`):
    -- AdjustDamageForMoveType walks the rows in table order and leaves the
    -- LAST one's multiplier for the effectiveness line and "doesn't affect" /
    -- "missed" (BattleSim Turn `_typeRows`).  Handed over raw like the rest,
    -- so the Gen 1 gate a hub's Wire.battleRuleset applies is this line's;
    -- Gold's walk keeps the product and reads none.
    chartOrder = (generation == 1) and ruleset.chartOrder or nil,
    -- Gold's wTimeOfDay, which MORNING SUN / SYNTHESIS / MOONLIGHT compare
    -- (MediatedBattle.timeOfDay2, stamped on the ruleset as a hub reads it);
    -- the screen's upload is handed over raw here, so the generation gate a
    -- hub's Wire.battleRuleset applies is this line's.  Red has no clock, and
    -- Gen 3 builds its fight in `_begin3` (no wTimeOfDay in a GBA battle).
    timeOfDay = (generation == 2) and ruleset.timeOfDay or nil,
    -- Gold's wBattleType (contract K21), off the same upload: what a hub
    -- hands the referee's `opts.battleType` from the ruleset.
    battleType = (generation == 2) and ruleset.battleType or nil,
    -- Zero, which the referee reads as "no deadline at all". A solo fight has
    -- nobody to keep waiting and the vanilla battle menu waits forever.
    choiceTimeout = Config.SOLO_CHOICE_TIMEOUT,
    -- Neither of these can fire here -- nothing disconnects and nothing
    -- contains a throw mid-resolve -- but the resolve ceiling is the referee's
    -- own guard against a turn that opened and cannot close, and a solo fight
    -- that wedged forever would be worse than one that ends in a draw.
    reconnectGrace = Config.BATTLE_RECONNECT_GRACE,
    resolveTimeout = Config.BATTLE_RESOLVE_TIMEOUT,
    now = 0,
    sides = sides,
  })
  if not sim then
    undoRoll()
    self:warn("nosim", "the mod's battle system could not assemble this "
      .. "fight (%s), so it is fought the ordinary way; report this with the "
      .. "battle you were in", tostring(why))
    return false
  end

  -- The opponent's mind, where it is not the referee's.  On Red and Gold the
  -- referee runs the cart's own computer for side b -- the move, the item,
  -- the switch and the send-out, off the class data above (contract K16) --
  -- so SoloBrain builds nothing for a wild monster, a Gold trainer or a Red
  -- trainer with no registered `brain`, and `Turn:autoPick` answers every
  -- turn and every forced send-out (M:_answerFoe).  The one brain built here
  -- is a mod's own: a Red trainer whose record or class carries a `brain`
  -- function, whose move is filed.  A nil brain is the ordinary answer, not a
  -- failure, and is not logged as one -- see SoloBrain's header.
  local brain
  if kind == "trainer" then
    brain = SoloBrain.new({ game = game, engine = state })
  end

  self.fight, self.sim, self.brain = fight, sim, brain
  self.engine, self.game, self.kind = state, game, kind
  self.generation = generation
  self.wildMon = wildMon
  self.mapId = mapId
  self.settled, self.reason = false, nil
  self.refuseRun, self.failedRun, self.fledLine = nil, nil, nil
  self.runAttempts, self.faults = 0, 0
  self.clock, self.seq = 0, 0
  self.warned = nil
  self.save = game.save
  self.levels = self:_levelSnapshot(game)

  -- The theme the engine's own battle was already playing, kept.
  --
  -- `MediatedBattle:musicKind` answers "wild" for a wild fight and "link" for
  -- everything else, which is right for every fight it was written for and
  -- wrong for this one: a gym leader would be fought under the link cue, over
  -- the top of the gym theme the buried battle started a frame ago. The engine
  -- worked the answer out in its own `enter` (`BattleState.musicKind`, which is
  -- where trainer / gym / final are told apart) and it is sitting on the state
  -- underneath us, so it is copied rather than re-derived. Seeding the cache is
  -- the whole of it -- the screen reads it once for the theme and once for the
  -- victory jingle, and both go through here.
  --
  -- Gen 2 is unaffected either way: its song is chosen from the mode and the
  -- trainer class, and `kind` is not consulted.
  if type(state.musicKind) == "string" and state.musicKind ~= "" then
    fight.cachedMusicKind = state.musicKind
  end

  -- Set before the push, not after: pushing emits `screen.pushed` again, on
  -- this very screen, straight back into the listener that called us. It
  -- declines on kind alone -- a battle screen of ours is neither `wild` nor
  -- `trainer` -- but a live fight in the slot is the answer that does not
  -- depend on that staying true.
  if self.ui and type(self.ui.pushState) == "function" then
    self.ui:pushState(game, fight)
  end

  -- The field is up. `onReady` is the referee's own announcement in the
  -- online path and it is what moves the screen out of `setup` and prints the
  -- opening line, so it is stated here in the same shape the hub broadcasts.
  fight:onReady({
    battle = battleId,
    mode = mode,
    sides = { a = { PLAYER_SEAT }, b = { FOE_SEAT } },
  })

  -- One pump immediately, so the opening send-outs are on screen in the frame
  -- the fight started rather than the one after it.
  self:_pump()
  return true
end

-- The wire, as a table.
--
-- Four message types reach it and only one of them is answered. The choice is
-- handed to the referee and **nothing is drained here**: `sendChoice` sets the
-- screen's own phase *after* this returns, so draining inside it would let the
-- events of the turn it just closed set `pendingTurn` and `mustReplace` on a
-- screen that is about to overwrite both. One frame of latency is invisible; a
-- menu that opens and is immediately closed is not.
function M:_transport(pending)
  local solo = self
  return {
    isReady = function() return true end,
    send = function(transport, msgType, payload)
      if msgType == Wire.BATTLE_RULESET then
        pending.ruleset = payload
      elseif msgType == Wire.BATTLE_PARTY then
        -- Side b is the NPC claim (wild encounter or trainer + kit); side nil
        -- is the player's own party, which is what side a is built from.
        if payload and payload.side == "b" then
          pending.wild = payload
        else
          pending.party = payload
        end
      elseif msgType == Wire.BATTLE_CHOICE then
        -- `false` is a real referee refusal (already answered, a switch
        -- that names nobody). The screen keeps the menu open then.
        -- Parked RUN is handled, not refused -- `_choose` returns true
        -- so `sendChoice` still closes the menu for the pump.
        transport.refusal = nil
        solo.kindRefused3 = nil
        local taken = solo:_choose(payload) and true or false
        -- A Gen 3 screen keeps the refused menu up with the line the cart
        -- prints for that refusal -- the lone double's per seat (CoopBattle
        -- `refuseOwn`), the single screen's where pret prints it
        -- (MediatedBattle `sendChoice`) -- worded here, beside the referee
        -- that knows why (M.refusalText3).  A choice the fight's kind turned
        -- down itself is the kind's to word (its parked line), never this;
        -- Red and Gold read no refusal line.
        if not taken and solo.gen3 and (solo.gen3.double or not solo.kindRefused3) then
          local ok, line = pcall(solo._refusal3, solo, payload)
          transport.refusal = ok and line or nil
        end
        return taken
      elseif msgType == Wire.BATTLE_MOVESET then
        -- A move learned mid-fight (the screen's LearnMove exchange) or a
        -- level-up (contract K9) is the hub's to apply on the online path;
        -- here it is ours, or the monster would go on fighting with the move
        -- it just forgot and the stats it walked in with.
        if solo.generation == 3 then return solo:_applyMoveset3(payload) end
        return solo:_applyMoveset12(payload)
      end
      -- Everything else -- a session leave on the way out, a reconnect nudge
      -- from a transport that never dropped -- is about a hub this fight does
      -- not have, and is dropped rather than answered.
    end,
  }
end

-- ------------------------------------------------------------------
-- the player's turn
-- ------------------------------------------------------------------

-- **RUN is decided here, in both of the ways it can go, on the solo path.**
--
-- The referee now gates `_resolveRuns` the way Teleport is gated: wild /
-- coop_wild flee, 1v1 / coop_pvp concede, coop_npc refuses without finishing
-- so a hub-refereed gym cannot be forfeited by a filed `run`. What it still
-- does not do is Gen 1's wild escape roll, or return to the menu without
-- spending the turn -- a trainer `run` that reaches the sim emits the refusal
-- and the rest of the turn still happens. Solo intercepts both halves here
-- so vanilla holds: trainer RUN does not spend the turn, wild RUN is a roll.
-- The referee never learns that RUN was pressed, which is the whole point of
-- this boundary.
--
-- ------- a trainer's RUN
--
-- Forwarded to the sim, a trainer RUN now refuses without finishing -- but
-- it still spends the turn (the foe attacks). Vanilla refuses and does *not*
-- spend the turn (`BattleState:tryRun`'s trainer arm returns before the roll).
--
-- The refusal *line* is the screen's own -- `MediatedBattle:updateCommand`
-- prints it and does not file the choice -- so all this owes, if a `run`
-- still arrives (a call site that skipped the menu), is the `turn` that
-- reopens the window without spending it. A second copy of the sentence fed
-- from here is what the player used to read twice, in two consecutive boxes.
-- Leave the line to the screen.
--
-- ------- a wild RUN
--
-- Vanilla rolls for it (`BattleState:runRoll`, and Gold's
-- `Battle:runRollVanilla`), and a referee that always lets you go is not a
-- kindness -- it is a silent difficulty change to ordinary single-player play,
-- where every wild encounter becomes one free press of B. So the roll happens
-- here, against the referee's own current effective speeds, and only an escape
-- that actually succeeded is forwarded. A failed one prints "Can't escape!"
-- and **spends the turn**, which is the half that is easy to leave out and the
-- half the enemy's free attack lives in.
--
-- ------- **parked for the pump rather than acted on from here**
--
-- Which is the same rule the rest of this seam runs on and the one place it is
-- easy to get wrong: `MediatedBattle:sendChoice` sets `phase`, `pendingTurn`
-- and `answeredTurn` *after* the transport call returns, so a `turn` fed from
-- inside it is overwritten one line later and the menu never comes back.
-- Measured, not guessed -- it was the first way this was written. The failed
-- escape rides the same parking space for the same reason, plus one of its
-- own: the events its spent turn produces must land *after* "Can't escape!",
-- and from in here they would land in the middle of the screen's own bookkeeping.
function M:_choose(payload)
  local sim = self.sim
  if not (sim and type(payload) == "table") then return false end
  -- Gen 3: which of our seats this is for (a lone double has two; see
  -- M:_seat3).  A choice naming neither is refused, and the menu stays open.
  local seat = PLAYER_SEAT
  if self.generation == 3 then
    seat = self:_seat3(payload)
    if not seat then return false end
    -- The fight's kind reads every choice first (contract C2 `choose`): a
    -- Safari throw, a facility's forfeit, a RUN the kind refuses in its own
    -- words.  Handled there, nothing below runs.
    local okK, handled, taken = self:_hook3(self.gen3, "choose", payload, seat)
    if okK and handled == true then
      self.kindRefused3 = not taken or nil
      return taken and true or false
    end
  end
  if payload.action == "run" then
    if self.kind == "trainer" then
      self.refuseRun = true
      return true
    end
    -- Gen 3's referee owns the whole of a wild RUN (pret TryRunFromBattle:
    -- the Smoke Ball, Run Away, the speed odds with the attempt bonus, a
    -- failed attempt spending the turn), so it is simply filed.  What it
    -- refuses at the door is a trapped runner -- Mean Look, a bind, Ingrain,
    -- Shadow Tag / Arena Trap / Magnet Pull -- and the cart answers that with
    -- a line and the menu back, the turn unspent, so that is parked for the
    -- pump like the trainer refusal above.
    if self.generation == 3 then
      if self:_submit3(payload, seat) then return true end
      self.cantEscape = self:_cantEscapeText3(seat)
      return true
    end
    -- Gold's SMOKE BALL: an escape with no roll and no attempt counted, its
    -- line parked for the pump like the others here (see M:_smokeBall).
    local fled = self.generation == 2 and self:_smokeBall() or nil
    if fled then
      local taken = sim:submitChoice(PLAYER_SEAT, payload) and true or false
      if taken then self.fledLine = fled end
      return taken
    end
    if not self:_escapes() then
      self.failedRun = true
      return true
    end
  end
  if self.generation == 3 then return self:_submit3(payload, seat) end
  return sim:submitChoice(PLAYER_SEAT, payload) and true or false
end

-- The player's choice into the Gen 3 referee, for `seat` (PLAYER_SEAT, or a
-- lone double's second seat).  The last answer of a turn
-- resolves that turn inside `submitChoice`, so a resolution that throws would
-- throw out through the screen's own menu code; it is contained here instead.
-- A choice that was taken before the throw (the referee is left `resolving`)
-- answers true -- the menu closes, and M:_pump hands the fight back once it
-- sees the referee is not coming out of it; one refused before it answers
-- false, and the menu stays open.
--
-- The double screen's `seat` rides along into `submitChoice` untouched: the
-- referee builds the filed choice from the fields it knows (Turn.lua
-- `_normaliseChoice`) and reads nothing else, so there is nothing to strip.
function M:_submit3(payload, seat)
  local sim = self.sim
  local ok, filed = pcall(sim.submitChoice, sim, seat or PLAYER_SEAT, payload)
  if ok then return filed and true or false end
  self:warn("choose3", "the mod's battle referee failed on this turn (%s); the fight is "
    .. "handed back to the ordinary battle system; report it with the move or item "
    .. "you chose", tostring(filed))
  return sim.phase == "resolving"
end

-- The escape roll, in each generation's own arithmetic, out of 256.
--
-- Gen 1 (`engine/battle/core.asm` TryRunningFromBattle, ported at
-- `src/battle/BattleState.lua:runRollVanilla`): faster than the foe is a
-- guaranteed getaway; otherwise `b = floor(enemySpeed / 4) % 256`, a zero `b`
-- is a guaranteed getaway too (the cartridge's divide-by-zero overflow), and
-- the odds are `floor(playerSpeed * 32 / b) + 30 * (attempts - 1)` against one
-- random byte, escaping on `roll <= odds` -- the original's `jr nc` keeps the
-- equal case.
--
-- Gen 2 (`src/battle/gen2/Battle.lua:runRollVanilla`) is close but not the
-- same, and guessing would have been wrong twice: the divisor is clamped to 1
-- rather than allowed to overflow, the attempt bonus is `30 * attempts` rather
-- than `30 * (attempts - 1)` -- so Gold's *first* try already carries it -- and
-- the comparison is strict, `roll < odds`.
--
-- Returned as a number rather than a boolean so the two comparisons stay next
-- to the two formulas that need them.
local function escapeOdds(generation, pSpd, eSpd, attempts)
  if pSpd >= eSpd then return 256 end
  if generation == 2 then
    return floor(pSpd * 32 / max(1, floor(eSpd / 4))) + 30 * attempts
  end
  local b = floor(eSpd / 4) % 256
  if b == 0 then return 256 end
  return floor(pSpd * 32 / b) + 30 * (attempts - 1)
end

-- Did this attempt get away?
--
-- The speeds are the *referee's*, taken through its own `_speedOf`, which is
-- the one place badge boosts, stat stages and paralysis are all folded in
-- together -- and the same three things vanilla's `wBattleMonSpeed` carries
-- into `TryRunningFromBattle`. Re-deriving them here from the sheets would be a
-- second speed formula to keep in step with the one the fight is actually
-- being fought under.
--
-- The roll comes off the referee's own RNG, so a solo fight remains exactly
-- reproducible from its seed -- an escape is part of the battle, not something
-- happening beside it.
--
-- A fight this cannot price -- no active monster on one side, a referee with no
-- speed to report -- lets the player go. Failing open is the honest default
-- here: the alternative is a wild encounter nobody can leave, which is the one
-- state a wild encounter must never be in.
function M:_escapes()
  local sim = self.sim
  local player = sim and sim.byId and sim.byId[PLAYER_SEAT]
  local foe = sim and sim.byId and sim.byId[FOE_SEAT]
  local mine, theirs = activeOf(player), activeOf(foe)
  if not (mine and theirs) then return true end

  -- Counted before the roll and never rolled back, which is vanilla's order
  -- too: a refused attempt still raises the odds of the next one.
  self.runAttempts = (self.runAttempts or 0) + 1

  local okMine, pSpd = pcall(sim._speedOf, sim, player, mine)
  local okTheirs, eSpd = pcall(sim._speedOf, sim, foe, theirs)
  pSpd, eSpd = tonumber(okMine and pSpd), tonumber(okTheirs and eSpd)
  if not (pSpd and eSpd) then
    self:warn("runspeed", "the escape odds for this battle could not be "
      .. "worked out, so you got away; report this with the POKéMON you were "
      .. "running from")
    return true
  end

  local odds = escapeOdds(self.generation, floor(pSpd), floor(eSpd),
                          self.runAttempts)
  if odds >= 256 then return true end

  local rng = sim.rng
  local okRoll, roll = pcall(function() return rng:byte() end)
  if not (okRoll and tonumber(roll)) then return true end
  if self.generation == 2 then return roll < odds end
  return roll <= odds
end

-- Gold's SMOKE BALL, before any of the above.
--
-- pokecrystal engine/battle/core.asm TryToRunAwayFromBattle: once the battle
-- type, the trainer and the trap checks are through (SUBSTATUS_CANT_RUN, and
-- wPlayerWrapCount -- a monster held by a binding move cannot use it either),
-- the player's battle monster's item is asked its held effect, and HELD_ESCAPE
-- prints BattleText_UserFledUsingAStringBuffer1 and jumps straight to
-- `.can_escape` -- ahead of wNumFleeAttempts and the speed roll, so it neither
-- counts an attempt nor draws a byte.  The fight then ends as any escape
-- does (the referee's `run`, the screen's ending for it).
--
-- The item is the one the monster holds *now*: the screen's sheet for it, which
-- `MediatedBattle:applyHeld2` keeps on every `held` event (a THIEF that took it
-- took the escape with it), else the referee's own copy of the monster; its
-- held effect is read from this client's item data (K2's `heldFields2`), the
-- way the cart asks GetItemHeldEffect.  Answers the line to print, the item's
-- name filled in, or nil when the run is the ordinary roll.
M.HELD_ESCAPE2 = "HELD_ESCAPE"
function M:_smokeBall()
  local sim, fight = self.sim, self.fight
  local player = sim and sim.byId and sim.byId[PLAYER_SEAT]
  local mine = activeOf(player)
  if not mine then return nil end
  if type(mine.trapped) == "table" and (tonumber(mine.trapped.turns) or 0) > 0 then
    return nil
  end
  local sheet
  local slot = tonumber(mine.slot)
  for _, s in ipairs((fight and fight.mine) or {}) do
    if type(s) == "table" and slot and tonumber(s.slot) == slot then sheet = s; break end
  end
  local item
  if sheet then item = sheet.heldItem else item = mine.heldItem end
  if type(item) ~= "string" or item == "" then return nil end
  local fields = MediatedBattle.heldFields2(self.game, item)
  if not (fields and fields.holdEffect == M.HELD_ESCAPE2) then return nil end
  local name = (sheet and sheet.species) or mine.species or "POKéMON"
  return ("%s\nfled using a\n%s!"):format(tostring(name), fields.itemName or item)
end

-- The turn a failed escape costs, spent without the referee being asked for a
-- move the player did not make.
--
-- `submitChoice` cannot express this. Its `ACTIONS` set is fight / item /
-- switch / run / cancel, and there is deliberately no "do nothing" on the wire
-- -- an online client that could file one could stall a turn for everybody
-- else. The referee has the concept, though, and uses it constantly:
-- `_fillForcedChoices` writes `{ action = "skip" }` straight onto a seat that
-- must recharge, is trapped, or is storing energy. A failed escape is exactly
-- that shape -- the seat is spending its turn on nothing -- so it is written
-- the same way.
--
-- Writing `fighter.choice` from outside is otherwise this file's one banned
-- move (see M:_answerFoe on why a brain's answer must go through
-- `submitChoice`), and the reason it is safe here is that the ban is about
-- *index vocabulary*: `submitChoice` normalises zero-based moves and party
-- positions, `fighter.choice` holds them already converted, and a choice that
-- carries no index at all cannot be caught between the two.
--
-- `forcedPending` is then the referee's own way of saying "every living seat is
-- answered, close this turn on the next tick" -- set by `_openTurn` when a
-- whole turn came out forced. Setting it here rather than reaching for the
-- private `_maybeResolve` means the turn closes inside `tick`, on the pump's
-- own next line, through the referee's own path. Without it the fight would
-- wedge: the opponent has usually answered several frames ago, so nothing else
-- in the frame would be left to notice that the turn is complete.
function M:_spendTurn()
  local sim = self.sim
  local player = sim and sim.byId and sim.byId[PLAYER_SEAT]
  if not (player and sim.phase == "choice") then return false end
  if player.choice ~= nil then return false end
  player.choice = { action = "skip" }
  sim.forcedPending = true
  return true
end

-- ------------------------------------------------------------------
-- the pump
-- ------------------------------------------------------------------

-- Called once a frame from src/Client.lua, whether or not a fight is running:
-- the blackout warp waits for the world to come back and has to be pumped
-- across the frames it waits for, and that outlives the fight that caused it.
function M:update(dt, game) -- luacheck: ignore game
  Coop.pumpBlackout(self, dt)
  if not self.sim then return false end
  self.clock = self.clock + (tonumber(dt) or 0)
  return self:_pump()
end

-- One frame of refereeing.
--
-- The order is the whole of it. The opponent answers first, because its answer
-- can be the one that closes the turn; the buffer is drained; the clock is
-- advanced, because `tick` is the *only* thing that walks a forced chain -- a
-- recharge, a thrash, a trap -- one step at a time, and a fight where every
-- living seat is forced closes no turn without it; and the buffer is drained
-- again, because that tick will have produced more. A pump that drained only
-- after the choice-driven path would stall the first time nobody had a choice
-- to make.
--
-- ------- and a referee that throws is contained, but only for so long
--
-- A throw out of `tick`, `drainEvents`, or the opponent's picker is caught
-- rather than allowed to reach src/Client.lua's pcall, because one bad frame
-- should not take a whole battle down. What that used to hide is the failure
-- that is not a bad frame: a deterministic throw repeats every frame forever.
-- The turn never resolves, `outcome()` stays nil, `SOLO_CHOICE_TIMEOUT` is
-- zero so no deadline arrives -- and in a trainer fight RUN is refused, so
-- the player is left standing in front of a battle screen with no way out of
-- it at all, reading a warning that asks them to "finish or leave this battle"
-- and cannot do either.
--
-- So the frames are counted. `Config.SOLO_FAULT_LIMIT` in a row and the fight
-- is handed back: `M:reset` takes our screen off and leaves the engine's own
-- battle -- which has been sitting underneath the whole time -- on top, to be
-- fought the ordinary way. The counter is per *frame*, not per call, and it
-- resets on any frame that completes cleanly, so an isolated bad event never
-- accumulates toward it.
function M:_pump()
  local sim, fight = self.sim, self.fight
  if not (sim and fight) then return false end

  -- A RUN a skipped-menu call site filed last frame, answered now that the
  -- screen has finished writing over its own choice state. See M:_choose.
  -- Honest trainer menus no longer send, so this is the backstop.
  --
  -- **The `turn` and nothing else.** The refusal line is the screen's own --
  -- `MediatedBattle:updateCommand` prints "No! There's no\nrunning from a\n
  -- trainer battle!" -- so a copy fed from here is the same sentence in a
  -- second box. All this owes is the window: vanilla returns straight to the
  -- menu (`afterQueue = "menu"`) and does not spend the turn, so the seat
  -- still owes the referee an answer and the next choice resolves normally.
  if self.refuseRun then
    self.refuseRun = nil
    self:_feed({ t = "turn", amount = sim.turn })
  end

  -- A wild RUN the escape roll turned down, answered in the same place and for
  -- the same reason. Line first, then the turn is spent on nothing, so the
  -- enemy's free attack lands behind "Can't escape!" rather than in front of it.
  if self.failedRun then
    self.failedRun = nil
    self:_feed({ t = "msg", text = "Can't escape!" })
    self:_spendTurn()
  end

  -- Gold's SMOKE BALL line (M:_smokeBall), ahead of the escape the referee
  -- already has filed -- the cart prints it before the escape's own ending.
  if self.fledLine then
    local text = self.fledLine
    self.fledLine = nil
    self:_feed({ t = "msg", text = text })
  end

  -- A Gen 3 trapped RUN: the line, then the window back, nothing spent.
  if self.cantEscape then
    local text = self.cantEscape
    self.cantEscape = nil
    self:_feed({ t = "msg", text = text })
    self:_feed({ t = "turn", amount = sim.turn })
  end

  local faults = 0
  local okFoe, foeErr = pcall(self._answerFoe, self)
  if not okFoe then
    faults = faults + 1
    self:warn("foe", "the opponent in this battle could not pick a move (%s); "
      .. "it is given a few more frames and then this fight is handed back to "
      .. "the ordinary battle system; report it with the trainer you were fighting",
      tostring(foeErr))
  end
  faults = faults + self:_drain()

  local ok, err = pcall(sim.tick, sim, floor(self.clock))
  if not ok then
    faults = faults + 1
    self:warn("tick", "the mod's battle referee stopped answering (%s); it is "
      .. "given a few more frames and then this fight is handed back to the "
      .. "ordinary battle system; report it with the fight you were in",
      tostring(err))
  end
  faults = faults + self:_drain()

  -- Gen 3: a turn that threw half way through resolving.  BattleSim3 resolves
  -- a turn in one synchronous call, so a referee still `resolving` once the
  -- frame is done is one whose resolution raised -- inside a submitted choice
  -- as often as inside `tick` -- and nothing above counted it: every later
  -- frame is clean, the referee waits out its resolve deadline and calls the
  -- fight a draw (a replacement that threw sets no deadline and never ends at
  -- all).  Counted here instead, so it is handed back like any other fight
  -- the referee cannot keep going, rather than scored.
  if self.generation == 3 and sim.phase == "resolving" and not sim.result then
    faults = faults + 1
    self:warn("stall3", "the mod's battle referee stopped part way through a turn; "
      .. "this fight is handed back to the ordinary battle system; report it with "
      .. "the move or item that was being used")
  end

  if faults > 0 then
    self.faults = (self.faults or 0) + 1
    if self.faults >= (tonumber(Config.SOLO_FAULT_LIMIT) or 3) then
      -- Said unconditionally rather than through M:warn, because this is the
      -- one line in the sequence that names something the player can act on
      -- and it must not be swallowed as a repeat of the warnings above it.
      mod.log:error("the mod's battle system could not keep this fight going, "
        .. "so the ordinary battle has been put back on screen -- fight it as "
        .. "usual; turn SOLO BATTLES off in the mod manager if it happens again")
      self:reset()
      return false
    end
  else
    self.faults = 0
  end

  -- Gen 3's lone double: one of our seats the referee is still waiting on
  -- while the screen has stopped asking about it (M:_backstop3).
  if self.generation == 3 and self.gen3 and self.gen3.double then self:_backstop3() end

  local outcome = sim:outcome()
  if outcome and not self.settled then self:_settle(outcome) end
  return true
end

-- Everything the referee has produced since the last look, in order.
--
-- Answers how many faults it hit -- 0 or 1 -- so M:_pump can count a frame
-- rather than a call. A drain that throws used to fail completely silently,
-- which made a fight that stalled here unattributable: the events simply
-- stopped arriving and nothing anywhere said why.
function M:_drain()
  local sim, fight = self.sim, self.fight
  if not (sim and fight) then return 0 end
  local ok, events = pcall(sim.drainEvents, sim)
  if not ok then
    self:warn("drain", "this battle's events could not be read from the mod's "
      .. "referee (%s); if the fight stops moving it will be handed back to "
      .. "the ordinary battle system", tostring(events))
    return 1
  end
  if type(events) ~= "table" then return 0 end
  for _, event in ipairs(events) do self:_feed(event) end
  return 0
end

-- One event, renumbered, onto the screen.
--
-- The screen reads `seq` as a stream position: an event at or below the last
-- one it applied is a duplicate and is dropped, and a jump forward is counted
-- as a gap. The referee owns its own numbering, and this file needs to be able
-- to slip an event of its own in (see M:_choose) without colliding with it --
-- so every event is stamped with a counter this file owns instead. The
-- referee's tables are ours by then: `drainEvents` hands them over and keeps
-- no reference.
--
-- A throw is contained rather than allowed to take the fight down with it. One
-- unreadable line is a cosmetic loss; a raise out of the pump is a battle that
-- stops answering with the player standing in front of it.
function M:_feed(event)
  local fight = self.fight
  if not (fight and type(event) == "table") then return false end
  self.seq = self.seq + 1
  event.battle = fight.battle
  event.seq = self.seq
  -- Gen 3 has no engine battle underneath to mark the dex as each foe comes
  -- out (pret Cmd_switchinanim's HandleSetPokedexFlag), to note an Amulet
  -- Coin the moment its holder is sent in (HeldItems onSwitchIn), to count
  -- the balls thrown (gBattleResults) or to know who ran -- so the events
  -- that say so are read on the way past.  See M:_note3.
  if self.generation == 3 then self:_note3(event) end
  local ok, err = pcall(fight.onEvent, fight, event)
  if not ok then
    self:warn("event", "part of this battle could not be shown (%s); the "
      .. "fight itself is unaffected -- report this with the move or item "
      .. "that was being used", tostring(err))
    return false
  end
  return true
end

-- ------------------------------------------------------------------
-- the opponent
-- ------------------------------------------------------------------

-- The opponent's answer for this turn, if it owes one.
--
-- On Red and Gold that is `Turn:autoPick`, every turn and every forced
-- send-out, wild and trainer alike: the referee runs the carts' own computer
-- for a seat nobody filed for -- pokered TrainerAI, AIEnemyTrainerChooseMoves
-- and EnemySendOut; pokecrystal AIChooseMove, AI_SwitchOrTryItem and
-- FindMonInOTPartyToSwitchIntoBattle -- at the cart's own points (contract
-- K16), the path a hub's NPC seat takes, so SoloBrain builds no brain there.
-- A brain, where there is one -- Gen 3's, which answers the whole turn, or a
-- mod's registered `brain` on a Red trainer, which answers the move -- is
-- asked first, and `autoPick` takes whatever it declines.
--
-- The two speak different index vocabularies and that is the sharpest edge in
-- this file. `autoPick` writes `fighter.choice` directly, so its `move` is
-- one-based and its `slot` is a party index. `submitChoice` normalises from the
-- wire's vocabulary: zero-based `move`, and `slot` is the monster's own party
-- position rather than a count off the array. `SoloBrain` answers in
-- `submitChoice`'s, which is why its result goes through `submitChoice` and
-- must never be assigned to `fighter.choice`.
--
-- Looped the way `Hub:fillNpcChoices` is: filing the last outstanding choice
-- can resolve the turn and open the next one, where a forced skip on the
-- player leaves the NPC owing again. One pick per frame used to paint
-- "Waiting for X..." for a frame of that chain; a pick that filed nothing
-- (empty moves, no target) used to paint it forever, because
-- `SOLO_CHOICE_TIMEOUT` is 0. `Turn:autoPick` now files Struggle (empty sheet)
-- or skip (no target) rather than declining, and the loop is what carries a
-- trap/recharge chain without a wait line.
function M:_answerFoe()
  -- Gen 3 answers every computer seat on either side -- a trainer's, a
  -- second trainer's, Steven's, a wild one -- in its own loop (contract C4).
  if self.generation == 3 and self.gen3 then return self:_answerNpcs3() end
  local sim = self.sim
  local foe = sim and sim.byId and sim.byId[FOE_SEAT]
  if not (sim and foe) then return false end

  local bound = (tonumber(Config.BATTLE_MON_MAX) or 6)
    * math.max(1, tonumber(Config.COOP_FIGHTERS) or 1)
  local filed = false
  for _ = 1, bound do
    if not owes(sim, foe) then break end

    local got = false
    local brain = self.brain
    if brain then
      local player = sim.byId[PLAYER_SEAT]
      local view = {
        mon = foe.mons[foe.active],
        foe = player and player.mons and player.mons[player.active] or nil,
        party = foe.mons,
        active = foe.active,
        bag = foe.bag,
        mustReplace = foe.mustReplace and true or false,
      }
      -- (Gen 3's brain, which reads the referee itself, is asked through
      -- M:_answerNpcs3 / M:_npcView3.)
      local ok, choice = pcall(brain.choose, brain, view)
      if not ok then
        self:warn("brain", "the trainer's own AI could not be asked for a move "
          .. "(%s), so the referee's own trainer AI answers for it instead; "
          .. "report this with the trainer you were fighting", tostring(choice))
      elseif type(choice) == "table" and sim:submitChoice(FOE_SEAT, choice) then
        got = true
      end
    end
    if not got then
      got = sim:autoPick(FOE_SEAT) and true or false
    end
    if not got then break end
    filed = true
  end
  return filed
end

-- ------------------------------------------------------------------
-- the ending, in two halves
-- ------------------------------------------------------------------

-- Half one: the referee has a verdict.
--
-- Handed to the screen, which prints it and then waits for the player to read
-- it. Nothing is written to the save here except the wild monster's own
-- condition, and that has to happen *before* the outcome goes across: a catch
-- is granted inside `MediatedBattle:finish`, from the engine monster this file
-- handed it, and a monster caught at four HP with a burn on it should arrive in
-- the party at four HP with a burn on it. The referee has been fighting a copy;
-- this is where the copy is written back onto the original.
function M:_settle(outcome)
  self.settled = true
  self.reason = outcome.reason

  if self.generation == 3 then return self:_settle3(outcome) end

  if self.kind == "wild" and self.wildMon then
    local foe = self.sim.byId[FOE_SEAT]
    local mon = foe and foe.mons and foe.mons[1]
    if mon then self:_applyMon(self.wildMon, mon) end
  end

  local ok, err = pcall(self.fight.onOutcome, self.fight, outcome)
  if not ok then
    self:warn("outcome", "the end of this battle could not be shown (%s); "
      .. "leave the battle screen and the result still counts", tostring(err))
  end
end

-- Half two: the player has read it and the screen has come off the stack.
--
-- Reached through the screen's own `onDone`, which fires from its `exit` --
-- so by the time this runs the mod's battle is already gone and the frozen
-- engine battle is what is left underneath. This is exactly the position
-- `Coop:onBattleOver` is in, which is why the ritual below is a call into the
-- statics that were lifted out of it rather than a second copy of them.
--
-- The order is the order co-op earned, one bug at a time, and none of it is
-- interchangeable:
--
--   1. **The party comes home first.** Everything below can change the answer
--      to "does this player have anything left standing" -- the ritual heals --
--      and until the fight's damage is on the save monsters the honest answer
--      is not even available.
--   2. **What levelled is stamped on the buried battle**, because the
--      overworld's `afterBattle` offers evolutions to exactly the monsters the
--      battle recorded, and the battle that recorded them is this one.
--   3. **The blackout is decided once, before anything heals.**
--   4. **The buried battle comes off the stack first**, unwound to by identity.
--      By identity, because a text box or a transition can be sitting between
--      the two and a fixed number of pops is a guess. Off, because left there
--      it would resume the moment ours came off and the player would fight the
--      same trainer twice.
--
--      This step used to be number five, *after* the forget prompts, and that
--      inversion was a real bug rather than an untidiness. `Coop.offerForgets`
--      pushes `MoveLearnMenu` synchronously, straight above the buried battle;
--      an unwind that then popped everything above that battle destroyed the
--      menu -- and, for two moves at once, the "..." box carrying the
--      continuation -- in the same frame it was raised. Every solo level-up
--      that taught a fifth move lost it silently. Co-op never had the bug
--      because co-op unwinds at the *start* of its fight (`Coop.lua:2510`) and
--      so has nothing left above the battle by prompt time; solo unwinds at the
--      end, which inverts the pair. Doing it first here reproduces exactly the
--      stack shape co-op prompts over: the world, and nothing above it.
--   5. **The forget prompts go up, over the world**, as they do in co-op: they
--      are the player's own screens and belong over the world, not under a
--      warp -- and `Coop.pumpBlackout` is written to wait for them, since the
--      thing it waits for is the overworld coming back to the top.
--   6. **The ritual runs, and the whiteout is run by whoever the engine did
--      not run it for.** A won trainer battle whose winner's own team was
--      wiped is the case that needs the second half: the engine marks the
--      trainer beaten and deliberately does not black anybody out.
--
-- ------- except that 4 and 5 swap over on Gold, and have to
--
-- `Coop.finishBuriedBattle` calls `onFinish`, and the two generations disagree
-- about who pops the battle around it. Gen 1's `BattleState:finish` pops the
-- state itself and *then* calls `onFinish`, so a caller standing in for it pops
-- first and hands the ritual a state already off the stack -- which is the
-- contract co-op has always run on. Gen 2 has no such split: the pop lives
-- *inside* the closure `World:startBattle` hands to `Gen2BattleState` as
-- `onDone`, which the loader aliases onto `onFinish` (`src/Client.lua:2523`),
-- and it pops the top of the stack unconditionally.
--
-- So on Gold the battle is left where it is and the ritual takes it down, and
-- the prompts go up after -- because anything pushed before it would be exactly
-- what that pop took. The callback is the test rather than the generation
-- number, because "does the ritual pop for itself" is a property of the
-- callback and not of the game.
--
-- ------- and the prediction is checked rather than trusted
--
-- Which is still a guess about somebody else's closure, and it was wrong the
-- first time it met one: a Gold battle that carries an `onDone` which does not
-- pop -- anything that pushed `Gen2BattleState` itself rather than going
-- through `World:startBattle` -- was predicted to take itself down, and nobody
-- did. The buried battle stayed on the stack under a finished fight, with the
-- player standing on a battle that had already been told it was won.
--
-- The fix is not a better guess. Between the ritual and the prompts this
-- function now *looks*: a battle that was handed its result and is still on the
-- stack is taken off, by identity, exactly as the other branch would have taken
-- it off. The prediction chooses the order; the observation decides the
-- outcome. See `settleStack` below for what it is gated on and why.
function M:_ended(result, toLearn)
  if self.generation == 3 then return self:_ended3(result, toLearn) end
  local game, engine, sim = self.game, self.engine, self.sim
  local reason, save, levels = self.reason, self.save, self.levels
  -- Snapshot before the fight is released: a mid-battle movie that already
  -- answered (accept or cancel) must not be re-offered by checkParty, and
  -- `self.fight` is about to be nilled.
  local evoResolved = self.fight and self.fight.evoResolved
  -- ...and whether an AMULET COIN came out on our seat (Gold's wAmuletCoin,
  -- latched by the screen at each send-out -- MediatedBattle:noteAmulet2),
  -- which the prize the ritual pays is doubled by (Coop.payTrainerPrize).
  local amuletCoin = false
  if self.fight and type(self.fight.amuletCoin2) == "function" then
    local okAmulet, coin = pcall(self.fight.amuletCoin2, self.fight)
    amuletCoin = okAmulet and coin == true
  end
  -- Released before any of it runs. Everything below can push a screen, and a
  -- screen that pushes is a `screen.pushed` back into the divert -- which must
  -- find no fight in the slot rather than a half-finished one.
  self.fight, self.sim, self.brain = nil, nil, nil
  self.engine, self.game, self.wildMon = nil, nil, nil
  self.kind, self.reason, self.save, self.levels = nil, nil, nil, nil
  self.settled, self.refuseRun, self.failedRun = false, nil, nil
  self.fledLine = nil
  self.generation, self.runAttempts, self.faults = nil, 0, 0

  if not (game and sim) then return false end

  self:_reconcile(sim, game, save)

  local levelled = M.levelledSince(game, save, levels)
  levelled = EvolveFx.withoutResolved(levelled, evoResolved)
  if engine and levelled then engine.leveledUp = levelled end
  if engine and evoResolved then engine.evoResolved = evoResolved end
  if engine and amuletCoin then engine.amuletCoin = true end

  local outcome = M.engineResult(result, reason)
  local blackout = Coop.blacksOut(outcome, game)

  -- Coop's own, borrowed rather than copied a third time. It reads exactly one
  -- field off the holder it is called on -- `self.ui`, to pace two prompts with
  -- a "..." box -- and this file has one. Sessions states its own twin of this
  -- flow because it cannot reach Coop at all; this file can, and a third copy
  -- of "put the moves a level taught to the player" would be a third thing to
  -- keep in step.
  local function offerForgets()
    local okForgets, whyForgets = pcall(Coop.offerForgets, self, game, toLearn)
    if not okForgets then
      self:warn("forgets", "a move learned in this battle could not be offered "
        .. "(%s); it can still be learned by levelling again",
        tostring(whyForgets))
    end
  end

  -- Whether the ritual takes the battle off the stack for itself. See the
  -- generation note in this function's header.
  --
  -- Asked of the function `Coop.finishBuriedBattle` will actually call --
  -- `Coop.buriedFinisher`, which is that ritual's own selection -- and not of
  -- `engine.onDone` regardless of whether that is the one that runs. The two
  -- are the same function on a Gold battle World:startBattle pushed, because
  -- Client aliases the missing `onFinish` onto `onDone`; they are *not* the
  -- same on a Gold battle pushed by anything else that supplied its own
  -- `onFinish`, and asking the wrong one predicted a pop that no function on
  -- the state was ever going to perform.
  local finisher = Coop.buriedFinisher(engine)
  local ritualPops = finisher ~= nil and engine ~= nil
    and finisher == engine.onDone

  -- Step 4. `mayFinish` is what the unwind's answer is *for*: `unwindStackTo`
  -- gives up after sixteen pops, and a target it never reached is a battle
  -- still buried under a pile. Finishing it anyway would mark the trainer
  -- beaten and pay their prize while leaving them on the stack to be fought
  -- again when the pile clears -- so an unwind that did not arrive declines to
  -- finish, and the engine's own battle is left to run for real. A target that
  -- was already gone from the stack answers false too, and that one is *not* a
  -- reason to decline: there is nothing to unwind and nothing to fight twice.
  local mayFinish = engine ~= nil
  if engine then
    local reachable = Coop.stackHolds(game, engine) ~= false
    local unwound = Coop.unwindStackTo(game, engine, not ritualPops)
    if reachable and not unwound then
      mayFinish = false
      self:warn("unwind", "this battle's rewards could not be handed over "
        .. "because too many screens were open above it, so the ordinary "
        .. "battle is still waiting underneath -- fight it as usual")
    end
  end

  local handled, engineRitual = false, false
  local function finishEngine()
    if not (engine and mayFinish) then return end
    handled, engineRitual = Coop.finishBuriedBattle(engine, game, outcome,
                                                    blackout)
  end

  -- Step 4c -- and whatever was predicted, check.
  --
  -- `ritualPops` is an inference about somebody else's closure, and an
  -- inference is a guess however carefully it is made: it is right about the
  -- two shapes this repo knows (Gen 1's onFinish, which never pops, and the
  -- popping closure `World:startBattle` hands Gold), and it is a guess about
  -- every other way a battle can arrive on the stack. When it guesses high --
  -- "the ritual will pop this" for a callback that does not -- the player is
  -- left standing on a battle that has already been told it was won, which
  -- resumes the moment anything above it clears and cannot be dismissed. That
  -- is the worst ending this feature has, and it is not worth risking on a
  -- prediction when the answer is *observable one line later*.
  --
  -- So the prediction only chooses the order, and this decides the outcome: a
  -- battle that was told how it went and is still on the stack comes off, by
  -- identity, exactly as the non-popping branch would have taken it off.
  --
  -- Gated on `handled`, which is the difference between "nobody popped it" and
  -- "we declined to finish it". A battle the unwind could not reach was never
  -- given its result and is still owed a real fight -- see `mayFinish` above --
  -- so it must be left exactly where it is.
  --
  -- Before the forget prompts, never after: the prompts push MoveLearnMenu
  -- straight above whatever is on top, and an unwind that ran after them is an
  -- unwind that takes them down again.
  local function settleStack()
    if not (engine and handled) then return end
    if Coop.stackHolds(game, engine) ~= true then return end
    if not Coop.unwindStackTo(game, engine, true) then
      self:warn("settle", "this battle is over but its screen could not be "
        .. "closed; if the old battle comes back, walk out of it as usual or "
        .. "reload from your last save")
    end
  end

  -- Steps 5 and 6, in whichever order the buried battle's own pop allows.
  if ritualPops then
    finishEngine()
    settleStack()
    offerForgets()
  else
    offerForgets()
    finishEngine()
    settleStack()
  end

  if blackout and not (handled and engineRitual) then
    -- "battle", not co-op's default "2-on-2": a lone player's four possible
    -- blackout warnings must not describe a feature they were not using.
    Coop.blackout(self, game, "battle")
  end

  -- And nothing else, deliberately: a wild encounter that ended in a catch has
  -- already had the monster added by the screen, and a trainer that was beaten
  -- has already been marked by its own onFinish. There is no third thing owed.
  -- Said out loud so a reader does not go looking for it.
  return true
end

-- The word the engine's `onFinish` is expecting.
--
-- The screen answers "win" / "loss" / "draw", which is the verdict from this
-- player's point of view and is what the prize and the blackout are decided
-- on. Two of the referee's reasons are not verdicts at all and have to be said
-- in the engine's own vocabulary instead:
--
--   * **run.** `BattleState` finishes a flee as "run", and the overworld's
--     `afterBattle` treats anything that is not "lose" as an ordinary end. Left
--     as the screen's "loss" -- which is what fleeing scores as, since the side
--     that ran is recorded as the loser -- running away from a PIDGEY would
--     heal the player's party and take half their money. A wild monster that
--     flees, and a POKE DOLL, land here from the other direction and are the
--     same non-event.
--   * **catch.** "caught" is the engine's word, and the one thing that must not
--     happen is for a catch to be handed on as the "win" it scores as: a win
--     pays a prize, and `Commands.start_battle` reads a win back as the
--     trainer having been beaten.
--
-- Everything else passes through untouched, including a win by a player whose
-- own team was wiped -- see Coop's note on why that stays a win.
function M.engineResult(result, reason)
  if reason == "catch" then return "caught" end
  if reason == "run" then return "run" end
  return result or "draw"
end

-- ------------------------------------------------------------------
-- bringing the party home
-- ------------------------------------------------------------------

-- Level per party monster, keyed by the monster itself.
--
-- By identity rather than by index, because a catch appends to this same party
-- between the two reads and an index would move under a caught monster's
-- neighbours. Keyed weakly for the same reason every cache in this repo is: a
-- fight abandoned by a reload must not hold six monsters alive.
function M:_levelSnapshot(game)
  local party = game and game.save and game.save.party
  if type(party) ~= "table" then return nil end
  local out = setmetatable({}, { __mode = "k" })
  for _, mon in ipairs(party) do
    if type(mon) == "table" then out[mon] = tonumber(mon.level) or 0 end
  end
  return out
end

-- Which of them gained a level, in the shape `Evolution.checkParty` wants: a
-- set keyed by the save-party monster.
--
-- Derived rather than recorded, because the level-ups happened inside the
-- screen and this file may not reach into `MediatedBattle.leveledUp` after
-- `_ended` has released the fight. The difference between the level a
-- monster had when the fight opened and the level it has now is the same fact
-- by a shorter route -- and a monster the snapshot never saw is one that
-- joined the party during the fight, which is a monster that was caught and
-- has therefore not levelled into anything. Subtract `evoResolved` (a movie
-- the player already answered mid-fight) before handing this to
-- `Coop.offerEvolutions`.
function M.levelledSince(game, save, levels)
  local party = game and game.save and game.save.party
  if not (type(levels) == "table" and type(party) == "table") then return nil end
  if save and game.save ~= save then return nil end
  local out, any = {}, false
  for _, mon in ipairs(party) do
    local before = levels[mon]
    if before and (tonumber(mon.level) or 0) > before then
      out[mon] = true
      any = true
    end
  end
  if not any then return nil end
  return out
end

-- The referee's copy of one monster's moves as its party struct holds them:
-- the list a TRANSFORM put aside (`preTransform.moves`, both referees), with
-- every slot a MIMIC wrote given back its own MIMIC (`preMimic`) -- what a
-- switch-out would have reloaded, read without moving the copy.  The PP of
-- such a slot is the carts' difference: Red's party MIMIC paid for every use
-- of the mimicked move (pokered DecrementPP spends the party's PP at the slot,
-- BattleSim Effects.restoreMoves keeps the slot's), Gold's paid for none of
-- them (pokecrystal BattleCommand_DoTurn's CheckMimicUsed skips the party's
-- spend on a MIMIC slot holding another move), so its saved row's own PP is
-- the party's.  Rows are { id, pp }.
local function partyMoves12(mon, generation)
  local list = mon.moves
  local saved = type(mon.preTransform) == "table" and mon.preTransform.moves or nil
  if type(saved) == "table" then list = saved end
  if type(list) ~= "table" then return nil end
  local mimicked = type(mon.preMimic) == "table" and mon.preMimic or nil
  local out = {}
  for i, row in ipairs(list) do
    if type(row) == "table" then
      local own = mimicked and mimicked[i]
      if type(own) == "table" and own.id ~= nil then
        local pp = (generation == 2 and own.pp ~= nil) and own.pp or row.pp
        out[#out + 1] = { id = own.id, pp = pp, ppUps = row.ppUps }
      else
        out[#out + 1] = { id = row.id, pp = row.pp, ppUps = row.ppUps }
      end
    end
  end
  return out
end

-- HP, PP and status, from the referee's copy back onto the player's own party.
--
-- **This is the only thing this file writes to the save**, and the reason it
-- has to is stated in the header: nothing else brings these three home. Exp,
-- levels, learned moves, a caught monster and every bag item are already
-- written by the screen as the fight runs, and writing any of them a second
-- time here would double them.
--
-- Resolved through the party position each sheet stamped rather than through
-- the array index. `snapshotMons` skips a monster it cannot describe, and one
-- skip shifts every index after it -- which would be a fight's damage written
-- onto the wrong POKeMON. It is the same two-step the screen's own
-- `savePartyIndex` takes, for the same reason.
--
-- Refused outright when the save the fight opened against is no longer the one
-- loaded. A player who reloads mid-battle (F2 is a hard load, not a checkpoint)
-- comes back holding a different party, and writing one playthrough's damage
-- onto another's monsters is the one failure here that cannot be walked off.
function M:_reconcile(sim, game, save)
  local party = game and game.save and game.save.party
  if type(party) ~= "table" then return false end
  if save and game.save ~= save then
    self:warn("reload", "the save changed while a battle was running, so that "
      .. "battle's damage was not written to your party; nothing was lost, "
      .. "but check the party you loaded")
    return false
  end
  local player = sim and sim.byId and sim.byId[PLAYER_SEAT]
  if not (player and type(player.mons) == "table") then return false end
  -- Read off the game rather than `self.generation`: `_ended` has already let
  -- the fight go (and the generation with it) by the time this runs.
  local generation = Gen.generation(game)

  local applied = 0
  for _, mon in ipairs(player.mons) do
    local index = (tonumber(mon.slot) or 0) + 1
    local target = party[index]
    if type(target) == "table" then
      -- Gold's SKETCH, should the fight have ended before the screen heard of
      -- it: the referee states a TRANSFORMed user's sketch only when the
      -- Transform is undone (BattleSim2 Turn `_sketch`, `ppTouched`), and a
      -- fight that ends first undoes nothing.  The party's own list is right
      -- here, so the screen's rule (MediatedBattle.sketchHome) runs on it --
      -- a no-op once the screen has written it.  A solo fight is always one
      -- against the computer, the mode the cart writes home in.
      if generation == 2 then
        MediatedBattle.sketchHome(game, Config.SOLO_WILD_MODE, target.moves,
          partyMoves12(mon, generation), target)
      end
      self:_applyMon(target, mon, generation)
      applied = applied + 1
    end
  end
  return applied > 0
end

-- One monster's condition, from a referee's copy onto the real thing.
--
-- **HP is a delta, not a value**, and that is the whole of this function. The
-- save monster may have levelled during the fight, and `Experience.apply` adds
-- the max-HP gain of every level onto its current HP as it goes -- so its
-- `stats.hp` has moved on from the `maxHp` the referee has been fighting
-- against. Writing the referee's number straight across would take those gains
-- back off again, which is a level-up that heals for nothing. Carrying the
-- growth across instead reproduces exactly what a vanilla battle would have
-- left behind: the fight's damage, plus the level's gain.
--
-- A monster the referee has at zero is left at zero whatever it grew, because
-- fainted is not a number.
--
-- **PP is matched by move id, never by slot**, and that is not caution: the
-- sheet skips a move it cannot describe, so the two lists are the same length
-- only by luck. What is matched is the referee's copy *as the party sees it*
-- (`partyMoves12`): a TRANSFORMed monster's own list put aside at the
-- Transform -- both carts' DoTurn / DecrementPP leave the party's PP alone
-- while it is transformed, so those are its numbers -- and each slot a MIMIC
-- wrote back to MIMIC (on Red at the slot's PP, the PP the two shared; on
-- Gold at the PP it had, `partyMoves12`).  A move the copy holds and the
-- party does not (a referee that kept no `preMimic`) finds nothing to write to
-- and is passed over -- before wave 4 it *ended* the walk, so a fight that
-- ended under a MIMIC or a TRANSFORM brought no PP home at all past that
-- slot.
--
-- `generation` (1 or 2) is the game's: a TOXIC comes home as PSN on both
-- (MediatedBattle.partyStatus12).
--
-- Status is the engine's own three-letter token in both places, so it passes
-- through. There is no counter to carry: the engine keeps sleep's on the
-- battler and throws it away with the battle, so a monster that leaves asleep
-- leaves asleep and nothing more.
function M:_applyMon(target, mon, generation)
  if not (type(target) == "table" and type(mon) == "table") then return false end
  generation = generation or self.generation

  local simMax = max(1, tonumber(mon.maxHp) or 1)
  local saveMax = tonumber(target.stats and target.stats.hp) or simMax
  local grown = max(0, saveMax - simMax)
  local hp = max(0, tonumber(mon.hp) or 0)
  if hp <= 0 then
    target.hp = 0
  else
    target.hp = min(saveMax, hp + grown)
  end

  -- nil is healthy and is what the engine stores for it, so the absence is
  -- written as an absence rather than as a token nothing branches on.  A
  -- TOXIC comes home as the PSN the party's status byte holds
  -- (MediatedBattle.partyStatus12: badly poisoned is a battle-only flag on
  -- both carts); this path reconciles Red and Gold only (`_applyMon3` is
  -- Gen 3's).
  target.status = MediatedBattle.partyStatus12(statusToken(mon.status),
    generation)

  local moves = type(target.moves) == "table" and target.moves or nil
  local simMoves = partyMoves12(mon, generation)
  if moves and simMoves then
    local at = 1
    for _, simMove in ipairs(simMoves) do
      local id = simMove.id
      local found = at
      while found <= #moves and moves[found].id ~= id do found = found + 1 end
      if found <= #moves then
        moves[found].pp = max(0, tonumber(simMove.pp) or 0)
        -- Red's PP byte, whole: a slot DecrementPP wrapped holds 63 PP and
        -- one PP Up fewer (pokered decrement_pp.asm; the referee's `stepPp`),
        -- and that is what the party struct keeps -- never the PP clamped to
        -- a maximum.  Written only where it moved, so a slot that never
        -- stated its PP Ups keeps its shape.
        local ups = tonumber(simMove.ppUps)
        if generation == 1 and ups and ups ~= (tonumber(moves[found].ppUps) or 0) then
          moves[found].ppUps = ups
        end
        at = found + 1
      end
    end
  end
  return true
end

-- ------------------------------------------------------------------
-- teardown
-- ------------------------------------------------------------------

-- Everything let go of, with nothing finished off.
--
-- For the paths that are not an ending: a save loaded or created out from under
-- a fight, and a referee that has faulted often enough to be given up on. Those
-- two are the only callers that exist. A mod being disabled does not reach here
-- and does not need to -- the manager's toggle ends in `love.event.quit`, so
-- there is no in-process teardown to run -- and an F5 hot reload cannot reach
-- here at all: `dev/HotReload.lua` drops the outgoing loader wholesale without
-- calling into it, so a fight in flight would strand its screen on the stack.
-- Closing that would need a teardown seam the mod API does not have, which is
-- an upstream change rather than something to fake from this side.
--
-- The buried engine battle is
-- deliberately *not* told anything -- it has not been fought -- and is left on
-- the stack, where it is the battle the player is now looking at. That is the
-- same answer `Coop:release` gives, and it is the honest one: an encounter that
-- was taken over and then dropped still owes the player a battle.
--
-- The pending warp is dropped rather than fired, for Coop's reason: the heal
-- and the money are already written, and a warp left armed across a teardown
-- goes off in whatever the player is doing next.
function M:reset()
  if self.generation == 3 then return self:_reset3() end
  local game, fight, engine = self.game, self.fight, self.engine
  self.fight, self.sim, self.brain = nil, nil, nil
  self.engine, self.game, self.wildMon = nil, nil, nil
  self.kind, self.reason, self.save, self.levels = nil, nil, nil, nil
  self.settled, self.pendingWarp, self.refuseRun = false, nil, nil
  self.failedRun, self.generation, self.fledLine = nil, nil, nil
  self.runAttempts, self.faults = 0, 0
  if game and fight and engine then
    -- Our screen off, the engine's battle back on top, untouched.
    Coop.unwindStackTo(game, engine, false)
  end
  return true
end

-- ==================================================================
-- Gen 3 (FireRed / LeafGreen / Emerald)
-- ==================================================================
--
-- See the Gen 3 note in this file's header for why there is no divert here:
-- the fight is taken before the engine starts one, through the two entries
-- below, and everything the engine's own battle would have paid after it --
-- the prize, Pickup, the whiteout, the evolutions, the script's resume -- is
-- paid by this file, the cart's way, from the engine's own modules.

-- pret HOLD_EFFECT_DOUBLE_PRIZE (the Amulet Coin, include/constants/hold_effects.h).
local HOLD_DOUBLE_PRIZE = 32

local function int3(value, fallback)
  local n = tonumber(value)
  if not n or n ~= n then return fallback end
  return floor(n)
end

local function try3(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, value = pcall(fn, ...)
  if ok then return value end
  return nil
end

local function copyList(list)
  if type(list) ~= "table" then return nil end
  local out = {}
  for i, v in ipairs(list) do out[i] = v end
  return out
end

local STAT_KEYS3 = { "hp", "atk", "def", "spe", "spa", "spd" }

-- ------------------------------------------------------------------
-- which Gen 3 fights are taken
-- ------------------------------------------------------------------

-- "wild" | "trainer" | nil, from the engine's own battle opts and foe: the
-- `wild` flag BattleBridge.start reads, else a trainer id or a party, else a
-- species (an encounter).
function M.gen3Kind(opts, foe)
  opts = type(opts) == "table" and opts or {}
  if opts.wild == true then return "wild" end
  if tonumber(opts.trainerId) then return "trainer" end
  if type(foe) == "table" then
    if tonumber(foe.trainerId) or type(foe.party) == "table" then return "trainer" end
    if foe.species ~= nil or foe.speciesId ~= nil then return "wild" end
  elseif tonumber(foe) then
    return "trainer"
  end
  return nil
end

-- Config.SOLO_REFUSED_GEN3, asked of every place a Gen 3 fight spells itself:
-- the battle opts, the foe / encounter, and a `kinds` table on any of them
-- (the engine battle state's own, should a caller hand one in) -- any number
-- of tables, nil ones skipped.  A name counts when it is set to anything but
-- false -- the trainer op passes `firstBattle = false` for an ordinary
-- trainer, and that must not refuse it.
function M.gen3Refused(...)
  local places = {}
  local function add(t)
    if type(t) == "table" then
      places[#places + 1] = t
      if type(t.kinds) == "table" then places[#places + 1] = t.kinds end
    end
  end
  for i = 1, select("#", ...) do add((select(i, ...))) end
  for _, field in ipairs(Config.SOLO_REFUSED_GEN3 or {}) do
    for _, place in ipairs(places) do
      local v = place[field]
      if v ~= nil and v ~= false then return true end
    end
  end
  return false
end

-- A double battle of any shape: the trainer's own double flag, its row's, or a
-- second trainer.  Not the take-over decision on its own -- M.gen3TakesDouble
-- is -- but the question that sends a fight to it: anything this says yes to
-- is either fought as the cart's double (two monsters a side from one shared
-- team, CoopBattle's solo double screen) or handed back, never fought as a
-- single battle the cart never had.
function M.gen3Double(opts, foe)
  opts = type(opts) == "table" and opts or {}
  if opts.double == true or opts.trainerIdB ~= nil then return true end
  return type(foe) == "table" and foe.doubleBattle == true
end

-- A *lone* double: one trainer -- one party, one AI, one defeat flag -- who
-- sends out two at once (trainerbattle types 4 / 6 / 7 / 8, the row's
-- doubleBattle).  A second trainer (`trainerIdB`, gBattleTypeFlags'
-- TWO_OPPONENTS) is not: that is two parties and two AIs on one side, which
-- the referee does not seat (Config.SOLO_REFUSED_GEN3 refuses
-- `twoOpponents` too).
function M.gen3LoneDouble(opts, foe)
  opts = type(opts) == "table" and opts or {}
  if opts.trainerIdB ~= nil then return false end
  if opts.double == true then return true end
  return type(foe) == "table" and foe.doubleBattle == true
end

-- How many monsters of this party can be sent out: a species, not an egg, HP
-- above zero -- the count the engine's Party.monsStateToDoubles takes (pret
-- GetMonsStateToDoubles, pokefirered/src/pokemon.c), which battle_bridge's
-- start and the trainerbattle opcode both gate a double on.
function M.gen3UsableMons(party)
  local n = 0
  for _, mon in ipairs(type(party) == "table" and party or {}) do
    if type(mon) == "table" then
      local species = int3(mon.species or mon.speciesId, 0)
      if species ~= 0 and species ~= 412 and not mon.isEgg and not mon.egg
          and int3(mon.hp, 0) ~= 0 then
        n = n + 1
      end
    end
  end
  return n
end

-- The take-over decision for a double: a lone one, and a party that can put
-- two monsters on the field (PLAYER_HAS_TWO_USABLE_MONS).  With fewer the
-- fight is handed back and the cart says its own "not enough POKéMON" and
-- halts, exactly as it does with this mod off.
function M.gen3TakesDouble(opts, foe, party)
  return M.gen3LoneDouble(opts, foe) and M.gen3UsableMons(party) >= 2
end

-- ------------------------------------------------------------------
-- the solo kind registry (contract C2 of docs/plans/gen3-solo-remaining-fights.md)
-- ------------------------------------------------------------------
--
-- An ordinary wild encounter and an ordinary trainer are this file's own
-- fight, start to finish.  Every other fight the carts start -- the Safari
-- Zone, a roamer, a scripted or legendary wild, a Pokemon Tower ghost, the
-- facilities, two trainers or Steven beside you, the first battles, the
-- tutorials -- is the same fight with a few rules moved, and each family's
-- rules live in their own module under src/Solo3/, registered here by name:
--
--   SoloBattle.registerKind3(name, kind)
--
-- `name` is the stand's `kind3` (contract C1: "safari" | "roamer" |
-- "legendary" | "scripted" | "ghost" | "facility" | "pair" | "partner" |
-- "firstBattle" | "tutorial"; "wild" / "trainer" are this file's own and
-- need no kind).  A fight whose name no kind claims is handed back to the
-- cart, silently, whatever the refusal list says -- so a family nobody has
-- written yet is the cart's fight, never an ordinary one fought by mistake.
--
-- `kind` is a table of hooks, every one optional.  Each is called as
-- `kind:<hook>(ctx, ...)` inside a pcall; a hook that throws is said once
-- and the fight goes on the way the comment beside it says.  `ctx` is the
-- fight's own state table (the one M:_begin3 keeps as `self.gen3`), so what
-- a hook writes on it the rest of the fight reads.  From the entry: `solo`
-- (this SoloBattle), `game`, `kind` (the entry's own "wild" / "trainer"),
-- `name` = `kind3` (the kind's name), `hooks3` (the kind), `stand` and its
-- `facility3` / `tutorial3` / `firstBattle3` / `ghost3`, `opts` (the
-- engine's battle opts), `foe` (the encounter or the trainer's foe record),
-- `trainerId`, `done` (the caller's continuation -- a kind may wrap it),
-- `session`, `family`, `song`, `parties`.  From seating on: `party`,
-- `wildMon`, `trainer`, `enemySheets`, `pending` (the screen's uploads),
-- `fight`, `create`, `sim`, `npcs`, `double`, `foeSeats`; from the verdict:
-- `outcome`, `verdict`, `whiteout`, `healAfter`, `deferHeal`, `scriptedLoss`.
--
--   takes(ctx) -> ok, why
--       After the common gates (the row, a fight already running, the
--       refusal list, a battle already on screen), before anything is built.
--       False hands the fight back.  May set the foe and the shape:
--       ctx.party (the foe's engine monsters), ctx.wildMon, ctx.trainer,
--       ctx.double (true / false; nil asks the core's lone-double rule),
--       ctx.foeSeats, ctx.parties[ownerId] (another NPC's engine party, for
--       the dex and the TV), ctx.song, and the flags below.  Throws: handed
--       back.
--   screen(ctx, screenOpts) -> extra?
--       The options the screen is about to be built with
--       (MediatedBattle.new's for a single, CoopBattle.newSoloDouble's for a
--       double -- ctx.screen says which); edit them in place, or return a
--       table of keys to set.  Throws: handed back.
--   seat(ctx, create) -> extra?, sides?
--       The referee's Turn.create options, sides included, as the core
--       built them; edit in place, return `extra` (C3 create keys to set:
--       rules, firstBattle, ghost, safari, mode...) and / or `sides`
--       ({ a = { entry... }, b = { entry... } }, appended after the core's
--       own: Steven on a, the second trainer on b).  Throws: handed back.
--   brains(ctx, npcs) -> extra?
--       Who answers each NPC owner's seats (contract C4): `npcs[ownerId]` is
--       a SoloBrain (anything with :choose(view)), a function(view, seat),
--       "referee" (Turn:autoPick, which plays `wildPick` / a side entry's
--       `ai`) or false (nobody: the kind files that seat itself).  The core's
--       default is the trainer's SoloBrain on "solo_foe", or "referee" for a
--       wild; an owner it was not told about is the referee's.  PLAYER_SEAT
--       is the screen's unless named here.  A brain answering `false` is
--       asked again next frame (a scripted turn waiting on its beat); nil or
--       a refused choice falls to the referee.  Throws: handed back.
--   choose(ctx, payload, seat) -> handled, taken
--       Every choice the screen files, before the core reads it (a Safari
--       throw, a forfeit, a refused RUN with the kind's own words).
--       `handled` true: the core does nothing more and answers `taken`.
--       Helpers: ctx.solo:file3(payload, seat), ctx.solo:parkLine3(text).
--   note(ctx, event)
--       Every referee event on its way to the screen, after the core's own
--       reading of it (M:_note3).
--   settle(ctx, outcome) -> handled
--       The verdict is in, ctx.verdict / ctx.whiteout / ctx.healAfter /
--       ctx.scriptedLoss decided (and still the kind's to change).  True
--       skips the core's after-words (the defeated line, the defeat speech
--       and the prize; or the lost lines).
--   word(ctx, outcome, ending) -> doneWord?
--       Contract C5: `ending.result` (handed to `done`) and `ending.word`
--       (session.battleOutcome, the TV) as the core read them off
--       outcome.how / by, ending.halt (the trainer-script halt of a draw),
--       and the monsters the reports name (playerMon, foeMon, playerMon2,
--       lastFoeMon).  A word returned replaces ending.result and lifts the
--       halt: the kind answers the caller itself.  Throws: the core's word.
--   finish(ctx, outcome, ending) -> after?
--       After the rewards, the prompts and the engine's end-of-battle
--       reports, before the map's resume scripts and `done(ending.result)`:
--       the kind's writeback and engine tails.  A function returned is
--       called once `done` has returned (a record the caller's
--       continuation would otherwise overwrite).
--   handBack(ctx) -> handled
--       A fight the referee could not keep going is about to be handed back
--       (M:_reset3): put back what the kind took.  True: the kind started
--       the cart's battle itself.
--
-- Flags a kind may set on ctx: `partyless` (the screen uploads no party:
-- Safari, a tutorial), `noReconcile` (HP / PP / status are not written home:
-- the party was not in the fight, or was rented), `lossless` (an ending with
-- nobody standing on side a costs nothing: no whiteout, no lost lines),
-- `noPickup`, `noDexSeen` (the foe's send-out marks no dex "seen": FRLG
-- legendaries, a veiled ghost, the Frontier), `noFieldReturn` (the fight does
-- not end on the field, so the map's resume scripts are not run: the TEACHY
-- TV's demonstrations, which go back to the TEACHY TV -- pret teachy_tv.c:1208
-- TeachyTvRestorePlayerPartyCallback, CB2_ReturnToTeachyTV).
--
-- A family module is found by its name the first time a fight asks for one
-- (M.KIND_FILES3), so nothing at boot has to list them: it returns a table
-- whose `kinds3` maps names to kinds, or registers them itself at load.
M.KINDS3 = {}

-- The kind names this file fights itself.
M.DEFAULT_KINDS3 = { wild = true, trainer = true }

-- Where each family lives (wave 2 / 3 of the plan).
M.KIND_FILES3 = {
  safari = "Solo3/Safari",
  roamer = "Solo3/Legend", legendary = "Solo3/Legend",
  scripted = "Solo3/Legend", ghost = "Solo3/Legend",
  facility = "Solo3/Facility",
  pair = "Solo3/Doubles", partner = "Solo3/Doubles",
  firstBattle = "Solo3/First",
  tutorial = "Solo3/Tutorial",
}

-- The engine keys that spell each kind (contract C1's refusal keys), for a
-- fight that arrives with no stand naming it (a direct call; an older
-- stand): the first family that matches names the fight, in the order
-- src/CoopField.lua's classify3 asks (the cart's own nesting: a tutorial
-- whatever else it is; a facility's hall decides even its pair and partner
-- fights -- a Battle Tower multi carries all three; a first battle before a
-- trainer; the ghost before the scripted wild, the Marowak being both).
-- Safari and the veiled ghost are also session states the engine reads at
-- its own start (the safari flag, a Tower floor without the SILPH SCOPE);
-- only the stand sees those.
M.KIND_KEYS3 = {
  { "tutorial", { "oldManTutorial", "tutorialKind", "tutorial", "pokedude" } },
  { "facility", { "dome", "palace", "arena", "factory", "pike", "pyramid", "battleTower",
                  "tower", "trainerHill", "trainerTower", "secretBase", "frontier" } },
  { "firstBattle", { "firstBattle", "firstBattleKind" } },
  { "partner", { "partner" } },
  { "pair", { "twoOpponents", "trainerIdB" } },
  { "safari", { "safari" } },
  { "roamer", { "roamer" } },
  { "ghost", { "ghost", "ghostBattle" } },
  { "legendary", { "legendary", "specialWild", "kyogreGroudon", "regi", "groudon", "kyogre",
                   "rayquaza" } },
  { "scripted", { "wildScripted" } },
}

-- The hooks a kind may carry; anything else on it is the kind's own.
M.KIND_HOOKS3 = {
  "takes", "screen", "seat", "brains", "choose", "note", "settle", "word", "finish", "handBack",
}

-- Register (or, on a hot reload, replace) a kind.  -> true, or false + why.
function M.registerKind3(name, kind)
  if type(name) ~= "string" or name == "" then return false, "a kind needs a name" end
  if type(kind) ~= "table" then return false, "a kind is a table of hooks" end
  for _, hook in ipairs(M.KIND_HOOKS3) do
    local fn = kind[hook]
    if fn ~= nil and type(fn) ~= "function" then
      return false, ("the %s kind's %s is not a function"):format(name, hook)
    end
  end
  M.KINDS3[name] = kind
  return true
end

function M.unregisterKind3(name)
  if type(name) == "string" then M.KINDS3[name] = nil end
end

-- A family module, read once per file, only when it is there: the mod's own
-- resolver gives up on every later module once one is missing or broken
-- (main.lua), so a file that does not exist yet is never asked for, and one
-- that does not even parse is said here and never handed to it.  A suite's
-- stub facade has no reader; its kinds are registered by hand.
local kindFilesTried3 = {}
local function kindLoadWarn3(file, why)
  if not (type(mod) == "table" and type(mod.log) == "table") then return end
  mod.log:warn("the %s solo battles could not be loaded from src/%s.lua (%s); those fights "
    .. "are fought the ordinary way -- reinstall the mod folder so that file is whole",
    file, file, tostring(why))
end
local function loadKindFile3(file)
  if kindFilesTried3[file] then return end
  kindFilesTried3[file] = true
  if not (type(mod) == "table" and type(mod.read) == "function") then return end
  local okR, body = pcall(mod.read, mod, "src/" .. file .. ".lua")
  if not (okR and type(body) == "string") then return end
  local loadstr = loadstring or load
  local chunk, syntaxErr = loadstr(body, "@rby_mmo/src/" .. file .. ".lua")
  if not chunk then
    kindLoadWarn3(file, syntaxErr)
    return
  end
  -- Through the resolver, so the family is the one module every reader of it
  -- shares; a family that registers itself returns nothing (the resolver's
  -- `true`), one that failed to start returns nil (main.lua logs why).  Asked
  -- for as optional: a family that throws while starting is kept to itself
  -- and never switches the resolver off for the modules asked after it.
  local ok, family = pcall(need, file, true)
  if not ok or family == nil then
    kindLoadWarn3(file, ok and "it failed to start" or family)
    return
  end
  if type(family) == "table" and type(family.kinds3) == "table" then
    for name, kind in pairs(family.kinds3) do
      if M.KINDS3[name] == nil then M.registerKind3(name, kind) end
    end
  end
end

-- Every family module there is, read now (an install that would rather
-- meet a broken one at boot than at its first fight).  -> the kind names
-- registered.
function M.loadKinds3()
  local files = {}
  for _, file in pairs(M.KIND_FILES3) do files[file] = true end
  for file in pairs(files) do loadKindFile3(file) end
  local names = {}
  for name in pairs(M.KINDS3) do names[#names + 1] = name end
  table.sort(names)
  return names
end

-- The kind registered under `name`, its family module read first if need be.
function M.kind3(name)
  if type(name) ~= "string" then return nil end
  local kind = M.KINDS3[name]
  if kind then return kind end
  local file = M.KIND_FILES3[name]
  if file then loadKindFile3(file) end
  return M.KINDS3[name]
end

-- The kind name of a fight: the stand's `kind3` (opts.stand3, src/CoopField.lua),
-- else a caller's own `opts.kind3`, else the first family whose engine key
-- is set on the opts, the foe / encounter, or a `kinds` table on either
-- (set to anything but false: the trainer op's `firstBattle = false` is an
-- ordinary trainer), else `base` ("wild" / "trainer").
function M.kind3Name(opts, foe, base)
  opts = type(opts) == "table" and opts or {}
  local stand = type(opts.stand3) == "table" and opts.stand3 or nil
  local named = stand and stand.kind3
  if type(named) == "string" and named ~= "" then return named end
  if type(opts.kind3) == "string" and opts.kind3 ~= "" then return opts.kind3 end
  local places = {}
  for _, t in ipairs({ opts, foe }) do
    if type(t) == "table" then
      places[#places + 1] = t
      if type(t.kinds) == "table" then places[#places + 1] = t.kinds end
    end
  end
  for _, row in ipairs(M.KIND_KEYS3) do
    for _, key in ipairs(row[2]) do
      for _, place in ipairs(places) do
        local v = place[key]
        if v ~= nil and v ~= false then return row[1] end
      end
    end
  end
  return base
end

local unpack3 = unpack or table.unpack
local function pack3(...) return { n = select("#", ...), ... } end

-- One hook of the fight's kind, guarded: -> true, its results; false when
-- the kind has no such hook; false, "error" when it threw (said once).
function M:_hook3(ctx, name, ...)
  local kind = type(ctx) == "table" and ctx.hooks3 or nil
  local fn = type(kind) == "table" and kind[name] or nil
  if type(fn) ~= "function" then return false end
  local res = pack3(pcall(fn, kind, ctx, ...))
  if not res[1] then
    self:warn("kind3:" .. name, "the %s fight's own rules failed at '%s' (%s); %s", tostring(ctx.name),
      name, tostring(res[2]), (name == "takes" or name == "screen" or name == "seat" or name == "brains")
        and "this fight is fought the ordinary way -- report it with the battle you met"
        or "the battle carries on by the ordinary rules -- report it with the battle you were in")
    return false, "error"
  end
  return true, unpack3(res, 2, res.n)
end

-- Copy `extra`'s keys onto `into` (a hook's returned table).
local function merge3(into, extra)
  if type(extra) ~= "table" then return into end
  for k, v in pairs(extra) do into[k] = v end
  return into
end

-- Helpers a kind's `choose` reaches through ctx.solo: file a choice into the
-- referee (M:_submit3), and park a line the pump prints before the window
-- comes back with nothing spent (the trapped-RUN path).
function M:file3(payload, seat) return self:_submit3(payload, seat) end
function M:parkLine3(text)
  if type(text) == "string" and text ~= "" then self.cantEscape = text end
end
function M:say3(text) return self:_say3(text) end

-- ------------------------------------------------------------------
-- the monsters on the other side, built as the engine builds them
-- ------------------------------------------------------------------

-- A wild monster's held item, SetWildMonHeldItem.  Emerald asks its own
-- encounter rules (the engine's encounter_rules/rse.lua wildHeldItem: pret
-- pokeemerald/src/pokemon.c:6678, Compound Eyes and the common == rare
-- certainty included).  FireRed / LeafGreen is pret pokefirered/src/
-- pokemon.c:6032 itself: one Random() % 100 drawn whatever the species
-- holds; a species whose common and rare slots name the same item holds it
-- every time (FRLG's Snorlax and its LEFTOVERS); otherwise 45..94 is the
-- common item and 95..99 the rare one -- not the engine port's `r < 50` /
-- `r < 55` reading (battle/init.lua foe_mon_from), which keeps the odds but
-- maps the draw onto the wrong items and never draws for an empty species.
-- pret wins.  Whether the roll happens at all is the caller's (M.gen3HeldRoll).
--
-- opts: { alteringCave = true } on Emerald's ALTERING CAVE (M.gen3AlteringCave):
-- pret pokeemerald pokemon.c:6692 reads `gMapHeader.mapLayoutId ==
-- LAYOUT_ALTERING_CAVE` and, for a species in sAlteringCaveWildMonHeldItems,
-- holds that table's item at 95..99 (the cart's own table, which the engine's
-- wildHeldItem reads from the player's cart -- wild_extra's
-- alteringCaveHeldItems); FireRed / LeafGreen has no such arm.
--
-- -> item (0 for none), wrote: whether SetWildMonHeldItem wrote the held
-- item at all.  pret returns early on a draw under chanceNoItem (or under
-- chanceNotRare for an Altering Cave species) and leaves whatever the
-- monster already held -- `setwildbattle`'s item -- but every other draw is
-- a SetMonData over it, ITEM_NONE included (an item-less species' common
-- slot, FRLG's common == rare == ITEM_NONE): a builder keeps its row's item
-- only when `wrote` is false (M.gen3FoeMon, CoopField's buildMon).  The
-- engine's wildHeldItem says the same with nil (returned early) or a number.
function M.gen3WildItem(species, random16, opts)
  if Gen3.family() == "rse" then
    local Enc = Gen3.engine("src.core.game3.encounters")
    local rules = Enc and try3(Enc.rules)
    local held = type(rules) == "table" and try3(rules.wildHeldItem, species,
      { alteringCave = (type(opts) == "table" and opts.alteringCave) and true or nil }) or nil
    return int3(held, 0), int3(held, nil) ~= nil
  end
  local info = Gen3.speciesInfo(species)
  local items = info and info.heldItems or {}
  local common, rare = int3(items.common, 0), int3(items.rare, 0)
  local r = random16() % 100
  if common == rare then return common, true end
  if r > 44 then
    if r <= 94 then return common, true end
    return rare, true
  end
  return 0, false
end

-- Emerald's ALTERING CAVE, where SetWildMonHeldItem rolls the cave's own
-- held items (pret pokeemerald pokemon.c:6692, LAYOUT_ALTERING_CAVE -- the
-- one map on that layout, MAP_ALTERING_CAVE; the engine's map id for it).
-- FireRed's SIX ISLAND cave is another map, and its cart has no such arm.
M.ALTERING_CAVE3 = "EM_ALTERING_CAVE"
function M.gen3AlteringCave(mapId)
  return mapId == M.ALTERING_CAVE3
end

-- Whether a wild foe rolls a held item at all (SetWildMonHeldItem's gate; a
-- trainer's monster never reaches it -- M.gen3TrainerParty builds with
-- `wild = false`): not under BATTLE_TYPE_LEGENDARY -- which on FireRed /
-- LeafGreen is also GHOST_UNVEILED, the scoped Marowak (pret pokefirered
-- include/constants/battle.h) -- nor for the Teachy TV's POKeDUDE (FRLG),
-- nor a Battle Pyramid or Battle Pike wild (Emerald, whose facility builds
-- its own monsters anyway).  Read off the engine's own opts and the foe row,
-- the places the engine spells these (battle/init.lua:717-740).  An exempt
-- fight keeps its row's own item (`setwildbattle`'s, Southern Island's SOUL
-- DEW); any other wild rolls over it (M.gen3WildItem's `wrote`).
M.HELD_ROLL_EXEMPT3 = {
  "legendary", "specialWild", "kyogreGroudon", "regi", "groudon", "kyogre", "rayquaza",
  "ghostUnveiled", "pokedude", "pyramid", "pike",
}
function M.gen3HeldRoll(opts, foe)
  for _, place in ipairs({ opts, foe }) do
    if type(place) == "table" then
      for _, key in ipairs(M.HELD_ROLL_EXEMPT3) do
        local v = place[key]
        if v ~= nil and v ~= false then return false end
      end
    end
  end
  return true
end

-- A move as a number: a trainer row may name its custom moves.
local function moveNum3(entry)
  if type(entry) == "table" then entry = entry.id or entry.num or entry.move end
  local n = tonumber(entry)
  if n then return floor(n) end
  if type(entry) == "string" and entry ~= "" then
    local Moves = Gen3.engine("src.core.game3.battle.moves")
    return int3(Moves and try3(Moves.numForName, entry), nil)
  end
  return nil
end

-- One foe monster, the way the engine completes one (battle/init.lua
-- foe_mon_from, which is local there): the personality off Random32 unless
-- given, a wild monster's IVs off two Random() draws and its held item off a
-- third, gender and nature from the personality, the moves the party row
-- names or else the last four the learnset gives by this level (pret
-- GiveMonInitialMoveset), stats and ability through Damage.ensureStats, and
-- exp set on the growth curve (Experience.syncExpToLevel) -- so a caught one
-- is the cart's monster at that level, not a sheet.
--
-- opts: { wild = true } for an encounter (the IV / item draws), and
-- `heldRoll = false` (M.gen3HeldRoll's answer) for a wild that rolls no held
-- item -- a legendary, the scoped Marowak, the POKeDUDE's -- and
-- `alteringCave = true` on Emerald's ALTERING CAVE (M.gen3AlteringCave).  A
-- wild that rolls rolls over the row's own item as SetWildMonHeldItem does
-- (CB2_InitBattleInternal runs it after setwildbattle's CreateScriptedWildMon:
-- pokeemerald battle_main.c:700, pokefirered battle_main.c:708), keeping it
-- only when the draw wrote nothing (M.gen3WildItem).  A row's
-- `fatefulEncounter` (seteventmon / CreateEnemyEventMon, the engine's
-- natives_events.lua: Mew, Deoxys and the island legendaries) is carried on
-- the monster, so the one caught keeps the bit its obedience and a trade
-- read.  nil when the engine cannot describe the species.
function M.gen3FoeMon(row, opts)
  opts = opts or {}
  if type(row) ~= "table" then return nil end
  local P = Gen3.engine("src.core.game3.pokemon")
  if not P then return nil end
  local species = int3(row.species, nil) or int3(row.speciesId, nil)
  if not species and type(row.species) == "string" then
    species = int3(try3(P.speciesFromName, row.species), nil)
  end
  if not species or species < 1 then return nil end
  local level = max(1, min(100, int3(row.level, 5)))
  local Rng = Gen3.engine("src.core.game3.rng")
  local function random16()
    local v = int3(Rng and try3(Rng.Random), nil)
    if v then return v % 65536 end
    return math.random(0, 65535)
  end
  local personality = int3(row.personality, nil)
  if personality == nil then
    personality = int3(Rng and try3(Rng.Random32), nil) or (random16() * 65536 + random16())
  end
  personality = personality % 4294967296
  local ivs
  if type(row.ivs) == "table" then
    ivs = {}
    for _, k in ipairs(STAT_KEYS3) do ivs[k] = max(0, min(31, int3(row.ivs[k], 0))) end
  elseif opts.wild then
    local iv1, iv2 = random16(), random16()
    ivs = {
      hp = iv1 % 32, atk = floor(iv1 / 32) % 32, def = floor(iv1 / 1024) % 32,
      spe = iv2 % 32, spa = floor(iv2 / 32) % 32, spd = floor(iv2 / 1024) % 32,
    }
  else
    local iv = max(0, min(31, int3(row.iv, 0)))
    ivs = { hp = iv, atk = iv, def = iv, spe = iv, spa = iv, spd = iv }
  end
  local evs = {}
  for _, k in ipairs(STAT_KEYS3) do
    evs[k] = type(row.evs) == "table" and max(0, min(255, int3(row.evs[k], 0))) or 0
  end
  local item = int3(row.item, nil) or int3(row.heldItem, nil)
  if opts.wild and opts.heldRoll ~= false then
    local rolled, wrote = M.gen3WildItem(species, random16, { alteringCave = opts.alteringCave })
    if wrote or item == nil then item = rolled end
  end
  item = max(0, item or 0)
  local gender = row.gender
  if gender ~= "M" and gender ~= "F" and gender ~= "U" then
    gender = try3(P.gender, species, personality) or "U"
  end
  local info = Gen3.speciesInfo(species) or {}
  local friendship = int3(row.friendship, nil) or int3(info.baseFriendship, 70)
  local mon = {
    species = species, speciesId = species,
    name = try3(P.name, species), nickname = "",
    level = level,
    item = item, heldItem = item,
    gender = gender, ivs = ivs, evs = evs,
    personality = personality,
    nature = int3(row.nature, nil) or int3(try3(P.natureId, personality), nil) or personality % 25,
    ability = int3(row.ability or row.abilityId, nil),
    friendship = friendship, happiness = friendship,
    pokeball = 4, pokerus = 0,
  }
  mon.abilityId = mon.ability
  local moves = {}
  for _, entry in ipairs(type(row.moves) == "table" and row.moves or {}) do
    local n = moveNum3(entry)
    if n and n > 0 and #moves < 4 then moves[#moves + 1] = n end
  end
  if #moves > 0 then
    mon.moves = moves
    mon.pp = copyList(row.pp)
    mon.maxPp = copyList(row.maxPp)
  else
    local ok, lm, lp, lmax = pcall(P.movesAtLevel, species, level)
    if not (ok and type(lm) == "table" and #lm > 0) then return nil end
    mon.moves, mon.pp, mon.maxPp = lm, copyList(lp), copyList(lmax)
  end
  if type(mon.maxPp) ~= "table" or #mon.maxPp < #mon.moves then
    mon.maxPp = {}
    for i, m in ipairs(mon.moves) do
      mon.maxPp[i] = int3(try3(P.movePp, m), nil) or int3(try3(function()
        return Gen3.moveInfo(m).pp
      end), 5)
    end
  end
  if type(mon.pp) ~= "table" or #mon.pp < #mon.moves then
    mon.pp = {}
    for i in ipairs(mon.moves) do mon.pp[i] = mon.maxPp[i] end
  end
  local Damage = Gen3.engine("src.core.game3.battle.damage")
  if not (Damage and pcall(Damage.ensureStats, mon, level)) then
    if not pcall(P.applyStats, mon) then return nil end
  end
  if mon.ability == nil then
    mon.ability = int3(try3(P.abilityId, species, personality), 0)
    mon.abilityId = mon.ability
  end
  local hp = int3(row.hp, nil)
  if hp == nil or hp > int3(mon.maxHp, 1) then hp = mon.maxHp end
  mon.hp = hp
  if type(row.status) == "string" and row.status ~= "" then mon.status = row.status end
  if row.fatefulEncounter ~= nil then mon.fatefulEncounter = row.fatefulEncounter and true or false end
  local Experience = Gen3.engine("src.core.game3.battle.experience")
  if Experience then pcall(Experience.syncExpToLevel, mon) end
  return mon
end

-- A trainer's personalities, pret CreateNPCTrainerParty: a base of 0x80 for a
-- double battle, 0x78 for a female trainer, 0x88 otherwise, plus a running
-- hash of the trainer's and each species' names shifted up a byte.  The engine
-- computes that hash (Trainers._doublePersonalities, the same GBA charset
-- sums) but only uses it for doubles; the cart uses it for every trainer, so
-- it is re-based here for singles.  nil when the row cannot be read.
function M.gen3TrainerPersonalities(trainerId, count)
  local Trainers = Gen3.engine("src.core.game3.scripting.trainers")
  local t = Trainers and trainerId and try3(Trainers.get, trainerId)
  if type(t) ~= "table" or type(Trainers._doublePersonalities) ~= "function" then return nil end
  local pers = try3(Trainers._doublePersonalities, t)
  if type(pers) ~= "table" or (count and #pers ~= count) then return nil end
  if t.doubleBattle then return pers end
  local female = int3(t.gender, 0) == 1 or int3(t.encounterMusic, 0) >= 128
  local base = female and 0x78 or 0x88
  local out = {}
  for i, p in ipairs(pers) do out[i] = (int3(p, 0x80) - 0x80 + base) % 4294967296 end
  return out
end

-- The `trainer.party` hook, as BattleBridge runs it before a trainer battle
-- (battle_bridge.lua hooked_trainer_party): another mod that reshapes trainer
-- parties reshapes this fight too.  The foe unchanged when nothing wraps it.
function M.gen3HookedFoe(foe, trainerId)
  local Runtime = Gen3.engine("src.mods.Runtime")
  if not (Runtime and try3(Runtime.wantsHook, "trainer.party")) then return foe end
  local G3 = Gen3.engine("src.mods.Gen3Compat")
  if not (G3 and type(foe) == "table" and type(foe.party) == "table") then return foe end
  local named = try3(G3.partyNames, foe.party)
  if type(named) ~= "table" then return foe end
  local ok, out = pcall(Runtime.call, "trainer.party", function(_, _, party) return party end,
    foe.trainerClass, trainerId, named)
  if not (ok and type(out) == "table" and #out > 0) then return foe end
  local nums = try3(G3.partyNums, out)
  if type(nums) ~= "table" or #nums == 0 then return foe end
  local copy = {}
  for k, v in pairs(foe) do copy[k] = v end
  copy.party = nums
  return copy
end

-- The trainer's whole party as engine monsters: each row's own moves (else
-- the learnset), its held item (the cart's -- no wild item roll on a trainer's
-- monster), its IVs from the trainer's difficulty, zero EVs, the pret
-- personality.
function M.gen3TrainerParty(foe, trainerId)
  if type(foe) ~= "table" then return {} end
  local rows = (type(foe.party) == "table" and #foe.party > 0) and foe.party or { foe }
  local pers = M.gen3TrainerPersonalities(trainerId, #rows)
  local out = {}
  for i, raw in ipairs(rows) do
    if type(raw) == "table" then
      local row = {}
      for k, v in pairs(raw) do row[k] = v end
      if row.personality == nil and pers then row.personality = pers[i] end
      local mon = M.gen3FoeMon(row, { wild = false })
      if mon then
        mon.trainerId = trainerId
        out[#out + 1] = mon
      end
    end
  end
  return out
end

-- Rendered text for a dialog the engine may hold as a string or as a text IR
-- (Trainers.dialogs reads the live script VM's copy).
local function textOf3(value)
  if type(value) == "string" then return value ~= "" and value or nil end
  if type(value) ~= "table" then return nil end
  local TextIR = Gen3.engine("src.core.game3.scripting.text_ir")
  local s = TextIR and try3(TextIR.toPlain, value, {})
  if type(s) == "string" and s ~= "" then return s end
  return nil
end

local function strOr(...)
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    if type(v) == "string" and v ~= "" then return v end
  end
  return nil
end

-- The NPC record MediatedBattle, SoloBrain and the music read: the numeric
-- trainer id (Gen3.audio's battle / victory themes), class and name, the
-- TRAINER_PIC_* the arena stands on the foe edge, the four item slots, the
-- AI flags, the overworld graphic (Gen.trainerWalkSpriteId), the dialogs.
--
-- The name is the trainer book's first, as the engine's battle reads it
-- (battle/init.lua: `trainerInfo.name or opts.trainerName`): Trainers.info
-- answers FireRed's rival and Champion with the name the player gave the
-- rival (`rivalName`, pret battle_message.c:2078), where the foe record and
-- the row both carry the cart's placeholder.
function M.gen3TrainerRecord(foe, trainerId, opts)
  opts = type(opts) == "table" and opts or {}
  foe = type(foe) == "table" and foe or {}
  local Trainers = Gen3.engine("src.core.game3.scripting.trainers")
  local session = Gen3.session()
  local rivalName = strOr(opts.rivalName, session and session.rivalName)
  local info = (Trainers and trainerId)
    and try3(Trainers.info, trainerId, { rivalName = rivalName }) or nil
  info = type(info) == "table" and info or {}
  local dialogs = type(info.dialogs) == "table" and info.dialogs or {}
  local class = int3(foe.trainerClass, nil) or int3(info.class, nil)
  local className = strOr(foe.trainerClassName, info.className)
  local name = strOr(info.name, opts.trainerName, foe.trainerName)
  local graphicsId = int3(opts.graphicsId, nil)
    or (type(opts.object) == "table" and int3(opts.object.graphicsId, nil)) or nil
  return {
    id = trainerId, trainerId = trainerId,
    trainerClass = class, classId = class,
    className = className, trainerClassName = className,
    trainerName = name,
    name = name or className or "TRAINER",
    trainerPic = int3(opts.trainerPicId, nil) or int3(foe.trainerPic, nil) or int3(info.pic, nil),
    items = foe.items or info.items,
    aiFlags = int3(opts.aiFlags, nil) or int3(foe.aiFlags, nil) or int3(info.aiFlags, 0),
    gender = foe.gender or info.gender,
    graphicsId = graphicsId,
    defeatText = textOf3(opts.defeatText) or textOf3(foe.defeatText) or textOf3(dialogs.defeat),
    victoryText = textOf3(opts.victoryText) or textOf3(foe.victoryText) or textOf3(dialogs.victory),
  }
end

-- "YOUNGSTER BEN", the way the cart names a trainer in "... would like to
-- battle!".
function M.gen3FoeLabel(trainer)
  if type(trainer) ~= "table" then return "TRAINER" end
  local class, name = trainer.className, trainer.trainerName
  if type(class) == "string" and class ~= "" and type(name) == "string" and name ~= "" then
    return class .. " " .. name
  end
  return strOr(name, class) or "TRAINER"
end

-- The terrain a wild fight is fought on (pret battle_main.c:689, the engine's
-- BattleBg.resolveFromBehavior over the cell the player stands on), for
-- Nature Power / Secret Power / Camouflage, and whether the map is underwater
-- (the Dive Ball).  Terrains past PLAIN are backdrops only and read as the
-- sim's BUILDING default.
function M.gen3Terrain(game)
  local BattleBg = Gen3.engine("src.core.game3.battle.bg")
  local Map = Gen3.engine("src.core.game3.map")
  if not (BattleBg and Map) then return nil, false end
  local mapId = Map.current
  local maps = type(game) == "table" and type(game.data) == "table" and game.data.maps or nil
  local def = type(maps) == "table" and mapId and maps[mapId] or nil
  local mapKind = type(def) == "table" and def.kind or nil
  local mapType = type(def) == "table" and def.mapType or nil
  local behavior
  local Collision = Gen3.engine("src.core.game3.collision")
  local Player = Gen3.engine("src.core.game3.player")
  if Collision and Player then
    local bx, by = Player.cellX, Player.cellY
    if Player.moving then bx, by = Player.targetX, Player.targetY end
    behavior = try3(Collision.behavior, bx, by)
  end
  local terrain
  if behavior ~= nil or mapType ~= nil then
    terrain = int3(try3(BattleBg.resolveFromBehavior, behavior, mapKind, mapType), nil)
  end
  if terrain == nil and mapKind then terrain = int3(try3(BattleBg.resolveFromMapKind, mapKind), nil) end
  local underwater = terrain == 3 or mapType == 5 or mapType == "MAP_TYPE_UNDERWATER"
  if terrain ~= nil and (terrain < 0 or terrain > 9) then terrain = 8 end
  return terrain, underwater and true or false
end

-- Is anything in this party still able to fight?  A Battle Arena loser the
-- judge "fainted" is not, whatever HP it kept (pret Cmd_checkteamslost skips
-- arenaLost*Mons): marked `judged` on the monster itself (a referee sheet),
-- or named in `judged` -- a set of 0-based party positions, the referee's
-- judged sheets' `slot`s (M.judgedSlots3) -- for a save party, which never
-- carries the mark.
function M.gen3Standing(party, judged)
  judged = type(judged) == "table" and judged or {}
  for i, mon in ipairs(type(party) == "table" and party or {}) do
    if type(mon) == "table" and not mon.isEgg and int3(mon.species, 0) ~= 412
        and int3(mon.hp, 0) > 0 and not mon.judged and not judged[i - 1] then
      return true
    end
  end
  return false
end

-- The party positions (0-based, the sheets' `slot`) of a referee fighter's
-- judged monsters (BattleSim3/Arena.lua), or an empty set.
function M.judgedSlots3(fighter)
  local out = {}
  for _, sheet in ipairs(type(fighter) == "table" and type(fighter.mons) == "table" and fighter.mons or {}) do
    if type(sheet) == "table" and sheet.judged then out[int3(sheet.slot, 0)] = true end
  end
  return out
end

-- Level per session-party monster by identity (see M:_levelSnapshot for why).
function M.levels3(party)
  if type(party) ~= "table" then return nil end
  local out = setmetatable({}, { __mode = "k" })
  for _, mon in ipairs(party) do
    if type(mon) == "table" then out[mon] = int3(mon.level, 0) end
  end
  return out
end

function M.levelled3(party, levels)
  if not (type(party) == "table" and type(levels) == "table") then return nil end
  local out, any = {}, false
  for _, mon in ipairs(party) do
    local before = levels[mon]
    if before and int3(mon.level, 0) > before then out[mon] = true; any = true end
  end
  return any and out or nil
end

-- The engine's words for how it went (contract C5): the one `done(result)`
-- is handed (battle_bridge's continuation: a native's VAR_RESULT, the
-- trainerbattle opcode) and the one session.battleOutcome / the TV are
-- written from (Natives.outcome_to_code, pret B_OUTCOME_*).  Every post-battle
-- script reads the code (`specialvar VAR_RESULT, GetBattleOutcome`), and a
-- legendary's script turns on it: WON is "defeated", RAN / PLAYER_TELEPORTED
-- "ran from", anything else falls through to FLAG_CAUGHT_X -- so the word is
-- read off how the referee says the fight ended (outcome().how / by), never
-- off which side left:
--
--   how "catch"                -> "caught"            (7)
--   how "flee" (a wild seat's own RUN) -> "mon_fled"  (6)
--   how "run" (the player's RUN, a POKe DOLL / FLUFFY TAIL) -> "run" (4)
--   how "teleport" / "roar"    -> "teleport_player" (5), except where the
--       cart says the outcome by the user's side (Emerald's
--       VARIOUS_SET_TELEPORT_OUTCOME, pokeemerald battle_script_commands.c:
--       6487; the engine's profile rule teleportOutcome = "side") and the
--       wild monster used it: "mon_teleported" (10).  FireRed / LeafGreen
--       set PLAYER_TELEPORTED whoever used it (battle_scripts_1.s:1933 /
--       :3290) -- Mew's TELEPORT on Emerald is 10, and FARAWAY ISLAND's
--       script keeps the Mew; a player's WHIRLWIND on Mewtwo is 5, "ran
--       from", never the catch path.
--   how "balls"                -> "no_safari_balls"   (8)
--   how "forfeit"              -> "forfeited"         (9)
--   a knockout / an Arena judgment / the clock: a whiteout is "lose" to
--       `done` whatever the knockouts said (pret IsPlayerDefeated counts
--       DREW), and to the save what they said -- both sides out at once is
--       DREW (3: pret Cmd_checkteamslost ORs B_OUTCOME_LOST and
--       B_OUTCOME_WON into gBattleOutcome, pokeemerald
--       battle_script_commands.c:3564 / :3577, pokefirered :3401 / :3413),
--       which a post-battle script and a roamer's writeback read; else the
--       verdict. A knockout draw whose sheets and the save disagree is
--       promoted to a win in M:_settle3 before this mapping. Every other
--       trainer draw maps to "lose" for `done` and DREW for the save, and
--       an ordinary trainer's is halted so the beaten script does not run;
--       special kinds supply their own `word` hook (a facility's "draw",
--       a pair's "lose").
--
-- info: { verdict ("win" | "loss" | "draw", ours), reason, how, by,
--         whiteout, ranSide, kind ("wild" | "trainer"), teleportBySide }.
-- A referee that says no `how` (one older than W1-RF's outcome fields) is
-- read the old way: reason "catch", and a "run" by the side the referee's
-- `run` event named (`ranSide`; none -- a POKe DOLL -- was ours), else by
-- the verdict.
-- -> doneWord, saveWord
function M.gen3Words(info)
  info = type(info) == "table" and info or {}
  local verdict, how = info.verdict, info.how
  if how == nil then
    if info.reason == "catch" then
      how = "catch"
    elseif info.reason == "run" then
      local side = info.ranSide
      if side ~= "a" and side ~= "b" then side = (verdict == "win") and "b" or "a" end
      how = (side == "b") and "flee" or "run"
    end
  end
  if how == "catch" then return "caught", "caught" end
  if how == "flee" then return "mon_fled", "mon_fled" end
  if how == "run" or how == "item" then return "run", "run" end
  if how == "teleport" or how == "roar" then
    local w = (info.teleportBySide and info.by == "b") and "mon_teleported" or "teleport_player"
    return w, w
  end
  if how == "balls" then return "no_safari_balls", "no_safari_balls" end
  if how == "forfeit" then return "forfeited", "forfeited" end
  if info.whiteout then return "lose", (verdict == "draw") and "draw" or "lose" end
  if verdict == "win" then return "win", "win" end
  if verdict == "loss" then return "lose", "lose" end
  if info.kind == "trainer" then return "lose", "draw" end
  return "draw", "draw"
end

-- Does this cart word a TELEPORT / ROAR ending by the user's side?  The
-- engine's battle profile rule when it states one (Emerald's
-- teleportOutcome = "side"), else the family's.
function M.teleportBySide3(bp, family)
  local rules = type(bp) == "table" and type(bp.rules) == "table" and bp.rules or nil
  local rule = rules and rules.teleportOutcome
  if rule ~= nil then return rule == "side" end
  family = (type(bp) == "table" and bp.family) or family or Gen3.family()
  return family == "rse"
end

-- M.gen3Words' `done` word, in the older positional shape (kept for the
-- callers and suites that ask it so): `ranSide` is the side the referee's
-- `run` event named, `kind` "trainer" turns a draw into "lose", `how` / `by`
-- / `teleportBySide` are the outcome's own when known.
function M.gen3Result(verdict, reason, whiteout, ranSide, kind, how, by, teleportBySide)
  local done = M.gen3Words({
    verdict = verdict, reason = reason, whiteout = whiteout, ranSide = ranSide,
    kind = kind, how = how, by = by, teleportBySide = teleportBySide,
  })
  return done
end

-- ...and the word session.battleOutcome is written from: the same, except
-- that a drawn trainer fight the player is still standing after, and a
-- double knockout the player whites out from, stay B_OUTCOME_DREW for a
-- script that reads the outcome.
function M.gen3OutcomeWord(verdict, reason, whiteout, ranSide, how, by, teleportBySide)
  local _, save = M.gen3Words({
    verdict = verdict, reason = reason, whiteout = whiteout, ranSide = ranSide,
    how = how, by = by, teleportBySide = teleportBySide,
  })
  return save
end

-- ------------------------------------------------------------------
-- the two entries
-- ------------------------------------------------------------------
--
-- Both answer true when the fight is now this file's -- the screen is up, the
-- referee is running, and `opts.done(result)` is called at most once after it
-- ends (or after the engine's own battle, if a failing referee has to hand it
-- back). It is never called for an unfinished trainer draw the player is
-- still standing after -- a timeout, a disconnect, a forfeit: the trainer
-- script waiting on it is halted instead (M.haltScript3; no flag, no prize,
-- B_OUTCOME_DREW on the save, none of the bytes after the trainerbattle
-- command). Only a knockout draw whose sheets and the save disagree
-- (M:_settle3) completes as a win; a kind's own `word` (a facility's draw, a
-- pair's or Steven's) answers its caller itself. They answer false,
-- silently, when they declined, in which case nothing at all has happened
-- and the caller starts the engine's own battle.
--
-- opts (both):
--   done       function(result): "win" | "lose" | "draw" | "run" | "mon_fled"
--              | "caught" | "teleport_player" | "mon_teleported" |
--              "no_safari_balls" | "forfeited" (M.gen3Words, contract C5) --
--              Natives.outcome_to_code's vocabulary, so a caller can hand this
--              the very callback it was going to hand the engine (the trainer
--              script's resume, the trainer flag, a native's VAR_RESULT).
--              Called after the rewards, the whiteout and the evolutions.
--   stand3     (optional) the stand-in src/CoopField.lua built for the fight
--              (contract C1): its `kind3` names the fight's kind (contract
--              C2, M.kind3Name), `facility3` / `tutorial3` the hall or the
--              tutorial; a kind reads the rest.  Without one, the engine's
--              own keys on the opts / foe name the kind.
--   fallback   function() (optional): starts the engine's own battle, for the
--              one case this file gives a fight back (a referee that keeps
--              faulting).  Without it, BattleBridge.start / startWild are
--              called with the same foe and `done`.
--   mapId      the map the fight is met on: Emerald's ALTERING CAVE rolls a
--              wild built here from the cave's own held items
--              (M.gen3AlteringCave); otherwise informational.
--   party      (optional) the opponent's monsters, already built as engine
--              monsters (src/CoopField.lua's stand-in builds them for its
--              cover before solo is asked): fought as they are, so the
--              monster the cover announced is the one fought and handed back,
--              and a wild's personality / IVs / item are rolled once, not
--              twice.  A wild encounter may carry its one monster as
--              `enc.mon` instead.  Built here, the engine's way, when absent.
--   + the engine's battle opts, read for refusals (Config.SOLO_REFUSED_GEN3)
--     and, on a trainer, for what they mean: trainerId, defeatText,
--     victoryText, trainerName, trainerPicId, noWhiteout, double, rivalName,
--     earlyRival / rivalFlags, graphicsId / object (the NPC's overworld
--     graphic, for the arena).
--
-- Both decline while this file is handing a fight back to the engine (see
-- M:_handBack3): that start re-enters the divert that called them.

-- An engine monster a caller handed in, when it is one: a species, a level
-- and a move list are what every later step reads off it.
local function prebuilt3(mon)
  return type(mon) == "table" and int3(mon.species, 0) > 0 and int3(mon.level, 0) > 0
    and type(mon.moves) == "table" and #mon.moves > 0
end

-- The caller's prebuilt party (`opts.party`), when every member of it is an
-- engine monster; nil to build one.
local function prebuiltParty3(party)
  if type(party) ~= "table" or #party == 0 then return nil end
  for _, mon in ipairs(party) do
    if not prebuilt3(mon) then return nil end
  end
  return party
end

-- A wild encounter: `enc` is what `encounter.roll` produced -- the engine
-- encounter { species (number or pret name), speciesId, level, item,
-- personality, moves, roamer, foe } -- or any foe row of that shape, and
-- optionally `mon` (see `party` above).
function M:fromGen3Encounter(game, enc, opts)
  opts = type(opts) == "table" and opts or {}
  if not self:isOn() then return false end
  if self.fight or self.handingBack3 then return false end
  if not (type(game) == "table" and Gen.generation(game) == 3) then return false end
  if type(enc) ~= "table" then return false end
  if M.gen3Refused(opts, enc) then return false end
  -- A roamer, a legendary, the Safari Zone...: their kind's, or the cart's.
  local ctx = self:_ctx3(game, "wild", opts, enc)
  if not ctx then return false end
  if self:_fightOnScreen3() then return false end
  if not self:_takes3(ctx) then return false end
  local mon = ctx.wildMon or (prebuiltParty3(ctx.party) and ctx.party[1]) or nil
  if not mon then
    local given = prebuiltParty3(opts.party)
    mon = (given and given[1]) or (prebuilt3(enc.mon) and enc.mon) or nil
  end
  mon = mon or M.gen3FoeMon(enc, { wild = true, heldRoll = M.gen3HeldRoll(opts, enc),
    alteringCave = M.gen3AlteringCave(opts.mapId) })
  if not mon then
    self:warn("nofoe3", "the wild POKéMON in this encounter could not be built for the "
      .. "mod's battle system, so it is fought the ordinary way; report this with "
      .. "the species you met")
    return false
  end
  ctx.wildMon = ctx.wildMon or mon
  ctx.party = prebuiltParty3(ctx.party) or { mon }
  local begun = self:_begin3(game, ctx)
  if begun then
    -- pret battle_setup.c: a battle starting re-arms the encounter cooldown,
    -- as BattleBridge.startWild does for the engine's own.
    local Enc = Gen3.engine("src.core.game3.encounters")
    if Enc then pcall(Enc.resetRateModifiers) end
  end
  return begun
end

-- A trainer: `foe` is the engine's foe record (Trainers.foeFromId, what the
-- trainer op hands startTrainerBattle), or a bare numeric trainer id.
function M:fromGen3Trainer(game, foe, opts)
  opts = type(opts) == "table" and opts or {}
  if not self:isOn() then return false end
  if self.fight or self.handingBack3 then return false end
  if not (type(game) == "table" and Gen.generation(game) == 3) then return false end
  local trainerId = int3(opts.trainerId, nil)
    or (type(foe) == "table" and int3(foe.trainerId, nil)) or int3(foe, nil)
  -- A bare id, or a record that names the trainer but carries no monsters:
  -- the party is the engine's own trainer row (Trainers.foeFromId, the
  -- trainer op's own lookup).
  if type(foe) ~= "table" or (type(foe.party) ~= "table" and foe.species == nil
                              and foe.speciesId == nil) then
    local Trainers = Gen3.engine("src.core.game3.scripting.trainers")
    foe = Trainers and trainerId and try3(Trainers.foeFromId, trainerId) or nil
  end
  if type(foe) ~= "table" then return false end
  if M.gen3Refused(opts, foe) then return false end
  -- Two trainers, Steven, a facility, Oak's lab...: their kind's, or the cart's.
  local ctx = self:_ctx3(game, "trainer", opts, foe)
  if not ctx then return false end
  ctx.trainerId = trainerId
  -- A lone double with two usable monsters is fought as the cart's double;
  -- any other double (a second trainer, a party that cannot field two) is
  -- the cart's to refuse in its own words.  A kind that says what shape its
  -- fight is (ctx.double true or false) is not asked this.
  local function loneDouble()
    local double = M.gen3Double(opts, foe)
    if double then
      local session = Gen3.session()
      if not M.gen3TakesDouble(opts, foe, session and session.party) then return false end
    end
    ctx.double = double or nil
    return true
  end
  if not ctx.hooks3 and not loneDouble() then return false end
  if self:_fightOnScreen3() then return false end
  if not self:_takes3(ctx) then return false end
  if ctx.hooks3 and ctx.double == nil and not loneDouble() then return false end
  -- A prebuilt party has been through the `trainer.party` hook already (the
  -- stand-in built it with M.gen3HookedFoe); it is not run a second time.
  local party = prebuiltParty3(ctx.party)
  local hooked = foe
  if not party then
    local given = prebuiltParty3(opts.party)
    hooked = given and foe or M.gen3HookedFoe(foe, trainerId)
    party = given or M.gen3TrainerParty(hooked, trainerId)
  end
  if #party == 0 then
    self:warn("nofoe3", "this trainer's party could not be built for the mod's battle "
      .. "system, so the trainer is fought the ordinary way; report this with the "
      .. "trainer you met")
    return false
  end
  ctx.party = party
  ctx.trainer = ctx.trainer or M.gen3TrainerRecord(hooked, trainerId, opts)
  return self:_begin3(game, ctx)
end

-- A stand-in that names neither an encounter nor a trainer (the Teachy TV's
-- POKeDUDE, routed here by src/CoopField.lua's wrap of its start): routed
-- through the entry its shape says -- a trainer stand to M:fromGen3Trainer,
-- anything else to M:fromGen3Encounter with its encounter, its foe, or its
-- first prebuilt monster as the row -- with the stand as `opts.stand3` and
-- its monsters as `opts.party`.  Every tutorial is a wild-shaped fight on
-- the cart (the old man's Weedle, Wally's Ralts, the POKeDUDE's demo foe),
-- so there is no third entry: the tutorial kind's own hooks (contract C2)
-- seat what differs.  `opts` are the engine's battle opts (the stand's own
-- `opts` when absent).  Same answer as the entry it reaches.
function M:fromGen3Stand(game, stand, opts)
  if type(stand) ~= "table" then return false end
  local o = {}
  local src = type(opts) == "table" and opts or (type(stand.opts) == "table" and stand.opts) or {}
  for k, v in pairs(src) do o[k] = v end
  o.stand3 = stand
  if o.party == nil and type(stand.enemyParty) == "table" and #stand.enemyParty > 0 then
    o.party = stand.enemyParty
  end
  if stand.kind == "trainer" then
    local foe = stand.foe or stand.trainerId
      or (type(stand.trainer) == "table" and stand.trainer.trainerId) or nil
    return self:fromGen3Trainer(game, foe, o)
  end
  local enc = type(stand.encounter) == "table" and stand.encounter
    or (type(stand.foe) == "table" and stand.foe) or nil
  if not enc then
    local lead = type(o.party) == "table" and o.party[1] or nil
    if type(lead) ~= "table" then return false end
    enc = { species = lead.species or lead.speciesId, level = lead.level, mon = lead }
  end
  return self:fromGen3Encounter(game, enc, o)
end

-- A fight's own state table (contract C2's `ctx`, kept as `self.gen3` once
-- it is seated), or nil when its kind is one nobody registered -- that fight
-- is the cart's.
function M:_ctx3(game, base, opts, foe)
  local name = M.kind3Name(opts, foe, base)
  local kind = nil
  if not M.DEFAULT_KINDS3[name] or M.KINDS3[name] then
    kind = M.kind3(name)
    if not kind then return nil end
  end
  local stand = type(opts.stand3) == "table" and opts.stand3 or nil
  return {
    solo = self, game = game,
    -- `kind` the entry's own "wild" / "trainer", `name` (and `kind3`, the
    -- stand's spelling) the kind's name, `hooks3` the registered kind.
    kind = base, name = name, kind3 = name, hooks3 = kind,
    stand = stand,
    -- The stand's details of its kind (src/CoopField.lua classify3): the
    -- hall, the tutorial, which first battle, which ghost.
    facility3 = stand and stand.facility3 or nil,
    tutorial3 = stand and stand.tutorial3 or nil,
    firstBattle3 = stand and stand.firstBattle3 or nil,
    ghost3 = stand and stand.ghost3 or nil,
    opts = opts, done = opts.done, foe = foe,
    session = Gen3.session(),
    family = Gen3.family(),
    song = opts.song,
    parties = {},
  }
end

-- The kind's `takes`, for a fight that has one; a throw is a no.
function M:_takes3(ctx)
  local ok, taken = self:_hook3(ctx, "takes")
  if ok then return taken and true or false end
  return taken ~= "error"
end

-- Another fight already owns the screen: the cart's own battle, or a mod
-- fight (a mediated 1v1, a co-op screen) on the game3 stack.
function M:_fightOnScreen3()
  if Gen3.inBattle() then return true end
  for _, screen in ipairs(Gen3Ui.states() or {}) do
    if type(screen) == "table" and (screen.mmoBattle or screen.sim ~= nil) then return true end
  end
  return false
end

-- ------------------------------------------------------------------
-- building the fight
-- ------------------------------------------------------------------

-- ctx is the fight's own state table (M:_ctx3, filled by the entry and the
-- kind's `takes`): kind ("wild" | "trainer"), party (the foe's engine
-- monsters), opts, foe, trainer, wildMon, double / foeSeats, and the kind.
function M:_begin3(game, ctx)
  local kind, party, opts = ctx.kind, ctx.party, ctx.opts or {}
  local Turn = turnFor(3)
  if type(Turn) ~= "table" or type(Turn.create) ~= "function" then
    self:warn("noturn", "the mod's Gen 3 battle referee could not be loaded, so this "
      .. "fight runs on the ordinary battle system; solo battles will keep falling "
      .. "back until the mod is reinstalled")
    return false
  end
  local enemySheets = Sheet3.mons(game, party, { wild = kind == "wild" })
  if type(enemySheets) ~= "table" or #enemySheets == 0 then
    self:warn("nofoe", "the opponent in this battle could not be described for the "
      .. "mod's battle system, so it is fought the ordinary way; report this with the "
      .. "trainer or the species you met")
    return false
  end
  ctx.enemySheets = enemySheets

  self.counter = self.counter + 1
  local battleId = ("solo_%d"):format(self.counter)
  local mode = (kind == "wild") and Config.SOLO_WILD_MODE or Config.SOLO_TRAINER_MODE
  local trainer = ctx.trainer
  local pending = {}
  ctx.battleId, ctx.mode, ctx.pending = battleId, mode, pending
  -- A double (M.gen3TakesDouble said yes, or the kind said so): two seats a
  -- side -- the cart's gPlayerParty behind battlers 0 and 2, the foes behind
  -- 1 and 3 -- except that a trainer with one monster fields one (pret's
  -- absent battler from the start).  Only a trainer's fight is a double on
  -- the carts unless a kind says otherwise.
  local double = ctx.double == true and (kind == "trainer" or ctx.hooks3 ~= nil)
  local foeSeats = int3(ctx.foeSeats, nil) or ((double and #enemySheets >= 2) and 2 or 1)
  ctx.double = double or nil
  ctx.screen = double and "double" or "single"
  -- Stated before the screen is built: the transport's moveset handling reads
  -- it, and so does every Gen 3 arm the pump reaches.
  self.generation = 3
  local fight
  -- The party as the fight found it, before the double screen -- which fights
  -- on the live party -- has touched a monster of it (M.snapshotParty3); put
  -- back on every way out that is not the fight's own ending.
  local partySnap = nil
  local function giveUp()
    self.generation = nil
    M.restoreParty3(partySnap)
    return false
  end
  if double then
    local session0 = Gen3.session()
    partySnap = M.snapshotParty3(session0 and session0.party)
    fight = self:_doubleScreen3(game, pending, {
      battle = battleId, mode = mode, trainer = trainer,
      enemySheets = enemySheets, foeSeats = foeSeats,
    }, ctx)
    if not fight then return giveUp() end
  else
    local screenOpts = {
      transport = self:_transport(pending),
      ui = self.ui,
      game = game,
      battle = battleId,
      role = "host",
      peerId = (kind ~= "wild") and FOE_SEAT or nil,
      peerName = (kind == "wild") and "WILD" or M.gen3FoeLabel(trainer),
      trainer = (kind ~= "wild") and trainer or nil,
      npcParty = (kind ~= "wild") and enemySheets or nil,
      mode = mode,
      wildParty = (kind == "wild") and enemySheets or nil,
      wildCatchMon = ctx.wildMon,
      -- The battle theme a script named (Emerald's legendary natives,
      -- Trainer Hill: `opts.song`), for the screen's music to play.
      song = ctx.song,
      onDone = function(result, toLearn) self:_ended(result, toLearn) end,
    }
    local okS, extraS = self:_hook3(ctx, "screen", screenOpts)
    if not okS and extraS == "error" then return giveUp() end
    merge3(screenOpts, extraS)
    fight = MediatedBattle.new(screenOpts)
  end
  ctx.fight = fight

  local started
  if double then
    -- The double screen is the newer code at this boundary; a throw out of
    -- its upload is a fight not taken, said once, rather than a raise into
    -- src/Client.lua's divert.
    local okS, value = pcall(fight.start, fight, game)
    if not okS then
      self:warn("double3start", "the mod's double-battle screen could not describe your party "
        .. "(%s), so this double battle is fought the ordinary way; report it with the "
        .. "trainer you met", tostring(value))
    end
    started = okS and value
  else
    started = fight:start(game)
  end
  local mine = pending.party
  local hasParty = type(mine) == "table" and type(mine.mons) == "table" and #mine.mons > 0
  if not (started and (hasParty or ctx.partyless)) then return giveUp() end
  mine = type(mine) == "table" and mine or {}

  local ruleset = pending.ruleset or {}
  local terrain, underwater = M.gen3Terrain(game)
  local player = Gen3.player()
  local foeName = (kind == "wild") and (enemySheets[1].species or "WILD")
    or M.gen3FoeLabel(trainer)
  local create = {
    id = battleId,
    mode = mode,
    seed = self:_seed(),
    typeTable = ruleset.typeTable,
    specialTypes = ruleset.specialTypes,
    movePool = ruleset.movePool,
    terrain = ruleset.terrain or terrain,
    -- The overworld's weather opens every fight the engine runs off the link
    -- (battle/init.lua `overworldWeather`, pret battle_util.c:1709), trainers
    -- included; the ruleset names one only for a wild fight (Sheet3.ruleset),
    -- so a trainer on a rainy route asks the field itself.
    weather = ruleset.weather or Sheet3.fieldWeather(),
    underwater = ruleset.underwater == true or underwater,
    choiceTimeout = Config.SOLO_CHOICE_TIMEOUT,
    reconnectGrace = Config.BATTLE_RECONNECT_GRACE,
    resolveTimeout = Config.BATTLE_RESOLVE_TIMEOUT,
    now = 0,
    -- The cart's own wild move (contract C3): a wild battle without an AI
    -- script picks `Random() & 3` until it lands on a move, never the
    -- trainer heuristic (pret battle_controller_opponent.c: the AI runs only
    -- for TRAINER | FIRST_BATTLE | SAFARI | ROAMER -- pokefirered :1355,
    -- pokeemerald :1563).  On every wild fight this file seats; a side
    -- entry's own `ai` (a roamer's, Birch's Zigzagoon's) is the referee's to
    -- prefer.  A trainer's seat never reads it.
    wildPick = (kind == "wild") and "cart" or nil,
    -- A double is one entry a side with `seats` on it (contract C1 of
    -- docs/plans/gen3-solo-doubles.md, the shared team of
    -- docs/plans/gen3-battle-sheet.md §1.3): the referee expands it into two
    -- seats over the one party and the one bag -- the trainer's four item
    -- slots are spent from a single kit whichever of its monsters reaches
    -- for them, as on the cart.  A single leaves `seats` unset, which is the
    -- one-seat entry the referee always had.
    sides = {
      a = { {
        playerId = PLAYER_SEAT,
        seats = double and 2 or nil,
        name = (player and player.name ~= nil and player.name ~= "") and player.name or "PLAYER",
        mons = mine.mons,
        bag = mine.bag,
        -- The badges this save holds (Gen3.badgeList, contract K1 of
        -- docs/plans/gen3-badge-rules.md): BattleSim3 applies the cart's badge
        -- boosts and obedience from them on side a of a wild / trainer fight,
        -- as the engine's own battle does (battle/engine.lua Engine.hasBadge).
        -- One entry for a single and for both seats of a lone double -- the
        -- referee hands the entry's badges to each seat it expands, the
        -- cart's one gSaveBlock behind battlers 0 and 2.  Read from the save
        -- here rather than taken off `mine.badges` (the screen's upload, the
        -- same list today), so the entry never depends on what either screen
        -- chose to send.
        badges = Gen3.badgeList(),
        -- Which cart's obedience rule the referee plays (its `family`):
        -- FireRed / LeafGreen exempt FOCUS PUNCH from the ignored-orders
        -- branch, Emerald does not (the engine's battle profile rule
        -- obedienceFocusPunchExempt, battle/profile.lua:34 and
        -- profiles/emerald/battle.lua:39).
        family = Gen3.family(),
      } },
      b = { {
        playerId = FOE_SEAT,
        seats = double and foeSeats or nil,
        name = foeName,
        mons = enemySheets,
        -- The trainer's four item slots as the referee's bag (§4 ids only):
        -- the same claim MediatedBattle uploaded as side b, by the numbers.
        bag = (kind ~= "wild") and pending.wild and pending.wild.bag or nil,
      } },
    },
  }
  -- The kind's create options (contract C3) and its extra side entries.
  local okC, extraC, sidesC = self:_hook3(ctx, "seat", create)
  if not okC and extraC == "error" then
    fight.onDone = nil
    return giveUp()
  end
  if type(extraC) == "table" then
    for k, v in pairs(extraC) do
      if k ~= "sides" then create[k] = v end
    end
  end
  if type(sidesC) == "table" then
    for _, side in ipairs({ "a", "b" }) do
      for _, entry in ipairs(type(sidesC[side]) == "table" and sidesC[side] or {}) do
        local list = create.sides[side]
        list[#list + 1] = entry
      end
    end
  end
  ctx.create = create
  local sim, why = Turn.create(create)
  if not sim then
    fight.onDone = nil
    giveUp()
    self:warn("nosim", "the mod's battle system could not assemble this fight (%s), so "
      .. "it is fought the ordinary way; report this with the battle you were in",
      tostring(why))
    return false
  end

  -- Who answers the computer's seats (contract C4): the trainer's own
  -- SoloBrain on the trainer's, the referee's own picker (`wildPick` / the
  -- entry's `ai`) on a wild one; the kind may add or replace any owner's.
  local npcs = {}
  if kind == "trainer" then
    npcs[FOE_SEAT] = SoloBrain.new({ game = game, generation = 3, trainer = trainer }) or "referee"
  else
    npcs[FOE_SEAT] = "referee"
  end
  ctx.sim = sim
  local okB, extraB = self:_hook3(ctx, "brains", npcs)
  if not okB and extraB == "error" then
    fight.onDone = nil
    return giveUp()
  end
  merge3(npcs, extraB)
  local brain = type(npcs[FOE_SEAT]) == "table" and npcs[FOE_SEAT] or nil

  local session = Gen3.session()
  self.fight, self.sim, self.brain = fight, sim, brain
  self.engine, self.game, self.kind = nil, game, kind
  self.generation = 3
  self.wildMon = ctx.wildMon
  self.mapId = opts.mapId
  self.settled, self.reason = false, nil
  self.refuseRun, self.failedRun, self.cantEscape = nil, nil, nil
  self.runAttempts, self.faults = 0, 0
  self.clock, self.seq = 0, 0
  self.warned = nil
  self.save = session
  self.levels = nil
  -- The fight's state is its ctx (contract C2), with what the core keeps:
  ctx.npcs = npcs
  ctx.session = session
  ctx.levels = M.levels3(session and session.party)
  ctx.verdict, ctx.whiteout, ctx.healAfter = nil, false, false
  ctx.amuletPlayer, ctx.amuletFoe = false, false
  -- The side the referee's `run` event named, when one did (M.gen3Words).
  ctx.ranSide = nil
  -- pret gBattleResults, as far as the ending reads it (the TV, M:_note3).
  ctx.results = { catchAttempts = {}, usedMasterBall = false, lastUsedItem = 0 }
  -- A double: `foeSeats` trainer seats.  The ending reads `double` for the
  -- prize and the TV; M:_note3 keeps `foeOut` (the party index out on each
  -- foe slot) and `lastFoeFainted` from it.
  ctx.foeSeats = double and foeSeats or nil
  ctx.foeOut = double and {} or nil
  -- The party as the fight found it (a double only; M:_reset3 restores it).
  ctx.partySnap = partySnap
  self.gen3 = ctx

  -- Claimed only once it is on screen.  A layer the modal stack refused would
  -- leave a referee running a fight nobody can see or answer; the caller is
  -- told no instead, and fights the cart's own battle.
  local pushed = nil
  if self.ui and type(self.ui.pushState) == "function" then
    local okP, layer = pcall(self.ui.pushState, self.ui, game, fight)
    pushed = okP and layer or nil
  end
  if not pushed then
    fight.onDone = nil
    self:_clear3()
    M.restoreParty3(partySnap)
    self:warn("push3", "the mod's battle screen could not be opened over the field, so "
      .. "this fight is fought the ordinary way; if it keeps happening, turn SOLO "
      .. "BATTLES off in the mod manager (F10) and report it")
    return false
  end
  -- The seats, as the referee named them, side by side in slot order: one a
  -- side for a single; both of each shared team in a lone double
  -- (solo_player, solo_player#2; solo_foe and, for a trainer with two
  -- monsters or more, solo_foe#2); and whatever entries a kind added.
  -- The screen's own mode, whatever the referee was seated as (a Safari
  -- referee's mode is its own; the screen stays a wild one).
  fight:onReady({
    battle = battleId,
    mode = mode,
    sides = { a = M.sideIds3(sim, "a", PLAYER_SEAT), b = M.sideIds3(sim, "b", FOE_SEAT) },
  })
  self:_pump()
  return true
end

-- The screen of a double: CoopBattle's solo double (contract C3 of
-- docs/plans/gen3-solo-doubles.md) -- two monsters a side, a command menu per
-- monster, targets, a replacement per seat -- behind the same narrow surface
-- MediatedBattle serves a single (`start`, `onReady`, `onEvent`, `onOutcome`,
-- `say`, `onDone`, `evoResolved`, `battle`), over the same table transport,
-- plus the two M:_backstop3 reads (`waitingOnReferee`, `reopenOwed`) and the
-- transport's `refusal` line it reads back (`_transport`).  The kind's
-- `screen` hook sees its options first (`ctx`).
-- Reached for here rather than at load: CoopBattle is the co-op screen, and
-- every other fight this file runs never needs it.  nil when it cannot be
-- built, said once; the caller hands the fight back.
function M:_doubleScreen3(game, pending, args, ctx)
  local okC, CoopBattle = pcall(need, "CoopBattle")
  if not (okC and type(CoopBattle) == "table" and type(CoopBattle.newSoloDouble) == "function") then
    self:warn("double3load", "the mod's double-battle screen could not be loaded, so this "
      .. "double battle is fought the ordinary way; reinstall the mod folder so every "
      .. "file under src/ is present")
    return nil
  end
  local trainer = args.trainer
  local screenOpts = {
    transport = self:_transport(pending),
    ui = self.ui,
    battle = args.battle,
    trainer = trainer,
    -- "TWINS ELI & ANNE would like to battle!", as the single says it.
    peerName = M.gen3FoeLabel(trainer),
    npcParty = args.enemySheets,
    mode = args.mode,
    selfId = PLAYER_SEAT,
    foeId = FOE_SEAT,
    foeSeats = args.foeSeats,
    song = ctx and ctx.song or nil,
    onDone = function(result, toLearn) self:_ended(result, toLearn) end,
  }
  if ctx then
    local okH, extra = self:_hook3(ctx, "screen", screenOpts)
    if not okH and extra == "error" then return nil end
    merge3(screenOpts, extra)
  end
  local ok, fight = pcall(CoopBattle.newSoloDouble, game, screenOpts)
  if not (ok and type(fight) == "table" and type(fight.start) == "function") then
    self:warn("double3open", "the mod's double-battle screen could not be opened (%s), so "
      .. "this double battle is fought the ordinary way; report it with the trainer "
      .. "you met", tostring(ok and "no screen" or fight))
    return nil
  end
  return fight
end

-- A party's seat ids in slot order, from the referee itself (`seatsOf`):
-- the owner's own id first, then `<id>#2` for a shared team's second seat.
function M.seatIds3(sim, ownerId)
  local out = {}
  local ok, seats = pcall(sim.seatsOf, sim, ownerId)
  for _, seat in ipairs(ok and type(seats) == "table" and seats or {}) do
    out[#out + 1] = seat.playerId
  end
  if #out == 0 then out[1] = ownerId end
  return out
end

-- Every seat id on one side of the referee, in slot order -- every owner's
-- (a second trainer's, Steven's), each shared team's two -- from its own
-- `bySide`; `fallback` alone when it has none.
function M.sideIds3(sim, side, fallback)
  local out = {}
  local bucket = type(sim) == "table" and type(sim.bySide) == "table" and sim.bySide[side] or nil
  for _, fighter in ipairs(type(bucket) == "table" and bucket or {}) do
    if type(fighter) == "table" and fighter.playerId then out[#out + 1] = fighter.playerId end
  end
  if #out == 0 then out[1] = fallback end
  return out
end

-- The fighter standing on a field slot (the referee's own `_fighterAtSlot`,
-- restated over its public `fighters`).
local function fighterAt3(sim, slot)
  slot = int3(slot, nil)
  if not (slot and type(sim) == "table") then return nil end
  for _, fighter in ipairs(sim.fighters or {}) do
    if fighter.slot == slot then return fighter end
  end
  return nil
end

-- ------------------------------------------------------------------
-- small Gen 3 pieces the shared pump calls
-- ------------------------------------------------------------------

-- The player seat a Gen 3 choice is filed into.  A lone double's screen
-- (CoopBattle's solo double, contract C3 of docs/plans/gen3-solo-doubles.md)
-- says which monster it is choosing for by its field slot, `seat` -- side a's
-- 0 or 1 -- and the referee takes a choice by the seat's own id (PLAYER_SEAT,
-- PLAYER_SEAT .. "#2"), so the slot is looked up among our seats rather than
-- spelled: whatever the referee named the seat on that slot is the answer.
-- An absent `seat` is the first.  Every other Gen 3 fight has one seat, and
-- a `seat` there is not read.  nil for a slot none of our seats stands on.
function M:_seat3(payload)
  local g3, sim = self.gen3, self.sim
  if not (g3 and g3.double) then return PLAYER_SEAT end
  local slot = int3(payload.seat, 0)
  for _, seat in ipairs(sim and sim:seatsOf(PLAYER_SEAT) or {}) do
    if seat.slot == slot then return seat.playerId end
  end
  return nil
end

-- How long a lone double's screen may sit waiting on the referee while the
-- referee waits on one of our seats, in seconds of pump time, before
-- M:_backstop3 steps in.  A real fight never comes near it: the two agree
-- within the frame the events are drained in.
local OWED_BACKSTOP3 = 3

-- The backstop for a seat the screen never asks.
--
-- Nothing else would end that wait.  A solo fight has no choice clock
-- (`SOLO_CHOICE_TIMEOUT` is 0), a trainer's RUN is refused, and M:_pump's
-- stall count only catches a referee stuck part way through a turn -- so if
-- the double's screen and the referee ever disagree about who owes (a
-- replacement `send` it could not map leaving a seat looking fainted, a
-- solicitation it let go of), the fight sits behind an empty wait box for
-- good.  So: the referee owes a choice from one of our seats, the screen says
-- it has nothing to show and nothing to ask (`waitingOnReferee`), and that has
-- held for OWED_BACKSTOP3 seconds.  The screen is asked to put that seat's
-- question back up first (`reopenOwed` -- its menu, or its replacement
-- picker), once per seat per window; if it cannot, or it is the same seat in
-- the same window again, the referee answers for it (`autoPick`, the picker
-- every timed-out seat of a hub fight gets).  Either is a disagreement worth
-- reporting, and says so.
function M:_backstop3()
  local sim, fight, g3 = self.sim, self.fight, self.gen3
  local seat = nil
  if not sim.result and (sim.phase == "choice" or sim.phase == "replace")
     and type(fight.waitingOnReferee) == "function" and try3(fight.waitingOnReferee, fight) then
    local okS, seats = pcall(sim.seatsOf, sim, PLAYER_SEAT)
    for _, s in ipairs(okS and type(seats) == "table" and seats or {}) do
      if owes(sim, s) then seat = s; break end
    end
  end
  if not seat then
    g3.owedSince = nil
    return false
  end
  g3.owedSince = g3.owedSince or self.clock
  if self.clock - g3.owedSince < OWED_BACKSTOP3 then return false end
  g3.owedSince = nil
  local window = ("%s:%s:%s"):format(tostring(sim.phase), tostring(sim.turn), tostring(seat.playerId))
  if g3.reopened ~= window and type(fight.reopenOwed) == "function" then
    g3.reopened = window
    if try3(fight.reopenOwed, fight, seat.slot, seat.mustReplace == true) then
      self:warn("reopen3", "the double battle screen stopped asking for one of your POKéMON's "
        .. "choices while the referee waited on it, so it was asked again; if it keeps "
        .. "happening, report it with the trainer you were fighting")
      return true
    end
  end
  local filed = try3(sim.autoPick, sim, seat.playerId) == true
  self:warn("autopick3", "the double battle screen could not ask for one of your POKéMON's "
    .. "choices, so the referee chose for it to keep the fight going; if it keeps "
    .. "happening, turn SOLO BATTLES off in the mod manager (F10) and report it with "
    .. "the trainer you were fighting")
  return filed
end

-- Who answers a seat (contract C4): its owner's entry in the fight's `npcs`
-- (M:_begin3's default, the kind's `brains`), else the referee for any
-- owner but the player -- a computer seat nobody named is never left
-- unanswered -- and nobody for the player's own seats (the screen's).  nil:
-- not this loop's seat.
function M:_answerer3(seat)
  local npcs = self.gen3 and self.gen3.npcs or {}
  local answer = npcs[seat.owner or seat.playerId]
  if answer == false then return nil end
  if answer ~= nil then return answer end
  if (seat.owner or seat.playerId) == PLAYER_SEAT then return nil end
  return "referee"
end

-- Every computer seat that owes the referee an answer -- a command for the
-- turn, or a monster for an emptied seat -- on either side, in pret's
-- battler order (the referee's own `order`: a1 b1 a2 b2, the cart's battlers
-- 0..3, each choosing in turn), each asked of its OWNER's answerer
-- (M:_answerer3): a trainer's one SoloBrain for both seats of its shared
-- team, because the item budget is the trainer's and not a monster's (the
-- brain facts of docs/plans/gen3-solo-doubles.md); a second trainer's own,
-- Steven's own on side a; the referee's picker (`Turn:autoPick`, which plays
-- the create's `wildPick` and a side entry's `ai`) for a wild seat.  A
-- brain's answer goes through `submitChoice` (its index vocabulary, see
-- M:_answerFoe); one it declines or the referee refuses falls to
-- `autoPick`, seat by seat; a brain that answers `false` is waiting for its
-- moment (a tutorial's scripted beat) and is asked again next frame.  A
-- seat neither can answer is left for the next frame without holding the
-- others up.  Looped, because filing the last answer can resolve the turn
-- and open the next one, where a seat owes again (Hub:fillNpcChoices).
function M:_answerNpcs3()
  local sim, g3 = self.sim, self.gen3
  if not (sim and g3) then return false end
  local seats = {}
  for _, fighter in ipairs(type(sim.order) == "table" and sim.order or {}) do
    if self:_answerer3(fighter) ~= nil then seats[#seats + 1] = fighter end
  end
  if #seats == 0 then return false end
  local bound = (tonumber(Config.BATTLE_MON_MAX) or 6)
    * math.max(1, tonumber(Config.COOP_FIGHTERS) or 1) * #seats
  local filed, stuck = false, {}
  for _ = 1, bound do
    -- A seat that could not be answered is skipped for the rest of this
    -- phase of this turn only; a turn the loop opens asks it afresh.
    local stamp = tostring(sim.phase) .. ":" .. tostring(sim.turn)
    local seat = nil
    for _, s in ipairs(seats) do
      if stuck[s] ~= stamp and owes(sim, s) then seat = s; break end
    end
    if not seat then break end

    local answer = self:_answerer3(seat)
    local got, waiting = false, false
    if answer ~= "referee" then
      local ok, choice = true, nil
      if type(answer) == "function" then
        ok, choice = pcall(answer, self:_npcView3(seat), seat)
      elseif type(answer) == "table" and type(answer.choose) == "function" then
        ok, choice = pcall(answer.choose, answer, self:_npcView3(seat))
      end
      if not ok then
        self:warn("brain", "the trainer's own AI could not be asked for a move "
          .. "(%s), so the referee's own trainer AI answers for it instead; "
          .. "report this with the trainer you were fighting", tostring(choice))
      elseif choice == false then
        waiting = true
      elseif type(choice) == "table" and sim:submitChoice(seat.playerId, choice) then
        got = true
      end
    end
    if not got and not waiting then
      got = sim:autoPick(seat.playerId) and true or false
    end
    if got then filed = true else stuck[seat] = stamp end
  end
  return filed
end
-- The name the lone double's loop was written under.
M._answerFoes3 = M._answerNpcs3

-- What a brain is shown for one computer seat, on either side.
--
-- A single (one seat a side) is the view a Gen 3 trainer has always had:
-- its monster (a fainted seat's last one stands in for the send-out
-- question), its party and bag, the monster across the field (`foe`), the
-- referee and both battlers.  A double adds contract C2 of
-- docs/plans/gen3-solo-doubles.md, read off the referee's sides rather than
-- off two owners, so a second trainer and a side-a ally get it too:
--
--   double     true
--   side       "a" | "b", the seat's own side (a brain may sit on either)
--   seat       the choosing seat's field slot
--   partner    the other battler standing on the seat's side -- the shared
--              team's sibling, the other trainer's, Steven's, the player's
--              -- else nil; partnerSlot its field slot
--   foes       the other side's standing battlers, { slot, battler }, by slot
--              (both of the player's and Steven's, against a foe brain)
--   claimed    party indices (1-based: the referee's own, once it normalised
--              the sibling's choice) a sibling seat OF THE SAME PARTY has
--              filed a switch or a replacement into this turn -- the party
--              menu's "already selected" (pret monToSwitchIntoId).  Another
--              trainer's switch is into another party, and claims nothing
--              here (pret's halves: battle_ai_switch_items.c reads its own
--              flank's party only).
--
-- `foe` / `foeBattler` are the first of `foes`, for whatever part of the
-- brain reads one.
function M:_npcView3(seat)
  local sim = self.sim
  local side = seat.side == "a" and "a" or "b"
  local other = side == "a" and "b" or "a"
  local bySide = type(sim.bySide) == "table" and sim.bySide or {}
  if not sim.double then
    local opp = (bySide[other] or {})[1]
    local view = {
      mon = seat.active and seat.mons[seat.active] or nil,
      foe = opp and opp.mons and opp.active and opp.mons[opp.active] or nil,
      party = seat.mons,
      active = seat.active,
      bag = seat.bag,
      mustReplace = seat.mustReplace and true or false,
      sim = sim,
      battler = seat.b,
      foeBattler = opp and opp.b or nil,
      fighter = seat,
      side = side,
    }
    if view.mon == nil and seat.lastB then view.mon = seat.lastB.mon end
    return view
  end
  local foes = {}
  for _, p in ipairs(bySide[other] or {}) do
    if p.b and activeOf(p) then foes[#foes + 1] = { slot = p.slot, battler = p.b } end
  end
  local partner, partnerSlot = nil, nil
  for _, s in ipairs(bySide[side] or {}) do
    if s ~= seat and s.b and activeOf(s) and not partner then partner, partnerSlot = s.b, s.slot end
  end
  local claimed = {}
  for _, s in ipairs(type(seat.seats) == "table" and seat.seats or {}) do
    if s ~= seat then
      local c = s.choice
      if type(c) == "table" and c.action == "switch" and tonumber(c.slot) then
        claimed[tonumber(c.slot)] = true
      end
    end
  end
  local lead = foes[1]
  local view = {
    mon = seat.active and seat.mons[seat.active] or nil,
    foe = lead and lead.battler.mon or nil,
    party = seat.mons,
    active = seat.active,
    bag = seat.bag,
    mustReplace = seat.mustReplace and true or false,
    sim = sim,
    battler = seat.b,
    foeBattler = lead and lead.battler or nil,
    fighter = seat,
    double = true,
    side = side,
    seat = seat.slot,
    partner = partner,
    partnerSlot = partnerSlot,
    foes = foes,
    claimed = claimed,
  }
  if view.mon == nil and seat.lastB then view.mon = seat.lastB.mon end
  return view
end
-- The name the lone double's view was written under (a seat's own party
-- stands in for the `seats` it was handed).
function M:_foeView3(seat) return self:_npcView3(seat) end

-- A `send`: the dex's "seen" for a foe (the engine monster the sheet was cut
-- from carries the personality Unown / Spinda record), and an Amulet Coin on
-- whoever just came out.  Either seat of a double: a shared team's two seats
-- hold the one `mons` table, so the party index finds the monster from the
-- first seat whichever slot it came out on -- and the cart's Amulet Coin
-- (gBattleStruct->moneyMultiplier, set as its holder is sent in) does not ask
-- which battler position it was either.  The fighter is the one standing on
-- the event's slot, so a second trainer's monster is read from its own party
-- (and its engine monster from ctx.parties[owner]); a kind that says the
-- fight marks no dex "seen" (ctx.noDexSeen: FRLG's legendaries and veiled
-- ghosts, pret battle_main.c:2618; the Frontier) is not marked.
function M:_onSend3(event)
  local g3, sim = self.gen3, self.sim
  if not (g3 and sim and sim.byId) then return end
  local foeSide = event.side == "b"
  local fighter = fighterAt3(sim, event.slot)
  if not (fighter and fighter.side == event.side) then
    fighter = sim.byId[foeSide and FOE_SEAT or PLAYER_SEAT]
  end
  local index = int3(event.mon, nil)
  local mon = fighter and index and fighter.mons and fighter.mons[index + 1] or nil
  if foeSide then
    local species = int3(event.speciesId, nil) or int3(mon and mon.speciesNum, nil)
    local owner = fighter and fighter.owner or FOE_SEAT
    local party = (type(g3.parties) == "table" and g3.parties[owner])
      or (owner == FOE_SEAT and g3.party) or nil
    local src = mon and type(party) == "table" and party[int3(mon.slot, index or 0) + 1] or nil
    if species and not g3.noDexSeen then
      pcall(Gen3.dexMark, species, true, false, src and src.personality)
    end
    -- Who is out on each foe slot (and whose it is), for the double's
    -- last-fainted foe.
    local slot = int3(event.slot, nil)
    if g3.foeOut and slot and mon then
      g3.foeOut[slot] = mon
      g3.foeOwner = g3.foeOwner or {}
      g3.foeOwner[slot] = owner
    end
  end
  if mon and int3(mon.heldItem, 0) ~= 0 and int3(mon.holdEffect, 0) == HOLD_DOUBLE_PRIZE then
    if foeSide then g3.amuletFoe = true else g3.amuletPlayer = true end
  end
end

-- pret ITEM_MASTER_BALL: gBattleResults keeps it apart from the rest.
local ITEM_MASTER_BALL = 1
-- pret ITEM_SAFARI_BALL: counted nowhere.
local ITEM_SAFARI_BALL = 5

-- Every Gen 3 event on its way to the screen: a `send` (M:_onSend3); a `run`,
-- whose side is who left (M.gen3Words' fallback); and our side's `ball`,
-- counted the way Cmd_handleballthrow keeps gBattleResults (the engine's
-- Catching.tryCatch: the last ball, a MASTER BALL flag, a per-ball count
-- indexed ball id - 1, capped at 255) for the ending's TV report -- except a
-- SAFARI BALL, which pret counts nowhere (pokeemerald
-- battle_script_commands.c Cmd_handleballthrow: `if (gLastUsedItem !=
-- ITEM_SAFARI_BALL)` around the whole count).  Then the kind's own `note`.
function M:_note3(event)
  local g3 = self.gen3
  local t = event.t
  if t == "send" then
    self:_onSend3(event)
  elseif not g3 then
    return
  elseif t == "faint" and event.side == "b" and g3.foeOut then
    -- A double's gBattleResults.lastOpponentSpecies: the foe's monster that
    -- fainted last, whichever slot it stood on (pret Cmd_tryfaintmon writes
    -- it from gBattlerPartyIndexes of the fainting battler).  A single's
    -- ending reads the one foe slot's monster instead, as before.
    local slot = int3(event.slot, -1)
    local mon = g3.foeOut[slot]
    if mon then
      g3.lastFoeFainted = mon
      g3.lastFoeFaintedOwner = g3.foeOwner and g3.foeOwner[slot] or FOE_SEAT
    end
  elseif t == "run" and (event.side == "a" or event.side == "b") then
    g3.ranSide = event.side
  elseif t == "ball" and event.side == "a" then
    local ball = int3(event.text, nil)
    if ball and ball >= 1 then
      local r = g3.results
      r.lastUsedItem = ball
      if ball == ITEM_MASTER_BALL then
        r.usedMasterBall = true
      elseif ball ~= ITEM_SAFARI_BALL and int3(r.catchAttempts[ball - 1], 0) < 255 then
        r.catchAttempts[ball - 1] = int3(r.catchAttempts[ball - 1], 0) + 1
      end
    end
  end
  if self.gen3 then self:_hook3(self.gen3, "note", event) end
end

-- A mid-fight learn, onto the referee's copy (the hub's applyBattleMoveset3,
-- src/Hub.lua): one slot added or one id changed; an unchanged id keeps the
-- referee's PP and combat fields; the active battler takes the new list only
-- when it is not wearing a Transform / Mimic overlay.
local function movesetDeltaOk(old, incoming)
  local prevLen = type(old) == "table" and #old or 0
  local nextLen = #incoming
  if nextLen == prevLen then
    local changed = 0
    for i = 1, nextLen do
      local prev = old[i]
      if not (prev and prev.id == incoming[i].id) then changed = changed + 1 end
    end
    return changed <= 1
  end
  if nextLen == prevLen + 1 then
    for i = 1, prevLen do
      local prev = old[i]
      if not (prev and prev.id == incoming[i].id) then return false end
    end
    return true
  end
  return false
end

-- Red and Gold's: the hub's own learn (src/Hub.lua `learnTo`, exported for
-- exactly this caller so a solo fight and a hub fight land a learn in the same
-- place by the same two rules, `movesetDeltaOk` / `nextMoves12`), then the
-- referee's level-up (contract K9 of docs/plans/gen12-referee-gaps-fix.md,
-- `sim:levelUp(playerId, monIndex1, level, stats, maxHp)` -- the call both
-- hubs make after the moves).  The payload is read through the wire's own
-- reader first, as a hub reads it, so the referee is never handed a field a
-- hub would have refused.  Before K9 this path dropped the message whole: a
-- solo Red or Gold fight never heard of a move learned mid-fight, nor of a
-- level.
--
-- A transformed battler learns where the cart's LearnMove writes: into the
-- party list its referee put aside at Transform (`preTransform.moves`, which
-- a switch-out or a faint gives back), and on Red into the battle list as
-- well -- pokered LearnMove (engine/pokemon/learn_move.asm, the
-- `wPlayerMonNumber` check) copies the party's moves and PP over
-- wBattleMonMoves / wBattleMonPP whatever the substatus, while pokecrystal
-- LearnMove (engine/pokemon/learn.asm) skips that copy under
-- SUBSTATUS_TRANSFORMED, so on Gold the copied moves fight on.  `learnTo` has
-- the rule; until wave 3 this path kept a transformed battler's list whole
-- and the learn was lost at the switch-out.  The level-up lands either way,
-- as on the hub -- the monster grew whatever it is wearing.  Answers whether
-- anything reached the referee.
function M:_applyMoveset12(payload)
  local sim = self.sim
  local fighter = sim and sim.byId and sim.byId[PLAYER_SEAT]
  if not (fighter and type(fighter.mons) == "table") then return false end
  local clean = Wire.battleMoveset(payload, self.generation)
  if not clean then return false end
  local mon = fighter.mons[clean.mon + 1]
  if type(mon) ~= "table" then return false end
  local Hub = need("Hub")
  local applied = Hub.learnTo(self.generation, mon, clean.moves)
  local grew = clean.level ~= nil or clean.stats ~= nil or clean.maxHp ~= nil
  if grew and type(sim.levelUp) == "function" then
    local ok, err = pcall(sim.levelUp, sim, PLAYER_SEAT, clean.mon + 1,
      clean.level, clean.stats, clean.maxHp)
    if ok then
      applied = true
    else
      self:warn("levelup", "a level gained in this battle could not reach the "
        .. "battle referee (%s), so it fights on its old stats until the "
        .. "battle ends -- the level itself is kept; report this with the "
        .. "monster that levelled", tostring(err))
    end
  end
  return applied
end

function M:_applyMoveset3(payload)
  local sim = self.sim
  local fighter = sim and sim.byId and sim.byId[PLAYER_SEAT]
  if not (fighter and type(payload) == "table") then return false end
  local raw = {}
  for key, value in pairs(payload) do raw[key] = value end
  raw.battle = raw.battle or sim.id
  payload = Wire.battleMoveset(raw, 3)
  if not payload then return false end
  local index = int3(payload.mon, nil)
  local mon = index and fighter.mons and fighter.mons[index + 1]
  if not mon then return false end
  local incoming = payload.moves
  if type(incoming) ~= "table" or #incoming == 0 then return false end
  local old = type(mon.moves) == "table" and mon.moves or {}
  if not movesetDeltaOk(old, incoming) then return false end
  local Turn = turnFor(3)
  local nextMoves = {}
  for i, nm in ipairs(incoming) do
    local prev = old[i]
    if prev and prev.id == nm.id then
      nextMoves[i] = prev
    else
      nextMoves[i] = Turn.copyMove(nm)
    end
  end
  mon.moves = nextMoves
  -- Whichever seat has it out: a double's two seats share the party, so the
  -- monster that learned may be standing on either (`seatsOf`; a single is
  -- its one seat).
  local okS, seats = pcall(sim.seatsOf, sim, PLAYER_SEAT)
  if not (okS and type(seats) == "table" and #seats > 0) then seats = { fighter } end
  for _, seat in ipairs(seats) do
    local b = seat.b
    if b ~= nil and b.mon == mon and not b.overlay then b.moves = nextMoves end
  end
  if payload.level ~= nil and type(sim.levelUp) == "function" then
    sim:levelUp(PLAYER_SEAT, index + 1, payload.level, payload.stats, payload.maxHp)
  end
  return true
end

-- The line a trapped RUN prints: the ability that holds the runner when one
-- does (pret STRINGID_PREVENTSESCAPE), else STRINGID_CANTESCAPE's.
function M:_cantEscapeText3(seat)
  local sim = self.sim
  local player = sim and sim.byId and sim.byId[seat or PLAYER_SEAT]
  local b = player and player.b
  if b then
    local okA, Abilities = pcall(need, "BattleSim3/Abilities")
    if okA and type(Abilities) == "table" and type(Abilities.escapeBlocker) == "function" then
      local ok, foe, ability = pcall(Abilities.escapeBlocker, sim, b)
      if ok and foe and ability then
        local who = sim:nameOf(foe)
        if self.kind == "wild" then who = "Wild " .. who end
        return ("%s prevents\nescape with %s!"):format(who, sim:abilityLabel(foe))
      end
    end
  end
  return "Can't escape!"
end

-- ------------------------------------------------------------------
-- a refused command, in the cart's words (the lone double's and the single's)
-- ------------------------------------------------------------------

-- The party member a choice's `slot` names (the referee's own partyIndexOf:
-- the sheet carrying that party position, else the position counted off).
local function partyIndex3(fighter, wireSlot)
  for i, mon in ipairs(fighter.mons or {}) do
    if int3(mon.slot, -1) == wireSlot then return i end
  end
  return wireSlot + 1
end

-- The cart's "Foe " in front of a trainer's monster's name (sText_FoePkmnPrefix),
-- out of the player's own text pack.
local function foePrefix3()
  local RomText = Gen3.engine("src.core.game3.rom_text")
  local prefix = RomText and try3(RomText.plain, "sText_FoePkmnPrefix") or nil
  return type(prefix) == "string" and prefix or "Foe "
end

-- Why the referee turned player seat `seatId`'s command down, in the line the
-- cart prints for the same refusal at the same point -- it checks each
-- battler's action as it is chosen and keeps that battler's menu up -- or nil
-- when the referee's reason is not one the cart has a line for (a menu that
-- should never have offered it).  Read off the referee's own state, in the
-- order Turn.lua `_normaliseChoice` refuses in:
--
--   * a move: the limitations pret's TrySetCantSelectMoveBattleScript checks
--     (battle_util.c:302; the engine's commands.lua selectionError) --
--     Disabled, Tormented, Taunted, sealed by Imprison, not the Choice Band's
--     move, no PP -- the last that applies being the one said, as there;
--   * an item: a medicine that would do nothing (the referee's own
--     `_itemHasEffect`; party_menu.c gText_WontHaveEffect, the engine's
--     items.lua);
--   * a switch: a trapped monster (party_menu.c:5964 gText_PkmnCantSwitchOut)
--     or one a foe's ability holds (pokemon.c:6029
--     gText_PkmnsXPreventsSwitching; the engine's Engine.canSwitch).
--
-- Each line is the player's own text pack's (Gen3.battleText), else this
-- file's spelling of it.  Pure over the referee: the double screen's suite asks
-- it from its own table transport.
function M.refusalText3(sim, seatId, choice)
  local fighter = type(sim) == "table" and type(sim.byId) == "table" and sim.byId[seatId] or nil
  local b = fighter and fighter.b
  if not (b and b.mon and type(choice) == "table") then return nil end
  local okI, Items = pcall(need, "BattleSim3/Items")
  if not (okI and type(Items) == "table") then return nil end
  local name = sim:nameOf(b)
  local active = { side = "player", name = name }

  if choice.action == "fight" then
    local index = int3(choice.move, nil)
    local mv = index and type(b.moves) == "table" and b.moves[index + 1] or nil
    if type(mv) ~= "table" then return nil end
    local okL, bad = pcall(sim.moveLimitations, sim, b)
    if not (okL and type(bad) == "table" and bad[index + 1]) then return nil end
    local num, label = int3(mv.num, 0), sim:moveLabel(mv)
    local fill = { active = active, currentMove = num > 0 and num or label, trainer = true }
    local key, line
    if b.disabledNum and num == b.disabledNum then
      key, line = "STRINGID_PKMNMOVEISDISABLED", ("%s's %s\nis disabled!"):format(name, label)
    end
    if b.tormented and num == b.lastMoveNum then
      key, line = "STRINGID_PKMNCANTUSEMOVETORMENT",
        ("%s can't use the same\nmove in a row due to the TORMENT!"):format(name)
    end
    if int3(b.tauntTurns, 0) > 0 and int3(mv.power, 0) == 0 then
      key, line = "STRINGID_PKMNCANTUSEMOVETAUNT", ("%s can't use\n%s after the taunt!"):format(name, label)
    end
    if try3(sim.isImprisoned, sim, b, num) then
      key, line = "STRINGID_PKMNCANTUSEMOVESEALED", ("%s can't use the\nsealed %s!"):format(name, label)
    end
    local band = b.choicedMove
    if band and band ~= num and try3(Items.of, b) == (Items.HOLD and Items.HOLD.CHOICE_BAND) then
      local item = int3(b.mon.heldItem, 0)
      fill = { active = active, lastItem = item > 0 and item or sim:itemLabel(b),
               currentMove = band, trainer = true }
      key, line = "STRINGID_ITEMALLOWSONLYYMOVE",
        ("%s allows the\nuse of only %s!"):format(sim:itemLabel(b), sim:moveLabelByNum(band))
    end
    if int3(mv.pp, 0) <= 0 then
      key, line, fill = "STRINGID_NOPPLEFT", "There's no PP left for\nthis move!", {}
    end
    if not key then return nil end
    return Gen3.battleText(key, fill) or line
  end

  if choice.action == "item" then
    local item = try3(Items.idOf, choice.item)
    local effect = item and try3(Items.bagEffect, item) or nil
    if not effect or effect.ball or effect.escape or effect.flute then return nil end
    -- Out of the bag for this seat (the other has filed the last one): the
    -- screen's bag does not list it, so there is no line of the cart's for it.
    if fighter.bag and try3(sim._bagHas, sim, fighter, item) == false then return nil end
    local index = fighter.active
    local slot = int3(choice.slot, nil)
    if slot ~= nil then index = partyIndex3(fighter, slot) end
    if not (index and fighter.mons[index]) then return nil end
    if effect.activeOnly and index ~= fighter.active then return nil end
    local moveIndex = int3(choice.move, nil)
    if moveIndex then moveIndex = moveIndex + 1 elseif effect.needsMove then return nil end
    if try3(sim._itemHasEffect, sim, fighter, effect, index, moveIndex) ~= false then return nil end
    return Gen3.battleText("gText_WontHaveEffect", {}) or "It won't have\nany effect."
  end

  if choice.action == "switch" and not fighter.mustReplace then
    -- pret battle_main.c:4241: wrapped, escape-prevented, rooted -- or the
    -- Battle Arena, where nobody switches -- all open the party menu as
    -- PARTY_ACTION_CANT_SWITCH, and its line is the one (party_menu.c
    -- gText_PkmnCantSwitchOut).
    local arena = type(sim.rules) == "table" and sim.rules.arena == true
    if arena or try3(sim.isTrapped, sim, b) then
      return Gen3.battleText("gText_PkmnCantSwitchOut", { stringVars = { name } })
        or ("%s can't be switched\nout!"):format(name)
    end
    local okA, Abilities = pcall(need, "BattleSim3/Abilities")
    if okA and type(Abilities) == "table" and type(Abilities.escapeBlocker) == "function" then
      local ok, foe = pcall(Abilities.escapeBlocker, sim, b)
      if ok and foe then
        local who = foePrefix3() .. sim:nameOf(foe)
        local ability = sim:abilityLabel(foe)
        return Gen3.battleText("gText_PkmnsXPreventsSwitching", { buff1 = who, lastAbility = ability })
          or ("%s's %s\nprevents switching!"):format(who, ability)
      end
    end
  end
  return nil
end

-- That, for a choice a Gen 3 screen sent: the seat its `seat` names (a lone
-- double's), the player's on a single screen.
function M:_refusal3(payload)
  local seat = self:_seat3(payload)
  if not seat then return nil end
  return M.refusalText3(self.sim, seat, payload)
end

-- ------------------------------------------------------------------
-- the ending
-- ------------------------------------------------------------------

-- The fill the cart's battle strings expand (Adapter.fill's fields).
function M:_fill3(extra)
  local g3 = self.gen3
  local t = g3 and g3.trainer or nil
  local player = Gen3.player()
  local fill = {
    playerName = (player and player.name) or "PLAYER",
    trainer = (self.kind == "trainer") or nil,
    trainer1Class = t and (strOr(t.className) or t.trainerClass) or nil,
    trainer1Name = t and t.trainerName or nil,
  }
  for k, v in pairs(extra or {}) do fill[k] = v end
  return fill
end

local function battleProfile3()
  local BP = Gen3.engine("src.core.game3.battle.profile")
  local bp = BP and try3(BP.get, Gen3.session()) or nil
  return type(bp) == "table" and bp or nil
end

function M:_say3(text)
  local fight = self.fight
  if not (fight and type(text) == "string" and text ~= "") then return end
  pcall(fight.say, fight, text)
end

-- Half one on Gen 3: the verdict is in.  The wild monster's condition goes
-- onto the engine monster first (a catch keeps the damage it was caught
-- with, and a sleeping one its turns left -- pret's STATUS1 counter, through
-- Sheet3.applyToMon's `sleepTurns`), the screen is told, and then the cart's
-- own after-words -- the defeated line, the trainer's defeat speech and the
-- prize (paid now, as the engine pays it inside its battle), or the
-- whiteout's lines (whose money is taken with the warp, in half two).
--
-- A knockout draw whose sheets and the save disagree. Every slot a sheet
-- covers is read from the sheet: reconcile has not copied HP home yet, and
-- the save still holds what the fight started with. A sheet that still
-- stands, or a save monster no sheet covers that still stands, disagrees.
-- `half` (Steven's fight): the save party's player positions end there --
-- past it are his three (doStevenBattle appends them behind the player's,
-- and a fight with no stand-in leaves them in place, Doubles.partnerMons),
-- never the player's, and the fight is lost with the player's alone (pret
-- Cmd_checkteamslost's INGAME_PARTNER branch).
local function knockoutDisagreement3(sim, session, half)
  local player = sim and sim.byId and sim.byId[PLAYER_SEAT]
  local covered = {}
  local sheetAlive = false
  for _, sheet in ipairs(type(player) == "table" and player.mons or {}) do
    if type(sheet) == "table" then
      covered[int3(sheet.slot, 0)] = true
      if (tonumber(sheet.hp) or 0) > 0 and not sheet.judged then sheetAlive = true end
    end
  end
  if sheetAlive then return true end
  local party = type(session) == "table" and session.party or nil
  for i, mon in ipairs(type(party) == "table" and party or {}) do
    if half and i > half then break end
    if not covered[i - 1] and type(mon) == "table" and not mon.isEgg
        and int3(mon.species, 0) ~= 412 and int3(mon.hp, 0) > 0 and not mon.judged then
      return true
    end
  end
  return false
end

function M:_settle3(outcome)
  local g3, sim, fight = self.gen3, self.sim, self.fight
  local verdict = MediatedBattle.resultFor(outcome, FOE_SEAT)
  if self.kind == "wild" and self.wildMon then
    local foe = sim.byId[FOE_SEAT]
    local mon = foe and foe.mons and foe.mons[1]
    if mon then pcall(Sheet3.applyToMon, self.wildMon, mon) end
  end
  local ok, err = pcall(fight.onOutcome, fight, outcome)
  if not ok then
    self:warn("outcome", "the end of this battle could not be shown (%s); leave the "
      .. "battle screen and the result still counts", tostring(err))
  end
  if not g3 then return end
  -- A knockout draw is a win only when the referee's sheets and the save
  -- disagree. Covered slots are the sheets' (reconcile has not run, so the
  -- save still holds the HP the fight started with). A sheet that still
  -- stands, or a save monster the sheets do not cover that still stands,
  -- is the disagreement. A timeout, a disconnect and a forfeit stay draws
  -- and halt. Facilities keep their own judgment.
  -- Steven's three are never the player's: only the save's player half
  -- (Doubles' `playerHalf`) is read.
  local how = CoopField.knockoutHow3(outcome.how, outcome.reason)
  local half = g3.name == "partner" and type(g3.dbl) == "table"
    and tonumber(g3.dbl.playerHalf) or nil
  g3.standingDraw = verdict == "draw" and g3.kind == "trainer"
    and (g3.name == "trainer" or g3.name == "pair" or g3.name == "partner"
      or g3.name == "firstBattle") and not g3.facility3
    and how ~= nil and knockoutDisagreement3(sim, Gen3.session(), half) or false
  if g3.standingDraw then verdict = CoopField.trainerDrawResult3(verdict, how, true) end
  g3.verdict = verdict
  -- The referee's whole verdict (its `how` / `by`, contract C5), for the
  -- word M:_ended3 hands the engine.
  g3.outcome = outcome
  local reason = outcome.reason
  -- The player's party, either seat's monsters: a double's two seats share
  -- the one `mons` table, so the first seat's is every monster the player
  -- has (an ally's -- Steven's -- are not: the fight is lost when the
  -- player's are down, pret Cmd_checkteamslost's partner branch).
  local standing = hasLiving(sim.byId[PLAYER_SEAT])
  local lost = (verdict == "loss" or verdict == "draw") and reason ~= "run" and not standing
  -- A kind whose side a fights with nothing of the player's (Safari: out of
  -- balls is no defeat) loses nothing.
  if g3.lossless then lost = false end
  g3.whiteout = lost
  -- The loss that is not a whiteout, in battle_bridge writeback's order:
  --   * Emerald's first battle (pokeemerald battle_setup.c:950
  --     CB2_EndFirstBattle: Birch's Zigzagoon never sends you home) and a
  --     scripted loss (battle_tower.c:1994: Steven's fight, the Frontier --
  --     the script that called the fight decides what a loss means): no
  --     warp, no money, no heal -- the cart still prints its whiteout lines
  --     (pret BattleScript_LocalBattleLost) unless the kind says otherwise;
  --   * the early rival's heal-after flag (RIVAL_BATTLE_HEAL_AFTER: `noWhiteout
  --     or (earlyRival and rivalFlags bit 0)`): the party healed -- unless the
  --     caller defers it (a Secret Base, secret_base.inc:641) -- and the
  --     script carries on, no warp and no money.
  local opts = g3.opts or {}
  local scripted = opts.scriptedLoss or opts.firstBattleKind == "birch"
  local healAfter = opts.noWhiteout
    or (opts.earlyRival and (int3(opts.rivalFlags, 0) % 2 == 1))
  if g3.whiteout and scripted then
    g3.whiteout, g3.scriptedLoss = false, true
  elseif g3.whiteout and healAfter then
    g3.whiteout, g3.healAfter = false, true
    g3.deferHeal = opts.deferHeal and true or nil
  end
  -- The kind's own after-words (a pair's two defeat speeches and A + B's
  -- prize, a facility's silence), in place of the core's when it says so.
  local okK, handled = self:_hook3(g3, "settle", outcome)
  if okK and handled == true then return end
  local okW, errW = pcall(function()
    if self.kind == "trainer" and verdict == "win"
        and (reason == "ko" or outcome.how == "judge" or g3.standingDraw) then
      self:_trainerWon3()
    elseif lost then
      -- pret BattleScript_LocalBattleLost's early-rival arm (the engine's
      -- D.pushBattleLost): the rival crows first -- the trainer's victory
      -- speech -- and a heal-after fight says nothing more.
      local t = g3.trainer or {}
      if self.kind == "trainer" and opts.earlyRival and t.victoryText then
        self:_say3(t.victoryText)
      end
      if g3.whiteout or g3.scriptedLoss then self:_lostLines3() end
    end
  end)
  if not okW then
    self:warn("reward3", "the end-of-battle rewards could not be worked out (%s); report "
      .. "this with the battle you were in", tostring(errW))
  end
end

-- The Amulet Coin: its holder was sent in on our side, or -- FireRed and
-- LeafGreen only (Emerald's amuletCoinPlayerOnly) -- on theirs.
function M:_moneyMultiplier3(bp)
  local g3 = self.gen3
  if not g3 then return 1 end
  if g3.amuletPlayer then return 2 end
  local playerOnly = bp and bp.rules and bp.rules.amuletCoinPlayerOnly
  if g3.amuletFoe and not playerOnly then return 2 end
  return 1
end

-- pret BattleScript_LocalTrainerBattleWon: "PLAYER defeated CLASS NAME!",
-- the trainer's defeat speech, and getmoneyreward -- FireRed's
-- 4 x last level x class value (Prize.awardTrainerWin, said only when
-- something was paid), Emerald's money table (Prize.rewardRse, always said).
-- A lone double pays twice over on both carts (pokefirered Cmd_getmoneyreward's
-- `BATTLE_TYPE_DOUBLE ? 2 : 1`, pokeemerald GetTrainerMoneyToGive's DOUBLE
-- arm; the engine's prize.lua `double`).
function M:_trainerWon3()
  local g3 = self.gen3
  local t = g3.trainer or {}
  local double = g3.double == true
  local fill = self:_fill3()
  self:_say3(Gen3.battleText("STRINGID_PLAYERDEFEATEDTRAINER1", fill)
    or ("%s defeated\n%s!"):format(fill.playerName, M.gen3FoeLabel(t)))
  if t.defeatText then self:_say3(t.defeatText) end
  local session = Gen3.session()
  local trainerId = int3(t.trainerId, nil)
  local Prize = Gen3.engine("src.core.game3.battle.prize")
  if not (session and trainerId and Prize) then return end
  local bp = battleProfile3()
  local mult = self:_moneyMultiplier3(bp)
  local name = session.name or fill.playerName
  if bp and bp.rules and bp.rules.money == "rse" then
    local amount = int3(try3(Prize.rewardRse, trainerId, { double = double, moneyMultiplier = mult }), 0)
    local gained = int3(try3(Prize.apply, session, amount), 0)
    g3.prize = gained
    self:_say3(try3(Prize.moneyMessage, name, amount))
    return
  end
  local Trainers = Gen3.engine("src.core.game3.scripting.trainers")
  local info = Trainers and try3(Trainers.info, trainerId) or nil
  local lastLevel = int3(type(info) == "table" and info.lastLevel, nil)
  if not lastLevel or lastLevel < 1 then
    local party = g3.party or {}
    local last = party[#party]
    lastLevel = int3(last and last.level, 1)
  end
  local gained = int3(try3(Prize.awardTrainerWin, session, trainerId, {
    lastLevel = lastLevel, double = double, moneyMultiplier = mult,
  }), 0)
  g3.prize = gained
  if gained > 0 then self:_say3(try3(Prize.moneyMessage, name, gained)) end
end

-- pret BattleScript_LocalBattleLost's lines (the engine's D.pushBattleLost):
-- Emerald says the two whiteout lines; FireRed says what it is about to cost
-- -- the loss of Cmd_getmoneyreward's lose branch, never more than is held.
function M:_lostLines3()
  local bp = battleProfile3()
  local session = Gen3.session()
  local fill = self:_fill3()
  local fallback1 = fill.playerName .. " is out of\nusable POKéMON!"
  local fallback2 = fill.playerName .. " whited out!"
  if bp and bp.rules and bp.rules.lostText == "rse" then
    self:_say3(Gen3.battleText("STRINGID_PLAYERWHITEOUT", fill) or fallback1)
    self:_say3(Gen3.battleText("STRINGID_PLAYERWHITEOUT2", fill) or fallback2)
    return
  end
  local BB = Gen3.engine("src.core.game3.battle_bridge")
  local money = int3(session and session.money, 0)
  local loss = min(int3(BB and try3(BB.calcMoneyLossFrlg, session), 0), money)
  fill.buff1 = tostring(loss)
  if self.kind == "wild" then
    self:_say3(Gen3.battleText("STRINGID_PLAYERWHITEOUT", fill) or fallback1)
    self:_say3(Gen3.battleText(loss > 0 and "STRINGID_PLAYERWHITEOUT2"
      or "STRINGID_PLAYERWHITEDOUT", fill) or fallback2)
  else
    self:_say3(Gen3.battleText("STRINGID_PLAYERLOSTAGAINSTENEMYTRAINER", fill) or fallback1)
    self:_say3(Gen3.battleText(loss > 0 and "STRINGID_PLAYERPAIDPRIZEMONEY"
      or "STRINGID_PLAYERWHITEDOUT", fill) or fallback2)
  end
end

-- HP, PP and status home onto the session party -- the same delta rule as
-- M:_applyMon (a level's HP growth survives), through Sheet3.applyToMon (PP
-- lives in `mon.pp[]` by slot on a Gen 3 mon) -- and the sleep counter with
-- them.  Resolved through each sheet's own party slot.  Once for a double
-- too: its two seats hold the one `mons` table, so the first seat's list is
-- the whole party, whichever side of the field each monster fought on.
function M:_reconcile3(sim, session)
  local party = session and session.party
  local player = sim and sim.byId and sim.byId[PLAYER_SEAT]
  if not (type(party) == "table" and player and type(player.mons) == "table") then return false end
  local applied = 0
  for _, simMon in ipairs(player.mons) do
    local target = party[int3(simMon.slot, 0) + 1]
    if type(target) == "table" then
      local simMax = max(1, int3(simMon.maxHp, 1))
      local saveMax = int3(target.maxHp, simMax)
      local grown = max(0, saveMax - simMax)
      local hp = max(0, int3(simMon.hp, 0))
      if hp > 0 then hp = min(saveMax, hp + grown) end
      Sheet3.applyToMon(target, { hp = hp, status = simMon.status, moves = simMon.moves })
      if target.status == "SLP" and tonumber(simMon.sleepTurns) then
        target.sleep = int3(simMon.sleepTurns, 0)
      end
      applied = applied + 1
    end
  end
  return applied > 0
end

-- The whiteout (battle_bridge.lua writeback's lose branch): the cart's money
-- loss, then Field.respawnAtHeal -- the VM halted, the party healed, the warp
-- to the last heal location, `world.blacked_out`.  A build without the field
-- module still heals rather than leaving the party at zero.
function M:_whiteout3(game, session)
  local BB = Gen3.engine("src.core.game3.battle_bridge")
  if BB then pcall(BB.applyWhiteoutMoneyLoss, session, type(game) == "table" and game.save or nil) end
  local Field = Gen3.engine("src.core.game3.field")
  local ok, err = false, "the field module is unavailable"
  if Field and type(Field.respawnAtHeal) == "function" then ok, err = pcall(Field.respawnAtHeal) end
  if not ok then
    local Party = Gen3.engine("src.core.game3.party")
    if Party then pcall(Party.healAll, session.party) end
    self:warn("whiteout3", "the trip back to the POKéMON CENTER after this loss failed (%s); "
      .. "your party was healed where you stand -- walk there, or reload from your last save",
      tostring(err))
  end
end

-- Everything that describes a running fight, let go together (the ending, a
-- hand-back, a screen that would not open).
function M:_clear3()
  self.fight, self.sim, self.brain = nil, nil, nil
  self.engine, self.game, self.wildMon = nil, nil, nil
  self.kind, self.reason, self.save, self.levels = nil, nil, nil, nil
  self.settled, self.pendingWarp, self.refuseRun = false, nil, nil
  self.failedRun, self.generation, self.cantEscape = nil, nil, nil
  self.runAttempts, self.faults = 0, 0
  self.gen3 = nil
end

-- The engine monster a sim fighter has out at the end (or last had out, for a
-- side that was knocked out), found through its sheet's party slot in `party`.
-- A double's first seat for the reports that take one monster a side.
local function endMon3(fighter, party)
  if not (fighter and type(party) == "table") then return nil end
  local sheet = fighter.mons and fighter.active and fighter.mons[fighter.active] or nil
  if not sheet and fighter.lastB then sheet = fighter.lastB.mon end
  if not sheet then
    for _, m in ipairs(fighter.mons or {}) do sheet = sheet or m end
  end
  local mon = sheet and party[int3(sheet.slot, 0) + 1] or nil
  return type(mon) == "table" and mon or nil
end

-- The player's second battler at the end of a double, as pret's
-- HandleEndTurn_FinishBattle fills gBattleResults.playerMon2Species: the
-- second player battler's gBattlerPartyIndexes -- the monster standing on
-- that position, or the last one that stood there (a fainted battler's party
-- index is never cleared).  nil for a seat that never had one, where the cart
-- would leave the species 0.
function M.secondMon3(sim, party)
  if not (sim and type(party) == "table") then return nil end
  local ok, seats = pcall(sim.seatsOf, sim, PLAYER_SEAT)
  local seat = ok and type(seats) == "table" and seats[2] or nil
  if not seat then return nil end
  local sheet = seat.active and seat.mons and seat.mons[seat.active] or nil
  if not sheet and seat.lastB then sheet = seat.lastB.mon end
  local mon = sheet and party[int3(sheet.slot, 0) + 1] or nil
  return type(mon) == "table" and mon or nil
end

-- Half two on Gen 3: the screen is off the stack.
--
-- In the engine's own order (battle_bridge.lua finish): the party home, the
-- cart's gBattleOutcome, the whiteout or the rival's heal, Pickup after a win
-- -- then, one at a time, any move-learn prompt the player left unanswered
-- and the after-battle evolutions (pret FreeResetData_ReturnToOvOrDoEvolutions:
-- a won battle only), and last, once those have closed, the rest of what the
-- engine does as a battle it ran comes to an end (M:_finishEffects3), the
-- kind's own tail (contract C2 `finish`), a first battle's saved song let go,
-- the map's resume scripts and the caller's `done` -- so a trainer script
-- resumes over a settled party, on a field no prompt is still covering.
function M:_ended3(result, toLearn)
  local game, sim, g3 = self.game, self.sim, self.gen3
  local reason = self.reason
  local evoResolved = self.fight and self.fight.evoResolved
  self:_clear3()
  if not (game and sim and g3) then return false end

  local session = Gen3.session()
  local same = session ~= nil and session == g3.session
  if same then
    -- A kind whose party was not in the fight (Safari) or was rented has
    -- nothing to bring home.
    if not g3.noReconcile then self:_reconcile3(sim, session) end
  else
    self:warn("reload", "the save changed while a battle was running, so that battle's "
      .. "damage was not written to your party; nothing was lost, but check the party "
      .. "you loaded")
  end
  local o = type(g3.outcome) == "table" and g3.outcome or {}
  local verdict = g3.verdict or result
  local whiteout = same and g3.whiteout
    and not M.gen3Standing(session.party, M.judgedSlots3(sim.byId and sim.byId[PLAYER_SEAT]))
  -- A flight with no `how` is decided by who ran; one with no `run` event was
  -- a POKé DOLL / FLUFFY TAIL thrown by our side (the only side with a bag in
  -- a wild fight).
  local ranSide = (reason == "run") and (g3.ranSide or "a") or nil
  local bp = battleProfile3()
  local doneWord, saveWord = M.gen3Words({
    verdict = verdict, reason = reason, how = o.how, by = o.by,
    whiteout = whiteout, ranSide = ranSide, kind = g3.kind,
    teleportBySide = M.teleportBySide3(bp, g3.family),
  })
  local won = verdict == "win" and (reason == "ko" or o.how == "judge" or g3.standingDraw)

  -- A knockout whose sheets and the save disagreed was promoted at
  -- settlement, so that continuation sets the flag and pays the prize.
  -- Every other unfinished trainer result halts rather than running a
  -- beaten script without its victory flag. Kinds may supply their own word.
  local ending = {
    result = doneWord, word = saveWord,
    halt = same and g3.kind == "trainer" and doneWord == "lose" and not whiteout
      and not g3.healAfter and not g3.scriptedLoss,
  }
  -- Read now: the ending's reports name the monsters out at the end.  In a
  -- double the reports that take one monster a side (the quest log,
  -- `battle.ended`) are given each side's first seat; the TV also reads the
  -- player's second battler and the foe's monster that fainted last.
  ending.playerMon = same and endMon3(sim.byId and sim.byId[PLAYER_SEAT], session.party) or nil
  ending.foeMon = endMon3(sim.byId and sim.byId[FOE_SEAT], g3.party)
  if g3.double then
    if same then ending.playerMon2 = M.secondMon3(sim, session.party) end
    local fainted = g3.lastFoeFainted
    local owner = g3.lastFoeFaintedOwner or FOE_SEAT
    local party = (type(g3.parties) == "table" and g3.parties[owner])
      or (owner == FOE_SEAT and g3.party) or nil
    local src = fainted and type(party) == "table" and party[int3(fainted.slot, 0) + 1] or nil
    ending.lastFoeMon = type(src) == "table" and src or nil
  end
  -- The kind's own word (contract C5): it answers its caller itself.
  local okK, kindWord = self:_hook3(g3, "word", o, ending)
  if okK and type(kindWord) == "string" and kindWord ~= "" then
    ending.result, ending.halt = kindWord, false
  end

  if same then
    local Natives = Gen3.engine("src.core.game3.scripting.natives")
    local code = Natives and try3(Natives.outcome_to_code, ending.word)
    if code ~= nil then session.battleOutcome = code end
    if whiteout then
      self:_whiteout3(game, session)
    elseif g3.healAfter and not g3.deferHeal then
      local Party = Gen3.engine("src.core.game3.party")
      if Party then pcall(Party.healAll, session.party) end
    end
    -- Pickup after a win (pret Cmd_pickup, the engine's
    -- give_payday_money_and_pickup), unless the kind's rules have none.
    if won and not g3.noPickup then
      local Prize = Gen3.engine("src.core.game3.battle.prize")
      if Prize then pcall(Prize.pickup, session.party, nil, bp and bp.rules or nil) end
    end
  end

  local halt = ending.halt
  local levelled = same and won and M.levelled3(session.party, g3.levels) or nil
  levelled = EvolveFx.withoutResolved(levelled, evoResolved)
  local done = g3.done
  local opts = g3.opts or {}
  local finished = false
  local function finish()
    if finished then return end
    finished = true
    local after = nil
    if same then
      local okE, errE = pcall(self._finishEffects3, self, session, g3, {
        result = halt and ending.word or ending.result, word = ending.word,
        playerMon = ending.playerMon, foeMon = ending.foeMon,
        playerMon2 = ending.playerMon2, lastFoeMon = ending.lastFoeMon,
      })
      if not okE then
        self:warn("effects3", "part of the end of this battle could not be recorded (%s); "
          .. "the battle itself counted -- report this with the battle you were in",
          tostring(errE))
      end
      -- The kind's own tail: its writeback and the engine's ends of it (a
      -- roamer's relocation, the Safari Zone's counters, a facility's
      -- records).
      local okF, tail = self:_hook3(g3, "finish", o, ending)
      if okF and type(tail) == "function" then after = tail end
      -- pokeemerald battle_setup.c:952 CB2_EndFirstBattle's
      -- Overworld_ClearSavedMusic (battle_bridge.lua finish, for both
      -- carts' first battles): the song the script saved to come back to
      -- (Oak's / Birch's theme) is let go, and the map's own plays.
      if opts.firstBattleKind or opts.firstBattle then
        local Audio = Gen3.engine("src.core.game3.audio")
        if Audio and type(Audio.clearSavedSong) == "function" then
          pcall(Audio.clearSavedSong)
          pcall(Gen3.audio.restoreMapSong)
        end
      end
      if halt then M.haltScript3() end
      -- The map's resume scripts (pokefirered battle_setup.c:432), after the
      -- last prompt the fight left up has closed -- for a fight that ends on
      -- the field (`noFieldReturn`).
      local Space = not g3.noFieldReturn and Gen3.engine("src.core.game3.scripting.space") or nil
      if Space then pcall(Space.returnToField) end
    end
    if halt then return end
    local okD, errD = true, nil
    if type(done) == "function" then
      okD, errD = pcall(done, ending.result)
    end
    if not okD then
      self:warn("done3", "what was waiting on this battle could not carry on (%s); "
        .. "talk to the trainer again, or reload from your last save", tostring(errD))
    end
    if after then
      local okA, errA = pcall(after)
      if not okA then
        self:warn("after3k", "the end of this battle could not be fully recorded (%s); "
          .. "report this with the battle you were in", tostring(errA))
      end
    end
  end
  self:_afterBattle3(game, same and toLearn or nil, levelled, finish)
  return true
end

-- The script VM's waiting trainerbattle, ended where it waits (Vm:halt,
-- aborted -- what Field.respawnAtHeal does to it on the cart's whiteout):
-- whatever the script locked is released and nothing after the command runs.
-- False when no script is running.
function M.haltScript3()
  local Space = Gen3.engine("src.core.game3.scripting.space")
  local vm = type(Space) == "table" and Space.vm or nil
  if type(vm) ~= "table" or type(vm.halt) ~= "function" then return false end
  if type(vm.isRunning) == "function" and try3(vm.isRunning, vm) ~= true then return false end
  local ok, err = pcall(vm.halt, vm, true)
  if not ok then
    mod.log:warn("the trainer's script could not be stopped after an unfinished battle "
      .. "(%s); reload from your last save if the world seems stuck", tostring(err))
    return false
  end
  return true
end

-- What the engine does as a battle it ran itself comes to an end, beyond the
-- rewards (battle/init.lua finish, then battle_bridge.lua finish), for a
-- fight off the link:
--
--   * Emerald's Pokérus: a chance to catch it, then its spread through the
--     party (pret ReturnFromBattleToOverworld; Pokemon.randomlyGivePartyPokerus
--     / partySpreadPokerus).
--   * FireRed / LeafGreen's quest log: a won or caught fight becomes the
--     "previously on your quest" scene (quest_log_recorder.battle), where the
--     cart keeps them.
--   * Emerald's TV: "POKéMON TODAY" and its breaking news
--     (pret TryPutPokemonTodayOnAir, the engine's BattleBridge.tvBattleEnd).
--     Called with the session first, as the TV reads it: the engine's own
--     call hands it the results table in that place.
--   * `battle.ended`, the engine event every listener waits on (src/Client.lua
--     narrates a fight to a partner from it; the engine's Discord presence
--     leaves its battle line).  Emitted through the engine's own mod runtime,
--     with the engine's payload -- `{ battle = <state>, result }` -- the
--     state being what the engine's battle state says about the fight
--     (`wild`, `link`, the trainer's class / name / id, `player` / `enemy`
--     as `{ mon = <engine monster> }`, the parties, `battleResults`, and the
--     engine's own battle-type flags and `kinds` -- M.engineKinds3), and
--     `rbyMmoSolo` saying whose fight it was.
--
-- The TV is told the fight's battle type the way BattleBridge.tvBattleEnd
-- tells it (pret battle_main.c:5102's exclusions: a safari, a first battle,
-- Wally's tutorial, a Frontier fight, an e-Reader trainer are never on air).

-- The engine's words for a fight's ending, where they differ from the
-- caller's (battle/init.lua's st.result, which `battle.ended` carries): a
-- catch is "catch", a wild flee "fled", the player's TELEPORT
-- "player_teleported" (battle/effects/special.lua:292).
M.ENGINE_RESULT3 = { caught = "catch", mon_fled = "fled", teleport_player = "player_teleported" }

-- The battle-type flags the engine's battle state carries for a fight
-- (battle/init.lua:539-740, from the start's opts and foe), for the reports
-- that read them.  `g3` is a fight's ctx; its kind name stands in for the
-- session states the engine reads at its own start (the Safari Zone, a
-- Pokemon Tower ghost) and its stand's `tutorial3` for the POKeDUDE.
function M.engineFlags3(g3)
  g3 = type(g3) == "table" and g3 or {}
  local opts = type(g3.opts) == "table" and g3.opts or {}
  local foe = type(g3.foe) == "table" and g3.foe or {}
  local function on(key)
    return (opts[key] ~= nil and opts[key] ~= false) or (foe[key] ~= nil and foe[key] ~= false)
  end
  return {
    wild = g3.kind == "wild",
    double = g3.double or nil,
    link = false, unionRoom = false, spectate = false, multi = nil,
    safari = on("safari") or g3.name == "safari",
    roamer = on("roamer") or g3.name == "roamer",
    legendary = on("legendary"),
    wildScripted = on("wildScripted"),
    trainerTower = opts.trainerTower and true or false,
    eReader = opts.eReader and true or false,
    battleTower = opts.battleTower and true or false,
    secretBase = opts.secretBase and true or false,
    pokedude = on("pokedude") or g3.tutorial3 == "pokedude",
    ghostBattle = on("ghostBattle") or on("ghost") or g3.name == "ghost",
    oldManTutorial = on("oldManTutorial") or g3.tutorial3 == "oldMan",
    firstBattle = on("firstBattle"),
  }
end

-- The engine battle state's `kinds` for that fight: its own Kinds.fromOpts
-- over the opts and those flags (battle/kinds.lua, the one table the quest
-- log, the TV and every `battle.ended` listener read), else -- an engine
-- without it, or a profile it refuses -- the same table spelled here: each
-- flag that is set, the start's extra kinds, `trainer` off the wild,
-- `firstBattle` / `tutorial` named as the profile names them.
M.EXTRA_KINDS3 = {
  "twoOpponents", "partner", "recordedLink", "frontier", "trainerHill", "kyogreGroudon", "regi",
  "groudon", "kyogre", "rayquaza", "dome", "palace", "arena", "factory", "pike", "pyramid",
}
function M.engineKinds3(opts, flags, bp)
  opts = type(opts) == "table" and opts or {}
  flags = type(flags) == "table" and flags or {}
  local Kinds = Gen3.engine("src.core.game3.battle.kinds")
  if Kinds and type(Kinds.fromOpts) == "function" and type(bp) == "table"
      and type(bp.kinds) == "table" then
    local ok, k = pcall(Kinds.fromOpts, opts, flags, bp)
    if ok and type(k) == "table" then return k end
  end
  local k = {}
  for name, v in pairs(flags) do
    if v == true then k[name] = true end
  end
  for _, name in ipairs(M.EXTRA_KINDS3) do
    if opts[name] then k[name] = true end
  end
  k.trainer = not flags.wild or nil
  local named = type(bp) == "table" and type(bp.kinds) == "table" and bp.kinds or {}
  if opts.firstBattleKind ~= nil then
    k.firstBattle = opts.firstBattleKind
  elseif flags.firstBattle then
    k.firstBattle = named.firstBattle or true
  end
  if opts.tutorialKind ~= nil then
    k.tutorial = opts.tutorialKind
  elseif flags.oldManTutorial then
    k.tutorial = named.tutorial or "oldman"
  end
  return k
end

-- The TV's battle type (BattleBridge.tvBattleEnd's, pret battle_main.c:5102).
function M.tvBattleType3(st)
  local k = type(st.kinds) == "table" and st.kinds or {}
  return {
    link = st.link or k.link, recordedLink = k.recordedLink, trainer = not st.wild,
    firstBattle = k.firstBattle ~= nil, safari = st.safari or k.safari,
    ereaderTrainer = st.eReader, wallyTutorial = k.tutorial == "wally", frontier = k.frontier,
  }
end

function M:_finishEffects3(session, g3, ending)
  local bp = battleProfile3()
  local family = (bp and bp.family) or Gen3.family()
  local wild = g3.kind == "wild"
  local t = g3.trainer or {}
  -- The engine battle state's own word.
  local stateResult = M.ENGINE_RESULT3[ending.result] or ending.result
  local st = M.engineFlags3(g3)
  st.kinds = M.engineKinds3(g3.opts, st, bp)
  local fields = {
    rbyMmoSolo = true,
    over = true, result = stateResult,
    trainerId = (not wild) and int3(t.trainerId, nil) or nil,
    trainerClass = (not wild) and int3(t.trainerClass, nil) or nil,
    trainerClassName = (not wild) and t.className or nil,
    trainerName = (not wild) and t.trainerName or nil,
    player = ending.playerMon and { mon = ending.playerMon } or nil,
    enemy = ending.foeMon and { mon = ending.foeMon } or nil,
    -- A double, in the engine state's own words: `double`, and `player2` --
    -- the name BattleBridge.tvBattleEnd reads the second battler by.
    player2 = ending.playerMon2 and { mon = ending.playerMon2 } or nil,
    playerParty = session.party, foeParty = g3.party,
    battleResults = g3.results, session = session,
  }
  for k, v in pairs(fields) do st[k] = v end

  local Pokemon = Gen3.engine("src.core.game3.pokemon")
  if family == "rse" and Pokemon then
    pcall(Pokemon.randomlyGivePartyPokerus, session.party, session)
    pcall(Pokemon.partySpreadPokerus, session.party, session)
  end

  -- FireRed / LeafGreen's quest log keeps no scene of the old man's
  -- tutorial or the POKe DUDE's demonstrations (pret quest_log_battle.c:14
  -- TrySetQuestLogBattleEvent: LINK | OLD_MAN_TUTORIAL | POKEDUDE; the engine
  -- skips them at its own call site, battle/init.lua:417).
  local FieldModules = Gen3.engine("src.core.game3.field_modules")
  if family ~= "rse" and not (st.oldManTutorial or st.pokedude) and FieldModules
     and try3(FieldModules.enabled, "questLog", session) == true then
    local Recorder = Gen3.engine("src.core.game3.quest_log_recorder")
    if Recorder then pcall(Recorder.battle, session, st) end
  end

  if family == "rse" then
    local Rse = Gen3.engine("src.core.game3.rse.init")
    local Natives = Gen3.engine("src.core.game3.scripting.natives")
    if Rse and type(Rse.call) == "function" then
      local function speciesOf(mon)
        return mon and (int3(Pokemon and try3(Pokemon.speciesOf, mon), nil)
          or int3(mon.species, 0)) or 0
      end
      local function nickOf(mon)
        if not mon then return "" end
        return strOr(mon.nickname, mon.name) or ""
      end
      local caught = ending.result == "caught"
      local r = g3.results or {}
      local results = {
        playerMon1Species = speciesOf(ending.playerMon), playerMon1Name = nickOf(ending.playerMon),
        -- 0 on a single; a double's second battler (M.secondMon3).
        playerMon2Species = speciesOf(ending.playerMon2),
        caughtMonSpecies = caught and speciesOf(ending.foeMon) or 0,
        caughtMonNick = caught and nickOf(ending.foeMon) or "",
        caughtMonBall = caught and int3(r.lastUsedItem, 0) or 0,
        catchAttempts = r.catchAttempts or {},
        usedMasterBall = r.usedMasterBall == true,
        lastUsedItem = int3(r.lastUsedItem, 0),
        -- A double's is the trainer's monster that fainted last (M:_note3).
        lastOpponentSpecies = speciesOf(ending.lastFoeMon or ending.foeMon),
        shinyWildMon = wild and ending.foeMon ~= nil and Pokemon ~= nil
          and try3(Pokemon.isShiny, ending.foeMon) == true or false,
      }
      local code = Natives and try3(Natives.outcome_to_code, ending.word) or nil
      pcall(Rse.call, "tv", "onBattleEnd", "TryPutPokemonTodayOnAir", nil, session, results,
        code, M.tvBattleType3(st))
    end
  end

  local Runtime = Gen3.engine("src.mods.Runtime")
  if Runtime and try3(Runtime.wants, "battle.ended") == true then
    pcall(Runtime.emit, "battle.ended", { battle = st, result = stateResult })
  end
end

-- The prompts a Gen 3 fight still owes, one after another, then `finish`:
-- a move-learn exchange the player left the screen before answering
-- (LearnMove's Gen 3 arm, the overworld wording), then each levelled monster
-- that now qualifies through the cart's EvolutionScene (which teaches the
-- evolved species' moves itself before it closes).
function M:_afterBattle3(game, toLearn, levelled, finish)
  local steps = {}
  for _, entry in ipairs(type(toLearn) == "table" and toLearn or {}) do
    if type(entry) == "table" and type(entry.mon) == "table" and entry.move then
      steps[#steps + 1] = function(advance)
        local opened = LearnMove.open(game, entry.mon, entry.move, function() advance() end,
          { ui = self.ui, battle = false })
        if not opened then advance() end
      end
    end
  end
  if levelled then
    local Evolution = Gen3.engine("src.core.game3.evolution")
    local Scene = Gen3.engine("src.ui.game3.evolution_scene")
    if not (Evolution and Scene and type(Scene.start) == "function") then
      self:warn("evolve3", "the engine's Gen 3 evolution scene is unavailable, so POKéMON "
        .. "that levelled in this battle were not offered evolutions -- level again or "
        .. "use a RARE CANDY")
    else
      local session = Gen3.session()
      for _, mon in ipairs(Gen3.party() or {}) do
        if levelled[mon] then
          steps[#steps + 1] = function(advance)
            local into = int3(try3(Evolution.levelTarget, mon, session), nil)
            if not into then return advance() end
            local ok, started = pcall(Scene.start, mon, into, {
              canStop = true, session = session, bag = session and session.bag,
              via = "level", onDone = function() advance() end,
            })
            if not (ok and started) then
              self:warn("evolve3", "could not open the evolution scene after this battle; "
                .. "it can still evolve by levelling again or with a RARE CANDY")
              advance()
            end
          end
        end
      end
    end
  end
  local index = 0
  local function nextStep()
    index = index + 1
    local step = steps[index]
    if not step then return finish() end
    local moved = false
    local function advance()
      if moved then return end
      moved = true
      nextStep()
    end
    local ok, err = pcall(step, advance)
    if not ok then
      self:warn("after3", "a prompt after this battle failed (%s); carrying on", tostring(err))
      advance()
    end
  end
  nextStep()
end

-- ------- the party as a double found it
--
-- A single's screen (MediatedBattle) fights copies: HP, status and PP stay on
-- the referee's sheets until M:_reconcile3 brings them home.  A lone double's
-- screen is CoopBattle's, and co-op seats fight on the live session party
-- itself (newSoloDouble: "the same table") -- HP and status as the referee's
-- damage and status events replay, PP as each `moves` event lands (savePp3),
-- a held item as it is eaten or knocked off (applyHeld3), EXP, the level, its
-- stats and the moves it teaches as each knockout pays (gainExp3,
-- LearnMove).  The fight's own ending is right regardless: M:_reconcile3
-- writes the referee's final HP / PP / status over all of it, and the rest is
-- what the fight earned.  A hand-back is not: the cart's battle against the
-- same trainer would start from a party already hurt, poisoned, out of PP and
-- part-levelled by a fight it never saw -- and pay the same EXP again.  So the
-- party is recorded as the fight is diverted and put back, value for value,
-- before the cart's battle starts in its place.
--
-- In place, never replaced: each member, and each plain table it holds (its
-- moves, PP, IVs, EVs, stats), is the very table it was, with the contents it
-- had -- keys the fight added are taken off again -- so nothing that kept a
-- reference to one is left holding a copy.  Plain data only: a table with a
-- metatable is a reference to something else and is kept as that reference,
-- never walked.  Three levels down covers a Gen 3 party monster (the
-- monster, its lists, anything a list holds).  The list itself -- who, in
-- which order -- is put back too.
local PARTY_SNAP_DEPTH = 3

local function snapTable3(t, depth, recs)
  if recs[t] then return end
  local fields, nested = {}, {}
  recs[t] = { ref = t, fields = fields }
  for k, v in pairs(t) do
    fields[k] = v
    if type(v) == "table" and depth > 1 and getmetatable(v) == nil then
      nested[#nested + 1] = v
    end
  end
  for _, child in ipairs(nested) do snapTable3(child, depth - 1, recs) end
end

-- The record; nil for no party.
function M.snapshotParty3(party)
  if type(party) ~= "table" then return nil end
  local recs, members = {}, {}
  for i, mon in ipairs(party) do
    members[i] = mon
    if type(mon) == "table" and getmetatable(mon) == nil then
      snapTable3(mon, PARTY_SNAP_DEPTH, recs)
    end
  end
  return { party = party, members = members, count = #members, recs = recs }
end

-- Put it back.  False for no record (nothing to do, nothing done).
function M.restoreParty3(snap)
  if type(snap) ~= "table" or type(snap.party) ~= "table" then return false end
  local party = snap.party
  for i = #party, snap.count + 1, -1 do party[i] = nil end
  for i = 1, snap.count do party[i] = snap.members[i] end
  for _, rec in pairs(snap.recs) do
    local t, fields = rec.ref, rec.fields
    for k in pairs(t) do
      if fields[k] == nil then t[k] = nil end
    end
    for k, v in pairs(fields) do t[k] = v end
  end
  return true
end

-- `reset` on Gen 3.  There is no buried battle to put back on top, so what
-- "hand it back" means here is: take our screen off without running its
-- ending, and -- unless the save changed underneath (a load drops the fight
-- and everything waiting on it) -- start the engine's own battle against the
-- same opponent, with the caller's `done` on it.
-- A fight its kind ends on the spot, between two frames of the referee: the
-- POKe DUDE's demonstration with B held (pret pokefirered battle_main.c:1455
-- BattleMainCB2: gSpecialVar_Result = gBattleOutcome = B_OUTCOME_DREW, the
-- fade, CB2_QuitPokedudeBattle straight back to gMain.savedCallback).  No
-- further turn: the referee is dropped where it stands.  Nothing comes home
-- and nothing is reported -- no reconcile, no Pickup, no evolutions, no quest
-- log, TV or battle.ended (what the screen already paid stays paid); the
-- cart's outcome code is written where its gBattleOutcome is
-- (session.battleOutcome, from `saveWord`, else `word`, through
-- Natives.outcome_to_code; `saveWord` false writes none -- the POKe DUDE's
-- bag and party menus leave it alone), the screen comes off without its own
-- ending, and the caller's `done(word)` runs.  The kind gives back what it
-- borrowed before it asks.  -> true when there was a fight to end.
function M:quit3(word, saveWord)
  local g3, fight, game = self.gen3, self.fight, self.game
  if not (self.generation == 3 and g3 and fight) then return false end
  self:_clear3()
  fight.onDone = nil
  if Gen3Ui.has(fight) then pcall(Gen3Ui.pop, game, fight) end
  local session = Gen3.session()
  if saveWord ~= false and session ~= nil and session == g3.session then
    local Natives = Gen3.engine("src.core.game3.scripting.natives")
    local code = Natives and try3(Natives.outcome_to_code, saveWord or word)
    if code ~= nil then session.battleOutcome = code end
  end
  local done = g3.done
  if type(done) == "function" then
    local ok, err = pcall(done, word)
    if not ok then
      self:warn("done3", "what was waiting on this battle could not carry on (%s); "
        .. "talk to the trainer again, or reload from your last save", tostring(err))
    end
  end
  return true
end

function M:_reset3()
  local game, fight, g3 = self.game, self.fight, self.gen3
  self:_clear3()
  if fight then
    fight.onDone = nil
    if Gen3Ui.has(fight) then pcall(Gen3Ui.pop, game, fight) end
  end
  if not g3 then return true end
  local session = Gen3.session()
  if session == nil or session ~= g3.session then return true end
  -- A double's screen has been writing the fight onto the live party; the
  -- cart's battle starts from the party it would have started from, so it is
  -- put back first (after the pop, which is the screen's last chance to
  -- write).  A single's screen never touched HP, status or PP, and has no
  -- snapshot.
  if g3.partySnap and not M.restoreParty3(g3.partySnap) then
    self:warn("restore3", "your party could not be put back the way this battle found it "
      .. "before the ordinary battle took over; check your POKéMON's HP and PP, or "
      .. "reload from your last save")
  end
  -- The kind puts back what it took (a facility's `Battle._nextFacility`),
  -- and may start the cart's battle itself (a roamer with its own
  -- encounter).  Under the hand-back guard: that start re-enters the divert.
  self.handingBack3 = true
  local okK, handled = self:_hook3(g3, "handBack")
  self.handingBack3 = false
  if okK and handled == true then return true end
  self:_handBack3(game, g3)
  return true
end

-- A wild foe row for the engine's own battle, carrying the one monster that
-- was met rather than a fresh roll of its species: its personality, IVs,
-- nature, held item and moves ride on the row the engine's battle builds its
-- monster from (battle/init.lua foe_mon_from re-rolls the IVs and the item
-- only when the row leaves them out).  `foe` is the encounter row (copied,
-- never written; its `mon` is dropped), `mon` the engine monster.  The foe
-- unchanged when there is no monster to carry.  Exported for src/Client.lua's
-- own hand-back of a step encounter, so both hand the same monster back.
function M.gen3HandedFoe(foe, mon)
  if type(mon) ~= "table" then return foe end
  local copy = {}
  for k, v in pairs(type(foe) == "table" and foe or {}) do copy[k] = v end
  copy.mon = nil
  copy.species = int3(mon.species, nil) or int3(mon.speciesId, nil) or copy.species
  copy.level = int3(mon.level, nil) or copy.level
  copy.personality, copy.nature = mon.personality, mon.nature
  copy.ivs, copy.evs = mon.ivs, mon.evs
  copy.item = int3(mon.item, nil) or int3(mon.heldItem, 0)
  copy.moves, copy.pp = copyList(mon.moves), copyList(mon.pp)
  copy.ability, copy.gender, copy.friendship = mon.ability, mon.gender, mon.friendship
  return copy
end

-- Start the engine's own battle in this fight's place.  src/Client.lua's
-- divert sits in front of that start (the BattleBridge.start wrap), so for as
-- long as it runs this file answers every offer with no (`handingBack3`) --
-- otherwise the hand-back would be diverted straight back into a solo fight,
-- handed back again, and so on.
function M:_handBack3(game, g3)
  self.handingBack3 = true
  local okH, errH = pcall(function()
    local opts = g3.opts or {}
    if type(opts.fallback) == "function" then
      local ok, err = pcall(opts.fallback)
      if not ok then
        self:warn("fallback3", "the ordinary battle could not be started again (%s); walk "
          .. "into it again, or reload from your last save", tostring(err))
      end
      return
    end
    local BB = Gen3.engine("src.core.game3.battle_bridge")
    local startOpts = {}
    for k, v in pairs(opts) do
      if k ~= "fallback" and k ~= "done" and k ~= "mapId" and k ~= "party" then
        startOpts[k] = v
      end
    end
    startOpts.done = g3.done
    local ok, err = false, "the engine's battle bridge is unavailable"
    if BB then
      if g3.kind == "wild" then
        local mon = type(g3.party) == "table" and g3.party[1] or nil
        ok, err = pcall(BB.startWild, nil, game, M.gen3HandedFoe(g3.foe, mon), startOpts)
      else
        startOpts.wild = false
        startOpts.trainerId = startOpts.trainerId or (g3.trainer and g3.trainer.trainerId)
        ok, err = pcall(BB.start, nil, game, g3.foe, startOpts)
      end
    end
    if not ok then
      self:warn("fallback3", "the ordinary battle could not be started again (%s); walk into "
        .. "it again, or reload from your last save", tostring(err))
      -- The engine's own answer to a battle that will not start (BattleBridge's
      -- doStart failure): the waiting script is released as though it was won.
      if type(g3.done) == "function" then pcall(g3.done, "win") end
    end
  end)
  self.handingBack3 = false
  if not okH then
    self:warn("fallback3", "the ordinary battle could not be started again (%s); walk into "
      .. "it again, or reload from your last save", tostring(errH))
  end
end

return M
