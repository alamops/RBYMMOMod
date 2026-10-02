-- src/SoloBattle.lua: the referee a player with nobody to play with gets.
--
-- Run: luajit tests/solo_battle.lua                 (from this folder's root)
--   or luajit mods/rby_mmo/tests/solo_battle.lua    (from the engine)
--
-- Standalone, for the reason tests/battle_sim_turn.lua is: the claim this
-- feature makes is that a solo fight is a `Turn` built and pumped in this
-- process with no socket, no hub and no protocol version between a
-- single-player game and its own battles -- so it loads the shipped files
-- through the same `need`-shaped resolver main.lua uses, hands them a stub
-- facade the way tests/rby_mmo_test.lua does, and drives a whole fight with no
-- love, no display and no engine.
--
-- ------- and `package.path` is pinned empty on purpose
--
-- Every engine reach in this graph is a lazy `pcall(require, ...)`:
-- MediatedBattle's renderer, Coop's warp, SoloBrain's TrainerAI. Run from the
-- engine checkout those resolve and run from this folder they do not, which
-- would make the same suite a different suite depending on which directory it
-- was started in -- and the sharpest end of that is `SoloBrain`, whose default
-- RNG is `math.random`: with the engine reachable a trainer fight stops being a
-- pure function of its seed. Blanking the search path makes every one of those
-- requires fail the same way in both places, which is both what keeps this
-- suite deterministic and what proves the fallback contract SoloBattle states
-- outright: a nil brain is not a failure, `Turn:autoPick` answers for the
-- opponent, and the fight still runs. The brain itself is tests/solo_brain.lua.
--
-- Legal: every species, move and trainer below is invented for this file. No
-- ROM-derived name appears in it. The item ids are the ones `BattleSim`'s own
-- effect table is keyed on, exactly as tests/battle_sim_turn.lua uses them.

package.path = ""

-- ------------------------------------------------------------------
-- where we are
-- ------------------------------------------------------------------

local ROOT = "."
do
  local invoked = arg and arg[0]
  local dir = invoked and invoked:match("^(.*)[/\\]tests[/\\][^/\\]+$")
  if dir and dir ~= "" then ROOT = dir end
end

local function slurp(path)
  local handle = io.open(path, "rb")
  if not handle then return nil end
  local body = handle:read("*a")
  handle:close()
  return body
end

-- ------------------------------------------------------------------
-- the mod facade, and the module graph resolved through it
-- ------------------------------------------------------------------

local warns = {}
local errors = {}
local prompts = {}      -- what Coop.offerForgets pushed, in order

local stubMod = {
  id = "rby_mmo",
  path = ROOT,
  log = {
    info = function() end,
    warn = function(_, fmt, ...)
      local ok, line = pcall(string.format, fmt, ...)
      warns[#warns + 1] = ok and line or tostring(fmt)
    end,
    error = function(_, fmt, ...)
      local ok, line = pcall(string.format, fmt, ...)
      errors[#errors + 1] = ok and line or tostring(fmt)
    end,
  },
  -- The forget prompt's only seam. `Coop.offerForgets` calls
  -- `mod.ui.push(game, "MoveLearnMenu", mon, move)` and the engine's screen
  -- goes straight onto the stack, so a stand-in that records *and pushes* is
  -- what makes the ordering question in section 10 answerable at all.
  ui = {
    push = function(game, screen, mon, move)
      prompts[#prompts + 1] = {
        screen = screen, mon = mon, move = move,
        top = game and game.stack and game.stack:top(),
      }
      if game and game.stack then game.stack:push({ moveLearn = true }) end
    end,
  },
  options = { get = function() return false end },
}

local loadstr = loadstring or load
local cache = {}
local function need(name)
  if cache[name] ~= nil then return cache[name] end
  local path = ROOT .. "/src/" .. name .. ".lua"
  local body = slurp(path)
  if not body then error("missing " .. path, 0) end
  local chunk, err = loadstr(body, "@" .. name .. ".lua")
  if not chunk then error(tostring(err), 0) end
  cache[name] = chunk(need, stubMod)
  return cache[name]
end

local Config = need("Config")
local Coop = need("Coop")
local Turn = need("BattleSim/Turn")
local Solo = need("SoloBattle")

-- The two seat ids src/SoloBattle.lua holds the referee's fighters under.
-- Private there and restated here rather than exported: they are the vocabulary
-- of the fight this suite is driving, and a rename that broke them would break
-- every assertion below loudly rather than silently.
local PLAYER, FOE = "solo_player", "solo_foe"

-- ------------------------------------------------------------------
-- assertions
-- ------------------------------------------------------------------

local passed, failed = 0, 0

local function ok(condition, what)
  if condition then
    passed = passed + 1
  else
    failed = failed + 1
    io.stderr:write("FAIL " .. tostring(what) .. "\n")
  end
end

local function eq(actual, expected, what)
  if actual == expected then
    passed = passed + 1
  else
    failed = failed + 1
    io.stderr:write(string.format("FAIL %s: expected %s, got %s\n",
      tostring(what), tostring(expected), tostring(actual)))
  end
end

-- ------------------------------------------------------------------
-- fixtures
-- ------------------------------------------------------------------
--
-- A dataset with two invented species and one invented move, which is all
-- `MediatedBattle.snapshotMons` needs: a species it cannot find falls back to
-- the id, and a move it cannot find becomes a 40-power neutral hit. The type
-- chart exists because `snapshotRuleset` reads the axes off it.

local data = {
  type_chart = {
    types = { NORM = {}, FIRE = {} },
    matchups = {},
  },
  moves = {
    THUMP = { power = 40, accuracy = 100, type = "NORM", pp = 20 },
  },
  pokemon = {
    ALPHA = { name = "ALPHA", types = { "NORM" }, catchRate = 200 },
    BETA  = { name = "BETA",  types = { "NORM" }, catchRate = 200 },
  },
  items = {},
  constants = {},
}

local function mon(o)
  o = o or {}
  local maxHp = o.maxHp or 60
  return {
    species = o.species or "ALPHA",
    level = o.level or 20,
    hp = o.hp or maxHp,
    exp = o.exp or 1000,
    stats = {
      hp = maxHp, attack = o.atk or 40, defense = o.def or 40,
      speed = o.spd or 40, special = o.spc or 40,
    },
    dvs = { hp = 8, attack = 8, defense = 8, speed = 8, special = 8 },
    statExp = { hp = 0, attack = 0, defense = 0, speed = 0, special = 0 },
    moves = { { id = "THUMP", pp = o.pp or 20 } },
  }
end

-- The engine's state stack, in the three calls this feature makes of it:
-- `push`, `pop`, `top`, plus the `states` array `Coop.stackHolds` walks.
local function newStack()
  local s = { states = {} }
  function s:push(state) self.states[#self.states + 1] = state; return state end
  function s:pop() return table.remove(self.states) end
  function s:top() return self.states[#self.states] end
  return s
end

local function newGame(party)
  local game = {
    data = data,
    save = { party = party, inventory = {}, options = {}, money = 3000,
             playerName = "PLAYER" },
    stack = newStack(),
  }
  game.stack:push({ isOverworld = true })
  return game
end

-- One fight, opened the way src/Client.lua's `screen.pushed` listener opens
-- one: the engine's own battle is already on the stack, and the divert is
-- offered it.
--
-- The event recorder is installed from `pushState`, which is the only moment
-- between the screen being built and `_begin`'s first pump -- so the opening
-- send-outs are in the record rather than drained before anybody was watching.
local function fightOf(kind, o)
  o = o or {}
  local game = newGame(o.party or {
    mon({ species = "ALPHA", spd = o.pSpd or 90, atk = o.pAtk or 40,
          maxHp = o.pHp or 200, level = 20 }),
  })
  for id, count in pairs(o.inventory or {}) do game.save.inventory[id] = count end
  -- `cart2`: a Gold game (the referee-fidelity section at the end of this file
  -- installs what reads it as one) -- the cart's data, and the player's id and
  -- purse where Gold keeps them.
  if o.cart2 then
    game.generation = 2
    game.data = o.data or game.data
    game.save.generation = 2
    game.save.player = { name = "PLAYER", id = 4321, money = o.money or 3000 }
  end

  local state, wildMon
  if kind == "wild" then
    wildMon = o.wildMon or mon({ species = "BETA", spd = o.eSpd or 10,
                                 maxHp = o.eHp or 40, atk = o.eAtk or 20 })
    state = { kind = "wild", enemy = { mon = wildMon }, enemyParty = { wildMon },
              battleType = o.battleType }
  else
    state = {
      kind = "trainer",
      enemyParty = o.foes or { mon({ species = "BETA", spd = 5, maxHp = 400,
                                     atk = 5 }) },
      trainer = o.trainer or { baseMoney = o.baseMoney or 20, classId = "OPP_ALPHA" },
      oppClass = "OPP_ALPHA",
    }
  end
  -- Gen 1 pops the battle itself and *then* calls onFinish; Gold's pop lives
  -- inside the onDone closure. Which of the two a state carries is what
  -- `_ended` branches on -- see section 10.
  --
  -- Three shapes, because the two obvious ones are not the only two a Gold
  -- battle arrives in:
  --
  --   * default          -- Gen 1: onFinish only, and it does not pop.
  --   * `gold`           -- Gold through World:startBattle: onDone pops, and
  --                         src/Client.lua aliases the absent onFinish onto it,
  --                         so both fields name the same popping function.
  --   * `goldNoPop`      -- Gold pushed by anything else: an onDone that does
  --                         *not* pop, which is the shape that stranded a
  --                         finished battle on the stack. Section 10's third
  --                         case is the regression.
  --   * `goldSplit`      -- the same disagreement from the other side: a
  --                         popping onDone that is never called, because a
  --                         different onFinish is what the ritual selects.
  local ending = {}
  local function record(result)
    ending[#ending + 1] = { result = result, top = game.stack:top() }
  end
  if o.goldSplit then
    state.onDone = function(result)
      ending[#ending + 1] = { result = result, via = "onDone" }
      game.stack:pop()
    end
    state.onFinish = function(result)
      ending[#ending + 1] = { result = result, via = "onFinish",
                              top = game.stack:top() }
    end
  elseif o.goldNoPop then
    state.onDone = function(result) record(result) end
    state.onFinish = state.onDone
  elseif o.gold then
    state.onDone = function(result)
      record(result)
      game.stack:pop()
    end
    state.onFinish = state.onDone
  else
    state.onFinish = function(result) record(result) end
  end
  for key, value in pairs(o.mark or {}) do state[key] = value end
  game.stack:push(state)

  local events = {}
  local ui = {
    pushState = function(_, g, screen)
      g.stack:push(screen)
      local inner = screen.onEvent
      screen.onEvent = function(self, event)
        events[#events + 1] = event
        return inner(self, event)
      end
    end,
    say = function(_, _, after) if after then after() end end,
  }

  -- `unseeded`: no seed hook, so `_seed` draws the same love-then-math roll
  -- `_randomByte` does when `random` is absent too -- the game's own shape.
  local solo = Solo.new(ui, {
    enabled = function() return o.enabled ~= false end,
    seed = (not o.unseeded) and function() return o.seed or 4242 end or nil,
    random = o.random,
  })
  local started = (kind == "wild")
    and solo:onWildEncounter(game, state, o.mapId or "MAP")
    or solo:onTrainerBattle(game, state, o.mapId or "MAP")
  return {
    solo = solo, game = game, state = state, wildMon = wildMon,
    sim = solo.sim, fight = solo.fight, events = events, ending = ending,
    started = started and true or false,
    party = game.save.party,
  }
end

-- Does the player's seat owe the referee an answer? The same question
-- src/SoloBattle.lua asks of the *opponent's* seat before it wakes the brain,
-- asked here for the side a suite has to answer for.
local function playerOwes(sim)
  local seat = sim.byId[PLAYER]
  if seat.choice ~= nil then return false end
  if seat.mustReplace then return true end
  return sim.phase == "choice"
end

-- Fight the whole thing with the first move, replacing from the bench when the
-- referee asks. Choices go out through `MediatedBattle:sendChoice` rather than
-- straight into the sim, because the seam under test is the fake transport --
-- a choice that never crossed it would not be the choice the game files.
local function playOut(f, limit)
  local sim, fight = f.sim, f.fight
  for _ = 1, (limit or 300) do
    if sim:outcome() then break end
    if playerOwes(sim) then
      if sim.byId[PLAYER].mustReplace then
        local seat = sim.byId[PLAYER]
        local slot = nil
        for i, m in ipairs(seat.mons) do
          if (tonumber(m.hp) or 0) > 0 and i ~= seat.active then
            slot = tonumber(m.slot) or (i - 1)
            break
          end
        end
        if slot then fight:sendChoice({ action = "switch", slot = slot }) end
      else
        fight:sendChoice({ action = "fight", move = 0 })
      end
    end
    f.solo:update(1 / 60, f.game)
  end
  return sim:outcome()
end

local function kindsOf(events, only)
  local out = {}
  for _, event in ipairs(events) do
    if not only or only[event.t] then out[#out + 1] = event.t end
  end
  return table.concat(out, " ")
end

local function countKind(events, kind)
  local n = 0
  for _, event in ipairs(events) do
    if event.t == kind then n = n + 1 end
  end
  return n
end

local function saidTimes(fight, needle)
  local n = 0
  for _, line in ipairs(fight.lines or {}) do
    if type(line) == "string" and line:find(needle, 1, true) then n = n + 1 end
  end
  return n
end

-- ------------------------------------------------------------------
-- 1. the seating, which is the whole of decision D2
-- ------------------------------------------------------------------
--
-- One fighter per side and the NPC's *whole* bench on that one fighter. The
-- hub's dealer cannot express this shape -- `openMediatedBattle` deals an NPC
-- party round-robin across every co-op seat before it reads the plan's sides,
-- so a three-mon trainer arrives two mons deep -- and skipping the hub is what
-- buys it. A fight that seated four is a fight that lost a monster silently.

;(function()
  local foes = {
    mon({ species = "BETA", level = 11, maxHp = 41, spd = 5 }),
    mon({ species = "BETA", level = 12, maxHp = 42, spd = 5 }),
    mon({ species = "BETA", level = 13, maxHp = 43, spd = 5 }),
  }
  local f = fightOf("trainer", { foes = foes })
  ok(f.started, "a trainer battle is taken over")
  eq(f.sim.mode, Config.SOLO_TRAINER_MODE, "seated in the trainer mode")
  eq(Config.SOLO_TRAINER_MODE, "coop_npc",
     "which is coop_npc -- not wild, or a POKe BALL would keep a gym "
     .. "leader's monster")
  eq(#f.sim.fighters, 2, "exactly two fighters")
  eq(#f.sim:snapshot().field, 2, "and two field slots, not four")

  local foe = f.sim.byId[FOE]
  eq(#foe.mons, 3, "the trainer's whole party is on the one seat")
  local levels = {}
  for i, m in ipairs(foe.mons) do levels[i] = m.level end
  eq(table.concat(levels, ","), "11,12,13",
     "in party order, so the trainer leads with the monster it means to")

  -- The trainer's own kit. This fixture has no items list and no AI class
  -- that would give it one, so the seat is empty -- not DEFAULT_NPC_BAG.
  -- A Youngster that spammed potions was the gym kit being handed to every
  -- NPC; gym leaders still reach for their class item via SoloBrain.bagFor.
  local bag = foe.bag
  eq(bag, nil, "a trainer with no items carries no bag")
end)()

;(function()
  local f = fightOf("trainer", {
    trainer = { baseMoney = 20, classId = "OPP_ALPHA",
                items = { "POTION", "POTION" } },
  })
  eq(f.sim.byId[FOE].bag and f.sim.byId[FOE].bag.POTION, 2,
     "the trainer's own items list is the bag, counted per entry")
end)()

;(function()
  local f = fightOf("wild", {})
  ok(f.started, "a wild encounter is taken over")
  eq(f.sim.mode, Config.SOLO_WILD_MODE, "seated in the wild mode")
  eq(Config.SOLO_WILD_MODE, "wild",
     "which has to contain the word: Effects.isWildMode gates catching and "
     .. "fleeing on mode:find(\"wild\")")
  eq(#f.sim.fighters, 2, "one fighter a side here too")
  eq(#f.sim.byId[FOE].mons, 1, "with the one monster that was met")
end)()

-- ------------------------------------------------------------------
-- 2. a whole trainer fight, faint to replace to a verdict
-- ------------------------------------------------------------------
--
-- The property the spike measured and this pins: a three-mon trainer fought on
-- one seat runs through both replacements to a real outcome, and every event
-- reaches the screen. The brain is deliberately absent here (see the header),
-- so what answers for the trainer is `Turn:autoPick` -- the same picker every
-- hub-refereed NPC seat runs on.

;(function()
  local f = fightOf("trainer", {
    party = { mon({ species = "ALPHA", spd = 90, atk = 120, maxHp = 200,
                    level = 40 }) },
    foes = {
      mon({ species = "BETA", level = 11, maxHp = 40, spd = 5, atk = 5 }),
      mon({ species = "BETA", level = 12, maxHp = 40, spd = 5, atk = 5 }),
      mon({ species = "BETA", level = 13, maxHp = 40, spd = 5, atk = 5 }),
    },
  })
  eq(f.solo.brain, nil,
     "no brain: with no engine reachable SoloBrain declines, which is the "
     .. "fallback contract rather than a failure")

  local out = playOut(f)
  ok(out ~= nil, "the fight reaches an outcome")
  if out then
    eq(out.outcome, "win", "the player won it")
    eq(out.reason, "ko", "by knockout")
  end
  eq(f.fight.result, "win", "and the screen was told so")

  -- The shape of the stream, with everything but the send-outs, the faints and
  -- the ending filtered away: three monsters come out, three fall, and the
  -- replacement always follows the faint that caused it.
  eq(kindsOf(f.events, { send = true, faint = true, over = true }),
     "send send faint send faint send faint over",
     "both openers, then faint/send twice, then the last faint and over")
  eq(countKind(f.events, "over"), 1, "exactly one over")
  eq(f.sim:snapshot().phase, "over", "and the referee settled")
  eq(f.solo.settled, true, "the outcome was handed to the screen once")
end)()

-- ------------------------------------------------------------------
-- 3. a POKe BALL: refused by a trainer, honoured by a wild
-- ------------------------------------------------------------------
--
-- Gen 1 charges for a ball thrown at a trainer's monster -- the ball is gone
-- and the turn is spent (`BattleState:throwBall`'s non-wild arm) -- and
-- `coop_npc` gets that for free, because the referee's refusal costs exactly
-- the same two things. What it does *not* get is the cart's wording; that
-- divergence is written down in Config rather than asserted here.

;(function()
  local f = fightOf("trainer", { inventory = { POKE_BALL = 3 } })
  local sim, fight = f.sim, f.fight
  eq(sim.byId[PLAYER].bag.POKE_BALL, 3, "the balls went up with the party")

  -- Parked the way `MediatedBattle:commitItem` parks it: the debit is only
  -- taken when the referee confirms the use, so the screen has to be holding
  -- the pending item before the choice goes out.
  fight.pendingItem, fight.pendingItemSlot = "POKE_BALL", 1
  local turnBefore = sim.turn
  ok(fight:sendChoice({ action = "item", item = "POKE_BALL" }),
     "the throw is filed")
  f.solo:update(1 / 60, f.game)
  f.solo:update(1 / 60, f.game)

  eq(countKind(f.events, "catch"), 0, "nothing is caught off a trainer")
  eq(saidTimes(fight, "But it failed"), 1, "the throw is refused")
  eq(sim.byId[PLAYER].bag.POKE_BALL, 2, "the ball is spent all the same")
  eq(f.game.save.inventory.POKE_BALL, 2, "and debited from the real bag")
  eq(sim.turn, turnBefore + 1, "and the turn goes with it")
  eq(sim:outcome(), nil, "the fight carries on")
end)()

;(function()
  -- The same throw on the wild path, which is what makes the refusal above a
  -- property of the seating rather than of the ball.
  local caught, tried = 0, 0
  for seed = 1, 12 do
    local f = fightOf("wild", { seed = seed, inventory = { POKE_BALL = 9 },
                                eHp = 40, eAtk = 5 })
    local sim, fight = f.sim, f.fight
    tried = tried + 1
    for _ = 1, 60 do
      if sim:outcome() then break end
      if playerOwes(sim) then
        fight.pendingItem, fight.pendingItemSlot = "POKE_BALL", 1
        fight:sendChoice({ action = "item", item = "POKE_BALL" })
      end
      f.solo:update(1 / 60, f.game)
    end
    local out = sim:outcome()
    if out and out.reason == "catch" then caught = caught + 1 end
  end
  eq(tried, 12, "twelve seeded wild encounters were thrown at")
  ok(caught > 0, "a wild monster can be caught (" .. caught .. "/12 seeds)")
end)()

-- ------------------------------------------------------------------
-- 4. the wild escape roll
-- ------------------------------------------------------------------
--
-- The referee never learns RUN was pressed on the wild path: `_resolveRuns`
-- rolls no dice and ends the fight on the spot, which online is right (fleeing
-- a duel is a concession) and single-player is not -- every wild encounter
-- would become one free press of B. So the roll is made at the boundary, and
-- this is the section that says it is really a roll.
--
-- The speeds are chosen so the odds are interesting rather than a foregone
-- conclusion: 50 against 120 gives `floor(50 * 32 / floor(120 / 4))` = 53 out
-- of 256 on the first attempt, and +30 on every one after it.

local function escapedOnAttempt(seed, attempt)
  local f = fightOf("wild", { seed = seed, pSpd = 50, eSpd = 120,
                              eHp = 9999, eAtk = 5 })
  -- The attempts already refused, which is the only thing that differs between
  -- these four runs: same seed, same fight, same first byte off the referee's
  -- RNG. `_escapes` counts before it rolls and never rolls back, which is
  -- vanilla's order too, so setting the count is setting the odds.
  f.solo.runAttempts = attempt - 1
  f.fight:sendChoice({ action = "run" })
  f.solo:update(1 / 60, f.game)
  local out = f.sim:outcome()
  return out ~= nil and out.reason == "run"
end

;(function()
  local counts = {}
  for attempt = 1, 4 do
    local n = 0
    for seed = 1, 200 do
      if escapedOnAttempt(seed, attempt) then n = n + 1 end
    end
    counts[attempt] = n
  end

  ok(counts[1] > 0 and counts[1] < 200,
     "the first attempt is a roll, not a verdict: " .. counts[1]
     .. "/200 seeds got away")
  -- Strictly rising over an identical seed set is the whole claim, and it is
  -- exact rather than statistical: the same 200 rolls are being compared
  -- against four different thresholds.
  ok(counts[2] > counts[1], "a second attempt escapes more often ("
     .. counts[1] .. " -> " .. counts[2] .. ")")
  ok(counts[3] > counts[2], "a third more often still (" .. counts[3] .. ")")
  ok(counts[4] > counts[3], "and a fourth (" .. counts[4] .. ")")
end)()

;(function()
  -- A refused escape costs the turn, and the enemy's free attack lives in it.
  -- Seed 3 fails its first roll; the assertion below is what makes that a fact
  -- about the code rather than about the seed.
  local f = fightOf("wild", { seed = 3, pSpd = 50, eSpd = 120, eHp = 9999,
                              eAtk = 25 })
  local sim, fight = f.sim, f.fight
  local hpBefore = sim.byId[PLAYER].mons[1].hp
  local turnBefore = sim.turn
  ok(fight:sendChoice({ action = "run" }),
     "a failed escape is handled, not a refused send")
  eq(fight.answeredTurn, true, "so the menu closes for the pump")
  eq(fight.phase, "play", "and the command slab is gone while the line plays")
  f.solo:update(1 / 60, f.game)
  f.solo:update(1 / 60, f.game)

  eq(sim:outcome(), nil, "this attempt did not get away")
  eq(saidTimes(fight, "Can't escape!"), 1, "and said so, once")
  eq(f.solo.runAttempts, 1, "the attempt was counted for the next one's odds")
  eq(sim.turn, turnBefore + 1, "a failed escape spends the turn")
  ok(sim.byId[PLAYER].mons[1].hp < hpBefore,
     "which is where the enemy's free attack lands")
end)()

;(function()
  -- Left alone, the odds climb until the ceiling ends it: nothing is trapped in
  -- a wild encounter forever. Sixty seeds, every one of them out.
  local worst, stuck = 0, 0
  for seed = 1, 60 do
    local f = fightOf("wild", { seed = seed, pSpd = 50, eSpd = 120,
                                eHp = 9999, eAtk = 3 })
    local sim, fight = f.sim, f.fight
    local tries = 0
    for _ = 1, 400 do
      if sim:outcome() then break end
      if playerOwes(sim) then
        tries = tries + 1
        fight:sendChoice({ action = "run" })
      end
      f.solo:update(1 / 60, f.game)
    end
    local out = sim:outcome()
    if not (out and out.reason == "run") then stuck = stuck + 1 end
    if tries > worst then worst = tries end
  end
  eq(stuck, 0, "every seeded encounter is eventually escapable")
  ok(worst > 1, "and some of them took more than one press (" .. worst
     .. " at the worst)")
end)()

-- ------------------------------------------------------------------
-- 5. RUN against a trainer: refused, and said once
-- ------------------------------------------------------------------
--
-- Forwarded, a trainer RUN would forfeit the gym, and a forfeit is a loss, and
-- a loss blacks the player out. Vanilla refuses and does *not* spend the turn.
--
-- The refusal line belongs to the screen -- `MediatedBattle:updateCommand`
-- prints it and does not file the choice -- so the menu never closes and the
-- turn is not spent. A `run` that still arrives (a skipped-menu call site)
-- is parked on `refuseRun` so the pump can reopen the window without a
-- second copy of the sentence.

;(function()
  local f = fightOf("trainer", {})
  local sim, fight = f.sim, f.fight
  local turnBefore = sim.turn

  -- The RUN slab, pressed. Driven through the command menu rather than through
  -- sendChoice, because that is the path that used to print the line too early.
  local input = { wasPressed = function(_, key) return key == "a" end }
  fight.commandIndex = 4
  eq(fight.COMMANDS[4], "RUN", "the fourth command is RUN")
  fight:updateCommand(input)

  eq(saidTimes(fight, "running from"), 1, "the screen refuses, once")
  eq(f.solo.refuseRun, nil, "and nothing is filed with the referee")
  eq(fight.answeredTurn, false, "the menu is not closed as answered")

  f.solo:update(1 / 60, f.game)
  eq(saidTimes(fight, "running from"), 1,
     "the pump adds no second copy of the sentence")
  eq(sim.turn, turnBefore, "the turn is not spent")
  eq(sim:outcome(), nil, "and nothing was forfeited")
  eq(sim.byId[PLAYER].choice, nil, "the seat still owes an answer")
  eq(fight.answeredTurn, false, "and the command is still theirs to give")
  eq(f.solo.refuseRun, nil, "and the parking space stayed empty")
end)()

-- ------------------------------------------------------------------
-- 5b. RUN in a 1v1 is a concession, not a trainer refusal
-- ------------------------------------------------------------------
--
-- MediatedBattle used to print the trainer sentence and then file `run` for
-- every non-wild mode, so a duel read as a gym. 1v1 files the concession and
-- does not lie; coop_npc still says the line and does not file.

;(function()
  local Mediated = need("MediatedBattle")
  eq(Mediated.COMMANDS[4], "RUN", "the fourth command is RUN")

  local function pressRun(mode)
    local sent = {}
    local fight = setmetatable({
      mode = mode,
      phase = "choose",
      commandIndex = 4,
      lines = {},
      answeredTurn = false,
      sendChoice = function(_, choice)
        sent[#sent + 1] = choice
        return true
      end,
    }, { __index = Mediated })
    fight:updateCommand({ wasPressed = function(_, key) return key == "a" end })
    return fight, sent
  end

  local pvp, pvpSent = pressRun("1v1")
  eq(#pvpSent, 1, "1v1 RUN is filed")
  eq(pvpSent[1] and pvpSent[1].action, "run", "...as a concession")
  eq(saidTimes(pvp, "running from"), 0,
     "and does not pretend a 1v1 is a trainer battle")
  eq(saidTimes(pvp, "forfeit"), 1,
     "and says it forfeited after the send landed")

  local npc, npcSent = pressRun("coop_npc")
  eq(#npcSent, 0, "trainer RUN is not filed")
  eq(saidTimes(npc, "running from"), 1,
     "the screen still says there is no running from a trainer battle")
end)()

-- ------------------------------------------------------------------
-- 6. what the divert declines
-- ------------------------------------------------------------------
--
-- Safari, the ghost and the old man in Gen 1; the Bug-Catching Contest, the
-- catching tutorial and the roaming beasts in Gen 2 -- by field name, and by
-- the byte two of them are spelled as instead. A number is truthy whatever it
-- is, which is why the value-keyed set exists at all: a name loop asked about
-- `battleType` would refuse every Gold battle ever fought.

;(function()
  for _, field in ipairs(Config.SOLO_REFUSED) do
    ok(Solo.refused({ kind = "wild", [field] = true }),
       "a battle marked " .. field .. " is declined")
    ok(Solo.refused({ battle = { wild = true, [field] = true } }),
       "and declined one level down, where Gold keeps it")
  end
  eq(#Config.SOLO_REFUSED, 7, "four Gen 1 names and three Gen 2 ones")

  for value in pairs(Config.SOLO_REFUSED_BATTLE_TYPES) do
    ok(Solo.refused({ battle = { wild = true, battleType = value } }),
       "battleType " .. value .. " is declined")
    ok(Solo.refused({ kind = "wild", battleType = value }),
       "and so is the same byte on the outer state")
  end
  local listed = {}
  for value in pairs(Config.SOLO_REFUSED_BATTLE_TYPES) do
    listed[#listed + 1] = value
  end
  table.sort(listed)
  eq(table.concat(listed, ","), "3,5,6,7,9",
     "tutorial, roaming, contest, forceshiny and trap")

  -- The other half, and the one a truthiness bug would break: an ordinary
  -- fight is taken.
  ok(not Solo.refused({ kind = "wild" }), "an ordinary wild is accepted")
  ok(not Solo.refused({ kind = "trainer" }), "an ordinary trainer is accepted")
  ok(not Solo.refused({ battle = { wild = true, battleType = 0 } }),
     "battleType 0 is accepted -- zero is truthy in Lua and a field loop "
     .. "would have refused it")
  ok(not Solo.refused({ battle = { trainer = true, battleType = 1 } }),
     "and so is 1, the Cherrygrove rival, which is deliberately not listed")
  eq(Solo.refused(nil), false, "nothing at all is not a refusal")

  eq(Solo.kindOf({ kind = "wild" }), "wild", "Gen 1 names its kind outright")
  eq(Solo.kindOf({ battle = { trainer = {} } }), "trainer",
     "Gen 2 keeps it on the inner battle")
  eq(Solo.kindOf({ kind = "link" }), nil, "a link battle is not ours")
  eq(Solo.kindOf({ mmoBattle = true }), nil, "and neither is our own screen")
end)()

;(function()
  -- End to end: a refused encounter is left where it was, silently. The
  -- engine's own battle is still the top of the stack and nothing was said.
  local before = #warns
  local f = fightOf("wild", { mark = { safari = true } })
  eq(f.started, false, "a Safari encounter is not taken over")
  eq(f.solo:isRunning(), false, "no fight is left half-open")
  eq(f.game.stack:top(), f.state, "the engine's battle is still on top")
  eq(#warns, before, "and the player was told nothing")
end)()

;(function()
  local before = #warns
  local f = fightOf("wild", { enabled = false })
  eq(f.started, false, "with the row off nothing is diverted")
  eq(f.game.stack:top(), f.state, "the vanilla battle is what runs")
  eq(#warns, before, "silently, again")
end)()

-- ------------------------------------------------------------------
-- 7. the wild seat carries no bag
-- ------------------------------------------------------------------
--
-- Wild is 1xNPC with no items: the player uploads the encounter as side "b"
-- without a bag. A trainer 1xNPC sends the kit from this game's data on that
-- same side. Seeding DEFAULT_NPC_BAG onto wildlife made `Turn._autoChoice`
-- drink potions before it attacked.

;(function()
  local f = fightOf("wild", {})
  eq(f.sim.byId[FOE].bag, nil, "the wild seat has no bag at all")

  -- And the consequence, which is the part a player would have noticed: over a
  -- long seeded fight against a monster that cannot be killed quickly, the
  -- referee never announces an item for the wild side.
  local used, turns = 0, 0
  for seed = 1, 8 do
    local g = fightOf("wild", { seed = seed, pAtk = 5, pHp = 9999,
                                eHp = 9999, eAtk = 5 })
    local foeSlot = 2
    for _ = 1, 240 do
      if g.sim:outcome() then break end
      if playerOwes(g.sim) then
        g.fight:sendChoice({ action = "fight", move = 0 })
      end
      g.solo:update(1 / 60, g.game)
    end
    turns = turns + g.sim.turn
    for _, event in ipairs(g.events) do
      if event.t == "item" and event.slot == foeSlot then used = used + 1 end
    end
  end
  ok(turns >= 100, "the fights ran long enough to matter (" .. turns
     .. " turns over eight seeds)")
  eq(used, 0, "and a wild monster reached for an item in none of them")
end)()

-- ------------------------------------------------------------------
-- 7b. an NPC with nothing to file still spends the turn
-- ------------------------------------------------------------------
--
-- `Turn:_autoChoice` used to return nil when the active mon has no moves.
-- Solo's choice clock is 0 (no deadline), and a trainer fight refuses RUN, so
-- a pick that filed nothing used to leave the band on "Waiting for X..."
-- forever. `_begin` already pumped the NPC once, so wipe the filed choice
-- too: this turn is the hang case. One update after the player files is
-- enough; the empty sheet Struggles.

;(function()
  local f = fightOf("trainer", {
    party = { mon({ species = "ALPHA", spd = 90, atk = 120, maxHp = 200 }) },
    foes = { mon({ species = "BETA", spd = 5, maxHp = 80, atk = 5 }) },
  })
  ok(f.started, "the fight opened")
  f.sim.byId[FOE].mons[1].moves = {}
  f.sim.byId[FOE].choice = nil
  local turnBefore = f.sim.turn
  ok(f.fight:sendChoice({ action = "fight", move = 0 }), "the player answers")
  eq(f.sim.turn, turnBefore, "the NPC has not answered yet")
  f.solo:update(1 / 60, f.game)
  ok(f.sim.turn > turnBefore or f.sim:outcome() ~= nil,
     "one pump after the player files is enough")
end)()

-- ------------------------------------------------------------------
-- 7c. a fainted wild in the choice window does not wait forever
-- ------------------------------------------------------------------
--
-- The screenshot hang: Drowzee's bar empty, Marcel asleep, band on
-- "Waiting for WILD...". The wild is already down, so `_owes` is false
-- for it and autoPick will not file. The player can still press FIGHT;
-- that used to be refused (no living target) while the screen marked
-- the turn answered, and SOLO_CHOICE_TIMEOUT is 0, so the wait never
-- ended. One pump must close the fight.

;(function()
  local f = fightOf("wild", {
    party = { mon({ species = "ALPHA", spd = 90, atk = 40, maxHp = 200 }) },
    wildMon = mon({ species = "BETA", spd = 5, maxHp = 40, atk = 5 }),
  })
  ok(f.started, "the encounter opened")
  local foe = f.sim.byId[FOE]
  foe.mons[1].hp = 0
  foe.active = nil
  f.solo:update(1 / 60, f.game)
  local out = f.sim:outcome()
  ok(out ~= nil, "one pump ends a wild that is already down")
  eq(out and out.reason, "ko", "as a knockout, not a timeout")
  eq(f.fight.phase, "over", "and the screen leaves the wait line")
  eq(f.fight.finished, true, "finish ran, so draw no longer calls holdLine")
  for _ = 1, 30 do f.solo:update(1 / 60, f.game) end
  ok(f.sim:outcome() ~= nil, "later pumps do not reopen the window")
  eq(f.fight.phase, "over", "thirty frames later it is still over")
end)()

;(function()
  local f = fightOf("wild", {
    party = { mon({ species = "ALPHA", spd = 90, atk = 40, maxHp = 200 }) },
    wildMon = mon({ species = "BETA", spd = 5, maxHp = 40, atk = 5 }),
  })
  local player = f.sim.byId[PLAYER]
  player.mons[1].status = "sleep"
  player.mons[1].statusTurns = 3
  local foe = f.sim.byId[FOE]
  foe.mons[1].hp = 0
  foe.active = nil
  -- The player still files, the way an asleep seat does in Gen 1. The
  -- referee must not refuse the fight and leave the band waiting.
  ok(f.fight:sendChoice({ action = "fight", move = 0 }),
     "FIGHT against a downed wild is not a silent refusal")
  f.solo:update(1 / 60, f.game)
  ok(f.sim:outcome() ~= nil, "and the asleep player is not stuck waiting")
  eq(f.fight.phase, "over", "the hold line is gone")
  eq(f.fight.finished, true, "the ending is on the screen, not Waiting for WILD")
end)()

-- Sleep alone is not the hang: an asleep lead still finishes a living wild.
;(function()
  local f = fightOf("wild", {
    party = { mon({ species = "ALPHA", spd = 90, atk = 120, maxHp = 200 }) },
    wildMon = mon({ species = "BETA", spd = 5, maxHp = 20, atk = 5 }),
  })
  f.sim.byId[PLAYER].mons[1].status = "sleep"
  f.sim.byId[PLAYER].mons[1].statusTurns = 2
  local out = playOut(f, 80)
  ok(out ~= nil, "sleep alone does not wedge a wild fight")
end)()

-- The client contract: a transport that returns false must not mark the
-- turn answered. A hub send that returns nil is still a success.
;(function()
  local Mediated = need("MediatedBattle")
  local seen = 0
  eq(Mediated.submitChoice({
    send = function() seen = seen + 1; return false end,
  }, "solo_1", { action = "fight", move = 0 }), false,
     "an explicit false send keeps the turn unspent")
  eq(seen, 1, "the choice still reached the transport")

  eq(Mediated.submitChoice({
    send = function() end,
  }, "solo_1", { action = "fight", move = 0 }), true,
     "a hub send that returns nil is still a success")

  local f = fightOf("wild", {})
  eq(f.fight.answeredTurn, false, "the opening window is unanswered")
  eq(f.fight:sendChoice({ action = "switch", slot = 5 }), false,
     "a switch that names nobody is refused")
  eq(f.fight.answeredTurn, false,
     "and the screen does not pretend the turn was spent")
end)()

-- ------------------------------------------------------------------
-- 8. a referee that keeps throwing gives the fight back
-- ------------------------------------------------------------------
--
-- A throw out of `tick` is contained rather than allowed to take the battle
-- down -- but the failure that is not a bad frame is the deterministic one:
-- the same throw every frame, no outcome, no deadline (SOLO_CHOICE_TIMEOUT is
-- zero) and, in a trainer fight, no RUN. A player standing in front of a
-- battle with no way out of it at all.

;(function()
  local f = fightOf("trainer", {})
  local before = #errors
  f.sim.tick = function() error("boom", 0) end

  local limit = Config.SOLO_FAULT_LIMIT
  eq(limit, 3, "three frames is the limit")
  for frame = 1, limit - 1 do
    f.solo:update(1 / 60, f.game)
    eq(f.solo.faults, frame, "frame " .. frame .. " counted a fault")
    eq(f.solo:isRunning(), true, "and the fight is still ours")
  end

  f.solo:update(1 / 60, f.game)
  eq(f.solo:isRunning(), false, "the third bad frame hands the fight back")
  eq(f.game.stack:top(), f.state,
     "leaving the engine's own battle on top, to be fought the ordinary way")
  ok(#errors > before, "and it is said out loud rather than warned once")

  f.solo:update(1 / 60, f.game)
  eq(f.solo:isRunning(), false, "and nothing restarts it")
end)()

;(function()
  -- One bad frame is a bad frame. The counter is per frame and resets on any
  -- frame that completes cleanly, so an isolated throw never accumulates.
  local f = fightOf("trainer", {})
  local real, calls = f.sim.tick, 0
  f.sim.tick = function(...)
    calls = calls + 1
    if calls == 1 then error("blip", 0) end
    return real(...)
  end

  f.solo:update(1 / 60, f.game)
  eq(f.solo.faults, 1, "the blip is counted")
  eq(f.solo:isRunning(), true, "but survived")
  f.solo:update(1 / 60, f.game)
  eq(f.solo.faults, 0, "and the next clean frame clears the count")
  f.solo:update(1 / 60, f.game)
  eq(f.solo:isRunning(), true, "so the fight goes on")
end)()

-- ------------------------------------------------------------------
-- 9. bringing the party home
-- ------------------------------------------------------------------
--
-- HP, PP and status are the *only* things this file writes to the save: exp, a
-- level, a learned move, a caught monster and every bag item are already
-- written by the screen as the fight runs, and a second copy here would double
-- them.
--
-- HP is carried as a delta, and that is the whole of `_applyMon`. A monster
-- that levelled mid-fight has had the level's max-HP gain added to its current
-- HP by `Experience.apply`, so its `stats.hp` has moved on from the `maxHp` the
-- referee has been fighting against. Writing the referee's number straight
-- across would take that gain back off -- a level-up that heals for nothing.

;(function()
  local f = fightOf("trainer", {
    party = { mon({ species = "ALPHA", spd = 90, atk = 120, maxHp = 200,
                    level = 20, exp = 1000 }) },
    foes = { mon({ species = "BETA", spd = 5, maxHp = 20, atk = 1 }) },
    seed = 7,
  })
  local out = playOut(f)
  eq(out and out.outcome, "win", "the fight was won")

  local sheet = f.sim.byId[PLAYER].mons[1]
  local saved = f.party[1]
  -- The state the ending has to reconcile, stated rather than fought for: the
  -- referee left the monster at 15 of the 30 it was fighting with, and the
  -- screen levelled it into a 32 max while the fight ran.
  sheet.hp, sheet.maxHp = 15, 30
  sheet.status = "sleep"
  sheet.moves[1].pp = 7
  saved.stats.hp = 32
  saved.level = 21
  saved.exp = 4321
  -- And a monster the screen caught and added mid-fight, which the referee
  -- never held a sheet for.
  f.party[2] = mon({ species = "BETA", hp = 3 })

  f.fight:exit()

  eq(saved.hp, 17, "HP comes home as a delta: 15 fought for, plus the 2 the "
     .. "level grew, not the referee's 15")
  eq(saved.status, "SLP", "the condition comes with it, in the engine's token")
  eq(saved.moves[1].pp, 7, "and the PP that was actually spent")
  eq(saved.exp, 4321, "exp is the screen's and is not written a second time")
  eq(saved.level, 21, "nor the level it bought")
  eq(#f.party, 2, "the caught monster is not added again")
  eq(f.party[2].hp, 3, "and is not written over by a sheet that never held it")
  eq(f.game.save.money, 3400,
     "the buried battle's prize was paid: 20 base against a level-20 party")
end)()

;(function()
  -- Zero is not a number that grows. A monster the referee has at nothing is
  -- fainted, whatever its max moved to.
  --
  -- A second, healthy monster is in the party for a reason worth naming: the
  -- ritual that runs after the reconciliation heals a party with nothing left
  -- standing, so a lone fainted monster would come back out of this function
  -- at full HP -- which is `Coop.blacksOut` working, not `_applyMon` failing.
  -- Sections 9's whole point is that the party is reconciled *first*, and this
  -- is the shape of the fixture that lets both facts be true at once.
  local f = fightOf("trainer", {
    party = {
      mon({ species = "ALPHA", spd = 90, atk = 120, maxHp = 200, level = 20 }),
      mon({ species = "BETA", spd = 20, maxHp = 50, level = 20 }),
    },
    foes = { mon({ species = "BETA", spd = 5, maxHp = 20, atk = 1 }) },
    seed = 7,
  })
  playOut(f)
  local sheet = f.sim.byId[PLAYER].mons[1]
  sheet.hp, sheet.maxHp = 0, 30
  f.party[1].stats.hp = 40
  f.fight:exit()
  eq(f.party[1].hp, 0, "a fainted monster stays fainted")
  ok(f.party[2].hp > 0, "and the bench monster was left standing")
end)()

;(function()
  -- The wild monster's own condition goes back onto the engine's copy before
  -- the outcome crosses, because a catch is granted from that copy: a monster
  -- caught at four HP should arrive at four HP.
  local f = fightOf("wild", { seed = 11, eHp = 40, eAtk = 5,
                              party = { mon({ species = "ALPHA", spd = 90,
                                              atk = 120, maxHp = 200,
                                              level = 40 }) } })
  eq(f.wildMon.hp, 40, "the engine's monster starts whole")
  local out = playOut(f)
  eq(out and out.reason, "ko", "the encounter ended in a knockout")
  eq(f.wildMon.hp, 0, "and the referee's copy was written back onto it")
end)()

-- ------------------------------------------------------------------
-- 10. the ending, in the order co-op earned one bug at a time
-- ------------------------------------------------------------------
--
-- The buried battle comes off the stack *before* the forget prompt goes up.
-- `Coop.offerForgets` pushes MoveLearnMenu synchronously, straight above
-- whatever is on top; an unwind that then popped everything above the buried
-- battle destroyed the menu in the same frame it was raised, and every solo
-- level-up that taught a fifth move lost it silently. Co-op never had the bug
-- because co-op unwinds at the *start* of its fight and has nothing left above
-- the battle by prompt time.
--
-- Except that the two steps swap over on Gold, and have to: Gen 1's
-- `BattleState:finish` pops the state and then calls onFinish, so a caller
-- standing in for it pops first; Gold's pop lives *inside* the onDone closure,
-- so the battle is left where it is and the ritual takes it down -- and
-- anything pushed before that would be exactly what the pop took.
-- `engine.onDone` is the test rather than the generation number, because "does
-- the ritual pop for itself" is a property of the callback.

;(function()
  prompts = {}
  local f = fightOf("trainer", {
    party = { mon({ species = "ALPHA", spd = 90, atk = 120, maxHp = 200,
                    level = 40 }) },
    foes = { mon({ species = "BETA", spd = 5, maxHp = 20, atk = 1 }) },
    seed = 7,
  })
  playOut(f)
  -- What a level-up that taught a fifth move hands `onDone`.
  f.fight.toLearn = { { mon = f.party[1], move = "THUMP" } }
  f.fight:exit()

  eq(#prompts, 1, "the forget prompt was offered exactly once")
  eq(prompts[1] and prompts[1].screen, "MoveLearnMenu", "and it is that screen")
  ok(prompts[1] and prompts[1].top and prompts[1].top.isOverworld,
     "raised over the world -- the buried battle was already unwound, so "
     .. "there is nothing left for the unwind to take the menu down with")
  eq(Coop.stackHolds(f.game, f.state), false,
     "the engine's battle really is off the stack by then")
  eq(#f.ending, 1, "and the buried battle was finished off")
  eq(f.ending[1].result, "win", "with the verdict the screen reached")
end)()

;(function()
  -- The same ending on a Gold-shaped state, whose onDone pops for itself.
  prompts = {}
  local f = fightOf("trainer", {
    gold = true,
    party = { mon({ species = "ALPHA", spd = 90, atk = 120, maxHp = 200,
                    level = 40 }) },
    foes = { mon({ species = "BETA", spd = 5, maxHp = 20, atk = 1 }) },
    seed = 7,
  })
  playOut(f)
  f.fight.toLearn = { { mon = f.party[1], move = "THUMP" } }
  f.fight:exit()

  eq(#f.ending, 1, "the ritual ran")
  eq(f.ending[1].top, f.state,
     "with the battle still on the stack, because its own onDone is the pop")
  eq(#prompts, 1, "and the prompt still went up once")
  ok(prompts[1] and prompts[1].top and prompts[1].top.isOverworld,
     "after that pop, over the world -- pushed before it, the menu is what "
     .. "the pop would have taken")
end)()

;(function()
  -- And the shape that stranded a player: a Gold battle whose `onDone` does
  -- *not* pop.
  --
  -- `World:startBattle` builds a closure that pops, and every Gold battle the
  -- overworld itself raises carries it -- but "this state has an onDone" and
  -- "somebody is going to take this battle off the stack" are two different
  -- facts, and `_ended` used to read the first as the second. Anything that
  -- pushes `Gen2BattleState` with a callback of its own -- another mod, a
  -- driver staging an encounter, a future engine path -- produces this state,
  -- and the ending it used to get was: the mod's screen closes, the ritual runs,
  -- the buried battle is told it was won, and it is still sitting there. The
  -- player is standing on a finished battle they cannot leave and which would
  -- be fought again the moment anything above it cleared. Nothing recovered
  -- from it short of a reload.
  --
  -- So the assertion is the outcome, not the branch: whoever was supposed to
  -- pop it, a battle that was handed its result is off the stack -- and the
  -- forget prompt is still raised over the world exactly once, because the
  -- correction has to happen *before* the prompt or it takes the prompt with it.
  prompts = {}
  local f = fightOf("trainer", {
    goldNoPop = true,
    party = { mon({ species = "ALPHA", spd = 90, atk = 120, maxHp = 200,
                    level = 40 }) },
    foes = { mon({ species = "BETA", spd = 5, maxHp = 20, atk = 1 }) },
    seed = 7,
  })
  playOut(f)
  f.fight.toLearn = { { mon = f.party[1], move = "THUMP" } }
  f.fight:exit()

  eq(#f.ending, 1, "the ritual ran on a Gold battle whose onDone never pops")
  eq(f.ending[1].result, "win", "with the verdict the screen reached")
  eq(Coop.stackHolds(f.game, f.state), false,
     "and the battle is off the stack anyway -- nobody popped it, so the "
     .. "ending looked and took it down itself")
  ok(f.game.stack:top() and f.game.stack:top().isOverworld
     or (f.game.stack:top() and f.game.stack:top().moveLearn),
     "leaving the world, not a finished battle, under what is on top")
  eq(#prompts, 1, "the forget prompt still went up exactly once")
  ok(prompts[1] and prompts[1].top and prompts[1].top.isOverworld,
     "over the world -- the correction ran before the prompt, so there was "
     .. "nothing left for it to unwind through")
end)()

;(function()
  -- The same disagreement, read from the other side: `onDone` pops, but
  -- `onDone` is not what runs.
  --
  -- `Coop.finishBuriedBattle` selects `onFinish or onDone`, so a state carrying
  -- both calls the first and the popping closure on the second is never
  -- reached. Reading the pop off `onDone` while the ritual runs `onFinish` is
  -- the drift itself, which is why the selection now lives in one exported
  -- place -- `Coop.buriedFinisher` -- and both sides ask it.
  prompts = {}
  local f = fightOf("trainer", {
    goldSplit = true,
    party = { mon({ species = "ALPHA", spd = 90, atk = 120, maxHp = 200,
                    level = 40 }) },
    foes = { mon({ species = "BETA", spd = 5, maxHp = 20, atk = 1 }) },
    seed = 7,
  })
  playOut(f)
  f.fight.toLearn = { { mon = f.party[1], move = "THUMP" } }
  f.fight:exit()

  eq(#f.ending, 1, "exactly one of the two callbacks ran")
  eq(f.ending[1].via, "onFinish", "the one the ritual selects")
  eq(Coop.stackHolds(f.game, f.state), false,
     "and the battle is off the stack, though the callback that pops it "
     .. "was never the one called")
  eq(#prompts, 1, "the forget prompt went up exactly once")
  ok(prompts[1] and prompts[1].top and prompts[1].top.isOverworld,
     "over the world")
end)()

;(function()
  -- The other half of the same rule: a battle the unwind could *not* reach was
  -- never told how it went, and must be left exactly where it is.
  --
  -- The correction is gated on the battle having been finished off, which is
  -- what separates "nobody popped it" from "we declined to finish it". Sixteen
  -- screens above the buried battle is `unwindStackTo` giving up; `_ended`
  -- declines to pay the prize and mark the trainer beaten, and the ordinary
  -- engine battle is left underneath to be fought for real. A correction that
  -- popped it anyway would delete a battle nobody ever resolved.
  prompts = {}
  local f = fightOf("trainer", {
    goldNoPop = true,
    party = { mon({ species = "ALPHA", spd = 90, atk = 120, maxHp = 200,
                    level = 40 }) },
    foes = { mon({ species = "BETA", spd = 5, maxHp = 20, atk = 1 }) },
    seed = 7,
  })
  playOut(f)
  -- Seventeen states over the buried battle: one more than the unwind's guard.
  for _ = 1, 17 do f.game.stack:push({ pile = true }) end
  f.fight:exit()

  eq(#f.ending, 0, "a battle too deeply buried to reach was never finished")
  eq(Coop.stackHolds(f.game, f.state), true, "and is still on the stack, "
     .. "waiting to be fought as an ordinary battle")
end)()

;(function()
  -- The engine's own vocabulary on the way out, which is what decides whether
  -- the overworld heals the player and takes half their money.
  eq(Solo.engineResult("loss", "run"), "run",
     "fleeing a PIDGEY is not a defeat")
  eq(Solo.engineResult("win", "catch"), "caught",
     "and a catch is not a trainer who was beaten")
  eq(Solo.engineResult("win", "ko"), "win", "everything else passes through")
  eq(Solo.engineResult(nil, nil), "draw", "with a draw for nothing at all")
end)()

-- ------------------------------------------------------------------
-- 11. the second fight of the day: a bar that is out of the real maximum
-- ------------------------------------------------------------------
--
-- A solo fight writes HP back to the save, so the *next* encounter opens with
-- a monster that is already hurt -- and that is the one case the mediated
-- screen used to get wrong. An event on this wire carries current HP, and the
-- screen had no other handle on a seat's maximum, so it took the largest HP it
-- had ever seen there for one: a monster walking out on 42 of 200 drew a full
-- bar with "42/42" printed over it, for the rest of the fight.
--
-- The referee has held the real maximum since it built the battler, and from
-- PROTOCOL 24 states it on the `send`. Asserted here, on a whole fight through
-- the fake transport, because this is where a player meets it -- the wire-level
-- reading is tests/mediated_battle_client.lua's section 15.

;(function()
  local hurt = mon({ species = "ALPHA", spd = 90, atk = 40, maxHp = 200,
                     level = 20 })
  hurt.hp = 42
  local f = fightOf("wild", { party = { hurt } })
  ok(f.started, "a hurt party still opens the fight")

  local sheet = f.fight.mine[1]
  eq(sheet.hp, 42, "the upload describes the monster as it is")
  eq(sheet.maxHp, 200, "...with the maximum beside it")

  local seat = f.fight.slots[f.fight:mySlot()]
  eq(seat.hp, 42, "the screen's own seat holds that HP")
  eq(seat.maxHp, 200, "and is drawn against the real maximum, not against 42")
  eq(("%d/%d"):format(seat.shownHp or seat.hp, seat.maxHp), "42/200",
     "so the plate prints the pair a player can act on")

  -- The foe of a wild fight walks out whole, which is the case the old guess
  -- got right -- it must keep getting it right.
  local foe = f.fight.slots[f.fight:foeSlot()]
  eq(foe.hp, foe.maxHp, "a wild monster is still out of its own whole bar")
end)()

-- ------------------------------------------------------------------
-- the chart's axis by name reaches the solo referee
-- ------------------------------------------------------------------
--
-- Gold's badge type boost (BattleSim2, DoBadgeTypeBoosts) names a move's type
-- through the ruleset's `typeIds` -- MediatedBattle.snapshotRuleset's axis, the
-- registry ids in chart order -- and the solo divert hands its referee
-- whatever the ruleset carries (`turnFor(generation)`, one call site for Gen 1
-- and Gold).  The axis rides Gold's ruleset only: Gen 1's referee has no type
-- boost to read it, so a Gen 1 fight is handed none (Gold's ruleset is held to
-- carrying it in tests/mediated_battle_client.lua; this harness pins
-- package.path empty, so every game here reads as Gen 1).

;(function()
  local real, seen = Turn.create, nil
  Turn.create = function(opts)
    seen = opts
    return real(opts)
  end
  local okFight, f = pcall(fightOf, "wild")
  Turn.create = real
  ok(okFight and f.started, "typeIds solo: the wild fight is taken over")
  ok(seen ~= nil and seen.typeIds == nil,
     "typeIds solo: Gen 1's referee is handed no axis -- it has no type boost")
end)()

-- ------------------------------------------------------------------
-- Gen 3's statics, and that none of them reaches this generation's path
-- ------------------------------------------------------------------
--
-- The Gen 3 fight itself is tests/gen3_solo.lua (it needs the game3 stand-ins
-- and the modal stack). What is pinned here is the vocabulary the Gen 3
-- divert is decided with -- all pure functions -- and that the referee per
-- generation is still the one this file was written against.

;(function()
  eq(Solo.turnFor(1), Turn, "turnFor(1) is still BattleSim")
  eq(Solo.turnFor(3), need("BattleSim3/Turn"), "turnFor(3) is BattleSim3")
  ok(Solo.gen3Refused({ safari = true }), "gen3Refused: a safari opt")
  ok(Solo.gen3Refused({}, { roamer = true }), "gen3Refused: a roamer foe")
  ok(Solo.gen3Refused(nil, nil, { kinds = { tutorial = "wally" } }),
     "gen3Refused: a kinds table on any argument")
  ok(not Solo.gen3Refused({ firstBattle = false, trainerId = 5 }, {}),
     "gen3Refused: firstBattle = false is an ordinary trainer")
  ok(Solo.gen3Double({ double = true }, {}), "gen3Double: the double flag")
  ok(not Solo.gen3Double({}, { doubleBattle = false }), "gen3Double: a single")
  ok(Solo.gen3Double({}, { doubleBattle = true }), "gen3Double: a double trainer row")
  ok(Solo.gen3Double({ trainerIdB = 5 }, {}), "gen3Double: a second trainer is a double of a kind")
  ok(not Solo.gen3Double(nil, nil), "gen3Double: nothing is not")
  -- The wider question above; the take-over decision below it.
  ok(Solo.gen3LoneDouble({ double = true }, {}), "gen3LoneDouble: the double flag")
  ok(Solo.gen3LoneDouble({}, { doubleBattle = true }), "gen3LoneDouble: a double trainer row")
  ok(not Solo.gen3LoneDouble({}, { doubleBattle = false }), "gen3LoneDouble: a single is not")
  ok(not Solo.gen3LoneDouble(nil, nil), "gen3LoneDouble: nothing is not")
  ok(not Solo.gen3LoneDouble({ trainerIdB = 5 }, {}), "gen3LoneDouble: a second trainer is not")
  ok(not Solo.gen3LoneDouble({ double = true, trainerIdB = 5 }, { doubleBattle = true }),
     "gen3LoneDouble: ...whatever else says double")
  local function gen3Mon(species, extra)
    local m = { species = species, hp = 20 }
    for k, v in pairs(extra or {}) do m[k] = v end
    return m
  end
  eq(Solo.gen3UsableMons({ gen3Mon(4), gen3Mon(16) }), 2, "gen3UsableMons: two")
  eq(Solo.gen3UsableMons({ gen3Mon(4), gen3Mon(16, { hp = 0 }) }), 1, "gen3UsableMons: a fainted one is not")
  eq(Solo.gen3UsableMons({ gen3Mon(4), { species = 16 } }), 1, "gen3UsableMons: one with no HP is not")
  eq(Solo.gen3UsableMons({ gen3Mon(4), gen3Mon(16, { isEgg = true }) }), 1, "gen3UsableMons: an egg is not")
  eq(Solo.gen3UsableMons({ gen3Mon(4), gen3Mon(16, { egg = true }) }), 1, "gen3UsableMons: ...either egg flag")
  eq(Solo.gen3UsableMons({ gen3Mon(4), gen3Mon(412) }), 1, "gen3UsableMons: the egg species is not")
  eq(Solo.gen3UsableMons({ gen3Mon(4), gen3Mon(0) }), 1, "gen3UsableMons: no species is not")
  eq(Solo.gen3UsableMons({ gen3Mon(4), { speciesId = 16, hp = 3 } }), 2,
     "gen3UsableMons: a monster known only by its speciesId counts")
  eq(Solo.gen3UsableMons({ gen3Mon(4), "junk", false }), 1, "gen3UsableMons: a non-monster entry is not")
  eq(Solo.gen3UsableMons({}), 0, "gen3UsableMons: an empty party")
  eq(Solo.gen3UsableMons(nil), 0, "gen3UsableMons: no party")
  local two = { gen3Mon(4), gen3Mon(16) }
  ok(Solo.gen3TakesDouble({ double = true }, {}, two), "gen3TakesDouble: a lone double, two usable")
  ok(Solo.gen3TakesDouble({}, { doubleBattle = true }, two), "gen3TakesDouble: ...by the row")
  ok(not Solo.gen3TakesDouble({ double = true }, {}, { gen3Mon(4) }), "gen3TakesDouble: not with one monster")
  ok(not Solo.gen3TakesDouble({ double = true }, {}, { gen3Mon(4), gen3Mon(16, { hp = 0 }) }),
     "gen3TakesDouble: ...nor with one usable and a fainted one")
  ok(not Solo.gen3TakesDouble({ double = true }, {}, nil), "gen3TakesDouble: nor with no party")
  ok(not Solo.gen3TakesDouble({ double = true, trainerIdB = 5 }, {}, two),
     "gen3TakesDouble: not a second trainer's, whatever the party")
  ok(not Solo.gen3TakesDouble({}, {}, two), "gen3TakesDouble: not a single")
  ok(Solo.gen3Refused({ partner = true }, {}), "gen3Refused: Steven's partner stays refused")
  ok(Solo.gen3Refused({ twoOpponents = true }, {}), "gen3Refused: ...and two opponents")
  eq(Solo.gen3Result("win", "catch"), "caught", "gen3Result: a catch")
  eq(Solo.gen3Result("loss", "run"), "run", "gen3Result: the player ran")
  eq(Solo.gen3Result("win", "run"), "fled", "gen3Result: the wild mon left")
  eq(Solo.gen3Result("draw", "ko", true), "lose", "gen3Result: a whiteout draw is a defeat")
  eq(Solo.gen3Kind({ wild = true }), "wild", "gen3Kind: wild")
  eq(Solo.gen3Kind({ trainerId = 7 }), "trainer", "gen3Kind: trainer")
  local s = Solo.new(nil, { enabled = function() return true end })
  eq(s:fromGen3Encounter({ generation = 1, save = {} }, { species = 1, level = 5 }, {}), false,
     "the Gen 3 entries decline on a Gen 1 game")
  eq(s:fromGen3Trainer({ generation = 1, save = {} }, 5, {}), false, "...both of them")
  eq(s:isRunning(), false, "and nothing was started")
end)()

-- ------------------------------------------------------------------
-- A Gen 3 double's pure helpers: the seats, the second monster, the party
-- as a fight found it
-- ------------------------------------------------------------------
--
-- Table-in, table-out: the referee is a stand-in that answers `seatsOf`, the
-- way the real one does for a shared team's two seats.

;(function()
  local function simWith(seats) return { seatsOf = function() return seats end } end

  -- seatIds3: the owner's own id first, then `<id>#2` for a shared team's second seat
  local two = simWith({ { playerId = "me" }, { playerId = "me#2" } })
  eq(table.concat(Solo.seatIds3(two, "me"), ","), "me,me#2", "seatIds3: both seats of a shared team, in slot order")
  eq(table.concat(Solo.seatIds3(simWith({ { playerId = "foe" } }), "foe"), ","), "foe",
     "seatIds3: a one-seat side is its one id")
  eq(table.concat(Solo.seatIds3(simWith({}), "me"), ","), "me", "seatIds3: no seats answered -> the owner's id")
  eq(table.concat(Solo.seatIds3({ seatsOf = function() error("boom") end }, "me"), ","), "me",
     "seatIds3: a referee that throws -> the owner's id")
  eq(table.concat(Solo.seatIds3({}, "me"), ","), "me", "seatIds3: a referee with no seatsOf -> the owner's id")

  -- secondMon3: the monster on (or last on) the second player seat
  local party = { { name = "p1" }, { name = "p2" }, { name = "p3" }, { name = "p4" } }
  local standing = simWith({ { playerId = "me", active = 1, mons = { { slot = 0 } } },
                             { playerId = "me#2", active = 2, mons = { { slot = 0 }, { slot = 3 } } } })
  eq(Solo.secondMon3(standing, party), party[4], "secondMon3: the second seat's active monster, by its party slot")
  local fainted = simWith({ { playerId = "me" }, { playerId = "me#2", lastB = { mon = { slot = 1 } } } })
  eq(Solo.secondMon3(fainted, party), party[2],
     "secondMon3: a seat with nothing standing is the monster that last stood there")
  eq(Solo.secondMon3(simWith({ { playerId = "me" } }), party), nil, "secondMon3: no second seat, no monster")
  eq(Solo.secondMon3(simWith({ { playerId = "me" }, { playerId = "me#2" } }), party), nil,
     "secondMon3: a second seat that never had one has none")
  eq(Solo.secondMon3(standing, nil), nil, "secondMon3: no party")
  eq(Solo.secondMon3(nil, party), nil, "secondMon3: no referee")
  eq(Solo.secondMon3({ seatsOf = function() error("boom") end }, party), nil, "secondMon3: a referee that throws")
  eq(Solo.secondMon3(simWith({ { playerId = "me" }, { playerId = "me#2", active = 1, mons = { { slot = 9 } } } }), party),
     nil, "secondMon3: a slot the party does not hold is no monster")

  -- snapshotParty3 / restoreParty3: everything a fight wrote, put back in place
  local moves, pp = { 1, 2 }, { 5, 6 }
  local m1 = { species = 4, hp = 20, level = 10, shiny = false, moves = moves, pp = pp,
               ivs = { hp = 31 }, deep = { inner = { x = 1 } } }
  local m2 = { species = 16, hp = 30 }
  local m3 = { species = 29, hp = 10 }
  local live = { m1, m2, m3 }
  local snap = Solo.snapshotParty3(live)
  ok(type(snap) == "table", "snapshotParty3: a party is recorded")
  -- what a fight does to the live party
  m1.hp, m1.level, m1.status, m1.shiny, m1.fightKey = 1, 11, "PSN", true, "added"
  moves[1], pp[2] = 99, 0
  m1.ivs.hp = 0
  m1.deep.inner.x = 2
  live[1], live[2] = m2, m1
  live[3] = nil
  live[4] = { species = 5 }
  eq(Solo.restoreParty3(snap), true, "restoreParty3: a record is restored")
  eq(live[1], m1, "restoreParty3: the first member is the same monster table")
  eq(live[2], m2, "restoreParty3: ...the second")
  eq(live[3], m3, "restoreParty3: ...a removed member is back")
  eq(live[4], nil, "restoreParty3: ...a member the fight added is gone")
  eq(#live, 3, "restoreParty3: ...the same size")
  eq(m1.hp, 20, "restoreParty3: HP")
  eq(m1.level, 10, "restoreParty3: level")
  eq(m1.status, nil, "restoreParty3: a status the fight added is off again")
  eq(m1.fightKey, nil, "restoreParty3: a key the fight added is off again")
  eq(m1.shiny, false, "restoreParty3: a false field is restored as false, not dropped")
  eq(m1.moves, moves, "restoreParty3: the moves list is the very table it was")
  eq(moves[1], 1, "restoreParty3: ...with its contents")
  eq(pp[2], 6, "restoreParty3: ...and the PP")
  eq(m1.ivs.hp, 31, "restoreParty3: a nested table is restored in place")
  eq(m1.deep.inner.x, 1, "restoreParty3: ...three levels down")
  -- something with a metatable is a reference to something else: kept, never walked
  local shared = setmetatable({ n = 1 }, { __index = {} })
  m2.ref = shared
  local snap2 = Solo.snapshotParty3(live)
  shared.n = 2
  m2.ref = nil
  Solo.restoreParty3(snap2)
  eq(m2.ref, shared, "restoreParty3: a table with a metatable comes back as the same reference")
  eq(shared.n, 2, "restoreParty3: ...and is not itself rewound")
  -- a monster that holds itself is no loop
  local loop = { species = 4, hp = 5 }
  loop.me = loop
  local snap3 = Solo.snapshotParty3({ loop })
  ok(type(snap3) == "table", "snapshotParty3: a self-referencing monster is recorded, not looped on")
  -- no record
  eq(Solo.snapshotParty3(nil), nil, "snapshotParty3: no party, no record")
  eq(Solo.snapshotParty3("junk"), nil, "snapshotParty3: not a party, no record")
  eq(Solo.restoreParty3(nil), false, "restoreParty3: no record, nothing done")
  eq(Solo.restoreParty3({}), false, "restoreParty3: a record with no party, nothing done")
  -- an empty party is a record too: it empties the list again
  local empty = {}
  local snap4 = Solo.snapshotParty3(empty)
  empty[1] = { species = 4 }
  eq(Solo.restoreParty3(snap4), true, "restoreParty3: an empty party's record restores")
  eq(#empty, 0, "restoreParty3: ...to empty")
end)()

-- ------------------------------------------------------------------
-- Gold solo: the client half of referee fidelity
-- ------------------------------------------------------------------
--
-- docs/plans/gen12-referee-fidelity.md: Gold's cart lineage on side a (K6), the
-- player's traded mons (K1), the wild held item the engine never rolls, a
-- `held` event written home, SMOKE BALL and AMULET COIN.  This harness pins
-- package.path empty, so every game above reads as Gen 1; this section makes
-- a Gold game read as one by standing in for the four engine modules the
-- client asks -- the link handshake's generation (a game's own `generation`,
-- which is what the real one reads first), the launcher's cart, and the Gold
-- item / mail tables in their engine shape -- and takes them away again after.
-- Item rows and species slots are invented for this file.

;(function()
  local stubs = {
    ["src.link.Handshake"] = {
      generation = function(game) return tonumber(type(game) == "table" and game.generation) or 1 end,
    },
    ["src.core.gen2.ItemEffects"] = {
      heldItemFor = function(id, d)
        local def = d and d.items and d.items[id]
        if type(def) ~= "table" or def.heldEffect == nil then return nil end
        return { heldEffect = def.heldEffect, heldParameter = def.heldParameter or 0 }
      end,
    },
    ["src.core.gen2.Mail"] = { isMail = function(id) return id == "FLOWER_MAIL" end },
  }
  local saved = {}
  for name, module in pairs(stubs) do
    saved[name] = package.loaded[name]
    package.loaded[name] = module
  end

  local goldData = setmetatable({
    items = {
      BERRY       = { name = "BERRY", heldEffect = "HELD_BERRY", heldParameter = 5 },
      NUGGET      = { name = "NUGGET", heldEffect = "HELD_NONE", heldParameter = 0 },
      SMOKE_BALL  = { name = "SMOKE BALL", heldEffect = "HELD_ESCAPE", heldParameter = 0 },
      AMULET_COIN = { name = "AMULET COIN", heldEffect = "HELD_AMULET_COIN", heldParameter = 0 },
    },
    pokemon = {
      ALPHA = { name = "ALPHA", types = { "NORM" }, catchRate = 200 },
      BETA  = { name = "BETA", types = { "NORM" }, catchRate = 200, items = { "BERRY", "NUGGET" } },
    },
  }, { __index = data })
  local function goldMon(o, item, otId)
    local m = mon(o)
    m.item, m.otId = item, otId
    return m
  end
  local function bytes(list)
    local i = 0
    return function() i = i + 1; return list[i] end, function() return i end
  end
  local Turn2 = need("BattleSim2/Turn")
  local function spyCreate(fn)
    local real, seen = Turn2.create, nil
    Turn2.create = function(opts) seen = opts; return real(opts) end
    local okRun, result = pcall(fn)
    Turn2.create = real
    return seen, okRun and result or nil, okRun or result
  end

  -- K6: side a's family, Gen.family's word for the running cart.
  local seen, f = spyCreate(function()
    return fightOf("wild", { cart2 = true, data = goldData, random = function() return 0 end })
  end)
  ok(f and f.started, "gold solo: a Gold wild fight is taken over")
  eq(seen and seen.sides.a[1].family, "gs", "K6: side a is Gold / Silver when the launcher names no cart")
  eq(seen and seen.sides.b[1].family, nil, "K6: ...and side b carries none")
  package.loaded["src.core.GameVersion"] = {
    ORDER = { "red", "gold", "crystal" },
    VERSIONS = { red = { generation = 1 }, gold = { generation = 2 }, crystal = { generation = 2 } },
    get = function() return "crystal" end,
    engine = function(v) return v == "crystal" and "crystal" or "gs" end,
  }
  seen = spyCreate(function()
    return fightOf("wild", { cart2 = true, data = goldData, random = function() return 0 end })
  end)
  eq(seen and seen.sides.a[1].family, "crystal", "K6: a Crystal boot says crystal")
  package.loaded["src.core.GameVersion"] = nil
  local realOne, seenOne = Turn.create, nil
  Turn.create = function(opts) seenOne = opts; return realOne(opts) end
  pcall(fightOf, "wild")
  Turn.create = realOne
  eq(seenOne and seenOne.sides.a[1].family, nil, "K6: a Gen 1 fight's side a carries no family")

  -- K1: the player's own traded mon says so; the fight is against the computer.
  f = fightOf("wild", { cart2 = true, data = goldData, random = function() return 0 end,
                        party = { goldMon({ species = "ALPHA", spd = 90, maxHp = 200 }, nil, 77),
                                  goldMon({ species = "ALPHA", maxHp = 200 }, nil, 4321) } })
  eq(f.fight.mine[1].traded, true, "K1 solo: a mon from another OT id is uploaded traded")
  eq(f.fight.mine[2].traded, nil, "K1 solo: the player's own is not")

  -- The wild held item: the cart's two draws, onto the engine monster.
  local random, drawn = bytes({ 250, 99 })
  f = fightOf("wild", { cart2 = true, data = goldData, random = random })
  eq(f.wildMon.item, "BERRY", "wild item: rolled onto the engine monster the catch keeps")
  eq(f.fight.wildParty[1].heldItem, "BERRY", "wild item: the foe's sheet carries it")
  eq(f.fight.wildParty[1].holdEffect, "HELD_BERRY", "wild item: ...with its K2 fields")
  eq(drawn(), 2, "wild item: two draws, off the solo's own byte source")
  random, drawn = bytes({ 191 })
  f = fightOf("wild", { cart2 = true, data = goldData, random = random })
  eq(f.wildMon.item, nil, "wild item: under 192 the monster holds nothing")
  random, drawn = bytes({})
  f = fightOf("wild", { cart2 = true, data = goldData, random = random, battleType = 10 })
  eq(f.wildMon.item, "BERRY", "wild item: a forced-item encounter holds item 1")
  eq(drawn(), 0, "wild item: ...with no draw")
  -- A divert that declines after the roll leaves the engine's monster as it was.
  random = bytes({ 250, 99 })
  f = fightOf("wild", { cart2 = true, data = goldData, random = random, party = {} })
  eq(f.started, false, "wild item: an empty party is not taken over")
  eq(f.wildMon.item, nil, "wild item: ...and the roll is undone -- the engine's battle starts as built")
  -- The fight's seed is not moved by the roll.
  local seedSeen
  seen = spyCreate(function()
    return fightOf("wild", { cart2 = true, data = goldData, random = bytes({ 250, 99 }), seed = 99 })
  end)
  seedSeen = seen and seen.seed
  eq(seedSeen, 99, "wild item: the referee's seed is the solo's, untouched by the roll")
  -- ...and in the game's own shape, with no hook in: `_seed` and `_randomByte`
  -- both draw the one love-then-math generator, so the seed is drawn ahead of
  -- the roll and is the same draw whether the wild species has item slots
  -- (BETA: BERRY / NUGGET, two draws) or none (ALPHA, no draw).
  local function sharedDraws(wild)
    local love_ = rawget(_G, "love")
    local host = (love_ and love_.math and love_.math.random) and love_.math or math
    local real, n = host.random, 0
    host.random = function(lo, hi)
      n = n + 1
      if lo == nil then return 0.5 end
      if hi == nil then lo, hi = 1, lo end
      -- A byte answers 250 (an item, item 1); anything wider says which draw it was.
      local v = (hi - lo == 255) and 250 or (1000 + n)
      return math.max(lo, math.min(hi, lo + v))
    end
    local spied, fight, okRun = spyCreate(function()
      return fightOf("wild", { cart2 = true, data = goldData, unseeded = true,
                               wildMon = mon({ species = wild, spd = 10, maxHp = 40, atk = 20 }) })
    end)
    host.random = real
    ok(okRun == true, "seed (" .. wild .. "): the fight opens with no hook in")
    return spied and spied.seed, fight
  end
  local slotSeed, slotFight = sharedDraws("BETA")
  local bareSeed, bareFight = sharedDraws("ALPHA")
  eq(slotFight and slotFight.wildMon.item, "BERRY", "seed: the slotted species rolls its item off the shared generator")
  eq(bareFight and bareFight.wildMon.item, nil, "seed: ...and the bare one holds none")
  ok(slotSeed ~= nil, "seed: the referee is handed one")
  eq(slotSeed, bareSeed, "seed: the same draw with item slots and without -- the roll never moves it")

  -- The catch keeps what the wild monster holds at the throw.
  f = fightOf("wild", { cart2 = true, data = goldData, random = bytes({ 250, 99 }) })
  f.solo:_feed({ t = "held", slot = 3, side = "b", mon = 0, text = "BERRY", amount = 0 })
  f.fight:grantCatch({ caught = {} })
  eq(f.wildMon.item, nil, "catch: a wild monster that ate its berry is caught holding nothing")
  f = fightOf("wild", { cart2 = true, data = goldData, random = bytes({ 250, 99 }) })
  f.fight:grantCatch({ caught = {} })
  eq(f.wildMon.item, "BERRY", "catch: ...and one that kept it is caught with it")
  -- Its own THIEF of an item nobody here described: the BERRY it was rolled is
  -- gone (THIEF takes only when its user holds nothing), and what it took is a
  -- claim -- caught holding nothing, not the roll handed back.
  f = fightOf("wild", { cart2 = true, data = goldData, random = bytes({ 250, 99 }) })
  f.solo:_feed({ t = "held", slot = 3, side = "b", mon = 0, text = "BERRY", amount = 0 })
  f.solo:_feed({ t = "held", slot = 3, side = "b", mon = 0, text = "MASTER_BALL", amount = 1 })
  f.fight:grantCatch({ caught = {} })
  eq(f.wildMon.item, nil, "catch: a foreign item it took is not caught, and its lost BERRY is not handed back")

  -- `held` written home: a berry eaten, in a wild fight and against a trainer.
  for _, kind in ipairs({ "wild", "trainer" }) do
    f = fightOf(kind, { cart2 = true, data = goldData, random = function() return 0 end,
                        party = { goldMon({ species = "ALPHA", spd = 90, maxHp = 200 }, "BERRY", 4321) } })
    f.solo:_feed({ t = "held", slot = 0, side = "a", mon = 0, text = "BERRY", amount = 0 })
    eq(f.party[1].item, nil, "held solo (" .. kind .. "): the berry eaten is gone from the save")
  end
  -- ...and the whole way round, from the referee itself: a holder already under
  -- half its maximum eats its BERRY in the first turn (HandleHPHealingItem),
  -- the referee says so with a `held`, and the save loses the berry.
  f = fightOf("trainer", { cart2 = true, data = goldData, seed = 7,
                           party = { goldMon({ species = "ALPHA", spd = 90, atk = 1, maxHp = 200, hp = 90 },
                                             "BERRY", 4321) },
                           foes = { mon({ species = "BETA", spd = 5, maxHp = 400, atk = 1 }) } })
  f.fight:sendChoice({ action = "fight", move = 0 })
  for _ = 1, 4 do f.solo:update(1 / 60, f.game) end
  local ate
  for _, event in ipairs(f.events) do
    if event.t == "held" and event.side == "a" and event.text == "BERRY" and event.amount == 0 then ate = event end
  end
  ok(ate ~= nil, "held solo (referee): the Gold referee's own `held` reaches the screen")
  eq(f.party[1].item, nil, "held solo (referee): ...and the berry it ate is gone from the save")
  -- A foe's THIEF on a trainer fight: gone for good ("if the enemy steals your
  -- item, it's gone for good if you don't get it back").
  f = fightOf("trainer", { cart2 = true, data = goldData,
                           party = { goldMon({ species = "ALPHA", spd = 90, maxHp = 200 }, "NUGGET", 4321) } })
  f.solo:_feed({ t = "held", slot = 0, side = "a", mon = 0, text = "NUGGET", amount = 0 })
  f.solo:_feed({ t = "held", slot = 3, side = "b", mon = 0, text = "NUGGET", amount = 1 })
  eq(f.party[1].item, nil, "held solo: a trainer's THIEF takes the item from the save")
  -- The player's THIEF from the wild monster: kept.
  f = fightOf("wild", { cart2 = true, data = goldData, random = bytes({ 250, 99 }) })
  f.solo:_feed({ t = "held", slot = 3, side = "b", mon = 0, text = "BERRY", amount = 0 })
  f.solo:_feed({ t = "held", slot = 0, side = "a", mon = 0, text = "BERRY", amount = 1 })
  eq(f.party[1].item, "BERRY", "held solo: the player's THIEF from a wild monster is kept")

  -- SMOKE BALL: a slow runner holding one gets away, with the cart's line,
  -- no roll and no attempt counted.
  f = fightOf("wild", { cart2 = true, data = goldData, random = function() return 0 end,
                        party = { goldMon({ species = "ALPHA", spd = 1, maxHp = 200 }, "SMOKE_BALL", 4321) },
                        eSpd = 250 })
  f.fight:sendChoice({ action = "run" })
  eq(f.solo.runAttempts, 0, "smoke ball: the attempt is not counted (the cart skips wNumFleeAttempts)")
  for _ = 1, 4 do f.solo:update(1 / 60, f.game) end
  local fledAt, ranAt
  for i, event in ipairs(f.events) do
    if event.t == "msg" and tostring(event.text):find("fled using a", 1, true) then fledAt = fledAt or i end
    if event.t == "run" then ranAt = ranAt or i end
  end
  ok(fledAt ~= nil, "smoke ball: the cart's line is printed")
  eq(fledAt and f.events[fledAt].text, "ALPHA\nfled using a\nSMOKE BALL!",
     "smoke ball: BattleText_UserFledUsingAStringBuffer1, the item's name filled in")
  ok(fledAt and ranAt and fledAt < ranAt, "smoke ball: ...ahead of the escape itself")
  local out = f.sim:outcome()
  eq(out and out.reason, "run", "smoke ball: the fight ends in an escape")
  -- The same runner with the ball gone (a THIEF took it) rolls like anyone.
  f = fightOf("wild", { cart2 = true, data = goldData, random = function() return 0 end,
                        party = { goldMon({ species = "ALPHA", spd = 1, maxHp = 200 }, "SMOKE_BALL", 4321) },
                        eSpd = 250 })
  f.solo:_feed({ t = "held", slot = 0, side = "a", mon = 0, text = "SMOKE_BALL", amount = 0 })
  f.fight:sendChoice({ action = "run" })
  eq(f.solo.runAttempts, 1, "smoke ball: once taken, the run is the ordinary roll")
  eq(f.solo.fledLine, nil, "smoke ball: ...and no line is owed")

  -- AMULET COIN: the lead comes out holding one and the trainer's prize doubles.
  local function trainerWin(item)
    local fight = fightOf("trainer", {
      cart2 = true, data = goldData, money = 3000, seed = 7,
      party = { goldMon({ species = "ALPHA", spd = 90, atk = 120, maxHp = 200, level = 20 }, item, 4321) },
      foes = { mon({ species = "BETA", spd = 5, maxHp = 20, atk = 1 }) },
    })
    local result = playOut(fight)
    fight.fight:exit()
    return fight, result
  end
  local plainWin, plainOut = trainerWin(nil)
  eq(plainOut and plainOut.outcome, "win", "amulet: the Gold trainer fight is won")
  eq(plainWin.game.save.player.money, 3400, "amulet: the prize, 20 base against level 20")
  local coinWin, coinOut = trainerWin("AMULET_COIN")
  eq(coinOut and coinOut.outcome, "win", "amulet: ...won holding the coin")
  eq(coinWin.state.amuletCoin, true, "amulet: the buried battle is told the coin came out")
  eq(coinWin.game.save.player.money, 3800, "amulet: the prize doubled (pokecrystal .DoubleReward)")

  for name in pairs(stubs) do package.loaded[name] = saved[name] end
end)()

-- ------------------------------------------------------------------

io.write(string.format("solo_battle: %d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
