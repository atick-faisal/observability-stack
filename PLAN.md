# Decoupled Observability Stack — Design

> Implementation checklist lives in [`TASKS.md`](./TASKS.md). This document is the *why*; that one is the *what next*.

## Context

`ai-asset-management/observability/` contains a working Grafana LGTM stack, but it is welded to that one app: it joins the app's Compose network by name, hardcodes scrape targets (`backend:8000`, `db:5432`), bakes app-specific label values into dashboards (`{service="backend"}`, `imgworker_*`), and shares one `.env` between LGTM and GlitchTip. It also carries WSL2/Docker-Desktop and corporate-proxy artifacts that don't belong on a Linux VPS.

This repo is a fresh, application-independent replacement. One deployment on a VPS serves every future project. Onboarding a new FastAPI+Postgres app should be: copy an agent directory, add a few Docker labels, `uv add obskit`, one function call.

**Architecture** — two independently deployable halves:

- **Server (VPS)**: Traefik fronts Grafana and GlitchTip on public subdomains, plus a single `ingest.<domain>` host exposing three authenticated paths that proxy to Prometheus remote-write, Loki push, and Tempo OTLP/HTTP. Nothing else is reachable from outside.
- **Agent (every app host)**: one Alloy container that discovers scrape targets and log streams *from Docker labels*, runs optional cAdvisor / postgres_exporter via Compose profiles, receives OTLP traces from the local app, and pushes everything to `ingest.<domain>` over HTTPS with basic auth and local buffering. The app exposes nothing publicly.

```
APP HOST                              OBSERVABILITY VPS
┌──────────────────────┐              ┌────────────────────┐
│ fastapi  ──/metrics─┐│              │ Traefik (TLS+auth) │
│ postgres ──exporter─┤│    HTTPS     │   │                │
│ cadvisor ───────────┼┼─────────────▶│   ├─▶ Loki         │
│ docker logs ────────┤│    (push)    │   ├─▶ Prometheus   │
│ host /proc /sys ────┤│              │   └─▶ Tempo        │
│         alloy ──────┘│              │        Grafana     │
└──────────────────────┘              └────────────────────┘
```

**Decisions**: Alloy agent per app host (not direct OTLP, not remote scraping) · Prometheus v3 remote-write receiver (not Mimir) · ship an `obskit` Python SDK · Traefik + Let's Encrypt · dashboards for FastAPI / PostgreSQL / host+containers · 30d metrics, 14d logs, 7d traces · GlitchTip in its own compose file.

---

## 1. Label taxonomy — the load-bearing decision

Four identity labels, spelled **identically** in every signal, flat, no dots:

| Label | Meaning | Cardinality | Example |
|---|---|---|---|
| `app` | Deployment unit — one value per app repo | ~10s | `asset-management` |
| `service` | Process role inside the app | ~5 per app | `api`, `worker`, `db` |
| `env` | `production` \| `staging` \| `local` | 3 | `production` |
| `host` | Machine the agent runs on | ~10s | `app-vps-01` |

Everything else is a *dimension*, not identity: `job`, `instance`, `container`, `level`, `method`, `status_code`, `route`.

Injected at exactly one choke point per signal:

- **Prometheus** — `app`/`env`/`host` as `external_labels` on the agent's `prometheus.remote_write`; they land on every series (app, node, cAdvisor, postgres). `service` comes from discovery relabels. `instance` pinned to a stable value so dashboard variables survive restarts.
- **Loki** — stream labels are exactly `app, env, host, service, container, level`. Six, all bounded. `trace_id`/`span_id` go to **structured metadata**, never labels. Everything else stays in the JSON body, queried with `| json`.
- **Tempo/OTel** — SDK sets resource attributes `app`, `service`, `env`, `host` with those flat names, *plus* `service.name = "{app}-{service}"` and `deployment.environment.name` for semconv/service-graph compatibility, and opts into stable HTTP semconv (`OTEL_SEMCONV_STABILITY_OPT_IN=http`) so spans carry `http.response.status_code` rather than the pre-1.0 `http.status_code`. Tempo span-metrics `dimensions: [app, service, env, http.route, http.response.status_code]`, reconciled with the taxonomy by `write_relabel_configs` on the generator's remote-write (see `docs/labels.md` §3.4).

**Why this shape**: Grafana's `tracesToLogsV2` / `tracesToMetrics` map span tags to target-datasource labels *by name*. Matching names means the mapping is `tags: [{key: app},{key: service},{key: env}]` with no per-app renaming — that is what makes dashboards and correlation links app-independent.

