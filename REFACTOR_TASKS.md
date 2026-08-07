# Refactor Tasks

Design rationale lives in [`REFACTOR_PLAN.md`](./REFACTOR_PLAN.md); each item below cites the
section that justifies it. Tick items off as they land; this file is the source of truth for
progress across sessions.

Each phase ends with a **Verify** step. Do not start the next phase until the current one verifies.

Phases 0–3 change no behaviour except where noted in P0. Phase 4 does.

---

## P0 — Correctness, no renames

Independent of everything else. **All of it before the GlitchTip Dokploy service is created**
(§ Sequencing), because P0.1 and P0.2 are what make that service correct on a host where it might
one day be the only thing running.

- [x] **GlitchTip gets its own headers middleware** (§A5). Define `obs-glitchtip-headers` on the
      `glitchtip-web` container in `compose.glitchtip.yml` with the same four settings Grafana's
      `obs-secure-headers` carries (`compose.yml:190-193`), and point
      `traefik.http.routers.obs-glitchtip.middlewares` at it instead of `obs-secure-headers@docker`.
- [x] **`.env.glitchtip.example` carries the four deploy-shape variables uncommented** (§A4) —
      `OBS_DOMAIN`, `GLITCHTIP_DOMAIN`, `OBS_EDGE_NETWORK`, `OBS_EDGE_EXTERNAL`. Delete the
      "Deploying GlitchTip on its own" preamble that explains when to uncomment them; it documents
      a trap that this change removes.
- [x] **`GLITCHTIP_DOMAIN` leaves `.env.server.example`** (`:27`) — exactly one compose file reads
      it and it is not this stack's.
- [x] **`make glitchtip-up` stops passing `.env.server`** — and `compose.yml` with it, which was
      not in the original plan. `GT_FILES` carried `$(LOCAL_FILES)`, and `compose.yml` declares
      `${INGEST_USERS:?…}` and `${GF_ADMIN_PASSWORD:?…}`, so dropping only the env file aborts the
      render. `GT_FILES` is now the two GlitchTip files and one `--env-file`, which is also what a
      platform deploying `compose.glitchtip.yml` alone runs.

      Consequence: the project name no longer comes from `compose.yml:1`, so it is set as
      `COMPOSE_PROJECT_NAME=$(PROJECT)` on the command line — this is what keeps `glitchtip-web` on
      the LGTM stack's `obs` network. Deliberately *not* a `name:` in `compose.glitchtip.yml`, per
      §A7. `PROJECT := observability` landed here rather than in P2 since the variable was needed;
      the `demo-down` volume names now build from it too.
- [x] **Log rotation on every service** (§B1). An `x-obs-logging` anchor beside `x-obs-labels`
      carrying `driver: json-file` with `max-size` and `max-file`, applied in `compose.yml`,
      `compose.glitchtip.yml`, `compose.edge.yml`, `compose.demo.yml` and
      `agent/compose.agent.yml`. The agent file matters most — it is copied into app repos.
      10 MB × 3. `compose.demo.yml` only needed it on the three services it introduces; `alloy`,
      `cadvisor` and `postgres_exporter` are overlays on the agent file and inherit it from there.
- [x] **Document the `daemon.json` default** (§B1) — `log-driver` / `log-opts` in the deploy guide,
      so a container added later inherits a bound. In `docs/deploy-vps.md` §1, since it is a
      property of the box rather than of a deploy.
- [x] **Reconcile the out-of-order window with the agent's WAL** (§B3). **Prometheus moved**:
      `out_of_order_time_window: 2h` → `8h`, matching the agent's `max_keepalive_time`. The agent's
      buffer is authoritative because it is the number that says how long an outage can run, and
      widening is close to free — the out-of-order head holds only samples actually received out of
      order. *Behaviour change — the only one in P0.*
- [x] **Rewrite `docs/operations.md` §1's buffer table** so it states the relationship its own
      heading claims to enforce, and record which number is authoritative and why. Gained a margin
      column. `PLAN.md` §9 and §10 risk 1 carried the old value and now point at the change.
- [x] `agent/README.md`'s buffer/window table gets the same correction, plus the
      `agent/config.alloy` comment at the WAL block.

