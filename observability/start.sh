#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Reuse the repository's .env loading and Compose wrapper. This script is the
# containers-only escape hatch; it should honor the same provider choice as
# build.sh/start.sh instead of assuming Docker.
# shellcheck source=../scripts/common.sh
source "$SCRIPT_DIR/../scripts/common.sh"

: "${DATOMIC_HOME:?DATOMIC_HOME is not set. Copy .env.example to .env and set it.}"
DATOMIC_LOG_PATH="${DATOMIC_LOG_PATH:-${DATOMIC_HOME}/log}"
export DATOMIC_LOG_PATH

case "${DATOMIC_COMPOSE:-}" in
  'docker compose') COMPOSE=(docker compose) ;;
  'podman compose') COMPOSE=(podman compose) ;;
  '')
    if has docker && docker compose version >/dev/null 2>&1; then COMPOSE=(docker compose)
    elif has podman && podman compose version >/dev/null 2>&1; then COMPOSE=(podman compose)
    fi ;;
  *)
    echo "DATOMIC_COMPOSE must be 'docker compose' or 'podman compose'." >&2
    exit 1 ;;
esac
(( ${#COMPOSE[@]} > 0 )) || { echo 'No working Compose provider found.' >&2; exit 1; }
"${COMPOSE[@]}" version >/dev/null 2>&1 || { echo "Compose provider is unavailable: ${COMPOSE[*]}" >&2; exit 1; }

case "${1:-up}" in
  up)
    echo "→ Starting observability stack..."
    compose up -d

    echo ""
    echo "→ Start the Datomic transactor in a separate terminal:"
    echo ""
    echo "   cd $DATOMIC_HOME && JAVA_TOOL_OPTIONS=-Duser.timezone=UTC bin/transactor config/transactor.properties"
    echo ""
    echo "   (JVM forced to UTC so log timestamps match Promtail's fixed UTC parsing,"
    echo "   independent of this machine's local timezone.)"
    echo ""
    echo "→ Optional — start the peer lab in a third terminal:"
    echo ""
    echo "   cd $(dirname "$SCRIPT_DIR")/peer-lab && clj -M:dev"
    echo ""
    echo "─────────────────────────────────────────"
    echo "  Grafana        → http://localhost:3000  (no login required)"
    echo "  Prometheus     → http://localhost:9090"
    echo "  Loki           → http://localhost:3100"
    echo "  Transactor     → http://localhost:9100/metrics  (once transactor is up)"
    echo "  Peer           → http://localhost:9101/metrics  (once peer-lab is up)"
    echo "─────────────────────────────────────────"

    GRAFANA_URL="http://localhost:3000/d/datomic-overview"
    echo "→ Opening transactor dashboard: $GRAFANA_URL"
    if command -v open >/dev/null 2>&1; then
      open "$GRAFANA_URL"
    elif command -v xdg-open >/dev/null 2>&1; then
      xdg-open "$GRAFANA_URL"
    fi
    ;;

  down)
    compose down
    ;;

  down-v)
    echo "→ Stopping stack and wiping all data volumes..."
    compose down -v
    ;;

  validate)
    echo "→ Checking transactor metrics endpoint..."
    curl -sf http://localhost:9100/metrics | grep -c "datomic_transactor" \
      && echo "✓ Transactor metrics OK" \
      || echo "✗ Transactor metrics not reachable — is the transactor running?"

    echo ""
    echo "→ Checking peer metrics endpoint..."
    curl -sf http://localhost:9101/metrics | grep -c "datomic_peer" \
      && echo "✓ Peer metrics OK" \
      || echo "✗ Peer metrics not reachable — is peer-lab running? (cd peer-lab && clj -M:dev)"

    echo ""
    echo "→ Checking Prometheus target..."
    curl -sf "http://localhost:9090/api/v1/targets" \
      | grep -o '"health":"[^"]*"' | head -1
    echo ""

    echo "→ Checking Loki..."
    curl -sf "http://localhost:3100/loki/api/v1/labels" | grep -q '"status":"success"' \
      && echo "✓ Loki OK" \
      || echo "✗ Loki not ready"
    ;;

  reload)
    # Prometheus runs with --web.enable-lifecycle, so a config change (a new
    # scrape target, say) needs no container restart.
    echo "→ Reloading Prometheus config..."
    curl -sf -X POST http://localhost:9090/-/reload \
      && echo "✓ Reloaded" \
      || echo "✗ Reload failed — is Prometheus running?"
    ;;

  logs)
    compose logs -f "${2:-}"
    ;;

  *)
    echo "Usage: $0 [up|down|down-v|validate|reload|logs [service]]"
    exit 1
    ;;
esac
