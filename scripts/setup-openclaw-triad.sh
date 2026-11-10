#!/usr/bin/env bash
#
# setup-openclaw-triad.sh (v3.3)
#
# CHANGELOG v3.3 (vs v3.2) — env-driven model lineup
#   - NANOGPT_MODEL_CATALOG drives the provider model list:
#       comma-separated "vendor/model-id" or "vendor/model-id|Display Name"
#       (display name optional; defaults to the last path segment)
#   - TRIAD_SCOUT_MODEL / TRIAD_RISK_MODEL / TRIAD_JUDGE_MODEL set seat
#     defaults; AGENT_<NAME>_MODEL still overrides per agent (highest
#     precedence); UTILITY_MODEL sets the shared fallback.
#   - Generation-time consistency advisory: every referenced model is
#     checked against the catalog; a loud ADVISORY prints if missing
#     (catches subscription mismatches BEFORE boot, not during transport).
#   - Seeded .env documents all model knobs with a DeepSeek/GLM example.
#
# CHANGELOG v3.2 (vs v3.1) — schema-valid config from birth
#   - Agent entries carry NO theme/role keys (the runtime schema rejected
#     them 2026-11-07). Personas live solely in each agent AGENTS.md.
#   - agents.ownership: "explicit" declared (multi-agent roster requirement).
#   - No root "swarm" key, no agents "bindings" array (rejected; Telegram
#     routing is runtime channel registration instead: make telegram).
#   - Display names use roster names VERBATIM (no capitalize-glue).
#   - Compose: second tmpfs /home/openclaw/.tmp (uid/gid 0700) + TMPDIR/TMP
#     env -> private temp root (read_only fs cannot use /tmp fallback).
#
# CHANGELOG v3.1 — --non-interactive/--yes no-ops; consolidates: no json:ro
#   mount, standalone image-side rm -rf guard, mem_limit 3g, sandbox off,
#   nanogpt wiring (bare catalog ids / prefixed refs), systemAgent,
#   getent GID-20 guard, container paths throughout.
#
# Bash 3.2 safe (macOS stock): no ${var,,}, no associative arrays.
#
set -euo pipefail

###############################################################################
# USAGE
###############################################################################

