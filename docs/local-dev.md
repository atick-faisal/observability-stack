# Local development

The whole stack runs on a laptop — server, agent, a demo app, a database, and a load generator —
and every verification script in this repo is written against that local run. If a change cannot
be demonstrated here, it is not finished.

```bash
cp .env.lgtm.example .env.lgtm    # set GF_ADMIN_PASSWORD; OBS_DOMAIN can stay example.com
make demo-up
```

> [!IMPORTANT]
> **Every env file the Makefile reads is local.** `.env.lgtm`, `.env.glitchtip` and
> `agent/.env.agent` hold local values and nothing else. What goes into a deploy lives beside them
> with a `.production` suffix — `.env.glitchtip.production`, `agent/.env.agent.production` — and is
> read by nothing: a paste buffer for the platform's environment UI, and a record of what was
> pasted. Both halves are gitignored by the `.env*` rule.
>
> This is not tidiness. `agent/.env.agent` is loaded automatically by `make demo-up`, so a VPS
> URL in it turns the demo into a production pusher and leaves every verify script querying an
> empty local Prometheus — a failure with nothing on screen to explain it. Point the demo at the
> VPS with the flag instead:
>
> ```bash
> make demo-up REMOTE=1        # reads agent/.env.agent.production
> ```
>
> Push-only. The VPS routes `grafana.<domain>` and three ingest paths and nothing else, so its
> query APIs are unreachable and `make verify-signals` cannot follow — confirm it in Grafana. It
> arrives labelled `app=demo, env=local`, since `compose.demo.yml` sets identity under
> `environment:`, which outranks any `--env-file`.

Grafana is on <http://localhost:3000>. Don't check anything until Loki says it is ready — **poll,
do not sleep**:

```bash
until curl -sf localhost:3100/ready >/dev/null; do sleep 3; done
```

Until then both Loki and Tempo answer `503 Ingester not ready: waiting for 15s after being ready`.
Measured at **35s** on a plain `docker restart`, but it is not reliably 35s: on one full
`demo-up` against volumes carrying a fortnight of test data it stayed 503 for **several minutes**
while Tempo was already serving. That is why the loop above exists and no script in this repo
sleeps a fixed number of seconds — the first scrape also has to land before any dashboard has
data, so "it looks empty" and "it is not up yet" are the same picture.

---

## What `make demo-up` actually starts

Three compose files plus the agent's, merged into one project called `observability`:

| File | Adds |
|---|---|
| `compose.lgtm.yml` | The deployed shape: prometheus, loki, tempo, grafana. No ports, config baked into the images. |
| `compose.lgtm.local.yml` | `127.0.0.1` ports, and bind-mounts the configs from the working tree. |
| `compose.demo.yml` | `demo-api`, `demo-db`, `demo-loadgen`, and the agent's settings. |
| `agent/compose.agent.yml` | Alloy, cAdvisor, `postgres-exporter` — **used unmodified**. |

That last point is the reason the demo exists. `agent/` is what you copy into a real app repo, so
running it here without edits is what makes "copy this directory" a tested claim rather than a
hope. Everything app-specific lives in `compose.demo.yml`.

The bind mounts are what makes dashboard work bearable: Grafana's file provider re-reads
`lgtm/grafana/dashboards/` every 30 seconds, so an edit shows up without a rebuild. The
deployed stack has no such mount and reads the baked copy — which is also why
`make verify-config` exists, to render the deployed shape and prove it still resolves.

| | |
|---|---|
| Grafana | <http://localhost:3000> |
| Prometheus | <http://localhost:9090> |
| Loki | <http://localhost:3100> |
| Tempo | <http://localhost:3200>, OTLP `:4317` / `:4318` |
| demo-api | <http://localhost:8000> — `/ok`, `/slow`, `/db`, `/items/{id}`, `/boom`, plus `/health` and `/metrics` |
| Alloy's UI | <http://localhost:12345> — `/graph` shows every component and what it discovered |

## Verifying

Each script asserts something different, and each exits non-zero on failure. Run them after the
stack has been up for a couple of minutes.

```bash
make verify-signals       # scripts/verify-signals.sh
```
Seven checks: metrics arrive with the label contract intact, `pg_up` is present, log streams carry
exactly the six labels in `labels.md` §3.2, a `trace_id` from a Loki line resolves in Tempo,
exemplars exist, span-metrics use the same label vocabulary and join with `fastapi_requests_total`,
and Tempo's service graph has a `demo-loadgen → demo-api` edge.

```bash
make verify-dashboards    # every panel target across all three dashboards
```
Extracts every `expr` from every dashboard JSON and asserts each returns data. This exists because
an expression that returns nothing renders as an empty graph, which is indistinguishable from a
quiet period — and the dashboards are provisioned read-only, so nobody notices one has gone blank
by trying to edit it. A rename in `labels.md` breaks this rather than a graph three months later.

```bash
make demo-up EDGE=1 && make verify-ingest
```
Routes the agent through Traefik on `*.localhost` instead of straight at the backends, so the
labels, the basic auth, the path routing and the rate limit are all exercised by the same stack.
Expect ACME failures in Traefik's log: Let's Encrypt cannot issue for `.localhost`, so Traefik
serves its built-in self-signed certificate and the script uses `curl -k`. `ACME_CASERVER` is
overridden to the staging CA in this mode, because the production CA counts 5 failed validations
per hostname per hour against you.

