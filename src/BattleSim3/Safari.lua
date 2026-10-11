-- The Safari Zone: Turn.create's `safari` mode (contract C3 of
-- docs/plans/gen3-solo-remaining-fights.md; research §1.2).
--
-- FireRed / LeafGreen (pokefirered/src/battle_main.c:2282, :4334-4429,
-- battle_ai_script_commands.c:1713) and Emerald (pokeemerald/src/battle_main.c:
-- 3113, battle_util.c:52-76 / :541-634, battle_ai_script_commands.c:2029) run
-- one battle type with two menus:
--
--   * the player's battler is zeroed (battle_main.c:2565): side a fields NO
--     battler -- the trainer stands alone (Turn.create's `noBattler`, implied
--     here) -- so there is no send-out, faint, EXP or bag;
--   * the menu is BALL / BAIT / ROCK / RUN (FRLG) or BALL / POKeBLOCK / GO NEAR
--     / RUN (Emerald): the choice `{ action = "safari", throw = ... }` (M.THROWS
--     per family; a throw of the other cart is refused) and `{ action = "run" }`;
--   * the wild monster never chooses a move: its AI script AI_Safari
--     (data/battle_ai_scripts.s:3242 / :3226) rolls `Random() % 100` against the
--     flee rate (Cmd_if_random_safari_flee) and FLEES or WATCHES -- decided when
--     the turn opens, from the counters as they stand then (`_safariDecide`;
--     the referee files it, so it is never asked of an answerer);
--   * the turn runs in battler order (SetActionsAndBattlersTurnOrder's SAFARI
--     arm, pokefirered :3537): the player's action, then the monster's.
--
-- The state (`battle.safari`, M.options + M.seat) is pret's gBattleStruct
-- fields: catchFactor / escapeFactor (0..20), the FRLG rock and bait counters,
-- the Emerald go-near and pokeblock counters, gBattleResults.pokeblockThrows,
-- and gNumSafariBalls.  Emerald's three tables (sGoNearCounterToCatchFactor,
-- sGoNearCounterToEscapeFactor, sPkblToEscapeFactor) are the cart's: the
-- client reads them from the player's cart and hands them to `create`, 1-based
-- lists (pret index i at list[i + 1]); nothing here carries their values.
--
-- RNG (Turn.lua's header is the contract): the flee roll roll(0,99) when the
-- turn opens; then the player's action -- roll(0,4) for BAIT / ROCK, up to four
-- roll(0,65535) for a ball (Catch.attempt), nothing for GO NEAR, a POKeBLOCK
-- or RUN; the monster's flee or watch draws nothing.
--
-- No new event kinds: a ball is `item` (amount = the SAFARI BALLS left) and
-- `ball`; the throws are `anim` BAIT_THROW / ROCK_THROW / POKEBLOCK_THROW (the
-- thrower's slot, target the wild slot); FireRed's reaction is `anim`
-- SAFARI_REACTION on the wild slot with amount 0 watching / 1 angry / 2
-- eating; a flee is the wild seat's ordinary `run`; each line is the cart's.
--
-- Nothing here raises; no love, no engine modules, no mod facade.

local need = ...
local Catch = need("BattleSim3/Catch")

local M = {}

local floor, max, min = math.floor, math.max, math.min

M.FAMILIES = { frlg = true, rse = true }

-- What each cart's menu throws (pokefirered/src/battle_controller_safari.c
-- HandleInputChooseAction: BALL / BAIT / ROCK; pokeemerald :170: BALL /
-- POKeBLOCK / GO NEAR).  RUN is the plain `run` action.
M.THROWS = {
  frlg = { ball = true, bait = true, rock = true },
  rse = { ball = true, near = true, block = true },
}

-- pokeemerald include/constants/battle_string_ids.h:552 B_MSG_MON_CURIOUS /
-- ENTHRALLED / IGNORED: a POKeBLOCK throw's `verdict`, 0..2, the case's own
-- reading of the block against the monster's nature (pokeblock.c:1264: gain 0
-- -> curious, > 0 -> enthralled, < 0 -> ignored), decided by the client.
M.VERDICT_MAX = 2

