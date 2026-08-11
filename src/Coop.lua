-- Co-op battles: the two of you against one trainer, the two of you against
-- the two of them, and (when partied on the same map) the two of you against
-- one wild encounter.
--
-- Three flows live here, and they are less alike than they look.
--
--   * **Against an NPC.**  One partner walks into a trainer, is asked whether
--     to wait or to go in alone. Waiting is allowed even when the partner is
--     on another map: the invite is stored for them and the join confirm pops
--     automatically when they arrive. They can leave wait mode and take the
--     trainer alone at any time. Accept → both fight it together. Decline →
--     the waiter is told, encouraged, and released into a solo 1v1.
--   * **Against a wild.**  Same-map partner online and free → divert into
--     mediated `coop_wild`: host posts COOP_WAIT and covers the engine wild
--     with a wait box (ALONE = withdraw + solo). Partner auto-joins; no
--     WAIT/JOIN invite. Soft-lock: a wait with no join within COOP_ASK_TIMEOUT
--     withdraws and releases into solo wild. Mutual waits arbitrate by
--     lexicographically smaller playerId (their wait wins; see considerOffer).
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
-- 1. **A decline ends the wait.**  Saying no to an NPC invite tells the
--    waiter (via the hub), clears the offer, and sends them into the solo
--    fight the engine already built under their prompt. The decliner is not
--    dragged into anything -- if they never walked into the trainer, "no" is
--    simply no.
-- 2. **The fight cannot be dodged.**  Once a trainer has been triggered, every
--    exit from every prompt this module raises ends in a battle.  B on the
--    wait/alone choice is BATTLE ALONE, not "never mind"; B while waiting
--    reopens that same choice rather than releasing the player.  The engine
--    has already committed to the encounter by the time we are asked, so a
--    prompt that could be escaped would be a prompt that skipped a trainer.
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
local CoopBattle = need("CoopBattle")

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
    -- the four-way PARTY BATTLE ask, ours or theirs
    ask = nil,
    -- Battle key of an NPC join confirm already on screen, so onOffer and
    -- walking into the same trainer do not stack a second box.
    joinAsk = nil,
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

-- ------- state

function M:reset()
  -- The encounter is released rather than dropped.  Losing the connection
  -- mid-prompt must not leave a player frozen in front of a trainer with a
  -- suspended script and no box on screen -- rule 2 outlives the hub.
  self:release()
  self:closeAskBox()
  self.waiting, self.offer, self.ask = nil, nil, nil
  self.joinAsk, self.joinBox = nil, nil
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
-- once-only guard is what makes that safe to say: a player who picks BATTLE
-- ALONE while a join is already in flight, or whose party dissolves in the
-- same frame the hub answers, would otherwise resume one suspended script
-- twice -- and the second resume runs a battle nobody is standing in front of.
-- Let the engine's own battle happen: close the prompt and get out of the way.
--
-- Nothing is resumed and nothing is started, because nothing was ever stopped
-- -- the battle has been sitting under the prompt the whole time.
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
function M:consume(result, blackout)
  local encounter = self.encounter
  self.encounter = nil
  if not encounter then return false end
  local engine = encounter.engine
  if not (engine and engine.onFinish) then return false end

  -- Prize money, which the engine pays from inside its own battle screen and
  -- so never gets to pay for one it did not run. Its formula, at the level of
  -- the strongest monster the trainer had -- a 2-on-2 has two last opponents,
  -- and paying for the better of them is the reading that cannot be gamed by
  -- ordering the party.
  if result == "win" and engine.trainer then
    local best = 0
    for _, mon in ipairs(engine.enemyParty or {}) do
      best = math.max(best, tonumber(mon.level) or 0)
    end
    local prize = (tonumber(engine.trainer.baseMoney) or 0) * best
    local save = encounter.game and encounter.game.save
    if prize > 0 and save then
      save.money = math.min(999999, (tonumber(save.money) or 0) + prize)
    end
  end

  -- Paid *before* the blackout, and halved by it, which is the order vanilla
  -- uses too: BattleState pays PAY DAY and the prize inside the battle, and
  -- only then does the whiteout tax what is left.
  local outcome = result or "draw"
  local engineRitual = false
  if blackout and outcome ~= "win" then
    outcome = "lose"
    engineRitual = true
  end

  local ok, err = pcall(engine.onFinish, outcome)
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
function M.blacksOut(result, game)
  if result == "loss" then return true end
  local party = game and game.save and game.save.party
  if type(party) ~= "table" or #party == 0 then return false end
  for _, mon in ipairs(party) do
    if (tonumber(mon.hp) or 0) > 0 then return false end
  end
  return true
