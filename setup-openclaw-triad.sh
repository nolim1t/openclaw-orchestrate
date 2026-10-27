#!/usr/bin/env bash
#
# setup-openclaw-triad.sh
# Portable, parameterized OpenClaw triad workspace builder
#
# USAGE:
#   ./setup-openclaw-triad.sh                        # Auto-detect features from env
#   ./setup-openclaw-triad.sh --docker               # Also generate Docker config
#   ./setup-openclaw-triad.sh --docker --wallet xmr  # Docker + Monero treasury
#   ./setup-openclaw-triad.sh --state-dir /srv/openclaw
#
# PORTABILITY:
#   - Every path derives from OPENCLAW_STATE_DIR (default ~/.openclaw)
#   - Optional features activate only when their API keys are present
#   - Docker compose paths are generated from the resolved state dir,
#     then overridable at runtime via docker.env
#   - Whole tree is relocatable: tar it, move it, set env vars, run
#

set -euo pipefail

##############################################################################
# PATHS — everything else derives from these
##############################################################################

STATE_DIR="${OPENCLAW_STATE_DIR:-${HOME}/.openclaw}"
WORKSPACE_ROOT="${STATE_DIR}/workspace-triad"
AGENTS_ROOT="${STATE_DIR}/agents"
PLUGINS_DIR="${STATE_DIR}/plugins"
SHARED_DIR="${STATE_DIR}/shared"
LOGS_DIR="${STATE_DIR}/logs"
HELPERS_DIR="${STATE_DIR}/helpers"

# Container-side paths (independent of host layout)
CONTAINER_HOME="${CONTAINER_HOME:-/home/openclaw}"
CONTAINER_STATE_DIR="${CONTAINER_STATE_DIR:-${CONTAINER_HOME}/.openclaw}"

##############################################################################
# MODEL DEFAULTS (NanoGPT model IDs — override any of these)
##############################################################################

CLAWDIA_MODEL="${CLAWDIA_MODEL:-anthropic/claude-sonnet-4-6}"
CLAWDIO_MODEL="${CLAWDIO_MODEL:-anthropic/claude-opus-4-6}"
ARBITER_MODEL="${ARBITER_MODEL:-anthropic/claude-opus-4-6}"
UTILITY_MODEL="${UTILITY_MODEL:-openai/gpt-5.4-mini}"

CLAWDIA_THINKING="${CLAWDIA_THINKING:-medium}"
CLAWDIO_THINKING="${CLAWDIO_THINKING:-high}"
ARBITER_THINKING="${ARBITER_THINKING:-high}"

##############################################################################
# FEATURE TOGGLES — auto-detected from env vars, overridable
##############################################################################

USE_ELEVENLABS="${USE_ELEVENLABS:-auto}"
USE_TELEGRAM="${USE_TELEGRAM:-auto}"
USE_POLYMARKET="${USE_POLYMARKET:-auto}"
USE_WALLET="${USE_WALLET:-auto}"

WALLET_TYPE="${WALLET_TYPE:-btc}"
WALLET_AGENT="${WALLET_AGENT:-clawdio}"

DOCKER_ENABLE="${DOCKER_ENABLE:-false}"
BASE_IMAGE="${BASE_IMAGE:-python:3.11-slim}"

##############################################################################
# HELPERS
##############################################################################

usage() {
    cat << 'EOF'
Usage: ./setup-openclaw-triad.sh [OPTIONS]

Options:
  --state-dir PATH       Override state directory (default: ~/.openclaw)
  --docker               Generate Dockerfile, docker-compose.yml, docker.env
  --wallet TYPE          Enable crypto treasury (btc | xmr | eth)
  --wallet-agent NAME    Which agent holds the wallet (default: clawdio)
  --non-interactive      Never prompt (use environment only)
  --help                 Show this message

Required:
  NANOGPT_API_KEY        Single key for all models

Optional (feature auto-enables when set):
  ELEVENLABS_API_KEY     TTS voice
  TELEGRAM_BOT_TOKEN     Chat interface
  POLYMARKET_API_KEY     Live trading (otherwise testnet stub only)
  WALLET_PRIVATE_KEY     Crypto treasury

Model overrides:
  CLAWDIA_MODEL, CLAWDIO_MODEL, ARBITER_MODEL, UTILITY_MODEL
  CLAWDIA_THINKING, CLAWDIO_THINKING, ARBITER_THINKING

Docker overrides:
  BASE_IMAGE             Swap base image (default: python:3.11-slim)
  CONTAINER_HOME         Container home (default: /home/openclaw)
  CONTAINER_STATE_DIR    Container state dir (default: $CONTAINER_HOME/.openclaw)

Example:
  export NANOGPT_API_KEY="xxx"
  export WALLET_PRIVATE_KEY="yyy" WALLET_TYPE=xmr
  ./setup-openclaw-triad.sh --docker --wallet xmr
EOF
    exit 0
}

