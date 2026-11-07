#!/usr/bin/env bash
#
# setup-openclaw-triad.sh (v3.2)
#
# Consolidates every fix from the 2026-11-07 deployment saga.
#
# CHANGELOG v3.2 (vs v3.1) — "schema-valid + writable temp"
#   CONFIG (openclaw.json) — validated against the live runtime schema:
#     - REMOVED theme:/role: from agent entries (Unrecognized keys);
#       personas live in agents' AGENTS.md / DREAMS.md, their true home.
#     - ADDED agents.ownership: "explicit" (multi-agent roster requirement).
#     - REMOVED agents.bindings (Unrecognized key) — Telegram channel
#       registration happens at runtime via `openclaw channels add telegram`
#       (the runtime suppressed ambient env credentials and told us the
#       correct mechanism on 2026-11-07).
#     - REMOVED root-level swarm key (Unrecognized key).
#     - Display name is the roster name VERBATIM ("thesource" stays
#       "thesource"; naive capitalization produced "Thesource").
#   COMPOSE:
#     - Second tmpfs /home/openclaw/.tmp (uid/gid matched, 0700) plus
#       TMPDIR/TMP env pointing at it. Root fs is read_only; the runtime's
#       secure-temp requirements demand a REAL private dir — /tmp is not
#       writable and fails with "Unable to create fallback OpenClaw temp dir".
#   GENERAL:
#     - Post-generation summary reminds about `openclaw channels add telegram`
#       when TELEGRAM_BOT_TOKEN is present.
#
# CHANGELOG v3.1 (vs v3.0)
#     - --non-interactive/--yes accepted as no-ops (v2.5 Makefile compat).
#     - Standalone RUN rm -rf guard in Dockerfile; dropped openclaw.json:ro
#       mount (bind-type mismatch); mem_limit 3g (exit 137 under 2g); sandbox
#       off (container IS the sandbox); nanogpt wiring (bare catalog ids,
#       nanogpt/-prefixed refs); systemAgent; container paths throughout;
#       BASE_IMAGE node:24-slim; .env stewardship; bash 3.2 safe.
#
set -euo pipefail

###############################################################################
# USAGE
###############################################################################