end

-- Where a blackout returns to, resolved the way OverworldState:healPoint
-- resolves it: the Center this player last slept in, then the world's own
-- declared boot heal point, then the spawn cell.
--
-- Read rather than asked for, because there is no facade call for it -- and
-- read in the engine's order rather than a simpler one, so a modded world that
-- moved its starting town sends co-op losers to the same place a solo loss
-- would. Nil is a real answer for a build with no field data at all, and the
-- caller declines to warp rather than guessing a map name.
function M.healPoint(game)
  local save = game and game.save
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
function M:blackout(game)
  local save = game and game.save
  if not save then
    mod.log:warn("a lost 2-on-2 could not black you out (no save); walk to a "
      .. "POKéMON CENTER to heal")
    return false
  end

  M.healParty(game)
  -- The world's own divisor if it names one, read off data the same way
  -- badgesOf reads the badge rows -- a mod that retunes the penalty retunes it
  -- here too. Two is vanilla.
  local world = game.data and game.data.constants and game.data.constants.world
  local divisor = tonumber(world and world.blackoutMoneyDivisor) or 2
  if divisor > 0 then
    save.money = math.floor((tonumber(save.money) or 0) / divisor)
  end
  -- DisplayPlayerBlackedOutText clears BIT_ALWAYS_ON_BIKE; a player who blacks
  -- out on a forced-bike route wakes up on foot, not pedalling indoors.
  save.forcedBike = nil

  local target = M.healPoint(game)
  local api = mod.world
  if not (api and target and target.map) then
    -- Healed and taxed but not moved. Said out loud rather than silently
    -- half-done: the player is standing somewhere they did not expect to be.
    mod.log:warn("a lost 2-on-2 healed your party but could not send you to a "
      .. "POKéMON CENTER; walk out and back in, or reload your last save")
    return false
  end
  self.pendingWarp = { game = game, target = target, clock = 0 }
  return self:pumpBlackout(0)
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

  pending.clock = (pending.clock or 0) + (dt or 0)
  local stack = pending.game and pending.game.stack
  local top = stack and stack.top and stack:top()
  if not (top and top.isOverworld) then
    if pending.clock < BLACKOUT_WARP_WAIT then return false end
    -- Given up on rather than fired blind. The party is healed and the money
    -- is already gone, so this is a player standing in the wrong place, not a
    -- player stuck at zero HP.
    self.pendingWarp = nil
    mod.log:warn("your party was healed after the 2-on-2 but the trip to a "
      .. "POKéMON CENTER never got a chance to start; walk there, or reload "
      .. "from your last save")
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
    mod.log:warn("a lost 2-on-2 healed your party but the warp to a POKéMON "
      .. "CENTER failed (%s); reload from your last save if you are stuck",
      tostring(ok and why or done))
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

-- What to call a fight in a sentence.  A script-driven battle need not name
-- its trainer, and "a battle" is a better answer than refusing the whole offer
-- over a cosmetic field.
local function fightName(label)
  return label or "a battle"
end

