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
local Borrow3 = need("Borrow3")

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
-- An unfinished trainer draw (the clock, a disconnect, a forfeit) does not
-- beat the trainer: the script is halted where it waits, the flag stays
-- unset and no prize is paid. A wiped draw is a whiteout and reaches here
-- as "lose". A knockout whose sheets and the save disagree is a win, and
-- that decision is made once for the fight (solo compares the sheets to
-- the save; co-op trusts the referee and whites every client out).
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
-- takes a fight somebody listening actually wants (Config.SOLO_REFUSED_GEN3
-- is refused for everybody, Config.COOP_REFUSED_GEN3 and the kinds co-op has
-- no shape for are never put to co-op, link / headless pass straight
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

-- The referee's how, when this draw is a knockout. "ko" and an Arena
-- "judge" count, and so does a knockout that arrived with no how -- which is
-- every co-op one: a hub's outcome carries `reason` and never `how`
-- (Wire.battleOutcome / the hub's Relay.settleMediated name their fields), so
-- `reason == "ko"` is how co-op tells a knockout draw.  A timeout, a
-- disconnect and a forfeit do not.
function M.knockoutHow3(how, reason)
  if how == "ko" or how == "judge" then return how end
  if how == nil and reason == "ko" then return "ko" end
  return nil
end

-- A draw is a win only when the caller has already decided, once for the
-- fight, that a knockout's sheets and the save disagree (`standing`).
-- Co-op passes false: the hub's draw is the decision, and a client's own
-- party must not complete the trainer on its own.
function M.trainerDrawResult3(result, how, standing)
  if result ~= "draw" or standing ~= true then return result end
  if not M.knockoutHow3(how) then return result end
  return "win"
end

-- ------- which fights a divert may take

-- The first key of `list` any of these tables carries, or nil.  The list is
-- the caller's: Config.COOP_REFUSED_GEN3 for what co-op will not fight,
-- Config.SOLO_REFUSED_GEN3 for what stays on the cart for everybody (Config
-- names every key and why).  The battle start opts, the wild `foe` and the
-- encounter are all asked, the way SoloBattle.refused asks a state and its
-- inner battle.  A key set to `false` refuses nothing -- the trainer op
-- passes `firstBattle = false` for every ordinary trainer.
function M.refused3(list, ...)
  if type(list) ~= "table" then return nil end
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

function M.coopRefused3(...) return M.refused3(Config.COOP_REFUSED_GEN3, ...) end
function M.soloRefused3(...) return M.refused3(Config.SOLO_REFUSED_GEN3, ...) end

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

-- ------- what kind of fight it is (docs/plans/gen3-solo-remaining-fights.md C1)
--
-- Every stand-in carries the kind the engine spelled its fight with, read where
-- the engine spells it -- the start opts, the wild `foe`, the encounter, or a
-- session predicate for the two the cart never puts a key on (the Safari Zone,
-- a POKeMON TOWER floor).  One name per fight, the first that applies:
--
--   kind3       "tutorial" | "facility" | "firstBattle" | "partner" | "pair"
--               | "safari" | "roamer" | "ghost" | "legendary" | "scripted"
--               | "wild" | "trainer"
--   facility3   the hall: "tower" | "dome" | "palace" | "arena" | "factory" |
--               "pike" | "pyramid" | "hill" | "trainerTower" | "secretBase" |
--               "eReader" (a Battle Tent is its hall: the engine starts
--               Verdanturf's as `palace`, Fallarbor's as `arena`, Slateport's
--               as `factory` -- rse/frontier/palace.lua, tents.lua)
--   tutorial3   "oldMan" | "wally" | "pokedude"
--   firstBattle3  "oak" | "birch"            (kind3 "firstBattle")
--   ghost3        "veiled" | "unveiled"      (kind3 "ghost")
--
-- The order is the order the cart's own rules nest in: a tutorial is a scripted
-- replay whatever else it is, a facility's hall decides its rules even for its
-- two-trainer and partner fights (a Battle Tower multi carries `partner` and
-- `twoOpponents` as well -- its stand keeps those fields too), a first battle is
-- one before it is a trainer.  Among the wild kinds, battle_bridge's own
-- `standardWild` test reads the same keys.

-- The halls, by the key BattleBridge.start receives (rse/frontier/tower.lua
-- Tower.startBattle sets `frontier` and `battleOpts[kind] = true`; Trainer
-- Hill, Secret Base, FireRed's tower and e-Reader set their own).  The halls
-- come before `battleTower`: pret runs a Pike single as BATTLE_TOWER type, and
-- the engine marks it `pike`.
local FACILITY_KEYS3 = {
  { "dome", "dome" }, { "palace", "palace" }, { "arena", "arena" },
  { "factory", "factory" }, { "pike", "pike" }, { "pyramid", "pyramid" },
  { "battleTower", "tower" }, { "tower", "tower" },
  { "trainerHill", "hill" }, { "trainerTower", "trainerTower" },
  { "secretBase", "secretBase" }, { "eReader", "eReader" },
  -- `frontier` with no hall is never started (every Frontier start names its
  -- hall); the Battle Tower is the Frontier's plain rules.
  { "frontier", "tower" },
}
M.FACILITY_KEYS3 = FACILITY_KEYS3

-- The Emerald legend kinds battle_bridge copies (EXTRA_KINDS), and FireRed's
-- own two words for a static legend (natives.lua StartLegendaryBattle).
local LEGEND_KEYS3 = { "legendary", "specialWild", "kyogreGroudon", "regi", "groudon",
                       "kyogre", "rayquaza" }

-- The kinds co-op seats: a plain wild and a plain trainer (a lone double
-- included).  Every other kind is solo's -- the carts have no two-player shape
-- for it (Config.COOP_REFUSED_GEN3).
M.COOP_KINDS3 = { wild = true, trainer = true }

local function set3(v) return v ~= nil and v ~= false end

local function anyKey3(keys, ...)
  for i = 1, select("#", ...) do
    local t = select(i, ...)
    if type(t) == "table" then
      for _, k in ipairs(keys) do
        if set3(t[k]) then return k end
      end
    end
  end
  return nil
end

local function profileKinds3(session)
  local Profile = g3("src.core.game3.battle.profile")
  local prof = Profile and try3(Profile.get, session)
  return type(prof) == "table" and type(prof.kinds) == "table" and prof.kinds or {}
end

-- battle/kinds.lua spells a tutorial "oldman" (FireRed's profile) or "wally"
-- (Emerald's); C1 spells them "oldMan" / "wally" / "pokedude".
local function tutorialName3(v, session)
  if v == "wally" or v == "pokedude" then return v end
  if v == "oldman" or v == "oldMan" then return "oldMan" end
  local own = profileKinds3(session).tutorial
  if own == "wally" then return "wally" end
  return "oldMan"
end

local function tutorialOf3(session, ...)
  for i = 1, select("#", ...) do
    local t = select(i, ...)
    if type(t) == "table" then
      if set3(t.pokedude) then return "pokedude" end
      if set3(t.oldManTutorial) then return "oldMan" end
      local k = t.tutorialKind
      if not set3(k) then k = t.tutorial end
      if set3(k) then return tutorialName3(k, session) end
    end
  end
  return nil
end

local function facilityOf3(...)
  for i = 1, select("#", ...) do
    local t = select(i, ...)
    if type(t) == "table" then
      for _, row in ipairs(FACILITY_KEYS3) do
        if set3(t[row[1]]) then return row[2] end
      end
    end
  end
  return nil
end

-- battle_bridge.lua's `standardWild`: the wilds nothing else claims, the only
-- ones it asks the Safari Zone about.
local function standardWild3(opts, foe)
  return not anyKey3({ "wildScripted", "legendary", "roamer", "firstBattle",
                       "oldManTutorial", "firstBattleKind", "tutorialKind" }, opts, foe)
end

-- -> { kind3, facility3?, tutorial3?, firstBattle3?, ghost3? }
--
-- `wild` is the door's answer (a step encounter or `opts.wild`), `foe` the
-- encounter or the engine's foe, `opts` the start opts (nil at the roll),
-- `ctx` { mapId, session }.
function M.classify3(wild, foe, opts, ctx)
  ctx = ctx or {}
  foe = type(foe) == "table" and foe or {}
  opts = type(opts) == "table" and opts or {}
  local session = ctx.session
  if session == nil then session = Gen3.session() end
  local inner = type(foe.foe) == "table" and foe.foe or nil
  local tutorial3 = tutorialOf3(session, opts, foe)
  if tutorial3 then return { kind3 = "tutorial", tutorial3 = tutorial3 } end
  local facility3 = facilityOf3(opts, foe)
  if facility3 then return { kind3 = "facility", facility3 = facility3 } end
  local first = anyKey3({ "firstBattle", "firstBattleKind" }, opts, foe)
  if first then
    local kind = type(opts.firstBattleKind) == "string" and opts.firstBattleKind
      or profileKinds3(session).firstBattle
    if kind ~= "oak" and kind ~= "birch" then kind = wild and "birch" or "oak" end
    return { kind3 = "firstBattle", firstBattle3 = kind }
  end
  if set3(opts.partner) then return { kind3 = "partner" } end
  if set3(opts.twoOpponents) or opts.trainerIdB ~= nil then return { kind3 = "pair" } end
  if not wild then return { kind3 = "trainer" } end
  if set3(opts.safari) or set3(foe.safari)
     or (standardWild3(opts, foe) and M.safari3(session)) then
    return { kind3 = "safari" }
  end
  if set3(opts.roamer) or set3(foe.roamer) or (inner and set3(inner.roamer)) then
    return { kind3 = "roamer" }
  end
  -- battle/init.lua ghost_battle: an explicit `ghost` either way wins (the
  -- Marowak native sets it), else a wild on a POKeMON TOWER floor without the
  -- SILPH SCOPE.  GHOST_UNVEILED is the Marowak met with the scope.
  local ghost
  if opts.ghost ~= nil then ghost = set3(opts.ghost)
  elseif foe.ghost ~= nil then ghost = set3(foe.ghost)
  else ghost = set3(opts.ghostBattle) or set3(foe.ghostBattle) or M.ghost3(ctx.mapId, session) end
  if ghost then
    local unveiled = set3(opts.ghostUnveiled) or set3(foe.ghostUnveiled)
    return { kind3 = "ghost", ghost3 = unveiled and "unveiled" or "veiled" }
  end
  if anyKey3(LEGEND_KEYS3, opts, foe) then return { kind3 = "legendary" } end
  if anyKey3({ "wildScripted" }, opts, foe) then return { kind3 = "scripted" } end
  return { kind3 = "wild" }
end

-- Why co-op will not fight this one, or nil: a key Config.COOP_REFUSED_GEN3
-- names, else a kind co-op has no shape for (the Safari Zone and the tower
-- ghosts carry no key at all; a roamer's is on the encounter).
function M.coopRefusal3(cls, ...)
  local key = M.coopRefused3(...)
  if key then return key end
  local kind = type(cls) == "table" and cls.kind3 or nil
  if kind and not M.COOP_KINDS3[kind] then return kind end
  return nil
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

-- An IV / EV table in whichever spelling the engine row uses: the battle's
-- hp/atk/def/spe/spa/spd, or the FireRed roamer's attack/defense/speed/spAtk/
-- spDef (roamer.lua generateMon -- read as-is, its five non-HP IVs were all 0).
local STAT_ALIASES3 = {
  hp = { "hp", "HP" }, atk = { "atk", "attack" }, def = { "def", "defense" },
  spe = { "spe", "speed" }, spa = { "spa", "spAtk", "spAttack" },
  spd = { "spd", "spDef", "spDefense" },
}
local function copyStats(src)
  if type(src) ~= "table" then return nil end
  local out = {}
  for _, k in ipairs({ "hp", "atk", "def", "spe", "spa", "spd" }) do
    local v
    for _, alias in ipairs(STAT_ALIASES3[k]) do
      v = tonumber(src[alias])
      if v then break end
    end
    out[k] = math.max(0, floor(v or 0))
  end
  return out
end

-- pret STATUS1_* (include/constants/battle.h): bits 0-2 the sleep counter,
-- then POISON 8, BURN 16, FREEZE 32, PARALYSIS 64, TOXIC_POISON 128.  A roamer
-- keeps its status in the save as that byte (Emerald's roamer.status, FireRed's
-- statusNum) or as the engine battle's own word (what Roamer.onBattleEnd writes
-- back from the battle's monster).  -> the battle's word, and the sleep turns.
local STATUS_WORDS3 = {
  SLP = "SLP", SLEEP = "SLP", PSN = "PSN", POISON = "PSN", BRN = "BRN", BURN = "BRN",
  FRZ = "FRZ", FREEZE = "FRZ", PAR = "PAR", PARALYSIS = "PAR", TOX = "TOX", TOXIC = "TOX",
}
function M.status3(status, statusNum, sleep)
  if type(status) == "string" and status ~= "" then
    local word = STATUS_WORDS3[status:upper()]
    if word then return word, (word == "SLP") and tonumber(sleep) or nil end
    return nil
  end
  local n = tonumber(status)
  if not n or n == 0 then n = tonumber(statusNum) end
  if not n or n <= 0 then return nil end
  n = floor(n) % 256
  if n % 8 > 0 then return "SLP", n % 8 end
  if floor(n / 8) % 2 == 1 then return "PSN" end
  if floor(n / 16) % 2 == 1 then return "BRN" end
  if floor(n / 32) % 2 == 1 then return "FRZ" end
  if floor(n / 64) % 2 == 1 then return "PAR" end
  if floor(n / 128) % 2 == 1 then return "TOX" end
  return nil
end

-- A monster the engine already built in full (rse/frontier/trainers.lua
-- createMon + applyStats for every Frontier, Trainer Hill, Secret Base and
-- Pyramid monster; Story.stevenParty; Pokedude.build): taken as it is.
-- Rebuilding one through a spec builder re-rolls what it leaves out and drops
-- what it does not read (the Trainer Tower's abilityNum, a facility's
-- nature-matched personality).
local BUILT_STATS3 = { "attack", "defense", "speed", "spAtk", "spDef" }
function M.built3(mon)
  if type(mon) ~= "table" then return false end
  if not (tonumber(mon.species or mon.speciesId) and tonumber(mon.level)) then return false end
  if type(mon.moves) ~= "table" or #mon.moves == 0 then return false end
  if not ((tonumber(mon.maxHp) or 0) > 0) then return false end
  for _, k in ipairs(BUILT_STATS3) do
    if not ((tonumber(mon[k]) or 0) > 0) then return false end
  end
  return true
end

local function copyList3(list)
  if type(list) ~= "table" then return list end
  local out = {}
  for i, v in ipairs(list) do out[i] = v end
  return out
end

-- The stand-in's own copy of an engine-built monster: the same fields, its own
-- move lists (a fight writes PP), so the engine's table is never written.
function M.copyMon3(mon)
  local out = {}
  for k, v in pairs(mon) do out[k] = v end
  out.moves, out.pp, out.maxPp = copyList3(mon.moves), copyList3(mon.pp), copyList3(mon.maxPp)
  out.species = tonumber(mon.species) or tonumber(mon.speciesId)
  out.speciesId = out.species
  if out.hp == nil then out.hp = out.maxHp end
  return out
end

-- pret CalculatePPWithBonus (pokemon.c): a move's PP with its PP Ups --
-- (ppBonuses >> 2*slot) & 3 of them, a fifth of the base each.
local function ppWithBonus3(base, bonuses, slot)
  local ups = floor((tonumber(bonuses) or 0) / (4 ^ (slot - 1))) % 4
  return base + floor(base * 20 * ups / 100)
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

-- pret CreateMonWithGenderNatureLetter (the scoped Marowak: female, SERIOUS)
-- and CreateMaleMon (Wally's Ralts, the old man's Weedle): a row that fixes a
-- nature or a gender but no personality is given a personality that has them,
-- drawn the way the cart draws it -- Random32 until it fits.  The engine's
-- own foe builder keeps the fields and a random personality instead
-- (battle/init.lua foe_mon_from), so the stats it computes from the
-- personality's nature disagree with the nature it shows; pret wins.  A
-- gender the species cannot have is not looked for (the row's field is still
-- kept, as the engine keeps it); the search is bounded either way.
function M.fixedPersonality3(P, species, spec, dword)
  local nature = tonumber(spec.nature)
  if nature and (nature < 0 or nature > 24) then nature = nil end
  local gender = spec.gender
  if gender ~= "M" and gender ~= "F" then gender = nil end
  if gender then
    -- A fixed-gender species answers the same for every personality (the
    -- ratio is compared with personality % 256).
    local lo, hi = try3(P.gender, species, 0), try3(P.gender, species, 255)
    if lo == hi then gender = nil end
  end
  if nature == nil and gender == nil then return nil end
  local last
  for _ = 1, 4096 do
    local p = dword()
    last = p
    local okNature = nature == nil or (tonumber(try3(P.natureId, p)) or (p % 25)) == nature
    local okGender = gender == nil or try3(P.gender, species, p) == gender
    if okNature and okGender then return p end
  end
  return last
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
  -- FireRed's roamer keeps its personality as `pid` (roamer.lua).
  local personality = tonumber(spec.personality) or tonumber(spec.pid)
  if personality == nil then personality = M.fixedPersonality3(P, species, spec, dword) end
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
  if opts.wild then
    -- pret SetWildMonHeldItem runs after the monster is made
    -- (CB2_InitBattleInternal: pokeemerald battle_main.c:700, pokefirered
    -- :708), so a draw that writes -- ITEM_NONE included -- writes over the
    -- row's own item (`setwildbattle`'s, the start's zeroed one); only a draw
    -- that returns early leaves it (SoloBattle.gen3WildItem's `wrote`).
    local rolled, wrote
    if opts.family == "rse" then
      -- The engine's own roll (encounter_rules/rse.lua wildHeldItem): nil
      -- when it returned early, a number when it wrote; `alteringCave` its
      -- ALTERING CAVE arm (pret pokeemerald pokemon.c:6692).
      local Encounters = g3("src.core.game3.encounters")
      local rules = Encounters and try3(Encounters.rules)
      local held = rules and try3(rules.wildHeldItem, species,
        { alteringCave = opts.alteringCave and true or nil }) or nil
      rolled = tonumber(held)
      wrote = rolled ~= nil
    else
      -- FireRed / LeafGreen's roll is SoloBattle's (gen3WildItem) -- one
      -- statement of pret SetWildMonHeldItem, so the monster a stand-in builds
      -- and the one a solo fight would build agree.  The roll below is the
      -- same arithmetic (pret pokefirered pokemon.c:6032: one Random() % 100
      -- always drawn; common == rare holds it every time; 45-94 the common
      -- item, 95-99 the rare one), for a graph without SoloBattle (never in
      -- play).
      local Solo = solo3()
      if Solo and type(Solo.gen3WildItem) == "function" then
        local ok, got, didWrite = pcall(Solo.gen3WildItem, species, word)
        if ok and tonumber(got) then rolled, wrote = tonumber(got), didWrite == true end
      end
      if rolled == nil then
        local meta = try3(P.speciesMeta, species)
        local common = tonumber(type(meta) == "table" and meta.itemCommon) or 0
        local rare = tonumber(type(meta) == "table" and meta.itemRare) or 0
        local r = word() % 100
        if common == rare then rolled, wrote = common, true
        elseif r > 44 then rolled, wrote = (r <= 94) and common or rare, true end
      end
    end
    if wrote then item = rolled end
  end
  item = floor(tonumber(item) or 0)
  local moves, pp, maxPp = nil, nil, nil
  if type(spec.moves) == "table" and #spec.moves > 0 then
    moves, pp, maxPp = {}, {}, {}
    for _, m in ipairs(spec.moves) do
      local id = tonumber(type(m) == "table" and (m.id or m.num) or m)
      if id and id > 0 and #moves < 4 then
        moves[#moves + 1] = floor(id)
        local base = tonumber(try3(P.movePp, id)) or (Gen3.moveInfo(id) or {}).pp or 0
        local slot = #moves
        -- pret CreateBattleTowerMon: SetMonMoveSlot gives each move its base
        -- PP, and the PP Ups are set after it -- so the current PP stays the
        -- base and only the maximum grows (a Trainer Tower row's ppBonuses).
        maxPp[slot] = ppWithBonus3(base, spec.ppBonuses, slot)
        local given = type(spec.pp) == "table" and tonumber(spec.pp[slot]) or nil
        pp[slot] = given and math.max(0, math.min(floor(given), maxPp[slot])) or base
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
  -- The row's own ability, else its ability slot (pret GetAbilityBySpecies:
  -- abilities[abilityNum ? 1 : 0], even when that slot is empty -- a Trainer
  -- Tower row's abilityNum), else the personality's.
  local abilityNum = tonumber(spec.abilityNum)
  local ability = tonumber(spec.ability) or tonumber(spec.abilityId)
  if ability == nil and abilityNum ~= nil then
    local pair = try3(P.abilities, species)
    if type(pair) == "table" then
      ability = tonumber(pair[(abilityNum ~= 0) and 2 or 1]) or 0
    end
  end
  ability = ability or tonumber(try3(P.abilityId, species, personality)) or 0
  local nature = tonumber(spec.nature)
  if not nature or nature < 0 or nature > 24 then
    nature = tonumber(try3(P.natureId, personality)) or (personality % 25)
  end
  local gender = spec.gender
  if gender ~= "M" and gender ~= "F" and gender ~= "U" then
    gender = try3(P.gender, species, personality) or "U"
  end
  local mon = {
    species = species, speciesId = species,
    speciesNumbering = P.NUMBERING_INTERNAL or "internal",
    name = try3(P.name, species),
    nickname = type(spec.nickname) == "string" and spec.nickname or "",
    level = level, metLevel = level,
    growthRate = growth,
    exp = tonumber(SummaryData and try3(SummaryData.expForLevel, growth, level)) or 0,
    personality = personality,
    nature = nature,
    ivs = ivs,
    evs = copyStats(spec.evs) or zeros(),
    ability = ability, abilityId = ability, abilityNum = abilityNum,
    gender = gender,
    heldItem = item, item = item,
    moves = moves, pp = pp, maxPp = maxPp,
    -- The species' base friendship: Pokemon.baseFriendship reads the meta
    -- row's `friendship` (there is no `baseFriendship` key on it -- reading
    -- that one handed every wild monster 70).
    friendship = tonumber(spec.friendship)
      or tonumber(try3(P.baseFriendship, species))
      or tonumber(type(meta) == "table" and meta.friendship) or 70,
    otId = tonumber(spec.otId),
    pokerus = 0,
  }
  -- A fateful encounter (seteventmon / the event legends) stays one: it is
  -- what lets Mew and Deoxys obey, and what a trade reads.
  if spec.fatefulEncounter ~= nil then mon.fatefulEncounter = spec.fatefulEncounter and true or false end
  if not try3(function() P.applyStats(mon) return true end) then
    return nil, "no stats"
  end
  mon.hp = tonumber(mon.maxHp) or mon.hp
  -- A monster that arrives hurt (a roamer banks its HP in the save):
  -- pret CreateRoamerMonInstance sets the saved HP after building it.
  local hp = tonumber(spec.hp)
  if hp and tonumber(mon.maxHp) then mon.hp = math.max(0, math.min(floor(hp), mon.maxHp)) end
  mon.status, mon.sleep = M.status3(spec.status, spec.statusNum, spec.sleep or spec.sleepTurns)
  return mon
end

-- A foe the engine handed a battle start, as the engine would build it
-- (battle/init.lua foe_mon_from): every field the row carries kept --
-- personality, IVs, nature, gender, ability or ability slot, moves and PP,
-- held item, nickname, HP, status -- and only what it leaves out rolled.  An
-- engine-built monster is copied as it is (M.built3).  `opts.wild` asks for
-- the cart's wild held-item roll, which writes over the row's own item
-- whenever its draw writes at all (pret SetWildMonHeldItem, after
-- setwildbattle's CreateScriptedWildMon): pret skips it for a LEGENDARY
-- battle (FireRed's GHOST_UNVEILED is that bit), the Pike and the Pyramid,
-- and the POKe DUDE.  `opts.alteringCave` (Emerald's ALTERING CAVE,
-- SoloBattle.gen3AlteringCave) rolls the cave's own items.
function M.foeMon3(spec, opts)
  if type(spec) ~= "table" then return nil, "no foe" end
  if M.built3(spec) then return M.copyMon3(spec) end
  local P = g3("src.core.game3.pokemon")
  if not P then return nil, "the engine's POKeMON module is unavailable" end
  opts = opts or {}
  return buildMon(P, spec, { wild = opts.wild == true,
    alteringCave = opts.alteringCave == true or nil,
    family = family3(opts.session or Gen3.session()) })
end

-- Is `mapId` Emerald's ALTERING CAVE, where a wild rolls the cave's own held
-- items (pret pokeemerald pokemon.c:6692, LAYOUT_ALTERING_CAVE)?
-- SoloBattle.gen3AlteringCave is the one statement; the literal is the
-- answer for a graph without SoloBattle (never in play).
function M.alteringCave3(mapId)
  if type(mapId) ~= "string" then return false end
  local Solo = solo3()
  if Solo and type(Solo.gen3AlteringCave) == "function" then
    local ok, yes = pcall(Solo.gen3AlteringCave, mapId)
    if ok then return yes == true end
  end
  return mapId == "EM_ALTERING_CAVE"
end

-- A wild encounter's monster.  `enc` is what `encounter.roll` returned (the
-- mod-facing shape: `speciesId` numeric, `species` the engine's key name) or
-- the engine's own (numeric `species`); `mapId` the map it was met on (the
-- ALTERING CAVE's held items, M.alteringCave3).
function M.wildMon3(enc, session, mapId)
  if type(enc) ~= "table" then return nil, "no encounter" end
  local P = g3("src.core.game3.pokemon")
  if not P then return nil, "the engine's POKeMON module is unavailable" end
  return buildMon(P, enc, { wild = true, family = family3(session),
    alteringCave = M.alteringCave3(mapId) or nil })
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

-- ------- a facility's trainer: no gTrainers row
--
-- pret battle_message.c:2043 / battle_tower.c:1436: a Frontier, Trainer Hill,
-- Trainer Tower, e-Reader or Secret Base opponent is not a gTrainers row, and
-- the engine never asks Trainers.info for one (battle/init.lua: trainerInfo
-- is nil for trainerTower / eReader / secretBase, and a `frontierTrainer`
-- names the rest).  Asking it anyway named a Trainer Tower trainer after
-- whatever row 0 is.  The record is built from what the facility handed the
-- start instead: `opts.frontierTrainer` { class, className, name, pic }, else
-- the opts' / foe's trainerName, trainerClass, trainerClassName, trainerPicId.

-- pret's three facility scripts, CHECK_BAD_MOVE | TRY_TO_FAINT |
-- CHECK_VIABILITY (FireRed battle_ai_script_commands.c:342-357 for the
-- Trainer Tower and e-Reader, Emerald :371-372 for the Frontier, Trainer Hill,
-- e-Reader and Secret Base).  The halls whose start passes no aiFlags get them
-- here: the engine falls back to 1 for FireRed's tower and e-Reader and to 0
-- for Emerald's Secret Base (battle/init.lua), which pret does not.
local FACILITY_AI_DEFAULT3 = { trainerTower = true, eReader = true, secretBase = true }
local function facilityAi3(session)
  local Profile = g3("src.core.game3.battle.profile")
  local prof = Profile and try3(Profile.get, session)
  if Profile and type(prof) == "table" and type(Profile.aiBit) == "function" then
    local sum = 0
    for _, name in ipairs({ "CHECK_BAD_MOVE", "TRY_TO_FAINT", "CHECK_VIABILITY" }) do
      local bit = tonumber(try3(Profile.aiBit, prof, name))
      if not bit then return 7 end
      sum = sum + bit
    end
    return sum
  end
  return 7
end

-- FireRed's Trainer Tower and e-Reader rows carry a *facility* class, mapped
-- to a trainer class by the cart (pret trainer_tower.c:447, battle_tower.c:1340;
-- the engine's trainer_tower pack `facilityClassTrainerClass`).
local function facilityClass3(facilityClass)
  local Tower = g3("src.core.game3.trainer_tower")
  local pack = Tower and try3(Tower.pack)
  local classes = type(pack) == "table" and pack.facilityClassTrainerClass or nil
  local mapped = type(classes) == "table" and tonumber(classes[tonumber(facilityClass)]) or nil
  return mapped
end

local function className3(class)
  if not class then return nil end
  local Trainers = g3("src.core.game3.scripting.trainers")
  local pack = Trainers and try3(Trainers.pack)
  local names = type(pack) == "table" and pack.classNames or nil
  return type(names) == "table" and label3(names[class]) or nil
end

local function cleanText3(text)
  if type(text) ~= "string" then return nil end
  local clean = Gen3.cleanText and Gen3.cleanText(text) or text
  if clean == "" then return nil end
  return clean
end

-- -> the trainer record (trainerRecord3's shape, and SoloBattle.gen3TrainerRecord's
-- names beside it), for a facility fight.  `which` = "B" reads the second
-- trainer of a facility pair (`frontierTrainerB`, `defeatTextB`).
function M.facilityRecord3(foe, opts, facility3, session, which)
  foe = type(foe) == "table" and foe or {}
  opts = type(opts) == "table" and opts or {}
  local b = which == "B"
  local ft, defeat, victory
  if b then
    ft, defeat, victory = opts.frontierTrainerB, opts.defeatTextB, opts.victoryTextB
  else
    ft, defeat, victory = opts.frontierTrainer, opts.defeatText, opts.victoryText
  end
  ft = type(ft) == "table" and ft or nil
  local class = tonumber(ft and ft.class)
    or (not b and (tonumber(opts.trainerClass) or tonumber(foe.trainerClass))) or nil
  if not ft and (facility3 == "trainerTower" or facility3 == "eReader") then
    class = facilityClass3(foe.trainerClass) or class
  end
  local className = label3(ft and ft.className)
    or (not b and (label3(opts.trainerClassName) or label3(foe.trainerClassName)) or nil)
    or className3(class)
  local name = label3(ft and ft.name)
    or (not b and (label3(opts.trainerName) or label3(foe.trainerName)) or nil)
  local pic = tonumber(ft and ft.pic)
    or (not b and (tonumber(opts.trainerPicId) or tonumber(foe.trainerPicId)
                   or tonumber(foe.trainerPic)) or nil)
  local tid = not b and (tonumber(opts.trainerId) or tonumber(foe.trainerId)) or nil
  local ai = tonumber(opts.aiFlags) or tonumber(foe.aiFlags)
  if ai == nil and FACILITY_AI_DEFAULT3[facility3] then ai = facilityAi3(session) end
  -- pret battle_ai_script_commands.c:290-296: a facility trainer uses no items
  -- (the engine hands the start `trainerItems = { 0, 0, 0, 0 }`).
  local items = { 0, 0, 0, 0 }
  if type(opts.trainerItems) == "table" then
    for i = 1, 4 do items[i] = floor(tonumber(opts.trainerItems[i]) or 0) end
  end
  return {
    id = tid and tostring(tid) or nil,
    trainerId = tid,
    frontierTrainerId = not b and tonumber(foe.frontierTrainerId) or nil,
    facility = facility3,
    trainerClass = class, class = class, classId = class,
    className = className, trainerClassName = className,
    name = name, trainerName = name,
    trainerPic = pic, pic = pic,
    items = items,
    aiFlags = ai or 0,
    doubleBattle = (set3(opts.double) or set3(foe.doubleBattle)) and true or false,
    gender = foe.gender,
    defeatText = cleanText3(defeat),
    victoryText = cleanText3(victory),
  }
end

-- A facility's monsters, as the facility built them: the Frontier, Trainer
-- Hill, Secret Base and Pyramid hand the start finished monsters (createMon +
-- applyStats, nature-matched personalities, fixed IVs, EV spreads) and are
-- copied as they are; FireRed's Trainer Tower hands battleTowerMon rows,
-- built here keeping every field the row carries (pret CreateBattleTowerMon:
-- abilityNum, IVs, EVs, nickname, friendship, OT id, PP Ups).  Never through
-- SoloBattle.gen3FoeMon, which reads none of abilityNum, nickname or PP Ups.
function M.facilityParty3(foe)
  if type(foe) ~= "table" then return nil, "no trainer" end
  local rows = (type(foe.party) == "table" and #foe.party > 0) and foe.party or { foe }
  local out = {}
  for _, row in ipairs(rows) do
    local mon, why = M.foeMon3(row, { wild = false })
    if not mon then return nil, why end
    out[#out + 1] = mon
  end
  return out
end

local function slice3(list, from, to)
  local out = {}
  for i = from, math.min(to, #list) do out[#out + 1] = list[i] end
  return out
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
--         defeatText?, double?, class3? }
--
-- `class3` is M.classify3's answer; absent, the stand-in is the plain kind
-- (`kind3` = "wild" / "trainer").  `coopRefused3` is what co-op will not fight
-- it for (nil: co-op may be offered it) -- set by the door builders below.
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
  local cls = type(args.class3) == "table" and args.class3 or { kind3 = kind }
  self.kind3 = cls.kind3 or kind
  self.facility3 = cls.facility3
  self.tutorial3 = cls.tutorial3
  self.firstBattle3 = cls.firstBattle3
  self.ghost3 = cls.ghost3
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
--
-- Which kinds run it is the cart's own start, per kind (pret pokeemerald
-- battle_setup.c): every wild start the field makes -- DoStandardWildBattle,
-- the roamer's, the Pike's, a scripted wild's, the legends', Birch's first
-- battle -- counts the day's wild battles and ticks the rematch clock, but
-- DoSafariBattle and StartWallyTutorialBattle do neither (the engine's own
-- start counts a Safari wild too; pret wins); a trainer ticks it from
-- DoTrainerBattle and DoBattlePyramidTrainerHillBattle, never from
-- DoSpecialTrainerBattle (the Frontier halls, the Secret Base, the e-Reader,
-- Steven).  FireRed / LeafGreen have no match call: Caps.gate answers no there.
local NO_WILD_START3 = { safari = true, tutorial = true }
local TRAINER_START_HALLS3 = { hill = true, pyramid = true }
function Stand:begin3()
  if self.began then return false end
  self.began = true
  if not self:sameSession() then return false end
  -- A Palace / Arena / Dome fight hangs its rules object on Battle._nextFacility
  -- for the engine's Battle.start to take (rse/frontier/palace.lua): the
  -- mod's fight takes it instead, or the next engine Frontier fight would
  -- inherit it.  Kept on the stand-in, and put back if it is handed back.
  self:takeFacility3()
  if self.kind == "trainer" then
    if self.kind3 == "partner"
       or (self.kind3 == "facility" and not TRAINER_START_HALLS3[self.facility3]) then
      M.trainerStart3(self, self.foe, self.opts, { noRematch = true })
    else
      M.trainerStart3(self, self.foe, self.opts)
    end
  elseif not NO_WILD_START3[self.kind3] then
    M.wildStart3()
  end
  return true
end

-- ------- what a stand-in borrowed from the engine, and gives back
--
-- Two things the engine left where its own Battle.start would pick them up,
-- held by the stand-in while the mod fights and put back the moment the fight
-- is handed to the cart (Stand:fightAlone, and a divert nobody took):
--
--   * the partner's monsters.  Steven's multi (natives_frontier_story.lua
--     doStevenBattle) and a Battle Tower multi (tower.lua doTowerBattle)
--     append the partner's three to session.party and say where the player's
--     half ends (`playerHalf`).  The mod's fight is the player's half against
--     two trainers with the partner on a seat of its own, so the stand-in
--     lifts them out (`partnerParty`) and session.party is the player's alone
--     -- the party every solo snapshot, reconcile and EXP pass reads.  The
--     script's own LoadPlayerParty puts the saved party back afterwards, as
--     on the cart.
--   * Battle._nextFacility (see Stand:begin3).
--   * the POKe DUDE's demonstration (M.pokedudeStand3, taken by the TEACHY TV
--     wrap's divertPokedude): what the engine's own startTeachyTvBattle does
--     around its battle (battle/pokedude.lua start(); pret teachy_tv.c:1172
--     TeachyTvPrepBattle) -- the TEACHY TV's layers off the modal stack and
--     the bag and START menus hidden (`teachyCover3`), the POKe DUDE's bag in
--     place of the player's (TeachyTv.initPokedudeBag, `teachyBag3`), and his
--     party in place of the player's (SavePlayerParty, then
--     InitPokedudePartyAndOpponent writing his monsters into gPlayerParty:
--     `partyBorrow3`), so the solo screen, its EXP and the evolutions after a
--     win read his monsters as the cart's battle does.  Each goes back on a
--     hand-back (giveBack3) and at the fight's end, in the stand's `done`
--     (TeachyTvRestorePlayerPartyCallback, :1208: LoadPlayerParty first).
--
-- The party and the bag are the save itself, so each swap is also recorded
-- in src/Borrow3.lua's ledger (`BORROW_PARTY3` / `BORROW_BAG3`) and released
-- when it goes back.  A demonstration that never reaches either end -- its
-- screen threw and was popped, an F5 hot reload mid-fight -- leaves the
-- record behind, and the `save.write` link gives the swap back before the
-- file is written (or refuses the write while the fight is really still on
-- screen: Stand:fightLive3).  What that backstop does *not* put back is the
-- cover: by the time a save is written the player is on the field with the
-- START menu's own layers on the modal stack, and swapping the TEACHY TV's
-- saved layers in over them (or reopening the bag menu under the save box)
-- would put a dead TEACHY TV over the save screen.  A stale cover is
-- forgotten instead; the TEACHY TV it lifted is closed, as if the player had
-- left it.

function Stand:detachPartner3(session, half)
  if type(session) ~= "table" or type(session.party) ~= "table" then return false end
  half = tonumber(half)
  if not half or half < 0 or #session.party <= half then return false end
  local mons = {}
  for i = half + 1, #session.party do mons[#mons + 1] = session.party[i] end
  for i = #session.party, half + 1, -1 do table.remove(session.party, i) end
  self.partnerParty = mons
  self.partnerDetached3 = { session = session, half = half, mons = mons }
  return true
end

function Stand:restorePartner3()
  local held = self.partnerDetached3
  if not held then return false end
  self.partnerDetached3 = nil
  local party = type(held.session) == "table" and held.session.party or nil
  if type(party) ~= "table" then return false end
  local at = math.min(held.half, #party)
  for i, mon in ipairs(held.mons) do table.insert(party, at + i, mon) end
  return true
end

local function battleModule3() return g3("src.core.game3.battle") end

function Stand:takeFacility3()
  local held = self.nextFacility3
  if held == nil then return false end
  local Battle = battleModule3()
  if type(Battle) == "table" and rawget(Battle, "_nextFacility") == held then
    Battle._nextFacility = nil
    return true
  end
  return false
end

function Stand:restoreFacility3()
  local held = self.nextFacility3
  if held == nil then return false end
  local Battle = battleModule3()
  if type(Battle) ~= "table" then return false end
  Battle._nextFacility = held
  return true
end

-- The ledger names this file's swaps go under (src/Borrow3.lua), and the
-- word a refused save says to the player for each.
local BORROW_PARTY3, BORROW_BAG3 = "pokedude.party", "pokedude.bag"
M.BORROW_PARTY3, M.BORROW_BAG3 = BORROW_PARTY3, BORROW_BAG3

-- Is the fight holding this stand's borrows really still running?  The
-- ledger's `alive` (src/Borrow3.lua), asked as a save is about to be written.
-- Not once the stand has finished or been handed back (its ends give
-- everything back themselves), not in a save other than its own, and
-- otherwise only while the screen fighting it is on the game3 modal stack:
-- `takingNow3` covers the one synchronous window between the borrows and the
-- taker's push (divertPokedude), and `holdsFn3` -- the door's
-- `handler.holds(stand)`, src/Client.lua -- names the screen solo is
-- fighting this stand on.  A screen that threw and was popped, or one a
-- reload left behind, is not on the stack: the borrow is stale.
function Stand:fightLive3()
  if self.finished or not self:sameSession() then return false end
  if self.takingNow3 then return true end
  local holds = self.holdsFn3
  if type(holds) ~= "function" then return false end
  local ok, screen = pcall(holds, self)
  return ok and type(screen) == "table" and Gen3Ui.has(screen) == true
end

-- The ledger's `giveBack` for one swap: put that swap back, and forget the
-- cover rather than restore it (see the section header -- the player is on
-- the field by now, and the stack is the START menu's).
function Stand:giveBackStale3(which)
  self.teachyCover3 = nil
  if which == "party" then return self:returnParty3() end
  return self:returnTeachyBag3()
end

local function holdBorrow3(stand, session, name, which, label)
  Borrow3.hold(session, name,
    function() return stand:giveBackStale3(which) end,
    function() return stand:fightLive3() end,
    label)
end

-- The fight's own party in place of the session's (pret SavePlayerParty, then
-- the demonstration's monsters written into gPlayerParty).  Once; false when
-- there is no session or no party to put in.
function Stand:borrowParty3(party)
  if self.partyBorrow3 then return true end
  local session = Gen3.session()
  if type(session) ~= "table" or type(party) ~= "table" or #party == 0 then return false end
  self.partyBorrow3 = { session = session, party = session.party }
  session.party = party
  holdBorrow3(self, session, BORROW_PARTY3, "party", "party")
  return true
end

-- LoadPlayerParty: the player's own party back, once (into the save it was
-- borrowed from).
function Stand:returnParty3()
  local held = self.partyBorrow3
  if not held then return false end
  self.partyBorrow3 = nil
  held.session.party = held.party
  Borrow3.release(held.session, BORROW_PARTY3)
  return true
end

-- The menus the engine's startTeachyTvBattle hides for its battle
-- (battle/pokedude.lua HIDDEN_MENUS / hide_menus): only a menu already loaded
-- can be open, so they are read where the engine reads them -- package.loaded,
-- through Gen3.loaded's gate, never a require.
local TEACHY_MENUS3 = { "src.ui.game3.bag_menu", "src.ui.game3.start_menu" }

-- The TEACHY TV off the screen while the fight runs, as the engine's own
-- start takes it off (pret teachy_tv.c:1175 TeachyTvFree): its layers lifted
-- off the modal stack whole -- the fight's screen is pushed onto an empty
-- stack, so nothing under it draws or takes input -- and an open bag or START
-- menu closed.  An engine_internals reach-around, the engine's own
-- (Stack._layers swapped by battle/pokedude.lua start / finish_battle);
-- docs/upstream/gen3-spawn-npc.md addendum D asks for the seam.
function Stand:coverTeachy3()
  if self.teachyCover3 then return true end
  local cover = { menus = {} }
  local Stack = g3("src.ui.game3.stack")
  if type(Stack) == "table" and type(Stack._layers) == "table" then
    cover.stack, cover.layers = Stack, Stack._layers
    Stack._layers = {}
  end
  for _, name in ipairs(TEACHY_MENUS3) do
    local menu = Gen3.loaded(name)
    if menu and menu.open then
      menu.open = false
      cover.menus[#cover.menus + 1] = menu
    end
  end
  self.teachyCover3 = cover
  return true
end

-- ...and back (finish_battle: Stack._layers = saved.layers, show_menus).
function Stand:uncoverTeachy3()
  local cover = self.teachyCover3
  if not cover then return false end
  self.teachyCover3 = nil
  if cover.stack then cover.stack._layers = cover.layers end
  for _, menu in ipairs(cover.menus) do menu.open = true end
  return true
end

-- The POKe DUDE's bag in place of the player's (the engine's start:
-- TeachyTv.initPokedudeBag, pret item_menu.c:2162 InitPokedudeBag after
-- BackUpPlayerBag).  Not over a swap somebody else made and has not undone.
function Stand:borrowTeachyBag3(scriptId)
  if self.teachyBag3 then return true end
  local session = Gen3.session()
  local TeachyTv = g3("src.core.game3.teachy_tv")
  if not (type(session) == "table" and TeachyTv and type(TeachyTv.initPokedudeBag) == "function") then
    return false
  end
  if session.teachyBagBackup ~= nil then return false end
  if not pcall(TeachyTv.initPokedudeBag, session, scriptId) then
    -- BackUpPlayerBag runs first: a swap that threw after it left the
    -- player's bag in the backup and (some of) the POKe DUDE's in the bag.
    -- There was no backup before the call, so whatever is there now is the
    -- player's own: put it back, or the next save writes his.
    if session.teachyBagBackup ~= nil then try3(TeachyTv.restorePlayerBag, session) end
    return false
  end
  self.teachyBag3 = session
  holdBorrow3(self, session, BORROW_BAG3, "bag", "bag")
  return true
end

-- RestorePlayerBag, for the swap this stand made.
function Stand:returnTeachyBag3()
  local session = self.teachyBag3
  if not session then return false end
  self.teachyBag3 = nil
  local TeachyTv = g3("src.core.game3.teachy_tv")
  if TeachyTv then try3(TeachyTv.restorePlayerBag, session) end
  Borrow3.release(session, BORROW_BAG3)
  return true
end

-- Everything borrowed goes back: the stand-in is the cart's again.
function Stand:giveBack3()
  self:returnParty3()
  self:returnTeachyBag3()
  self:uncoverTeachy3()
  self:restorePartner3()
  self:restoreFacility3()
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
  -- The cart's start reads what the stand-in borrowed (Stand:giveBack3).
  self:giveBack3()
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
  local session = Gen3.session() or (type(self.game) == "table" and self.game.session) or nil
  local lost = lostResult(outcome)
  local won = outcome == "win"
  local engineResult = won and "win" or "lose"
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
    -- Unfinished: the clock, a disconnect, a forfeit, or a knockout the
    -- referee already settled. Stop the script instead of running a
    -- beaten-trainer branch.
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

-- Both doors refuse what stays on the cart for everybody
-- (Config.SOLO_REFUSED_GEN3), classify the rest (M.classify3), and then:
--
--   * `ctx.solo` false (only co-op is listening -- SOLO BATTLES is off): a
--     kind co-op will not fight is refused here, before a monster is rolled
--     for it, exactly as before solo took those kinds over;
--   * `ctx.solo` true: the stand-in is built for every kind, and the reason
--     co-op will not fight it rides on it as `stand.coopRefused3` -- the
--     divert (src/Client.lua offerFight3) then never puts it to co-op.
--
-- Every stand-in carries `kind3` (and `facility3` / `tutorial3` /
-- `firstBattle3` / `ghost3` where they apply), and the kind's own fields:
--
--   safari     `safari = true`
--   roamer     `roamer = true`, `roamerFoe` (the save's descriptor)
--   pair       `trainerIdB`, `trainerB` (record), `enemyPartyB`, `defeatTextB`
--   partner    `partner = true`, `playerHalf`, `partnerTrainerId`,
--              `partnerBackPic`, `partnerTrainer` (record), `partnerParty`
--   facility   `trainer` (M.facilityRecord3), the facility's own monsters,
--              `nextFacility3` (the engine's Battle._nextFacility, if any);
--              a facility pair or multi carries the pair / partner fields too
--   any        `scriptedLoss` (the start's: a loss is the script's to answer,
--              no whiteout -- battle_bridge.lua writeback)

-- Whether a wild foe rolls a held item at all: pret SetWildMonHeldItem
-- skips a LEGENDARY battle (FireRed's GHOST_UNVEILED is that bit), the POKe
-- DUDE, the Pike and the Pyramid.  SoloBattle.gen3HeldRoll is the one
-- statement of that gate (read off the opts and the foe row); the kind is
-- the answer for a graph without SoloBattle (never in play).
local function heldRoll3(cls, opts, spec)
  local Solo = solo3()
  if Solo and type(Solo.gen3HeldRoll) == "function" then
    local ok, roll = pcall(Solo.gen3HeldRoll, opts, spec)
    if ok then return roll ~= false end
  end
  local kind = type(cls) == "table" and cls.kind3 or "wild"
  return not (kind == "legendary" or kind == "facility"
              or (kind == "ghost" and cls.ghost3 == "unveiled"))
end

-- The wild foe of each kind, built as the cart builds it.  `mapId` is the
-- map it is met on: Emerald's ALTERING CAVE rolls the cave's own held items
-- (M.alteringCave3).
function M.wildFoe3(cls, enc, session, opts, mapId)
  local kind = type(cls) == "table" and cls.kind3 or "wild"
  local spec = enc
  if kind == "roamer" then
    -- pret CreateRoamerMonInstance (roamer.c): the saved species, level, IVs
    -- and personality, then the saved HP and status.  The encounter carries
    -- them as its `foe` (roamer.lua tryEncounter); the engine's own battle
    -- builds the encounter's outer species and level instead and re-rolls the
    -- rest (battle/init.lua foe_mon_from) -- pret wins.  A roamer is an
    -- ordinary wild to SetWildMonHeldItem: rolled.
    spec = type(enc.foe) == "table" and enc.foe or enc
  end
  local roll = heldRoll3(cls, opts, spec)
  if kind == "firstBattle" then
    -- Birch's ZIGZAGOON: pret zeroes its item (pokeemerald battle_controllers.c
    -- SetUpBattleVarsAndBirchZigzagoon) and SetWildMonHeldItem then rolls it
    -- once (battle_main.c:700; FIRST_BATTLE is not exempt).  That one roll is
    -- the kind's (src/Solo3/First.lua rollHeldItem, in its `takes`, on the
    -- monster built here still holding the start's zeroed item) -- rolled here
    -- too, it would be drawn twice.
    roll = false
  end
  return M.foeMon3(spec, { wild = roll, session = session,
    alteringCave = M.alteringCave3(mapId) })
end

local function cleanDefeat3(text)
  local clean = cleanText3(text)
  return clean and (clean:gsub("\n\n", "\f")) or nil
end

-- The fields every door stamps once the stand-in is built.
local function stamp3(stand, cls, coop, opts)
  stand.coopRefused3 = coop
  stand.scriptedLoss = set3(opts.scriptedLoss) or nil
  if cls.kind3 == "facility" and set3(opts.frontier) then
    local Battle = battleModule3()
    stand.nextFacility3 = type(Battle) == "table" and rawget(Battle, "_nextFacility") or nil
  end
  return stand
end

-- The wild door: `encounter.roll`'s encounter, or the foe a wild
-- BattleBridge.start was handed (`opts` its start opts).  nil + reason when
-- nobody listening may take it.
function M.wildStand3(enc, ctx, opts)
  ctx = ctx or {}
  if type(enc) ~= "table" then return nil, "no encounter" end
  opts = type(opts) == "table" and opts or {}
  local refused = M.soloRefused3(enc, enc.foe, opts)
  if refused then return nil, refused end
  local session = Gen3.session()
  local cls = M.classify3(true, enc, opts, { mapId = ctx.mapId, session = session })
  -- A foe record riding on the encounter is a roamer's (Roamer.tryEncounter
  -- returns { roamer, foe }); anything else carrying one is a shape nothing
  -- here knows, and the cart's.
  if enc.foe ~= nil and cls.kind3 ~= "roamer" then return nil, "foe" end
  local coop = M.coopRefusal3(cls, enc, enc.foe, opts)
  if coop and not ctx.solo then return nil, coop end
  local mon, why = M.wildFoe3(cls, enc, session, opts, ctx.mapId)
  if not mon then return nil, why end
  local stand = M.stand3({
    kind = "wild", party = { mon }, encounter = enc, game = ctx.game,
    mapId = ctx.mapId, fightAlone = ctx.fightAlone, opts = opts, done = opts.done,
    class3 = cls,
  })
  stamp3(stand, cls, coop, opts)
  if cls.kind3 == "safari" then stand.safari = true end
  if cls.kind3 == "roamer" then
    stand.roamer = true
    stand.roamerFoe = type(enc.foe) == "table" and enc.foe or enc
  end
  return stand
end

-- A two-trainer fight's second trainer (pret battle_main.c:1977
-- CreateNPCTrainerParty(&gEnemyParty[3], B)): built the way the first is,
-- through the `trainer.party` hook with B's own id, cut like A's to three.
local function trainerB3(opts, ctx)
  local tidB = tonumber(opts.trainerIdB)
  if not tidB then return nil, nil, "no second trainer" end
  local Trainers = g3("src.core.game3.scripting.trainers")
  local foeB = Trainers and try3(Trainers.foeFromId, tidB) or nil
  if type(foeB) ~= "table" then return nil, nil, "no second trainer" end
  local partyB, why = M.trainerParty3(foeB, tidB)
  if not partyB then return nil, nil, why end
  local trainerB = M.trainerRecord3(foeB, { trainerId = tidB, game = ctx.game })
  if trainerB then trainerB.defeatText = cleanText3(opts.defeatTextB) end
  return slice3(partyB, 1, 3), trainerB
end

-- The partner a multi gives the player (Steven; a Battle Tower partner): who
-- it is, and its monsters lifted out of session.party (Stand:detachPartner3).
local function partner3(stand, opts, ctx, session, cls)
  stand.partner = true
  stand.playerHalf = tonumber(opts.playerHalf)
  stand.partnerTrainerId = tonumber(opts.partnerTrainerId)
  stand.partnerBackPic = opts.partnerBackPic
  local record
  if cls.kind3 == "facility" then
    local name, pic = label3(opts.partnerName), tonumber(opts.partnerPicId)
    record = { name = name, trainerName = name, pic = pic, trainerPic = pic,
               frontierTrainerId = tonumber(opts.frontierPartner), facility = cls.facility3 }
  elseif stand.partnerTrainerId then
    record = M.trainerRecord3(stand.partnerTrainerId, { game = ctx.game })
  end
  stand.partnerTrainer = record
  stand:detachPartner3(session, stand.playerHalf)
end

-- The trainer door (BattleBridge.start): nil + reason when nobody listening
-- may take the start.
function M.trainerStand3(foe, opts, ctx)
  ctx = ctx or {}
  opts = opts or {}
  if opts.wild then return nil, "wild" end
  if opts.link or (type(foe) == "table" and foe.link) then return nil, "link" end
  if opts.headless then return nil, "headless" end
  local refused = M.soloRefused3(opts, foe)
  if refused then return nil, refused end
  local session = Gen3.session()
  local cls = M.classify3(false, foe, opts, { mapId = ctx.mapId, session = session })
  local coop = M.coopRefusal3(cls, opts, foe)
  if coop and not ctx.solo then return nil, coop end
  local double = (set3(opts.double) or (type(foe) == "table" and set3(foe.doubleBattle)))
    and true or nil
  local stand, partyB, trainerB
  if cls.kind3 == "facility" then
    -- A facility trainer is no gTrainers row and has no id to ask one for
    -- (the Frontier passes none; FireRed's tower and e-Reader pass 0).
    local all, why = M.facilityParty3(foe)
    if not all then return nil, why end
    local party = all
    -- A facility pair (the Pike double; a Tower multi) arrives as one party,
    -- A's half first (battle_bridge: `frontierFoeHalf`).
    local half = tonumber(opts.frontierFoeHalf)
    if set3(opts.twoOpponents) and half and half > 0 and half < #all then
      party, partyB = slice3(all, 1, half), slice3(all, half + 1, #all)
      trainerB = M.facilityRecord3(foe, opts, cls.facility3, session, "B")
    end
    stand = M.stand3({
      kind = "trainer", party = party, foe = foe, opts = opts, game = ctx.game,
      trainer = M.facilityRecord3(foe, opts, cls.facility3, session),
      mapId = ctx.mapId, defeatText = opts.defeatText, double = double,
      fightAlone = ctx.fightAlone, done = opts.done, class3 = cls,
    })
  else
    local tid = tonumber(opts.trainerId) or tonumber(type(foe) == "table" and foe.trainerId)
    if not tid then return nil, "no trainer id" end
    local party, why = M.trainerParty3(foe, tid)
    if not party then return nil, why end
    if opts.trainerIdB ~= nil then
      -- pret battle_main.c:1977: each of two trainers fields min(partySize, 3).
      party = slice3(party, 1, 3)
      partyB, trainerB, why = trainerB3(opts, ctx)
      if not partyB then return nil, why end
      double = true
    end
    local trainer = M.trainerRecord3(foe, { trainerId = tid, trainerName = opts.trainerName,
      trainerClassName = opts.trainerClassName, trainerClass = opts.trainerClass,
      trainerPicId = opts.trainerPicId, game = ctx.game })
    stand = M.stand3({
      kind = "trainer", party = party, trainer = trainer, foe = foe, opts = opts,
      game = ctx.game, mapId = ctx.mapId, defeatText = opts.defeatText,
      double = double, fightAlone = ctx.fightAlone, done = opts.done, class3 = cls,
    })
  end
  stamp3(stand, cls, coop, opts)
  if partyB then
    stand.enemyPartyB = partyB
    stand.trainerB = trainerB
    stand.trainerIdB = tonumber(opts.trainerIdB)
    stand.defeatTextB = cleanDefeat3(opts.defeatTextB)
  end
  if set3(opts.partner) then partner3(stand, opts, ctx, session, cls) end
  return stand
end

-- The TEACHY TV's demonstration (battle/pokedude.lua startTeachyTvBattle):
-- both parties as the cart builds them (Pokedude.build, pret
-- battle_controller_pokedude.c InitPokedudePartyAndOpponent), the POKe DUDE's
-- monsters on the player's side (`playerParty`), the demonstration's number
-- (`pokedudeScript`), and a `done` that answers the TEACHY TV the way the
-- cart's battle ends (pret teachy_tv.c:1208 TeachyTvRestorePlayerPartyCallback,
-- the engine's finish_battle): the player's party back (LoadPlayerParty, the
-- swap divertPokedude made -- Stand:borrowParty3), the player's bag back
-- (TeachyTv.restorePlayerBag, a no-op unless the demonstration swapped it), the
-- TEACHY TV's layers and menus back (Stand:uncoverTeachy3), then the outcome
-- code.  Never co-op's (`coopRefused3 = "pokedude"`).
local function pokedudeCode3(Pokedude, word)
  local O = type(Pokedude) == "table" and type(Pokedude.OUTCOME) == "table" and Pokedude.OUTCOME
    or { WON = 1, LOST = 2, DREW = 3, RAN = 4, CAUGHT = 7 }
  if word == "draw" then return O.DREW end
  if word == "catch" or word == "caught" then return O.CAUGHT end
  if lostResult(word) then return O.LOST end
  if word == "run" then return O.RAN end
  return O.WON
end
M.pokedudeCode3 = pokedudeCode3

function M.pokedudeStand3(session, scriptId, opts, ctx)
  ctx = ctx or {}
  opts = type(opts) == "table" and opts or {}
  local Pokedude = g3("src.core.game3.battle.pokedude")
  if not (Pokedude and type(Pokedude.build) == "function") then return nil, "no POKe DUDE" end
  local ok, party, foes = pcall(Pokedude.build, scriptId)
  if not (ok and type(party) == "table" and type(foes) == "table" and type(foes[1]) == "table") then
    return nil, "no demonstration party"
  end
  local lead = foes[1]
  local cls = { kind3 = "tutorial", tutorial3 = "pokedude" }
  local stand
  local function done(word)
    if stand then stand:returnParty3() end
    -- The stand's own swap through its own return (which also clears its
    -- ledger record, src/Borrow3.lua); RestorePlayerBag regardless when it
    -- made none, as finish_battle calls it.
    if not (stand and stand:returnTeachyBag3()) then
      local TeachyTv = g3("src.core.game3.teachy_tv")
      if TeachyTv then try3(TeachyTv.restorePlayerBag, session) end
    end
    if stand then stand:uncoverTeachy3() end
    if type(opts.onDone) == "function" then opts.onDone(pokedudeCode3(Pokedude, word)) end
  end
  stand = M.stand3({
    kind = "wild", party = foes, game = ctx.game, mapId = ctx.mapId,
    encounter = { species = tonumber(lead.species), speciesId = tonumber(lead.species),
                  level = lead.level, pokedude = true },
    -- What startTeachyTvBattle hands Battle.start besides the parties.
    opts = { wild = true, pokedude = true, pdScriptNum = tonumber(scriptId) },
    fightAlone = ctx.fightAlone, done = done, class3 = cls,
  })
  stand.coopRefused3 = "pokedude"
  stand.pokedudeScript = tonumber(scriptId)
  stand.playerParty = party
  stand.teachyOpts = opts
  return stand
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
-- bookkeeping and the Elite Four's league friendship.  `how.noRematch` for a
-- special battle, which pret never ticks the clock for (Stand:begin3).
function M.trainerStart3(stand, foe, opts, how)
  local session = Gen3.session()
  if not session then return end
  local Caps = g3("src.core.game3.capabilities")
  if not (type(how) == "table" and how.noRematch)
     and Caps and try3(Caps.gate, session, "match_call") then
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
  handler = nil,   -- { wants = fn(kind, mapId) -> false | true | "solo",
                   --   take = fn(stand, foe, opts, kind) -> bool, skipWild = fn() }
}

-- The engine's own start, whatever is installed over it.
function M.originalStart3()
  local BB = (start3.handle and start3.handle.module)
    or g3("src.core.game3.battle_bridge")
  if not BB then return nil end
  return rawget(BB, START_KEY) or BB.start
end

-- A trainer start, and a wild one that did not come through `encounter.roll`
-- (fishing, Rock Smash, Sweet Scent, and every scripted, legendary, ghost,
-- tutorial, first-battle or facility wild -- the stand-in says which kind,
-- M.classify3; co-op is put only the plain ones, solo the rest).  A step
-- encounter the roll hook already offered is not offered twice:
-- `handler.skipWild()` says so.  Nor is a fight this mod is handing back to
-- the cart (`opts[M.HANDBACK3]`), which is the cart's now.
--
-- `handler.wants(kind, mapId)` answers who is listening: false nobody, "solo"
-- SOLO BATTLES is on (every kind it takes is built), anything else truthy
-- only co-op (a kind co-op will not fight is refused before it is built).
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
  local want = true
  if type(handler.wants) == "function" then want = handler.wants(kind, mapId) end
  if not want then return false end
  local ctx = {
    game = game, mapId = mapId, solo = want == "solo",
    fightAlone = function() return inner(modArg, game, foe, opts) end,
  }
  local stand
  if kind == "wild" then
    stand = M.wildStand3(foe, ctx, opts)
  else
    stand = M.trainerStand3(foe, opts, ctx)
  end
  if not stand then return false end
  local ok, taken = pcall(handler.take, stand, foe, opts, kind)
  if ok and taken == true then return true end
  -- Nobody took it: the cart's start runs next, with what it left in place.
  stand:giveBack3()
  if not ok then error(taken, 0) end
  return false
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

-- ------- the TEACHY TV start wrap (an engine_internals reach-around)
--
-- The POKe DUDE's demonstrations never reach BattleBridge.start: the TEACHY
-- TV (teachy_tv.lua startDemonstration) calls battle/pokedude.lua
-- Pokedude.startTeachyTvBattle, which hides the TEACHY TV's layers, swaps in
-- the POKe DUDE's bag and calls Battle.start itself (pret teachy_tv.c:1172
-- TeachyTvPrepBattle).  So that one function is wrapped, with the start
-- wrap's discipline: Gen3.wrapFn keeps the pristine original on the module, a
-- hot reload peels this mod's own previous wrapper rather than stacking on it,
-- the wrapper retires itself for a stale instance (alive() / Gen3.wrapLive) and
-- answers what the engine would, and a demonstration handed back is the
-- wrapped function itself, called with the TEACHY TV's own arguments.  What
-- the wrapped start does around its battle -- the music, the transition, the
-- TEACHY TV off the stack, the bag and party swaps -- the divert does around
-- the solo fight (divertPokedude), and gives back with the fight.
--
-- It takes a demonstration only when SOLO BATTLES is on (`handler.wants`);
-- co-op has nothing to join in a cutscene.  The TEACHY TV's own
-- `onDemonstration` slot is not used: it is one slot, a replacement rather
-- than a chain, and the engine's tests own it.  docs/upstream/gen3-spawn-npc.md
-- is where the seam that would retire this wrap belongs.

local POKEDUDE_KEY = "__rby_mmo_pokedude"
local pokedude3 = {
  handle = nil,
  retired = false,
  -- { wants = fn("tutorial") -> bool, take = fn(stand) -> bool, game = fn()?,
  --   holds = fn(stand) -> the screen fighting it, or nil (Stand:fightLive3) }
  handler = nil,
}

-- The engine's own demonstration start, whatever is installed over it.
function M.originalPokedude3()
  local Pokedude = (pokedude3.handle and pokedude3.handle.module)
    or g3("src.core.game3.battle.pokedude")
  if not Pokedude then return nil end
  return rawget(Pokedude, POKEDUDE_KEY) or Pokedude.startTeachyTvBattle
end

-- The cart's own demonstration in place of the divert's (Stand:fightAlone's
-- start, and a demonstration solo would not take): the wrapped function with
-- the TEACHY TV's own arguments -- its music and transition, then its battle.
-- `introPlayed`: the divert already played both (a borrow or the take failed
-- once its transition was over), so the cart's start is asked for its battle
-- alone -- a copy of the TEACHY TV's opts with the engine's own `headless`,
-- which is exactly startTeachyTvBattle's start() with no PlayMapChosenOrBattleBGM
-- and no BattleTransition_StartOnField (the same lift, bag swap, Battle.start
-- and finish_battle; `onDone` and `transition` ride along in the copy).
-- Without it the player heard the battle music start over and saw the
-- transition play a second time.
local function teachyFallback3(inner, session, scriptId, opts, introPlayed)
  local args = opts
  if introPlayed then
    args = {}
    if type(opts) == "table" then for k, v in pairs(opts) do args[k] = v end end
    args.headless = true
  end
  local ok, err = pcall(inner, session, scriptId, args)
  if not ok then
    mod.log:warn("the TEACHY TV's own demonstration could not start (%s); close the TEACHY TV "
      .. "and choose the program again -- report it with the program you chose", tostring(err))
  end
  return ok and err
end

-- What the engine's own start does before its battle (battle/pokedude.lua
-- startTeachyTvBattle; pret teachy_tv.c:1172 TeachyTvPrepBattle): the battle
-- music (PlayMapChosenOrBattleBGM -- a wild battle's, MUS_VS_WILD, as the
-- engine plays it), then the transition over the TEACHY TV -- the cart's for
-- the program, WHITE_BARS_FADE for the battle basics and SLICE for the rest
-- (TeachyTv.battleTransition; the TEACHY TV hands it as `opts.transition`) --
-- and, once it has played, the battle: here the TEACHY TV taken off the
-- screen (Stand:coverTeachy3), the POKe DUDE's bag and party in
-- (Stand:borrowTeachyBag3, Stand:borrowParty3), then the solo fight offered.
-- The start answers "started" at once, as the engine's does; a fight solo
-- will not take after the transition gets everything back (Stand:giveBack3)
-- and is the cart's own demonstration, from its own start -- its battle
-- alone, since the intro has played (teachyFallback3's `introPlayed`).
--
-- The borrows are not decided before the intro: the swap is the engine's
-- after-the-transition step (start()), and the taker's screen can only go up
-- once the transition is over, so neither answer exists earlier.
--
-- Before anything is borrowed, the ledger (src/Borrow3.lua) is settled: a
-- demonstration that died mid-fight with no save since left the POKe DUDE's
-- party and bag in the session, and borrowing over them would file *his*
-- monsters as the player's own to give back.
local function divertPokedude(inner, session, scriptId, opts)
  local handler = pokedude3.handler
  if not (handler and type(handler.take) == "function") then return false end
  local o = type(opts) == "table" and opts or {}
  if o.headless or o[M.HANDBACK3] then return false end
  if type(handler.wants) == "function" and not handler.wants("tutorial") then return false end
  -- The engine's own refusal (startTeachyTvBattle: a battle already running).
  local Battle = battleModule3()
  if type(Battle) == "table" and try3(Battle.isActive) then return false end
  local game = type(handler.game) == "function" and handler.game() or nil
  local stand = M.pokedudeStand3(session, scriptId, o, {
    game = game,
    fightAlone = function() return inner(session, scriptId, opts) end,
  })
  if not stand then return false end
  stand.holdsFn3 = type(handler.holds) == "function" and handler.holds or nil
  local function begin()
    local live = Gen3.session()
    if live then
      local ok, restored = pcall(Borrow3.settle, live)
      if ok and type(restored) == "number" and restored > 0 then
        mod.log:info("gave back %d item(s) an unfinished battle had borrowed", restored)
      end
    end
    stand:coverTeachy3()
    -- Both borrows, or neither fight: a demonstration that kept the player's
    -- bag or party would play the POKe DUDE's script against the wrong one.
    if not stand:borrowTeachyBag3(scriptId) or not stand:borrowParty3(stand.playerParty) then
      stand:giveBack3()
      teachyFallback3(inner, session, scriptId, opts, true)
      return
    end
    stand.takingNow3 = true
    local ok, taken = pcall(handler.take, stand)
    stand.takingNow3 = nil
    if ok and taken == true then return end
    stand:giveBack3()
    if not ok then
      mod.log:warn("the TEACHY TV divert failed (%s); this demonstration is shown on the "
        .. "game's own battle screen -- turn SOLO BATTLES off in the mod manager (F10) if "
        .. "it keeps happening", tostring(taken))
    end
    teachyFallback3(inner, session, scriptId, opts, true)
  end
  Gen3.audio.playSong("MUS_VS_WILD")
  local BT = g3("src.core.game3.battle_transition")
  local TeachyTv = g3("src.core.game3.teachy_tv")
  local id = o.transition or (TeachyTv and try3(TeachyTv.battleTransition, scriptId))
    or (BT and try3(function() return BT.ID.SLICE end)) or nil
  if BT and type(BT.start) == "function" and id ~= nil then
    local ok = pcall(BT.start, id, { overUi = true }, begin)
    if ok then return true end
  end
  -- No transition to play (a build without one): the battle at once.
  begin()
  return true
end

function M.installPokedude3(handler)
  pokedude3.handler = handler
  if pokedude3.handle and Gen3.wrapLive(pokedude3.handle) then
    pokedude3.retired = false
    return true
  end
  local Pokedude = g3("src.core.game3.battle.pokedude")
  -- A build without the TEACHY TV's battles: nothing to divert, and nothing
  -- the player can miss.
  if not (Pokedude and type(Pokedude.startTeachyTvBattle) == "function") then return false end
  local handle
  handle = Gen3.wrapFn(Pokedude, "startTeachyTvBattle", POKEDUDE_KEY, function(inner)
    return function(session, scriptId, opts)
      if not pokedude3.retired and Gen3.wrapLive(handle) and alive() then
        local ok, taken = pcall(divertPokedude, inner, session, scriptId, opts)
        if ok and taken then return true end
        if not ok then
          mod.log:warn("the TEACHY TV divert failed (%s); this demonstration is shown "
            .. "on the game's own battle screen -- turn SOLO BATTLES off in the mod "
            .. "manager (F10) if it keeps happening", tostring(taken))
        end
      end
      return inner(session, scriptId, opts)
    end
  end)
  if not handle then return false end
  pokedude3.handle, pokedude3.retired = handle, false
  return true
end

-- Put back what the wrapper wrapped, when the slot still holds it; under
-- somebody else's wrapper ours is retired in place.
function M.restorePokedude3()
  if not pokedude3.handle then return false end
  pokedude3.retired = true
  if Gen3.unwrapFn(pokedude3.handle) then pokedude3.handle = nil end
  return true
end

function M.pokedude3Installed()
  return pokedude3.handle ~= nil and not pokedude3.retired
end

return M
