#!/usr/bin/env bash
#
# Focused end-to-end: two partied players on the same map, host steps a wild
# encounter, both auto-join into hub-refereed coop_wild, host throws a
# MASTER_BALL, and the catcher grant lands in the host party.
#
# Reuses mmo_host.lua / mmo_join.lua. Both early-exit after party formation
# and the wild divert once MMO_PARTY_WILD_E2E=1 (see the "party wild" blocks
# there). The full LAN coop trainer leg in run-mmo-e2e.sh is untouched.
#
# Run from the Gen1Recomp checkout root with this mod symlinked into mods/:
#
#   bash mods/rby_mmo/tests/drivers/run-party-wild-e2e.sh
#
# Prerequisites (same as run-mmo-e2e.sh):
#   - ROM imported (data/generated/ present) or ROM_PATH in mods/rby_mmo/.env
#   - love on PATH
#   - mods/rby_mmo -> this checkout
#
# Wild is staged through BattleState.newWild in the driver (not grass RNG).
# Two LOVE windows drive themselves; do not click into them.

set -uo pipefail
export MMO_PARTY_WILD_E2E=1
export MMO_TIMEOUT="${MMO_TIMEOUT:-900}"
exec "$(dirname "$0")/run-mmo-e2e.sh"