-- ------- against an NPC: the player who arrives first
--
-- Called when this player triggers a trainer battle.  `startAlone` is the
-- continuation that runs the ordinary 1v1 -- the engine has already decided
-- there is a battle, and every path through here ends by calling it or by
-- handing over to a co-op one.
--
-- Returns true when this module took the encounter over (a prompt is up, and
-- startAlone will be called later or not at all), false when the caller should
-- simply proceed.  False is the answer for a player who is not in a party or
-- not connected: co-op is an addition to the game, and a lone player must
-- never notice it exists.
-- Called when the engine has just pushed a trainer battle.
--
-- **The battle object is the whole trick here.** It has already been built and
-- pushed by the engine -- its enemy party is real, its `onFinish` is wired to
-- the overworld's entire post-battle flow (the defeated-trainer flag, victory
-- rewards, the whiteout, the script that was waiting) -- and none of that is
-- anything a mod should be reimplementing.
--
-- So the prompt goes on top of it rather than instead of it, and the two
-- answers do very different things with almost no code:
--
--   * BATTLE ALONE simply closes the prompt. The engine's battle is sitting
--     underneath, frozen because a StateStack only updates its top, and it
--     resumes untouched. Nothing was intercepted at all.
--   * The co-op path pops it, holds it, fights the 2-on-2 in its place, and
--     then calls its `onFinish` with the result -- so the trainer is marked
--     beaten, the badge is awarded, a wipe blacks you out and the script
--     carries on, exactly as if one player had fought it.
--
-- Returns true when a prompt is up. False means the encounter is none of this
-- module's business, and the engine's battle is left completely alone.
function M:onTrainerBattle(game, state, mapId)
  if not (state and state.kind == "trainer") then return false end
  if not (self.transport:isReady() and self.party:has()) then return false end
  if self.running then return false end
  -- Partner has to be online (in the roster). Same map is *not* required: the
  -- waiter may hold the encounter until they arrive, and the invite pops for
  -- them on map.entered. Offline / no partner means this is a solo fight.
  local partner = self.party:partner()
  local here = partner and self.roster:get(partner.id)
  if not here then return false end

  local label = Wire.label(tostring(state.oppClass or ""):gsub("^OPP_", "")
    :gsub("_", " "))
  -- The trainer class alone is not quite specific enough: one map can hold two
  -- of the same class with different parties. The lead monster's species and
  -- level tell those apart, and both partners derive them from the battle their
  -- own engine just built -- so they agree by both looking at the same trainer
  -- rather than by trusting a value one of them sent.
  local lead = state.enemyParty and state.enemyParty[1]
  local key = M.battleKey(mapId, state.oppClass,
    lead and lead.species, lead and lead.level)

  self.encounter = {
    battle = key,
    label = label,
    map = mapId,
    -- The engine's own battle, held so the co-op path can hand it its result.
    engine = state,
    game = game,
  }

  if self:offerMatches(key) then
    self:askToJoin(game, self.offer)
    return true
  end
  self:askWaitOrAlone(game)
  return true
end

-- The wild mon the engine just built, for a grant and for the battle key.
--
-- Wild BattleState keeps the mon on `enemy.mon` (newWild never fills
-- enemyParty). Trainer battles put it in enemyParty[1]. Both shapes are
-- accepted so a headless fixture that only stubs enemyParty still works.
function M.wildMonOf(state)
  if type(state) ~= "table" then return nil end
  local mon = state.enemyParty and state.enemyParty[1]
  if mon then return mon end
  local enemy = state.enemy
  return enemy and enemy.mon or nil
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
-- beginWildCoop posts COOP_WAIT and covers the engine wild with a wait box so
-- the host cannot fight solo while the partner auto-joins (see considerOffer).
function M:onWildEncounter(game, state, mapId)
  if not (state and state.kind == "wild") then return false end
  if not (self.transport:isReady() and self.party:has()) then return false end
  if self.running or self.waiting or self.ask then return false end
  if self.joinAsk then return false end
  if self.offer then
    if self.offer.mode ~= "coop_wild" then return false end
    -- Partner already waiting on grass: join them; do not start a local wait.
    if not self:partnerOnMap(mapId) then return false end
    if self:inFightExcept(game, state) then return false end
    local partner = self.party:partner()
    local row = partner and self.roster:get(partner.id)
    if row and row.busy then return false end
    local offer = self.offer
    -- Pop the just-pushed wild; their battle key will not match ours, so
    -- joinedEngine would leave this fight under the co-op screen otherwise.
    if game and game.stack and game.stack:top() == state then
      game.stack:pop()
    end
    return self:autoJoinWild(offer)
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

-- Start a Party vs Wild wait: same wire as trainer WAIT, with a covering box
-- so the engine wild under it cannot update (frozen until join / ALONE /
-- timeout). Short clock still applies -- see M:update.
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
  self:showWildWaiting()
  return true
end

