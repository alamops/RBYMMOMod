#!/usr/bin/env bash
#
# Gen 2 end-to-end: two real LOVE instances on Gold, real sockets, driven
# menus — presence/chat plus product legs (trade, mediated 1v1, party,
# coop_wild, coop_npc). Same contract as run-mmo-e2e.sh (Gen 1), no human
# input.
#
#   Run from the Gen1Recomp checkout root, with this mod linked into mods/:
#
#     bash mods/rby_mmo/tests/drivers/run-mmo-e2e-gen2.sh
#
# Two windows open and drive themselves. Leave them alone until it finishes
# -- clicking into them steals the input the drivers are queueing.
#
# .env (see .env.example):
#
#     GOLD_ROM_PATH=/path/to/Pokemon Gold.gbc
#     GOLD_ROM_VERSION=gold
#
# HostServer locks the room to generation 2 from the Gold boot — no separate
# hub.js process (equal peer to Gen 1's in-game host path).

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
# Same contract as Gen 1: machine-local ROM paths live in .env (gitignored).
# Prefer the linked mod's copy; fall back to this checkout, then the main
# project folder — agetor worktrees often lack a private .env.
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
  # Supplement GOLD_ROM_* from the main project .env when the linked copy
  # has Gen 1 paths only (or is a thin worktree stub).
  CANON_ENV="${RBY_MMO_ENV:-$HOME/Projects/alamops/RBYMMOMod/.env}"
  if [ -z "${GOLD_ROM_PATH:-}" ] && [ -f "$CANON_ENV" ] \
      && [ "$(cd "$(dirname "$CANON_ENV")" && pwd)" != "$MOD_REAL" ]; then
    load_env "$CANON_ENV" 2>/dev/null || true
  fi
fi

DRIVERS="$MOD_DIR/tests/drivers"
if [ ! -f "$DRIVERS/mmo_host_gen2.lua" ] && [ -f "$MOD_REAL/tests/drivers/mmo_host_gen2.lua" ]; then
  DRIVERS="$MOD_REAL/tests/drivers"
fi

RUN_ID="${MMO_RUN_ID:-$$}"
ADDR_FILE="${MMO_ADDR_FILE:-/tmp/rby_mmo_gen2_addr-$RUN_ID.txt}"
MMO_GAME_PORT="${RBY_MMO_PORT:-$(( 7600 + ($$ % 200) ))}"
export RBY_MMO_PORT="$MMO_GAME_PORT"

if [ -n "${MMO_JOIN_ADDRESS:-}" ] && [ "${MMO_JOIN_ADDRESS##*:}" != "$MMO_GAME_PORT" ]; then
  echo "  note: MMO_JOIN_ADDRESS=$MMO_JOIN_ADDRESS names a port this host is"
  echo "        not binding; dialling 127.0.0.1:$MMO_GAME_PORT instead."
  MMO_JOIN_ADDRESS=""
fi
: "${MMO_JOIN_ADDRESS:=127.0.0.1:$MMO_GAME_PORT}"
export MMO_JOIN_ADDRESS

SHOT_DIR="${SHOT_DIR:-/tmp/rby_mmo_gen2_shots-$RUN_ID}"
LIMIT="${MMO_LIMIT:-2}"
HOST_ID="mmohost-gold-$RUN_ID"
GUEST_ID="mmoguest-gold-$RUN_ID"
HOST_LOG="/tmp/rby_mmo_gen2_host_$$.log"
GUEST_LOG="/tmp/rby_mmo_gen2_guest_$$.log"
TIMEOUT="${MMO_TIMEOUT:-900}"

echo "  rby_mmo Gen 2 e2e (Gold host + guest, driven LOVE)"
echo "  engine: $ENGINE_ROOT"
echo "  env: $ENV_FILE"

fail() { echo "  !! $*" >&2; exit 2; }