Hard rules, documented in `docs/labels.md`:
- Never a label: `trace_id`, `span_id`, `user_id`, `request_id`, raw URL path, SQL text.
- HTTP path in metrics is always the **matched route pattern**, never `request.url.path`.
- `app` never appears in a *metric name*. Names stay generic (`fastapi_requests_total`); identity lives in labels. This is the biggest fix versus the reference.

---

## 2. Repo layout

```
observability-stack/
├─ PLAN.md  TASKS.md  README.md  Makefile  .gitignore
├─ compose.yml                     # server, as deployed: build:, traefik labels, no ports
├─ compose.local.yml               # local: 127.0.0.1 ports + bind-mounted config
├─ compose.edge.yml                # opt-in traefik, for a host with no proxy already
├─ compose.glitchtip.yml           # server: glitchtip web/worker/migrate + own pg + valkey
├─ compose.demo.yml                # local e2e: demo app + pg + agent
├─ compose.demo.edge.yml           # local e2e: agent pushes through the edge instead
├─ .env.server.example  .env.glitchtip.example
├─ server/
│  ├─ prometheus/{Dockerfile,prometheus.yml}
│  ├─ loki/{Dockerfile,loki-config.yaml}
│  ├─ tempo/{Dockerfile,tempo-config.yaml}
│  └─ grafana/Dockerfile
│     grafana/provisioning/{datasources,dashboards,alerting}/
│     grafana/dashboards/{Applications,Databases,Infrastructure}/*.json
├─ agent/                          # ← copied verbatim into any app repo
│  ├─ compose.agent.yml  config.alloy  .env.agent.example
│  ├─ postgres-exporter-init.sql  README.md
├─ sdk/obskit/
│  ├─ pyproject.toml  README.md
│  └─ src/obskit/{__init__,settings,logging,tracing,metrics,middleware,errors,runtime}.py + py.typed
│     tests/
├─ demo/app/  demo/loadgen/
├─ scripts/  add-ingest-user.sh verify-ingest.sh verify-signals.sh verify-dashboards.sh backup.sh
└─ docs/  labels.md onboarding-an-app.md deploy-vps.md local-dev.md operations.md
```

---

## 3. The agent — one `.alloy` file, never edited

Identity and destination come from env vars; **targets come from Docker labels**. No app-specific string appears in the file.

App opt-in convention:

```yaml
services:
  api:
    labels:
      obs.service: api
      obs.metrics.port: "8000"    # presence = scrape me
      obs.metrics.path: /metrics
  db:
    labels: { obs.service: db }   # logs only
  migrations:
    labels: { obs.logs: "false" }
```

Discovery, no static addresses:

```alloy
discovery.relabel "metrics_targets" {
  targets = discovery.docker.containers.targets
  rule { source_labels = ["__meta_docker_container_label_obs_metrics_port"]
         regex = "" action = "drop" }
  rule { source_labels = ["__meta_docker_port_private"]
         target_label  = "__meta_docker_container_label_obs_metrics_port"
         action        = "keepequal" }
  rule { source_labels = ["__meta_docker_network_ip", "__meta_docker_container_label_obs_metrics_port"]
         separator = ":" target_label = "__address__" }
  rule { source_labels = ["__meta_docker_container_label_obs_service"]
         target_label = "service" }
}
```

The port label is `__meta_docker_port_private`, **not** the `__meta_docker_port_private_port` that
Prometheus' own `docker_sd` documents — Alloy names it differently, and getting it wrong drops
every target with no error anywhere. Discovery emits one target per (network × exposed TCP port),
so `keepequal` is what picks the right one, and `OBS_DOCKER_NETWORK` collapses the multi-network
case where the same series would otherwise be scraped twice.

The scrape sets **`honor_labels = true`**. The SDK already stamps `app`/`service`/`env` on the
app's own series; without it, the `service` relabelled onto the target collides and Prometheus
renames one of them `exported_service`.

The **empty-env-var idiom** handles genuinely optional static targets (Alloy has no conditionals) — unset var → empty address → dropped → job is a no-op:

```alloy
discovery.relabel "extra" {
  targets = [{ __address__ = sys.env("OBS_EXTRA_TARGET"), service = sys.env("OBS_EXTRA_SERVICE") }]
  rule { source_labels = ["__address__"] regex = "" action = "drop" }
}
```

Identity injected once, at the exit:

