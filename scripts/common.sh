#!/usr/bin/env bash
# Shared configuration and checks for build.sh and start.sh.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# .env is the one place that records this machine's setup. It is trusted shell
# config, readable and editable by hand; explicit environment values win.
ENV_FILE="${DATOMIC_ENV:-$ROOT_DIR/.env}"
saved_names=() saved_values=()
for name in DATOMIC_HOME DATOMIC_VERSION DATOMIC_DOWNLOAD DATOMIC_CLEAN DATOMIC_DOWNLOAD_DIR DATOMIC_JAVA_OPTS DATOMIC_CONSOLE_JAVA_OPTS DATOMIC_TRANSACTOR_CONFIG DATOMIC_CONSOLE_PORT DATOMIC_URI DATOMIC_LOG_PATH DATOMIC_COMPOSE DATOMIC_START_TIMEOUT DATOMIC_ENV JAVA_HOME JAVA_TOOL_OPTIONS; do
  if [[ -n "${!name+x}" ]]; then
    saved_names+=("$name") saved_values+=("${!name}")
  fi
done
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
fi
for ((i=0; i<${#saved_names[@]}; i++)); do
  printf -v "${saved_names[i]}" '%s' "${saved_values[i]}"
  export "${saved_names[i]}"
done

# shellcheck disable=SC2034 # consumed by build.sh and start.sh
RUN_DIR="$ROOT_DIR/.run"
DATOMIC_VERSION="${DATOMIC_VERSION:-1.0.7705}"
DATOMIC_HOME="${DATOMIC_HOME:-}"
DATOMIC_DOWNLOAD_DIR="${DATOMIC_DOWNLOAD_DIR:-$ROOT_DIR/.datomic}"
DATOMIC_CONSOLE_PORT="${DATOMIC_CONSOLE_PORT:-8080}"
DATOMIC_URI="${DATOMIC_URI:-datomic:dev://localhost:4334/}"
DATOMIC_START_TIMEOUT="${DATOMIC_START_TIMEOUT:-180}"
DATOMIC_JAVA_OPTS="${DATOMIC_JAVA_OPTS:--Xms1g -Xmx1g -XX:+UseG1GC -XX:MaxGCPauseMillis=50 -Duser.timezone=UTC}"
DATOMIC_CONSOLE_JAVA_OPTS="${DATOMIC_CONSOLE_JAVA_OPTS:--Xmx512m -Duser.timezone=UTC}"
# This script's shebang runs bash non-interactively, so it never sources
# .zshrc/.zprofile: tools whose PATH entry is only added there (e.g. Homebrew's
# `brew shellenv`) are invisible here even though they work in an interactive
# shell. Add the standard Homebrew bin dirs so `has` matches what the user sees.
for brew_bin in /opt/homebrew/bin /usr/local/bin; do
  [[ -d "$brew_bin" && ":$PATH:" != *":$brew_bin:"* ]] && PATH="$PATH:$brew_bin"
done
if [[ -n "${JAVA_HOME:-}" ]]; then export PATH="$JAVA_HOME/bin:$PATH"; fi
COMPOSE=()

info() { printf '→ %s\n' "$*"; }
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }
http() { curl --connect-timeout 2 --max-time 5 --silent --fail "$@"; }
# Best-effort: open a URL in the default browser. Silent no-op if neither tool exists.
open_url() {
  if has open; then open "$1" >/dev/null 2>&1 || true
  elif has xdg-open; then xdg-open "$1" >/dev/null 2>&1 || true
  fi
}

# Print one missing-prerequisite message with the install command for this OS.
missing() {
  local what="$1" mac="$2" linux="$3"
  printf '%s\n' "$what" >&2
  if [[ "$(uname -s)" == Darwin ]]; then printf '  Install: %s\n' "$mac" >&2
  else printf '  Install: %s\n' "$linux" >&2
  fi
}

requirements() {
  local mode="$1" errors=0 version found
  if [[ -n "${JAVA_HOME:-}" && ! -x "$JAVA_HOME/bin/java" ]]; then
    fail "JAVA_HOME does not contain bin/java. Configure JAVA_HOME or unset it to use PATH."
  fi
  # GA releases print `version "21"` with no minor part, so accept `.` or `"`.
  if ! version="$(java -version 2>&1)" || [[ ! "$version" =~ version\ \"(17|21|25)[.\"] ]]; then
    if has java; then found="$(printf '%s\n' "$version" | head -1)"; else found=""; fi
    missing "Java 17, 21, or 25 is required. Found: ${found:-no java on PATH}" \
      'brew install --cask temurin@21   (or set JAVA_HOME to a supported JDK)' \
      'sudo apt install -y openjdk-21-jdk   (or set JAVA_HOME to a supported JDK)'
    errors=$((errors+1))
  fi
  if ! has curl; then
    missing 'curl is required.' 'brew install curl' 'sudo apt install -y curl'; errors=$((errors+1))
  fi
  if [[ "$mode" == build ]]; then
    if ! has clojure || ! clojure -Sdescribe >/dev/null 2>&1; then
      missing 'Clojure CLI is required to build the exporter.' \
        'brew install clojure/tools/clojure' \
        'see https://clojure.org/guides/install_clojure#_linux_instructions'
      errors=$((errors+1))
    fi
  elif ! has lsof; then
    missing 'lsof is required to check ports.' 'lsof ships with macOS; check your PATH' 'sudo apt install -y lsof'
    errors=$((errors+1))
  fi
  case "${DATOMIC_COMPOSE:-}" in
    'docker compose') COMPOSE=(docker compose) ;;
    'podman compose') COMPOSE=(podman compose) ;;
    '')
      if has docker && docker compose version >/dev/null 2>&1; then COMPOSE=(docker compose)
      elif has podman && podman compose version >/dev/null 2>&1; then COMPOSE=(podman compose)
      fi ;;
    *) fail "DATOMIC_COMPOSE must be 'docker compose' or 'podman compose'." ;;
  esac
  if [[ ${#COMPOSE[@]} == 0 ]] || ! "${COMPOSE[@]}" version >/dev/null 2>&1; then
    if ! has docker && ! has podman; then
      missing 'Docker is not installed.' \
        'Docker Desktop, or: brew install colima docker docker-compose' \
        'Docker Engine and docker-compose-plugin, see https://docs.docker.com/engine/install/'
    elif has docker && ! docker compose version >/dev/null 2>&1; then
      # `docker compose version` is client-side: it fails only when the plugin
      # is missing, whether or not the daemon is running.
      # shellcheck disable=SC2016 # printed for the participant to run, not expanded here
      missing 'docker is installed but the "docker compose" plugin is missing.' \
        'brew install docker-compose && mkdir -p ~/.docker/cli-plugins && ln -sfn "$(brew --prefix)/opt/docker-compose/bin/docker-compose" ~/.docker/cli-plugins/docker-compose' \
        'sudo apt install -y docker-compose-plugin'
    elif has podman && ! podman compose version >/dev/null 2>&1; then
      printf 'podman is installed but "podman compose" is missing. Install a Compose provider (e.g. podman-compose).\n' >&2
    fi
    errors=$((errors+1))
  fi
  (( errors == 0 )) || fail "$errors prerequisite check(s) failed. See TROUBLESHOOTING.md#install-the-prerequisites."
}

installation() {
  [[ "$DATOMIC_HOME" == /* ]] || fail "Set DATOMIC_HOME in .env to an absolute path, or run ./build.sh to choose a path or download."
  [[ -x "$DATOMIC_HOME/bin/transactor" && -x "$DATOMIC_HOME/bin/console" && -x "$DATOMIC_HOME/bin/classpath" && -d "$DATOMIC_HOME/lib/console" && -f "$DATOMIC_HOME/VERSION" ]] ||
    fail "Not a complete Datomic Pro installation (including Console): $DATOMIC_HOME"
  DATOMIC_LOG_PATH="${DATOMIC_LOG_PATH:-$DATOMIC_HOME/log}"
  # Defaults to this repo's own file, used in place — edit it and restart to
  # pick up changes. Set DATOMIC_TRANSACTOR_CONFIG to use a different one.
  DATOMIC_TRANSACTOR_CONFIG="${DATOMIC_TRANSACTOR_CONFIG:-$ROOT_DIR/config/transactor.properties}"
  [[ "$DATOMIC_TRANSACTOR_CONFIG" == /* && "$DATOMIC_LOG_PATH" == /* ]] || fail "Config and log paths must be absolute."
}

compose() {
  DATOMIC_LOG_PATH="$DATOMIC_LOG_PATH" "${COMPOSE[@]}" -f "$ROOT_DIR/observability/docker-compose.yml" "$@"
}

healthy() {
  local result url
  for url in http://localhost:9100/metrics "http://localhost:$DATOMIC_CONSOLE_PORT" http://localhost:9090/-/ready http://localhost:3100/ready http://localhost:3000/api/health; do
    http "$url" >/dev/null || return 1
  done
  result="$(http --get --data-urlencode 'query=up{job="datomic-transactor"}' http://localhost:9090/api/v1/query)" || return 1
  [[ "$result" =~ \"value\":\[[^]]*,\"1\"\] ]] || return 1
  result="$(http --get --data-urlencode 'query={job="datomic"}' --data-urlencode 'limit=1' http://localhost:3100/loki/api/v1/query_range)" || return 1
  [[ "$result" == *'"values":[['* ]]
}
