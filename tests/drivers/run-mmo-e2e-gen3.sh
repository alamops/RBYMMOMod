#!/usr/bin/env bash
#
# Gen 3 end-to-end: two real LOVE instances on one Gen 3 cart -- FireRed
# (default), LeafGreen or Emerald -- real sockets, every leg driven through
# the real menus (START > MMO > ...), a screenshot at every leg. Same
# contract as run-mmo-e2e.sh (Gen 1) and run-mmo-e2e-gen2.sh (Gold), no human
# input.
#
#   Run from the Gen1Recomp checkout root, with this mod linked into mods/:
#
#     bash mods/rby_mmo/tests/drivers/run-mmo-e2e-gen3.sh
#     GEN3_GAME=emerald bash mods/rby_mmo/tests/drivers/run-mmo-e2e-gen3.sh
#
# Two windows open and drive themselves. Leave them alone until it finishes
# -- clicking into them steals the input the drivers are queueing.
#
# .env (see .env.example), one key per cart:
#
#     FIRE_RED_ROM_PATH=/path/to/Pokemon FireRed.gba
#     EMERALD_ROM_PATH=/path/to/Pokemon Emerald.gba
#     LEAF_GREEN_ROM_PATH=/path/to/Pokemon LeafGreen.gba
#
# A cart already imported (a LOVE identity holding <game>/rom-cache.complete,
# e.g. rby-mmo-g3-import-fr) is copied into each throwaway identity instead
# of importing again; the ROM is only read when no import exists anywhere.
#
# The host is the in-game HostServer, which locks the room to generation 3
# from the boot -- no separate hub.js process. Legs: boot, the START menu's
# MMO row, MAIN, HOST GAME / JOIN GAME by code, presence (see + walk, avatar
# objects, nameplates, the arrival toast), chat (SAY on the letter grid, the
# corner toast, the CHAT log), PLAYERS / profile card / ADD FRIEND / FRIENDS /
# MY PROFILE / RANK, interact (A on the other player), a trade with a dex
# check, a party (INVITE, MEMBERS, the party list on the region map, LEAVE)
# and leaving. Between the trade and the party's end (wave 5): two mediated
# 1v1s through the real ACTIONS menu (the arena, the host asking; then CLASSIC
# BATTLE UI, the guest asking -- command menu, move list, a damaging turn, the
# knockout, the result, the party exactly as it was), and, inside the party,
# a co-op wild 2v1 (both on Route 1 / Route 101 grass, the walker's step
# encounter diverted into the mod's co-op fight, EXP and a level-up) and a
# co-op NPC trainer 2v2 (walked into for real, the trainer's flag set on both
# carts). Both sides hold badges (the host 1 and 5, the guest 3 and 7) and the
# host reads its own hub's referee live at each fight's first command menu: the
# 1v1s are link battles and carry no badge rules (even with a hostile upload of
# badges from the guest's client), the co-op wild and trainer fights carry each
# player's own badges and cart family on side a and none on the computer's
# (even with a hostile upload for its side). Screenshots land in SHOT_DIR as
# g3-<game>-<role>-<NN>-<leg>.png with an index.html contact sheet
# (tests/drivers/shots_index.py).
#
# Env: GEN3_GAME (firered|leafgreen|emerald), SHOT_DIR, MMO_TIMEOUT (s),
# RBY_MMO_PORT, MMO_RUN_ID, MMO_HOST_SPRITE / MMO_GUEST_SPRITE, and
# GEN3_LEGS -- a comma list narrowing the run to some legs (default: all):
# chat, social (ADD FRIEND / FRIENDS / RANK), trade, battle (the two 1v1s),
# party (invite / members / region map / leave), coop (wild + trainer; needs
# the party, so it implies it). Boot, hosting / joining, presence and the
# final leave always run. E.g. GEN3_LEGS=battle for the fights alone,
# GEN3_LEGS=coop for the party and its two 2-on-2s.

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
fail() { echo "  !! $*" >&2; exit 2; }
[ -n "$ENV_SH" ] || fail "tools/env.sh is missing from $MOD_REAL"
# shellcheck source=/dev/null
. "$ENV_SH"
load_env "$ENV_FILE" 2>/dev/null || true
# Worktrees ship a thin .env; the canonical one fills the Gen 3 keys.
load_canon_env 2>/dev/null || true

GAME="${GEN3_GAME:-firered}"
case "$GAME" in
  firered|leafgreen|emerald) ;;
  *) fail "GEN3_GAME must be firered, leafgreen or emerald (got '$GAME')" ;;
esac