**Verify** — done, all green:
```bash
# GlitchTip renders and routes with no LGTM stack and no .env.server anywhere
make glitchtip-config-check
docker compose --env-file .env.glitchtip -f compose.glitchtip.yml config \
  | grep 'obs-glitchtip-headers'             # 4 definitions + 1 router reference
docker compose --env-file .env.glitchtip -f compose.glitchtip.yml config \
  | grep 'obs-secure-headers' && echo "FAIL: still depends on the LGTM stack"

# ...and still joins the LGTM project's network when run here
make glitchtip-up
docker network inspect observability_obs --format '{{range .Containers}}{{.Name}} {{end}}'
./scripts/verify-errors.sh

# Rotation reaches every container, in both stacks
docker compose --env-file .env.server -f compose.yml -f compose.local.yml config \
  | grep -c 'max-size'
docker compose --env-file .env.glitchtip -f compose.glitchtip.yml config \
  | grep -c 'max-size'
docker inspect --format '{{.Name}} {{.HostConfig.LogConfig.Config}}' $(docker ps -q)

make demo-up && make demo-verify && make verify-dashboards   # nothing regressed
OUTAGE_SECONDS=120 make verify-resilience
```

Two things found while verifying, neither caused by P0 and neither fixed here:

- **`agent/.env.agent` points the local demo at the VPS.** Since `9d33693` that file feeds
  interpolation, and it holds `https://ingest.obs.atick.dev` plus a real credential — so
  `make demo-up` makes the demo a *production* pusher and `make demo-verify` queries an empty
  `127.0.0.1:9090`. Verification here was run with the file moved aside. It is gitignored and
  local, but it means the repo's headline local loop does not work from this working tree.
- **`verify-resilience.sh`'s drain step waits on metrics only**, then checks logs immediately.
  The `loki.write` WAL replay is slower, so checks 5 and 6 can false-negative on a short outage —
  observed once, with the lines present in Loki when queried a minute later, and clean on a
  re-run. Worth making the drain wait per-signal.

---

## P1 — File and directory renames

**One commit**, `git mv` throughout so history follows, with the doc updates included. A
half-renamed repo is worse than either end (§ Sequencing).

- [ ] `git mv compose.yml compose.lgtm.yml` (§A2)
- [ ] `git mv compose.local.yml compose.lgtm.local.yml` (§A2)
- [ ] `git mv server/{prometheus,loki,tempo,grafana} lgtm/` (§A3); update the four `build:` contexts
      in `compose.lgtm.yml` (`:60,112,132,156`) and the four bind-mount paths in
      `compose.lgtm.local.yml`
- [ ] **Delete `server/traefik/`** and its two `.gitignore` lines, plus the dead `letsencrypt/`
      line (§A3). Verified unreferenced outside `.gitignore`.
- [ ] `git mv .env.server.example .env.lgtm.example`; rename the local `.env.server` to `.env.lgtm`
      (§A4). Add `ACME_EMAIL`'s "only read when you add `compose.edge.yml`" note.
- [ ] `Makefile` — `SERVER_ENV := --env-file .env.lgtm`, and the `env-check` message points at the
      new name
- [ ] **`postgres_exporter` → `postgres-exporter`** (§A8) in `agent/compose.agent.yml:95` and
      `compose.demo.yml:51`; prose in `README.md`, `PLAN.md`, `agent/README.md`
- [ ] Update every `compose.yml` / `compose.local.yml` / `.env.server` / `server/` reference across
      `README.md`, `agent/README.md`, `docs/`, `PLAN.md`, `TASKS.md`, and the header comments
      inside every compose file

**Verify**:
```bash
# No stale references anywhere
grep -rn "\.env\.server\|compose\.local\.yml\|server/prometheus\|server/loki\|server/tempo\|server/grafana\|server/traefik\|postgres_exporter" \
  --include="*.md" --include="*.yml" --include="*.sh" --include="Makefile" . \
  | grep -v "^./TASKS.md"        # historical entries there may stay

make config-check && make glitchtip-config-check
make demo-up && make demo-verify && make verify-dashboards
```
`TASKS.md` records what happened at the time and may keep the old names; everything describing the
repo *as it is now* must not.

---

## P2 — Makefile conventions

