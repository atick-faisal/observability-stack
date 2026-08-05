# Implementation Tasks

Design rationale lives in [`PLAN.md`](./PLAN.md). Tick items off as they land; this file is the source of truth for progress across sessions.

Each milestone ends with a **Verify** step. Do not start the next milestone until the current one verifies.

---

## M0 — Foundations

- [x] `PLAN.md` and `TASKS.md` in project root
- [x] Repo skeleton per PLAN §2 — *only directories with real content are created; git does not track empty directories, so the rest of §2 stays a map and each milestone creates its own*
- [x] `.gitignore` — `.env*`, `!*.example`, `server/traefik/secrets/*`, `!server/traefik/secrets/.gitkeep`, `__pycache__/`, `.venv/`, `*.egg-info/`
- [x] `Makefile` — `up`, `down`, `logs`, `demo-up`, `demo-down`, `demo-verify`, `lint`, `test`
- [x] `README.md` — what this is, the two halves, quickstart pointer
- [x] `docs/labels.md` — the four identity labels, per-signal injection points, the "never a label" list
- [x] Initial commit

**Verify**: read `docs/labels.md` end to end. It is the contract everything after depends on; if it is vague, nothing downstream will be consistent.

---

## M1 — Server core

- [x] `compose.yml` — prometheus, loki, tempo, grafana; named volumes; ports bound to `127.0.0.1` only
- [x] `server/prometheus/prometheus.yml` — self-scrape only; `out_of_order_time_window: 2h`; `exemplars.max_exemplars: 200000`
- [x] Prometheus flags — `--web.enable-remote-write-receiver`, `--enable-feature=exemplar-storage`, `--storage.tsdb.retention.time=30d`, `--storage.tsdb.retention.size=25GB`
- [x] `server/loki/loki-config.yaml` — 336h retention, tsdb v13, `allow_structured_metadata`, `volume_enabled`, `discover_log_levels`, `pattern_ingester`, compactor retention, `reject_old_samples_max_age: 168h`
- [x] `server/tempo/tempo-config.yaml` — OTLP receivers, 168h `block_retention`, metrics_generator span-metrics + service-graphs remote_writing to Prometheus with exemplars, **`local-blocks` disabled**
- [x] `.env.server.example`
- [x] Healthchecks on ~~all four services~~ **prometheus and grafana only** (no proxy-clearing prefixes — that was a corporate-network artifact) — *the Loki and Tempo images are distroless: `grafana/loki:3.7.1` ships only `/usr/bin/loki` and `grafana/tempo:2.10.5` no `bin/` at all. No shell, no wget, no curl, so a container healthcheck is impossible. This is why the reference has none either. Readiness is asserted from the host in the verify block below; Grafana `depends_on` them with `condition: service_started`.*

Also landed, not in the original list:

- [x] No `user: "0"` anywhere — named volumes mount at each image's **own** data path (`/prometheus`, `/loki`, `/var/tempo`, `/var/lib/grafana`), so Docker seeds them with the image's ownership. The reference mounted at `/data/loki` and `/data/tempo`, paths absent from those images, which is what forced root.
- [x] `GF_PLUGINS_PREINSTALL_DISABLED=true` — every datasource here is core; without it Grafana logs a plugin permission `error` on every boot
- [x] `server/grafana/provisioning/{datasources,dashboards,plugins}/.gitkeep` + `alerting/empty.yaml` — Grafana logs an `error` for each provisioning subdirectory that does not exist, and a `warn` for a `.gitkeep` in `alerting/`
- [x] `Makefile` — `--env-file .env.server` (Compose only auto-loads `.env`) and an `env-check` prerequisite on `up`/`demo-up`

**Verify**:
```bash
cp .env.server.example .env.server   # set GF_ADMIN_PASSWORD
make up
# Loki and Tempo need ~60s after start ("Ingester not ready: waiting for 15s after being ready")
until curl -sf localhost:3100/ready >/dev/null; do sleep 3; done

curl -sf localhost:9090/-/healthy && \
curl -sf localhost:3100/ready && \
curl -sf localhost:3200/ready && \
curl -sf localhost:3000/api/health
```
A clean boot on fresh volumes logs **zero** `level=error` lines across all four services. Anything else is a regression.

---

## M2 — Grafana provisioning