usage() {
    cat << 'USAGEEOF'
setup-openclaw-triad.sh (v3.3) — generate the full OpenClaw triad stack.

Generates into OPENCLAW_STATE_DIR (default ~/.openclaw):
  openclaw.json        Gateway config (schema-valid, container paths)
  agents/*/            Agent dirs (DBs created by runtime)
  workspace-triad/     Per-agent workspaces, journals, dreams, calibration
  shared/              Append-only ledgers + calibration CSVs
  plugins/telegram-bot/bot.py   Roster-aware Telegram front-end
  tmp/ state/ logs/    Runtime dirs (lock files, leases, rotated logs)
  .gitignore           Keeps secrets + runtime state out of any repo
  Docker:
    Dockerfile         node:24-slim + openclaw runtime + image-side guard
    docker-compose.yml whole-state-dir bind, 3g mem, .tmp tmpfs, TMPDIR
    docker.env         Interpolation vars (NO secrets — committable)

Env-driven configuration (read from environment; Makefile sources .env):
  AGENT_ROSTER             comma list, default seer,guardian,sage
                           (position 1 = scout, 2 = risk/veto, 3 = judge)
  PERSONALITY_PRESET       default|mystic|bold|conservative|quant
  NANOGPT_API_KEY          enables nanogpt model provider wiring
  NANOGPT_MODEL_CATALOG    comma list of vendor/model-id (optional |Name)
  TRIAD_SCOUT_MODEL        scout seat default model id (bare, no prefix)
  TRIAD_RISK_MODEL         risk seat default model id
  TRIAD_JUDGE_MODEL        judge seat default model id
  UTILITY_MODEL            shared fallback model id
  AGENT_<NAME>_MODEL       per-agent override (beats the seat defaults)
  OPENCLAW_GATEWAY_TOKEN   required for network-bound gateway auth
  TELEGRAM_BOT_TOKEN       enables telegram plugin + runtime reminder
  TELEGRAM_USER_ID         comma-separated allowlist for the bot
  ELEVENLABS_API_KEY       enables per-agent TTS voices
  BASE_IMAGE               default node:24-slim
  OPENCLAW_VERSION         npm version of openclaw runtime (default latest)
  DOCKER_ENABLE=true       emit Docker files (or pass --docker)
  OLLAMA_ONLY=1            all seats + utility on the local Ollama provider
                           (testnet/CI mode; judgment quality is NOT calibrated)
  OLLAMA_BASE_URL          container-view Ollama endpoint
  OLLAMA_SCOUT/RISK/JUDGE/UTILITY_MODEL  per-seat ollama model ids (bare)  

Model spelling rules (the generator handles BOTH for you):
  - Catalog ids are BARE ("vendor/model-id") — what the NanoGPT API expects.
  - References in the config are nanogpt/-prefixed — what the router expects.

Flags:
  --state-dir PATH   override OPENCLAW_STATE_DIR
  --docker           force-enable Docker emission
  --wallet TYPE      btc|xmr|eth custodial config (position-2 agent holds it)
  --non-interactive  accepted no-op (v3 is always env-driven)
  --yes              alias of --non-interactive
  --help             this message
USAGEEOF
    exit 0
}


is_ollama_only() {
  [ "${OLLAMA_ONLY:-0}" = "1" ]
}

###############################################################################
# ARGUMENTS
###############################################################################

DOCKER_FLAG=false
WALLET_TYPE_ARG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --state-dir)
            [[ -n "${2:-}" ]] || { echo "--state-dir needs a path" >&2; exit 1; }
            OPENCLAW_STATE_DIR="$2"; shift 2 ;;
        --docker)   DOCKER_FLAG=true; shift ;;
        --wallet)
            [[ -n "${2:-}" ]] || { echo "--wallet needs a type (btc|xmr|eth)" >&2; exit 1; }
            WALLET_TYPE_ARG="$2"; shift 2 ;;
        --non-interactive|--yes) shift ;;
        --help|-h)  usage ;;
        *) echo "Unknown option: $1 (try --help)" >&2; exit 1 ;;
    esac
done

###############################################################################
# CORE VARIABLES (order matters under set -u)
###############################################################################

STATE_DIR="${OPENCLAW_STATE_DIR:-${HOME}/.openclaw}"
ENV_FILE="${STATE_DIR}/.env"

WORKSPACE_ROOT="${STATE_DIR}/workspace-triad"
AGENTS_ROOT="${STATE_DIR}/agents"
PLUGINS_DIR="${STATE_DIR}/plugins"
SHARED_DIR="${STATE_DIR}/shared"
CALIBRATION_DIR="${SHARED_DIR}/calibration"
LOGS_DIR="${STATE_DIR}/logs"
TMP_DIR="${STATE_DIR}/tmp"
STATE_RUNTIME_DIR="${STATE_DIR}/state"

CONTAINER_HOME="${CONTAINER_HOME:-/home/openclaw}"
CONTAINER_STATE_DIR="${CONTAINER_STATE_DIR:-${CONTAINER_HOME}/.openclaw}"
CONTAINER_AGENTS_ROOT="${CONTAINER_STATE_DIR}/agents"
CONTAINER_WORKSPACE_ROOT="${CONTAINER_STATE_DIR}/workspace-triad"

OPENCLAW_VERSION="${OPENCLAW_VERSION:-latest}"
BASE_IMAGE="${BASE_IMAGE:-node:24-slim}"
CONTAINER_MEM_LIMIT="${CONTAINER_MEM_LIMIT:-3g}"
CONTAINER_CPUS="${CONTAINER_CPUS:-2}"

APP_UID="$(id -u)"
APP_GID="$(id -g)"

# --- Roster -----------------------------------------------------------------
ROSTER_RAW="${AGENT_ROSTER:-seer,guardian,sage}"
ROSTER=()
IFS=',' read -ra _rl <<< "$ROSTER_RAW"
for _n in "${_rl[@]}"; do
    _t="$(echo "$_n" | tr -d '[:space:]')"
    [[ -n "$_t" ]] && ROSTER+=("$_t")
done
[[ "${#ROSTER[@]}" -eq 3 ]] || { echo "ERROR: AGENT_ROSTER must list exactly 3 agents (got: ${ROSTER_RAW})" >&2; exit 1; }
SCOUT="${ROSTER[0]}"
RISK="${ROSTER[1]}"
JUDGE="${ROSTER[2]}"

PRESET="${PERSONALITY_PRESET:-default}"

# --- Feature detection -------------------------------------------------------
NANOGPT_KEY="${NANOGPT_API_KEY:-}"
NANOGPT_ERA=false; [[ -n "$NANOGPT_KEY" ]] && NANOGPT_ERA=true
TELEGRAM_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_ON=false; if [[ -n "$TELEGRAM_TOKEN" ]]; then TELEGRAM_ON=true; fi
ELEVEN_KEY="${ELEVENLABS_API_KEY:-}"
ELEVEN_ON=false; if [[ -n "$ELEVEN_KEY" ]]; then ELEVEN_ON=true; fi
DOCKER_ENABLE="${DOCKER_ENABLE:-false}"
[[ "$DOCKER_FLAG" == "true" ]] && DOCKER_ENABLE=true
WALLET_TYPE="${WALLET_TYPE_ARG:-${WALLET_TYPE:-}}"
WALLET_AGENT="${WALLET_AGENT:-$RISK}"

USE_WALLET=false; if [[ -n "$WALLET_TYPE" ]]; then USE_WALLET=true; fi
# --- Ollama (local LLM; only consumed when OLLAMA_ONLY=1) ------------------
# Container-view URL by default; the generation-time preflight separately
# probes the host view (localhost). See ollama_preflight().
OLLAMA_BASE_URL="${OLLAMA_BASE_URL:-http://host.docker.internal:11434/v1}"
OLLAMA_SCOUT_MODEL="${OLLAMA_SCOUT_MODEL:-qwen3:1.7b}"
OLLAMA_RISK_MODEL="${OLLAMA_RISK_MODEL:-qwen3:1.7b}"
OLLAMA_JUDGE_MODEL="${OLLAMA_JUDGE_MODEL:-qwen3:1.7b}"
OLLAMA_UTILITY_MODEL="${OLLAMA_UTILITY_MODEL:-qwen3:0.6b}"

###############################################################################
# MODEL LINEUP RESOLUTION (v3.3 — env-driven)
###############################################################################

# Catalog: bare vendor/model-id entries; optional display name after "|".
# Defaults keep the legacy lineup if the variable is unset.
MODEL_CATALOG_RAW="${NANOGPT_MODEL_CATALOG:-anthropic/claude-sonnet-4-6,anthropic/claude-opus-4-6,openai/gpt-5.4-mini}"

MODELS_ENTRIES=""
MODEL_CATALOG_IDS=""
IFS=',' read -ra _mc <<< "$MODEL_CATALOG_RAW"
for _m in "${_mc[@]}"; do
    _m="$(printf '%s' "$_m" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [[ -z "$_m" ]] && continue
    _id="$_m"; _name=""
    case "$_m" in
        *"|"*) _id="${_m%%|*}"; _name="${_m#*|}" ;;
    esac
    [[ -z "$_name" ]] && _name="${_id##*/}"
    MODELS_ENTRIES="${MODELS_ENTRIES}
          { id: \"${_id}\", name: \"${_name}\" },"
    MODEL_CATALOG_IDS="${MODEL_CATALOG_IDS},${_id}"
done
[[ -n "$MODEL_CATALOG_IDS" ]] || { echo "ERROR: NANOGPT_MODEL_CATALOG parsed to nothing" >&2; exit 1; }
MODELS_ENTRIES="${MODELS_ENTRIES%,}"
MODEL_CATALOG_IDS="${MODEL_CATALOG_IDS#,}"

catalog_has() {
    case ",${MODEL_CATALOG_IDS}," in
        *",$1,"*) return 0 ;;
        *)        return 1 ;;
    esac
}


