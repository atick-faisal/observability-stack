# Operations

Running the server after it is deployed: what expires when, what to back up, what makes it fall
over, and what to be careful about when upgrading.

---

## 1. Retention and disk

| Signal | Kept | Where set | Also capped by |
|---|---|---|---|
| Metrics | **30d** | `compose.lgtm.yml` → `--storage.tsdb.retention.time` | `--storage.tsdb.retention.size=25GB` |
| Logs | **336h** (14d) | `lgtm/loki/loki-config.yaml` → `limits_config.retention_period` | `ingestion_rate_mb: 16`, burst 32 |
| Traces | **168h** (7d) | `lgtm/tempo/tempo-config.yaml` → `block_retention` | |
| Errors | **30d** | `.env.glitchtip` → `GLITCHTIP_RETENTION_DAYS` | |

Whichever of time and size hits first wins for Prometheus. Loki's retention needs
`compactor.retention_enabled: true`, which is set — without it `retention_period` is inert and
the disk grows forever.

GlitchTip's 30 days is matched to Prometheus deliberately rather than left at its 90-day default:
an error you cannot pull up the metrics, logs and trace for is an error you cannot investigate,
and those expire at 30d / 14d / 7d.

### The windows that must stay wider than the agent's buffers

> [!IMPORTANT]
> The agent buffers all three signals to disk through an outage and replays them **with their
> original timestamps**. A server that rejects that replay as too old is worse than no buffer,
> because it looks like it worked — the agent reports success and the gap is permanent.
>
> **The agent's buffer is the authoritative number.** It is the one that says how long an outage
> can run; each server-side window follows it, and must be at least as wide.

| Signal | Agent holds | Server accepts | Margin |
|---|---|---|---|
| metrics | 8h WAL (`max_keepalive_time`) | `out_of_order_time_window: 8h` (`prometheus.yml`) | exactly equal |
| logs | 8h WAL (`max_segment_age`), 20 retries ≈ 1h per batch | `reject_old_samples_max_age: 168h` (`loki-config.yaml`) | 21× |
| traces | 10 000 batches on disk | any timestamp — Tempo has no window | unbounded |

Shortening either server-side value without shortening the agent's buffer is how you get a
silent hole. `make verify-resilience` is the regression test.

> **The metrics row was `8h` against `2h` until this was reconciled**, and the reason it never
> showed up is worth keeping. A single agent replays *in order* into a head whose max time is the
> moment it went down, so it barely touches the out-of-order path — the 2h window was almost never
> the thing being tested. What the window actually protects is a **second** agent's replay landing
> against the first agent's live writes, which is the multi-app case, and multi-app is the premise
> of this stack rather than an edge case. With two app hosts, an outage longer than two hours on
> one of them was a permanent gap that nothing reported.
>
> Prometheus moved rather than the agent because widening is close to free: the out-of-order head
> holds only samples actually received out of order, so it costs head memory during the replay it
> exists for and nothing in steady state. Lowering the agent to 2h would have been the other
> defensible choice, at the cost of replay depth.
>
> `make verify-resilience` (`make demo-up SECOND_AGENT=1` first) now also runs a second, independent
> agent alongside the first. Its outage is a network disconnect from the server, not a container
> stop — Alloy pulls metrics from the app, so a stopped agent would not be scraping and would have
> nothing to replay — and it is timed short (90s by default) because the first agent's live writes
> never stop, so the head has already moved past agent 2's buffered timestamps the moment it
> reconnects. That is what a single agent, however long its own outage runs, structurally cannot
> produce. One side effect worth knowing if you go looking: two agents sharing one Docker host also
> cross-collect each other's container logs (Alloy's log discovery has no per-agent network filter,
> unlike its metrics scrape) — harmless for the checks, which query by full `app`+`service` label,
> but expected noise if you're inspecting log volume in the demo.

### When disk gets tight

```bash
docker system df -v | grep observability
```

`prometheus_data` and `tempo_data` are the two that grow. Lower `retention.size` before lowering
`retention.time` — a size cap deletes oldest-first and takes effect immediately, while a time
change waits for the next compaction.

## 2. Backup and restore

Dashboards are files in git, so the irreplaceable state is smaller than it looks: `grafana.db`
(the admin account, users, annotations, alert state) and GlitchTip's Postgres. Those two are the
default set.

