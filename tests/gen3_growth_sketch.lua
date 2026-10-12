-- Regression coverage for Gen 3 growth/Sketch through the real clients,
-- wire reader, Lua hub and solo referee. Synthetic; no ROM or display.
local ROOT = (arg[0]:match('^(.*)/tests/[^/]+$')) or '.'
local mod = { generation = 3, game = { generation = 3 }, id = 'rby_mmo',
  log = { warn = function() end, info = function() end, error = function() end },
  options = { get = function() end } }
local cache = {}
local function need(name)
  if cache[name] then return cache[name] end
  cache[name] = assert(loadfile(ROOT .. '/src/' .. name .. '.lua'))(need, mod)
  return cache[name]
end
local passed = 0
local function eq(a, b, label)
  assert(a == b, label .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a))
  passed = passed + 1
end
local Turn, Wire = need('BattleSim3/Turn'), need('Wire')
local Med, Coop, Hub, Solo = need('MediatedBattle'), need('CoopBattle'), need('Hub'), need('SoloBattle')
local Gen3, Sheet = need('Gen3'), need('Sheet3')
local function move(id, num, effect, power)
  return { id = id, num = num, effect = effect or 0, power = power or 1,
    accuracy = 100, pp = 20, maxPp = 20, type = 0, chance = 0, target = 0, priority = 0, flags = 0 }
end
local function mon(row, speed)
  return { generation = 3, species = 'MON', speciesNum = 235, level = 10,
    hp = 30, maxHp = 30, stats = { atk = 10, def = 100, spe = speed or 10, spa = 10, spd = 100 },
    types = { 0 }, ability = 0, heldItem = 0, gender = 'M', moves = { row or move('TACKLE', 33) } }
end
local function battle(mode, seats, owner)
  return assert(Turn.create({ id = 'regression', mode = mode or 'coop_npc', seed = 1,
    sides = { a = { { playerId = owner or 'a', seats = seats, mons = { mon(), mon() } } },
      b = { { playerId = 'b', mons = { mon() } } } } }))
end
local stats = { atk = 20, def = 110, spe = 20, spa = 20, spd = 110 }
local function growth()
  return { battle = 'regression', mon = 0, moves = { move('TACKLE', 33) },
    level = 11, maxHp = 35, stats = stats }
end
-- Both ownership boundaries carry growth to the real turn machine.
for _, path in ipairs({ 'hub', 'solo' }) do
  local owner = path == 'solo' and 'solo_player' or 'a'
  local sim = battle(nil, 2, owner)
  local fighter = sim.byId[owner]
  fighter.mons[1].hp = 7
  local payload = assert(Wire.battleMoveset(growth(), 3))
  eq(payload.stats and payload.stats.spe, 20, path .. ': the wire retains Gen 3 stats')
  if path == 'hub' then
    local hub = Hub.new({ generation = 3 })
    eq(hub:applyBattleMoveset({ sim = sim, mode = 'coop_npc' }, { id = owner }, payload), true, 'hub takes growth')
  else
    local solo = setmetatable({ sim = sim }, Solo)
    eq(solo:_applyMoveset3(payload), true, 'solo takes growth')
  end
  eq(fighter.mons[1].level, 11, path .. ': level')
  eq(fighter.mons[1].hp, 12, path .. ': damage is kept; only the HP delta is added')
  eq(fighter.b.stats.atk, 20, path .. ': live attack')
  eq(sim:levelUp(owner, 2, 11, stats, 35), true, path .. ': second double seat grows')
  eq(fighter.seats[2].b.stats.atk, 20, path .. ': second double seat stats')