-- pokefirered include/constants/battle_string_ids.h:555: the SAFARI_REACTION
-- animation's argument and the line it shows.
M.WATCHING, M.ANGRY, M.EATING = 0, 1, 2

M.FACTOR_MAX = 20        -- the catch / escape factor caps (battle_main.c:4408, battle_util.c:597)
M.COUNTER_MAX = 6        -- the bait / rock counters' cap (battle_main.c:4388)
M.GO_NEAR_STEPS = 3      -- go-near counter's last step (battle_util.c:604 `< 3`)
M.PKBL_STEPS = 3         -- pokeblock counter's last step (battle_util.c:571 `< 3`)
M.PKBL_ROWS = 4          -- sPkblToEscapeFactor rows the counter can reach (0..3)
M.EM_ESCAPE_FACTOR = 3   -- pokeemerald/src/battle_main.c:3116 (a code constant)
M.BALLS_MAX = 255        -- gNumSafariBalls is a u8
M.BLOCK_NAME_MAX = 32    -- bytes of a POKeBLOCK's name the referee will print
M.BLOCK_DEFAULT = "POKeBLOCK"

local function int(value, fallback)
  local n = tonumber(value)
  if not n or n ~= n then return fallback end
  return floor(n)
end

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

-- ------------------------------------------------------------------
-- the factors (pure; pinned by the `safari` vectors)
-- ------------------------------------------------------------------

-- pokefirered/src/battle_main.c:2284 (pokeemerald :3115): the species'
-- catch rate in twentieths, floored.
function M.catchFactor(catchRate)
  return floor(clamp(int(catchRate, 0), 0, 255) * 100 / 1275)
end

