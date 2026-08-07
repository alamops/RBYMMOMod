#!/usr/bin/env bash
#
# End-to-end test for party-versus-party: a real Node hub and FOUR real LOVE
# instances, four windows, real sockets between all five.
#
# This is the row run-hub-e2e.sh cannot reach. That one runs two clients and
# fights an NPC -- two humans on one side, two monsters belonging to nobody on
# the other. Party-versus-party differs in every place that has ever broken:
#
#   * four humans have to agree before anything starts, and any one no ends it
#   * four parties have to reach one host, packed, and come back as monsters
#   * four saves take the damage and the exp, on four different machines
#   * the hub has to score a battle with two winners and two losers
#
# All of it existed only in tests/rby_mmo_test.lua, where the four "clients"
# are four tables in one process sharing one clock, one Lua state and one copy
# of the data. Every real fault this feature has had -- a party read as specs,
# a trainer record only one side held, a screen that drew nothing behind a
# pcall -- was invisible until two real clients ran. A four-client path that no
# real client had ever walked is where the next one lives.
#
#   Run from the Gen1Recomp checkout root, with this mod linked into mods/:
#
#     bash mods/rby_mmo/tests/drivers/run-quad-e2e.sh
#
# Requires a ROM to have been imported already (scripts/setup.sh --rom ...).
#
# FOUR windows will open and drive themselves. This is heavier than the
# two-client run in every dimension -- four LOVE processes, four copies of the
# game's data, four windows compositing -- so expect it to be slower per leg
# even where nothing is waiting. Leave them alone until it finishes; clicking
# into one steals the input its driver is queueing.
#
# NONE of the four hosts. All take the JOIN path.

set -uo pipefail
cd "$(dirname "$0")/../../../.." || exit 1

MOD_DIR="mods/rby_mmo"

ENV_FILE="$MOD_DIR/.env"
# shellcheck source=/dev/null
. "$MOD_DIR/tools/env.sh"
load_env "$ENV_FILE"
DRIVERS="$MOD_DIR/tests/drivers"
HUB_CLI="$MOD_DIR/server/bin/rby-mmo-hub.js"

ROLES=(a b c d)

# Six seats for four clients, and the two spare are not slack. A client that
# reconnects -- which the join leg does, by design, after typing a code -- can
# briefly hold two seats while the hub notices the first one has gone. With a
# cap of exactly four, the fifth arrival is refused as "full" and the run
# reports a hub bug that is really an accounting race in the test's own
# choreography.
MAX="${MMO_HUB_MAX:-6}"

# Everything this run owns is namespaced by RUN_ID. Four runs of four clients
# sharing a barrier directory is the same failure the two-client script
# documents at length, four times over: one run's signal satisfies another's
# await and both report "one side never reached DONE".
RUN_ID="${MMO_RUN_ID:-$$}"
HUB_LOG="/tmp/rby_mmo_quad_server_$$.log"
SHOT_DIR="${SHOT_DIR:-/tmp/rby_mmo_quad_shots-$RUN_ID}"
SYNC_OWNED=$([ -n "${MMO_SYNC_DIR:-}" ] && echo 0 || echo 1)
SYNC_DIR="${MMO_SYNC_DIR:-/tmp/rby_mmo_quad_sync-$RUN_ID}"

# The longest barrier in mmo_util's PHASE table for this scenario is
# quad_ready at 900s, and a run crosses eight of them. A good run exits the
# moment all four print DONE, so the only thing a large number costs is how
# long a genuinely stuck run takes to admit it.
TIMEOUT="${MMO_TIMEOUT:-3600}"

fail() { echo "  !! $*" >&2; exit 2; }

command -v love >/dev/null 2>&1 || fail "love is not on PATH (brew install --cask love)"
command -v node >/dev/null 2>&1 || fail "node is not on PATH -- the hub is a node program"
[ -f main.lua ] || fail "run this from the Gen1Recomp checkout root"
[ -d "$MOD_DIR" ] || fail "$MOD_DIR is missing -- symlink the mod into mods/"
[ -f "$HUB_CLI" ] || fail "$HUB_CLI is missing -- this test needs the server half"
[ -d data/generated ] || fail "no data/generated -- import a ROM first
     scripts/setup.sh --rom \"/path/to/rom.gb\", or set ROM_PATH in $ENV_FILE"

