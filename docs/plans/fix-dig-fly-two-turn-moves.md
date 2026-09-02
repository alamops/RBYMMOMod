# Plan — Two-turn charge / vanish moves (Dig, Fly, and family)

| Field | Value |
| --- | --- |
| Date | 2026-08-31 |
| Source | User: Dig/Fly (and other >1-turn moves) broken — vanish anims, two turns, hits-while-hidden, gen1+gen2, e2e |
| Config | AGENTS_CONFIG.yml (quality) |
| Flags | none (grill questions skipped — recommended defaults locked) |
| Gates | self-resolved after skipped grill |
| Branch | fix/fix-dig-fly |
| Base SHA | set at implement start on fix/fix-dig-fly |

## 1. Objective & success criteria

Two-turn charge moves work in mediated BattleSim **and** look right on the top-down battlefield, in Gen 1 and Gen 2.

- **Vanish family:** Dig slides down and stays gone; Fly lifts off and stays gone; both reappear on the hitting turn.
- **Charge family (stay visible):** SolarBeam, Skull Bash, Razor Wind, Sky Attack — turn-one setup text, no damage, no second PP spend, turn-two hit.
- **Invuln exceptions (per generation):**
  - Gen 1: Swift hits Fly/Dig; Thunder hits Fly; Earthquake/Fissure miss Dig (cartridge).
  - Gen 2: engine `FLY_DIG_EXCEPTIONS` — Fly ← Gust/Whirlwind/Thunder/Twister; Dig ← Earthquake/Fissure/Magnitude. Swift does **not** hit.
- **Upload:** Gen 2 `EFFECT_FLY` / `EFFECT_SOLARBEAM` / … map onto charge/fly so Gold fights actually two-turn.
- **E2e:** headless BattleSim (+ JS twin) owns semantics; `battlefield_shot.lua` owns vanish pixels. No new harness.

## 2. Context & constraints

- C4 already implements CHARGE (39) / FLY (43) two-turn + forced release + PP skip (`src/BattleSim/Turn.lua:2384`, twins). Dig is **not** special-cased: engine treats Dig as CHARGE + `move.id == "DIG"` for invuln + “dug a hole” + `SLIDE_DOWN_ANIM` (`gen1recomp` `BattleState.lua:4266-4273`).
- Invuln gate is absolute (`Turn.lua:2401`) — no Thunder/Swift/EQ exceptions.
- `chargeMessage` says “flew up high” for every effect 43 and “is glowing” otherwise — Dig talks like Fly.
- Theatre: `HIDEPIC` / `fxSeat.hidden` are ball-catch only. DIG/FLY anims lunge + type VFX; seat stays drawn. CoopField only *clears* hide on cancel, never sets it.
- Gen 2 upload is broken: `MediatedBattle.moveOf` calls Gen1 `Effects.idOf`; `EFFECT_FLY` → 0 → one-turn hit. BattleSim2 still has the Gen1 87-slot table.
- Legal: original Battlefield/Vfx only — no ROM `battle_anims`.
- Peer `misty-sand-db32` has claimed `src/BattleSim` + `src/MediatedBattle.lua` on another branch (learn-move). This worktree is isolated; no steal.

## 3. Approach & key decisions

- **Dig vanish** keys off `move.id == "DIG"` (engine), not effect 43 alone. Store `charging.moveId` for exception lookup.
- **Charge-turn `anim.amount = 1`** (existing field; SHAKE_ANIM uses it for shakes). Client: amount==1 + DIG/FLY → persist hide; amount==1 + charge-only → self glow; release anim (no amount) → emerge + strike.
- **Gen 2 `idOf` aliases** map `EFFECT_FLY` → 43 and `EFFECT_SOLARBEAM|SKULL_BASH|RAZOR_WIND|SKY_ATTACK` → 39. Do not grow the 87-slot `NAMES` table.
- **`moveOf(..., generation)`** uses `effectsFor` so Gold sheets get those aliases.
- **Hide persistence** copies `ballFlow` / `BALL_HIDE_FX`: hold finished `dig`/`fly` fx at `t==1` until release/faint/switch.
- **No Hyper Beam work** (already implemented). No Dive/Bounce (Gen 3). Gen 2 EQ 2× vs Dig deferred (engine Damage.lua has no hook; hits-while-hidden is the ask).

