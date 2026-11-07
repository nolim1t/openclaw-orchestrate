#!/usr/bin/env bash
#
# Makefile for OpenClaw Triad Orchestration (v3 — secrets-stash aware)
# Place this in ~/openclaw-orchestrate/Makefile
#
# KEY CHANGE vs v2: a persistent secrets stash OUTSIDE the state dir.
#   env/.env.real-secrets  — your actual API keys, lives here forever.
#   env/.env.example       — shape-only template (no real keys), safe to commit.
# 'make init' now seeds in priority order: stash first, example second.
# 'make secrets-save' snapshots the live .env into the stash.
# 'make secrets-restore' pushes the stash back into the state dir.
#
# IMPORTANT: the rebuild script overwrites this Makefile from the pinned
# tag on every run — commit + tag any change here (Layer 3), or the
# fetch silently reverts it.
#
# USAGE:
#   make init            # Create dirs, seed .env (stash > example)
#   make secrets-save    # Snapshot live .env -> env/.env.real-secrets
#   make secrets-restore # Push stash -> live .env (no questions asked)
#   make setup           # Regenerate the stack using .env values
#   make docker-build    # Build the container image
#   make docker-up       # Start the Gateway
#   make docker-down     # Stop containers (state preserved)
#   make clean           # Remove containers + image (state preserved)
#   make wipe            # DANGER: remove ALL state (typed confirmation)
#   make logs            # Follow Gateway logs live
#   make logs-system     # Last 100 log lines
#   make shell           # Shell into the container
#   make status          # Deployment + state directory health
#   make agents          # Show the configured roster
#   make help            # This reference
#

SHELL := /bin/bash
.PHONY: init secrets-save secrets-restore setup docker-build docker-up docker-down clean wipe logs logs-system shell status agents help

# =============================================================================
# CONFIGURATION (override via environment or .env file)
# =============================================================================

OPENCLAW_STATE_DIR ?= $(HOME)/.openclaw
ORCHESTRATE_DIR := $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))

COMPOSE_FILE ?= $(OPENCLAW_STATE_DIR)/docker-compose.yml
COMPOSE_ENV ?= $(OPENCLAW_STATE_DIR)/docker.env
ENV_FILE ?= $(OPENCLAW_STATE_DIR)/.env

# Secrets lifecycle: stash survives `rm -rf ~/.openclaw` AND survives the
# rebuild's pinned-tag fetch (only Makefile + scripts/* are fetched).
ENV_DIR ?= $(ORCHESTRATE_DIR)/env
SECRETS_STASH ?= $(ENV_DIR)/.env.real-secrets
SECRETS_EXAMPLE ?= $(ENV_DIR)/.env.example

DOCKER_ENABLE ?= true

# =============================================================================
# INITIALIZATION
# =============================================================================

init:
	@echo "🚀 Initializing OpenClaw orchestration..."
	@mkdir -p $(ORCHESTRATE_DIR)/scripts $(ENV_DIR)
	@mkdir -p $(OPENCLAW_STATE_DIR)
	@if [ ! -f "$(ORCHESTRATE_DIR)/scripts/setup-openclaw-triad.sh" ]; then \
		echo "   ⚠  Setup script missing — place setup-openclaw-triad.sh in scripts/"; \
	else \
		echo "   ✓ Setup script present"; \
	fi
	@if [ -f "$(ENV_FILE)" ]; then \
		echo "   ✓ .env already present (preserved)"; \
	elif [ -f "$(SECRETS_STASH)" ]; then \
		cp $(SECRETS_STASH) $(ENV_FILE); \
		chmod 600 $(ENV_FILE); \
		echo "   ✓ Seeded $(ENV_FILE) from real-secrets STASH"; \
		echo "   ⚠  Never a bad moment: 'make secrets-save' to refresh the stash"; \
	elif [ -f "$(SECRETS_EXAMPLE)" ]; then \
		cp $(SECRETS_EXAMPLE) $(ENV_FILE); \
		chmod 600 $(ENV_FILE); \
		echo "   ✓ Seeded $(ENV_FILE) from EXAMPLE template"; \
		echo "   ⚠  Keys are placeholders — fill in NANOGPT_API_KEY now"; \
	else \
		echo "   ⚠  No stash and no example — 'make setup' will seed a skeleton .env"; \
	fi
	@chmod 600 $(ENV_FILE) 2>/dev/null || true
	@echo "✓ Init complete. Edit $(ENV_FILE) then run 'make setup'"

