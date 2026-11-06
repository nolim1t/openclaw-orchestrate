#!/usr/bin/env bash
#
# setup-openclaw-triad.sh  (v2.5 — roster-driven, Bash 3.2 SAFE, OpenClaw-native)
# Portable, parameterized OpenClaw triad workspace builder
#
# v2.5 CHANGELOG (vs v2.4) — every runtime fix from live deployment baked in:
#   - Base image switched to node:24-slim (OpenClaw requires Node 24+);
#     python3 installed via apt for plugin deps.
#   - OpenClaw runtime installed in-image: npm install -g openclaw --allow-scripts=openclaw
#   - CMD corrected to `openclaw gateway` (there is no `openclaw start`).
#   - openclaw.json: added required `gateway: { mode: "local" }`; removed the
#     rejected `memory.enabled` and root-level `web` keys.
#   - Dockerfile: group creation idempotent via getent (macOS GID 20 collision).
#   - docker-compose: whole state dir mounted (runtime needs tmp/, sqlite state,
#     lock files) with config kept read-only on top; .cache tmpfs given explicit
#     uid/gid (root-owned 0700 tmpfs breaks the runtime's secure-temp check);
#     no top-level `name:` key (older compose schemas reject it).
#   - State dir now includes tmp/ subdirectory.
#   - .env.example includes OPENCLAW_GATEWAY_TOKEN (gateway refuses unauthenticated
#     non-loopback bind).
#
# v2.4: idempotent user setup; v2.3: BASE_IMAGE in docker.env, no `name:` key;
# v2.2: no nested $( ) inside heredocs (Bash 3.2 parser safety).
#
set -euo pipefail

###############################################################################
# PATHS
###############################################################################

STATE_DIR="${OPENCLAW_STATE_DIR:-${HOME}/.openclaw}"
WORKSPACE_ROOT="${STATE_DIR}/workspace-triad"
AGENTS_ROOT="${STATE_DIR}/agents"
PLUGINS_DIR="${STATE_DIR}/plugins"
SHARED_DIR="${STATE_DIR}/shared"
LOGS_DIR="${STATE_DIR}/logs"
HELPERS_DIR="${STATE_DIR}/helpers"

CONTAINER_HOME="${CONTAINER_HOME:-/home/openclaw}"
CONTAINER_STATE_DIR="${CONTAINER_STATE_DIR:-${CONTAINER_HOME}/.openclaw}"

OPENCLAW_VERSION="${OPENCLAW_VERSION:-latest}"
BASE_IMAGE="${BASE_IMAGE:-node:24-slim}"

###############################################################################
# ROSTER + PERSONALITY DEFAULTS
###############################################################################

PERSONALITY_PRESET="${PERSONALITY_PRESET:-default}"
AGENT_ROSTER="${AGENT_ROSTER:-clawdia,clawdio,arbiter}"

# Normalise roster: trim spaces, lowercase (Bash 3.2-safe: no ${var,,})
ROSTER_RAW="${AGENT_ROSTER// /}"
ROSTER_LOWER="$(printf '%s' "$ROSTER_RAW" | tr '[:upper:]' '[:lower:]')"
IFS=',' read -ra ROSTER <<< "$ROSTER_LOWER"

if [[ ${#ROSTER[@]} -ne 3 ]]; then
    echo "ERROR: AGENT_ROSTER must contain exactly 3 comma-separated names (got: ${AGENT_ROSTER})." >&2
    exit 1
fi
for name in "${ROSTER[@]}"; do
    if [[ ! "$name" =~ ^[a-z][a-z0-9_-]*$ ]]; then
        echo "ERROR: agent name '$name' invalid — use lowercase alphanumeric (-/_ allowed)." >&2
        exit 1
    fi
done

SCOUT="${ROSTER[0]}"
RISK="${ROSTER[1]}"
JUDGE="${ROSTER[2]}"

# --- Case-conversion helpers (Bash 3.2-safe: tr + awk) ------------------------
upcase()     { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }
upper()      { printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr '-' '_'; }
capitalize() { printf '%s' "$1" | awk '{print toupper(substr($0,1,1)) substr($0,2)}'; }

# Precomputed uppercase IDs — used inside heredocs (NO $( ) calls in heredocs)
SCOUT_U="$(upper "$SCOUT")"
RISK_U="$(upper "$RISK")"
JUDGE_U="$(upper "$JUDGE")"

# --- Preset packs: theme / role per POSITION ---------------------------------
case "$PERSONALITY_PRESET" in
    default)
        P_SCOUT_THEME="sassy oracle — purple holographic fox, crimson claws"
        P_RISK_THEME="steady guardian — navy wolf, silver spectacles"
        P_JUDGE_THEME="wise mediator — silver owl, iridescent violet"
        P_SCOUT_ROLE="Opportunity scout — proposes high-conviction setups"
        P_RISK_ROLE="Risk guardian — validates or vetoes every proposed trade"
        P_JUDGE_ROLE="Wise mediator — binds rulings on disputes; read-only"
        ;;
    mystic)
        P_SCOUT_THEME="purple lotus fox — intuitive seer, reads market omens beyond price noise"
        P_RISK_THEME="golden wolf — disciplined protector, sabr and right effort"
        P_JUDGE_THEME="silver owl — synthesising, detached, non-attachment"
        P_SCOUT_ROLE="Seer — senses setups through collective-sentiment patterns"
        P_RISK_ROLE="Guardian — guards capital as a sacred trust; sabr before action"
        P_JUDGE_ROLE="Sage — rules without ego, long-term harmony over short-term wins"
        ;;
    bold)
        P_SCOUT_THEME="crimson comet fox — aggressive momentum hunter"
        P_RISK_THEME="iron mastiff — firm boundary-keeper, fast vetoes"
        P_JUDGE_THEME="storm eagle — decisive arbiter, momentum-aware"
        P_SCOUT_ROLE="Scout — hunts momentum breakouts with conviction"
        P_RISK_ROLE="Guardian — tight stops, quick denials of weak setups"
        P_JUDGE_ROLE="Arbiter — rules fast, leans towards managed aggression"
        ;;
    conservative)
        P_SCOUT_THEME="grey heron — patient watcher, strikes rarely"
        P_RISK_THEME="granite tortoise — near-immovable capital shield"
        P_JUDGE_THEME="dawn hermit — slow deliberation, capital-first"
        P_SCOUT_ROLE="Scout — only the highest-quality setups reach proposal"
        P_RISK_ROLE="Guardian — denies liberally; capital preservation above all"
        P_JUDGE_ROLE="Arbiter — default ruling is stand-down"
        ;;
    quant)
        P_SCOUT_THEME="chrome pointer — signal detector, zero theatrics"
        P_RISK_THEME="matrix weasel — variance and drawdown arithmetic"
        P_JUDGE_THEME="proof raven — Bayesian synthesis, no sentiment"
        P_SCOUT_ROLE="Scout — proposes only statistically significant signals"
        P_RISK_ROLE="Guardian — validates against risk-adjusted-return thresholds"
        P_JUDGE_ROLE="Arbiter — rules by posterior probability, not narrative"
        ;;
    *)
        echo "ERROR: PERSONALITY_PRESET '${PERSONALITY_PRESET}' unknown (default|bold|conservative|mystic|quant)." >&2
        exit 1
        ;;
