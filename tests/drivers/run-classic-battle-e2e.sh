#!/usr/bin/env bash
#
# Classic 160×144 battle-chrome screenshot e2e.
#
# One LOVE instance, real ROM HUD / party icons / battle pics. Captures
# 1v1 + 2x2 + 3x3 frames and gates on classic_battle_shot.lua's GAPS:0.
#
#   bash mods/rby_mmo/tests/drivers/run-classic-battle-e2e.sh
#
# From the Gen1Recomp checkout root (mods/rby_mmo → this repo). Same ROM
# preflight as run-battlefield-e2e.sh.
set -uo pipefail
cd "$(dirname "$0")/../../../.." || exit 1
MOD_DIR="mods/rby_mmo"
OUT="mods/rby_mmo/tmp/e2e-classic"
mkdir -p "$OUT"

ENV_FILE="$MOD_DIR/.env"
# shellcheck source=/dev/null
. "$MOD_DIR/tools/env.sh"
load_env "$ENV_FILE"

fail() { echo "  !! $*" >&2; exit 2; }

command -v love >/dev/null 2>&1 || fail "love is not on PATH (brew install --cask love)"
[ -f main.lua ] || fail "run this from the Gen1Recomp checkout root"
[ -d "$MOD_DIR" ] || fail "$MOD_DIR is missing -- symlink the mod into mods/"

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
SHOT_LOG="$OUT/classic_battle_shot.log"

echo
echo "running classic_battle_shot.lua (one LOVE instance, real window)…"
echo "  shots: $SHOT_DIR"

if [ -n "${ROM_PATH:-}" ] && [ -f "$ROM_PATH" ]; then
  export POKEPORT_IMPORT_ROM="$ROM_PATH"
  export POKEPORT_VERSION="${ROM_VERSION:-red}"
fi

SHOT_DIR="$SHOT_DIR" POKEPORT_IDENTITY="classicui" POKEPORT_TOUCH=0 \
  POKEPORT_DRIVER="$MOD_DIR/tests/drivers/classic_battle_shot.lua" \
  love . >"$SHOT_LOG" 2>&1
shot_status=$?

echo
grep -E '^CLASSIC_SHOT:' "$SHOT_LOG" | sed 's/^/  /'

gaps=$(grep -o 'GAPS:[0-9]*' "$SHOT_LOG" | tail -1 | cut -d: -f2)
if [ "$shot_status" -ne 0 ] || [ -z "${gaps:-}" ] || [ "$gaps" -ne 0 ]; then
  echo
  echo "  RESULT: classic_battle_shot.lua FAILED (exit=$shot_status gaps=${gaps:-unknown})" >&2
  echo "  full log: $SHOT_LOG" >&2
  echo "  shots: $SHOT_DIR" >&2
  exit 1
fi
echo "  RESULT: classic_battle_shot.lua passed -- GAPS:0. Screenshots in $SHOT_DIR"
echo "OK — classic chrome screenshot driver green."
exit 0