DRIVERS="$MOD_DIR/tests/drivers"
if [ ! -f "$DRIVERS/mmo_host_gen3.lua" ] && [ -f "$MOD_REAL/tests/drivers/mmo_host_gen3.lua" ]; then
  DRIVERS="$MOD_REAL/tests/drivers"
fi

RUN_ID="${MMO_RUN_ID:-$$}"
ADDR_FILE="${MMO_ADDR_FILE:-/tmp/rby_mmo_gen3_addr-$GAME-$RUN_ID.txt}"
# Gen 1 binds 7500+, Gen 2 7600+; Gen 3 takes its own band so all three can
# run side by side on one machine.
MMO_GAME_PORT="${RBY_MMO_PORT:-$(( 7800 + ($$ % 150) ))}"
export RBY_MMO_PORT="$MMO_GAME_PORT"
if [ -n "${MMO_JOIN_ADDRESS:-}" ] && [ "${MMO_JOIN_ADDRESS##*:}" != "$MMO_GAME_PORT" ]; then
  echo "  note: MMO_JOIN_ADDRESS=$MMO_JOIN_ADDRESS names a port this host is"
  echo "        not binding; dialling 127.0.0.1:$MMO_GAME_PORT instead."
  MMO_JOIN_ADDRESS=""
fi
: "${MMO_JOIN_ADDRESS:=127.0.0.1:$MMO_GAME_PORT}"
export MMO_JOIN_ADDRESS

SHOT_DIR="${SHOT_DIR:-/tmp/rby_mmo_gen3_shots-$GAME-$RUN_ID}"
LIMIT="${MMO_LIMIT:-2}"
HOST_ID="mmohost-g3-$GAME-$RUN_ID"
GUEST_ID="mmoguest-g3-$GAME-$RUN_ID"
HOST_LOG="/tmp/rby_mmo_gen3_${GAME}_host_$$.log"
GUEST_LOG="/tmp/rby_mmo_gen3_${GAME}_guest_$$.log"
TIMEOUT="${MMO_TIMEOUT:-1500}"
# Both drivers read the same leg list (mmo_util.lua's g3Leg); exported so a
# narrowed run narrows both sides alike.
export GEN3_LEGS="${GEN3_LEGS:-all}"

echo "  rby_mmo Gen 3 e2e ($GAME host + guest, driven LOVE) legs: $GEN3_LEGS"
echo "  engine: $ENGINE_ROOT"
echo "  env: $ENV_FILE"

command -v love >/dev/null 2>&1 || fail "love is not on PATH (brew install --cask love)"
command -v node >/dev/null 2>&1 || true
[ -f main.lua ] || fail "engine root missing main.lua"
if [ ! -d "$MOD_DIR" ] && [ ! -d "$MOD_REAL/src" ]; then
  fail "$MOD_DIR is missing -- symlink the mod into mods/"
fi
[ -f "$DRIVERS/mmo_host_gen3.lua" ] || fail "missing mmo_host_gen3.lua"
[ -f "$DRIVERS/mmo_join_gen3.lua" ] || fail "missing mmo_join_gen3.lua"

check_gen3_rom_config "$GAME" || fail "fix $(gen3_rom_key "$GAME") in $ENV_FILE"
ROM="$(gen3_rom_path "$GAME")"

# The cart's cache: an import somewhere on this machine, or import now, or a
# clean SKIP (CI has no ROM).
if ! have_gen3_cache "$GAME" "$ENGINE_ROOT"; then
  if [ -n "$ROM" ] && [ -f "$ROM" ]; then
    IMPORT_ID="rby-mmo-g3-import-$GAME-$RUN_ID"
    echo "  no $GAME cache yet; importing $(basename "$ROM") into LOVE identity $IMPORT_ID"
    if ! POKEPORT_IDENTITY="$IMPORT_ID" \
         POKEPORT_VERSION="$GAME" \
         POKEPORT_IMPORT_ROM="$ROM" \
         POKEPORT_IMPORT_ONLY=1 \
         love . ; then
      fail "$GAME import failed -- check $(gen3_rom_key "$GAME") is the canonical US cart
     (SHA-1 $(gen3_rom_sha "$GAME"))."
    fi
    have_gen3_cache "$GAME" "$ENGINE_ROOT" || fail "the $GAME import left no rom-cache.complete"
  else
    echo "  SKIP: no $GAME cache and no usable $(gen3_rom_key "$GAME")."
    echo "        In $ENV_FILE set $(gen3_rom_key "$GAME")=/path/to/the/cart.gba"
    exit 0
  fi
fi
echo "  $GAME cache: $(gen3_cache_dir "$GAME" "$ENGINE_ROOT")"

