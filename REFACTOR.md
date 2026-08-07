# Refactor plan — naming and structure

Written from the position of someone cloning this repo for the first time, who has to work out
what deploys where without reading the history. Nothing here changes behaviour; it changes what
the repo tells you about itself.

The one hard constraint: **the LGTM stack and GlitchTip deploy as two separate services**, each
with its own environment, on a host whose proxy already exists. Every decision below follows from
taking that seriously rather than treating it as an afterthought.

---

## 1. What a newcomer sees today

```
compose.yml  compose.local.yml  compose.edge.yml  compose.demo.yml
compose.demo.edge.yml  compose.glitchtip.yml  compose.glitchtip.local.yml
.env.server.example  .env.glitchtip.example
agent/  demo/  docs/  scripts/  sdk/  server/  observability/
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
| `observability/config.alloy` | Stray, untracked. Fallout from `OBS_AGENT_DIR`'s default when a `demo-up` ran without it. |

## 2. The design underneath

Five units, which the file names should make obvious and currently do not:

| Unit | What it is | Deployed |
|---|---|---|
| **lgtm** | Prometheus, Loki, Tempo, Grafana | its own service |
| **glitchtip** | 5 containers + its own Postgres | its own service |
| **edge** | Traefik | only when the host has no proxy |
| **agent** | Alloy + exporters, copied into app repos | per app host |
| **demo** | exercises all of the above | local only |

Plus `sdk/` (the published `obstack` package), `scripts/`, `docs/`.

That is a good architecture. The rest of this document is making the names match it.

---

## 3. Decision: compose files stay at the repo root

The obvious "improvement" is to group each unit into a directory — `lgtm/compose.yml`,
`glitchtip/compose.yml`, and so on. **Do not do this.** Compose resolves relative paths — build
contexts, bind mounts, `env_file` — against the *project directory*, which is the directory of the
**first** `-f` file. An overlay set spanning two directories therefore resolves the second file's
paths against the first file's location.

This repo has already paid for that lesson once: `OBS_AGENT_DIR` exists solely because
`agent/compose.agent.yml` is overlaid from the root, and `make demo-up` sets it to `./agent` so the
`config.alloy` bind mount resolves. Nesting three units would multiply that by three.

`agent/compose.agent.yml` is the deliberate exception, because that directory is copied wholesale
into an app repo, where it is the only compose file present and the redundancy in its name is what
makes it self-describing.

So the grouping has to be carried by names, not directories.

---

## 4. Naming scheme

**Rule: `compose.<unit>[.<context>].yml`.** Contexts are `local` (host ports and bind-mounted
config), `edge` (route through Traefik instead of direct), `macos`. Every unit is named; there is
no implicit default.

| From | To |
|---|---|
| `compose.yml` | `compose.lgtm.yml` |
| `compose.local.yml` | `compose.lgtm.local.yml` |
| `compose.glitchtip.yml` | unchanged |
| `compose.glitchtip.local.yml` | unchanged |
| `compose.edge.yml` | unchanged |
| `compose.demo.yml` | unchanged |
| `compose.demo.edge.yml` | unchanged |
| `agent/compose.agent.yml` | unchanged |
| `agent/compose.agent.macos.yml` | unchanged |

Two files move. Everything else already obeys the rule — which is the point: the rule was there,
`compose.yml` was the exception hiding it.

### Why `lgtm` and not `signals` or `server`

`server` is wrong: GlitchTip is server-side too, and the meaningful axis is server-vs-agent.
`signals` is tempting — it matches `verify-signals.sh` and the metrics/logs/traces triad, with
errors as a fourth thing — but it names a concept while its sibling `glitchtip` names a product,
and a scheme that mixes the two teaches nothing. `lgtm` is the recognised name for exactly this
set of components, so `compose.lgtm.yml` beside `compose.glitchtip.yml` is one consistent idea.
That it is Prometheus rather than Mimir is a wart the wider ecosystem already lives with.

### Directories

| From | To | |
|---|---|---|
| `server/{prometheus,loki,tempo,grafana}/` | `lgtm/…` | matches the unit name and the compose file |
| `server/traefik/` | `edge/` | Traefik is the edge, not the server. Contains only `secrets/.gitkeep`; **check before moving** — this path has been deliberately left alone before. |
| `observability/` | delete | stray, untracked, one file |

No `glitchtip/` directory: it bakes no config, so there is nothing to put in one. Asymmetric, and
honest about it.

---

## 5. Each unit's env file is self-contained

This is the change that actually resolves the confusion, and it is worth more than the renames.

Today `compose.glitchtip.yml` reads `OBS_DOMAIN`, `OBS_EDGE_NETWORK` and `OBS_EDGE_EXTERNAL` from
`.env.server` — because locally `make glitchtip-up` passes both files. That makes the two stacks
look coupled, and it creates a shadowing trap: `.env.glitchtip` is the later `--env-file`, so any
key present in both silently wins.

But **the duplication already exists in production and cannot be avoided.** Two services means two
environment UIs, and each has to carry the domain and the edge network regardless. So the files
should say so:

| File | Holds |
|---|---|
| `.env.lgtm` | `GF_ADMIN_*`, `INGEST_USERS`, `OBS_DOMAIN`, `OBS_EDGE_NETWORK`, `OBS_EDGE_EXTERNAL` |
| `.env.glitchtip` | `SECRET_KEY`, `POSTGRES_*`, `ALLOWED_HOSTS`, `GLITCHTIP_DOMAIN`, `OBS_DOMAIN`, `OBS_EDGE_NETWORK`, `OBS_EDGE_EXTERNAL` |
| `.env.edge` | `ACME_EMAIL`, `OBS_DOMAIN` |
| `agent/.env.agent` | unchanged |

**Rule: no compose file depends on another unit's env file being loaded.** Each `make <unit>-up`
passes exactly one `--env-file`. The shadowing trap disappears, and so does the commented-out
"only when deploying standalone" block that currently papers over it — those four variables just
belong in `.env.glitchtip.example`, uncommented.

The cost is `OBS_DOMAIN` written in three places locally, where it is `localhost` in all three and
drift is harmless. In production it was always going to be three places.

## 6. Break the GlitchTip → LGTM middleware dependency

`compose.glitchtip.yml` references `obs-secure-headers@docker`, which is defined **only on the
Grafana container** in `compose.yml`. Deployed on a host without the LGTM stack, Traefik has no
such middleware and fails the router closed with a 404. It works today only because both stacks
happen to share one Traefik.

Give GlitchTip its own `obs-glitchtip-headers` with the same four settings, on its own container.
Four duplicated label lines buy a file that stands alone in function as well as in syntax — which
is what making it render standalone was for.

After this, every compose file is self-contained with respect to Traefik. `obs-ingest-auth` and
`obs-ingest-ratelimit` are defined on Prometheus and referenced by Loki and Tempo, all inside
`compose.lgtm.yml`, so they are already fine.

---

## 7. Makefile

Two conventions, applied without exception.

**Lifecycle — `<unit>-<verb>`:**

```
lgtm-up        lgtm-down        lgtm-logs
glitchtip-up   glitchtip-down   glitchtip-logs
demo-up        demo-down        demo-logs
edge-up        edge-down
```

Drop bare `up`/`down`/`logs`. With two independently deployed stacks, `make up` cannot answer
"up what?" honestly. `make help` becomes the entry point. (If the muscle memory is worth keeping,
`up` as an alias for `lgtm-up` is defensible — but it is the same lie `compose.yml` told.)

`edge-up`/`edge-down` are new: the edge is currently reachable only as `EDGE=1` on `demo-up`,
which is why `compose.edge.yml` once carried a comment pointing at a `make edge-up` that had never
existed.

**Assertions — `verify-<thing>`:**

```
verify-signals      (was demo-verify — and it already runs verify-signals.sh)
verify-ingest       verify-dashboards      verify-errors      verify-resilience
verify-config       (was config-check + glitchtip-config-check; renders both deployed shapes)
```

Everything else — `backup`, `restore`, `lint`, `test`, `help` — is already fine.

Each target's `##` help text should state what it *composes*, since that is the part no name can
carry: `demo-up` starts the LGTM stack, the agent and the demo app.

