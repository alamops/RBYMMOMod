-- The 2-on-2 simulation: four battlers, one turn at a time.
--
-- **This is the part Gen1Recomp does not have, and this file is where it is
-- added.** The engine's `BattleState` carries exactly one active battler per
-- side and `TurnOrder.firstMover` compares a pair; neither can be talked into
-- a four-monster field. So the *field* is modelled here -- four slots, an
-- ordering over all of them, a target on every action, and a faint that pulls
-- the next mon out of that trainer's own party -- and everything underneath it
-- is still the engine's.
--
-- What is emphatically **not** reimplemented: damage. Type effectiveness, STAB,
-- the critical-hit shift chain, the badge boosts, burn's attack cut, screens,
-- the 217..255 random factor -- all of it comes from `src/battle/Damage.lua`
-- through the `damage` seam below, so a mon hits for the same number in a
-- co-op battle as it does in a wild one. A second damage formula living in a
-- mod would be a second answer to a question the engine has already answered,
-- and the two would drift on the first ruleset change.
--
-- **Nothing here requires an engine module, or love.** Every engine part
-- arrives through `deps` at construction. That is what lets the suite drive a
-- whole battle -- four slots, faints, switches, a winner -- under plain luajit
-- with hand-built mons, which is the only way the turn order and the target
-- rules get asserted at all.
--
-- The output is a list of **events**, never a mutated screen. One side
-- simulates and the other three replay what it produces (see CoopBattle's
-- header for why it is host-authoritative rather than four-way lockstep), and
-- a replayed battle and a simulated one have to look identical -- which they
-- do, because the events are the only thing either of them draws from.

local need = ...
local Config = need("Config")

local M = {}
M.__index = M

-- ------- construction

-- deps: { data, ruleset, damage, status, turnOrder, rng }
--
-- `damage` is src/battle/Damage.lua, `turnOrder` is src/battle/TurnOrder.lua
-- and `status` is src/battle/Status.lua -- handed in rather than required so
-- this file stays loadable, and drivable, with none of them present.
--
-- slots: four, in the order a1, a2, b1, b2.  Each is
--   { side = "a"|"b", owner = <player id or nil for an NPC>, name = "ANN",
--     party = { mon, ... }, index = 1 }
function M.new(deps, slots)
  local self = setmetatable({
    data = deps.data,
    ruleset = deps.ruleset or {},
    damage = deps.damage,
    status = deps.status,
    turnOrder = deps.turnOrder,
    rng = deps.rng or function(a, b) return a end,
    makeBattler = deps.makeBattler,
    -- The BattleState-shaped adapter (src/CoopField.lua). Present in a real
    -- battle and absent under the headless suite, which is the whole reason
    -- runAction has a fallback at all.
    fieldObj = deps.field,
    drain = deps.drain,
    -- src/inventory/ItemEffects.use, and the save its items come out of.
    itemUse = deps.itemUse,
    -- src/battle/Experience.lua. A trainer battle that awarded nothing would
    -- be a trainer battle you would never fight twice.
    experience = deps.experience,
    -- src/battle/Experience.lua's movesLearnedAt, handed in beside apply so
    -- this file still loads without the engine.
    movesAt = deps.movesAt,
    -- src/battle/TrainerAI.lua, and the trainer record the NPC side came from.
    -- Both are needed: the move layers read the battler, the class actions
    -- read who the trainer is.
    trainerAI = deps.trainerAI,
    trainer = deps.trainer,
    aiUses = deps.aiUses or 0,
    save = deps.save,
    onError = deps.onError,
    slots = {},
    -- Battlers knocked down inside one action, acted on once it finishes: the
    -- engine's pipeline can faint two at a time (Explosion, recoil, a
    -- multi-hit) and a send-out mid-action would put a fresh mon in front of a
    -- move that is still resolving.
    pendingFaints = {},
    turn = 0,
    over = nil,
  }, M)

  for i, raw in ipairs(slots or {}) do
    self.slots[i] = {
      index = i,
      side = raw.side,
      owner = raw.owner,
      name = raw.name or ("P" .. i),
      party = raw.party or {},
      active = raw.active or 1,
      -- This trainer's own items, if they have any. A player brings their bag;
      -- an NPC brings nothing, which is what stops a gym leader spamming a
      -- SUPER POTION it was never given.
      bag = raw.bag,
      -- The badges this trainer has earned, as the set `makeBattler` reads.
      --
      -- It has to come in with the slot rather than be looked up: the host
      -- builds all four battlers and holds only its own save, so a badge set
      -- read locally would give the host's own boosts to everybody and nobody
      -- else theirs. Absent is a real answer -- see Coop's buildField for the
      -- two cases, and why one of them deliberately has none.
      badges = raw.badges,
      battler = nil,
    }
    self:sendOut(self.slots[i], self.slots[i].active)
  end
  return self
end

-- Build the battler for a slot's current mon.
--
-- Through the engine's own `BattleState.makeBattler` when one was handed in,
-- because that is what attaches the merged status registry, the badge rows and
-- the battle sprite -- the three things `Damage.compute` and the renderer read
-- and neither of which this file should be inventing. The fallback exists for
-- the suite, which has no engine to ask.
function M:sendOut(slot, index)
  local mon = slot.party[index]
  if not mon then
    slot.battler = nil
    return nil
  end
  slot.active = index
  slot.announced = false
  -- Whoever seeded the monster that just left seeded *that* monster. The one
  -- arriving carries no Leech Seed (`leechSeeded` lives on the battler, and this
  -- is a new one), so the pointer that says where the drain goes has to go with
  -- it -- otherwise a fresh monster would start feeding a trainer it never met.
  slot.seededBy = nil
  -- Whatever this slot was being waited for, it has answered. Cleared here
  -- rather than only in `replace` so a *replayer* -- which never sets
  -- `awaiting` itself but is told about the choice, and is told about the
  -- monster that answers it -- tracks the same state the host does. Without
  -- that, the three clients watching cannot tell a paused field from a
  -- running one, and so cannot say who everyone is waiting for.
  slot.awaiting = nil
  if self.makeBattler then
    -- A save-shaped stand-in carrying nothing but the badges, because that is
    -- the only field `makeBattler` reads off it. Passing the real save would
    -- work for exactly one of the four slots and be wrong for the other three.
    local save = slot.badges and { inventory = slot.badges } or nil
    slot.battler = self.makeBattler(self.data, mon, slot.side == "a", save)
  else
    local def = (self.data.pokemon or {})[mon.species] or { types = {}, baseStats = {} }
    slot.battler = {
      mon = mon, def = def, name = mon.nickname or def.name or mon.species,
      isPlayer = slot.side == "a", stages = {},
      -- The HP the bar is currently showing, which trails `mon.hp` while a
      -- drain plays. `makeBattler` sets it and this table did not, so anything
      -- reading a battler's displayed HP got nil from the fallback and
      -- silently fell back to the true HP -- a bar with no descent left in it.
      shownHP = mon.hp,
      curStats = mon.stats, curTypes = def.types, curMoves = mon.moves,
      statuses = self.data.statuses,
      -- Carried here too, and gated the same way the engine gates it, so a
      -- build with no BattleState to ask does not quietly fight a different
      -- battle from one that has it.
      badges = (slot.side == "a") and slot.badges or nil,
      badgeBoosts = self.data.constants and self.data.constants.badgeBoosts,
    }
  end
  return slot.battler
end