step()  { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
ok()    { printf '   ✓ %s\n' "$1"; }
warn()  { printf '   ⚠ %s\n' "$1"; }
skip()  { printf '   – %s\n' "$1"; }

detect_features() {
    [[ "$USE_ELEVENLABS" == "auto" ]] && USE_ELEVENLABS=$( [[ -n "${ELEVENLABS_API_KEY:-}" ]] && echo true || echo false )
    [[ "$USE_TELEGRAM"   == "auto" ]] && USE_TELEGRAM=$(   [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]] && echo true || echo false )
    [[ "$USE_POLYMARKET" == "auto" ]] && USE_POLYMARKET=$( [[ -n "${POLYMARKET_API_KEY:-}" ]] && echo true || echo false )
    [[ "$USE_WALLET"     == "auto" ]] && USE_WALLET=$(     [[ -n "${WALLET_PRIVATE_KEY:-}" ]] && echo true || echo false )
}

validate_config() {
    step "Validating configuration"

    if [[ -z "${NANOGPT_API_KEY:-}" ]]; then
        warn "NANOGPT_API_KEY not set — agents will not run until it is"
    else
        ok "NanoGPT key present"
    fi

    if [[ "$USE_WALLET" == "true" ]]; then
        if [[ ! "$WALLET_TYPE" =~ ^(btc|xmr|eth)$ ]]; then
            warn "WALLET_TYPE '$WALLET_TYPE' invalid — falling back to btc"
            WALLET_TYPE="btc"
        fi
        if [[ ! "$WALLET_AGENT" =~ ^(clawdia|clawdio|arbiter)$ ]]; then
            warn "WALLET_AGENT '$WALLET_AGENT' invalid — falling back to clawdio"
            WALLET_AGENT="clawdio"
        fi
        ok "Wallet: ${WALLET_TYPE^^} held by ${WALLET_AGENT}"
    fi

    return 0
}

##############################################################################
# DIRECTORY STRUCTURE
##############################################################################

create_directory_structure() {
    step "Creating directory structure"

    mkdir -p "${STATE_DIR}"

    # Agent runtime state (sqlite transcripts live here)
    for agent in clawdia clawdio arbiter; do
        mkdir -p "${AGENTS_ROOT}/${agent}/agent"
        mkdir -p "${AGENTS_ROOT}/${agent}/sessions"
    done

    # Workspaces
    mkdir -p "${WORKSPACE_ROOT}/clawdia"/{journal,analysis/setups,analysis/patterns,scratch}
    mkdir -p "${WORKSPACE_ROOT}/clawdio"/{risk-model/historical-setups,veto-log,audits/weekly}
    mkdir -p "${WORKSPACE_ROOT}/arbiter"/{rulings,dispute-archive,drift-watch}

    # Wallet workspace (only when enabled)
    if [[ "$USE_WALLET" == "true" ]]; then
        mkdir -p "${WORKSPACE_ROOT}/${WALLET_AGENT}/wallet"
    fi

    # Plugins, shared data, logs, helpers
    mkdir -p "${PLUGINS_DIR}/polymarket-clob"/{src,tests,fixtures}
    mkdir -p "${SHARED_DIR}"/{calibration,state}
    mkdir -p "${LOGS_DIR}"
    mkdir -p "${HELPERS_DIR}"

    ok "Tree created under ${STATE_DIR}"
}

##############################################################################
# CONFIG GENERATION
##############################################################################

