#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/scripts/common.sh"

# The installation this repo manages, alongside build.sh and gitignored. Any
# other location is a path the participant supplies and this script never edits.
INSTALL_DIR="$ROOT_DIR/datomic-pro"

usage() {
  cat <<EOF
Usage: ./build.sh [PATH|download]

Prepares this setup: resolves a Datomic Pro installation, records it in .env,
and builds the metrics exporter into it.

  PATH        Absolute path to an existing Datomic Pro installation.
  download    Install Datomic Pro $DATOMIC_VERSION into ./datomic-pro.
  -h, --help  Show this message.

With no argument and nothing configured, build.sh proposes ./datomic-pro and
installs there when you press Enter. If that folder already exists it asks
whether to use it or delete and download again; DATOMIC_CLEAN=1 answers clean.

The whole setup lives in .env, created from .env.example on first run. Read that
file to see exactly what ./start.sh will run; edit it to change anything.
See README.md and TROUBLESHOOTING.md.
EOF
}

# Normalize a path a participant typed or pasted: strip stray surrounding
# whitespace and expand a leading ~, which read(1) does not expand.
normalize() {
  local value="$1" tilde='~'
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  # Matched through a variable so the patterns stay literal ~ rather than
  # being read as a tilde expansion of this script's own home directory.
  case "$value" in
    "$tilde") value="$HOME" ;;
    "$tilde"/*) value="$HOME/${value:2}" ;;
  esac
  printf '%s' "$value"
}

# Write DATOMIC_HOME into .env, the single readable record of this setup.
record_home() {
  local tmp="$ENV_FILE.tmp"
  if [[ ! -f "$ENV_FILE" ]]; then
    if [[ -f "$ROOT_DIR/.env.example" ]]; then cp "$ROOT_DIR/.env.example" "$ENV_FILE"
    else printf '# Datomic lab configuration, read by build.sh and start.sh.\n' > "$ENV_FILE"
    fi
    info "Created $ENV_FILE"
  fi
  # Replacing the assignment in place keeps the surrounding comments intact.
  grep -v '^[[:space:]]*DATOMIC_HOME=' "$ENV_FILE" > "$tmp" || true
  printf "DATOMIC_HOME='%s'\n" "${DATOMIC_HOME//\'/\'\\\'\'}" >> "$tmp"
  mv "$tmp" "$ENV_FILE"
}

# ./datomic-pro already exists. Reuse it, or delete it and download again.
# Nothing is deleted without an explicit answer: the default is always to reuse.
keep_existing() {
  local answer
  if [[ "${DATOMIC_CLEAN:-}" == 1 ]]; then return 1; fi
  if [[ ! -t 0 ]]; then
    info "Using the existing $INSTALL_DIR (set DATOMIC_CLEAN=1 to download it again)"
    return 0
  fi
  printf '%s already exists.\n  use   - keep this installation and its databases\n  clean - delete the folder and download Datomic Pro %s again\nChoose [use/clean]: ' \
    "$INSTALL_DIR" "$DATOMIC_VERSION" >&2
  IFS= read -r answer || answer=use
  case "$(normalize "$answer")" in
    ''|[uU]|[uU][sS][eE]) return 0 ;;
    [cC]|[cC][lL][eE][aA][nN]) return 1 ;;
    *) fail 'Answer "use" or "clean".' ;;
  esac
}

# Install Datomic Pro into ./datomic-pro, caching the ZIP in DATOMIC_DOWNLOAD_DIR.
# Every failure path removes its partial work so a retry starts clean.
download_datomic() {
  local archive staging extracted
  [[ "$DATOMIC_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Invalid DATOMIC_VERSION."
  [[ "$DATOMIC_DOWNLOAD_DIR" == /* ]] || fail "DATOMIC_DOWNLOAD_DIR must be absolute."
  DATOMIC_HOME="$INSTALL_DIR"
  if [[ -d "$INSTALL_DIR" ]]; then
    if keep_existing; then return 0; fi
    info "Removing $INSTALL_DIR"
    rm -rf "$INSTALL_DIR"
  fi
  has unzip || fail "unzip is required for the download. Configure it on PATH and retry."
  mkdir -p "$DATOMIC_DOWNLOAD_DIR"
  archive="$DATOMIC_DOWNLOAD_DIR/datomic-pro-$DATOMIC_VERSION.zip"
  if [[ ! -f "$archive" ]]; then
    info "Downloading Datomic Pro $DATOMIC_VERSION"
    if ! curl --fail --location --proto '=https' --retry 2 --connect-timeout 15 --max-time 600 --progress-bar \
      "https://datomic-pro-downloads.s3.amazonaws.com/$DATOMIC_VERSION/datomic-pro-$DATOMIC_VERSION.zip" -o "$archive.part"; then
      rm -f "$archive.part"
      fail "Download failed. Check your connection and retry ./build.sh."
    fi
    mv "$archive.part" "$archive"
  fi
  unzip -tq "$archive" >/dev/null || fail "Invalid ZIP: $archive. Move it aside and retry."
  staging="$(mktemp -d "$DATOMIC_DOWNLOAD_DIR/extract.XXXXXX")"
  extracted="$staging/datomic-pro-$DATOMIC_VERSION"
  if ! unzip -q "$archive" -d "$staging"; then
    rm -rf "$staging"
    fail "Could not extract $archive. Move it aside and retry."
  fi
  if [[ ! -d "$extracted" ]]; then
    rm -rf "$staging"
    fail "$archive does not contain datomic-pro-$DATOMIC_VERSION/. Move it aside and retry to fetch the official archive."
  fi
  if ! mv "$extracted" "$INSTALL_DIR"; then
    rm -rf "$staging"
    fail "Could not install into $INSTALL_DIR. Check permissions and free space."
  fi
  rm -rf "$staging"
}

# Datomic's bin/ scripts start with #!/bin/bash, which does not exist on NixOS
# and similar systems, and they call each other directly (bin/transactor runs
# bin/classpath), so invoking them through bash is not enough. Rewrite the
# shebangs of the installation this repo manages; cat keeps the file modes.
# Systems that have /bin/bash are left untouched.
portable_shebangs() {
  local script tmp
  [[ -x /bin/bash ]] && return 0
  for script in "$INSTALL_DIR"/bin/*; do
    [[ -f "$script" && "$(head -1 "$script")" == '#!/bin/bash' ]] || continue
    tmp="$(mktemp)"
    { printf '#!/usr/bin/env bash\n'; tail -n +2 "$script"; } > "$tmp"
    cat "$tmp" > "$script"
    rm -f "$tmp"
  done
}

selection=""
case "${1-}" in
  -h|--help) usage; exit 0 ;;
  '') ;;
  -*) usage >&2; fail "Unknown option: $1" ;;
  *) selection="$(normalize "$1")" ;;
esac
(( $# <= 1 )) || fail "Too many arguments. Run ./build.sh --help."

requirements build

# DATOMIC_HOME comes from the environment or .env; otherwise ask once and record it.
if [[ -n "$selection" ]]; then choice="$selection"
elif [[ -n "$DATOMIC_HOME" ]]; then choice=""
elif [[ "${DATOMIC_DOWNLOAD:-}" == 1 ]]; then choice=download
elif [[ -t 0 ]]; then
  # The prompt goes to stderr so it stays visible when stdout is redirected.
  # Enter accepts the proposed folder; anything else is an existing installation.
  printf 'Install Datomic Pro %s in %s?\nPress Enter to accept, or type the absolute path of an existing installation: ' \
    "$DATOMIC_VERSION" "$INSTALL_DIR" >&2
  IFS= read -r choice || fail "No selection. Set DATOMIC_HOME in .env or DATOMIC_DOWNLOAD=1."
  choice="$(normalize "$choice")"
  [[ -n "$choice" ]] || choice=download
else fail "Set DATOMIC_HOME=/absolute/path in .env, or DATOMIC_DOWNLOAD=1 to install Pro $DATOMIC_VERSION in $INSTALL_DIR."
fi
if [[ "$choice" == download ]]; then download_datomic
elif [[ -n "$choice" ]]; then DATOMIC_HOME="$choice"
fi
# Before installation(), which rejects #!/bin/bash scripts on such systems.
if [[ "$DATOMIC_HOME" == "$INSTALL_DIR" ]]; then portable_shebangs; fi

# The transactor properties file must already exist: by default that's this
# repo's own config/transactor.properties, used in place; a custom
# DATOMIC_TRANSACTOR_CONFIG must be the participant's own existing file.
installation
[[ -f "$DATOMIC_TRANSACTOR_CONFIG" ]] || fail "Properties file does not exist: $DATOMIC_TRANSACTOR_CONFIG"
# Checked before the slow uberjar build: a root-owned installation cannot receive the exporter.
[[ -w "$DATOMIC_HOME/lib" ]] || fail "Cannot write to $DATOMIC_HOME/lib. Use an installation you own, or fix its ownership, then retry."
# Recorded once the installation is known good, so a later failure does not
# make the participant answer the prompt again.
record_home
info "Building the metrics exporter"
# The build task uses an alias-free basis: Datomic supplies Clojure at runtime.
(cd "$ROOT_DIR/metrics-exporter" && clojure -T:build uberjar)
cp "$ROOT_DIR/metrics-exporter/target/datomic-metrics-standalone.jar" "$DATOMIC_HOME/lib/datomic-metrics-standalone.jar"
mkdir -p "$DATOMIC_LOG_PATH" "$RUN_DIR"
compose config >/dev/null
if "${COMPOSE[0]}" info >/dev/null 2>&1; then info "Build complete. Run ./start.sh."
else info "Build complete. Docker is not running: start Docker Desktop, or run colima start, then run ./start.sh."
fi
printf 'Datomic:     %s\nRecorded in: %s\nProperties:  %s (edit directly; ./transactor-restart.sh applies changes without a rebuild)\n' \
  "$DATOMIC_HOME" "$ENV_FILE" "$DATOMIC_TRANSACTOR_CONFIG"
