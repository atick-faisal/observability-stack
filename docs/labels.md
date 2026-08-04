# Label taxonomy

This is the contract. Every milestone after M0 depends on it. If a config, dashboard, or SDK
change disagrees with this document, the change is wrong — not the document.

The one-sentence version: **four identity labels, spelled identically in metrics, logs, and
traces, injected at exactly one choke point per signal.**

---

## 1. The four identity labels

| Label | Meaning | Cardinality | Allowed values | Example |
|---|---|---|---|---|
| `app` | Deployment unit — one value per app repo | ~10s | `[a-z0-9-]+` | `asset-management` |
| `service` | Process role inside the app | ~5 per app | `[a-z0-9-]+` | `api`, `worker`, `db` |
| `env` | Deployment environment | exactly 3 | `production` \| `staging` \| `local` | `production` |
| `host` | Machine the agent runs on | ~10s | `[a-z0-9.-]+` | `app-vps-01` |

`app` is the *deployment unit*, not the framework, not the language, not the container image.
One app repo produces one value of `app`. Two apps never share a value; one app never has two.

`service` is the *role a process plays inside* that app. It answers "which part of the app is
this?", not "what software is it?". A Postgres container belonging to `asset-management` is
`app=asset-management, service=db` — not `app=postgres`.

Together, `(app, service, env, host)` identifies a running process uniquely enough to be the
join key across all three signals. That is the entire purpose of these four.

## 2. Identity versus dimension

Identity is the four labels above **and nothing else**. Everything else is a dimension: useful
for slicing within a signal, never used to correlate across signals.

| | Labels |
|---|---|
| **Identity** (all signals, same spelling) | `app`, `service`, `env`, `host` |
| **Dimension** (signal-local) | `job`, `instance`, `container`, `level`, `method`, `status_code`, `route` |

The practical difference: you may add, rename, or drop a dimension in one signal without
touching the others. Changing an identity label is a breaking change to every dashboard and
every correlation link at once.

## 3. Injection points — one per signal

Identity is attached in exactly one place per signal. Not per job, not per exporter, not per
container. This is what guarantees that *every* series carries it, including the ones nobody
thought about.

| Signal | Choke point | What it sets |
|---|---|---|
| Metrics | `prometheus.remote_write "obs"` → `external_labels` in `agent/config.alloy` | `app`, `env`, `host` |
| Logs | `loki.process` → `stage.labels` in `agent/config.alloy` | `app`, `env`, `host`, `service`, `container`, `level` |
| Traces | OTel `Resource` in `obskit`'s `tracing.py` | `app`, `service`, `env`, `host` |

### 3.1 Metrics → Prometheus

`app`, `env`, and `host` are set once as `external_labels` on the agent's
`prometheus.remote_write`. Because they are applied at the exit, they land on **every** series
the agent forwards — the app's own `/metrics`, `node_*` from `prometheus.exporter.unix`,
`container_*` from cAdvisor, and `pg_*` from postgres_exporter — with no per-job configuration
and no way to forget one.

`service` comes from discovery relabels, sourced from the `obs.service` Docker label on the
container being scraped.

`instance` is pinned to a stable value via a relabel rule. Left to its default it is the
container IP, which changes on every restart and silently breaks any dashboard variable built
on it.

Metrics carry `app`, `env`, `host`, `service` — four labels, same spelling as everywhere else.

### 3.2 Logs → Loki

Loki stream labels are **exactly these six, and no others**:

```
app, env, host, service, container, level
```

All six are bounded. Adding a seventh, or making any of these unbounded, multiplies the number
of active streams and is the single fastest way to make Loki unusable.

- `trace_id` and `span_id` go to **structured metadata**, never to labels. They are indexed and
  filterable there, without creating a stream per request.
- Everything else stays in the JSON log body and is queried with `| json` at read time.

Not every log line is JSON. Postgres and Traefik emit plain text, so JSON parsing must be
**conditional** (see §6) — unconditional parsing mangles those lines. For non-JSON containers,
`level` comes from Loki's own `discover_log_levels`.