-- Is this state still on the stack at all?
--
-- Three answers, not two: true, false, and *nil* for "this stack cannot say".
-- A caller that treats "cannot say" as "no" would refuse to unwind anything at
-- all against a stack that only offers a top, and a caller that treats it as
-- "yes" is exactly as safe as it was before this existed. Both readings are
-- used below.
function M:onStack(game, target)
  local stack = game and game.stack
  local states = stack and stack.states
  if not (target and type(states) == "table") then return nil end
  for i = #states, 1, -1 do
    if states[i] == target then return true end
  end
  return false
end

-- Take everything above `target` off the stack, and optionally `target` too.
--
-- The prompt is one or two widget states deep depending on how far the player
-- got, so this unwinds by identity rather than by counting -- a fixed number of
-- pops is a guess, and a wrong guess here either leaves a menu on screen or
-- eats the world underneath it.
function M:unwindTo(game, target, alsoPop)
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
  if self:onStack(game, target) == false then return false end
  local guard = 0
  while stack:top() and stack:top() ~= target and guard < 16 do
    stack:pop()
    guard = guard + 1
  end
  if alsoPop and stack:top() == target then stack:pop() end
  return true
end

-- Whether the partner is currently standing on `mapId`.
--
-- Absence (offline, no roster row) is not "elsewhere" -- it is nobody to wait
-- for, and onTrainerBattle already refused that case. A real row on another
-- map is the wait-for-arrival path.
function M:partnerOnMap(mapId)
  if not mapId then return false end
  local partner = self.party:partner()
  local row = partner and self.roster:get(partner.id)
  return row ~= nil and row.map == mapId
end

-- The choice that cannot be escaped.
--
-- Two rows and no cancel: Ui:choose maps B onto the *last* row, and the last
-- row is BATTLE ALONE.  That is rule 2 in one line -- a player who keeps
-- pressing B fights the trainer by themselves, which is what would have
-- happened without this mod installed, rather than walking away from an
-- encounter the engine has already begun.
function M:askWaitOrAlone(game)
  local name = self.party:partnerName() or "your friend"
  local mapId = self.encounter and self.encounter.map
  local prompt = self:partnerOnMap(mapId)
    and ("Battle with %s?"):format(name)
    or ("Wait for %s\nto arrive?"):format(name)

  self.ui:choose(game, prompt, {
    { label = "WAIT", onSelect = function() self:beginWait() end },
    {
      label = "ALONE",
      onSelect = function()
        -- Withdraw before releasing.  If an offer of ours is still standing,
        -- the partner's client has to stop showing it before this side
        -- disappears into a battle -- an offer whose owner is already fighting
        -- is the one thing the partner can do nothing about.
        self:withdraw("alone")
        self:release()
      end,
    },
  })
end

-- Start waiting, and tell the partner.
--
-- The encounter is deliberately *not* released here: this is the one branch
-- that does not end in a battle straight away, and holding the continuation is
-- what leaves the player standing in front of the trainer instead of fighting
-- it.  Everything that ends the wait -- joining, giving up, the party
-- dissolving, the connection dropping -- releases it.
--
-- The offer is sent immediately even when the partner is on another map: their
-- client stores it and only raises the join confirm once they share this map
-- (see M:considerOffer / map.entered).
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
    clock = 0,
  }
  self.transport:send(Wire.COOP_WAIT, {
    battle = encounter.battle,
    label = encounter.label,
    map = encounter.map,
  })
  local name = self.party:partnerName() or "your friend"
  if self:partnerOnMap(encounter.map) then
    self:note(("Waiting for %s at %s."):format(name, fightName(encounter.label)))
  else
    self:note(("Waiting for %s to\narrive at %s."):format(
      name, fightName(encounter.label)))
  end
  self:showWaiting()
  return true
end

-- The box the waiting player stands behind.
--
-- Two rows: BACK reopens wait/alone; ALONE is last so B leaves wait and fights
-- solo -- rule 2 still holds from wait mode. The partner's invite stays up
-- until ALONE (or timeout), so a BACK that later picks WAIT again does not
-- flicker their confirm away.
function M:showWaiting()
  local waiting = self.waiting
  if not waiting then return end
  local name = self.party:partnerName() or "your friend"
  local prompt = self:partnerOnMap(waiting.map)
    and ("Waiting for %s..."):format(name)
    or ("Waiting for %s\nto arrive..."):format(name)
  -- nil game, like every other prompt this module raises: Ui falls back to the
  -- context's current game, which is the only one there is.
  self.ui:choose(nil, prompt, {
      {
        label = "BACK",
        onSelect = function()
          self:askWaitOrAlone(nil)
        end,
      },
      {
        label = "ALONE",
        onSelect = function()
          self:withdraw("alone")
          self:release()
        end,
      },
    })
