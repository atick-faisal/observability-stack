# The agent

One Alloy container per app host. It discovers what to collect from Docker labels, receives OTLP
traces from the local app, and pushes metrics, logs, and traces to the observability VPS. The app
exposes nothing publicly and needs no address but `alloy:4317`.

Copy this directory into your app repo as `observability/`. Nothing in it is app-specific, and
`config.alloy` is not meant to be edited — if you find yourself editing it, that is a bug in the
label convention, not in your app.

## Install

```bash
cp -r observability-stack/agent your-app/observability
cp observability/.env.agent.example observability/.env.agent   # fill it in

docker compose -f compose.yml -f observability/compose.agent.yml up -d
```

Add `--profile postgres` for `postgres_exporter`, `--profile containers` for cAdvisor, or both.

## Label your containers

```yaml
services:
  api:
    labels:
      obs.service: api
      obs.metrics.port: "8000"    # presence = scrape me
      obs.metrics.path: /metrics  # optional, defaults to /metrics
    expose:
      - "8000"                    # required — see below
  db:
    labels:
      obs.service: db             # logs only
  migrations:
    labels:
      obs.logs: "false"           # collect nothing
```

Everything is collected by default: a container with no labels still has its logs shipped, with
`service` falling back to its container name. Only `obs.metrics.port` is opt-in, because scraping
something that does not serve Prometheus text is a waste rather than a mistake.

**`obs.metrics.port` must be exposed.** The agent matches the label against Docker's port
metadata, which means `EXPOSE` in the image or `expose:` in Compose. *Publishing* the port is not
required and not wanted. A container that genuinely cannot expose its port is what
`OBS_EXTRA_TARGET` is for.

## Configure

Everything lives in `.env.agent`, read inside the container — see `.env.agent.example`. Nothing
is interpolated by Compose, so a `$` in a password needs no escaping.

`OBS_APP`, `OBS_ENV`, and `OBS_HOST` are the identity stamped onto every metric and every log
stream. They must match what the app's own `OBS_*` variables say, which is easiest to guarantee
by keeping them in one file that both halves read.

`OBS_HOST` is worth stating twice: on the **trace** path the app sets it, not the agent. An app
that leaves it unset reports `socket.gethostname()`, which inside a container is the container id
— so its traces will disagree with its own metrics, which carry the agent's value.

`OBS_INGEST_USER` / `OBS_INGEST_PASSWORD` are one credential per app+env, minted on the server
with `scripts/add-ingest-user.sh <app>-<env>`. All three writers send it. The username is what
identifies this app in the server's access log, so push volume can be attributed and one app can
be rotated without touching any other.

`OBS_INGEST_TLS_INSECURE` disables certificate verification on all three writers. It exists for
one purpose — letting the stack's own end-to-end test push through Traefik on a laptop, where
Let's Encrypt cannot have issued a certificate for a domain whose DNS points at the VPS. Setting
it against a real endpoint makes basic auth worthless, since the credentials become readable by
whoever terminates the connection.

## What it collects

| Source | Signal | Discovered by |
|---|---|---|
| Any container with `obs.metrics.port` | metrics | Docker labels |
| `prometheus.exporter.unix` (built in) | host metrics | always on |
| cAdvisor, profile `containers` | per-container metrics | its own `obs.*` labels |
| postgres_exporter, profile `postgres` | database metrics | its own `obs.*` labels |
| Every container without `obs.logs="false"` | logs | Docker labels |
| The app's OTLP on `:4317` / `:4318` | traces | the app points at it |

Alloy's own UI is on `127.0.0.1:12345` — `/graph` shows every component and what it discovered.

## postgres_exporter

The exporter connects as its own least-privilege role, not as the application user. Create it once:

```bash
POSTGRES_EXPORTER_PASSWORD=... docker compose exec -T db \
  psql -U postgres -d appdb -f - < observability/postgres-exporter-init.sql
```

On a database that does not exist yet, mount the same file into
`/docker-entrypoint-initdb.d/` instead and set `POSTGRES_EXPORTER_PASSWORD` on the Postgres
container — it reads the variable itself. Re-running rotates the password rather than failing.

`--collector.stat_checkpointer` is not optional on PostgreSQL 17 and later: the checkpoint
counters moved out of `pg_stat_bgwriter` into `pg_stat_checkpointer`, and that collector is off by
default.

## Things that will bite you

**A container on two networks is scraped twice.** Docker discovery emits one target per
(network × exposed port), so the same series arrives twice with the same timestamp and Prometheus
rejects the write. Set `OBS_DOCKER_NETWORK` to the network the agent shares with the app. Logs are
unaffected — the Docker log source keys its tailers by container id, and a container with three
exposed ports is still tailed exactly once.

**Recreating a container can cost one batch of cAdvisor samples.** `id` is dropped from cAdvisor's
series because a container id is unbounded over time; the consequence is that while a recreated
container briefly coexists with its predecessor, the two collapse onto one series and Prometheus
rejects the whole remote-write request with `duplicate sample for timestamp`. It resolves itself
within a scrape or two. Remove the `labeldrop` rule in `config.alloy` if you would rather have the
cardinality than the gap.

**`alloy validate` does not build components.** It checks syntax and the component graph, so a
malformed `stage.match` selector or an unresolvable endpoint passes validation and fails at
startup. Watch `docker compose logs alloy` after the first `up`.

**cAdvisor needs `compose.agent.macos.yml` on a Mac**, and `prometheus.exporter.unix` reports the
Docker Desktop VM rather than macOS. Both are local-development artifacts; a Linux VPS needs
neither.

## What it does not do

The agent does not collect its own logs (`obs.logs: "false"` on the alloy service) — a failing
push logs a line, and tailing your own log makes that line another thing to push. Read them with
`docker compose logs alloy`. Monitoring the observability stack itself is out of scope for v1.