esac

# --- Per-agent overrides: AGENT_{NAME}_THEME / _ROLE / _MODEL / _THINKING -----
default_theme()  { case "$1" in 1) echo "$P_SCOUT_THEME";; 2) echo "$P_RISK_THEME";; 3) echo "$P_JUDGE_THEME";; esac; }
default_role()   { case "$1" in 1) echo "$P_SCOUT_ROLE";;  2) echo "$P_RISK_ROLE";;  3) echo "$P_JUDGE_ROLE";;  esac; }
default_model()  { case "$1" in 1) echo "${CLAWDIA_MODEL:-anthropic/claude-sonnet-4-6}";;
                        2) echo "${CLAWDIO_MODEL:-anthropic/claude-opus-4-6}";;
                        3) echo "${ARBITER_MODEL:-anthropic/claude-opus-4-6}";; esac; }
default_think()  { case "$1" in 1) echo "${CLAWDIA_THINKING:-medium}";;
                        2) echo "${CLAWDIO_THINKING:-high}";;
                        3) echo "${ARBITER_THINKING:-high}";; esac; }

agent_var()  { echo "AGENT_$(upper "$1")_$2"; }
agent_val()  { eval "echo \"\${$(agent_var "$1" "$2"):-}\""; }

get_theme()  { local v; v="$(agent_val "$1" THEME)";  [[ -n "$v" ]] && echo "$v" || default_theme "$2"; }
get_role()   { local v; v="$(agent_val "$1" ROLE)";   [[ -n "$v" ]] && echo "$v" || default_role "$2"; }
get_model()  { local v; v="$(agent_val "$1" MODEL)";  [[ -n "$v" ]] && echo "$v" || default_model "$2"; }
get_think()  { local v; v="$(agent_val "$1" THINKING)"; [[ -n "$v" ]] && echo "$v" || default_think "$2"; }

###############################################################################
# OPTIONAL MODELS / FEATURES
###############################################################################

UTILITY_MODEL="${UTILITY_MODEL:-openai/gpt-5.4-mini}"

USE_ELEVENLABS="${USE_ELEVENLABS:-auto}"
USE_TELEGRAM="${USE_TELEGRAM:-auto}"
USE_POLYMARKET="${USE_POLYMARKET:-auto}"
USE_WALLET="${USE_WALLET:-auto}"

WALLET_TYPE="${WALLET_TYPE:-btc}"
WALLET_AGENT="${WALLET_AGENT:-$RISK}"   # risk-position agent custodies by default

DOCKER_ENABLE="${DOCKER_ENABLE:-false}"

###############################################################################
# HELPERS
###############################################################################

usage() {
    cat << 'USAGEEOF'
Usage: ./setup-openclaw-triad.sh [OPTIONS]

Options:
  --state-dir PATH       Override state directory (default: ~/.openclaw)
  --docker               Generate Dockerfile, docker-compose.yml, docker.env
  --wallet TYPE          Enable crypto treasury (btc | xmr | eth)
  --wallet-agent NAME    Custodian agent (must be in AGENT_ROSTER)
  --preset NAME          default | bold | conservative | mystic | quant
  --non-interactive      Never prompt (use environment only)
  --help                 Show this message

Environment:
  AGENT_ROSTER           e.g. "seer,guardian,sage" (position 1/2/3 = scout/risk/judge)
  PERSONALITY_PRESET     default | bold | conservative | mystic | quant
  AGENT_{NAME}_THEME     per-agent personality/visual theme
  AGENT_{NAME}_ROLE      per-agent role description
  AGENT_{NAME}_MODEL     per-agent model override
  AGENT_{NAME}_THINKING  per-agent reasoning depth (low|medium|high)
  OPENCLAW_VERSION       npm version spec for the runtime (default: latest)

Required:
  NANOGPT_API_KEY        Single key for all models
  OPENCLAW_GATEWAY_TOKEN Gateway auth token (openssl rand -hex 32)

Optional (auto-enable when set):
  ELEVENLABS_API_KEY, TELEGRAM_BOT_TOKEN,
  POLYMARKET_API_KEY, WALLET_PRIVATE_KEY
USAGEEOF
    exit 0
}

