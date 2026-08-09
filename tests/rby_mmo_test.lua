-- rby_mmo suite.
--
-- Two halves.
--
-- The first drives the real headless loader, which is what proves the mod
-- loads in the game: same Loader, same validate, same merge.  It asserts
-- the mod's *stated effect* -- the screens and seams it claims to install
-- are actually installed -- rather than just that nothing threw.
--
-- The second unit-tests the pure modules through the same resolver main.lua
-- uses, so the files under test are the shipped ones and not a copy.  These
-- are the parts that face the network, and they are the parts worth pinning:
-- everything arriving from another player's process goes through Wire, and
-- everything the trade and battle code sees goes through SessionNet.
--
-- Run: luajit tests/rby_mmo_test.lua   (from the engine checkout root)

package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local check, eq = T.check, T.eq

local MOD_PATH = "mods/rby_mmo"

-- ------------------------------------------------------------------
-- 1. the real load
-- ------------------------------------------------------------------

-- The committed fixture dataset, not a ROM import: this tier has to run on
-- a checkout that has never seen a ROM, which is what CI is.
--
-- The link surface is snapshotted from a no-mod load first, so the "vanilla
-- is untouched" assertion below compares against the engine's own baseline
-- rather than against hardcoded Red values the fixture does not carry.
-- That is the check that makes affects_link=false in the manifest honest:
-- if this mod ever starts writing into pokemon/moves/type_chart, two
-- players' link fingerprints diverge and this test fails first.
local function linkSurface(data)
  local rows = {}
  for _, registry in ipairs({ "pokemon", "moves" }) do
    local ids = {}
    for id in pairs(data[registry] or {}) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
      local record = data[registry][id]
      local stats = record.baseStats or {}
      rows[#rows + 1] = table.concat({
        registry, id,
        tostring(record.power), tostring(record.accuracy), tostring(record.type),
        tostring(stats.hp), tostring(stats.attack), tostring(stats.defense),
        tostring(stats.speed), tostring(stats.special),
      }, "|")
    end
  end
  return table.concat(rows, "\n")
end

local baseline = T.sdk.loadNone()
local vanillaSurface = linkSurface(baseline.data)
baseline.release()
check(#vanillaSurface > 0, "the baseline snapshot is not vacuously empty")

-- The manifest sets experimental=true, so the loader leaves the mod off
-- until the player turns it on in the mod manager.  That is the intended
-- behaviour for a mod that opens a network connection -- installing it must
-- not be what starts talking to a server -- so it is asserted, not worked
-- around.
local offByDefault = T.sdk.loadMod(MOD_PATH)
eq(#offByDefault.errors, 0, "an experimental mod still discovers cleanly")
eq(offByDefault.mod.state, "disabled",
   "experimental means off until the player opts in")
eq(offByDefault.loader.content.screens:get("RbyMmoMain"), nil,
   "and a disabled mod installs nothing")
offByDefault.release()

-- Everything past here is the opted-in mod, reached by handing the loader a
-- filesystem whose options.lua already has it enabled -- the same file the
-- mod manager writes when the player flips the switch.
local function enabledFs()
  local inner = T.fs.new(".")
  local OPTIONS = "options.lua"
  local body = "return { mods = { rby_mmo = true } }"
  local loadstr = loadstring or load
  local fs = { root = inner.root }

  function fs.read(path)
    if path == OPTIONS then return body end
    return inner.read(path)
  end
  function fs.load(path)
    if path == OPTIONS then return loadstr(body, OPTIONS) end
    return inner.load(path)
  end
  function fs.getInfo(path)
    if path == OPTIONS then return { type = "file" } end
    return inner.getInfo(path)
  end
  -- narrowed to this mod alone: the checkout also carries the gallery and
  -- nuzlocke, and a suite that loaded those too would be testing them
  function fs.getDirectoryItems(path)
    if path == "mods" then return { "rby_mmo" } end
    return inner.getDirectoryItems(path)
  end
  return fs
end

local run = T.sdk.loadMod(MOD_PATH, { fs = enabledFs() })

eq(#run.errors, 0, "loads clean through the headless loader")
check(run.mod ~= nil, "the loader found the mod")
eq(run.mod.state, "loaded", "the mod reached the loaded state once enabled")

-- the screens it says it installs
local screens = run.loader.content.screens
for _, id in ipairs({
  "RbyMmoMain", "RbyMmoRoster", "RbyMmoActions", "RbyMmoChatLog",
  "RbyMmoScope", "RbyMmoCompose", "RbyMmoPick", "RbyMmoText",
  "RbyMmoConfirm", "RbyMmoState", "RbyMmoProfile", "RbyMmoRank",
  "RbyMmoHostSetup", "RbyMmoHostInfo", "RbyMmoJoinAddress",
  "RbyMmoParty", "RbyMmoPartyList", "RbyMmoFriends",
  "RbyMmoCharSetup", "RbyMmoCharPick",
  "RbyMmoChoose", "RbyMmoChooseMenu",
  "RbyMmoServers", "RbyMmoServerActions", "RbyMmoServerEdit",
}) do
  check(screens:get(id) ~= nil, "screen " .. id .. " is registered")
end

-- the seams it says it wraps
for _, hook in ipairs({ "input.step", "render.hud", "ui.start_menu.items",
                        "ui.naming.grid", "render.zones", "player.sprite",
                        "movement.speed" }) do
  local chain = run.loader.hooks.chains[hook]
  check(chain ~= nil and #chain > 0, "wraps " .. hook)
end

-- NEW GAME emits save.created, never save.loaded -- so a mod that only
-- listens for one leaves the other world half torn down (see Client.lua's
-- own header on why: the engine reuses one player entity for the life of
-- the process, so a stash taken before QUIT is still standing after the
-- title screen unless something drops it). Both have to be subscribed, not
-- just one, and this is the seam that says so without needing a live
-- world to fire either event through.
for _, name in ipairs({ "save.loaded", "save.created" }) do
  local listeners = run.loader.events.listeners[name]
  check(listeners ~= nil and #listeners > 0,
        "subscribes to " .. name .. ", so a fresh save is resynced exactly "
        .. "like a loaded one")
end

-- ------- movement.speed: holding B on foot halves the step
--
-- Driven straight off the registered chain entry rather than through a
-- Client export, because the wrap runs entirely inside the closure the
-- loader captured -- this is the same chain OverworldController's
-- Player:tryMove would call, with a passthrough `next` standing in for it.
-- `frames` is frames-per-tile, so the arithmetic is relative to whatever the
-- engine handed in, never a hardcoded 8.
--
-- Wrapped for scope, the way later sections in this file are: the main
-- chunk is close enough to Lua's 200-local ceiling that a handful of new
-- names here is enough to cross it.

;(function()

local speedChain = run.loader.hooks.chains["movement.speed"]
local speedEntry = speedChain[1]
local passthroughNext = function(f) return f end

local heldB = { isDown = function(_, b) return b == "b" end }
local notHeldB = { isDown = function(_, b) return false end }

eq(speedEntry.callback(passthroughNext, 16, { input = heldB }), 8,
   "on foot with B held, a 16-frame walk tile runs at 8")
eq(speedEntry.callback(passthroughNext, 11, { input = heldB }), 5,
   "the halving floors rather than rounds")
check(speedEntry.callback(passthroughNext, 1, { input = heldB }) >= 1,
      "and never drops below one frame a tile")

-- Only the *speed* passes through here. What the step is reported as is a
-- separate question, and a bike step is reported fast -- the wire flag means
-- pace, not "B was held" (src/Client.lua). That side of the wrap writes to a
-- Client local the loader gives this suite no handle on, so it is covered
-- where it lands instead: the roster and Avatars sections below drive a
-- `fast` row through to npc.stepFrames, and the e2e drivers assert the flag
-- actually crossed the wire.
eq(speedEntry.callback(passthroughNext, 16, { input = heldB, onBike = true }), 16,
   "the bike is already fast, so holding B changes nothing about its speed")
eq(speedEntry.callback(passthroughNext, 16, { input = heldB, surfing = true }), 16,
   "and surfing is left alone too")
eq(speedEntry.callback(passthroughNext, 16, { input = notHeldB }), 16,
   "letting go of B walks at the ordinary pace")

-- the loader's own option store, the same one mod.options:get reads --
-- toggling it off is what a player who wants their old walk speed back does
run.loader.modOptions["rby_mmo"] = { run = false }
eq(speedEntry.callback(passthroughNext, 16, { input = heldB }), 16,
   "and turning B TO RUN off walks at the ordinary pace even with B held")
run.loader.modOptions["rby_mmo"] = nil

end)()

-- ------- the characters it brings of its own
--
-- Asserted through the real loader rather than a stub because the shape is
-- the point: Chars.list offers a sprite only if the *catalog* says it walks,
-- and SpriteRenderer cuts frames out of `image` on the strength of `frames`.
-- A record that registered but lied about either would be a character that
-- appears in the picker and then draws wrongly on every other player's
-- screen, which no unit test of this mod's own code could see.
for _, id in ipairs({ "SPRITE_NIRE", "SPRITE_NIRE_HOOD" }) do
  local record = run.loader.content.sprites:get(id)
  check(record ~= nil, id .. " is in the character catalog")
  if record then
    eq(record.walker, true, id .. " walks, so it can be worn")
    eq(record.frames, 6, id .. " carries a full six-frame sheet")
    check(type(record.image) == "string"
          and record.image:find(MOD_PATH, 1, true) == 1,
          id .. "'s art comes out of the mod folder")
  end
  -- and the game's own view of the catalog sees it, which is what the
  -- renderer and the avatar layer actually read
  check((run.data.sprites or {})[id] ~= nil, id .. " reaches the merged data")
end

-- The back pic is 48x48 art that has to draw at a whole number: the classic
-- battle view hands the registered scale straight to a nearest-neighbour
-- draw call, so a fraction would spread some source pixels over one
-- destination pixel and others over two. 1 is the only whole number this
-- art size can draw at without standing in the text box.
for _, id in ipairs({ "rby_mmo_nire_back", "rby_mmo_nire_hood_back" }) do
  local scale = run.loader.content.battle_sprite_scales:get(id)
  check(scale ~= nil, id .. " sizes its back pic")
  if scale then
    eq(scale.scale, 1, id .. " draws at exactly 1x")
    check(type(scale.path) == "string"
          and scale.path:find(MOD_PATH, 1, true) == 1,
          id .. " points at the mod's own art")
  end
end

-- the inter-mod surface it publishes
local exports = run.loader.exports["rby_mmo"]
check(type(exports) == "table", "publishes exports")
check(type(exports.isHosting) == "function", "exports isHosting")
eq(exports.isHosting(), false, "and reports not hosting on a fresh load")
check(type(exports.hostAddress) == "function", "exports hostAddress")
eq(exports.hostAddress(), false, "which is falsy while not hosting")
check(type(exports.chat) == "function", "exports chat")
eq(#exports.chat(), 0, "with no messages on a fresh load")
-- The toast queue is the only record a toast leaves once it expires; a
-- driver reads it here rather than through a screenshot.
check(type(exports.toasts) == "function", "exports toasts")
eq(exports.toasts().count, 0, "with nothing stacked on a fresh load")
check(type(exports.isConnected) == "function", "exports isConnected")
check(type(exports.players) == "function", "exports players")
eq(exports.isConnected(), false, "reports disconnected before connecting")
eq(#exports.players(), 0, "the roster starts empty")
check(type(exports.party) == "function", "exports party")
eq(#exports.party(), 0, "and nobody is in one before connecting")
-- Whether the hub this copy is on treats it as an operator's connection
-- (docs/plans/admin-join-code.md #4/D). Derived only from a credential a
-- real hub grants; a client that never connected has none, so the honest
-- answer is false, the same shape isHosting/isConnected already pin above.
check(type(exports.isAdmin) == "function", "exports isAdmin")
eq(exports.isAdmin(), false, "and reports no operator status on a fresh load")
-- The rows and not the store: a hub this copy has played on is a fact another
-- mod may want to read, and a mutator it may not.
check(type(exports.servers) == "function", "exports servers")
eq(#exports.servers(), 0, "with nothing on the list before a hub answers")
-- The four-way PARTY BATTLE ask, which only a four-client run can exercise
-- for real -- so the seat it is watched through has to exist here.
check(type(exports.coopAsk) == "function", "exports coopAsk")
eq(exports.coopAsk(), nil, "with nothing asked before connecting")

-- Vanilla must be untouched.  This mod adds multiplayer; it does not change
-- Gen 1 content, which is exactly what affects_link=false promises about
-- the link fingerprint.
eq(linkSurface(run.data), vanillaSurface,
   "the link surface is byte-identical with the mod installed")

run.release()

-- ------------------------------------------------------------------
-- 2. the modules, through main.lua's own resolver
-- ------------------------------------------------------------------

local stubSave, stubOptions, stubPipelines = {}, {}, {}
local stubSprites = {}
local stubScales = {}

local stubEvents = {}

local stubMod = {
  id = "rby_mmo",
  path = MOD_PATH,
  log = {
    info = function() end,
    warn = function() end,
    error = function() end,
  },
  -- mod.save is writable by a mod; mod.options is not. The stub mirrors
  -- that asymmetry, because the settings code depends on it.
  save = {
    get = function(_, key, default)
      local value = stubSave[key]
      if value == nil then return default end
      return value
    end,
    set = function(_, key, value) stubSave[key] = value end,
  },
  options = {
    define = function() end,
    get = function(_, key) return stubOptions[key] end,
  },
  -- Every event the mod emits, kept rather than dropped.
  --
  -- There was no `events` on this stub at all, so `mod.events:emit` threw
  -- inside the pcall that guards it and every announcement the mod makes was
  -- swallowed in silence -- which is exactly the shape of bug an event is for
  -- reporting. A recorder makes them assertable.
  events = {
    emit = function(_, name, payload)
      stubEvents[#stubEvents + 1] = { name = name, payload = payload }
    end,
    on = function() end,
    once = function() end,
  },
  -- the mod's own files, addressed the way the loader addresses them
  assets = { path = function(_, relative) return MOD_PATH .. "/" .. relative end },
  -- only what Overlay's pipeline query touches, plus the two registries Cast
  -- writes the mod's own characters into
  content = {
    sprites = {
      each = function()
        local id = nil
        return function()
          id = next(stubSprites, id)
          if id == nil then return nil end
          return id, stubSprites[id]
        end
      end,
      get = function(_, id) return stubSprites[id] end,
      register = function(_, id, record) stubSprites[id] = record end,
    },
    battle_sprite_scales = {
      get = function(_, id) return stubScales[id] end,
      register = function(_, id, record) stubScales[id] = record end,
    },
    render_pipelines = {
      each = function(self)
        local id = nil
        return function()
          id = next(stubPipelines, id)
          if id == nil then return nil end
          return id, stubPipelines[id]
        end
      end,
    },
  },
}

-- `modOverride` lets a caller build a module graph against a mod facade of
-- its own rather than the shared `stubMod` above -- the servers/WELCOME
-- section below needs a `mod.hooks` that actually records what it is
-- handed (to reach the per-tick chain), which would be wrong to wire onto
-- the stub every other section in this file shares.
local function resolver(modOverride)
  local useMod = modOverride or stubMod
  local loadstr = loadstring or load
  local cache = {}
  local function need(name)
    if cache[name] then return cache[name] end
    local handle = io.open(MOD_PATH .. "/src/" .. name .. ".lua", "rb")
    if not handle then error("missing module " .. name, 0) end
    local body = handle:read("*a")
    handle:close()
    local chunk = assert(loadstr(body, "@" .. name .. ".lua"))
    cache[name] = chunk(need, useMod)
    return cache[name]
  end
  return need
end

local need = resolver()
local Config = need("Config")
local Wire = need("Wire")
local Roster = need("Roster")
local Chat = need("Chat")
local Toast = need("Toast")
local SessionNet = need("SessionNet")
local Transport = need("Transport")

-- ------------------------------------------------------------------
-- Sha256: pinned against the published standard, then against Node
-- ------------------------------------------------------------------
--
-- src/Sha256.lua is a from-scratch SHA-256 / HMAC-SHA256 (its own header
-- explains why: love.data is unavailable under this headless suite). A
-- hand-written digest is exactly the kind of code that can be subtly wrong
-- and still agree with itself, so every check below is against an outside
-- source of truth -- RFC 4231, FIPS 180-4, or Node's node:crypto via
-- tests/fixtures/hmac_vectors.lua -- never Sha256 asserting against Sha256.

local Sha256 = need("Sha256")
local Vectors = dofile(MOD_PATH .. "/tests/fixtures/hmac_vectors.lua")

-- hex -> raw bytes, for RFC 4231's keys and messages, several of which are
-- not text (a 20/131-byte key of 0x0b/0xaa, 50 bytes of 0xdd)
local function fromHex(hex)
  return (hex:gsub("..", function(cc) return string.char(tonumber(cc, 16)) end))
end

for _, v in ipairs(Vectors.SHA256) do
  eq(Sha256.hex(v.input), v.digest,
     "Sha256.hex matches the standard vector: " .. v.label)
end

for _, v in ipairs(Vectors.RFC_HMAC) do
  eq(Sha256.hmacHex(fromHex(v.keyHex), fromHex(v.dataHex)), v.digest,
     "Sha256.hmacHex matches RFC 4231 test case " .. v.case)
end
-- case 6 alone exercises the key-longer-than-the-block path (131 bytes into
-- a 64-byte block), so it is worth naming on its own rather than trusting
-- the loop above to have covered it
local case6
for _, v in ipairs(Vectors.RFC_HMAC) do
  if v.case == 6 then case6 = v end
end
check(case6 ~= nil, "RFC 4231 case 6 is present in the fixture")
eq(#fromHex(case6.keyHex), 131,
   "case 6's key really is longer than the HMAC block size")

-- the cross-language known-answer vector server/auth.test.js already fixes.
-- The Lua-side key is the *normalised* code as ASCII bytes -- never the
-- dashed display form -- which is what Wire.code produces and what Hub.lua
-- actually signs with, so this doubles as a Wire.code cross-check.
eq(Wire.code(Vectors.KAT.code), Vectors.KAT.code,
   "the known-answer vector's code normalises the way the digest assumes")
eq(Sha256.hmacHex(Wire.code(Vectors.KAT.code), Vectors.KAT.nonce), Vectors.KAT.digest,
   "the cross-language known-answer vector (also fixed by server/auth.test.js) "
   .. "reproduces exactly")

-- the generated cross-language set: (code, nonce) -> digest triples Node
-- produced, covering canonical/lowercase/messy/old-dashed-habit spellings of
-- one code, an I/L/O/U-noise spelling, every character of
-- Config.CODE_ALPHABET across the set, and 32-hex nonces throughout. A drift
-- in either Wire.code or Sha256.hmacHex shows up here as a specific failing
-- label, not as "wrong join code" in the field.
for _, v in ipairs(Vectors.CROSS) do
  eq(Wire.code(v.code), v.normalized,
     "Wire.code normalises like Node's normalizeCode: " .. v.label)
  eq(Sha256.hmacHex(v.normalized, v.nonce), v.digest,
     "Sha256.hmacHex matches the Node-generated vector: " .. v.label)
end

-- embedded \0 does not truncate the digest the way a C-string read would
local withNul = fromHex("6162630064656600676869")
eq(#withNul, 11, "the embedded-\\0 fixture really is 11 raw bytes")
eq(Sha256.hex(withNul), "039829b9687ee660b05223c59daa86348bf5856dda159e65412a454c57dc1911",
   "a NUL byte inside the message does not truncate the digest")

-- the 55/56/64-byte padding boundaries: FIPS 180-4 padding needs a 0x80
-- byte plus an 8-byte length field, so a message must be under 56 bytes to
-- keep its padding inside the same block; 56 spills into a second block,
-- and 64 is exactly one full block with the pad occupying an entire block
-- of its own
eq(Sha256.hex(string.rep("a", 55)), "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318",
   "55 bytes -- padding still fits in the same block")
eq(Sha256.hex(string.rep("a", 56)), "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a",
   "56 bytes -- padding spills into a second block")
eq(Sha256.hex(string.rep("a", 64)), "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb",
   "64 bytes -- exactly one full block, padding is a block of its own")

-- ------- Sha256.equals: constant-time, but still just equality

check(Sha256.equals("abc123", "abc123"), "equals is true for identical strings")
check(not Sha256.equals("abc123", "abc124"), "and false for a one-character difference")
check(not Sha256.equals("abc", "abcd"), "and false when the lengths differ")
check(Sha256.equals(fromHex("610062"), fromHex("610062")),
      "and true for equal strings containing \\0")

-- ------- Wire: the trust boundary

eq(Wire.text("HELLO"), "HELLO", "plain text survives")
eq(Wire.text("  spaced   out  "), "spaced out", "runs of whitespace collapse")
eq(Wire.text("drop\0these\tbytes"), "dropthesebytes", "control bytes are dropped")
eq(Wire.text("emoji \240\159\152\128 gone"), "emoji gone",
   "multi-byte sequences the font cannot draw are dropped")
eq(Wire.text(""), nil, "an empty string is not a message")
eq(Wire.text("   "), nil, "whitespace alone is not a message")
eq(Wire.text(12345), nil, "a non-string is not a message")
eq(#Wire.text(string.rep("a", 500)), Config.MESSAGE_MAX, "text is capped")
eq(#Wire.name(string.rep("b", 50)), Config.NAME_MAX, "names are capped shorter")

-- ------- MOTD: the same sanitiser, a bigger budget
--
-- src/Client.lua's welcome handler makes exactly this call --
-- `Wire.text(msg.motd, Config.MOTD_MAX)` -- so the budget is pinned here
-- against drift, and the call is exercised at the two edges plus the
-- untrusted-input floor Wire.text already guarantees every other field.

eq(Config.MOTD_MAX, 120, "the MOTD budget is pinned")
check(Config.MOTD_MAX > Config.MESSAGE_MAX,
      "a hub's message of the day gets more room than one chat line")

-- Wrapped for scope, the way the movement.speed block above is: kept out of
-- the main chunk's own locals so this file stays under Lua's 200-local cap.
;(function()
  local motdWhole = string.rep("m", Config.MOTD_MAX)
  eq(Wire.text(motdWhole, Config.MOTD_MAX), motdWhole,
     "exactly MOTD_MAX characters survive whole")
  local motdOverlong = string.rep("m", Config.MOTD_MAX + 1)
  local motdTruncated = Wire.text(motdOverlong, Config.MOTD_MAX)
  eq(#motdTruncated, Config.MOTD_MAX, "one character over the budget is cut to it")
  eq(motdTruncated, motdWhole, "and the surviving characters are the leading ones")
end)()
eq(Wire.text(nil, Config.MOTD_MAX), nil, "a nil motd -- an old hub's silence -- is nil")
eq(Wire.text(42, Config.MOTD_MAX), nil, "a non-string motd is nil, not stringified")
eq(Wire.text("", Config.MOTD_MAX), nil, "an empty motd is nil, same as an empty chat line")
eq(Wire.text("   ", Config.MOTD_MAX), nil, "whitespace alone is nil here too")

eq(Wire.id("abc_123-x"), "abc_123-x", "a well-formed id survives")
eq(Wire.id("../../etc/passwd"), nil, "a path is not an id")
eq(Wire.id(""), nil, "an empty id is rejected")

eq(Wire.int("42", 0, 100), 42, "a numeric string becomes a number")
eq(Wire.int(7.9, 0, 100), 7, "floats are floored")
eq(Wire.int(0 / 0, 0, 100), nil, "NaN is rejected")
eq(Wire.int(math.huge, 0, 100), nil, "infinity is rejected")
eq(Wire.int(500, 0, 100), nil, "out of range is rejected")
eq(Wire.int(-1, 0, 100), nil, "below range is rejected")

-- Sprite ids are identifiers, not prose. Running one through the chat
-- sanitiser strips the underscore, and SPRITE_RED silently became
-- SPRITERED -- which missed the catalog lookup and drew every remote player
-- as the fallback. Found by the first real two-instance run; pinned here.
eq(Wire.spriteId("SPRITE_RED"), "SPRITE_RED", "an underscore survives a sprite id")
eq(Wire.text("SPRITE_RED"), "SPRITERED",
   "which the prose sanitiser would have eaten -- hence the separate one")
eq(Wire.spriteId("SPRITE_COOLTRAINER_M"), "SPRITE_COOLTRAINER_M",
   "several underscores too")
eq(Wire.spriteId("../etc/passwd"), nil, "a path is not a sprite id")
eq(Wire.spriteId("has space"), nil, "nor is anything with a space")
eq(Wire.spriteId(42), nil, "nor a non-string")

-- Too long is refused rather than truncated, so both hubs answer the same
-- bytes the same way -- see Wire.spriteId's own header for why a cut id is
-- worse than a rejected one.
eq(Wire.spriteId(string.rep("a", 40)), string.rep("a", 40),
   "exactly forty characters is accepted")
eq(Wire.spriteId(string.rep("a", 41)), nil,
   "forty-one is refused outright, not trimmed back to forty")

-- The message type mmo.sprite rides on -- see its header in src/Wire.lua for
-- why one name serves both directions.
eq(Wire.SPRITE, "mmo.sprite",
   "the wire vocabulary carries the character-change message type")

eq(Wire.presence({ id = "s1", name = "ANN", sprite = "SPRITE_BLUE" }).sprite,
   "SPRITE_BLUE", "and presence carries it through intact")

eq(Wire.facing("left"), "left", "a real facing survives")
eq(Wire.facing("sideways"), nil, "an invented facing is rejected")
eq(Wire.mapId("PALLET_TOWN"), "PALLET_TOWN", "a map id survives")
eq(Wire.mapId("../secret"), nil, "a traversal is not a map id")

local presence = Wire.presence({
  id = "p1", name = "ASH", sprite = "SPRITE_RED",
  map = "PALLET_TOWN", x = 5, y = 6, facing = "up",
})
check(presence ~= nil, "a full presence sanitises")
eq(presence.x, 5, "position survives")
eq(presence.busy, false, "busy defaults to false")

eq(Wire.presence({ name = "NOID" }), nil, "presence without an id is rejected")
eq(Wire.presence({ id = "p2" }), nil, "presence without a name is rejected")

-- a half-formed position must not place an avatar at a made-up cell
local partial = Wire.presence({ id = "p3", name = "MISTY", map = "VIRIDIAN", x = 4 })
check(partial ~= nil, "presence survives a missing position")
eq(partial.map, nil, "an incomplete position is dropped whole")
eq(partial.x, nil, "x goes with it")

eq(Wire.presence({ id = "p4", name = "BROCK" }).sprite, Config.DEFAULT_SPRITE,
   "a missing sprite falls back rather than failing")

-- ------- parties on the wire
--
-- Presence carries whether somebody is in a party and never which one: it is
-- what decides whether the INVITE row is offered, and a party id on every
-- presence would let any client map out who is travelling with whom.

eq(presence.party, false, "presence with no party field reads as unattached")
eq(Wire.presence({ id = "p5", name = "MISTY", party = true }).party, true,
   "and a party flag survives")
eq(Wire.presence({ id = "p6", name = "GARY", party = "7" }).party, true,
   "a party id sent where a flag belongs is reduced to the flag")

-- ------- pace on the wire
--
-- Client truth, the same shape as party: nothing the hub can see says
-- whether a player is holding B or riding a bike, so the sender's word is
-- taken. The coercion is *stricter* than party's, though -- both hubs
-- re-derive this one field from the same wire bytes, and Lua and JS
-- truthiness part ways on 0 and "", so only a literal true counts.

eq(presence.fast, false, "presence with no fast field reads as walking pace")
eq(Wire.presence({ id = "p7", name = "MISTY", fast = true }).fast, true,
   "and a fast flag survives")
eq(Wire.presence({ id = "p8", name = "GARY", fast = "junk" }).fast, false,
   "while junk in the field is walking pace -- only a literal true is fast")

local member = Wire.member({ id = "m1", name = "ANN", x = 4, y = 9 })
check(member ~= nil, "a members row sanitises")
eq(member.name, "ANN", "keeping the name")
eq(member.x, nil, "and dropping a position it has no business carrying")
eq(Wire.member({ name = "NOID" }), nil, "a row without an id is rejected")
eq(Wire.member({ id = "m2" }), nil, "and one without a name")

local members = Wire.members({ { id = "m1", name = "ANN" },
                               { id = "m2", name = "BOB" } })
eq(#members, 2, "a full members list survives")
eq(members[2].name, "BOB", "in the order the hub sent it")

-- A list refused whole, never delivered short: a party you are told has one
-- member when it has two is worse than one you are told nothing about,
-- because every screen would draw the wrong thing confidently.
eq(Wire.members({ { id = "m1", name = "ANN" }, { name = "BROKEN" } }), nil,
   "one bad row refuses the whole list")
eq(Wire.members({}), nil, "an empty party is not a party")
eq(Wire.members("nonsense"), nil, "and neither is a string")

local overfull = {}
for i = 1, Config.PARTY_MAX + 1 do
  overfull[i] = { id = "m" .. i, name = "P" .. i }
end
eq(Wire.members(overfull), nil,
   "a hub claiming more members than PARTY_MAX is refused, not truncated")

-- ------- Wire.partyEvent: what your partner just did, off the wire
--
-- The fighter never sends their own name and the hub stamps it from the
-- connection -- so a good outbound payload from the fighter's own client
-- (no name) and a good inbound one the hub has stamped (with a name) are
-- both exercised, and the sanitiser is the same call either way.

local defeatWild = Wire.partyEvent({
  kind = "defeat_wild", name = "ANN", species = "PIDGEY", level = 5,
})
check(defeatWild ~= nil, "a good wild-win event sanitises")
eq(defeatWild.name, "ANN", "keeping the name")
eq(defeatWild.species, "PIDGEY", "and the species")
eq(defeatWild.level, 5, "and the level")

for _, kind in ipairs({ "defeat_wild", "defeated_by_wild", "capture" }) do
  local mon = Wire.partyEvent({ kind = kind, name = "ANN", species = "MEW", level = 70 })
  check(mon ~= nil, "a good mon event of kind " .. kind .. " sanitises")
  eq(mon.kind, kind, "keeping its kind")
end

for _, kind in ipairs({ "defeat_trainer", "defeated_by_trainer" }) do
  local trainer = Wire.partyEvent({ kind = kind, name = "ANN", trainer = "BUG CATCHER" })
  check(trainer ~= nil, "a good trainer event of kind " .. kind .. " sanitises")
  eq(trainer.trainer, "BUG CATCHER", "keeping the trainer's name")
  eq(trainer.species, nil, "and carrying no species -- a trainer event never has one")
end

eq(Wire.partyEvent({ kind = "picnic", name = "ANN" }), nil,
   "an unknown kind is refused -- the set is closed the way COOP_REASONS is")
eq(Wire.partyEvent({ kind = "defeat_wild", species = "PIDGEY", level = 5 }), nil,
   "a mon event with no name is refused -- there is nobody the sentence is about")
eq(Wire.partyEvent({ kind = "defeat_wild", name = "ANN", level = 5 }), nil,
   "a mon event missing its species is refused rather than delivered half-built")
eq(Wire.partyEvent({ kind = "defeat_wild", name = "ANN", species = "PIDGEY" }), nil,
   "and so is one missing its level")
eq(Wire.partyEvent({ kind = "defeat_trainer", name = "ANN" }), nil,
   "a trainer event missing the trainer is refused the same way")
eq(Wire.partyEvent({ kind = "defeat_wild", name = "ANN", species = "PIDGEY", level = 0 }), nil,
   "level 0 is below the floor -- Gen 1 has no level-0 POKeMON")
eq(Wire.partyEvent({ kind = "defeat_wild", name = "ANN", species = "PIDGEY", level = 101 }), nil,
   "and level 101 is past LEVEL_MAX, the cap on a number about to be printed "
   .. "on somebody else's screen")
eq(Wire.partyEvent({ kind = "defeat_wild", name = "ANN", species = "PIDGEY", level = 100 })
   .level, 100, "while exactly the cap is a real level and survives")
eq(Wire.partyEvent("nonsense"), nil, "a non-table event is refused outright")
eq(Wire.partyEvent(nil), nil, "and so is nothing at all")

-- The fighter's own client never gets to claim the name displayed to their
-- partner -- the hub is the one that stamps it -- but the sanitiser itself
-- only ever validates the `name` field it is handed; a bad one is refused
-- exactly like a bad species or level.
eq(Wire.partyEvent({ kind = "capture", species = "MEW", level = 5 }), nil,
   "a capture with no name is refused just like any other kind")

-- ------- ranked fields off the wire
--
-- A rating is drawn straight onto a trainer card and a leaderboard row, so
-- it is re-derived like everything else here: the hub is another process,
-- and a modified one is a normal thing to meet.

eq(Wire.outcome("win"), "win", "a win is an outcome")
eq(Wire.outcome("loss"), "loss", "so is a loss")
eq(Wire.outcome("draw"), "draw", "and a draw, which scores nothing")
eq(Wire.outcome("WIN"), nil, "the vocabulary is exact, not case-folded")
eq(Wire.outcome("victory"), nil, "an invented outcome is refused")
eq(Wire.outcome(1), nil, "and so is a number")

local TOKEN = string.rep("ab", 16)
eq(Wire.token(TOKEN), TOKEN, "a claim token is 32 lowercase hex characters")
eq(Wire.token(string.rep("ab", 8)), nil,
   "a short one is refused rather than kept: it would fail every claim, "
   .. "silently, from then on")
eq(Wire.token(string.rep("ab", 40)), nil, "and a long one too")
eq(Wire.token(TOKEN:upper()), nil, "upper case is a different string, not the same token")
eq(Wire.token("zz" .. TOKEN:sub(3)), nil, "and a non-hex character is not a token")
eq(Wire.token(nil), nil, "nothing is not a token")

eq(Wire.points(120), 120, "a rating in range survives")
eq(Wire.points(0), 0, "zero is a rating, not a missing one")
eq(Wire.points(-5), 0, "below the floor reads as zero rather than negative")
eq(Wire.points(Config.RANK_MAX + 1), 0,
   "and so does a value past the ceiling -- a card says 0 rather than "
   .. "drawing a number the hub could not have meant")
eq(Wire.points("many"), 0, "a non-number is zero, never nil: the row draws either way")

eq(Wire.presence({ id = "p9", name = "GARY", points = 250 }).points, 250,
   "presence carries the rating, so a card shows the live number")
eq(Wire.presence({ id = "p9", name = "GARY" }).points, 0,
   "and an absent one reads as unranked")

-- wrapped so the locals below are released again: this chunk is close to
-- Lua's 200-local ceiling for one function body, which is why the trade
-- section further down lives inside a function of its own
do
local board = Wire.ranking({
  { name = "ALPHA", sprite = "SPRITE_RED", points = 300 },
  { name = "BRAVO", sprite = "SPRITE_LASS", points = 100 },
})
eq(#board, 2, "a leaderboard survives the trip")
eq(board[1].name, "ALPHA", "in the hub's order, which is the ranking")
eq(board[2].points, 100, "with the points intact")
eq(Wire.ranking({ { name = "   ", points = 5 }, { name = "CAL", points = 4 } })[1]
   .name, "CAL", "a nameless row is dropped rather than repaired")
eq(Wire.ranking({ { name = "DEL" } })[1].sprite, Config.DEFAULT_SPRITE,
   "a row with no character falls back to one everybody has")
eq(#Wire.ranking("not a list"), 0, "a non-list leaderboard is an empty one")

local overlong = {}
for i = 1, Config.RANK_TOP + 5 do
  overlong[i] = { name = "P" .. i, points = 100 - i }
end
eq(#Wire.ranking(overlong), Config.RANK_TOP,
   "the length is ours, not the hub's: a hub cannot decide how big this screen is")
end

-- ------- payload shape (the relay's only defence)

local function nest(depth)
  local node = { leaf = 1 }
  for _ = 1, depth do node = { node } end
  return node
end

eq(Wire.payloadOk({ type = "party", mons = { { species = "PIKACHU" } } }), true,
   "an ordinary link payload passes")
eq(Wire.payloadOk(nest(6)), true, "so does a party-shaped nesting depth")
eq(Wire.payloadOk("not a table"), false, "a scalar is not a payload")
eq(Wire.payloadOk(nil), false, "nor is nothing")

-- The regression. src/link/Json.lua decodes inside a pcall and tolerates
-- input far deeper than Json.encode can re-emit, so a payload nested a few
-- thousand levels used to decode fine and then throw while being forwarded
-- -- taking the host's whole game down with it. ~12KB of brackets, well
-- under the line cap, from any player already in a session with you.
eq(Wire.payloadOk(nest(6000)), false, "a payload deep enough to break the "
   .. "encoder is refused before it is forwarded")
eq(Wire.payloadOk(nest(Config.PAYLOAD_MAX_DEPTH + 5)), false,
   "and so is anything past the depth budget")

-- breadth is bounded too, so a flat-but-enormous payload cannot get through
local wide = {}
for i = 1, Config.PAYLOAD_MAX_NODES + 50 do wide[i] = i end
eq(Wire.payloadOk(wide), false, "an over-wide payload is refused")

-- ------- Wire.code / Wire.hex / Wire.formatCode: the join-code sanitisers
--
-- Wire.code normalises exactly the way server/lib/auth.js's normalizeCode
-- does -- same inputs, same verdicts -- so both suites assert the same
-- cases from testNormalization() in server/auth.test.js rather than two
-- suites that quietly drift apart on what a "valid code" is.

local CODE_CANON = "A7K3P9"
local CODE_LOWER = "a7k3p9"
local CODE_MESSY = " a7k-3p9, ?? "
local CODE_DASH_HABIT = "A7K-3P9" -- someone who remembers the old grouped form
local CODE_NOISY = "IA7LK3OP9U" -- I, L, O, U interspersed as noise

eq(Wire.code(CODE_CANON), CODE_CANON, "the canonical form is unchanged")
eq(Wire.code(CODE_LOWER), CODE_CANON, "lowercase normalises the same as uppercase")
eq(Wire.code(CODE_MESSY), CODE_CANON, "spaces and stray punctuation are stripped")
eq(Wire.code(CODE_DASH_HABIT), CODE_CANON,
   "a dash typed out of old 16-character habit still normalises to the same passcode")

-- I, L, O and U are outside the alphabet, so they are dropped as noise like
-- any other stray character -- never folded to a lookalike (O -> 0, I -> 1).
-- A Lua half that aliased them would derive a different key from the same
-- typed input and every such player would see "wrong passcode".
eq(Wire.code(CODE_NOISY), CODE_CANON,
   "I, L, O and U are dropped as noise, leaving the code intact")
eq(Wire.code("A7K3PO"), nil,
   "typing O for 0 drops a character and fails the length check, rather than aliasing to 0")
check(Wire.code("A7K3P1") ~= Wire.code("A7K3PI"), "and I is not an alias for 1")

eq(Wire.code("A7K3P"), nil, "a too-short input is rejected")
eq(Wire.code("A7K3P99"), nil, "a too-long input is rejected")
eq(Wire.code("ABCD-EFGH-JKMN-PQRS"), nil,
   "a legacy 16-character code is refused outright, not truncated to 6")

eq(Wire.code(42), nil, "a number is not a code")
eq(Wire.code(true), nil, "a boolean is not a code")
eq(Wire.code({}), nil, "a table is not a code")
eq(Wire.code(nil), nil, "nil is not a code")

eq(Wire.formatCode(Wire.code(CODE_CANON)), CODE_CANON,
   "formatCode(code(x)) round-trips the canonical form")
eq(Wire.formatCode(Wire.code(CODE_MESSY)), CODE_CANON,
   "a messy input round-trips to the same canonical form")
check(not Wire.formatCode(CODE_CANON):find("-"),
      "formatCode adds no grouping at 6 characters")

-- ------- Wire.hex: the digest/nonce sanitiser
--
-- Not "exactly N hex characters" but "hex, and no longer than the caller's
-- budget" -- the same string accepts a 64-char digest with the default cap
-- and a 32-char nonce under Config.NONCE_HEX, which is exactly the two
-- shapes that cross the wire (mmo.challenge's nonce, mmo.auth's response).

local HEX64 = string.rep("a1", 32)
local HEX32 = string.rep("b2", 16)

eq(Wire.hex(HEX64), HEX64, "64 lowercase hex characters is accepted at the digest length")
eq(#Wire.hex(HEX64), Config.DIGEST_HEX, "matching the digest length exactly")
eq(Wire.hex(HEX32, Config.NONCE_HEX), HEX32, "32 lowercase hex characters is accepted as a nonce")
eq(Wire.hex(HEX64, Config.NONCE_HEX), nil, "64 hex characters exceeds the 32-hex nonce budget")

eq(Wire.hex(HEX64:upper()), nil, "uppercase hex is rejected")
eq(Wire.hex(HEX64 .. "a1"), nil, "past the default digest budget is rejected")
eq(Wire.hex("not-hex-at-all!!"), nil, "non-hex characters are rejected")
eq(Wire.hex(""), nil, "an empty string is rejected")
eq(Wire.hex(12345), nil, "a non-string is rejected")
eq(Wire.hex(nil), nil, "nil is rejected")

-- ------- Roster

local roster = Roster.new()
roster:setSelf("me")

roster:put(Wire.presence({ id = "me", name = "SELF", map = "PALLET", x = 1, y = 1 }))
eq(roster.count, 0, "our own presence is never added as a remote player")

roster:put(Wire.presence({ id = "a", name = "ANN", map = "PALLET", x = 5, y = 5 }))
roster:put(Wire.presence({ id = "b", name = "BOB", map = "PALLET", x = 30, y = 30 }))
roster:put(Wire.presence({ id = "c", name = "CAL", map = "VIRIDIAN", x = 5, y = 5 }))
eq(roster.count, 3, "three remote players are tracked")

eq(#roster:onMap("PALLET"), 2, "onMap filters by map")
eq(#roster:near("PALLET", 5, 6, Config.LOCAL_RADIUS), 1, "near filters by distance")
eq(roster:near("PALLET", 5, 6, Config.LOCAL_RADIUS)[1].name, "ANN",
   "and returns the close one")

eq(Roster.distance({ x = 0, y = 0 }, { x = 3, y = 4 }), 4,
   "distance is Chebyshev, not Euclidean -- the world is a grid")

eq(roster:at("PALLET", 5, 5).name, "ANN", "at() finds who is standing on a cell")
eq(roster:at("PALLET", 9, 9), nil, "at() finds nobody on an empty cell")

-- a move must not erase the identity that arrived with the join
roster:move("a", "PALLET", 6, 5, "right")
eq(roster:get("a").name, "ANN", "a move keeps the name")
eq(roster:get("a").sprite, Config.DEFAULT_SPRITE, "a move keeps the sprite")
eq(roster:get("a").x, 6, "and applies the new position")

-- ...and the flags that ride on a presence update are actually applied.
--
-- The regression, found by the two-instance run and invisible to every
-- assertion that came before it: a party formed after both players were
-- already online arrives as a presence update, and a merge that copied the
-- position but not the flag left the roster on its join-time false forever.
-- What the player saw was an INVITE row still offered against somebody who
-- could no longer accept, and no PARTY column and no map marker at all.
eq(roster:get("a").party, false, "a player joins unattached")
roster:setParty("a", true)
eq(roster:get("a").party, true, "a presence update can put them in a party")
roster:move("a", "PALLET", 7, 5, "right")
eq(roster:get("a").party, true, "and walking does not take it off them again")
roster:setParty("a", false)
eq(roster:get("a").party, false, "leaving one clears it")
eq(roster:setParty("nosuch", true), nil, "an unknown id is a no-op")

-- ------- setSprite: the character somebody is wearing, changed mid-session
--
-- Exact setPoints shape, and pinned the same way: an open trainer card
-- holds this entry by reference (Card.new keeps it as self.player), so a
-- setter that swapped the table for a fresh one would leave that card
-- drawing the old portrait forever while the roster below it already knew
-- better.

do
  local before = roster:get("a")
  eq(before.sprite, Config.DEFAULT_SPRITE,
     "sanity: ANN starts wearing the default character")
  local returned = roster:setSprite("a", "SPRITE_BLUE")
  eq(roster:get("a").sprite, "SPRITE_BLUE", "setSprite changes the stored character")
  check(returned == before,
        "and returns the very same table setSprite was called with, not a copy")
  check(roster:get("a") == before,
        "the roster's own entry is that same table too -- an in-place write, "
        .. "never a put()")
  eq(roster:setSprite("nosuch", "SPRITE_RED"), nil,
     "an unknown id is a no-op, and returns nothing to update")
end

-- ------- pace rides through move(), not a setter
--
-- The opposite choice from party, and for the reason src/Roster.lua spells
-- out: pace is a property of the step itself, so it travels through move()'s
-- own trailing argument rather than a setParty-shaped call. A nil is an
-- old-shaped caller with no opinion, and must leave whatever was last
-- recorded alone -- reading "no opinion" as "not fast" would stop every
-- runner mid-stride the moment any pre-pace call site fired.

eq(roster:get("a").fast, false,
   "nobody starts flagged as fast -- Wire.presence always coerces the field")
roster:move("a", "PALLET", 8, 5, "right", true)
eq(roster:get("a").fast, true, "a move can flag the step as a fast one")
roster:move("a", "PALLET", 9, 5, "right")
eq(roster:get("a").fast, true,
   "and an old-shaped call with no fast argument leaves it alone")
roster:move("a", "PALLET", 10, 5, "right", false)
eq(roster:get("a").fast, false, "while an explicit false clears it")

roster:setBusy("a", true)
eq(roster:get("a").busy, true, "busy is carried the same way")

local sorted = roster:sorted()
eq(sorted[1].name, "ANN", "sorted is stable and alphabetical")
eq(sorted[3].name, "CAL", "all the way down")

roster:remove("a")
eq(roster.count, 2, "remove decrements the count")
eq(roster:remove("nosuch"), nil, "removing an unknown id is a no-op")
eq(roster.count, 2, "and does not corrupt the count")

-- ------- Chat

local chat = Chat.new()
for i = 1, Config.CHAT_HISTORY + 20 do
  chat:push({ name = "N", scope = "global", text = "line " .. i })
end
eq(#chat.history, Config.CHAT_HISTORY, "history is bounded")
eq(chat.history[#chat.history].text, "line " .. (Config.CHAT_HISTORY + 20),
   "and keeps the newest")

chat:clear()
chat:push({ name = "ANN", scope = "global", text = "hi" })
eq(chat.unread, 1, "an inbound line counts as unread")
chat:push({ name = "ME", scope = "global", text = "hey", outgoing = true })
eq(chat.unread, 1, "our own line does not")
chat:markRead()
eq(chat.unread, 0, "opening the log clears it")

eq(chat:line({ name = "ANN", scope = "global", text = "hi" }), "[G]ANN: hi",
   "a global line is tagged")
eq(chat:line({ name = "ANN", scope = "private", text = "psst" }), "[W]ANN: psst",
   "a whisper is tagged differently")

eq(chat:line({ name = "ANN", scope = "party", text = "this way" }),
   "[P]ANN: this way", "and a party line differently again")

-- Chat no longer floats a line over anybody's head. chat:bubble,
-- chat:bubbleFor, chat:update and Config.BUBBLE_SECONDS are gone with it --
-- a line that used to bubble is now a toast in the corner (src/Toast.lua),
-- which is pinned in its own section below rather than re-created here.
check(chat.bubble == nil, "Chat carries no bubble method any more")
check(chat.bubbleFor == nil, "nor a way to ask what is bubbling")
check(chat.update == nil, "nor an age-the-bubbles tick -- toasts age themselves")
check(Config.BUBBLE_SECONDS == nil, "and the config knob that timed them is gone too")

-- ------- MOTD: the exact push shape src/Client.lua's welcome handler uses
--
-- `ctx.chat:push({ name = "HUB", scope = "global", text = motd })` -- no
-- `from`, because the hub stands on no map and owns no avatar (Client.lua's
-- comment on the welcome handler). Pinned here at the Chat seam, since the
-- suite has no cheap way to drive the real handler live (see the note where
-- the fake-hub tier begins below).

chat:clear()
;(function()
  local hubEntry = chat:push({ name = "HUB", scope = "global", text = "welcome to the hub" })
  check(hubEntry ~= nil, "the hub line is accepted with no `from`")
  eq(chat.history[#chat.history].name, "HUB", "it lands in the scrollback under the HUB name")
  eq(chat:line(hubEntry), "[G]HUB: welcome to the hub",
     "and renders like any other global line -- Chat:line never reads `from`")
end)()
eq(chat.unread, 1,
   "it lights the unread badge -- deliberate, per docs/plans/server-live-ops.md "
   .. "#3: a greeting nobody notices is a greeting nobody reads")

-- ------- Toast: the queue behind the corner stack
--
-- push/update/clear/list/state is plain arithmetic on a list -- the part of
-- src/Toast.lua that runs with no love.graphics at all -- so it is pinned
-- here exactly the way Chat's history above is, and :draw (which does need
-- love) is left to the manual/e2e check the plan calls out.

local toastQ = Toast.new({})
eq(#toastQ:list(), 0, "a fresh queue starts empty")
eq(toastQ:state().count, 0, "and state agrees")

eq(Toast.new({}):push(nil), nil, "pushing nothing queues nothing")
eq(Toast.new({}):push(""), nil, "and neither does an empty line")
local entry = toastQ:push("hello")
check(entry ~= nil, "a real line is queued")
eq(entry.age, 0, "born at age zero")
eq(#toastQ:list(), 1, "and the queue now holds it")

toastQ:update(Config.TOAST_SECONDS - 0.1)
eq(#toastQ:list(), 1, "a line survives right up to its TTL")
eq(toastQ:list()[1].age, Config.TOAST_SECONDS - 0.1, "ageing by dt accumulates exactly")
toastQ:update(0.2)
eq(#toastQ:list(), 0, "and is gone once its age reaches TOAST_SECONDS")

toastQ:clear()
for i = 1, Config.TOAST_MAX + 3 do toastQ:push("line " .. i) end
eq(#toastQ:list(), Config.TOAST_MAX, "the stack never grows past TOAST_MAX")
eq(toastQ:list()[1].text, "line 4",
   "the oldest lines are the ones dropped, not the newest")
eq(toastQ:list()[Config.TOAST_MAX].text, "line " .. (Config.TOAST_MAX + 3),
   "so the most recent line is always still there")

toastQ:clear()
eq(#toastQ:list(), 0, "clear empties the queue outright")
eq(toastQ:state().count, 0, "and state reflects the same empty queue")

-- list() hands back a copy, not the live entries -- otherwise a driver
-- reading it could age or empty the real queue by accident.
toastQ:push("copy me")
local snapshot = toastQ:list()
toastQ:update(1)
eq(snapshot[1].age, 0, "a list() snapshot does not age just because the queue does")

-- update(dt) tolerates a bad dt rather than throwing, the same way Wire
-- tolerates a bad field: a caller that hands it nil or NaN gets a no-op tick.
toastQ:clear()
toastQ:push("still here")
toastQ:update(nil)
eq(#toastQ:list(), 1, "a nil dt ages nothing rather than raising")

-- ------- the one line that is not white
--
-- A colour is the exception and stays one: it is reserved for a line about
-- somebody the player chose, so the corner keeps meaning one thing.
toastQ:clear()
eq(toastQ:push("plain").color, nil, "an ordinary line names no colour")
eq(toastQ:list()[1].color, nil, "and the copy handed out says so too")
local blue = toastQ:push("ANN joined the server", Config.FRIEND_BLUE)
eq(blue.color, Config.FRIEND_BLUE, "a line may carry one")
eq(toastQ:list()[2].color, Config.FRIEND_BLUE, "which travels with the copy")

-- ------- Toast: the sentences
--
-- Every formatter below either returns the exact sentence or nil -- never a
-- half-built one -- so push() can be handed a formatter's result directly.

eq(Toast.chatLine("ANN", "over here"), "[ANN]: over here",
   "a chat line names the speaker and nothing else -- no scope tag, unlike Chat:line")
eq(Toast.chatLine(nil, "text"), nil, "a nameless chat line is refused")
eq(Toast.chatLine("ANN", nil), nil, "and so is a textless one")
eq(Toast.chatLine(5, "text"), nil, "a non-string name is refused")

eq(Toast.joinLine("MISTY"), "MISTY joined the server", "an arrival names the server, not the map")
eq(Toast.joinLine(nil), nil, "a nameless arrival is refused")
eq(Toast.joinLine(42), nil, "and neither is a numeric one")

eq(Toast.partLine("MISTY"), "MISTY left the server", "a departure reads the same way")
eq(Toast.partLine(nil), nil, "a nameless departure is refused")

-- A friend arriving gets the *same sentence* and a different colour.  Two
-- wordings would read as two different events; the blue is what answers "was
-- that anybody I know" without being read.
eq(Toast.joinColor(false), nil, "an ordinary arrival asks for no colour")
eq(Toast.joinColor(nil), nil, "and neither does one where nothing is known")
eq(Toast.joinColor(true), Config.FRIEND_BLUE, "a friend's arrival is blue")

eq(Toast.partyLine({ kind = "defeat_wild", name = "ANN", species = "PIDGEY", level = 5 }),
   "ANN defeated PIDGEY lv 5", "beating a wild names the species and level")
eq(Toast.partyLine({ kind = "defeated_by_wild", name = "ANN", species = "PIDGEY", level = 10 }),
   "ANN was defeated by PIDGEY lv 10", "losing to one reads as the mirror sentence")
eq(Toast.partyLine({ kind = "capture", name = "ANN", species = "MEWTWO", level = 70 }),
   "ANN captured MEWTWO lv 70", "a capture is its own sentence, not a win")
eq(Toast.partyLine({ kind = "defeat_trainer", name = "ANN", trainer = "BUG CATCHER" }),
   "ANN defeated BUG CATCHER", "beating a trainer names the trainer, not a species")
eq(Toast.partyLine({ kind = "defeated_by_trainer", name = "ANN", trainer = "BUG CATCHER" }),
   "ANN was defeated by BUG CATCHER", "and losing to one is the mirror")

eq(Toast.partyLine(nil), nil, "a non-table event has no sentence")
eq(Toast.partyLine({ kind = "defeat_wild", species = "PIDGEY", level = 5 }), nil,
   "an event with no name cannot be about anybody")
eq(Toast.partyLine({ kind = "picnic", name = "ANN" }), nil,
   "an unknown kind draws nothing -- there is no sentence to put it in")
eq(Toast.partyLine({ kind = "defeat_wild", name = "ANN", level = 5 }), nil,
   "a mon event missing its species is refused rather than printed with a hole")
eq(Toast.partyLine({ kind = "defeat_wild", name = "ANN", species = "PIDGEY" }), nil,
   "and so is one missing its level")
eq(Toast.partyLine({ kind = "defeat_trainer", name = "ANN" }), nil,
   "a trainer event missing the trainer is refused the same way")

-- ------- SessionNet: the shim the engine's link code runs over

local sent = {}
local fakeTransport = {
  ready = true,
  send = function(self, msgType, payload)
    sent[#sent + 1] = { type = msgType, payload = payload }
    return true
  end,
  isReady = function(self) return self.ready end,
}

local session = SessionNet.new(fakeTransport, "peer1", "RIVAL")
eq(session.closed, false, "a new session is open")
eq(session.paired, true, "and presents as paired, which link code expects")

session:send({ type = "party", mons = {} })
eq(#sent, 1, "sending puts exactly one message on the transport")
eq(sent[1].type, Wire.RELAY, "wrapped in a relay envelope")
eq(sent[1].payload.to, "peer1", "addressed to the peer")
eq(sent[1].payload.payload.type, "party",
   "with the engine's own message untouched inside it")

session:deliver({ type = "pick", index = 2 })
session:deliver({ type = "confirm", ok = true })
local polled = session:poll()
eq(#polled, 2, "poll drains everything delivered")
eq(polled[1].type, "pick", "in order")
eq(#session:poll(), 0, "and leaves the inbox empty")

-- LinkBattle watches .closed to notice the link died underneath it
fakeTransport.ready = false
session:update()
eq(session.closed, true, "a dead transport closes the session")

sent = {}
local closing = SessionNet.new(fakeTransport, "peer2", "GARY")
closing:close()
eq(closing.closed, true, "close marks it closed")
eq(sent[1].type, Wire.SESSION_LEAVE, "and tells the hub to tear the session down")
sent = {}
closing:close()
eq(#sent, 0, "closing twice does not send a second goodbye")

-- ------- Transport framing

local fakeNet = {
  closed = false,
  outbox = {},
  inbox = {},
  send = function(self, msg) self.outbox[#self.outbox + 1] = msg end,
  update = function() end,
  poll = function(self)
    local msgs = self.inbox
    self.inbox = {}
    return msgs
  end,
  close = function(self) self.closed = true end,
}

local transport = Transport.new()
transport:attach(fakeNet)
check(transport:isOpen(), "an attached transport is open")
eq(transport:isReady(), false, "but not ready until the hub welcomes us")

transport:send(Wire.HELLO, { name = "ASH" })
eq(fakeNet.outbox[1].type, Wire.HELLO, "send stamps the type")
eq(fakeNet.outbox[1].name, "ASH", "and carries the payload")

fakeNet.inbox = {
  { type = Wire.WELCOME, id = "x" },
  "not a table",
  { noType = true },
  { type = Wire.PONG },
}
local got = transport:update(0.016)
eq(#got, 1, "malformed messages and pongs are filtered out")
eq(got[1].type, Wire.WELCOME, "leaving the real one")

transport:markReady()
check(transport:isReady(), "markReady flips it to ready")

-- silence past the timeout must not leave the player staring at a frozen
-- world believing they are still connected
transport:update(Config.TIMEOUT + 1)
eq(transport:isOpen(), false, "a silent hub times out")
check(transport.error ~= nil, "and says why")

-- ------------------------------------------------------------------
-- 3. Hub: the relay a hosting player runs
-- ------------------------------------------------------------------
--
-- Hub is deliberately socket-free so it can be driven here with fake peers.
-- These are the same behaviours server/hub.test.js pins on the Node side;
-- two implementations of one protocol only stay honest if both are tested.
--
-- This is *not* a seam for pinning MOTD end-to-end: Hub.lua is the embedded
-- in-game hub, which docs/plans/server-live-ops.md #3 deliberately leaves
-- out of this feature entirely (its Wire.WELCOME below carries no `motd`
-- field at all, and never will). The dedicated hub that does send one is
-- server/lib/relay.js, out of this suite's reach. And src/Client.lua's own
-- welcome handler -- the code that calls `Wire.text(msg.motd,
-- Config.MOTD_MAX)` and pushes the HUB chat line -- lives inside the
-- closure M.install() builds, reachable only by handing it a full mod
-- facade (events, hooks, ui, world, transport, ...); section 1 above loads
-- that closure through the real loader but never connects it, and section
-- 2's `need()` resolver returns the module table without ever calling
-- install(). Driving a real WELCOME through that handler would mean
-- building install()'s whole facade from scratch here -- exactly the heavy
-- scaffolding this suite avoids -- so the welcome-carries-motd behaviour is
-- pinned one layer down instead: Config.MOTD_MAX / Wire.text(_, MOTD_MAX)
-- above (the sanitiser the handler calls) and the Chat push shape above
-- that (the exact table the handler builds from the result).

local Hub = need("Hub")

local function fakePeer()
  local peer = { outbox = {}, closed = false }
  function peer:send(msg) self.outbox[#self.outbox + 1] = msg end
  function peer:close() self.closed = true end
  return peer
end

-- pull the first message of a type off a peer, so later assertions are not
-- confused by traffic an earlier step left behind
local function take(peer, msgType)
  for i, msg in ipairs(peer.outbox) do
    if msg.type == msgType then return table.remove(peer.outbox, i) end
  end
  return nil
end

local function saw(peer, msgType)
  return take(peer, msgType) ~= nil
end

-- `token` is the claim ticket a returning player presents; a first visit
-- has none, which is what makes the hub mint one.
local function join(hub, name, map, x, y, token)
  local peer = fakePeer()
  local client = hub:accept(peer)
  if client then
    hub:receive(client, { type = Wire.HELLO, proto = Config.PROTOCOL,
      name = name, map = map, x = x, y = y, facing = "down",
      rankToken = token })
  end
  return client, peer
end

-- ------- the cap the host chose

eq(Hub.new({}).limit, Config.DEFAULT_PLAYERS, "no limit given falls back to 4")
eq(Hub.new({ maxPlayers = 12 }).limit, 12, "the host's number is honoured")
eq(Hub.new({ maxPlayers = 999 }).limit, Config.MAX_PLAYERS,
   "above the ceiling clamps to 64")
eq(Hub.new({ maxPlayers = 1 }).limit, Config.MIN_PLAYERS,
   "below the floor clamps to 2")
eq(Hub.new({ maxPlayers = "nonsense" }).limit, Config.DEFAULT_PLAYERS,
   "a non-number falls back rather than erroring")

local hub = Hub.new({ maxPlayers = 3 })
local ann, annPeer = join(hub, "ANN", "PALLET", 5, 5)
local bob, bobPeer = join(hub, "BOB", "PALLET", 6, 5)
local cal, calPeer = join(hub, "CAL", "PALLET", 40, 40)

eq(hub.count, 3, "three players fill a limit of three")
check(take(annPeer, Wire.WELCOME) ~= nil, "the first player is welcomed")
local bobWelcome = take(bobPeer, Wire.WELCOME)
eq(#bobWelcome.players, 1, "the second sees the first on the roster")
eq(bobWelcome.players[1].name, "ANN", "by name")
-- The embedded hub is out of the admin-join-code feature entirely (the plan
-- calls this out at #3.5/#8): only server/lib/relay.js's credential lookup
-- can grant operator status, so Hub.lua's own welcome must never carry the
-- key at all -- not even as a false -- and src/Client.lua's
-- `myAdmin = msg.admin == true` is written to read that absence as false.
eq(bobWelcome.admin, nil,
   "and the in-game hub's welcome carries no admin key -- it never grants operator status")
check(saw(annPeer, Wire.JOIN), "and the first is told about the second")

-- The cap is charged at hello, not on connect. A socket that has not
-- introduced itself is not a player, so it gets accepted and then refused
-- when it tries to claim a seat.
local fourth, fourthPeer = join(hub, "FOURTH", "PALLET", 1, 1)
check(fourth ~= nil, "a fourth connection is accepted")
local refusal = take(fourthPeer, Wire.ERROR)
check(refusal ~= nil, "but refused when it says hello")
check(refusal.message:find("full"), "saying it is full")
check(refusal.message:find("3"), "and naming the limit")
check(fourthPeer.closed, "and the connection is closed")
eq(hub.players, 3, "so it never became a player")

-- ------- an idle connection cannot hold a seat
--
-- This is the slot-exhaustion fix. Charging the player cap on connect meant
-- four sockets that said nothing locked everyone out of a four-player game.

local idleHub = Hub.new({ maxPlayers = 2 })
local idlePeer = fakePeer()
local idle = idleHub:accept(idlePeer)
check(idle ~= nil, "a silent connection is accepted")
eq(idleHub.players, 0, "but is not a player")
eq(idleHub:isFull(), false, "and does not fill the game")

-- two real players still fit alongside it
check(select(1, join(idleHub, "ONE")) ~= nil, "a real player still fits")
check(select(1, join(idleHub, "TWO")) ~= nil, "and so does a second")
eq(idleHub.players, 2, "both became players")
eq(idleHub:isFull(), true, "which is what fills the game")

-- ...and the silent one is reaped once its welcome runs out
idleHub:update(Config.HANDSHAKE_TIMEOUT + 1)
check(idlePeer.closed, "the silent connection is dropped after the deadline")
check(take(idlePeer, Wire.ERROR) ~= nil, "having been told why")
eq(idleHub.clients[idle.id], nil, "and is gone from the table")

-- a flood of silent connections is bounded rather than unbounded
local floodHub = Hub.new({ maxPlayers = 2 })
local accepted = 0
for _ = 1, Config.MAX_PENDING + 6 do
  if floodHub:accept(fakePeer()) then accepted = accepted + 1 end
end
eq(accepted, Config.MAX_PENDING, "pending connections are capped")
eq(floodHub.players, 0, "and none of them are players")

-- ------- authentication: an optional join-code gate in front of admission
--
-- Same handshake server/lib/relay.js drives on the Node side: hello, then
-- -- only when the hub carries a code -- a challenge, then an HMAC response
-- before the peer is admitted. A hub with no code configured must behave
-- exactly as it always did: hello admits straight away and no challenge
-- ever crosses the wire, which is the regression guard every player who
-- joined before codes existed depends on.

local openHub = Hub.new({ maxPlayers = 3 })
eq(openHub:requiresCode(), false, "a hub built with no join code does not require one")
local openClient, openPeer = join(openHub, "OPENPLAYER", "PALLET", 1, 1)
check(openClient ~= nil, "a hub with no join code still admits on hello")
eq(openHub.players, 1, "immediately -- no challenge round trip")
eq(take(openPeer, Wire.CHALLENGE), nil, "and no challenge is ever sent")
check(take(openPeer, Wire.WELCOME) ~= nil, "the welcome arrives exactly as before codes existed")

-- mmo.auth with no outstanding challenge (never issued one, on a hub with
-- no code) is a no-op, not an error
openPeer.outbox = {}
openHub:receive(openClient, { type = Wire.AUTH, response = string.rep("0", 64) })
eq(#openPeer.outbox, 0, "mmo.auth with no outstanding challenge is a no-op")

-- ------- a coded hub

local JOIN_CODE = "A7K3P9"
local codedHub = Hub.new({ maxPlayers = 3, joinCode = JOIN_CODE })
eq(codedHub:requiresCode(), true, "a hub constructed with a join code requires one")

-- the answer a client owes for a given nonce, computed the way a real
-- client would: normalise the code it was handed, then HMAC the nonce with
-- it -- mirroring src/Sessions.lua / src/Ui.lua, not reaching into the hub
local function answer(rawCode, nonce)
  return Sha256.hmacHex(Wire.code(rawCode), nonce)
end

local codedPeer = fakePeer()
local codedClient = codedHub:accept(codedPeer)
codedHub:receive(codedClient, { type = Wire.HELLO, proto = Config.PROTOCOL,
  name = "ASH", map = "PALLET", x = 1, y = 1, facing = "down" })

eq(codedHub.players, 0, "hello alone does not seat a player on a coded hub")
eq(codedHub:isFull(), false, "so a coded hub with only unanswered challenges is not full")
local challenge = take(codedPeer, Wire.CHALLENGE)
check(challenge ~= nil, "a challenge is sent instead of a welcome")
eq(#challenge.nonce, Config.NONCE_HEX, "the nonce is 32 hex characters")
check(challenge.nonce:match("^[0-9a-f]+$") ~= nil, "and lowercase hex")
eq(take(codedPeer, Wire.WELCOME), nil, "no welcome until the challenge is answered")

-- the correct response admits, and only now charges the seat
codedHub:receive(codedClient, { type = Wire.AUTH, response = answer(JOIN_CODE, challenge.nonce) })
check(take(codedPeer, Wire.WELCOME) ~= nil, "the correct response admits the player")
eq(codedHub.players, 1, "and the seat is charged only on a successful answer")

-- replaying the same accepted response again does nothing: the nonce was
-- consumed the moment it was read, and the client is ready besides
codedPeer.outbox = {}
codedHub:receive(codedClient, { type = Wire.AUTH, response = answer(JOIN_CODE, challenge.nonce) })
eq(#codedPeer.outbox, 0, "auth after admission is a no-op, not a re-welcome")

-- a wrong response is refused and the connection dropped
local wrongPeer = fakePeer()
local wrongClient = codedHub:accept(wrongPeer)
codedHub:receive(wrongClient, { type = Wire.HELLO, proto = Config.PROTOCOL, name = "MISTY" })
local wrongChallenge = take(wrongPeer, Wire.CHALLENGE)
check(wrongChallenge ~= nil, "a second connection is challenged independently")

codedHub:receive(wrongClient,
  { type = Wire.AUTH, response = answer("Z9Y8X7", wrongChallenge.nonce) })
local wrongError = take(wrongPeer, Wire.ERROR)
check(wrongError ~= nil, "a wrong response is refused")
check(wrongError.message:find("code"), "naming the join code as the problem")
check(wrongPeer.closed, "and the connection is closed")
eq(codedHub.clients[wrongClient.id], nil, "the client record is gone, not merely refused")
eq(codedHub.players, 1, "and no seat was ever charged for it")

-- a second mmo.auth on a connection that already failed is silently
-- nothing, since the client record no longer exists to receive it
wrongPeer.outbox = {}
codedHub:receive(wrongClient, { type = Wire.AUTH, response = answer(JOIN_CODE, wrongChallenge.nonce) })
eq(#wrongPeer.outbox, 0, "a message from a client the hub already forgot goes nowhere")

-- a response captured for one connection's nonce does not work on another:
-- the HMAC is bound to the nonce it answers, not just to the join code
local nonceOwnerPeer = fakePeer()
local nonceOwnerClient = codedHub:accept(nonceOwnerPeer)
codedHub:receive(nonceOwnerClient, { type = Wire.HELLO, proto = Config.PROTOCOL, name = "OWNER" })
local ownerNonce = take(nonceOwnerPeer, Wire.CHALLENGE).nonce

local replayPeer = fakePeer()
local replayClient = codedHub:accept(replayPeer)
codedHub:receive(replayClient, { type = Wire.HELLO, proto = Config.PROTOCOL, name = "REPLAY" })
local replayNonce = take(replayPeer, Wire.CHALLENGE).nonce
check(ownerNonce ~= replayNonce, "two connections are challenged with different nonces")

codedHub:receive(replayClient, { type = Wire.AUTH, response = answer(JOIN_CODE, ownerNonce) })
eq(take(replayPeer, Wire.WELCOME), nil,
   "a response computed for another connection's nonce does not admit this one")
check(take(replayPeer, Wire.ERROR) ~= nil, "and is refused just like a wrong code")

-- a code typed messily still authenticates: both sides normalise through
-- Wire.code, so the display form the player typed does not have to match
-- the display form the host was given
local messyPeer = fakePeer()
local messyClient = codedHub:accept(messyPeer)
codedHub:receive(messyClient, { type = Wire.HELLO, proto = Config.PROTOCOL, name = "MESSY" })
local messyNonce = take(messyPeer, Wire.CHALLENGE).nonce
codedHub:receive(messyClient,
  { type = Wire.AUTH, response = answer("  a7k 3p9!! ", messyNonce) })
check(take(messyPeer, Wire.WELCOME) ~= nil,
      "a code typed lowercase and messily still authenticates")

-- An unanswered challenge does not hold a slot forever, and it buys no
-- extra time either: HANDSHAKE_TIMEOUT is one budget covering hello, the
-- challenge and the answer, anchored at accept.  That is deliberately the
-- same budget server/lib/limits.js measures from register, so one client
-- meets one deadline whichever hosting path it dialled -- the Lua side used
-- to hand a challenged peer HELLO_TIMEOUT + AUTH_TIMEOUT (twenty seconds)
-- for the identical exchange.
local ghostPeer = fakePeer()
local ghostClient = codedHub:accept(ghostPeer)
codedHub:receive(ghostClient, { type = Wire.HELLO, proto = Config.PROTOCOL, name = "GHOST" })
check(take(ghostPeer, Wire.CHALLENGE) ~= nil, "the ghost connection is challenged")

codedHub:update(Config.HANDSHAKE_TIMEOUT - 1)
check(not ghostPeer.closed, "a challenged peer is not reaped inside the budget")

codedHub:update(2)
check(ghostPeer.closed,
      "but being challenged does not extend it past HANDSHAKE_TIMEOUT")
check(take(ghostPeer, Wire.ERROR) ~= nil, "having been told why")
eq(codedHub.clients[ghostClient.id], nil, "and the slot is freed, not held forever")

-- the same deadline, to the second, on an uncoded hub: a peer that says
-- nothing and a peer that says hello and stalls are given identical rope
local budgetHub = Hub.new({ maxPlayers = 2 })
local silentPeer = fakePeer()
local silentClient = budgetHub:accept(silentPeer)
budgetHub:update(Config.HANDSHAKE_TIMEOUT - 1)
check(not silentPeer.closed, "an ungreeted peer is not reaped inside the budget either")
budgetHub:update(2)
check(silentPeer.closed, "and is reaped at the same deadline a challenged one is")
eq(budgetHub.clients[silentClient.id], nil, "leaving no record behind")

-- MAX_PENDING and greeted-only isFull() behave the same with a code
-- configured: a challenged-but-unanswered peer is still just pending
local pendingHub = Hub.new({ maxPlayers = 2, joinCode = "ZZZZZZ" })
local pendingClient, pendingPeer = join(pendingHub, "WAITING")
check(pendingClient ~= nil, "a hello on a coded hub is still accepted")
check(take(pendingPeer, Wire.CHALLENGE) ~= nil, "and still challenged")
eq(pendingHub.players, 0, "but is not a player yet")
eq(pendingHub:isFull(), false, "so isFull() does not count it")

local floodCodedHub = Hub.new({ maxPlayers = 2, joinCode = "ZZZZZZ" })
local floodAccepted = 0
for _ = 1, Config.MAX_PENDING + 6 do
  if floodCodedHub:accept(fakePeer()) then floodAccepted = floodAccepted + 1 end
end
eq(floodAccepted, Config.MAX_PENDING, "pending connections are capped the same with a code configured")
eq(floodCodedHub.players, 0, "and none of them are players")

-- ------- the cap holds on a hub that challenges
--
-- The regression this exists for: isFull() was checked at hello, but on a
-- coded hub hello does not charge a seat -- answering the challenge does.
-- So every peer that greeted while there was room passed a gate nobody
-- repeated, and then every one of them was seated. A hub built for two
-- admitted six, and the identical bug was reproduced in server/lib/relay.js
-- before both were moved to check inside admit(), where the seat is
-- actually charged.

local CAP = 2
local capHub = Hub.new({ maxPlayers = CAP, joinCode = JOIN_CODE })
local rush = {}
for i = 1, 6 do
  local peer = fakePeer()
  local client = capHub:accept(peer)
  capHub:receive(client, { type = Wire.HELLO, proto = Config.PROTOCOL,
    name = "RUSH" .. i, map = "PALLET", x = i, y = 1, facing = "down" })
  local challenge = take(peer, Wire.CHALLENGE)
  rush[i] = { peer = peer, client = client, nonce = challenge and challenge.nonce }
end

local challenged = 0
for _, entry in ipairs(rush) do
  if entry.nonce then challenged = challenged + 1 end
end
eq(challenged, 6, "six peers all greet, and all are challenged, while there is room")
eq(capHub.players, 0, "none of them is a player on the strength of hello alone")

-- ...and now every one of them answers correctly, before any of them has
-- been admitted
local welcomed, refused, saidFull, closed = 0, 0, 0, 0
for _, entry in ipairs(rush) do
  capHub:receive(entry.client,
    { type = Wire.AUTH, response = answer(JOIN_CODE, entry.nonce) })
  if take(entry.peer, Wire.WELCOME) then welcomed = welcomed + 1 end
  local err = take(entry.peer, Wire.ERROR)
  if err then
    refused = refused + 1
    if err.message:find("full") and err.message:find(tostring(CAP)) then
      saidFull = saidFull + 1
    end
  end
  if entry.peer.closed then closed = closed + 1 end
end

eq(welcomed, CAP, "only as many peers are welcomed as the host bought seats for")
eq(capHub.players, CAP, "which is what the hub counts too")
eq(capHub:isFull(), true, "and the hub is full, not oversubscribed")
eq(refused, 6 - CAP, "the overflow is refused rather than seated")
eq(saidFull, 6 - CAP, "each with the full-hub sentence, naming the cap")
eq(closed, 6 - CAP, "and each connection closed")

local lingering = 0
for _, entry in ipairs(rush) do
  local record = capHub.clients[entry.client.id]
  if record and not record.ready then lingering = lingering + 1 end
end
eq(lingering, 0, "no refused connection is left holding a pending slot")
eq(capHub.count, CAP, "so the hub is left holding exactly the connections it seated")

-- ------- the entropy pool behind both credentials
--
-- Hub.Entropy backs the nonces above and the join code the HOST screen
-- offers, and its own header is honest about what it is: material folded in
-- over a session -- frame timings, clocks, heap size, button presses -- not
-- a CSPRNG. What is worth pinning is not how it hashes, which is its
-- business, but the property the one-instantaneous-sample code it replaced
-- did not have: what is stirred in is what makes two draws differ. Its seed
-- and clock arguments exist so that can be asserted rather than hoped for.

local Entropy = Hub.Entropy

-- a clock that advances a microsecond per reading, so the draw-time jitter
-- burst is repeatable here even though it is not on a real machine
local function steadyClock()
  local t = 0
  return function() t = t + 1e-6; return t end
end

-- what a few seconds of play looks like from the pool's side: one stir per
-- fixed step, carrying the step's duration, the clock, the heap, and a
-- fourth number that differs per "machine"
local function played(pool, steps, flavour)
  for i = 1, steps do
    pool:stir(0.0166 + i * 1e-7, i * 1e-3, 900 + (i % 37), flavour + i)
  end
  return pool
end

local COLD = "an identical cold state"

local twinA = played(Entropy.new(COLD, steadyClock()), 200, 1)
local twinB = played(Entropy.new(COLD, steadyClock()), 200, 1)
eq(twinA:code(), twinB:code(),
   "a pool is worth exactly what is stirred into it: identical state plus "
   .. "identical material draws an identical code, and nothing here pretends "
   .. "otherwise")

-- ...so two hubs off identically cold pools diverge only because the
-- material they were fed diverged, which is the whole claim
local hubA = Hub.new({ maxPlayers = 2, joinCode = JOIN_CODE,
                       entropy = played(Entropy.new(COLD, steadyClock()), 200, 3) })
local hubB = Hub.new({ maxPlayers = 2, joinCode = JOIN_CODE,
                       entropy = played(Entropy.new(COLD, steadyClock()), 200, 8) })
local collisions, repeats, malformed, nonceSeen = 0, 0, 0, {}
for _ = 1, 32 do
  local a, b = hubA:newNonce(), hubB:newNonce()
  if a == b then collisions = collisions + 1 end
  for _, nonce in ipairs({ a, b }) do
    if type(nonce) ~= "string" or #nonce ~= Config.NONCE_HEX
       or not nonce:match("^[0-9a-f]+$") then
      malformed = malformed + 1
    end
    if nonceSeen[nonce] then repeats = repeats + 1 end
    nonceSeen[nonce] = true
  end
end
eq(collisions, 0,
   "two hubs started identically cold and fed different material never "
   .. "challenge with the same nonce")
eq(repeats, 0, "and no nonce in 64 draws repeats at all")
eq(malformed, 0, "every one of them 32 lowercase hex characters")

-- codes drawn from a pool that has been played, on the real clock and the
-- real jitter burst, are distinct and typeable
local livePool = played(Entropy.new(), 400, 5)
local SAMPLE = 256
local codeSeen, repeatedCode, unusable = {}, 0, 0
for _ = 1, SAMPLE do
  local code = livePool:code()
  -- Wire.code is what the hub will normalise the player's typing through,
  -- so a drawn code that is not its own normal form is a code that cannot
  -- be typed back in
  if type(code) ~= "string" or Wire.code(code) ~= code then
    unusable = unusable + 1
  end
  if codeSeen[code] then repeatedCode = repeatedCode + 1 end
  codeSeen[code] = true
end
eq(unusable, 0, "every drawn code is already-normalised Wire.code input")
eq(repeatedCode, 0, SAMPLE .. " codes drawn from one pool are all distinct")

-- a code drawn before a single frame has been played is weaker -- the pool
-- header says by how much -- but it is never malformed
local coldCode = Entropy.new():code()
eq(Wire.code(coldCode), coldCode,
   "a code drawn cold, before anything has been stirred in, is still typeable")

-- the pool answers rather than raising, which is what lets Client.newJoinCode
-- log a remediation instead of breaking a mod callback
local tooWide, why = Entropy.new():bytes(64)
eq(tooWide, nil, "a draw wider than one digest is refused")
check(type(why) == "string", "with a reason, not a raise")

-- and a hub whose pool cannot answer refuses the peer instead of admitting
-- it unchallenged
local brokenHub = Hub.new({ maxPlayers = 2, joinCode = JOIN_CODE,
                            entropy = { bytes = function() return nil, "no pool" end } })
local brokenPeer = fakePeer()
local brokenClient = brokenHub:accept(brokenPeer)
brokenHub:receive(brokenClient,
  { type = Wire.HELLO, proto = Config.PROTOCOL, name = "NONONCE" })
eq(take(brokenPeer, Wire.CHALLENGE), nil, "a hub that cannot draw a nonce does not challenge")
check(take(brokenPeer, Wire.ERROR) ~= nil, "it refuses, with something to read")
eq(brokenHub.players, 0, "and never seats a peer it could not challenge")

-- the host occupies a slot like anyone else, so a freed one reopens
hub:drop(cal)
eq(hub.players, 2, "dropping frees a seat")
check(saw(annPeer, Wire.PART), "and the others are told")
local late = join(hub, "LATE", "PALLET", 1, 1)
check(late ~= nil, "which the next player can take")
hub:drop(late)

-- ------- chat scopes

hub:update(Config.CHAT_GATE * 2) -- clear the gate for everyone
annPeer.outbox, bobPeer.outbox = {}, {}

hub:receive(ann, { type = Wire.CHAT, scope = "global", text = "hello all" })
local heard = take(bobPeer, Wire.CHAT)
check(heard ~= nil, "global chat reaches the other player")
eq(heard.text, "hello all", "intact")
eq(heard.name, "ANN", "and attributed")
eq(take(annPeer, Wire.CHAT), nil, "the sender is not echoed to themselves")

-- the gate is per sender and spans scopes
hub:receive(ann, { type = Wire.CHAT, scope = "global", text = "again" })
eq(take(bobPeer, Wire.CHAT), nil, "a second message inside the gate is dropped")
hub:update(Config.CHAT_GATE * 2)
hub:receive(ann, { type = Wire.CHAT, scope = "global", text = "later" })
check(saw(bobPeer, Wire.CHAT), "and allowed once the gate lapses")

-- local: BOB is adjacent, a distant player is not
local far, farPeer = join(hub, "FAR", "PALLET", 90, 90)
take(farPeer, Wire.WELCOME)

hub:update(Config.CHAT_GATE * 2)
hub:receive(ann, { type = Wire.CHAT, scope = "local", text = "nearby" })
check(saw(bobPeer, Wire.CHAT), "local chat reaches a neighbour")
eq(take(farPeer, Wire.CHAT), nil, "and does not reach someone across the map")

-- a player with no cell (in a battle or a menu) cannot be heard locally
hub:receive(bob, { type = Wire.MOVE })
hub:update(Config.CHAT_GATE * 2)
hub:receive(bob, { type = Wire.CHAT, scope = "local", text = "from limbo" })
eq(take(annPeer, Wire.CHAT), nil, "a player with no position sends no local chat")
hub:receive(bob, { type = Wire.MOVE, map = "PALLET", x = 6, y = 5, facing = "up" })

-- private reaches exactly one person
hub:update(Config.CHAT_GATE * 2)
annPeer.outbox, bobPeer.outbox, farPeer.outbox = {}, {}, {}
hub:receive(ann, { type = Wire.CHAT, scope = "private", to = bob.id,
                   text = "psst" })
local whisper = take(bobPeer, Wire.CHAT)
check(whisper ~= nil, "a whisper reaches its target")
eq(whisper.scope, "private", "tagged private")
eq(take(farPeer, Wire.CHAT), nil, "and nobody else")

-- ------- requests and sessions

annPeer.outbox, bobPeer.outbox, farPeer.outbox = {}, {}, {}
hub:receive(ann, { type = Wire.REQUEST, to = bob.id, kind = "trade" })
local request = take(bobPeer, Wire.REQUEST)
check(request ~= nil, "a request reaches the other player")
eq(request.kind, "trade", "with the kind")
eq(request.name, "ANN", "and the asker's name")

-- a third party must not be able to answer on someone else's behalf
hub:receive(far, { type = Wire.RESPOND, to = ann.id, kind = "trade",
                   accept = true })
eq(take(annPeer, Wire.SESSION), nil, "only the player asked may accept")

hub:receive(bob, { type = Wire.RESPOND, to = ann.id, kind = "trade",
                   accept = true })
local annSession = take(annPeer, Wire.SESSION)
local bobSession = take(bobPeer, Wire.SESSION)
check(annSession ~= nil and bobSession ~= nil, "accepting starts a session")
eq(annSession.role, "host", "the asker hosts")
eq(bobSession.role, "guest", "the answerer joins")
eq(annSession.id, bobSession.id, "both sides share a session id")
eq(annSession.peer, bob.id, "and know who they are paired with")

-- relay carries the engine's own vocabulary through unread
hub:receive(ann, { type = Wire.RELAY, to = bob.id,
                   payload = { type = "party", mons = { { species = "PIKACHU" } } } })
local relayed = take(bobPeer, Wire.RELAY)
check(relayed ~= nil, "a relay reaches the paired player")
eq(relayed.payload.type, "party", "payload type intact")
eq(relayed.payload.mons[1].species, "PIKACHU", "and its contents")
eq(relayed.from, ann.id, "stamped with the sender")

-- ...but only inside the session
hub:receive(ann, { type = Wire.RELAY, to = far.id, payload = { type = "party" } })
eq(take(farPeer, Wire.RELAY), nil, "a relay outside the session goes nowhere")

-- a busy player auto-declines
hub:receive(far, { type = Wire.REQUEST, to = bob.id, kind = "battle" })
local declined = take(farPeer, Wire.DECLINE)
check(declined ~= nil, "a busy player declines")
eq(declined.name, "BOB", "naming them")

hub:receive(ann, { type = Wire.SESSION_LEAVE })
local ended = take(bobPeer, Wire.SESSION_END)
check(ended ~= nil, "leaving ends the session for the other side")
eq(ended.reason, "peer_left", "with a reason")

-- ------- parties
--
-- Driven on their own hub so the scenario is not reading traffic the trade
-- above left behind.  These are the same behaviours server/hub.test.js pins
-- over real sockets on the Node side; two implementations of one protocol
-- only stay honest if both are tested.
--
-- Wrapped in a function for scope, like the trade scenario further down:
-- this chunk is already at Lua's 200-local ceiling for one function body,
-- and a dozen more names at the top level is what tips it over.

;(function()

local partyHub = Hub.new({ maxPlayers = 4 })
local pAnn, pAnnPeer = join(partyHub, "ANN", "PALLET", 5, 5)
local pBob, pBobPeer = join(partyHub, "BOB", "PALLET", 6, 5)
local pCal, pCalPeer = join(partyHub, "CAL", "PALLET", 7, 5)
pAnnPeer.outbox, pBobPeer.outbox, pCalPeer.outbox = {}, {}, {}

-- an invite reaches its target, and nobody else
partyHub:receive(pAnn, { type = Wire.PARTY_INVITE, to = pBob.id })
local invite = take(pBobPeer, Wire.PARTY_INVITE)
check(invite ~= nil, "an invite reaches the player it names")
eq(invite.name, "ANN", "with the asker's name")
eq(invite.from, pAnn.id, "and their id to answer to")
eq(take(pCalPeer, Wire.PARTY_INVITE), nil, "and reaches nobody else")

-- only the player who was asked may answer it
partyHub:receive(pCal, { type = Wire.PARTY_RESPOND, to = pAnn.id, accept = true })
eq(take(pAnnPeer, Wire.PARTY), nil, "a third party cannot accept for them")

partyHub:receive(pBob, { type = Wire.PARTY_RESPOND, to = pAnn.id, accept = true })
local annParty = take(pAnnPeer, Wire.PARTY)
local bobParty = take(pBobPeer, Wire.PARTY)
check(annParty ~= nil and bobParty ~= nil, "accepting forms the party for both")
eq(annParty.id, bobParty.id, "both sides share a party id")
eq(#annParty.members, 2, "and the whole membership, not a delta")
eq(#partyHub:partyMembers(annParty.id), 2, "which the hub agrees with")

-- everyone else is told, because the flag is what gates their INVITE row
local seen = take(pCalPeer, Wire.MOVE)
check(seen ~= nil, "the rest of the game hears the presence change")
eq(seen.party, true, "and sees them as spoken for")

-- the ask is spent: answering twice cannot form a second party
partyHub:receive(pBob, { type = Wire.PARTY_RESPOND, to = pAnn.id, accept = true })
eq(take(pAnnPeer, Wire.PARTY), nil, "the same ask cannot be accepted twice")

-- somebody already in a party is refused before the prompt is ever shown
pCalPeer.outbox = {}
partyHub:receive(pCal, { type = Wire.PARTY_INVITE, to = pBob.id })
local refused = take(pCalPeer, Wire.PARTY_DECLINE)
check(refused ~= nil, "inviting someone who is taken is declined at once")
eq(refused.reason, "in_party", "with a reason worth telling apart from a no")
eq(take(pBobPeer, Wire.PARTY_INVITE), nil, "and never reaches them")

-- ...and so is inviting *out* of a party you are already in
partyHub:receive(pAnn, { type = Wire.PARTY_INVITE, to = pCal.id })
eq(take(pCalPeer, Wire.PARTY_INVITE), nil,
   "a player already in a party cannot invite anyone")

-- party chat reaches the party and stops there
partyHub:update(Config.CHAT_GATE * 2)
pAnnPeer.outbox, pBobPeer.outbox, pCalPeer.outbox = {}, {}, {}
partyHub:receive(pAnn, { type = Wire.CHAT, scope = "party", text = "this way" })
local partyLine = take(pBobPeer, Wire.CHAT)
check(partyLine ~= nil, "a party line reaches the other member")
eq(partyLine.scope, "party", "tagged party")
eq(take(pCalPeer, Wire.CHAT), nil, "and nobody outside it")

-- a player with no party has nowhere to say it, so it is dropped rather than
-- widened -- a scope that silently became "everyone" is the worst failure a
-- message somebody meant privately could have
partyHub:update(Config.CHAT_GATE * 2)
partyHub:receive(pCal, { type = Wire.CHAT, scope = "party", text = "anyone?" })
eq(take(pAnnPeer, Wire.CHAT), nil, "party chat with no party goes nowhere")
eq(take(pBobPeer, Wire.CHAT), nil, "not even to a party that exists")

-- leaving ends it for both, and tells the rest of the game
pAnnPeer.outbox, pBobPeer.outbox, pCalPeer.outbox = {}, {}, {}
partyHub:receive(pAnn, { type = Wire.PARTY_LEAVE })
local bobEnd = take(pBobPeer, Wire.PARTY_END)
check(bobEnd ~= nil, "leaving ends the party for the other member")
eq(bobEnd.reason, "peer_left", "and says which of the two it was")
local annEnd = take(pAnnPeer, Wire.PARTY_END)
check(annEnd ~= nil, "the leaver is told too, so a client always converges")
eq(annEnd.reason, "left", "with the reason that suppresses a box")
eq(pAnn.partyId, nil, "the hub holds no party for either of them")
eq(pBob.partyId, nil, "on either side")
eq(take(pCalPeer, Wire.MOVE).party, false, "and everyone sees them free again")

-- and now they can be asked again
partyHub:receive(pCal, { type = Wire.PARTY_INVITE, to = pBob.id })
check(take(pBobPeer, Wire.PARTY_INVITE) ~= nil,
      "a player whose party ended can be invited again")
partyHub:receive(pBob, { type = Wire.PARTY_RESPOND, to = pCal.id, accept = false })
local said = take(pCalPeer, Wire.PARTY_DECLINE)
check(said ~= nil, "declining answers the asker")
eq(said.reason, "no", "as a no rather than as a taken player")

-- a party does not survive the connection that made it
partyHub:receive(pCal, { type = Wire.PARTY_INVITE, to = pBob.id })
partyHub:receive(pBob, { type = Wire.PARTY_RESPOND, to = pCal.id, accept = true })
take(pBobPeer, Wire.PARTY); take(pCalPeer, Wire.PARTY)
partyHub:drop(pCal)
local dropEnd = take(pBobPeer, Wire.PARTY_END)
check(dropEnd ~= nil, "a member disconnecting ends the party")
eq(dropEnd.reason, "peer_left", "as a peer leaving")
eq(pBob.partyId, nil, "and the survivor is not left in a party of one")

-- a party outlives a trade: being busy stops you battling, not travelling
partyHub:receive(pAnn, { type = Wire.PARTY_INVITE, to = pBob.id })
partyHub:receive(pBob, { type = Wire.PARTY_RESPOND, to = pAnn.id, accept = true })
local together = take(pAnnPeer, Wire.PARTY)
check(together ~= nil, "two free players team up")
partyHub:receive(pAnn, { type = Wire.REQUEST, to = pBob.id, kind = "trade" })
partyHub:receive(pBob, { type = Wire.RESPOND, to = pAnn.id, kind = "trade",
                         accept = true })
check(take(pAnnPeer, Wire.SESSION) ~= nil, "and can still trade with each other")
eq(pAnn.partyId, together.id, "without the trade ending the party")
partyHub:receive(pAnn, { type = Wire.SESSION_LEAVE })
eq(pAnn.partyId, together.id, "or ending it when the trade does")

end)()

-- ------- friends: routing an ask, and holding one for somebody who is away
--
-- The hub half only.  It never learns who is friends with whom -- the two
-- clients keep that (src/Friends.lua) -- so everything below is about who
-- still owes an answer to whom, which is the one part of the feature that
-- cannot live in a client.
--
-- Wrapped in a function for scope, like the party scenario above.

;(function()

local friendHub = Hub.new({ maxPlayers = 4 })
local fAnn, fAnnPeer = join(friendHub, "ANN", "PALLET", 5, 5)
local fBob, fBobPeer = join(friendHub, "BOB", "PALLET", 6, 5)
local fCal, fCalPeer = join(friendHub, "CAL", "PALLET", 7, 5)
fAnnPeer.outbox, fBobPeer.outbox, fCalPeer.outbox = {}, {}, {}

-- an ask reaches its target, and nobody else
friendHub:receive(fAnn, { type = Wire.FRIEND_ASK, to = fBob.id })
local ask = take(fBobPeer, Wire.FRIEND_ASK)
check(ask ~= nil, "an ask reaches the player it names")
eq(ask.name, "ANN", "with the asker's name, which is what an answer travels by")
eq(ask.from, fAnn.id, "and their id, because they are still here to point at")
eq(take(fCalPeer, Wire.FRIEND_ASK), nil, "and reaches nobody else")

-- ...and the hub keeps holding it.  This is the difference between a friend
-- ask and a party invite: an invite is spent on delivery, because a prompt
-- nobody answered is a prompt that stopped existing when its screen closed.
eq(friendHub.friendHeld, 1, "a delivered ask is still held")

-- only the player who was actually asked may answer it
friendHub:receive(fCal, { type = Wire.FRIEND_ANSWER, toName = "ANN",
                          accept = true })
eq(take(fAnnPeer, Wire.FRIEND_ANSWER), nil,
   "a third party cannot accept on somebody else's behalf -- which is the "
   .. "whole reason the hub holds the ask rather than forwarding any answer "
   .. "it is handed")

-- ...and an answer to a question nobody asked goes nowhere
friendHub:receive(fBob, { type = Wire.FRIEND_ANSWER, toName = "CAL",
                          accept = true })
eq(take(fCalPeer, Wire.FRIEND_ANSWER), nil,
   "and neither can a client answer a question that was never put to it")

friendHub:receive(fBob, { type = Wire.FRIEND_ANSWER, toName = "ANN",
                          accept = true })
local answer = take(fAnnPeer, Wire.FRIEND_ANSWER)
check(answer ~= nil, "the player who was asked can answer")
eq(answer.name, "BOB", "under their own name, stamped from the connection")
eq(answer.accept, true, "carrying the yes")
eq(friendHub.friendHeld, 0, "and the ask is spent")

-- the ask is spent: answering twice reaches nobody
friendHub:receive(fBob, { type = Wire.FRIEND_ANSWER, toName = "ANN",
                          accept = true })
eq(take(fAnnPeer, Wire.FRIEND_ANSWER), nil,
   "the same ask cannot be answered twice")

-- a no is an answer, not silence: "they said no" and "they have not answered
-- yet" are the two states this feature most needs to keep apart
friendHub:update(Config.CHAT_GATE * 2)
friendHub:receive(fAnn, { type = Wire.FRIEND_ASK, to = fCal.id })
take(fCalPeer, Wire.FRIEND_ASK)
friendHub:receive(fCal, { type = Wire.FRIEND_ANSWER, toName = "ANN",
                          accept = false })
local refused = take(fAnnPeer, Wire.FRIEND_ANSWER)
check(refused ~= nil, "a refusal comes back too")
eq(refused.accept, false, "as a no rather than as nothing at all")

-- an ask for somebody who is not connected is held, not dropped
friendHub:update(Config.CHAT_GATE * 2)
friendHub:receive(fAnn, { type = Wire.FRIEND_ASK, to = fBob.id })
friendHub:drop(fBob)
fBobPeer.outbox = {}
eq(friendHub.friendHeld, 1, "an unanswered ask survives the connection")

local fBob2, fBob2Peer = join(friendHub, "BOB", "PALLET", 6, 5)
local again = take(fBob2Peer, Wire.FRIEND_ASK)
check(again ~= nil, "and is put to them again when they come back")
eq(again.name, "ANN", "still naming the asker")
check(fBob2 ~= nil, "on a fresh connection with a new id")

-- ...and it is *still* held, because it is still unanswered
eq(friendHub.friendHeld, 1, "re-delivering does not spend it")

-- an answer for an asker who has gone offline waits for them the same way
friendHub:drop(fAnn)
fAnnPeer.outbox = {}
friendHub:receive(fBob2, { type = Wire.FRIEND_ANSWER, toName = "ANN",
                           accept = true })
eq(friendHub.friendHeld, 1, "the answer is held for the asker who left")
local fAnn2, fAnn2Peer = join(friendHub, "ANN", "PALLET", 5, 5)
local late = take(fAnn2Peer, Wire.FRIEND_ANSWER)
check(late ~= nil, "and reaches them on their next welcome")
eq(late.accept, true, "with the answer they were waiting for")
eq(friendHub.friendHeld, 0, "an answer, unlike an ask, is spent on delivery")
check(fAnn2 ~= nil, "on whatever connection they came back on")

-- asking twice is one ask: a client holding the button down must not stack
-- boxes on somebody else's screen
friendHub:update(Config.CHAT_GATE * 2)
friendHub:receive(fAnn2, { type = Wire.FRIEND_ASK, to = fCal.id })
friendHub:update(Config.CHAT_GATE * 2)
friendHub:receive(fAnn2, { type = Wire.FRIEND_ASK, to = fCal.id })
eq(friendHub.friendHeld, 1, "two asks from one name are one held ask")

-- ...and the gate refuses the second one inside the window outright
fCalPeer.outbox = {}
friendHub:receive(fAnn2, { type = Wire.FRIEND_ASK, to = fCal.id })
eq(take(fCalPeer, Wire.FRIEND_ASK), nil,
   "a second ask inside the chat window is dropped, the way a party event is")

-- removal travels, so the two lists cannot disagree about whether a
-- friendship exists
friendHub:receive(fAnn2, { type = Wire.FRIEND_REMOVE, toName = "CAL" })
local removed = take(fCalPeer, Wire.FRIEND_REMOVE)
check(removed ~= nil, "a removal reaches the other side")
eq(removed.name, "ANN", "naming the sender, stamped from the connection")
eq(friendHub.friendHeld, 0,
   "and takes the ask between the two of them with it -- a box about a "
   .. "decision already made is a box nobody should be answering")

-- ...and is held for somebody who is away, like everything else
friendHub:drop(fCal)
friendHub:update(Config.CHAT_GATE * 2)
friendHub:receive(fAnn2, { type = Wire.FRIEND_REMOVE, toName = "CAL" })
eq(friendHub.friendHeld, 1, "a removal for an absent player waits for them")
local _, fCal2Peer = join(friendHub, "CAL", "PALLET", 7, 5)
check(take(fCal2Peer, Wire.FRIEND_REMOVE) ~= nil,
      "and lands on their next welcome")

-- a name cannot befriend itself, however many connections are wearing it
local sameHub = Hub.new({ maxPlayers = 4 })
local sAnn = join(sameHub, "ANN", "PALLET", 1, 1)
local sAnn2, sAnn2Peer = join(sameHub, "ANN", "PALLET", 2, 1)
sAnn2Peer.outbox = {}
sameHub:receive(sAnn, { type = Wire.FRIEND_ASK, to = sAnn2.id })
eq(take(sAnn2Peer, Wire.FRIEND_ASK), nil,
   "two connections wearing one name have no friendship to form -- and a "
   .. "hold filed under that name would be one either of them could answer")
eq(sameHub.friendHeld, 0, "so nothing is held for it either")

-- the per-name ceiling, which is what stops one inbox growing without bound
local capHub = Hub.new({ maxPlayers = 64 })
local capTarget = join(capHub, "ZED", "PALLET", 1, 1)
for index = 1, Config.FRIEND_HOLD_PER_NAME + 2 do
  local asker = join(capHub, ("ASK%d"):format(index), "PALLET", index, 2)
  capHub:update(Config.CHAT_GATE * 2)
  capHub:receive(asker, { type = Wire.FRIEND_ASK, to = capTarget.id })
end
eq(capHub.friendHeld, Config.FRIEND_HOLD_PER_NAME,
   "one inbox holds no more than the per-name ceiling")

-- and the week-long expiry, which is what stops a hub that runs for a month
-- accumulating asks nobody will ever answer
capHub:update(Config.FRIEND_HOLD + 1)
capHub:holdFriend("SOMEONE", { kind = "ask", name = "LATE" })
eq(capHub.friendHeld, 1, "everything older than the hold window is swept")

end)()

-- ------- refusals and liveness
--
-- One do-block for the section: its dozen locals are the section's own, and
-- handing their slots back is what keeps the main chunk under Lua's 200-local
-- ceiling now that two branches' suites live in one file.
do

-- the cap is charged at hello, so a stranger connects and is then refused
local stranger, strangerPeer = join(hub, "STRANGER", "PALLET", 1, 1)
check(take(strangerPeer, Wire.ERROR) ~= nil, "the room is full again")
eq(hub.players, 3, "and the stranger never became a player")

local hub2 = Hub.new({ maxPlayers = 4 })
local oldPeer = fakePeer()
local oldClient = hub2:accept(oldPeer)
hub2:receive(oldClient, { type = Wire.HELLO, proto = Config.PROTOCOL + 1,
                          name = "OLD" })
local mismatch = take(oldPeer, Wire.ERROR)
check(mismatch ~= nil, "a protocol mismatch is refused")
check(mismatch.message:find("protocol"), "and says so")

local namelessPeer = fakePeer()
local namelessClient = hub2:accept(namelessPeer)
hub2:receive(namelessClient, { type = Wire.HELLO, proto = Config.PROTOCOL,
                               name = "   " })
check(take(namelessPeer, Wire.ERROR) ~= nil, "an unusable name is refused")

local pingClient, pingPeer = join(hub2, "PING")
take(pingPeer, Wire.WELCOME)
hub2:receive(pingClient, { type = Wire.PING })
check(saw(pingPeer, Wire.PONG), "a ping is answered")

-- shutting down tells everyone rather than dropping them silently
local shutPeer = select(2, join(hub2, "SHUT"))
take(shutPeer, Wire.WELCOME)
hub2:shutdown("The host ended the game.")
local goodbye = take(shutPeer, Wire.ERROR)
check(goodbye ~= nil, "shutdown tells every player")
check(shutPeer.closed, "and closes their connection")
eq(hub2.count, 0, "leaving the hub empty")

end

-- ------------------------------------------------------------------
-- 3b. Ranked PVP: the arithmetic, and the hub that applies it
-- ------------------------------------------------------------------
--
-- Two halves, and the second is the one that matters.
--
-- The arithmetic is pinned against numbers written out by hand, because
-- server/lib/rank.js has to produce the same ones -- a win worth 27 points
-- on a dedicated hub and 16 on a hosted game is not a ranking, it is two,
-- and the only way that stays true is if both suites assert the same table.
--
-- The hub half is the anti-cheat: a result is a claim by a stranger's
-- process, and the whole defence is that two independent claims have to
-- agree. Every way of getting points without winning a battle is tried here.

do

local Rank = need("Rank")

-- ------- the curve

-- Even ratings are an even match, whatever the number
eq(Rank.expected(0, 0), 0.5, "two unranked players are even")
eq(Rank.expected(500, 500), 0.5, "and so are two equal ratings anywhere")
check(Rank.expected(400, 0) > 0.9, "400 points of gap is a heavy favourite")
check(Rank.expected(0, 400) < 0.1, "seen from the other side")

-- ------- what a match is worth
--
-- The brief's rule, in numbers: beating somebody above you pays more than
-- beating somebody below you, and the loss mirrors it.

local evenGain, evenLoss = Rank.swing(0, 0)
eq(evenGain, 16, "an even match is worth half of RANK_K")
eq(evenLoss, 16, "and costs the loser the same")

local upsetGain, upsetLoss = Rank.swing(0, 300)
local farmGain, farmLoss = Rank.swing(300, 0)
check(upsetGain > evenGain, "beating somebody far above you is worth more")
check(farmGain < evenGain, "and beating somebody far below you is worth less")
eq(upsetGain + upsetLoss, 32, "the two halves of one match add up to RANK_K")
eq(upsetLoss, farmGain, "and the curve is symmetric about the gap")

-- ------- the rematch discount

eq(Rank.discount(16, 0), 16, "a first meeting is worth full price")
eq(Rank.discount(16, 1), 8, "the rematch is worth half")
eq(Rank.discount(16, 2), 4, "and the one after that a quarter")
eq(Rank.discount(16, Config.RANK_REPEAT_FADE), 0,
   "far enough in, a rematch is worth nothing at all")
eq(Rank.discount(16, 9999), 0,
   "and an absurd count is zero rather than a division by an infinity")

-- ------- the board

local season = Rank.newBoard()
eq(season:points("ASH"), Config.RANK_START, "everybody starts unranked")

local first = season:record("ASH", "GARY", 0)
check(first ~= nil, "a match between two players settles")
eq(first.winner.points, 16, "the winner is on the board")
eq(first.loser.points, 0, "and the loser cannot go below zero")
eq(season:points("ASH"), 16, "which is what the board now says")

-- Names are the identity, and they are the *same* identity in any case.
eq(season:points("ash"), 16, "a name is matched case-insensitively")
eq(season:record("ASH", "ash", 0), nil, "and nobody can beat themselves")
eq(season:record("ASH", nil, 0), nil, "a nameless opponent is not a match")

-- Farming: the same two players, over and over, inside the window.
local farm = Rank.newBoard()
local earned = {}
for i = 1, 6 do
  local settled = farm:record("ALPHA", "BRAVO", 10 * i)
  earned[i] = settled.winner.gained
end
check(earned[1] > 0, "the first win pays")
check(earned[2] < earned[1], "the rematch pays less")
check(earned[3] < earned[2], "and so on down")
eq(earned[6], 0, "until a rematch inside the window is worth nothing")
check(farm:points("BRAVO") == 0, "and the loser bottoms out at zero")

-- ...and the discount does not care which way round the wins go, so two
-- friends cannot take turns.
local swapped = Rank.newBoard()
local there = swapped:record("ALPHA", "BRAVO", 0).winner.gained
local back = swapped:record("BRAVO", "ALPHA", 1).winner.gained
check(back < there, "alternating wins is the same pairing, and is discounted")

-- ------- a team battle is rated as a team battle
--
-- A 2-on-2 was scored as two 1v1s paired by slot index, which reused the whole
-- rating machinery unchanged and was arbitrary in the way that matters:
-- nothing about a four-way says who fought whom. Both players attack both
-- opponents, a move redirects across the pair when a target falls, and the
-- side loses together. What each player actually played is *them against the
-- other pair*, and that is now what is scored.

;(function()
  local board = Rank.newBoard()
  local settled = board:recordTeam({ "ANN", "BOB" }, { "CAL", "DEE" }, 0)
  check(settled ~= nil, "a two-a-side battle settles")
  eq(#settled.winners, 2, "both winners are rated")
  eq(#settled.losers, 2, "and both losers are")
  check(settled.winners[1].gained > 0, "the winners gained")
  check(settled.losers[1].lost >= 0, "and the losers paid")
  eq(board:points("ANN"), board:points("BOB"),
     "team-mates who went in level come out level")

  -- Everyone played one battle, not two, and not none.
  for _, name in ipairs({ "ANN", "BOB", "CAL", "DEE" }) do
    eq(board:entry(name).played, 1, name .. " has exactly one rated result")
  end

  -- ------- and the order they are listed in changes nothing
  --
  -- This is the whole of what was wrong before. Under slot pairing, the same
  -- four players with the same ratings and the same result were rated
  -- *differently* depending on which of them the hub happened to list first --
  -- so putting your stronger player in the other seat moved everybody's
  -- points. The rating is now about the two sides, and a side is a set.
  -- The two opponents have to be *differently* rated, and only one side's
  -- order may change. Swap both sides symmetrically and slot pairing happens
  -- to match the same people up anyway, so the test would pass under the very
  -- design it exists to reject. Under slot pairing this exact swap moved three
  -- of the four ratings: 43/16/10 became 42/17/11 for the same four people,
  -- the same battle and the same result.
  local SEATS = { "STRONG", "WEAK", "RIVAL", "ROOKIE" }
  local function play(winners, losers)
    local seat = Rank.newBoard()
    for _ = 1, 6 do seat:record("STRONG", "PADDING", 0) end
    for _ = 1, 3 do seat:record("RIVAL", "PADDING2", 0) end
    seat:recordTeam(winners, losers, 500)
    local after = {}
    for _, name in ipairs(SEATS) do after[name] = seat:points(name) end
    return after
  end

  local straight = play({ "STRONG", "WEAK" }, { "RIVAL", "ROOKIE" })
  local reseated = play({ "STRONG", "WEAK" }, { "ROOKIE", "RIVAL" })
  for _, name in ipairs(SEATS) do
    eq(reseated[name], straight[name],
       name .. " is rated the same whichever seat they were listed in")
  end

  -- ...and the strength that decides it is the pair's, not one member's.
  local carried = Rank.newBoard()
  for _ = 1, 4 do carried:record("CARRY", "FODDER", 0) end
  local strongPair = carried:recordTeam({ "ROOKIE1", "ROOKIE2" },
                                        { "CARRY", "FODDER" }, 100)
  local evenPair = Rank.newBoard():recordTeam({ "ROOKIE1", "ROOKIE2" },
                                              { "PLAIN1", "PLAIN2" }, 100)
  check(strongPair.loserSide > evenPair.loserSide,
        "a pair carrying a rated player is worth more than a pair of unknowns")
  check(strongPair.winners[1].gained > evenPair.winners[1].gained,
        "and beating them pays more -- the side's strength is what is rated, "
        .. "not whoever happened to be listed first")

  -- ------- farming a 2-on-2 is discounted like farming a 1v1
  local afternoon = Rank.newBoard()
  local paid = {}
  for i = 1, 5 do
    local round = afternoon:recordTeam({ "P1", "P2" }, { "P3", "P4" }, 10 * i)
    paid[i] = round.winners[1].gained
  end
  check(paid[1] > 0, "the first party battle pays")
  check(paid[2] < paid[1], "running it again pays less")
  check(paid[3] < paid[2], "and less again")
  eq(paid[5], 0, "until the same four are worth nothing to each other")

  -- ...whichever side wins, because it is the same four people arranging
  -- results between themselves.
  local taking = Rank.newBoard()
  local wentOut = taking:recordTeam({ "Q1", "Q2" }, { "Q3", "Q4" }, 0)
  local cameBack = taking:recordTeam({ "Q3", "Q4" }, { "Q1", "Q2" }, 1)
  check(cameBack.winners[1].gained < wentOut.winners[1].gained,
        "two parties taking turns to win is the same meeting, and discounted")

  -- ...and bringing in somebody genuinely new is worth its full value, because
  -- a fight nobody has had before is not a fight anyone can be farming.
  local fresh = Rank.newBoard()
  for _ = 1, 3 do fresh:recordTeam({ "R1", "R2" }, { "R3", "R4" }, 0) end
  local stale = fresh:recordTeam({ "R1", "R2" }, { "R3", "R4" }, 1)
  local newcomer = fresh:recordTeam({ "R1", "R2" }, { "R3", "NEWBIE" }, 2)
  check(newcomer.winners[1].gained > stale.winners[1].gained,
        "a new opponent on the other side makes the battle worth playing again")

  -- ------- and what is not a match
  eq(Rank.newBoard():recordTeam({ "X", "Y" }, { "Y", "Z" }, 0), nil,
     "a player on both sides is not a battle between four people")
  eq(Rank.newBoard():recordTeam({ "X", "X" }, { "Y", "Z" }, 0), nil,
     "and neither is the same name twice on one side")
  eq(Rank.newBoard():recordTeam({}, { "Y", "Z" }, 0), nil, "an empty side is not a side")
  -- A name that will not resolve takes the whole battle down with it, rather
  -- than quietly rating the three players who did have one against a side
  -- that is short a member.
  eq(Rank.newBoard():recordTeam({ "X", "   " }, { "Y", "Z" }, 0), nil,
     "nor is one carrying a name that resolves to nobody")

  -- The mean is what a side is worth, and it is stated rather than implied.
  eq(Rank.teamPoints({ { points = 100 }, { points = 200 } }), 150,
     "a side is worth the average of its members")
  eq(Rank.teamPoints({}), 0, "and an empty one is worth nothing")
end)()

-- Once the window has passed, the pairing is fresh again. Two boards played
-- identically up to the rematch, so the ratings are the same at that point
-- and the only thing that differs is how long the players waited.
local soon, later = Rank.newBoard(), Rank.newBoard()
soon:record("ALPHA", "BRAVO", 0)
later:record("ALPHA", "BRAVO", 0)
local sooner = soon:record("ALPHA", "BRAVO", 1).winner.gained
local waited = later:record("ALPHA", "BRAVO",
                            Config.RANK_REPEAT_WINDOW + 1).winner.gained
check(waited > sooner, "a rematch after the window is worth full price again")

-- ------- claiming a name
--
-- A rating is keyed by trainer name, so without this anybody who knows your
-- nickname can put your rating on and spend it. The ticket is what turns
-- "types the same name" into "is the same player".

local claims = Rank.newBoard()
local TICKET = string.rep("a1", 16)
local OTHER = string.rep("b2", 16)

eq(claims:claimed("ASH"), false, "a name nobody has used is unclaimed")
eq(claims:claim("ASH", nil, TICKET), "claimed", "the first player to use it claims it")
eq(claims:claimed("ASH"), true, "and it is claimed from then on")
eq(claims:claim("ASH", TICKET, OTHER), "owner",
   "the holder of the ticket is the owner, and does not re-claim it")
eq(claims:claim("ash", TICKET, OTHER), "owner", "whatever case they type it in")
eq(claims:claim("ASH", nil, OTHER), "impostor",
   "somebody typing the name with no ticket is not the owner")
eq(claims:claim("ASH", OTHER, nil), "impostor", "nor is a wrong ticket")
eq(claims:claimed("ASH"), true, "and neither attempt took the name over")

-- The ticket itself is never kept -- only its digest -- so a leaked board
-- file lists who is ranked and gives nobody a way to be them.
local stored = claims:get("ASH")
check(stored.tokenHash ~= nil, "a claimed name carries a digest")
check(stored.tokenHash ~= TICKET, "which is not the ticket")
check(not tostring(stored.tokenHash):find(TICKET, 1, true),
      "and does not contain it")

-- A hub that cannot mint (its entropy pool refused) leaves the name open
-- rather than locking it: everybody scores as they did before tickets.
local unmintable = Rank.newBoard()
eq(unmintable:claim("NOBODY", nil, nil), "open", "no ticket to give means no claim")
eq(unmintable:claimed("NOBODY"), false, "and the name stays free for the next one")
eq(unmintable:claim("NOBODY", nil, TICKET), "claimed", "who can still claim it")

-- Claims survive the file, because a season that forgot them would hand
-- every name back to whoever typed it first after a restart.
local reloaded = Rank.newBoard():import(claims:export())
eq(reloaded:claim("ASH", TICKET, OTHER), "owner", "a ticket still works after a reload")
eq(reloaded:claim("ASH", OTHER, nil), "impostor", "and a wrong one still does not")
local corrupt = Rank.newBoard():import({
  { name = "ASH", points = 10, tokenHash = "not a digest" },
})
eq(corrupt:claimed("ASH"), false,
   "a hash that is not a hash is dropped -- a name nobody can claim would be "
   .. "worse than one anybody can")

-- Nothing that leaves the hub carries the digest.
claims:record("ASH", "GARY", 0)
for _, row in ipairs(claims:top(Config.RANK_TOP)) do
  eq(row.tokenHash, nil, "the leaderboard sent to clients carries no digests")
end

-- ------- a claim is provisional until it is proved
--
-- Board:claim's own header explains the rule; what follows pins it case by
-- case, mirroring server/rank.test.js's claim scenarios one for one so the
-- two Board twins stay honest about the same thing.

local mintTokenCounter = 0
local function mintToken()
  mintTokenCounter = mintTokenCounter + 1
  return Sha256.hex("rby_mmo_test/board_twin_token|" .. mintTokenCounter)
             :sub(1, Config.RANK_TOKEN_HEX)
end

-- A fresh claim starts life unproved.
do
  local board = Rank.newBoard()
  local token = mintToken()
  eq(board:claim("ASH", nil, token), "claimed", "the name is free, so it is claimed")
  eq(board:get("ASH").confirmed, false,
     "but a mint only says a ticket was posted, not that anyone proved holding it")
  -- ...and it is not written down. A row nobody has proved, played or scored
  -- under is one Board:claim will hand to the next player who asks, so
  -- persisting it buys nothing -- and a hub anybody can dial would otherwise
  -- grow (and rewrite) a row per passing hello.
  local exported
  for _, row in ipairs(board:export()) do
    if row.name == "ASH" then exported = row end
  end
  eq(exported, nil,
     "and an unproved, unplayed, unrated claim is not written to the file at all")
end

-- The claim moves for a name nobody is *using*. A holder who is connected and
-- ranked under it right now is the one thing board state cannot see, and
-- without it the leniency above is a theft: the second player takes the
-- claim, and the first player's next win lands on it.
do
  local board = Rank.newBoard()
  local held = mintToken()
  eq(board:claim("ASH", nil, held), "claimed", "first visit mints a claim")

  eq(board:claim("ASH", nil, mintToken(), true), "impostor",
     "a tokenless hello while the holder is connected and ranked is an impostor")
  eq(board:claim("ASH", mintToken(), mintToken(), true), "impostor",
     "and so is a wrong ticket")
  eq(board:claim("ASH", held, mintToken(), true), "owner",
     "the holder themselves is still the owner, live or not")

  -- The lockout this whole branch exists to fix has the owner *gone*, so it
  -- is untouched: same board, nobody connected, same tokenless hello.
  local gone = Rank.newBoard()
  gone:claim("ASH", nil, mintToken())
  local fresh = mintToken()
  eq(gone:claim("ASH", nil, fresh, false), "claimed",
     "with the holder disconnected the reclaim still works")
  eq(gone:claim("ASH", fresh, mintToken()), "owner",
     "and the ticket it minted is the one that answers")
end

-- A row with a rating but no games behind it is not reclaimable either.
-- `played` is the rule; this is the belt on top of it, for a hand-edited
-- ranking.json where the two disagree.
do
  local edited = Rank.newBoard():import({
    { name = "EDITED", points = 500, played = 0, won = 0, confirmed = false,
      tokenHash = ("a"):rep(64) },
  })
  eq(edited:get("EDITED").points, 500, "sanity: the imported row has a rating")
  eq(edited:get("EDITED").played, 0, "and no games behind it")
  eq(edited:claim("EDITED", nil, mintToken()), "impostor",
     "points above the starting value block a reclaim on their own")
end

-- The ticket holder returning confirms the claim, and from then on nothing
-- reclaims it -- not even a hello with no ticket at all.
do
  local board = Rank.newBoard()
  local token = mintToken()
  eq(board:claim("ASH", nil, token), "claimed", "first visit mints a claim")
  eq(board:get("ASH").confirmed, false, "not proved yet")

  eq(board:claim("ASH", token, mintToken()), "owner",
     "the ticket holder returns and is recognised")
  eq(board:get("ASH").confirmed, true,
     "a proved ticket confirms the claim, even though nothing has scored")

  eq(board:claim("ASH", nil, mintToken()), "impostor",
     "and a confirmed claim is never reclaimed, even at zero games played")
end

-- Unconfirmed and unscored: any hello for the name moves the claim, right
-- ticket, wrong ticket or none at all -- until somebody proves it.
do
  local board = Rank.newBoard()
  local oldToken = mintToken()
  eq(board:claim("ASH", nil, oldToken), "claimed", "first visit mints a claim")
  eq(board:get("ASH").confirmed, false, "nobody has proved it yet")

  local newToken = mintToken()
  eq(board:claim("ASH", nil, newToken), "claimed",
     "a second tokenless hello for an unconfirmed, unscored name re-mints "
     .. "rather than locking the name shut")

  -- The claim is still unproved, so even a *wrong* ticket moves it again
  -- instead of being told apart from a missing one -- "unconfirmed and
  -- unscored" is the whole test, not which ticket was presented.
  local staleToken = mintToken()
  eq(board:claim("ASH", oldToken, staleToken), "claimed",
     "a wrong ticket on a still-unconfirmed, unscored name reclaims once "
     .. "more rather than answering impostor")

  eq(board:claim("ASH", staleToken, mintToken()), "owner",
     "the latest ticket is the one that answers now")
  eq(board:get("ASH").confirmed, true, "and proving it confirms the claim")

  eq(board:claim("ASH", newToken, mintToken()), "impostor",
     "now that it is proved, an earlier ticket is worthless")
end

-- A name that has settled a battle is never up for grabs, ticket or not --
-- even a legacy row that reached disk unconfirmed.
do
  local board = Rank.newBoard()
  local token = mintToken()
  board:claim("ASH", nil, token)
  board:record("ASH", "GARY", 0)
  local row
  for _, r in ipairs(board:export()) do if r.name == "ASH" then row = r end end
  eq(row.played, 1, "sanity: this name has scored")
  eq(row.confirmed, true, "and settling confirmed it too")

  row.confirmed = false
  local reloaded = Rank.newBoard():import({ row })
  eq(reloaded:get("ASH").confirmed, false,
     "the imported state: unconfirmed on file, but already scored")
  eq(reloaded:get("ASH").played, 1, "and scored")
  eq(reloaded:claim("ASH", nil, mintToken()), "impostor",
     "played > 0 blocks reclaim on its own, independent of confirmed")
end

-- Settling a match confirms both names in the same breath, ticket or not.
do
  local board = Rank.newBoard()
  eq(board:get("ALPHA"), nil, "sanity: neither name is on the board yet")
  board:record("ALPHA", "BRAVO", 0)
  eq(board:get("ALPHA").confirmed, true,
     "the winner is confirmed by having played, ticket or not")
  eq(board:get("BRAVO").confirmed, true,
     "and so is the loser -- a settled battle proves both names at once")
end

-- confirmed round-trips through export/import, both ways.
do
  -- The unconfirmed side of the trip has to be a row the file actually keeps,
  -- and export drops the throwaway ones -- so this is an unproved claim on a
  -- name that has played, which is what a legacy file looks like.
  local board = Rank.newBoard():import({
    { name = "PROVISIONAL", points = 12, played = 1, won = 1, confirmed = false,
      tokenHash = ("b"):rep(64) },
  })
  eq(board:get("PROVISIONAL").confirmed, false, "sanity: unconfirmed")

  local provenToken = mintToken()
  board:claim("PROVEN", nil, provenToken)
  board:claim("PROVEN", provenToken, mintToken())
  eq(board:get("PROVEN").confirmed, true, "sanity: confirmed by its owner")

  local reloaded = Rank.newBoard():import(board:export())
  eq(reloaded:get("PROVISIONAL").confirmed, false,
     "an unconfirmed claim comes back unconfirmed")
  eq(reloaded:get("PROVEN").confirmed, true,
     "and a confirmed one comes back confirmed -- both directions of the trip")
end

-- What the file is allowed to grow. Every first hello under a new name claims
-- it, so a hub anybody can dial would otherwise write a row per connection --
-- and rewrite the whole file each time. Only claims worth surviving a restart
-- are written: proved, played, or carrying a rating.
do
  local board = Rank.newBoard()
  board:claim("DRIFTER", nil, mintToken())
  board:seen("WATCHER", "SPRITE_RED")
  eq(#board:export(), 0,
     "a board of nothing but fresh claims and passers-by writes no rows at all")

  local proved = mintToken()
  board:claim("PROVER", nil, proved)
  board:claim("PROVER", proved, mintToken())
  board:record("WINNER", "LOSER", 0)
  local names = {}
  for _, row in ipairs(board:export()) do names[#names + 1] = row.name end
  table.sort(names)
  eq(table.concat(names, ","), "LOSER,PROVER,WINNER",
     "and a proved claim, a win and a loss are all kept -- those are what a "
     .. "restart has to survive")
end

-- A legacy row with no `confirmed` field is judged by its results: played is
-- proof, and nothing played is exactly the leniency a fresh claim gets.
do
  local hashOf = function(char) return char:rep(64) end
  local legacy = Rank.newBoard():import({
    { name = "VETERAN", points = 40, played = 3, won = 2, tokenHash = hashOf("a") },
    { name = "ROOKIE", points = 0, played = 0, won = 0, tokenHash = hashOf("b") },
  })
  eq(legacy:get("VETERAN").confirmed, true,
     "a legacy row with no confirmed field, but with results, is read as confirmed")
  eq(legacy:get("ROOKIE").confirmed, false,
     "and one with no results yet is read as provisional -- the same leniency "
     .. "a fresh claim gets")
  eq(legacy:claim("VETERAN", nil, mintToken()), "impostor",
     "so the veteran cannot be reclaimed")
  eq(legacy:claim("ROOKIE", nil, mintToken()), "claimed",
     "but the rookie can be -- nothing has scored under that name yet")
end

-- The twin drift: import's tokenHash shape tightens to exactly what
-- server/lib/rank.js has always required, /^[0-9a-f]{64}$/ (D4 in the plan).
do
  local hash64 = ("a1"):rep(32)
  eq(#hash64, 64, "sanity: the fixture hash is 64 characters")
  local board = Rank.newBoard():import({
    { name = "SHORT", points = 5, tokenHash = hash64:sub(1, 63) },
    { name = "LONG", points = 5, tokenHash = hash64 .. "a" },
    { name = "SHOUTY", points = 5, tokenHash = hash64:upper() },
    { name = "EXACT", points = 5, tokenHash = hash64 },
  })
  eq(board:claimed("SHORT"), false, "63 hex characters is rejected")
  eq(board:claimed("LONG"), false, "65 hex characters is rejected")
  eq(board:claimed("SHOUTY"), false, "uppercase hex is rejected")
  eq(board:claimed("EXACT"), true, "exactly 64 lowercase hex characters is accepted")
end

-- ------- the leaderboard

local ladder = Rank.newBoard()
for i = 1, 14 do
  ladder:seen("WINNER" .. i, "SPRITE_RED")
  -- everybody beats the same punchbag once, so every winner is on the board
  ladder:record("WINNER" .. i, "PUNCHBAG" .. i, i)
end
ladder:seen("LURKER", "SPRITE_LASS")

local top = ladder:top(Config.RANK_TOP)
eq(#top, Config.RANK_TOP, "the board is cut to the top ten")
check(top[1].points >= top[2].points, "best first")
check(top[#top].points > 0, "and nobody with nothing to show is on it")
for _, row in ipairs(top) do
  check(row.name ~= "LURKER", "a player who has never won is not ranked")
  check(row.name:find("PUNCHBAG") == nil, "and neither is one who only lost")
end

-- Persistence: the same board, through a file and back.
local saved = ladder:export()
check(#saved > #top, "everything is exported, not only the visible ten")
local restored = Rank.newBoard():import(saved)
eq(restored:points(top[1].name), top[1].points, "a rating survives a round trip")
eq(#restored:top(Config.RANK_TOP), #top, "and so does the board it makes")
local mangled = Rank.newBoard():import({ "not a row", { name = "OK", points = 40 },
                                         { points = 9 } })
eq(mangled:points("OK"), 40, "a corrupt row costs its own rating, not the file's")

end

do

-- ------- the hub half: two reports, one result

local ranked = Hub.new({ maxPlayers = 4 })
local one, onePeer = join(ranked, "ONE", "PALLET", 1, 1)
local two, twoPeer = join(ranked, "TWO", "PALLET", 2, 1)

local hello = take(onePeer, Wire.WELCOME)
eq(hello.points, 0, "a welcome carries your own rating, which starts at zero")
local joinMsg = take(onePeer, Wire.JOIN)
eq(joinMsg.player.points, 0, "and presence carries everybody else's")

-- pair them for a battle, the way two players who accepted one are paired
-- Both sides out of whatever they were in first: the hub refuses a request
-- from a player who is already paired, and a fight that never started would
-- make every assertion after it pass by doing nothing.
local function fight(hub, a, aPeer, b, bPeer)
  hub:receive(a, { type = Wire.SESSION_LEAVE })
  hub:receive(b, { type = Wire.SESSION_LEAVE })
  aPeer.outbox, bPeer.outbox = {}, {}
  hub:receive(a, { type = Wire.REQUEST, to = b.id, kind = "battle" })
  hub:receive(b, { type = Wire.RESPOND, to = a.id, kind = "battle", accept = true })
  local session = take(aPeer, Wire.SESSION)
  take(bPeer, Wire.SESSION)
  check(session ~= nil, "the battle this scenario needs actually started")
  return session and session.id
end

local matchId = fight(ranked, one, onePeer, two, twoPeer)
check(matchId ~= nil, "a battle session has an id to file a result under")

-- One side alone proves nothing.
ranked:receive(one, { type = Wire.RESULT, session = matchId, outcome = "win" })
eq(ranked.board:points("ONE"), 0, "one report on its own scores nothing")
eq(take(onePeer, Wire.RANK), nil, "and moves nobody")

-- A bystander cannot vote on somebody else's battle.
local three = join(ranked, "THREE", "PALLET", 9, 9)
ranked:receive(three, { type = Wire.RESULT, session = matchId, outcome = "loss" })
eq(ranked.board:points("ONE"), 0, "a player who was not in the battle is ignored")

-- The loser agreeing is what settles it.
ranked:receive(two, { type = Wire.RESULT, session = matchId, outcome = "loss" })
eq(ranked.board:points("ONE"), 16, "two agreeing reports settle the match")
eq(ranked.board:points("TWO"), 0, "and the loser floors at zero")
local rankMsg = take(onePeer, Wire.RANK)
check(rankMsg ~= nil, "the winner is told their new rating")
eq(rankMsg.points, 16, "with the number")
check(saw(twoPeer, Wire.RANK), "and so is the loser -- both, in the same breath")

-- Re-reporting a settled match pays nothing a second time.
ranked:receive(one, { type = Wire.RESULT, session = matchId, outcome = "win" })
ranked:receive(two, { type = Wire.RESULT, session = matchId, outcome = "loss" })
eq(ranked.board:points("ONE"), 16, "a settled match cannot be settled twice")

-- Disagreement scores nothing at all: this is the lie, and it does not pay.
local liarId = fight(ranked, one, onePeer, two, twoPeer)
ranked:receive(one, { type = Wire.RESULT, session = liarId, outcome = "win" })
ranked:receive(two, { type = Wire.RESULT, session = liarId, outcome = "win" })
eq(ranked.board:points("ONE"), 16, "two players both claiming the win score nothing")
eq(ranked.board:points("TWO"), 0, "neither of them")

-- A player cannot revise their answer until it matches.
local revisedId = fight(ranked, one, onePeer, two, twoPeer)
ranked:receive(one, { type = Wire.RESULT, session = revisedId, outcome = "loss" })
ranked:receive(one, { type = Wire.RESULT, session = revisedId, outcome = "win" })
ranked:receive(two, { type = Wire.RESULT, session = revisedId, outcome = "loss" })
eq(ranked.board:points("TWO"), 0,
   "the first answer stands, so a retraction cannot manufacture agreement")
eq(ranked.board:points("ONE"), 16, "and nothing was paid out")

-- An agreed draw is a real answer, and it is worth nothing.
local drawId = fight(ranked, one, onePeer, two, twoPeer)
ranked:receive(one, { type = Wire.RESULT, session = drawId, outcome = "draw" })
ranked:receive(two, { type = Wire.RESULT, session = drawId, outcome = "draw" })
eq(ranked.board:points("ONE"), 16, "a draw moves nobody")

-- A trade is not a battle, so there is nothing to report on one.
ranked:receive(one, { type = Wire.SESSION_LEAVE })
ranked:receive(two, { type = Wire.SESSION_LEAVE })
onePeer.outbox, twoPeer.outbox = {}, {}
ranked:receive(one, { type = Wire.REQUEST, to = two.id, kind = "trade" })
ranked:receive(two, { type = Wire.RESPOND, to = one.id, kind = "trade",
                      accept = true })
local tradeSession = take(onePeer, Wire.SESSION)
check(tradeSession ~= nil, "a trade session starts like any other")
local tradeId = tradeSession and tradeSession.id
take(twoPeer, Wire.SESSION)
ranked:receive(one, { type = Wire.RESULT, session = tradeId, outcome = "win" })
ranked:receive(two, { type = Wire.RESULT, session = tradeId, outcome = "loss" })
eq(ranked.board:points("ONE"), 16, "a trade cannot be reported as a won battle")
ranked:receive(one, { type = Wire.SESSION_LEAVE })

-- ------- the report window
--
-- The two players do not finish at the same instant, so a report has to
-- survive the session being torn down -- but not forever.

local lateId = fight(ranked, one, onePeer, two, twoPeer)
ranked:receive(one, { type = Wire.RESULT, session = lateId, outcome = "win" })
ranked:receive(one, { type = Wire.SESSION_LEAVE })
ranked:update(1)
ranked:receive(two, { type = Wire.RESULT, session = lateId, outcome = "loss" })
check(ranked.board:points("ONE") > 16,
   "a report that lands after the session ended still counts")

local staleId = fight(ranked, one, onePeer, two, twoPeer)
local carried = ranked.board:points("ONE")
ranked:receive(one, { type = Wire.RESULT, session = staleId, outcome = "win" })
ranked:receive(one, { type = Wire.SESSION_LEAVE })
ranked:update(Config.RANK_REPORT_GRACE + 1)
ranked:receive(two, { type = Wire.RESULT, session = staleId, outcome = "loss" })
eq(ranked.board:points("ONE"), carried,
   "but a report long after the grace period has nothing left to settle")
eq(next(ranked.matches), nil, "and the paperwork is not kept forever")

-- ------- the leaderboard, over the wire

onePeer.outbox = {}
ranked:receive(one, { type = Wire.RANKS })
local answer = take(onePeer, Wire.RANKING)
check(answer ~= nil, "asking for the ranking is answered")
check(#answer.entries > 0, "with the players who have won something")
eq(answer.entries[1].name, "ONE", "best first")
check(answer.entries[1].points > 0, "and nobody at zero is on it")
for _, row in ipairs(answer.entries) do
  check(row.name ~= "TWO", "a player who has only lost is not ranked")
end

-- ...but not as fast as a client can ask.
ranked:receive(one, { type = Wire.RANKS })
eq(take(onePeer, Wire.RANKING), nil, "a second request in the same second is dropped")
ranked:update(Config.RANK_QUERY_GATE + 0.1)
ranked:receive(one, { type = Wire.RANKS })
check(take(onePeer, Wire.RANKING) ~= nil, "and answered again once the gate opens")

-- ------- a rating belongs to the name, not the connection

local returning = Hub.new({ maxPlayers = 4 })
local rejoinA, rejoinAPeer = join(returning, "COMEBACK")
local rejoinB = join(returning, "VICTIM")
-- the ticket the hub minted for this name, handed over exactly once
local ticket = take(rejoinAPeer, Wire.WELCOME).rankToken
check(Wire.token(ticket) ~= nil, "a first visit is handed a claim ticket")
local rejoinId = nil
returning:receive(rejoinA, { type = Wire.REQUEST, to = rejoinB.id, kind = "battle" })
returning:receive(rejoinB, { type = Wire.RESPOND, to = rejoinA.id,
                             kind = "battle", accept = true })
for _, client in pairs(returning.clients) do
  if client.sessionId then rejoinId = client.sessionId end
end
returning:receive(rejoinA, { type = Wire.RESULT, session = rejoinId, outcome = "win" })
returning:receive(rejoinB, { type = Wire.RESULT, session = rejoinId, outcome = "loss" })
local won = returning.board:points("COMEBACK")
check(won > 0, "the winner has a rating")
returning:drop(rejoinA)

-- Back with the ticket: the same player, and their rating with them.
local backAgain, backPeer = join(returning, "COMEBACK", nil, nil, nil, ticket)
eq(backAgain.points, won, "which is still theirs when they reconnect")
local backWelcome = take(backPeer, Wire.WELCOME)
eq(backWelcome.points, won, "and the welcome says so")
eq(backWelcome.ranked, true, "they are scored, as themselves")
eq(backWelcome.rankToken, nil,
   "and the ticket is not re-sent: a hub that handed it to whoever asked "
   .. "would not be checking anything")
returning:drop(backAgain)

-- Somebody else typing the same name: admitted, and worth nothing.
local faker, fakerPeer = join(returning, "COMEBACK")
local fakeWelcome = take(fakerPeer, Wire.WELCOME)
eq(fakeWelcome.ranked, false, "a stranger typing a claimed name is told they are not scored")
eq(fakeWelcome.points, 0,
   "and wears none of that name's rating -- the ticket would buy nothing otherwise")
eq(fakeWelcome.rankToken, nil, "no ticket is handed out for a name already claimed")

-- ...and their battles do not move the real player's rating.
local victim = join(returning, "VICTIM2")
returning:receive(faker, { type = Wire.REQUEST, to = victim.id, kind = "battle" })
returning:receive(victim, { type = Wire.RESPOND, to = faker.id,
                            kind = "battle", accept = true })
local fakeId = faker.sessionId
returning:receive(faker, { type = Wire.RESULT, session = fakeId, outcome = "win" })
returning:receive(victim, { type = Wire.RESULT, session = fakeId, outcome = "loss" })
eq(returning.board:points("COMEBACK"), won,
   "an unranked player cannot add to the rating of the name they borrowed")
eq(returning.board:points("VICTIM2"), 0,
   "and their opponent loses nothing to a match that was never scored")

-- ------- reclaim, over the wire -- the same rule server/lib/relay.js runs
--
-- Mirrors testReclaimOverTheWire in server/rank.test.js: welcome.ranked and
-- welcome.rankToken are what a client actually reads, so the twin is pinned
-- there and not only against Board:claim's return value.

-- Wrapped in a function purely for scope, like section 8/10 below: this
-- do-block is already close to Lua's 200-local ceiling.
;(function()

local reclaimHub = Hub.new({ maxPlayers = 8 })

local delta1, delta1Peer = join(reclaimHub, "DELTA")
local oldTicket = take(delta1Peer, Wire.WELCOME).rankToken
check(Wire.token(oldTicket) ~= nil, "a first visit mints a claim ticket")
reclaimHub:drop(delta1)

-- Back without the ticket -- a save that never carried it -- before ever
-- proving it or playing a scored battle.
local delta2, delta2Peer = join(reclaimHub, "DELTA")
local delta2Welcome = take(delta2Peer, Wire.WELCOME)
eq(delta2Welcome.ranked, true,
   "an unconfirmed, unscored name follows the player who is here now")
local newTicket = delta2Welcome.rankToken
check(Wire.token(newTicket) ~= nil, "a fresh ticket goes out with the reclaim")
check(newTicket ~= oldTicket, "and it is not the one that got lost")
reclaimHub:drop(delta2)

-- Prove the fresh ticket, which is the moment the claim stops moving.
local delta3, delta3Peer = join(reclaimHub, "DELTA", nil, nil, nil, newTicket)
eq(take(delta3Peer, Wire.WELCOME).ranked, true, "the new ticket is recognised")
reclaimHub:drop(delta3)

local delta4, delta4Peer = join(reclaimHub, "DELTA", nil, nil, nil, oldTicket)
local delta4Welcome = take(delta4Peer, Wire.WELCOME)
eq(delta4Welcome.ranked, false,
   "the ticket that got lost is worthless once the claim has moved on and "
   .. "been proved")
eq(delta4Welcome.rankToken, nil,
   "no ticket is handed to somebody presenting a stale one")
reclaimHub:drop(delta4)

local delta5, delta5Peer = join(reclaimHub, "DELTA", nil, nil, nil, newTicket)
local delta5Welcome = take(delta5Peer, Wire.WELCOME)
eq(delta5Welcome.ranked, true, "the proven ticket is the one that answers now")
eq(delta5Welcome.rankToken, nil,
   "and a confirmed owner is not re-sent a ticket they already hold")

end)()

-- ------- a name somebody is standing in is not up for grabs
--
-- The impostor gate the board cannot see for itself, through the hub that
-- computes it: a second player typing a name somebody is connected and ranked
-- under does not take the claim. Reachable by accident -- two copies that
-- never changed the default trainer name -- and permanent if it went through,
-- because the first player's next settled win would confirm the taker's
-- claim. Mirrors testLiveHolderOverTheWire in server/rank.test.js.

;(function()

local liveHub = Hub.new({ maxPlayers = 8 })
local claimed = {}
liveHub.onClaim = function(what, name) claimed[#claimed + 1] = what .. ":" .. name end

local holder, holderPeer = join(liveHub, "ECHO")
eq(take(holderPeer, Wire.WELCOME).ranked, true, "the first ECHO is ranked")
local held = liveHub:claimHash("ECHO")
check(held ~= nil, "and holds an unproved claim on the name")

local second, secondPeer = join(liveHub, "ECHO")
local secondWelcome = take(secondPeer, Wire.WELCOME)
eq(secondWelcome.ranked, false,
   "a second ECHO arriving while the first is still here is not scored")
eq(secondWelcome.rankToken, nil, "and is handed no ticket")
eq(liveHub:claimHash("ECHO"), held, "the claim did not move")
eq(holder.ranked, true, "and the holder is still ranked")
eq(claimed[1], "unscored:ECHO",
   "the host is told, which is the seam server/lib/relay.js logs on")
liveHub:drop(second)

-- The lockout this branch exists to fix is the *disconnected* owner, and it
-- still works: same tokenless hello, once the holder is gone.
liveHub:drop(holder)
local later, laterPeer = join(liveHub, "ECHO")
local laterWelcome = take(laterPeer, Wire.WELCOME)
eq(laterWelcome.ranked, true,
   "with the holder gone, an unproved, unscored claim follows whoever is here")
check(Wire.token(laterWelcome.rankToken) ~= nil, "and a fresh ticket goes out")
check(liveHub:claimHash("ECHO") ~= held, "the claim moved this time")
eq(claimed[2], "taken:ECHO", "and the host is told about that too")
liveHub:drop(later)

end)()

-- ------- a battle is scored into the claims it started against, or not at all
--
-- A claim that moved between the first turn and the last report belongs to
-- somebody else now, and Board:record would confirm it into permanence on the
-- way past. Mirrors testClaimMovedMidMatch in server/rank.test.js.

;(function()

local midHub = Hub.new({ maxPlayers = 8 })

local function battle(a, b)
  midHub:receive(a, { type = Wire.REQUEST, to = b.id, kind = "battle" })
  midHub:receive(b, { type = Wire.RESPOND, to = a.id, kind = "battle",
                      accept = true })
  return a.sessionId
end

-- The control: the same battle, nobody's claim touched, settles normally.
local control = join(midHub, "CONTROL")
local sparring = join(midHub, "SPARRING")
local firstId = battle(control, sparring)
midHub:receive(control, { type = Wire.RESULT, session = firstId, outcome = "win" })
midHub:receive(sparring, { type = Wire.RESULT, session = firstId, outcome = "loss" })
eq(midHub.board:points("CONTROL"), 16, "sanity: an untouched match scores")

local nova = join(midHub, "NOVA")
local vega = join(midHub, "VEGA")
local matchId = battle(nova, vega)
local startedWith = midHub:claimHash("NOVA")

-- NOVA reports and leaves -- the paperwork outlives the session by design --
-- and with nobody connected under the name, its unproved claim is up for
-- grabs again.
midHub:receive(nova, { type = Wire.RESULT, session = matchId, outcome = "win" })
midHub:drop(nova)
local taker = join(midHub, "NOVA")
check(midHub:claimHash("NOVA") ~= startedWith, "sanity: the claim moved")

midHub:receive(vega, { type = Wire.RESULT, session = matchId, outcome = "loss" })
eq(midHub.board:points("NOVA"), 0,
   "the settlement is dropped: those points would have landed on a claim the "
   .. "winner does not hold")
eq(midHub.board:points("VEGA"), 0, "and the loser pays nothing for it")
eq(midHub.board:get("NOVA").confirmed, false,
   "nor is the new claim confirmed by somebody else's battle")
eq(taker.ranked, true, "sanity: the taker is a normal player")

end)()

end

-- ------------------------------------------------------------------
-- 3c. mmo.sprite: changing character mid-session, over the hub
-- ------------------------------------------------------------------
--
-- The character row is now reachable from the connected menu, not just at
-- hello, so the hub has to learn a change and pass it on. Mirrors
-- server/hub.test.js's (or sprite.test.js's) mmo.sprite cases one for one --
-- identical assertion strings agreed with T-B, so the two hub twins stay
-- honest about the same behaviour.

;(function()

local spriteHub = Hub.new({ maxPlayers = 8 })
local ann2, ann2Peer = join(spriteHub, "ANN2", "PALLET", 5, 5)
local bob2, bob2Peer = join(spriteHub, "BOB2", "PALLET", 6, 5)
ann2Peer.outbox, bob2Peer.outbox = {}, {}

spriteHub:receive(ann2, { type = Wire.SPRITE, sprite = "SPRITE_BLUE" })
local annSees = take(ann2Peer, Wire.SPRITE)
local bobSees = take(bob2Peer, Wire.SPRITE)
check(annSees ~= nil and bobSees ~= nil,
      "a sprite change is stored and broadcast to everyone, the sender too")
eq(annSees.id, ann2.id, "naming who changed")
eq(annSees.sprite, "SPRITE_BLUE", "and to what")
eq(bobSees.id, ann2.id, "the same message, word for word, to everyone else")
eq(bobSees.sprite, "SPRITE_BLUE", "the same message, word for word")
eq(ann2.sprite, "SPRITE_BLUE", "and the hub's own record of them moved too")

-- a malformed id
ann2Peer.outbox, bob2Peer.outbox = {}, {}
spriteHub:receive(ann2, { type = Wire.SPRITE, sprite = "bad id with spaces" })
eq(take(ann2Peer, Wire.SPRITE), nil,
   "a bad sprite id costs the sender nothing but the message")
eq(take(bob2Peer, Wire.SPRITE), nil, "nobody else hears about it either")
eq(ann2.sprite, "SPRITE_BLUE", "and the hub keeps the last good value")

-- re-sending what is already stored
ann2Peer.outbox, bob2Peer.outbox = {}, {}
spriteHub:receive(ann2, { type = Wire.SPRITE, sprite = "SPRITE_BLUE" })
eq(take(ann2Peer, Wire.SPRITE), nil, "an unchanged sprite is not rebroadcast")
eq(take(bob2Peer, Wire.SPRITE), nil, "not even to somebody else")

-- the gate: two real changes back to back keep only the first
spriteHub:update(Config.CHAT_GATE * 2) -- clear whatever gate the setup left armed
ann2Peer.outbox, bob2Peer.outbox = {}, {}
spriteHub:receive(ann2, { type = Wire.SPRITE, sprite = "SPRITE_RED" })
check(take(ann2Peer, Wire.SPRITE) ~= nil, "sanity: the first of the pair goes through")
spriteHub:receive(ann2, { type = Wire.SPRITE, sprite = "SPRITE_YOUNGSTER" })
eq(take(ann2Peer, Wire.SPRITE), nil,
   "two changes inside the gate keep only the first")
eq(ann2.sprite, "SPRITE_RED", "the hub is still holding the first value")

-- and the gate lapsing lets the next one through
spriteHub:update(Config.CHAT_GATE * 2)
spriteHub:receive(ann2, { type = Wire.SPRITE, sprite = "SPRITE_YOUNGSTER" })
check(take(ann2Peer, Wire.SPRITE) ~= nil,
      "a change after the gate opens goes through")
eq(ann2.sprite, "SPRITE_YOUNGSTER", "and the hub holds the new value")

-- a connection that has not said hello yet is not a player and cannot be one
local pendingPeer = fakePeer()
local pending = spriteHub:accept(pendingPeer)
spriteHub:receive(pending, { type = Wire.SPRITE, sprite = "SPRITE_RED" })
eq(pending.sprite, Config.DEFAULT_SPRITE,
   "a client that never said hello cannot change a sprite")
eq(take(pendingPeer, Wire.SPRITE), nil, "and nothing is broadcast about it")

end)()

-- ------- the board learns a new face only from the name's real owner

;(function()

local boardHub = Hub.new({ maxPlayers = 8 })
local owner, ownerPeer = join(boardHub, "FACE", "PALLET", 1, 1)
take(ownerPeer, Wire.WELCOME)
eq(owner.ranked, true, "sanity: the first FACE claims the name and is ranked")
eq(boardHub.board:get("FACE").sprite, Config.DEFAULT_SPRITE,
   "sanity: admit already seeded the board with the hello's sprite")

ownerPeer.outbox = {}
boardHub:receive(owner, { type = Wire.SPRITE, sprite = "SPRITE_BLUE" })
check(take(ownerPeer, Wire.SPRITE) ~= nil, "sanity: the owner's own change went out")
eq(boardHub.board:get("FACE").sprite, "SPRITE_BLUE",
   "a ranked owner's change re-seeds the board's face")

-- a second FACE while the first is still connected and ranked is an
-- impostor, the same rule "a name somebody is standing in is not up for
-- grabs" pins above
local impostor, impostorPeer = join(boardHub, "FACE", "PALLET", 2, 1)
local impostorWelcome = take(impostorPeer, Wire.WELCOME)
eq(impostorWelcome.ranked, false,
   "sanity: a second FACE while the first is connected is not scored")

boardHub:update(Config.CHAT_GATE * 2)
ownerPeer.outbox, impostorPeer.outbox = {}, {}
boardHub:receive(impostor, { type = Wire.SPRITE, sprite = "SPRITE_YOUNGSTER" })
check(take(impostorPeer, Wire.SPRITE) ~= nil,
      "sanity: an unranked client's own change still reaches the wire -- "
      .. "everyone still sees them wearing it")
eq(impostor.sprite, "SPRITE_YOUNGSTER",
   "sanity: the hub still stores what the impostor is wearing, for their "
   .. "own avatar")
eq(boardHub.board:get("FACE").sprite, "SPRITE_BLUE",
   "an impostor cannot repaint a ranked row's face")

end)()

-- ------- the announcement is not behind anything that can fail
--
-- The failure this pins is specific and it is permanent, which is what makes
-- it worth a case of its own. The store at the top of the handler is what
-- arms its own no-op guard: once client.sprite has moved, every later
-- mmo.sprite carrying the same id returns at `sprite == client.sprite`. So a
-- throw *between* the store and the broadcast does not cost one message -- it
-- costs the whole session. The client's reconcile loop re-sends the same id
-- every SPRITE_RETRY for as long as the player stays connected, the hub eats
-- each one as a no-op, and nobody else in the game is ever told, with nothing
-- anywhere to say why.
--
-- The board is the call that could do it: it is the one thing this handler
-- touches that it does not own. So the order is the invariant -- announce,
-- then reseed -- and this drives it with a board that throws, which is the
-- only way to state "the announcement does not depend on that call" without
-- waiting for a real bug in Rank. server/sprite.test.js runs the same case.

;(function()

local orderHub = Hub.new({ maxPlayers = 8 })
local one, onePeer = join(orderHub, "ORDER1", "PALLET", 1, 1)
local two, twoPeer = join(orderHub, "ORDER2", "PALLET", 2, 1)
eq(one.ranked, true, "sanity: the sender owns its name, so the board is in play")
onePeer.outbox, twoPeer.outbox = {}, {}

orderHub.board.seen = function()
  error("the board could not take that name", 0)
end

local ok = pcall(orderHub.receive, orderHub, one,
                 { type = Wire.SPRITE, sprite = "SPRITE_BLUE" })
eq(ok, false, "sanity: the board really did throw")
check(take(twoPeer, Wire.SPRITE) ~= nil,
      "a board that fails does not cost everyone else the announcement")
check(take(onePeer, Wire.SPRITE) ~= nil, "nor the sender their acknowledgement")
eq(one.sprite, "SPRITE_BLUE",
   "and what the hub is holding is exactly what it announced -- never a "
   .. "value stored but never said, which the no-op guard would then eat "
   .. "every retry of")

end)()

-- ------------------------------------------------------------------
-- 4. The host joins its own game over loopback
-- ------------------------------------------------------------------
--
-- HostServer:start needs luasocket, which plain luajit does not have, so
-- the hub and the running flag are set directly here. Everything under
-- test -- the Net-shaped local peer, the JSON round-trip, and Transport
-- driving it -- is the real code path a hosting player takes.

local HostServer = need("HostServer")

local hosted = HostServer.new()
eq(hosted:localNet(), nil, "there is no local net before hosting starts")

hosted.hub = Hub.new({ maxPlayers = 2 })
hosted.running = true

local localNet = hosted:localNet()
check(localNet ~= nil, "hosting yields a local net for the host's own client")
eq(hosted.hub.count, 1, "and the host occupies a slot like anyone else")

local hostTransport = Transport.new()
hostTransport:attach(localNet)
check(hostTransport:isOpen(), "Transport accepts it unchanged")

hostTransport:send(Wire.HELLO, { proto = Config.PROTOCOL, name = "HOST",
                                 map = "PALLET", x = 3, y = 4, facing = "down" })
local hostMsgs = hostTransport:update(0.016)
eq(#hostMsgs, 1, "the host hears back from its own hub")
eq(hostMsgs[1].type, Wire.WELCOME, "with a welcome, exactly as a guest would")
check(hostMsgs[1].id ~= nil, "carrying an id")

-- the second slot is the one friend a limit of 2 allows
local guestPeer = fakePeer()
local guestClient = hosted.hub:accept(guestPeer)
hosted.hub:receive(guestClient, { type = Wire.HELLO, proto = Config.PROTOCOL,
                                  name = "FRIEND" })
check(take(guestPeer, Wire.WELCOME) ~= nil, "one friend fits alongside the host")
local thirdPeer = fakePeer()
local third = hosted.hub:accept(thirdPeer)
hosted.hub:receive(third, { type = Wire.HELLO, proto = Config.PROTOCOL,
                            name = "THIRD" })
check(take(thirdPeer, Wire.ERROR) ~= nil, "a second friend does not")

-- ------- the host's own peer cannot take the fan-out down with it
--
-- Hub:broadcast walks every client in table order and hands each one's peer
-- the message. The socket peers guard their encoder (HostServer's Peer:send
-- says why); this handle is the odd one out, and it is odd in the direction
-- that matters -- a throw here happens *inside* somebody else's broadcast,
-- abandoning the loop, so the host's own copy of a message could cost every
-- other player theirs, and leave the hub holding state it had committed and
-- never finished announcing. What reaches this peer is Hub's own payloads,
-- so nothing ordinary can fail; the point is that nothing extraordinary can
-- either.
local hostOwn = hosted.localClient
check(hostOwn ~= nil, "hosting keeps a handle on the host's own client")
check(pcall(function()
  hostOwn.peer:send({ type = "mmo.unencodable", nope = print })
end), "a message the encoder cannot take does not throw out of the host's "
   .. "own peer, so the broadcast carrying it still reaches everyone else")

-- the friend is still on; only the host's own seat is given back
localNet:close()
eq(hosted.hub.players, 1, "closing the local net frees the host's own slot")

-- ------------------------------------------------------------------
-- 5. Avatar step routing
-- ------------------------------------------------------------------
--
-- The rest of Avatars needs a live overworld, but the routing decision is
-- pure and is what decides whether a remote player walks or teleports.

local Avatars = need("Avatars")

local function step(fromX, fromY, toX, toY)
  local dir, tx, ty = Avatars.stepToward(fromX, fromY, toX, toY)
  return dir, tx, ty
end

eq(step(3, 6, 3, 6), nil, "already there is not a step")

local dir, tx, ty = step(3, 6, 4, 6)
eq(dir, "right", "one tile east steps right")
eq(tx, 4, "onto the next cell")
eq(ty, 6, "with y unchanged")

eq(step(3, 6, 2, 6), "left", "west steps left")
eq(step(3, 6, 3, 7), "down", "south steps down")
eq(step(3, 6, 3, 5), "up", "north steps up")

-- One axis at a time: the overworld grid has no diagonal step, so a
-- diagonal target has to be walked as two separate steps.
dir, tx, ty = step(3, 6, 5, 8)
eq(dir, "right", "a diagonal target resolves x first")
eq(tx, 4, "and moves exactly one tile")
eq(ty, 6, "leaving y for the next step")

-- ...and each call moves one tile, so a run of them walks the whole path
local x, y = 3, 6
local walked = 0
while true do
  local d, nx, ny = step(x, y, 5, 8)
  if not d then break end
  x, y = nx, ny
  walked = walked + 1
  if walked > 10 then break end
end
eq(walked, 4, "two east and two south is four steps")
eq(x, 5, "landing on the target x")
eq(y, 8, "and the target y")

-- ------- a fast step sets the remote avatar's step pace
--
-- advance() writes npc.stepFrames straight onto the live NPC -- the field
-- NPC:update reads fresh every frame, per the module's own header -- so the
-- fake world only needs to hand back a handle whose .npc is a plain mutable
-- table shaped like the fields advance touches.  mod.world is set directly
-- on the shared stub for the length of this section and cleared afterward,
-- so nothing later that touches stubMod sees a fake world it did not ask
-- for.  Wrapped for scope, the same reason as elsewhere in this file.

;(function()

local fakeNpc = { cellX = 5, cellY = 5, moving = false, facing = "down" }
local fakeWorld = {
  npc = function(_, mapId, npcId) return { npc = fakeNpc } end,
}
stubMod.world = fakeWorld

local avatars = Avatars.new()
avatars.mapId = "PALLET"

local av = { npcId = "n1", x = 5, y = 5, facing = "down" }
local runnerRow = { id = "a", x = 6, y = 5, facing = "right", fast = true }
check(avatars:advance(av, runnerRow), "advance starts a step toward the new cell")
eq(fakeNpc.stepFrames, Config.FAST_STEP_FRAMES,
   "a fast roster row paces the step at the fast frame count")

-- the step "completes" the way NPC:update would drive it, before the next
-- one starts
fakeNpc.moving = false
fakeNpc.cellX, fakeNpc.cellY = 6, 5

local walkerRow = { id = "a", x = 7, y = 5, facing = "right", fast = false }
check(avatars:advance(av, walkerRow), "advance starts the next step")
eq(fakeNpc.stepFrames, nil,
   "and a walking-pace row clears it back to the engine's own default")

-- The bug this flag's rename fixed: a cyclist's row says fast the same way a
-- sprinter's does, because the wire carries the pace and not the reason for
-- it. Before that, a remote cyclist stepped at 16 while their own game moved
-- them at 8 and they drifted straight through RESYNC_DISTANCE.
fakeNpc.moving = false
fakeNpc.cellX, fakeNpc.cellY = 7, 5

local cyclistRow = { id = "a", x = 8, y = 5, facing = "right", fast = true }
check(avatars:advance(av, cyclistRow), "advance starts a cyclist's step")
eq(fakeNpc.stepFrames, Config.FAST_STEP_FRAMES,
   "and a cyclist is paced by the same one flag a sprinter is")

stubMod.world = nil

end)()

-- ------- Avatars:refresh -- a player who changed character while we were
-- looking at them
--
-- The sprite is baked in at spawn and never re-read, so the only way to
-- redraw somebody wearing a new one is despawn+respawn -- and only for a
-- player whose avatar is actually up right now. Logged through a fake
-- world's spawnNpc/removeNpc calls, the same shape the section above uses.

;(function()

stubSprites.SPRITE_RED = { walker = true }
stubSprites.SPRITE_BLUE = { walker = true }

local calls = {}
local liveNpc = { cellX = 5, cellY = 5, moving = false, facing = "down" }
local fakeWorld = {
  spawnNpc = function(_, mapId, opts)
    calls[#calls + 1] = { op = "spawn", map = mapId, sprite = opts.sprite }
    return "npc-refresh"
  end,
  removeNpc = function(_, npcId)
    calls[#calls + 1] = { op = "despawn", npcId = npcId }
  end,
  npc = function(_, mapId, npcId) return { npc = liveNpc } end,
}

local avatars = Avatars.new()
avatars.mapId = "PALLET"

local row = { id = "a", map = "PALLET", x = 5, y = 5, facing = "down",
              sprite = "SPRITE_RED" }

-- no world in play at all (a battle, the title screen)
stubMod.world = nil
eq(avatars:refresh(row), nil, "refresh with no world in play is a no-op")

stubMod.world = fakeWorld

-- nobody has an avatar up for this player yet
eq(avatars:refresh(row), nil,
   "refresh for a player with no avatar up is a no-op -- they spawn as "
   .. "their new self the next time they come into view")
eq(#calls, 0, "and nothing was despawned or spawned to get there")

-- spawn one for real, so refresh has something to rebuild
avatars:spawn(row)
eq(#calls, 1, "sanity: spawning the first time wrote one call")
calls = {}

-- the roster has already moved this player to another map: refresh declines
-- rather than respawning them somewhere that is not the active map
local elsewhere = { id = "a", map = "VIRIDIAN", x = 1, y = 1, facing = "down",
                     sprite = "SPRITE_BLUE" }
eq(avatars:refresh(elsewhere), nil,
   "refresh for a map-mismatched roster entry is a no-op -- they will spawn "
   .. "wearing the new character on the way in")
eq(#calls, 0, "no despawn happened to get there")

-- same map, spawned: the real path -- despawn the old sheet, spawn the new
local changed = { id = "a", map = "PALLET", x = 5, y = 5, facing = "down",
                   sprite = "SPRITE_BLUE" }
local result = avatars:refresh(changed)
check(result ~= nil, "refresh rebuilds the avatar")
eq(#calls, 2, "exactly one despawn and one spawn")
eq(calls[1].op, "despawn", "the old sheet goes first")
eq(calls[2].op, "spawn", "and the new one follows")
eq(calls[2].sprite, "SPRITE_BLUE",
   "the new spawn carries the character that was just chosen, not the old one")

stubMod.world = nil
stubSprites.SPRITE_RED = nil
stubSprites.SPRITE_BLUE = nil

end)()

-- ------------------------------------------------------------------
-- 5b. Avatars decorate / undecorate -- the depth-nudge compensation
-- ------------------------------------------------------------------
--
-- decorate/undecorate patch a live NPC's update and pose so an avatar
-- always loses a draw-order tie against the player: a whole-pixel py is
-- nudged up by AVATAR_DEPTH_NUDGE right after NPC:update recomputes it, and
-- both ways a position leaves the avatar layer -- pose, for the renderer,
-- and cellOf, for a caller comparing against the roster -- add it back so
-- nothing downstream of the sort ever sees the fraction.  See
-- src/Config.lua's AVATAR_DEPTH_NUDGE and src/Avatars.lua's decorate for the
-- full argument.
--
-- A stub class stands in for the engine's NPC: update writes a new
-- whole-pixel py only while moving -- exactly like NPC:update landing a
-- step -- and pose reads py back out seven values wide, the same shape
-- src/Avatars.lua wraps.  cellOf itself reaches through mod.world:npc, a
-- live overworld handle this headless suite does not stand up -- that call
-- is e2e territory, exercised by run-mmo-e2e.sh.  What is pinned here
-- instead is the arithmetic cellOf leans on just as much as pose does: case
-- 5 below proves the round trip -- subtract the nudge, add it back -- lands
-- on the exact original whole pixel.
--
-- Wrapped for scope, like the trainer-card section below: this file's main
-- chunk sits close enough to Lua's 200-local ceiling that one more section's
-- worth of locals is what tips it over.

;(function()

local NUDGE = Config.AVATAR_DEPTH_NUDGE

local StubNpcClass = {}
StubNpcClass.__index = StubNpcClass

function StubNpcClass:update(...)
  if self.moving then self.py = self.targetPy end
  return "base-update", 42
end

function StubNpcClass:pose(...)
  return "sprite", self.px, self.py, self.facing, self.phase, self.flip, self.hop
end

local function newStubNpc(py)
  return setmetatable({
    px = 48, py = py, facing = "down", phase = 2, flip = true, hop = false,
    moving = false,
  }, StubNpcClass)
end

-- a bare-table fingerprint, so "undecorate leaves it indistinguishable from
-- a table that was never decorated" is a real comparison and not a
-- hand-picked field list
local function keyList(t)
  local ks = {}
  for k in pairs(t) do ks[#ks + 1] = tostring(k) end
  table.sort(ks)
  return table.concat(ks, ",")
end

-- 1. decorate marks the NPC and installs instance-level update/pose
local originalPy = 80
local npc = newStubNpc(originalPy)
Avatars.decorate(npc)
eq(npc.mmoAvatar, true, "decorate marks the NPC as an avatar")
eq(npc.passable, true, "and makes it passable, the same escape hatch the follower uses")
check(type(rawget(npc, "update")) == "function",
      "update is shadowed on the instance, not left resolving through the metatable")
check(type(rawget(npc, "pose")) == "function", "so is pose")

-- 2. idle drift-proofing: a hundred no-op updates nudge exactly once
for i = 1, 100 do npc:update() end
eq(npc.py, originalPy - NUDGE,
   "a whole py is nudged once and then never again -- the fraction is the guard")

-- 3. moving recompute: the base update writes a fresh whole py, and that
-- gets nudged too, from the new value rather than stacking on the old one
local newPy = 96
npc.moving = true
npc.targetPy = newPy
npc:update()
eq(npc.py, newPy - NUDGE, "a freshly-landed step is nudged from its own new py")

-- 4. the override forwards whatever the base update returned, arity and all
npc.moving = false
local r1, r2 = npc:update()
eq(r1, "base-update", "the wrapped update forwards the base call's first return value")
eq(r2, 42, "and its second -- the wrapper does not narrow the base method's arity")

-- 5. pose hands back the true pixel, not the sort's nudged one -- and this
-- is also the round trip cellOf leans on, since it undoes the same nudge
-- the same way
local sprite, px, poseP, facing, phase, flip, hop = npc:pose()
eq(poseP, newPy, "pose adds the nudge back, landing exactly on the whole pixel again")
eq(poseP, (newPy - NUDGE) + NUDGE,
   "the same round trip cellOf performs -- subtract, then add back -- is exact in doubles")
eq(sprite, "sprite", "pose forwards the sprite untouched")
eq(px, npc.px, "and px untouched")
eq(facing, npc.facing, "and facing")
eq(phase, npc.phase, "and the walk phase")
eq(flip, npc.flip, "and the step flip")
eq(hop, npc.hop, "and the hop flag -- only py is ever touched")

-- 6. decorate is idempotent: an already-marked NPC is untouched, not
-- rewrapped, so a second nudge never stacks on the first
local updateFn, poseFn = rawget(npc, "update"), rawget(npc, "pose")
local pyBeforeRedecorate = npc.py
Avatars.decorate(npc)
eq(rawget(npc, "update"), updateFn, "redecorating keeps the same update closure")
eq(rawget(npc, "pose"), poseFn, "and the same pose closure")
eq(npc.py, pyBeforeRedecorate, "and touches no field -- the marker alone is the guard")

-- 7. undecorate restores a table indistinguishable from one that was never
-- decorated -- the engine pools NPC tables, so anything left behind would
-- be born again on some later, ordinary NPC
local plainNpc = newStubNpc(64)
local plainKeys = keyList(plainNpc)
Avatars.decorate(plainNpc)
Avatars.undecorate(plainNpc)
eq(keyList(plainNpc), plainKeys,
   "the key set after decorate+undecorate matches the table before either ran")
eq(rawget(plainNpc, "update"), nil, "update falls back to the metatable again")
eq(rawget(plainNpc, "pose"), nil, "so does pose")
eq(plainNpc.update, StubNpcClass.update, "which resolves to the class method")
eq(plainNpc.pose, StubNpcClass.pose, "for both")

-- 8. a pre-existing instance override survives a decorate/undecorate round
-- trip -- decorate has to wrap *that*, not the class method underneath it,
-- and undecorate has to hand back that exact function, not nil
local overridden = newStubNpc(64)
local preexisting = function(self, ...) return "pre-existing" end
rawset(overridden, "update", preexisting)
Avatars.decorate(overridden)
check(rawget(overridden, "update") ~= preexisting,
      "decorate wraps whatever was already shadowing update on the instance")
Avatars.undecorate(overridden)
eq(rawget(overridden, "update"), preexisting,
   "and undecorate hands back that exact pre-existing function, not the class method")

-- 9. half-decoration refusal: nothing is written until both class methods
-- are in hand, and undecorate never touches a table it did not mark
local NoUpdateClass = { pose = StubNpcClass.pose }
NoUpdateClass.__index = NoUpdateClass
local broken = setmetatable({ py = 64 }, NoUpdateClass)
local brokenKeys = keyList(broken)
Avatars.decorate(broken)
eq(keyList(broken), brokenKeys,
   "a class with no update method gets no fields written at all -- half a decoration")
eq(broken.mmoAvatar, nil,
   "not even the marker, so decorating the same table again after it is fixed still works")

local untouched = newStubNpc(64)
local sentinelUpdate = function(self, ...) return "sentinel" end
rawset(untouched, "update", sentinelUpdate)
local untouchedKeys = keyList(untouched)
Avatars.undecorate(untouched)
eq(keyList(untouched), untouchedKeys, "undecorate on a table it never marked is a no-op")
eq(rawget(untouched, "update"), sentinelUpdate,
   "and never blanks an instance slot that was already there")

end)()

-- ------------------------------------------------------------------
-- 6. Characters you can wear
-- ------------------------------------------------------------------
--
-- The catalog carries boulders and Poke Balls next to the people. Wearing a
-- boulder is not just odd-looking: an object sheet has no walk frames, so
-- the avatar would animate wrongly on every other screen.

local Chars = need("Chars")

eq(Chars.label("SPRITE_COOLTRAINER_M"), "COOLTRAINER M", "labels are readable")
eq(Chars.label("SPRITE_RED"), "RED", "and short ones stay short")

eq(Chars.excluded("SPRITE_BOULDER"), true, "a boulder is not a character")
eq(Chars.excluded("SPRITE_POKE_BALL"), true, "nor is an item")
eq(Chars.excluded("SPRITE_UNUSED_GUARD"), true, "unused entries are skipped")
eq(Chars.excluded("SPRITE_GAMBLER_ASLEEP"), true,
   "and a pose with no walk cycle is skipped")
eq(Chars.excluded("SPRITE_YOUNGSTER"), false, "a person is a character")

-- Shaped like the real records: `walker` is what the catalog actually
-- carries, and it is the flag that decides whether a sprite can be worn.
-- SPRITE_NURSE is here as the case that catches a naive "is it a person"
-- filter -- a person, but drawn from a sheet with no walking frames.
stubSprites = {
  SPRITE_RED = { walker = true },
  SPRITE_YOUNGSTER = { walker = true },
  SPRITE_AGATHA = { walker = true },
  SPRITE_NURSE = { walker = false },
  SPRITE_BOULDER = { walker = false },
  SPRITE_POKE_BALL = { walker = false },
  SPRITE_UNUSED_GUARD = { walker = true },
}
local wearable = Chars.list()
eq(wearable[1], "SPRITE_RED", "RED leads the list -- it is the guaranteed one")
local names = {}
for _, id in ipairs(wearable) do names[id] = true end
check(names.SPRITE_AGATHA and names.SPRITE_YOUNGSTER, "people are offered")
check(not names.SPRITE_BOULDER and not names.SPRITE_POKE_BALL,
      "objects are not")
check(not names.SPRITE_UNUSED_GUARD, "and neither are unused entries")
check(not names.SPRITE_NURSE,
      "nor a person with no walk cycle -- she would break mid-step")

-- The fallback the goal asks for: a character this game does not carry --
-- a different ROM, a mod the other player has and you do not -- becomes RED
-- rather than failing to draw.
eq(Chars.available("SPRITE_AGATHA"), true, "a character we have is available")
eq(Chars.available("SPRITE_MISSINGNO"), false, "one we do not have is not")
eq(Chars.resolve("SPRITE_AGATHA"), "SPRITE_AGATHA", "so it resolves to itself")
eq(Chars.resolve("SPRITE_MISSINGNO"), Config.DEFAULT_SPRITE,
   "and an unknown character falls back to RED")
eq(Chars.resolve(nil), Config.DEFAULT_SPRITE, "as does nothing at all")
eq(Chars.resolve("SPRITE_BOULDER"), Config.DEFAULT_SPRITE,
   "and so does a real sprite that is not a character")

-- ------- portrait colours match the overworld
--
-- The trainer card, the ranking list and the character picker all crop frame
-- 0 through Chars.portrait. Blitting the raw sheet skips SpriteRenderer's
-- OBP bake and turns DMG shades into the wrong colours (lime-green skin on
-- a gentleman, for instance). This pins the path through resolveImage.

;(function()
  local usedResolve = false
  local mockImg = { getDimensions = function() return 16, 96 end }
  local savedSR = package.loaded["src.render.SpriteRenderer"]
  package.loaded["src.render.SpriteRenderer"] = {
    new = function(record, seed)
      check(record.image == "sprites/gentleman.png",
            "portrait passes the sprite record through")
      eq(seed, "SPRITE_GENTLEMAN",
         "portrait uses the sprite id as the renderer seed")
      return {
        resolveImage = function(self)
          usedResolve = true
          return mockImg
        end,
      }
    end,
  }

  _G.love = _G.love or {}
  love.graphics = love.graphics or {}
  local savedNewQuad = love.graphics.newQuad
  love.graphics.newQuad = function(x, y, w, h, iw, ih)
    return { x = x, y = y, w = w, h = h, iw = iw, ih = ih }
  end

  local portraitMod = {
    content = {
      sprites = {
        get = function(_, id)
          if id == "SPRITE_GENTLEMAN" then
            return { image = "sprites/gentleman.png", frames = 6, walker = true }
          end
        end,
      },
    },
  }
  local portraitNeed = resolver(portraitMod)
  local PortraitChars = portraitNeed("Chars")

  local art = PortraitChars.portrait("SPRITE_GENTLEMAN")
  check(usedResolve,
        "portrait asks SpriteRenderer for a palette-correct image")
  check(art ~= nil and art.image == mockImg,
        "and hands back what resolveImage returned")
  check(art.quad ~= nil, "with a quad for the front frame")

  package.loaded["src.render.SpriteRenderer"] = savedSR
  if savedNewQuad then love.graphics.newQuad = savedNewQuad end
end)()

-- ------- the trainer card fits the box it is drawn in
--
-- Wrapped for scope, like the look-bookkeeping section below: this file's
-- main chunk is close enough to Lua's 200-local ceiling that two branches
-- adding a section each is enough to cross it, which is how it failed the
-- moment the address-layout work and this met.
--
-- The card is a 20-tile box. Glyphs are 8px and the text column starts at
-- x=16, so a row reaches the right border after 17 characters -- and a row
-- level with the portrait (x=116) after only 12.

;(function()
--
-- The regression this pins: NAME and the character label are the two rows
-- whose width the *player* decides, and both were drawn beside the portrait,
-- where neither fits. "LOOK/COOLTRAINER M" (18) was rendered straight
-- through the art. They now get full-width rows, which is only correct for
-- as long as nothing can exceed 17 -- so that is what is asserted, against
-- the real catalog rather than the stub above.

local ROW_CHARS = 17          -- (152 - 16) / 8, border to text column
local BESIDE_ART_CHARS = 12   -- (116 - 16) / 8, portrait's left edge

check(#"NAME/" + Config.NAME_MAX <= ROW_CHARS,
      "a full-length trainer name still fits its row")
check(#"NAME/" + Config.NAME_MAX > BESIDE_ART_CHARS,
      "and would not have fit beside the portrait -- why the row moved")

-- The catalog half needs the real thing. The committed fixture carries two
-- walkers ("FIX PLAYER", 10 chars), so asserting against it would pass
-- without ever seeing a name long enough to fail -- a green tick for
-- coverage that is not there. Real dataset or an honest skip, the way
-- tests/mod_examples_tests.lua handles the same gap.
local generated = loadfile("data/generated/sprites.lua")
if not generated then
  print("rby_mmo: card-width check skipped -- no data/generated/sprites.lua "
    .. "to measure real character names against")
else
  local longest, longestId = 0, nil
  local wearable = 0
  for id, record in pairs(generated() or {}) do
    if type(id) == "string" and type(record) == "table"
       and record.walker == true and not Chars.excluded(id) then
      wearable = wearable + 1
      local label = Chars.label(id)
      if #label > longest then longest, longestId = #label, id end
    end
  end
  check(wearable > 0, "the real catalog offers wearable characters")
  check(longest <= ROW_CHARS,
        ("the longest character label fits its row (%s, %d chars)")
          :format(tostring(longestId), longest))
  -- The prefix this row used to carry cannot come back: the longest label
  -- is the whole row on its own, so "LOOK/" would put it 5 over.
  check(#"LOOK/" + longest > ROW_CHARS,
        "and a LOOK/ prefix would not -- the bare label is not a style choice")
end

end)()

-- ------- the trainer card on the wire

local card = Wire.profile({ idNo = 12345, money = 3000, badges = 3,
                            seen = 60, owned = 30, playtime = 7265 })
eq(card.money, nil, "money is never carried -- the card does not show it")
check(card ~= nil, "a full card sanitises")
eq(card.badges, 3, "badge count survives")
eq(card.playtime, 7265, "so does playtime")
eq(Wire.profile(nil), nil, "no card is not a card")
eq(Wire.profile("nope"), nil, "and neither is a string")

local hostile = Wire.profile({ idNo = "9" .. string.rep("9", 12),
                               badges = 1e9, seen = 0 / 0 })
check(hostile ~= nil, "a hostile card still sanitises to a table")
eq(hostile.idNo, nil, "an out-of-range id is dropped")
eq(hostile.badges, nil, "an absurd badge count is dropped")
eq(hostile.seen, nil, "and NaN is dropped")

-- presence carries it through, since the card is shown from the roster
local withCard = Wire.presence({ id = "p9", name = "ASH",
                                 profile = { badges = 8 } })
eq(withCard.profile.badges, 8, "presence carries the card")
eq(Wire.presence({ id = "p9", name = "ASH" }).profile, nil,
   "and a player who sent none simply has none")

-- ------- the card this copy builds, for the wire and for MY PROFILE
--
-- Client is loaded here rather than at the top of this section because
-- requiring it constructs the transport, the host server and the UI; none
-- of that is wanted by the pure-module tests above.
--
-- Wrapped for scope for the same reason as the section above.

;(function()

local Client = need("Client")

local saveGame = { save = {
  player = { id = 4242, name = "GREEN" },
  money = 1234,
  -- camelCase, the way src/core/SaveData.lua writes it
  playTime = 3661,
  pokedex = { seen = { A = true, B = true, C = true }, owned = { A = true } },
} }

-- The regression: this read save.playtime, which no engine save has, so
-- every card ever sent said TIME/  0:00 and nobody could tell it was a bug
-- rather than a new file.
eq(Client.profile(saveGame).playtime, 3661, "playtime comes off save.playTime")
eq(Client.profile({ save = { playtime = 99 } }).playtime, 99,
   "and a save that used the lowercase key is still read")

eq(Client.profile(saveGame).money, nil,
   "the card that goes on the wire has no money on it")
eq(Client.profile(saveGame).seen, 3, "the dex is counted, not guessed")
eq(Client.profile(saveGame).owned, 1, "both halves of it")

-- Your own card is roster-shaped so the same screen draws it, and money is
-- what tells the two apart -- Wire.profile can never produce it, so a card
-- carrying money is necessarily the local one.
local mine = Client.ownCard(saveGame)
eq(mine.name, "GREEN", "your own card falls back to the save's trainer name")
eq(mine.sprite, Config.DEFAULT_SPRITE, "and to the default look")
eq(mine.money, 1234, "your own card shows your own wallet")
eq(mine.profile.idNo, 4242, "and carries the same fields peers are sent")

-- The menus call these with a colon, which puts the module table in the
-- first slot; without arg1 the save fallback above silently became PLAYER.
eq(Client:ownCard(saveGame).name, "GREEN", "the colon form reaches the save")
eq(Client:playerName(saveGame), "GREEN", "and so does playerName's")

end)()

-- ------- the characters the mod brings of its own
--
-- Wrapped for scope like the two sections above, for the same reason: this
-- chunk is close enough to Lua's 200-local ceiling that one more section at
-- the top level is enough to cross it.

;(function()

local Cast = need("Cast")

stubSprites = {}
stubScales = {}
check(Cast.install(), "the mod's own characters register")

local ids = Cast.ids()
eq(#ids, 2, "two of them")
eq(ids[1], "SPRITE_NIRE", "NIRE")
eq(ids[2], "SPRITE_NIRE_HOOD", "and NIRE HOOD")

-- Installing twice would be a duplicate registration, which the loader is
-- entitled to refuse -- and F5 in dev mode re-runs the entry chunk.
check(Cast.install(), "installing again is a no-op rather than a second try")
eq(#Cast.ids(), 2, "and does not double the cast")

-- The catalog is what everything downstream reads, so what matters is that
-- the record satisfies the same filter every other wearable character does.
local offered = {}
for _, id in ipairs(Chars.list()) do offered[id] = true end
check(offered.SPRITE_NIRE and offered.SPRITE_NIRE_HOOD,
      "so the CHARACTER screen offers them like any other character")
eq(Chars.available("SPRITE_NIRE"), true, "and a peer wearing one can draw it")
eq(Chars.label("SPRITE_NIRE_HOOD"), "NIRE HOOD", "under a readable name")

-- Every character in the options row has to be a character that exists, or
-- the row offers a choice that silently resolves back to RED.
for _, row in ipairs(Config.SPRITES) do
  if row[2] == "SPRITE_NIRE" or row[2] == "SPRITE_NIRE_HOOD" then
    offered[row[2]] = "listed"
  end
end
eq(offered.SPRITE_NIRE, "listed", "NIRE is offered in the options row too")
eq(offered.SPRITE_NIRE_HOOD, "listed", "and so is NIRE HOOD")

-- ------- the pics the catalog does not cover
--
-- "front" is the trainer card, Oak's intro and the Hall of Fame; "back" is
-- the battle pic. A vanilla character answers nothing at all, which is what
-- keeps wearing COOLTRAINER from changing what you fight as.
local back = Cast.pic("SPRITE_NIRE", "back")
local front = Cast.pic("SPRITE_NIRE", "front")
check(back and back:find("back.png", 1, true), "NIRE has a battle back pic")
check(front and front:find("front.png", 1, true), "and a trainer-card pic")
eq(Cast.pic("SPRITE_NIRE", nil), front, "an unnamed side is the front one")
eq(Cast.pic("SPRITE_RED", "back"), nil, "RED keeps the pics the game gave it")
eq(Cast.pic(nil, "back"), nil, "and wearing nothing changes nothing")
eq(Cast.owns("SPRITE_NIRE"), true, "NIRE is ours")
eq(Cast.owns("SPRITE_RED"), false, "RED is not")

-- ------- the art is really there, and really the size the engine reads it at
--
-- A PNG's IHDR is its first chunk, so width and height are bytes 17..24 --
-- enough to catch the failure this cannot otherwise see: a sheet that is one
-- frame short, or a back pic resaved at another size, loads without
-- complaint and then draws wrongly. The scale registered for the back pic is
-- only correct for the size asserted here.
local function pngSize(path)
  local handle = io.open(path, "rb")
  if not handle then return nil end
  local head = handle:read(24)
  handle:close()
  if type(head) ~= "string" or #head < 24 then return nil end
  local function be32(at)
    local a, b, c, d = head:byte(at, at + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
  end
  return be32(17), be32(21)
end

for _, char in ipairs(Config.OWN_CHARS) do
  for file, want in pairs({ ["walk.png"] = { 16, 96 },
                            ["front.png"] = { 56, 56 },
                            ["back.png"] = { 48, 48 } }) do
    local w, h = pngSize(MOD_PATH .. "/" .. char.dir .. "/" .. file)
    eq(w, want[1], char.label .. "'s " .. file .. " is " .. want[1] .. " wide")
    eq(h, want[2], "and " .. want[2] .. " tall")
  end
end

-- The registered scale has to be a whole number -- a fraction draws uneven
-- pixels on the classic battle view's nearest-neighbour canvas, which was
-- exactly this mod's shipped bug (64/48, chosen to keep a 64px footprint).
-- It also has to keep the pic under the text-box top: feet pin at y=96
-- regardless of scale, so the pic grows upward from there, and 96 screen
-- pixels tall would reach all the way up over the enemy pic and status
-- boxes. 95 is the most room there is below that ceiling.
for _, char in ipairs(Config.OWN_CHARS) do
  local scale = stubScales[Cast.scaleId(char)]
  check(scale ~= nil, char.label .. "'s back pic is sized")
  if scale then
    eq(scale.scale % 1, 0, char.label .. "'s scale is a whole number")
    check(48 * scale.scale <= 95,
          char.label .. "'s back pic stays under the text-box top")
  end
end

-- ------- the snap: a fractional or non-numeric backScale is caught and
-- rounded, never shipped as asked
--
-- Config.OWN_CHARS only ever carries 1 today, so exercising the snap needs
-- a synthetic row -- built by loading a second, disposable copy of Cast
-- through the same resolver()-plus-preseeded-cache trick the file-store
-- Client tests above use, with its own Config swap and its own log and
-- registries, so none of this touches the real cast or the
-- stubSprites/stubScales the rest of this section shares.
local function loadCastWith(chars)
  local scaleStub, spriteStub, warns = {}, {}, {}
  local fakeMod = {
    id = "rby_mmo",
    path = MOD_PATH,
    log = {
      info = function() end,
      error = function() end,
      warn = function(_, fmt, ...)
        local ok, line = pcall(string.format, fmt, ...)
        warns[#warns + 1] = ok and line or tostring(fmt)
      end,
    },
    assets = { path = function(_, relative) return MOD_PATH .. "/" .. relative end },
    content = {
      sprites = { register = function(_, id, record) spriteStub[id] = record end },
      battle_sprite_scales = {
        register = function(_, id, record) scaleStub[id] = record end,
      },
    },
  }
  local loadstr = loadstring or load
  local cache = {
    Config = {
      MOD_ID = Config.MOD_ID,
      CHAR_FRAMES = Config.CHAR_FRAMES,
      CHAR_PALETTE_SOURCE = Config.CHAR_PALETTE_SOURCE,
      OWN_CHARS = chars,
    },
  }
  local function need2(name)
    if cache[name] then return cache[name] end
    local handle = io.open(MOD_PATH .. "/src/" .. name .. ".lua", "rb")
    if not handle then error("missing module " .. name, 0) end
    local body = handle:read("*a")
    handle:close()
    local chunk = assert(loadstr(body, "@" .. name .. ".lua"))
    cache[name] = chunk(need2, fakeMod)
    return cache[name]
  end
  local FreshCast = need2("Cast")
  FreshCast.install()
  return FreshCast, scaleStub, warns
end

local function snapChar(id, backScale)
  return { id = id, label = id, dir = "assets/chars/nire", backScale = backScale }
end

do
  local char = snapChar("SPRITE_SNAP_FRACTION", 64 / 48)
  local FreshCast, scaleStub, warns = loadCastWith({ char })
  local scale = scaleStub[FreshCast.scaleId(char)]
  check(scale ~= nil, "a fractional backScale still registers a scale")
  eq(scale and scale.scale, 1, "snapped to the nearest whole number")
  eq(#warns, 1, "and exactly one warn fires")
  check(warns[1] and warns[1]:find("whole-number backScale", 1, true) ~= nil,
        "naming the whole-number remediation")
end

do
  local char = snapChar("SPRITE_SNAP_ABSENT", nil)
  local FreshCast, scaleStub, warns = loadCastWith({ char })
  local scale = scaleStub[FreshCast.scaleId(char)]
  eq(scale and scale.scale, 1, "an absent backScale defaults to 1")
  eq(#warns, 0, "and is not treated as a mistake worth warning about")
end

do
  local char = snapChar("SPRITE_SNAP_WHOLE", 2)
  local FreshCast, scaleStub, warns = loadCastWith({ char })
  local scale = scaleStub[FreshCast.scaleId(char)]
  eq(scale and scale.scale, 2, "an already-whole backScale registers unchanged")
  eq(#warns, 0, "and does not warn")
end

do
  local char = snapChar("SPRITE_SNAP_NONNUMERIC", "smash")
  local FreshCast, scaleStub, warns = loadCastWith({ char })
  local scale = scaleStub[FreshCast.scaleId(char)]
  eq(scale and scale.scale, 1, "a non-numeric backScale falls back to 1")
  eq(#warns, 1, "and is warned about, not silently substituted")
  check(warns[1] and warns[1]:find("whole-number backScale", 1, true) ~= nil,
        "naming the same remediation")
end

-- ------- the mark that says a character came with the mod
--
-- The CHARACTER list is 36 ROM characters and two of ours, and the rule for
-- the mark is small enough to state exactly: ours, visible, and not the one
-- under the cursor -- which is the only row where the mark and the cursor
-- would land in the same cell. Pinned here rather than off a screenshot,
-- because it has to keep holding as the list scrolls.
local UiRows = need("Ui").markedRows

local list = {
  { label = "MR FUJI", value = "SPRITE_MR_FUJI" },
  { label = "NIRE", value = "SPRITE_NIRE" },
  { label = "NIRE HOOD", value = "SPRITE_NIRE_HOOD" },
  { label = "OAK", value = "SPRITE_OAK" },
}

local function marked(index, scroll, rows)
  local out = {}
  for _, mark in ipairs(UiRows({ items = list, index = index,
                                 scroll = scroll or 0, rows = rows or 7 })) do
    out[#out + 1] = list[(scroll or 0) + mark.row].label
  end
  return table.concat(out, ",")
end

eq(marked(1), "NIRE,NIRE HOOD", "both of ours are marked, and nothing else")
eq(marked(2), "NIRE HOOD",
   "except the one under the cursor -- it would share the cursor's cell")
eq(marked(3), "NIRE", "and the other way round")
eq(marked(4), "NIRE,NIRE HOOD", "a vanilla row under the cursor marks neither")

-- The rows are the *visible* ones, so a scrolled list marks by what is on
-- screen rather than by position in the whole catalog.
eq(marked(1, 2, 7), "NIRE HOOD", "a scrolled list marks what is on screen")
eq(marked(1, 0, 2), "NIRE", "and a short window stops at its last row")

-- The y it hands back is the widget's own row geometry: row 1 at y=24, then
-- every 16 after it. Wrong by one row and the mark lands on the neighbour.
local rows = UiRows({ items = list, index = 1, scroll = 0, rows = 7 })
eq(rows[1].row, 2, "the mark is on the second visible row")
eq(rows[1].y, 8 + 2 * 16, "at the y that row's label is drawn on")

eq(#UiRows(nil), 0, "no menu marks nothing")
eq(#UiRows({}), 0, "and neither does one with no items")

stubSprites = {}
stubScales = {}

end)()

-- ------------------------------------------------------------------
-- 7. Playing nicely with a mod that owns the world pass
-- ------------------------------------------------------------------
--
-- DramaticShapeVoxelMod registers a "voxel" render pipeline whose drawWorld
-- replaces the overworld with a 3D diorama. This overlay places nameplates
-- by tile offset from the local player, which is only true of the flat 2D
-- projection -- under a diorama a label would float somewhere unrelated to
-- the character it names. Detecting that is what lets it fall back instead
-- of drawing nonsense.

local Overlay = need("Overlay")
local overlay = Overlay.new({ chat = Chat.new() })

local function gameWith(pipelineLevels)
  return { save = { options = { pipelines = pipelineLevels } } }
end

stubPipelines = {}
eq(overlay:worldIsFlat(gameWith({})), true, "no pipelines means the flat world")
eq(overlay:worldIsFlat({}), true, "and so does a save with no options")
eq(overlay:worldIsFlat(nil), true, "and no game at all")

-- a post-process pipeline does not move anything; the projection is intact
stubPipelines = { tiltshift = { worldPresent = function() end } }
eq(overlay:worldIsFlat(gameWith({ tiltshift = 2 })), true,
   "a post-process pipeline leaves the projection alone")

-- one that replaces the world does
stubPipelines = {
  voxel = { drawWorld = function() end },
  tiltshift = { worldPresent = function() end },
}
eq(overlay:worldIsFlat(gameWith({ voxel = 0, tiltshift = 2 })), true,
   "a world pipeline that is switched off still leaves it flat")
eq(overlay:worldIsFlat(gameWith({ voxel = 1 })), false,
   "but an active one means the flat projection no longer holds")
eq(overlay:worldIsFlat(gameWith({ voxel = 3, tiltshift = 1 })), false,
   "at any level, alongside any post-process")

stubPipelines = {}

-- Voxel exports its live camera to companion mods.  A nameplate must use
-- that projection rather than the flat camera's 16px grid, and its returned
-- coordinates are canvas pixels, not necessarily final-window pixels when
-- Voxel's anti-aliasing is on.
;(function()
local projectedArgs = nil
local voxelGame = {
  mods = { exports = { DRAMATIC_SHAPE = { lib = {
    require = function(name)
      if name == "Voxel3D" then
        return {
          project = function(x, y, z)
            projectedArgs = { x, y, z }
            return 150, 75
          end,
          size = function() return 300, 150 end,
        }
      end
      if name == "VoxelScene" then
        return { groundAt = function() return 4 end }
      end
    end,
  } } } },
}
local voxelOverworld = { map = {} }
local vx, vy = overlay:voxelAnchor(voxelGame, voxelOverworld, 32, 48, 600, 450)
eq(vx, 300, "a Voxel x coordinate is scaled from its canvas to the final window")
eq(vy, 225, "and the same applies to y when AA enlarged the canvas")
eq(projectedArgs[1], 40, "the label projects from the avatar cell centre")
eq(projectedArgs[2], 22, "from two pixels above its 16px head and ground height")
eq(projectedArgs[3], 56, "using the centre of the avatar's world-depth cell")
eq(overlay:voxelAnchor({}, voxelOverworld, 0, 0, 600, 450), nil,
   "a renderer without Voxel's companion API remains a safe fallback")
end)()

-- Wrapped in a function purely for scope, the way the trade scenario below
-- is: this chunk sits at Lua's 200-local ceiling for one function body, and
-- the merge put two branches' worth of new top-level names into it at once.

;(function()

-- ------- the party marker on a nameplate
--
-- A `▶` in front of your party member's nickname, so that on a map with
-- several players standing on it "which of these is my friend" is answerable
-- at a glance. Everybody else keeps their own name.
--
-- What this cannot check is whether the marker is *drawable*: the committed
-- fixture font carries letters and digits and nothing else, so asking it
-- about `▶` would fail on a glyph the real extracted font has. The
-- two-instance driver asks that question against the real charmap -- and it
-- is not hypothetical, it is the bug this marker had. An asterisk drew
-- nothing at all, and every string-level assertion here passed anyway.

local Party = need("Party")
local plateParty = Party.new({ send = function() end },
                             { say = function() end })
plateParty:setSelf("me")
eq(overlay:nameFor({ id = "them", name = "BOB" }), "BOB",
   "with no party in play, a player is drawn under their own name")

plateParty:onParty({ id = "1", members = { { id = "me", name = "ANN" },
                                           { id = "them", name = "BOB" } } })
local partied = Overlay.new({ chat = Chat.new(), party = plateParty })

eq(partied:nameFor({ id = "them", name = "BOB" }),
   Overlay.PARTY_MARK .. "BOB",
   "your party member's plate carries the marker, in front of the name")
eq(partied:nameFor({ id = "them", name = "BOB" }), "\226\150\182BOB",
   "which is the game's own cursor glyph -- the font has no asterisk to draw")
eq(partied:nameFor({ id = "other", name = "CAL" }), "CAL",
   "a player outside the party is not marked")
eq(partied:nameFor({ id = "me", name = "ANN" }), "ANN",
   "nor are you, on the one screen you never appear on anyway")

-- One glyph, three bytes. Every length this file measures for the screen is
-- measured in glyphs, and a marker that is one character but three bytes long
-- is exactly what tells a byte-counting cap from a glyph-counting one.
eq(#Overlay.PARTY_MARK, 3, "the marker is three bytes of UTF-8")
eq(#partied:nameFor({ id = "them", name = "BOB" }), 6,
   "so a marked name is longer in bytes than it is on screen")

-- ------- what colour a plate is drawn in
--
-- Three answers, most specific first.  The interesting case is the overlap: a
-- friend who is also the person you are travelling with comes out green, and
-- that is the right way round -- the party is the relationship that changes
-- what you should do next, being friends is a standing fact that will still
-- be true when the party ends.
do
  local Friends = need("Friends")
  local mine = Friends.new({ send = function() end, isReady = function() return true end },
                           { say = function() end },
                           { mod = { save = { get = function() end,
                                              set = function() end },
                                     log = { warn = function() end } } })
  mine:setHub("colour:7788", "ME")
  mine:_add("BOB")

  local plain = Overlay.new({ chat = Chat.new(), party = plateParty })
  eq(plain:labelColor({ id = "other", name = "CAL" }), Overlay.LABEL_WHITE,
     "somebody you have never met is drawn white")

  local withFriends = Overlay.new({ chat = Chat.new(), party = plateParty,
                                    friends = mine })
  eq(withFriends:labelColor({ id = "other", name = "BOB" }),
     Overlay.FRIEND_BLUE, "a friend is drawn in the smooth blue")
  eq(Overlay.FRIEND_BLUE, Config.FRIEND_BLUE,
     "which is the one Config holds, so the plate and the corner toast that "
     .. "announces them cannot drift apart")
  eq(withFriends:labelColor({ id = "other", name = "bob" }),
     Overlay.FRIEND_BLUE, "matched on the name, folded the way the list folds it")
  eq(withFriends:labelColor({ id = "them", name = "BOB" }),
     Overlay.PARTY_GREEN,
     "and a friend who is also your party member stays green -- the marker "
     .. "you need to pick them out of a crowd is not the one to give up")
  eq(withFriends:labelColor({ id = "other", name = "CAL" }),
     Overlay.LABEL_WHITE, "everybody else is still white")

  eq(plain:isFriend({ id = "other", name = "BOB" }), false,
     "an overlay built without a friends list simply has none, rather than "
     .. "throwing on a ctx that predates the feature")
end

-- ------- nameplate screen position
--
-- Matches SpriteRenderer and Camera:follow -- the old anchor used the centre
-- of the view minus half a cell, which sat the plate on the character's
-- chest instead of above their head.

local cx, top = Overlay.screenOf(80, 80, 80, 80)
eq(cx, 72, "a co-located avatar is centred at sprite left + 8")
eq(top, 60, "with its sprite top at screen y=60, not 64")

local cx2, top2 = Overlay.screenOf(96, 80, 80, 80)
eq(cx2, 88, "one cell to the right shifts the label centre by 16px")
eq(top2, 60, "and leaves vertical placement unchanged")

local _, top3 = Overlay.screenOf(80, 96, 80, 80)
eq(top3, 76, "one cell down moves the sprite top by 16px")

-- mid-step: fractional cells follow pixel position, not integer cells
local cx4, top4 = Overlay.screenOf(88, 80, 80, 80)
eq(cx4, 80, "half a step east lands halfway between the two columns")
eq(top4, 60, "without changing the row")

-- ------- your party member on the TOWN MAP
--
-- Where in Kanto they are, which is the one question the overworld cannot
-- answer -- it only ever shows the room you are standing in.
--
-- Only the placement is asserted here, because only the placement can be
-- wrong in an interesting way: which member lands on which city, and who is
-- left off. The drawing itself is four love.graphics calls that plain luajit
-- has no love to make, so the two-instance driver opens a real TOWN MAP and
-- reads back what the frame committed.
--
-- The fake state is the shape src/ui/TownMap builds for itself: byMap is its
-- mapId -> {name, x, y} index, and markerXY puts a cell at x*8+16, y*8+8.

local townRoster = Roster.new()
townRoster:setSelf("me")
townRoster:put(Wire.presence({ id = "them", name = "BOB", sprite = "SPRITE_BLUE",
                               map = "CERULEAN_CITY", x = 3, y = 4 }))
local townParty = Party.new({ send = function() end }, { say = function() end })
townParty:setSelf("me")
local townOverlay = Overlay.new({ roster = townRoster, party = townParty,
                                  chat = Chat.new() })
local TOWN_STATE = {
  mode = "grid",
  byMap = {
    CERULEAN_CITY = { name = "CERULEAN CITY", x = 10, y = 5 },
    PALLET_TOWN   = { name = "PALLET TOWN",   x = 3,  y = 15 },
    REDS_HOUSE_2F = { name = "PALLET TOWN",   x = 3,  y = 15 },
  },
}

eq(#townOverlay:townMapMarks(TOWN_STATE), 0,
   "with no party there is nobody to put on the map")

townParty:onParty({ id = "1", members = { { id = "me", name = "ANN" },
                                          { id = "them", name = "BOB" } } })
local marks = townOverlay:townMapMarks(TOWN_STATE)
eq(#marks, 1, "a party member standing in a known city gets a mark")
eq(marks[1].name, "BOB", "carrying their nickname")
eq(marks[1].sprite, "SPRITE_BLUE", "and the character they chose")
eq(marks[1].place, "CERULEAN CITY", "at the city they are actually in")
-- markerXY: the nybble grid sits two tiles in and one tile down
eq(marks[1].x, 10 * 8 + 16, "on the cell's own screen column")
eq(marks[1].y, 5 * 8 + 8, "and row")

-- an interior points at its town's square, the way the screen's own index does
townRoster:move("them", "REDS_HOUSE_2F", 1, 1, "down")
eq(townOverlay:townMapMarks(TOWN_STATE)[1].place, "PALLET TOWN",
   "a member indoors shows at the town the building is in")

-- ...and a map the town map has no square for leaves them off rather than
-- putting them at a guessed cell
townRoster:move("them", "SOME_MODDED_MAP", 1, 1, "down")
eq(#townOverlay:townMapMarks(TOWN_STATE), 0,
   "a map with no square on the town map places nobody")

-- a member in a battle or a menu has no cell at all, and so no city
townRoster:move("them", nil, nil, nil, "down")
eq(#townOverlay:townMapMarks(TOWN_STATE), 0,
   "and neither does a member who is not in the world right now")

-- you are never drawn: the screen already blinks your own location, and a
-- second marker on the same city reads as two people standing there
townRoster:move("them", "CERULEAN_CITY", 3, 4, "down")
local mine = townOverlay:townMapMarks(TOWN_STATE)
eq(#mine, 1, "back on the map once they are somewhere again")
eq(mine[1].id, "them", "and it is them, never you")

-- a screen with no coordinates at all (the list-mode fallback) has no cells
eq(#townOverlay:townMapMarks({ mode = "grid" }), 0,
   "a town map with no index places nobody")
eq(#townOverlay:townMapMarks(nil), 0, "and neither does no screen at all")

end)()

-- ------------------------------------------------------------------
-- 8. The typed line staying on a 160-wide screen
-- ------------------------------------------------------------------
--
-- Scoped like the sections around it: this file is at Lua's 200-local
-- ceiling for one function body, and the merge that brought parties in
-- added another branch's worth of names to the same chunk.

;(function()

--
-- NamingScreen lays its field out from a fixed x=56 for maxLen slots of
-- 8px, which was written for the vanilla seven-character name.  Every grid
-- this mod opens is longer, and at 32 -- an address -- the line ran to 312
-- on a 160-wide screen: "192.168.1.20:7788" typed in and the port gone off
-- the right edge, with no way to check it.  The whole point of the layout
-- below is that no length the mod uses can do that again, so the lengths
-- are read out of Config rather than written down here.

local Ui = need("Ui")

local function fits(maxLen, typed)
  local glyphs = {}
  for i = 1, #(typed or "") do glyphs[i] = typed:sub(i, i) end
  local x, cells = Ui.fieldLayout(maxLen, glyphs)
  return x, cells, x + #cells * 8
end

for _, case in ipairs({
  { "an address", 32 },
  { "a chat line", Config.COMPOSE_MAX },
  { "a join code", Config.CODE_ENTRY_MAX },
  { "a trainer name", Config.NAME_MAX },
}) do
  local label, maxLen = case[1], case[2]
  local x, cells, right = fits(maxLen)
  check(x >= 0 and right <= 160, label .. " draws inside the screen")
  eq(x, 160 - right, label .. " is centred, not pushed to one side")
  check(#cells > 0, label .. " shows something to type into")
end

-- The case the screenshot was taken of: the whole address, readable.
local addrX, addrCells = fits(32, "192.168.1.20:7788")
eq(table.concat(addrCells):sub(1, 17), "192.168.1.20:7788",
   "a full ip and port is on the line, port included")
check(addrX + #addrCells * 8 <= 160, "and still inside the right edge")

-- Longer than the window: the end is what is kept, because the characters
-- just entered are the ones being checked.
local _, longCells = fits(32, "averylonghostname.example.com:77")
eq(#longCells, 18, "the window is as many slots as fit between the margins")
eq(table.concat(longCells), "ame.example.com:77",
   "and holds the end of a line too long to show whole")

-- Short lines pad with dashes exactly as the vanilla field does.
local _, codeCells = fits(Config.CODE_ENTRY_MAX, "AB")
eq(#codeCells, Config.CODE_ENTRY_MAX, "a short field keeps all its slots")
eq(table.concat(codeCells), "AB" .. ("-"):rep(Config.CODE_ENTRY_MAX - 2),
   "with dashes standing in for what is not typed yet")

-- ------- and the leaderboard row, which is the same question
--
-- Four columns want eighteen glyphs and the row is eighteen glyphs, so
-- packing them left the portrait touching a name on one side and a place on
-- the other -- which is what the trainer card's own portrait did to the row
-- beneath it until it moved up four pixels. The name is the column that
-- pays for the gaps, and only when the score is wide enough to need it.
--
-- No wrapper of its own: the section this now sits inside is already a
-- function (the merge that brought parties in scoped it), so these locals
-- are released with it.
do
  -- read off the screen's own layout, so this cannot drift from what draws
  local L = Ui.RANK_LAYOUT
  check(L.artX >= L.posX + 16, "the portrait clears the place column")
  check(L.nameX >= L.artX + 16, "and the name clears the portrait")
  -- the digit boundaries, which is the only place the arithmetic changes --
  -- 1429 iterations of the same three cases would drown the suite's count
  -- without asserting anything the list below does not
  for _, points in ipairs({ 0, 1, 9, 10, 99, 100, 999, 1000, Config.RANK_MAX }) do
    local room = Ui.nameRoom(points)
    local nameRight = L.nameX + room * 8
    local scoreLeft = L.right - 8 * #tostring(points)
    check(nameRight <= scoreLeft,
          ("a name beside %d never reaches its score"):format(points))
    check(room >= 1, "and there is always at least one glyph of it to read")
  end

  eq(Ui.nameRoom(16) >= Config.NAME_MAX, true,
     "an ordinary rating leaves room for the longest name there is")
  eq(Ui.nameRoom(999) >= Config.NAME_MAX, true, "and so does a three-figure one")
  eq(Ui.nameRoom(0) >= Config.NAME_MAX, true, "and an unranked zero")
  check(Ui.nameRoom(Config.RANK_MAX) < Config.NAME_MAX,
        "only a four-figure rating trims a full-length name, by one glyph")
end

-- ------- and the roster row, where the trade runs the other way
--
-- ROSTER_LAYOUT is RANK_LAYOUT's mirror image: there the score is
-- fixed-width and the name pays for the gaps, here the name is what the
-- player reads the row by and never pays, so the place name spends
-- whatever `placeRoom` works out is left over.  Read off M.ROSTER_LAYOUT
-- and M.placeRoom themselves, for the same reason the RANK block above
-- reads off M.RANK_LAYOUT and M.nameRoom -- so this cannot drift from what
-- the screen actually draws with.
do
  local L = Ui.ROSTER_LAYOUT
  eq(L.labelX, 16, "the label starts where ListMenu starts one")
  eq(L.right, 152, "the right column ends where RANK's does")
  eq(L.gap, 8, "one glyph of air is kept between name and place")
  eq(L.min, 3, "below three glyphs a place name is not worth showing")

  -- room = max(floor((right - labelX - 8*#name - gap) / 8), 0) -- pinned
  -- against a hand-worked copy of the formula, not only the inequality it
  -- exists to satisfy, for every length a trainer name can actually be.
  for n = 1, Config.NAME_MAX do
    local name = ("A"):rep(n)
    local want = math.max(
      math.floor((L.right - L.labelX - 8 * n - L.gap) / 8), 0)
    local room = Ui.placeRoom(name)
    eq(room, want, ("placeRoom matches the formula at %d glyphs"):format(n))
    check(L.labelX + 8 * n + L.gap + 8 * room <= L.right,
          ("a place beside a %d-glyph name never reaches the right edge"):format(n))
  end

  eq(Ui.placeRoom(("A"):rep(Config.NAME_MAX)), 6,
     "a full-length name still leaves the PALLET of PALLET TOWN")
  check(Ui.placeRoom(("A"):rep(Config.NAME_MAX)) >= L.min,
        "and that is still enough of a place name to be worth showing")

  eq(Ui.placeRoom(("A"):rep(80)), 0,
     "an absurdly long name leaves nothing for a place -- clamped, not negative")

  -- ...and the friend mark, which is the one thing that ever made this row's
  -- label longer than the name in it.  The mark is three bytes of UTF-8 and
  -- one glyph on screen, so a byte count would quietly steal *two* characters
  -- from the place beside it instead of the one it actually costs.
  eq(#Ui.FRIEND_MARK, 3, "the mark is a multi-byte glyph")
  eq(Ui.FRIEND_MARK, "\226\150\183",
     "and it is the hollow arrow, spelled the way the e2e driver spells it "
     .. "when it asks the real charmap whether the font can draw it")
  eq(Ui.rosterLabel("ANN", false), "ANN", "an ordinary row is just the name")
  eq(Ui.rosterLabel("ANN", true), Ui.FRIEND_MARK .. "ANN",
     "and a friend's row carries the mark in front of it")
  eq(Ui.placeRoom(Ui.rosterLabel("ANN", true)), Ui.placeRoom("AANN"),
     "which costs the place name exactly one glyph, not three")

  -- The cost, stated rather than left to be discovered from a screenshot:
  -- the mark moves the trimming boundary by one name-length, and does not
  -- introduce trimming the row was not already doing.
  eq(Ui.placeRoom("HOSTY"), 11, "PALLET TOWN fits whole beside a 5-glyph name")
  eq(Ui.placeRoom("HOSTYY"), 10,
     "and is already one glyph short beside a 6-glyph one, with no mark in "
     .. "sight -- so a marked 5-glyph name is the row behaving as it always has")
  eq(Ui.placeRoom(Ui.rosterLabel("HOSTY", true)), Ui.placeRoom("HOSTYY"),
     "which is exactly what the mark costs: one name-length, no more")
  eq(Ui.placeRoom(Ui.rosterLabel(("A"):rep(Config.NAME_MAX), true)), 5,
     "and even the longest name plus a mark still leaves a readable place")
  check(Ui.placeRoom(Ui.rosterLabel(("A"):rep(Config.NAME_MAX), true)) >= L.min,
        "above the floor below which a place name is not worth showing")
end

-- ------- Places.name: what the player's own town map calls a map id
--
-- The resolver never ships a name of its own -- it reads whatever the
-- engine already decoded from the player's ROM into
-- game.data.field.townMap, tolerating both shapes src/ui/TownMap.lua does,
-- and falls back to the engine's own gsub (TownMap.lua's entryName) when
-- there is nothing to read.  Driven directly, through the same resolver
-- every other module in this file goes through.
do
  local Places = need("Places")

  local flatGame = { data = { field = { townMap = {
    PALLET_TOWN = { x = 5, y = 6, name = "PALLET TOWN" },
  } } } }
  eq(Places.name(flatGame, "PALLET_TOWN"), "PALLET TOWN",
     "a flat townMap resolves a name directly")

  local nestedGame = { data = { field = { townMap = { locations = {
    PALLET_TOWN = { name = "PALLET TOWN" },
  } } } } }
  eq(Places.name(nestedGame, "PALLET_TOWN"), "PALLET TOWN",
     "and so does the .locations shape the extractor can nest it under")

  local labelGame = { data = { field = { townMap = {
    CERULEAN_CITY = { label = "CERULEAN CITY" },
  } } } }
  eq(Places.name(labelGame, "CERULEAN_CITY"), "CERULEAN CITY",
     "an entry with only a .label reads too, like the engine's own reader")

  eq(Places.name(flatGame, "REDS_HOUSE_1F"), "REDS HOUSE 1F",
     "a miss falls back to the id with underscores turned to spaces")

  local emptyNameGame = { data = { field = { townMap = {
    VIRIDIAN_CITY = { name = "" },
  } } } }
  eq(Places.name(emptyNameGame, "VIRIDIAN_CITY"), "VIRIDIAN CITY",
     "an entry whose .name is the empty string is a miss too, not a blank row")

  eq(Places.name(flatGame, nil), nil,
     "no map id, no place -- nil, not a placeholder string")
  eq(Places.name(flatGame, ""), nil,
     "and an empty one is treated the same as none at all")

  -- Nothing here may raise: this runs once per roster row from inside a
  -- mod callback, and the doc comment on Places.lua is explicit that an
  -- unexpected shape is allowed to cost a nice name, never the screen.
  for _, case in ipairs({
    { "no game at all", nil },
    { "a game with no .data", {} },
    { "a .data that is not a table", { data = "junk" } },
    { "a .field that is not a table", { data = { field = "junk" } } },
    { "a .townMap that is not a table", { data = { field = { townMap = "junk" } } } },
    { "a .locations that is not a table",
      { data = { field = { townMap = { locations = "junk" } } } } },
  }) do
    local label, junkGame = case[1], case[2]
    local ok, result = pcall(Places.name, junkGame, "REDS_HOUSE_1F")
    check(ok, "Places.name does not raise on " .. label)
    if ok then
      eq(result, "REDS HOUSE 1F", "and still falls back to the gsub form on " .. label)
    end
  end
end

end)()

-- ------------------------------------------------------------------
-- 9. Settings the player changes in game
-- ------------------------------------------------------------------
--
-- Menu code calls these as client:setMaxPlayers(n) -- the colon form, which
-- passes the module table as the first argument. A setter that took the
-- value positionally would store `self` instead, and clampPlayers would
-- turn that into the default: the host's choice silently ignored, with no
-- error anywhere. Both spellings are pinned here for exactly that reason.

local Client = need("Client")

stubSave, stubOptions = {}, { maxplayers = 6, hub = "10.0.0.9:7788" }

eq(Client.maxPlayers(), 6, "with nothing saved, the option row is the default")
eq(Client.joinAddress(), "10.0.0.9:7788", "and likewise for the address")

eq(Client.setMaxPlayers(Client, 12), 12, "the colon form stores the value")
eq(Client.maxPlayers(), 12, "and it reads back")
eq(Client.setMaxPlayers(20), 20, "the dot form works too")
eq(Client.maxPlayers(), 20, "and reads back")

eq(Client.setMaxPlayers(Client, 999), Config.MAX_PLAYERS,
   "an out-of-range value is clamped, not stored")
eq(Client.setMaxPlayers(Client, 1), Config.MIN_PLAYERS, "at both ends")

eq(Client.setJoinAddress(Client, "192.168.1.7:7788"), "192.168.1.7:7788",
   "the colon form stores an address")
eq(Client.joinAddress(), "192.168.1.7:7788", "which then wins over the option")
eq(Client.setJoinAddress(Client, ""), nil, "an empty address is refused")
eq(Client.joinAddress(), "192.168.1.7:7788", "leaving the previous one intact")

-- ------- the port the player did not type
--
-- Net's own fallback is 7778 -- the pokeserver relay's -- so an address that
-- reaches the socket without a port dials a machine nobody is hosting on and
-- comes back "relay unreachable", which is the one error message that points
-- the player away from the thing that is actually wrong. Every one of these
-- is a way of not choosing a port, and every one of them has to end up on
-- DEFAULT_PORT. Written against the symbol, not the number, because
-- RBY_MMO_PORT moves it -- that is how two e2e runs host on one machine.
local PORT = Config.DEFAULT_PORT
local function ported(host) return ("%s:%d"):format(host, PORT) end

eq(Client.setJoinAddress(Client, "mybox"), ported("mybox"),
   "a bare hostname is completed with the default port")
eq(Client.joinAddress(), ported("mybox"), "and reads back that way")
eq(Client.setJoinAddress(Client, "192.168.1.20"), ported("192.168.1.20"),
   "so is a bare IP")
eq(Client.setJoinAddress(Client, "MYBOX.EXAMPLE.COM"), ported("MYBOX.EXAMPLE.COM"),
   "case is left alone -- the resolver does not care and the player does")

-- A colon with nothing behind it is not a port; it used to become
-- "mybox::7788", dialled at host "mybox:", which fails like a hub that is
-- down rather than like the typo it is.
eq(Client.setJoinAddress(Client, "mybox:"), ported("mybox"),
   "a colon with no digits behind it means no port was chosen")
eq(Client.setJoinAddress(Client, "mybox:abc"), ported("mybox"),
   "and neither is something that is not a number")
eq(Client.setJoinAddress(Client, "mybox:99999"), ported("mybox"),
   "nor a number no socket can bind")
eq(Client.setJoinAddress(Client, "mybox:0"), ported("mybox"), "at the other end too")

-- tonumber says yes to all three of these and Net's ":%d+" says no, so
-- reading the slot with tonumber alone would call the address complete and
-- then hand it to a parser that drops the port and dials 7778.
eq(Client.setJoinAddress(Client, "mybox:0x1E"), ported("mybox"), "hex is not a port")
eq(Client.setJoinAddress(Client, "mybox:1e3"), ported("mybox"), "nor is exponent notation")
eq(Client.setJoinAddress(Client, "mybox:+7788"), ported("mybox"), "nor a signed number")

-- Every space goes, wherever it is. The grid has a space glyph and no
-- address has any use for one, so a space is only ever something that was
-- easy to type -- and taking them all out is what keeps this string and the
-- codeKey the passcode is filed under identical.
eq(Client.setJoinAddress(Client, "  mybox  "), ported("mybox"),
   "spaces around an address are removed, not carried into the hostname")
eq(Client.setJoinAddress(Client, "my box . com"), ported("mybox.com"),
   "and so are spaces in the middle of one")

-- A port held off its colon by a space is still the port the player meant,
-- so it survives rather than reading as a port that was never given. Spelled
-- out rather than built from DEFAULT_PORT: the point is that 7788 here came
-- from what was typed, which is only visible if the two cannot coincide.
eq(Client.setJoinAddress(Client, "mybox: 7788"), "mybox:7788",
   "a typed port keeps its value across the space that was in front of it")
eq(Client.setJoinAddress(Client, " mybox : 1234 "), "mybox:1234",
   "and the spaces around a full address do not cost it its port either")

eq(Client.setJoinAddress(Client, ported("mybox")), ported("mybox"),
   "a port that was typed is stored exactly as typed")
eq(Client.setJoinAddress(Client, "mybox:1"), "mybox:1",
   "and a deliberately odd one is not second-guessed")

eq(Client.setJoinAddress(Client, ":7788"), nil,
   "an address with no host is refused -- there is nothing there to dial")
eq(Client.setJoinAddress(Client, "   "), nil, "and so is whitespace alone")
eq(Client.joinAddress(), "mybox:1", "neither of which disturbed what was stored")

-- The option row is a text field a player edits in the mod manager, so it
-- arrives with the same freedoms. Reads complete it too, not just writes.
stubSave.hub = nil
stubOptions.hub = "hub.example.com"
eq(Client.joinAddress(), ported("hub.example.com"),
   "an option row typed without a port is completed on the way out")
stubOptions.hub, stubSave.hub = "10.0.0.9:7788", "mybox:1"

eq(Client.isHosting(), false, "a fresh client is not hosting")

-- ------- the claim ticket, as the client keeps it
--
-- The hub's half of this is tested above; this is the client's, and it is
-- the half that has to survive the save file. A ticket filed under the wrong
-- key, or stored half-formed, does not fail loudly -- the player simply
-- stops being ranked one day, with nothing on screen to connect it to.

local TICKET_A = string.rep("c3", 16)
local TICKET_B = string.rep("d4", 16)

eq(Client.rankToken(Client, "hub.example.com:7788"), nil,
   "a hub never played on has no ticket")
eq(Client.setRankToken(Client, "hub.example.com:7788", TICKET_A), TICKET_A,
   "one the hub minted is stored")
eq(Client.rankToken(Client, "hub.example.com:7788"), TICKET_A,
   "and comes back for that hub")
eq(Client.rankToken(Client, "HUB.EXAMPLE.COM:7788"), TICKET_A,
   "however the address was capitalised -- one hub, one key")
eq(Client.rankToken(Client, "other.example.com:7788"), nil,
   "and never for a different one: a ticket is only worth anything to the "
   .. "hub that minted it")

eq(Client.setRankToken(Client, "other.example.com:7788", TICKET_B), TICKET_B,
   "a player on two hubs holds two")
eq(Client.rankToken(Client, "hub.example.com:7788"), TICKET_A,
   "and neither overwrites the other")

eq(Client.setRankToken(Client, "hub.example.com:7788", "not a token"), nil,
   "something that is not a ticket is refused")
eq(Client.rankToken(Client, "hub.example.com:7788"), TICKET_A,
   "leaving the real one where it was")
eq(Client.setRankToken(Client, "hub.example.com:7788", TICKET_A:sub(1, 8)), nil,
   "and so is a truncated one, which would fail every claim from then on")

-- Hosting has no address to file under, and still has a name to hold.
eq(Client.setRankToken(Client, nil, TICKET_B), TICKET_B,
   "a hosting copy stores its own ticket")
eq(Client.rankToken(Client, nil), TICKET_B, "under a key of its own")
eq(Client.rankToken(Client, "hub.example.com:7788"), TICKET_A,
   "which is not the one any dialled hub uses")

-- ------- the claim ticket's file store: love.filesystem, stubbed
--
-- D1 adds a file of the mod's own, in the LOVE save directory, that a save
-- reload cannot take away -- the section above is mod.save alone, which is
-- exactly what a headless suite already had. This is the other half.
--
-- Wrapped in a function purely for scope, like section 10 below: the chunk
-- above it is already close to Lua's 200-local ceiling for one function
-- body.
--
-- tests.modkit (required at the very top of this file) already installs a
-- global `love` stub with its own in-memory love.filesystem, shared by the
-- whole suite -- everything from here on assumes it is there. Each case
-- below swaps in a *private* filesystem of its own, isolated from that
-- shared one and from every other case, and always restores the ambient
-- stub afterward rather than nulling it out -- leaving `love` absent would
-- break every other section that follows (Stats.randomDVs reaches for
-- love.math.random with no guard, the way real game code does).
--
-- Client.lua's tokenStore and json() results are module-level caches loaded
-- once per chunk, so each case below asks resolver() for a fresh Client --
-- and `love` is swapped in *before* that require runs, per the same
-- instruction, though src/Client.lua's own filesystem() reads it lazily at
-- call time and would work either order.

;(function()

local ambientLove = _G.love

local function loveFilesystem(seed)
  local files = {}
  if type(seed) == "table" then
    for path, body in pairs(seed) do files[path] = body end
  end
  local fs = { files = files }
  -- Called as fs.read(path) / fs.write(path, data) -- plain functions, not
  -- methods, because that is how src/Client.lua's filesystem() calls them.
  function fs.read(path)
    local body = files[path]
    if body == nil then return nil, "could not open " .. tostring(path) end
    return body
  end
  function fs.write(path, data)
    files[path] = data
    return true
  end
  -- The real love.filesystem has one, and src/Client.lua uses it to tell "no
  -- file" from "a file that would not open" -- which read() alone answers
  -- with the same nil either way.
  function fs.getInfo(path)
    if files[path] == nil then return nil end
    return { type = "file", size = #files[path] }
  end
  return fs
end

-- The same encoder Client.lua reaches for (src.link.Json) -- a file of our
-- own here would be a second thing to keep in step with it.
local RealJson = require("src.link.Json")

-- A welcome's grant is written to the file, keyed by the address dialled and
-- the upper-cased trainer name -- not mod.save's key, which is address alone.
do
  stubSave = {}
  local fs = loveFilesystem()
  _G.love = { filesystem = fs }
  local fileClient = resolver()("Client")
  local granted = string.rep("e5", 16)
  eq(fileClient.setRankToken(fileClient, "hub.example.com:7788", granted, "ash"),
     granted, "the grant is stored")
  local body = fs.files[Config.RANK_TOKEN_FILE]
  check(type(body) == "string", "and the file was written")
  local decoded = RealJson.decode(body)
  eq(decoded["hub.example.com:7788|ASH"], granted,
     "under the address and the upper-cased name, however it was typed")
  _G.love = ambientLove
end

-- A ticket the file holds survives mod.save being wiped wholesale -- the
-- shape of a CONTINUE, which replaces the whole save table (Game.lua's
-- restoreSave), not just the one key this mod happened to write.
do
  stubSave = {}
  local fs = loveFilesystem()
  _G.love = { filesystem = fs }
  local fileClient = resolver()("Client")
  local granted = string.rep("f6", 16)
  fileClient.setRankToken(fileClient, "hub.example.com:7788", granted, "ash")
  stubSave = {}
  eq(fileClient.rankToken(fileClient, "hub.example.com:7788", "ash"), granted,
     "the file still answers, though mod.save was just wiped")
  _G.love = ambientLove
end

-- A different name on the same hub has no ticket of its own -- the file
-- keys by hub *and* name, where mod.save (checked below) keys by hub alone.
do
  stubSave = {}
  local fs = loveFilesystem({
    [Config.RANK_TOKEN_FILE] = RealJson.encode({
      ["hub.example.com:7788|ASH"] = string.rep("07", 16),
    }),
  })
  _G.love = { filesystem = fs }
  local fileClient = resolver()("Client")
  eq(fileClient.rankToken(fileClient, "hub.example.com:7788", "gary"), nil,
     "a different name on the same hub has no ticket of its own")
  _G.love = ambientLove
end

-- Neither does the same name on a different hub.
do
  stubSave = {}
  local fs = loveFilesystem({
    [Config.RANK_TOKEN_FILE] = RealJson.encode({
      ["hub.example.com:7788|ASH"] = string.rep("07", 16),
    }),
  })
  _G.love = { filesystem = fs }
  local fileClient = resolver()("Client")
  eq(fileClient.rankToken(fileClient, "other.example.com:7788", "ash"), nil,
     "and neither does the same name on a different hub")
  _G.love = ambientLove
end

-- A file that will not decode is warned about once and treated as empty --
-- never a lockout -- and the next grant overwrites it whole, repairing it.
do
  stubSave = {}
  local fs = loveFilesystem({ [Config.RANK_TOKEN_FILE] = "not json at all {" })
  _G.love = { filesystem = fs }
  local warns = {}
  stubMod.log.warn = function(_, fmt, ...)
    local ok, line = pcall(string.format, fmt, ...)
    warns[#warns + 1] = ok and line or tostring(fmt)
  end
  local fileClient = resolver()("Client")
  eq(fileClient.rankToken(fileClient, "hub.example.com:7788", "ash"), nil,
     "a file that will not decode is treated as empty")
  check(#warns > 0, "and the corruption is warned about")
  check(warns[1]:find(Config.RANK_TOKEN_FILE, 1, true) ~= nil,
     "naming the file, so a player who reads the log knows what to delete")

  local granted = string.rep("18", 16)
  eq(fileClient.setRankToken(fileClient, "hub.example.com:7788", granted, "ash"),
     granted, "the next grant still stores")
  local decoded = RealJson.decode(fs.files[Config.RANK_TOKEN_FILE])
  eq(decoded["hub.example.com:7788|ASH"], granted,
     "overwriting the file whole, which repairs it")

  stubMod.log.warn = function() end
  _G.love = ambientLove
end

-- A read that *fails* is not a file that is absent, and only one of the two
-- may be overwritten. Rewriting the whole table after a failed read would
-- hand back a file holding one key and throw away every other hub's ticket --
-- so nothing is written at all, and the file on disk is left exactly as it
-- was.
do
  stubSave = {}
  local other = string.rep("4b", 16)
  local seeded = RealJson.encode({ ["other.example.com:7788|GARY"] = other })
  local fs = loveFilesystem({ [Config.RANK_TOKEN_FILE] = seeded })
  -- The file is there -- getInfo still says so -- and will not open.
  fs.read = function() return nil, "permission denied" end
  _G.love = { filesystem = fs }
  local warns = {}
  stubMod.log.warn = function(_, fmt, ...)
    local ok, line = pcall(string.format, fmt, ...)
    warns[#warns + 1] = ok and line or tostring(fmt)
  end
  local fileClient = resolver()("Client")
  local granted = string.rep("5c", 16)
  eq(fileClient.setRankToken(fileClient, "hub.example.com:7788", granted, "ash"),
     granted, "the grant is still stored -- in mod.save, which never failed")
  eq(fs.files[Config.RANK_TOKEN_FILE], seeded,
     "and the file is untouched: the other hub's ticket is still in it")
  check(#warns > 0, "the failure is warned about")
  check(warns[1]:find(Config.RANK_TOKEN_FILE, 1, true) ~= nil,
        "naming the file, so a player who reads the log knows which one")
  eq(fileClient.rankToken(fileClient, "hub.example.com:7788", "ash"), granted,
     "and this session still answers with the ticket it was just handed")

  stubMod.log.warn = function() end
  _G.love = ambientLove
end

-- A write that fails leaves mod.save holding the newer ticket, so the older
-- one the file still has must not shadow it: a real SAVE and relaunch would
-- otherwise present the stale one and be told it is an impostor.
do
  stubSave = {}
  local stale = string.rep("6d", 16)
  local fs = loveFilesystem({
    [Config.RANK_TOKEN_FILE] = RealJson.encode({
      ["hub.example.com:7788|ASH"] = stale,
    }),
  })
  _G.love = { filesystem = fs }
  local fileClient = resolver()("Client")
  eq(fileClient.rankToken(fileClient, "hub.example.com:7788", "ash"), stale,
     "sanity: the file answers first while it is the only answer")

  fs.write = function() return false, "disk full" end
  stubMod.log.warn = function() end
  local granted = string.rep("7e", 16)
  eq(fileClient.setRankToken(fileClient, "hub.example.com:7788", granted, "ash"),
     granted, "the grant is stored in mod.save even though the file refused it")
  eq(fileClient.rankToken(fileClient, "hub.example.com:7788", "ash"), granted,
     "and it is what answers: a key the write did not land is dropped from "
     .. "this session rather than left in front of the newer one")
  _G.love = ambientLove
end

-- A ticket that predates the file store, living only in mod.save, is still
-- found -- back-compat with every ticket already issued before this fix.
do
  stubSave = {}
  local fs = loveFilesystem()
  _G.love = { filesystem = fs }
  local fileClient = resolver()("Client")
  local legacy = string.rep("29", 16)
  stubSave["rank:hub.example.com:7788"] = legacy
  eq(fileClient.rankToken(fileClient, "hub.example.com:7788", "ash"), legacy,
     "a ticket that predates the file store is still found, in mod.save")
  _G.love = ambientLove
end

-- With no love global at all -- any copy running outside LOVE -- behaviour
-- is identical to before this fix: mod.save only. (The suite itself always
-- has the ambient stub, per the header above; this case removes it on
-- purpose, for the one case that needs it gone, and puts it straight back.)
do
  stubSave = {}
  _G.love = nil
  local headlessClient = resolver()("Client")
  local token = string.rep("3a", 16)
  eq(headlessClient.setRankToken(headlessClient, "hub.example.com:7788", token, "ash"),
     token, "setRankToken still stores to mod.save with no love global")
  eq(headlessClient.rankToken(headlessClient, "hub.example.com:7788", "ash"), token,
     "and rankToken still reads it back -- exactly the old, save-only behaviour")
  eq(stubSave["rank:hub.example.com:7788"], token,
     "written to mod.save, and nowhere else to check")
  _G.love = ambientLove
end

end)()

-- ------------------------------------------------------------------
-- 9b. mmo.sprite from the client: push, reconcile, and the ack
-- ------------------------------------------------------------------
--
-- A fresh Client (resolver()("Client"), the same idiom the rank-token-file
-- tests just above use) rather than the one every other section in this
-- file shares: this needs install() -- the only way to reach the tick that
-- reconciles spriteAcked -- and running it on the shared instance would
-- wire its hooks and exports a second time on top of whatever a later
-- section still expects to find untouched.

;(function()

stubSave, stubOptions = {}, {}
stubSprites.SPRITE_RED = { walker = true }
stubSprites.SPRITE_BLUE = { walker = true }
stubSprites.SPRITE_YOUNGSTER = { walker = true }

local capturedTick
-- the harness's own events table records emits for the co-op sections that
-- run after this one, so it is put back afterwards rather than dropped
local origEvents = stubMod.events
stubMod.exports = {}
stubMod.events = { on = function() end }
stubMod.hooks = {
  wrap = function(_, name, fn)
    if name == "input.step" then capturedTick = fn end
  end,
}
stubMod.ui = { push = function() end, insertBefore = function(_, items) return items end }
stubMod.content.screens = { register = function() end, get = function() end }

local sprClient = resolver()("Client")
sprClient.install()
check(capturedTick ~= nil, "sanity: install() wrapped input.step, so there is a tick to drive")

local function fakeNet()
  local inbox = {}
  local net = { closed = false, outbox = {} }
  function net:send(msg) self.outbox[#self.outbox + 1] = msg end
  function net:update() end
  function net:poll()
    local out = inbox
    inbox = {}
    return out
  end
  function net:close() self.closed = true end
  function net:deliver(msg) inbox[#inbox + 1] = msg end
  return net
end

local function takeSprite(net)
  for i, msg in ipairs(net.outbox) do
    if msg.type == Wire.SPRITE then return table.remove(net.outbox, i) end
  end
  return nil
end

local function drive(dt)
  capturedTick(function() end, {}, dt)
end

-- ------- pushSprite sends only when the transport is ready

eq(sprClient.pushSprite(), false,
   "pushSprite before the transport has ever connected sends nothing")

local net = fakeNet()
sprClient.transport:attach(net)
eq(sprClient.pushSprite(), false,
   "and still nothing while attached but not yet welcomed")

sprClient.transport:markReady()
sprClient.ctx.roster:setSelf("me")

eq(sprClient.pushSprite(), true, "ready, pushSprite sends")
check(takeSprite(net) ~= nil, "and a message actually went out")
net.outbox = {}

-- ------- setSpriteChoice while connected sends exactly one message

eq(sprClient.setSpriteChoice("SPRITE_RED"), "SPRITE_RED",
   "setSpriteChoice while connected succeeds for a character this game can draw")
eq(#net.outbox, 1, "and sends exactly one message for it")
eq(net.outbox[1].type, Wire.SPRITE, "of the sprite type")
eq(net.outbox[1].sprite, sprClient.spriteChoice(),
   "carrying the resolved choice sent to the hub")
net.outbox = {}

-- ------- an inbound self echo is the ack

net:deliver({ type = Wire.SPRITE, id = "me", sprite = sprClient.spriteChoice() })
drive(0.016) -- one ordinary step: reads the echo, does not yet cross the retry window
net.outbox = {}
drive(Config.CHAT_GATE * 2 + 0.1) -- well past SPRITE_RETRY
eq(takeSprite(net), nil,
   "once the hub's own echo has acked the choice, the reconcile tick past "
   .. "SPRITE_RETRY sends nothing")

-- ------- a gate-dropped push is re-sent

eq(sprClient.setSpriteChoice("SPRITE_BLUE"), "SPRITE_BLUE",
   "choosing a different character")
local first = takeSprite(net)
check(first ~= nil, "sanity: the immediate push went out")
eq(first.sprite, "SPRITE_BLUE", "carrying the new choice")
net.outbox = {}

-- no echo delivered this time -- simulating a push the hub's own gate
-- (Hub.lua's SPRITE_GATE) refused in silence
drive(Config.CHAT_GATE * 2 + 0.1)
local second = takeSprite(net)
check(second ~= nil,
      "a push the hub never acked is re-sent once SPRITE_RETRY has passed")
eq(second.sprite, "SPRITE_BLUE", "the same choice, tried again")
net.outbox = {}

-- ack it, so the option-driven test below is caused only by the option --
-- not by BLUE still sitting unacknowledged
net:deliver({ type = Wire.SPRITE, id = "me", sprite = "SPRITE_BLUE" })
drive(0.016)
net.outbox = {}
drive(Config.CHAT_GATE * 2 + 0.1)
eq(takeSprite(net), nil, "sanity: BLUE is acked and the reconcile loop is quiet")

-- ------- an option-driven change is carried by the same reconcile loop
--
-- Nobody called setSpriteChoice here: the global MY SPRITE row in the mod
-- manager writes mod.options directly and calls nothing, so this is the
-- only thing that ever tells the hub about a change made there.

stubSave.sprite = ""
stubOptions.sprite = "SPRITE_YOUNGSTER"
drive(Config.CHAT_GATE * 2 + 0.1)
local optionPush = takeSprite(net)
check(optionPush ~= nil,
      "an option-driven change with nobody calling setSpriteChoice is still "
      .. "pushed, by the reconcile loop")
eq(optionPush.sprite, "SPRITE_YOUNGSTER", "carrying the option row's value")
net.outbox = {}

-- ack it too, so disconnect is the only thing that can explain what happens next
net:deliver({ type = Wire.SPRITE, id = "me", sprite = "SPRITE_YOUNGSTER" })
drive(0.016)
net.outbox = {}
drive(Config.CHAT_GATE * 2 + 0.1)
eq(takeSprite(net), nil, "sanity: YOUNGSTER acked too, quiet before the disconnect test")

-- ------- disconnect resets the ack state
--
-- spriteAcked is private, so this is observed the only way it can be from
-- out here: with the choice already acked and nothing left to reconcile,
-- reconnect *without* a hello (which would normally reseed it) and check
-- whether the loop still trusts the old hub's word or starts over.

sprClient.disconnect()
check(sprClient.transport:isOpen() == false, "sanity: disconnect closes the transport")

local net2 = fakeNet()
sprClient.transport:attach(net2)
sprClient.transport:markReady()
drive(Config.CHAT_GATE * 2 + 0.1)
check(takeSprite(net2) ~= nil,
      "disconnect resets the ack state -- a new session pushes the "
      .. "standing choice again rather than trusting a hub it already left")

stubMod.exports = nil
stubMod.events = origEvents
stubMod.hooks = nil
stubMod.ui = nil
stubMod.content.screens = nil
stubSprites.SPRITE_RED = nil
stubSprites.SPRITE_BLUE = nil
stubSprites.SPRITE_YOUNGSTER = nil

end)()

-- ------------------------------------------------------------------
-- 9c. mmo.sprite end to end, in hosting mode: pick -> hub -> other player
-- ------------------------------------------------------------------
--
-- The gap this closes. Every other case in this file drives one end of the
-- loop against a stand-in: 3c drives Hub with fake peers and no client, 9b
-- drives Client with a fake net and no hub. Both were green while the real
-- thing was not, because the seam neither of them crosses is the one a
-- hosting player actually uses -- Client's transport is HostServer:localNet,
-- whose send() runs Hub:receive *synchronously, inside the UI callback that
-- picked the character*, with the JSON round trip in the middle and no pcall
-- anywhere on the way. That is where a change made from the CHARACTER row
-- either reaches the other players or silently does not, and nothing headless
-- had ever run it.
--
-- So this is the whole path, with only the socket taken out: the real Client
-- in hosting mode, the real HostServer local peer, the real Hub, and a second
-- player attached to that hub the way section 3 attaches one. The assertion
-- is the one the end-to-end driver makes from the other side of the wire --
-- the other player is told, by id, which character this one is now wearing.

;(function()

stubSave, stubOptions = {}, {}

local capturedTick
-- the harness's own events table records emits for the co-op sections that
-- run after this one, so it is put back afterwards rather than dropped
local origEvents = stubMod.events
stubMod.exports = {}
stubMod.events = { on = function() end }
stubMod.hooks = {
  wrap = function(_, name, fn)
    if name == "input.step" then capturedTick = fn end
  end,
}
stubMod.ui = { push = function() end, insertBefore = function(_, items) return items end }
stubMod.content.screens = { register = function() end, get = function() end }

local hostClient = resolver()("Client")
hostClient.install()
check(capturedTick ~= nil, "sanity: install() wrapped input.step")
-- Cast.install() ran inside install() and wrote the mod's own characters into
-- the stub catalog, so this is the same id the picker offers and the same one
-- the end-to-end driver picks.
check(stubSprites.SPRITE_NIRE ~= nil,
      "sanity: the mod's own characters are in the catalog to be picked")
stubSprites.SPRITE_RED = { walker = true }

-- Hosting, wired exactly as Client.host() wires it. start() is skipped
-- because it opens a real port and plain luajit has no luasocket (section 4
-- says the same); accept/flush are the two members of update() that need one,
-- so they are stubbed and everything else -- the hub's clock, the local peer,
-- the reaper -- runs for real.
local hosted = hostClient.ctx.server
hosted.hub = Hub.new({ maxPlayers = 4 })
hosted.running = true
hosted.accept = function() end
hosted.flush = function() end

local localNet = hosted:localNet()
check(localNet ~= nil, "the host gets a local net to join its own game with")
hostClient.transport:attach(localNet)

-- The other player, on the same hub, holding an outbox instead of a socket
local friendPeer = fakePeer()
local friend = hosted.hub:accept(friendPeer)
hosted.hub:receive(friend, { type = Wire.HELLO, proto = Config.PROTOCOL,
                             name = "FRIEND", map = "PALLET", x = 1, y = 1,
                             facing = "down" })
check(take(friendPeer, Wire.WELCOME) ~= nil, "and is welcomed onto it")

local function drive(dt) capturedTick(function() end, {}, dt or 0.016) end

stubSave.name = "HOSTY"
hostClient.sendHello({ save = { name = "HOSTY" } })
drive()
check(hostClient.transport:isReady(),
      "the host is welcomed by its own hub and reaches the ready state")
local hostId = hostClient.ctx.roster.selfId
check(hostId ~= nil, "and knows the id the hub gave it")

-- past the gate the hello left behind, and with the friend's outbox clean, so
-- what arrives below can only have been caused by the pick
hosted.hub:update(Config.CHAT_GATE * 4)
drive()
friendPeer.outbox = {}

-- ------- the pick, through the same call the CHARACTER row makes

eq(hostClient.setSpriteChoice("SPRITE_NIRE"), "SPRITE_NIRE",
   "the host picks a character mid-session, the way the CHARACTER row does")
eq(hostClient.spriteChoice(), "SPRITE_NIRE", "and is wearing it locally")

local told = take(friendPeer, Wire.SPRITE)
check(told ~= nil,
      "picking a character while hosting reaches the other player in the "
      .. "game -- the whole loop, from the UI call to a peer's outbox")
eq(told.id, hostId, "naming the host by the id that player already knows them by")
eq(told.sprite, "SPRITE_NIRE", "and the character just picked")
eq(hosted.hub.clients[hostId].sprite, "SPRITE_NIRE",
   "and the hub is holding it, so a player who joins later is told by the "
   .. "ordinary presence stream")

-- ------- and the host's own echo settles the reconcile loop
--
-- The other half of the same round trip: the broadcast has no exception, so
-- the host hears its own change back, and that copy is the acknowledgement.
-- Without it the tick would re-push forever against a hub already holding the
-- answer.
drive()
friendPeer.outbox = {}
drive(Config.CHAT_GATE * 2 + 0.1)
eq(take(friendPeer, Wire.SPRITE), nil,
   "the hub's own echo acks it, so the reconcile tick goes quiet rather than "
   .. "re-pushing a character the hub already has")

localNet:close()
hosted.running = false
hosted.hub = nil

stubMod.exports = nil
stubMod.events = origEvents
stubMod.hooks = nil
stubMod.ui = nil
stubMod.content.screens = nil
stubSprites.SPRITE_RED = nil

end)()

-- ------------------------------------------------------------------
-- 10. Trading, and the one invariant that matters
-- ------------------------------------------------------------------
--
-- Either both sides of a trade apply it or neither does.  Nothing else in
-- this suite is worth as much: the failure mode is silent, permanent, and
-- costs a player a Pokemon.
--
-- It is driven end to end -- two Sessions instances, the real Hub between
-- them, and the engine's own Protocol.TradeSession doing the trading -- so
-- the thing under test is the message ordering a real pair of clients sees.
-- pump() is deliberately shaped like src/Client.lua's tick: every message
-- the hub queued is dispatched first, and only then does the session get
-- its update.  That gap is where the duplication bug lived, so a harness
-- that collapsed the two would not be able to see it.
--
-- Wrapped in a function purely for scope: the chunk above it is already
-- close to Lua's 200-local ceiling for one function body.

;(function()

local Sessions = need("Sessions")
local Data = T.fixtures.load()
local Pokemon = require("src.pokemon.Pokemon")

local warns = {}
local function clearWarns()
  for i = #warns, 1, -1 do warns[i] = nil end
end
stubMod.log.warn = function(_, fmt, ...)
  local ok, line = pcall(string.format, fmt, ...)
  warns[#warns + 1] = ok and line or tostring(fmt)
end

local function tradeSide(hub, name, species)
  local side = { name = name, said = {} }
  side.peer = fakePeer()
  side.client = hub:accept(side.peer)
  side.transport = {
    send = function(_, msgType, payload)
      local msg = {}
      if type(payload) == "table" then
        for k, v in pairs(payload) do msg[k] = v end
      end
      msg.type = msgType
      hub:receive(side.client, msg)
      return true
    end,
    isReady = function() return true end,
  }
  side.ui = {
    say = function(_, text) side.said[#side.said + 1] = text end,
    confirm = function(_, _, text, cb)
      side.confirmText = text
      side.confirmBox = cb
      return { kind = "confirm" }
    end,
    choose = function(_, _, text, items)
      side.chooseText = text
      side.chosen = items
      return { kind = "choose" }
    end,
    pickPartyMon = function(_, _, _, cb) side.pickBox = cb end,
    pushState = function() end,
    ctx = {},
  }
  side.sessions = Sessions.new(side.transport, side.ui)
  side.game = {
    data = Data,
    save = {
      party = { Pokemon.new(Data, species, 12) },
      player = { name = name },
      pokedex = { seen = {}, owned = {} },
    },
  }
  hub:receive(side.client, { type = Wire.HELLO, proto = Config.PROTOCOL,
                             name = name, map = "FIX_TOWN", x = 1, y = 1 })
  return side
end

local sessionDispatch = {
  [Wire.SESSION] = function(s, m) s.sessions:onSession(s.game, m) end,
  [Wire.RELAY] = function(s, m) s.sessions:onRelay(m) end,
  [Wire.SESSION_END] = function(s, m) s.sessions:onSessionEnd(m.reason) end,
  [Wire.REQUEST] = function(s, m) s.sessions:onRequest(s.game, m) end,
  [Wire.DECLINE] = function(s, m) s.sessions:onDecline(m) end,
  [Wire.REQUEST_CANCEL] = function(s, m) s.sessions:onCancel(m) end,
}

local function pump(side, dt)
  local batch = side.peer.outbox
  side.peer.outbox = {}
  for _, msg in ipairs(batch) do
    local handler = sessionDispatch[msg.type]
    if handler then handler(side, msg) end
  end
  side.sessions:update(side.game, dt or 0)
end

local function partyOf(side)
  local names = {}
  for _, mon in ipairs(side.game.save.party) do names[#names + 1] = mon.species end
  return table.concat(names, ",")
end

local function answerPick(side, index)
  local box = side.pickBox
  side.pickBox = nil
  box(index)
end

local function answerConfirm(side, yes)
  local box = side.confirmBox
  side.confirmBox = nil
  box(yes)
end

-- Two players, paired through the hub, driven as far as both confirm boxes
-- being open -- which is the fork every ordering below takes from.
local function pairAtConfirm()
  -- the hub counts its own refusals, so a scenario can say out loud whether
  -- a message died on the way through it or after it arrived
  local hub = Hub.new({ maxPlayers = 2 })
  hub.dropped = 0
  hub.onDrop = function() hub.dropped = hub.dropped + 1 end
  local a = tradeSide(hub, "ANN", "FIXMON_B")
  local b = tradeSide(hub, "BOB", "FIXMON_C")

  a.sessions:request({ id = b.client.id, name = "BOB" }, "trade")
  pump(b)                     -- the ask lands, and BOB says yes
  answerConfirm(b, true)
  pump(a); pump(b)            -- paired: both send hello
  pump(a); pump(b)            -- hello in, party out
  pump(a); pump(b)            -- party in, both picking
  answerPick(a, 1); answerPick(b, 1)
  pump(a); pump(b)            -- picks crossed, both confirming
  return hub, a, b
end

local hubX, ann, bob = pairAtConfirm()
check(ann.confirmBox ~= nil and bob.confirmBox ~= nil,
      "both sides reach the confirm box")
eq(partyOf(ann), "FIXMON_B", "ANN starts with her own POKéMON and nothing else")
eq(partyOf(bob), "FIXMON_C", "and BOB with his")

-- ------- the box does not ask twice
--
-- The machine sits in "confirming" from the moment this side answers until
-- the peer's answer arrives, so a prompt driven off the stage alone re-opened
-- the instant the player closed it -- asking them to agree to the same trade
-- again, and putting a second confirm on the wire each time.

answerConfirm(ann, true)
pump(ann); pump(ann)
eq(ann.confirmBox, nil, "answering the confirm box does not re-open it")

-- ------- local-first: this side completes before the peer does

pump(bob)                     -- BOB sees ANN's confirm; his box is still open
answerConfirm(bob, true)      -- ...and now he completes first
pump(bob)
pump(ann)
pump(bob)
pump(ann)

eq(partyOf(ann), "FIXMON_C", "peer-completes-first: ANN ends up with BOB's POKéMON")
eq(partyOf(bob), "FIXMON_B", "and BOB with ANN's")
eq(#ann.game.save.party, 1, "ANN's party did not grow")
eq(#bob.game.save.party, 1, "nor did BOB's")
eq(ann.sessions.active, nil, "and the session is closed on ANN's side")
eq(bob.sessions.active, nil, "and on BOB's")

-- ------- the other ordering, which used to decide who lost a POKéMON

local hubY, ann2, bob2 = pairAtConfirm()
answerConfirm(bob2, true)
pump(ann2)
answerConfirm(ann2, true)     -- ANN completes first this time
pump(ann2)

-- The rule the whole fix rests on: finishing locally is not what ends a
-- session.  ANN has applied, and BOB's confirm is still in flight to nobody
-- -- if she hung up here the hub would tell BOB "peer_left" and the message
-- he needs would go down with the session.
eq(partyOf(ann2), "FIXMON_C", "ANN has applied her half")
check(ann2.sessions.active ~= nil,
      "but the session outlives local completion rather than ending on it")
eq(ann2.sessions.active.stage, "settling",
   "waiting on the peer to say it applied too")

pump(bob2)
pump(ann2)
pump(bob2)

eq(hubY.dropped, 0, "and the hub refused nothing along the way")
eq(partyOf(ann2), "FIXMON_C", "local-completes-first: ANN still ends up with BOB's")
eq(partyOf(bob2), "FIXMON_B", "and BOB with ANN's")
eq(ann2.sessions.active, nil, "with the session closed on ANN's side")
eq(bob2.sessions.active, nil, "and on BOB's")

-- ------- the regression: peer_left arriving with a confirm still unread
--
-- The failure this whole section exists for.  BOB finishes, applies, and his
-- process goes away in the same breath; the hub forwards his confirm and
-- then tells ANN "peer_left", and both land in one batch.  Dropping the
-- session on peer_left threw away the confirm that was already sitting in
-- its inbox, so ANN never applied: two of BOB's POKéMON in the world and
-- none of ANN's.  Nothing errored, which is the whole signature.

local hubZ, ann3, bob3 = pairAtConfirm()
answerConfirm(ann3, true)     -- ANN's confirm goes on the wire
pump(bob3)
answerConfirm(bob3, true)
pump(bob3)                    -- BOB applies his half
eq(partyOf(bob3), "FIXMON_B", "BOB applied his half before leaving")

hubZ:receive(bob3.client, { type = Wire.SESSION_LEAVE })
pump(ann3)                    -- confirm, then peer_left, in one batch

eq(partyOf(ann3), "FIXMON_C",
   "a peer that leaves in the same batch as its confirm does not strand us")
eq(partyOf(bob3), "FIXMON_B", "and BOB is left holding exactly one POKéMON")
eq(#ann3.game.save.party, 1, "ANN holds exactly one too")
eq(ann3.sessions.active, nil, "and the session is finished, not left hanging")

-- neither FIXMON exists twice across the two parties, which is the invariant
-- stated as the thing it actually protects
local census = {}
for _, side in ipairs({ ann3, bob3 }) do
  for _, mon in ipairs(side.game.save.party) do
    census[mon.species] = (census[mon.species] or 0) + 1
  end
end
eq(census.FIXMON_B, 1, "exactly one of the POKéMON ANN put up")
eq(census.FIXMON_C, 1, "and exactly one of BOB's -- neither duplicated nor lost")
eq(hubZ.dropped, 0,
   "and the hub refused nothing -- the message that used to vanish was "
   .. "relayed fine and died a layer further in, which is why nobody saw it")

-- ------- a peer that never acknowledges does not pin the session open
--
-- An older build of this mod, or one whose acknowledgement is lost with the
-- connection, simply never sends it.  Both halves are applied by then, so
-- the settling clock is a courtesy rather than a commitment.

local _, ann7, bob7 = pairAtConfirm()
answerConfirm(bob7, true)
pump(ann7)
answerConfirm(ann7, true)
pump(ann7)
eq(ann7.sessions.active.stage, "settling", "ANN is settling")
bob7.peer.outbox = {}         -- BOB's half of the world goes quiet
pump(ann7, 11)
eq(ann7.sessions.active, nil, "an acknowledgement that never comes still ends it")
eq(partyOf(ann7), "FIXMON_C", "with the applied trade left exactly as it was")

-- ------- the timeout fails closed
--
-- ANN answers, BOB never does.  What must not happen is ANN keeping a copy
-- of both: a trade that times out is a trade that did not happen, on both
-- sides.

local _, ann4, bob4 = pairAtConfirm()
answerConfirm(ann4, true)
pump(ann4, 30)
check(ann4.sessions.active ~= nil, "a wait shorter than the timeout is still live")
pump(ann4, 31)

eq(ann4.sessions.active, nil, "silence past the timeout ends the session")
eq(partyOf(ann4), "FIXMON_B", "and leaves ANN's party exactly as it started")
eq(#ann4.game.save.party, 1, "with nothing gained")
local timedOut = false
for _, line in ipairs(ann4.said) do
  if line:find("never answered") then timedOut = true end
end
check(timedOut, "with something on screen saying why")

pump(bob4)
eq(partyOf(bob4), "FIXMON_C", "and BOB's party exactly as it started too")
eq(bob4.sessions.active, nil, "his session ends on the goodbye rather than hanging")

-- ------- the second silent drop, given a voice
--
-- onRelay used to swallow a refused payload without a word, which is how the
-- duplication above stayed invisible: src/Hub.lua counted zero drops because
-- the message was relayed fine and died one layer further in.

local _, ann5, bob5 = pairAtConfirm()
clearWarns()
ann5.sessions:onRelay({ from = "999999", payload = { type = "confirm" } })
eq(#warns, 1, "a relay from someone who is not the peer is logged, not swallowed")
check(warns[1]:find("MMO"), "and the warning names somewhere to go from")

ann5.sessions:onRelay({ from = bob5.client.id, payload = "not a table" })
ann5.sessions:onRelay({ from = "999999", payload = {} })
eq(#warns, 1, "further drops in the same session stay quiet -- one line, not a flood")

-- ...and the count starts again with the next session, so a later trade that
-- goes wrong is not silenced by an earlier one that did
local _, ann6 = pairAtConfirm()
clearWarns()
ann6.sessions:onRelay({ from = "999999", payload = {} })
eq(#warns, 1, "a fresh session gets its own warning")

-- a relay arriving with no session at all is the same story
clearWarns()
local orphan = Sessions.new(ann6.transport, ann6.ui)
orphan:onRelay({ from = "1", payload = {} })
orphan:onRelay({ from = "1", payload = {} })
eq(#warns, 1, "a relay with no session open is logged exactly once")

stubMod.log.warn = function() end

-- ------- a ranked battle's paperwork survives the session it belonged to
--
-- The result is reported after the battle ends, which is after either side
-- may have torn the session down -- so Sessions keeps the hub's session id
-- and the state it handed the engine, and answers exactly once.

local _, ann8, bob8 = pairAtConfirm()
local liveId = ann8.sessions.active and ann8.sessions.active.id
check(liveId ~= nil, "a session carries the hub's id for it")
eq(liveId, bob8.sessions.active.id, "and both sides file under the same one")

-- what beginBattle records when it hands a battle to the engine
local fought = { kind = "link" }
ann8.sessions.lastBattle =
  { id = liveId, peerId = bob8.client.id, peerName = "BOB", state = fought }

eq(ann8.sessions:claimBattle({ kind = "wild" }), nil,
   "a different battle -- a wild encounter, a cable-club link -- claims nothing")
local claimed = ann8.sessions:claimBattle(fought)
check(claimed ~= nil, "the battle this mod handed over is claimed")
eq(claimed.id, liveId, "under the session it was fought in")
eq(ann8.sessions:claimBattle(fought), nil,
   "and only once, so a result cannot be reported twice")

-- ------- battle invite: waiting, refuse, cancel
--
-- The ask used to leave a one-line "Asked X to battle." that dismissed on A
-- while keeping the player busy with nothing on screen.  Waiting holds the
-- screen, B opens a cancel confirm, a refuse names who said no, and a cancel
-- tells the other side the invite is gone.

local function said(side, needle)
  for _, line in ipairs(side.said) do
    if line:find(needle, 1, true) then return true end
  end
  return false
end

local function pressCancel(side)
  local items = side.chosen
  check(items ~= nil and items[1] and items[1].onSelect,
        "the waiting box has a CANCEL row")
  -- Chosen stays: a No on the confirm drops back onto the same waiting box
  -- (it is still underneath), so the next B has to find the same row.
  items[1].onSelect()
end

local battleHub = Hub.new({ maxPlayers = 4 })
local asker = tradeSide(battleHub, "ASH", "FIXMON_B")
local target = tradeSide(battleHub, "GARY", "FIXMON_C")

asker.sessions:request({ id = target.client.id, name = "GARY" }, "battle")
eq(asker.sessions.outgoing ~= nil, true, "a battle ask is held as outgoing")
check(asker.chooseText and asker.chooseText:find("GARY", 1, true),
      "and the asker sees Waiting for GARY...")
eq(asker.sessions:isBusy(), true, "so they cannot ask anybody else")

pump(target)
check(target.confirmBox ~= nil, "GARY is asked to battle")
check(target.confirmText and target.confirmText:find("battle", 1, true),
      "naming a battle, not a trade")

-- Refuse: waiting comes down, and the sentence names the refusal.
answerConfirm(target, false)
pump(asker)
eq(asker.sessions.outgoing, nil, "a refuse clears the ask")
eq(asker.sessions:isBusy(), false, "and frees the asker")
check(said(asker, "refused"), "with 'GARY refused to battle'")
check(said(asker, "GARY"), "naming who refused")

-- Cancel from the asker's side: GARY's prompt comes down with a sentence.
asker.said = {}
target.said = {}
asker.sessions:request({ id = target.client.id, name = "GARY" }, "battle")
pump(target)
check(target.confirmBox ~= nil, "GARY is asked again")
eq(battleHub.clients[asker.client.id].pendingTo, target.client.id,
   "the hub holds the outstanding ask")

pressCancel(asker)
check(asker.confirmBox ~= nil, "B/CANCEL opens a yes/no confirm")
-- No keeps waiting: confirm callback returns without cancelling.
asker.confirmBox(false)
eq(asker.sessions.outgoing ~= nil, true, "answering No leaves the ask outstanding")
eq(battleHub.clients[asker.client.id].pendingTo, target.client.id,
   "and the hub still holds it")

pressCancel(asker)
asker.confirmBox(true)
pump(target)
eq(asker.sessions.outgoing, nil, "Yes cancels the ask")
eq(asker.sessions:isBusy(), false, "and frees the asker")
eq(battleHub.clients[asker.client.id].pendingTo, nil,
   "the hub drops pendingTo")
eq(target.sessions.incoming, nil, "GARY's incoming is cleared")
check(said(target, "cancelled"), "and GARY is told the invite was cancelled")
check(said(target, "ASH"), "naming who cancelled")

-- A yes after cancel must not open a session.
target.confirmBox = nil
asker.sessions:request({ id = target.client.id, name = "GARY" }, "battle")
pump(target)
asker.sessions:cancelRequest()
pump(target)
-- stale confirm from before cancel, if the harness still held the cb
if target.confirmBox then answerConfirm(target, true) end
pump(asker); pump(target)
eq(asker.sessions.active, nil, "accepting a cancelled ask starts no session")
eq(target.sessions.active, nil, "on either side")

-- Peer gone while waiting: same lock Party fixed for invites.
asker.said = {}
asker.sessions:request({ id = target.client.id, name = "GARY" }, "battle")
eq(asker.sessions.outgoing ~= nil, true, "waiting again")
asker.sessions:onPeerGone(target.client.id)
eq(asker.sessions.outgoing, nil, "a peer going offline clears the ask")
check(said(asker, "offline"), "and says so on screen")

-- ------- invites during a live fight are refused, not shown
--
-- isBusy only covered trade/PVP sessions. A wild encounter, a trainer
-- battle, a link battle on the stack, or a co-op screen used to leave the
-- confirm free to open on top of the fight.

eq(Sessions.isFightState({ kind = "wild" }), true, "a wild battle is a fight")
eq(Sessions.isFightState({ kind = "trainer" }), true, "a trainer battle is")
eq(Sessions.isFightState({ kind = "link" }), true, "a link battle is")
eq(Sessions.isFightState({ sim = {} }), true, "a co-op screen (has sim) is")
eq(Sessions.isFightState({ kind = "menu" }), false, "a menu is not")
eq(Sessions.isFightState(nil), false, "and neither is nothing")

local fighting = tradeSide(battleHub, "MISTY", "FIXMON_B")
local challenger = tradeSide(battleHub, "SURGE", "FIXMON_C")
fighting.game.stack = {
  states = { { kind = "overworld" }, { kind = "wild" } },
  top = function(self) return self.states[#self.states] end,
}
eq(Sessions.stackHasFight(fighting.game), true,
   "a wild battle anywhere on the stack counts")
eq(fighting.sessions:inFight(fighting.game), true, "so inFight sees it")

challenger.sessions:request({ id = fighting.client.id, name = "MISTY" }, "battle")
pump(fighting)
eq(fighting.confirmBox, nil, "no invite prompt opens over the wild battle")
eq(fighting.sessions.incoming, nil, "and nothing is held as incoming")
pump(challenger)
eq(challenger.sessions.outgoing, nil, "the asker is told no")
check(said(challenger, "refused") or said(challenger, "MISTY"),
      "with a refusal naming MISTY")

-- Buried under a menu: still a fight.
fighting.game.stack.states = {
  { kind = "trainer" }, { kind = "menu" },
}
challenger.said = {}
challenger.sessions:request({ id = fighting.client.id, name = "MISTY" }, "battle")
pump(fighting); pump(challenger)
eq(fighting.confirmBox, nil, "a menu over a trainer battle still auto-refuses")

-- Co-op running, no screen yet (handoff): fighting callback.
fighting.game.stack = { states = {}, top = function() return nil end }
fighting.sessions.fighting = function() return true end
challenger.said = {}
challenger.sessions:request({ id = fighting.client.id, name = "MISTY" }, "battle")
pump(fighting); pump(challenger)
eq(fighting.confirmBox, nil, "a co-op handoff without a screen still refuses")

-- ------- battle compat: name the mods, allow vanilla-link mismatches
--
-- The engine refuses any fingerprint mismatch.  Over the hub we only refuse
-- when a side has touched the lockstep surface (linkModified), and the
-- refusal has to name the mods that differ so players know what to turn off.

local function fakeModDiff(a, b)
  local function index(mods)
    local byId = {}
    for _, mod in ipairs(mods or {}) do byId[tostring(mod.id)] = mod end
    return byId
  end
  local mine, theirs = index(a and a.mods), index(b and b.mods)
  local onlyMine, onlyTheirs, differing = {}, {}, {}
  for id, mod in pairs(mine) do
    local peer = theirs[id]
    if not peer then onlyMine[#onlyMine + 1] = mod
    elseif tostring(peer.version) ~= tostring(mod.version) then
      differing[#differing + 1] = { id = id, mine = mod.version,
                                    theirs = peer.version }
    end
  end
  for id, mod in pairs(theirs) do
    if not mine[id] then onlyTheirs[#onlyTheirs + 1] = mod end
  end
  return { onlyMine = onlyMine, onlyTheirs = onlyTheirs, differing = differing }
end

local fakeHandshake = {
  battleAllowed = function(verdict)
    return verdict == "full" or verdict == "vanilla_peer" or verdict == nil
  end,
  modDiff = fakeModDiff,
  describe = function(a, b, verdict, mode)
    local peer = (b and b.name) or "THEY"
    local diff = fakeModDiff(a, b)
    local lines = { "Your games differ." }
    if #diff.onlyTheirs > 0 then
      lines[#lines + 1] = peer .. " has:"
      for _, mod in ipairs(diff.onlyTheirs) do
        lines[#lines + 1] = (" %s %s"):format(tostring(mod.id):upper(),
                                              tostring(mod.version or "?"))
      end
    end
    if #diff.onlyMine > 0 then
      lines[#lines + 1] = "You have:"
      for _, mod in ipairs(diff.onlyMine) do
        lines[#lines + 1] = (" %s %s"):format(tostring(mod.id):upper(),
                                              tostring(mod.version or "?"))
      end
    end
    for _, row in ipairs(diff.differing) do
      lines[#lines + 1] = ("%s %s vs %s"):format(tostring(row.id):upper(),
                                                 tostring(row.mine),
                                                 tostring(row.theirs))
    end
    if mode == "battle" then
      lines[#lines + 1] = "Link battle needs"
      lines[#lines + 1] = "the same mods."
    end
    return lines
  end,
}

local vanillaA = { name = "ASH", fingerprint = "aaa", linkModified = false,
                   mods = { { id = "rby_mmo", version = "0.11.0", affectsLink = false } } }
local vanillaB = { name = "GARY", fingerprint = "bbb", linkModified = false,
                   mods = { { id = "rby_mmo", version = "0.11.0", affectsLink = false } } }
eq(Sessions.canBattle("full", vanillaA, vanillaB, fakeHandshake), true,
   "identical fingerprints still battle")
eq(Sessions.canBattle("subset", vanillaA, vanillaB, fakeHandshake), true,
   "Red-vs-Blue style mismatch is allowed when neither side touched link rules")
eq(Sessions.canBattle("refused", vanillaA, vanillaB, fakeHandshake), false,
   "an engine mismatch is still refused")

local modded = { name = "GARY", fingerprint = "ccc", linkModified = true,
                 mods = {
                   { id = "rby_mmo", version = "0.11.0", affectsLink = false },
                   { id = "stat_tweaks", version = "1.2.0", affectsLink = true },
                 } }
eq(Sessions.canBattle("subset", vanillaA, modded, fakeHandshake), false,
   "a link-affecting mod on one side still blocks the fight")

local block = Sessions.battleBlockMessage(vanillaA, modded, "subset", fakeHandshake)
check(block:find("STAT_TWEAKS", 1, true) or block:find("stat_tweaks", 1, true),
      "the refusal names the mod only they have")
check(block:find("GARY", 1, true), "and whose game has it")

local stealth = { name = "GARY", fingerprint = "ddd", linkModified = true,
                  mods = { { id = "rby_mmo", version = "0.11.0", affectsLink = false } } }
local stealthMsg = Sessions.battleBlockMessage(vanillaA, stealth, "subset", fakeHandshake)
check(stealthMsg:find("battle rules", 1, true),
      "same mod list but linkModified still explains the block")

end)()

-- ------------------------------------------------------------------
-- 11. Parties, both sides of the invite
-- ------------------------------------------------------------------
--
-- Driven the way the trade scenario above is: two real Party instances with
-- the real Hub between them, and a pump() shaped like src/Client.lua's tick
-- -- dispatch everything the hub queued, then let the client act.  Half of
-- what a party has to get right is about *two* clients agreeing (an invite
-- one of them can no longer accept, a leave the other has to hear), and a
-- single instance asserted against a fake hub cannot see any of it.

;(function()

local Party = need("Party")

local function partySide(hub, name)
  local side = { name = name, said = {}, chat = Chat.new() }
  side.peer = fakePeer()
  side.client = hub:accept(side.peer)
  side.transport = {
    send = function(_, msgType, payload)
      local msg = {}
      if type(payload) == "table" then
        for k, v in pairs(payload) do msg[k] = v end
      end
      msg.type = msgType
      hub:receive(side.client, msg)
      return true
    end,
    isReady = function() return true end,
  }
  side.ui = {
    say = function(_, text) side.said[#side.said + 1] = text end,
    confirm = function(_, _, text, cb) side.confirmText = text; side.confirmBox = cb end,
  }
  side.party = Party.new(side.transport, side.ui, side.chat)
  hub:receive(side.client, { type = Wire.HELLO, proto = Config.PROTOCOL,
                             name = name, map = "FIX_TOWN", x = 1, y = 1 })
  local welcome = take(side.peer, Wire.WELCOME)
  side.party:setSelf(welcome and welcome.id)
  return side
end

local partyDispatch = {
  [Wire.PARTY_INVITE] = function(s, m) s.party:onInvite({}, m) end,
  [Wire.PARTY_DECLINE] = function(s, m) s.party:onDecline(m) end,
  [Wire.PARTY] = function(s, m) s.party:onParty(m) end,
  [Wire.PARTY_END] = function(s, m) s.party:onEnd(m) end,
}

local function pumpParty(side)
  local batch = side.peer.outbox
  side.peer.outbox = {}
  for _, msg in ipairs(batch) do
    local handler = partyDispatch[msg.type]
    if handler then handler(side, msg) end
  end
end

local function answer(side, yes)
  local box = side.confirmBox
  side.confirmBox = nil
  box(yes)
end

local function saidSomething(side, needle)
  for _, line in ipairs(side.said) do
    if line:find(needle, 1, true) then return true end
  end
  return false
end

local hub = Hub.new({ maxPlayers = 4 })
local ann = partySide(hub, "ANN")
local bob = partySide(hub, "BOB")
local cal = partySide(hub, "CAL")

eq(ann.party:has(), false, "nobody starts in a party")
eq(#ann.party:list(), 0, "with nothing to list")

-- ------- the invite, accepted

ann.party:invite({ id = bob.client.id, name = "BOB" })
check(saidSomething(ann, "Asked BOB"), "the asker is told the invite went out")
pumpParty(bob)
check(bob.confirmBox ~= nil, "and the invited player is asked")
check(bob.confirmText:find("ANN"), "by name")

answer(bob, true)
pumpParty(ann); pumpParty(bob)
eq(ann.party:has(), true, "accepting puts the asker in a party")
eq(bob.party:has(), true, "and the answerer")
eq(ann.party:count(), 2, "of two")
eq(ann.party:partnerName(), "BOB", "each knowing who the other is")
eq(bob.party:partnerName(), "ANN", "from both sides")
check(saidSomething(ann, "party"), "and both are told on screen")
check(saidSomething(bob, "party"), "not just the one who accepted")

-- you are on your own members list, which is the one list that includes you
eq(#ann.party:list(), 2, "the members list carries both of you")
eq(ann.party:isSelf(ann.client.id), true, "and knows which one is you")
eq(ann.party:isPartner(ann.client.id), false, "so the marker is not drawn on you")
eq(ann.party:isPartner(bob.client.id), true, "and is on them")

-- the party's own history says when it started
local note = ann.chat:recent()[1]
check(note ~= nil and note.text:find("BOB"), "the chat log records the teaming up")
eq(note.scope, "party", "as a party line")
eq(ann.chat.unread, 0, "which does not count as an unread line")

-- ------- what an invite cannot do

cal.said = {}
cal.party:invite({ id = bob.client.id, name = "BOB" })
pumpParty(cal)
check(saidSomething(cal, "already"), "inviting a taken player says so plainly")
eq(cal.party:has(), false, "and forms nothing")

ann.said = {}
ann.party:invite({ id = cal.client.id, name = "CAL" })
check(saidSomething(ann, "already in"), "and neither can somebody already in one")
pumpParty(cal)
eq(cal.confirmBox, nil, "the prompt never reaches them")

-- an invite that arrives while you are in a party is refused on your behalf,
-- rather than queued behind whatever you are doing
cal.party.outgoing = nil
cal.party:invite({ id = ann.client.id, name = "ANN" })
pumpParty(ann)
eq(ann.confirmBox, nil, "a player in a party is not prompted")
pumpParty(cal)
check(saidSomething(cal, "ANN"), "and the asker hears back rather than waiting")

-- ------- party chat

hub:update(Config.CHAT_GATE * 2)
ann.peer.outbox, bob.peer.outbox, cal.peer.outbox = {}, {}, {}
hub:receive(ann.client, { type = Wire.CHAT, scope = "party", text = "this way" })
check(take(bob.peer, Wire.CHAT) ~= nil, "a party line reaches your partner")
eq(take(cal.peer, Wire.CHAT), nil, "and stops at the party")

-- ------- leaving

bob.said = {}
ann.said = {}
eq(ann.party:leave(), true, "leaving reports that it happened")
eq(ann.party:has(), false, "and clears immediately, without waiting on the hub")
pumpParty(bob)
eq(bob.party:has(), false, "the other member's party ends too")
check(saidSomething(bob, "ANN left"), "and they are told who left")

-- the hub's own confirmation lands on a client with nothing left to clear,
-- which is the ordinary case rather than an error
ann.said = {}
pumpParty(ann)
eq(ann.party:has(), false, "the leaver stays out")
eq(#ann.said, 0, "and is not told what they just did")

-- ------- a member who disconnects

ann.party:invite({ id = bob.client.id, name = "BOB" })
pumpParty(bob); answer(bob, true)
pumpParty(ann); pumpParty(bob)
eq(ann.party:has(), true, "they can team up again afterwards")

bob.said = {}
hub:drop(ann.client)
pumpParty(bob)
eq(bob.party:has(), false, "a member disconnecting ends the party")
check(saidSomething(bob, "left"), "and the survivor is told rather than left alone")
eq(bob.party:partnerName(), nil, "with nobody left to name")

-- ------- an ask that can never be answered is not left hanging
--
-- Both of these leave the *asker* stuck, not the person who walked away:
-- an outgoing invite is held until an answer comes back, and this client's
-- own "You already asked X." then refuses every later invite. A player
-- locked out of the feature by somebody else's timing, naming a trainer who
-- may not even be online, is the failure worth pinning.

-- (a) the player we asked disconnects before answering
cal.said = {}
cal.party:invite({ id = bob.client.id, name = "BOB" })
eq(cal.party.outgoing ~= nil, true, "an unanswered invite is held")
cal.peer.outbox = {}
hub:drop(bob.client)
cal.party:onPeerGone(bob.client.id)
eq(cal.party.outgoing, nil, "a peer going offline releases the ask")
check(saidSomething(cal, "offline"), "and says why, naming them")
eq(cal.party:onPeerGone(ann.client.id), nil,
   "somebody else leaving is not our business")

-- (b) we join a party while somebody else's prompt is still on our screen
local dan = partySide(hub, "DAN")
local eve = partySide(hub, "EVE")
local fay = partySide(hub, "FAY")
fay.party:invite({ id = dan.client.id, name = "DAN" })
pumpParty(dan)
check(dan.confirmBox ~= nil, "DAN has FAY's prompt up")
eve.party:invite({ id = dan.client.id, name = "DAN" })
pumpParty(dan)
-- DAN's client refuses EVE outright: it already has a prompt up, and two
-- boxes for the same question is not a choice anybody can make
pumpParty(eve)
check(saidSomething(eve, "DAN"), "a second asker hears back rather than waiting")

-- ...and now DAN teams up with somebody else while FAY's prompt is still on
-- screen. The answer FAY is waiting for has to arrive, and it has to be no.
dan.confirmBox = nil
fay.said, fay.peer.outbox = {}, {}
dan.party:onParty({ id = "9", members = { { id = dan.client.id, name = "DAN" },
                                          { id = eve.client.id, name = "EVE" } } })
check(take(fay.peer, Wire.PARTY_DECLINE) ~= nil,
      "joining a party answers the prompt that was still up, rather than "
      .. "leaving the asker waiting on a box that is gone")
eq(dan.party.incoming, nil, "and the prompt is spent")

-- ------- and a reset takes everything, including a half-finished invite

cal.party.outgoing = { to = "x", name = "X" }
cal.party.incoming = { from = "y", name = "Y" }
cal.party:reset()
eq(cal.party.outgoing, nil, "a disconnect drops an unanswered invite")
eq(cal.party.incoming, nil, "and a prompt that was still up")

end)()

-- ------------------------------------------------------------------
-- 11b. Friends, both sides of the ask
-- ------------------------------------------------------------------
--
-- Driven the way the party scenario above is: two real Friends instances with
-- the real Hub between them, and a pump() shaped like src/Client.lua's tick.
-- Most of what this feature has to get right is about the two sides agreeing
-- across time -- an ask answered after the asker logged out, a friendship one
-- side ended while the other was away -- and a single instance asserted
-- against a fake hub cannot see any of it.
--
-- love is absent under this interpreter, so the file half of the store is a
-- no-op here and mod.save is the whole persistence.  That is the right half to
-- pin anyway: the file is a mirror of exactly these rows, and what a suite can
-- check is that the rows written are the rows read back.

;(function()

local Friends = need("Friends")

-- One mod facade per *machine*, not per side: two players sharing a save
-- folder is exactly what the bucket key exists to keep apart, and the only way
-- to assert that is to hand both of them the same store.
local function fakeSave()
  local kept = {}
  return {
    save = {
      get = function(_, key) return kept[key] end,
      set = function(_, key, value) kept[key] = value end,
    },
    log = { warn = function() end, error = function() end,
            info = function() end },
    kept = kept,
  }
end

local function friendSide(hub, name, facade)
  local side = { name = name, said = {} }
  side.peer = fakePeer()
  side.client = hub:accept(side.peer)
  side.transport = {
    send = function(_, msgType, payload)
      local msg = {}
      if type(payload) == "table" then
        for k, v in pairs(payload) do msg[k] = v end
      end
      msg.type = msgType
      hub:receive(side.client, msg)
      return true
    end,
    isReady = function() return true end,
  }
  side.ui = {
    say = function(_, text) side.said[#side.said + 1] = text end,
    confirm = function(_, _, text, cb) side.confirmText = text; side.confirmBox = cb end,
  }
  side.friends = Friends.new(side.transport, side.ui, { mod = facade })
  hub:receive(side.client, { type = Wire.HELLO, proto = Config.PROTOCOL,
                             name = name, map = "FIX_TOWN", x = 1, y = 1 })
  take(side.peer, Wire.WELCOME)
  side.friends:setHub("hub.example:7788", name)
  return side
end

local friendDispatch = {
  [Wire.FRIEND_ASK] = function(s, m) s.friends:onAsk({}, m) end,
  [Wire.FRIEND_ANSWER] = function(s, m) s.friends:onAnswer(m) end,
  [Wire.FRIEND_REMOVE] = function(s, m) s.friends:onRemoved(m) end,
}

local function pumpFriends(side)
  local batch = side.peer.outbox
  side.peer.outbox = {}
  for _, msg in ipairs(batch) do
    local handler = friendDispatch[msg.type]
    if handler then handler(side, msg) end
  end
end

local function answerFriend(side, yes)
  local box = side.confirmBox
  side.confirmBox, side.confirmText = nil, nil
  box(yes)
end

local function friendNames(side)
  local out = {}
  for _, entry in ipairs(side.friends:list()) do out[#out + 1] = entry.name end
  return table.concat(out, ",")
end

local function toldFriend(side, needle)
  for _, line in ipairs(side.said) do
    if line:find(needle, 1, true) then return true end
  end
  return false
end

local fhub = Hub.new({ maxPlayers = 8 })
local annBox = fakeSave()
local bobBox = fakeSave()
local ann = friendSide(fhub, "ANN", annBox)
local bob = friendSide(fhub, "BOB", bobBox)

eq(ann.friends:count(), 0, "nobody starts with friends")
eq(ann.friends:isFriend("BOB"), false, "and nobody is one")

-- ------- the ask, accepted

ann.friends:ask({ id = bob.client.id, name = "BOB" })
check(toldFriend(ann, "Asked BOB"), "the asker is told the ask went out")
pumpFriends(bob)
check(bob.confirmBox ~= nil, "and the other player is asked")
check(bob.confirmText:find("ANN"), "by name")

answerFriend(bob, true)
eq(bob.friends:isFriend("ANN"), true,
   "saying yes writes the friendship on the side that consented, there and "
   .. "then -- not when an acknowledgement comes back")
pumpFriends(ann)
eq(ann.friends:isFriend("BOB"), true, "and on the asker when the answer lands")
check(toldFriend(ann, "BOB is now your"), "who is told out loud")

-- ------- a name is a name, however it was typed

eq(ann.friends:isFriend("bob"), true, "the list folds case, like the board")
eq(ann.friends:isFriend("BOBBY"), false, "without folding two names into one")

-- ------- what the store keeps, and where

do
  local reopened = Friends.new(ann.transport, ann.ui, { mod = annBox })
  reopened:setHub("hub.example:7788", "ANN")
  eq(reopened:isFriend("BOB"), true,
     "a fresh copy of the store reads the same hub's list back")

  reopened:setHub("hub.example:7788", "CAL")
  eq(reopened:isFriend("BOB"), false,
     "another trainer on the same machine and the same hub has their own list")

  reopened:setHub("elsewhere:7788", "ANN")
  eq(reopened:isFriend("BOB"), false,
     "and so does the same trainer on another hub -- ANN there is not ANN "
     .. "here, which is the whole reason the list is filed per hub")

  reopened:setHub("HUB.EXAMPLE:7788 ", "ann")
  eq(reopened:isFriend("BOB"), true,
     "one hub typed two ways, and one name typed two ways, are one bucket")
end

-- ------- a no is an answer

fhub:update(Config.CHAT_GATE * 2)
local cal = friendSide(fhub, "CAL", fakeSave())
ann.said = {}
ann.friends:ask({ id = cal.client.id, name = "CAL" })
pumpFriends(cal)
answerFriend(cal, false)
pumpFriends(ann)
eq(ann.friends:isFriend("CAL"), false, "a no writes nothing")
check(toldFriend(ann, "CAL said no"), "and says so, which silence could not")

-- asking again is allowed, because a no is not a ban: the outgoing guard is
-- cleared by the answer
fhub:update(Config.CHAT_GATE * 2)
ann.said = {}
ann.friends:ask({ id = cal.client.id, name = "CAL" })
check(toldFriend(ann, "Asked CAL"), "so they can be asked again later")

-- ...but not twice while one is still unanswered
ann.said = {}
ann.friends:ask({ id = cal.client.id, name = "CAL" })
check(toldFriend(ann, "already asked"), "one outstanding ask per person")

-- and never against somebody already on the list
ann.said = {}
ann.friends:ask({ id = bob.client.id, name = "BOB" })
check(toldFriend(ann, "already"), "nor against a friend you already have")

-- ------- an ask that arrives mid-fight waits rather than taking the screen

-- ANN's second ask is still sitting on CAL's socket unread.  Dropped rather
-- than pumped, so the box that opens below is unambiguously the one this block
-- is about: the queue is deliberately first-in-first-out, and a stray ask
-- ahead of it would be answered instead.
cal.peer.outbox = {}
cal.confirmBox = nil
cal.busy = true
cal.friends.busy = function() return cal.busy end
fhub:update(Config.CHAT_GATE * 2)
bob.friends:ask({ id = cal.client.id, name = "CAL" })
pumpFriends(cal)
eq(cal.confirmBox, nil,
   "a yes/no box does not open over a battle -- the hub is holding the ask, "
   .. "so nothing is lost by waiting")
cal.friends:update({}, 0.1)
eq(cal.confirmBox, nil, "and it keeps waiting while the fight is on")

cal.busy = false
cal.friends:update({}, 0.1)
check(cal.confirmBox ~= nil, "and opens the moment the fight is over")
check(cal.confirmText:find("BOB"), "asking what it was always going to ask")
answerFriend(cal, true)
pumpFriends(bob)
eq(bob.friends:isFriend("CAL"), true, "and the answer lands as usual")

-- ------- an ask that outlives the connection it was made on

fhub:update(Config.CHAT_GATE * 2)
local dan = friendSide(fhub, "DAN", fakeSave())
ann.friends:ask({ id = dan.client.id, name = "DAN" })
-- DAN closes the game before answering: the box was on screen and nobody
-- pressed anything
dan.peer.outbox = {}
fhub:drop(dan.client)

local danBack = friendSide(fhub, "DAN", fakeSave())
pumpFriends(danBack)
check(danBack.confirmBox ~= nil,
      "the hub puts the ask again the next time they log in, which is the "
      .. "whole reason it keeps holding a delivered one")
answerFriend(danBack, true)
pumpFriends(ann)
eq(ann.friends:isFriend("DAN"), true, "and the friendship forms a session late")

-- ------- an answer that outlives the *asker's* connection

fhub:update(Config.CHAT_GATE * 2)
local eve = friendSide(fhub, "EVE", fakeSave())
local fay = friendSide(fhub, "FAY", fakeSave())
eve.friends:ask({ id = fay.client.id, name = "FAY" })
pumpFriends(fay)
eve.peer.outbox = {}
fhub:drop(eve.client)
answerFriend(fay, true)

local eveBack = friendSide(fhub, "EVE", fakeSave())
pumpFriends(eveBack)
eq(eveBack.friends:isFriend("FAY"), true,
   "an answer given while the asker was away reaches them on their next "
   .. "welcome, so the two lists still agree")

-- ------- the two lists cannot drift apart

-- Somebody whose answer was lost asks again: the side that already agreed
-- says yes without troubling anybody, because consent was given once.
fhub:update(Config.CHAT_GATE * 2)
bob.confirmBox = nil
ann.friends:remove("BOB")
pumpFriends(bob)
eq(bob.friends:isFriend("ANN"), false,
   "a removal takes the friendship off both sides -- one that only came off "
   .. "one would leave the other asking for consent that was already given")
eq(ann.friends:isFriend("BOB"), false, "and off the side that pressed it")
eq(bob.confirmBox, nil, "silently, because there is nothing to do about it")

fhub:update(Config.CHAT_GATE * 2)
ann.friends:ask({ id = bob.client.id, name = "BOB" })
pumpFriends(bob)
check(bob.confirmBox ~= nil, "so being asked again does ask")
answerFriend(bob, true)
pumpFriends(ann)

bob.confirmBox = nil
ann.said = {}
-- ...and now the drift case: ANN's copy lost the answer somehow, so she asks
-- a friendship BOB already has.
ann.friends:_drop("BOB")
fhub:update(Config.CHAT_GATE * 2)
ann.friends:ask({ id = bob.client.id, name = "BOB" })
pumpFriends(bob)
eq(bob.confirmBox, nil,
   "somebody who already has you on their list is not asked to agree twice")
pumpFriends(ann)
eq(ann.friends:isFriend("BOB"), true, "the lists heal instead")

-- ------- the order the screen draws them in

do
  local sorter = Friends.new(ann.transport, ann.ui, { mod = fakeSave() })
  sorter:setHub("sort:7788", "ANN")
  -- written directly so the timestamps are the test's rather than the clock's
  sorter.entries = {
    OLD = { name = "OLD", key = "OLD", added = 10 },
    MID = { name = "MID", key = "MID", added = 20 },
    NEW = { name = "NEW", key = "NEW", added = 30 },
  }
  local roster = Roster.new()
  roster:setSelf("me")
  roster:put(Wire.presence({ id = "1", name = "OLD", map = "FIX_TOWN",
                             x = 1, y = 1 }))

  local rows = sorter:sorted(roster)
  local order = {}
  for _, row in ipairs(rows) do
    order[#order + 1] = row.name .. (row.player and "+" or "-")
  end
  eq(table.concat(order, ","), "OLD+,NEW-,MID-",
     "online first -- the only rows that lead anywhere -- then newest friend "
     .. "first inside each group")

  eq(#sorter:sorted(nil), 3,
     "and with no roster at all every row is simply offline, rather than the "
     .. "screen refusing to draw")
end

-- ------- the ceiling on a list

do
  local full = Friends.new(ann.transport, ann.ui, { mod = fakeSave() })
  full:setHub("full:7788", "ANN")
  for index = 1, Config.FRIENDS_MAX do
    full:_add(("F%d"):format(index))
  end
  eq(full:count(), Config.FRIENDS_MAX, "the list fills to its ceiling")
  eq(full:_add("ONEMORE"), nil,
     "and refuses the next one rather than dropping somebody -- deciding who "
     .. "a player has stopped being friends with is not this mod's call")
  eq(full:isFriend("F1"), true, "so the oldest friend is still there")
end

-- ------- and a disconnect closes the list without losing it

ann.friends:reset()
eq(ann.friends:isOpen(), false, "leaving closes the open list")
eq(ann.friends:count(), 0, "so nothing is drawn for a hub we are not on")
eq(ann.friends:isFriend("BOB"), false, "and nothing answers about one")
ann.friends:setHub("hub.example:7788", "ANN")
eq(ann.friends:isFriend("BOB"), true, "reconnecting reads it straight back")

end)()

-- ------------------------------------------------------------------
-- 11c. The three screens a friendship shows up on
-- ------------------------------------------------------------------
--
-- FRIENDS (the list itself), ACTIONS (the row that makes and unmakes one, in
-- both of its shapes) and PLAYERS (the mark).  Built through Ui:install and
-- the registered constructors rather than a copy of the conditionals written
-- here, which is the whole reason this is worth asserting: what these screens
-- offer is decided by three tables agreeing (the roster, the party, the
-- friends list), and only the real constructor consults all three.

;(function()

local Ui = need("Ui")
local Friends = need("Friends")

-- Saved and put back, never nil'd: stubMod is shared with every section after
-- this one, and a field left nil is a field the next section finds missing
-- rather than as it was.
local keptScreens, keptHooks, keptUi = stubMod.content.screens, stubMod.hooks,
                                       stubMod.ui

local registry, pushes = {}, {}
stubMod.content.screens = {
  register = function(_, id, def) registry[id] = def end,
  get = function(_, id) return registry[id] end,
}
stubMod.hooks = { wrap = function() end }
stubMod.ui = {
  push = function(_, id, opts) pushes[#pushes + 1] = { id = id, opts = opts } end,
  Menu = { new = function(_, items, opts)
    return { kind = "menu", items = items, opts = opts }
  end },
  ListMenu = { new = function(_, title, items, opts)
    return { kind = "list", title = title, items = items, opts = opts,
             index = 1, scroll = 0, close = function() end }
  end },
  TextBox = { new = function(_, text, onDone)
    return { kind = "text", text = text, onDone = onDone }
  end },
}

local roster = Roster.new()
roster:setSelf("me")
roster:put(Wire.presence({ id = "bob", name = "BOB", map = "PALLET_TOWN",
                           x = 1, y = 1 }))
roster:put(Wire.presence({ id = "cal", name = "CAL", map = "PALLET_TOWN",
                           x = 2, y = 1 }))

local party = need("Party").new({ send = function() end }, { say = function() end })
party:setSelf("me")

local said = {}
local friends = Friends.new(
  { send = function() end, isReady = function() return true end },
  { say = function(_, text) said[#said + 1] = text end,
    confirm = function() end },
  { mod = { save = { get = function() end, set = function() end },
            log = { warn = function() end } } })
friends:setHub("screens:7788", "ME")

local screenCtx = { roster = roster, party = party, friends = friends,
                    coop = { pendingOffer = function() return nil end },
                    client = { playerName = function() return "ME" end } }
local screenUi = Ui.new(screenCtx)
check(pcall(function() screenUi:install() end),
      "the friends screens register under a minimal stub")
check(registry[Ui.SCREEN.FRIENDS] ~= nil, "including FRIENDS itself")

local function rowsOf(screen)
  local out = {}
  for _, item in ipairs(screen.items or {}) do
    out[#out + 1] = tostring(item.label) .. "/" .. tostring(item.right)
  end
  return table.concat(out, ",")
end

local function labelsOf(screen)
  local out = {}
  for _, item in ipairs(screen.items or {}) do out[#out + 1] = item.label end
  return table.concat(out, ",")
end

-- ------- an empty list leads somewhere

do
  local screen = registry[Ui.SCREEN.FRIENDS].new({})
  eq(screen.kind, "text",
     "with nobody on it, FRIENDS is a sentence rather than an empty list")
  check(screen.text:find("No friends"), "saying so")
  pushes = {}
  screen.onDone()
  eq(pushes[1] and pushes[1].id, Ui.SCREEN.ROSTER,
     "and handing over the list a friendship is started from, the way the "
     .. "empty PARTY screen does")
end

-- ------- the rows, and the order they are in

friends.entries = {
  BOB = { name = "BOB", key = "BOB", added = 10 },
  CAL = { name = "CAL", key = "CAL", added = 20 },
  DEE = { name = "DEE", key = "DEE", added = 30 },
}

do
  local screen = registry[Ui.SCREEN.FRIENDS].new({})
  eq(screen.kind, "list", "with friends on it, FRIENDS is a list")
  eq(screen.title, "FRIENDS", "titled for what it is")
  eq(rowsOf(screen), "CAL/PALLET TOWN,BOB/PALLET TOWN,DEE/OFFLINE",
     "online first -- newest of them first -- then the ones who are not here, "
     .. "each row saying where they are or that they are away")

  -- the other three things the column can say
  roster:setBusy("bob", true)
  eq(rowsOf(registry[Ui.SCREEN.FRIENDS].new({})),
     "CAL/PALLET TOWN,BOB/BUSY,DEE/OFFLINE",
     "a friend mid-trade says BUSY, as they do on PLAYERS")
  roster:setBusy("bob", false)

  roster:move("bob", nil, nil, nil, "down")
  eq(rowsOf(registry[Ui.SCREEN.FRIENDS].new({})),
     "CAL/PALLET TOWN,BOB/ONLINE,DEE/OFFLINE",
     "a friend with no cell -- in a battle or a menu -- says ONLINE, where "
     .. "PLAYERS leaves the column blank: blank next to a row saying OFFLINE "
     .. "would read as a third state nobody can name")
  roster:move("bob", "PALLET_TOWN", 1, 1, "down")

  party:onParty({ id = "1", members = { { id = "me", name = "ME" },
                                        { id = "cal", name = "CAL" } } })
  eq(rowsOf(registry[Ui.SCREEN.FRIENDS].new({})),
     "CAL/PARTY,BOB/PALLET TOWN,DEE/OFFLINE",
     "and the person you are travelling with says PARTY, which outranks "
     .. "where they are standing")
  party:reset()
  party:setSelf("me")
end

-- ------- pressing A on a row

do
  local screen = registry[Ui.SCREEN.FRIENDS].new({})
  pushes = {}
  screen.opts.onChoose(screen.items[1], screen)
  local opened = pushes[1]
  eq(opened and opened.id, Ui.SCREEN.ACTIONS,
     "an online friend opens the same menu walking up to them does")
  eq(opened.opts.playerId, "cal", "pointed at the connection they are on")

  pushes = {}
  screen.opts.onChoose(screen.items[3], screen)
  opened = pushes[1]
  eq(opened and opened.id, Ui.SCREEN.ACTIONS, "and so does one who is away")
  eq(opened.opts.playerId, nil,
     "with no connection to point at, because there is not one")
  eq(opened.opts.friendName, "DEE", "so they are named instead")
end

-- ------- the row that makes and unmakes a friendship

do
  local menu = registry[Ui.SCREEN.ACTIONS].new({}, { playerId = "bob" })
  check(labelsOf(menu):find("UNFRIEND"),
        "somebody already on the list is offered UNFRIEND")
  check(not labelsOf(menu):find("ADD FRIEND"), "and not both at once")

  friends:_drop("BOB")
  menu = registry[Ui.SCREEN.ACTIONS].new({}, { playerId = "bob" })
  check(labelsOf(menu):find("ADD FRIEND"),
        "and somebody who is not is offered ADD FRIEND -- the row is always "
        .. "there in one state or the other, because whether they will say "
        .. "yes is a fact about a human and not one the menu can see")
  eq(menu.items[1].label, "PROFILE", "PROFILE still leads")
  eq(menu.items[2].label, "ADD FRIEND",
     "and the friend row is second, above everything you might *do* with "
     .. "them: it is the other question about who they are")

  -- the box has to stay clear of the two characters it is about, which is
  -- what decided the label (UNFRIEND, not REMOVE FRIEND)
  local widest = 0
  for _, item in ipairs(menu.items) do
    if #item.label > widest then widest = #item.label end
  end
  eq(widest, #"PARTY BATTLE",
     "no friend row is wider than PARTY BATTLE, so the menu is exactly as "
     .. "wide as it has always been")
  friends:_add("BOB")
end

-- ------- ...and the same row for somebody who is not here

do
  local menu = registry[Ui.SCREEN.ACTIONS].new({}, { friendName = "DEE" })
  eq(menu.kind, "menu", "an absent friend still gets a menu, not a refusal")
  eq(labelsOf(menu), "UNFRIEND",
     "with the one command that still means anything -- there is nobody there "
     .. "to trade, battle or whisper")

  local stranger = registry[Ui.SCREEN.ACTIONS].new({}, { friendName = "ZED" })
  eq(stranger.kind, "text",
     "somebody who is neither online nor on the list is the old sentence")
  check(stranger.text:find("offline"), "which is about bad luck, not choice")
end

-- ------- the mark on the PLAYERS list

do
  friends:_drop("CAL")
  local list = registry[Ui.SCREEN.ROSTER].new({})
  eq(rowsOf(list), Ui.FRIEND_MARK .. "BOB/PALLET TOWN,CAL/PALLET TOWN",
     "a friend's row carries the mark in front of the nickname -- and at a "
     .. "three-glyph name the place beside it still fits whole, because the "
     .. "one glyph the mark costs is one the row had spare")

  friends:_add("CAL")
  eq(labelsOf(registry[Ui.SCREEN.ROSTER].new({})),
     Ui.FRIEND_MARK .. "BOB," .. Ui.FRIEND_MARK .. "CAL",
     "and the mark follows the list rather than the roster, so befriending "
     .. "somebody marks the row they were already on")

  -- The mark is on *every* friend's row, cursor or not. That is the whole
  -- reason it is not in the cursor column: PLAYERS on a two-player hub has
  -- one row, the cursor opens on it, and a mark that yielded there would
  -- never be drawn at all.
  local one = Roster.new()
  one:setSelf("me")
  one:put(Wire.presence({ id = "bob", name = "BOB", map = "PALLET_TOWN",
                          x = 1, y = 1 }))
  local kept = screenCtx.roster
  screenCtx.roster = one
  local solo = registry[Ui.SCREEN.ROSTER].new({})
  eq(labelsOf(solo), Ui.FRIEND_MARK .. "BOB",
     "the only row on the list is marked, even though the cursor is on it")
  screenCtx.roster = kept
end

stubMod.content.screens, stubMod.hooks, stubMod.ui = keptScreens, keptHooks,
                                                     keptUi

end)()

-- ------------------------------------------------------------------
-- 12. A chosen character survives the door it was worn through
-- ------------------------------------------------------------------
--
-- The old rule was "leaving hands the trainer back, always." The new one
-- keeps a character that was actually *chosen*: syncLook wears the
-- standing choice whenever explicitChoice() answers, and restores vanilla
-- only when it does not -- so disconnect, a map change with nothing worn
-- yet, and another save taking over all ask that one question instead of
-- each assuming its own answer.
--
-- The trap is unchanged from before: the overworld reuses one player
-- object across map changes -- OverworldController:setMap calls Player.new
-- only when it has none -- while this mod re-wears the look on every
-- map.entered. Re-reading "the original" on each of those reads back the
-- renderer the mod itself installed, so leaving restored the hub
-- character. One door was enough to lose the real one, which is why the
-- entity the original came from is pinned here alongside it.
--
-- Wrapped for scope, like section 8.

;(function()

local Client = need("Client")

-- The real renderer needs a graphics context; the bookkeeping under test
-- does not care what the object is, only which one is where.
package.loaded["src.render.SpriteRenderer"] = {
  new = function(record, kind) return { worn = record, kind = kind } end,
}

stubSprites.SPRITE_RED = { walker = true }
stubSprites.SPRITE_ROCKET = { walker = true }
stubSave.sprite = "SPRITE_ROCKET"
eq(Client.spriteChoice(), "SPRITE_ROCKET", "the chosen character resolves")
eq(Client.explicitChoice(), "SPRITE_ROCKET",
   "and it counts as an explicit choice -- worth wearing outside a session")

local overworld = { player = nil }
stubMod.world = { overworld = function() return overworld end }

local function newPlayer(name)
  return { sprite = { vanilla = name } }
end

-- ------- one player object, walked through a door

local red = newPlayer("red")
overworld.player = red
local redSheet = red.sprite

eq(Client.wornLook(), nil, "before joining you are wearing nothing of ours")
check(Client.applyLook(), "joining wears the chosen character")
check(red.sprite ~= redSheet, "which really does swap the live renderer")
eq(Client.wornLook(), "SPRITE_ROCKET", "and that is what is worn")

-- map.entered, twice, on the player object the overworld handed back
check(Client.refreshLook(), "entering a map re-wears it")
check(Client.refreshLook(), "and again, as a long session would")
check(red.sprite ~= redSheet, "still wearing it")

Client.restoreLook()
eq(red.sprite, redSheet, "restoreLook itself still gives the trainer back")
-- The battle and trainer-card pics hang off this one, so a direct restore
-- is a game whose pics go back to vanilla in the same breath as the sprite.
eq(Client.wornLook(), nil, "and restoreLook alone is wearing nothing again")

Client.restoreLook()
eq(red.sprite, redSheet, "and restoring twice is not a second restore")

-- ------- explicitChoice: what counts as "asked to be somebody else"
--
-- spriteChoice always answers -- everybody has to be drawn as somebody --
-- but syncLook, disconnect and the widened refreshLook all have to tell
-- "chose a character" apart from "left it to the game", and that is this
-- predicate's whole job.

stubSave.sprite, stubOptions.sprite = nil, nil
eq(Client.explicitChoice(), nil,
   "neither the save field nor the option is set -- nobody touched this")

stubSave.sprite = "SPRITE_RED"
eq(Client.explicitChoice(), nil,
   "picking RED resolves to the engine's own default, which is a restore "
   .. "wearing it, not a choice")

stubSave.sprite = "SPRITE_ROCKET"
eq(Client.explicitChoice(), "SPRITE_ROCKET",
   "a character this game can actually draw comes back as itself")

stubSave.sprite = "SPRITE_FROM_ANOTHER_ROM"
eq(Client.explicitChoice(), nil,
   "a save carried over from a different catalog degrades to RED, and "
   .. "that degrade reads as no choice rather than as RED chosen on purpose")

stubSave.sprite = nil
stubOptions.sprite = "SPRITE_ROCKET"
eq(Client.explicitChoice(), "SPRITE_ROCKET",
   "with no save field, the global option is the standing choice")

stubSave.sprite = "SPRITE_RED"
stubOptions.sprite = "SPRITE_ROCKET"
eq(Client.explicitChoice(), nil,
   "the save field wins over the option even when the save is only RED")

stubOptions.sprite = nil

-- ------- the choice follows you out the door
--
-- disconnect() used to be a plain restore; now it runs syncLook(), which
-- keeps a chosen look on and only undresses a player who never asked for
-- one. Driven through the client's own teardown, not just restoreLook
-- directly, because disconnect is the one path a deliberate leave and a
-- dropped connection both funnel through.

stubSave.sprite = "SPRITE_ROCKET"
red.sprite = redSheet
check(Client.applyLook(), "wearing the chosen character again")
check(red.sprite ~= redSheet, "worn")
Client.disconnect()
check(red.sprite ~= redSheet,
      "disconnecting keeps the chosen look -- it belongs to the player, "
      .. "not to the session that first wore it")
eq(Client.wornLook(), "SPRITE_ROCKET", "and it is still what is worn")

-- Setting the choice applies it there and then -- the whole point of the
-- offline picker row is that it does not need a game to be started.
eq(Client.setSpriteChoice("SPRITE_RED"), "SPRITE_RED",
   "setSpriteChoice succeeds for a character this game can draw")
eq(red.sprite, redSheet,
   "and picking RED wears the engine's own renderer -- which, since red "
   .. "was already vanilla, means putting it straight back")
eq(Client.wornLook(), nil,
   "RED is not a look anybody 'wears': explicitChoice reads it as no "
   .. "choice, so syncLook routes it through restoreLook")

-- Explicit choice again, this time through setSpriteChoice rather than a
-- save write behind its back -- the offline row's whole path.
eq(Client.setSpriteChoice("SPRITE_ROCKET"), "SPRITE_ROCKET",
   "choosing the grunt again")
check(red.sprite ~= redSheet,
      "setSpriteChoice wears the look immediately, offline included -- "
      .. "there is no game running here, and it still applied")
eq(Client.wornLook(), "SPRITE_ROCKET", "and that is what is worn")

check(Client.setSpriteChoice("SPRITE_NOT_IN_THIS_CATALOG") == nil,
      "a character this game cannot draw is refused")
eq(stubSave.sprite, "SPRITE_ROCKET",
   "and the refusal does not disturb the choice already standing")

Client.disconnect()
check(red.sprite ~= redSheet, "the teardown keeps that choice on too")

-- ------- nothing chosen, nothing to keep

stubSave.sprite, stubOptions.sprite = nil, nil
check(Client.applyLook(),
      "the game still draws whoever spriteChoice resolves to -- "
      .. "everybody has to be drawn as somebody")
Client.disconnect()
eq(red.sprite, redSheet,
   "but with no explicit choice standing, disconnecting is exactly the "
   .. "restore it always was")
eq(Client.wornLook(), nil, "and nothing is worn once it has")

-- ------- refreshLook's widened gate: an offline save wears its choice too
--
-- The old gate was "already wearing one, or in a game" -- which is exactly
-- why a single-player save with a character picked never showed it until
-- this widened. The third clause is what a save that was never connected
-- rides in on.

Client.restoreLook()
red.sprite = redSheet
eq(Client.refreshLook(), false,
   "a map change with nothing worn, no game, and no choice does not "
   .. "dress the player up")
eq(red.sprite, redSheet, "and leaves the trainer alone")

stubSave.sprite = "SPRITE_ROCKET"
eq(Client.refreshLook(), true,
   "the same map change, once a choice is standing, wears it -- this is "
   .. "what dresses an offline save on its first map.entered")
check(red.sprite ~= redSheet, "and it really is worn")
eq(Client.wornLook(), "SPRITE_ROCKET", "the chosen character")

Client.restoreLook()
red.sprite = redSheet

-- ------- a fresh save drops the old stash
--
-- M.saveLoaded() is leave(); restoreLook(); syncLook() -- in that order,
-- because the stash belongs to the world that is going away and the new
-- save may have chosen somebody else, or nobody. NEW GAME has to run
-- through here too: the engine reuses one player entity for the life of
-- the process, so a fresh file that never resynced would inherit whatever
-- the last save left worn.

stubSave.sprite = "SPRITE_ROCKET"
check(Client.applyLook(), "the outgoing save's character is worn")
check(red.sprite ~= redSheet, "worn")

stubSave.sprite = nil
Client.saveLoaded()
eq(red.sprite, redSheet,
   "a save with no choice at all drops the outgoing look -- a NEW GAME "
   .. "must not inherit the last file's character")
eq(Client.wornLook(), nil, "and wears nothing until told to")

stubSprites.SPRITE_GENTLEMAN = { walker = true }
check(Client.applyLook(), "worn again for the next handoff")
stubSave.sprite = "SPRITE_GENTLEMAN"
Client.saveLoaded()
eq(Client.wornLook(), "SPRITE_GENTLEMAN",
   "a save loaded in on top of it wears its own choice, not the "
   .. "previous file's")
check(red.sprite ~= redSheet, "worn")
Client.restoreLook()
red.sprite = redSheet
stubSprites.SPRITE_GENTLEMAN = nil

-- ------- a player the engine really did rebuild

stubSave.sprite = "SPRITE_ROCKET"
check(Client.applyLook(), "worn, and then the world rebuilds the player")
local blue = newPlayer("blue")
local blueSheet = blue.sprite
overworld.player = blue

-- the map that rebuilt the player re-wears on the new one, and the sheet it
-- stashes is that one's own -- not the renderer left on the object that died
check(Client.refreshLook(), "the rebuilt player wears the character")
check(blue.sprite ~= blueSheet, "worn")
Client.restoreLook()
eq(blue.sprite, blueSheet, "and gets its own sheet back, not the old one's")

-- and a restore aimed at an entity that is already gone stays its hand
check(Client.applyLook(), "worn on the current player")
local ghost = newPlayer("ghost")
local ghostSheet = ghost.sprite
overworld.player = ghost
Client.restoreLook()
eq(ghost.sprite, ghostSheet, "a player swapped in since is left exactly as it is")

stubMod.world = nil
stubSave.sprite = nil
stubSprites.SPRITE_ROCKET = nil

end)()

-- ------- co-op battles
--
-- Driven exactly the way the party scenario above is -- real Coop instances
-- with the real Hub between them -- because every rule this feature has is
-- about two clients disagreeing about the same fight, and none of it is
-- visible from one instance asserted against a fake hub.
--
-- The four rules from the brief, each asserted here by name:
--
--   * the choice cannot be escaped, and B is BATTLE ALONE;
--   * a no leaves nothing behind, so the waiter keeps waiting and the same
--     ask is made again next time;
--   * nobody joins a battle that has started;
--   * PARTY BATTLE refuses an opponent with no party, and a partner who is
--     not on this map, and needs all four to agree.

;(function()

local Coop = need("Coop")
local Party = need("Party")
local Ui = need("Ui")

-- A client, with the two prompt widgets recorded rather than drawn.
--
-- `chosen` is what makes the unescapable choice testable at all: Ui:choose
-- hands over a row list, and pressing B runs the *last* row -- so the harness
-- keeps the rows and offers both "pick by label" and "press B" as separate
-- moves, which is the only way to tell the two apart.
local function coopSide(hub, name, mapId)
  local side = { name = name, said = {}, chat = Chat.new() }
  -- A stand-in for the engine's StateStack. The co-op prompt goes on top of
  -- the trainer battle rather than replacing it, so "did BATTLE ALONE work"
  -- is the question "is the engine's battle back on top", and that needs a
  -- stack to ask it of.
  side.stack = {
    states = {},
    top = function(self) return self.states[#self.states] end,
    pop = function(self) return table.remove(self.states) end,
    push = function(self, st) self.states[#self.states + 1] = st end,
  }
  side.game = { stack = side.stack, save = { party = {}, inventory = {} } }
  side.peer = fakePeer()
  side.client = hub:accept(side.peer)
  side.roster = Roster.new()
  side.transport = {
    send = function(_, msgType, payload)
      local msg = {}
      if type(payload) == "table" then
        for k, v in pairs(payload) do msg[k] = v end
      end
      msg.type = msgType
      hub:receive(side.client, msg)
      return true
    end,
    isReady = function() return true end,
  }
  -- Every prompt this module raises is a state on the stack, so the fakes put
  -- one there: without it `unwindTo` would have nothing to unwind and the
  -- BATTLE ALONE assertions would pass for the wrong reason.
  side.ui = {
    say = function(_, text, onDone)
      side.said[#side.said + 1] = text
      side.sayDone = onDone
    end,
    confirm = function(_, _, text, cb)
      side.confirmText = text; side.confirmBox = cb
      side.stack:push({ prompt = "confirm" })
    end,
    choose = function(_, _, text, items)
      side.chooseText = text; side.chosen = items
      side.stack:push({ prompt = "choose" })
    end,
    pushState = function(_, _, state) side.stack:push(state) end,
  }
  side.party = Party.new(side.transport, side.ui, side.chat)
  side.coop = Coop.new(side.transport, side.ui, side.party, side.roster,
                       side.chat)
  hub:receive(side.client, { type = Wire.HELLO, proto = Config.PROTOCOL,
                             name = name, map = mapId or "FIX_TOWN",
                             x = 1, y = 1 })
  local welcome = take(side.peer, Wire.WELCOME)
  side.id = welcome and welcome.id
  side.party:setSelf(side.id)
  side.roster:setSelf(side.id)
  -- The welcome carries everyone already online, and the roster has to hold
  -- them: co-op refuses a fight whose partner it cannot see standing anywhere,
  -- so a harness that skipped this would fail for the wrong reason.
  for _, raw in ipairs((welcome and welcome.players) or {}) do
    side.roster:put(Wire.presence(raw))
  end
  return side
end

local coopDispatch = {
  [Wire.PARTY_INVITE] = function(s, m) s.party:onInvite({}, m) end,
  [Wire.PARTY] = function(s, m) s.party:onParty(m) end,
  [Wire.PARTY_END] = function(s, m) s.party:onEnd(m); s.coop:onPartyEnd() end,
  [Wire.COOP_OFFER] = function(s, m) s.coop:onOffer(m) end,
  [Wire.COOP_OFFER_END] = function(s, m) s.coop:onOfferEnd(m) end,
  [Wire.COOP_JOINED] = function(s, m) s.coop:onJoined({}, m) end,
  [Wire.COOP_ASK] = function(s, m) s.coop:onAsk({}, m) end,
  [Wire.COOP_DECLINE] = function(s, m) s.coop:onDecline(m) end,
  [Wire.COOP_BATTLE] = function(s, m) s.coop:onBattle({}, m) end,
  [Wire.JOIN] = function(s, m) s.roster:put(Wire.presence(m.player)) end,
  [Wire.MOVE] = function(s, m)
    local id = Wire.id(m.id)
    if not id then return end
    s.roster:setParty(id, m.party)
    s.roster:move(id, Wire.mapId(m.map), Wire.int(m.x, 0, 4096),
                  Wire.int(m.y, 0, 4096), Wire.facing(m.facing))
  end,
}

local function pump(side)
  local batch = side.peer.outbox
  side.peer.outbox = {}
  for _, msg in ipairs(batch) do
    local handler = coopDispatch[msg.type]
    if handler then handler(side, msg) end
  end
end

local function said(side, needle)
  for _, line in ipairs(side.said) do
    if line:find(needle, 1, true) then return true end
  end
  return false
end

-- Pick a row of the unescapable choice by its label.
local function pick(side, label)
  for _, item in ipairs(side.chosen or {}) do
    if item.label == label then
      side.chosen = nil
      item.onSelect()
      return true
    end
  end
  return false
end

-- Press B on it.
--
-- Ui.cancelRow is the screen's own rule, called here rather than copied:
-- reproducing "the last row" in the harness would let the screen stop obeying
-- it without a single check going red, which is exactly the regression rule 2
-- cannot afford.
local function pressB(side)
  local row = Ui.cancelRow(side.chosen)
  side.chosen = nil
  if not row then return false end
  row.onSelect()
  return true
end

eq(Ui.cancelRow({ { label = "WAIT" }, { label = "ALONE" } }).label, "ALONE",
   "B selects the last row of a choice")
eq(Ui.cancelRow({}), nil, "and an empty choice has no row to select")

-- Run whatever a ui:say was given as its continuation.
--
-- In game the player presses A and the box closes; here nothing does, so the
-- handoff's own "and now hand the encounter back" step would never run and
-- `running` would stay set -- which is rule 3 refusing every later prompt for
-- the rest of the suite. Draining it is what the player pressing A is.
local function settle(side)
  local done = side.sayDone
  side.sayDone = nil
  if done then done() end
  return done ~= nil
end

local function answerConfirm(side, yes)
  local box = side.confirmBox
  side.confirmBox = nil
  if not box then return false end
  box(yes)
  return true
end

-- The engine pushing a trainer battle, which is the thing the mod now watches
-- for. The object carries the three fields the real one carries and this code
-- actually reads: what kind it is, who the trainer is, the party it built, and
-- the onFinish that runs the whole post-battle flow.
local function engage(side, oppClass)
  local battle = {
    kind = "trainer",
    oppClass = oppClass or "OPP_BUG_CATCHER",
    enemyParty = { { species = "FIXMON_A" }, { species = "FIXMON_B" } },
    onFinish = function(result) side.finished = result end,
  }
  side.engine = battle
  side.finished = nil
  side.stack:push(battle)
  return side.coop:onTrainerBattle(side.game, battle, "FIX_TOWN"), battle
end

-- BATTLE ALONE leaves the engine's own battle on top, untouched.
local function fightsAlone(side)
  return side.stack:top() == side.engine
end

local FIGHT = Coop.battleKey("FIX_TOWN", "OPP_BUG_CATCHER", "FIXMON_A", nil)
local OTHER = Coop.battleKey("FIX_TOWN", "OPP_LASS", "FIXMON_A", nil)

-- ------- the key is derived, not invented

check(FIGHT ~= OTHER, "two trainers on one map get different keys")
eq(Coop.battleKey("FIX_TOWN", "OPP_BUG_CATCHER", "FIXMON_A", nil), FIGHT,
   "and the same trainer gets the same key from both sides")
check(Wire.battleKey(FIGHT) == FIGHT,
      "a derived key survives its own sanitiser")
check(Wire.battleKey("FIX|TOWN; DROP") == nil,
      "and one carrying anything else does not")

local hub = Hub.new({ maxPlayers = 8 })
local ann = coopSide(hub, "ANN")
local bob = coopSide(hub, "BOB")
pump(ann); pump(bob)

-- ------- a lone player never sees any of it

eq(engage(ann), false,
   "a player with no party is not offered co-op at all")
eq(ann.chosen, nil, "no prompt is raised")

-- ------- team up

ann.party:invite({ id = bob.client.id, name = "BOB" })
pump(bob)
answerConfirm(bob, true)
pump(ann); pump(bob)
eq(ann.party:has(), true, "ANN and BOB are a party")

-- ------- the first player reaches the trainer

ann.said = {}
eq(engage(ann), true,
   "a party member walking into a trainer is asked first")
check(ann.chooseText:find("BOB"), "and the question names their partner")
eq(#ann.chosen, 2, "with exactly two answers")
eq(ann.chosen[2].label, "ALONE",
   "and BATTLE ALONE last -- which is what B selects")

-- ------- rule 2: B is an answer, not an escape

pressB(ann)
check(fightsAlone(ann), "pressing B fights the trainer rather than dodging it")
eq(ann.coop:isWaiting(), false, "and starts no wait")

-- ------- waiting, and what the partner is told

engage(ann)
pick(ann, "WAIT")
eq(ann.coop:isWaiting(), true, "choosing WAIT starts a wait")
check(not fightsAlone(ann), "and does not hand the battle back yet")
check(ann.chosen ~= nil, "a waiting box is put up")

pump(bob)
local offer = bob.coop:pendingOffer()
check(offer ~= nil, "the partner is told about the fight")
eq(offer.battle, FIGHT, "by key")
eq(offer.name, "ANN", "and by who is standing there")
eq(offer.label, "BUG CATCHER", "with something to call the trainer")

-- ------- rule 2 again: backing out of waiting reopens the choice

ann.said = {}
pressB(ann)
eq(ann.coop:isWaiting(), false, "B on the waiting box stops waiting")
check(not fightsAlone(ann), "without handing the battle back yet")
eq(#(ann.chosen or {}), 2, "and reopens the wait/alone choice")
eq(ann.chosen[2].label, "ALONE", "still with ALONE as the B answer")
pump(bob)
eq(bob.coop:pendingOffer(), nil, "the partner's offer is taken down with it")

-- ...and from there the player is still cornered
pressB(ann)
check(fightsAlone(ann), "so the way out of waiting is still into a battle")

-- ------- rule 1: a no leaves nothing behind

engage(ann)
pick(ann, "WAIT")
pump(bob)
check(bob.coop:pendingOffer() ~= nil, "ANN is waiting again")

eq(engage(bob), true,
   "the second player reaching the same fight is asked to join")
check(bob.confirmText:find("ANN"), "naming who is waiting")
eq(bob.chosen, nil, "and is not asked to wait for anybody")

answerConfirm(bob, false)
check(fightsAlone(bob), "saying no fights that trainer alone")
pump(ann)
eq(ann.coop:isWaiting(), true,
   "but does NOT decide anything for the player who is waiting")
check(not said(ann, "alone"), "who is not even told")

-- ...and the ask is made again, because nothing recorded the refusal
eq(engage(bob), true,
   "walking back into the same fight asks again")
check(bob.confirmBox ~= nil, "with the same yes/no")

-- a different trainer is not that fight, and is not offered as one
answerConfirm(bob, false)
engage(bob, "OPP_LASS")
eq(bob.confirmBox, nil, "another trainer on the same map is not the same fight")
check(bob.chosen ~= nil, "so BOB gets the wait/alone choice for it instead")
pick(bob, "ALONE")

-- ------- yes: both sides reach the handoff

engage(bob)
answerConfirm(bob, true)
pump(ann); pump(bob)

eq(ann.coop:isWaiting(), false, "a yes ends the wait")
check(ann.coop.lastPlan ~= nil, "and the waiting player reaches the handoff")
check(bob.coop.lastPlan ~= nil, "as does the one who joined")
-- The bug this pins: M:onBattle used to build the joiner's plan with no
-- `engine` field at all, so M:startBattle's unwind never ran for BOB -- his
-- own trainer battle sat under the co-op screen for the whole fight and came
-- straight back the moment it popped, dropping him into the same trainer
-- again, alone. M:joinedEngine is the fix; this is its direct pin, checked by
-- identity and not merely by non-nil, so a version that handed back the
-- *wrong* battle would still fail here.
check(bob.coop.lastPlan.engine == bob.engine,
      "and BOB's own trainer battle rides along on his plan too")
eq(ann.coop.lastPlan.kind, "npc", "as a co-op fight against an NPC")
eq(#ann.coop.lastPlan.allies, 2, "with both of them on the same side")

-- Both sides now put their party on the wire, which is the first step of
-- assembling a real four-slot field. Neither has an engine to build one with
-- under luajit, so both abandon with a sentence rather than half-starting --
-- and rule 2 still holds: the trainer each of them walked into is handed back.
--
-- Two releases, and that is right rather than a double count: each walked into
-- that trainer and each has a script suspended in front of it.
settle(ann); settle(bob)
eq(ann.coop.running, false, "neither is left marked as mid-battle")

-- ------- rule 3: nobody joins once it has started

ann.coop.running = true
eq(engage(ann), false,
   "a trainer met while a co-op battle is running is left to the engine")
ann.coop.running = false

-- an offer taken up twice starts one fight, not two
engage(ann)
pick(ann, "WAIT")
pump(bob)
bob.transport.send(nil, Wire.COOP_JOIN, { to = ann.id, battle = FIGHT })
bob.transport.send(nil, Wire.COOP_JOIN, { to = ann.id, battle = FIGHT })
local joins = 0
for _, msg in ipairs(ann.peer.outbox) do
  if msg.type == Wire.COOP_JOINED then joins = joins + 1 end
end
eq(joins, 1, "a second join finds nothing left to accept")
pump(ann); pump(bob)
-- both are mid-handoff again; hand their encounters back before moving on
settle(ann); settle(bob)

-- ------- PARTY BATTLE: the refusals the brief names

local cal = coopSide(hub, "CAL")
local dee = coopSide(hub, "DEE")
pump(ann); pump(bob); pump(cal); pump(dee)

ann.said = {}
eq(ann.coop:challenge({}, { id = cal.id, name = "CAL", party = false },
                      "FIX_TOWN"), false,
   "PARTY BATTLE refuses an opponent who is not in a party")
check(said(ann, "isn't in"), "and says exactly that")

-- CAL and DEE pair up, on the same map
cal.party:invite({ id = dee.client.id, name = "DEE" })
pump(dee)
answerConfirm(dee, true)
pump(cal); pump(dee); pump(ann); pump(bob)

-- ...but ANN's own partner has wandered off
hub:receive(bob.client, { type = Wire.MOVE, map = "FIX_ROUTE", x = 4, y = 4 })
pump(ann)
ann.said = {}
eq(ann.coop:challenge({}, { id = cal.id, name = "CAL", party = true },
                      "FIX_TOWN"), false,
   "and refuses when your own partner is not on this map")
check(said(ann, "BOB"), "naming the member who is elsewhere")

-- bring BOB back
hub:receive(bob.client, { type = Wire.MOVE, map = "FIX_TOWN", x = 1, y = 1 })
pump(ann)

-- ------- all four have to agree

ann.said = {}
eq(ann.coop:challenge({}, { id = cal.id, name = "CAL", party = true },
                      "FIX_TOWN"), true, "with all four in place, the ask goes out")
pump(bob); pump(cal); pump(dee)
check(bob.confirmBox ~= nil, "your own partner is asked")
check(cal.confirmBox ~= nil, "the player you challenged is asked")
check(dee.confirmBox ~= nil, "and so is theirs -- all four, not two")
eq(ann.confirmBox, nil, "the asker is not asked again")

-- one no ends it for everyone
ann.coop.lastPlan, bob.coop.lastPlan = nil, nil
cal.coop.lastPlan, dee.coop.lastPlan = nil, nil
answerConfirm(bob, true)
answerConfirm(cal, true)
pump(ann); pump(bob); pump(cal); pump(dee)
eq(ann.coop.lastPlan, nil, "three yesses out of four start nothing")
eq(cal.coop.lastPlan, nil, "on either side")
answerConfirm(dee, false)
pump(ann); pump(bob); pump(cal); pump(dee)
check(said(cal, "said no") or said(ann, "said no"),
      "one refusal is told to the others")
eq(ann.coop.ask, nil, "and the ask is off")

-- ...and with every yes, all four reach the handoff
ann.said, bob.said, cal.said, dee.said = {}, {}, {}, {}
ann.coop.lastPlan, bob.coop.lastPlan = nil, nil
cal.coop.lastPlan, dee.coop.lastPlan = nil, nil
eq(ann.coop:challenge({}, { id = cal.id, name = "CAL", party = true },
                      "FIX_TOWN"), true, "asked again")
pump(bob); pump(cal); pump(dee)
answerConfirm(bob, true)
answerConfirm(cal, true)
answerConfirm(dee, true)
pump(ann); pump(bob); pump(cal); pump(dee)

for _, side in ipairs({ ann, bob, cal, dee }) do
  check(side.coop.lastPlan ~= nil, side.name .. " reaches the handoff")
  eq(side.coop.lastPlan.kind, "party", "as a party battle")
  eq(#side.coop.lastPlan.allies, 2, "with two on their side")
  eq(#side.coop.lastPlan.foes, 2, "and two against")
end
eq(ann.coop.lastPlan.side, bob.coop.lastPlan.side,
   "partners are told they are on the same side")
check(ann.coop.lastPlan.side ~= cal.coop.lastPlan.side,
      "and opponents are not")

-- ------- the engine's battle is finished off, not left hanging
--
-- The bug this catches: a co-op battle stands in for the trainer battle the
-- engine built, so that battle has to be told how it went. Its `onFinish` is
-- the entire post-battle flow -- the defeated-trainer flag, the victory
-- rewards, the whiteout on a wipe, the script that has been waiting in front
-- of the trainer. Dropping it instead of calling it leaves all of that undone
-- and the map script suspended for good.

ann.coop.running = false
engage(ann)
pick(ann, "WAIT")
check(ann.coop.encounter ~= nil, "the encounter is held while waiting")
eq(ann.finished, nil, "and the engine's battle has not been told anything yet")

ann.coop.engineBattle = ann.engine
ann.coop:onBattleOver("win")
eq(ann.finished, "win",
   "a finished co-op battle hands its result to the engine's own battle")
eq(ann.coop.encounter, nil, "and the encounter is spent")

-- ...and BATTLE ALONE hands it nothing, because nothing stood in for it: the
-- engine's battle was underneath the prompt the whole time and simply resumes.
engage(ann)
check(not fightsAlone(ann), "the prompt is on top of the battle")
pressB(ann)
check(fightsAlone(ann), "B closes the prompt and the engine's battle resumes")
eq(ann.finished, nil, "with nothing finished off behind its back")

-- ------- BOB's own displaced battle gets its result back too
--
-- The block above pins the waiter's half, which already worked before the
-- fix. This is the half that did not: before M:joinedEngine existed, a
-- player who *joined* was never handed their own engine battle at all, so
-- nothing was ever there for onBattleOver to find. Mirrored here to show the
-- mechanism -- once BOB's own battle is held in engineBattle, onBattleOver
-- hands it its result exactly as it does for a waiter -- is not itself
-- role-specific; only getting the battle into that slot in the first place
-- was ever the problem, and that half is pinned by the identity check on
-- bob.coop.lastPlan.engine above.
--
-- bob.coop.offer is cleared first so this reaches the ordinary WAIT/ALONE
-- choice rather than a join prompt left over from an earlier scenario in this
-- same suite -- the fight this test cares about is BOB's own, not ANN's.

bob.coop.running = false
bob.coop.offer = nil
engage(bob)
pick(bob, "WAIT")
check(bob.coop.encounter ~= nil, "BOB's own encounter is held while he waits too")
eq(bob.finished, nil, "and his own engine battle has not been told anything yet")

bob.coop.engineBattle = bob.engine
bob.coop:onBattleOver("win")
eq(bob.finished, "win",
   "a finished co-op battle hands its result back to BOB's own battle too")
eq(bob.coop.encounter, nil, "and BOB's encounter is spent as well")

-- ------- ownership transfer only happens for a genuine match
--
-- M:startBattle is where the encounter slot is emptied, and reaching it needs
-- a running CoopBattle, which needs the real engine's link modules -- out of
-- reach under plain luajit, same as the abandoned four-slot field above.
-- What *is* reachable is M:joinedEngine, which decides what that slot is
-- emptied *of*: a call that adopts nothing must also disturb nothing. An
-- encounter quietly cleared out from under a fight nobody joined would be the
-- mirror bug -- release() later unwinding to a battle that is no longer on the
-- stack, hunting for something that is not there.

local ownership = { battle = FIGHT, engine = bob.engine, game = bob.game }
bob.coop.encounter = ownership
eq(bob.coop:joinedEngine(bob.game, { battle = OTHER }, nil), nil,
   "a mismatched battle key adopts nothing")
check(bob.coop.encounter == ownership,
      "...and leaves BOB's own encounter exactly where it was")
eq(bob.coop:joinedEngine(bob.game, { battle = FIGHT },
                         { { id = "x", name = "X" } }), nil,
   "and neither does a party-vs-party message, even naming the right key")
check(bob.coop.encounter == ownership, "still untouched")

-- ...and an encounter whose battle has already left the stack is not adopted
-- either, however well its key matches. A join the hub drops leaves exactly
-- that behind: the player fights the trainer alone, that battle pops itself,
-- and the reference names nothing. unwindTo would then pop sixteen screens
-- looking for it.
local ghost = { name = "a battle that finished itself" }
bob.coop.encounter = { battle = FIGHT, engine = ghost, game = bob.game }
eq(bob.coop:joinedEngine(bob.game, { battle = FIGHT }, nil), nil,
   "and neither does an encounter whose battle is already off the stack")
eq(bob.coop:unwindTo(bob.game, ghost, true), false,
   "unwinding to a state that is not on the stack does nothing at all")
check(#bob.game.stack.states > 0,
      "...rather than taking sixteen screens down hunting for it")
bob.coop.encounter = nil

-- ------- negative: a party-vs-party battle never adopts an encounter
--
-- foes on the plan means this is PARTY BATTLE, not an NPC fight, and no
-- encounter is ever the right answer for one -- see M:joinedEngine's own
-- comment. Exercised with a live encounter deliberately in place, and naming
-- the very battle the message is about, so a guard that forgot to check
-- `foes` first would still pass a "no encounter set" test and only fail here.

bob.coop.running = false
bob.coop.encounter = { battle = FIGHT, engine = bob.engine, game = bob.game }
bob.coop:onBattle(bob.game, {
  side = "a",
  allies = { { id = bob.id, name = "BOB" } },
  foes = { { id = ann.id, name = "ANN" } },
  battle = FIGHT,
})
check(bob.coop.lastPlan ~= nil, "the party battle still reaches the handoff")
eq(bob.coop.lastPlan.engine, nil,
   "but never adopts BOB's own live encounter, even naming its own battle key")
bob.coop.running, bob.coop.battle, bob.coop.encounter = false, nil, nil

-- ------- negative: a different trainer, or none named at all, adopts nothing

bob.coop.encounter = { battle = FIGHT, engine = bob.engine, game = bob.game }
bob.coop:onBattle(bob.game, {
  side = "a",
  allies = { { id = bob.id, name = "BOB" } },
  battle = OTHER,
})
eq(bob.coop.lastPlan.engine, nil,
   "a battle naming someone else's trainer does not adopt BOB's encounter")
bob.coop.running, bob.coop.battle, bob.coop.encounter = false, nil, nil

bob.coop.encounter = { battle = FIGHT, engine = bob.engine, game = bob.game }
bob.coop:onBattle(bob.game, {
  side = "a",
  allies = { { id = bob.id, name = "BOB" } },
  -- no battle field at all -- the ACTIONS-menu join path, which never named one
})
eq(bob.coop.lastPlan.engine, nil,
   "and a message with no battle key at all adopts nothing either")
bob.coop.running, bob.coop.battle, bob.coop.encounter = false, nil, nil

bob.coop.encounter = { battle = FIGHT, engine = bob.engine, game = bob.game }
bob.coop:onBattle(bob.game, {
  side = "a",
  allies = { { id = bob.id, name = "BOB" } },
  battle = "FIX|TOWN; DROP", -- fails Wire.battleKey's own sanitiser
})
eq(bob.coop.lastPlan.engine, nil,
   "nor does a battle field too malformed for Wire.battleKey to accept")
bob.coop.running, bob.coop.battle, bob.coop.encounter = false, nil, nil

-- ------- a ranked 2-on-2 needs all four to agree
--
-- The hub scores a party battle as one team match -- each player against the
-- other pair's combined strength -- so every player gets exactly one rated
-- result, and, exactly as in a 1v1, one report is worth nothing on its own.

;(function()
  local id = nil
  for askId in pairs(hub.coopMatches or {}) do id = askId end
  if not id then
    -- The four-way above settled its ask into a battle, which is where the
    -- paperwork is created; if it is not there the rest cannot be asserted.
    check(false, "a settled party battle leaves ranking paperwork")
    return
  end
  local match = hub.coopMatches[id]
  eq(#match.a, 2, "the paperwork holds one side of two...")
  eq(#match.b, 2, "...against the other side of two")
  eq(#match.everyone, 4, "and needs all four to report")

  -- three reports settle nothing
  hub:receive(ann.client, { type = Wire.RESULT, session = id, outcome = "win" })
  hub:receive(bob.client, { type = Wire.RESULT, session = id, outcome = "win" })
  hub:receive(cal.client, { type = Wire.RESULT, session = id, outcome = "loss" })
  check(hub.coopMatches[id] ~= nil, "three reports out of four settle nothing")

  -- a player cannot revise their answer into agreement
  hub:receive(ann.client, { type = Wire.RESULT, session = id, outcome = "loss" })
  eq(match.reports[ann.client.id], "win", "the first answer from each stands")

  hub:receive(dee.client, { type = Wire.RESULT, session = id, outcome = "loss" })
  eq(hub.coopMatches[id], nil, "the fourth report settles it, once")

  -- and it moved somebody: the winning side gained, the losing side lost
  local board = hub.board
  check(board ~= nil, "the hub keeps a board")
  -- Read straight off the board's entries: everybody starts at RANK_START, so
  -- somebody above it is somebody a co-op battle paid.
  local winners, losers = 0, 0
  for _, entry in pairs(board.entries or {}) do
    if (entry.points or 0) > Config.RANK_START then winners = winners + 1 end
    if (entry.played or 0) > 0 and (entry.points or 0) <= Config.RANK_START then
      losers = losers + 1
    end
  end
  eq(winners, 2, "both winners gained points")
  eq(losers, 2, "and both losers were rated too")

  -- a report for a battle that was already settled is simply ignored
  hub:receive(ann.client, { type = Wire.RESULT, session = id, outcome = "win" })
  check(true, "a late report after settlement is not an error")
end)()

-- ------- a finished co-op battle is reclaimed by the hub
--
-- The leak this pins: a relay group was opened when four players agreed and
-- only ever closed when somebody *disconnected*. Nothing told the hub a battle
-- had merely ended, so a server that ran for a week held one dead group per
-- battle ever fought -- each still routing traffic at players who had walked
-- away, and each holding their coopBattleId so the hub thought they were still
-- in it.

;(function()
  -- The four-way above left a live group behind it -- and so did the earlier
  -- NPC join, which opens a group of two. Selected by shape rather than by
  -- whichever `pairs` happened to yield first, or this passes or fails
  -- depending on a hash order.
  local liveId
  for id, group in pairs(hub.coopBattles or {}) do
    if #(group.members or {}) == 4 then liveId = id end
  end
  check(liveId ~= nil, "agreeing on a party battle opens a relay group")
  local group = hub.coopBattles[liveId]
  eq(#group.members, 4, "with all four in it")
  eq(ann.client.coopBattleId, liveId, "and each of them filed under it")

  -- one goodbye closes it for everybody
  hub:receive(ann.client, { type = Wire.COOP_LEAVE })
  eq(hub.coopBattles[liveId], nil, "one goodbye reclaims the whole group")
  eq(ann.client.coopBattleId, nil, "the player who said it is let out")
  eq(bob.client.coopBattleId, nil, "and so is everybody else -- it ends at once")

  -- and traffic sent afterwards goes nowhere rather than to a dead group
  bob.peer.outbox = {}
  hub:receive(cal.client,
    { type = Wire.COOP_RELAY, payload = { t = "act" } })
  eq(take(bob.peer, Wire.COOP_MSG), nil,
     "relaying into a closed group reaches nobody")

  -- a goodbye from somebody in no battle is ignored rather than an error
  hub:receive(ann.client, { type = Wire.COOP_LEAVE })
  check(true, "a goodbye with no battle behind it is harmless")

  -- the backstop: a group whose battle never said goodbye is aged out
  local staleId = hub:openCoopBattle("stale", { ann.client.id, bob.client.id })
  check(hub.coopBattles[staleId] ~= nil, "a group can be opened directly")
  hub.coopBattles[staleId].startedAt = hub.clock - (Config.COOP_BATTLE_MAX + 1)
  hub:update(0)
  eq(hub.coopBattles[staleId], nil,
     "a group whose battle never ended is reclaimed on age")
  eq(ann.client.coopBattleId, nil, "and its members are let out of it too")
end)()

-- ------- partner gating: two layers, and both are checked
--
-- Menu truth (Ui.lua, ctx.party:isPartner) and state truth (Coop:challenge's
-- own guard) are meant to agree: the row is the courtesy, the guard is what
-- makes the state genuinely unreachable if the row is ever forced or reached
-- some other way. Both are asserted here, independently.

;(function()
  -- The row, built exactly as the real ACTIONS screen builds it -- through
  -- Ui:install and the registered screen's own constructor, not a copy of
  -- the conditional written here. `mod.ui.Menu` is stubbed to hand the item
  -- list straight back rather than draw it, and `mod.content.screens` and
  -- `mod.hooks` are given just enough to let `install` register without
  -- throwing -- neither is touched by any other test in this file.
  local screenRegistry = {}
  stubMod.content.screens = {
    register = function(_, id, def) screenRegistry[id] = def end,
    get = function(_, id) return screenRegistry[id] end,
  }
  stubMod.hooks = { wrap = function() end }
  stubMod.ui = {
    Menu = { new = function(_, items, opts) return { items = items, opts = opts } end },
  }

  local ctx = { party = ann.party, roster = ann.roster, coop = ann.coop }
  local ui = Ui.new(ctx)
  local installed = pcall(function() ui:install() end)
  check(installed, "the real ACTIONS screen registers under a minimal stub")

  local def = screenRegistry[Ui.SCREEN.ACTIONS]
  check(def ~= nil, "and the screen the brief names is the one that registered")

  local function hasRow(playerId, label)
    local menu = def.new({}, { playerId = playerId })
    for _, item in ipairs(menu.items) do
      if item.label == label then return true end
    end
    return false
  end

  eq(hasRow(bob.id, "PARTY BATTLE"), false,
     "PARTY BATTLE is absent from your own partner's menu")
  eq(hasRow(cal.id, "PARTY BATTLE"), true,
     "and present against anybody else -- CAL is nobody's partner here")

  stubMod.content.screens, stubMod.hooks, stubMod.ui = nil, nil, nil
end)()

-- ------- partner gating: the guard makes the state unreachable
--
-- Even if the row above were forced, `challenge()` refuses a partner before
-- anything is written down: no ask, no message sent, and -- the bug this
-- closes -- no ~70s "You already asked" soft-lock, because self.ask is never
-- set in the first place.

;(function()
  ann.said = {}
  eq(ann.coop:challenge({}, { id = bob.client.id, name = "BOB", party = true },
                        "FIX_TOWN"), false,
     "PARTY BATTLE against your own partner is refused before anything is sent")
  check(said(ann, "already\non your team"),
        "and says so, naming the reason rather than staying silent")
  eq(ann.coop.ask, nil,
     "no ask is recorded -- the ~70s soft-lock (COOP_ASK_TIMEOUT + "
     .. "COOP_ASK_GRACE) has nothing left to grab onto")

  bob.peer.outbox = {}
  pump(bob)
  check(bob.confirmBox == nil, "and the partner is never asked at all")
end)()

-- ------- a dead party cannot enter a 2-on-2
--
-- Belt-and-braces: after the blackout rule the state should be unreachable,
-- but buildField refuses it anyway -- the first (and only) place full HP
-- exists before a field is built. Pure, against `Coop:buildField` directly,
-- the same way the badge and NPC-field tests elsewhere in this file drive it.

;(function()
  local Coop = need("Coop")
  local assembler = setmetatable({}, { __index = Coop })

  local function packed(hp) return { species = "FIXMON_A", level = 10, hp = hp } end
  local function planOf(over)
    local base = {
      hostId = "ann",
      allies = { { id = "ann", name = "ANN" }, { id = "bob", name = "BOB" } },
      foes = { { id = "cal", name = "CAL" }, { id = "dee", name = "DEE" } },
    }
    for k, v in pairs(over or {}) do base[k] = v end
    return base
  end
  local function build(parties, over)
    return assembler:buildField({}, { parties = parties, badges = {},
                                       plan = planOf(over) }, {})
  end

  local field = build({ ann = { packed(50) }, bob = { packed(50) },
                        cal = { packed(50) }, dee = { packed(50) } })
  check(field ~= nil, "a field where both sides can stand up assembles")

  local nilField, why, closeGroup = build({
    ann = { packed(0) }, bob = { packed(0) },
    cal = { packed(50) }, dee = { packed(50) },
  })
  eq(nilField, nil, "a side with nothing healthy is refused a field")
  check(tostring(why):find("healthy", 1, true) ~= nil,
        "and the reason names what is wrong")
  eq(closeGroup, true,
     "and asks the caller to close the group over it, not just abandon the "
     .. "assembly")

  local nilFieldB, whyB, closeB = build({
    ann = { packed(50) }, bob = { packed(50) },
    cal = { packed(0) }, dee = { packed(0) },
  })
  eq(nilFieldB, nil, "and refused from either side")
  eq(closeB, true, "with the same close-the-group answer")

  local mixed = build({
    ann = { packed(0) }, bob = { packed(50) },
    cal = { packed(50) }, dee = { packed(50) },
  })
  check(mixed ~= nil,
        "one fainted trainer beside a standing partner is not a wiped side "
        .. "-- there is still somebody to send out")

  -- A placeholder/string party carries no HP this host can read, and is
  -- deliberately NOT judged: "unreadable" is not "fainted".
  local placeholder = build({
    ann = { "GHOST" }, bob = { packed(50) },
    cal = { packed(50) }, dee = { packed(50) },
  })
  check(placeholder ~= nil,
        "a party this host cannot read HP from is not refused -- only a "
        .. "genuinely readable wipe is")
end)()

-- ------- fromHost: who may end the assembly, and who may not
--
-- `abort` and `field` are declarations about the battle as a whole, and only
-- the host's word counts -- everything else per-slot stays open, because the
-- battle checks the owner of each action itself.

;(function()
  local Coop = need("Coop")

  local named = setmetatable({ battle = { plan = { hostId = "ann" } } },
                              { __index = Coop })
  eq(named:fromHost("ann"), true, "the named host is believed")
  eq(named:fromHost("bob"), false, "and nobody else is")

  local permissive = setmetatable({ battle = { plan = {} } }, { __index = Coop })
  eq(permissive:fromHost("bob"), true,
     "a plan naming no host at all is permissive -- an older peer that never "
     .. "sent one must not break a battle")
  eq(permissive:fromHost(nil), true, "and so is a sender with no id of its own")

  -- ...and it is really what gates the two host-only messages, not merely
  -- what a unit test of fromHost alone would prove.
  local function client(hostId)
    return setmetatable({
      battle = { ready = false, plan = { hostId = hostId }, parties = {}, badges = {} },
      running = true,
      ui = { say = function() end },
      transport = { send = function() end, isReady = function() return true end },
      party = { isSelf = function() return false end, selfId = "ann" },
    }, { __index = Coop })
  end

  local c1 = client("ann")
  Coop.onMessage(c1, {}, { from = "cal", payload = { t = "abort" } })
  check(c1.battle ~= nil, "an abort claimed by a non-host does nothing")

  local c2 = client("ann")
  Coop.onMessage(c2, {}, { from = "ann", payload = { t = "abort" } })
  eq(c2.battle, nil, "the host's own abort closes the assembly")

  local c3 = client(nil)
  Coop.onMessage(c3, {}, { from = "cal", payload = { t = "abort" } })
  eq(c3.battle, nil,
     "with no host named, an abort is taken from anybody -- an older-peer "
     .. "compatibility case, not a hole")

  local c4 = client("ann")
  Coop.onMessage(c4, {}, { from = "cal",
    payload = { t = "field", field = { slots = {}, host = "cal" } } })
  check(c4.battle ~= nil and not c4.battle.ready,
        "a field claimed by a non-host is never built")
end)()

-- ------- tryStart: a dead-party host relays abort, never field, then leaves
--
-- No hub needed here -- tryStart's whole job is deciding what to send, and a
-- fake transport can watch that as well as a real one.

;(function()
  local Coop = need("Coop")
  local function packed(hp) return { species = "FIXMON_A", level = 10, hp = hp } end

  local sent, saidText = {}, {}
  local host = setmetatable({
    transport = {
      send = function(_, t, payload) sent[#sent + 1] = { type = t, payload = payload } end,
      isReady = function() return true end,
    },
    ui = { say = function(_, text) saidText[#saidText + 1] = text end },
    party = { selfId = "ann", isSelf = function(_, id) return id == "ann" end },
    running = true,
    battle = {
      host = true, ready = false,
      parties = { ann = { packed(0) }, bob = { packed(0) },
                  cal = { packed(50) }, dee = { packed(50) } },
      badges = {},
      plan = {
        hostId = "ann",
        allies = { { id = "ann", name = "ANN" }, { id = "bob", name = "BOB" } },
        foes = { { id = "cal", name = "CAL" }, { id = "dee", name = "DEE" } },
      },
    },
  }, { __index = Coop })

  Coop.tryStart(host, {})

  -- transport:send's second argument is `{ payload = <relay payload> }` --
  -- the wrapper `coopSide`'s fake transport flattens elsewhere in this file,
  -- and this harness deliberately does not, so it is unwrapped here instead.
  local sawAbort, sawField, sawLeave = false, false, false
  for _, m in ipairs(sent) do
    local relayed = type(m.payload) == "table" and m.payload.payload
    if m.type == Wire.COOP_RELAY and type(relayed) == "table"
       and relayed.t == "abort" then sawAbort = true end
    if m.type == Wire.COOP_RELAY and type(relayed) == "table"
       and relayed.t == "field" then sawField = true end
    if m.type == Wire.COOP_LEAVE then sawLeave = true end
  end
  check(sawAbort, "a dead-party host relays an abort")
  check(not sawField,
        "and never relays the field that would have started a broken battle")
  check(sawLeave,
        "and says goodbye -- the same one-goodbye-closes-all a finished "
        .. "battle uses")
  eq(host.battle, nil, "its own assembly is abandoned")
  eq(host.running, false, "and it is no longer marked mid-battle")
end)()

-- ------- the ask box: only ever taken down when it is what is on screen
--
-- unwindTo pops up to sixteen states hunting for its target; aimed at a box
-- that is buried under something the player opened on purpose, that would
-- throw the wrong thing away. So closeAskBox only ever pops the box when it
-- is genuinely on top -- and forgets the held reference either way, because
-- there is nothing left for a stale one to do.

;(function()
  local Coop = need("Coop")
  local function stackOf()
    return {
      states = {},
      top = function(self) return self.states[#self.states] end,
      pop = function(self) return table.remove(self.states) end,
      push = function(self, st) self.states[#self.states + 1] = st end,
    }
  end

  -- The ordinary case: the box is what the player is looking at.
  local stack1 = stackOf()
  local box1 = { name = "askbox" }
  stack1:push(box1)
  local c1 = setmetatable({ askBox = { box = box1, game = { stack = stack1 } } },
                           { __index = Coop })
  eq(c1:closeAskBox(), true, "a box that is top-of-stack is taken down")
  eq(#stack1.states, 0, "and really comes off the stack")
  eq(c1.askBox, nil, "and is forgotten either way")

  -- Buried: something was pushed on top of it -- a battle screen, in the
  -- real bug. Left exactly alone rather than popped blind.
  local stack2 = stackOf()
  local box2 = { name = "askbox" }
  stack2:push(box2)
  stack2:push({ name = "battle" })
  local c2 = setmetatable({ askBox = { box = box2, game = { stack = stack2 } } },
                           { __index = Coop })
  eq(c2:closeAskBox(), false, "a buried box is left exactly where it is")
  eq(#stack2.states, 2, "nothing is popped hunting for it")
  eq(c2.askBox, nil,
     "but the held reference is dropped either way -- there is nothing left "
     .. "this ask owns")

  -- No box at all: harmless.
  local c3 = setmetatable({}, { __index = Coop })
  eq(c3:closeAskBox(), false, "nothing to close is not an error")

  -- A box already gone from the stack some other way is not hunted for
  -- either.
  local stack4 = stackOf()
  stack4:push({ name = "something else" })
  local c4 = setmetatable({
    askBox = { box = { name = "gone" }, game = { stack = stack4 } },
  }, { __index = Coop })
  eq(c4:closeAskBox(), false,
     "a box that is no longer on the stack at all is left alone rather than "
     .. "hunted for")
  eq(#stack4.states, 1, "so the state that is there is untouched")

  -- ------- and every resolution path really calls it
  local function bareCoop(askBox)
    return setmetatable({ askBox = askBox, ui = { say = function() end } },
                         { __index = Coop })
  end

  local d1 = bareCoop({ box = {}, game = {} })
  d1:onDecline({ reason = "declined" })
  eq(d1.askBox, nil, "onDecline takes the asker's box down")

  local d2 = bareCoop({ box = {}, game = {} })
  d2.ask = { role = "asker", peer = "cal" }
  d2:onPeerGone("cal")
  eq(d2.askBox, nil, "so does losing the peer the ask was aimed at")

  local d3 = bareCoop({ box = {}, game = {} })
  d3.ask = { role = "asker" }
  d3:onPartyEnd()
  eq(d3.askBox, nil, "and so does the party dissolving mid-ask")

  local d4 = bareCoop({ box = {}, game = {} })
  d4.ask = { role = "asker",
             clock = Config.COOP_ASK_TIMEOUT + Config.COOP_ASK_GRACE }
  d4.transport = { send = function() end }
  d4.clock = 0
  d4:update(0)
  eq(d4.askBox, nil, "and so does the deadline backstop")

  local d5 = bareCoop({ box = {}, game = {} })
  d5:onBattle({}, { side = "not-a-side" })
  eq(d5.askBox, nil, "and the ask being resolved -- reaching a real battle")

  local d6 = bareCoop({ box = {}, game = {} })
  d6:reset()
  eq(d6.askBox, nil, "and a full reset")
end)()

-- ------- blackout: one rule, healed and taxed and sent home
--
-- Coop.blacksOut, Coop:consume's translation, and Coop:blackout's mod-side
-- ritual for the battle the engine never ran -- a party-versus-party co-op
-- battle, or a won trainer battle whose winner's own team was wiped.

;(function()
  local Coop = need("Coop")

  -- ------- blacksOut: the matrix

  eq(Coop.blacksOut("loss", { save = { party = {} } }), true,
     "a reported loss blacks out regardless of what the party looks like")

  local wiped = { save = { party = {
    { hp = 0, stats = { hp = 50 } }, { hp = 0, stats = { hp = 30 } },
  } } }
  eq(Coop.blacksOut("win", wiped), true,
     "a win with nothing left standing blacks out too -- the engine's own "
     .. "safety net, adopted here because consume steps around it")
  eq(Coop.blacksOut("draw", wiped), true, "and so does a wiped draw")

  local standing = { save = { party = {
    { hp = 0, stats = { hp = 50 } }, { hp = 10, stats = { hp = 30 } },
  } } }
  eq(Coop.blacksOut("win", standing), false,
     "one monster still standing is not a blackout")
  eq(Coop.blacksOut("draw", standing), false, "on a draw either")

  eq(Coop.blacksOut("win", { save = { party = {} } }), false,
     "an empty party is never a blackout -- there is no team to have lost")
  eq(Coop.blacksOut("win", { save = {} }), false,
     "nor a save with no party at all")
  eq(Coop.blacksOut("win", nil), false, "nor no game at all")

  -- ------- healPoint: save's own Center, then the world's boot heal, then spawn

  eq(Coop.healPoint({ save = { lastHeal = { map = "CENTER", x = 3, y = 4 } } }).map,
     "CENTER", "the save's own last heal wins when there is one")
  eq(Coop.healPoint({
    save = {}, data = { field = { boot = { lastHeal = { map = "BOOT_CENTER" } } } },
  }).map, "BOOT_CENTER",
     "falling back to the world's declared boot heal point")
  local spawnOnly = Coop.healPoint({
    save = {},
    data = { field = { boot = { startMap = "PALLET", startX = 5, startY = 6 } } },
  })
  eq(spawnOnly.map, "PALLET", "and finally the spawn cell")
  eq(spawnOnly.x, 5, "with its coordinates")
  eq(Coop.healPoint({ save = {}, data = {} }), nil,
     "nil for a build with no field data at all, rather than a guessed map")

  -- ------- healParty: the Pokemon.heal mirror

  local movesData = { FIX_TACKLE = { pp = 20 } }
  local party = {
    { stats = { hp = 60 }, hp = 1, status = "PSN",
      moves = { { id = "FIX_TACKLE", pp = 2, ppUps = 1 } } },
  }
  check(Coop.healParty({ data = { moves = movesData }, save = { party = party } }),
        "healParty runs over a real save")
  eq(party[1].hp, 60, "hp goes to the stat")
  eq(party[1].status, nil, "status clears")
  eq(party[1].moves[1].pp, 24,
     "and PP restores to base plus the PP UP bonus (20 + floor(20/5)*1)")
  eq(Coop.healParty({ save = {} }), false,
     "no party at all is answered rather than thrown through")

  -- ------- consume: the translation, and who ends up owing the ritual

  local c1 = setmetatable({}, { __index = Coop })
  eq(c1:consume("win", false), false, "no encounter at all: nothing to consume")

  local c2 = setmetatable({ encounter = { engine = {} } }, { __index = Coop })
  eq(c2:consume("win", false), false,
     "an engine with no onFinish is the same as no engine")
  eq(c2.encounter, nil, "but the encounter is still spent either way")

  local seen
  local c3 = setmetatable({
    encounter = { engine = { onFinish = function(r) seen = r end } },
  }, { __index = Coop })
  local handled3, ritual3 = c3:consume("loss", true)
  eq(seen, "lose",
     "a reported loss with blackout owed is translated to the engine's own "
     .. "word -- \"loss\" would have skipped afterBattle's ritual entirely")
  eq(handled3, true, "the engine took the battle")
  eq(ritual3, true, "and ran its own ritual -- ours is not owed")

  seen = nil
  local c4 = setmetatable({
    encounter = { engine = { onFinish = function(r) seen = r end } },
  }, { __index = Coop })
  local handled4, ritual4 = c4:consume("win", true)
  eq(seen, "win",
     "a WIN is never translated, even with the party wiped -- "
     .. "Commands.start_battle reads it back as ctx.lastCheck")
  eq(ritual4, false, "so the ritual it did not run is still owed to us")

  seen = nil
  local c5 = setmetatable({
    encounter = { engine = { onFinish = function(r) seen = r end } },
  }, { __index = Coop })
  local handled5, ritual5 = c5:consume("draw", false)
  eq(seen, "draw", "no blackout owed: the result passes through untranslated")
  eq(ritual5, false, "and nothing is owed on either side")

  -- A throwing onFinish still spends the encounter, and hands the ritual
  -- back to the caller -- the engine never got as far as running its own.
  local warnings = {}
  stubMod.log.warn = function(_, fmt, ...)
    local ok, line = pcall(string.format, fmt, ...)
    warnings[#warnings + 1] = ok and line or tostring(fmt)
  end
  local c6 = setmetatable({
    encounter = { engine = { onFinish = function() error("boom") end } },
  }, { __index = Coop })
  local handled6, ritual6 = c6:consume("loss", true)
  eq(handled6, true, "the engine 'took' the battle -- there is no third state")
  eq(ritual6, false, "but its ritual never ran, so ours is still owed")
  check(#warnings > 0, "and the failure is said out loud, not swallowed")

  -- Prize money: at the level of the trainer's strongest monster, before the
  -- blackout that would otherwise tax it away.
  local save7 = { money = 100 }
  local c7 = setmetatable({
    encounter = {
      game = { save = save7 },
      engine = { onFinish = function() end, trainer = { baseMoney = 10 },
                 enemyParty = { { level = 5 }, { level = 12 } } },
    },
  }, { __index = Coop })
  c7:consume("win", false)
  eq(save7.money, 220,
     "the prize is baseMoney * the strongest opponent's level (10 * 12), "
     .. "added to what was already there")

  local save8 = { money = 999990 }
  local c8 = setmetatable({
    encounter = {
      game = { save = save8 },
      engine = { onFinish = function() end, trainer = { baseMoney = 100 },
                 enemyParty = { { level = 50 } } },
    },
  }, { __index = Coop })
  c8:consume("win", false)
  eq(save8.money, 999999, "and the prize is capped rather than overflowing")

  -- ------- blackout / pumpBlackout: heal and tax now, warp when the screen
  -- comes free

  local calls = {}
  stubMod.world = {
    warpTo = function(_, map, x, y, facing)
      calls[#calls + 1] = { map = map, x = x, y = y, facing = facing }
      return true
    end,
  }

  warnings = {}
  local nosave = setmetatable({}, { __index = Coop })
  eq(nosave:blackout({}), false, "a blackout with no save to write is refused")
  check(#warnings > 0, "and says so")

  -- The ordinary case: nothing on top of the world but the world itself, so
  -- the warp fires in the same call.
  warnings, calls = {}, {}
  local moves = { FIX_TACKLE = { pp = 20 } }
  local game1 = {
    data = { moves = moves },
    save = {
      money = 101, forcedBike = true,
      party = { { stats = { hp = 40 }, hp = 0, status = "PSN",
                  moves = { { id = "FIX_TACKLE", pp = 0 } } } },
      lastHeal = { map = "PALLET_CENTER", x = 3, y = 4 },
    },
    stack = { top = function() return { isOverworld = true } end },
  }
  local ok1 = setmetatable({}, { __index = Coop })
  local fired1 = ok1:blackout(game1)
  eq(fired1, true,
     "with nothing covering the world, the warp fires in the same call as "
     .. "the rest of the ritual")
  eq(game1.save.party[1].hp, 40, "the party is healed first")
  eq(game1.save.party[1].status, nil, "status cleared")
  eq(game1.save.party[1].moves[1].pp, 20, "PP restored")
  eq(game1.save.money, 50, "money halved and floored (101 / 2)")
  eq(game1.save.forcedBike, nil, "and the forced-bike flag cleared")
  eq(#calls, 1, "exactly one warp went out")
  eq(calls[1].map, "PALLET_CENTER", "to this player's own last heal")
  eq(ok1.pendingWarp, nil,
     "and nothing is left waiting for a screen that already arrived")

  -- Deferred: a menu is up, so the warp waits -- and fires once, when the
  -- world comes back on top.
  warnings, calls = {}, {}
  local topRef = { isOverworld = false }
  local game2 = {
    data = { moves = moves },
    save = {
      money = 10, party = { { stats = { hp = 30 }, hp = 0, moves = {} } },
      lastHeal = { map = "VIRIDIAN_CENTER", x = 1, y = 1 },
    },
    stack = { top = function() return topRef end },
  }
  local ok2 = setmetatable({}, { __index = Coop })
  local fired2 = ok2:blackout(game2)
  eq(fired2, false, "a menu on top of the world defers the warp")
  eq(#calls, 0, "so nothing has warped yet")
  check(ok2.pendingWarp ~= nil, "and a warp is held, waiting for the screen")
  eq(game2.save.party[1].hp, 30,
     "the heal already landed, though -- it is a save write, not a screen")

  topRef.isOverworld = true
  eq(ok2:pumpBlackout(0.5), true,
     "the deferred warp fires once the world is back on top")
  eq(#calls, 1, "exactly once")
  eq(ok2.pendingWarp, nil, "and the wait is spent")

  eq(ok2:pumpBlackout(0.5), false,
     "pumping again with nothing pending does nothing")
  eq(#calls, 1, "still just the one warp")

  -- Expiry: the world never comes back, and the wait gives up rather than
  -- firing blind.
  warnings, calls = {}, {}
  local stuck = { isOverworld = false }
  local game3 = {
    data = { moves = moves },
    save = { money = 10, party = {}, lastHeal = { map = "X" } },
    stack = { top = function() return stuck end },
  }
  local ok3 = setmetatable({}, { __index = Coop })
  ok3:blackout(game3)
  check(ok3.pendingWarp ~= nil, "armed, waiting on a screen that never clears")
  eq(ok3:pumpBlackout(61), false, "past the wait, the warp gives up")
  eq(ok3.pendingWarp, nil,
     "and disarms rather than firing blind wherever the player has wandered "
     .. "to by then")
  check(#warnings > 0, "and says so")
  eq(#calls, 0, "no warp ever went out")

  -- No heal point anywhere: healed and taxed, but told rather than guessed.
  warnings = {}
  local game4 = { data = {}, save = { money = 10, party = {} } }
  local ok4 = setmetatable({}, { __index = Coop })
  eq(ok4:blackout(game4), false,
     "with nowhere to send the player, the warp is declined rather than "
     .. "guessed")
  check(#warnings > 0, "and said out loud")
  eq(ok4.pendingWarp, nil,
     "nothing is left armed for a target that does not exist")

  -- Divisor: the world's own constant, when it names one; two otherwise.
  local gameDiv = {
    data = { moves = {}, constants = { world = { blackoutMoneyDivisor = 4 } } },
    save = { money = 100, party = {} },
    stack = { top = function() return { isOverworld = true } end },
  }
  local okDiv = setmetatable({}, { __index = Coop })
  okDiv:blackout(gameDiv)
  eq(gameDiv.save.money, 25,
     "a world that names its own divisor is honoured (100 / 4)")

  stubMod.world = nil
  stubMod.log.warn = function() end
end)()

-- ------- the party dissolving takes the co-op with it

ann.coop.running = false
ann.said = {}
engage(ann)
pick(ann, "WAIT")
eq(ann.coop:isWaiting(), true, "ANN is waiting again")
bob.party:leave()
pump(ann)
eq(ann.coop:isWaiting(), false, "BOB leaving the party ends the wait")
if ann.sayDone then ann.sayDone() end
check(fightsAlone(ann),
      "and hands the trainer back rather than leaving ANN standing there")

end)()

-- ------- the host port is overridable, and the default address follows it
--
-- Two end-to-end runs on one machine used to host on the same port, so the
-- second silently joined the first's game -- which surfaced as a roster that
-- had strangers in it rather than as the harness collision it was.

;(function()
  local Config = need("Config")
  check(Config.DEFAULT_PORT > 0 and Config.DEFAULT_PORT < 65536,
        "the default port is a port")
  eq(Config.DEFAULT_HUB, ("127.0.0.1:%d"):format(Config.DEFAULT_PORT),
     "and the default address is built from it rather than repeating a literal")
end)()

-- ------- the 2-on-2 simulation
--
-- CoopSim is the part Gen1Recomp does not have: four battlers on one field,
-- an ordering over all of them, a target on every action, and a side that
-- loses only when both its trainers are out of mons.
--
-- Damage is injected as a flat stub here **on purpose**. The engine already
-- owns the damage formula and already tests it; what has never existed before
-- is the field around it, so these checks are about turn order, targeting,
-- redirection, faints, send-outs and the win condition -- each of which would
-- be invisible under a random roll.

;(function()

local CoopSim = need("CoopSim")

local DATA = {
  pokemon = {
    RATTATA = { name = "RATTATA", types = { "NORMAL" }, baseStats = { speed = 72 } },
    PIDGEY  = { name = "PIDGEY",  types = { "NORMAL" }, baseStats = { speed = 56 } },
    SLOWPOKE= { name = "SLOWPOKE",types = { "WATER" },  baseStats = { speed = 15 } },
  },
  moves = {
    TACKLE = { id = "TACKLE", name = "TACKLE", power = 40, type = "NORMAL",
               accuracy = 100, category = "physical" },
    GROWL  = { id = "GROWL",  name = "GROWL",  power = 0,  type = "NORMAL",
               accuracy = 100, category = "status" },
    QUICK  = { id = "QUICK_ATTACK", name = "QUICK ATTACK", power = 40,
               type = "NORMAL", accuracy = 100, category = "physical" },
  },
}
DATA.moves.QUICK_ATTACK = DATA.moves.QUICK

local function mon(species, hp, speed, moves)
  return {
    species = species, level = 10, hp = hp,
    stats = { hp = hp, attack = 20, defense = 20, special = 20, speed = speed },
    moves = moves or { { id = "TACKLE", pp = 20 } },
  }
end

-- A fixed 10 a hit, so every assertion below is about the field and never
-- about a roll.
local FLAT = {
  compute = function() return 10, { crit = false, typeMult = 10 } end,
  accuracyRoll = function() return true end,
}

local function build(slots)
  return CoopSim.new({
    data = DATA, ruleset = {}, damage = FLAT,
    rng = function(a) return a end,
  }, slots)
end

local function fourWay()
  return build({
    { side = "a", owner = "ann", name = "ANN",
      party = { mon("RATTATA", 30, 72) } },
    { side = "a", owner = "bob", name = "BOB",
      party = { mon("SLOWPOKE", 30, 15) } },
    { side = "b", owner = nil, name = "FOE",
      party = { mon("PIDGEY", 30, 56) } },
    { side = "b", owner = nil, name = "FOE",
      party = { mon("PIDGEY", 30, 56) } },
  })
end

-- ------- four on the field, which is the whole point

local sim = fourWay()
eq(#sim.slots, 4, "a co-op battle has four slots")
eq(#sim:living(), 4, "all four start standing")
eq(#sim:living("a"), 2, "two to a side")
eq(#sim:targetsFor(sim:slot(1)), 2, "and two things to aim at")
eq(sim:targetsFor(sim:slot(1))[1].side, "b", "which are the opponents")
eq(sim:targetsFor(sim:slot(3))[1].side, "a", "from either side")

-- an ally is never a target: Gen 1 has no move that wants one
for _, target in ipairs(sim:targetsFor(sim:slot(1))) do
  check(target.index ~= 2, "your partner is not on your target list")
end

-- ------- ordering over four, not two pairs

local order = sim:order({
  { slot = 1, move = 1, target = 3 },   -- RATTATA, speed 72
  { slot = 2, move = 1, target = 3 },   -- SLOWPOKE, speed 15
  { slot = 3, move = 1, target = 1 },   -- PIDGEY, speed 56
  { slot = 4, move = 1, target = 1 },   -- PIDGEY, speed 56
})
eq(#order, 4, "every living slot gets a place in the turn")
eq(order[1].slot.index, 1, "the fastest of all four moves first")
eq(order[4].slot.index, 2, "and the slowest of all four moves last")
-- the two identical PIDGEYs are ordered by slot, not by a coin flip: four
-- clients have to agree, and a per-pair roll would give four answers
eq(order[2].slot.index, 3, "a speed tie breaks on slot index...")
eq(order[3].slot.index, 4, "...stably, so every client agrees")

-- Priority beats speed, across all four -- and the move it reads is looked up
-- against the battler that is out, because an action carries a *slot in the
-- move list* and not a move record.
local quick = build({
  { side = "a", owner = "ann", name = "ANN",
    party = { mon("SLOWPOKE", 30, 15, { { id = "QUICK_ATTACK", pp = 20 } }) } },
  { side = "a", owner = "bob", name = "BOB", party = { mon("RATTATA", 30, 72) } },
  { side = "b", owner = nil, name = "FOE", party = { mon("PIDGEY", 30, 56) } },
  { side = "b", owner = nil, name = "FOE", party = { mon("PIDGEY", 30, 4) } },
})
local priority = quick:order({
  { slot = 2, move = 1, target = 3 },   -- speed 72, ordinary move
  { slot = 1, move = 1, target = 3 },   -- speed 15, QUICK ATTACK
})
eq(priority[1].slot.index, 1,
   "a priority move goes first even from the slowest thing on the field")

-- ------- a turn resolves, and damage lands on the chosen target

sim = fourWay()
local events = sim:resolveTurn({
  { slot = 1, move = 1, target = 4 },
  { slot = 2, move = 1, target = 4 },
  { slot = 3, move = 1, target = 1 },
  { slot = 4, move = 1, target = 1 },
})
check(#events > 0, "a turn produces events")
eq(sim:slot(4).battler.mon.hp, 10, "both allies hit the target they chose")
eq(sim:slot(3).battler.mon.hp, 30, "and the one they did not is untouched")
eq(sim:slot(1).battler.mon.hp, 10, "while both foes concentrated on one ally")

-- PP is spent
eq(sim:slot(1).battler.curMoves[1].pp, 19, "using a move spends a PP")

-- ------- a target that falls mid-turn redirects rather than fizzling
--
-- Ordinary in a four-way field and near-impossible in a 1v1: the fast ally
-- knocks the target over before the slow one swings at it.

sim = build({
  { side = "a", owner = "ann", name = "ANN", party = { mon("RATTATA", 30, 72) } },
  { side = "a", owner = "bob", name = "BOB", party = { mon("RATTATA", 30, 60) } },
  { side = "b", owner = nil, name = "FOE", party = { mon("PIDGEY", 10, 5) } },
  { side = "b", owner = nil, name = "FOE", party = { mon("PIDGEY", 30, 4) } },
})
sim:resolveTurn({
  { slot = 1, move = 1, target = 3 },
  { slot = 2, move = 1, target = 3 },
})
check(sim:isDown(sim:slot(3)), "the first attacker knocks the target out")
eq(sim:slot(4).battler.mon.hp, 20,
   "and the second swings at whoever is still standing instead of losing its turn")

-- ------- a faint pulls the next mon out of that trainer's own party

sim = build({
  { side = "a", owner = "ann", name = "ANN", party = { mon("RATTATA", 30, 72) } },
  { side = "a", owner = "bob", name = "BOB", party = { mon("RATTATA", 30, 60) } },
  { side = "b", owner = nil, name = "FOE",
    party = { mon("PIDGEY", 10, 5), mon("SLOWPOKE", 25, 5) } },
  { side = "b", owner = nil, name = "FOE", party = { mon("PIDGEY", 30, 4) } },
})
events = sim:resolveTurn({ { slot = 1, move = 1, target = 3 } })
eq(sim:slot(3).battler.mon.species, "SLOWPOKE",
   "a fainted slot sends out that trainer's next mon")
eq(sim:slot(3).active, 2, "and remembers which one is out")
local sawSend = false
for _, event in ipairs(events) do
  if event.kind == "send" then sawSend = true end
end
check(sawSend, "and says so in an event, so the replayers follow")

-- ------- a side loses only when BOTH its trainers are out

sim = build({
  { side = "a", owner = "ann", name = "ANN", party = { mon("RATTATA", 30, 72) } },
  { side = "a", owner = "bob", name = "BOB", party = { mon("RATTATA", 30, 60) } },
  { side = "b", owner = nil, name = "FOE", party = { mon("PIDGEY", 10, 5) } },
  { side = "b", owner = nil, name = "FOE", party = { mon("PIDGEY", 10, 4) } },
})
sim:resolveTurn({ { slot = 1, move = 1, target = 3 } })
eq(sim.over, nil, "one opponent down is not a win")
check(sim:isDown(sim:slot(3)), "even though that slot is empty")
eq(sim:sideBeaten("b"), false, "because the other trainer is still there")

events = sim:resolveTurn({ { slot = 1, move = 1, target = 4 } })
eq(sim.over, "a", "both of them down is a win for the other side")
local sawOver = false
for _, event in ipairs(events) do
  if event.kind == "over" then sawOver = true end
end
check(sawOver, "announced as an event like everything else")

-- a battle that is over resolves nothing further
eq(#sim:resolveTurn({ { slot = 1, move = 1, target = 4 } }), 0,
   "and a finished battle takes no more turns")

-- ------- an NPC picks for itself, and picks sensibly

sim = build({
  { side = "a", owner = "ann", name = "ANN", party = { mon("RATTATA", 30, 72) } },
  { side = "a", owner = "bob", name = "BOB", party = { mon("RATTATA", 8, 60) } },
  { side = "b", owner = nil, name = "FOE",
    party = { mon("PIDGEY", 30, 56,
      { { id = "GROWL", pp = 20 }, { id = "TACKLE", pp = 20 } }) } },
  { side = "b", owner = nil, name = "FOE", party = { mon("PIDGEY", 30, 4) } },
})
local npc = sim:npcAction(sim:slot(3))
check(npc ~= nil, "an unowned slot chooses its own action")
eq(npc.move, 2, "taking the move with power over the one without")
eq(npc.target, 2, "and aiming at the opponent closest to falling")

-- ------- a slot nobody filed an action for is skipped, not defaulted

sim = fourWay()
events = sim:resolveTurn({ { slot = 1, move = 1, target = 3 } })
eq(sim:slot(3).battler.mon.hp, 20, "the one action that was filed happens")
eq(sim:slot(1).battler.mon.hp, 30,
   "and a slot with no action does nothing rather than guessing a move")

-- ------- defaultAction: what the deadline files for a slot nobody answered
--
-- Not an AI, and not a description of one -- the exact legality rules the
-- turn deadline leans on: the first move that still has PP, at the first
-- living opponent, and nil for anything that cannot act at all.

;(function()
  local function fieldOf(moves1)
    return build({
      { side = "a", owner = "ann", name = "ANN",
        party = { mon("RATTATA", 30, 72, moves1) } },
      { side = "a", owner = "bob", name = "BOB", party = { mon("RATTATA", 30, 60) } },
      { side = "b", owner = nil, name = "FOE", party = { mon("PIDGEY", 10, 5) } },
      { side = "b", owner = nil, name = "FOE", party = { mon("PIDGEY", 30, 4) } },
    })
  end

  local live = fieldOf({ { id = "GROWL", pp = 0 }, { id = "TACKLE", pp = 20 } })
  local action = live:defaultAction(1)
  check(action ~= nil, "a slot that can act gets an action")
  eq(action.move, 2, "the first move that still has PP -- not the one the "
     .. "menu would offer first")
  eq(action.target, 3, "aimed at the first living opponent")

  local spent = fieldOf({ { id = "TACKLE", pp = 0 }, { id = "GROWL", pp = 0 } })
  eq(spent:defaultAction(1).move, 1,
     "nothing left in any move falls back to the first slot -- runAction is "
     .. "what turns it into Struggle, not this file inventing a move")

  local down = fieldOf(nil)
  down:slot(1).battler.mon.hp = 0
  eq(down:defaultAction(1), nil, "a fainted slot gets nothing to file")

  local gone = fieldOf(nil)
  gone:forfeit("bob")
  eq(gone:defaultAction(2), nil, "and neither does a slot that has left")

  local stranded = fieldOf(nil)
  stranded:slot(3).battler.mon.hp = 0
  stranded:slot(4).battler.mon.hp = 0
  eq(stranded:defaultAction(1), nil,
     "and a slot that could act gets nothing either, once there is no living "
     .. "opponent left to aim a default at")

  eq(live:defaultAction(99), nil,
     "an index the field does not have answers nil, not an error")
end)()

end)()

-- ------- the engine's own move effects, on a four-slot field
--
-- This is the block that justifies src/CoopField.lua existing.
--
-- The claim it has to support is not "damage happens" -- the block above
-- already covers the field, and the engine already tests damage. It is that
-- **the engine's real `performMove` runs against four slots**, with the real
-- `move_effects` records behind it. If that is true, then charge moves, stat
-- stages, Substitute, recoil, multi-hit and everything else in the registry
-- work in a co-op battle for free, because none of them are reimplemented.
--
-- So: real BattleState, real EffectRegistry, real effect records from the
-- fixture dataset, driven through the adapter.

;(function()

local CoopSim = need("CoopSim")
local CoopField = need("CoopField")

local okBS, BattleState = pcall(require, "src.battle.BattleState")
if not okBS then
  check(false, "BattleState is requirable headlessly")
  return
end

-- The fixture dataset, plus two moves built on real effect records. The
-- records are the engine's; only the moves pointing at them are ours, because
-- the fixture ships four moves and none of them charge.
-- Loaded through the SDK rather than T.fixtures: the effect *records* are
-- merged registry content (the engine registers MoveEffects into it), and a
-- bare fixture table carries the moves without them.
local base = T.sdk.loadNone()
local fixtures = base.data
local data = {}
for k, v in pairs(fixtures) do data[k] = v end
data.moves = {}
for k, v in pairs(fixtures.moves or {}) do data.moves[k] = v end

check(data.move_effects ~= nil, "the fixture carries the engine's effect records")
check(data.move_effects.ATTACK_UP1_EFFECT ~= nil, "including a stat-stage one")
check(data.move_effects.CHARGE_EFFECT ~= nil, "and a charge one")

data.moves.FIX_BOOST = {
  id = "FIX_BOOST", name = "FIX BOOST", power = 0, accuracy = 100,
  type = "NORMAL", category = "status", pp = 20,
  effect = "ATTACK_UP1_EFFECT",
}
-- The engine's own STRUGGLE record, which the fixture dataset does not carry.
-- Recoil is what makes it Struggle rather than a weak Normal move, so the
-- effect is named rather than left off.
data.moves.STRUGGLE = {
  id = "STRUGGLE", name = "STRUGGLE", power = 50, accuracy = 100,
  type = "NORMAL", category = "physical", pp = 1,
  effect = data.move_effects and data.move_effects.RECOIL_EFFECT
    and "RECOIL_EFFECT" or nil,
}

data.moves.FIX_CHARGE = {
  id = "FIX_CHARGE", name = "FIX CHARGE", power = 40, accuracy = 100,
  type = "NORMAL", category = "physical", pp = 10,
  effect = "CHARGE_EFFECT",
}

-- Status- and volatile-inducing moves, each pointing at the engine's own
-- move_effects record -- sleep, a flinch chance, Hyper Beam's recharge and
-- Leech Seed's drain, reached through this same adapter rather than a
-- description of any of them written here.
check(data.move_effects.SLEEP_EFFECT ~= nil, "a sleep-inducing record")
check(data.move_effects.FLINCH_SIDE_EFFECT1 ~= nil, "a flinch side effect")
check(data.move_effects.HYPER_BEAM_EFFECT ~= nil, "a recharge one")
check(data.move_effects.LEECH_SEED_EFFECT ~= nil, "and a Leech Seed one")

data.moves.FIX_SLEEP = {
  id = "FIX_SLEEP", name = "FIX SLEEP", power = 0, accuracy = 100,
  type = "NORMAL", category = "status", pp = 20, effect = "SLEEP_EFFECT",
}
data.moves.FIX_FLINCH = {
  id = "FIX_FLINCH", name = "FIX FLINCH", power = 30, accuracy = 100,
  type = "NORMAL", category = "physical", pp = 20,
  effect = "FLINCH_SIDE_EFFECT1",
}
data.moves.FIX_HYPER = {
  id = "FIX_HYPER", name = "FIX HYPER", power = 150, accuracy = 100,
  type = "NORMAL", category = "special", pp = 5, effect = "HYPER_BEAM_EFFECT",
}
data.moves.FIX_LEECH = {
  id = "FIX_LEECH", name = "FIX LEECH", power = 0, accuracy = 100,
  type = "GRASS", category = "status", pp = 20, effect = "LEECH_SEED_EFFECT",
}

local species = "FIXMON_A"
local function mon(hp, speed, moves)
  return {
    species = species, level = 20, hp = hp,
    stats = { hp = hp, attack = 30, defense = 30, special = 30, speed = speed },
    moves = moves,
  }
end

local game = {
  data = data,
  save = { inventory = {}, options = {}, party = {} },
}
local ruleset = (data.rulesets and data.rulesets.gen1_faithful) or {}

local function fieldSim(slots)
  local rng = function(a) return a end
  local holder = {}
  local field = CoopField.new(
    { BattleState = BattleState, rng = rng }, game, holder, ruleset)
  local sim = CoopSim.new({
    data = data, ruleset = ruleset, rng = rng,
    trainerAI = require("src.battle.TrainerAI"),
    damage = require("src.battle.Damage"),
    status = require("src.battle.Status"),
    turnOrder = require("src.battle.TurnOrder"),
    field = field, drain = CoopField.drain,
    -- The engine's own battler builder, which is what the real client hands
    -- in. Without it every test here ran against CoopSim's fallback -- a
    -- different object, with no sprite, no merged registries and no badges --
    -- so anything that depends on how a battler is *built* was untested.
    makeBattler = BattleState.makeBattler,
    itemUse = require("src.inventory.ItemEffects").use,
    experience = require("src.battle.Experience"),
    save = game.save,
    -- Surfaced rather than swallowed: a move that throws inside the engine's
    -- pipeline is exactly the failure this block exists to catch, and a silent
    -- pcall here would have let the charge-release bug pass as "no damage".
    onError = function(err) check(false, "a move resolved cleanly: " .. tostring(err)) end,
  }, slots)
  field.slots = sim.slots
  return sim, field
end

-- A variant of `fieldSim` with the rng swapped out. The status gate's own
-- rolls -- paralysis's full-stop, confusion's self-hit -- are deterministic
-- under the fixture rng (`function(a) return a end` always answers its lower
-- bound), so proving the *other* branch of either needs a purpose-built one.
local function fieldSimRng(rngFn, slots)
  local holder = {}
  local field = CoopField.new(
    { BattleState = BattleState, rng = rngFn }, game, holder, ruleset)
  local sim = CoopSim.new({
    data = data, ruleset = ruleset, rng = rngFn,
    trainerAI = require("src.battle.TrainerAI"),
    damage = require("src.battle.Damage"),
    status = require("src.battle.Status"),
    turnOrder = require("src.battle.TurnOrder"),
    field = field, drain = CoopField.drain,
    makeBattler = BattleState.makeBattler,
    itemUse = require("src.inventory.ItemEffects").use,
    experience = require("src.battle.Experience"),
    save = game.save,
    onError = function(err) check(false, "a move resolved cleanly: " .. tostring(err)) end,
  }, slots)
  field.slots = sim.slots
  return sim, field
end

-- Clears the paralysis (63/256) and confusion self-hit (128/256) thresholds
-- -- one short of the upper bound handed to the roll, rather than the bound
-- itself: `gen1_faithful.oneIn256Miss` makes a roll of exactly 255 miss even
-- a 100%-accurate move (Damage.accuracyRoll), so an rng that always answered
-- the true maximum would turn every "proceeds" scenario below into a miss
-- instead of the landed hit it is meant to prove.
local function highRng(a, b)
  if not b then return a end
  return b - 1
end

-- ------- a stat-stage move, run by the engine

local sim, field = fieldSim({
  { side = "a", owner = "ann", name = "ANN",
    party = { mon(60, 50, { { id = "FIX_BOOST", pp = 20 } }) } },
  { side = "a", owner = "bob", name = "BOB",
    party = { mon(60, 40, { { id = "FIX_TACKLE", pp = 20 } }) } },
  { side = "b", owner = nil, name = "FOE",
    party = { mon(60, 30, { { id = "FIX_TACKLE", pp = 20 } }) } },
  { side = "b", owner = nil, name = "FOE",
    party = { mon(60, 20, { { id = "FIX_TACKLE", pp = 20 } }) } },
})

check(getmetatable(field) ~= nil, "the field is a BattleState-shaped object")
eq(type(field.performMove), "function",
   "and inherits performMove from the engine rather than defining one")
eq(field.performMove, BattleState.performMove,
   "-- the very same function, not a copy")

local before = sim:slot(1).battler.stages.attack or 0
local events = sim:resolveTurn({ { slot = 1, move = 1, target = 3 } })
local after = sim:slot(1).battler.stages.attack or 0
eq(after, before + 1,
   "a status move raised a stat stage -- the engine's effect record ran")
check(#events > 0, "and the turn produced messages to replay")

local sawUsed = false
for _, event in ipairs(events) do
  if event.kind == "msg" and tostring(event.text):find("FIX BOOST") then
    sawUsed = true
  end
end
check(sawUsed, "including the engine's own \"used <move>!\" line")

-- PP came off through the engine's own decrement
eq(sim:slot(1).battler.curMoves[1].pp, 19, "and the engine spent the PP")

-- ------- a charge move: two turns, which is the thing a 1v1-only registry
-- was supposed to make impossible here

sim, field = fieldSim({
  { side = "a", owner = "ann", name = "ANN",
    party = { mon(60, 50, { { id = "FIX_CHARGE", pp = 10 } }) } },
  { side = "a", owner = "bob", name = "BOB",
    party = { mon(60, 40, { { id = "FIX_TACKLE", pp = 20 } }) } },
  { side = "b", owner = nil, name = "FOE",
    party = { mon(200, 30, { { id = "FIX_TACKLE", pp = 20 } }) } },
  { side = "b", owner = nil, name = "FOE",
    party = { mon(200, 20, { { id = "FIX_TACKLE", pp = 20 } }) } },
})

local foeHP = sim:slot(3).battler.mon.hp
sim:resolveTurn({ { slot = 1, move = 1, target = 3 } })
check(sim:slot(1).battler.charging ~= nil,
      "turn one of a charge move charges instead of hitting")
eq(sim:slot(3).battler.mon.hp, foeHP, "and deals nothing yet")

sim:resolveTurn({ { slot = 1, move = 1, target = 3 } })
eq(sim:slot(1).battler.charging, nil, "turn two releases it")
check(sim:slot(3).battler.mon.hp < foeHP, "and it lands")

-- ------- small helpers the status blocks below all share

local function fourFixSlots(overrides)
  local raw = {
    { side = "a", owner = "ann", name = "ANN",
      party = { mon(60, 50, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "a", owner = "bob", name = "BOB",
      party = { mon(60, 45, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "b", owner = "cal", name = "CAL",
      party = { mon(60, 30, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "b", owner = "dee", name = "DEE",
      party = { mon(60, 20, { { id = "FIX_TACKLE", pp = 20 } }) } },
  }
  for k, v in pairs(overrides or {}) do raw[k] = v end
  return raw
end

local function msgTexts(events, fromSlot)
  local out = {}
  for _, e in ipairs(events) do
    if e.kind == "msg" and (fromSlot == nil or e.from == fromSlot) then
      out[#out + 1] = tostring(e.text)
    end
  end
  return out
end

local function anyFind(list, needle)
  for _, t in ipairs(list) do
    if t:find(needle, 1, true) then return true end
  end
  return false
end

-- ------- SING is enforced: a sleeping battler skips its turn for real
--
-- Plan finding 1. `CoopSim.runAction` had no status gate at all -- a slept
-- monster attacked on schedule, same as an awake one. The gate is the
-- engine's own `BattleState:statusInterrupt`, reached through the field
-- adapter exactly as it is for a 1v1; this pins that the sleeper's turn stays
-- lost, prints the original's own wording, ticks the counter, and hands the
-- move back once the counter reaches zero.

;(function()
  -- A real infliction first: SING's own effect record, run through the
  -- four-slot adapter, actually lands SLP -- the claim CoopField exists to
  -- support in the first place.
  local landing = fieldSim(fourFixSlots({
    [1] = { side = "a", owner = "ann", name = "ANN",
            party = { mon(60, 50, { { id = "FIX_SLEEP", pp = 20 } }) } },
  }))
  landing:resolveTurn({ { slot = 1, move = 1, target = 3 } })
  eq(landing:slot(3).battler.mon.status, "SLP",
     "SLEEP_EFFECT lands through the four-slot adapter, not only a 1v1")

  -- The enforcement itself, with the duration under this test's own control
  -- rather than the fixture rng's -- the fixed rng rolls the shortest
  -- possible nap (`rng(1, 7)` returns 1), and three real turns of "is fast
  -- asleep!" is the point.
  local sim = fieldSim(fourFixSlots())
  local sleeper = sim:slot(3).battler
  sleeper.mon.status = "SLP"
  sleeper.sleepTurns = 2

  local hpBefore = sim:slot(1).battler.mon.hp
  local ppBefore = sleeper.curMoves[1].pp
  local events = sim:resolveTurn({ { slot = 3, move = 1, target = 1 } })
  local texts = msgTexts(events)
  check(anyFind(texts, "fast asleep"), "the sleeper's own turn says so")
  check(not anyFind(texts, "FIX TACKLE"),
        "and never prints the move it would have used")
  eq(sim:slot(1).battler.mon.hp, hpBefore,
     "the monster it would have hit takes nothing")
  eq(sleeper.curMoves[1].pp, ppBefore,
     "and no PP is spent on a turn that never happened")
  eq(sleeper.sleepTurns, 1, "the counter ticks down, once, on this turn alone")

  -- Turn two: the counter reaches zero and the mon wakes -- but waking is
  -- itself the whole of this turn, the same as the original's.
  events = sim:resolveTurn({ { slot = 3, move = 1, target = 1 } })
  texts = msgTexts(events)
  check(anyFind(texts, "woke up"), "the wake message lands on schedule")
  check(not anyFind(texts, "FIX TACKLE"), "the waking turn is still not a move")
  eq(sim:slot(3).battler.mon.status, nil, "and the status is actually gone")

  -- Turn three: free to act, and it does.
  hpBefore = sim:slot(1).battler.mon.hp
  events = sim:resolveTurn({ { slot = 3, move = 1, target = 1 } })
  texts = msgTexts(events)
  check(anyFind(texts, "FIX TACKLE"), "the move flows again once the mon is awake")
  check((sim:slot(1).battler.mon.hp or 0) < hpBefore,
        "and it actually lands on its target")
end)()

-- ------- paralysis, in both directions
--
-- The fixed suite rng returns the minimum for every roll, which always
-- clears the 63/256 full-stop threshold. Proving the *other* branch -- a
-- paralysed mon moving normally on the turns it is not stopped -- needs a
-- roll that clears it instead of falling under it, which is what `highRng`
-- buys. Paralysis's speed cut is pinned elsewhere (TurnOrder); this is the
-- beforeMove gate alone.

;(function()
  -- Fixed rng: always the 63/256 full-stop.
  local stopped = fieldSim(fourFixSlots())
  stopped:slot(3).battler.mon.status = "PAR"
  local hpBefore = stopped:slot(1).battler.mon.hp
  local events = stopped:resolveTurn({ { slot = 3, move = 1, target = 1 } })
  local texts = msgTexts(events)
  check(anyFind(texts, "fully paralyzed"),
        "the fixed rng's 0/256 roll always clears the 63/256 threshold")
  check(not anyFind(texts, "FIX TACKLE"),
        "and the move it would have used never prints")
  eq(stopped:slot(1).battler.mon.hp, hpBefore, "so the target takes nothing")

  -- An rng that always answers above the threshold: the same mon, the same
  -- turn, and this time it moves.
  local proceeds = fieldSimRng(highRng, fourFixSlots())
  proceeds:slot(3).battler.mon.status = "PAR"
  hpBefore = proceeds:slot(1).battler.mon.hp
  events = proceeds:resolveTurn({ { slot = 3, move = 1, target = 1 } })
  texts = msgTexts(events)
  check(not anyFind(texts, "fully paralyzed"),
        "a roll clear of the threshold does not full-stop")
  check(anyFind(texts, "FIX TACKLE"), "and the paralysed mon's move proceeds")
  check((proceeds:slot(1).battler.mon.hp or 0) < hpBefore,
        "landing on its target like any other turn")
end)()

-- ------- confusion: the self-hit, the proceed, and the snap-out
--
-- `confusedTurns` is a volatile independent of `mon.status` -- a mon can be
-- confused and nothing else -- so it is set directly, the same choice sleep
-- and paralysis make above.

;(function()
  -- Fixed rng: the 0/256 roll clears the 128/256 self-hit threshold every
  -- time, so the confused mon hits itself instead of its intended target.
  local hit = fieldSim(fourFixSlots())
  hit:slot(1).battler.confusedTurns = 2
  local targetHpBefore = hit:slot(3).battler.mon.hp
  local selfHpBefore = hit:slot(1).battler.mon.hp
  local events = hit:resolveTurn({ { slot = 1, move = 1, target = 3 } })
  local texts = msgTexts(events, 1)
  check(anyFind(texts, "is confused"), "the confusion tick always prints first")
  check(anyFind(texts, "hurt itself"), "and the roll lands the self-hit")
  eq(hit:slot(3).battler.mon.hp, targetHpBefore,
     "the monster it meant to hit is untouched")
  check((hit:slot(1).battler.mon.hp or 0) < selfHpBefore,
        "the damage lands on the confused mon itself instead")

  -- Low enough to die of it: the self-hit's faint reaches the same flow any
  -- other knockout does.
  local dying = fieldSim(fourFixSlots({
    [1] = { side = "a", owner = "ann", name = "ANN",
            party = { mon(1, 50, { { id = "FIX_TACKLE", pp = 20 } }) } },
  }))
  dying:slot(1).battler.confusedTurns = 2
  events = dying:resolveTurn({ { slot = 1, move = 1, target = 3 } })
  local sawFaint, sawFaintMsg = false, false
  for _, e in ipairs(events) do
    if e.kind == "faint" and e.slot == 1 then sawFaint = true end
    if e.kind == "msg" and tostring(e.text):find("fainted", 1, true) then
      sawFaintMsg = true
    end
  end
  check(sawFaint, "a confused mon that kills itself faints through the same "
        .. "event the field uses for any other knockout")
  check(sawFaintMsg, "and is announced the same way")
  check(dying:isDown(dying:slot(1)), "the field actually recognises it as down")

  -- An rng clear of the threshold: still confused, still says so, but this
  -- time the move it picked is the one that lands.
  local proceeds = fieldSimRng(highRng, fourFixSlots())
  proceeds:slot(1).battler.confusedTurns = 2
  local hpBefore = proceeds:slot(3).battler.mon.hp
  events = proceeds:resolveTurn({ { slot = 1, move = 1, target = 3 } })
  texts = msgTexts(events, 1)
  check(anyFind(texts, "is confused"),
        "the tick still prints -- confusion has not gone anywhere")
  check(anyFind(texts, "FIX TACKLE"), "but the move it picked flows this time")
  check(not anyFind(texts, "hurt itself"), "and it does not hit itself")
  check((proceeds:slot(3).battler.mon.hp or 0) < hpBefore,
        "landing on the target it actually aimed at")

  -- The counter reaching zero snaps out of it, and the move that turn
  -- proceeds normally -- the original's own rule, not a self-hit avoided.
  local snapping = fieldSim(fourFixSlots())
  snapping:slot(1).battler.confusedTurns = 1
  hpBefore = snapping:slot(3).battler.mon.hp
  events = snapping:resolveTurn({ { slot = 1, move = 1, target = 3 } })
  texts = msgTexts(events, 1)
  check(anyFind(texts, "snapped out"), "the counter reaching zero ends it")
  eq(snapping:slot(1).battler.confusedTurns, nil,
     "and the volatile is really gone")
  check(anyFind(texts, "FIX TACKLE"), "the turn it snaps out on is a normal move")
  check((snapping:slot(3).battler.mon.hp or 0) < hpBefore, "which lands")
end)()

-- ------- freeze holds, with no self-thaw
;(function()
  local sim = fieldSim(fourFixSlots())
  sim:slot(3).battler.mon.status = "FRZ"
  for turn = 1, 3 do
    local hpBefore = sim:slot(1).battler.mon.hp
    local events = sim:resolveTurn({ { slot = 3, move = 1, target = 1 } })
    local texts = msgTexts(events)
    check(anyFind(texts, "frozen solid"),
          ("turn %d: the freeze message prints again"):format(turn))
    check(not anyFind(texts, "FIX TACKLE"),
          ("turn %d: and the move never runs"):format(turn))
    eq(sim:slot(1).battler.mon.hp, hpBefore,
       ("turn %d: so the target takes nothing"):format(turn))
    eq(sim:slot(3).battler.mon.status, "FRZ",
       ("turn %d: with no self-thaw -- nothing in this gate clears it"):format(turn))
  end
end)()

-- ------- Wrap/Bind holds, now that boundTurns is refreshed before the gate
--
-- `battler.boundTurns` is a mirror of whichever living opponent is holding
-- this slot in a trap, refreshed immediately before every action -- the
-- refresh `CoopSim.runAction` now does that nothing here used to. A held mon
-- skips its turn exactly the way a slept or paralysed one does.
;(function()
  local sim = fieldSim(fourFixSlots())
  sim:slot(3).battler.trappingTurns = 2
  local hpBefore = sim:slot(3).battler.mon.hp
  local events = sim:resolveTurn({ { slot = 1, move = 1, target = 3 } })
  check(anyFind(msgTexts(events), "can't move"),
        "a mon held by a living trapper skips its turn")
  eq(sim:slot(3).battler.mon.hp, hpBefore,
     "so the trapper it would have hit takes nothing")
end)()

-- ------- flinch bites the second mover, and does not outlive its turn
--
-- Plan finding: flinch discipline. `resolveTurn` clears every slot's
-- `flinched` at the top of the turn (sparing a recharging/raging one -- the
-- Hyper Beam glitch below), and the gate itself runs inline per-slot inside
-- the execution loop -- so a first mover's flinch bites a later mover the
-- same turn, and does not leak into a turn nothing caused it on.

;(function()
  -- ANN (speed 90) moves before CAL (speed 10) in the same turn. The fixed
  -- rng's 0/256 roll always clears FLINCH_SIDE_EFFECT1's 26/256 chance, so
  -- CAL is flinched before its own action comes up.
  local sim = fieldSim(fourFixSlots({
    [1] = { side = "a", owner = "ann", name = "ANN",
            party = { mon(60, 90, { { id = "FIX_FLINCH", pp = 20 } }) } },
    [3] = { side = "b", owner = "cal", name = "CAL",
            party = { mon(60, 10, { { id = "FIX_TACKLE", pp = 20 } }) } },
  }))
  local annTargetHp = sim:slot(3).battler.mon.hp
  local calTargetHp = sim:slot(1).battler.mon.hp
  local calPP = sim:slot(3).battler.curMoves[1].pp
  local events = sim:resolveTurn({
    { slot = 1, move = 1, target = 3 }, { slot = 3, move = 1, target = 1 },
  })
  check(anyFind(msgTexts(events, 3), "flinched"),
        "the second mover's own turn prints the flinch, not the attack that "
        .. "caused it")
  eq(sim:slot(1).battler.mon.hp, calTargetHp,
     "the flinched mon's intended target takes nothing from it")
  eq(sim:slot(3).battler.curMoves[1].pp, calPP,
     "and no PP is spent on a turn that never happened")
  check((sim:slot(3).battler.mon.hp or 0) < annTargetHp,
        "ANN's own attack still landed -- the flinch is CAL's turn, not ANN's")

  -- ------- an ordinary battler does not carry a stale flag into its own turn
  --
  -- Whatever set `flinched` to true, the top-of-turn sweep wipes it before an
  -- ordinary battler's own action is reached, so a flag left over from
  -- outside this turn (however it got there) never eats a turn nothing
  -- actually caused this time.
  local ordinary = fieldSim(fourFixSlots())
  ordinary:slot(3).battler.flinched = true
  local hpBefore = ordinary:slot(1).battler.mon.hp
  events = ordinary:resolveTurn({ { slot = 3, move = 1, target = 1 } })
  local texts = msgTexts(events)
  check(not anyFind(texts, "flinched"),
        "a stale flag is cleared before this mon's own turn")
  check(anyFind(texts, "FIX TACKLE"), "and the turn is an ordinary move")
  check((ordinary:slot(1).battler.mon.hp or 0) < hpBefore, "which lands")

  -- ------- the Hyper Beam glitch: a recharging battler is spared the sweep
  --
  -- core.asm skips the top-of-turn clear for a mon that must recharge or is
  -- locked into Rage, so a flag already sitting on one survives to be read by
  -- its own recharge check instead -- eating the recharge turn on a flinch
  -- rather than clearing the flag for free. Built directly: both flags are
  -- fixture state a fast attacker would otherwise have to land in the same
  -- turn to produce, and the point under test is the sweep's own exception,
  -- not how the flag got there.
  local recharging = fieldSim(fourFixSlots())
  local battler = recharging:slot(3).battler
  battler.flinched = true
  battler.mustRecharge = true
  local ppBefore = battler.curMoves[1].pp
  events = recharging:resolveTurn({ { slot = 3, move = 1, target = 1 } })
  texts = msgTexts(events)
  check(anyFind(texts, "flinched"),
        "the sweep spared this slot, so the stale flag survived to be read")
  check(not anyFind(texts, "must recharge"),
        "and it is read before the recharge check ever runs")
  check(battler.mustRecharge == true,
        "which means the recharge itself was never consumed -- an extra "
        .. "recharge turn is now owed")
  eq(battler.curMoves[1].pp, ppBefore, "no PP moves on a turn spent flinching")
end)()

-- ------- a Hyper Beam-class move actually recharges
--
-- Plan finding: recharge discipline. `BattleState:executeAction` routes a
-- battler with `mustRecharge` through `preRechargeChecks` and never reaches
-- `performMove` -- but nothing in the co-op path used to read the flag at
-- all, so Hyper Beam fired every turn, free. This pins the fix: it fires,
-- sets the flag, recharges the next turn instead of firing again, and is
-- free to move on the one after.

;(function()
  local sim = fieldSim(fourFixSlots({
    [1] = { side = "a", owner = "ann", name = "ANN",
            party = { mon(60, 50, { { id = "FIX_HYPER", pp = 5 } }) } },
    [3] = { side = "b", owner = "cal", name = "CAL",
            party = { mon(400, 30, { { id = "FIX_TACKLE", pp = 20 } }) } },
  }))
  local user = sim:slot(1).battler

  -- Turn one: it fires, and hits hard enough that the target survives to owe
  -- the recharge (Gen 1 skips it only on a KO).
  local hpAfterFirst = sim:slot(3).battler.mon.hp
  sim:resolveTurn({ { slot = 1, move = 1, target = 3 } })
  check(user.mustRecharge == true,
        "landing sets the recharge flag -- the half MoveEffects had nowhere "
        .. "to be read from before this file")
  check((sim:slot(3).battler.mon.hp or 0) < hpAfterFirst, "and it actually hit")

  -- Turn two: this used to fire Hyper Beam again, free, every turn -- the bug
  -- this whole gate exists to close. Now it recharges instead.
  local hpBeforeSecond = sim:slot(3).battler.mon.hp
  local ppBefore = user.curMoves[1].pp
  local events = sim:resolveTurn({ { slot = 1, move = 1, target = 3 } })
  local texts = msgTexts(events)
  check(anyFind(texts, "must recharge"), "turn two recharges instead of moving")
  check(not anyFind(texts, "FIX HYPER"),
        "the pre-fix behaviour -- firing every turn -- is gone")
  eq(sim:slot(3).battler.mon.hp, hpBeforeSecond,
     "so the target it was aimed at takes nothing")
  eq(user.curMoves[1].pp, ppBefore, "and no PP is spent on a recharge turn")
  eq(user.mustRecharge, nil, "reaching the recharge announcement clears the flag")

  -- Turn three: free to move again.
  hpBeforeSecond = sim:slot(3).battler.mon.hp
  events = sim:resolveTurn({ { slot = 1, move = 1, target = 3 } })
  check(anyFind(msgTexts(events), "FIX HYPER"), "and the third turn moves again")
  check((sim:slot(3).battler.mon.hp or 0) < hpBeforeSecond, "landing once more")
end)()

-- ------- Leech Seed actually drains, to the seeder, and never throws
--
-- Plan finding: the residual repair. `Status.residual` indexes
-- `opponent.mon.hp` for the drain right after mutating the PSN/BRN tick's own
-- HP, and the sim used to hand it `nil` for every seeded battler -- a throw
-- the surrounding pcall swallowed along with the message and the `damage`
-- event for HP that had already moved. This pins the fix: the drain lands
-- both ways, the seeder pointer survives a replacement and is cleared by one,
-- and a seeded-but-orphaned battler still gets its PSN/BRN half with nothing
-- thrown.

;(function()
  local sim = fieldSim(fourFixSlots({
    [1] = { side = "a", owner = "ann", name = "ANN",
            party = { mon(200, 50, { { id = "FIX_LEECH", pp = 20 },
                                      { id = "FIX_TACKLE", pp = 20 } }) } },
    [2] = { side = "a", owner = "bob", name = "BOB",
            party = { mon(200, 45, { { id = "FIX_TACKLE", pp = 20 } }) } },
    [3] = { side = "b", owner = "cal", name = "CAL",
            party = { mon(200, 30, { { id = "FIX_TACKLE", pp = 20 } }),
                      mon(200, 10, { { id = "FIX_TACKLE", pp = 20 } }) } },
    [4] = { side = "b", owner = "dee", name = "DEE",
            party = { mon(200, 20, { { id = "FIX_TACKLE", pp = 20 } }) } },
  }))
  -- FIXMON_A is GRASS, which LEECH_SEED_EFFECT refuses outright -- the same
  -- immunity a real GRASS-type target has. Overridden on the live battler
  -- rather than by minting a whole second species, since that is the only
  -- field the effect actually reads.
  sim:slot(3).battler.curTypes = { "NORMAL" }
  sim:slot(4).battler.curTypes = { "NORMAL" }

  sim:resolveTurn({ { slot = 1, move = 1, target = 3 } })
  check(sim:slot(3).battler.leechSeeded == true,
        "the primary effect lands through the four-slot adapter")
  eq(sim:slot(3).seededBy, 1,
     "and the sim remembers who seeded it -- the pointer the engine's own "
     .. "battler never needed at two slots")

  -- The drain: a whole turn later, at the residual step, in both directions.
  -- CAL also attacks the seeder this turn -- both directions have to be
  -- visible even in the same turn as an ordinary hit, and a seeder sitting
  -- at full HP would have the heal capped invisibly at the cap, proving
  -- nothing about whether it actually landed.
  local seedHpBefore = sim:slot(3).battler.mon.hp
  local events = sim:resolveTurn({ { slot = 3, move = 1, target = 1 } })
  local sawSeedMsg, sawSeedLoss = false, false
  local seederHp = {}
  for _, e in ipairs(events) do
    if e.kind == "msg" and tostring(e.text):find("LEECH SEED", 1, true) then
      sawSeedMsg = true
    end
    if e.kind == "damage" and e.slot == 3 and (e.amount or 0) > 0 then
      sawSeedLoss = true
    end
    if e.kind == "damage" and e.slot == 1 and e.hp then
      seederHp[#seederHp + 1] = e.hp
    end
  end
  check(sawSeedMsg, "the drain says so")
  check(sawSeedLoss, "with a damage event for the seeded mon's loss")
  check(#seederHp >= 2,
        "and the seeder's HP is reported twice this turn -- once for the "
        .. "hit it took from CAL, once for the drain that partly healed it")
  check(#seederHp >= 2 and seederHp[#seederHp] > seederHp[1],
        "with the later number higher than the first -- both directions ride "
        .. "the wire, not just the one HP a client happens to be drawing")
  check((sim:slot(3).battler.mon.hp or 0) < seedHpBefore, "and the field agrees")

  -- Cleared on replacement: the seed pointer belongs to the monster that is
  -- out, not the slot, so a fresh send-out starts owing nobody.
  sim:sendOut(sim:slot(3), 2)
  eq(sim:slot(3).seededBy, nil,
     "a replacement is not still feeding whoever seeded the monster it replaced")

  -- A seeded, poisoned battler whose seeder is gone: the PSN half still fires
  -- and nothing throws.
  local orphan = fieldSim(fourFixSlots())
  orphan:slot(3).battler.curTypes = { "NORMAL" }
  local victim = orphan:slot(3).battler
  victim.mon.status = "PSN"
  victim.leechSeeded = true
  orphan:slot(3).seededBy = nil -- the seeder never existed for this battler
  local before = victim.mon.hp
  local out = {}
  orphan:runResidual(orphan:slot(3), function(e) out[#out + 1] = e end)
  check(anyFind(msgTexts(out), "hurt by poison"),
        "the PSN half still prints -- a missing seeder does not swallow the "
        .. "part of the tick that has somewhere to go")
  check((victim.mon.hp or 0) < before, "and the poison damage really lands")
  eq(victim.leechSeeded, true,
     "the seed itself is untouched -- lifted for the length of the call, not "
     .. "cured by a seeder that happens to be missing")
end)()

-- ------- the assembled field is not taken on trust
--
-- It was the one inbound payload that skipped Wire, and the least defensible
-- one to skip it: the sender is another player's client, and this table says
-- how many monsters are on the field, whose they are, and what is drawn over
-- them. Four things were reachable from a modified peer -- the slot count, the
-- side, the name, and the party length.

;(function()
  local packedMon = { species = "X", level = 5 }
  local function slot(over)
    local out = { side = "a", owner = "ann", name = "ANN",
                  party = { packedMon } }
    for k, v in pairs(over or {}) do
      if v == "\0" then out[k] = nil else out[k] = v end
    end
    return out
  end
  local function fieldOf(slots, over)
    local out = { slots = slots, host = "ann" }
    for k, v in pairs(over or {}) do out[k] = v end
    return out
  end
  local function four(over)
    local slots = {}
    for i = 1, Config.COOP_FIGHTERS do
      slots[i] = slot(i > 2 and { side = "b", owner = "cal", name = "CAL" } or nil)
    end
    if over then for k, v in pairs(over) do slots[1][k] = v end end
    return fieldOf(slots)
  end

  local clean = Wire.coopField(four())
  check(clean ~= nil, "a well-formed field is accepted")
  eq(#clean.slots, Config.COOP_FIGHTERS, "with its four slots")
  eq(clean.slots[1].name, "ANN", "and the names it carried")

  -- the count, which buildField only ever checked on the sending side
  local three = four()
  table.remove(three.slots)
  eq(Wire.coopField(three), nil, "a field with the wrong number of slots is refused")
  local five = four()
  five.slots[5] = slot()
  eq(Wire.coopField(five), nil, "and so is one with too many")

  -- the side, which decides who may be attacked
  eq(Wire.coopField(four({ side = "c" })), nil,
     "a side that is neither a nor b is refused")

  -- the name, which is drawn on screen and put in events other mods read
  local shouty = Wire.coopField(four({ name = string.rep("!", 400) }))
  check(shouty == nil or #shouty.slots[1].name <= Config.COOP_LABEL_MAX,
        "a name is cleaned and bounded before it can reach a screen")

  -- the party length, which decides how long a battle can possibly last
  local horde = {}
  for i = 1, Config.COOP_TEAM_MAX + 5 do horde[i] = packedMon end
  eq(Wire.coopField(four({ party = horde })), nil,
     "a party longer than a Gen 1 team is refused -- unbounded, every faint "
     .. "is answered by another monster and the battle never ends")
  eq(Wire.coopField(four({ party = {} })), nil, "and an empty one is not a team")

  -- an owner that is not an id at all, told apart from an NPC's absent one
  eq(Wire.coopField(four({ owner = { evil = true } })), nil,
     "an owner that is not an id is refused")
  local npc = four()
  npc.slots[3].owner, npc.slots[4].owner = nil, nil
  npc.slots[3].name, npc.slots[4].name = "BUG CATCHER", "BUG CATCHER"
  local wild = Wire.coopField(npc)
  check(wild ~= nil, "a slot with no owner is fine -- that is an NPC")
  eq(wild and wild.slots[3].owner, nil, "and stays owned by nobody")

  -- and the shape as a whole
  eq(Wire.coopField(nil), nil, "no field is not a field")
  eq(Wire.coopField({ slots = "nope" }), nil, "and neither is one with no slots")
  eq(Wire.coopField(fieldOf({ slot(), slot(), slot(), "nope" })), nil,
     "a slot that is not a table is refused")

  -- ...and the receiving code really uses it.
  --
  -- Testing the sanitiser alone proves nothing about the door it guards: with
  -- `Wire.coopField` removed from `onMessage` every check above still passed.
  -- Driven through the real handler instead.
  local Coop = need("Coop")
  local said = {}
  local client = setmetatable({
    battle = { ready = false, plan = {}, parties = {}, badges = {} },
    running = true,
    ui = { say = function(_, text) said[#said + 1] = text end },
    transport = { send = function() end, isReady = function() return true end },
    -- Enough of a party for `startBattle` to get *past* the guard when the
    -- guard is removed. Without it the sabotage aborts the whole run on a nil
    -- index, which proves the line matters but says nothing about what it
    -- does -- and a crash is a poor substitute for a named failure.
    party = { isSelf = function() return false end, selfId = "ann" },
  }, { __index = Coop })

  local bogus = four()
  bogus.slots[5] = slot()          -- one slot too many
  Coop.onMessage(client, { data = data },
                 { from = "ann", payload = { t = "field", field = bogus } })
  eq(client.battle, nil,
     "a field that fails the sanitiser is refused by the handler, not built")
  -- On the *sanitiser's* sentence, not merely on "something went wrong".
  -- Without the check, `startBattle` gets the malformed field and gives up
  -- later when a party will not unpack -- which also clears the battle and
  -- also says something, so an assertion that only looked for a refusal
  -- passed either way and proved nothing about the guard.
  local blamedField = false
  for _, text in ipairs(said) do
    if tostring(text):find("field", 1, true) then blamedField = true end
  end
  check(blamedField,
        "and refused as an unreadable *field* -- rejected at the door rather "
        .. "than half-built and abandoned deeper in")
end)()

-- ------- an item paid for on a turn that never happened comes back
--
-- The bag is debited when the action is committed, because only this client
-- owns it. But the battle can end before that action ever resolves -- the host
-- drops, the stall clock fires -- and the potion was simply gone, having
-- healed nobody.

;(function()
  local CoopBattle = need("CoopBattle")
  local bag = { POTION = 2 }
  local client = setmetatable({
    sim = fieldSim({
      { side = "a", owner = "ann", name = "ANN",
        party = { mon(90, 50, { { id = "FIX_TACKLE", pp = 20 } }) } },
      { side = "a", owner = "bob", name = "BOB",
        party = { mon(90, 40, { { id = "FIX_TACKLE", pp = 20 } }) } },
      { side = "b", owner = "cal", name = "CAL",
        party = { mon(90, 30, { { id = "FIX_TACKLE", pp = 20 } }) } },
      { side = "b", owner = "dee", name = "DEE",
        party = { mon(90, 20, { { id = "FIX_TACKLE", pp = 20 } }) } },
    }),
    host = false, mine = 1, messages = {}, owed = "POTION",
    game = { data = data, save = { inventory = bag, party = {} } },
  }, { __index = CoopBattle })

  -- Through `exit`, which is what actually runs when a battle ends -- calling
  -- `refundUnspent` directly would pass with the call removed from `exit`,
  -- which is the whole of what makes this work.
  CoopBattle.exit(client)
  eq(bag.POTION, 3, "a battle that ended without resolving the turn gives it back")
  eq(client.owed, nil, "and only once")
  CoopBattle.exit(client)
  eq(bag.POTION, 3, "however many times the teardown runs")

  -- ...and a turn that *did* resolve settles the debt, so nothing is refunded
  client.owed = "POTION"
  CoopBattle.applyTurn(client, { seq = 1, events = {} })
  eq(client.owed, nil, "a resolved turn clears what was owed")
  CoopBattle.refundUnspent(client)
  eq(bag.POTION, 3, "so it is not handed back a second time")
end)()

-- ------- and when the clock runs out, the host picks for you
--
-- The other half of the countdown. When it reaches zero the host sends out the
-- next living reserve and the battle moves again -- but the picker belongs to
-- the player who ran out of time, and closing it was left to the button they
-- never pressed. They were parked in a bench list for a slot that was already
-- filled, could not take their next turn, and their eventual pick was dropped
-- as a stale duplicate.

;(function()
  local CoopBattle = need("CoopBattle")
  local function field()
    return fieldSim({
      { side = "a", owner = "ann", name = "ANN",
        party = { mon(400, 50, { { id = "FIX_TACKLE", pp = 20 } }) } },
      { side = "a", owner = "bob", name = "BOB",
        party = { mon(400, 40, { { id = "FIX_TACKLE", pp = 20 } }) } },
      { side = "b", owner = "cal", name = "CAL",
        party = { mon(1, 30, { { id = "FIX_TACKLE", pp = 20 } }),
                  mon(400, 25, { { id = "FIX_TACKLE", pp = 20 } }),
                  mon(400, 20, { { id = "FIX_TACKLE", pp = 20 } }) } },
      { side = "b", owner = "dee", name = "DEE",
        party = { mon(400, 20, { { id = "FIX_TACKLE", pp = 20 } }) } },
    })
  end

  -- CAL is the host here, so the clock and the picker are on one client --
  -- the case where "the host picked for me" is easiest to get wrong.
  local sim = field()
  local sent = {}
  local host = setmetatable({
    sim = sim, host = true, mine = 3, messages = {}, pending = {}, seq = 0,
    phase = "messages",
    game = { data = data, save = { inventory = {}, party = {} } },
    net = { poll = function() return {} end,
            send = function(payload) sent[#sent + 1] = payload end },
  }, { __index = CoopBattle })

  sim:resolveTurn({ { slot = 1, move = 1, target = 3 } })
  CoopBattle.playEvents(host, { { kind = "choose", slot = 3, trainer = "CAL" } })
  eq(host.replacing, true, "the player whose monster fell is asked to choose")

  -- Nothing happens before the clock runs out.
  CoopBattle.tickStalls(host, Config.COOP_CHOICE_TIMEOUT - 1)
  eq(host.replacing, true, "and is left to decide while there is time")
  eq(sim:slot(3).awaiting, true, "with the field still waiting on them")

  -- ...and then it does.
  CoopBattle.tickStalls(host, 2)
  eq(sim:slot(3).awaiting, nil, "when it runs out the field stops waiting")
  eq(sim:slot(3).active, 2, "the next living reserve is sent out")
  eq(host.replacing, nil,
     "and the picker closes on the event rather than on a button the player "
     .. "never pressed")

  -- Everyone is told it was the clock, not a choice.
  -- A queued line is a row, not a bare string -- it carries who acted, so the
  -- spotlight can move when the line is *shown* rather than when the turn
  -- arrived. Read the text out of it.
  local blamed = false
  for _, row in ipairs(host.messages) do
    local text = type(row) == "table" and row.text or row
    if type(text) == "string" and text:find("too long", 1, true) then
      blamed = true
    end
  end
  check(blamed, "and it is said out loud that the time ran out, so a choice "
        .. "made by a clock does not read as one the player made")

  -- The same on a client that is only watching the answer arrive.
  local guest = setmetatable({
    sim = field(), host = false, mine = 3, messages = {}, replacing = true,
    switchIndex = 2,
    game = { data = data, save = { inventory = {}, party = {} } },
  }, { __index = CoopBattle })
  CoopBattle.playEvents(guest, { { kind = "send", slot = 3, index = 2,
                                   name = "X", trainer = "CAL" } })
  eq(guest.replacing, nil,
     "a replacement that arrives off the wire closes the picker too")
  eq(guest.switchIndex, 1, "and puts the cursor back")

  -- Somebody else's replacement leaves my picker alone.
  local mine = setmetatable({
    sim = field(), host = false, mine = 1, messages = {}, replacing = true,
    game = { data = data, save = { inventory = {}, party = {} } },
  }, { __index = CoopBattle })
  CoopBattle.playEvents(mine, { { kind = "send", slot = 3, index = 2 } })
  eq(mine.replacing, true,
     "but another player's replacement does not close mine")
end)()

-- ------- the turn deadline: one clock, every slot, the host's own included
--
-- The old clock ran backwards -- it forfeited the one player who *had*
-- answered and left an idle host unbounded. This is its replacement: one
-- deadline per turn, and on expiry every slot that still owes an action is
-- defaulted for, the host's own slot no exception. All-or-nothing, though:
-- one slot `defaultAction` cannot answer for abandons the whole attempt
-- rather than filing half a turn.

;(function()
  local CoopBattle = need("CoopBattle")
  local sim = fieldSim({
    { side = "a", owner = "ann", name = "ANN",
      party = { mon(200, 50, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "a", owner = "bob", name = "BOB",
      party = { mon(200, 45, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "b", owner = "cal", name = "CAL",
      party = { mon(200, 30, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "b", owner = "dee", name = "DEE",
      party = { mon(200, 20, { { id = "FIX_TACKLE", pp = 20 } }) } },
  })
  local sent = {}
  local host = setmetatable({
    sim = sim, host = true, mine = 1, messages = {}, pending = {}, seq = 0,
    phase = "wait",
    game = { data = data, save = { inventory = {}, party = {} } },
    net = { poll = function() return {} end,
            send = function(payload) sent[#sent + 1] = payload end },
  }, { __index = CoopBattle })

  -- BOB and CAL have already answered. ANN -- the host's own slot -- and DEE
  -- have not: the deadline belongs to the turn, not to whichever phase the
  -- host's own screen happens to be sitting in.
  host.pending[2] = { slot = 2, kind = "move", move = 1, target = 3 }
  host.pending[3] = { slot = 3, kind = "move", move = 1, target = 1 }

  CoopBattle.openTurn(host)
  eq(host.turnOpened, 0, "the deadline is armed the moment the turn opens")

  CoopBattle.tickStalls(host, Config.COOP_TURN_TIMEOUT - 1)
  check(#sent == 0, "short of the deadline, nothing has been decided for anybody")

  local hpBefore = sim:slot(1).battler.mon.hp
  CoopBattle.tickStalls(host, 2)
  check(#sent > 0, "past it, the turn resolves and goes out on the wire")
  local events = sent[#sent].events or {}
  local blamed = {}
  for _, event in ipairs(events) do
    if event.kind == "msg" and tostring(event.text):find("too long", 1, true) then
      blamed[#blamed + 1] = tostring(event.text)
    end
  end
  check(#blamed == 2, "exactly the two idle slots are named -- BOB and CAL, "
        .. "who had already answered, are not")
  local sawAnn, sawDee = false, false
  for _, text in ipairs(blamed) do
    if text:find("ANN", 1, true) then sawAnn = true end
    if text:find("DEE", 1, true) then sawDee = true end
  end
  check(sawAnn, "the host's own idle slot is defaulted for -- the half the "
        .. "old self-forfeit clock could never do")
  check(sawDee, "and so is the other player's")
  check((sim:slot(1).battler.mon.hp or 0) < hpBefore,
        "and the turn actually resolved -- the attacks it produced landed")
  eq(host.turnOpened, nil,
     "the deadline that just fired is spent -- `tryResolve` disarms it the "
     .. "moment a turn commits to resolving, and the next one is armed at "
     .. "the next handover, not left running")

  -- ------- all-or-nothing: one un-defaultable slot aborts the whole attempt
  --
  -- `defaultAction` answers nil when a slot has nothing left to aim at.
  -- Filing what *could* be defaulted and leaving the rest used to be exactly
  -- the half-resolved state nothing could recover from: `pending` half full,
  -- the clock disarmed by the caller with nothing left to re-arm it. Now the
  -- picks are gathered before any of them is filed, and one nil abandons the
  -- whole attempt.
  local sim3 = fieldSim({
    { side = "a", owner = "ann", name = "ANN",
      party = { mon(200, 50, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "a", owner = "bob", name = "BOB",
      party = { mon(200, 45, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "b", owner = "cal", name = "CAL",
      party = { mon(200, 30, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "b", owner = "dee", name = "DEE",
      party = { mon(200, 20, { { id = "FIX_TACKLE", pp = 20 } }) } },
  })
  -- Both foes are down without the battle having resolved it -- an
  -- artificial but legal field state (a real one reaches it mid-turn,
  -- between the last knockout and `checkOver` catching up), and the one
  -- that leaves ANN with nothing to default to.
  sim3:slot(3).battler.mon.hp = 0
  sim3:slot(4).battler.mon.hp = 0
  local sent3 = {}
  local host3 = setmetatable({
    sim = sim3, host = true, mine = 1, messages = {}, pending = {}, seq = 0,
    phase = "wait",
    game = { data = data, save = { inventory = {}, party = {} } },
    net = { poll = function() return {} end,
            send = function(payload) sent3[#sent3 + 1] = payload end },
  }, { __index = CoopBattle })
  host3.pending[2] = { slot = 2, kind = "move", move = 1, target = 3 }

  CoopBattle.openTurn(host3)
  CoopBattle.tickStalls(host3, Config.COOP_TURN_TIMEOUT + 1)
  eq(#sent3, 0, "nothing goes out -- one slot with no target to default to "
     .. "means the whole attempt is abandoned, not filed half-full")
  check(host3.pending[2] ~= nil,
        "the one real commitment already on file is untouched")
  eq(host3.pending[1], nil,
     "and nothing was invented for the slot that could not be defaulted")
  eq(host3.turnOpened, 0,
     "the clock re-arms instead of firing again on the very next frame")

  -- And nobody is late for a menu they have not been offered yet: the
  -- messages phase is the previous turn still being read, not a wait for an
  -- answer.
  local narrating = setmetatable({
    sim = fieldSim({
      { side = "a", owner = "ann", name = "ANN",
        party = { mon(200, 50, { { id = "FIX_TACKLE", pp = 20 } }) } },
      { side = "a", owner = "bob", name = "BOB",
        party = { mon(200, 45, { { id = "FIX_TACKLE", pp = 20 } }) } },
      { side = "b", owner = "cal", name = "CAL",
        party = { mon(200, 30, { { id = "FIX_TACKLE", pp = 20 } }) } },
      { side = "b", owner = "dee", name = "DEE",
        party = { mon(200, 20, { { id = "FIX_TACKLE", pp = 20 } }) } },
    }),
    host = true, mine = 1, messages = {}, pending = {}, seq = 0,
    phase = "messages",
    game = { data = data, save = { inventory = {}, party = {} } },
    net = { poll = function() return {} end, send = function() end },
  }, { __index = CoopBattle })
  eq(CoopBattle.autoPickLate(narrating), false,
     "the deadline never fires against a turn nobody has been offered yet")

  -- ------- the clock freezes during a replacement pause
  --
  -- A faint stops the field for the shorter clock; if the turn deadline kept
  -- counting through that pause, a slow replacement would burn most of the
  -- next turn's budget before anybody still owing one was even asked.
  local sim2 = fieldSim({
    { side = "a", owner = "ann", name = "ANN",
      party = { mon(1, 50, { { id = "FIX_TACKLE", pp = 20 } }),
                mon(200, 45, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "a", owner = "bob", name = "BOB",
      party = { mon(200, 40, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "b", owner = "cal", name = "CAL",
      party = { mon(200, 30, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "b", owner = "dee", name = "DEE",
      party = { mon(200, 20, { { id = "FIX_TACKLE", pp = 20 } }) } },
  })
  local host2 = setmetatable({
    sim = sim2, host = true, mine = 2, messages = {}, pending = {}, seq = 0,
    phase = "wait",
    game = { data = data, save = { inventory = {}, party = {} } },
    net = { poll = function() return {} end, send = function() end },
  }, { __index = CoopBattle })

  sim2:resolveTurn({ { slot = 3, move = 1, target = 1 } })
  check(sim2:awaitingChoice() ~= nil,
        "ANN's monster fell, and the field is paused for a send-out")
  host2.turnOpened = 5 -- as though a turn had already been open five seconds

  CoopBattle.tickStalls(host2, Config.COOP_CHOICE_TIMEOUT - 1)
  eq(host2.turnOpened, 5, "not a second of it is spent while the field is "
     .. "paused for something else entirely")
  check(sim2:awaitingChoice() ~= nil, "and the pause itself is still open")

  CoopBattle.tickStalls(host2, 2)
  eq(sim2:awaitingChoice(), nil,
     "past its own threshold, the replacement clock resolves the pause on "
     .. "its own schedule -- independent of the frozen deadline beside it")
  eq(host2.turnOpened, 5,
     "which still has not moved -- tickStalls returns before reaching clock "
     .. "one on the same tick the pause clears")

  CoopBattle.tickStalls(host2, 1)
  eq(host2.turnOpened, 6,
     "resumed, the clock picks up from where it was left -- one real second "
     .. "passes and it moves by exactly one, not by the whole pause")
end)()

-- ------- every kind on the wire has a name
--
-- `KINDS` is the allow-list a client's action is checked against, and it read
-- as though it were exhaustive. It was not: a replacement travels down the
-- same wire with `kind = "replace"`, and nothing in the vocabulary said so --
-- a bare string in one caller and an implicit default in another.
--
-- The fix is *not* to add it to KINDS. KINDS is what `resolveTurn` dispatches,
-- and a "replace" reaching that would be handed to `runOther`, which has no
-- branch for it -- so the slot would silently do nothing for a turn instead of
-- falling back to a move. It is named separately, which is what it is.

;(function()
  local CoopSim = need("CoopSim")
  local CoopBattle = need("CoopBattle")

  eq(CoopSim.REPLACE, "replace", "the off-turn action has a name")
  eq(CoopSim.KINDS[CoopSim.REPLACE], nil,
     "and is deliberately not a turn action -- resolveTurn would dispatch it "
     .. "to a branch that does not exist, and the slot would lose its turn")

  -- Everything KINDS *does* claim is really dispatched. A kind in the
  -- allow-list with nowhere to go is the same bug from the other side: it
  -- passes validation and then does nothing.
  local field = fieldSim({
    { side = "a", owner = "ann", name = "ANN",
      party = { mon(90, 50, { { id = "FIX_TACKLE", pp = 20 } }),
                mon(90, 45, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "a", owner = "bob", name = "BOB",
      party = { mon(90, 40, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "b", owner = "cal", name = "CAL",
      party = { mon(90, 30, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "b", owner = "dee", name = "DEE",
      party = { mon(90, 20, { { id = "FIX_TACKLE", pp = 20 } }) } },
  })
  for kind in pairs(CoopSim.KINDS) do
    if kind ~= "move" then
      local reached = false
      local emitted = {}
      local ok = pcall(function()
        field:runOther(field:slot(1),
                       { slot = 1, kind = kind, index = 2, item = "NONE" },
                       function(event) emitted[#emitted + 1] = event end)
        reached = true
      end)
      check(ok and reached,
            ("the turn kind %q is dispatched rather than falling through"):format(kind))
    end
  end

  -- The client sends the named constant, not a string that happens to match.
  local sent = {}
  local picker = fieldSim({
    { side = "a", owner = "ann", name = "ANN",
      party = { mon(90, 50, { { id = "FIX_TACKLE", pp = 20 } }),
                mon(90, 45, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "a", owner = "bob", name = "BOB",
      party = { mon(90, 40, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "b", owner = "cal", name = "CAL",
      party = { mon(90, 30, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "b", owner = "dee", name = "DEE",
      party = { mon(90, 20, { { id = "FIX_TACKLE", pp = 20 } }) } },
  })
  picker:slot(1).battler.mon.hp = 0
  local client = setmetatable({
    sim = picker, host = false, mine = 1, messages = {}, replacing = true,
    switchIndex = 1,
    game = { data = data, save = { inventory = {}, party = {} } },
    sendAction = function(_, action) sent[#sent + 1] = action end,
  }, { __index = CoopBattle })
  CoopBattle.updateReplace(client,
    { wasPressed = function(_, key) return key == "a" end })
  eq(sent[1] and sent[1].kind, CoopSim.REPLACE,
     "a replacement goes out under the name the vocabulary gives it")

  -- ------- and a stale one is dropped rather than turned into a move
  --
  -- The bug the gap was hiding. A duplicate replacement -- a retry, or one
  -- that raced the first -- arrives for a slot that has already answered. The
  -- kind is not in KINDS, so the fallback turned it into a *move* and filed it
  -- for that slot, overwriting whatever the player had actually chosen for the
  -- turn. It is now recognised and ignored.
  local host = fieldSim({
    { side = "a", owner = "ann", name = "ANN",
      party = { mon(90, 50, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "a", owner = "bob", name = "BOB",
      party = { mon(90, 40, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "b", owner = "cal", name = "CAL",
      party = { mon(90, 30, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "b", owner = "dee", name = "DEE",
      party = { mon(90, 20, { { id = "FIX_TACKLE", pp = 20 } }) } },
  })
  local inbox = { { t = "act", from = "cal",
                    action = { slot = 3, kind = CoopSim.REPLACE, index = 1 } } }
  local hostClient = setmetatable({
    sim = host, host = true, mine = 1, messages = {}, pending = {}, seq = 0,
    game = { data = data, save = { inventory = {}, party = {} } },
    net = { poll = function() local out = inbox; inbox = {}; return out end,
            send = function() end },
  }, { __index = CoopBattle })
  eq(host:slot(3).awaiting, nil, "the slot is not waiting on anything")
  CoopBattle.drainNet(hostClient)
  eq(hostClient.pending[3], nil,
     "a replacement for a slot that already answered files nothing -- it does "
     .. "not become a move that player never chose")
end)()

-- ------- a wait says what it is waiting for
--
-- A player who has not answered a faint stops the whole field -- nothing
-- resolves while any slot is awaiting -- so the other three sit in front of a
-- battle that cannot move. It used to cost a full minute in front of an empty
-- message box, which is indistinguishable from a battle that has hung, and
-- that ambiguity is exactly how the first wedged co-op battle got reported.
--
-- Two changes, and the second is the one that matters: the pause that blocks
-- everything gets the *shorter* clock, and every client says who it is waiting
-- for and counts down.

;(function()
  local CoopBattle = need("CoopBattle")
  check(Config.COOP_CHOICE_TIMEOUT < Config.COOP_TURN_TIMEOUT,
        "a pause that stops the whole field is given less rope than one that "
        .. "holds up a single turn")

  -- **Two fields, not one.** The host resolves on its own copy and the
  -- replayer only ever hears events -- so a test that pointed both at one sim
  -- would find `awaiting` already set by the host's own faint and pass whether
  -- or not a replayer is ever told anything. That is precisely the state this
  -- is about: the three clients who did not resolve the turn.
  local function field()
    return fieldSim({
      { side = "a", owner = "ann", name = "ANN",
        party = { mon(400, 50, { { id = "FIX_TACKLE", pp = 20 } }) } },
      { side = "a", owner = "bob", name = "BOB",
        party = { mon(400, 40, { { id = "FIX_TACKLE", pp = 20 } }) } },
      { side = "b", owner = "cal", name = "CAL",
        party = { mon(1, 30, { { id = "FIX_TACKLE", pp = 20 } }),
                  mon(400, 25, { { id = "FIX_TACKLE", pp = 20 } }) } },
      { side = "b", owner = "dee", name = "DEE",
        party = { mon(400, 20, { { id = "FIX_TACKLE", pp = 20 } }) } },
    })
  end
  local host, sim = field(), field()
  -- ANN's client: not the one being asked, so the one that has to be told.
  local client = setmetatable({
    sim = sim, host = false, mine = 1, messages = {}, phase = "wait",
    game = { data = data, save = { inventory = {}, party = {} } },
  }, { __index = CoopBattle })

  -- Waiting on the others generally: named, but no clock yet.
  local budget, named = CoopBattle.waitingOn(client)
  check(budget == Config.COOP_TURN_TIMEOUT and named == nil,
        "a client that has committed is waiting on the other trainers")
  eq(CoopBattle.waitLine(client), nil,
     "and says nothing about it for the first few seconds -- an ordinary turn "
     .. "has all four deciding at once")

  CoopBattle.tickStalls(client, Config.COOP_WAIT_HINT + 1)
  local line = CoopBattle.waitLine(client)
  check(line ~= nil and line:find("Waiting", 1, true) ~= nil,
        "once it has gone on, it says so")
  -- ------- and now the number is honest, because the deadline is real
  --
  -- The turn deadline used to be host-only in effect: `tickStalls` spent the
  -- general-wait budget on the host alone, so a replayer that counted the
  -- same number down to zero sat on "(0)" for the rest of the wait -- the bug
  -- Finding 5 pinned. Nothing on a replayer's own client ever fired at that
  -- mark. `openTurn`/`autoPickLate` now enforce one deadline per turn for
  -- every slot, the host's own included, so the countdown a non-host shows is
  -- a promise the host really keeps -- and it prints alongside the name.
  check(line:find("(", 1, true) ~= nil,
        "and a countdown -- the deadline is enforced host-side for every "
        .. "slot now, so the number is no longer theatre")
  check(line:find("BOB", 1, true) ~= nil,
        "naming the first trainer who has not answered yet")

  -- The host's own forfeit clock is real, so its general wait still counts
  -- down -- the one place a number is not theatre.
  local hostWaiter = setmetatable({
    sim = field(), host = true, mine = 1, messages = {}, phase = "wait",
    game = { data = data, save = { inventory = {}, party = {} } },
  }, { __index = CoopBattle })
  CoopBattle.tickStalls(hostWaiter, Config.COOP_WAIT_HINT + 1)
  local hostLine = CoopBattle.waitLine(hostWaiter)
  check(hostLine ~= nil and hostLine:find("(", 1, true) ~= nil,
        "but the host's own general wait still counts down -- its forfeit "
        .. "clock really is running")

  -- CAL's monster falls, and CAL is asked. Every client is told the field is
  -- paused, not only CAL's -- which is what lets ANN's name the person.
  local events = host:resolveTurn({ { slot = 1, move = 1, target = 3 } })
  eq(sim:slot(3).awaiting, nil,
     "the replayer knows nothing about the pause until it is told")
  CoopBattle.playEvents(client, events)
  check(sim:slot(3).awaiting == true,
        "the paused slot is marked on a replayer too, not only on the host")

  client.waitShown = 0
  local clock, who = CoopBattle.waitingOn(client)
  eq(who, "CAL", "so the wait names the player it is waiting for")
  eq(clock, Config.COOP_CHOICE_TIMEOUT, "on the shorter of the two clocks")
  CoopBattle.tickStalls(client, Config.COOP_WAIT_HINT + 1)
  local paused = CoopBattle.waitLine(client)
  check(paused ~= nil and paused:find("CAL", 1, true) ~= nil,
        "and says their name on screen rather than showing an empty box")

  -- ------- and every line of it fits the box
  --
  -- The message box is eighteen characters wide. A trainer name is up to ten,
  -- and "<NAME> is choosing... (30)" on one line ran off the right edge -- the
  -- way a clipped line always ships, by looking fine for every short name
  -- anybody happens to test with. Checked against the longest name the wire
  -- will carry rather than against a convenient one.
  local LONGEST = string.rep("W", Config.NAME_MAX)
  local function widest(text)
    local most = 0
    for line in tostring(text or ""):gmatch("[^\n]+") do
      most = math.max(most, #line)
    end
    return most
  end
  eq(widest("123456789012345678"), 18, "the ruler measures what it says")

  sim:slot(3).name = LONGEST
  client.waitShown = Config.COOP_WAIT_HINT + 1
  local longLine = CoopBattle.waitLine(client)
  check(longLine ~= nil, "the longest name still produces a line")
  check(widest(longLine) <= 18,
        ("and it fits the box (%d columns): %q"):format(
          widest(longLine), tostring(longLine)))

  -- The other side of it: the generic wait, with the larger clock in it.
  local generic = setmetatable({
    sim = fieldSim({
      { side = "a", owner = "ann", name = LONGEST,
        party = { mon(90, 50, { { id = "FIX_TACKLE", pp = 20 } }) } },
      { side = "a", owner = "bob", name = "BOB",
        party = { mon(90, 40, { { id = "FIX_TACKLE", pp = 20 } }) } },
      { side = "b", owner = "cal", name = "CAL",
        party = { mon(90, 30, { { id = "FIX_TACKLE", pp = 20 } }) } },
      { side = "b", owner = "dee", name = "DEE",
        party = { mon(90, 20, { { id = "FIX_TACKLE", pp = 20 } }) } },
    }),
    host = false, mine = 1, messages = {}, phase = "wait",
    waitShown = Config.COOP_WAIT_HINT + 1,
    game = { data = data, save = { inventory = {}, party = {} } },
  }, { __index = CoopBattle })
  local waitLine = CoopBattle.waitLine(generic)
  check(waitLine ~= nil and widest(waitLine) <= 18,
        ("the general wait fits too (%d columns): %q"):format(
          widest(waitLine), tostring(waitLine)))
  sim:slot(3).name = "CAL"

  -- The player being asked is not told to wait for themselves.
  local theirs = setmetatable({
    sim = sim, host = false, mine = 3, messages = {}, phase = "wait",
    replacing = true,
    game = { data = data, save = { inventory = {}, party = {} } },
  }, { __index = CoopBattle })
  eq(CoopBattle.waitingOn(theirs), nil,
     "the player being asked is choosing, not waiting")

  -- Answering it clears the wait everywhere, including on the replayer that
  -- only ever hears about it.
  local sent = {}
  host:replace(3, 2, function(event) sent[#sent + 1] = event end)
  CoopBattle.playEvents(client, sent)
  eq(sim:slot(3).awaiting, nil, "sending one out clears the pause")
  client.phase = "choose"
  eq(CoopBattle.waitingOn(client), nil, "and nobody is waiting on anybody")

  -- ------- and now it counts across the whole turn, reset only at the handover
  --
  -- `waitShown` used to reset the instant `waitingOn()` went quiet -- which is
  -- also the instant this client's own commit does -- so the number a slow
  -- player was shown depended on how fast *they* answered, not on when the
  -- turn actually opened. It now ticks unconditionally (see `tickStalls`) and
  -- is reset in exactly one place: the messages->choose handover in `update`,
  -- beside `openTurn` -- the same event that starts the host's own deadline,
  -- so all four clients' counters agree with what the deadline is actually
  -- counting against.
  CoopBattle.tickStalls(client, 1)
  eq(client.waitShown, 7,
     "ticking on regardless -- there is no answer left here that would clear "
     .. "it early")

  -- The handover is what really puts it away: a fresh batch of messages
  -- draining to nothing hands the box back to a menu, and that is the one
  -- place `waitShown` goes back to zero.
  client.phase, client.after, client.messages, client.frame =
    "messages", "choose", {}, 0
  CoopBattle.update(client, 0.1)
  eq(client.phase, "choose", "the handover actually happened")
  eq(client.waitShown, 0,
     "and that is where the clock is really reset -- at the event every "
     .. "client reaches from its own copy of the same batch, not whenever "
     .. "this one client happens to stop waiting")
end)()

-- ------- acted tracking: what the wait line above is actually reading
--
-- The name in `waitLine` comes from `missingActors`, and that list is only as
-- honest as the `acted` bookkeeping behind it: your own commit, the host's
-- own pending file, and -- the new part -- an `act` a replayer merely
-- overheard on the wire (see `drainNet`'s "watched, never acted on" branch).
-- This pins each contributor and the two moments the whole table is thrown
-- away and started again.

;(function()
  local CoopBattle = need("CoopBattle")
  local sim = fieldSim({
    { side = "a", owner = "ann", name = "ANN",
      party = { mon(60, 50, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "a", owner = "bob", name = "BOB",
      party = { mon(60, 45, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "b", owner = "cal", name = "CAL",
      party = { mon(60, 30, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "b", owner = "dee", name = "DEE",
      party = { mon(60, 20, { { id = "FIX_TACKLE", pp = 20 } }) } },
  })

  -- Committing marks the slot that just answered.
  local committer = setmetatable({
    sim = sim, host = false, mine = 1, messages = {}, pending = {},
    game = { data = data, save = { inventory = {}, party = {} } },
  }, { __index = CoopBattle })
  CoopBattle.commit(committer, { slot = 1, move = 1, target = 3 })
  check(committer.acted and committer.acted[1] == true,
        "committing an action marks this slot acted, on the client that sent it")

  -- A fanned `act` for an ordinary move marks it on a replayer that never
  -- resolved anything -- the fix itself: until now these were read only by
  -- the host and dropped by everybody else.
  local watcher = setmetatable({
    sim = sim, host = false, mine = 1, messages = {},
    game = { data = data, save = { inventory = {}, party = {} } },
    net = { poll = function()
              return { { t = "act", from = "bob",
                         action = { slot = 2, kind = "move", move = 1, target = 3 } } }
            end },
  }, { __index = CoopBattle })
  CoopBattle.drainNet(watcher)
  check(watcher.acted and watcher.acted[2] == true,
        "a replayer marks a slot the moment its `act` is fanned out -- it does "
        .. "not have to wait for the turn to resolve to know who has answered")

  -- But a replacement is not a turn action, and marking it acted would be a
  -- lie: the slot that sent it still owes this turn a move, and the case
  -- that makes the lie visible is a lost `res` recovered by snapshot, where
  -- nothing ever resets `acted` and the slot stays silently omitted from the
  -- wait line for the rest of the turn. So the branch reads the kind on the
  -- message -- it is all a replayer has, and nothing is simulated from it --
  -- and a REPLACE marks nothing at all.
  local watcher2 = setmetatable({
    sim = sim, host = false, mine = 1, messages = {},
    game = { data = data, save = { inventory = {}, party = {} } },
    net = { poll = function()
              return { { t = "act", from = "cal",
                         action = { slot = 3, kind = CoopSim.REPLACE, index = 2 } } }
            end },
  }, { __index = CoopBattle })
  CoopBattle.drainNet(watcher2)
  check(not (watcher2.acted and watcher2.acted[3]),
        "a replacement act marks nothing -- its slot still owes this turn a move")

  -- And the sender has to own the slot it names, the same rule the host has
  -- always applied to the actions it actually files. A claim for somebody
  -- else's slot marks nothing either.
  local impostor = setmetatable({
    sim = sim, host = false, mine = 1, messages = {},
    game = { data = data, save = { inventory = {}, party = {} } },
    net = { poll = function()
              return { { t = "act", from = "dee",
                         action = { slot = 3, kind = "move", move = 1, target = 1 } } }
            end },
  }, { __index = CoopBattle })
  CoopBattle.drainNet(impostor)
  check(not (impostor.acted and impostor.acted[3]),
        "an act claimed for a slot the sender does not own marks nothing")

  -- A resolved turn throws the whole table away, on the client that resolved
  -- it and on the one that only replayed it.
  local clearer = setmetatable({
    sim = sim, host = false, mine = 1, messages = {}, seq = 0,
    acted = { [2] = true, [3] = true },
    game = { data = data, save = { inventory = {}, party = {} } },
  }, { __index = CoopBattle })
  CoopBattle.applyTurn(clearer,
    { seq = 1, sig = sim:signature(), events = {} })
  eq(clearer.acted, nil,
     "a turn landing clears every slot's acted flag, ready for the next one")

  -- ------- who missingActors excludes, and who it does not
  --
  -- Self, an NPC partner (nobody to wait for), a downed slot and a gone one
  -- are all the same kind of "nothing owed" -- excluded together rather than
  -- one at a time, because a wait line that named any of the four would be a
  -- bug report of its own.
  local excludeSim = fieldSim({
    { side = "a", owner = "ann", name = "ANN",
      party = { mon(60, 50, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "a", owner = nil, name = "PARTNER",
      party = { mon(60, 45, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "b", owner = "cal", name = "CAL",
      party = { mon(60, 30, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "b", owner = "dee", name = "DEE",
      party = { mon(60, 20, { { id = "FIX_TACKLE", pp = 20 } }) } },
  })
  excludeSim:slot(3).battler.mon.hp = 0
  excludeSim:forfeit("dee")
  local excluded = setmetatable({
    sim = excludeSim, host = false, mine = 1, messages = {},
    game = { data = data, save = { inventory = {}, party = {} } },
  }, { __index = CoopBattle })
  eq(#CoopBattle.missingActors(excluded), 0,
     "self, an NPC partner, a downed slot and a gone one are all excluded -- "
     .. "with only those four on the field, nobody is left to wait for")

  -- ------- and who it names, at the width the box actually has
  local named = fieldSim({
    { side = "a", owner = "ann", name = "ANN",
      party = { mon(60, 50, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "a", owner = "bob", name = string.rep("B", Config.NAME_MAX),
      party = { mon(60, 45, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "b", owner = "cal", name = "CAL",
      party = { mon(60, 30, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "b", owner = "dee", name = "DEE",
      party = { mon(60, 20, { { id = "FIX_TACKLE", pp = 20 } }) } },
  })
  local waiter = setmetatable({
    sim = named, host = false, mine = 1, messages = {}, phase = "wait",
    waitShown = Config.COOP_WAIT_HINT + 1,
    game = { data = data, save = { inventory = {}, party = {} } },
  }, { __index = CoopBattle })
  local missing = CoopBattle.missingActors(waiter)
  eq(#missing, 3, "BOB, CAL and DEE are all still owed a turn")
  eq(missing[1], string.rep("B", Config.NAME_MAX),
     "named in slot order -- the first one who has not answered, first")

  local line = CoopBattle.waitLine(waiter)
  local function widest(text)
    local most = 0
    for l in tostring(text or ""):gmatch("[^\n]+") do most = math.max(most, #l) end
    return most
  end
  check(line ~= nil and line:find(string.rep("B", Config.NAME_MAX), 1, true) ~= nil,
        "the wait line names the first missing player at the full ten characters")
  -- ------- the fit rule's priority order, pinned at the point it bites
  --
  -- Eighteen columns, and at NAME_MAX (10) the three pieces cannot all have
  -- them: name (10) + "..." (3) + " (54)" (5) is already eighteen, with
  -- nothing left for " +2". The name is never truncated and the number is
  -- kept -- it is the half the deadline makes true -- so the tail that goes
  -- is " +N", the least load-bearing of the three.
  check(line:find("+2", 1, true) == nil,
        "and drops the '+N' tail rather than the name or the number -- there "
        .. "is no room for all three at NAME_MAX")
  check(line:find("(", 1, true) ~= nil,
        "the countdown survives the same squeeze -- it is the half that "
        .. "makes the deadline honest")
  check(widest(line) <= 18,
        ("and still fits the eighteen-column box (%d columns): %q"):format(
          widest(line), tostring(line)))

  -- A short name leaves room for all three: the full name, the countdown,
  -- and the "+N" tail that says how many others are also still deciding.
  local shortNamed = fieldSim({
    { side = "a", owner = "ann", name = "ANN",
      party = { mon(60, 50, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "a", owner = "bob", name = "BOB",
      party = { mon(60, 45, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "b", owner = "cal", name = "CAL",
      party = { mon(60, 30, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "b", owner = "dee", name = "DEE",
      party = { mon(60, 20, { { id = "FIX_TACKLE", pp = 20 } }) } },
  })
  local shortWaiter = setmetatable({
    sim = shortNamed, host = false, mine = 1, messages = {}, phase = "wait",
    waitShown = Config.COOP_WAIT_HINT + 1,
    game = { data = data, save = { inventory = {}, party = {} } },
  }, { __index = CoopBattle })
  local shortLine = CoopBattle.waitLine(shortWaiter)
  check(shortLine ~= nil and shortLine:find("BOB", 1, true) ~= nil,
        "a short name still names the first trainer")
  check(shortLine:find("+2", 1, true) ~= nil,
        "and this time all three fit -- the '+N' tail is not dropped when "
        .. "there is room for it")
  check(shortLine:find("(", 1, true) ~= nil, "alongside the countdown")
  check(widest(shortLine) <= 18,
        ("and still within the box (%d columns): %q"):format(
          widest(shortLine), tostring(shortLine)))
end)()

-- ------- a fresh line survives the tick it was created on
--
-- Finding 1. A line used to offer its own dismiss window on the very tick it
-- appeared, so a player holding A -- every player -- swallowed lines they
-- never saw: press A on ITEM with an empty bag and "You have nothing to use!"
-- was queued, shown and eaten in one frame. And the queue-empty fall-through
-- that hands the box back to a menu ran on the very next tick regardless, so
-- a batch of exactly one line was never readable at all. `MSG_MIN_DWELL`
-- fixes the first; the split between "what is queued" and "what is on
-- screen" (see CoopBattle.lua's `M:update`) fixes the second.

;(function()
  local CoopBattle = need("CoopBattle")
  local NOPRESS = { wasPressed = function() return false end }
  local function pressA() return { wasPressed = function(_, k) return k == "a" end } end
  local function messageClient(text)
    return setmetatable({
      phase = "messages", after = "choose", messages = { text }, frame = 0,
      game = { input = NOPRESS, data = data, save = { inventory = {}, party = {} } },
    }, { __index = CoopBattle })
  end

  -- The line is shown and dwell-checked on the same call -- that is what
  -- makes this the same-tick case rather than a later one. A dt of one
  -- frame is far short of the floor, so the press this tick is refused.
  local flicker = messageClient("You have nothing\nto use!")
  flicker.game.input = pressA()
  CoopBattle.update(flicker, 0.1)
  check(flicker.shown ~= nil,
        "an A pressed on the very tick a line appears does not eat it -- the "
        .. "dwell floor covers the tick the line was created on too")

  -- It survives being looked at, not merely the one press -- and it survives
  -- past the floor itself with nobody touching a button.
  flicker.game.input = NOPRESS
  CoopBattle.update(flicker, 0.1)
  check(flicker.shown ~= nil, "and an unread line does not vanish on its own")
  CoopBattle.update(flicker, 0.1)
  check(flicker.shown ~= nil,
        "even once the floor (0.25s) has passed, nothing dismisses it but a "
        .. "press or the full 1.6s dwell")

  -- Past the floor, a deliberate press finally lands.
  flicker.game.input = pressA()
  CoopBattle.update(flicker, 0.1)
  check(flicker.shown == nil, "and now a press dismisses it")

  -- The queue was empty and the last (only) line has just been dismissed --
  -- the exact case the flicker lived in. The box hands back to the menu
  -- rather than sitting wedged on an empty line forever.
  flicker.game.input = NOPRESS
  CoopBattle.update(flicker, 0.1)
  eq(flicker.phase, "choose",
     "a one-line batch, once dismissed, hands the turn back rather than "
     .. "wedging on an empty message box")

  -- The other way out: the 1.6s auto-advance, untouched by the floor.
  -- Fifteen tenths of a second first, well clear of both the dwell floor and
  -- the floating-point edge of 1.6 itself, then a push well past it -- the
  -- claim is "eventually, unattended", not the exact millisecond.
  local auto = messageClient("There's no one\nelse to send out!")
  for _ = 1, 15 do CoopBattle.update(auto, 0.1) end
  check(auto.shown ~= nil,
        "a second and a half is past the dwell floor but short of the 1.6s "
        .. "auto-advance -- so it is not gone early")
  CoopBattle.update(auto, 0.2)
  check(auto.shown == nil,
        "but past 1.6s it advances on its own, with nobody having pressed anything")
  CoopBattle.update(auto, 0.1)
  eq(auto.phase, "choose",
     "and hands the box back here too, not only after a deliberate press")
end)()

-- ------- run consent: a question Gen 1 never had to ask
--
-- RUN in a party-versus-party battle is not the trainer refusal and not a
-- unilateral escape: it prompts the partner, commits nothing until they
-- answer, and only a yes ends the battle -- for all four, with the runners'
-- ranked loss the same "over" event a knockout produces.

;(function()
  local CoopBattle = need("CoopBattle")
  local CoopSim = need("CoopSim")

  local function field()
    return fieldSim({
      { side = "a", owner = "ann", name = "ANN",
        party = { mon(90, 50, { { id = "FIX_TACKLE", pp = 20 } }) } },
      { side = "a", owner = "bob", name = "BOB",
        party = { mon(90, 40, { { id = "FIX_TACKLE", pp = 20 } }) } },
      { side = "b", owner = "cal", name = "CAL",
        party = { mon(90, 30, { { id = "FIX_TACKLE", pp = 20 } }) } },
      { side = "b", owner = "dee", name = "DEE",
        party = { mon(90, 20, { { id = "FIX_TACKLE", pp = 20 } }) } },
    })
  end

  -- ------- partyBattle: told apart from an NPC fight by ownership, not by
  -- a flag either side could get out of step with

  local npcClient = setmetatable({
    sim = fieldSim({
      { side = "a", owner = "ann", name = "ANN",
        party = { mon(90, 50, { { id = "FIX_TACKLE", pp = 20 } }) } },
      { side = "a", owner = "bob", name = "BOB",
        party = { mon(90, 40, { { id = "FIX_TACKLE", pp = 20 } }) } },
      { side = "b", owner = nil, name = "FOE",
        party = { mon(90, 30, { { id = "FIX_TACKLE", pp = 20 } }) } },
      { side = "b", owner = nil, name = "FOE",
        party = { mon(90, 20, { { id = "FIX_TACKLE", pp = 20 } }) } },
    }),
    mine = 1,
  }, { __index = CoopBattle })
  eq(CoopBattle.partyBattle(npcClient), false,
     "an NPC's two ownerless slots are not a party battle")

  local pvpClient = setmetatable({ sim = field(), mine = 1 }, { __index = CoopBattle })
  eq(CoopBattle.partyBattle(pvpClient), true, "four owned slots are")
  local partner = CoopBattle.partnerOf(pvpClient, pvpClient.sim:slot(1))
  eq(partner and partner.index, 2, "and the partner is the other slot on the same side")

  -- ------- RUN, from the command menu: PvP asks, NPC refuses as always

  local pvpMenu = setmetatable({
    sim = field(), mine = 1, phase = "choose", commandIndex = 1, pending = {},
    net = { send = function() end },
  }, { __index = CoopBattle })
  local pvpCommands = CoopBattle.COMMANDS or {}
  local runIndex
  for i, c in ipairs(pvpCommands) do if c == "RUN" then runIndex = i end end
  check(runIndex ~= nil, "RUN is one of the four commands")
  pvpMenu.commandIndex = runIndex
  CoopBattle.updateCommand(pvpMenu, { wasPressed = function(_, k) return k == "a" end })
  check(pvpMenu.runAsk ~= nil, "RUN in a party battle raises the ask rather "
        .. "than committing an action")
  eq(pvpMenu.runAsk.role, "asking", "from the asker's own side, it is 'asking'")
  eq(next(pvpMenu.pending), nil, "and commits nothing -- no action was filed")
  eq(pvpMenu.phase, "choose", "the phase itself is untouched by asking")

  local npcMenu = setmetatable({
    sim = npcClient.sim, mine = 1, phase = "choose", commandIndex = runIndex,
    pending = {},
  }, { __index = CoopBattle })
  local committed
  npcMenu.commit = function(_, action) committed = action end
  CoopBattle.updateCommand(npcMenu, { wasPressed = function(_, k) return k == "a" end })
  eq(npcMenu.runAsk, nil, "against an NPC, RUN never raises a prompt")
  check(committed ~= nil and committed.kind == "run",
        "it is filed as the ordinary refused action instead -- byte-identical "
        .. "to today")

  -- ------- the partner's prompt: NO by default, and a settle floor before
  -- any button counts

  eq(CoopBattle.RUN_DEFAULT, 2, "the default cursor position is the second row")
  eq(CoopBattle.RUN_ANSWERS[CoopBattle.RUN_DEFAULT], "NO",
     "which is the answer that costs nothing")

  local asked = setmetatable({
    sim = field(), mine = 2, host = false,
    runAsk = { role = "deciding", slot = 1, name = "ANN", clock = 0 },
  }, { __index = CoopBattle })
  local answeredWith
  asked.answerRun = function(_, ok) answeredWith = ok end

  -- A-press at the very moment the prompt opens does not confirm anything --
  -- the settle floor covers the tick a fresh prompt appears on, exactly as it
  -- does for an ordinary message line.
  CoopBattle.updateRunAsk(asked, { wasPressed = function(_, k) return k == "a" end }, 0.1)
  eq(answeredWith, nil, "an A press inside the settle floor answers nothing")
  eq(asked.runAsk.role, "deciding", "the prompt is still up")

  -- ...but moving the cursor is exempt from the same floor: it is not an
  -- answer, and a player who pre-positions on YES during the floor and then
  -- presses A has made exactly the two-step decision this is asking for.
  eq(asked.runAsk.index, CoopBattle.RUN_DEFAULT,
     "the cursor has already latched onto the default (NO) -- driven, even "
     .. "though the floor refused to act on it")
  CoopBattle.updateRunAsk(asked, { wasPressed = function(_, k) return k == "left" end }, 0)
  eq(asked.runAsk.index, 1, "a directional press moves the cursor even inside "
     .. "the floor")

  -- Past the floor, A confirms whatever the cursor is on.
  CoopBattle.updateRunAsk(asked, { wasPressed = function(_, k) return k == "a" end }, 0.3)
  eq(answeredWith, true, "and now A really answers -- here, YES, because the "
     .. "cursor was moved onto it")

  -- B always answers NO, the same way it does on every other picker.
  local askedB = setmetatable({
    sim = field(), mine = 2, host = false,
    runAsk = { role = "deciding", slot = 1, name = "ANN", clock = 1 },
  }, { __index = CoopBattle })
  local bAnswer
  askedB.answerRun = function(_, ok) bAnswer = ok end
  CoopBattle.updateRunAsk(askedB, { wasPressed = function(_, k) return k == "b" end }, 0)
  eq(bAnswer, false, "B backs out of the prompt exactly like it says no")

  -- ------- spam: a repeated ask for the same slot does not reset the prompt

  local spammed = setmetatable({
    sim = field(), host = false, mine = 1, messages = {},
    runAsk = { role = "deciding", slot = 2, name = "BOB", index = 1, clock = 5 },
    net = { poll = function() return { { t = Wire.COOP_RUN_ASK, from = "bob" } } end },
  }, { __index = CoopBattle })
  CoopBattle.drainNet(spammed)
  eq(spammed.runAsk.index, 1,
     "a repeated ask for the same slot does not reset the cursor")
  eq(spammed.runAsk.clock, 5, "nor restart the settle floor")

  -- ------- simultaneous RUNs: mutual consent, no tie-break needed

  local crossed = setmetatable({
    sim = field(), host = false, mine = 1, messages = {},
    runAsk = { role = "asking", slot = 2, name = "BOB" },
    net = { poll = function() return { { t = Wire.COOP_RUN_ASK, from = "bob" } } end },
  }, { __index = CoopBattle })
  local crossedAnswer
  crossed.answerRun = function(_, ok) crossedAnswer = ok end
  CoopBattle.drainNet(crossed)
  eq(crossedAnswer, true,
     "a run_ask arriving while this client is itself asking is taken as "
     .. "consent -- a player who has just asked to leave has already agreed "
     .. "to leaving")

  -- ------- the host: refuses consent with no ask behind it

  local warnings = {}
  stubMod.log.warn = function(_, fmt, ...)
    local ok, line = pcall(string.format, fmt, ...)
    warnings[#warnings + 1] = ok and line or tostring(fmt)
  end
  local lonelyHost = setmetatable({ sim = field(), host = true, mine = 1 },
                                   { __index = CoopBattle })
  eq(CoopBattle.hostRunAnswer(lonelyHost, 2, true), false,
     "a yes with no recorded ask behind it is refused")
  check(#warnings > 0, "and says so, so the pair can just ask again")
  stubMod.log.warn = function() end

  -- ------- partner gone: no consent needed, the flee is immediate

  local soloSim = field()
  soloSim:forfeit("bob")
  local soloHost = setmetatable({ sim = soloSim, host = true, mine = 1,
                                   messages = {}, pending = {}, seq = 0,
                                   game = { data = data,
                                            save = { inventory = {}, party = {} } },
                                   net = { send = function() end } },
                                 { __index = CoopBattle })
  eq(CoopBattle.hostRunAsk(soloHost, 1), true,
     "asking with nobody left on your side resolves the flee, not a prompt")
  check(soloHost.result ~= nil, "the battle ends right there -- there is "
        .. "nobody to hold it open for")

  -- ------- yes: the flee, broadcast as an ordinary resolved batch, with the
  -- runners' loss and the opponents' win landing on the host AND a replayer

  local sent = {}
  local host = setmetatable({
    sim = field(), host = true, mine = 1, messages = {}, pending = {}, seq = 0,
    phase = "wait",
    game = { data = data, save = { inventory = {}, party = {} } },
    net = { poll = function() return {} end,
            send = function(p) sent[#sent + 1] = p end },
  }, { __index = CoopBattle })

  eq(CoopBattle.hostRunAsk(host, 1), true, "ANN's ask is recorded")
  check(host.result == nil, "and nothing is decided yet -- BOB has not answered")
  eq(CoopBattle.hostRunAnswer(host, 2, true), true, "BOB's yes resolves it")
  check(host.result ~= nil, "the battle is over on the host")
  eq(host.result, "loss",
     "ANN's own side fled, so the host -- sitting in that same slot -- "
     .. "reports a ranked loss")

  local last = sent[#sent]
  eq(last.t, "res", "the flee reaches the wire as an ordinary resolved batch")
  check(type(last.sig) == "string" and #last.sig > 0,
        "signed with the field's signature like any other turn")
  local sawOver, overWinner = false, nil
  for _, event in ipairs(last.events or {}) do
    if event.kind == "over" then sawOver, overWinner = true, event.winner end
  end
  check(sawOver, "and carries the same 'over' event a knockout produces")
  eq(overWinner, "b", "naming the side that was left standing")

  -- A replayer on the winning side applies the very same batch and reaches
  -- the opposite, honestly-different verdict.
  local replaySim = field()
  local replayer = setmetatable({
    sim = replaySim, host = false, mine = 3, messages = {}, seq = 0,
    game = { data = data, save = { inventory = {}, party = {} } },
  }, { __index = CoopBattle })
  CoopBattle.applyTurn(replayer, last)
  eq(replayer.result, "win",
     "CAL -- on the side that was left standing -- sees a win from the exact "
     .. "same batch")
  eq(host.sim:signature(), replaySim:signature(),
     "and the two fields agree, byte for byte, on how it ended")

  -- ------- no: the asker alone sees the refusal, and nothing was committed

  local declined = setmetatable({
    sim = field(), host = false, mine = 1, messages = {},
    runAsk = { role = "asking", slot = 2, name = "BOB" },
    net = { poll = function()
      return { { t = Wire.COOP_RUN_ANSWER, from = "bob", ok = false } }
    end },
  }, { __index = CoopBattle })
  CoopBattle.drainNet(declined)
  eq(declined.runAsk.role, "refused", "the asker's own prompt turns into a "
     .. "refusal to read")
  eq(declined.runAsk.name, "BOB", "naming who said no")

  -- Read like any other line: nothing before the settle floor, a press after
  -- it, and the same 1.6s auto-advance untouched by any of this.
  local advanced = false
  CoopBattle.updateRunAsk(declined,
    { wasPressed = function(_, k) return k == "a" end }, 0.1)
  check(declined.runAsk ~= nil, "not dismissed inside the floor")
  CoopBattle.updateRunAsk(declined,
    { wasPressed = function(_, k) return k == "a" end }, 0.3)
  eq(declined.runAsk, nil, "but a deliberate press past it clears the line")

  local lingered = setmetatable({
    sim = field(), host = false, mine = 1, messages = {},
    runAsk = { role = "refused", name = "BOB", clock = 0 },
  }, { __index = CoopBattle })
  for _ = 1, 15 do
    CoopBattle.updateRunAsk(lingered, { wasPressed = function() return false end }, 0.1)
  end
  check(lingered.runAsk ~= nil, "past the dwell floor but short of the "
        .. "auto-advance, nobody touched it")
  CoopBattle.updateRunAsk(lingered, { wasPressed = function() return false end }, 0.3)
  eq(lingered.runAsk, nil, "and past it, the line clears itself -- nobody "
     .. "has to press anything")

  -- ------- deadline teardown: the ask and the record die with the turn

  local expiredHost = setmetatable({
    sim = field(), host = true, mine = 1, messages = {}, pending = {}, seq = 0,
    runAsks = { [1] = true },
    game = { data = data, save = { inventory = {}, party = {} } },
    net = { send = function() end },
  }, { __index = CoopBattle })
  -- Filled in as though the deadline's auto-pick had already gathered every
  -- slot's action -- tryResolve only needs `pending` complete to fire.
  expiredHost.pending[1] = { slot = 1, kind = "move", move = 1, target = 3 }
  expiredHost.pending[2] = { slot = 2, kind = "move", move = 1, target = 3 }
  expiredHost.pending[3] = { slot = 3, kind = "move", move = 1, target = 1 }
  expiredHost.pending[4] = { slot = 4, kind = "move", move = 1, target = 1 }
  CoopBattle.tryResolve(expiredHost)
  eq(expiredHost.runAsks, nil,
     "tryResolve throws away any ask the host was holding -- it belonged to "
     .. "the turn that just resolved")

  local expiredClient = setmetatable({
    sim = field(), host = false, mine = 1, messages = {},
    runAsk = { role = "deciding", slot = 2, name = "BOB", clock = 3 },
  }, { __index = CoopBattle })
  CoopBattle.playEvents(expiredClient, { { kind = "msg", text = "..." } })
  eq(expiredClient.runAsk, nil,
     "and every client's own prompt comes down with the same batch, "
     .. "whether or not a turn actually resolved")

  local expiredHost2 = setmetatable({
    sim = field(), host = true, mine = 1, messages = {},
    runAsks = { [1] = true },
    game = { data = data, save = { inventory = {}, party = {} } },
  }, { __index = CoopBattle })
  CoopBattle.playEvents(expiredHost2, { { kind = "msg", text = "..." } })
  eq(expiredHost2.runAsks, nil,
     "the host's record dies in playEvents too -- not only in tryResolve -- "
     .. "so a batch that plays without resolving a turn (a forced send-out) "
     .. "does not leave a stale ask a forged yes could still be accepted "
     .. "against")

  -- ------- a run_ask that arrives mid-narration is deferred, not driven
  -- straight through the message queue

  local narrating = setmetatable({
    frame = 0, phase = "messages", after = "choose",
    messages = { "still reading..." },
    runAsk = { role = "deciding", slot = 2, name = "BOB", clock = 5 },
    game = { input = { wasPressed = function(_, k) return k == "a" end },
             data = data, save = { inventory = {}, party = {} } },
  }, { __index = CoopBattle })
  local drove = false
  narrating.updateRunAsk = function() drove = true end
  CoopBattle.update(narrating, 0.1)
  eq(drove, false,
     "while a batch of messages is still up, the ask is left alone rather "
     .. "than opening a picker over a turn nobody has finished watching")

  -- ------- NPC battles: the refusal is byte-identical, and fled() mirrors
  -- a knockout's own event

  local text = {}
  npcClient.sim:runOther(npcClient.sim:slot(1), { kind = "run" },
    function(e) text[#text + 1] = e end)
  check(#text == 1 and text[1].kind == "msg",
        "against a trainer, RUN still produces the original's own refusal")
  check(tostring(text[1].text):find("running", 1, true) ~= nil
        or tostring(text[1].text):find("No!", 1, true) ~= nil,
        "in the original's words")

  local fleeEvents = {}
  local fledOk = npcClient.sim:fled("a",
    function(e) fleeEvents[#fleeEvents + 1] = e end)
  eq(fledOk, true, "fled() succeeds once, for a side that has not already lost")
  eq(#fleeEvents, 1, "with exactly one event")
  eq(fleeEvents[1].kind, "over", "the same kind a knockout's checkOver emits")
  eq(fleeEvents[1].winner, "b", "naming the side that was left standing")
  eq(npcClient.sim:fled("a", function() end), false,
     "and refused a second time -- the battle is already decided")
end)()

-- ------- the wedge fix: the "(0)" freeze, pinned at the exact clocks that
-- used to get it wrong
--
-- One resync per wait, armed only past the deadline's own grace -- and a
-- snapshot that answers a flagged wedge hands the menu back rather than
-- merely correcting the numbers underneath it.

;(function()
  local CoopBattle = need("CoopBattle")
  local function field()
    return fieldSim({
      { side = "a", owner = "ann", name = "ANN",
        party = { mon(90, 50, { { id = "FIX_TACKLE", pp = 20 } }) } },
      { side = "a", owner = "bob", name = "BOB",
        party = { mon(90, 40, { { id = "FIX_TACKLE", pp = 20 } }) } },
      { side = "b", owner = "cal", name = "CAL",
        party = { mon(90, 30, { { id = "FIX_TACKLE", pp = 20 } }) } },
      { side = "b", owner = "dee", name = "DEE",
        party = { mon(90, 20, { { id = "FIX_TACKLE", pp = 20 } }) } },
    })
  end

  local function watcher()
    local resent = {}
    local w = setmetatable({
      sim = field(), host = false, mine = 1, messages = {}, phase = "wait",
      net = { poll = function() return {} end,
              send = function(p) resent[#resent + 1] = p end },
    }, { __index = CoopBattle })
    w.resent = resent
    return w
  end

  -- Exactly at the deadline: nothing yet. The grace is real headroom.
  local atDeadline = watcher()
  atDeadline.waitShown = Config.COOP_TURN_TIMEOUT
  CoopBattle.tickStalls(atDeadline, 0)
  eq(#atDeadline.resent, 0,
     "no resync fires at exactly the turn deadline")
  eq(atDeadline.wedged, nil, "and the client is not flagged wedged yet")

  -- One tick later than the grace allows: exactly one resync.
  local pastGrace = watcher()
  pastGrace.waitShown = Config.COOP_TURN_TIMEOUT + Config.COOP_ASK_GRACE
  CoopBattle.tickStalls(pastGrace, 0)
  eq(#pastGrace.resent, 1, "past the grace, exactly one resync goes out")
  eq(pastGrace.resent[1].t, "resync", "asking the host for the field")
  eq(pastGrace.wedged, true, "and the client flags itself wedged")
  eq(pastGrace.wedgeAsked, true, "so a second expiry does not ask again")

  CoopBattle.tickStalls(pastGrace, 1)
  CoopBattle.tickStalls(pastGrace, 1)
  eq(#pastGrace.resent, 1,
     "one request per wait -- ticking on past it does not pile up more")

  -- A snapshot answering a flagged wedge hands the menu back and refunds
  -- whatever the reopened turn owed.
  local sim = field()
  local wedgedClient = setmetatable({
    sim = sim, host = false, mine = 1, messages = {}, phase = "wait",
    wedged = true, wedgeAsked = true, owed = "POTION",
    game = { data = data, save = { inventory = { POTION = 0 }, party = {} } },
    net = { poll = function()
      return { { t = "state", seq = 5, slots = sim:snapshot() } }
    end },
  }, { __index = CoopBattle })
  CoopBattle.drainNet(wedgedClient)
  eq(wedgedClient.phase, "choose",
     "a snapshot answering a flagged wedge hands the menu back")
  eq(wedgedClient.game.save.inventory.POTION, 1,
     "and refunds the item the reopened turn had already spent")
  eq(wedgedClient.wedged, nil, "the flag is spent")
  eq(wedgedClient.wedgeAsked, nil, "both halves of it")

  -- Unwedge on a client that never flagged a wedge is a no-op.
  local calm = setmetatable({ phase = "choose", owed = "POTION",
                               game = { save = { inventory = { POTION = 0 } } } },
                             { __index = CoopBattle })
  eq(CoopBattle.unwedge(calm), false,
     "unwedge on a client that is not flagged wedged does nothing")
  eq(calm.phase, "choose", "leaving whatever phase it found")
  eq(calm.game.save.inventory.POTION, 0, "and refunding nothing nobody asked for")

  -- The host-silence clock is only ever moved by the host's own traffic --
  -- another player's act does not touch it, a forged 'res' from the wrong
  -- sender does not either, and the real host's message does.
  local untouched = setmetatable({
    sim = field(), host = false, mine = 1, messages = {}, hostClock = 10,
    net = { poll = function()
      return { { t = "act", from = "cal",
                 action = { slot = 3, kind = "move", move = 1, target = 1 } } }
    end },
  }, { __index = CoopBattle })
  CoopBattle.drainNet(untouched)
  eq(untouched.hostClock, 10,
     "a peer's own move does not reset the host-silence clock")

  local forged = setmetatable({
    sim = field(), host = false, mine = 1, messages = {}, hostClock = 10,
    hostId = "ann",
    net = { poll = function()
      return { { t = "res", seq = 1, from = "cal", events = {} } }
    end },
  }, { __index = CoopBattle })
  CoopBattle.drainNet(forged)
  eq(forged.hostClock, 10,
     "and neither does a 'res' forged from somebody who is not the host")

  local real = setmetatable({
    sim = field(), host = false, mine = 1, messages = {}, hostClock = 10,
    hostId = "ann",
    net = { poll = function()
      return { { t = "res", seq = 1, from = "ann", events = {} } }
    end },
  }, { __index = CoopBattle })
  CoopBattle.drainNet(real)
  eq(real.hostClock, 0, "but the real host's own message resets it")

  -- And the handover itself resets hostClock, wedged and wedgeAsked
  -- together, on every client -- not only when a host message happens to
  -- arrive.
  local handover = setmetatable({
    frame = 0, phase = "messages", after = "choose", messages = {},
    hostClock = 50, wedged = true, wedgeAsked = true,
    game = { input = { wasPressed = function() return false end },
             data = data, save = { inventory = {}, party = {} } },
  }, { __index = CoopBattle })
  CoopBattle.update(handover, 0.1)
  eq(handover.phase, "choose", "the handover really happened")
  eq(handover.hostClock, 0, "and hostClock is reset there too")
  eq(handover.wedged, nil, "wedged is cleared at the same event")
  eq(handover.wedgeAsked, nil, "and so is wedgeAsked -- a client that "
     .. "recovered the ordinary way does not carry the flag into whatever "
     .. "the next wait turns out to need it for")
end)()

-- ------- needsTarget: the truth table behind Finding 2
--
-- A zero-power move whose merged effect record is `primary` and is not
-- `accuracyChecked` is self-targeting by construction (MoveEffects.lua's own
-- comment: everything else in `primary` "is self-targeting and never rolls
-- accuracy"). Three effects break that rule by reading the target they are
-- given even though the numbers say self-only, and everything else --
-- missing records, `kind ~= "primary"`, any power, a nil moveInst -- is
-- conservative in the picker's favour: a needless press costs less than a
-- wrongly-skipped one costs a turn.

;(function()
  local CoopBattle = need("CoopBattle")
  local moves = {}
  for k, v in pairs(data.moves) do moves[k] = v end
  local gdata = {}
  for k, v in pairs(data) do gdata[k] = v end
  gdata.moves = moves
  local c = setmetatable({ game = { data = gdata } }, { __index = CoopBattle })

  eq(CoopBattle.needsTarget(c, { id = "FIX_BOOST" }), false,
     "a stat-up move (power 0, a primary record, never accuracy-checked) "
     .. "commits without a picker")
  eq(CoopBattle.needsTarget(c, { id = "FIX_TACKLE" }), true,
     "anything with power keeps the picker")

  moves.FIX_GHOST_MOVE = nil
  eq(CoopBattle.needsTarget(c, { id = "FIX_GHOST_MOVE" }), true,
     "a move id nothing in the dataset defines keeps the picker -- "
     .. "conservative rather than guessing it is self-only")

  moves.FIX_UNKNOWN_EFFECT = {
    id = "FIX_UNKNOWN_EFFECT", name = "FIX UNKNOWN", power = 0, accuracy = 100,
    type = "NORMAL", category = "status", pp = 20,
    effect = "NOT_A_REGISTERED_EFFECT",
  }
  eq(CoopBattle.needsTarget(c, { id = "FIX_UNKNOWN_EFFECT" }), true,
     "and a move whose effect record cannot be found keeps it too")

  -- Growl's family: a primary record, but accuracy-checked, so it does
  -- reach across the field unlike Swords Dance.
  moves.FIX_GROWL = {
    id = "FIX_GROWL", name = "FIX GROWL", power = 0, accuracy = 100,
    type = "NORMAL", category = "status", pp = 20, effect = "ATTACK_DOWN1_EFFECT",
  }
  eq(CoopBattle.needsTarget(c, { id = "FIX_GROWL" }), true,
     "an accuracy-checked status effect keeps the picker")

  -- The three proven exceptions: zero-power, primary, never accuracy-checked
  -- by the numbers -- and still not self-only, because each reads the target
  -- it is handed.
  for _, effect in ipairs({ "HAZE_EFFECT", "CONVERSION_EFFECT", "TRANSFORM_EFFECT" }) do
    check(data.move_effects[effect] ~= nil,
          ("the merged registry carries %s to test against"):format(effect))
    moves["FIX_" .. effect] = {
      id = "FIX_" .. effect, name = effect:sub(1, 9), power = 0, accuracy = 100,
      type = "NORMAL", category = "status", pp = 20, effect = effect,
    }
    eq(CoopBattle.needsTarget(c, { id = "FIX_" .. effect }), true,
       effect .. " keeps the picker even though the numbers say self-only")
  end

  eq(CoopBattle.needsTarget(c, nil), true,
     "a nil moveInst is conservative too, not a crash")
end)()

-- ------- a self-only move commits itself, straight from the move menu
--
-- Finding 2's other half: what the move menu actually does with the answer
-- above. A move `needsTarget` says no to is committed on the spot, with the
-- first living opponent as the (inert) wire target -- CoopSim.runAction never
-- reads it for a self-targeting effect. A damaging move on the same list
-- still opens the picker exactly as before.

;(function()
  local CoopBattle = need("CoopBattle")
  local sim = fieldSim({
    { side = "a", owner = "ann", name = "ANN",
      party = { mon(60, 50, { { id = "FIX_BOOST", pp = 20 },
                              { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "a", owner = "bob", name = "BOB",
      party = { mon(60, 45, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "b", owner = "cal", name = "CAL",
      party = { mon(60, 30, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "b", owner = "dee", name = "DEE",
      party = { mon(60, 20, { { id = "FIX_TACKLE", pp = 20 } }) } },
  })
  local committed = {}
  local client = setmetatable({
    sim = sim, host = false, mine = 1, messages = {}, phase = "move",
    moveIndex = 1,
    game = { data = data, save = { inventory = {}, party = {} } },
    commit = function(_, action) committed[#committed + 1] = action end,
  }, { __index = CoopBattle })
  local function pressA() return { wasPressed = function(_, k) return k == "a" end } end

  CoopBattle.updateMove(client, pressA())
  eq(#committed, 1, "a self-only move commits on its own, straight from the "
     .. "move menu")
  eq(committed[1].target, sim:targetsFor(sim:slot(1))[1].index,
     "with the first living opponent as the target -- inert, but present, "
     .. "so the wire shape is the one it always was")
  eq(client.phase, "move", "and the phase never became the picker for it")

  client.moveIndex = 2
  CoopBattle.updateMove(client, pressA())
  eq(#committed, 1, "the damaging move on the same list did not commit itself")
  eq(client.phase, "target", "it opens the picker exactly as before")
end)()

-- ------- the target picker is a list of both, not one name at a time
--
-- Finding 3. `drawTarget` shows both living opponents through `drawList`,
-- and `updateTarget` navigates the pair the way that list is drawn: LEFT and
-- RIGHT (as well as UP/DOWN, which hold -- there is no second row in a pair
-- of two) move the cursor, clamped rather than wrapping, matching every
-- other picker on this screen.

;(function()
  local CoopBattle = need("CoopBattle")
  local sim = fieldSim({
    { side = "a", owner = "ann", name = "ANN",
      party = { mon(60, 50, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "a", owner = "bob", name = "BOB",
      party = { mon(60, 45, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "b", owner = "cal", name = "CAL",
      party = { mon(60, 30, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "b", owner = "dee", name = "DEE",
      party = { mon(60, 20, { { id = "FIX_TACKLE", pp = 20 } }) } },
  })
  local client = setmetatable({
    sim = sim, host = false, mine = 1, messages = {}, phase = "target",
    moveIndex = 1, targetIndex = 1,
    game = { data = data, save = { inventory = {}, party = {} } },
  }, { __index = CoopBattle })
  local function press(key) return { wasPressed = function(_, k) return k == key end } end

  eq(#sim:targetsFor(sim:slot(1)), 2, "two living foes to aim the picker at")
  CoopBattle.updateTarget(client, press("right"))
  eq(client.targetIndex, 2, "RIGHT moves onto the second")
  CoopBattle.updateTarget(client, press("right"))
  eq(client.targetIndex, 2, "and clamps there -- it does not wrap back to the first")
  CoopBattle.updateTarget(client, press("left"))
  eq(client.targetIndex, 1, "LEFT returns")
  CoopBattle.updateTarget(client, press("up"))
  eq(client.targetIndex, 1, "UP holds -- there is no second row in a pair")
  client.targetIndex = 2
  CoopBattle.updateTarget(client, press("down"))
  eq(client.targetIndex, 2, "and so does DOWN")

  -- One foe faints: the picker clamps to the one still standing rather than
  -- pointing at a name that is no longer on the list.
  sim:slot(4).battler.mon.hp = 0
  eq(#sim:targetsFor(sim:slot(1)), 1, "one target left")
  CoopBattle.updateTarget(client, press("right"))
  eq(client.targetIndex, 1, "the clamp holds against a list that just got shorter")
  eq(client.phase, "target", "and the picker is still open -- one foe left is not none")

  -- Both faint: the picker cannot stay open on an empty list, and there is
  -- no key that would get a player out of it if it did.
  sim:slot(3).battler.mon.hp = 0
  CoopBattle.updateTarget(client, press("a"))
  eq(client.phase, "choose",
     "an empty target list backs out to the command menu instead of a picker "
     .. "with nothing on it")
end)()

-- ------- vertical target list: real navigation, not a coincidental clamp
--
-- The picker test above starts each direction already at the edge it is
-- checking, so UP and DOWN clamping there is indistinguishable from UP and
-- DOWN doing nothing at all. This starts away from both edges to show they
-- actually move the cursor -- the column `drawTarget`/`drawColumn` now draws
-- one name per row down, not two names side by side (LEFT/RIGHT staying
-- aliases is already pinned above).

;(function()
  local CoopBattle = need("CoopBattle")
  local sim = fieldSim({
    { side = "a", owner = "ann", name = "ANN",
      party = { mon(60, 50, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "a", owner = "bob", name = "BOB",
      party = { mon(60, 45, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "b", owner = "cal", name = "CAL",
      party = { mon(60, 30, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "b", owner = "dee", name = "DEE",
      party = { mon(60, 20, { { id = "FIX_TACKLE", pp = 20 } }) } },
  })
  local client = setmetatable({
    sim = sim, host = false, mine = 1, messages = {}, phase = "target",
    moveIndex = 1, targetIndex = 2,
    game = { data = data, save = { inventory = {}, party = {} } },
  }, { __index = CoopBattle })
  local function press(key) return { wasPressed = function(_, k) return k == key end } end

  CoopBattle.updateTarget(client, press("up"))
  eq(client.targetIndex, 1, "UP genuinely moves the cursor up the column")
  CoopBattle.updateTarget(client, press("up"))
  eq(client.targetIndex, 1, "and clamps at the top rather than wrapping")
  CoopBattle.updateTarget(client, press("down"))
  eq(client.targetIndex, 2, "DOWN moves it back down")
  CoopBattle.updateTarget(client, press("down"))
  eq(client.targetIndex, 2, "and clamps at the bottom")

  -- ------- foe scale, keyed off the layout, not off who is watching
  eq(CoopBattle.FOE_SCALE, 0.85,
     "the far pair draws fifteen percent smaller -- published for the suite "
     .. "since there is no graphics device here to measure a drawn pixel")
  eq(CoopBattle.scaleFor(client, 1), 1, "slots 1 and 2 draw at plain scale...")
  eq(CoopBattle.scaleFor(client, 2), 1, "...regardless of who is watching")
  eq(CoopBattle.scaleFor(client, 3), CoopBattle.FOE_SCALE,
     "slots 3 and 4 draw smaller...")
  eq(CoopBattle.scaleFor(client, 4), CoopBattle.FOE_SCALE,
     "...because that is where SLOT_POS puts them on every client")

  -- And that holds from every seat, not just this one -- `scaleFor` used to
  -- ask the viewer-relative `foeSide`, which shrank whichever pair the
  -- reader was *not* in: for the two players actually sitting in slots 3 and
  -- 4, that was their own pair drawn small in the corner with room to spare,
  -- while the opposition stood full size where the shrink exists to
  -- declutter. A slot-3 client must see its own pair exactly as small as
  -- everyone else does.
  local fromSlot3 = setmetatable({
    sim = sim, host = false, mine = 3, messages = {},
    game = { data = data, save = { inventory = {}, party = {} } },
  }, { __index = CoopBattle })
  eq(CoopBattle.scaleFor(fromSlot3, 3), CoopBattle.FOE_SCALE,
     "slot 3's own pair still draws small from slot 3's own seat")
  eq(CoopBattle.scaleFor(fromSlot3, 1), 1,
     "and slot 1's pair -- the opposition, from here -- still draws at plain "
     .. "scale")

  -- ------- foeSide: viewer-relative, and only ever a label
  --
  -- Unlike `scaleFor`, this one is genuinely about who is watching -- it
  -- answers "is this the side that is not mine", which is what a label
  -- should answer to and not what the layout is keyed off.
  check(not CoopBattle.foeSide(client, 1), "my own slot is not a foe")
  check(not CoopBattle.foeSide(client, 2), "neither is my partner's")
  check(CoopBattle.foeSide(client, 3), "the other side is")
  check(CoopBattle.foeSide(client, 4), "both of their slots")
  check(CoopBattle.foeSide(fromSlot3, 1), "from CAL's seat, ANN's slot is the foe")
  check(not CoopBattle.foeSide(fromSlot3, 3), "and CAL's own is not")

  -- ------- picOriginFor: one shared anchor for the pic, the cursor, the anim
  local fakeSprite = { getDimensions = function() return 56, 56 end }
  local rawX, rawY, rawScale = CoopBattle.picOriginFor(client, 3)
  check(rawX ~= nil and rawScale == 1,
        "with no sprite to measure, the offset falls back to plain scale and "
        .. "the raw position -- the same fallback drawField has always used")
  local adjX, adjY, adjScale = CoopBattle.picOriginFor(client, 3, fakeSprite)
  eq(adjScale, CoopBattle.FOE_SCALE, "measured, a foe slot reports the shrink")
  check(adjX > rawX and adjY > rawY,
        "and is pushed down and in to keep the sprite's feet and centreline "
        .. "where a full-size one had them")

  local allyRawX, allyRawY = CoopBattle.picOriginFor(client, 1)
  local allyX, allyY, allyScale = CoopBattle.picOriginFor(client, 1, fakeSprite)
  eq(allyScale, 1, "an ally slot never shrinks, sprite or not")
  eq(allyX, allyRawX, "so its position never moves for a sprite, either")
  eq(allyY, allyRawY, "same for the y")

  eq(CoopBattle.picOriginFor(client, 99), nil,
     "a slot with no position answers nil")

  -- ------- paint order: the hovered target comes forward while picking
  local order = CoopBattle.paintOrder(client)
  eq(order[#order], 4,
     "with the cursor on DEE (targetIndex 2), DEE paints last -- in front of "
     .. "everything else on the field")
  client.targetIndex = 1
  order = CoopBattle.paintOrder(client)
  eq(order[#order], 3, "moving the cursor to CAL brings CAL forward instead")

  -- Outside the target phase the spotlight decides it instead -- whoever is
  -- being narrated, or this client's own monster with nobody narrated yet.
  client.phase = "choose"
  client.acting = nil
  order = CoopBattle.paintOrder(client)
  eq(order[#order], client.mine,
     "with nobody narrated, your own monster paints last -- the one you are "
     .. "looking at while you decide")
  client.acting = 3
  order = CoopBattle.paintOrder(client)
  eq(order[#order], 3,
     "and whoever is being narrated takes it once a turn is playing out")
end)()

-- ------- the command box, against the engine's own 2x2 truth table
--
-- Finding 4, first half. FIGHT/ITEM top row, SWITCH/RUN bottom row --
-- BattleState.lua:1544-1557's own col/row decomposition and clamp, index
-- row-major, transferred directly rather than approximated. All sixteen
-- combinations, because a grid that is right on the ones anybody tries by
-- hand and wrong on the rest is how this shipped broken the first time.

;(function()
  local CoopBattle = need("CoopBattle")
  local NAMES = { "FIGHT", "ITEM", "SWITCH", "RUN" }
  local truth = {
    { 1, "left", 1 }, { 1, "right", 2 }, { 1, "up", 1 }, { 1, "down", 3 },
    { 2, "left", 1 }, { 2, "right", 2 }, { 2, "up", 2 }, { 2, "down", 4 },
    { 3, "left", 3 }, { 3, "right", 4 }, { 3, "up", 1 }, { 3, "down", 3 },
    { 4, "left", 3 }, { 4, "right", 4 }, { 4, "up", 2 }, { 4, "down", 4 },
  }
  for _, row in ipairs(truth) do
    local from, direction, expect = row[1], row[2], row[3]
    local client = setmetatable({ commandIndex = from }, { __index = CoopBattle })
    CoopBattle.updateCommand(client,
      { wasPressed = function(_, k) return k == direction end })
    eq(client.commandIndex, expect,
       ("%s %s from %s lands on %s"):format(
         NAMES[from], direction, NAMES[from], NAMES[expect]))
  end
end)()

-- ------- the move grid, and the hold rule a short list needs
--
-- Finding 4, second half. Drawn 2x2 like the command box, so it takes the
-- same rule -- except a move list can be shorter than four, and a direction
-- pointing at a slot nothing occupies has to hold rather than land on a row
-- that is not drawn (WideBattle.lua:351-377's own rule for the same shape
-- of grid).

;(function()
  local CoopBattle = need("CoopBattle")
  local function press(key) return { wasPressed = function(_, k) return k == key end } end

  local sim = fieldSim({
    { side = "a", owner = "ann", name = "ANN",
      party = { mon(60, 50, { { id = "FIX_TACKLE", pp = 20 },
                              { id = "FIX_TACKLE", pp = 20 },
                              { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "a", owner = "bob", name = "BOB",
      party = { mon(60, 45, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "b", owner = "cal", name = "CAL",
      party = { mon(60, 30, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "b", owner = "dee", name = "DEE",
      party = { mon(60, 20, { { id = "FIX_TACKLE", pp = 20 } }) } },
  })
  local client = setmetatable({
    sim = sim, host = false, mine = 1, messages = {}, phase = "move",
    moveIndex = 2,
    game = { data = data, save = { inventory = {}, party = {} } },
  }, { __index = CoopBattle })

  eq(#CoopBattle.liveMoves(client), 3, "three moves on the list")
  CoopBattle.updateMove(client, press("down"))
  eq(client.moveIndex, 2,
     "DOWN from the second move would be a fourth slot nothing draws -- it holds")

  client.moveIndex = 1
  CoopBattle.updateMove(client, press("down"))
  eq(client.moveIndex, 3, "DOWN from the first lands on the third -- that slot exists")

  client.moveIndex = 3
  CoopBattle.updateMove(client, press("right"))
  eq(client.moveIndex, 3, "RIGHT from the third would be a fourth slot too -- it holds as well")

  -- With one move, every arrow holds -- there is nowhere else to go.
  local lone = fieldSim({
    { side = "a", owner = "ann", name = "ANN",
      party = { mon(60, 50, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "a", owner = "bob", name = "BOB",
      party = { mon(60, 45, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "b", owner = "cal", name = "CAL",
      party = { mon(60, 30, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "b", owner = "dee", name = "DEE",
      party = { mon(60, 20, { { id = "FIX_TACKLE", pp = 20 } }) } },
  })
  local loner = setmetatable({
    sim = lone, host = false, mine = 1, messages = {}, phase = "move",
    moveIndex = 1,
    game = { data = data, save = { inventory = {}, party = {} } },
  }, { __index = CoopBattle })
  for _, direction in ipairs({ "left", "right", "up", "down" }) do
    CoopBattle.updateMove(loner, press(direction))
    eq(loner.moveIndex, 1, direction .. " holds with only one move on the list")
  end
end)()

-- ------- the gap between two lines is not a stage for the wait line
--
-- Dismissing a line leaves `shown` empty for one tick before the next row is
-- popped. drawMessage's fallback used to run in that gap, so with a
-- replacement pause overlapping a playing batch the box flashed
-- "X is choosing... (n)" for a single frame between every pair of battle
-- lines -- reported as "the battle kinda flickers during a moment of
-- waiting". The fallback belongs to a finished queue only.

;(function()
  local CoopBattle = need("CoopBattle")
  local sim = fieldSim({
    { side = "a", owner = "ann", name = "ANN",
      party = { mon(90, 50, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "a", owner = "bob", name = "BOB",
      party = { mon(90, 40, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "b", owner = "cal", name = "CAL",
      party = { mon(1, 30, { { id = "FIX_TACKLE", pp = 20 } }),
                mon(90, 25, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "b", owner = "dee", name = "DEE",
      party = { mon(90, 20, { { id = "FIX_TACKLE", pp = 20 } }) } },
  })
  -- A replacement pause is live (CAL owes a monster), so waitingOn answers --
  -- and the client is mid-batch with one line dismissed and one still queued:
  -- the exact frame that used to flash the countdown.
  sim:resolveTurn({ { slot = 1, move = 1, target = 3 } })
  check(sim:awaitingChoice() ~= nil, "a choice is pending while the batch plays")
  local client = setmetatable({
    sim = sim, host = false, mine = 1, phase = "messages", shown = nil,
    messages = { { text = "NEXT LINE" } },
    waitShown = Config.COOP_WAIT_HINT + 2,
    game = { data = data, save = { inventory = {}, party = {} } },
  }, { __index = CoopBattle })

  check(CoopBattle.waitLine(client) ~= nil,
        "the countdown line is available in this state -- the hazard is real")
  -- The REAL decision, not a mirror of it. The first version of this test
  -- copied drawMessage's logic into the test and passed with the guard
  -- removed -- a test of nothing. boxText is the method drawMessage draws.
  local function boxTextOf(c) return CoopBattle.boxText(c) end
  eq(boxTextOf(client), "",
     "mid-batch, the one-tick gap draws the empty page gap, not the countdown")
  client.shown = "A LINE"
  eq(boxTextOf(client), "A LINE", "a shown line always wins")
  client.shown = nil
  client.phase = "wait"
  client.messages = {}
  check(boxTextOf(client) ~= "",
        "and once the queue is truly over, the reassurance lines return")
end)()

-- ------- a co-op battle tells the rest of the game it happened
--
-- **The engine's own `battle.started` and `battle.ended` never fire for one.**
-- `battle.started` is emitted from `BattleState:enter`, and the trainer battle
-- a co-op one displaces is taken off the stack before it ever enters;
-- `battle.ended` is emitted from `BattleState:finish`, and the co-op flow calls
-- that battle's `onFinish` directly rather than finishing it. So a mod watching
-- the engine sees nothing at all -- not a co-op battle starting, and not a
-- trainer being beaten by two people.
--
-- A mod cannot emit an engine event: `mod.events:emit` is namespaced to
-- `mod.<id>.*` so that no mod can forge one. So the mod emits its own pair,
-- and what matters is that the payload is worth listening to -- a listener
-- that has to reach into `battle` for everything might as well not have been
-- told.

;(function()
  local CoopBattle = need("CoopBattle")

  -- `false` for a slot nobody owns, never nil: a table constructor drops
  -- trailing nils, so { "ann", "bob", nil, nil } is a list of *two* and the
  -- field would quietly be built with two slots instead of four.
  local function fieldOf(owners)
    local built = {}
    for i = 1, #owners do
      local owner = owners[i] or nil
      built[i] = { side = (i <= 2) and "a" or "b",
                   owner = owner ~= false and owner or nil,
                   name = owner and tostring(owner):upper() or "FOE",
                   party = { mon(90, 60 - i * 5,
                                 { { id = "FIX_TACKLE", pp = 20 } }) } }
    end
    return fieldSim(built)
  end

  local function heard(name)
    for _, row in ipairs(stubEvents) do
      if row.name == name then return row.payload end
    end
    return nil
  end

  -- Against a trainer: two humans and two slots belonging to nobody.
  stubEvents = {}
  local npc = setmetatable({
    sim = fieldOf({ "ann", "bob", false, false }), host = true, mine = 1,
    messages = {}, ranksPoints = false, trainer = { id = "OPP_BUG_CATCHER" },
    game = { data = data, save = { inventory = {}, party = {} } },
  }, { __index = CoopBattle })
  CoopBattle.enter(npc)

  local started = heard("mod.rby_mmo.coop_battle_started")
  check(started ~= nil, "a co-op battle announces that it started")
  if started then
    eq(started.kind, "npc", "saying what kind of battle it is -- as a word")
    eq(started.fighters, 4, "how many are on the field")
    eq(started.humans, 2, "and how many of them are people")
    eq(started.mine, 1, "which one this client is")
    eq(started.side, "a", "and which side that puts them on")
    eq(started.host, true, "whether this client is the one simulating")
    eq(started.trainerId, "OPP_BUG_CATCHER", "who they are fighting")
    eq(started.ranked, false, "and whether it is worth any points")
    eq(#(started.slots or {}), 4, "with a row per slot")
    eq(started.slots[1].name, "ANN", "naming each trainer")
    check(started.slots[1].species ~= nil, "and what they sent out")
    eq(started.slots[3].owner, nil, "an NPC slot belongs to nobody")
  end

  -- The pair: ending is announced too, with the result.
  stubEvents = {}
  npc.result = "win"
  npc.onDone = function() end
  CoopBattle.exit(npc)
  local ended = heard("mod.rby_mmo.coop_battle_ended")
  check(ended ~= nil, "and announces that it ended")
  if ended then
    eq(ended.result, "win", "carrying how it went")
    eq(ended.kind, "npc", "and the same shape as the start, so one listener "
       .. "can read both")
  end

  -- Against another party: four humans, and `kind` says so. This is the field
  -- the old payload could not describe at all -- it reported the slot *count*
  -- under the name `kind`, so a listener asking "is this a party battle?" got
  -- 4 and could only be wrong.
  stubEvents = {}
  local versus = setmetatable({
    sim = fieldOf({ "ann", "bob", "cal", "dee" }), host = false, mine = 3,
    messages = {}, ranksPoints = true,
    game = { data = data, save = { inventory = {}, party = {} } },
  }, { __index = CoopBattle })
  CoopBattle.enter(versus)
  local party = heard("mod.rby_mmo.coop_battle_started")
  check(party ~= nil, "a party battle announces itself too")
  if party then
    eq(party.kind, "party", "and is a different kind of battle")
    eq(party.humans, 4, "with four people in it")
    eq(party.mine, 3, "seen from whichever seat this client is in")
    eq(party.side, "b", "on whichever side that is")
    eq(party.host, false, "and this one is not the host")
    eq(party.trainerId, nil, "there is no trainer to name")
    eq(party.ranked, true, "and it is worth points")
  end
  stubEvents = {}
end)()

-- ------- what a co-op battle is worth, and what it is not
--
-- **An NPC co-op battle pays no ranked points, deliberately.** Elo rates you
-- against an opponent's rating and a trainer has none, so there is nothing for
-- the curve to say. Inventing one from the trainer's party would be worse than
-- silence: NPCs are an infinite, respawning supply, and the rematch discount
-- -- the one thing that stops a rating being farmed -- is keyed on pairs of
-- *players* and would never fire against a trainer. Two friends could grind
-- gym leaders to the top of the board without ever meeting anybody.
--
-- It was already the behaviour. What it was not was a decision: it fell out of
-- `coopMatches` only ever being created on the four-human path, it lived as an
-- inline condition in two places, nothing asserted it, and -- worst -- nothing
-- told the player, who won a battle and watched a number not move.

;(function()
  local Coop = need("Coop")

  -- The rule itself, in the one place it is now written down.
  check(Coop.ranksPoints({ hostId = "ann",
    allies = { { id = "ann" }, { id = "bob" } },
    foes = { { id = "cal" }, { id = "dee" } } }),
    "a battle against another party is worth points")
  check(not Coop.ranksPoints({ hostId = "ann",
    allies = { { id = "ann" }, { id = "bob" } },
    engine = { enemyParty = {} } }),
    "a battle against a trainer is not")
  check(not Coop.ranksPoints({ hostId = "ann", foes = {} }),
        "and neither is one with an empty other side")
  check(not Coop.ranksPoints(nil), "nor no plan at all")

  -- ...and it is the same answer the badge decision reads, because both are
  -- the same question -- "are the other two people?" -- and a second copy of
  -- it would be a second copy to get out of step.
  local assembler = setmetatable({}, { __index = Coop })
  local packed = { "packed" }
  local versus = assembler:buildField({ data = data }, {
    parties = { ann = packed, bob = packed, cal = packed, dee = packed },
    badges = { ann = { BOULDERBADGE = true } },
    plan = { hostId = "ann",
             allies = { { id = "ann", name = "ANN" }, { id = "bob", name = "BOB" } },
             foes = { { id = "cal", name = "CAL" }, { id = "dee", name = "DEE" } } },
  }, {})
  check(versus ~= nil and versus.slots[1].badges == nil,
        "the battle that pays points is the battle where badges do not count "
        .. "-- one rule, read in both places")
end)()

-- ------- and the player is told, once
--
-- The half that was actually missing. A player who wins a 2-on-2 against a
-- trainer and is never told why their rating did not move concludes the
-- ranking is broken. Said on a win, because that is when they would look --
-- and once per session, because a rule explained is a courtesy and a rule
-- repeated after every fight is a nag.

;(function()
  local CoopBattle = need("CoopBattle")
  local said = {}
  local function fourSlots()
    return fieldSim({
      { side = "a", owner = "ann", name = "ANN",
        party = { mon(90, 50, { { id = "FIX_TACKLE", pp = 20 } }) } },
      { side = "a", owner = "bob", name = "BOB",
        party = { mon(90, 40, { { id = "FIX_TACKLE", pp = 20 } }) } },
      { side = "b", owner = "cal", name = "CAL",
        party = { mon(90, 30, { { id = "FIX_TACKLE", pp = 20 } }) } },
      { side = "b", owner = "dee", name = "DEE",
        party = { mon(90, 20, { { id = "FIX_TACKLE", pp = 20 } }) } },
    })
  end
  local function battle(ranks)
    return setmetatable({
      sim = fourSlots(), host = false, mine = 1,
      messages = {}, ranksPoints = ranks, turnCount = 1,
      game = { data = data, save = { inventory = {}, party = {} } },
      say = function(_, text) said[#said + 1] = text end,
    }, { __index = CoopBattle })
  end
  local function saidIt()
    for _, text in ipairs(said) do
      if tostring(text):find("No points", 1, true) then return true end
    end
    return false
  end

  CoopBattle.saidUnranked = nil

  -- Losing is not the moment: nobody expects points for losing.
  said = {}
  CoopBattle.playEvents(battle(false), { { kind = "over", winner = "b" } })
  check(not saidIt(), "losing an unranked battle explains nothing")

  -- Winning one is.
  said = {}
  CoopBattle.playEvents(battle(false), { { kind = "over", winner = "a" } })
  check(saidIt(), "winning one says why it paid nothing")

  -- ...and only the first time.
  said = {}
  CoopBattle.playEvents(battle(false), { { kind = "over", winner = "a" } })
  check(not saidIt(), "and does not say it again for the rest of the session")

  -- A battle that *does* pay never says it, whether or not it has been said.
  CoopBattle.saidUnranked = nil
  said = {}
  CoopBattle.playEvents(battle(true), { { kind = "over", winner = "a" } })
  check(not saidIt(), "a battle that pays points explains nothing -- there is "
        .. "nothing to explain")
  CoopBattle.saidUnranked = nil
end)()

-- ------- badges reach the field they were earned for
--
-- Gen 1 gives the player x9/8 on a stat per badge, and the engine applies it
-- from the battler's own `badges` set -- which `makeBattler` fills only when
-- it is handed a save. A co-op battle is built by the host, and the host holds
-- one save out of four, so every battler was built with `nil` and **nobody's
-- badges counted**: two players beating a trainer together hit weaker than
-- either of them would have done alone.
--
-- The set therefore travels with the party it belongs to, and is applied where
-- the engine would apply it -- which is not everywhere. See buildField.

;(function()
  local Damage = require("src.battle.Damage")
  local rows = (data.constants and data.constants.badgeBoosts)
    or Damage.BADGE_BOOSTS
  local attack
  for _, row in ipairs(rows or {}) do
    if row.stat == "attack" then attack = row.badge end
  end
  if not attack then
    check(true, "(this build has no attack badge to boost)")
    return
  end

  -- A hitter, not the shared `mon` helper: its attack is 30, and x9/8 of 30
  -- is 33 -- a rise the damage formula floors away entirely at this level, so
  -- a correct badge would read as a broken one.
  local function hitter()
    return { species = species, level = 20, hp = 200,
             stats = { hp = 200, attack = 240, defense = 30,
                       special = 30, speed = 50 },
             moves = { { id = "FIX_TACKLE", pp = 20 } } }
  end

  local function fieldWith(badges)
    return fieldSim({
      { side = "a", owner = "ann", name = "ANN", badges = badges,
        party = { hitter() } },
      { side = "a", owner = "bob", name = "BOB",
        party = { mon(200, 40, { { id = "FIX_TACKLE", pp = 20 } }) } },
      { side = "b", owner = nil, name = "FOE",
        party = { mon(400, 30, { { id = "FIX_TACKLE", pp = 20 } }) } },
      { side = "b", owner = nil, name = "FOE",
        party = { mon(400, 20, { { id = "FIX_TACKLE", pp = 20 } }) } },
    })
  end

  local bare = fieldWith(nil)
  eq(bare:slot(1).battler.badges, nil,
     "a trainer who brought no badges has no badge set")

  local badged = fieldWith({ [attack] = true })
  check(badged:slot(1).battler.badges ~= nil,
        "and one who did has the set the engine reads")
  eq(badged:slot(1).battler.badges[attack], true, "carrying the badge itself")

  -- ...and it is worth something, asserted at the point where it can be:
  -- straight through the engine's own damage calculation, with the two
  -- battlers the co-op field built and the crit pinned off.
  --
  -- **The crit has to be pinned, and that is a fact about Gen 1 rather than
  -- about this test.** `gen1_faithful` sets `critIgnoresStages`, and a
  -- critical hit recomputes from unmodified stats -- so it skips stat stages
  -- *and* badge boosts together. This harness's rng returns its argument,
  -- which crits every time, so a badge measured through resolveTurn here
  -- would read as worth nothing whether it worked or not.
  local Damage = require("src.battle.Damage")
  local ruleset = (data.rulesets and data.rulesets.gen1_faithful) or {}
  local move = data.moves.FIX_TACKLE
  local target = bare:slot(3).battler
  local rng = function(a) return a end

  local plain = Damage.compute(ruleset, bare:slot(1).battler, target, move,
                               { rng = rng, forceCrit = false })
  local boosted = Damage.compute(ruleset, badged:slot(1).battler, target, move,
                                 { rng = rng, forceCrit = false })
  check(plain > 0 and boosted > 0, "both attacks land")
  check(boosted > plain,
        "a badge earned in the single-player game is worth something in a "
        .. "co-op battle -- it used to be worth nothing")

  -- ...and on a critical hit it is worth nothing, to both of them equally,
  -- which is the original's rule and not a bug in the line above.
  eq(Damage.compute(ruleset, badged:slot(1).battler, target, move,
                    { rng = rng, forceCrit = true }),
     Damage.compute(ruleset, bare:slot(1).battler, target, move,
                    { rng = rng, forceCrit = true }),
     "a critical hit ignores badge boosts, as it ignores stat stages")

  -- ------- and what the wire will accept
  eq(Wire.badges(nil), nil, "no badges is not a badge set")
  eq(Wire.badges({}), nil, "and neither is an empty list")
  eq(Wire.badges("BOULDERBADGE"), nil, "a bare string is not a list of them")
  local ok = Wire.badges({ attack, attack })
  check(ok ~= nil and ok[attack] == true, "a list becomes the set the engine reads")
  local counted = 0
  for _ in pairs(ok) do counted = counted + 1 end
  eq(counted, 1, "with a repeat counted once")
  local long = {}
  for i = 1, Config.COOP_BADGES_MAX + 20 do long[i] = "BADGE_" .. i end
  local bounded = Wire.badges(long)
  local size = 0
  for _ in pairs(bounded or {}) do size = size + 1 end
  check(size <= Config.COOP_BADGES_MAX,
        "and a list longer than the cap is cut to it rather than forwarded")
  eq(Wire.badges({ "not a badge!" }), nil,
     "an id that is not id-shaped is dropped, not indexed")
end)()

-- ------- two parties meet on even terms
--
-- The other half of the decision, and the one that is easy to get wrong by
-- being generous. `BattleState.makeBattler` says it in its own comment --
-- "LinkBattle builds clamped copies with save=nil (no badge boosts)" -- so the
-- engine's own human-versus-human battle gives neither side theirs. A party
-- battle that handed them out would be a different game from a link battle,
-- and would do it *asymmetrically*: the engine gates badges on `isPlayer`,
-- which on this shared field is a fact about which side you stand on, so side
-- A would get boosts and side B could not.

;(function()
  local Coop = need("Coop")
  local CoopBattle = need("CoopBattle")
  local assembler = setmetatable({}, { __index = Coop })
  local packed = { "packed-party" }
  local badges = { BOULDERBADGE = true }

  local function fieldFor(plan)
    return assembler:buildField({ data = data }, {
      parties = { ann = packed, bob = packed, cal = packed, dee = packed },
      badges = { ann = badges, bob = badges, cal = badges, dee = badges },
      plan = plan,
    }, {})
  end

  -- Four humans: nobody's badges are on the field.
  local versus = fieldFor({
    hostId = "ann",
    allies = { { id = "ann", name = "ANN" }, { id = "bob", name = "BOB" } },
    foes = { { id = "cal", name = "CAL" }, { id = "dee", name = "DEE" } },
  })
  check(versus ~= nil, "a party-versus-party field assembles")
  for _, slot in ipairs(versus and versus.slots or {}) do
    eq(slot.badges, nil,
       (slot.name or "?") .. " brings no badge boosts to a party battle")
  end

  -- Two humans against a trainer: they do.
  local trainerId
  for id, record in pairs(data.trainers or {}) do
    if record.parties and record.parties[1] and #record.parties[1] > 0 then
      trainerId = id break
    end
  end
  if trainerId then
    local enemy = CoopBattle.trainerParty({ data = data }, trainerId, 1)
    local npc = fieldFor({
      hostId = "ann", label = "TRAINER",
      allies = { { id = "ann", name = "ANN" }, { id = "bob", name = "BOB" } },
      engine = { enemyParty = enemy, trainer = { id = trainerId } },
    })
    check(npc ~= nil, "an NPC co-op field assembles")
    local withBadges, without = 0, 0
    for _, slot in ipairs(npc and npc.slots or {}) do
      if slot.badges then withBadges = withBadges + 1 else without = without + 1 end
    end
    eq(withBadges, 2, "both players bring their badges to a trainer battle")
    eq(without, 2, "and the trainer's two bring none -- badges are the "
       .. "player's side of a Gen 1 battle")
  end
end)()

-- ------- the replay contract
--
-- **The single most important invariant in the whole design.** One client
-- resolves and the other three apply what it says happened; if a turn's events
-- are not enough to rebuild the field from them, the three replayers are
-- looking at a battle that is not the one being played. Every fault this
-- feature has had at the protocol level has been a violation of exactly this,
-- and each one survived because nothing asserted it: HP that never moved for
-- an attack, a replacement the host filed as a turn, a snapshot that rewound
-- the wrong client.
--
-- Two things make this a real test rather than a restatement of the code:
--
--   1. **The replayer is the real one.** `CoopBattle.playEvents` is called
--      through the metatable on a stand-in carrying only the fields it reads,
--      so this exercises the path a client actually runs. A hand-written copy
--      of "what a replayer does" would agree with itself forever while the
--      shipped code drifted out from under it.
--   2. **The comparison is the one the wire makes.** `signature()`, slot for
--      slot, exactly as CoopBattle compares the host's stamp against its own.
--
-- Checked after *every* turn, never only at the end: a divergence that is
-- corrected by a later event still means somebody watched a wrong number.

;(function()

local CoopBattle = need("CoopBattle")
if not CoopBattle.loadEngine() then
  check(true, "(the engine's battle modules are unavailable here)")
  return
end

-- A fresh description each call. The two fields must not share a single mon
-- table, or the host damaging its copy would silently damage the replayer's
-- and every comparison would pass for the worst possible reason.
local function describe(build)
  local out = {}
  for _, raw in ipairs(build) do
    local party = {}
    for _, entry in ipairs(raw.party) do
      local moves = {}
      for _, mv in ipairs(entry.moves) do
        moves[#moves + 1] = { id = mv.id, pp = mv.pp }
      end
      party[#party + 1] = mon(entry.hp, entry.speed, moves)
    end
    out[#out + 1] = { side = raw.side, owner = raw.owner, name = raw.name,
                      party = party }
  end
  return out
end

-- The client, as thin as it can be and still be the real thing: `playEvents`
-- reads `sim`, `host`, `mine`, `messages`, `game` and calls its own `say`,
-- `gainExp`, `learnMove` and `resultFor` -- all of which come off the
-- metatable, not from here.
local function replayer(sim, mine)
  return setmetatable({
    sim = sim, host = false, mine = mine, messages = {}, pending = {},
    game = { data = data, save = { inventory = {}, party = {} } },
  }, { __index = CoopBattle })
end

-- One scenario: build both fields, run the turns on the host, replay the
-- events on the guest, and compare after each. `turns` is a list of functions
-- that each return a list of actions -- a function so a scenario can look at
-- the host's live field to decide what to do next.
local function conform(what, build, turns, mine)
  local host = fieldSim(describe(build))
  local guest = fieldSim(describe(build))
  local client = replayer(guest, mine or 1)

  if guest:signature() ~= host:signature() then
    check(false, what .. ": the two copies start identical")
    return host, guest, client
  end

  for i, turn in ipairs(turns) do
    if host.over then break end
    local actions = turn(host)
    local events = host:resolveTurn(actions)
    CoopBattle.playEvents(client, events)
    if guest:signature() ~= host:signature() then
      check(false, ("%s: the replayer matches the host after turn %d"):format(what, i))
      print(("    host  %s"):format(host:signature()))
      print(("    guest %s"):format(guest:signature()))
      return host, guest, client
    end
  end
  check(true, what .. ": the replayer matches the host after every turn")
  return host, guest, client
end

local function tackle(n) return { id = "FIX_TACKLE", pp = n or 20 } end

-- ------- four humans trading blows until somebody falls
--
-- The ordinary case, and the one that was broken: the engine's move pipeline
-- writes HP straight onto the monster, so a turn that announced nothing left
-- every bar frozen.
local FOUR = {
  { side = "a", owner = "ann", name = "ANN",
    party = { { hp = 120, speed = 50, moves = { tackle() } },
              { hp = 120, speed = 45, moves = { tackle() } } } },
  { side = "a", owner = "bob", name = "BOB",
    party = { { hp = 120, speed = 40, moves = { tackle() } },
              { hp = 120, speed = 35, moves = { tackle() } } } },
  { side = "b", owner = "cal", name = "CAL",
    party = { { hp = 120, speed = 30, moves = { tackle() } },
              { hp = 120, speed = 25, moves = { tackle() } } } },
  { side = "b", owner = "dee", name = "DEE",
    party = { { hp = 120, speed = 20, moves = { tackle() } },
              { hp = 120, speed = 15, moves = { tackle() } } } },
}

local function allAttack()
  return { { slot = 1, move = 1, target = 3 }, { slot = 2, move = 1, target = 4 },
           { slot = 3, move = 1, target = 1 }, { slot = 4, move = 1, target = 2 } }
end

local brawl = {}
for _ = 1, 12 do brawl[#brawl + 1] = allAttack end
conform("four humans attacking", FOUR, brawl)

-- ...and from the seat of a player on the *other* side, because `mine` is what
-- decides which events a client applies to itself.
conform("seen from the other side", FOUR, brawl, 3)

-- ------- and the harness has teeth
--
-- A test that compares two copies is worth exactly what it is worth when they
-- differ. One damage event dropped on the floor -- the precise shape of the
-- bug this exists for -- must be caught, or every green run above means
-- nothing.
;(function()
  local host = fieldSim(describe(FOUR))
  local guest = fieldSim(describe(FOUR))
  local client = replayer(guest, 1)
  local events = host:resolveTurn(allAttack())
  local kept, dropped = {}, false
  for _, event in ipairs(events) do
    if event.kind == "damage" and not dropped then dropped = true
    else kept[#kept + 1] = event end
  end
  check(dropped, "a turn of four attacks produces at least one damage event")
  CoopBattle.playEvents(client, kept)
  check(guest:signature() ~= host:signature(),
        "and losing one of them is caught -- the comparison is not vacuous")
end)()

-- ------- a switch by choice
conform("a switch mid-battle", FOUR, {
  allAttack,
  function() return { { slot = 1, kind = "switch", index = 2 },
                      { slot = 3, move = 1, target = 1 },
                      { slot = 4, move = 1, target = 2 } } end,
  allAttack,
  function() return { { slot = 3, kind = "switch", index = 2 },
                      { slot = 1, move = 1, target = 3 } } end,
  allAttack,
})

-- ------- a status move, which changes a stage and no HP
--
-- The silent case: nothing about the field's numbers moves, so a replayer that
-- was quietly re-simulating rather than replaying would still agree here. It
-- is in the list because a turn that emits only text must also leave the two
-- copies equal.
conform("a status move", {
  { side = "a", owner = "ann", name = "ANN",
    party = { { hp = 200, speed = 50, moves = { { id = "FIX_BOOST", pp = 20 } } } } },
  { side = "a", owner = "bob", name = "BOB",
    party = { { hp = 200, speed = 40, moves = { tackle() } } } },
  { side = "b", owner = "cal", name = "CAL",
    party = { { hp = 200, speed = 30, moves = { tackle() } } } },
  { side = "b", owner = "dee", name = "DEE",
    party = { { hp = 200, speed = 20, moves = { tackle() } } } },
}, { allAttack, allAttack, allAttack })

-- ------- a charge move, which spans two turns
--
-- Half a move on turn one and the rest on turn two. A replayer holds no
-- `charging` state of its own -- it never runs an effect -- so what has to
-- survive is that the HP it is told about lands on the right turn.
conform("a charge move", {
  { side = "a", owner = "ann", name = "ANN",
    party = { { hp = 200, speed = 50, moves = { { id = "FIX_CHARGE", pp = 10 } } } } },
  { side = "a", owner = "bob", name = "BOB",
    party = { { hp = 200, speed = 40, moves = { tackle() } } } },
  { side = "b", owner = "cal", name = "CAL",
    party = { { hp = 200, speed = 30, moves = { tackle() } } } },
  { side = "b", owner = "dee", name = "DEE",
    party = { { hp = 200, speed = 20, moves = { tackle() } } } },
}, { allAttack, allAttack, allAttack, allAttack })

-- ------- out of PP, which is Struggle and its recoil
--
-- Recoil takes HP off the *attacker*, which is the case a "damage goes to the
-- target" assumption gets wrong -- and the announcement has to cover whoever
-- lost it, not whoever was aimed at.
conform("struggling with no PP", {
  { side = "a", owner = "ann", name = "ANN",
    party = { { hp = 200, speed = 50, moves = { tackle(0) } } } },
  { side = "a", owner = "bob", name = "BOB",
    party = { { hp = 200, speed = 40, moves = { tackle() } } } },
  { side = "b", owner = "cal", name = "CAL",
    party = { { hp = 200, speed = 30, moves = { tackle() } } } },
  { side = "b", owner = "dee", name = "DEE",
    party = { { hp = 200, speed = 20, moves = { tackle() } } } },
}, { allAttack, allAttack, allAttack })

-- ------- an NPC pair, whose moves only the host ever chooses
--
-- Two of the four slots belong to nobody, so their actions are decided on the
-- host and exist nowhere else. If a turn's events did not carry what an NPC
-- did, the replayers would be watching two monsters that never act.
conform("an NPC pair", {
  { side = "a", owner = "ann", name = "ANN",
    party = { { hp = 150, speed = 50, moves = { tackle() } } } },
  { side = "a", owner = "bob", name = "BOB",
    party = { { hp = 150, speed = 40, moves = { tackle() } } } },
  { side = "b", owner = nil, name = "FOE",
    party = { { hp = 150, speed = 30, moves = { tackle() } } } },
  { side = "b", owner = nil, name = "FOE",
    party = { { hp = 150, speed = 20, moves = { tackle() } } } },
}, {
  function(host)
    local actions = { { slot = 1, move = 1, target = 3 },
                      { slot = 2, move = 1, target = 4 } }
    for _, index in ipairs({ 3, 4 }) do
      local npc = host:npcAction(host:slot(index))
      if npc then actions[#actions + 1] = npc end
    end
    return actions
  end,
  function(host)
    local actions = { { slot = 1, move = 1, target = 3 },
                      { slot = 2, move = 1, target = 4 } }
    for _, index in ipairs({ 3, 4 }) do
      local npc = host:npcAction(host:slot(index))
      if npc then actions[#actions + 1] = npc end
    end
    return actions
  end,
})

-- ------- a faint, the pause, and the replacement that ends it
--
-- The replacement is not part of a turn -- it is answered while the field is
-- stopped -- so it travels as its own message and its events go through the
-- same replay path. This is where the deadlock lived, and where a replayer can
-- most easily end up with the wrong monster on the field.
;(function()
  local build = {
    { side = "a", owner = "ann", name = "ANN",
      party = { { hp = 400, speed = 50, moves = { tackle() } } } },
    { side = "a", owner = "bob", name = "BOB",
      party = { { hp = 400, speed = 40, moves = { tackle() } } } },
    { side = "b", owner = "cal", name = "CAL",
      party = { { hp = 1, speed = 30, moves = { tackle() } },
                { hp = 400, speed = 25, moves = { tackle() } } } },
    { side = "b", owner = "dee", name = "DEE",
      party = { { hp = 400, speed = 20, moves = { tackle() } } } },
  }
  local host = fieldSim(describe(build))
  local guest = fieldSim(describe(build))
  local client = replayer(guest, 1)

  CoopBattle.playEvents(client,
    host:resolveTurn({ { slot = 1, move = 1, target = 3 } }))
  eq(guest:signature(), host:signature(),
     "a faint leaves the replayer where the host is")
  local waiting = host:awaitingChoice()
  check(waiting ~= nil and waiting.index == 3,
        "and the field is stopped, waiting on that slot's owner")

  -- The owner answers. On the host this is `replace`; on the other three it is
  -- whatever `replace` emitted, replayed.
  local sent = {}
  check(host:replace(3, 2, function(event) sent[#sent + 1] = event end),
        "the owner's choice is accepted")
  CoopBattle.playEvents(client, sent)
  eq(guest:signature(), host:signature(),
     "and the replayer sends out the same monster the host did")
  eq(guest:slot(3).active, 2, "which is the one that was chosen")
  eq(host:awaitingChoice(), nil, "with the field moving again")

  CoopBattle.playEvents(client, host:resolveTurn(allAttack()))
  eq(guest:signature(), host:signature(),
     "and the turn after a replacement still agrees")
end)()

-- ------- somebody closes the game
--
-- A forfeit is not announced as a turn event at all: the host writes the slot
-- off and tells the other three separately. It is in this list because "gone"
-- is part of the signature, so a client that missed one would disagree about
-- who is still in the fight -- and about whether the battle is over.
;(function()
  local host = fieldSim(describe(FOUR))
  local guest = fieldSim(describe(FOUR))
  local client = replayer(guest, 1)

  CoopBattle.playEvents(client, host:resolveTurn(allAttack()))
  eq(guest:signature(), host:signature(), "the two copies agree before anyone leaves")

  local left = host:forfeit("dee")
  check(left ~= nil and left.index == 4, "the host writes off the player who left")
  check(guest:forfeit("dee") ~= nil, "and the message puts the others in step")
  eq(guest:signature(), host:signature(), "which leaves the copies equal again")

  CoopBattle.playEvents(client, host:resolveTurn({
    { slot = 1, move = 1, target = 3 }, { slot = 2, move = 1, target = 3 },
    { slot = 3, move = 1, target = 1 },
  }))
  eq(guest:signature(), host:signature(),
     "and the battle carries on three ways, still in step")
end)()

-- ------- and the host has to accept the answer when it comes off the wire
--
-- Everything above drives the host directly. The other half of the contract is
-- how a *message* reaches it, and that is where the replacement deadlock lived:
-- a non-host's choice arrives down the same wire as an ordinary action, and
-- the host filed it in the queue of pending turn actions and then asked itself
-- to resolve -- which it refuses to do while any slot is awaiting. The pause
-- waited on itself. Driven through the real `drainNet`, because the routing
-- decision *is* the bug.
;(function()
  local build = {
    { side = "a", owner = "ann", name = "ANN",
      party = { { hp = 400, speed = 50, moves = { tackle() } } } },
    { side = "a", owner = "bob", name = "BOB",
      party = { { hp = 400, speed = 40, moves = { tackle() } } } },
    { side = "b", owner = "cal", name = "CAL",
      party = { { hp = 1, speed = 30, moves = { tackle() } },
                { hp = 400, speed = 25, moves = { tackle() } } } },
    { side = "b", owner = "dee", name = "DEE",
      party = { { hp = 400, speed = 20, moves = { tackle() } } } },
  }
  local host = fieldSim(describe(build))
  local inbox, sent = {}, {}
  local hostClient = setmetatable({
    sim = host, host = true, mine = 1, messages = {}, pending = {}, seq = 0,
    game = { data = data, save = { inventory = {}, party = {} } },
    net = {
      poll = function() local out = inbox; inbox = {}; return out end,
      send = function(payload) sent[#sent + 1] = payload end,
    },
  }, { __index = CoopBattle })

  host:resolveTurn({ { slot = 1, move = 1, target = 3 } })
  local waiting = host:awaitingChoice()
  check(waiting ~= nil and waiting.index == 3,
        "the field is waiting on the player whose monster fell")

  -- CAL answers, from another machine. Shaped exactly as CoopBattle:sendAction
  -- puts it on the wire, and stamped with the sender the way Coop does.
  inbox[#inbox + 1] = { t = "act", from = "cal",
                        action = { slot = 3, index = 2 } }
  CoopBattle.drainNet(hostClient)

  eq(host:awaitingChoice(), nil,
     "a replacement off the wire is applied rather than queued as a turn")
  eq(host:slot(3).active, 2, "with the monster its owner actually chose")
  eq(hostClient.pending[3], nil,
     "and nothing is left in the pending actions to be resolved later")
  local told = false
  for _, payload in ipairs(sent) do
    if payload.t == "res" then
      for _, event in ipairs(payload.events or {}) do
        if event.kind == "send" and event.slot == 3 then told = true end
      end
    end
  end
  check(told, "and the other three are told, in a numbered turn like any other")

  -- The same message shape for a slot that is *not* awaiting is an ordinary
  -- action and must still be queued -- the fix is a fork, not a redirect.
  sent = {}
  inbox[#inbox + 1] = { t = "act", from = "dee",
                        action = { slot = 4, move = 1, target = 1 } }
  CoopBattle.drainNet(hostClient)
  check(hostClient.pending[4] ~= nil or host.over ~= nil,
        "an ordinary action from the same wire is still filed as a turn action")

  -- And a slot cannot be answered for by somebody who does not own it.
  host:resolveTurn({ { slot = 1, move = 1, target = 4 } })
  local before = host:signature()
  inbox[#inbox + 1] = { t = "act", from = "ann",
                        action = { slot = 3, index = 1 } }
  CoopBattle.drainNet(hostClient)
  eq(host:signature(), before,
     "and nobody can send out somebody else's monster")
end)()

-- ------- a turn that never arrived, and one that arrived wrong
--
-- Two different failures behind one recovery, and both are silent by design:
-- the battle repairs itself rather than stopping, so without these counters
-- nothing anywhere would ever say a client had been shown numbers that were
-- never true.
--
--   * a **gap** is a message that never came -- the sequence skips;
--   * a **desync** is one where every message arrived and the two copies still
--     disagree -- the sequence is right and the signature is not.
--
-- Driven through the real `applyTurn`, because the ordering inside it is the
-- substance: the events are played *before* the signature is compared, so a
-- comparison made against the pre-turn field would report a desync on every
-- healthy turn.
;(function()
  local sim = fieldSim(describe(FOUR))
  local asked = {}
  local client = setmetatable({
    sim = sim, host = false, mine = 1, messages = {}, seq = 0,
    game = { data = data, save = { inventory = {}, party = {} } },
    net = { send = function(payload) asked[#asked + 1] = payload end },
  }, { __index = CoopBattle })

  -- A healthy turn: right sequence, right signature, nothing reported.
  local host = fieldSim(describe(FOUR))
  local events = host:resolveTurn({ { slot = 1, move = 1, target = 3 } })
  CoopBattle.applyTurn(client, { seq = 1, sig = host:signature(), events = events })
  eq(client.gaps, nil, "a turn that arrives in order reports no gap")
  eq(client.desyncs, nil, "and one that leaves the copies agreeing reports no drift")
  eq(#asked, 0, "so nothing is asked of the host")
  eq(client.seq, 1, "and the sequence moves on")

  -- A gap: turn 2 never arrived and turn 3 is here.
  local skipped = host:resolveTurn({ { slot = 1, move = 1, target = 3 } })
  CoopBattle.applyTurn(client, { seq = 3, sig = host:signature(), events = skipped })
  eq(client.gaps, 1, "a sequence that skips is counted as a missed turn")
  eq(client.seq, 3, "the client takes the host's number rather than its own")
  eq(#asked, 1, "and asks for the field")
  eq(asked[1] and asked[1].t, "resync", "which is what a resync request is")

  -- A desync: the sequence is right, every message arrived, and the two copies
  -- still disagree. The events are applied first either way -- a client that
  -- refused a turn it could not verify would fall further behind with every
  -- one it refused.
  asked = {}
  client.seq = 3
  local more = host:resolveTurn({ { slot = 1, move = 1, target = 3 } })
  CoopBattle.applyTurn(client, { seq = 4, sig = "1:1:1:0|2:1:1:0|3:1:1:0|4:1:1:0",
                                 events = more })
  eq(client.desyncs, 1, "a signature that disagrees is counted as drift")
  eq(#asked, 1, "and also asks for the field")
  eq(asked[1] and asked[1].t, "resync", "by the same means")

  -- A turn carrying no signature at all -- an older host -- is applied and not
  -- second-guessed. Nothing is worse than a client that treats "cannot check"
  -- as "wrong" and re-syncs on every turn forever.
  asked = {}
  local before = client.desyncs
  local plain = host:resolveTurn({ { slot = 1, move = 1, target = 3 } })
  CoopBattle.applyTurn(client, { seq = 5, events = plain })
  eq(client.desyncs, before, "a turn with no signature reports no drift")
  eq(#asked, 0, "and asks for nothing")

  -- The counters are what the export reports, which is the only way an
  -- end-to-end run can ever see any of this.
  eq(client.gaps, 1, "the gap count is what a run reads back")
  eq(client.desyncs, 1, "and so is the drift count")
end)()

-- ------- putting one client right must not put the others wrong
--
-- The repair path, which is part of this contract rather than an aside: when a
-- replayer notices it has drifted it asks for the field, and the host answers
-- with a snapshot. Every message on this wire is fanned out to all four, so an
-- unaddressed answer was applied by all three replayers -- and the two who
-- were perfectly in step had their sequence set back to the host's, which the
-- next turn read as a gap, which made them ask too. One client a single
-- message behind became a resync storm that never converged.
;(function()
  local sim = fieldSim(describe(FOUR))
  local client = setmetatable({
    sim = sim, host = false, mine = 2, messages = {},
    game = { data = data, save = { inventory = {}, party = {} } },
  }, { __index = CoopBattle })

  eq(sim:slot(2).owner, "bob", "this client is sitting in BOB's slot")
  check(CoopBattle.addressedToMe(client, { to = "bob" }),
        "a snapshot addressed to this client is for this client")
  check(not CoopBattle.addressedToMe(client, { to = "cal" }),
        "and one addressed to somebody else is not -- which is what stops a "
        .. "client that was never behind having its sequence rewound")
  check(CoopBattle.addressedToMe(client, {}),
        "an answer with no address is still taken: a snapshot is the host's "
        .. "own field and is always safe to apply")

  -- ...and the host addresses it. Driven through drainNet so the assertion is
  -- about what the host actually puts on the wire.
  local hostSim = fieldSim(describe(FOUR))
  local inbox, sent = { { t = "resync", from = "cal" } }, {}
  local hostClient = setmetatable({
    sim = hostSim, host = true, mine = 1, messages = {}, pending = {}, seq = 7,
    game = { data = data, save = { inventory = {}, party = {} } },
    net = {
      poll = function() local out = inbox; inbox = {}; return out end,
      send = function(payload) sent[#sent + 1] = payload end,
    },
  }, { __index = CoopBattle })
  CoopBattle.drainNet(hostClient)
  local answer
  for _, payload in ipairs(sent) do
    if payload.t == "state" then answer = payload end
  end
  check(answer ~= nil, "the host answers a request for the field")
  eq(answer and answer.to, "cal", "addressed to whoever asked, and nobody else")
  eq(answer and answer.seq, 7, "carrying the turn the field is at")
end)()

-- ------- display sequencing: sim truth and the screen are two different clocks
--
-- Everything above this line is about *what happened* -- the replay contract,
-- turn for turn. This is about *when it is shown*: `mon.hp` lands the instant
-- a `damage` event is applied, on every client, but `battler.shownHP` -- the
-- number the bar is actually drawn from -- and the fainted flag that decides
-- whether a monster is even still drawn only move once the messages queue
-- reaches the row that was queued for them. That gap is deliberate (it is the
-- animation), and it is also exactly where a display bug hides: nothing about
-- the replay contract above would notice a bar that teleported, a monster
-- that vanished a frame early, or a same-turn NPC replacement that ate its
-- predecessor's exit. These blocks drive real frames through the real
-- `CoopBattle:update` -- never a hand simulation of what it "should" do -- and
-- pin the four rules the header above `M.startDrain` and `M.playEvents`
-- claims: the drain rate, the faint sink, the display shadow, and the fact
-- that none of it can be hurried past with a button.

;(function()
  -- 1. Truth and display are two clocks.
  --
  -- A `damage` event moves `mon.hp` the moment `playEvents` applies it -- has
  -- to, since a replayer's signature is compared against the host's from that
  -- instant. The *bar* is a queued row like any other text line, so it only
  -- starts falling once the messages phase reaches it, it falls at the
  -- engine's own maxHP/96 a frame, and the rest of the queue -- the very next
  -- line of text -- is held hostage until it lands exactly on the target.
  local sim = fieldSim({
    { side = "a", owner = "ann", name = "ANN", party = { mon(96, 50, { tackle() }) } },
    { side = "a", owner = "bob", name = "BOB", party = { mon(96, 40, { tackle() }) } },
    { side = "b", owner = "cal", name = "CAL", party = { mon(96, 30, { tackle() }) } },
    { side = "b", owner = "dee", name = "DEE", party = { mon(96, 20, { tackle() }) } },
  })
  local client = replayer(sim, 1)
  client.phase, client.frame = "messages", 0
  client.game.input = { wasPressed = function() return false end }

  local battler = sim:slot(1).battler
  local preHP = battler.mon.hp

  CoopBattle.playEvents(client, {
    { kind = "damage", slot = 1, hp = preHP - 20 },
    { kind = "msg", text = "next line" },
  })
  eq(battler.mon.hp, preHP - 20, "sim truth moves the instant the event lands")
  eq(battler.shownHP, preHP,
     "and the display has not moved at all -- it is still queued behind the "
     .. "drain row playEvents built for it")

  CoopBattle.update(client, 1 / 60)
  check(client.draining ~= nil,
        "one frame reaches the queued drain row and starts it")
  eq(battler.shownHP, preHP, "starting the drain does not itself move the bar")
  eq(#client.messages, 1, "and the text queued behind it is still waiting")

  local steps = 0
  while client.draining and steps < 200 do
    local before = battler.shownHP
    CoopBattle.update(client, 1 / 60)
    steps = steps + 1
    if client.draining then
      eq(before - battler.shownHP, math.max(1, battler.mon.stats.hp) / 96,
         "every frame the bar falls by maxHP/96, the engine's own rate")
    end
    eq(client.shown, nil,
       "and the queue stays blocked -- no text shows while the bar still owes "
       .. "its fall")
  end
  eq(steps, 20, "a 96 HP bar losing 20 takes exactly maxHP/96 steps to land")
  eq(battler.shownHP, preHP - 20, "and it lands exactly on the target, not past it")

  CoopBattle.update(client, 1 / 60)
  eq(client.shown, "next line",
     "only once the bar has finished does the line behind it show")
end)()

;(function()
  -- 2. Rounding at draw.
  --
  -- `displayHP` -- the file's own draw-time helper -- is not exported, on
  -- purpose: drawing is not this suite's job to touch, and exporting a
  -- function just to make it reachable would change the file for the test.
  -- It is reached instead through its real upvalue chain off `M.drawPanel`,
  -- which is exported, so this pins the exact closure the screen draws with
  -- rather than a rewritten copy of what it is supposed to do. The rule it
  -- pins: a fractional bar rounds up while it is still falling, so the number
  -- on screen never claims to be lower than the bar has visibly reached, and
  -- rounds down while healing, for the same reason run the other way.
  local function findDisplayHP()
    local i = 1
    while true do
      local name, value = debug.getupvalue(CoopBattle.drawPanel, i)
      if not name then return nil end
      if name == "drawReadout" then
        local j = 1
        while true do
          local innerName, innerValue = debug.getupvalue(value, j)
          if not innerName then return nil end
          if innerName == "displayHP" then return innerValue end
          j = j + 1
        end
      end
      i = i + 1
    end
  end
  local displayHP = findDisplayHP()
  check(type(displayHP) == "function",
        "the draw-time HP helper is reachable off drawPanel's own upvalues")

  eq(displayHP({ shownHP = 10.7, mon = { hp = 5 } }), 11,
     "draining down, a fractional bar rounds up -- it never undercounts what "
     .. "has not visibly fallen yet")
  eq(displayHP({ shownHP = 4.3, mon = { hp = 10 } }), 4,
     "and healing up, it rounds down for the same reason run the other way")
  eq(displayHP({ shownHP = 7, mon = { hp = 7 } }), 7,
     "a bar that has already arrived reads exactly where it landed")
  eq(displayHP({ shownHP = nil, mon = { hp = 42 } }), 42,
     "and a battler this screen never animated reads the true HP rather than "
     .. "inventing a descent from nowhere")
end)()

;(function()
  -- 3. Not skippable.
  --
  -- The engine reads a button only for a text page that has finished
  -- printing; `M:stepDrain` and `M:stepFaint` never consult input at all.
  -- Pinned by mashing A and B through both and counting frames against a run
  -- that never presses anything -- if either state ever started listening for
  -- a button, this is the only place that would notice the descent got
  -- shorter.
  local function buildSlots()
    return {
      { side = "a", owner = "ann", name = "ANN", party = { mon(96, 50, { tackle() }) } },
      { side = "a", owner = "bob", name = "BOB", party = { mon(96, 40, { tackle() }) } },
      { side = "b", owner = "cal", name = "CAL", party = { mon(96, 30, { tackle() }) } },
      { side = "b", owner = "dee", name = "DEE", party = { mon(96, 20, { tackle() }) } },
    }
  end

  local function drainRun(pressed)
    local sim = fieldSim(buildSlots())
    local client = replayer(sim, 1)
    client.phase, client.frame = "messages", 0
    client.game.input = { wasPressed = function() return pressed end }
    local battler = sim:slot(1).battler
    CoopBattle.playEvents(client,
      { { kind = "damage", slot = 1, hp = battler.mon.hp - 20 } })
    local calls = 0
    for i = 1, 200 do
      CoopBattle.update(client, 1 / 60)
      calls = i
      if not client.draining then break end
    end
    return calls, battler.shownHP
  end

  local quietCalls, quietHP = drainRun(false)
  local mashedCalls, mashedHP = drainRun(true)
  eq(mashedCalls, quietCalls,
     "mashing A and B through a drain does not shorten it by one frame")
  eq(mashedHP, quietHP, "and it lands on exactly the same number either way")

  local function faintRun(pressed)
    local sim = fieldSim(buildSlots())
    local client = replayer(sim, 1)
    client.phase, client.frame = "messages", 0
    client.game.input = { wasPressed = function() return pressed end }
    local battler = sim:slot(1).battler
    client.messages = { { faintfx = battler, slot = 1 } }
    CoopBattle.update(client, 1 / 60) -- pops the row, starts the sink
    local calls = 0
    for i = 1, 60 do
      CoopBattle.update(client, 1 / 60)
      calls = i
      if not client.faintFx then break end
    end
    return calls
  end

  eq(faintRun(true), faintRun(false),
     "and mashing through the 30-frame faint sink does not shorten it either")
end)()

;(function()
  -- 4. Faint order and the sink.
  --
  -- `CoopSim.announceFaint` queues the `faint` event before the "fainted!"
  -- text -- the original's own order, sprite sliding first and the words
  -- printed over it. The display's `fainted` flag is not allowed to follow
  -- the *event* that early, though: it goes up only when the faint row is
  -- actually reached and the sink starts, or a client reading messages a
  -- moment slower than the host watches a monster vanish before anything on
  -- screen explained why.
  local build = {
    { side = "a", owner = "ann", name = "ANN", party = { mon(400, 50, { tackle() }) } },
    { side = "a", owner = "bob", name = "BOB", party = { mon(400, 40, { tackle() }) } },
    { side = "b", owner = "cal", name = "CAL", party = { mon(1, 30, { tackle() }) } },
    { side = "b", owner = "dee", name = "DEE", party = { mon(400, 20, { tackle() }) } },
  }
  local host = fieldSim(describe(build))
  local events = host:resolveTurn({ { slot = 1, move = 1, target = 3 } })

  local faintIdx, faintMsgIdx
  for i, event in ipairs(events) do
    if event.kind == "faint" and not faintIdx then faintIdx = i end
    if event.kind == "msg" and not faintMsgIdx
       and tostring(event.text):find("fainted!", 1, true) then
      faintMsgIdx = i
    end
  end
  check(faintIdx ~= nil and faintMsgIdx ~= nil and faintIdx < faintMsgIdx,
        "the sim's own event list puts the faint before the fainted! text")

  local guest = fieldSim(describe(build))
  local client = replayer(guest, 1)
  client.phase, client.frame = "messages", 0
  client.game.input = { wasPressed = function() return false end }

  CoopBattle.playEvents(client, events)
  eq(guest:slot(3).battler.fainted, nil,
     "receiving the turn does not itself mark the battler fainted -- that is "
     .. "the display's flag, and the display has not reached the row yet")

  local sinkStart, sinkEnd, textFrame
  local wasSinking = false
  for i = 1, 1000 do
    CoopBattle.update(client, 1 / 60)
    local isSinking = client.faintFx ~= nil
    if isSinking and not sinkStart then
      sinkStart = i
      eq(guest:slot(3).battler.fainted, true,
         "and it is set the instant the faint row starts the sink, not before")
    end
    if wasSinking and not isSinking and not sinkEnd then sinkEnd = i - 1 end
    wasSinking = isSinking
    if not textFrame and type(client.shown) == "string"
       and client.shown:find("fainted!", 1, true) then
      textFrame = i
    end
    if textFrame then break end
  end
  check(sinkStart ~= nil and sinkEnd ~= nil, "the sink actually ran")
  eq(sinkEnd - sinkStart + 1, 30,
     "and blocked the queue for exactly the engine's 30 frames")
  check(textFrame ~= nil and textFrame > sinkEnd,
        "the fainted! text is shown only once the sink has fully played")
end)()

;(function()
  -- 5. Engine-placed drains.
  --
  -- `CoopField.drain` turns the engine's own queued rows into events, and a
  -- `drain` row's position is the engine's, not this mod's: one per hit,
  -- after the flash, before the effectiveness or critical line, carrying the
  -- HP the bar is allowed to stop at. The later `damage` event -- the one
  -- that actually moves `mon.hp` -- is the catch-all, and it has to agree
  -- with what the drain already promised.
  local sim = fieldSim(describe(FOUR))
  local events = sim:resolveTurn({ { slot = 1, move = 1, target = 3 } })

  local drainIdx, textIdx, damageIdx, drainTo, damageHp
  for i, event in ipairs(events) do
    if event.kind == "drain" and not drainIdx then
      drainIdx, drainTo = i, event.to
    end
    if event.kind == "msg" and drainIdx and not textIdx
       and (tostring(event.text):find("Critical", 1, true)
            or tostring(event.text):find("effective", 1, true)) then
      textIdx = i
    end
    if event.kind == "damage" and not damageIdx then
      damageIdx, damageHp = i, event.hp
    end
  end
  check(drainIdx ~= nil, "a damaging turn carries at least one drain row")
  check(textIdx ~= nil and drainIdx < textIdx,
        "placed before the hit's own effectiveness/critical text")
  check(damageIdx ~= nil and drainIdx < damageIdx,
        "and before the damage event that actually moves the HP")
  eq(drainTo, damageHp,
     "the drain's stop and the damage event's final HP are the same number")
end)()

;(function()
  -- 6. Same-turn NPC replacement keeps its exit.
  --
  -- An NPC slot has nobody to pause for, so `CoopSim` sends its next monster
  -- out inside the very turn that felled the last one -- sim truth moves on
  -- immediately, mid-`resolveTurn`. The display cannot: the fallen monster is
  -- still owed its drain and its 30-frame sink. `M:holdDisplay` is what makes
  -- that possible, catching the outgoing battler in a shadow *before*
  -- `resolveTurn` moves the slot on -- called here the way `tryResolve` calls
  -- it, in the same order. This is the bug the file's own header names
  -- (`dropDisplayFor`, which purged the dying monster's rows instead of
  -- playing them): without the shadow the replacement simply appears, with no
  -- fall in between.
  local build = {
    { side = "a", owner = "ann", name = "ANN", party = { mon(400, 50, { tackle() }) } },
    { side = "a", owner = "bob", name = "BOB", party = { mon(400, 40, { tackle() }) } },
    { side = "b", owner = nil, name = "FOE",
      party = { mon(1, 30, { tackle() }), mon(300, 25, { tackle() }) } },
    { side = "b", owner = nil, name = "FOE2", party = { mon(300, 20, { tackle() }) } },
  }
  local sim = fieldSim(build)
  local host = replayer(sim, 1)
  host.host = true
  host.phase, host.frame = "messages", 0
  host.game.input = { wasPressed = function() return true end }

  local oldBattler = sim:slot(3).battler
  -- The pieces `tryResolve` runs, in the order it runs them.
  CoopBattle.holdDisplay(host)
  local events = sim:resolveTurn({ { slot = 1, move = 1, target = 3 } })
  check(sim:slot(3).battler ~= oldBattler,
        "sim truth already stands the replacement in the slot the instant "
        .. "resolveTurn returns")
  eq(sim:slot(3).battler.mon.hp, 300,
     "-- the reserve, untouched this turn, not the one that just fell")
  CoopBattle.playEvents(host, events)

  eq(CoopBattle.shownBattlerAt(host, 3), oldBattler,
     "but the display still shows the one that fell, until its rows play")

  local sawFaintingOld = false
  for i = 1, 400 do
    CoopBattle.update(host, 1 / 60)
    if host.faintFx and host.faintFx.battler == oldBattler then
      sawFaintingOld = true
    end
    if host.phase ~= "messages" then break end
  end
  check(sawFaintingOld, "the sink that plays is the departed monster's own")
  eq(host.phase, "choose", "the queue drains all the way back to a menu")
  eq(CoopBattle.shownBattlerAt(host, 3), sim:slot(3).battler,
     "and once it has, the shadow lets go -- the display shows the replacement")
  local newBattler = sim:slot(3).battler
  eq(newBattler.shownHP, newBattler.mon.hp,
     "with the bar already sitting on the replacement's own HP -- snapDisplay, "
     .. "run automatically on the way back to the menu, closed the gap")
end)()

;(function()
  -- 7. Text stays up through effects.
  --
  -- A queued effect row (anim, drain, faint) is taken off the head of the
  -- queue *ahead of* the ordinary text-dwell check, which is what lets the
  -- last line stay on screen while the flash or the fall plays under it: the
  -- box would otherwise go blank for the whole of every hit, naming a move
  -- nothing on screen still credits. The dwell clock is not ticked while an
  -- effect runs, either -- so a line shown a moment before a long drain does
  -- not silently expire mid-effect and lose the words to the thing they were
  -- describing.
  local sim = fieldSim({
    { side = "a", owner = "ann", name = "ANN", party = { mon(96, 50, { tackle() }) } },
    { side = "a", owner = "bob", name = "BOB", party = { mon(96, 40, { tackle() }) } },
    { side = "b", owner = "cal", name = "CAL", party = { mon(96, 30, { tackle() }) } },
    { side = "b", owner = "dee", name = "DEE", party = { mon(96, 20, { tackle() }) } },
  })
  local client = replayer(sim, 1)
  client.phase, client.frame = "messages", 0
  client.game.input = { wasPressed = function() return false end }

  client.messages = { { text = "Line A" } }
  CoopBattle.update(client, 1 / 60)
  eq(client.shown, "Line A", "the line shows on the frame it is reached")
  local frozenClock = client.msgClock

  local battler = sim:slot(1).battler
  client.messages[#client.messages + 1] =
    { drain = battler, slot = 1, to = battler.mon.hp - 20 }
  CoopBattle.update(client, 1 / 60) -- pops the drain row, starts it
  eq(client.shown, "Line A",
     "an effect reaching the head of the queue does not clear the line above it")
  check(client.draining ~= nil, "and the drain really did start")

  for _ = 1, 30 do
    if not client.draining then break end
    CoopBattle.update(client, 1 / 60)
  end
  check(client.draining == nil, "the drain ran to completion")
  eq(client.shown, "Line A", "the same line is still up once it has")
  eq(client.msgClock, frozenClock,
     "and its dwell clock never advanced while the effect was running")
end)()

;(function()
  -- 8. Unknown kinds are ignored, both directions.
  --
  -- The event vocabulary is meant to grow, and a client running an older
  -- build must not choke on a kind it has never heard of, nor queue anything
  -- from it that could wedge the messages phase for whatever comes after.
  -- `playEvents` has no branch for a kind it does not recognise, so it is
  -- simply dropped.
  local sim = fieldSim({
    { side = "a", owner = "ann", name = "ANN", party = { mon(96, 50, { tackle() }) } },
    { side = "a", owner = "bob", name = "BOB", party = { mon(96, 40, { tackle() }) } },
    { side = "b", owner = "cal", name = "CAL", party = { mon(96, 30, { tackle() }) } },
    { side = "b", owner = "dee", name = "DEE", party = { mon(96, 20, { tackle() }) } },
  })
  local client = replayer(sim, 1)
  client.phase, client.frame = "messages", 0
  client.game.input = { wasPressed = function() return false end }

  local ok = pcall(CoopBattle.playEvents, client,
    { { kind = "sparkle", slot = 1, glitter = true } })
  check(ok, "a kind this build has never heard of does not throw")
  eq(#client.messages, 0, "and queues nothing that could wedge the messages phase")

  -- A real event still either side of it works normally, so the drop is
  -- silent rather than derailing the rest of the batch.
  CoopBattle.playEvents(client,
    { { kind = "sparkle" }, { kind = "msg", text = "still here" },
      { kind = "sparkle" } })
  eq(#client.messages, 1, "a real event survives sitting next to unknown ones")
  CoopBattle.update(client, 1 / 60)
  eq(client.shown, "still here", "and plays normally")
end)()

;(function()
  -- 9. Snap points.
  --
  -- The moments a half-played animation would be a lie rather than a lag: the
  -- host's numbers have just changed underneath the display -- mid-drain, in
  -- this case -- and nothing about the running `shownHP` still means
  -- anything. Driven through the real `state` branch of `drainNet`, because
  -- that is what a resync actually runs: `sim:restore` followed by
  -- `snapDisplay`, the same pair `M:drainNet`'s `state` handler calls.
  local build = {
    { side = "a", owner = "ann", name = "ANN", party = { mon(96, 50, { tackle() }) } },
    { side = "a", owner = "bob", name = "BOB", party = { mon(96, 40, { tackle() }) } },
    { side = "b", owner = "cal", name = "CAL", party = { mon(96, 30, { tackle() }) } },
    { side = "b", owner = "dee", name = "DEE", party = { mon(96, 20, { tackle() }) } },
  }
  local hostSim = fieldSim(describe(build))
  local guestSim = fieldSim(describe(build))
  local guest = replayer(guestSim, 1)
  guest.phase, guest.frame = "messages", 0
  guest.game.input = { wasPressed = function() return false end }
  local inbox = {}
  guest.net = { poll = function() local out = inbox; inbox = {}; return out end,
                send = function() end }

  hostSim:resolveTurn({ { slot = 1, move = 1, target = 3 } })

  -- The guest is mid-drain on a number the host never sent -- standing in for
  -- the ordinary trigger, a lost message, without reproducing the exact turn.
  CoopBattle.playEvents(guest,
    { { kind = "damage", slot = 1, hp = guestSim:slot(1).battler.mon.hp - 10 } })
  CoopBattle.update(guest, 1 / 60)
  check(guest.draining ~= nil, "the guest is mid-drain when the resync lands")
  check(guestSim:slot(1).battler.shownHP ~= guestSim:slot(1).battler.mon.hp,
        "-- display and truth genuinely disagree at this instant")

  inbox[#inbox + 1] = { t = "state", seq = 9, slots = hostSim:snapshot() }
  CoopBattle.drainNet(guest)

  check(guest.draining == nil, "the resync clears a running drain outright")
  check(guest.faintFx == nil, "and any faint sink with it")
  check(next(guest.shownBattler or {}) == nil,
        "the display shadow is cleared -- nothing is owed an exit any more")
  for i, slot in ipairs(guestSim.slots) do
    if slot.battler then
      eq(slot.battler.shownHP, slot.battler.mon.hp,
         ("slot %d reads exactly where the host's numbers put it"):format(i))
    end
  end
  local sawSwapGhost = false
  for _, row in ipairs(guest.messages) do
    if type(row) == "table" and row.swap then sawSwapGhost = true end
  end
  check(not sawSwapGhost,
        "and no queued swap row survives to put a monster the field no longer "
        .. "holds back on screen seconds later")
end)()

-- ------- what a faint does to the four people watching it
--
-- The lifecycle, rule by rule, because "a 2-on-2 works" is four separate
-- claims and only one of them is about damage:
--
--   * a monster that falls with team-mates left **stops the battle** and its
--     owner is asked, at once, which one follows it;
--   * nobody else's turn resolves while that question is open;
--   * a monster that falls with nothing left does **not** stop anything -- its
--     trainer is simply out, and watches;
--   * a side is beaten only when **both** its trainers are;
--   * and a monster that has fainted never comes back onto the field.
;(function()
  -- ANN is huge and does the killing. CAL has a reserve; DEE does not.
  local build = {
    { side = "a", owner = "ann", name = "ANN",
      party = { { hp = 400, speed = 50, moves = { tackle() } } } },
    { side = "a", owner = "bob", name = "BOB",
      party = { { hp = 400, speed = 45, moves = { tackle() } } } },
    { side = "b", owner = "cal", name = "CAL",
      party = { { hp = 1, speed = 30, moves = { tackle() } },
                { hp = 400, speed = 25, moves = { tackle() } } } },
    { side = "b", owner = "dee", name = "DEE",
      party = { { hp = 1, speed = 20, moves = { tackle() } } } },
  }

  -- ------- with a reserve: the battle stops and the owner is asked
  local sim = fieldSim(describe(build))
  local events = sim:resolveTurn({ { slot = 1, move = 1, target = 3 } })
  local asked, fainted = nil, false
  for _, event in ipairs(events) do
    if event.kind == "choose" then asked = event end
    if event.kind == "faint" and event.slot == 3 then fainted = true end
  end
  check(fainted, "a monster that falls is announced as fainted")
  check(asked ~= nil and asked.slot == 3,
        "and its owner is asked which one follows, immediately")
  check(asked ~= nil and asked.trainer == "CAL",
        "the ask names whose choice it is")
  local waiting = sim:awaitingChoice()
  check(waiting ~= nil and waiting.index == 3, "the field is stopped on that slot")

  -- Nobody else moves in the meantime. This is the claim that makes the pause
  -- a pause rather than a prompt: a turn resolved around an empty slot would
  -- spend three people's moves on a field that is about to change.
  local hpBefore = sim:slot(1).battler.mon.hp
  local ignored = sim:resolveTurn({ { slot = 4, move = 1, target = 1 } })
  eq(sim:slot(1).battler.mon.hp, hpBefore,
     "no turn resolves while a replacement is outstanding")
  eq(#ignored, 0, "and nothing is announced to anyone")

  -- ...and answering it starts the battle again.
  check(sim:replace(3, 2, function() end), "the owner's answer is taken")
  eq(sim:awaitingChoice(), nil, "which releases the field")
  eq(sim:slot(3).active, 2, "with the monster they chose out")
  check((sim:slot(3).battler.mon.hp or 0) > 0, "and it is a live one")
  sim:resolveTurn({ { slot = 4, move = 1, target = 1 } })
  check((sim:slot(1).battler.mon.hp or 0) < hpBefore,
        "and turns resolve again afterwards")

  -- ------- a fainted monster never comes back
  --
  -- Asked for by index, the way a client asks. `replace` is the only door onto
  -- the field, so this is the whole of the guarantee -- and the index comes
  -- off the wire, where a stale or modified client can put anything.
  local revive = fieldSim(describe(build))
  revive:resolveTurn({ { slot = 1, move = 1, target = 3 } })
  check(revive:awaitingChoice() ~= nil, "CAL is asked again")
  check(revive:replace(3, 1, function() end),
        "a request naming the monster that just fainted is accepted...")
  eq(revive:slot(3).active, 2,
     "...but sends out a living one instead -- a fainted POKeMON is never "
     .. "put back on the field")
  check((revive:slot(3).battler.mon.hp or 0) > 0, "and it is standing")

  -- ------- with nothing left: no pause, no ask, and the side fights on
  -- Its own field, with CAL healthy: the build above leaves CAL on one hit
  -- point, and a CAL that faints in the middle of this would put the battle
  -- back into the *paused* state and prove nothing about the unpaused one.
  local out = fieldSim(describe({
    { side = "a", owner = "ann", name = "ANN",
      party = { { hp = 400, speed = 50, moves = { tackle() } } } },
    { side = "a", owner = "bob", name = "BOB",
      party = { { hp = 400, speed = 45, moves = { tackle() } } } },
    { side = "b", owner = "cal", name = "CAL",
      party = { { hp = 400, speed = 30, moves = { tackle() } } } },
    { side = "b", owner = "dee", name = "DEE",
      party = { { hp = 1, speed = 20, moves = { tackle() } } } },
  }))
  local downEvents = out:resolveTurn({ { slot = 1, move = 1, target = 4 } })
  local askedAnyone = false
  for _, event in ipairs(downEvents) do
    if event.kind == "choose" then askedAnyone = true end
  end
  check(not askedAnyone,
        "a trainer with nothing left is not asked to send anything out")
  eq(out:awaitingChoice(), nil, "and the battle is not stopped for them")
  check(out:isDown(out:slot(4)), "their slot is out of the fight")
  check(out.over == nil,
        "but the battle is not over -- a side falls only when both its "
        .. "trainers do")
  check(#out:targetsFor(out:slot(1)) == 1,
        "and they cannot be attacked any more -- one target left, not two")

  -- Their partner fights on, and the turn resolves without waiting for them.
  local before = out:slot(1).battler.mon.hp
  out:resolveTurn({ { slot = 1, move = 1, target = 3 },
                    { slot = 3, move = 1, target = 1 } })
  check((out:slot(1).battler.mon.hp or 0) < before,
        "the remaining trainer on that side still takes their turn")

  -- ...and only when the partner falls too is the side beaten.
  out:slot(3).battler.mon.hp = 1
  out:resolveTurn({ { slot = 1, move = 1, target = 3 } })
  eq(out.over, "a", "and when the last one falls, the other side wins")
end)()

-- ------- and the player who is out is a spectator, not a prompt
--
-- The rule above is the field's. This is the client's, and it was the one that
-- was missing: the host stops waiting on a slot that is down and files nothing
-- for it, but the player was still shown the command menu -- so they picked a
-- move, were dropped into a wait, and were asked again next turn, for the rest
-- of a battle they were no longer in.
;(function()
  local sim = fieldSim(describe({
    { side = "a", owner = "ann", name = "ANN",
      party = { { hp = 400, speed = 50, moves = { tackle() } } } },
    { side = "a", owner = "bob", name = "BOB",
      party = { { hp = 1, speed = 45, moves = { tackle() } },
                { hp = 400, speed = 40, moves = { tackle() } } } },
    { side = "b", owner = "cal", name = "CAL",
      party = { { hp = 400, speed = 30, moves = { tackle() } } } },
    { side = "b", owner = "dee", name = "DEE",
      party = { { hp = 400, speed = 20, moves = { tackle() } } } },
  }))
  local client = setmetatable({
    sim = sim, host = false, mine = 2, messages = {}, phase = "choose",
    game = { data = data, save = { inventory = {}, party = {} } },
  }, { __index = CoopBattle })

  check(not CoopBattle.spectating(client),
        "a player whose monster is standing is not a spectator")

  -- BOB's monster falls, and BOB has one left: this is the *replacing* state,
  -- which is a decision rather than a spectacle.
  sim:slot(2).battler.mon.hp = 0
  client.replacing = true
  check(not CoopBattle.spectating(client),
        "nor is one who has been asked to send out their next")

  -- ...and once BOB has nothing left, they are.
  client.replacing = false
  sim:slot(2).party[2].hp = 0
  check(CoopBattle.spectating(client),
        "a player with nothing left to send out is watching, not choosing")
  eq(sim:hasReserve(sim:slot(2)), nil, "which is what having no reserve means")

  -- The field agrees: their side is still alive, so the battle continues
  -- around them rather than ending.
  check(not sim:sideBeaten("a"),
        "their side fights on while their partner stands")

  -- And a forfeited slot is the same kind of out.
  local gone = fieldSim(describe(FOUR))
  local goneClient = setmetatable({
    sim = gone, host = false, mine = 1, messages = {}, phase = "choose",
    game = { data = data, save = { inventory = {}, party = {} } },
  }, { __index = CoopBattle })
  check(not CoopBattle.spectating(goneClient), "a connected player chooses")
  gone:forfeit("ann")
  check(CoopBattle.spectating(goneClient),
        "and a slot written off after a disconnect is out the same way")

  -- Once the battle is decided nobody is a spectator -- the result screen is
  -- for everyone, and a spectator gate that outlived the battle would swallow
  -- the button that closes it.
  goneClient.result = "loss"
  check(not CoopBattle.spectating(goneClient),
        "and once the battle is over, nobody is left watching it")
end)()

-- ------- all the way to a decision
--
-- Run until somebody wins rather than for a fixed count, so the last turn --
-- the one carrying the faints, the exp and the verdict, and the most crowded
-- turn a battle has -- is covered rather than stopped short of.
;(function()
  local build = {
    { side = "a", owner = "ann", name = "ANN",
      party = { { hp = 150, speed = 50, moves = { tackle() } } } },
    { side = "a", owner = "bob", name = "BOB",
      party = { { hp = 150, speed = 40, moves = { tackle() } } } },
    { side = "b", owner = "cal", name = "CAL",
      party = { { hp = 60, speed = 30, moves = { tackle() } } } },
    { side = "b", owner = "dee", name = "DEE",
      party = { { hp = 60, speed = 20, moves = { tackle() } } } },
  }
  local host = fieldSim(describe(build))
  local guest = fieldSim(describe(build))
  local client = replayer(guest, 1)

  local turns, matched = 0, true
  while not host.over and turns < 30 do
    CoopBattle.playEvents(client, host:resolveTurn(allAttack()))
    turns = turns + 1
    if guest:signature() ~= host:signature() then matched = false break end
  end
  check(host.over ~= nil, "the battle reaches a decision")
  check(matched, "and the replayer agrees with the host on every turn of it")
  eq(client.result, "win",
     "and the client is told the verdict from its own side's point of view")
end)()

-- ------- replay conformance holds with statuses in play
--
-- The status gate changes a resolved turn's own event stream -- more
-- messages, animations, and a turn a battler simply skips -- so the same
-- comparison the wire makes gets one scenario carrying sleep and paralysis
-- through several turns, checked against the host after every one.

;(function()
  local build = {
    { side = "a", owner = "ann", name = "ANN",
      party = { { hp = 200, speed = 50, moves = { tackle() } } } },
    { side = "a", owner = "bob", name = "BOB",
      party = { { hp = 200, speed = 45, moves = { tackle() } } } },
    { side = "b", owner = "cal", name = "CAL",
      party = { { hp = 200, speed = 30, moves = { tackle() } } } },
    { side = "b", owner = "dee", name = "DEE",
      party = { { hp = 200, speed = 20, moves = { tackle() } } } },
  }
  local host = fieldSim(describe(build))
  local guest = fieldSim(describe(build))
  local client = replayer(guest, 1)

  -- Only the host needs the status -- it is the only copy that ever
  -- simulates; the replayer's job is to agree on the HP the events carry,
  -- not to hold the same volatile state.
  host:slot(3).battler.mon.status = "SLP"
  host:slot(3).battler.sleepTurns = 2
  host:slot(4).battler.mon.status = "PAR"

  local function turn()
    return { { slot = 1, move = 1, target = 3 }, { slot = 2, move = 1, target = 4 } }
  end

  -- Turn one: CAL is asleep, DEE fully paralysed (the fixed rng's 0/256 roll
  -- always clears the 63/256 threshold).
  CoopBattle.playEvents(client, host:resolveTurn(turn()))
  eq(guest:signature(), host:signature(),
     "the replayer agrees while both statuses are gating a turn")

  -- Turn two: CAL wakes (losing the turn on the wake itself), DEE stays
  -- paralysed.
  CoopBattle.playEvents(client, host:resolveTurn(turn()))
  eq(guest:signature(), host:signature(),
     "and still agrees on the wake-up turn -- a message-only difference from "
     .. "an ordinary one, and no ordinary turn was ever the risk")

  -- Turn three: CAL is free and actually swings.
  CoopBattle.playEvents(client, host:resolveTurn(turn()))
  eq(guest:signature(), host:signature(),
     "and agrees again once the gate stops firing and the move actually lands")
end)()

end)()

-- ------- a replacement is not a turn
--
-- When a monster faints its slot is *awaiting*, and nothing resolves until it
-- has sent the next one out. A non-host files that choice down the same wire
-- as an ordinary action, and the host used to put it in the queue of pending
-- turn actions and then ask itself to resolve -- which it refuses to do while
-- anything is awaiting. The pause waited on itself: every non-host player
-- whose monster fainted froze the battle for all four until a stall timeout
-- picked for them a minute later. Four clients found it; two never could,
-- because with an NPC pair the only human who can faint is usually the host.

;(function()
  local pause = fieldSim({
    { side = "a", owner = "ann", name = "ANN",
      party = { mon(400, 50, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "a", owner = "bob", name = "BOB",
      party = { mon(400, 40, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "b", owner = "cal", name = "CAL",
      party = { mon(1, 5, { { id = "FIX_TACKLE", pp = 20 } }),
                mon(400, 30, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "b", owner = "dee", name = "DEE",
      party = { mon(400, 20, { { id = "FIX_TACKLE", pp = 20 } }) } },
  })

  pause:resolveTurn({ { slot = 1, move = 1, target = 3 } })
  local waiting = pause:awaitingChoice()
  check(waiting ~= nil and waiting.index == 3,
        "a fainted slot with a reserve stops the field and asks its owner")

  -- The state the wedge lived in: while a slot is awaiting, there is nothing
  -- to aim at on that side, so a player who opens FIGHT has an empty target
  -- list -- which is why CoopBattle refuses to open the picker at all.
  eq(#pause:targetsFor(pause:slot(1)), 1,
     "the other side still has one target while the fainted slot chooses")

  -- And the choice itself resolves the pause. `replace` is what the host runs
  -- for a replacement, whoever sent it -- the fix is that a non-host's arrives
  -- here rather than in the pending-actions queue.
  local sent = {}
  check(pause:replace(3, 2, function(event) sent[#sent + 1] = event end),
        "the owner's choice is accepted")
  eq(pause:awaitingChoice(), nil, "and the field stops waiting")
  eq(pause:slot(3).active, 2, "with the chosen monster out")
  local announced = false
  for _, event in ipairs(sent) do
    if event.kind == "send" and event.slot == 3 then announced = true end
  end
  check(announced, "and the other three are told which one it was")
end)()

-- ------- levelling up offers the move the species learns
--
-- The trap this pins: the host resolves every slot, so a move written onto the
-- host's *copy* of somebody else's monster is thrown away with the copy --
-- the same shape of bug that made items free for everyone but the host. The
-- level-up therefore *announces* the move and each client applies it to its
-- own live party.

;(function()
  local species = "FIXMON_A"
  local def = data.pokemon[species]
  -- The learn is driven off the species' own learnset, so the test needs one
  -- to exist; if the fixture has none there is nothing to assert.
  local Experience = require("src.battle.Experience")
  local learnLevel, learnMove
  for level = 2, 60 do
    local ok, moves = pcall(Experience.movesLearnedAt, def, level)
    if ok and moves and moves[1] then learnLevel, learnMove = level, moves[1] break end
  end

  if not learnLevel then
    check(true, "(the fixture species has no level-up learnset to check)")
    return
  end

  local learnSim = fieldSim({
    { side = "a", owner = "ann", name = "ANN",
      party = { mon(60, 50, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "a", owner = "bob", name = "BOB",
      party = { mon(60, 40, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "b", owner = nil, name = "FOE",
      party = { mon(1, 30, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "b", owner = nil, name = "FOE",
      party = { mon(60, 20, { { id = "FIX_TACKLE", pp = 20 } }) } },
  })
  -- one level short of the one that teaches something, with almost enough exp
  local learner = learnSim:slot(1).battler.mon
  learner.level = learnLevel - 1
  learner.exp = 0
  learner.statExp = {}

  local out = learnSim:resolveTurn({ { slot = 1, move = 1, target = 3 } })
  local learned, grew = nil, false
  for _, event in ipairs(out) do
    if event.kind == "learn" then learned = event end
    if event.kind == "msg" and tostring(event.text):find("grew to") then grew = true end
  end

  if not grew then
    check(true, "(the fixture payout was not enough to level; nothing to learn)")
    return
  end
  check(learned ~= nil, "reaching the level announces the move as an event")
  eq(learned.slot, 1, "naming the slot it belongs to, so only its owner applies it")
  check(learned.move ~= nil, "and which move it is")
end)()

-- ------- an NPC picks through the engine's own trainer AI
--
-- The heuristic this replaced was strongest-move/weakest-target, which is not
-- what a Gen 1 trainer does: the real AI discourages a move the defender
-- resists, encourages status on a healthy target, and -- per trainer class --
-- spends items and switches instead of attacking. Those layers are the
-- engine's and are now driven rather than approximated.

;(function()
  local aiSim = fieldSim({
    { side = "a", owner = "ann", name = "ANN",
      party = { mon(60, 50, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "a", owner = "bob", name = "BOB",
      party = { mon(8, 40, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "b", owner = nil, name = "FOE",
      party = { mon(60, 30, { { id = "FIX_TACKLE", pp = 20 },
                              { id = "FIX_SCRATCH", pp = 20 } }) } },
    { side = "b", owner = nil, name = "FOE",
      party = { mon(60, 20, { { id = "FIX_TACKLE", pp = 20 } }) } },
  })

  local action = aiSim:npcAction(aiSim:slot(3))
  check(action ~= nil, "an unowned slot still chooses an action")
  eq(action.slot, 3, "for itself")
  -- Targeting stays this file's job: Gen 1 has no notion of two opponents, so
  -- nothing in the engine can answer "which of these two".
  eq(action.target, 2, "aiming at the opponent closest to falling")
  check(action.move ~= nil, "with a move chosen")
  check(action.move >= 1 and action.move <= 2,
        "and the move is an index into what it actually knows")

  -- With every move spent the AI reaches Struggle rather than nothing, which
  -- is the fallback path the old heuristic had no answer for at all.
  for _, moveInst in ipairs(aiSim:slot(3).battler.curMoves) do moveInst.pp = 0 end
  local spent = aiSim:npcAction(aiSim:slot(3))
  check(spent ~= nil, "a monster with nothing left still takes its turn")
  eq(aiSim:hasPP(aiSim:slot(3).battler), false, "having genuinely nothing left")
end)()

-- ------- out of PP means Struggle, not a lost turn

sim = fieldSim({
  { side = "a", owner = "ann", name = "ANN",
    party = { mon(60, 50, { { id = "FIX_TACKLE", pp = 0 } }) } },
  { side = "a", owner = "bob", name = "BOB",
    party = { mon(60, 40, { { id = "FIX_TACKLE", pp = 20 } }) } },
  { side = "b", owner = nil, name = "FOE",
    party = { mon(200, 30, { { id = "FIX_TACKLE", pp = 20 } }) } },
  { side = "b", owner = nil, name = "FOE",
    party = { mon(200, 20, { { id = "FIX_TACKLE", pp = 20 } }) } },
})
eq(sim:hasPP(sim:slot(1).battler), false, "a monster with no PP has none left")
eq(sim:hasPP(sim:slot(2).battler), true, "and one with PP does")

local emptyFoe = sim:slot(3).battler.mon.hp
events = sim:resolveTurn({ { slot = 1, move = 1, target = 3 } })
check(sim:slot(3).battler.mon.hp < emptyFoe,
      "a monster with nothing left still attacks -- it Struggles")
local saidStruggle = false
for _, event in ipairs(events) do
  if event.kind == "msg" and tostring(event.text):find("STRUGGLE") then
    saidStruggle = true
  end
end
check(saidStruggle, "and the battle says so by name")

-- ...and it costs the attacker, which is the whole of what makes Struggle
-- Struggle rather than a weak Normal move. It runs through the engine's own
-- STRUGGLE record and its RECOIL_EFFECT, so the recoil is the engine's -- not
-- an approximation of it written here.
local struggler = sim:slot(1).battler.mon
check((struggler.hp or 0) < (struggler.stats.hp or 0),
      "Struggle hurts the POKeMON using it -- the recoil is the engine's own")

-- ------- and the choice of who follows is the player's
--
-- The picker itself, driven through the real `updateReplace`: what it offers,
-- what it refuses, and what it puts on the wire. It is the one menu in this
-- battle that **cannot be cancelled** -- the slot is empty and there is no
-- turn to go back to -- so B doing nothing is a feature and worth pinning.
;(function()
  local CoopBattle = need("CoopBattle")
  local picker = fieldSim({
    { side = "a", owner = "ann", name = "ANN",
      party = { mon(60, 50, { { id = "FIX_TACKLE", pp = 20 } }),
                mon(60, 45, { { id = "FIX_TACKLE", pp = 20 } }),
                mon(60, 40, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "a", owner = "bob", name = "BOB",
      party = { mon(60, 40, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "b", owner = "cal", name = "CAL",
      party = { mon(60, 30, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "b", owner = "dee", name = "DEE",
      party = { mon(60, 20, { { id = "FIX_TACKLE", pp = 20 } }) } },
  })
  local sent = {}
  local client = setmetatable({
    sim = picker, host = false, mine = 1, messages = {}, replacing = true,
    game = { data = data, save = { inventory = {}, party = {} } },
    sendAction = function(_, action) sent[#sent + 1] = action end,
  }, { __index = CoopBattle })
  local function press(key)
    return { wasPressed = function(_, which) return which == key end }
  end

  -- The active one has fallen, and the third is dead: the bench is what is
  -- left, and only what is left.
  picker:slot(1).battler.mon.hp = 0
  picker:slot(1).party[3].hp = 0
  local bench = CoopBattle.benchOf(client, picker:slot(1))
  eq(#bench, 1, "the bench offers the living reserves and nothing else")
  eq(bench[1].index, 2, "by their place in the party")

  -- B is not a way out.
  CoopBattle.updateReplace(client, press("b"))
  eq(client.replacing, true, "B does not cancel a replacement -- there is no "
     .. "turn to go back to")
  eq(#sent, 0, "and files nothing")

  -- A takes what the cursor is on, files it, and closes the picker.
  CoopBattle.updateReplace(client, press("a"))
  eq(client.replacing, nil, "A answers it")
  eq(#sent, 1, "and puts exactly one choice on the wire")
  eq(sent[1].slot, 1, "for this player's own slot")
  eq(sent[1].index, 2, "naming the monster they picked")

  -- With two on the bench the cursor moves, and wraps.
  picker:slot(1).party[3].hp = 60
  client.replacing, client.switchIndex, sent = true, 1, {}
  eq(#CoopBattle.benchOf(client, picker:slot(1)), 2, "two reserves, two rows")
  CoopBattle.updateReplace(client, press("down"))
  eq(client.switchIndex, 2, "down moves the cursor")
  CoopBattle.updateReplace(client, press("down"))
  eq(client.switchIndex, 1, "and wraps at the end of a short list")
  CoopBattle.updateReplace(client, press("up"))
  eq(client.switchIndex, 2, "as does up, the other way")
  CoopBattle.updateReplace(client, press("a"))
  eq(sent[1] and sent[1].index, 3, "and A files whichever row it landed on")

  -- Nothing left to choose from is not a menu. It closes itself rather than
  -- holding a player in front of an empty list they cannot leave.
  picker:slot(1).party[2].hp = 0
  picker:slot(1).party[3].hp = 0
  client.replacing = true
  CoopBattle.updateReplace(client, press("a"))
  eq(client.replacing, nil, "an empty bench closes the picker instead of "
     .. "trapping the player in it")
end)()

-- a monster that still has *something* is not made to Struggle
sim = fieldSim({
  { side = "a", owner = "ann", name = "ANN",
    party = { mon(60, 50, { { id = "FIX_TACKLE", pp = 0 },
                            { id = "FIX_SCRATCH", pp = 5 } }) } },
  { side = "a", owner = "bob", name = "BOB",
    party = { mon(60, 40, { { id = "FIX_TACKLE", pp = 20 } }) } },
  { side = "b", owner = nil, name = "FOE",
    party = { mon(200, 30, { { id = "FIX_TACKLE", pp = 20 } }) } },
  { side = "b", owner = nil, name = "FOE",
    party = { mon(200, 20, { { id = "FIX_TACKLE", pp = 20 } }) } },
})
eq(sim:hasPP(sim:slot(1).battler), true, "one empty move is not empty-handed")
events = sim:resolveTurn({ { slot = 1, move = 1, target = 3 } })
local struggled = false
for _, event in ipairs(events) do
  if event.kind == "msg" and tostring(event.text):find("STRUGGLE") then
    struggled = true
  end
end
check(not struggled,
      "picking an empty move falls through to a usable one, not to Struggle")

-- ------- running is refused, in the game's own words

sim = fieldSim({
  { side = "a", owner = "ann", name = "ANN",
    party = { mon(60, 50, { { id = "FIX_TACKLE", pp = 20 } }) } },
  { side = "a", owner = "bob", name = "BOB",
    party = { mon(60, 40, { { id = "FIX_TACKLE", pp = 20 } }) } },
  { side = "b", owner = nil, name = "FOE",
    party = { mon(60, 30, { { id = "FIX_TACKLE", pp = 20 } }) } },
  { side = "b", owner = nil, name = "FOE",
    party = { mon(60, 20, { { id = "FIX_TACKLE", pp = 20 } }) } },
})
events = sim:resolveTurn({ { slot = 1, kind = "run" } })
local refused = false
for _, event in ipairs(events) do
  if event.kind == "msg" and tostring(event.text):lower():find("running") then
    refused = true
  end
end
check(refused, "RUN is refused -- a co-op battle is always a trainer battle")

-- ------- switching by choice costs the turn and swaps the mon

sim = fieldSim({
  { side = "a", owner = "ann", name = "ANN",
    party = { mon(60, 50, { { id = "FIX_TACKLE", pp = 20 } }),
              mon(45, 60, { { id = "FIX_TACKLE", pp = 20 } }) } },
  { side = "a", owner = "bob", name = "BOB",
    party = { mon(60, 40, { { id = "FIX_TACKLE", pp = 20 } }) } },
  { side = "b", owner = nil, name = "FOE",
    party = { mon(60, 30, { { id = "FIX_TACKLE", pp = 20 } }) } },
  { side = "b", owner = nil, name = "FOE",
    party = { mon(60, 20, { { id = "FIX_TACKLE", pp = 20 } }) } },
})
eq(sim:slot(1).active, 1, "the first mon is out")
sim:resolveTurn({ { slot = 1, kind = "switch", index = 2 } })
eq(sim:slot(1).active, 2, "SWITCH sends out the chosen one")
eq(sim:slot(1).battler.mon.stats.hp, 45, "and the field holds the new battler")

-- switching to something that is not there is refused rather than crashing
sim:resolveTurn({ { slot = 1, kind = "switch", index = 5 } })
eq(sim:slot(1).active, 2, "an impossible switch leaves the field alone")

-- ------- a ball is blocked, the way a trainer battle blocks one

local ballId
for id, def in pairs(data.items or {}) do
  if id:find("BALL") and not def.key then ballId = id break end
end
if ballId then
  sim = fieldSim({
    { side = "a", owner = "ann", name = "ANN",
      party = { mon(60, 50, { { id = "FIX_TACKLE", pp = 20 } }) }, bag = { [ballId] = 5 } },
    { side = "a", owner = "bob", name = "BOB",
      party = { mon(60, 40, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "b", owner = nil, name = "FOE",
      party = { mon(60, 30, { { id = "FIX_TACKLE", pp = 20 } }) } },
    { side = "b", owner = nil, name = "FOE",
      party = { mon(60, 20, { { id = "FIX_TACKLE", pp = 20 } }) } },
  })
  events = sim:resolveTurn({ { slot = 1, kind = "item", item = ballId } })
  local blocked = false
  for _, event in ipairs(events) do
    if event.kind == "msg" and tostring(event.text):lower():find("blocked") then
      blocked = true
    end
  end
  check(blocked, "a ball thrown in a co-op battle is blocked by the trainer")
else
  check(true, "(no ball in the fixture dataset to throw)")
end

-- ------- beating something pays both winners, as an event
--
-- The bug this pins is the one that took items and move learning before it:
-- the host resolves every slot but holds the real party for only its own, so
-- exp applied *here* paid the host and nobody else -- while still printing
-- "gained 136 EXP. Points!" on all four screens. So the payout is announced,
-- already divided, and each client applies it to the party its own save keeps.

sim = fieldSim({
  { side = "a", owner = "ann", name = "ANN",
    party = { mon(60, 50, { { id = "FIX_TACKLE", pp = 20 } }) } },
  { side = "a", owner = "bob", name = "BOB",
    party = { mon(60, 40, { { id = "FIX_TACKLE", pp = 20 } }) } },
  { side = "b", owner = nil, name = "FOE",
    party = { mon(1, 30, { { id = "FIX_TACKLE", pp = 20 } }) } },
  { side = "b", owner = nil, name = "FOE",
    party = { mon(60, 20, { { id = "FIX_TACKLE", pp = 20 } }) } },
})
for _, slot in ipairs({ sim:slot(1), sim:slot(2) }) do
  slot.battler.mon.exp = 0
  slot.battler.mon.statExp = {}
end

events = sim:resolveTurn({ { slot = 1, move = 1, target = 3 } })
check(sim:isDown(sim:slot(3)), "the foe goes down")

local paid = {}
for _, event in ipairs(events) do
  if event.kind == "exp" then paid[event.slot] = event end
end
check(paid[1] ~= nil, "the trainer who swung is paid")
check(paid[2] ~= nil, "and so is their partner -- both were in the fight")
eq(paid[1].winners, 2, "with the share divided between the two of them")
check(paid[1].amount > 0, "and it is worth something")
eq(paid[1].amount, paid[2].amount, "the same to each")
eq(paid[1].species, "FIXMON_A", "naming what was beaten, so a client can price it")

-- **Nothing was applied here.** That is the whole point: the host must not be
-- the only player who keeps what they earned.
eq(sim:slot(1).battler.mon.exp, 0,
   "the host applies nothing -- each client pays its own monster")
eq(sim:slot(2).battler.mon.exp, 0, "including its partner's")

-- the event carries what a client needs to price it for itself: EXP.ALL
-- doubles the divisor on the winner and spreads the other half across the
-- party, and none of that can be decided by the host
check(paid[1].level ~= nil, "the event names the level that was beaten")
check(paid[1].species ~= nil, "and the species, so the client can price it")

-- and the share is the engine's own arithmetic, halved for two winners
local solo = sim:expShare(sim:slot(3).battler.def, 30, 1)
local pair = sim:expShare(sim:slot(3).battler.def, 30, 2)
check(solo > 0, "one winner is owed something")
check(pair < solo, "and two winners each get less than one would")

-- ------- a fainted monster's replacement is its owner's choice
--
-- Auto-sending the next one is the easy implementation and it quietly removes
-- one of the few real decisions a Gen 1 battle offers. An NPC still sends out
-- whatever comes next -- there is nobody to ask.

sim = fieldSim({
  { side = "a", owner = "ann", name = "ANN",
    party = { mon(1, 50, { { id = "FIX_TACKLE", pp = 20 } }),
              mon(45, 60, { { id = "FIX_TACKLE", pp = 20 } }) } },
  { side = "a", owner = "bob", name = "BOB",
    party = { mon(60, 40, { { id = "FIX_TACKLE", pp = 20 } }) } },
  { side = "b", owner = nil, name = "FOE",
    party = { mon(1, 30, { { id = "FIX_TACKLE", pp = 20 } }),
              mon(50, 30, { { id = "FIX_TACKLE", pp = 20 } }) } },
  { side = "b", owner = nil, name = "FOE",
    party = { mon(60, 20, { { id = "FIX_TACKLE", pp = 20 } }) } },
})

events = sim:resolveTurn({ { slot = 1, move = 1, target = 3 } })
eq(sim:slot(3).active, 2, "an NPC sends out its next one without being asked")

sim:slot(1).battler.mon.hp = 0
local asked = {}
sim:announceFaint(sim:slot(1), function(e) asked[#asked + 1] = e end)
local sawChoose = false
for _, event in ipairs(asked) do
  if event.kind == "choose" and event.slot == 1 then sawChoose = true end
end
check(sawChoose, "a player's slot asks instead of choosing for them")
check(sim:awaitingChoice() ~= nil, "and the field knows it is waiting")
eq(sim:slot(1).active, 1, "with nothing sent out yet")
eq(sim:sideBeaten("a"), false, "their side is not beaten while a reserve waits")

check(sim:replace(1, 2, function() end), "answering sends out the chosen one")
eq(sim:slot(1).active, 2, "which is the one that was asked for")
eq(sim:awaitingChoice(), nil, "and nobody is waiting any more")

-- ------- a player who leaves mid-battle forfeits, rather than deadlocking
--
-- The host resolves a turn only once every human has filed an action, so a
-- player who closes the game would otherwise leave the other three sitting on
-- a turn that never comes. A client that is still connected but silent is the
-- same problem wearing a disguise, and lands on the same answer.

sim = fieldSim({
  { side = "a", owner = "ann", name = "ANN",
    party = { mon(60, 50, { { id = "FIX_TACKLE", pp = 20 } }),
              mon(60, 50, { { id = "FIX_TACKLE", pp = 20 } }) } },
  { side = "a", owner = "bob", name = "BOB",
    party = { mon(60, 40, { { id = "FIX_TACKLE", pp = 20 } }) } },
  { side = "b", owner = "cal", name = "CAL",
    party = { mon(60, 30, { { id = "FIX_TACKLE", pp = 20 } }) } },
  { side = "b", owner = "dee", name = "DEE",
    party = { mon(60, 20, { { id = "FIX_TACKLE", pp = 20 } }) } },
})

eq(#sim:living(), 4, "four are standing")
local left = sim:forfeit("cal")
check(left ~= nil, "the player who left is found by id")
eq(left.index, 3, "and it is their slot")
check(sim:isDown(sim:slot(3)), "a gone slot counts as out of the fight")
eq(sim:hasReserve(sim:slot(3)), nil, "with no reserve to send out")
eq(#sim:living(), 3, "so three are left standing")
eq(sim:sideBeaten("b"), false, "their side fights on while their partner is up")

sim:forfeit("dee")
eq(sim:sideBeaten("b"), true, "both of them gone beats the side")
eq(sim:forfeit("cal"), nil, "a player cannot leave twice")

-- the timeouts are ordered the way the design says -- but the other way round
-- from a first guess. The turn deadline is a *guarantee*: a turn opens, and
-- within COOP_TURN_TIMEOUT the host either resolves it or auto-picks for
-- whoever is late and resolves it anyway, so a `res` lands inside that many
-- seconds of every turn opening on a healthy host. The stall clock is what
-- asks "has the host said anything at all", and that question only means
-- something once a healthy host would have had to speak -- so it has to
-- exceed the guarantee, not undercut it. A shorter stall clock used to trip
-- every replayer into a resync on a legitimately quiet turn (four players
-- thinking, nobody late enough to be auto-picked yet) as an *expected* state.
check(Config.COOP_TURN_TIMEOUT > 0, "the host waits a finite time on a choice")
check(Config.COOP_STALL_TIMEOUT > 0, "and a replayer waits a finite time on the host")
check(Config.COOP_STALL_TIMEOUT > Config.COOP_TURN_TIMEOUT,
      "with the replayer's patience set past the deadline that guarantees "
      .. "the host will have spoken by then -- silence past that really is "
      .. "silence, not just an ordinary quiet turn")

-- ------- assembling an NPC side from a trainer record
--
-- This is where two real bugs lived, and neither was reachable from the field
-- tests: a trainer's `parties` entries are *specs* (species and level), not
-- monsters, and every party crosses the wire packed. A slot handed either one
-- raw has nothing to fight with.

local CoopBattle = need("CoopBattle")

local trainerId
for id, record in pairs(data.trainers or {}) do
  if record.parties and record.parties[1] and #record.parties[1] > 0 then
    trainerId = id
    break
  end
end

if trainerId then
  local built = CoopBattle.trainerParty({ data = data }, trainerId, 1)
  check(built ~= nil, "a trainer's party builds into real monsters")
  check(#built > 0, "with something in it")
  local first = built[1]
  check(first.stats ~= nil and (first.stats.hp or 0) > 0,
        "each one has stats -- a spec has none, which is the bug this catches")
  eq(first.hp, first.stats.hp, "and starts at full health")
  check(type(first.moves) == "table" and #first.moves > 0, "and knows moves")

  -- ...and it survives the round trip every party makes over the wire
  local packed = CoopBattle.packParty(built)
  check(packed ~= nil, "a built party packs for the wire")
  local rebuilt = CoopBattle.unpackParty({ data = data }, packed)
  check(rebuilt ~= nil, "and unpacks on the other side")
  eq(#rebuilt, #built, "with everyone still in it")
  eq(rebuilt[1].species, first.species, "as the same species")
  check((rebuilt[1].stats.hp or 0) > 0, "with stats recomputed, not lost")
else
  check(true, "(no trainer with a party in the fixture dataset)")
end

-- ------- the field names the trainer, so nobody has to have met them
--
-- Only the player who walked into the NPC holds the trainer record; anyone who
-- joined by answering an invitation has never seen it. The assembled field is
-- what closes that gap -- without the id on it, three of the four clients play
-- the wrong music and fight with an AI that has no class to reason from.

if trainerId then
  local Coop = need("Coop")
  local enemy = CoopBattle.trainerParty({ data = data }, trainerId, 1)
  local assembler = setmetatable({}, { __index = Coop })
  local battle = {
    parties = { ["ann"] = CoopBattle.packParty(enemy) },
    plan = {
      hostId = "ann", label = "TRAINER",
      allies = { { id = "ann", name = "ANN" }, { id = "bob", name = "BOB" } },
      engine = { enemyParty = enemy, trainer = { id = trainerId } },
    },
  }
  battle.parties["bob"] = battle.parties["ann"]
  local built = assembler:buildField({ data = data }, battle,
    battle.plan.allies)
  check(built ~= nil, "an NPC co-op field assembles")
  if built then
    eq(built.trainer, trainerId, "and names the trainer it was built against")
    eq(#built.slots, 4, "with four slots on it")
  end

  -- ...and the joiner reads it back. This is the client the whole id exists
  -- for: it answered an invitation, it never walked into this trainer, and so
  -- it has no engine battle to take the record off.
  local world = { data = data }
  local joined = Coop.trainerFor(world, built, nil)
  check(joined ~= nil, "a client that never met the trainer still resolves it")
  eq(joined, data.trainers[trainerId], "as this build's own record, not a copy")

  -- the client that did walk into them keeps what it already has, even if the
  -- field disagrees -- the record in hand is the one the engine built the
  -- displaced battle from
  local own = { trainer = { id = "OPP_SOMETHING_ELSE" } }
  eq(Coop.trainerFor(world, built, own), own.trainer,
     "and whoever walked into them keeps the record they already hold")

  -- the id is off the wire, so it is sanitised before it is used as a key
  eq(Coop.trainerFor(world, { trainer = { evil = true } }, nil), nil,
     "a trainer id that is not a string resolves to nothing")
  eq(Coop.trainerFor(world, { trainer = "../../etc/passwd" }, nil), nil,
     "and one that is not id-shaped is refused rather than looked up")
  eq(Coop.trainerFor(world, { trainer = "OPP_NOT_IN_THIS_BUILD" }, nil), nil,
     "an id this build has no record for leaves the battle faceless")
  eq(Coop.trainerFor(world, {}, nil), nil,
     "and a field with no trainer on it -- two parties -- names nobody")
end

-- ------- and the id is what picks the theme
--
-- The point of carrying it: a gym leader has their own battle music, and the
-- rule that decides so reads a badge table off the trainer's id. A client that
-- resolved no trainer plays the ordinary theme -- so before the id travelled,
-- the host heard the gym leader's music and everyone else heard a stranger's.

local eng = CoopBattle.loadEngine()
if eng and eng.BattleState then
  local function kindFor(trainer)
    return CoopBattle.musicKind({ trainer = trainer })
  end

  -- The subject comes from the badge table the rule itself reads, rather than
  -- from a name written down here: a leader renamed upstream would otherwise
  -- quietly turn this into a test of nothing. Only the id is needed -- the rule
  -- never looks at the rest of the record.
  local okBadges, victories = pcall(require, "data.scripts.victories")
  local leader
  if okBadges and type(victories) == "table" then
    for key, reward in pairs(victories) do
      if reward.badge and key:find("#", 1, true) then
        leader = key:sub(1, key:find("#", 1, true) - 1)
        break
      end
    end
  end

  if leader then
    eq(kindFor({ id = leader }), "gym",
       "a gym leader's co-op battle plays the gym leader's theme")
    check(kindFor({ id = "OPP_NOT_A_LEADER" }) ~= "gym",
          "and an ordinary trainer's does not -- the id really is deciding it")
  else
    check(true, "(this build ships no badge table to read leaders from)")
  end
  eq(kindFor(nil), "link",
     "two parties fighting each other get the link theme, not a trainer's")

  -- ------- and it is actually asked for, at the right moment
  --
  -- This build ships no audio data, so nothing can be heard here and
  -- Music.playBattle would return without doing anything. What can be checked
  -- is the boundary: that the battle asks for the right song at the right
  -- point. The three things that go wrong silently are all here -- a fanfare
  -- played to a closed screen, a victory theme that loops on into the
  -- overworld because nothing restored the map, and a "finalWin" jingle no
  -- build has.
  local realMusic = eng.Music
  local asked = {}
  eng.Music = {
    playBattle = function(_, kind) asked[#asked + 1] = "battle:" .. tostring(kind) end,
    playVictory = function(_, kind) asked[#asked + 1] = "win:" .. tostring(kind) end,
    restoreMap = function() asked[#asked + 1] = "restore" end,
  }

  local function battle(trainer)
    return setmetatable({
      game = { data = data }, trainer = trainer, messages = {},
      announce = function() end, say = function() end,
    }, { __index = CoopBattle })
  end

  local fight = battle(leader and { id = leader } or { id = "OPP_ANY" })
  fight:enter()
  eq(asked[1], "battle:" .. (leader and "gym" or "trainer"),
     "opening the battle asks for the battle theme")

  asked = {}
  fight.result = "win"
  fight:playVictoryMusic()
  fight:playVictoryMusic()
  eq(#asked, 1, "the fanfare starts once, however often the result is reached")
  fight:exit()
  eq(asked[2], "restore",
     "and the map theme comes back on the way out -- a victory theme loops "
     .. "forever, so a win that did not restore would play on in the overworld")

  -- a loss restores too, and never sounds a fanfare
  asked = {}
  local lost = battle({ id = "OPP_ANY" })
  lost.result = "loss"
  lost:playVictoryMusic()
  lost:exit()
  eq(#asked, 1, "a loss asks for exactly one thing")
  eq(asked[1], "restore", "and that thing is the map, not a fanfare")

  -- the rival's last fight: its own battle theme, the gym leader's jingle
  asked = {}
  local final = battle({ id = "OPP_RIVAL3" })
  if final:musicKind() == "final" then
    final.result = "win"
    final:playVictoryMusic()
    eq(asked[1], "win:gym",
       "the rival's last fight answers with the gym leader's jingle -- there "
       .. "is no such song as finalWin")
  else
    check(true, "(this build has no final-rival theme to fold)")
  end

  eng.Music = realMusic
end

-- ------- exp is priced on the client, not handed down
--
-- The host resolves the knockout but holds nobody's party except its own, so
-- what crosses the wire is a description of the kill -- species, level, how
-- many shared it -- and each client runs the engine's own arithmetic over its
-- own live monster. This asserts the two things that description has to buy:
-- that a shared knockout really is divided, and that an EXP.ALL in the bag
-- reaches a monster that never left its ball.

if eng and eng.Experience then
  local species = next(data.pokemon)
  local function monster(level)
    local built = eng.Pokemon.new(data, species, level or 5)
    built.statExp = built.statExp or {}
    return built
  end
  local function harness(inventory, party)
    local active = party[1]
    return setmetatable({
      mine = 1,
      game = { data = data, save = { inventory = inventory, party = party } },
      sim = { slot = function() return { battler = { mon = active,
                                                     name = "ACTIVE" } } end },
      say = function() end,
    }, { __index = CoopBattle })
  end
  local event = { slot = 1, species = species, level = 40, winners = 2 }
  -- A monster built at a level already carries the exp that level costs, so
  -- every assertion below is on the *gain*, not on the total.
  local baseline = monster().exp
  local function gained(mon) return mon.exp - baseline end

  -- one winner against two: the second must be worth strictly less
  local solo = monster()
  harness({}, { solo }):gainExp({ slot = 1, species = species, level = 40,
                                  winners = 1 })
  local shared = monster()
  harness({}, { shared }):gainExp(event)
  check(gained(shared) < gained(solo),
        "a knockout two players shared is worth less each than one alone")
  check(gained(shared) > 0, "but not nothing")

  -- EXP.ALL: the fighter takes less, and the bench stops being left out
  local benchOff, benchOn = monster(), monster()
  local fighterOff, fighterOn = monster(), monster()
  harness({}, { fighterOff, benchOff }):gainExp(event)
  harness({ EXP_ALL = 1 }, { fighterOn, benchOn }):gainExp(event)
  eq(gained(benchOff), 0, "without an EXP.ALL the bench gains nothing")
  check(gained(benchOn) > 0, "with one it does")
  check(gained(fighterOn) < gained(fighterOff),
        "and the monster that fought takes the halved share, as in the "
        .. "original -- an EXP.ALL costs the fighter, it is not free exp")

  -- a fainted party member is still left out
  local fainted = monster()
  fainted.hp = 0
  harness({ EXP_ALL = 1 }, { monster(), fainted }):gainExp(event)
  eq(gained(fainted), 0,
     "a fainted party member shares nothing, EXP.ALL or not")
else
  check(true, "(engine battle modules unavailable here)")
end

base.release()

end)()

-- ------------------------------------------------------------------
-- 13. The hubs you have played on
-- ------------------------------------------------------------------
--
-- src/Servers.lua is the store behind START > MMO > SERVERS -- who this
-- copy has connected to, a name, a favourite flag, a join code. Driven
-- here with love removed: the module's own header says a missing love
-- degrades it to mod.save alone, which is the half worth pinning against a
-- headless stub -- the dual-write file half already has its own coverage
-- pattern (the rank-token section above) and repeating it here would only
-- be testing the same file-store shape a second time.

;(function()

local ambientLove = _G.love
_G.love = nil

local Servers = need("Servers")

-- ------- record: creation, defaults, and the key an address is filed under

do
  stubSave = {}
  local store = Servers.new()

  local entry = store:record("short-host")
  check(entry ~= nil, "recording a fresh address creates an entry")
  local expectedAddress = ("short-host:%d"):format(Config.DEFAULT_PORT)
  eq(entry.address, expectedAddress,
     "withPort fills in the default port when none was typed")
  eq(entry.key, expectedAddress:lower(), "the key is the address, lower-cased")
  -- The label is the address with the port every hub of ours uses left off:
  -- the sanitiser truncates rather than wraps, and ":7788" is exactly what
  -- normalize just filled in, so eliding it costs no information and buys the
  -- five characters that keep a real address from being drawn as a false one.
  -- Only the label is shortened -- entry.address above still carries the port
  -- CONNECT dials.
  eq(entry.name, "short-host",
     "and the name defaults to the address with the standard port left off")
  eq(entry.fav, false, "a fresh entry is not a favourite")
  eq(entry.code, nil, "and has no code until one is given")

  local spaced = store:record("  Mixed.Case.Host  ")
  check(spaced ~= nil, "whitespace and case do not stop a record")
  local expectedMixed = "Mixed.Case.Host:" .. tostring(Config.DEFAULT_PORT)
  eq(spaced.address, expectedMixed,
     "surrounding whitespace is stripped before the port is filled in")
  eq(spaced.key, expectedMixed:lower(),
     "the key is lower-cased and holds no whitespace, however it was typed")

  local stoppedAtColon = store:record("colon-host:")
  eq(stoppedAtColon.address, ("colon-host:%d"):format(Config.DEFAULT_PORT),
     "a remembered server treats an empty port slot as the default port too")

  local badPort = store:record("bad-port.example:nope")
  eq(badPort.address, ("bad-port.example:%d"):format(Config.DEFAULT_PORT),
     "and so does a non-numeric port slot")

  local impossiblePort = store:record("bad-port.example:99999")
  eq(impossiblePort.address, ("bad-port.example:%d"):format(Config.DEFAULT_PORT),
     "or a numeric port no socket can dial")

  eq(store:record(":7788"), nil,
     "but a remembered server still needs a host, not only a port")

  local ported = store:record("already.has.a.port:9191")
  eq(ported.address, "already.has.a.port:9191",
     "an address that already carries a port keeps its own, not the default")
  -- Only the *standard* port is elided. A port that is not the one every hub
  -- of ours listens on is the difference between a name that dials and a name
  -- that does not, so it stays -- and when what is left still will not fit,
  -- truncation is the last resort rather than the first.
  eq(ported.name, ("already.has.a.port:9191"):sub(1, Config.SERVER_NAME_MAX),
     "a name too long even with the port kept is truncated, not re-ported")

  local oddPort = store:record("hub:9191")
  eq(oddPort.name, "hub:9191",
     "a non-standard port is part of the name -- it is not the one eliding "
     .. "assumes, so dropping it would name a hub nothing is listening on")

  local longHost = store:record("a-very-long-hostname.example")
  eq(#longHost.name, Config.SERVER_NAME_MAX,
     "a host too long for the row is capped at the name limit")
  eq(longHost.name, ("a-very-long-hostname.example"):sub(1,
     Config.SERVER_NAME_MAX),
     "from the front, and with the elided standard port never counted in")
  eq(longHost.address, ("a-very-long-hostname.example:%d")
     :format(Config.DEFAULT_PORT),
     "while the address CONNECT dials is untouched by any of that")
end

-- ------- record: refresh keeps the player's own fields, and the code only
-- moves when a fresh one is actually given

do
  stubSave = {}
  local store = Servers.new()
  local VALID_CODE = "A7K3P9"

  local first = store:record("refresh.example", VALID_CODE)
  local key = first.key
  eq(first.code, VALID_CODE, "the code given at record time is kept")

  store:rename(key, "My Named Hub")
  store:setFavorite(key, true)

  local again = store:record("refresh.example", nil)
  eq(again.key, key, "the same address refreshes the same row, not a new one")
  eq(again.name, "My Named Hub",
     "a reconnect does not overwrite the name the player chose")
  eq(again.fav, true, "nor the favourite flag")
  eq(again.code, VALID_CODE,
     "and a reconnect with no code leaves the one already on the row alone")

  local OTHER_CODE = "K3P9A7"
  local recoded = store:record("refresh.example", OTHER_CODE)
  eq(recoded.code, OTHER_CODE,
     "but a reconnect that does carry a code updates it")
end

-- ------- list: favourites first, and address (key) DESC within each group

do
  stubSave = {}
  local store = Servers.new()
  store:record("b-host")
  store:record("a-host")
  store:record("c-host")

  local plain = store:list()
  eq(#plain, 3, "all three are listed")
  eq(plain[1].key:sub(1, 1), "c", "descending: c sorts above b and a")
  eq(plain[2].key:sub(1, 1), "b", "b sits in the middle")
  eq(plain[3].key:sub(1, 1), "a", "and a is last of the plain group")

  store:setFavorite(plain[3].key, true) -- a-host
  local withFav = store:list()
  eq(withFav[1].key:sub(1, 1), "a",
     "a favourite is pinned above every non-favourite, regardless of address")
  eq(withFav[2].key:sub(1, 1), "c", "the non-favourite group is still DESC")
  eq(withFav[3].key:sub(1, 1), "b", "with b last")
end

-- ------- featured: a synthetic menu row, never part of persisted recents

do
  stubSave = {}
  local store = Servers.new()

  eq(#store:list(), 0,
     "the persisted-recents list stays empty on a fresh copy")
  eq(store:get(Config.FEATURED_SERVER_HOST), nil,
     "and normal get does not expose the product-owned server")

  local menu = store:menuList()
  eq(#menu, 1, "the menu projection still has the featured server")
  local featured = menu[1]
  eq(featured.name, "RBY MMO OFFICIAL", "under its canonical label")
  eq(featured.address, "play.rbymmo.com:7788",
     "with the official dial address")
  eq(featured.code, "QG0251", "and the official join code")
  eq(featured.key, Config.FEATURED_SERVER_HOST:lower(),
     "filed under the same normalised key as a recent")
  eq(featured.featured, true,
     "marked so the UI can protect product-owned fields")

  local resolved = store:menuGet(featured.key)
  check(resolved ~= nil, "menuGet resolves the synthetic row")
  eq(resolved and resolved.address, Config.FEATURED_SERVER_HOST,
     "to the same official address")
  eq(resolved and resolved.code, Config.FEATURED_SERVER_CODE,
     "and the same official code")

  local returned = store:record(Config.FEATURED_SERVER_HOST,
                                Config.FEATURED_SERVER_CODE)
  check(returned ~= nil and returned.featured == true,
        "a welcome from the official hub returns the synthetic entry")
  eq(#store:list(), 0,
     "but does not turn the official hub into a persisted recent")
  eq(store:get(Config.FEATURED_SERVER_HOST), nil,
     "or make it visible through normal get")
  eq(stubSave.servers, nil,
     "and recording only the official hub performs no persistence write")
end

do
  -- An older build may already have persisted the official address. Loading
  -- it must collapse that stale row into the canonical synthetic one, even if
  -- its user-editable fields disagree. A later ordinary write also cleans it
  -- out of the mirror instead of writing the legacy copy back.
  stubSave = { servers = {
    { address = "PLAY.RBYMMO.COM:7788", name = "Old nickname",
      fav = true, code = "A7K3P9", last = 99 },
  } }
  local store = Servers.new()

  eq(#store:list(), 0,
     "a saved copy of the official address is not counted as a recent")
  local menu = store:menuList()
  eq(#menu, 1, "the saved official address is deduped in the menu")
  eq(menu[1].name, Config.FEATURED_SERVER_NAME,
     "and the synthetic row keeps its canonical label")
  eq(menu[1].code, Config.FEATURED_SERVER_CODE,
     "rather than a code from the stale saved row")

  store:record("ordinary-after-upgrade.example")
  eq(#stubSave.servers, 1,
     "the next persistence write contains only the ordinary recent")
  eq(stubSave.servers[1].address,
     ("ordinary-after-upgrade.example:%d"):format(Config.DEFAULT_PORT),
     "so the legacy official row is not persisted again")
  local updatedMenu = store:menuList()
  eq(#updatedMenu, 2, "the menu has the featured row plus that one recent")
  eq(updatedMenu[1].name, Config.FEATURED_SERVER_NAME,
     "and the featured server stays above persisted rows")
end

do
  stubSave = {}
  local store = Servers.new()
  local officialKey = Config.FEATURED_SERVER_HOST:lower()
  local ordinary = store:record("mutable.example")

  eq(store:rename(officialKey, "Renamed"), nil,
     "the featured row cannot be renamed")
  eq(store:setFavorite(officialKey, true), nil,
     "the featured row cannot be favourited")
  eq(store:setAddress(officialKey, "elsewhere.example:9191"), nil,
     "the featured row's address cannot be edited")
  eq(store:setCode(officialKey, "A7K3P9"), nil,
     "the featured row's code cannot be edited")
  eq(store:remove(officialKey), nil,
     "the featured row cannot be deleted")
  eq(store:setAddress(ordinary.key, Config.FEATURED_SERVER_HOST), nil,
     "and an ordinary recent cannot be moved onto the featured address")

  local featured = store:menuGet(officialKey)
  eq(featured and featured.name, Config.FEATURED_SERVER_NAME,
     "refused mutators leave the official label unchanged")
  eq(featured and featured.address, Config.FEATURED_SERVER_HOST,
     "and leave its address unchanged")
  eq(featured and featured.code, Config.FEATURED_SERVER_CODE,
     "and leave its code unchanged")
  eq(#store:list(), 1,
     "while the ordinary persisted recent remains the only counted row")
end

-- ------- eviction: the cap, LRU order, favourites, and the row just written

do
  -- the real cap, so this is the same number a player's copy enforces
  stubSave = {}
  local store = Servers.new()
  for i = 1, Config.SERVER_LIST_MAX do
    local entry = store:record(("host%02d"):format(i))
    -- controlled recency: host01 is the oldest, host16 the newest of the
    -- batch, so which one the cap evicts is never left to os.time()'s
    -- one-second resolution
    entry.last = i
  end
  eq(#store:list(), Config.SERVER_LIST_MAX,
     "exactly the cap fits with no eviction yet")

  local newest = store:record("host17")
  eq(#store:list(), Config.SERVER_LIST_MAX,
     "recording one more holds the list at the cap, not above it")
  check(store:get("host01") == nil,
        "the least recently connected non-favourite is the one dropped")
  check(store:get("host17") ~= nil, "and the row just recorded is in the list")
  check(newest ~= nil, "record() still hands back the entry it just wrote")
end

do
  -- favourites are never eviction candidates, even once they push the list
  -- past the cap -- so the cap is shrunk here to reach that state in a
  -- handful of rows rather than seventeen
  local savedCap = Config.SERVER_LIST_MAX
  Config.SERVER_LIST_MAX = 1
  stubSave = {}
  local store = Servers.new()

  local fav = store:record("kept-favourite")
  store:setFavorite(fav.key, true)
  store:record("second-row")

  eq(#store:list(), 2,
     "a favourite and the row that pushed the list past the cap both survive "
     .. "-- there was nothing else eligible to evict")
  check(store:get(fav.key) ~= nil, "the favourite itself is still there")

  Config.SERVER_LIST_MAX = savedCap
end

do
  -- the row record() just wrote can never be its own eviction, even set up
  -- so that -- by recency alone -- an older row would look newer than it
  local savedCap = Config.SERVER_LIST_MAX
  Config.SERVER_LIST_MAX = 1
  stubSave = {}
  local store = Servers.new()

  local existing = store:record("already-here")
  existing.last = os.time() + 1000000 -- made to look far newer than "now"

  local brandNew = store:record("just-recorded")
  eq(#store:list(), 1, "the cap held at one")
  check(store:get(brandNew.key) ~= nil,
        "the row just recorded is never its own eviction, however its own "
        .. "timestamp compares to what else is on the list")
  check(store:get(existing.key) == nil,
        "so the older row gives way instead, even though it was made to "
        .. "look newer")

  Config.SERVER_LIST_MAX = savedCap
end

do
  -- The same protection on every other mutator, not just record().
  --
  -- Writing re-reads the file first, because another save slot -- or a second
  -- copy under the same LOVE identity -- may have recorded a hub since we last
  -- looked. Folding theirs in can push the list back over the cap, and the
  -- eviction that follows must not be allowed to throw away the row the caller
  -- is in the middle of changing and about to be handed back.
  --
  -- _read is stood in for rather than a file written, because love is absent
  -- for this whole section: this is the one behaviour that only exists when
  -- the read half answers, so the read half is what gets stubbed.
  local savedCap = Config.SERVER_LIST_MAX
  Config.SERVER_LIST_MAX = 1
  stubSave = {}
  local store = Servers.new()

  local mine = store:record("zzz-host")
  -- a degraded clock: every row's `last` reads 0, the tie falls to the key,
  -- and by key alone this row is the one that loses it
  mine.last = 0
  store._read = function()
    return { { address = "aaa-host", last = 0 } }, false
  end

  local renamed = store:rename(mine.key, "Kept Name")
  check(renamed ~= nil, "the rename is applied")
  check(store:get(mine.key) ~= nil,
        "and the row it was applied to is still listed -- the write's own "
        .. "eviction is told which row not to take")
  eq(renamed and renamed.name, "Kept Name",
     "so what comes back is a row that is really on the list")

  Config.SERVER_LIST_MAX = savedCap
end

-- ------- rename: sanitised, capped, and a garbage-only name is refused

do
  stubSave = {}
  local store = Servers.new()
  local entry = store:record("rename.example")
  local key = entry.key

  local long = ("x"):rep(Config.SERVER_NAME_MAX + 10)
  local renamed = store:rename(key, long)
  check(renamed ~= nil, "a long name is truncated, not refused")
  eq(#renamed.name, Config.SERVER_NAME_MAX,
     "truncated to exactly the cap, the naming grid's own limit")

  local warns = {}
  stubMod.log.warn = function(_, fmt, ...)
    local ok, line = pcall(string.format, fmt, ...)
    warns[#warns + 1] = ok and line or tostring(fmt)
  end

  eq(store:rename(key, "\1\2\3"), nil,
     "a name with nothing the font can draw is refused")
  eq(store:get(key).name, long:sub(1, Config.SERVER_NAME_MAX),
     "leaving the row's real name exactly as it was")
  check(#warns > 0, "and the refusal is logged")

  eq(store:rename("no-such-key:1234", "Anything"), nil,
     "renaming a key nothing is stored under is refused, not a crash")

  stubMod.log.warn = function() end
end

-- ------- setCode: only a whole code is accepted, and a refusal never clears

do
  stubSave = {}
  local store = Servers.new()
  local entry = store:record("code.example")
  local key = entry.key

  eq(store:setCode(key, "A7K3P9"), entry, "a valid code is accepted")
  eq(store:get(key).code, "A7K3P9", "and lands on the row")

  eq(store:setCode(key, "too-short"), nil, "a half-code is refused")
  eq(store:get(key).code, "A7K3P9", "leaving the real code exactly as it was")

  eq(store:setCode(key, nil), nil, "nil is refused the same way")
  eq(store:get(key).code, "A7K3P9", "and still never clears the row")

  eq(store:setCode("gone:1234", "A7K3P9"), nil,
     "an unknown key refuses rather than creating a row")
end

-- ------- setAddress: re-keys in place, and a collision replaces the target

do
  stubSave = {}
  local store = Servers.new()
  local entry = store:record("old.address:1111")
  local key = entry.key
  store:rename(key, "Kept Name")
  store:setFavorite(key, true)
  store:setCode(key, "A7K3P9")

  local moved = store:setAddress(key, "new.address:2222")
  check(moved ~= nil, "the address changes")
  eq(moved.key, "new.address:2222", "under a new key")
  check(store:get(key) == nil, "and the old key is gone")
  eq(moved.name, "Kept Name", "the name travels with the row")
  eq(moved.fav, true, "so does the favourite flag")
  eq(moved.code, "A7K3P9", "and the join code")

  -- a collision: a second row is moved onto the address the first row
  -- already lives at
  local other = store:record("third.address:3333")
  local collided = store:setAddress(other.key, "new.address:2222")
  check(collided ~= nil, "the move still succeeds")
  eq(#store:list(), 1,
     "the row already at that address is replaced, not duplicated")
  eq(store:get("new.address:2222").address, "new.address:2222",
     "one row lives at the target address afterward")

  eq(store:setAddress("gone:1234", "somewhere:5555"), nil,
     "an unknown key is refused rather than creating a row")
end

-- ------- get: a key or a raw, differently-cased address both resolve

do
  stubSave = {}
  local store = Servers.new()
  local entry = store:record("Case.Example:4444")
  eq(store:get(entry.key), entry, "the key finds it")
  eq(store:get("CASE.example:4444"), entry,
     "so does the raw address, however it is cased")
  eq(store:get("nothing-stored-here:1"), nil,
     "and an address nothing was ever recorded under answers nil")
end

-- ------- persistence: a fresh store over the same mod.save sees the same rows

do
  stubSave = {}
  local first = Servers.new()
  first:record("persisted.example:5555")

  local second = Servers.new()
  local list = second:list()
  eq(#list, 1, "a new store instance sees what the old one wrote")
  eq(list[1].address, "persisted.example:5555",
     "the same row, over mod.save alone")
end

-- ------- remove: the entry leaves the list, and a dropped key stays dropped
-- until the player asks for that hub again on purpose

do
  stubSave = {}
  local store = Servers.new()
  local entry = store:record("gone.example:6666")
  local key = entry.key

  local removed = store:remove(key)
  eq(removed, entry, "remove hands back the entry it deleted")
  check(store:get(key) == nil, "and the row is gone from the store")
  eq(#store:list(), 0, "so the list it was the only row of is empty")

  local warns = {}
  stubMod.log.warn = function(_, fmt, ...)
    local ok, line = pcall(string.format, fmt, ...)
    warns[#warns + 1] = ok and line or tostring(fmt)
  end
  eq(store:remove("no-such-key:1234"), nil,
     "removing a key nothing is stored under refuses rather than crashing")
  check(#warns > 0, "and the refusal is logged")
  stubMod.log.warn = function() end

  -- The dropped mark is what stops the file half from resurrecting a row
  -- this session deleted on purpose: _persist folds in rows it has never
  -- seen, and without the mark a copy of this key still sitting on disk
  -- would walk straight back in on the very write meant to remove it. love
  -- is absent for this whole section (see the header above), so the
  -- fold-in this guards against is driven directly rather than through a
  -- real file -- the same way the eviction-protection block above stands
  -- in for _read.
  store:_ingest({ { address = entry.address, last = 1 } }, true)
  check(store:get(key) == nil,
        "a fold-in of a file row filed under the deleted key does not "
        .. "resurrect it")

  -- record() is not a fold-in, though -- it is the player asking to connect
  -- to that hub again, on purpose, and that has to win. A deleted-then-
  -- rejoined hub reappearing is the intended shape of the guard, not a
  -- second bug in the same corner: record() clears the drop mark itself
  -- (src/Servers.lua, right after it fills in address/last/code) before
  -- this write ever reaches _persist.
  local rejoined = store:record(entry.address)
  check(rejoined ~= nil, "recording the same address again succeeds")
  eq(rejoined.key, key, "under the same key as before")
  check(store:get(key) ~= nil,
        "and it is really back in the store, not just handed back once")
  eq(#store:list(), 1,
     "deleted-then-rejoined reappears on the list rather than staying "
     .. "invisible forever")
end

_G.love = ambientLove

end)()

-- ------------------------------------------------------------------
-- 14. previewRows: which visible rows get a portrait
-- ------------------------------------------------------------------
--
-- The picker's portrait sits in the gutter to the *left* of every visible
-- row that names a character -- unlike the "came with the mod" mark above,
-- a portrait is not a distinction between rows, so the row under the
-- cursor gets one exactly like its neighbours. Pinned here the same way
-- markedRows is: the rule has to hold while the list scrolls, and this
-- headless suite has no graphics context to read a frame with.

;(function()

local UiPreview = need("Ui").previewRows

local list = {
  { label = "  ALPHA", value = "SPRITE_ALPHA" },
  { label = "  BETA", value = "SPRITE_BETA" },
  { label = "  GAMMA", value = "SPRITE_GAMMA" },
}

local function ids(index, scroll, rows)
  local out = {}
  for _, preview in ipairs(UiPreview({ items = list, index = index,
                                       scroll = scroll or 0, rows = rows or 7 })) do
    out[#out + 1] = list[(scroll or 0) + preview.row].value
  end
  return table.concat(out, ",")
end

eq(ids(1), "SPRITE_ALPHA,SPRITE_BETA,SPRITE_GAMMA",
   "every visible row previews, cursor row included")
eq(ids(2), "SPRITE_ALPHA,SPRITE_BETA,SPRITE_GAMMA",
   "unlike the mark, the row under the cursor is not skipped")

-- The rows are the *visible* ones, so a scrolled list previews what is on
-- screen rather than the whole catalog.
eq(ids(1, 1, 7), "SPRITE_BETA,SPRITE_GAMMA",
   "a scrolled list previews what is on screen")
eq(ids(1, 0, 2), "SPRITE_ALPHA,SPRITE_BETA",
   "and a short window stops at its last row")

-- The y it hands back is the widget's own row geometry, same as markedRows.
local rows = UiPreview({ items = list, index = 1, scroll = 0, rows = 7 })
eq(rows[1].row, 1, "the first row previews first")
eq(rows[1].y, 8 + 1 * 16, "at the y that row's label is drawn on")
eq(rows[1].id, "SPRITE_ALPHA", "the id comes from item.value")

eq(#UiPreview(nil), 0, "no menu previews nothing")
eq(#UiPreview({}), 0, "and neither does one with no items")
eq(#UiPreview({ items = { { label = "no value" } } }), 0,
   "a row with no value -- not a character row -- previews nothing")

end)()

-- ------------------------------------------------------------------
-- 15. WELCOME writes the hub this copy actually reached to the server list
-- ------------------------------------------------------------------
--
-- src/Client.lua records a hub the moment it welcomes this copy in
-- (handlers[Wire.WELCOME], gated on the private `dialled` upvalue) -- never
-- on a dial that only timed out or was refused. `dialled` and the handler
-- table are both private to that module, reachable only through the real
-- per-tick pump, so this drives a whole, fresh, isolated Client instance
-- through it: a fake Net stands in for the socket (the same shape the
-- Transport section above uses), and `mod.hooks:wrap` is a stub that
-- actually *records* what it is given -- which is what makes the captured
-- "input.step" callback callable directly, exactly the way the real engine
-- calls it once a fixed step.
--
-- Built against a mod facade of its own (resolver(miniMod), not the shared
-- stubMod) so nothing here has to fight the rest of this file over
-- `mod.hooks` / `mod.exports`, which no other section needs to be anything
-- but a no-op. love is removed for the same reason section 13 removes it:
-- the servers store this Client owns would otherwise dual-write through
-- the ambient love stub's real filesystem, which is a second thing to
-- reason about that this section does not need.

;(function()

local ambientLove = _G.love
_G.love = nil

local hookChains = {}
local miniSave, miniOptions = {}, {}
local screens = {}
local miniWarns = {}

local miniMod = {
  id = "rby_mmo",
  path = MOD_PATH,
  log = {
    info = function() end,
    warn = function(_, fmt, ...)
      local ok, line = pcall(string.format, fmt, ...)
      miniWarns[#miniWarns + 1] = ok and line or tostring(fmt)
    end,
    error = function() end,
  },
  save = {
    get = function(_, key, default)
      local v = miniSave[key]
      if v == nil then return default end
      return v
    end,
    set = function(_, key, value) miniSave[key] = value end,
  },
  options = {
    define = function() end,
    get = function(_, key) return miniOptions[key] end,
  },
  events = {
    emit = function() end,
    on = function() end,
    once = function() end,
  },
  assets = { path = function(_, relative) return MOD_PATH .. "/" .. relative end },
  content = {
    sprites = {
      each = function() return function() return nil end end,
      get = function() return nil end,
      register = function() end,
    },
    battle_sprite_scales = { get = function() end, register = function() end },
    render_pipelines = { each = function() return function() return nil end end },
    screens = {
      register = function(_, id, def) screens[id] = def end,
      get = function(_, id) return screens[id] end,
    },
  },
  hooks = {
    wrap = function(_, name, fn)
      hookChains[name] = hookChains[name] or {}
      hookChains[name][#hookChains[name] + 1] = fn
    end,
  },
  ui = {},
  exports = {},
}

local Client = resolver(miniMod)("Client")
check(Client ~= nil, "a Client instance builds against its own mod facade")
Client.install()

local stepFn = hookChains["input.step"] and hookChains["input.step"][1]
check(stepFn ~= nil, "install() registers the per-tick pump")
local passthroughNext = function() end

local function fakeNet()
  return {
    closed = false, outbox = {}, inbox = {},
    send = function(self, msg) self.outbox[#self.outbox + 1] = msg end,
    update = function() end,
    poll = function(self) local m = self.inbox; self.inbox = {}; return m end,
    close = function(self) self.closed = true end,
  }
end

-- ------- a dialled connection records, with the code stored for it

local netA = fakeNet()
local ADDRESS_A = "welcome.example.test:9191"
Client.setJoinAddress(ADDRESS_A)
Client.setJoinCode(ADDRESS_A, "A7K3P9")
-- Client.connect dials through Transport:connect, which really opens a
-- socket -- unreachable headless. The suite's own seam for this (attach, in
-- the Transport-framing section far above) skips M.connect entirely and so
-- never sets `dialled`, the field this section is about -- so :connect
-- itself is overridden, on the one Transport instance this Client owns, to
-- land on the fake net the way :attach would.
Client.transport.connect = function(self)
  self.net = netA
  self.state = "connecting"
  self.error = nil
  self.clock, self.lastHeard, self.lastPing = 0, 0, 0
  return true
end

local connected = Client.connect({})
check(connected, "connect succeeds against the fake net")

netA.inbox = { { type = Wire.WELCOME, id = "peer-a", players = {} } }
stepFn(passthroughNext, {}, 0.016)

local recorded = Client.servers():get(ADDRESS_A)
check(recorded ~= nil, "a WELCOME on a dialled connection records the hub")
-- No challenge arrived, so nothing was answered with a code and nothing is
-- written down as one. M.joinCode falls back to the standing JOIN CODE option
-- when a hub has none of its own, so recording its answer here regardless
-- would stamp that one option onto every open hub the player ever joins --
-- pinned under the per-hub key, where it then outranks the option it came
-- from.
eq(recorded.code, nil,
   "but a hub that never challenged us gets no code on its row")

-- ------- a hub that did challenge: the code that answered it is kept
--
-- Driven through the real CHALLENGE handler rather than by setting the flag,
-- because the flag is a private upvalue and the thing being pinned is exactly
-- that answering is what makes it true.

Client.disconnect()
local netD = fakeNet()
local ADDRESS_D = "challenged.example.test:9191"
Client.setJoinAddress(ADDRESS_D)
Client.setJoinCode(ADDRESS_D, "A7K3P9")
Client.transport.connect = function(self)
  self.net = netD
  self.state = "connecting"
  self.error = nil
  self.clock, self.lastHeard, self.lastPing = 0, 0, 0
  return true
end
check(Client.connect({}), "connect succeeds for the challenged case")

-- a whole nonce, in the shape Wire.hex accepts: lowercase hex, NONCE_HEX long
local NONCE = ("ab"):rep(Config.NONCE_HEX / 2)
netD.inbox = { { type = Wire.CHALLENGE, nonce = NONCE } }
stepFn(passthroughNext, {}, 0.016)

local answer
for _, msg in ipairs(netD.outbox) do
  if msg.type == Wire.AUTH then answer = msg end
end
check(answer ~= nil, "the challenge is answered from the stored code")
eq(answer and answer.response, Sha256.hmacHex("A7K3P9", NONCE),
   "with the HMAC the hub will check")

netD.inbox = { { type = Wire.WELCOME, id = "peer-d", players = {} } }
stepFn(passthroughNext, {}, 0.016)

local challenged = Client.servers():get(ADDRESS_D)
check(challenged ~= nil, "the hub is recorded")
eq(challenged and challenged.code, "A7K3P9",
   "and this time the row carries the code, because a code is what got us in")

-- ------- no dial, no record -- the self-host shape

Client.disconnect()
local netB = fakeNet()
Client.transport:attach(netB)
netB.inbox = { { type = Wire.WELCOME, id = "peer-b", players = {} } }
stepFn(passthroughNext, {}, 0.016)

eq(#Client.servers():list(), 2,
   "a WELCOME with nothing dialled -- hosting's own shape -- adds no row; "
   .. "the list still holds only the two from the cases above")

-- ------- a servers-store failure cannot break the tick that carries it

Client.disconnect()
local netC = fakeNet()
local ADDRESS_C = "breaks.example.test:9191"
Client.setJoinAddress(ADDRESS_C)
Client.transport.connect = function(self)
  self.net = netC
  self.state = "connecting"
  self.error = nil
  self.clock, self.lastHeard, self.lastPing = 0, 0, 0
  return true
end
check(Client.connect({}), "connect succeeds again for the failure case")

local realRecord = Client.servers().record
Client.servers().record = function() error("boom: a forced store failure") end

netC.inbox = { { type = Wire.WELCOME, id = "peer-c", players = {} } }
miniWarns = {}
local ranWithoutThrowing = pcall(stepFn, passthroughNext, {}, 0.016)
check(ranWithoutThrowing,
      "a servers-store failure inside WELCOME is pcall-wrapped, so the tick "
      .. "that carries it never throws")
check(Client.isConnected(),
      "and the connection itself survives -- only the bookkeeping failed")
check(#miniWarns > 0, "the failure is logged")
check((miniWarns[1] or ""):find(ADDRESS_C, 1, true) ~= nil,
      "naming the address that could not be added to the list")

Client.servers().record = realRecord

-- ------- forgetHub clears the stored join code, never the rank claim
-- ticket, for the same hub
--
-- The code is the hub's secret, filed under "code:<hub>" (Client.lua's
-- codeKey) and is what a "Forget this server" row should drop. The claim
-- ticket is the player's own earned identity on that hub, filed separately
-- under "rank:<hub>" (tokenKey) -- deleting a bookmark must not cost a
-- rating, so it is deliberately left standing.

local FORGET_ADDR = "forget.example.test:9191"
miniSave["code:" .. FORGET_ADDR] = "A7K3P9"
miniSave["rank:" .. FORGET_ADDR] = "a-claim-ticket"

local forgot = Client.forgetHub(FORGET_ADDR)
check(forgot == true, "forgetHub reports success")
eq(miniSave["code:" .. FORGET_ADDR], nil,
   "the stored join code for that hub is cleared")
eq(miniSave["rank:" .. FORGET_ADDR], "a-claim-ticket",
   "but the rank claim ticket for the same hub is left exactly as it was")

_G.love = ambientLove

end)()

-- ------------------------------------------------------------------
-- 16. The three screens behind SERVERS
-- ------------------------------------------------------------------
--
-- Driven the way the partner-gating section drives ACTIONS, above: through
-- Ui:install() and the registered screen's own constructor, against a
-- minimal stub of mod.content.screens / mod.hooks / mod.ui, swapped onto
-- the shared stubMod for the length of this section and restored
-- afterward -- never left nil'd on a field the rest of this file relies on.
-- love is removed too, for section 13's reason: a store built under the
-- ambient stub would dual-write through its real in-memory filesystem, and
-- a fresh storeWith() below is supposed to start from nothing every time.

;(function()

local Servers = need("Servers")
local Ui = need("Ui")

local ambientLove = _G.love
_G.love = nil

local screenRegistry = {}
stubMod.content.screens = {
  register = function(_, id, def) screenRegistry[id] = def end,
  get = function(_, id) return screenRegistry[id] end,
}
stubMod.hooks = { wrap = function() end }
-- Where a row's onSelect says to go next. Recorded rather than performed:
-- these screens navigate by pushing, so the push *is* the observable, and a
-- stub that actually built the next screen would be a second screen's
-- assertions leaking into this one's.
local pushes = {}
stubMod.ui = {
  push = function(_, id, opts)
    pushes[#pushes + 1] = { id = id, opts = opts }
  end,
  Menu = { new = function(_, items, opts)
    return { items = items, opts = opts, clampScroll = function() end }
  end },
  ListMenu = { new = function(_, title, items, opts)
    return { title = title, items = items, opts = opts }
  end },
  TextBox = { new = function(_, text, onDone)
    return { text = text, onDone = onDone }
  end },
  NamingScreen = { new = function(_, opts)
    opts = opts or {}
    return {
      maxLen = opts.maxLen,
      title = opts.title,
      glyphs = {},
      onDone = opts.onDone,
      update = function() end,
      confirm = function(self)
        if type(self.onDone) == "function" then
          self.onDone(table.concat(self.glyphs))
        end
      end,
      draw = function(self, ...) end,
    }
  end },
}

local function fakeClient(hosting, connected)
  return { isHosting = function() return hosting end,
           isConnected = function() return connected end }
end

local function storeWith(entries)
  stubSave = {}
  local store = Servers.new()
  for _, addr in ipairs(entries or {}) do store:record(addr) end
  return store
end

local ctx = { client = fakeClient(false, false), chat = { unread = 0 },
              servers = storeWith({}) }
local ui = Ui.new(ctx)
check(pcall(function() ui:install() end),
      "the real SERVERS screens register under this minimal stub")

-- ------- SCREEN.MAIN: the SERVERS row

local mainDef = screenRegistry[Ui.SCREEN.MAIN]
check(mainDef ~= nil, "SCREEN.MAIN is the one that registered")

local function mainLabels()
  local out = {}
  for i, item in ipairs(mainDef.new({}).items) do out[i] = item.label end
  return out
end
local function hasLabel(list, label)
  for _, l in ipairs(list) do if l == label then return true end end
  return false
end

ctx.servers = storeWith({})
eq(hasLabel(mainLabels(), "SERVERS"), true,
   "a disconnected fresh copy always has the SERVERS row")

ctx.servers = storeWith({ "one.example" })
local rows = mainLabels()
eq(hasLabel(rows, "SERVERS"), true,
   "remembered recents keep the row visible while disconnected")
local hostIdx, serversIdx
for i, label in ipairs(rows) do
  if label == "HOST GAME" then hostIdx = i end
  if label == "SERVERS" then serversIdx = i end
end
eq(serversIdx, 1, "first on the menu")
eq(hostIdx, serversIdx + 1, "directly above HOST GAME")

ctx.client = fakeClient(true, false)
eq(hasLabel(mainLabels(), "SERVERS"), false,
   "hosting hides the row even with a non-empty list")

ctx.client = fakeClient(false, true)
eq(hasLabel(mainLabels(), "SERVERS"), false,
   "and so does already being connected")

ctx.client = fakeClient(false, false)

-- ------- SCREEN.SERVERS: the list itself

local serversDef = screenRegistry[Ui.SCREEN.SERVERS]
check(serversDef ~= nil, "SCREEN.SERVERS registers")

ctx.servers = storeWith({ "b-host", "a-host" })
ctx.servers:setFavorite(ctx.servers:list()[2].key, true) -- a-host
do
  local expected = ctx.servers:menuList()
  local menu = serversDef.new({})
  eq(#menu.items, #expected,
     "one row per menu server, including the synthetic first row")
  for i, entry in ipairs(expected) do
    eq(menu.items[i].label, entry.name,
       "row " .. i .. " carries the entry's name")
    eq(menu.items[i].value, entry.key, "and its key")
    -- The trailing space is load-bearing, not a typo: the mark is drawn hard
    -- against the right edge of the row, and the space is what holds it off
    -- the border.
    eq(menu.items[i].right, entry.fav and "▶ " or nil,
       "favourites are marked with ▶ -- never *, which this font cannot draw")
  end
end

ctx.servers = storeWith({})
do
  local menu = serversDef.new({})
  eq(#menu.items, 1,
     "zero recents still leaves one real, selectable featured row")
  eq(menu.items[1].label, Config.FEATURED_SERVER_NAME,
     "the featured row is first under its official name")
  eq(menu.items[1].value, Config.FEATURED_SERVER_HOST:lower(),
     "and selects the key for the official address")
end

-- ------- SCREEN.SERVERACT: the fixed row order, and the gone-entry case

local actDef = screenRegistry[Ui.SCREEN.SERVERACT]
check(actDef ~= nil, "SCREEN.SERVERACT registers")

do
  ctx.servers = storeWith({})
  local featured = ctx.servers:menuList()[1]
  local game = {}
  local menu = actDef.new(game, { key = featured.key })
  eq(#menu.items, 1,
     "the featured server action screen contains only CONNECT")
  eq(menu.items[1].label, "CONNECT", "and CONNECT is that sole action")

  local calls = {}
  local realClient = ctx.client
  ctx.client = {
    isHosting = function() return false end,
    isConnected = function() return false end,
    setJoinAddress = function(_, address)
      calls[#calls + 1] = { name = "address", value = address }
      return address
    end,
    setJoinCode = function(_, address, code)
      calls[#calls + 1] = { name = "code", address = address, value = code }
      return code
    end,
    connect = function(_, game)
      calls[#calls + 1] = { name = "connect", game = game }
      return true
    end,
  }

  pushes = {}
  menu.items[1].onSelect()
  local setup = pushes[#pushes]
  check(setup ~= nil and setup.id == Ui.SCREEN.CHARSET,
        "featured CONNECT enters the regular character setup path")
  eq(setup.opts and setup.opts.verb, "JOIN",
     "using the same JOIN setup as a remembered server")
  check(type(setup.opts and setup.opts.onReady) == "function",
        "and waits for character setup before dialing")
  setup.opts.onReady()

  eq(calls[1] and calls[1].name, "address",
     "the regular dial path sets the address first")
  eq(calls[1] and calls[1].value, "play.rbymmo.com:7788",
     "to the official host")
  eq(calls[2] and calls[2].name, "code",
     "then stores the featured join code")
  eq(calls[2] and calls[2].address, "play.rbymmo.com:7788",
     "under the address connect will dial")
  eq(calls[2] and calls[2].value, "QG0251",
     "with the official code")
  eq(calls[3] and calls[3].name, "connect",
     "and finally uses the existing connect call")
  eq(calls[3] and calls[3].game, game,
     "for the game that opened the action screen")

  ctx.client = realClient
  pushes = {}
end

ctx.servers = storeWith({ "act.example" })
local actKey = ctx.servers:list()[1].key
do
  local menu = actDef.new({}, { key = actKey })
  local order = {}
  for i, item in ipairs(menu.items) do order[i] = item.label end
  local expectedOrder = { "CONNECT", "FAVORITE", "EDIT HOST", "EDIT CODE",
                           "RENAME", "DELETE" }
  eq(#order, #expectedOrder, "the six rows the plan names, DELETE last")
  for i, label in ipairs(expectedOrder) do
    eq(order[i], label, "row " .. i .. " is " .. label)
  end
  -- Menu grows the box downwards to fit its rows (th = rows * 2 + 2), so ty
  -- is what keeps the last row on an 18-tile screen -- pinned here so a
  -- seventh row added later trips this instead of only failing on-screen.
  eq(menu.opts and menu.opts.ty, 18 - (#expectedOrder * 2 + 2),
     "ty is recalculated for six rows, not left at the five-row value")

  ctx.servers:setFavorite(actKey, true)
  local refreshed = actDef.new({}, { key = actKey })
  eq(refreshed.items[2].label, "UNFAVORITE",
     "the second row flips once the entry is a favourite")

  local gone = actDef.new({}, { key = "no-such-key:1234" })
  check(gone.items == nil,
        "a missing entry is the TextBox path, not a Menu -- no .items")
  check(type(gone.text) == "string" and gone.text:find("gone", 1, true) ~= nil,
        "and it says the server is gone")
end

-- ------- SCREEN.SERVERACT: where the cursor lands on a reopen
--
-- Toggling the favourite mark rebuilds this menu, because Menu pops itself
-- before running a row -- so the rebuild has to be told where the cursor was
-- or it parks on CONNECT, and a second press on the row just pressed would
-- dial a hub nobody asked for.

do
  eq(actDef.new({}, { key = actKey }).index, 1,
     "with no row asked for, the cursor starts on CONNECT")
  eq(actDef.new({}, { key = actKey, row = 3 }).index, 3,
     "opts.row is where a reopen puts it")

  -- Clamped rather than trusted: an opts table is anybody's to hand in, and a
  -- Menu with its index off the end draws no arrow at all.
  local rows = #actDef.new({}, { key = actKey }).items
  eq(actDef.new({}, { key = actKey, row = 999 }).index, rows,
     "a row past the end is clamped to the last one")
  eq(actDef.new({}, { key = actKey, row = 0 }).index, 1,
     "and a row before the first is clamped up to it")
  eq(actDef.new({}, { key = actKey, row = "not a number" }).index, 1,
     "so is something that is not a row number at all")

  -- The favourite row's own reopen: it comes back to itself, not to CONNECT.
  -- A second press there is far likelier to be "no, put it back" than a
  -- request to dial.
  pushes = {}
  local menu = actDef.new({}, { key = actKey })
  menu.items[2].onSelect()
  local last = pushes[#pushes]
  check(last ~= nil, "toggling the favourite reopens the menu")
  eq(last.id, Ui.SCREEN.SERVERACT, "on SERVERACT itself")
  eq(last.opts and last.opts.key, actKey, "for the same entry")
  eq(last.opts and last.opts.row, 2,
     "with the cursor back on the row that was just pressed, not on CONNECT")
  pushes = {}
end

-- ------- SCREEN.SERVERACT: DELETE, behind a yes/no CONFIRM

do
  ctx.servers = storeWith({ "delete.example:7777" })
  local delKey = ctx.servers:list()[1].key
  local delEntry = ctx.servers:get(delKey)

  pushes = {}
  local menu = actDef.new({}, { key = delKey })
  menu.items[6].onSelect()

  local confirmPush = pushes[#pushes]
  check(confirmPush ~= nil and confirmPush.id == Ui.SCREEN.CONFIRM,
        "DELETE asks first, through the same yes/no box every other "
        .. "destructive row uses")
  check(confirmPush.opts and confirmPush.opts.text
        and confirmPush.opts.text:find(delEntry.name, 1, true) ~= nil,
        "and the question names the entry, so a mis-press is caught before "
        .. "it costs anything")
  check(type(confirmPush.opts and confirmPush.opts.onChoose) == "function",
        "the box is answered through onChoose, not by pressing through it")
  eq(confirmPush.opts and confirmPush.opts.defaultNo, true,
     "and it opens on NO -- the one confirm in this mod that does, so "
     .. "neither a stray A nor a stray B deletes anything")

  -- "no": back to this menu, cursor still on DELETE -- the same landing
  -- spot the favourite row's reopen uses, and for the same reason: a
  -- mis-press answered "no" should not leave a second delete one press away.
  pushes = {}
  confirmPush.opts.onChoose(false)
  local declined = pushes[#pushes]
  check(declined ~= nil and declined.id == Ui.SCREEN.SERVERACT,
        "declining reopens SERVERACT, not the list")
  eq(declined.opts and declined.opts.key, delKey, "for the same entry")
  eq(declined.opts and declined.opts.row, 6, "cursor still on DELETE")
  check(ctx.servers:get(delKey) ~= nil, "and nothing was actually deleted")

  -- "yes": the row is really gone, and the list is where it lands.
  pushes = {}
  confirmPush.opts.onChoose(true)
  local accepted = pushes[#pushes]
  check(accepted ~= nil and accepted.id == Ui.SCREEN.SERVERS,
        "accepting lands on the list, not back on the entry that no longer "
        .. "exists")
  check(ctx.servers:get(delKey) == nil, "the entry is gone from the store")
  eq(#ctx.servers:list(), 0, "and so is the row it was the only one of")
  pushes = {}
end

-- ------- SCREEN.SERVERACT: DELETE's yes-path also asks the client to
-- forget the hub's stored join code (see Client.forgetHub)

do
  ctx.servers = storeWith({ "clears.example:7777" })
  local clearKey = ctx.servers:list()[1].key
  local clearEntry = ctx.servers:get(clearKey)

  local forgotten = {}
  local realClient = ctx.client
  ctx.client = {
    isHosting = function() return false end,
    isConnected = function() return false end,
    forgetHub = function(_, address) forgotten[#forgotten + 1] = address end,
  }

  pushes = {}
  local menu = actDef.new({}, { key = clearKey })
  menu.items[6].onSelect()
  local confirmPush = pushes[#pushes]
  pushes = {}
  confirmPush.opts.onChoose(true)

  eq(#forgotten, 1,
     "a successful delete calls client:forgetHub exactly once")
  eq(forgotten[1], clearEntry.address,
     "with the address the row was for, not the store key")
  local landed = pushes[#pushes]
  check(landed ~= nil and landed.id == Ui.SCREEN.SERVERS,
        "and still lands on the list")

  ctx.client = realClient
  pushes = {}
end

-- ------- SCREEN.SERVERACT: DELETE survives a client with no forgetHub
--
-- The older-build shape: deletion has already succeeded by the time
-- forgetHub would be reached, so the row is gone either way -- this only
-- warns instead of clearing the code, and must not throw.

do
  ctx.servers = storeWith({ "noforget.example:7777" })
  local noForgetKey = ctx.servers:list()[1].key

  local realClient = ctx.client
  ctx.client = { isHosting = function() return false end,
                 isConnected = function() return false end }
  -- no .forgetHub field at all

  local warns = {}
  stubMod.log.warn = function(_, fmt, ...)
    local ok, line = pcall(string.format, fmt, ...)
    warns[#warns + 1] = ok and line or tostring(fmt)
  end

  pushes = {}
  local menu = actDef.new({}, { key = noForgetKey })
  menu.items[6].onSelect()
  local confirmPush = pushes[#pushes]
  pushes = {}
  local ok = pcall(confirmPush.opts.onChoose, true)

  check(ok, "a client with no forgetHub does not throw the delete")
  check(#warns > 0, "and it is logged instead")
  local landed = pushes[#pushes]
  check(landed ~= nil and landed.id == Ui.SCREEN.SERVERS,
        "deletion already succeeded, so the list is still where it lands")
  check(ctx.servers:get(noForgetKey) == nil, "and the entry really is gone")

  ctx.client = realClient
  stubMod.log.warn = function() end
  pushes = {}
end

-- ------- SCREEN.SERVERACT: DELETE against a store with no remove method
--
-- Not the same failure as remove refusing a key -- the row is still on the
-- list and still works, so "That server is gone." would be a lie. This
-- reopens SERVERACT instead of the gone TextBox.

do
  local fakeEntry = { key = "immutable:1", name = "immutable:1",
                       address = "immutable.example:7777", fav = false }
  local fakeStore = {
    get = function(_, key)
      if key ~= fakeEntry.key then return nil end
      return fakeEntry
    end,
    -- deliberately no .remove
  }
  local realServers = ctx.servers
  ctx.servers = fakeStore

  pushes = {}
  local menu = actDef.new({}, { key = fakeEntry.key })
  menu.items[6].onSelect()
  local confirmPush = pushes[#pushes]
  pushes = {}
  confirmPush.opts.onChoose(true)

  local reopened = pushes[#pushes]
  check(reopened ~= nil and reopened.id == Ui.SCREEN.SERVERACT,
        "a store with no remove reopens SERVERACT, not the gone TextBox")
  eq(reopened.opts and reopened.opts.key, fakeEntry.key, "for the same entry")
  eq(reopened.opts and reopened.opts.row, 6, "cursor still on DELETE")

  ctx.servers = realServers
  pushes = {}
end

-- ------- SCREEN.SERVERACT: DELETE answered on an entry that vanished first

do
  ctx.servers = storeWith({ "vanish.example:8888" })
  local vanishKey = ctx.servers:list()[1].key

  pushes = {}
  local menu = actDef.new({}, { key = vanishKey })
  menu.items[6].onSelect()
  local confirmPush = pushes[#pushes]
  check(confirmPush ~= nil, "DELETE still asks first")

  -- The entry is removed out from under the question -- evicted, or
  -- re-keyed by EDIT HOST elsewhere -- between the ask and the answer.
  ctx.servers:remove(vanishKey)

  pushes = {}
  confirmPush.opts.onChoose(true)
  local textPush = pushes[#pushes]
  check(textPush ~= nil and textPush.id == Ui.SCREEN.TEXT,
        "a yes on a row that is already gone is a TextBox, not a crash")
  check(textPush.opts and textPush.opts.text
        and textPush.opts.text:find("gone", 1, true) ~= nil,
        "and it says so, the same sentence a stale key gets on open")
  check(type(textPush.opts and textPush.opts.onDone) == "function",
        "pressed through, rather than left standing")

  pushes = {}
  textPush.opts.onDone()
  local afterDone = pushes[#pushes]
  check(afterDone ~= nil and afterDone.id == Ui.SCREEN.SERVERS,
        "and pressing through it lands on the list, same as the direct "
        .. "yes path")
  pushes = {}
end

-- ------- M:confirm with no opts at all leaves defaultNo nil
--
-- DELETE is the one confirm in this mod that opens on NO (pinned above),
-- reached through a fourth opts argument. Every other caller -- and this
-- mod has no other self:confirm site today -- hands in three arguments and
-- must keep the vanilla YES-first box, so `opts and opts.defaultNo` has to
-- stay nil rather than being coerced to false.

do
  pushes = {}
  ui:confirm({}, "Some question?", function() end)
  local plain = pushes[#pushes]
  check(plain ~= nil and plain.id == Ui.SCREEN.CONFIRM,
        "confirm with no opts still pushes CONFIRM")
  eq(plain.opts and plain.opts.defaultNo, nil,
     "and defaultNo is nil, not false -- CONFIRM's own registration is what "
     .. "normalises it to a boolean")
  pushes = {}
end

-- ------- SCREEN.SERVEREDIT: opts.field, and the unknown-field case

local editDef = screenRegistry[Ui.SCREEN.SERVEREDIT]
check(editDef ~= nil, "SCREEN.SERVEREDIT registers")

ctx.servers = storeWith({ "edit.example:1234" })
local editKey = ctx.servers:list()[1].key
do
  local hostScreen = editDef.new({}, { key = editKey, field = "host" })
  eq(hostScreen.title, "EDIT HOST", "the host grid carries its own title")
  eq(table.concat(hostScreen.glyphs), "edit.example:1234",
     "seeded with the entry's current address")

  local typedScreen = editDef.new({}, { key = editKey, field = "name",
                                        typed = "Retry" })
  eq(table.concat(typedScreen.glyphs), "Retry",
     "a refused attempt coming back through `typed` wins over the stored value")

  -- An unknown field is a TextBox too, but not the *same* TextBox: nothing
  -- has happened to the server, so saying it is gone would be a lie about the
  -- entry rather than a complaint about the caller. B lands on the entry's own
  -- menu, which is where the three fields that do exist are.
  local unknown = editDef.new({}, { key = editKey, field = "not-a-real-field" })
  check(unknown.items == nil and unknown.glyphs == nil,
        "an unknown field is a TextBox, not a naming grid")
  eq(unknown.text, "There is nothing\nto edit there.",
     "and it complains about the field, never about the server")
  check(unknown.text:find("gone", 1, true) == nil,
        "the entry is still there, so it is not the gone sentence")
  pushes = {}
  unknown.onDone()
  eq(pushes[1] and pushes[1].id, Ui.SCREEN.SERVERACT,
     "pressing through it lands on the entry's own menu")
  eq(pushes[1] and pushes[1].opts and pushes[1].opts.key, editKey,
     "for the entry that was being edited")
  pushes = {}

  local goneKey = editDef.new({}, { key = "missing:1", field = "host" })
  check(goneKey.items == nil and goneKey.glyphs == nil,
        "a missing key is refused the same way, whatever field was asked for")
end

-- ------- SCREEN.SERVEREDIT: a refusal says how much was typed, never what
--
-- A refused join code is a near-miss of a real one, which is the worst kind
-- to write into a log file somebody will paste into a bug report. The count
-- is what makes "too short" diagnosable without printing the characters.

do
  local warns = {}
  stubMod.log.warn = function(_, fmt, ...)
    local ok, line = pcall(string.format, fmt, ...)
    warns[#warns + 1] = ok and line or tostring(fmt)
  end

  local TYPED = "SECRETX9" -- every character is in the code alphabet; eight
                           -- of them are not six, so the store refuses it
  local codeScreen = editDef.new({}, { key = editKey, field = "code" })
  check(type(codeScreen.glyphs) == "table", "EDIT CODE is a naming grid")
  for i = 1, #TYPED do codeScreen.glyphs[i] = TYPED:sub(i, i) end
  pushes = {}
  codeScreen:confirm()

  check(#warns > 0, "a refused code is logged")
  local joined = table.concat(warns, "\n")
  eq(joined:find(TYPED, 1, true), nil,
     "and what was typed is nowhere in what was logged")
  eq(joined:find(TYPED:sub(1, Config.CODE_LEN), 1, true), nil,
     "not even the first six characters of it, which would be the code")
  check(joined:find("%(%d+ character%(s%)%)") ~= nil,
        "the length is what stands in for it")
  check(joined:find(("(%d character(s))"):format(#TYPED), 1, true) ~= nil,
        "and it is the length actually typed")
  check(joined:find("code", 1, true) ~= nil, "naming the field that refused")

  eq(ctx.servers:get(editKey).code, nil,
     "the row keeps the code it had -- a refusal never writes one")

  local last = pushes[#pushes]
  check(last ~= nil and last.id == Ui.SCREEN.TEXT,
        "the player is told in a box, not only in the log")
  pushes = {}
  stubMod.log.warn = function() end
end

stubMod.content.screens, stubMod.hooks, stubMod.ui = nil, nil, nil
_G.love = ambientLove

end)()

-- ------------------------------------------------------------------
-- 17. The offline character row, and the picker's two doors
-- ------------------------------------------------------------------
--
-- SCREEN.MAIN's CHARACTER row and SCREEN.CHARPICK's backTo opt are pinned
-- against a fake client and a stubbed mod.ui rather than the real widgets:
-- what is under test is Ui.lua's own branching -- which rows exist, and
-- where a choice sends the player back to -- not Menu/ListMenu's layout,
-- which needs a graphics context this suite does not have.

;(function()

local Ui = need("Ui")
local SCREEN = Ui.SCREEN

-- what SCREEN.MAIN and SCREEN.CHARPICK actually read off the client
local function fakeClient(state)
  state = state or {}
  return {
    isHosting = function() return state.hosting == true end,
    isConnected = function() return state.connected == true end,
    spriteChoice = function() return state.choice or "SPRITE_ALPHA" end,
    setSpriteChoice = function(_, id) state.choice = id return id end,
  }
end

local pushed
local screensStore = {}
stubMod.ui = {
  push = function(game, id, opts) pushed = { id = id, opts = opts } end,
  Menu = { new = function(game, items, opts)
    return { items = items, opts = opts, clampScroll = function() end }
  end },
  ListMenu = { new = function(game, title, items, opts)
    return { title = title, items = items, opts = opts, index = 1,
             scroll = 0, close = function() end }
  end },
}
stubMod.hooks = { wrap = function() end }
stubMod.content.screens = {
  register = function(_, id, record) screensStore[id] = record end,
  get = function(_, id) return screensStore[id] end,
}

local ctx = { client = fakeClient(), chat = { unread = 0 } }
local ui = Ui.new(ctx)
ui:install()

-- ------- the row itself

local function mainItems()
  return screensStore[SCREEN.MAIN].new({}).items
end

do
  local items = mainItems()
  eq(#items, 4,
     "offline, the menu is SERVERS / HOST GAME / JOIN GAME / CHARACTER")
  eq(items[1].label, "SERVERS", "the always-available server list is first")
  eq(items[2].label, "HOST GAME", "HOST GAME is second")
  eq(items[3].label, "JOIN GAME", "JOIN GAME is third")
  eq(items[4].label, "CHARACTER", "and CHARACTER is fourth")

  pushed = nil
  items[4].onSelect()
  eq(pushed and pushed.id, SCREEN.CHARPICK, "CHARACTER opens the picker")
  eq(pushed and pushed.opts and pushed.opts.backTo, SCREEN.MAIN,
     "and tells it to come straight back to the MMO menu, not the "
     .. "host/join setup flow")
end

ctx.client = fakeClient({ connected = true })
do
  local items = mainItems()
  eq(#items, 9, "connected as a guest: 9 rows now that FRIENDS rides along")
  local labels = {}
  for _, item in ipairs(items) do labels[#labels + 1] = item.label end
  eq(table.concat(labels, "|"),
     "PLAYERS|FRIENDS|CHAT|SAY|PARTY|MY PROFILE|RANK|CHARACTER|LEAVE",
     "FRIENDS sits directly under PLAYERS -- the same question with the half "
     .. "of the answer a roster structurally cannot give -- and CHARACTER is "
     .. "still after RANK and before LEAVE")

  local friendRow
  for _, item in ipairs(items) do
    if item.label == "FRIENDS" then friendRow = item end
  end
  pushed = nil
  friendRow.onSelect()
  eq(pushed and pushed.id, SCREEN.FRIENDS, "FRIENDS opens the friends list")

  local charRow
  for _, item in ipairs(items) do
    if item.label == "CHARACTER" then charRow = item end
  end
  pushed = nil
  charRow.onSelect()
  eq(pushed and pushed.id, SCREEN.CHARPICK,
     "connected, CHARACTER opens the picker too")
  eq(pushed and pushed.opts and pushed.opts.backTo, SCREEN.MAIN,
     "and comes straight back to the MMO menu, not the host/join setup flow")
end

ctx.client = fakeClient({ hosting = true })
do
  local items = mainItems()
  eq(#items, 2,
     "hosting but not connected: still just ADDRESS and END GAME -- a "
     .. "listener with nobody on it to show a new face to gets no CHARACTER "
     .. "row")
  eq(items[1].label, "ADDRESS", "first")
  eq(items[2].label, "END GAME", "and second")
end

ctx.client = fakeClient({ hosting = true, connected = true })
do
  local items = mainItems()
  eq(#items, 10,
     "hosting and connected to your own hub: 10 rows, two past the eight "
     .. "this screen shows at once")
  local labels = {}
  for _, item in ipairs(items) do labels[#labels + 1] = item.label end
  eq(table.concat(labels, "|"),
     "ADDRESS|PLAYERS|FRIENDS|CHAT|SAY|PARTY|MY PROFILE|RANK|CHARACTER|END GAME",
     "ADDRESS leads, FRIENDS follows PLAYERS, CHARACTER still after RANK, "
     .. "END GAME last")
end

ctx.client = fakeClient()

-- ------- CHARPICK's two doors

stubSprites = {}
stubSprites.SPRITE_ALPHA = { walker = true }
stubSprites.SPRITE_MIDDLE_AGED_WOMAN = { walker = true }

do
  local menu = screensStore[SCREEN.CHARPICK].new({}, { backTo = SCREEN.MAIN })
  local labels, values = {}, {}
  for _, item in ipairs(menu.items) do
    labels[#labels + 1] = item.label
    values[#values + 1] = item.value
  end
  check(table.concat(labels, "|"):find("  MIDDLE AGED WOMA", 1, true) ~= nil,
        "the label is indented past the gutter and trimmed to 16 glyphs, "
        .. "dropping the trailing N")
  check(table.concat(values, "|"):find("SPRITE_MIDDLE_AGED_WOMAN", 1, true)
        ~= nil,
        "but item.value stays the bare id, which is what the choice reads")

  pushed = nil
  menu.opts.onChoose(menu.items[1], menu)
  eq(pushed.id, SCREEN.MAIN, "choosing with a backTo opt returns straight to it")
  eq(next(pushed.opts), nil, "with no leftover setup opts to carry back")

  pushed = nil
  menu.opts.onCancel()
  eq(pushed.id, SCREEN.MAIN, "and cancelling goes the same way")
end

do
  -- no backTo: the older door, still open for the TRAINER flow
  local setupOpts = { verb = "HOST" }
  local menu = screensStore[SCREEN.CHARPICK].new({}, { back = setupOpts })

  pushed = nil
  menu.opts.onChoose(menu.items[1], menu)
  eq(pushed.id, SCREEN.CHARSET,
     "with no backTo, choosing still goes back to the setup flow")
  check(pushed.opts == setupOpts,
        "carrying the exact setup opts it arrived with")

  pushed = nil
  menu.opts.onCancel()
  eq(pushed.id, SCREEN.CHARSET, "cancelling keeps the same door")
end

stubSprites = {}
stubMod.ui = nil
stubMod.hooks = nil
stubMod.content.screens = nil

end)()

T.finish("rby_mmo")