end

-- Cover the engine wild while a Party vs Wild offer stands.
--
-- Single row: ALONE is last (and only), so B maps to withdraw+release and the
-- host fights the engine wild solo -- same ending as trainer ALONE, without a
-- BACK row that would reopen a WAIT/ALONE ask this path never showed. The
-- choose screen is stack-top, so the wild underneath cannot update until this
-- pops (join → startBattle, ALONE/timeout → release, or arbitration unwind).
function M:showWildWaiting()
  local waiting = self.waiting
  if not (waiting and waiting.mode == "coop_wild") then return end
  local name = self.party:partnerName() or "your friend"
  local prompt = ("Waiting for %s..."):format(name)
  self.ui:choose(waiting.game, prompt, {
    {
      label = "ALONE",
      onSelect = function()
        self:withdraw("alone")
        self:release()
      end,
    },
  })
end

-- Take our offer off the table.  Safe to call when there is none: every exit
-- from a fight goes through here, and making each of them check first would be
-- four places to forget.
function M:withdraw(reason)
  if not self.waiting then return false end
  self.waiting = nil
  self.transport:send(Wire.COOP_CANCEL, { reason = Wire.coopReason(reason) })
  return true
end

-- Take the join confirm down, if it is still up.
--
-- Same rule as closeAskBox: only when the held box is what the player is
-- looking at. An offer ending under a menu leaves the confirm alone rather
-- than popping sixteen states hunting for it.
function M:closeJoinBox()
  local held = self.joinBox
  self.joinBox = nil
  self.joinAsk = nil
  if not held then return false end
  local stack = held.game and held.game.stack
  local states = stack and stack.states
  if not (states and held.box) then return false end
  if states[#states] ~= held.box then return false end
  return self:unwindTo(held.game, held.box, true)
end

-- One sentence for "they went in alone", shared by the offer ending under the
-- confirm and by a yes that arrives after the wait is already over -- so a
-- race cannot print it twice.
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

-- Push the join confirm when an offer is live and we are free to answer it.
--
-- Same-map only: an invite for a fight three screens away is stored (chat
-- note + JOIN row) but not shoved in the player's face. Mid-fight and mid-
-- wait are also quiet -- a box over a wild encounter is worse than a note.
--
-- `coop_wild` never asks: partner auto-joins when free on the same map, which
-- is the whole Party vs Wild product rule. Busy / off-map leaves the offer
-- standing so the host's short wait can time out into solo wild.
--
-- Mutual coop_wild waits: lexicographically smaller playerId's wait wins.
-- If offer.from < selfId we withdraw our wait and join theirs; otherwise we
-- keep ours and drop the inbound offer so both sides cannot time out stuck.
function M:considerOffer(game, myMap)
  local offer = self.offer
  if not offer then return false end
  if self.joinAsk or self.ask or self.running then return false end
  if not (offer.map and myMap and offer.map == myMap) then return false end

  if offer.mode == "coop_wild" then
    if self.waiting then
      if self.waiting.mode ~= "coop_wild" then return false end
      local selfId = self.party and self.party.selfId
      local from = offer.from
      if not (selfId and from) then return false end
      if from < selfId then
        return self:autoJoinWild(offer)
      end
      -- Ours wins; clear inbound so waiting+offer cannot block later gates.
      self.offer = nil
      return false
    end
    -- Covered wild under a wait box counts as inFight; free joiners must not
    -- be mid-fight. Mutual wait is handled above before this check.
    if self:inFight(game) then return false end
    return self:autoJoinWild(offer)
  end

  if self.waiting or self:inFight(game) then return false end
  return self:askToJoin(game, offer)
end

-- Answer a Party vs Wild offer without a confirm box.
--
-- When called while we already hold a coop_wild wait (mutual divert / menu
-- JOIN after arbitration chose their offer), withdraw ours and discard the
-- local engine wild first -- their battle key will not match ours.
-- Same rule as considerOffer: only join over our wait when offer.from < selfId.
function M:autoJoinWild(offer)
  if not (offer and offer.mode == "coop_wild") then return false end
  if not self.transport:isReady() then return false end
  if self.running or self.ask then return false end
  if self.waiting then
    if self.waiting.mode ~= "coop_wild" then return false end
    local selfId = self.party and self.party.selfId
    local from = offer.from
    if not (selfId and from and from < selfId) then return false end
    -- Quiet cancel: onOfferEnd does not announce timeout the way alone/left do.
    self:withdraw("timeout")
    local enc = self.encounter
    self.encounter = nil
    if enc and enc.engine then
      self:unwindTo(enc.game, enc.engine, true)
    end
  end
  local from, battle = offer.from, offer.battle
  -- Cleared before the send so a second considerOffer tick cannot double-join.
  -- A late alone from the hub still lands as COOP_OFFER_END with no box up.
  self.offer = nil
  self.transport:send(Wire.COOP_JOIN, { to = from, battle = battle })
  return true
end

-- The yes/no that ends somebody else's wait.
--
-- No tells the waiter (rule 1) and clears the offer. The decliner is not
-- pulled into a fight they never walked into -- release is a no-op unless
-- they also triggered the trainer themselves.
function M:askToJoin(game, offer)
  if not offer then return false end
  if self.joinAsk then return true end
  self.joinAsk = offer.battle
  local box = self.ui:confirm(game,
    ("Join %s against\n%s?"):format(offer.name, fightName(offer.label)),
    function(yes)
      self.joinBox = nil
      self.joinAsk = nil
      if not yes then
        -- Tell the waiter, then step out of the way. Hub clears their offer
        -- and delivers COOP_DECLINE; they go in alone.
        if self:offerMatches(offer.battle) then
          self.offer = nil
          self.transport:send(Wire.COOP_CANCEL, { reason = "no" })
        end
        self:release()
        return
      end
      -- Re-checked at the moment of answering rather than only when the box
      -- went up: the partner may have given up and gone in alone while this
      -- sat on screen waiting for a human. Same sentence as onOfferEnd -- a
      -- yes that is simply late is not a different story from the box being
      -- taken down under them.
      if not self:offerMatches(offer.battle) then
        self:announceAlone(offer.name, function() self:release() end)
        return
      end
      self.transport:send(Wire.COOP_JOIN,
        { to = offer.from, battle = offer.battle })
    end)
  self.joinBox = box and { box = box, game = game } or nil
  return true
end

-- Walking up to the partner and pressing A, or picking them off the roster,
-- reaches the same yes/no -- which is the third way in. It answers false when
-- there is nothing standing, and the ACTIONS menu uses that to decide whether
-- to offer the row at all.
function M:joinFromMenu(game)
  local offer = self.offer
  if not offer then return false end
  -- No encounter is set: nobody triggered a trainer to get here, so releasing
  -- is a no-op and "no" is simply no, leaving the player standing where they
  -- were rather than dropping them into a fight they never walked into.
  -- coop_wild never shows the confirm -- same auto-join as considerOffer.
  if offer.mode == "coop_wild" then
    return self:autoJoinWild(offer)
  end
  return self:askToJoin(game, offer)
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
  -- Yes/no first: an invite that ended under the confirm must not leave a
  -- box that can only be answered into a late-yes path.
  self:closeJoinBox()
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
-- outlive its battle: a player who says yes keeps theirs deliberately (see
-- M:askToJoin) and the hub can still drop that join -- the partner pressing
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

  local packed = CoopBattle.packParty(game and game.save and game.save.party)
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
-- Read off the badge *rows* rather than off a list written down here, so a mod
-- that adds a badge -- or retunes which ones boost what -- is covered without
-- this file knowing about it. Only the rows can matter: `makeBattler` walks
-- them and asks the bag, so a badge nothing boosts is a badge nothing reads.
function M.badgesOf(game)
  local data = game and game.data
  local inventory = game and game.save and game.save.inventory
  if not (data and inventory) then return nil end
  local rows = data.constants and data.constants.badgeBoosts
  if not rows then
    local ok, Damage = pcall(require, "src.battle.Damage")
    rows = ok and Damage and Damage.BADGE_BOOSTS or nil
  end
  local out = {}
  for _, row in ipairs(rows or {}) do
    if row.badge and inventory[row.badge] then out[#out + 1] = row.badge end
  end
  if #out == 0 then return nil end
  return out
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
                    party = CoopBattle.packParty(left) }
  if #right > 0 then
    out[#out + 1] = { side = "b", owner = nil, name = label,
                      party = CoopBattle.packParty(right) }
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
  -- The trainer, resolved the same way on every client: off the id the field
  -- named, against this build's own data. Whoever walked into them already
  -- holds the record and keeps it; everyone else looks it up. An id that
  -- matches nothing simply leaves the pair nil, and the battle runs without a
  -- face -- which is what a wild-style co-op battle looks like anyway.
  local trainer = M.trainerFor(game, field, engine)
  -- The picture, unlike the record, is not re-derived. The engine loads a pic
  -- through its own cache, with the trainer's palette and the padding the
  -- draw offsets assume; loading the file directly would give a differently
  -- coloured, differently placed copy. So the entrance is shown by whoever
  -- walked into them -- which is *both* players on the wait-and-join path,
  -- since each of them triggered the trainer and each holds their own battle.
  -- It is nil only for somebody who walked into nothing: a party-versus-party
  -- fight, and a join taken from the ACTIONS menu. Those open straight on the
  -- monsters rather than on a picture that is subtly wrong.
  local trainerPic = engine and engine.trainerPic
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
    -- Carried from the battle the co-op one displaced: its trainer record is
    -- what the AI reads a class off, and its aiUses is the allowance the
    -- engine had already computed for it.
    trainer = trainer,
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
  --   * false -- there was no engine battle behind this one at all, which is
  --     what a party-versus-party battle always is. Nobody walked into a
  --     trainer, so there is no onFinish to hand a result to and nothing
  --     anywhere that will black anybody out. Ours.
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
-- refuse politely.
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
      -- The screen is the engine's; if a build has not got it, say so and
      -- move on rather than swallowing a level-up the player earned.
      mod.log:warn("could not open the move-learning screen for %s; it can "
        .. "still be learned by levelling again", tostring(entry.move))
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
  self.waiting, self.offer = nil, nil
  self:closeJoinBox()
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
    self:closeJoinBox()
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

-- Clocks, and the two things they expire.
--
-- An offer and an ask are the only states here that nobody is obliged to
-- answer, so they are the only two that can outlive their moment.  Everything
-- else is a player looking at a box, and a player is allowed to take as long
-- as they like.
function M:update(dt)
  dt = dt or 0
  self.clock = self.clock + dt

  -- The third thing with a clock, and the only one that is not a question:
  -- a warp this player is already owed, waiting for the screen it needs.
  if self.pendingWarp then self:pumpBlackout(dt) end

  local offer = self.offer
  if offer then
    offer.clock = (offer.clock or 0) + dt
    if offer.clock >= Config.COOP_OFFER_TIMEOUT then self.offer = nil end
  end

  -- Waiting has no clock on the trainer path, deliberately.
  --
  -- The offer and the ask both expire, because both are questions somebody may
  -- never answer. Standing at a fight is not a question: the battle cannot be
  -- dodged (rule 2), so there is nothing for a wait to expire *to* -- B on the
  -- waiting screen reopens the wait/alone choice, and BATTLE ALONE is how it
  -- ends. A clock here used to be accumulated and never read, which reads as
  -- an expiry somebody forgot to finish.
  --
  -- Party vs Wild is the exception: the partner is auto-pulled with no JOIN
  -- confirm, so a busy/lagging partner would leave the host on a covering wait
  -- box forever. COOP_ASK_TIMEOUT is short enough that solo wild resumes before
  -- the grass fight feels abandoned, and withdraw clears the hub offer so the
  -- partner stops holding it.
  local waiting = self.waiting
  if waiting and waiting.kind == "wild" then
    waiting.clock = (waiting.clock or 0) + dt
    if waiting.clock >= Config.COOP_ASK_TIMEOUT then
      self:withdraw("timeout")
      self:release()
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