### 3.3 Traces → Tempo

The SDK sets OTel resource attributes using the flat names — `app`, `service`, `env`, `host` —
*and additionally* the OTel semantic-convention names:

| Attribute | Value | Why both |
|---|---|---|
| `app`, `service`, `env`, `host` | as defined above | correlation by identical name |
| `service.name` | `"{app}-{service}"` | semconv; drives Tempo's service graph and the Grafana trace UI |
| `deployment.environment.name` | same as `env` | semconv |

The flat names are what dashboards and correlation links use. The semconv names are what Tempo
and Grafana's built-in trace tooling expect. Setting both costs nothing and avoids choosing.

Tempo's span-metrics generator is configured with:

```yaml
dimensions: [app, service, env, http.route, http.response.status_code]
```

so `traces_spanmetrics_*` series carry the same identity labels as everything else and can be
graphed alongside them.

## 4. Hard rules

### 4.1 One spelling per concept, across all three signals

`env` is `env` in metrics, `env` in logs, and `env` in traces. Never `environment`, never
`deployment_env`, never `ENV`.

This is the rule that makes everything else work. Grafana's `tracesToLogsV2` and
`tracesToMetrics` map span attributes onto target-datasource labels **by name**. When the names
already match, the configuration is:

```yaml
tags: [{ key: app }, { key: service }, { key: env }]
```

— one block, in `datasources.yaml`, correct for every app forever. When the names don't match,
every pair needs an explicit rename, and every new app needs the list extended.

> The reference stack (`ai-asset-management`) writes `env="production"` on its Prometheus
> targets and `environment="production"` on its Loki streams. They mean the same thing and
> Grafana cannot know it. That is why this rule is first.

### 4.2 Never a label

Not in metrics, not as a Loki stream label, not as a span-metrics dimension:

| Never a label | Because | Put it here instead |
|---|---|---|
| `trace_id`, `span_id` | unique per request — unbounded | Loki structured metadata; span identity |
| `user_id`, `request_id`, session/tenant ids | unbounded, and often personal data | log body |
| Raw URL path (`/users/8123/orders/55`) | unbounded — one series per id | matched route pattern (§4.3) |
| SQL text | unbounded, and leaks data into an unencrypted index | log body / span attribute |
| Full error message | unbounded — messages interpolate values | exception *type* as the label, message in the body |

The test: *can this take a value derived from user input or from time?* If yes, it is not a
label.

### 4.3 HTTP paths are always the matched route pattern

Metrics record `/users/{user_id}/orders/{order_id}`, never `/users/8123/orders/55`. The pattern
is bounded by the number of routes in the app; the raw path is bounded by the number of rows in
the database.

In FastAPI the pattern is obtained by walking `app.routes` and testing
`route.matches(scope) == Match.FULL` — `request.url.path` is always the raw path and must never
reach a metric label.

Unmatched requests (404s) collapse to a single `route=""`, deliberately: an open endpoint being
scanned would otherwise generate one series per probed URL.

### 4.4 `app` never appears in a metric name

Metric names are generic and describe *what is measured*. Identity lives in labels.

```
fastapi_requests_total{app="asset-management", service="api"}      ✅
imgworker_images_processed_total                                    ❌
asset_management_requests_total                                     ❌
```

A metric name containing the app name cannot be graphed by a shared dashboard, cannot be
aggregated across apps, and forces a new dashboard per app — which defeats the purpose of this
repo. The reference stack namespaces its worker metrics `imgworker_*`; those panels work for
exactly one app and are not portable.

The same applies to `service` and `env`.

### 4.5 Labels are lowercase, flat, and underscore-free where possible

`app`, not `App` or `app.name`. Dots are legal in OTel attributes but not in Prometheus label
names, where they become underscores — so a dotted attribute silently changes spelling when it
crosses into metrics, breaking §4.1. Keeping the four identity labels flat and single-word
sidesteps the whole translation problem.

