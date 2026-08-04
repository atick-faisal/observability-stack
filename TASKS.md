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

- [ ] `tracesToMetrics` latency query — ships at M5. `traces_spanmetrics_calls_total` is stable, but Tempo has used more than one name for the latency histogram; the query gets written from Prometheus' actual series list rather than from memory.

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

## M3a — `obskit` SDK

*Split out of the original M3 so the SDK is reviewable before the demo app depends on it.*

- [x] `sdk/obskit/pyproject.toml` — base deps + `[grpc]` / `[http]` / `[sqlalchemy]` / `[errors]` extras — *`fastapi` had to be named explicitly: `opentelemetry-instrumentation-fastapi` depends only on `opentelemetry-instrumentation-asgi`*
- [x] `settings.py` — `ObservabilitySettings(BaseSettings)`, `env_prefix="OBS_"`, `ObservabilityConfigError` raised on missing `app` (via `.load()`), plus `[a-z0-9-]+` enforcement on `app`/`service` so a malformed identity fails at startup rather than at query time
- [x] `logging.py` — structlog config; `_add_otel_context` injecting `032x`/`016x` hex; JSON vs Console by env; stdlib routed through `ProcessorFormatter`; **`foreign_pre_chain` must exclude `filter_by_level`**; `cache_logger_on_first_use=True`; noise suppression for `sqlalchemy.engine`, `uvicorn.access`, `watchfiles`
- [x] `metrics.py` — instance-local `CollectorRegistry`; `fastapi_requests_total` / `fastapi_requests_duration_seconds` / `fastapi_exceptions_total` / `fastapi_requests_in_progress` / `fastapi_app_info`; `disable_created_metrics()`; OpenMetrics exposition (`prometheus_client.openmetrics.exposition`)
- [x] `middleware.py` — `PrometheusMiddleware` (matched-route pattern, exemplars, `status_code="500"` default) and `RequestLoggingMiddleware` (event `"HTTP"`, level by status class, `clear_contextvars` at start)
- [x] `tracing.py` — TracerProvider, resource attrs (`app`/`service`/`env`/`host` + `service.name` + `deployment.environment.name`), FastAPI + optional SQLAlchemy instrumentors (an `AsyncEngine` is unwrapped to its `sync_engine`), degrade to no tracing on exporter failure
- [x] `errors.py` — `sentry_sdk.init(dsn, enable_tracing=False, shutdown_timeout=10)`, plus `environment` and `release` so GlitchTip can group by them
- [x] `runtime.py` — `setup_observability`, `setup_worker_observability`, `Observability` dataclass with `shutdown()`
- [x] `__init__.py` (four public names + `bind_request_context` + `ObservabilityConfigError`), `py.typed`
- [x] Tests — 37, covering settings validation, logging JSON shape incl. `trace_id`, metrics registry isolation across two setups, setup wiring, and the trace↔log↔exemplar correlation
- [x] `sdk/obskit/README.md` — usage example (the only place docs live)

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

- [x] `demo/app` — FastAPI with `/ok`, `/items/{item_id}`, `/slow`, `/boom`, `/db`, and `/health` passed to `excluded_paths`; Dockerfile on `python:3.13-slim` + `uv`, non-root, installing `obskit` from the local path
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

- [ ] `agent/config.alloy`
  - [ ] `discovery.docker` + `discovery.relabel "metrics_targets"` (label-driven, `keepequal` port match)
  - [ ] `discovery.relabel "log_targets"` (drop on `obs.logs="false"`, derive `container`/`service`)
  - [ ] `loki.source.docker` + `loki.process` with **`stage.match`-guarded** `stage.json` (plain-text containers must pass through untouched)
  - [ ] `prometheus.exporter.unix` with stable `instance` relabel
  - [ ] `otelcol.receiver.otlp` (gRPC 4317, HTTP 4318) → `batch` → `attributes` (upsert `host`) → `otelcol.exporter.otlphttp`
  - [ ] Exits: `prometheus.remote_write` (external_labels, `send_exemplars`, queue_config, WAL), `loki.write`
  - [ ] `OBS_EXTRA_TARGET` empty-env-var escape hatch
- [ ] `agent/compose.agent.yml` — `alloy` always; `cadvisor` profile `containers` (Linux-native: no `privileged`, no containerd flag, `devices: [/dev/kmsg]`); `postgres_exporter` profile `postgres` with env-driven `DATA_SOURCE_URI` and the PG17+ collector flags incl. `--collector.stat_checkpointer`
- [ ] `agent/compose.agent.macos.yml` — containerd override for local testing only
- [ ] `agent/postgres-exporter-init.sql` — `postgres_exporter` role, `pg_monitor` grant, search_path
- [ ] `agent/.env.agent.example`, `agent/README.md`
- [ ] Extend `compose.demo.yml` (shipped at M3b) with the agent, and re-point `OBS_OTLP_ENDPOINT` from `tempo:4317` to `alloy:4317` — that one variable is the whole of what the agent changes for an app
- [ ] `scripts/verify-signals.sh` (steps 1–5, exit codes)

