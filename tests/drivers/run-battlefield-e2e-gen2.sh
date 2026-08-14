#!/usr/bin/env bash
#
# Battlefield theatre e2e, **Gold** (Gen 2 top-down arena).
#
# The Gen 1 sibling is run-battlefield-e2e.sh, and this is deliberately the
# same driver on a different boot rather than a second driver: since
# docs/plans/gen2-new-battle-system.md the theatre is not a Gen 1 feature, so
# the thing worth proving is that ONE screenshot driver passes its own pixel
# assertions on both carts. `battlefield_shot.lua` resolves its looks through
# `Gen.defaultSprite`, its species through the live dex, and boots through
# `mmo_util.bootToPlay` -- all three of which answer per generation.
#
#   1. Confirms the arena asset packs with the mod
#   2. Runs the mod's Lua suite headlessly (the same bar the Gen 1 script sets)
#   3. Imports the Gold cache when it is absent and a GOLD_ROM_PATH is set,
#      then launches one real LOVE instance on Gold, drives
#      tests/drivers/battlefield_shot.lua, and gates on its verdict
#
# From the Gen1Recomp checkout root (mods/rby_mmo → this repo):
#
#   bash mods/rby_mmo/tests/drivers/run-battlefield-e2e-gen2.sh
#
# .env (see .env.example), same contract as run-mmo-e2e-gen2.sh:
#
#     GOLD_ROM_PATH=/path/to/Pokemon Gold.gbc
#     GOLD_ROM_VERSION=gold
#
# **Exits 0 when there is no Gold cache and no usable GOLD_ROM_PATH**, the same
# clean-skip every Gen 2 driver in this folder honours: CI has no ROM and must
# not fail for not having one. A skip says so in as many words.
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
ARENA="$MOD_DIR/assets/battle/outdoor_grass_arena.png"
OUT="$MOD_DIR/tmp/e2e-battlefield-gen2"
mkdir -p "$OUT"

fail() { echo "  !! $*" >&2; exit 2; }

# ---------------------------------------------------------------- .env
# Machine-local ROM paths live in .env (gitignored). Prefer the linked mod's
# copy, fall back to this checkout, then the main project folder -- agetor
# worktrees often lack a private .env. Same ladder as run-mmo-e2e-gen2.sh.
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
  CANON_ENV="${RBY_MMO_ENV:-$HOME/Projects/alamops/RBYMMOMod/.env}"
  if [ -z "${GOLD_ROM_PATH:-}" ] && [ -f "$CANON_ENV" ] \
      && [ "$(cd "$(dirname "$CANON_ENV")" && pwd)" != "$MOD_REAL" ]; then
    load_env "$CANON_ENV" 2>/dev/null || true
  fi
fi

echo "  rby_mmo Gen 2 battlefield e2e (Gold, one driven LOVE instance)"
echo "  engine: $ENGINE_ROOT"
echo "  env: $ENV_FILE"

# ------------------------------------------------------------- asset sanity
if [ ! -f "$ARENA" ]; then
  fail "missing arena asset: $ARENA"
fi
bytes=$(wc -c < "$ARENA" | tr -d ' ')
echo "  arena: $ARENA ($bytes bytes)"

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

# ------------------------------------------------------------- Gold preflight
command -v love >/dev/null 2>&1 || fail "love is not on PATH (brew install --cask love)"
[ -f main.lua ] || fail "run this from the Gen1Recomp checkout root"
command -v check_gold_rom_config >/dev/null 2>&1 && check_gold_rom_config || true

RUN_ID="${MMO_RUN_ID:-$$}"

have_gold=0
if command -v have_gold_cache >/dev/null 2>&1 && have_gold_cache "$ENGINE_ROOT"; then
  have_gold=1
  echo "  gold cache: present"
else
  for marker in \
      "gold/data/generated/landmarks.lua" \
      "data/generated/gold/landmarks.lua"; do
    if [ -f "$marker" ]; then
      have_gold=1
      echo "  gold cache: found $marker"
      break
    fi
  done
fi

if [ "$have_gold" -ne 1 ]; then
  if [ -n "${GOLD_ROM_PATH:-}" ] && [ -f "$GOLD_ROM_PATH" ]; then
    echo "  no Gold cache yet; importing $(basename "$GOLD_ROM_PATH") as gold"
    if ! POKEPORT_IDENTITY="rby-mmo-gold-bf-import-$RUN_ID" \
         POKEPORT_VERSION=gold \
         POKEPORT_IMPORT_ROM="$GOLD_ROM_PATH" \
         POKEPORT_IMPORT_ONLY=1 \
         love . ; then
      fail "Gold import failed -- check GOLD_ROM_PATH is canonical US Gold
     (SHA-1 d8b8a3600a465308c9953dfa04f0081c05bdcb94)."
    fi
    have_gold=1
  else
    echo
    echo "  SKIP: no Gold cache and no usable GOLD_ROM_PATH."
    echo "        In $ENV_FILE set GOLD_ROM_PATH and GOLD_ROM_VERSION=gold"
    echo "        Gen 1 arena e2e remains:"
    echo "          bash $MOD_DIR/tests/drivers/run-battlefield-e2e.sh"
    exit 0
  fi
fi

# ------------------------------------------------------------- the shot run
SHOT_DIR="${SHOT_DIR:-/tmp/rby_mmo_bf_gen2_shots-$RUN_ID}"
mkdir -p "$SHOT_DIR"
SHOT_LOG="$OUT/battlefield_shot.log"

echo
echo "  running battlefield_shot.lua on Gold (one LOVE instance, real window)…"
echo "  shots: $SHOT_DIR"

if [ -n "${GOLD_ROM_PATH:-}" ] && [ -f "$GOLD_ROM_PATH" ]; then
  export POKEPORT_IMPORT_ROM="$GOLD_ROM_PATH"
fi
export POKEPORT_VERSION=gold

SHOT_DIR="$SHOT_DIR" POKEPORT_IDENTITY="bfe2e-gold-$RUN_ID" POKEPORT_TOUCH=0 \
  POKEPORT_DRIVER="$MOD_DIR/tests/drivers/battlefield_shot.lua" \
  love . >"$SHOT_LOG" 2>&1
shot_status=$?

echo
grep -E '^BF_SHOT:' "$SHOT_LOG" | sed 's/^/  /'

gaps=$(grep -o 'GAPS:[0-9]*' "$SHOT_LOG" | tail -1 | cut -d: -f2)
if [ "$shot_status" -ne 0 ] || [ -z "${gaps:-}" ] || [ "$gaps" -ne 0 ]; then
  echo
  echo "  RESULT: battlefield_shot.lua on Gold FAILED (exit=$shot_status gaps=${gaps:-unknown})" >&2
  echo "  full log: $SHOT_LOG" >&2
  exit 1
fi

echo "  RESULT: battlefield_shot.lua passed on Gold -- GAPS:0."
echo "          Screenshots in $SHOT_DIR"
rm -f "$SHOT_LOG"

echo
echo "OK — arena asset present; suite green; Gold arena screenshot driver green."
exit 0