- [ ] Lifecycle targets become `<unit>-<verb>` (§A6): `lgtm-up`, `lgtm-down`, `lgtm-logs`; drop
      bare `up` / `down` / `logs`
- [ ] `demo-verify` → `verify-signals` (§A6) — it already runs `verify-signals.sh`
- [ ] `config-check` + `glitchtip-config-check` → one `verify-config` rendering both deployed shapes
- [ ] **No `edge-up`** — `make lgtm-up EDGE=1` is the spelling, because `compose.edge.yml` cannot
      render standalone (§A4, §A6)
- [ ] `PROJECT := observability` variable; build the volume names in the `demo-down` recipe from it
      (`Makefile:90`) instead of hardcoding `observability_demo_db_data` /
      `observability_alloy_data` (§A6)
- [ ] Every `##` help text states what the target *composes* — `demo-up` starts the LGTM stack, the
      agent and the demo app, and nothing currently says so
- [ ] Update the target names quoted in `README.md`, `docs/local-dev.md`, `docs/deploy-vps.md`,
      `docs/onboarding-an-app.md` and every script header that names one

**Verify**:
```bash
make help                                   # every target listed, every unit named
make lgtm-up && make lgtm-down
make demo-up && make verify-signals && make verify-dashboards && make demo-down
make verify-config
grep -rn "make up\b\|make down\b\|demo-verify\|config-check" --include="*.md" --include="*.sh" .
```

---

## P3 — Documentation

- [ ] **The `OBS_*` three-tier table into `docs/labels.md`** (§A9) — app identity, agent config,
      deploy shape; who reads each and when. The third tier is the only one Compose interpolates,
      which is the only one the `$$` trap applies to.
- [ ] `git mv docs/deploy-vps.md docs/deploy-server.md` (§A10)
- [ ] `git mv docs/onboarding-an-app.md docs/onboard-app.md` (§A10)
- [x] **Collapse `docs/deploy-server.md` §7's shape-A/shape-B split** — it exists only because the
      env files were entangled, which P0 fixed. Done in P0: the split had become actively wrong
      ("Do not uncomment them in shape A" inverted), so it was rewritten there rather than left to
      mislead for three phases. Only the filename part of this item is outstanding.
- [ ] **Document the `EDGE=1` DNS-shadowing trap** (§A10) — a leftover `EDGE=1` Traefik holds
      network aliases for `ingest.${OBS_DOMAIN}` and `grafana.${OBS_DOMAIN}`, so once `.env.lgtm`
      holds a real domain it hijacks those names in Docker DNS and pushes fail against its
      self-signed certificate, presenting as a server-side certificate problem
- [ ] **Document the project-name asymmetry** (§A7) in `docs/operations.md`, *including* the
      warning not to "fix" it by adding `name:` to `compose.glitchtip.yml`
- [ ] Update the documentation table in `README.md` for the two renamed files

**Verify**: read `docs/labels.md` and `docs/deploy-server.md` end to end; every link in
`README.md`'s table resolves; `grep -rn "deploy-vps\|onboarding-an-app" .` is clean.

---

## P4 — Hardening

Independent of each other and of everything above; land in any order. Behaviour changes throughout.

- [ ] **A second agent in `make verify-resilience`** (§B3) — the case the single-agent test
      structurally cannot fail on, and the case that motivated raising the out-of-order window in
      P0. One agent replays in order into a head whose max time is when it went down; only a second
      agent's replay lands against live writes.
- [ ] **Make `verify-resilience.sh`'s drain wait per-signal**, not on metrics alone. The
      `loki.write` WAL replay lags the `prometheus.remote_write` one, so checks 5 and 6 can report
      a gap that is not there — a false negative in the one test that exists to catch a real one.
- [ ] **`mem_limit` on every service** (§B2), with the sizing recorded in `docs/operations.md`,
      plus the note that a limit converts "the box dies" into "one service restarts and replays
      its WAL"
- [ ] **`.github/workflows/ci.yml`, cheap job** (§B4) — SDK checks extracted from `cd.yml` as a
      reusable workflow rather than duplicated; `docker compose config` on every overlay
      combination; `shellcheck` on the nine scripts; `actionlint`
- [ ] **`ci.yml`, demo job** (§B4) — `make demo-up && make verify-signals && make
      verify-dashboards` on `ubuntu-latest`. This is the one that makes the README's "a rename in
      `docs/labels.md` breaks the build" true.
