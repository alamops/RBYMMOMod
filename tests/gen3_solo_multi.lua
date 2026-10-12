-- Headless Gen 3 solo battles: the Battle Frontier's two-sided fights, the
-- half of the `facility` kind src/Solo3/FacilityMulti.lua seats (contract C2
-- of docs/plans/gen3-solo-remaining-fights.md, K-FAC2; research §1.4, §1.5,
-- §3.4) -- a Battle Tower multi with the partner chosen in the lobby, and the
-- Battle Pike's two-trainer room -- through the real src/SoloBattle.lua core,
-- the real BattleSim3 referee, CoopBattle's real solo double screen and
-- src/CoopField.lua's real stand-ins.  The rig is
-- tests/fixtures/gen3_solo_dbl_rig.lua.
--
--   1. the module: its hook table answers either call style, the two shapes,
--      the partner read from the frontier book, B's win words read from it;
--   2. the route: the real `facility` kind hands both fights here
--      (src/Solo3/Facility.lua's multi dispatch -- checked; without it the
--      same delegation is stood in so the scenarios below still measure the
--      real hooks);
--   3. a Tower multi, seated: the player's one seat and the partner's (not
--      `spare`), A and B on slots 3 / 4 each with their half, no bags, the
--      Frontier's rules, three minds on the Frontier's scripts with no items,
--      the screen told the partner, the second trainer, the prompts and the
--      jingle; the partner's front pic and the player's own on the GBA page;
--   4. a Tower multi, ended: the win in the Frontier's words with no money,
--      no EXP and the jingle; the fight going on while the partner stands
--      after the player's half is down; the loss with both trainers' win
--      words and no whiteout; the forfeit; the draw; the partner's
--      monsters back behind the player's (with the fight's damage) before
--      the script reads the party, and on a hand-back;
--   5. the Pike's double: one monster each on slots 3 / 4, the player's two
--      seats, the Frontier's rules, the win and the damage carried into the
--      next room (no heal), the loss's words, the room refused to a party
--      with one monster standing;
--   6. a Battle Palace double on the double screen, through the real
--      Facility kind: FIGHT asks the Palace's pick for each seat by its field
--      slot, the facility files the nature's choice, no move list opens, the
--      fight plays to the facility's word;
--   7. off Emerald: handed back.
--
-- Run from the engine checkout root:
--
--   luajit mods/rby_mmo/tests/gen3_solo_multi.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local check, eq = T.check, T.eq

local here = (debug.getinfo(1, "S").source:sub(2):match("(.+)[/\\]")) or "."
local R = dofile(here .. "/fixtures/gen3_solo_dbl_rig.lua")(T)

local Solo, CoopField, CoopBattle = R.Solo, R.CoopField, R.CoopBattle
local mon, block = R.mon, R.block
local warns = R.warns

-- ===================================================================
-- the stand-ins this suite adds (synthetic numbers)
-- ===================================================================

-- The engine's frontier trainer book (rse/frontier/trainers.lua): three
-- frontier trainers -- A, B, and the lobby partner -- with their classes,
-- pics, walkers and speeches.
local FRONTIER = {
  [11] = { class = 60, className = "COOLTRAINER", name = "ALICE", pic = 40, gfx = 120,
           speech = { [1] = "ALICE: I won!", [2] = "ALICE: I lost..." } },
  [12] = { class = 61, className = "BLACK BELT", name = "BRUNO", pic = 41, gfx = 121,
           speech = { [1] = "BRUNO: Ha!", [2] = "BRUNO: argh" } },
  [33] = { class = 62, className = "PSYCHIC", name = "LUCY", pic = 44, gfx = 122,
           speech = { [1] = "LUCY: ok", [2] = "LUCY: hm" } },
}
local bookAsks = {}
local FakeFrontier = { FACILITY = { TOWER = 0, DOME = 1, PALACE = 2, ARENA = 3, FACTORY = 4,
                                    PIKE = 5, PYRAMID = 6 } }
local function bookRow(tid, what, fac)
  bookAsks[#bookAsks + 1] = { tid = tid, what = what, facility = fac }
  return FRONTIER[tonumber(tid)]
end
function FakeFrontier.trainerSpeech(_, tid, which, fac)
  local t = bookRow(tid, "speech" .. tostring(which), fac)
  local s = t and t.speech and t.speech[which]
  return s and { plain = s } or nil
end
function FakeFrontier.opponentClass(_, tid, fac)
  local t = bookRow(tid, "class", fac)
  return t and t.class or 0
end
function FakeFrontier.className(_, cls)
  for _, t in pairs(FRONTIER) do if t.class == cls then return t.className end end
  return ""
end
function FakeFrontier.gfxId(_, tid, fac)
  local t = bookRow(tid, "gfx", fac)
  return t and t.gfx or 0
end
function FakeFrontier.trainerName(_, tid, fac)
  local t = bookRow(tid, "name", fac)
  return t and t.name or ""
end
function FakeFrontier.frontSpriteId(_, tid, fac)
  local t = bookRow(tid, "pic", fac)
  return t and t.pic or 0
end
package.loaded["src.core.game3.rse.frontier.trainers"] = FakeFrontier
package.loaded["src.core.game3.scripting.text_ir"] = {
  toPlain = function(ir) return type(ir) == "table" and ir.plain or "" end,
}
package.loaded["src.core.game3.rse.frontier.util"] = {
  frontier = function(sess)
    if type(sess.frontier) ~= "table" then sess.frontier = {} end
    return sess.frontier
  end,
}

-- The cart's constants (the engine's constants.lua `of`): the songs the
-- screens play by name, the player's front pics.  The rig's stub is the one
-- Gen3.engine already holds, so its `of` is moved in place.
local SONGS = { MUS_VICTORY_TRAINER = 352, MUS_B_TOWER = 400, MUS_B_PIKE = 401 }
local PICS = { TRAINER_PIC_BRENDAN = 71, TRAINER_PIC_MAY = 72, TRAINER_PIC_RED = 89,
               TRAINER_PIC_LEAF = 90 }
