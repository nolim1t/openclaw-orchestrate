#!/usr/bin/env bash
#
# Makefile for OpenClaw Triad Orchestration
# Place this in ~/openclaw-orchestrate/Makefile
#
# USAGE:
#   make init                    # Seed setup script and env template
#   make setup                   # Run setup with current env vars (.env auto-loaded)
#   make test                    # Dry-run the generator in a throwaway sandbox
#   make docker-build            # Build Docker image
#   make docker-up               # Start containers
#   make docker-down             # Stop containers
#   make clean                   # Remove containers only (preserve state)
#   make wipe                    # DANGER: Remove ALL state including workspaces
#   make logs                    # View live logs
#   make shell                   # Shell into container
#   make status                  # Check deployment status
#   make agents                  # Show current agent roster & personalities
#   make check                   # Validate script syntax + generated config
#
# CONFIGURATION:
#   Edit .env or export env vars before running make commands.
#   AGENT_ROSTER, PERSONALITY_PRESET and AGENT_{NAME}_* vars are passed
#   through to the setup script automatically.
#   State directory is controlled by OPENCLAW_STATE_DIR (default: ~/.openclaw)
#

SHELL := /bin/bash
.PHONY: init setup test docker-build docker-up docker-down clean wipe logs logs-system \
        shell status agents check help

# =============================================================================
# CONFIGURATION (override via environment or .env file)
# =============================================================================

OPENCLAW_STATE_DIR ?= $(HOME)/.openclaw
ORCHESTRATE_DIR := $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))
ENV_FILE := $(OPENCLAW_STATE_DIR)/.env

# Docker compose flags
COMPOSE_FILE ?= $(OPENCLAW_STATE_DIR)/docker-compose.yml
COMPOSE_ENV ?= $(OPENCLAW_STATE_DIR)/docker.env

# Feature flags
DOCKER_ENABLE ?= true

# Test sandbox — throwaway state dir for dry runs (overridable)
TEST_STATE_DIR ?= /tmp/openclaw-test-$(shell mktemp -u %s)

# =============================================================================
# ENV LOADING
# The .env file is the single source of truth for secrets AND customization.
# This helper exports everything in it for the current recipe.
# =============================================================================

define load_env
	set -a; \
	if [ -f "$(ENV_FILE)" ]; then . "$(ENV_FILE)"; fi; \
	set +a
endef

# =============================================================================
# INITIALIZATION
# =============================================================================

init:
	@echo "🚀 Initializing OpenClaw orchestration..."
	@mkdir -p $(ORCHESTRATE_DIR)/scripts $(ORCHESTRATE_DIR)/env
	@mkdir -p $(OPENCLAW_STATE_DIR) 2>/dev/null || true
	@if [ ! -f "$(ORCHESTRATE_DIR)/scripts/setup-openclaw-triad.sh" ]; then \
		echo "   ⚠ Setup script missing — place setup-openclaw-triad.sh in scripts/"; \
		echo "     (update the curl URL below to your repo, or copy it manually)"; \
	else \
		echo "   ✓ Setup script present"; \
	fi
	@if [ ! -f "$(ENV_FILE)" ] && [ -f "$(ORCHESTRATE_DIR)/env/.env.example" ]; then \
		cp $(ORCHESTRATE_DIR)/env/.env.example $(ENV_FILE); \
		echo "   ✓ Seeded $(ENV_FILE) from template"; \
	elif [ -f "$(ENV_FILE)" ]; then \
		echo "   ✓ Existing .env preserved"; \
	fi
	@chmod 600 $(ENV_FILE) 2>/dev/null || true
	@echo "✓ Initialization complete. Edit $(ENV_FILE) and run 'make setup'"

# =============================================================================
# SETUP & DEPLOYMENT
# =============================================================================

# NOTE: rather than passing each variable individually, setup sources .env
# with set -a so EVERY variable — secrets, feature keys, AGENT_ROSTER,
# PERSONALITY_PRESET and all AGENT_{NAME}_* overrides — reaches the script.
# Shell-level defaults (e.g. ${WALLET_TYPE:-btc}) live in the setup script.

