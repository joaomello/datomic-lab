# Setup and troubleshooting

The build and startup scripts report missing prerequisites before running the
system. Configure tools yourself; neither script installs tools, switches
Docker contexts, or starts a VM. Build can run while the container VM is stopped.

## Docker Compose with Colima

You need the Docker CLI, the Compose plugin (`docker compose`), and a running
Colima Docker runtime. Installing Colima alone does not provide Compose.
Configure tools using your usual package manager and shell environment.
See the [Colima installation guide](https://colima.run/docs/installation/).

```bash
colima start
colima status
docker context ls
docker context show
docker compose version
docker info
```

For the default Colima profile, use `docker context use colima` if needed.
Custom profiles have their own contexts. Exported `DOCKER_HOST` or
`DOCKER_CONTEXT` can override the selected context. Docker Desktop also works
when its engine is running.

On Apple Silicon, native ARM, Apple's virtualization framework, and VirtioFS
are suitable settings. Measure with `docker stats` before increasing VM
resources. Transactor and Console run on macOS and use memory independently
of the Colima VM.

## Podman alternative

If you don't use Docker, configure Podman and a Compose provider, then select
it in `.env`:

```bash
DATOMIC_COMPOSE='podman compose'
```

On macOS, initialize and start your Podman machine as needed, then check
`podman info` and `podman compose version`. Automatic provider selection
prefers Docker Compose if both are available. Networking and bind mounts work
the same way conceptually as Colima; see the sections above if containers
can't reach the host or read the log directory.

## Compose requirements and ports

The stack uses the Compose Specification: named volumes, read-only bind mounts,
environment interpolation, published ports, `depends_on`, and `host-gateway`
host mapping. Build and startup validate Compose configuration.

| Ports | Purpose |
|-------|---------|
| 4334, 4335 | Datomic dev storage |
| 9100 | Transactor metrics |
| 8080 | Console (configurable) |
| 3000, 9090, 3100 | Grafana, Prometheus, Loki |

Startup checks local transactor and Console ports; Compose reports container
port conflicts. A running manual transactor is not adopted or stopped.

```bash
lsof -nP -iTCP:4334 -sTCP:LISTEN
lsof -nP -iTCP:8080 -sTCP:LISTEN
```

Stop the conflicting service yourself, or change the relevant configuration.
For Console use `DATOMIC_CONSOLE_PORT=8081`. Changes to Datomic storage ports
also require updating the transactor properties and `DATOMIC_URI`.

Use one session at a time. Start/stop manages this project's Compose
stack, so stop any manually managed observability session before using it.

## Datomic selection and downloads

`DATOMIC_HOME` must be an absolute path to an extracted Pro distribution with
`bin/transactor`, `bin/console`, `lib/console`, and `VERSION`. An invalid configured
path fails; it is not silently replaced by a download.

When `DATOMIC_HOME` is set in neither the environment nor `.env`, build asks for
a path or `download`, then writes the answer to `.env`. Use `DATOMIC_DOWNLOAD=1`
for unattended download selection, or pass the path as `./build.sh /path`.
Explicit environment values override `.env`, and build records the value it used
so `.env` always describes the current setup.

Downloads use the [official public ZIP](https://docs.datomic.com/setup/pro-setup.html).
A failed transfer removes its partial file and retries from the beginning. An
invalid cached ZIP produces an error; move that specific ZIP aside and retry.
An archive that does not contain `datomic-pro-<version>/` is reported by name.
Extraction does not overwrite an existing installation directory and leaves no
staging directory behind if it fails.

Build adds `lib/datomic-metrics-standalone.jar` to the selected installation.
It preserves other configurations and databases. The transactor properties file
(`config/transactor.properties` by default, or `DATOMIC_TRANSACTOR_CONFIG`) is
read from where it already lives, not copied in — build only checks it exists.
Stop users of that installation before rebuilding the exporter; use a separate
installation for an independent lab.

## Java, heap, and GC

Check `java -version` and `clojure -Sdescribe`. A `java` command on PATH may
only be an OS stub; the checks verify Java actually runs. Configure `JAVA_HOME`
to select Java 17, 21, or 25.

Use `DATOMIC_JAVA_OPTS` for the full transactor option list and
`DATOMIC_CONSOLE_JAVA_OPTS` for Console. Keep each on one line without embedded
quoting or shell expressions. Datomic replaces its default GC options when
non-heap JVM arguments are supplied, so the lab defaults explicitly include G1.

Global `JAVA_TOOL_OPTIONS` affects all JVMs and can conflict with GC choices.
Inspect the startup log if Java rejects an option. Stop with Ctrl+C and restart
to apply changes.

## Missing metrics or logs

During the session, inspect these from another terminal:

```bash
tail -f .run/transactor.log
tail -f .run/console.log
docker logs -f datomic-prometheus
docker logs -f datomic-promtail
```

Use `podman logs` when running Podman. After a failed startup the containers
are removed; the JVM logs remain in `.run/`. Startup prints recent container
logs before cleanup on failure.

The exporter starts on Datomic's first metrics callback, which can take about
a minute. `DATOMIC_START_TIMEOUT` defaults to 180 seconds for readiness.
Startup checks service endpoints, the transactor scrape, and recent logs in
Loki. An absent optional peer is expected.

If local metrics work but Prometheus shows the transactor down at
http://localhost:9090/targets, inspect container-to-host networking.
Compose maps `host.containers.internal` to `host-gateway`; the destination
depends on the runtime. Verify it reaches the macOS JVM, not just the container
VM. This mapping works on the tested Colima setup. For another runtime, adjust
the mapping and Prometheus targets together as needed.

The project and `DATOMIC_LOG_PATH` must be shared with the container VM.
Colima may need explicit mounts for directories outside your home directory:
see the [Colima FAQ](https://colima.run/docs/faq/).
`DATOMIC_LOG_PATH` selects the collected directory; it does not change where
Datomic writes logs. Configure Datomic logging separately when moving its files.

Keep `-Duser.timezone=UTC` to match Promtail. If logs do not appear, verify
current `.log` files in the mounted directory and inspect Promtail errors.
Promtail is end of life; [migration to Alloy](https://grafana.com/docs/grafana-cloud/observe-and-act/send-data/alloy/set-up/migrate/from-promtail/)
is a separate maintenance task.

## Shutdown or an interrupted terminal

Ctrl+C stops the owned JVM children and runs Compose down, preserving databases
and volumes. No stored PIDs are used to control later sessions.

A small `.run/active` directory prevents simultaneous sessions. The build script
does not check this marker. If the terminal is forcibly killed, inspect remaining
Java processes and containers and stop them yourself. Once no session is running,
`./stop.sh` clears the stale marker, including its PID file, after successful
shutdown and when the recorded session PID is no longer running. A normal exit
clears it automatically.

For containers only, `./observability/start.sh` remains available with an explicit
`DATOMIC_HOME` in `.env`. Its `down-v` command discards observability volumes;
normal shutdown does not.
