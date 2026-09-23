#!/usr/bin/env bash
# Exercise build/start lifecycle in isolation; no real JVMs or containers start.
set -euo pipefail
PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/datomic-setup-test.XXXXXX")"
TASK_TMP="$(cd "$TASK_TMP" && pwd)"
REPO="$TASK_TMP/repo"
export TRACE_DIR="$TASK_TMP/trace"
mkdir -p "$REPO/scripts" "$REPO/config" "$REPO/metrics-exporter" "$REPO/observability" "$TRACE_DIR" "$TASK_TMP/tools"
cp "$PROJECT/build.sh" "$PROJECT/start.sh" "$PROJECT/transactor-restart.sh" "$REPO/"
cp "$PROJECT/scripts/common.sh" "$REPO/scripts/"
cp "$PROJECT/config/transactor.properties" "$REPO/config/"
cp "$PROJECT/.env.example" "$REPO/"

# Runtime fixtures emulate external tools; their arguments and signals are real.
cat > "$TASK_TMP/tools/java" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == -version ]]; then echo 'openjdk version "21.0.1"' >&2; exit; fi
printf '%s\n' "$@" > "$TRACE_DIR/console-args"
echo $$ > "$TRACE_DIR/console-pid"
exec sleep 300
EOF
cat > "$TASK_TMP/tools/clojure" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == -Sdescribe ]]; then exit; fi
mkdir -p target
printf fixture > target/datomic-metrics-standalone.jar
EOF
cat > "$TASK_TMP/tools/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TRACE_DIR/compose"
EOF
cat > "$TASK_TMP/tools/lsof" <<'EOF'
#!/usr/bin/env bash
[[ "${PORT_CONFLICT:-}" == 1 ]]
EOF
cat > "$TASK_TMP/tools/curl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *datomic-pro-downloads*)
    # Emulate an interrupted transfer: real curl leaves the -o file behind.
    prev=""; out=""
    for arg in "$@"; do if [[ "$prev" == -o ]]; then out="$arg"; fi; prev="$arg"; done
    if [[ -n "$out" ]]; then printf 'partial' > "$out"; fi
    exit 22 ;;
  *query_range*) printf '{"data":{"result":[{"values":[["123","log"]]}]}}' ;;
  *api/v1/query*) printf '{"data":{"result":[{"value":[123,"1"]}]}}' ;;
  *) printf '{}' ;;
esac
EOF
chmod +x "$TASK_TMP/tools/"*
export PATH="$TASK_TMP/tools:$PATH"
unset JAVA_HOME DATOMIC_HOME DATOMIC_DOWNLOAD DATOMIC_DOWNLOAD_DIR DATOMIC_TRANSACTOR_CONFIG DATOMIC_COMPOSE
export DATOMIC_ENV="$REPO/.env" DATOMIC_START_TIMEOUT=5

fixture() {
  mkdir -p "$1/bin" "$1/lib/console" "$1/config" "$1/log"
  printf '1.0.7705\n' > "$1/VERSION"
  cat > "$1/bin/transactor" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$TRACE_DIR/transactor-args"
echo $$ > "$TRACE_DIR/transactor-pid"
if [[ "${FAIL_TRANSACTOR:-}" == 1 ]]; then exit 2; fi
exec sleep 300
EOF
  printf '#!/usr/bin/env bash\nexit 0\n' > "$1/bin/console"
  printf '#!/usr/bin/env bash\necho fixture\n' > "$1/bin/classpath"
  chmod +x "$1/bin/"*
}
# The first-run and use/clean questions only appear on a terminal, so they are
# exercised through script(1). BSD and util-linux differ in argument order.
if script -q /dev/null true >/dev/null 2>&1; then TTY_STYLE=bsd
elif script -qec true /dev/null >/dev/null 2>&1; then TTY_STYLE=gnu
else TTY_STYLE=none; echo 'NOTE: no usable script(1); skipping interactive cases'
fi
tty_run() {
  local answer="$1"
  shift
  # The pause lets the prompt appear before the answer is typed into the pty.
  if [[ "$TTY_STYLE" == bsd ]]; then
    { sleep 0.4; printf '%s\n' "$answer"; sleep 0.2; } | script -q /dev/null "$@" 2>&1 | tr -d '\r'
  else
    { sleep 0.4; printf '%s\n' "$answer"; sleep 0.2; } | script -qec "$*" /dev/null 2>&1 | tr -d '\r'
  fi
}