## 5. Where each label actually comes from

| Label | Agent (`agent/config.alloy`) | App (`obskit`) |
|---|---|---|
| `app` | `OBS_APP` env var | `OBS_APP` → `ObservabilitySettings.app` — **required**, startup fails without it |
| `service` | `obs.service` Docker label on the container | `OBS_SERVICE` → `.service`, default `api` |
| `env` | `OBS_ENV` env var | `OBS_ENV` → `.env`, default `local` |
| `host` | `OBS_HOST` env var | `OBS_HOST` → `.host`, default `socket.gethostname()`; the agent overwrites it on ingest |

Both halves read the same variable names from `.env`, so a single file configures the agent and
the app consistently. `host` is authoritative from the agent — the agent upserts it onto
incoming spans, because a containerized app reports its container id as its hostname, which is
not the machine.

An app opts a container into collection with Docker labels:

```yaml
services:
  api:
    labels:
      obs.service: api
      obs.metrics.port: "8000"     # presence = scrape me
      obs.metrics.path: /metrics
  db:
    labels:
      obs.service: db              # logs only, no metrics port
  migrations:
    labels:
      obs.logs: "false"            # opt out entirely
```

`obs.metrics.port` must also be `EXPOSE`d in the image or `expose:`d in Compose — the agent
matches it against Docker's published port metadata.

## 6. Consequences for later milestones

Recorded here so they are not rediscovered the hard way:

- **JSON log parsing must be conditional.** Guard `stage.json` with a `stage.match` selector so
  plain-text containers (Postgres, Traefik) pass through untouched and get `level` from
  `discover_log_levels`. Parsing unconditionally corrupts them. *(M4)*
- **Provisioned dashboards are immutable.** `allowUiUpdates: false` on the dashboard provider —
  a dashboard edited in the UI and not in git is a dashboard that will be silently reverted.
  *(M2)*
- **Grafana's provisioning loader interpolates `$VAR`.** `$__tags` and `${__value.raw}` must be
  written `$$__tags` and `$${__value.raw}` in `datasources.yaml`. This is Grafana, not Docker
  Compose. *(M2)*
- **Use `tracesToLogsV2`, not `tracesToLogs`.** The v1 field is deprecated and has no `tags`
  support, so trace→log links fall back to trace-id-only matching and lose the app/service/env
  filter. *(M2)*

## 7. Worked example

One app, `asset-management`, running its API in production on `app-vps-01`.

**Identity, identical in all three signals:**

```
app=asset-management  service=api  env=production  host=app-vps-01
```

**Metrics** — a request-rate series:

```
fastapi_requests_total{
  app="asset-management", service="api", env="production", host="app-vps-01",
  method="GET", route="/assets/{asset_id}", instance="app-vps-01"
}
```

**Logs** — a stream, plus one line's structured metadata:

```
{app="asset-management", service="api", env="production",
 host="app-vps-01", container="assetmgmt-api-1", level="error"}
   ↳ structured metadata: trace_id=4bf92f..., span_id=00f067...
   ↳ body: {"event":"HTTP","status_code":500,"route":"/assets/{asset_id}","duration_ms":812}
```

**Traces** — a span's resource attributes:

```
app=asset-management  service=api  env=production  host=app-vps-01
service.name=asset-management-api
deployment.environment.name=production
```

**Selecting it in each query language** — note that the label matcher is character-for-character
the same in all three:

```promql
sum(rate(fastapi_requests_total{app="asset-management", service="api", env="production"}[5m]))
```

```logql
{app="asset-management", service="api", env="production"} | json | status_code >= 500
```

```traceql
{ resource.app = "asset-management" && resource.service = "api" && resource.env = "production" }
```

That identity is what a dashboard variable substitutes into, what an exemplar carries from a
metric to a trace, and what a derived field carries from a log line back to a trace. It works
because the four names never change spelling.
