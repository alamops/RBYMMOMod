-- The Lua half of the hub protocol's cross-runtime parity check.
--
-- Run: luajit tests/drivers/hub_protocol_parity.lua .        (from this root)
--
-- Drives src/Hub.lua through a fixed set of scenarios and prints a JSON
-- digest of the wire-visible outcomes on stdout. server/hub_protocol_parity.test.js
-- builds the same scenarios against server/lib/relay.js and asserts equality.
-- It spawns this file when luajit is on PATH and falls back to
-- tests/fixtures/hub_protocol_parity.json -- this script's own committed
-- output -- when it is not.
--
-- These scenarios are not a sample of every hub behaviour. They are the seats
-- where Hub.lua and relay.js can disagree about identity, admit, or ranked
-- settlement -- the places a client would notice which hosting path refereed
-- them. BattleSim event streams stay in battle_turn_parity; this file is the
-- hub envelope around that.
--
-- Standalone: no love, no engine, no mod facade. Synthetic fixtures only.
--
-- Invoked as: luajit <this file> <repo root>
-- Regenerate:
--   luajit tests/drivers/hub_protocol_parity.lua . > tests/fixtures/hub_protocol_parity.json

local ROOT = arg and arg[1] or "."

local function slurp(path)
  local handle = io.open(path, "rb")
  if not handle then return nil end
  local body = handle:read("*a")
  handle:close()
  return body
end

local loadstr = loadstring or load
local cache = {}
local function need(name)
  if cache[name] ~= nil then return cache[name] end
  local path = ROOT .. "/src/" .. name .. ".lua"
  local body = slurp(path)
  if not body then error("missing " .. path, 0) end
  local chunk, err = loadstr(body, "@" .. name .. ".lua")
  if not chunk then error(tostring(err), 0) end
  cache[name] = chunk(need)
  return cache[name]
end

local Config = need("Config")
local Wire = need("Wire")
local Hub = need("Hub")

-- ------------------------------------------------------------------
-- canonical JSON out (same shape as battle_turn_parity.lua)
-- ------------------------------------------------------------------

local function encString(s)
  local body = s:gsub('[%c"\\]', function(c)
    if c == '"' then return '\\"' end
    if c == '\\' then return '\\\\' end
    if c == '\n' then return '\\n' end
    if c == '\r' then return '\\r' end
    if c == '\t' then return '\\t' end
    return string.format('\\u%04x', c:byte())
  end)
  return '"' .. body .. '"'
end

local function encNumber(n)
  if n == math.floor(n) then return string.format("%d", n) end
  return string.format("%.17g", n)
end

local function encScalar(v)
  local t = type(v)
  if t == "nil" then return "null" end
  if t == "boolean" then return v and "true" or "false" end
  if t == "number" then return encNumber(v) end
  if t == "string" then return encString(v) end
  error("cannot encode " .. t, 0)
end