```bash
make backup                                   # the irreplaceable set
make backup ARGS="--all --keep 7"             # ...plus the three TSDBs, keeping the newest 7
make restore DIR=backups/<stamp>              # dry run: prints what it would replace
make restore DIR=backups/<stamp> ARGS=--yes   # and now for real
```

Each volume is copied the way its storage engine allows, which is **not one method**:

| | How | Why not a live tar |
|---|---|---|
| `grafana_data` | stop → tar → start | `grafana.db` is SQLite; a sequential tar of the file and its `-wal` sidecar can capture a pair that disagree, which restores as a *corrupt* database rather than an old one. Grafana is a query UI, so the few seconds cost no ingest. |
| `glitchtip_pg_data` | `pg_dump -Fc` | Tarring a live `PGDATA` without `pg_backup_start` is the textbook way to produce something that will not replay. |
| the three TSDBs | tar, live, opt-in behind `--all` | All three replay a WAL on start and write blocks temp-then-rename, so a live tar is a power cut, which they are built to survive. Not in the default set: they are retention-bounded and 25 GB-capped, and a routine backup should not be tens of gigabytes. |

`restore.sh` refuses a backup whose `SHA256SUMS` is missing or does not match. No password passes
through either script — the GlitchTip dump runs as the container's own `$POSTGRES_USER` over a
local socket.

> [!WARNING]
> **`backups/` is gitignored, and a backup on the same disk is not a backup.** Copy it off the
> box.

### Verifying a restore

Two things that look like failures and are not:

- **`grafana.db` can never hash equal to its backup.** Grafana writes to it on boot, so a
  correct restore still produces a different file. The identity marker is the `user` table's
  per-install random salt — regenerated by a fresh install, untouched by a restart.
- **GlitchTip's event count climbs on its own** if anything is still reporting errors. Measured
  at 643 → 646 in 16 seconds under the demo load generator. An exact count assertion only means
  something with the reporters stopped.

Verified once, for real: `restore.sh` run against a genuinely destroyed volume
(`docker volume rm observability_grafana_data`, recreated empty by compose) put the Grafana
install fingerprint back from a fresh one, and GlitchTip's event count back from 656 to exactly
651.

## 3. Cardinality

Cardinality is the failure mode that kills a Prometheus, and it arrives gradually. What to watch:

```promql
topk(10, count by (__name__)({__name__=~".+"}))          # which metrics have the most series
sum(scrape_samples_scraped) by (job)                     # which target is growing
prometheus_tsdb_head_series                              # the headline number
```

The rules that keep it bounded, from `docs/labels.md`:

- **Never a label**: user id, request id, trace id, full URL, raw SQL, timestamp, email. Route
  *templates* (`/items/{item_id}`), never resolved paths.
- **cAdvisor is the usual offender.** `id` is dropped from its series because a container id is
  unbounded over time, and a `--disable_metrics` list turns off the per-NUMA-node, per-TCP-state
  and per-process families. Both are already configured in `agent/compose.agent.yml`.
- The trade-off of the `id` labeldrop: while a recreated container briefly coexists with its
  predecessor, the two collapse onto one series and Prometheus rejects that write with
  `duplicate sample for timestamp`. It resolves within a scrape or two. Remove the rule if you
  would rather have the cardinality than the gap.

## 4. Do not re-enable Tempo `local-blocks`

`lgtm/tempo/tempo-config.yaml` runs `processors: [service-graphs, span-metrics]` and
deliberately omits `local-blocks`. It holds completed parquet blocks in RAM for
`complete_block_timeout` (1h by default); the reference stack measured **12 GB+** of growth from
it. Nothing here uses TraceQL metrics queries, which is the only thing it enables. §10 sets
tempo's `mem_limit`, which is what turns a re-enabled `local-blocks` into a restart instead of a
box-wide OOM.

If you ever do need TraceQL metrics, budget the memory first and cap `complete_block_timeout`.

## 5. Pinned images

Every image is pinned to a tag. Three are additionally pinned to a **digest**, because their tags
float:

| Image | Digest | |
|---|---|---|
| `glitchtip/glitchtip:6` | `sha256:95e0e2d6…` | The one that matters. `:6` is a whole minor series, and `glitchtip-migrate` runs Django migrations on every `up` — so an unattended bump rewrites the schema of the database holding every error ever reported, and migrations do not run backwards. |
| `traefik:v3.5` | `sha256:16acb89c…` | Patch-level drift, but it is the edge: a moved tag takes every route down at once. |
| `valkey/valkey:8-alpine` | `sha256:a0381758…` | Patch-level. GlitchTip's queue. |

