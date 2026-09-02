-- Driver: six guests, two parties of three, one 3-on-3 between them.
--
-- Six instances under MMO_ROLE=a|b|c|d|e|f, launched by
-- tests/drivers/run-hex-e2e.sh (Node hub, all JOIN).
--
--   a ALPHA / b BETA / c CHARLIE  vs  d DELTA / e ECHO / f FOXTROT
--
--   MMO_ROLE=a POKEPORT_IDENTITY=mmohex-a \
--     POKEPORT_DRIVER=mods/rby_mmo/tests/drivers/mmo_hex.lua love .

if os.getenv("MMO_SOUND") ~= "1" and love and love.audio then
  love.audio.setVolume(0)
end

local ROLES = {
  a = { name = "ALPHA",   species = "CHARIZARD", level = 50, side = 1, lead = true },
  b = { name = "BETA",    species = "PIKACHU",    level = 50, side = 1 },
  c = { name = "CHARLIE", species = "BLASTOISE",   level = 50, side = 1 },
  d = { name = "DELTA",   species = "VENUSAUR",   level = 50, side = 2, lead = true },
  e = { name = "ECHO",    species = "ALAKAZAM",  level = 50, side = 2 },
  f = { name = "FOXTROT", species = "SNORLAX",    level = 50, side = 2 },
}
local ORDER = { "a", "b", "c", "d", "e", "f" }

local ROLE = tostring(os.getenv("MMO_ROLE") or "a"):lower()
if not ROLES[ROLE] then ROLE = "a" end

