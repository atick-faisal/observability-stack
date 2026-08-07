COMPOSE       ?= docker compose
# Declared in compose.lgtm.yml, and needed here because the GlitchTip targets no
# longer pass compose.lgtm.yml — see GT_ENVIRON — and because `docker volume rm`
# needs the prefix Compose builds volume names from.
PROJECT       := observability
SERVER_ENV    := --env-file .env.lgtm
# compose.lgtm.local.yml is what publishes the 127.0.0.1 ports and bind-mounts the
# configs. compose.lgtm.yml on its own is the deployed shape: no ports, config baked
# into the images.
LOCAL_FILES   := -f compose.lgtm.yml -f compose.lgtm.local.yml
SERVER_FILES  := $(SERVER_ENV) $(LOCAL_FILES)
# The demo runs agent/ unmodified — that is what makes "copy this directory into
# your app repo" a tested claim rather than a hope. OBS_AGENT_DIR is needed
# because Compose resolves relative paths against the first -f file's directory.
AGENT_FILES   := -f agent/compose.agent.yml
ifeq ($(shell uname -s),Darwin)
AGENT_FILES   += -f agent/compose.agent.macos.yml
endif
DEMO_ENV      := OBS_AGENT_DIR=./agent
# agent/.env.agent is the file a real app host puts the agent's settings in, and
# compose.agent.yml loads it with `env_file:`. That alone does nothing here:
# compose.demo.yml sets the same keys under `environment:`, which Compose ranks
# above env_file, so the file was read and discarded — authoritative-looking and
# inert. Rotating a credential in it changed nothing and failed as a 401, which
# on the server is indistinguishable from a mis-escaped hash.
#
# Passing it as a second --env-file makes it feed *interpolation* instead, so the
# ${OBS_INGEST_USER:-demo} defaults in compose.demo.yml give way to it. Later
# --env-file wins, hence the position after SERVER_ENV. Absent, the defaults
# apply and a fresh clone still comes up with no setup, which is what makes
# running agent/ unmodified a tested claim. Shell env still beats both.
#
# Caveat: Compose interpolates these values, so a literal $ in a password would
# be eaten. scripts/add-ingest-user.sh generates alphanumeric passwords for this
# reason, among others.
#
# That mechanism is also a loaded gun, which is why REMOTE=1 below exists: fill
# agent/.env.agent with a VPS URL and the demo silently becomes a production
# pusher, `make verify-signals` queries an empty local Prometheus, and nothing on
# screen says why. Point the demo at the VPS with the flag, not with the filename.
DEMO_ENV_FILE := $(if $(wildcard agent/.env.agent),--env-file agent/.env.agent,)
DEMO_FILES    := $(SERVER_ENV) $(DEMO_ENV_FILE) $(LOCAL_FILES) -f compose.demo.yml $(AGENT_FILES)
DEMO_PROFILES := --profile postgres --profile containers

# REMOTE=1 sends the demo's signals at the deployed stack instead of at localhost
# — the only way to exercise the real ingest path, credentials and TLS from here.
#
# Push-only: the VPS routes grafana.<domain> and three ingest PathPrefixes and
# nothing else, so its query APIs are not reachable and `make verify-signals` cannot
# follow. Confirm the push in Grafana. scripts/verify-deployed.sh is the assertion
# that belongs here and does not exist yet (REFACTOR_TASKS.md P4).
#
# Identity is unaffected — compose.demo.yml sets OBS_APP / OBS_ENV / OBS_HOST
# under `environment:`, which outranks any --env-file — so this arrives on the VPS
# as app=demo, env=local, which is what a test push should look like.
ifdef REMOTE
DEMO_ENV_FILE := --env-file agent/.env.agent.production
DEMO_FILES    := $(SERVER_ENV) $(DEMO_ENV_FILE) $(LOCAL_FILES) -f compose.demo.yml $(AGENT_FILES)
endif

