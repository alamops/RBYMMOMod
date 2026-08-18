#!/usr/bin/env bash
#
# Solo-battle e2e -- ONE LOVE instance, no sockets, both carts.
#
# The feature under test (src/SoloBattle.lua, the SOLO BATTLES row in the F10
# mod manager) is the one part of this mod that has nothing to do with the
# network: with the row on, an offline copy fights its ordinary wild
# encounters and its trainers on this mod's own battle screen, refereed
# in-process by src/BattleSim. So this driver is shaped like
# run-battlefield-e2e.sh -- the repo's other single-instance, ROM-backed
# driver -- and not like run-mmo-e2e.sh: no hub, no second window, no addr
# file, nothing to synchronise.
#
#   1. gates on the mod's headless Lua suite
#   2. writes an options.lua that enables the mod and **pre-seeds the SOLO
#      BATTLES row OFF**, so the driver's default-OFF leg is the same leg on a
#      dirty identity as on a fresh one
#   3. launches one LOVE per generation, driving
#      tests/drivers/solo_battle_e2e.lua, and gates on its GAPS: count
#
# From the Gen1Recomp checkout root (mods/rby_mmo -> this repo):
#
#   bash mods/rby_mmo/tests/drivers/run-solo-battle-e2e.sh          # both legs
#   bash mods/rby_mmo/tests/drivers/run-solo-battle-e2e.sh --gen1   # Red only
#   bash mods/rby_mmo/tests/drivers/run-solo-battle-e2e.sh --gen2   # Gold only
#
# .env (gitignored, see .env.example) -- and **its absence is not an error**:
#
#     ROM_PATH=/path/to/Poke Red.gb
#     ROM_VERSION=red
#     GOLD_ROM_PATH=/path/to/Pokemon Gold.gbc
#     GOLD_ROM_VERSION=gold
#
# A leg with no cache and no usable ROM **skips cleanly (exit 0)**, which is
# this repo's standing convention for every ROM-backed driver: CI has no
# cartridge and must not fail for not having one (README.md, "Both skip
# cleanly"). A run where both legs skip is a pass that says so in as many
# words -- it is never a silent green.
#
# Env knobs: SOLO_TIMEOUT (seconds per leg, default 900), SHOT_DIR (defaults
# to a **run-specific** directory -- two concurrent runs must not overwrite
# each other's screenshots), MMO_SOUND=1 to hear it.

set -uo pipefail

# ------------------------------------------------------------------ layout
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENGINE_ROOT=""
# An explicit override wins, and it is the one that matters when this mod is
# being developed in a worktree: the *shared* gen1recomp checkout has
# mods/rby_mmo pointing at the main clone, so a run started from a worktree
# path would load a copy of this mod that has no src/SoloBattle.lua in it. Point
# GEN1RECOMP_ROOT at a private engine view whose mods/rby_mmo is this branch.
if [ -n "${GEN1RECOMP_ROOT:-}" ] && [ -f "${GEN1RECOMP_ROOT}/main.lua" ]; then
  ENGINE_ROOT="$GEN1RECOMP_ROOT"
fi
probe="$SCRIPT_DIR"
for _ in 1 2 3 4 5 6 7 8; do
  [ -n "$ENGINE_ROOT" ] && break
  if [ -f "$probe/main.lua" ] && [ -d "$probe/mods" ]; then
    ENGINE_ROOT="$probe"
    break
  fi
  probe="$(dirname "$probe")"
done
if [ -z "$ENGINE_ROOT" ] && [ -f "$HOME/Projects/alamops/gen1recomp/main.lua" ]; then
  ENGINE_ROOT="$HOME/Projects/alamops/gen1recomp"
fi
if [ -z "$ENGINE_ROOT" ]; then
  echo "  !! could not find a Gen1Recomp checkout (main.lua + mods/)" >&2
  exit 2
fi
cd "$ENGINE_ROOT" || exit 1

MOD_DIR="mods/rby_mmo"
MOD_REAL="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUT="$MOD_DIR/tmp/e2e-solo-battle"
[ -d "$MOD_DIR" ] || OUT="$MOD_REAL/tmp/e2e-solo-battle"
mkdir -p "$OUT"

fail() { echo "  !! $*" >&2; exit 2; }

