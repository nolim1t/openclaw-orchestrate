#!/usr/bin/env bash
#
# Makefile for OpenClaw Triad Orchestration (v2 — .env-aware)
# Place this in ~/openclaw-orchestrate/Makefile
#
# KEY CHANGE vs v1: the setup target SOURCES your state-dir .env before
# invoking the generator, so every variable in it — AGENT_ROSTER,
# PERSONALITY_PRESET, AGENT_{NAME}_*, API keys — reaches the script.
# No more hand-enumerated variable lists silently dropping new knobs.
#
# USAGE:
#   make init            # Create dirs, seed .env from template
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
.PHONY: init setup docker-build docker-up docker-down clean wipe logs logs-system shell status agents help

# =============================================================================
# CONFIGURATION (override via environment or .env file)
# =============================================================================

OPENCLAW_STATE_DIR ?= $(HOME)/.openclaw
ORCHESTRATE_DIR := $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))

COMPOSE_FILE ?= $(OPENCLAW_STATE_DIR)/docker-compose.yml
COMPOSE_ENV ?= $(OPENCLAW_STATE_DIR)/docker.env
ENV_FILE ?= $(OPENCLAW_STATE_DIR)/.env

DOCKER_ENABLE ?= true

# =============================================================================
# INITIALIZATION
# =============================================================================

init:
	@echo "🚀 Initializing OpenClaw orchestration..."
	@mkdir -p $(ORCHESTRATE_DIR)/scripts $(ORCHESTRATE_DIR)/env
	@mkdir -p $(OPENCLAW_STATE_DIR)
	@if [ ! -f "$(ORCHESTRATE_DIR)/scripts/setup-openclaw-triad.sh" ]; then \
		echo "   ⚠  Setup script missing — place setup-openclaw-triad.sh in scripts/"; \
	else \
		echo "   ✓ Setup script present"; \
	fi
	@if [ ! -f "$(ENV_FILE)" ]; then \
		if [ -f "$(ORCHESTRATE_DIR)/env/.env.example" ]; then \
			cp $(ORCHESTRATE_DIR)/env/.env.example $(ENV_FILE); \
			echo "   ✓ Seeded $(ENV_FILE) from template"; \
		else \
			echo "   ⚠  No .env.example in env/ — run 'make setup' to generate one"; \
		fi \
	else \
		echo "   ✓ .env already present (preserved)"; \
	fi
	@chmod 600 $(ENV_FILE) 2>/dev/null || true
	@echo "✓ Init complete. Edit $(ENV_FILE) then run 'make setup'"

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
	@read -p "Type 'WIPE' to confirm: " CONFIRM && \
		[ "$$CONFIRM" = "WIPE" ] || { echo "Aborted"; exit 1; }
	rm -rf $(OPENCLAW_STATE_DIR)
	@echo "✓ Complete wipe done. Run 'make init' to start fresh"

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
		echo "   Secrets: present ($(ENV_FILE))" || echo "   Secrets: MISSING"
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
	@echo "  make init         Initialize dirs and seed .env from template"
	@echo "  make setup        Regenerate the stack using .env values"
	@echo "  make docker-build Build the container image"
	@echo "  make docker-up    Start the gateway"
	@echo "  make docker-down  Stop containers"
	@echo "  make clean        Remove containers + image (state preserved)"
	@echo "  make wipe         DANGER: remove ALL state (confirm required)"
	@echo "  make logs         Follow gateway logs"
	@echo "  make logs-system  Last 100 lines of logs"
	@echo "  make shell        Shell into the container"
	@echo "  make agents       Show configured roster and preset"
	@echo "  make status       Deployment and state health"
	@echo ""
	@echo "Workflow:"
	@echo "  1. make init"
	@echo "  2. Edit $(ENV_FILE):"
	@echo "       NANOGPT_API_KEY, OPENCLAW_GATEWAY_TOKEN,"
	@echo "       AGENT_ROSTER, PERSONALITY_PRESET"
	@echo "  3. make setup"
	@echo "  4. make docker-build && make docker-up"
	@echo ""