command -v love >/dev/null 2>&1 || fail "love is not on PATH (brew install --cask love)"
[ -f main.lua ] || fail "engine root missing main.lua"
if [ ! -d "$MOD_DIR" ] && [ ! -d "$MOD_REAL/src" ]; then
  fail "$MOD_DIR is missing -- symlink the mod into mods/"
fi
[ -f "$DRIVERS/mmo_host_gen2.lua" ] || fail "missing mmo_host_gen2.lua"
[ -f "$DRIVERS/mmo_join_gen2.lua" ] || fail "missing mmo_join_gen2.lua"

command -v check_gold_rom_config >/dev/null 2>&1 && check_gold_rom_config || true

# Gold cache: LOVE identity or engine tree.
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
    IMPORT_ID="rby-mmo-gold-import-$RUN_ID"
    if ! POKEPORT_IDENTITY="$IMPORT_ID" \
         POKEPORT_VERSION=gold \
         POKEPORT_IMPORT_ROM="$GOLD_ROM_PATH" \
         POKEPORT_IMPORT_ONLY=1 \
         love . ; then
      fail "Gold import failed -- check GOLD_ROM_PATH is canonical US Gold
     (SHA-1 d8b8a3600a465308c9953dfa04f0081c05bdcb94)."
    fi
    have_gold=1
  else
    echo "  SKIP: no Gold cache and no usable GOLD_ROM_PATH."
    echo "        In $ENV_FILE set GOLD_ROM_PATH and GOLD_ROM_VERSION=gold"
    echo "        Gen 1 e2e remains: bash $MOD_DIR/tests/drivers/run-mmo-e2e.sh"
    exit 0
  fi
fi

SYNC_OWNED=$([ -n "${MMO_SYNC_DIR:-}" ] && echo 0 || echo 1)
SYNC_DIR="${MMO_SYNC_DIR:-/tmp/rby_mmo_gen2_sync-$RUN_ID}"
rm -f "$ADDR_FILE" "$ADDR_FILE.tmp" "$HOST_LOG" "$GUEST_LOG"
rm -rf "$SYNC_DIR"
mkdir -p "$SHOT_DIR" "$SYNC_DIR"

EXTRA_MODS=""
for id in ${MMO_WITH_MODS:-}; do
  EXTRA_MODS="$EXTRA_MODS, $id = true"
done
for id in ${MMO_WITHOUT_MODS:-}; do
  EXTRA_MODS="$EXTRA_MODS, $id = false"
done

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

# Gold walkers: Chris (default) vs a second catalog id so look is checkable.
enable_mod_for() {
  local dir
  dir="$(save_dir_for "$1")"
  [ -n "$dir" ] || fail "could not determine LOVE's save directory for $1"
  mkdir -p "$dir"
  printf 'return { mods = { rby_mmo = true%s }, modOptions = { rby_mmo = { hub = "%s", sprite = "%s" } } }\n' \
    "$EXTRA_MODS" "$MMO_JOIN_ADDRESS" "$2" > "$dir/options.lua"
  echo "$dir"
}

HOST_SPRITE="${MMO_HOST_SPRITE:-SPRITE_CHRIS}"
# Gold has no Kris walker id in the catalog; YOUNGSTER is a distinct walker.
GUEST_SPRITE="${MMO_GUEST_SPRITE:-SPRITE_YOUNGSTER}"
HOST_SAVE="$(enable_mod_for "$HOST_ID" "$HOST_SPRITE")"
GUEST_SAVE="$(enable_mod_for "$GUEST_ID" "$GUEST_SPRITE")"

# Throwaway identities do not inherit the play.sh gold extract. Copy a known
# cache when present so LOVE does not stall on the importer (or need a human).
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
    echo "  seeded Gold cache into $(basename "$1") from $src"
  fi
}
seed_gold_cache "$HOST_SAVE"
seed_gold_cache "$GUEST_SAVE"