DRIVERS="$MOD_DIR/tests/drivers"
[ -f "$DRIVERS/solo_battle_e2e.lua" ] || DRIVERS="$MOD_REAL/tests/drivers"
DRIVER="$DRIVERS/solo_battle_e2e.lua"
[ -f "$DRIVER" ] || fail "missing solo_battle_e2e.lua beside this script"

# ------------------------------------------------------------------ args
WANT_GEN1=1
WANT_GEN2=1
for arg in "$@"; do
  case "$arg" in
    --gen1|--red|gen1|red) WANT_GEN1=1; WANT_GEN2=0 ;;
    --gen2|--gold|gen2|gold) WANT_GEN1=0; WANT_GEN2=1 ;;
    --both|both) WANT_GEN1=1; WANT_GEN2=1 ;;
    -h|--help)
      # Absolute: this script has already cd'd to the engine root, so a
      # relative $0 no longer resolves.
      sed -n '2,45p' "$SCRIPT_DIR/$(basename "$0")" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) fail "unknown argument: $arg (try --gen1, --gen2, --both)" ;;
  esac
done

# ------------------------------------------------------------------ .env
# Machine-local ROM paths live in .env (gitignored, and routinely absent from
# a fresh worktree). Prefer the linked mod's copy, fall back to this checkout,
# then the main project folder -- the same ladder run-mmo-e2e-gen2.sh walks.
# `load_env` is a no-op on a file that is not there, so a missing .env costs
# nothing here and is reported by the per-leg ROM checks below instead of
# dying obscurely at `love`.
ENV_FILE=""
for candidate in \
    "$MOD_DIR/.env" \
    "$MOD_REAL/.env" \
    "${RBY_MMO_ENV:-$HOME/Projects/alamops/RBYMMOMod/.env}"; do
  if [ -f "$candidate" ]; then
    ENV_FILE="$candidate"
    break
  fi
done

ENV_SH=""
for candidate in "$MOD_DIR/tools/env.sh" "$MOD_REAL/tools/env.sh"; do
  if [ -f "$candidate" ]; then
    ENV_SH="$candidate"
    break
  fi
done
if [ -n "$ENV_SH" ]; then
  # shellcheck source=/dev/null
  . "$ENV_SH"
  if [ -n "$ENV_FILE" ]; then
    load_env "$ENV_FILE" 2>/dev/null || true
    CANON_ENV="${RBY_MMO_ENV:-$HOME/Projects/alamops/RBYMMOMod/.env}"
    if [ -z "${GOLD_ROM_PATH:-}" ] && [ -f "$CANON_ENV" ] \
        && [ "$(cd "$(dirname "$CANON_ENV")" && pwd)" != "$MOD_REAL" ]; then
      load_env "$CANON_ENV" 2>/dev/null || true
    fi
  fi
else
  echo "  note: tools/env.sh not found; relying on the ambient environment"
fi

echo "  rby_mmo solo-battle e2e (one driven LOVE per generation, no network)"
echo "  engine: $ENGINE_ROOT"
if [ -n "$ENV_FILE" ]; then
  echo "  env: $ENV_FILE"
else
  echo "  env: none found (.env is gitignored; ROM_PATH/GOLD_ROM_PATH must be"
  echo "       in the environment, or the matching leg skips)"
fi

# ------------------------------------------------------------------ tools
# luajit and love are Homebrew/cask installs that are routinely not on a
# non-interactive PATH; MODKIT_LUAJIT is the documented override.
LUAJIT="${MODKIT_LUAJIT:-luajit}"
if ! command -v "$LUAJIT" >/dev/null 2>&1; then
  if [ -x /opt/homebrew/bin/luajit ]; then
    LUAJIT=/opt/homebrew/bin/luajit
  else
    fail "luajit is not on PATH (brew install luajit), and MODKIT_LUAJIT is unset"
  fi
fi

LOVE="${LOVE_BIN:-love}"
if ! command -v "$LOVE" >/dev/null 2>&1; then
  if [ -x /Applications/love.app/Contents/MacOS/love ]; then
    LOVE=/Applications/love.app/Contents/MacOS/love
  else
    fail "love is not on PATH (brew install --cask love), and LOVE_BIN is unset"
  fi