generate_openclaw_json() {
    step "Generating openclaw.json"

    local tts_clawdia="" tts_clawdio="" tts_arbiter=""
    if [[ "$USE_ELEVENLABS" == "true" ]]; then
        tts_clawdia=$(printf ',\n        "tts": { "providers": { "elevenlabs": { "speakerVoiceId": "%s" } } }' "${ELEVENLABS_VOICE_ID:-default}")
        tts_clawdio=$(printf ',\n        "tts": { "providers": { "elevenlabs": { "speakerVoiceId": "%s" } } }' "${ELEVENLABS_VOICE_ID_CLAWDIO:-${ELEVENLABS_VOICE_ID:-default}}")
        tts_arbiter=$(printf ',\n        "tts": { "providers": { "elevenlabs": { "speakerVoiceId": "%s" } } }' "${ELEVENLABS_VOICE_ID_ARBITER:-${ELEVENLABS_VOICE_ID:-default}}")
    fi

    cat > "${STATE_DIR}/openclaw.json" << EOF
// ${STATE_DIR}/openclaw.json
// Generated by setup-openclaw-triad.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
// Format: JSON5 (comments + trailing commas permitted)
// Validate: openclaw config schema

{
  agents: {
    ownership: "explicit",

    defaults: {
      workspace: "${WORKSPACE_ROOT}",
      cwd: "${WORKSPACE_ROOT}",
      systemAgent: { agentId: "clawdia" },
      heartbeat: { agentId: "clawdio" },
      authInheritance: { agentId: "clawdia" },
      skills: ["market-data", "risk-limits", "trade-log", "docs-search"]
    },

    entries: {
      clawdia: {
        name: "Clawdia",
        workspace: "${WORKSPACE_ROOT}/clawdia",
        agentDir: "${AGENTS_ROOT}/clawdia/agent",
        model: {
          primary: "${CLAWDIA_MODEL}",
          fallbacks: ["${UTILITY_MODEL}"]
        },
        utilityModel: "${UTILITY_MODEL}",
        thinkingDefault: "${CLAWDIA_THINKING}",
        reasoningDefault: "on",
        fastModeDefault: false,
        identity: {
          name: "Clawdia",
          theme: "sassy oracle — purple holographic fox, crimson claws"
        },
        tools: {
          allow: ["read", "write", "edit", "exec", "message", "sessions_list", "sessions_history"],
          deny: ["apply_patch", "browser", "gateway", "canvas", "nodes"]
        },
        subagents: { allowAgents: ["clawdio", "arbiter"] },
        sandbox: { mode: "all", scope: "agent", workspaceAccess: "none" }${tts_clawdia}
      },

      clawdio: {
        name: "Clawdio",
        workspace: "${WORKSPACE_ROOT}/clawdio",
        agentDir: "${AGENTS_ROOT}/clawdio/agent",
        model: {
          primary: "${CLAWDIO_MODEL}",
          fallbacks: ["${CLAWDIA_MODEL}"]
        },
        utilityModel: "${UTILITY_MODEL}",
        thinkingDefault: "${CLAWDIO_THINKING}",
        reasoningDefault: "on",
        fastModeDefault: false,
        identity: {
          name: "Clawdio",
          theme: "steady guardian — navy wolf, silver spectacles"
        },
        tools: {
          allow: ["read", "write", "exec", "message", "sessions_list", "sessions_history"],
          deny: ["apply_patch", "browser", "gateway", "canvas", "nodes"]
        },
        subagents: { allowAgents: [] },
        sandbox: { mode: "all", scope: "agent", workspaceAccess: "none" }${tts_clawdio}
      },

      arbiter: {
        name: "The Arbiter",
        workspace: "${WORKSPACE_ROOT}/arbiter",
        agentDir: "${AGENTS_ROOT}/arbiter/agent",
        model: {
          primary: "${ARBITER_MODEL}",
          fallbacks: ["${CLAWDIA_MODEL}"]
        },
        utilityModel: "${UTILITY_MODEL}",
        thinkingDefault: "${ARBITER_THINKING}",
        reasoningDefault: "on",
        fastModeDefault: false,
        identity: {
          name: "The Arbiter",
          theme: "wise mediator — silver owl, iridescent violet"
        },
        tools: {
          allow: ["read", "message", "sessions_list", "sessions_history", "sessions_send", "session_status"],
          deny: ["write", "edit", "apply_patch", "exec", "process", "browser", "gateway", "canvas", "nodes", "cron"]
        },
        subagents: { allowAgents: [] },
        sandbox: { mode: "all", scope: "agent", workspaceAccess: "none" }${tts_arbiter}
      }
    }
  },

  bindings: [
    { agentId: "clawdia", match: { channel: "telegram", accountId: "default" } },
    { agentId: "clawdio", match: { channel: "telegram", accountId: "risk" } },
    { agentId: "arbiter", match: { channel: "telegram", accountId: "arbiter" } },
    { agentId: "clawdia", match: { channel: "telegram", accountId: "" } }
  ],

  talk: { agentId: "clawdia" },

  channels: {
    telegram: {
      allowFrom: ["${TELEGRAM_USER_ID:-}"]
    }
  },

  tools: { swarm: false },
  memory: { enabled: true },
  web: { enabled: true }
}
EOF

    ok "openclaw.json (paths resolved to ${STATE_DIR})"
}

generate_trading_json() {
    step "Generating trading.json"

    mkdir -p "${PLUGINS_DIR}/polymarket-clob"

    cat > "${PLUGINS_DIR}/polymarket-clob/trading.json" << EOF
{
  "mode": "testnet",
  "exchange": "polymarket_clob",

  "websocket_endpoint": "wss://ws.polymarket.com/clob",
  "rest_endpoint": "https://gamma-api.polymarket.com",

  "risk_limits": {
    "max_position_size_pct": 5,
    "daily_loss_limit_pct": 15,
    "max_daily_trades": 20,
    "min_risk_reward": "2:1",
    "max_single_trade_loss_pct": 8,
    "max_concentration_per_asset_pct": 25
  },

  "position_scaling": {
    "bull_market_max": 5,
    "bear_market_max": 2,
    "sideways_max": 3
  },

  "profit_taking": {
    "scale_out_levels": [25, 50, 75],
    "trail_stop_after_pct": 10
  },

  "stop_losses": {
    "hard_stop_pct": 8,
    "mental_stop_pct": 5,
    "time_based_exit_hours": 24
  },

  "heartbeat_interval_minutes": 60,
  "dispute_timeout_ms": 500,

  "logging": {
    "level": "INFO",
    "trade_log_path": "${SHARED_DIR}/trade-ledger.jsonl",
    "incident_log_path": "${LOGS_DIR}/incidents.log"
  }
}
EOF

    ok "trading.json (log paths resolved)"
}