```alloy
prometheus.remote_write "obs" {
  external_labels = { app = sys.env("OBS_APP"), env = sys.env("OBS_ENV"), host = sys.env("OBS_HOST") }
  endpoint {
    url = sys.env("OBS_PROM_URL")
    basic_auth { username = sys.env("OBS_INGEST_USER")  password = sys.env("OBS_INGEST_PASSWORD") }
    send_exemplars = true
    queue_config { capacity = 10000  max_shards = 10  min_backoff = "1s"  max_backoff = "5m" }
  }
  wal { truncate_frequency = "2h"  max_keepalive_time = "8h" }
}
```

**Log parsing must be conditional** — the reference applied `stage.json` unconditionally, which mangles Postgres/Traefik plain-text logs. Wrap it in `stage.match { selector = "{container=~\".+\"} |~ \"^\\\\s*\\\\{\"" }` so non-JSON lines fall through. The selector matches on `container`, not `app`: `app` is added by `loki.write`'s `external_labels`, which run *after* this stage. LogQL rejects backtick raw strings here, so the regex is unescaped twice — once by Alloy, once by LogQL.

**Traces**: `otelcol.receiver.otlp` (gRPC 4317 + HTTP 4318) → `batch` → `otelcol.exporter.otlphttp` with `otelcol.auth.basic`. The agent does **not** rewrite `host` on spans: `otelcol.processor.attributes` only reaches span attributes and `host` is a *resource* attribute, so it would take an `otelcol.processor.transform` with an OTTL statement string-concatenated from `sys.env`. The app's own value is used instead — see `docs/labels.md` §5 for what that costs.

`compose.agent.yml`: `alloy` always; `cadvisor` under profile `containers`; `postgres_exporter` under profile `postgres`, its `DATA_SOURCE_*` variables read from `.env.agent` inside the container rather than interpolated by Compose (no hardcoded `db`, and no `$`-escaping in passwords). Both optional services carry their own `obs.*` labels and are discovered by the same mechanism as any app container. Host metrics via Alloy's built-in `prometheus.exporter.unix` — no node_exporter container. Recommended wiring is `docker compose -f compose.yml -f observability/compose.agent.yml up`, so the agent shares the app's project network natively and the reference's `external:` network hack disappears.

Carry over verbatim from the reference (correct and hard-won): postgres_exporter's `--collector.stat_checkpointer` (required for PG17+/18, where checkpoint metrics moved out of `pg_stat_bgwriter`) and its sibling collector flags; cAdvisor's `--disable_metrics=advtcp,cpu_topology,...` list and the `id` labeldrop.

---

## 4. Ingress and auth

Traefik static config: `web` (:80 → redirect) and `websecure` (:443), docker provider with `exposedByDefault: false`, LE HTTP-01 resolver. It lives in `compose.edge.yml` as CLI arguments rather than a `traefik.yml` — Traefik's three static-config sources (file, CLI, env) are **mutually exclusive**, and only the CLI form lets Compose interpolate `ACME_EMAIL` out of `.env.server`.

**Routing is container labels in `compose.yml`, not a file provider.** Labels are inert without a Traefik reading them, and Traefik ignores anything not on its own network, so one copy of them serves both our own edge and one that already exists on the host. `OBS_EDGE_NETWORK` / `OBS_EDGE_EXTERNAL` point the `edge` network at whatever proxy is already there — on a Dokploy host, `dokploy-network`. Compose's `include:` is strictly additive and rejects a file redeclaring anything it imported, so two variables do what an overlay file cannot.

**Second stated limitation, from that**: on a shared edge network, anything else attached to it reaches the ingest backends directly, bypassing the basic auth below. `obs` stays a separate private network so only the four services and the demo are on it, but the edge network is as trusted as the host. Single-owner box, same boundary as the limitation stated further down.

| Host / path | Backend | Middlewares |
|---|---|---|
| `grafana.<domain>` | grafana:3000 | secure-headers |
| `errors.<domain>` | glitchtip-web:8000 | secure-headers |
| `ingest.<domain>` + `PathPrefix(/api/v1/write)` | prometheus:9090 | ingest-auth, ratelimit |
| `ingest.<domain>` + `PathPrefix(/loki/api/v1/push)` | loki:3100 | ingest-auth, ratelimit |
| `ingest.<domain>` + `PathPrefix(/v1/traces)` | tempo:4318 | ingest-auth, ratelimit |

Paths are the **native upstream paths**, no rewriting — swapping Prometheus for Mimir later is just a change of the router's service. Anything else on `ingest.<domain>` matches no router → 404. **Nothing publishes a host port**; `compose.local.yml` adds `127.0.0.1` bindings for local work only, so on the VPS the authenticated path is the only path.

Credentials: **one per app+env**, basic auth, defined as a label.

