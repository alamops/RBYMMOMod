#!/usr/bin/env bash
#
# Gen 3 generation-mismatch e2e: two Node hubs and two games, each game
# dialling the hub of the OTHER generation through the real menus, each
# refused with the reason on screen.
#
#   fr   a Gen 3 boot (GEN3_GAME, default firered) -> hub --generation 1
#   red  a Red boot (Gen 1)                        -> hub --generation 3
#
#   bash mods/rby_mmo/tests/drivers/run-mismatch-e2e-gen3.sh
#
# The Gen 3 leg needs a FireRed (or GEN3_GAME) import or its ROM path; the
# Red leg needs the engine's Gen 1 data (data/generated) and is skipped with
# a note when it is absent. Screenshots: g3-<game>-<role>-<NN>-<leg>.png +
# index.html. Env: SHOT_DIR, MMO_TIMEOUT (s), GEN3_GAME, MMO_RUN_ID,
# MMO_MISMATCH_ROLES ("fr red").

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENGINE_ROOT=""
probe="$SCRIPT_DIR"
for _ in 1 2 3 4 5 6 7 8; do
  if [ -f "$probe/main.lua" ] && [ -d "$probe/mods" ]; then ENGINE_ROOT="$probe"; break; fi
  probe="$(dirname "$probe")"
done
[ -n "$ENGINE_ROOT" ] || ENGINE_ROOT="$HOME/Projects/alamops/gen1recomp"
cd "$ENGINE_ROOT" || exit 1

MOD_DIR="mods/rby_mmo"
MOD_REAL="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE=""
for candidate in \
    "$MOD_DIR/.env" "$MOD_REAL/.env" \
    "${RBY_MMO_ENV:-$HOME/Projects/alamops/RBYMMOMod/.env}"; do
  if [ -f "$candidate" ]; then ENV_FILE="$candidate"; break; fi
done
: "${ENV_FILE:=$MOD_DIR/.env}"

fail() { echo "  !! $*" >&2; exit 2; }
ENV_SH=""
if [ -f "$MOD_DIR/tools/env.sh" ]; then ENV_SH="$MOD_DIR/tools/env.sh"
elif [ -f "$MOD_REAL/tools/env.sh" ]; then ENV_SH="$MOD_REAL/tools/env.sh"; fi
[ -n "$ENV_SH" ] || fail "tools/env.sh is missing from $MOD_REAL"
# shellcheck source=/dev/null
. "$ENV_SH"
load_env "$ENV_FILE" 2>/dev/null || true
load_canon_env 2>/dev/null || true

DRIVERS="$MOD_DIR/tests/drivers"
[ -f "$DRIVERS/mmo_mismatch_gen3.lua" ] || DRIVERS="$MOD_REAL/tests/drivers"
HUB_CLI="$MOD_DIR/server/bin/rby-mmo-hub.js"
[ -f "$HUB_CLI" ] || HUB_CLI="$MOD_REAL/server/bin/rby-mmo-hub.js"
command -v love >/dev/null 2>&1 || fail "love is not on PATH"
command -v node >/dev/null 2>&1 || fail "node is not on PATH"

GAME="${GEN3_GAME:-firered}"
RUN_ID="${MMO_RUN_ID:-$$}"
SHOT_DIR="${SHOT_DIR:-/tmp/rby_mmo_mismatch_gen3_shots-$RUN_ID}"
SYNC_DIR="${MMO_SYNC_DIR:-/tmp/rby_mmo_mismatch_gen3_sync-$RUN_ID}"
TIMEOUT="${MMO_TIMEOUT:-600}"
read -r -a ROLES <<< "${MMO_MISMATCH_ROLES:-fr red}"

