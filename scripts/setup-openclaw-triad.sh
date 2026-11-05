#!/usr/bin/env bash
#
# setup-openclaw-triad.sh
# Portable, parameterized OpenClaw triad workspace builder
#
# USAGE:
#   ./setup-openclaw-triad.sh                        # Uses default triad
#   ./setup-openclaw-triad.sh --docker               # Docker + default triad
#   ./setup-openclaw-triad.sh --roster "oracle,risk,arbiter"  # Custom names
#   ./setup-openclaw-triad.sh --state-dir /srv/openclaw
#   ./setup-openclaw-triad.sh --personality "sassy"  # Personality preset
#
# PORTABILITY:
#   - Every path derives from OPENCLAW_STATE_DIR (default ~/.openclaw)
#   - Optional features activate only when their API keys are present
#   - Docker compose paths are generated from the resolved state dir
#   - Whole tree is relocatable: tar it, move it, set env vars, run
#
# CUSTOMIZATION — Agent roster & personalities:
#   AGENT_ROSTER           Comma-separated agent names (default: clawdia,clawdio,arbiter)
#   AGENT_{name}_ROLE      Role description for each agent
#   AGENT_{name}_THEME     Visual/personality theme (e.g. "purple holographic fox")
#   AGENT_{name}_MODEL     Model override for specific agent
#   AGENT_{name}_THINKING  Thinking depth: light|medium|high (default: medium)
#   PERSONALITY_PRESET     Quick personality packs: default|bold|conservative|mystic
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
# CUSTOMIZABLE AGENT SYSTEM
##############################################################################

# Default agent roster — easily overridden
DEFAULT_AGENT_ROSTER="clawdia,clawdio,arbiter"
AGENT_ROSTER="${AGENT_ROSTER:-$DEFAULT_AGENT_ROSTER}"

# Personality presets — quick-start templates
# Override any of these with individual AGENT_{name}_* vars
declare -A PERSONALITY_PRESETS=(
    [default]="sassy oracle|steady guardian|wise mediator"
    [bold]="reckless visionary|impulse trader|momentum hunter"
    [conservative]="risk sentinel|capital warden|loss avenger"
    [mystic]="intuitive seer|dream reader|probability monk"
    [quant]="data hermit|statistical phantom|arbitrage ghost"
)

PERSONALITY_PRESET="${PERSONALITY_PRESET:-default}"
PRESET_THEMES="${PERSONALITY_PRESETS[$PERSONALITY_PRESET]:-${PERSONALITY_PRESETS[default]}}"

# Split preset themes into array (pipe-delimited)
IFS='|' read -ra PRESET_THEME_ARRAY <<< "$PRESET_THEMES"

# Model assignments — one key per agent in roster order
CLAWDIA_MODEL="${CLAWDIA_MODEL:-${CLAWDIA_MODEL:-anthropic/claude-sonnet-4-6}}"
CLAWDIO_MODEL="${CLAWDIO_MODEL:-anthropic/claude-opus-4-6}"
ARBITER_MODEL="${ARBITER_MODEL:-anthropic/claude-opus-4-6}"
UTILITY_MODEL="${UTILITY_MODEL:-openai/gpt-5.4-mini}"

CLAWDIA_THINKING="${CLAWDIA_THINKING:-medium}"
CLAWDIO_THINKING="${CLAWDIO_THINKING:-high}"
ARBITER_THINKING="${ARBITER_THINKING:-high}"

# Helper to get model for agent (checks AGENT_{name}_MODEL first, then falls back)
get_agent_model() {
    local name="$1"
    local var_name="AGENT_${name^^}_MODEL"
    local val="${!var_name:-}"
    
    if [[ -n "$val" ]]; then
        echo "$val"
    else
        # Fall back to legacy vars for default names
        case "$name" in
            clawdia) echo "$CLAWDIA_MODEL" ;;
            clawdio) echo "$CLAWDIO_MODEL" ;;
            arbiter) echo "$ARBITER_MODEL" ;;
            *)       echo "$UTILITY_MODEL" ;;
        esac
    fi
}

# Helper to get thinking level for agent
get_agent_thinking() {
    local name="$1"
    local var_name="AGENT_${name^^}_THINKING"
    local val="${!var_name:-}"
    
    if [[ -n "$val" ]]; then
        echo "$val"
    else
        case "$name" in
            clawdia) echo "$CLAWDIA_THINKING" ;;
            clawdio) echo "$CLAWDIO_THINKING" ;;
            arbiter) echo "$ARBITER_THINKING" ;;
            *)       echo "medium" ;;
        esac
    fi
}

