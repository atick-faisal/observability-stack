# Refactor plan

Written from the position of someone cloning this repo for the first time, who has to work out
what deploys where without reading the history — and then, separately, from the position of
whoever is on call for it at 3am.

The checklist lives in [`REFACTOR_TASKS.md`](./REFACTOR_TASKS.md). This file is the *why*.

Two parts, because they are independent and want different appetites for risk:

- **Part A — naming and structure.** Nothing here changes behaviour. It changes what the repo
  tells you about itself.
- **Part B — gaps and limitations.** Things that are absent or understated, ranked by what they
  cost when they bite.

Part A can ship without Part B and vice versa. The one hard constraint threading both: **the LGTM
stack and GlitchTip deploy as two separate services**, each with its own environment, on a host
whose proxy already exists. Most of what follows is taking that seriously rather than treating it
as an afterthought.

Current state, for sequencing: LGTM is live on Dokploy at `obs.atick.dev`; the GlitchTip service
has not been created yet; `obstack` 0.1.0 is on PyPI.

---

# Part A — naming and structure

## A0. What a newcomer sees

```
compose.yml  compose.local.yml  compose.edge.yml  compose.demo.yml
compose.demo.edge.yml  compose.glitchtip.yml  compose.glitchtip.local.yml
.env.server.example  .env.glitchtip.example
agent/  demo/  docs/  scripts/  sdk/  server/
```

Seven compose files at the root with no visible rule, and `compose.yml` — the one name that
carries a convention — is not the whole thing. It is one of two independently deployed stacks.

The specific misdirections:

| | |
|---|---|
| `compose.yml` | The LGTM stack, named as if it were the repo. It also makes `compose.local.yml` mean "LGTM, local" through an unwritten rule that an omitted subject means LGTM. |
| `.env.server` | Four scopes in one file: LGTM's secrets, the host's domain, the edge's network, and `GLITCHTIP_DOMAIN` — which exactly one compose file reads, and it is not this stack's. |
| `server/` | Four LGTM service configs *and* `traefik/`, which is the edge. Also one letter from `.env.server`, which holds different things. |
| `demo-verify` | The only noun-verb target among five `verify-*` ones, and it runs `verify-signals.sh`, so it does not match its own script. |
| `config-check` | A third convention again, alongside `glitchtip-config-check`. |
| `up` vs `demo-up` | The prefix means "*and also*", not "instead of". `demo-up` starts the LGTM stack too. Nothing says so. |

Underneath is a good architecture — five units the file names should make obvious and currently
do not:

| Unit | What it is | Deployed |
|---|---|---|
| **lgtm** | Prometheus, Loki, Tempo, Grafana | its own service |
| **glitchtip** | 5 containers + its own Postgres | its own service |
| **edge** | Traefik | only when the host has no proxy |
| **agent** | Alloy + exporters, copied into app repos | per app host |
| **demo** | exercises all of the above | local only |

Plus `sdk/` (the published `obstack` package), `scripts/`, `docs/`. The rest of Part A is making
the names match that.

## A1. Compose files stay at the repo root

The obvious "improvement" is to group each unit into a directory — `lgtm/compose.yml`,
`glitchtip/compose.yml`, and so on. **Do not do this.** Compose resolves relative paths — build
contexts, bind mounts, `env_file` — against the *project directory*, which is the directory of the
**first** `-f` file. An overlay set spanning two directories therefore resolves the second file's
paths against the first file's location.

This repo has already paid for that lesson once: `OBS_AGENT_DIR` exists solely because
`agent/compose.agent.yml` is overlaid from the root, and `make demo-up` sets it to `./agent` so the
`config.alloy` bind mount resolves (`Makefile:10`, `agent/compose.agent.yml:28`). Nesting three
units would multiply that by three.

`agent/compose.agent.yml` is the deliberate exception, because that directory is copied wholesale
into an app repo, where it is the only compose file present and the redundancy in its name is what
makes it self-describing.

So the grouping has to be carried by names, not directories.

## A2. Naming rule: `compose.<unit>[.<context>].yml`

Contexts are `local` (host ports and bind-mounted config), `edge` (route through Traefik instead of
direct), `macos`. Every unit is named; there is no implicit default.

| From | To |
|---|---|
| `compose.yml` | `compose.lgtm.yml` |
| `compose.local.yml` | `compose.lgtm.local.yml` |

Two files move. Every other compose file already obeys the rule — which is the point: the rule was
there, `compose.yml` was the exception hiding it.

