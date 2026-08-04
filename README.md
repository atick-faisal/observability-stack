# observability-stack

An application-independent Grafana LGTM stack. One deployment on a VPS serves every project.

Onboarding a new FastAPI + Postgres app is four steps: copy `agent/`, add a few Docker labels,
`uv add obskit`, one function call.

> **Status: pre-v1, under construction.** Current milestone: **M0 — Foundations**.
> See [`TASKS.md`](./TASKS.md) for what is done and what is next.

## The two halves

Both are deployable independently.

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

**Server** — Traefik fronts Grafana and GlitchTip on public subdomains, plus a single
`ingest.<domain>` host exposing three authenticated paths that proxy to Prometheus
remote-write, Loki push, and Tempo OTLP/HTTP. Nothing else is reachable from outside.

**Agent** — one Alloy container per app host. It discovers scrape targets and log streams from
Docker labels, runs optional cAdvisor / postgres_exporter via Compose profiles, receives OTLP
traces from the local app, and pushes everything to `ingest.<domain>` over HTTPS with basic
auth and local buffering. The app exposes nothing publicly.

## Onboarding an app

```yaml
# 1. copy agent/ into the app repo as observability/, then label the containers
services:
  api:
    labels:
      obs.service: api
      obs.metrics.port: "8000"
      obs.metrics.path: /metrics
```

```bash
# 2. run the agent alongside the app
docker compose -f compose.yml -f observability/compose.agent.yml up -d

# 3. add the SDK
uv add "obskit[grpc,sqlalchemy] @ git+<repo-url>@v0.1.0#subdirectory=sdk/obskit"
```

```python
# 4. wire it up
from obskit import setup_observability

setup_observability(app, engine=engine)
```

## Documentation

| | |
|---|---|
| [`docs/labels.md`](./docs/labels.md) | **Read this first.** The label contract everything else depends on. |
| [`PLAN.md`](./PLAN.md) | Design and rationale — the *why*. |
| [`TASKS.md`](./TASKS.md) | Implementation checklist — the *what next*. |
| `docs/onboarding-an-app.md` | The four-step diff in detail. *(M10)* |
| `docs/deploy-vps.md` | Provisioning, DNS, first `up`. *(M10)* |
| `docs/local-dev.md` | The demo stack, and macOS caveats. *(M10)* |
| `docs/operations.md` | Retention, backup/restore, cardinality. *(M10)* |

## Quickstart

```bash
make help          # list targets
make up            # start the server stack          (M1)
make demo-up       # start the local end-to-end demo (M4)
make demo-verify   # assert all five signals arrive  (M4)
```
