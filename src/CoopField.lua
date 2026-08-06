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

local need, mod = ...

local M = {}

-- Built on first use, because `BattleState` is the metatable's parent and
-- requiring it at file scope would drag the whole renderer into a headless
-- validate.
local Field, engine

-- deps: { BattleState, Strings } -- handed in by CoopBattle, which is the only
-- caller that has an engine to hand.
function M.build(deps)
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
  local Cls = M.build(deps)
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
      events[#events + 1] = { kind = "anim", anim = tostring(row.anim) }
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

return M