# fr: the Gen 3 cart's cache (or import, or skip the leg)
want_role() { local r; for r in "${ROLES[@]}"; do [ "$r" = "$1" ] && return 0; done; return 1; }
if want_role fr; then
  check_gen3_rom_config "$GAME" || fail "fix $(gen3_rom_key "$GAME") in $ENV_FILE"
  if ! have_gen3_cache "$GAME" "$ENGINE_ROOT"; then
    rom="$(gen3_rom_path "$GAME")"
    if [ -n "$rom" ] && [ -f "$rom" ]; then
      POKEPORT_IDENTITY="rby-mmo-g3-import-$GAME-$RUN_ID" POKEPORT_VERSION="$GAME" \
        POKEPORT_IMPORT_ROM="$rom" POKEPORT_IMPORT_ONLY=1 love . \
        || fail "$GAME import failed -- expected SHA-1 $(gen3_rom_sha "$GAME")"
    else
      echo "  SKIP (fr leg): no $GAME cache and no usable $(gen3_rom_key "$GAME")."
      ROLES=("${ROLES[@]/fr}")
    fi
  fi
fi
# red: the engine's own Gen 1 data, and ROM_PATH -- a fresh LOVE identity
# sits on the ROM picker without POKEPORT_IMPORT_ROM even when data/generated
# is populated (the import is per save identity), exactly as run-mmo-e2e.sh.
if want_role red; then
  if [ ! -f "data/generated/constants.lua" ]; then
    echo "  SKIP (red leg): no Gen 1 data in $ENGINE_ROOT/data/generated (run scripts/setup.sh --rom)."
    ROLES=("${ROLES[@]/red}")
  elif [ -z "${ROM_PATH:-}" ] || [ ! -f "$ROM_PATH" ]; then
    echo "  SKIP (red leg): no usable ROM_PATH; a fresh identity would stall on the ROM picker."
    echo "        Set ROM_PATH (and ROM_VERSION) in $ENV_FILE."
    ROLES=("${ROLES[@]/red}")
  else
    check_rom_config || fail "fix ROM_PATH / ROM_VERSION in $ENV_FILE"
  fi
fi
LIVE_ROLES=()
for r in "${ROLES[@]}"; do [ -n "$r" ] && LIVE_ROLES+=("$r"); done
if [ "${#LIVE_ROLES[@]}" -eq 0 ]; then
  echo "  SKIP: neither leg can run on this machine."
  exit 0
fi

rm -rf "${SYNC_DIR:?}"
mkdir -p "$SHOT_DIR" "$SYNC_DIR"
HUB_HOME="$(mktemp -d "${TMPDIR:-/tmp}/rby_mmo_mismatch_gen3.XXXXXX")"