usage() {
    cat << 'USAGEEOF'
setup-openclaw-triad.sh (v3.2) — generate the full OpenClaw triad stack.

Generates into OPENCLAW_STATE_DIR (default ~/.openclaw):
  openclaw.json        Gateway config (schema-valid, container paths)
  agents/*/           Agent dirs (DBs created by runtime)
  workspace-triad/     Per-agent workspaces, journals, dreams, calibration
  shared/              Append-only ledgers + calibration CSVs
  plugins/telegram-bot/bot.py   Legacy Telegram front-end (fallback only)
  tmp/ state/ logs/    Runtime dirs (lock files, leases, rotated logs)
  .gitignore           Keeps secrets + runtime state out of any repo
  Docker:
    Dockerfile         node:24-slim + openclaw runtime + image-side guard
    docker-compose.yml whole-state-dir bind, 2x tmpfs (.cache + .tmp),
                       TMPDIR wired, locked-down runtime
    docker.env         Interpolation vars (NO secrets — committable)

Env-driven configuration (read from the environment; Makefile sources .env):
  AGENT_ROSTER             comma list, default seer,guardian,sage
                           (position 1 = scout/proposer, 2 = risk/veto,
                            3 = judge/read-only ruler)
  PERSONALITY_PRESET       default|mystic|bold|conservative|quant
  NANOGPT_API_KEY          enables nanogpt model provider wiring
  OPENCLAW_GATEWAY_TOKEN   required for network-bound gateway auth
  TELEGRAM_BOT_TOKEN       enables telegram channel wiring
  TELEGRAM_USER_ID         comma-separated allowlist for the bot
  ELEVENLABS_API_KEY       enables per-agent TTS voices
  AGENT_<NAME>_MODEL/THINKING/VOICE   per-agent overrides
  BASE_IMAGE               default node:24-slim
  OPENCLAW_VERSION         npm version of openclaw runtime (default latest)
  DOCKER_ENABLE=true       emit Docker files (or pass --docker)

Flags:
  --state-dir PATH   override OPENCLAW_STATE_DIR
  --docker           force-enable Docker emission
  --wallet TYPE      btc|xmr|eth custodial config (position-2 agent holds it)
  --non-interactive  v2.5 compat no-op (v3+ is always env/.env driven)
  --yes              alias of --non-interactive (no-op)
  --help             this message

NOTE: the Telegram CHANNEL is registered at runtime, post-boot:
    docker exec -it openclaw-triad openclaw channels add telegram
USAGEEOF
    exit 0
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
TELEGRAM_ON=false; [[ -n "$TELEGRAM_TOKEN" ]] && TELEGRAM_ON=true
ELEVEN_KEY="${ELEVENLABS_API_KEY:-}"
ELEVEN_ON=false; [[ -n "$ELEVEN_KEY" ]] && ELEVEN_ON=true
DOCKER_ENABLE="${DOCKER_ENABLE:-false}"
[[ "$DOCKER_FLAG" == "true" ]] && DOCKER_ENABLE=true
WALLET_TYPE="${WALLET_TYPE_ARG:-${WALLET_TYPE:-}}"
WALLET_AGENT="${WALLET_AGENT:-$RISK}"
USE_WALLET=false; [[ -n "$WALLET_TYPE" ]] && USE_WALLET=true

###############################################################################
# BASH 3.2-SAFE HELPERS
###############################################################################

up() { echo "$1" | tr '[:lower:]' '[:upper:]'; }

agent_var() {
    local vname="AGENT_$(up "$1")_$2"
    local val="${!vname:-}"
    [[ -n "$val" ]] && echo "$val" || echo "$3"
}

mkdirs() { local d; for d in "$@"; do mkdir -p "$d"; done }

###############################################################################
# PERSONAS + PRESETS  (used for the agents' DOCS, not the config schema)
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
        SCOUT_THEME="sassy oracle fox"; SCOUT_ROLE="Research and propose trades; delegate evaluation to ${RISK}"
        RISK_THEME="steady guardian wolf"; RISK_ROLE="Validate or veto every proposal; co-sign approvals"
        JUDGE_THEME="wise mediator owl";   JUDGE_ROLE="Binding rulings on disagreement; read-only by design"
        TEMPERAMENT="balanced and playful; sharp commentary, sound judgement"
        MAX_POS=5; MAX_DAILY=15; MAX_TRADES=20 ;;
esac

# Per-position model defaults (overridable via AGENT_<NAME>_MODEL)
SCOUT_MODEL_DEFAULT="anthropic/claude-sonnet-4-6"
RISK_MODEL_DEFAULT="anthropic/claude-opus-4-6"
JUDGE_MODEL_DEFAULT="anthropic/claude-opus-4-6"
UTILITY_MODEL="${UTILITY_MODEL:-openai/gpt-5.4-mini}"

pref() {  # nanogpt-era reference spelling for a model id
    if [[ "$NANOGPT_ERA" == "true" ]]; then echo "nanogpt/$1"; else echo "$1"; fi
}

echo "== setup-openclaw-triad v3.2 =="
echo "   roster : ${SCOUT} (scout) / ${RISK} (risk) / ${JUDGE} (judge)"
echo "   preset : ${PRESET}   base: ${BASE_IMAGE}   openclaw: ${OPENCLAW_VERSION}"
echo "   era    : nanogpt=${NANOGPT_ERA} telegram=${TELEGRAM_ON} tts=${ELEVEN_ON} docker=${DOCKER_ENABLE}"

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
# Optional:
# TELEGRAM_BOT_TOKEN=
# TELEGRAM_USER_ID=
# ELEVENLABS_API_KEY=
# ELEVENLABS_VOICE_ID=
# AGENT_$(up "$SCOUT")_MODEL=
# AGENT_$(up "$RISK")_MODEL=
# AGENT_$(up "$JUDGE")_MODEL=
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
# PER-AGENT WORKSPACE DOCS (AGENTS.md + DREAMS.md)
# Personas ACTUALLY live here — the runtime schema rejected theme/role on
# agent entries, and the docs are what the agents read anyway.
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
# OPENCLAW.JSON — schema-valid (validated against live runtime 2026-11-07)
#
# Schema rules learned the hard way:
#   - agent entries accept: name, workspace, agentDir, model, utilityModel,
#     thinkingDefault, reasoningDefault, sandbox, tools, tts. NOT theme/role.
#   - agents accepts: ownership ("explicit" required for multi-agent),
#     defaults, entries. NOT bindings.
#   - root accepts: gateway, models, agents. NOT swarm.
#   - Telegram channel registration happens at runtime:
#       openclaw channels add telegram
###############################################################################

MODELS_BLOCK=""
if [[ "$NANOGPT_ERA" == "true" ]]; then
    MODELS_BLOCK=$(cat << 'EOMB'
  models: {
    mode: "merge",
    providers: {
      nanogpt: {
        baseUrl: "https://nano-gpt.com/api/v1",
        apiKey: "${NANOGPT_API_KEY}",
        api: "openai-completions",
        models: [
          { id: "anthropic/claude-sonnet-4-6", name: "Claude Sonnet 4.6" },
          { id: "anthropic/claude-opus-4-6", name: "Claude Opus 4.6" },
          { id: "openai/gpt-5.4-mini", name: "GPT-5.4 Mini" }
        ]
      }
    }
  },
EOMB
)
fi

AGENT_ENTRIES=""
for AGENT in "${ROSTER[@]}"; do
    case "$AGENT" in
        "$SCOUT") DEF_MODEL="$SCOUT_MODEL_DEFAULT" ;;
        "$RISK")  DEF_MODEL="$RISK_MODEL_DEFAULT"  ;;
        *)        DEF_MODEL="$JUDGE_MODEL_DEFAULT" ;;
    esac
    MODEL="$(agent_var "$AGENT" MODEL "$DEF_MODEL")"
    THINK="$(agent_var "$AGENT" THINKING medium)"
    VOICE="$(agent_var "$AGENT" VOICE "${ELEVENLABS_VOICE_ID:-default}")"

    TTS=""
    if [[ "$ELEVEN_ON" == "true" ]]; then
        TTS=", tts: { providers: { elevenlabs: { speakerVoiceId: \"${VOICE}\" } } }"
    fi

    # Judge is read-only by design: a mediator who can alter the record
    # isn't a mediator. Scout+Risk get write/exec; Judge gets read/message.
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
          fallbacks: [\"$(pref "$UTILITY_MODEL")\"]
        },
        utilityModel: \"$(pref "$UTILITY_MODEL")\",
        thinkingDefault: \"${THINK}\",
        reasoningDefault: \"on\",
        sandbox: { mode: \"off\" }${TOOLS}${TTS}
      },"
done
AGENT_ENTRIES="${AGENT_ENTRIES%,}"   # trim trailing comma (bash 3.2 param expansion)

cat << EOJSON > "${STATE_DIR}/openclaw.json"
// Generated by setup-openclaw-triad.sh (v3.2)
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
        fallbacks: ["$(pref "$UTILITY_MODEL")"]
      },
      utilityModel: "$(pref "$UTILITY_MODEL")",
      sandbox: { mode: "off" }
    },
    entries: {
${AGENT_ENTRIES}
    }
  }
}
EOJSON

echo "   [ok] openclaw.json written (schema-valid: ownership explicit, no theme/role/bindings/swarm, systemAgent=${SCOUT})"

###############################################################################
# TELEGRAM PLUGIN (legacy fallback front-end; primary path is the runtime
# channel registered via `openclaw channels add telegram`)
###############################################################################

TG_DIR="${PLUGINS_DIR}/telegram-bot"
mkdirs "$TG_DIR"

cat << 'EOBOT' > "${TG_DIR}/bot.py"
#!/usr/bin/env python3
"""Legacy roster-aware Telegram front-end for the OpenClaw triad.
Primary path is the runtime channel (openclaw channels add telegram);
keep this as a fallback if the channel route is unavailable."""
import logging, os, asyncio

logging.basicConfig(
    format="%(asctime)s %(levelname)s %(name)s — %(message)s", level=logging.INFO
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
        lines = "\n".join(f"/{a} — talk to {a}" for a in ROSTER)
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
echo "   [ok] telegram plugin written (roster: ${ROSTER_RAW}; primary path: runtime channel)"

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
# Generated by setup-openclaw-triad.sh (v3.2) — interpolation only, no secrets.
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
# Generated by setup-openclaw-triad.sh (v3.2)

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

# Host-matched uid/gid. macOS primary GID is 20 ('staff'), which collides
# with Debian's dialout group — reuse instead of failing (exit 4 taught us).
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
# fail with 'not a directory'. This line is standalone on purpose.)
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
# Generated by setup-openclaw-triad.sh (v3.2)
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
    environment:
      OPENCLAW_STATE_DIR: ${CONTAINER_STATE_DIR}
      OPENCLAW_WORKSPACE_DIR: ${CONTAINER_STATE_DIR}/workspace-triad
      OPENCLAW_CONFIG_PATH: ${CONTAINER_STATE_DIR}/openclaw.json
      # read_only container: the runtime demands a REAL private temp dir
      # (uid-owned, 0700, trusted ancestors). /tmp is not writable here.
      TMPDIR: /home/openclaw/.tmp
      TMP: /home/openclaw/.tmp
    volumes:
      # Whole state dir: runtime needs tmp/, sqlite state, lease locks.
      # (The former per-file openclaw.json:ro overlay is GONE by design —
      #  a bind-type mismatch made boots fail with 'not a directory'.)
      - ${OPENCLAW_HOST_STATE_DIR}:${CONTAINER_STATE_DIR}
    tmpfs:
      # User-owned secure temp/cache (root-owned tmpfs tripped EACCES once).
      - /home/openclaw/.cache:uid=${APP_UID},gid=${APP_GID},mode=0700
      # Private temp root (2026-11-07: /tmp fallback denied on read_only fs).
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

    echo "   [ok] Docker trio written: Dockerfile + docker-compose.yml + docker.env (mem_limit=${CONTAINER_MEM_LIMIT}, .tmp tmpfs + TMPDIR, no json:ro mount, standalone image-side guard)"
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
  Preset    : ${PRESET} — limits: ${MAX_POS}% pos / ${MAX_DAILY}% daily / ${MAX_TRADES} trades
EOSUM
if [[ "$DOCKER_ENABLE" == "true" ]]; then
    echo "  1. Review ${ENV_FILE} (secrets, keys)"
    echo "  2. make docker-build && make docker-up"
else
    echo "  1. Review ${ENV_FILE} (secrets, keys)"
    echo "  2. run with --docker / DOCKER_ENABLE=true for the container stack"
fi
echo "  3. make logs — expect [gateway] ready and your roster names registering"
if [[ "$TELEGRAM_ON" == "true" ]]; then
    echo "  4. Telegram channel (once, after first successful boot):"
    echo "     make telegram    # or: docker exec -it openclaw-triad openclaw channels add telegram"
fi
cat << EOSUM2

  First contact:
    docker exec -it openclaw-triad openclaw agent \\
        --agent ${SCOUT} --message "Hello — introduce yourself in one sentence."
======================================================================
EOSUM2
