-- The three tutorials, replayed by SOLO BATTLES: the `tutorial` kind of the
-- Gen 3 solo kind registry (contract C2 of docs/plans/gen3-solo-remaining-
-- fights.md; the research in §1.5 of docs/plans/gen3-solo-remaining-fights-
-- research.md, the referee's tutorial mode as built in its §3.1, this file's
-- remainder in §3.4 K-TUT).
--
--   oldMan    FireRed / LeafGreen, Viridian City (pret pokefirered
--             battle_setup.c:301 StartOldManTutorialBattle, BATTLE_TYPE_OLD_MAN_
--             TUTORIAL): the old man fields nothing, opens his bag and throws
--             his one POKe BALL at a WEEDLE (battle_controller_oak_old_man.c:278
--             SimulateInputChooseAction, item_menu.c:2106 Task_Bag_OldManTutorial).
--   wally     Emerald, Route 102 (pokeemerald battle_setup.c:480
--             StartWallyTutorialBattle, BATTLE_TYPE_WALLY_TUTORIAL): WALLY's
--             ZIGZAGOON (the script's LoadWallyZigzagoon, already in
--             session.party when the fight starts) TACKLEs twice, then the
--             throw turn, then the ball (battle_controller_wally.c:188
--             WallyHandleActions).
--   pokedude  FireRed / LeafGreen TEACHY TV (battle_controller_pokedude.c,
--             teachy_tv.c:1172 TeachyTvPrepBattle): the POKe DUDE's own party
--             against a demo foe, both sides played from the cart's input
--             scripts (sInputScripts_ChooseAction_* / _ChooseMove_*), his
--             voice-over at the points his text scripts name
--             (sPokedudeTextScripts_*).  Reaches solo through src/CoopField.lua's
--             TEACHY TV wrap (divertPokedude: the music, the transition, the
--             TEACHY TV off the screen, his bag and party in -- then
--             pokedudeStand3's `pokedudeScript`, `playerParty`, `teachyOpts`,
--             and a `done` that gives all of it back and answers the TEACHY
--             TV's onDone with pret's code).  Holding B quits it (DREW).
--
-- The referee plays the rules (BattleSim3 Turn.create `tutorial`: a forced
-- catch that gives nothing, `given = false`; no crits under the old man /
-- WALLY; the POKe DUDE's sure hits, voided crits, no disobedience and gated
-- side-b effects; side-entry `noBattler` for the old man; an NPC-driven side
-- a; WALLY's `wallyThrow` action).  The screen plays the presentation
-- (MediatedBattle's `tutorial` screen option: the back pic, the prompt, the
-- cursor walked at the cart's pace by `autoplay3`, the voice-over box
-- `sayTutorial3`, WALLY's recall on the referee's `wallyThrow` event, the
-- POKe DUDE's B fade; it takes no player input).  What is this file's:
--
--   * seating -- side a as the cart fields it (the old man alone; WALLY's and
--     the POKe DUDE's party under their names), each with the tutorial's own
--     bag; the referee's `tutorial` / `catch = "forced"`; the screen told
--     which tutorial, whose name, which back pic, which prompt;
--   * the driver -- side a is answered by this file, not the player: the
--     core asks an NPC answerer every frame its seat owes (src/SoloBattle.lua
--     M:_answerNpcs3: `false` is "waiting for its beat"), and the answer here
--     is to hand the screen the cart's scripted input once its menu is up
--     (`autoplay3`), which files it through its own `sendChoice`; the POKe
--     DUDE's foe is answered from the opponent's column of the same scripts;
--   * the borrowed bag -- BackUpPlayerBag / PrepareBagForWallyTutorial
--     around the old man's and WALLY's bags (the player's own bag is never
--     touched); the POKe DUDE's party and bag are the TEACHY TV door's
--     (src/CoopField.lua), and `takes` holds the door to it;
--   * the POKe DUDE's quit -- B held ends his demonstration as DREW
--     (M.quit3, SoloBattle M:quit3);
--   * the word -- the POKe DUDE's catching demo answers "catch" (the engine's
--     TEACHY TV finish compares the result to "catch",
--     battle/pokedude.lua finish_battle); the old man and WALLY take the
--     core's "caught" (pret B_OUTCOME_CAUGHT either way).
--
-- What the core already does for a tutorial and needs nothing here: the
-- forced catch's `given = false` is the screen's (no catch granted); the TV
-- and battle.ended read `tutorial3` and the engine keys (SoloBattle.
-- engineFlags3: `oldManTutorial`, `pokedude`; engineKinds3: `tutorialKind =
-- "wally"` -> the TV's wallyTutorial exclusion); WALLY's Pokérus pass runs over
-- WALLY's ZIGZAGOON, which is what gPlayerParty holds at pret
-- ReturnFromBattleToOverworld; the FireRed / LeafGreen quest log leaves out
-- the old man and the POKe DUDE (pret quest_log_battle.c:14
-- TrySetQuestLogBattleEvent: OLD_MAN_TUTORIAL | POKEDUDE, read off the same
-- keys); a demonstration runs no map resume scripts (ctx.noFieldReturn, set
-- here: the TEACHY TV is where it goes back to).
--
-- Solo only: co-op refuses every tutorial (Config.COOP_REFUSED_GEN3), so
-- nothing here is ever on a hub's wire.
--
-- Loaded lazily by src/SoloBattle.lua (KIND_FILES3: tutorial -> "Solo3/Tutorial").

local need, mod = ...
local Gen3 = need("Gen3")
local Borrow3 = need("Borrow3")

local M = {}

local floor = math.floor

local function int(v, fallback)
  local n = tonumber(v)
  if not n or n ~= n then return fallback end
  return floor(n)
end

local function try(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, value = pcall(fn, ...)
  if ok then return value end
  return nil
end

local function set(v) return v ~= nil and v ~= false end

-- Siblings reached when a fight asks, never at load (src/Solo3/Safari.lua's
-- reason: this file is read by SoloBattle.kind3 long after the graph that
-- needs it has loaded).
local function sibling(name)
  if type(need) ~= "function" then return nil end
  local ok, value = pcall(need, name)
  if ok and type(value) == "table" then return value end
  return nil
end

-- Said once a fight where the core can say it (its per-fight `warn`), else
-- through the facade's log.
local function warn(ctx, key, fmt, ...)
  local solo = type(ctx) == "table" and ctx.solo or nil
  if type(solo) == "table" and type(solo.warn) == "function" then
    return solo:warn("tutorial3:" .. key, fmt, ...)
  end
  if type(mod) == "table" and type(mod.log) == "table" and type(mod.log.warn) == "function" then
    mod.log:warn(fmt, ...)
  end
end

-- src/SoloBattle.lua's PLAYER_SEAT / FOE_SEAT: side a's first entry and side
-- b's.
M.PLAYER_SEAT = "solo_player"
M.FOE_SEAT = "solo_foe"

-- The three tutorials (contract C1's `tutorial3`), and the spellings the
-- engine uses for them (battle/kinds.lua: FireRed's profile says "oldman").
M.TUTORIALS = { oldMan = true, wally = true, pokedude = true }
local SPELLINGS = { oldMan = "oldMan", oldman = "oldMan", wally = "wally", pokedude = "pokedude" }

-- pret include/constants/items.h -- the same numbers on all three carts.
M.ITEM_POKE_BALL = 4
M.ITEM_POTION = 13
M.ITEM_ANTIDOTE = 14

-- The trainer on our edge, as the cart's "<X> used <item>!" names him (the
-- subject of pret's sText_OldManUsedItem, "The old man used\n{B_LAST_ITEM}!",
-- pokefirered battle_message.c:463; sText_WallyUsedItem, "WALLY used\n...",
-- pokeemerald battle_message.c:462; sText_PokedudeUsedItem, "The POKé DUDE
-- used\n...", pokefirered :464) -- read out of the player's text pack, these
-- words when it cannot say them.
M.USED_ITEM = {
  oldMan = "STRINGID_OLDMANUSEDITEM", wally = "STRINGID_WALLYUSEDITEM",
  pokedude = "STRINGID_POKEDUDEUSED",
}
M.NAMES = { oldMan = "The old man", wally = "WALLY", pokedude = "The POKé DUDE" }

-- The action prompt each controller prints (pret OakOldManHandleChooseAction
-- gText_WhatWillOldManDo, pokefirered battle_message.c:1280; WallyHandle
-- ChooseAction gText_WhatWillWallyDo, pokeemerald battle_message.c:1273;
-- PokedudeHandleChooseAction gText_WhatWillPkmnDo), by text key: the screen
-- reads it out of the player's cart.
M.PROMPTS = {
  oldMan = "gText_WhatWillOldManDo", wally = "gText_WhatWillWallyDo",
  pokedude = "gText_WhatWillPkmnDo",
}

-- The back pic standing where the player's would, as the screen option takes
-- it (MediatedBattle `tutorial.backPic`): the old man's and the POKe DUDE's by
-- their pret names (pokefirered include/constants/trainers.h:175-176
-- TRAINER_BACK_PIC_POKEDUDE / _OLD_MAN; the engine's intro_seq.lua and
-- Pokedude.BACK_PIC draw the same two), WALLY's by the engine's battle-profile
-- key (battle/init.lua:749 backPicOverride = backPics.wally; pokeemerald
-- battle_controller_wally.c:1035).
M.BACK_PICS = {
  oldMan = "TRAINER_BACK_PIC_OLD_MAN", wally = "wally", pokedude = "TRAINER_BACK_PIC_POKEDUDE",
}

-- The bags the tutorials open: InitOldManBag (pokefirered item_menu.c:2098)
-- and DoWallyTutorialBagMenu (pokeemerald item_menu.c) each add a POTION and
-- one POKé BALL to a bag emptied for them.  The POKe DUDE's is the engine's
-- own copy of InitPokedudeBag's (TeachyTv.POKEDUDE_BAG, pokefirered
-- item_menu.c:2162), else the same list here.
M.BAGS = {
  oldMan = { { id = 13, count = 1 }, { id = 4, count = 1 } },
  wally = { { id = 13, count = 1 }, { id = 4, count = 1 } },
}
M.POKEDUDE_BAG = {
  { id = 13, count = 1 }, { id = 14, count = 1 }, { id = 4, count = 5 },
  { id = 3, count = 1 }, { id = 8, count = 1 },
}

-- The pockets each cart empties for its tutorial bag and puts back after:
-- BackUpPlayerBag (pokefirered item_menu.c:2061: Items, Key Items, POKé
-- BALLS) and PrepareBagForWallyTutorial (pokeemerald item_menu.c:2283: Items
-- and POKé BALLS).  The POKe DUDE's is the TEACHY TV door's (the engine's
-- own TeachyTv.initPokedudeBag / restorePlayerBag).
M.BAG_POCKETS = {
  oldMan = { "ITEMS", "KEY_ITEMS", "POKE_BALLS" },
  wally = { "ITEMS", "POKE_BALLS" },
}

-- The foe's send-out marks no dex "seen" in the old man's and the POKe
-- DUDE's battles (pokefirered battle_main.c:2605 / :2624 / :2780 and
-- battle_script_commands.c:4522: OLD_MAN_TUTORIAL | POKEDUDE among the
-- exclusions); Emerald has no such exclusion for WALLY's RALTS (pokeemerald
-- battle_main.c:3442).
M.NO_DEX_SEEN = { oldMan = true, pokedude = true }

-- ------------------------------------------------------------------
-- which tutorial, and its words
-- ------------------------------------------------------------------

-- The tutorial this fight is: the stand's (src/CoopField.lua classify3), else
-- the engine keys on the opts or the foe (`pokedude`, `oldManTutorial`,
-- `tutorialKind` / `tutorial`, a `kinds.tutorial`).  nil for none.
function M.which3(ctx)
  ctx = type(ctx) == "table" and ctx or {}
  local named = SPELLINGS[ctx.tutorial3]
  if named then return named end
  for _, key in ipairs({ "opts", "foe" }) do
    local place = ctx[key]
    if type(place) == "table" then
      if set(place.pokedude) then return "pokedude" end
      if set(place.oldManTutorial) then return "oldMan" end
      local k = SPELLINGS[place.tutorialKind] or SPELLINGS[place.tutorial]
        or (type(place.kinds) == "table" and SPELLINGS[place.kinds.tutorial]) or nil
      if k then return k end
    end
  end
  return nil
end

-- A sentinel the text pack keeps as it is (letters only), standing in for
-- the item so the subject can be read off the line.
local ITEM_SENTINEL = "RBYMMOITEMSENTINEL"

-- The trainer's name for `which`: the subject of the cart's own "<X> used
-- <item>!" line (M.USED_ITEM), else M.NAMES.  The referee words every item
-- line "<name> used <item>!", so its line is the cart's.
function M.seatName3(which)
  local id = M.USED_ITEM[which]
  local text = id and Gen3.battleText(id, { lastItem = ITEM_SENTINEL }) or nil
  if type(text) == "string" then
    local head = text:match("^(.-)" .. ITEM_SENTINEL)
    if head then
      head = head:gsub("%s+", " ")
      local subject = head:match("^%s*(.-)%s+used%s*$")
      if subject and subject ~= "" then return subject end
    end
  end
  return M.NAMES[which]
end

-- An item's name in the referee's alphabet, the screen's own reading of it
-- (Sheet3.bag); nil leaves the referee's default.
local function itemName(id)
  local Sheet3 = sibling("Sheet3")
  local raw = Gen3.itemName(id)
  if type(raw) ~= "string" or raw == "" then return nil end
  local name = Sheet3 and try(Sheet3.wireName, raw, "move") or raw
  if type(name) ~= "string" or name == "" then return nil end
  return name
end

-- A battle item the referee knows (its §4 bag table, Sheet3.bagEffect); a
-- key item (the TEACHY TV, the TM CASE) is not on a battle bag.
local function battleItem(id)
  local Sheet3 = sibling("Sheet3")
  if not (Sheet3 and type(Sheet3.bagEffect) == "function") then return true end
  return try(Sheet3.bagEffect, id) ~= nil
end

-- The engine's TEACHY TV module and its POKe DUDE (battle/pokedude.lua).
local function teachyTv() return Gen3.engine("src.core.game3.teachy_tv") end
local function pokedudeModule() return Gen3.engine("src.core.game3.battle.pokedude") end

-- The tutorial's bag as the referee and the screen take it: { id, count,
-- name } per battle item, in the cart's order.
function M.bag3(which)
  local rows = M.BAGS[which]
  if which == "pokedude" then
    local TeachyTv = teachyTv()
    local own = TeachyTv and type(TeachyTv.POKEDUDE_BAG) == "table" and TeachyTv.POKEDUDE_BAG or nil
    if own then
      rows = {}
      for _, e in ipairs(own) do
        rows[#rows + 1] = { id = int(e.id, 0), count = int(e.qty or e.count, 1) }
      end
    else
      rows = M.POKEDUDE_BAG
    end
  end
  local out = {}
  for _, e in ipairs(rows or {}) do
    if e.id > 0 and e.count > 0 and battleItem(e.id) then
      out[#out + 1] = { id = e.id, count = e.count, name = itemName(e.id) }
    end
  end
  return out
end

local function copyBag(entries)
  local out = {}
  for i, e in ipairs(entries or {}) do out[i] = { id = e.id, count = e.count, name = e.name } end
  return out
end

-- ------------------------------------------------------------------
-- the POKe DUDE's scripts (pokefirered battle_controller_pokedude.c)
-- ------------------------------------------------------------------

-- pokefirered include/teachy_tv.h: the four battle demonstrations.
M.TTVSCR = { BATTLE = 0, STATUS = 1, MATCHUPS = 2, CATCHING = 3 }
-- The battler ids the scripts' columns are read by (gActiveBattler in a
-- single: the player's 0, the opponent's 1).
M.PD_PLAYER, M.PD_OPPONENT = 0, 1

local function row(player, opponent)
  return { cursor = { [0] = player, [1] = opponent } }
end

-- sInputScripts_ChooseAction_Battle / _Status / _Matchups / _Catching
-- (battle_controller_pokedude.c:2002-2060), laid end to end as the cart lays
-- them: PokedudeSimulateInputChooseAction (:2429) reads row action_idx of its
-- demonstration's table and steps on, starting over only where the next row
-- says 4 -- and only the BATTLE table has such a row, so the STATUS script
-- runs on into the MATCHUPS rows, and those into the CATCHING rows (quirk
-- kept: the cart reads the next table's bytes).  Cursor 0 FIGHT, 1 BAG, 2
-- POKéMON, 3 RUN.  Each row's delay (64 frames for the player, none for the
-- opponent) is the screen's pace (MediatedBattle TUTORIAL_PACE3), not this
-- file's.
M.PD_ACTION_ROWS = {
  row(0, 0), row(4, 4),                -- BATTLE
  row(0, 0), row(1, 0), row(0, 0),     -- STATUS
  row(0, 0), row(2, 0), row(0, 0),     -- MATCHUPS
  row(0, 0), row(0, 0), row(1, 0),     -- CATCHING
}
M.PD_ACTION_BASE = { [0] = 0, [1] = 2, [2] = 5, [3] = 8 }
-- sInputScripts_ChooseMove_* (:2070-2136): the move slot each side picks,
-- each table closed by 255 (start over).
M.PD_MOVE_ROWS = {
  [0] = { row(2, 2), row(255, 255) },
  [1] = { row(2, 2), row(2, 0), row(2, 0), row(255, 255) },
  [2] = { row(2, 0), row(0, 0), row(0, 0), row(255, 255) },
  [3] = { row(0, 2), row(2, 2), row(255, 255) },
}
-- The item each demonstration's bag picks: OpenBagAndChooseItem (:353) opens
-- the CATCHING demonstration's bag on Task_Bag_TeachyTvCatching (POKé BALL,
-- item_menu.c:2296) and every other one's on Task_Bag_TeachyTvStatus
-- (ANTIDOTE, item_menu.c:2337), used on the party menu's first row -- the
-- battler out (Task_PartyMenuFromBag_PokedudeStep, party_menu.c:2080).
M.PD_BAG_ITEM = { [3] = 4 }
M.PD_BAG_ITEM_DEFAULT = 14

-- A demonstration's script state: per side, the two row counters
-- (gPokedudeBattlerStates[battler]->action_idx / move_idx), and the text
-- script's position (gBattleStruct->pdMessageNo).
function M.pdNewState3(script)
  return {
    script = int(script, 0),
    messageNo = 0,
    sides = { [0] = { actionIdx = 0, moveIdx = 0 }, [1] = { actionIdx = 0, moveIdx = 0 } },
  }
end

local function actionRow(pd, idx)
  local base = M.PD_ACTION_BASE[pd.script]
  if base == nil then return nil end
  return M.PD_ACTION_ROWS[base + idx + 1]
end

local function moveRow(pd, idx)
  local rows = M.PD_MOVE_ROWS[pd.script]
  return rows and rows[idx + 1] or nil
end

-- The action `side` files this turn (PokedudeSimulateInputChooseAction:
-- emit the row's cursor, step on, start over at a 4).  Past the last row the
-- cart reads whatever follows its tables (and the engine's own port of it
-- indexes nothing); FIGHT, which keeps the demonstration going.
function M.pdTakeAction3(pd, side)
  local s = pd.sides[side]
  local r = actionRow(pd, s.actionIdx)
  if not r then return 0 end
  s.actionIdx = s.actionIdx + 1
  local nxt = actionRow(pd, s.actionIdx)
  if nxt and nxt.cursor[side] == 4 then s.actionIdx = 0 end
  local cursor = r.cursor[side]
  if cursor == nil or cursor > 3 then return 0 end
  return cursor
end

-- The move slot (0-based) `side` picks (PokedudeSimulateInputChooseMove,
-- :2477: emit the row's cursor, step on, start over at a 255).
function M.pdTakeMove3(pd, side)
  local s = pd.sides[side]
  local r = moveRow(pd, s.moveIdx)
  if not r then return 0 end
  s.moveIdx = s.moveIdx + 1
  local nxt = moveRow(pd, s.moveIdx)
  if not nxt or nxt.cursor[side] == 255 then s.moveIdx = 0 end
  local slot = r.cursor[side]
  if slot == nil or slot > 3 then return 0 end
  return slot
end

-- HandlePokedudeVoiceoverEtc (:2508), for one controller command reaching
-- `side`'s controller: while the text script's next header names this
-- command (and, for a PRINTSTRING, this string), step past it; a header with
-- a callback is a voice-over, and the command is checked against the header
-- after it again once that box closes (PokedudeBufferRunCommand re-runs the
-- command); one without (NULL) is passed over and lets the command through.
-- `headers` is the engine's Pokedude.TEXT_SCRIPTS[script] ({ cmd, side,
-- stringId, kind }).  -> the voice-overs due, { index0, kind } each (index0
-- the line in the demonstration's sPokedudeTexts_* table).
function M.pdEvent3(pd, headers, cmd, side, stringId)
  local out = {}
  if type(headers) ~= "table" then return out end
  while true do
    local entry = headers[pd.messageNo + 1]
    if type(entry) ~= "table" or entry.cmd ~= cmd or entry.side ~= side then break end
    if cmd == "printstring" and entry.stringId ~= stringId then break end
    local index0 = pd.messageNo
    pd.messageNo = pd.messageNo + 1
    if not entry.kind then break end
    out[#out + 1] = { index0 = index0, kind = entry.kind }
  end
  return out
end

-- One voice-over line in the cart's words (the engine's Pokedude.textFor:
-- the demonstration's sPokedudeTexts_* line through the battle text pack).
-- nil when the pack cannot say it.
local function pdLine(ctx, index0)
  local PD = pokedudeModule()
  local key = PD and try(PD.textKey, ctx.tut3.pd.script, index0) or nil
  if type(key) ~= "string" then return nil end
  local session = ctx.session or Gen3.session()
  return Gen3.battleText(key, { playerName = type(session) == "table" and session.name or nil })
end

-- Say the voice-overs `due` on the screen, in order.  The STATUS demo's
-- healthbox line lights the player's box over the darkened field
-- (PokedudeAction_PrintMessageWithHealthboxPals, :2586:
-- DoLoadHealthboxPalsForLevelUp on B_POSITION_PLAYER_LEFT).
local function sayAll(ctx, due)
  local fight = ctx.fight
  for _, e in ipairs(due or {}) do
    local text = e.text or pdLine(ctx, e.index0)
    if text and fight and type(fight.sayTutorial3) == "function" then
      local opts = (e.kind == "healthbox") and { lit = "ally" } or nil
      local ok, err = pcall(fight.sayTutorial3, fight, text, opts)
      if not ok then
        warn(ctx, "say", "the POKe DUDE's voice-over could not be shown (%s); the demonstration "
          .. "goes on without it -- report it with the TEACHY TV program you watched", tostring(err))
      end
    elseif text and fight and type(fight.say) == "function" then
      -- A screen without the voice-over box still prints the line.
      pcall(fight.say, fight, text)
    end
  end
end

-- ------------------------------------------------------------------
-- the borrowed bag
-- ------------------------------------------------------------------

-- The POKe DUDE's party and bag are the TEACHY TV door's (src/CoopField.lua
-- divertPokedude: SavePlayerParty / InitPokedudePartyAndOpponent and
-- InitPokedudeBag before the fight is offered, LoadPlayerParty and
-- RestorePlayerBag in the stand's `done` and its giveBack3).  The old man's
-- and WALLY's bags are this file's: the tutorial's bag in place of the
-- player's while the fight runs, as the cart swaps it (M.BAG_POCKETS), so an
-- item the screen spends comes out of the tutorial's bag, never the
-- player's.  Made once the fight is running (the driver's or the stream's
-- first call), so no way out of the fight can leave it swapped: the fight's
-- own end (`word`), its hand-back (`handBack`) and a quit put it back.  A
-- fight that reaches none of them -- its screen thrown off the stack, an F5
-- hot reload mid-tutorial -- is caught by the save ledger (src/Borrow3.lua):
-- the borrow is held there under M.BAG_BORROW, alive while this fight's
-- screen is still up, and the `save.write` link gives the pockets back before
-- any save could write the tutorial's POTION and POKé BALL as the player's.
M.BAG_BORROW = "bag pockets"

-- RestorePlayerBag / RestoreBagAfterWallyTutorial: the player's pockets back,
-- whatever the tutorial's bag spent.  Once: whoever runs first (the fight's
-- own end, or the ledger for a fight that never reached it) clears it.
local function giveBagBack(st, b)
  if st.bagBorrow ~= b then return false end
  st.bagBorrow = nil
  for key, list in pairs(b.pockets) do b.bag.pockets[key] = list end
  local Bag = Gen3.engine("src.core.game3.bag")
  if Bag and type(Bag.migrate) == "function" then pcall(Bag.migrate, b.bag) end
  return true
end

-- Is the tutorial that holds `b` still being fought: the core's fight is
-- still this one (SoloBattle M:_clear3 drops `gen3` at the end and at a
-- hand-back) and its screen is still on the modal stack (one thrown off it
-- is over, whatever the core still points at).
local function fightAlive(ctx, st, b)
  if st.bagBorrow ~= b then return false end
  local solo = ctx.solo
  if type(solo) ~= "table" or solo.gen3 ~= ctx or solo.fight == nil then return false end
  local Gen3Ui = sibling("Gen3Ui")
  if Gen3Ui and type(Gen3Ui.has) == "function" then
    local ok, up = pcall(Gen3Ui.has, solo.fight)
    return ok and up == true
  end
  return true
end

function M.borrowBag3(ctx)
  local st = ctx.tut3
  if not st or st.bagBorrowed then return false end
  st.bagBorrowed = true
  if st.which == "pokedude" then return false end
  local session = ctx.session or Gen3.session()
  if type(session) ~= "table" or type(session.bag) ~= "table" then return false end
  local bag = session.bag
  if type(bag.pockets) ~= "table" then return false end
  -- A tutorial that died mid-fight left its pockets in the bag and its
  -- record on the ledger: settle first, or this borrow would save that
  -- tutorial's pockets as the player's and its record would replace the
  -- one holding the player's own.
  pcall(Borrow3.settle, session)
  local saved = {}
  for _, key in ipairs(M.BAG_POCKETS[st.which] or {}) do
    saved[key] = bag.pockets[key]
    bag.pockets[key] = {}
  end
  local b = { bag = bag, pockets = saved, session = session }
  st.bagBorrow = b
  -- Labelled "bag" for the refusal line -- the player's word for it, and the
  -- POKé DUDE's bag borrow says the same, so the two read as one.
  Borrow3.hold(session, M.BAG_BORROW, function() giveBagBack(st, b) end,
    function() return fightAlive(ctx, st, b) end, "bag")
  for _, e in ipairs(st.bag or {}) do Gen3.bag.add(e.id, e.count) end
  return true
end

function M.returnBag3(ctx)
  local st = type(ctx) == "table" and ctx.tut3 or nil
  local b = st and st.bagBorrow
  if not b then return false end
  Borrow3.release(b.session, M.BAG_BORROW)
  return giveBagBack(st, b)
end

-- ------------------------------------------------------------------
-- the scripted inputs
-- ------------------------------------------------------------------

-- A move slot (0-based) the referee will take for this battler: the asked
-- one when it holds a move with PP, else the first that does (the engine's
-- own Commands.playerAction fallback), else the asked one (the referee turns
-- a seat with no PP left into Struggle).
local function usableMove(mon, slot)
  local moves = type(mon) == "table" and type(mon.moves) == "table" and mon.moves or nil
  if not moves then return slot end
  local mv = moves[slot + 1]
  if type(mv) == "table" and int(mv.pp, 1) > 0 then return slot end
  for i, m in ipairs(moves) do
    if type(m) == "table" and int(m.pp, 1) > 0 then return i - 1 end
  end
  return slot
end

-- Does a medicine do anything for this monster (the referee refuses one that
-- would not, BattleSim3 `_itemHasEffect`)?  Only a cure is checked against
-- the monster's status: the TEACHY TV's ANTIDOTE on its poisoned RATTATA.
local function medicineWorks(id, mon)
  local Items = sibling("BattleSim3/Items")
  local effect = Items and try(Items.bagEffect, id) or nil
  if type(effect) ~= "table" or type(effect.cure) ~= "table" then return true end
  local status = type(mon) == "table" and mon.status or nil
  return status ~= nil and effect.cure[status] == true
end

-- The party slot (the sheet's own `slot`, the wire's) one row right of the
-- battler out in the battle party menu (Task_PartyMenu_PokedudeStep,
-- party_menu.c:2028: UpdateCurrentPartySelection MENU_DIR_RIGHT from the
-- first row, then SHIFT): the first other monster, in party order.  nil when
-- that one cannot come in.
local function shiftSlot(view)
  local party = type(view.party) == "table" and view.party or {}
  for i, mon in ipairs(party) do
    if i ~= view.active then
      if int(mon.hp, 0) > 0 then return int(mon.slot, i - 1) end
      return nil
    end
  end
  return nil
end

local function fightChoice(view, slot)
  return { action = "fight", move = usableMove(view.mon, slot) }
end

-- The POKe DUDE's turn on side a: the choice, the voice-overs due before the
-- cursor moves (CHOOSEACTION's -- or, for a fainted seat's successor, which
-- has no action menu, CHOOSEPOKEMON's), and those due once the command is
-- picked and before its sub-menu opens (CHOOSEMOVE, OPENBAG, CHOOSEPOKEMON:
-- the controller is sent the sub-menu's command only after the action, and
-- HandlePokedudeVoiceoverEtc runs ahead of it).
local function pdPlan(ctx, view, seat)
  local st = ctx.tut3
  local pd = st.pd
  local due, after = {}, {}
  local function vo(cmd, into)
    for _, e in ipairs(M.pdEvent3(pd, st.headers, cmd, M.PD_PLAYER)) do into[#into + 1] = e end
  end
  if seat.mustReplace then
    -- A fainted monster's successor (PokedudeHandleChoosePokemon -> the same
    -- party-menu walk).
    vo("choosepokemon", due)
    local slot = shiftSlot(view)
    if slot == nil then
      for i, mon in ipairs(view.party or {}) do
        if int(mon.hp, 0) > 0 then slot = int(mon.slot, i - 1); break end
      end
    end
    return { action = "switch", slot = slot or 0 }, due, after
  end
  vo("chooseaction", due)
  local cursor = M.pdTakeAction3(pd, M.PD_PLAYER)
  if cursor == 1 then
    vo("openbag", after)
    local item = M.PD_BAG_ITEM[pd.script] or M.PD_BAG_ITEM_DEFAULT
    local choice = { action = "item", item = tostring(item) }
    local Items = sibling("BattleSim3/Items")
    local effect = Items and try(Items.bagEffect, item) or nil
    if not (type(effect) == "table" and effect.ball) then
      if not medicineWorks(item, view.mon) then return fightChoice(view, 0), due, after end
      choice.slot = int(view.mon and view.mon.slot, 0)
    end
    return choice, due, after
  elseif cursor == 2 then
    vo("choosepokemon", after)
    local slot = shiftSlot(view)
    if slot == nil then return fightChoice(view, 0), due, after end
    return { action = "switch", slot = slot }, due, after
  elseif cursor == 3 then
    return { action = "run" }, due, after
  end
  vo("choosemove", after)
  return fightChoice(view, M.pdTakeMove3(pd, M.PD_PLAYER)), due, after
end

-- WALLY's throw turn, as the referee takes it (contract C-W of wave 4b:
-- BattleSim3's `wallyThrow` action, accepted under `tutorial = "wally"`).
M.WALLY_THROW = { action = "wallyThrow" }

-- This turn's scripted input for side a, and what goes with it: { choice,
-- due = voice-overs before the walk, after = voice-overs between the command
-- and its sub-menu }.
function M.plan3(ctx, view, seat)
  local st = ctx.tut3
  local which = st.which
  if which == "pokedude" then
    local choice, due, after = pdPlan(ctx, view, seat)
    return { choice = choice, due = due, after = after }
  end
  local step = st.step
  st.step = step + 1
  if which == "oldMan" then
    -- SimulateInputChooseAction (battle_controller_oak_old_man.c:278): the
    -- cursor to BAG, A; then Task_Bag_OldManTutorial picks the POKé BALL.
    return { choice = { action = "item", item = tostring(M.ITEM_POKE_BALL) } }
  end
  -- WallyHandleActions (pokeemerald battle_controller_wally.c:188): states
  -- 1-2, FIGHT twice -- move slot 0 on the foe (WallyHandleChooseMove,
  -- B_ACTION_EXEC_SCRIPT 0x100); state 3, B_ACTION_WALLY_THROW -- its own
  -- action, ordered with the moves by speed (battle_main.c: not in the
  -- item / switch-first loop), which recalls the ZIGZAGOON, slides WALLY in,
  -- says "You throw a BALL now, right?" and cancels the turn's second action
  -- (battle_util.c:625 HandleAction_WallyBallThrow) -- so a RALTS that wins
  -- the order still acts; states 4-5, BAG and the POKé BALL
  -- (Task_WallyTutorialBagMenu) on turn 4, the item first, the forced catch
  -- ending the fight before the foe's turn.  The screen plays the recall when
  -- the referee's `wallyThrow` event arrives.
  if step < 2 then return { choice = fightChoice(view, 0) } end
  if step == 2 then
    local throw = {}
    for k, v in pairs(M.WALLY_THROW) do throw[k] = v end
    return { choice = throw }
  end
  return { choice = { action = "item", item = tostring(M.ITEM_POKE_BALL) } }
end

-- A choice the referee refused (`tries` refusals so far this turn): the cart
-- would have filed its input whatever it did, and a referee never freezes,
-- so the turn goes on -- FIGHT with each move the battler can use in turn,
-- then RUN; a fainted seat's successor, each monster that can still fight.
-- The old man has no move: his RUN, which a seat with no battler always gets
-- away with (BattleSim3's `noBattler`).
local function fallbackPlan(view, seat, tries)
  if seat.mustReplace then
    local bench = {}
    for i, mon in ipairs(type(view.party) == "table" and view.party or {}) do
      if i ~= view.active and int(mon.hp, 0) > 0 then bench[#bench + 1] = int(mon.slot, i - 1) end
    end
    return { choice = { action = "switch", slot = bench[tries] or bench[1] or 0 } }
  end
  local moves = {}
  for i, m in ipairs(type(view.mon) == "table" and type(view.mon.moves) == "table"
                     and view.mon.moves or {}) do
    if type(m) == "table" and int(m.pp, 1) > 0 then moves[#moves + 1] = i - 1 end
  end
  local slot = moves[tries]
  if slot ~= nil then return { choice = { action = "fight", move = slot } } end
  return { choice = { action = "run" } }
end

local function sameChoice(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  if a.action ~= b.action then return false end
  return tonumber(a.move) == tonumber(b.move) and tonumber(a.item) == tonumber(b.item)
    and tonumber(a.slot) == tonumber(b.slot)
end
M.sameChoice3 = sameChoice

-- The screen is showing its menu for this seat: the command menu, or a
-- fainted seat's party picker.
local function atMenu(fight, seat)
  if fight.phase == "choose" then return true end
  return seat.mustReplace == true and fight.phase == "switch"
end

-- Does the screen hold its walk for the lines said between a command and its
-- sub-menu (contract C-V of wave 4b: `autoplay3`'s `opts.afterCommand`, the
-- walk waiting on `tutorialIdle3`)?
local function holdsAfterCommand(fight)
  return type(fight.autoplay3) == "function" and type(fight.tutorialIdle3) == "function"
end

-- Side a's answerer (contract C4: the core's NPC loop asks it every frame the
-- seat owes, src/SoloBattle.lua M:_answerNpcs3).  It never files itself and
-- always answers `false` (waiting): once the screen's menu is up -- after the
-- last turn's lines have played, so a voice-over lands where the cart prints
-- it -- this turn's input goes to the screen (`autoplay3`), which walks the
-- cursor at the cart's pace and files it through its own `sendChoice`.  The
-- voice-overs due before the walk are said first; those due between the
-- command and its sub-menu ride the walk (`afterCommand`), or -- on a screen
-- that cannot hold its walk for them -- are said before it too.  A screen
-- without `autoplay3` is handed the choice to file at once.  A choice the
-- referee refused (`onFiled(false)`, or `sendChoice` saying no) is replanned
-- (fallbackPlan), its lines not said again.
function M.driveSideA3(ctx, view, seat)
  local st, fight, sim = ctx.tut3, ctx.fight, ctx.sim
  if not (st and type(fight) == "table" and type(sim) == "table") or fight.finished or st.quit then
    return false
  end
  M.begin3(ctx)
  local window = tostring(sim.turn) .. ":" .. tostring(sim.phase)
  local p = st.pending
  if p and p.window == window and p.booked then return false end
  if not atMenu(fight, seat) then return false end
  if not (p and p.window == window) then
    p = { window = window, plan = M.plan3(ctx, view, seat), tries = 0 }
    st.pending = p
  elseif p.refused then
    p.tries = p.tries + 1
    p.plan, p.refused = fallbackPlan(view, seat, p.tries), false
  end
  p.booked = true
  local plan = p.plan
  local after = (type(plan.after) == "table" and #plan.after > 0) and plan.after or nil
  local held = after ~= nil and holdsAfterCommand(fight)
  if not p.said then
    p.said = true
    sayAll(ctx, plan.due)
    if after and not held then sayAll(ctx, after) end
  end
  local booking = p
  local function onFiled(sent)
    if sent == false and st.pending == booking then
      booking.refused, booking.booked = true, false
    end
  end
  if type(fight.autoplay3) == "function" then
    local opts = nil
    if held then
      opts = { afterCommand = function()
        if booking.afterSaid then return end
        booking.afterSaid = true
        sayAll(ctx, after)
      end }
    end
    local ok, booked = pcall(fight.autoplay3, fight, plan.choice, onFiled, opts)
    if ok then
      -- `false`: a walk already running -- asked again next frame.
      if booked == false then p.booked = false end
      return false
    end
    warn(ctx, "autoplay", "the tutorial's turn could not be played on the battle screen (%s); "
      .. "it is filed without the cursor walk -- report it with the battle you watched",
      tostring(booked))
    if after and held and not booking.afterSaid then
      booking.afterSaid = true
      sayAll(ctx, after)
    end
  end
  if not fight:sendChoice(plan.choice) then p.refused, p.booked = true, false end
  return false
end

-- The POKe DUDE's B (contract C-Q of wave 4b): the screen, having faded out,
-- asks once (`tutorial.quit(how)`).  `how` "battle" is B held in the battle
-- (pret pokefirered battle_main.c:1455 BattleMainCB2: gBattleOutcome =
-- B_OUTCOME_DREW, CB2_QuitPokedudeBattle); "bag" / "party" is B pressed in
-- his bag or party menu (item_menu.c:2192 Task_BButtonInterruptTeachyTv,
-- party_menu.c:2052 PartyMenuPokedudeIsCancelled: straight back to the
-- TEACHY TV, its resume set, gBattleOutcome left alone).  Either way the
-- fight ends on the spot -- no further turn, nothing brought home or reported
-- (SoloBattle M:quit3) -- and the TEACHY TV hears DREW, which is its way back
-- to the program list (teachy_tv.c:1208 TeachyTvRestorePlayerPartyCallback
-- -> SetTeachyTvControllerModeToResume, as the menus' exits set it; the
-- engine's TeachyTv.modeAfterBattle).  His party, his bag and the TEACHY TV's
-- layers go back in the stand's `done`.
function M.quit3(ctx, how)
  local st = ctx.tut3
  if not st or st.quit then return false end
  st.quit = true
  M.returnBag3(ctx)
  local solo = ctx.solo
  if not (type(solo) == "table" and type(solo.quit3) == "function") then return false end
  local inMenu = how == "bag" or how == "party"
  return solo:quit3("draw", (not inMenu) and "draw" or false)
end

-- The POKe DUDE's foe (its controller is the POKe DUDE's too: pret
-- InitSinglePlayerBtlControllers, battle_controllers.c:89): the opponent's
-- column of the same scripts, filed at once (its delay is 0).  A fainted
-- seat's replacement is the referee's (the demonstrations' foes have one
-- monster).
function M.driveFoe3(ctx, view, seat)
  local st = ctx.tut3
  if not (st and st.pd) or seat.mustReplace then return nil end
  local cursor = M.pdTakeAction3(st.pd, M.PD_OPPONENT)
  local slot = 0
  if cursor == 0 then slot = M.pdTakeMove3(st.pd, M.PD_OPPONENT) end
  return { action = "fight", move = usableMove(view.mon, slot) }
end

-- The first of the driver's and the stream's calls once the fight is
-- running: the tutorial's bag in.
function M.begin3(ctx)
  local st = ctx.tut3
  if not st or st.begun then return end
  st.begun = true
  M.borrowBag3(ctx)
end

-- ------------------------------------------------------------------
-- the POKe DUDE's PRINTSTRING voice-overs, off the stream
-- ------------------------------------------------------------------

local function startsWith(text, prefix)
  return type(text) == "string" and text:sub(1, #prefix) == prefix
end

-- Whose monster a "<X> ..." line is about: the name of a monster in `id`'s
-- party the line starts with (the referee narrates by the sheet's species
-- name, Move.lua Bm:nameOf).  The stream is read after the turn has
-- resolved, so the whole party is asked, not the one out now (the foe may
-- have fainted later in the same turn).
local function opensWithMonOf(sim, id, text, rest)
  local f = type(sim) == "table" and type(sim.byId) == "table" and sim.byId[id] or nil
  for _, mon in ipairs(f and f.mons or {}) do
    local name = mon.species
    if type(name) == "string" and name ~= "" and startsWith(text, name .. rest) then return true end
  end
  return false
end

-- A line about the foe's monster and none of side a's (the demonstrations'
-- two sides never share a name; a line both could have said is nobody's).
local function foeLine(sim, text, rest)
  return opensWithMonOf(sim, M.FOE_SEAT, text, rest)
    and not opensWithMonOf(sim, M.PLAYER_SEAT, text, rest)
end

-- The commands the POKe DUDE's text scripts wait for that the referee's
-- stream carries, read before the screen shows the event (the core's
-- M:_note3 runs the kind's `note` first), so a voice-over is queued ahead of
-- the line it precedes on the cart:
--   PRINTSTRING STRINGID_USEDMOVE to the opponent -- the foe's "<X> used <move>!"
--     (Cmd_attackstring prints it to gBattlerAttacker);
--   PRINTSTRING STRINGID_PKMNFASTASLEEP to the opponent -- "<X> is fast asleep."
--     (BattleScript_MoveUsedIsAsleep's printstring, the attacker's);
--   PRINTSTRING STRINGID_PKMNGAINEDEXP to the player -- each `exp` award
--     (Cmd_getexp prints it to the EXP getter);
--   ENDLINKBATTLE to the player -- the forced catch's end
--     (BattleScript_OldMan_Pokedude_CaughtMessage: "Gotcha!", then
--     endlinkbattle, then the fight is over).
function M.pdNote3(ctx, event)
  local st, sim = ctx.tut3, ctx.sim
  local t = event.t
  local due = nil
  if t == "msg" then
    if foeLine(sim, event.text, " used ") then
      due = M.pdEvent3(st.pd, st.headers, "printstring", M.PD_OPPONENT, "STRINGID_USEDMOVE")
    elseif foeLine(sim, event.text, " is fast asleep") then
      due = M.pdEvent3(st.pd, st.headers, "printstring", M.PD_OPPONENT, "STRINGID_PKMNFASTASLEEP")
    end
  elseif t == "exp" then
    due = M.pdEvent3(st.pd, st.headers, "printstring", M.PD_PLAYER, "STRINGID_PKMNGAINEDEXP")
  elseif t == "over" and event.text == "catch" then
    due = M.pdEvent3(st.pd, st.headers, "endlinkbattle", M.PD_PLAYER)
  end
  if due and #due > 0 then sayAll(ctx, due) end
end

-- ------------------------------------------------------------------
-- the kind
-- ------------------------------------------------------------------

local Tutorial = {}

-- Every tutorial is a wild-shaped fight on the cart (the WEEDLE, WALLY's
-- RALTS, the demonstration's foe).  The POKe DUDE's needs his party (the
-- stand's `playerParty`) and his demonstration's number.
function Tutorial:takes(ctx)
  if ctx.kind ~= "wild" then return false, "a tutorial is a wild battle" end
  local which = M.which3(ctx)
  if not which then return false, "no tutorial" end
  local st = { which = which, step = 0 }
  if which == "pokedude" then
    local stand = ctx.stand
    local party = type(stand) == "table" and stand.playerParty or nil
    if type(party) ~= "table" or #party == 0 or type(party[1]) ~= "table" then
      return false, "the POKe DUDE's party is missing"
    end
    -- His party is the session's for the fight: the TEACHY TV door put it
    -- there (src/CoopField.lua divertPokedude, Stand:borrowParty3), as the
    -- cart writes it into gPlayerParty.  A stand that did not is no
    -- demonstration of ours.
    local session = ctx.session or Gen3.session()
    if not (type(session) == "table" and session.party == party) then
      return false, "the POKe DUDE's party is not in place"
    end
    local opts = type(ctx.opts) == "table" and ctx.opts or {}
    local script = int(stand.pokedudeScript, nil) or int(opts.pdScriptNum, nil)
    if script == nil or M.PD_ACTION_BASE[script] == nil then
      return false, "no such TEACHY TV demonstration"
    end
    st.pd = M.pdNewState3(script)
    local PD = pokedudeModule()
    local headers = PD and type(PD.TEXT_SCRIPTS) == "table" and PD.TEXT_SCRIPTS[script] or nil
    if type(headers) ~= "table" then
      warn(ctx, "headers", "this build cannot say the POKe DUDE's lines, so his demonstration "
        .. "plays without them -- update the game to hear him")
      headers = {}
    end
    st.headers = headers
  end
  st.name = M.seatName3(which)
  st.bag = M.bag3(which)
  ctx.tut3 = st
  -- Nothing of side a comes home (the old man fields nothing; WALLY's
  -- ZIGZAGOON and the POKe DUDE's party are the cart's to throw away --
  -- LoadPlayerParty); nobody whites out (the old man cannot lose, WALLY's
  -- RALTS knows no damaging move, and the TEACHY TV takes a loss as LOST); no
  -- Pickup over a borrowed party.
  ctx.noReconcile, ctx.lossless, ctx.noPickup = true, true, true
  if which == "oldMan" then ctx.partyless = true end
  if M.NO_DEX_SEEN[which] then ctx.noDexSeen = true end
  -- The TEACHY TV's battle goes back to the TEACHY TV, not the field: no map
  -- resume scripts.
  if which == "pokedude" then ctx.noFieldReturn = true end
  return true
end

-- The screen: which tutorial, whose name, whose back pic, which prompt, the
-- tutorial's bag; the old man fields nothing; the POKe DUDE's fight can be
-- quit with B (`tutorial.quit`, M.quit3).  His party is already the
-- session's (the TEACHY TV door's), which is the party the screen reads as
-- it starts.
function Tutorial:screen(ctx, screenOpts)
  local st = ctx.tut3
  screenOpts.tutorial = {
    kind = st.which, name = st.name, backPic = M.BACK_PICS[st.which], prompt = M.PROMPTS[st.which],
  }
  if st.which == "pokedude" then
    screenOpts.tutorial.quit = function(how) return M.quit3(ctx, how) end
  end
  if st.which == "oldMan" then screenOpts.noOwnBattler = true end
  screenOpts.bag = copyBag(st.bag)
end

-- The referee: the tutorial's battle type (a forced catch that gives
-- nothing; its crit / accuracy / obedience rules) and side a as the cart
-- fields it -- the old man alone with his bag (side-entry `noBattler`), WALLY
-- and the POKe DUDE under their names with theirs.  Side a keeps the save's
-- badges: pret's badge boosts read the player's flags whoever stands on the
-- player's side (pokefirered pokemon.c:2381 ShouldGetStatBadgeBoost: only a
-- link or e-Reader battle is exempt).
function Tutorial:seat(ctx, create)
  local st = ctx.tut3
  local a = create.sides.a[1]
  if st.which == "oldMan" then
    create.sides.a[1] = { playerId = a.playerId, name = st.name, noBattler = true,
                          bag = copyBag(st.bag) }
  else
    a.name = st.name
    a.bag = copyBag(st.bag)
  end
  return { tutorial = st.which, catch = "forced" }
end

-- Side a is this file's driver (M.driveSideA3), and the POKe DUDE's foe his
-- script's (M.driveFoe3); the old man's WEEDLE and WALLY's RALTS stay the
-- referee's (`wildPick = "cart"`: no AI script runs for a tutorial's wild,
-- pret battle_controller_opponent.c:1355).
function Tutorial:brains(ctx, npcs)
  npcs[M.PLAYER_SEAT] = function(view, seat) return M.driveSideA3(ctx, view, seat) end
  if ctx.tut3.which == "pokedude" then
    npcs[M.FOE_SEAT] = function(view, seat) return M.driveFoe3(ctx, view, seat) end
  end
end

-- The screen takes no player input in a tutorial; anything it files that is
-- not this turn's scripted input is refused, the menu kept and nothing
-- spent (the carts' controllers read no button there).
function Tutorial:choose(ctx, payload)
  local p = ctx.tut3 and ctx.tut3.pending
  if p and p.plan and sameChoice(p.plan.choice, payload) then return false end
  return true, false
end

function Tutorial:note(ctx, event)
  M.begin3(ctx)
  if ctx.tut3.which == "pokedude" and type(event) == "table" then M.pdNote3(ctx, event) end
end

-- The fight's end, before the caller's `done`: the old man's / WALLY's bag
-- back (RestorePlayerBag / RestoreBagAfterWallyTutorial run before the
-- cart's callback), and the POKe DUDE's catch answered "catch"
-- (battle/pokedude.lua finish_battle, the TEACHY TV's CAUGHT).  His party
-- stays his until the stand's `done`: pret runs the evolutions after a won
-- demonstration on gPlayerParty -- his monsters -- and only then
-- LoadPlayerParty (FreeResetData_ReturnToOvOrDoEvolutions, then
-- TeachyTvRestorePlayerPartyCallback).
function Tutorial:word(ctx, outcome)
  M.returnBag3(ctx)
  if ctx.tut3.which == "pokedude" and type(outcome) == "table" and outcome.how == "catch" then
    return "catch"
  end
  return nil
end

-- A fight the referee could not keep going goes to the cart's own battle (the
-- core's hand-back: the stand's fightAlone -- which gives the POKe DUDE's
-- party, bag and the TEACHY TV back first -- or the TEACHY TV's own start)
-- with the player's bag where the cart's start expects it.
function Tutorial:handBack(ctx)
  M.returnBag3(ctx)
  return false
end

M.Tutorial = Tutorial
M.kinds3 = { tutorial = Tutorial }

return M
