#!/usr/bin/env bash
#
# Makefile for OpenClaw Triad Orchestration (v3.1 — secrets-stash + telegram)
# Place this in ~/openclaw-orchestrate/Makefile
#
# v3.1 (vs v3): NEW `make telegram` target (runtime channel registration —
#   the README/.env.example reference it as the canonical path); fixed the
#   unclosed-quote syntax error in the status target's Secrets line that
#   killed `make status` (and therefore `make docker-up`) after boot.
# v3 (vs v2): secrets-stash lifecycle — env/.env.real-secrets persists your
#   keys across state-dir wipes; init seeds from stash first, example second.
#
# IMPORTANT: the rebuild script fetches this Makefile from the pinned tag
# on every run and overwrites the local copy — commit + tag any change here.
#
# USAGE:
#   make init             # Create dirs, seed .env (stash > example)
#   make secrets-save     # Snapshot live .env -> env/.env.real-secrets
#   make secrets-restore  # Push stash -> live .env
#   make setup            # Regenerate the stack using .env values
#   make docker-build     # Build the container image
#   make docker-up        # Start the Gateway
#   make docker-down      # Stop containers (state preserved)
#   make telegram         # Register the Telegram channel (once, post-boot)
#   make clean            # Remove containers + image (state preserved)
#   make wipe             # DANGER: remove ALL state (typed confirmation)
#   make logs             # Follow Gateway logs live
#   make logs-system      # Last 100 log lines
#   make shell            # Shell into the container
#   make status           # Deployment + state directory health
#   make agents           # Show the configured roster
#   make help             # This reference
#

SHELL := /bin/bash
.PHONY: init backup backup-offsite restore restore-offsite stash _restore-confirm secrets-save secrets-restore setup docker-build docker-up docker-down telegram clean wipe logs logs-system shell status agents help

# =============================================================================
# CONFIGURATION (override via environment or .env file)
# =============================================================================

OPENCLAW_STATE_DIR ?= $(HOME)/.openclaw
ORCHESTRATE_DIR := $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))

# Backup variables
PROTON_DRIVE_CMD ?= $(ORCHESTRATE_DIR)/proton-drive
PROTON_REMOTE_FOLDER ?= /my-files/openclaw
PROTON_REMOTE_FILE ?= openclaw-latest.tar.gz
PROTON_SECRETS_FILE ?= .env.real-secrets
BACKUP_DIR ?= $(HOME)/openclaw-backups
BACKUP_ARCHIVE := $(BACKUP_DIR)/$(PROTON_REMOTE_FILE)
STASH_DIR := $(BACKUP_DIR)/stash
STASH_FILES := openclaw.json .env
SECRETS_STASH ?= $(ORCHESTRATE_DIR)/env/.env.real-secrets

COMPOSE_FILE ?= $(OPENCLAW_STATE_DIR)/docker-compose.yml
COMPOSE_ENV ?= $(OPENCLAW_STATE_DIR)/docker.env
ENV_FILE ?= $(OPENCLAW_STATE_DIR)/.env

# Secrets lifecycle: stash survives `rm -rf ~/.openclaw` AND survives the
# rebuild's pinned-tag fetch (only Makefile + scripts/* are fetched).
ENV_DIR ?= $(ORCHESTRATE_DIR)/env
SECRETS_STASH ?= $(ENV_DIR)/.env.real-secrets
SECRETS_EXAMPLE ?= $(ENV_DIR)/.env.example

CONTAINER_NAME ?= openclaw-triad

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
		echo "   ℹ  Never a bad moment: 'make secrets-save' to refresh the stash"; \
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
# SECRETS LIFECYCLE — local stash + Proton Drive mirror
#
#   make secrets-save      Copy live .env to env/.env.real-secrets + upload
#   make secrets-restore   Restore .env from local stash (or pull from Drive)
# =============================================================================