fi
[ -f main.lua ] || fail "run this from the Gen1Recomp checkout root"

# ------------------------------------------------------------- headless bar
# Same gate the battlefield driver sets: a red suite means the LOVE run would
# only be a slower way of learning the same thing.
SUITE="$MOD_DIR/tests/rby_mmo_test.lua"
[ -f "$SUITE" ] || SUITE="$MOD_REAL/tests/rby_mmo_test.lua"
echo
echo "  running the mod's Lua suite…"
if ! "$LUAJIT" "$SUITE" >"$OUT/suite.tail.txt" 2>&1; then
  tail -8 "$OUT/suite.tail.txt" >&2
  fail "headless suite failed -- see $OUT/suite.tail.txt"
fi
tail -1 "$OUT/suite.tail.txt" | sed 's/^/    /'

# ------------------------------------------------------------------ probe
# LOVE's save directory for an identity, so options.lua can be written before
# the game starts. Lifted from run-mmo-e2e-gen2.sh, which needs the same
# answer for the same reason: a sandboxed mod cannot enable itself.
RUN_ID="${SOLO_RUN_ID:-$$}"
TIMEOUT="${SOLO_TIMEOUT:-900}"
SHOT_ROOT="${SHOT_DIR:-/tmp/rby_mmo_solo_shots-$RUN_ID}"

PROBE="$(mktemp -d)"
cat > "$PROBE/conf.lua" <<'PROBE_CONF'
function love.conf(t)
  t.identity = os.getenv("POKEPORT_IDENTITY") or "pokemon-love2d"
  t.window = false
end
PROBE_CONF
cat > "$PROBE/main.lua" <<'PROBE_MAIN'
function love.load()
  print("SAVEDIR=" .. tostring(love.filesystem.getSaveDirectory()))
  love.event.quit()
end
PROBE_MAIN
cleanup_probe() { rm -rf "$PROBE"; }
trap cleanup_probe EXIT

save_dir_for() {
  POKEPORT_IDENTITY="$1" "$LOVE" "$PROBE" 2>/dev/null \
    | sed -n 's/^SAVEDIR=//p' | head -1
}

# Enable the mod for one throwaway identity, with SOLO BATTLES seeded OFF.
#
# Off, not on, and that is the point: the driver's first battle leg asserts
# that an untouched copy of this mod does **not** take the game's encounters,
# and it then flips the row through the mod manager's own row callback -- the
# thing a keypress on that row calls -- so the "no relaunch" half of the
# feature is exercised rather than assumed. Seeding the value explicitly (as
# opposed to leaving the key absent and trusting the schema default) is what
# makes that leg deterministic on an identity a previous run left dirty.
enable_mod_for() {
  local dir
  dir="$(save_dir_for "$1")"
  [ -n "$dir" ] || fail "could not determine LOVE's save directory for $1"
  mkdir -p "$dir"
  printf 'return { mods = { rby_mmo = true }, modOptions = { rby_mmo = { solo = false } } }\n' \
    > "$dir/options.lua"
  echo "$dir"
}

# Throwaway identities do not inherit play.sh's Gold extract; copy a known
# cache in so LOVE does not stall on the importer (or on a human).
seed_gold_cache() {
  local dest="$1/gold"
  [ -d "$dest/data/generated" ] && return 0
  local src=""
  for candidate in \
      "${HOME}/Library/Application Support/LOVE/rby-mmo-gold/gold" \
      "${HOME}/Library/Application Support/LOVE/rby-mmo-gold-import/gold" \
      "${ENGINE_ROOT}/gold"; do
    if [ -f "$candidate/data/generated/landmarks.lua" ]; then
      src="$candidate"
      break
    fi
  done
  if [ -n "$src" ]; then
    mkdir -p "$(dirname "$dest")"
    cp -R "$src" "$dest"
    echo "    seeded the Gold cache from $src"
  fi
}

