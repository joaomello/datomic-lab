#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/scripts/common.sh"

# Safety net for an interrupted terminal: normal Ctrl+C already stops
# everything via ./start.sh's own trap. Find leftover JVMs by matching the
# command lines start.sh launches; the saved PID identifies only the supervisor.
case "${DATOMIC_COMPOSE:-}" in
  'docker compose') COMPOSE=(docker compose) ;;
  'podman compose') COMPOSE=(podman compose) ;;
  '')
    if has docker && docker compose version >/dev/null 2>&1; then COMPOSE=(docker compose)
    elif has podman && podman compose version >/dev/null 2>&1; then COMPOSE=(podman compose)
    fi ;;
esac

status=0
have_datomic=false
if [[ "$DATOMIC_HOME" == /* && -x "$DATOMIC_HOME/bin/transactor" ]]; then
  have_datomic=true
  DATOMIC_LOG_PATH="${DATOMIC_LOG_PATH:-$DATOMIC_HOME/log}"
  DATOMIC_TRANSACTOR_CONFIG="${DATOMIC_TRANSACTOR_CONFIG:-$ROOT_DIR/config/transactor.properties}"
fi

info "Looking for leftover Datomic transactor and Console processes"
pids=()
if [[ "$have_datomic" == true ]]; then
  while IFS= read -r pid; do [[ -n "$pid" ]] && pids+=("$pid"); done \
    < <(pgrep -f "bin/transactor.*$DATOMIC_TRANSACTOR_CONFIG" 2>/dev/null || true)
fi
while IFS= read -r pid; do [[ -n "$pid" ]] && pids+=("$pid"); done \
  < <(pgrep -f 'clojure.main -i bin/bridge.clj --main datomic.console' 2>/dev/null || true)

if [[ ${#pids[@]} -gt 0 ]]; then
  # de-duplicate
  read -r -a pids <<< "$(printf '%s\n' "${pids[@]}" | sort -un | tr '\n' ' ')"
  info "Stopping PIDs: ${pids[*]}"
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  for ((i=0; i<10; i++)); do
    alive=false
    for pid in "${pids[@]}"; do kill -0 "$pid" 2>/dev/null && alive=true; done
    [[ "$alive" == false ]] && break
    sleep 1
  done
  for pid in "${pids[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      printf 'PID %s did not stop; inspect it and kill -9 manually if needed.\n' "$pid" >&2
      status=1
    fi
  done
else
  info "No leftover Datomic JVMs found"
fi

if [[ ${#COMPOSE[@]} -gt 0 ]]; then
  info "Stopping observability containers (data volumes are preserved)"
  DATOMIC_LOG_PATH="${DATOMIC_LOG_PATH:-}" "${COMPOSE[@]}" -f "$ROOT_DIR/observability/docker-compose.yml" down || status=1
else
  printf 'No container runtime detected; skipping "compose down". Stop containers yourself if any are running.\n' >&2
fi

if [[ -d "$RUN_DIR/active" ]]; then
  session_pid=""
  if [[ -f "$RUN_DIR/active/pid" ]]; then
    session_pid="$(<"$RUN_DIR/active/pid")"
  fi
  if [[ "$session_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$session_pid" 2>/dev/null; then
    printf 'Session PID %s is still running; keeping the active marker.\n' "$session_pid" >&2
    status=1
  elif (( status != 0 )); then
    printf 'Shutdown incomplete; keeping %s/active.\n' "$RUN_DIR" >&2
  elif rm -f "$RUN_DIR/active/pid" && rmdir "$RUN_DIR/active" 2>/dev/null; then
    info "Cleared stale $RUN_DIR/active marker"
  else
    printf 'Could not clear %s/active; remove it by hand once nothing is running.\n' "$RUN_DIR" >&2
    status=1
  fi
fi

if (( status == 0 )); then
  info "Everything stopped. Databases and container volumes were preserved."
else
  printf 'Some things may still be running; see messages above.\n' >&2
fi
exit "$status"