setup:
	@echo "📦 Running OpenClaw setup..."
	@test -x "$(ORCHESTRATE_DIR)/scripts/setup-openclaw-triad.sh" || \
		{ echo "❌ scripts/setup-openclaw-triad.sh not found or not executable. Run 'make init'."; exit 1; }
	@$(load_env) ; \
	export OPENCLAW_STATE_DIR="$(OPENCLAW_STATE_DIR)" ; \
	$(ORCHESTRATE_DIR)/scripts/setup-openclaw-triad.sh --non-interactive \
		$(if $(filter true,$(DOCKER_ENABLE)),--docker,)
	@echo "✓ Setup complete"
	@echo "  Roster: $(shell $(load_env) 2>/dev/null; echo "$${AGENT_ROSTER:-clawdia,clawdio,arbiter}")"
	@echo "  Preset: $(shell $(load_env) 2>/dev/null; echo "$${PERSONALITY_PRESET:-default}")"

# =============================================================================
# TESTING — dry-run the generator in a throwaway sandbox
# =============================================================================

# Runs the FULL generator against a disposable state directory using your
# real .env customization (roster, presets, agent overrides) but with a
# dummy API key, then validates every generated artifact. Nothing touches
# ~/.openclaw. No Docker involved, no network calls beyond date/hostname.

test:
	@echo "🧪 Testing OpenClaw setup generator..."
	@test -x "$(ORCHESTRATE_DIR)/scripts/setup-openclaw-triad.sh" || \
		{ echo "❌ Setup script missing. Run 'make init'."; exit 1; }
	@bash -n $(ORCHESTRATE_DIR)/scripts/setup-openclaw-triad.sh || \
		{ echo "❌ Setup script has syntax errors"; exit 1; }
	@echo "   ✓ Script syntax OK"
	@echo ""
	@SANDBOX="$(TEST_STATE_DIR)"; \
	mkdir -p "$$SANDBOX"; \
	$(load_env) ; \
	NANOGPT_API_KEY="$${NANOGPT_API_KEY:-test-dummy-key}" \
	OPENCLAW_STATE_DIR="$$SANDBOX" \
	$(ORCHESTRATE_DIR)/scripts/setup-openclaw-triad.sh --non-interactive \
		> /dev/null 2> "$(TEST_STATE_DIR)/stderr.log" || \
		{ echo "❌ Generator exited non-zero:"; \
		  tail -20 "$(TEST_STATE_DIR)/stderr.log"; \
		  echo "   Sandbox kept at $(TEST_STATE_DIR) for inspection"; \
		  exit 1; }; \
	echo "   ✓ Generator completed without errors"
	@echo ""
	@echo "   Verifying generated artifacts..."
	@test -f "$(TEST_STATE_DIR)/openclaw.json" \
		&& echo "   ✓ openclaw.json exists" \
		|| { echo "   ✗ openclaw.json missing"; exit 1; }
	@test -f "$(TEST_STATE_DIR)/.env.example" \
		&& echo "   ✓ .env.example exists" \
		|| { echo "   ✗ .env.example missing"; exit 1; }
	@test -f "$(TEST_STATE_DIR)/.env" \
		&& echo "   ✓ .env seeded" \
		|| { echo "   ✗ .env missing"; exit 1; }
	@test "$$(stat -c %a "$(TEST_STATE_DIR)/.env" 2>/dev/null)" = "600" \
		&& echo "   ✓ .env has 600 permissions" \
		|| { echo "   ✗ .env wrong permissions"; exit 1; }
	@test -f "$(TEST_STATE_DIR)/plugins/polymarket-clob/trading.json" \
		&& python3 -m json.tool "$(TEST_STATE_DIR)/plugins/polymarket-clob/trading.json" > /dev/null \
		&& echo "   ✓ trading.json valid" \
		|| { echo "   ✗ trading.json missing or invalid"; exit 1; }
	@test "$$(grep -o '\"mode\": \"testnet\"' "$(TEST_STATE_DIR)/plugins/polymarket-clob/trading.json" | head -1)" = '"mode": "testnet"' \
		&& echo "   ✓ trading mode = testnet (safe default)" \
		|| { echo "   ✗ trading mode not testnet"; exit 1; }
	@ROSTER_TEST=$$($(load_env) 2>/dev/null; echo "$${AGENT_ROSTER:-clawdia,clawdio,arbiter}"); \
	IFS=','; \
	for name in $$ROSTER_TEST; do \
		dir="$(TEST_STATE_DIR)/workspace-triad/$$name"; \
		test -d "$$dir" || { echo "   ✗ workspace missing for agent: $$name"; exit 1; }; \
		for f in IDENTITY.md AGENTS.md SOUL.md DREAMS.md; do \
			test -f "$$dir/$$f" || { echo "   ✗ $$name missing $$f"; exit 1; }; \
		done; \
		grep -q "$$name" "$(TEST_STATE_DIR)/openclaw.json" || \
			{ echo "   ✗ $$name not wired into openclaw.json"; exit 1; }; \
		echo "   ✓ agent $$name: workspace + identity files + config entry"; \
	done; \
	unset IFS
	@test -d "$(TEST_STATE_DIR)/agents" \
		&& echo "   ✓ agents runtime dirs created" \
		|| { echo "   ✗ agents/ missing"; exit 1; }
	@test -f "$(TEST_STATE_DIR)/shared/trade-ledger.jsonl" \
		&& echo "   ✓ trade ledger initialised" \
		|| { echo "   ✗ trade ledger missing"; exit 1; }
	@test -f "$(TEST_STATE_DIR)/shared/calibration/README.md" \
		&& echo "   ✓ calibration archive initialised" \
		|| { echo "   ✗ calibration missing"; exit 1; }
	@echo ""
	@echo "   Cleaning up sandbox..."
	@rm -rf "$(TEST_STATE_DIR)"
	@echo ""
	@echo "✅ All tests passed — generator is healthy"

