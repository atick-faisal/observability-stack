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

docker compose -f compose.lgtm.yml -f observability/compose.agent.yml up -d
```

Add `--profile postgres` for `postgres-exporter`, `--profile containers` for cAdvisor, or both.

## Install on a platform that deploys from git

Dokploy, Coolify and anything else that re-clones the repo on every deploy needs a different
shape, for two reasons that both fail *quietly*:

* **A bind-mounted repo file does not survive the next deploy** — it comes back empty or missing.
  So `config.alloy` is built into an image (`Dockerfile`) instead of mounted.
* **Variables from the platform's UI are written to a `.env` for interpolation, not injected into
  containers.** So the settings come from `environment:` rather than `.env.agent`.

`compose.agent.deploy.yml` is that shape. `include:` it from the app's own compose file, which
then declares only the app's services:

```yaml
# compose.deploy.yml, at the app repo root — the one file the platform points at
include:
  - observability/compose.agent.deploy.yml

services:
  api:
    networks: [obs]
    expose: ["8000"]
    labels:
      obs.service: api
      obs.metrics.port: "8000"
    environment:
      OBS_OTLP_ENDPOINT: http://alloy:4317
```

The variable names are the same ones `.env.agent.example` documents, plus two:

| | |
|---|---|
| `OBS_NETWORK` | The Docker network name for this app, e.g. `myapp-obs`. Required — Docker network names are global to the host, so a shared default would silently join two apps together. The agent's `OBS_DOCKER_NETWORK` tracks it, which scopes both metrics discovery and log collection to your own containers. |
| `COMPOSE_PROFILES` | `postgres,containers` — there is no `--profile` to pass. Compose reads it from the same `.env`. |

Two differences from `.env.agent` follow from Compose reading these rather than the container:
a `$` in a value **is** eaten, so keep generated secrets alphanumeric; and the seven variables with
no sane default fail the render when unset instead of producing an agent that pushes nowhere or
labels every series `app=""`.

The observability-stack repo's own `compose.demo.deploy.yml` is a worked example: it includes this
file unmodified and adds three services.

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

> [!IMPORTANT]
> **`obs.metrics.port` must be exposed.** The agent matches the label against Docker's port
> metadata, which means `EXPOSE` in the image or `expose:` in Compose. *Publishing* the port is
> not required and not wanted. A container that genuinely cannot expose its port is what
> `OBS_EXTRA_TARGET` is for.

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

> [!CAUTION]
> `OBS_INGEST_TLS_INSECURE` disables certificate verification on all three writers. It exists for
> one purpose — letting the stack's own end-to-end test push through Traefik on a laptop, where
> Let's Encrypt cannot have issued a certificate for a domain whose DNS points at the VPS.
> Setting it against a real endpoint makes basic auth worthless, since the credentials become
> readable by whoever terminates the connection.

## What it collects

| Source | Signal | Discovered by |
|---|---|---|
| Any container with `obs.metrics.port` | metrics | Docker labels |
| `prometheus.exporter.unix` (built in) | host metrics | always on |
| cAdvisor, profile `containers` | per-container metrics | its own `obs.*` labels |
| postgres-exporter, profile `postgres` | database metrics | its own `obs.*` labels |
| Every container without `obs.logs="false"` | logs | Docker labels, narrowed by `OBS_DOCKER_NETWORK` where set |
| The app's OTLP on `:4317` / `:4318` | traces | the app points at it |

Alloy's own UI is on `127.0.0.1:12345` — `/graph` shows every component and what it discovered.

## What it holds on to when the VPS is unreachable

All three writers buffer to disk, under `--storage.path` in the `alloy_data` volume, and replay
with the **original timestamps** — so an outage leaves a continuous line rather than a gap, and
`docker volume rm` on that volume is the one action that throws the buffer away.

| Signal | Mechanism | Roughly how long | The server-side window, which must be at least as wide |
|---|---|---|---|
| metrics | `prometheus.remote_write` WAL | 8h (`max_keepalive_time`) | `out_of_order_time_window: 8h` |
| logs | `loki.write` WAL | 8h (`max_segment_age`), 20 retries ≈ 1h per batch | `reject_old_samples_max_age: 168h` |
| traces | `otelcol` sending queue on `otelcol.storage.file` | 10 000 batches | none — Tempo accepts any timestamp |

> [!WARNING]
> The server-side column is the half people forget. A buffer whose replay the server rejects as
> too old is worse than no buffer, because it looks like it worked.
>
> **These numbers travel together.** Raising a buffer here without raising the matching window on
> the server buys nothing past the old window, silently. The metrics pair is the one that hides:
> a single agent replays *in order*, so it barely touches the out-of-order path, and a window
> narrower than this WAL only bites once a **second** agent is replaying against the first one's
> live writes. `docs/operations.md` §1 has the full reasoning. `make demo-up SECOND_AGENT=1`
> followed by `make verify-resilience` exercises that second agent, as checks 8/9.

`--stability.level=public-preview` in `compose.agent.yml` is required by exactly one component,
`otelcol.storage.file`, which is what puts the trace queue on disk instead of in memory. The flag
is a floor rather than a switch: it permits public-preview components to be referenced, and every
other component in `config.alloy` is generally-available. Drop the flag and Alloy refuses to start
with a message naming the component, which is the right failure.

> [!NOTE]
> One thing to know before you go looking: **Tempo's time-bounded search does not surface
> backfilled traces.** After a fifteen-minute outage, a search over the first ten minutes of that
> window comes back empty while `GET /api/traces/<id>` on a trace from the same minute returns it
> in full. The spans are stored — the search path is what does not find them. Check the trace
> side by taking a `trace_id` off a log line from the outage and looking that up, which is what
> `scripts/verify-resilience.sh` does.

That script asserts all of this in the server repo by stopping the server for fifteen minutes
and checking for a hole afterwards.

## postgres-exporter

The exporter connects as its own least-privilege role, not as the application user. Create it once:

```bash
POSTGRES_EXPORTER_PASSWORD=... docker compose exec -T db \
  psql -U postgres -d appdb -f - < observability/postgres-exporter-init.sql
