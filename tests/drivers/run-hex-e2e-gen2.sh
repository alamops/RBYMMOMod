#!/usr/bin/env bash
#
# Gen 2 end-to-end: SIX Gold LOVE instances, Node hub, 3-on-3 party PvP.
# Same choreography as run-hex-e2e.sh but boots Gold and skips cleanly
# when no Gold cache / GOLD_ROM_PATH (same message as run-mmo-e2e-gen2.sh).
#
#   bash mods/rby_mmo/tests/drivers/run-hex-e2e-gen2.sh

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
[ -n "$ENGINE_ROOT" ] || { echo "  !! could not find Gen1Recomp checkout" >&2; exit 2; }
cd "$ENGINE_ROOT" || exit 1

MOD_DIR="mods/rby_mmo"
MOD_REAL="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE=""
for candidate in \
    "$MOD_DIR/.env" \
    "$MOD_REAL/.env" \
    "${RBY_MMO_ENV:-$HOME/Projects/alamops/RBYMMOMod/.env}"; do
  if [ -f "$candidate" ]; then ENV_FILE="$candidate"; break; fi
done
: "${ENV_FILE:=$MOD_DIR/.env}"

ENV_SH=""
if [ -f "$MOD_DIR/tools/env.sh" ]; then ENV_SH="$MOD_DIR/tools/env.sh"
elif [ -f "$MOD_REAL/tools/env.sh" ]; then ENV_SH="$MOD_REAL/tools/env.sh"; fi
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

DRIVERS="$MOD_DIR/tests/drivers"
[ -f "$DRIVERS/mmo_hex_gen2.lua" ] || DRIVERS="$MOD_REAL/tests/drivers"
HUB_CLI="$MOD_DIR/server/bin/rby-mmo-hub.js"
[ -f "$HUB_CLI" ] || HUB_CLI="$MOD_REAL/server/bin/rby-mmo-hub.js"

fail() { echo "  !! $*" >&2; exit 2; }

command -v love >/dev/null 2>&1 || fail "love is not on PATH"
[ -f main.lua ] || fail "engine root missing main.lua"

RUN_ID="${MMO_RUN_ID:-$$}"

command -v check_gold_rom_config >/dev/null 2>&1 && check_gold_rom_config || true

have_gold=0
if command -v have_gold_cache >/dev/null 2>&1 && have_gold_cache "$ENGINE_ROOT"; then
  have_gold=1
else
  for marker in \
      "gold/data/generated/landmarks.lua" \
      "data/generated/gold/landmarks.lua"; do
    if [ -f "$marker" ]; then have_gold=1; break; fi
  done
fi

if [ "$have_gold" -ne 1 ]; then
  if [ -n "${GOLD_ROM_PATH:-}" ] && [ -f "$GOLD_ROM_PATH" ]; then
    echo "  no Gold cache yet; importing $(basename "$GOLD_ROM_PATH") as gold"
    IMPORT_ID="rby-mmo-gold-hex-import-$RUN_ID"
    POKEPORT_IDENTITY="$IMPORT_ID" POKEPORT_VERSION=gold \
      POKEPORT_IMPORT_ROM="$GOLD_ROM_PATH" POKEPORT_IMPORT_ONLY=1 love . \
      || fail "Gold import failed -- check GOLD_ROM_PATH"
    have_gold=1
  else
    echo "  SKIP: no Gold cache and no usable GOLD_ROM_PATH."
    echo "        In $ENV_FILE set GOLD_ROM_PATH and GOLD_ROM_VERSION=gold"
    echo "        Gen 1 hex remains: bash $MOD_DIR/tests/drivers/run-hex-e2e.sh"
    exit 0
  fi
fi

ROLES=(a b c d e f)
MAX="${MMO_HUB_MAX:-8}"
HUB_LOG="/tmp/rby_mmo_hex_gen2_server_$$.log"
SHOT_DIR="${SHOT_DIR:-/tmp/rby_mmo_hex_gen2_shots-$RUN_ID}"
SYNC_DIR="${MMO_SYNC_DIR:-/tmp/rby_mmo_hex_gen2_sync-$RUN_ID}"
TIMEOUT="${MMO_TIMEOUT:-5400}"

rm -rf "$SYNC_DIR"
mkdir -p "$SHOT_DIR" "$SYNC_DIR"

