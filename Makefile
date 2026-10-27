#!/usr/bin/env bash
#
# Makefile for OpenClaw Triad Orchestration
# Place this in ~/openclaw-orchestrate/Makefile
#
# USAGE:
#   make init                    # Clone setup script and env template
#   make setup                   # Run setup with current env vars
#   make docker-build            # Build Docker image
#   make docker-up               # Start containers
#   make docker-down             # Stop containers
#   make clean                   # Remove containers only (preserve state)
#   make wipe                    # DANGER: Remove ALL state including workspaces
#   make logs                    # View live logs
#   make shell                   # Shell into container
#   make status                  # Check deployment status
#
# CONFIGURATION:
#   Edit .env or export env vars before running make commands
#   State directory is controlled by OPENCLAW_STATE_DIR (default: ~/.openclaw)
#

SHELL := /bin/bash
.PHONY: init setup docker-build docker-up docker-down clean wipe logs shell status help

# =============================================================================
# CONFIGURATION (override via environment or .env file)
# =============================================================================

OPENCLAW_STATE_DIR ?= $(HOME)/.openclaw
ORCHESTRATE_DIR := $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))

# Docker compose flags
COMPOSE_FILE ?= $(OPENCLAW_STATE_DIR)/docker-compose.yml
COMPOSE_ENV ?= $(OPENCLAW_STATE_DIR)/docker.env

# Feature flags
DOCKER_ENABLE ?= true

# =============================================================================
# INITIALIZATION
# =============================================================================

init:
	@echo "🚀 Initializing OpenClaw orchestration..."
	@mkdir -p $(ORCHESTRATE_DIR)/{scripts,env}
	@mkdir -p $(OPENCLAW_STATE_DIR) 2>/dev/null || true
	@if [ ! -f "$(ORCHESTRATE_DIR)/scripts/setup-openclaw-triad.sh" ]; then \
		echo "   Fetching setup script..."; \
		curl -L https://raw.githubusercontent.com/your-repo/setup-openclaw-triad.sh \
			-o $(ORCHESTRATE_DIR)/scripts/setup-openclaw-triad.sh; \
		chmod +x $(ORCHESTRATE_DIR)/scripts/setup-openclaw-triad.sh; \
	else \
		echo "   ✓ Setup script already present"; \
	fi
	@cp -n $(ORCHESTRATE_DIR)/env/.env.example $(OPENCLAW_STATE_DIR)/.env 2>/dev/null || true
	@chmod 600 $(OPENCLAW_STATE_DIR)/.env 2>/dev/null || true
	@echo "✓ Initialization complete. Edit $(OPENCLAW_STATE_DIR)/.env and run 'make setup'"

# =============================================================================
# SETUP & DEPLOYMENT
# =============================================================================

setup:
	@echo "📦 Running OpenClaw setup..."
	@export OPENCLAW_STATE_DIR="$(OPENCLAW_STATE_DIR)" \
		DOCKER_ENABLE="$(DOCKER_ENABLE)" \
		NANOGPT_API_KEY="$(NANOGPT_API_KEY)" \
		ELEVENLABS_API_KEY="$(ELEVENLABS_API_KEY)" \
		TELEGRAM_BOT_TOKEN="$(TELEGRAM_BOT_TOKEN)" \
		POLYMARKET_API_KEY="$(POLYMARKET_API_KEY)" \
		WALLET_PRIVATE_KEY="$(WALLET_PRIVATE_KEY)" \
		WALLET_TYPE="$(WALLET_TYPE:-btc)" \
		WALLET_AGENT="$(WALLET_AGENT:-clawdio)" \
	&& $(ORCHESTRATE_DIR)/scripts/setup-openclaw-triad.sh --non-interactive \
		$(if $(filter true,$(DOCKER_ENABLE)),--docker,)
	@echo "✓ Setup complete"

docker-build:
	@echo "🐳 Building Docker image..."
	@test -f "$(COMPOSE_FILE)" || { echo "❌ docker-compose.yml not found. Run 'make setup' first."; exit 1; }
	cd $(OPENCLAW_STATE_DIR) && \
		docker compose --env-file $(COMPOSE_ENV) build --pull
	@echo "✓ Build complete"

docker-up:
	@echo "🚀 Starting OpenClaw triad..."
	@test -f "$(COMPOSE_FILE)" || { echo "❌ docker-compose.yml not found. Run 'make setup' first."; exit 1; }
	cd $(OPENCLAW_STATE_DIR) && \
		docker compose --env-file $(COMPOSE_ENV) up -d
	@echo "✓ Containers started"
	@sleep 2
	@$(MAKE) status

