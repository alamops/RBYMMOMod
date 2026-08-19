-- Co-op battles: the two of you against one trainer, the two of you against
-- the two of them, and (when partied on the same map) the two of you against
-- one wild encounter.
--
-- Three flows live here, and they are less alike than they look.
--
--   * **Against an NPC.**  One partner walks into a trainer and is asked
--     nothing at all, and is shown nothing at all: the wait starts on the spot
--     (COOP_WAIT out) *behind the engine's own encounter presentation*, which
--     is already on screen and is what the waiter watches for the second the
--     round trip takes. Same map is required -- a partner who is not standing
--     here is told so once ("was too far to join!") and the trainer is fought
--     the vanilla way, with no offer posted at all. The partner is pulled in
--     automatically -- no confirm, no interaction with the NPC (see M:autoJoin
--     for the consent model). A partner who is busy when the offer lands does
--     not lose it: M:update re-attempts it as soon as they are free. The one
--     out left is the clock: a wait with no join within SOLO_FALLBACK_AFTER
--     withdraws and releases the waiter into the solo 1v1 with one line.
--   * **Against a wild.**  Same-map partner online and free → divert into
--     mediated `coop_wild`: host posts COOP_WAIT and leaves the engine wild on
--     screen exactly as the trainer path does. Same auto-join, same clock.
--     Mutual waits arbitrate by lexicographically smaller playerId (their wait
--     wins; see considerOffer), in both modes.
--   * **Against another party.**  PARTY BATTLE on the ACTIONS menu, and all
--     four have to agree before anything starts.
--
-- **What this module is, precisely: the agreement.**  It decides who is
-- waiting, who may join, what a "no" costs and what it does not, and when the
-- door closes.  It does not *fight* the battle -- src/CoopSim.lua is the
-- four-slot field and src/CoopBattle.lua is the screen -- but it does assemble
-- it: M:begin runs the party exchange that turns four agreements into four
-- battlers, and pushes the result.
--
-- Three rules are worth naming up front, because every awkward-looking branch
-- below is one of them being obeyed rather than an oversight.
--
-- 1. **The party is the consent, on both ends.**  Nobody is asked anything
--    when a fight begins: forming the party was the yes, the walker-in starts
--    waiting the instant the trainer triggers, and the partner is pulled in
--    without a confirm. An offer that cannot be taken this instant (mid-fight,
--    mid-trade) stays standing and is re-attempted from M:update the moment
--    this client is free, and the waiter's own clock is what ends a wait
--    nobody ever takes. The outs did not go anywhere and are the whole reason
--    no ask is needed: the SOLO_FALLBACK_AFTER self-release, STOP once a fight
--    is up -- and, for a player who wants none of this, cancelling the party.
-- 2. **The fight cannot be dodged.**  Once a trainer has been triggered, every
--    exit from every prompt this module raises ends in a battle.  The engine
--    has already committed to the encounter by the time this module is called,
--    so a prompt that could be escaped would be a prompt that skipped a
--    trainer -- which is why the wait raises no prompt at all: it leaves the
--    engine's battle on screen and simply takes it over, or does not.
-- 3. **The door closes when the battle starts, not when it is agreed.**
--    running is set at handoff and refuses every later join, because a fourth
--    monster appearing mid-turn is not a thing the other three agreed to.
--
-- Shaped like Party and Sessions -- a transport, a ui and the other state
-- modules handed in at construction, no engine modules, no love -- which is
-- what lets the suite drive both flows, from both sides, under plain luajit.

local need, mod = ...
local Config = need("Config")
local Wire = need("Wire")
local Gen = need("Gen")
local CoopBattle = need("CoopBattle")
local Mediated = need("MediatedBattle")

-- How often a standing offer is re-attempted while this client is busy.
--
-- Local rather than a Config constant on purpose: the hubs know nothing about
-- it -- they hold the offer and relay whatever COOP_JOIN arrives -- and every
-- co-op number in Config is one the Node twin mirrors. Half a second is below
-- notice for the player being pulled in and keeps the poll's real cost (a walk
-- of the state stack) at twice a second on the rare ticks an offer stands.
local JOIN_RETRY_EVERY = 0.5

-- How long a wait stands before this client gives up and fights alone.
--
-- **One timeout, not two.** This used to be Config.COOP_ASK_TIMEOUT (60s),
-- which was the right number for a wait the player was *watching* -- a cover
-- was up, nothing else could happen, and a minute was a generous window for a
-- partner to surface from a menu. There is no cover any more: the waiter is
-- looking at the engine's own encounter, which they can fight. Sixty seconds
-- of that is not a wait, it is a solo battle that suddenly turns into a co-op
-- one halfway through.
--
-- Six seconds instead, and the number is chosen against what is on screen
-- rather than against the network: the engine's entry wipe plus the trainer's
-- appear-and-send-out runs for several seconds before the player is given a
-- menu, so the common case (a free partner, a sub-second round trip) is
-- covered by the animation and the join lands before anything is asked of
-- them. What is left over is the round-9 retry window -- a partner who was in
-- a menu or mid-trade when the offer landed gets a handful of re-attempts
-- (JOIN_RETRY_EVERY) inside it -- and past that the honest answer is that they
-- are not coming.
--
-- Local rather than a Config constant for the same reason JOIN_RETRY_EVERY is:
-- no hub knows about it. The hubs hold the offer and relay COOP_JOIN; both
-- twins' own ask expiry is still Config.COOP_ASK_TIMEOUT, which this does not
-- touch (that clock is the four-way PARTY BATTLE ask, and it is unchanged).
local SOLO_FALLBACK_AFTER = 6

local M = {}
M.__index = M

function M.new(transport, ui, party, roster, chat)
  return setmetatable({
    transport = transport,
    ui = ui,
    party = party,
    roster = roster,
    chat = chat,
    -- our own standing offer: { battle, label, map, start }
    waiting = nil,
    -- the partner's, as it arrived: { from, name, battle, label, map, clock }
    offer = nil,
    -- Who the overlay's "!" is about, and the one field here that exists for
    -- the *display* rather than for the handshake: { id, battle, map }.
    --
    -- It has to be a latch and not a read of `offer`, because `offer` is set
    -- and cleared inside a single synchronous handler in the case the mark is
    -- entirely for -- onOffer sets it, considerOffer takes it, and autoJoin
    -- clears it before the join is even sent, all before any renderer gets a
    -- tick.  A field polled once a frame can never see that.  So the arrival
    -- is written down here instead, and it outlives the offer by design: it is
    -- released when the fight reaches the screen (startBattle), when the offer
    -- ends some other way, when the partner goes, when the party does, and on
    -- the offer's own timeout -- every place `offer` itself is dropped.
    offerMarkFor = nil,
    -- the four-way PARTY BATTLE ask, ours or theirs
    ask = nil,
    -- Three optional hooks the client installs, all shaped like `fighting`:
    -- `busy()` answers Sessions:isBusy() (mid-trade / mid-1v1-request),
    -- `here()` answers the map this player is standing on, and `toast(text)`
    -- puts one line in the corner of the screen. Coop holds no engine, session
    -- or renderer dependency of its own -- see M:challenge's header -- so all
    -- three are handed in by src/Client.lua and all three are optional:
    -- absent, a join is simply never deferred for a trade, never retried on a
    -- tick, and says what it has to say in the party log alone.
    busy = nil,
    here = nil,
    toast = nil,
    -- Dedupes the "was brave / went 1-on-1" sentence when an offer ends and
    -- a late yes would otherwise say it twice.
    aloneAnnounced = false,
    -- The encounter this player is standing in, while a prompt of ours is up:
    -- { battle, label, map, start }.  `start` is the one continuation that
    -- lets the trainer be fought, and it is held here rather than passed
    -- through each branch because the branch that eventually needs it is often
    -- not the one that was given it -- a player who joins their partner's
    -- fight is released by a message from the hub, three functions away from
    -- the prompt that suspended them.  See M:release.
    encounter = nil,
    -- The box the asker is left looking at after PARTY BATTLE, held so it can
    -- be taken back down: { box, game }.  It deliberately does *not* live on
    -- self.ask -- that is cleared the instant the hub answers, and the box
    -- outlives it by however long the player takes to press A, which is the
    -- whole reason it used to end up buried under a battle screen.
    askBox = nil,
    -- A blackout's warp, waiting for the screen to come free:
    -- { game, target, clock }.  See M:pumpBlackout.
    pendingWarp = nil,
    -- true from handoff until the battle is done; the join door is shut
    running = false,
    clock = 0,
  }, M)
end