expect_failure() {
  local expected="$1"
  shift
  if "$@" > "$TASK_TMP/result" 2>&1; then echo "Unexpected success: $*"; exit 1; fi
  grep -Fq "$expected" "$TASK_TMP/result" || { cat "$TASK_TMP/result"; exit 1; }
}
# Usage must work on a machine that cannot yet build, so it precedes requirements.
JAVA_HOME="$TASK_TMP/missing-jdk" bash "$REPO/build.sh" --help > "$TASK_TMP/help" 2>&1
grep -Fq 'Usage: ./build.sh' "$TASK_TMP/help"
grep -Fq '1.0.7705' "$TASK_TMP/help"
expect_failure 'Unknown option: --nope' bash "$REPO/build.sh" --nope
expect_failure 'Too many arguments' bash "$REPO/build.sh" /one /two
echo 'PASS: --help works without a toolchain; bad arguments are rejected'

# Prerequisite messages name what was found and how to install what is missing.
# Each case shadows one fixture tool with a variant placed earlier on PATH.
variant() {
  local dir="$TASK_TMP/variant-$1"
  mkdir -p "$dir"
  printf '#!/usr/bin/env bash\n%s\n' "$3" > "$dir/$2"
  chmod +x "$dir/$2"
}
check_requirements() {
  PATH="$TASK_TMP/variant-$1:$PATH" bash -c 'source "$1/scripts/common.sh"; requirements build' _ "$REPO"
}
variant java26 java "echo 'openjdk version \"26.0.1\" 2026-04-21' >&2"
expect_failure 'Found: openjdk version "26.0.1"' check_requirements java26
grep -Fq 'Install:' "$TASK_TMP/result"
variant java-ga java "echo 'openjdk version \"21\" 2023-09-19' >&2"
check_requirements java-ga
echo 'PASS: unsupported Java shows the version found; GA "21" is accepted'

# A stale JAVA_HOME (removed or upgraded JDK) falls back to the java on PATH.
JAVA_HOME="$TASK_TMP/missing-jdk" check_requirements none > "$TASK_TMP/java-stale" 2>&1
grep -Fq "ignoring JAVA_HOME=$TASK_TMP/missing-jdk" "$TASK_TMP/java-stale"
# A valid JAVA_HOME wins over PATH, and the error says where that java came from.
variant jdk11/bin java "echo 'openjdk version \"11.0.2\" 2019-01-15' >&2"
JAVA_HOME="$TASK_TMP/variant-jdk11" expect_failure '(from JAVA_HOME)' check_requirements none
grep -Fq 'openjdk version "11.0.2"' "$TASK_TMP/result"
echo 'PASS: stale JAVA_HOME falls back to PATH; a wrong one is named in the error'

# A missing Compose plugin is reported as such even when the daemon is also
# down, instead of first sending the participant to start Colima.
variant no-compose docker 'exit 1'
expect_failure 'docker compose' check_requirements no-compose
if grep -Fq 'colima start' "$TASK_TMP/result"; then cat "$TASK_TMP/result"; exit 1; fi
# Which of the two diagnoses applies depends on the host: common.sh always adds
# Homebrew's bin to PATH, so a machine with the formula installed cannot be made
# to look like one without it. Assert each wording only where it can apply.
if bash -c 'source "$1/scripts/common.sh"; compose_binary >/dev/null' _ "$REPO"; then
  grep -Fq 'not registered as a Docker CLI plugin' "$TASK_TMP/result"
else
  grep -Fq 'plugin is missing' "$TASK_TMP/result"
fi
echo 'PASS: missing compose plugin is diagnosed before the daemon'

