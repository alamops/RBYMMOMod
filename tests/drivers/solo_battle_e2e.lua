-- Committed e2e driver for **solo battles** (src/SoloBattle.lua): the mod's
-- own battle system substituted for the engine's on ordinary wild encounters
-- and trainers, with no hub, no partner and no socket anywhere.
--
-- One LOVE instance, no network. That is the whole point of the feature and
-- so it is the whole shape of this driver: everything the two-instance MMO
-- drivers need a peer for -- a referee, a partner, a wire -- solo does in
-- process, and the only thing worth proving out here is what the headless
-- suite structurally cannot see: a real overworld, a real engine BattleState
-- pushed onto a real stack, this mod's screen taking it over, and **the real
-- save afterwards**.
--
--   SHOT_DIR=/path/to/inspect \
--   POKEPORT_IDENTITY=soloe2e POKEPORT_TOUCH=0 \
--   POKEPORT_DRIVER=mods/rby_mmo/tests/drivers/solo_battle_e2e.lua \
--   love .
--
-- From the Gen1Recomp checkout root, with mods/rby_mmo -> RBYMMOMod. See
-- tests/drivers/run-solo-battle-e2e.sh for the wrapped, gated invocation on
-- both carts (it also writes the options.lua that enables the mod).
--
-- ------- what the legs prove, in order
--
--   1. **the row is real** -- the F10 mod manager's own row model carries
--      SOLO BATTLES and it reads OFF, so a player can find it and flip it.
--   2. **default OFF is honoured** -- with the row off, a staged wild
--      encounter is fought by the *engine's* battle. The mod is invisible.
--   3. **flipping it takes effect with no relaunch** -- the flip goes through
--      the manager row's own step(), which is what a keypress on that row
--      calls, and the next encounter diverts.
--   4. **a solo wild fight** diverts to this mod's screen, plays to a win, and
--      the save is right afterwards: exp gained, PP spent, the engine's own
--      battle told how it went and off the stack, overworld restored.
--   5. **a refused kind stays vanilla** -- Config.SOLO_REFUSED, spelled the
--      way each generation spells it (Gen 1 `ghost`, Gold's roaming
--      battleType byte), is fought by the engine with no word to the player.
--   6. **a solo trainer fight** diverts, plays to a win, and pays out: prize
--      money on the save, the engine's onFinish called with "win" (which is
--      the script's resume), and the player back in the overworld and walking.
--   7. **a real sighted trainer** (Gen 1; Gold's map objects carry no Gen 1
--      sight cone, so the leg skips there) walked into for real, so the
--      *defeated flag* is asserted against a live npcId rather than a staged
--      battle that never had one.
--   8. **a catch** in a solo wild fight adds the monster exactly once.
--
-- ------- what is local here, and why
--
-- `mmo_util.lua` is shared by every driver in this folder and several agents
-- are in it at once, so nothing below was added there. Each of these is either
-- solo-shaped or a thing the shared file gets wrong for a mediated screen:
--
--   * `bootToPlay` / `stackNames` -- thin wrappers now, nothing more. They
--     were real copies while the shared boot still went through the engine's
--     `U.newGame` and its 400-tap Gen 1 budget, short of the intro's ~441;
--     `H.newGame` fixed that upstream and `H.bootToPlay` routes through it, so
--     these just spare the call sites a `game` argument.
--   * `medOnStack` / `awaitCommandMenu` / `throwItem` -- a solo fight is a
--     `MediatedBattle`, which carries no `.sim`; every fight helper in
--     mmo_util keys on that field and would report a fight over before its
--     first turn opened.
--   * `stageRefusedWild` -- mmo_util's `stageWild` pushes the state itself and
--     the divert fires *inside* that push (StateStack:push emits screen.pushed
--     after enter()), so a refusal field stamped on the returned state would
--     always be one frame too late. This marks it before the push.
--   * `dropStaged` -- take a staged battle back off the stack by identity. The
--     legs that assert "the engine kept it" must not then fight it.
--   * `moneyOf` / `expOf` -- the two save fields spelled differently per
--     generation (`save.money` vs `save.player.money`, `mon.exp` vs
--     `mon.experience`). Mirrors src/Gen.lua's `money` accessor rather than
--     reaching into the mod, which is sandboxed away from a driver.

if os.getenv("MMO_SOUND") ~= "1" and love and love.audio then
  love.audio.setVolume(0)
end