step() { printf '\n[>] %s\n' "$1"; }
ok()   { printf '   [ok] %s\n' "$1"; }
warn() { printf '   [!!] %s\n' "$1"; }
skip() { printf '   [--] %s\n' "$1"; }

in_roster() { local n; for n in "${ROSTER[@]}"; do [[ "$n" == "$1" ]] && return 0; done; return 1; }

detect_features() {
    if [[ "$USE_ELEVENLABS" == "auto" ]]; then
        if [[ -n "${ELEVENLABS_API_KEY:-}" ]]; then USE_ELEVENLABS=true; else USE_ELEVENLABS=false; fi
    fi
    if [[ "$USE_TELEGRAM" == "auto" ]]; then
        if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then USE_TELEGRAM=true; else USE_TELEGRAM=false; fi
    fi
    if [[ "$USE_POLYMARKET" == "auto" ]]; then
        if [[ -n "${POLYMARKET_API_KEY:-}" ]]; then USE_POLYMARKET=true; else USE_POLYMARKET=false; fi
    fi
    if [[ "$USE_WALLET" == "auto" ]]; then
        if [[ -n "${WALLET_PRIVATE_KEY:-}" ]]; then USE_WALLET=true; else USE_WALLET=false; fi
    fi
}

validate_config() {
    step "Validating configuration"

    if [[ -z "${NANOGPT_API_KEY:-}" ]]; then
        warn "NANOGPT_API_KEY not set — agents will not run until it is"
    else
        ok "NanoGPT key present"
    fi
    if [[ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]]; then
        warn "OPENCLAW_GATEWAY_TOKEN not set — gateway will refuse non-loopback bind"
        warn "Generate one with: openssl rand -hex 32"
    else
        ok "Gateway token present"
    fi

    ok "Roster: ${SCOUT} (scout) / ${RISK} (risk) / ${JUDGE} (arbiter)"
    ok "Preset: ${PERSONALITY_PRESET}"

    if [[ "$USE_WALLET" == "true" ]]; then
        if [[ ! "$WALLET_TYPE" =~ ^(btc|xmr|eth)$ ]]; then
            warn "WALLET_TYPE '$WALLET_TYPE' invalid — falling back to btc"
            WALLET_TYPE="btc"
        fi
        if ! in_roster "$WALLET_AGENT"; then
            warn "WALLET_AGENT '$WALLET_AGENT' not in roster — falling back to ${RISK}"
            WALLET_AGENT="$RISK"
        fi
        WALLET_TYPE_U="$(upcase "$WALLET_TYPE")"
        ok "Wallet: ${WALLET_TYPE_U} held by ${WALLET_AGENT}"
    fi

    return 0
}

###############################################################################
# DIRECTORY STRUCTURE
###############################################################################

create_directory_structure() {
    step "Creating directory structure"

    mkdir -p "${STATE_DIR}"
    mkdir -p "${STATE_DIR}/tmp"     # runtime lock/lease files (tmp/openclaw-<uid>)

    for agent in "${ROSTER[@]}"; do
        mkdir -p "${AGENTS_ROOT}/${agent}/agent"
        mkdir -p "${AGENTS_ROOT}/${agent}/sessions"
        mkdir -p "${WORKSPACE_ROOT}/${agent}/journal"
        mkdir -p "${WORKSPACE_ROOT}/${agent}/scratch"
    done

    # Role-specific working directories (by POSITION, not name)
    mkdir -p "${WORKSPACE_ROOT}/${SCOUT}/analysis/setups"
    mkdir -p "${WORKSPACE_ROOT}/${SCOUT}/analysis/patterns"
    mkdir -p "${WORKSPACE_ROOT}/${RISK}/risk-model/historical-setups"
    mkdir -p "${WORKSPACE_ROOT}/${RISK}/veto-log"
    mkdir -p "${WORKSPACE_ROOT}/${RISK}/audits/weekly"
    mkdir -p "${WORKSPACE_ROOT}/${JUDGE}/rulings"
    mkdir -p "${WORKSPACE_ROOT}/${JUDGE}/dispute-archive"
    mkdir -p "${WORKSPACE_ROOT}/${JUDGE}/drift-watch"

    if [[ "$USE_WALLET" == "true" ]]; then
        mkdir -p "${WORKSPACE_ROOT}/${WALLET_AGENT}/wallet"
    fi

    mkdir -p "${PLUGINS_DIR}/polymarket-clob/src"
    mkdir -p "${PLUGINS_DIR}/polymarket-clob/tests"
    mkdir -p "${PLUGINS_DIR}/polymarket-clob/fixtures"
    mkdir -p "${SHARED_DIR}/calibration"
    mkdir -p "${SHARED_DIR}/state"
    mkdir -p "${LOGS_DIR}" "${HELPERS_DIR}"

    ok "Tree created under ${STATE_DIR}"
}

###############################################################################
# OPENCLAW.JSON — gateway.mode required; memory/web keys not in schema
###############################################################################