# Compose installed but never linked into ~/.docker/cli-plugins: the message
# must say "register", not "install", and name docker-compose over docker-buildx.
variant unregistered docker 'exit 1'
variant unregistered docker-compose 'echo "Docker Compose version 5.5.1"'
expect_failure 'not registered as a Docker CLI plugin' check_requirements unregistered
grep -Fq 'docker-compose, not docker-buildx' "$TASK_TMP/result"
# Advising an install here is what sent a participant in circles; guard it.
if grep -Fq 'brew install docker-compose' "$TASK_TMP/result"; then cat "$TASK_TMP/result"; exit 1; fi
echo 'PASS: installed-but-unregistered Compose is told to register, not install'

expect_failure 'DATOMIC_DOWNLOAD=1' bash "$REPO/build.sh" </dev/null
expect_failure 'Not a complete Datomic' env DATOMIC_HOME="$TASK_TMP/missing" DATOMIC_DOWNLOAD=1 bash "$REPO/build.sh"
expect_failure 'Download failed' env DATOMIC_DOWNLOAD=1 bash "$REPO/build.sh"
[[ ! -f "$REPO/.datomic/datomic-pro-1.0.7705.zip" ]]
# A failed transfer must not leave a partial file behind to grow across retries.
[[ -z "$(find "$REPO/.datomic" -maxdepth 1 -name '*.part' -print -quit)" ]]
echo 'PASS: selection required; invalid paths and failed downloads fail clearly'

# An archive laid out unexpectedly is reported by name instead of a raw mv error.
mkdir -p "$TASK_TMP/badzip/datomic-pro-9.9.9"
touch "$TASK_TMP/badzip/datomic-pro-9.9.9/placeholder"
(cd "$TASK_TMP/badzip" && zip -qr "$REPO/.datomic/datomic-pro-1.0.7705.zip" datomic-pro-9.9.9)
expect_failure 'does not contain datomic-pro-1.0.7705/' env DATOMIC_DOWNLOAD=1 bash "$REPO/build.sh"
[[ -z "$(find "$REPO/.datomic" -maxdepth 1 -name 'extract.*' -print -quit)" ]]
rm -f "$REPO/.datomic/datomic-pro-1.0.7705.zip"
echo 'PASS: malformed archive is rejected and leaves no staging directory'

fixture "$TASK_TMP/archive/datomic-pro-1.0.7705"
(cd "$TASK_TMP/archive" && zip -qr "$REPO/.datomic/datomic-pro-1.0.7705.zip" datomic-pro-1.0.7705)
INSTALL="$REPO/datomic-pro"
[[ ! -e "$REPO/.env" ]]
if [[ "$TTY_STYLE" != none ]]; then
  # Pressing Enter accepts the proposed folder next to the scripts.
  tty_run '' bash "$REPO/build.sh" > "$TASK_TMP/first-run"
  grep -Fq "Install Datomic Pro 1.0.7705 in $INSTALL?" "$TASK_TMP/first-run" ||
    { cat "$TASK_TMP/first-run"; exit 1; }
  [[ -f "$INSTALL/VERSION" && -f "$INSTALL/lib/datomic-metrics-standalone.jar" ]]
  echo 'PASS: first run proposes ./datomic-pro and Enter installs there'
else
  DATOMIC_DOWNLOAD=1 bash "$REPO/build.sh" >/dev/null
fi
# The choice is recorded in .env, created from .env.example, and nowhere else.
grep -Fqx "DATOMIC_HOME='$INSTALL'" "$REPO/.env"
# Everything else in .env must be the documented example, comments included.
diff <(grep -v "^DATOMIC_HOME=" "$REPO/.env") "$REPO/.env.example" >/dev/null
[[ ! -e "$REPO/.run/datomic-home" ]]
echo 'PASS: the installation is recorded in a new .env built from .env.example'