```yaml
traefik.http.middlewares.obs-ingest-auth.basicauth.users: ${INGEST_USERS}
traefik.http.middlewares.obs-ingest-auth.basicauth.removeheader: "true"
```

This was originally specified as `usersFile`, to avoid `$`-doubling bcrypt hashes: Compose interpolates values it reads from `--env-file`, so a hash has to be written with `$$`. That reasoning no longer survives, because `usersFile` needs a path readable inside **Traefik's** container, and where the proxy is not ours we do not control its mounts. So the doubling is handled where it can be tested instead: `scripts/add-ingest-user.sh <app>-<env>` runs `htpasswd -nbB` and prints the line already doubled, and `scripts/verify-ingest.sh` asserts a correct credential returns 400 and a wrong one 401 — the failure this trades against is a 401 indistinguishable from a wrong password.

Per-app credentials mean you can rotate one app in isolation, and the username appears in Traefik access logs for volume attribution.

**Stated limitation**: basic auth authenticates the sender but does not enforce that its `app` label matches its credential. Acceptable for a single-owner fleet. Upgrade path when it isn't: a per-credential Traefik `headers` middleware injecting `X-Scope-OrgID`, plus `auth_enabled: true` on Loki and Prometheus → Mimir. This is exactly the swap the URL-level design preserves.

**Agent → VPS is OTLP/HTTP, not gRPC**, because gRPC through Traefik needs h2c passthrough and end-to-end HTTP/2 — materially more fragile than an HTTP/1.1 POST with basic auth. **App → local Alloy is gRPC (4317)**: same-host, no TLS, and decisively `grpcio` ignores `http_proxy`/`https_proxy` while the HTTP exporter honours them (the reference environment sets a global corporate proxy that would silently swallow local OTLP).

---

## 5. `obskit` SDK

Four public names:

```python
def setup_observability(
    app: FastAPI, *,
    settings: ObservabilitySettings | None = None,
    engine: Engine | AsyncEngine | None = None,
    excluded_paths: Collection[str] = (),
) -> Observability: ...

def setup_worker_observability(*, settings=None, metrics_port: int | None = None) -> Observability: ...

@dataclass(frozen=True, slots=True)
class Observability:
    settings: ObservabilitySettings
    registry: CollectorRegistry
    tracer_provider: TracerProvider | None
    def shutdown(self, timeout_s: float = 5.0) -> None: ...

class ObservabilitySettings(BaseSettings):   # env_prefix="OBS_"
    app: str
    service: str = "api"
    env: Literal["local", "staging", "production"] = "local"
    host: str = Field(default_factory=socket.gethostname)
    version: str = "0.0.0"
    log_level: str = "INFO"
    log_format: Literal["auto", "json", "console"] = "auto"
    otlp_endpoint: str | None = None            # http://alloy:4317
    otlp_protocol: Literal["grpc", "http"] = "grpc"
    trace_sample_ratio: float = 1.0
    metrics_enabled: bool = True
    metrics_path: str = "/metrics"
    error_dsn: str | None = None
```

**Port verbatim from the reference — this logic is correct**:

- Metric names `fastapi_requests_total` / `fastapi_requests_duration_seconds` / `fastapi_exceptions_total` / `fastapi_requests_in_progress` / `fastapi_app_info`; `disable_created_metrics()`; matched-route-pattern path; `status_code = "500"` default before dispatch; exemplars via `.inc(exemplar=…)` / `.observe(…, exemplar=…)` served through the **OpenMetrics** renderer (`prometheus_client.openmetrics.exposition.generate_latest` + its `CONTENT_TYPE_LATEST`) — without that content type exemplars are silently dropped.
  → source: `ai-asset-management/backend/app/middleware/metrics.py`
  **`fastapi_responses_total` is dropped.** The reference increments it in the same `finally` block, with the same labels, as `fastapi_requests_total` — a byte-identical duplicate series for zero extra information. (Dashboard 16110 intended `requests_total` to be counted *before* dispatch, without `status_code`; the reference counts both after.) We author every dashboard ourselves, so 16110 compatibility buys nothing.
- structlog: `_add_otel_context` injecting `032x`/`016x` hex trace/span IDs, `merge_contextvars`, `ExceptionRenderer`, `cache_logger_on_first_use=True`, stdlib loggers routed through `ProcessorFormatter`, and critically **`foreign_pre_chain` must exclude `filter_by_level`** (ProcessorFormatter passes `logger=None` → `AttributeError`).
  → source: `ai-asset-management/backend/app/observability/logging.py`
  **Configuring the root logger is not enough.** uvicorn and gunicorn install handlers directly on their own loggers with `propagate=False`, so the reference's setup never reaches them: startup lines and the whole `"Exception in ASGI application"` traceback stay plain text, and one traceback becomes one Loki line per frame. `obskit` clears those handlers and re-enables propagation.