return function(game)
  local H = dofile("mods/rby_mmo/tests/drivers/mmo_util.lua")
  local U = H.U
  local TAG = "SOLO_E2E:"
  local SHOT_DIR = os.getenv("SHOT_DIR") or "/tmp/rby_mmo_solo_shots"
  os.execute('mkdir -p "' .. SHOT_DIR .. '" 2>/dev/null')

  local MOD_ID = "rby_mmo"
  local OPTION_KEY = "solo"           -- src/SoloBattle.lua M.OPTION
  local OPTION_LABEL = "SOLO BATTLES" -- src/SoloBattle.lua M.OPTION_LABEL

  local pass, fail = 0, 0
  -- Tag-first, like battlefield_shot.lua: the wrapper greps `^SOLO_E2E:`, and
  -- U.log's own "[driver]" prefix would push the tag off the line start.
  -- mmo_util's own waits still log through U.log, and their TIMEOUT lines are
  -- grepped separately by the wrapper.
  local function log(...)
    local parts = { TAG }
    for i = 1, select("#", ...) do
      parts[#parts + 1] = tostring((select(i, ...)))
    end
    print(table.concat(parts, "\t"))
  end
  local function check(ok, what, note)
    if ok then
      pass = pass + 1
      log("ok " .. what .. (note and ("  [" .. tostring(note) .. "]") or ""))
    else
      fail = fail + 1
      log("FAIL " .. what .. (note and ("  [" .. tostring(note) .. "]") or ""))
    end
    return ok and true or false
  end
  local function skip(what, why)
    log("skip " .. what .. " -- " .. tostring(why))
  end
  local function shot(name)
    U.shot(game, SHOT_DIR .. "/" .. name .. ".png")
  end

  -- ------------------------------------------------------------------
  -- save readers, per generation
  -- ------------------------------------------------------------------

  -- src/Gen.lua's money accessor, mirrored: Gen 2 always writes
  -- save.player.money, Gen 1 keeps save.money unless a player table already
  -- carries one.
  local function moneyOf()
    local save = game and game.save
    if type(save) ~= "table" then return 0 end
    local player = save.player
    if save.generation == 2 or H.generation(game) == 2 then
      return math.floor(tonumber(player and player.money) or 0)
    end
    if type(player) == "table" and player.money ~= nil then
      return math.floor(tonumber(player.money) or 0)
    end
    return math.floor(tonumber(save.money) or 0)
  end

  -- MediatedBattle:gainExp writes through the engine's own Experience.apply
  -- (Gen 1, `mon.exp`) or src/Exp2.lua (Gen 2, `mon.experience`).
  local function expOf(mon)
    if type(mon) ~= "table" then return 0 end
    return math.floor(tonumber(mon.exp or mon.experience) or 0)
  end

  local function ppOf(mon)
    local total = 0
    for _, mv in ipairs((type(mon) == "table" and mon.moves) or {}) do
      total = total + (tonumber(mv.pp) or 0)
    end
    return total
  end

  local function lead()
    return game.save and game.save.party and game.save.party[1] or nil
  end

  -- A pristine, deterministic fighter before every leg that measures a delta.
  -- frontloadDamage puts the highest-power move in slot 1, which is what makes
  -- "mash A" resolve a fight instead of trading GROWLs until PP runs out.
  --
  -- Resolved per call rather than once at load: this file's helpers are
  -- defined before the boot below has run, and the generation is a property of
  -- the game that is running.
  local function partySpecies()
    return H.generation(game) == 2 and "CYNDAQUIL" or "CHARIZARD"
  end
  local function freshParty()
    local mon = H.seedParty(game, partySpecies(), 50)
    if mon then H.frontloadDamage(game.data, mon) end
    return mon
  end

  -- ------------------------------------------------------------------
  -- staging helpers this file owns
  -- ------------------------------------------------------------------

  -- Take a staged engine battle back off the stack, by identity.
  --
  -- Two legs assert the engine *kept* an encounter, and neither wants to then
  -- fight it: a vanilla battle driven to a decision here would prove nothing
  -- the engine's own suites do not already prove, and would cost a minute.
  local function dropStaged(state)
    if state == nil then return true end
    for _ = 1, 20 do
      if not H.onStack(game, state) then break end
      if not pcall(function() game.stack:pop() end) then break end
      U.wait(2)
    end
    U.wait(8)
    return not H.onStack(game, state)
  end

  -- Make a staged Gold battle end the way a real Gold battle ends.
  --
  -- On Gen 2 the pop that takes a finished battle off the stack does not live
  -- in `Gen2BattleState` at all: it lives inside the `onDone` closure
  -- `World:startBattle` builds around it (engine `src/world/gen2/World.lua`),
  -- and `src/Client.lua` aliases the state's absent `onFinish` onto it -- so
  -- every Gold battle a player can walk into carries *one* function, on both
  -- fields, and that function pops.
  --
  -- `mmo_util`'s Gen 2 staging pushes `Gen2BattleState` itself with a callback
  -- of its own, which recorded the outcome and popped nothing. That is a shape
  -- no Gold player can produce, and it is exactly the question
  -- `src/SoloBattle.lua`'s ending has to answer -- who takes the buried battle
  -- down -- so a leg staged that way was exercising a path the product does not
  -- ship while leaving the one it does ship untested. (It found a real
  -- fragility doing so, which is now fixed and covered headlessly: the
  -- non-popping shape is `goldNoPop` in `mods/rby_mmo/tests/solo_battle.lua`
  -- section 10.)
  --
  -- So the callbacks are restamped to Gold's real shape. Gen 1 is left alone:
  -- there the pop is `BattleState:finish`'s own, `onFinish` never pops, and
  -- `mmo_util`'s staging is already faithful.
  local function likeWorldStartBattle(state, onFinish)
    if state == nil or H.generation(game) ~= 2 then return state end
    local done = function(outcome)
      -- `World:startBattle` pops unconditionally. By identity here, because
      -- the engine's unconditional pop is safe on the invariants an overworld
      -- maintains and a driver has none of them: a wrong guess would take the
      -- world down and every assertion after it would blame the mod.
      if H.top(game) == state then pcall(function() game.stack:pop() end) end
      if onFinish then onFinish(outcome) end
    end
    state.onDone = done
    state.onFinish = done
    return state
  end

  -- A wild encounter this mod is required to hand straight back.
  --
  -- Gen 1 gets a real Pokemon Tower ghost through BattleState's own
  -- `makeGhost` (falling back to the bare field if the ghost art is not in
  -- this build's cache); Gold gets the roaming battle *byte*, which is the
  -- half of Config.SOLO_REFUSED that is keyed by value rather than by name --
  -- and is inert on the Gen 2 screen, which only ever branches on FORCESHINY
  -- and TRAP. Both are marked before the push, because the divert runs inside
  -- it.
  local function stageRefusedWild(species, level)
    species, level = species or "GASTLY", level or 5
    if H.generation(game) == 2 then
      local okB, Battle = pcall(require, "src.battle.gen2.Battle")
      local okM, Mon = pcall(require, "src.battle.gen2.Mon")
      local okS, Screens = pcall(require, "src.ui.Screens")
      if not (okB and Battle and okM and Mon and okS and Screens) then
        return nil, "gen2 battle modules unavailable"
      end
      local wild = Mon.new(game.data, species, level)
      if not wild then return nil, "no such species: " .. tostring(species) end
      local okNew, battle = pcall(Battle.new, {
        data = game.data,
        party = (game.save and game.save.party) or {},
        wild = wild,
        save = game.save,
        battleType = 5, -- BATTLETYPE_ROAMING, Config.SOLO_REFUSED_BATTLE_TYPES
      })
      if not (okNew and battle) then return nil, tostring(battle) end
      battle.battleType = 5
      local okPush, state = pcall(Screens.push, game, "Gen2BattleState",
        { battle = battle, save = game.save })
      state = (okPush and state) or H.top(game)
      if not state then return nil, "Gen2BattleState never came up" end
      return state, "battleType=5 (roaming)"
    end
    local BattleState = require("src.battle.BattleState")
    local function build()
      local ok, battle = pcall(BattleState.newWild, game, species, level)
      if ok and battle and not battle.dead then return battle end
      return nil
    end
    local battle = build()
    if not battle then return nil, "newWild refused " .. tostring(species) end
    local how = "makeGhost()"
    if not pcall(function() battle:makeGhost() end) then
      -- The ghost disguise loads art generated from the player's own cache and
      -- a build without it would leave the state half-mutated -- worse than
      -- not disguised at all. Start over and set the one field
      -- Config.SOLO_REFUSED actually reads.
      battle = build()
      if not battle then return nil, "newWild refused on the retry" end
      battle.ghost = true
      how = "ghost field (makeGhost unavailable)"
    end
    game.stack:push(battle)
    return battle, how
  end

  -- The species a wild leg fights. SENTRET is Gold's Route 29 opener and does
  -- not exist on Red; PIDGEY is the Gen 1 one and is in Johto too, so the
  -- fallback is real rather than decorative.
  local function stageWildOf(candidates, level, onFinish)
    for _, species in ipairs(candidates) do
      local staged = H.stageWild(game, species, level or 5, onFinish)
      if staged then return likeWorldStartBattle(staged, onFinish), species end
    end
    return nil, nil
  end

  -- ------------------------------------------------------------------
  -- driving the mod's screen
  -- ------------------------------------------------------------------
  --
  -- **A solo fight is a `MediatedBattle`, and a MediatedBattle has no `.sim`.**
  -- That field belongs to `CoopBattle`, the 2-on-2 screen, and every helper in
  -- mmo_util that touches a fight keys on it -- `awaitCommandMenu`,
  -- `throwBattleItem`, and the `top.sim == nil` done-predicate the co-op legs
  -- pass to `drivePrompts`. Reused here they would be worse than useless: the
  -- done-predicate is true on the very first poll, so a fight would report
  -- itself finished before its first turn opened and every save assertion
  -- after it would read an untouched party as a passing one.
  --
  -- So the three below read the mediated screen's own machine instead: its
  -- `mmoBattle` marker, its `phase` (setup/play/choose/move/item/... --
  -- src/MediatedBattle.lua), and `M.COMMANDS` = FIGHT / SWITCH / ITEM / RUN.
  -- They stay local rather than joining mmo_util for the same reason
  -- everything else here does; if the shared file ever grows a mediated-screen
  -- vocabulary, these are what it should be.

  -- The mod's screen anywhere on the stack, not merely on top: a box pushed
  -- over the fight for a frame must not read as the fight being over.
  local function medOnStack()
    for _, state in ipairs((game.stack and game.stack.states) or {}) do
      if state and state.mmoBattle == true then return state end
    end
    return nil
  end

  local function medTop()
    local top = H.top(game)
    if H.isMediatedBattle(top) then return top end
    return nil
  end

  -- Wait for this mod's screen to be the thing on the stack. The divert is
  -- synchronous inside StateStack:push, so this is a formality -- but a
  -- formality that names the failure when the row is off, the kind was
  -- refused, or _begin bailed.
  local function awaitDivert(what)
    return H.waitFor(game, function()
      return H.isMediatedBattle(H.top(game))
    end, 240, what or "the mod's battle screen to take the encounter")
  end

  -- The command grid really being what the player is looking at. "phase ==
  -- choose" and nothing weaker: the opening line holds the message box for its
  -- whole dwell, and a driver that taps an arrow into that lands every press
  -- behind it one step out of order.
  local function awaitCommandMenu(what)
    return H.waitSeconds(game, function()
      local top = medTop()
      return top ~= nil and top.phase == "choose"
    end, 60, what or "the solo command grid")
  end

  -- ------- what the arena is actually holding
  --
  -- The two halves of the picture a solo fight draws, read off the live screen
  -- rather than off a fixture, because both were wrong in a way only a real
  -- boot could show:
  --
  --   * **the player's own front pic.** `MediatedBattle:seatFront` hands the
  --     arena a *front* for both sides -- that is the whole difference between
  --     this theatre and the classic 160x144 stage, where the player's side is
  --     a back pic. When it fails it falls back to `slot.sprite`, which on our
  --     own seat *is* that back pic, so the failure draws a monster seen from
  --     behind and mirrored rather than an empty seat. Nothing but comparing
  --     the two images catches that: a nil check passes on the wrong pic.
  --   * **the figure on the foe edge.** `Battlefield.drawHuman` falls back to a
  --     dark placeholder rectangle when a human names no walk sheet, which is
  --     what a solo trainer fight drew for the whole battle.
  --
  -- Soft throughout: a probe that throws must not take the leg with it.
  local function arenaProbe(mine)
    local top = medTop()
    if not top then return nil end
    local out = {}
    pcall(function()
      if not (top.usesBattlefield and top:usesBattlefield()) then
        out.classic = true
        return
      end
      local index = mine and top:mySlot() or top:foeSlot()
      local slot = top.slots and top.slots[index]
      local seat = top.battlefieldSeat and top:battlefieldSeat(index, mine)
      out.front = seat and seat.front or nil
      out.slotSprite = slot and slot.sprite or nil
      local ctx = top.battlefieldCtx and top:battlefieldCtx() or nil
      out.foeHumans = ctx and ctx.foeHumans or nil
    end)
    return out
  end

  -- FIGHT / SWITCH / ITEM / RUN, then the bag row for `itemId`.
  --
  -- The grid's shape is asked for rather than assumed -- the battlefield band
  -- lays all four in one row, classic GB chrome and Gold keep the 2x2 -- which
  -- is the same rule mmo_util's own version follows and the same one that
  -- silently broke the co-op catch flow when it was assumed instead.
  local function throwItem(itemId)
    local top = medTop()
    if not (top and top.phase == "choose") then return false end
    local cols = 2
    if type(top.commandCols) == "function" then
      local ok, got = pcall(top.commandCols, top)
      if ok and tonumber(got) then cols = tonumber(got) end
    end
    if cols >= 4 then
      U.tap(game, "right"); U.wait(6)
      U.tap(game, "right"); U.wait(6)
    else
      U.tap(game, "down"); U.wait(6)
    end
    U.tap(game, "a"); U.wait(10)
    top = medTop()
    if not (top and top.phase == "item") then return false end
    local items = (type(top.usableItems) == "function") and top:usableItems() or {}
    local want = 1
    for i, row in ipairs(items) do
      if row.id == itemId then want = i break end
    end
    top.itemIndex = want
    U.tap(game, "a"); U.wait(20)
    return true
  end

  -- Mash the fight to its end, the way the co-op legs do: drivePrompts answers
  -- whatever box is up, and the extra tap walks the command grid (FIGHT ->
  -- move 1, which frontloadDamage made the strongest one).
  local function fightToEnd(seconds)
    return H.drivePrompts(game, function()
      return medOnStack() == nil
    end, seconds or 240, function()
      U.tap(game, "a")
    end)
  end

  local function backToOverworld(seconds)
    H.closeToOverworld(game)
    return H.waitSeconds(game, function() return H.inPlay(game) end,
                         seconds or 30, "the overworld to come back")
  end

  -- ------------------------------------------------------------------
  -- boot
  -- ------------------------------------------------------------------
  --
  -- `H.bootToPlay` again, now that it is safe to use.  This driver carried its
  -- own copy of the boot because `mmo_util`'s went through the engine's
  -- `U.newGame`, whose Gen 1 arm mashed A 400 times against an intro that
  -- reaches the overworld at tap 441 -- and then returned nothing, so a driver
  -- walked on and asserted against OakSpeech while reading a save it had
  -- seeded itself.  That is fixed upstream of here now: `H.newGame` waits for
  -- the overworld to actually be on top, on a budget with real headroom, and
  -- names the stack it is stuck on when it gives up.  `H.bootToPlay` routes
  -- through it, so the local copy has done its job and is gone -- one boot for
  -- every driver in the repo, which is the point of keeping it in `mmo_util`.
  local function bootToPlay()
    return H.bootToPlay(game) and H.inPlay(game)
  end

  local function stackNames()
    return H.stackNames(game)
  end

  local events = H.captureEvents({ "battle.started", "battle.ended" })

  local booted = bootToPlay()
  if not check(booted, "booted to a playable overworld") then
    log("shots in", SHOT_DIR)
    log("GAPS:" .. tostring(fail))
    log("SUMMARY", "pass=" .. pass, "fail=" .. fail)
    log("DONE")
    love.event.quit(1)
    return
  end
  if game.save and game.save.player then
    game.save.player.name = "SOLO"
  end
  local GEN = H.generation(game)
  log("generation =", tostring(GEN))
  log("stack after boot:", stackNames())

  local exports = H.requireMod(game, TAG)
  if not exports then
    log("stack:", stackNames())
    log("GAPS:1")
    log("SUMMARY", "pass=" .. pass, "fail=" .. (fail + 1))
    log("DONE")
    love.event.quit(1)
    return
  end
  local connected = type(exports.isConnected) == "function"
    and exports.isConnected() or false
  check(connected == false,
        "and nothing is connected -- this is the offline copy the row is for")

  freshParty()
  log("party:", table.concat(H.partySpecies(game), ","))

  -- ------------------------------------------------------------------
  -- 1. the row, through the mod manager's own row model
  -- ------------------------------------------------------------------
  --
  -- Not simulated keypresses. The manager's cursor walks a flat row list with
  -- category headers in it, and a driver that counted DOWNs to reach a row
  -- would report "SOLO BATTLES is missing" the first time a mod was installed
  -- beside this one -- a failure about the driver's arithmetic wearing the
  -- clothes of a failure about the feature. What is asserted instead is the
  -- model the options screen draws from and the callback its keypress runs:
  -- `ManagerState:buildOptionRows` (src/mods/ManagerState.lua) and, for the
  -- flip, the row's own `step()`. A row that is in there is a row the player
  -- can see; a `step()` that flips it is the flip a player performs.
  -- The manager, opened the way F10 opens it, and its own row model.
  local function openManager()
    local okScreens, Screens = pcall(require, "src.ui.Screens")
    if not (okScreens and Screens) then return nil end
    local okPush, pushed = pcall(Screens.push, game, "ManagerState")
    local mgr = (okPush and pushed) or nil
    if mgr == nil then
      local top = H.top(game)
      if top and top.screenId == "ManagerState" then mgr = top end
    end
    return mgr
  end

  local function closeManager(mgr)
    if mgr and H.top(game) == mgr then
      pcall(function() game.stack:pop() end)
      U.wait(6)
    end
    H.closeToOverworld(game)
  end

  local function schemaRows()
    return game.mods and game.mods.optionSchemas
      and game.mods.optionSchemas[MOD_ID]
  end

  -- The SOLO BATTLES row as the OPTIONS.. screen builds it.
  local function soloRowOf(mgr)
    local schema = schemaRows()
    local entry = mgr and mgr.byId and mgr.byId[MOD_ID] or nil
    if not (mgr and entry and type(schema) == "table"
            and type(mgr.buildOptionRows) == "function") then
      return nil, entry
    end
    local okRows, rows = pcall(mgr.buildOptionRows, mgr, entry, schema)
    if not (okRows and type(rows) == "table") then
      log("warn buildOptionRows failed:", tostring(rows))
      return nil, entry
    end
    local labels, soloRow = {}, nil
    for _, row in ipairs(rows) do
      labels[#labels + 1] = tostring(row.label)
      if row.id == OPTION_KEY then soloRow = row end
    end
    log("manager option rows:", table.concat(labels, ","))
    return soloRow, entry
  end

  -- What mod.options:get actually reads (Loader's per-mod option store).
  local function optionValue()
    local stored = game.mods and game.mods.modOptions
      and game.mods.modOptions[MOD_ID]
    return stored and stored[OPTION_KEY]
  end

  do
    local mgr = openManager()
    check(mgr ~= nil, "F10's mod manager opens (Screens.push ManagerState)")

    local schema = schemaRows()
    check(type(schema) == "table",
          "the mod published an options schema to the loader")

    -- The schema's own answer to "what does this default to", which is the
    -- answer a player with no options.lua at all would get.
    local declared = nil
    for _, row in ipairs(schema or {}) do
      if row.key == OPTION_KEY then declared = row end
    end
    check(declared ~= nil,
          ("the schema carries a %q row"):format(OPTION_KEY))
    check(declared ~= nil and declared.type == "toggle",
          "and it is a toggle, not a choice or a number",
          declared and tostring(declared.type))
    check(declared ~= nil and declared.default == false,
          "and it defaults to OFF (Config.SOLO_BATTLES_DEFAULT)",
          declared and tostring(declared.default))
    check(declared ~= nil and declared.label == OPTION_LABEL,
          ("and its label is %q"):format(OPTION_LABEL),
          declared and tostring(declared.label))

    local soloRow, entry = soloRowOf(mgr)
    check(entry ~= nil, "the manager lists rby_mmo among the installed mods")
    check(soloRow ~= nil,
          "the OPTIONS.. screen really draws a SOLO BATTLES row")
    if soloRow then
      check(soloRow.label == OPTION_LABEL,
            "the row reads " .. OPTION_LABEL, tostring(soloRow.label))
      local shown = soloRow.value and soloRow.value() or nil
      check(shown == "OFF",
            "and it reads OFF before anybody touches it", tostring(shown))
      shot("solo-manager-row")
    end
    closeManager(mgr)
    check(optionValue() ~= true,
          "and nothing has turned it on behind the player's back")
  end

  -- ------------------------------------------------------------------
  -- 2. default OFF is honoured
  -- ------------------------------------------------------------------
  --
  -- Run before anything is flipped, so what it proves is what it says: an
  -- untouched copy of this mod does not take the game's battles. The wrapper
  -- seeds the row OFF in options.lua rather than leaving the key absent, so
  -- this leg is the same leg on an identity a previous run left dirty.
  do
    check(optionValue() ~= true, "the row is off for the default-OFF leg")

    freshParty()
    local finished = nil
    local staged, species = stageWildOf({ "PIDGEY", "SENTRET", "RATTATA" }, 5,
      function(result) finished = result end)
    check(staged ~= nil, "staged a wild encounter with the row off",
          tostring(species))
    if staged then
      U.wait(20)
      local top = H.top(game)
      check(not H.isMediatedBattle(top),
            "with SOLO BATTLES off the mod's screen never appears")
      check(top == staged,
            "the engine's own battle is what the player is looking at")
      shot("solo-off-engine-battle")
      check(dropStaged(staged), "and it comes back off the stack cleanly")
      check(finished == nil,
            "nothing finished the engine's battle behind the player's back")
    end
    check(backToOverworld(), "back in the overworld after the OFF leg")
  end

  -- ------------------------------------------------------------------
  -- 3. flipping it on, through the row a player would press
  -- ------------------------------------------------------------------
  --
  -- Not a write into loader.modOptions. `ManagerState:buildOptionRows` gives
  -- each toggle a `step()` closure, and that closure is exactly what the
  -- options screen calls when the row is pressed -- it writes both
  -- save.options.modOptions and loader.modOptions and emits
  -- mod.options_changed, none of which a driver poking one table would do.
  --
  -- Mid-session and with no relaunch, which is the half of success criterion 1
  -- that a pre-seeded options.lua can never show: the very next encounter
  -- (leg 4) is the assertion that it took.
  do
    local mgr = openManager()
    local soloRow = soloRowOf(mgr)
    check(soloRow ~= nil, "reopened the manager on the SOLO BATTLES row")
    local flipped, shown = false, nil
    if soloRow then
      local okStep = pcall(soloRow.step, soloRow, 1)
      shown = soloRow.value and soloRow.value() or nil
      flipped = okStep and shown == "ON"
    end
    check(flipped, "the row's own step() turns it ON", tostring(shown))
    closeManager(mgr)
    check(optionValue() == true,
          "and it landed in the table mod.options:get reads",
          tostring(optionValue()))
  end

  -- ------------------------------------------------------------------
  -- 4. a solo wild fight, and the save afterwards
  -- ------------------------------------------------------------------
  do
    freshParty()
    local before = lead()
    local expBefore, ppBefore = expOf(before), ppOf(before)
    local hpBefore = tonumber(before and before.hp) or 0
    local partyBefore = H.partySpeciesCount(game)
    local startedBefore = events["battle.started"]

    local finished = nil
    local staged, species = stageWildOf({ "PIDGEY", "SENTRET", "RATTATA" }, 5,
      function(result) finished = result end)
    check(staged ~= nil, "staged a wild encounter with the row on",
          tostring(species))

    if staged then
      check(awaitDivert("the solo wild divert"),
            "the encounter diverts onto this mod's battle screen")
      check(H.onStack(game, staged),
            "and the engine's own battle is frozen underneath, not destroyed")
      do
        local top = H.top(game)
        log(("solo wild: id=%s mode=%s phase=%s"):format(
          tostring(top and top.battleId), tostring(top and top.mode),
          tostring(top and top.phase)))
        check(top and top.mode == "wild",
              "seated as a wild fight, so catching and running are legal",
              tostring(top and top.mode))
      end
      check(awaitCommandMenu("the solo wild command grid"),
            "the command grid opens on the mod's screen")
      shot("solo-wild-battle")

      do
        local arena = arenaProbe(true)
        if arena and arena.classic then
          skip("the wild arena probe", "this generation draws the classic stage")
        else
          log(("solo wild arena: front=%s back=%s same=%s foeHumans=%d"):format(
            tostring(arena and arena.front ~= nil),
            tostring(arena and arena.slotSprite ~= nil),
            tostring(arena and arena.front == arena.slotSprite),
            arena and arena.foeHumans and #arena.foeHumans or -1))
          check(arena ~= nil and arena.front ~= nil,
                "our own seat hands the arena a pic to draw")
          check(arena ~= nil and arena.slotSprite ~= nil
                  and arena.front ~= arena.slotSprite,
                "...and it is the FRONT pic co-op draws, not the classic "
                .. "stage's back pic")
          check(arena ~= nil and arena.foeHumans ~= nil
                  and #arena.foeHumans == 0,
                "a wild fight stands nobody on the foe edge")
        end
      end

      local over, seen = fightToEnd(240)
      check(over, "the solo wild fight runs to an end", tostring(seen))
      check(backToOverworld(), "and the overworld is restored")
      shot("solo-wild-after")

      -- The save, which is the whole reason this leg is out here.
      local after = lead()
      check(finished == "win",
            "the engine's own battle was told it was a win", tostring(finished))
      check(not H.onStack(game, staged),
            "and it is off the stack -- no rematch waiting underneath")
      check(expOf(after) > expBefore,
            "exp landed on the real save monster",
            ("%d -> %d"):format(expBefore, expOf(after)))
      check(ppOf(after) < ppBefore,
            "and the PP it spent is on the save too",
            ("%d -> %d"):format(ppBefore, ppOf(after)))
      check((tonumber(after and after.hp) or 0) <= hpBefore
            and (tonumber(after and after.hp) or 0) > 0,
            "HP reflects the fight and the winner is standing",
            ("%d -> %s"):format(hpBefore, tostring(after and after.hp)))
      check(H.partySpeciesCount(game) == partyBefore,
            "a won wild fight adds nobody to the party")
      log("engine battle.started since the leg opened:",
          tostring(events["battle.started"] - startedBefore))
    end
  end

  -- ------------------------------------------------------------------
  -- 5. a refused kind stays vanilla
  -- ------------------------------------------------------------------
  do
    freshParty()
    local staged, how = stageRefusedWild(GEN == 2 and "SENTRET" or "GASTLY", 5)
    if staged == nil then
      skip("the refused-kind leg", tostring(how))
    else
      log("refused kind staged as:", tostring(how))
      U.wait(20)
      local top = H.top(game)
      check(not H.isMediatedBattle(top),
            "a Config.SOLO_REFUSED battle is handed straight back to the engine")
      check(top == staged,
            "the engine's own battle is what the player is looking at")
      shot("solo-refused-engine-battle")
      check(dropStaged(staged), "and it comes back off the stack cleanly")
      check(backToOverworld(), "back in the overworld after the refused leg")
    end
  end

  -- ------------------------------------------------------------------
  -- 6. a solo trainer fight, and the payout
  -- ------------------------------------------------------------------
  do
    freshParty()
    local class, total = H.coopTrainer(game.data)
    check(class ~= nil, "the dataset has a trainer with two POKeMON",
          tostring(class) .. " total level " .. tostring(total))
    if class then
      local moneyBefore = moneyOf()
      local expBefore = expOf(lead())
      local finished = nil
      local record = function(result) finished = result end
      local staged = likeWorldStartBattle(H.stageTrainer(game, class, record),
                                          record)
      check(staged ~= nil, "staged a trainer battle", tostring(class))

      if staged then
        check(awaitDivert("the solo trainer divert"),
              "the trainer diverts onto this mod's battle screen")
        check(H.onStack(game, staged),
              "and the engine's trainer battle is frozen underneath")
        do
          local top = H.top(game)
          log(("solo trainer: id=%s mode=%s phase=%s"):format(
            tostring(top and top.battleId), tostring(top and top.mode),
            tostring(top and top.phase)))
          check(top and top.mode == "coop_npc",
                "seated as coop_npc, so a ball cannot catch a trainer's mon",
                tostring(top and top.mode))
        end
        check(awaitCommandMenu("the solo trainer command grid"),
              "the command grid opens on the mod's screen")
        shot("solo-trainer-battle")

        do
          local arena = arenaProbe(true)
          if arena and arena.classic then
            skip("the trainer arena probe",
                 "this generation draws the classic stage")
          else
            local who = arena and arena.foeHumans and arena.foeHumans[1] or nil
            log(("solo trainer arena: front=%s same=%s foe=%s sheet=%s"):format(
              tostring(arena and arena.front ~= nil),
              tostring(arena and arena.front == arena.slotSprite),
              tostring(who and who.name), tostring(who and who.spriteId)))
            check(arena ~= nil and arena.front ~= nil
                    and arena.front ~= arena.slotSprite,
                  "our own seat draws its front pic here too")
            check(who ~= nil,
                  "the trainer is standing on the foe edge")
            check(who ~= nil and type(who.spriteId) == "string"
                    and who.spriteId ~= "",
                  "...with a real walk sheet, not the placeholder silhouette",
                  tostring(who and who.spriteId))
            check(who ~= nil and type(who.name) == "string"
                    and who.name ~= "" and who.name ~= "FRIEND",
                  "...named as the trainer and not as an absent peer",
                  tostring(who and who.name))
          end
        end

        local over, seen = fightToEnd(360)
        check(over, "the solo trainer fight runs to an end", tostring(seen))
        check(backToOverworld(), "and the overworld is restored")
        shot("solo-trainer-after")

        check(finished == "win",
              "the engine's trainer battle got its result back -- which is the "
              .. "script that was waiting, resumed", tostring(finished))
        check(not H.onStack(game, staged),
              "and it is off the stack, so the trainer is not refought")
        check(moneyOf() > moneyBefore,
              "prize money was paid onto the save",
              ("%d -> %d"):format(moneyBefore, moneyOf()))
        check(expOf(lead()) > expBefore,
              "and the trainer's mons paid exp",
              ("%d -> %d"):format(expBefore, expOf(lead())))

        -- Walking is the honest test of "the world is the player's again":
        -- StateStack only updates its top, so a leaked screen freezes the
        -- overworld and no direction moves anybody. Four directions, because
        -- wherever the last warp left us at least one of them is open.
        local from = H.playerCell(game)
        local moved = false
        for _, dir in ipairs({ "down", "up", "left", "right" }) do
          if moved then break end
          U.hold(game, dir, 18)
          U.wait(10)
          local now = H.playerCell(game)
          moved = from ~= nil and now ~= nil
            and (now.x ~= from.x or now.y ~= from.y or now.mapId ~= from.mapId)
        end
        check(moved, "and the player can walk again",
              from and (tostring(from.mapId) .. " " .. tostring(from.x)
                        .. "," .. tostring(from.y)) or "?")
      end
    end
  end

  -- ------------------------------------------------------------------
  -- 7. a real sighted trainer, for the defeated flag
  -- ------------------------------------------------------------------
  --
  -- stageTrainer above pushes a battle nobody walked into, so it has no npcId
  -- and there is no flag for the world to set -- what it can prove is the
  -- payout and the handoff, and it does. The defeated flag needs a trainer
  -- who exists in the world, which means walking into a real sight line.
  --
  -- mmo_util's sight helpers read Gen 1's map objects (`movement == "STAY"`
  -- plus a `range` cone); Gold spells NPC movement as numeric SPRITEMOVEDATA
  -- and has no such record, so `sightTrainerOn` answers nil there and this leg
  -- skips rather than failing for a shape it was never written against.
  do
    local SIGHT_MAP = "ROUTE_3"
    local sightObj = H.sightTrainerOn(game.data, SIGHT_MAP)
    if sightObj == nil then
      skip("the sighted-trainer leg",
           ("no Gen 1-shaped sight trainer on %s (generation %d)")
             :format(SIGHT_MAP, GEN))
    else
      freshParty()
      local npcId = H.sightNpcId(SIGHT_MAP, sightObj)
      log("sight trainer:", tostring(sightObj.name), "npcId", tostring(npcId),
          "class", tostring(sightObj.trainerClass))
      local defeatedBefore = game.save and game.save.defeatedTrainers
        and game.save.defeatedTrainers[npcId] or nil
      check(defeatedBefore ~= true, "and it has not been beaten yet")

      check(H.warpToSightLine(game, SIGHT_MAP, sightObj,
              { dist = 2, behind = 0, side = 1 }) ~= nil,
            "warped beside the trainer's sight line")
      check(H.awaitOnMap(game, SIGHT_MAP, 90), "arrived on " .. SIGHT_MAP)

      -- Latched from inside the walk: the divert takes the engine's battle
      -- over the frame it is pushed, and after the fight the ritual unwinds it
      -- -- so the window in which the stack names it is the fight itself.
      local staged, finished = nil, nil
      local function catchStaged()
        if staged then return staged end
        staged = H.captureStagedTrainer(game)
        if staged then
          H.wrapBattleFinish(staged, function(result) finished = result end)
          H.softenTopTrainer(game)
        end
        return staged
      end

      check(H.walkIntoTrainerSight(game, sightObj, { dist = 2 }),
            "walked into the trainer's sight")
      local diverted = H.waitFor(game, function()
        catchStaged()
        H.softenTopTrainer(game)
        if H.isMediatedBattle(H.top(game)) then return true end
        local top = H.top(game)
        -- The pre-battle text is a plain box; advance it, never a menu row.
        if top ~= nil and top.items == nil and not H.isMediatedBattle(top) then
          U.tap(game, "a")
        end
        return false
      end, 60 * 10, "the sighted trainer to divert onto the mod's screen")
      check(diverted,
            "a trainer walked into for real diverts onto this mod's screen")
      catchStaged()
      check(staged ~= nil,
            "and the engine's own trainer battle was caught underneath it")
      shot("solo-sight-trainer")

      if diverted then
        check(awaitCommandMenu("the sighted-trainer command grid"),
              "the command grid opens")
        local over, seen = fightToEnd(360)
        check(over, "the sighted trainer fight runs to an end", tostring(seen))
        check(backToOverworld(), "and the overworld is restored")
        shot("solo-sight-after")
        check(finished == "win",
              "the world's own onFinish ran -- the script resumed",
              tostring(finished))
        local defeated = game.save and game.save.defeatedTrainers
          and npcId and game.save.defeatedTrainers[npcId] == true
        check(defeated == true,
              "and defeatedTrainers marks the sighted trainer beaten",
              tostring(npcId))
        -- No rematch: the buried battle must be gone, not merely off the top.
        local buried = false
        for _, state in ipairs((game.stack and game.stack.states) or {}) do
          if state and state.kind == "trainer" then buried = true end
        end
        check(not buried,
              "no trainer BattleState left buried under the overworld")
      end
    end
  end

  -- ------------------------------------------------------------------
  -- 8. a catch, exactly once
  -- ------------------------------------------------------------------
  --
  -- Last, so the party growth it asserts is unambiguous: every earlier leg
  -- reseeds a one-member party, and this one deliberately does not run before
  -- anything that would.
  do
    freshParty()
    check(H.giveItem(game, "MASTER_BALL", 1), "seeded a MASTER_BALL")
    local ballsBefore = (game.save.inventory
      and game.save.inventory.MASTER_BALL) or 0
    local partyBefore = H.partySpeciesCount(game)

    local finished = nil
    local staged, species = stageWildOf({ "RATTATA", "SENTRET", "PIDGEY" }, 5,
      function(result) finished = result end)
    check(staged ~= nil, "staged a wild encounter to catch", tostring(species))
    local speciesBefore = species and H.partySpeciesCount(game, species) or 0

    if staged then
      check(awaitDivert("the solo catch divert"),
            "the encounter diverts onto this mod's battle screen")
      check(awaitCommandMenu("the command grid before MASTER_BALL"),
            "the command grid opens")
      check(throwItem("MASTER_BALL"),
            "filed MASTER_BALL from the ITEM menu")
      local over, seen = fightToEnd(240)
      check(over, "the catch runs the fight to an end", tostring(seen))
      check(backToOverworld(), "and the overworld is restored")
      shot("solo-catch-after")

      local ballsAfter = (game.save.inventory
        and game.save.inventory.MASTER_BALL) or 0
      check(ballsAfter < ballsBefore, "the ball was spent",
            ("%d -> %d"):format(ballsBefore, ballsAfter))
      check(H.partySpeciesCount(game) == partyBefore + 1,
            "the party grew by exactly one",
            ("%d -> %d"):format(partyBefore, H.partySpeciesCount(game)))
      check(species ~= nil
            and H.partySpeciesCount(game, species) == speciesBefore + 1,
            ("the caught %s is in the party exactly once"):format(
              tostring(species)),
            ("%d -> %s"):format(speciesBefore,
              tostring(species and H.partySpeciesCount(game, species))))
      check(finished == "caught",
            "and the engine's battle was told 'caught', not 'win' -- a catch "
            .. "must not read back as a trainer beaten", tostring(finished))
    end
  end

  -- ------------------------------------------------------------------

  log("shots in", SHOT_DIR)
  log("GAPS:" .. tostring(fail))
  log("SUMMARY", "pass=" .. pass, "fail=" .. fail)
  log("DONE")
  love.event.quit(fail > 0 and 1 or 0)
end