-- ------- what the field looks like, in one string
--
-- The whole of a replayer's state that the host also knows: for each slot, who
-- is out, on how much HP, and whether they have forfeited. It exists so the
-- two can be *compared* -- a host-authoritative battle where nobody ever
-- checks the copies agree is a battle that can silently show two players
-- different things until one of them acts on a number that was never true.
--
-- Deliberately not a hash. It is short, it is compared as a whole, and when it
-- differs the difference itself is the diagnosis -- a digest would only say
-- "somewhere".
function M:signature()
  local parts = {}
  for i, slot in ipairs(self.slots) do
    local mon = slot.battler and slot.battler.mon
    parts[#parts + 1] = table.concat({
      i, slot.active or 0, (mon and mon.hp) or -1, slot.gone and 1 or 0,
    }, ":")
  end
  return table.concat(parts, "|")
end

-- The field as data, for a replayer that has fallen behind to be put right.
function M:snapshot()
  local out = {}
  for i, slot in ipairs(self.slots) do
    local mon = slot.battler and slot.battler.mon
    out[i] = {
      active = slot.active,
      hp = (mon and mon.hp) or 0,
      gone = slot.gone and true or false,
    }
  end
  return out
end

-- Put this field back to what the host says it is.
--
-- Only ever called on a replayer, and only after a gap or a mismatch: it is
-- the recovery, not the normal path. Sends the right monster out if the host
-- has one out that this copy does not.
function M:restore(snapshot)
  if type(snapshot) ~= "table" then return false end
  for i, slot in ipairs(self.slots) do
    local row = snapshot[i]
    if type(row) == "table" then
      -- A different monster out means a different monster to un-seed, and
      -- `sendOut` drops the pointer for us. One that is still the same monster
      -- keeps it: a snapshot carries HP and who is out, not volatiles, so the
      -- seed pointer this copy already holds is the better answer than nil.
      if row.active and row.active ~= slot.active then
        self:sendOut(slot, row.active)
      end
      local mon = slot.battler and slot.battler.mon
      if mon and tonumber(row.hp) then mon.hp = math.max(0, math.floor(row.hp)) end
      slot.gone = row.gone and true or false
    end
  end
  return true
end

-- ------- reading the field

function M:slot(i) return self.slots[i] end

-- Down, or gone.
--
-- A trainer whose player closed the game is out of the fight exactly as surely
-- as one whose last monster fell -- and treating the two the same is what
-- stops a disconnect deadlocking the other three: a gone slot is never waited
-- on for an action and never counted as still standing.
function M:isDown(slot)
  if slot and slot.gone then return true end
  return not (slot and slot.battler and slot.battler.mon
              and (slot.battler.mon.hp or 0) > 0)
end

-- Their player left. The slot forfeits: no more actions, no reserve, and the
-- side is beaten once both of its trainers are in that state.
function M:forfeit(id)
  for _, slot in ipairs(self.slots) do
    if slot.owner and slot.owner == id and not slot.gone then
      slot.gone = true
      slot.announced = true
      slot.awaiting = nil
      return slot
    end
  end
  return nil
end

