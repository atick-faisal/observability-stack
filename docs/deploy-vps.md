# Deploying the server

One VPS serves every app. This is the half that receives; [`onboarding-an-app.md`](./onboarding-an-app.md)
is the half that sends.

The whole deployed shape is `compose.yml` on its own — nothing published, each service building a
small image with its config baked in, routing driven by container labels. Everything below is
either filling in `.env.server` or deciding which of two edge shapes you are in.

---

## 1. What the box needs

| | |
|---|---|
| RAM | 4 GB works for a handful of apps. Prometheus and Tempo's metrics-generator are the two that grow. |
| Disk | 60 GB. The TSDBs are capped (§4) but GlitchTip's Postgres and the Docker images are not counted in that cap. |
| Ports | `80` and `443` reachable from the internet. `80` is not optional — ACME's HTTP-01 challenge uses it, and the redirect to HTTPS keeps it in play. |
| Software | Docker Engine with the Compose plugin. Nothing else — no Python, no Go, no Grafana packages. |
| Clock | `chrony` or `systemd-timesyncd`, running. See §6; this is the failure that looks like a different failure. |

Nothing in the stack needs root beyond Docker itself, and no service runs as `user: "0"`.

## 2. DNS

Three A records, all pointing at the VPS:

```
grafana.<domain>    A    <vps-ip>
ingest.<domain>     A    <vps-ip>
errors.<domain>     A    <vps-ip>     # only if you run GlitchTip
```

They must resolve **before** the first `up`. Traefik requests a certificate per hostname on
startup, and Let's Encrypt counts **5 failed validations per hostname per hour** against you on
the production CA — so a stack brought up against DNS that has not propagated locks itself out
of certificates for the rest of the hour.

`ingest.<domain>` is the only one apps ever talk to. It exposes exactly three paths, each
authenticated; everything else on that host 404s (§5).

## 3. Configure

```bash
git clone <this-repo> observability-stack && cd observability-stack
cp .env.server.example .env.server
```

`.env.server.example` documents every variable inline. Four matter on a first deploy:

| Variable | |
|---|---|
| `OBS_DOMAIN` | The bare domain. The three hostnames are derived from it. |
| `GF_ADMIN_PASSWORD` | Read **once**, when Grafana first creates the admin user. Editing it later does nothing. |
| `GF_SERVER_ROOT_URL` | Set to `https://grafana.<domain>`. Share and alert links are built from it, so a wrong value produces links to `localhost`. |
| `ACME_EMAIL` | Only read by `compose.edge.yml`. Let's Encrypt rejects an address whose domain is not a real TLD. |

> **Do not put a `$` in `GF_ADMIN_PASSWORD`.** Compose interpolates values it reads from
> `--env-file`, so `$$` collapses to one `$` and `$NAME` expands to that variable's value.
> Measured: `GF_ADMIN_PASSWORD=ab$$cd` reaches Grafana as `ab$cd`. What you type is not what
> gets set, and because the admin user is created exactly once, the first login failure is also
> the point at which fixing it means destroying `grafana_data`. The same trap applies to
> `INGEST_USERS`, where it is handled for you — see §5, and to `.env.glitchtip` (§7). One rule,
> everywhere: **anything Compose reads from an `--env-file` or an environment UI is interpolated.**
> Keep generated secrets alphanumeric and it never fires.

Then mint one ingest credential per app+env:

```bash
./scripts/add-ingest-user.sh myapp-production
```

It prints both halves — what goes in the app host's `.env.agent`, and the bcrypt hash to append
to `INGEST_USERS` here, already `$$`-doubled. It edits neither file: `.env.server` may already
hold other credentials, and a script that rewrites a secrets file is a script that can lose one.

**Replace the default `INGEST_USERS` value before this is reachable.** It ships as `demo:demo`,
which is what the local demo pushes with.

## 4. Which edge

Two shapes, and picking the wrong one costs you a fight over `:443`.

**A — nothing else on the box owns `:80`/`:443`.** Use ours:

```bash
docker compose --env-file .env.server -f compose.yml -f compose.edge.yml up -d --build
```

**B — the host already runs a proxy** (Dokploy, Coolify, an existing Traefik). Deploy
`compose.yml` alone and point it at that proxy's network:

```bash
# in .env.server, or the platform's environment UI
OBS_EDGE_NETWORK=dokploy-network
OBS_EDGE_EXTERNAL=true
```

```bash
docker compose --env-file .env.server -f compose.yml up -d --build
```

The `traefik.*` labels are inert without a Traefik reading them, and Traefik ignores containers
that are not on its own network — so one set of labels serves both shapes and there is no second
compose file to keep in sync.

> **What shape B shares.** Everything else on that edge network can reach Prometheus, Loki and
> Tempo *directly*, bypassing the basic auth Traefik applies. The `obs` network stays private,
> but the edge network is only as trusted as the host. That is the stated single-owner-box
> assumption in `PLAN.md` §7, and on a shared host it is a real exposure rather than a
> theoretical one.

A second ACME client contending for `:443` buys nothing, which is why B is not simply "run ours
anyway". On a single box the isolation argument is imaginary — the box dying takes both.

Check what a deploy will actually render, without needing that network to exist locally:

```bash
make config-check
```

## 5. Verify the deploy

```bash
curl -sI https://grafana.<domain> | head -1                  # 200, and a Let's Encrypt chain
curl -sI -o /dev/null -w '%{http_code}\n' https://ingest.<domain>/api/v1/write   # 401
```