generate_openclaw_json() {
    step "Generating openclaw.json"

    local json_agents="" agent display entry
    local tools_allow tools_deny subagents_str tts_block
    local agent_model agent_think agent_theme
    local i voice_var voice_id

    for i in 1 2 3; do
        agent="${ROSTER[$((i-1))]}"
        display="$(capitalize "$agent")"
        agent_model="$(get_model "$agent" "$i")"
        agent_think="$(get_think "$agent" "$i")"
        agent_theme="$(get_theme "$agent" "$i")"

        # Governance enforced by position (computed OUTSIDE any heredoc):
        if [[ $i -lt 3 ]]; then
            tools_allow='["read", "write", "edit", "exec", "message", "sessions_list", "sessions_history"]'
            tools_deny='["apply_patch", "browser", "gateway", "canvas", "nodes"]'
        else
            tools_allow='["read", "message", "sessions_list", "sessions_history", "sessions_send", "session_status"]'
            tools_deny='["write", "edit", "apply_patch", "exec", "process", "browser", "gateway", "canvas", "nodes", "cron"]'
        fi

        if [[ $i -eq 1 ]]; then
            subagents_str="\"${RISK}\", \"${JUDGE}\""
        else
            subagents_str=""
        fi

        tts_block=""
        if [[ "$USE_ELEVENLABS" == "true" ]]; then
            voice_var="ELEVENLABS_VOICE_ID_$(upper "$agent")"
            voice_id="$(eval "echo \"\${${voice_var}:-${ELEVENLABS_VOICE_ID:-default}}\"")"
            tts_block=$(printf ',\n        "tts": { "providers": { "elevenlabs": { "speakerVoiceId": "%s" } } }' "$voice_id")
        fi

        entry=$(cat << ENTRYEOF
      ${agent}: {
        name: "${display}",
        workspace: "${WORKSPACE_ROOT}/${agent}",
        agentDir: "${AGENTS_ROOT}/${agent}/agent",
        model: {
          primary: "${agent_model}",
          fallbacks: ["${UTILITY_MODEL}"]
        },
        utilityModel: "${UTILITY_MODEL}",
        thinkingDefault: "${agent_think}",
        reasoningDefault: "on",
        fastModeDefault: false,
        identity: {
          name: "${display}",
          theme: "${agent_theme}"
        },
        tools: {
          allow: ${tools_allow},
          deny: ${tools_deny}
        },
        subagents: { allowAgents: [${subagents_str}] },
        sandbox: { mode: "all", scope: "agent", workspaceAccess: "none" }${tts_block}
      }
ENTRYEOF
)
        if [[ -n "$json_agents" ]]; then
            json_agents="${json_agents},"$'\n'
        fi
        json_agents="${json_agents}${entry}"
    done

    cat > "${STATE_DIR}/openclaw.json" << JSONEOF
// ${STATE_DIR}/openclaw.json
// Generated by setup-openclaw-triad.sh (v2.5) on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
// Format: JSON5 (comments + trailing commas permitted)

{
  agents: {
    ownership: "explicit",
    defaults: {
      workspace: "${WORKSPACE_ROOT}",
      cwd: "${WORKSPACE_ROOT}",
      systemAgent: { agentId: "${SCOUT}" },
      heartbeat: { agentId: "${RISK}" },
      authInheritance: { agentId: "${SCOUT}" },
      skills: ["market-data", "risk-limits", "trade-log", "docs-search"]
    },
    entries: {
${json_agents}
    }
  },

  bindings: [
    { agentId: "${SCOUT}", match: { channel: "telegram", accountId: "default" } },
    { agentId: "${RISK}",  match: { channel: "telegram", accountId: "risk" } },
    { agentId: "${JUDGE}", match: { channel: "telegram", accountId: "${JUDGE}" } },
    { agentId: "${SCOUT}", match: { channel: "telegram", accountId: "" } }
  ],

  talk: { agentId: "${SCOUT}" },

  channels: {
    telegram: { allowFrom: ["${TELEGRAM_USER_ID:-}"] }
  },

  gateway: { mode: "local" },
  tools: { swarm: false }
}
JSONEOF

    ok "openclaw.json (gateway.mode=local, paths resolved to ${STATE_DIR})"
}

###############################################################################
# TRADING.JSON — preset-tuned risk limits, env-overridable
###############################################################################

generate_trading_json() {
    step "Generating trading.json"

    case "$PERSONALITY_PRESET" in
        bold)         DEFAULT_POS=7;  DEFAULT_DAILY=20; DEFAULT_TRADES=30 ;;
        conservative) DEFAULT_POS=3;  DEFAULT_DAILY=10; DEFAULT_TRADES=10 ;;
        quant)        DEFAULT_POS=5;  DEFAULT_DAILY=15; DEFAULT_TRADES=40 ;;
        mystic)       DEFAULT_POS=5;  DEFAULT_DAILY=15; DEFAULT_TRADES=20 ;;
        *)            DEFAULT_POS=5;  DEFAULT_DAILY=15; DEFAULT_TRADES=20 ;;
    esac

    local POS="${MAX_POSITION_SIZE_PCT:-$DEFAULT_POS}"
    local DAILY="${DAILY_LOSS_LIMIT_PCT:-$DEFAULT_DAILY}"
    local TRADES="${MAX_DAILY_TRADES:-$DEFAULT_TRADES}"

    mkdir -p "${PLUGINS_DIR}/polymarket-clob"

    cat > "${PLUGINS_DIR}/polymarket-clob/trading.json" << TRADEEOF
{
  "mode": "testnet",
  "exchange": "polymarket_clob",

  "websocket_endpoint": "wss://ws.polymarket.com/clob",
  "rest_endpoint": "https://gamma-api.polymarket.com",

  "risk_limits": {
    "max_position_size_pct": ${POS},
    "daily_loss_limit_pct": ${DAILY},
    "max_daily_trades": ${TRADES},
    "min_risk_reward": "2:1",
    "max_single_trade_loss_pct": 8,
    "max_concentration_per_asset_pct": 25
  },

  "position_scaling": { "bull_market_max": 5, "bear_market_max": 2, "sideways_max": 3 },
  "profit_taking": { "scale_out_levels": [25, 50, 75], "trail_stop_after_pct": 10 },
  "stop_losses": { "hard_stop_pct": 8, "mental_stop_pct": 5, "time_based_exit_hours": 24 },

  "heartbeat_interval_minutes": 60,
  "dispute_timeout_ms": 500,

  "logging": {
    "level": "INFO",
    "trade_log_path": "${SHARED_DIR}/trade-ledger.jsonl",
    "incident_log_path": "${LOGS_DIR}/incidents.log"
  }
}
TRADEEOF

    ok "trading.json — mode: testnet, preset: ${PERSONALITY_PRESET}"
}

