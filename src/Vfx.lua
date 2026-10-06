-- The battle's particle vocabulary.
--
-- Every move a monster can use, every item a bag can open in a fight, every
-- status that lands and every stat stage that moves resolves *here* to one
-- small record -- a style, a palette, a delivery and how hard it hits -- and
-- src/Battlefield.lua draws that record. Nothing in this file draws anything,
-- requires anything, or reads a clock: a look is a value, and a particle is a
-- pure function of (which particle, how far through, which emission).
--
-- **Why the split.** Battlefield owns the canvas and is already the largest
-- file in the mod; the catalogue is the half that has to be readable by
-- somebody adding a move, and the particle math is the half the suite has to
-- be able to assert with no LOVE, no engine and no mod facade in the process.
-- Both of those want to be here rather than three hundred lines inside a
-- renderer.
--
-- **Every move resolves.** `M.forMove` never returns nil: an id the engine
-- does not know, a move with no type, a Gen 2 type this file has never heard
-- of -- each of them lands on a defensible fallback rather than a frame with
-- nothing on it. That is the whole contract this module exists to keep, and
-- the reason resolution is a chain of three narrowing questions (an explicit
-- override, then the move's shape, then its type) instead of one table.
--
-- **Determinism.** A particle's position is `f(i, t, seed)` with a hash for
-- the randomness, never `math.random`. Two clients watching the same fight
-- see the same sparks, a headless suite can assert a frame, and re-running an
-- effect never reshuffles it half way through. `rand01` is two rounds of
-- MINSTD over small integers, which stays exact in a double on every
-- interpreter this mod runs under (LuaJIT, 5.1, 5.4).
--
-- No love, no engine modules, no mod facade.

local need = ...            -- entry-chunk shape; this module resolves nothing

local M = {}

local sin, cos, pi = math.sin, math.cos, math.pi
local abs, floor, max, min = math.abs, math.floor, math.max, math.min

local function num(v, fallback)
  local n = tonumber(v)
  if not n or n ~= n then return fallback end
  return n
end

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

-- ------------------------------------------------------------------
-- deterministic randomness
-- ------------------------------------------------------------------
--
-- Three small integers in, a 0..1 float out, and the same three always give
-- the same float. The inputs are reduced mod 1024 first so every product below
-- stays under 2^53 and is therefore exact in a double -- an overflow here
-- would show up as particles that drift apart between two players' screens,
-- which is the one thing a shared fight must not do.

local MINSTD = 48271
local MODULUS = 2147483647

function M.rand01(a, b, salt)
  local h = (floor(num(a, 0)) % 1024) * 1664525
    + (floor(num(b, 0)) % 1024) * 1013904223
    + (floor(num(salt, 0)) % 1024) * 22695477
  h = h % MODULUS
  h = (h * MINSTD) % MODULUS
  h = (h * MINSTD) % MODULUS
  return h / MODULUS
end

local rand01 = M.rand01

-- ------------------------------------------------------------------
-- palettes
-- ------------------------------------------------------------------
--
-- Three colours per palette and always in the same order -- core, mid, edge --
-- so a particle picks a tint by index and every style reads the same way
-- against every type. Core is the hot centre (near-white for most types), mid
-- is the colour a player names the type by, edge is the shadow that keeps the
-- lighter two legible over a bright arena.
--
-- Original colours, chosen against this mod's own grass arena. Nothing here is
-- sampled from a ROM.

local function palette(core, mid, edge)
  return { core, mid, edge }
end

M.PALETTES = {
  NORMAL   = palette({ 1, 1, 1 },             { 0.95, 0.93, 0.86 }, { 0.72, 0.69, 0.62 }),
  FIGHTING = palette({ 1, 0.93, 0.78 },       { 0.90, 0.44, 0.22 }, { 0.58, 0.21, 0.12 }),
  FLYING   = palette({ 1, 1, 1 },             { 0.72, 0.85, 0.99 }, { 0.48, 0.60, 0.82 }),
  POISON   = palette({ 0.94, 0.74, 1 },       { 0.68, 0.32, 0.82 }, { 0.38, 0.14, 0.52 }),
  GROUND   = palette({ 0.97, 0.88, 0.64 },    { 0.78, 0.60, 0.34 }, { 0.44, 0.32, 0.18 }),
  ROCK     = palette({ 0.90, 0.84, 0.72 },    { 0.66, 0.58, 0.44 }, { 0.36, 0.31, 0.23 }),
  BUG      = palette({ 0.90, 0.97, 0.62 },    { 0.60, 0.77, 0.24 }, { 0.32, 0.44, 0.12 }),
  GHOST    = palette({ 0.82, 0.74, 1 },       { 0.46, 0.36, 0.74 }, { 0.19, 0.14, 0.36 }),
  STEEL    = palette({ 1, 1, 1 },             { 0.77, 0.81, 0.88 }, { 0.45, 0.50, 0.58 }),
  FIRE     = palette({ 1, 0.96, 0.72 },       { 1, 0.57, 0.15 },    { 0.76, 0.18, 0.06 }),
  WATER    = palette({ 0.87, 0.97, 1 },       { 0.29, 0.62, 0.96 }, { 0.10, 0.29, 0.64 }),
  GRASS    = palette({ 0.82, 1, 0.68 },       { 0.35, 0.79, 0.34 }, { 0.13, 0.42, 0.18 }),
  ELECTRIC = palette({ 1, 1, 0.82 },          { 1, 0.86, 0.20 },    { 0.82, 0.56, 0.04 }),
  PSYCHIC  = palette({ 1, 0.87, 0.96 },       { 0.96, 0.34, 0.63 }, { 0.58, 0.12, 0.39 }),
  ICE      = palette({ 0.93, 1, 1 },          { 0.55, 0.89, 0.97 }, { 0.20, 0.54, 0.72 }),
  DRAGON   = palette({ 0.88, 0.84, 1 },       { 0.43, 0.40, 0.87 }, { 0.19, 0.17, 0.50 }),
  DARK     = palette({ 0.74, 0.68, 0.76 },    { 0.34, 0.28, 0.37 }, { 0.11, 0.09, 0.14 }),
  FAIRY    = palette({ 1, 0.91, 0.98 },       { 0.96, 0.55, 0.81 }, { 0.68, 0.25, 0.53 }),

  -- Not types. The bag, the stat board and the status line borrow these so a
  -- potion never wears a monster's colours.
  HEAL     = palette({ 0.94, 1, 0.92 },       { 0.38, 0.93, 0.53 }, { 0.11, 0.56, 0.28 }),
  CURE     = palette({ 1, 1, 0.95 },          { 0.70, 0.93, 1 },    { 0.30, 0.58, 0.84 }),
  BUFF     = palette({ 1, 0.98, 0.82 },       { 1, 0.76, 0.27 },    { 0.76, 0.45, 0.08 }),
  DEBUFF   = palette({ 0.88, 0.84, 0.95 },    { 0.55, 0.48, 0.73 }, { 0.27, 0.22, 0.41 }),
  REVIVE   = palette({ 1, 1, 0.90 },          { 1, 0.90, 0.42 },    { 0.85, 0.62, 0.12 }),
  ESCAPE   = palette({ 1, 1, 1 },             { 0.86, 0.86, 0.90 }, { 0.55, 0.55, 0.62 }),
}

M.DEFAULT_PALETTE = "NORMAL"

-- The palette a name resolves to, always something drawable.
function M.palette(name)
  if type(name) == "string" then
    local hit = M.PALETTES[name]
    if hit then return hit end
    local upper = M.PALETTES[name:upper()]
    if upper then return upper end
  end
  return M.PALETTES[M.DEFAULT_PALETTE]
end

-- ------------------------------------------------------------------
-- styles
-- ------------------------------------------------------------------
--
-- A style is *how* an effect moves and what it is made of; the palette says
-- what colour it is. The two are independent on purpose -- Poison's rising
-- bubbles are the right shape for a Poison-type status move and for a poison
-- condition ticking, and a mod that adds a nineteenth type gets a look for
-- free by naming a style and a palette rather than writing an emitter.
--
-- `shape` is the primitive src/Battlefield.lua draws for one particle:
--
--   dot     a filled circle
--   puff    a soft circle with a lighter core (smoke, wisp)
--   flame   a teardrop, pointed up (fire)
--   streak  a line pointing away from the anchor (impact spray)
--   bolt    a jagged five-segment line from the anchor (electricity)
--   shard   a narrow diamond, rotated (ice, crystal)
--   leaf    an ovate leaf, pointed tip and a stem, rotated (foliage)
--   chunk   a rough pentagon, rotated (rock, dirt)
--   arc     a crescent stroke (wind)
--   ring    a circle outline (bubbles)
--   star    a four-point twinkle (metal, fairy, healing)
--   arrow   a solid triangle plus a stem (stat stages)
--   note    a filled head with a stem (song, flute)
--
-- `ring` is a style-level flourish drawn once at the anchor rather than per
-- particle: "shock" is a hard fast expanding outline, "wave" a slower ground
-- ripple, "pulse" two soft concentric rings. `glow` is the additive core
-- flash at t == 0, as an alpha.
--
-- `size` is one particle's radius in px at scale 1, sized against the 60px
-- monsters this arena draws (M.MON_DRAW).

M.STYLES = {
  impact  = { count = 12, shape = "streak", size = 4.0, ring = "shock", glow = 0.55 },
  ember   = { count = 16, shape = "flame",  size = 5.4, glow = 0.50 },
  splash  = { count = 14, shape = "dot",    size = 3.4, ring = "wave",  glow = 0.35 },
  leaf    = { count = 14, shape = "leaf",   size = 6.4, glow = 0.25 },
  spark   = { count = 15, shape = "bolt",   size = 5.4, ring = "shock", glow = 0.60 },
  shard   = { count = 12, shape = "shard",  size = 4.6, glow = 0.40 },
  psi     = { count = 14, shape = "dot",    size = 3.2, ring = "pulse", glow = 0.45 },
  rock    = { count = 11, shape = "chunk",  size = 4.4, glow = 0.20 },
  quake   = { count = 14, shape = "chunk",  size = 3.8, ring = "wave",  glow = 0.20 },
  gust    = { count = 10, shape = "arc",    size = 5.0, glow = 0.25 },
  bubble  = { count = 14, shape = "ring",   size = 4.0, glow = 0.30 },
  swarm   = { count = 16, shape = "dot",    size = 2.6, glow = 0.20 },
  spirit  = { count = 11, shape = "puff",   size = 5.0, glow = 0.35 },
  shine   = { count = 9,  shape = "star",   size = 4.8, glow = 0.50 },
  rage    = { count = 14, shape = "dot",    size = 3.6, glow = 0.45 },
  shadow  = { count = 13, shape = "puff",   size = 4.2, glow = 0.30 },
  sparkle = { count = 14, shape = "star",   size = 3.6, glow = 0.40 },
  heal    = { count = 14, shape = "star",   size = 3.2, ring = "pulse", glow = 0.35 },
  cure    = { count = 12, shape = "dot",    size = 3.0, ring = "pulse", glow = 0.30 },
  buff    = { count = 7,  shape = "arrow",  size = 5.0, glow = 0.30 },
  debuff  = { count = 7,  shape = "arrow",  size = 5.0, glow = 0.25 },
  blast   = { count = 20, shape = "puff",   size = 6.0, ring = "shock", glow = 0.80 },
  note    = { count = 8,  shape = "note",   size = 4.4, glow = 0.25 },
  puff    = { count = 14, shape = "puff",   size = 5.0, glow = 0.30 },
  revive  = { count = 14, shape = "star",   size = 3.4, ring = "pulse", glow = 0.55 },
}

M.DEFAULT_STYLE = "impact"

-- The styles that are *light* rather than matter. Drawn with an additive
-- blend, so overlapping particles brighten into a hot core instead of stacking
-- into an opaque blob -- which is what fire, electricity and a healing sparkle
-- do and what a rock or a leaf emphatically does not. Split as a set rather
-- than a field on each entry because it is a rendering decision, and the two
-- lists change for different reasons.
M.ADDITIVE = {
  ember = true, spark = true, shine = true, psi = true, sparkle = true,
  heal = true, cure = true, revive = true, blast = true, rage = true,
}

function M.additive(name)
  return type(name) == "string" and M.ADDITIVE[name] == true
end

function M.style(name)
  if type(name) == "string" then
    local hit = M.STYLES[name]
    if hit then return hit, name end
  end
  return M.STYLES[M.DEFAULT_STYLE], M.DEFAULT_STYLE
end

-- How many particles one emission spends. `intensity` is the spec's own
-- multiplier -- a status move that only nudges a stat is not the same event as
-- Explosion, and spending the same twenty particles on both flattens the
-- difference the player is meant to read.
function M.count(style, intensity)
  local def = M.style(style)
  local n = floor(def.count * clamp(num(intensity, 1), 0.15, 2.5) + 0.5)
  return max(1, min(48, n))
end

-- ------------------------------------------------------------------
-- the emitters
-- ------------------------------------------------------------------
--
-- One function per style. Signature is (i, n, t, r1, r2, r3) and the returns
-- are, in order:
--
--   x, y     the particle's offset from the anchor, in *unit* space -- 1.0 is
--            the effect's radius, +y is down (screen order, not maths order)
--   r        radius multiplier over the style's `size`
--   alpha    0..1; a caller skips anything at or below 0
--   tint     1 core / 2 mid / 3 edge, indexing the palette
--   angle    radians, for the shapes that rotate; 0 for the rest
--
-- r1..r3 are three fixed randoms for this particle, drawn once by M.particle
-- from (seed, i) so a given spark keeps its personality for the whole effect.
-- Nothing here allocates: an emission of twenty particles costs twenty calls
-- and no tables, which is what lets an effect run inside a draw loop.

local EMIT = {}

-- Radial spray, fast out and decelerating: the shape of a blow landing.
EMIT.impact = function(i, n, t, r1, r2, r3)
  local ang = (i / n) * pi * 2 + r1 * 0.9
  local u = 1 - (1 - t) * (1 - t)
  local reach = (0.45 + r2 * 0.75) * u
  return cos(ang) * reach, sin(ang) * reach,
    (0.5 + r3 * 0.6) * (1 - t * 0.7), (1 - t) * (1 - t * 0.2),
    (r1 < 0.35) and 1 or 2, ang
end

-- Flames: staggered births, a rising waver, and a cooling tint as they climb.
-- The angle is a small lean, not a spin -- a flame that tumbles reads as a
-- leaf, and a flame that sits dead upright in a row reads as a row of dots.
EMIT.ember = function(i, n, t, r1, r2, r3)
  local born = r1 * 0.35
  local u = (t - born) / (1 - born)
  if u <= 0 then return 0, 0, 0, 0, 1, 0 end
  local x = (r2 - 0.5) * 1.3 * (0.35 + u * 0.65) + sin(u * pi * 3 + r3 * 6.283) * 0.14
  local y = 0.5 - u * 1.5
  local tint = (u < 0.35) and 1 or ((u < 0.75) and 2 or 3)
  local lean = (r2 - 0.5) * 0.55 + sin(u * pi * 3 + r3 * 6.283) * 0.28
  return x, y, (0.45 + r3 * 0.75) * (1 - u * 0.8), 1 - u * u, tint, lean
end

-- Droplets thrown up and out, then pulled back down: gravity is the t^2 term.
EMIT.splash = function(i, n, t, r1, r2, r3)
  local side = ((i % 2) == 0) and 1 or -1
  local ang = pi * (0.20 + r1 * 0.30)
  local speed = 0.85 + r2 * 0.75
  local x = side * cos(ang) * speed * t
  local y = -sin(ang) * speed * t + 1.75 * t * t - 0.15
  return x, y, (0.4 + r3 * 0.5) * (1 - t * 0.35), 1 - t * t,
    (r3 < 0.4) and 1 or 2, 0
end

-- Foliage: drifts out, sways across its own path, and tumbles as it goes.
EMIT.leaf = function(i, n, t, r1, r2, r3)
  local ang = (i / n) * pi * 2 + r1
  local reach = (0.35 + r2 * 0.8) * t
  local x = cos(ang) * reach + sin(t * pi * 2 + r3 * 6.283) * 0.18
  local y = sin(ang) * reach * 0.7 - 0.25 * t + 0.55 * t * t
  local spin = r3 * 6.283 + t * pi * 3 * ((r1 < 0.5) and 1 or -1)
  return x, y, 0.6 + r3 * 0.5, 1 - t * t * t, (r2 < 0.45) and 1 or 2, spin
end

-- Electricity does not fade, it *flickers*: three discharges across the
-- effect, each particle belonging to exactly one of them.
EMIT.spark = function(i, n, t, r1, r2, r3)
  local band = i % 3
  local u = t * 3 - band
  if u < 0 or u > 1 then return 0, 0, 0, 0, 1, 0 end
  local ang = r1 * pi * 2
  local reach = 0.3 + r2 * 0.85
  return cos(ang) * reach, sin(ang) * reach,
    0.55 + r3 * 0.5, 1 - u, (u < 0.5) and 1 or 2, ang
end

-- Crystals: out fast, then held -- ice does not disperse, it hangs and melts.
EMIT.shard = function(i, n, t, r1, r2, r3)
  local ang = (i / n) * pi * 2 + r1 * 0.6
  local u = 1 - (1 - t) * (1 - t) * (1 - t)
  local reach = (0.4 + r2 * 0.6) * u
  return cos(ang) * reach, sin(ang) * reach,
    (0.6 + r3 * 0.6) * (0.4 + u * 0.6), 1 - t * t,
    (r3 < 0.5) and 1 or 2, ang + r3
end

-- Motes drawn inward along a spiral: the pull, not the blow.
EMIT.psi = function(i, n, t, r1, r2, r3)
  local ang = (i / n) * pi * 2 + t * pi * 2.2 + r1 * 0.5
  local reach = (1.05 - t * 0.85) * (0.55 + r2 * 0.5)
  local a = (t < 0.15) and (t / 0.15) or (1 - (t - 0.15) / 0.85)
  return cos(ang) * reach, sin(ang) * reach * 0.8,
    0.45 + r3 * 0.5, clamp(a, 0, 1), (r3 < 0.4) and 1 or 2, 0
end

-- Chunks with weight: flung out on a ballistic arc and tumbling as they fly.
EMIT.rock = function(i, n, t, r1, r2, r3)
  local side = ((i % 2) == 0) and 1 or -1
  local ang = pi * (0.15 + r1 * 0.4)
  local speed = 0.8 + r2 * 0.8
  local x = side * cos(ang) * speed * t
  local y = -sin(ang) * speed * t + 1.6 * t * t
  return x, y, 0.7 + r3 * 0.6, 1 - t * t, (r2 < 0.5) and 2 or 3,
    r3 * 6.283 + t * pi * 2.5 * side
end

-- Dirt off the ground line rather than out of the monster: the plume starts
-- at the seat's feet (+0.55 in unit space) and climbs.
EMIT.quake = function(i, n, t, r1, r2, r3)
  local x = (r1 - 0.5) * 1.7 * (0.6 + t * 0.8)
  local lift = (0.5 + r2 * 0.8) * (t * 1.8 - t * t * 1.1)
  return x, 0.55 - lift, 0.55 + r3 * 0.7, 1 - t * t,
    (r2 < 0.5) and 2 or 3, r3 * 6.283 + t * 4
end

-- Wind sweeps *across* a seat rather than bursting on it, so every particle
-- travels the same left-to-right lane at its own speed.
EMIT.gust = function(i, n, t, r1, r2, r3)
  local lane = ((i - 0.5) / n - 0.5) * 1.5
  local u = t * (0.8 + r1 * 0.5) + r2 * 0.3
  local a = min(1, u * 3) * (1 - max(0, (u - 0.6) / 0.4))
  return -1.2 + u * 2.6, lane + sin(u * pi * 2 + r3 * 6.283) * 0.18,
    0.6 + r3 * 0.5, clamp(a, 0, 1), (r3 < 0.4) and 1 or 2, 0
end

-- Bubbles rise, swell, and pop at the top rather than fading out.
EMIT.bubble = function(i, n, t, r1, r2, r3)
  local born = r1 * 0.4
  local u = (t - born) / (1 - born)
  if u <= 0 then return 0, 0, 0, 0, 1, 0 end
  local x = (r2 - 0.5) * 1.4 + sin(u * pi * 2.5 + r3 * 6.283) * 0.12
  local pop = (u > 0.8) and (1 - (u - 0.8) / 0.2) or 1
  return x, 0.5 - u * 1.35, (0.5 + r3 * 0.6) * (0.4 + u * 0.6),
    pop * (1 - u * 0.3), (r3 < 0.35) and 1 or 2, 0
end

-- A swarm does not expand; it circles. Two incommensurate frequencies keep
-- the dots from ever settling into a visible ring.
EMIT.swarm = function(i, n, t, r1, r2, r3)
  local ph = r1 * 6.283
  local sp = 2.2 + r2 * 2.0
  local rad = 0.35 + r3 * 0.7
  local a = min(1, t * 5) * min(1, (1 - t) * 4)
  return cos(t * sp * pi + ph) * rad, sin(t * sp * pi * 1.4 + ph * 1.7) * rad * 0.75,
    0.35 + r3 * 0.3, clamp(a, 0, 1), (r2 < 0.4) and 1 or 2, 0
end

-- Wisps: they grow as they rise and thin out rather than shrinking.
EMIT.spirit = function(i, n, t, r1, r2, r3)
  local born = r1 * 0.3
  local u = clamp((t - born) / (1 - born), 0, 1)
  local x = (r2 - 0.5) * 1.5 + sin(u * pi * 2 + r3 * 6.283) * 0.3
  return x, 0.4 - u * 1.2, (0.7 + r3 * 0.8) * (0.5 + u * 0.7),
    clamp(min(1, u * 4) * (1 - u) * 1.1, 0, 1), (r3 < 0.5) and 2 or 3, 0
end

-- Gleams that arrive one after another rather than all at once: metal
-- catching the light as something turns.
EMIT.shine = function(i, n, t, r1, r2, r3)
  local born = (i - 1) / n * 0.5
  local u = clamp((t - born) / 0.5, 0, 1)
  local ang = r1 * 6.283
  local reach = 0.25 + r2 * 0.8
  local pulse = sin(u * pi)
  return cos(ang) * reach, sin(ang) * reach * 0.8,
    (0.5 + r3 * 0.7) * pulse, pulse, (r3 < 0.6) and 1 or 2, ang * 0.5
end

-- Energy wound up into a rising helix.
EMIT.rage = function(i, n, t, r1, r2, r3)
  local u = clamp(t * 1.15 - r1 * 0.15, 0, 1)
  local ang = (i / n) * pi * 2 + u * pi * 3
  local rad = (0.85 - u * 0.45) * (0.6 + r2 * 0.6)
  return cos(ang) * rad, sin(ang) * rad * 0.55 + 0.45 - u * 1.1,
    0.5 + r3 * 0.5, sin(u * pi), (r3 < 0.4) and 1 or 2, 0
end

-- The only style that closes in: darkness gathers on the seat instead of
-- spraying off it.
EMIT.shadow = function(i, n, t, r1, r2, r3)
  local ang = (i / n) * pi * 2 + r1 * 0.8
  local rad = (1.15 - t) * (0.6 + r2 * 0.6)
  return cos(ang) * rad, sin(ang) * rad * 0.85,
    (0.55 + r3 * 0.6) * (0.5 + t * 0.5),
    clamp(min(1, t * 4) * (1 - t * t), 0, 1), (r3 < 0.3) and 2 or 3, 0
end

-- Twinkles: each one owns a short window and is simply absent outside it.
EMIT.sparkle = function(i, n, t, r1, r2, r3)
  local born = r1 * 0.6
  local u = clamp((t - born) / 0.4, 0, 1)
  local ang = r2 * 6.283
  local rad = 0.3 + r3 * 0.8
  local pulse = sin(u * pi)
  return cos(ang) * rad, sin(ang) * rad * 0.85 - t * 0.25,
    (0.4 + r3 * 0.6) * pulse, pulse, (r2 < 0.5) and 1 or 2, ang
end

-- Restoration reads as *upward*: sparks lift off the feet and thin out.
EMIT.heal = function(i, n, t, r1, r2, r3)
  local born = r1 * 0.45
  local u = clamp((t - born) / (1 - born), 0, 1)
  local x = (r2 - 0.5) * 1.5 + sin(u * pi * 2 + r3 * 6.283) * 0.1
  return x, 0.6 - u * 1.4, (0.4 + r3 * 0.5) * (1 - u * 0.4),
    sin(u * pi), (r3 < 0.5) and 1 or 2, r2 * 6.283
end

-- A cure is a wash rather than a burst: three rings of motes leaving together.
EMIT.cure = function(i, n, t, r1, r2, r3)
  local u = clamp(t * 1.2 - (i % 3) * 0.1, 0, 1)
  local ang = (i / n) * pi * 2
  local rad = 0.25 + u * 0.75
  return cos(ang) * rad, sin(ang) * rad * 0.7,
    0.45 + r3 * 0.4, sin(u * pi), (r1 < 0.5) and 1 or 2, 0
end

-- Stat stages are the one effect that has to be *read*, not just felt, so they
-- are arrows and they are staggered: a player counts them going up.
EMIT.buff = function(i, n, t, r1, r2, r3)
  local born = (i - 1) / n * 0.4
  local u = clamp((t - born) / (1 - born), 0, 1)
  return (r1 - 0.5) * 1.4, 0.7 - u * 1.5, 0.7 + r2 * 0.4,
    min(1, sin(u * pi) * 1.4), (r3 < 0.5) and 1 or 2, 0
end

-- ...and the same arrows falling, pointed the other way (angle == pi).
EMIT.debuff = function(i, n, t, r1, r2, r3)
  local born = (i - 1) / n * 0.4
  local u = clamp((t - born) / (1 - born), 0, 1)
  return (r1 - 0.5) * 1.4, -0.6 + u * 1.4, 0.7 + r2 * 0.4,
    min(1, sin(u * pi) * 1.4), (r3 < 0.5) and 2 or 3, pi
end

-- Everything at once, big, and rising as it goes: a detonation.
EMIT.blast = function(i, n, t, r1, r2, r3)
  local ang = (i / n) * pi * 2 + r1 * 0.7
  local u = 1 - (1 - t) * (1 - t)
  local reach = (0.5 + r2 * 0.9) * u
  local tint = (t < 0.3) and 1 or ((r3 < 0.5) and 2 or 3)
  return cos(ang) * reach, sin(ang) * reach * 0.85 - u * 0.2,
    (0.8 + r3 * 0.9) * (1 - t * 0.5), 1 - t * t, tint, 0
end

-- Notes drift up and bob; the angle is the tilt, not a spin.
EMIT.note = function(i, n, t, r1, r2, r3)
  local born = (i - 1) / n * 0.5
  local u = clamp((t - born) / (1 - born), 0, 1)
  local x = (r1 - 0.5) * 1.3 + sin(u * pi * 2) * 0.2
  return x, 0.5 - u * 1.4, 0.8 + r2 * 0.3, sin(u * pi),
    (r3 < 0.5) and 1 or 2, sin(u * pi * 3) * 0.35
end

-- Smoke: expands, thins, and drifts up a little as it goes.
EMIT.puff = function(i, n, t, r1, r2, r3)
  local ang = (i / n) * pi * 2 + r1 * 0.5
  local u = 1 - (1 - t) * (1 - t)
  local rad = (0.3 + r2 * 0.7) * u
  return cos(ang) * rad, sin(ang) * rad * 0.8 - u * 0.15,
    (0.9 + r3 * 0.8) * (0.4 + u * 0.8), 1 - t * t, (r3 < 0.4) and 1 or 2, 0
end

-- A narrow column rather than a spray: something being lifted back up.
EMIT.revive = function(i, n, t, r1, r2, r3)
  local born = r1 * 0.5
  local u = clamp((t - born) / (1 - born), 0, 1)
  return (r2 - 0.5) * 0.9, 0.75 - u * 1.7, (0.4 + r3 * 0.6) * (1 - u * 0.3),
    sin(u * pi), (r3 < 0.6) and 1 or 2, r2 * 6.283
end

-- One particle of one emission.
--
-- `seed` is the emission's own number, so two Flamethrowers in a row do not
-- draw the identical sixteen sparks; `i` is the particle. Everything else is
-- t. Returns the tuple documented above, with alpha 0 for a particle that has
-- not been born yet or is already spent -- a caller loops 1..M.count and skips
-- anything non-positive rather than testing for nil.
function M.particle(style, i, n, t, seed)
  local def, name = M.style(style)
  local emit = EMIT[name]
  if not emit then return 0, 0, 0, 0, 1, 0 end
  i = max(1, floor(num(i, 1)))
  n = max(1, floor(num(n, def.count)))
  t = clamp(num(t, 0), 0, 1)
  seed = floor(num(seed, 0))
  local r1 = rand01(seed, i, 1)
  local r2 = rand01(seed, i, 2)
  local r3 = rand01(seed, i, 3)
  local x, y, r, a, tint, angle = emit(i, n, t, r1, r2, r3)
  if not (a and a > 0) then return num(x, 0), num(y, 0), 0, 0, 1, 0 end
  tint = floor(num(tint, 2))
  if tint < 1 then tint = 1 elseif tint > 3 then tint = 3 end
  return num(x, 0), num(y, 0), max(0, num(r, 0)), clamp(a, 0, 1), tint,
    num(angle, 0)
end

-- ------------------------------------------------------------------
-- delivery
-- ------------------------------------------------------------------
--
-- Where an effect happens, which is a separate question from what it looks
-- like. Five answers, and every move / item / condition resolves to one:
--
--   burst       at the seat it lands on. The default, and what every contact
--               move gets: the blow is at the defender, not in between.
--   projectile  a core travelling attacker -> defender, trailing as it goes,
--               bursting on arrival. Ember, spark, leaf, shard, splash, rock
--               and psi wear those looks in the air; everything else is a
--               bright ball (Shadow Ball).
--   beam        ember / spark / shard / splash / psi wear fire, lightning,
--               crystals, water and a helix of motes; other styles keep a
--               widening energy quad, with the burst under the far end.
--   self        at the user's own seat: a stat boost, a heal, a screen.
--   field       across the whole arena: Earthquake, Explosion, a Poke Flute.
--
-- The split between `burst` and `projectile` for a move with no explicit entry
-- is Gen 1's own physical / special line, because that line already tracks
-- "does this move touch the target" closely enough to read right, and because
-- it is a rule rather than a list -- a move this file has never seen still
-- gets the correct one.

M.DELIVERIES = {
  burst = true, projectile = true, beam = true, self = true, field = true,
}

M.TYPE_STYLE = {
  NORMAL = "impact", FIGHTING = "impact", FLYING = "gust",  POISON = "bubble",
  GROUND = "quake",  ROCK = "rock",       BUG = "swarm",    GHOST = "spirit",
  STEEL  = "shine",  FIRE = "ember",      WATER = "splash", GRASS = "leaf",
  ELECTRIC = "spark", PSYCHIC = "psi",    ICE = "shard",    DRAGON = "rage",
  DARK = "shadow",   FAIRY = "sparkle",
}

-- **A type's registry id is not always its name, and getting this wrong is
-- silent.** A move record carries `type` as an id into the `type_chart`
-- registry, and two of those ids do not spell the type the way everything
-- else does:
--
--   * `PSYCHIC_TYPE` -- the cart's own constant, so named because `PSYCHIC` is
--     already a *move*. Both generations use it (src/battle/gen2/Battle.lua
--     says so out loud at its `HELD_` lookup), and it is what every one of the
--     15 Gen 1 Psychic moves carries. Missing it does not fail loudly: those
--     moves simply fall through to NORMAL's impact and the whole type quietly
--     loses its look.
--   * `BIRD` -- the unused beta type at chart index 13. Nothing in Red uses
--     it, but a mod or a hack ROM may, and Flying is what it was going to be.
--
-- Aliases rather than second entries in the table above, so there is still
-- exactly one style and one palette per *type* -- the alias says "this id is
-- that type", not "this is another type that happens to look the same".
M.TYPE_ALIAS = {
  PSYCHIC_TYPE = "PSYCHIC",
  BIRD = "FLYING",
}

-- The canonical type key for a registry id: the alias if there is one, the id
-- itself otherwise. Callers pass whatever the move record carried.
function M.typeKey(typeId)
  if type(typeId) ~= "string" or typeId == "" then return nil end
  local up = typeId:upper()
  return M.TYPE_ALIAS[up] or up
end

-- Gen 1's Special types, which is also the set whose moves are fired rather
-- than thrown. Mirrored from MediatedBattle's own SPECIAL list; the two agree
-- because they are describing the same generation, not because either imports
-- the other. DARK and STEEL are Gen 2 physical/special by type as well.
M.RANGED_TYPES = {
  FIRE = true, WATER = true, GRASS = true, ELECTRIC = true,
  ICE = true, PSYCHIC = true, DRAGON = true, DARK = true,
}

-- ------------------------------------------------------------------
-- the move catalogue
-- ------------------------------------------------------------------
--
-- **This table is an override, not the mapping.** Every move already has a
-- look from its type (`M.TYPE_STYLE`) and a delivery from its category, and a
-- move absent from here is not a move without an effect -- it is a move whose
-- type answers the question well enough. What is listed is the moves where the
-- type is a poor description of what the player sees: beams, detonations,
-- moves that act on the user rather than the target, and the handful whose
-- identity is the animation.
--
-- A field left out falls through to the type-derived default, so an entry that
-- only wants a different delivery says only that.
--
-- **Leave `intensity` out unless it disagrees with the move's power band.**
-- These entries predate M.POWER_BANDS, when 1.0 was every move's baseline and
-- 1.25 meant "heavier than usual". It does not any more: a 120-power move's
-- band is 1.38, so those same authored numbers had quietly become a *cap* --
-- Fire Blast and Thunder were being drawn lighter than an unnamed move of the
-- same power. An override should say what the band cannot, not restate a
-- weaker version of it. Splash and the status moves are the honest uses: they
-- are deliberately feebler than any power table would guess.
--
-- Gen 1 and Gen 2 ids, because this mod runs on both.

local function beam(scale) return { delivery = "beam", scale = scale } end
local function selfBuff(style, pal)
  return { delivery = "self", style = style or "buff", palette = pal or "BUFF" }
end

M.MOVE_STYLE = {
  -- ------- beams and streams: a continuous line, not a lobbed object
  HYPER_BEAM   = beam(1.30),
  SOLARBEAM    = beam(1.30),
  ICE_BEAM     = beam(1.00),
  PSYBEAM      = beam(1.00),
  AURORA_BEAM  = beam(1.00),
  FLAMETHROWER = beam(1.10),
  THUNDERBOLT  = beam(1.05),
  HYDRO_PUMP   = beam(1.25),
  ZAP_CANNON   = beam(1.20),
  AEROBLAST    = { delivery = "beam", style = "gust", scale = 1.20 },
  TWINEEDLE    = { delivery = "projectile", scale = 0.85 },
  -- Draining moves are a beam that runs the other way; the look is the tether.
  ABSORB       = beam(0.85),
  MEGA_DRAIN   = beam(0.95),
  GIGA_DRAIN   = beam(1.10),
  LEECH_LIFE   = beam(0.90),
  DREAM_EATER  = { delivery = "beam", style = "psi", palette = "GHOST", scale = 1.05 },

  -- ------- detonations
  EXPLOSION    = { style = "blast", palette = "FIRE", delivery = "field", scale = 1.60,
                   intensity = 1.4, duration = 0.70 },
  SELFDESTRUCT = { style = "blast", palette = "FIRE", delivery = "self", scale = 1.35,
                   duration = 0.60 },

  -- ------- moves whose whole point is the size of them
  EARTHQUAKE   = { delivery = "field", scale = 1.50, intensity = 1.3 },
  FISSURE      = { scale = 1.50, intensity = 1.3 },
  MAGNITUDE    = { delivery = "field", scale = 1.35 },
  SURF         = { delivery = "field", scale = 1.45, intensity = 1.2 },
  WHIRLPOOL    = { style = "psi", palette = "WATER" },
  BLIZZARD     = { scale = 1.35 },
  FIRE_BLAST   = { delivery = "projectile", scale = 1.40 },
  SACRED_FIRE  = { delivery = "projectile", scale = 1.30 },
  -- Thunder is a strike, not a thrown object: a projectile here is a yellow
  -- ball in the air for half the life, which is the opposite of lightning.
  THUNDER      = { delivery = "burst", scale = 1.35 },
  PETAL_DANCE  = { style = "leaf", scale = 1.20 },
  SANDSTORM    = { style = "quake", palette = "GROUND", delivery = "field",
                   scale = 1.45, duration = 0.60 },
  ROCK_SLIDE   = { scale = 1.30, intensity = 1.2 },
  SKY_ATTACK   = { style = "shine", palette = "FLYING", delivery = "projectile",
                   scale = 1.25 },
  ANCIENTPOWER = { style = "rock", scale = 1.15 },
  HORN_DRILL   = { scale = 1.35 },
  GUILLOTINE   = { scale = 1.35 },
  HYPER_FANG   = { scale = 1.15 },
  CRUNCH       = { style = "impact", palette = "DARK", scale = 1.10 },
  MEGAHORN     = { style = "impact", palette = "BUG", scale = 1.20 },

  -- ------- thrown, not swung
  RAZOR_LEAF   = { delivery = "projectile", scale = 1.15 },
  LEECH_SEED   = { style = "leaf", delivery = "projectile", scale = 0.85 },
  SHADOW_BALL  = { delivery = "projectile", scale = 1.10 },
  EGG_BOMB     = { delivery = "projectile", scale = 1.10 },
  BARRAGE      = { delivery = "projectile" },
  BONE_CLUB    = { delivery = "projectile" },
  BONEMERANG   = { delivery = "projectile" },
  BONE_RUSH    = { delivery = "projectile" },
  ROCK_THROW   = { delivery = "projectile" },
  SPIKE_CANNON = { delivery = "projectile" },
  PIN_MISSILE  = { delivery = "projectile" },
  MUD_SLAP     = { delivery = "projectile", scale = 0.9 },
  ACID         = { delivery = "projectile" },
  SLUDGE       = { delivery = "projectile" },
  SLUDGE_BOMB  = { delivery = "projectile", scale = 1.15 },
  SMOG         = { delivery = "projectile" },
  POISON_STING = { delivery = "projectile", scale = 0.8 },
  OCTAZOOKA    = { delivery = "projectile", scale = 1.05 },
  ICY_WIND     = { style = "gust", palette = "ICE" },
  POWDER_SNOW  = { style = "gust", palette = "ICE", scale = 0.9 },

  -- Charge-turn looks (Dig / Fly vanish, SolarBeam-class glow). The *release*
  -- strike still uses the type default or the entries above; MediatedBattle
  -- reads CHARGE_STYLE only when anim.amount == 1.
  --
  -- ------- acts on the user, not on anything opposite
  SWORDS_DANCE = selfBuff(),
  SHARPEN      = selfBuff(),
  MEDITATE     = selfBuff(),
  GROWTH       = selfBuff("heal", "GRASS"),
  AGILITY      = selfBuff(),
  DOUBLE_TEAM  = selfBuff("puff", "NORMAL"),
  MINIMIZE     = selfBuff("puff", "NORMAL"),
  HARDEN       = selfBuff("shine", "STEEL"),
  WITHDRAW     = selfBuff("shine", "WATER"),
  DEFENSE_CURL = selfBuff(),
  BARRIER      = selfBuff("shine", "PSYCHIC"),
  ACID_ARMOR   = selfBuff("shine", "POISON"),
  AMNESIA      = selfBuff("psi", "PSYCHIC"),
  FOCUS_ENERGY = selfBuff("spark", "BUFF"),
  BELLY_DRUM   = selfBuff(),
  CURSE        = selfBuff("spirit", "GHOST"),
  LIGHT_SCREEN = selfBuff("shine", "PSYCHIC"),
  REFLECT      = selfBuff("shine", "ICE"),
  MIST         = selfBuff("puff", "ICE"),
  SAFEGUARD    = selfBuff("shine", "FAIRY"),
  PROTECT      = selfBuff("shine", "CURE"),
  DETECT       = selfBuff("shine", "CURE"),
  ENDURE       = selfBuff("shine", "FIGHTING"),
  SUBSTITUTE   = selfBuff("puff", "NORMAL"),
  TRANSFORM    = selfBuff("sparkle", "PSYCHIC"),
  CONVERSION   = selfBuff("sparkle", "PSYCHIC"),
  CONVERSION2  = selfBuff("sparkle", "PSYCHIC"),
  METRONOME    = selfBuff("sparkle", "NORMAL"),
  MIMIC        = selfBuff("sparkle", "PSYCHIC"),
  TELEPORT     = selfBuff("puff", "PSYCHIC"),
  SPLASH       = { style = "splash", palette = "WATER", delivery = "self",
                   scale = 0.70, intensity = 0.6 },
  MILK_DRINK   = selfBuff("heal", "HEAL"),
  SOFTBOILED   = selfBuff("heal", "HEAL"),
  RECOVER      = selfBuff("heal", "HEAL"),
  REST         = selfBuff("heal", "HEAL"),
  MOONLIGHT    = selfBuff("heal", "HEAL"),
  MORNING_SUN  = selfBuff("heal", "HEAL"),
  SYNTHESIS    = selfBuff("heal", "HEAL"),
  HEAL_BELL    = { style = "cure", palette = "CURE", delivery = "field" },
  HAZE         = { style = "puff", palette = "DARK", delivery = "field" },
  RAIN_DANCE   = { style = "splash", palette = "WATER", delivery = "field" },
  SUNNY_DAY    = { style = "shine", palette = "FIRE", delivery = "field" },
  PERISH_SONG  = { style = "note", palette = "GHOST", delivery = "field" },

  -- ------- sound, powder and gaze: aimed at the target but never touching it
  GROWL        = { style = "note", delivery = "projectile", intensity = 0.8 },
  ROAR         = { style = "note", delivery = "projectile", intensity = 0.9 },
  SING         = { style = "note", palette = "FAIRY", delivery = "projectile" },
  SUPERSONIC   = { style = "note", palette = "PSYCHIC", delivery = "projectile" },
  SCREECH      = { style = "note", palette = "STEEL", delivery = "projectile" },
  SNORE        = { style = "note", delivery = "projectile" },
  SLEEP_POWDER = { style = "sparkle", palette = "GRASS", delivery = "projectile" },
  STUN_SPORE   = { style = "sparkle", palette = "ELECTRIC", delivery = "projectile" },
  POISONPOWDER = { style = "sparkle", palette = "POISON", delivery = "projectile" },
  SPORE        = { style = "sparkle", palette = "GRASS", delivery = "projectile" },
  TOXIC        = { style = "bubble", palette = "POISON", scale = 1.15 },
  POISON_GAS   = { style = "bubble", palette = "POISON" },
  THUNDER_WAVE = { style = "spark", delivery = "projectile", scale = 0.90 },
  GLARE        = { style = "spark", palette = "NORMAL", intensity = 0.8 },
  HYPNOSIS     = { style = "psi", palette = "PSYCHIC" },
  CONFUSE_RAY  = { style = "psi", palette = "GHOST", delivery = "projectile" },
  SWEET_KISS   = { style = "sparkle", palette = "FAIRY", delivery = "projectile" },
  LOVELY_KISS  = { style = "sparkle", palette = "FAIRY", delivery = "projectile" },
  STRING_SHOT  = { style = "swarm", palette = "BUG", delivery = "projectile" },
  SPIDER_WEB   = { style = "swarm", palette = "BUG", delivery = "projectile" },
  SAND_ATTACK  = { style = "quake", delivery = "projectile", scale = 0.90 },
  SMOKESCREEN  = { style = "puff", palette = "DARK" },
  FLASH        = { style = "shine", palette = "NORMAL", scale = 1.15 },
  KINESIS      = { style = "psi", palette = "PSYCHIC" },
  SWEET_SCENT  = { style = "sparkle", palette = "FAIRY" },
  SPIKES       = { style = "shard", palette = "GROUND" },

  -- ------- the odd ones out
  PAY_DAY      = { style = "sparkle", palette = "BUFF" },
  COUNTER      = { style = "impact", scale = 1.15 },
  MIRROR_COAT  = { style = "psi", palette = "PSYCHIC", scale = 1.15 },
  DESTINY_BOND = { style = "spirit", palette = "GHOST", delivery = "self" },
  NIGHT_SHADE  = { style = "spirit", palette = "GHOST", delivery = "projectile" },
  PSYWAVE      = { style = "psi", delivery = "projectile" },
  SONICBOOM    = { style = "gust", palette = "NORMAL", delivery = "projectile" },
  DRAGON_RAGE  = { delivery = "projectile", scale = 1.10 },
  SEISMIC_TOSS = { style = "impact", scale = 1.20 },
  FUTURE_SIGHT = { style = "psi", palette = "PSYCHIC", delivery = "self" },
  THIEF        = { style = "shadow", palette = "DARK" },
  FLAIL        = { style = "impact", scale = 1.15 },
  REVERSAL     = { style = "impact", palette = "FIGHTING", scale = 1.15 },
}

-- Turn-one setup looks. Dig/Fly stay on the user (dust / gust) so the charge
-- does not fire a foe projectile; SolarBeam-class glows in place. Release
-- still uses MOVE_STYLE / the type default.
M.CHARGE_STYLE = {
  DIG          = { style = "quake", palette = "GROUND", delivery = "self", scale = 1.15 },
  FLY          = { style = "gust", palette = "FLYING", delivery = "self", scale = 1.15 },
  SOLARBEAM    = { style = "shine", palette = "GRASS", delivery = "self", scale = 1.20 },
  SKULL_BASH   = { style = "shine", palette = "NORMAL", delivery = "self", scale = 1.10 },
  RAZOR_WIND   = { style = "gust", palette = "NORMAL", delivery = "self", scale = 1.10 },
  SKY_ATTACK   = { style = "shine", palette = "FLYING", delivery = "self", scale = 1.20 },
  -- Gen 3's two new semi-invulnerable turns. Names no Gen 1 or Gen 2 move
  -- carries, so these two rows are dead weight on those carts rather than a
  -- change to anything they draw.
  DIVE         = { style = "splash", palette = "WATER", delivery = "self", scale = 1.15 },
  BOUNCE       = { style = "gust", palette = "FLYING", delivery = "self", scale = 1.15 },
}

-- Moves that fire once per hit of a multi-hit or that a client sees twice in a
-- turn are not special-cased: each `anim` row is one emission with its own
-- seed, which is exactly the behaviour a flurry wants.

-- ------------------------------------------------------------------
-- resolution
-- ------------------------------------------------------------------

local function specOf(style, pal, delivery, scale, intensity, duration)
  return {
    style = style, palette = pal, delivery = delivery,
    scale = scale, intensity = intensity, duration = duration,
  }
end

-- The base every move starts from: its type's look, and a delivery decided by
-- whether Gen 1 would have called the type Special.
local function typeSpec(typeId)
  local style = M.TYPE_STYLE[typeId] or M.DEFAULT_STYLE
  local pal = M.PALETTES[typeId] and typeId or M.DEFAULT_PALETTE
  local delivery = M.RANGED_TYPES[typeId] and "projectile" or "burst"
  return specOf(style, pal, delivery, 1, 1, nil)
end

-- ------------------------------------------------------------------
-- how hard it hit
-- ------------------------------------------------------------------
--
-- A move's type says what it looks like; its **power** says how much of it
-- there is. Without this, Ember (40) and Fire Blast (120) spent the same
-- sixteen sparks at the same radius, and the 36 Normal physical moves -- from
-- Pound at 40 to Mega Kick at 120 -- were one single effect.
--
-- **Bands, not a curve, and that is the whole point.** A continuous function
-- of power would give almost every move its own number and almost none of
-- them a difference anybody could see: `M.count` rounds to whole particles, so
-- 0.78 and 0.81 of a sixteen-particle style are the same sixteen particles.
-- It would move the "distinct looks" metric a long way and the screen not at
-- all. Five bands are what a player can actually tell apart -- each step is
-- two or three particles and three or four pixels of radius.
--
-- The edges are placed against Red's real distribution rather than round
-- numbers: 2..39 catches the chip damage, 40..64 the early-game staples,
-- 65..89 the workhorses, 90..119 the finishers, 120+ the ten biggest moves in
-- the game.
M.POWER_BANDS = {
  { max = 39,  intensity = 0.78, scale = 0.85 },
  { max = 64,  intensity = 0.88, scale = 0.93 },
  { max = 89,  intensity = 1.00, scale = 1.00 },
  { max = 119, intensity = 1.18, scale = 1.10 },
  { max = nil, intensity = 1.38, scale = 1.22 },
}

-- **Power 1 is not a weak move; it is a move whose power is not a number.**
-- Gen 1 marks fixed-damage and one-hit-KO moves with power 1 -- Seismic Toss,
-- Night Shade, Dragon Rage, Sonicboom, Psywave, Super Fang, Counter, and the
-- OHKOs Guillotine, Horn Drill and Fissure. Banding those as chip damage would
-- draw the biggest moves in the game as the smallest, so they take the middle
-- band and say nothing about their own weight. The ones that deserve more get
-- it by name in M.MOVE_STYLE, which is exactly what that table is for.
M.FIXED_DAMAGE_POWER = 1

-- The band a power falls in. nil for a power that says nothing -- a status
-- move (0, handled separately) or the fixed-damage marker.
function M.powerBand(power)
  local p = floor(num(power, 0))
  if p <= 0 or p == M.FIXED_DAMAGE_POWER then return nil end
  for _, band in ipairs(M.POWER_BANDS) do
    if band.max == nil or p <= band.max then return band end
  end
  return M.POWER_BANDS[#M.POWER_BANDS]
end

local function upperId(value)
  if type(value) ~= "string" or value == "" then return nil end
  return value:upper()
end

-- The look one move wears. **Never nil**: an unknown id, a missing definition
-- and a type this file has never heard of all land on NORMAL's impact rather
-- than on a frame with nothing drawn on it.
--
-- `def` is the engine's move record (`game.data.moves[id]`), which carries the
-- type as a registry id string. `typeName` is the escape hatch for a caller
-- holding the type by some other route -- the wire carries type as a chart
-- *index*, which cannot be turned back into a name without the chart, so a
-- caller that has the name passes it rather than making this file guess.
function M.forMove(moveId, def, typeName)
  local id = upperId(moveId)
  -- Through `typeKey`, so a registry id that does not spell its own type
  -- (`PSYCHIC_TYPE`, `BIRD`) still lands on that type's look rather than
  -- falling through to NORMAL's impact -- see M.TYPE_ALIAS.
  local typeId = M.typeKey(typeName)
  if typeId == nil and type(def) == "table" then typeId = M.typeKey(def.type) end

  local out = typeSpec(typeId)

  -- A move that deals no damage is not aimed the way an attack is: it is a
  -- gesture at the target, so it keeps the type's look but loses the weight.
  -- (The moves that act on the *user* are all named in M.MOVE_STYLE -- there
  -- is nothing in a move record that says "this one targets me", so a mod's
  -- new self-buff falls here and reads as a gesture at the foe. Stated rather
  -- than silently wrong: name it in MOVE_STYLE to fix it.)
  local status = false
  if type(def) == "table" then
    status = (def.category == "status")
      or (def.category == nil and num(def.power, 0) <= 0)
  end
  if status then
    out.intensity = 0.75
    out.scale = 0.90
  else
    -- How hard it hit, in bands (see M.POWER_BANDS). Applied to the *base*, so
    -- an entry in M.MOVE_STYLE that names its own weight still wins below --
    -- Fire Blast is authored heavier than its band, Splash lighter than
    -- anything, and neither wants a power table's opinion.
    local band = type(def) == "table" and M.powerBand(def.power) or nil
    if band then
      out.intensity = band.intensity
      out.scale = band.scale
    end
  end

  local over = id and M.MOVE_STYLE[id] or nil
  if over then
    if over.style then out.style = over.style end
    if over.palette then out.palette = over.palette end
    if over.delivery then out.delivery = over.delivery end
    if over.scale then out.scale = over.scale end
    if over.intensity then out.intensity = over.intensity end
    if over.duration then out.duration = over.duration end
  end
  if not M.DELIVERIES[out.delivery] then out.delivery = "burst" end
  if not M.STYLES[out.style] then out.style = M.DEFAULT_STYLE end
  if not M.PALETTES[out.palette] then out.palette = M.DEFAULT_PALETTE end
  return out
end

-- ------------------------------------------------------------------
-- the bag
-- ------------------------------------------------------------------
--
-- Every item src/BattleSim/Effects.lua's `itemEffect` answers for -- which is
-- the closed set of things a bag can do inside a fight -- and nothing else:
-- a Repel or an Escape Rope never opens in battle, so neither has a look here.
--
-- **Balls are deliberately absent.** A thrown ball already has five queued
-- rows and a whole flow of its own (the arc, the recall, the rocking, the
-- burst; see `startBallFx` in src/MediatedBattle.lua), and putting a second
-- effect over it would be drawing the throw twice. `M.forItem` answers nil for
-- them, and nil is the caller's signal to leave the ball flow alone.
--
-- Every one of these plays on the seat of whoever opened the bag: an item is
-- something a trainer does to their own monster. Poke Flute is the exception
-- and says so -- it wakes both sides' parties, so it plays across the field.

local ITEM_BALLS = {
  POKE_BALL = true, GREAT_BALL = true, ULTRA_BALL = true,
  MASTER_BALL = true, SAFARI_BALL = true,
}

M.ITEM_STYLE = {
  -- restoring HP
  POTION       = { style = "heal", palette = "HEAL", scale = 0.90 },
  SUPER_POTION = { style = "heal", palette = "HEAL" },
  HYPER_POTION = { style = "heal", palette = "HEAL", scale = 1.15 },
  MAX_POTION   = { style = "heal", palette = "HEAL", scale = 1.25, intensity = 1.2 },
  FULL_RESTORE = { style = "heal", palette = "HEAL", scale = 1.25, intensity = 1.3 },
  FRESH_WATER  = { style = "heal", palette = "WATER" },
  SODA_POP     = { style = "heal", palette = "WATER" },
  LEMONADE     = { style = "heal", palette = "ELECTRIC" },

  -- clearing a condition
  ANTIDOTE     = { style = "cure", palette = "POISON" },
  BURN_HEAL    = { style = "cure", palette = "FIRE" },
  ICE_HEAL     = { style = "cure", palette = "ICE" },
  AWAKENING    = { style = "cure", palette = "PSYCHIC" },
  PARLYZ_HEAL  = { style = "cure", palette = "ELECTRIC" },
  FULL_HEAL    = { style = "cure", palette = "CURE", intensity = 1.2 },

  -- back from nothing
  REVIVE       = { style = "revive", palette = "REVIVE" },
  MAX_REVIVE   = { style = "revive", palette = "REVIVE", scale = 1.2, intensity = 1.25 },

  -- PP
  ETHER        = { style = "sparkle", palette = "CURE" },
  MAX_ETHER    = { style = "sparkle", palette = "CURE", intensity = 1.2 },
  ELIXER       = { style = "sparkle", palette = "CURE", scale = 1.1 },
  MAX_ELIXER   = { style = "sparkle", palette = "CURE", scale = 1.2, intensity = 1.25 },
  ELIXIR       = { style = "sparkle", palette = "CURE", scale = 1.1 },
  MAX_ELIXIR   = { style = "sparkle", palette = "CURE", scale = 1.2, intensity = 1.25 },

  -- the X shelf: the same arrows a stat stage draws, because that is what
  -- these are
  X_ATTACK     = { style = "buff", palette = "BUFF" },
  X_DEFEND     = { style = "buff", palette = "BUFF" },
  X_SPEED      = { style = "buff", palette = "BUFF" },
  X_SPECIAL    = { style = "buff", palette = "BUFF" },
  X_ACCURACY   = { style = "buff", palette = "BUFF" },
  DIRE_HIT     = { style = "spark", palette = "BUFF", scale = 0.95 },
  GUARD_SPEC   = { style = "shine", palette = "CURE" },

  -- vitamins, which do land mid-fight in this ruleset
  HP_UP        = { style = "sparkle", palette = "HEAL" },
  PROTEIN      = { style = "sparkle", palette = "BUFF" },
  IRON         = { style = "sparkle", palette = "STEEL" },
  CARBOS       = { style = "sparkle", palette = "ELECTRIC" },
  CALCIUM      = { style = "sparkle", palette = "PSYCHIC" },

  -- and the two that end fights rather than change them
  POKE_DOLL    = { style = "puff", palette = "ESCAPE", scale = 1.2 },
  POKE_FLUTE   = { style = "note", palette = "CURE", delivery = "field",
                   scale = 1.3, duration = 0.60 },
}

-- The look one item wears, or **nil for a ball** -- see above. An item this
-- table has never heard of also answers nil rather than a guess: the fight
-- announces "But it failed" for those, and an effect over a failure would be
-- saying the opposite of the line under it.
function M.forItem(itemId)
  local id = upperId(itemId)
  if id == nil or ITEM_BALLS[id] then return nil end
  local entry = M.ITEM_STYLE[id]
  if not entry then return nil end
  local out = specOf(entry.style, entry.palette, entry.delivery or "self",
    entry.scale or 1, entry.intensity or 1, entry.duration)
  if not M.DELIVERIES[out.delivery] then out.delivery = "self" end
  if not M.STYLES[out.style] then out.style = M.DEFAULT_STYLE end
  if not M.PALETTES[out.palette] then out.palette = M.DEFAULT_PALETTE end
  return out
end

-- ------------------------------------------------------------------
-- conditions and stat stages
-- ------------------------------------------------------------------
--
-- **Two vocabularies, and both are real.** What travels on the wire is
-- `Wire.STATUSES` -- the three-letter tokens a status box shows (SLP, PSN,
-- BRN, FRZ, PAR, TOX) -- and that is what a `status` event carries, so it is
-- what a client resolving one has in hand. What the turn machine calls the
-- same conditions internally is the long name (`sleep`, `poison`, ...;
-- `Turn.STATUS_TO_WIRE` is the map between them), and that is what a caller
-- reading a battler's own record has. Both are keyed here rather than making
-- either side translate first: a lookup that silently missed would be a
-- condition that lands with no sight of it, which is the failure this file is
-- least likely to notice.
--
-- `confusion` is the one with no wire token, because Gen 1 carries it as a
-- volatile rather than a status -- it only ever arrives by the long name.
--
-- These play at the seat that took the condition, and they are deliberately
-- *smaller* than a move: a condition landing is a footnote to the attack that
-- caused it, and drawn at full weight it competed with the move for the same
-- half second.

local BURN   = { style = "ember",  palette = "FIRE" }
local FREEZE = { style = "shard",  palette = "ICE" }
local PARA   = { style = "spark",  palette = "ELECTRIC" }
local POISON = { style = "bubble", palette = "POISON" }
local TOXIC  = { style = "bubble", palette = "POISON", scale = 1.15 }
local SLEEP  = { style = "note",   palette = "PSYCHIC" }
local CONFUSE = { style = "psi",   palette = "PSYCHIC" }

M.STATUS_STYLE = {
  -- the wire tokens
  BRN = BURN, FRZ = FREEZE, PAR = PARA, PSN = POISON, TOX = TOXIC, SLP = SLEEP,
  -- CNF is the HUD chip for the confusion volatile (not a Wire.STATUSES token)
  CNF = CONFUSE,
  -- ...and the turn machine's own names for the same six, plus the volatile
  burn = BURN, freeze = FREEZE, paralysis = PARA, poison = POISON,
  toxic = TOXIC, sleep = SLEEP, confusion = CONFUSE,
}

-- A condition landing (or ticking). nil for a token with no look, which is
-- what a caller reads as "say it in the box and draw nothing" -- and which is
-- also what a `status` event carrying no token means: the condition cleared.
function M.forStatus(status)
  if type(status) ~= "string" or status == "" then return nil end
  local entry = M.STATUS_STYLE[status]
    or M.STATUS_STYLE[status:upper()]
    or M.STATUS_STYLE[status:lower()]
  if not entry then return nil end
  return specOf(entry.style, entry.palette, "burst", entry.scale or 0.85,
    entry.intensity or 0.8, entry.duration)
end

-- The look of a status animation the Red referee names by its battle_anims
-- id (BattleSim Turn `_statusAnim`, wave 5): the sleeping monster's SLP_ANIM /
-- SLP_PLAYER_ANIM (pokered CheckPlayerStatusConditions / CheckEnemyStatus
-- Conditions, every turn it sleeps), the confused one's CONF_ANIM /
-- CONF_PLAYER_ANIM (behind IsConfusedText), and BURN_PSN_ANIM, the residual
-- burn or poison tick (HandlePoisonBurnLeechSeed) -- worn in the colours of
-- the condition doing it, `status` (the seat's token: BRN, else poison).
-- The arena draws these where the classic page plays the engine's clip.  nil
-- for any other id.
local STATUS_ANIM_LOOK = {
  SLP_ANIM = "SLP", SLP_PLAYER_ANIM = "SLP",
  CONF_ANIM = "confusion", CONF_PLAYER_ANIM = "confusion",
}

-- ...and every other cart animation the Red / Gold referees name by id
-- (contract K20 of docs/plans/gen12-referee-remaining-gaps.md): one row per
-- id, `{ style, palette, scale?, intensity? }`, worn on the seat the `anim`
-- event names.  A string row borrows a condition's look (`M.forStatus`).
-- Ids the classic page plays through the engine's own clip and the arena has
-- no particle for are simply absent; an id on no list is skipped (nil), as
-- every unknown `_ANIM` always has been.
--
--   Red (pokered constants/move_constants.asm, data/moves/animations.asm):
--     STATUS_AFFECTED_ANIM  EnemyFlashAnim, SE_SHOW_MON_PIC -- a FLY or
--                           charge cut short (or released) brings the
--                           monster back into view (core.asm
--                           `.FlyOrChargeEffect`); the arena's emerge is the
--                           screens' (`clearVanishAt`), this is the shimmer
--                           on it.
--     XSTATITEM_ANIM        XStatItemAnim, SE_SPIRAL_BALLS_INWARD -- an X
--                           item on the user's seat: a gathering shimmer in
--                           the stat board's colours (the `stat` event behind
--                           it draws the arrows).  Also ChargeEffect's and
--                           BideEffect's own turn-1 clip (contract K22), with
--                           no item behind it: the same plain look, and the
--                           screens' bag-look takeover (`dropItemLook`) runs
--                           only behind an `item` event on that seat.
--     BLOCKBALL_ANIM        TossBallAnimation's `.BlockBall`, after TOSS_ANIM
--                           in a trainer fight: the trainer knocks the ball
--                           away -- a small knock where it was stopped (the
--                           screens wear it on the seat the ball was thrown
--                           at, and close the throw).
--     SLIDE_DOWN_ANIM       ChargeEffect's DIG turn: the monster sinks out of
--                           sight -- a ground rumble under the screens' dig
--                           vanish, which STATUS_AFFECTED_ANIM or DIG's
--                           release undoes, as FLY's.
--   Gold (pokecrystal / pokegold constants/move_constants.asm, ANIM_<X> sent
--   as <X>_ANIM): the residual and condition clips of engine/battle/core.asm
--   (ResidualDamage's PSN / BRN / SAP / IN_NIGHTMARE, HandleWeather's
--   IN_SANDSTORM, HandleWrap's IN_WHIRLPOOL, the attraction check's IN_LOVE,
--   the thaw / paralysis checks' FRZ / PAR), and the after-anims
--   (BATTLE_AFTERANIMS: MISS, BattleCommand_StatDownAnim's ENEMY_STAT_DOWN /
--   WOBBLE pair, the DAMAGE pair, HIT_CONFUSION; PLAYER_STAT_DOWN, which no
--   routine plays, keeps the drop's look).  The curse tick plays
--   ANIM_IN_NIGHTMARE on the carts; UNDER_CURSE is kept for a referee that
--   names it apart.
local POISON_NAME = "PSN"
M.CART_ANIM_LOOK = {
  -- Red
  STATUS_AFFECTED_ANIM = { style = "sparkle", palette = "NORMAL", scale = 0.75, intensity = 0.6 },
  XSTATITEM_ANIM       = { style = "sparkle", palette = "BUFF",   scale = 0.9,  intensity = 0.9 },
  BLOCKBALL_ANIM       = { style = "impact",  palette = "NORMAL", scale = 0.6,  intensity = 0.7 },
  SLIDE_DOWN_ANIM      = { style = "quake",   palette = "GROUND", scale = 0.9,  intensity = 0.85 },
  -- Gold: the conditions
  BRN_ANIM = "BRN", PSN_ANIM = POISON_NAME, FRZ_ANIM = "FRZ", PAR_ANIM = "PAR",
  SAP_ANIM             = { style = "swarm",   palette = "GRASS" },
  IN_LOVE_ANIM         = { style = "shine",   palette = "FAIRY" },
  IN_SANDSTORM_ANIM    = { style = "rock",    palette = "ROCK" },
  IN_NIGHTMARE_ANIM    = { style = "shadow",  palette = "GHOST" },
  IN_WHIRLPOOL_ANIM    = { style = "splash",  palette = "WATER" },
  UNDER_CURSE_ANIM     = { style = "spirit",  palette = "GHOST" },
  -- Gold: the after-anims
  MISS_ANIM            = { style = "gust",    palette = "ESCAPE", scale = 0.6, intensity = 0.5 },
  ENEMY_STAT_DOWN_ANIM  = { style = "debuff", palette = "DEBUFF", scale = 1, intensity = 0.95 },
  WOBBLE_ANIM           = { style = "debuff", palette = "DEBUFF", scale = 1, intensity = 0.95 },
  PLAYER_STAT_DOWN_ANIM = { style = "debuff", palette = "DEBUFF", scale = 1, intensity = 0.95 },
  ENEMY_DAMAGE_ANIM    = { style = "impact",  palette = "NORMAL", scale = 0.85, intensity = 0.8 },
  PLAYER_DAMAGE_ANIM   = { style = "impact",  palette = "NORMAL", scale = 0.85, intensity = 0.8 },
  HIT_CONFUSION_ANIM   = { style = "impact",  palette = "PSYCHIC" },
}

function M.forStatusAnim(anim, status)
  if type(anim) ~= "string" then return nil end
  local key = STATUS_ANIM_LOOK[anim]
  if anim == "BURN_PSN_ANIM" then
    key = (status == "BRN" or status == "burn") and "BRN"
      or ((status == "TOX" or status == "toxic") and "TOX" or "PSN")
  end
  if not key then
    local look = M.CART_ANIM_LOOK[anim]
    if type(look) == "string" then
      key = look
      -- A Gold poison tick on a badly poisoned monster wears TOXIC's look.
      if look == POISON_NAME and (status == "TOX" or status == "toxic") then key = "TOX" end
    elseif type(look) == "table" then
      return specOf(look.style, look.palette, "burst", look.scale or 0.85,
        look.intensity or 0.8, look.duration)
    else
      -- A `_PLAYER_` variant of an id listed once (`<X>_PLAYER_ANIM`, the
      -- naming K20 gives a clip the cart plays from the player's side) wears
      -- the same look as `<X>_ANIM`.
      local base = anim:match("^(.+)_PLAYER_ANIM$")
      if base and M.CART_ANIM_LOOK[base .. "_ANIM"] ~= nil then
        return M.forStatusAnim(base .. "_ANIM", status)
      end
    end
  end
  if not key then return nil end
  return M.forStatus(key)
end

-- A stat stage moving: arrows up for a rise, arrows down for a drop, and the
-- count of them is the size of the change (a Growl is one arrow, a Screech is
-- two). `delta` is the stage change the `stat` event carried.
function M.forStat(delta)
  local d = floor(num(delta, 0))
  if d == 0 then return nil end
  local steps = min(3, abs(d))
  if d > 0 then
    return specOf("buff", "BUFF", "burst", 1, 0.6 + steps * 0.35, nil)
  end
  return specOf("debuff", "DEBUFF", "burst", 1, 0.6 + steps * 0.35, nil)
end

-- The compact burst that rides the moment a blow *lands*, in the attacking
-- move's own colours. Small on purpose: the move's own effect is already
-- playing on this seat, and this is the punctuation on it, not a second
-- sentence. `spec` is the move's own record (or nil, for a hit with no move
-- behind it -- a residual, a recoil).
function M.forImpact(spec)
  local pal = (type(spec) == "table" and spec.palette) or M.DEFAULT_PALETTE
  if not M.PALETTES[pal] then pal = M.DEFAULT_PALETTE end
  return specOf("impact", pal, "burst", 0.85, 0.8, nil)
end

-- ------------------------------------------------------------------
-- Gen 3 (FireRed / LeafGreen / Emerald)
-- ------------------------------------------------------------------
--
-- **A separate door, never a change to the Gen 1 / Gen 2 one.** A Gen 3 move
-- arrives as a sheet row (docs/plans/gen3-battle-sheet.md, C4): the type is a
-- pret `TYPE_*` *number*, not a registry id string; the effect is a pret
-- `EFFECT_*` number; the target is a `MOVE_TARGET_*` bit mask. None of those
-- mean anything to `M.forMove`, and teaching it to read numbers would change
-- what it answers for a Gen 1 caller that ever passed one. So Gen 3 has its own
-- entry points -- `forMove3`, `forItem3` -- and its own override tables, and
-- every table above keeps answering exactly what it answered before.
--
-- **Still never nil, and never a blank.** 354 moves resolve like this, in
-- order: an explicit Gen 3 entry (`MOVE_STYLE3`), else the Gen 1 / Gen 2 entry
-- for the same move (the ROM names Gen 3 carries for the classic moves are the
-- old twelve-character spellings -- SOLARBEAM, SELFDESTRUCT -- so those rows
-- already match; `GEN3_MOVE_ALIAS` folds the pret constant spellings a caller
-- may hold instead), else the move's *shape* read off its effect and target
-- (a self boost plays on the user, a stat drop is a falling-arrow gesture at the
-- target, a spread move plays across the field), else its type. A move this
-- file has never heard of still wears its type's colours at its power's weight.
--
-- The numbers below are pret's own enums (include/constants/pokemon.h TYPE_*,
-- battle_move_effects.h EFFECT_*, battle.h MOVE_TARGET_*): public constants,
-- the same ones src/BattleSim3 branches on. No ROM value is read or kept here.

-- pret TYPE_*: 0..17, MYSTERY (???, Curse's type) at 9.
M.GEN3_TYPES = {
  [0] = "NORMAL", [1] = "FIGHTING", [2] = "FLYING", [3] = "POISON",
  [4] = "GROUND", [5] = "ROCK", [6] = "BUG", [7] = "GHOST", [8] = "STEEL",
  [9] = "MYSTERY", [10] = "FIRE", [11] = "WATER", [12] = "GRASS",
  [13] = "ELECTRIC", [14] = "PSYCHIC", [15] = "ICE", [16] = "DRAGON",
  [17] = "DARK",
}

-- The type key a Gen 3 row names: a pret number, or a name the caller already
-- resolved (the cart's own gTypeNames text is upper-case and one word, so it is
-- already a key). nil for anything else.
function M.gen3TypeKey(value)
  local n = tonumber(value)
  if n then return M.GEN3_TYPES[floor(n)] end
  if type(value) == "string" and value ~= "" then return M.typeKey(value) end
  return nil
end

-- pret constant spellings -> the catalogue's key for the same move. The cart's
-- own move names are the twelve-character ones the tables above already use;
-- these are only the ones a caller holding a pret `MOVE_*` token would spell
-- differently.
M.GEN3_MOVE_ALIAS = {
  SOLAR_BEAM = "SOLARBEAM", SELF_DESTRUCT = "SELFDESTRUCT",
  POISON_POWDER = "POISONPOWDER", ANCIENT_POWER = "ANCIENTPOWER",
  SONIC_BOOM = "SONICBOOM", SOFT_BOILED = "SOFTBOILED",
  SMOKE_SCREEN = "SMOKESCREEN", CONVERSION_2 = "CONVERSION2",
  DRAGON_BREATH = "DRAGONBREATH", FEATHER_DANCE = "FEATHERDANCE",
  GRASS_WHISTLE = "GRASSWHISTLE",
}

-- The catalogue key for a Gen 3 move id: the engine's own constant name
-- (Moves.constName upper-cases the ROM name and turns spaces and hyphens into
-- underscores, so WILL-O-WISP is WILL_O_WISP), folded through the alias table.
-- A display name a caller passes instead is folded the same way.
function M.moveKey3(moveId)
  local id = upperId(moveId)
  if not id then return nil end
  id = id:gsub("[%s%-]+", "_")
  return M.GEN3_MOVE_ALIAS[id] or id
end

-- The moves Gen 3 added (and the few old ones whose Gen 3 shape the type
-- misreads). Same field rules as MOVE_STYLE: a field left out falls through.
M.MOVE_STYLE3 = {
  -- ------- beams and streams
  HYDRO_CANNON = beam(1.30),
  BLAST_BURN   = { style = "ember", delivery = "beam", scale = 1.30 },
  OVERHEAT     = { style = "ember", delivery = "beam", scale = 1.25 },
  SIGNAL_BEAM  = { style = "sparkle", palette = "BUG", delivery = "beam", scale = 1.00 },
  PSYCHO_BOOST = { style = "psi", delivery = "beam", scale = 1.30 },
  DRAGONBREATH = { style = "ember", palette = "DRAGON", delivery = "beam", scale = 1.00 },
  LUSTER_PURGE = { style = "psi", delivery = "projectile", scale = 1.10 },
  MIST_BALL    = { style = "psi", delivery = "projectile", scale = 1.10 },

  -- ------- across the whole field
  ERUPTION     = { style = "blast", palette = "FIRE", delivery = "field", scale = 1.50,
                   intensity = 1.3 },
  WATER_SPOUT  = { style = "splash", palette = "WATER", delivery = "field", scale = 1.45,
                   intensity = 1.2 },
  HEAT_WAVE    = { style = "ember", palette = "FIRE", delivery = "field", scale = 1.35 },
  MUDDY_WATER  = { style = "splash", palette = "GROUND", delivery = "field", scale = 1.35 },
  HYPER_VOICE  = { style = "note", palette = "NORMAL", delivery = "field", scale = 1.25 },
  HAIL         = { style = "shard", palette = "ICE", delivery = "field", scale = 1.45,
                   duration = 0.60 },
  MUD_SPORT    = { style = "quake", palette = "GROUND", delivery = "field" },
  WATER_SPORT  = { style = "splash", palette = "WATER", delivery = "field" },
  TEETER_DANCE = { style = "psi", palette = "NORMAL", delivery = "field" },
  AROMATHERAPY = { style = "cure", palette = "GRASS", delivery = "field" },
  FRENZY_PLANT = { style = "leaf", palette = "GRASS", scale = 1.40, intensity = 1.3 },
  SHEER_COLD   = { style = "shard", palette = "ICE", scale = 1.45, intensity = 1.3 },

  -- ------- thrown, not swung
  WEATHER_BALL = { delivery = "projectile", scale = 1.05 },
  SHOCK_WAVE   = { style = "spark", delivery = "projectile" },
  WATER_PULSE  = { style = "splash", delivery = "projectile" },
  ROCK_TOMB    = { style = "rock", delivery = "projectile", scale = 1.10 },
  ROCK_BLAST   = { style = "rock", delivery = "projectile" },
  BULLET_SEED  = { style = "leaf", delivery = "projectile", scale = 0.85 },
  ICICLE_SPEAR = { style = "shard", delivery = "projectile", scale = 0.90 },
  MUD_SHOT     = { style = "quake", palette = "GROUND", delivery = "projectile" },
  AIR_CUTTER   = { style = "gust", delivery = "projectile" },
  ICE_BALL     = { style = "shard", delivery = "projectile" },
  SPIT_UP      = { style = "blast", palette = "NORMAL", delivery = "projectile" },
  SEED_BOMB    = { style = "leaf", delivery = "projectile" },
  WILL_O_WISP  = { style = "ember", palette = "GHOST", delivery = "projectile",
                   intensity = 0.8 },
  EXTRASENSORY = { style = "psi", delivery = "projectile" },
  DOOM_DESIRE  = { style = "shine", palette = "STEEL", delivery = "self", scale = 1.20 },

  -- ------- blows with a look of their own
  AERIAL_ACE   = { style = "gust", palette = "FLYING", scale = 1.10 },
  SKY_UPPERCUT = { style = "impact", palette = "FIGHTING", scale = 1.15 },
  FOCUS_PUNCH  = { style = "impact", palette = "FIGHTING", scale = 1.30, intensity = 1.2 },
  SUPERPOWER   = { style = "impact", palette = "FIGHTING", scale = 1.30 },
  BRICK_BREAK  = { style = "impact", palette = "FIGHTING", scale = 1.10 },
  METEOR_MASH  = { style = "impact", palette = "STEEL", scale = 1.15 },
  SHADOW_PUNCH = { style = "impact", palette = "GHOST" },
  ASTONISH     = { style = "spirit", palette = "GHOST" },
  KNOCK_OFF    = { style = "impact", palette = "DARK" },
  FAKE_OUT     = { style = "impact", palette = "NORMAL", scale = 0.90 },
  BLAZE_KICK   = { style = "ember", palette = "FIRE", scale = 1.10 },
  POISON_FANG  = { style = "impact", palette = "POISON" },
  DRAGON_CLAW  = { style = "impact", palette = "DRAGON", scale = 1.10 },
  LEAF_BLADE   = { style = "leaf", palette = "GRASS", scale = 1.15 },
  SAND_TOMB    = { style = "quake", palette = "GROUND" },

  -- ------- acts on the user
  CALM_MIND    = selfBuff("psi", "PSYCHIC"),
  BULK_UP      = selfBuff("rage", "FIGHTING"),
  DRAGON_DANCE = selfBuff("rage", "DRAGON"),
  IRON_DEFENSE = selfBuff("shine", "STEEL"),
  COSMIC_POWER = selfBuff("sparkle", "PSYCHIC"),
  TAIL_GLOW    = selfBuff("shine", "BUG"),
  HOWL         = selfBuff("note", "BUFF"),
  CHARGE       = selfBuff("spark", "ELECTRIC"),
  STOCKPILE    = selfBuff("rage", "BUFF"),
  CAMOUFLAGE   = selfBuff("puff", "NORMAL"),
  WISH         = selfBuff("sparkle", "HEAL"),
  INGRAIN      = selfBuff("leaf", "GRASS"),
  SLACK_OFF    = selfBuff("heal", "HEAL"),
  SWALLOW      = selfBuff("heal", "HEAL"),
  REFRESH      = selfBuff("cure", "CURE"),
  MAGIC_COAT   = selfBuff("shine", "PSYCHIC"),
  SNATCH       = selfBuff("shadow", "DARK"),
  GRUDGE       = selfBuff("spirit", "GHOST"),
  IMPRISON     = selfBuff("psi", "PSYCHIC"),
  FOLLOW_ME    = selfBuff("sparkle", "NORMAL"),
  HELPING_HAND = selfBuff("buff", "BUFF"),
  RECYCLE      = selfBuff("sparkle", "NORMAL"),
  NATURE_POWER = selfBuff("sparkle", "GRASS"),
  ASSIST       = selfBuff("sparkle", "NORMAL"),

  -- ------- gestures at the target
  UPROAR       = { style = "note", delivery = "projectile" },
  METAL_SOUND  = { style = "note", palette = "STEEL", delivery = "projectile" },
  GRASSWHISTLE = { style = "note", palette = "GRASS", delivery = "projectile" },
  YAWN         = { style = "note", palette = "PSYCHIC", delivery = "projectile" },
  FAKE_TEARS   = { style = "splash", palette = "WATER", delivery = "projectile",
                   intensity = 0.8 },
  TICKLE       = { style = "sparkle", palette = "NORMAL", delivery = "projectile" },
  FEATHERDANCE = { style = "gust", palette = "FLYING", delivery = "projectile" },
  TAUNT        = { style = "shadow", palette = "DARK", delivery = "projectile" },
  TORMENT      = { style = "shadow", palette = "DARK", delivery = "projectile" },
  FLATTER      = { style = "sparkle", palette = "DARK", delivery = "projectile" },
  MEMENTO      = { style = "spirit", palette = "DARK", delivery = "projectile" },
  BLOCK        = { style = "shadow", palette = "NORMAL" },
  ODOR_SLEUTH  = { style = "psi", palette = "NORMAL" },
  SKILL_SWAP   = { style = "psi", palette = "PSYCHIC", delivery = "projectile" },
  ROLE_PLAY    = { style = "psi", palette = "PSYCHIC", delivery = "projectile" },
  TRICK        = { style = "sparkle", palette = "PSYCHIC", delivery = "projectile" },
}

-- pret EFFECT_* numbers the shape rules below read.
local E3_SELF_BOOST = {
  [10] = true, [11] = true, [12] = true, [13] = true, [14] = true, [15] = true,
  [16] = true, [50] = true, [51] = true, [52] = true, [53] = true, [54] = true,
  [55] = true, [56] = true, [47] = true, [142] = true, [206] = true, [208] = true,
  [211] = true, [212] = true, [156] = true, [108] = true,
}
local E3_STAT_DROP = {
  [18] = true, [19] = true, [20] = true, [21] = true, [22] = true, [23] = true,
  [24] = true, [58] = true, [59] = true, [60] = true, [61] = true, [62] = true,
  [63] = true, [64] = true, [205] = true,
}
local E3_SELF_HEAL = {
  [32] = true, [37] = true, [132] = true, [133] = true, [134] = true,
  [157] = true, [162] = true, [179] = true,
}
-- A condition inflicted without damage: the look of that condition, thrown.
local E3_INFLICT = {
  [1] = "SLP", [33] = "TOX", [49] = "confusion", [66] = "PSN", [67] = "PAR",
  [167] = "BRN", [187] = "SLP", [118] = "confusion", [166] = "confusion",
}
-- MOVE_TARGET_* bits.
local TARGET_USER = 16
local TARGET_FOES_AND_ALLY = 32

-- One Gen 3 move's look. `row` is the C4 move row (or the engine's own
-- Moves.get record): `type` a pret number, `power`, `effect`, `target`, and an
-- optional `category`. `typeName` wins over the row's type when given. Never
-- nil.
function M.forMove3(moveId, row, typeName)
  local id = M.moveKey3(moveId)
  row = type(row) == "table" and row or {}
  local typeId = M.gen3TypeKey(typeName) or M.gen3TypeKey(row.type)

  local out = typeSpec(typeId)
  local power = num(row.power, 0)
  local status = row.category == "status" or (row.category == nil and power <= 0)
  if status then
    out.intensity = 0.75
    out.scale = 0.90
  else
    local band = M.powerBand(power)
    if band then
      out.intensity = band.intensity
      out.scale = band.scale
    end
  end

  -- The move's shape, for a move nobody named: read off what it does.
  local over = id and (M.MOVE_STYLE3[id] or M.MOVE_STYLE[id]) or nil
  if not over then
    local effect = floor(num(row.effect, -1))
    local target = floor(num(row.target, 0))
    local inflicted = status and E3_INFLICT[effect] or nil
    if status and E3_SELF_HEAL[effect] then
      out.style, out.palette, out.delivery = "heal", "HEAL", "self"
    elseif status and (E3_SELF_BOOST[effect] or target == TARGET_USER) then
      out.style, out.palette, out.delivery = "buff", "BUFF", "self"
    elseif status and E3_STAT_DROP[effect] then
      out.style, out.palette, out.delivery = "debuff", "DEBUFF", "projectile"
    elseif inflicted then
      local look = M.STATUS_STYLE[inflicted]
      if look then
        out.style, out.palette = look.style, look.palette
      end
      out.delivery = "projectile"
    elseif not status and target == TARGET_FOES_AND_ALLY then
      out.delivery = "field"
      out.scale = math.max(out.scale or 1, 1.30)
    end
  else
    if over.style then out.style = over.style end
    if over.palette then out.palette = over.palette end
    if over.delivery then out.delivery = over.delivery end
    if over.scale then out.scale = over.scale end
    if over.intensity then out.intensity = over.intensity end
    if over.duration then out.duration = over.duration end
  end
  if not M.DELIVERIES[out.delivery] then out.delivery = "burst" end
  if not M.STYLES[out.style] then out.style = M.DEFAULT_STYLE end
  if not M.PALETTES[out.palette] then out.palette = M.DEFAULT_PALETTE end
  return out
end

-- The charge-turn look for a Gen 3 two-turn move (Dig, Fly, Dive, Bounce,
-- SolarBeam, Skull Bash, Razor Wind, Sky Attack), or nil for a move that has
-- none. Through the alias table, so a pret spelling finds the same row.
function M.chargeStyle3(moveId)
  local id = M.moveKey3(moveId)
  if not id then return nil end
  local entry = M.CHARGE_STYLE[id]
  if not entry then return nil end
  return specOf(entry.style, entry.palette, entry.delivery or "self",
    entry.scale or 1, entry.intensity or 1, entry.duration)
end

-- The Gen 3 bag, by the names the cart prints (PARLYZ HEAL, ENERGYPOWDER,
-- POKé DOLL...) folded to keys. Separate from ITEM_STYLE for the same reason
-- the move table is: several of these names are Gold's too (MOOMOO_MILK,
-- BERRY_JUICE, ENERGY_ROOT...), and a look added for Gen 3 must not start
-- drawing on a Gold fight that has never had one.
M.ITEM_STYLE3 = {
  PARALYZE_HEAL = { style = "cure", palette = "ELECTRIC" },
  MOOMOO_MILK   = { style = "heal", palette = "HEAL" },
  ENERGYPOWDER  = { style = "heal", palette = "GRASS" },
  ENERGY_POWDER = { style = "heal", palette = "GRASS" },
  ENERGY_ROOT   = { style = "heal", palette = "GRASS", scale = 1.15 },
  HEAL_POWDER   = { style = "cure", palette = "GRASS" },
  REVIVAL_HERB  = { style = "revive", palette = "GRASS" },
  BERRY_JUICE   = { style = "heal", palette = "HEAL", scale = 0.90 },
  LAVA_COOKIE   = { style = "cure", palette = "FIRE" },
  SACRED_ASH    = { style = "revive", palette = "FIRE", scale = 1.30, intensity = 1.3 },
  BLUE_FLUTE    = { style = "note", palette = "WATER" },
  YELLOW_FLUTE  = { style = "note", palette = "ELECTRIC" },
  RED_FLUTE     = { style = "note", palette = "FIRE" },
  POKE_FLUTE    = { style = "note", palette = "CURE", delivery = "field",
                    scale = 1.3, duration = 0.60 },
  FLUFFY_TAIL   = { style = "puff", palette = "ESCAPE", scale = 1.2 },
  ORAN_BERRY    = { style = "heal", palette = "HEAL", scale = 0.85 },
  SITRUS_BERRY  = { style = "heal", palette = "HEAL" },
  CHERI_BERRY   = { style = "cure", palette = "ELECTRIC" },
  CHESTO_BERRY  = { style = "cure", palette = "PSYCHIC" },
  PECHA_BERRY   = { style = "cure", palette = "POISON" },
  RAWST_BERRY   = { style = "cure", palette = "FIRE" },
  ASPEAR_BERRY  = { style = "cure", palette = "ICE" },
  LEPPA_BERRY   = { style = "sparkle", palette = "CURE" },
  PERSIM_BERRY  = { style = "cure", palette = "PSYCHIC" },
  LUM_BERRY     = { style = "cure", palette = "CURE", intensity = 1.2 },
}

local ITEM_BALLS3 = {
  POKE_BALL = true, GREAT_BALL = true, ULTRA_BALL = true, MASTER_BALL = true,
  SAFARI_BALL = true, NET_BALL = true, DIVE_BALL = true, NEST_BALL = true,
  REPEAT_BALL = true, TIMER_BALL = true, LUXURY_BALL = true, PREMIER_BALL = true,
}

-- "POKé DOLL" -> POKE_DOLL, "GUARD SPEC." -> GUARD_SPEC, "X ATTACK" -> X_ATTACK.
function M.itemKey3(name)
  if type(name) ~= "string" or name == "" then return nil end
  local key = name:upper()
    :gsub("\195\169", "E"):gsub("\195\137", "E")
    :gsub("[%.']", ""):gsub("[%s%-]+", "_")
    :gsub("^_+", ""):gsub("_+$", "")
  if key == "" then return nil end
  return key
end

-- A Gen 3 bag item's look, or nil (a ball -- the throw is its own flow -- or an
-- item this table has never heard of, which plays nothing rather than a guess).
-- `item` is the name the cart prints, or a pret-style key.
function M.forItem3(item)
  local id = M.itemKey3(item)
  if id == nil or ITEM_BALLS3[id] then return nil end
  local entry = M.ITEM_STYLE3[id] or M.ITEM_STYLE[id]
  if not entry then return nil end
  local out = specOf(entry.style, entry.palette, entry.delivery or "self",
    entry.scale or 1, entry.intensity or 1, entry.duration)
  if not M.DELIVERIES[out.delivery] then out.delivery = "self" end
  if not M.STYLES[out.style] then out.style = M.DEFAULT_STYLE end
  if not M.PALETTES[out.palette] then out.palette = M.DEFAULT_PALETTE end
  return out
end

return M
