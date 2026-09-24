# Datomic Lab

A local Datomic Pro playground for learning: a transactor, the Datomic
Console, an optional peer REPL, and dashboards (Grafana, Prometheus, Loki) to
watch it all work.

<img src="docs/images/architecture.png" alt="Datomic Lab architecture" width="850">

Datomic (transactor and Console) runs as Java processes on your machine. Only
the observability stack runs in Docker.

> This is a learning lab, not a production setup: local `dev` storage, no
> authentication, one transactor.

## Before you start

You need macOS or Linux with:

- **Java 17, 21, or 25**
- **[Clojure CLI](https://clojure.org/guides/install_clojure)**
- **Docker with Compose v2** (Docker Desktop, Docker Engine, or Colima)
- `curl`, `unzip`, `lsof` (usually already installed)

Check that everything answers:

```bash
java -version
clojure -Sdescribe
docker compose version
docker info
```

Missing something? Follow the
[install steps for macOS (Docker Desktop or Colima) and Linux](TROUBLESHOOTING.md#install-the-prerequisites).
Using Colima? Run `colima start` before each session.

## Quick start

Clone the repository somewhere under your home directory (Colima only shares
your home folder with its VM), then from the repository root:

```bash
./build.sh    # first time only: downloads Datomic Pro and builds the lab
./start.sh    # starts everything; keep this terminal open
```

When `./build.sh` asks `Install Datomic Pro … in …/datomic-pro?`, **press
Enter**. The first build downloads about 300 MB; the first start downloads the
Docker images.

`./start.sh` is ready when it prints `Keep this terminal open`. The first
metrics can take about a minute to appear.

## Open the lab

| What | URL |
| --- | --- |
| Datomic Console | <http://localhost:8080/browse> |
| Grafana dashboard | <http://localhost:3000/d/datomic-overview> |
| Prometheus | <http://localhost:9090> |

## Try it

1. In Console, create a database, for example `lab`.
2. Define a small schema, transact a few entities, and query them.
3. Watch the transactor in Grafana under **Datomic → Transactor Metrics**.
4. Want to write Clojure against it? Follow the
   [peer lab](peer-lab/README.md).

## Stop

Press `Ctrl+C` in the `./start.sh` terminal. Your databases and dashboards are
kept; run `./start.sh` again next time.

If the terminal was closed and something is still running:

```bash
./stop.sh
```

## Something went wrong?

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for installation steps, port
conflicts, missing metrics or logs, and all configuration options.

## Learn more

- [Observability details](OBSERVABILITY.md)
- [Peer lab](peer-lab/README.md)
- [Metrics exporter](metrics-exporter/README.md)
- [Datomic Pro setup](https://docs.datomic.com/setup/pro-setup.html)
- [Datomic transactor](https://docs.datomic.com/operation/transactor.html)
- [Datomic Console](https://docs.datomic.com/resources/console.html)