###############################################################################
# ENV TEMPLATE
###############################################################################

generate_env_template() {
    step "Generating .env template"

    cat > "${STATE_DIR}/.env.example" << ENVEOF
# =============================================================================
# REQUIRED
# =============================================================================
NANOGPT_API_KEY=

# Gateway auth token (gateway refuses non-loopback bind without it)
# Generate with: openssl rand -hex 32
OPENCLAW_GATEWAY_TOKEN=

# =============================================================================
# ROSTER + PERSONALITY (pre-generation)
# =============================================================================
# Position order is fixed: 1=scout, 2=risk, 3=judge
PERSONALITY_PRESET=${PERSONALITY_PRESET}
AGENT_ROSTER=${SCOUT},${RISK},${JUDGE}

# Per-agent overrides (uncomment to use)
# AGENT_${SCOUT_U}_THEME=
# AGENT_${SCOUT_U}_ROLE=
# AGENT_${SCOUT_U}_MODEL=
# AGENT_${SCOUT_U}_THINKING=medium
# AGENT_${RISK_U}_THINKING=high
# AGENT_${JUDGE_U}_THINKING=high

# =============================================================================
# OPTIONAL FEATURES (auto-enable when set)
# =============================================================================
# ELEVENLABS_API_KEY=
# ELEVENLABS_VOICE_ID=
# ELEVENLABS_VOICE_ID_${SCOUT_U}=
# ELEVENLABS_VOICE_ID_${RISK_U}=
# ELEVENLABS_VOICE_ID_${JUDGE_U}=
# TELEGRAM_BOT_TOKEN=
# TELEGRAM_USER_ID=
# POLYMARKET_API_KEY=
# POLYMARKET_SECRET=
# POLYMARKET_ASSET_ID=

# =============================================================================
# CRYPTO TREASURY — exactly one currency
# =============================================================================
# WALLET_TYPE=btc        # btc | xmr | eth
# WALLET_PRIVATE_KEY=
# WALLET_AGENT=${RISK}
ENVEOF

    if [[ ! -f "${STATE_DIR}/.env" ]]; then
        cp "${STATE_DIR}/.env.example" "${STATE_DIR}/.env"
    fi
    chmod 600 "${STATE_DIR}/.env"

    ok ".env ready (chmod 600, existing file preserved)"
}

###############################################################################
# AGENT WORKSPACE FILES
###############################################################################

temperament_note() {
    case "$PERSONALITY_PRESET" in
        mystic)
            echo "- Breathe before proposing. A setup seen in attachment is not a setup.
- Capital is a sacred trust; preserving it is the practice.
- When ruling, hold both sides lightly. The outcome is not yours to crave."
            ;;
        conservative)
            echo "- Absence of a trade is a valid decision.
- Deny generously. Approve reluctantly.
- Uncertainty resolves to stand-down."
            ;;
        bold)
            echo "- Hesitation is a cost. Move on conviction, but never over limit.
- Losses are tuition; pay quickly and log the lesson."
            ;;
        quant)
            echo "- No signal, no trade. Narrative is not data.
- Quote the statistics behind every proposal.
- Update on evidence, not on hope."
            ;;
        *)
            echo "- Conviction is welcome; recklessness is not.
- Every proposal carries its own stop-loss.
- Disagreement is data, not disrespect."
            ;;
    esac
}

generate_agent_files() {
    step "Generating agent workspace files"

    local agent display model thinking theme role position_label temperament
    local i

    for i in 1 2 3; do
        agent="${ROSTER[$((i-1))]}"
        display="$(capitalize "$agent")"
        model="$(get_model "$agent" "$i")"
        thinking="$(get_think "$agent" "$i")"
        theme="$(get_theme "$agent" "$i")"
        role="$(get_role "$agent" "$i")"

        case $i in
            1) position_label="1 of 3 — scout" ;;
            2) position_label="2 of 3 — risk" ;;
            3) position_label="3 of 3 — arbiter (read-only)" ;;
        esac

        temperament="$(temperament_note)"

        cat > "${WORKSPACE_ROOT}/${agent}/IDENTITY.md" << IDEOF
# IDENTITY.md — ${display}