A `401` there is the point of the whole edge. Then, from an app host with a real credential,
`scripts/verify-ingest.sh` asserts the full matrix: a wrong credential gets 401, a right one
reaches the backend, and every path that is not one of the three ingest paths 404s — including
`/api/v1/query`, `/-/quit` and `/api/v1/admin/tsdb/delete_series`.

The three ingest paths are the native upstream ones, unrewritten:

| Path | Backend | |
|---|---|---|
| `/api/v1/write` | Prometheus | remote-write |
| `/loki/api/v1/push` | Loki | |
| `/v1/traces` | Tempo | OTLP/**HTTP**, not gRPC — gRPC through Traefik needs h2c passthrough and end-to-end HTTP/2 |

A rate limit of 100 req/s average, 200 burst, per client IP sits in front of all three. It is a
blast-radius guard, not a quota: an agent in a retry loop is indistinguishable from an attack,
and the cost of being wrong is dropped samples the agent's WAL replays anyway.

## 6. Check the clock

```bash
timedatectl status | grep -E 'System clock synchronized|NTP service'
```

Both must say `yes`/`active`. This is worth its own step because skew does not fail loudly:

- Loki rejects samples too far in the future outright, so an app host running fast simply stops
  having logs — with a 400 in the agent's log and nothing at all in Grafana.
- A host running slow interleaves its lines wrongly against every other host's, and the log view
  looks fine. You only find it by noticing a response logged before its request.

The agent's disk buffers make this worse rather than better, because they replay with the
original timestamps: a skewed host's backlog arrives skewed. Fix the clock before backfilling.

## 7. Error tracking, optionally

GlitchTip is five more containers and a second Postgres, so it is opt-in and separate. Its
settings live in `.env.glitchtip`, which is only ever GlitchTip's — nothing in it is shared with
`.env.server`, so it can be handed over or rotated on its own.

```bash
cp .env.glitchtip.example .env.glitchtip     # SECRET_KEY, POSTGRES_PASSWORD, ALLOWED_HOSTS
```

**`.env.glitchtip` is the whole environment.** Nothing is supplied by `.env.server`, including the
four values that describe *where* GlitchTip runs — `OBS_DOMAIN`, `GLITCHTIP_DOMAIN`,
`OBS_EDGE_NETWORK` and `OBS_EDGE_EXTERNAL`. They are duplicated between the two files because two
independently deployed services means two environments, and each has to say where it runs.

```
OBS_DOMAIN=example.com
GLITCHTIP_DOMAIN=https://errors.example.com
OBS_EDGE_NETWORK=dokploy-network
OBS_EDGE_EXTERNAL=true
```

> **Do not skip them.** Every one has a default that is right locally and wrong on a VPS, and none
> of them fails the render. Rendered with them unset you get ``Host(`errors.localhost`)``, an
> `observability_edge` bridge the platform's Traefik is not on, and `http://localhost:8001` as the
> base of every DSN GlitchTip issues — a deploy that comes up healthy and is unreachable.

`GLITCHTIP_DOMAIN` is what DSNs and outbound links are generated from, and its scheme decides
whether session cookies get the `Secure` flag. Its host must be `errors.${OBS_DOMAIN}`, which is
what the Traefik label routes and what `ALLOWED_HOSTS` has to list.

**On an existing platform.** Dokploy and Coolify deploy one compose file per service, so add a
second service pointing at `compose.glitchtip.yml` and paste `.env.glitchtip` into its environment.
It renders and routes on its own — `make glitchtip-config-check` asserts that, and is worth running
before you push.

> **A separate service is a separate Compose project, so `obs` is project-local.**
> `glitchtip-web:8000` is *not* reachable from the LGTM project's containers — apps report over
> `https://errors.<domain>` instead, which is what an app on any other host does anyway. Nothing
> in the stack depends on the in-network path.

**On the same box, one project.** `make glitchtip-up` is the local shape: it passes
`COMPOSE_PROJECT_NAME=observability`, so `glitchtip-web` joins the same `obs` network as everything
else and an app here can report to `http://<key>@glitchtip-web:8000/1` without leaving the host.
The project name is set on the command line rather than as `name:` in `compose.glitchtip.yml`,
because that file has to take its name from whatever deploys it.

Leave `ENABLE_USER_REGISTRATION=true` for the first signup, which becomes the first
organisation's owner, then set it false and bring it up again. Invite everyone else. With it
false from the start there is no way in short of `manage.py createsuperuser` on the box.

Set a real `EMAIL_URL` before anyone depends on this. The default `consolemail://` prints mail
to the container's stdout, and password-reset links are mail — with no transport, the only
account recovery is a shell on the box. It is also the one value here you did not generate, so
it is where the `$$` rule from §3 actually bites — as does percent-encoding a `#` or `@`, since
it is a URL.

Verify:

```bash
curl -sI https://errors.<domain> | head -1        # 200, Let's Encrypt chain
curl -s  https://errors.<domain>/_health/         # ok
```

Then register, create an organisation and a project, and point an app at the DSN it hands you.
`scripts/verify-errors.sh` asserts the whole path end to end — an unhandled exception in the demo
becoming an issue tagged with the same `app`/`env`/`host` the dashboards filter by — but it reads
through `docker compose exec` and `localhost:8001`, so it only checks a **local** GlitchTip. For
a deployed one, run it on the VPS or check the UI.

## 8. After the first deploy

- [`operations.md`](./operations.md) — retention, backups, cardinality, upgrades.
- [`onboarding-an-app.md`](./onboarding-an-app.md) — pointing the first app at `ingest.<domain>`.

Back up before you need to: `make backup` covers the two things that cannot be rebuilt from git,
`grafana.db` and GlitchTip's database. Dashboards are files in this repo, so the irreplaceable
state is smaller than it looks.
