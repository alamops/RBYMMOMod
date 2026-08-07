-- The 2-on-2 battle screen: four monsters on one field.
--
-- `CoopSim` is the rules; this is the screen. It is a plain state object of the
-- shape `src/core/StateStack.lua` expects -- enter, exit, update, draw,
-- isOpaque -- pushed through the mod's own `screens` registry, which is why
-- the mod can own a whole battle without touching `game.stack` directly.
--
-- ------- why host-authoritative, and not four-way lockstep
--
-- The engine's `LinkBattle` is lockstep: two peers run the same simulation off
-- one shared seed and exchange only choices. That works at two because both
-- ends draw from the same RNG stream in the same order, and the tie-break is
-- inverted on one side so the two agree.
--
-- At four it stops being cheap. Every client would have to consume the same
-- draws in the same order across four action resolutions, four faints and four
-- send-outs, and any one of them lagging a message would desync the field
-- rather than one battler. So one client simulates and the other three replay
-- the **events** it produces. The cost is honest -- the host decides, and a
-- modified host could decide wrongly -- and it is the same trust the engine's
-- own host-authoritative branch already takes for `action`/`event` in a link
-- battle, one player wider.
--
-- The upshot for this file: `self.host` runs `CoopSim` and broadcasts; everyone
-- else applies what arrives. **Both paths draw from the same event list**, so
-- the battle a replayer sees is the battle the host ran, not an approximation
-- of it.
--
-- ------- what this covers
--
-- All four battle commands, and the whole move-effect surface.
--
-- FIGHT resolves through `src/CoopField.lua`, which is a BattleState-shaped
-- object over the four slots -- so the move that runs is the engine's own
-- `performMove` and every `move_effects` record behind it. Charge moves charge,
-- Substitute absorbs, Hyper Beam recharges, Metronome calls, multi-hit hits,
-- recoil recoils, stat stages move. None of that is reimplemented here; see
-- CoopField's header for why it did not have to be.
--
-- ITEM goes through the engine's own `ItemEffects.use`, so a potion heals what
-- a potion heals and an item that refuses mid-battle refuses in the engine's
-- words. SWITCH costs the turn, as it does in the original.
--
-- A thrown ball is **refused**, and that is the complete behaviour rather than
-- a missing one: every monster on the far side belongs to a trainer, and Gen 1
-- does not let you catch somebody else's. It is refused in the original's own
-- words, taken from the game's text table.
--
-- RUN is two questions wearing one label, and they are answered separately.
-- Against an **NPC trainer** it is the original's question and keeps the
-- original's refusal, word for word. Against **two other players** it is a
-- question Gen 1 never had to ask -- and the answer is yes, with the consent of
-- the partner who shares the loss. See "RUN, in a battle where the other side
-- is people" below for the whole of it.

local need, mod = ...
local Config = need("Config")
local Wire = need("Wire")
local CoopSim = need("CoopSim")
local CoopField = need("CoopField")

local M = {}
M.__index = M

-- ------- the engine, loaded once and never at file scope
--
-- Lazily, and behind pcall, for the reason src/Sessions.lua loads the link
-- stack lazily: a player who never fights a co-op battle should not drag the
-- battle renderer in, and `modkit validate` -- which loads this file headlessly
-- with no love and no data -- must not meet a require that throws.
local engine, engineTried

local function loadEngine()
  if engineTried then return engine end
  engineTried = true
  local parts, ok = {}, true
  local function grab(key, path)
    local good, value = pcall(require, path)
    if good then parts[key] = value else ok = false end
    return good
  end
  grab("BattleState", "src.battle.BattleState")
  grab("Damage", "src.battle.Damage")
  grab("TurnOrder", "src.battle.TurnOrder")
  grab("Status", "src.battle.Status")
  grab("TypeChart", "src.battle.TypeChart")
  grab("Font", "src.render.Font")
  grab("HudTiles", "src.render.HudTiles")
  grab("Protocol", "src.link.Protocol")
  -- The real trainer AI: the Gen 1 move layers, and the per-class item and
  -- switch behaviour a strongest-move heuristic has no idea about.
  grab("TrainerAI", "src.battle.TrainerAI")
  -- The theatre: the battle theme, the victory theme, and the map music to go
  -- back to afterwards.
  grab("Music", "src.core.Music")
  -- The move-effect pipeline and the item table. These are what turn a co-op
  -- battle from a damage calculator into a battle, so a failure to load them
  -- is worth the same error as a missing renderer.
  grab("EffectRegistry", "src.battle.EffectRegistry")
  grab("ItemEffects", "src.inventory.ItemEffects")
  grab("Experience", "src.battle.Experience")
  grab("Pokemon", "src.pokemon.Pokemon")
  grab("Stats", "src.pokemon.Stats")
  -- Optional: a build with no battle_anims still fights, it just does not
  -- flash. Grabbed like the rest so a missing one is one warning, not a crash
  -- in the middle of somebody's turn.
  grab("AnimPlayer", "src.battle.AnimPlayer")
  if not ok then
    mod.log:error("the engine's battle modules are unavailable, so 2-on-2 "
      .. "battles cannot be drawn; everything else about co-op still works -- "
      .. "report this with the game version")
    engine = false
    return engine
  end
  engine = parts
  return engine
end

M.loadEngine = loadEngine


-- ------- packing a party for the wire
--
-- Through the engine's own pack/unpack, and -- this is the part that matters --
-- **both** sides go through it, exactly as LinkBattle does. A mon that has been
-- packed and rebuilt has had its stats recomputed from real species data, so
-- every client is looking at the same numbers; using the live save on the local
-- side and a rebuilt copy on the remote one would give the host slightly
-- different stats from everyone else's replay.
function M.packParty(party)
  local eng = loadEngine()
  if not (eng and eng.Protocol) then return nil end
  local ok, packed = pcall(eng.Protocol.packParty, party)
  return ok and packed or nil
end