**Verify**: Alloy UI `localhost:12345/graph` shows every component healthy; targets appear with zero static addresses in the config; `verify-signals.sh` steps 1–3 pass.

---

## M5 — Cross-signal correlation

- [ ] Confirm Tempo 2.10.5 span-metrics picks up `app`/`service`/`env` from **resource** attributes; if not, add `otelcol.processor.transform` in the agent copying them onto spans
- [ ] Confirm exemplars survive the Alloy → Prometheus hop (OpenMetrics content-type negotiation)

**Verify**: `verify-signals.sh` steps 4–5 pass. Manual round trip in Grafana: latency panel exemplar → Tempo trace → linked log line → back to the trace.

---

## M6 — Traefik + ingest auth

- [ ] `server/traefik/traefik.yml` — entrypoints, LE HTTP-01 resolver, file + docker providers (`exposedByDefault: false`), JSON access log
- [ ] `server/traefik/dynamic/middlewares.yml` — `ingest-auth` (basicAuth `usersFile`, `removeHeader: true`), `ingest-ratelimit`, `secure-headers`
- [ ] Router labels: `grafana.<domain>`; `ingest.<domain>` × 3 native paths → prometheus / loki / tempo
- [ ] Remove host port bindings from prometheus/loki/tempo (keep `127.0.0.1` for on-box debugging)
- [ ] `scripts/add-ingest-user.sh` (`htpasswd -nbB`, appends, chmod 0600)
- [ ] `scripts/verify-ingest.sh`
- [ ] Switch the demo agent to HTTPS + credentials

**Verify**:
```bash
curl -o /dev/null -w '%{http_code}\n' -u u:p https://ingest.localhost/api/v1/write -d ''   # 400 = auth passed
curl -o /dev/null -w '%{http_code}\n'        https://ingest.localhost/api/v1/write -d ''   # 401
curl -o /dev/null -w '%{http_code}\n'        https://ingest.localhost/graph                # 404
```
Then re-run `verify-signals.sh` — all five steps still pass over HTTPS.

---

## M7 — Dashboards

- [ ] `Applications/fastapi-service.json` — RED, p50/p95/p99 with exemplars, in-progress, top routes by rate and p99, exception types, status-code breakdown, embedded Loki panel, service graph
- [ ] `Databases/postgresql.json` — `pg_up`, connections vs max, commit/rollback, cache hit ratio, deadlocks, longest transaction, replication lag, DB size, `pg_stat_checkpointer_*`, autovacuum
- [ ] `Infrastructure/host-and-containers.json` — node CPU/mem/disk/fs/net/load; per-container CPU/RSS/net/restarts
- [ ] All three: classic v1 JSON `schemaVersion: 41`, chained `$app`/`$env`/`$service` variables, fixed datasource UIDs, `editable: false`
- [ ] `scripts/verify-dashboards.sh`

**Verify**: `scripts/verify-dashboards.sh` — every panel `expr` returns a non-empty result for `$app=demo`.

---

## M8 — GlitchTip

- [ ] `compose.glitchtip.yml` — web / worker / migrate + own `postgres:16-alpine` + `valkey`
- [ ] `.env.glitchtip.example` (separate from the server env — no shared file)
- [ ] Traefik router `errors.<domain>`

**Verify**: create a project in the UI, set `OBS_ERROR_DSN` on the demo app, hit `/boom`, confirm the event appears via the GlitchTip API.

---

## M9 — Resilience

- [ ] Enable Alloy `loki.write` WAL + `--stability.level=experimental`
- [ ] `scripts/backup.sh` / `scripts/restore.sh` — Grafana volume (`grafana.db` is the only irreplaceable state) plus the TSDB volumes

**Verify**: stop the server stack for 15 minutes with `loadgen` running, restart it. Assert **no gap** in `fastapi_requests_total` over the outage window (validates `out_of_order_time_window`) and that logs backfilled. Then run `restore.sh` against a fresh volume set once.

---

## M10 — Ship

- [ ] `docs/deploy-vps.md` — provisioning, DNS, first `up`, clock-sync check
- [ ] `docs/onboarding-an-app.md` — the four-step diff, incl. the `EXPOSE`/`expose:` requirement for label-driven scraping
- [ ] `docs/local-dev.md` — demo stack, Mac caveats
- [ ] `docs/operations.md` — retention/disk, backup/restore, cardinality watch, **do-not-re-enable Tempo `local-blocks`**, pinned digests, out-of-scope list, and the `$`-in-password trap: Compose collapses `$$` → `$` when reading `--env-file`, so a `$` in `GF_ADMIN_PASSWORD` reaches Grafana as something other than what the file shows (measured: `PW=ab$$cd` arrives as `ab$cd`)
- [ ] Pin resolved digests for `traefik`, `glitchtip`, `valkey`
- [ ] Deploy to the VPS; onboard the first real app; tag `v0.1.0`

**Verify**: `curl -vI https://grafana.<domain>` shows a Let's Encrypt chain. The onboarded app's repo diff is exactly: copy `agent/`, add `obs.*` labels, `uv add obskit`, one `setup_observability(app, engine=engine)` call.
