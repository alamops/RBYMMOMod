#!/usr/bin/env bash
#
# Battlefield theatre + CLASSIC BATTLE UI e2e, **Gen 3** (FireRed, Emerald).
#
# The Gen 1 / Gen 2 siblings are run-battlefield-e2e.sh / -gen2.sh. Same two
# drivers, their Gen 3 arms: tests/drivers/battlefield_shot.lua stages the
# 640x360 arena (1v1 idle, a hit, 2v2, an NPC trainer's pic, the POKeMON list,
# the solo double: one player behind two seats, the trainer behind two foes)
# and tests/drivers/classic_battle_shot.lua the cart's own 240x160 battle page
# (1v1, the move menu, 2v2 guild focus, the POKeMON page, the bag, a trainer
# intro, and the GBA double screen: chooser, move-target previews, the target
# blink, START HP figures, empty seats). Both pixel-assert what they draw and
# gate on GAPS:0.
#
#   1. Runs the mod's Lua suite headlessly (the same bar the other scripts set)
#   2. For each game (GEN3_GAME=firered|emerald|both, default both): seeds a
#      throwaway LOVE identity from an already-imported cache (copied, never
#      re-imported -- tools/env.sh seed_gen3_cache, or the imported identities
#      rby-mmo-g3-import-{fr,em}), launches one real LOVE instance per driver
#      and gates on its verdict
#   3. Leaves every PNG in SHOT_DIR (default /tmp/rby_mmo_bf_gen3_shots-<run>),
#      named g3-<fr|em>-<frame>.png, and the driver logs in SHOT_DIR/logs
#      (E2E_LOG_DIR overrides) -- nothing is written into the checkout
#
# From the Gen1Recomp checkout root (mods/rby_mmo -> this repo), or a private
# engine view with the same shape:
#
#   bash mods/rby_mmo/tests/drivers/run-battlefield-e2e-gen3.sh
#   GEN3_GAME=emerald SHOT_DIR=/tmp/em bash mods/rby_mmo/tests/drivers/run-battlefield-e2e-gen3.sh
#
# .env (see .env.example), same contract as run-mmo-e2e-gen3.sh:
#
#     FIRE_RED_ROM_PATH=/path/to/Pokemon FireRed.gba
#     EMERALD_ROM_PATH=/path/to/Pokemon Emerald.gba
#
# **Exits 0 when a game has no imported cache and no usable ROM path** -- the
# clean skip every generation-specific driver here honours; CI has no ROM.
# The screen must be unlocked: LOVE stops presenting frames on a locked Mac
# and a driver then waits forever for a screenshot.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENGINE_ROOT=""
probe="$SCRIPT_DIR"
for _ in 1 2 3 4 5 6 7 8; do
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
  echo "  !! could not find Gen1Recomp checkout (main.lua + mods/)" >&2
  exit 2
fi
cd "$ENGINE_ROOT" || exit 1

MOD_DIR="mods/rby_mmo"
MOD_REAL="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUN_ID="${MMO_RUN_ID:-$$}"
SHOT_DIR="${SHOT_DIR:-/tmp/rby_mmo_bf_gen3_shots-$RUN_ID}"
mkdir -p "$SHOT_DIR"
# Logs beside the shots, outside the checkout: a ROM-booted log is scratch.
OUT="${E2E_LOG_DIR:-$SHOT_DIR/logs}"
mkdir -p "$OUT"

fail() { echo "  !! $*" >&2; exit 2; }

# ---------------------------------------------------------------- .env
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
: "${ENV_FILE:=$MOD_DIR/.env}"

ENV_SH=""
if [ -f "$MOD_DIR/tools/env.sh" ]; then
  ENV_SH="$MOD_DIR/tools/env.sh"
elif [ -f "$MOD_REAL/tools/env.sh" ]; then
  ENV_SH="$MOD_REAL/tools/env.sh"
fi
if [ -n "$ENV_SH" ]; then
  # shellcheck source=/dev/null
  . "$ENV_SH"
  load_env "$ENV_FILE" 2>/dev/null || true