function M.unpackParty(game, packed)
  local eng = loadEngine()
  if not (eng and eng.Protocol) then return nil end
  local out = {}
  for _, entry in ipairs(packed or {}) do
    local ok, mon = pcall(eng.Protocol.unpackMon, game.data, entry, {})
    if not (ok and mon) then return nil end
    out[#out + 1] = mon
  end
  if #out == 0 then return nil end
  return out
end

-- An NPC trainer's party, built the way the engine builds one.
--
-- `data.trainers[class].parties[index]` is a list of *specs* -- species and
-- level, sometimes moves -- not monsters. BattleState.newTrainer turns them
-- into real mons with the fixed trainer DVs and recomputed stats, and this
-- does the same thing for the same reason: a spec handed to the field would
-- have no stats to fight with.
--
-- Fixed DVs and the same stat recompute, so a co-op battle against a trainer
-- meets exactly the monsters a solo battle against them would.
function M.trainerParty(game, oppClass, partyIndex)
  local eng = loadEngine()
  if not (eng and eng.Pokemon and eng.Stats) then return nil end
  local record = (game.data.trainers or {})[oppClass]
  local specs = record and record.parties and record.parties[partyIndex or 1]
  if not (specs and #specs > 0) then return nil end

  local dvs = (game.data.constants and game.data.constants.trainerDvs)
    or { attack = 9, defense = 8, speed = 8, special = 8 }

  local out = {}
  for _, spec in ipairs(specs) do
    local ok, mon = pcall(eng.Pokemon.new, game.data, spec.species, spec.level)
    if not (ok and mon) then return nil end
    mon.dvs = dvs
    local statsOk, stats = pcall(eng.Stats.calc,
      game.data.pokemon[spec.species], spec.level, dvs)
    if statsOk and stats then
      mon.stats = stats
      mon.hp = stats.hp
    end
    if spec.moves then
      mon.moves = {}
      for _, moveId in ipairs(spec.moves) do
        local def = game.data.moves[moveId]
        mon.moves[#mon.moves + 1] = { id = moveId, pp = def and def.pp or 0 }
      end
    end
    out[#out + 1] = mon
  end
  return out
end

-- ------- construction
--
-- opts:
--   slots   four { side, owner, name, party } in a1,a2,b1,b2 order
--   mine    the slot index this player controls
--   host    true if this client runs the simulation
--   net     { send = fn(payload), poll = fn() -> { payload } } or nil
--   onDone  called with "win"|"loss"|"draw" once the battle ends
function M.new(game, opts)
  local eng = loadEngine()
  if not eng then return nil, "2-on-2 battles need the engine's battle modules." end

  local ruleset
  do
    local rulesets = game.data.rulesets
    local selected = game.save and game.save.options and game.save.options.ruleset
    ruleset = (rulesets and selected and rulesets[selected])
      or (rulesets and rulesets.gen1_faithful)
      or {}
  end

  local self = setmetatable({
    game = game,
    isOpaque = true,
    mine = opts.mine or 1,
    host = opts.host and true or false,
    -- Which player is simulating. Held so a disconnect can tell "the host
    -- left" (nobody can resolve another turn) from "a player left" (the fight
    -- continues three ways).
    hostId = opts.hostId,
    -- The trainer this battle stood in for: their picture, their music, and
    -- the line they say when they lose.
    trainer = opts.trainer,
    trainerPic = opts.trainerPic,
    endBattleText = opts.endBattleText,
    -- Whether winning this one moves anybody's rating. Handed in rather than
    -- worked out here: Coop owns that rule (see its `ranksPoints`), and a
    -- second copy of it living in the battle screen is a second copy to get
    -- out of step.
    ranksPoints = opts.ranksPoints and true or false,
    net = opts.net,
    onDone = opts.onDone,
    phase = "intro",
    moveIndex = 1,
    targetIndex = 1,
    frame = 0,
    messages = {},
    shown = nil,
    events = {},
    pending = {},      -- actions collected this turn, keyed by slot
    -- Two silences, measured separately. `waitClock` is the host waiting on a
    -- player's choice; `hostClock` is everybody else waiting on the host.
    waitClock = 0,
    hostClock = 0,
    sent = false,
    result = nil,
  }, M)

  local rng = function(a, b)
    if love and love.math then return love.math.random(a, b) end
    return a
  end

  -- The adapter first, because the sim resolves moves through it. It reads the
  -- sim's slot list live rather than a copy, so a send-out the sim does is
  -- visible to the next move the engine resolves.
  local slots = {}
  local field = CoopField.new(
    { BattleState = eng.BattleState, rng = rng }, game, slots, ruleset)

  self.sim = CoopSim.new({
    data = game.data,
    ruleset = ruleset,
    damage = eng.Damage,
    status = eng.Status,
    turnOrder = eng.TurnOrder,
    makeBattler = eng.BattleState.makeBattler,
    field = field,
    drain = CoopField.drain,
    itemUse = eng.ItemEffects and eng.ItemEffects.use,
    experience = eng.Experience,
    movesAt = eng.Experience and eng.Experience.movesLearnedAt,
    trainerAI = eng.TrainerAI,
    -- The trainer the NPC side came from, and how many class actions it may
    -- spend. wAICount in the original; without it every gym leader would
    -- potion on every turn it was allowed to.
    trainer = opts.trainer,
    aiUses = opts.aiUses,
    save = game.save,
    onError = function(err)
      mod.log:warn("a move failed to resolve in a co-op battle (%s); the "
        .. "battle continues -- report the move it happened on", tostring(err))
    end,
    rng = rng,
  }, opts.slots)

  -- The field was built before the sim had slots; point it at the real list
  -- now that there is one.
  field.slots = self.sim.slots

  if eng.TypeChart and eng.TypeChart.load then
    pcall(eng.TypeChart.load, game.data)
  end

  -- The engine's own subanimation player, driving the engine's own animation
  -- data. It draws in the classic 160x144 coordinate space with one player pic
  -- and one enemy pic, so drawAnim below translates each frame onto the slot
  -- that actually acted -- the same trick WideBattle uses to move an animation
  -- between two anchors it was not authored for.
  if eng.AnimPlayer and game.data.battle_anims then
    local ok, player = pcall(eng.AnimPlayer.new, game.data.battle_anims)
    if ok then self.animPlayer = player end
  end
  return self
end

-- ------- lifecycle

-- Announced to any mod that cares, on this mod's own event names.
--
-- **Not `battle.started` / `battle.ended`.** `mod.events:emit` is namespaced by
-- the loader -- a mod may only emit `mod.<id>.*` -- and that rule is a good
-- one: it is what stops any installed mod forging an engine event and having
-- every listener believe the engine said it. So a co-op battle says so under
-- its own name, and a mod that wants to hear about one listens for that.
--
-- The payload carries the same three things the engine's own battle events
-- carry, plus the slot roster, because "who is in it" is the question a
-- four-way battle raises that a 1v1 does not.
-- Tell the rest of the game a co-op battle happened.
--
-- **The engine's own `battle.started` and `battle.ended` never fire for one**,
-- and cannot be made to. `battle.started` is emitted from `BattleState:enter`,
-- and the trainer battle this displaced is taken off the stack before it ever
-- enters; `battle.ended` is emitted from `BattleState:finish`, and the co-op
-- flow calls that battle's `onFinish` directly rather than finishing it. So a
-- mod watching the engine's events sees nothing at all -- not a co-op battle
-- starting, and not a trainer being beaten by two people.
--
-- A mod cannot emit an engine event: `mod.events:emit` is namespaced to
-- `mod.<id>.*` precisely so that no mod can forge one. So these are the mod's
-- own, under `mod.rby_mmo.`, and the payload is shaped to be worth listening
-- to rather than to be a notification -- a listener that has to reach into
-- `battle` for everything might as well not have been told.
function M:announce(name, extra)
  local slots = (self.sim and self.sim.slots) or {}
  local human = 0
  for _, slot in ipairs(slots) do
    if slot.owner then human = human + 1 end
  end
  local payload = {
    -- The running battle, handed over as the engine's own `battle.started`
    -- hands over its BattleState. **Read only**: it is not a copy, so a
    -- listener that writes to it desyncs all four clients. Said in the README
    -- beside the snippet, which is where somebody writing a listener looks.
    battle = self,
    -- What *kind* of battle, as a word. This used to be the slot count -- a
    -- number, under a name that reads like a category -- so a listener asking
    -- "is this a party battle?" got `4` and could only be wrong.
    --
    -- Asked through `M:partyBattle`, which is the same question the RUN rule
    -- turns on -- one definition, so a listener and the rules can never
    -- disagree about which sort of battle this is.
    kind = self:partyBattle() and "party" or "npc",
    fighters = #slots,
    humans = human,
    -- Who this client is in it, so a listener does not have to work out which
    -- of the four is the player it is running inside.
    mine = self.mine,
    side = slots[self.mine] and slots[self.mine].side,
    host = self.host,
    trainerId = self.trainer and self.trainer.id,
    -- Whether it moves anybody's rating -- see Coop.ranksPoints.
    ranked = self.ranksPoints and true or false,
    slots = {},
  }
  for i, slot in ipairs(slots) do
    payload.slots[i] = {
      side = slot.side, owner = slot.owner, name = slot.name,
      species = slot.battler and slot.battler.mon and slot.battler.mon.species,
    }
  end
  for k, v in pairs(extra or {}) do payload[k] = v end
  local ok, err = pcall(function()
    mod.events:emit("mod.rby_mmo." .. name, payload)
  end)
  if not ok then
    mod.log:warn("could not announce %s (%s); the battle is unaffected",
      name, tostring(err))
  end
end

-- Which battle theme this is, decided by the engine's own rule rather than by
-- a guess here.
--
-- "trainer" is not good enough: a gym leader has their own theme, the rival's
-- last fight has another, and the rule that separates them reads a badge table
-- this mod has no business duplicating. So the engine's `computeMusicKind` is
-- run against a stand-in carrying only the two fields it reads -- which is why
-- the trainer's id travels with the assembled field. A client that joined by
-- invitation and never met this trainer would otherwise hear the ordinary
-- trainer theme while the host heard the gym leader's.
--
-- Answered once. The victory theme is `kind .. "Win"`, so a kind that moved
-- between the start of the battle and the end of it would answer the gym
-- leader's theme with the wrong jingle.
function M.musicKind(self)
  if self.cachedMusicKind then return self.cachedMusicKind end
  local kind = self.trainer and "trainer" or "link"
  local eng = engine
  if eng and eng.BattleState and self.trainer then
    local probe = setmetatable({ kind = "trainer", trainer = self.trainer },
      { __index = eng.BattleState })
    local ok, decided = pcall(probe.computeMusicKind, probe)
    if ok and type(decided) == "string" then kind = decided end
  end
  self.cachedMusicKind = kind
  return kind
end

function M:enter()
  -- The trainer theme, through the engine's own picker so a gym leader still
  -- gets a gym leader's music. `kind` is the battle's, not this screen's: a
  -- co-op fight against a trainer is a trainer battle to everything except the
  -- turn loop.
  local eng = engine
  if eng and eng.Music then
    pcall(eng.Music.playBattle, self.game.data, self:musicKind(),
      self.trainer and self.trainer.id or nil)
  end
  self:say("2 on 2 battle!")
  self.phase = "messages"
  self.after = "choose"
  self:announce("coop_battle_started")
end

-- The fanfare, once, when the result is known.
--
-- The jingle is looked up as `kind .. "Win"`, and the rival's last fight is
-- the one place where the two kinds part company: its battle theme is its own
-- but its victory theme is the gym leader's, so "final" is folded to "gym"
-- here the way the engine folds it. Asking for a "finalWin" that no build has
-- would be silence where the fanfare belongs.
--
-- Guarded against a second call because a result can be reached twice -- a
-- forfeit racing the last knockout -- and the original starts this music once.
function M:playVictoryMusic()
  if self.result ~= "win" or self.victoryMusicPlayed then return end
  self.victoryMusicPlayed = true
  local eng = engine
  if not (eng and eng.Music) then return end
  local kind = self:musicKind()
  if kind == "final" then kind = "gym" end
  pcall(eng.Music.playVictory, self.game.data, kind,
    self.trainer and self.trainer.id or nil)
end

-- Give back an item paid for on a turn that never happened.
--
-- The bag is debited when the action is committed, because only this client
-- owns it -- but the battle can end before that action is ever resolved: the
-- host disconnects, the stall clock fires, somebody forfeits. A potion that
-- healed nobody should not be gone.
function M:refundUnspent()
  local id = self.owed
  self.owed = nil
  if not id then return end
  local inventory = self.game.save and self.game.save.inventory
  if not inventory then return end
  inventory[id] = (inventory[id] or 0) + 1
  self.itemList = nil
end

function M:exit()
  self:refundUnspent()

  -- The world gets its music back on the way out, win or lose. The victory
  -- theme loops until something stops it -- each Defeated* song ends in a
  -- `sound_loop 0` -- so a win that did not restore here would follow the
  -- players back into the overworld and play there forever. The engine's own
  -- finish() restores unconditionally for the same reason.
  local eng = engine
  if eng and eng.Music then pcall(eng.Music.restoreMap, self.game.data) end
  if self.onDone and not self.reported then
    self.reported = true
    self:announce("coop_battle_ended", { result = self.result or "draw" })
    self.onDone(self.result or "draw", self.toLearn)
  end
end

function M:say(text)
  self.messages[#self.messages + 1] = text
end

function M:mySlot() return self.sim:slot(self.mine) end

-- ------- input
--
-- The same four commands the original offers, in the same 2x2 arrangement.

-- How long a freshly shown line is safe from the button that dismisses it.
--
-- A line used to offer its dismiss window on the very tick it was created:
-- `shown` is set and the A/B check below runs in the same call, before one
-- frame has painted it. So a player holding A through a battle -- which is
-- every player -- swallowed lines they never saw, and the ones printed by a
-- menu that answers itself were invisible: press A on ITEM with an empty bag
-- and "You have nothing to use!" was queued, shown and eaten inside a single
-- frame, leaving a flicker and a menu that appeared to do nothing at all.
--
-- A quarter of a second is longer than any button edge and shorter than any
-- deliberate press, and it is a floor rather than a delay: the auto-advance
-- below is untouched, so nothing waits longer than it did.
local MSG_MIN_DWELL = 0.25

-- ...and how long a line stays up when nobody presses anything. Named rather
-- than written twice: the run-consent states read it too (M:updateRunAsk), and
-- two copies of a timing constant are two things to move separately.
local MSG_AUTO_ADVANCE = 1.6

function M:update(dt)
  self.frame = self.frame + 1
  local input = self.game.input

  if self.net then
    self:drainNet()
    self:tickStalls(dt or 0)
  end

  if self.phase == "messages" then
    -- An animation holds the queue while it runs, so a move's flash lands
    -- before the line that says what it did -- the engine's own ordering.
    if self.anim then
      if self.animPlayer and self.animPlayer.update then
        pcall(self.animPlayer.update, self.animPlayer)
      end
      local done = true
      if self.animPlayer and self.animPlayer.isDone then
        local ok, finished = pcall(self.animPlayer.isDone, self.animPlayer)
        done = (not ok) or finished
      end
      if done or input:wasPressed("b") then self.anim = nil end
      return
    end
    -- A falling bar holds the queue exactly as an animation does, and -- like
    -- the engine's -- it cannot be hurried. `UpdateHPBar` is not a text page:
    -- the engine reads the button only for a page that has finished printing,
    -- so A and B do nothing here. Stepped once per call rather than by `dt`,
    -- because this screen's update runs on the same fixed 60Hz step the engine
    -- counts its frames in.
    if self.draining then
      self:stepDrain()
      return
    end
    if self.faintFx then
      self:stepFaint()
      return
    end
    -- A swap costs no time at all: it is the moment the screen catches up with
    -- a send-out the field applied a while ago, and everything the departed
    -- monster was owed has just finished playing. Taken here rather than in
    -- the effect branch below because it neither blocks nor clears the line on
    -- screen -- "CAL sent out X!" is printed over a field that already has X
    -- standing on it, which is the order the original prints it in. Drained in
    -- a loop so a slot swapped twice in one turn does not cost a frame each.
    while true do
      local head = self.messages[1]
      if type(head) == "table" and head.swap then
        table.remove(self.messages, 1)
        self:applySwap(head)
      else
        break
      end
    end
    if #self.messages > 0 then
      -- An effect runs *under* the line already on screen.
      --
      -- These used to wait for `self.shown` to clear, which meant the box went
      -- blank for the whole of every flash and every drain: the monster was
      -- hit by a move nothing on screen still named. The engine keeps the last
      -- page up while its effects play, so the head of the queue is taken as
      -- soon as it is an effect, `shown` is left where it is, and the dwell
      -- clock below is not ticked while one runs -- a line must not time out
      -- in the middle of the thing it is describing.
      local head = self.messages[1]
      if type(head) == "table"
         and (head.anim or head.drain or head.faintfx) then
        table.remove(self.messages, 1)
        if head.anim then
          self.acting = head.from or self.acting
          self:startAnim(head)
        elseif head.drain then
          self:startDrain(head)
        else
          self:startFaint(head)
        end
        return
      end
      if self.shown == nil then
        local next = table.remove(self.messages, 1)
        if type(next) == "table" then
          self.acting = next.from or self.acting
          next = next.text
        end
        self.shown = next
        self.msgClock = 0
      end
    end
    -- ------- the dwell, which the **last** line of a queue is owed too
    --
    -- This used to live inside the queue check above, and that is the whole of
    -- the reported flicker. A line is *removed* from the queue at the moment
    -- it is shown, so the last one leaves the queue empty -- and on the very
    -- next tick the handover below cleared it and opened a menu over the top,
    -- whatever the player did. Every batch's final line therefore got exactly
    -- one frame, and a batch of exactly one line -- "You have nothing to
    -- use!", "There's no one else to send out!" -- was never readable at all:
    -- press A on an empty bag and the menu blinked and did nothing.
    --
    -- So the queue and the line on screen are two separate questions now. A
    -- line is up until it is dismissed, and only then is the box handed back.
    if self.shown ~= nil then
      self.msgClock = (self.msgClock or 0) + (dt or 0)
      -- advanced by A, or by a short dwell, so a long exchange does not need
      -- four buttons pressed for every hit -- but not before the line has been
      -- on screen long enough to be read (see MSG_MIN_DWELL). The clock is not
      -- ticked while an effect runs, so the floor is a quarter of a second of
      -- the line actually being *up*, not of wall time under a flash.
      if self.msgClock >= MSG_MIN_DWELL
         and (input:wasPressed("a") or input:wasPressed("b")) then
        self.shown = nil
      elseif self.msgClock > MSG_AUTO_ADVANCE then
        self.shown = nil
      end
      return
    end
    -- A row that carried no text at all (an empty `msg` event) leaves nothing
    -- on screen and nothing to wait for -- the next tick takes the row behind
    -- it rather than treating the queue as spent.
    if #self.messages > 0 then return end
    if self.result then return self:finish() end
    -- The queue is empty and nobody is mid-effect, so whatever the bars were
    -- animating towards is simply where they are. Snapped rather than left to
    -- arrive on its own: the next thing to happen is a menu, and a bar still
    -- creeping under one is a bar that will still be creeping when the answer
    -- to that menu resolves.
    self:snapDisplay()
    -- ...and the box is handed back empty. The line that was on it has already
    -- been dismissed by the dwell above -- including the case this clear was
    -- written for, a queue that *ends* on an effect row and pops it while
    -- `shown` is still set. That line now keeps the box until it is dismissed
    -- like any other, rather than either vanishing on the next tick or sitting
    -- there through the whole of the next wait, on top of the wait and
    -- spectating lines that exist to say the battle has not hung. Cleared here
    -- anyway, because the clock has to be put away and a `shown` that somehow
    -- survived would outlive the phase that owns it.
    self.shown = nil
    self.msgClock = nil
    -- ------- and `acted` is deliberately NOT cleared here
    --
    -- This used to reset it, on the reading that a menu about to open is a
    -- turn nobody has answered yet. It is not: the four clients leave the
    -- messages phase at their own pace -- each line is held until *that*
    -- player dismisses it -- so somebody who reads quickly commits while
    -- somebody else is still two lines behind, and the `act` that arrives
    -- meanwhile was thrown away by this clear the moment the slow reader
    -- finally reached their menu. The wait line then named a player who had
    -- already answered, for the rest of the turn.
    --
    -- The turn boundary is covered where the turn actually turns: `tryResolve`
    -- clears it on the host beside `pending`, and `applyTurn` clears it on
    -- every replayer -- above its seq-gap early return, so a turn that arrives
    -- out of order still resets the answers. Both of those happen once per
    -- turn, which is the thing being counted; this handover happens whenever a
    -- batch of messages runs out, which is not.
    self.phase = self.after or "choose"
    -- ...and this is where the turn deadline starts, on the host. See
    -- `M:openTurn` for why it is stamped here and nowhere else.
    self:openTurn()
    -- ...and the countdown the *other three* read starts from the same event.
    -- It is a display of the host's budget, so it has to be measured from the
    -- moment the turn became answerable and not from the moment this particular
    -- client got round to answering -- see the tick in `tickStalls`. Reset on
    -- every client, host included, because the host is showing the same line.
    self.waitShown = 0
    -- ...and so are both halves of the "this wait has gone wrong" state, for
    -- the same reason: a new turn is a new wait, owed its own question if it
    -- too runs past the number it is showing (see `tickStalls`).
    --
    -- `wedged` is cleared here and not only inside `unwedge`, and that matters
    -- more than it looks: a client that flagged a wait and then recovered the
    -- ordinary way -- the host's `res` finally arriving -- would otherwise hold
    -- the flag for the rest of the battle, and the *next* snapshot it ever
    -- received, for any reason, would reopen a menu behind a playing batch.
    -- That is precisely the case `unwedge` promises cannot happen.
    self.wedgeAsked = nil
    self.wedged = nil
    -- ...and this is where the host-silence clock starts, too.
    --
    -- It measures a host that has stopped answering, so it has to be measured
    -- from the moment the host owes an answer -- the handover -- rather than
    -- from its last message. Ticked from the last `res` instead, it was
    -- counting the *narration* that message produced (a dozen lines at
    -- MSG_AUTO_ADVANCE apiece is twenty seconds) plus the deliberation after
    -- it, which together routinely exceed COOP_STALL_TIMEOUT on a perfectly
    -- healthy battle: the 75-versus-60 headroom the timeout is documented to
    -- have only exists if the 60 and the 75 start at the same event.
    self.hostClock = 0
    return
  end

  -- Your own monster comes back to the front the moment the turn is yours to
  -- decide, which is when you need to see it.
  if self.phase == "choose" or self.phase == "move"
     or self.phase == "target" then
    self.acting = nil
  end
  -- A replacement outranks the turn: this slot has nothing on the field, so
  -- there is no move for it to make until one is chosen.
  if self.replacing then return self:updateReplace(input) end
  -- ...and a run consent outranks whatever was underneath it, the same way and
  -- for the same reason: it is a question this player has to answer before the
  -- menu behind it means anything.
  --
  -- Placed **after** the messages branch above, which returns while a batch is
  -- still being read -- so an ask that arrives mid-narration is deferred to the
  -- handover rather than opening a picker over the top of a turn nobody has
  -- finished watching. (And if that turn's own `res` gets there first, it takes
  -- the ask down with it: see `playEvents`.)
  if self.runAsk then return self:updateRunAsk(input, dt) end

  -- Out of the fight, and so out of the decisions.
  --
  -- A player whose last monster fell has nothing to send out and nothing to
  -- act with -- the host already stops waiting on their slot, and files
  -- nothing for it. Without this they were still shown the command menu,
  -- picked a move, and were dropped into "wait" while the turn resolved
  -- around them: a menu that answers nothing, offered over and over, for the
  -- rest of a battle they are no longer in. Their side is still alive while
  -- their partner stands, so the right state is watching, not leaving.
  if self:spectating() then
    self.phase = "wait"
    return
  end

  if self.phase == "choose" then return self:updateCommand(input) end
  if self.phase == "move" then return self:updateMove(input) end
  if self.phase == "target" then return self:updateTarget(input) end
  if self.phase == "switch" then return self:updateSwitch(input) end
  if self.phase == "item" then return self:updateItem(input) end
  -- "wait" does nothing but let drainNet do its work
end

-- Who this client is waiting for, and how long it has been waiting.
--
-- Returns a name and the seconds left on that wait, or nil when nothing is
-- being waited on. Answered on every client from the field itself rather than
-- from the host's bookkeeping: the slot that owes an answer is marked on all
-- four copies, so all four can name the same person.
--
-- The clock each client shows is its own -- a replayer cannot read the host's
-- -- and all four start theirs on the **handover**, the moment the last of a
-- turn's messages is dismissed and the box is handed back. That is an event
-- every client reaches from its own copy of the same batch, which is why the
-- four numbers say the same thing rather than merely something similar.
-- Returns the **budget first** and the name second, and that order is load
-- bearing: callers ask `if self:waitingOn() then`, and a general wait has no
-- name to give -- so a signature that led with the name answered "no, nothing
-- is being waited for" in exactly the case where something was, and the clock
-- never started.
--
-- The general wait answers COOP_TURN_TIMEOUT on **every** client, and that is
-- honest again now that the host really enforces it (see `tickStalls`). It was
-- not, for one release: the only clock at that budget forfeited the host to
-- itself and never touched an idle player, so three of the four clients
-- counted down a number nothing would act on. What each client counts is still
-- its own -- a replayer cannot read the host's -- and all four start it at the
-- handover, which is the same event the host's own deadline is stamped at.
function M:waitingOn()
  if self.result or self.replacing then return nil end
  local pending = self.sim and self.sim:awaitingChoice()
  if pending and pending.index ~= self.mine then
    return Config.COOP_CHOICE_TIMEOUT, (pending.name or "Someone")
  end
  if self.phase == "wait" then
    return Config.COOP_TURN_TIMEOUT, nil
  end
  return nil
end

-- ------- who has not answered yet
--
-- Which slots owe this turn an action, by name. Every client can answer it,
-- because every client hears every `act` -- the relay fans them out to all
-- four and only the host used to read them (see `drainNet`).
--
-- Never this client's own slot. You are not waiting for yourself: your own
-- action is filed the moment you commit, and a wait line that named the
-- person reading it would be a bug report rather than reassurance. (The host's
-- auto-pick makes no such exclusion, and must not: a host that has not
-- answered is exactly what the deadline is for. This is a *display* rule.)
--
-- NPCs are skipped (`slot.owner ~= nil`): their move is chosen inside
-- `tryResolve` and there is nobody to wait for. So are slots that are down --
-- the host stops waiting on those too.
function M:missingActors()
  local out = {}
  if not self.sim then return out end
  local acted = self.acted or {}
  for _, slot in ipairs(self.sim.slots or {}) do
    if slot.owner ~= nil and slot.index ~= self.mine
       and not self.sim:isDown(slot) and not acted[slot.index] then
      out[#out + 1] = tostring(slot.name or "Someone")
    end
  end
  return out
end

-- This slot has answered for this turn, on whichever client noticed.
--
-- Lazily built, because every reader tolerates its absence and the suite
-- builds clients straight out of `setmetatable` without one.
function M:markActed(index)
  if not index then return end
  self.acted = self.acted or {}
  self.acted[index] = true
end

-- The line a wait puts in the message box once it has gone on long enough to
-- need explaining. Nil until then, because a clock that flashed up on every
-- ordinary turn would be noise rather than reassurance.
--
-- ------- the name **and** the number
--
-- The general wait spent one release saying only who, and the reason was
-- sound at the time: `tickStalls` acted on that budget on the host alone, so a
-- replayer counted 60 down to 0 and then sat on "(0)" for as long as the wait
-- lasted, saying the battle had hung when it had not.
--
-- The deadline is real on every slot now -- the host auto-picks for anybody
-- still deciding at COOP_TURN_TIMEOUT, itself included -- so the number is
-- honest again and comes back beside the name. Each of the four ticks its own
-- `waitShown`, and all four reset it at the **handover**: the moment the turn's
-- last message is dismissed and the menu opens. That is the same event
-- `openTurn` stamps the host's deadline at, so the number a player reads is a
-- promise that something happens around then, and that promise is now kept.
function M:waitLine()
  local budget, who = self:waitingOn()
  if not budget then return nil end
  local spent = self.waitShown or 0
  if spent < Config.COOP_WAIT_HINT then return nil end
  local left = math.max(0, math.ceil((budget or 0) - spent))
  -- Split so a full-length name still fits. The box is eighteen characters
  -- wide, a trainer name is up to ten, and "<NAME> is choosing... (30)" on one
  -- line ran off the right edge -- which is how a clipped line gets shipped:
  -- it looks fine for every short name anybody tests with.
  if who then return ("%s is\nchoosing... (%d)"):format(who, left) end
  local missing = self:missingActors()
  local name = missing[1]
  if name then
    name = name:sub(1, Config.NAME_MAX)
    -- ------- what fits, in the order it is worth keeping
    --
    -- Eighteen columns for "<NAME>... +N (60)", and at NAME_MAX all three
    -- cannot have them: ten for the name, three for the ellipsis and five for
    -- " (60)" is exactly eighteen with nothing left over. So the rule, in
    -- priority order: the **name** is never truncated, the **number** is kept
    -- because it is the half the deadline makes true, and the " +N" tail --
    -- "how many others are also still deciding" -- is the one that goes. Both
    -- tails are measured rather than assumed, so the day NAME_MAX moves the
    -- line loses a tail instead of running off the edge.
    local more = (#missing > 1) and (" +%d"):format(#missing - 1) or ""
    local clock = (" (%d)"):format(left)
    if #name + #more + 3 + #clock > 18 then more = "" end
    if #name + 3 + #clock > 18 then clock = "" end
    return ("Waiting for\n%s...%s%s"):format(name, more, clock)
  end
  -- Nobody nameable -- an older host that sends no `act` this client can read,
  -- or a turn whose last answer is already in flight. The number still stands
  -- on its own: the deadline is what makes the box worth reading, and a client
  -- that cannot name anybody is exactly the one that most needs telling the
  -- wait is bounded. No host special case any more -- there is one budget and
  -- one mechanism behind it now, so there is one line.
  return ("Waiting for the\nothers... (%d)"):format(left)
end

-- Has this player anything left to do?
--
-- Down *and* not being asked for a replacement means down for good: a slot
-- with a reserve is `replacing` instead, and one that is merely waiting on
-- somebody else is not down at all. `gone` counts too -- a forfeited slot is
-- as out as an empty one.
function M:spectating()
  if self.result then return false end
  if self.replacing then return false end
  -- Guarded on the field, not only on the slot: this is read from `draw`,
  -- which runs every frame including the ones where the battle is being torn
  -- down, and a nil field there would take the screen out through the pcall
  -- that guards drawing rather than through anything that could report it.
  if not self.sim then return false end
  local slot = self:mySlot()
  return slot ~= nil and self.sim:isDown(slot)
end

function M:liveMoves()
  local slot = self:mySlot()
  local battler = slot and slot.battler
  return (battler and battler.curMoves) or {}
end

-- FIGHT / ITEM / SWITCH / RUN, laid out 2x2 like the original's command box.
M.COMMANDS = { "FIGHT", "ITEM", "SWITCH", "RUN" }

-- ------- one step around a 2x2 picker
--
-- Every picker on this screen is drawn by `drawList`, which lays its rows out
-- **row-major across two columns**: row 1 top-left, row 2 top-right, row 3
-- bottom-left, row 4 bottom-right. So the arrows have to move that way too,
-- and until now they did not: the command box cycled 1>2>3>4>1 on up/left and
-- down/right, which meant DOWN from FIGHT landed on ITEM -- the box to its
-- *right* -- and LEFT from FIGHT wrapped round to RUN. Anybody navigating by
-- what is on screen went somewhere else.
--
-- The rule is the engine's own (BattleState.lua:1544-1557): decompose the
-- index into a row and a column, move one of them, clamp at every edge. No
-- wrap anywhere -- LEFT from FIGHT stays on FIGHT.
--
-- `count` closes the second half of it, and that is the Wide-layout move
-- grid's rule (WideBattle.lua:351-377): a direction that points at a slot
-- past the end of the list **holds** the current position rather than moving
-- to a row that is not drawn. Three moves, cursor on the second: DOWN would
-- be slot four, which nothing occupies, so the cursor stays where it is.
--
-- One deliberate difference from WideBattle: its horizontal step *crosses* to
-- the other column (LEFT and RIGHT do the same thing) rather than clamping.
-- Here the command box and the move list are the same box, drawn by the same
-- function, one press apart -- so both clamp, and no arrow on this screen ever
-- wraps.
local function gridStep(index, count, direction)
  local row = math.floor((index - 1) / 2)
  local col = (index - 1) % 2
  if direction == "left" then col = math.max(0, col - 1)
  elseif direction == "right" then col = math.min(1, col + 1)
  elseif direction == "up" then row = math.max(0, row - 1)
  elseif direction == "down" then row = math.min(1, row + 1)
  else return index end
  local moved = row * 2 + col + 1
  if moved > count then return index end
  return moved
end

local GRID_KEYS = { "left", "right", "up", "down" }

-- The slot a directional press lands on, or nil when no direction was pressed
-- -- so the caller's own A / B handling stays exactly where it was.
local function gridPress(index, count, input)
  for _, key in ipairs(GRID_KEYS) do
    if input:wasPressed(key) then return gridStep(index, count, key) end
  end
  return nil
end

function M:updateCommand(input)
  self.commandIndex = self.commandIndex or 1
  local moved = gridPress(self.commandIndex, #M.COMMANDS, input)
  if moved then
    self.commandIndex = moved
  elseif input:wasPressed("a") then
    local command = M.COMMANDS[self.commandIndex]
    if command == "FIGHT" then
      self.moveIndex = 1
      self.phase = "move"
    elseif command == "SWITCH" then
      self.switchIndex = 1
      self.phase = "switch"
    elseif command == "ITEM" then
      self.itemIndex = 1
      self.phase = "item"
    elseif command == "RUN" then
      -- Two different questions behind one command, told apart by who is on
      -- the other side of the field (M:partyBattle).
      --
      -- Against a **trainer** it is the original's question, and the original's
      -- answer: you cannot run from a trainer battle. Filed as an action rather
      -- than answered here, so the refusal arrives in the turn's own message
      -- flow and costs the turn exactly as the original's does.
      --
      -- Against **two other players** it is a question Gen 1 never had to ask,
      -- and the answer is neither the refusal nor a unilateral escape: leaving
      -- ends the battle for four people and books the pair who left a ranked
      -- loss, so the other half of that pair is asked first (M:askToRun).
      -- Nothing is committed until they answer -- see the state machine there.
      if self:partyBattle() then
        self:askToRun()
      else
        self:commit({ slot = self.mine, kind = "run" })
      end
    end
  end
end

-- ------- moves that are aimed at nobody
--
-- Three effects that a zero-power primary record does not tell apart from a
-- Swords Dance, because each of them reads the monster the player picked:
--
--   * HAZE_EFFECT (MoveEffects.lua:234) walks `{ user, target }` and resets
--     both sides' stages, screens and counters;
--   * CONVERSION_EFFECT (MoveEffects.lua:277) copies the *target's* types
--     onto the user, and fails outright against a mid-Fly target;
--   * TRANSFORM_EFFECT (MoveEffects.lua:292) becomes the target -- its
--     species, its sprite, its stats and its moves.
--
-- So they keep the picker even though the predicate below would clear them.
local READS_ITS_TARGET = {
  HAZE_EFFECT = true, CONVERSION_EFFECT = true, TRANSFORM_EFFECT = true,
}

-- Does this move have to be aimed at somebody?
--
-- The question the move menu is really asking, and the reason "Attack who?"
-- used to open on a Swords Dance: a self-only move was made to pick one of two
-- foes for no reason, and whichever the player chose changed nothing.
--
-- Answered from the engine's own bookkeeping rather than from a list of move
-- names. A zero-power move whose merged `move_effects` record is `primary` and
-- is **not** `accuracyChecked` is self-targeting by construction: pokered's
-- ACC_CHECKED set (MoveEffects.lua:377-388) is exactly the status handlers
-- that call MoveHitTest against the other side -- Growl, Thunder Wave, Toxic,
-- Sleep Powder, Leech Seed, Disable, Confuse Ray -- and the comment beside it
-- says the rest of `MoveEffects.primary` "is self-targeting and never rolls
-- accuracy". That leaves Swords Dance, Rest, Recover, Light Screen, Reflect,
-- Mist, Substitute, Focus Energy and the rest of their family.
--
-- Conservative in every other direction, because a picker offered needlessly
-- costs a button press and one skipped wrongly costs a turn: anything with
-- power, anything whose record is missing, and every `kind == "full"` record
-- (Roar and Whirlwind, Mimic, Metronome -- effects that run their own flow and
-- cannot be classified this way) keeps the picker.
--
-- `data` is reached through a guard rather than off `self.game` directly: every
-- other nil path in here lands on `true` -- no move, no record, no effect all
-- keep the picker -- and this was the one that threw instead, on a screen built
-- without a game (which is how the suite builds one) or during a teardown that
-- has already let go of it.
function M:needsTarget(moveInst)
  local data = self.game and self.game.data or {}
  local def = moveInst and (data.moves or {})[moveInst.id]
  if not def then return true end
  if (def.power or 0) > 0 then return true end
  local record = (data.move_effects or {})[def.effect]
  if not record then return true end
  if record.kind ~= "primary" then return true end
  if record.accuracyChecked then return true end
  if READS_ITS_TARGET[def.effect] then return true end
  return false
end

function M:updateMove(input)
  local moves = self:liveMoves()
  if #moves == 0 then return end
  -- The list is drawn 2x2 (drawMoves), so it is navigated 2x2 -- see gridStep
  -- for the rule and for what a direction pointing past the last move does.
  local moved = gridPress(self.moveIndex, #moves, input)
  if moved then
    self.moveIndex = moved
  elseif input:wasPressed("b") then
    self.phase = "choose"
  elseif input:wasPressed("a") then
    -- Nothing to aim at yet.
    --
    -- A slot whose monster has fainted is *down* until its trainer sends the
    -- next one out, so when both opponents faint in the same turn there is a
    -- real window with no legal target -- and it is exactly the window the
    -- other side is standing in a menu deciding. Refused here with a sentence
    -- rather than opened empty, because an empty picker is a cursor pointing
    -- at nothing that no key gets out of.
    --
    -- Checked ahead of the self-move shortcut below, and for both of them: a
    -- Swords Dance committed during that window would still carry a target
    -- slot, and there is none to name.
    if #self.sim:targetsFor(self:mySlot()) == 0 then
      self.phase = "messages"
      self.after = "choose"
      self:say("Wait for the other\ntrainer!")
      return
    end
    -- A move that is aimed at nobody is committed on the spot.
    --
    -- The target that travels with it is the first living opponent, and it is
    -- **semantically inert**: `CoopSim.runAction` passes the chosen slot
    -- through to `performMove`, and a self-targeting effect record never reads
    -- it. So the wire shape is the one it always was, the sim resolves the
    -- same turn it would have, and the player is spared a question whose
    -- answer could not matter.
    --
    -- Gated on the battler having PP left, and that is not belt and braces:
    -- Gen 1's rule is all-or-nothing, so a monster with every move empty has
    -- Struggle substituted for whatever it picked (`CoopSim.runAction`), and
    -- Struggle *does* read its target -- it is an ordinary attack with recoil.
    -- Shortcutting on the chosen move's own record would therefore aim a real
    -- attack at the first living opponent without asking, on the one turn a
    -- player most wants to choose.
    local pick = moves[self.moveIndex]
    local mine = self:mySlot()
    local hasPP = self.sim:hasPP(mine and mine.battler)
    if pick and hasPP and not self:needsTarget(pick) then
      local first = self.sim:targetsFor(self:mySlot())[1]
      return self:commit({ slot = self.mine, move = self.moveIndex,
                           target = first.index })
    end
    self.targetIndex = 1
    self.phase = "target"
  end
end

-- The mons this trainer could send out instead: alive, and not the one
-- already standing there.
function M:benchOf(slot)
  local out = {}
  for i, mon in ipairs(slot.party or {}) do
    if i ~= slot.active and (mon.hp or 0) > 0 then
      out[#out + 1] = { index = i, mon = mon }
    end
  end
  return out
end

-- Choosing who comes out after a faint.
--
-- The same bench the SWITCH command shows, with one difference that matters:
-- it cannot be cancelled. A monster has fainted and its slot is empty -- there
-- is no "never mind" available, so B does nothing here rather than dropping
-- the player back into a turn they cannot take.
function M:updateReplace(input)
  local slot = self.sim:slot(self.mine)
  local bench = self:benchOf(slot)
  if #bench == 0 then
    self.replacing = nil
    return
  end
  self.switchIndex = math.min(self.switchIndex or 1, #bench)
  if input:wasPressed("up") then
    self.switchIndex = self.switchIndex > 1 and self.switchIndex - 1 or #bench
  elseif input:wasPressed("down") then
    self.switchIndex = self.switchIndex < #bench and self.switchIndex + 1 or 1
  elseif input:wasPressed("a") then
    self.replacing = nil
    self:sendAction({ slot = self.mine, kind = CoopSim.REPLACE,
                      index = bench[self.switchIndex].index })
  end
end

function M:updateSwitch(input)
  local bench = self:benchOf(self:mySlot())
  if #bench == 0 then
    -- Said out loud and routed back through the message flow rather than
    -- bounced silently: a menu that opens and closes on the same button looks
    -- like a broken screen, and gives a player mashing A no way out.
    self:say("There's no one\nelse to send out!")
    self.phase = "messages"
    self.after = "choose"
    return
  end
  if input:wasPressed("up") then
    self.switchIndex = self.switchIndex > 1 and self.switchIndex - 1 or #bench
  elseif input:wasPressed("down") then
    self.switchIndex = self.switchIndex < #bench and self.switchIndex + 1 or 1
  elseif input:wasPressed("b") then
    self.phase = "choose"
  elseif input:wasPressed("a") then
    self:commit({ slot = self.mine, kind = "switch",
                  index = bench[self.switchIndex].index })
  end
end

-- What is in the bag that can be used in a battle at all.
--
-- Read from the live save rather than a copy: an item spent in a co-op battle
-- is spent, the same way it is in any other. Balls are listed, because
-- refusing one is a thing the game *says* rather than a row it hides.
function M:usableItems()
  if self.itemList then return self.itemList end
  local out = {}
  local inventory = (self.game.save and self.game.save.inventory) or {}
  local items = self.game.data.items or {}
  for id, count in pairs(inventory) do
    local def = items[id]
    if def and (count or 0) > 0 and not def.machine and not def.key then
      out[#out + 1] = { id = id, name = def.name or id, count = count }
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  self.itemList = out
  return out
end

function M:updateItem(input)
  local items = self:usableItems()
  if #items == 0 then
    self:say("You have nothing\nto use!")
    self.phase = "messages"
    self.after = "choose"
    return
  end
  if input:wasPressed("up") then
    self.itemIndex = self.itemIndex > 1 and self.itemIndex - 1 or #items
  elseif input:wasPressed("down") then
    self.itemIndex = self.itemIndex < #items and self.itemIndex + 1 or 1
  elseif input:wasPressed("b") then
    self.phase = "choose"
  elseif input:wasPressed("a") then
    local pick = items[self.itemIndex]
    -- Paid for here, on the client that owns the bag.
    --
    -- The host simulates every slot but holds nobody else's inventory, so if
    -- the deduction were left to the simulation an item used by any other
    -- player would work and cost nothing. Spending it at the moment of
    -- committing keeps the bag the one thing each player accounts for
    -- themselves -- the same reason only your own party is the live one.
    local inventory = self.game.save and self.game.save.inventory
    if inventory and (inventory[pick.id] or 0) > 0 then
      inventory[pick.id] = inventory[pick.id] - 1
      if inventory[pick.id] <= 0 then inventory[pick.id] = nil end
      -- Held until the turn it was spent on comes back resolved. The bag is
      -- debited here on purpose -- only this client owns it -- but a turn that
      -- never resolves (the host drops, the stall clock fires) used to take
      -- the item with it, healing nobody.
      self.owed = pick.id
    end
    -- the list is cached, and it has just changed
    self.itemList = nil
    self:commit({ slot = self.mine, kind = "item", item = pick.id })
  end
end

function M:updateTarget(input)
  local targets = self.sim:targetsFor(self:mySlot())
  -- The picker was opened on a target that has since fainted or left. The
  -- early return this used to be swallowed B as well as everything else, so
  -- the player sat on a blank "Attack who?" with no key that did anything --
  -- a wedged battle for all four, from one monster fainting at the wrong
  -- moment. Back out instead; the command menu is still answerable.
  if #targets == 0 then
    self.phase = "choose"
    return
  end
  if self.targetIndex > #targets then self.targetIndex = #targets end
  -- ------- one name per row, so one axis moves
  --
  -- The list is drawn down the box now rather than across it (see drawTarget),
  -- so UP and DOWN are what move between the foes. LEFT and RIGHT are kept as
  -- **aliases** rather than dropped: they moved this picker for a release, a
  -- player who learned that is not wrong about which two monsters are on the
  -- field, and there is no second column for them to mean anything else.
  --
  -- Clamped at both ends like every other picker on this screen -- DOWN on the
  -- last foe stays on the last foe rather than flicking back to the first.
  local step = 0
  if input:wasPressed("up") or input:wasPressed("left") then step = -1
  elseif input:wasPressed("down") or input:wasPressed("right") then step = 1 end
  if step ~= 0 then
    self.targetIndex =
      math.max(1, math.min(#targets, self.targetIndex + step))
  elseif input:wasPressed("b") then
    self.phase = "choose"
  elseif input:wasPressed("a") then
    local target = targets[self.targetIndex]
    self:commit({ slot = self.mine, move = self.moveIndex, target = target.index })
  end
end

-- ------- RUN, in a battle where the other side is people
--
-- **A party cannot leave one of these on one person's say-so.** Two players
-- share a side, share the loss, and share the ranked points that go with it --
-- so one of them pressing RUN is a proposal, not a decision, and the whole of
-- this section is the shape of that proposal.
--
-- Four states, and every one of them is torn down by something that cannot be
-- forgotten:
--
--   asking    -- the asker, waiting. Nothing has been committed: their slot
--                still owes the turn an action, so the deadline treats them
--                exactly as it treats anybody who has not answered.
--   deciding  -- the partner, holding a two-answer picker over whatever they
--                were doing. Offered to a partner who is *spectating* too:
--                their monsters are gone, their half of the decision is not.
--   fleeing   -- the answer was yes; the host's closing events are on their way.
--   refused   -- the answer was no; a line to read, and then the command menu
--                back exactly as it was left, with the turn's own clock still
--                running.
--
-- ------- what rides on the wire, and why the hub never had to learn it
--
-- Two payload kinds inside the battle's existing relay envelope
-- (Wire.COOP_RUN_ASK / Wire.COOP_RUN_ANSWER). Both hubs forward a co-op payload
-- unread -- shape is the only thing they judge -- so this needed no hub change
-- on either side, and a client built before it drops both through its inbound
-- dispatch without a branch. A mixed-version battle therefore degrades to
-- today's behaviour rather than to a hang: the ask is never answered, and the
-- turn deadline files it as a refusal like any other.
--
-- Neither message names a slot. Who asked is the `from` the hub stamps, and
-- which slot that is, is a fact the receiving client reads off its own copy of
-- the field -- the same rule the `act` handler follows, and for the same
-- reason: a slot named in a payload is a slot a modified client could claim.
--
-- ------- and the host is still the only one that may end a battle
--
-- A yes does not end anything by itself. It is *reported*, and the host
-- resolves the flee -- and only after checking it saw the ask that a yes is an
-- answer to, so a modified client cannot forfeit its partner's battle by
-- posting consent nobody asked for.

-- Is this a battle between four players, or two players and a trainer?
--
-- Answered off the field rather than off the trainer record, because that is
-- the description all four clients were built from: a co-op battle against an
-- NPC carries two ownerless slots and a party battle carries none.
-- `self.trainer` would be a weaker test -- a script-driven battle need not name
-- a trainer at all -- and this is the question the run rule turns on.
function M:partyBattle()
  local slots = (self.sim and self.sim.slots) or {}
  if #slots == 0 then return false end
  for _, slot in ipairs(slots) do
    if slot.owner == nil then return false end
  end
  return true
end

-- The other player on this slot's side, if there is still somebody there.
--
-- "Still there" means **present**, not standing. A partner whose last monster
-- fell is spectating -- they have a screen, they are watching this battle, and
-- half of the decision to leave it is theirs exactly as it was before. A
-- partner whose client has gone is the other thing entirely: there is nobody to
-- ask, so this answers nil and the ask is skipped rather than waited on.
function M:partnerOf(slot)
  if not (slot and self.sim) then return nil end
  for _, other in ipairs(self.sim.slots or {}) do
    if other.index ~= slot.index and other.side == slot.side
       and other.owner ~= nil and not other.gone then
      return other
    end
  end
  return nil
end

-- Which slot a player id is sitting in, on this client's copy of the field.
function M:slotOwnedBy(id)
  if id == nil or not self.sim then return nil end
  for _, slot in ipairs(self.sim.slots or {}) do
    if slot.owner ~= nil and slot.owner == id then return slot end
  end
  return nil
end

-- Two answers, laid out in the box four commands normally sit in. Published so
-- the suite can assert the picker without a graphics device.
local RUN_ANSWERS = { "YES", "NO" }
M.RUN_ANSWERS = RUN_ANSWERS

-- ------- and the cursor starts on **NO**, which is the whole safety of it
--
-- Every other picker on this screen opens on the answer a player most often
-- wants. This one opens on the answer that costs nothing, because of *when* it
-- appears: a consent prompt lands at the messages->choose handover, which is
-- the exact moment all four players are holding A to get through the last
-- turn's narration. Opening on YES would mean one already-travelling press
-- forfeits the battle for four people and books two ranked losses -- a decision
-- nobody consciously made, and one that cannot be taken back.
--
-- So the button that is already down answers "no", which is the answer that
-- leaves everything exactly as it was. Saying yes takes a direction and then a
-- press, which is what a deliberate decision looks like.
local RUN_DEFAULT = 2   -- "NO"
M.RUN_DEFAULT = RUN_DEFAULT

-- Ask the partner. Commits nothing.
function M:askToRun()
  if not self:partyBattle() then return false end
  local partner = self:partnerOf(self:mySlot())
  self.runAsk = { role = "asking", slot = partner and partner.index,
                  name = partner and partner.name }
  if self.net then self.net.send({ t = Wire.COOP_RUN_ASK }) end
  -- The host hears its own ask directly rather than off the wire: the relay
  -- fans a message out to everyone *except* its sender, so a host that waited
  -- to receive its own ask would wait forever.
  if self.host then self:hostRunAsk(self.mine) end
  return true
end

-- The partner's answer, sent and -- when this client is also the host --
-- acted on in the same breath, for the reason above.
function M:answerRun(ok)
  if not self.runAsk then return false end
  ok = ok and true or false
  -- A yes leaves this player watching for the host's closing events; a no puts
  -- them straight back where they were, because nothing about their own turn
  -- was ever touched.
  self.runAsk = ok and { role = "fleeing" } or nil
  if self.net then
    self.net.send({ t = Wire.COOP_RUN_ANSWER, ok = ok })
  end
  if self.host then self:hostRunAnswer(self.mine, ok) end
  return true
end

-- The host, noting an ask.
--
-- Recorded rather than acted on, because the thing that acts on it is the
-- answer -- with one exception, which is the whole reason this returns
-- something: a player whose partner is **gone** has nobody to get permission
-- from, and holding them in a battle until a disconnected client answers would
-- be the deadlock this consent flow exists to avoid. They leave immediately.
function M:hostRunAsk(index)
  if not (self.host and self.sim) or self.result then return false end
  if not self:partyBattle() then return false end
  local slot = self.sim:slot(index)
  if not (slot and slot.owner ~= nil and not slot.gone) then return false end
  self.runAsks = self.runAsks or {}
  self.runAsks[index] = true
  if not self:partnerOf(slot) then return self:resolveFlee(index) end
  return true
end

-- The host, hearing an answer.
--
-- A no is nothing to the host: the asker closes their own wait on the same
-- message, and no turn state was ever written. A yes is checked against the ask
-- it claims to answer -- the answerer's partner must be a slot this host
-- actually saw ask, on this turn -- and only then does the party leave.
function M:hostRunAnswer(index, ok)
  if not (self.host and self.sim) or self.result then return false end
  if not ok then return false end
  local slot = self.sim:slot(index)
  local partner = slot and self:partnerOf(slot)
  if not (partner and (self.runAsks or {})[partner.index]) then
    mod.log:warn("a co-op run answer arrived with no ask behind it, so it is "
      .. "ignored; the battle carries on and whoever wanted to leave can pick "
      .. "RUN again")
    return false
  end
  return self:resolveFlee(partner.index)
end

-- The party leaves, and the battle ends for all four.
--
-- Broadcast as an ordinary resolved batch -- a numbered `res` with the field's
-- signature on it -- so the three replayers apply it through exactly the path
-- every turn takes. The `over` event inside it is the *same* event a knockout
-- produces, which is what makes `resultFor` answer "loss" on both clients that
-- left and "win" on both they left, and the ranked report that follows is the
-- one that was already there. Nothing new reaches the outcome vocabulary.
--
-- No action is resolved, so nothing is spent: an item paid for on the turn that
-- was being decided is still owed, and `refundUnspent` gives it back on the way
-- out.
function M:resolveFlee(index)
  if not (self.host and self.sim) or self.result then return false end
  local slot = self.sim:slot(index)
  if not (slot and slot.side) then return false end

  local events = {}
  events[#events + 1] = { kind = "msg",
    text = (slot.name or "Someone") .. "'s party\nfled the battle!" }
  if not self.sim:fled(slot.side, function(e) events[#events + 1] = e end) then
    return false
  end

  -- The turn that was being decided is void, and everything that belonged to it
  -- goes with it -- including the deadline, which has nothing left to enforce.
  self.pending = {}
  self.acted = nil
  self.runAsks = nil
  self.turnOpened = nil

  self.seq = (self.seq or 0) + 1
  if self.net then
    self.net.send({ t = "res", seq = self.seq, sig = self.sim:signature(),
                    events = events })
  end
  self:playEvents(events)
  return true
end

-- The prompt and the wait, driven with the same grid the command box uses --
-- because it is the same box, with two answers where four commands normally sit.
function M:updateRunAsk(input, dt)
  local ask = self.runAsk
  if not ask then return end
  -- Ticked for every state, and counted from the first frame this prompt is
  -- actually being *driven* -- which is not the frame it arrived, if it arrived
  -- behind a batch of messages (see the branch order in `update`).
  ask.clock = (ask.clock or 0) + (dt or 0)

  if ask.role == "deciding" then
    ask.index = ask.index or RUN_DEFAULT
    local moved = gridPress(ask.index, #RUN_ANSWERS, input)
    if moved then
      ask.index = moved
      return
    end
    -- ------- and no button counts until the box has been on screen
    --
    -- The same floor a freshly printed line gets (MSG_MIN_DWELL), for the same
    -- reason and against a worse consequence. This prompt opens at the handover
    -- with A held down; without a floor the press that dismissed the last line
    -- of narration would also answer a question the player has not seen yet.
    -- A quarter of a second is longer than any button edge and shorter than any
    -- deliberate press, so it costs a deciding player nothing.
    --
    -- The cursor is exempt: moving it is not an answer, and a player who
    -- pre-positions on YES during the floor and then presses A has made exactly
    -- the two-step decision this is asking for.
    if ask.clock < MSG_MIN_DWELL then return end
    if input:wasPressed("a") then
      self:answerRun(ask.index == 1)
    elseif input:wasPressed("b") then
      -- B backs out of every other picker on this screen, and backing out of
      -- "shall we leave?" is saying no.
      self:answerRun(false)
    end
    return
  end

  -- "asking" and "fleeing" are ended by the message that answers them, never
  -- by a button: there is nothing here for a press to mean. "refused" is a line
  -- to read, and it is read the way every other line on this screen is -- a
  -- floor before a press counts, and an auto-advance behind it (MSG_MIN_DWELL).
  --
  -- Deliberately **not** routed through the message queue, which is what would
  -- otherwise have said this: reaching the messages phase would hand the box
  -- back through `openTurn` on the way out, and re-arm the very turn deadline
  -- this refusal must leave running.
  if ask.role ~= "refused" then return end
  if ask.clock >= MSG_MIN_DWELL
     and (input:wasPressed("a") or input:wasPressed("b")) then
    self.runAsk = nil
  elseif ask.clock > MSG_AUTO_ADVANCE then
    self.runAsk = nil
  end
end

function M:drawRunAsk()
  local ask = self.runAsk
  if not ask then return end
  local name = ask.name
  if ask.role == "deciding" then
    -- Short on purpose: the title row is one line of the box, and at NAME_MAX
    -- "%s: RUN?" is eighteen columns exactly.
    return self:drawList(RUN_ANSWERS, ask.index or RUN_DEFAULT,
      ((name or "They") .. ": RUN?"))
  end
  if ask.role == "refused" then
    return self:drawText((name or "They") .. " says\nNO!")
  end
  if ask.role == "fleeing" or not name then
    return self:drawText("Getting away...")
  end
  return self:drawText("Asking " .. name .. "\nto RUN...")
end

-- ------- one turn, across four clients

-- This client has chosen. The host files it; everybody else posts it and waits.
-- Send an action that is not part of a turn.
--
-- A replacement is answered immediately rather than collected with everybody
-- else's choices: the turn is already paused waiting for it, and holding it
-- back would deadlock the pause against itself.
function M:sendAction(action)
  if self.host then return self:applyReplace(action) end
  if self.net then self.net.send({ t = "act", action = action }) end
end

function M:applyReplace(action)
  local events = {}
  -- Said before the monster is sent out, and said to everybody: a choice that
  -- was made *for* somebody by a clock looks exactly like a choice they made,
  -- and the player who ran out of time is owed the difference.
  if action.forced then
    local slot = self.sim:slot(action.slot)
    events[#events + 1] = { kind = "msg",
      text = ((slot and slot.name) or "Someone") .. "\ntook too long!" }
  end
  -- Who is on screen, taken before the field moves. See M:holdDisplay: this is
  -- the one client that simulates first and shows afterwards, so a battler it
  -- does not hold on to here is one it can no longer draw.
  self:holdDisplay()
  local ok = self.sim:replace(action.slot, action.index,
    function(event) events[#events + 1] = event end)
  if not ok then return false end
  self.seq = (self.seq or 0) + 1
  if self.net then
    self.net.send({ t = "res", seq = self.seq,
                    sig = self.sim:signature(), events = events })
  end
  self:playEvents(events)
  self:tryResolve()
  return true
end

function M:commit(action)
  self.phase = "wait"
  -- Your own answer is in, whoever else's is not -- which is what keeps the
  -- wait line from naming the person reading it.
  self:markActed(action.slot)
  -- ...and everybody else is told, **including when this client is the host**.
  --
  -- The host used to file straight into `pending` and return, so its own
  -- choice never went on the wire at all. The other three learn who has
  -- answered by watching `act` go past (see the observe-only branch in
  -- `drainNet`), so they could never learn the host had chosen: their wait
  -- line named the host for the whole of every turn, while the host sat in
  -- `tryResolve` waiting on *them*. The one player who is never late was the
  -- one everybody was told to wait for.
  --
  -- Sent unconditionally, and it cannot come back: the relay fans a message
  -- out to every member of the group **except its sender** (server/lib/relay.js
  -- and src/Hub.lua both skip `client.id`), so the host never receives its own
  -- `act` and the branch that files somebody else's action can never re-file
  -- this one on top of the copy going into `pending` below.
  if self.net then self.net.send({ t = "act", action = action }) end
  if self.host then
    self.pending[action.slot] = action
    return self:tryResolve()
  end
end

-- Everything the host is still waiting on, filled in for the slots nobody is
-- sitting at. An NPC's move is chosen here rather than on its "own" client
-- because there is no such client -- and choosing it anywhere but the host
-- would be a second opinion about what the same NPC did.
function M:tryResolve()
  if not self.host then return end
  -- Nobody takes a turn while a slot is still empty. The player choosing has
  -- nothing on the field to act with, and resolving around them would spend
  -- the other three's moves on a field that is about to change.
  if self.sim:awaitingChoice() then return end
  local actions = {}
  for _, slot in ipairs(self.sim.slots) do
    if not self.sim:isDown(slot) then
      if slot.owner == nil then
        local npc = self.sim:npcAction(slot)
        if npc then actions[#actions + 1] = npc end
      elseif self.pending[slot.index] then
        actions[#actions + 1] = self.pending[slot.index]
      else
        return -- still waiting on a human
      end
    end
  end

  self.pending = {}
  -- Any consent ask the host was holding belongs to the turn that is now over,
  -- and goes with it: an answer that arrives after this finds no ask behind it
  -- and is refused (see `hostRunAnswer`), which is precisely what "unanswered
  -- at the deadline counts as no" means on the authoritative side.
  self.runAsks = nil
  -- ------- and the deadline stops here, because the turn has been taken
  --
  -- `turnOpened` used to be disarmed only by *firing*, so it ran straight on
  -- through the messages phase -- and a batch of narration is not free: every
  -- line holds the box for at least 1.6 seconds, and a four-slot turn produces
  -- a dozen of them. Deliberation plus narration crossed 60 seconds routinely,
  -- and `autoPickLate` then filed a turn for players who had not been offered
  -- one, with "took too long!" against their names.
  --
  -- An idle host made it near-certain rather than merely likely: it never
  -- leaves the messages phase on its own, so the clock it holds was the one
  -- clock nothing was going to stop.
  --
  -- Cleared at the moment this commits to resolving, beside `pending` and for
  -- the same reason -- both belong to the turn that is now over. `openTurn`
  -- re-arms it at the handover, which is where a turn becomes decidable *to a
  -- player* rather than merely computable. (`autoPickLate` guards the phase
  -- itself as well; the two halves close the window from both ends.)
  self.turnOpened = nil
  self.owed = nil
  self.turnCount = (self.turnCount or 0) + 1
  -- The four monsters as the screen currently has them, held before the turn
  -- resolves. A monster that faints and is replaced inside `resolveTurn` --
  -- which is every NPC replacement, since there is nobody to pause for -- is
  -- gone from its slot by the time any of this is drawn, and this is the only
  -- moment it can still be caught. See M:holdDisplay.
  self:holdDisplay()
  local events = self.sim:resolveTurn(actions) or {}
  -- Whoever the clock picked for is named first, ahead of the turn their
  -- absence produced -- so the reason arrives before the consequence, and it
  -- arrives on all four clients rather than only on the one holding the clock.
  -- Cleared here whether or not there were any: a note that outlived its turn
  -- would blame somebody on the *next* one.
  if self.lateNotes then
    for i = #self.lateNotes, 1, -1 do
      table.insert(events, 1, self.lateNotes[i])
    end
    self.lateNotes = nil
  end
  -- A new turn is owed a new set of answers, so the old ones go with the
  -- turn they belonged to -- the same moment `pending` was emptied above.
  self.acted = nil
  -- Numbered, and stamped with what the field looks like afterwards.
  --
  -- A replayer applies HP straight out of these events, so a single lost
  -- message used to leave it showing numbers that were never true, forever,
  -- with nothing to notice it by. The sequence catches a message that never
  -- arrived; the signature catches the subtler case where they all arrived and
  -- the two copies still disagree.
  self.seq = (self.seq or 0) + 1
  if self.net then
    self.net.send({ t = "res", seq = self.seq,
                    sig = self.sim:signature(), events = events })
  end
  self:playEvents(events)
end

-- Apply a turn's events -- the host to its own screen, everybody else to
-- theirs. One function for both, which is what makes a replay and a simulation
-- land on the same screen rather than merely a similar one.
function M:playEvents(events)
  -- The first resolved turn is what takes the trainer's picture off the field,
  -- on every client rather than only the one that resolved it.
  self.turnCount = self.turnCount or 0

  -- ------- which monster a queued row belongs to
  --
  -- Every display row is queued against the battler *object* it is about, not
  -- against the slot it stands in. A slot's battler is replaced outright on a
  -- send-out (see `M:shownBattlerAt` for the whole story), so a row that named
  -- only the slot would be spent on whoever walked on next -- which is exactly
  -- what a same-turn NPC replacement produces.
  --
  -- `showing` answers "who is on screen in this slot at this point in the
  -- batch": the display shadow to begin with, and then whatever each `send`
  -- swaps in as the walk passes it. Rows queued before that `send` therefore
  -- hold the outgoing monster and rows queued after it hold the new one.
  -- `queuing` is per call, and the shadow it falls back to only advances when
  -- a queued `swap` row is finally consumed -- so between the two there is a
  -- window where neither has caught up: two batches played before the queue
  -- drained. The host reaches it on every forced replacement (`applyReplace`
  -- plays a batch and `tryResolve` can resolve the next turn in the same
  -- frame), and a replayer reaches it whenever two `res` arrive in one poll.
  -- Falling back to the shadow there answered with the *departed* monster, so
  -- the new turn's drain and faint rows were spent on a monster that is no
  -- longer on the field: a bar that never moves, and the wrong sprite sunk.
  --
  -- So the queue is asked first. The newest `swap` still waiting for this slot
  -- is what the screen will be showing by the time these rows come up, which
  -- is the question every caller is really asking.
  local queuing = {}
  local function showing(index)
    local held = queuing[index]
    if held ~= nil then return held end
    for i = #self.messages, 1, -1 do
      local row = self.messages[i]
      if type(row) == "table" and row.swap == index then return row.battler end
    end
    return self:shownBattlerAt(index)
  end

  for _, event in ipairs(events or {}) do
    if event.kind == "msg" then
      -- Carried with the line rather than applied now: the spotlight has to
      -- move when the message is *shown*, not when the turn is received, or
      -- all four moves would light up the last actor at once.
      self.messages[#self.messages + 1] =
        { text = event.text, from = event.from }
    elseif event.kind == "anim" then
      -- Queued alongside the messages rather than played now, so it arrives in
      -- the order the turn produced it rather than all at once at the end.
      self.messages[#self.messages + 1] =
        { anim = event.anim, from = event.from, to = event.to }
    elseif event.kind == "damage" then
      -- The replayers are told the resulting HP rather than the amount, so a
      -- dropped or reordered event cannot leave a bar drifting away from the
      -- host's.
      local slot = self.sim:slot(event.slot)
      if slot and slot.battler and not self.host then
        slot.battler.mon.hp = event.hp
      end
      -- The number above is the truth and it lands now. The *bar* is a queued
      -- row like any other, so it falls when its turn in the queue comes round
      -- rather than the moment the turn was received -- otherwise all four
      -- bars drop at once while the lines that explain them are still being
      -- read, which is the one thing the engine's 1v1 never does.
      --
      -- Queued on the host too. Its sim applied the HP during `resolveTurn`,
      -- long before any of this is shown, so the host needs the wait more than
      -- the replayers do, not less.
      --
      -- Queued for *every* damage event rather than only the ones with no
      -- drain row beside them: residual damage and a used item produce no
      -- drain row at all, and a row that asks a bar for where it already is
      -- costs a frame and does nothing.
      local shownAt = showing(event.slot)
      if shownAt then
        self.messages[#self.messages + 1] =
          { drain = shownAt, slot = event.slot, to = event.hp }
      end
    elseif event.kind == "drain" then
      -- One per strike, placed by the field in the engine's own queue order --
      -- after the hit animation, before the effectiveness line. It carries how
      -- far the bar may fall on *this* strike, which is what stops a multi-hit
      -- move draining straight to the post-last-hit HP and leaving the later
      -- strikes with nothing to animate.
      --
      -- No HP is applied here. Sim truth arrives only on `damage`, so a drain
      -- row that went missing costs an animation and never a number.
      local shownAt = showing(event.slot)
      if shownAt then
        self.messages[#self.messages + 1] =
          { drain = shownAt, slot = event.slot, to = event.to }
      end
    elseif event.kind == "faint" then
      -- ------- "this one is down", as a *drawing* fact, handed to the queue
      --
      -- `CoopField.onFaint` marks the battler the instant the move lands, and
      -- on the host that is inside `resolveTurn` -- before one frame of the
      -- turn has been shown. Drawing straight off that flag made the beaten
      -- monster vanish a second before the sink that exists to show it
      -- falling, and only on the host, so the four clients disagreed about
      -- what they had just watched.
      --
      -- So the flag is the display's from here on: cleared on the battler the
      -- row is queued against, and set again when that row comes up. Cleared
      -- *here* rather than in a pass over the whole batch beforehand, because
      -- the slot's own battler is no help -- on the host it may already be the
      -- replacement -- and `showing` is what knows which monster this faint is
      -- about. Nothing about the *rules* changes: `sim:isDown` is still what
      -- every rule reads, and it is untouched.
      --
      -- The sink is queued rather than played: the monster stands on the field
      -- until the row that fells it comes up, and the "fainted!" line is
      -- printed over the top of it -- the engine's own order, which emits the
      -- slide and the cry before the text (BattleState:enemyMonFainted).
      local shownAt = showing(event.slot)
      if shownAt then
        shownAt.fainted = nil
        self.messages[#self.messages + 1] =
          { faintfx = shownAt, slot = event.slot }
      end
    elseif event.kind == "choose" then
      -- Only its owner is asked; the other three watch an empty slot until it
      -- is filled.
      -- Marked on every client, not only the one being asked: a paused field
      -- is a fact about the battle, and the other three have to know it to say
      -- who they are waiting for rather than showing an empty box.
      local waiting = self.sim:slot(event.slot)
      if waiting then waiting.awaiting = true end
      if event.slot == self.mine then
        self.replacing = true
        self.switchIndex = 1
      else
        self:say((event.trainer or "They") .. " is choosing\nwho to send out...")
      end
    elseif event.kind == "exp" then
      self:gainExp(event)
    elseif event.kind == "learn" then
      self:learnMove(event)
    elseif event.kind == "send" then
      local slot = self.sim:slot(event.slot)
      -- Who was standing there, taken before the swap lands: the rows already
      -- queued for this slot are about that monster and nothing else.
      local leaving = showing(event.slot)
      -- Sim truth, applied *now* rather than in the queue: a replayer's
      -- signature has to match the host's the moment the event is applied.
      if slot and not self.host then self.sim:sendOut(slot, event.index) end
      -- ...and the *display* follows at its own pace. The outgoing monster is
      -- held in the shadow so it keeps being drawn -- and keeps draining and
      -- sinking -- while its rows play, and the new one is queued behind them
      -- as a swap row. Without this an NPC's monster that fell and was
      -- replaced inside the same resolved turn simply blinked out of
      -- existence: the replacement was on the field before the bar it emptied
      -- had moved a pixel.
      if slot then
        local shadow = self:displayShadow()
        shadow[event.slot] = leaving
        queuing[event.slot] = slot.battler
        self.messages[#self.messages + 1] =
          { swap = event.slot, battler = slot.battler }
      end
      -- The question has been answered -- and it may not have been answered by
      -- the player who was asked. When the clock runs out the host picks the
      -- next living reserve and sends this event like any other, so the picker
      -- has to close on the *event* rather than only on the button that
      -- normally causes it. Without this the slow player was left sitting in a
      -- bench list for a slot that was already filled, unable to take their
      -- next turn, and their eventual pick was dropped as a stale duplicate.
      if event.slot == self.mine and self.replacing then
        self.replacing = nil
        self.switchIndex = 1
      end
    elseif event.kind == "over" then
      self.result = self:resultFor(event.winner)
      -- The victory theme starts the moment the win is decided, not as the
      -- screen closes: it is what the defeat line and the trainer's parting
      -- line are read over, exactly as the engine queues it ahead of its own
      -- _TrainerDefeatedText. Playing it on the way out would sound the fanfare
      -- to an empty screen.
      self:playVictoryMusic()
      -- Why the rating did not move, said once.
      --
      -- Winning a 2-on-2 against a trainer pays everything a trainer battle
      -- pays -- exp, badges, prize money -- and no ranked points, because
      -- there is no opponent rating to be measured against. A player who is
      -- never told simply sees a number that did not change and concludes the
      -- ranking is broken. Said on a win only, because that is the moment they
      -- would look, and only once per session: a rule explained is a courtesy
      -- and a rule repeated after every fight is a nag.
      -- Once per save rather than once per process: `saidUnranked` is reset
      -- when a save is loaded (see Client), because a player who loads a
      -- different game is exactly the one who has not been told yet.
      if self.result == "win" and not self.ranksPoints and not M.saidUnranked then
        M.saidUnranked = true
        self:say("No points for a\n2-on-2 vs an NPC.")
        self:say("Battle players to\nclimb the ranks!")
      end
      -- What the trainer says on the way down. Printed here rather than left
      -- to the battle we displaced: that battle never runs its own end, so its
      -- text would never be said at all.
      if self.result == "win" and self.endBattleText then
        for page in (tostring(self.endBattleText) .. "\f"):gmatch("(.-)\f") do
          if page ~= "" then self:say(page) end
        end
      end
    end
  end
  -- ------- and every open menu closes here, on the events rather than a button
  --
  -- This is the replayer's half of the auto-pick. When the host's deadline
  -- fires it files an action for whoever was still deciding, and the turn comes
  -- back as an ordinary `res` -- so the client that was idle is sitting in a
  -- move list, or a target picker, for a turn that has already been taken.
  -- Setting the phase is what closes it (every picker is drawn and driven off
  -- `self.phase`), and it is set here for *every* batch, which is the same
  -- discipline the `send` branch above closes the bench picker with.
  --
  -- `replacing` is deliberately not touched: it outranks the phase, and the
  -- `send` branch is what clears it, on the event that answers it.
  self.phase = "messages"
  self.after = self.result and "over" or "choose"
  -- ...and any run consent still standing comes down with the same batch, on
  -- both ends of it. A turn that has been decided is a turn whose ask can no
  -- longer be answered: the asker's wait and the partner's prompt both belong
  -- to it, and this is the one event every client reaches. It is also what
  -- makes the deadline's answer to an unanswered ask "no" without a rule of its
  -- own -- the auto-picked turn arrives here like any other.
  self.runAsk = nil
  -- ...and the host's *record* of the asks dies in the same breath as the
  -- prompts they put on screen. Clearing it in `tryResolve` alone was not
  -- enough: a batch that plays without resolving a turn -- `applyReplace`'s
  -- forced send-out is one -- took every prompt down and left the record
  -- standing, which is exactly the state `hostRunAnswer`'s check exists to make
  -- unreachable: an ask no client is displaying, that a forged yes could still
  -- be accepted against.
  if self.host then self.runAsks = nil end
  -- Every turn starts on FIGHT.
  --
  -- The cursor used to keep whatever row was picked last, and that is a trap:
  -- land it on ITEM, empty the bag, and the menu opens an empty list, bounces
  -- straight back and opens it again -- a visible flicker and a turn that
  -- never resolves, because nothing was ever committed. Starting on the one
  -- command that can always be actioned makes that unreachable.
  --
  -- The move and target cursors go back with it, for the same reason and for
  -- one more: a client whose picker was closed by an auto-picked turn would
  -- otherwise re-open next turn still pointing at half of a decision that was
  -- taken out of its hands.
  self.commandIndex = 1
  self.moveIndex = 1
  self.targetIndex = 1
end

function M:resultFor(winner)
  if winner == "draw" then return "draw" end
  local slot = self:mySlot()
  if slot and slot.side == winner then return "win" end
  return "loss"
end

-- ------- the bar falling, and the monster after it
--
-- Two blocking states, both of them the engine's own, both of them living
-- entirely on the display side: `mon.hp` is the sim's and is applied where it
-- always was, and `battler.shownHP` is the number the bar is drawn from. The
-- gap between the two *is* the animation.
--
-- Neither is skippable. The engine reads a button only for a text page that
-- has finished printing -- a draining bar and a sinking monster are held by
-- the queue itself -- so there is deliberately no input here to find.

-- The fall, in frames and pixels per frame: pokered's AnimationSlideMonDown,
-- which the engine's own battle screen counts down the same way.
local FAINT_FRAMES = 30
local FAINT_STEP = 2

-- A queued drain row comes up: start it, or answer it on the spot.
--
-- `makeBattler` seeds `shownHP` from the mon's HP, so it is there for every
-- battler this screen ever draws. A missing one is a battler built by
-- something that did not, and the safe answer is the true number rather than
-- an invented descent from one -- `mon.hp` has already moved by the time this
-- runs, so there is nothing left to work the starting point back out of.
--
-- The row carries the battler itself rather than a slot to look one up in, so
-- a bar that was queued for the monster that has since left still falls on
-- that monster -- see `M:shownBattlerAt`.
-- `to` is clamped, and that is a wire rule rather than a tidiness one. It
-- arrives inside a `res` from the host, `stepDrain` stops on exact equality,
-- and a drain is deliberately unskippable -- so a NaN, an infinity or a plain
-- 1e9 is a stop condition that never comes true and a message queue that never
-- moves again, for one client, from one corrupt or forged number. Held to what
-- a bar can actually show: nothing below empty, nothing above this monster's
-- maximum. NaN is refused outright, because it compares false against every
-- bound there is.
function M:startDrain(row)
  local battler = row.drain
  local to = tonumber(row.to)
  if not (type(battler) == "table" and battler.mon and to) then return false end
  if to ~= to then return false end
  local max = tonumber(battler.mon.stats and battler.mon.stats.hp) or 0
  to = math.max(0, math.min(max, to))
  if battler.shownHP == nil then
    battler.shownHP = to
    return false
  end
  if battler.shownHP == to then return false end
  -- The budget is the second half of the same guard, and it covers what a
  -- clamp cannot: the bar moves by a *rate*, so a step small enough to lose
  -- its last fraction to floating point would never reach `to` exactly. 96
  -- frames is the whole descent (see the rate below); the slack is there so an
  -- ordinary drain never meets this at all, and one that does is snapped to
  -- where it was going rather than left holding the queue.
  self.draining = { battler = battler, slot = row.slot, to = to, frames = 120 }
  return true
end

-- One frame of it. `maxHP / 96` per frame is the engine's rate, and it is a
-- rate rather than a duration for a reason: the bar is 48 pixels and moves one
-- pixel every two frames whatever the monster's HP, so a 20 HP magikarp and a
-- 300 HP snorlax take the same second and a half to empty.
function M:stepDrain()
  local at = self.draining
  local battler = at.battler
  if not (battler and battler.mon) then
    self.draining = nil
    return
  end
  -- Out of frames: the bar has had longer than a full descent and still has
  -- not landed on `to`, so it is put there. A drain has no button to escape it
  -- by, so the only other end to this is a queue that never moves again.
  at.frames = (at.frames or 120) - 1
  if at.frames <= 0 then
    battler.shownHP = at.to
    self.draining = nil
    return
  end
  local shown = battler.shownHP or at.to
  local max = (battler.mon.stats and battler.mon.stats.hp) or 1
  local step = math.max(1, max) / 96
  if shown > at.to then
    shown = math.max(at.to, shown - step)
  else
    shown = math.min(at.to, shown + step)
  end
  battler.shownHP = shown
  if shown == at.to then self.draining = nil end
end

-- The fall. The flag goes up *before* the text, which is the engine's order
-- (BattleState:enemyMonFainted queues the slide and the cry, then says the
-- line): the sprite is sliding out of its box while the box says why.
function M:startFaint(row)
  local battler = row.faintfx
  if type(battler) ~= "table" then return false end
  battler.fainted = true
  self.faintFx = { battler = battler, slot = row.slot, frames = FAINT_FRAMES }
  return true
end

function M:stepFaint()
  local fx = self.faintFx
  fx.frames = (fx.frames or 0) - 1
  if fx.frames <= 0 then self.faintFx = nil end
end

-- Is this slot the one currently sinking?
function M:sinkingAt(index)
  local fx = self.faintFx
  if fx and fx.slot == index and (fx.frames or 0) > 0 then return fx end
  return nil
end

-- ------- the monster on screen, which is not always the monster in the slot
--
-- A send-out **replaces** `slot.battler` with a different object rather than
-- editing the one that was there, and it lands as sim truth the instant the
-- `send` event is applied -- it has to, because a replayer's signature must
-- match the host's from that moment. The display cannot move that fast: the
-- monster that just left is still owed its exit, the bar draining to zero and
-- the thirty-frame sink.
--
-- The two are told apart by a shadow. `shownBattler[i]` is the battler the
-- screen is still drawing for slot `i`; the slot's own battler is what the
-- rules are being applied to. They differ for exactly as long as the queued
-- rows for the departed monster take to play, and a `swap` row -- queued
-- behind those rows by the `send` branch -- is what finally puts them back in
-- step.
--
-- This is what the earlier `dropDisplayFor` got wrong, and it is the bug this
-- whole screen's exit sequencing exists for: it *purged* the dying monster's
-- rows instead of playing them, so an NPC's monster -- whose replacement is
-- sent out inside the same resolved turn, with no player to pause for --
-- vanished mid-drain and the next one appeared in its place with no fall in
-- between. A human's replacement never showed the bug, because the `choose`
-- pause holds the turn open until the player answers and the rows have long
-- since played by then.
--
-- Lazily built, and every reader tolerates its absence: the suite builds
-- clients straight out of `setmetatable` without one.
function M:displayShadow()
  self.shownBattler = self.shownBattler or {}
  return self.shownBattler
end

-- The battler slot `index` is *drawn* from: the shadow if one is being held,
-- and otherwise the slot's own, which is the answer whenever the display and
-- the field agree -- which is nearly always.
function M:shownBattlerAt(index)
  local shadow = self.shownBattler
  local held = shadow and shadow[index]
  if held then return held end
  local slot = self.sim and self.sim:slot(index)
  return slot and slot.battler or nil
end

-- A queued swap coming up: the departed monster's rows have all played, so the
-- screen may finally show what the field has shown since the `send` landed.
function M:applySwap(row)
  self:displayShadow()[row.swap] = row.battler
end

-- Hold what is on screen now, before the sim is asked to move.
--
-- Only the host needs this, and it needs it because it is the one client whose
-- `slot.battler` has already moved on by the time `playEvents` runs: it
-- simulates the turn first and shows it afterwards, so a monster that fainted
-- and was replaced inside `resolveTurn` is unreachable from the slot by then.
-- Taken before the turn resolves, the shadow still points at it -- which is
-- what lets the host queue that monster's drain and sink against the right
-- object and watch the same exit everybody else watches.
function M:holdDisplay()
  if not self.sim then return end
  local shadow = self:displayShadow()
  for _, slot in ipairs(self.sim.slots or {}) do
    if shadow[slot.index] == nil then shadow[slot.index] = slot.battler end
  end
end

-- Put every bar where its monster actually is, and stop animating.
--
-- The snap points are the three moments where an animation half-played would
-- be a lie rather than a lag: handing the turn back to a menu, being re-synced
-- by the host (the numbers just changed underneath the display), and leaving
-- the screen. Everywhere else the gap between `shownHP` and `mon.hp` is the
-- whole point.
function M:snapDisplay()
  self.draining = nil
  self.faintFx = nil
  -- The shadow goes with them. Nothing is owed an exit any more, so every slot
  -- draws the monster the field says is standing in it -- which is the safety
  -- net for a swap row that never arrived, and the reason a resync puts the
  -- screen right in one step.
  --
  -- Any queued *display* row goes with them -- swap, drain and sink alike --
  -- and it has to: a resync rebuilds every battler, so a swap row left in the
  -- queue would put a monster the field no longer holds back on screen some
  -- seconds after the display was told the truth, and a drain or a faint row
  -- left beside it would fire against the *new* field -- a bar walked back
  -- down to a number nobody holds any more, or a healthy monster sinking off
  -- its square. Nothing is lost by dropping them: the snap has already shown
  -- everything they were going to show.
  --
  -- Text and animation rows stay. They are bounded, they say what happened
  -- rather than change what is drawn, and cutting a player's last few lines
  -- off mid-sentence is a worse lie than reading them a moment late.
  self.shownBattler = {}
  local kept = {}
  for _, row in ipairs(self.messages or {}) do
    if not (type(row) == "table"
            and (row.swap or row.drain or row.faintfx)) then
      kept[#kept + 1] = row
    end
  end
  self.messages = kept
  if not self.sim then return end
  for _, slot in ipairs(self.sim.slots or {}) do
    local battler = slot.battler
    if battler and battler.mon then
      battler.shownHP = battler.mon.hp
      battler.fainted = self.sim:isDown(slot) or nil
    end
  end
end

function M:finish()
  if self.finished then return end
  self.finished = true
  self:snapDisplay()
  self.game.stack:pop()
end

-- The field, laid out the way the modern games lay a double battle out --
-- inside a screen a third of their width.
--
-- **The constraint first, because it decides everything else.** A Gen 1 battle
-- pic is 56x56. Four of them plus four status readouts plus a six-row message
-- box do not fit in 160x144 -- not staggered, not overlapped, not anywhere.
-- The first version of this screen pretended otherwise and the result was the
-- ally half of the field drawn underneath the command box: two garbled strips
-- where CHARIZARD and PIKACHU should have been, and their pictures invisible
-- behind it.
--
-- So the pics are drawn at half scale. That is the one lever that makes the
-- whole thing fit, and it is spent deliberately: **half is an integer scale**,
-- so a 56x56 pic lands on 28x28 with every pixel doubled down cleanly rather
-- than resampled into mush -- which is what any of 0.6, 0.75 or "fit to box"
-- would have done to art drawn for one exact size.
--
-- What that buys is the modern arrangement:
--
--   * four monsters visible at once, staggered diagonally so the pair on each
--     side reads as two things at different depths rather than one wide smear;
--   * the foes' two status readouts stacked in the top-left, away from their
--     pictures, and the allies' two stacked in the bottom-right, away from
--     theirs -- which is where Gen 3 puts them;
--   * a full-width message and command box in its usual place.
--
-- Every glyph, box and HP bar is still the engine's own (Font, HudTiles), so a
-- palette or asset mod owns the look of this exactly as it owns a wild battle.

-- Real size. Nothing is scaled.
local PIC_SCALE = 1

-- ...except the far side, a little.
--
-- Two 56-pixel pics in the 72 each pair is given means a pair overlaps itself,
-- and the foes' pair is the one that suffers for it: it sits at the top of the
-- screen with the trainer's panel beside it, so the overlap reads as one shape
-- rather than two monsters. Fifteen percent off is enough to open a gap between
-- them and to say "those two are further away", and it is small enough that the
-- art is still recognisably itself -- which a half-scale foe would not be.
--
-- **Baselines hold.** A sprite is anchored at its top-left, so scaling it in
-- place lifts its feet off the ground; every draw below therefore pushes it
-- back down by the height it lost and in by half the width, and the monster
-- stands exactly where it stood.
local FOE_SCALE = 0.85

-- Published for the suite, which cannot reach a file-local and has no graphics
-- device to measure a drawn pixel with.
M.FOE_SCALE = FOE_SCALE

-- The Gen 3 double-battle arrangement: each side's readouts and each side's
-- monsters sit on *opposite* diagonals.
--
--   [foe 1 name + bar]
--   [foe 2 name + bar]          foe1 foe2
--
--   ally1 ally2                 [ally 1 name + bar]
--                               [ally 2 name + bar]
--
-- This is what buys the diagonal that a single row could not. The screen above
-- the command box is two 48-pixel halves; in each half the panel takes one
-- side and the monsters the other, so nothing is drawn over anything and the
-- two pairs still sit on a genuine diagonal, bottom-left to top-right.
--
-- Two 56-pixel pics do not fit the 72 each pair is given, so a pair overlaps
-- itself. That is deliberate -- which of the two is in front is the turn
-- indicator (see M:spotlight) -- and it is why real size costs nothing here.
-- x starts at 2, not 0: at 0 the screen border shaves the first column off,
-- which is what clipped CHARIZARD's left side. y drops the pair clear of the
-- foes' panel above them.
-- Pushed out into the space each pair actually has.
--
-- A Gen 1 battle pic carries several rows and columns of transparent border,
-- so a pair placed by its *bounding boxes* leaves a visible gap at the edges
-- and looks huddled in the middle of its quarter. These are placed by where
-- the monsters read: your pair sits low, close to the command box, and theirs
-- spreads right into the corner. The pairs also stand further apart than the
-- minimum, so each of the two is legible rather than one hiding the other.
-- Clear of the panels, not merely near them.
--
-- The panels are drawn *after* the monsters, so anything that strays under one
-- is cut off by it -- which is what sliced WEEDLE's left side: their pair
-- started at 84 and the foes' panel runs to 88. Their pair now starts past the
-- panel edge and spreads into the corner; yours sits low and right, as far
-- into its quarter as the readouts beside it allow.
local SLOT_POS = {
  [1] = { x = 8,   y = 58 },   -- yours, bottom-left
  [2] = { x = 30,  y = 58 },
  [3] = { x = 92,  y = 2 },    -- theirs, top-right
  [4] = { x = 110, y = 2 },
}

-- Back to front: the second of each pair is drawn first so the first sits in
-- front of it, matching the order of the readouts beside them.
local DEPTH_ORDER = { 4, 3, 2, 1 }

-- Half the screen wide, six tiles tall: two readouts of two rows each (a name
-- row and a bar row -- the engine's HP bar is a full row and will not fit
-- beside a name at this width) plus the border.
-- The two panels are sized differently on purpose.
--
-- Yours is twelve tiles because it has to hold a nine-glyph name -- eleven
-- shipped CHARIZAR. Theirs is eleven, because every pixel it gives back is a
-- pixel their pair can occupy without being sliced by it, and an eight-glyph
-- cap costs the enemy side far less than a monster with its head cut off.
local FOE_PANEL = { tx = 0, ty = 0, tw = 11, th = 6 }
local ALLY_PANEL = { tx = 8, ty = 6, tw = 12, th = 6 }
local PANEL_SLOTS = { [1] = { 3, 4 }, [2] = { 1, 2 } }

-- The HP the *readout* shows, which trails `mon.hp` while a drain plays.
--
-- Rounded the engine's way (BattleState's own `shownHP` helper): a bar on its
-- way down rounds up and one on its way up rounds down, so the number always
-- lags the animation by less than a point rather than reaching the
-- destination before the bar does. The HUD ticks in whole HP either way.
local function displayHP(battler)
  local shown = battler.shownHP
  local truth = battler.mon.hp or 0
  if shown == nil then return truth end
  if shown > truth then return math.ceil(shown) end
  return math.floor(shown)
end

-- Whether a slot has anything to draw, which is not the same question as
-- whether it is still in the fight.
--
-- `sim:isDown` answers the rules' question and answers it the instant the HP
-- reaches zero -- which on the host is inside `resolveTurn`, before any of the
-- turn has been shown. The display's answer is the flag the faint row sets, so
-- a monster stays on the field until the queue gets round to felling it.
--
-- Asked about a battler rather than about a slot, because the two part company
-- while a departed monster is still being shown out (M:shownBattlerAt).
local function hidden(slot, battler)
  if not slot or slot.gone then return true end
  return battler == nil or battler.fainted == true
end

-- A monster on its way off the field.
--
-- pokered's AnimationSlideMonDown, and it is a *clip* rather than a slide: the
-- pic sinks two pixels a frame and the rows that pass the baseline are cut
-- off, so it disappears behind its own square instead of walking down the
-- screen over whatever is drawn below it -- which at four slots is another
-- player's monster.
local function drawSinking(sprite, x, y, framesLeft, scale)
  scale = scale or PIC_SCALE
  local sw, sh = sprite:getDimensions()
  local offset = (FAINT_FRAMES - framesLeft) * FAINT_STEP
  -- The offset is in *screen* pixels and the quad is cut in *sprite* pixels,
  -- so the clip has to be divided back through the draw scale or the pic would
  -- be cut faster than it sinks and vanish early. The divisor is the scale this
  -- sprite is actually drawn at rather than PIC_SCALE: a foe draws at
  -- FOE_SCALE, and dividing its clip by 1 sank it through its own feet a
  -- sixth too fast -- the pic vanishing before the thirty frames were up.
  local visible = sh - math.floor(offset / scale)
  if visible <= 0 then return end
  local quad = love.graphics.newQuad(0, 0, sw, visible, sw, sh)
  love.graphics.draw(sprite, quad, x, y + offset, 0, scale, scale)
end

-- ------- the status abbreviation, on the name row
--
-- SLP, PAR, BRN, PSN, FRZ -- the three-letter forms the engine's own HUD prints,
-- through the ordinary font, which is why `Font.draw` is all this needs.
--
-- **This is the original bug report.** A monster put to sleep loses its turn in
-- silence between two batches of messages: the line that said so scrolled past
-- some seconds ago, nothing on screen carries it, and a player watching their
-- monster do nothing for three turns running has no way to tell an enforced
-- sleep from a battle that has broken. Four monsters make it worse, not better
-- -- there is four times as much narration for the one line that mattered to
-- get lost in.
--
-- Read straight off `mon.status`, which is the id: a build that adds a status
-- gets its own id shown rather than a blank, cut to three so a long one cannot
-- push the bar off the panel.
local function statusTag(battler)
  local mon = battler and battler.mon
  local status = mon and mon.status
  if type(status) ~= "string" or status == "" then return nil end
  return status:sub(1, 3)
end

local function drawReadout(self, battler, panel, row, mine)
  local Font, HudTiles = engine.Font, engine.HudTiles
  if not battler or not battler.mon then return end
  local tx = panel.tx + 1
  local ty = panel.ty + row
  love.graphics.setColor(0, 0, 0, 1)
  if mine then Font.drawCode(0xED, tx * 8, ty * 8) end
  -- ------- what the row spends its columns on
  --
  -- Cut to the panel's real inner width rather than a written-down number, so
  -- resizing one never leaves a stale cap behind -- and the status takes its
  -- four columns (" SLP") out of the *name's* budget rather than out of the
  -- panel, so the row is exactly as wide as it always was. A healthy monster
  -- gets every column back, which is the common case and the one the eleven-
  -- and twelve-tile panel widths were chosen for.
  --
  -- Drawn at the end of the reserved space rather than after the name, so the
  -- badge sits in the same column on both rows of a panel instead of jittering
  -- with the length of whoever is standing there.
  local budget = panel.tw - 3
  local status = statusTag(battler)
  if status then budget = budget - 4 end
  Font.draw(tostring(battler.name or "?"):sub(1, budget), tx * 8 + 8, ty * 8)
  if status then
    Font.draw(" " .. status, (tx + 1 + budget) * 8, ty * 8)
  end
  local hp = displayHP(battler)
  local ok = pcall(HudTiles.drawHPBar, self.game.data, tx, ty + 1,
    { hp = hp, stats = battler.mon.stats },
    nil, false, panel.tw - 4)
  if not ok then
    Font.draw(("%d/%d"):format(hp,
      (battler.mon.stats and battler.mon.stats.hp) or 0), tx * 8, (ty + 1) * 8)
  end
end

function M:drawPanel(panel, which)
  local Font = engine.Font
  local rows = PANEL_SLOTS[which]
  local any = false
  for _, index in ipairs(rows) do
    if not hidden(self.sim:slot(index), self:shownBattlerAt(index)) then
      any = true
    end
  end
  if not any then return end
  Font.drawBox(panel.tx, panel.ty, panel.tw, panel.th)
  for i, index in ipairs(rows) do
    local battler = self:shownBattlerAt(index)
    if not hidden(self.sim:slot(index), battler) then
      drawReadout(self, battler, panel, (i - 1) * 2 + 1, index == self.mine)
    end
  end
end

-- Whose turn it is, as a drawing question.
--
-- The two monsters in a pair overlap, so "which one is in front" is a free
-- channel, and the useful thing to spend it on is who is acting: the slot
-- being narrated is lifted to the top and everything else keeps its depth.
-- Falls back to your own monster, which is right while you are the one being
-- asked to choose.
function M:spotlight()
  return self.acting or self.mine
end

-- Whether the trainer is still standing where their monsters will be. Held
-- through the opening lines and gone the moment anybody is asked to choose --
-- the original scrolls the picture off before the first menu, and a picture
-- that outstays that reads as a rendering fault rather than an entrance.
function M:showingTrainer()
  return self.trainerPic ~= nil and (self.turnCount or 0) == 0
    and self.phase == "messages"
end

-- Is this slot on the other side of the field from mine?
--
-- **Viewer-relative, and deliberately nothing to do with the layout.** "foe"
-- here means one thing: not side "b", not the NPC's -- the side that is not the
-- side my own slot stands on. It is what a *label* should answer to.
--
-- It is emphatically **not** what the layout is keyed off. `SLOT_POS` and
-- `PANEL_SLOTS` are index-fixed constants -- 1 and 2 are the bottom-left pair
-- with the bottom-right panel, 3 and 4 the top-right pair with the top-left one
-- -- and they are the same on all four clients. A comment here used to claim
-- `PANEL_SLOTS` was keyed off this test; it never was, and anything that
-- believed it drew the far side's decoration over the near side's monsters for
-- the two players sitting in slots 3 and 4. See `M:scaleFor`.
function M:foeSide(index)
  local ours = self.sim and self.sim:slot(self.mine)
  ours = ours and ours.side
  local slot = self.sim and self.sim:slot(index)
  return (slot ~= nil and ours ~= nil and slot.side ~= ours) and true or false
end

-- How big slot `index` draws. Its own function so the suite can ask without a
-- graphics device -- see FOE_SCALE for why the far pair is smaller.
--
-- ------- keyed off the **layout**, not off who is reading the screen
--
-- This used to ask `foeSide`, and that was a category error with a visible
-- consequence. FOE_SCALE exists for one reason: slots 3 and 4 sit in the 72
-- pixels at the top of the screen with the foes' panel beside them, and two
-- 56-pixel pics in that space read as one shape unless the far pair is opened
-- up a little. That is a fact about `SLOT_POS`, which is an index-fixed
-- constant identical on all four clients.
--
-- `foeSide` is viewer-relative. In a party battle the two players sitting in
-- slots 3 and 4 are on the far side of *nobody's* screen but their opponents',
-- so asking it shrank whichever pair the reader was not in -- which for half
-- the table was their own pair, drawn small in the bottom-left where there is
-- room for it at full size, while the opposition stood full size in the corner
-- the shrink exists to unclutter. Both halves wrong, and only for the clients
-- nobody tests from.
function M:scaleFor(index)
  if index == 3 or index == 4 then return FOE_SCALE end
  return PIC_SCALE
end

-- ------- where slot `index` actually lands, in screen pixels
--
-- **One anchor, three callers.** The pic itself, the target picker's cursor and
-- the animation translation are all in the same space, and until now only the
-- pic knew about it: `drawField` worked the shrink offsets out inline while
-- `drawTarget` and `animOffset` used raw `SLOT_POS`. The two of them therefore
-- pointed four to eight pixels above and to the left of the foe they were about
-- -- the exact size of the FOE_SCALE offsets, which is the tell.
--
-- The rule, which is FOE_SCALE's own promise kept: a sprite is anchored at its
-- top-left, so scaling it in place would lift its feet off the ground. Pushing
-- it back down by the height it lost and in by half the width it lost leaves
-- its feet and its centre line exactly where a full-size pic had them.
--
-- Returns `x, y, scale`, or nil for a slot with no position. A sprite that
-- cannot be measured -- or one that was not handed in at all -- falls back to
-- PIC_SCALE and the raw position rather than to offsets nobody can compute,
-- which is what `drawField` has always done. The measurement is behind a pcall
-- for the same reason every other sprite call on this screen is.
function M:picOriginFor(index, sprite)
  local at = SLOT_POS[index]
  if not at then return nil end
  local scale, x, y = self:scaleFor(index), at.x, at.y
  if scale ~= PIC_SCALE then
    local sw, sh
    if sprite then
      local ok, w, h = pcall(sprite.getDimensions, sprite)
      if ok then sw, sh = w, h end
    end
    if sw and sh then
      x = x + (1 - scale) * sw / 2
      y = y + (1 - scale) * sh
    else
      scale = PIC_SCALE
    end
  end
  return x, y, scale
end

-- ------- back to front, and what outranks what
--
-- Three claims on "who is in front", in order:
--
--   1. the **hovered target**, while the target picker is open. It is the one
--      question on this screen whose answer is a monster on the field, and two
--      overlapping foes are exactly when a name in a list is not enough -- so
--      the one about to be hit comes clear of the other while the cursor is on
--      it. Outranks the spotlight because the spotlight is nobody's during a
--      pick: it falls back to your own monster, which is not what is being
--      chosen between.
--   2. the **spotlight**, whoever is being narrated (M:spotlight).
--   3. `DEPTH_ORDER`, the resting arrangement.
--
-- Returned as a list so it can be asserted against without drawing anything.
function M:paintOrder()
  local top = self:spotlight()
  if self.phase == "target" and self.sim then
    local mine = self:mySlot()
    local targets = mine and self.sim:targetsFor(mine) or {}
    local hovered = targets[self.targetIndex or 1]
    if hovered then top = hovered.index end
  end
  local order = {}
  for _, index in ipairs(DEPTH_ORDER) do
    if index ~= top then order[#order + 1] = index end
  end
  order[#order + 1] = top
  return order
end

function M:drawField()
  -- Their side is the trainer until the trainer leaves. Drawing both puts a
  -- WEEDLE through the sprite's chest.
  local hideFoes = self:showingTrainer()

  for _, index in ipairs(self:paintOrder()) do
    local slot = self.sim:slot(index)
    -- What is on *screen* in this slot, which is the monster still being shown
    -- out whenever one is -- not necessarily the one the field says is
    -- standing there (M:shownBattlerAt).
    local battler = self:shownBattlerAt(index)
    local theirs = self:foeSide(index)
    local sinking = self:sinkingAt(index)
    -- A sink is drawn from the battler its own row captured, so a slot whose
    -- replacement has already landed still sinks the monster that fell.
    local sprite = (sinking and sinking.battler and sinking.battler.sprite)
      or (battler and battler.sprite)
    -- Where this pic actually lands, at whatever scale its position draws at --
    -- worked out by the one function the cursor and the animations also ask,
    -- so all three agree to the pixel (M:picOriginFor).
    local x, y, scale = self:picOriginFor(index, sprite)
    if sprite and x and not (hideFoes and theirs) then
      if sinking then
        love.graphics.setColor(1, 1, 1, 1)
        -- Behind a pcall for the reason the HP bar is: a sprite with
        -- dimensions this cannot quad is a monster missing from the field for
        -- one frame, not a battle that stops for four people.
        pcall(drawSinking, sprite, x, y, sinking.frames, scale)
      elseif not hidden(slot, battler) then
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.draw(sprite, x, y, 0, scale, scale)
      end
    end
  end
  self:drawPanel(FOE_PANEL, 1)
  self:drawPanel(ALLY_PANEL, 2)
end

-- This screen resolves its own colours.
--
-- Every pixel on it is already palette-correct: the pictures come out of the
-- engine's cache with their species palette applied, and the boxes and glyphs
-- are the engine's own. So the colourising display modes are told to leave the
-- surface alone rather than remap what is already right -- the same opt-out
-- WideBattle takes. Without it the same battle renders differently from one
-- instance to the next depending on which display mode each player picked,
-- which is exactly what two side-by-side clients showed.
function M:zones()
  return { { colors = false, x = 0, y = 0, w = 160, h = 144 } }
end

-- ------- animations
--
-- The engine authors every battle animation against the classic layout: one
-- player pic low-left, one enemy pic high-right. Four monsters means four
-- anchors, so each frame is translated by the distance between the anchor it
-- was drawn for and the slot that actually acted.
--
-- Rigid, whole-frame translation and never a scale, for the reason WideBattle
-- gives when it does the same thing: an animation is a set of OAM sprites laid
-- out relative to each other, and moving them apart individually pulls it to
-- pieces.

-- Where the classic layout puts the two pics an animation was authored around.
local CLASSIC_PLAYER = { x = 8, y = 40 }
local CLASSIC_ENEMY = { x = 88, y = 0 }

function M:startAnim(row)
  self.anim = row
  if not (self.animPlayer and self.animPlayer.start) then
    -- No animation data in this build: the flash is skipped and the messages
    -- carry on, which is the degrade the header promises.
    self.anim = nil
    return false
  end
  local slot = self.sim:slot(row.from)
  local ok = pcall(self.animPlayer.start, self.animPlayer, row.anim,
                   slot and slot.side == "a")
  if not ok then self.anim = nil end
  return ok
end

-- How far to shift this animation so it lands on the slot that acted.
--
-- Measured to the pic's *drawn* origin rather than to its raw `SLOT_POS`, so a
-- slot that draws at FOE_SCALE has its flash land on the monster rather than
-- four to eight pixels above and left of it (M:picOriginFor). The sprite is
-- looked up for the same reason the pic does: the offsets depend on how big it
-- is, and only it can say.
function M:animOffset(row)
  local index = row and row.from
  if not index then return 0, 0 end
  local battler = self:shownBattlerAt(index)
  local x, y = self:picOriginFor(index, battler and battler.sprite)
  if not x then return 0, 0 end
  local slot = self.sim and self.sim:slot(index)
  local from = (slot and slot.side == "a") and CLASSIC_PLAYER or CLASSIC_ENEMY
  return x - from.x, y - from.y
end

function M:drawAnim()
  local row = self.anim
  if not (row and self.animPlayer and self.animPlayer.draw) then return end
  local dx, dy = self:animOffset(row)
  love.graphics.push()
  love.graphics.translate(dx, dy)
  pcall(self.animPlayer.draw, self.animPlayer)
  love.graphics.pop()
end

-- ------- exp
--
-- Applied only to *your* monster, on your own client, for the reason the whole
-- co-op design keeps running into: the host resolves every slot but holds the
-- real party for only one of them. Every client sees every exp event; three of
-- them ignore each one.
--
-- The host does not send a number to add. It sends what was beaten and how
-- many shared in beating it, and each client prices that for itself through
-- the engine's own Experience.apply -- which is also what divides the stat
-- exp, raises the stats and decides whether a level was crossed. Applying a
-- host-computed number instead would skip all three.
function M:gainExp(event)
  if event.slot ~= self.mine then return end
  local slot = self.sim:slot(self.mine)
  local mon = slot and slot.battler and slot.battler.mon
  local eng = engine
  local def = mon and event.species and (self.game.data.pokemon or {})[event.species]
  if not (mon and def and eng and eng.Experience) then return end

  -- EXP.ALL, the way the original splits it: the monster that fought takes
  -- half, and the other half is divided again across the whole living party.
  -- The engine expresses that as a *divisor* rather than a fraction, so
  -- holding one doubles the divisor on the first pass and the second pass
  -- divides by the party size on top.
  local save = self.game.save
  local expAll = save and save.inventory and (save.inventory.EXP_ALL or 0) > 0
  local party = (save and save.party) or {}

  -- Everyone still standing on the winning side shares it, exactly as the
  -- engine divides a solo battle between its own participants -- so a co-op
  -- knockout is worth half each, not full each. Holding an EXP.ALL doubles
  -- the divisor: that is how the original expresses "half now, half spread".
  local winners = math.max(1, tonumber(event.winners) or 1)

  mon.statExp = mon.statExp or {}
  mon.exp = mon.exp or 0
  local ok, levels, gained = pcall(eng.Experience.apply, self.game.data, mon,
    def, event.level or 1, true, winners * (expAll and 2 or 1), false)
  if not ok then return end

  self:say((mon.nickname or slot.battler.name or "?")
    .. " gained\n" .. tostring(gained or 0) .. " EXP. Points!")
  self:levelled(mon, slot.battler.name, levels)

  -- A level raises both HP numbers, and the bar has to be told.
  --
  -- `Experience.apply` runs the moment the event is received, so max HP and
  -- current HP move mid-queue while `shownHP` stays where the last drain left
  -- it -- and a bar drawn from an old number against a new denominator is a
  -- bar that visibly *shrinks* on the level-up, and stays wrong until the next
  -- snap. So the climb is queued like any other bar movement and animates
  -- upward, which is what the engine's own level-up does (gen1recomp #224).
  -- Queued after the level lines above, so it plays under them. Guarded on
  -- the battler and on the queue itself, because every other line here goes
  -- out through `say` and a caller that stubs `say` has neither.
  if slot.battler and self.messages then
    self.messages[#self.messages + 1] =
      { drain = slot.battler, slot = event.slot, to = mon.hp }
  end

  -- ...and the other half, spread over everyone still standing -- including
  -- the monster that fought, exactly as the original's second pass does.
  -- Fainted party members are skipped, and no "gained EXP" line is printed for
  -- any of them: the original prints only what a level-up produces.
  if expAll then
    for _, member in ipairs(party) do
      if (member.hp or 0) > 0 then
        member.statExp = member.statExp or {}
        member.exp = member.exp or 0
        local gotOk, gotLevels = pcall(eng.Experience.apply, self.game.data,
          member, def, event.level or 1, true,
          winners * 2 * math.max(1, #party), false)
        if gotOk then self:levelled(member, nil, gotLevels) end
      end
    end
  end
end

-- What a level-up costs, wherever it happened: a line, whatever moves come
-- with the level, and a note for the evolution check the displaced battle
-- runs on the way out. A party member that levelled on EXP.ALL still evolves
-- and still learns, though it never left its ball.
function M:levelled(mon, fallbackName, levels)
  if not (levels and #levels > 0) then return end
  local eng = engine
  local def = (self.game.data.pokemon or {})[mon.species]
  local name = mon.nickname or fallbackName or (def and def.name) or "?"
  for _, newLevel in ipairs(levels) do
    self:say(name .. " grew to\nlevel " .. tostring(newLevel) .. "!")
    -- Levelled here, so the moves it learns are decided here too -- the host
    -- cannot know, because it is not the copy that gained the level.
    local moves = eng and eng.Experience and eng.Experience.movesLearnedAt
      and select(2, pcall(eng.Experience.movesLearnedAt, def, newLevel))
    for _, moveId in ipairs(moves or {}) do
      self:teach(mon, name, moveId)
    end
  end
  self.leveledUp = self.leveledUp or {}
  self.leveledUp[mon] = true
end

-- ------- learning a move
--
-- Applied only to *your* monster, on your own client, because only there is it
-- the live party entry that the save keeps. Every client sees the event; three
-- of them ignore it.
--
-- With a free slot the move is simply learned. With four already known there
-- is a choice to make, and it needs a screen -- so it is remembered and put to
-- the player once the battle is over rather than opened on top of a battle
-- three other people are still fighting.
function M:learnMove(event)
  if event.slot ~= self.mine then return end
  local slot = self.sim:slot(self.mine)
  local mon = slot and slot.battler and slot.battler.mon
  if not mon then return end
  self:teach(mon, mon.nickname or slot.battler.name, event.move)
end

function M:teach(mon, name, moveId)
  local def = (self.game.data.moves or {})[moveId]
  if not def then return end
  for _, known in ipairs(mon.moves or {}) do
    if known.id == moveId then return end
  end
  name = name or "?"

  if #(mon.moves or {}) < 4 then
    mon.moves[#mon.moves + 1] = { id = moveId, pp = def.pp }
    self:say(name .. " learned\n" .. (def.name or moveId) .. "!")
    return
  end

  self.toLearn = self.toLearn or {}
  self.toLearn[#self.toLearn + 1] = { mon = mon, move = moveId }
  self:say(name .. " is trying to\nlearn " .. (def.name or moveId) .. "!")
end

-- ------- nobody is saying anything
--
-- A disconnect is handled elsewhere (peerGone). This is the other shape of the
-- same problem and the one that used to hang forever: a client that is still
-- connected and has simply stopped answering. A wedged game, a closed laptop, a
-- network that drops packets without dropping the socket -- from the outside
-- all three look exactly like somebody taking their time.
--
-- **Three clocks live here, and they are three different questions.** Named,
-- because a clock nobody can name is a clock somebody re-uses for the wrong
-- silence -- which is exactly how the old self-forfeit came about.
--
--   * the **turn deadline** (`turnOpened`, COOP_TURN_TIMEOUT): host-only. One
--     per turn, over every player slot including the host's own. On expiry the
--     late slots are auto-picked (see `autoPickLate`) and the turn resolves.
--   * the **replacement-choice clock** (`waitClock`, COOP_CHOICE_TIMEOUT):
--     host-only, and untouched by any of this. A slot awaiting a send-out
--     freezes the whole field rather than one turn, so it gets the shorter
--     rope and a different mechanism -- a forced send-out, not an auto-pick.
--   * the **host-silence clock** (`hostClock`, COOP_STALL_TIMEOUT): on the
--     three replayers, who cannot resolve anything and can only ask. Two things
--     about what it measures, and both were wrong in their own direction: it
--     counts silence *from the host* rather than silence on the wire (see the
--     reset in `drainNet`), and it counts from the **handover** -- the moment
--     the host owes an answer -- rather than from the host's last message,
--     which would fold the whole of that message's narration into the silence
--     it is meant to be measuring.
--
-- One more thing lives here that is not a clock in that sense either: the
-- bottomed-out wait below (`wedgeAsked`). It is the promise `waitLine` printed
-- being kept -- when the number on screen runs out with nothing to show for
-- it, this asks the host for the field rather than sitting on "(0)".
--
-- `waitShown` is not a clock in that sense: it is how long the turn has been
-- open, ticked on all four purely so the line can appear and count down against
-- the deadline above. It enforces nothing.

-- ------- how much longer than the host's own deadline a wait is given
--
-- The wait below is bounded by the host's deadline, not by this client's copy
-- of the number -- and the two do not start together. Every client stamps its
-- countdown at *its own* handover, and a client that read the last batch faster
-- than the host reaches that moment first; on top of that the host's answer has
-- to travel. So asking at exactly COOP_TURN_TIMEOUT would fire on every turn
-- the host lets run to its deadline, on all three replayers at once, for a
-- battle with nothing wrong with it -- and each pointless snapshot would clear
-- `acted` (the wait line then misnaming who is late) and reset `waitShown` (the
-- countdown jumping back to 60), which is the same number lying again in a new
-- way.
--
-- Borrowed rather than invented, and from the closest analogue there is:
-- Config pairs COOP_ASK_TIMEOUT with COOP_ASK_GRACE for exactly this shape of
-- question -- "how much slack on top of a sixty-second budget before the side
-- that is waiting concludes the answer is never coming". This is that question
-- asked about a different sixty. (A constant of this mod's own would have to
-- live in Config.lua, which this change does not own.)
local WEDGE_GRACE = Config.COOP_ASK_GRACE

function M:tickStalls(dt)
  if self.result or self.phase == "over" then return end

  -- ------- the clock the *screen* reads, and it starts at the handover
  --
  -- Ticked on every client rather than only the one that can act on it: the
  -- host's `waitClock` decides when to step in and a replayer has no
  -- equivalent, so without this the three people who are merely waiting are the
  -- three with nothing to look at.
  --
  -- **Ticked unconditionally, not only while `waitingOn()` answers.** It used
  -- to start when *this* client committed -- `waitingOn` is falsy for the whole
  -- of your own deliberation, and the else branch above reset it every frame of
  -- it. So a player who spent twenty seconds choosing started counting twenty
  -- seconds late and was reading "(20)" at the moment the host's deadline fired
  -- and picked for everybody. The number promised something that had already
  -- happened.
  --
  -- What it counts now is time since the turn opened, because that is what the
  -- deadline it is counting against measures. The reset lives at the
  -- messages->choose handover in `update`, beside `openTurn` -- one event, and
  -- every client reaches it from its own copy of the same batch of messages.
  -- `COOP_WAIT_HINT` still decides when any of it is *shown* (see `waitLine`),
  -- so an ordinary turn still says nothing.
  self.waitShown = (self.waitShown or 0) + (dt or 0)

  if self.host then
    if self.sim:awaitingChoice() then
      -- ------- clock two: the replacement choice, exactly as it was
      --
      -- A choice nobody answers stops the battle dead -- the field refuses to
      -- resolve while any slot is awaiting -- so it gets the *shorter* clock:
      -- a player still picking a move holds up one turn, a player who has not
      -- answered a faint holds up everything, and theirs is the easier
      -- decision of the two. Resolved by sending out whatever was next rather
      -- than waiting forever.
      self.waitClock = (self.waitClock or 0) + dt
      if self.waitClock >= Config.COOP_CHOICE_TIMEOUT then
        self.waitClock = 0
        local slot = self.sim:awaitingChoice()
        if slot then
          self:applyReplace({ slot = slot.index,
                              index = self.sim:hasReserve(slot),
                              forced = true })
        end
      end
      return
    end
    self.waitClock = 0

    -- ------- clock one: the turn deadline
    --
    -- **The old clock here ran backwards.** It only ticked while the host's own
    -- phase was "wait" -- that is, only once the host had *already committed*
    -- -- and it ended in `forfeitSilent`, which excludes the host's own slot.
    -- So the one player who had answered was the one being clocked, and the
    -- one who had not was bounded by nothing at all: an idle host held the
    -- other three forever, and a committed host wrote off whoever it was
    -- waiting for. Both halves are gone.
    --
    -- What replaces it does not care whose phase is what. The deadline belongs
    -- to the *turn*, it is stamped when the turn becomes decidable (see
    -- `openTurn`), and on expiry every slot that still owes an action is
    -- picked for -- the host's own included. Nobody is ever written off for
    -- being slow; the battle simply moves.
    --
    -- Frozen while a replacement pause is live (the early return above): that
    -- silence belongs to the other clock, and letting this one run through a
    -- 30-second pause would fire it the instant the pause cleared, on players
    -- who had not been asked anything yet.
    if self.turnOpened then
      self.turnOpened = self.turnOpened + dt
      if self.turnOpened >= Config.COOP_TURN_TIMEOUT then
        -- Disarmed before the pick, not after: `autoPickLate` resolves the
        -- turn, and the batch of messages that produces keeps `tickStalls`
        -- running -- an armed clock still past its deadline would fire again
        -- on the very next frame, and every frame after it. The turn that
        -- resolves re-arms it at the handover (see `openTurn`).
        --
        -- ...unless nothing was filed, which is now three cases rather than
        -- one: a sim with no `defaultAction` to ask, the messages phase (the
        -- previous turn is still being read -- nobody is late for a menu they
        -- have not been offered), and a slot `defaultAction` cannot answer for,
        -- which abandons the whole attempt rather than filing half a turn. All
        -- three re-arm rather than leaving the clock dead, so the wait stays
        -- bounded and the next expiry tries again on a field that has moved.
        self.turnOpened = nil
        if not self:autoPickLate() then self.turnOpened = 0 end
      end
    end
    return
  end

  -- ------- the wait that outlived the number printed on it
  --
  -- **This is the reported "(0)" freeze, and it is a lost message rather than
  -- a broken clock.** A replayer commits, goes to `wait`, and from then on the
  -- only thing that can move it is the host's next `res` -- so a message
  -- dropped in either direction wedges it: an `act` that never arrived leaves
  -- the host waiting for an answer this client believes it gave, and a `res`
  -- that never arrived leaves this client waiting for a turn the host believes
  -- it sent. Either way the countdown on screen runs to zero and sits there.
  --
  -- Neither clock below covered it. `hostClock` is reset by *any* traffic --
  -- another player's `act`, the host's answer to somebody else's resync -- so
  -- in a chatty group it never reaches COOP_STALL_TIMEOUT at all; and even at
  -- 75 seconds it is longer than the 60 this client is counting down. The only
  -- thing that unwedged the battle was the host's own turn deadline, a full
  -- minute later, which then auto-picked away the turn this player had already
  -- taken.
  --
  -- So the promise the number makes is kept by the client that made it: when
  -- the budget on screen runs out with nothing to show for it, ask the host for
  -- the field. One request per wait -- `wedgeAsked` is cleared at the handover
  -- beside `waitShown` -- so a slow turn costs one message and not a storm, and
  -- the host's answer is addressed to the asker alone (see the `resync`
  -- handler). What comes back puts this client right: see `M:unwedge`.
  --
  -- Never while spectating (that wait is permanent by design and has nothing to
  -- ask about), never mid-replacement, and never on the host -- the host is the
  -- thing being waited *for*, and its own deadline is what bounds it.
  if self.phase == "wait" and not self.replacing and not self.wedgeAsked
     and not self:spectating()
     and (self.waitShown or 0) >= Config.COOP_TURN_TIMEOUT + WEDGE_GRACE then
    self.wedgeAsked = true
    self.wedged = true
    mod.log:warn("a co-op turn has taken longer than its own deadline; asking "
      .. "the host for the field in case a message was lost")
    self:requestResync()
  end

  -- A replayer, waiting on the host.
  self.hostClock = (self.hostClock or 0) + dt
  if self.hostClock < Config.COOP_STALL_TIMEOUT then return end
  self.hostClock = 0
  if not self.stalled then
    -- First silence: assume a lost message and ask for the field. Cheap, and
    -- it repairs the ordinary case without anybody noticing.
    self.stalled = true
    mod.log:warn("the co-op battle has gone quiet; asking the host for the "
      .. "field again")
    return self:requestResync()
  end
  -- Second silence: the host is not answering at all, and nobody else can
  -- resolve a turn. Ended as a draw and said out loud, because four people
  -- sitting on a battle that will never continue is the worst outcome
  -- available.
  self.result = "draw"
  self:say("The battle was\ncut short.")
  self.phase = "messages"
  self.after = "over"
end

-- ------- the turn is now decidable: start the deadline
--
-- Stamped at **one** point, and this is it: the moment `update` hands the box
-- back from the messages phase to whatever comes next. That one point covers
-- both cases the deadline has to cover -- the first `choose` (the opening
-- "2 on 2 battle!" line drains and the first menu opens) and every later one
-- (a resolved turn's events finish applying and the next menu opens) -- and it
-- has the property `tryResolve` does not: it fires when the turn is decidable
-- *to a player*, rather than when the sim finished computing the last one and
-- everybody still had twenty seconds of messages to read.
--
-- Held as seconds elapsed rather than as a timestamp, because that is what
-- every other clock on this screen is: `tickStalls` is handed `dt` and there is
-- no wall clock in here to read. Nil means "no turn is open", which is the
-- state during a replacement pause and after the deadline has fired.
--
-- Host-only. It is the host that enforces it; the number the other three see
-- is a display of the same budget (see `waitLine`), started from their own
-- side of the same event.
function M:openTurn()
  if not self.host or self.result then return end
  self.turnOpened = 0
end

-- ------- the deadline fires: pick for whoever is late
--
-- The owner's policy, and it is deliberately not the old one: **nobody
-- forfeits for being slow.** A player who has wandered off costs the table one
-- turn's worth of their monster doing something sensible, not their place in
-- the battle -- and a battle that ends because somebody answered the door is a
-- worse outcome than one that plays itself for a turn.
--
-- Every living player slot that has not filed an action gets
-- `CoopSim:defaultAction`, **the host's own slot included** -- which is the
-- half the old clock could not do and the half the reported hang needed.
--
-- `defaultAction` is asked for through a guard rather than called outright: the
-- suite builds clients over minimal sims, and a sim without one leaves the slot
-- unfiled (the turn then simply waits, exactly as it did before) rather than
-- taking the battle down inside a clock.
function M:autoPickLate()
  if not (self.host and self.sim) then return false end
  if self.result then return false end
  -- ------- nobody is late during the narration
  --
  -- The messages phase is not a wait for an answer: it is the turn *before*
  -- this one still being read, on a box that holds every line for at least
  -- 1.6 seconds. Nobody has been offered the menu yet, so nobody can be late
  -- for it, and firing here files a turn against players who were never asked.
  --
  -- The clock's other end is closed in `tryResolve`, which disarms it the
  -- moment it commits to resolving. This is the belt to that pair of braces:
  -- the host reaches the messages phase by paths that never touch `tryResolve`
  -- at all -- the opening "2 on 2 battle!" line, and `applyReplace` playing a
  -- forced send-out's batch.
  if self.phase == "messages" then return false end
  -- Never while a slot is still owed a send-out: that pause is the other
  -- clock's, and a turn cannot resolve through it anyway.
  if self.sim:awaitingChoice() then return false end
  self.pending = self.pending or {}

  -- ------- collected for everybody first, filed for nobody until it is
  --
  -- **A partial auto-pick is an unrecoverable hang, and it used to be one file
  -- away.** `defaultAction` returns nil for a live slot with no living target,
  -- and the old loop filed whatever it did get: `tryResolve` then found a slot
  -- still owing an action and returned, leaving `pending` half full, `acted`
  -- half set, `lateNotes` sitting there ready to blame those players on some
  -- *later* turn, the deadline disarmed by the caller, and -- for the host's
  -- own slot -- `closePickers` having parked it in "wait" with no menu to
  -- answer from. Nothing left could resolve or re-arm anything.
  --
  -- So the picks are gathered before a single one is filed, and one nil is
  -- enough to abandon the whole attempt. Returning false re-arms the clock in
  -- `tickStalls`, so the next expiry tries again -- by which time the field has
  -- almost certainly moved (the slot with no target means the other side is
  -- mid-faint) and every slot can be answered for.
  local picks = {}
  for _, slot in ipairs(self.sim.slots or {}) do
    if slot.owner ~= nil and not self.sim:isDown(slot)
       and not self.pending[slot.index] then
      local action = self.sim.defaultAction
        and self.sim:defaultAction(slot.index)
      if not action then return false end
      picks[#picks + 1] = { slot = slot, action = action }
    end
  end
  if #picks == 0 then return false end

  local notes = {}
  for _, pick in ipairs(picks) do
    local slot = pick.slot
    self.pending[slot.index] = pick.action
    self:markActed(slot.index)
    -- Said out loud, per slot, in the words the forced replacement already
    -- uses (see `applyReplace`): a choice a clock made looks exactly like a
    -- choice the player made, and the four people watching are owed the
    -- difference. One line, and it fits the eighteen-column box at the
    -- longest name the wire can carry (NAME_MAX 10 + "took too long!").
    notes[#notes + 1] = { kind = "msg",
      text = (slot.name or "Someone") .. "\ntook too long!" }
    -- ...and if it was *this* client that was idle, its menus close on the
    -- state change rather than on a button it is not going to press --
    -- the same discipline the forced send-out closes the bench picker with.
    if slot.index == self.mine then self:closePickers() end
  end

  -- Carried into the turn rather than said here, so all four clients hear it:
  -- `tryResolve` puts them at the head of the events it broadcasts. Ordinary
  -- `msg` rows -- nothing new on the wire, and an older client plays them like
  -- any other line.
  self.lateNotes = notes
  self:tryResolve()
  return true
end

-- Shut whatever menu this client is sitting in, because its answer has just
-- been filed for it. Only the phases that are a *question*: `replacing` is
-- untouched, since a slot awaiting a send-out is never auto-picked.
function M:closePickers()
  local open = self.runAsk ~= nil
    or self.phase == "choose" or self.phase == "move"
    or self.phase == "target" or self.phase == "switch"
    or self.phase == "item"
  if not open then return false end
  -- A consent ask is a question too, and the clock has just answered it: the
  -- turn this client was going to spend on running has been spent on a move
  -- instead, so neither the wait nor the prompt has anything left to resolve.
  self.runAsk = nil
  self.phase = "wait"
  -- The cursors go back where a fresh turn would put them, so the menu that
  -- opens next turn is not still pointing at half a decision from this one.
  self.commandIndex = 1
  self.moveIndex = 1
  self.targetIndex = 1
  return true
end

-- ------- one turn, as a replayer sees it
--
-- Two things can be wrong with an arriving turn, and they need telling apart.
--
--   * **A gap.** Its number is not the one after the last, so a message was
--     lost. Nothing about the events in hand can repair that -- the missing
--     turn's damage is simply unknown -- so the field is asked for instead.
--   * **A mismatch.** Every turn arrived and the two copies still disagree,
--     which means a replay diverged rather than a message vanished. Same
--     remedy, different cause, and worth logging as its own thing because it
--     points at a bug in the mod rather than at the network.
--
-- Both recover the same way and neither ends the battle: the host is the
-- authority, so being put back in step with it is always available.
function M:applyTurn(msg)
  local seq = Wire.int(msg.seq, 1, 100000)
  local expected = (self.seq or 0) + 1
  -- The turn has come back, so every answer this client was watching for was
  -- given -- the replayer's half of the reset `tryResolve` does on the host.
  self.acted = nil

  if seq and seq ~= expected then
    self.gaps = (self.gaps or 0) + 1
    mod.log:warn("a co-op battle missed turn %d (saw %d); asking the host to "
      .. "re-send the field", expected, seq)
    self.seq = seq
    self:playEvents(msg.events)
    return self:requestResync()
  end

  self.seq = seq or expected
  -- The turn this client was waiting on has come back, so whatever it spent
  -- on that turn was really spent.
  self.owed = nil
  self:playEvents(msg.events)

  if type(msg.sig) == "string" then
    local mine = self.sim:signature()
    if mine ~= msg.sig then
      self.desyncs = (self.desyncs or 0) + 1
      mod.log:warn("a co-op battle drifted from the host after turn %d "
        .. "(host %s, here %s); re-syncing", self.seq, msg.sig, mine)
      return self:requestResync()
    end
  end
end

-- Whether a message the relay fanned out to all four was meant for this one.
--
-- An older host sends no `to` at all, and a snapshot is always safe to apply
-- -- it is the host's own field -- so an unaddressed one is still taken. What
-- it must not do is silently reset the sequence of a client that was never
-- behind, which is what `to` prevents.
function M:addressedToMe(msg)
  local to = Wire.id(msg.to)
  if not to then return true end
  local slot = self.sim:slot(self.mine)
  return slot ~= nil and slot.owner == to
end

-- Did the host say this?
--
-- `res`, `state` and `gone` are the three things only the host is ever
-- entitled to send: a resolved turn, a snapshot of the field, and a player
-- written off. The relay fans every message out to all four, so without this
-- any client could post one -- rewriting everybody's HP, replacing the whole
-- field, or forfeiting a player who is still sitting there. `act` has been
-- checked against its sender all along (see `drainNet`); this is the same rule
-- pointed the other way.
--
-- It is a slightly wider fix than the display sequencing it arrived with:
-- `state` and `gone` predate all of it. The rule is the same for all three and
-- the surface was flagged as one, so it is closed as one.
--
-- Answered permissively when either side of the comparison is unknown -- an
-- older host sends no `from`, and a client that never learned who the host is
-- has nothing to compare against. Refusing there would break a battle that is
-- merely old rather than forged.
function M:fromHost(msg)
  if self.hostId == nil or msg.from == nil then return true end
  return msg.from == self.hostId
end

function M:requestResync()
  if not self.net then return false end
  self.net.send({ t = "resync" })
  return true
end

-- ------- and what the answer does to a client that was stuck
--
-- A snapshot has always put the *field* right. It never put the **screen**
-- right, and that is the other half of the "(0)" freeze: a client wedged in
-- `wait` -- because the turn it answered never came back -- had its HP numbers
-- corrected and was left sitting in the same answered-and-waiting state, with
-- no menu, for as long as the battle lasted.
--
-- So a snapshot that answers a wedged wait hands the box back. Whatever this
-- client committed to is now either resolved (the field it has just been given
-- is the proof) or was never received; both readings end the same way, with the
-- player owed a menu. Committing again costs nothing on the wire -- the host
-- keys `pending` by slot, so a second answer replaces the first rather than
-- adding to it, and nothing about the sim moves either way.
--
-- It is not free in the **bag**, though, and that is why the refund happens
-- first. `updateItem` debits the item at the moment of committing, because only
-- this client owns its inventory, and `owed` holds exactly one id -- so a
-- player who picked a POTION, was unwedged, and picked one again would be
-- debited twice and refunded once. The turn being reopened here is by
-- definition unresolved, which is precisely the condition `refundUnspent` was
-- written for.
--
-- `acted` goes with it, because it is a claim about a turn this client has just
-- been told it is not in step with: keeping it would leave the wait line naming
-- people who have answered and omitting people who have not.
--
-- Only for a wait this client actually flagged (see `tickStalls`). An ordinary
-- resync -- one asked for because a turn number had a gap in it -- must not
-- reopen a menu behind the batch of messages it is already playing.
function M:unwedge()
  if not self.wedged then return false end
  self.wedged, self.wedgeAsked = nil, nil
  self.waitShown = 0
  self.acted = nil
  if self.result or self.replacing or self:spectating() then return true end
  if self.phase == "wait" then
    -- The item paid for on the turn that is being reopened comes back before
    -- the menu that can spend another one does (see the header).
    self:refundUnspent()
    self.phase = "choose"
    self.commandIndex = 1
    self.moveIndex = 1
    self.targetIndex = 1
    -- A consent ask belongs to the turn that went missing with it.
    self.runAsk = nil
  end
  return true
end

-- ------- somebody left
--
-- Two very different cases behind one message.
--
-- If it was the **host**, there is nobody left to resolve a turn: the other
-- three are replaying events from a client that has gone. The battle ends,
-- called a draw, because nobody won it and inventing a winner from whoever
-- happened to still be connected would be worse than saying so.
--
-- If it was anybody else, their slot forfeits and the fight carries on three
-- ways. That is the case the host must handle promptly -- it stops waiting for
-- an action that will never arrive, which is the deadlock this exists for.
function M:peerGone(id)
  if not id or self.result then return false end

  local hostGone = self.hostId ~= nil and self.hostId == id
  if hostGone and not self.host then
    self.result = "draw"
    self:say("The battle was\ncut short.")
    self.phase = "messages"
    self.after = "over"
    return true
  end

  local slot = self.sim:forfeit(id)
  if not slot then return false end
  -- A consent ask whose other end has just walked out cannot be answered by
  -- anybody, so it comes down rather than sitting there waiting on a client
  -- that is gone.
  if self.runAsk and self.runAsk.slot == slot.index then self.runAsk = nil end
  self:say((slot.name or "Someone") .. "\nleft the battle!")
  self.phase = "messages"
  -- Whatever they had filed is void, and the turn may now be resolvable
  -- without them.
  self.pending[slot.index] = nil
  if self.host then
    if self.sim:checkOver({}) then
      self.result = self:resultFor(self.sim.over)
      self.after = "over"
    else
      self:tryResolve()
    end
  end
  return true
end

-- ------- the wire

function M:drainNet()
  for _, msg in ipairs(self.net.poll() or {}) do
    if type(msg) == "table" then
      -- ------- the host-silence clock hears the **host**, not the wire
      --
      -- This used to be reset by any message at all, on the reading that
      -- traffic means the battle is alive. It does not: only the host can
      -- resolve a turn, so a battle whose host has stopped answering is a
      -- battle that has stopped, however busy the other three are -- and they
      -- *are* busy, because a player who has not heard back keeps pressing
      -- buttons and every one of those `act` messages reset this clock on the
      -- other two. Three replayers therefore held each other's stall detection
      -- at zero forever, and the one recovery that exists for a departed host
      -- -- ask for the field, then call it cut short -- could never fire.
      --
      -- The three types the host alone may send are exactly the three that
      -- count as the host answering, and each is checked against `fromHost`
      -- like the handlers below, so a client cannot keep somebody else's
      -- clock alive by posting one.
      --
      -- Resetting it here is the *ceiling* on the wait, not where the wait
      -- starts: the handover restarts it too (see `update`), because the
      -- narration a `res` produces is time the host is entitled to and not
      -- silence to be counted against it.
      if (msg.t == "res" or msg.t == "state" or msg.t == "gone")
         and self:fromHost(msg) then
        self.hostClock = 0
        self.stalled = nil
      end
      if msg.t == "act" and self.host and type(msg.action) == "table" then
        local action = msg.action
        -- Only the slot that sent it may act for it. Without this a modified
        -- client could file its partner's move, or the NPC's.
        local slot = self.sim:slot(action.slot)
        if slot and slot.owner and slot.owner == msg.from then
          -- A replacement, not a turn.
          --
          -- The field is paused waiting for exactly this slot to send its next
          -- monster out, and `tryResolve` refuses to resolve anything while it
          -- is -- so filing a replacement as an ordinary action put it in a
          -- queue that could never be drained, and the pause waited on itself.
          -- Every non-host player whose monster fainted deadlocked the battle
          -- for all four until the stall timeout force-picked for them a
          -- minute later. Told apart by the field's own `awaiting`, which is
          -- the host's state and cannot be claimed by a message.
          if slot.awaiting then
            self:applyReplace({ slot = action.slot,
                                index = Wire.int(action.index, 1, 6) })
          elseif action.kind == CoopSim.REPLACE then
            -- An answer to a question that is no longer being asked: the
            -- replacement already landed and this is a duplicate, or a stale
            -- retry. Dropped rather than fed to the line below, which would
            -- not recognise the kind, fall back to "move", and file a move
            -- this player never chose -- overwriting the one they did.
            mod.log:warn("a co-op replacement arrived for a slot that is not "
              .. "waiting; ignoring it (the battle is unaffected)")
          else
            -- Re-derived rather than trusted, like anything else off the wire:
            -- this decides what somebody else's monster does.
            local kind = CoopSim.KINDS[action.kind] and action.kind or "move"
            self.pending[action.slot] = {
              slot = action.slot,
              kind = kind,
              move = Wire.int(action.move, 1, 8) or 1,
              target = Wire.int(action.target, 1, Config.COOP_FIGHTERS) or 1,
              index = Wire.int(action.index, 1, 6),
              item = kind == "item" and Wire.spriteId(action.item) or nil,
            }
            self:markActed(action.slot)
            self:tryResolve()
          end
        end
      elseif msg.t == "act" and not self.host and type(msg.action) == "table" then
        -- Watched, never acted on.
        --
        -- The relay fans every `act` out to all four, and until now the three
        -- clients that cannot resolve a turn simply dropped them -- which is
        -- why their wait line had nothing to say and fell back to a countdown
        -- nothing on this client enforces. Reading them costs nothing and
        -- answers the only question a waiting player has: who are we waiting
        -- for. Nothing is filed and nothing is simulated from it -- the host
        -- is still the only client that acts on an action, and it still checks
        -- the sender owns the slot (above) before it does.
        --
        -- Two conditions on the marking, both of them about not lying to the
        -- player reading the wait line:
        --
        --   * a **replacement is not a turn action**. The slot that sends one
        --     still owes this turn a move, so marking it acted takes it off
        --     the missing list for good -- and the case that makes that
        --     visible is a lost `res` recovered by snapshot, where the turn
        --     never resets `acted` and the slot stays silently omitted for the
        --     rest of it. The host tells the two apart by `slot.awaiting`,
        --     which is its own state; here the kind on the message is all
        --     there is, and it is enough because nothing is simulated from it.
        --
        --   * the **sender must own the slot it names**. The host has checked
        --     that all along, and the comment above claims the rule for this
        --     branch too -- so the code has to make it true rather than take
        --     any client's word for which slot has answered.
        local seen = Wire.int(msg.action.slot, 1, Config.COOP_FIGHTERS)
        local slot = seen and self.sim:slot(seen)
        if slot and slot.owner and slot.owner == msg.from
           and msg.action.kind ~= CoopSim.REPLACE then
          self:markActed(seen)
        end
      elseif msg.t == Wire.COOP_RUN_ASK then
        -- Who asked is the sender the hub stamped, resolved against this
        -- client's own copy of the field -- never a slot named in the payload,
        -- which is a slot a modified client could claim.
        local from = self:slotOwnedBy(msg.from)
        local mine = self:mySlot()
        if from and not self.result then
          -- Recorded by the host whichever side it came from: the host is what
          -- resolves a flee, and it will not resolve one it never saw asked
          -- for -- including when the host is one of the two being asked
          -- *about*, sitting on the other side of the field.
          if self.host then self:hostRunAsk(from.index) end
          -- ...and only the asker's own partner is being asked. The other two
          -- see the message and ignore it, exactly as they ignore an `act`
          -- filed for a slot they do not own.
          if mine and from.index ~= self.mine and from.side == mine.side
             and self:partyBattle() then
            local up = self.runAsk
            -- ------- the same question, asked again
            --
            -- A prompt already up for this slot is left exactly as it is, and
            -- that is a guard against the settle floor being defeated by
            -- repetition: a client that sent an ask every frame would otherwise
            -- put the cursor back on the safe answer and restart the clock
            -- every frame, leaving a prompt that can never be answered -- and,
            -- worse, one whose floor is forever about to expire under a player
            -- who is holding A. The prompt on screen *is* the ask; a second
            -- copy of it says nothing new.
            local already = up ~= nil and up.role == "deciding"
              and up.slot == from.index
            if up and up.role == "asking" then
              -- ------- both of them pressed RUN
              --
              -- Two asks crossing on the wire, and the wrong answer here is a
              -- wedge: two clients each waiting for the other to answer a
              -- question neither is being shown. The right one needs no
              -- tie-break at all, because the state itself is the answer --
              -- **a player who has just asked to leave has already consented
              -- to leaving.** So the second ask is taken as the reply to the
              -- first, from both ends; the host sees two yeses and resolves the
              -- first one it can, and the second finds the battle already
              -- decided and does nothing (see `resolveFlee`).
              self:answerRun(true)
            elseif not already then
              self.runAsk = { role = "deciding", slot = from.index,
                              name = from.name, index = RUN_DEFAULT,
                              clock = 0 }
            end
          end
        end
      elseif msg.t == Wire.COOP_RUN_ANSWER then
        local from = self:slotOwnedBy(msg.from)
        local ok = Wire.flag(msg.ok)
        if from and not self.result then
          if self.host then self:hostRunAnswer(from.index, ok) end
          -- The asker's own end of it. Everyone else has nothing to close.
          if self.runAsk and self.runAsk.role == "asking"
             and self.runAsk.slot == from.index then
            self.runAsk = ok and { role = "fleeing" }
              or { role = "refused", name = from.name, clock = 0 }
          end
        end
      elseif msg.t == "res" and not self.host and self:fromHost(msg) then
        self:applyTurn(msg)
      elseif msg.t == "resync" and self.host then
        -- Somebody fell behind. Answer with the field itself rather than with
        -- the turns they missed: a snapshot puts them right in one message
        -- whatever they lost, and cannot itself arrive out of order.
        --
        -- Addressed to whoever asked, because the relay fans every message out
        -- to all four. An unaddressed answer was applied by all three
        -- replayers, and the two who were perfectly in step had their `seq`
        -- set back to the host's -- which the next turn then read as a gap, so
        -- they asked too, which rewound everybody again. One client falling
        -- behind by a single message turned into a resync storm that never
        -- converged and a battle that never ended.
        if self.net then
          self.net.send({ t = "state", to = msg.from, seq = self.seq or 0,
                          slots = self.sim:snapshot() })
        end
      elseif msg.t == "gone" and not self.host and self:fromHost(msg) then
        -- The host has written somebody off. Applied rather than re-derived,
        -- so all four agree on who is still in the fight.
        local owner = Wire.id(msg.owner)
        if owner then
          local slot = self.sim:forfeit(owner)
          if slot then self:say((slot.name or "Someone") .. "\nstopped answering!") end
        end
      elseif msg.t == "state" and not self.host and self:fromHost(msg)
             and self:addressedToMe(msg) then
        self.sim:restore(msg.slots)
        -- The numbers have just changed underneath the screen, so whatever the
        -- bars were animating towards is no longer where they are going. The
        -- display is put where the host says the field is, in one step: an
        -- animation left running across a resync is a bar sliding towards a
        -- number nobody holds any more.
        self:snapDisplay()
        self.seq = Wire.int(msg.seq, 0, 100000) or self.seq
        self.resyncs = (self.resyncs or 0) + 1
        mod.log:warn("a co-op battle re-synchronised with the host after a "
          .. "lost message; the field on screen is correct again")
        -- ...and a client that was stuck answering a turn nobody sent back
        -- gets its menu returned with it (M:unwedge).
        self:unwedge()
      end
    end
  end
end

-- ------- drawing
--
-- Four monsters in 160x144, which the classic layout was never asked to hold.
-- Foes across the top, allies across the middle, and the message box in its
-- usual place at the bottom -- the two rows overlap by a few pixels, which the
-- transparent margins on a Gen 1 pic absorb.
--
-- Every glyph, box and HP bar is the engine's own (Font, HudTiles), so a
-- palette mod or an asset mod still owns the look of a co-op battle exactly as
-- it owns a wild one.

-- The field, in the 160x144 the classic layout was never asked to hold four
-- monsters in.
--
-- Foes across the top, allies across the middle, message box in its usual
-- place at the bottom. The two rows overlap by a few pixels, which the
-- transparent margins on a Gen 1 pic absorb -- and each pair is pushed to the
-- outside edges so the two monsters on a side read as two rather than as one
-- wide smear.
--
-- What the message box says right now -- one decision, drawn by drawMessage
-- and testable without a graphics device (which is why it is its own method:
-- the first version of its regression test mirrored this logic inside the
-- test and proved nothing).
--
-- An empty box is what a player stares at while three other people take their
-- turns, and it is indistinguishable from a battle that has hung -- so the box
-- says which of the two it is whenever there is no line to show. But the
-- fallback lines belong to a *finished* queue, never to the gap between two
-- lines of one that is still playing: dismissing a line leaves `shown` empty
-- for one tick before the next is popped, and a fallback drawn into that gap
-- flashed for a single frame between every pair of battle lines -- most
-- visibly the "X is choosing... (n)" countdown while a replacement pause
-- overlapped a batch, reported as "the battle kinda flickers during a moment
-- of waiting". Mid-batch, an empty frame is the original's own page gap.
function M:boxText()
  local text = self.shown
  if self.phase == "messages" then
    return text or ""
  end
  if text ~= nil and text ~= "" then return text end
  if self:spectating() then
    return "No POKeMON left!\nWatching..."
  end
  local waiting = self:waitLine()
  if waiting then return waiting end
  if self:waitingOn() then
    return "Waiting for the\nothers..."
  end
  return ""
end

function M:drawMessage()
  local Font = engine.Font
  Font.drawBox(0, 12, 20, 6)
  love.graphics.setColor(0, 0, 0, 1)
  local text = self:boxText()
  local y = 112
  for line in tostring(text):gmatch("[^\n]+") do
    Font.draw(line, 8, y)
    y = y + 16
  end
end

-- A 2x2 list drawn in the message box, with the cursor on `index`. Every
-- picker here is one, so they look like one thing rather than four.
function M:drawList(rows, index, title)
  local Font = engine.Font
  Font.drawBox(0, 12, 20, 6)
  love.graphics.setColor(0, 0, 0, 1)
  if title then Font.draw(title, 8, 104) end
  local shown = math.min(#rows, 4)
  local first = 1
  if index > 4 then first = index - 3 end
  for i = 0, shown - 1 do
    local row = rows[first + i]
    if row then
      local col = (i % 2) * 80
      local line = math.floor(i / 2) * 16
      Font.draw(tostring(row):sub(1, 9), 16 + col, 112 + line)
    end
  end
  local at = index - first
  Font.drawCode(0xED, 8 + (at % 2) * 80, 112 + math.floor(at / 2) * 16)
end

-- ------- the same box, one name per row
--
-- A vertical variant of `drawList`, and a separate function rather than a mode
-- on it: the move menu and the command box are 2x2 because four short labels in
-- two columns is what fits, and nothing about the target picker should be able
-- to move them. Here the rows are *names* -- up to NAME_MAX of them, and a
-- second column would cut them in half exactly where two similar foes stop
-- being distinguishable.
--
-- Two rows are visible below the title, which is what the six-tile box has room
-- for; a longer list scrolls under the cursor rather than being clipped, so
-- this still works the day a field has more than two foes on a side.
function M:drawColumn(rows, index, title)
  local Font = engine.Font
  Font.drawBox(0, 12, 20, 6)
  love.graphics.setColor(0, 0, 0, 1)
  if title then Font.draw(title, 8, 104) end
  local shown = math.min(#rows, 2)
  local first = 1
  if index > 2 then first = index - 1 end
  for i = 0, shown - 1 do
    local row = rows[first + i]
    if row then
      -- Sixteen glyphs of room: the cursor takes the first column of the box
      -- and the name starts at the second, so a full NAME_MAX name has six
      -- columns to spare rather than the nine-glyph cut a 2x2 row has to make.
      Font.draw(tostring(row):sub(1, 16), 16, 112 + i * 16)
    end
  end
  Font.drawCode(0xED, 8, 112 + (index - first) * 16)
end

function M:drawCommand()
  self:drawList(M.COMMANDS, self.commandIndex or 1)
end

-- The post-faint picker. Titled, because it is not the same question as the
-- SWITCH command even though it shows the same list: this one has to be
-- answered.
function M:drawReplace()
  local bench = self:benchOf(self.sim:slot(self.mine))
  if #bench == 0 then return self:drawText("No one left!") end
  local rows = {}
  for _, entry in ipairs(bench) do
    local def = (self.game.data.pokemon or {})[entry.mon.species]
    rows[#rows + 1] = (entry.mon.nickname or (def and def.name) or entry.mon.species)
  end
  self:drawList(rows, self.switchIndex or 1, "Who's next?")
end

function M:drawSwitch()
  local bench = self:benchOf(self:mySlot())
  if #bench == 0 then
    return self:drawText("There's no one\nelse to send out!")
  end
  local rows = {}
  for _, entry in ipairs(bench) do
    local def = (self.game.data.pokemon or {})[entry.mon.species]
    rows[#rows + 1] = (entry.mon.nickname or (def and def.name) or entry.mon.species)
  end
  self:drawList(rows, self.switchIndex or 1)
end

function M:drawItem()
  local items = self:usableItems()
  if #items == 0 then
    return self:drawText("You have nothing\nto use.")
  end
  local rows = {}
  for _, entry in ipairs(items) do rows[#rows + 1] = entry.name end
  self:drawList(rows, self.itemIndex or 1)
end

function M:drawText(text)
  local Font = engine.Font
  Font.drawBox(0, 12, 20, 6)
  love.graphics.setColor(0, 0, 0, 1)
  local y = 112
  for line in tostring(text):gmatch("[^\n]+") do
    Font.draw(line, 8, y)
    y = y + 16
  end
end

function M:drawMoves()
  local Font = engine.Font
  Font.drawBox(0, 12, 20, 6)
  love.graphics.setColor(0, 0, 0, 1)
  local moves = self:liveMoves()
  -- Nothing left anywhere: say what is actually going to happen rather than
  -- listing four moves that cannot be used. The turn still resolves -- the sim
  -- substitutes STRUGGLE whatever was chosen -- so this is the menu telling
  -- the truth about it.
  if not self.sim:hasPP(self:mySlot() and self:mySlot().battler) then
    Font.draw("No moves left!", 16, 112)
    Font.draw("STRUGGLE", 16, 128)
    Font.drawCode(0xED, 8, 128)
    return
  end
  for i, moveInst in ipairs(moves) do
    local def = (self.game.data.moves or {})[moveInst.id]
    local label = (def and def.name) or moveInst.id or "-"
    local col = ((i - 1) % 2) * 80
    local row = math.floor((i - 1) / 2) * 16
    Font.draw(label:sub(1, 9), 16 + col, 112 + row)
  end
  local col = ((self.moveIndex - 1) % 2) * 80
  local row = math.floor((self.moveIndex - 1) / 2) * 16
  Font.drawCode(0xED, 8 + col, 112 + row)
  -- PP on the move the cursor is on, because a move with none left is the one
  -- thing about it a player has to know before pressing A.
  local pick = moves[self.moveIndex]
  if pick then
    Font.draw(("PP %2d"):format(pick.pp or 0), 112, 104)
  end
end

-- "Attack who?", as a list of who.
--
-- It used to show one name at a time, under the question, with the cursor
-- nailed to it -- so the choice was invisible: nothing on screen said there was
-- a second foe. Then both, side by side through `drawList`, which showed the
-- choice but at nine glyphs a column: two foes of the same species read as one
-- truncated name printed twice.
--
-- So it is a column now (`drawColumn`), one name per row, at the full width the
-- box has. The two things being told apart are the names, and this is the
-- layout that lets them be.
function M:drawTarget()
  local Font = engine.Font
  local targets = self.sim:targetsFor(self:mySlot())
  local rows = {}
  for _, entry in ipairs(targets) do
    rows[#rows + 1] = (entry.battler and entry.battler.name) or "?"
  end
  self:drawColumn(rows, self.targetIndex or 1, "Attack who?")
  local pick = targets[self.targetIndex]
  -- ...and the cursor also lands on the monster itself, because picking one of
  -- two identical foes off a name alone is a guess.
  --
  -- Placed against the pic's drawn origin rather than its raw `SLOT_POS`
  -- (M:picOriginFor): every hoverable target is on the far pair, which is
  -- exactly the pair FOE_SCALE moves, so the raw position put the cursor beside
  -- where the monster *would* have stood at full size.
  if pick then
    local battler = self:shownBattlerAt(pick.index)
    local x, y = self:picOriginFor(pick.index, battler and battler.sprite)
    if x then
      love.graphics.setColor(0, 0, 0, 1)
      Font.drawCode(0xED, x + 10, y + 28)
    end
  end
end

-- Drawn behind a guard, and this is not belt-and-braces.
--
-- StateStack calls draw() directly, so an error here is not a missing frame --
-- it is the game stopping, for four people, mid-battle. The mod's own rule is
-- that a broken renderer costs a display and never the game, and a co-op
-- battle is the one screen in this mod that draws enough moving parts to earn
-- the guard. Warned once, then quietly, so a failure that repeats every frame
-- does not become the log.
function M:draw()
  local ok, err = pcall(self.drawSafe, self)
  if ok then return end
  if not self.drawFailed then
    self.drawFailed = true
    mod.log:error("the 2-on-2 screen failed to draw (%s); the battle is still "
      .. "running and can be finished blind, but report this", tostring(err))
  end
end

function M:drawSafe()
  local eng = engine
  if not eng then return end
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.rectangle("fill", 0, 0, 160, 144)
  self:drawField()
  -- The trainer stands where their monsters will, until the fight starts --
  -- the original's ScrollTrainerPic moment, held rather than animated.
  if self:showingTrainer() then
    love.graphics.setColor(1, 1, 1, 1)
    local ok = pcall(love.graphics.draw, self.trainerPic, 96, 4)
    if not ok then self.trainerPic = nil end
  end
  self:drawAnim()
  if self.replacing then
    self:drawReplace()
  -- Drawn under exactly the condition `update` drives it under, phase included:
  -- an ask deferred behind a batch of messages must leave the message box on
  -- screen, or the box would show a question the buttons are not answering.
  elseif self.runAsk and self.phase ~= "messages" then
    self:drawRunAsk()
  elseif self.phase == "choose" then
    self:drawCommand()
  elseif self.phase == "move" then
    self:drawMoves()
  elseif self.phase == "target" then
    self:drawTarget()
  elseif self.phase == "switch" then
    self:drawSwitch()
  elseif self.phase == "item" then
    self:drawItem()
  else
    self:drawMessage()
  end
  love.graphics.setColor(1, 1, 1, 1)
end

return M
