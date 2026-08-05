COMPOSE       ?= docker compose
SERVER_ENV    := --env-file .env.server
# compose.local.yml is what publishes the 127.0.0.1 ports and bind-mounts the
# configs. compose.yml on its own is the deployed shape: no ports, config baked
# into the images.
LOCAL_FILES   := -f compose.yml -f compose.local.yml
SERVER_FILES  := $(SERVER_ENV) $(LOCAL_FILES)
# The demo runs agent/ unmodified — that is what makes "copy this directory into
# your app repo" a tested claim rather than a hope. OBS_AGENT_DIR is needed
# because Compose resolves relative paths against the first -f file's directory.
AGENT_FILES   := -f agent/compose.agent.yml
ifeq ($(shell uname -s),Darwin)
AGENT_FILES   += -f agent/compose.agent.macos.yml
endif
DEMO_ENV      := OBS_AGENT_DIR=./agent
DEMO_FILES    := $(SERVER_ENV) $(LOCAL_FILES) -f compose.demo.yml $(AGENT_FILES)
DEMO_PROFILES := --profile postgres --profile containers

# EDGE=1 routes the demo agent through Traefik on *.localhost instead of straight
# at the backends, so the labels, the basic auth and the path routing are all
# exercised by the same verify-signals.sh that passes on the direct path.
ifdef EDGE
DEMO_FILES    += -f compose.edge.yml -f compose.demo.edge.yml
DEMO_ENV      += ACME_CASERVER=https://acme-staging-v02.api.letsencrypt.org/directory
endif
# GlitchTip is five more containers and a second Postgres, so it is opt-in: its own
# compose file, its own env file, its own targets. Nothing in `up` or `demo-up`
# pulls it in. GT_SVCS is named explicitly on every command because these files
# overlay the same Compose project as everything else — `down` here would otherwise
# take Grafana with it.
GLITCHTIP_FILES := -f compose.glitchtip.yml -f compose.glitchtip.local.yml
GT_FILES        := $(SERVER_FILES) $(GLITCHTIP_FILES)
GT_SVCS         := glitchtip-postgres glitchtip-valkey glitchtip-migrate glitchtip-web glitchtip-worker

SDK_DIR       := sdk/obskit
DEMO_DIRS     := demo/app demo/loadgen

.DEFAULT_GOAL := help

.PHONY: help up down logs demo-up demo-down demo-logs demo-verify verify-ingest verify-dashboards verify-errors glitchtip-up glitchtip-down glitchtip-logs config-check lint test env-check glitchtip-env-check

env-check:
	@test -f .env.server || { echo "missing .env.server — cp .env.server.example .env.server"; exit 1; }

glitchtip-env-check:
	@test -f .env.glitchtip || { echo "missing .env.glitchtip — cp .env.glitchtip.example .env.glitchtip"; exit 1; }

help: ## List available targets
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk -F':.*?## ' '{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

up: env-check ## Start the server stack (prometheus, loki, tempo, grafana)
	$(COMPOSE) $(SERVER_FILES) up -d --build

down: ## Stop the server stack, keeping volumes
	$(COMPOSE) $(SERVER_FILES) down

logs: ## Tail server stack logs (SVC=grafana to narrow)
	$(COMPOSE) $(SERVER_FILES) logs -f --tail=100 $(SVC)

demo-up: env-check ## Start the server stack plus the local end-to-end demo
	$(DEMO_ENV) $(COMPOSE) $(DEMO_FILES) $(DEMO_PROFILES) up -d --build

# Not `down -v`: that removes every volume in the merged project, including
# prometheus_data and grafana_data — and grafana.db holds the admin account,
# which is only ever created once.
demo-down: ## Stop the demo stack, removing only the demo's own volumes
	$(DEMO_ENV) $(COMPOSE) $(DEMO_FILES) $(DEMO_PROFILES) down
	-docker volume rm -f observability_demo_db_data observability_alloy_data

demo-logs: ## Tail demo stack logs (SVC=alloy to narrow)
	$(DEMO_ENV) $(COMPOSE) $(DEMO_FILES) $(DEMO_PROFILES) logs -f --tail=100 $(SVC)

demo-verify: ## Assert every signal arrives from the demo app
	./scripts/verify-signals.sh

verify-ingest: ## Assert the edge authenticates and routes (needs: make demo-up EDGE=1)
	./scripts/verify-ingest.sh

verify-dashboards: ## Assert every panel on every dashboard has data (needs: make demo-up)
	./scripts/verify-dashboards.sh

glitchtip-up: env-check glitchtip-env-check ## Start GlitchTip alongside the server stack, on :8001
	COMPOSE_IGNORE_ORPHANS=true $(COMPOSE) $(GT_FILES) up -d $(GT_SVCS)

# Not `down`: these files overlay the `observability` project, so a plain down would
# stop Prometheus, Loki, Tempo and Grafana too. Volumes are kept — glitchtip_pg_data
# is every error ever reported.
glitchtip-down: ## Stop and remove the GlitchTip containers, keeping their volumes
	COMPOSE_IGNORE_ORPHANS=true $(COMPOSE) $(GT_FILES) rm -sf $(GT_SVCS)

glitchtip-logs: ## Tail GlitchTip logs (SVC=glitchtip-worker to narrow)
	COMPOSE_IGNORE_ORPHANS=true $(COMPOSE) $(GT_FILES) logs -f --tail=100 $(or $(SVC),$(GT_SVCS))

verify-errors: ## Assert an unhandled exception reaches GlitchTip (needs: glitchtip-up, demo-up)
	./scripts/verify-errors.sh

# Renders the deployed shape — no ports, no bind mounts, edge network external —
# without needing that network to exist here. This is exactly what a deploy runs.
config-check: env-check ## Render the deployed compose shape and check it resolves
	@OBS_EDGE_NETWORK=dokploy-network OBS_EDGE_EXTERNAL=true \
		$(COMPOSE) $(SERVER_ENV) -f compose.yml config >/dev/null && echo "compose.yml (deployed shape) OK"

lint: ## Type-check and lint the SDK and the demo
	cd $(SDK_DIR) && uv run mypy src && uv run ruff check .
	@for d in $(DEMO_DIRS); do \
		echo "==> $$d"; \
		uv run --directory $$d mypy main.py && uv run --directory $$d ruff check . || exit 1; \
	done

test: ## Run the SDK test suite
	cd $(SDK_DIR) && uv run pytest
