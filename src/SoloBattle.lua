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

local need, mod = ...
local Config = need("Config")
local Wire = need("Wire")
local Gen = need("Gen")
local Coop = need("Coop")
local MediatedBattle = need("MediatedBattle")
local SoloBrain = need("SoloBrain")

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

-- How much of each item the trainer's seat is given.
--
-- The bag is a *floor*, not the budget. What actually limits a trainer is the
-- AI's own counter -- `class.uses` on Gen 1, the `items` list Gen 2's AI_TryItem
-- consumes -- and `src/SoloBrain.lua` spends that itself. The referee's bag is
-- underneath it as a possession check (`Turn._bagHas`), and the only failure
-- mode worth avoiding is the bag running out first and turning a gym leader's
-- second FULL HEAL into a refused choice. One per monster the trainer brought
-- cannot bind before the AI's own counter does.
local NPC_ITEM_STOCK = Config.BATTLE_MON_MAX

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
  if generation == 2 then return need("BattleSim2/Turn") end
  return need("BattleSim/Turn")
end

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

local function activeOf(fighter)
  local mon = fighter and fighter.mons and fighter.mons[fighter.active]
  if mon and (tonumber(mon.hp) or 0) > 0 then return mon end
  return nil
end

local function hasLiving(fighter)
  for _, mon in ipairs((fighter and fighter.mons) or {}) do
    if (tonumber(mon.hp) or 0) > 0 then return true end
  end
  return false
end