# Test with a CUSTOM roster to verify the dynamic agent system end-to-end.
# Complements 'make test' which exercises the default (or .env) roster.

test-roster:
	@echo "🧪 Testing dynamic roster generation..."
	@SANDBOX="$(TEST_STATE_DIR)-roster"; \
	mkdir -p "$$SANDBOX"; \
	AGENT_ROSTER="alpha,beta,gamma,delta" \
	PERSONALITY_PRESET="quant" \
	AGENT_ALPHA_THEME="test theme alpha" \
	AGENT_BETA_MODEL="test/model-beta" \
	AGENT_DELTA_THINKING="high" \
	NANOGPT_API_KEY="test-dummy-key" \
	OPENCLAW_STATE_DIR="$$SANDBOX" \
	$(ORCHESTRATE_DIR)/scripts/setup-openclaw-triad.sh --non-interactive \
		> /dev/null 2>&1 || \
		{ echo "❌ Generator failed on custom roster"; rm -rf "$$SANDBOX"; exit 1; }; \
	for name in alpha beta gamma delta; do \
		test -d "$$SANDBOX/workspace-triad/$$name" || \
			{ echo "   ✗ agent $$name workspace missing"; rm -rf "$$SANDBOX"; exit 1; }; \
		grep -q "$$name" "$$SANDBOX/openclaw.json" || \
			{ echo "   ✗ agent $$name absent from openclaw.json"; rm -rf "$$SANDBOX"; exit 1; }; \
	done; \
	grep -q "test/model-beta" "$$SANDBOX/openclaw.json" || \
		{ echo "   ✗ per-agent model override not applied"; rm -rf "$$SANDBOX"; exit 1; }; \
	echo "   ✓ 4-agent custom roster: all workspaces + config entries"; \
	grep -q "test theme alpha" "$$SANDBOX/workspace-triad/alpha/SOUL.md" || \
		{ echo "   ✗ theme override not flowing into SOUL.md"; rm -rf "$$SANDBOX"; exit 1; }; \
	echo "   ✓ per-agent theme override flows into SOUL.md"; \
	grep -q '"thinkingDefault": "high"' "$$SANDBOX/openclaw.json" || \
		{ echo "   ✗ per-agent thinking override not applied"; rm -rf "$$SANDBOX"; exit 1; }; \
	echo "   ✓ per-agent thinking override flows into openclaw.json"; \
	test "$$(ls -1 $$SANDBOX/agents | wc -l)" = "4" || \
		{ echo "   ✗ expected 4 agent runtime dirs"; rm -rf "$$SANDBOX"; exit 1; }; \
	echo "   ✓ 4 agent runtime dirs"; \
	rm -rf "$$SANDBOX"; \
	echo ""
	@echo "✅ Dynamic roster test passed"