return function(game)
  local H = dofile("mods/rby_mmo/tests/drivers/mmo_util.lua")
  local U = H.U
  local TAG = "MMO_HEX_" .. ROLE:upper() .. ":"
  local ME = ROLES[ROLE]
  local SHOT_DIR = os.getenv("SHOT_DIR") or "/tmp/rby_mmo_hex_shots"
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
    U.shot(game, ("%s/hex-%s-%s.png"):format(SHOT_DIR, ROLE, name))
  end

  local function marker(side, tag) return ("hex_%s_%s"):format(side, tag) end

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

  local TAGS = { "ready", "seen", "paired", "agreed", "fought", "ranked", "left" }
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

  if not H.newGame(game, TAG) then
    log("RESULT 1 failure(s)")
    return
  end
  if game.save and game.save.player then
    game.save.player.name = ME.name
  end

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

  local Pokemon = require("src.pokemon.Pokemon")
  game.save.party = { Pokemon.new(game.data, ME.species, ME.level) }
  H.frontloadDamage(game.data, game.save.party[1])
  log("in the overworld as", ME.name, "with",
      table.concat(H.partySpecies(game), ","))

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
  check(asked, "the join-code grid opened")
  check(H.enterJoinCode(game, code), "the hub's code can be typed on the grid")
  U.wait(60)

  local connected = H.waitSeconds(game, function() return exports.isConnected() end,
                                  120, "the connection to open")
  if not connected then
    shot("join-FAILED")
    bail("connected to the dedicated hub")
    return
  end
  check(connected, "connected to the dedicated hub")
  H.closeToOverworld(game)
  H.signal(marker(ROLE, "ready"))
  for _, side in ipairs(ORDER) do
    if side ~= ROLE then H.await(game, marker(side, "ready")) end
  end

  local sawAll = H.waitSeconds(game, function()
    return #exports.players() >= 5
  end, 120, "the other five to appear on the roster")
  check(sawAll, "all five other guests are on the roster")
  H.closeToOverworld(game)
  shot("roster")
  rendezvous("seen")

  -- ------- two parties of three
  local function invite(name)
    H.closeToOverworld(game)
    if H.openMmo(game) and H.selectLabel(game, "PLAYERS") then
      U.wait(25)
      if H.selectLabel(game, name) then
        U.wait(30)
        return H.selectLabel(game, "INVITE")
      end
    end
    return false
  end

  if ME.lead then
    local first, second
    if ME.side == 1 then
      first, second = ROLES.b.name, ROLES.c.name
    else
      first, second = ROLES.e.name, ROLES.f.name
    end
    check(invite(first), "first invite from this party's lead")
    check(H.waitSeconds(game, function() return #exports.party() >= 2 end, 120,
                        "the second member to join"),
          "the second member joined")
    check(invite(second), "second invite completes the party of three")
  end

  local paired = H.drivePrompts(game, function()
    return #exports.party() == 3
  end, 180)
  check(paired, "the party formed with three members")
  local mates = {}
  for _, member in ipairs(exports.party()) do
    mates[#mates + 1] = tostring(member.name)
  end
  table.sort(mates)
  log("party members:", table.concat(mates, ","))

  local flagged = H.waitSeconds(game, function()
    local inParties = 0
    for _, row in ipairs(exports.players()) do
      if row.party then inParties = inParties + 1 end
    end
    return inParties >= 5
  end, 120, "everyone else's party flag to arrive")
  check(flagged, "all five other guests read as being in a party")
  H.closeToOverworld(game)

  local SPREAD = {
    b = "left", c = "right",
    e = "left", f = "right",
  }
  if SPREAD[ROLE] then U.hold(game, SPREAD[ROLE], 22) end
  U.wait(30)
  rendezvous("spread")
  U.wait(45)
  shot("two-parties")
  rendezvous("paired")

  -- ------- six-way ask, all yes (ALPHA asks DELTA's party)
  if ROLE == "a" then
    local target = ROLES.d
    if H.openMmo(game) and H.selectLabel(game, "PLAYERS") then
      U.wait(25)
      if H.selectLabel(game, target.name) then
        U.wait(30)
        local labels = H.menuLabels(game)
        local hasRow = false
        for _, label in ipairs(labels) do
          if label == "PARTY BATTLE" then hasRow = true end
        end
        check(hasRow, "PARTY BATTLE is offered against another party")
        check(H.selectLabel(game, "PARTY BATTLE"),
              "asked the other party for a 3-on-3")
      else
        check(false, "found the other party's lead on the PLAYERS list")
      end
    else
      check(false, "opened the PLAYERS list to challenge from")
    end
  end

  if ROLE == "a" then
    local ask = exports.coopAsk()
    if ask then check(ask.role == "asker", "the one who asked is not asked again") end
  else
    local askedBox = H.waitSeconds(game, function()
      return exports.coopAsk() ~= nil
    end, 90, "the six-way ask to arrive")
    check(askedBox, "the ask reached this instance")
    local ask = exports.coopAsk()
    if ask then check(ask.role == "asked", "and this side is put the question") end
    U.wait(60)
    shot("ask-box")
  end

  local agreed = H.drivePrompts(game, function()
    local top = H.top(game)
    return top ~= nil and top.sim ~= nil and #top.sim.slots == 6
  end, 300)
  check(agreed, "six yesses put a six-slot battle on screen")

  local top = H.top(game)
  if not (top and top.sim) then
    bail("the party-versus-party battle came up")
    return
  end

  local slotNames, owned, mine, theirs = {}, 0, 0, 0
  for _, slot in ipairs(top.sim.slots) do
    slotNames[#slotNames + 1] = tostring(slot.name) .. "/" ..
      tostring(slot.battler and slot.battler.mon and slot.battler.mon.species)
    if slot.owner then owned = owned + 1 end
    if slot.side == "a" then mine = mine + 1 else theirs = theirs + 1 end
  end
  log("field:", table.concat(slotNames, " "))
  check(owned == 6, "every one of the six slots belongs to a real player")
  check(mine == 3 and theirs == 3, "three a side")

  local ours = top.sim:slot(top.mine)
  check(ours ~= nil and ours.name == ME.name, "your slot is yours")
  check(ours ~= nil and ours.battler ~= nil
        and ours.battler.mon == game.save.party[1],
        "and it is fighting with your live party, not a copy of it")

  local seen, distinct = {}, 0
  for _, slot in ipairs(top.sim.slots) do
    local species = slot.battler and slot.battler.mon and slot.battler.mon.species
    if species and not seen[species] then seen[species] = true; distinct = distinct + 1 end
  end
  check(distinct == 6, "six different POKeMON -- nobody's party was read twice")

  check(H.awaitCommandMenu(game, "the command menu for the battle shot"),
        "the co-op command grid opens once the opening line is done")
  U.wait(30)
  shot("hex-battle")
  check(exports.coopDrawFailed() == false, "the 3-on-3 screen drew without error")
  local sync = exports.coopSync()
  check(sync.gaps == 0, "no turn went missing on the wire")
  check(sync.desyncs == 0, "and this copy never drifted from the host")
  rendezvous("agreed")

  local hpBefore = game.save.party[1].hp
  local over = H.drivePrompts(game, function()
    local now = H.top(game)
    return now == nil or now.sim == nil
  end, 300, function() U.tap(game, "a") end)
  check(over, "the party-versus-party battle runs to an end")
  shot("hex-after")

  local after = exports.coopSync()
  check(after.gaps == 0, "still no gaps by the end of it")
  check(after.desyncs == 0, "and no drift by the end of it")
  check(events["link.desync"] == 0, "no desync was reported")

  local heardStart = announced["mod.rby_mmo.coop_battle_started"]
  local heardEnd = announced["mod.rby_mmo.coop_battle_ended"]
  check(heardStart >= 1, "a listening mod hears the co-op battle start")
  check(heardEnd >= 1, "and hears it end")
  check(events["battle.started"] == 0 and events["battle.ended"] == 0,
        "while the engine's own battle events stay silent")

  local said = announced.payloads["mod.rby_mmo.coop_battle_started"]
  check(said ~= nil, "and the announcement carries a payload")
  if said then
    log(("announced: kind=%s humans=%s mine=%s side=%s ranked=%s"):format(
      tostring(said.kind), tostring(said.humans), tostring(said.mine),
      tostring(said.side), tostring(said.ranked)))
    check(said.kind == "party", "which says this was a party battle")
    check(said.humans == 6, "with six people in it")
    check(said.ranked == true, "and worth points")
  end
  log(("own hp: %s -> %s"):format(tostring(hpBefore),
      tostring(game.save.party[1].hp)))

  H.drivePrompts(game, function()
    local now = H.top(game)
    return now == nil or now == game.overworld or now.isOverworld
  end, 120)
  H.closeToOverworld(game)
  rendezvous("fought")

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
  check(scored or (tonumber(exports.points()) or 0) == 0,
        "the hub answered with this player's points")
  H.rankAfterBattle(game, exports, check, 120)
  H.closeToOverworld(game)
  if H.openMmo(game) then
    H.shotRank(game, ("%s/hex-%s-rank.png"):format(SHOT_DIR, ROLE), check)
  end
  rendezvous("ranked")

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
  check(H.waitSeconds(game, function()
    return not exports.isConnected()
  end, 30, "this instance to leave"), "LEAVE disconnects this guest")
  shot("hex-left")
  H.signal(marker(ROLE, "left"))

  log(("RESULT %d failure(s)"):format(failures))
  log("DONE")
  U.wait(60)
  love.event.quit()
end