-- Does this seat owe the referee an answer right now?
--
-- Asked before the brain is, and that is the whole reason it exists:
-- `src/SoloBrain.lua` carries the AI's `aiUses` budget and draws from the
-- engine's RNG, so a speculative call spends a gym leader's FULL HEAL on a turn
-- nobody asked about. `Turn:autoPick` refuses politely when a seat owes
-- nothing; the brain has no way to know.
local function owes(sim, fighter)
  if not (sim and fighter) then return false end
  if fighter.choice ~= nil then return false end
  if fighter.mustReplace then return hasLiving(fighter) end
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
function M.new(ui, opts)
  opts = opts or {}
  return setmetatable({
    ui = ui,
    enabled = opts.enabled,
    seedFn = opts.seed,

    -- The live fight, or nothing. All five are set together and cleared
    -- together: half of a solo battle is not a state this file can be in.
    fight = nil,      -- the MediatedBattle screen
    sim = nil,        -- the Turn refereeing it
    brain = nil,      -- SoloBrain, on a trainer fight with an AI to bridge
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

    -- What the player has shown the AI: move ids in the order they were first
    -- used, and how long their current monster has been out.
    playerMoves = nil,
    playerTurns = 0,
    playerMon = nil,
    playerMove = nil,

    -- Coop.blackout parks its deferred warp here and Coop.pumpBlackout takes
    -- it from here. Ours to own, because a holder that never pumps leaves the
    -- player healed, taxed and standing where they lost.
    pendingWarp = nil,

    -- One warning per fight per reason: this runs inside a per-frame pump, and
    -- a log line a frame describes one fact several hundred times.
    warned = nil,
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

-- The trainer's kit, as a sheet the referee will hold them to.
--
-- `Turn.DEFAULT_NPC_BAG` is the generic gym kit the hub seeds an unclaimed NPC
-- seat with (`Hub.lua:1542`) -- and the hub is the *only* place that does it,
-- so a caller with no hub has to do it itself or field a trainer who cannot
-- reach for anything. On top of it go the items this particular trainer's AI
-- would actually use, which `SoloBrain.itemsFor` reports: the default kit holds
-- none of GIOVANNI's GUARD SPEC, LANCE's HYPER POTION or BRUNO's X DEFEND, and
-- a choice for an item the seat does not hold is simply refused.
--
-- The wild seat gets no bag at all, which is both correct and load-bearing: a
-- seat with no sheet fails `Turn._bagHas`, so `Turn:autoPick` -- the fallback
-- picker, and the only thing answering for a wild monster -- never reaches for
-- an item. A RATTATA with a POTION would be nobody's idea of Gen 1.
local function npcBag(Turn, trainer, data, generation)
  local bag = {}
  for id, count in pairs(Turn.DEFAULT_NPC_BAG or {}) do bag[id] = count end
  local ok, wanted = pcall(SoloBrain.itemsFor, trainer, data, generation)
  if ok and type(wanted) == "table" then
    for _, id in ipairs(wanted) do
      bag[id] = max(bag[id] or 0, NPC_ITEM_STOCK)
    end
  end
  return bag
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
  if kind == "wild" then
    wildMon = Coop.wildMonOf(state)
    if not wildMon then return false end
    enemySheets = MediatedBattle.snapshotMons(game, { wildMon })
  else
    local party = enemyPartyOf(state)
    if not party then return false end
    enemySheets = MediatedBattle.snapshotMons(game, party)
  end
  if type(enemySheets) ~= "table" or #enemySheets == 0 then
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
    mode = mode,
    wildParty = (kind == "wild") and enemySheets or nil,
    wildCatchMon = wildMon,
    onDone = function(result, toLearn) self:_ended(result, toLearn) end,
  })

  local started = fight:start(game)
  local mine = pending.party
  if not (started and type(mine) == "table" and type(mine.mons) == "table"
          and #mine.mons > 0) then
    -- `start` already said why (an empty or undescribable party) and finished
    -- the screen it never pushed. Nothing has been taken over, so the engine's
    -- own battle is still on the stack and still about to run.
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
    } },
    b = { {
      playerId = FOE_SEAT,
      name = (kind == "wild") and (enemySheets[1].species or "WILD")
        or foeName(state),
      mons = enemySheets,
      -- **Nil on the wild path, and it has to be spelled as a branch.**
      -- `(kind == "wild") and nil or npcBag(...)` reads like a ternary and is
      -- not one: `true and nil` is nil, `nil or npcBag(...)` is the bag, so
      -- the wild seat was handed the gym kit on *both* sides of the test. The
      -- symptom is the exact one npcBag's own header says must never happen --
      -- `Turn._autoChoice` reaches for a bag before it reaches for a move, so
      -- a RATTATA was drinking SUPER POTIONs and spraying X ATTACK.
      bag = (kind ~= "wild")
        and npcBag(Turn, SoloBrain.trainerOf(state), game.data, generation)
        or nil,
    } },
  }

  local ruleset = pending.ruleset or {}
  local sim, why = Turn.create({
    id = battleId,
    mode = mode,
    seed = self:_seed(),
    chart = ruleset.chart,
    specialTypes = ruleset.specialTypes,
    metronomePool = ruleset.metronomePool,
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
    self:warn("nosim", "the mod's battle system could not assemble this "
      .. "fight (%s), so it is fought the ordinary way; report this with the "
      .. "battle you were in", tostring(why))
    return false
  end

  -- The opponent's mind. Constructed once per fight and never for a wild one:
  -- there is no trainer record behind a PIDGEY, so there is no per-trainer
  -- behaviour to be faithful to and `Turn:autoPick` is the honest answer.
  -- A nil brain is not a failure and is not logged as one -- see SoloBrain's
  -- header, where declining is the whole error contract.
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
  self.refuseRun, self.failedRun = nil, nil
  self.runAttempts, self.faults = 0, 0
  self.clock, self.seq = 0, 0
  self.playerMoves, self.playerTurns = {}, 0
  self.playerMon, self.playerMove = nil, nil
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
    send = function(_, msgType, payload)
      if msgType == Wire.BATTLE_RULESET then
        pending.ruleset = payload
      elseif msgType == Wire.BATTLE_PARTY then
        -- Side b is the wild encounter the screen was handed; side nil is the
        -- player's own party, which is what side a is built from.
        if payload and payload.side == "b" then
          pending.wild = payload
        else
          pending.party = payload
        end
      elseif msgType == Wire.BATTLE_CHOICE then
        solo:_choose(payload)
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

-- **RUN is decided here, in both of the ways it can go, and nowhere else.**
--
-- The referee's `_resolveRuns` is not gated on the mode and rolls no dice: a
-- `run` from either side ends the fight there and then, and the side that ran
-- is recorded as the loser. Online that is correct -- fleeing a duel is a
-- concession, and a duel has no escape odds -- but neither half of it is
-- single-player's answer, so both halves are answered at this boundary. The
-- referee never learns that RUN was pressed, which is the whole point:
-- `src/BattleSim/Turn.lua` has a JavaScript twin with parity fixtures over it
-- and does not move for this feature.
--
-- ------- a trainer's RUN
--
-- Forwarded, it would mean pressing RUN forfeits the gym, and a forfeit reads
-- as a loss, and a loss blacks the player out. Vanilla refuses: "No! There's
-- no running from a trainer battle!", `afterQueue = "menu"`, and the turn is
-- **not** spent (`BattleState:tryRun`'s trainer arm returns before the roll).
--
-- The refusal *line* is not ours. `MediatedBattle:updateCommand` already says
-- it, on the screen, before it files the choice -- so all this owes is the
-- `turn` that reopens the window the screen believes it has already answered.
-- A second copy of the sentence fed from here is what the player used to read
-- twice, in two consecutive boxes. Leave the line to the screen.
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
  if payload.action == "run" then
    if self.kind == "trainer" then
      self.refuseRun = true
      return false
    end
    if not self:_escapes() then
      self.failedRun = true
      return false
    end
  end
  return sim:submitChoice(PLAYER_SEAT, payload) and true or false
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
-- A throw out of `tick` or `drainEvents` is caught rather than allowed to reach
-- src/Client.lua's pcall, because one bad frame should not take a whole battle
-- down. What that used to hide is the failure that is not a bad frame: a
-- deterministic throw repeats every frame forever. The turn never resolves,
-- `outcome()` stays nil, `SOLO_CHOICE_TIMEOUT` is zero so no deadline arrives
-- -- and in a trainer fight RUN is refused, so the player is left standing in
-- front of a battle screen with no way out of it at all, reading a warning that
-- asks them to "finish or leave this battle" and cannot do either.
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

  -- A RUN the trainer path refused last frame, answered now that the screen has
  -- finished writing over its own choice state. See M:_choose.
  --
  -- **The `turn` and nothing else.** The refusal line is the screen's own --
  -- `MediatedBattle:updateCommand` prints "No! There's no\nrunning from a\n
  -- trainer battle!" before it files the choice -- so a copy fed from here is
  -- the same sentence in a second box. All this owes is the window: vanilla
  -- returns straight to the menu (`afterQueue = "menu"`) and does not spend the
  -- turn, so the seat still owes the referee an answer and the next choice
  -- resolves normally.
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

  self:_answerFoe()
  local faults = self:_drain()

  local ok, err = pcall(sim.tick, sim, floor(self.clock))
  if not ok then
    faults = faults + 1
    self:warn("tick", "the mod's battle referee stopped answering (%s); it is "
      .. "given a few more frames and then this fight is handed back to the "
      .. "ordinary battle system; report it with the fight you were in",
      tostring(err))
  end
  faults = faults + self:_drain()

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

-- What the player has shown, for the layers that read it.
--
-- Both Gen 1's and Gen 2's AI reason about the *player's* history: how long the
-- monster in front of them has been out, and which moves it has used (Gen 2's
-- SMART layer prices its own move against the last one the player played, and
-- its switch score counts how many super-effective moves it has been shown).
-- None of that rides on an event -- the vocabulary has no "a move was used"
-- kind -- so it is read straight off the referee's own copy, where
-- `lastMoveIndex` is exactly the field it was recorded in.
--
-- Recorded only when the entry differs from the previous one, so a player who
-- presses the same move eight times leaves one mark rather than eight. That
-- keeps the list at the length a matchup scan wants and keeps its last entry
-- correct, which is the one thing that has to be.
function M:_trackPlayer()
  local sim = self.sim
  local player = sim and sim.byId and sim.byId[PLAYER_SEAT]
  local mon = player and player.mons and player.mons[player.active]
  if not mon then return end

  if mon ~= self.playerMon then
    -- A different monster is out. The counters the AI reads are per-send-out,
    -- so both reset -- and identity is the only sound test for "the same
    -- monster", since a party can hold two of a species at one level.
    self.playerMon = mon
    self.playerTurns = 0
  else
    self.playerTurns = self.playerTurns + 1
  end

  local index = tonumber(mon.lastMoveIndex) or 0
  local move = index >= 1 and mon.moves and mon.moves[index] or nil
  local id = move and move.id
  if id and id ~= self.playerMove then
    self.playerMove = id
    self.playerMoves[#self.playerMoves + 1] = id
  end
end

-- The opponent's answer for this turn, if it owes one.
--
-- `SoloBrain` first and `Turn:autoPick` behind it, and the fallback is a
-- complete answer rather than a degraded one: it is the same picker that
-- answers for every NPC seat in every hub-refereed fight. The brain makes a
-- good fight better and can never make one fail to run.
--
-- The two speak different index vocabularies and that is the sharpest edge in
-- this file. `autoPick` writes `fighter.choice` directly, so its `move` is
-- one-based and its `slot` is a party index. `submitChoice` normalises from the
-- wire's vocabulary: zero-based `move`, and `slot` is the monster's own party
-- position rather than a count off the array. `SoloBrain` answers in
-- `submitChoice`'s, which is why its result goes through `submitChoice` and
-- must never be assigned to `fighter.choice`.
function M:_answerFoe()
  local sim = self.sim
  local foe = sim and sim.byId and sim.byId[FOE_SEAT]
  if not owes(sim, foe) then return false end

  local brain = self.brain
  if brain then
    -- Tracked here, once, at the moment the opponent is actually asked --
    -- which is also the moment the turn count means something.
    if sim.phase == "choice" then self:_trackPlayer() end
    local player = sim.byId[PLAYER_SEAT]
    local ok, choice = pcall(brain.choose, brain, {
      mon = foe.mons[foe.active],
      foe = player and player.mons and player.mons[player.active] or nil,
      party = foe.mons,
      active = foe.active,
      bag = foe.bag,
      mustReplace = foe.mustReplace and true or false,
      playerUsedMoves = self.playerMoves,
      playerTurns = self.playerTurns,
    })
    if not ok then
      self:warn("brain", "the trainer's own AI could not be asked for a move "
        .. "(%s), so this fight is played with the referee's generic picker; "
        .. "report this with the trainer you were fighting", tostring(choice))
    elseif type(choice) == "table" and sim:submitChoice(FOE_SEAT, choice) then
      return true
    end
  end

  return sim:autoPick(FOE_SEAT) and true or false
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
  local game, engine, sim = self.game, self.engine, self.sim
  local reason, save, levels = self.reason, self.save, self.levels
  -- Released before any of it runs. Everything below can push a screen, and a
  -- screen that pushes is a `screen.pushed` back into the divert -- which must
  -- find no fight in the slot rather than a half-finished one.
  self.fight, self.sim, self.brain = nil, nil, nil
  self.engine, self.game, self.wildMon = nil, nil, nil
  self.kind, self.reason, self.save, self.levels = nil, nil, nil, nil
  self.settled, self.refuseRun, self.failedRun = false, nil, nil
  self.generation, self.runAttempts, self.faults = nil, 0, 0

  if not (game and sim) then return false end

  self:_reconcile(sim, game, save)

  local levelled = M.levelledSince(game, save, levels)
  if engine and levelled then engine.leveledUp = levelled end

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
-- screen and it keeps no such list (`CoopBattle` does; `MediatedBattle` does
-- not, and this file may not change it). The difference between the level a
-- monster had when the fight opened and the level it has now is the same fact
-- by a shorter route -- and a monster the snapshot never saw is one that
-- joined the party during the fight, which is a monster that was caught and
-- has therefore not levelled into anything.
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

  local applied = 0
  for _, mon in ipairs(player.mons) do
    local index = (tonumber(mon.slot) or 0) + 1
    local target = party[index]
    if type(target) == "table" then
      self:_applyMon(target, mon)
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
-- only by luck -- and a Mimic or a Transform rewrites the referee's copy
-- outright. Matching by id makes both harmless: a move the referee is no longer
-- holding simply finds nothing to write to, which is also vanilla's rule (the
-- battle's copy is discarded and the original ids come back).
--
-- Status is the engine's own three-letter token in both places, so it passes
-- through. There is no counter to carry: the engine keeps sleep's on the
-- battler and throws it away with the battle, so a monster that leaves asleep
-- leaves asleep and nothing more.
function M:_applyMon(target, mon)
  if not (type(target) == "table" and type(mon) == "table") then return false end

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
  -- written as an absence rather than as a token nothing branches on.
  target.status = statusToken(mon.status)

  local moves = type(target.moves) == "table" and target.moves or nil
  local simMoves = type(mon.moves) == "table" and mon.moves or nil
  if moves and simMoves then
    local at = 1
    for _, simMove in ipairs(simMoves) do
      local id = simMove.id
      while at <= #moves and moves[at].id ~= id do at = at + 1 end
      if at > #moves then break end
      moves[at].pp = max(0, tonumber(simMove.pp) or 0)
      at = at + 1
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
  local game, fight, engine = self.game, self.fight, self.engine
  self.fight, self.sim, self.brain = nil, nil, nil
  self.engine, self.game, self.wildMon = nil, nil, nil
  self.kind, self.reason, self.save, self.levels = nil, nil, nil, nil
  self.settled, self.pendingWarp, self.refuseRun = false, nil, nil
  self.failedRun, self.generation = nil, nil
  self.runAttempts, self.faults = 0, 0
  self.playerMoves, self.playerTurns = nil, 0
  self.playerMon, self.playerMove = nil, nil
  if game and fight and engine then
    -- Our screen off, the engine's battle back on top, untouched.
    Coop.unwindStackTo(game, engine, false)
  end
  return true
end

return M
