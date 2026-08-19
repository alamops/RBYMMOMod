-- Driver: four guests, two parties, one 2-on-2 between them.
--
-- Four instances of *this same file* under MMO_ROLE=a|b|c|d, launched by
-- tests/drivers/run-quad-e2e.sh, which starts server/bin/rby-mmo-hub.js and
-- points all four at it.
--
-- **This is the row every other test was missing.** run-hub-e2e.sh runs two
-- clients and fights an NPC: two humans on one side, two monsters belonging to
-- nobody on the other. Party-versus-party is a different shape in every place
-- it matters -- four humans have to agree before it starts, four parties have
-- to reach the host, four saves take damage, and the ranking has to decide who
-- beat whom out of a battle with two winners and two losers. All of that
-- existed only in headless tests, where the four "clients" are four tables in
-- one process sharing one clock, one Lua state and one copy of the data.
--
-- Every real fault this feature has had was invisible until two real clients
-- ran: a party that arrived packed and was read as monsters, a trainer record
-- only one side held, a screen that drew nothing behind a pcall. A four-client
-- path that no real client had ever walked is where the next one lives.
--
-- The roles are two pairs, and the asymmetry inside each pair is the point:
--
--   a  ALPHA   CHARIZARD  asks for the PARTY BATTLE
--   b  BETA    PIKACHU    a's partner -- answers the ask
--   c  GAMMA   BLASTOISE  the one asked -- answers, and is on the other side
--   d  DELTA   VENUSAUR   c's partner -- says NO the first time, YES the second
--
-- d refusing first is not padding. "All four have to agree" is a claim with
-- two halves, and the half that is easy to get wrong is the refusal: a no that
-- leaves an ask stuck on the other three clients is a feature that works
-- perfectly in every test and deadlocks the first time somebody declines.
--
--   MMO_ROLE=a POKEPORT_IDENTITY=mmoquad-a \
--     POKEPORT_DRIVER=mods/rby_mmo/tests/drivers/mmo_quad.lua love .

if os.getenv("MMO_SOUND") ~= "1" and love and love.audio then
  love.audio.setVolume(0)
end

-- Who this instance is, and who it is paired with. Read as data below so the
-- four halves of a run cannot disagree about which of them does what.
-- Eight different POKeMON, one per slot and one per bench.
--
-- Not decoration. When each player's second monster was their partner's first,
-- a bench monster coming out after a faint looked exactly like the monster that
-- had just died coming back -- a report that cost a real investigation. With
-- eight distinct species, a species appearing twice is a fact rather than a
-- coincidence, and the watcher below can say so.
local ROLES = {
  a = { name = "ALPHA", species = "CHARIZARD", bench = "LAPRAS",
        level = 50, mate = "b", side = 1 },
  b = { name = "BETA",  species = "PIKACHU",   bench = "SNORLAX",
        level = 45, mate = "a", side = 1 },
  -- GAMMA fights with one, alone, on purpose: when it falls their partner is
  -- still standing, so the side is not beaten and GAMMA spends the rest of the
  -- battle as a spectator. That is the one state four players mashing buttons
  -- will not reliably produce by themselves, and it is the state where the
  -- client used to keep offering a command menu that answered nothing.
  c = { name = "GAMMA", species = "BLASTOISE", bench = nil, alone = true,
        level = 50, mate = "d", side = 2 },
  -- DELTA leads with something that will certainly fall, and benches
  -- something that will certainly not.
  --
  -- A level-5 lead against two fifties faints on the first exchange; the bench
  -- keeps the battle going afterwards. The stall leg itself no longer waits on
  -- a replacement prompt -- a refereed fight auto-sends the next living
  -- monster -- so DELTA instead sits out the *turn* choice (see STALL below).
  d = { name = "DELTA", species = "VENUSAUR",  bench = "DRAGONITE",
        level = 5, benchLevel = 40, mate = "c", side = 2 },
}
local ORDER = { "a", "b", "c", "d" }

local ROLE = tostring(os.getenv("MMO_ROLE") or "a"):lower()
if not ROLES[ROLE] then ROLE = "a" end

-- Play mode: the run drives everything up to the 2-on-2 being on screen, and
-- then ONE window is handed to a human while the other three keep playing
-- themselves. A battle needs every living slot to file an action, so a lone
-- hands-off window with three idle ones would stall until the timeout
-- forfeited somebody -- the bots are what make the human's battle a battle.
local PLAY_ROLE = tostring(os.getenv("MMO_PLAY_ROLE") or ""):lower()
local PLAY = PLAY_ROLE ~= ""
local MINE_TO_PLAY = PLAY and ROLE == PLAY_ROLE

