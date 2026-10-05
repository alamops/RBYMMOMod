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

-- The invite, end to end: the busy a roster row is drawn from, the reason a
-- refusal carries, and two asks that crossed.
--
-- Every field here is one a client reads to decide whether to *offer* a
-- battle or what to say when one comes back, so a one-sided drift is a
-- refusal that reads correctly on one hosting path and as a snub on the
-- other -- for the same event, with nothing in the game to tell them apart.
--
-- The reason is normalised to a sentinel rather than left absent: a nil field
-- vanishes from a Lua table, and "no key" and "null" are not the same value
-- to the comparison on the far side.
local function slimDecline(msg)
  if not msg then return { absent = true } end
  return {
    kind = msg.kind,
    reason = msg.reason or "(none)",
    named = msg.name ~= nil,
  }
end

scenarios[#scenarios + 1] = {
  name = "invite_busy_reason_and_cross",
  run = function()
    local hub = makeHub()
    local a = dial(hub, "ASKER", ID_A)
    local b = dial(hub, "ASKED", ID_B)
    take(a.peer, Wire.WELCOME); take(b.peer, Wire.WELCOME)
    takeAll(a.peer, Wire.JOIN); takeAll(b.peer, Wire.JOIN)
    a.peer.outbox, b.peer.outbox = {}, {}

    -- A client's own word on being mid-fight, which no hub can see for itself
    hub:receive(b.client, { type = Wire.MOVE, map = "PALLET", x = 6, y = 5,
                            facing = "down", busy = true })
    local busyMove = take(a.peer, Wire.MOVE)
    hub:receive(b.client, { type = Wire.MOVE, map = "PALLET", x = 6, y = 5,
                            facing = "down", busy = "yes" })
    local looseMove = take(a.peer, Wire.MOVE)
    a.peer.outbox, b.peer.outbox = {}, {}

    -- An ask nobody is there to answer
    hub:receive(a.client, { type = Wire.REQUEST, to = "nobodyatall",
                            kind = "battle" })
    local gone = slimDecline(take(a.peer, Wire.DECLINE))
    a.peer.outbox, b.peer.outbox = {}, {}

    -- A refusal that carries why, and one that made its reason up
    hub:receive(a.client, { type = Wire.REQUEST, to = b.id, kind = "battle" })
    take(b.peer, Wire.REQUEST)
    hub:receive(b.client, { type = Wire.RESPOND, to = a.id, kind = "battle",
                            accept = false, reason = "fighting" })
    local reasoned = slimDecline(take(a.peer, Wire.DECLINE))

    hub:receive(a.client, { type = Wire.REQUEST, to = b.id, kind = "battle" })
    take(b.peer, Wire.REQUEST)
    hub:receive(b.client, { type = Wire.RESPOND, to = a.id, kind = "battle",
                            accept = false, reason = "your mother" })
    local forged = slimDecline(take(a.peer, Wire.DECLINE))
    a.peer.outbox, b.peer.outbox = {}, {}

    -- Two invites that crossed are an agreement, not a collision
    hub:receive(a.client, { type = Wire.REQUEST, to = b.id, kind = "battle" })
    hub:receive(b.client, { type = Wire.REQUEST, to = a.id, kind = "battle" })
    local crossA, crossB = take(a.peer, Wire.SESSION), take(b.peer, Wire.SESSION)
    local crossed = {
      id = crossA and crossA.id or "(none)",
      askerRole = crossA and crossA.role or "(none)",
      answererRole = crossB and crossB.role or "(none)",
      refusals = #takeAll(a.peer, Wire.DECLINE) + #takeAll(b.peer, Wire.DECLINE),
    }

    return {
      busy = busyMove and busyMove.busy == true,
      looseBusy = looseMove and looseMove.busy == true,
      gone = gone,
      reasoned = reasoned,
      forged = forged,
      crossed = crossed,
    }
  end,
}

