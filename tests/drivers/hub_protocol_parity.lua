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
-- ignored rather than read -- on both hosting paths.
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
--   * a Gen 3 sheet's `traded` / `fateful` -- true kept, false dropped,
--     anything else refuses the sheet;
--   * the `obey` event: each of the eight outcome tokens kept, any other text
--     dropped with the event kept, and the kind refused by a Gen 2 reader;
--   * a Gold party's badge names, Johto and Kanto;
--   * the Gen 1 / Gen 2 ruleset's `typeIds` (the chart's axis by name):
--     1..BATTLE_TYPE_MAX ids, anything unreadable refusing the ruleset, and
--     never read on Gen 3.
-- ------------------------------------------------------------------

local OBEY_TOKENS = { "ignores_asleep", "uses_random_move", "falls_asleep", "hits_itself",
                      "loafing", "wont_obey", "turned_away", "pretend_not_notice" }

local function badgeRules()
  local function flagged(traded, fateful)
    local sheet = mon3({ species = "MEW", speciesNum = 151 })
    sheet.traded, sheet.fateful = traded, fateful
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
      local kind, input, gen = case[1], case[2], case[3]
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
-- boundary cases of the two new readings.
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

local runs = {}
for _, scenario in ipairs(scenarios) do
  runs[#runs + 1] = {
    name = scenario.name,
    result = scenario.run(),
  }
end

io.write(enc(runs))
io.write("\n")
