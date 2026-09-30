-- A BattleState-shaped object over a four-slot field.
--
-- **This is the file that makes a co-op battle a real battle rather than a
-- damage calculator.**
--
-- The first cut of this mod reimplemented the turn: roll accuracy, compute
-- damage, subtract HP. That gets you a fight, and it gets you nothing else --
-- no Fly, no Substitute, no Hyper Beam recharge, no stat stages, no Bide, no
-- recoil, no Metronome. Every one of those lives in the engine's
-- `move_effects` registry, and the registry looked unreachable because it is
-- driven by `BattleState`, which is 1v1.
--
-- It is not unreachable, and the reason is worth stating plainly, because it
-- is the whole design:
--
--   **`EffectRegistry`, `MoveEffects` and `StatusRegistry` never read
--   `battle.player` or `battle.enemy`.** Not once. `makeCtx` takes `user` and
--   `target` as arguments, and everything else it wants from the battle it
--   asks for through a method -- `sayNext`, `applyDamage`, `computeDamage`,
--   `accuracyRoll`, `onFaint`, `sideOf`, `performMove`, and about eight more.
--   `BattleState:performMove` is the same: 200 lines, and not one of them
--   mentions either side by name.
--
-- So the pair-shaped thing in the engine is not the effect system. It is
-- `BattleState`'s *bookkeeping* -- which two battlers are out, whose party
-- they came from, where their pictures go. Replace that, keep the rest.
--
-- Which is exactly what this is: a table whose `__index` chain ends at
-- `BattleState`, so every generic method is the engine's own code running
-- unmodified, with the handful that assume two battlers overridden below.
-- `performMove` here **is** `BattleState.performMove`. Fly charges because
-- the engine charges it; Substitute absorbs because the engine absorbs it.
--
-- The overrides, and why each one has to be:
--
--   * `onFaint`   -- BattleState's sends out the next mon from *the* party and
--                    hands out exp; a slot owns its own party and there are
--                    four of them.
--   * `sideOf`    -- two sides indexed by `isPlayer`; here a side has two
--                    slots, and a battler's side is its slot's.
--   * `cancelMoveAnim` -- reads `self.player`/`self.enemy` to un-hide a
--                    digging pic. Same job, resolved through the slots.
--   * the queue drains to **events** rather than to a renderer, because three
--     other clients have to replay it.
--
-- Nothing here is a copy of engine logic. Every override is bookkeeping the
-- engine could not have done for four slots, and everything else is left
-- alone on purpose -- a second implementation of Gen 1's move effects would
-- drift from the first one the day either changed.
--
-- ------- and on Gen 3, the other half of "the engine's battle"
--
-- FireRed, LeafGreen and Emerald never get the adapter above: co-op there is
-- refereed by the hub's BattleSim3 (like Gold's by BattleSim2), and the Gen 1
-- `src.battle.BattleState` this file would inherit is a boot error on
-- Emerald.  What a Gen 3 boot needs from this file instead is the *stand-in*
-- (the section at the bottom): the object every co-op / solo divert hands its
-- result to when the engine's own battle was never started.  On Gen 1 / Gen 2
-- that object is the engine's pushed BattleState, buried under the mod's
-- screen; on Gen 3 the divert cancels the cart's fight before it exists
-- (`encounter.roll` for a wild, a wrap of battle_bridge.lua BattleBridge.start
-- for a trainer), so the stand-in is built here, shaped like that buried
-- BattleState, and its `onFinish` runs the cart's own post-battle flow.

local need, mod = ...
local Gen = need("Gen")
local Config = need("Config")
local Wire = need("Wire")
local Gen3 = need("Gen3")
local Gen3Ui = need("Gen3Ui")

local M = {}

-- Built on first use, because `BattleState` is the metatable's parent and
-- requiring it at file scope would drag the whole renderer into a headless
-- validate.
local Field, engine

