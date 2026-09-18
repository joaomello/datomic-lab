#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/scripts/common.sh"
requirements run
installation
"${COMPOSE[0]}" info >/dev/null 2>&1 || fail "Container runtime unavailable. Check your context and start Colima, Docker Desktop, or the Podman machine. See TROUBLESHOOTING.md."
[[ "$DATOMIC_START_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || fail "DATOMIC_START_TIMEOUT must be a positive number of seconds."
if [[ ! "$DATOMIC_CONSOLE_PORT" =~ ^[1-9][0-9]*$ ]] || (( DATOMIC_CONSOLE_PORT > 65535 )); then fail "Invalid DATOMIC_CONSOLE_PORT."; fi
[[ -f "$DATOMIC_HOME/lib/datomic-metrics-standalone.jar" && -f "$DATOMIC_TRANSACTOR_CONFIG" && -d "$DATOMIC_LOG_PATH" ]] || fail "Build is incomplete. Run ./build.sh first."
compose config >/dev/null
ports=(9100 "$DATOMIC_CONSOLE_PORT")
if [[ "$DATOMIC_URI" == datomic:dev://localhost:4334/ ]]; then ports+=(4334 4335); fi
for port in "${ports[@]}"; do
  if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    fail "Port $port is in use. Inspect: lsof -nP -iTCP:$port -sTCP:LISTEN. Stop the existing service or adjust its configuration."
  fi
done

mkdir -p "$RUN_DIR"
mkdir "$RUN_DIR/active" 2>/dev/null || fail "A session is already active. See TROUBLESHOOTING.md if its terminal was killed."
# Lets ./transactor-restart.sh find this running session and signal it; not
# used to control anything after a crash (see TROUBLESHOOTING.md).
printf '%s' "$$" > "$RUN_DIR/active/pid"
containers_started=false transactor_pid="" console_pid=""
read -r -a transactor_options <<< "$DATOMIC_JAVA_OPTS"

# memory-index-max/-threshold and object-cache-max configure the transactor
# but Datomic never reports them at runtime; read the same file the transactor
# uses so the Grafana reference lines track it instead of a hand-maintained copy.
property() {
  sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*([0-9]+)([kKmMgG]?).*/\1 \2/p" "$DATOMIC_TRANSACTOR_CONFIG" | tail -1
}
to_mb() {
  local num="$1" unit="$2"
  case "$unit" in
    [gG]) echo $((num * 1024)) ;;
    [kK]) echo $((num / 1024)) ;;
    *) echo "$num" ;;
  esac
}

start_transactor() {
  local mem_max mem_threshold ocache_max
  DATOMIC_METRICS_MEMORY_INDEX_MAX_MB="" DATOMIC_METRICS_MEMORY_INDEX_THRESHOLD_MB="" DATOMIC_METRICS_OBJECT_CACHE_MAX_MB=""
  read -r mem_max mem_max_unit < <(property memory-index-max) || true
  [[ -n "$mem_max" ]] && DATOMIC_METRICS_MEMORY_INDEX_MAX_MB="$(to_mb "$mem_max" "$mem_max_unit")"
  read -r mem_threshold mem_threshold_unit < <(property memory-index-threshold) || true
  [[ -n "$mem_threshold" ]] && DATOMIC_METRICS_MEMORY_INDEX_THRESHOLD_MB="$(to_mb "$mem_threshold" "$mem_threshold_unit")"
  read -r ocache_max ocache_max_unit < <(property object-cache-max) || true
  [[ -n "$ocache_max" ]] && DATOMIC_METRICS_OBJECT_CACHE_MAX_MB="$(to_mb "$ocache_max" "$ocache_max_unit")"
  export DATOMIC_METRICS_MEMORY_INDEX_MAX_MB DATOMIC_METRICS_MEMORY_INDEX_THRESHOLD_MB DATOMIC_METRICS_OBJECT_CACHE_MAX_MB
  (
    cd "$DATOMIC_HOME"
    exec bin/transactor "${transactor_options[@]}" "$DATOMIC_TRANSACTOR_CONFIG"
  ) >> "$RUN_DIR/transactor.log" 2>&1 &
  transactor_pid=$!
}

restart_transactor() {
  info "Restarting the transactor with $DATOMIC_TRANSACTOR_CONFIG"
  kill "$transactor_pid" 2>/dev/null || true
  wait "$transactor_pid" 2>/dev/null || true
  start_transactor
  info "Transactor restarted (PID $transactor_pid). Console keeps running; reconnect it if it shows a stale connection."
}

cleanup() {
  local status=$? pid i alive
  trap - EXIT INT TERM HUP
  info "Stopping processes and containers (data is preserved)"
  for pid in "$transactor_pid" "$console_pid"; do [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true; done
  for ((i=0; i<20; i++)); do
    alive=false
    for pid in "$transactor_pid" "$console_pid"; do [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && alive=true; done
    if [[ "$alive" == false ]]; then break; fi
    sleep 1
  done
  for pid in "$transactor_pid" "$console_pid"; do
    [[ -n "$pid" ]] || continue
    if kill -0 "$pid" 2>/dev/null; then
      printf 'PID %s has not stopped; inspect it before restarting. No force kill was sent.\n' "$pid" >&2
    else wait "$pid" 2>/dev/null || true
    fi
  done
  if [[ "$containers_started" == true ]]; then
    if (( status != 0 && status != 130 && status != 143 )); then compose logs --tail=40 || true; fi
    compose down || status=1
  fi
  rm -f "$RUN_DIR/active/pid"
  rmdir "$RUN_DIR/active"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap restart_transactor HUP

containers_started=true
info "Starting observability"
compose up -d
read -r -a console_options <<< "$DATOMIC_CONSOLE_JAVA_OPTS"
info "Starting transactor and Datomic Console"
start_transactor
(
  cd "$DATOMIC_HOME"
  # bin/console wraps Java without exec; use its entry point so this shell owns
  # the JVM directly and Ctrl+C cannot leave an orphan Console.
  classpath="$(bin/classpath)"
  exec java -server "${console_options[@]}" -cp "lib/console/*:$classpath" \
    clojure.main -i bin/bridge.clj --main datomic.console -p "$DATOMIC_CONSOLE_PORT" dev "$DATOMIC_URI"
) > "$RUN_DIR/console.log" 2>&1 &
console_pid=$!

check_children() {
  local pid
  for pid in "$transactor_pid" "$console_pid"; do
    kill -0 "$pid" 2>/dev/null || fail "A Datomic JVM exited. See .run/transactor.log and .run/console.log."
  done
}
info "Waiting for services, transactor metrics, and logs in Loki (the first report can take a minute)"
deadline=$((SECONDS+DATOMIC_START_TIMEOUT))
until healthy; do
  check_children
  (( SECONDS < deadline )) || fail "Readiness timed out. Logs are in .run/. See TROUBLESHOOTING.md for scrape and log checks."
  sleep 2
done
grafana_url="http://localhost:3000/d/datomic-overview"
open_url "$grafana_url"
printf '\nDatomic Console  http://localhost:%s/browse\nGrafana          %s (anonymous local access)\nPrometheus       http://localhost:9090\n\nKeep this terminal open. Ctrl+C stops everything and preserves data.\n' "$DATOMIC_CONSOLE_PORT" "$grafana_url"
while true; do check_children; sleep 2; done