- `sentry_sdk.init(dsn, enable_tracing=False, shutdown_timeout=10)` — OTel owns tracing.

**One uvicorn worker per container.** The reference's image ends `CMD ["fastapi", "run", "--workers", "4", …]`. Four processes share one listening socket and each holds its own registry, so consecutive scrapes answer from different workers, a counter appears to move backwards, and Prometheus reads every decrease as a reset — `rate()` returns numbers that are simply wrong, with nothing logged anywhere. The instance-local registry does not help: the problem is one endpoint backed by N processes. Scale by container, or adopt `PROMETHEUS_MULTIPROC_DIR`. Documented in the SDK README.

**Change from the reference**:

- Every metric carries `app`/`service`/`env` from settings, not a module-level constant; `fastapi_app_info` carries `app/service/env/version`. Not `host` — the agent is authoritative there (§1, and `docs/labels.md` §3.1).
- The route label is named `route`, not `path`, matching the dimension name in `docs/labels.md` §2.
- Metrics register on an **instance-local `CollectorRegistry`**, not global `REGISTRY` — kills duplicate-timeseries failures on re-import and in tests.
- **Pure-ASGI middleware, not `BaseHTTPMiddleware`.** Same logic, without the per-request anyio task, the latency tax, and BaseHTTPMiddleware's breakage of `StreamingResponse` backpressure and `BackgroundTasks` timing. Status comes from wrapping `send` and reading `http.response.start`; the route pattern comes from `scope["route"]`, which the router has already computed, with the `app.routes` walk as fallback.
- The scrape endpoint is excluded from tracing (`excluded_urls`) as well as from metrics, and the ASGI `"http send"`/`"http receive"` child spans are suppressed (`exclude_spans`) — together they are ~3 spans per request plus one trace per scrape, describing nothing.
- `excluded_paths` is a parameter, not a hardcoded app-specific frozenset.
- No JWT/user-email extraction in the logging middleware (that was app coupling). Export `bind_request_context(**fields)` so apps add their own contextvars.
- Explicit failure modes: missing or malformed `OBS_APP` raises `ObservabilityConfigError` at startup (fail fast on programmer error); OTLP exporter construction failure logs at `error` and continues without tracing (degrade on infra error).
- No docstrings/comments; usage lives in the SDK README.

Deps: base `fastapi`, `structlog`, `prometheus-client`, `opentelemetry-sdk`, `opentelemetry-instrumentation-fastapi`, `pydantic-settings`. Extras `[grpc]`, `[http]`, `[sqlalchemy]`, `[errors]`. (`opentelemetry-instrumentation-fastapi` depends only on `opentelemetry-instrumentation-asgi`, so `fastapi` has to be named explicitly.)
Install: `uv add "obskit[grpc,sqlalchemy] @ git+https://github.com/<you>/observability-stack@v0.1.0#subdirectory=sdk/obskit"`.

**Logs stay stdout-JSON + Alloy Docker tailing — not OTLP push.** Reasons in order: it captures *every* container including Postgres, Traefik and crashed processes (exactly what you want mid-incident); a hard crash loses an in-process OTLP buffer whereas the line is already durable in Docker's json-file driver; Alloy stays the single choke point applying the label taxonomy. OTLP logs are documented as the escape hatch for non-Docker deployments.

---

## 6. Dashboards

**Classic v1 JSON, `schemaVersion: 41`, for all three** — the reference mixed v1 with the still-moving `dashboard.grafana.app/v2` resource format; normalize to v1, which is what grafana.com exports and what file provisioning handles best.

**Author all three ourselves; vendor nothing in v1.** Community dashboards (16110, 9628, node-exporter-full) bake in `$job`/`$instance` assumptions and dozens of panels that ignore `$app`. We reuse their *metric families* — that is why the SDK keeps the 16110 names — but not their labels: `app_name` and `path` become `app` and `route`, and `fastapi_responses_total` does not exist here at all. Panels are hand-picked, 10–14 each.

Chained variables, on every dashboard that has something to chain:

```
$app     = label_values(fastapi_app_info, app)
$env     = label_values(fastapi_app_info{app="$app"}, env)
$service = label_values(fastapi_app_info{app="$app",env="$env"}, service)   # multi, includeAll
```