end
local sim = battle()
local f = sim.byId.a
f.b.stages.atk = 2
f.b.transformed, f.b.overlay = true, true
f.b.stats = { atk = 120, def = 120, spe = 120, spa = 120, spd = 120 }
eq(sim:levelUp('a', 1, 11, stats, 35), true, 'a transformed mon grows')
eq(f.mons[1].stats.atk, 20, 'own stats grow under Transform')
eq(f.b.stats.atk, 120, 'Transform stats stay copied')
eq(f.b.stages.atk, 2, 'stages survive growth')
eq(sim:levelUp('a', 1, 11, stats, 35), false, 'repeat claims cannot heal')
eq(sim:levelUp('b', 1, 11, stats, 35), false, 'foe cannot grow')
eq(battle('1v1'):levelUp('a', 1, 11, stats, 35), false, 'PvP cannot grow')
eq(sim:levelUp('a', 2, 11, { atk = 20 }, 35), false, 'partial stats are refused')
eq(f.mons[2].level, 10, 'bad claims mutate nothing')
-- Send a successful Sketch through the real single-screen event handler.
local sketch, tackle = move('SKETCH', 166, 95, 0), move('TACKLE', 33)
local sketchSim = assert(Turn.create({ id = 'regression', mode = 'coop_npc', seed = 1,
  sides = { a = { { playerId = 'a', mons = { mon(sketch, 1) } } },
    b = { { playerId = 'b', mons = { mon(tackle, 100) } } } } }))
sketchSim:drainEvents()
assert(sketchSim:submitChoice('a', { action = 'fight', move = 0 }))
assert(sketchSim:submitChoice('b', { action = 'fight', move = 0 }))
local learned
for _, event in ipairs(sketchSim:drainEvents()) do
  if event.t == 'moves' and event.slot == 0 and event.moves[1].num == 33 then learned = event end
end
assert(learned, 'the referee successfully sketches the target move')
for _, mode in ipairs({ 'coop_npc', '1v1' }) do
  local saved = { species = 235, moves = { 166 }, pp = { 1 }, maxPp = { 1 }, ppBonusesPacked = 7 }
  local screen = Med.new({ battle = 'regression', game = { generation = 3 }, mode = mode })
  screen.mine, screen.active = { mon(sketch) }, 1
  screen.saveMon = function() return saved end
  learned.seq = 1
  screen:onEvent(learned)
  eq(screen.mine[1].moves[1].num, 33, mode .. ': FIGHT shows the sketched move')
  eq(saved.moves[1], mode == '1v1' and 166 or 33, mode .. ': only NPC fights write Sketch home')
  eq(saved.ppBonusesPacked, mode == '1v1' and 7 or 4, mode .. ': Sketch clears only its PP Up bits')
  if mode ~= '1v1' then eq(saved.pp[1], learned.moves[1].pp, 'Sketch PP is saved') end
end
-- A save that keeps all four slots (0 for empty, as Gen3Save.fromPortMon
-- writes them) still takes Sketch home: row j is the j-th known move.
do
  local saved = { species = 235, moves = { 166, 0, 0, 0 }, pp = { 1, 0, 0, 0 },
    maxPp = { 1, 0, 0, 0 }, ppBonusesPacked = 7 }
  local screen = Med.new({ battle = 'regression', game = { generation = 3 }, mode = 'coop_npc' })
  screen.mine, screen.active = { mon(sketch) }, 1
  screen.saveMon = function() return saved end
  learned.seq = 1
  screen:onEvent(learned)
  eq(screen.mine[1].moves[1].num, 33, 'padded save: FIGHT shows the sketched move')
  eq(saved.moves[1], 33, 'padded save: Sketch is written home')
  eq(saved.moves[2], 0, 'padded save: the empty slots stay empty')
  eq(saved.ppBonusesPacked, 4, 'padded save: only slot 1 loses its PP Up bits')
  -- The empty slot first: the known move sits in save slot 2.
  local gap = { moves = { 0, 166, 0, 0 }, pp = { 0, 1, 0, 0 }, maxPp = { 0, 1, 0, 0 },
    ppBonusesPacked = 2 + 3 * 4 }
  eq(Sheet.sketchHome(gap, { sketch }, learned.moves) ~= nil, true, 'gap save: Sketch is taken')
  eq(gap.moves[2], 33, 'gap save: written onto the slot that held SKETCH')
  eq(gap.moves[1], 0, 'gap save: the empty slot is untouched')
  eq(gap.ppBonusesPacked, 2, "gap save: slot 2's PP Up bits clear, slot 1's survive")
  -- Row-shaped save slots keep their shape.
  local rows = { moves = { { id = 166, pp = 1, maxPp = 1 } } }
  eq(Sheet.sketchHome(rows, { sketch }, learned.moves) ~= nil, true, 'row save: Sketch is taken')
  eq(type(rows.moves[1]), 'table', 'row save: the slot stays a row')
  eq(rows.moves[1].id, 33, 'row save: its id is the sketched move')
  -- A save whose known moves disagree with the referee's rows is refused.
  local other = { moves = { 166, 33, 0, 0 } }
  eq(Sheet.sketchHome(other, { sketch }, learned.moves), nil, 'mismatched save: nothing written')
  eq(other.moves[1], 166, 'mismatched save: untouched')