SYNC_OWNED=$([ -n "${MMO_SYNC_DIR:-}" ] && echo 0 || echo 1)
SYNC_DIR="${MMO_SYNC_DIR:-/tmp/rby_mmo_gen3_sync-$GAME-$RUN_ID}"
rm -f "$ADDR_FILE" "$ADDR_FILE.tmp" "$HOST_LOG" "$GUEST_LOG"
rm -rf "${SYNC_DIR:?}"
mkdir -p "$SHOT_DIR" "$SYNC_DIR"

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

save_dir_for() {
  POKEPORT_IDENTITY="$1" love "$PROBE" 2>/dev/null \
    | sed -n 's/^SAVEDIR=//p' | head -1
}

# The look each side wears, by the cart's own OW graphic name (src/Chars.lua's
# Gen 3 catalog). The host keeps its own trainer; the guest wears a second
# graphic so the two avatars are told apart on screen.
case "$GAME" in
  emerald)
    DEF_HOST_SPRITE="OBJ_EVENT_GFX_BRENDAN_NORMAL"
    DEF_GUEST_SPRITE="OBJ_EVENT_GFX_WALLY" ;;
  *)
    DEF_HOST_SPRITE="OBJ_EVENT_GFX_RED_NORMAL"
    DEF_GUEST_SPRITE="OBJ_EVENT_GFX_BLUE" ;;
esac
HOST_SPRITE="${MMO_HOST_SPRITE:-$DEF_HOST_SPRITE}"
GUEST_SPRITE="${MMO_GUEST_SPRITE:-$DEF_GUEST_SPRITE}"

enable_mod_for() {
  local dir
  dir="$(save_dir_for "$1")"
  [ -n "$dir" ] || fail "could not determine LOVE's save directory for $1"
  mkdir -p "$dir"
  printf 'return { mods = { rby_mmo = true }, modOptions = { rby_mmo = { hub = "%s", sprite = "%s", port = "%s" } } }\n' \
    "$MMO_JOIN_ADDRESS" "$2" "$MMO_GAME_PORT" > "$dir/options.lua"
  echo "$dir"
}

HOST_SAVE="$(enable_mod_for "$HOST_ID" "$HOST_SPRITE")"
GUEST_SAVE="$(enable_mod_for "$GUEST_ID" "$GUEST_SPRITE")"
rm -rf "$PROBE"

seed_gen3_cache "$HOST_SAVE" "$GAME" "$ENGINE_ROOT" || fail "could not seed the $GAME cache for the host"
seed_gen3_cache "$GUEST_SAVE" "$GAME" "$ENGINE_ROOT" || fail "could not seed the $GAME cache for the guest"

echo "  sprites: host=$HOST_SPRITE guest=$GUEST_SPRITE"
echo "  guest dials: $MMO_JOIN_ADDRESS   (host binds :$MMO_GAME_PORT)"
echo "  enabled the mod in $(dirname "$HOST_SAVE")/{$HOST_ID,$GUEST_ID}"