`$app` and `$env` are universal — the agent stamps them onto everything it forwards. **`$service` is not.** It identifies the workload that emitted a series, and only the app's own instrumentation has one worth selecting on: cAdvisor labels every container metric `service=cadvisor` regardless of what it is observing, and node-exporter series carry no `service` at all. So Applications chains all three; Databases substitutes `$datname`; Infrastructure substitutes `$host` and `$container`, and identifies a container by its `name` label. Applying `$service` to those would filter every panel down to nothing.

Datasources are the fixed UIDs `prometheus`/`loki`/`tempo` — we own provisioning, so a `$datasource` variable is pure friction. `exemplar: true` on latency-histogram targets so click-through to Tempo works.

**Every panel's query is a test.** `scripts/verify-dashboards.sh` substitutes the demo's values for the variables and asserts each expression returns something, because an empty result renders identically to a quiet period and these dashboards cannot be repaired in the browser. It also asserts the file shape — `schemaVersion`, `editable`, unique uids, no datasource outside the three — and asks Grafana which dashboards it actually provisioned and into which folder, which is the only check that can see a file provisioning rejected.

1. `Applications/fastapi-service.json` — RED (rate, error %, p50/p95/p99 from `fastapi_requests_duration_seconds_bucket` with exemplars), in-progress gauge, top routes by rate and by p99, exception types, status-code breakdown, embedded Loki panel `{app="$app",env="$env",service=~"$service"} | json`, service graph from `traces_spanmetrics_*`.
2. `Databases/postgresql.json` — `pg_up`, connections vs `max_connections`, commit/rollback rate, cache-hit ratio, deadlocks, longest transaction, replication lag, DB size, `pg_stat_checkpointer_*` (PG17+ series names), autovacuum, and the database's own logs.
3. `Infrastructure/host-and-containers.json` — `$host` from `label_values(node_uname_info, host)`; node CPU/mem/disk/fs/network/load; per-container CPU/RSS/net/restarts from cAdvisor filtered by `$app` and `$container`. Restarts are `changes(container_start_time_seconds[$__range])` — cAdvisor exports no restart counter.

**Exporter vocabularies are not internally consistent, so every metric name is measured before it is charted.** `pg_stat_database_xact_commit` has no `_total`; `pg_stat_checkpointer_num_timed_total`, from the same exporter, does. cAdvisor reports `container_spec_memory_limit_bytes` as 0 rather than absent when no limit is set, which turns the obvious "percentage of limit" panel into `+Inf`. Node-exporter's disk and network series are dominated by devices that are structurally always zero — `nbd*`, `erspan0`, `gre0`, `sit0` — which the conventional `device!~"lo|veth.*|docker.*"` deny-list does not exclude. None of this is discoverable from documentation; all of it is discoverable in ten seconds from `/api/v1/label/__name__/values` against a running stack, which is the step that precedes writing any panel here.

Provider: file, `foldersFromFilesStructure: true`, `updateIntervalSeconds: 30`, `allowUiUpdates: false` (tightened from the reference — provisioned dashboards should be immutable).

---

## 7. Server config deltas from the reference

- **Prometheus**: `--storage.tsdb.retention.time=30d` + `--storage.tsdb.retention.size=25GB`; keep `--web.enable-remote-write-receiver` and `--enable-feature=exemplar-storage`. Add:
  ```yaml
  storage:
    tsdb: { out_of_order_time_window: 2h }
    exemplars: { max_exemplars: 200000 }
  ```
  **Without `out_of_order_time_window`, every sample an agent buffered during a VPS outage is rejected as too-old and you get a permanent gap.** This is the single most likely production surprise.
- **Loki**: retention `336h` (14d); `reject_old_samples_max_age: 168h`; keep tsdb/v13, `allow_structured_metadata`, `volume_enabled`, `discover_log_levels`, `pattern_ingester`, compactor retention.
- **Tempo**: `compactor.compaction.block_retention: 168h` (7d); span-metrics `dimensions: [app, service, env, http.route, http.response.status_code]` plus the `write_relabel_configs` that reconcile the generator's label names (§3, `docs/labels.md` §3.4); service-graph `dimensions: [app, env]`, without which a service map cannot be scoped to one app; **keep `local-blocks` disabled** — the reference documents a 12 GB memory regression from it. Record as do-not-re-enable in `docs/operations.md`.
- **Grafana datasources**: keep fixed UIDs, `exemplarTraceIdDestinations`, and Loki `derivedFields` with `matcherType: label` + `matcherRegex: trace_id`. **Replace `tracesToLogs` with `tracesToLogsV2`**, `tags: [{key: app},{key: service},{key: env}]`. Keep the `$$` escaping but document the real reason: *Grafana's provisioning loader* interpolates `$VAR`/`${VAR}`, so `$__tags` and `${__value.raw}` must be written `$$__tags` / `$${__value.raw}`. (The reference comment blames Compose; that's wrong and would mislead.)
- **cAdvisor moves to the agent side** with a Linux-native config: drop `privileged: true`, drop `--containerd=/run/containerd/containerd.sock` and that mount (WSL2/Docker-Desktop only); use `devices: [/dev/kmsg]` plus the standard read-only mounts. `compose.agent.macos.yml` restores the containerd flag for local testing only.

