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

- [ ] `server/grafana/provisioning/datasources/datasources.yaml` — fixed UIDs `prometheus`/`loki`/`tempo`; `exemplarTraceIdDestinations`; Loki `derivedFields` (`matcherType: label`, `matcherRegex: trace_id`); `tracesToLogsV2` + `tracesToMetrics` with `tags: [{key: app},{key: service},{key: env}]`; `serviceMap`, `nodeGraph`
- [ ] Remember `$$` escaping for `$__tags` / `${__value.raw}` (Grafana's provisioning loader interpolates `$VAR`)
- [ ] `server/grafana/provisioning/dashboards/provider.yaml` — file provider, `foldersFromFilesStructure: true`, `updateIntervalSeconds: 30`, `allowUiUpdates: false`
- [ ] Three placeholder dashboard JSONs in `Applications/`, `Databases/`, `Infrastructure/`

**Verify**:
```bash
curl -su admin:$PW localhost:3000/api/datasources | jq -r '.[].uid'   # → prometheus loki tempo
curl -su admin:$PW localhost:3000/api/search | jq -r '.[].folderTitle'  # → 3 folders
```

---

## M3 — `obskit` SDK + demo app

- [ ] `sdk/obskit/pyproject.toml` — base deps + `[grpc]` / `[http]` / `[sqlalchemy]` / `[errors]` extras
- [ ] `settings.py` — `ObservabilitySettings(BaseSettings)`, `env_prefix="OBS_"`, `ObservabilityConfigError` raised on missing `app`
- [ ] `logging.py` — structlog config; `_add_otel_context` injecting `032x`/`016x` hex; JSON vs Console by env; stdlib routed through `ProcessorFormatter`; **`foreign_pre_chain` must exclude `filter_by_level`**; `cache_logger_on_first_use=True`; noise suppression for `sqlalchemy.engine`, `uvicorn.access`, `watchfiles`
- [ ] `metrics.py` — instance-local `CollectorRegistry`; `fastapi_requests_total` / `fastapi_responses_total` / `fastapi_requests_duration_seconds` / `fastapi_exceptions_total` / `fastapi_requests_in_progress` / `fastapi_app_info`; `disable_created_metrics()`; OpenMetrics exposition (`prometheus_client.openmetrics.exposition`)
- [ ] `middleware.py` — `PrometheusMiddleware` (matched-route path via `route.matches(scope) == Match.FULL`, exemplars, `status_code="500"` default) and `RequestLoggingMiddleware` (event `"HTTP"`, level by status class, `clear_contextvars` at start)
- [ ] `tracing.py` — TracerProvider, resource attrs (`app`/`service`/`env`/`host` + `service.name` + `deployment.environment.name`), FastAPI + optional SQLAlchemy instrumentors, degrade to no-op tracer on exporter failure
- [ ] `errors.py` — `sentry_sdk.init(dsn, enable_tracing=False, shutdown_timeout=10)`
- [ ] `runtime.py` — `setup_observability`, `setup_worker_observability`, `Observability` dataclass with `shutdown()`
- [ ] `__init__.py` (four public names + `bind_request_context`), `py.typed`
- [ ] Tests — settings validation, logging JSON shape incl. `trace_id`, metrics registry isolation across two setups, setup wiring
- [ ] `sdk/obskit/README.md` — usage example (the only place docs live)
- [ ] `demo/app` — FastAPI with `/ok`, `/slow`, `/boom`, `/db`; Dockerfile on `python:3.13-slim` + `uv`, installing `obskit` from local path
- [ ] `demo/loadgen` — async loop with a fixed error/slow mix

**Verify**:
```bash
cd sdk/obskit && uv run pytest && uv run mypy src
curl -s localhost:8000/metrics | grep fastapi_requests_total
docker logs demo-api | tail -1 | jq .trace_id   # non-null after hitting a route
```

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
- [ ] `compose.demo.yml` — demo app + db + agent wired against the server stack
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
- [ ] `docs/operations.md` — retention/disk, backup/restore, cardinality watch, **do-not-re-enable Tempo `local-blocks`**, pinned digests, out-of-scope list
- [ ] Pin resolved digests for `traefik`, `glitchtip`, `valkey`
- [ ] Deploy to the VPS; onboard the first real app; tag `v0.1.0`

**Verify**: `curl -vI https://grafana.<domain>` shows a Let's Encrypt chain. The onboarded app's repo diff is exactly: copy `agent/`, add `obs.*` labels, `uv add obskit`, one `setup_observability(app, engine=engine)` call.