**Why `lgtm`.** `server` is wrong: GlitchTip is server-side too, and the meaningful axis is
server-vs-agent. `signals` is tempting — it matches `verify-signals.sh` and the metrics/logs/traces
triad, with errors as a fourth thing — but it names a concept while its sibling `glitchtip` names a
product, and a scheme that mixes the two teaches nothing. `lgtm` is the recognised name for exactly
this set of components, so `compose.lgtm.yml` beside `compose.glitchtip.yml` is one consistent
idea. That it is Prometheus rather than Mimir is a wart the wider ecosystem already lives with.

## A3. Directories

| From | To | |
|---|---|---|
| `server/{prometheus,loki,tempo,grafana}/` | `lgtm/…` | matches the unit name and the compose file; build contexts at `compose.yml:60,112,132,156` |
| `server/traefik/secrets/` | **delete** | see below |

`server/traefik/secrets/` holds a `.gitkeep` and nothing else, and nothing references the path:
`grep -rn "traefik/secrets"` across compose files, scripts and docs returns only the `.gitignore`
rule that protects it and the TASKS.md line recording that rule being written. `compose.edge.yml`
mounts no secrets — TLS is ACME into the `traefik_acme` volume. Delete the directory and its two
`.gitignore` lines rather than moving it to an `edge/` that would then contain only it. The
`letsencrypt/` line in `.gitignore` is dead for the same reason.

No `glitchtip/` directory either: it bakes no config, so there is nothing to put in one.
Asymmetric, and honest about it.

## A4. Each unit's env file stands alone

This is the change that actually resolves the confusion, and it is worth more than the renames.

Today `compose.glitchtip.yml` reads `OBS_DOMAIN`, `OBS_EDGE_NETWORK` and `OBS_EDGE_EXTERNAL` from
`.env.server`, because locally `make glitchtip-up` passes both files. That makes the two stacks
look coupled, and it creates a shadowing trap: `.env.glitchtip` is the later `--env-file`, so any
key present in both silently wins. `.env.glitchtip.example:41-44` currently works around this by
shipping those four variables *commented out* with a paragraph explaining when to uncomment them —
which is the trap documented, not removed.

But **the duplication already exists in production and cannot be avoided.** Two services means two
environment UIs, and each has to carry the domain and the edge network regardless. So the files
should say so:

| File | Holds |
|---|---|
| `.env.lgtm` | `GF_ADMIN_*`, `GF_SERVER_ROOT_URL`, `INGEST_USERS`, `ACME_EMAIL`, `OBS_DOMAIN`, `OBS_EDGE_NETWORK`, `OBS_EDGE_EXTERNAL` |
| `.env.glitchtip` | `SECRET_KEY`, `POSTGRES_*`, `ALLOWED_HOSTS`, `GLITCHTIP_*`, `EMAIL_*`, `CELERY_*`, `OBS_DOMAIN`, `OBS_EDGE_NETWORK`, `OBS_EDGE_EXTERNAL` |
| `agent/.env.agent` | unchanged |

**Rule: no compose file depends on another unit's env file being loaded.** Each `make <unit>-up`
passes exactly one `--env-file`. The shadowing trap disappears, and so does the commented-out
block that papers over it — those four variables just belong in `.env.glitchtip.example`,
uncommented. `GLITCHTIP_DOMAIN` leaves `.env.server.example:27` entirely.

The cost is `OBS_DOMAIN` written in two places locally, where it is `localhost` in both and drift
is harmless. In production it was always going to be two places.

**No `.env.edge`.** The tempting third file does not survive contact with the code:
`compose.edge.yml` declares no networks of its own and references `edge` and `obs`, which only
`compose.yml` declares. It cannot render standalone and is always an overlay on the LGTM stack.
`ACME_EMAIL` therefore belongs in `.env.lgtm`, commented "only read when you add
`compose.edge.yml`" — the same treatment `GF_SERVER_ROOT_URL` already gets.

## A5. Break GlitchTip's dependency on an LGTM label

`compose.glitchtip.yml:209` references `obs-secure-headers@docker`, which is defined **only on the
Grafana container**, at `compose.yml:190-193`. Deployed on a host without the LGTM stack, Traefik
has no such middleware and fails the router closed with a 404. It works today only because both
stacks happen to share one Traefik on one box.