**Not carried over**: `host.docker.internal`, the `${APP_PROJECT_NAME}_default` external network, `http_proxy`/`no_proxy` env plumbing and the proxy-clearing healthcheck prefixes, `user: "0"` on Loki/Tempo (use pre-created volumes with correct ownership), and the shared LGTM/GlitchTip `.env` (now three separate env files).

**GlitchTip's secrets are read by its containers, not interpolated by Compose.** `compose.glitchtip.yml` names `.env.glitchtip` in `env_file:` rather than referencing `${SECRET_KEY}` and `${POSTGRES_PASSWORD}`, so those values never pass through the `${}` layer and the `$$`-doubling that `INGEST_USERS` needs does not apply to them — which matters most for exactly the values most likely to contain a `$`, a generated key and a generated password. Only what is *derived* stays in `environment:`: `GLITCHTIP_DOMAIN` and `CSRF_TRUSTED_ORIGINS`, both from `GLITCHTIP_DOMAIN` in `.env.server`, so a deployment cannot set one and forget the other. Same pattern as the agent's `DATA_SOURCE_*` (§3).

**GlitchTip gets a third network of its own.** `obs` carries the LGTM services *and* the app containers on the box; GlitchTip's Postgres holds exception payloads — stack traces, request context — from every app that reports there, and belongs on neither. Only `glitchtip-web` joins `obs` (so an app can POST to `glitchtip-web:8000`) and `edge` (so Traefik can route `errors.<domain>`).

**Error events carry the label contract too.** `sentry_sdk.init` gets `server_name=settings.host`; its default is `socket.gethostname()`, which inside a container is the short container ID — a value that matches nothing else in the stack and changes on every recreate. With `OBS_HOST` instead, an error's `server_name`, `environment` and `release` tags are the same strings the metrics, logs and traces are filtered by, which is the only reason the fourth signal is worth having next to the other three.

---

## 8. Local development

`make demo-up` → `docker compose -f compose.yml -f compose.demo.yml --profile postgres --profile containers up -d`, bringing up the **real server stack** (Traefik included, on `*.localhost`, so the auth path is genuinely exercised) plus:

- `demo-api` — FastAPI on `python:3.13-slim`, installing `obskit` from the local path so SDK edits are live; routes `/ok`, `/items/{item_id}`, `/slow`, `/boom`, `/db`, plus `/health` passed to `excluded_paths` so probe traffic reaches no metric and no log line; carries the `obs.*` Docker labels. Build context is the repo root with the host layout mirrored inside the image, which is what lets the `obskit` path dependency resolve identically in both places.
- `demo-db` — `postgres:18-alpine` with the exporter bootstrap SQL applied on first boot. **Postgres 18 moved the data directory**: the volume mounts at `/var/lib/postgresql`, not `/var/lib/postgresql/data`, and the image refuses to start on the old path.
- the **unmodified `agent/config.alloy`**, with `.env.demo` pointing at `https://ingest.localhost/...` — proving one file works in both places.
- `loadgen` — async loop hitting the routes with a fixed error/slow mix, itself wired with `setup_worker_observability`. That gives `app=demo` a second `service`, which is the only way the chained `$app`/`$service` dashboard variables (§6) are testable, and it instruments httpx so `traceparent` propagates and Tempo's service graph has an edge to draw. Its own counter is named `client_requests_total`, not `loadgen_requests_total` — `docs/labels.md` §4.4 bars `service` from a metric name exactly as it bars `app`.

This assembles in stages: M3b brings up the server stack plus `demo-api`/`demo-db`/`demo-loadgen` with `OBS_OTLP_ENDPOINT` pointed straight at `tempo:4317`; M4 adds the agent and re-points that one variable at `alloy:4317`; M6 puts Traefik in front.

Mac caveats for `docs/local-dev.md`: `prometheus.exporter.unix` reports the Docker Desktop Linux VM, not macOS, so the infra dashboard is verified for *shape*, not values; cAdvisor needs the containerd override.