# =============================================================================
# SECRETS STASH — survive state-dir wipes and rebuilds
# =============================================================================

secrets-save:
	@test -f "$(ENV_FILE)" || { echo "❌ No live .env to snapshot ($(ENV_FILE))"; exit 1; }
	@mkdir -p $(ENV_DIR)
	@cp $(ENV_FILE) $(SECRETS_STASH)
	@chmod 600 $(SECRETS_STASH)
	@echo "🔐 Stashed live secrets -> $(SECRETS_STASH) ($(shell wc -c < $(ENV_FILE) | tr -d ' ') bytes)"

secrets-restore:
	@test -f "$(SECRETS_STASH)" || { echo "❌ No stash at $(SECRETS_STASH) — nothing to restore"; exit 1; }
	@mkdir -p $(OPENCLAW_STATE_DIR)
	@cp $(SECRETS_STASH) $(ENV_FILE)
	@chmod 600 $(ENV_FILE)
	@echo "🔓 Restored stash -> $(ENV_FILE)"

# =============================================================================
# SETUP — sources .env so ALL variables (roster, preset, keys) reach the script
# =============================================================================

setup:
	@echo "📦 Running OpenClaw setup (reading $(ENV_FILE))..."
	@if [ ! -f "$(ENV_FILE)" ]; then \
		echo "❌ $(ENV_FILE) not found. Run 'make init' and fill in your keys."; \
		exit 1; \
	fi
	@set -a && . "$(ENV_FILE)" && set +a && \
		export OPENCLAW_STATE_DIR="$(OPENCLAW_STATE_DIR)" && \
		$(ORCHESTRATE_DIR)/scripts/setup-openclaw-triad.sh --non-interactive \
			$(if $(filter true,$(DOCKER_ENABLE)),--docker,)
	@echo "✓ Setup complete — re-run 'make setup' any time you change .env"

# =============================================================================
# DEPLOYMENT
# =============================================================================

docker-build:
	@echo "🐳 Building Docker image..."
	@test -f "$(COMPOSE_FILE)" || { echo "❌ docker-compose.yml not found. Run 'make setup' first."; exit 1; }
	cd $(OPENCLAW_STATE_DIR) && \
		docker compose --env-file $(COMPOSE_ENV) build --pull
	@echo "✓ Build complete"

docker-up:
	@echo "🚀 Starting OpenClaw gateway..."
	@test -f "$(COMPOSE_FILE)" || { echo "❌ docker-compose.yml not found. Run 'make setup' first."; exit 1; }
	cd $(OPENCLAW_STATE_DIR) && \
		docker compose --env-file $(COMPOSE_ENV) up -d --force-recreate
	@sleep 8
	@$(MAKE) --no-print-directory status

docker-down:
	@echo "🛑 Stopping containers..."
	@test -f "$(COMPOSE_FILE)" || { echo "⚠️  No compose file found, skipping"; exit 0; }
	cd $(OPENCLAW_STATE_DIR) && docker compose --env-file $(COMPOSE_ENV) down
	@echo "✓ Containers stopped"

# =============================================================================
# CLEANUP
# =============================================================================

clean:
	@echo "🧹 Removing containers and image (preserving state)..."
	@test -f "$(COMPOSE_FILE)" || { echo "⚠️  No compose file found"; exit 0; }
	cd $(OPENCLAW_STATE_DIR) && docker compose --env-file $(COMPOSE_ENV) down
	@docker rmi openclaw-triad:local 2>/dev/null || true
	@echo "✓ Cleanup complete (state preserved in $(OPENCLAW_STATE_DIR))"

wipe:
	@echo "☣️  DANGER: This will remove ALL OpenClaw state — journals, ledgers, calibration!"
	@echo "    Your secrets stash ($(SECRETS_STASH)) survives, but live agent data does not."
	@read -p "Type 'WIPE' to confirm: " CONFIRM && \
		[ "$$CONFIRM" = "WIPE" ] || { echo "Aborted"; exit 1; }
	rm -rf $(OPENCLAW_STATE_DIR)
	@echo "✓ Complete wipe done. Run 'make init' then 'make secrets-restore' for a from-scratch boot"