end
-- A double event can name the second seat and a non-leading save slot.
for _, mode in ipairs({ 'coop_npc', 'coop_pvp' }) do
  local saved = { species = 235, moves = { 166 }, pp = { 1 }, maxPp = { 1 } }
  local live = { mon = saved, curMoves = { sketch } }
  local seats = { { party = { {}, saved }, battler = {} }, { party = { {}, saved }, battler = live } }
  local screen = setmetatable({ gen3 = true, mediated = true, battleId = 'regression', mode = mode,
    mine = 1, ownSlots = { 1, 2 }, medMine = { { slot = 1, moves = { sketch } } },
    medSeq = 0, medGaps = 0, medSlots = { [1] = 2 },
    sim = { slot = function(_, i) return seats[i] end } }, Coop)
  screen:onBattleEvent({ battle = 'regression', seq = 1, t = 'moves', slot = 1, mon = 0, moves = learned.moves })
  eq(live.curMoves[1].num, 33, mode .. ': the second seat menu is refreshed')
  eq(saved.moves[1], mode == 'coop_pvp' and 166 or 33, mode .. ': double Sketch writeback')
end
-- Client growth is sent even if the new level teaches nothing.
Gen3.moveInfo = function(num)
  if num == 33 then return { name = 'TACKLE', constName = 'MOVE_TACKLE', pp = 20,
    effect = 0, power = 1, type = 0, accuracy = 100, target = 0, priority = 0, flags = 0 } end
end
local saved = { species = 235, level = 11, hp = 12, maxHp = 35, attack = 20, defense = 110,
  speed = 20, spAtk = 20, spDef = 110, moves = { 33 }, pp = { 15 }, maxPp = { 20 } }
local sent
local transport = { send = function(_, kind, payload)
  if kind == Wire.BATTLE_MOVESET then sent = payload end
  return true
end }
local screen = Med.new({ battle = 'regression', game = { generation = 3 }, mode = 'coop_npc', transport = transport })
screen.mine, screen.active, screen.saveMon = { mon() }, 1, function() return saved end
screen:levelled3(saved, 'MON', { 11 })
eq(sent.level, 11, 'single: a no-learn level sends growth')
eq(sent.stats.atk, 20, 'single: flat save stats reach the wire')
eq(sent.maxHp, 35, 'single: maximum HP reaches the wire')
sent = nil
local seat = { party = { saved }, battler = { mon = saved } }
local double = setmetatable({ gen3 = true, mediated = true, game = { generation = 3 }, mode = 'coop_npc',
  battleId = 'regression', transport = transport, mine = 1, medMine = { mon() }, messages = {},
  sim = { slot = function() return seat end }, say = function() end,
  sheetIndexFor = function() return 1 end }, Coop)
double:levelled3(saved, 'MON', { 11 })
eq(sent.level, 11, 'double: a no-learn level sends growth')
-- The actual hello sender must carry Crystal, rather than a hand-built hello.
need('Transport').new = function() return { send = function(_, _, payload) sent = payload; return true end } end
local Client, Gen = need('Client'), need('Gen')
Gen.generation, Gen.version = function() return 2 end, function() return 'crystal' end
Client.playerName, Client.playerId = function() return 'ANN' end, function() return string.rep('a', 32) end
Client.spriteChoice, Client.profile = function() return 'SPRITE_CHRIS' end, function() return {} end
Client.sendHello({ generation = 2 })
eq(sent.version, 'crystal', 'Crystal cart reaches the real hello')
local crystalHub = Hub.new({ generation = 2 })
local peer = { send = function() end, close = function() end }
local client = assert(crystalHub:accept(peer))
sent.type = Wire.HELLO
crystalHub:receive(client, sent)
eq(client.version, 'crystal', 'the Lua hub admits the actual client cart')
print(string.format('%d/%d checks passed (gen3_growth_sketch)', passed, passed))