# Seat defaults are BARE ids in BOTH modes; pref() adds the prefix at
# reference time (fixes the double-prefix bug: ollama/… and nanogpt/
# must each be added exactly once).
if is_ollama_only; then
    SCOUT_MODEL_DEFAULT="$OLLAMA_SCOUT_MODEL"
    RISK_MODEL_DEFAULT="$OLLAMA_RISK_MODEL"
    JUDGE_MODEL_DEFAULT="$OLLAMA_JUDGE_MODEL"
    UTILITY_MODEL_DEFAULT="$OLLAMA_UTILITY_MODEL"
else
    SCOUT_MODEL_DEFAULT="${TRIAD_SCOUT_MODEL:-deepseek/deepseek-v4.1-flash-1017}"
    RISK_MODEL_DEFAULT="${TRIAD_RISK_MODEL:-anthropic/claude-opus-4-6}"
    JUDGE_MODEL_DEFAULT="${TRIAD_JUDGE_MODEL:-anthropic/claude-opus-4-6}"
    UTILITY_MODEL_DEFAULT="${UTILITY_MODEL:-openai/gpt-5.4-mini}"
fi

pref() {  # reference spelling for a model id, per active mode/era
    if is_ollama_only; then
        echo "ollama/$1"
    elif [[ "$NANOGPT_ERA" == "true" ]]; then
        echo "nanogpt/$1"
    else
        echo "$1"
    fi
}
# Consistency advisory: every referenced model should be in the catalog.
# Loud but non-fatal — the runtime is the final judge at transport time.
ADVISE_MISSING=0
advise_check() {  # advise_check <label> <bare-id>
    if is_ollama_only; then
        # Seats must be in the generated ollama fleet, not the nanogpt catalog.
        ollama_fleet_has() {
            case ",qwen3:0.6b,qwen3:1.7b," in
                *",$1,"*) return 0 ;;
                *)        return 1 ;;
            esac
        }
        for _seat in "$SCOUT_MODEL_DEFAULT" "$RISK_MODEL_DEFAULT" \
                    "$JUDGE_MODEL_DEFAULT" "$UTILITY_MODEL_DEFAULT"; do
            if ! ollama_fleet_has "$_seat"; then
                echo "   [!] ADVISORY: OLLAMA model '${_seat}' is not in the generated"
                echo "       ollama provider fleet (qwen3:0.6b, qwen3:1.7b). Add it to"
                echo "       the ollama providers block before boot."
                ADVISE_MISSING=$((ADVISE_MISSING + 1))
            fi
        done
    else
        advise_check "scout seat" "$SCOUT_MODEL_DEFAULT"
        advise_check "risk seat"  "$RISK_MODEL_DEFAULT"
        advise_check "judge seat" "$JUDGE_MODEL_DEFAULT"
        advise_check "utility"    "$UTILITY_MODEL_DEFAULT"
    fi
}

###############################################################################
# BASH 3.2-SAFE HELPERS
###############################################################################

up() { echo "$1" | tr '[:lower:]' '[:upper:]'; }

agent_var() {  # agent_var <name> <SUFFIX> <default> -> AGENT_<UPPER>_<SUFFIX>
    local vname="AGENT_$(up "$1")_$2"
    local val="${!vname:-}"
    [[ -n "$val" ]] && echo "$val" || echo "$3"
}

mkdirs() { local d; for d in "$@"; do mkdir -p "$d"; done }

###############################################################################
# PERSONAS + PRESETS (personas live in AGENTS.md, NOT in config — v3.2)
###############################################################################