check_rom_config || exit 2

for role in "${ROLES[@]}"; do rm -f "/tmp/rby_mmo_quad_${role}_$$.log"; done
rm -f "$HUB_LOG"
rm -rf "$SYNC_DIR"
mkdir -p "$SHOT_DIR" "$SYNC_DIR"

HUB_HOME="$(mktemp -d "${TMPDIR:-/tmp}/rby_mmo_quad_cfg.XXXXXX")" \
  || fail "could not make a scratch directory for the hub's config"
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
  if [ "${SYNC_OWNED:-0}" = "1" ] && [ -n "${SYNC_DIR:-}" ]; then
    rm -rf "$SYNC_DIR" 2>/dev/null
  fi
  for role in "${ROLES[@]}"; do
    local_pid="PID_${role}"
    [ -n "${!local_pid:-}" ] && kill "${!local_pid}" 2>/dev/null
    local_save="SAVE_${role}"
    [ -n "${!local_save:-}" ] && rm -rf "${!local_save}"
  done
  stop_hub
  [ -n "${HUB_HOME:-}" ] && rm -rf "$HUB_HOME"
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

# A different base range from run-hub-e2e.sh on purpose. Both scripts pick a
# pid-derived starting point and walk up, and a developer running one of each
# is exactly the case where two scans that start in the same place spend their
# time discovering each other's ports. Nothing is ever killed to take a port.
PORT="${MMO_HUB_PORT:-}"
if [ -z "$PORT" ]; then
  base=$(( 7960 + ($$ % 150) ))
  for offset in $(seq 0 60); do
    candidate=$(( base + offset ))
    if port_free "$candidate"; then PORT="$candidate"; break; fi
  done
  [ -n "$PORT" ] || fail "could not find a free port in $base..$(( base + 60 ))"
elif ! port_free "$PORT"; then
  fail "MMO_HUB_PORT=$PORT is already in use.
     Unset it to let this run pick its own free port -- do not kill whatever
     is holding it; on a shared machine that is somebody else's run."
fi
HUB_ADDRESS="127.0.0.1:$PORT"

echo "  hub config: $HUB_CONFIG"
if ! hub_cli init --yes --host 127.0.0.1 --port "$PORT" --max "$MAX" \
     --log-level info >"$HUB_LOG" 2>&1; then
  echo "  !! rby-mmo-hub init failed:" >&2
  tail -20 "$HUB_LOG" >&2
  exit 1
fi

JOIN_CODE="$(hub_cli invite list --reveal 2>/dev/null \
  | awk '$NF ~ /^[0-9A-HJKMNP-TV-Z]{6}$/ { print $NF; exit }')"