# ------------------------------------------------------------------ one leg
#
# $1 = generation (1|2), $2 = label. Returns 0 pass, 1 fail, 3 skip.
run_leg() {
  local gen="$1" label="$2"
  local identity="soloe2e-g${gen}-${RUN_ID}"
  local shots="$SHOT_ROOT/gen$gen"
  local logfile="$OUT/solo-gen$gen.log"
  local save_dir=""

  echo
  echo "  ---- $label ----"

  if [ "$gen" = "2" ]; then
    command -v check_gold_rom_config >/dev/null 2>&1 && check_gold_rom_config
    local have_gold=0
    if command -v have_gold_cache >/dev/null 2>&1 \
       && have_gold_cache "$ENGINE_ROOT"; then
      have_gold=1
      echo "    gold cache: present"
    fi
    if [ "$have_gold" -ne 1 ]; then
      for marker in "gold/data/generated/landmarks.lua" \
                    "data/generated/gold/landmarks.lua"; do
        if [ -f "$marker" ]; then have_gold=1; echo "    gold cache: $marker"; break; fi
      done
    fi
    if [ "$have_gold" -ne 1 ]; then
      if [ -n "${GOLD_ROM_PATH:-}" ] && [ -f "$GOLD_ROM_PATH" ]; then
        echo "    no Gold cache yet; importing $(basename "$GOLD_ROM_PATH")"
        if ! POKEPORT_IDENTITY="rby-mmo-gold-solo-import-$RUN_ID" \
             POKEPORT_VERSION=gold \
             POKEPORT_IMPORT_ROM="$GOLD_ROM_PATH" \
             POKEPORT_IMPORT_ONLY=1 \
             "$LOVE" . ; then
          echo "    !! Gold import failed -- check GOLD_ROM_PATH is canonical" >&2
          echo "       US Gold (SHA-1 d8b8a3600a465308c9953dfa04f0081c05bdcb94)." >&2
          return 1
        fi
      else
        echo "    SKIP: no Gold cache and no usable GOLD_ROM_PATH."
        echo "          Set GOLD_ROM_PATH and GOLD_ROM_VERSION=gold in .env"
        return 3
      fi
    fi
  else
    command -v check_rom_config >/dev/null 2>&1 && { check_rom_config || return 1; }
    if [ ! -d data/generated ]; then
      if [ -n "${ROM_PATH:-}" ] && [ -f "$ROM_PATH" ]; then
        echo "    no game data yet; importing $(basename "$ROM_PATH") as ${ROM_VERSION:-red}"
        local py=.venv/bin/python3
        [ -x "$py" ] || py=python3
        if ! "$py" tools/build_data.py --rom "$ROM_PATH" \
             --version "${ROM_VERSION:-red}" --clean; then
          echo "    !! importing $ROM_PATH failed -- does ROM_VERSION match?" >&2
          return 1
        fi
      else
        echo "    SKIP: no data/generated, and no usable ROM_PATH."
        echo "          Set ROM_PATH (and ROM_VERSION) in .env -- see"
        echo "          .env.example -- or import once with:"
        echo "            scripts/setup.sh --rom \"/path/to/rom.gb\""
        return 3
      fi
    fi
  fi

  save_dir="$(enable_mod_for "$identity")"
  echo "    enabled rby_mmo (SOLO BATTLES seeded OFF) in $save_dir"
  mkdir -p "$shots"
  rm -f "$logfile"

  # A ROM_PATH is not optional even with a cache present: a *fresh* LOVE
  # identity that cannot find one stalls forever on the ROM picker, and an
  # e2e that stalls on a picker looks exactly like an e2e that hung.
  local -a envs=()
  if [ "$gen" = "2" ]; then
    seed_gold_cache "$save_dir"
    envs+=("POKEPORT_VERSION=gold")
    if [ -n "${GOLD_ROM_PATH:-}" ] && [ -f "$GOLD_ROM_PATH" ]; then
      envs+=("POKEPORT_IMPORT_ROM=$GOLD_ROM_PATH")
    fi
  else
    envs+=("POKEPORT_VERSION=${ROM_VERSION:-red}")
    if [ -n "${ROM_PATH:-}" ] && [ -f "$ROM_PATH" ]; then
      envs+=("POKEPORT_IMPORT_ROM=$ROM_PATH")
    fi
  fi

  echo "    driver: $DRIVER"
  echo "    shots:  $shots"
  echo "    budget: ${TIMEOUT}s"

  # stdbuf is GNU coreutils and is not on every mac; without it the log is
  # block-buffered, which only costs liveness while the run is in flight.
  # Spelled as two branches rather than an optional array: expanding an empty
  # array under `set -u` is an unbound-variable error on bash 3.2, which is
  # what /usr/bin/env bash still resolves to on a stock mac.
  if command -v stdbuf >/dev/null 2>&1; then
    env "${envs[@]}" \
        SHOT_DIR="$shots" \
        POKEPORT_IDENTITY="$identity" \
        POKEPORT_TOUCH=0 \
        POKEPORT_DRIVER="$DRIVER" \
        stdbuf -oL -eL "$LOVE" . >"$logfile" 2>&1 &
  else
    env "${envs[@]}" \
        SHOT_DIR="$shots" \
        POKEPORT_IDENTITY="$identity" \
        POKEPORT_TOUCH=0 \
        POKEPORT_DRIVER="$DRIVER" \
        "$LOVE" . >"$logfile" 2>&1 &
  fi
  local pid=$!

  local waited=0
  while [ "$waited" -lt "$TIMEOUT" ]; do
    kill -0 "$pid" 2>/dev/null || break
    grep -q 'SOLO_E2E:.*DONE' "$logfile" 2>/dev/null && break
    sleep 1
    waited=$((waited + 1))
  done
  local timed_out=0
  if kill -0 "$pid" 2>/dev/null; then
    if ! grep -q 'SOLO_E2E:.*DONE' "$logfile" 2>/dev/null; then
      timed_out=1
      echo "    !! no DONE after ${TIMEOUT}s -- killing the instance" >&2
    fi
    kill "$pid" 2>/dev/null
  fi
  wait "$pid" 2>/dev/null
  local status=$?

  echo
  grep -E '^SOLO_E2E:|TIMEOUT' "$logfile" | sed 's/^/    /'

  local gaps
  gaps=$(grep -o 'GAPS:[0-9]*' "$logfile" | tail -1 | cut -d: -f2)

  # The identity is throwaway; the shots are not.
  [ -n "$save_dir" ] && rm -rf "$save_dir"

  if [ "$timed_out" -eq 1 ]; then
    echo
    echo "    RESULT: $label TIMED OUT after ${TIMEOUT}s" >&2
    tail -30 "$logfile" | sed 's/^/      /' >&2
    echo "    full log: $logfile" >&2
    return 1
  fi
  if [ -z "${gaps:-}" ]; then
    echo
    echo "    RESULT: $label produced no verdict (exit=$status)" >&2
    tail -30 "$logfile" | sed 's/^/      /' >&2
    echo "    full log: $logfile" >&2
    return 1
  fi
  if [ "$gaps" -ne 0 ]; then
    echo
    echo "    RESULT: $label FAILED -- $gaps assertion(s)" >&2
    echo "    full log: $logfile" >&2
    return 1
  fi
  echo "    RESULT: $label passed -- GAPS:0. Screenshots in $shots"
  rm -f "$logfile"
  return 0
}