HUB_HOME="$(mktemp -d "${TMPDIR:-/tmp}/rby_mmo_hex_gen2_cfg.XXXXXX")"
HUB_CONFIG="$HUB_HOME/config.json"

stop_hub() {
  [ -n "${HUB_PID:-}" ] || return 0
  kill "$HUB_PID" 2>/dev/null
  for _ in 1 2 3 4 5; do
    kill -0 "$HUB_PID" 2>/dev/null || return 0
    sleep 1
  done
  kill -9 "$HUB_PID" 2>/dev/null
}

cleanup() {
  rm -rf "$SYNC_DIR" 2>/dev/null
  for role in "${ROLES[@]}"; do
    local_pid="PID_${role}"
    [ -n "${!local_pid:-}" ] && kill "${!local_pid}" 2>/dev/null
    local_save="SAVE_${role}"
    [ -n "${!local_save:-}" ] && rm -rf "${!local_save}"
  done
  stop_hub
  rm -rf "$HUB_HOME"
}
trap cleanup EXIT

hub_cli() { node "$HUB_CLI" --config "$HUB_CONFIG" "$@"; }

port_free() {
  node -e '
    const net = require("node:net");
    const server = net.createServer();
    server.once("error", () => process.exit(1));
    server.listen(Number(process.argv[1]), "127.0.0.1",
      () => server.close(() => process.exit(0)));
  ' "$1" 2>/dev/null
}

PORT="${MMO_HUB_PORT:-}"
if [ -z "$PORT" ]; then
  base=$(( 8160 + ($$ % 150) ))
  for offset in $(seq 0 60); do
    candidate=$(( base + offset ))
    if port_free "$candidate"; then PORT="$candidate"; break; fi
  done
  [ -n "$PORT" ] || fail "could not find a free port"
fi
HUB_ADDRESS="127.0.0.1:$PORT"

# Loopback e2e: every LOVE shares 127.0.0.1, so the per-address cap must
# cover all six guests (default 4 refuses the 5th).
hub_cli init --yes --host 127.0.0.1 --port "$PORT" --max "$MAX" \
  --generation 2 --per-ip "$MAX" --log-level info >"$HUB_LOG" 2>&1 \
  || { tail -20 "$HUB_LOG" >&2; exit 1; }

JOIN_CODE="$(hub_cli invite list --reveal 2>/dev/null \
  | awk '$NF ~ /^[0-9A-HJKMNP-TV-Z]{6}$/ { print $NF; exit }')"