CLEANED=0
cleanup() {
  [ "$CLEANED" = "1" ] && return 0
  CLEANED=1
  [ -n "${HOST_PID:-}" ] && kill "$HOST_PID" 2>/dev/null
  [ -n "${GUEST_PID:-}" ] && kill "$GUEST_PID" 2>/dev/null
  if [ "${SYNC_OWNED:-0}" = "1" ] && [ -n "${SYNC_DIR:-}" ]; then
    rm -rf "${SYNC_DIR:?}" 2>/dev/null
  fi
  [ -n "${HOST_SAVE:-}" ] && rm -rf "${HOST_SAVE:?}"
  [ -n "${GUEST_SAVE:-}" ] && rm -rf "${GUEST_SAVE:?}"
  rm -f "$ADDR_FILE" "$ADDR_FILE.tmp"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

# Only needed when a cache was not seeded; harmless otherwise (the engine
# reads it only when its cache is not ready).
if [ -n "$ROM" ] && [ -f "$ROM" ]; then
  export POKEPORT_IMPORT_ROM="$ROM"
fi
export POKEPORT_VERSION="$GAME"
export POKEPORT_TOUCH=0
export MMO_SYNC_DIR="$SYNC_DIR"
export GEN3_GAME="$GAME"

run_love() {
  if command -v stdbuf >/dev/null 2>&1; then
    stdbuf -oL -eL love . "$@"
  else
    love . "$@"
  fi
}

echo "  host limit: $LIMIT   join code: required (6 chars, minted in game)"
echo "  shots: $SHOT_DIR"
echo "  starting host..."
MMO_ADDR_FILE="$ADDR_FILE" SHOT_DIR="$SHOT_DIR" MMO_LIMIT="$LIMIT" \
  POKEPORT_IDENTITY="$HOST_ID" POKEPORT_DRIVER="$DRIVERS/mmo_host_gen3.lua" \
  run_love >"$HOST_LOG" 2>&1 &
HOST_PID=$!

for _ in $(seq 1 "$TIMEOUT"); do
  [ -f "$ADDR_FILE" ] && break
  kill -0 "$HOST_PID" 2>/dev/null || break
  sleep 1
done
if [ ! -f "$ADDR_FILE" ]; then
  echo "  !! the host never started listening. Its log:" >&2
  tail -40 "$HOST_LOG" >&2
  echo "  full log kept: $HOST_LOG" >&2
  exit 1
fi
echo "  host is up at $(head -1 "$ADDR_FILE")"

echo "  starting guest..."
MMO_ADDR_FILE="$ADDR_FILE" SHOT_DIR="$SHOT_DIR" \
  POKEPORT_IDENTITY="$GUEST_ID" POKEPORT_DRIVER="$DRIVERS/mmo_join_gen3.lua" \
  run_love >"$GUEST_LOG" 2>&1 &
GUEST_PID=$!

for _ in $(seq 1 "$TIMEOUT"); do
  if grep -q "MMO_HOST:.*DONE" "$HOST_LOG" 2>/dev/null \
     && grep -q "MMO_JOIN:.*DONE" "$GUEST_LOG" 2>/dev/null; then
    break
  fi
  if ! kill -0 "$HOST_PID" 2>/dev/null && ! kill -0 "$GUEST_PID" 2>/dev/null; then
    break
  fi
  sleep 1
done

kill "$HOST_PID" "$GUEST_PID" 2>/dev/null
wait 2>/dev/null

echo
echo "  ---- host ----"
grep -E 'MMO_HOST:|TIMEOUT|driver error' "$HOST_LOG" | sed 's/^/  /'
echo "  ---- guest ----"
grep -E 'MMO_JOIN:|TIMEOUT|driver error' "$GUEST_LOG" | sed 's/^/  /'

count() { grep -c "$1" "$2" 2>/dev/null | head -1 || true; }

host_fail=$(count 'MMO_HOST:.*FAIL' "$HOST_LOG"); host_fail=${host_fail:-0}
guest_fail=$(count 'MMO_JOIN:.*FAIL' "$GUEST_LOG"); guest_fail=${guest_fail:-0}
host_ok=$(count 'MMO_HOST:[[:space:]]ok ' "$HOST_LOG"); host_ok=${host_ok:-0}
guest_ok=$(count 'MMO_JOIN:[[:space:]]ok ' "$GUEST_LOG"); guest_ok=${guest_ok:-0}
host_done=$(count 'MMO_HOST:.*DONE' "$HOST_LOG"); host_done=${host_done:-0}
guest_done=$(count 'MMO_JOIN:.*DONE' "$GUEST_LOG"); guest_done=${guest_done:-0}

# The contact sheet, whatever the verdict: a failed run's pictures are the
# evidence.
INDEXER="$DRIVERS/shots_index.py"
[ -f "$INDEXER" ] || INDEXER="$MOD_REAL/tests/drivers/shots_index.py"
if [ -f "$INDEXER" ] && command -v python3 >/dev/null 2>&1; then
  python3 "$INDEXER" "$SHOT_DIR" | sed 's/^/  /'
fi

dump_logs() {
  echo
  echo "  ---- host log (tail) ----"
  tail -40 "$HOST_LOG" | sed 's/^/  /'
  echo "  ---- guest log (tail) ----"
  tail -40 "$GUEST_LOG" | sed 's/^/  /'
  echo
  echo "  full logs kept: $HOST_LOG  $GUEST_LOG"
}

echo
echo "  checks: host $host_ok ok / $host_fail FAIL, guest $guest_ok ok / $guest_fail FAIL"
echo "  shots: $SHOT_DIR ($(ls "$SHOT_DIR"/*.png 2>/dev/null | wc -l | tr -d ' ') png)"
if [ "$host_done" -ne 1 ] || [ "$guest_done" -ne 1 ]; then
  echo "  RESULT: incomplete -- one side never reached DONE."
  dump_logs
  exit 1
fi
if [ "$host_fail" -ne 0 ] || [ "$guest_fail" -ne 0 ]; then
  echo "  RESULT: FAILED -- $host_fail host + $guest_fail guest failure(s)."
  dump_logs
  exit 1
fi
echo "  RESULT: Gen 3 ($GAME) end-to-end passed. Screenshots in $SHOT_DIR"
rm -f "$HOST_LOG" "$GUEST_LOG"
exit 0