-- pokefirered/src/battle_main.c:2285: FireRed / LeafGreen's escape factor,
-- the species' safariZoneFleeRate in twentieths, floored, never below 2.
-- (Emerald's is M.EM_ESCAPE_FACTOR whatever the species.)
function M.escapeFactor(fleeRate)
  local f = floor(clamp(int(fleeRate, 0), 0, 255) * 100 / 1275)
  if f <= 1 then f = 2 end
  return f
end

-- pokefirered/src/battle_script_commands.c:9496: a SAFARI BALL's catch rate is
-- the factor scaled back, into a u8 (the factor never passes 20, so 255 at
-- most); the ball's own x1.5 is Catch.BONUS[Catch.SAFARI].
function M.ballCatchRate(factor)
  return floor(int(factor, 0) * 1275 / 100) % 256
end

-- The flee chance in percent, read when the turn opens (Cmd_if_random_safari_
-- flee: `(u8)(Random() % 100) < rate`).  FireRed / LeafGreen
-- (pokefirered/src/battle_ai_script_commands.c:1713): a rock out doubles the
-- escape factor (cap 20), bait out quarters it (floor 1); Emerald
-- (pokeemerald :2029): the escape factor alone -- 0 after the pokeblock glitch,
-- which never flees.
function M.fleeRate(s)
  local esc = int(s.escapeFactor, 0)
  if s.family == "rse" then return esc * 5 end
  local rate
  if int(s.rock, 0) ~= 0 then
    rate = min(M.FACTOR_MAX, esc * 2)
  elseif int(s.bait, 0) ~= 0 then
    rate = floor(esc / 4)
    if rate == 0 then rate = 1 end
  else
    rate = esc
  end
  return rate * 5
end

-- pokefirered/src/battle_main.c:4381 HandleAction_ThrowBait: the bait counter
-- grows by `Random() % 5 + 2` (`roll` is that 0..4 draw), capped at 6, the
-- rock counter is dropped, and the catch factor halves -- 2 or less becomes 3,
-- so bait RAISES a low factor (the cart's floor, kept).  Never undone.
function M.bait(s, roll)
  s.bait = min(M.COUNTER_MAX, int(s.bait, 0) + int(roll, 0) + 2)
  s.rock = 0
  s.catchFactor = floor(int(s.catchFactor, 0) / 2)
  if s.catchFactor <= 2 then s.catchFactor = 3 end
end

-- pokefirered/src/battle_main.c:4397 HandleAction_ThrowRock: the rock counter
-- grows the same way, bait is dropped, and the catch factor doubles (cap 20)
-- until the counter runs out (M.watch).
function M.rock(s, roll)
  s.rock = min(M.COUNTER_MAX, int(s.rock, 0) + int(roll, 0) + 2)
  s.bait = 0
  s.catchFactor = min(M.FACTOR_MAX, int(s.catchFactor, 0) * 2)
end

-- pokefirered/src/battle_main.c:4334 HandleAction_WatchesCarefully: the
-- monster's watching turn spends one rock turn -- the last one puts the
-- species' catch factor back (`baseCatchFactor`) and it watches; else it is
-- angry -- or, with no rock out, one bait turn (eating while any is left).
-- Returns M.WATCHING / M.ANGRY / M.EATING.
function M.watch(s)
  if int(s.rock, 0) ~= 0 then
    s.rock = int(s.rock, 0) - 1
    if s.rock == 0 then
      s.catchFactor = int(s.baseCatchFactor, 0)
      return M.WATCHING
    end
    return M.ANGRY
  end
  if int(s.bait, 0) ~= 0 then
    s.bait = int(s.bait, 0) - 1
    if s.bait == 0 then return M.WATCHING end
    return M.EATING
  end
  return M.WATCHING
end

-- pokeemerald/src/battle_util.c:589 HandleAction_GoNear: the cart's tables at
-- the counter (`goNearCatch` / `goNearEscape`, pret index n at list[n + 1])
-- raise both factors (u8 sums, capped at 20).  The counter stops at 3: the
-- first three steps "crept closer" (true), the fourth and every later one
-- still add the last entries but "can't get any closer" (false).
function M.goNear(s)
  local n = int(s.goNear, 0)
  local addCatch = int(s.goNearCatch and s.goNearCatch[n + 1], 0)
  local addEscape = int(s.goNearEscape and s.goNearEscape[n + 1], 0)
  s.catchFactor = min(M.FACTOR_MAX, (int(s.catchFactor, 0) + addCatch) % 256)
  s.escapeFactor = min(M.FACTOR_MAX, (int(s.escapeFactor, 0) + addEscape) % 256)
  if n < M.GO_NEAR_STEPS then
    s.goNear = n + 1
    return true
  end
  return false
end

-- pokeemerald/src/battle_util.c:561 HandleAction_ThrowPokeblock: one more
-- throw on the battle's count (capped at 255), the pokeblock counter steps to
-- at most 3, and -- while the escape factor is over 1 -- the cart's table at
-- [counter][verdict] (`pkblToEscape`, pret row r at list[r + 1], column v at
-- row[v + 1]) comes off it; a factor below that entry becomes 1, one EQUAL to
-- it becomes 0 -- the vanilla pokeblock glitch (pret's BUGFIX `<=`, not
-- taken), after which the monster never flees until GO NEAR raises it.
function M.block(s, verdict)
  s.pokeblockThrows = min(255, int(s.pokeblockThrows, 0) + 1)
  if int(s.pkblCounter, 0) < M.PKBL_STEPS then s.pkblCounter = int(s.pkblCounter, 0) + 1 end
  local esc = int(s.escapeFactor, 0)
  if esc > 1 then
    local row = s.pkblToEscape and s.pkblToEscape[s.pkblCounter + 1]
    local d = int(row and row[clamp(int(verdict, 0), 0, M.VERDICT_MAX) + 1], 0)
    if esc < d then s.escapeFactor = 1 else s.escapeFactor = esc - d end
  end
end

-- ------------------------------------------------------------------
-- create
-- ------------------------------------------------------------------

-- A list of `n` bytes, or nil when any is missing or not a number.
local function byteList(raw, n)
  if type(raw) ~= "table" then return nil end
  local out = {}
  for i = 1, n do
    local v = int(raw[i], nil)
    if v == nil then return nil end
    out[i] = clamp(v, 0, 255)
  end
  return out
end

-- The `safari` create option before the sides are read:
--   { family = "frlg" | "rse", balls = 0..255,
--     goNearCatch = { 4 bytes }, goNearEscape = { 4 bytes },   (rse)
--     pkblToEscape = { 4+ rows of 3 bytes },                    (rse)
--     catchFactor = 0..20?, escapeFactor = 0..20? }             (overrides)
-- -> state, or nil plus the refusal.  `mode` is the create's.
function M.options(raw, mode)
  if type(raw) ~= "table" then return nil, "safari needs an options table" end
  if mode ~= "wild" then return nil, "safari needs a one-on-one wild fight" end
  local family = raw.family
  if not (type(family) == "string" and M.FAMILIES[family]) then
    return nil, "safari needs a family (frlg or rse)"
  end
  local balls = int(raw.balls, nil)
  if balls == nil then return nil, "safari needs its ball count" end
  local s = {
    family = family, balls = clamp(balls, 0, M.BALLS_MAX),
    catchFactor = 0, baseCatchFactor = 0, escapeFactor = 0,
    rock = 0, bait = 0, goNear = 0, pkblCounter = 0, pokeblockThrows = 0,
  }
  if family == "rse" then
    s.goNearCatch = byteList(raw.goNearCatch, M.GO_NEAR_STEPS + 1)
    s.goNearEscape = byteList(raw.goNearEscape, M.GO_NEAR_STEPS + 1)
    local rows = nil
    if type(raw.pkblToEscape) == "table" then
      rows = {}
      for r = 1, M.PKBL_ROWS do
        rows[r] = byteList(raw.pkblToEscape[r], M.VERDICT_MAX + 1)
        if not rows[r] then rows = nil; break end
      end
    end
    s.pkblToEscape = rows
    if not (s.goNearCatch and s.goNearEscape and s.pkblToEscape) then
      return nil, "safari needs the cart's go-near and pokeblock tables"
    end
  end
  return s
end

-- The factors, once the wild monster is known (pret's battle-start values):
-- the catch factor from its catch rate, the escape factor from its
-- `safariFleeRate` sheet field on FireRed / LeafGreen and M.EM_ESCAPE_FACTOR on
-- Emerald; `catchFactor` / `escapeFactor` in the option override either,
-- 0..20.  -> true, or nil plus the refusal.
function M.seat(s, raw, wildMon)
  local cf = int(raw.catchFactor, nil)
  if cf ~= nil then
    s.catchFactor = clamp(cf, 0, M.FACTOR_MAX)
  else
    s.catchFactor = M.catchFactor(wildMon and wildMon.catchRate)
  end
  s.baseCatchFactor = s.catchFactor
  local ef = int(raw.escapeFactor, nil)
  if ef ~= nil then
    s.escapeFactor = clamp(ef, 0, M.FACTOR_MAX)
  elseif s.family == "rse" then
    s.escapeFactor = M.EM_ESCAPE_FACTOR
  elseif wildMon and wildMon.safariFleeRate ~= nil then
    s.escapeFactor = M.escapeFactor(wildMon.safariFleeRate)
  else
    return nil, "safari needs the wild sheet's safariFleeRate"
  end
  return true
end

-- What `outcome().safari` carries: the balls left (the client writes them back)
-- and Emerald's gBattleResults.pokeblockThrows (the Safari Fan Club's count).
function M.summary(s)
  return { balls = s.balls, pokeblockThrows = s.pokeblockThrows }
end

-- ------------------------------------------------------------------
-- the turn (installed on Turn's Battle)
-- ------------------------------------------------------------------

local Sb = {}

local VERDICT_TEXT = {
  [0] = " is curious about the ", [1] = " is enthralled by the ", [2] = " completely ignored the ",
}
local REACTION_TEXT = { [0] = " is watching carefully!", [1] = " is angry!", [2] = " is eating!" }

-- The wild monster's action for the turn now opening (AI_Safari, from
-- OpponentHandleChooseMove at selection): roll(0,99) under the flee rate is
-- `run` (the flee: Turn.lua `_wildFlee`), anything else the watching turn.
-- Filed like a lock-in -- `chose`, and no `cancel` -- so nobody is asked.
function Sb:_safariDecide()
  local wild = self.bySide.b[1]
  if not wild or wild.choice ~= nil or not (wild.b and wild.b.mon.hp > 0) then return end
  local rate = M.fleeRate(self.safari)
  local choice
  if self:roll(0, 99) < rate then
    choice = { action = "run", flee = true }
  else
    choice = { action = "safari", watch = true }
  end
  wild.forced = true
  wild.choice = choice
  self:_emit("chose", { slot = wild.slot, side = wild.side, text = wild.name })
end

-- The trainer's choice under `safari` (Turn.lua `_normaliseChoice` hands it
-- here): RUN, or one throw of this cart's menu.  A BALL with none left, a
-- throw of the other cart, or a POKeBLOCK with no `verdict` (0..2) is refused.
-- `blockName` (optional, at most M.BLOCK_NAME_MAX bytes) is the block's name
-- for the cart's lines.  The wild seat files nothing: its turn is decided.
function Sb:_safariChoice(fighter, choice)
  local s = self.safari
  if fighter.side ~= "a" then return nil end
  if choice.action == "run" then return { action = "run" } end
  if choice.action ~= "safari" then return nil end
  local throw = choice.throw
  if not (type(throw) == "string" and M.THROWS[s.family][throw]) then return nil end
  if throw == "ball" and s.balls <= 0 then return nil end
  if throw ~= "block" then return { action = "safari", throw = throw } end
  local verdict = int(choice.verdict, nil)
  if verdict == nil or verdict < 0 or verdict > M.VERDICT_MAX then return nil end
  local out = { action = "safari", throw = "block", verdict = verdict }
  local name = choice.blockName
  if type(name) == "string" and name ~= "" and #name <= M.BLOCK_NAME_MAX then out.blockName = name end
  return out
end

-- One Safari turn, in battler order: the trainer's action, then -- unless that
-- ended it -- the monster's.  RUN always gets away (pokefirered/src/battle_
-- main.c:4414 HandleAction_SafariZoneRun: B_OUTCOME_RAN, nothing asked, no
-- roll); a `skip` (a timed-out trainer) throws nothing.
function Sb:_safariTurn()
  local trainer, wild = self.bySide.a[1], self.bySide.b[1]
  local choice = trainer.choice
  if choice and choice.action == "run" then
    trainer.acted = true
    self:say("Got away safely!")
    self:_emit("run", { slot = trainer.slot, side = trainer.side, text = trainer.name })
    self:_finish("win", self:_sidePlayers("b"), self:_sidePlayers("a"), "run", "run", "a")
    return
  end
  if choice and choice.action == "safari" then
    trainer.acted = true
    self:_safariThrow(trainer, wild, choice)
  end
  if self.result then return end
  local wc = wild.choice
  if wc and wild.b and wild.b.mon.hp > 0 then
    wild.acted = true
    if wc.flee then
      self:_wildFlee(wild)
    elseif wc.watch then
      self:_safariWatch(wild)
    end
  end