# EDGE=1 routes the demo agent through Traefik on *.localhost instead of straight
# at the backends, so the labels, the basic auth and the path routing are all
# exercised by the same verify-signals.sh that passes on the direct path.
ifdef EDGE
DEMO_FILES    += -f compose.edge.yml -f compose.demo.edge.yml
DEMO_ENV      += ACME_CASERVER=https://acme-staging-v02.api.letsencrypt.org/directory
endif
# GlitchTip is five more containers and a second Postgres, so it is opt-in: its own
# compose file, its own env file, its own targets. Nothing in `lgtm-up` or `demo-up`
# pulls it in.
GLITCHTIP_FILES := -f compose.glitchtip.yml -f compose.glitchtip.local.yml
# compose.glitchtip.yml interpolates its settings rather than reading .env.glitchtip
# with `env_file:` — see that file's header for why. So the file has to be handed to
# Compose.
#
# One unit, one --env-file, and no other unit's compose file: what runs here is what
# a platform deploying compose.glitchtip.yml on its own runs. compose.lgtm.yml used to
# be in this list, which meant .env.lgtm had to be too — it declares
# ${INGEST_USERS:?...} and ${GF_ADMIN_PASSWORD:?...}, so its absence aborts the
# render — and .env.glitchtip then silently shadowed whatever the two files shared.
GT_ENV          := --env-file .env.glitchtip
GT_FILES        := $(GT_ENV) $(GLITCHTIP_FILES)
GT_SVCS         := glitchtip-postgres glitchtip-valkey glitchtip-migrate glitchtip-web glitchtip-worker
# The project name is what keeps these containers on the same `obs` network as the
# LGTM stack, which is the only thing that makes glitchtip-web:8000 reachable from an
# app on this box. It comes from compose.lgtm.yml's `name:` when that file is on the
# command line; here it is not, so it would otherwise come from the directory name.
#
# Set here rather than as `name:` in compose.glitchtip.yml on purpose. That file has
# to take its project name from whatever deploys it — a `name:` would pin the VPS to
# this repo's local choice, and on any overlay the last file's `name` wins.
#
# COMPOSE_IGNORE_ORPHANS because the LGTM containers carry this project's label and
# are not in these files, so Compose would offer to remove them.
GT_ENVIRON      := COMPOSE_PROJECT_NAME=$(PROJECT) COMPOSE_IGNORE_ORPHANS=true

SDK_DIR       := sdk/obstack
DEMO_DIRS     := demo/app demo/loadgen

.DEFAULT_GOAL := help

.PHONY: help lgtm-up lgtm-down lgtm-logs demo-up demo-down demo-logs verify-signals verify-ingest verify-dashboards verify-errors verify-resilience backup restore glitchtip-up glitchtip-down glitchtip-logs verify-config lint test env-check glitchtip-env-check remote-check

env-check:
	@test -f .env.lgtm || { echo "missing .env.lgtm — cp .env.lgtm.example .env.lgtm"; exit 1; }

# EDGE and REMOTE both rewrite the same three URLs, and compose.demo.edge.yml sets
# them under `environment:`, so EDGE would win silently. Fail instead.
remote-check:
	@test -z "$(REMOTE)" -o -f agent/.env.agent.production || { \
		echo "REMOTE=1 needs agent/.env.agent.production — cp agent/.env.agent.example agent/.env.agent.production and fill in the VPS URLs and credential"; exit 1; }
	@test -z "$(REMOTE)" -o -z "$(EDGE)" || { \
		echo "REMOTE=1 and EDGE=1 both set the agent's push URLs — pick one"; exit 1; }

glitchtip-env-check:
	@test -f .env.glitchtip || { echo "missing .env.glitchtip — cp .env.glitchtip.example .env.glitchtip"; exit 1; }

help: ## List available targets
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk -F':.*?## ' '{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

lgtm-up: env-check ## Start the LGTM stack (prometheus, loki, tempo, grafana)
	$(COMPOSE) $(SERVER_FILES) up -d --build

lgtm-down: ## Stop the LGTM stack, keeping volumes
	$(COMPOSE) $(SERVER_FILES) down

lgtm-logs: ## Tail LGTM stack logs (SVC=grafana to narrow)
	$(COMPOSE) $(SERVER_FILES) logs -f --tail=100 $(SVC)

demo-up: env-check remote-check ## Start the LGTM stack, the agent and the demo app (EDGE=1 through Traefik, REMOTE=1 pushes at the VPS)
	$(DEMO_ENV) $(COMPOSE) $(DEMO_FILES) $(DEMO_PROFILES) up -d --build