- [x] `server/grafana/provisioning/datasources/datasources.yaml` — fixed UIDs `prometheus`/`loki`/`tempo`; `exemplarTraceIdDestinations`; Loki `derivedFields` (`matcherType: label`, `matcherRegex: trace_id`); `tracesToLogsV2` + `tracesToMetrics` with `tags: [{key: app},{key: service},{key: env}]`; `serviceMap`, `nodeGraph`
- [x] Remember `$$` escaping for `$__tags` / `${__value.raw}` (Grafana's provisioning loader interpolates `$VAR`)
- [x] `server/grafana/provisioning/dashboards/provider.yaml` — file provider, `foldersFromFilesStructure: true`, `updateIntervalSeconds: 30`, `allowUiUpdates: false`
- [x] Three placeholder dashboard JSONs in `Applications/`, `Databases/`, `Infrastructure/`

Also landed, not in the original list:

- [x] `tracesToLogsV2` uses `customQuery` — `{$$__tags} | trace_id="$${__span.traceId}"` — rather than `filterByTraceID: true`. `trace_id` is Loki **structured metadata** (labels §3), so this is an indexed filter; `filterByTraceID` would emit `|= "<traceID>"`, a substring scan of the log body.
- [x] Prometheus `timeInterval: 15s` (matches `scrape_interval`, so `$__rate_interval` resolves correctly) and `prometheusVersion` realigned to the pinned `3.11.3`
- [x] Deleted `provisioning/{datasources,dashboards}/.gitkeep` and `dashboards/.gitkeep` — superseded by real files, and M1 proved Grafana logs a `warn` for a `.gitkeep` in a directory it scans. `provisioning/plugins/.gitkeep` stays: that directory gets no real file and its absence logs an `error`.

Deferred, with reason:

- [x] ~~`tracesToMetrics` latency query~~ — shipped at M5. The histogram is `traces_spanmetrics_latency_bucket`, read off Prometheus rather than recalled.

**Verify**:
```bash
# $GF_ADMIN_USER, not a hardcoded admin — read the creds from the container so
# they never land in a shell history.
G() { docker compose --env-file .env.server -f compose.yml exec -T grafana \
        sh -c "curl -s -u \"\$GF_SECURITY_ADMIN_USER:\$GF_SECURITY_ADMIN_PASSWORD\" \"http://localhost:3000$1\""; }

G /api/datasources                | jq -r '.[].uid'      # → loki prometheus tempo
G '/api/search?type=dash-folder'  | jq -r '.[].title'    # → Applications Databases Infrastructure

# the $$ escaping round-tripped: single $ on the way out
G /api/datasources/uid/tempo | jq -r '.jsonData.tracesToLogsV2.query'
#   → {${__tags}} | trace_id="${__span.traceId}"

# each datasource actually reaches its backend over the obs network
for u in prometheus loki tempo; do G "/api/datasources/uid/$u/health" | jq -r .status; done   # → OK OK OK
```
Provisioned dashboards are immutable: a `POST /api/dashboards/db` with `overwrite: true`
returns `400 {"message":"Cannot save provisioned dashboard"}`. Note that `meta.canSave`
still reports `true` — in Grafana 13 that field reflects the *user's permission*, not the
provisioning lock, so the write attempt is the only real test.

Zero `level=error` lines, as at M1.

---

## M3a — `obstack` SDK

*Split out of the original M3 so the SDK is reviewable before the demo app depends on it.*

- [x] `sdk/obstack/pyproject.toml` — base deps + `[grpc]` / `[http]` / `[sqlalchemy]` / `[errors]` extras — *`fastapi` had to be named explicitly: `opentelemetry-instrumentation-fastapi` depends only on `opentelemetry-instrumentation-asgi`*
- [x] `settings.py` — `ObservabilitySettings(BaseSettings)`, `env_prefix="OBS_"`, `ObservabilityConfigError` raised on missing `app` (via `.load()`), plus `[a-z0-9-]+` enforcement on `app`/`service` so a malformed identity fails at startup rather than at query time
- [x] `logging.py` — structlog config; `_add_otel_context` injecting `032x`/`016x` hex; JSON vs Console by env; stdlib routed through `ProcessorFormatter`; **`foreign_pre_chain` must exclude `filter_by_level`**; `cache_logger_on_first_use=True`; noise suppression for `sqlalchemy.engine`, `uvicorn.access`, `watchfiles`
- [x] `metrics.py` — instance-local `CollectorRegistry`; `fastapi_requests_total` / `fastapi_requests_duration_seconds` / `fastapi_exceptions_total` / `fastapi_requests_in_progress` / `fastapi_app_info`; `disable_created_metrics()`; OpenMetrics exposition (`prometheus_client.openmetrics.exposition`)
- [x] `middleware.py` — `PrometheusMiddleware` (matched-route pattern, exemplars, `status_code="500"` default) and `RequestLoggingMiddleware` (event `"HTTP"`, level by status class, `clear_contextvars` at start)
- [x] `tracing.py` — TracerProvider, resource attrs (`app`/`service`/`env`/`host` + `service.name` + `deployment.environment.name`), FastAPI + optional SQLAlchemy instrumentors (an `AsyncEngine` is unwrapped to its `sync_engine`), degrade to no tracing on exporter failure
- [x] `errors.py` — `sentry_sdk.init(dsn, enable_tracing=False, shutdown_timeout=10)`, plus `environment` and `release` so GlitchTip can group by them
- [x] `runtime.py` — `setup_observability`, `setup_worker_observability`, `Observability` dataclass with `shutdown()`
- [x] `__init__.py` (four public names + `bind_request_context` + `ObservabilityConfigError`), `py.typed`
- [x] Tests — 37, covering settings validation, logging JSON shape incl. `trace_id`, metrics registry isolation across two setups, setup wiring, and the trace↔log↔exemplar correlation
- [x] `sdk/obstack/README.md` — usage example (the only place docs live)

Reference defects found and countered:

- [x] **`fastapi_responses_total` dropped.** The reference increments it in the same `finally` block with the same labels as `fastapi_requests_total` — a byte-identical duplicate series. See PLAN §5.
- [x] **Root-logger config does not reach uvicorn.** uvicorn installs handlers on its own loggers with `propagate=False`, so the reference's setup leaves startup lines and the entire `"Exception in ASGI application"` traceback as plain text — one Loki line per stack frame, none carrying a `trace_id`. `configure_logging` now clears those handlers and re-enables propagation; measured before/after on a real uvicorn process, 11/11 stdout lines are JSON.
- [x] **`BaseHTTPMiddleware` → pure ASGI.** Drops the per-request anyio task and the associated breakage of `StreamingResponse` backpressure and `BackgroundTasks` timing.
- [x] **`app_name` → `app`/`service`/`env`; `path` → `route`.** labels.md §4.1/§4.4 and §2 respectively.
- [x] `O(routes)` walk per request → `scope["route"]`, which the router already computed. The walk stays as fallback; labels.md §4.3 updated.
- [x] The scrape endpoint was still being *traced* while excluded from metrics — one trace per scrape, forever. Now excluded from both, and the ASGI `"http send"`/`"http receive"` child spans are suppressed (3 spans per request → 1).

**Verify**:
```bash
make lint && make test        # mypy strict + ruff + 37 tests
```
Then against a real uvicorn process, which is what catches anything `TestClient` cannot —
the uvicorn logger adoption above was found exactly this way:
```bash
OBS_APP=demo OBS_ENV=production uv run --with uvicorn uvicorn smoke:app --port 8123
curl -s localhost:8123/items/7 && curl -s localhost:8123/boom
curl -s localhost:8123/metrics | grep '^fastapi_'
#   → route="/items/{item_id}" (never /items/7), route="" for a 404,
#     exception_type="ValueError" at status_code="500"
curl -so /dev/null -w '%{content_type}\n' localhost:8123/metrics
#   → application/openmetrics-text; version=1.0.0; charset=utf-8   (or exemplars vanish)
```
Every stdout line must parse as JSON, including uvicorn's own.

Not verifiable here, by construction: exemplars reaching Prometheus (M5), spans reaching Tempo
(M3b), trace→log correlation in Grafana (M5).

---

## M3b — demo app

- [x] `demo/app` — FastAPI with `/ok`, `/items/{item_id}`, `/slow`, `/boom`, `/db`, and `/health` passed to `excluded_paths`; Dockerfile on `python:3.13-slim` + `uv`, non-root, installing `obstack` from the local path
- [x] `demo/loadgen` — async loop with a fixed error/slow mix (70/15/8/5/2), wired with `setup_worker_observability` on `:9101`
- [x] `compose.demo.yml` — *moved up from M4.* demo-api + demo-db + demo-loadgen on the server stack's `obs` network, OTLP straight at `tempo:4317`. M4 extends this file with the agent rather than creating it.
- [x] `make lint` extended to type-check and lint both demo projects — they are the template every onboarded app copies

Decisions worth keeping:

- [x] **`OBS_LOG_FORMAT=json` is set explicitly on both demo services.** `auto` resolves to the console renderer when `env=local`, which is exactly what the local demo is — so without this the e2e would exercise a pretty-printed log path production never uses, and M4's `stage.json` would be validated against nothing. The default is right for a developer running uvicorn by hand; it is wrong the moment a collector tails the container. Noted in the SDK README.
- [x] `client_requests_total`, not `loadgen_requests_total` — labels.md §4.4 bars `service` from a metric name exactly as it bars `app`. This is the pattern onboarded apps will copy for their own metrics.
- [x] httpx is instrumented in the loadgen, so `traceparent` propagates and each trace covers **two** services. Without it every trace has one service and Tempo's service graph — provisioned at M2, verified at M5 — has no edge to draw.
- [x] **Postgres 18 moved the data directory.** The volume mounts at `/var/lib/postgresql`; the image refuses to boot on the old `/var/lib/postgresql/data`. Found the hard way; recorded in `compose.demo.yml` and PLAN §8 so M4's postgres_exporter does not rediscover it.

Reference defects found and countered (`ai-asset-management/backend/Dockerfile`):

- [x] **`CMD ["fastapi", "run", "--workers", "4", …]` corrupts every counter.** Four processes share one listening socket, each with its own `CollectorRegistry`; consecutive scrapes answer from different workers, so a counter appears to move backwards and Prometheus reads each decrease as a reset. `rate()` is then wrong with nothing logged. The demo runs one worker per container; the SDK README grew a "Running multiple workers" section, because the instance-local registry does **not** save you here.
- [x] `FROM python:3.12` (not `-slim`) → `python:3.13-slim`. The demo image is 388 MB.
- [x] Runs as root, no `USER` → unprivileged `demo` user.
- [x] No healthcheck on the backend service, so nothing downstream can `depends_on: service_healthy` — which is exactly what the loadgen needs.

Fed back into the SDK:

- [x] `httpx` added to `_QUIET_LOGGERS`. It logs one INFO line per outbound request, duplicating whatever the caller already logs — the same relationship `uvicorn.access` has to our own `"HTTP"` line. Only visible once a real client process existed.

**Verify** — `make demo-up`, then:
```bash
curl -s localhost:8000/metrics | grep '^fastapi_requests_total'
#   route="/items/{item_id}" present, /items/7 absent, route="" for a 404,
#   status_code="500" and exception_type="ValueError" for /boom,
#   app/service/env on every series, /health absent entirely
curl -so /dev/null -w '%{content_type}\n' localhost:8000/metrics
#   → application/openmetrics-text; version=1.0.0; charset=utf-8

# every line JSON, uvicorn's own included — 429/429 and 425/425 when measured
docker compose --env-file .env.server -f compose.yml -f compose.demo.yml \
  logs --no-log-prefix demo-api | python3 -c \
  'import json,sys; [json.loads(l) for l in sys.stdin if l.strip()]; print("all JSON")'

# the join M3a could not make: a trace_id out of a log line, resolved in Tempo
TID=$(docker logs observability-demo-api-1 2>&1 | grep '"route": "/db"' | tail -1 | jq -r .trace_id)
curl -s "localhost:3200/api/traces/$TID" | jq -r '...'
#   → demo-loadgen: GET
#     demo-api: GET /db
#     demo-api: connect, INSERT, SELECT
```
The last one is the milestone: one trace spanning both services, with the SQLAlchemy spans nested
under the HTTP server span — which is the `AsyncEngine` → `sync_engine` unwrap running against a
real database for the first time. Both resources carry `app`/`service`/`env`/`host` plus
`service.name` and `service.version`.

Server stack still logs zero `level=error` lines, with one exception unrelated to the demo: Loki
emits a single `ratestore.go: error getting ingester clients err="empty ring"` while its ingester
joins the ring at startup, then never again.

---

## M4 — Agent

- [x] `agent/config.alloy`
  - [x] `discovery.docker` + `discovery.relabel "metrics_targets"` (label-driven, `keepequal` port match)
  - [x] `discovery.relabel "log_targets"` (drop on `obs.logs="false"`, derive `container`/`service`)
  - [x] `loki.source.docker` + `loki.process` with **`stage.match`-guarded** `stage.json` (plain-text containers must pass through untouched)
  - [x] `prometheus.exporter.unix` with stable `instance` relabel
  - [x] `otelcol.receiver.otlp` (gRPC 4317, HTTP 4318) → `batch` → `otelcol.exporter.otlphttp` — *no `attributes` stage; see the decisions below*
  - [x] Exits: `prometheus.remote_write` (external_labels, `send_exemplars`, queue_config, WAL), `loki.write`
  - [x] `OBS_EXTRA_TARGET` empty-env-var escape hatch
- [x] `agent/compose.agent.yml` — `alloy` always; `cadvisor` profile `containers` (Linux-native: no `privileged`, no containerd flag, `devices: [/dev/kmsg]`); `postgres_exporter` profile `postgres` with env-driven `DATA_SOURCE_URI` and the PG17+ collector flags incl. `--collector.stat_checkpointer`
- [x] `agent/compose.agent.macos.yml` — containerd override for local testing only
- [x] `agent/postgres-exporter-init.sql` — `postgres_exporter` role, `pg_monitor` grant, search_path
- [x] `agent/.env.agent.example`, `agent/README.md`
- [x] Extend `compose.demo.yml` (shipped at M3b) with the agent, and re-point `OBS_OTLP_ENDPOINT` from `tempo:4317` to `alloy:4317` — that one variable is the whole of what the agent changes for an app
- [x] `scripts/verify-signals.sh` (six checks, exit code = number of failures)

Decisions worth keeping:

- [x] **`honor_labels = true` on the discovered-targets scrape.** The SDK already stamps `app`/`service`/`env` on the app's own series, and the agent relabels `service` onto the target from `obs.service`. Without `honor_labels` those collide and Prometheus renames one `exported_service` — measured, then fixed. This is `docs/labels.md` §3.1's "the SDK's values win for those series", in config.
- [x] **`host` is not rewritten on spans.** `otelcol.processor.attributes` cannot reach resource attributes, so the upsert PLAN §3 described would need an `otelcol.processor.transform` with an OTTL statement concatenated from `sys.env`. The app's own value is used instead; `docs/labels.md` §5 now says so and states what it costs (traces only — `host` is in no correlation link and no span-metrics dimension).
- [x] **`service` falls back to the container name** where `obs.service` is absent, rather than to an empty label. Unlabelled containers still get their logs collected with something usable.
- [x] `agent/` is used **unmodified** by the demo — `make demo-up` overlays `agent/compose.agent.yml` — so "copy this directory into your repo" is a tested claim. `OBS_AGENT_DIR` exists because Compose resolves relative paths against the *first* `-f` file's directory, not the file's own.
- [x] `demo-down` no longer runs `down -v`: on the merged project that removed `grafana_data` too, and the Grafana admin account is created exactly once.

Measured, where reading the documentation would have been wrong:

- [x] **The port label is `__meta_docker_port_private`, not `__meta_docker_port_private_port`.** Prometheus' own `docker_sd` documents the latter; Alloy names it differently. With the wrong name `keepequal` matches nothing, every target is dropped, and *nothing is logged* — the component stays healthy with an empty output.
- [x] **`alloy validate` does not build components.** The config validated clean while carrying a `stage.match` selector that LogQL rejects. Validation covers syntax and the component graph; a bad selector, a bad endpoint, or a bad stage only surfaces when the container starts.
- [x] **LogQL rejects backtick raw strings in a line filter.** The regex is unescaped twice — once by Alloy reading the string, once by LogQL reading the quoted filter — so `\\\\s` in the config is `\s` at the regex.
- [x] **`loki.source.docker` tails a multi-port container exactly once.** Tested with a throwaway container exposing three ports: discovery emitted three targets, Alloy created one tailer, and Loki received one copy of each line. *Metrics* are not so lucky — one target per network means a two-network container is scraped twice, which is what `OBS_DOCKER_NETWORK` is for.
- [x] **`gcr.io/cadvisor/cadvisor:v0.57.0` does not exist.** That mirror stopped publishing after v0.47.x; v0.54.0+ lives on `ghcr.io/google/cadvisor`. PLAN §9 had the wrong registry; the reference had it right.
- [x] **Mounting `/var/run:ro` into cAdvisor makes `/run` read-only** (it is a symlink on Linux), so any later mount under `/run` fails to create its parent. Mount the socket alone.
- [x] **Loki adds a `service_name` stream label of its own** — a seventh label duplicating `service` under a second spelling. `discover_service_name: []` turns it off; `docs/labels.md` §3.2 records it.
- [x] **`/loki/api/v1/labels` is resolved over a coarse window** and keeps reporting labels from streams no longer being written. `verify-signals.sh` asserts on `/series` instead, which returns the label sets of streams actually active.

Reference defects found and countered (`observability/alloy/config.docker.alloy`):

- [x] **`send_exemplars` is never set, so it defaults to `false` and every exemplar is discarded at the last hop.** The reference does all the upstream work — OpenMetrics exposition, `.observe(…, exemplar=…)`, `--enable-feature=exemplar-storage` on Prometheus — and then throws the result away in the one line nobody reads. PLAN risk 6, made real.
- [x] **`environment="production"` on log streams next to `env="production"` on metric targets.** Two spellings of one concept, which Grafana cannot reconcile. `docs/labels.md` §4.1 is first in that document because of this line.
- [x] **`stage.json` applied unconditionally**, mangling Postgres and Traefik output and minting an empty `level` label for every plain-text line.
- [x] **Four hardcoded targets** (`backend:8000`, `postgres_exporter:9187`, `cadvisor:8080`, `host.docker.internal:9100`) — the premise of this repo.
- [x] **No `queue_config` and no `wal` block** on `prometheus.remote_write`; defaults only (PLAN risks 1–2).
- [x] **`compose_project` label with no consumer**, and `job="docker"` hardcoded onto every log stream.
- [x] **`service` sourced from `com.docker.compose.service`** — renaming a Compose service silently renames a label the dashboards filter on. `obs.service` is explicit.
- [x] **No OTLP receiver at all**: the app writes traces straight to Tempo, so it must know the collector's address and a VPS blip drops them with no local buffer.
- [x] cAdvisor `privileged: true` + the containerd flag (Docker-Desktop/WSL2 artifacts), and `--store_container_labels` left at its default, which turns every Docker label — including this stack's own `obs.*` — into a metric label.
- [x] `user: "0"` on the Alloy container is unnecessary: `grafana/alloy:v1.16.1` declares no `USER` and already runs as root.
- [x] `postgres-exporter-init.sh`, a shell wrapper whose header documents three ways to run it, none automatic → one `.sql` reading the password with psql's `\getenv`, so the same file works from `/docker-entrypoint-initdb.d/` and from `psql -f`.

Known and accepted, not worked around:

- [x] **Recreating a container costs one remote-write batch of cAdvisor samples.** `id` is dropped (unbounded over time), so while a recreated container briefly coexists with its predecessor the two collapse onto one series, Prometheus answers `400 duplicate sample for timestamp`, and the whole request is rejected — measured at 587 samples on one `docker compose up` of Loki. Recorded in `agent/README.md` with the one-line change that trades it back for cardinality.
- [x] **`prometheus.exporter.unix` logs one `level=error` per boot on Docker Desktop**: `udev_data_path` now points through `rootfs_path`, which resolves on a Linux VPS but not on the Mac VM, where `/run/udev` does not exist.
- [x] Removing a container mid-refresh logs one `error inspecting Docker container … No such container` from the log tailer. Transient, self-correcting.

**Verify** — `make demo-up`, then `./scripts/verify-signals.sh`, all six green:

```
1. metrics       fastapi_requests_total{app="demo"}; app/env/host/service/instance present,
                 instance is the container name, no exported_* collision
2. metrics       node_uname_info, container_memory_usage_bytes, pg_up — all carrying
                 app/env/host from external_labels alone
3. logs          stream labels are exactly app,container,env,host,level,service;
                 trace_id in structured metadata
4. traces        20 traces for service.name=demo-api, and the trace_id taken from a log
                 line resolves in Tempo across both services
5. exemplars     10 exemplar series survived the agent hop      (M5's, already green)
6. span-metrics  traces_spanmetrics_calls_total{app="demo"}     (M5's, already green)
```

Alloy's own graph (`localhost:12345/graph`) shows all 17 components healthy and four discovered
targets — `demo-api`, `demo-loadgen`, `cadvisor`, `postgres_exporter` — with no static address
anywhere in the config. The plain-text guard holds: `{service="db"}` returns intact Postgres
lines with no `level` label.

Server stack error lines on a clean boot: prometheus 0, tempo 0, grafana 0, cadvisor 0,
postgres_exporter 0, loki 1 (the known startup `empty ring`), alloy 1 (the macOS-only udev path).

---

## M5 — Cross-signal correlation

Two of the three questions this milestone existed to answer were settled at M4, because the agent
had to be running to answer them at all:

- [x] ~~Confirm exemplars survive the Alloy → Prometheus hop~~ — they do. `send_exemplars = true` on `prometheus.remote_write` is the whole of it, and it is off by default.
- [x] ~~Confirm Tempo 2.10.5 span-metrics picks up `app`/`service`/`env` from **resource** attributes~~ — `app` and `env` yes, so no `otelcol.processor.transform` is needed to copy them onto spans.

What was left was the collision that turned up while checking — and, once the running stack was
measured rather than read, three more next to it. All of them are fixed in one config block plus
one SDK function; no dashboard, app, or agent change followed.

- [x] **`traces_spanmetrics_*` carried `service="demo-api"`, not `service="api"`.** Fixed with `write_relabel_configs` on the generator's remote-write in `server/tempo/tempo-config.yaml`. That is the only mechanism that works: the `__` prefix is applied against a *hardcoded* list of the four intrinsics (`service`, `span_name`, `span_kind`, `status_code`), so `intrinsic_dimensions.service: false` does not un-prefix `__service`, and `dimension_mappings`' target name goes through the same check. Rejected: setting `service.name` to the bare service, which fixes the label at source but merges two apps' `api` into one node in Tempo's service list and one entry in its service dropdown — the opposite of what a multi-app stack needs.
- [x] **`http.response.status_code` was a dead dimension** — configured since M2, never populated. OpenTelemetry Python emits pre-1.0 attribute names (`http.status_code`, `http.method`, `http.target`) unless `OTEL_SEMCONV_STABILITY_OPT_IN` is set, and nothing set it. `obstack.tracing.apply_semconv_opt_in()` now does, from `build_tracer_provider()` — the one path both `setup_observability` and `setup_worker_observability` take, always before an instrumentor is constructed. `setdefault`, so `http/dup` survives.
- [x] **Service-graph edges carried no identity at all** — `{client, server, connection_type}` and nothing else, so M7's service map could not be scoped to `$app`. `service_graphs.dimensions: [app, env]`. `client`/`server` stay `service.name` on purpose: Grafana uses them as node names and clicks through to Tempo's service search on the value.
- [x] **`status_code` meant two different things in one Prometheus** — HTTP status on app metrics, span status on span-metrics. The span status is relabelled to `span_status` and `status_code` is cleared before the HTTP one takes it, so spans without an HTTP status (database, client) carry no `status_code` rather than a span status wearing its name.
- [x] **`__metrics_gen_instance` dropped** — its value is the Tempo container's id, so every restart re-identified every span-metric series.
- [x] `tracesToMetrics` gains the deferred p95 latency query, and its error query moves to `span_status`. All three scope to `span_kind="SPAN_KIND_SERVER"` — the rate a service *serves*, not that plus everything it calls — and break down `by (route)`.
- [x] `scripts/verify-signals.sh` — steps 5 and 6 are no longer advisory (`STRICT_STEPS` defaults to all seven), step 6 asserts the join rather than mere existence, and a new step 7 covers the service graph.

Measured, where reading the documentation would have been wrong:

- [x] **`write_relabel_configs` does apply.** Tempo's generator storage is Prometheus' own `remote.WriteStorage`, and the full `RemoteWriteConfig` is honoured. This was the milestone's one real risk; the fallback (routing the generator through the server Alloy) was not needed.
- [x] **`span_metrics.enable_instance_label: false` does not remove `__metrics_gen_instance`.** Tempo 2.10.5 accepts it, `/status/config` shows it applied, and the label is still written — it governs a plain `instance` label we never see. The knob was removed rather than left in place looking correct; the labeldrop does the work.
- [x] **Compose does not recreate a container when a bind-mounted config file changes.** `make demo-up` left Tempo running the old config, and the new labels only appeared after an explicit `docker restart`. Worth knowing before trusting any "I changed the config and re-upped" result.
- [x] Old span-metric series linger for the registry's `stale_duration` (15m) and Prometheus' 5m lookback, so a label change looks half-applied for several minutes. Verification polls for the *absence* of the old label rather than sleeping.
- [x] The service-graph database node became `demo-db` (the server address) rather than `demo` (the database name) once stable semconv landed — a better node name, and a reminder that the semconv switch reaches further than the two labels it was made for.

Reference defects found and countered:

- [x] `traces_spanmetrics_*` is unjoinable with the reference's own application metrics — same `service` collision, unnoticed, so its `tracesToMetrics` links have never returned data.
- [x] A dead `http.response.status_code` dimension, for the same reason ours was dead: nothing sets the semconv opt-in. A config that looks correct and does nothing is worse than one that is absent.
- [x] Service graph with no identity dimensions, on a stack meant to host more than one app.
- [x] `__metrics_gen_instance` left enabled on a single-generator deployment.
- [x] `status_code` carrying two different meanings in one Prometheus, with nothing distinguishing them.

**Verify** — `make demo-up`, `docker restart observability-tempo-1`, then `./scripts/verify-signals.sh`, all seven green:

```
6. span-metrics  labels are exactly
                 __name__,app,env,route,service,span_kind,span_name,span_status,status_code
                 and this returns non-zero:
                   count(
                     sum by (app,env,service,route,status_code) (traces_spanmetrics_calls_total{...})
                     and
                     sum by (app,env,service,route,status_code) (fastapi_requests_total{app="demo"})
                   )
7. service graph edge demo-loadgen → demo-api, labelled app=demo
```

That join is the milestone assertion: the same request, described independently by the app's own
instrumentation and by Tempo's generator, agreeing on five label names and values with no
translation layer between them.

A recent trace carries `http.request.method`, `http.response.status_code`, `url.path`,
`server.address` — stable semconv, and the reason `status_code="200"` exists on span-metrics at
all. The three `tracesToMetrics` queries return data with `$__tags` expanded to
`app="demo",service="api",env="local"`; `/slow` reports a p95 of 1.92s, which is the load
generator's configured delay.

- [x] **The round trip, by hand in Grafana.** Explore → Prometheus → `fastapi_requests_duration_seconds_bucket` with exemplars on → exemplar → Tempo trace → the span's links → Loki line → **View Trace in Tempo** → back to the same trace. Confirmed end to end.

  **Grafana 13 has no "Logs for this span" button.** Trace→logs, trace→metrics and span links are all collapsed behind one blue **Links** dropdown at the top-right of the expanded span detail. Following an older walkthrough, the reasonable conclusion is that `tracesToLogsV2` is misconfigured — it is not. `GET /api/datasources/uid/tempo` in the logged-in browser tab is the fastest way to separate "config missing" from "UI moved"; the config Grafana stores can also be read from `grafana.db` without credentials at all.

  Fresh traces confirmed carrying `http.request.method` / `url.path` / `server.address` in the UI. Worth noting that Tempo's 7-day retention means Explore's default window still shows pre-M5 traces with the old attribute names — narrow to the last 15 minutes before concluding the semconv opt-in did not take.

---

## M6 — Edge and ingest auth

The deployment target turned out to be a Hetzner VPS **already running Dokploy**, which
already runs Traefik on `:80`/`:443` with a working Let's Encrypt resolver. That invalidated
most of the original checklist, which assumed the stack brought its own proxy and owned the
box. Recorded below as it was actually built. Domain is `obs.atick.dev` (DNS at name.com),
nested so one name covers every service this stack will add.

### 6a — packaging and routing

- [x] `server/{prometheus,loki,tempo,grafana}/Dockerfile` — each COPYs its own config in
- [x] `compose.yml` is now the **deployed** shape: `build:`, Traefik labels, **no published ports, no bind mounts**
- [x] `compose.local.yml` — `127.0.0.1` ports and bind-mounted config, added by `make up` / `make demo-up`
- [x] Router labels: `grafana.${OBS_DOMAIN}`; `ingest.${OBS_DOMAIN}` × 3 native paths → prometheus / loki / tempo
- [x] `obs-secure-headers` middleware (HSTS, nosniff, referrer-policy) on Grafana
- [x] `compose.edge.yml` — our own Traefik, for a host with no proxy; static config as CLI args
- [x] `compose.demo.edge.yml` + `make demo-up EDGE=1` — routes the demo agent through the edge
- [x] `make config-check` renders the deployed shape without needing the external network to exist

**Measured, where reading the documentation first would have been wrong:**

- [x] **`include:` cannot override anything.** The plan was `compose.dokploy.yml` importing `compose.yml` and adding network membership. Compose rejects it: `services.tempo conflicts with imported resource`, and the same for networks. `include:` is strictly additive.
- [x] **`external:` interpolates, which is what replaced it.** `external: ${OBS_EDGE_EXTERNAL:-false}` renders as a plain bridge by default and as `external: true` with the variable set — verified with `docker compose config` both ways. Two variables, no second compose file, and the deploy points straight at `compose.yml`.
- [x] **`extends:` was not an option either** — it explicitly drops `depends_on`, which would have silently broken tempo's wait on prometheus.
- [x] **Grafana's dashboards could not be baked at `/var/lib/grafana/dashboards`.** That path is inside the `grafana_data` volume, and a named volume only inherits image content when it is *first* created — on the existing volume the baked dashboards would have been shadowed and silently absent. Moved to `/etc/grafana/dashboards`, which no volume covers, and `provisioning/dashboards/provider.yaml` updated to match.
- [x] **Traefik's static config sources are mutually exclusive** (file *or* CLI *or* env). A `server/traefik/traefik.yml` therefore could not have read `ACME_EMAIL` from `.env.server`; CLI args can, so the file was never created.
- [x] **Local edge runs were hitting production Let's Encrypt.** With a real `OBS_DOMAIN` whose DNS does not point at the laptop, every validation fails — and LE counts 5 failed validations per hostname per hour against you. `make demo-up EDGE=1` now pins `ACME_CASERVER` to the staging directory.
- [x] **`ingest.<domain>` does not resolve inside a container.** Docker's DNS knows nothing about it, and a resolver that does answer for `.localhost` answers `127.0.0.1` — the agent talking to itself. Traefik carries network aliases for both hostnames instead.
- [x] Baked configs verified by extracting them from the images (`docker create` + `cp`, since loki and tempo are distroless and have no shell) and diffing against the repo — identical for all four.

**Verified**: `make config-check` OK · `make demo-up` then `verify-signals.sh` **7/7 green**, unchanged by the packaging switch · through the edge, `https://grafana.obs.atick.dev/api/health` returns Grafana's health JSON with HSTS/nosniff/referrer-policy applied, `http://` 301s to it, and the three ingest routers **fail closed with 404** because 6b's auth middleware does not exist yet.

### 6b — ingest authentication

- [x] `obs-ingest-auth` (basicauth `users` from `${INGEST_USERS}`, `removeheader`) and `obs-ingest-ratelimit` (100/s, burst 200, per client IP), both label-defined on prometheus and referenced `@docker` from loki and tempo
- [x] `scripts/add-ingest-user.sh` — `htpasswd -nbB`, emitting the hash **already `$$`-doubled**, with a docker fallback where apache2-utils is absent
- [x] `scripts/verify-ingest.sh` — 6 checks, exit code = failures
- [x] `OBS_INGEST_TLS_INSECURE` on all three writers in `config.alloy`, documented as local-only in three places
- [x] `INGEST_USERS` in `.env.server.example`, carrying the demo:demo hash so a fresh clone runs

`usersFile` was specified in PLAN §7 precisely to avoid `$$`-doubling bcrypt hashes, but it needs
a path readable inside *Traefik's* container and we no longer own that container. The doubling
moves to a script and a test instead.

**Measured:**

- [x] **A single `$` in `.env.server` does not merely unescape — it truncates.** `INGEST_USERS=demo:$2y$05$AAAA` renders as `demo:$2y$05`, because Compose reads `$AAAA` as a variable reference and expands it to nothing. Doubling is not cosmetic; measured both ways with `docker compose config`.
- [x] **Shell environment variables are *not* re-interpolated, `--env-file` values are.** So the value passes with a single `$` from the shell and a doubled `$$` from the file. Only the file form matters for `.env.server`, but the asymmetry will mislead anyone debugging by exporting the variable to compare.
- [x] **`${entry//$/$$}` in bash expands `$$` to the shell's PID**, producing a plausible-looking hash that is silently wrong (`demo-local:311652y311650531165kPAt…`). `add-ingest-user.sh` uses `sed` instead.
- [x] **The rate-limit check passed while testing nothing.** 400 sequential `curl` invocations each pay process startup and a TLS handshake, capping out well below the 100/s limit. Re-run through `xargs -P 50`: 123/400 return 429.
- [x] **Tempo answers 415, not 400, to an empty body** — it checks the content type before looking at the body. With `Content-Type: application/json` and `{}`, a well-formed OTLP request carrying no spans, it returns 200; that is the one backend that can be asked to *accept* something rather than reject it.

**Verified**: `verify-ingest.sh` 6/6 — 401 with no credential, wrong password and unknown user; 400/400/200 from the three backends with the right one; 404 on `/graph`, `/-/quit`, `/api/v1/query`, `/api/v1/admin/tsdb/delete_series`, `/loki/api/v1/query`, `/ready`, `/metrics` and `/`; 123/400 rate-limited.

**The milestone assertion**: with the demo agent pushing through the edge, Traefik's access log shows **23× 204 on `/api/v1/write`, 83× 204 on `/loki/api/v1/push`, 44× 200 on `/v1/traces`**, all attributed to user `demo` — and `verify-signals.sh` is **7/7 green** with the newest sample 7 seconds old. Every signal traversed Traefik with basic auth, and nothing about the label contract changed.

---

## M7 — Dashboards

All three are classic v1 JSON, `schemaVersion: 41`, fixed datasource UIDs, `editable: false`,
and hand-written — no vendored community dashboard, for the reasons in PLAN §6. The verifier
lands first, because 40 hand-written panels is well past the number anyone re-checks by eye.

### 7a — the verifier and the FastAPI dashboard

- [x] `scripts/verify-dashboards.sh` — file shape, every panel expression, and Grafana's own view of what it provisioned
- [x] `make verify-dashboards`
- [x] `Applications/fastapi-service.json` — 14 panels in five rows: RED stats; requests by route and status code; p50/p95/p99 with exemplars on p99; p99 by route; a top-routes table joining rate and p99; exception types; error rate by route; an embedded Loki panel on the same `app`/`env`/`service` selection; Tempo's service map beside the `traces_service_graph_*` series that feed it

**Measured, where reading the documentation first would have been wrong:**

- [x] **cAdvisor series carry `service="cadvisor"`, not the observed container's service.** The container's identity is in `name` and `image`. Applying the shared `$service` variable to a per-container panel returns nothing — which is why M7's variable chain is not uniform across the three dashboards, contrary to what PLAN §6 claimed.
- [x] **Node-exporter series carry no `service` label at all** (`app`, `env`, `host`, `instance`, `job`), so the Infrastructure dashboard keys on `$host` instead.
- [x] **cAdvisor exports no restart counter.** `container_restart_count` does not exist; restarts are `changes(container_start_time_seconds{name!=""}[$__range])`.
- [x] **jq's `//` treats `false` as absent.** The obvious spelling of the `editable: false` assertion, `.editable // "absent"`, failed on all three dashboards — the ones that were correct. `has("editable")` instead. The check tested nothing until it tested the wrong thing loudly.
- [x] **`format: "table"` is applied in the browser, not by the backend.** `POST /api/ds/query` returns one labelled frame per series either way, so the top-routes table's `joinByField` cannot be asserted from the API. What is asserted: both targets return `route`-labelled series, and Grafana round-trips the four transformations unmodified.

**Verified**: `verify-dashboards.sh` — 16 Prometheus/Loki targets green (1 tempo panel reported as not evaluable), file shape green, and Grafana reports all three dashboards provisioned under the folder each directory name implies. `verify-signals.sh` still **7/7**. Grafana loads all 19 panels including the five row headers, with no provisioning errors in its log.

### 7b — the remaining two

- [x] `Databases/postgresql.json` — 17 panels in five rows: `pg_up`, connections vs `max_connections`, DB size, uptime; transactions, rows, cache hit ratio, longest transaction; connections by state, deadlocks, replication lag, WAL; checkpoints, checkpoint I/O, dead tuples, autovacuum; the database's own logs. Variables are `$app`/`$env`/`$datname` — the placeholder's `$service` is gone, because one exporter covers every database and filtering on the single value `db` selects nothing useful
- [x] `Infrastructure/host-and-containers.json` — 17 panels in three rows: CPU/memory/load/uptime/container-count stats; CPU by mode, memory, load against core count, filesystem, disk, network; per-container CPU, memory, network in/out, restarts, OOM kills. Variables are `$app`/`$env`/`$host`/`$container`

**Measured, where reading the documentation first would have been wrong:**

- [x] **`pg_stat_database_*` counters carry no `_total` suffix** — `pg_stat_database_xact_commit`, `…_blks_hit`, `…_deadlocks` — while `pg_stat_checkpointer_*` and `pg_stat_bgwriter_*` in the *same exporter* do have it. Ten panels' worth of plausible names would have returned nothing.
- [x] **`pg_settings_max_connections` carries a `server="demo-db:5432"` label** that `pg_stat_database_numbackends` does not, so connections-vs-max is `scalar()`, not a label join. The numerator is deliberately unfiltered by `$datname`: the limit is server-wide, so a per-database numerator would be a meaningless percentage.
- [x] **`pg_stat_activity_count` and `pg_stat_activity_max_tx_duration` emit a synthetic `state="disabled"` row** alongside the real states. Unfiltered, `max()` reports a duration belonging to no session, and the by-state panel charts a state no connection is ever in.
- [x] **`container_spec_memory_limit_bytes` is 0 for every container** — nothing here sets a memory limit, so "memory as a percentage of limit" evaluates to `+Inf`. The panel was dropped rather than shipped as one the harness cannot assert; `container_oom_events_total` answers the same question without inventing a denominator.
- [x] **`container_cpu_cfs_throttled_seconds_total` and `container_fs_usage_bytes` return nothing** for named containers under this cAdvisor build. Also dropped.
- [x] **Node disk and network series are mostly stubs**: 16 of 18 block devices are `nbd1`–`nbd15`, and 9 of 10 interfaces are `erspan0`/`gre0`/`gretap0`/`ip6tnl0`/`sit0`/`tunl0` — which the conventional `device!~"lo|veth.*|docker.*"` deny-list lets straight through. Disk uses `topk(5, …)`; network uses an allow-list. Both stay correct on a VPS, where an allow-list of mountpoints or device names would not.
- [x] **`includeAll` on `$container` expands to `.*`, which matches cAdvisor's machine-level series** (`name=""`). Every container panel carries `name!=""` as well; without it the "Containers" count and every stacked panel gain a phantom member.

**Verified**: `make verify-dashboards` — **51 Prometheus/Loki targets green across all three dashboards** on the first run, 1 tempo panel reported as not evaluable, file shape green, all three provisioned under the folder their directory name implies. Grafana loads both new dashboards at version 2 (22 and 20 panels including row headers) with no provisioning errors. `verify-signals.sh` still **7/7**, `make lint` clean, `make test` 39 passed. The packaged path is now proven too: `docker compose -f compose.yml build grafana` bakes all three under `/etc/grafana/dashboards/<Folder>/`, byte-identical to the repo.

---

## M8 — GlitchTip

- [x] `compose.glitchtip.yml` — `glitchtip-web` / `-worker` / `-migrate` + own `postgres:16-alpine` + `valkey`, on a third network of their own. An overlay of the same Compose project rather than a second project, so `glitchtip-web` joins the existing `edge` network and needs no proxy or published port of its own
- [x] `compose.glitchtip.local.yml` — `127.0.0.1:8001`, the one thing local work needs and a deploy must not have
- [x] `.env.glitchtip.example` — read by the containers via `env_file:`, never interpolated by Compose
- [x] Traefik router `errors.<domain>` → `glitchtip-web:8000` behind `obs-secure-headers@docker`
- [x] `scripts/verify-errors.sh` (+ `make verify-errors`, `glitchtip-up`, `glitchtip-down`, `glitchtip-logs`) — health, migrate, DSN, `/boom` → issue, and the event's tags
- [x] `OBS_ERROR_DSN` passthrough on `demo-api`, empty by default; `obstack[errors]` in the demo's dependencies
- [x] `sentry_sdk.init(server_name=settings.host)` in the SDK, with a test

**Measured, where reading the documentation first would have been wrong:**

- [x] **`ENABLE_OPEN_USER_REGISTRATION` is not a GlitchTip setting.** The name is `ENABLE_USER_REGISTRATION`, it defaults to **true**, and the wrong name is accepted in silence — set it, restart, and open registration is still on. Caught only by reading the setting back out of the running container.
- [x] **`GLITCHTIP_MAX_EVENT_LIFE_DAYS` is the legacy name**; `settings.py:163` reads it solely as the fallback default for `GLITCHTIP_RETENTION_DAYS`. Both work today; only one will keep working.
- [x] **`ALLOWED_HOSTS` defaults to `["*"]`**, and GlitchTip logs a warning about it on every boot. Restricting it is right, but it has to include the *in-network* name as well as the public one: an app reporting to `http://<key>@glitchtip-web:8000/1` sends `Host: glitchtip-web:8000`, and Django rejects an unknown host with a 400 before any view runs. Proven both ways here — `https://errors.<domain>` returned 400 until the hostname was added, then 200.
- [x] **`GLITCHTIP_DOMAIN` is a full URL, not a domain** — `settings.py:91` raises `ImproperlyConfigured` unless it starts with `http`. Its *scheme* is what decides whether session and CSRF cookies get the `Secure` flag (`settings.py:801`), so leaving it `http://…` on a stack served over TLS is a silently insecure cookie, not a cosmetic wrong link.
- [x] **The CSRF failure I expected does not happen, so it is not claimed.** Django compares the browser `Origin` against `<scheme>://<host>`, and behind a TLS-terminating proxy that is usually `http` vs `https`. Measured: a real login POST through Traefik, carrying a browser `Origin` and a valid CSRF cookie, returns **400 `email_password_mismatch`** — granian forwards the scheme, so Django already sees `https`. `CSRF_TRUSTED_ORIGINS` is still set, because that is a property of the app server rather than of the configuration, but the comment says what was measured.
- [x] **The event's `server_name` was the container ID**, not `OBS_HOST` — `sentry_sdk` defaults to `socket.gethostname()`. An error tagged `e8ca088cb289` joins nothing: it matches no `host` label on any metric, log or trace, and it changes on every recreate. One argument, and the fourth signal is filterable by the same strings as the other three.

**Verified**: `verify-errors.sh` **8/8** — `/_health/` 200, `glitchtip-migrate` exited 0, the demo's DSN matches a key on the project, `GET /boom` moves the event count, and the newest event carries `transaction=/boom`, `environment=local`, `release=demo-api@0.1.0`, `server_name=demo-host`. `--bootstrap` is idempotent. Through the edge, `https://errors.<domain>/_health/` returns 200 with `referrer-policy: strict-origin-when-cross-origin`, so the router and the shared middleware both apply; Traefik's ACME attempt for that hostname appears in its log alongside the other two, failing against the staging CA exactly as they do because DNS does not point here. `verify-signals.sh` still **7/7**, `verify-dashboards.sh` still green, `make lint` clean, `make test` **41 passed**, and `compose.yml + compose.glitchtip.yml` renders with the edge network external and nothing published.

**Reference defects surfaced** (measured against `../ai-asset-management/observability/`, not read off):

- Its GlitchTip runs as **the cluster superuser in the default database with the password `postgres`** (`DATABASE_URL=postgres://postgres:postgres@postgres:5432/postgres`), and that same container **publishes `5431:5432` on every host interface**.
- `web` **publishes `8001:8000`**, so the app answers regardless of what fronts it.
- **One `.env` serves both stacks**: GlitchTip's `SECRET_KEY` and DB password sit beside `GF_ADMIN_PASSWORD`, `POSTGRES_EXPORTER_PASSWORD` and the corporate proxy settings. There is no way to hand over or rotate one without the others.
- **`valkey/valkey` carries no tag at all** → `:latest`, whatever it happens to be at redeploy. `postgres:16` floats its minor.
- **No healthchecks, and `depends_on` is a bare list** — `web`, `worker` and `migrate` all start when Postgres's *container* exists, not when it accepts connections, and `migrate` races `web` instead of gating it.
- **`GLITCHTIP_DOMAIN=http://10.200.112.10:8001`** — one deployment's private IP, committed in the example, over plaintext, which by `settings.py:801` also means non-`Secure` cookies anywhere it is served over TLS.
- **Neither retention variable is set**, so events keep the 90-day default while the LGTM stack beside it retains 30d metrics / 14d logs / 7d traces. The error outlives every signal that would explain it, by two months.

---

## M9 — Resilience

- [x] `loki.write` WAL in `agent/config.alloy`, plus the endpoint retry budget the WAL alone does not fix
- [x] `otelcol.storage.file` backing the trace exporter's `sending_queue`, with an explicit `retry_on_failure` — the third signal now buffers too, rather than being written off
- [x] `--stability.level=public-preview` in `compose.agent.yml`, for that one component and nothing else
- [x] `scripts/backup.sh` — grafana + GlitchTip by default, the three TSDBs behind `--all`, `manifest.txt` + `SHA256SUMS`, `--keep N`
- [x] `scripts/restore.sh` — refuses an unverifiable or mismatched backup, `--yes`-gated, one restore method per storage engine
- [x] `scripts/verify-resilience.sh` (+ `make verify-resilience`, `backup`, `restore`)
- [x] `agent/README.md` — what the agent holds on to, for how long, and the server-side window each buffer needs

**Measured, where the plan was wrong:**

- [x] **The `loki.write` `wal` block is generally-available in Alloy 1.16.1 and needs no flag.** PLAN §10.2 called it experimental and recommended "enable it and accept the gate"; it graduated in the interim. Alloy starts with the block at the default stability level and creates `/var/lib/alloy/loki.write.obs/wal` — measured, not read.
- [x] **A stability flag *is* needed, but for a different component and a weaker gate.** `otelcol.storage.file` is `public-preview`. Proven both directions: with the flag Alloy runs, without it Alloy exits 1 with a message naming the component. The flag is a floor, not a switch — it permits public-preview components to be referenced, and everything else in `config.alloy` is GA.
- [x] **The WAL on its own would still have lost logs in the very outage it exists for.** `loki.write`'s endpoint defaults to `max_backoff_retries = 10`, which on the same backoff curve gives up after roughly nine minutes — inside a fifteen-minute outage, and a batch dropped there is dropped for good. Twenty retries carries it past an hour. Enabling the WAL without touching this would have looked done and not been.
- [x] **`otelcol` discards silently after five minutes.** `retry_on_failure.max_elapsed_time` defaults to `5m`, after which the batch is dropped with no further log line — so the failure mode is not an error, it is a hole in the traces that nothing records. `0s` means keep retrying and lets the queue, rather than a timer, be the bound.
- [x] **Alloy rejects an unknown block attribute at startup**, which is what makes the WAL's five argument names verifiable instead of assumed: a deliberate `definitely_not_a_real_arg` fails the initial load by name. Every argument in both new blocks was confirmed this way before the comments describing them were written.
- [x] **Tempo stores backfilled traces but its time-bounded search will not show them.** After a 15-minute outage, `/api/search?start=&end=` over the first ten minutes of that window returned **0 traces** — while `GET /api/traces/<id>`, for an id taken from a log line stamped 60 seconds into the same outage, returned **200 with `demo-api` and `demo-loadgen` on it**. Alloy's own counters agree with the second reading: `otelcol_exporter_sent_spans_total` climbing with no `send_failed_spans_total` and no `enqueue_failed_spans_total` registered at all. The spans are there; the search path does not surface them. This is worth knowing because the obvious way to check after an outage — search Tempo over the window — reports data loss that did not happen. `verify-resilience.sh` asserts the trace side through the `trace_id` on a backfilled log line instead, which is the same join `verify-signals.sh` already relies on.
- [x] **The first draft of that check defaulted `STRICT_STEPS` to `1,2,3,4,5` while the script had grown to seven `check` calls**, so the trace and buffer assertions were downgraded to warnings and the run still printed "all required checks passed" — with a genuine failure in it. Caught by reading the output rather than the exit code.
- [x] **A missing Prometheus bucket has no null to look for.** `count_over_time` at a step with no samples yields no series, so the point simply is not in the response — counting the returned points against the expected count *is* the gap check, and looking for zeros instead would pass through any hole.
- [x] **BusyBox `tar` has no `--numeric-owner`**, and would have failed the extract on that flag. It also does not need it: with no uname/gname mapping at all it restores the numeric uid/gid from the header, which is what keeps Grafana's 472 and Prometheus' 65534 intact.
- [x] **Waiting for the middle of a replay is not waiting for the end of it.** The drain poll originally watched for a sample from *inside* the outage, but `remote_write` replays its WAL in order, so that only proves the replay started. A run reported **19/20 buckets — "there is a hole in the metrics"** at `t1+372s`; querying the identical window by hand a minute later returned **20/20, twenty samples each**. The condition is now the newest bucket the assertions need (`t1+120`), which cannot be satisfied early or by live traffic because it has not happened yet when the polling starts — and it subsumes the fixed wall-clock wait it replaced.
- [x] **A restore cannot be checked by hashing the file back, and not against a live system either.** Grafana writes to `grafana.db` on boot, so a correctly restored database never hashes equal to its backup. The marker is the `user` table's per-install random salt instead — regenerated by a fresh install, untouched by a restart (measured identical across `docker restart`), and hashed so no credential material is printed. On the GlitchTip side an exact event count is only meaningful with the load generator stopped: measured **643 → 646 in 16 seconds** on its own, which is enough to make a correct restore look like it lost four events.

**Verified**: `make verify-resilience` **9/9** against a real **901-second** outage of `prometheus loki tempo grafana` with the app still serving — metrics **20/20 60s buckets present, none empty**, across a window running from two minutes before the outage to two minutes after; **100 log lines backfilled with their own timestamps, the earliest 60s into the outage** rather than at replay time; and trace `f794d696…`, taken from a log line in the first minute of the outage, resolving in Tempo with `demo-api,demo-loadgen` on it. The buffers were doing the work rather than retries: the `loki.write` WAL kept being written to while Loki was down, and the trace queue held **352 batches on disk** mid-outage. The replay reached the end of the window **382s** after the restart, most of which is `remote_write`'s reconnect backoff rather than the replay itself.

Backup and restore round-tripped for real, not dry-run: `backup.sh --all` wrote grafana 147.1KB / prometheus 21.9MB / loki 13.7MB / tempo 43.3MB / `glitchtip_pg` 4.0MB / uploads 199B with a manifest and verified sums, and `restore.sh` was then run against a **genuinely destroyed volume** — `docker volume rm observability_grafana_data`, recreated empty by compose. The Grafana install fingerprint went `32b9a46c` → `eb734f7a` (a fresh install, so a no-op restore could not have passed) → `32b9a46c`, and GlitchTip's event count went **651 → 656 → 651 exactly**. `restore.sh` refuses a backup whose `SHA256SUMS` is missing or does not match, checked by tampering with one.

No regressions: `verify-signals.sh` **7/7**, `verify-dashboards.sh` green (51 targets, all three dashboards provisioned), `verify-errors.sh` **8/8**, `make config-check` OK, `make lint` clean, `make test` **41 passed**.

**Reference defects surfaced** (measured against `../ai-asset-management/observability/`, not read off):

- **`compose.lgtm.yml:163` sets `--stability.level=generally-available` explicitly**, which is already the default. So the `loki.write` WAL is not merely unused there — at the time that line was written it was unreachable. Neither `config.docker.alloy` nor `config.windows.alloy` contains a `wal` block anywhere, on any writer.
- **Its `prometheus.yml` sets no `tsdb.out_of_order_time_window`.** With two or more agents, a sample older than the head's max time is rejected outright — so even if it did buffer, the replay would be refused and the gap made permanent. The buffering and the acceptance window are two halves of one feature, and it has neither.
- **Its `loki-config.yaml` limits block sets no `reject_old_samples_max_age`**, leaving Loki's default. Same problem, log side.
- **There is no backup or restore script anywhere in the repository** — `find -iname '*backup*'` returns nothing. Single node, filesystem storage, no copy of `grafana.db`, and a GlitchTip Postgres holding every error ever reported.

The first three are one finding seen three times: the reference's durability story is not weaker than this one, it is that buffering would not have helped it even if it had any.

---

## M10 — Ship

- [x] **Rename the SDK `obskit` → `obstack`.** The name was taken on PyPI before we could publish it.
- [x] `docs/deploy-vps.md` — provisioning, DNS, first `up`, clock-sync check
- [x] `docs/onboarding-an-app.md` — the four-step diff, incl. the `EXPOSE`/`expose:` requirement for label-driven scraping
- [x] `docs/local-dev.md` — demo stack, Mac caveats
- [x] `docs/operations.md` — retention/disk, backup/restore, cardinality watch, **do-not-re-enable Tempo `local-blocks`**, pinned digests, out-of-scope list, and the `$`-in-password trap: Compose collapses `$$` → `$` when reading `--env-file`, so a `$` in `GF_ADMIN_PASSWORD` reaches Grafana as something other than what the file shows (measured: `PW=ab$$cd` arrives as `ab$cd`)
- [x] Pin resolved digests for `traefik`, `glitchtip`, `valkey` — multi-arch index digests, with `scripts/resolve-digests.sh --check` to report drift without ever re-pinning on its own. `postgres:16-alpine` / `postgres:18-alpine` deliberately left floating; the reasoning is in `docs/operations.md`.
- [ ] Deploy to the VPS; onboard the first real app; tag `v0.1.0`

**Verify**: `curl -vI https://grafana.<domain>` shows a Let's Encrypt chain. The onboarded app's repo diff is exactly: copy `agent/`, add `obs.*` labels, `uv add obstack`, one `setup_observability(app, engine=engine)` call.

### Measured, where the plan was wrong

- [x] **The SDK's name was already on PyPI, and nothing in the plan would ever have caught it.** `obskit` is an active package — Talaat Magdy, v1.1.0, uploaded 2026-04-01, described as *"Production-ready observability toolkit for Python microservices"*, which is our pitch almost word for word. Every milestone from M2 on had been building against a name that could not be published. Nothing failed, because nothing checked: a name is only contested at `twine upload`, which is the last step of the last milestone. Renamed to **`obstack`** here — 93 occurrences across 34 files, one directory, three lockfiles — because after `v0.1.0` is tagged and anyone has installed it, the same edit is a breaking change instead of a mechanical one. The general lesson is that a distribution name is an external dependency and should be claimed, or at least checked, at the moment it is chosen.
- [x] **`docker manifest inspect -v` hands you the wrong digest to pin.** It reports one `Descriptor` per platform, and the first entry is `linux/amd64` — so the obvious `jq -r '.[0].Descriptor.digest'` yields a *platform manifest*, and pinning it produces a compose file that runs on the VPS and cannot start on an arm64 Mac. What has to be pinned is the multi-arch **index** digest, which comes from the registry's `Docker-Content-Digest` header with the index media types in `Accept` — omit them and the registry silently converts the response down to a single platform and returns that digest instead. `scripts/resolve-digests.sh` does it that way; all three pins were checked to carry both `linux/amd64` and `linux/arm64` before being written down.
- [x] **"Loki is up" and "Loki is ready" are different questions, and the gap is not a fixed number of seconds.** Writing the health section of `operations.md` meant running its own commands, and `curl -sf localhost:3100/ready` returned **503 for several minutes** after a full `demo-up` — while Tempo, restarted seconds apart, was already serving, and while Loki itself was happily answering `/loki/api/v1/labels` and `/metrics` throughout. A plain `docker restart` of the same container then reached ready in **35s**. So the delay is not a constant to document; the ring has to settle, and how long that takes depends on what is in the volume. Every readiness instruction in the docs is now a poll loop rather than a `sleep`, which is what the scripts in `scripts/` already did. The near-miss is that the doc would otherwise have shipped saying "give it ninety seconds", and the reader whose stack took four minutes would have gone looking for a fault that was not there.
- [x] **A comment referenced a Make target that does not exist.** `compose.edge.yml` told the reader to run `make edge-up`; the Makefile has never had that target — the real invocation is `make demo-up EDGE=1`. Nothing failed, because nothing executes a comment. Found only by reading the file end to end while writing `local-dev.md`, which is an argument for writing the docs from the configs rather than from memory.
- [x] **`docker buildx imagetools inspect` is not usable unattended on macOS.** It authenticates through the Docker credential helper, which needs an unlocked login keychain and fails with `error getting credentials` in any non-interactive session — so the tool the plan assumed for this job cannot run in CI or over ssh. Anonymous registry calls work everywhere and need no credentials at all.