end

function Sb:_safariThrow(trainer, wild, choice)
  local s = self.safari
  local target = wild.b
  local who, it = trainer.name, self:nameOf(target)
  local throw = choice.throw
  if throw == "ball" then
    -- HandleAction_SafariZoneBallThrow (pokefirered/src/battle_main.c:4371):
    -- the ball leaves the count first; BattleScript_SafariBallThrow's
    -- handleballthrow rolls with the factor's catch rate and the ball's x1.5.
    -- Not a catch attempt in gBattleResults (battle_script_commands.c:9549).
    s.balls = s.balls - 1
    self:_emit("item", { slot = trainer.slot, side = trainer.side, text = tostring(Catch.SAFARI),
                         amount = s.balls })
    self:say(who .. " used SAFARI BALL!")
    local mon = target.mon
    local caught, shakes = Catch.attempt(Catch.SAFARI, {
      mon = { catchRate = M.ballCatchRate(s.catchFactor), hp = mon.hp, maxHp = mon.maxHp,
              status = mon.status },
    }, self.rng, {})
    self:_emit("ball", { slot = trainer.slot, side = trainer.side, target = wild.slot,
                         amount = caught and 4 or shakes, text = tostring(Catch.SAFARI) })
    if caught then
      self:say("Gotcha! " .. it .. " was caught!")
      local finish = self:_finish("win", self:_sidePlayers("a"), self:_sidePlayers("b"), "catch",
        "catch", "a")
      if finish then
        finish.caught = self:_caughtSheet(target, Catch.SAFARI)
        finish.catcher = trainer.owner
      end
      return
    end
    self:say(Catch.SHAKE_TEXT[shakes] or Catch.SHAKE_TEXT[0])
    if s.balls <= 0 then
      -- BattleScript_ShakeBallThrow: the last ball missed -- B_OUTCOME_NO_
      -- SAFARI_BALLS, before the monster acts.
      self:say("ANNOUNCER: You're out of SAFARI BALLS! Game over!")
      self:_finish("win", self:_sidePlayers("b"), self:_sidePlayers("a"), "run", "balls", "a")
    end
    return
  end
  if throw == "bait" then
    M.bait(s, self:roll(0, 4))
    self:say(who .. " threw some BAIT at the " .. it .. "!")
    self:_emit("anim", { slot = trainer.slot, side = trainer.side, target = wild.slot, text = "BAIT_THROW" })
  elseif throw == "rock" then
    M.rock(s, self:roll(0, 4))
    self:say(who .. " threw a ROCK at the " .. it .. "!")
    self:_emit("anim", { slot = trainer.slot, side = trainer.side, target = wild.slot, text = "ROCK_THROW" })
  elseif throw == "near" then
    -- BattleScript_ActionGetNear: a line, no animation.
    if M.goNear(s) then
      self:say(who .. " crept closer to " .. it .. "!")
    else
      self:say(who .. " can't get any closer!")
    end
  elseif throw == "block" then
    -- BattleScript_ActionThrowPokeblock: the throw line, the animation, the
    -- verdict line (gSafariPokeblockResultStringIds).
    M.block(s, choice.verdict)
    self:say(who .. " threw a POKeBLOCK at the " .. it .. "!")
    self:_emit("anim", { slot = trainer.slot, side = trainer.side, target = wild.slot,
                         text = "POKEBLOCK_THROW" })
    self:say(it .. VERDICT_TEXT[choice.verdict] .. (choice.blockName or M.BLOCK_DEFAULT) .. "!")
  end
end

-- The monster's watching turn: FireRed / LeafGreen spend a rock or bait turn
-- and show the reaction (BattleScript_WatchesCarefully: the line, then
-- B_ANIM_SAFARI_REACTION on the monster); Emerald only watches
-- (pokeemerald/src/battle_util.c:541: the line, no counters, no animation).
function Sb:_safariWatch(wild)
  local s = self.safari
  local it = self:nameOf(wild.b)
  if s.family == "rse" then
    self:say(it .. REACTION_TEXT[M.WATCHING])
    return
  end
  local reaction = M.watch(s)
  self:say(it .. REACTION_TEXT[reaction])
  self:_emit("anim", { slot = wild.slot, side = wild.side, text = "SAFARI_REACTION", amount = reaction })
end

function M.install(Battle)
  for k, v in pairs(Sb) do Battle[k] = v end
end

return M
