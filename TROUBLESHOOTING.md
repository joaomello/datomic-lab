# Troubleshooting

Start with the [README](README.md). Come here when a step fails. The scripts
report missing tools before running, but they never install anything, start a
VM, or switch Docker contexts for you.

- [Install the prerequisites](#install-the-prerequisites): Java, Clojure, Docker Desktop or Colima
- [A port is already in use](#a-port-is-already-in-use)
- [Java or Clojure problems](#java-or-clojure-problems)
- [Datomic download or installation](#datomic-download-or-installation)
- [No metrics or logs in Grafana](#no-metrics-or-logs-in-grafana)
- [The terminal was closed or killed](#the-terminal-was-closed-or-killed)
- [Configuration reference](#configuration-reference)

## Install the prerequisites

You need Java, the Clojure CLI, and Docker with Compose v2. Follow the steps
for your system, then run the checks at the end.

### macOS

Install [Homebrew](https://brew.sh) if you don't have it, then install Java and
Clojure:

```bash
brew install --cask temurin@21
brew install clojure/tools/clojure
```

Then install **one** of these Docker options.

#### Option A: Docker Desktop

1. Download and install
   [Docker Desktop for Mac](https://docs.docker.com/desktop/setup/install/mac-install/).
   It includes Docker Compose.
2. Open Docker Desktop and wait until it says the engine is running.

#### Option B: Colima (free, no Docker Desktop)

Colima runs Docker in a small VM. You need Colima, the Docker CLI, and the
Compose plugin. Installing Colima alone isn't enough.

```bash
brew install colima docker docker-compose
```

Register Compose as a Docker plugin so that `docker compose` works:

```bash
mkdir -p ~/.docker/cli-plugins
ln -sfn "$(brew --prefix)/opt/docker-compose/bin/docker-compose" ~/.docker/cli-plugins/docker-compose
```

Start Colima with enough resources for the lab:

```bash
colima start --cpu 4 --memory 4
docker context use colima
```

Colima doesn't start automatically after a reboot. Run `colima start` before
each session, or `brew services start colima` to start it at login.

If Docker Desktop is also installed, check that `docker context show` prints
`colima`. An exported `DOCKER_HOST` or `DOCKER_CONTEXT` overrides the context.

### Linux

Install Java, `curl`, `unzip`, and `lsof` (Debian/Ubuntu shown):

```bash
sudo apt update
sudo apt install -y openjdk-21-jdk curl unzip lsof
```

Install the Clojure CLI with the
[official Linux instructions](https://clojure.org/guides/install_clojure#_linux_instructions).

Install Docker Engine and the Compose plugin with
[Docker's guide for your distribution](https://docs.docker.com/engine/install/).
Make sure the `docker-compose-plugin` package is installed, then let your user
run Docker without `sudo`:

```bash
sudo usermod -aG docker "$USER"
```

Log out and back in for the group change to apply.

### Check everything

```bash
java -version            # 17, 21, or 25
clojure -Sdescribe
docker compose version   # v2.x
docker info              # must show a running server
docker run --rm hello-world
```

The old standalone `docker-compose` command isn't used; `docker compose` must
work.

## A port is already in use

| Port | Used by |
| --- | --- |
| 4334, 4335 | Datomic transactor |
| 9100 | Transactor metrics |
| 9101 | Peer metrics (peer lab) |
| 8080 | Datomic Console |
| 3000, 9090, 3100 | Grafana, Prometheus, Loki |

Find what's using a port:

```bash
lsof -nP -iTCP:8080 -sTCP:LISTEN
```

Stop that process, or move Console to another port with
`DATOMIC_CONSOLE_PORT=8081` in `.env`. The scripts don't stop or take over a
transactor that you started by hand. If you change the transactor ports, you
also have to update `config/transactor.properties` and `DATOMIC_URI`.

Run one lab session at a time.

## Java or Clojure problems

Check `java -version` and `clojure -Sdescribe`. On macOS, `java` on your PATH
can be a system stub that doesn't run Java. Set `JAVA_HOME` to a Java 17, 21,
or 25 installation.

A global `JAVA_TOOL_OPTIONS` applies to every JVM and can conflict with the
lab's GC settings. If Java rejects an option, check `.run/transactor.log`.

## Datomic download or installation

- `./build.sh` downloads the
  [official Datomic Pro ZIP](https://docs.datomic.com/setup/pro-setup.html)
  into `./datomic-pro` and caches it in `.datomic/`.
- To reuse an installation you already have:
  `./build.sh /absolute/path/to/datomic-pro`.
- To download without being asked: `DATOMIC_DOWNLOAD=1 ./build.sh`.
- To download again from scratch: `DATOMIC_CLEAN=1 ./build.sh`.

`DATOMIC_HOME` must be an absolute path to an extracted Pro distribution
(`bin/transactor`, `bin/console`, `lib/console`, `VERSION`). If the path is
invalid, the build fails; it doesn't fall back to downloading.

If a cached ZIP is corrupt, move it out of `.datomic/` and run the build again.
Failed downloads clean up after themselves.

The build adds `lib/datomic-metrics-standalone.jar` to the installation. Your
databases and other configuration stay untouched. Stop anything that is using
that installation before you rebuild.

## No metrics or logs in Grafana

First, wait about a minute. The exporter starts on Datomic's first metrics
callback. An empty **peer** dashboard is expected until you start the peer lab.

Check from another terminal:

```bash
curl -s http://localhost:9100/metrics | head    # transactor metrics
tail -f .run/transactor.log
tail -f .run/console.log
docker logs -f datomic-prometheus
docker logs -f datomic-promtail
```

If startup fails, the containers are removed,
but the JVM logs stay in `.run/` and startup prints the recent container logs.

**Metrics work locally but Prometheus shows the target down**
(<http://localhost:9090/targets>): the containers can't reach your host.
Compose maps `host.containers.internal` to `host-gateway`, and the transactor
is scraped through that name. This works on Docker Desktop and Colima. With
another runtime, adjust the mapping and the Prometheus targets together.

**No logs in Loki:** the repository and the Datomic log directory
(`DATOMIC_LOG_PATH`, default `$DATOMIC_HOME/log`) must be visible to the
container VM. Keeping the repository under your home directory usually handles
that. Colima may need explicit mounts for other locations; see the
[Colima FAQ](https://colima.run/docs/faq/). Also keep `-Duser.timezone=UTC` in
the JVM options, because Promtail reads Datomic's timestamps as UTC.

## The terminal was closed or killed

`Ctrl+C` stops everything cleanly and keeps your data. If the terminal was
killed instead, run:

```bash
./stop.sh
```

It stops the leftover processes and containers and clears the `.run/active`
session marker. It never deletes data. If it can't clean up, look for leftover
`java` processes and `datomic-*` containers and stop them yourself.

To run only the containers, use `./observability/start.sh` (this requires
`DATOMIC_HOME` in `.env`). Its `down-v` command **deletes** the observability
volumes.

## Configuration reference

`./build.sh` creates `.env` from [`.env.example`](.env.example) and records
`DATOMIC_HOME` in it. Environment variables override `.env`.

| Setting | Purpose |
| --- | --- |
| `DATOMIC_HOME` | Absolute path to a Datomic Pro installation |
| `DATOMIC_VERSION` | Download version; default `1.0.7705` |
| `DATOMIC_DOWNLOAD=1` | Download without being asked |
| `DATOMIC_CLEAN=1` | Delete `./datomic-pro` and download again |
| `DATOMIC_DOWNLOAD_DIR` | Where the ZIP is cached; default `.datomic/` |
| `DATOMIC_TRANSACTOR_CONFIG` | Transactor properties file; default `config/transactor.properties` |
| `DATOMIC_LOG_PATH` | Log directory that Promtail reads; default `$DATOMIC_HOME/log` |
| `DATOMIC_CONSOLE_PORT` | Console port; default `8080` |
| `DATOMIC_URI` | Console's transactor URI; default `datomic:dev://localhost:4334/` |
| `DATOMIC_JAVA_OPTS` | Full transactor JVM options (replaces the defaults) |
| `DATOMIC_CONSOLE_JAVA_OPTS` | Console JVM options |
| `DATOMIC_START_TIMEOUT` | Readiness timeout in seconds; default `180` |

Example:

```bash
DATOMIC_JAVA_OPTS='-Xms1g -Xmx2g -XX:+UseG1GC -XX:MaxGCPauseMillis=100 -Duser.timezone=UTC'
```

Keep each option list on one line, and always include `-Duser.timezone=UTC`.
The scripts read `.env` as shell configuration, so don't put secrets in it.

**Transactor settings:** edit
[`config/transactor.properties`](config/transactor.properties), then run
`./transactor-restart.sh`. This restarts only the transactor; you don't need to
rebuild, and Console may need to reconnect.