CLEANED=0
cleanup() {
  [ "$CLEANED" = "1" ] && return 0
  CLEANED=1
  for r in fr red; do
    v="PID_$r"; [ -n "${!v:-}" ] && kill "${!v}" 2>/dev/null
    v="HUBPID_$r"; [ -n "${!v:-}" ] && kill "${!v}" 2>/dev/null
  done
  for r in fr red; do
    v="SAVE_$r"; [ -n "${!v:-}" ] && rm -rf "${!v:?}"
  done
  rm -rf "${SYNC_DIR:?}" 2>/dev/null
  [ -n "${HUB_HOME:-}" ] && rm -rf "${HUB_HOME:?}"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

free_port() {
  local base=$1 candidate offset
  for offset in $(seq 0 80); do
    candidate=$(( base + offset ))
    node -e "const n=require('node:net').createServer();n.once('error',()=>process.exit(1));n.listen($candidate,'127.0.0.1',()=>n.close(()=>process.exit(0)))" \
      2>/dev/null && { echo "$candidate"; return 0; }
  done
  return 1
}

# start_hub <role> <generation> <port base>: sets HUB_<role>, CODE_<role>
start_hub() {
  local role="$1" gen="$2" base="$3" port cfg log code
  port="$(free_port "$base")" || fail "no free port for the $role hub"
  cfg="$HUB_HOME/$role/config.json"
  log="/tmp/rby_mmo_mismatch_gen3_hub_${role}_$$.log"
  mkdir -p "$HUB_HOME/$role"
  node "$HUB_CLI" --config "$cfg" init --yes --host 127.0.0.1 --port "$port" --max 4 \
    --generation "$gen" --per-ip 4 --log-level info >"$log" 2>&1 \
    || { cat "$log" >&2; fail "hub init --generation $gen failed"; }
  code="$(node "$HUB_CLI" --config "$cfg" invite list --reveal 2>/dev/null \
    | awk '$NF ~ /^[0-9A-HJKMNP-TV-Z]{6}$/ { print $NF; exit }')"
  [ -n "$code" ] || fail "the generation $gen hub minted no join code"
  node "$HUB_CLI" --config "$cfg" start >>"$log" 2>&1 &
  printf -v "HUBPID_$role" '%s' "$!"
  local up=0 pidv="HUBPID_$role"
  for _ in $(seq 1 60); do
    grep -q 'RBY MMO hub listening on' "$log" 2>/dev/null && { up=1; break; }
    kill -0 "${!pidv}" 2>/dev/null || break
    sleep 1
  done
  [ "$up" = "1" ] || { tail -20 "$log" >&2; fail "the generation $gen hub never listened"; }
  printf -v "HUB_$role" '%s' "127.0.0.1:$port"
  printf -v "CODE_$role" '%s' "$code"
  printf -v "HUBLOG_$role" '%s' "$log"
  echo "  hub for $role: 127.0.0.1:$port, generation $gen"
}

PROBE="$(mktemp -d)"
cat > "$PROBE/conf.lua" <<'EOF'
function love.conf(t)
  t.identity = os.getenv("POKEPORT_IDENTITY") or "pokemon-love2d"
  t.window = false
end
EOF
cat > "$PROBE/main.lua" <<'EOF'
function love.load()
  print("SAVEDIR=" .. tostring(love.filesystem.getSaveDirectory()))
  love.event.quit()
end
EOF
save_dir_for() {
  POKEPORT_IDENTITY="$1" love "$PROBE" 2>/dev/null | sed -n 's/^SAVEDIR=//p' | head -1
}
enable_mod_for() {
  local dir
  dir="$(save_dir_for "$1")"
  [ -n "$dir" ] || fail "could not determine LOVE's save directory for $1"
  mkdir -p "$dir"
  printf 'return { mods = { rby_mmo = true }, modOptions = { rby_mmo = { hub = "%s" } } }\n' "$2" \
    > "$dir/options.lua"
  echo "$dir"
}

export POKEPORT_TOUCH=0
run_love() {
  if command -v stdbuf >/dev/null 2>&1; then stdbuf -oL -eL love . "$@"; else love . "$@"; fi
}

for role in "${LIVE_ROLES[@]}"; do
  case "$role" in
    fr)  start_hub fr 1 $(( 8860 + ($$ % 100) )); version="$GAME"; hub_gen=1; my_gen=3 ;;
    red) start_hub red 3 $(( 8960 + ($$ % 100) )); version="${ROM_VERSION:-red}"; hub_gen=3; my_gen=1 ;;
    *) fail "unknown role $role" ;;
  esac
  hubv="HUB_$role"; codev="CODE_$role"
  id="mmomismatch-g3-$role-$RUN_ID"
  dir="$(enable_mod_for "$id" "${!hubv}")"
  printf -v "SAVE_$role" '%s' "$dir"
  if [ "$role" = "fr" ]; then
    seed_gen3_cache "$dir" "$GAME" "$ENGINE_ROOT" || fail "could not seed the $GAME cache"
  fi
  log="/tmp/rby_mmo_mismatch_gen3_${role}_$$.log"
  printf -v "LOG_$role" '%s' "$log"
  echo "  starting $role ($version) against the generation $hub_gen hub..."
  # the Gen 1 client imports on its fresh identity; the Gen 3 one was seeded
  if [ "$role" = "red" ]; then export POKEPORT_IMPORT_ROM="$ROM_PATH"; else unset POKEPORT_IMPORT_ROM; fi
  MMO_ROLE="$role" MMO_HUB_CODE="${!codev}" MMO_HUB_GEN="$hub_gen" MMO_MY_GEN="$my_gen" \
    SHOT_DIR="$SHOT_DIR" MMO_SYNC_DIR="$SYNC_DIR" POKEPORT_IDENTITY="$id" \
    POKEPORT_VERSION="$version" POKEPORT_DRIVER="$DRIVERS/mmo_mismatch_gen3.lua" \
    run_love >"$log" 2>&1 &
  printf -v "PID_$role" '%s' "$!"