```bash
./scripts/resolve-digests.sh            # what the tags resolve to now
./scripts/resolve-digests.sh --check    # exit 1 if a pin has drifted; never edits anything
```

`--check` is the one worth running in CI. It reports; re-pinning stays a deliberate act,
especially for GlitchTip, where it is a decision to run migrations.

**`postgres:16-alpine` (GlitchTip) and `postgres:18-alpine` (demo) are deliberately left
floating.** They move only within a major version, the demo one is disposable, and pinning
GlitchTip's database would introduce a second upgrade schedule that has to be kept compatible
with the application's by hand. That is a worse failure mode than a patch-level Postgres bump.

The digest pinned is always the multi-arch **index**, not a platform manifest — see
`scripts/resolve-digests.sh`'s header for why the obvious ways to resolve one are both wrong.

### Upgrading

1. `make backup` first. For GlitchTip this is not optional — migrations do not run backwards.
2. Change the tag *and* the digest together. A tag with a stale digest is a lie in the file.
3. `make verify-config`, then `make lgtm-up --build`.
4. Watch for `level=error` on a clean boot. Zero is the standard the stack holds itself to.

## 6. Project-name asymmetry between the two stacks

`compose.lgtm.yml:1` declares `name: observability`. `compose.glitchtip.yml` deliberately does
not — see its header comment.

Deployed as its own standalone service (its own Dokploy/Coolify entry), `compose.glitchtip.yml`'s
project name comes from whatever the platform names that service, since there is no `name:` to
fall back on. Set it explicitly on the platform side rather than leaving it to a default.

> [!WARNING]
> **Do not "fix" this by adding `name:` to `compose.glitchtip.yml`.** Locally, `make glitchtip-up`
> sets `COMPOSE_PROJECT_NAME=observability` on the command line specifically so GlitchTip's
> containers join the LGTM stack's `obs` network — the only thing that makes `glitchtip-web:8000`
> reachable from an app on the same box. A `name:` in the file would fight that: on an overlay of
> multiple compose files, the last file's `name` wins, so it would silently start a second,
> disconnected project instead of joining the first. The file has to take its project name from
> whatever deploys it, which is precisely why it has none of its own.

## 7. The `$` trap

Compose interpolates values it reads from `--env-file`. So in **`.env.lgtm`**:

- `$$` collapses to a single `$` — measured: `GF_ADMIN_PASSWORD=ab$$cd` reaches the container as
  `ab$cd`.
- `$NAME` expands to that variable's value — measured: `xy$HOME` arrives as `xy/Users/ai`.

Two consequences:

- **Avoid `$` in `GF_ADMIN_PASSWORD` entirely.** The admin user is created exactly once, so the
  first failed login is also the point at which fixing it means destroying `grafana_data`.
- **Every `$` in a bcrypt hash in `INGEST_USERS` must be doubled.** `scripts/add-ingest-user.sh`
  prints it doubled already, and `scripts/verify-ingest.sh` proves the round trip — a
  mis-escaped hash produces a 401 indistinguishable from a wrong password.

**`.env.glitchtip` is the opposite.** It is handed to containers via `env_file:` and is *not*
interpolated, so a `$` there is literal. Two files, two rules — which is why they are two files.

## 8. Health and first response

```bash
curl -sf localhost:9090/-/healthy      # prometheus
curl -sf localhost:3100/ready          # loki
curl -sf localhost:3200/ready          # tempo
curl -sf localhost:3000/api/health     # grafana
```

Loki and Tempo have no container healthcheck: their images are distroless — `grafana/loki:3.7.1`
ships only `/usr/bin/loki` — so there is no shell, no wget and no curl to run one with. Readiness
is checked from the host instead.

> [!NOTE]
> **After a restart, a `503` from Loki or Tempo is not yet a problem.** Both answer
> `Ingester not ready: waiting for 15s after being ready` until the ingester has joined the ring
> and settled. Measured at 35s on a plain `docker restart`; observed at several minutes on a full
> stack restart against volumes holding a fortnight of data, with Tempo ready long before Loki.

Poll rather than assuming a number, and only start looking for a cause once it has been
minutes *and* the ring is not `ACTIVE`:

