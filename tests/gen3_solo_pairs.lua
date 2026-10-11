-- Headless Gen 3 solo battles: Emerald's two other doubles, the `pair` and
-- `partner` kinds of src/Solo3/Doubles.lua (contract C2 of
-- docs/plans/gen3-solo-remaining-fights.md; research §1.5, §2.3), through
-- the real src/SoloBattle.lua core, the real BattleSim3 referee, CoopBattle's
-- real solo double screen and src/CoopField.lua's real stand-ins.  The rig is
-- tests/fixtures/gen3_solo_dbl_rig.lua.
--
--   1. the registry: both kinds are found through mod:read at the first fight
--      that asks (SoloBattle.KIND_FILES3), and their hooks are well formed;
--   2. a pair, seated: A's first three on slot 3 with A's bag, B's first three
--      on slot 4 spending A's bag (`bagFrom`), the sides in field order, the
--      screen's `trainerB` / `npcPartyB` the very sheets B's entry holds, two
--      brains on A | B with one item pool -- through the door's stand-in and
--      without one;
--   3. a pair, ended: the win in the cart's order (both defeated, A's lose
--      text, B's, the summed prize A + B with no x2) and engagePair's finish
--      answered "win" (both flags, B then A); the loss (whiteout, no flags);
--      the draw answered "lose", never the trainer-script halt;
--   4. a pair handed back: Emerald only, never inside the Battle Pyramid or
--      Trainer Hill, never without two usable monsters;
--   5. Steven: the player's half on slot 0, his three on slot 1 (`spare`,
--      the player's badges, no obedience fact), MAXIE and TABITHA as a pair
--      with no items, his brain on their flags with no items and no
--      disobedience, the screen's `partner` / `partnerParty`, EXP shared with
--      his monsters as participants, the win and its prize, the loss with his
--      monsters still standing (no mod whiteout, `done("lose")`), the draw
--      word, his party back behind the player's on every ending and hand-back.
--
-- Run from the engine checkout root:
--
--   luajit mods/rby_mmo/tests/gen3_solo_pairs.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local check, eq = T.check, T.eq

local here = (debug.getinfo(1, "S").source:sub(2):match("(.+)[/\\]")) or "."
local R = dofile(here .. "/fixtures/gen3_solo_dbl_rig.lua")(T)

local Solo, Prize = R.Solo, R.Prize
local CoopField = R.CoopField
local TRAINERS, MONEY = R.TRAINERS, R.MONEY
local mon, block = R.mon, R.block
local warns = R.warns

-- ===================================================================
-- the trainers (synthetic rows)
-- ===================================================================