# =============================================================================
# MONITORING & DEBUGGING
# =============================================================================

logs:
	@test -f "$(COMPOSE_FILE)" || { echo "❌ No compose file found"; exit 1; }
	cd $(OPENCLAW_STATE_DIR) && docker compose --env-file $(COMPOSE_ENV) logs -f

logs-system:
	@test -f "$(COMPOSE_FILE)" || { echo "❌ No compose file found"; exit 1; }
	cd $(OPENCLAW_STATE_DIR) && docker compose --env-file $(COMPOSE_ENV) logs --tail=100

shell:
	@test -f "$(COMPOSE_FILE)" || { echo "❌ No compose file found"; exit 1; }
	cd $(OPENCLAW_STATE_DIR) && docker compose --env-file $(COMPOSE_ENV) exec openclaw-triad /bin/bash

agents:
	@echo "🤖 Configured roster (from $(ENV_FILE)):"
	@grep -E '^AGENT_ROSTER' $(ENV_FILE) 2>/dev/null || echo "   AGENT_ROSTER not set — script default applies"
	@grep -E '^PERSONALITY_PRESET' $(ENV_FILE) 2>/dev/null || true

status:
	@echo "📊 Deployment status:"
	@test -f "$(COMPOSE_FILE)" || { echo "   No Docker deployment found"; return 0; }
	cd $(OPENCLAW_STATE_DIR) && docker compose --env-file $(COMPOSE_ENV) ps || true
	@echo ""
	@echo "📁 State directory: $(OPENCLAW_STATE_DIR)"
	@test -f "$(OPENCLAW_STATE_DIR)/openclaw.json" && \
		echo "   Config: present" || echo "   Config: MISSING"
	@test -f "$(ENV_FILE)" && \
		echo "   Secrets: present ($(ENV_FILE))" || \
		echo "   Secrets: MISSING (try 'make secrets-restore')"
	@test -f "$(SECRETS_STASH)" && \
		echo "   Stash:   present ($(SECRETS_STASH))" || \
		echo "   Stash:   not yet saved (run 'make secrets-save')"
	@test -d "$(OPENCLAW_STATE_DIR)/agents" && \
		echo "   Agent dirs: $$(ls -1 $(OPENCLAW_STATE_DIR)/agents 2>/dev/null | tr '\n' ' ')" || \
		echo "   Agents: not initialized"
	@test -f "$(OPENCLAW_STATE_DIR)/state/openclaw.sqlite" && \
		echo "   Runtime DB: present" || echo "   Runtime DB: not yet created"

# =============================================================================
# HELP
# =============================================================================

help:
	@echo "OpenClaw Triad Orchestration"
	@echo "============================"
	@echo ""
	@echo "Commands:"
	@echo "  make init            Initialize dirs, seed .env (stash > example)"
	@echo "  make secrets-save    Snapshot live .env -> env/.env.real-secrets"
	@echo "  make secrets-restore Restore stash -> live .env"
	@echo "  make setup           Regenerate the stack using .env values"
	@echo "  make docker-build    Build the container image"
	@echo "  make docker-up        Start the gateway"
	@echo "  make docker-down      Stop containers"
	@echo "  make clean           Remove containers + image (state preserved)"
	@echo "  make wipe            DANGER: remove ALL state (confirm required)"
	@echo "  make logs            Follow gateway logs"
	@echo "  make logs-system     Last 100 lines of logs"
	@echo "  make shell           Shell into the container"
	@echo "  make agents          Show configured roster and preset"
	@echo "  make status          Deployment and state health (incl. stash)"
	@echo ""
	@echo "From-scratch bootstrap:"
	@echo "  1. make init                  # seeds .env from stash if present"
	@echo "  2. make secrets-restore       # if .env keys look stale"
	@echo "  3. Edit $(ENV_FILE):"
	@echo "       NANOGPT_API_KEY, OPENCLAW_GATEWAY_TOKEN,"
	@echo "       AGENT_ROSTER, PERSONALITY_PRESET"
	@echo "  4. make secrets-save          # persist your keys for next wipe"
	@echo "  5. make setup"
	@echo "  6. make docker-build && make docker-up"
	@echo ""