---

## 8. Docs

Low value, listed for completeness. `docs/deploy-vps.md` describes deploying to a PaaS as often as
to a bare VPS; `docs/deploy-server.md` pairs with `docs/onboard-app.md` as two imperatives naming
the two halves. `local-dev.md`, `operations.md` and `labels.md` are already right.

Content changes that are *not* optional, because the renames make them wrong:

- every `compose.yml` / `.env.server` reference across `docs/`, `README.md`, `agent/README.md`
- `docs/deploy-vps.md` §7's shape-A/shape-B split, which simplifies once each env file stands alone
- the `EDGE=1` DNS-shadowing trap, still undocumented: `compose.edge.yml` gives its Traefik network
  aliases for `ingest.${OBS_DOMAIN}` and `grafana.${OBS_DOMAIN}`, so a leftover `EDGE=1` Traefik
  hijacks the real hostname in Docker DNS once `.env.lgtm` holds a real domain, and pushes fail
  against its self-signed cert — presenting as a server-side certificate problem

---

## 9. Order of work

Phase 0 and the rest are independent; 0 is worth doing whether or not the renames happen.

**Phase 0 — correctness, no renames.**
1. GlitchTip gets its own `obs-glitchtip-headers` middleware (§6).
2. `.env.glitchtip.example` carries the four deploy-shape variables uncommented; `make
   glitchtip-up` stops passing `.env.server` (§5).
3. `GLITCHTIP_DOMAIN` out of `.env.server.example`.
4. Delete `observability/`.

**Phase 1 — file and directory renames (§4).** One commit, `git mv` throughout so history follows.
Land it with the doc updates in the same commit; a half-renamed repo is worse than either end.

**Phase 2 — Makefile (§7).**

**Phase 3 — docs (§8).**

### The one live risk

Renaming `compose.yml` breaks the existing Dokploy service, whose compose-path field points at it.
Sequence deliberately:

1. Create and verify the **GlitchTip** service first — it is new, so it has nothing to migrate.
2. Push Phase 1.
3. Update the LGTM service's compose path to `compose.lgtm.yml` **before** its next deploy.

It fails loudly rather than silently if the order slips, but it does fail. `.env.server` →
`.env.lgtm` is a local-file rename only: Dokploy keys its environment by variable name, so nothing
needs re-pasting there.

### Not worth doing

- **Renaming `glitchtip` → `errors`.** The repo already uses `errors` for the capability
  (`errors.<domain>`, `verify-errors.sh`, `OBS_ERROR_DSN`) and `glitchtip` for the product's
  containers. That is a principled split — capability at the boundary, product where the product
  is — and collapsing it either way is churn.
- **Flattening `sdk/obstack/`.** One package under `sdk/` looks redundant, but it leaves room for a
  second and costs nothing.
- **Nesting compose files by unit.** See §3. This is the one that will look most tempting to a
  future reader, and it is the one that breaks.