### Verification harness

`scripts/verify-signals.sh` asserts with exit codes:

1. `count(fastapi_requests_total{app="demo"}) > 0`
2. Loki `/label/app/values` contains `demo`, and a `query_range` result carries `trace_id` in structured metadata
3. Tempo `/api/search?tags=service.name%3Ddemo-api` returns ≥1 trace
4. `/api/v1/query_exemplars?query=fastapi_requests_duration_seconds_bucket` returns ≥1 exemplar
5. `traces_spanmetrics_calls_total{app="demo"}` exists

`scripts/verify-dashboards.sh` extracts every `expr` from the three dashboard JSONs and asserts a non-empty result.

---

## 9. Pinned versions

`prom/prometheus:v3.11.3` · `grafana/loki:3.7.1` · `grafana/tempo:2.10.5` · `grafana/grafana:13.0.1` · `grafana/alloy:v1.16.1` · `quay.io/prometheuscommunity/postgres-exporter:v0.19.1` · `ghcr.io/google/cadvisor:v0.57.0` (the `gcr.io/cadvisor` mirror stopped publishing after v0.47.x) · `traefik:v3.5` · `glitchtip/glitchtip:6` · `postgres:16-alpine` (GlitchTip) · `valkey/valkey:8-alpine` · `postgres:18-alpine` (demo) · `python:3.13-slim`.

The first seven are exactly what the reference proves in production. Pin resolved digests for `traefik`, `glitchtip`, `valkey` at M1/M8 and record them in `docs/operations.md` — `:6` and `:v3.5` are floating tags.

---

## 10. Risks

1. **Out-of-order rejection after an agent outage** — mitigated by `out_of_order_time_window: 2h`; M9 exists solely to verify this.
2. **Alloy's `loki.write` WAL sits behind the experimental stability gate** (`--stability.level=experimental`). Without it, log durability across a VPS outage is best-effort retries only. Recommendation: enable it and accept the gate.
3. **Traces are not durably buffered** — Alloy's OTLP `sending_queue` is in-memory. A long outage drops traces. Accepted; traces are the least valuable signal to backfill.
4. **Basic auth does not enforce label integrity** (§4) — documented, with the `X-Scope-OrgID` upgrade path.
5. ~~**`keepequal` port matching requires the metrics port to appear in `__meta_docker_port_private_port`**~~ — confirmed at M4, and the label is `__meta_docker_port_private`. The port must be `EXPOSE`d in the image or `expose:`d in compose; publishing it is not required. Document in `onboarding-an-app.md`; the `OBS_EXTRA_TARGET` env escape hatch covers containers that can't. **New at M4**: discovery emits one target per network as well as per port, so a container on two networks is scraped twice — `OBS_DOCKER_NETWORK` exists for that.
6. ~~**Exemplars need OpenMetrics negotiation end to end**~~ — confirmed working through the agent at M4, with `send_exemplars = true` on `prometheus.remote_write` (off by default; the reference never sets it and drops every exemplar at that line). `verify-signals.sh` step 5 is the regression test.
7. ~~**Tempo span-metrics dimension lookup**~~ — settled across M4 and M5. 2.10.5 reads `app`/`env` from resource attributes, so no `transform` processor is needed. The `service` collision (generator writes its own from `service.name`; ours arrives as `__service`) is fixed by `write_relabel_configs` on the generator's remote-write — the only mechanism that works, since the `__` prefix is applied against a hardcoded list that `intrinsic_dimensions` and `dimension_mappings` do not affect. Rejected alternatives: setting `service.name` to the bare service, which fixes the label but merges two apps' `api` into one node in Tempo's service list; and `dimension_mappings`, whose target name goes through the same collision check. Same block drops `__metrics_gen_instance` — `enable_instance_label: false` is accepted by 2.10.5 and does not remove it.
8. **Clock skew** between app hosts and the VPS corrupts log ordering and can trip Loki's max-future-age. Require `chrony`/`systemd-timesyncd`; `deploy-vps.md` checks it.
9. **Single node, filesystem storage, no HA.** `scripts/backup.sh` tars the Grafana volume (`grafana.db` is the only irreplaceable state) plus the TSDB volumes; restore tested once at M10.
10. **Cardinality** — cAdvisor is the usual offender; carry over the reference's `--disable_metrics` list and `id` labeldrop.

**Out of scope for v1**, listed as future work in `docs/operations.md`: stack self-monitoring dashboards, Grafana alerting/contact-point provisioning, Pyroscope profiling, Mimir/multi-tenancy, community dashboard vendoring.