scenarios[#scenarios + 1] = {
  name = "invite_busy_mediated_fight",
  run = function()
    local hub = makeHub()
    local a = dial(hub, "HOST", ID_A)
    local b = dial(hub, "ALLY", ID_B)
    local c = dial(hub, "ASKER", ID_C)
    take(a.peer, Wire.WELCOME); take(b.peer, Wire.WELCOME); take(c.peer, Wire.WELCOME)
    takeAll(a.peer, Wire.JOIN); takeAll(b.peer, Wire.JOIN); takeAll(c.peer, Wire.JOIN)
    a.peer.outbox, b.peer.outbox, c.peer.outbox = {}, {}, {}

    hub:receive(c.client, { type = Wire.REQUEST, to = b.id, kind = "trade" })
    take(b.peer, Wire.REQUEST)
    a.peer.outbox, b.peer.outbox, c.peer.outbox = {}, {}, {}
    hub:openCoopBattle("c-busy", { a.client.id, b.client.id },
      { mode = "coop_npc", hostId = a.client.id })
    local published = take(c.peer, Wire.MOVE)
    b.peer.outbox, c.peer.outbox = {}, {}
    hub:receive(b.client, { type = Wire.RESPOND, to = c.id, kind = "trade",
                            accept = true })
    local stacked = slimDecline(take(c.peer, Wire.DECLINE))
    local stackedSession = take(c.peer, Wire.SESSION) or take(b.peer, Wire.SESSION)
    c.peer.outbox, b.peer.outbox = {}, {}
    hub:receive(c.client, { type = Wire.REQUEST, to = b.id, kind = "battle" })
    local midFight = slimDecline(take(c.peer, Wire.DECLINE))
    local reached = take(b.peer, Wire.REQUEST)
    b.peer.outbox, c.peer.outbox = {}, {}
    hub:receive(b.client, { type = Wire.REQUEST, to = c.id, kind = "trade" })
    local fromFighter = take(c.peer, Wire.REQUEST)
    return {
      hadSession = b.client.sessionId ~= nil,
      publishedBusy = published and published.busy == true,
      stacked = stacked,
      stackedSession = stackedSession ~= nil,
      midFight = midFight,
      reachedFighter = reached ~= nil,
      fromFighter = fromFighter ~= nil,
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
-- generation lock (PROTOCOL 20, widened to 3 by PROTOCOL 30)
-- ------------------------------------------------------------------
--
-- One Gen 3 hub seats FireRed, LeafGreen and Emerald together and refuses
-- every other generation; Gen 1 and Gen 2 hubs refuse Gen 3.  The seat a
-- client would notice is the refusal *sentence* and who ends up on whose
-- roster, so those are what the digest keeps.  Map ids and sprite names are
-- synthetic engine-shaped strings -- nothing here is read off a cart.

local ID_E = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
local ID_F = "ffffffffffffffffffffffffffffffff"

local function makeGenHub(generation)
  local hub = Hub.new({ maxPlayers = 8, generation = generation })
  hub.forceBattleSeed = 1
  return hub
end

-- A hello with the generation fields spelled out.  `generation` and
-- `version` are passed through untouched -- nil stays absent -- because
-- "missing" is itself one of the cases being pinned.
local function dialAs(hub, name, playerId, o)
  local peer = fakePeer()
  local client = hub:accept(peer)
  hub:receive(client, {
    type = Wire.HELLO, proto = Config.PROTOCOL,
    name = name, map = o.map or "PALLET", x = 5, y = 5, facing = "down",
    playerId = playerId, sprite = o.sprite,
    generation = o.generation, version = o.version,
  })
  return { client = client, peer = peer, id = client.id, name = name }
end

-- The fields of a presence the generation work touches.  Absent is a
-- sentinel rather than nil for the reason slimDecline's reason is: a nil
-- vanishes from a Lua table, and "no key" and "null" are not the same value
-- to the comparison on the far side.
local function slimPresence(p)
  if not p then return { absent = true } end
  return {
    id = p.id,
    name = p.name,
    sprite = p.sprite or "(none)",
    version = p.version or "(none)",
    map = p.map or "(none)",
  }
end

local function slimRoster(players)
  local out = {}
  for _, p in ipairs(players or {}) do out[#out + 1] = slimPresence(p) end
  table.sort(out, function(x, y) return x.id < y.id end)
  return out
end

-- What one hello got back: refused with which sentence, or admitted.
local function outcomeOf(side)
  local refuse = take(side.peer, Wire.ERROR)
  local welcome = take(side.peer, Wire.WELCOME)
  return {
    admitted = welcome ~= nil,
    refuse = refuse and refuse.message or "(none)",
    closed = side.peer.closed == true,
  }
end

scenarios[#scenarios + 1] = {
  name = "generation_gen3_hub_seats_every_gen3_cart",
  run = function()
    local hub = makeGenHub(3)
    local fr = dialAs(hub, "LEAF", ID_A, {
      generation = 3, version = "firered",
      sprite = "OBJ_EVENT_GFX_GREEN_NORMAL", map = "FR_PALLET_TOWN",
    })
    local frWelcome = take(fr.peer, Wire.WELCOME)
    local em = dialAs(hub, "MAY", ID_B, {
      generation = 3, version = "emerald",
      sprite = "OBJ_EVENT_GFX_MAY_NORMAL", map = "EM_LITTLEROOT_TOWN",
    })
    local emWelcome = take(em.peer, Wire.WELCOME)
    local joinAtFr = take(fr.peer, Wire.JOIN)
    -- LeafGreen with no sprite (the hub stamps the Gen 3 token), and a
    -- Gen 3 client claiming a Gen 1 cart (admitted; the version is not kept)
    local lg = dialAs(hub, "GREEN", ID_C, {
      generation = 3, version = "leafgreen", map = "FR_VIRIDIAN_CITY",
    })
    local lgWelcome = take(lg.peer, Wire.WELCOME)
    local liar = dialAs(hub, "LIAR", ID_D, {
      generation = 3, version = "red",
      sprite = "OBJ_EVENT_GFX_RED_NORMAL", map = "FR_PALLET_TOWN",
    })
    local liarWelcome = take(liar.peer, Wire.WELCOME)
    local laterAtEm = {}
    for _, msg in ipairs(takeAll(em.peer, Wire.JOIN)) do
      laterAtEm[#laterAtEm + 1] = msg.player
    end
    return {
      generation = hub.generation,
      frWelcomed = frWelcome ~= nil,
      emWelcomed = emWelcome ~= nil,
      lgWelcomed = lgWelcome ~= nil,
      liarWelcomed = liarWelcome ~= nil,
      emSees = slimRoster(emWelcome and emWelcome.players),
      frSeesJoin = slimPresence(joinAtFr and joinAtFr.player),
      emSeesLater = slimRoster(laterAtEm),
      liarSees = slimRoster(liarWelcome and liarWelcome.players),
      players = hub.players,
    }
  end,
}

scenarios[#scenarios + 1] = {
  name = "generation_gen3_refused_by_gen1_and_gen2_hubs",
  run = function()
    local gen1 = makeGenHub(1)
    local atGen1 = outcomeOf(dialAs(gen1, "LEAF", ID_A, {
      generation = 3, version = "firered", sprite = "OBJ_EVENT_GFX_GREEN_NORMAL",
    }))
    local gen2 = makeGenHub(2)
    local atGen2 = outcomeOf(dialAs(gen2, "MAY", ID_B, {
      generation = 3, version = "emerald", sprite = "OBJ_EVENT_GFX_MAY_NORMAL",
    }))
    return {
      atGen1 = atGen1, gen1Players = gen1.players,
      atGen2 = atGen2, gen2Players = gen2.players,
    }
  end,
}

scenarios[#scenarios + 1] = {
  name = "generation_gen1_and_gen2_refused_by_gen3_hub",
  run = function()
    local hub = makeGenHub(3)
    local red = outcomeOf(dialAs(hub, "RED", ID_A, {
      generation = 1, version = "red", sprite = Config.DEFAULT_SPRITE,
    }))
    -- A hello that names no generation is the PROTOCOL 20 compat Gen 1, and
    -- a Gen 3 hub refuses it in the Gen 1 sentence rather than guessing 3.
    local legacy = outcomeOf(dialAs(hub, "OLD", ID_B, {
      sprite = Config.DEFAULT_SPRITE,
    }))
    local gold = outcomeOf(dialAs(hub, "GOLD", ID_C, {
      generation = 2, version = "gold", sprite = Config.DEFAULT_SPRITE_GEN2,
    }))
    return { red = red, legacy = legacy, gold = gold, players = hub.players }
  end,
}

scenarios[#scenarios + 1] = {
  name = "generation_unknown_refused_missing_is_gen1",
  run = function()
    local hub = makeGenHub(1)
    local four = outcomeOf(dialAs(hub, "FOUR", ID_A, { generation = 4 }))
    local zero = outcomeOf(dialAs(hub, "ZERO", ID_B, { generation = 0 }))
    local text = outcomeOf(dialAs(hub, "TEXT", ID_C, { generation = "1" }))
    local yes = outcomeOf(dialAs(hub, "YES", ID_D, { generation = true }))
    local legacy = dialAs(hub, "OLD", ID_E, { sprite = Config.DEFAULT_SPRITE })
    local legacyOutcome = outcomeOf(legacy)
    -- A Gen 1 cart's version survives on a Gen 1 hub; a Gen 3 cart's does
    -- not, and costs the hello nothing -- the field is optional.
    local yellow = dialAs(hub, "YELLOW", ID_F, {
      generation = 1, version = "yellow", sprite = Config.DEFAULT_SPRITE,
    })
    local yellowWelcome = take(yellow.peer, Wire.WELCOME)
    local mixed = dialAs(hub, "MIXED", ID_A, {
      generation = 1, version = "emerald", sprite = Config.DEFAULT_SPRITE,
    })
    local mixedWelcome = take(mixed.peer, Wire.WELCOME)
    local joinsAtLegacy = {}
    for _, msg in ipairs(takeAll(legacy.peer, Wire.JOIN)) do
      joinsAtLegacy[#joinsAtLegacy + 1] = msg.player
    end
    return {
      four = four, zero = zero, text = text, yes = yes,
      legacy = legacyOutcome,
      yellowWelcomed = yellowWelcome ~= nil,
      mixedWelcomed = mixedWelcome ~= nil,
      legacySees = slimRoster(joinsAtLegacy),
      players = hub.players,
    }
  end,
}

-- ------------------------------------------------------------------
-- Gen 3 (PROTOCOL 30): a mediated fight on BattleSim3 / lib/battle3, and the
-- Gen 3 dialect of every upload read by Wire.lua and lib/sanitize.js side by
-- side.  The digests carry sentinels rather than nil ("(nil)") for the reason
-- slimPresence does: a nil vanishes from a Lua table where JS keeps a null.
-- ------------------------------------------------------------------

local CHART3 = { 10, 12, 20, 11, 10, 20, 12, 11, 20, -1, -1, 0, 0, 7, 0 }
local POOL3 = { "33:0:40:0:100:35:0:0:0:51:POOL_TAP", "52:4:40:10:100:25:10:0:0:18:POOL_SPARK" }

local function move3(o)
  o = o or {}
  return {
    id = o.id or "TAP3", num = o.num or 33, pp = o.pp or 20, maxPp = o.maxPp or 20,
    power = o.power or 90, type = o.type or 0, accuracy = o.accuracy or 100,
    effect = o.effect or 0, chance = o.chance or 0, target = o.target or 0,
    priority = o.priority or 0, flags = o.flags or 51, name = o.name,
  }
end

local function mon3(o)
  o = o or {}
  return {
    generation = 3, species = o.species or "GAMMA", speciesNum = o.speciesNum or 1,
    level = o.level or 50, hp = o.hp or 150, maxHp = o.maxHp or o.hp or 150,
    stats = { atk = o.atk or 120, def = o.def or 80, spe = o.spe or 90,
              spa = o.spa or 80, spd = o.spd or 80 },
    types = o.types or { 0 }, ability = o.ability or 0,
    heldItem = o.heldItem or 0, holdEffect = o.holdEffect or 0,
    holdEffectParam = o.holdEffectParam or 0, gender = o.gender or "M",
    friendship = 70, weight = 300, nature = 0,
    hiddenPower = { type = 1, power = 50 }, beatUp = { atk = 60, def = 60 },
    catchRate = o.catchRate,
    moves = o.moves or { move3() },
  }
end

local function orNil(v)
  if v == nil then return "(nil)" end
  return v
end

-- The scalar fields of one battle event, sentinel for the absent ones that a
-- Gen 3 referee can set (the `moves` rows are pinned by the sim fixtures).
local EVENT_KEYS = { "t", "text", "amount", "hp", "maxHp", "slot", "side", "status",
  "mon", "target", "spread", "stat", "stage", "delta", "holding", "confused", "team" }

local function slimEvent(e)
  local out = {}
  for _, k in ipairs(EVENT_KEYS) do out[k] = orNil(e[k]) end
  out.moves = e.moves and #e.moves or 0
  return out
end

scenarios[#scenarios + 1] = {
  name = "gen3_mediated_fight",
  run = function()
    local hub = makeGenHub(3)
    local a = dialAs(hub, "ANN", ID_A, { generation = 3, version = "firered",
      sprite = "OBJ_EVENT_GFX_RED_NORMAL", map = "FR_PALLET_TOWN" })
    local b = dialAs(hub, "BOB", ID_B, { generation = 3, version = "emerald",
      sprite = "OBJ_EVENT_GFX_MAY_NORMAL", map = "EM_LITTLEROOT_TOWN" })
    take(a.peer, Wire.WELCOME)
    take(b.peer, Wire.WELCOME)
    takeAll(a.peer, Wire.JOIN)
    takeAll(b.peer, Wire.JOIN)
    local sess = openFight(hub, a, b)
    a.peer.outbox = {}
    b.peer.outbox = {}
    hub:receive(a.client, { type = Wire.BATTLE_RULESET, battle = sess.id,
      generation = 3, typeTable = CHART3, movePool = POOL3, terrain = 3 })
    local hurt = mon3({ atk = 400, def = 400, spe = 300, hp = 100, maxHp = 150,
      moves = { move3({ power = 200 }) } })
    hub:receive(a.client, { type = Wire.BATTLE_PARTY, battle = sess.id, mons = { hurt },
      bag = { { id = 13, count = 2, name = "TONIC" }, { id = "350", count = 1 } } })
    hub:receive(b.client, { type = Wire.BATTLE_PARTY, battle = sess.id,
      mons = { mon3({ species = "DELTA", hp = 1, def = 5, atk = 10, spe = 1,
                      moves = { move3({ power = 10 }) } }) } })
    local record = hub.battles[sess.id]
    local opened = record.sim ~= nil
    hub:receive(a.client, { type = Wire.BATTLE_CHOICE, battle = sess.id,
      action = "item", item = "13", slot = 0 })
    local held = record.bagHold[a.id]
    hub:receive(b.client, { type = Wire.BATTLE_CHOICE, battle = sess.id,
      action = "fight", move = 0 })
    local bagAfter = { potion = orNil(record.bags[a.id]["13"]), flute = orNil(record.bags[a.id]["350"]) }
    local outcome = fightItOut(hub, a, b, sess.id)
    return {
      opened = opened,
      ruleset = { triples = #record.ruleset.typeTable / 3, pool = record.ruleset.movePool,
                  terrain = record.ruleset.terrain },
      held = orNil(held),
      bagAfter = bagAfter,
      outcome = slimOutcome(outcome),
      battleGone = hub.battles[sess.id] == nil,
    }
  end,
}

-- The same fight's opening event stream, event by event: the envelope the
-- hub wraps around BattleSim3 has to hand every client the same stream on
-- both hosting paths.
scenarios[#scenarios + 1] = {
  name = "gen3_event_stream",
  run = function()
    local hub = makeGenHub(3)
    local a = dialAs(hub, "ANN", ID_A, { generation = 3, version = "leafgreen",
      sprite = "OBJ_EVENT_GFX_RED_NORMAL", map = "FR_PALLET_TOWN" })
    local b = dialAs(hub, "BOB", ID_B, { generation = 3, version = "firered",
      sprite = "OBJ_EVENT_GFX_RED_NORMAL", map = "FR_PALLET_TOWN" })
    local sess = openFight(hub, a, b)
    hub:receive(a.client, { type = Wire.BATTLE_RULESET, battle = sess.id,
      typeTable = CHART3 })
    hub:receive(a.client, { type = Wire.BATTLE_PARTY, battle = sess.id,
      mons = { mon3({ ability = 22, types = { 10 }, moves = { move3({ type = 10, effect = 4, chance = 100 }) } }),
               mon3({ species = "ZETA", ability = 2, types = { 11 } }) } })
    hub:receive(b.client, { type = Wire.BATTLE_PARTY, battle = sess.id,
      mons = { mon3({ species = "ETA", ability = 45, types = { 12 },
                      heldItem = 139, holdEffect = 1, holdEffectParam = 10 }) } })
    local events = {}
    for _ = 1, 3 do
      if not hub.battles[sess.id] then break end
      for _, msg in ipairs(takeAll(a.peer, Wire.BATTLE_EVENT)) do events[#events + 1] = slimEvent(msg) end
      hub:receive(a.client, { type = Wire.BATTLE_CHOICE, battle = sess.id, action = "fight", move = 0 })
      hub:receive(b.client, { type = Wire.BATTLE_CHOICE, battle = sess.id, action = "fight", move = 0 })
    end
    for _, msg in ipairs(takeAll(a.peer, Wire.BATTLE_EVENT)) do events[#events + 1] = slimEvent(msg) end
    return { events = events, count = #events }
  end,
}

-- The Gen 3 dialect at the boundary: each input through the Lua sanitiser,
-- and the JS half runs the same inputs through lib/sanitize.
local function dialect3()
  local caught = mon3({ species = "CAUGHT" })
  caught.weight, caught.hiddenPower, caught.beatUp = nil, nil, nil
  caught.ball, caught.personality, caught.otId = 4, 305419896, 4660
  caught.ivs = { hp = 31, atk = 0, def = 1, spe = 2, spa = 3, spd = 4 }
  local noAbility = mon3(); noAbility.ability = nil
  local badGender = mon3(); badGender.gender = "X"
  local named = mon3({ moves = { move3({ name = "Tap Three" }), move3({ id = "B", num = 182,
    power = 0, accuracy = 0, effect = 111, target = 16, priority = 3, flags = 0 }) } })
  named.abilityName, named.itemName, named.sleepTurns, named.status = "BLAZE", "ORAN", 3, "SLP"
  return {
    { "ruleset", { generation = 3, typeTable = CHART3, movePool = POOL3, terrain = 9,
                   weather = "SAND", underwater = false, seed = 99, specialTypes = { 10, 11 } } },
    { "ruleset", { typeTable = CHART3, movePool = { "7:0:40:0:100:10:0:0:-0:3:X", { id = "ROW",
      num = 12, pp = 5, power = 0, accuracy = 0, type = 0, effect = 38, chance = 0, target = 0,
      priority = 0, flags = 2 } } } },
    { "ruleset", { typeTable = { 0, -1, 10 } } },
    { "ruleset", { typeTable = CHART3, movePool = { "+7:0:40:0:100:10:0:0:0:3:X" } } },
    { "ruleset", { typeTable = CHART3, weather = "FOG" } },
    { "ruleset", { typeTable = CHART3, underwater = "yes" } },
    { "ruleset", { movePool = { "999:0:40:0:100:10:0:0:0:3:X" } } },
    { "mon", named },
    { "mon", caught },
    { "mon", noAbility },
    { "mon", badGender },
    { "party", { battle = "b1", mons = { named } } },
    { "party", { battle = "b1", mons = { caught } } },
    { "bag", { { id = 13, count = 2, name = "TONIC" }, { id = "1", count = 1 }, { id = 350, count = 1 } } },
    { "bag", { ["13"] = 2, ["22"] = 1 } },
    { "bag", { { id = "0x0D", count = 1 } } },
    { "bag", { { id = 5, count = 1 } } },
    { "bag", { { id = 13, count = 1 }, { id = "13", count = 1 } } },
    { "choice", { battle = "b1", action = "fight", move = 1, target = 4, pass = 2 } },
    { "choice", { battle = "b1", action = "item", item = "9", dexCaught = true, slot = 0 } },
    { "choice", { battle = "b1", action = "item", item = "9", dexCaught = 1 } },
    { "event", { battle = "b1", seq = 3, t = "stat", slot = 0, side = "a", text = "ATK fell",
                 stat = "atk", stage = -2, delta = -2, amount = 2 } },
    { "event", { battle = "b1", seq = 4, t = "held", slot = 3, side = "b", mon = 0, amount = 139,
                 holding = 0, text = "ORAN BERRY" } },
    { "event", { battle = "b1", seq = 5, t = "ball", slot = 0, side = "a", target = 3, amount = 4, text = "4" } },
    { "event", { battle = "b1", seq = 6, t = "anim", slot = 1, side = "a", text = "SWEEP",
                 target = 4, spread = 1, stat = "hp", stage = 9, delta = -20, holding = 999 } },
    { "event", { battle = "b1", seq = 7, t = "weather", text = "RAIN", amount = 1 } },
    { "event", { battle = "b1", seq = 8, t = "moves", slot = 0, side = "a", moves = { move3(), { id = "OLD",
      pp = 1, power = 1, accuracy = 1, type = 0, effect = 0, chance = 0 } } } },
    { "moveset", { battle = "b1", mon = 0, moves = { move3(), move3({ id = "NEW", num = 44 }) } } },
  }
end

scenarios[#scenarios + 1] = {
  name = "gen3_dialect",
  run = function()
    local out = {}
    for i, case in ipairs(dialect3()) do
      local kind, input = case[1], case[2]
      local got
      if kind == "ruleset" then got = Wire.battleRuleset(input, 3)
      elseif kind == "mon" then got = Wire.battleMon(input)
      elseif kind == "party" then got = Wire.battleParty(input, 3)
      elseif kind == "bag" then got = Wire.battleBag(input, 3)
      elseif kind == "choice" then got = Wire.battleChoice(input, 3)
      elseif kind == "event" then got = Wire.battleEvent(input)
      elseif kind == "moveset" then got = Wire.battleMoveset(input, 3)
      end
      out[i] = { kind = kind, got = orNil(got) }
    end
    return { cases = out }
  end,
}

-- The Gen 3 dialect at the edges where the two twins used to read one message
-- two ways: a list that is an object, a number LuaJIT's tonumber reads and
-- JS's Number does not (or the reverse), a choice index that is `true`.
--
-- And JSON's null inside a list, which the Lua half is never handed at all:
-- src/link/Json.lua appends nothing for a null element and stores nothing for
-- a null value, so `[10, null, 12]` reaches Hub.lua as { 10, 12 }.  A case
-- below spells that null as NULL and `decoded` closes it up the way the
-- engine's decoder does; the JS half hands the same case to lib/sanitize with
-- a real null in it (tests/hub_battle.lua holds the engine decoder to this).
local NULL = setmetatable({}, { __tostring = function() return "null" end })

local function decoded(v)
  if v == NULL then return nil end
  if type(v) ~= "table" then return v end
  local out, top = {}, 0
  for k in pairs(v) do
    if type(k) == "number" and k > top then top = k end
  end
  for i = 1, top do
    if v[i] ~= nil and v[i] ~= NULL then out[#out + 1] = decoded(v[i]) end
  end
  for k, value in pairs(v) do
    if type(k) ~= "number" and value ~= NULL then out[k] = decoded(value) end
  end
  return out
end

local function edges3()
  local chartHole = { 10, 12, 20, NULL, 11, 10, 20, 12, 11, 20, -1, -1, 0, 0, 7, 0 }
  local chartGap = { 10, 12, NULL, 11, 10, 20, 12, 11, 20, -1, -1, 0, 0, 7, 0 }
  return {
    { "ruleset", { typeTable = chartHole } },
    { "ruleset", { typeTable = chartGap } },
    { "ruleset", { typeTable = CHART3, specialTypes = { 10, NULL, 11 } } },
    { "ruleset", { typeTable = CHART3, movePool = { NULL, POOL3[1] } } },
    { "ruleset", { typeTable = CHART3, specialTypes = { a = 1 } } },
    { "ruleset", { typeTable = CHART3, movePool = { a = "x" } } },
    { "ruleset", { typeTable = CHART3, specialTypes = {} } },
    { "ruleset", { typeTable = CHART3, movePool = { a = NULL } } },
    { "ruleset", { typeTable = { a = 10 } } },
    { "mon", mon3({ types = { NULL, 10 } }) },
    { "mon", mon3({ moves = { move3(), NULL } }) },
    { "mon", mon3({ heldItem = "1e-9999999" }) },
    { "mon", mon3({ level = "\194\16050" }) },
    { "mon", mon3({ level = " \t50\n" }) },
    { "mon", mon3({ moves = { move3({ priority = "-0x1" }) } }) },
    { "mon", mon3({ ability = "0x1.8p1", holdEffect = "0b11" }) },
    { "party", { battle = "b1", mons = { mon3(), NULL } } },
    { "party", { battle = "b1", generation = { 3 }, mons = { mon3() } } },
    { "bag", { { id = 13, count = 2 }, NULL } },
    { "bag", { ["13"] = 2, ["22"] = NULL } },
    { "bag", { ["13"] = NULL } },
    { "choice", { battle = "b1", action = "fight", move = 0, pass = true } },
    { "choice", { battle = "b1", action = "fight", move = 0, pass = "" } },
    { "choice", { battle = "b1", action = "fight", move = 0, pass = { 3 } } },
    { "choice", { battle = "b1", action = "switch", slot = true } },
    { "choice", { battle = "b1", action = "fight", move = "0x0", pass = " 2 " } },
    { "moveset", { battle = "b1", mon = 0, moves = { NULL, move3() } } },
    { "moveset", { battle = "b1", mon = true, moves = { move3() } } },
    { "event", { battle = "b1", seq = 9, t = "anim", slot = 0, side = "a", text = "SWEEP",
                 target = true, spread = "", stage = { 1 }, holding = "0x10" } },
  }
end

scenarios[#scenarios + 1] = {
  name = "gen3_wire_edges",
  run = function()
    local out = {}
    for i, case in ipairs(edges3()) do
      local kind, input = case[1], decoded(case[2])
      local got
      if kind == "ruleset" then got = Wire.battleRuleset(input, 3)
      elseif kind == "mon" then got = Wire.battleMon(input)
      elseif kind == "party" then got = Wire.battleParty(input, 3)
      elseif kind == "bag" then got = Wire.battleBag(input, 3)
      elseif kind == "choice" then got = Wire.battleChoice(input, 3)
      elseif kind == "event" then got = Wire.battleEvent(input)
      elseif kind == "moveset" then got = Wire.battleMoveset(input, 3)
      end
      out[i] = { kind = kind, got = orNil(got) }
    end
    return { cases = out }
  end,
}

-- Gen 1 / Gen 2 read paths, as they were before Gen 3 had a dialect: a stray
-- `num` on an older row, and Gen 3's choice fields on an older choice, are
-- ignored rather than read -- on both hosting paths.  The one Gen 3 event
-- field an older reader does keep since contract K10 of
-- docs/plans/gen12-referee-gaps-fix.md is `stage` (the signed stage of a
-- `stat` event), so the Gen 2 read of the `stat` case below carries it.
-- Since that plan's wave 5 two more are Gold's own on a Gen 2 hub: a
-- Metronome pool row's `num` (the cart's move number, so the Gen 2 pool case
-- keeps its 7) and a choice's `pass` (BATON PASS's successor, so the Gen 2
-- choice's unreadable "far" refuses it) -- referee_gaps_wave5_dialect has
-- the rest of their cases.
local function gen12()
  local stray = { id = "thump", pp = 20, power = 40, accuracy = 255, type = 0, effect = 0,
                  chance = 0, num = 7 }
  local sheet = { species = "ALPHA", level = 50, hp = 100, maxHp = 100,
                  stats = { atk = 90, def = 90, spd = 90, spc = 90 }, moves = { stray } }
  local asked = { battle = "b1", action = "fight", move = 0, pass = "far", dexCaught = 1 }
  return {
    { "mon", sheet },
    { "party", { battle = "b1", mons = { sheet } }, 1 },
    { "ruleset", { chart = CHART, metronomePool = { stray } }, 1 },
    { "ruleset", { chart = CHART, metronomePool = { stray } }, 2 },
    { "ruleset", { chart = CHART, metronomePool = { stray } } },
    { "choice", asked, 1 },
    { "choice", asked, 2 },
    { "choice", asked },
    { "event", { battle = "b1", seq = 1, t = "ability" }, 1 },
    { "event", { battle = "b1", seq = 2, t = "stat", slot = 0, side = "a", target = 2,
                 stage = 1, delta = 1, holding = 3 }, 2 },
    { "event", { battle = "b1", seq = 3, t = "moves", slot = 0, side = "a", moves = { stray } }, 1 },
    { "moveset", { battle = "b1", mon = 0, moves = { stray } }, 1 },
  }
end

scenarios[#scenarios + 1] = {
  name = "gen12_read_paths",
  run = function()
    local out = {}
    for i, case in ipairs(gen12()) do
      local kind, input, gen = case[1], case[2], case[3]
      local got
      if kind == "ruleset" then got = Wire.battleRuleset(input, gen)
      elseif kind == "mon" then got = Wire.battleMon(input)
      elseif kind == "party" then got = Wire.battleParty(input, gen)
      elseif kind == "choice" then got = Wire.battleChoice(input, gen)
      elseif kind == "event" then got = Wire.battleEvent(input, gen)
      elseif kind == "moveset" then got = Wire.battleMoveset(input, gen)
      end
      out[i] = { kind = kind, got = orNil(got) }
    end
    return { cases = out }
  end,
}

-- ------------------------------------------------------------------
-- The badge rules' wire (docs/plans/gen3-badge-rules.md K1-K3), each input
-- read by Wire.lua here and lib/sanitize.js there, under the reader's
-- generation (the third field):
--
--   * a Gen 3 party's badge numbers ("1".."8"; the sanitisers keep any id and
--     drop the rest, the referee reads 1..8);
--   * a Gen 3 sheet's `traded` / `unfateful` -- true kept, false dropped,
--     anything else refuses the sheet; the retired `fateful` neither copied
--     nor read;
--   * the `obey` event: each of the eight outcome tokens kept, any other text
--     dropped with the event kept, and the kind refused by a Gen 2 reader;
--   * a Gold party's badge names, Johto and Kanto;
--   * the Gen 1 / Gen 2 ruleset's `typeIds` (the chart's axis by name):
--     1..BATTLE_TYPE_MAX ids, all or nothing, anything unreadable DROPPING the
--     list and keeping the ruleset, a JSON null closed up first (NULL, as
--     `decoded` reads it), a ruleset with none, and never read on Gen 3.
-- ------------------------------------------------------------------

local OBEY_TOKENS = { "ignores_asleep", "uses_random_move", "falls_asleep", "hits_itself",
                      "loafing", "wont_obey", "turned_away", "pretend_not_notice" }

local function badgeRules()
  local function flagged(traded, unfateful)
    local sheet = mon3({ species = "MEW", speciesNum = 151 })
    sheet.traded, sheet.unfateful = traded, unfateful
    return sheet
  end
  local function retired(fateful)
    local sheet = mon3({ species = "MEW", speciesNum = 151 })
    sheet.fateful = fateful
    return sheet
  end
  local gold = { species = "ALPHA", level = 50, hp = 100, maxHp = 100,
                 stats = { atk = 90, def = 90, spe = 90, spa = 90, spd = 90 },
                 moves = { { id = "thump", pp = 20, power = 40, accuracy = 255, type = 0,
                             effect = 0, chance = 0 } } }
  local wide = {}
  for i = 1, Config.BATTLE_TYPE_MAX + 1 do wide[i] = "T" .. i end
  local full = {}
  for i = 1, Config.BATTLE_TYPE_MAX do full[i] = "T" .. i end
  local cases = {
    { "party", { battle = "b1", mons = { mon3() }, badges = { "1", "3", "8" } }, 3 },
    { "party", { battle = "b1", mons = { mon3() },
                 badges = { "1", "3", "8", "3", "9", "bad id!", 5, true, "" } }, 3 },
    { "party", { battle = "b1", mons = { mon3() }, badges = { "bad id!", 7 } }, 3 },
    { "party", { battle = "b1", mons = { flagged(true, true) }, badges = { "2" } }, 3 },
    { "mon", flagged(true, true) },
    { "mon", flagged(false, false) },
    { "mon", flagged(true, nil) },
    { "mon", flagged("yes", nil) },
    { "mon", flagged(nil, 1) },
    { "mon", flagged(nil, true) },
    { "mon", retired(true) },
    { "mon", retired(1) },
    { "party", { battle = "b1", mons = { gold },
                 badges = { "ZEPHYR", "MINERAL", "RISING", "BOULDER", "EARTH" } }, 2 },
    { "party", { battle = "b1", mons = { gold }, badges = { "ZEPHYR", "ZEPHYR", "bad id!" } }, 2 },
    { "ruleset", { chart = CHART, typeIds = { "NORMAL", "FIRE" } }, 2 },
    { "ruleset", { chart = CHART, typeIds = { "NORMAL", "PSYCHIC_TYPE" }, specialTypes = { 1 } }, 1 },
    { "ruleset", { chart = CHART, typeIds = full }, 2 },
    { "ruleset", { chart = CHART, typeIds = wide }, 2 },
    { "ruleset", { chart = CHART, typeIds = { "NORMAL", 7 } }, 2 },
    { "ruleset", { chart = CHART, typeIds = { "NORMAL", "BAD TYPE" } }, 2 },
    { "ruleset", { chart = CHART, typeIds = { "NORMAL", string.rep("X", 41) } }, 2 },
    { "ruleset", { chart = CHART, typeIds = {} }, 2 },
    { "ruleset", { chart = CHART, typeIds = "NORMAL" }, 2 },
    { "ruleset", { chart = CHART, typeIds = { "NORMAL", "mymod.FAIRY" }, specialTypes = { 1 } }, 2 },
    { "ruleset", { chart = CHART, typeIds = { "NORMAL", NULL, "FIRE" } }, 2 },
    { "ruleset", { chart = CHART, typeIds = { NULL, NULL } }, 2 },
    { "ruleset", { chart = CHART, typeIds = { "NORMAL", NULL, "BAD TYPE" } }, 2 },
    { "ruleset", { chart = CHART, specialTypes = { 1 } }, 1 },
    { "ruleset", { chart = CHART }, 2 },
    { "ruleset", { typeTable = CHART3, typeIds = { "NORMAL" } }, 3 },
  }
  for i, token in ipairs(OBEY_TOKENS) do
    cases[#cases + 1] = { "event", { battle = "b1", seq = 20 + i, t = "obey", slot = 0, side = "a",
                                     text = token }, 3 }
  end
  for i, text in ipairs({ "LOAFING", "loafing around", "", 7 }) do
    cases[#cases + 1] = { "event", { battle = "b1", seq = 40 + i, t = "obey", slot = 1, side = "a",
                                     text = text }, 3 }
  end
  cases[#cases + 1] = { "event", { battle = "b1", seq = 50, t = "obey", slot = 0, side = "a" }, 3 }
  cases[#cases + 1] = { "event", { battle = "b1", seq = 51, t = "obey", slot = 0, side = "a",
                                   text = "loafing" }, 2 }
  return cases
end

scenarios[#scenarios + 1] = {
  name = "badge_rules_dialect",
  run = function()
    local out = {}
    for i, case in ipairs(badgeRules()) do
      local kind, input, gen = case[1], decoded(case[2]), case[3]
      local got
      if kind == "ruleset" then got = Wire.battleRuleset(input, gen)
      elseif kind == "mon" then got = Wire.battleMon(input)
      elseif kind == "party" then got = Wire.battleParty(input, gen)
      elseif kind == "event" then got = Wire.battleEvent(input, gen)
      end
      out[i] = { kind = kind, got = orNil(got) }
    end
    return { cases = out }
  end,
}

-- ------------------------------------------------------------------
-- Gen 3 Pay Day coins and the holders-only exp fact, through the hub
-- (docs/plans/gen3-battle-sheet.md §1 outcome, §7.1 exp).  A coop_wild field:
-- ANN's PAYER scatters coins first, BOB's BOOMER blows itself up to take the
-- wild mon down with it.  ANN's fighter is paid as a participant; BOB's seat
-- fought but has nobody standing who did, so it gets the holders-only fact
-- (`participants` 0, no `mon`); and the outcome carries side a's coins to
-- both players.  Then each twin's sanitiser reads what it was sent, and the
-- boundary cases of the two new readings.  `read1` / `read2` keep the coins
-- since contract K11 of docs/plans/gen12-referee-gaps-fix.md (every reader
-- reads `payDay`, each under its own cart's bound -- gen12_payday_forward).
-- ------------------------------------------------------------------

local IDLE3 = { id = "IDLE", num = 150, effect = 85, power = 0, target = 16, flags = 0 }

local function slimExp(e)
  if not e then return "(nil)" end
  return { slot = orNil(e.slot), participants = orNil(e.participants), mon = orNil(e.mon),
           level = orNil(e.level), species = orNil(e.species) }
end

local function slimPaid(msg)
  if not msg then return "(nil)" end
  return { outcome = msg.outcome, reason = orNil(msg.reason), winners = orNil(msg.winners),
           losers = orNil(msg.losers), payDay = orNil(msg.payDay) }
end

local PAYDAY_EDGES = { 200, 0, 1, 65535, 65536, -3, 1.5, "0x10", " 7 ", "1e2", true, { 3 } }
local PARTICIPANT_EDGES = { 0, "0", -1, 1.9, 12, 13, " 0 " }

scenarios[#scenarios + 1] = {
  name = "gen3_coop_wild_payday",
  run = function()
    local hub = makeGenHub(3)
    local a = dialAs(hub, "ANN", ID_A, { generation = 3, version = "firered",
      sprite = "OBJ_EVENT_GFX_RED_NORMAL", map = "FR_PALLET_TOWN" })
    local b = dialAs(hub, "BOB", ID_B, { generation = 3, version = "emerald",
      sprite = "OBJ_EVENT_GFX_MAY_NORMAL", map = "EM_LITTLEROOT_TOWN" })
    local id = "c1"
    local opened = hub:openCoopBattle(id, { a.id, b.id }, { mode = "coop_wild", hostId = a.id }) ~= nil
    hub:receive(a.client, { type = Wire.BATTLE_RULESET, battle = id, typeTable = CHART3 })
    hub:receive(a.client, { type = Wire.BATTLE_PARTY, battle = id, side = "a", mons = {
      mon3({ species = "PAYER", level = 40, spe = 300, atk = 50,
             moves = { move3({ id = "COINS", num = 6, effect = 34, power = 20, chance = 100 }) } }) } })
    hub:receive(b.client, { type = Wire.BATTLE_PARTY, battle = id, side = "a", mons = {
      mon3({ species = "BOOMER", spe = 200, atk = 999,
             moves = { move3({ id = "BLAST", num = 153, effect = 7, power = 250 }) } }),
      mon3({ species = "SHARER", heldItem = 182, holdEffect = 25, moves = { move3(IDLE3) } }) } })
    hub:receive(a.client, { type = Wire.BATTLE_PARTY, battle = id, side = "b", mons = {
      mon3({ species = "WILDLING", def = 5, spe = 1, catchRate = 45, moves = { move3(IDLE3) } }) } })
    local record = hub.battles[id]
    local simOpen = record ~= nil and record.sim ~= nil
    a.peer.outbox, b.peer.outbox = {}, {}
    local exps, outcome = {}, nil
    for _ = 1, 6 do
      if not hub.battles[id] then break end
      hub:receive(a.client, { type = Wire.BATTLE_CHOICE, battle = id, action = "fight", move = 0 })
      hub:receive(b.client, { type = Wire.BATTLE_CHOICE, battle = id, action = "fight", move = 0 })
      for _, msg in ipairs(takeAll(a.peer, Wire.BATTLE_EVENT)) do
        if msg.t == "exp" then exps[#exps + 1] = msg end
      end
      outcome = take(a.peer, Wire.BATTLE_OUTCOME)
      if outcome then break end
    end
    local atBob = take(b.peer, Wire.BATTLE_OUTCOME)
    local raw, read3, read2, read1 = {}, {}, {}, {}
    for i, e in ipairs(exps) do
      raw[i] = slimExp(e)
      read3[i] = slimExp(Wire.battleEvent(e, 3))
      read2[i] = slimExp(Wire.battleEvent(e, 2))
      read1[i] = slimExp(Wire.battleEvent(e, 1))
    end
    local payEdges = {}
    for i, v in ipairs(PAYDAY_EDGES) do
      local got = Wire.battleOutcome({ battle = "b1", outcome = "win", payDay = v }, 3)
      payEdges[i] = { kept = got ~= nil, payDay = orNil(got and got.payDay) }
    end
    local partEdges = {}
    for i, v in ipairs(PARTICIPANT_EDGES) do
      local e = { battle = "b1", seq = i, t = "exp", slot = 0, level = 5, participants = v }
      partEdges[i] = {
        gen3 = orNil((Wire.battleEvent(e, 3) or {}).participants),
        none = orNil((Wire.battleEvent(e) or {}).participants),
      }
    end
    return {
      opened = opened,
      simOpen = simOpen,
      exp = raw,
      expRead3 = read3,
      expRead2 = read2,
      expRead1 = read1,
      outcome = slimPaid(outcome),
      outcomeAtBob = slimPaid(atBob),
      read3 = slimPaid(outcome and Wire.battleOutcome(outcome, 3)),
      readNone = slimPaid(outcome and Wire.battleOutcome(outcome)),
      read2 = slimPaid(outcome and Wire.battleOutcome(outcome, 2)),
      read1 = slimPaid(outcome and Wire.battleOutcome(outcome, 1)),
      payEdges = payEdges,
      partEdges = partEdges,
      battleGone = hub.battles[id] == nil,
    }
  end,
}

-- The same Pay Day in a fight between players pays nobody: a Gen 3 1v1 where
-- the winner used it.  The referee counts the coins and the outcome carries
-- none (link rules), on both hosting paths.
scenarios[#scenarios + 1] = {
  name = "gen3_pvp_payday_absent",
  run = function()
    local hub = makeGenHub(3)
    local a = dialAs(hub, "ANN", ID_A, { generation = 3, version = "firered",
      sprite = "OBJ_EVENT_GFX_RED_NORMAL", map = "FR_PALLET_TOWN" })
    local b = dialAs(hub, "BOB", ID_B, { generation = 3, version = "leafgreen",
      sprite = "OBJ_EVENT_GFX_RED_NORMAL", map = "FR_PALLET_TOWN" })
    local sess = openFight(hub, a, b)
    hub:receive(a.client, { type = Wire.BATTLE_RULESET, battle = sess.id, typeTable = CHART3 })
    hub:receive(a.client, { type = Wire.BATTLE_PARTY, battle = sess.id, mons = {
      mon3({ species = "PAYER", level = 40, spe = 300, atk = 400,
             moves = { move3({ id = "COINS", num = 6, effect = 34, power = 60, chance = 100 }) } }) } })
    hub:receive(b.client, { type = Wire.BATTLE_PARTY, battle = sess.id, mons = {
      mon3({ species = "DELTA", hp = 150, def = 5, spe = 1, moves = { move3(IDLE3) } }) } })
    local record = hub.battles[sess.id]
    local outcome = nil
    for _ = 1, 6 do
      if not hub.battles[sess.id] then break end
      hub:receive(a.client, { type = Wire.BATTLE_CHOICE, battle = sess.id, action = "fight", move = 0 })
      hub:receive(b.client, { type = Wire.BATTLE_CHOICE, battle = sess.id, action = "fight", move = 0 })
      outcome = take(a.peer, Wire.BATTLE_OUTCOME) or take(b.peer, Wire.BATTLE_OUTCOME)
      if outcome then break end
    end
    -- The coins were counted (the sim's own tally, side a) and not paid.
    local tally = record and record.sim and record.sim:snapshot().payDay
    return {
      counted = orNil(tally and tally.a),
      outcome = slimPaid(outcome),
      battleGone = hub.battles[sess.id] == nil,
    }
  end,
}

-- ------------------------------------------------------------------
-- The referee-fidelity wire (docs/plans/gen12-referee-fidelity.md K1-K3),
-- each input read by Wire.lua here and lib/sanitize.js there, under the
-- reader's generation (the third field; a mon is read with none, as the hub
-- reads a caught sheet):
--
--   * K1 -- `traded` on a Gen 1 and a Gen 2 sheet: true kept, false and a
--     JSON null (NULL) kept as absent, anything else refuses the sheet (and
--     a party carrying it); `unfateful` still never copied off either;
--   * K2 -- Gold's held-item data beside `heldItem`: each field at and past
--     its bound, each wrong type, `mail` read like `traded`; the same fields
--     on a Gen 1 sheet ignored, not refused; and a Gen 3 sheet untouched (its
--     numeric hold effect, no holdParam or mail copied);
--   * K3 -- Gold's `held` event: kept for a generation 2 reader, its `text`
--     an id and its `amount` a 0 / 1 flag (anything else dropped with the
--     event kept), refused by a Gen 1 reader, and Gen 3's `held` read as it
--     always was by a Gen 3 reader or one that names none.
-- ------------------------------------------------------------------

local function sheet12(gen, extra)
  local sheet = { species = "ALPHA", level = 50, hp = 100, maxHp = 100,
                  moves = { { id = "thump", pp = 20, power = 40, accuracy = 255, type = 0,
                              effect = 0, chance = 0 } } }
  if gen == 2 then
    sheet.stats = { atk = 90, def = 90, spe = 90, spa = 90, spd = 90 }
  else
    sheet.stats = { atk = 90, def = 90, spd = 90, spc = 90 }
  end
  for k, v in pairs(extra or {}) do sheet[k] = v end
  return sheet
end

local function merged(base, extra)
  local out = {}
  for k, v in pairs(base) do out[k] = v end
  for k, v in pairs(extra) do out[k] = v end
  return out
end

local function fidelity()
  local held = { heldItem = "LEFTOVERS", holdEffect = "HELD_LEFTOVERS", holdParam = 10,
                 itemName = "LEFTOVERS" }
  local gen3Held = { battle = "b1", seq = 80, t = "held", slot = 3, side = "b", mon = 0,
                     amount = 139, holding = 0, text = "ORAN BERRY" }
  local function held2(extra)
    return merged({ battle = "b1", seq = 60, t = "held", slot = 0, side = "a", mon = 0,
                    text = "LEFTOVERS", amount = 1 }, extra or {})
  end
  local gen3Extra = mon3({ heldItem = 139, holdEffect = 1, holdEffectParam = 10 })
  gen3Extra.holdParam, gen3Extra.mail = 5, true
  return {
    -- K1
    { "mon", sheet12(1, { traded = true }) },
    { "mon", sheet12(1, { traded = false }) },
    { "mon", sheet12(1, { traded = "yes" }) },
    { "mon", sheet12(1, { traded = 1 }) },
    { "mon", sheet12(1, { traded = NULL }) },
    { "mon", sheet12(1, { traded = true, unfateful = true }) },
    { "mon", sheet12(1, { generation = 1, traded = true }) },
    { "mon", sheet12(2, { traded = true }) },
    { "mon", sheet12(2, { traded = false }) },
    { "mon", sheet12(2, { traded = "true" }) },
    { "mon", sheet12(2, { traded = 0 }) },
    { "mon", sheet12(2, { generation = 2, traded = true, unfateful = true }) },
    { "party", { battle = "b1", mons = { sheet12(1, { traded = true }) } }, 1 },
    { "party", { battle = "b1", mons = { sheet12(1, { traded = "yes" }) } }, 1 },
    { "party", { battle = "b1", mons = { sheet12(2, { traded = true }) } }, 2 },
    -- K2 on a Gold sheet
    { "mon", sheet12(2, held) },
    { "mon", sheet12(2, merged(held, { mail = true })) },
    { "mon", sheet12(2, merged(held, { mail = false })) },
    { "mon", sheet12(2, merged(held, { mail = "yes" })) },
    { "mon", sheet12(2, merged(held, { mail = 1 })) },
    { "mon", sheet12(2, merged(held, { mail = NULL })) },
    { "mon", sheet12(2, { heldItem = "POLKADOT_BOW", holdEffect = "HELD_" .. string.rep("X", 27) }) },
    { "mon", sheet12(2, { holdEffect = "HELD_" .. string.rep("X", 28) }) },
    { "mon", sheet12(2, { holdEffect = "LEFTOVERS" }) },
    { "mon", sheet12(2, { holdEffect = "HELD_leftovers" }) },
    { "mon", sheet12(2, { holdEffect = "HELD_" }) },
    { "mon", sheet12(2, { holdEffect = "HELD_LEFT OVERS" }) },
    { "mon", sheet12(2, { holdEffect = 7 }) },
    { "mon", sheet12(2, { holdParam = 0 }) },
    { "mon", sheet12(2, { holdParam = 255 }) },
    { "mon", sheet12(2, { holdParam = 256 }) },
    { "mon", sheet12(2, { holdParam = -1 }) },
    { "mon", sheet12(2, { holdParam = "12" }) },
    { "mon", sheet12(2, { holdParam = 3.7 }) },
    { "mon", sheet12(2, { holdParam = true }) },
    { "mon", sheet12(2, { holdParam = "" }) },
    { "mon", sheet12(2, { itemName = "MYSTERYBERRY" }) },
    { "mon", sheet12(2, { itemName = "KINGS ROCK OF OLD" }) },
    { "mon", sheet12(2, { itemName = "Pink*Bow" }) },
    { "mon", sheet12(2, { itemName = "@@@" }) },
    { "mon", sheet12(2, { itemName = 5 }) },
    -- K2 on a Gen 1 sheet: not its dialect, so ignored rather than refused
    { "mon", sheet12(1, merged(held, { mail = true })) },
    { "mon", sheet12(1, { holdEffect = 7, holdParam = 999, itemName = 5, mail = "yes" }) },
    { "mon", sheet12(1, { generation = 1, holdEffect = "HELD_LEFTOVERS", mail = true }) },
    -- K2 never reaches a Gen 3 sheet
    { "mon", gen3Extra },
    { "mon", mon3({ holdEffect = "HELD_LEFTOVERS" }) },
    -- K1 + K2 through a party, stamped by the hub's generation
    { "party", { battle = "b1", mons = { sheet12(2, merged(held, { traded = true, mail = true })) } }, 2 },
    { "party", { battle = "b1", mons = { sheet12(2, { holdEffect = "LEFTOVERS" }) } }, 2 },
    { "party", { battle = "b1", mons = { sheet12(1, held) } }, 1 },
    -- K3
    { "event", held2(), 2 },
    { "event", held2({ seq = 61, text = "BERRY", amount = 0 }), 2 },
    { "event", held2({ seq = 62, amount = 2 }), 2 },
    { "event", held2({ seq = 63, amount = -1 }), 2 },
    { "event", held2({ seq = 64, amount = "1" }), 2 },
    { "event", held2({ seq = 65, amount = true }), 2 },
    { "event", held2({ seq = 66, amount = 0.5 }), 2 },
    { "event", held2({ seq = 67, text = "bad id!" }), 2 },
    { "event", held2({ seq = 68, text = 7 }), 2 },
    { "event", held2({ seq = 69, text = "GOLD BERRY" }), 2 },
    { "event", held2({ seq = 70, holding = 3, target = 1, mon = 6 }), 2 },
    { "event", held2({ seq = 71 }), 1 },
    { "event", gen3Held, 3 },
    { "event", gen3Held },
    { "event", gen3Held, 2 },
    { "event", { battle = "b1", seq = 72, t = "item", slot = 0, side = "a", text = "POTION",
                 amount = 5 }, 2 },
    { "event", { battle = "b1", seq = 73, t = "ability", slot = 0, side = "a" }, 2 },
  }
end

scenarios[#scenarios + 1] = {
  name = "referee_fidelity_dialect",
  run = function()
    local out = {}
    for i, case in ipairs(fidelity()) do
      local kind, input, gen = case[1], decoded(case[2]), case[3]
      local got
      if kind == "mon" then got = Wire.battleMon(input)
      elseif kind == "party" then got = Wire.battleParty(input, gen)
      elseif kind == "event" then got = Wire.battleEvent(input, gen)
      end
      out[i] = { kind = kind, got = orNil(got) }
    end
    return { cases = out }
  end,
}

-- ------------------------------------------------------------------
-- Gold's cart lineage on a fighter entry (contract K6 of
-- docs/plans/gen12-referee-fidelity.md)
-- ------------------------------------------------------------------
--
-- The Gen 2 referee reads side a's first fighter's `family` for the rule Gold
-- / Silver and Crystal disagree on (TruncateHL_BC), and each hub stamps it on
-- a human seat from the hello it admitted: gold / silver -> gs, crystal ->
-- crystal, nothing for a hello that named no cart, an NPC seat, or any Kanto
-- cart.  The digest is the entries the referee is handed (Turn.create here,
-- Turn.attempt on relay.js), in seat order, "(nil)" for no field -- what the
-- referee then does with it is tests/fixtures/battle2_turn_parity.json's.

local function sheet2(o)
  o = o or {}
  return {
    species = o.species or "ALPHA", level = 50, hp = o.hp or 300, maxHp = o.hp or 300,
    stats = { atk = 100, def = 100, spe = o.spe or 50, spa = 50, spd = 100 },
    moves = { move({ power = 20 }) },
  }
end

local function familyFight(generation, versions, mode)
  local hub = makeGenHub(generation)
  local seen = {}
  local real = hub.Turn
  hub.Turn = setmetatable({
    create = function(opts) seen.opts = opts; return real.create(opts) end,
  }, { __index = real })
  local ids = { ID_A, ID_B, ID_C, ID_D }
  local sprite = generation == 2 and Config.DEFAULT_SPRITE_GEN2 or Config.DEFAULT_SPRITE
  local players = {}
  for i, version in ipairs(versions) do
    players[i] = dialAs(hub, "P" .. i, ids[i], {
      generation = generation, version = version ~= "(none)" and version or nil, sprite = sprite,
    })
  end
  local memberIds = {}
  for i, p in ipairs(players) do memberIds[i] = p.id end
  local opts = { mode = mode, hostId = memberIds[1] }
  if mode == "coop_pvp" then
    opts.sides = { a = { memberIds[1], memberIds[2] }, b = { memberIds[3], memberIds[4] } }
  end
  hub:openCoopBattle("kf", memberIds, opts)
  local record = hub.battles["kf"]
  local function sheet() return generation == 2 and sheet2() or mon() end
  hub:receive(players[1].client, { type = Wire.BATTLE_RULESET, battle = "kf", chart = CHART })
  for _, p in ipairs(players) do
    hub:receive(p.client, { type = Wire.BATTLE_PARTY, battle = "kf",
                            side = mode == "coop_npc" and "a" or nil, mons = { sheet() } })
  end
  if mode == "coop_npc" then
    hub:receive(players[1].client, { type = Wire.BATTLE_PARTY, battle = "kf", side = "b",
                                     mons = { sheet(), sheet() } })
  end
  local entries = {}
  for _, side in ipairs({ "a", "b" }) do
    for _, entry in ipairs(seen.opts and seen.opts.sides[side] or {}) do
      local npc = false
      for _, npcId in ipairs(record and record.npcIds or {}) do
        if npcId == entry.playerId then npc = true end
      end
      entries[#entries + 1] = {
        side = side, seat = npc and "npc" or entry.playerId, family = entry.family or "(nil)",
      }
    end
  end
  return { opened = record ~= nil and record.sim ~= nil, entries = entries }
end

scenarios[#scenarios + 1] = {
  name = "gen2_cart_family_stamp",
  run = function()
    return {
      gold = familyFight(2, { "crystal", "silver" }, "coop_npc"),
      bare = familyFight(2, { "gold", "(none)" }, "coop_npc"),
      spar = familyFight(2, { "crystal", "gold", "silver", "crystal" }, "coop_pvp"),
      kanto = familyFight(1, { "red", "yellow" }, "coop_npc"),
    }
  end,
}

-- ------------------------------------------------------------------
-- The referee-gap wire (docs/plans/gen12-referee-gaps-fix.md K7-K11, K13),
-- each input read by Wire.lua here and lib/sanitize.js there, under the
-- reader's generation (the third field; a mon is read with none, as the hub
-- reads a caught sheet):
--
--   * K7  -- `base` / `dvs` / `statExp` on a Gen 1 and a Gen 2 sheet: each
--     block whole or the sheet refused, at and past every bound, each wrong
--     key set (Gen 1 keys on a Gold sheet, Gold's split Special on `statExp`),
--     a JSON null as absent, through a party and a caught sheet, and never
--     read off a Gen 3 sheet;
--   * K8  -- a move row's `ppUps` (both) and `priority` (Gold only; a Gen 1
--     row's is neither copied nor refused, nor one a reader naming no
--     generation reads), on a sheet, a ruleset's pool and a `moves` event;
--   * K9  -- `mmo.battle_moveset`'s `level` / `stats` / `maxHp`, Gen 1 and
--     Gen 2 only, each refusing the message when unreadable;
--   * K10 -- a `stat` event's signed `stage` for an older reader;
--   * K11 -- `payDay` on an outcome per reader, PAYDAY12_MAX for 1 / 2 and
--     PAYDAY3_MAX for 3 or none (payEdges12), and kept on a run outcome by
--     every reader (which runs pay is the hubs' gate, gen12_payday_forward);
--   * K13 -- an id refused past 40 characters, never cut, wherever one rides,
--     and its twin: a map id refused past 64 (Wire.mapId / cleanMapId);
--   * K14 -- Gold's `happiness` 0..255 on a Gen 2 sheet, refusing the sheet
--     when unreadable, neither copied nor refused off a Gen 1 sheet, never
--     read off a Gen 3 one.
-- ------------------------------------------------------------------

local function k7(gen)
  if gen == 2 then
    return {
      base = { hp = 41, atk = 52, def = 63, spe = 74, spa = 85, spd = 96 },
      dvs = { atk = 12, def = 7, spe = 15, spc = 3 },
      statExp = { hp = 1000, atk = 2000, def = 0, spe = 65535, spc = 7 },
    }
  end
  return {
    base = { hp = 41, atk = 52, def = 63, spd = 74, spc = 85 },
    dvs = { atk = 12, def = 7, spd = 15, spc = 3 },
    statExp = { hp = 1000, atk = 2000, def = 0, spd = 65535, spc = 7 },
  }
end

local function row12(id, extra)
  return merged({ id = id, pp = 20, power = 40, accuracy = 255, type = 0, effect = 0, chance = 0 },
                extra or {})
end

local GROWN1 = { atk = 91, def = 92, spd = 93, spc = 94 }
local GROWN2 = { atk = 91, def = 92, spe = 93, spa = 94, spd = 95 }

local function statEvent(seq, stage)
  return { battle = "b1", seq = seq, t = "stat", slot = 0, side = "a", amount = 2,
           text = "ATK fell", stage = stage }
end

local function gaps()
  local B1 = { hp = 41, atk = 52, def = 63, spd = 74, spc = 85 }
  local thump = row12("thump")
  return {
    -- K7
    { "mon", sheet12(1, k7(1)) },
    { "mon", sheet12(2, k7(2)) },
    { "mon", sheet12(2, merged(k7(2), { generation = 2 })) },
    { "mon", sheet12(1, { base = { hp = 0, atk = 255, def = 1, spd = 2, spc = 3 } }) },
    { "mon", sheet12(1, { base = merged(B1, { atk = 256 }) }) },
    { "mon", sheet12(1, { base = merged(B1, { hp = -1 }) }) },
    { "mon", sheet12(1, { base = { atk = 52, def = 63, spd = 74, spc = 85 } }) },
    { "mon", sheet12(2, { base = B1 }) },
    { "mon", sheet12(1, { base = { 41, 52, 63, 74, 85 } }) },
    { "mon", sheet12(1, { base = "41" }) },
    { "mon", sheet12(1, { base = NULL, dvs = NULL, statExp = NULL }) },
    { "mon", sheet12(1, { dvs = { atk = 15, def = 0, spd = "7", spc = 3.9 } }) },
    { "mon", sheet12(1, { dvs = { atk = 16, def = 0, spd = 7, spc = 3 } }) },
    { "mon", sheet12(1, { dvs = { atk = true, def = 0, spd = 7, spc = 3 } }) },
    { "mon", sheet12(1, { dvs = { atk = "0x10", def = 0, spd = 7, spc = 3 } }) },
    { "mon", sheet12(1, { dvs = { atk = " 9 ", def = 0, spd = 7, spc = 3 } }) },
    { "mon", sheet12(2, { dvs = { atk = 1, def = 2, spd = 3, spc = 4 } }) },
    { "mon", sheet12(2, { dvs = { atk = 1, def = 2, spe = 3, spc = 4, spa = 9, hp = 5 } }) },
    { "mon", sheet12(2, { statExp = { hp = 1, atk = 2, def = 3, spe = 4, spa = 5, spd = 6 } }) },
    { "mon", sheet12(1, { statExp = { hp = 65535, atk = 0, def = 1, spd = 2, spc = 3 } }) },
    { "mon", sheet12(1, { statExp = { hp = 65536, atk = 0, def = 1, spd = 2, spc = 3 } }) },
    { "mon", sheet12(1, { statExp = { atk = 0, def = 1, spd = 2, spc = 3 } }) },
    { "mon", merged(sheet12(1, k7(2)), { generation = 1 }) },
    { "mon", merged(mon3(), k7(2)) },
    { "mon", merged(mon3(), { base = "x", dvs = 99, statExp = true }) },
    { "party", { battle = "b1", mons = { sheet12(2, k7(2)) } }, 2 },
    { "party", { battle = "b1", mons = { sheet12(1, k7(2)) } }, 1 },
    { "outcome", { battle = "b1", outcome = "win", reason = "catch", caught = sheet12(1, k7(1)) }, 1 },
    { "outcome", { battle = "b1", outcome = "win", reason = "catch",
                   caught = sheet12(1, { dvs = { atk = 99 } }) }, 1 },
    -- K8
    { "move", row12("m", { ppUps = 0 }), 1 },
    { "move", row12("m", { ppUps = 3 }), 2 },
    { "move", row12("m", { ppUps = 4 }), 1 },
    { "move", row12("m", { ppUps = -1 }), 2 },
    { "move", row12("m", { ppUps = "2" }), 1 },
    { "move", row12("m", { ppUps = 1.5 }), 1 },
    { "move", row12("m", { ppUps = true }), 1 },
    { "move", row12("m", { ppUps = NULL }), 1 },
    { "move", row12("m", { priority = 0 }), 2 },
    { "move", row12("m", { priority = 255 }), 2 },
    { "move", row12("m", { priority = 256 }), 2 },
    { "move", row12("m", { priority = -1 }), 2 },
    { "move", row12("m", { priority = "fast" }), 2 },
    { "move", row12("m", { priority = "3" }), 2 },
    { "move", row12("m", { priority = 3 }), 1 },
    { "move", row12("m", { priority = "fast" }), 1 },
    { "move", row12("m", { priority = 3, ppUps = 2 }) },
    { "move", merged(move3(), { ppUps = 3, priority = 2 }), 3 },
    { "ruleset", { chart = CHART, metronomePool = { row12("m", { priority = 2, ppUps = 0 }) } }, 2 },
    { "ruleset", { chart = CHART, metronomePool = { row12("m", { priority = 2, ppUps = 0 }) } }, 1 },
    { "ruleset", { chart = CHART, metronomePool = { row12("m", { ppUps = 9 }) } }, 2 },
    { "event", { battle = "b1", seq = 4, t = "moves", slot = 0, side = "a",
                 moves = { row12("m", { priority = 3, ppUps = 1 }) } }, 2 },
    { "event", { battle = "b1", seq = 5, t = "moves", slot = 0, side = "a",
                 moves = { row12("m", { priority = 3, ppUps = 1 }) } }, 1 },
    { "mon", sheet12(2, { moves = { row12("m", { priority = 3, ppUps = 3 }) } }) },
    { "mon", sheet12(2, { moves = { row12("m", { priority = 300 }) } }) },
    { "mon", sheet12(1, { moves = { row12("m", { priority = 300 }) } }) },
    -- K9
    { "moveset", { battle = "b1", mon = 0, moves = { thump }, level = 51, stats = GROWN1, maxHp = 140 }, 1 },
    { "moveset", { battle = "b1", mon = 1, moves = { thump }, level = 51, stats = GROWN2, maxHp = 140 }, 2 },
    { "moveset", { battle = "b1", mon = 0, moves = { thump }, stats = GROWN1 }, 2 },
    { "moveset", { battle = "b1", mon = 0, moves = { thump }, level = 0 }, 1 },
    { "moveset", { battle = "b1", mon = 0, moves = { thump }, level = 101 }, 1 },
    { "moveset", { battle = "b1", mon = 0, moves = { thump }, level = "50" }, 1 },
    { "moveset", { battle = "b1", mon = 0, moves = { thump }, level = true }, 2 },
    { "moveset", { battle = "b1", mon = 0, moves = { thump }, maxHp = 0 }, 1 },
    { "moveset", { battle = "b1", mon = 0, moves = { thump }, maxHp = 1000 }, 2 },
    { "moveset", { battle = "b1", mon = 0, moves = { thump }, stats = { atk = 91, def = 92, spd = 93 } }, 1 },
    { "moveset", { battle = "b1", mon = 0, moves = { thump }, stats = merged(GROWN1, { atk = 0 }) }, 1 },
    { "moveset", { battle = "b1", mon = 0, moves = { thump }, level = 51, stats = NULL, maxHp = NULL }, 1 },
    { "moveset", { battle = "b1", mon = 0, moves = { move3() }, level = 51, stats = GROWN2, maxHp = 140 }, 3 },
    { "moveset", { battle = "b1", mon = 0, moves = { thump }, level = 51, stats = GROWN1, maxHp = 140 } },
    -- K10
    { "event", statEvent(10, -6), 1 },
    { "event", statEvent(11, 6), 1 },
    { "event", statEvent(12, -7), 1 },
    { "event", statEvent(13, 7), 2 },
    { "event", statEvent(14, "-2"), 2 },
    { "event", statEvent(15, true), 1 },
    { "event", statEvent(16, 2.5), 1 },
    { "event", statEvent(17, -1), 2 },
    { "event", statEvent(18, -3), 3 },
    { "event", statEvent(19, -3) },
    -- K13
    { "id", string.rep("i", 40) },
    { "id", string.rep("i", 41) },
    { "id", string.rep("i", 100) },
    { "id", "a-b_C9" },
    { "id", "" },
    { "id", "a b" },
    { "reconnect", { battle = string.rep("b", 40) } },
    { "reconnect", { battle = string.rep("b", 41) } },
    { "move", row12(string.rep("m", 40)), 1 },
    { "move", row12(string.rep("m", 41)), 1 },
    { "mon", sheet12(1, { speciesId = string.rep("S", 41) }) },
    { "mon", sheet12(2, { heldItem = string.rep("H", 41) }) },
    { "event", { battle = "b1", seq = 20, t = "item", slot = 0, side = "a", text = string.rep("I", 41) }, 1 },
    { "choice", { battle = "b1", action = "item", item = string.rep("I", 41) }, 1 },
    { "outcome", { battle = "b1", outcome = "win", catcher = string.rep("c", 41) }, 1 },
    { "party", { battle = string.rep("p", 41), mons = { sheet12(1) } }, 1 },
    -- K13's twin: a map id refused past 64 characters, never cut
    { "mapId", string.rep("M", 64) },
    { "mapId", string.rep("M", 65) },
    { "mapId", string.rep("M", 200) },
    { "mapId", "FR_PALLET_TOWN" },
    { "mapId", "route-1.2" },
    { "mapId", "" },
    { "mapId", "../secret" },
    { "mapId", "a b" },
    { "mapId", 64 },
    -- K14
    { "mon", sheet12(2, { happiness = 0 }) },
    { "mon", sheet12(2, { happiness = 70 }) },
    { "mon", sheet12(2, { happiness = 255 }) },
    { "mon", sheet12(2, { happiness = 256 }) },
    { "mon", sheet12(2, { happiness = -1 }) },
    { "mon", sheet12(2, { happiness = "70" }) },
    { "mon", sheet12(2, { happiness = 70.9 }) },
    { "mon", sheet12(2, { happiness = " 9 " }) },
    { "mon", sheet12(2, { happiness = "0x10" }) },
    { "mon", sheet12(2, { happiness = true }) },
    { "mon", sheet12(2, { happiness = "fond" }) },
    { "mon", sheet12(2, { happiness = { 70 } }) },
    { "mon", sheet12(2, { happiness = NULL }) },
    { "mon", sheet12(2, merged(k7(2), { happiness = 200, generation = 2 })) },
    { "mon", sheet12(1, { happiness = 70 }) },
    { "mon", sheet12(1, { happiness = "fond" }) },
    { "mon", merged(mon3(), { happiness = 70 }) },
    { "party", { battle = "b1", mons = { sheet12(2, { happiness = 200 }) } }, 2 },
    { "party", { battle = "b1", mons = { sheet12(2, { happiness = 300 }) } }, 2 },
    { "outcome", { battle = "b1", outcome = "win", reason = "catch",
                   caught = sheet12(2, { happiness = 70 }) }, 2 },
    -- K11 on an escape: every reader keeps a run outcome's coins
    { "outcome", { battle = "b1", outcome = "win", winners = { "nw1a" }, losers = { ID_A },
                   reason = "run", payDay = 350 }, 1 },
    { "outcome", { battle = "b1", outcome = "win", winners = { "nw1a" }, losers = { ID_A },
                   reason = "run", payDay = 350 }, 2 },
    { "outcome", { battle = "b1", outcome = "win", winners = { "nw1a" }, losers = { ID_A },
                   reason = "run", payDay = 350 }, 3 },
    { "outcome", { battle = "b1", outcome = "win", winners = { ID_A }, losers = { "nw1a" },
                   reason = "run", payDay = 350 } },
  }
end

local PAYDAY12_EDGES = { 200, 0, 1, 65535, 65536, 999999, 1000000, -3, 1.5, "0x10", " 7 ", "1e2",
                         true, { 3 } }

scenarios[#scenarios + 1] = {
  name = "referee_gaps_dialect",
  run = function()
    local out = {}
    for i, case in ipairs(gaps()) do
      local kind, input, gen = case[1], decoded(case[2]), case[3]
      local got
      if kind == "mon" then got = Wire.battleMon(input)
      elseif kind == "party" then got = Wire.battleParty(input, gen)
      elseif kind == "move" then got = Wire.battleMove(input, gen)
      elseif kind == "ruleset" then got = Wire.battleRuleset(input, gen)
      elseif kind == "event" then got = Wire.battleEvent(input, gen)
      elseif kind == "moveset" then got = Wire.battleMoveset(input, gen)
      elseif kind == "outcome" then got = Wire.battleOutcome(input, gen)
      elseif kind == "choice" then got = Wire.battleChoice(input, gen)
      elseif kind == "reconnect" then got = Wire.battleReconnect(input)
      elseif kind == "id" then got = Wire.id(input)
      elseif kind == "mapId" then got = Wire.mapId(input)
      end
      out[i] = { kind = kind, got = orNil(got) }
    end
    local payEdges12 = {}
    for i, v in ipairs(PAYDAY12_EDGES) do
      local row = {}
      for _, reader in ipairs({ 1, 2, 3, "none" }) do
        local got = Wire.battleOutcome({ battle = "b1", outcome = "win", payDay = v },
                                       reader ~= "none" and reader or nil)
        row["r" .. tostring(reader)] = orNil(got and got.payDay)
      end
      payEdges12[i] = row
    end
    return { cases = out, payEdges12 = payEdges12 }
  end,
}

-- ------------------------------------------------------------------
-- A mid-fight level-up reaches the referee (contract K9): both hubs forward a
-- moveset's `level` / `stats` / `maxHp` to `sim:levelUp(playerId, monIndex,
-- level, stats, maxHp)` -- the index 1-based -- whatever became of the move
-- list, and only when the referee has the method.  The sim's method is a stub
-- that records each call, and the hub's own rows are set first so the digest
-- never leans on how either sim's copyMove spells a field it was not given.
-- Along the way the learn keeps highCrit, PP Ups and Gold priority on an
-- unchanged row and takes them off a new one (K8).  A Gen 3 hub reads none of
-- it and so calls nothing.
-- ------------------------------------------------------------------

local function slimMoves12(moves)
  local out = {}
  for i, m in ipairs(moves or {}) do
    out[i] = { id = m.id, pp = orNil(m.pp), power = orNil(m.power), highCrit = orNil(m.highCrit),
               ppUps = orNil(m.ppUps), priority = orNil(m.priority) }
  end
  return out
end

local function levelFight(generation)
  local hub = makeGenHub(generation)
  local sprite = generation == 2 and Config.DEFAULT_SPRITE_GEN2 or Config.DEFAULT_SPRITE
  local a = dialAs(hub, "ANN", ID_A, { generation = generation, sprite = sprite })
  local b = dialAs(hub, "BOB", ID_B, { generation = generation, sprite = sprite })
  local sess = openFight(hub, a, b)
  uploadReady(hub, a, b, sess.id, { sheet12(generation) }, { sheet12(generation) })
  local record = hub.battles[sess.id]
  if not (record and record.sim) then return { opened = false } end
  local calls = {}
  record.sim.levelUp = function(_, playerId, index, level, stats, maxHp)
    calls[#calls + 1] = { playerId = playerId, index = index, level = orNil(level),
                          stats = orNil(stats), maxHp = orNil(maxHp) }
  end
  local gold = generation == 2
  local live = record.sim.byId[a.id].mons[1]
  live.moves = {
    row12("slash", { pp = 7, power = 70, highCrit = true, ppUps = 1, priority = gold and 1 or nil }),
    row12("thump", { pp = 9, highCrit = false }),
  }
  local steps = {}
  local function send(extra)
    hub:receive(a.client, merged({ type = Wire.BATTLE_MOVESET, battle = sess.id, mon = 0 }, extra))
    steps[#steps + 1] = { calls = #calls, moves = slimMoves12(live.moves) }
  end
  local four = { row12("slash"), row12("thump"), row12("swap"), row12("extra") }
  -- 1. the hub's own moves (rewritten by the client) and a level-up: the list
  --    keeps the hub's rows, the referee hears the growth
  send({ moves = { row12("slash", { pp = 99, power = 999 }), row12("thump") },
         level = 51, stats = gold and GROWN2 or GROWN1, maxHp = 140 })
  -- 2. a learn carrying K8 fields, with its level
  send({ moves = { row12("slash"), row12("thump"),
                   row12("learnt", { ppUps = 2, priority = 3, highCrit = true }) }, level = 52 })
  -- 3. forget-and-learn with no level: nothing is called
  send({ moves = { row12("slash"), row12("thump"), row12("swap", { ppUps = 0 }) } })
  -- 4. two slots rewritten: the list is refused, the level still goes on
  send({ moves = { row12("aaa"), row12("bbb"), row12("swap") }, level = 53 })
  -- 5. a transformed battler grows; only its list is protected
  live.transformed = true
  send({ moves = four, level = 54, maxHp = 150 })
  live.transformed = nil
  -- 6. a mangled level refuses the whole message
  send({ moves = four, level = 0 })
  -- 7. a referee with no K9 method: the learn lands, nothing is called
  record.sim.levelUp = false
  send({ moves = four, level = 55 })
  return { opened = true, calls = calls, steps = steps }
end

local function levelFight3()
  local hub = makeGenHub(3)
  local a = dialAs(hub, "ANN", ID_A, { generation = 3, version = "firered",
    sprite = "OBJ_EVENT_GFX_RED_NORMAL", map = "FR_PALLET_TOWN" })
  local b = dialAs(hub, "BOB", ID_B, { generation = 3, version = "emerald",
    sprite = "OBJ_EVENT_GFX_MAY_NORMAL", map = "EM_LITTLEROOT_TOWN" })
  local sess = openFight(hub, a, b)
  hub:receive(a.client, { type = Wire.BATTLE_RULESET, battle = sess.id, typeTable = CHART3 })
  hub:receive(a.client, { type = Wire.BATTLE_PARTY, battle = sess.id, mons = { mon3() } })
  hub:receive(b.client, { type = Wire.BATTLE_PARTY, battle = sess.id, mons = { mon3() } })
  local record = hub.battles[sess.id]
  if not (record and record.sim) then return { opened = false } end
  local calls = 0
  record.sim.levelUp = function() calls = calls + 1 end
  hub:receive(a.client, { type = Wire.BATTLE_MOVESET, battle = sess.id, mon = 0,
    moves = { move3(), move3({ id = "NEW3", num = 44 }) }, level = 51, stats = GROWN2, maxHp = 140 })
  local ids = {}
  for i, m in ipairs(record.sim.byId[a.id].mons[1].moves) do ids[i] = m.id end
  return { opened = true, calls = calls, moves = ids }
end

scenarios[#scenarios + 1] = {
  name = "levelup_moveset_forward",
  run = function()
    return { red = levelFight(1), gold = levelFight(2), gen3 = levelFight3() }
  end,
}

-- ------------------------------------------------------------------
-- Pay Day on a Gen 1 / Gen 2 outcome (contract K11): the hubs copy the
-- referee's `outcome().payDay` onto the broadcast in the NPC modes alone, and
-- only a positive count -- a 0 is the field's absence on both twins, where
-- Lua alone would read it as true.  On an escape (reason `run`) only a Red
-- hub copies it: pokered pays wTotalPayDayMoney after a Teleport / Whirlwind
-- / Roar / POKE DOLL escape (wBattleResult left at 0, EndOfBattle), Gold calls
-- every escape a DRAW (ExitBattle skips CheckPayDay) and Gen 3 pays only from
-- HandleEndTurn_BattleWon -- so a Gold and a Gen 3 hub keep the field off a
-- run whatever the referee said (paysDay).  The referee's outcome is a stub
-- here (the coins themselves are the Gen 1 / Gen 2 turn fixtures'); what is
-- pinned is the hub's copy and each reader's read of it.  A stub run names
-- the side that fled the loser, as the referees' `_concedeRun` does.
-- ------------------------------------------------------------------

local function paidFight(generation, mode, coins, reason)
  local hub = makeGenHub(generation)
  local a, b
  if generation == 3 then
    a = dialAs(hub, "ANN", ID_A, { generation = 3, version = "firered",
      sprite = "OBJ_EVENT_GFX_RED_NORMAL", map = "FR_PALLET_TOWN" })
    b = dialAs(hub, "BOB", ID_B, { generation = 3, version = "emerald",
      sprite = "OBJ_EVENT_GFX_MAY_NORMAL", map = "EM_LITTLEROOT_TOWN" })
  else
    local sprite = generation == 2 and Config.DEFAULT_SPRITE_GEN2 or Config.DEFAULT_SPRITE
    a = dialAs(hub, "ANN", ID_A, { generation = generation, sprite = sprite })
    b = dialAs(hub, "BOB", ID_B, { generation = generation, sprite = sprite })
  end
  local function sheet(extra)
    if generation == 3 then return mon3(extra) end
    return sheet12(generation, extra)
  end
  local id
  local solo = mode == "wild"
  if mode == "1v1" then
    id = openFight(hub, a, b).id
    uploadReady(hub, a, b, id, { sheet12(generation) }, { sheet12(generation) })
  else
    -- `wild` seats its one player alone against the hub's seat; `coop_wild`
    -- seats both.
    id = "w1"
    hub:openCoopBattle(id, solo and { a.id } or { a.id, b.id }, { mode = mode, hostId = a.id })
    if generation == 3 then
      hub:receive(a.client, { type = Wire.BATTLE_RULESET, battle = id, typeTable = CHART3 })
    else
      hub:receive(a.client, { type = Wire.BATTLE_RULESET, battle = id, chart = CHART })
    end
    hub:receive(a.client, { type = Wire.BATTLE_PARTY, battle = id, side = "a", mons = { sheet() } })
    if not solo then
      hub:receive(b.client, { type = Wire.BATTLE_PARTY, battle = id, side = "a", mons = { sheet() } })
    end
    hub:receive(a.client, { type = Wire.BATTLE_PARTY, battle = id, side = "b",
                            mons = { sheet({ catchRate = 45 }) } })
  end
  local record = hub.battles[id]
  if not (record and record.sim) then return { opened = false } end
  a.peer.outbox, b.peer.outbox = {}, {}
  local verdict = { outcome = "win", winners = { a.id }, losers = { b.id }, reason = "ko", payDay = coins }
  if reason == "run" then
    -- The players fled: the hub's seat (or, in a 1v1, the other player) is
    -- the winners list, the whole of side a the losers.
    local wild = record.npcIds and record.npcIds[1]
    verdict = { outcome = "win", winners = { wild or b.id },
                losers = (mode == "1v1" or solo) and { a.id } or { a.id, b.id },
                reason = "run", payDay = coins }
  end
  record.sim.outcome = function() return verdict end
  hub:flushBattle(record)
  local outcome = take(a.peer, Wire.BATTLE_OUTCOME)
  return {
    opened = true,
    outcome = slimPaid(outcome),
    read1 = slimPaid(outcome and Wire.battleOutcome(outcome, 1)),
    read2 = slimPaid(outcome and Wire.battleOutcome(outcome, 2)),
    read3 = slimPaid(outcome and Wire.battleOutcome(outcome, 3)),
    readNone = slimPaid(outcome and Wire.battleOutcome(outcome)),
    battleGone = hub.battles[id] == nil,
  }
end

scenarios[#scenarios + 1] = {
  name = "gen12_payday_forward",
  run = function()
    return {
      redWild = paidFight(1, "coop_wild", 350),
      goldWild = paidFight(2, "wild", 99999),
      goldNone = paidFight(2, "coop_wild", 0),
      red1v1 = paidFight(1, "1v1", 350),
      -- K11 on an escape: Red's hub carries the coins, Gold's and Gen 3's
      -- never do, a link fight never does, and 0 is still absence.
      redWildRun = paidFight(1, "wild", 350, "run"),
      redCoopRun = paidFight(1, "coop_wild", 350, "run"),
      redRunNone = paidFight(1, "wild", 0, "run"),
      red1v1Run = paidFight(1, "1v1", 350, "run"),
      goldWildRun = paidFight(2, "wild", 350, "run"),
      goldCoopRun = paidFight(2, "coop_wild", 350, "run"),
      gen3WildRun = paidFight(3, "wild", 350, "run"),
      gen3WildKo = paidFight(3, "wild", 350),
    }
  end,
}

-- ------------------------------------------------------------------
-- K13's twin on the roster: a map id past 64 characters leaves its player
-- unplaced on both hubs -- in a hello's welcome / join and on a step -- where
-- Hub.lua once stood them on its first 64 characters (Wire.mapId cut it, the
-- node hub's cleanMapId refused it).  A 64-character id places them.
-- ------------------------------------------------------------------

local function slimStep(msg)
  if not msg then return "(nil)" end
  return { id = msg.id, map = msg.map or "(none)", x = orNil(msg.x), y = orNil(msg.y) }
end

scenarios[#scenarios + 1] = {
  name = "map_id_bound",
  run = function()
    local hub = makeGenHub(1)
    local edge, long = string.rep("M", 64), string.rep("M", 65)
    local a = dialAs(hub, "ANN", ID_A, { map = long, sprite = Config.DEFAULT_SPRITE })
    local aWelcome = take(a.peer, Wire.WELCOME)
    local b = dialAs(hub, "BOB", ID_B, { map = edge, sprite = Config.DEFAULT_SPRITE })
    local bWelcome = take(b.peer, Wire.WELCOME)
    local joinAtA = take(a.peer, Wire.JOIN)
    local steps = {}
    for _, map in ipairs({ edge, long, "ROUTE_1", string.rep("M", 200), "../secret" }) do
      hub:receive(a.client, { type = Wire.MOVE, map = map, x = 3, y = 4, facing = "up" })
      steps[#steps + 1] = slimStep(take(b.peer, Wire.MOVE))
    end
    return {
      aWelcomed = aWelcome ~= nil,
      bWelcomed = bWelcome ~= nil,
      bSees = slimRoster(bWelcome and bWelcome.players),
      aSeesJoin = slimPresence(joinAtA and joinAtA.player),
      steps = steps,
    }
  end,
}

-- ------------------------------------------------------------------
-- A learn on a transformed battler (Red and Gold, real referees): the hubs
-- judge it against, and write it into, the party list the referee put aside
-- at Transform (`mon.preTransform.moves`), so the switch-out gives back the
-- learned list.  Gold leaves the copied moves in the fight (pokecrystal
-- LearnMove skips the battle copy while SUBSTATUS_TRANSFORMED is set); Red
-- overwrites them with its own (pokered LearnMove has no such check) -- a
-- separate copy, so the PP the fight spends never reaches the party list.
-- A rewrite is refused either way.  `learnTo` in both hubs.
-- ------------------------------------------------------------------

local function slimRows(moves)
  local out = {}
  for i, m in ipairs(moves or {}) do out[i] = { id = m.id, pp = orNil(m.pp) } end
  return out
end

local function transformLearn(generation)
  local hub = makeGenHub(generation)
  local sprite = generation == 2 and Config.DEFAULT_SPRITE_GEN2 or Config.DEFAULT_SPRITE
  local a = dialAs(hub, "ANN", ID_A, { generation = generation, sprite = sprite })
  local id = "t1"
  hub:openCoopBattle(id, { a.id }, { mode = "wild", hostId = a.id })
  hub:receive(a.client, { type = Wire.BATTLE_RULESET, battle = id, chart = CHART })
  local function mv(moveId, effect, power)
    return row12(moveId, { pp = 10, power = power or 0, effect = effect or 0 })
  end
  hub:receive(a.client, { type = Wire.BATTLE_PARTY, battle = id, side = "a", mons = {
    sheet12(generation, { species = "COPYCAT", moves = { mv("TRANSFORM", 57), mv("TACKLE", 0, 1) } }),
    sheet12(generation, { species = "BENCH", moves = { mv("TACKLE", 0, 1) } }) } })
  hub:receive(a.client, { type = Wire.BATTLE_PARTY, battle = id, side = "b", mons = {
    sheet12(generation, { species = "FOE", moves = { mv("GROWL"), mv("HUSH") } }) } })
  local record = hub.battles[id]
  if not (record and record.sim) then return { opened = false } end
  hub:receive(a.client, { type = Wire.BATTLE_CHOICE, battle = id, action = "fight", move = 0 })
  local live = record.sim.byId[a.id].mons[1]
  local function look()
    local saved = live.preTransform
    return {
      transformed = live.transformed == true,
      battle = slimRows(live.moves),
      party = saved and slimRows(saved.moves) or "(none)",
      separate = saved and saved.moves and saved.moves[1] ~= live.moves[1] or "(n/a)",
    }
  end
  local steps = { look() }
  -- a learn: appended to the party list
  hub:receive(a.client, { type = Wire.BATTLE_MOVESET, battle = id, mon = 0,
    moves = { mv("TRANSFORM", 57), mv("TACKLE", 0, 1), mv("LEARNT", 0, 40) } })
  steps[#steps + 1] = look()
  -- a rewrite: refused, nothing moves
  hub:receive(a.client, { type = Wire.BATTLE_MOVESET, battle = id, mon = 0,
    moves = { mv("AAA"), mv("BBB"), mv("CCC") } })
  steps[#steps + 1] = look()
  -- the switch-out undoes the Transform: the learned list comes back
  hub:receive(a.client, { type = Wire.BATTLE_CHOICE, battle = id, action = "switch", slot = 1 })
  steps[#steps + 1] = look()
  return { opened = true, steps = steps }
end

scenarios[#scenarios + 1] = {
  name = "transformed_learn",
  run = function()
    return { red = transformLearn(1), gold = transformLearn(2) }
  end,
}

-- ------------------------------------------------------------------
-- Wave 4 of docs/plans/gen12-referee-gaps-fix.md, the wire: Red's MIMIC
-- pick rides a Gen 1 choice (`mimic`, 0..3 into the target's moves; Gold and
-- Gen 3 ignore it, a bad one refuses the choice), and Gold's wTimeOfDay a
-- Gen 2 ruleset (`timeOfDay`, morn / day / nite; Red and Gen 3 ignore it, a
-- bad one refuses the ruleset).  Wire.battleChoice / Wire.battleRuleset and
-- their sanitize twins.
-- ------------------------------------------------------------------

local function wave4()
  local function fight(extra) return merged({ battle = "b1", action = "fight", move = 0 }, extra) end
  local function rules(extra) return merged({ chart = CHART }, extra) end
  return {
    { "choice", fight({ mimic = 0 }), 1 },
    { "choice", fight({ mimic = 3 }), 1 },
    { "choice", fight({ mimic = 4 }), 1 },
    { "choice", fight({ mimic = -1 }), 1 },
    { "choice", fight({ mimic = "2" }), 1 },
    { "choice", fight({ mimic = " 1 " }), 1 },
    { "choice", fight({ mimic = "0x1" }), 1 },
    { "choice", fight({ mimic = 1.5 }), 1 },
    { "choice", fight({ mimic = true }), 1 },
    { "choice", fight({ mimic = "one" }), 1 },
    { "choice", fight({ mimic = { 1 } }), 1 },
    { "choice", fight({ mimic = NULL }), 1 },
    { "choice", { battle = "b1", action = "switch", slot = 1, mimic = 2 }, 1 },
    { "choice", { battle = "b1", action = "run", mimic = 7 }, 1 },
    { "choice", fight({ mimic = 2 }), 2 },
    { "choice", fight({ mimic = 9 }), 2 },
    { "choice", fight({ mimic = 2 }), 3 },
    { "choice", fight({ mimic = 9 }), 3 },
    { "choice", fight({ mimic = 2 }) },
    { "choice", fight({ mimic = 9 }) },
    { "ruleset", rules({ timeOfDay = "morn" }), 2 },
    { "ruleset", rules({ timeOfDay = "day" }), 2 },
    { "ruleset", rules({ timeOfDay = "nite" }), 2 },
    { "ruleset", rules({ timeOfDay = "NITE" }), 2 },
    { "ruleset", rules({ timeOfDay = "night" }), 2 },
    { "ruleset", rules({ timeOfDay = "eve" }), 2 },
    { "ruleset", rules({ timeOfDay = "darkness" }), 2 },
    { "ruleset", rules({ timeOfDay = "" }), 2 },
    { "ruleset", rules({ timeOfDay = 2 }), 2 },
    { "ruleset", rules({ timeOfDay = true }), 2 },
    { "ruleset", rules({ timeOfDay = { "nite" } }), 2 },
    { "ruleset", rules({ timeOfDay = NULL }), 2 },
    { "ruleset", rules({ timeOfDay = "day", metronomePool = { row12("m", { priority = 1 }) } }), 2 },
    { "ruleset", rules({ timeOfDay = "nite" }), 1 },
    { "ruleset", rules({ timeOfDay = "evening" }), 1 },
    { "ruleset", rules({ timeOfDay = "nite" }) },
    { "ruleset", rules({ timeOfDay = "evening" }) },
    { "ruleset", { typeTable = CHART3, timeOfDay = "nite" }, 3 },
    { "ruleset", { typeTable = CHART3, timeOfDay = "evening" }, 3 },
  }
end

scenarios[#scenarios + 1] = {
  name = "referee_gaps_wave4_dialect",
  run = function()
    local out = {}
    for i, case in ipairs(wave4()) do
      local kind, input, gen = case[1], decoded(case[2]), case[3]
      local got
      if kind == "choice" then got = Wire.battleChoice(input, gen)
      elseif kind == "ruleset" then got = Wire.battleRuleset(input, gen)
      end
      out[i] = { kind = kind, got = orNil(got) }
    end
    return out
  end,
}

-- ------------------------------------------------------------------
-- Wave 4, the hubs and the real referees: a learn is judged against the
-- PARTY list and reaches the battle list only as the cart's LearnMove does
-- (`learnTo`).  Red's MIMIC pick reaches the referee off the wire (`mimic`
-- 1 copies the foe's second move; none, its first); a re-send of the same
-- ids (a level-up with no new move) leaves the copy in the fight; the copy
-- sent back as a learn is refused; a real learn lands (Red's LearnMove
-- copies the party list over the copy), and the switch-out gives back the
-- learned list.  Red and Gold: a re-send on a transformed battler leaves the
-- copied moves (on Red it used to replace them), and a MIMIC used before the
-- Transform is folded into the list put aside.  Gold's referee keeps no
-- saved MIMIC row yet, so its MIMIC run is pinned as each hub plays it, and
-- the Gold rules are driven through the exported `learnTo` on synthetic
-- state.  Last, Gold's wTimeOfDay reaches the referee off a Gen 2 ruleset
-- (MOONLIGHT heals half at night, a quarter by day, half with no clock) and
-- a Red hub reads none.
-- ------------------------------------------------------------------

local function overlayHub(generation, id, aMoves)
  local hub = makeGenHub(generation)
  local sprite = generation == 2 and Config.DEFAULT_SPRITE_GEN2 or Config.DEFAULT_SPRITE
  local a = dialAs(hub, "ANN", ID_A, { generation = generation, sprite = sprite })
  hub:openCoopBattle(id, { a.id }, { mode = "wild", hostId = a.id })
  hub:receive(a.client, { type = Wire.BATTLE_RULESET, battle = id, chart = CHART })
  hub:receive(a.client, { type = Wire.BATTLE_PARTY, battle = id, side = "a", mons = {
    sheet12(generation, { species = "COPYCAT", moves = aMoves }),
    sheet12(generation, { species = "BENCH", moves = { row12("TACKLE", { pp = 10, power = 1 }) } }) } })
  hub:receive(a.client, { type = Wire.BATTLE_PARTY, battle = id, side = "b", mons = {
    sheet12(generation, { species = "FOE", moves = { row12("GROWL", { pp = 10, power = 0 }),
                                                     row12("HUSH", { pp = 10, power = 0 }) } }) } })
  return hub, a, hub.battles[id]
end

local function ovMove(moveId, effect, power)
  return row12(moveId, { pp = 10, power = power or 0, effect = effect or 0 })
end

local function lookOverlay(live)
  local saved = live.preTransform
  local mimic = live.preMimic
  local kept = {}
  if type(mimic) == "table" then
    for i = 1, 4 do kept[#kept + 1] = mimic[i] and (i .. ":" .. mimic[i].id) or nil end
  end
  return {
    transformed = live.transformed == true,
    battle = slimRows(live.moves),
    party = saved and slimRows(saved.moves) or "(none)",
    mimic = kept,
  }
end

local function mimicLearn(generation, pick)
  local id = "m1"
  local hub, a, record = overlayHub(generation, id, { ovMove("MIMIC", 82), ovMove("TACKLE", 0, 1) })
  if not (record and record.sim) then return { opened = false } end
  hub:receive(a.client, { type = Wire.BATTLE_CHOICE, battle = id, action = "fight", move = 0,
                          mimic = pick })
  local live = record.sim.byId[a.id].mons[1]
  local steps = { lookOverlay(live) }
  local function send(moves)
    hub:receive(a.client, { type = Wire.BATTLE_MOVESET, battle = id, mon = 0, moves = moves })
    steps[#steps + 1] = lookOverlay(live)
  end
  -- a level-up with no new move: the party's ids again
  send({ ovMove("MIMIC", 82), ovMove("TACKLE", 0, 1) })
  -- the battle list sent back as a learn
  send({ ovMove(live.moves[1].id), ovMove("TACKLE", 0, 1), ovMove("LEARNT", 0, 40) })
  -- a learn
  send({ ovMove("MIMIC", 82), ovMove("TACKLE", 0, 1), ovMove("LEARNT", 0, 40) })
  hub:receive(a.client, { type = Wire.BATTLE_CHOICE, battle = id, action = "switch", slot = 1 })
  steps[#steps + 1] = lookOverlay(live)
  return { opened = true, steps = steps }
end

local function transformResend(generation, mimicFirst)
  local id = "t2"
  local moves = { ovMove("TRANSFORM", 57), ovMove("TACKLE", 0, 1) }
  if mimicFirst then moves = { ovMove("MIMIC", 82), ovMove("TRANSFORM", 57), ovMove("TACKLE", 0, 1) } end
  local hub, a, record = overlayHub(generation, id, moves)
  if not (record and record.sim) then return { opened = false } end
  if mimicFirst then
    hub:receive(a.client, { type = Wire.BATTLE_CHOICE, battle = id, action = "fight", move = 0, mimic = 1 })
  end
  hub:receive(a.client, { type = Wire.BATTLE_CHOICE, battle = id, action = "fight",
                          move = mimicFirst and 1 or 0 })
  local live = record.sim.byId[a.id].mons[1]
  local steps = { lookOverlay(live) }
  local own = {}
  for i, m in ipairs(moves) do own[i] = m end
  hub:receive(a.client, { type = Wire.BATTLE_MOVESET, battle = id, mon = 0, moves = own })
  steps[#steps + 1] = lookOverlay(live)
  own[#own + 1] = ovMove("LEARNT", 0, 40)
  hub:receive(a.client, { type = Wire.BATTLE_MOVESET, battle = id, mon = 0, moves = own })
  steps[#steps + 1] = lookOverlay(live)
  hub:receive(a.client, { type = Wire.BATTLE_CHOICE, battle = id, action = "switch", slot = 1 })
  steps[#steps + 1] = lookOverlay(live)
  return { opened = true, steps = steps }
end

-- The exported rule on synthetic state: a MIMIC's copy in slot 1 (`pp` its
-- PP), the party's MIMIC saved at 9 PP, and optionally a Transform over it.
local function synthLearn(generation, transformed)
  local function own() return { [1] = ovMove("MIMIC", 82) } end
  local mon
  if transformed then
    mon = { transformed = true, moves = { ovMove("COPY") },
            preTransform = { moves = { row12("HUSH", { pp = 4 }), ovMove("TACKLE", 0, 1) } } }
  else
    mon = { moves = { row12("HUSH", { pp = 4 }), ovMove("TACKLE", 0, 1) } }
  end
  mon.preMimic = own()
  mon.preMimic[1].pp = 9
  local steps = {}
  local function try(moves)
    steps[#steps + 1] = { applied = Hub.learnTo(generation, mon, moves), state = lookOverlay(mon) }
  end
  try({ ovMove("MIMIC", 82), ovMove("TACKLE", 0, 1) })
  try({ ovMove("NEW"), ovMove("BBB") })
  try({ ovMove("MIMIC", 82), ovMove("TACKLE", 0, 1), ovMove("LEARNT", 0, 40) })
  return steps
end

local function timeHeal(generation, timeOfDay)
  local hub = makeGenHub(generation)
  local sprite = generation == 2 and Config.DEFAULT_SPRITE_GEN2 or Config.DEFAULT_SPRITE
  local a = dialAs(hub, "ANN", ID_A, { generation = generation, sprite = sprite })
  local id = "h1"
  hub:openCoopBattle(id, { a.id }, { mode = "wild", hostId = a.id })
  hub:receive(a.client, { type = Wire.BATTLE_RULESET, battle = id, chart = CHART, timeOfDay = timeOfDay })
  local record = hub.battles[id]
  local kept = record and record.ruleset and orNil(record.ruleset.timeOfDay) or "(no ruleset)"
  hub:receive(a.client, { type = Wire.BATTLE_PARTY, battle = id, side = "a", mons = {
    sheet12(generation, { species = "MOTH", hp = 40, moves = { ovMove("MOONLIGHT", 130) } }) } })
  hub:receive(a.client, { type = Wire.BATTLE_PARTY, battle = id, side = "b", mons = {
    sheet12(generation, { species = "FOE", moves = { ovMove("HUSH") } }) } })
  if not (record and record.sim) then return { opened = false, kept = kept } end
  hub:receive(a.client, { type = Wire.BATTLE_CHOICE, battle = id, action = "fight", move = 0 })
  return { opened = true, kept = kept, simTime = orNil(record.sim.timeOfDay),
           hp = record.sim.byId[a.id].mons[1].hp }
end

scenarios[#scenarios + 1] = {
  name = "overlay_learn_and_time",
  run = function()
    return {
      redMimicPick = mimicLearn(1, 1),
      redMimicNone = mimicLearn(1, nil),
      goldMimic = mimicLearn(2, 1),
      redTransform = transformResend(1, false),
      goldTransform = transformResend(2, false),
      redMimicTransform = transformResend(1, true),
      redSynth = synthLearn(1, false),
      goldSynth = synthLearn(2, false),
      redSynthT = synthLearn(1, true),
      goldSynthT = synthLearn(2, true),
      goldNite = timeHeal(2, "nite"),
      goldDay = timeHeal(2, "day"),
      goldMorn = timeHeal(2, "morn"),
      goldNone = timeHeal(2, nil),
      goldBad = timeHeal(2, "evening"),
      redNite = timeHeal(1, "nite"),
      redBad = timeHeal(1, "evening"),
    }
  end,
}

-- ------------------------------------------------------------------
-- Wave 5 of docs/plans/gen12-referee-gaps-fix.md, the wire: Red's
-- TypeEffects order on a Gen 1 ruleset (`chartOrder`, an even list of chart
-- indices 0..BATTLE_TYPE_MAX - 1, at most CHART_ORDER_MAX; refused whole when
-- unreadable, ignored by Gen 2 / Gen 3 / a reader naming none); Gold's
-- BASE_GENDER in a Gen 2 sheet's `base` (K15, 0..255, refusing the sheet when
-- unreadable, ignored on Red); Gold's BATON PASS successor on a Gen 2 choice
-- (`pass`, Gen 3's index and bounds; a Gen 1 hub ignores it); a Gold
-- Metronome pool row's cart number (`num`, 1..NUM_ATTACKS2, refusing the
-- ruleset when unreadable; Red ignores it).  Wire.battleRuleset /
-- battleMon / battleChoice and their sanitize twins.  `orderLen` reports a
-- long list by its length, so the fixture holds the verdict, not the list.
-- ------------------------------------------------------------------

local function wave5()
  local function rules(extra) return merged({ chart = CHART }, extra) end
  local function fight(extra) return merged({ battle = "b1", action = "fight", move = 0 }, extra) end
  local B2 = { hp = 41, atk = 52, def = 63, spe = 74, spa = 85, spd = 96 }
  local B1 = { hp = 41, atk = 52, def = 63, spd = 74, spc = 85 }
  local function gold(gender) return sheet12(2, { base = merged(B2, { gender = gender }) }) end
  local function pooled(extra) return rules({ metronomePool = { row12("m", extra) } }) end
  local long = {}
  for i = 1, 514 do long[i] = i % 20 end
  local function first(n)
    local out = {}
    for i = 1, n do out[i] = long[i] end
    return out
  end
  return {
    -- chartOrder
    { "ruleset", rules({ chartOrder = { 0, 1, 1, 0 } }), 1 },
    { "ruleset", rules({ chartOrder = { 19, 19 } }), 1 },
    { "ruleset", rules({ chartOrder = { 1, 0, 1, 0 } }), 1 },
    { "ruleset", rules({ chartOrder = { 20, 0 } }), 1 },
    { "ruleset", rules({ chartOrder = { -1, 0 } }), 1 },
    { "ruleset", rules({ chartOrder = { 0, 1, 1 } }), 1 },
    { "ruleset", rules({ chartOrder = {} }), 1 },
    { "ruleset", rules({ chartOrder = { 0, NULL, 1 } }), 1 },
    { "ruleset", rules({ chartOrder = { 0, NULL, 1, 1 } }), 1 },
    { "ruleset", rules({ chartOrder = { NULL, NULL } }), 1 },
    { "ruleset", rules({ chartOrder = { "1", 0 } }), 1 },
    { "ruleset", rules({ chartOrder = { " 1 ", 0 } }), 1 },
    { "ruleset", rules({ chartOrder = { "0x1", 0 } }), 1 },
    { "ruleset", rules({ chartOrder = { 1.5, 0 } }), 1 },
    { "ruleset", rules({ chartOrder = { true, 0 } }), 1 },
    { "ruleset", rules({ chartOrder = { "one", 0 } }), 1 },
    { "ruleset", rules({ chartOrder = { { 1 }, 0 } }), 1 },
    { "ruleset", rules({ chartOrder = { a = 1 } }), 1 },
    { "ruleset", rules({ chartOrder = "0,1" }), 1 },
    { "ruleset", rules({ chartOrder = 7 }), 1 },
    { "ruleset", rules({ chartOrder = NULL }), 1 },
    { "ruleset", rules({ chartOrder = { 0, 1 }, metronomePool = { row12("m", { num = 7 }) },
                         typeIds = { "NORMAL", "FIGHTING" } }), 1 },
    { "ruleset", rules({ chartOrder = { 0, 1 } }), 2 },
    { "ruleset", rules({ chartOrder = { 0, 1, 1 } }), 2 },
    { "ruleset", rules({ chartOrder = { 0, 1 } }) },
    { "ruleset", rules({ chartOrder = "bad" }) },
    { "ruleset", { typeTable = CHART3, chartOrder = { 0, 1 } }, 3 },
    { "ruleset", { typeTable = CHART3, chartOrder = "bad" }, 3 },
    { "orderLen", rules({ chartOrder = first(512) }), 1 },
    { "orderLen", rules({ chartOrder = first(513) }), 1 },
    { "orderLen", rules({ chartOrder = first(514) }), 1 },
    { "orderLen", rules({ chartOrder = first(164) }), 1 },
    -- K15 base.gender
    { "mon", gold(0) },
    { "mon", gold(127) },
    { "mon", gold(254) },
    { "mon", gold(255) },
    { "mon", gold(256) },
    { "mon", gold(-1) },
    { "mon", gold("31") },
    { "mon", gold(" 9 ") },
    { "mon", gold("0x1f") },
    { "mon", gold(31.9) },
    { "mon", gold(true) },
    { "mon", gold("male") },
    { "mon", gold({ 31 }) },
    { "mon", gold(NULL) },
    { "mon", sheet12(2, merged(k7(2), { base = merged(B2, { gender = 31 }), generation = 2 })) },
    { "mon", sheet12(2, { base = { gender = 31 } }) },
    { "mon", sheet12(1, { base = merged(B1, { gender = 254 }) }) },
    { "mon", sheet12(1, { base = merged(B1, { gender = "male" }) }) },
    { "mon", merged(mon3(), { base = merged(B2, { gender = 31 }) }) },
    { "party", { battle = "b1", mons = { gold(31) } }, 2 },
    { "party", { battle = "b1", mons = { gold(300) } }, 2 },
    { "outcome", { battle = "b1", outcome = "win", reason = "catch", caught = gold(31) }, 2 },
    -- Gold's BATON PASS successor
    { "choice", fight({ pass = 0 }), 2 },
    { "choice", fight({ pass = 5 }), 2 },
    { "choice", fight({ pass = 6 }), 2 },
    { "choice", fight({ pass = -1 }), 2 },
    { "choice", fight({ pass = "2" }), 2 },
    { "choice", fight({ pass = " 1 " }), 2 },
    { "choice", fight({ pass = 1.5 }), 2 },
    { "choice", fight({ pass = true }), 2 },
    { "choice", fight({ pass = "two" }), 2 },
    { "choice", fight({ pass = { 1 } }), 2 },
    { "choice", fight({ pass = NULL }), 2 },
    { "choice", fight({ pass = 2, dexCaught = true }), 2 },
    { "choice", { battle = "b1", action = "switch", slot = 1, pass = 2 }, 2 },
    { "choice", fight({ pass = 2 }), 1 },
    { "choice", fight({ pass = 9 }), 1 },
    { "choice", fight({ pass = 2, mimic = 1 }), 1 },
    { "choice", fight({ pass = 2 }), 3 },
    { "choice", fight({ pass = 9 }), 3 },
    { "choice", fight({ pass = 2 }) },
    { "choice", fight({ pass = 9 }) },
    -- Gold Metronome pool `num`
    { "ruleset", pooled({ num = 1 }), 2 },
    { "ruleset", pooled({ num = 251 }), 2 },
    { "ruleset", pooled({ num = 252 }), 2 },
    { "ruleset", pooled({ num = 0 }), 2 },
    { "ruleset", pooled({ num = -1 }), 2 },
    { "ruleset", pooled({ num = "7" }), 2 },
    { "ruleset", pooled({ num = 7.5 }), 2 },
    { "ruleset", pooled({ num = true }), 2 },
    { "ruleset", pooled({ num = "x" }), 2 },
    { "ruleset", pooled({ num = { 7 } }), 2 },
    { "ruleset", pooled({ num = NULL }), 2 },
    { "ruleset", pooled({ num = 7, priority = 2, ppUps = 1 }), 2 },
    { "ruleset", rules({ metronomePool = { row12("a", { num = 3 }), row12("b") } }), 2 },
    { "ruleset", pooled({ num = 7 }), 1 },
    { "ruleset", pooled({ num = 999 }), 1 },
    { "ruleset", pooled({ num = 7 }) },
    { "ruleset", pooled({ num = 999 }) },
    -- the Gen 1 / Gen 2 pool read as a list on both twins (a null row closed
    -- up, an object refused)
    { "ruleset", rules({ metronomePool = { row12("a", { num = 3 }), NULL, row12("b") } }), 2 },
    { "ruleset", rules({ metronomePool = { NULL } }), 1 },
    { "ruleset", rules({ metronomePool = {} }), 1 },
    { "ruleset", rules({ metronomePool = { a = row12("a") } }), 2 },
    { "ruleset", rules({ metronomePool = "rows" }), 1 },
  }
end

scenarios[#scenarios + 1] = {
  name = "referee_gaps_wave5_dialect",
  run = function()
    local out = {}
    for i, case in ipairs(wave5()) do
      local kind, input, gen = case[1], decoded(case[2]), case[3]
      local got
      if kind == "ruleset" then got = Wire.battleRuleset(input, gen)
      elseif kind == "orderLen" then
        local read = Wire.battleRuleset(input, gen)
        got = read and (read.chartOrder and #read.chartOrder or "(no order)") or "(refused)"
      elseif kind == "mon" then got = Wire.battleMon(input)
      elseif kind == "party" then got = Wire.battleParty(input, gen)
      elseif kind == "outcome" then got = Wire.battleOutcome(input, gen)
      elseif kind == "choice" then got = Wire.battleChoice(input, gen)
      end
      out[i] = { kind = kind, got = orNil(got) }
    end
    return out
  end,
}

-- ------------------------------------------------------------------
-- Wave 5, the hubs and the real referees: each new field reaches its
-- referee off the wire and changes the fight the cart's way.
--
--   * Red's chartOrder: a type-0 move into a type-0 / type-1 foe on a chart
--     where 0 -> 0 is NO_EFFECT and 0 -> 1 SUPER_EFFECTIVE.  The last row
--     AdjustDamageForMoveType applied decides PrintMoveFailureText's line:
--     the immunity last is "It doesn't affect", the super-effective row last
--     is "<USER>'s attack missed!", no order is the product (an immunity).
--     A Gen 2 hub keeps none.
--   * Gold's `pass`: BATON PASS names the second bench (party index 2); with
--     none the referee picks the first living; a `pass` naming nobody is
--     refused by the referee and one past SLOT_MAX by the wire (no turn).
--   * Gold's K15 gender: ATTRACT male into female lands, male into male and a
--     sheet with no ratio fail (`.genderless_samegender`).
--   * Gold's pool `num`: METRONOME's byte is a move number, so the same
--     two-row pool calls a different move once its rows state their numbers.
-- ------------------------------------------------------------------

local function wave5Hub(generation, id, rules, aMons, bMons)
  local hub = makeGenHub(generation)
  local sprite = generation == 2 and Config.DEFAULT_SPRITE_GEN2 or Config.DEFAULT_SPRITE
  local a = dialAs(hub, "ANN", ID_A, { generation = generation, sprite = sprite })
  hub:openCoopBattle(id, { a.id }, { mode = "wild", hostId = a.id })
  hub:receive(a.client, merged({ type = Wire.BATTLE_RULESET, battle = id }, rules))
  hub:receive(a.client, { type = Wire.BATTLE_PARTY, battle = id, side = "a", mons = aMons })
  hub:receive(a.client, { type = Wire.BATTLE_PARTY, battle = id, side = "b", mons = bMons })
  a.peer.outbox = {}
  return hub, a, hub.battles[id]
end

-- The lines of `user`'s own move: from its "<USER> used" line up to the next
-- "used" line.  Only those are what each field decides; the foe's turn is the
-- referees' business (their own fixtures pin it), so it stays out of this
-- digest.
local function msgTexts(peer, user)
  local out, on = {}, false
  for _, msg in ipairs(takeAll(peer, Wire.BATTLE_EVENT)) do
    if msg.t == "msg" then
      if msg.text:find(" used ", 1, true) then on = msg.text:sub(1, #user + 1) == user .. " " end
      if on then out[#out + 1] = msg.text end
    end
  end
  return out
end

local IMMUNE_CHART = { { 0, 200 }, { 100, 100 } }

-- The computer's monster on the field (side b's seat), its HP.
local function foeHp(sim)
  for _, fighter in ipairs(sim.fighters) do
    if fighter.side == "b" then
      local live = fighter.active and fighter.mons[fighter.active]
      return orNil(live and live.hp)
    end
  end
  return "(no foe)"
end

local function redOrder(generation, order)
  local id = "co"
  local hub, a, record = wave5Hub(generation, id, { chart = IMMUNE_CHART, chartOrder = order }, {
    sheet12(generation, { species = "TAPPER", moves = { row12("TAP", { pp = 10, power = 40 }) } }) }, {
    sheet12(generation, { species = "DUO", types = { 0, 1 }, moves = { row12("HUSH", { pp = 10, power = 0 }) } }) })
  local kept = record and record.ruleset and orNil(record.ruleset.chartOrder) or "(no ruleset)"
  if not (record and record.sim) then return { opened = false, kept = kept } end
  local rows = record.sim.chartRows and #record.sim.chartRows or 0
  hub:receive(a.client, { type = Wire.BATTLE_CHOICE, battle = id, action = "fight", move = 0 })
  return { opened = true, kept = kept, rows = rows, texts = msgTexts(a.peer, "TAPPER"), foeHp = foeHp(record.sim) }
end

local function goldPass(pass)
  local id = "bp"
  local function sheet(species, moves) return sheet12(2, { species = species, moves = moves }) end
  local hub, a, record = wave5Hub(2, id, { chart = CHART }, {
    sheet("PASSER", { row12("BATON_PASS", { pp = 10, power = 0, effect = 134 }) }),
    sheet("BENCH1", { row12("TAP", { pp = 10, power = 1 }) }),
    sheet("BENCH2", { row12("TAP", { pp = 10, power = 1 }) }) }, {
    sheet("FOE", { row12("HUSH", { pp = 10, power = 0 }) }) })
  if not (record and record.sim) then return { opened = false } end
  hub:receive(a.client, { type = Wire.BATTLE_CHOICE, battle = id, action = "fight", move = 0, pass = pass })
  local fighter = record.sim.byId[a.id]
  return { opened = true, turn = record.sim.turn, active = fighter.mons[fighter.active].species,
           texts = msgTexts(a.peer, "PASSER") }
end

local function goldAttract(mine, theirs)
  local id = "at"
  local function sheet(species, gender, moves)
    local extra = k7(2)
    if gender ~= nil then extra.base = merged(extra.base, { gender = gender }) end
    return sheet12(2, merged(extra, { species = species, moves = moves }))
  end
  local hub, a, record = wave5Hub(2, id, { chart = CHART }, {
    sheet("CHARMER", mine, { row12("ATTRACT", { pp = 15, power = 0, effect = 133 }) }) }, {
    sheet("FOE", theirs, { row12("HUSH", { pp = 10, power = 0 }) }) })
  if not (record and record.sim) then return { opened = false } end
  local live = record.sim.byId[a.id].mons[1]
  local held = live.base and orNil(live.base.gender) or "(no base)"
  hub:receive(a.client, { type = Wire.BATTLE_CHOICE, battle = id, action = "fight", move = 0 })
  return { opened = true, gender = held, texts = msgTexts(a.peer, "CHARMER") }
end

local function goldMetronome(numbered)
  local id = "mt"
  local function poolRow(moveId, num)
    return row12(moveId, { pp = 10, power = 0, num = numbered and num or nil })
  end
  local hub, a, record = wave5Hub(2, id, { chart = CHART,
    metronomePool = { poolRow("CALLED_A", 200), poolRow("CALLED_B", 7) } }, {
    sheet12(2, { species = "WAGGLER", moves = { row12("METRONOME", { pp = 10, power = 0, effect = 83 }) } }) }, {
    sheet12(2, { species = "FOE", moves = { row12("HUSH", { pp = 10, power = 0 }) } }) })
  if not (record and record.sim) then return { opened = false } end
  local nums = {}
  for i, entry in ipairs(record.ruleset.metronomePool or {}) do nums[i] = orNil(entry.num) end
  hub:receive(a.client, { type = Wire.BATTLE_CHOICE, battle = id, action = "fight", move = 0 })
  return { opened = true, nums = nums, texts = msgTexts(a.peer, "WAGGLER") }
end

scenarios[#scenarios + 1] = {
  name = "wave5_hub_fields",
  run = function()
    return {
      redImmuneLast = redOrder(1, { 0, 1, 0, 0 }),
      redSuperLast = redOrder(1, { 0, 0, 0, 1 }),
      redNoOrder = redOrder(1, nil),
      redBadOrder = redOrder(1, { 0, 0, 0 }),
      goldOrderIgnored = redOrder(2, { 0, 0, 0, 1 }),
      goldPassBench2 = goldPass(2),
      goldPassNone = goldPass(nil),
      goldPassNobody = goldPass(4),
      goldPassPastMax = goldPass(6),
      goldAttractMF = goldAttract(0, 254),
      goldAttractMM = goldAttract(0, 0),
      goldAttractNone = goldAttract(nil, nil),
      goldMetronomeNum = goldMetronome(true),
      goldMetronomePlace = goldMetronome(false),
    }
  end,
}

-- ------------------------------------------------------------------
-- Wave 6 of docs/plans/gen12-referee-gaps-fix.md, the wire:
--
--   * A Red / Gold reader's `msg` keeps the carts' battle glyphs (é … ♂ ♀ &,
--     Wire.battleText): a multi-byte glyph only as its whole UTF-8 sequence,
--     every other byte past 0x7F dropped, spaces collapsed and trimmed, the
--     line cut at MESSAGE_MAX glyphs (seventy é keep sixty).  A Gen 3 or
--     unnamed reader's `msg`, and every other kind's text (`chose`, `send`),
--     read through M.text as before.  The strings here are the bytes a hub or
--     client is handed; the JS twin's are what Node's UTF-8 decoding makes of
--     the same bytes (a stray or truncated sequence is U+FFFD there), so each
--     row pins one byte stream through both readers.
--   * A Gen 1 / Gen 2 `moves` event keeps each row's `ppUps` (K8's reader,
--     0..3; a row past it is dropped like any mangled row), so a client can
--     mirror the PP Up bits DecrementPP's wrap borrows.
--   * A JSON null in a Gen 1 / Gen 2 `chart` (row or cell) or `specialTypes`
--     is closed up on both twins (lib/sanitize.js used to refuse a null row
--     and read a null cell or index as 0), each cell / index read as Wire.int
--     reads it (`true`, `{ 1 }` and "" refused on both), and an object where
--     the specialTypes list belongs refused on both (Lua used to read it as
--     no Special type).
--   * An NPC party's trainer facts: Red's `aiMods` (1..4, at most 8, a list
--     refused whole -- the party with it; ignored by a Gold / Gen 3 reader or
--     one naming no generation) and the Red / Gold display `name`
--     (Wire.npcName: the battle glyphs, cut at NPC_NAME_MAX 23; dropped, not
--     refused, when it does not read).  `npc` reports just those two fields
--     of the party read, or "(refused)".
-- ------------------------------------------------------------------

local function wave6()
  local E, ELL, MALE, FEMALE = "\195\169", "\226\128\166", "\226\153\130", "\226\153\128"
  local function line(text, t) return { battle = "b1", seq = 1, t = t or "msg", text = text } end
  local function rules(extra) return merged({ chart = CHART }, extra) end
  local function party(extra, gen) return merged({ battle = "b1", mons = { sheet12(gen or 1) } }, extra) end
  local function movesEvent(rows)
    return { battle = "b1", seq = 2, t = "moves", slot = 0, side = "a", mon = 0, moves = rows }
  end
  local texts = {
    "Both POK" .. E .. "MON will faint in 3 turns!",
    "Enemy POK" .. E .. "MON's LIGHT SCREEN fell!",
    "ALPHA ignored orders" .. ELL .. "sleeping!",
    "COOLTRAINER" .. MALE .. " used X ATTACK on JR.TRAINER" .. FEMALE .. "!",
    "TWINS AMY & MAY used an item",
    "  POK" .. E .. "  " .. ELL .. "\t" .. E .. "  ",
    "\226\195\169X",
    "\226\128\195\169",
    "\195E\169",
    "\240\159\152\128 HI",
    "POK\195\137MON",
    "POK\195\168MON",
    string.rep(E, 70),
    string.rep("A", 59) .. E .. "B",
    "#MON <PKMN> @ \\ _ ~ \194\165",
  }
  local cases = {}
  for _, gen in ipairs({ 1, 2, 3, "none" }) do
    for _, text in ipairs(texts) do
      cases[#cases + 1] = { "event", line(text), gen ~= "none" and gen or nil }
    end
  end
  local tail = {
    -- other kinds keep M.text
    { "event", line("COOLTRAINER" .. MALE, "chose"), 1 },
    { "event", line("POK" .. E .. "MON", "send"), 2 },
    { "event", line("Wild POK" .. E .. "MON fled!", "run"), 2 },
    -- ppUps on the older `moves` event
    { "event", movesEvent({ row12("TAP", { pp = 0, maxPp = 35, ppUps = 3 }),
                            row12("HUSH", { ppUps = 4 }), row12("ZAP", { ppUps = "2" }),
                            row12("NAP", { ppUps = NULL }) }), 1 },
    { "event", movesEvent({ row12("TAP", { pp = 0, maxPp = 35, ppUps = 3, priority = 2 }),
                            row12("HUSH", { ppUps = -1 }) }), 2 },
    -- chart nulls (rows and cells)
    { "ruleset", { chart = { { 100, NULL, 50 }, { 0, 200 } } }, 1 },
    { "ruleset", { chart = { NULL, { 100, 50 }, { 0, 200 } } }, 2 },
    { "ruleset", { chart = { { 100, 50 }, NULL } } },
    { "ruleset", { chart = { { NULL, NULL } } }, 1 },
    { "ruleset", { chart = { NULL } }, 1 },
    { "ruleset", { chart = { { 100, 50 }, { a = 1 } } }, 1 },
    { "ruleset", { chart = { a = { 100 } } }, 2 },
    { "ruleset", { chart = { { true, 100 } } }, 1 },
    { "ruleset", { chart = { { "100", " 50 " } } }, 2 },
    { "ruleset", { chart = { { "", 50 } } }, 1 },
    { "ruleset", { chart = { { { 100 }, 50 } } }, 1 },
    { "ruleset", { chart = { { "0x10", 50 } } }, 1 },
    -- specialTypes nulls
    { "ruleset", rules({ specialTypes = { 1, NULL, 0 } }), 1 },
    { "ruleset", rules({ specialTypes = { NULL } }), 2 },
    { "ruleset", rules({ specialTypes = {} }), 1 },
    { "ruleset", rules({ specialTypes = {} }), 2 },
    { "ruleset", rules({ specialTypes = { a = 1 } }), 1 },
    { "ruleset", rules({ specialTypes = { a = NULL } }), 2 },
    { "ruleset", rules({ specialTypes = { true } }), 1 },
    { "ruleset", rules({ specialTypes = { { 1 } } }), 2 },
    { "ruleset", rules({ specialTypes = { "" } }), 1 },
    { "ruleset", rules({ specialTypes = { "1", " 0 " } }), 2 },
    { "ruleset", rules({ specialTypes = "1" }), 1 },
    { "ruleset", rules({ specialTypes = { 1, NULL, 0 } }) },
    -- Red aiMods
    { "npc", party({ aiMods = { 1, 2, 3 } }), 1 },
    { "npc", party({ aiMods = {} }), 1 },
    { "npc", party({ aiMods = { 1, NULL, 3 } }), 1 },
    { "npc", party({ aiMods = { NULL } }), 1 },
    { "npc", party({ aiMods = { 4, 4 } }), 1 },
    { "npc", party({ aiMods = { 0 } }), 1 },
    { "npc", party({ aiMods = { 5 } }), 1 },
    { "npc", party({ aiMods = { -1 } }), 1 },
    { "npc", party({ aiMods = { "2", " 3 " } }), 1 },
    { "npc", party({ aiMods = { "0x2" } }), 1 },
    { "npc", party({ aiMods = { 1.5 } }), 1 },
    { "npc", party({ aiMods = { true } }), 1 },
    { "npc", party({ aiMods = { { 1 } } }), 1 },
    { "npc", party({ aiMods = { "" } }), 1 },
    { "npc", party({ aiMods = { 1, 2, 3, 4, 1, 2, 3, 4 } }), 1 },
    { "npc", party({ aiMods = { 1, 2, 3, 4, 1, 2, 3, 4, 1 } }), 1 },
    { "npc", party({ aiMods = { 1, 2, 3, 4, NULL, 1, 2, 3, 4 } }), 1 },
    { "npc", party({ aiMods = { a = 1 } }), 1 },
    { "npc", party({ aiMods = { a = NULL } }), 1 },
    { "npc", party({ aiMods = "1,2" }), 1 },
    { "npc", party({ aiMods = 3 }), 1 },
    { "npc", party({ aiMods = NULL }), 1 },
    { "npc", party({ aiMods = { 1, 2 }, generation = 1 }) },
    { "npc", party({ aiMods = { 9 }, generation = 1 }) },
    { "npc", party({ aiMods = { 1, 2 } }) },
    { "npc", party({ aiMods = { 9 } }) },
    { "npc", party({ aiMods = { 1, 2 } }, 2), 2 },
    { "npc", party({ aiMods = { 9 } }, 2), 2 },
    { "npc", { battle = "b1", mons = { mon3() }, aiMods = { 1 } }, 3 },
    { "npc", { battle = "b1", mons = { mon3() }, aiMods = { 9 } }, 3 },
    -- the NPC seat's display name
    { "npc", party({ name = "COOLTRAINER" .. MALE }), 1 },
    { "npc", party({ name = "POK" .. E .. "MANIAC", aiMods = { 1 } }), 1 },
    { "npc", party({ name = "JR.TRAINER" .. FEMALE }), 1 },
    { "npc", party({ name = "FIREBREATHER WALT" }, 2), 2 },
    { "npc", party({ name = "TWINS AMY & MAY" }, 2), 2 },
    { "npc", party({ name = "SWIMMER" .. MALE .. " HAROLD" }, 2), 2 },
    { "npc", party({ name = "FIREBREATHER ABCDEFGHIJ" }, 2), 2 },
    { "npc", party({ name = "FIREBREATHER ABCDEFGHIJK" }, 2), 2 },
    { "npc", party({ name = string.rep(E, 30) }, 2), 2 },
    { "npc", party({ name = "  RIVAL   BLUE  " }), 1 },
    { "npc", party({ name = "BUG_CATCHER<PK>#" }), 1 },
    { "npc", party({ name = "" }), 1 },
    { "npc", party({ name = "   " }), 1 },
    { "npc", party({ name = "\240\159\152\128" }), 1 },
    { "npc", party({ name = "\195" }), 1 },
    { "npc", party({ name = 42 }), 1 },
    { "npc", party({ name = { "A" } }), 1 },
    { "npc", party({ name = true }), 1 },
    { "npc", party({ name = NULL }), 1 },
    { "npc", party({ name = "ROCKET", generation = 2 }, 2) },
    { "npc", party({ name = "ROCKET" }) },
    { "npc", { battle = "b1", mons = { mon3() }, name = "LEADER" }, 3 },
  }
  for _, case in ipairs(tail) do cases[#cases + 1] = case end
  return cases
end

local function readWave6(kind, input, gen)
  if kind == "event" then return Wire.battleEvent(input, gen) end
  if kind == "ruleset" then return Wire.battleRuleset(input, gen) end
  if kind == "npc" then
    local read = Wire.battleParty(input, gen)
    if not read then return "(refused)" end
    return { name = orNil(read.name), aiMods = orNil(read.aiMods) }
  end
  return nil
end

scenarios[#scenarios + 1] = {
  name = "referee_gaps_wave6_dialect",
  run = function()
    local out = {}
    for i, case in ipairs(wave6()) do
      local kind, input, gen = case[1], decoded(case[2]), case[3]
      out[i] = { kind = kind, got = orNil(readWave6(kind, input, gen)) }
    end
    return out
  end,
}

-- ------------------------------------------------------------------
-- Wave 6, the hubs and the real referees: an NPC party's `name` and Red
-- `aiMods` reach the referee on every seat the trainer is dealt across, and
-- nowhere else.  The digest is each roster entry the hub hands Turn.create
-- (`name`, `aiMods`) beside what the referee kept (`fighter.name`,
-- `fighter.aiMods` -- Red's referee drops the layers off a wild seat), then,
-- for a one-human fight, the trainer's opening X item: the cart's AI item
-- line with the seat's name in it (pokered AIBattleUseItemText), as sent and
-- as a Red / Gold client's Wire.battleEvent reads it.
--
--   redNamed       COOLTRAINER♂ with layers 1, 3: named, layered, its line whole
--   redUnnamed     no name and no layers: "TRAINER", none (as before)
--   redBadName     a name that does not read is dropped: "TRAINER"; an empty
--                  layer list is a class with no layer (YOUNGSTER)
--   redBadMods     a layer off the cart's four refuses the party: no fight
--   redTwoSeats    a 2v2 trainer dealt across two seats: both carry it
--   redHumanClaims a human's own party naming a name and layers: the seat is
--                  its connection's name, and carries no layers
--   redWild        a wild seat: the hub passes what came, Red's referee keeps
--                  no layers for a wild monster
--   goldNamed      Gold: the name rides, `aiMods` is not Gold's (not read)
-- ------------------------------------------------------------------

local function npcFight(generation, mode, sideB, sideA, humans)
  local hub = makeGenHub(generation)
  local seen = {}
  local real = hub.Turn
  hub.Turn = setmetatable({
    create = function(opts) seen.opts = opts; return real.create(opts) end,
  }, { __index = real })
  local sprite = generation == 2 and Config.DEFAULT_SPRITE_GEN2 or Config.DEFAULT_SPRITE
  local ids, names = { ID_A, ID_B }, { "ANN", "BOB" }
  local players, memberIds = {}, {}
  for i = 1, humans or 1 do
    players[i] = dialAs(hub, names[i], ids[i], { generation = generation, sprite = sprite })
    memberIds[i] = players[i].id
  end
  local id = "nf"
  hub:openCoopBattle(id, memberIds, { mode = mode, hostId = memberIds[1] })
  hub:receive(players[1].client, { type = Wire.BATTLE_RULESET, battle = id, chart = CHART })
  for _, p in ipairs(players) do
    hub:receive(p.client, merged({ type = Wire.BATTLE_PARTY, battle = id, side = "a",
                                   mons = { sheet12(generation, { species = "HERO" }) } }, sideA or {}))
  end
  hub:receive(players[1].client, merged({ type = Wire.BATTLE_PARTY, battle = id, side = "b",
    mons = { sheet12(generation, { species = "FOE" }), sheet12(generation, { species = "FOE" }) } },
    sideB or {}))
  local record = hub.battles[id]
  local entries = {}
  for _, side in ipairs({ "a", "b" }) do
    for _, entry in ipairs(seen.opts and seen.opts.sides[side] or {}) do
      local npc = false
      for _, npcId in ipairs(record and record.npcIds or {}) do
        if npcId == entry.playerId then npc = true end
      end
      local fighter = record and record.sim and record.sim.byId[entry.playerId]
      entries[#entries + 1] = {
        side = side, seat = npc and "npc" or entry.playerId,
        name = orNil(entry.name), aiMods = orNil(entry.aiMods),
        simName = fighter and orNil(fighter.name) or "(no sim)",
        simAiMods = fighter and orNil(fighter.aiMods) or "(no sim)",
      }
    end
  end
  local out = { opened = record ~= nil and record.sim ~= nil, entries = entries }
  if out.opened and (humans or 1) == 1 then
    players[1].peer.outbox = {}
    hub:receive(players[1].client, { type = Wire.BATTLE_CHOICE, battle = id, action = "fight", move = 0 })
    local lines = {}
    for _, msg in ipairs(takeAll(players[1].peer, Wire.BATTLE_EVENT)) do
      if msg.t == "msg" and msg.text:find(" used ", 1, true) and msg.text:sub(1, 4) ~= "HERO" then
        local read = Wire.battleEvent(msg, generation)
        lines[#lines + 1] = { sent = msg.text, read = read and orNil(read.text) or "(refused)" }
      end
    end
    out.lines = lines
  end
  return out
end

scenarios[#scenarios + 1] = {
  name = "wave6_hub_fields",
  run = function()
    local MALE, FEMALE = "\226\153\130", "\226\153\128"
    local xItem = { { id = "X_ATTACK", count = 1 } }
    return {
      redNamed = npcFight(1, "coop_npc", { name = "COOLTRAINER" .. MALE, aiMods = { 1, 3 }, bag = xItem }),
      redUnnamed = npcFight(1, "coop_npc", { bag = xItem }),
      redBadName = npcFight(1, "coop_npc", { name = 42, aiMods = {}, bag = xItem }),
      redBadMods = npcFight(1, "coop_npc", { name = "LASS", aiMods = { 9 } }),
      redTwoSeats = npcFight(1, "coop_npc", { name = "JR.TRAINER" .. FEMALE, aiMods = { 1 } }, nil, 2),
      redHumanClaims = npcFight(1, "coop_npc", { name = "LASS" }, { name = "MALLORY", aiMods = { 2 } }),
      redWild = npcFight(1, "wild", { name = "WILD", aiMods = { 1 } }),
      goldNamed = npcFight(2, "coop_npc", { name = "TWINS AMY & MAY", aiMods = { 1 }, bag = xItem }),
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