# ------------------------------------------------------------------ run
ran=0
failed=0
skipped=0

if [ "$WANT_GEN1" -eq 1 ]; then
  run_leg 1 "Gen 1 (${ROM_VERSION:-red})"
  case $? in
    0) ran=$((ran + 1)) ;;
    3) skipped=$((skipped + 1)) ;;
    *) failed=$((failed + 1)) ;;
  esac
fi

if [ "$WANT_GEN2" -eq 1 ]; then
  run_leg 2 "Gen 2 (gold)"
  case $? in
    0) ran=$((ran + 1)) ;;
    3) skipped=$((skipped + 1)) ;;
    *) failed=$((failed + 1)) ;;
  esac
fi

echo
if [ "$failed" -ne 0 ]; then
  echo "  RESULT: solo-battle e2e FAILED ($failed leg(s); $ran passed, $skipped skipped)"
  exit 1
fi
if [ "$ran" -eq 0 ]; then
  echo "  SKIP: no leg had a cache or a usable ROM, so nothing was driven."
  echo "        This is a clean skip, not a pass: set ROM_PATH (and"
  echo "        GOLD_ROM_PATH) in .env and run it again to actually prove"
  echo "        anything about solo battles."
  exit 0
fi
echo "  OK — suite green; solo battles driven on $ran generation(s)" \
     "($skipped skipped). Screenshots under $SHOT_ROOT"
exit 0