# Helper to get theme/personality for agent
get_agent_theme() {
    local idx="$1"
    local name="$2"
    local var_name="AGENT_${name^^}_THEME"
    local val="${!var_name:-}"
    
    if [[ -n "$val" ]]; then
        echo "$val"
    elif [[ $idx -lt ${#PRESET_THEME_ARRAY[@]} ]]; then
        echo "${PRESET_THEME_ARRAY[$idx]}"
    else
        echo "custom agent"
    fi
}

# Helper to get role description
get_agent_role() {
    local idx="$1"
    local name="$2"
    local var_name="AGENT_${name^^}_ROLE"
    local val="${!var_name:-}"
    
    if [[ -n "$val" ]]; then
        echo "$val"
    else
        # Default roles based on preset index
        case $idx in
            0) echo "Opportunity Scout — finds edges, generates signals" ;;
            1) echo "Risk Guardian — enforces limits, protects capital" ;;
            2) echo "Arbiter — mediates disputes, makes binding rulings" ;;
            *) echo "Autonomous Agent — contributes to triad governance" ;;
        esac
    fi
}

# Feature toggles — auto-detected from env vars, overridable
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
  --roster NAMES         Comma-separated agent names (default: clawdia,clawdio,arbiter)
  --preset PACK          Personality pack: default|bold|conservative|mystic|quant
  --non-interactive      Never prompt (use environment only)
  --help                 Show this message

Required:
  NANOGPT_API_KEY        Single key for all models

Optional (feature auto-enables when set):
  ELEVENLABS_API_KEY     TTS voice
  TELEGRAM_BOT_TOKEN     Chat interface
  POLYMARKET_API_KEY     Live trading (otherwise testnet stub only)
  WALLET_PRIVATE_KEY     Crypto treasury

Agent Customization:
  AGENT_ROSTER           "oracle,risk,arbiter" — comma-separated names
  AGENT_{name}_THEME     Personality theme per agent
  AGENT_{name}_ROLE      Role description per agent
  AGENT_{name}_MODEL     Model override per agent
  AGENT_{name}_THINKING  Thinking depth: light|medium|high

Personality Presets:
  default  — Sassy oracle / Steady guardian / Wise mediator
  bold     — Reckless visionary / Impulse trader / Momentum hunter
  conservative — Risk sentinel / Capital warden / Loss avenger
  mystic   — Intuitive seer / Dream reader / Probability monk
  quant    — Data hermit / Statistical phantom / Arbitrage ghost

Example:
  export NANOGPT_API_KEY="xxx"
  export AGENT_ROSTER="seer,sentinel,judge"
  export AGENT_SEER_THEME="mystical raven with crystal orb"
  export AGENT_SEER_ROLE="Probability diviner — reads market omens"
  ./setup-openclaw-triad.sh --preset mystic
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

    # Validate agent roster
    IFS=',' read -ra AGENT_NAMES <<< "$AGENT_ROSTER"
    local agent_count=${#AGENT_NAMES[@]}
    
    if [[ $agent_count -lt 2 ]]; then
        warn "Agent roster has fewer than 2 agents — minimum recommended for triad governance"
    fi
    
    ok "Agent roster: ${AGENT_ROSTER} (${agent_count} agents)"

    if [[ "$USE_WALLET" == "true" ]]; then
        if [[ ! "$WALLET_TYPE" =~ ^(btc|xmr|eth)$ ]]; then
            warn "WALLET_TYPE '$WALLET_TYPE' invalid — falling back to btc"
            WALLET_TYPE="btc"
        fi
        # Check if wallet agent exists in roster
        local wallet_found=false
        for name in "${AGENT_NAMES[@]}"; do
            [[ "$name" == "$WALLET_AGENT" ]] && wallet_found=true && break
        done
        if [[ "$wallet_found" != "true" ]]; then
            warn "WALLET_AGENT '$WALLET_AGENT' not in roster — will be created anyway"
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

    # Agent runtime state — one per agent in roster
    IFS=',' read -ra AGENT_NAMES <<< "$AGENT_ROSTER"
    for name in "${AGENT_NAMES[@]}"; do
        mkdir -p "${AGENTS_ROOT}/${name}/agent"
        mkdir -p "${AGENTS_ROOT}/${name}/sessions"
    done

    # Workspaces — dynamic based on roster
    for i in "${!AGENT_NAMES[@]}"; do
        local name="${AGENT_NAMES[$i]}"
        mkdir -p "${WORKSPACE_ROOT}/${name}"/{journal,analysis/setups,analysis/patterns,scratch}
    done

    # Add wallet workspace (only when enabled)
    if [[ "$USE_WALLET" == "true" ]]; then
        mkdir -p "${WORKSPACE_ROOT}/${WALLET_AGENT}/wallet"
    fi

    # Plugins, shared data, logs, helpers
    mkdir -p "${PLUGINS_DIR}/polymarket-clob"/{src,tests,fixtures}
    mkdir -p "${SHARED_DIR}"/{calibration,state}
    mkdir -p "${LOGS_DIR}"
    mkdir -p "${HELPERS_DIR}"

    ok "Tree created under ${STATE_DIR} for ${#AGENT_NAMES[@]} agents"
}