-- A pair: A fields four (only its first three come out), carries a POTION;
-- B fields two and carries a HYPER POTION nobody may use (pret: only A's
-- four items are the fight's pool).
local A, B = 500, 501
TRAINERS[A] = { class = 57, className = "YOUNGSTER", name = "ANDY", pic = 5, gender = 0,
                aiFlags = 1, items = { 13, 0, 0, 0 }, defeat = "ANDY: I lost!",
                party = { { species = 16, level = 5, moves = { 33 } }, { species = 29, level = 5, moves = { 33 } },
                          { species = 16, level = 6, moves = { 33 } }, { species = 29, level = 9, moves = { 33 } } } }
TRAINERS[B] = { class = 59, className = "LASS", name = "BETH", pic = 11, gender = 1,
                aiFlags = 4, items = { 21, 0, 0, 0 }, defeat = "BETH: no way!",
                party = { { species = 4, level = 5, moves = { 33 } }, { species = 16, level = 7, moves = { 33 } } } }
-- Steven's fight: MAXIE and TABITHA, and STEVEN's own row (no party: the
-- engine builds his three itself, natives_frontier_story.lua stevenParty).
local MAXIE, TABITHA, STEVEN = 700, 701, 702
TRAINERS[MAXIE] = { class = 50, className = "MAGMA LEADER", name = "MAXIE", pic = 31, gender = 0,
                    aiFlags = 1, items = { 21, 21, 0, 0 }, defeat = "MAXIE: we failed.",
                    party = { { species = 29, level = 8, moves = { 33 } }, { species = 16, level = 8, moves = { 33 } } } }
TRAINERS[TABITHA] = { class = 51, className = "MAGMA ADMIN", name = "TABITHA", pic = 32, gender = 0,
                      aiFlags = 2, items = { 0, 0, 0, 0 }, defeat = "TABITHA: hmph.",
                      party = { { species = 4, level = 8, moves = { 33 } } } }
TRAINERS[STEVEN] = { class = 52, className = "PKMN TRAINER", name = "STEVEN", pic = 21, gender = 0,
                     aiFlags = 7, items = { 0, 0, 0, 0 }, party = {} }

-- The engine's prize, worked out independently of the code under test:
-- 4 x the row's last level x the class's money value (pret
-- GetTrainerMoneyToGive's TWO_OPPONENTS arm), A's plus B's.
local function prizeOf(id)
  local t = TRAINERS[id]
  return 4 * t.party[#t.party].level * (MONEY[t.class] or 5)
end

-- engagePair's finishBattle, as trainer_sight.lua writes it: anything but a
-- loss sets both flags, B then A; a loss sets none.  What it heard is kept.
local function engagePairDone()
  local rec = { flags = {}, heard = {} }
  function rec.done(result)
    rec.heard[#rec.heard + 1] = result
    rec.party = R.session() and #R.session().party or nil
    if result == "lose" or result == "whiteout" or result == "blackout" then return end
    rec.flags[#rec.flags + 1] = B
    rec.flags[#rec.flags + 1] = A
  end
  return rec
end

-- A pair's start, the way the engine's engagePair hands it to BattleBridge.start.
local function pairOpts(extra)
  local o = { wild = false, trainerId = A, trainerIdB = B, twoOpponents = true, double = true,
              defeatText = "ANDY: I lost!", defeatTextB = "BETH: no way!" }
  for k, v in pairs(extra or {}) do o[k] = v end
  return o
end

-- The door's stand-in for a pair (src/CoopField.lua trainerStand3), as
-- src/Client.lua's divert builds it with SOLO BATTLES listening.
local function pairStand(opts)
  local foe = R.FakeTrainers.foeFromId(A)
  local stand, why = CoopField.trainerStand3(foe, opts, { game = R.game(), solo = true })
  return stand, foe, why
end

local function strongParty(n)
  local out = {}
  local species = { 151, 16, 4, 29 }
  for i = 1, n or 3 do
    out[i] = mon(species[i], 50, { moves = { 300 } })
  end
  return out
end

-- ===================================================================
-- 1. the registry
-- ===================================================================

block("registry", function()
  eq(Solo.KIND_FILES3.pair, "Solo3/Doubles", "registry: a pair's module is Solo3/Doubles")
  eq(Solo.KIND_FILES3.partner, "Solo3/Doubles", "registry: ...and so is the partner's")
  local pair = Solo.kind3("pair")
  check(type(pair) == "table", "registry: the pair kind is found through mod:read")
  check(R.contains(R.reads, "src/Solo3/Doubles.lua"), "registry: ...by reading src/Solo3/Doubles.lua")
  local partner = Solo.kind3("partner")
  check(type(partner) == "table" and partner ~= pair, "registry: the partner kind, a kind of its own")
  local Doubles = R.need("Solo3/Doubles")
  eq(pair, Doubles.Pair, "registry: the pair is Doubles.Pair")
  eq(partner, Doubles.Partner, "registry: the partner is Doubles.Partner")
  for _, kind in ipairs({ pair, partner }) do
    for name, fn in pairs(kind) do
      local known = false
      for _, hook in ipairs(Solo.KIND_HOOKS3) do if hook == name then known = true end end
      check(known and type(fn) == "function", "registry: '" .. tostring(name) .. "' is a hook the core calls")
    end
  end
  for _, hook in ipairs({ "takes", "screen", "seat", "brains", "settle", "word" }) do
    check(type(pair[hook]) == "function", "registry: the pair has " .. hook)
    check(type(partner[hook]) == "function", "registry: the partner has " .. hook)
  end
  check(type(partner.finish) == "function" and type(partner.handBack) == "function",
        "registry: the partner puts Steven's party back (finish, handBack)")
end)

-- ===================================================================
-- 2. a pair, seated
-- ===================================================================

-- What a pair's seating must be, whichever way it arrived.
local function checkPairSeating(tag, solo)
  local sim = solo.sim
  check(sim ~= nil, tag .. ": the referee is running")
  if not sim then return end
  eq(table.concat(Solo.sideIds3(sim, "b"), ","), "solo_foe,solo_foe_b",
     tag .. ": side b is A then B, in field order")
  eq(table.concat(Solo.sideIds3(sim, "a"), ","), "solo_player,solo_player#2",
     tag .. ": side a is the player's two seats")
  local fa, fb = sim.byId.solo_foe, sim.byId.solo_foe_b
  eq(fa.slot, 3, tag .. ": A on slot 3 (battler 1)")
  eq(fb.slot, 4, tag .. ": B on slot 4 (battler 3)")
  eq(#fa.seats, 1, tag .. ": A stands behind one seat")
  eq(#fa.mons, 3, tag .. ": A fields its first three of four")
  eq(fa.mons[3].level, 6, tag .. ": ...the third (not the level-9 fourth)")
  eq(#fb.mons, 2, tag .. ": B fields its own two")
  eq(fb.mons[1].speciesNum, 4, tag .. ": ...B's lead first")
  eq(fb.bag, fa.bag, tag .. ": B spends A's bag (one pool)")
  check(fa.bag and fa.bag[13] == 1, tag .. ": ...which holds A's POTION")
  eq(fa.bag and fa.bag[21], nil, tag .. ": ...and not B's HYPER POTION")
  local create = R.lastCreate()
  local entryB = create and create.sides.b[2]
  eq(entryB and entryB.bagFrom, "solo_foe", tag .. ": B's entry names A's as its bag")
  local so = R.lastScreen()
  check(so and so.trainerB ~= nil, tag .. ": the double screen is told the second trainer")
  eq(so and so.npcPartyB, entryB and entryB.mons, tag .. ": ...and holds the very sheets B's entry holds")
  eq(so and so.trainerB and so.trainerB.trainerName, "BETH", tag .. ": ...B's record")
  eq(so and so.trainerB and so.trainerB.defeatText, "BETH: no way!", tag .. ": ...with B's lose text")
  eq(so and so.peerNameB, "LASS BETH", tag .. ": ...and B's label")
  eq(so and so.trainer and so.trainer.trainerName, "ANDY", tag .. ": A is the screen's trainer")
  eq(#(so and so.npcParty or {}), 3, tag .. ": ...with A's three")
  -- The two brains: one per trainer, each on its own seat, A | B, one pool.
  local npcs = solo.gen3 and solo.gen3.npcs or {}
  local ba, bb = npcs.solo_foe, npcs.solo_foe_b
  check(type(ba) == "table" and type(bb) == "table" and ba ~= bb, tag .. ": a brain per trainer")
  if type(ba) == "table" and type(bb) == "table" then
    eq(ba.family3, "rse", tag .. ": Emerald's scripts (each ORs DOUBLE_BATTLE in at its double)")
    eq(ba.owner, "solo_foe", tag .. ": A's brain answers A's seat")
    eq(bb.owner, "solo_foe_b", tag .. ": B's brain answers B's seat")
    eq(ba.aiFlags, 5, tag .. ": A's brain runs A | B (1 | 4)")
    eq(bb.aiFlags, 5, tag .. ": ...and so does B's")
    eq(ba.pool3, bb.pool3, tag .. ": both spend one item pool")
    eq(ba.pool3.owner, "solo_foe", tag .. ": ...counted in A's bag")
    eq(table.concat(ba.pool3.items, ","), "13", tag .. ": ...A's four slots, ITEM_NONE dropped")
  end
  local parties = solo.gen3 and solo.gen3.parties or {}
  eq(parties.solo_foe_b and #parties.solo_foe_b, 2, tag .. ": B's engine monsters are kept for the dex / TV")
end

block("pair seated through the door", function()
  R.newGame("emerald")
  R.session().party = strongParty(3)
  local opts = pairOpts()
  local stand, foe, why = pairStand(opts)
  check(stand ~= nil, "pair door: the stand-in is built (" .. tostring(why) .. ")")
  eq(stand and stand.kind3, "pair", "pair door: ...and says it is a pair")
  local solo = R.newSolo()
  local rec = engagePairDone()
  local took = solo:fromGen3Trainer(R.game(), foe, R.standOpts(stand, rec.done))
  check(took, "pair door: solo takes the pair (" .. table.concat(warns, " / ") .. ")")
  check(solo.fight and solo.fight.soloDouble, "pair door: on the solo double screen")
  checkPairSeating("pair door", solo)
  eq(stand.enemyParty[1], solo.gen3 and solo.gen3.party[1], "pair door: A's monsters are the stand-in's own")
  solo:reset()
end)

block("pair seated without a stand-in", function()
  R.newGame("emerald")
  R.session().party = strongParty(3)
  local solo = R.newSolo()
  local rec = engagePairDone()
  -- Each trainer's party through the `trainer.party` hook with its own id
  -- (battle_bridge.lua hooked_trainer_party; pret battle_main.c:1977).
  local hooked = {}
  local realHooked = Solo.gen3HookedFoe
  Solo.gen3HookedFoe = function(foe, id)
    hooked[#hooked + 1] = id
    return realHooked(foe, id)
  end
  local took = solo:fromGen3Trainer(R.game(), A, pairOpts({ done = rec.done }))
  Solo.gen3HookedFoe = realHooked
  check(took, "pair bare: the engine's own opts name the pair, and solo takes it")
  eq(table.concat(hooked, ","), A .. "," .. B, "pair bare: A's and B's parties each go through the hook, by id")
  checkPairSeating("pair bare", solo)
  solo:reset()
  local Doubles = R.need("Solo3/Doubles")
  eq(Doubles.inPyramidOrHill({ inPyramid = true }), true, "guard: the Battle Pyramid is a facility's floor")
  eq(Doubles.inPyramidOrHill({ inHill = true }), true, "guard: ...and so is a Trainer Hill challenge")
  eq(Doubles.inPyramidOrHill({}), false, "guard: ...anywhere else is the field")
end)

-- ===================================================================
-- 3. a pair, ended
-- ===================================================================

-- The cart's text pack for the lines the ending reads, in capitals so a cart
-- line can be told from a screen's own spelling.
local function cartTwoTrainers()
  R.TEXT.STRINGID_TWOENEMIESDEFEATED = function(fill)
    return ("%s %s AND %s %s WERE DEFEATED!"):format(tostring(fill.trainer1Class),
      tostring(fill.trainer1Name), tostring(fill.trainer2Class), tostring(fill.trainer2Name))
  end
  R.TEXT.STRINGID_PLAYERGOTMONEY = function(fill)
    return ("%s GOT $%s FOR WINNING!"):format(tostring(fill.playerName), tostring(fill.buff1))
  end
end

block("pair won", function()
  R.newGame("emerald")
  cartTwoTrainers()
  R.session().party = strongParty(3)
  local money = R.session().money
  local stand, foe = pairStand(pairOpts())
  local solo = R.newSolo()
  local rec = engagePairDone()
  check(solo:fromGen3Trainer(R.game(), foe, R.standOpts(stand, rec.done)), "pair won: taken")
  local fight = solo.fight
  local frames = R.playDouble(solo)
  check(solo.fight == nil, "pair won: the fight ended and let go (" .. frames .. " frames)")
  eq(table.concat(rec.heard, ","), "win", "pair won: engagePair's finish heard 'win', once")
  eq(table.concat(rec.flags, ","), B .. "," .. A, "pair won: ...so both flags are set, B then A")
  eq(R.session().battleOutcome, 1, "pair won: B_OUTCOME_WON")
  -- The prize: A's and B's summed, no x2 for the double.
  local want = prizeOf(A) + prizeOf(B)
  eq(solo.gen3, nil, "pair won: the fight's state is let go")
  eq(R.session().money - money, want, "pair won: the prize is A's + B's (" .. want .. "), no x2")
  eq(Prize.rewardRse(A, { double = true, twoOpponents = true, trainerIdB = B }), want,
     "pair won: ...the engine's own Prize.rewardRse agrees")
  check(want ~= 2 * want and Prize.rewardRse(A, { double = true }) == 2 * prizeOf(A),
        "pair won: (a lone double would have paid A's x2 -- the pair does not)")
  -- The after-words, in the cart's order.
  local log = fight.textLog or {}
  local both = R.indexIn(log, "YOUNGSTER ANDY AND LASS BETH WERE DEFEATED!")
  local loseA = R.indexIn(log, "ANDY: I lost!", both)
  local loseB = R.indexIn(log, "BETH: no way!", loseA)
  local paid = R.indexIn(log, "ANN GOT $" .. want .. " FOR WINNING!", loseB)
  check(both ~= nil, "pair won: 'A and B were defeated!' in the cart's words")
  check(loseA ~= nil, "pair won: ...then A's lose text")
  check(loseB ~= nil, "pair won: ...then B's")
  check(paid ~= nil, "pair won: ...then the summed prize line")
  eq(R.countIn(log, "STRINGID_PLAYERDEFEATEDTRAINER1"), 0, "pair won: never the lone trainer's 'defeated' line")
  eq(R.FakeVm.halted, 0, "pair won: no script was halted")
end)

-- Every seat of ours at its first foe, the foes far stronger: the loss.
block("pair lost", function()
  R.newGame("emerald")
  R.session().party = { mon(16, 3, { moves = { 45 } }), mon(29, 3, { moves = { 45 } }) }
  local strong = { { species = 151, level = 60, moves = { 300 } } }
  local savedA, savedB = TRAINERS[A].party, TRAINERS[B].party
  TRAINERS[A].party, TRAINERS[B].party = strong, strong
  local money = R.session().money
  local stand, foe = pairStand(pairOpts())
  local solo = R.newSolo()
  local rec = engagePairDone()
  check(solo:fromGen3Trainer(R.game(), foe, R.standOpts(stand, rec.done)), "pair lost: taken")
  local _, fight = R.playDouble(solo)
  TRAINERS[A].party, TRAINERS[B].party = savedA, savedB
  check(solo.fight == nil, "pair lost: the fight ended")
  eq(table.concat(rec.heard, ","), "lose", "pair lost: engagePair's finish heard 'lose'")
  eq(#rec.flags, 0, "pair lost: ...so no trainer flag is set")
  check(R.contains(R.fieldCalls(), "respawn"), "pair lost: the whiteout's warp")
  check(R.session().money < money, "pair lost: ...and its money")
  local log = fight and fight.textLog or {}
  check(R.contains(log, "STRINGID_PLAYERWHITEOUT|"), "pair lost: the cart's whiteout lines")
  eq(R.FakeVm.halted, 0, "pair lost: no script halted by the core (the whiteout's own warp ends it)")
end)

-- A draw: every monster on the field down at once.  The two trainers' and
-- the player's two each at 1 HP, every move a GROWL, a sandstorm on the map:
-- the end of turn 1 chips all four out (pret B_OUTCOME_DREW).  engagePair's
-- finish must hear "lose" (no flags; the cart whites out on a draw,
-- battle_setup.c:1335) -- never left waiting behind a halted script.
block("pair drawn", function()
  R.newGame("emerald")
  R.FakeWeather.id = 8
  R.session().party = { mon(16, 20, { moves = { 45 }, hp = 1 }), mon(29, 20, { moves = { 45 }, hp = 1 }) }
  local savedA, savedB = TRAINERS[A].party, TRAINERS[B].party
  TRAINERS[A].party = { { species = 16, level = 20, moves = { 45 } } }
  TRAINERS[B].party = { { species = 29, level = 20, moves = { 45 } } }
  local stand, foe = pairStand(pairOpts())
  TRAINERS[A].party, TRAINERS[B].party = savedA, savedB
  for _, m in ipairs(stand.enemyParty) do m.hp = 1 end
  for _, m in ipairs(stand.enemyPartyB) do m.hp = 1 end
  local solo = R.newSolo()
  local rec = engagePairDone()
  check(solo:fromGen3Trainer(R.game(), foe, R.standOpts(stand, rec.done)), "pair drawn: taken")
  local verdict
  local realSettle = solo._settle3
  solo._settle3 = function(self, outcome)
    verdict = outcome
    return realSettle(self, outcome)
  end
  R.playDouble(solo)
  solo._settle3 = nil
  eq(verdict and verdict.winner, nil, "pair drawn: the referee called it a draw (no winner)")
  eq(verdict and verdict.how, "ko", "pair drawn: ...by knockouts")
  eq(table.concat(rec.heard, ","), "lose", "pair drawn: engagePair's finish heard 'lose', not left waiting")
  eq(#rec.flags, 0, "pair drawn: ...so no flag is set")
  eq(R.FakeVm.halted, 0, "pair drawn: the trainer-script halt is not used")
  -- The word, asked directly: a draw the core would have halted is "lose".
  local Doubles = R.need("Solo3/Doubles")
  eq(Doubles.Pair:word({}, {}, { result = "lose", word = "draw", halt = true }), "lose",
     "pair word: a draw the core would halt is answered 'lose'")
  eq(Doubles.Pair:word({}, {}, { result = "win", word = "win" }), "win", "pair word: a win is 'win'")
end)

-- ===================================================================
-- 4. a pair handed back
-- ===================================================================

block("pair handed back", function()
  local cases = {
    { "inside the Battle Pyramid", "emerald", { inPyramid = true }, 3 },
    { "inside Trainer Hill", "emerald", { inHill = true }, 3 },
    { "on FireRed (no two-trainer battles)", "firered", nil, 3 },
    { "with one usable monster", "emerald", nil, 1 },
  }
  for _, case in ipairs(cases) do
    R.newGame(case[2], case[3])
    R.session().party = strongParty(case[4])
    local mark = #warns
    local solo = R.newSolo()
    local took = solo:fromGen3Trainer(R.game(), A, pairOpts({ done = function() end }))
    eq(took, false, "pair back: a pair " .. case[1] .. " is the cart's")
    eq(solo:isRunning(), false, "pair back: ...nothing running (" .. case[1] .. ")")
    eq(R.Stack.depth(), 0, "pair back: ...nothing on the stack (" .. case[1] .. ")")
    eq(#warns, mark, "pair back: ...said nothing, it is the cart's to fight (" .. case[1] .. ")")
  end
  -- A second trainer with no party at all: handed back, and said.
  R.newGame("emerald")
  R.session().party = strongParty(3)
  local mark = #warns
  local solo = R.newSolo()
  eq(solo:fromGen3Trainer(R.game(), A, pairOpts({ trainerIdB = 9999, done = function() end })), false,
     "pair back: a second trainer nobody can build is the cart's")
  check(R.countIn(warns, "two trainers at once could not be set up") == 1,
        "pair back: ...said once, with what to report")
  R.dropWarnsSince(mark)
end)

-- ===================================================================
-- 5. Steven
-- ===================================================================

-- Steven's three, as the engine's stevenParty builds them: his OT, not the
-- player's (so the obedience check would call them traded).
local function stevenThree(level, moves)
  local out = {}
  for i, sp in ipairs({ 5, 151, 4 }) do
    out[i] = mon(sp, level or 40, { moves = moves or { 300 }, otId = 999, otName = "STEVEN",
                                    personality = i - 1 })
  end
  return out
end

-- doStevenBattle's start (natives_frontier_story.lua): his three appended
-- behind the player's, `playerHalf` saying where the player's end.
local function stevenOpts(half, extra)
  local o = { wild = false, trainerId = MAXIE, twoOpponents = true, trainerIdB = TABITHA,
              partner = true, playerHalf = half, partnerTrainerId = STEVEN,
              partnerBackPic = "steven", trainerItems = { 0, 0, 0, 0 }, scriptedLoss = true }
  for k, v in pairs(extra or {}) do o[k] = v end
  return o
end

-- The native's continuation (set_outcome + VAR_RESULT): the word it heard and
-- the party the script would then read.
local function nativeDone()
  local rec = { heard = {} }
  function rec.done(result)
    rec.heard[#rec.heard + 1] = result
    rec.code = R.CODES[result]
    local party = R.session().party
    rec.partyCount = #party
    rec.party = {}
    for i, m in ipairs(party) do rec.party[i] = m end
  end
  return rec
end

-- The Space Center, staged: the session party is the player's `mine` and his
-- three; the door's stand-in lifts his three back out (Stand:detachPartner3).
local function stevenStand(mine, his, extra)
  local party = R.session().party
  for _, m in ipairs(mine) do party[#party + 1] = m end
  for _, m in ipairs(his) do party[#party + 1] = m end
  local engineStarts = {}
  local foe = R.FakeTrainers.foeFromId(MAXIE)
  local stand, why = CoopField.trainerStand3(foe, stevenOpts(#mine, extra), {
    game = R.game(), solo = true,
    fightAlone = function() engineStarts[#engineStarts + 1] = #R.session().party end,
  })
  return stand, foe, engineStarts, why
end

block("Steven seated", function()
  R.newGame("emerald")
  R.STORE.badges = { [1] = true, [3] = true }
  local mine = { mon(16, 30, { moves = { 300 } }), mon(29, 30, { moves = { 300 } }), mon(4, 30, { moves = { 300 } }) }
  local his = stevenThree()
  local stand, foe, _, why = stevenStand(mine, his)
  check(stand ~= nil, "Steven: the stand-in is built (" .. tostring(why) .. ")")
  eq(stand and stand.kind3, "partner", "Steven: ...a partner fight")
  eq(#R.session().party, 3, "Steven: ...his three lifted out of the session party")
  local solo = R.newSolo()
  local rec = nativeDone()
  check(solo:fromGen3Trainer(R.game(), foe, R.standOpts(stand, rec.done)),
        "Steven: solo takes it (" .. table.concat(warns, " / ") .. ")")
  local sim = solo.sim
  eq(table.concat(Solo.sideIds3(sim, "a"), ","), "solo_player,solo_ally", "Steven: side a is the player, then him")
  eq(table.concat(Solo.sideIds3(sim, "b"), ","), "solo_foe,solo_foe_b", "Steven: side b is MAXIE, then TABITHA")
  local me, ally = sim.byId.solo_player, sim.byId.solo_ally
  eq(#me.seats, 1, "Steven: the player commands one seat")
  eq(me.slot, 0, "Steven: ...slot 0 (battler 0)")
  eq(ally.slot, 1, "Steven: he stands on slot 1 (battler 2)")
  eq(ally.spare, true, "Steven: his entry is `spare` (the fight is lost with the player's three)")
  eq(#me.mons, 3, "Steven: the player brings their three")
  eq(#ally.mons, 3, "Steven: he brings his")
  eq(ally.mons[1].speciesNum, 5, "Steven: ...in his order")
  local traded = false
  for _, s in ipairs(ally.mons) do if s.traded then traded = true end end
  check(not traded, "Steven: his monsters carry no obedience fact (never disobey)")
  local create = R.lastCreate()
  local allyEntry = create.sides.a[2]
  eq(allyEntry and table.concat(allyEntry.badges or {}, ","), "1,3",
     "Steven: his entry carries the player's badges (their boosts are every B_SIDE_PLAYER battler's)")
  check(ally.badges and ally.badges[1] and ally.badges[3], "Steven: ...and the referee holds them for him")
  local fa, fb = sim.byId.solo_foe, sim.byId.solo_foe_b
  check(fa.bag == nil or next(fa.bag) == nil, "Steven: MAXIE has no items (INGAME_PARTNER)")
  check(fb.bag == nil or next(fb.bag) == nil, "Steven: ...nor TABITHA")
  eq(#fa.mons, 2, "Steven: MAXIE fields his own")
  eq(#fb.mons, 1, "Steven: TABITHA hers")
  -- The brains.
  local npcs = solo.gen3.npcs
  local bAlly, bA, bB = npcs.solo_ally, npcs.solo_foe, npcs.solo_foe_b
  check(type(bAlly) == "table" and type(bA) == "table" and type(bB) == "table", "Steven: three brains")
  eq(bAlly.owner, "solo_ally", "Steven: his brain answers his seat")
  eq(bAlly.side3, "a", "Steven: ...from side a")
  eq(bAlly.aiFlags, 3, "Steven: ...on the opponents' scripts (MAXIE | TABITHA = 1 | 2)")
  eq(bAlly.noItems, true, "Steven: ...never an item")
  eq(bAlly.noDisobey, true, "Steven: ...never disobeys")
  eq(bA.noItems and bB.noItems, true, "Steven: the foes use no items either")
  eq(bA.aiFlags, 3, "Steven: MAXIE's brain on MAXIE | TABITHA")
  -- The screen.
  local so = R.lastScreen()
  local p = so and so.partner
  check(type(p) == "table", "Steven: the double screen is told its partner")
  eq(p and p.gfxName, "OBJ_EVENT_GFX_STEVEN", "Steven: ...his walker")
  eq(p and p.partnerBackPic, "steven", "Steven: ...his back pic (the profile's key)")
  eq(p and p.name, "STEVEN", "Steven: ...his name")
  eq(so and so.partnerParty, allyEntry and allyEntry.mons, "Steven: ...the very sheets his entry holds")
  eq(so and so.playerHalf, 3, "Steven: ...and where the player's half ends")
  eq(so and so.trainerB and so.trainerB.trainerName, "TABITHA", "Steven: TABITHA is the second trainer")
  local items = so and so.trainer and so.trainer.items or {}
  eq(table.concat(items, ","), "0,0,0,0", "Steven: MAXIE's record carries no items")
  check(solo.fight and solo.fight.partner3 ~= nil, "Steven: the screen seats him")
  solo:reset()
end)

block("Steven won", function()
  R.newGame("emerald")
  R.TEXT.STRINGID_TWOENEMIESDEFEATED = function(fill)
    return ("%s AND %s WERE DEFEATED!"):format(tostring(fill.trainer1Name), tostring(fill.trainer2Name))
  end
  local lead = mon(16, 30, { moves = { 300 } })
  local mine = { lead, mon(29, 30, { moves = { 300 } }) }
  local his = stevenThree()
  local stand, foe = stevenStand(mine, his)
  local money = R.session().money
  local exp0 = lead.exp
  local solo = R.newSolo()
  local rec = nativeDone()
  check(solo:fromGen3Trainer(R.game(), foe, R.standOpts(stand, rec.done)), "Steven won: taken")
  local fight = solo.fight
  local events = {}
  local onEvent = fight.onEvent
  fight.onEvent = function(self, ev)
    events[#events + 1] = ev
    return onEvent(self, ev)
  end
  R.playDouble(solo)
  check(solo.fight == nil, "Steven won: the fight ended")
  eq(table.concat(rec.heard, ","), "win", "Steven won: the native hears 'win' (VAR_RESULT 1)")
  eq(rec.code, 1, "Steven won: ...B_OUTCOME_WON")
  eq(rec.partyCount, 5, "Steven won: his three are back behind the player's before the script reads the party")
  eq(rec.party[3], his[1], "Steven won: ...his own monster tables, in his order")
  eq(rec.party[5], his[3], "Steven won: ...all three")
  eq(R.session().money - money, prizeOf(MAXIE) + prizeOf(TABITHA),
     "Steven won: MAXIE's and TABITHA's prize, summed")
  local log = fight.textLog or {}
  local both = R.indexIn(log, "MAXIE AND TABITHA WERE DEFEATED!")
  check(both ~= nil, "Steven won: both foes defeated, in the cart's words")
  check(R.indexIn(log, "MAXIE: we failed.", both) ~= nil, "Steven won: ...MAXIE's lose text")
  check(R.indexIn(log, "TABITHA: hmph.", both) ~= nil, "Steven won: ...TABITHA's")
  check(lead.exp > exp0, "Steven won: the player's lead earned EXP")
  local shared, his2 = false, false
  for _, ev in ipairs(events) do
    if ev.t == "exp" and (tonumber(ev.participants) or 0) >= 2 then shared = true end
    if ev.t == "exp" and ev.slot == 1 then his2 = true end
  end
  check(shared, "Steven won: a knockout's EXP is shared with his monster as a participant")
  check(his2, "Steven won: ...his monster is paid a share of its own")
  eq(R.FakeVm.halted, 0, "Steven won: no script halted")
end)

block("Steven lost", function()
  R.newGame("emerald")
  R.FakeWeather.id = 8
  -- The player's one monster at 1 HP: the sandstorm takes it at the end of
  -- turn 1 while Steven's three stand.
  local mine = { mon(16, 30, { moves = { 45 }, hp = 1 }) }
  local his = stevenThree(40, { 45 })
  local stand, foe = stevenStand(mine, his)
  local money = R.session().money
  local solo = R.newSolo()
  local rec = nativeDone()
  check(solo:fromGen3Trainer(R.game(), foe, R.standOpts(stand, rec.done)), "Steven lost: taken")
  local sim = solo.sim
  local _, fight = R.playDouble(solo)
  check(solo.fight == nil, "Steven lost: the fight ended")
  local standing = false
  for _, s in ipairs(sim.byId.solo_ally.mons) do if s.hp > 0 then standing = true end end
  check(standing, "Steven lost: his monsters were still standing")
  eq(table.concat(rec.heard, ","), "lose", "Steven lost: ...and still the fight is lost (VAR_RESULT 2)")
  check(not R.contains(R.fieldCalls(), "respawn"), "Steven lost: no mod whiteout (the script whites out itself)")
  eq(R.session().money, money, "Steven lost: no money taken")
  local log = fight and fight.textLog or {}
  check(R.contains(log, "STRINGID_PLAYERWHITEOUT|"), "Steven lost: the cart still prints its whiteout lines")
  eq(rec.partyCount, 4, "Steven lost: his three are back behind the player's one")
  eq(R.FakeVm.halted, 0, "Steven lost: no script halted (the caller is waiting for its word)")
  -- The draw is the cart's B_OUTCOME_DREW, never halted: VAR_RESULT 3.
  local Doubles = R.need("Solo3/Doubles")
  eq(Doubles.Partner:word({}, {}, { result = "lose", word = "draw", halt = true }), "draw",
     "Steven word: a draw is 'draw' (VAR_RESULT 3)")
  eq(Doubles.Partner:word({}, {}, { result = "lose", word = "lose" }), "lose", "Steven word: a loss 'lose'")
  eq(Doubles.Partner:word({}, {}, { result = "win", word = "win" }), "win", "Steven word: a win 'win'")
end)

block("Steven handed back", function()
  R.newGame("emerald")
  local mine = { mon(16, 30, { moves = { 300 } }), mon(29, 30, { moves = { 300 } }) }
  local his = stevenThree()
  local stand, foe, engineStarts = stevenStand(mine, his)
  local solo = R.newSolo()
  local rec = nativeDone()
  check(solo:fromGen3Trainer(R.game(), foe, R.standOpts(stand, rec.done)), "Steven back: taken")
  eq(#R.session().party, 2, "Steven back: the player's two while the mod fights")
  solo:reset()
  eq(#engineStarts, 1, "Steven back: the cart's own battle is started")
  eq(engineStarts[1], 5, "Steven back: ...over the party the engine left (his three behind the player's)")
  eq(R.session().party[3], his[1], "Steven back: ...his own monsters, in place")
  eq(#rec.heard, 0, "Steven back: the native is not answered by the mod (the cart's battle will)")
  -- The hook alone, twice: idempotent.
  local Doubles = R.need("Solo3/Doubles")
  eq(Doubles.Partner:handBack({ stand = stand }), false, "Steven back: handBack lets the core start the cart's")
  eq(#R.session().party, 5, "Steven back: ...and puts nothing back twice")
end)

block("Steven handed back off Emerald / without a party", function()
  R.newGame("firered")
  local mine = { mon(16, 30, { moves = { 300 } }) }
  local his = stevenThree()
  local stand, foe = stevenStand(mine, his)
  local solo = R.newSolo()
  eq(solo:fromGen3Trainer(R.game(), foe, R.standOpts(stand, function() end)), false,
     "Steven back: no partner battle off Emerald")
  R.newGame("emerald")
  local bare = R.newSolo()
  eq(bare:fromGen3Trainer(R.game(), MAXIE, stevenOpts(3, { done = function() end })), false,
     "Steven back: a partner fight with no partner monsters anywhere is the cart's")
end)

eq(#warns, 0, "nothing warned that a scenario did not ask for: " .. table.concat(warns, " / "))

T.finish("gen3_solo_pairs")