secrets-save:
	@echo "🔐 Saving secrets..."
	@test -f "$(ENV_FILE)" || { echo "❌ No live .env at $(ENV_FILE) to save."; exit 1; }
	@mkdir -p "$$(dirname $(SECRETS_STASH))"
	@cp "$(ENV_FILE)" "$(SECRETS_STASH)" && chmod 600 "$(SECRETS_STASH)"
	@echo "   ✓ Local stash: $(SECRETS_STASH)"
	@if [ -x "$(PROTON_DRIVE_CMD)" ]; then \
		"$(PROTON_DRIVE_CMD)" filesystem upload -c replace \
			"$(SECRETS_STASH)" "$(PROTON_REMOTE_FOLDER)"; \
		echo "   ✓ Remote mirror: $(PROTON_REMOTE_FOLDER)/$(PROTON_SECRETS_FILE)"; \
	else \
		echo "   ⚠  proton-drive CLI not found — saved locally only."; \
	fi

secrets-restore:
	@echo "🔑 Restoring secrets to $(ENV_FILE)..."
	@if [ ! -f "$(SECRETS_STASH)" ]; then \
		if [ -x "$(PROTON_DRIVE_CMD)" ]; then \
			echo "   No local stash — pulling from Proton Drive..."; \
			mkdir -p "$(BACKUP_DIR)" "$$(dirname $(SECRETS_STASH))"; \
			"$(PROTON_DRIVE_CMD)" filesystem download -c replace \
				"$(PROTON_REMOTE_FOLDER)/$(PROTON_SECRETS_FILE)" "$(BACKUP_DIR)"; \
			mv "$(BACKUP_DIR)/$(PROTON_SECRETS_FILE)" "$(SECRETS_STASH)"; \
			chmod 600 "$(SECRETS_STASH)"; \
		else \
			echo "❌ No local stash and no proton-drive CLI — cannot restore."; exit 1; \
		fi; \
	fi
	@mkdir -p "$(OPENCLAW_STATE_DIR)"
	@cp "$(SECRETS_STASH)" "$(ENV_FILE)" && chmod 600 "$(ENV_FILE)"
	@echo "✓ Secrets restored."

# =============================================================================
# SETUP — sources .env so ALL variables (roster, preset, keys, models) reach
# the generator. Env-driven lineup since generator v3.3.
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

# =============================================================================
# BACKUP / RESTORE — rolling archive + config stash, mirrored to Proton Drive
#
#   make backup            Snapshot ~/.openclaw (minus config) to ~/openclaw-backups/
#   make stash             Mirror openclaw.json + .env locally and to /my-files/openclaw
#   make backup-offsite    Backup + stash + upload archive (full offsite sync)
#   make restore           Restore from local archive + local stash mirror
#   make restore-offsite   Pull everything from Proton Drive and restore
# =============================================================================

backup:
	@echo "💾 Backing up $(OPENCLAW_STATE_DIR) (config excluded — see 'make stash')..."
	@test -d "$(OPENCLAW_STATE_DIR)" || { echo "❌ Nothing to back up — $(OPENCLAW_STATE_DIR) not found."; exit 1; }
	@mkdir -p "$(BACKUP_DIR)"
	tar -czf "$(BACKUP_ARCHIVE).tmp" \
		--exclude='.openclaw/openclaw.json' \
		--exclude='*/node_modules' \
		--exclude='*/.git' \
		-C "$$(dirname $(OPENCLAW_STATE_DIR))" "$$(basename $(OPENCLAW_STATE_DIR))"
	mv "$(BACKUP_ARCHIVE).tmp" "$(BACKUP_ARCHIVE)"
	@echo "✓ Archive saved: $(BACKUP_ARCHIVE)"
	@ls -lh "$(BACKUP_ARCHIVE)"

stash:
	@echo "🗄  Stashing config files..."
	@test -x "$(PROTON_DRIVE_CMD)" || { echo "❌ proton-drive CLI not found at $(PROTON_DRIVE_CMD)"; exit 1; }
	@mkdir -p "$(STASH_DIR)"
	@for f in $(STASH_FILES); do \
		test -f "$(OPENCLAW_STATE_DIR)/$$f" || { echo "❌ $(OPENCLAW_STATE_DIR)/$$f missing"; exit 1; }; \
		cp "$(OPENCLAW_STATE_DIR)/$$f" "$(STASH_DIR)/"; \
	done
	@chmod 600 "$(STASH_DIR)/.env"
	"$(PROTON_DRIVE_CMD)" filesystem upload -c replace \
		"$(OPENCLAW_STATE_DIR)/openclaw.json" \
		"$(OPENCLAW_STATE_DIR)/.env" \
		"$(PROTON_REMOTE_FOLDER)"
	@echo "✓ Config stash uploaded to $(PROTON_REMOTE_FOLDER)"