- [ ] **Nightly schedule** for `verify-ingest` (needs `EDGE=1`) and `verify-resilience` (~20 min)
- [ ] **Scrape the stack itself** (§B6) — static targets for `loki:3100`, `tempo:3200`,
      `grafana:3000` and the edge in `lgtm/prometheus/prometheus.yml`, labelled to match the
      taxonomy
- [ ] **Move `obs.logs: "false"` out of the shared anchor** into the demo overlay (§B6), where its
      reason actually lives — on a VPS with no demo it suppresses the logs you most want
- [ ] **Schedule `scripts/backup.sh`** (§B7) — systemd timer or Dokploy scheduled task, in the
      deploy guide
- [ ] **Offsite copy step** (§B7) — `rclone` / `restic` / a bucket. Today the backup lives on the
      disk it protects.
- [ ] **Run a restore drill once** and record the result in `docs/operations.md` §2, so the
      procedure is known to work rather than believed to
- [ ] **`scripts/verify-deployed.sh`** (§B8) — takes a domain and a credential; asserts the TLS
      chain is Let's Encrypt on both hosts, the three ingest paths 401 without credentials, a
      non-ingest path on `ingest.<domain>` 404s, and one authenticated remote-write round trip
      lands and is queryable. That last assertion is the only thing that can catch a mis-escaped
      `INGEST_USERS` hash, which otherwise presents as an ordinary wrong password.
- [ ] **Trust-boundary section in `docs/operations.md`** (§B9) — label spoofing is unenforced,
      Grafana has no per-app separation, the shared edge network bypasses basic auth. Record the
      `X-Scope-OrgID` / Grafana-orgs upgrade path as the thing to build when an app arrives that
      is not yours.
- [ ] **Read-only Grafana `Viewer` account** (§B9) — the cheap half, so routine use is not the
      admin account whose password can only be set once
- [ ] **State the image-pinning tiers as a rule** in `docs/operations.md` §5, and extend
      `scripts/resolve-digests.sh --check` to report the tag-pinned tier too (§B10)

**Verify**: `ci.yml` green on a pull request; `docker stats` shows every container under its limit
after `make demo-up`; `verify-deployed.sh` passes against the live VPS; a restore drill completes
from an offsite copy.

---

## P5 — Alerting (v1.1)

Pairs with P4's self-monitoring — the same piece of work, and there is nothing to fire on until
those scrape targets exist (§B5, §B6). `PLAN.md` §10 scoped both out of v1 deliberately; this is
where they come back.

- [ ] Alert rules provisioned as **files in git**, replacing
      `server/grafana/provisioning/alerting/empty.yaml`, so the same "not UI state" property the
      dashboards hold applies here too
- [ ] Per-app 5xx rate and p95 latency from `fastapi_requests_*`, chained on `$app` / `$env`
- [ ] **Agent absent** — `absent()` over `fastapi_app_info` per app. The failure mode the push
      architecture creates: an app that stopped reporting looks exactly like an app that is idle.
- [ ] `pg_up`, host disk free, Prometheus' own `up`
- [ ] One contact point, configured from the environment so no secret lands in git
- [ ] `scripts/verify-alerts.sh` — assert each rule evaluates and resolves its variables, the same
      argument `verify-dashboards.sh` makes for panels

**Verify**: stop `demo-api` and confirm the agent-absent alert fires and then resolves; each rule
appears in Grafana under the expected folder.

---

## Deploy migration

The one live risk (§ The one live risk). Renaming `compose.yml` breaks the running Dokploy LGTM
service, whose compose-path field points at it. It fails loudly rather than silently if the order
slips, but it does fail.

- [ ] 1. Create and verify the **GlitchTip** Dokploy service at `errors.obs.atick.dev` — after P0,
      before P1. It is new, so it has nothing to migrate.
- [ ] 2. Push P1.
- [ ] 3. Update the LGTM service's compose path to `compose.lgtm.yml` **before** its next deploy.
- [ ] 4. Redeploy LGTM and confirm `grafana.obs.atick.dev` and all three ingest paths still answer.

`.env.server` → `.env.lgtm` needs nothing on the Dokploy side: it keys its environment by variable
name, not by file.