case "$PRESET" in
    mystic)
        SCOUT_THEME="purple lotus fox"; SCOUT_ROLE="Scry the markets; propose trades from pattern and intuition grounded in data"
        RISK_THEME="golden wolf";       RISK_ROLE="Guard the pack treasury; validate or veto every proposal against the risk charter"
        JUDGE_THEME="silver owl";       JUDGE_ROLE="Rule only on disputes; read the full record, never touch it"
        TEMPERAMENT="mystic and deliberate; speak in calm, contemplative cadence"
        MAX_POS=5; MAX_DAILY=15; MAX_TRADES=20 ;;
    bold)
        SCOUT_THEME="crimson comet fox"; SCOUT_ROLE="Hunt fast-moving opportunities; propose aggressive but logged trades"
        RISK_THEME="iron mastiff";        RISK_ROLE="Hard veto on any breach of the risk charter, no exceptions"
        JUDGE_THEME="storm eagle";        JUDGE_ROLE="Arbitrate disputes with swift, binding rulings"
        TEMPERAMENT="decisive and direct; tolerate drawdown but never breach limits"
        MAX_POS=7; MAX_DAILY=20; MAX_TRADES=30 ;;
    conservative)
        SCOUT_THEME="grey heron";     SCOUT_ROLE="Wade carefully; propose only high-conviction setups"
        RISK_THEME="granite tortoise"; RISK_ROLE="Slow, skeptical review; when in doubt, veto"
        JUDGE_THEME="dawn hermit";     JUDGE_ROLE="Consider patiently; favor standing down over action"
        TEMPERAMENT="cautious and patient; capital preservation dominates"
        MAX_POS=3; MAX_DAILY=10; MAX_TRADES=10 ;;
    quant)
        SCOUT_THEME="chrome pointer";  SCOUT_ROLE="Scan systematically; propose statistically favorable setups only"
        RISK_THEME="matrix weasel";    RISK_ROLE="Stress-test every proposal; demand edge, not vibes"
        JUDGE_THEME="proof raven";     JUDGE_ROLE="Resolve disputes from the numbers alone"
        TEMPERAMENT="analytical and terse; probabilities over adjectives"
        MAX_POS=5; MAX_DAILY=15; MAX_TRADES=40 ;;
    *)  # default
        SCOUT_THEME="sassy oracle fox";    SCOUT_ROLE="Research and propose trades; delegate evaluation to ${RISK}"
        RISK_THEME="steady guardian wolf"; RISK_ROLE="Validate or veto every proposal; co-sign approvals"
        JUDGE_THEME="wise mediator owl";   JUDGE_ROLE="Binding rulings on disagreement; read-only by design"
        TEMPERAMENT="balanced and playful; sharp commentary, sound judgement"
        MAX_POS=5; MAX_DAILY=15; MAX_TRADES=20 ;;
esac

echo "== setup-openclaw-triad v3.3 =="
echo "   roster : ${SCOUT} (scout) / ${RISK} (risk) / ${JUDGE} (judge)"
echo "   preset : ${PRESET}   base: ${BASE_IMAGE}   openclaw: ${OPENCLAW_VERSION}"
echo "   era    : nanogpt=${NANOGPT_ERA} telegram=${TELEGRAM_ON} tts=${ELEVEN_ON} docker=${DOCKER_ENABLE}"
echo "   models : catalog=${MODEL_CATALOG_IDS}"
echo "            scout=${SCOUT_MODEL_DEFAULT}  risk=${RISK_MODEL_DEFAULT}  judge=${JUDGE_MODEL_DEFAULT}"
echo "            utility=${UTILITY_MODEL_DEFAULT}"
if [[ "$ADVISE_MISSING" -gt 0 ]]; then
    echo "            [!] ${ADVISE_MISSING} reference(s) missing from catalog — see ADVISORY above"
else
    echo "            (all references covered by catalog)"
fi

###############################################################################
# .ENV STEWARDSHIP (seed if absent, NEVER overwrite)
###############################################################################

mkdirs "$STATE_DIR"

if [[ ! -f "$ENV_FILE" ]]; then
    OPENCLAW_GATEWAY_TOKEN_SEED="$(openssl rand -hex 32 2>/dev/null || echo change-me-please)"
    cat << ENVEOF > "$ENV_FILE"
# OpenClaw triad environment — secrets live here. chmod 600. Never commit.
NANOGPT_API_KEY=
OPENCLAW_GATEWAY_TOKEN=${OPENCLAW_GATEWAY_TOKEN_SEED}
AGENT_ROSTER=${ROSTER_RAW}
PERSONALITY_PRESET=${PRESET}

# --- Model lineup (v3.3+) — change models HERE, never in the scripts ---
# Catalog ids are BARE vendor/model-id; optional display name after |.
# Every model referenced below must appear in the catalog.
# NANOGPT_MODEL_CATALOG=deepseek/deepseek-v4.1-flash-1017,z-ai/glm-5.3,z-ai/glm-5.3-flash-uncensored
# TRIAD_SCOUT_MODEL=deepseek/deepseek-v4.1-flash-1017
# TRIAD_RISK_MODEL=z-ai/glm-5.3
# TRIAD_JUDGE_MODEL=z-ai/glm-5.3
# UTILITY_MODEL=z-ai/glm-5.3-flash-uncensored
# Per-agent overrides beat the seat vars:
# AGENT_$(up "$SCOUT")_MODEL=
# AGENT_$(up "$RISK")_MODEL=
# AGENT_$(up "$JUDGE")_MODEL=

# Optional:
# TELEGRAM_BOT_TOKEN=
# TELEGRAM_USER_ID=
# ELEVENLABS_API_KEY=
# ELEVENLABS_VOICE_ID=
DOCKER_ENABLE=${DOCKER_ENABLE}
ENVEOF
    chmod 600 "$ENV_FILE"
    echo "   [!] Seeded ${ENV_FILE} — fill in NANOGPT_API_KEY (and Telegram token if desired)."
else
    echo "   [ok] Existing .env preserved"
fi

###############################################################################
# DIRECTORY SCAFFOLD
###############################################################################

mkdirs "$AGENTS_ROOT" "$WORKSPACE_ROOT" "$PLUGINS_DIR" "$SHARED_DIR" \
       "$CALIBRATION_DIR" "$LOGS_DIR" "$TMP_DIR" "$STATE_RUNTIME_DIR"