echo "  sprites: host=$HOST_SPRITE guest=$GUEST_SPRITE"
echo "  guest dials: $MMO_JOIN_ADDRESS   (host binds :$MMO_GAME_PORT)"
rm -rf "$PROBE"
echo "  enabled the mod in $(dirname "$HOST_SAVE")/{$HOST_ID,$GUEST_ID}"

cleanup() {
  if [ "${SYNC_OWNED:-0}" = "1" ] && [ -n "${SYNC_DIR:-}" ]; then
    rm -rf "$SYNC_DIR" 2>/dev/null
  fi
  [ -n "${HOST_PID:-}" ] && kill "$HOST_PID" 2>/dev/null
  [ -n "${GUEST_PID:-}" ] && kill "$GUEST_PID" 2>/dev/null
  [ -n "${HOST_SAVE:-}" ] && rm -rf "$HOST_SAVE"
  [ -n "${GUEST_SAVE:-}" ] && rm -rf "$GUEST_SAVE"
}
trap cleanup EXIT

if [ -n "${GOLD_ROM_PATH:-}" ] && [ -f "$GOLD_ROM_PATH" ]; then
  export POKEPORT_IMPORT_ROM="$GOLD_ROM_PATH"
fi
export POKEPORT_VERSION=gold
export POKEPORT_TOUCH=0
export MMO_SYNC_DIR="$SYNC_DIR"

echo "  host limit: $LIMIT   join code: required (6 chars, minted in game)"
echo "  shots: $SHOT_DIR"
echo "  starting host..."
MMO_ADDR_FILE="$ADDR_FILE" SHOT_DIR="$SHOT_DIR" MMO_LIMIT="$LIMIT" \
  POKEPORT_IDENTITY="$HOST_ID" POKEPORT_DRIVER="$DRIVERS/mmo_host_gen2.lua" \
  stdbuf -oL -eL love . >"$HOST_LOG" 2>&1 &
HOST_PID=$!

for _ in $(seq 1 "$TIMEOUT"); do
  [ -f "$ADDR_FILE" ] && break
  kill -0 "$HOST_PID" 2>/dev/null || break
  sleep 1
done
[ -f "$ADDR_FILE" ] || {
  echo "  !! the host never started listening. Its log:" >&2
  tail -40 "$HOST_LOG" >&2
  exit 1
}
echo "  host is up at $(head -1 "$ADDR_FILE")"

echo "  starting guest..."
MMO_ADDR_FILE="$ADDR_FILE" SHOT_DIR="$SHOT_DIR" \
  POKEPORT_IDENTITY="$GUEST_ID" POKEPORT_DRIVER="$DRIVERS/mmo_join_gen2.lua" \
  stdbuf -oL -eL love . >"$GUEST_LOG" 2>&1 &
GUEST_PID=$!

for _ in $(seq 1 "$TIMEOUT"); do
  if grep -q "DONE" "$HOST_LOG" 2>/dev/null \
     && grep -q "DONE" "$GUEST_LOG" 2>/dev/null; then
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
grep -E 'MMO_HOST:|TIMEOUT' "$HOST_LOG" | sed 's/^/  /'
echo "  ---- guest ----"
grep -E 'MMO_JOIN:|TIMEOUT' "$GUEST_LOG" | sed 's/^/  /'

count() { grep -c "$1" "$2" 2>/dev/null | head -1 || true; }

host_fail=$(count 'MMO_HOST:.*FAIL' "$HOST_LOG"); host_fail=${host_fail:-0}
guest_fail=$(count 'MMO_JOIN:.*FAIL' "$GUEST_LOG"); guest_fail=${guest_fail:-0}
host_done=$(count 'MMO_HOST:.*DONE' "$HOST_LOG"); host_done=${host_done:-0}
guest_done=$(count 'MMO_JOIN:.*DONE' "$GUEST_LOG"); guest_done=${guest_done:-0}

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
echo "  RESULT: Gen 2 end-to-end passed. Screenshots in $SHOT_DIR"
rm -f "$HOST_LOG" "$GUEST_LOG"
exit 0
