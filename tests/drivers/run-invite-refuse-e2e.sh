#!/usr/bin/env bash
#
# Focused end-to-end: a battle invite that arrives while the host is mid-
# trainer fight must be auto-refused -- no yes/no over the fight, and the
# guest must see the refusal.
#
# Reuses mmo_host.lua / mmo_join.lua. Both early-exit after host/guest chat
# once MMO_INVITE_REFUSE_E2E=1 (see the "invite refuse" blocks there).
#
#   bash mods/rby_mmo/tests/drivers/run-invite-refuse-e2e.sh
#
# Same prerequisites as run-mmo-e2e.sh (ROM imported, love on PATH, mod
# symlinked into mods/). Shorter wall-clock budget: this run never reaches
# trade / link battle / co-op.

set -uo pipefail
export MMO_INVITE_REFUSE_E2E=1
export MMO_TIMEOUT="${MMO_TIMEOUT:-600}"
exec "$(dirname "$0")/run-mmo-e2e.sh"