##############################################################################
# CONFIG GENERATION
##############################################################################

generate_openclaw_json() {
    step "Generating openclaw.json with ${#AGENT_NAMES[@]} agents"

    local entries=""
    local bindings=""
    local first=true

    IFS=',' read -ra AGENT_NAMES <<< "$AGENT_ROSTER"
    for i in "${!AGENT_NAMES[@]}"; do
        local name="${AGENT_NAMES[$i]}"
        local display="${name^}"  # Capitalize first letter
        local theme
        local role
        local model
        local thinking
        
        theme=$(get_agent_theme "$i" "$name")
        role=$(get_agent_role "$i" "$name")
        model=$(get_agent_model "$name")
        thinking=$(get_agent_thinking "$name")

        local tts_config=""
        if [[ "$USE_ELEVENLABS" == "true" ]]; then
            local voice_var="ELEVENLABS_VOICE_ID_${name^^}"
            local voice_id="${!voice_var:-${ELEVENLABS_VOICE_ID:-default}}"
            tts_config=$(printf ',\n        "tts": { "providers": { "elevenlabs": { "speakerVoiceId": "%s" } } }' "$voice_id")
        fi

        # Determine if this agent can have subagents (first two agents usually can)
        local subagent_list="[]"
        if [[ $i -eq 0 ]]; then
            # First agent is system agent — can spawn others
            local other_agents=""
            for j in "${!AGENT_NAMES[@]}"; do
                [[ $j -ne $i ]] && other_agents="${other_agents:+, }\"${AGENT_NAMES[$j]}\""
            done
            subagent_list="[${other_agents}]"
        fi

        # Build agent entry
        local entry
        entry=$(cat << EOF
      ${name}: {
        name: "${display}",
        workspace: "${WORKSPACE_ROOT}/${name}",
        agentDir: "${AGENTS_ROOT}/${name}/agent",
        model: {
          primary: "${model}",
          fallbacks: ["${UTILITY_MODEL}"]
        },
        utilityModel: "${UTILITY_MODEL}",
        thinkingDefault: "${thinking}",
        reasoningDefault: "on",
        fastModeDefault: false,
        identity: {
          name: "${display}",
          theme: "${theme}"
        },
        tools: {
          allow: ["read", "write", "edit", "exec", "message", "sessions_list", "sessions_history"],
          deny: ["apply_patch", "browser", "gateway", "canvas", "nodes"]
        },
        subagents: { allowAgents: ${subagent_list} },
        sandbox: { mode: "all", scope: "agent", workspaceAccess: "none" }${tts_config}
      }
EOF
)

        # Build binding entry
        local binding
        binding="{ agentId: \"${name}\", match: { channel: \"telegram\", accountId: \"${name}\" } }"

        # Append with commas
        if [[ "$first" == "true" ]]; then
            entries="$entry"
            bindings="$binding"
            first=false
        else
            entries="${entries},
${entry}"
            bindings="${bindings},
    ${binding}"
        fi
    done

    # Set system agent (first in roster) and heartbeat agent (second in roster)
    IFS=',' read -ra AGENT_NAMES <<< "$AGENT_ROSTER"
    local system_agent="${AGENT_NAMES[0]}"
    local heartbeat_agent="${AGENT_NAMES[1]:-${AGENT_NAMES[0]}}"  # Fall back to first if only one

    cat > "${STATE_DIR}/openclaw.json" << EOF
// ${STATE_DIR}/openclaw.json
// Generated by setup-openclaw-triad.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
// Format: JSON5 (comments + trailing commas permitted)
// Agent roster: ${AGENT_ROSTER}

{
  agents: {
    ownership: "explicit",

    defaults: {
      workspace: "${WORKSPACE_ROOT}",
      cwd: "${WORKSPACE_ROOT}",
      systemAgent: { agentId: "${system_agent}" },
      heartbeat: { agentId: "${heartbeat_agent}" },
      authInheritance: { agentId: "${system_agent}" },
      skills: ["market-data", "risk-limits", "trade-log", "docs-search"]
    },

    entries: {
${entries}
    }
  },

  bindings: [
    ${bindings}
  ],

  talk: { agentId: "${system_agent}" },

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
    step "Generating .env template with agent customization section"

    cat > "${STATE_DIR}/.env.example" << 'EOF'
# =============================================================================
# NANOGPT — REQUIRED (single key, all models)
# =============================================================================
NANOGPT_API_KEY=

# =============================================================================
# AGENT CUSTOMIZATION — redefine your triad
# =============================================================================
# AGENT_ROSTER=oracle,risk,arbiter           # Comma-separated agent names
# AGENT_ORACLE_THEME=mystical seer with crystal ball
# AGENT_ORACLE_ROLE=Probability diviner — reads market omens
# AGENT_ORACLE_MODEL=anthropic/claude-sonnet-4-6
# AGENT_ORACLE_THINKING=medium
#
# AGENT_RISK_THEME=navy guardian wolf
# AGENT_RISK_ROLE=Capital warden — enforces loss limits
# AGENT_RISK_MODEL=anthropic/claude-opus-4-6
# AGENT_RISK_THINKING=high
#
# AGENT_ARBITER_THEME=silver owl mediator
# AGENT_ARBITER_ROLE=Final authority — resolves conflicts
# AGENT_ARBITER_MODEL=anthropic/claude-opus-4-6
# AGENT_ARBITER_THINKING=high

# =============================================================================
# OPTIONAL — uncomment and fill to enable the feature
# =============================================================================

# ElevenLabs TTS (per-agent voice overrides supported)
# ELEVENLABS_API_KEY=
# ELEVENLABS_VOICE_ID=default
# ELEVENLABS_VOICE_ID_ORACLE=voice_id_1
# ELEVENLABS_VOICE_ID_RISK=voice_id_2

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
# AGENT WORKSPACE FILES — FULLY DYNAMIC
##############################################################################

generate_agent_files() {
    step "Generating agent workspace files for ${#AGENT_NAMES[@]} agents"

    IFS=',' read -ra AGENT_NAMES <<< "$AGENT_ROSTER"
    for i in "${!AGENT_NAMES[@]}"; do
        local name="${AGENT_NAMES[$i]}"
        local display="${name^}"  # Capitalize first letter
        local theme
        local role
        local model
        local thinking
        
        theme=$(get_agent_theme "$i" "$name")
        role=$(get_agent_role "$i" "$name")
        model=$(get_agent_model "$name")
        thinking=$(get_agent_thinking "$name")

        cat > "${WORKSPACE_ROOT}/${name}/IDENTITY.md" << EOF
# IDENTITY.md — ${display}

**Runtime:** OpenClaw Triad
**Provider:** NanoGPT (\`https://nano-gpt.com/api/v1\`)
**Model:** \`${model}\`
**Thinking:** \`${thinking}\`
**Workspace:** \`${WORKSPACE_ROOT}/${name}\`
**Generated:** $(date -u +"%Y-%m-%d")

---

See \`SOUL.md\` for temperament and \`AGENTS.md\` for role and protocol.
EOF

        cat > "${WORKSPACE_ROOT}/${name}/AGENTS.md" << EOF
# AGENTS.md — ${display}'s Role

| Field | Value |
|---|---|
| Agent id | \`${name}\` |
| Model | \`${model}\` |
| Thinking | \`${thinking}\` |
| Workspace | \`${WORKSPACE_ROOT}/${name}\` |
| State dir | \`${AGENTS_ROOT}/${name}/agent\` |
| Theme | ${theme} |

---

**Role:** ${role}

---

Governance: no single agent executes alone. Alignment between at least two
agents authorizes execution; disagreement escalates to the highest-indexed
agent in the roster, whose ruling is binding.
EOF

        cat > "${WORKSPACE_ROOT}/${name}/SOUL.md" << EOF
# SOUL.md — ${display}

**Theme:** ${theme}

## Temperament Profile

Generated from personality preset: \`${PERSONALITY_PRESET}\`

### Core Traits
- **Primary function:** ${role}
- **Decision style:** Derived from \`${thinking}\` thinking depth
- **Bias profile:** Adjust via AGENT_${name^^}_BIAS env var

### Behavioral Guidelines

Replace this section with your custom archetype definition. Examples:

---
**For a mystical archetype:**
- Trusts pattern recognition over explicit calculation
- Seeks coherence across seemingly unrelated signals
- Operates with higher uncertainty tolerance

**For a conservative archetype:**
- Requires 95%+ confidence before any action
- Prefers small, repeated wins over large bets
- Automatically rejects trades with asymmetric downside

**For a bold archetype:**
- Acts on 60%+ conviction thresholds
- Embraces concentration during clear edges
- Accepts drawdowns as learning investment
---

### Calibration Targets

Track accuracy and alignment here:
- Signal hit rate: TBD
- False positive rate: TBD
- Alignment with consensus: TBD

Current phase: testnet
EOF

        cat > "${WORKSPACE_ROOT}/${name}/DREAMS.md" << EOF
# DREAMS.md — ${display}

**Goal:** Evolve ${theme} into a calibrated trading entity

## Milestones

### Phase 1: Testnet Validation
- [ ] Run 30 consecutive days without manual intervention
- [ ] Achieve >55% signal accuracy on Polymarket
- [ ] Zero policy violations or risk breaches

### Phase 2: Paper Trading
- [ ] Match or exceed benchmark P&L for 90 days
- [ ] Demonstrate consistent risk-adjusted returns
- [ ] Survive 3+ market regime changes

### Phase 3: Live Capital
- [ ] Start with $100 allocation
- [ ] Scale 2x monthly while maintaining Sharpe >1.5
- [ ] Reach $10k without drawdown >20%

## Reflection Prompts

Answer these weekly:
1. What trades did I veto that later proved correct?
2. What signals did I miss that were obvious in hindsight?
3. How has my ${theme} archetype evolved this week?

---

Generated: $(date -u +"%Y-%m-%d")
EOF

        # Create journal file
        touch "${WORKSPACE_ROOT}/${name}/journal/$(date +%Y-%m-%d).md"
        ok "${display} (${model}, thinking: ${thinking})"
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

    step "Generating Telegram bot with dynamic agent routing"

    mkdir -p "${PLUGINS_DIR}/telegram-bot"

    IFS=',' read -ra AGENT_NAMES <<< "$AGENT_ROSTER"
    local agent_commands=""
    for name in "${AGENT_NAMES[@]}"; do
        local display="${name^}"
        agent_commands="${agent_commands}/${name} — ${display}\n"
    done

    cat > "${PLUGINS_DIR}/telegram-bot/bot.py" << EOF
#!/usr/bin/env python3
"""Telegram front-end for the OpenClaw triad.

Agent roster: ${AGENT_ROSTER}
"""

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

# Dynamic agent list from roster
AVAILABLE_AGENTS = [a.strip() for a in "${AGENT_ROSTER}".split(",")]


def authorised(update: Update) -> bool:
    return str(update.effective_user.id) in ALLOWED


async def cmd_start(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not authorised(update):
        return
    
    agent_help = "\n".join([f"/{a} — ${{a.capitalize()}}" for a in AVAILABLE_AGENTS])
    
    await update.message.reply_text(
        f"OpenClaw triad online.\\nAgents: \\${', '.join(AVAILABLE_AGENTS)}\\n\\n"
        f"{agent_help}\\n"
        "/list — List all agents and their roles"
    )


async def list_agents(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """List all agents with their roles."""
    if not authorised(update):
        return
    
    roles = {
        "clawdia": "Opportunity Scout",
        "clawdio": "Risk Guardian", 
        "arbiter": "Mediator",
    }
    
    # Try to fetch from config if available
    role_str = ""
    for name in AVAILABLE_AGENTS:
        role = roles.get(name, "Autonomous Agent")
        role_str += f"• {{name}} ({role})\\n"
    
    await update.message.reply_text(f"Active Agents:\\n{{role_str}}")


async def relay(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Forward an authorised message to the appropriate agent."""
    if not authorised(update):
        log.warning("Rejected message from %s", update.effective_user.id)
        return
    
    # Route based on command prefix: /clawdia, /clawdio, etc.
    msg_text = update.message.text
    if msg_text.startswith("/"):
        command = msg_text.split()[0][1:]  # Strip slash
        if command in AVAILABLE_AGENTS:
            await update.message.reply_text(f"Routing to {{command.capitalize()}}…")
            # TODO: route to the gateway (HTTP or socket) and stream the reply back.
        else:
            await update.message.reply_text(f"Unknown agent. Available: {{', '.join(AVAILABLE_AGENTS)}}")
    else:
        # Broadcast to all agents
        await update.message.reply_text("Received. Broadcasting to all agents…")


def main() -> None:
    if not TOKEN:
        raise SystemExit("TELEGRAM_BOT_TOKEN is not set")
    if not ALLOWED:
        raise SystemExit("TELEGRAM_USER_ID is not set — refusing to run open to everyone")

    app = Application.builder().token(TOKEN).build()
    app.add_handler(CommandHandler("start", cmd_start))
    app.add_handler(CommandHandler("list", list_agents))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, relay))
    app.run_polling()


if __name__ == "__main__":
    main()
EOF

    ok "telegram bot scaffold for ${#AGENT_NAMES[@]} agents"
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
# Change docker.env to relocate the stack without rebuilding anything.
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

    IFS=',' read -ra AGENT_NAMES <<< "$AGENT_ROSTER"
    local calibration_entries=""
    for i in "${!AGENT_NAMES[@]}"; do
        local name="${AGENT_NAMES[$i]}"
        local trait=""
        case $i in
            0) trait="hunches" ;;
            1) trait="vetoes" ;;
            2) trait="rulings" ;;
            *) trait="signals" ;;
        esac
        
        calibration_entries="${calibration_entries}
| \`${name}-${trait}.csv\` | Measure specific to ${name} |"
    done

    cat > "${SHARED_DIR}/calibration/README.md" << EOF
# Calibration Archive

Tracks each agent's accuracy over time.

**Agent Roster:** ${AGENT_ROSTER}

## Metrics${calibration_entries}

Reviewed weekly.

## Agent-Specific Targets

EOF

    for name in "${AGENT_NAMES[@]}"; do
        cat >> "${SHARED_DIR}/calibration/README.md" << EOF

### ${name^}
- **Signal accuracy:** Target >55%
- **False positive rate:** Target <10%
- **Drawdown tolerance:** Per role definition

EOF
    done

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

    IFS=',' read -ra AGENT_NAMES <<< "$AGENT_ROSTER"

    cat << EOF

═══════════════════════════════════════════════════════════
  SETUP COMPLETE
═══════════════════════════════════════════════════════════

  State directory    ${STATE_DIR}
  Workspaces         ${WORKSPACE_ROOT}
  Agent count        ${#AGENT_NAMES[@]}
  Personality preset ${PERSONALITY_PRESET}

  Agents
EOF

    for i in "${!AGENT_NAMES[@]}"; do
        local name="${AGENT_NAMES[$i]}"
        local display="${name^}"
        local theme
        local model
        local thinking
        
        theme=$(get_agent_theme "$i" "$name")
        model=$(get_agent_model "$name")
        thinking=$(get_agent_thinking "$name")
        
        echo "    $(printf '%2d' $((i+1))). ${display}" >> /dev/null
        cat << EOF
    • ${display} — ${theme}
      Model: ${model}
      Thinking: ${thinking}
EOF
    done

    cat << EOF

  Features
    NanoGPT API        ${tick}  (required)
    ElevenLabs TTS     ${f_tts}
    Telegram bot       ${f_tg}
    Polymarket CLOB    ${f_pm}
    Crypto treasury    ${f_wal}$( [[ "$USE_WALLET" == "true" ]] && echo "  (${WALLET_TYPE^^} · ${WALLET_AGENT})" )
    Docker             ${f_doc}

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
    2. Customize agent SOUL.md files for your personas
    3. openclaw config schema
    4. openclaw start

═══════════════════════════════════════════════════════════
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
            --roster)
                [[ -n "${2:-}" ]] || { echo "--roster needs comma-separated names"; exit 1; }
                AGENT_ROSTER="$2"; shift 2
                ;;
            --preset)
                [[ -n "${2:-}" ]] || { echo "--preset needs a pack name"; exit 1; }
                PERSONALITY_PRESET="$2"; shift 2
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