done
unset POKEPORT_IMPORT_ROM
rm -rf "$PROBE"

for _ in $(seq 1 "$TIMEOUT"); do
  all_done=1; any_alive=0
  for role in "${LIVE_ROLES[@]}"; do
    logv="LOG_$role"; pidv="PID_$role"
    grep -q "MMO_MISMATCH_.*DONE" "${!logv}" 2>/dev/null || all_done=0
    kill -0 "${!pidv}" 2>/dev/null && any_alive=1
  done
  [ "$all_done" = "1" ] && break
  [ "$any_alive" = "0" ] && break
  sleep 1
done
for role in "${LIVE_ROLES[@]}"; do
  pidv="PID_$role"; kill "${!pidv}" 2>/dev/null; wait "${!pidv}" 2>/dev/null
  pidv="HUBPID_$role"; kill "${!pidv}" 2>/dev/null
done

total_fail=0; incomplete=0
for role in "${LIVE_ROLES[@]}"; do
  logv="LOG_$role"; upper=$(echo "$role" | tr '[:lower:]' '[:upper:]')
  echo "  ---- $role ----"
  grep -E "MMO_MISMATCH_${upper}:|TIMEOUT|driver error" "${!logv}" | sed 's/^/  /'
  f=$(grep -c "MMO_MISMATCH_${upper}:.*FAIL" "${!logv}" 2>/dev/null || true); f=${f:-0}
  o=$(grep -c "MMO_MISMATCH_${upper}:[[:space:]]ok " "${!logv}" 2>/dev/null || true); o=${o:-0}
  d=$(grep -c "MMO_MISMATCH_${upper}:.*DONE" "${!logv}" 2>/dev/null || true); d=${d:-0}
  echo "  checks $role: $o ok / $f FAIL"
  total_fail=$(( total_fail + f ))
  [ "$d" -ne 1 ] && incomplete=$(( incomplete + 1 ))
done

INDEXER="$DRIVERS/shots_index.py"
[ -f "$INDEXER" ] || INDEXER="$MOD_REAL/tests/drivers/shots_index.py"
if [ -f "$INDEXER" ] && command -v python3 >/dev/null 2>&1; then
  python3 "$INDEXER" "$SHOT_DIR" | sed 's/^/  /'
fi

if [ "$incomplete" -ne 0 ]; then
  echo "  RESULT: incomplete -- $incomplete leg(s) never reached DONE."
  for role in "${LIVE_ROLES[@]}"; do logv="LOG_$role"; echo "  log kept: ${!logv}"; done
  exit 1
fi
if [ "$total_fail" -ne 0 ]; then
  echo "  RESULT: FAILED -- $total_fail failure(s)."
  for role in "${LIVE_ROLES[@]}"; do logv="LOG_$role"; echo "  log kept: ${!logv}"; done
  exit 1
fi
echo "  RESULT: generation mismatch refused both ways. Screenshots in $SHOT_DIR"
for role in "${LIVE_ROLES[@]}"; do
  logv="LOG_$role"; rm -f "${!logv}"
  hl="HUBLOG_$role"; rm -f "${!hl}"
done
exit 0