-- Everyone still standing, in slot order.
function M:living(side)
  local out = {}
  for _, slot in ipairs(self.slots) do
    if (side == nil or slot.side == side) and not self:isDown(slot) then
      out[#out + 1] = slot
    end
  end
  return out
end

-- Has this trainer any mon left to send out?  A side is beaten when *both* of
-- its trainers are, which is what makes a 2-on-2 last longer than a 1v1 rather
-- than ending the moment one player is swept.
function M:hasReserve(slot)
  if slot.gone then return nil end
  for i, mon in ipairs(slot.party) do
    if i ~= slot.active and (mon.hp or 0) > 0 then return i end
  end
  return nil
end

function M:sideBeaten(side)
  for _, slot in ipairs(self.slots) do
    if slot.side == side then
      if not self:isDown(slot) then return false end
      if self:hasReserve(slot) then return false end
    end
  end
  return true
end

-- The slots an action from `slot` may legally aim at.
--
-- Both living opponents, and -- deliberately -- **not** the ally. Gen 1 has no
-- move that wants a partner as its target, so allowing one would be inventing
-- a rule rather than extending one; a player who wants to hit their friend can
-- do it the way the games have always allowed, by using a move that spreads.
-- There are none of those in Gen 1 either, which is the point.
function M:targetsFor(slot)
  local foe = slot.side == "a" and "b" or "a"
  return self:living(foe)
end

-- ------- the turn
--
-- One action per living slot, resolved in speed order over all four rather
-- than as two independent pairs. That single sentence is the whole reason this
-- file exists: `TurnOrder.firstMover` answers "does a go before b", and a
-- four-way field needs "in what order do these four go", which is a different
-- question and not one the engine is asked anywhere.

local function speedOf(self, slot)
  if self.turnOrder and self.turnOrder.effectiveSpeed then
    local ok, value = pcall(self.turnOrder.effectiveSpeed, slot.battler)
    if ok and type(value) == "number" then return value end
  end
  local stats = slot.battler and slot.battler.curStats
  return (stats and stats.speed) or 0
end

local function moveDef(self, moveInst)
  if not moveInst then return nil end
  local moves = self.data.moves or {}
  local def = moves[moveInst.id]
  if not def then return nil end
  -- the instance's own PP travels with the mon; everything else is the record
  local merged = { id = moveInst.id }
  for k, v in pairs(def) do merged[k] = v end
  return merged
end

-- Has this monster anything left to use?
--
-- Gen 1's rule is all-or-nothing: Struggle comes out when *every* move is
-- empty, not when the one you picked is. So this asks about the whole set.
function M:hasPP(battler)
  for _, moveInst in ipairs((battler and battler.curMoves) or {}) do
    if (moveInst.pp or 0) > 0 then return true end
  end
  return false
end

-- The move a monster with nothing left uses.
--
-- Built in the engine's own shape -- `{ id = "STRUGGLE", pp = 1, struggle =
-- true }`, exactly what BattleState:resolveTurn hands itself -- so the engine
-- recognises it: `struggle` is the flag that stops performMove decrementing PP
-- on a move that has none, and STRUGGLE is a real move record with real
-- recoil. Inventing a 50-power Normal move here instead would have looked
-- right and done no recoil at all.
local function struggleMove()
  return { id = "STRUGGLE", pp = 1, struggle = true }
end

-- The action's move, resolved.
--
-- An action carries a *slot in the mon's move list*, not a move -- which is
-- what it has to carry, because that is the only part of a move choice the
-- other three clients can be told without also being told what is in this
-- player's party. So the record is looked up here, against the battler that is
-- actually out, rather than being read off the action.
local function moveOf(self, action)
  local slot = self.slots[action and action.slot]
  local battler = slot and slot.battler
  local moves = battler and battler.curMoves
  return moveDef(self, moves and moves[action.move])
end

-- ------- the engine's own wording, without requiring its module
--
-- `src/core/Strings.lua` is the engine's catalog: the English source doubles as
-- the key, and a mod's `strings` registry supplies a translation which lands in
-- `data.strings`. One sentence below is authored by the *caller* of the recharge
-- gate rather than by the gate itself (in a 1v1 that caller is
-- `BattleState:executeAction`; here it is this file), so it has to be said from
-- here -- and this file deliberately requires no engine module at all, which is
-- what lets the suite drive a whole battle under plain luajit.
--
-- So the same lookup is done against the same table: catalog hit, else the
-- English source, formatted either way. Byte-identical to what a 1v1 prints, and
-- translatable through the very same registry entry.
local function says(self, source, ...)
  local catalog = self.data and self.data.strings
  local pattern = source
  if type(catalog) == "table" and type(catalog[source]) == "string" then
    pattern = catalog[source]
  end
  local ok, text = pcall(string.format, pattern, ...)
  if not ok then ok, text = pcall(string.format, source, ...) end
  return ok and text or source
end

-- pokered's <USER> text macro (home/text.asm PlaceMoveUsersName): a battler on
-- the enemy side is named "Enemy NIDORAN". `BattleState`'s own `displayName` is
-- a file-local there, so the rule is repeated here rather than reached for --
-- one line, and the alternative is an engine require this file does not make.
local function displayName(battler)
  return battler.isPlayer and battler.name or ("Enemy " .. tostring(battler.name))
end

local function priorityOf(move)
  if not move then return 0 end
  if move.priority then return move.priority end
  if move.id == "QUICK_ATTACK" then return 1 end
  if move.id == "COUNTER" then return -1 end
  return 0
end

-- Sort the turn.
--
-- Priority first, then speed, then -- and this is the part a pairwise
-- comparison cannot express -- a **stable tiebreak on slot index**. Two
-- battlers with identical speed have to be ordered the same way on all four
-- clients or the host and the replayers disagree about what happened, and a
-- coin flip per pair would give four different answers. The host's own RNG
-- would work too; the index is simply cheaper and cannot drift.
function M:order(actions)
  local queue = {}
  for _, action in ipairs(actions) do
    local slot = self.slots[action.slot]
    if slot and not self:isDown(slot) then
      queue[#queue + 1] = {
        action = action,
        slot = slot,
        speed = speedOf(self, slot),
        priority = priorityOf(moveOf(self, action)),
      }
    end
  end
  table.sort(queue, function(x, y)
    if x.priority ~= y.priority then return x.priority > y.priority end
    if x.speed ~= y.speed then return x.speed > y.speed end
    return x.slot.index < y.slot.index
  end)
  return queue
end

-- ------- action kinds
--
-- A turn is one action per living slot, and not all of them are moves. The
-- non-move ones resolve first and in slot order, which is Gen 1's own
-- ordering: switching and using an item happen before anybody attacks, and
-- neither is raced on speed.
-- `npcItem` is deliberately not in this set: it is never accepted off the
-- wire. A trainer's item use is decided by the host's own AI, so a client
-- claiming one would be a client acting for a monster it does not own.
M.KINDS = { move = true, switch = true, item = true, run = true }

-- The one action that is **not** a turn action, and so not in the set above.
--
-- A replacement is answered while the field is *stopped*: a monster has
-- fainted, its slot owes an answer, and nothing resolves until it arrives. It
-- travels down the same wire as a move -- there is only one -- so it is a
-- value a client can put in `kind`, which is exactly why it belongs in the
-- vocabulary rather than being a bare string in one caller and an implicit
-- default in another.
--
-- It is deliberately kept out of KINDS rather than added to it. KINDS is what
-- `resolveTurn` dispatches, and a "replace" that reached it would be handed to
-- `runOther`, which has no branch for it -- so the slot would silently do
-- nothing for the turn instead of falling back to a move. Naming it here says
-- what it is without changing what a turn can be.
--
-- The host does not route on it: a replacement is recognised by the field's
-- own `awaiting`, which is host state and cannot be claimed by a message. The
-- kind is what tells a *stale* one apart from a move -- see CoopBattle's `act`
-- handler.
M.REPLACE = "replace"

-- Resolve one whole turn and return the events it produced.
--
-- `actions` is one entry per living slot. A slot with no action -- an owner
-- who dropped, a mon that fainted before its turn came round -- is skipped
-- rather than defaulted to something, because a default here would be this
-- file choosing somebody's move for them.
-- Every slot's HP, right now.
--
-- The engine writes damage straight onto the monster. Nothing about
-- `performMove` announces a number -- in a 1v1 there is nobody to announce it
-- to -- so the only way to know what a turn did to four monsters is to look
-- before and look after.
local function hpNow(self)
  local out = {}
  for i, slot in ipairs(self.slots) do
    local mon = slot.battler and slot.battler.mon
    out[i] = mon and mon.hp or nil
  end
  return out
end

-- What the last step changed, as events the other three can apply.
--
-- **This is what makes a replay a replay.** The engine path -- the whole move
-- effect registry, reached through CoopField -- mutates HP in place and drains
-- only text and animations, so before this existed a client that was not the
-- host watched four HP bars that never moved for an attack. The bars were then
-- dragged back into line once a turn by the desync check, which is a repair
-- mechanism doing the job of the protocol: it papered over the fault well
-- enough that a two-client run still looked right, while every replayer spent
-- every turn a whole turn behind.
--
-- Absolute HP, never a delta, so applying the same event twice is harmless and
-- a lost one is corrected by the next.
local function announceHp(self, before, emit)
  for i, slot in ipairs(self.slots) do
    local mon = slot.battler and slot.battler.mon
    local now = mon and mon.hp
    if now and before[i] and now ~= before[i] then
      emit({ kind = "damage", slot = i, amount = before[i] - now, hp = now })
    end
  end
end

function M:resolveTurn(actions)
  local events = {}
  if self.over then return events end
  -- Paused, and the pause belongs here rather than only in whatever is asking.
  --
  -- A slot whose monster fell is empty until its owner says what follows, and
  -- resolving around an empty slot would spend three people's moves on a field
  -- that is about to change -- and hand the side that is one monster down a
  -- free turn. The host's own loop already declines to ask while a choice is
  -- outstanding; this makes the field say no as well, so a second caller (a
  -- stall timeout, a future one) cannot resolve a turn the battle is not
  -- ready for.
  if self:awaitingChoice() then return events end
  self.turn = self.turn + 1

  -- **Flinch discipline**, `BattleState:clearTurnFlinches` (BattleState.lua:1359)
  -- over four slots instead of two.
  --
  -- core.asm:297-300 clears both sides' FLINCHED bits as a turn's move selection
  -- opens, and core.asm:293-295 skips the clear for a monster that must recharge
  -- or is locked into Rage -- the Hyper Beam flinch glitch, where the flag
  -- survives to eat the recharge turn. Both halves are kept.
  --
  -- Here rather than inside the execution loop, and that placement is the whole
  -- point: the gate itself runs per-slot *inside* the loop, so a flinch a first
  -- mover inflicts still bites a later mover in the same turn, exactly as it does
  -- in the original. Clearing at the top and gating inline is what produces that
  -- ordering; clearing per-slot as each one acts would not.
  for _, slot in ipairs(self.slots) do
    local battler = slot.battler
    if battler and not (battler.mustRecharge or battler.rageMove) then
      battler.flinched = false
    end
  end

  local function emit(event) events[#events + 1] = event end

  -- Wrapped around every step rather than placed after the ones that were
  -- remembered: a move effect can take HP off any of the four (recoil, a
  -- drain, Leech Seed landing, a partner caught by a spread), and a list of
  -- "the steps that can change HP" is a list that goes stale.
  local function step(fn, ...)
    local before = hpNow(self)
    fn(...)
    announceHp(self, before, emit)
  end

  -- Switches and items first, in slot order.
  for _, action in ipairs(actions) do
    local slot = self.slots[action.slot]
    local kind = action.kind or "move"
    if slot and kind ~= "move" and not self:isDown(slot) then
      step(function() self:runOther(slot, action, emit) end)
    end
  end
  if self:checkOver(emit) then return events end

  for _, entry in ipairs(self:order(actions)) do
    local slot = entry.slot
    if (entry.action.kind or "move") == "move" and not self:isDown(slot) then
      step(function() self:runAction(slot, entry.action, emit) end)
      self:reapFaints(emit)
    end
    if self:checkOver(emit) then return events end
  end

  -- Residual damage -- burn, poison, Leech Seed -- after every action, in
  -- slot order.
  for _, slot in ipairs(self.slots) do
    if not self:isDown(slot) then
      step(function() self:runResidual(slot, emit) end)
    end
  end
  self:reapFaints(emit)
  self:checkOver(emit)
  return events
end

-- ------- the non-move actions

function M:runOther(slot, action, emit)
  local kind = action.kind
  if kind == "npcItem" then return self:runNpcItem(slot, action, emit)
  elseif kind == "switch" then return self:runSwitch(slot, action, emit)
  elseif kind == "item" then return self:runItem(slot, action, emit)
  elseif kind == "run" then return self:runFlee(slot, emit) end
end

-- Switching by choice.  Costs the turn, exactly as it does in the original.
function M:runSwitch(slot, action, emit)
  local index = action.index
  local mon = slot.party[index]
  if not (mon and (mon.hp or 0) > 0 and index ~= slot.active) then
    emit({ kind = "msg", text = "There's no one\nelse to send out!" })
    return
  end
  local leaving = slot.battler and slot.battler.name or "?"
  self:sendOut(slot, index)
  emit({ kind = "msg", text = slot.name .. " withdrew\n" .. leaving .. "!" })
  emit({ kind = "send", slot = slot.index, index = index,
         name = slot.battler.name, trainer = slot.name })
  emit({ kind = "msg", text = slot.name .. " sent out\n" .. slot.battler.name .. "!" })
end

-- **Running is refused, and that is the complete behaviour rather than a gap.**
--
-- A co-op battle is always a trainer battle -- an NPC trainer, or two of them
-- who are other players -- and Gen 1 does not let anybody run from one. So the
-- right implementation is the original's refusal, in the original's words,
-- taken from the game's own text table when it is there.
function M:runFlee(slot, emit)
  local text = (self.data.text and self.data.text._NoRunningText)
    or "No! There's no\nrunning from a\ntrainer battle!"
  emit({ kind = "msg", text = text })
end

-- ------- a party that left the field
--
-- **The other half of RUN, and it is not the same question as the refusal
-- above.** `runFlee` answers "may I leave a trainer battle": no, in the
-- original's words, and that stays the whole answer whenever the opposition
-- is an NPC trainer. This answers a question Gen 1 never had to ask -- "may we
-- leave a battle against two other *people*" -- and the answer there is yes,
-- with the partner's consent, because the alternative is two players held in a
-- fight neither can end while the other three read messages.
--
-- Not an action, and deliberately not reachable from `resolveTurn`. Running
-- costs the fleeing side the battle rather than costing it a turn, so it is
-- resolved the way a knockout is: the side is over, the other side won, and
-- the `over` event that says so is the same one `checkOver` emits -- which is
-- what makes every client's `resultFor` answer "loss" for the runners and
-- "win" for the people they left, through the machinery that was already
-- there. Nothing new reaches the result vocabulary, so nothing new reaches
-- the ranking.
--
-- Refused once the battle is already decided: a forfeit racing a knockout must
-- not overwrite a winner who has already been named.
function M:fled(side, emit)
  if self.over then return false end
  if side ~= "a" and side ~= "b" then return false end
  self.over = (side == "a") and "b" or "a"
  emit({ kind = "over", winner = self.over })
  return true
end

-- Items, through the engine's own ItemEffects.
--
-- Not reimplemented: a potion heals what the engine says a potion heals, an X
-- ATTACK moves the stage the engine moves, and an item that refuses mid-battle
-- refuses with the sentence the engine refuses in. `itemUse` is that function,
-- handed in at construction so this file still loads without it.
--
-- A ball is the other refusal that is really a rule: you cannot throw one at
-- somebody else's POKeMON, and every opponent in a co-op battle belongs to a
-- trainer.
function M:runItem(slot, action, emit)
  local itemId = action.item
  if not itemId then return end
  local bag = slot.bag
  if bag and (bag[itemId] or 0) <= 0 then
    emit({ kind = "msg", text = "There's none left!" })
    return
  end

  if not (self.itemUse and self.save) then
    emit({ kind = "msg", text = "That can't be used\nhere." })
    return
  end

  -- The mon it is used on: a slot's own active mon by default, or another of
  -- that trainer's party for a revive.
  local target = slot.party[action.index or slot.active]

  -- A ball is answered before ItemEffects is asked, and from the item record
  -- rather than from a list of known ball ids.
  --
  -- ItemEffects recognises a ball by name against the five vanilla ones, so a
  -- modded ball -- or the suite's FIX_BALL -- would fall past it and be run as
  -- an ordinary item. The item record's own `ball` field, and the `balls`
  -- registry beside it, are the moddable answer to "is this a ball", and they
  -- are what this asks.
  local itemDef = (self.data.items or {})[itemId]
  local isBall = (itemDef and itemDef.ball ~= nil)
    or ((self.data.balls or {})[itemId] ~= nil)
  if isBall then
    local text = (self.data.text and self.data.text._NoCatchTrainerText)
      or "The trainer\nblocked the BALL!"
    emit({ kind = "msg", text = text })
    return
  end

  local ok, status, messages = pcall(self.itemUse, self.data, self.save,
    itemId, target, self.fieldObj, action.move)
  if not ok then
    emit({ kind = "msg", text = "That can't be used\nhere." })
    return
  end
  if status == "ball" then
    local text = (self.data.text and self.data.text._NoCatchTrainerText)
      or "The trainer\nblocked the BALL!"
    emit({ kind = "msg", text = text })
    return
  end

  for _, line in ipairs(messages or {}) do
    emit({ kind = "msg", text = tostring(line) })
  end
  -- **The bag is not touched here, and that is the fix for a real bug.**
  --
  -- This runs on the *host*, which simulates every slot -- and the host holds
  -- no bag for anybody but itself, because an inventory never crosses the
  -- wire. So a potion used by another player healed correctly (the host
  -- applies it and the resulting HP rides back in the events) and was never
  -- paid for: an infinite supply for everyone except the host.
  --
  -- Spending an item is the owner's own bookkeeping, so the owner's client
  -- does it when it commits the action -- see CoopBattle:updateItem.
  -- The item may have healed or revived; the bar follows the mon -- but only
  -- when the mon it healed is the one standing in the slot. A `damage` event
  -- names a *slot*, and every client applies it to whatever that slot has on
  -- the field, so a revive used on a benched party member would have drained
  -- the active monster's bar to the fainted one's HP. Nothing reachable sends
  -- an index today (see `updateItem`), which is exactly the sort of gap a
  -- later caller walks into.
  if target and slot.party[slot.active] == target then
    emit({ kind = "damage", slot = slot.index, amount = 0, hp = target.hp or 0 })
  end
end

-- A trainer using one of its own items.
--
-- Through TrainerAI.useItem, which both applies the effect and returns the
-- lines the original prints -- a potion that healed silently would look like
-- the monster simply not taking damage.
function M:runNpcItem(slot, action, emit)
  local ai = self.trainerAI
  local field = self.fieldObj
  if not (ai and ai.useItem and field) then return end
  local prevEnemy, prevTrainer = field.enemy, field.trainer
  field.enemy, field.trainer = slot.battler, self.trainer
  local ok, messages = pcall(ai.useItem, field, action.item)
  field.enemy, field.trainer = prevEnemy, prevTrainer
  if not ok then return end
  for _, line in ipairs(messages or {}) do
    emit({ kind = "msg", text = tostring(line) })
  end
  local mon = slot.battler and slot.battler.mon
  if mon then
    emit({ kind = "damage", slot = slot.index, amount = 0, hp = mon.hp or 0 })
  end
end

-- ------- a move
--
-- **This is the engine's own performMove**, reached through the field adapter
-- (src/CoopField.lua) rather than reimplemented. Charge moves charge, Substitute
-- absorbs, Hyper Beam recharges, Metronome calls, multi-hit hits, recoil
-- recoils, stat stages move -- all of it, because none of it is written here.
--
-- The fallback underneath is the no-engine path, and it exists so this file
-- stays drivable under plain luajit with a stubbed damage function. It is
-- deliberately thin: it is a test harness, not a second battle system.
function M:runAction(slot, action, emit)
  local battler = slot.battler
  if not battler then return end

  local target = self.slots[action.target]
  -- The chosen target may have fainted earlier in the same turn -- ordinary in
  -- a four-way field and almost impossible in a 1v1. The move redirects to
  -- whoever is still standing rather than fizzling, because "your target fell
  -- over so you lose your turn" is a rule nobody agreed to when they picked it.
  --
  -- Resolved before the move rather than after it, because both gates below
  -- take a target: the confusion self-hit inside `statusInterrupt` reads its
  -- *screens* (Gen 1 checks the opponent's Reflect against a mon hitting
  -- itself -- the real glitch, kept), and `preRechargeChecks` wants a trapping
  -- counter -- which is a different battler again, and is worked out just below.
  if not target or self:isDown(target) or target.side == slot.side then
    target = self:targetsFor(slot)[1]
  end
  if not target then return end

  -- ------- held in place by Wrap, Bind, Fire Spin or Clamp
  --
  -- `Status.beforeMove` (Status.lua:185) refuses the turn on `battler.boundTurns`
  -- -- and that field is a **mirror**, not state. The engine refreshes it from
  -- the opponent's `trappingTurns` immediately before the gate every time an
  -- action runs (BattleState.lua:2736-2738), deliberately writing it nowhere
  -- else so the two peers of a link battle cannot disagree about a mirror.
  --
  -- Nothing here was doing that refresh, so the rung was unreachable: a monster
  -- caught in a Wrap moved every turn, and the four-slot field made it worse
  -- than a 1v1 would -- `runRecharge` handed `preRechargeChecks` the
  -- *redirected* target, whose `trappingTurns` might belong to the wrong
  -- battler entirely.
  --
  -- So the trapper is looked up the way a four-way field has to: over this
  -- slot's living opponents, rather than "the other one". The gates read it from
  -- there -- `beforeMove` through the mirror, `preRechargeChecks`
  -- (BattleState.lua:2875) straight off the battler it is handed.
  --
  -- **The trapper's own half is still not adopted, and that is named rather
  -- than hidden.** `BattleState:fightLockedAction` returns `{ special =
  -- "trapping" }` / `{ special = "bide" }` to lock the *attacker* into
  -- continuing its own move, and no action on this wire carries a special. A
  -- co-op Wrap therefore re-rolls its move each turn while its victim is held.
  -- This covers the victim's half of the pair.
  local trapper, trapped = nil, nil
  for _, candidate in ipairs(self:targetsFor(slot)) do
    local turns = candidate.battler and candidate.battler.trappingTurns
    if turns then trapper, trapped = candidate, turns break end
  end
  battler.boundTurns = trapped and math.max(1, trapped) or nil
  -- Whoever the gates should be reading a trapping counter off: the trapper
  -- when there is one, and otherwise the target the move is aimed at, which is
  -- what the 1v1 always hands them.
  local gateTarget = (trapper and trapper.battler) or target.battler

  -- **A recharge turn is not a move turn.** `BattleState:executeAction`
  -- (BattleState.lua:2775) routes a battler with `mustRecharge` through
  -- `preRechargeChecks` and never reaches `performMove` -- whatever move was
  -- picked is simply not used. The flag itself is set by the engine's own
  -- HYPER_BEAM_EFFECT running through this adapter (MoveEffects.lua:593), so it
  -- has been landing on co-op battlers all along with nothing reading it: Hyper
  -- Beam fired every turn, free. This is the read.
  if self.fieldObj and battler.mustRecharge then
    return self:runRecharge(slot, target, emit, gateTarget)
  end

  local moveInst = battler.curMoves and battler.curMoves[action.move]
  -- Out of everything: Struggle, whatever was chosen. Checked here rather than
  -- at the menu because a turn is resolved on the host, and the host is the
  -- only client that knows what every monster has left.
  if not self:hasPP(battler) then
    moveInst = struggleMove()
  elseif not moveInst or (moveInst.pp or 0) <= 0 then
    -- The one they picked is empty but others are not. The menu should not
    -- have offered it; falling through to the first move that *can* be used is
    -- better than losing the turn to a mis-selection.
    for _, candidate in ipairs(battler.curMoves or {}) do
      if (candidate.pp or 0) > 0 then moveInst = candidate break end
    end
  end
  if not moveInst then return end

  if self.fieldObj then
    local field = self.fieldObj

    -- **The status gate**, and it is the engine's own.
    --
    -- `BattleState:statusInterrupt` (BattleState.lua:2892) is the wrapper a 1v1
    -- runs immediately before `performMove`: it calls `Status.beforeMove` for the
    -- sleep -> freeze -> held -> flinch -> disable -> confusion -> paralysis
    -- gauntlet, routes every line through `sayStatusMsg` (so the "Enemy " prefix
    -- and the SLP_/CONF_ onomatopoeia animations are the original's), computes
    -- the 40-power typeless confusion self-hit against the *opponent's* screens,
    -- and clears the volatiles full paralysis clears -- sparing `invulnerable`,
    -- which is the Fly/Dig glitch.
    --
    -- `performMove` does none of that, so the co-op path had no gating at all: a
    -- sleeping monster attacked, a paralysed one never full-stopped, a flinch
    -- meant nothing. Calling the wrapper rather than reimplementing it is the
    -- same bargain the rest of this file makes -- and it costs nothing, because
    -- everything it queues drains through the adapter into ordinary events.
    --
    -- The roll is `field.rng`, which is the sim's own closure (CoopBattle hands
    -- one `rng` to both), so the host's paralysis coin is the host's.
    field.queue, field.nextInsert, field.fainted = {}, 0, {}
    local okGate, interrupted =
      pcall(field.statusInterrupt, field, battler, target.battler)
    if not okGate then
      -- A gate that throws lets the turn through rather than eating it. The
      -- likely cause is a dataset with no `statuses` records, and a battle where
      -- nobody can ever move is worse than one where a status is not enforced.
      if self.onError then self.onError(interrupted) end
      interrupted = false
    end
    self:drainInto(field, slot.index, target.index, emit)
    if interrupted then return end

    -- Whether the seed was already on the target before this action, so that
    -- "an action landed Leech Seed" can be told from "the target was seeded
    -- three turns ago" -- see runResidual for what the pointer is for.
    local seededBefore = target.battler and target.battler.leechSeeded

    field.queue, field.nextInsert, field.fainted = {}, 0, {}
    local ok, err = pcall(field.performMove, field, battler, target.battler,
                          moveInst, false)
    if not ok then
      -- One bad move record must not end four people's battle.
      emit({ kind = "msg", text = (battler.name or "?") .. "'s\nattack failed!" })
      if self.onError then self.onError(err) end
      return
    end
    self:drainInto(field, slot.index, target.index, emit)

    -- `battler.leechSeeded` is a bare boolean (MoveEffects.lua:182): the engine
    -- never needed to remember who seeded, because in a 1v1 the drain goes to
    -- the one monster on the other side. With four slots it does need to be
    -- remembered, and the only moment it can be is now.
    if target.battler and target.battler.leechSeeded and not seededBefore then
      target.seededBy = slot.index
    end
    return
  end

  return self:runActionSimple(slot, target, moveInst, action, emit)
end

-- Everything the field queued, as stamped events, plus the faints it booked.
--
-- Factored out because three call sites need it -- the status gate, a recharge
-- turn and the move itself -- and all three have to stamp identically.
--
-- Every event gets stamped with who acted and who they aimed at. The engine's
-- queue rows do not carry that -- in a 1v1 there is nothing to say -- and it is
-- exactly what the screen needs to put an animation over the right monster out
-- of four.
--
-- Except on a drain row, where `to` is not a slot at all: it is the HP the bar
-- stops at, and the slot it belongs to already rode along as `slot`. Stamping
-- that one would overwrite a health point with a slot index and send every
-- watching client's bar to "4 HP" -- so the drain keeps its own.
function M:drainInto(field, from, to, emit)
  for _, event in ipairs(self.drain(field)) do
    if event.from == nil then event.from = from end
    if event.to == nil and event.kind ~= "drain" then event.to = to end
    emit(event)
  end
  -- Anything the gate or the move knocked down -- the confusion self-hit can
  -- faint its own user -- is booked here and sent out after the action, never
  -- during it.
  for _, downed in ipairs(field.fainted) do
    self.pendingFaints[#self.pendingFaints + 1] = downed
  end
  field.fainted = {}
end

-- A turn spent recharging, the engine's way.
--
-- `preRechargeChecks` (BattleState.lua:2855) is deliberately narrower than the
-- full gate: sleep, freeze, held-in-place and flinch each lose the turn *without*
-- consuming the recharge flag (core.asm:3328-3382), and the disable, confusion
-- and paralysis ticks come after the flag is consumed in the original, so they
-- must not run at all on a recharge turn. Only reaching the announcement clears
-- the flag -- a monster put to sleep while recharging is still recharging when it
-- wakes, which is the original's behaviour and not an oversight.
--
-- `gateTarget` is the battler the gate reads a trapping counter off, worked out
-- by `runAction` over the living opponents (see the held-in-place note there).
-- It is *not* always the monster the move was aimed at: a redirected target's
-- `trappingTurns` says nothing about who is holding this monster. Absent, the
-- resolved target's battler stands in, which is what a 1v1 hands it.
function M:runRecharge(slot, target, emit, gateTarget)
  local field = self.fieldObj
  local battler = slot.battler
  field.queue, field.nextInsert, field.fainted = {}, 0, {}
  local ok, blocked = pcall(field.preRechargeChecks, field, battler,
                            gateTarget or target.battler)
  if not ok then
    -- The flag is dropped rather than left standing: a slot that could never
    -- clear it would never act again.
    battler.mustRecharge = nil
    if self.onError then self.onError(blocked) end
    return
  end
  if not blocked then
    battler.mustRecharge = nil
    field:sayNext(says(self, "%s\nmust recharge!", displayName(battler)))
  end
  self:drainInto(field, slot.index, target.index, emit)
end

-- The no-engine path. See runAction's header for why it is thin.
function M:runActionSimple(slot, target, moveInst, action, emit)
  local battler = slot.battler
  local move = moveDef(self, moveInst)
  if not move then return end

  if self.status and self.status.beforeMove then
    local ok, canMove, msgs, selfHit =
      pcall(self.status.beforeMove, battler, self.rng, self)
    if ok then
      for _, text in ipairs(msgs or {}) do emit({ kind = "msg", text = text }) end
      if selfHit then return self:hurtSelf(slot, emit) end
      if not canMove then return end
    end
  end

  -- Struggle rather than a lost turn, the same rule the engine path takes.
  if (moveInst.pp or 0) <= 0 then
    if self:hasPP(battler) then return end
    moveInst = struggleMove()
    move = moveDef(self, moveInst) or move
  else
    moveInst.pp = moveInst.pp - 1
  end
  emit({ kind = "msg",
         text = battler.name .. " used\n" .. (move.name or move.id) .. "!" })

  if not self:lands(battler, target.battler, move) then
    emit({ kind = "msg", text = battler.name .. "'s\nattack missed!" })
    return
  end
  if (move.power or 0) > 0 and move.category ~= "status" then
    self:dealDamage(slot, target, move, emit)
  end
end

function M:lands(attacker, defender, move)
  if not (self.damage and self.damage.accuracyRoll) then return true end
  if (move.accuracy or 100) >= 100 and not self.ruleset.oneIn256Miss then
    return true
  end
  local ok, hit = pcall(self.damage.accuracyRoll, self.ruleset, move,
                        attacker, defender, self.rng)
  if not ok then return true end
  return hit and true or false
end

function M:dealDamage(slot, target, move, emit)
  local amount, info = 0, {}
  if self.damage and self.damage.compute then
    local ok, value, meta = pcall(self.damage.compute, self.ruleset,
      slot.battler, target.battler, move, { rng = self.rng })
    if ok then amount, info = value or 0, meta or {} end
  end
  if info.missed then
    emit({ kind = "msg", text = slot.battler.name .. "'s\nattack missed!" })
    return
  end
  self:applyDamage(target, amount, emit)
  if info.crit then emit({ kind = "msg", text = "Critical hit!" }) end
  self:checkFaint(target, emit)
end

function M:hurtSelf(slot, emit)
  local amount = 0
  if self.damage and self.damage.compute then
    local ok, value = pcall(self.damage.compute, self.ruleset,
      slot.battler, slot.battler,
      { id = "CONFUSED", power = 40, type = "NORMAL", category = "physical" },
      { rng = self.rng, typeless = true })
    if ok then amount = value or 0 end
  end
  self:applyDamage(slot, amount, emit)
  self:checkFaint(slot, emit)
end

function M:applyDamage(slot, amount, emit)
  local mon = slot.battler.mon
  amount = math.max(0, math.floor(amount or 0))
  mon.hp = math.max(0, (mon.hp or 0) - amount)
  emit({ kind = "damage", slot = slot.index, amount = amount, hp = mon.hp })
end

-- ------- faints
--
-- Collected during a move and acted on after it, because the engine's effect
-- pipeline may faint more than one battler in a single action (Explosion,
-- recoil, a multi-hit finishing two things) and a send-out in the middle of
-- that would put a fresh mon in front of a move still resolving.
function M:reapFaints(emit)
  local pending = self.pendingFaints
  self.pendingFaints = {}
  for _, slot in ipairs(pending) do
    self:announceFaint(slot, emit)
  end
  -- Anything the simple path or a residual knocked down without going through
  -- the field is caught here too.
  for _, slot in ipairs(self.slots) do
    if self:isDown(slot) and not slot.announced then
      self:announceFaint(slot, emit)
    end
  end
end

-- Exp for a beaten monster, shared by the side that beat it.
--
-- Gen 1 divides a defeat between everyone who *took part*; here that is read
-- as both trainers on the winning side, because in a 2-on-2 both of them were
-- in the fight whether or not they landed the last hit. The engine's own
-- Experience.apply does the arithmetic and the level-ups, so a co-op battle
-- pays exactly what the same trainer pays in a single one -- split two ways.
--
-- Only a real player's mon gains: an NPC's party is thrown away when the
-- battle ends, and levelling it would be bookkeeping nobody ever reads.
function M:awardExp(beaten, emit)
  if not (self.experience and self.experience.apply) then return end
  local def = beaten.battler and beaten.battler.def
  local level = beaten.battler and beaten.battler.mon and beaten.battler.mon.level
  if not (def and def.baseExp and level) then return end

  -- Everyone still standing on the other side, and only real players: an
  -- NPC's party is discarded when the battle ends, so paying it is bookkeeping
  -- nobody reads.
  local winners = {}
  for _, slot in ipairs(self.slots) do
    if slot.side ~= beaten.side and slot.owner and not self:isDown(slot) then
      winners[#winners + 1] = slot
    end
  end
  if #winners == 0 then return end

  for _, slot in ipairs(winners) do
    local mon = slot.battler and slot.battler.mon
    if mon then
      -- **Announced, not applied here.**
      --
      -- This runs on the host, which holds the *real* party only for its own
      -- slot -- everyone else's is an unpacked copy that is thrown away when
      -- the battle ends. Applying exp here paid the host and nobody else,
      -- while still printing "gained 136 EXP. Points!" on all four screens.
      --
      -- The same trap took items (spent on a bag the host does not have) and
      -- move learning (written to a copy). The answer is the same one, and it
      -- belongs here most of all: the host computes the share, the event
      -- carries it, and each client applies it to the party its own save
      -- keeps. The host's own slot stops being a special case.
      --
      -- The *share* is still the host's to compute, because only the host
      -- knows how many winners there were -- which is what Gen 1 divides by.
      local share = self:expShare(def, level, #winners)
      if share > 0 then
        emit({ kind = "exp", slot = slot.index, amount = share,
               species = beaten.battler.mon.species, level = level,
               winners = #winners })
      end
    end
  end
end

-- What one winner is owed, without touching anybody's monster.
--
-- Experience.gainFor is the engine's own arithmetic -- base exp divided by the
-- participants, scaled by the beaten monster's level, then the trainer bonus.
-- Asking it rather than repeating it keeps a co-op payout identical to a solo
-- one, split.
function M:expShare(def, level, participants)
  local gainFor = self.experience and self.experience.gainFor
  if not gainFor then return 0 end
  local ok, amount = pcall(gainFor, def, level, true, participants, false,
                           self.data.constants)
  if not ok then return 0 end
  return math.max(0, math.floor(tonumber(amount) or 0))
end

-- What this monster learns at the level it just reached.
--
-- **Announced rather than applied.** The host resolves every slot, but a move
-- written onto the host's *copy* of somebody else's monster is thrown away
-- with the copy -- the same trap that made items free for everybody but the
-- host. So the level-up says which move was learned and each client applies it
-- to its own live party, which is the only place it can persist.
function M:offerMoves(slot, level, emit)
  if not (self.movesAt and self.data.pokemon) then return end
  local mon = slot.battler and slot.battler.mon
  local def = mon and self.data.pokemon[mon.species]
  if not def then return end
  local ok, moves = pcall(self.movesAt, def, level)
  if not (ok and moves) then return end
  for _, moveId in ipairs(moves) do
    emit({ kind = "learn", slot = slot.index, move = moveId })
  end
end

function M:announceFaint(slot, emit)
  if slot.announced or not self:isDown(slot) then return false end
  slot.announced = true
  -- The faint before its own message, which is the order the original prints
  -- it in: the sprite sinks off the bottom of the box and *then* the text
  -- appears. Emitted the other way round, a client that pauses on the message
  -- leaves the beaten monster standing there while it is being told the
  -- monster has fallen.
  emit({ kind = "faint", slot = slot.index })
  emit({ kind = "msg", text = (slot.battler and slot.battler.name or "?")
         .. "\nfainted!" })
  -- Awarded before the replacement is sent out, so the mon that was actually
  -- standing there when it fell is the one that gets paid.
  self:awardExp(slot, emit)
  local next = self:hasReserve(slot)
  if not next then return true end

  -- Whose choice this is.
  --
  -- An NPC sends out whatever comes next -- there is nobody to ask. A player
  -- is *asked*, because which monster follows a faint is one of the few real
  -- decisions a Gen 1 battle offers, and taking it away is the difference
  -- between playing a battle and watching one.
  --
  -- The slot is left empty in the meantime. It cannot act while it is, the
  -- side is not beaten while it holds a reserve, and the host will not resolve
  -- another turn until it is filled -- so an unanswered choice pauses the
  -- battle rather than quietly deciding it.
  if slot.owner then
    slot.awaiting = true
    emit({ kind = "choose", slot = slot.index, trainer = slot.name })
    return true
  end

  self:sendOut(slot, next)
  slot.announced = false
  emit({ kind = "send", slot = slot.index, index = next,
         name = slot.battler.name, trainer = slot.name })
  emit({ kind = "msg",
         text = slot.name .. " sent out\n" .. slot.battler.name .. "!" })
  return true
end

-- Is anybody still choosing?  The host will not resolve a turn while one is.
function M:awaitingChoice()
  for _, slot in ipairs(self.slots) do
    if slot.awaiting and not slot.gone then return slot end
  end
  return nil
end

-- The answer: send this one out.
--
-- Refused unless the slot is actually waiting and the pick is a living reserve
-- -- it arrives off the wire, so it is somebody else's word about which of
-- their monsters is next.
function M:replace(slotIndex, index, emit)
  local slot = self.slots[slotIndex]
  if not (slot and slot.awaiting) then return false end
  local mon = slot.party[index]
  if not (mon and (mon.hp or 0) > 0) then
    index = self:hasReserve(slot)
    if not index then return false end
  end
  slot.awaiting = nil
  self:sendOut(slot, index)
  slot.announced = false
  if emit then
    emit({ kind = "send", slot = slot.index, index = index,
           name = slot.battler.name, trainer = slot.name })
    emit({ kind = "msg",
           text = slot.name .. " sent out\n" .. slot.battler.name .. "!" })
  end
  return true
end

function M:checkFaint(slot, emit)
  if not self:isDown(slot) then return false end
  return self:announceFaint(slot, emit)
end

-- Where a seeded slot's Leech Seed drains to.
--
-- The slot that seeded it, resolved to whatever monster that trainer has out
-- *now* -- which is the original's rule read honestly. Gen 1 drains into "the
-- other side's active monster" and never has to say more, because there is only
-- one; so a seeder who fainted and sent out a replacement keeps receiving, and
-- that is what following the slot rather than the battler gives.
--
-- Nil when the seeder is down or gone. That case does not exist in a 1v1 (the
-- battle would be over) and it does here, so it is answered below.
function M:seederFor(slot)
  local seeder = slot.seededBy and self.slots[slot.seededBy]
  if not seeder or self:isDown(seeder) then return nil end
  return seeder
end

-- Poison, burn and Leech Seed, at the end of the turn.
--
-- **`Status.residual` needs the opponent, and it was being handed nil.** The
-- function (Status.lua:219) subtracts the poison or burn tick from `mon.hp`
-- first and only *then* indexes `opponent.mon.hp` for a seeded battler -- so for
-- any seeded monster it threw, halfway through, with the HP already moved. The
-- pcall around it swallowed the throw, and with it both the message and the
-- `damage` event for damage that had really been dealt: a silent desync every
-- watching client inherited, and a Leech Seed that never drained anything.
--
-- Two changes, and the order matters:
--
--   * the seeder is passed, so the drain has somewhere to go;
--   * when there is no seeder left to drain into, the seed is *lifted for the
--     length of the call* rather than the call being risked. That keeps the
--     poison and burn halves running exactly as they always should have, and it
--     is the only structure in which a broken seed cannot cost them their
--     message. The seed itself stays on the monster.
--
-- The HP that moved is emitted either way, including when the call still fails
-- for some reason nobody has thought of -- an absolute number, so a client that
-- gets it twice is unharmed and one that misses it is corrected by the next.
function M:runResidual(slot, emit)
  if not (self.status and self.status.residual) then return end
  local battler = slot.battler
  if not (battler and battler.mon) then return end
  local before = battler.mon.hp or 0

  local seeder = self:seederFor(slot)
  local opponent = seeder and seeder.battler or nil
  -- Seeded, with nobody to feed. A documented divergence rather than a rule
  -- borrowed from somewhere: the original cannot reach this state, so there is
  -- no original behaviour to be faithful to. The seed holds and drains nothing
  -- this turn, which is the reading that neither invents a victim nor quietly
  -- cures a monster of a status it still has.
  local lifted = battler.leechSeeded and not opponent
  if lifted then battler.leechSeeded = nil end

  local ok, msgs = pcall(self.status.residual, battler, opponent,
                         self.fieldObj or self)
  if lifted then battler.leechSeeded = true end

  if ok then
    for _, text in ipairs(msgs or {}) do emit({ kind = "msg", text = text }) end
  elseif self.onError then
    self.onError(msgs)
  end

  local after = battler.mon.hp or 0
  if after ~= before then
    emit({ kind = "damage", slot = slot.index,
           amount = before - after, hp = after })
  end
  -- The seeder was healed by the drain; `resolveTurn`'s HP wrapper around this
  -- call reports that slot's change as its own event, so nothing is emitted for
  -- it here -- one absolute HP per slot per step, from one place.
end

function M:checkOver(emit)
  if self.over then return true end
  local aDown, bDown = self:sideBeaten("a"), self:sideBeaten("b")
  if not (aDown or bDown) then return false end
  -- Both sides falling in the same turn is a draw, and it is reachable here in
  -- a way it is not in a 1v1: a residual tick can take the last mon on each
  -- side at once. Called a draw rather than resolved by slot order, because
  -- "whoever the loop happened to reach first" is not a winner.
  self.over = (aDown and bDown) and "draw" or (aDown and "b" or "a")
  emit({ kind = "over", winner = self.over })
  return true
end

-- ------- an NPC's choice
--
-- Deliberately simple, and deliberately here rather than in the renderer: it
-- has to produce the same action on every client that asks, and the host is
-- the only one that does.
--
-- It picks the strongest move it has that is not out of PP, and aims at the
-- living opponent with the least HP left. That is a step above the vanilla
-- trainer AI's random pick and well below anything clever -- enough that two
-- players ganging up on one NPC pair is a fight rather than a formality.
function M:npcAction(slot)
  local battler = slot.battler
  if not battler then return nil end

  -- The target is mine to choose; the move is not.
  --
  -- Gen 1 has no notion of picking between two opponents, so nothing in the
  -- engine can answer "which of these two". Everything *else* about an enemy's
  -- turn it already answers better than a heuristic can, so the split is:
  -- this file decides who to hit, TrainerAI decides what with.
  local target, lowest = nil, nil
  for _, candidate in ipairs(self:targetsFor(slot)) do
    local hp = candidate.battler.mon.hp or 0
    if lowest == nil or hp < lowest then target, lowest = candidate, hp end
  end
  if not target then return nil end

  -- A class action first, exactly as the engine orders it: a trainer who is
  -- going to use a potion or swap a monster does that *instead* of attacking.
  local special = self:npcClassAction(slot)
  if special then return special end

  local pick = self:npcMove(slot, target)
  if not pick then return nil end
  return { slot = slot.index, move = pick, target = target.index }
end

-- The action a slot files when nobody filed one for it.
--
-- Not an AI and deliberately not `npcAction`: this is what a *player's* slot
-- does when their turn deadline runs out, and the honest answer there is the
-- dullest legal one -- the first move that still has PP, at the first opponent
-- still standing. A clever pick would be this file playing somebody's turn
-- better than they would have; a lost turn would be worse than either.
--
-- Nil only for a slot that cannot act at all: down, gone, or with no living
-- opponent left to aim at (in which case the battle is over anyway). A monster
-- with nothing left in any move still gets an action -- `runAction` substitutes
-- Struggle for it, exactly as it does for a chosen move.
function M:defaultAction(slotIndex)
  local slot = self.slots[slotIndex]
  if not (slot and slot.battler) or self:isDown(slot) then return nil end
  local target = self:targetsFor(slot)[1]
  if not target then return nil end

  local move = 1
  for i, moveInst in ipairs(slot.battler.curMoves or {}) do
    if (moveInst.pp or 0) > 0 then move = i break end
  end
  return { slot = slot.index, kind = "move", move = move, target = target.index }
end

-- Which move, through the engine's own AI where it is available.
--
-- TrainerAI.chooseMove is the real thing: the Gen 1 layers that discourage a
-- move the defender resists, encourage a status move on a healthy target, and
-- fall through to Struggle when every slot is spent. It returns a move
-- *instance*, and an action carries a slot index, so the answer is matched
-- back to the list it came from -- the index is the only part another client
-- can be told without also being told this monster's moveset.
function M:npcMove(slot, target)
  local battler = slot.battler
  local ai = self.trainerAI
  if ai and ai.chooseMove and self.fieldObj then
    -- The AI reads the defender off the battle, and in a four-way field the
    -- defender is whichever of the two this NPC has just decided to hit.
    local field = self.fieldObj
    local prevEnemy, prevPlayer = field.enemy, field.player
    field.enemy, field.player = battler, target.battler
    local ok, chosen = pcall(ai.chooseMove, battler, self.rng, field)
    field.enemy, field.player = prevEnemy, prevPlayer
    if ok and chosen then
      for i, moveInst in ipairs(battler.curMoves or {}) do
        if moveInst == chosen or moveInst.id == chosen.id then return i end
      end
      -- Struggle: not in the list, and runAction substitutes it anyway once it
      -- sees the monster has nothing left.
      if chosen.struggle then return 1 end
    end
  end

  -- No engine to ask: the strongest thing that still has PP.
  local best, bestPower = nil, -1
  for i, moveInst in ipairs(battler.curMoves or {}) do
    if (moveInst.pp or 0) > 0 then
      local def = moveDef(self, moveInst)
      local power = (def and def.power) or 0
      if power > bestPower then best, bestPower = i, power end
    end
  end
  return best
end

-- A trainer using an item, or swapping a monster.
--
-- This is the half of a Gen 1 trainer that a strongest-move heuristic misses
-- entirely: a gym leader who potions at low health, a class that switches out
-- of a bad matchup. TrainerAI decides both, and it reads them off the battle --
-- so the field is pointed at this NPC for the length of the call and put back
-- afterwards.
--
-- `kind` is borrowed too. It is "link" the rest of the time, deliberately, so
-- that PP is decremented for every side; classAction refuses to run on
-- anything but a trainer battle, and this *is* one from the NPC's point of
-- view. Restored immediately, because performMove reads the same field.
function M:npcClassAction(slot)
  local ai = self.trainerAI
  local field = self.fieldObj
  if not (ai and ai.classAction and field and self.trainer) then return nil end
  if (self.aiUses or 0) <= 0 then return nil end

  local prevEnemy, prevTrainer, prevKind, prevUses =
    field.enemy, field.trainer, field.kind, field.aiUses
  field.enemy, field.trainer = slot.battler, self.trainer
  field.kind, field.aiUses = "trainer", self.aiUses
  local ok, action = pcall(ai.classAction, field)
  field.enemy, field.trainer = prevEnemy, prevTrainer
  field.kind, field.aiUses = prevKind, prevUses
  if not (ok and type(action) == "table") then return nil end

  -- One class action per monster, the way wAICount is spent.
  self.aiUses = math.max(0, (self.aiUses or 0) - 1)

  if action.special == "aiSwitch" then
    local next = self:hasReserve(slot)
    if next then return { slot = slot.index, kind = "switch", index = next } end
    return nil
  end
  if action.special == "aiItem" and action.item then
    return { slot = slot.index, kind = "npcItem", item = action.item }
  end
  return nil
end

M.SIDE_MAX = Config.COOP_SIDE

return M
