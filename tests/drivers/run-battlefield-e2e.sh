#!/usr/bin/env bash
#
# Battlefield theatre e2e (Gen1 top-down arena).
#
#   1. Confirms the arena asset packs with the mod
#   2. Runs the battlefield-related Lua suite headlessly
#   3. Launches one real LOVE instance, drives tests/drivers/battlefield_shot.lua
#      (a committed, pixel-asserting screenshot driver — see that file for
#      what it captures and checks) and gates the script on its verdict.
#      Round 2: six frames -- idle/action (dark-slate plates + modern
#      FIGHT/PKMN/ITEM/RUN band chrome, trainer color, ally-mon flip), move
#      (the drawListPanel MOVES list), ball (a throw mid-arc, target seat
#      hidden via Battlefield.fxSeat), bubble (a rounded callout with
#      moveName), and nire (SELF switched to SPRITE_NIRE via a real
#      Cast.install(), pinning the walk-sheet requantize fix).
#   4. Optionally forwards to run-hub-e2e.sh when --play is passed
#
# From the Gen1Recomp checkout root (mods/rby_mmo → this repo):
#
#   bash mods/rby_mmo/tests/drivers/run-battlefield-e2e.sh
#   bash mods/rby_mmo/tests/drivers/run-battlefield-e2e.sh --play
#
# Requires a ROM already imported (scripts/setup.sh --rom ...) or ROM_PATH
# set in mods/rby_mmo/.env — same convention as run-mmo-e2e.sh, whose
# preflight/import block this mirrors for a single LOVE instance instead of
# a host+guest pair.
set -uo pipefail
cd "$(dirname "$0")/../../../.." || exit 1
MOD_DIR="mods/rby_mmo"
ARENA="$MOD_DIR/assets/battle/outdoor_grass_arena.png"
OUT="mods/rby_mmo/tmp/e2e-battlefield"
mkdir -p "$OUT"

if [[ ! -f "$ARENA" ]]; then
  echo "missing arena asset: $ARENA" >&2
  exit 1
fi

# Asset sanity (packed with the mod; not under docs/screenshots).
bytes=$(wc -c < "$ARENA" | tr -d ' ')
echo "arena: $ARENA ($bytes bytes)"
if [[ "$bytes" -gt 2000000 ]]; then
  echo "warn: arena PNG is large (>2MB); consider re-encoding before pack" >&2
fi

# Headless layout smoke via the mod suite subset is the automated bar today.
echo "running battlefield-related Lua suite…"
if ! luajit "$MOD_DIR/tests/rby_mmo_test.lua" | tee "$OUT/suite.tail.txt" | tail -5; then
  echo "  !! headless suite failed -- see $OUT/suite.tail.txt" >&2
  exit 1
fi

# ---------------------------------------------------------------- .env
ENV_FILE="$MOD_DIR/.env"
# shellcheck source=/dev/null
. "$MOD_DIR/tools/env.sh"
load_env "$ENV_FILE"

fail() { echo "  !! $*" >&2; exit 2; }

command -v love >/dev/null 2>&1 || fail "love is not on PATH (brew install --cask love)"
[ -f main.lua ] || fail "run this from the Gen1Recomp checkout root"

if [ ! -d data/generated ]; then
  if [ -n "${ROM_PATH:-}" ] && [ -f "$ROM_PATH" ]; then
    echo "  no game data yet; importing $(basename "$ROM_PATH") as ${ROM_VERSION:-red}"
    PY=.venv/bin/python3
    [ -x "$PY" ] || PY=python3
    if ! "$PY" tools/build_data.py --rom "$ROM_PATH" \
        --version "${ROM_VERSION:-red}" --clean; then
      fail "importing $ROM_PATH failed -- check ROM_VERSION matches the ROM"
    fi
  else
    fail "no data/generated, and no usable ROM_PATH.
     Set ROM_PATH (and ROM_VERSION) in $ENV_FILE -- see .env.example --
     or import once with: scripts/setup.sh --rom \"/path/to/rom.gb\""
  fi
fi
check_rom_config || exit 2

SHOT_DIR="${SHOT_DIR:-$(mktemp -d)}"
mkdir -p "$SHOT_DIR"
SHOT_LOG="$OUT/battlefield_shot.log"

echo
echo "running battlefield_shot.lua (one LOVE instance, real window)…"
echo "  shots: $SHOT_DIR"

if [ -n "${ROM_PATH:-}" ] && [ -f "$ROM_PATH" ]; then
  export POKEPORT_IMPORT_ROM="$ROM_PATH"
  export POKEPORT_VERSION="${ROM_VERSION:-red}"
fi

SHOT_DIR="$SHOT_DIR" POKEPORT_IDENTITY="bfe2e" POKEPORT_TOUCH=0 \
  POKEPORT_DRIVER="$MOD_DIR/tests/drivers/battlefield_shot.lua" \
  love . >"$SHOT_LOG" 2>&1
shot_status=$?

echo
grep -E '^BF_SHOT:' "$SHOT_LOG" | sed 's/^/  /'

gaps=$(grep -o 'GAPS:[0-9]*' "$SHOT_LOG" | tail -1 | cut -d: -f2)
if [ "$shot_status" -ne 0 ] || [ -z "${gaps:-}" ] || [ "$gaps" -ne 0 ]; then
  echo
  echo "  RESULT: battlefield_shot.lua FAILED (exit=$shot_status gaps=${gaps:-unknown})" >&2
  echo "  full log: $SHOT_LOG" >&2
  exit 1
fi
echo "  RESULT: battlefield_shot.lua passed -- GAPS:0. Screenshots in $SHOT_DIR"
rm -f "$SHOT_LOG"

echo
echo "Live playtest checklist (owner):"
echo "  docs/plans/coop-battlefield-layout.md §5"
echo

if [[ "${1:-}" == "--play" ]]; then
  echo "forwarding to hub e2e for a live two-client fight…"
  exec bash "$MOD_DIR/tests/drivers/run-hub-e2e.sh"
fi

echo "OK — asset present; suite green; battlefield screenshot driver green."
exit 0