[ ${#JOIN_CODE} -eq 6 ] || fail "could not read a join code back out of $HUB_CONFIG"
echo "  join code: ****** (6 chars, required)"

echo "  starting the hub on $HUB_ADDRESS (max $MAX)..."
node "$HUB_CLI" --config "$HUB_CONFIG" start >>"$HUB_LOG" 2>&1 &
HUB_PID=$!

READY='RBY MMO hub listening on'
for _ in $(seq 1 60); do
  grep -q "$READY" "$HUB_LOG" 2>/dev/null && break
  kill -0 "$HUB_PID" 2>/dev/null || break
  sleep 1
done
if ! grep -q "$READY" "$HUB_LOG" 2>/dev/null; then
  echo "  !! the hub never started listening. Its log:" >&2
  tail -30 "$HUB_LOG" >&2
  exit 1
fi
grep -m1 "$READY" "$HUB_LOG" | sed 's/^/  /'

# ------------------------------------------------------------ the four clients

EXTRA_MODS=""
for id in ${MMO_WITH_MODS:-}; do EXTRA_MODS="$EXTRA_MODS, $id = true"; done
for id in ${MMO_WITHOUT_MODS:-}; do EXTRA_MODS="$EXTRA_MODS, $id = false"; done

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

enable_mod_for() {
  local dir
  dir="$(save_dir_for "$1")"
  [ -n "$dir" ] || fail "could not determine LOVE's save directory for $1"
  mkdir -p "$dir"
  printf 'return { mods = { rby_mmo = true%s }, modOptions = { rby_mmo = { hub = "%s", sprite = "%s" } } }\n' \
    "$EXTRA_MODS" "$HUB_ADDRESS" "$2" > "$dir/options.lua"
  echo "$dir"
}

# Four different characters. Not decoration: presence carries the sprite
# choice, and four identical ones would let a hub that sent everyone the same
# row pass. The roster assertion reads names, but a human looking at the four
# screenshots can see at a glance whether four distinct people are on them.
SPRITE_a="${MMO_A_SPRITE:-SPRITE_RED}"
SPRITE_b="${MMO_B_SPRITE:-SPRITE_COOLTRAINER_M}"
SPRITE_c="${MMO_C_SPRITE:-SPRITE_COOLTRAINER_F}"
SPRITE_d="${MMO_D_SPRITE:-SPRITE_BUG_CATCHER}"

for role in "${ROLES[@]}"; do
  sprite_var="SPRITE_${role}"
  id="mmoquad-${role}-$RUN_ID"
  printf -v "ID_${role}" '%s' "$id"
  dir="$(enable_mod_for "$id" "${!sprite_var}")"
  printf -v "SAVE_${role}" '%s' "$dir"
done
rm -rf "$PROBE"
echo "  shots: $SHOT_DIR"

if [ -n "${ROM_PATH:-}" ] && [ -f "$ROM_PATH" ]; then
  export POKEPORT_IMPORT_ROM="$ROM_PATH"
  export POKEPORT_VERSION="${ROM_VERSION:-red}"
else
  echo "  note: no usable ROM_PATH; a fresh save identity may stall on the"
  echo "        importer. Set ROM_PATH in $ENV_FILE to make this reliable."
fi

# All four at once. There is no host to wait for -- the hub is already up --
# and staggering them would make one of them the de-facto first arrival, which
# is precisely the asymmetry a four-way agreement must not depend on.
for role in "${ROLES[@]}"; do
  id_var="ID_${role}"
  log="/tmp/rby_mmo_quad_${role}_$$.log"
  printf -v "LOG_${role}" '%s' "$log"
  echo "  starting guest $role..."
  MMO_ROLE="$role" MMO_JOIN_ADDRESS="$HUB_ADDRESS" MMO_HUB_CODE="$JOIN_CODE" \
    MMO_PLAY_ROLE="${MMO_PLAY:+a}" \
    SHOT_DIR="$SHOT_DIR" MMO_SYNC_DIR="$SYNC_DIR" \
    POKEPORT_IDENTITY="${!id_var}" POKEPORT_DRIVER="$DRIVERS/mmo_quad.lua" \
    love . >"$log" 2>&1 &
  printf -v "PID_${role}" '%s' "$!"
done

# ------- play mode
#
# MMO_PLAY=1 hands one window (role a) to a human once the 2-on-2 is on
# screen; the other three become bots that keep the battle moving. Nothing is
# asserted and nothing is torn down on a timer: the session lasts until the
# human closes their window (or interrupts this script), and the EXIT trap
# then cleans up the hub, the bots and the throwaway saves as usual.
if [ -n "${MMO_PLAY:-}" ]; then
  echo ""
  echo "  PLAY MODE -- four windows are coming up and will drive themselves"
  echo "  through joining, forming two parties and agreeing the battle."
  echo "  The window titled 'YOURS TO PLAY -- ALPHA' then stops driving and"
  echo "  is yours. Close that window (or Ctrl-C here) to end the session."
  echo ""
  while kill -0 "$PID_a" 2>/dev/null; do
    sleep 2
  done
  echo "  your window closed -- tearing the session down."
  exit 0
fi

# Wait for ALL FOUR to print DONE. One instance finishing says nothing about
# the other three.
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
  pid_var="PID_${role}"
  kill "${!pid_var}" 2>/dev/null
  wait "${!pid_var}" 2>/dev/null
done
stop_hub
wait "$HUB_PID" 2>/dev/null

# ------------------------------------------------------------------- verdict

count() { grep -c "$1" "$2" 2>/dev/null | head -1 || true; }

total_fail=0
total_incomplete=0
for role in "${ROLES[@]}"; do
  log_var="LOG_${role}"
  upper=$(echo "$role" | tr '[:lower:]' '[:upper:]')
  echo
  echo "  ---- guest $role ----"
  grep -E "MMO_QUAD_${upper}:|TIMEOUT" "${!log_var}" | sed 's/^/  /'
  f=$(count "MMO_QUAD_${upper}:.*FAIL" "${!log_var}"); f=${f:-0}
  d=$(count "MMO_QUAD_${upper}:.*DONE" "${!log_var}"); d=${d:-0}
  total_fail=$(( total_fail + f ))
  [ "$d" -ne 1 ] && total_incomplete=$(( total_incomplete + 1 ))
done

warns=""
for role in "${ROLES[@]}"; do
  log_var="LOG_${role}"
  more=$(grep -h "WARN barrier" "${!log_var}" 2>/dev/null || true)
  [ -n "$more" ] && warns="$warns$more"$'\n'
done

hub_fail=0
hub_drops=$(count 'refused a relayed message' "$HUB_LOG"); hub_drops=${hub_drops:-0}
hub_sessions=$(count 'session [0-9]*:' "$HUB_LOG"); hub_sessions=${hub_sessions:-0}
hub_errors=$(count ' ERROR ' "$HUB_LOG"); hub_errors=${hub_errors:-0}
hub_joined=$(count 'joined' "$HUB_LOG"); hub_joined=${hub_joined:-0}

echo
echo "  ---- hub ----"
echo "  joins: $hub_joined   sessions brokered: $hub_sessions" \
     "  relay drops: $hub_drops   errors: $hub_errors"
grep -E 'WARN|ERROR' "$HUB_LOG" | head -10 | sed 's/^/  /'

if [ "$hub_drops" -ne 0 ]; then
  # The whole 2-on-2 rides the relay path, so a dropped payload is a turn that
  # half-happened. It can pass every in-game assertion and still be a fault.
  echo "  !! the hub refused $hub_drops relayed payload(s) -- a battle lost traffic"
  hub_fail=$((hub_fail + 1))
fi
if [ "$hub_errors" -ne 0 ]; then
  echo "  !! the hub logged $hub_errors error(s)"
  hub_fail=$((hub_fail + 1))
fi

dump_logs() {
  for role in "${ROLES[@]}"; do
    log_var="LOG_${role}"
    echo
    echo "  ---- guest $role log (tail) ----"
    tail -25 "${!log_var}" | sed 's/^/  /'
  done
  echo
  echo "  ---- hub log (tail) ----"
  tail -25 "$HUB_LOG" | sed 's/^/  /'
  echo
  echo "  full logs kept:"
  for role in "${ROLES[@]}"; do log_var="LOG_${role}"; echo "    ${!log_var}"; done
  echo "    $HUB_LOG"
}

echo
if [ -n "$warns" ]; then
  echo "  BARRIER WARNINGS -- the PHASE table is thinner than the work it covers:"
  echo "$warns" | sed 's/^/  /'
  echo
fi
if [ "$total_incomplete" -ne 0 ]; then
  echo "  RESULT: incomplete -- $total_incomplete of 4 never reached DONE."
  dump_logs
  exit 1
fi
if [ "$total_fail" -ne 0 ] || [ "$hub_fail" -ne 0 ]; then
  echo "  RESULT: FAILED -- $total_fail guest + $hub_fail hub failure(s)."
  dump_logs
  exit 1
fi
if [ -n "$warns" ]; then
  echo "  RESULT: assertions passed, but a barrier warned. Raise it in"
  echo "          $DRIVERS/mmo_util.lua's PHASE table before trusting this."
  exit 1
fi
echo "  RESULT: four-client party-versus-party passed. Screenshots in $SHOT_DIR"
for role in "${ROLES[@]}"; do log_var="LOG_${role}"; rm -f "${!log_var}"; done
rm -f "$HUB_LOG"
