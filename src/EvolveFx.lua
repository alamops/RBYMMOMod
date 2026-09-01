-- Mid-battle evolution movie: timing, qualify, apply.
--
-- Vanilla still only evolves after a fight (`BattleState:finish` ->
-- `Evolution.checkParty`). The custom screens -- CoopBattle, MediatedBattle,
-- and SoloBattle sitting on the latter -- offer a level-up evolution *on the
-- arena* after that mon's grew-to / learn-move lines, with the same flash
-- clock and B-cancel as `src/ui/EvolutionState.lua`.
--
-- This file owns **none of the drawing**. Battlefield paints the white pulse;
-- the screens swap the seat pic via `picSpecies`. Pushing the engine's
-- EvolutionState / Gen2EvolutionAnim onto a 640x360 arena is the catch-screen
-- postage-stamp bug, so the movie stays in-place.
--
-- **Local only.** Same contract as exp and levels: the save and this client's
-- sprite update; the hub and the other players keep the uploaded pre-evo
-- sheet for this fight. No PROTOCOL bump. If the screen pops mid-movie, do
-- not apply -- leave `leveledUp` so `Coop.offerEvolutions` still runs.
--
-- No love. Engine modules are pcall'd so a headless suite can assert the
-- clock with no ROM and no Evolution.lua.

local need = ...
local Gen = need("Gen")
local Exp2 = need("Exp2")

local M = {}