for AGENT in "${ROSTER[@]}"; do
    AW="${WORKSPACE_ROOT}/${AGENT}"
    mkdirs "$AW" "${AW}/journal" "${AGENTS_ROOT}/${AGENT}/agent"
    CAL_CSV="${CALIBRATION_DIR}/${AGENT}-decisions.csv"
    [[ -f "$CAL_CSV" ]] || printf 'timestamp,proposal,confidence,outcome,hit\n' > "$CAL_CSV"
done

###############################################################################
# PER-AGENT WORKSPACE DOCS (personas live HERE since v3.2)
###############################################################################

timeline_docs() {
    cat << 'TLEOF'
## Non-skippable milestones
1. TESTNET — four weeks, zero unlogged manual interventions. `trading.json`
   ships in `"mode": "testnet"` for exactly this reason.
2. PAPER — four weeks of positive expectancy on simulated fills.
3. LIVE (small) — only when all three agents align on readiness, and only
   at risk limits that are genuinely affordable to lose.

Weekly ritual: review your calibration CSV hit-rate; note miscalibration
in your journal — never silently correct it.
TLEOF
}

write_agent_docs() {
    local agent="$1" theme="$2" role="$3"
    local aw="${WORKSPACE_ROOT}/${agent}"

    cat << EOAG > "${aw}/AGENTS.md"
# ${agent} — ${theme}

**Position role:** ${role}

## Temperament
${TEMPERAMENT}

## Hard rules
- You never execute alone. Proposals flow to ${RISK} for validation;
  disputes go to ${JUDGE}, whose rulings are binding.
- Every decision is logged to shared/ calibration CSVs. The ledger is
  append-only. Retro-editing a record is the one unforgivable sin.
EOAG

    cat << EOD > "${aw}/DREAMS.md"
# ${agent}'s dreams

I hold capital in trust, not in ambition. My success is measured in
calibrated judgement, not raw profit — a well-rejected trade is a win.

$(timeline_docs)
EOD
}

write_agent_docs "$SCOUT" "$SCOUT_THEME" "$SCOUT_ROLE"
write_agent_docs "$RISK" "$RISK_THEME" "$RISK_ROLE"
write_agent_docs "$JUDGE" "$JUDGE_THEME" "$JUDGE_ROLE"

###############################################################################
# TRADING CONFIG (testnet by default)
###############################################################################

cat << EOT > "${SHARED_DIR}/trading.json"
{
  "mode": "testnet",
  "risk": {
    "maxPositionPct": ${MAX_POS},
    "maxDailyLossPct": ${MAX_DAILY},
    "maxTradesPerDay": ${MAX_TRADES},
    "minRiskReward": 2.0
  },
  "notes": "Defaults are starting points, set to numbers you can afford to lose."
}
EOT

cat << EOG > "${SHARED_DIR}/GITGUIDE.md"
# Shared ledger discipline

- shared/ledger.csv is append-only. Never rewrite history.
- Weekly: each agent reviews its calibration hit-rate from
  shared/calibration/<name>-decisions.csv.
- A dead-broke or broken system look identical from the logs: check the
  NanoGPT balance alongside calibration reviews.
EOG

if [[ "$USE_WALLET" == "true" ]]; then
    cat << EOW > "${SHARED_DIR}/wallet.json"
{
  "type": "${WALLET_TYPE}",
  "custodian": "${WALLET_AGENT}",
  "mode": "testnet",
  "keySource": "environment",
  "auditLog": "logs/wallet.log",
  "maxAutoWithdrawalUsd": 0
}
EOW
    echo "   [ok] Wallet config: ${WALLET_TYPE} held by ${WALLET_AGENT} (testnet, env-sourced key, zero auto-withdrawal)"
fi

###############################################################################
# OPENCLAW.JSON — schema-valid assembly (v3.2: no theme/role keys, explicit
# ownership, verbatim display names, no swarm, no bindings arrays)
###############################################################################

###############################################################################
# PROVIDERS ASSEMBLY (nanogpt AND/OR ollama)
###############################################################################

PROVIDERS=()

if [[ "$NANOGPT_ERA" == "true" ]]; then
    PROVIDERS+=("      nanogpt: {
        baseUrl: \"https://nano-gpt.com/api/v1\",
        apiKey: \"${NANOGPT_API_KEY}\",
        api: \"openai-completions\",
        models: [${MODELS_ENTRIES}
        ]
      }")
fi