backup-offsite: backup stash
	@echo "☁️  Uploading archive to $(PROTON_REMOTE_FOLDER)..."
	"$(PROTON_DRIVE_CMD)" filesystem upload -c replace "$(BACKUP_ARCHIVE)" "$(PROTON_REMOTE_FOLDER)"
	@echo "✓ Offsite sync complete — Proton Drive retains prior versions."

restore:
	@test -f "$(BACKUP_ARCHIVE)" || { echo "❌ No local archive at $(BACKUP_ARCHIVE). Try 'make restore-offsite'."; exit 1; }
	@$(MAKE) --no-print-directory _restore-confirm \
		ARCHIVE="$(BACKUP_ARCHIVE)" CONFIG_SRC="$(STASH_DIR)"

restore-offsite:
	@echo "⬇️  Fetching backups from Proton Drive ($(PROTON_REMOTE_FOLDER))..."
	@test -x "$(PROTON_DRIVE_CMD)" || { echo "❌ proton-drive CLI not found at $(PROTON_DRIVE_CMD)"; exit 1; }
	@mkdir -p "$(BACKUP_DIR)" "$(STASH_DIR)"
	"$(PROTON_DRIVE_CMD)" filesystem download -c replace \
		"$(PROTON_REMOTE_FOLDER)/$(PROTON_REMOTE_FILE)" "$(BACKUP_DIR)"
	"$(PROTON_DRIVE_CMD)" filesystem download -c replace \
		"$(PROTON_REMOTE_FOLDER)/openclaw.json" \
		"$(PROTON_REMOTE_FOLDER)/.env" \
		"$(STASH_DIR)"
	@chmod 600 "$(STASH_DIR)/.env"
	@$(MAKE) --no-print-directory _restore-confirm \
		ARCHIVE="$(BACKUP_ARCHIVE)" CONFIG_SRC="$(STASH_DIR)"

_restore-confirm:
	@echo "⚠️  This will overwrite $(OPENCLAW_STATE_DIR)"
	@echo "   Archive:  $(ARCHIVE) ($$(du -h '$(ARCHIVE)' | cut -f1))"
	@echo "   Configs:  from $(CONFIG_SRC)"
	@read -p "Type 'RESTORE to confirm: " CONFIRM && \
		[ "$$CONFIRM" = "RESTORE" ] || { echo "Aborted"; exit 1; }
	@mkdir -p "$(OPENCLAW_STATE_DIR)"
	tar -xzf "$(ARCHIVE)" -C "$$(dirname $(OPENCLAW_STATE_DIR))"
	@for f in $(STASH_FILES); do \
		if [ -f "$(CONFIG_SRC)/$$f" ]; then \
			cp "$(CONFIG_SRC)/$$f" "$(OPENCLAW_STATE_DIR)/"; \
			echo "   ✓ $$f restored from stash"; \
		else \
			echo "   ⚠  $$f not in stash — restored state may be incomplete"; \
		fi; \
	done
	@chmod 600 "$(ENV_FILE)" 2>/dev/null || true
	@echo "✓ Restored. Run 'make setup' && 'make docker-up' to resume."
	
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
# TELEGRAM — channel registration happens AT RUNTIME, once, after the
# gateway has booted successfully. Requires TELEGRAM_BOT_TOKEN + USER_ID
# in .env, and the gateway up. This is not an idempotent generator step.
# =============================================================================