```

On a database that does not exist yet, mount the same file into
`/docker-entrypoint-initdb.d/` instead and set `POSTGRES_EXPORTER_PASSWORD` on the Postgres
container — it reads the variable itself. Re-running rotates the password rather than failing.

On a platform that deploys from git, that mount is the same trap as `config.alloy`: build the file
into a small Postgres image instead. `demo/db/Dockerfile` in the observability-stack repo is three
lines and does exactly that.

`--collector.stat_checkpointer` is not optional on PostgreSQL 17 and later: the checkpoint
counters moved out of `pg_stat_bgwriter` into `pg_stat_checkpointer`, and that collector is off by
default.

## Things that will bite you

**A container on two networks is scraped twice.** Docker discovery emits one target per
(network × exposed port), so the same series arrives twice with the same timestamp and Prometheus
rejects the write. Set `OBS_DOCKER_NETWORK` to the network the agent shares with the app. Duplicate
ports are not the same problem — the Docker log source keys its tailers by container id, so a
container with three exposed ports is still tailed exactly once.

**`OBS_DOCKER_NETWORK` scopes logs as well as metrics.** Unset, this agent tails *every* container
on the host and stamps its own `app` label on all of them — right on a dedicated app host, wrong
the moment the box runs anything else, and on a box running two apps with two agents each one
ships the other's logs under its own name. Set it and a container with no interface on that
network stops being collected at all, which is the intent but is a real change if you had set the
variable for the duplicate-samples reason alone. `compose.agent.deploy.yml` always sets it.

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
`docker compose logs alloy`. Monitoring the observability stack itself is deliberately out of
scope — see `docs/operations.md` §9.
