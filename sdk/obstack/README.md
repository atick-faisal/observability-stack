# obstack

Drop-in observability for FastAPI: structured JSON logs, Prometheus metrics, and OTLP traces
that all carry the same four identity labels — `app`, `service`, `env`, `host`.

> [!IMPORTANT]
> Those four names are the contract. They are spelled identically in every signal so Grafana can
> jump from a metric to a trace to a log line without renaming anything. See
> [`docs/labels.md`](../../docs/labels.md) — if this README and that document ever disagree, that
> document wins.

## Install

```bash
uv add "obstack[grpc,sqlalchemy] @ git+https://github.com/atick-faisal/observability-stack@v0.1.0#subdirectory=sdk/obstack"
```

| Extra | Pulls in | When |
|---|---|---|
| `grpc` | `opentelemetry-exporter-otlp-proto-grpc` | app → local Alloy on `:4317` (the default) |
| `http` | `opentelemetry-exporter-otlp-proto-http` | app → a collector over HTTP/1.1 |
| `sqlalchemy` | `opentelemetry-instrumentation-sqlalchemy` | you pass `engine=` |
| `errors` | `sentry-sdk` | you set `OBS_ERROR_DSN` |

## Use

```python
from fastapi import FastAPI
from obstack import setup_observability

app = FastAPI()
obs = setup_observability(app, engine=engine)
```

That one call configures structlog, registers the metrics and request-logging middleware,
serves `/metrics`, and — when `OBS_OTLP_ENDPOINT` is set — starts exporting traces.

For a process with no FastAPI app:

```python
from obstack import setup_worker_observability

obs = setup_worker_observability(metrics_port=9100)
...
obs.shutdown()
```

## Configure

Every setting is an environment variable prefixed `OBS_`. The agent reads the same four
identity variables from the same `.env`, which is what keeps the two halves consistent.

| Variable | Default | Notes |
|---|---|---|
| `OBS_APP` | **required** | `[a-z0-9-]+`. Missing or malformed raises `ObservabilityConfigError` at startup |
| `OBS_SERVICE` | `api` | `[a-z0-9-]+` |
| `OBS_ENV` | `local` | `local` \| `staging` \| `production` |
| `OBS_HOST` | `socket.gethostname()` | lowercased; the agent is authoritative for metrics |
| `OBS_VERSION` | `0.0.0` | surfaces as `fastapi_app_info{version=...}` |
| `OBS_LOG_LEVEL` | `INFO` | |
| `OBS_LOG_FORMAT` | `auto` | `auto` is console when `env=local`, JSON otherwise — set `json` explicitly if a collector tails a container running with `env=local` |
| `OBS_OTLP_ENDPOINT` | *unset* | e.g. `http://alloy:4317`. Unset disables tracing entirely |
| `OBS_OTLP_PROTOCOL` | `grpc` | `grpc` \| `http` |
| `OBS_TRACE_SAMPLE_RATIO` | `1.0` | parent-based ratio sampler |
| `OBS_METRICS_ENABLED` | `true` | |
| `OBS_METRICS_PATH` | `/metrics` | always excluded from its own metrics |
| `OBS_ERROR_DSN` | *unset* | GlitchTip / Sentry DSN. Events are tagged `environment` = `OBS_ENV`, `release` = `<app>-<service>@<version>` and `server_name` = `OBS_HOST`, so an error joins the other three signals |

`setup_observability(app, *, settings=None, engine=None, excluded_paths=())` — pass `settings`
to bypass the environment, `engine` to trace SQLAlchemy queries (an `AsyncEngine` is unwrapped
for you), and `excluded_paths` for health checks you do not want in the metrics.

## What you get

**Logs** — newline-delimited JSON on stdout, one `"HTTP"` line per request, with `trace_id` and
`span_id` injected whenever a span is active. Standard-library loggers (uvicorn, SQLAlchemy) are
routed through the same chain, so every line is JSON. Add your own request-scoped fields with
`bind_request_context(tenant="acme")`. `sqlalchemy.engine`, `uvicorn.access`, `httpx` and
`watchfiles` are pinned to `WARNING` — each of them logs a line per request that duplicates one
the SDK already emits.

**Metrics** — on an instance-local `CollectorRegistry`, so importing twice or setting up two apps
in one process cannot collide:

```
fastapi_requests_total{app,service,env,method,route,status_code}
fastapi_requests_duration_seconds{app,service,env,method,route}
fastapi_exceptions_total{app,service,env,method,route,exception_type}
fastapi_requests_in_progress{app,service,env,method}
fastapi_app_info{app,service,env,version}
```

`route` is always the **matched route pattern** (`/items/{item_id}`), never the raw path —
unmatched requests collapse to `route=""` so a scanner cannot mint a series per probed URL.
Exposition is OpenMetrics, which is what makes exemplars survive; a plain-text `/metrics`
endpoint drops them silently.

**Traces** — a `Resource` carrying `app` / `service` / `env` / `host` plus `service.name`
(`"{app}-{service}"`) and `deployment.environment.name`. If the exporter cannot be built the SDK
logs at `error` and runs on without tracing; it never takes the app down for an infrastructure
problem. A missing `OBS_APP`, by contrast, is a programmer error and fails at startup.

Setup also sets `OTEL_SEMCONV_STABILITY_OPT_IN=http` if it is unset, so HTTP spans carry
`http.request.method`, `http.response.status_code`, `url.path` and `server.address` rather than
the pre-1.0 names OpenTelemetry Python still defaults to. This is a **process-wide** switch read
once, so it applies to every HTTP instrumentation in the process, including ones the SDK does not
install (`httpx`, `requests`). Export it yourself — `http/dup` emits both sets — to keep control
of the timing during a migration; the SDK will not override an explicit value.

## Running multiple workers

> [!WARNING]
> **One worker per container.** Scale by running more containers, not more workers.
>
> `uvicorn --workers N` and `fastapi run --workers N` fork N processes that share one listening
> socket. Each holds its own `CollectorRegistry`, so consecutive scrapes land on different
> workers and a counter appears to move *backwards* — which Prometheus reads as a counter reset,
> making `rate()` and every dashboard built on it quietly wrong. Nothing logs an error; the
> graphs are just false.

The instance-local registry does not save you here: the problem is one endpoint answering from N
independent processes. If you must run multiple workers in one container, set
`PROMETHEUS_MULTIPROC_DIR` and use `prometheus_client`'s multiprocess collector, and note that
gauges and exemplars behave differently under it.

## Develop

```bash
uv sync --all-extras
uv run pytest
uv run mypy src
uv run ruff check .
```
