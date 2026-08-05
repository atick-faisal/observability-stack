COMPOSE       ?= docker compose
SERVER_ENV    := --env-file .env.server
SERVER_FILES  := $(SERVER_ENV) -f compose.yml
# The demo runs agent/ unmodified — that is what makes "copy this directory into
# your app repo" a tested claim rather than a hope. OBS_AGENT_DIR is needed
# because Compose resolves relative paths against the first -f file's directory.
AGENT_FILES   := -f agent/compose.agent.yml
ifeq ($(shell uname -s),Darwin)
AGENT_FILES   += -f agent/compose.agent.macos.yml
endif
DEMO_ENV      := OBS_AGENT_DIR=./agent
DEMO_FILES    := $(SERVER_ENV) -f compose.yml -f compose.demo.yml $(AGENT_FILES)
DEMO_PROFILES := --profile postgres --profile containers
SDK_DIR       := sdk/obskit
DEMO_DIRS     := demo/app demo/loadgen

.DEFAULT_GOAL := help

.PHONY: help up down logs demo-up demo-down demo-logs demo-verify lint test env-check

env-check:
	@test -f .env.server || { echo "missing .env.server — cp .env.server.example .env.server"; exit 1; }

help: ## List available targets
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk -F':.*?## ' '{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

up: env-check ## Start the server stack (traefik, prometheus, loki, tempo, grafana)
	$(COMPOSE) $(SERVER_FILES) up -d

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

demo-verify: ## Assert all five signals arrive from the demo app
	./scripts/verify-signals.sh

lint: ## Type-check and lint the SDK and the demo
	cd $(SDK_DIR) && uv run mypy src && uv run ruff check .
	@for d in $(DEMO_DIRS); do \
		echo "==> $$d"; \
		uv run --directory $$d mypy main.py && uv run --directory $$d ruff check . || exit 1; \
	done

test: ## Run the SDK test suite
	cd $(SDK_DIR) && uv run pytest