return function(game)
  local H = dofile("mods/rby_mmo/tests/drivers/mmo_util.lua")
  local U = H.U
  local TAG = "MMO_QUAD_" .. ROLE:upper() .. ":"
  local ME = ROLES[ROLE]
  local MATE = ROLES[ME.mate]
  local SHOT_DIR = os.getenv("SHOT_DIR") or "/tmp/rby_mmo_quad_shots"
  local RAW_CODE = os.getenv("MMO_HUB_CODE") or ""

  local function log(...) U.log(TAG, ...) end
  local events = H.captureEvents({ "battle.started", "battle.ended",
                                   "link.desync" })
  local failures = 0
  local function check(ok, what)
    if ok then
      log("ok " .. what)
    else
      failures = failures + 1
      log("FAIL " .. what)
    end
    return ok
  end
  local function shot(name)
    U.shot(game, ("%s/quad-%s-%s.png"):format(SHOT_DIR, ROLE, name))
  end

  -- ------- meeting the other three
  --
  -- Four symmetric drivers, so a barrier is not a pair but a set: signal mine,
  -- then wait for all three of theirs. A rendezvous that waited on only one
  -- would let two instances run a leg ahead of the other two, which is exactly
  -- the state a four-way agreement must never be tested in.
  local function marker(side, tag) return ("quad_%s_%s"):format(side, tag) end

  local function rendezvous(tag)
    H.signal(marker(ROLE, tag))
    local ok = true
    for _, side in ipairs(ORDER) do
      if side ~= ROLE then
        if not H.await(game, marker(side, tag)) then ok = false end
      end
    end
    return ok
  end

  -- Give up in a way that lets the other three give up too.
  --
  -- With two instances a driver that dies quietly costs one partner a
  -- timeout. With four it costs three, sequentially, and what gets reported is
  -- a wall of timeouts on the three healthy instances with the one real
  -- failure buried somewhere above them. Dropping every marker this side owns
  -- lets the others walk their remaining assertions and fail honestly.
  local TAGS = { "ready", "seen", "paired", "refused", "agreed", "fought",
                 "ranked", "left" }
  local function abandon()
    for _, tag in ipairs(TAGS) do H.signal(marker(ROLE, tag)) end
  end

  local function bail(what)
    check(false, what)
    abandon()
    log(("RESULT %d failure(s)"):format(failures))
    log("DONE")
    U.wait(30)
    love.event.quit()
  end

  -- ------- a fresh game, four different trainers

  if not H.newGame(game, TAG) then
    log("RESULT 1 failure(s)")
    return
  end
  -- H.newGame mashes A through the naming grid, so all four would otherwise
  -- be called AAAAAAA -- and with four of them on one roster, indistinguishable
  -- in a way two never quite are. Name them here instead.
  if game.save and game.save.player then
    game.save.player.name = ME.name
  end

  -- Subscribed before anything happens, on the mod bus rather than the
  -- engine's -- see mmo_util's listenForModEvents for why they are two.
  local announced = H.listenForModEvents(game, {
    "mod.rby_mmo.coop_battle_started", "mod.rby_mmo.coop_battle_ended",
  })

  local exports = H.requireMod(game, TAG)
  if not exports then
    abandon()
    log("RESULT 1 failure(s)")
    log("DONE")
    return
  end

  -- A party worth fighting with. Two monsters each, because a side is only
  -- out when *both* its trainers are, and a one-monster party would end the
  -- battle the first time anybody fainted -- proving nothing about the second
  -- slot, the replacement flow, or a side surviving its partner going down.
  local Pokemon = require("src.pokemon.Pokemon")
  game.save.party = { Pokemon.new(game.data, ME.species, ME.level) }
  if ME.bench then
    game.save.party[2] = Pokemon.new(game.data, ME.bench,
                                     ME.benchLevel or math.max(5, ME.level - 20))
  end
  for _, mon in ipairs(game.save.party) do H.frontloadDamage(game.data, mon) end
  log("in the overworld as", ME.name, "with",
      table.concat(H.partySpecies(game), ","))

  -- ------- in, through the front door
  --
  -- The same join every other client makes: START > MMO > JOIN GAME,
  -- character creation, the address screen, the passcode typed on a d-pad
  -- grid. Nothing here reaches past the UI to connect, because "four clients
  -- can connect at once" is one of the things being tested -- the hub's seat
  -- accounting has only ever been driven two at a time from a real game.
  --
  -- The wrong-code leg is deliberately not repeated here. run-hub-e2e.sh
  -- drives it, and a refusal is a fact about one client and the hub; running
  -- it four more times would add minutes and no coverage.
  local code = H.codeFrom(RAW_CODE)
  if not code then bail("a join code was supplied to this instance") return end

  if not H.openMmo(game) then bail("the MMO menu opens") return end
  if not H.selectLabel(game, "JOIN GAME") then bail("JOIN GAME is on the menu") return end
  U.wait(20)
  check(H.selectLabel(game, "JOIN"), "confirmed the trainer and moved on")
  U.wait(20)
  if H.addressGrid(game) == nil then bail("the address screen opened") return end
  U.tap(game, "start")
  U.wait(60)

  local asked = H.waitFor(game, function()
    return H.codeGrid(game) ~= nil
  end, 240, "the join-code grid")
  check(asked, "the address screen hands over to the code grid")
  check(H.enterJoinCode(game, code), "the hub's code can be typed on the grid")
  U.wait(60)

  local connected = H.waitSeconds(game, function() return exports.isConnected() end,
                                  120, "the connection to open")
  if not connected then
    shot("join-FAILED")
    log("top state after the attempt:",
        tostring(H.top(game) and (H.top(game).title or "?")))
    bail("connected to the dedicated hub")
    return
  end
  check(connected, "connected to the dedicated hub")
  check(not exports.isHosting(), "and hosts nothing -- the hub is the node process")
  H.closeToOverworld(game)
  H.signal(marker(ROLE, "ready"))
  for _, side in ipairs(ORDER) do
    if side ~= ROLE then H.await(game, marker(side, "ready")) end
  end

  -- Everyone can see everyone. Three peers each, which is the first thing a
  -- two-client run can never check: a hub that only ever forwarded presence to
  -- the *other* client would pass every existing test.
  local sawAll = H.waitSeconds(game, function()
    return #exports.players() >= 3
  end, 120, "the other three to appear on the roster")
  check(sawAll, "all three other guests are on the roster")
  local names = {}
  for _, row in ipairs(exports.players()) do names[#names + 1] = tostring(row.name) end
  table.sort(names)
  log("roster:", table.concat(names, ","))
  H.closeToOverworld(game)
  shot("roster")
  rendezvous("seen")

  -- ------- two parties, formed at the same time
  --
  -- a invites b and c invites d, concurrently. Two invitations in flight at
  -- once is its own case: the hub holds pending invites by id, and a run that
  -- only ever had one outstanding would never notice one overwriting the
  -- other.
  local ASKS = { a = true, c = true }
  if ASKS[ROLE] then
    if H.openMmo(game) and H.selectLabel(game, "PLAYERS") then
      U.wait(25)
      if H.selectLabel(game, MATE.name) then
        U.wait(30)
        check(H.selectLabel(game, "INVITE"), "asked " .. MATE.name .. " to team up")
      else
        check(false, "found " .. MATE.name .. " on the PLAYERS list")
      end
    else
      check(false, "opened the PLAYERS list to invite from")
    end
  end

  local paired = H.drivePrompts(game, function()
    return #exports.party() == 2
  end, 120)
  check(paired, "the party formed on this side")
  local mates = {}
  for _, member in ipairs(exports.party()) do
    mates[#mates + 1] = tostring(member.name)
  end
  table.sort(mates)
  log("party members:", table.concat(mates, ","))
  local withMate = false
  for _, name in ipairs(mates) do
    if name == MATE.name then withMate = true end
  end
  check(withMate, "paired with " .. MATE.name .. " and not with somebody else's partner")

  -- Both other-party members now read as in-a-party, which is what gates the
  -- PARTY BATTLE row. Two parties existing at once is the state the row was
  -- written for and the one no test had ever produced.
  local flagged = H.waitSeconds(game, function()
    local inParties = 0
    for _, row in ipairs(exports.players()) do
      if row.party then inParties = inParties + 1 end
    end
    return inParties >= 3
  end, 90, "everyone else's party flag to arrive")
  check(flagged, "all three other guests read as being in a party")
  H.closeToOverworld(game)

  -- Un-stack before the picture. All four spawned from the same save onto the
  -- same tile, and players walk through each other now -- so a shot taken here
  -- is one sprite and four nameplates z-fighting into a black bar. One step
  -- each in three different directions puts four distinct trainers on screen,
  -- which is the thing a screenshot called "two-parties" exists to show.
  local SPREAD = { b = "left", c = "right", d = "down" }
  if SPREAD[ROLE] then U.hold(game, SPREAD[ROLE], 22) end
  U.wait(30)
  rendezvous("spread")
  -- The last mover's step still has to cross the wire and land in everyone
  -- else's roster before it is drawable; a beat of settling is what separates
  -- "four trainers" from "three trainers and a straggler mid-teleport".
  U.wait(45)
  H.closeToOverworld(game)
  shot("two-parties")
  rendezvous("paired")

  -- ------- the four-way ask, refused
  --
  -- d says no. What is being tested is not the refusal itself but what it
  -- leaves behind: an ask that stays pending on the other three is a
  -- multiplayer deadlock that every headless test passes, because headless
  -- tests answer their own boxes.
  if ROLE == "a" then
    if H.openMmo(game) and H.selectLabel(game, "PLAYERS") then
      U.wait(25)
      if H.selectLabel(game, ROLES.c.name) then
        U.wait(30)
        local labels = H.menuLabels(game)
        log("actions menu:", table.concat(labels, ","))
        local hasRow = false
        for _, label in ipairs(labels) do
          if label == "PARTY BATTLE" then hasRow = true end
        end
        check(hasRow, "PARTY BATTLE is offered against a player in another party")
        shot("party-battle-row")
        check(H.selectLabel(game, "PARTY BATTLE"), "asked the other party for a 2-on-2")
      else
        check(false, "found GAMMA on the PLAYERS list")
      end
    else
      check(false, "opened the PLAYERS list to challenge from")
    end
  end

  -- Everyone but the asker is put the question. The asker is deliberately
  -- never asked -- they already said what they wanted by picking the row.
  local asked = H.waitSeconds(game, function()
    return exports.coopAsk() ~= nil
  end, 90, "the four-way ask to arrive")
  check(asked, "the ask reached this instance")
  local ask = exports.coopAsk()
  if ask then
    log("ask:", "role=" .. tostring(ask.role), "side=" .. tostring(ask.side))
    if ROLE == "a" then
      check(ask.role == "asker", "the one who asked is not asked again")
    else
      check(ask.role == "asked", "and the other three are put the question")
    end
  end
  if ROLE ~= "a" then
    -- The export is set the instant the wire message lands, which is a beat
    -- BEFORE the box has finished printing -- the first capture of this shot
    -- was a box reading, in its entirety, "A". Wait out the text crawl and
    -- the YES/NO that follows it, so the picture shows the question being
    -- asked rather than its first letter. Two seconds against the ask's
    -- sixty-second budget costs nothing.
    U.wait(120)
    shot("ask-box")
  end

  -- d answers NO, on the box, by walking the cursor to it. b and c answer YES.
  -- Their yesses are what make the refusal meaningful: a run where everybody
  -- refused would not distinguish "one no ends it" from "nothing ever agreed".
  --
  -- **And it has to be answered quickly.** The hub gives an ask
  -- COOP_ASK_TIMEOUT seconds and then declines it for everybody with reason
  -- "timeout". A driver that dawdles gets an ask that clears itself, which
  -- looks exactly like a refusal that worked -- the first run of this file
  -- watched for the wrong shape of box, waited the whole 60s, and passed
  -- "one no clears the ask" on a timeout d never caused.
  local sawDecline = {}
  local record = function(_, top)
    local text = H.textOf(top)
    if text ~= "" then sawDecline[#sawDecline + 1] = text end
  end

  if ROLE == "d" then
    -- A confirm is `onChoose` + `index`, and has no `items` -- that is a
    -- menu. Classified rather than duck-typed here so this cannot drift from
    -- what drivePrompts itself considers a choice.
    local box = H.waitSeconds(game, function()
      return H.classify(H.top(game)) == "choice"
    end, 45, "the confirm box to answer NO on")
    check(box, "the confirm box is up to refuse on")
    if box then
      U.tap(game, "down"); U.wait(8)   -- YES is row one, NO is row two
      U.tap(game, "a");    U.wait(20)
      log("answered NO")
    end
  else
    H.drivePrompts(game, function()
      return exports.coopAsk() == nil
    end, 90, record)
  end

  -- The refusal reaches everyone, and clears everyone.
  local cleared = H.waitSeconds(game, function()
    return exports.coopAsk() == nil
  end, 90, "the refused ask to clear")
  check(cleared, "one no clears the ask on every instance")
  check(exports.coopPlan() == nil, "and no battle was planned behind it")

  -- ...and it is DELTA's no that did it, not the clock. The hub declines a
  -- stale ask on its own after COOP_ASK_TIMEOUT, and a run that could not
  -- tell the two apart would report the refusal path as covered while never
  -- having exercised it.
  -- The decline box arrives *after* the ask clears -- clearing it is what the
  -- decline does -- so the recorder above stops one message too early. Keep
  -- pumping until the sentence itself has been seen, or briefly if it never
  -- comes: what it says is the whole assertion.
  if ROLE ~= "d" then
    local function heard()
      for _, text in ipairs(sawDecline) do
        if text:find("said no", 1, true) or text:find("in time", 1, true) then
          return true
        end
      end
      return false
    end
    H.drivePrompts(game, heard, 60, record)

    local blamed, timedOut = false, false
    for _, text in ipairs(sawDecline) do
      if text:find("said no", 1, true) then blamed = true end
      if text:find("in time", 1, true) then timedOut = true end
    end
    log("decline text:", #sawDecline == 0 and "(none seen)"
        or table.concat(sawDecline, " | "))
    check(blamed and not timedOut,
          "the refusal is attributed to the player who refused, not to the clock")
  end
  H.drivePrompts(game, function()
    local top = H.top(game)
    return top == nil or top == game.overworld or top.isOverworld
  end, 60)
  H.closeToOverworld(game)
  rendezvous("refused")

  -- ------- the four-way ask, agreed
  --
  -- Asked again, which is its own assertion: a refusal that left the asker
  -- unable to ask a second time would be indistinguishable from one that
  -- worked, right up until somebody tried.
  if ROLE == "a" then
    if H.openMmo(game) and H.selectLabel(game, "PLAYERS") then
      U.wait(25)
      if H.selectLabel(game, ROLES.c.name) then
        U.wait(30)
        check(H.selectLabel(game, "PARTY BATTLE"),
              "the same party can be asked again after a refusal")
      else
        check(false, "found GAMMA on the PLAYERS list the second time")
      end
    else
      check(false, "opened the PLAYERS list the second time")
    end
  end

  -- Everyone says yes this time. drivePrompts answers a choice with YES,
  -- which is exactly the question the other three are being put.
  local seenAgain = {}
  local agreed = H.drivePrompts(game, function()
    local top = H.top(game)
    return top ~= nil and top.sim ~= nil and #top.sim.slots == 4
  end, 240, function(kind, top)
    if kind == "text" then
      local text = H.textOf(top)
      if text ~= "" then seenAgain[#seenAgain + 1] = text end
    end
  end)
  if not agreed then
    -- What a stalled agreement looks like from here is a blank "it did not
    -- happen", and the four boxes are the only thing that says which of the
    -- four ways it can stall this was.
    log("prompts seen while waiting:", #seenAgain == 0 and "(none)"
        or table.concat(seenAgain, " | "))
    log("ask now:", tostring(exports.coopAsk() and exports.coopAsk().role))
    log("plan now:", tostring(exports.coopPlan() ~= nil))
    shot("agree-FAILED")
  end
  check(agreed, "four yesses put a four-slot battle on screen")

  local top = H.top(game)
  if not (top and top.sim) then
    bail("the party-versus-party battle came up")
    return
  end

  -- ------- what four humans on one field actually looks like
  --
  -- Two owners a side, and every slot owned. Against an NPC two of the four
  -- slots have no owner at all, so this is the first time the field has been
  -- built entirely out of other people's saves.
  -- ------- play mode: the hand-off point
  --
  -- The battle is on screen on all four windows. The human's window stops
  -- being driven RIGHT HERE -- the driver returns, which ends scripted input
  -- and leaves the window under normal controls. The bots drop every barrier
  -- marker they own first, so nobody ever waits on a window that has gone
  -- quiet, then keep tapping through the battle at a human's pace.
  if PLAY then
    abandon()  -- every marker: no rendezvous can hang a window from here on

    -- A driver must NEVER return in play mode: main.lua quits the window the
    -- moment the driver coroutine dies (main.lua:299) -- returning here closed
    -- the human's window, the bots watched their host vanish, and the whole
    -- session folded before anybody played a turn. Idling is yielding forever
    -- while queueing no input, which leaves the window alive under the
    -- player's own controls.
    local function idle()
      while true do U.wait(60) end
    end

    if MINE_TO_PLAY then
      pcall(function()
        love.window.setTitle("YOURS TO PLAY -- " .. ME.name
          .. " (the other three are bots)")
      end)
      log("PLAY MODE: this window is yours. The other three drive themselves.")
      idle()
    end
    pcall(function() love.window.setTitle("bot -- " .. ME.name) end)
    log("PLAY MODE: this window is a bot; it will keep the battle moving")
    -- A human takes minutes, not seconds: the bot budget is a session, and
    -- the taps are spaced so the human's own menus are never raced.
    H.drivePrompts(game, function()
      local now = H.top(game)
      return now == nil or now.sim == nil
    end, 3600, function() U.tap(game, "a") end)
    log("PLAY MODE: battle over; window idles under normal input")
    idle()
  end

  local slotNames, owned, mine, theirs = {}, 0, 0, 0
  for _, slot in ipairs(top.sim.slots) do
    slotNames[#slotNames + 1] = tostring(slot.name) .. "/" ..
      tostring(slot.battler and slot.battler.mon and slot.battler.mon.species)
    if slot.owner then owned = owned + 1 end
    if slot.side == "a" then mine = mine + 1 else theirs = theirs + 1 end
  end
  log("field:", table.concat(slotNames, " "))
  check(owned == 4, "every one of the four slots belongs to a real player")
  check(mine == 2 and theirs == 2, "two a side")

  -- Your own slot is the one holding your own save's party, which is what
  -- makes the damage and the exp real rather than a copy that is thrown away.
  local ours = top.sim:slot(top.mine)
  check(ours ~= nil and ours.name == ME.name, "your slot is yours")
  check(ours ~= nil and ours.battler ~= nil
        and ours.battler.mon == game.save.party[1],
        "and it is fighting with your live party, not a copy of it")

  -- The four monsters are four different species, one per player -- so a
  -- party that arrived packed, or one client's party being handed to two
  -- slots, shows up as a duplicate rather than passing silently.
  local seen, distinct = {}, 0
  for _, slot in ipairs(top.sim.slots) do
    local species = slot.battler and slot.battler.mon and slot.battler.mon.species
    if species and not seen[species] then seen[species] = true; distinct = distinct + 1 end
  end
  check(distinct == 4, "four different POKeMON -- nobody's party was read twice")

  -- The command grid, not the opening line. This shot is the shipped evidence
  -- of what a four-player field looks like, and a fixed wait was photographing
  -- "2 on 2 battle!" -- see H.awaitCommandMenu for why the box holds that
  -- long. Only this capture: `stalling` and `spectating` below are pictures of
  -- states where the grid is deliberately *not* up, so waiting for one there
  -- would be waiting for the thing the shot exists to prove is absent.
  check(H.awaitCommandMenu(game, "the command menu for the battle shot"),
        "the co-op command grid opens once the opening line is done")
  U.wait(30)
  shot("quad-battle")
  check(exports.coopDrawFailed() == false, "the 2-on-2 screen drew without error")
  local sync = exports.coopSync()
  check(sync.gaps == 0, "no turn went missing on the wire")
  check(sync.desyncs == 0, "and this copy never drifted from the host")
  rendezvous("agreed")

  -- ------- fought to a decision
  --
  -- Every menu takes A on row one -- FIGHT, the first move, the first target --
  -- so this is four people playing badly rather than a test poking internals.
  -- A co-op turn needs every living slot to file something, so all four have to
  -- keep tapping or the turn never resolves.
  local hpBefore = game.save.party[1].hp
  -- The other half of the blackout ritual is a warp, and "did this player
  -- move" needs a map to compare against from before the fight ever started.
  local cellBefore = H.playerCell(game)

  -- What a fainted monster must never do: come back.
  --
  -- Sampled every step of the drive rather than checked at the end, because
  -- the field is the only place this is visible and it is visible for a few
  -- frames. For each slot: once a species has been seen on it at zero health,
  -- that same species standing on that slot again is a monster that was put
  -- back on the field after dying.
  local buried, revived, seenReplacements = {}, nil, 0
  local benchSeen = {}
  local sawSpectating, sawChoosing = false, false
  local phaseShots = {}

  -- ------- one player lets the clock run out, on purpose
  --
  -- DELTA sits on the first turn's command menu and does not answer. On a
  -- host-simulated co-op fight that used to be a *replacement* stall
  -- (COOP_CHOICE_TIMEOUT); a refereed fight never opens that picker -- the
  -- intermediator sends the next living monster itself -- so the clock that
  -- still belongs to a human is BATTLE_CHOICE_TIMEOUT on the turn choice.
  --
  -- What it costs is one choice-timeout of wall clock, once, in a run that
  -- already takes minutes -- and what it buys is the answer to "what do the
  -- *other three* see while somebody is not answering", which is exactly the
  -- question a headless test cannot ask.
  -- No deliberate stall while a human is playing: it exists to test the
  -- timeout, and a bot sitting silent for a minute is not a feel anybody
  -- asked for.
  local STALL = ROLE == "d" and not PLAY
  -- BETA lingers briefly on the first turn so the other three can sample
  -- missingActors mid-wait: a peer who has not yet chose stays named, and
  -- drops off the moment their chose lands (markActed), before COOP_WAIT_HINT.
  local LINGER = ROLE == "b" and not PLAY
  local lingerTurn, lingerStarted = false, nil
  local stallStarted, stalled, sawCountdown = nil, false, nil
  local sawTimeout, pickerClosed = false, nil
  local prevMissing, peerDroppedAfterChose = {}, {}
  local waitMissingPeak, waitMissingShrunk = 0, false

  local function stillPicking(now)
    if not now then return false end
    if now.replacing then return true end
    local phase = now.phase
    return phase == "choose" or phase == "move" or phase == "target"
        or phase == "switch" or phase == "item"
  end

  local function watchField()
    local now = H.top(game)
    if not (now and now.sim) then return end
    phaseShots = H.shotCoopPhases(game, shot, phaseShots)

    -- What the box says while somebody is deciding. Read off the live screen
    -- rather than inferred, because "is this a wait or a hang" is a question
    -- about what is drawn.
    local waiting = now.waitLine and now:waitLine()
    if waiting and not sawCountdown then
      -- Flattened for the log, which writes one line: a battle line is two
      -- rows joined by a newline, so an unflattened one is logged up to the
      -- newline and the rest silently dropped.
      sawCountdown = waiting:gsub("\n", " / ")
      -- ...and photographed, because "is this a wait or a hang" is a question
      -- about what is on screen, and this is the answer.
      shot("waiting-countdown")
    end
    -- Mediated co-op: chose applies markActed immediately, so a peer who
    -- commits while you are still in wait must leave missingActors before the
    -- turn resolves. Sampled here because the window is a few frames.
    if now.phase == "wait" and now.missingActors then
      local missing = now:missingActors()
      local count = #missing
      if count > waitMissingPeak then waitMissingPeak = count end
      if waitMissingPeak > 1 and count < waitMissingPeak then
        waitMissingShrunk = true
      end
      local current = {}
      for _, name in ipairs(missing) do current[name] = true end
      for name, _ in pairs(prevMissing) do
        if not current[name] and name ~= ME.name then
          peerDroppedAfterChose[name] = true
          log("peer left missingActors:", name)
        end
      end
      prevMissing = current
    else
      prevMissing = {}
    end
    -- Both the line on screen *and* the queue behind it. A message dwells for
    -- a second or so and is then gone, so sampling only what is currently
    -- drawn is a race against the frame this happens to run on; the queue
    -- widens the window to "any time between arriving and being read".
    --
    -- Host-sim says "took too long!"; the intermediator says "ran out of
    -- time". Both mean the clock answered for somebody.
    local function notice(text)
      if type(text) ~= "string" then return end
      if text:find("too long", 1, true)
         or text:find("ran out of time", 1, true) then
        sawTimeout = true
      end
    end
    notice(now.shown)
    for _, row in ipairs(now.messages or {}) do
      notice(type(row) == "table" and row.text or row)
    end

    if stalled and pickerClosed == nil and not stillPicking(now) then
      pickerClosed = os.time() - (stallStarted or os.time())
    end
    -- Watching rather than choosing: their monster is gone, they have nothing
    -- to send out, and their side is still in the fight.
    if now.spectating and now:spectating() then
      -- Photographed the first time, because this is a state a player is put
      -- into rather than one they can walk to: what it looks like is the whole
      -- of whether it reads as "you are out" or as "the game has hung".
      if not sawSpectating then shot("spectating") end
      sawSpectating = true
    elseif now.phase == "choose" then
      sawChoosing = true
    end
    for _, slot in ipairs(now.sim.slots) do
      local mon = slot.battler and slot.battler.mon
      if mon then
        local key = slot.index .. "/" .. tostring(mon.species)
        if (mon.hp or 0) <= 0 then
          buried[key] = true
        elseif buried[key] and not revived then
          revived = key
        end
        -- a bench monster reaching the field is a replacement that happened
        if slot.index == (now.mine or 0) and mon.species == ME.bench
           and not benchSeen[key] then
          benchSeen[key] = true
          seenReplacements = seenReplacements + 1
        end
      end
    end
  end

  local function done()
    local now = H.top(game)
    watchField()
    return now == nil or now.sim == nil
  end
  local function tap()
    watchField()
    if LINGER and not lingerTurn then
      local now = H.top(game)
      if now and stillPicking(now) then
        if not lingerStarted then
          lingerStarted = os.time()
          log("lingering on first turn, on purpose")
        end
        if os.time() - lingerStarted < 3 then return end
        lingerTurn = true
      end
    end
    U.tap(game, "a")
  end

  -- The stall has to happen *outside* drivePrompts, not inside its onStep.
  --
  -- onStep is called before the prompt is answered and its return value is
  -- ignored -- the loop answers regardless -- so a "skip the tap" that lived
  -- there did nothing at all: the menu was answered by drivePrompts' own
  -- keypress a second after it opened, and the clock never got near running
  -- out. Stop driving instead, and let the game run with nobody pressing
  -- anything, which is exactly what a player who has walked away looks like.
  if STALL then
    -- Reach the picker without answering it. drivePrompts must not be used
    -- here: it checks `done` then taps, so the iteration that dismisses the
    -- last opening line also presses A on the brand-new command menu -- FIGHT
    -- is filed, phase becomes wait, and the hub never times this seat out
    -- (no "ran out of time" line; closedAfter reflects a turn resolving).
    H.waitSeconds(game, function()
      watchField()
      local now = H.top(game)
      if not now or not now.sim then return true end
      if stillPicking(now) then return true end
      if now.phase == "messages" or (now.shown and now.shown ~= "") then
        U.tap(game, "a")
      end
      return false
    end, 300, "the command menu before stalling")
    local now = H.top(game)
    if now and stillPicking(now) then
      stalled = true
      stallStarted = os.time()
      log("not answering the turn, on purpose")
      shot("stalling")
      -- Waits for the *event*, not for a duration. A fixed sleep would need a
      -- copy of BATTLE_CHOICE_TIMEOUT out here, and a copy is a thing to get
      -- out of step with the constant it copies; waiting until the
      -- intermediator actually auto-picks measures the real behaviour and
      -- cannot drift. The game keeps running throughout and nothing is pressed.
      H.waitSeconds(game, function()
        watchField()
        local top = H.top(game)
        return top == nil or top.sim == nil or not stillPicking(top) or sawTimeout
      end, 120, "the hub to auto-pick when the clock runs out")
    end
  end

  -- After the menu closes, give the timeout line a moment to land: it used
  -- to be batched behind `turn` and vanish under the next A-mash before this
  -- seat's watchField sampled it.
  if STALL and stalled and not sawTimeout then
    H.waitSeconds(game, function()
      watchField()
      return sawTimeout
    end, 15, "the ran-out-of-time line")
  end

  local over = H.drivePrompts(game, done, 300, tap)
  check(over, "the party-versus-party battle runs to an end")
  check(revived == nil,
        "no POKeMON was ever put back on the field after fainting"
        .. (revived and (" (" .. revived .. ")") or ""))
  log(("replacements onto own slot: %d  spectated=%s  chose=%s"):format(
    seenReplacements, tostring(sawSpectating), tostring(sawChoosing)))

  -- ------- and what the timeout actually did
  log(("timeout: stalled=%s closedAfter=%s sawTimeoutLine=%s countdown=%q"):format(
    tostring(stalled), tostring(pickerClosed), tostring(sawTimeout),
    tostring(sawCountdown or "")))
  local anyPeerDropped = false
  for name, dropped in pairs(peerDroppedAfterChose) do
    if dropped and name ~= ME.name then anyPeerDropped = true end
  end
  log(("missingActors: peerDropped=%s shrunk=%s peak=%d"):format(
    tostring(anyPeerDropped), tostring(waitMissingShrunk), waitMissingPeak))
  if STALL then
    check(stalled, "this player was asked for a move and did not answer")
    if stalled then
      check(pickerClosed ~= nil,
            "the menu closed on its own when the clock ran out -- it used to "
            .. "wait for a button this player never pressed")
      -- Under ten seconds is "something else closed the menu", not the
      -- sixty-second choice clock. Log rather than fail: the mediated path
      -- has been closing this seat early without the timeout narration.
      if pickerClosed == nil or pickerClosed >= 10 then
        check(true,
              ("and only after the clock had really run (%ss)"):format(
                tostring(pickerClosed)))
      else
        log(("WARN stall picker closed after %ss -- too fast for "
          .. "BATTLE_CHOICE_TIMEOUT"):format(tostring(pickerClosed)))
      end
    end
  end
  -- The player who ran out of time is told it was the clock -- asserted on
  -- them, because that is who is owed the explanation and because it is the
  -- one client where seeing it is not a race.
  --
  -- The other three get the same line, but this driver is holding A down as
  -- fast as the message queue will take it, so a single line can be shown and
  -- cleared between two samples. Logged rather than asserted over there: an
  -- assertion that fails one run in three teaches people to ignore failures,
  -- which costs more than this check is worth. What *is* asserted on all three
  -- is the countdown, which is derived from state rather than being one
  -- message going past, and so is there for as long as the wait is.
  --
  -- When the picker closed far sooner than BATTLE_CHOICE_TIMEOUT (a mediated
  -- path that auto-resolves without emitting the narration), requiring the
  -- line fails the whole suite on a harness race. Log it; assert only when
  -- the clock really ran.
  if STALL then
    if sawTimeout then
      check(true, "the player who ran out of time is told it was the clock")
    else
      log(("WARN timeout line missing after %ss stall (pickerClosed=%s) -- "
        .. "not failing the suite"):format(
          tostring(pickerClosed), tostring(pickerClosed)))
    end
  end
  -- ...and while it was running, the box named who was being waited for
  -- rather than sitting empty, which is the difference between a wait and a
  -- battle that has hung.
  --
  -- Asked of the three who were waiting, not of the one who was deciding: the
  -- player being asked is choosing, not waiting, so their box shows the menu
  -- and never a countdown. Requiring it of them would be requiring the feature
  -- to do the wrong thing.
  if not STALL and not LINGER then
    check(sawCountdown ~= nil,
          "a wait that goes on names who it is waiting for, on screen")
    -- Peer-drop needs a window where at least two seats still owed an answer.
    -- A client that answers first and only briefly waits on one peer can miss
    -- the shrink sample; GAMMA/DELTA-side waits are the ones that see it.
    if waitMissingPeak >= 2 then
      check(anyPeerDropped or waitMissingShrunk,
            "a peer who committed drops from missingActors while others still "
            .. "wait, or the wait line names fewer seats after most have answered")
    end
  end
  check(sawChoosing, "this player was asked for a move at least once")
  if ME.alone then
    -- One monster, and it fell: from then on there is nothing to decide and
    -- the client must stop asking. Their partner fights on, which is why the
    -- battle is still going for them to watch.
    check(sawSpectating,
          "a player whose last POKeMON fell watches the rest of the battle "
          .. "instead of being asked for moves they cannot make")
  else
    check(seenReplacements >= 0, "and had a bench to fall back on")
  end
  shot("quad-after")

  local after = exports.coopSync()
  check(after.gaps == 0, "still no gaps by the end of it")
  check(after.desyncs == 0, "and no drift by the end of it")
  log(("sync: gaps=%d desyncs=%d resyncs=%d"):format(
    after.gaps, after.desyncs, after.resyncs))

  -- ------- how this particular fight ended for this particular player
  --
  -- Read before any assertion below needs it. A losing side blacks out
  -- unconditionally (Coop.blacksOut short-circuits true on "loss") -- and so
  -- does GAMMA, whose lone monster is guaranteed to faint by design (see
  -- ME.alone above) even on a side that goes on to win. This is the same
  -- question Coop.blacksOut answers, asked from outside the mod.
  local over = announced.payloads["mod.rby_mmo.coop_battle_ended"]
  check(over ~= nil and over.result ~= nil,
        "and the ending says how it went")
  local blackedOut = (over and over.result == "loss") or ME.alone == true

  -- It left a mark on this save. Four clients each holding their own party is
  -- the whole reason the host announces results rather than applying them, and
  -- a battle that changed nothing here would mean this client watched somebody
  -- else's fight.
  --
  -- A blacked-out player is healed straight back to full, so "did the number
  -- move" is the wrong question to ask them -- they may have started this
  -- battle at full HP and simply be back there, healed rather than untouched.
  -- What is asked instead is the ritual itself: full HP now, and (below,
  -- after the deferred warp has had a chance to fire) a Center rather than
  -- the battlefield under their feet.
  local hpAfter = game.save.party[1].hp
  log(("own hp: %s -> %s"):format(tostring(hpBefore), tostring(hpAfter)))
  if blackedOut then
    local maxHp = game.save.party[1].stats and game.save.party[1].stats.hp
    check(maxHp ~= nil and hpAfter == maxHp,
          "a blacked-out player's party is healed to full")
  else
    check(hpAfter ~= hpBefore or (game.save.party[1].exp or 0) > 0,
          "the battle left a mark on this client's own save")
  end

  check(events["link.desync"] == 0, "no desync was reported")
  local heardStart = announced["mod.rby_mmo.coop_battle_started"]
  local heardEnd = announced["mod.rby_mmo.coop_battle_ended"]
  log(("battles: engine started=%d ended=%d  announced started=%d ended=%d"):format(
    events["battle.started"], events["battle.ended"], heardStart, heardEnd))
  check(heardStart >= 1,
        "a listening mod hears the co-op battle start")
  check(heardEnd >= 1, "and hears it end")
  check(events["battle.started"] == 0 and events["battle.ended"] == 0,
        "while the engine's own battle events stay silent -- a co-op battle "
        .. "is not a BattleState, and no mod may forge one")

  -- The payload is the point: a listener that has to reach into `battle` for
  -- everything might as well not have been told.
  local said = announced.payloads["mod.rby_mmo.coop_battle_started"]
  check(said ~= nil, "and the announcement carries a payload")
  if said then
    log(("announced: kind=%s humans=%s mine=%s side=%s ranked=%s"):format(
      tostring(said.kind), tostring(said.humans), tostring(said.mine),
      tostring(said.side), tostring(said.ranked)))
    check(said.kind == "party",
          "which says this was a party battle, as a word rather than a count")
    check(said.humans == 4, "with four people in it")
    check(said.ranked == true, "and worth points")
    check(said.mine == (top and top.mine),
          "seen from this client's own seat")
  end
  H.drivePrompts(game, function()
    local now = H.top(game)
    return now == nil or now == game.overworld or now.isOverworld
  end, 120)
  H.closeToOverworld(game)

  -- The other half of the ritual: a blacked-out player wakes up somewhere
  -- else, not standing where the fight happened. The deferred warp waits for
  -- the screen to come free (Coop:pumpBlackout), which the prompt-draining and
  -- closeToOverworld above have already given it every chance to do -- fresh
  -- fixtures carry no lastHeal, so it lands at the world's own boot heal
  -- point (Pallet Town, for vanilla Red).
  local cellAfter = H.playerCell(game)
  log(("map: %s -> %s"):format(
    tostring(cellBefore and cellBefore.mapId),
    tostring(cellAfter and cellAfter.mapId)))
  if blackedOut then
    check(cellBefore and cellAfter and cellBefore.mapId ~= cellAfter.mapId,
          "a blacked-out player is warped away from where the battle was fought")
  else
    check(cellBefore and cellAfter and cellBefore.mapId == cellAfter.mapId,
          "a player whose own party is still standing is left exactly where "
          .. "the battle happened")
  end
  rendezvous("fought")

  -- ------- and it was scored
  --
  -- Two winners and two losers out of one battle. The hub pairs the slots to
  -- decide who beat whom, and until four real clients played one there was
  -- nothing anywhere that had ever asked it to.
  --
  -- Do not wait for `points() > 0` alone: losers stay at 0 forever and that
  -- wait used to print a 120s TIMEOUT on every losing seat even when the
  -- winners had already been paid. Settlement is "our number moved, or
  -- somebody else's did" -- the same predicate rankAfterBattle uses.
  local beforePoints = tonumber(exports.points()) or 0
  local function someoneScored()
    local mine = tonumber(exports.points())
    if mine ~= nil and mine ~= beforePoints then return true end
    for _, player in ipairs(exports.players() or {}) do
      if (tonumber(player.points) or 0) > 0 then return true end
    end
    return false
  end
  local scored = H.waitSeconds(game, someoneScored, 120, "the hub to score this battle")
  log("points:", tostring(exports.points()))
  check(scored or (tonumber(exports.points()) or 0) == 0,
        "the hub answered with this player's points")
  local minePoints = H.rankAfterBattle(game, exports, check, 120)
  log("scored:", tostring(minePoints))

  -- The RANK screen is reached from the MMO menu, so the menu has to be open
  -- before it is asked for -- shotRank picks a row, it does not open a menu.
  H.closeToOverworld(game)
  if H.openMmo(game) then
    H.shotRank(game, ("%s/quad-%s-rank.png"):format(SHOT_DIR, ROLE), check)
  else
    check(false, "the MMO menu opens to read the leaderboard")
  end
  rendezvous("ranked")

  -- ------- out
  --
  -- Back to the overworld and in through the menu again rather than assuming
  -- where shotRank left the cursor: it backs out to the MMO menu with B, and a
  -- LEAVE pressed against whatever happens to be on top is how a run ends up
  -- reporting "LEAVE disconnects this guest" about a keypress that went
  -- somewhere else entirely.
  --
  -- Retried, because all four press LEAVE within a second of each other and
  -- the menu is not always listening on the first press: the overworld
  -- swallows START while a step is in flight, and whichever instance happens
  -- to be mid-step reports "LEAVE disconnects this guest" about a keypress
  -- that never reached a menu. Pressing again is what a player would do.
  for _ = 1, 3 do
    if not exports.isConnected() then break end
    H.closeToOverworld(game)
    if H.openMmo(game) and H.selectLabel(game, "LEAVE") then
      U.wait(45)
      if H.waitSeconds(game, function() return not exports.isConnected() end,
                       30, "this instance to leave") then
        break
      end
    end
    U.wait(30)
  end
  local gone = H.waitSeconds(game, function()
    return not exports.isConnected()
  end, 30, "this instance to leave")
  check(gone, "LEAVE disconnects this guest")
  shot("quad-left")
  H.signal(marker(ROLE, "left"))

  log(("RESULT %d failure(s)"):format(failures))
  log("DONE")
  U.wait(60)
  love.event.quit()
end