generate_env_template() {
    step "Generating .env template"

    cat > "${STATE_DIR}/.env.example" << 'EOF'
# =============================================================================
# NANOGPT — REQUIRED (single key, all models)
# =============================================================================
NANOGPT_API_KEY=

# =============================================================================
# OPTIONAL — uncomment and fill to enable the feature
# =============================================================================

# ElevenLabs TTS (per-agent voice overrides supported)
# ELEVENLABS_API_KEY=
# ELEVENLABS_VOICE_ID=
# ELEVENLABS_VOICE_ID_CLAWDIO=
# ELEVENLABS_VOICE_ID_ARBITER=

# Telegram chat interface
# TELEGRAM_BOT_TOKEN=
# TELEGRAM_USER_ID=

# Polymarket CLOB (omit to stay on testnet stubs)
# POLYMARKET_API_KEY=
# POLYMARKET_SECRET=
# POLYMARKET_ASSET_ID=

# =============================================================================
# CRYPTO TREASURY — exactly one currency
# =============================================================================
# WALLET_TYPE=btc        # or xmr (privacy) or eth
# WALLET_PRIVATE_KEY=
EOF

    if [[ ! -f "${STATE_DIR}/.env" ]]; then
        cp "${STATE_DIR}/.env.example" "${STATE_DIR}/.env"
    fi
    chmod 600 "${STATE_DIR}/.env"

    ok ".env ready (chmod 600, existing file preserved)"
}

##############################################################################
# AGENT WORKSPACE FILES
##############################################################################

generate_agent_files() {
    step "Generating agent workspace files"

    for agent in clawdia clawdio arbiter; do
        local display model thinking
        case "$agent" in
            clawdia) display="Clawdia";      model="$CLAWDIA_MODEL"; thinking="$CLAWDIA_THINKING" ;;
            clawdio) display="Clawdio";      model="$CLAWDIO_MODEL"; thinking="$CLAWDIO_THINKING" ;;
            arbiter) display="The Arbiter";  model="$ARBITER_MODEL"; thinking="$ARBITER_THINKING" ;;
        esac

        cat > "${WORKSPACE_ROOT}/${agent}/IDENTITY.md" << EOF
# IDENTITY.md — ${display}