fi

echo "  rby_mmo Gen 3 battlefield + classic e2e (one driven LOVE instance per driver)"
echo "  engine: $ENGINE_ROOT"
echo "  env: $ENV_FILE"

# ------------------------------------------------------------- headless bar
echo
echo "  running the mod's Lua suite…"
LUAJIT="${MODKIT_LUAJIT:-luajit}"
if ! command -v "$LUAJIT" >/dev/null 2>&1; then
  if [ -x /opt/homebrew/bin/luajit ]; then
    LUAJIT=/opt/homebrew/bin/luajit
  else
    fail "luajit is not on PATH (brew install luajit), and MODKIT_LUAJIT is unset"
  fi
fi
if ! "$LUAJIT" "$MOD_DIR/tests/rby_mmo_test.lua" >"$OUT/suite.tail.txt" 2>&1; then
  tail -5 "$OUT/suite.tail.txt" >&2
  fail "headless suite failed -- see $OUT/suite.tail.txt"
fi
tail -1 "$OUT/suite.tail.txt" | sed 's/^/    /'

# ------------------------------------------------------------- LOVE
LOVE_BIN="${LOVE_BIN:-}"
if [ -z "$LOVE_BIN" ]; then
  if command -v love >/dev/null 2>&1; then
    LOVE_BIN="$(command -v love)"
  elif [ -x /Applications/love.app/Contents/MacOS/love ]; then
    LOVE_BIN=/Applications/love.app/Contents/MacOS/love
  else
    fail "love is not on PATH (brew install --cask love)"
  fi
fi
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN="gtimeout"
elif [ -x /opt/homebrew/bin/timeout ]; then
  TIMEOUT_BIN=/opt/homebrew/bin/timeout
fi
RUN_TIMEOUT="${RUN_TIMEOUT:-420}"

LOVE_HOME="$HOME/Library/Application Support/LOVE"
if [ ! -d "$LOVE_HOME" ] && [ -n "${XDG_DATA_HOME:-}" ]; then
  LOVE_HOME="$XDG_DATA_HOME/love"
fi

GAMES="${GEN3_GAME:-both}"
case "$GAMES" in
  both) GAMES="firered emerald" ;;
  firered|emerald|leafgreen) ;;
  *) fail "GEN3_GAME must be firered, emerald, leafgreen or both (got $GAMES)" ;;
esac

short_of() {
  case "$1" in
    firered) echo fr ;;
    leafgreen) echo lg ;;
    emerald) echo em ;;
  esac
}

# The cache for one game, copied into a throwaway identity: tools/env.sh's
# seed_gen3_cache when this checkout has it, else the imported identity
# rby-mmo-g3-import-<fr|em> by hand. The identity also gets the imported
# identity's options (the mod list, and the cart settings the import chose).
seed_identity() {
  local game="$1" ident="$2" short src
  short="$(short_of "$game")"
  local dest="$LOVE_HOME/$ident"
  rm -rf "$dest"
  mkdir -p "$dest"
  if command -v seed_gen3_cache >/dev/null 2>&1; then
    seed_gen3_cache "$dest" "$game" "$ENGINE_ROOT" >/dev/null 2>&1 || true
  fi
  if [ ! -f "$dest/$game/rom-cache.complete" ]; then
    src="$LOVE_HOME/rby-mmo-g3-import-$short/$game"
    if [ -f "$src/rom-cache.complete" ]; then
      cp -cR "$src" "$dest/$game" 2>/dev/null || cp -R "$src" "$dest/$game" || return 1
    fi
  fi
  local opts="$LOVE_HOME/rby-mmo-g3-import-$short"
  for f in options.lua mod_option_schemas.json; do
    if [ -f "$opts/$f" ]; then cp "$opts/$f" "$dest/$f"; fi
  done
  [ -f "$dest/$game/rom-cache.complete" ]
}