Give GlitchTip its own `obs-glitchtip-headers` with the same four settings, on its own container.
Four duplicated label lines buy a file that stands alone in function as well as in syntax — which
is what making it render standalone was for.

This is the highest-value item in Part A, it needs no rename, and it wants doing **before** the
GlitchTip Dokploy service is created.

After it, every compose file is self-contained with respect to Traefik. `obs-ingest-auth` and
`obs-ingest-ratelimit` are defined on Prometheus and referenced by Loki and Tempo, all inside
`compose.lgtm.yml`, so they are already fine.

## A6. Makefile

Two conventions, applied without exception.

**Lifecycle — `<unit>-<verb>`:**

```
lgtm-up        lgtm-down        lgtm-logs
glitchtip-up   glitchtip-down   glitchtip-logs
demo-up        demo-down        demo-logs
```

Drop bare `up`/`down`/`logs`. With two independently deployed stacks, `make up` cannot answer
"up what?" honestly. `make help` becomes the entry point.

No `edge-up`. Per A4 the edge cannot stand alone, and a target implying otherwise is the same lie
`compose.yml` told. `make lgtm-up EDGE=1` is the honest spelling, alongside the `demo-up EDGE=1`
that already exists.

**Assertions — `verify-<thing>`:**

```
verify-signals      (was demo-verify — and it already runs verify-signals.sh)
verify-ingest       verify-dashboards      verify-errors      verify-resilience
verify-config       (was config-check + glitchtip-config-check; renders both deployed shapes)
```

Everything else — `backup`, `restore`, `lint`, `test`, `help` — is already fine.

Two smaller things:

- `Makefile:90` hardcodes `observability_demo_db_data` and `observability_alloy_data`. The project
  name lives in `compose.yml:1`; put it in a `PROJECT := observability` variable and build the
  volume names from it, so there is one place to change.
- Each target's `##` help text should state what it *composes*, since that is the part no name can
  carry: `demo-up` starts the LGTM stack, the agent and the demo app.

## A7. Compose project name — a hazard to flag, not a change to make

`name: observability` is declared only in `compose.yml:1`. Deployed standalone,
`compose.glitchtip.yml`'s project name comes from the directory it is cloned into, so container and
volume names differ between the local overlay and the VPS.

Do **not** "fix" this by adding `name:` to `compose.glitchtip.yml`. On the local overlay the last
file's `name` wins, so `make glitchtip-up` would silently start a *second* project and GlitchTip
would no longer join the `obs` network the LGTM containers are on — which is the only thing that
makes `glitchtip-web:8000` reachable from a same-box app. Set the name on the deploy side (the
Dokploy service name) and document the asymmetry in `docs/operations.md`.

## A8. `postgres_exporter` → `postgres-exporter`

The one underscore among otherwise hyphenated service names (`agent/compose.agent.yml:95`,
`compose.demo.yml:51`). Safe to rename: nothing dials it by DNS. It is discovered from Docker
labels and scraped by container IP, and its `DATA_SOURCE_*` variables are unaffected. Update the
prose in `README.md`, `PLAN.md` and `agent/README.md` in the same commit.

## A9. `OBS_*` is three namespaces — document, don't rename

Three tiers wearing one prefix, with different readers and different failure modes:

| Tier | Examples | Read by | Read when |
|---|---|---|---|
| App identity | `OBS_APP`, `OBS_SERVICE`, `OBS_ENV`, `OBS_HOST` | the SDK, inside the container | at app start |
| Agent config | `OBS_PROM_URL`, `OBS_INGEST_*`, `OBS_DOCKER_NETWORK` | Alloy's `sys.env()`, inside the container | at agent start |
| Deploy shape | `OBS_DOMAIN`, `OBS_EDGE_NETWORK`, `OBS_EDGE_EXTERNAL` | **Compose, at render time** | at `up` |

The third tier is not observability configuration at all — it is placement. It is also the only
tier subject to the `$$`-doubling trap, because it is the only one Compose interpolates. That
distinction currently has to be inferred.

Renaming the tier would be churn across every doc, both env examples and a live Dokploy
environment. A four-row table in `docs/labels.md` costs nothing and buys the same understanding.

## A10. Docs

Low value, listed for completeness: `docs/deploy-vps.md` → `docs/deploy-server.md` (it describes
deploying to a PaaS as often as to a bare VPS), pairing with `docs/onboard-app.md` as two
imperatives naming the two halves. `local-dev.md`, `operations.md` and `labels.md` are already
right.