**Runtime:** OpenClaw Triad
**Provider:** NanoGPT (\`https://nano-gpt.com/api/v1\`)
**Model:** \`${model}\`
**Thinking:** \`${thinking}\`
**Workspace:** \`${WORKSPACE_ROOT}/${agent}\`
**Generated:** $(date -u +"%Y-%m-%d")

---

See \`SOUL.md\` for temperament and \`AGENTS.md\` for role and protocol.
EOF

        cat > "${WORKSPACE_ROOT}/${agent}/AGENTS.md" << EOF
# AGENTS.md — ${display}'s Role

| Field | Value |
|---|---|
| Agent id | \`${agent}\` |
| Model | \`${model}\` |
| Thinking | \`${thinking}\` |
| Workspace | \`${WORKSPACE_ROOT}/${agent}\` |
| State dir | \`${AGENTS_ROOT}/${agent}/agent\` |

---

Governance: no single agent executes alone. Alignment between Clawdia and
Clawdio authorises execution; disagreement escalates to the Arbiter, whose
ruling is binding.
EOF

        cat > "${WORKSPACE_ROOT}/${agent}/SOUL.md" << EOF
# SOUL.md — ${display}

Placeholder. Replace with the full archetype definition.

- **Clawdia** — The Sassy Oracle: intuitive, impulsive, high conviction
- **Clawdio** — The Steady Guardian: prudent, analytical, capital-first
- **The Arbiter** — The Wise Mediator: neutral, synthesising, final authority
EOF

        cat > "${WORKSPACE_ROOT}/${agent}/DREAMS.md" << EOF
# DREAMS.md — ${display}

Placeholder. Track milestones and calibration targets here.

**Current phase:** testnet
EOF

        touch "${WORKSPACE_ROOT}/${agent}/journal/$(date +%Y-%m-%d).md"
        ok "${display} (${model})"
    done
}

##############################################################################
# CONDITIONAL: WALLET
##############################################################################

generate_wallet_integration() {
    if [[ "$USE_WALLET" != "true" ]]; then
        skip "Wallet (no WALLET_PRIVATE_KEY)"
        return
    fi

    step "Generating ${WALLET_TYPE^^} treasury for ${WALLET_AGENT}"

    mkdir -p "${WORKSPACE_ROOT}/${WALLET_AGENT}/wallet"

    cat > "${WORKSPACE_ROOT}/${WALLET_AGENT}/wallet/config.json" << EOF
{
  "enabled": true,
  "type": "${WALLET_TYPE}",
  "custodian_agent": "${WALLET_AGENT}",
  "purpose": "Treasury — holds realised profits, gates withdrawals",
  "security": {
    "key_source": "environment_variable",
    "key_env_var": "WALLET_PRIVATE_KEY",
    "cold_storage_recommended": true,
    "withdrawal_requires_approval": true,
    "max_auto_withdrawal_usd": 0
  },
  "audit": {
    "log_path": "${LOGS_DIR}/wallet.log",
    "log_all_queries": true
  },
  "notifications": {
    "on_deposit_over_usd": 100,
    "on_withdrawal_request": true
  }
}
EOF

    cat > "${PLUGINS_DIR}/polymarket-clob/src/wallet_manager.py" << 'PYEOF'
#!/usr/bin/env python3
"""
Treasury wallet manager — BTC / XMR / ETH.

Design rules:
  - Private key is read from the environment, never from disk.
  - Every operation is appended to an audit log.
  - Withdrawals require explicit human approval by default.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path


@dataclass(frozen=True)
class WalletConfig:
    wallet_type: str
    custodian_agent: str
    log_path: Path
    approval_required: bool


class WalletManager:
    SUPPORTED = ("btc", "xmr", "eth")

    def __init__(self, config_path: Path) -> None:
        self.config = self._load(config_path)
        self._private_key = os.environ.get("WALLET_PRIVATE_KEY", "")
        if not self._private_key:
            raise RuntimeError("WALLET_PRIVATE_KEY is not set")

    def _load(self, path: Path) -> WalletConfig:
        data = json.loads(path.read_text())
        if data["type"] not in self.SUPPORTED:
            raise ValueError(f"Unsupported wallet type: {data['type']}")
        return WalletConfig(
            wallet_type=data["type"],
            custodian_agent=data["custodian_agent"],
            log_path=Path(data["audit"]["log_path"]),
            approval_required=data["security"]["withdrawal_requires_approval"],
        )

    # -- read-only operations ------------------------------------------------

    def address(self) -> str:
        """Derive the public receive address. Currency-specific."""
        raise NotImplementedError(f"address() for {self.config.wallet_type}")

    def balance(self) -> float:
        """Query confirmed balance. Currency-specific."""
        raise NotImplementedError(f"balance() for {self.config.wallet_type}")

    # -- mutating operations -------------------------------------------------

    def request_withdrawal(self, amount: float, destination: str) -> str:
        """Queue a withdrawal. Returns a status string."""
        if self.config.approval_required:
            self._audit("withdrawal_requested", amount, "pending_approval", destination)
            return "pending_approval"

        self._audit("withdrawal_sent", amount, "sent", destination)
        return "sent"

    # -- audit ---------------------------------------------------------------

    def _audit(self, kind: str, amount: float, status: str, destination: str = "") -> None:
        self.config.log_path.parent.mkdir(parents=True, exist_ok=True)
        entry = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "kind": kind,
            "amount": amount,
            "status": status,
            "destination": destination,
            "wallet_type": self.config.wallet_type,
            "agent": self.config.custodian_agent,
        }
        with self.config.log_path.open("a") as fh:
            fh.write(json.dumps(entry) + "\n")


if __name__ == "__main__":
    state_dir = Path(os.environ.get("OPENCLAW_STATE_DIR", Path.home() / ".openclaw"))
    agent = os.environ.get("WALLET_AGENT", "clawdio")
    cfg = state_dir / "workspace-triad" / agent / "wallet" / "config.json"

    if not cfg.exists():
        raise SystemExit(f"No wallet config at {cfg}")

    wm = WalletManager(cfg)
    print(f"Treasury: {wm.config.wallet_type.upper()} custodied by {wm.config.custodian_agent}")
    print(f"Audit log: {wm.config.log_path}")
PYEOF

    ok "wallet_manager.py + config.json for ${WALLET_AGENT}"
}

##############################################################################
# CONDITIONAL: TELEGRAM
##############################################################################

generate_telegram_bot() {
    if [[ "$USE_TELEGRAM" != "true" ]]; then
        skip "Telegram bot (no TELEGRAM_BOT_TOKEN)"
        return
    fi

    step "Generating Telegram bot"

    mkdir -p "${PLUGINS_DIR}/telegram-bot"

    cat > "${PLUGINS_DIR}/telegram-bot/bot.py" << 'PYEOF'
#!/usr/bin/env python3
"""Telegram front-end for the OpenClaw triad."""

import logging
import os

from telegram import Update
from telegram.ext import (
    Application,
    CommandHandler,
    ContextTypes,
    MessageHandler,
    filters,
)

logging.basicConfig(
    format="%(asctime)s %(levelname)s %(name)s — %(message)s",
    level=logging.INFO,
)
log = logging.getLogger("openclaw.telegram")

TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
ALLOWED = {u.strip() for u in os.environ.get("TELEGRAM_USER_ID", "").split(",") if u.strip()}


def authorised(update: Update) -> bool:
    return str(update.effective_user.id) in ALLOWED


async def cmd_start(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not authorised(update):
        return
    await update.message.reply_text(
        "OpenClaw triad online.\n"
        "/clawdia — opportunity scout\n"
        "/clawdio — risk guardian\n"
        "/arbiter — mediator"
    )


async def relay(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Forward an authorised message to the OpenClaw gateway."""
    if not authorised(update):
        log.warning("Rejected message from %s", update.effective_user.id)
        return

    # TODO: route to the gateway (HTTP or socket) and stream the reply back.
    await update.message.reply_text("Received. Routing to the triad…")


def main() -> None:
    if not TOKEN:
        raise SystemExit("TELEGRAM_BOT_TOKEN is not set")
    if not ALLOWED:
        raise SystemExit("TELEGRAM_USER_ID is not set — refusing to run open to everyone")

    app = Application.builder().token(TOKEN).build()
    app.add_handler(CommandHandler("start", cmd_start))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, relay))
    app.run_polling()


if __name__ == "__main__":
    main()
PYEOF

    ok "telegram bot scaffold"
}

##############################################################################
# CONDITIONAL: DOCKER  (paths derived from the configured state dir)
##############################################################################

generate_docker_config() {
    if [[ "$DOCKER_ENABLE" != "true" ]]; then
        skip "Docker (pass --docker to enable)"
        return
    fi

    step "Generating Docker configuration"

    # --- resolve absolute host paths (compose does not expand ~) ------------
    local host_state host_workspace host_agents host_shared host_logs host_plugins
    host_state="$(cd "${STATE_DIR}" && pwd)"
    host_workspace="${host_state}/workspace-triad"
    host_agents="${host_state}/agents"
    host_shared="${host_state}/shared"
    host_logs="${host_state}/logs"
    host_plugins="${host_state}/plugins"

    local app_uid app_gid
    app_uid="$(id -u)"
    app_gid="$(id -g)"

    # --- docker.env : interpolation variables, NO SECRETS -------------------
    cat > "${STATE_DIR}/docker.env" << EOF
# Docker Compose interpolation — generated $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Contains no secrets. Safe to commit.
#
# Usage:  docker compose --env-file docker.env up -d
# Secrets stay in .env, injected into the container via env_file.

COMPOSE_PROJECT_NAME=openclaw-triad

# ---- Host paths (derived from OPENCLAW_STATE_DIR) ----
OPENCLAW_HOST_STATE_DIR=${host_state}
OPENCLAW_CONFIG_FILE=${host_state}/openclaw.json
OPENCLAW_WORKSPACE_DIR=${host_workspace}
OPENCLAW_AGENTS_DIR=${host_agents}
OPENCLAW_SHARED_DIR=${host_shared}
OPENCLAW_LOGS_DIR=${host_logs}
OPENCLAW_PLUGINS_DIR=${host_plugins}
OPENCLAW_ENV_FILE=.env

# ---- Container paths ----
CONTAINER_HOME=${CONTAINER_HOME}
CONTAINER_STATE_DIR=${CONTAINER_STATE_DIR}

# ---- Ownership (matches host user so bind mounts stay writable) ----
APP_UID=${app_uid}
APP_GID=${app_gid}

# ---- Resources ----
CONTAINER_MEM_LIMIT=1g
CONTAINER_CPUS=1.0
EOF

    # --- docker-compose.yml -------------------------------------------------
    cat > "${STATE_DIR}/docker-compose.yml" << 'EOF'
# Generated by setup-openclaw-triad.sh
#
# Every path is a variable, defaulting to whatever the setup script resolved.
# Change docker.env to relocate the stack without regenerating anything.
#
#   docker compose --env-file docker.env up -d
#
name: ${COMPOSE_PROJECT_NAME:-openclaw-triad}

services:
  openclaw-triad:
    build:
      context: .
      dockerfile: Dockerfile
      args:
        BASE_IMAGE: ${BASE_IMAGE:-python:3.11-slim}
        CONTAINER_HOME: ${CONTAINER_HOME:-/home/openclaw}
        CONTAINER_STATE_DIR: ${CONTAINER_STATE_DIR:-/home/openclaw/.openclaw}
        APP_UID: ${APP_UID:-1000}
        APP_GID: ${APP_GID:-1000}

    image: ${COMPOSE_PROJECT_NAME:-openclaw-triad}:local
    container_name: ${COMPOSE_PROJECT_NAME:-openclaw-triad}
    restart: unless-stopped

    # Run as the host user so bind-mounted volumes stay writable.
    user: "${APP_UID:-1000}:${APP_GID:-1000}"

    # Secrets only. Paths come from docker.env at the compose level.
    env_file:
      - ${OPENCLAW_ENV_FILE:-.env}

    environment:
      OPENCLAW_STATE_DIR: ${CONTAINER_STATE_DIR:-/home/openclaw/.openclaw}
      OPENCLAW_WORKSPACE_DIR: ${CONTAINER_STATE_DIR:-/home/openclaw/.openclaw}/workspace-triad
      OPENCLAW_CONFIG_PATH: ${CONTAINER_STATE_DIR:-/home/openclaw/.openclaw}/openclaw.json
      PYTHONDONTWRITEBYTECODE: "1"
      PYTHONPYCACHEPREFIX: /tmp/pycache

    volumes:
      # Config is read-only: the container consumes it, never rewrites it.
      - ${OPENCLAW_CONFIG_FILE:-./openclaw.json}:${CONTAINER_STATE_DIR:-/home/openclaw/.openclaw}/openclaw.json:ro

      # Agent workspaces — the markdown each agent loads.
      - ${OPENCLAW_WORKSPACE_DIR:-./workspace-triad}:${CONTAINER_STATE_DIR:-/home/openclaw/.openclaw}/workspace-triad

      # Session transcripts and sqlite state — must persist.
      - ${OPENCLAW_AGENTS_DIR:-./agents}:${CONTAINER_STATE_DIR:-/home/openclaw/.openclaw}/agents

      # Append-only ledgers and calibration data.
      - ${OPENCLAW_SHARED_DIR:-./shared}:${CONTAINER_STATE_DIR:-/home/openclaw/.openclaw}/shared

      # Logs.
      - ${OPENCLAW_LOGS_DIR:-./logs}:${CONTAINER_STATE_DIR:-/home/openclaw/.openclaw}/logs

      # Plugin code.
      - ${OPENCLAW_PLUGINS_DIR:-./plugins}:${CONTAINER_STATE_DIR:-/home/openclaw/.openclaw}/plugins

    networks:
      - openclaw-net

    # ---- Hardening ----
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    read_only: true
    tmpfs:
      - /tmp:size=64m,mode=1777
      - /var/tmp:size=16m,mode=1777
      - ${CONTAINER_HOME:-/home/openclaw}/.cache:size=64m,mode=0700

    # ---- Resources ----
    mem_limit: ${CONTAINER_MEM_LIMIT:-1g}
    cpus: ${CONTAINER_CPUS:-1.0}

    # Replace with a real readiness probe once the gateway exposes one.
    healthcheck:
      test: ["CMD-SHELL", "test -f ${CONTAINER_STATE_DIR:-/home/openclaw/.openclaw}/openclaw.json"]
      interval: 60s
      timeout: 5s
      retries: 3
      start_period: 20s

    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

networks:
  openclaw-net:
    driver: bridge
EOF

    # --- Dockerfile ---------------------------------------------------------
    cat > "${STATE_DIR}/Dockerfile" << 'EOF'
# syntax=docker/dockerfile:1
#
# Generated by setup-openclaw-triad.sh
#
# If OpenClaw publishes an official image, point BASE_IMAGE at it and the
# Python layer below becomes redundant:
#   docker compose --env-file docker.env build --build-arg BASE_IMAGE=<official>

ARG BASE_IMAGE=python:3.11-slim
ARG CONTAINER_HOME=/home/openclaw
ARG CONTAINER_STATE_DIR=/home/openclaw/.openclaw
ARG APP_UID=1000
ARG APP_GID=1000

FROM ${BASE_IMAGE}

ARG CONTAINER_HOME
ARG CONTAINER_STATE_DIR
ARG APP_UID
ARG APP_GID

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    HOME=${CONTAINER_HOME} \
    OPENCLAW_STATE_DIR=${CONTAINER_STATE_DIR} \
    OPENCLAW_CONFIG_PATH=${CONTAINER_STATE_DIR}/openclaw.json \
    OPENCLAW_WORKSPACE_DIR=${CONTAINER_STATE_DIR}/workspace-triad \
    PATH=${CONTAINER_HOME}/.local/bin:${PATH}

# Non-root user whose uid/gid match the host, so bind mounts stay writable.
RUN groupadd --gid "${APP_GID}" openclaw \
 && useradd --uid "${APP_UID}" --gid "${APP_GID}" \
            --create-home --home-dir "${CONTAINER_HOME}" \
            --shell /bin/bash openclaw \
 && mkdir -p "${CONTAINER_STATE_DIR}" \
 && chown -R "${APP_UID}:${APP_GID}" "${CONTAINER_HOME}"

WORKDIR ${CONTAINER_HOME}

COPY --chown=${APP_UID}:${APP_GID} requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir --requirement /tmp/requirements.txt \
 && rm -f /tmp/requirements.txt

USER openclaw

# Nothing is baked in. Config, workspaces, state and logs all arrive as
# bind mounts at runtime, so the image stays generic and reusable.
#
# TODO: install the OpenClaw runtime itself. Verify the official package name
# and installation method at https://docs.openclaw.ai before relying on this.
#   RUN npm install -g <official-openclaw-package>

CMD ["openclaw", "start"]
EOF

    # --- requirements.txt ---------------------------------------------------
    cat > "${STATE_DIR}/requirements.txt" << 'EOF'
websockets>=12.0
requests>=2.31.0
python-telegram-bot>=20.7
python-dotenv>=1.0.0
EOF

    # --- .dockerignore ------------------------------------------------------
    cat > "${STATE_DIR}/.dockerignore" << 'EOF'
# Secrets — never enter the build context
.env
*.key
*.pem

# Local state — supplied as bind mounts instead
agents/
shared/
logs/
workspace-triad/

# Noise
.git
.gitignore
*.pyc
__pycache__/
tests/
fixtures/
*.md
EOF

    # --- .gitignore ---------------------------------------------------------
    cat > "${STATE_DIR}/.gitignore" << 'EOF'
.env
docker.env.local
*.key
*.pem
agents/
shared/
logs/
__pycache__/
*.pyc
EOF

    ok "docker-compose.yml (paths from ${host_state})"
    ok "docker.env (relocate without rebuilding)"
    ok "Dockerfile (uid ${app_uid}:${app_gid}, non-root, read-only rootfs)"
    ok "requirements.txt, .dockerignore, .gitignore"
}

##############################################################################
# SHARED DATA
##############################################################################

generate_shared_data() {
    step "Initialising shared data"

    cat > "${SHARED_DIR}/trade-ledger.jsonl" << 'EOF'
# Append-only trade ledger. One JSON object per line.
# Written by the plugin, never by agents directly.
EOF

    echo '{}' > "${SHARED_DIR}/state/daily-counters.json"

    cat > "${SHARED_DIR}/calibration/README.md" << 'EOF'
# Calibration Archive

Tracks each agent's accuracy over time.

| File | Measures |
|---|---|
| `clawdia-hunches.csv` | Intuition hit rate by setup category |
| `clawdio-vetoes.csv` | Whether denied trades would have failed |
| `arbiter-rulings.csv` | Whether synthesised rulings were vindicated |

Reviewed weekly.
EOF

    ok "ledger, counters, calibration"
}

##############################################################################
# SUMMARY
##############################################################################

print_summary() {
    local tick="✓" cross="✗"
    local f_tts f_tg f_pm f_wal f_doc
    [[ "$USE_ELEVENLABS" == "true" ]] && f_tts="$tick" || f_tts="$cross"
    [[ "$USE_TELEGRAM"   == "true" ]] && f_tg="$tick"  || f_tg="$cross"
    [[ "$USE_POLYMARKET" == "true" ]] && f_pm="$tick"  || f_pm="$cross"
    [[ "$USE_WALLET"     == "true" ]] && f_wal="$tick" || f_wal="$cross"
    [[ "$DOCKER_ENABLE"  == "true" ]] && f_doc="$tick" || f_doc="$cross"

    cat << EOF

════════════════════════════════════════════════════════
  SETUP COMPLETE
════════════════════════════════════════════════════════

  State directory   ${STATE_DIR}
  Workspaces        ${WORKSPACE_ROOT}
  Agent state       ${AGENTS_ROOT}

  Features
    NanoGPT API        ✓  (required)
    ElevenLabs TTS     ${f_tts}
    Telegram bot       ${f_tg}
    Polymarket CLOB    ${f_pm}
    Crypto treasury    ${f_wal}$( [[ "$USE_WALLET" == "true" ]] && echo "  (${WALLET_TYPE^^} · ${WALLET_AGENT})" )
    Docker             ${f_doc}

  Models
    Clawdia            ${CLAWDIA_MODEL}
    Clawdio            ${CLAWDIO_MODEL}
    Arbiter            ${ARBITER_MODEL}
    Utility            ${UTILITY_MODEL}

EOF

    if [[ "$DOCKER_ENABLE" == "true" ]]; then
        cat << EOF
  Docker
    cd ${STATE_DIR}
    docker compose --env-file docker.env build
    docker compose --env-file docker.env up -d

    Relocate without rebuilding — edit docker.env:
      OPENCLAW_HOST_STATE_DIR, OPENCLAW_WORKSPACE_DIR, CONTAINER_STATE_DIR …

EOF
    fi

    cat << EOF
  Next
    1. Fill in ${STATE_DIR}/.env
    2. openclaw config schema
    3. openclaw start

════════════════════════════════════════════════════════
EOF
}

##############################################################################
# MAIN
##############################################################################

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --state-dir)
                [[ -n "${2:-}" ]] || { echo "--state-dir needs a path"; exit 1; }
                STATE_DIR="$2"
                WORKSPACE_ROOT="${STATE_DIR}/workspace-triad"
                AGENTS_ROOT="${STATE_DIR}/agents"
                PLUGINS_DIR="${STATE_DIR}/plugins"
                SHARED_DIR="${STATE_DIR}/shared"
                LOGS_DIR="${STATE_DIR}/logs"
                HELPERS_DIR="${STATE_DIR}/helpers"
                shift 2
                ;;
            --docker)       DOCKER_ENABLE=true; shift ;;
            --wallet)
                [[ -n "${2:-}" ]] || { echo "--wallet needs a type (btc|xmr|eth)"; exit 1; }
                WALLET_TYPE="$2"; USE_WALLET=true; shift 2
                ;;
            --wallet-agent)
                [[ -n "${2:-}" ]] || { echo "--wallet-agent needs a name"; exit 1; }
                WALLET_AGENT="$2"; shift 2
                ;;
            --non-interactive) shift ;;
            --help|-h)      usage ;;
            *) echo "Unknown option: $1"; echo; usage ;;
        esac
    done

    detect_features
    validate_config

    create_directory_structure
    generate_openclaw_json
    generate_trading_json
    generate_env_template
    generate_agent_files
    generate_shared_data

    generate_telegram_bot
    generate_wallet_integration
    generate_docker_config

    print_summary
}

main "$@"