local function isArray(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then return false end
    if k > n then n = k end
  end
  for i = 1, n do
    if t[i] == nil then return false end
  end
  return true
end

local enc
enc = function(v)
  local t = type(v)
  if t ~= "table" then return encScalar(v) end
  if isArray(v) then
    local parts = {}
    for i = 1, #v do parts[i] = enc(v[i]) end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  local keys = {}
  for k in pairs(v) do
    if type(k) == "string" then keys[#keys + 1] = k end
  end
  table.sort(keys)
  local parts = {}
  for i, k in ipairs(keys) do
    parts[i] = encString(k) .. ":" .. enc(v[k])
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

-- ------------------------------------------------------------------
-- fixtures
-- ------------------------------------------------------------------

-- Fixed ids so Lua and JS digests share the same keys (not derived hashes).
local ID_A = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
local ID_B = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
local ID_C = "cccccccccccccccccccccccccccccccc"
local ID_D = "dddddddddddddddddddddddddddddddd"

local CHART = { { 100, 100 }, { 100, 100 } }

local function fakePeer()
  local peer = { outbox = {}, closed = false }
  function peer:send(msg) self.outbox[#self.outbox + 1] = msg end
  function peer:close() self.closed = true end
  return peer
end

local function take(peer, msgType)
  for i, msg in ipairs(peer.outbox) do
    if msg.type == msgType then return table.remove(peer.outbox, i) end
  end
  return nil
end

local function takeAll(peer, msgType)
  local out = {}
  for _ = 1, 64 do
    local msg = take(peer, msgType)
    if not msg then break end
    out[#out + 1] = msg
  end
  return out
end

local function move(o)
  o = o or {}
  return {
    id = o.id or "thump",
    pp = o.pp or 20,
    power = o.power or 200,
    accuracy = o.accuracy or 255,
    type = 0, effect = 0, chance = 0,
  }
end

local function mon(o)
  o = o or {}
  return {
    species = o.species or "ALPHA",
    level = o.level or 50,
    hp = o.hp or 300,
    maxHp = o.maxHp or o.hp or 300,
    stats = {
      atk = o.atk or 200, def = o.def or 200,
      spd = o.spd or 100, spc = o.spc or 100,
    },
    moves = { move({ power = o.power }) },
  }
end

local function bruiser() return mon({ atk = 999, spd = 999, power = 200 }) end
local function glassjaw() return mon({ species = "BETA", hp = 1, def = 1, spd = 1, power = 20 }) end

local function makeHub()
  local hub = Hub.new({ maxPlayers = 8 })
  hub.forceBattleSeed = 1
  return hub
end

local function dial(hub, name, playerId)
  local peer = fakePeer()
  local client = hub:accept(peer)
  hub:receive(client, {
    type = Wire.HELLO, proto = Config.PROTOCOL,
    name = name, map = "PALLET", x = 5, y = 5, facing = "down",
    playerId = playerId, sprite = Config.DEFAULT_SPRITE,
  })
  return { client = client, peer = peer, id = client.id, name = name }
end

local function slimOutcome(msg)
  if not msg then return nil end
  return {
    outcome = msg.outcome,
    reason = msg.reason,
    winners = msg.winners,
    losers = msg.losers,
  }
end

local function slimBoard(hub)
  local rows = hub.board:export()
  local out = {}
  for i, row in ipairs(rows) do
    out[i] = {
      id = row.id,
      name = row.name,
      points = row.points,
      played = row.played,
      won = row.won,
    }
  end
  return out
end

local function slimWelcome(msg)
  if not msg then return nil end
  return {
    id = msg.id,
    ranked = msg.ranked == true,
    points = msg.points,
    -- claim tickets must not ride welcome under PROTOCOL 16
    claim = msg.claim,
    ticket = msg.ticket,
  }
end

local function slimRefuse(msg)
  if not msg then return nil end
  return { message = msg.message }
end

local function openFight(hub, a, b)
  hub:receive(a.client, { type = Wire.REQUEST, to = b.id, kind = "battle" })
  hub:receive(b.client, { type = Wire.RESPOND, to = a.id, kind = "battle", accept = true })
  local id = a.client.sessionId
  local hostSess = take(a.peer, Wire.SESSION)
  local guestSess = take(b.peer, Wire.SESSION)
  return {
    id = id,
    hostRole = hostSess and hostSess.role,
    guestRole = guestSess and guestSess.role,
  }
end

local function uploadReady(hub, a, b, battleId, aMons, bMons)
  hub:receive(a.client, {
    type = Wire.BATTLE_RULESET, battle = battleId, chart = CHART,
  })
  hub:receive(a.client, {
    type = Wire.BATTLE_PARTY, battle = battleId, mons = aMons or { bruiser() },
  })
  hub:receive(b.client, {
    type = Wire.BATTLE_PARTY, battle = battleId, mons = bMons or { glassjaw() },
  })
  take(a.peer, Wire.BATTLE_READY)
  take(b.peer, Wire.BATTLE_READY)
end

local function fightItOut(hub, a, b, battleId)
  for _ = 1, 30 do
    if not hub.battles[battleId] then break end
    takeAll(a.peer, Wire.BATTLE_EVENT)
    takeAll(b.peer, Wire.BATTLE_EVENT)
    hub:receive(a.client, {
      type = Wire.BATTLE_CHOICE, battle = battleId, action = "fight", move = 0,
    })
    hub:receive(b.client, {
      type = Wire.BATTLE_CHOICE, battle = battleId, action = "fight", move = 0,
    })
  end
  return take(a.peer, Wire.BATTLE_OUTCOME) or take(b.peer, Wire.BATTLE_OUTCOME)
end

-- ------------------------------------------------------------------
-- scenarios
-- ------------------------------------------------------------------

local scenarios = {}

scenarios[#scenarios + 1] = {
  name = "admit_welcome",
  run = function()
    local hub = makeHub()
    local a = dial(hub, "ANN", ID_A)
    local welcome = take(a.peer, Wire.WELCOME)
    return {
      welcome = slimWelcome(welcome),
      clientId = a.id,
      board = slimBoard(hub),
    }
  end,
}

scenarios[#scenarios + 1] = {
  name = "refuse_duplicate_id",
  run = function()
    local hub = makeHub()
    dial(hub, "ANN", ID_A)
    local peer = fakePeer()
    local client = hub:accept(peer)
    hub:receive(client, {
      type = Wire.HELLO, proto = Config.PROTOCOL,
      name = "ANN2", map = "PALLET", x = 1, y = 1, facing = "down",
      playerId = ID_A, sprite = Config.DEFAULT_SPRITE,
    })
    return {
      refuse = slimRefuse(take(peer, Wire.ERROR) or take(peer, "mmo.error")),
      closed = peer.closed == true,
    }
  end,
}

scenarios[#scenarios + 1] = {
  name = "refuse_wrong_proto",
  run = function()
    local hub = makeHub()
    local peer = fakePeer()
    local client = hub:accept(peer)
    hub:receive(client, {
      type = Wire.HELLO, proto = Config.PROTOCOL - 1,
      name = "OLD", map = "PALLET", x = 1, y = 1, facing = "down",
      playerId = ID_C, sprite = Config.DEFAULT_SPRITE,
    })
    return {
      refuse = slimRefuse(take(peer, Wire.ERROR) or take(peer, "mmo.error")),
      protocol = Config.PROTOCOL,
    }
  end,
}

scenarios[#scenarios + 1] = {
  name = "mediated_ko_settle",
  run = function()
    local hub = makeHub()
    local a = dial(hub, "HOST", ID_A)
    local b = dial(hub, "GUEST", ID_B)
    take(a.peer, Wire.WELCOME)
    take(b.peer, Wire.WELCOME)
    takeAll(a.peer, Wire.JOIN)
    takeAll(b.peer, Wire.JOIN)
    local sess = openFight(hub, a, b)
    a.peer.outbox = {}
    b.peer.outbox = {}
    uploadReady(hub, a, b, sess.id)
    a.peer.outbox = {}
    b.peer.outbox = {}
    local outcome = fightItOut(hub, a, b, sess.id)
    return {
      session = sess,
      outcome = slimOutcome(outcome),
      board = slimBoard(hub),
      battleGone = hub.battles[sess.id] == nil,
    }
  end,
}

scenarios[#scenarios + 1] = {
  name = "mediated_forfeit_disconnect",
  run = function()
    local hub = makeHub()
    local a = dial(hub, "STAYA", ID_A)
    local b = dial(hub, "DROPB", ID_B)
    take(a.peer, Wire.WELCOME)
    take(b.peer, Wire.WELCOME)
    takeAll(a.peer, Wire.JOIN)
    takeAll(b.peer, Wire.JOIN)
    local sess = openFight(hub, a, b)
    a.peer.outbox = {}
    b.peer.outbox = {}
    uploadReady(hub, a, b, sess.id, {
      mon({ atk = 40, def = 40, spd = 40, power = 40, hp = 100 }),
    }, {
      mon({ species = "BETA", atk = 40, def = 40, spd = 40, power = 40, hp = 100 }),
    })
    a.peer.outbox = {}
    b.peer.outbox = {}
    hub:drop(b.client)
    hub:update(Config.BATTLE_RECONNECT_GRACE + 2)
    local outcome = take(a.peer, Wire.BATTLE_OUTCOME)
    return {
      session = sess,
      outcome = slimOutcome(outcome),
      board = slimBoard(hub),
      battleGone = hub.battles[sess.id] == nil,
    }
  end,
}

scenarios[#scenarios + 1] = {
  name = "relay_hard_cut_in_battle",
  run = function()
    local hub = makeHub()
    local a = dial(hub, "HOST", ID_A)
    local b = dial(hub, "GUEST", ID_B)
    take(a.peer, Wire.WELCOME)
    take(b.peer, Wire.WELCOME)
    takeAll(a.peer, Wire.JOIN)
    takeAll(b.peer, Wire.JOIN)
    local sess = openFight(hub, a, b)
    a.peer.outbox = {}
    b.peer.outbox = {}
    uploadReady(hub, a, b, sess.id)
    a.peer.outbox = {}
    b.peer.outbox = {}
    hub:receive(a.client, {
      type = Wire.RELAY, to = b.id, payload = { hello = 1 },
    })
    return {
      session = sess,
      guestRelay = take(b.peer, Wire.RELAY) ~= nil,
      hostRelayDrops = a.client.relayDrops or 0,
    }
  end,
}

scenarios[#scenarios + 1] = {
  name = "ranking_carries_player_id",
  run = function()
    local hub = makeHub()
    local a = dial(hub, "HOST", ID_A)
    local b = dial(hub, "GUEST", ID_B)
    take(a.peer, Wire.WELCOME)
    take(b.peer, Wire.WELCOME)
    takeAll(a.peer, Wire.JOIN)
    takeAll(b.peer, Wire.JOIN)
    local sess = openFight(hub, a, b)
    a.peer.outbox = {}
    b.peer.outbox = {}
    uploadReady(hub, a, b, sess.id)
    a.peer.outbox = {}
    b.peer.outbox = {}
    fightItOut(hub, a, b, sess.id)
    a.peer.outbox = {}
    hub:receive(a.client, { type = Wire.RANKS })
    local ranking = take(a.peer, Wire.RANKING)
    local entries = {}
    for _, row in ipairs((ranking and ranking.entries) or {}) do
      entries[#entries + 1] = {
        id = row.id, name = row.name, points = row.points,
      }
    end
    return { entries = entries }
  end,
}

scenarios[#scenarios + 1] = {
  name = "bag_proof_hold_and_cancel",
  run = function()
    local hub = makeHub()
    local a = dial(hub, "ANN", ID_A)
    local b = dial(hub, "BOB", ID_B)
    take(a.peer, Wire.WELCOME)
    take(b.peer, Wire.WELCOME)
    takeAll(a.peer, Wire.JOIN)
    takeAll(b.peer, Wire.JOIN)
    local sess = openFight(hub, a, b)
    a.peer.outbox = {}
    b.peer.outbox = {}
    hub:receive(a.client, {
      type = Wire.BATTLE_RULESET, battle = sess.id, chart = CHART,
    })
    hub:receive(a.client, {
      type = Wire.BATTLE_PARTY, battle = sess.id,
      mons = { mon({ hp = 40, maxHp = 100, power = 40 }) },
      bag = { { id = "NOT_A_REAL_ITEM", count = 1 } },
    })
    local unknownRefused = hub.battles[sess.id].parties[a.id] == nil
    hub:receive(a.client, {
      type = Wire.BATTLE_PARTY, battle = sess.id,
      mons = { mon({ hp = 40, maxHp = 100, power = 40 }) },
      bag = { { id = "POTION", count = 1 } },
    })
    hub:receive(b.client, {
      type = Wire.BATTLE_PARTY, battle = sess.id,
      mons = { mon({ species = "BETA", hp = 100, power = 40 }) },
    })
    local record = hub.battles[sess.id]
    hub:receive(a.client, {
      type = Wire.BATTLE_CHOICE, battle = sess.id,
      action = "item", item = "POTION",
    })
    local held = record.bagHold[a.id] == "POTION"
      and record.bags[a.id].POTION == 1
    hub:receive(a.client, {
      type = Wire.BATTLE_CHOICE, battle = sess.id, action = "cancel",
    })
    return {
      unknownRefused = unknownRefused,
      heldThenCancelled = held
        and record.bagHold[a.id] == nil
        and record.bags[a.id].POTION == 1,
      simOpen = record.sim ~= nil,
    }
  end,
}

scenarios[#scenarios + 1] = {
  name = "sprite_and_chat_gates",
  run = function()
    local hub = makeHub()
    local a = dial(hub, "ANN", ID_A)
    local b = dial(hub, "BOB", ID_B)
    take(a.peer, Wire.WELCOME)
    take(b.peer, Wire.WELCOME)
    takeAll(a.peer, Wire.JOIN)
    takeAll(b.peer, Wire.JOIN)
    a.peer.outbox = {}
    b.peer.outbox = {}
    hub:receive(a.client, { type = Wire.SPRITE, sprite = "SPRITE_BLUE" })
    local firstSprite = a.client.sprite
    hub:receive(a.client, { type = Wire.SPRITE, sprite = "SPRITE_YELLOW" })
    local gatedSprite = a.client.sprite
    hub:receive(a.client, {
      type = Wire.CHAT, scope = "local", text = "hello once",
    })
    local firstChat = take(b.peer, Wire.CHAT) ~= nil
    hub:receive(a.client, {
      type = Wire.CHAT, scope = "local", text = "hello twice",
    })
    local gatedChat = take(b.peer, Wire.CHAT) == nil
    hub:update(Config.CHAT_GATE + 0.1)
    hub:receive(a.client, { type = Wire.SPRITE, sprite = "SPRITE_YELLOW" })
    local afterGraceSprite = a.client.sprite
    return {
      firstSprite = firstSprite,
      gatedSprite = gatedSprite,
      firstChat = firstChat,
      gatedChat = gatedChat,
      afterGraceSprite = afterGraceSprite,
    }
  end,
}

scenarios[#scenarios + 1] = {
  name = "coop_pvp_team_settle",
  run = function()
    local hub = makeHub()
    local a = dial(hub, "A1", ID_A)
    local b = dial(hub, "A2", ID_B)
    local c = dial(hub, "B1", ID_C)
    local d = dial(hub, "B2", ID_D)
    takeAll(a.peer, Wire.WELCOME)
    takeAll(b.peer, Wire.WELCOME)
    takeAll(c.peer, Wire.WELCOME)
    takeAll(d.peer, Wire.WELCOME)
    takeAll(a.peer, Wire.JOIN)
    takeAll(b.peer, Wire.JOIN)
    takeAll(c.peer, Wire.JOIN)
    takeAll(d.peer, Wire.JOIN)
    local id = "c1"
    hub:openCoopBattle(id, { a.id, b.id, c.id, d.id }, {
      mode = "coop_pvp", hostId = a.id,
      sides = { a = { a.id, b.id }, b = { c.id, d.id } },
    })
    local function side(players)
      local out = {}
      for _, p in ipairs(players) do
        out[#out + 1] = { id = p.id, name = p.name, ranked = true }
      end
      return out
    end
    hub.coopMatches[id] = {
      a = side({ a, b }), b = side({ c, d }),
      reports = {}, everyone = { a.id, b.id, c.id, d.id },
      startedAt = hub.clock,
    }
    hub:receive(a.client, {
      type = Wire.BATTLE_RULESET, battle = id, chart = CHART,
    })
    for _, p in ipairs({ a, b }) do
      hub:receive(p.client, {
        type = Wire.BATTLE_PARTY, battle = id, mons = { bruiser() },
      })
    end
    for _, p in ipairs({ c, d }) do
      hub:receive(p.client, {
        type = Wire.BATTLE_PARTY, battle = id, mons = { glassjaw() },
      })
    end
    local seats = {
      { client = a.client, peer = a.peer, battle = id },
      { client = b.client, peer = b.peer, battle = id },
      { client = c.client, peer = c.peer, battle = id },
      { client = d.client, peer = d.peer, battle = id },
    }
    a.peer.outbox = {}
    b.peer.outbox = {}
    c.peer.outbox = {}
    d.peer.outbox = {}
    for _ = 1, 30 do
      if not hub.battles[id] then break end
      for _, seat in ipairs(seats) do
        takeAll(seat.peer, Wire.BATTLE_EVENT)
        hub:receive(seat.client, {
          type = Wire.BATTLE_CHOICE, battle = id, action = "fight", move = 0,
        })
      end
    end
    local outcome = take(a.peer, Wire.BATTLE_OUTCOME)
      or take(b.peer, Wire.BATTLE_OUTCOME)
    return {
      outcome = slimOutcome(outcome),
      board = slimBoard(hub),
      battleGone = hub.battles[id] == nil,
      mode = "coop_pvp",
    }
  end,
}

-- Complete Party-vs-NPC (2xNPC): two humans + trainer seats, fight to KO.
scenarios[#scenarios + 1] = {
  name = "coop_npc_team_settle",
  run = function()
    local hub = makeHub()
    local a = dial(hub, "NPCA", ID_A)
    local b = dial(hub, "NPCB", ID_B)
    takeAll(a.peer, Wire.WELCOME)
    takeAll(b.peer, Wire.WELCOME)
    takeAll(a.peer, Wire.JOIN)
    takeAll(b.peer, Wire.JOIN)
    local id = "c1"
    hub:openCoopBattle(id, { a.id, b.id }, {
      mode = "coop_npc", hostId = a.id,
    })
    local record = hub.battles[id]
    local npcIds = record and record.npcIds or {}
    hub:receive(a.client, {
      type = Wire.BATTLE_RULESET, battle = id, chart = CHART,
    })
    hub:receive(a.client, {
      type = Wire.BATTLE_PARTY, battle = id, side = "a", mons = { bruiser() },
    })
    hub:receive(b.client, {
      type = Wire.BATTLE_PARTY, battle = id, side = "a", mons = { bruiser() },
    })
    hub:receive(a.client, {
      type = Wire.BATTLE_PARTY, battle = id, side = "b",
      mons = { glassjaw(), glassjaw() },
    })
    a.peer.outbox = {}
    b.peer.outbox = {}
    for _ = 1, 30 do
      if not hub.battles[id] then break end
      takeAll(a.peer, Wire.BATTLE_EVENT)
      takeAll(b.peer, Wire.BATTLE_EVENT)
      for _, p in ipairs({ a, b }) do
        hub:receive(p.client, {
          type = Wire.BATTLE_CHOICE, battle = id, action = "fight", move = 0,
        })
      end
    end
    local outcome = take(a.peer, Wire.BATTLE_OUTCOME)
      or take(b.peer, Wire.BATTLE_OUTCOME)
    return {
      outcome = slimOutcome(outcome),
      battleGone = hub.battles[id] == nil,
      mode = "coop_npc",
      npcSeats = #npcIds,
      npcA = npcIds[1],
      npcB = npcIds[2],
    }
  end,
}

-- ------------------------------------------------------------------

local runs = {}
for _, scenario in ipairs(scenarios) do
  runs[#runs + 1] = {
    name = scenario.name,
    result = scenario.run(),
  }
end

io.write(enc(runs))
io.write("\n")