## 4. Work breakdown — implementation

| ID | Goal | Files | Depends | Acceptance |
| --- | --- | --- | --- | --- |
| S1 | Gen1 charge text, Dig invuln, hitsInvulnerable, charging.moveId | `src/BattleSim/Effects.lua`, `src/BattleSim/Turn.lua` | — | Dig vanishes + “dug a hole”; Swift/Thunder exceptions; EQ misses Dig |
| S2 | Gen2 aliases + FLY_DIG_EXCEPTIONS | `src/BattleSim2/Effects.lua`, `src/BattleSim2/Turn.lua` | S1 contract | `idOf("EFFECT_FLY")==43`; Gen2 exception table |
| S3 | JS twins | `server/lib/battle/{Effects,Turn}.js`, `server/lib/battle2/{Effects,Turn}.js` | S1/S2 | Lua↔JS event parity |
| T1 | Seat kinds dig/fly/emerge | `src/Battlefield.lua` | — | `fxSeat` slides then `hidden`; draw skip |
| T2 | DIG/FLY self VFX; charge-only self glow | `src/Vfx.lua` | — | Charge is self, not foe projectile |
| T3 | Persist hide + amount==1; Gen2 upload | `src/MediatedBattle.lua` | T1 | Seat stays hidden across foe turn; `moveOf` uses gen Effects |
| T4 | Same vanish on host-sim theatre | `src/CoopBattle.lua` | T1 | Coop battlefield matches mediated |

## 5. Work breakdown — tests

| ID | Layer | Covers | ROM? |
| --- | --- | --- | --- |
| U1 | `tests/battle_sim_turn.lua` | Charge family texts; Fly/Dig invuln; Swift hits both; Thunder hits Fly; EQ misses Dig; PP once | No |
| U2 | `tests/battle_sim2_turn.lua` | `idOf` aliases; Gen2 exceptions (Gust/EQ hit, Swift misses) | No |
| U3 | JS `server/battle_turn.test.js` / `battle2_turn.test.js` | Mirror U1/U2 | No |
| E1 | `tests/drivers/battlefield_shot.lua` | DIG hide (empty seat pixels); FLY hide; emerge reappear | Yes (existing wrapper) |
| P1 | Regen parity JSON only if RNG draw sites move | `battle_turn_parity` / `battle2_turn_parity` | No |

E2e applies. Recipe: `bash mods/rby_mmo/tests/drivers/run-battlefield-e2e.sh` (+ `-gen2.sh`). Solo/mmo mash e2e is **not** the owner of these asserts.

## 6. Execution waves

1. S1+S2+S3 (semantics, lockstep twins) then T1–T4 (theatre).
2. Tests U1–U3 + E1 after impl.

## 7. Blast radius

Forced-choice injection, switch/faint clear of charging, ball-flow hide (must not share kinds), twin parity fixtures if accuracy draws move, `moveOf` metronome pool path.

## 8. Open questions / assumptions (skipped grill)

| Question | Answer | Source | Confidence |
| --- | --- | --- | --- |
| Gen1 EQ vs Dig? | Cart miss (not Stadium hit) | engine + pret | high |
| Gen2 exceptions? | Copy engine `FLY_DIG_EXCEPTIONS` | `gen2/Effects.lua:168` | high |
| Charge-only in scope? | Yes — two-turn + texts + e2e, stay visible | user “all types” | high |
| Visual? | Slide + persist hide | user Dig/Fly description | high |
| Hyper Beam / Dive? | Out — already works / Gen 3 | judgment | high |
| EQ 2× vs Dig in Gen2? | Deferred | no engine Damage hook found | medium |

## 9. Completeness ledger

Not `--no-follow-ups`. Deferred: Gen2 EQ/Magnitude double damage vs Dig; live LOVE mash e2e seeding Dig.