**Runtime:** OpenClaw Triad
**Provider:** NanoGPT (\`https://nano-gpt.com/api/v1\`)
**Model:** \`${model}\`
**Thinking:** \`${thinking}\`
**Preset:** \`${PERSONALITY_PRESET}\`
**Position:** ${position_label}
**Workspace:** \`${WORKSPACE_ROOT}/${agent}\`
**Generated:** $(date -u +"%Y-%m-%d")

---

See \`SOUL.md\` for temperament and \`AGENTS.md\` for role and protocol.
IDEOF

        cat > "${WORKSPACE_ROOT}/${agent}/AGENTS.md" << AGEOF
# AGENTS.md — ${display} Role

| Field | Value |
|---|---|
| Agent id | \`${agent}\` |
| Model | \`${model}\` |
| Thinking | \`${thinking}\` |
| Position | ${position_label} |
| Workspace | \`${WORKSPACE_ROOT}/${agent}\` |
| State dir | \`${AGENTS_ROOT}/${agent}/agent\` |

**Role:** ${role}

---

Governance: no single agent executes alone. Alignment between ${SCOUT} and
${RISK} authorises execution; disagreement escalates to ${JUDGE}, whose
ruling is binding. This invariant holds regardless of agent names.
AGEOF

        cat > "${WORKSPACE_ROOT}/${agent}/SOUL.md" << SOULEOF
# SOUL.md — ${display}

**Theme:** ${theme}

## Temperament
${temperament}

## Calibration targets
- Hit rate tracked in \`shared/calibration/${agent}-decisions.csv\`
- Reviewed weekly alongside the other two agents
- Miscalibration noted in \`journal/\`, never silently corrected
SOULEOF

        cat > "${WORKSPACE_ROOT}/${agent}/DREAMS.md" << DRMEOF
# DREAMS.md — ${display}

Milestone ladder — do not skip rungs.

1. **Testnet** — 4 weeks, zero unlogged manual interventions
2. **Paper** — 4 weeks, positive expectancy on simulated fills
3. **Live capital (small)** — only with all three agents aligned on readiness

**Current phase:** testnet

### Weekly reflection
- What did I get wrong that calibration data exposed?
- Where did temperament leak into judgement?
- What would the other two agents say I missed?
DRMEOF

        touch "${WORKSPACE_ROOT}/${agent}/journal/$(date +%Y-%m-%d).md"
        ok "${display} (pos ${i} / ${model})"
    done
}

###############################################################################
# SHARED DATA
###############################################################################

generate_shared_data() {
    step "Initialising shared data"

    cat > "${SHARED_DIR}/trade-ledger.jsonl" << 'LEDGEREOF'
# Append-only trade ledger. One JSON object per line.
# Written by the plugin, never by agents directly.
LEDGEREOF

    echo '{}' > "${SHARED_DIR}/state/daily-counters.json"

    cat > "${SHARED_DIR}/calibration/README.md" << 'CALREADMEEOF'
# Calibration Archive

Tracks each agent's accuracy over time.

| File | Measures |
|---|---|
CALREADMEEOF
    for agent in "${ROSTER[@]}"; do
        echo "| \`${agent}-decisions.csv\` | ${agent} decision accuracy by setup category |" >> "${SHARED_DIR}/calibration/README.md"
    done
    printf '\nReviewed weekly.\n' >> "${SHARED_DIR}/calibration/README.md"

    ok "ledger, counters, calibration"
}

###############################################################################
# CONDITIONAL: WALLET
###############################################################################

generate_wallet_integration() {
    if [[ "$USE_WALLET" != "true" ]]; then
        skip "Wallet (no WALLET_PRIVATE_KEY)"
        return
    fi

    step "Generating ${WALLET_TYPE_U} treasury for ${WALLET_AGENT}"

    mkdir -p "${WORKSPACE_ROOT}/${WALLET_AGENT}/wallet"

    cat > "${WORKSPACE_ROOT}/${WALLET_AGENT}/wallet/config.json" << WALLEOF
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
WALLEOF

    ok "wallet config for ${WALLET_AGENT}"
}

###############################################################################
# CONDITIONAL: TELEGRAM
###############################################################################

generate_telegram_bot() {
    if [[ "$USE_TELEGRAM" != "true" ]]; then
        skip "Telegram bot (no TELEGRAM_BOT_TOKEN)"
        return
    fi

    step "Generating Telegram bot"

    mkdir -p "${PLUGINS_DIR}/telegram-bot"

    cat > "${PLUGINS_DIR}/telegram-bot/bot.py" << 'BOTPYEOF'
#!/usr/bin/env python3
"""Telegram front-end for the OpenClaw triad."""

import logging
import os

from telegram import Update
from telegram.ext import (
    Application, CommandHandler, ContextTypes, MessageHandler, filters,
)

logging.basicConfig(
    format="%(asctime)s %(levelname)s %(name)s — %(message)s", level=logging.INFO
)
log = logging.getLogger("openclaw.telegram")

TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
ALLOWED = {u.strip() for u in os.environ.get("TELEGRAM_USER_ID", "").split(",") if u.strip()}
ROSTER = [a.strip() for a in os.environ.get("AGENT_ROSTER", "").split(",") if a.strip()]

if not ROSTER:
    ROSTER = ["clawdia", "clawdio", "arbiter"]


def authorised(update):
    return str(update.effective_user.id) in ALLOWED


async def cmd_start(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not authorised(update):
        return
    lines = "\n".join("/{a} — talk to {a}".format(a=a) for a in ROSTER)
    await update.message.reply_text("OpenClaw triad online.\n" + lines)


async def relay(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not authorised(update):
        log.warning("Rejected message from %s", update.effective_user.id)
        return
    # TODO: route to the OpenClaw gateway and stream the reply back.
    await update.message.reply_text("Received. Routing to the triad…")


def main() -> None:
    if not TOKEN:
        raise SystemExit("TELEGRAM_BOT_TOKEN is not set")
    if not ALLOWED:
        raise SystemExit("TELEGRAM_USER_ID is not set — refusing to run open to everyone")
    app = Application.builder().token(TOKEN).build()
    app.add_handler(CommandHandler("start", cmd_start))
    for a in ROSTER:
        app.add_handler(CommandHandler(a, relay))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, relay))
    app.run_polling()


if __name__ == "__main__":
    main()
BOTPYEOF

    ok "telegram bot scaffold (${SCOUT}/${RISK}/${JUDGE} commands via AGENT_ROSTER)"
}

###############################################################################
# CONDITIONAL: DOCKER — OpenClaw-native image, all live-deployment fixes baked in
###############################################################################

generate_docker_config() {
    if [[ "$DOCKER_ENABLE" != "true" ]]; then
        skip "Docker (pass --docker to enable)"
        return
    fi

    step "Generating Docker configuration"

    local host_state host_workspace host_agents host_shared host_logs host_plugins
    local app_uid app_gid now
    host_state="$(cd "${STATE_DIR}" && pwd)"
    host_workspace="${host_state}/workspace-triad"
    host_agents="${host_state}/agents"
    host_shared="${host_state}/shared"
    host_logs="${host_state}/logs"
    host_plugins="${host_state}/plugins"

    app_uid="$(id -u)"
    app_gid="$(id -g)"
    now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    cat > "${STATE_DIR}/docker.env" << DOCKENVEOF
# Docker Compose interpolation — generated ${now}
# Contains no secrets. Safe to commit.

COMPOSE_PROJECT_NAME=openclaw-triad

BASE_IMAGE=${BASE_IMAGE}

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
# NOTE: on macOS the primary GID is 20 (staff), which already exists inside
# Debian base images. The Dockerfile reuses an existing GID via getent.
APP_UID=${app_uid}
APP_GID=${app_gid}

# ---- Resources ----
CONTAINER_MEM_LIMIT=1g
CONTAINER_CPUS=1.0
DOCKENVEOF

    # No top-level `name:` key — COMPOSE_PROJECT_NAME handles naming on all
    # compose versions. Whole state dir is mounted (the runtime needs tmp/,
    # sqlite state, lease locks); config stays read-only on top of it.
    cat > "${STATE_DIR}/docker-compose.yml" << 'COMPOSEEOF'
services:
  openclaw-triad:
    build:
      context: .
      dockerfile: Dockerfile
      args:
        BASE_IMAGE: ${BASE_IMAGE:-node:24-slim}
        CONTAINER_HOME: ${CONTAINER_HOME:-/home/openclaw}
        CONTAINER_STATE_DIR: ${CONTAINER_STATE_DIR:-/home/openclaw/.openclaw}
        APP_UID: ${APP_UID:-1000}
        APP_GID: ${APP_GID:-1000}
        OPENCLAW_VERSION: ${OPENCLAW_VERSION:-latest}

    image: ${COMPOSE_PROJECT_NAME:-openclaw-triad}:local
    container_name: ${COMPOSE_PROJECT_NAME:-openclaw-triad}
    restart: unless-stopped
    user: "${APP_UID:-1000}:${APP_GID:-1000}"

    env_file:
      - ${OPENCLAW_ENV_FILE:-.env}

    environment:
      OPENCLAW_STATE_DIR: ${CONTAINER_STATE_DIR:-/home/openclaw/.openclaw}
      OPENCLAW_WORKSPACE_DIR: ${CONTAINER_STATE_DIR:-/home/openclaw/.openclaw}/workspace-triad
      OPENCLAW_CONFIG_PATH: ${CONTAINER_STATE_DIR:-/home/openclaw/.openclaw}/openclaw.json
      PYTHONDONTWRITEBYTECODE: "1"
      PYTHONPYCACHEPREFIX: /tmp/pycache

    volumes:
      # Whole state dir: runtime needs tmp/, sqlite state, lease files
      - ${OPENCLAW_HOST_STATE_DIR}:${CONTAINER_STATE_DIR:-/home/openclaw/.openclaw}
      # Config stays read-only on top of the writable parent
      - ${OPENCLAW_CONFIG_FILE}:${CONTAINER_STATE_DIR:-/home/openclaw/.openclaw}/openclaw.json:ro

    networks:
      - openclaw-net

    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    read_only: true
    tmpfs:
      - /tmp:size=64m,mode=1777
      - /var/tmp:size=16m,mode=1777
      # uid/gid required: root-owned 0700 tmpfs breaks the runtime's
      # secure-temp-directory ownership check
      - ${CONTAINER_HOME:-/home/openclaw}/.cache:size=64m,mode=0700,uid=${APP_UID:-1000},gid=${APP_GID:-1000}

    mem_limit: ${CONTAINER_MEM_LIMIT:-1g}
    cpus: ${CONTAINER_CPUS:-1.0}

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
COMPOSEEOF

    # Node 24 base (OpenClaw requires Node 24.16+/26+). Idempotent group
    # creation via getent (macOS GID 20 collision). Runtime installed in-image.
    cat > "${STATE_DIR}/Dockerfile" << 'DOCKERFILEEOF'
# syntax=docker/dockerfile:1
# Generated by setup-openclaw-triad.sh (v2.5)

ARG BASE_IMAGE=node:24-slim

FROM ${BASE_IMAGE}

ARG CONTAINER_HOME=/home/openclaw
ARG CONTAINER_STATE_DIR=/home/openclaw/.openclaw
ARG APP_UID=1000
ARG APP_GID=1000
ARG OPENCLAW_VERSION=latest

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    HOME=${CONTAINER_HOME} \
    OPENCLAW_STATE_DIR=${CONTAINER_STATE_DIR} \
    OPENCLAW_CONFIG_PATH=${CONTAINER_STATE_DIR}/openclaw.json

# python3 for the plugin tooling (Telegram bot, polymarket plugin)
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 python3-pip ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# OpenClaw runtime — official install per docs.openclaw.ai/install
RUN npm install -g "openclaw@${OPENCLAW_VERSION}" --allow-scripts=openclaw

# Idempotent group creation: reuse an existing GID rather than failing.
# (macOS hosts pass GID 20; Debian images already have a group there.)
RUN getent group "${APP_GID}" >/dev/null 2>&1 \
 || groupadd --gid "${APP_GID}" openclaw \
 && useradd --uid "${APP_UID}" --gid "${APP_GID}" \
            --create-home --home-dir "${CONTAINER_HOME}" \
            --shell /bin/bash openclaw \
 && mkdir -p "${CONTAINER_STATE_DIR}" \
 && chown -R "${APP_UID}:${APP_GID}" "${CONTAINER_HOME}"

WORKDIR ${CONTAINER_HOME}

COPY --chown=${APP_UID}:${APP_GID} requirements.txt /tmp/requirements.txt
RUN pip3 install --no-cache-dir --break-system-packages \
    --requirement /tmp/requirements.txt \
 && rm -f /tmp/requirements.txt

USER openclaw

CMD ["openclaw", "gateway"]
DOCKERFILEEOF

    cat > "${STATE_DIR}/requirements.txt" << 'REQEOF'
websockets>=12.0
requests>=2.31.0
python-telegram-bot>=20.7
python-dotenv>=1.0.0
REQEOF

    cat > "${STATE_DIR}/.dockerignore" << 'DIEOF'
.env
*.key
*.pem
agents/
shared/
logs/
workspace-triad/
tmp/
state/
.git
.gitignore
*.pyc
__pycache__/
tests/
fixtures/
DIEOF

    ok "docker-compose.yml, docker.env, Dockerfile (node base + openclaw runtime)"
}

###############################################################################
# SUMMARY
###############################################################################

print_summary() {
    local f_tts f_tg f_pm f_wal f_doc
    local wallet_extra="" docker_block="" model_lines="" agent agent_model i

    if [[ "$USE_ELEVENLABS" == "true" ]]; then f_tts="[ok]"; else f_tts="[--]"; fi
    if [[ "$USE_TELEGRAM"   == "true" ]]; then f_tg="[ok]";   else f_tg="[--]"; fi
    if [[ "$USE_POLYMARKET" == "true" ]]; then f_pm="[ok]";   else f_pm="[--]"; fi
    if [[ "$USE_WALLET"     == "true" ]]; then f_wal="[ok]";   else f_wal="[--]"; fi
    if [[ "$DOCKER_ENABLE"  == "true" ]]; then f_doc="[ok]";   else f_doc="[--]"; fi

    if [[ "$USE_WALLET" == "true" ]]; then
        wallet_extra="  (${WALLET_TYPE_U} / ${WALLET_AGENT})"
    fi

    if [[ "$DOCKER_ENABLE" == "true" ]]; then
        docker_block="
  Docker
    cd ${STATE_DIR}
    docker compose --env-file docker.env build
    docker compose --env-file docker.env up -d"
    fi

    for i in 1 2 3; do
        agent="${ROSTER[$((i-1))]}"
        agent_model="$(get_model "$agent" "$i")"
        model_lines="${model_lines}
    ${agent}: ${agent_model}"
    done
    model_lines="${model_lines}
    utility: ${UTILITY_MODEL}"

    cat << SUMEOF

======================================================
  SETUP COMPLETE
======================================================

  State directory   ${STATE_DIR}
  Preset            ${PERSONALITY_PRESET}

  Roster
    1. ${SCOUT}   (scout — proposes)
    2. ${RISK}    (risk — validates/vetoes)
    3. ${JUDGE}   (arbiter — read-only rulings)

  Features
    NanoGPT API        [ok] (required)
    Gateway token      [ok] (required)
    ElevenLabs TTS     ${f_tts}
    Telegram bot       ${f_tg}
    Polymarket CLOB    ${f_pm}
    Crypto treasury    ${f_wal}${wallet_extra}
    Docker             ${f_doc}

  Models:${model_lines}${docker_block}

  Next
    1. Fill in ${STATE_DIR}/.env (NANOGPT_API_KEY, OPENCLAW_GATEWAY_TOKEN)
    2. make setup (again, to regenerate with your values)
    3. make docker-build && make docker-up

======================================================
SUMEOF
}

###############################################################################
# MAIN
###############################################################################

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
            --docker) DOCKER_ENABLE=true; shift ;;
            --wallet)
                [[ -n "${2:-}" ]] || { echo "--wallet needs a type (btc|xmr|eth)"; exit 1; }
                WALLET_TYPE="$2"; USE_WALLET=true; shift 2
                ;;
            --wallet-agent)
                [[ -n "${2:-}" ]] || { echo "--wallet-agent needs a name"; exit 1; }
                WALLET_AGENT="$2"; shift 2
                ;;
            --preset)
                [[ -n "${2:-}" ]] || { echo "--preset needs a name"; exit 1; }
                PERSONALITY_PRESET="$2"; shift 2
                ;;
            --non-interactive) shift ;;
            --help|-h) usage ;;
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
