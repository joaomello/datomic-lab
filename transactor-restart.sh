#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/scripts/common.sh"
installation

pid_file="$RUN_DIR/active/pid"
[[ -f "$pid_file" ]] || fail "No active session found. Start one with ./start.sh."
pid="$(<"$pid_file")"
kill -0 "$pid" 2>/dev/null || fail "No active session found. Start one with ./start.sh."

info "Restarting the transactor in the running session (PID $pid) with $DATOMIC_TRANSACTOR_CONFIG"
kill -HUP "$pid"