[ ${#JOIN_CODE} -eq 6 ] || fail "could not read join code"

node "$HUB_CLI" --config "$HUB_CONFIG" start >>"$HUB_LOG" 2>&1 &
HUB_PID=$!
for _ in $(seq 1 60); do
  grep -q 'RBY MMO hub listening on' "$HUB_LOG" 2>/dev/null && break
  sleep 1
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
  POKEPORT_IDENTITY="$1" POKEPORT_VERSION=gold love "$PROBE" 2>/dev/null \
    | sed -n 's/^SAVEDIR=//p' | head -1
}

enable_mod_for() {
  local dir
  dir="$(save_dir_for "$1")"
  mkdir -p "$dir"
  printf 'return { mods = { rby_mmo = true }, modOptions = { rby_mmo = { hub = "%s", sprite = "%s" } } }\n' \
    "$HUB_ADDRESS" "$2" > "$dir/options.lua"
  echo "$dir"
}

seed_gold_cache() {
  local dest="$1/gold"
  [ -d "$dest/data/generated" ] && return 0
  local src=""
  for candidate in \
      "${HOME}/Library/Application Support/LOVE/rby-mmo-gold/gold" \
      "${HOME}/Library/Application Support/LOVE/rby-mmo-gold-import/gold" \
      "${ENGINE_ROOT}/gold"; do
    if [ -f "$candidate/data/generated/landmarks.lua" ]; then src="$candidate"; break; fi
  done
  if [ -n "$src" ]; then mkdir -p "$(dirname "$dest")"; cp -R "$src" "$dest"; fi
}

SPRITE_a="${MMO_A_SPRITE:-SPRITE_CHRIS}"
SPRITE_b="${MMO_B_SPRITE:-SPRITE_YOUNGSTER}"
SPRITE_c="${MMO_C_SPRITE:-SPRITE_LASS}"
SPRITE_d="${MMO_D_SPRITE:-SPRITE_BUG_CATCHER}"
SPRITE_e="${MMO_E_SPRITE:-SPRITE_COOLTRAINER_M}"
SPRITE_f="${MMO_F_SPRITE:-SPRITE_COOLTRAINER_F}"

export POKEPORT_VERSION=gold
export POKEPORT_TOUCH=0
[ -n "${GOLD_ROM_PATH:-}" ] && [ -f "$GOLD_ROM_PATH" ] && \
  export POKEPORT_IMPORT_ROM="$GOLD_ROM_PATH"

for role in "${ROLES[@]}"; do
  sprite_var="SPRITE_${role}"
  id="mmohex-gold-${role}-$RUN_ID"
  printf -v "ID_${role}" '%s' "$id"
  dir="$(enable_mod_for "$id" "${!sprite_var}")"
  seed_gold_cache "$dir"
  printf -v "SAVE_${role}" '%s' "$dir"
done
rm -rf "$PROBE"

echo "  launching 6 LOVE guests on $HUB_ADDRESS"
for role in "${ROLES[@]}"; do
  id_var="ID_${role}"
  log="/tmp/rby_mmo_hex_gen2_${role}_$$.log"
  printf -v "LOG_${role}" '%s' "$log"
  echo "  starting guest $role..."
  if command -v stdbuf >/dev/null 2>&1; then
    MMO_ROLE="$role" MMO_HUB_CODE="$JOIN_CODE" SHOT_DIR="$SHOT_DIR" \
      MMO_SYNC_DIR="$SYNC_DIR" POKEPORT_IDENTITY="${!id_var}" \
      POKEPORT_DRIVER="$DRIVERS/mmo_hex_gen2.lua" \
      stdbuf -oL -eL love . >"$log" 2>&1 &
  else
    MMO_ROLE="$role" MMO_HUB_CODE="$JOIN_CODE" SHOT_DIR="$SHOT_DIR" \
      MMO_SYNC_DIR="$SYNC_DIR" POKEPORT_IDENTITY="${!id_var}" \
      POKEPORT_DRIVER="$DRIVERS/mmo_hex_gen2.lua" love . >"$log" 2>&1 &
  fi
  printf -v "PID_${role}" '%s' "$!"
  pid_var="PID_${role}"
  booted=0
  for _ in $(seq 1 60); do
    grep -qE "game loaded|loaded mod rby_mmo" "$log" 2>/dev/null && { booted=1; break; }
    kill -0 "${!pid_var}" 2>/dev/null || fail "guest $role exited before boot (see $log)"
    sleep 1
  done
  [ "$booted" = "1" ] || fail "guest $role never booted (see $log)"
done

for _ in $(seq 1 "$TIMEOUT"); do
  all_done=1
  any_alive=0
  for role in "${ROLES[@]}"; do
    log_var="LOG_${role}"; pid_var="PID_${role}"
    grep -q "DONE" "${!log_var}" 2>/dev/null || all_done=0
    kill -0 "${!pid_var}" 2>/dev/null && any_alive=1
  done
  [ "$all_done" = "1" ] && break
  [ "$any_alive" = "0" ] && break
  sleep 1
done

for role in "${ROLES[@]}"; do
  pid_var="PID_${role}"; kill "${!pid_var}" 2>/dev/null; wait "${!pid_var}" 2>/dev/null
done
stop_hub

total_incomplete=0
total_fail=0
for role in "${ROLES[@]}"; do
  log_var="LOG_${role}"
  upper=$(echo "$role" | tr '[:lower:]' '[:upper:]')
  grep -E "MMO_HEX_${upper}:|TIMEOUT" "${!log_var}" | sed 's/^/  /'
  f=$(grep -c "MMO_HEX_${upper}:.*FAIL" "${!log_var}" 2>/dev/null || true); f=${f:-0}
  d=$(grep -c "MMO_HEX_${upper}:.*DONE" "${!log_var}" 2>/dev/null || true); d=${d:-0}
  total_fail=$(( total_fail + f ))
  [ "$d" -ne 1 ] && total_incomplete=$(( total_incomplete + 1 ))
done

if [ "$total_incomplete" -ne 0 ]; then
  echo "  RESULT: incomplete -- $total_incomplete of 6 never reached DONE."
  exit 1
fi
if [ "$total_fail" -ne 0 ]; then
  echo "  RESULT: FAILED -- $total_fail guest failure(s)."
  exit 1
fi
echo "  RESULT: Gen 2 six-client 3-on-3 passed. Screenshots in $SHOT_DIR"
exit 0