if is_ollama_only; then
    # Bare catalog ids — what the local Ollama API expects. References in
    # agents.* get the ollama/ prefix at reference time via pref().
    # apiKey is the documented non-secret marker for loopback/LAN origins.
    PROVIDERS+=("      ollama: {
        baseUrl: \"${OLLAMA_BASE_URL}\",
        apiKey: \"ollama-local\",
        api: \"openai-completions\",
        models: [
          { id: \"qwen3:0.6b\", name: \"qwen3-0.6b\" },
          { id: \"qwen3:1.7b\", name: \"qwen3-1.7b\" }
        ]
      }")
fi

MODELS_BLOCK=""
if [[ "${#PROVIDERS[@]}" -gt 0 ]]; then
    PROVIDERS_JOINED=""
    _pi=0
    _pn="${#PROVIDERS[@]}"
    for _pf in "${PROVIDERS[@]}"; do
        _pi=$((_pi + 1))
        PROVIDERS_JOINED="${PROVIDERS_JOINED}${_pf}"
        [[ "$_pi" -lt "$_pn" ]] && PROVIDERS_JOINED="${PROVIDERS_JOINED},"
        PROVIDERS_JOINED="${PROVIDERS_JOINED}
"
    done
    MODELS_BLOCK="  models: {
    mode: \"merge\",
    providers: {
${PROVIDERS_JOINED}    }
  },"
fi

# wllama_preflight

ollama_preflight() {
    # Generation-time, HOST-side probe. The generator runs on the host where
    # the Ollama server is localhost:11434 — OLLAMA_BASE_URL is the CONTAINER
    # view (host.docker.internal) and may not resolve from the host itself.
    # Container-side reachability is checked at boot time instead (see §8).
    # Advisory-only: generation must succeed without an Ollama server.
    is_ollama_only || return 0
    local tags _m
    tags="$(curl -sf --max-time 3 http://localhost:11434/api/tags 2>/dev/null || true)"
    if [[ -z "$tags" ]]; then
        echo "   [!] OLLAMA_ONLY=1 but no Ollama server answered on localhost:11434."
        echo "       Generation succeeded, but BOOT will need it:"
        echo "         ollama serve &        # if not already running"
        return 0
    fi
    for _m in "$OLLAMA_SCOUT_MODEL" "$OLLAMA_RISK_MODEL" \
              "$OLLAMA_JUDGE_MODEL" "$OLLAMA_UTILITY_MODEL"; do
        case "$tags" in
            *"\"${_m}\""*) ;;  # already pulled
            *)
                echo "   [!] Ollama is up but '${_m}' is not pulled yet:"
                echo "         ollama pull ${_m}"
                ;;
        esac
    done
    echo "   [ok] Ollama preflight: server reachable on localhost:11434"
    return 0
}