-- deps: { BattleState, Strings } -- handed in by CoopBattle, which is the only
-- caller that has an engine to hand.
function M.build(deps)
  -- Gen 2: never inherit Gen1 BattleState. Hub-mediated co-op replays
  -- BattleSim2 events; host-sim CoopField would silent-corrupt via MK403.
  local generation = Gen.generation(deps and deps.game)
  if generation == 2 then
    mod.log:warn("CoopField (Gen1 BattleState host-sim) is disabled on Gen 2; "
      .. "use hub-mediated co-op on a Gen 2 hub (BattleSim2) instead")
    return nil
  end
  -- Gen 3: the same refusal, and a harder one -- on Emerald the Gen 1
  -- BattleState a caller would hand in is the dead module the loader logs a
  -- boot error for.  Co-op there is BattleSim3's, on a Gen 3 hub.
  if generation == 3 then
    mod.log:warn("CoopField (Gen1 BattleState host-sim) is disabled on Gen 3; "
      .. "use hub-mediated co-op on a Gen 3 hub (BattleSim3) instead")
    return nil
  end
  -- Keyed on the engine it was built against, not merely on "has one been
  -- built". `F5` in dev mode re-requires the engine's modules, and a cache
  -- that only asked whether it was populated kept handing back a metatable
  -- whose __index pointed at the *previous* BattleState -- so a hot reload was
  -- silently ignored inside co-op battles while every other path picked it up.
  if Field and engine and engine.BattleState == deps.BattleState then
    return Field
  end
  engine = deps
  local BattleState = deps.BattleState
  if type(BattleState) ~= "table" then
    mod.log:warn("CoopField needs Gen1 BattleState; refusing construction -- "
      .. "report this with the game version")
    return nil
  end

  Field = setmetatable({}, { __index = BattleState })
  Field.__index = Field

  -- ------- the queue, drained to events
  --
  -- BattleState's queue rows are consumed by its own renderer a frame at a
  -- time. Here they are consumed by `drain` below and turned into the event
  -- list the other three clients replay, so a row that only means something
  -- to a 1v1 screen (a wait, a menu) is dropped rather than faked. Drain rows
  -- are *not* among the dropped ones any more: they are the engine's own
  -- pacing for the HP bar, one per strike with the stop it should halt at, and
  -- throwing them away is what made a multi-hit move show one silent jump
  -- instead of five. `fn` rows are *run*, because that is where the engine
  -- parks the state changes that go with an animation.

  function Field:say(text)
    table.insert(self.queue, { text = text })
  end

  function Field:sayNext(text)
    self.nextInsert = (self.nextInsert or 0) + 1
    table.insert(self.queue, self.nextInsert, { text = text })
  end

  function Field:act(fn)
    table.insert(self.queue, { fn = fn })
  end

  function Field:actNext(fn)
    self.nextInsert = (self.nextInsert or 0) + 1
    table.insert(self.queue, self.nextInsert, { fn = fn })
  end

  -- Animations are named in the events so a client that wants to draw one
  -- can, and dropped by the ones that do not. The mod's own battle screen
  -- does not play them: the engine's AnimPlayer is written against two pic
  -- positions, and a wrong animation is worse than none.
  function Field:animNext(name, isPlayer, shakes, ball)
    self.nextInsert = (self.nextInsert or 0) + 1
    table.insert(self.queue, self.nextInsert,
      { anim = name, attackerIsPlayer = isPlayer, shakes = shakes, ball = ball })
  end

  -- The engine schedules one of these per HP change, carrying the battler and
  -- the HP its bar is allowed to stop at. That pair is the whole of Gen 1's
  -- pacing: a multi-hit move takes every strike off the model while the turn
  -- is still being queued, so the *rows* are what remember that the bar should
  -- have paused five times on the way down.
  --
  -- It is kept, not dropped. The row is carried through to `M.drain` below and
  -- becomes an event, so the four screens animate the same descent instead of
  -- each snapping to whatever HP the mon happened to hold when the turn ended.
  -- `drain` holds the battler itself rather than a flag because that is the
  -- only handle on *whose* bar this is; when the engine calls with no battler
  -- (a poison tick, a Recover) the row still has to be here and the same
  -- length, because the `nextInsert` cursor counts rows and `cancelMoveAnim`
  -- indexes past them -- so it keeps a bare marker that resolves to no slot
  -- and is skipped downstream.
  function Field:drainNext(battler, stopAt)
    self.nextInsert = (self.nextInsert or 0) + 1
    table.insert(self.queue, self.nextInsert,
      { drain = battler or true, stopAt = stopAt })
  end

  function Field:ui() end
  function Field:uiNext() end
  function Field:animationsOn() return false end

  -- ------- the four-slot overrides

  function Field:slotOf(battler)
    for _, slot in ipairs(self.slots) do
      if slot.battler == battler then return slot end
    end
    return nil
  end

  -- A side is the two slots that share one. `sides[1]` is the local player's
  -- side so that any engine code reading `sideOf(x).screens` keeps working --
  -- Reflect and Light Screen are side-wide in Gen 1, and in a 2-on-2 that
  -- means they cover your partner too, which is the correct reading of a
  -- rule the original never had to be specific about.
  function Field:sideOf(battler)
    local slot = self:slotOf(battler)
    local side = slot and slot.side or "a"
    return side == "a" and self.sides[1] or self.sides[2]
  end

  -- The engine's cancel, with the two battlers it reaches for resolved
  -- through the slots instead.
  function Field:cancelMoveAnim()
    local row = self.moveAnimRow
    if not row then return end
    self.moveAnimRow = nil
    if row.anim == "DIG" or row.anim == "FLY" then
      for _, slot in ipairs(self.slots) do
        local battler = slot.battler
        if battler and battler.isPlayer == row.attackerIsPlayer then
          local pf = self.picFx and self.picFx[battler]
          if pf then pf.hidden = nil end
        end
      end
    end
    for i, item in ipairs(self.queue) do
      if item == row then
        table.remove(self.queue, i)
        if self.nextInsert and i <= self.nextInsert then
          self.nextInsert = self.nextInsert - 1
        end
        return
      end
    end
  end

  -- A faint, four-slot style.
  --
  -- No exp and no send-out here: exp is the sim's to award (it knows whose
  -- party the beaten mon belonged to) and the send-out has to happen where
  -- the turn loop can see it, so both are left to CoopSim. What this keeps is
  -- the one thing the engine's version does that matters to the effect
  -- registry -- marking the battler down exactly once, so a move that hits a
  -- fainted target does not faint it twice.
  function Field:onFaint(battler)
    if battler.faintQueued then return end
    battler.faintQueued = true
    battler.fainted = true
    local slot = self:slotOf(battler)
    if slot then self.fainted[#self.fainted + 1] = slot end
  end

  -- Never a wild battle and never the old man: `kind = "link"` is the honest
  -- answer and it is load-bearing in one place. Under `gen1_faithful` the
  -- enemy side does not spend PP -- a rule about an AI Gen 1 never bothered
  -- to decrement -- and applying it here would have the four clients disagree
  -- about an NPC's PP within a turn or two, exactly as it once broke the
  -- engine's own link battles.
  function Field:battleKind() return "link" end

  return Field
end

-- ------- construction

-- slots is CoopSim's own list; the field reads them live rather than copying,
-- so a send-out done by the sim is visible to the next move resolved here.
function M.new(deps, game, slots, ruleset)
  deps = deps or {}
  if deps.game == nil then deps.game = game end
  local generation = Gen.generation(game or deps.game)
  if generation == 2 then
    mod.log:warn("CoopField (Gen1 BattleState host-sim) is disabled on Gen 2; "
      .. "use hub-mediated co-op on a Gen 2 hub (BattleSim2) instead")
    return nil
  end
  if generation == 3 then
    mod.log:warn("CoopField (Gen1 BattleState host-sim) is disabled on Gen 3; "
      .. "use hub-mediated co-op on a Gen 3 hub (BattleSim3) instead")
    return nil
  end
  local Cls = M.build(deps)
  if not Cls then return nil end
  local self = setmetatable({
    game = game,
    data = game.data,
    ruleset = ruleset,
    slots = slots,
    kind = "link",
    queue = {},
    nextInsert = 0,
    fainted = {},
    picFx = {},
    sides = {
      { index = 1, battlers = {}, screens = {}, hazards = {}, tokens = {} },
      { index = 2, battlers = {}, screens = {}, hazards = {}, tokens = {} },
    },
    rng = deps.rng or function(a, b) return a end,
  }, Cls)
  self.field = { weather = nil, tokens = {}, sides = self.sides }

  -- The type chart is process-global state the engine primes when it builds a
  -- battle, and every damage calculation reads it. Primed here rather than
  -- left to the caller: this object is the thing that resolves moves, so a
  -- caller that forgot would get "TypeChart.load not called" out of the middle
  -- of somebody's turn -- which is exactly how this was found.
  local ok, TypeChart = pcall(require, "src.battle.TypeChart")
  if ok and TypeChart and TypeChart.load then
    pcall(TypeChart.load, game.data)
  end
  return self
end

-- Run everything the queue has collected, and hand back the events it means.
--
-- `fn` rows are executed rather than emitted: the engine parks real state
-- changes in them (a status landing, a stat stage settling) alongside the
-- cosmetics, so skipping them would drop half of what a move did.
function M.drain(field)
  local events = {}
  local guard = 0
  while #field.queue > 0 do
    guard = guard + 1
    -- A move effect that queues work which queues more work is ordinary
    -- (Metronome into a multi-hit); a row that queues itself is not. The cap
    -- is far above any real turn and stops a bad record hanging the game.
    if guard > 512 then
      mod.log:warn("a co-op turn queued more than 512 rows and was cut short; "
        .. "the battle continues -- report the move that did it")
      break
    end
    local row = table.remove(field.queue, 1)
    field.nextInsert = 0
    if row.text then
      events[#events + 1] = { kind = "msg", text = tostring(row.text) }
    elseif row.fn then
      local ok, err = pcall(row.fn)
      if not ok then
        mod.log:warn("a queued battle step failed (%s); the turn continues",
          tostring(err))
      end
    elseif row.anim then
      events[#events + 1] = {
        kind = "anim",
        anim = tostring(row.anim),
        -- Kept so a screen that plays the flash can face it the way the
        -- engine queued it (player vs enemy transform), not only by slot.
        attackerIsPlayer = row.attackerIsPlayer,
      }
    elseif row.drain then
      -- The bar's next resting place, named by slot so a client can animate
      -- somebody else's monster down to it. `to` is an absolute HP, not a
      -- delta: the engine pins the stop rather than the amount precisely so
      -- five strikes of Fury Attack each get their own halt, and a delta
      -- replayed against a copy that had already been told about hit four
      -- would land somewhere nobody's HP ever was.
      --
      -- A row whose battler is not on the field is skipped rather than
      -- reported: the engine's bare `drainNext()` (a poison tick, a Recover)
      -- says only "a bar moved" and there is no honest slot to put on it.
      local slot = field:slotOf(row.drain)
      local to = tonumber(row.stopAt)
      if slot and to then
        events[#events + 1] = { kind = "drain", slot = slot.index, to = to }
      end
    end
  end
  return events
end

-- =====================================================================
-- Gen 3: the stand-in for the battle a divert took
-- =====================================================================
--
-- On Gen 1 and Gen 2 a co-op or solo divert *stands in* for the engine's
-- battle: the engine pushes its BattleState, the divert buries it under the
-- mod's screen, and at the end hands it a result through `onFinish` -- which is
-- the overworld's whole post-battle flow (the trainer flag, the rewards, the
-- whiteout, the script waiting in front of the trainer).  src/Coop.lua's
-- `finishBuriedBattle` is written against that object, and so is
-- src/SoloBattle.lua.
--
-- A Gen 3 boot has no such object to bury.  FireRed / Emerald battles are
-- module-driven (src/core/game3/battle_bridge.lua -> battle/init.lua), no
-- `screen.pushed` is ever raised, and by the time a battle exists it is
-- already the cart's.  So the divert happens one step earlier -- the wild
-- encounter is cancelled at `encounter.roll` and a trainer at
-- BattleBridge.start -- and this section builds the object the rest of the mod
-- expects to find buried: `kind`, `enemyParty` (Gen 3 party mons built the way
-- battle/init.lua builds a foe), `trainer`, `checkpointOrigin`, and an
-- `onFinish` that runs what battle_bridge.lua's own `finish` would have run for
-- a fight it did not run itself:
--
--   * `session.battleOutcome` (B_OUTCOME_*), which scripts read back;
--   * a loss: the cart's whiteout -- BattleBridge.applyWhiteoutMoneyLoss (FRLG's
--     level x badge table, Emerald's half) and Field.respawnAtHeal -- or, for a
--     rival fight the cart lets you lose (noWhiteout / EARLY_RIVAL bit 0), the
--     heal-and-carry-on instead;
--   * the map music back, Space.returnToField (the map's ON_RESUME /
--     ON_RETURN_TO_FIELD scripts), and finally the trainerbattle opcode's own
--     `done(result)`, which is what sets the trainer flag on a win, jumps to
--     the CONTINUE_SCRIPT and ticks the script VM on.
--
-- A draw that is not a whiteout (a refereed fight that could not finish, a
-- lost connection -- a draw that leaves this player's team standing) is never
-- handed to the opcode at all.  The opcode has no third answer: "lose" skips
-- the flag but then runs the post-battle bytes after the trainerbattle
-- command (a gym leader's TM, the badge branch), and anything else marks the
-- trainer beaten.  So the script waiting on the trainer is halted instead
-- (Vm:halt, what the cart's own whiteout does to it), with no whiteout: the
-- trainer stays unbeaten, nothing after the battle runs, and nobody is sent to
-- a POKeMON CENTER for a fight nobody lost.  A draw that *does* leave the team
-- on nothing is a whiteout on the cart (pret IsPlayerDefeated counts
-- B_OUTCOME_DREW) and reaches here as "lose" -- Coop.finishBuriedBattle and
-- SoloBattle both map it.
--
-- While a divert is deciding (a co-op wait for the partner) the stand-in is
-- also the *cover*: a Gen 3 layer holding the field still, with the cart's
-- dialogue box saying what was met.  On Gen 1 / Gen 2 the engine's own
-- encounter intro plays during that wait; on Gen 3 nothing would, so the layer
-- is the whole of what the waiter sees for the fraction of a second the join
-- takes.  `fightAlone` hands the encounter back -- it takes the cover down and
-- starts the cart's own battle with exactly the arguments it was cancelled
-- with -- and is what Coop:release and SoloBattle's give-up path call.
--
-- A stand-in belongs to the save that was running when it was built
-- (`session`).  A load or a soft reset replaces the session (and a return to
-- the title clears it) while the stand-in can still be held -- a co-op wait's
-- clock, a dropped connection's release, the deferred queue below -- so
-- neither `fightAlone` nor `finish` does anything to a world other than its
-- own: the old fight is never started in the new file, and the new file's
-- script VM is never handed the old one's result.
--
-- ------- the BattleBridge.start wrap (an engine_internals reach-around)
--
-- The trainer opcode (scripting/ops_a.lua trainerbattle / dotrainerbattle)
-- does reach mods through `script.command`, but the only thing a hook there
-- could do is replace the *whole* opcode -- rematch rules, the already-beaten
-- skip, the double-battle check, the intro text, the trainer turning to face
-- the player -- and then suspend the VM through its private `nativePoll`.
-- The fight itself starts in one place, BattleBridge.start (via the VM
-- adapter's startTrainerBattle), with the opcode's `done` in its opts.  So
-- that one function is wrapped, through Gen3.wrapFn (the one wrapping
-- discipline this port has: a hot reload peels this mod's own previous
-- wrapper rather than stacking on it, another mod's wrapper on top is kept in
-- the chain, and an older wrapper of ours left inside one goes inert).  The
-- wrap is inert unless this mod instance is the loaded one, it only ever
-- takes a standard trainer fight a divert actually wants
-- (Config.SOLO_REFUSED_GEN3 is refused, link / headless pass straight
-- through, and so does a start this mod itself makes to hand a fight back --
-- `HANDBACK3` below).
--
-- Nothing in production takes the wrap off, and nothing has to.  The loader
-- has no unload callback for a mod (a rollback removes its events, hooks and
-- exports and runs none of its code), so there is no moment to call
-- restoreStart3 from.  The wrapper retires itself instead: every call first
-- asks `alive()` (a rolled-back mod has no exports; a hot-reloaded one has
-- new ones) and Gen3.wrapLive (a newer wrapper of ours replaced it), and on
-- either answer it is a straight call to what it wrapped.  restoreStart3 is
-- the explicit form of the same retirement, kept for the suite and for a
-- future unload point.  docs/upstream/gen3-spawn-npc.md asks upstream for the
-- seam that would retire the wrap altogether.

local floor = math.floor

local function g3(name) return Gen3.engine(name) end

local function try3(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, a, b, c = pcall(fn, ...)
  if ok then return a, b, c end
  return nil
end

-- Is this mod instance the loaded one?  mod.find answers nil for a mod the
-- loader rolled back, and a hot reload hands the new instance a new exports
-- table -- either way a wrapper left behind by that instance must answer what
-- the engine would.  Same test as src/Cast.lua's.
local function alive()
  local ok, handle = pcall(mod.find, Config.MOD_ID)
  return ok and type(handle) == "table" and handle.exports == mod.exports
end
M.alive3 = alive

-- The key a start this mod makes to hand a fight back carries in its opts.
-- A step encounter handed back is started through BattleBridge.startWild,
-- which calls the module's `start` -- this file's wrapper -- and the wrapper
-- must pass it straight to the cart rather than offer it to a divert again
-- (a co-op wait that timed out would otherwise open the same wait, forever).
-- In the opts rather than in a flag beside them, so it marks that one call
-- and nothing after it, and survives another mod's wrapper in the chain.
M.HANDBACK3 = "__rby_mmo_handback"

-- pret SPECIES_EGG, and the engine's Pokemon.isEgg rule (src/core/game3/
-- pokemon.lua): an egg is carried in the party but is never a fighter -- it is
-- not on a sheet, not on a bench, and not "standing" when a whiteout is
-- asked.  Stated here once for Coop, CoopBattle and CoopSim.
local SPECIES_EGG3 = 412
function M.isEgg3(mon)
  if type(mon) ~= "table" then return false end
  return mon.isEgg == true or mon.egg == true
    or tonumber(mon.species or mon.speciesId) == SPECIES_EGG3
end

-- ------- which fights a divert may take

-- The first refused kind any of these tables carries (Config.SOLO_REFUSED_GEN3
-- names every key and why), or nil.  The battle start opts, the wild `foe`
-- and the encounter are all asked, the way SoloBattle.refused asks a state and
-- its inner battle.
function M.refused3(...)
  local list = Config.SOLO_REFUSED_GEN3 or {}
  for i = 1, select("#", ...) do
    local t = select(i, ...)
    if type(t) == "table" then
      for _, key in ipairs(list) do
        if t[key] then return key end
      end
    end
  end
  return nil
end

local function storeOf(Space)
  if type(Space) ~= "table" then return nil end
  if type(Space.getStore) == "function" then
    local ok, store = pcall(Space.getStore)
    if ok and store then return store end
  end
  return Space.store
end

-- battle_bridge.lua safari_mode_active: the profile's own safari when it
-- has one (Emerald), else the session's, else FLAG_SYS_SAFARI_MODE.
local SAFARI_FLAG = 0x800
function M.safari3(session)
  local Profile = g3("src.core.game3.battle.profile")
  local prof = Profile and try3(Profile.get, session)
  if type(prof) == "table" and prof.safari then
    local Safari = g3("src.core.game3.safari")
    return (Safari and try3(Safari.isActive, session)) == true
  end
  if type(session) == "table" and type(session.safari) == "table" and session.safari.active then
    return true
  end
  local Space, Flags = g3("src.core.game3.scripting.space"), g3("src.core.game3.scripting.flags")
  local store = storeOf(Space)
  if not (store and Flags and type(Flags.getFlag) == "function") then return false end
  return try3(Flags.getFlag, store, nil, SAFARI_FLAG) and true or false
end

-- battle/init.lua ghost_battle: a wild met on a POKeMON TOWER floor without
-- the SILPH SCOPE is the Marowak ghost's kind of fight (FireRed only; the
-- profile says whether this cart has the kind at all).
local ITEM_SILPH_SCOPE = 359
function M.ghost3(mapId, session)
  if type(mapId) ~= "string" or not mapId:match("^FR_POKEMON_TOWER_%dF$") then return false end
  local Profile = g3("src.core.game3.battle.profile")
  local prof = Profile and try3(Profile.get, session)
  if type(prof) == "table" and type(prof.kinds) == "table" and not prof.kinds.ghost then
    return false
  end
  local Bag = g3("src.core.game3.bag")
  if Bag and type(session) == "table" and session.bag
     and try3(Bag.has, session.bag, ITEM_SILPH_SCOPE, 1) then
    return false
  end
  return true
end

local function family3(session)
  local Profile = g3("src.core.game3.battle.profile")
  local prof = Profile and try3(Profile.get, session)
  if type(prof) == "table" and type(prof.family) == "string" then return prof.family end
  return Gen3.family()
end

-- ------- the monsters, built the way the cart builds a foe
--
-- battle/init.lua foe_mon_from, in the mod's hands: the personality the cart
-- would roll (Random32) unless the encounter fixed one, the IVs from two
-- Random() halves, the wild held-item roll (FRLG: the species' common / rare
-- item at 50% / 5%; Emerald: its own wildHeldItem), the level's moves when
-- none were given, and the stats through the engine's own Pokemon.applyStats.
-- A trainer's monsters keep the trainer row's IVs, EVs, moves and item.

local function rng3()
  local Rng = g3("src.core.game3.rng")
  local function word()
    local v = Rng and try3(Rng.Random)
    if tonumber(v) then return floor(tonumber(v)) % 65536 end
    return math.random(0, 65535)
  end
  local function dword()
    local v = Rng and try3(Rng.Random32)
    if tonumber(v) then return floor(tonumber(v)) % 4294967296 end
    return word() * 65536 + word()
  end
  return word, dword
end

local function zeros()
  return { hp = 0, atk = 0, def = 0, spe = 0, spa = 0, spd = 0 }
end

local function copyStats(src)
  if type(src) ~= "table" then return nil end
  local out = {}
  for _, k in ipairs({ "hp", "atk", "def", "spe", "spa", "spd" }) do
    out[k] = math.max(0, floor(tonumber(src[k]) or 0))
  end
  return out
end

local function buildMon(P, spec, opts)
  opts = opts or {}
  local species = tonumber(spec.speciesId) or tonumber(spec.species)
  if not species and spec.species ~= nil and type(P.speciesFromName) == "function" then
    species = tonumber(try3(P.speciesFromName, spec.species))
  end
  if not species or species < 1 then return nil, "no species" end
  local level = math.max(1, math.min(100, floor(tonumber(spec.level) or 5)))
  local word, dword = rng3()
  local personality = tonumber(spec.personality)
  if personality == nil then personality = dword() end
  personality = floor(personality) % 4294967296
  local ivs = copyStats(spec.ivs)
  if not ivs then
    local iv1, iv2 = word(), word()
    ivs = {
      hp = iv1 % 32, atk = floor(iv1 / 32) % 32, def = floor(iv1 / 1024) % 32,
      spe = iv2 % 32, spa = floor(iv2 / 32) % 32, spd = floor(iv2 / 1024) % 32,
    }
  end
  local item = tonumber(spec.heldItem) or tonumber(spec.item)
  if item == nil and opts.wild then
    if opts.family == "rse" then
      local Encounters = g3("src.core.game3.encounters")
      local rules = Encounters and try3(Encounters.rules)
      item = rules and tonumber(try3(rules.wildHeldItem, species, {})) or nil
    else
      local meta = try3(P.speciesMeta, species)
      local common = tonumber(type(meta) == "table" and meta.itemCommon) or 0
      local rare = tonumber(type(meta) == "table" and meta.itemRare) or 0
      if common ~= 0 or rare ~= 0 then
        local r = word() % 100
        if common ~= 0 and rare ~= 0 then
          if r < 50 then item = common elseif r < 55 then item = rare end
        elseif common ~= 0 then
          if r < 50 then item = common end
        elseif r < 5 then
          item = rare
        end
      end
    end
  end
  item = floor(tonumber(item) or 0)
  local moves, pp, maxPp = nil, nil, nil
  if type(spec.moves) == "table" and #spec.moves > 0 then
    moves, pp, maxPp = {}, {}, {}
    for _, m in ipairs(spec.moves) do
      local id = tonumber(type(m) == "table" and (m.id or m.num) or m)
      if id and id > 0 and #moves < 4 then
        moves[#moves + 1] = floor(id)
        local full = tonumber(try3(P.movePp, id)) or (Gen3.moveInfo(id) or {}).pp or 0
        maxPp[#maxPp + 1] = full
        pp[#pp + 1] = full
      end
    end
  end
  if not moves or #moves == 0 then
    moves, pp, maxPp = try3(P.movesAtLevel, species, level)
    if type(moves) ~= "table" or #moves == 0 then return nil, "no moves at this level" end
    if type(maxPp) ~= "table" then
      maxPp = {}
      for i, m in ipairs(moves) do maxPp[i] = tonumber(try3(P.movePp, m)) or 0 end
    end
    if type(pp) ~= "table" then
      pp = {}
      for i in ipairs(moves) do pp[i] = maxPp[i] end
    end
  end
  local meta = try3(P.speciesMeta, species)
  local growth = tonumber(type(meta) == "table" and meta.growthRate) or 0
  local SummaryData = g3("src.core.game3.summary_data")
  local ability = tonumber(spec.ability) or tonumber(try3(P.abilityId, species, personality)) or 0
  local mon = {
    species = species, speciesId = species,
    speciesNumbering = P.NUMBERING_INTERNAL or "internal",
    name = try3(P.name, species),
    nickname = "",
    level = level, metLevel = level,
    growthRate = growth,
    exp = tonumber(SummaryData and try3(SummaryData.expForLevel, growth, level)) or 0,
    personality = personality,
    nature = tonumber(try3(P.natureId, personality)) or (personality % 25),
    ivs = ivs,
    evs = copyStats(spec.evs) or zeros(),
    ability = ability, abilityId = ability,
    gender = try3(P.gender, species, personality) or "U",
    heldItem = item, item = item,
    moves = moves, pp = pp, maxPp = maxPp,
    -- The species' base friendship: Pokemon.baseFriendship reads the meta
    -- row's `friendship` (there is no `baseFriendship` key on it -- reading
    -- that one handed every wild monster 70).
    friendship = tonumber(spec.friendship)
      or tonumber(try3(P.baseFriendship, species))
      or tonumber(type(meta) == "table" and meta.friendship) or 70,
    pokerus = 0,
  }
  if not try3(function() P.applyStats(mon) return true end) then
    return nil, "no stats"
  end
  mon.hp = tonumber(mon.maxHp) or mon.hp
  mon.status = nil
  return mon
end

-- A wild encounter's monster.  `enc` is what `encounter.roll` returned (the
-- mod-facing shape: `speciesId` numeric, `species` the engine's key name) or
-- the engine's own (numeric `species`).
function M.wildMon3(enc, session)
  if type(enc) ~= "table" then return nil, "no encounter" end
  local P = g3("src.core.game3.pokemon")
  if not P then return nil, "the engine's POKeMON module is unavailable" end
  return buildMon(P, enc, { wild = true, family = family3(session) })
end

-- src/SoloBattle.lua's Gen 3 foe builders, reached when a fight is built
-- rather than at load: SoloBattle needs Coop and Coop needs this file, so a
-- file-scope need() here would be a cycle the resolver refuses.  By the time a
-- trainer is met every module is loaded and this is a cache hit.
local function solo3()
  if type(need) ~= "function" then return nil end
  local ok, Solo = pcall(need, "SoloBattle")
  if ok and type(Solo) == "table" and type(Solo.gen3TrainerParty) == "function" then
    return Solo
  end
  return nil
end

-- A trainer's whole party (Trainers.foeFromId's `party`, lead first), built
-- the way the cart and a solo fight build it, so a co-op 2v2, a solo 1v1 and
-- the cart's own battle meet the same monsters: the `trainer.party` hook
-- another mod may wrap (battle_bridge.lua hooked_trainer_party, which the
-- divert steps around), the pret personalities (CreateNPCTrainerParty's
-- trainer-and-species name hash -- which fixes each monster's nature, gender
-- and ability; a Random32 per monster gave a gym leader's ace a different
-- nature on every visit), the row's IVs, moves and item.  Those builders are
-- SoloBattle's (`gen3HookedFoe`, `gen3TrainerParty`) -- one statement of
-- them, not two that drift.  The mod's own buildMon is the fallback for a
-- graph without SoloBattle (never in play).
--
-- -> party, nil, the (hooked) foe the party came from; nil + reason.
function M.trainerParty3(foe, trainerId)
  if type(foe) ~= "table" then return nil, "no trainer" end
  local tid = tonumber(trainerId) or tonumber(foe.trainerId)
  local Solo = solo3()
  if Solo then
    local hooked = foe
    if type(Solo.gen3HookedFoe) == "function" then
      local okH, got = pcall(Solo.gen3HookedFoe, foe, tid)
      if okH and type(got) == "table" then hooked = got end
    end
    local ok, party = pcall(Solo.gen3TrainerParty, hooked, tid)
    if not ok then return nil, tostring(party) end
    if type(party) ~= "table" or #party == 0 then return nil, "no monsters" end
    return party, nil, hooked
  end
  local P = g3("src.core.game3.pokemon")
  if not P then return nil, "the engine's POKeMON module is unavailable" end
  local specs = type(foe.party) == "table" and #foe.party > 0 and foe.party or { foe }
  local out = {}
  for _, spec in ipairs(specs) do
    local mon, why = buildMon(P, spec, { wild = false })
    if not mon then return nil, why end
    out[#out + 1] = mon
  end
  return out, nil, foe
end

local function label3(text)
  if type(text) ~= "string" then return nil end
  local clean = Gen3.cleanText and Gen3.cleanText(text) or text
  clean = clean:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
  if clean == "" then return nil end
  return clean
end

-- The trainer record every co-op / solo screen reads, from the foe the
-- opcode resolved (or, for a client that never walked into them, from the
-- trainer id alone).  `id` is the string a co-op field carries on the wire;
-- `trainerId` the number the cart's tables and Gen.playBattleMusic read.
function M.trainerRecord3(foe, opts)
  opts = opts or {}
  if type(foe) ~= "table" then
    local tid = tonumber(foe)
    local Trainers = g3("src.core.game3.scripting.trainers")
    foe = tid and Trainers and try3(Trainers.foeFromId, tid) or nil
    if type(foe) ~= "table" then return nil end
  end
  local tid = tonumber(opts.trainerId) or tonumber(foe.trainerId)
  if not tid then return nil end
  local className = label3(foe.trainerClassName or opts.trainerClassName)
  -- The name the cart prints: Trainers.info with the player's rival's name,
  -- which is what replaces the rival and champion rows' placeholder
  -- (pret battle_message.c; the engine's battle reads session.rivalName the
  -- same way).  The foe record carries the placeholder itself.
  local Trainers = g3("src.core.game3.scripting.trainers")
  local session = Gen3.session()
  local rival = type(session) == "table" and session.rivalName or nil
  if (type(rival) ~= "string" or rival == "") and type(opts.game) == "table"
     and type(opts.game.save) == "table" then
    rival = opts.game.save.rivalName
  end
  local info = Trainers and try3(Trainers.info, tid,
    { rivalName = type(rival) == "string" and rival or nil }) or nil
  local name = label3(type(info) == "table" and info.name or nil)
    or label3(foe.trainerName or opts.trainerName)
  local pic = tonumber(foe.trainerPic) or tonumber(opts.trainerPicId)
  return {
    id = tostring(tid),
    trainerId = tid,
    trainerClass = tonumber(foe.trainerClass) or tonumber(opts.trainerClass),
    class = tonumber(foe.trainerClass) or tonumber(opts.trainerClass),
    className = className,
    name = name,
    trainerPic = pic, pic = pic,
    items = foe.items,
    aiFlags = foe.aiFlags,
    doubleBattle = foe.doubleBattle and true or false,
    gender = foe.gender,
  }
end

-- "BUG CATCHER RICK", cut to what a co-op label carries on the wire.
function M.trainerLabel3(trainer)
  if type(trainer) ~= "table" then return nil end
  local parts = {}
  if trainer.className then parts[#parts + 1] = trainer.className end
  if trainer.name then parts[#parts + 1] = trainer.name end
  return Wire.label(table.concat(parts, " "))
end

-- The co-op origin id a Gen 3 trainer rides the wire under (Wire.npcId is an
-- id string): the cart's own trainer number, which is unique per trainer and
-- the same on every copy of the same cart -- so an invite joiner can mark the
-- very trainer their partner walked into beaten, and nothing else.
function M.originId3(trainerId)
  local tid = tonumber(trainerId)
  if not tid then return nil end
  return "g3t" .. tostring(floor(tid))
end

function M.originTrainer3(npcId)
  if type(npcId) ~= "string" then return nil end
  return tonumber(npcId:match("^g3t(%d+)$"))
end

-- The trainer number a map object's script fights now: its own, or -- a
-- rematch -- the row the cart's rematch table has it on today (FRLG's VS
-- Seeker tiers, Emerald's match-call table), which is the id the
-- trainerbattle opcode hands the fight (its `opponentA`).
local function rematchOf3(base, session)
  local out = {}
  local VsSeeker = g3("src.core.game3.vs_seeker")
  local Space = g3("src.core.game3.scripting.space")
  if VsSeeker and type(VsSeeker.rematchTrainerId) == "function" then
    local got = tonumber(try3(VsSeeker.rematchTrainerId, base, storeOf(Space)))
    if got and got > 0 then out[#out + 1] = got end
  end
  if session and family3(session) == "rse" then
    local Rematch = g3("src.core.game3.rse.rematch")
    if Rematch and type(Rematch.rematchTrainerId) == "function" then
      local got = tonumber(try3(Rematch.rematchTrainerId, session, base))
      if got and got > 0 then out[#out + 1] = got end
    end
  end
  return out
end

-- Is trainer `trainerId` one of the trainers standing on the map this client
-- is on?  Every object event the engine has loaded here is asked for the
-- trainer its script fights (trainer_sight.lua getTrainerId -- the object's
-- own trainerId, else the trainerbattle command in its script), and a rematch
-- answers for the row it would fight today.
--
-- This is what binds an invite joiner's synthetic finish (Coop's
-- syntheticFinish3) to their own world: the trainer number and the fight's
-- trainer record both arrived over the wire, from a partner, and agreeing
-- with each other proves nothing -- a partner could name a gym leader three
-- towns away and have this client set that leader's flag and pay their prize.
-- The object has to be here, on this client's own map.  False (never a
-- guess) when the engine's objects cannot be read.
function M.trainerOnMap3(trainerId)
  local tid = tonumber(trainerId)
  if not tid then return false end
  local Objects = g3("src.core.game3.objects")
  local Sight = g3("src.core.game3.trainer_sight")
  if not (Objects and Sight and type(Sight.getTrainerId) == "function") then return false end
  local byId = rawget(Objects, "_byId")
  if type(byId) ~= "table" then return false end
  local session = Gen3.session()
  for _, eo in pairs(byId) do
    if type(eo) == "table" and not eo.hidden then
      local base = tonumber(try3(Sight.getTrainerId, eo))
      if base and base > 0 then
        if base == tid then return true end
        for _, again in ipairs(rematchOf3(base, session)) do
          if again == tid then return true end
        end
      end
    end
  end
  return false
end

-- ------- deferred work: what the fight owes the field waits for the screen

local deferred3 = {}
-- How long a deferred step waits for the field before it runs anyway.  The
-- same bound Coop's blackout warp keeps (BLACKOUT_WARP_WAIT): every screen it
-- waits behind is a post-battle prompt the player is standing in front of.
-- Counted on the field only: off it (the title screen, a scene the cart runs
-- off the field) nothing runs at all, however long it takes.
M.DEFER3_WAIT = 60

-- The cart is talking: its message box or a YES / NO is open.  Read off the
-- engine's own modules, the way Gen3Ui.occupied reads them.
local function cartTalking3()
  local Message = g3("src.ui.game3.message")
  if Message and try3(Message.isOpen) then return true end
  local Choice = g3("src.ui.game3.choice")
  if type(Choice) == "table" and Choice.active == true then return true end
  return false
end

-- The field with nothing of anybody's in front of it: no layer on the game3
-- stack at all (the mod's forget-a-move prompt, an evolution, the cart's
-- menus), no line of the cart's being printed, the field phase up and the
-- cart's own battle not running.
--
-- `strict` also waits for the script VM to be idle and the field unlocked
-- (Gen3Ui.occupied).  That is the question for a whiteout that has nothing to
-- do with the script: a warp (Field.respawnAtHeal halts the VM) must never cut
-- a script off mid-sentence -- a gym leader's badge speech, the lines a beaten
-- trainer says -- which is exactly what the looser answer allowed.  It is
-- *not* the question for a stand-in's own steps: those run while the VM waits
-- on the very trainerbattle command they are about to answer (Vm:isRunning
-- counts "waiting"), and asked strictly they would wait on themselves.
function M.free3(strict)
  if not Gen3.inField() or Gen3.inBattle() then return false end
  if #Gen3Ui.states() ~= 0 then return false end
  if cartTalking3() then return false end
  if strict and Gen3Ui.occupied() then return false end
  return true
end

-- `opts.strict`: see M.free3.  Each step belongs to the save that queued it
-- (`session`): a load, a CONTINUE or a return to the title drops it unrun,
-- because a warp or a script's resume for a world that is gone would be done
-- to the one that replaced it.
function M.defer3(fn, what, opts)
  if type(fn) ~= "function" then return false end
  deferred3[#deferred3 + 1] = {
    fn = fn, what = what or "a step after the battle", clock = 0,
    session = Gen3.session(), strict = type(opts) == "table" and opts.strict == true,
  }
  M.pump3(0)
  return true
end

function M.pending3() return #deferred3 end

function M.pump3(dt)
  local entry = deferred3[1]
  if not entry then return false end
  local now = Gen3.session()
  if entry.session ~= nil and entry.session ~= now then
    -- Every step queued by another save goes at once, unrun.
    local dropped = 0
    for i = #deferred3, 1, -1 do
      local e = deferred3[i]
      if e.session ~= nil and e.session ~= now then
        table.remove(deferred3, i)
        dropped = dropped + 1
      end
    end
    mod.log:info("dropped %d step(s) a battle owed a save that is no longer "
      .. "loaded", dropped)
    return false
  end
  if not Gen3.inField() then return false end
  entry.clock = entry.clock + (tonumber(dt) or 0)
  if not M.free3(entry.strict) and entry.clock < M.DEFER3_WAIT then return false end
  table.remove(deferred3, 1)
  local ok, err = pcall(entry.fn)
  if not ok then
    mod.log:warn("%s failed after a battle (%s); reload from your last save if "
      .. "the world seems stuck", tostring(entry.what), tostring(err))
  end
  return true
end

-- Everything queued, dropped unrun.  src/Client.lua calls it when another save
-- takes over (save.loaded / save.created); pump3's own session check is the
-- same answer for a return to the title, which raises no event.
function M.resetDeferred3()
  for i = #deferred3, 1, -1 do deferred3[i] = nil end
end

-- The cart's whiteout, in two halves: the money now (FRLG's level x badge
-- table or Emerald's half -- BattleBridge.applyWhiteoutMoneyLoss is the one
-- that knows which), the heal and the trip to the heal location
-- (Field.respawnAtHeal, which also halts a waiting script) once the screen is
-- free.  `after` runs behind the warp.  `opts.strict` waits for the script VM
-- as well (M.free3): every caller but a stand-in answering its own
-- trainerbattle command passes it.
function M.whiteout3(game, after, opts)
  local session = Gen3.session() or (type(game) == "table" and game.session) or nil
  if not session then return false end
  local BB = g3("src.core.game3.battle_bridge")
  local save = type(game) == "table" and game.save or nil
  if BB and type(BB.applyWhiteoutMoneyLoss) == "function" then
    local ok, err = pcall(BB.applyWhiteoutMoneyLoss, session, save)
    if not ok then
      mod.log:warn("the whiteout's money could not be taken (%s); report this "
        .. "with the game version", tostring(err))
    end
  end
  local Party = g3("src.core.game3.party")
  if Party then try3(Party.healAll, session.party) end
  return M.defer3(function()
    local Field = g3("src.core.game3.field")
    if Field and type(Field.respawnAtHeal) == "function" then
      Field.respawnAtHeal()
    else
      mod.log:warn("there is no heal-location warp on this build; walk to a "
        .. "POKeMON CENTER -- your party was healed")
    end
    if after then after() end
  end, "the trip to the POKeMON CENTER",
    { strict = type(opts) == "table" and opts.strict == true })
end

-- ------- the stand-in

local Stand = {}
Stand.__index = Stand
M.Stand3 = Stand

local function introText3(kind, party, trainer)
  if kind == "wild" then
    local mon = party and party[1]
    local name = mon and Gen3.speciesName(tonumber(mon.species)) or "POKeMON"
    return ("Wild %s\nappeared!"):format(tostring(name))
  end
  local who = M.trainerLabel3(trainer) or "TRAINER"
  return ("%s\nwould like to battle!"):format(who)
end

-- args: { kind = "wild"|"trainer", party, trainer?, foe?, encounter?, opts?,
--         fightAlone = fn(), done = fn(result)?, game?, mapId?,
--         defeatText?, double? }
function M.stand3(args)
  args = args or {}
  local kind = args.kind == "trainer" and "trainer" or "wild"
  local party = args.party or {}
  local trainer = args.trainer
  local tid = trainer and tonumber(trainer.trainerId) or nil
  -- The defeat line keeps its page breaks (CoopBattle pages it on "\f");
  -- only the cart's printer codes are cleaned.
  local defeat = type(args.defeatText) == "string"
    and (Gen3.cleanText and Gen3.cleanText(args.defeatText) or args.defeatText) or nil
  if defeat == "" then defeat = nil end
  local self = setmetatable({
    -- the buried-BattleState shape Coop and SoloBattle read
    kind = kind,
    gen3Divert = true,
    wild = kind == "wild",
    enemyParty = party,
    enemy = party[1] and { mon = party[1] } or nil,
    trainer = trainer,
    trainerId = tid,
    oppClass = trainer and trainer.trainerClass or nil,
    -- A TRAINER_PIC id: CoopBattle / MediatedBattle hand it to the arena as
    -- `human.trainerPic`, and the classic page as `trainer.pic`.
    trainerPic = trainer and trainer.trainerPic or nil,
    endBattleText = defeat and (defeat:gsub("\n\n", "\f")) or nil,
    double = args.double and true or nil,
    label = (kind == "trainer") and M.trainerLabel3(trainer) or nil,
    checkpointOrigin = tid and { npcId = M.originId3(tid) } or nil,
    mapId = args.mapId,
    encounter = args.encounter,
    foe = args.foe,
    opts = args.opts or {},
    game = args.game,
    -- The save this encounter happened in (see the section header): nothing
    -- is started or finished for it once another one is running.
    session = Gen3.session(),
    -- the cover
    isOpaque = false,
    coverText = introText3(kind, party, trainer),
    -- private
    fightAloneFn = args.fightAlone,
    doneFn = args.done,
    finished = false,
    began = false,
  }, Stand)
  -- Coop.buriedFinisher reads onFinish (Gen 1) or onDone (Gen 2); both.
  self.onFinish = function(outcome) return self:finish(outcome) end
  self.onDone = self.onFinish
  return self
end

-- Put the cover up (the field freezes under any game3 layer).
function Stand:push(game)
  game = game or self.game
  self.game = game
  local pushed = Gen3Ui.pushScreen(game, "RbyMmoEncounter", self,
    { hideBelow = false, fullscreen = false })
  return pushed ~= nil
end

function Stand:onStack()
  return Gen3Ui.has(self)
end

function Stand:takeDown()
  if Gen3Ui.has(self) then return Gen3Ui.pop(self.game, self) end
  return false
end

function Stand:update() end
function Stand:handleInput() end

function Stand:draw()
  local text = self.coverText
  if type(text) ~= "string" or text == "" then return end
  local Font = Gen3Ui.Font
  if not (Font and type(Font.draw) == "function") then return end
  pcall(Gen3Ui.dialogueFrame)
  local l1, l2 = text:match("^([^\n]*)\n?(.*)$")
  pcall(Font.draw, l1 or "", 16, 121)
  if l2 and l2 ~= "" then pcall(Font.draw, l2, 16, 137) end
end

-- Is the save this encounter happened in still the one running?  A stand-in
-- built with no session (a suite's, by hand) never says no.
function Stand:sameSession()
  if self.session == nil then return true end
  return Gen3.session() == self.session
end

-- The mod's fight for this encounter has begun: run what battle_bridge.lua's
-- start does besides the battle itself (M.trainerStart3 / M.wildStart3 --
-- the match-call rematch clock, the league's friendship, Emerald's TV tally).
-- Once, and only for a fight the mod actually fights: a stand-in handed back
-- (`fightAlone`) is started by the cart's own start, which does all of it
-- itself, so running it at the take counted it twice for every co-op wait
-- that timed out.  Called by Coop:startBattle as the co-op screen goes up
-- and by src/Client.lua as solo takes the fight.
function Stand:begin3()
  if self.began then return false end
  self.began = true
  if not self:sameSession() then return false end
  if self.kind == "trainer" then
    M.trainerStart3(self, self.foe, self.opts)
  else
    M.wildStart3()
  end
  return true
end

-- Hand the encounter back to the cart: the cover comes down and the cart's
-- own battle starts, with the arguments it was cancelled with.  Once, and
-- only into the save it was met in: after a load, a CONTINUE or a return to
-- the title there is no encounter left to hand back (the script that was
-- waiting on it went with the old session), and starting it would put the
-- old file's trainer in front of the new file's player.
function Stand:fightAlone()
  if self.finished then return false end
  self.finished = true
  self.handedBack = true
  self:takeDown()
  if not self:sameSession() then
    mod.log:info("a battle from before the save was loaded was dropped, not "
      .. "started")
    return false
  end
  local fn = self.fightAloneFn
  if type(fn) ~= "function" then
    -- Nothing to start (a suite, or a stand-in built by hand): the script
    -- waiting on it is released the way a failed start releases it.
    if self.doneFn then pcall(self.doneFn, "win") end
    return false
  end
  local ok, err = pcall(fn)
  if not ok then
    mod.log:warn("the game's own battle could not be started after a divert "
      .. "(%s); the encounter is skipped -- report this with the map",
      tostring(err))
    -- battle_bridge's own failed start answers `done("win")`, which is what
    -- releases the script rather than leaving the player frozen.
    if self.doneFn then pcall(self.doneFn, "win") end
    return false
  end
  return true
end

local function lostResult(outcome)
  return outcome == "lose" or outcome == "loss" or outcome == "whiteout"
    or outcome == "blackout"
end

-- The trainer's script, halted where it waits: the cart's own ending for a
-- trainerbattle that is not answered (Field.respawnAtHeal does exactly this
-- before its warp).  Vm:halt unfreezes what the script locked and ends it, so
-- nothing after the trainerbattle command runs.
local function haltScript3()
  local Space = g3("src.core.game3.scripting.space")
  local vm = type(Space) == "table" and Space.vm or nil
  if type(vm) ~= "table" or type(vm.halt) ~= "function" then return false end
  local running = type(vm.isRunning) == "function" and try3(vm.isRunning, vm)
  if not running then return false end
  local ok, err = pcall(vm.halt, vm, true)
  if not ok then
    mod.log:warn("the trainer's script could not be stopped after an unfinished "
      .. "battle (%s); reload from your last save if the world seems stuck",
      tostring(err))
    return false
  end
  return true
end

-- The ritual.  `outcome` is what Coop.finishBuriedBattle / SoloBattle hand
-- over: "win", "lose" (a whiteout is owed and the engine takes it), "loss",
-- "draw".
function Stand:finish(outcome)
  if self.finished then return false end
  self.finished = true
  self:takeDown()
  -- A result for a save that is gone is nobody's: the script it would resume
  -- and the party it would heal belong to the old session (see fightAlone).
  if not self:sameSession() then
    mod.log:info("a battle from before the save was loaded ended; its result "
      .. "was dropped")
    return false
  end
  outcome = outcome or "draw"
  local lost = lostResult(outcome)
  local won = outcome == "win"
  local engineResult = won and "win" or "lose"
  local session = Gen3.session() or (type(self.game) == "table" and self.game.session) or nil
  local Natives = g3("src.core.game3.scripting.natives")
  if session and Natives and type(Natives.outcome_to_code) == "function" then
    local code = try3(Natives.outcome_to_code, lost and "lose" or (outcome == "win" and "win" or "draw"))
    if code then session.battleOutcome = code end
  end
  if self.kind == "wild" then
    local Encounters = g3("src.core.game3.encounters")
    if Encounters then try3(Encounters.resetRateModifiers) end
  end
  local done = self.doneFn
  local function backToField()
    local Audio = g3("src.core.game3.audio")
    if Audio then try3(Audio.restoreMapSong) end
    local Space = g3("src.core.game3.scripting.space")
    if Space then try3(Space.returnToField) end
  end
  local function carryOn()
    backToField()
    if done then
      local ok, err = pcall(done, engineResult)
      if not ok then
        mod.log:warn("the script waiting on this trainer could not carry on "
          .. "(%s); reload from your last save if the world seems stuck",
          tostring(err))
      end
    end
  end
  if lost then
    local opts = self.opts or {}
    local flags = tonumber(opts.rivalFlags) or 0
    local healAfter = opts.noWhiteout or (opts.earlyRival and (flags % 2 == 1))
    if healAfter then
      -- pret CB2_EndTrainerBattle RIVAL_BATTLE_HEAL_AFTER: healed, and the
      -- script carries on -- no whiteout (battle_bridge.lua writeback).
      local Party = g3("src.core.game3.party")
      if Party and session then try3(Party.healAll, session.party) end
      M.defer3(carryOn, "the script after this battle")
      return true
    end
    -- The whiteout, then the script (which respawnAtHeal has halted, as the
    -- cart's own finish leaves it).
    if not M.whiteout3(self.game, carryOn) then carryOn() end
    return true
  end
  if not won and self.kind == "trainer" then
    -- A draw that left this player standing (see the section header): the
    -- opcode is never answered -- "lose" would run the bytes after the
    -- trainerbattle command as though the trainer had been dealt with, and
    -- anything else marks them beaten.  The script is halted where it waits,
    -- nobody is whited out, and the trainer is there to be fought again.
    haltScript3()
    M.defer3(backToField, "the field after an unfinished battle")
    return true
  end
  -- The script carries on once the screen is the field's again: the cart runs
  -- a trainer's post-battle lines after its own battle screen has closed, and
  -- anything the fight left up (the forget-a-move prompt, an evolution) is
  -- that screen's tail.
  M.defer3(carryOn, "the script after this battle")
  return true
end

-- ------- building a stand-in for each door

-- The wild door (`encounter.roll`): nil + reason when this encounter is one a
-- divert must not take.
function M.wildStand3(enc, ctx, opts)
  ctx = ctx or {}
  if type(enc) ~= "table" then return nil, "no encounter" end
  local refused = M.refused3(enc, enc.foe, opts)
  if refused then return nil, refused end
  if enc.foe ~= nil then return nil, "foe" end
  local session = Gen3.session()
  if M.safari3(session) then return nil, "safari" end
  if M.ghost3(ctx.mapId, session) then return nil, "ghost" end
  local mon, why = M.wildMon3(enc, session)
  if not mon then return nil, why end
  return M.stand3({
    kind = "wild", party = { mon }, encounter = enc, game = ctx.game,
    mapId = ctx.mapId, fightAlone = ctx.fightAlone,
  })
end

-- The trainer door (BattleBridge.start): nil + reason when the start is not a
-- standard trainer fight a divert may take.
function M.trainerStand3(foe, opts, ctx)
  ctx = ctx or {}
  opts = opts or {}
  if opts.wild then return nil, "wild" end
  if opts.link or (type(foe) == "table" and foe.link) then return nil, "link" end
  if opts.headless then return nil, "headless" end
  local tid = tonumber(opts.trainerId) or tonumber(type(foe) == "table" and foe.trainerId)
  if not tid then return nil, "no trainer id" end
  local refused = M.refused3(opts, foe)
  if refused then return nil, refused end
  local party, why = M.trainerParty3(foe, tid)
  if not party then return nil, why end
  local trainer = M.trainerRecord3(foe, { trainerId = tid, trainerName = opts.trainerName,
    trainerClassName = opts.trainerClassName, trainerClass = opts.trainerClass,
    trainerPicId = opts.trainerPicId, game = ctx.game })
  return M.stand3({
    kind = "trainer", party = party, trainer = trainer, foe = foe, opts = opts,
    game = ctx.game, mapId = ctx.mapId, defeatText = opts.defeatText,
    double = (opts.double or (type(foe) == "table" and foe.doubleBattle)) and true or nil,
    fightAlone = ctx.fightAlone, done = opts.done,
  })
end

-- What battle_bridge.lua does at a wild battle's start that is not the battle
-- itself (BattleBridge.start, for `opts.wild`): Emerald's TV counts the day's
-- wild battles, and a cart with match call ticks its rematch clock for a wild
-- fight too (pokeemerald battle_setup.c:402 -- Rematch.onWildBattleStart).
function M.wildStart3()
  local session = Gen3.session()
  if not session then return end
  if family3(session) == "rse" then
    local Rse = g3("src.core.game3.rse.init")
    if Rse and type(Rse.call) == "function" then
      pcall(Rse.call, "tv", "incrementDailyWildBattles", "IncrementDailyWildBattles", nil)
    end
  end
  local Caps = g3("src.core.game3.capabilities")
  if Caps and try3(Caps.gate, session, "match_call") then
    local Rematch = g3("src.core.game3.rse.rematch")
    if Rematch then try3(Rematch.onWildBattleStart, session) end
  end
end

-- What battle_bridge.lua does at a trainer battle's start that is not the
-- battle itself, for a fight the divert took: Emerald's match-call rematch
-- bookkeeping and the Elite Four's league friendship.
function M.trainerStart3(stand, foe, opts)
  local session = Gen3.session()
  if not session then return end
  local Caps = g3("src.core.game3.capabilities")
  if Caps and try3(Caps.gate, session, "match_call") then
    local Rematch = g3("src.core.game3.rse.rematch")
    if Rematch then try3(Rematch.onTrainerBattleStart, session) end
  end
  local BB = g3("src.core.game3.battle_bridge")
  if BB then try3(BB.applyLeagueFriendship, session, nil, foe, opts or {}) end
end

-- ------- the BattleBridge.start wrap

local START_KEY = "__rby_mmo_start"
local start3 = {
  handle = nil,    -- Gen3.wrapFn's handle for the wrapper this file put in
  retired = false, -- restoreStart3 ran with somebody else's wrapper on top
  handler = nil,   -- { wants = fn(kind) -> bool, take = fn(stand) -> bool }
}

-- The engine's own start, whatever is installed over it.
function M.originalStart3()
  local BB = (start3.handle and start3.handle.module)
    or g3("src.core.game3.battle_bridge")
  if not BB then return nil end
  return rawget(BB, START_KEY) or BB.start
end

-- A trainer start, and a wild one that did not come through `encounter.roll`
-- (fishing, Rock Smash, Sweet Scent -- battle_bridge's own `standardWild`;
-- every scripted, legendary, roamer, safari or facility wild is refused by
-- Config.SOLO_REFUSED_GEN3). A step encounter the roll hook already offered
-- is not offered twice: `handler.skipWild()` says so.  Nor is a fight this mod
-- is handing back to the cart (`opts[M.HANDBACK3]`), which is the cart's now.
--
-- `inner` is what the wrapper wrapped -- the engine's start, or another mod's
-- wrapper around it -- so a fight handed back (`fightAlone`) goes down the
-- same chain an undiverted one would.
--
-- Taking the fight is not beginning it: the start's own bookkeeping
-- (Stand:begin3) runs when the mod's fight actually begins -- a co-op wait
-- that times out hands the fight back, and the cart's start then does it.
local function divertStart(inner, modArg, game, foe, opts)
  local handler = start3.handler
  if not (handler and type(handler.take) == "function") then return false end
  opts = opts or {}
  if opts.link or opts.headless then return false end
  if opts[M.HANDBACK3] then return false end
  local kind = opts.wild and "wild" or "trainer"
  if kind == "wild" then
    if opts.trainerId then return false end
    if type(handler.skipWild) == "function" and handler.skipWild() then return false end
  end
  local current = Gen3.position()
  local mapId = current and current.mapId
  if type(handler.wants) == "function" and not handler.wants(kind, mapId) then return false end
  local ctx = {
    game = game, mapId = mapId,
    fightAlone = function() return inner(modArg, game, foe, opts) end,
  }
  local stand
  if kind == "wild" then
    stand = M.wildStand3(foe, ctx, opts)
  else
    stand = M.trainerStand3(foe, opts, ctx)
  end
  if not stand then return false end
  return handler.take(stand, foe, opts, kind) == true
end

-- `handler.wants(kind, mapId)` is the cheap question (is anybody going to take
-- a fight of this kind, here, at all?) asked before anything is built, so a
-- player nobody would divert for never has a foe rolled twice; `handler.take(stand,
-- foe, opts)` is the divert itself (the engine's foe and battle opts ride
-- along for a taker that builds its own fight), true when it took the fight.
function M.installStart3(handler)
  start3.handler = handler
  if start3.handle and Gen3.wrapLive(start3.handle) then
    start3.retired = false
    return true
  end
  local BB = g3("src.core.game3.battle_bridge")
  if not (BB and type(BB.start) == "function") then
    mod.log:warn("this build has no Gen 3 battle entry to divert; co-op and solo "
      .. "battles will not take over trainer fights here -- update the game")
    return false
  end
  local handle
  handle = Gen3.wrapFn(BB, "start", START_KEY, function(inner)
    return function(modArg, game, foe, opts)
      if not start3.retired and Gen3.wrapLive(handle) and alive() then
        local ok, taken = pcall(divertStart, inner, modArg, game, foe, opts)
        if ok and taken then return true end
        if not ok then
          mod.log:warn("the battle divert failed (%s); this battle is fought the "
            .. "ordinary way -- the battle itself is unaffected", tostring(taken))
        end
      end
      return inner(modArg, game, foe, opts)
    end
  end)
  if not handle then return false end
  start3.handle, start3.retired = handle, false
  return true
end

-- Put back what the wrapper wrapped -- only when the slot still holds this
-- file's wrapper; a wrapper somebody stacked on top keeps the slot, and ours
-- is retired in place (answers what the engine would).
function M.restoreStart3()
  if not start3.handle then return false end
  start3.retired = true
  if Gen3.unwrapFn(start3.handle) then start3.handle = nil end
  return true
end

function M.start3Installed()
  return start3.handle ~= nil and not start3.retired
end

return M