local constAsks = {}
do
  local C = package.loaded["src.core.game3.constants"]
  local SET = {
    song = function(_, name) return SONGS[name] or 7 end,
    id = function(_, kind, name)
      constAsks[#constAsks + 1] = { kind = kind, name = name }
      if kind == "trainer_classes" then return PICS[name] end
      return nil
    end,
    name = function() return nil end,
  }
  C.of = function() return SET end
end

-- Every trainer line the double screen slides a trainer in for, and every
-- pair ending it says (the screen's own methods, wrapped as the rig wraps
-- `say`).
local slid = {}
do
  local sayTrainer, sayPair = CoopBattle.sayTrainer3, CoopBattle.sayPairDefeated3
  CoopBattle.sayTrainer3 = function(self, which, text)
    slid[#slid + 1] = { which = which, text = text }
    return sayTrainer(self, which, text)
  end
  CoopBattle.sayPairDefeated3 = function(self)
    slid[#slid + 1] = { which = "pair" }
    return sayPair(self)
  end
end

-- ===================================================================
-- the fights
-- ===================================================================

local Multi = R.need("Solo3/FacilityMulti")
local Facility = R.need("Solo3/Facility")

-- A partner monster (his OT, so the obedience check would call it traded).
local function his(species, level, moves, extra)
  local m = mon(species, level, { moves = moves or { 300 }, otId = 999, otName = "LUCY" })
  for k, v in pairs(extra or {}) do m[k] = v end
  return m
end

-- Tower.startBattle's opts for the hall (rse/frontier/tower.lua), the multi's
-- `extra` merged in (doTowerBattle) for the Tower, the Pike's for its room
-- (pike.lua doSpecialBattle).
local function startOpts(hall, extra)
  local o = {
    wild = false, frontier = true, double = true, aiFlags = 7,
    trainerItems = { 0, 0, 0, 0 }, scriptedLoss = true,
    trainerName = "ALICE", trainerPicId = 40,
    defeatText = "ALICE: I lost...", victoryText = "ALICE: I won!",
    frontierTrainer = { class = 60, className = "COOLTRAINER", name = "ALICE", pic = 40 },
    frontierOpponentB = 12, twoOpponents = true,
    frontierTrainerB = { class = 61, className = "BLACK BELT", name = "BRUNO", pic = 41 },
    defeatTextB = "BRUNO: argh",
  }
  o[hall] = true
  if hall == "tower" then
    o.battleTower = true
    o.song = "MUS_B_TOWER"
    o.partner, o.frontierPartner, o.partnerName, o.partnerPicId = true, 33, "LUCY", 44
  else
    o.song = "MUS_B_PIKE"
  end
  for k, v in pairs(extra or {}) do o[k] = v end
  return o
end

-- Tower.foeOf's record: A's and B's monsters as one party, A's first.
local function frontierFoe(party)
  return { party = party, trainerName = "ALICE", trainerClass = 60, trainerClassName = "COOLTRAINER",
           trainerPicId = 40, frontierTrainerId = 11,
           species = party[1].species, level = party[1].level }
end

-- Tower.startBattle's own `done`: the word, its code, the party the battle
-- room's script then reads -- and the stale interview record the engine's
-- `done` writes from its own battle state.
local function frontierDone()
  local rec = { heard = {} }
  function rec.done(result)
    rec.heard[#rec.heard + 1] = result
    rec.code = R.CODES[result]
    local s = R.session()
    rec.party = {}
    for i, m in ipairs(s.party) do rec.party[i] = m end
    rec.stale = { opponentSpecies = 0, playerSpecies = 0 }
    s.lastFrontierBattle = rec.stale
  end
  return rec
end

-- The door, the way src/Client.lua's offerFight3 walks it: CoopField's stand
-- for the start, solo offered the stand's own monsters and the stand itself,
-- the stand's begin3 once solo took it, its giveBack3 when nobody did.
local function offer(solo, foe, opts, done)
  local starts = {}
  local stand, why = CoopField.trainerStand3(foe, opts, {
    game = R.game(), solo = true,
    fightAlone = function() starts[#starts + 1] = #R.session().party end,
  })
  if not stand then return false, nil, why, starts end
  local taken = solo:fromGen3Trainer(R.game(), foe, R.standOpts(stand, done)) == true
  if taken then stand:begin3() else stand:giveBack3() end
  return taken, stand, nil, starts
end

-- A Battle Tower multi: the player's two, the partner's two appended behind
-- them (doTowerBattle), A's two and B's two.
local function towerMulti(o)
  o = o or {}
  R.newGame(o.cart or "emerald")
  -- The overworld's weather opens the fight (newGame clears it).
  R.FakeWeather.id = o.weather or 0
  local s = R.session()
  local mine = o.mine or { mon(16, 30, { moves = { 300 } }), mon(29, 30, { moves = { 300 } }) }
  local partner = o.partner or { his(4, 30), his(151, 30) }
  for _, m in ipairs(mine) do s.party[#s.party + 1] = m end
  for _, m in ipairs(partner) do s.party[#s.party + 1] = m end
  local foes = o.foes or { mon(16, 5, { moves = { 45 }, otId = 1 }), mon(29, 5, { moves = { 45 }, otId = 1 }),
                           mon(5, 5, { moves = { 45 }, otId = 2 }), mon(263, 5, { moves = { 45 }, otId = 2 }) }
  local opts = startOpts("tower", { playerHalf = #mine, frontierFoeHalf = 2 })
  for k, v in pairs(o.opts or {}) do opts[k] = v end
  local solo = R.newSolo(o.seed)
  local rec = frontierDone()
  local taken, stand, why, starts = offer(solo, frontierFoe(foes), opts, rec.done)
  return { solo = solo, rec = rec, taken = taken, stand = stand, why = why, starts = starts,
           mine = mine, partner = partner, foes = foes, opts = opts }
end

-- The Pike's two-trainer room: the player's party, one monster each.
local function pikeDouble(o)
  o = o or {}
  R.newGame(o.cart or "emerald")
  local s = R.session()
  local mine = o.mine or { mon(16, 30, { moves = { 300 } }), mon(29, 30, { moves = { 300 } }),
                           mon(4, 30, { moves = { 300 } }) }
  for _, m in ipairs(mine) do s.party[#s.party + 1] = m end
  local foes = o.foes or { mon(16, 5, { moves = { 33 }, otId = 1 }), mon(5, 5, { moves = { 33 }, otId = 2 }) }
  local opts = startOpts("pike", { frontierFoeHalf = 1 })
  for k, v in pairs(o.opts or {}) do opts[k] = v end
  local solo = R.newSolo(o.seed)
  local rec = frontierDone()
  local taken, stand, why, starts = offer(solo, frontierFoe(foes), opts, rec.done)
  return { solo = solo, rec = rec, taken = taken, stand = stand, why = why, starts = starts,
           mine = mine, foes = foes, opts = opts }
end

local function slidText()
  local out = {}
  for _, s in ipairs(slid) do out[#out + 1] = tostring(s.which) .. ":" .. tostring(s.text) end
  return table.concat(out, " | ")
end

-- ===================================================================
-- 1. the module
-- ===================================================================

block("module", function()
  check(type(Multi) == "table", "module: src/Solo3/FacilityMulti.lua loads through the mod's resolver")
  for _, hook in ipairs(Solo.KIND_HOOKS3) do
    check(type(Multi[hook]) == "function", "module: FacilityMulti." .. hook .. " is a function")
    check(type(Multi.kind[hook]) == "function", "module: ...and the kind table's " .. hook)
  end
  -- Either call style, and a caller's own kind table handed first.
  local ctx = {}
  local ending = { word = "draw", result = "lose" }
  eq(Multi.word(ctx, {}, ending), "draw", "module: M.word(ctx, ...) -- a draw is 'draw'")
  eq(Multi:word(ctx, {}, ending), "draw", "module: M:word(ctx, ...) answers the same")
  eq(Multi.kind:word(ctx, {}, ending), "draw", "module: the kind table's word answers the same")
  local someKind = { takes = function() return true end }
  eq(Multi.word(someKind, ctx, {}, ending), "draw",
     "module: a caller's own kind table passed first is read as a hook table, never the ctx")
  eq(Multi.word(ctx, {}, { word = "lose", result = "lose" }), nil, "module: a loss is the core's word")
  eq(Multi.word(ctx, {}, { word = "forfeited", result = "forfeited" }), nil, "module: ...a forfeit too")
  -- The two shapes.
  eq(Multi.shapeOf({ opts = { partner = true, twoOpponents = true } }), "partner",
     "module: a Tower multi is the partner shape")
  eq(Multi.shapeOf({ opts = { twoOpponents = true, frontierTrainerB = {} } }), "twoOpponents",
     "module: the Pike's room the two-opponent shape")
  eq(Multi.shapeOf({ opts = {} }), nil, "module: a lone trainer is neither")
  -- The partner, as the book names him.
  R.newGame("emerald")
  local p = Multi.partnerRecord3({ opts = { frontierPartner = 33, partnerName = "LUCY", partnerPicId = 44 },
                                   session = R.session() }, "tower")
  eq(p.name, "LUCY", "partner record: his name (the start's partnerName)")
  eq(p.className, "PSYCHIC", "partner record: his class, GetFrontierOpponentClass(gPartnerTrainerId)")
  eq(p.trainerPic, 44, "partner record: his front pic (partnerPicId)")
  eq(p.graphicsId, 122, "partner record: his walker (SetBattleTowerPartnerGfx)")
  eq(p.backPic, nil, "partner record: no back pic (a frontier partner has none)")
  eq(p.partnerBackPic, nil, "partner record: ...not Steven's either")
  local towerAsk = false
  for _, a in ipairs(bookAsks) do if a.tid == 33 and a.facility == 0 then towerAsk = true end end
  check(towerAsk, "partner record: read off the Tower's own tables (FRONTIER_FACILITY_TOWER)")
  -- B's win words.
  eq(Multi.frontierWinText3(R.session(), 12), "BRUNO: Ha!",
     "B's win words: FRONTIER_PLAYER_LOST_TEXT through the engine's book")
  eq(Multi.frontierWinText3(R.session(), 99), nil, "B's win words: nil for a trainer the book lacks")
end)

-- ===================================================================
-- 2. the route
-- ===================================================================

-- Does the real `facility` kind (src/Solo3/Facility.lua) hand a two-sided
-- fight to this module?  Probed with a Tower multi's ctx: FacilityMulti's
-- `takes` marks every ctx it reads (`multi3`).
local real = Solo.kind3("facility")
check(type(real) == "table", "route: the facility kind is found through mod:read")
local delegates = false
do
  local f = towerMulti({ opts = { done = nil } })
  if f.taken then
    delegates = f.solo.gen3 ~= nil and f.solo.gen3.multi3 == "partner"
    f.solo:reset()
  end
end
check(delegates, "route: the real facility kind hands a Battle Tower multi to FacilityMulti "
  .. "(src/Solo3/Facility.lua's multi dispatch)")
if not delegates then
  -- Without that dispatch the same delegation is stood in -- a two-sided
  -- fight's every hook to FacilityMulti, every other fight's to the real
  -- kind -- so the scenarios below still measure the real hooks, core,
  -- referee and screen (and the check above has already failed).
  print("gen3_solo_multi: src/Solo3/Facility.lua does not delegate -- routing through a stand-in")
  local adapter = {}
  for _, hook in ipairs(Solo.KIND_HOOKS3) do
    adapter[hook] = function(_, ctx, ...)
      if Multi.shapeOf(ctx) then return Multi[hook](ctx, ...) end
      local fn = real[hook]
      if type(fn) == "function" then return fn(real, ctx, ...) end
      return nil
    end
  end
  Solo.registerKind3("facility", adapter)
end
R.dropWarnsSince(0)

-- ===================================================================
-- 3. a Tower multi, seated
-- ===================================================================

block("tower multi seated", function()
  local f = towerMulti()
  check(f.taken, "tower seated: solo takes the multi (" .. tostring(f.why) .. " / "
    .. table.concat(warns, " / ") .. ")")
  local solo = f.solo
  local sim = solo.sim
  eq(f.stand and f.stand.kind3, "facility", "tower seated: the stand-in is a facility fight")
  eq(f.stand and f.stand.facility3, "tower", "tower seated: ...in the Battle Tower")
  eq(#R.session().party, 2, "tower seated: the partner's two lifted out of the session party")
  eq(table.concat(Solo.sideIds3(sim, "a"), ","), "solo_player,solo_ally", "tower seated: side a is the player, then the partner")
  eq(table.concat(Solo.sideIds3(sim, "b"), ","), "solo_foe,solo_foe_b", "tower seated: side b is A, then B")
  local me, ally = sim.byId.solo_player, sim.byId.solo_ally
  eq(#me.seats, 1, "tower seated: the player commands one seat")
  eq(me.slot, 0, "tower seated: ...slot 0 (battler 0)")
  eq(ally.slot, 1, "tower seated: the partner on slot 1 (battler 2)")
  eq(ally.spare, nil, "tower seated: the partner is NOT spare (Cmd_checkteamslost counts him: not Steven)")
  eq(#me.mons, 2, "tower seated: the player brings their two")
  eq(#ally.mons, 2, "tower seated: the partner his two")
  eq(ally.mons[1].speciesNum, 4, "tower seated: ...in his order")
  local traded = false
  for _, s in ipairs(ally.mons) do if s.traded then traded = true end end
  check(not traded, "tower seated: his monsters carry no obedience fact (INGAME_PARTNER never disobeys)")
  local fa, fb = sim.byId.solo_foe, sim.byId.solo_foe_b
  eq(#fa.seats, 1, "tower seated: A behind one seat")
  eq(fa.slot, 3, "tower seated: ...slot 3 (battler 1)")
  eq(fb.slot, 4, "tower seated: B on slot 4 (battler 3)")
  eq(#fa.mons, 2, "tower seated: A fields its half (gEnemyParty[0..1])")
  eq(#fb.mons, 2, "tower seated: B its own (gEnemyParty[3..4])")
  eq(fb.mons[1].speciesNum, 5, "tower seated: ...B's half, cut at frontierFoeHalf")
  check(fa.bag == nil or next(fa.bag) == nil, "tower seated: A has no items (the Frontier's)")
  check(fb.bag == nil or next(fb.bag) == nil, "tower seated: ...nor B")
  -- The Frontier's rules.
  local create = R.lastCreate()
  local r = create and create.rules or {}
  check(r.bag == false and r.forfeit == true and r.exp == false and r.boosts == false
        and r.obedience == false and r.theft == "foe" and r.soulDew == false,
        "tower seated: the referee plays the Frontier's rules")
  local nr = sim.rules or {}
  check(nr.noBag and nr.forfeit and nr.noExp, "tower seated: ...and holds them")
  -- The minds.
  local npcs = solo.gen3.npcs
  local bA, bB, bAlly = npcs.solo_foe, npcs.solo_foe_b, npcs.solo_ally
  check(type(bA) == "table" and type(bB) == "table" and type(bAlly) == "table", "tower seated: three minds")
  eq(bA.aiFlags, 7, "tower seated: A on the Frontier's scripts (BAD | TRY_TO_FAINT | VIABILITY)")
  eq(bB.aiFlags, 7, "tower seated: ...B too (the FRONTIER arm wins over TWO_OPPONENTS)")
  eq(bAlly.aiFlags, 7, "tower seated: ...and the partner (his controller runs the same setup)")
  check(bA.noItems and bB.noItems and bAlly.noItems, "tower seated: nobody uses items")
  eq(bAlly.noDisobey, true, "tower seated: the partner never disobeys")
  eq(bAlly.owner, "solo_ally", "tower seated: his mind answers his seat")
  eq(bAlly.side3, "a", "tower seated: ...from side a")
  eq(bB.owner, "solo_foe_b", "tower seated: B's mind answers B's seat")
  -- The screen.
  local so = R.lastScreen() or {}
  local p = so.partner
  check(type(p) == "table", "tower seated: the double screen is told its partner")
  eq(p and p.name, "LUCY", "tower seated: ...his name")
  eq(p and p.className, "PSYCHIC", "tower seated: ...his class")
  eq(p and p.trainerPic, 44, "tower seated: ...his front pic")
  eq(p and p.backPic, nil, "tower seated: ...and no back pic")
  local allyEntry = create and create.sides.a[2]
  local bEntry = create and create.sides.b[2]
  eq(allyEntry and allyEntry.playerId, "solo_ally", "tower seated: the partner's referee entry")
  eq(so.partnerParty, allyEntry and allyEntry.mons, "tower seated: the very sheets his entry holds")
  eq(so.playerHalf, 2, "tower seated: where the player's half ends")
  eq(so.trainerB and so.trainerB.trainerName, "BRUNO", "tower seated: BRUNO is the second trainer")
  eq(so.trainerB and so.trainerB.victoryText, "BRUNO: Ha!", "tower seated: ...his win words read from the book")
  eq(so.trainerB and so.trainerB.defeatText, "BRUNO: argh", "tower seated: ...his lose words the start's")
  eq(bEntry and bEntry.playerId, "solo_foe_b", "tower seated: B's referee entry")
  eq(so.npcPartyB, bEntry and bEntry.mons, "tower seated: the very sheets B's entry holds")
  eq(so.rules and so.rules.bag, false, "tower seated: BAG refused on the screen")
  eq(so.rules and so.rules.forfeit, true, "tower seated: RUN asks to forfeit")
  eq(so.victorySong, "MUS_VICTORY_TRAINER", "tower seated: the Frontier's victory jingle")
  eq(so.song, "MUS_B_TOWER", "tower seated: the hall's battle theme")
  local fight = solo.fight
  check(fight and fight.partner3 ~= nil and fight.pair3 ~= nil, "tower seated: the screen seats both")
  eq(fight and fight.victorySong3, "MUS_VICTORY_TRAINER", "tower seated: ...and holds the jingle")
  eq(solo.gen3.noDexSeen, true, "tower seated: no dex 'seen' for a Frontier foe")
  eq(solo.gen3.noPickup, true, "tower seated: no Pickup")
  solo:reset()
end)

block("tower multi classic pics", function()
  local f = towerMulti()
  check(f.taken, "tower pics: taken")
  local fight = f.solo.fight
  -- The intro, before anybody of ours is out: both our trainers by their
  -- front pics, flipped, low (pret battle_controller_player.c:2304).
  local m = fight:gen3ClassicModel()
  eq(m.playerBack, nil, "tower pics: not the page's one centred back")
  local figs = {}
  for _, fig in ipairs(m.figures3 or {}) do
    if fig.who == "partner" or fig.who == "player" then figs[fig.who] = fig end
  end
  local pf, me = figs.partner, figs.player
  check(pf and pf.kind == "front", "tower pics: the partner by his FRONT pic")
  eq(pf and pf.pic, 44, "tower pics: ...his own")
  eq(pf and pf.x, 32, "tower pics: ...at x 32")
  check(me and me.kind == "front", "tower pics: the player by their own FRONT pic")
  eq(me and me.pic, 71, "tower pics: ...TRAINER_PIC_BRENDAN for a boy (PlayerGenderToFrontTrainerPicId)")
  eq(me and me.x, 90, "tower pics: ...at x 90")
  eq(pf and pf.y, 128, "tower pics: both at y 80 + y2 48")
  eq(me and me.y, 128, "tower pics: ...the player too")
  check(pf and pf.flip and me and me.flip, "tower pics: both flipped (hFlip = 1)")
  eq(pf and pf.clipY, 112, "tower pics: cut where the message box covers them")
  local asked = false
  for _, a in ipairs(constAsks) do
    if a.kind == "trainer_classes" and a.name == "TRAINER_PIC_BRENDAN" then asked = true end
  end
  check(asked, "tower pics: the player's pic read through the engine's constants")
  -- A girl's.
  R.session().gender = 1
  local mg = fight:gen3ClassicModel()
  local girl
  for _, fig in ipairs(mg.figures3 or {}) do if fig.who == "player" then girl = fig end end
  eq(girl and girl.pic, 72, "tower pics: TRAINER_PIC_MAY for a girl")
  R.session().gender = 0
  -- Drawn: mirrored about the centre, only the rows above the box.
  local draws = {}
  local oldLove = rawget(_G, "love")
  local Battlefield = R.need("Battlefield")
  local realPic = Battlefield.gen3TrainerPic
  Battlefield.gen3TrainerPic = function(pic)
    return setmetatable({ tag = "trainer" .. tostring(pic) },
      { __index = { getDimensions = function() return 64, 64 end } })
  end
  _G.love = { graphics = {
    setColor = function() end,
    newQuad = function(x, y, w, h, sw, sh) return { x = x, y = y, w = w, h = h, sw = sw, sh = sh } end,
    draw = function(img, a, b, c, d, e, g)
      if type(a) == "table" then
        draws[#draws + 1] = { img = img, quad = a, x = b, y = c, sx = e }
      else
        draws[#draws + 1] = { img = img, x = a, y = b }
      end
    end,
  } }
  local okDraw, drew = pcall(fight.drawFigures3, fight, m)
  _G.love = oldLove
  Battlefield.gen3TrainerPic = realPic
  check(okDraw and drew, "tower pics: the figures draw (" .. tostring(drew) .. ")")
  local front = nil
  for _, d in ipairs(draws) do if d.quad and d.sx == -1 then front = front or d end end
  check(front ~= nil, "tower pics: a front pic is drawn mirrored")
  eq(front and front.quad.h, 16, "tower pics: ...its top 16 rows (112 - 96), the rest under the box")
  eq(front and front.x, 32 - 32 + 64, "tower pics: ...the mirror's origin on its right edge")
  eq(front and front.y, 96, "tower pics: ...its top at 128 - 32")
  -- Steven keeps his backs (the field's partner fight, unchanged).
  local x0, y0, rows, flip = CoopBattle.figureRect3({ x = 90, y = 80 }, 64, 64)
  eq(table.concat({ x0, y0, rows, tostring(flip) }, ","), "58,48,64,false",
     "tower pics: an unclipped, unflipped figure is the whole pic, centred")
  f.solo:reset()
end)

-- ===================================================================
-- 4. a Tower multi, ended
-- ===================================================================

block("tower multi won", function()
  slid = {}
  local f = towerMulti()
  check(f.taken, "tower won: taken")
  local s = R.session()
  local money = s.money
  local exp0 = f.mine[1].exp
  local solo = f.solo
  local sim = solo.sim
  local fight = solo.fight
  local events = {}
  local onEvent = fight.onEvent
  fight.onEvent = function(self, ev)
    events[#events + 1] = ev
    return onEvent(self, ev)
  end
  R.playDouble(solo)
  check(solo.fight == nil, "tower won: the fight ended")
  eq(table.concat(f.rec.heard, ","), "win", "tower won: the hall's continuation hears 'win'")
  eq(f.rec.code, 1, "tower won: ...B_OUTCOME_WON (VAR_RESULT 1)")
  eq(s.battleOutcome, 1, "tower won: gBattleOutcome 1 saved")
  eq(#f.rec.party, 4, "tower won: the partner's two are back behind the player's before the script reads the party")
  check(f.rec.party[3] == f.partner[1] and f.rec.party[4] == f.partner[2],
        "tower won: ...his own monster tables, in his order")
  local allySheets = sim.byId.solo_ally.mons
  eq(f.partner[1].hp, allySheets[1].hp, "tower won: ...with the fight's damage on them (gPlayerParty[3..])")
  eq(s.money, money, "tower won: no prize (the Frontier pays none)")
  eq(f.mine[1].exp, exp0, "tower won: no EXP")
  local anyExp = false
  for _, ev in ipairs(events) do if ev.t == "exp" then anyExp = true end end
  check(not anyExp, "tower won: ...the referee sent none")
  local log = fight.textLog or {}
  local idx = R.indexIn(log, "STRINGID_TWOENEMIESDEFEATED")
  check(idx ~= nil, "tower won: both trainers defeated, in the cart's words")
  check(R.indexIn(log, "ALICE: I lost...", idx or 1) ~= nil, "tower won: ...A's lose text")
  check(R.indexIn(log, "BRUNO: argh", idx or 1) ~= nil, "tower won: ...B's")
  check(not R.contains(log, "STRINGID_PLAYERGOTMONEY"), "tower won: no money line")
  check(not R.contains(log, "PLAYERDEFEATEDTRAINER1"), "tower won: not a lone trainer's defeated line")
  eq(slid[1] and slid[1].which, "pair", "tower won: the screen's pair ending says it (" .. slidText() .. ")")
  local jingle = false
  for _, c in ipairs(R.audioCalls) do if c[1] == "playSong" and c[2] == SONGS.MUS_VICTORY_TRAINER then jingle = true end end
  check(jingle, "tower won: MUS_VICTORY_TRAINER played")
  eq(s.frontier and s.frontier.disableRecordBattle, 1, "tower won: no battle recording offered")
  local lfb = s.lastFrontierBattle
  check(type(lfb) == "table" and lfb ~= f.rec.stale, "tower won: lastFrontierBattle is this fight's, over the engine's stale one")
  local sp = lfb and lfb.playerSpecies
  check(sp == 16 or sp == 29, "tower won: ...the player's battler (" .. tostring(sp) .. ")")
  local op = lfb and lfb.opponentSpecies
  check(op == 16 or op == 29, "tower won: ...A's (" .. tostring(op) .. ")")
  eq(#R.FakeDex.seen, 0, "tower won: no dex 'seen'")
  check(not R.contains(R.fieldCalls(), "respawn"), "tower won: no whiteout")
  eq(R.FakeVm.halted, 0, "tower won: no script halted")
end)

block("tower multi: the partner fights on", function()
  slid = {}
  -- The player's two at 1 HP with nothing that hurts: the sandstorm takes
  -- each at a turn's end; the partner's two are the ones who win.
  local f = towerMulti({
    weather = 8,
    mine = { mon(16, 30, { moves = { 45 }, hp = 1 }), mon(29, 30, { moves = { 45 }, hp = 1 }) },
    partner = { his(5, 40, { 300 }), his(151, 40, { 300 }) },
    foes = { mon(16, 30, { moves = { 45 }, otId = 1 }), mon(29, 30, { moves = { 45 }, otId = 1 }),
             mon(5, 30, { moves = { 45 }, otId = 2 }), mon(263, 30, { moves = { 45 }, otId = 2 }) },
  })
  check(f.taken, "fights on: taken")
  local sim = f.solo.sim
  R.playDouble(f.solo)
  check(f.solo.fight == nil, "fights on: the fight ended")
  local mineUp = false
  for _, sh in ipairs(sim.byId.solo_player.mons) do if (sh.hp or 0) > 0 then mineUp = true end end
  check(not mineUp, "fights on: every monster of the player's went down")
  eq(table.concat(f.rec.heard, ","), "win",
     "fights on: ...and the partner won it anyway (no Steven: the fight is not lost with the player's half)")
  eq(f.mine[1].hp, 0, "fights on: the player's fainted monsters written home")
  R.FakeWeather.id = 0
end)

block("tower multi lost", function()
  slid = {}
  local f = towerMulti({
    weather = 8,
    mine = { mon(16, 30, { moves = { 45 }, hp = 1 }), mon(29, 30, { moves = { 45 }, hp = 1 }) },
    partner = { his(4, 5, { 45 }), his(151, 5, { 45 }) },
    foes = { mon(16, 40, { moves = { 300 }, otId = 1 }), mon(29, 40, { moves = { 300 }, otId = 1 }),
             mon(5, 40, { moves = { 300 }, otId = 2 }), mon(263, 40, { moves = { 300 }, otId = 2 }) },
  })
  check(f.taken, "tower lost: taken")
  local s = R.session()
  local money = s.money
  local solo = f.solo
  local fight = solo.fight
  R.playDouble(solo)
  check(solo.fight == nil, "tower lost: the fight ended")
  eq(table.concat(f.rec.heard, ","), "lose", "tower lost: the hall's continuation hears 'lose'")
  eq(f.rec.code, 2, "tower lost: ...B_OUTCOME_LOST")
  check(not R.contains(R.fieldCalls(), "respawn"), "tower lost: no whiteout (the challenge's script answers it)")
  eq(s.money, money, "tower lost: no money taken")
  eq(R.healCalls(), 0, "tower lost: nobody healed here")
  local log = fight.textLog or {}
  check(not R.contains(log, "STRINGID_PLAYERWHITEOUT"), "tower lost: no whiteout lines")
  local a = R.indexIn(log, "ALICE: I won!")
  local b = R.indexIn(log, "BRUNO: Ha!")
  check(a ~= nil, "tower lost: A's win words")
  check(a and b and b > a, "tower lost: ...then B's (read from the book)")
  eq(slidText(), "a:ALICE: I won! | b:BRUNO: Ha!", "tower lost: each said with its trainer slid in, A then B")
  eq(#f.rec.party, 4, "tower lost: the partner's two back behind the player's")
  eq(f.partner[1].hp, 0, "tower lost: ...his fainted monsters fainted there too (gPlayerParty[3..] as the fight left it)")
  eq(f.partner[2].hp, 0, "tower lost: ...both")
  eq(R.FakeVm.halted, 0, "tower lost: no script halted")
  R.FakeWeather.id = 0
end)

block("tower multi draw", function()
  slid = {}
  -- Every monster on the field at 1 HP with nothing that hurts: the
  -- sandstorm takes all four at each turn's end, and the last of both sides
  -- fall together (pret Cmd_checkteamslost sets both bits: B_OUTCOME_DREW).
  local f = towerMulti({
    weather = 8,
    mine = { mon(16, 30, { moves = { 45 }, hp = 1 }), mon(29, 30, { moves = { 45 }, hp = 1 }) },
    partner = { his(4, 30, { 45 }, { hp = 1 }), his(151, 30, { 45 }, { hp = 1 }) },
    foes = { mon(16, 30, { moves = { 45 }, otId = 1, hp = 1 }), mon(29, 30, { moves = { 45 }, otId = 1, hp = 1 }),
             mon(5, 30, { moves = { 45 }, otId = 2, hp = 1 }), mon(263, 30, { moves = { 45 }, otId = 2, hp = 1 }) },
  })
  check(f.taken, "tower draw: taken")
  local s = R.session()
  local money = s.money
  R.playDouble(f.solo)
  check(f.solo.fight == nil, "tower draw: the fight ended")
  eq(table.concat(f.rec.heard, ","), "draw", "tower draw: the hall's continuation hears 'draw', never the trainer-script halt")
  eq(f.rec.code, 3, "tower draw: ...B_OUTCOME_DREW (VAR_RESULT 3)")
  eq(s.battleOutcome, 3, "tower draw: gBattleOutcome 3 saved")
  eq(R.FakeVm.halted, 0, "tower draw: no script halted")
  check(not R.contains(R.fieldCalls(), "respawn"), "tower draw: no whiteout")
  eq(s.money, money, "tower draw: no money moved")
  eq(slidText(), "a:ALICE: I won! | b:BRUNO: Ha!",
     "tower draw: both trainers' win words, as a loss says them (HandleEndTurn_BattleLost)")
  eq(#f.rec.party, 4, "tower draw: the partner's two back")
  R.FakeWeather.id = 0
end)

block("tower multi forfeit", function()
  slid = {}
  local f = towerMulti()
  check(f.taken, "tower forfeit: taken")
  local s = R.session()
  local solo = f.solo
  local fight = solo.fight
  -- Up to the first command menu; RUN; the cart's question; YES.
  for _ = 1, 600 do
    R.doubleFrame(solo, false)
    if fight.phase == "choose" and not fight:boxLive() then break end
  end
  eq(fight.phase, "choose", "tower forfeit: the action menu")
  local filed = {}
  local choose = solo._choose
  solo._choose = function(self, payload)
    local ok = choose(self, payload)
    filed[#filed + 1] = { action = payload.action, seat = payload.seat, ok = ok }
    return ok
  end
  local function press(key)
    R.game().input = R.fakeInput(key)
    fight:update(1 / 60)
    R.game().input = R.fakeInput()
  end
  fight.commandIndex = 4
  press("a")
  eq(fight.runAsk and fight.runAsk.role, "forfeit", "tower forfeit: RUN asks to forfeit the match")
  fight:update(1.0)
  fight.runAsk.index = 1
  press("a")
  solo._choose = choose
  local run = filed[1]
  eq(run and run.action, "run", "tower forfeit: YES files the seat's RUN")
  eq(run and run.ok, true, "tower forfeit: ...taken (the Frontier's forfeit, not the trainer-RUN refusal)")
  R.playDouble(solo)
  eq(table.concat(f.rec.heard, ","), "forfeited", "tower forfeit: done('forfeited')")
  eq(s.battleOutcome, 9, "tower forfeit: B_OUTCOME_FORFEITED")
  eq(#slid, 0, "tower forfeit: nobody slides in to speak")
  check(not R.contains(R.fieldCalls(), "respawn"), "tower forfeit: no whiteout")
  eq(#f.rec.party, 4, "tower forfeit: the partner's two back")
end)

block("tower multi handed back", function()
  local f = towerMulti()
  check(f.taken, "tower back: taken")
  eq(#R.session().party, 2, "tower back: the player's two while the mod fights")
  f.solo:reset()
  eq(#f.starts, 1, "tower back: the cart's own battle is started")
  eq(f.starts[1], 4, "tower back: ...over the party the engine left (his two behind the player's)")
  eq(R.session().party[3], f.partner[1], "tower back: ...his own monsters, in place")
  eq(#f.rec.heard, 0, "tower back: the hall is not answered by the mod")
  eq(Multi.handBack({ stand = f.stand }), false, "tower back: handBack lets the core start the cart's")
  eq(#R.session().party, 4, "tower back: ...and puts nothing back twice")
end)

-- ===================================================================
-- 5. the Pike's two-trainer room
-- ===================================================================

block("pike double seated", function()
  local f = pikeDouble()
  check(f.taken, "pike seated: solo takes the room (" .. tostring(f.why) .. " / " .. table.concat(warns, " / ") .. ")")
  local sim = f.solo.sim
  eq(f.stand and f.stand.facility3, "pike", "pike seated: a Pike fight")
  eq(table.concat(Solo.sideIds3(sim, "a"), ","), "solo_player,solo_player#2", "pike seated: the player's two seats")
  eq(table.concat(Solo.sideIds3(sim, "b"), ","), "solo_foe,solo_foe_b", "pike seated: side b is A, then B")
  local fa, fb = sim.byId.solo_foe, sim.byId.solo_foe_b
  eq(#fa.mons, 1, "pike seated: A fields one (FillFrontierTrainersParties(1))")
  eq(#fb.mons, 1, "pike seated: B fields one")
  eq(fa.slot, 3, "pike seated: A on slot 3")
  eq(fb.slot, 4, "pike seated: B on slot 4")
  eq(sim.byId.solo_ally, nil, "pike seated: no partner")
  local r = R.lastCreate().rules or {}
  check(r.bag == false and r.forfeit == true and r.exp == false, "pike seated: the Frontier's rules")
  local so = R.lastScreen() or {}
  eq(so.partner, nil, "pike seated: the screen is told no partner")
  eq(so.trainerB and so.trainerB.trainerName, "BRUNO", "pike seated: the second trainer")
  eq(so.victorySong, "MUS_VICTORY_TRAINER", "pike seated: the Frontier's jingle")
  local npcs = f.solo.gen3.npcs
  check(npcs.solo_foe.noItems and npcs.solo_foe_b.noItems, "pike seated: no items for either")
  eq(npcs.solo_ally, nil, "pike seated: no partner mind")
  f.solo:reset()
end)

block("pike double won", function()
  slid = {}
  local f = pikeDouble()
  check(f.taken, "pike won: taken")
  local s = R.session()
  local money = s.money
  local sim = f.solo.sim
  local fight = f.solo.fight
  R.playDouble(f.solo)
  eq(table.concat(f.rec.heard, ","), "win", "pike won: done('win')")
  eq(s.money, money, "pike won: no prize")
  eq(R.healCalls(), 0, "pike won: no heal (the Pike carries the damage into the next room)")
  local same = true
  for _, sh in ipairs(sim.byId.solo_player.mons) do
    local m = s.party[(sh.slot or 0) + 1]
    if not (m and m.hp == sh.hp) then same = false end
  end
  check(same, "pike won: every monster's HP home exactly as the fight left it")
  check(R.indexIn(fight.textLog or {}, "STRINGID_TWOENEMIESDEFEATED") ~= nil, "pike won: both defeated")
  check(R.contains(fight.textLog or {}, "BRUNO: argh"), "pike won: ...B's lose words")
end)

block("pike double lost", function()
  slid = {}
  local f = pikeDouble({
    mine = { mon(16, 5, { moves = { 45 }, hp = 3 }), mon(29, 5, { moves = { 45 }, hp = 3 }) },
    foes = { mon(16, 40, { moves = { 300 }, otId = 1 }), mon(5, 40, { moves = { 300 }, otId = 2 }) },
  })
  check(f.taken, "pike lost: taken")
  R.playDouble(f.solo)
  eq(table.concat(f.rec.heard, ","), "lose", "pike lost: done('lose')")
  eq(slidText(), "a:ALICE: I won! | b:BRUNO: Ha!", "pike lost: A's win words, then B's, each slid in")
  check(not R.contains(R.fieldCalls(), "respawn"), "pike lost: no whiteout")
end)

block("pike double with one monster standing", function()
  local f = pikeDouble({ mine = { mon(16, 30, { moves = { 300 } }), mon(29, 30, { moves = { 300 }, hp = 0 }) } })
  eq(f.taken, false, "pike one: the room is the cart's (pret AtLeastTwoAliveMons)")
  eq(#f.starts, 0, "pike one: nothing was started by the mod's stand-in")
  eq(f.solo.fight, nil, "pike one: no screen")
end)

-- ===================================================================
-- 6. a Battle Palace double, on the double screen
-- ===================================================================

-- The Palace's tables, as the engine's f2_data reads them off the cart
-- (synthetic numbers): every nature 60 / 80 / 20 / 40, targets and flavor
-- lines by nature.
local PALACE = { moveGroupLikelihood = {}, moveTarget = {}, flavorTextId = {} }
for n = 1, 25 do
  PALACE.moveGroupLikelihood[n] = { 60, 80, 20, 40 }
  PALACE.moveTarget[n] = (n - 1) % 3
  PALACE.flavorTextId[n] = (n - 1) % 4
end
package.loaded["src.core.game3.rse.frontier.f2_data"] = { palace = function() return PALACE end }

block("palace double through the core", function()
  check(CoopBattle.SOLO_DOUBLE_PALACE3 == true, "palace double: the double screen files the Palace pick")
  R.newGame("emerald")
  local s = R.session()
  local mine = { mon(16, 30, { moves = { 300, 45 }, nature = 0 }), mon(29, 30, { moves = { 300, 45 }, nature = 3 }),
                 mon(4, 30, { moves = { 300, 45 }, nature = 6 }) }
  for _, m in ipairs(mine) do s.party[#s.party + 1] = m end
  local foes = { mon(16, 5, { moves = { 45 }, otId = 1, nature = 0 }), mon(29, 5, { moves = { 45 }, otId = 1, nature = 1 }),
                 mon(5, 5, { moves = { 45 }, otId = 1, nature = 2 }) }
  local opts = {
    wild = false, frontier = true, palace = true, double = true, aiFlags = 7,
    trainerItems = { 0, 0, 0, 0 }, scriptedLoss = true,
    trainerName = "ALICE", trainerPicId = 40,
    defeatText = "ALICE: I lost...", victoryText = "ALICE: I won!",
    frontierTrainer = { class = 60, className = "COOLTRAINER", name = "ALICE", pic = 40 },
  }
  local solo = R.newSolo()
  local rec = frontierDone()
  local taken, stand, why = offer(solo, frontierFoe(foes), opts, rec.done)
  check(taken, "palace double: taken (" .. tostring(why) .. " / " .. table.concat(warns, " / ") .. ")")
  if not taken then return end
  eq(stand and stand.facility3, "palace", "palace double: a Battle Palace fight")
  local fight = solo.fight
  check(fight and fight.soloDouble, "palace double: on the double screen")
  check(fight and fight.palace3 and type(fight.palace3.pick) == "function",
        "palace double: the screen holds the Palace's pick")
  check(solo.sim and solo.sim.rules and solo.sim.rules.palace ~= nil, "palace double: the referee plays the Palace")
  eq(table.concat(Solo.sideIds3(solo.sim, "a"), ","), "solo_player,solo_player#2", "palace double: two seats of ours")
  -- Every pick the screen asks for, and every choice the screen itself files.
  local picks, own = {}, {}
  local pick = fight.palace3.pick
  fight.palace3.pick = function(screen, field)
    local took = pick(screen, field)
    picks[#picks + 1] = { field = field, took = took }
    return took
  end
  local choose = solo._choose
  solo._choose = function(self, payload)
    own[#own + 1] = payload.action
    return choose(self, payload)
  end
  local movesOpened = false
  for _ = 1, 6000 do
    if not solo.fight then break end
    if fight.phase == "move" or fight.phase == "target" then movesOpened = true end
    if not R.doubleFrame(solo, true) then break end
  end
  solo._choose = choose
  check(solo.fight == nil, "palace double: the fight ended")
  check(#picks >= 2, "palace double: FIGHT asked the Palace's pick (" .. #picks .. ")")
  local fields, allTook = {}, true
  for _, p in ipairs(picks) do
    fields[p.field] = true
    if p.took ~= true then allTook = false end
  end
  check(fields[0] and fields[1], "palace double: ...for each seat by its field slot (0 and 1)")
  check(allTook, "palace double: ...and every pick went (the nature's, filed by the facility)")
  check(not movesOpened, "palace double: no move list or target was ever opened")
  local fought = false
  for _, a in ipairs(own) do if a == "fight" then fought = true end end
  check(not fought, "palace double: the screen filed no move of its own")
  eq(#rec.heard, 1, "palace double: the hall's continuation answered once")
  check(rec.heard[1] == "win" or rec.heard[1] == "lose" or rec.heard[1] == "draw",
        "palace double: ...with the facility's word (" .. tostring(rec.heard[1]) .. ")")
  eq(R.FakeVm.halted, 0, "palace double: no script halted")
end)

-- ===================================================================
-- 7. off Emerald
-- ===================================================================

block("off Emerald", function()
  local f = towerMulti({ cart = "firered" })
  eq(f.taken, false, "off Emerald: FireRed has no Battle Frontier multi")
  eq(#R.session().party, 4, "off Emerald: the partner's monsters given back to the party")
end)

eq(#warns, 0, "nothing warned that a scenario did not ask for: " .. table.concat(warns, " / "))

T.finish("gen3_solo_multi")
