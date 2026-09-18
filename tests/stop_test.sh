#!/usr/bin/env bash
# Isolated stop fixtures: never discover or stop real JVMs or containers.
set -euo pipefail
PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/datomic-stop-test.XXXXXX")"
mkdir -p "$TASK_TMP/scripts" "$TASK_TMP/tools" "$TASK_TMP/.run/active"
cp "$PROJECT/stop.sh" "$TASK_TMP/"
cp "$PROJECT/scripts/common.sh" "$TASK_TMP/scripts/"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TASK_TMP/tools/pgrep"
printf '#!/usr/bin/env bash\nexit "${COMPOSE_EXIT:-0}"\n' > "$TASK_TMP/tools/docker"
chmod +x "$TASK_TMP/tools/pgrep" "$TASK_TMP/tools/docker"
export PATH="$TASK_TMP/tools:$PATH" DATOMIC_ENV="$TASK_TMP/no-env"
export DATOMIC_HOME="$TASK_TMP/no-install" DATOMIC_COMPOSE='docker compose'

# Use a reaped child PID to represent an interrupted session.
true &
dead_pid=$!
wait "$dead_pid"
printf '%s' "$dead_pid" > "$TASK_TMP/.run/active/pid"
bash "$TASK_TMP/stop.sh"
[[ ! -d "$TASK_TMP/.run/active" ]]
bash "$TASK_TMP/stop.sh"
echo 'PASS: stale PID file is removed and repeated stop succeeds'

mkdir "$TASK_TMP/.run/active"
printf '%s' "$$" > "$TASK_TMP/.run/active/pid"
if bash "$TASK_TMP/stop.sh"; then echo 'Unexpected success for live session'; exit 1; fi
[[ "$(<"$TASK_TMP/.run/active/pid")" == "$$" ]]
echo 'PASS: live session marker is preserved'

printf '%s' "$dead_pid" > "$TASK_TMP/.run/active/pid"
if COMPOSE_EXIT=1 bash "$TASK_TMP/stop.sh"; then echo 'Unexpected success for failed shutdown'; exit 1; fi
[[ -f "$TASK_TMP/.run/active/pid" ]]
echo 'PASS: failed shutdown preserves the marker'

printf 'Stop checks passed. Fixtures: %s\n' "$TASK_TMP"