-- ------- naming a fight
--
-- What makes two clients agree they are looking at the same trainer.
--
-- Built from the world rather than passed between the players: both sides
-- derive it from the map they are standing on and the trainer's own
-- identifiers, so agreeing is a consequence of being in the same place and not
-- of trusting a string somebody sent.  That matters -- the key is the whole of
-- "the same battle", and a key one side could choose would let a client invite
-- its partner to join a fight that partner is nowhere near.
--
-- The pieces are joined with "|", which M.battleKey's pattern keeps and
-- Wire.text would have stripped; that is the reason it has a sanitiser of its
-- own rather than borrowing the prose one.
function M.battleKey(mapId, ...)
  local parts = { tostring(mapId or "?") }
  for i = 1, select("#", ...) do
    local piece = select(i, ...)
    if piece ~= nil then parts[#parts + 1] = tostring(piece) end
  end
  local key = table.concat(parts, "|"):gsub("[^%w_%.%-:|]", "")
  return key:sub(1, Config.COOP_KEY_MAX)
end

-- Overworld NPC id and event-flag id from the engine battle the waiter (or a
-- walk-in joiner) is standing in front of.
--
-- Taken from `checkpointOrigin` rather than rebuilt from class+lead: Route 3
-- has multiple Bug Catchers, and fuzzy-matching by class would mark the wrong
-- one beaten. Nil is a real answer for wild fights and for fixtures that never
-- stamped an origin.
function M.originOf(engine)
  local origin = engine and engine.checkpointOrigin
  if type(origin) ~= "table" then return nil, nil end
  local npcId = Wire.npcId(origin.npcId)
  local event = Wire.eventFlag(origin.event)
  return npcId, event
end

-- The live overworld under (or beneath) whatever screen is up, for synthetic
-- post-battle work when there is no buried BattleState to hand an onFinish to.
function M.overworldOf(game)
  local world = mod.world
  if world and type(world.overworld) == "function" then
    local ok, ow = pcall(world.overworld, world)
    if ok and ow then return ow end
  end
  local states = game and game.stack and game.stack.states
  if type(states) ~= "table" then return nil end
  for i = #states, 1, -1 do
    local s = states[i]
    if s and type(s.afterBattle) == "function" then return s end
  end
  return nil
end

-- ------- state

function M:reset()
  -- The encounter is released rather than dropped.  Losing the connection
  -- mid-prompt must not leave a player frozen in front of a trainer with a
  -- suspended script and no box on screen -- rule 2 outlives the hub.
  self:release()
  self:closeAskBox()
  self.waiting, self.offer, self.ask = nil, nil, nil
  -- Nothing is coming for the connection that just dropped, so nothing is
  -- being pointed at either.
  self.offerMarkFor = nil
  self.aloneAnnounced = false
  -- Dropped, not fired. The heal and the money are already written to the
  -- save; a warp left armed across a dropped connection would go off in
  -- whatever the player is doing next.
  self.pendingWarp = nil
  self.running = false
  self.clock = 0
end

-- Let the encounter proceed, exactly once.
--
-- Every path out of every prompt this module raises ends here, and the
-- once-only guard is what makes that safe to say: a wait whose clock runs out
-- in the same frame the hub answers it, or a player whose party dissolves in
-- that frame, would otherwise resume one suspended script twice -- and the
-- second resume runs a battle nobody is standing in front of. Let the engine's
-- own battle happen: take down whatever is over it and get out of the way.
--
-- Nothing is resumed and nothing is started, because nothing was ever stopped
-- -- the battle has been sitting there, on screen, the whole time.
function M:release()
  local encounter = self.encounter
  self.encounter = nil
  if not encounter then return false end
  self:unwindTo(encounter.game, encounter.engine, false)
  return true
end

-- The co-op battle happened, so the encounter is spent: let the script that
-- was suspended in front of the trainer carry on, and do *not* fight it again.
--
-- This is the other half of rule 2, and the half that is easy to miss: the
-- rule is that a triggered trainer is always resolved, not that it is always
-- fought by one player. Dropping the encounter instead of consuming it leaves
-- the map script suspended forever, which is a frozen game.
-- The co-op battle stood in for the engine's, so the engine's battle is told
-- how it went and takes it from there: the defeated-trainer flag, the victory
-- rewards, a whiteout on a wipe, and the script that has been waiting in front
-- of the trainer since before the prompt went up.
--
-- Handing the result back rather than reimplementing any of it is the whole
-- reason the battle object was held instead of discarded.
--
-- One thing *is* translated on the way out: the result string. A co-op battle
-- reports "win"/"loss"/"draw"; the overworld's afterBattle runs the blackout
-- for the string **"lose"** and for nothing else. Handing it "loss" was
-- therefore handing it "not a loss" -- every player who lost a co-op trainer
-- battle walked out of it with a fainted party and no whiteout. See
-- M.blacksOut for the rule, which is the same rule on both paths.
--
-- **A win is never translated, even by a player whose own team was wiped.**
-- That string is not only a blackout switch: Commands.start_battle reads it
-- back as `ctx.lastCheck = (result == "win")`, which is what the map script
-- standing in front of the trainer branches on and what marks them beaten.
-- Calling a won battle a loss to get the ritual would mark the trainer
-- undefeated on this client and beaten on their partner's -- two worlds that
-- disagree about a gym, from one player's fainted party. So the win goes
-- through as a win, the script and the rewards run, and the ritual that player
-- is still owed is run afterwards by M:blackout. The ritual is owed to the
-- player; the defeat flag is owed to the world.
--
-- `blackout` is decided by the caller and handed in, because deciding it here
-- would mean asking whether the party is wiped *after* something may already
-- have healed it. Answers whether the engine took the ritual on.
--
-- The ritual itself is M.finishBuriedBattle, immediately below, which takes
-- the buried battle and the game as arguments instead of reading them off an
-- encounter. What is left here is the part that is genuinely co-op's: the
-- encounter slot is cleared *first* and unconditionally -- a consume that
-- found nothing still spends the encounter -- and "there is nothing held" is
-- answered `false` before the ritual is ever reached. Both return values pass
-- straight through, so a caller reading `handled, engineRitual` sees exactly
-- what it always saw.
function M:consume(result, blackout)
  local encounter = self.encounter
  self.encounter = nil
  if not encounter then return false end
  return M.finishBuriedBattle(encounter.engine, encounter.game, result, blackout)
end

-- ------- the ritual, without a co-op encounter wrapped around it
--
-- Lifted out of M:consume so a second caller can run it. src/SoloBattle.lua
-- substitutes this mod's battle system for ordinary wild and trainer fights
-- with no hub, no partner and no network at all -- and it still ends up in
-- exactly the position co-op is in when a fight ends: a frozen engine
-- BattleState sitting on the stack underneath, owed a result it could not
-- compute for itself. What follows is the thing it is owed.
--
-- It is extracted rather than copied because every line of it is a bug that
-- was already paid for once -- the prize the engine cannot pay for a battle it
-- did not run, the ordering against the blackout, the Gen 1 / Gen 2 field
-- aliasing, the pcall that hands the ritual back to the caller when the engine
-- throws. A second copy would drift from this one and re-earn all four.
--
-- Statics, not methods: they read nothing off `self`, take everything they use
-- as arguments, and are therefore callable from a sibling module loaded
-- through the same need() resolver as `Coop.finishBuriedBattle(...)`.

-- Prize money, which the engine pays from inside its own battle screen and
-- so never gets to pay for one it did not run. Its formula, at the level of
-- the strongest monster the trainer had -- a 2-on-2 has two last opponents,
-- and paying for the better of them is the reading that cannot be gamed by
-- ordering the party.
--
-- A wild encounter and a lost fight both land here and both pay nothing: the
-- `result == "win" and trainer` gate is what makes this safe to call
-- unconditionally, which is why the caller below does not repeat it.
function M.payTrainerPrize(engine, game, result)
  if not engine then return 0 end
  local trainer = engine.trainer
    or (engine.battle and engine.battle.trainer)
  local enemyParty = engine.enemyParty
    or (engine.battle and engine.battle.enemyParty)
  if result == "win" and trainer then
    local best = 0
    for _, mon in ipairs(enemyParty or {}) do
      best = math.max(best, tonumber(mon.level) or 0)
    end
    local prize = (tonumber(trainer.baseMoney) or 0) * best
    local save = game and game.save
    if prize > 0 and save then
      Gen.money.set(save, math.min(999999, Gen.money.get(save) + prize))
      return prize
    end
  end
  return 0
end

-- Which of a buried battle's two callbacks is the one that will actually run.
--
-- Gen 1 BattleState uses onFinish; Gen 2's ui/gen2/BattleState uses onDone
-- (Client stamps onFinish from onDone when present, but accept either), so a
-- Gold battle usually carries both fields pointing at the same function.
--
-- Exported, and the selection lives here alone, because a caller that needs to
-- reason about *what that function does* has to be reasoning about the same
-- function this ritual calls. src/SoloBattle.lua asks exactly that -- "does the
-- ritual take the battle off the stack for itself?" -- and it used to ask it of
-- `engine.onDone` while the ritual called a different `engine.onFinish`. On a
-- Gold battle pushed by something other than World:startBattle those two are
-- not the same function and do not agree about the pop, and the player was left
-- standing on a battle that had already been told it was over.
function M.buriedFinisher(engine)
  local finish = engine and (engine.onFinish or engine.onDone)
  if type(finish) ~= "function" then return nil end
  return finish
end

-- Tell the buried engine battle how the fight it never ran went.
--
-- `engine` is the frozen BattleState underneath, `game` is what holds the
-- save, `result` is "win"/"loss"/"draw" and `blackout` is the caller's already-
-- taken decision (see M.blacksOut) about whether this player's own team is
-- wiped. Returns the same pair M:consume has always returned: whether there
-- was anything to finish at all, and -- when there was -- whether the engine
-- ran the blackout ritual itself so the caller must not run a second one.
function M.finishBuriedBattle(engine, game, result, blackout)
  local finish = M.buriedFinisher(engine)
  if not finish then return false end

  M.payTrainerPrize(engine, game, result)

  -- Paid *before* the blackout, and halved by it, which is the order vanilla
  -- uses too: BattleState pays PAY DAY and the prize inside the battle, and
  -- only then does the whiteout tax what is left.
  local outcome = result or "draw"
  local engineRitual = false
  if blackout and outcome ~= "win" then
    outcome = "lose"
    engineRitual = true
  end

  local ok, err = pcall(finish, outcome)
  if not ok then
    mod.log:warn("the trainer battle could not be finished off (%s); if the "
      .. "world seems stuck, reload from your last save", tostring(err))
    -- The engine never got as far as its own ritual, so the caller's is the
    -- only one this player is going to get.
    engineRitual = false
  end
  return true, engineRitual
end

-- ------- blacking out
--
-- **One rule, applied per client, on both paths.**
--
-- The obvious half is that a party which lost blacks out. The other half is
-- the engine's own safety net, adopted here because co-op steps around the
-- place it lives: BattleState:finish() forces `lose` on any result that ends
-- with nothing healthy left, and calls that state "unrecoverable, not merely
-- wrong" in its own comment. A co-op battle never runs finish() -- consume
-- calls onFinish directly, which is what lets it pay a prize the engine could
-- not -- so the net has to be re-hung here. It matters in a 2-on-2 in a way it
-- barely does in a 1-on-1: a team can be wiped out while its *partner* wins
-- the battle, and that player would otherwise stand up in the overworld with
-- six fainted monsters and a victory.
--
-- A save with no party at all is not that player. It is a headless load, a
-- title screen, a harness -- a state with no team to have lost, and rewriting
-- somebody's money and position over it would be the mod inventing a defeat.
--
-- Already a static taking only what it inspects, so it needs no extraction to
-- serve a second caller: a solo fight asks the same question of the same save,
-- and "the party has nothing standing" does not become a different rule
-- because there was nobody else in the battle. Nothing here counts partners or
-- looks at a co-op field, so a lone player's wiped team answers `true` exactly
-- as one half of a 2-on-2's does.
function M.blacksOut(result, game)
  if result == "loss" then return true end
  local party = game and game.save and game.save.party
  if type(party) ~= "table" or #party == 0 then return false end
  for _, mon in ipairs(party) do
    if (tonumber(mon.hp) or 0) > 0 then return false end
  end
  return true
end

-- Where a blackout returns to. Prefer the live overworld's own healPoint
-- (Gen 1 OverworldState and Gen 2 World both expose it), then Gen 2's
-- save.spawn / landmarks table, then the Gen 1 lastHeal / boot path.
--
-- Nil is a real answer for a build with no field data at all, and the
-- caller declines to warp rather than guessing a map name.
function M.healPoint(game)
  local world = mod.world
  local ow = world and type(world.overworld) == "function" and world:overworld() or nil
  if ow and type(ow.healPoint) == "function" then
    local ok, target = pcall(function() return ow:healPoint() end)
    if ok and type(target) == "table" and target.map then return target end
    if not ok then
      mod.log:warn("overworld healPoint failed (%s); falling back to save "
        .. "spawn / lastHeal", tostring(target))
    end
  end

  local save = game and game.save
  if save and save.spawn then
    local landmarks = (ow and ow.landmarks)
      or (game and game.data and game.data.landmarks)
    local row = landmarks and landmarks.spawns and landmarks.spawns[save.spawn]
    if type(row) == "table" and row.map then
      return { map = row.map, x = row.x, y = row.y, spawn = save.spawn }
    end
  end

  local last = save and save.lastHeal
  if last and last.map then return last end
  local data = game and game.data
  local boot = (data and data.field and data.field.boot) or {}
  if boot.lastHeal and boot.lastHeal.map then return boot.lastHeal end
  if boot.startMap then
    return { map = boot.startMap, x = boot.startX, y = boot.startY }
  end
  return nil
end

-- The Pokémon Center heal, written into the save.
--
-- A mirror of Pokemon.heal (full HP, status cleared, every move's PP back to
-- base plus its PP UP bonus) rather than a call to it: requiring an engine
-- module from mod code is exactly what the permissions tripwire is for, and
-- these are fields this mod already reads to pack a party for the wire. The
-- divergence is deliberate and worth naming -- if the engine's heal ever grows
-- a step, this copy will not have it.
function M.healParty(game)
  local party = game and game.save and game.save.party
  if type(party) ~= "table" then return false end
  local moves = game.data and game.data.moves
  for _, mon in ipairs(party) do
    if mon.stats and mon.stats.hp then mon.hp = mon.stats.hp end
    mon.status = nil
    for _, mv in ipairs(mon.moves or {}) do
      local def = moves and moves[mv.id]
      -- RestoreBonusPP adds maxPP/5 per PP UP, floored -- and a move this
      -- build has no record of is left exactly as it was rather than given a
      -- PP figure invented from nothing.
      if def and def.pp then
        mv.pp = def.pp + (tonumber(mv.ppUps) or 0) * math.floor(def.pp / 5)
      end
    end
  end
  return true
end

-- How long the deferred warp below will wait for the screen to come free.
--
-- Everything it waits on is a post-battle menu the player is standing in front
-- of and cannot walk away from, so in practice it is seconds. The bound exists
-- for the case where the world never comes back on top at all -- a script
-- warped them somewhere, a screen got stuck -- because a warp that fires
-- minutes later, wherever the player has wandered to by then, is worse than
-- one that never fires and says so.
local BLACKOUT_WARP_WAIT = 60

-- The whole ritual, for the battle the engine never ran.
--
-- A party-versus-party co-op battle displaces no engine battle -- there was no
-- trainer to walk into -- so there is no `onFinish` to hand a result to and
-- nothing anywhere that will black anybody out. Without this the losing pair
-- simply stood up where they were, at zero HP, with no way back to a Center
-- except walking there with a fainted team. The other caller is a *won* co-op
-- trainer battle that left this player's own team wiped, where the engine ran
-- everything except the ritual -- see M:consume for why that win stays a win.
--
-- Each client runs its own, which is the point: "everybody wakes up in their
-- own last Pokémon Center" is not something one host could decide for four
-- saves it does not hold.
--
-- Heal, tax, then warp -- vanilla's order, and the safe one: a warp that
-- cannot be made still leaves a healed party rather than a stranded one.
--
-- The first two happen now and the third waits, because they are different
-- kinds of act. Healing and taxing are save writes: invisible, and wanted
-- before the engine's own post-battle flow runs, so evolutions and rewards see
-- the party the player will actually walk away with. The warp is a screen --
-- it pushes a Transition -- and there may well be one or two already up by the
-- time this is reached: a forget-a-move menu for a level-up, an evolution the
-- engine offered. Starting a map transition underneath those freezes it behind
-- a menu and then fades the world out from under whatever the player was
-- reading. See M:pumpBlackout.
--
-- Written as a method but holding nothing of co-op's: `self` is used for one
-- field, `pendingWarp`, which is the deferred warp's parking space and the
-- reason this cannot be a plain static -- somebody has to remember the warp
-- across the frames it waits for. That makes `self` a *holder* rather than a
-- Coop instance, and a sibling module with its own table can run the ritual as
-- `Coop.blackout(self, game)` so long as it also pumps it every frame with
-- `Coop.pumpBlackout(self, dt)`. Nothing below reads a party, a transport or a
-- roster, so a lone player's blackout is the same blackout.
--
-- ------- and the four things it may have to say
--
-- The ritual is holder-agnostic but its warnings were not: every one of them
-- named the 2-on-2, because for a long time a 2-on-2 was the only fight that
-- could reach here. A lone player who blacks out of a solo wild encounter and
-- is then told that "a lost 2-on-2 could not black you out" is being told
-- about a feature they were not using, which is worse than saying nothing --
-- it sends them looking for a partner that was never there.
--
-- So the noun is an argument. `context` is the word the four warnings use for
-- the fight that was lost, it defaults to "2-on-2", and every existing caller
-- passes nothing -- which is why co-op's four lines are still, to the byte,
-- the four lines it has always printed. `src/SoloBattle.lua` passes "battle".
--
-- Parked on `pendingWarp` rather than taken again by the pump, because the
-- deferred half runs frames later and the holder is the only thing that
-- crosses that gap: a pump that had to be told the noun every frame would be
-- one more thing a second caller could get wrong, and its default would be
-- co-op's word on a solo player's screen again.
function M:blackout(game, context)
  local save = game and game.save
  local noun = (type(context) == "string" and context ~= "") and context
    or "2-on-2"
  if not save then
    mod.log:warn("a lost %s could not black you out (no save); walk to a "
      .. "POKéMON CENTER to heal", noun)
    return false
  end

  M.healParty(game)
  -- The world's own divisor if it names one, read off data the same way
  -- badgesOf reads the badge rows -- a mod that retunes the penalty retunes it
  -- here too. Two is vanilla.
  local world = game.data and game.data.constants and game.data.constants.world
  local divisor = tonumber(world and world.blackoutMoneyDivisor) or 2
  if divisor > 0 then
    Gen.money.set(save, math.floor(Gen.money.get(save) / divisor))
  end
  -- DisplayPlayerBlackedOutText clears BIT_ALWAYS_ON_BIKE; a player who blacks
  -- out on a forced-bike route wakes up on foot, not pedalling indoors.
  save.forcedBike = nil

  local target = M.healPoint(game)
  local api = mod.world
  if not (api and target and target.map) then
    -- Healed and taxed but not moved. Said out loud rather than silently
    -- half-done: the player is standing somewhere they did not expect to be.
    mod.log:warn("a lost %s healed your party but could not send you to a "
      .. "POKéMON CENTER; walk out and back in, or reload your last save", noun)
    return false
  end
  self.pendingWarp = { game = game, target = target, clock = 0, context = noun }
  -- Called through M rather than off `self` so a holder that is not a Coop
  -- instance -- see the note above -- still reaches the pump. For a real Coop
  -- instance this resolves to the identical function `self:pumpBlackout(0)`
  -- found through __index, so the first-frame attempt is unchanged.
  return M.pumpBlackout(self, 0)
end

-- The waiting half of the ritual: warp as soon as the world is what the player
-- is looking at, and not before.
--
-- "Nothing on top of the overworld" is asked of the stack rather than tracked,
-- because the things that can be on top of it are not all this module's to
-- know about -- the forget-a-move menu is ours, the evolution the engine
-- offered is not, and a mod counting the screens somebody else pushed is a mod
-- that will one day miscount. isOverworld is the same marker WorldAPI itself
-- resolves the world by.
--
-- Called every frame from M:update, and once from M:blackout so the ordinary
-- case -- no menus, the world already back -- does not wait a frame for it.
function M:pumpBlackout(dt)
  local pending = self.pendingWarp
  if not pending then return false end

  -- The noun M:blackout parked here, for the two warnings below. Defaulted a
  -- second time rather than trusted, because a holder can be handed a warp
  -- table by a suite that never went through blackout at all.
  local noun = (type(pending.context) == "string" and pending.context ~= "")
    and pending.context or "2-on-2"
  pending.clock = (pending.clock or 0) + (dt or 0)
  local stack = pending.game and pending.game.stack
  local top = stack and stack.top and stack:top()
  if not (top and top.isOverworld) then
    if pending.clock < BLACKOUT_WARP_WAIT then return false end
    -- Given up on rather than fired blind. The party is healed and the money
    -- is already gone, so this is a player standing in the wrong place, not a
    -- player stuck at zero HP.
    self.pendingWarp = nil
    mod.log:warn("your party was healed after the %s but the trip to a "
      .. "POKéMON CENTER never got a chance to start; walk there, or reload "
      .. "from your last save", noun)
    return false
  end

  self.pendingWarp = nil
  local api = mod.world
  local target = pending.target
  if not (api and target) then return false end
  -- No arrival FX: a blackout is not a Fly and not a Teleport, and vanilla
  -- lands the player in front of the nurse with no poof.
  --
  -- The engine's own ritual also emits world.blacked_out here. A mod may only
  -- emit under its own namespace -- forging an engine event is exactly what
  -- Events refuses -- so listeners on that event do not see a co-op blackout.
  -- Named because it is a real divergence, and the seam that would close it
  -- (a WorldAPI:blackout()) is an upstream change, not a local one.
  --
  -- Two ways to fail and both are answered the same way: warpTo *returns*
  -- nil plus a reason when there is no overworld under us or the map is
  -- unknown, and throws for anything else.
  local ok, done, why = pcall(api.warpTo, api, target.map, target.x, target.y,
                              "down")
  if not (ok and done) then
    mod.log:warn("a lost %s healed your party but the warp to a POKéMON "
      .. "CENTER failed (%s); reload from your last save if you are stuck",
      noun, tostring(ok and why or done))
    return false
  end
  return true
end

function M:isWaiting() return self.waiting ~= nil end

-- The partner's standing offer, if there is one and it has not gone stale.
-- Read rather than reached for directly so that every caller -- the ACTIONS
-- menu, the trainer trigger, the suite -- asks the same question.
function M:pendingOffer()
  return self.offer
end

-- Is this offer about the fight in front of us?  The one test that turns "my
-- partner is waiting somewhere" into "my partner is waiting *here*", and the
-- reason a player crossing a route is never asked to join a battle three
-- screens away.
function M:offerMatches(key)
  local offer = self.offer
  return offer ~= nil and key ~= nil and offer.battle == key
end

function M:note(text)
  if not (self.chat and text) then return nil end
  return self.chat:push({
    name = "PARTY", scope = "party", text = text, outgoing = true,
  })
end

-- The corner of the screen, for a line whose moment is too short to be read
-- anywhere else.
--
-- A note goes in the party scrollback, which is the right home for the record
-- and the wrong one for the news: it is invisible unless the chat window is
-- open.  That is survivable for everything here except the join, whose whole
-- window is the fraction of a second before the battle covers the overworld --
-- the same fraction the "!" mark has, and the reason the mark alone was never
-- enough.  A toast is drawn in window space after the overlay and behind no
-- free-roam gate (src/Toast.lua, and src/Client.lua's render.hud wrap), so it
-- is the one thing this module can say that survives its own battle screen.
--
-- Both, never either: the note is the history, the toast is the moment.
function M:toastLine(text)
  local push = self.toast
  if not (text and type(push) == "function") then return false end
  local ok, err = pcall(push, text)
  if not ok then
    self.toast = nil
    mod.log:warn("a co-op line could not be shown in the corner (%s); it is "
      .. "still in the party chat log (START > MMO > CHAT)", tostring(err))
    return false
  end
  return true
end

-- What to call a fight in a sentence.  A script-driven battle need not name
-- its trainer, and "a battle" is a better answer than refusing the whole offer
-- over a cosmetic field.
local function fightName(label)
  return label or "a battle"
end

-- ------- against an NPC: the player who arrives first
--
-- Called when the engine has just pushed a trainer battle.
--
-- **Nothing is asked, and nothing is shown.**  Being in a party *is* the
-- consent for co-op battles, so a partied player who walks into a trainer with
-- an online partner on this map goes straight into the wait: COOP_WAIT out,
-- the engine's own encounter presentation left on screen, the partner auto-
-- joining a second later.  A player who does not want their fights turned into
-- 2-on-2s cancels the party; a player who has stopped wanting *this* one just
-- fights it -- SOLO_FALLBACK_AFTER hands the trainer back if the join has not
-- landed by then. Those are the outs, and they are why the question stopped
-- being worth asking.
--
-- **Same map is a hard gate**, exactly as it always was on the wild path (see
-- M:onWildEncounter, which refuses on `partnerOnMap` before anything is sent).
-- A wait used to be allowed to stand for a partner three screens away, on the
-- theory that they would walk over -- but the whole shape of this flow now is
-- that the engine's encounter covers the round trip, and no encounter covers a
-- walk. A partner who is not here is told so once and the trainer is fought
-- the ordinary way: no offer posted, nothing to withdraw, nothing to time out.
--
-- **The battle object is the whole trick here.** It has already been built and
-- pushed by the engine -- its enemy party is real, its `onFinish` is wired to
-- the overworld's entire post-battle flow (the defeated-trainer flag, victory
-- rewards, the whiteout, the script that was waiting) -- and none of that is
-- anything a mod should be reimplementing.
--
-- So the co-op path stands in for it rather than replacing it, and the two
-- endings do very different things with almost no code:
--
--   * The timeout (and every other release) simply lets go. The engine's
--     battle has been on screen the whole time and was never touched at all.
--   * The co-op path pops it, holds it, fights the 2-on-2 in its place, and
--     then calls its `onFinish` with the result -- so the trainer is marked
--     beaten, the badge is awarded, a wipe blacks you out and the script
--     carries on, exactly as if one player had fought it.
--
-- Returns true when this module took the encounter over (a wait is out, or a
-- join is under way). False means the encounter is none of this module's
-- business, and the engine's battle is left completely alone -- which is the
-- answer for a player who is not in a party or not connected: co-op is an
-- addition to the game, and a lone player must never notice it exists.
function M:onTrainerBattle(game, state, mapId)
  if not state then return false end
  -- Gen 2 BattleState has no `.kind`; the trainer record sits on state.battle.
  local kind = state.kind
  if not kind and state.battle and state.battle.trainer then kind = "trainer" end
  if kind ~= "trainer" then return false end
  if not (self.transport:isReady() and self.party:has()) then return false end
  if self.running then return false end
  -- Partner has to be online (in the roster). Offline / no partner means this
  -- is a solo fight, and a lone player must never notice co-op exists -- so
  -- that case is silent, and only this one is.
  local partner = self.party:partner()
  local here = partner and self.roster:get(partner.id)
  if not here then return false end
  -- ...and standing on this map. Refused *before* the encounter is claimed and
  -- before anything is sent: no COOP_WAIT, no offer for the partner to hold,
  -- no wait to time out. The player is simply told why their partner is not in
  -- this fight and left to fight it.
  --
  -- Said with a box over the trainer the engine just pushed, which is the same
  -- surface every other pre-battle line in this module uses (M:onDecline's
  -- pair, M:onPartyEnd's "There's nobody to wait for"): a StateStack only
  -- updates its top, so the battle underneath is held until the player presses
  -- A and then resumes untouched. Nothing is released, because nothing was
  -- ever taken -- `self.encounter` is not set on this path at all.
  if not self:partnerOnMap(mapId) then
    local who = (partner and partner.name) or self.party:partnerName()
      or "Your friend"
    local line = ("%s was too far\nto join!"):format(who)
    self:note(line)
    self.ui:say(line)
    return false
  end

  local trainer = state.battle and state.battle.trainer
  local oppClass = state.oppClass
    or (trainer and (trainer.classId or trainer.class))
  local enemyParty = state.enemyParty
    or (state.battle and state.battle.enemyParty)
  local label = Wire.label(tostring(oppClass or ""):gsub("^OPP_", "")
    :gsub("_", " "))
  -- The trainer class alone is not quite specific enough: one map can hold two
  -- of the same class with different parties. The lead monster's species and
  -- level tell those apart, and both partners derive them from the battle their
  -- own engine just built -- so they agree by both looking at the same trainer
  -- rather than by trusting a value one of them sent.
  local lead = enemyParty and enemyParty[1]
  local key = M.battleKey(mapId, oppClass,
    lead and lead.species, lead and lead.level)
  -- Concrete overworld id (and event flag) from the engine's checkpoint --
  -- what an invite joiner needs on the wire so they never fuzzy-match a Bug
  -- Catcher by class. See M.originOf / PROTOCOL 20.
  local npcId, event = M.originOf(state)

  self.encounter = {
    battle = key,
    label = label,
    map = mapId,
    -- The engine's own battle, held so the co-op path can hand it its result.
    engine = state,
    game = game,
    npcId = npcId,
    event = event,
  }

  -- We walked into the fight our partner is already standing at. Nothing left
  -- to agree about, so nothing is asked: take their offer. The engine trainer
  -- underneath stays exactly where it is -- startBattle adopts it through
  -- joinedEngine (same key, by construction), and a join the hub drops too
  -- late leaves the player fighting it alone, which is rule 2.
  if self:offerMatches(key) then
    return self:autoJoin(self.offer)
  end
  -- No ask: the party already answered it. beginWait only fails with no
  -- encounter, which cannot happen a dozen lines after one was built -- but if
  -- it ever does, the honest answer is to drop the claim and leave the
  -- engine's trainer alone rather than hold a claim on an encounter with no
  -- offer out.
  if self:beginWait() then return true end
  self.encounter = nil
  return false
end

-- The wild mon the engine just built, for a grant and for the battle key.
--
-- Wild BattleState keeps the mon on `enemy.mon` (newWild never fills
-- enemyParty). Trainer battles put it in enemyParty[1]. Gen 2's screen holds
-- the Battle on `state.battle`, where the foe is `battle.enemy` (a Mon) or
-- `battle.enemyParty[1]`. All shapes are accepted so a headless fixture that
-- only stubs enemyParty still works.
function M.wildMonOf(state)
  if type(state) ~= "table" then return nil end
  local mon = state.enemyParty and state.enemyParty[1]
  if mon then return mon end
  local enemy = state.enemy
  if enemy and enemy.mon then return enemy.mon end
  local battle = state.battle
  if type(battle) == "table" then
    mon = battle.enemyParty and battle.enemyParty[1]
    if mon then return mon end
    if battle.enemy then return battle.enemy end
  end
  return nil
end

-- Called when the engine has just pushed a wild encounter.
--
-- Divert only when partied, the partner is roster-online on *this* map, and
-- neither side is busy. Busy here is: we are already mid-co-op / mid-ask /
-- mid-wait, another fight is already on the stack (excluding this just-pushed
-- wild), or their presence says session-busy. Otherwise return false and leave
-- the engine wild completely alone.
--
-- Exception: a standing `coop_wild` offer from the partner means they already
-- diverted -- join that fight instead of opening a second wait (and drop the
-- just-pushed local wild so it cannot be fought under/after the join). A
-- trainer offer still refuses divert (solo engine wild).
--
-- beginWildCoop posts COOP_WAIT and leaves the engine wild running: the host
-- watches their own "Wild X appeared!" for the second the partner's auto-join
-- takes (see considerOffer), and startBattle stands in for that wild whether
-- or not the player has started fighting it.
function M:onWildEncounter(game, state, mapId)
  if not state then return false end
  -- Gen 2 BattleState has no `.kind`; a wild fight carries state.battle.wild.
  local kind = state.kind
  if not kind and state.battle and state.battle.wild then kind = "wild" end
  if kind ~= "wild" then return false end
  if not (self.transport:isReady() and self.party:has()) then return false end
  if self.running or self.waiting or self.ask then return false end
  if self.offer then
    if self.offer.mode ~= "coop_wild" then return false end
    -- Partner already waiting on grass: join them; do not start a local wait.
    if not self:partnerOnMap(mapId) then return false end
    if self:inFightExcept(game, state) then return false end
    local partner = self.party:partner()
    local row = partner and self.roster:get(partner.id)
    if row and row.busy then return false end
    -- Asked here rather than left to autoJoin, because the pop below is not
    -- reversible: a join refused after it would cost the player the encounter
    -- they walked into. The offer stays standing for M:update's retry.
    if self:sessionBusy() then return false end
    local offer = self.offer
    -- Pop the just-pushed wild; their battle key will not match ours, so
    -- joinedEngine would leave this fight under the co-op screen otherwise.
    if game and game.stack and game.stack:top() == state then
      game.stack:pop()
    end
    return self:autoJoin(offer)
  end
  if not self:partnerOnMap(mapId) then return false end
  local partner = self.party:partner()
  local row = partner and self.roster:get(partner.id)
  if row and row.busy then return false end
  if self:inFightExcept(game, state) then return false end

  local mon = M.wildMonOf(state)
  if not mon then return false end
  local species = mon.species
  local label = Wire.label(tostring(species or ""):gsub("_", " "))
  local key = M.battleKey(mapId, species, mon.level)

  self.encounter = {
    battle = key,
    label = label,
    map = mapId,
    engine = state,
    game = game,
    kind = "wild",
    wildCatchMon = mon,
  }
  return self:beginWildCoop()
end

-- Start a Party vs Wild wait: same wire as a trainer wait, and the same
-- absence of anything on screen. The engine wild stays exactly where it is and
-- keeps running -- its own "Wild X appeared!" and send-out are what the waiter
-- watches while the round trip happens. Short clock applies -- see M:update.
--
-- Nothing is asked here either, and never was: this path is the one the
-- trainer path was rewritten to match, twice now.
--
-- The encounter is held (not released) so a timed-out wait can still hand the
-- engine wild back via release(), and a successful join can hand it to
-- startBattle the same way the trainer path does.
function M:beginWildCoop()
  local encounter = self.encounter
  if not (encounter and encounter.kind == "wild") then return false end
  if not self.transport:isReady() then return false end
  self.waiting = {
    battle = encounter.battle,
    label = encounter.label,
    map = encounter.map,
    engine = encounter.engine,
    game = encounter.game,
    kind = "wild",
    mode = "coop_wild",
    wildCatchMon = encounter.wildCatchMon,
    clock = 0,
  }
  self.transport:send(Wire.COOP_WAIT, {
    battle = encounter.battle,
    label = encounter.label,
    map = encounter.map,
    mode = "coop_wild",
  })
  return true
end

-- Is this state still on the stack at all?
--
-- Three answers, not two: true, false, and *nil* for "this stack cannot say".
-- A caller that treats "cannot say" as "no" would refuse to unwind anything at
-- all against a stack that only offers a top, and a caller that treats it as
-- "yes" is exactly as safe as it was before this existed. Both readings are
-- used below.
--
-- The answer is a property of the stack and the target and of nothing else, so
-- the work is a static and the method is a one-line forward to it. Both forms
-- are kept deliberately: every caller in this file and in the suites reaches it
-- as `coop:onStack(...)`, and a sibling module holding a game but no Coop
-- instance reaches the same answer as `Coop.stackHolds(game, target)`.
function M.stackHolds(game, target)
  local stack = game and game.stack
  local states = stack and stack.states
  if not (target and type(states) == "table") then return nil end
  for i = #states, 1, -1 do
    if states[i] == target then return true end
  end
  return false
end

function M:onStack(game, target) return M.stackHolds(game, target) end

-- Take everything above `target` off the stack, and optionally `target` too.
--
-- The prompt is one or two widget states deep depending on how far the player
-- got, so this unwinds by identity rather than by counting -- a fixed number of
-- pops is a guess, and a wrong guess here either leaves a menu on screen or
-- eats the world underneath it.
--
-- Static plus method wrapper for the same reason M.stackHolds is: unwinding
-- reads nothing off a Coop instance, and the caller that most needs it next is
-- a solo battle burying an engine BattleState under exactly the same pile of
-- text boxes and transitions. `Coop.unwindStackTo(game, target, alsoPop)` from
-- a sibling; `self:unwindTo(...)` everywhere it already is.
function M.unwindStackTo(game, target, alsoPop)
  local stack = game and game.stack
  if not (stack and target) then return false end
  -- Never go looking for something that is not there.
  --
  -- The loop below stops on identity or on a guard of sixteen, and there is no
  -- third way out -- so a target that has already left the stack does not fail
  -- to find it, it takes sixteen screens down with it hunting for it. Mid-
  -- battle that is the battle and the world underneath.
  --
  -- A held reference outliving its state is not an exotic condition: a battle
  -- that finishes itself pops itself, and every reference anybody kept to it
  -- is stale from that instant. So this is checked rather than assumed, and
  -- the answer to a stale target is to do nothing at all.
  if M.stackHolds(game, target) == false then return false end
  local guard = 0
  while stack:top() and stack:top() ~= target and guard < 16 do
    stack:pop()
    guard = guard + 1
  end
  -- **The guard tripping is not the same thing as arriving**, and until this
  -- said so it was reported as one: sixteen pops that never reached the target
  -- returned `true` exactly as a clean unwind did, and `alsoPop` -- the whole
  -- point of the call on the losing path -- silently never happened.
  --
  -- Harmless while every caller ignored the answer. Not harmless for
  -- src/SoloBattle.lua, which unwinds to a buried BattleState and then tells it
  -- it was won: a target still on the stack under a pile too deep to clear
  -- would be marked beaten *and* left where it is, so it resumes the moment the
  -- pile comes off and the player fights the same trainer a second time. False
  -- is what lets that caller decline to finish a battle it could not reach.
  --
  -- Only the guard case is new. A target that had already left the stack has
  -- answered `false` from the line above since that check was written.
  if stack:top() ~= target then return false end
  if alsoPop then stack:pop() end
  return true
end

function M:unwindTo(game, target, alsoPop)
  return M.unwindStackTo(game, target, alsoPop)
end

-- Whether the partner is currently standing on `mapId`.
--
-- Absence (offline, no roster row) is not "elsewhere" -- it is nobody to wait
-- for, and onTrainerBattle refuses that case one line above the one that asks
-- this. Both answers now end the same way on both flows: no divert.
function M:partnerOnMap(mapId)
  if not mapId then return false end
  local partner = self.party:partner()
  local row = partner and self.roster:get(partner.id)
  return row ~= nil and row.map == mapId
end

-- Start waiting, and tell the partner.
--
-- Called straight from onTrainerBattle -- there is no choice and no cover in
-- front of it any more, so this is the whole of what triggering a trainer with
-- a partner standing here *does*: one message, one line in the party log, and
-- the engine's encounter left running on screen.
--
-- The encounter is deliberately *not* released here: this is the one branch
-- that does not end in a battle straight away, and holding the continuation is
-- what lets the co-op path hand the engine's trainer its result later.
-- Everything that ends the wait -- joining, the clock, the party dissolving,
-- the connection dropping -- releases it.
--
-- The partner is on this map by the time this runs (onTrainerBattle's gate),
-- so there is one wording rather than two.
function M:beginWait()
  local encounter = self.encounter
  if not encounter then return false end
  self.waiting = {
    battle = encounter.battle,
    label = encounter.label,
    map = encounter.map,
    -- The engine battle rides along, because the wait may end long after the
    -- prompt that started it and the co-op path still needs something to hand
    -- its result to.
    engine = encounter.engine,
    game = encounter.game,
    npcId = encounter.npcId,
    event = encounter.event,
    clock = 0,
  }
  local payload = {
    battle = encounter.battle,
    label = encounter.label,
    map = encounter.map,
  }
  -- PROTOCOL 20: concrete overworld id for invite joiners. Only on the
  -- trainer path -- wild waits have no defeatedTrainers key to set.
  if encounter.npcId then payload.npcId = encounter.npcId end
  if encounter.event then payload.event = encounter.event end
  self.transport:send(Wire.COOP_WAIT, payload)
  local name = self.party:partnerName() or "your friend"
  self:note(("Waiting for %s at %s."):format(name, fightName(encounter.label)))
  return true
end

-- **There is no wait cover, and its absence is the design.**
--
-- There used to be one -- a "Waiting for NAME..." choose box with a single
-- ALONE row -- pushed over the engine's battle so the engine's battle could
-- not update while the offer was out. It is gone, and nothing replaced it.
--
-- The reason is arithmetic: the auto-join round trip is sub-second on a live
-- hub, and a box that is up for a fraction of a second is not a screen, it is
-- a flicker. Everything it was carrying has somewhere better to be:
--
--   * *"who am I waiting for"* -- the engine is already showing the encounter
--     the wait is about, and the party log carries the sentence (beginWait's
--     note). The joiner's end of it is the "!" mark and the toast (M:autoJoin).
--   * *the ALONE row* -- replaced by the two gates that made it redundant:
--     same map (M:onTrainerBattle) refuses the case a player would have taken
--     it in, and SOLO_FALLBACK_AFTER (M:update) takes it for them in the case
--     that is left, with the trainer already on screen and playable.
--   * *freezing the engine's battle* -- deliberately given up. The waiter can
--     start fighting the trainer solo in the second before the join lands;
--     startBattle unwinds that battle and stands in for it either way, which
--     is exactly what it does for a walk-in joiner who did the same thing.
--
-- What is left is that the two clients look the same during the wait: both
-- watching an engine encounter, one of them about to be replaced.
--
-- Take our offer off the table.  Safe to call when there is none: every exit
-- from a fight goes through here, and making each of them check first would be
-- four places to forget.
function M:withdraw(reason)
  if not self.waiting then return false end
  self.waiting = nil
  self.transport:send(Wire.COOP_CANCEL, { reason = Wire.coopReason(reason) })
  return true
end

-- Mid-trade, as Sessions sees it.
--
-- A join is a battle screen pushed over whatever is there, and pushing one
-- over a live trade is the one thing an automatic pull must never do: the
-- other side of that trade is a third player watching a screen that stopped
-- answering. So it is a gate rather than a race, and the offer it refuses is
-- kept -- M:update takes it again once the trade is done.
--
-- pcall'd, and "cannot say" is answered as not-busy: a hook that throws must
-- cost the player nothing worse than a join they were expecting anyway. Warned
-- once, not once a tick, because the retry asks this twice a second.
function M:sessionBusy()
  local hook = self.busy
  if type(hook) ~= "function" then return false end
  local ok, busy = pcall(hook)
  if not ok then
    if not self.busyWarned then
      self.busyWarned = true
      mod.log:warn("could not tell whether a trade is in progress (%s); co-op "
        .. "joins are taken immediately -- finish a trade before joining",
        tostring(busy))
    end
    return false
  end
  return busy == true
end

-- One sentence for "they went in alone", shared by the offer ending while it
-- still stands and by a join that arrives after the wait is already over -- so
-- a race cannot print it twice.
function M:announceAlone(name, onDone)
  if self.aloneAnnounced then
    if onDone then onDone() end
    return false
  end
  self.aloneAnnounced = true
  local who = name or self.party:partnerName() or "Your friend"
  self.ui:say(("%s was brave\nand went 1-on-1!"):format(who), onDone)
  return true
end

-- ------- against an NPC: the partner's invite

-- Take the partner's offer when one is live and we are free to take it.
--
-- Same-map only, and the gate is kept on this end even though both flows now
-- refuse to *post* an off-map offer at all (M:onTrainerBattle, and the wild
-- path before it): a partner can step through a door in the second between the
-- wait going out and this arriving, and a player cannot be pulled into a
-- battle happening somewhere they are not. Such an offer is stored (chat note
-- + JOIN row) and taken if they walk back inside its lifetime. Mid-fight,
-- mid-trade and mid-ask leave it standing too -- and standing is the whole
-- trick, because M:update re-attempts it the moment those clear, which is what
-- fits a busy partner inside the waiter's SOLO_FALLBACK_AFTER window.
--
-- Neither mode asks. See M:autoJoin for why, and for what a player who does
-- not want the fight does instead.
--
-- Mutual waits: two partners who triggered in the same moment each hold the
-- other's offer, and lexicographically smaller playerId's wait wins. If
-- offer.from < selfId we withdraw ours and join theirs; otherwise we keep ours
-- and drop the inbound offer so both sides cannot sit until their clocks run
-- out. Mixed modes (their grass against our trainer) are two different fights
-- and never merge -- the inbound offer is simply left where it is.
function M:considerOffer(game, myMap)
  local offer = self.offer
  if not offer then return false end
  if self.ask or self.running then return false end
  if not (offer.map and myMap and offer.map == myMap) then return false end

  if self.waiting then
    if (self.waiting.mode == "coop_wild") ~= (offer.mode == "coop_wild") then
      return false
    end
    local selfId = self.party and self.party.selfId
    local from = offer.from
    if not (selfId and from) then return false end
    if from < selfId then
      return self:autoJoin(offer)
    end
    -- Ours wins; clear inbound so waiting+offer cannot block later gates.
    self.offer = nil
    return false
  end

  -- A wild we are ourselves waiting on is still on the stack and counts as
  -- inFight, which is why the mutual case is answered above this rather than
  -- by it.
  if self:inFight(game) then return false end
  return self:autoJoin(offer)
end

-- Take an offer, in either mode, with no confirm box.
--
-- **The consent model, said once.** Forming the party is the consent. Two
-- players who agreed to travel together have already agreed to fight together,
-- so a partner standing at a trainer -- or in the grass -- pulls the other in
-- without a yes/no, which is the rule Party vs Wild always had and the rule
-- the NPC path now shares. The outs are unchanged and all still cheap: the
-- waiter's own clock goes in solo (SOLO_FALLBACK_AFTER), the ACTIONS > JOIN
-- row is there for an offer that could not be taken when it landed, STOP
-- leaves a fight that has started, and leaving the party ends every offer at
-- once.
--
-- Busy is a deferral and not a refusal: mid-fight, mid-ask and mid-trade all
-- leave the offer standing for M:update's retry. That retry is the difference
-- between "the partner was in a menu at the wrong instant" costing the fight
-- and costing a second.
--
-- Called while we already hold a wait (mutual divert, or the menu JOIN row
-- after arbitration chose their offer): withdraw ours first, and only when
-- offer.from < selfId -- considerOffer's rule, re-asked here because the menu
-- row reaches this without going through it. A withdrawn *wild* wait also
-- discards the local engine wild, whose key will not match theirs; a withdrawn
-- *trainer* wait keeps it, because a trainer that has been walked into is owed
-- a battle either way (rule 2) -- startBattle adopts it when it is the same
-- fight and it resurfaces underneath when it is not.
function M:autoJoin(offer)
  if not offer then return false end
  if not self.transport:isReady() then return false end
  if self.running or self.ask then return false end
  if self:sessionBusy() then return false end
  if self.waiting then
    if (self.waiting.mode == "coop_wild") ~= (offer.mode == "coop_wild") then
      return false
    end
    local selfId = self.party and self.party.selfId
    local from = offer.from
    if not (selfId and from and from < selfId) then return false end
    local wild = self.waiting.kind == "wild"
      or self.waiting.mode == "coop_wild"
    -- Quiet cancel: onOfferEnd does not announce timeout the way alone/left do.
    self:withdraw("timeout")
    if wild then
      local enc = self.encounter
      self.encounter = nil
      if enc and enc.engine then
        self:unwindTo(enc.game, enc.engine, true)
      end
    end
  end
  local from, battle = offer.from, offer.battle
  -- Cleared before the send so a second considerOffer tick cannot double-join.
  -- A late alone from the hub still lands as COOP_OFFER_END with nothing up.
  self.offer = nil
  self.transport:send(Wire.COOP_JOIN, { to = from, battle = battle })
  -- One line, in the corner and in the party log rather than a box: being
  -- pulled into a fight is not disorienting when you are told whose it is, and
  -- a box here would be the confirm again wearing a different hat.
  --
  -- **In the corner because the log alone was invisible.** This is the last
  -- word the joiner gets before a battle they did not ask for lands on top of
  -- their overworld, and everything else that could carry it -- the partner's
  -- "!" mark, the note -- is either covered by that battle or behind a window
  -- nobody had open. The toast outlives the push (M:toastLine); the note keeps
  -- the history for anyone who scrolls back.
  local line = ("Joining %s's battle!"):format(
    offer.name or self.party:partnerName() or "your friend")
  self:note(line)
  self:toastLine(line)
  return true
end

-- The retry. An offer that could not be taken when it landed, taken later.
--
-- This is the whole of "the partner gets pulled in" in the case that actually
-- happens: the offer arrives while they are in a menu, finishing a wild fight,
-- mid-trade, or one map away, every gate above refuses it, and until this
-- existed nothing ever asked again -- the fight was lost to a half-second of
-- bad timing and the only way back was a menu row nobody knew about.
--
-- Cheap by construction. The caller only reaches here while an offer stands,
-- which is rare and bounded (COOP_OFFER_TIMEOUT), and this adds one number and
-- one compare to those ticks; the real work -- considerOffer's stack walk --
-- happens twice a second. Nothing at all is done on a tick with no offer.
--
-- The map comes from the `here` hook rather than from the caller because this
-- runs on the fixed step, where nobody handed us one, and Coop deliberately
-- cannot ask the world itself (see M:challenge's header). No hook, no retry:
-- the ACTIONS > JOIN row is still there.
function M:retryOffer(game, dt)
  if not game then return false end
  local offer = self.offer
  if not offer then return false end
  if self.running or self.ask then return false end
  offer.retry = (offer.retry or 0) + (dt or 0)
  if offer.retry < JOIN_RETRY_EVERY then return false end
  offer.retry = 0
  local here = self.here
  if type(here) ~= "function" then return false end
  local ok, myMap = pcall(here)
  if not ok then
    if not self.hereWarned then
      self.hereWarned = true
      mod.log:warn("could not read the current map for a co-op join (%s); use "
        .. "the JOIN row on your partner to join their battle", tostring(myMap))
    end
    return false
  end
  if not myMap then return false end
  return self:considerOffer(game, myMap)
end

-- Walking up to the partner and pressing A, or picking them off the roster.
--
-- The manual door, and the only one a player has to *find* -- kept precisely
-- because the automatic one can be closed at the wrong instant: an offer that
-- landed mid-fight or mid-trade is normally re-taken by M:update's retry, and
-- this is what that retry falls back to when the player would rather not wait
-- for it (or when the offer arrived before this build's hooks were wired).
-- Same auto-join as considerOffer, in both modes -- there is no confirm left
-- to raise. It answers false when there is nothing standing, and the ACTIONS
-- menu uses that to decide whether to offer the row at all.
--
-- `game` is taken and ignored: nothing here pushes a screen any more, and the
-- callers (src/Ui.lua's ACTIONS row) still have it to hand.
function M:joinFromMenu(game) -- luacheck: ignore game
  local offer = self.offer
  if not offer then return false end
  return self:autoJoin(offer)
end

-- ------- against another party

-- PARTY BATTLE, and the three ways it is refused before anything is sent.
--
-- Every one of them is answered here rather than by the hub, because the
-- client already knows all three answers and a round trip would turn an
-- immediate sentence into a pause followed by one.  The hub re-checks all of
-- it anyway -- these are the player's error messages, not the rule.
-- `myMap` is handed in rather than looked up.  The roster knows where every
-- *other* player is standing and deliberately holds no entry for us, so our
-- own map is the one position this module cannot ask it for -- and reaching
-- past it into the world would give Coop an engine dependency it otherwise
-- does not have, and cost the suite the ability to drive this from both sides.
function M:challenge(game, peer, myMap)
  if not (peer and peer.id) then return false end
  if not self.transport:isReady() then return false end

  if self:inFight(game) then
    self.ui:say("Finish your battle\nfirst.")
    return false
  end

  if not self.party:has() then
    self.ui:say("You need a party\nfor that.")
    return false
  end
  -- The one player this can never be aimed at is the one standing next to
  -- you: a 2-on-2 is two *parties*, and the two of you are one of them.
  --
  -- The ACTIONS menu already hides the row for a partner, so arriving here
  -- means it was reached some other way -- and the hub's own check answers a
  -- self-party challenge by dropping it in silence (nothing to say, since a
  -- well-behaved client cannot send one). Silence is the worst possible
  -- answer for the asker: self.ask is set, so every later attempt is refused
  -- with "You already asked" until the 70-second backstop expires it. Said
  -- here, before anything is written down, that state is unreachable.
  if self.party:isPartner(peer.id) then
    self.ui:say(("%s is already\non your team."):format(peer.name or "They"))
    return false
  end
  -- Their side of it.  presence.party is the one thing every client is told
  -- about every other -- deliberately a bool and never a party id -- and it is
  -- exactly the fact this row needs.
  if not peer.party then
    self.ui:say(("%s isn't in\na party."):format(peer.name or "They"))
    return false
  end

  -- Our own partner has to be standing here.  A four-way battle whose fourth
  -- player is two maps away is one that would begin without them and finish
  -- before they arrived.
  local partner = self.party:partner()
  local here = partner and self.roster:get(partner.id)
  if not (here and here.map and myMap and here.map == myMap) then
    self.ui:say(("%s isn't on\nthis map."):format(
      (partner and partner.name) or "Your friend"))
    return false
  end

  if self.ask then
    self.ui:say("You already asked\nfor a battle.")
    return false
  end

  self.ask = { role = "asker", peer = peer.id, name = peer.name, clock = 0 }
  self.transport:send(Wire.COOP_CHALLENGE, { to = peer.id })
  -- Held, not just shown. This box is a screen on the engine's stack that
  -- dismisses itself when the player presses A -- and a player who does not
  -- press A is a player still holding it when the battle screen goes up on
  -- top. A buried state gets no update, so it cannot be dismissed while it is
  -- down there, and it resurfaces intact when the battle pops: a sentence
  -- about an ask that was answered several minutes ago. See M:closeAskBox.
  self.askBox = {
    box = self.ui:say(("Asked %s for a\n2-on-2 battle."):format(
      peer.name or "them")),
    game = game,
  }
  return true
end

-- Take the asker's box down, if it is still up.
--
-- Every way the ask can end comes through here -- answered, declined, timed
-- out, the party dissolving, the battle actually starting -- because the box
-- outlives self.ask and so cannot be cleared alongside it.
--
-- **Only when the box is what the player is looking at**, which is stricter
-- than it first appears to need to be and deliberately so.
--
-- unwindTo pops everything above its target -- up to sixteen states -- and an
-- ask stands for up to seventy seconds. That is plenty of time for the player
-- to open something over the top of it: a party invite's confirm, a trade
-- request, any sentence another part of this mod decided to say. Resolving the
-- ask would then throw those away, which is a worse bug than the stale box
-- this exists to prevent. Aimed at a box that is already gone it would be
-- worse still, popping sixteen states hunting for it and taking the world.
--
-- The burial case is still covered, because it is not this call that covers
-- it: startBattle closes the box immediately before pushing the battle screen,
-- and at that instant nothing is on top of it. A box with something else above
-- it is simply left where it is -- it will be dismissed the ordinary way, by
-- the player pressing A on it once whatever they opened is closed.
function M:closeAskBox()
  local held = self.askBox
  self.askBox = nil
  if not held then return false end
  local stack = held.game and held.game.stack
  local states = stack and stack.states
  if not (states and held.box) then return false end
  if states[#states] ~= held.box then return false end
  return self:unwindTo(held.game, held.box, true)
end

-- True while this client is mid-fight: a co-op battle already handed off,
-- or a wild / trainer / link / co-op screen still on the stack (including
-- under a menu).  Mirrored in Sessions:inFight -- same rule, two call
-- sites, so a PARTY BATTLE ask and a 1v1 request both stay off a live fight.
function M.isFightState(state)
  if type(state) ~= "table" then return false end
  local kind = state.kind
  if kind == "wild" or kind == "trainer" or kind == "link" then return true end
  if state.sim ~= nil then return true end
  -- Gen 2 ui/gen2/BattleState: no kind; wild/trainer live on state.battle.
  local battle = state.battle
  if type(battle) == "table" and (battle.wild or battle.trainer) then
    return true
  end
  return false
end

function M.stackHasFight(game)
  local stack = game and game.stack
  if not stack then return false end
  local states = stack.states
  if type(states) == "table" then
    for i = #states, 1, -1 do
      if M.isFightState(states[i]) then return true end
    end
    return false
  end
  local top = stack.top and stack:top()
  return M.isFightState(top)
end

-- Like stackHasFight, but ignore one state -- the wild (or trainer) that was
-- just pushed and is the reason we are deciding whether to divert. Without
-- the exclusion, every divert predicate would see "already in a fight" and
-- refuse itself.
function M.stackHasFightExcept(game, except)
  local stack = game and game.stack
  if not stack then return false end
  local states = stack.states
  if type(states) == "table" then
    for i = #states, 1, -1 do
      local s = states[i]
      if s ~= except and M.isFightState(s) then return true end
    end
    return false
  end
  local top = stack.top and stack:top()
  return top ~= except and M.isFightState(top)
end

function M:inFight(game)
  if self.running or self.state then return true end
  if self.fighting and self.fighting(game) then return true end
  return M.stackHasFight(game)
end

function M:inFightExcept(game, except)
  if self.running or self.state then return true end
  if self.fighting and self.fighting(game) then return true end
  return M.stackHasFightExcept(game, except)
end

-- The ask, as it reaches the other three.  All four have to agree, so this is
-- put to each of them and any one no ends it -- which the hub enforces and
-- says out loud to everyone still holding a box.
function M:onAsk(game, msg)
  local id = Wire.id(msg.id)
  local from = Wire.id(msg.from)
  local name = Wire.name(msg.name)
  local side = Wire.side(msg.side)
  if not (id and from and name and side) then return end

  -- Already committed elsewhere, or mid-fight.  Answered immediately rather
  -- than queued: a box over a wild encounter or a live 2-on-2 is worse than
  -- a no the asker can act on now.
  if self.ask or self:inFight(game) then
    self.transport:send(Wire.COOP_ANSWER, { id = id, accept = false })
    return
  end

  self.ask = { role = "asked", id = id, name = name, side = side, clock = 0 }
  self.ui:confirm(game, ("%s wants a\n2-on-2 battle!"):format(name),
    function(yes)
      local pending = self.ask
      if not (pending and pending.role == "asked") then return end
      if not yes then self.ask = nil end
      self.transport:send(Wire.COOP_ANSWER,
        { id = pending.id, accept = yes and true or false })
    end)
end

function M:onDecline(msg)
  local name = Wire.name(msg and msg.name)
  local reason = Wire.coopReason(msg and msg.reason)

  -- NPC invite declined while we wait: the fight still has to happen (rule 2),
  -- so after the two sentences we release into the solo battle under the prompt.
  -- Party vs Wild has no invite UI and no "take them alone" pep talk -- just
  -- hand the engine wild back.
  if self.waiting then
    local wild = self.waiting.kind == "wild"
    self.waiting = nil
    if wild then
      self:release()
      return
    end
    local who = name or self.party:partnerName() or "Your friend"
    self.ui:say(("%s decided\nnot to join."):format(who), function()
      self.ui:say("You can take\nthem alone!", function()
        self:release()
      end)
    end)
    return
  end

  self.ask = nil
  -- The old box first, then the new one: two sentences about the same ask,
  -- one of them stale, is what a player would otherwise be left pressing A
  -- through.
  self:closeAskBox()
  if reason == "timeout" then
    self.ui:say("Nobody answered\nin time.")
  elseif reason == "gone" then
    self.ui:say(("%s went\noffline."):format(name or "Someone"))
  else
    self.ui:say(("%s said no."):format(name or "Someone"))
  end
end

-- ------- inbound: the NPC flow

function M:onOffer(game, msg, myMap)
  local offer = Wire.coopOffer(msg)
  if not offer then return end
  -- Only from the person we are actually travelling with.  The hub only ever
  -- forwards within a party, but this is the client's own check on it: an
  -- offer from a stranger would put a box in front of the player naming a
  -- fight they have no partner for.
  if not self.party:isPartner(offer.from) then return end
  offer.clock = 0
  self.offer = offer
  -- Written down *before* considerOffer, because considerOffer is where the
  -- offer stops existing: the free-and-on-map case takes it in this same call
  -- and clears `self.offer` before the send. Set afterwards, the latch would
  -- record an arrival for exactly the cases the mark is not needed for.
  self.offerMarkFor =
    { id = offer.from, battle = offer.battle, map = offer.map }
  self.aloneAnnounced = false
  if offer.mode ~= "coop_wild" then
    self:note(("%s is waiting at %s."):format(offer.name, fightName(offer.label)))
  end
  -- Invite like a 2-on-2 ask: same map, and free to answer. Off-map stays a
  -- note + JOIN row until considerOffer runs on map.entered. coop_wild
  -- auto-joins from considerOffer when free on-map.
  self:considerOffer(game, myMap)
end

function M:onOfferEnd(msg)
  local offer = self.offer
  local reason = Wire.coopReason(msg and msg.reason)
  local name = offer and offer.name
  self.offer = nil
  -- The offer ended without a fight, so the mark has nothing left to point at.
  self.offerMarkFor = nil
  -- Nothing to take down: an offer is a note and a menu row now, never a box.
  -- "They went in without you" and "they walked away" look identical from
  -- here and read very differently to somebody who was on their way over, so
  -- the two are told apart. A late JOIN that finds no offer also lands here
  -- as `alone` (hub twin), even when `self.offer` was already cleared.
  if reason == "alone" then
    self:announceAlone(name)
  elseif offer and reason == "left" then
    self:note(("%s left %s."):format(offer.name, fightName(offer.label)))
  end
end

-- Our offer was taken.  This is the message that ends the waiting, and the
-- only one that does.
function M:onJoined(game, msg)
  local waiting = self.waiting
  if not waiting then return end
  local name = Wire.name(msg and msg.name) or self.party:partnerName()
    or "your friend"
  -- The hub's mediated battle id (`c*`), carried as `plan` so it does not
  -- collide with `id` (the joiner). Without this, uploadMediated has nothing
  -- to name and the fight stays on host CoopSim under PROTOCOL 10.
  local planId = Wire.id(msg and msg.plan)
  local wild = waiting.kind == "wild" or waiting.mode == "coop_wild"
  self.waiting = nil
  self:note(("%s joined the fight."):format(name))
  self:begin(game, {
    kind = wild and "wild" or "npc",
    mode = wild and "coop_wild" or nil,
    id = planId,
    battle = waiting.battle,
    label = waiting.label,
    engine = waiting.engine,
    trainer = waiting.trainer,
    wildCatchMon = waiting.wildCatchMon or M.wildMonOf(waiting.engine),
    npcId = waiting.npcId,
    event = waiting.event,
    allies = self.party:list(),
    -- The player who was waiting is the one standing at the encounter, so they
    -- are the one that simulates.
    host = true,
    hostId = self.party.selfId,
  })
end

-- The engine's battle *this* client walked into, when the fight it is being
-- sent into is the one it is standing in front of.
--
-- The player who waited hands their own battle over through `waiting.engine`
-- (see M:onJoined).  This is the other half of that, and it was missing for a
-- long time.  Both players trigger the trainer, so the engine builds a real
-- BattleState on *both* machines -- the reference is client-local and could
-- never have crossed the wire, which is exactly why it has to be picked up
-- here rather than read off the message.  Without it, startBattle's unwind
-- never ran for the player who joined: their own battle sat under the co-op
-- screen for the whole fight and resurfaced the moment it popped, so the
-- trainer they had just beaten alongside a friend was put in front of them
-- again, alone.  See the comment on the unwind in M:startBattle, which
-- describes this exact failure and only ever prevented half of it.
--
-- Keyed on the battle the hub named rather than taken on trust, and that is
-- the whole of the safety here.  `self.encounter` is whatever trainer this
-- client last walked into, and two ways into a co-op battle have nothing to do
-- with it: a party-versus-party fight, which has foes and for which no
-- encounter is ever the right answer, and a join from the ACTIONS menu, where
-- nobody walked into anything and nil is the correct answer.  Matching the key
-- adopts the encounter only when it is demonstrably the same fight, and leaves
-- a mismatched one alone rather than handing it somebody else's result.
--
-- Matching the key is not quite enough on its own, because an encounter can
-- outlive its battle: a player who joins keeps theirs deliberately (see
-- M:autoJoin) and the hub can still drop that join -- the partner pressing
-- STOP in the same tick is enough -- in which case they fight the trainer
-- alone, that battle finishes itself, and the reference left behind names
-- nothing. The key would still match a later fight against the same class on
-- the same map, and the same lead. So the state has to still be *there*, which
-- is the one question the stack can answer for certain.
function M:joinedEngine(game, msg, foes)
  if foes then return nil end
  local encounter = self.encounter
  if not encounter then return nil end
  local key = Wire.battleKey(msg and msg.battle)
  if not (key and encounter.battle == key) then return nil end
  if self:onStack(game, encounter.engine) == false then return nil end
  return encounter.engine
end

-- A buried trainer BattleState this client still owes a result to, when
-- `joinedEngine` did not already name one.
--
-- Walk-in joiners normally adopt via the encounter key in onBattle. Under
-- mediation the stack can still be carrying that fight when startBattle
-- finally runs, and clearing the encounter without unwinding it is exactly
-- the "immediate FIGHT UI" rematch. Keyed on the waiter's concrete `npcId`
-- from the wire (PROTOCOL 20) -- never by trainer class alone (Route 3 Bug
-- Catchers). Returns nil for party fights, wild, and menu joiners who never
-- walked into anything.
function M:claimBuriedEngine(game, plan)
  if not plan or plan.foes then return nil end
  if plan.kind == "wild" or plan.mode == "coop_wild" then return nil end
  -- Same rules as joinedEngine, re-asked at startBattle: the encounter may
  -- still name a live stack state even when onBattle ran before it settled.
  local encounter = self.encounter
  if encounter and encounter.engine then
    local key = plan.battle
    if key and encounter.battle == key
        and self:onStack(game, encounter.engine) ~= false then
      return encounter.engine
    end
  end
  local npcId = Wire.npcId(plan.npcId)
  if not npcId then return nil end
  local states = game and game.stack and game.stack.states
  if type(states) ~= "table" then return nil end
  for i = #states, 1, -1 do
    local state = states[i]
    if state and state.kind == "trainer" then
      local origin = state.checkpointOrigin
      if type(origin) == "table"
          and Wire.npcId(origin.npcId) == npcId then
        return state
      end
    end
  end
  return nil
end

-- We joined theirs, or all four agreed.  One entry point for both, because
-- from here on they are the same thing: a set of fighters the hub has just
-- confirmed are all still connected.
function M:onBattle(game, msg)
  local side = Wire.side(msg and msg.side)
  local allies = Wire.members(msg and msg.allies)
  local foes = Wire.members(msg and msg.foes)
  self.ask = nil
  self.waiting = nil
  -- The ask is answered, so the sentence about having asked has nothing left
  -- to say. Closed here as well as in startBattle because a battle that never
  -- assembles still has to leave the screen clean.
  self:closeAskBox()
  if not (side and allies) then return end
  local hostId = Wire.id(msg.host)
  local mode = Wire.coopOfferMode(msg and msg.mode)
  local wild = mode == "coop_wild"
  local engine = self:joinedEngine(game, msg, foes)
  -- Prefer the hub-carried origin (waiter's checkpoint); fall back to a
  -- walk-in joiner's own engine so a protocol-18 hub still leaves them a path.
  local npcId = Wire.npcId(msg and msg.npcId)
  local event = Wire.eventFlag(msg and msg.event)
  if not npcId and engine then
    npcId, event = M.originOf(engine)
  elseif not event and engine then
    local _, engineEvent = M.originOf(engine)
    event = engineEvent
  end
  self:begin(game, {
    kind = foes and "party" or (wild and "wild" or "npc"),
    mode = mode,
    id = Wire.id(msg.id),
    side = side,
    allies = allies,
    foes = foes,
    -- The battle this client is standing in front of, so the co-op one can
    -- stand in for it and hand it its result.  Nil on both paths that were
    -- never standing in front of anything -- see M:joinedEngine.
    engine = engine,
    wildCatchMon = wild and M.wildMonOf(engine) or nil,
    npcId = npcId,
    event = event,
    battle = Wire.battleKey(msg and msg.battle),
    -- Derived from the id the hub named rather than assumed, so exactly one of
    -- the four believes it is the host.
    host = hostId ~= nil and self.party:isSelf(hostId),
    hostId = hostId,
  })
end

-- ------- the handoff
--
-- Everyone has agreed; now the battle is assembled.
--
-- Three things have to be true before four monsters can be put on a field, and
-- none of them is true yet at this point:
--
--   1. every human in it has to have handed over their party, because a client
--      only holds its own;
--   2. exactly one of them has to be the one that simulates (see CoopBattle's
--      header for why host-authoritative and not four-way lockstep);
--   3. the NPC side, if there is one, has to be built -- and built *once*, by
--      the host, or the four clients would be fighting four different pairs.
--
-- So this opens a short exchange rather than pushing a screen: everyone posts
-- their packed party, the host waits until it has them all, builds the field
-- and broadcasts it, and all four construct the same battle from the same
-- description.  `pending` is what that exchange is kept in.
--
-- The host is the player who was already standing at the fight (the NPC path)
-- or the one who issued the challenge (the party path).  Either way it is a
-- fact both sides can derive without asking, which is what stops two clients
-- both believing they are it.
function M:begin(game, plan)
  self.running = true
  self.lastPlan = plan
  self.battle = {
    plan = plan,
    host = plan.host and true or false,
    parties = {},
    badges = {},
    ready = false,
  }

  local packed = CoopBattle.packParty(game and game.save and game.save.party, game)
  if not packed then
    -- The engine's link modules are what pack a party, and without them there
    -- is no battle to have. Said out loud, and the trainer handed back, rather
    -- than leaving four players staring at nothing.
    return self:abandon("2-on-2 needs the\nlink modules.")
  end

  self.battle.parties[self.party.selfId or "me"] = packed
  -- The badges go with the party, for the reason the party does: the host
  -- builds all four battlers and holds only its own save. A badge set read
  -- locally by the host would hand its own boosts to everybody and nobody
  -- else theirs -- and, worse, the four copies of the field would disagree
  -- about how hard everyone hits.
  local mine = M.badgesOf(game)
  self.battle.badges[self.party.selfId or "me"] = mine
  self.transport:send(Wire.COOP_RELAY,
    { payload = { t = "party", mons = packed, badges = mine } })
  self:tryStart(game)
  return plan
end

-- Does this battle move anybody's rating?
--
-- **Only a battle against other players does, and that is a decision rather
-- than an omission.** Elo rates you against an opponent's rating, and a
-- trainer has none -- there is no number to be favoured or outmatched by, so
-- there is nothing for the curve to say. Inventing one from the trainer's
-- party would be worse than saying nothing: NPCs are an infinite, respawning
-- supply, and the one thing that stops a rating being farmed -- the rematch
-- discount -- is keyed on *pairs of players* and would never fire against a
-- trainer at all. Two friends could grind gym leaders to the top of the board
-- without ever meeting anybody.
--
-- So a co-op battle against an NPC pays what a trainer battle pays -- exp,
-- badges, prize money, the defeated flag -- and pays no points. It is worth
-- exactly what fighting that trainer alone is worth, which is the honest
-- answer. The player is told once, in CoopBattle, rather than left to notice
-- a number that did not move.
--
-- Read off the plan rather than recomputed from whatever is to hand, and read
-- in one place, because the answer is needed twice: here, to decide whether to
-- file a result, and in buildField, to decide whether badges count.
function M.ranksPoints(plan)
  return plan ~= nil and plan.foes ~= nil and #plan.foes > 0
end

-- The badges this player has earned, as a list for the wire.
--
-- Same dual-gen path as MediatedBattle.badgesOf (MK403): never hard-require
-- Gen 1 `src.battle.Damage` on Gold.
function M.badgesOf(game)
  return Mediated.badgesOf(game)
end

-- Give up on a battle that cannot be assembled, without breaking rule 2: the
-- trainer somebody walked into is still fought.
function M:abandon(text)
  self.running = false
  self.battle = nil
  self.ui:say(text, function() self:release() end)
  return nil
end

-- Is this the one client entitled to speak for the whole battle?
--
-- The hub named the host and every client derived the same answer from it (see
-- M:onBattle), so this is a fact all four already agree on rather than a claim
-- being taken at face value.
--
-- Permissive when the plan names nobody, which mirrors CoopBattle:fromHost: a
-- peer old enough not to send a host id is a compatibility case, and refusing
-- it would break a battle rather than protect one.
function M:fromHost(from)
  local plan = self.battle and self.battle.plan
  local hostId = plan and plan.hostId
  if hostId == nil or from == nil then return true end
  return from == hostId
end

-- Battle traffic from one of the other players.
--
-- Two kinds ride this: the party exchange above, which this module owns, and
-- everything the battle itself sends, which it does not -- so anything that is
-- not a party is handed straight to the live battle's inbox.
function M:onMessage(game, msg)
  local from = Wire.id(msg and msg.from)
  local payload = type(msg) == "table" and msg.payload
  if not (from and type(payload) == "table") then return end

  if payload.t == "party" then
    local battle = self.battle
    if not (battle and not battle.ready) then return end
    battle.parties[from] = payload.mons
    -- Sanitised on the way in like everything else: this ends up indexed by
    -- the engine while it decides how hard somebody hits.
    battle.badges[from] = Wire.badges(payload.badges)
    return self:tryStart(game)
  end

  -- The host looked at all four parties and refused to build a field. Carries
  -- no text: what it means is the same sentence on every client, and a reason
  -- read off the wire would be a reason another client chose the words of.
  if payload.t == "abort" and self.battle and not self.battle.ready then
    if not self:fromHost(from) then return end
    return self:abandon("Everyone needs a\nhealthy POKéMON.")
  end

  if payload.t == "field" and self.battle and not self.battle.ready then
    -- The host's word, and only the host's. Both of these are declarations
    -- about the battle as a whole rather than about their sender: `abort` ends
    -- the assembly for everybody, and `field` decides which four monsters are
    -- on it -- so a member who was merely *in* the group could otherwise pick
    -- the other three players' teams, or call off a battle nobody agreed to
    -- call off. Everything below this point is per-slot and stays open,
    -- because the battle checks the owner of each action itself.
    if not self:fromHost(from) then return end
    -- Sanitised like every other inbound payload, which this one was not.
    -- The sender is another player's client, and this table decides how many
    -- monsters are on the field and what is drawn over them.
    local field = Wire.coopField(payload.field)
    if not field then
      return self:abandon("That battle's field\ncouldn't be read.")
    end
    return self:startBattle(game, field)
  end

  -- Anything else belongs to the running battle. Stamped with who sent it,
  -- because the battle refuses an action filed for somebody else's slot.
  local inbox = self.inbox
  if inbox then
    payload.from = from
    inbox[#inbox + 1] = payload
  end
end

-- ------- the three things an intermediator says during a fight it is running
--
-- Carried rather than interpreted, which is this module's whole relationship
-- with the running battle: the screen owns the mediated exchange, and the id on
-- every one of these is checked *inside* it against the battle it uploaded to --
-- so a message about somebody else's match is inert without this file having to
-- know which match that is.
--
-- Sanitised here because that is where every other inbound payload is sanitised,
-- and these three decide what four screens draw and how the fight ends.
--
-- Nil-safe about the screen: the record on the hub is opened when the battle is
-- *agreed*, and the screen goes up a short exchange later, so a message that
-- arrives in that window has nowhere to go and is dropped. It cannot be one that
-- matters -- mmo.battle_ready is not sent until every seat has uploaded a party,
-- and the uploads come from the screens.
function M:onBattleReady(msg)
  local ready = Wire.battleReady(msg)
  if ready and self.state then self.state:onBattleReady(ready) end
end

function M:onBattleEvent(msg)
  local event = Wire.battleEvent(msg)
  if event and self.state then self.state:onBattleEvent(event) end
end

function M:onBattleOutcome(msg)
  local outcome = Wire.battleOutcome(msg)
  if outcome and self.state then self.state:onBattleOutcome(outcome) end
end

-- Transport became ready again under a live mediated co-op fight.
function M:onTransportReady()
  local state = self.state
  if state and state.mediated and state.onTransportReady then
    return state:onTransportReady()
  end
  return false
end

-- Do we have everything the field needs yet?  Only the host asks -- it is the
-- one that builds the field -- and it answers by counting the humans in the
-- plan against the parties in hand.
function M:tryStart(game)
  local battle = self.battle
  if not (battle and battle.host and not battle.ready) then return false end

  local humans = {}
  for _, member in ipairs(battle.plan.allies or {}) do humans[#humans + 1] = member end
  for _, member in ipairs(battle.plan.foes or {}) do humans[#humans + 1] = member end
  for _, member in ipairs(humans) do
    if not battle.parties[member.id] then return false end
  end

  local field, why, closeGroup = self:buildField(game, battle, humans)
  if not field then
    -- A refusal the other three have to hear about.
    --
    -- The host is the only client that ever sees all four parties, so it is
    -- the only one that can know this -- and the other three are sitting in
    -- `begin` with `running` set, waiting for a field that is now never
    -- coming. Told over the relay first and then closed with the same
    -- one-goodbye-closes-all COOP_LEAVE a finished battle uses: after the
    -- goodbye the group is gone and there is no longer any path to reach them.
    if closeGroup then
      self.transport:send(Wire.COOP_RELAY, { payload = { t = "abort" } })
      self.transport:send(Wire.COOP_LEAVE, {})
    end
    return self:abandon(why or "That battle can't\nstart.")
  end

  self.transport:send(Wire.COOP_RELAY, { payload = { t = "field", field = field } })
  -- The host builds this table and then reads it back through the same
  -- sanitiser the other three use. Not paranoia about itself: it means the
  -- shape the host plays is provably the shape it sent, so a field that would
  -- be rejected over there cannot quietly work over here.
  return self:startBattle(game, Wire.coopField(field) or field)
end

-- The four slots, as one description every client builds the same battle from.
--
-- Built by the host alone and sent whole, for the same reason the hub sends a
-- party's membership whole rather than as a delta: four clients deriving it
-- independently is four chances to derive it differently.
function M:buildField(game, battle, humans)
  local plan = battle.plan
  local slots = {}

  -- No bag goes in here, deliberately: this table crosses the wire, and a
  -- player's whole inventory is neither anybody else's business nor a thing
  -- worth putting in a relayed payload. Each client attaches its own in
  -- startBattle.
  -- Whether badges count in this battle at all, decided once for everybody.
  --
  -- **Against an NPC they do.** Two players fighting a trainer together are
  -- the player side of a trainer battle, and a trainer battle is exactly where
  -- Gen 1 applies the x9/8 badge boosts. Without this they hit weaker together
  -- than either would alone, which is the wrong way round for a co-op mode.
  --
  -- **Against another party they do not, for anybody.** That is not an
  -- oversight being preserved: `BattleState.makeBattler` says so in its own
  -- comment -- "LinkBattle builds clamped copies with save=nil (no badge
  -- boosts)" -- so the engine's own human-versus-human battle gives neither
  -- side theirs. Handing them out here would make a party battle a different
  -- game from a link battle, and would do it asymmetrically: the engine gates
  -- badges on `isPlayer`, which on this shared field is a fact about which
  -- side of it you stand on, so side A would get boosts and side B could not.
  -- Two parties meet on even terms, as two players already do.
  local versusPlayers = M.ranksPoints(plan)
  -- Absent is a real answer, and the common one: nobody has to have a badge,
  -- and a battle assembled without the table at all is a battle where nobody
  -- has any -- never a crash on the way to one.
  local held = battle.badges or {}

  local function add(side, member)
    slots[#slots + 1] = {
      side = side, owner = member.id, name = member.name,
      party = battle.parties[member.id],
      badges = (not versusPlayers) and held[member.id] or nil,
    }
  end

  for _, member in ipairs(plan.allies or {}) do add("a", member) end

  if plan.foes and #plan.foes > 0 then
    for _, member in ipairs(plan.foes) do add("b", member) end
  else
    -- Against an NPC: two opponents built from the trainer that was walked
    -- into, so a pair of players meets a pair of monsters rather than one.
    local npc = self:npcSide(game, plan)
    if not npc then return nil, "That trainer can't\nfight two of you." end
    for _, entry in ipairs(npc) do slots[#slots + 1] = entry end
  end

  -- Three is a full fight when the trainer only brought one monster (two
  -- players + one NPC seat); four is the usual 2v2. Anything else is a plan
  -- that did not assemble into a co-op field.
  if #slots < 3 or #slots > Config.COOP_FIGHTERS then
    return nil, "That battle can't\nbe started."
  end

  -- Nobody fights with a fainted team.
  --
  -- **This is the first moment the question can be asked at all.** Presence
  -- carries no HP -- deliberately; it is a position broadcast, not a save
  -- dump -- so up until the parties land here no client, the hub included,
  -- has any idea whether the four trainers about to be put on a field own a
  -- monster that can stand up. The host has all four now, so it asks now.
  --
  -- Refused per *side*, not per player: a pair where one has fainted and the
  -- other has not is a two-on-one, which is a battle. A side with nothing
  -- healthy is a side that cannot send anything out, and the sim would open
  -- on a slot it can never fill.
  --
  -- After the blackout rule above this should be unreachable -- a player who
  -- ends a battle with nothing healthy is warped to a Center and healed
  -- before they can walk anywhere. It is here for the day it is not.
  --
  -- Judged only on HP it can actually read. A packed monster always carries
  -- one, so for every party that ever crosses this wire the two readings are
  -- the same -- but "this slot's HP is not a number I recognise" is genuinely
  -- not the same statement as "this slot has fainted", and refusing a battle
  -- over the first would be the host inventing a faint out of a shape it did
  -- not understand.
  local alive, known = {}, {}
  for _, slot in ipairs(slots) do
    for _, mon in ipairs(slot.party or {}) do
      local hp = type(mon) == "table" and tonumber(mon.hp) or nil
      if hp then
        known[slot.side] = true
        if hp > 0 then alive[slot.side] = true end
      end
    end
  end
  if (known.a and not alive.a) or (known.b and not alive.b) then
    return nil, "Everyone needs a\nhealthy POKéMON.", true
  end
  -- Who the four are fighting, by id rather than by record: it is the one
  -- thing about the NPC side that is not already in the slots, and every
  -- client needs it to show the same face and play the same theme. A client
  -- that joined by answering an invitation never walked into this trainer and
  -- so has no other way to know.
  local trainer = plan.engine and plan.engine.trainer
  return { slots = slots, host = plan.hostId, trainer = trainer and trainer.id }
end

-- The NPC side, taken from the battle the engine already built.
--
-- The trainer's own party is split across up to two slots so a multi-mon
-- trainer is a genuine 2-on-2 rather than two players taking turns on one
-- monster. A trainer with only one mon gets a single foe seat -- the hub's
-- mediated path drops empty NPC seats the same way -- so parties can fight
-- any trainer, not only those with two or more POKéMON.
--
-- `enemyParty` is a list of real monsters with fixed trainer DVs and computed
-- stats -- the engine made them a moment ago when it constructed the battle
-- this prompt is sitting on top of. Rebuilding them from the trainer record
-- would be doing the same work twice and risking a different answer.
function M:npcSide(game, plan)
  local engine = plan.engine
  local party = engine and engine.enemyParty
  -- Wild battles (and coop_wild plans) carry one mon on wildCatchMon / enemy.mon
  -- rather than enemyParty. Feed that into the same pack path so buildField
  -- still produces a side-b slot the screen can draw.
  if not (party and #party > 0) then
    local mon = plan.wildCatchMon or M.wildMonOf(engine)
    if mon then party = { mon } end
  end
  if not (party and #party > 0) then return nil end

  local left, right = {}, {}
  for i, mon in ipairs(party) do
    local into = (i % 2 == 1) and left or right
    into[#into + 1] = mon
  end
  local label = plan.label or "TRAINER"
  -- Packed like every other party, because this table is about to be relayed
  -- to three other clients: a raw party of full monster tables is both larger
  -- than a payload should be and a second encoding of a thing that already has
  -- one. Wire.payloadOk bounds what may be forwarded, and a packed party is
  -- the shape it was bounded for.
  local out = {}
  out[#out + 1] = { side = "b", owner = nil, name = label,
                    party = CoopBattle.packParty(left, game) }
  if #right > 0 then
    out[#out + 1] = { side = "b", owner = nil, name = label,
                      party = CoopBattle.packParty(right, game) }
  end
  for _, entry in ipairs(out) do
    if not entry.party then return nil end
  end
  return out
end

-- Push the screen.  From here the battle owns the exchange, and this module
-- only carries its messages and hears how it ended.
-- Who the four are fighting, resolved the same way on every client.
--
-- Whoever walked into them already holds the record and keeps it. Everyone
-- else -- anybody who joined by answering an invitation, and so has never seen
-- this trainer -- looks it up by the id the field named, against their own
-- copy of the data. That id is off the wire like everything else, so it goes
-- through the same sanitiser a player id does before it is used as a key.
--
-- Nil is a real answer: two parties fighting each other have no trainer, and a
-- record this build does not have is not one worth inventing. The battle then
-- runs with no face, no class for the AI and the plain link theme -- which is
-- exactly what a party-versus-party co-op battle is.
function M.trainerFor(game, field, engine)
  if engine and engine.trainer then return engine.trainer end
  local id = Wire.id(field and field.trainer)
  if not (id and game and game.data) then return nil end
  return (game.data.trainers or {})[id]
end

-- Trainer record + strongest party level for the invite-joiner prize, looked
-- up from the waiter's concrete npcId against this client's own map data.
-- Never by class alone -- two Bug Catchers on Route 3 must not share a purse.
function M.trainerPrizeInfo(game, npcId)
  if not (npcId and game and game.data) then return nil, 0, nil, nil end
  local ow = M.overworldOf(game)
  local npc = ow and ow.npcPool and ow.npcPool[npcId]
  local def = npc and npc.def
  if not def then return nil, 0, nil, nil end
  local class = def.trainerClass
  local partyIndex = def.trainerParty or 1
  local trainer = class and (game.data.trainers or {})[class] or nil
  if not trainer then return nil, 0, class, partyIndex end
  local partyDef = trainer.parties and trainer.parties[partyIndex]
  local best = 0
  if type(partyDef) == "table" then
    for _, slot in ipairs(partyDef) do
      best = math.max(best, tonumber(slot and slot.level) or 0)
    end
  end
  return trainer, best, class, partyIndex
end

-- Finish a co-op NPC win for a joiner who never held a local BattleState
-- (ACTIONS-menu / invite path): defeat flag, event flag, prize, victory
-- rewards, and afterBattle -- the same contract consume → onFinish pays a
-- walk-in, without inventing a fake battle on the stack.
--
-- Gated by the caller on engineBattle / consume having already run: calling
-- this when a buried engine exists would double-pay and double-onFinish.
--
-- Client bind: npcId must resolve in this client's npcPool, and when the
-- co-op fight names a trainer class (field / engine / screen), that class
-- must match the NPC. Hub cannot verify map data; without the bind a forged
-- wire npcId could mark a random object beaten.
function M:syntheticFinish(game, plan, coopState)
  local npcId = Wire.npcId(plan and plan.npcId)
  if not npcId then return false end
  local save = game and game.save
  if not save then return false end

  local ow = M.overworldOf(game)
  local npc = ow and ow.npcPool and ow.npcPool[npcId]
  if not npc then
    mod.log:warn("co-op win could not finish trainer %s -- that id is not on "
      .. "this map's npcPool; stand near the fight or rejoin from the overworld "
      .. "so the defeat flag is not written against a stranger",
      tostring(npcId))
    return false
  end

  local expected = Wire.id(coopState and coopState.trainer and coopState.trainer.id)
    or Wire.id(plan.engine and plan.engine.trainer and plan.engine.trainer.id)
  if expected then
    local class = npc.def and npc.def.trainerClass
    if Wire.id(class) ~= expected then
      mod.log:warn("co-op win skipped synthetic finish for %s -- npc class %s "
        .. "does not match the fight's trainer %s; reload near the trainer if "
        .. "the defeat flag looks wrong",
        tostring(npcId), tostring(class), tostring(expected))
      return false
    end
  end

  save.defeatedTrainers = save.defeatedTrainers or {}
  save.defeatedTrainers[npcId] = true

  local event = plan.event
  if not event then
    -- Local header as a fallback when an older hub stripped the field: still
    -- keyed by the concrete npcId, never by class.
    local index = npc.def and npc.def.index
    local label = ow and ow.map and ow.map.def and ow.map.def.label
    local header = (index and label and game.data
      and type(game.data.trainerHeader) == "function")
      and game.data:trainerHeader(label, index) or nil
    event = header and Wire.eventFlag(header.event) or nil
  end
  if event then
    save.flags = save.flags or {}
    save.flags[event] = true
  end

  local trainer, best, class, partyIndex = M.trainerPrizeInfo(game, npcId)
  local prize = (tonumber(trainer and trainer.baseMoney) or 0) * best
  if prize > 0 then
    save.money = math.min(999999, (tonumber(save.money) or 0) + prize)
  end

  if ow then
    if class and type(ow.checkVictoryRewards) == "function" then
      local ok, err = pcall(ow.checkVictoryRewards, ow, class, partyIndex)
      if not ok then
        mod.log:warn("co-op victory rewards could not run for %s (%s); badges "
          .. "or items for this fight may need a reload from your last save",
          tostring(class), tostring(err))
      end
    end
    -- Stub battle for afterBattle: evolutions read leveledUp; kind/oppClass
    -- keep the Oak's Lab rival blackout exception honest if it ever lands here.
    local stub = {
      kind = "trainer",
      oppClass = class,
      partyIndex = partyIndex,
      leveledUp = coopState and coopState.leveledUp or nil,
    }
    if type(ow.afterBattle) == "function" then
      local ok, err = pcall(ow.afterBattle, ow, "win", stub)
      if not ok then
        mod.log:warn("co-op afterBattle could not run (%s); evolutions from "
          .. "this fight may need a reload from your last save", tostring(err))
      end
    end
    ow.engaging = false
    npc.frozen = false
  else
    mod.log:warn("no overworld to finish the co-op trainer against; the "
      .. "defeat flag and prize were still written -- reload if the world "
      .. "seems stuck")
  end
  return true
end

function M:startBattle(game, field)
  local battle = self.battle
  if not (battle and not battle.ready) then return false end
  battle.ready = true

  -- The slots crossed the wire carrying *packed* parties -- that is what a
  -- party is on a wire -- so they are turned back into monsters here, and the
  -- two cases are deliberately different.
  --
  -- Somebody else's party is the unpacked copy: rebuilt from real species data
  -- so every client is looking at the same numbers, exactly as LinkBattle
  -- rebuilds a peer's team.
  --
  -- **Our own party is the live one out of the save.** The unpacked copy would
  -- fight identically and then be thrown away -- and with it every point of
  -- damage taken and every point of exp earned. A co-op battle against a
  -- trainer is a real battle, so it has to leave a mark on the save the way any
  -- other trainer battle does.
  local err
  local mine
  local slots = {}
  -- Resolved before the battle is built, not after: the constructor reads the
  -- trainer record off it, and declaring it below meant every co-op battle was
  -- built with a nil trainer -- the AI silently falling back to a heuristic
  -- with nothing to say so.
  local engine = battle.plan and battle.plan.engine
  -- Walk-in harden (mediated coop_npc): if onBattle never adopted the buried
  -- engine fight, claim it now by encounter key or waiter's npcId before the
  -- co-op screen goes up. Left under CoopBattle it resurfaces as an immediate
  -- FIGHT UI the moment the 2-on-2 pops -- historical #20, still the rematch
  -- failure mode when the key/stack race loses under mediation.
  if not engine and battle.plan then
    engine = self:claimBuriedEngine(game, battle.plan)
    if engine then battle.plan.engine = engine end
  end
  -- The trainer, resolved the same way on every client: off the id the field
  -- named, against this build's own data. Whoever walked into them already
  -- holds the record and keeps it; everyone else looks it up. An id that
  -- matches nothing simply leaves the pair nil, and the battle runs without a
  -- face -- which is what a wild-style co-op battle looks like anyway.
  local trainer = M.trainerFor(game, field, engine)
  -- Music / badge identity for computeMusicKind: prefer the buried engine's
  -- oppClass + partyIndex; invite joiners recover them from the waiter's
  -- npcId (PROTOCOL 20) so Giovanni's gym (#3) is not confused with #2.
  local oppClass = engine and engine.oppClass or nil
  local partyIndex = engine and engine.partyIndex or nil
  if (not oppClass or not partyIndex) and battle.plan and battle.plan.npcId then
    local _, _, class, pidx = M.trainerPrizeInfo(game, battle.plan.npcId)
    oppClass = oppClass or class
    partyIndex = partyIndex or pidx
  end
  if not oppClass and trainer then
    oppClass = trainer.id
  end
  partyIndex = tonumber(partyIndex) or 1
  -- The picture, unlike the record, is not re-derived. The engine loads a pic
  -- through its own cache, with the trainer's palette and the padding the
  -- draw offsets assume; loading the file directly would give a differently
  -- coloured, differently placed copy. So the entrance is shown by whoever
  -- walked into them -- which is *both* players on the wait-and-join path,
  -- since each of them triggered the trainer and each holds their own battle.
  -- It is nil only for somebody who walked into nothing: a party-versus-party
  -- fight, and a join taken from the ACTIONS menu. Those open straight on the
  -- monsters rather than on a picture that is subtly wrong.
  -- Gen 2 BattleState keeps the face on enemyTrainerImage (no trainerPic).
  local trainerPic = engine and (engine.trainerPic or engine.enemyTrainerImage)
  for i, slot in ipairs(field.slots or {}) do
    local built = {
      side = slot.side, owner = slot.owner, name = slot.name, bag = slot.bag,
      -- Re-derived from the field rather than read off this client's own save,
      -- even for our own slot: every copy of the battle has to agree about how
      -- hard all four monsters hit, and the field is the one description all
      -- four copies were built from.
      badges = slot.badges,
    }
    if slot.owner and self.party:isSelf(slot.owner) then
      mine = i
      built.party = game and game.save and game.save.party
      built.bag = game and game.save and game.save.inventory
    elseif slot.owner then
      built.party = CoopBattle.unpackParty(game, slot.party)
    else
      -- The NPC side is packed like everyone else's, so it is read back the
      -- same way -- one rule for every party on the field.
      built.party = CoopBattle.unpackParty(game, slot.party)
    end
    if not (built.party and #built.party > 0) then
      return self:abandon("Someone's team\ncouldn't be read.")
    end
    slots[i] = built
  end
  if not mine then return self:abandon("You're not in\nthat battle.") end

  self.inbox = {}
  local inbox = self.inbox
  local net = {
    send = function(payload)
      self.transport:send(Wire.COOP_RELAY, { payload = payload })
    end,
    poll = function()
      local batch = inbox
      self.inbox = {}
      inbox = self.inbox
      return batch
    end,
  }

  local state
  state, err = CoopBattle.new(game, {
    slots = slots,
    mine = mine,
    -- Handed the screen pusher so the fight can put up the prompts it earns
    -- -- today, the naming grid a coop_wild catch owes its catcher.
    ui = self.ui,
    -- Carried from the battle the co-op one displaced: its trainer record is
    -- what the AI reads a class off, and its aiUses is the allowance the
    -- engine had already computed for it.
    trainer = trainer,
    oppClass = oppClass,
    partyIndex = partyIndex,
    aiUses = engine and engine.aiUses,
    trainerPic = trainerPic,
    -- Substituted by whoever started the battle, and lost with it unless it is
    -- carried across: the co-op battle is what actually ends the trainer.
    endBattleText = engine and engine.endBattleText,
    host = battle.host,
    hostId = battle.plan and battle.plan.hostId,
    -- ------- and what it takes for the hub to referee this one instead
    --
    -- Handed in rather than reached for, so the screen owns the whole of the
    -- mediated exchange and this module stays what it is: the thing that agrees
    -- a battle and carries its messages. `transport` is the hub connection
    -- itself and not `net` -- the mmo.battle_* types are addressed to the hub
    -- rather than relayed to the other three, which is the whole difference
    -- between the two paths.
    --
    -- `mode` is derived the same way `kind` on the plan is, and from the same
    -- fact: a co-op battle with human foes is the hub's `coop_pvp`, a wild
    -- divert is `coop_wild`, and one without foes against a trainer is
    -- `coop_npc`. The plan may also carry mode explicitly (hub fan-out on
    -- COOP_BATTLE) so a joiner that never held the encounter still opens the
    -- right screen.
    transport = self.transport,
    battleId = battle.plan and battle.plan.id,
    selfId = self.party and self.party.selfId,
    mode = (function()
      local plan = battle.plan
      if plan and (plan.kind == "wild" or plan.mode == "coop_wild") then
        return "coop_wild"
      end
      if M.ranksPoints(plan) then return "coop_pvp" end
      return "coop_npc"
    end)(),
    wildCatchMon = (function()
      local plan = battle.plan
      if not plan then return nil end
      if plan.kind ~= "wild" and plan.mode ~= "coop_wild" then return nil end
      return plan.wildCatchMon or M.wildMonOf(plan.engine)
    end)(),
    -- Whether a win here is worth points, so the screen can say so once
    -- rather than leave a player wondering why their rating did not move.
    ranksPoints = M.ranksPoints(battle.plan),
    net = net,
    onDone = function(outcome, toLearn)
      self:onBattleOver(outcome, game, state, toLearn)
    end,
  })
  if not state then return self:abandon(err or "That battle can't\nstart.") end

  -- The screen is cleared before the battle goes on it, and both halves of
  -- that matter.
  --
  -- The engine's battle comes off the stack now, and is held for its result.
  -- Left there it would resume the moment the co-op battle popped, and the
  -- player would fight the same trainer twice.
  if engine then
    self:unwindTo(game, engine, true)
    self.engineBattle = engine
  end
  -- The encounter slot is emptied here whatever was in it, and the two cases
  -- it empties are different.
  --
  -- The battle we just displaced is now held in `engineBattle`, and one slot
  -- for one battle is the whole point: `release()` unwinds *to* whatever the
  -- encounter names, and what it named is no longer on the stack.  M:reset
  -- takes that path on a dropped connection, mid-battle.  onBattleOver puts
  -- the battle back in this slot when there is finally a result to hand it.
  --
  -- Anything *else* in the slot is a trainer this battle did not fight, and
  -- must not be told it did.  A player can be standing at a trainer, prompt
  -- up, when a party-versus-party ask arrives and is answered -- and a party
  -- battle displaces nothing, so nothing here would have cleared it.  Left
  -- there, consume() would hand that trainer the *party* battle's result:
  -- marked beaten by a fight they were not in, and their prize money paid.
  -- Dropped instead, their battle is still sitting on the stack and comes back
  -- when this screen pops -- so the trainer is fought, for real, which is rule
  -- 2 and the honest outcome.
  self.encounter = nil
  -- And on the challenge path there is no engine battle to unwind to, which
  -- is exactly how the asker's "Asked NAME for a 2-on-2 battle." box used to
  -- get buried: nothing took it down, the battle screen went on top of it, a
  -- buried state gets no update so it could not be dismissed, and it came
  -- back the moment the battle popped. Unconditional now -- whatever the ask
  -- flow left up, it does not belong under a battle.
  self:closeAskBox()

  self.state = state
  -- The fight is on the screen, so the mark that was pointing at where it was
  -- about to happen has said the whole of what it had to say. Released beside
  -- the state rather than on `running` (which is set a round trip earlier, at
  -- the handoff) because the overworld is still what the player is looking at
  -- until this line -- and that window is the mark's entire life.
  self.offerMarkFor = nil
  self.ui:pushState(game, state)
  return true
end

function M:onBattleOver(result, game, state, toLearn)
  -- Reported before anything is torn down, because the id the hub files it
  -- under lives on the plan that is about to be cleared.
  --
  -- Only a party battle scores -- see M.ranksPoints for why an NPC one does
  -- not, and why that is a choice rather than an oversight.
  local battle = self.battle
  local plan = battle and battle.plan
  -- ...and not at all for a battle the hub refereed.
  --
  -- The vote exists because no client in a host-simulated battle could be
  -- believed about its own win, so four agreeing claims stood in for a witness.
  -- A mediated fight *had* a witness -- it did every roll -- and it has already
  -- settled the ranking from its own verdict; both hubs drop an mmo.result about
  -- one. Suppressed here rather than left to be dropped, because a message sent
  -- on the understanding that it will be ignored is a rule somebody has to
  -- remember, and the screen already knows the answer.
  local refereed = state ~= nil and state.mediated == true
  if plan and plan.id and M.ranksPoints(plan) and not refereed then
    local outcome = "draw"
    if result == "win" then outcome = "win"
    elseif result == "loss" then outcome = "loss" end
    -- A vote, not a verdict: the hub scores nothing until all four agree.
    self.transport:send(Wire.RESULT, { session = plan.id, outcome = outcome })
  end

  -- Tell the hub the battle is over, before the plan that names it is cleared.
  --
  -- Without this the hub never learns a co-op battle ended -- it only ever
  -- closed a relay group when somebody *disconnected* -- so a long-running
  -- server accumulated one dead group per battle ever fought, each still
  -- routing traffic to players who had walked away. The hub closes the whole
  -- group on one goodbye, because a co-op battle ends for everybody at once.
  if plan and plan.id then
    self.transport:send(Wire.COOP_LEAVE, {})
  end

  self.running = false
  -- Latched off the screen before it goes, so the counter survives the state
  -- that produced it. Everything on `coop.state` reads 0 the instant this line
  -- nils it, which is exactly when a caller asking "how did that fight go"
  -- runs -- `exports.coopSync().expPaid` was unreadable for that reason.
  self.lastExpPaid = (self.state and tonumber(self.state.expPaid)) or 0
  self.battle, self.inbox, self.state = nil, nil, nil
  self.lastResult = result
  -- The held battle is put back in the encounter slot so consume() -- the one
  -- place that knows how to finish a trainer off -- can reach it.
  if self.engineBattle then
    -- What levelled, carried across to the battle that is about to be told
    -- how this went: OverworldState:afterBattle offers evolutions to exactly
    -- the mons the battle recorded, and the battle that recorded them here is
    -- the co-op one, not the one holding the flag.
    -- Read off the *battle*, not the sim: exp is applied per client now, so
    -- the list of what levelled is the one this client built for its own
    -- party -- which is exactly the party the evolution check will walk.
    self.engineBattle.leveledUp = state and state.leveledUp or nil
    self.encounter = { engine = self.engineBattle, game = game }
    self.engineBattle = nil
  end
  self:note(("The 2-on-2 ended in a %s."):format(tostring(result)))

  -- Asked here, first, and once.
  --
  -- The question is whether this player's own party has anything left
  -- standing, and everything below is capable of changing that answer: the
  -- ritual heals, and the forget-a-move menu and the engine's post-battle flow
  -- both touch the same party. Asked later it would be answering about the
  -- world after the fix rather than the world that needed one.
  local blackout = M.blacksOut(result, game)

  self:offerForgets(game, toLearn)
  -- Consumed, not dropped. The trainer has been fought -- by four of them --
  -- so the script that was waiting in front of it carries on and the ordinary
  -- 1v1 never runs. Dropping it instead would leave that script suspended for
  -- the rest of the session.
  --
  -- Two answers come back, and between them they say who owes the ritual:
  --
  --   * false -- there was no engine battle behind this one at all: a
  --     party-versus-party fight, or an invite joiner who never walked into
  --     the trainer. Nobody (here) has an onFinish to hand a result to.
  --     Party fights leave blackout to us; invite NPC wins take
  --     M:syntheticFinish below when the waiter's npcId is on the plan.
  --   * true plus engineRitual -- we handed the engine "lose" and its own
  --     afterBattle did the whole vanilla thing. Not ours; running a second
  --     one would halve the money twice.
  --   * true without it -- a won trainer battle whose winner's own team was
  --     wiped. The engine marked the trainer beaten and ran the rewards, and
  --     deliberately did not black anybody out (see M:consume). Ours.
  --
  -- All of it runs *here*, after the battle screen has already come off the
  -- stack: CoopBattle:finish pops the state and StateStack:pop then calls its
  -- exit, which is what reaches this function. The ritual's save writes land
  -- immediately; its warp waits for whatever the two lines above may have put
  -- on screen (see M:pumpBlackout).
  local handled, engineRitual = self:consume(result, blackout)
  -- Invite / menu joiner: no buried BattleState, so consume is a no-op. On a
  -- win, finish the trainer off synthetically from the waiter's npcId --
  -- defeat flag, prize, afterBattle -- without pushing a fake battle. Never
  -- when consume already ran (walk-in engineBattle): that would double-pay.
  if not handled and result == "win" and plan and plan.npcId then
    handled = self:syntheticFinish(game, plan, state)
  end
  if blackout and not (handled and engineRitual) then self:blackout(game) end
end

-- Moves a monster levelled into but had no room for.
--
-- Put to the player *after* the battle, one screen at a time. Opening a
-- forget-a-move menu mid-battle would stop a fight three other people are
-- still in -- and unlike everything else on that screen, this one is a choice
-- only its owner can make and only their own save records.
--
-- The engine's own MoveLearnMenu is pushed rather than a copy of it: it is the
-- screen that already knows how to show four moves and their PP, and how to
-- refuse politely. Gen 2 has no Gen2MoveLearnMenu twin, but the Gen 1 screen
-- still resolves from the registry and works on Gold for the forget prompt —
-- try it rather than silently dropping earned moves.
--
-- Sessions:offerForgets is this function's twin on the mediated 1v1 / wild
-- path, over the same `{ mon, move }` entries: a fight that is not a co-op
-- battle has no co-op state to hand this one, so it states the flow itself.
-- The two differ in how they sequence -- that one hands MoveLearnMenu its own
-- completion callback, this one paces with a "..." box -- and if this ever
-- needs revisiting, that is the version to copy.
function M:offerForgets(game, toLearn)
  if not (game and toLearn and #toLearn > 0) then return false end
  local pending = {}
  for i, entry in ipairs(toLearn) do pending[i] = entry end

  local function nextOne()
    local entry = table.remove(pending, 1)
    if not entry then return end
    local ok = pcall(function()
      mod.ui.push(game, "MoveLearnMenu", entry.mon, entry.move)
    end)
    if not ok then
      -- Auto-fill an empty move slot when the forget UI is missing; otherwise
      -- warn so the player can re-level outside co-op.
      local mon = entry.mon
      local moved = false
      if type(mon) == "table" and type(mon.moves) == "table" and #mon.moves < 4 then
        local mdef = game.data and game.data.moves and game.data.moves[entry.move]
        mon.moves[#mon.moves + 1] = {
          id = entry.move,
          pp = (mdef and mdef.pp) or 5,
        }
        moved = true
        self.ui:say((mon.nickname or mon.species or "POKéMON")
          .. " learned\n" .. tostring(entry.move) .. "!")
      end
      if not moved then
        mod.log:warn("could not open the move-learning screen for %s; it can "
          .. "still be learned by levelling again", tostring(entry.move))
      end
    end
    -- One at a time, so two level-ups do not stack two menus.
    if #pending > 0 then self.ui:say("...", nextOne) end
  end

  nextOne()
  return true
end

-- ------- lifecycle

-- A party ending takes every co-op state with it: an offer with nobody to
-- accept it, and a four-way whose side has just lost a member, are both things
-- that can no longer resolve.
function M:onPartyEnd()
  local hadWait = self.waiting ~= nil
  self.waiting, self.offer, self.offerMarkFor = nil, nil, nil
  if self.ask then
    self.ask = nil
    self:closeAskBox()
    self.ui:say("The 2-on-2 battle\nis off.")
  end
  -- A player standing at a trainer waiting for a partner who has just left the
  -- party is a player waiting for nobody, so the fight is handed back rather
  -- than left suspended. Rule 2: it still ends in a battle.
  if hadWait then
    self.ui:say("There's nobody\nto wait for.", function() self:release() end)
  end
end

function M:onPeerGone(id)
  if not id then return end
  local offer = self.offer
  if offer and offer.from == id then
    self.offer = nil
  end
  -- The mark is anchored on that player's avatar, which is about to be
  -- despawned with them: pointing at where somebody who left was standing is
  -- the one thing it must never do. Keyed off the latch rather than the offer,
  -- which may already have been taken.
  local mark = self.offerMarkFor
  if mark and mark.id == id then
    self.offerMarkFor = nil
  end
  if self.ask and self.ask.peer == id then
    self.ask = nil
    self:closeAskBox()
    self.ui:say("They went offline.")
  end
  -- A live battle has to hear about it too, and this is the case that bites:
  -- the host waits for every human's action before resolving a turn, so a
  -- player who closes the game mid-battle would otherwise leave the other
  -- three sitting on a turn that never resolves.
  if self.state and self.state.peerGone then
    local ok, err = pcall(self.state.peerGone, self.state, id)
    if not ok then
      mod.log:warn("a co-op battle failed to handle a disconnect (%s); leave "
        .. "it from START > MMO if it seems stuck", tostring(err))
    end
  end
end

-- Clocks, and the three things they expire.
--
-- An offer, a wait and an ask are the states here nobody is obliged to answer,
-- so they are the ones that can outlive their moment.  Everything else is a
-- player looking at a box, and a player is allowed to take as long as they
-- like.
--
-- `game` is optional and only the retry uses it: a caller with no stack to
-- look at (the suite, and every tick before the first frame) still gets the
-- clocks, and simply does not re-attempt a standing offer.
function M:update(dt, game)
  dt = dt or 0
  self.clock = self.clock + dt

  -- The fourth thing with a clock, and the only one that is not a question:
  -- a warp this player is already owed, waiting for the screen it needs.
  if self.pendingWarp then self:pumpBlackout(dt) end

  local offer = self.offer
  if offer then
    offer.clock = (offer.clock or 0) + dt
    if offer.clock >= Config.COOP_OFFER_TIMEOUT then
      self.offer = nil
      -- Five minutes of "!" over somebody's head is not a signal any more.
      self.offerMarkFor = nil
      -- Five minutes of being busy is an answer, and the waiter is the one
      -- person who cannot see it: nothing was ever declined, so without this
      -- they keep a box up until their own clock runs out. Sent as `no`
      -- because that is the one reason a hub honours from a client with no
      -- offer of its own (src/Hub.lua's COOP_CANCEL handler and its relay.js
      -- twin) -- and it is what happened: this client is not coming.
      --
      -- Only when we hold no wait of our own, or the same message would clear
      -- *our* offer at the hub instead of answering theirs.
      if not self.waiting and self.transport:isReady() then
        self.transport:send(Wire.COOP_CANCEL, { reason = "no" })
      end
    else
      self:retryOffer(game, dt)
    end
  end

  -- Every wait has a clock, it is the same clock on both flows, and it is now
  -- the *only* thing that ends a wait nobody takes.
  --
  -- The trainer path used to have none, deliberately: the partner's confirm
  -- was a question a human would eventually answer one way or the other, and
  -- a decline released the waiter. There is no confirm any more (M:autoJoin)
  -- and no ALONE row either, so this is the whole of "the partner never came".
  --
  -- SOLO_FALLBACK_AFTER, not COOP_ASK_TIMEOUT -- see the constant for why the
  -- number moved from 60 to 6 when the cover went away. withdraw clears the
  -- hub offer so the partner stops holding one for a wait that is over. Rule 2
  -- still holds: this ends in the battle the engine already built, alone.
  local waiting = self.waiting
  if waiting then
    waiting.clock = (waiting.clock or 0) + dt
    if waiting.clock >= SOLO_FALLBACK_AFTER then
      self:withdraw("timeout")
      -- One line, where there used to be two -- and the same line on grass
      -- as at a trainer (owner: the situation is identical, so is the
      -- honesty). The fight is already on screen behind it, so this is a
      -- sentence over something the player can see rather than the ending
      -- of a screen they were held behind; release() takes the box down
      -- with everything else above the battle.
      local who = self.party:partnerName() or "Your friend"
      local line = ("%s couldn't\njoin!"):format(who)
      self:note(line)
      self.ui:say(line, function() self:release() end)
    end
  end

  local ask = self.ask
  if ask then
    ask.clock = (ask.clock or 0) + dt
    -- Deliberately later than the hub's own clock -- see COOP_ASK_GRACE. This
    -- is the backstop for a hub that never speaks, not the normal ending: in
    -- the ordinary case the hub expires the ask first and tells all four, and
    -- this never fires at all.
    if ask.clock >= Config.COOP_ASK_TIMEOUT + Config.COOP_ASK_GRACE then
      -- Told, not just dropped. Giving up locally while the hub still holds
      -- the ask is what left a player able to challenge again into silence.
      if ask.role == "asked" and ask.id then
        self.transport:send(Wire.COOP_ANSWER, { id = ask.id, accept = false })
      elseif ask.role == "asker" then
        self.transport:send(Wire.COOP_CANCEL, { reason = "timeout" })
      end
      self.ask = nil
      self:closeAskBox()
      self.ui:say("Nobody answered\nin time.")
    end
  end
end

return M