# =============================================================================
# CLEANUP
# =============================================================================

clean:
	@echo "🧹 Removing containers only (preserving state)..."
	@test -f "$(COMPOSE_FILE)" || { echo "⚠️  No compose file found"; exit 0; }
	cd $(OPENCLAW_STATE_DIR) && docker compose --env-file $(COMPOSE_ENV) down
	@docker image prune -af --filter "label=compose_project=openclaw-triad" 2>/dev/null || true
	@echo "✓ Cleanup complete (state preserved in $(OPENCLAW_STATE_DIR))"

wipe:
	@echo "☣️  DANGER: This will remove ALL OpenClaw state in:"
	@echo "    $(OPENCLAW_STATE_DIR)"
	@echo "   Including workspaces, journals, ledgers and wallet config."
	@echo "   Requires typed confirmation."
	@bash -c 'read -r -p "Type WIPE to confirm: " CONFIRM; \
		[ "$$CONFIRM" = "WIPE" ] || { echo "Aborted"; exit 1; }; \
		rm -rf "$(OPENCLAW_STATE_DIR)"/* "$(OPENCLAW_STATE_DIR)"/.[!.]* 2>/dev/null; \
		echo "✓ Complete wipe done. Run '"'"'make init'"'"' to start fresh"' OPENCLAW_STATE_DIR="$(OPENCLAW_STATE_DIR)"

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
	@if [ ! -f "$(COMPOSE_FILE)" ]; then \
		echo "   No Docker deployment found"; \
	else \
		cd $(OPENCLAW_STATE_DIR) && docker compose --env-file $(COMPOSE_ENV) ps; \
	fi
	@echo ""
	@echo "📁 State Directory: $(OPENCLAW_STATE_DIR)"
	@test -d "$(OPENCLAW_STATE_DIR)/agents" && \
		echo "   Agents: $$(ls -1 $(OPENCLAW_STATE_DIR)/agents 2>/dev/null | tr '\n' ' ')" || \
		echo "   Agents: Not initialized"
	@test -f "$(OPENCLAW_STATE_DIR)/openclaw.json" && \
		echo "   Config: Present" || echo "   Config: Missing"
	@test -f "$(ENV_FILE)" && \
		echo "   Secrets: Present ($$(stat -c%s $(ENV_FILE) 2>/dev/null || echo '?') bytes)" || \
		echo "   Secrets: Missing"

# =============================================================================
# AGENT ROSTER INSPECTION
# =============================================================================

agents:
	@$(load_env) 2>/dev/null; \
	ROSTER="$${AGENT_ROSTER:-clawdia,clawdio,arbiter}"; \
	PRESET="$${PERSONALITY_PRESET:-default}"; \
	echo "🎭 Agent Roster"; \
	echo "==============="; \
	echo "  Roster:  $$ROSTER"; \
	echo "  Preset:  $$PRESET"; \
	echo ""; \
	IFS=','; \
	for name in $$ROSTER; do \
		upper=$$(echo "$$name" | tr '[:lower:]' '[:upper:]'); \
		theme_var="AGENT_$${upper}_THEME"; \
		role_var="AGENT_$${upper}_ROLE"; \
		model_var="AGENT_$${upper}_MODEL"; \
		think_var="AGENT_$${upper}_THINKING"; \
		echo "  • $${name^}"; \
		[ -n "$${!theme_var}" ] && echo "      theme:    $${!theme_var}"; \
		[ -n "$${!role_var}" ]  && echo "      role:     $${!role_var}"; \
		[ -n "$${!model_var}" ] && echo "      model:    $${!model_var}"; \
		[ -n "$${!think_var}" ] && echo "      thinking: $${!think_var}"; \
	done; \
	unset IFS; \
	echo ""; \
	echo "  Workspace: $(OPENCLAW_STATE_DIR)/workspace-triad"