Content changes that are *not* optional, because the renames make them wrong:

- every `compose.yml` / `.env.server` reference across `docs/`, `README.md`, `agent/README.md`
- `docs/deploy-vps.md` §7's shape-A/shape-B split, which collapses once each env file stands alone
- the `EDGE=1` DNS-shadowing trap, still undocumented: `compose.edge.yml` gives its Traefik network
  aliases for `ingest.${OBS_DOMAIN}` and `grafana.${OBS_DOMAIN}`, so a leftover `EDGE=1` Traefik
  hijacks the real hostname in Docker DNS once `.env.lgtm` holds a real domain, and pushes fail
  against its self-signed certificate — presenting as a server-side certificate problem

---

# Part B — gaps and limitations

Ranked by what they cost. B1 through B3 are the ones that can produce an outage or a silent hole;
the rest are operability.

## B1. No log rotation on any container

`grep -rn "logging:" --include="*.yml" .` returns nothing. Every container therefore runs on
Docker's default `json-file` driver **with no `max-size` and no `max-file`**, and the logs grow
until the disk is full.

This is worse here than in a typical stack, for two compounding reasons. Traefik is configured with
`--accesslog=true --accesslog.format=json` (`compose.edge.yml:47-48`), so the edge writes one JSON
line per request forever. And every stack container carries `obs.logs: "false"` — deliberately, so
the stack does not ingest its own logs — which means nothing ships them, nothing reads them, and
nothing truncates them. They accumulate entirely unobserved on the box whose disk also holds
`prometheus_data`, `loki_data`, `tempo_data` and GlitchTip's Postgres.

**Do**: add a `logging:` block with `max-size` and `max-file` to every service in every compose
file — an anchor alongside `x-obs-labels` keeps it to one definition — and document setting
`log-driver`/`log-opts` defaults in `/etc/docker/daemon.json` in the deploy guide, so a container
added later inherits a bound rather than needing to remember one.

## B2. No memory limits on any container

`grep -rniE "mem_limit|deploy:|resources:"` also returns nothing. On a single VPS shared with the
apps being monitored, any one component can take the whole box: a wide Loki query, Tempo's
compactor, GlitchTip's Celery workers, or Prometheus on a cardinality spike.

The repo already knows this shape. `server/tempo/tempo-config.yaml` carries a do-not-re-enable note
about a measured 12 GB regression from `local-blocks`, and `CELERY_WORKER_AUTOSCALE` is capped at
`1,3` precisely so "GlitchTip does not end up competing with Prometheus for memory"
(`compose.glitchtip.yml:104-106`). Both are point fixes for a class of problem no service is
bounded against.

**Do**: set `mem_limit` per service with the sizing stated in `docs/operations.md`. Worth saying
explicitly in that doc: an OOMKilled Prometheus replays its WAL and loses a bounded amount; an
OOMKilled box loses everything on it, including the agent buffers on any app host that shares it.
A limit converts the second failure into the first.

## B3. The out-of-order window is narrower than the agent's buffer

`docs/operations.md` §1 has a table under the heading *"The windows that must stay wider than the
agent's buffers"*:

| Signal | Agent holds | Server must accept |
|---|---|---|
| metrics | 8h WAL | `out_of_order_time_window: 2h` |

Those two numbers do not satisfy that heading, and the table does not say so.

`PLAN.md` §10 risk 1 explains why the single-agent case survives anyway: the agent replays in order
into a head whose max time is the moment it went down, so the out-of-order path is barely used. It
then notes the window is what keeps *a second agent's* replay from being rejected against the
first's live writes — which is the multi-app case, and the multi-app case is the entire premise of
this repo. With two app hosts, an outage longer than two hours on one of them is a permanent gap,
and the agent reports success throughout.

**Do**: pick which number is authoritative and make the other follow. Raising
`out_of_order_time_window` to `8h` costs head-block memory in Prometheus and keeps the agent's
generous buffer; lowering the agent's `max_keepalive_time` to `2h` costs replay depth and keeps
Prometheus lean. Either is defensible; the current pair is not. Then rewrite the table so it states
the relationship it claims to enforce, and extend `make verify-resilience` with a second agent —
the case the single-agent test structurally cannot fail on.

## B4. No CI

`.github/workflows/cd.yml` is the only workflow, and it triggers on `v*.*.*` tags. So `make lint`,
`make test`, `make config-check`, `make glitchtip-config-check` and all five verify scripts run
exactly when someone remembers to run them.