telegram:
	@docker ps --format '{{.Names}}' | grep -q '^$(CONTAINER_NAME)$$' \
		|| { echo "❌ $(CONTAINER_NAME) is not running — boot first (make docker-up)"; exit 1; }
	@grep -qE '^TELEGRAM_BOT_TOKEN=..' $(ENV_FILE) 2>/dev/null \
		|| { echo "❌ TELEGRAM_BOT_TOKEN missing/empty in $(ENV_FILE)"; exit 1; }
	@echo "📡 Registering the Telegram channel (interactive)..."
	@docker exec -it $(CONTAINER_NAME) openclaw channels add telegram

# =============================================================================
# CLEANUP
# =============================================================================

clean:
	@echo "🧹 Removing containers and image (preserving state)..."
	@test -f "$(COMPOSE_FILE)" || { echo "⚠️  No compose file found"; exit 0; }
	cd $(OPENCLAW_STATE_DIR) && docker compose --env-file $(COMPOSE_ENV) down
	@docker rmi openclaw-triad:local 2>/dev/null || true
	@echo "✓ Cleanup complete (state preserved in $(OPENCLAW_STATE_DIR))"

pre-wipe-backup: backup-offsite

wipe: pre-wipe-backup
	@echo "☣️  DANGER: This will remove ALL OpenClaw state — journals, ledgers, calibration!"
	@read -p "Type 'WIPE' to confirm: " CONFIRM && \
		[ "$$CONFIRM" = "WIPE" ] || { echo "Aborted"; exit 1; }
	rm -rf $(OPENCLAW_STATE_DIR)
	@echo "✓ Wiped. Latest backup kept in $(BACKUP_DIR). Run 'make init' + 'make restore' to recover."

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
	cd $(OPENCLAW_STATE_DIR) && docker compose --env-file $(COMPOSE_ENV) exec $(CONTAINER_NAME) /bin/bash

agents:
	@echo "🤖 Configured roster (from $(ENV_FILE)):"
	@grep -E '^AGENT_ROSTER' $(ENV_FILE) 2>/dev/null || echo "   AGENT_ROSTER not set — script default applies"
	@grep -E '^PERSONALITY_PRESET' $(ENV_FILE) 2>/dev/null || true
	@echo "🧠 Model lineup:"
	@grep -E '^(NANOGPT_MODEL_CATALOG|TRIAD_[A-Z]+_MODEL|UTILITY_MODEL)=' $(ENV_FILE) 2>/dev/null \
		|| echo "   (no overrides — builtin Claude/GPT defaults apply)"

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
	@echo "  make init             Initialize dirs, seed .env (stash > example)"
	@echo "  make secrets-save     Snapshot live .env -> env/.env.real-secrets"
	@echo "  make secrets-restore  Restore stash -> live .env"
	@echo "  make setup            Regenerate the stack using .env values"
	@echo "  make docker-build     Build the container image"
	@echo "  make docker-up         Start the gateway"
	@echo "  make docker-down       Stop containers"
	@echo "  make telegram          Register Telegram channel (once, post-boot)"
	@echo "  make clean             Remove containers + image (state preserved)"
	@echo "  make wipe              DANGER: remove ALL state (confirm required)"
	@echo "  make backup           Snapshot ~/.openclaw to a rolling local archive"
	@echo "  make backup-offsite   Backup + upload archive to Proton Drive"
	@echo "  make restore          Restore from the local archive"
	@echo "  make restore-offsite  Download from Proton Drive and restore"
	@echo "  make logs              Follow gateway logs"
	@echo "  make logs-system       Last 100 lines of logs"
	@echo "  make shell              Shell into the container"
	@echo "  make agents            Show roster, preset, and model lineup"
	@echo "  make status            Deployment and state health (incl. stash)"
	@echo ""
	@echo "Workflow:"
	@echo "  1. make init"
	@echo "  2. Edit $(ENV_FILE):"
	@echo "       NANOGPT_API_KEY, OPENCLAW_GATEWAY_TOKEN,"
	@echo "       AGENT_ROSTER, PERSONALITY_PRESET, model lineup"
	@echo "  3. make secrets-save   # persist keys + lineup to the stash"
	@echo "  4. make setup"
	@echo "  5. make docker-build && make docker-up"
	@echo "  6. make telegram        # once, after first successful boot"
	@echo ""