import_identity() {
  local game="$1" ident="$2" rom
  rom=""
  if command -v gen3_rom_path >/dev/null 2>&1; then rom="$(gen3_rom_path "$game")"; fi
  if [ -z "$rom" ] || [ ! -f "$rom" ]; then return 1; fi
  echo "  no imported $game cache; importing $(basename "$rom") (one-time)"
  POKEPORT_IDENTITY="$ident" POKEPORT_VERSION="$game" \
    POKEPORT_IMPORT_ROM="$rom" POKEPORT_IMPORT_ONLY=1 "$LOVE_BIN" . >/dev/null 2>&1
  [ -f "$LOVE_HOME/$ident/$game/rom-cache.complete" ]
}

# One driver on one game; echoes the driver's tagged lines and returns its gaps.
run_driver() {
  local game="$1" driver="$2" tag="$3" ident="$4" log="$5"
  echo
  echo "  $game: $(basename "$driver") (identity $ident)"
  local cmd=( "$LOVE_BIN" . )
  if [ -n "$TIMEOUT_BIN" ]; then cmd=( "$TIMEOUT_BIN" "$RUN_TIMEOUT" "$LOVE_BIN" . ); fi
  SHOT_DIR="$SHOT_DIR" POKEPORT_IDENTITY="$ident" POKEPORT_VERSION="$game" \
    POKEPORT_TOUCH=0 POKEPORT_DRIVER="$driver" "${cmd[@]}" >"$log" 2>&1
  local status=$?
  grep -E "^$tag" "$log" | grep -E 'FAIL|GAPS|SUMMARY|captured' | sed 's/^/    /'
  local gaps
  gaps=$(grep -o 'GAPS:[0-9]*' "$log" | tail -1 | cut -d: -f2)
  if [ "$status" -ne 0 ] || [ -z "${gaps:-}" ] || [ "$gaps" -ne 0 ]; then
    echo "    RESULT: FAILED (exit=$status gaps=${gaps:-unknown}) -- full log: $log" >&2
    return 1
  fi
  echo "    RESULT: GAPS:0"
  return 0
}

failed=0
ran=0
for game in $GAMES; do
  short="$(short_of "$game")"
  ident="rby-mmo-bf3-$short-$RUN_ID"
  if ! seed_identity "$game" "$ident"; then
    if ! import_identity "$game" "$ident"; then
      echo
      echo "  SKIP $game: no imported cache (rby-mmo-g3-import-$short) and no usable"
      echo "       $(command -v gen3_rom_key >/dev/null 2>&1 && gen3_rom_key "$game" || echo ROM path) in $ENV_FILE"
      rm -rf "${LOVE_HOME:?}/$ident"
      continue
    fi
  fi
  ran=$((ran + 1))
  run_driver "$game" "$MOD_DIR/tests/drivers/battlefield_shot.lua" "BF_SHOT:" \
    "$ident" "$OUT/battlefield_shot-$short.log" || failed=$((failed + 1))
  run_driver "$game" "$MOD_DIR/tests/drivers/classic_battle_shot.lua" "CLASSIC_SHOT:" \
    "$ident" "$OUT/classic_battle_shot-$short.log" || failed=$((failed + 1))
  if [ "${KEEP_IDENTITY:-0}" != "1" ]; then rm -rf "${LOVE_HOME:?}/$ident"; fi
done

echo
if [ "$ran" -eq 0 ]; then
  echo "  SKIP: no Gen 3 cache for $GAMES. Import one once (scripts/setup.sh or"
  echo "        POKEPORT_IMPORT_ROM with POKEPORT_VERSION=<game>) and re-run."
  exit 0
fi
if [ "$failed" -ne 0 ]; then
  echo "  RESULT: $failed Gen 3 driver run(s) FAILED. Screenshots in $SHOT_DIR" >&2
  exit 1
fi
echo "  RESULT: every Gen 3 arena / classic driver passed -- GAPS:0."
echo "          Screenshots in $SHOT_DIR"
exit 0
