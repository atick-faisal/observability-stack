# Onboarding an app

Four steps: copy `agent/`, label the containers, add the SDK, make one call. The claim this
document has to survive is that **the diff in your app repo is exactly those four things** — no
new services to write, no config to tune, no address to hardcode beyond `alloy:4317`.

`demo/` is a worked example of all four, and `make demo-up` runs `agent/` unmodified. If
something here disagrees with `compose.demo.yml`, that file is the tested one.

Before you start you need one ingest credential from whoever runs the server:
`./scripts/add-ingest-user.sh <app>-<env>` there prints both halves.

---

## 1. Copy the agent

```bash
cp -r observability-stack/agent your-app/observability
cp your-app/observability/.env.agent.example your-app/observability/.env.agent
```

Fill in `.env.agent`. Nothing in `agent/` is app-specific and `config.alloy` is not meant to be
edited — if you find yourself editing it, that is a bug in the label convention, not in your app.

| | |
|---|---|
| `OBS_APP`, `OBS_ENV`, `OBS_HOST` | The identity stamped on every metric and log stream. |
| `OBS_PROM_URL`, `OBS_LOKI_URL`, `OBS_TRACES_URL` | `https://ingest.<domain>/...` — native upstream paths. `OBS_TRACES_URL` is a **base** URL; the OTLP exporter appends `/v1/traces`. |
| `OBS_INGEST_USER`, `OBS_INGEST_PASSWORD` | The credential minted for this app+env. |

`.env.agent` is read *inside* the container, not interpolated by Compose — so a `$` in the
password needs no escaping here. (The server's `.env.lgtm` is the opposite; see
[`deploy-server.md`](./deploy-server.md) §3.)

Then run it alongside your app:

```bash
docker compose -f compose.lgtm.yml -f observability/compose.agent.yml up -d
```

Add `--profile postgres` for `postgres-exporter`, `--profile containers` for cAdvisor, or both.

## 2. Label the containers

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

`service` is the **role a process plays inside your app**, not what software it is. A Postgres
container belonging to `asset-management` is `app=asset-management, service=db` — never
`app=postgres`. [`labels.md`](./labels.md) is the contract; it wins over this page.

### The port must be exposed

> [!IMPORTANT]
> This is the first thing that goes wrong. The agent matches `obs.metrics.port` against Docker's
> port metadata, which means `EXPOSE` in the image or `expose:` in Compose. **Publishing** the
> port (`ports:`) is neither required nor wanted — the app should expose nothing to the host.

A container that genuinely cannot expose its port is what `OBS_EXTRA_TARGET` is for:

```bash
OBS_EXTRA_TARGET=host.docker.internal:9100
OBS_EXTRA_SERVICE=worker
```

### A container on two networks is scraped twice

Docker discovery emits one target per **(network × exposed port)**, so the same series arrives
twice with the same timestamp and Prometheus rejects the whole write. Set the network the agent
shares with your app:

```bash
OBS_DOCKER_NETWORK=yourapp_default    # form: <project>_<network>
```

Logs are unaffected — the Docker log source keys its tailers by container id, so a container with
three exposed ports is still tailed exactly once.

## 3. Add the SDK

```bash
uv add "obstack[grpc,sqlalchemy]"
```

| Extra | When |
|---|---|
| `grpc` | app → local Alloy on `:4317` (the default) |
| `http` | app → a collector over HTTP/1.1 |
| `sqlalchemy` | you pass `engine=` |
| `errors` | you set `OBS_ERROR_DSN` |

## 4. Wire it up

```python
from fastapi import FastAPI
from obstack import setup_observability

app = FastAPI()
obs = setup_observability(app, engine=engine, excluded_paths=["/health"])
```

One call configures structlog, registers the metrics and request-logging middleware, serves
`/metrics`, and starts exporting traces when `OBS_OTLP_ENDPOINT` is set. For a process with no
FastAPI app, `setup_worker_observability(metrics_port=9100)`.

Then set the app's own environment:

```yaml
environment:
  OBS_APP: yourapp
  OBS_SERVICE: api
  OBS_ENV: production
  OBS_HOST: app-vps-01
  OBS_VERSION: 1.4.0
  OBS_OTLP_ENDPOINT: http://alloy:4317   # the only address the app needs
```

> [!IMPORTANT]
> `OBS_APP` / `OBS_ENV` / `OBS_HOST` **must match what `.env.agent` says.** Keeping them in one
> file both halves read is the easiest way to guarantee it, and the failure when they drift is
> not an error — it is two sets of series that never join.

## Things that will bite you

**`OBS_HOST` is set by the app on the trace path, not by the agent.** Metrics and logs get the
agent's value; traces get the app's. An app that leaves it unset reports
`socket.gethostname()`, which inside a container is the container id — so its traces silently
disagree with its own metrics. Set it explicitly.

**`OBS_LOG_FORMAT: auto` renders to the console when `env=local`.** The agent parses JSON. If you
run a container with `OBS_ENV=local` and expect a collector to read its logs, set
`OBS_LOG_FORMAT: json` explicitly.

**Recreating a container can cost one batch of cAdvisor samples.** `id` is dropped from cAdvisor's
series because a container id is unbounded over time; while a recreated container briefly
coexists with its predecessor the two collapse onto one series, and Prometheus rejects the write
with `duplicate sample for timestamp`. It resolves within a scrape or two.

> [!CAUTION]
> **`OBS_INGEST_TLS_INSECURE` is not a convenience flag.** It disables certificate verification
> on all three writers, which makes the basic auth worthless — the credentials become readable by
> whoever terminates the connection. It exists so this stack's own end-to-end test can push
> through Traefik on a laptop. Leave it alone.

**`alloy validate` does not build components.** It checks syntax and the component graph, so a
malformed selector or an unresolvable endpoint passes validation and fails at startup. Watch
`docker compose logs alloy` after the first `up`.

## Verify the onboarding

From the app host:

```bash
docker compose logs alloy | grep -i error     # expect nothing
curl -s localhost:12345/metrics | head        # Alloy's own UI; /graph shows what it discovered
```

From Grafana, within a minute or two: `fastapi_requests_total{app="yourapp"}` has series, the
`Applications` dashboard populates when you pick your `app`, and a log line for that app carries a
`trace_id` in structured metadata that resolves in Tempo.

If metrics are missing but logs are not, it is almost always step 2's `expose:`. If both are
missing, it is the credential — the server's Traefik access log names the user on every request,
and a 401 there is a wrong or mis-escaped hash rather than a wrong URL.

## Postgres metrics

The exporter connects as its own least-privilege role, not the application user:

```bash
POSTGRES_EXPORTER_PASSWORD=... docker compose exec -T db \
  psql -U postgres -d appdb -f - < observability/postgres-exporter-init.sql
```

On a database that does not exist yet, mount that file into `/docker-entrypoint-initdb.d/`
instead and set `POSTGRES_EXPORTER_PASSWORD` on the Postgres container — it reads the variable
itself. Re-running rotates the password rather than failing.

`--collector.stat_checkpointer` is not optional on PostgreSQL 17+: the checkpoint counters moved
out of `pg_stat_bgwriter` into `pg_stat_checkpointer`, and that collector is off by default.
`agent/compose.agent.yml` already passes it.

## Error tracking, optionally

If the server runs GlitchTip, add the `errors` extra and one variable:

```yaml
OBS_ERROR_DSN: https://<key>@errors.<domain>/<project-id>
```

Unset or empty means no error reporting, which is the default. Events arrive tagged with the same
`app` / `service` / `env` / `host`, so an issue in GlitchTip and a trace in Tempo describe
themselves the same way.