# Not `down -v`: that removes every volume in the merged project, including
# prometheus_data and grafana_data — and grafana.db holds the admin account,
# which is only ever created once.
demo-down: ## Stop the demo stack, removing only the demo's own volumes
	$(DEMO_ENV) $(COMPOSE) $(DEMO_FILES) $(DEMO_PROFILES) down
	-docker volume rm -f $(PROJECT)_demo_db_data $(PROJECT)_alloy_data

demo-logs: ## Tail demo stack logs (SVC=alloy to narrow)
	$(DEMO_ENV) $(COMPOSE) $(DEMO_FILES) $(DEMO_PROFILES) logs -f --tail=100 $(SVC)

verify-signals: ## Assert every signal arrives from the demo app
	./scripts/verify-signals.sh

verify-ingest: ## Assert the edge authenticates and routes (needs: make demo-up EDGE=1)
	./scripts/verify-ingest.sh

verify-dashboards: ## Assert every panel on every dashboard has data (needs: make demo-up)
	./scripts/verify-dashboards.sh

glitchtip-up: glitchtip-env-check ## Start GlitchTip on :8001 — 5 containers, its own Postgres, joins the LGTM stack's obs network
	$(GT_ENVIRON) $(COMPOSE) $(GT_FILES) up -d $(GT_SVCS)

# Not `down`: it removes every container carrying the project label, which is
# Prometheus, Loki, Tempo and Grafana too — the file list does not narrow that.
# Volumes are kept either way; glitchtip_pg_data is every error ever reported.
glitchtip-down: ## Stop and remove the GlitchTip containers, keeping their volumes
	$(GT_ENVIRON) $(COMPOSE) $(GT_FILES) rm -sf $(GT_SVCS)

glitchtip-logs: ## Tail GlitchTip logs (SVC=glitchtip-worker to narrow)
	$(GT_ENVIRON) $(COMPOSE) $(GT_FILES) logs -f --tail=100 $(or $(SVC),$(GT_SVCS))

verify-errors: ## Assert an unhandled exception reaches GlitchTip (needs: glitchtip-up, demo-up)
	./scripts/verify-errors.sh

# Takes about twenty minutes: it stops the server for fifteen and then waits for
# the agent to replay. OUTAGE_SECONDS=120 for a quick one.
verify-resilience: ## Assert a server outage leaves no gap in any signal (needs: make demo-up)
	./scripts/verify-resilience.sh

backup: ## Back up grafana.db and GlitchTip's database (--all adds the TSDBs)
	./scripts/backup.sh $(ARGS)

# No default target: the argument is which backup, and guessing that is the one
# mistake this pair must not make.
restore: ## Restore a backup — DIR=backups/<stamp>, then add ARGS=--yes
	@test -n "$(DIR)" || { echo "usage: make restore DIR=backups/<stamp> [ARGS=--yes]"; exit 1; }
	./scripts/restore.sh $(DIR) $(ARGS)

# Renders both deployed shapes — no ports, no bind mounts, edge network external —
# without needing that network to exist here. This is exactly what a deploy runs.
# compose.glitchtip.yml is rendered on its own, with no compose.lgtm.yml under it —
# the shape a platform that deploys one file per service renders. It borrows the
# `obs` and `edge` networks, and until they were declared here too this failed with
# "refers to undefined network obs" only on the deploy, never locally.
verify-config: env-check glitchtip-env-check ## Render both deployed compose shapes and check they resolve
	@OBS_EDGE_NETWORK=dokploy-network OBS_EDGE_EXTERNAL=true \
		$(COMPOSE) $(SERVER_ENV) -f compose.lgtm.yml config >/dev/null && echo "compose.lgtm.yml (deployed shape) OK"
	@OBS_EDGE_NETWORK=dokploy-network OBS_EDGE_EXTERNAL=true \
		$(COMPOSE) $(GT_ENV) -f compose.glitchtip.yml config >/dev/null \
		&& echo "compose.glitchtip.yml (deployed shape) OK"

lint: ## Type-check and lint the SDK and the demo
	cd $(SDK_DIR) && uv run mypy src && uv run ruff check .
	@for d in $(DEMO_DIRS); do \
		echo "==> $$d"; \
		uv run --directory $$d mypy main.py && uv run --directory $$d ruff check . || exit 1; \
	done

test: ## Run the SDK test suite
	cd $(SDK_DIR) && uv run pytest