> [!WARNING]
> **The DNS-shadowing trap.** `compose.edge.yml` gives its Traefik container network aliases for
> `ingest.${OBS_DOMAIN}` and `grafana.${OBS_DOMAIN}` on the `obs` network, so the demo agent can
> reach it by the same hostname a real deploy would use. If `.env.lgtm`'s `OBS_DOMAIN` is ever
> set to a real domain locally — testing against production-shaped values, say — and an `EDGE=1`
> Traefik is left running, Docker's embedded DNS resolves that real hostname to the local,
> self-signed Traefik for **any** other container on the `obs` network, including a real agent
> pointed at the VPS. The push then fails against a self-signed certificate, which presents as a
> server-side certificate problem rather than the local shadowing it actually is.
> `make demo-down` before switching `OBS_DOMAIN` or dropping `EDGE=1` avoids it.

```bash
make verify-resilience    # ~22 minutes
```
Stops prometheus, loki, tempo and grafana for fifteen minutes with the app still serving, then
asserts no gap in any signal. `OUTAGE_SECONDS=120 make verify-resilience` for a quick one. The
run takes longer than the outage because `remote_write`'s reconnect backoff dominates the drain —
measured at 382s to replay to the end of a 901s window. `make demo-up SECOND_AGENT=1` first adds
checks 8/9, which force the out-of-order path a single agent can't reach — see `agent/README.md`.

```bash
make hooks                # once per clone — installs the pre-commit hooks
make lint && make test    # pyright + ruff on three projects, 41 tests
```

## Error tracking

Opt-in, and five more containers:

```bash
cp .env.glitchtip.example .env.glitchtip     # SECRET_KEY, POSTGRES_PASSWORD
make glitchtip-up                            # 127.0.0.1:8001
./scripts/verify-errors.sh --bootstrap       # mints an organisation, a project and a DSN
OBS_ERROR_DSN=<the printed DSN> make demo-up
make verify-errors
```

The DSN's host is `glitchtip-web:8000`, not `localhost:8001` — it is dialled from inside the
`demo-api` container over the `obs` network. `ALLOWED_HOSTS` in `.env.glitchtip` has to contain
`glitchtip-web` for the same reason: Django rejects a `Host` header it does not know with a 400,
before any view runs.

## Stopping

```bash
make demo-down      # removes only the demo's own volumes
```

> [!CAUTION]
> Deliberately not `down -v`. That would remove every volume in the merged project, including
> `grafana_data` — and `grafana.db` holds the admin account, which is created exactly once from
> `GF_ADMIN_PASSWORD` and never re-read.

## macOS caveats

Both are local-only artifacts; a Linux VPS needs neither.

**cAdvisor needs `compose.agent.macos.yml`.** Docker Desktop runs containerd with the overlayfs
snapshotter, where cAdvisor cannot resolve a container's read-write layer and fails with
`failed to identify the read-write layer ID`. The overlay points it at the containerd socket
instead, which is the documented workaround (google/cadvisor#3709). The Makefile adds this file
automatically when `uname -s` is `Darwin`.

**`prometheus.exporter.unix` reports the Docker Desktop VM**, not macOS. Host CPU, memory and
disk on the Infrastructure dashboard are the VM's. They are real numbers about the wrong machine.

**No `timeout(1)`, and `date` is BSD.** `date -u -r <epoch>` here, `date -u -d @<epoch>` on Linux.
The scripts in `scripts/` handle both; anything new should too.

**`docker buildx imagetools inspect` fails unattended.** It authenticates through the Docker
credential helper, which needs an unlocked login keychain — so it errors with
`error getting credentials` in any non-interactive session. `scripts/resolve-digests.sh` talks to
the registry anonymously for that reason.

## Working on the stack itself

**Dashboards** are files in `lgtm/grafana/dashboards/<Folder>/`. Edit, wait 30s, reload. They
are provisioned `allowUiUpdates: false`, so the UI will not save over them — a `POST` to
`/api/dashboards/db` returns `400 Cannot save provisioned dashboard`. Note that `meta.canSave`
still reports `true`; in Grafana 13 that field reflects the user's permission, not the
provisioning lock, so the write attempt is the only real test.

**Configs** under `lgtm/*/` are bind-mounted locally, so `docker compose restart <svc>` picks
them up. A `make lgtm-up` rebuild is only needed to prove the baked-in copy also works — which
`make verify-config` and a `--build` do.

**`config.alloy`** is not bind-mounted; the agent image bakes it. Rebuild with
`make demo-up` after editing, and watch `make demo-logs SVC=alloy` — `alloy validate` checks the
component graph but does not build components, so a bad selector passes validation and fails at
startup.

**Adding a label or renaming one** means touching `docs/labels.md` first. It is the contract, and
`verify-signals.sh` and `verify-dashboards.sh` both assert against it. If they disagree with the
document, they are wrong.

**Documentation** builds with `make docs` (serves the site on :8000) and `make docs-build` (the
`mkdocs build --strict` that CI runs — strict, so a dead internal link fails it).

> [!WARNING]
> **`docs/index.md`, `docs/agent.md` and `docs/sdk.md` are generated, and gitignored.**
> `scripts/assemble-docs.sh` builds them from `README.md`, `agent/README.md` and
> `sdk/obstack/README.md` — the canonical copies, because those are what GitHub, the agent
> directory and PyPI render. Editing the page under `docs/` instead of its source loses the edit
> at the next build, without an error. Every other page under `docs/` is authored where it sits.