check:
	@echo "🔍 Validating..."
	@bash -n $(ORCHESTRATE_DIR)/scripts/setup-openclaw-triad.sh && \
		echo "   ✓ setup script syntax OK" || \
		{ echo "   ✗ setup script has syntax errors"; exit 1; }
	@if [ -f "$(OPENCLAW_STATE_DIR)/openclaw.json" ]; then \
		python3 -c "import json5,sys; json5.load(open('$(OPENCLAW_STATE_DIR)/openclaw.json'))" 2>/dev/null \
		&& echo "   ✓ openclaw.json parses (JSON5)" \
		|| echo "   ⚠ openclaw.json — install json5 to validate strictly"; \
	fi
	@if [ -f "$(OPENCLAW_STATE_DIR)/plugins/polymarket-clob/trading.json" ]; then \
		python3 -m json.tool "$(OPENCLAW_STATE_DIR)/plugins/polymarket-clob/trading.json" > /dev/null 2>&1 \
		&& echo "   ✓ trading.json valid" || echo "   ✗ trading.json invalid"; \
	fi
	@echo "✓ Validation finished"

# =============================================================================
# HELP
# =============================================================================

help:
	@echo "OpenClaw Triad Orchestration"
	@echo "============================"
	@echo ""
	@echo "Commands:"
	@echo "  make init         Initialize orchestration directory and seed .env"
	@echo "  make setup        Run full setup (generates config, workspaces, agents)"
	@echo "  make test         Dry-run generator in throwaway sandbox, verify output"
	@echo "  make test-roster  Test dynamic agent roster generation end-to-end"
	@echo "  make agents       Show current roster, themes, roles, models"
	@echo "  make check        Validate script syntax and generated config"
	@echo "  make docker-build Build Docker image"
	@echo "  make docker-up    Start containers"
	@echo "  make docker-down  Stop containers"
	@echo "  make clean        Remove containers only (preserve state)"
	@echo "  make wipe         DANGER: Remove ALL state (typed confirmation)"
	@echo "  make logs         Follow container logs"
	@echo "  make logs-system  Last 100 lines of system logs"
	@echo "  make shell        Shell into running container"
	@echo "  make status       Show deployment and state status"
	@echo "  make help         Show this help"
	@echo ""
	@echo "Configuration:"
	@echo "  State Dir:    $(OPENCLAW_STATE_DIR)"
	@echo "  Orchestrator: $(ORCHESTRATE_DIR)"
	@echo "  Env File:     $(ENV_FILE)"
	@echo "  Test Sandbox: TEST_STATE_DIR (default: /tmp/openclaw-test-*)"
	@echo ""
	@echo "Core Variables (in .env):"
	@echo "  NANOGPT_API_KEY (required)"
	@echo "  ELEVENLABS_API_KEY (optional, enables TTS)"
	@echo "  TELEGRAM_BOT_TOKEN (optional, enables chat interface)"
	@echo "  POLYMARKET_API_KEY (optional, enables live trading)"
	@echo "  WALLET_PRIVATE_KEY (optional, enables crypto treasury)"
	@echo "  WALLET_TYPE (btc|xmr|eth, default: btc)"
	@echo "  WALLET_AGENT (must match a roster name, default: clawdio)"
	@echo ""
	@echo "Agent Customization (in .env):"
	@echo "  AGENT_ROSTER          Comma-separated names (default: clawdia,clawdio,arbiter)"
	@echo "  PERSONALITY_PRESET    default|bold|conservative|mystic|quant"
	@echo "  AGENT_{NAME}_THEME    Personality/visual theme per agent"
	@echo "  AGENT_{NAME}_ROLE     Role description per agent"
	@echo "  AGENT_{NAME}_MODEL    Model override per agent"
	@echo "  AGENT_{NAME}_THINKING light|medium|high"
	@echo ""
	@echo "Quick Start:"
	@echo "  1. make init"
	@echo "  2. Edit $(ENV_FILE) — add keys, optionally set AGENT_ROSTER"
	@echo "  3. make test && make test-roster   # verify before committing"
	@echo "  4. make setup && make agents       # apply your roster"
	@echo "  5. make docker-build && make docker-up"
	@echo ""