# An existing ./datomic-pro is never replaced without an explicit answer.
if [[ "$TTY_STYLE" != none ]]; then
  touch "$INSTALL/participant-data"
  tty_run use bash "$REPO/build.sh" download > "$TASK_TMP/use"
  grep -Fq 'already exists' "$TASK_TMP/use" || { cat "$TASK_TMP/use"; exit 1; }
  [[ -f "$INSTALL/participant-data" ]]
  tty_run clean bash "$REPO/build.sh" download > "$TASK_TMP/clean"
  [[ ! -e "$INSTALL/participant-data" ]]
  [[ -f "$INSTALL/VERSION" ]]
  echo 'PASS: existing folder offers use (keeps databases) and clean (re-downloads)'
fi
touch "$INSTALL/participant-data"
bash "$REPO/build.sh" download < /dev/null > "$TASK_TMP/reuse" 2>&1
grep -Fq 'Using the existing' "$TASK_TMP/reuse"
[[ -f "$INSTALL/participant-data" ]]
DATOMIC_CLEAN=1 bash "$REPO/build.sh" download < /dev/null >/dev/null 2>&1
[[ ! -e "$INSTALL/participant-data" && -f "$INSTALL/VERSION" ]]
echo 'PASS: unattended runs keep the folder unless DATOMIC_CLEAN=1'

# A leftover session marker must not block rebuilding after shutdown.
mkdir -p "$REPO/.run/active"
touch "$INSTALL/participant-data"
bash "$REPO/build.sh" < /dev/null >/dev/null
[[ -f "$INSTALL/participant-data" ]]
rmdir "$REPO/.run/active"
rm -f "$INSTALL/participant-data"
echo 'PASS: a leftover session marker does not block rebuilding'

# Reading .env alone must be enough to rebuild: no environment, no prompt.
bash "$REPO/build.sh" < /dev/null >/dev/null
[[ "$(grep -c '^DATOMIC_HOME=' "$REPO/.env")" == 1 ]]
grep -Fqx "DATOMIC_HOME='$INSTALL'" "$REPO/.env"
echo 'PASS: .env alone drives a rebuild and the assignment stays unique'

# An installation owned by another user fails before the slow uberjar build.
if [[ "$(id -u)" != 0 ]]; then
  chmod a-w "$INSTALL/lib"
  expect_failure 'Cannot write to' env DATOMIC_HOME="$INSTALL" bash "$REPO/build.sh"
  chmod u+w "$INSTALL/lib"
  echo 'PASS: unwritable installation fails fast with a guiding message'
fi

printf 'DATOMIC_HOME=/invalid/from/env\nDATOMIC_JAVA_OPTS="-Xmx256m"\n' > "$REPO/.env"
export DATOMIC_HOME="$INSTALL"
bash "$REPO/build.sh" >/dev/null
# The environment wins, and .env is corrected so it still describes what runs.
grep -Fqx "DATOMIC_HOME='$INSTALL'" "$REPO/.env"
grep -Fq 'DATOMIC_JAVA_OPTS="-Xmx256m"' "$REPO/.env"
# The transactor config is read from the repo directly; build never copies
# anything into the installation's own (empty) config/ directory.
[[ -z "$(find "$INSTALL/config" -mindepth 1 -print -quit)" ]]
echo 'PASS: environment overrides .env, is recorded there, and config is never copied'

expect_failure 'Properties file does not exist' env DATOMIC_TRANSACTOR_CONFIG="$TASK_TMP/missing.properties" bash "$REPO/build.sh"
echo 'PASS: a configured transactor properties file must already exist'

# A typed path outranks .env and tolerates whitespace from a paste.
ALT="$TASK_TMP/alt-install"
fixture "$ALT"
unset DATOMIC_HOME
bash "$REPO/build.sh" "  $ALT  " >/dev/null
grep -Fqx "DATOMIC_HOME='$ALT'" "$REPO/.env"
[[ -f "$ALT/lib/datomic-metrics-standalone.jar" ]]
export DATOMIC_HOME="$INSTALL"
bash "$REPO/build.sh" >/dev/null
echo 'PASS: positional path overrides .env and is recorded in it'