# Agent entries assembled in a variable (expanded now), spliced into the
# config heredoc below. Entries carry ONLY schema-recognized keys.
AGENT_ENTRIES=""
for AGENT in "${ROSTER[@]}"; do
    # Set defaults
    SEAT_THINKING_DEFAULT="medium"
    SEAT_REASONING_DEFAULT="on"
    if is_ollama_only; then
        # Sub-2B models: reasoning loops + unstable tool-call formatting.
        SEAT_THINKING_DEFAULT="off"
        SEAT_REASONING_DEFAULT="off"
    fi
    case "$AGENT" in
        "$SCOUT") DEF_MODEL="$SCOUT_MODEL_DEFAULT" ;;
        "$RISK")  DEF_MODEL="$RISK_MODEL_DEFAULT"  ;;
        *)        DEF_MODEL="$JUDGE_MODEL_DEFAULT" ;;
    esac
    MODEL="$(agent_var "$AGENT" MODEL "$DEF_MODEL")"
    THINK="$(agent_var "$AGENT" THINKING "${SEAT_THINKING_DEFAULT}")" 
    VOICE="$(agent_var "$AGENT" VOICE "${ELEVENLABS_VOICE_ID:-default}")"

    TTS=""
    if [[ "$ELEVEN_ON" == "true" ]]; then
        TTS=", tts: { providers: { elevenlabs: { speakerVoiceId: \"${VOICE}\" } } }"
    fi

    # Judge is read-only by design: a mediator who can alter the record
    # is not a mediator. Scout+Risk get write/exec; Judge gets read/message.
    if [[ "$AGENT" != "$JUDGE" ]]; then
        TOOLS=", tools: { allow: [\"read\", \"write\", \"exec\", \"message\"] }"
    else
        TOOLS=", tools: { allow: [\"read\", \"message\"] }"
    fi
    AGENT_ENTRIES="${AGENT_ENTRIES}      ${AGENT}: {
        name: \"${AGENT}\",
        workspace: \"${CONTAINER_WORKSPACE_ROOT}/${AGENT}\",
        agentDir: \"${CONTAINER_AGENTS_ROOT}/${AGENT}/agent\",
        model: {
          primary: \"$(pref "$MODEL")\",
          fallbacks: [\"$(pref "$UTILITY_MODEL_DEFAULT")\"]
        },
        utilityModel: \"$(pref "$UTILITY_MODEL_DEFAULT")\",
        thinkingDefault: \"${THINK}\",
        reasoningDefault: \"${SEAT_REASONING_DEFAULT}\",
        sandbox: { mode: \"off\" }${TOOLS}${TTS}
      },"
done
AGENT_ENTRIES="${AGENT_ENTRIES%,}"   # trim trailing comma (bash 3.2 safe)

cat << EOJSON > "${STATE_DIR}/openclaw.json"
{
  gateway: { mode: "local" },
${MODELS_BLOCK}
  agents: {
    ownership: "explicit",
    defaults: {
      systemAgent: { agentId: "${SCOUT}" },
      workspace: "${CONTAINER_WORKSPACE_ROOT}",
      cwd: "${CONTAINER_WORKSPACE_ROOT}",
      model: {
        primary: "$(pref "$SCOUT_MODEL_DEFAULT")",
        fallbacks: ["$(pref "$UTILITY_MODEL_DEFAULT")"]
      },
      utilityModel: "$(pref "$UTILITY_MODEL_DEFAULT")",
      sandbox: { mode: "off" }
    },
    entries: {
${AGENT_ENTRIES}
    }
  }
}
EOJSON
if is_ollama_only; then
    echo "   mode   : OLLAMA_ONLY — all seats + utility on local Ollama."
    echo "            Mechanics/testing only. Do NOT calibrate judgment"
    echo "            quality from this mode's output."
fi
echo "   [ok] openclaw.json written (schema-valid, ownership explicit, sandbox off, systemAgent=${SCOUT})"
# Write ollama stuff
ollama_preflight

###############################################################################
# TELEGRAM PLUGIN (roster-aware front-end)
###############################################################################

TG_DIR="${PLUGINS_DIR}/telegram-bot"
mkdirs "$TG_DIR"

cat << 'EOBOT' > "${TG_DIR}/bot.py"
#!/usr/bin/env python3
"""Roster-aware Telegram front-end for the OpenClaw triad."""
import logging, os, asyncio

logging.basicConfig(
    format="%(asctime)s %(levelname)s %(name)s - %(message)s", level=logging.INFO
)
log = logging.getLogger("openclaw.telegram")

TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
ALLOWED = {u.strip() for u in os.environ.get("TELEGRAM_USER_ID", "").split(",") if u.strip()}
ROSTER = [a.strip() for a in os.environ.get("AGENT_ROSTER", "").split(",") if a.strip()]

if not ROSTER:
    ROSTER = ["scout", "risk", "arbiter"]


def authorised(update):
    return str(update.effective_user.id) in ALLOWED


def build_app():
    from telegram.ext import ApplicationBuilder, CommandHandler

    app = ApplicationBuilder().token(TOKEN).build()

    async def cmd_start(update, context):
        if not authorised(update):
            return
        lines = "\n".join(f"/{a} - talk to {a}" for a in ROSTER)
        await update.message.reply_text("OpenClaw triad online.\n" + lines)

    async def make_handler(agent):
        async def handler(update, context):
            if not authorised(update):
                return
            text = update.message.text or ""
            proc = await asyncio.create_subprocess_exec(
                "openclaw", "agent", "--agent", agent, "--message", text,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
            )
            out, _ = await proc.communicate()
            await update.message.reply_text((out or b"(no reply)").decode()[:4000])

        return handler

    app.add_handler(CommandHandler("start", cmd_start))
    for a in ROSTER:
        app.add_handler(CommandHandler(a, make_handler(a)))
    return app


if __name__ == "__main__":
    if not TOKEN:
        raise SystemExit("TELEGRAM_BOT_TOKEN is not set")
    build_app().run_polling()
EOBOT
chmod +x "${TG_DIR}/bot.py"

printf 'python-telegram-bot>=21,<22\n' > "${STATE_DIR}/requirements.txt"
echo "   [ok] telegram plugin written (roster: ${ROSTER_RAW})"
if [[ "$TELEGRAM_ON" == "true" ]]; then
    echo "   [i] Telegram credentials detected. The CHANNEL itself is registered"
    echo "       at runtime after first successful boot:  make telegram"
fi

###############################################################################
# GITIGNORE (state dir hygiene)
###############################################################################

cat << 'EOGI' > "${STATE_DIR}/.gitignore"
.env
agents/
state/
tmp/
logs/
*.sqlite
*.sqlite-*
*.log
EOGI

###############################################################################
# DOCKER EMISSION
###############################################################################

if [[ "$DOCKER_ENABLE" == "true" ]]; then

    HOST_STATE_DIR_ABS="$(cd "$STATE_DIR" && pwd)"

    # --- docker.env (interpolation vars; NO secrets — committable) ----------
    cat << EODE > "${STATE_DIR}/docker.env"
# Generated by setup-openclaw-triad.sh (v3.3) — interpolation only, no secrets.
COMPOSE_PROJECT_NAME=openclaw-triad

# ---- Host paths (derived from OPENCLAW_STATE_DIR) ----
OPENCLAW_HOST_STATE_DIR=${HOST_STATE_DIR_ABS}
OPENCLAW_WORKSPACE_DIR=${HOST_STATE_DIR_ABS}/workspace-triad

# ---- Container paths ----
CONTAINER_STATE_DIR=${CONTAINER_STATE_DIR}

# ---- Identity (host-matched uid/gid for bind-mount writes) ----
APP_UID=${APP_UID}
APP_GID=${APP_GID}

# ---- Build ----
BASE_IMAGE=${BASE_IMAGE}
OPENCLAW_VERSION=${OPENCLAW_VERSION}

# ---- Runtime ceilings ----
CONTAINER_MEM_LIMIT=${CONTAINER_MEM_LIMIT}
CONTAINER_CPUS=${CONTAINER_CPUS}
EODE

    # --- Dockerfile -----------------------------------------------------------
    # All ${VARS} below are Docker build args / env resolved by docker itself.
    cat << 'EODF' > "${STATE_DIR}/Dockerfile"
# syntax=docker/dockerfile:1
# Generated by setup-openclaw-triad.sh (v3.3)

ARG BASE_IMAGE=node:24-slim

FROM ${BASE_IMAGE}

ARG APP_UID=1000
ARG APP_GID=1000
ARG CONTAINER_HOME=/home/openclaw
ARG CONTAINER_STATE_DIR=/home/openclaw/.openclaw
ARG OPENCLAW_VERSION=latest

ENV DEBIAN_FRONTEND=noninteractive
ENV OPENCLAW_STATE_DIR=${CONTAINER_STATE_DIR}

# Runtime deps: git for workspaces, python3 for plugin tooling.
RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates python3 python3-pip \
    && rm -rf /var/lib/apt/lists/*

# Host-matched uid/gid. macOS primary GID is 20 (staff), which collides
# with Debian dialout — reuse instead of failing (exit 4 taught us).
RUN getent group "${APP_GID}" >/dev/null 2>&1 \
      || groupadd --gid "${APP_GID}" openclaw
RUN getent passwd "${APP_UID}" >/dev/null 2>&1 \
      || useradd --uid "${APP_UID}" --gid "${APP_GID}" \
           --create-home --home-dir "${CONTAINER_HOME}" \
           --shell /bin/bash openclaw
RUN mkdir -p "${CONTAINER_STATE_DIR}" \
    && chown -R "${APP_UID}:${APP_GID}" "${CONTAINER_HOME}"
# Image-side guard: no config-shaped directory may ever exist in the image.
# (A directory named openclaw.json in a cached layer made the bind-mount
# fail with not-a-directory. This line is standalone on purpose.)
RUN rm -rf "${CONTAINER_STATE_DIR}/openclaw.json"

# The OpenClaw runtime itself.
RUN npm install -g "openclaw@${OPENCLAW_VERSION}" --allow-scripts=openclaw

# Python plugin deps.
COPY requirements.txt /tmp/requirements.txt
RUN pip3 install --break-system-packages -r /tmp/requirements.txt \
    || pip3 install -r /tmp/requirements.txt
RUN rm /tmp/requirements.txt

USER openclaw
WORKDIR "${CONTAINER_HOME}"

EXPOSE 18789

CMD ["openclaw", "gateway"]
EODF

    # --- docker-compose.yml ----------------------------------------------------
    # ${VARS} below are interpolated by docker compose from docker.env.
    cat << 'EOCC' > "${STATE_DIR}/docker-compose.yml"
# Generated by setup-openclaw-triad.sh (v3.3)
services:
  openclaw-triad:
    image: openclaw-triad:local
    build:
      context: .
      args:
        APP_UID: "${APP_UID}"
        APP_GID: "${APP_GID}"
        BASE_IMAGE: "${BASE_IMAGE}"
        OPENCLAW_VERSION: "${OPENCLAW_VERSION}"
    container_name: openclaw-triad
    restart: unless-stopped
    env_file:
      - .env
    extra_hosts:
      - "host.docker.internal:host-gateway"
    environment:
      OPENCLAW_STATE_DIR: ${CONTAINER_STATE_DIR}
      OPENCLAW_WORKSPACE_DIR: ${CONTAINER_STATE_DIR}/workspace-triad
      OPENCLAW_CONFIG_PATH: ${CONTAINER_STATE_DIR}/openclaw.json
      TMPDIR: /home/openclaw/.tmp
      TMP: /home/openclaw/.tmp
    volumes:
      # Whole state dir: runtime needs tmp/, sqlite state, lease locks.
      # (No per-file config overlay — a bind-type mismatch caused
      #  not-a-directory OCI failures. The parent bind delivers config.)
      - ${OPENCLAW_HOST_STATE_DIR}:${CONTAINER_STATE_DIR}
    tmpfs:
      # User-owned secure temp/cache (root-owned tmpfs tripped EACCES once).
      - /home/openclaw/.cache:uid=${APP_UID},gid=${APP_GID},mode=0700
      # Private temp root (v3.2): read_only fs cannot fall back to /tmp.
      - /home/openclaw/.tmp:uid=${APP_UID},gid=${APP_GID},mode=0700
    read_only: true
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    mem_limit: ${CONTAINER_MEM_LIMIT}
    cpus: ${CONTAINER_CPUS}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    healthcheck:
      test: ["CMD-SHELL", "test -f ${CONTAINER_STATE_DIR}/openclaw.json"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 60s
EOCC

    echo "   [ok] Docker trio written: Dockerfile + docker-compose.yml + docker.env (mem_limit=${CONTAINER_MEM_LIMIT}, .tmp tmpfs + TMPDIR, no config-file mount, image-side guard)"
else
    echo "   [--] Docker emission skipped (DOCKER_ENABLE != true / no --docker)"
fi

###############################################################################
# SUMMARY
###############################################################################

cat << EOSUM

======================================================================
  Stack generated. Next:
======================================================================
  State dir : ${STATE_DIR}
  Roster    : ${SCOUT} (scout) / ${RISK} (risk) / ${JUDGE} (judge)
  Preset    : ${PRESET} - limits: ${MAX_POS}% pos / ${MAX_DAILY}% daily / ${MAX_TRADES} trades
  Models    : scout=${SCOUT_MODEL_DEFAULT} risk=${RISK_MODEL_DEFAULT}
              judge=${JUDGE_MODEL_DEFAULT} utility=${UTILITY_MODEL_DEFAULT}
EOSUM
if [[ "$ADVISE_MISSING" -gt 0 ]]; then
    echo "             [!] ${ADVISE_MISSING} model reference(s) missing from catalog — fix before boot"
fi
if [[ "$DOCKER_ENABLE" == "true" ]]; then
    echo "  1. Review ${ENV_FILE} (secrets, keys, model lineup)"
    echo "  2. make docker-build && make docker-up"
else
    echo "  1. Review ${ENV_FILE} (secrets, keys, model lineup)"
    echo "  2. run with --docker / DOCKER_ENABLE=true for the container stack"
fi
cat << EOSUM2
  3. make logs — expect [gateway] ready and your roster names registering

  First contact:
    docker exec -it openclaw-triad openclaw agent \\
        --agent ${SCOUT} --message "Hello - introduce yourself in one sentence."

  Telegram (once, after first successful boot):
    make telegram
======================================================================
EOSUM2