The README makes a claim that nothing currently enforces:

> It runs every panel's query against the demo and fails on any that comes back empty, so a rename
> in `docs/labels.md` breaks the build rather than a graph three months later.

There is no build.

**Do**: add `ci.yml` on push and pull request, in two jobs.

1. Cheap, always: the SDK checks already written in `cd.yml` (extract to a reusable workflow rather
   than duplicating), `docker compose config` on every overlay combination the Makefile can
   produce, `shellcheck` on the nine scripts, `actionlint`.
2. The valuable one: `make demo-up && make verify-signals && make verify-dashboards` on
   `ubuntu-latest`. It is a heavier job, and it is the only thing that can catch a label rename, a
   dashboard that stopped resolving, or a broken `keepequal` port match before a deploy does.

`verify-ingest` (needs `EDGE=1` and a Traefik) and `verify-resilience` (twenty minutes) belong on a
nightly schedule rather than on every push.

## B5. No alerting

`server/grafana/provisioning/alerting/empty.yaml` is a stub containing `apiVersion: 1`. For a stack
whose stated purpose is watching several applications, dashboards-only means the users tell you
first — and `allowUiUpdates: false` means the dashboards nobody can edit are also the dashboards
nobody is watching between incidents.

`PLAN.md` §10 lists alerting as out of scope for v1, which was the right call for v1. It is the
largest remaining functional gap in the product, and it should be named as such rather than left as
a stub file.

**Do (v1.1)**: provision a minimal set as files in git, exactly as the dashboards are, so the same
"not UI state" property holds. Enough to start:

- per-app 5xx rate and p95 latency, from `fastapi_requests_*`, chained on `$app`/`$env` the way the
  dashboards already are
- **agent absent** — `absent()` over `fastapi_app_info` per app. This is the one that catches the
  failure mode the whole push architecture creates: an app that stops reporting looks identical to
  an app that is idle.
- `pg_up`, host disk free, and Prometheus' own `up`

One contact point, configured from the environment so the secret does not land in git.

## B6. The stack does not monitor itself

`server/prometheus/prometheus.yml` has exactly one scrape target: Prometheus. Loki, Tempo, Grafana
and Traefik all expose `/metrics` and none is scraped. Combined with `obs.logs: "false"` on every
stack container, the observability stack is the least observable thing on the box. If Loki stops
accepting writes, nothing anywhere says so — the agent's WAL absorbs it, then gives up at 8h.

The blanket log opt-out has a good local reason, stated at `compose.yml:47-52`: the server and the
demo share one box, so without it Loki ingests its own logs under `app=demo`. On a VPS with no demo
that reason does not apply, and the label permanently suppresses the logs you most want during an
incident.

**Do**: add static scrape targets for `loki:3100`, `tempo:3200`, `grafana:3000` and the edge, under
a `service` label that matches the taxonomy. Move the `obs.logs: "false"` opt-out out of the shared
`x-obs-labels` anchor and into the demo overlay, where its reason actually lives. Then B5's alert
set has something to fire on. `PLAN.md` §10 lists stack self-monitoring as out of scope for v1
alongside alerting; the two are the same piece of work and should be scoped together.

## B7. Backups are scripted but never scheduled

`scripts/backup.sh` is careful — three storage engines, three copy strategies, each justified. And
nothing runs it. On a VPS, an unscheduled backup script is a backup that does not exist.

Worse, `backups/` is gitignored and local to the box. Today the backup lives on the disk it exists
to protect.

**Do**: a systemd timer (or Dokploy scheduled task) in the deploy guide, plus an offsite copy step
— `rclone`, `restic`, or a bucket, whichever is least effort — and a restore drill recorded once so
the procedure in `docs/operations.md` §2 is known to work rather than believed to. The drill is the
part that gets skipped and the part that matters.

## B8. Nothing verifies the deployed stack

Every verify script talks to `127.0.0.1`. `scripts/verify-errors.sh` is already recorded in
`TASKS.md` as unable to check a deployed GlitchTip, for a good reason (the REST API needs a token
that only exists after a human has logged into the UI). But the gap is wider than that one script:
the repo's headline claim is *test locally, deploy to a VPS with no code changes*, and only the
first half is mechanised.

**Do**: a `scripts/verify-deployed.sh` taking a domain and a credential, asserting the small set of
things that are actually checkable from outside and that broke at least once each during M10:

- the TLS chain on `grafana.<domain>` and `errors.<domain>` is Let's Encrypt, not Traefik's
  self-signed fallback
- all three ingest paths return 401 without credentials, and a non-ingest path on
  `ingest.<domain>` returns 404
- one authenticated remote-write round trip succeeds, and the sample is queryable afterwards —
  which is the check that a mis-escaped `INGEST_USERS` hash cannot pass

That last one is worth the whole script. A doubled-`$` mistake presents as a 401 indistinguishable
from a wrong password, and it is a mistake this stack's own documentation warns about four separate
times.

## B9. Trust boundary — documented, not enforced

Deliberate, and worth stating in one place in `docs/operations.md` rather than inferring from three:

- **Any valid ingest credential can write any `app` label.** One credential per app is
  *attribution, not enforcement* — it identifies the pusher in Traefik's access log and lets one
  app be rotated alone. It does not stop a compromised app host from writing series under another
  app's name, or from deleting nothing but costing everything through cardinality.
- **Every Grafana user sees every app's data.** There is one admin account and no orgs or teams.
- **On a shared edge network, the basic auth is bypassable.** Already noted at `compose.yml:33-36`:
  anything else on `dokploy-network` reaches `prometheus:9090`, `loki:3100` and `tempo:4318`
  directly. The `obs` network stays private; the edge network is only as trusted as the host.

All three are correct for a single-owner box running applications you own, which is what this is.
Record the upgrade path — `X-Scope-OrgID` with Loki/Mimir multi-tenancy, and Grafana orgs per app —
as the thing to build when an app arrives that is not yours, not before.

**Cheap half worth doing now**: provision a read-only Grafana `Viewer` account, so routine use is
not the admin account whose password can only be set once.

## B10. State the image-pinning rule as a rule

Three tiers exist and the reasoning for each is sound, but it is spread across
`docs/operations.md` §5, `PLAN.md` §9 and four compose comments:

| Tier | Images | |
|---|---|---|
| Digest-pinned | `traefik`, `glitchtip`, `valkey` | edge and error store; `resolve-digests.sh --check` reports drift |
| Tag-pinned | `prometheus`, `loki`, `tempo`, `grafana`, `alloy`, `cadvisor`, `postgres-exporter` | specific patch tags, unchecked |
| Floating | `postgres:16-alpine`, `postgres:18-alpine` | deliberate; move only within a major |

**Do**: one paragraph in `docs/operations.md` §5 stating the tiers and what earns a place in each,
and extend `scripts/resolve-digests.sh --check` to report the tag-pinned tier as well — a moved
patch tag is unlikely, and silent when it happens. Lowest priority in Part B.

---

# Sequencing

Phase 0 is independent of the renames and worth doing whether or not they happen. It is also the
phase that has to land **before the GlitchTip Dokploy service is created**, because A5 and A4 are
precisely what make that service correct on a host where it might one day be the only thing
running.

Phase 1 is one commit: `git mv` throughout, with the doc updates included. A half-renamed repo is
worse than either end.

Everything in Part B after B1 and B3 is independent of everything else and can land in any order.
B5 (alerting) pairs with B6 (self-monitoring) — they are the same piece of work, and B5 has
nothing to fire on until B6 exists.

## The one live risk

Renaming `compose.yml` breaks the existing Dokploy service, whose compose-path field points at it.
Sequence deliberately:

1. Create and verify the **GlitchTip** service first — it is new, so it has nothing to migrate.
2. Push Phase 1.
3. Update the LGTM service's compose path to `compose.lgtm.yml` **before** its next deploy.

It fails loudly rather than silently if the order slips, but it does fail. `.env.server` →
`.env.lgtm` is a local-file rename only: Dokploy keys its environment by variable name, so nothing
needs re-pasting there.

## Not worth doing

- **Renaming `glitchtip` → `errors`.** The repo already uses `errors` for the capability
  (`errors.<domain>`, `verify-errors.sh`, `OBS_ERROR_DSN`) and `glitchtip` for the product's
  containers. That is a principled split — capability at the boundary, product where the product
  is — and collapsing it either way is churn.
- **Flattening `sdk/obstack/`.** One package under `sdk/` looks redundant, but it leaves room for a
  second and costs nothing.
- **Renaming the `OBS_*` deploy-shape variables.** See A9: document the three tiers instead.
- **Nesting compose files by unit.** See A1. This is the one that will look most tempting to a
  future reader, and it is the one that breaks.