docker-down:
	@echo "🛑 Stopping containers..."
	@test -f "$(COMPOSE_FILE)" || { echo "⚠️  No compose file found, skipping"; exit 0; }
	cd $(OPENCLAW_STATE_DIR) && docker compose --env-file $(COMPOSE_ENV) down
	@echo "✓ Containers stopped"

# =============================================================================
# CLEANUP
# =============================================================================

clean:
	@echo "🧹 Removing containers only (preserving state)..."
	@test -f "$(COMPOSE_FILE)" || { echo "⚠️  No compose file found"; exit 0; }
	cd $(OPENCLAW_STATE_DIR) && docker compose --env-file $(COMPOSE_ENV) down
	@docker image prune -af --filter "label=compose_project=openclaw-triad"
	@echo "✓ Cleanup complete (state preserved in $(OPENCLAW_STATE_DIR))"

wipe:
	@echo "☣️  DANGER: This will remove ALL OpenClaw state!"
	@read -p "Are you absolutely sure? Type 'WIPE' to confirm: " CONFIRM && \
		[ "$$CONFIRM" = "WIPE" ] || { echo "Aborted"; exit 1; }
	rm -rf $(OPENCLAW_STATE_DIR)/*
	rm -rf ~/.openclaw/*
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

status:
	@echo "📊 Deployment Status:"
	@test -f "$(COMPOSE_FILE)" || { echo "   No Docker deployment found"; return 0; }
	cd $(OPENCLAW_STATE_DIR) && docker compose --env-file $(COMPOSE_ENV) ps
	@echo ""
	@echo "📁 State Directory: $(OPENCLAW_STATE_DIR)"
	@test -d "$(OPENCLAW_STATE_DIR)/agents" && \
		echo "   Agents: $(shell ls -1 $(OPENCLAW_STATE_DIR)/agents | tr '\n' ' ')" || echo "   Agents: Not initialized"
	@test -f "$(OPENCLAW_STATE_DIR)/openclaw.json" && \
		echo "   Config: Present" || echo "   Config: Missing"
	@test -f "$(OPENCLAW_STATE_DIR)/.env" && \
		echo "   Secrets: Present ($(shell stat -c%s $(OPENCLAW_STATE_DIR)/.env 2>/dev/null || echo '?') bytes)" || \
		echo "   Secrets: Missing"

# =============================================================================
# HELP
# =============================================================================

help:
	@echo "OpenClaw Triad Orchestration"
	@echo "============================"
	@echo ""
	@echo "Commands:"
	@echo "  make init         Initialize orchestration directory and fetch scripts"
	@echo "  make setup        Run full setup (generates config, workspaces, etc.)"
	@echo "  make docker-build Build Docker image"
	@echo "  make docker-up    Start containers"
	@echo "  make docker-down  Stop containers"
	@echo "  make clean        Remove containers only (preserve state)"
	@echo "  make wipe         DANGER: Remove ALL state (confirm required)"
	@echo "  make logs         Follow container logs"
	@echo "  make logs-system  Last 100 lines of system logs"
	@echo "  make shell        Shell into running container"
	@echo "  make status       Show deployment and state status"
	@echo "  make help         Show this help"
	@echo ""
	@echo "Configuration:"
	@echo "  State Dir:   $(OPENCLAW_STATE_DIR)"
	@echo "  Orchestrator: $(ORCHESTRATE_DIR)"
	@echo ""
	@echo "Environment Variables:"
	@echo "  NANOGPT_API_KEY (required)"
	@echo "  ELEVENLABS_API_KEY (optional, enables TTS)"
	@echo "  TELEGRAM_BOT_TOKEN (optional, enables chat interface)"
	@echo "  POLYMARKET_API_KEY (optional, enables live trading)"
	@echo "  WALLET_PRIVATE_KEY (optional, enables crypto treasury)"
	@echo "  WALLET_TYPE (btc|xmr|eth, default: btc)"
	@echo "  WALLET_AGENT (clawdia|clawdio|arbiter, default: clawdio)"
	@echo ""
	@echo "Quick Start:"
	@echo "  1. make init"
	@echo "  2. Export your API keys (see above)"
	@echo "  3. make setup"
	@echo "  4. make docker-build && make docker-up"
	@echo ""