# Build works with Docker stopped, and says to start it before ./start.sh.
# shellcheck disable=SC2016 # the fixture's own $1, expanded when it runs
variant daemon-down docker '[[ "$1" != info ]]'
PATH="$TASK_TMP/variant-daemon-down:$PATH" bash "$REPO/build.sh" > "$TASK_TMP/build-down" 2>&1
grep -Fq 'Docker is not running' "$TASK_TMP/build-down"
bash "$REPO/build.sh" > "$TASK_TMP/build-up" 2>&1
grep -Fq 'Build complete. Run ./start.sh.' "$TASK_TMP/build-up"
echo 'PASS: build summary reflects whether Docker is running'

expect_failure 'Port 9100 is in use' env PORT_CONFLICT=1 bash "$REPO/start.sh"
[[ ! -d "$REPO/.run/active" ]]
echo 'PASS: occupied port fails before starting services'

export DATOMIC_JAVA_OPTS='-Xms256m -Xmx768m -XX:+UseG1GC -Duser.timezone=UTC -Dworkshop.test=yes'
bash "$REPO/start.sh" > "$TASK_TMP/start-log" 2>&1 &
runner=$!
trap 'kill "$runner" 2>/dev/null || true' EXIT
for ((i=0; i<100; i++)); do
  if grep -q 'Keep this terminal open' "$TASK_TMP/start-log" && [[ -f "$TRACE_DIR/transactor-args" && -f "$TRACE_DIR/console-args" ]]; then break; fi
  sleep 0.1
done
grep -q 'Keep this terminal open' "$TASK_TMP/start-log" || { cat "$TASK_TMP/start-log"; exit 1; }
grep -Fxq -- '-Xmx768m' "$TRACE_DIR/transactor-args"
grep -Fxq -- '-Duser.timezone=UTC' "$TRACE_DIR/transactor-args"
grep -Fxq -- '-Dworkshop.test=yes' "$TRACE_DIR/transactor-args"

# ./transactor-restart.sh signals the running session; the transactor process
# restarts (new PID) while Console is left untouched.
old_transactor_pid="$(cat "$TRACE_DIR/transactor-pid")"
old_console_pid="$(cat "$TRACE_DIR/console-pid")"
bash "$REPO/transactor-restart.sh"
for ((i=0; i<50; i++)); do
  [[ "$(cat "$TRACE_DIR/transactor-pid")" != "$old_transactor_pid" ]] && break
  sleep 0.1
done
[[ "$(cat "$TRACE_DIR/transactor-pid")" != "$old_transactor_pid" ]] || { echo 'transactor did not restart'; exit 1; }
[[ "$(cat "$TRACE_DIR/console-pid")" == "$old_console_pid" ]] || { echo 'console was unexpectedly restarted'; exit 1; }
kill -0 "$old_console_pid" 2>/dev/null || { echo 'console left running after restart failed'; exit 1; }
echo 'PASS: transactor-restart.sh restarts only the transactor'

kill -TERM "$runner"
wait "$runner" || [[ $? == 143 ]]
trap - EXIT
[[ ! -d "$REPO/.run/active" ]]
for role in transactor console; do
  if kill -0 "$(cat "$TRACE_DIR/$role-pid")" 2>/dev/null; then echo "$role left running"; exit 1; fi
done
grep -q ' down$' "$TRACE_DIR/compose"
echo 'PASS: JVM flags forwarded; session protects build; termination stops both children and Compose'

expect_failure 'No active session found' bash "$REPO/transactor-restart.sh"
echo 'PASS: transactor-restart.sh fails clearly with no running session'

expect_failure 'A Datomic JVM exited' env FAIL_TRANSACTOR=1 bash "$REPO/start.sh"
[[ ! -d "$REPO/.run/active" ]]
if kill -0 "$(cat "$TRACE_DIR/console-pid")" 2>/dev/null; then echo 'Console left running after failure'; exit 1; fi
echo 'PASS: JVM failure cleans up the session'
printf 'Setup checks passed. Fixtures: %s\n' "$TASK_TMP"
