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
> `INGEST_USERS`, where it is handled for you — see §5.
>
> `.env.glitchtip` is **not** interpolated (it is handed to containers via `env_file:`), so `$`
> there is literal. Two files, two rules; that difference is why they are two files.

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

GlitchTip is five more containers and a second Postgres, so it is opt-in and separate.

```bash
cp .env.glitchtip.example .env.glitchtip     # SECRET_KEY, POSTGRES_PASSWORD, ALLOWED_HOSTS
make glitchtip-up
```

Set `GLITCHTIP_DOMAIN=https://errors.<domain>` in `.env.server` — DSNs and outbound links are
generated from it, and its scheme decides whether session cookies get the `Secure` flag.

Leave `ENABLE_USER_REGISTRATION=true` for the first signup, which becomes the first
organisation's owner, then set it false and `make glitchtip-up` again. Invite everyone else.

Set a real `EMAIL_URL` before anyone depends on this. The default `consolemail://` prints mail
to the container's stdout, and password-reset links are mail — with no transport, the only
account recovery is a shell on the box.

## 8. After the first deploy

- [`operations.md`](./operations.md) — retention, backups, cardinality, upgrades.
- [`onboarding-an-app.md`](./onboarding-an-app.md) — pointing the first app at `ingest.<domain>`.

Back up before you need to: `make backup` covers the two things that cannot be rebuilt from git,
`grafana.db` and GlitchTip's database. Dashboards are files in this repo, so the irreplaceable
state is smaller than it looks.