```bash
until curl -sf localhost:3100/ready >/dev/null; do sleep 3; done
curl -s localhost:3100/ring | grep -o ACTIVE     # what the ingester thinks it is
```

Note that Loki keeps serving `/loki/api/v1/labels` and `/metrics` throughout, so "Loki is up" and
"Loki is ready" are genuinely different questions.

| Symptom | First thing to check |
|---|---|
| One app's metrics stop, logs continue | That app's ingest credential, and its `expose:` — see `onboard-app.md`. |
| Everything from one host stops | The clock on that host. Loki rejects future-dated samples outright. |
| `duplicate sample for timestamp` | A container on two networks, scraped twice. Set `OBS_DOCKER_NETWORK` on that agent. |
| Logs arrive with a seventh stream label | `discover_service_name` re-enabled somewhere. It must stay `[]`. |
| Grafana graphs blank after a rename | `make verify-dashboards` — it names the panel. |

Traefik's access log is JSON and names the ingest user on every request, so push volume is
attributable per app and a 401 tells you which credential.

## 9. Out of scope for v1

Listed so their absence reads as a decision rather than an oversight:

- Stack self-monitoring dashboards — the agent does not collect its own logs, and nothing watches
  the watcher. Read them with `docker compose logs alloy`.
- Grafana alerting and contact-point provisioning. The `alerting/` provisioning directory exists
  and is empty.
- Pyroscope profiling.
- Mimir, or any multi-tenancy. Basic auth does not enforce label integrity — a credential for one
  app can write another app's labels. The upgrade path is `X-Scope-OrgID`, documented in
  `docs/archive/PLAN.md` §4.
- Community dashboard vendoring.
- HA. Single node, filesystem storage. §2 is the answer, and it is a real one only if the backups
  leave the box.

## 10. Memory limits

Every service carries a `mem_limit`. Without one, any single component can take the whole box: a
wide Loki query, Tempo's compactor, GlitchTip's Celery workers, or Prometheus on a cardinality
spike. The limit changes what that failure costs — an OOMKilled Prometheus replays its WAL and
loses a bounded amount; an OOMKilled box loses everything on it, including the agent buffers on any
app host that shares it. A limit converts the second failure into the first.

| Service | `mem_limit` | Why |
|---|---|---|
| prometheus | `1g` | The one most likely to grow: cardinality, plus the 8h out-of-order head (§1). |
| loki | `512m` | |
| tempo | `512m` | Bounded specifically because `local-blocks` stays off (§4) — this limit is what turns a re-enabled `local-blocks` into a restart instead of a box-wide OOM. |
| grafana | `256m` | Query-time aggregation on a wide dashboard is the spike case. |
| traefik | `128m` | Reverse proxy plus JSON access logging. Watch it if request volume grows a lot. |
| glitchtip-postgres | `512m` | |
| glitchtip-valkey | `128m` | Queue and cache; small working set. |
| glitchtip-web / -worker / -migrate | `512m` each | Uniform, via the `x-glitchtip-app` anchor. `CELERY_WORKER_AUTOSCALE` is already capped at `1,3` for the same reason — the worker isn't meant to want more than this. `-migrate` is one-shot and exits before its limit matters. |
| alloy (agent) | `256m` | Runs on the app host, not this one. |
| cadvisor | `128m` | |
| postgres-exporter | `64m` | |
| demo-db / demo-api / demo-loadgen | `256m` / `128m` / `96m` | Local only. `demo-loadgen` measured at 73% of a `64m` limit within minutes of `demo-up`, so it got the extra margin. |

**Budget check**, against §1 of `docs/deploy-server.md` ("4 GB works for a handful of apps"): LGTM
alone — prometheus + loki + tempo + grafana — totals 2.25 GB, leaving headroom for the OS and the
Docker daemon; `EDGE=1` adds traefik's 128m on top. GlitchTip, deployed as its own service, totals
about 1.66 GB steady-state (web + worker + postgres + valkey; migrate is transient and exits before
its limit is concurrent with the others) — comfortably less than the LGTM box, which fits it being
the smaller of the two stacks.

These are starting points, not measurements. Watch `docker stats` under real traffic, and once
`container_spec_memory_limit_bytes` is non-zero — it reports zero for every container while nothing
sets a limit — the "memory as % of limit" Grafana panel dropped during development for exactly that
reason becomes viable again. A container that gets OOMKilled routinely is the signal to raise its
limit, not evidence the limit was wrong to set.