-- evolution.asm EvolveMon delays 80 frames before .animLoop, polling nothing
-- (#968, #1031). Copied rather than required so this file stays love-free.
M.CANCEL_GRACE_FRAMES = 80
-- .animLoop: 8 iterations, hold 18-2k then k swaps of 6 frames (288 in all).
M.ANIM_LOOP_FRAMES = 288
M.FLASH_FRAMES = M.CANCEL_GRACE_FRAMES + M.ANIM_LOOP_FRAMES
-- Seat-FX lifetime the screens pass to emitFx. One movie, one span.
M.MOVIE_SECONDS = M.FLASH_FRAMES / 60

-- Which pic is on screen `t` frames into .animLoop (t may be negative during
-- the grace: every negative value is the old form).
function M.showsNew(t)
  t = tonumber(t) or 0
  for b = 1, 8 do
    local hold = 18 - 2 * b
    if t < hold then return false end
    t = t - hold
    local swap = b * 6
    if t < swap then return t % 6 < 3 end
    t = t - swap
  end
  return true
end

function M.canCancel(frame)
  return (tonumber(frame) or 0) > M.CANCEL_GRACE_FRAMES
end

-- White-pulse envelope the arena paints over a swapping pic. Same curve
-- Battlefield.fxSeat uses for `evolve`, so a centered bench pic and an on-
-- plate flash stay in step. `t` is 0..1 through the movie.
function M.flashPulse(movie)
  if type(movie) ~= "table" or movie.done then return 0 end
  local span = M.FLASH_FRAMES
  if span <= 0 then return 0 end
  local t = (tonumber(movie.frame) or 0) / span
  if t < 0 then t = 0 elseif t > 1 then t = 1 end
  return math.abs(math.sin(t * math.pi * 16)) * (0.4 + 0.6 * t)
end

-- Fight-plate HP when max HP changes (a level, then an evolution). The save
-- mon is not a source: copying its HP onto the plate heals fight damage.
-- Returns grown, newMax, newHp.
function M.hpGrowth(oldMax, newMax, currentHp)
  newMax = math.floor(tonumber(newMax) or 0)
  oldMax = math.floor(tonumber(oldMax) or newMax)
  if newMax <= 0 then return 0, nil, tonumber(currentHp) end
  local grown = newMax - oldMax
  if grown < 0 then grown = 0 end
  local hp = tonumber(currentHp)
  if hp and grown > 0 then
    hp = math.max(0, math.floor(hp) + grown)
    if hp > newMax then hp = newMax end
  end
  return grown, newMax, hp
end

local function formFields(kind)
  if kind == "icon" then return "oldIcon", "newIcon" end
  return "oldFront", "newFront"
end

-- Two-pic (or two-icon) cache on the movie so the flash does not reload
-- makeBattler / bag art every swap. Nil is a miss; false is "loaded, missing".
function M.formCacheGet(movie, kind, species)
  if type(movie) ~= "table" or species == nil then return nil end
  local oldF, newF = formFields(kind)
  if species == movie.from then
    if movie[oldF] ~= nil then return movie[oldF] end
  elseif species == movie.into then
    if movie[newF] ~= nil then return movie[newF] end
  end
  return nil
end

function M.formCachePut(movie, kind, species, value)
  if type(movie) ~= "table" or species == nil then return end
  local oldF, newF = formFields(kind)
  if species == movie.from then
    movie[oldF] = value or false
  elseif species == movie.into then
    movie[newF] = value or false
  end
end

-- Species the seat should draw this frame. After the movie settles, cancel
-- keeps `from` and a completed flash keeps `into`.
function M.picSpecies(movie)
  if type(movie) ~= "table" then return nil end
  if movie.done then
    if movie.canceled then return movie.from end
    return movie.into
  end
  if M.showsNew((movie.frame or 0) - M.CANCEL_GRACE_FRAMES) then
    return movie.into
  end
  return movie.from
end

function M.evolvingLine(movie)
  local name = (movie and movie.name) or "?"
  return "What? " .. name .. "\nis evolving!"
end

function M.stoppedLine(movie)
  local name = (movie and movie.name) or "?"
  return "Huh? " .. name .. "\nstopped evolving!"
end

function M.evolvedLine(movie, game)
  local name = (movie and movie.name) or "?"
  local into = movie and movie.into
  local shown = into
  local data = game and game.data
  local def = data and data.pokemon and into and data.pokemon[into]
  if type(def) == "table" and type(def.name) == "string" and def.name ~= "" then
    shown = def.name
  end
  return name .. " evolved\ninto " .. tostring(shown or "?") .. "!"
end

function M.begin(row)
  if type(row) ~= "table" then return nil end
  local mon = row.evolve or row.mon
  if type(mon) ~= "table" then return nil end
  return {
    mon = mon,
    from = row.from or mon.species,
    into = row.into,
    entry = row.entry,
    via = row.via or "LEVEL",
    name = row.name or mon.nickname or "?",
    frame = 0,
    done = false,
    canceled = false,
    cancelable = row.cancelable ~= false
      and row.via ~= "TRADE" and row.via ~= "ITEM",
  }
end

-- Advance the movie. `dt` nil means one 60Hz frame (CoopBattle's fixed step);
-- a real dt accumulates into whole frames so MediatedBattle's wall clock
-- still lands on the same cancel edge. Vanilla increments t first, then
-- reads a fresh B edge (`wasPressed`), then completes at FLASH_FRAMES.
--
-- Returns the movie. `movie.done` is the caller's cue to conclude.
function M.advance(movie, dt, pressedB)
  if type(movie) ~= "table" or movie.done then return movie end
  local add = 1
  if dt ~= nil then
    movie._acc = (tonumber(movie._acc) or 0) + (tonumber(dt) or 0)
    add = math.floor(movie._acc * 60 + 1e-9)
    movie._acc = movie._acc - add / 60
    if add < 1 then add = 0 end
  end
  movie.frame = (tonumber(movie.frame) or 0) + add
  if movie.cancelable and pressedB and M.canCancel(movie.frame) then
    movie.done = true
    movie.canceled = true
    return movie
  end
  if movie.frame >= M.FLASH_FRAMES then
    movie.done = true
    movie.canceled = false
  end
  return movie
end

local function gen2Daytime()
  local ok, Palettes = pcall(require, "src.render.Palettes")
  if not (ok and type(Palettes) == "table"
      and type(Palettes.clockDaytime) == "function") then
    return nil
  end
  local good, tod = pcall(Palettes.clockDaytime)
  if good then return tod end
  return nil
end

-- Does this mon now qualify for a *level-up* evolution? Nil if not, or if
-- the engine module is missing -- a missing module must not fail the fight.
function M.pending(game, mon)
  if not (game and type(mon) == "table") then return nil end
  if Gen.generation(game) == 2 then
    local ok, Evolution = pcall(require, "src.core.gen2.Evolution")
    if not (ok and type(Evolution) == "table"
        and type(Evolution.checkMon) == "function") then
      return nil
    end
    local entry
    local ran = pcall(function()
      entry = Evolution.checkMon(game.data, mon, { timeOfDay = gen2Daytime() })
    end)
    if ran and type(entry) == "table" and entry.into then
      return {
        from = mon.species,
        into = entry.into,
        entry = entry,
        via = entry.method or "LEVEL",
      }
    end
    return nil
  end
  local ok, Evolution = pcall(require, "src.pokemon.Evolution")
  if not (ok and type(Evolution) == "table"
      and type(Evolution.pendingFor) == "function") then
    return nil
  end
  local species, evo
  local ran = pcall(function()
    species, evo = Evolution.pendingFor(game, mon, { kind = "levelup" })
  end)
  if ran and species then
    return {
      from = mon.species,
      into = species,
      entry = evo,
      via = (evo and evo.method) or "LEVEL",
    }
  end
  return nil
end

-- Append an evolve row after the grew-to / teach lines, if this mon qualifies
-- and has not already resolved mid-fight. Returns the row or nil.
function M.enqueue(queue, game, mon, holder)
  if type(queue) ~= "table" or type(mon) ~= "table" then return nil end
  if holder and holder.evoResolved and holder.evoResolved[mon] then return nil end
  local pending = M.pending(game, mon)
  if not pending then return nil end
  local def = game and game.data and game.data.pokemon
      and game.data.pokemon[mon.species]
  local name = mon.nickname or (def and def.name) or "?"
  local row = {
    evolve = mon,
    from = pending.from,
    into = pending.into,
    entry = pending.entry,
    via = pending.via,
    name = name,
  }
  queue[#queue + 1] = row
  return row
end

-- Drop mons that already accepted or cancelled mid-fight, so the after-battle
-- fallback does not re-offer. Empty leftover is nil, matching checkParty's
-- "nothing to walk".
function M.withoutResolved(leveledUp, skip)
  if type(leveledUp) ~= "table" then return leveledUp end
  if type(skip) ~= "table" then return leveledUp end
  local out, any = {}, false
  for mon, flag in pairs(leveledUp) do
    if flag and not skip[mon] then
      out[mon] = true
      any = true
    end
  end
  if not any then return nil end
  return out
end

function M.markResolved(holder, mon)
  if not (holder and mon) then return end
  holder.evoResolved = holder.evoResolved or {}
  holder.evoResolved[mon] = true
  if type(holder.leveledUp) == "table" then
    holder.leveledUp[mon] = nil
  end
end

-- Gen 2 apply returns a new record. Every pointer that still named the old
-- one -- the plate, the forget list, the levelled set, the resolved set --
-- has to move, or the next tick writes the old species back over the new.
function M.retarget(holder, old, new)
  if not (holder and old and new and old ~= new) then return new end
  if type(holder.leveledUp) == "table" and holder.leveledUp[old] then
    holder.leveledUp[old] = nil
    holder.leveledUp[new] = true
  end
  if type(holder.evoResolved) == "table" and holder.evoResolved[old] then
    holder.evoResolved[old] = nil
    holder.evoResolved[new] = true
  end
  if type(holder.toLearn) == "table" then
    for _, entry in ipairs(holder.toLearn) do
      if type(entry) == "table" and entry.mon == old then
        entry.mon = new
      end
    end
  end
  local sim = holder.sim
  if type(sim) == "table" then
    for _, slot in ipairs(sim.slots or {}) do
      local battler = slot and slot.battler
      if battler and battler.mon == old then battler.mon = new end
    end
  end
  return new
end

-- Mutate (Gen 1) or replace (Gen 2) the save-party mon. Returns the live
-- record on success -- the Gen 2 one is a *new* table -- or nil on failure.
-- Failure must not mark resolved: the after-battle fallback still owes this.
function M.applyTo(game, movie, holder)
  if not (game and type(movie) == "table" and type(movie.mon) == "table") then
    return nil
  end
  local mon = movie.mon
  local into = movie.into
  if not into then return nil end
  if Gen.generation(game) == 2 then
    local ok, Evolution = pcall(require, "src.core.gen2.Evolution")
    if not (ok and type(Evolution) == "table"
        and type(Evolution.apply) == "function") then
      return nil
    end
    local evolved
    local ran = pcall(function()
      evolved = Evolution.apply(game.data, mon, movie.entry)
    end)
    if not (ran and type(evolved) == "table") then return nil end
    local party = game.save and game.save.party
    if type(party) == "table" then
      for i, member in ipairs(party) do
        if member == mon then
          party[i] = evolved
          break
        end
      end
    end
    if type(Evolution.markPokedex) == "function" then
      pcall(Evolution.markPokedex, game.save, into)
    end
    movie.mon = evolved
    if holder then M.retarget(holder, mon, evolved) end
    return evolved
  end
  local ok, Evolution = pcall(require, "src.pokemon.Evolution")
  if not (ok and type(Evolution) == "table"
      and type(Evolution.apply) == "function") then
    return nil
  end
  local ran = pcall(Evolution.apply, game, mon, into, movie.via or "LEVEL")
  if not ran then return nil end
  return mon
end

-- Moves the *evolved* species learns at this exact level. Asked after apply,
-- so `mon.species` is already the new form. Engine `learnEvolutionMoves`
-- pushes TextBox / MoveLearnMenu -- screens must not -- so this is the list
-- only, and `:teach` is what announces it.
function M.learnMoveIds(game, mon)
  if not (game and type(mon) == "table") then return {} end
  local data = game.data
  local def = data and data.pokemon and data.pokemon[mon.species]
  if Gen.generation(game) == 2 then
    local ok, Evolution = pcall(require, "src.core.gen2.Evolution")
    if ok and type(Evolution) == "table"
        and type(Evolution.learnedOnEvolve) == "function" then
      local got
      local ran = pcall(function()
        got = Evolution.learnedOnEvolve(data, mon.species, mon.level, mon)
      end)
      if ran and type(got) == "table" then return got end
    end
    if def and Exp2 and type(Exp2.movesLearnedAt) == "function" then
      local got
      local ran = pcall(function()
        got = Exp2.movesLearnedAt(def, mon.level)
      end)
      if ran and type(got) == "table" then return got end
    end
    return {}
  end
  local ok, Experience = pcall(require, "src.battle.Experience")
  if ok and type(Experience) == "table"
      and type(Experience.movesLearnedAt) == "function" and def then
    local got
    local ran = pcall(function()
      got = Experience.movesLearnedAt(def, mon.level)
    end)
    if ran and type(got) == "table" then return got end
  end
  return {}
end

-- Soft: missing Music must not fail the fight.
function M.playMusic(game, Music)
  if not (game and Music and type(Music.play) == "function") then return end
  pcall(function()
    if Music.stop then Music.stop() end
    if Music.special then
      Music.play(game.data, Music.special(game.data, "evolution"))
    end
  end)
end

function M.restoreBattleMusic(game, opts)
  if not game then return end
  pcall(Gen.playBattleMusic, game, opts or {})
end

function M.playCry(game, Sound, species)
  if not (game and Sound and type(Sound.playCry) == "function" and species) then
    return
  end
  pcall(Sound.playCry, game.data, species)
end

-- After-battle fallback the custom screens owe when an evolve row never
-- played (snap, pop, queue drop). Sessions cannot require Coop -- that
-- graph is a cycle -- so the offer lives here, and Coop.offerEvolutions is
-- the wrapper that stamps mod.log / mod.ui. `opts.warn` is `function(fmt, ...)`
-- and `opts.ui` is the facade with `:push` (Gen 2 only).
local offerEvolutionsGen2

function M.offerEvolutions(game, leveledUp, result, evoResolved, opts)
  leveledUp = M.withoutResolved(leveledUp, evoResolved)
  if not (game and type(leveledUp) == "table") then return false end
  local any = false
  for _ in pairs(leveledUp) do
    any = true
    break
  end
  if not any then return false end
  opts = type(opts) == "table" and opts or {}
  local warn = opts.warn
  local function note(fmt, ...)
    if type(warn) == "function" then warn(fmt, ...) end
  end

  if Gen.generation(game) == 2 then
    local outcome = result
    if outcome == "loss" then outcome = "lose" end
    if outcome == "lose" or outcome == "draw" then return false end
    return offerEvolutionsGen2(game, leveledUp, opts.ui, note)
  end

  local ok, Evolution = pcall(require, "src.pokemon.Evolution")
  if not (ok and type(Evolution) == "table"
      and type(Evolution.checkParty) == "function") then
    note("the engine's evolution module is unavailable, so POKéMON "
      .. "that levelled in this battle were not offered evolutions -- level "
      .. "again in a wild fight or use a RARE CANDY")
    return false
  end
  local ran, err = pcall(Evolution.checkParty, game, nil, leveledUp)
  if not ran then
    note("evolutions from this fight could not be offered (%s); "
      .. "level again in a wild fight or use a RARE CANDY", tostring(err))
    return false
  end
  return true
end

offerEvolutionsGen2 = function(game, leveledUp, ui, note)
  local ok, Evolution = pcall(require, "src.core.gen2.Evolution")
  if not (ok and type(Evolution) == "table"
      and type(Evolution.plan) == "function") then
    note("the engine's Gen 2 evolution module is unavailable, so "
      .. "POKéMON that levelled in this battle were not offered evolutions "
      .. "-- level again in a wild fight or use a RARE CANDY")
    return false
  end
  local party = game.save and game.save.party
  if type(party) ~= "table" then return false end
  local flags = {}
  local flagged = false
  for i, mon in ipairs(party) do
    if leveledUp[mon] then
      flags[i] = true
      flagged = true
    end
  end
  if not flagged then return false end
  local planned = Evolution.plan(game.data, party, flags,
    { timeOfDay = gen2Daytime() })
  if type(planned) ~= "table" or #planned == 0 then return false end
  if not (ui and type(ui.push) == "function") then
    note("could not open the evolution screen, so POKéMON that "
      .. "levelled in this battle were not offered evolutions -- level "
      .. "again in a wild fight or use a RARE CANDY")
    return false
  end

  local pending = {}
  for i, row in ipairs(planned) do pending[i] = row end
  local function nextOne()
    local row = table.remove(pending, 1)
    if not row then return end
    local pushed
    local ran = pcall(function()
      pushed = ui.push(game, "Gen2EvolutionAnim", {
        mon = row.mon,
        entry = row.entry,
        index = row.index,
        party = party,
        save = game.save,
        onDone = function()
          local stack = game.stack
          if stack and stack.pop then stack:pop() end
          nextOne()
        end,
      })
    end)
    if not (ran and type(pushed) == "table") then
      note("could not open the evolution screen for %s; it can still "
        .. "evolve by levelling again or with a RARE CANDY",
        tostring(row.mon and (row.mon.nickname or row.mon.species)))
      nextOne()
    end
  end
  nextOne()
  return true
end

return M
