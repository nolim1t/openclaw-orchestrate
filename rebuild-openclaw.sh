#!/usr/bin/env bash
#
# rebuild-openclaw.sh (v1.3)
# One-command, from-scratch rebuild of the OpenClaw triad stack.
#
# CHANGELOG v1.3 — "nanogpt era" hardening
#   - mem_limit default raised 2g -> 3g (rss hit 1.6GiB under 2g cap with
#     16 workers; 3g gives headroom inside the 6GB colima VM).
#   - NEW SELF-HEALS on the generated openclaw.json (no longer trusting
#     the tag's generator for model wiring at all):
#       * Injects the full models.providers.nanogpt block (OpenAI-compat
#         router, /api/v1, env-interpolated key) when NANOGPT_API_KEY is
#         set and the block is absent.
#       * Strips double-prefixed catalog ids ("id: nanogpt/..." -> bare);
#         NanoGPT's API expects bare ids like anthropic/claude-sonnet-4-6.
#       * Prefixes model REFERENCES (primary/utilityModel/fallbacks) with
#         nanogpt/ when bare — openclaw's router expects provider-prefixed
#         refs. Idempotent: skips lines already prefixed.
#       * Forces sandbox mode "all" -> "off" (sandbox-in-container cannot
#         resolve bind sources; the container itself is the sandbox).
#       * Injects agents.defaults.systemAgent.agentId = <first roster
#         member> so the TUI lands on YOUR agent, not the clawdia slot.
#   - Inspection expanded 8 -> 12 points, incl. provider presence,
#     catalog-id hygiene, ref-prefix hygiene, sandbox-off, mem_limit.
#
# CHANGELOG v1.2
#   - Perimeter defence: BASE_IMAGE forced to node:24-slim across .env /
#     docker.env / compose / Dockerfile; python ghost self-healed.
# CHANGELOG v1.1
#   - Pinned-tag auto-fetch; mem_limit enforcement; roster contamination
#     inspection; doctor recovery hint.
# CHANGELOG v1.0
#   - Initial: backup -> teardown -> regenerate -> inspect -> build -> boot.
#
# USAGE:
#   ./rebuild-openclaw.sh              # standard rebuild (keeps colima VM)
#   ./rebuild-openclaw.sh --fresh-vm   # also delete + recreate the colima VM
#   ./rebuild-openclaw.sh --no-build   # tear down + generate + validate only
#   ./rebuild-openclaw.sh --yes        # skip the confirmation prompt
#
# FETCH BEHAVIOUR (env-tunable):
#   OPENCLAW_PINNED_TAG=20261106-1428   # GitHub tag to pull recipe from
#   OPENCLAW_FETCH_MODE=auto|always|never
#
set -euo pipefail

###############################################################################
# CONFIG
###############################################################################

ORCHESTRATE_DIR="${OPENCLAW_ORCHESTRATE_DIR:-${HOME}/openclaw-orchestrate}"
STATE_DIR="${OPENCLAW_STATE_DIR:-${HOME}/.openclaw}"
ENV_FILE="${STATE_DIR}/.env"
BACKUP_DIR="${HOME}"
SCRIPTS_DIR="${ORCHESTRATE_DIR}/scripts"
SETUP_SCRIPT="${SCRIPTS_DIR}/setup-openclaw-triad.sh"
MAKEFILE_PATH="${ORCHESTRATE_DIR}/Makefile"

# --- Pinned recipe fetching -------------------------------------------------
PINNED_TAG="${OPENCLAW_PINNED_TAG:-20261106-1428}"
FETCH_REPO_BASE="https://raw.githubusercontent.com/nolim1t/openclaw-orchestrate/refs/tags/${PINNED_TAG}"
FETCH_MODE="${OPENCLAW_FETCH_MODE:-auto}"   # auto | always | never

# --- Runtime guardrails ------------------------------------------------------
# The ONLY correct base image. Enforced regardless of tag defaults.
FORCED_BASE_IMAGE="node:24-slim"
# 3g: rss was 1.6GiB under the old 2g cap with 16 workers (memory-pressure
# warnings at 100.3% threshold ratio). 3g inside the 6GB VM is comfortable.
MEM_LIMIT_DESIRED="${OPENCLAW_MEM_LIMIT:-3g}"
DEFAULT_CONTAINER_STATE_DIR="/home/openclaw/.openclaw"

FRESH_VM=false
DO_BUILD=true
ASSUME_YES=false

# Stale overrides from the pre-Node era that must NEVER survive a rebuild.
STALE_PATTERNS='BASE_IMAGE=python'

# Default-roster names — contamination from an unconfigured AGENT_ROSTER.
DEFAULT_ROSTER_RE='clawdia|clawdio|arbiter'

###############################################################################
# HELPERS
###############################################################################

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
ok()   { printf '   [ok] %s\n' "$1"; }
warn() { printf '   [!!] %s\n' "$1"; }
die()  { printf '\n   [FAIL] %s\n\n' "$1" >&2; exit 1; }

confirm() {
    local answer
    printf '%s [y/N]: ' "$1"
    read -r answer
    [[ "$answer" == "y" || "$answer" == "Y" || "$answer" == "yes" ]] || die "Aborted by user"
}

usage() {
    cat << 'USAGEEOF'
Usage: ./rebuild-openclaw.sh [OPTIONS]

Options:
  --fresh-vm    Delete and recreate the colima VM (virgin Docker estate).
  --no-build    Tear down + regenerate + validate, but skip build/boot.
  --yes         Skip the confirmation prompt.
  --help        This message.

Environment:
  OPENCLAW_PINNED_TAG   GitHub tag for Makefile + generator (default 20261106-1428).
  OPENCLAW_FETCH_MODE   auto (default) | always | never
  OPENCLAW_MEM_LIMIT    Container mem_limit to enforce (default 3g).

Defence policy (v1.3):
  Beyond base-image forcing, the script now TAKES OVER model wiring:
  it injects/heals the models.providers.nanogpt block, keeps catalog ids
  bare, keeps model refs nanogpt/-prefixed, forces sandbox off, sets
  systemAgent to your first roster member, and enforces mem_limit 3g —
  regardless of what the pinned tag's generator emits. The inspection
  (12 points) then verifies all of it BEFORE the expensive build.

What gets DELETED (irrecoverably):
  - ~/.openclaw/ and running openclaw containers/images
  - with --fresh-vm: the entire colima VM

What gets PRESERVED:
  - ~/.openclaw/.env secrets (backed up first)
  - ~/openclaw-orchestrate/ local copies (overwritten by pinned tag on fetch)
USAGEEOF
    exit 0
}

fetch_pinned() {
    local remote="$1" dest="$2" kind="$3"
    local url="${FETCH_REPO_BASE}/${remote}"

    [[ "$FETCH_MODE" == "never" ]] && return 1
    command -v curl >/dev/null 2>&1 || { warn "curl not on PATH — cannot fetch"; return 1; }

    if ! curl -fsSL --connect-timeout 15 "$url" -o "${dest}.fetch" 2>/dev/null; then
        rm -f "${dest}.fetch"
        return 1
    fi
    [[ -s "${dest}.fetch" ]] || { rm -f "${dest}.fetch"; return 1; }

    case "$kind" in
        shell)
            bash -n "${dest}.fetch" 2>/dev/null \
                || { rm -f "${dest}.fetch"; warn "fetched script failed bash -n"; return 1; }
            ;;
        makefile)
            grep -q '^docker-build:' "${dest}.fetch" 2>/dev/null \
                || { rm -f "${dest}.fetch"; warn "fetched Makefile lacks docker-build target"; return 1; }
            ;;
    esac

    mv -f "${dest}.fetch" "$dest"
    [[ "$kind" == "shell" ]] && chmod +x "$dest"
    return 0
}

fetch_required() {
    local remote="$1" dest="$2" kind="$3" label="$4"
    if fetch_pinned "$remote" "$dest" "$kind"; then
        ok "${label}: pulled from pinned tag ${PINNED_TAG}"
    elif [[ "$FETCH_MODE" == "always" ]]; then
        die "${label}: fetch from tag ${PINNED_TAG} failed (FETCH_MODE=always)"
    elif [[ -f "$dest" ]]; then
        warn "${label}: fetch failed — using existing LOCAL copy (may be stale!)"
    else
        die "${label}: fetch failed and no local copy exists at ${dest}"
    fi
}

enforce_base_image() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    if grep -E '^BASE_IMAGE=' "$file" >/dev/null 2>&1; then
        sed -i '' -E 's/^BASE_IMAGE=.*/BASE_IMAGE='"${FORCED_BASE_IMAGE}"'/' "$file"
    else
        echo "BASE_IMAGE=${FORCED_BASE_IMAGE}" >> "$file"
    fi
    if [[ "$(grep -c '^BASE_IMAGE=' "$file")" -gt 1 ]]; then
        local tmp_lines
        tmp_lines="$(grep -v '^BASE_IMAGE=' "$file")"
        { printf '%s\n' "$tmp_lines"; echo "BASE_IMAGE=${FORCED_BASE_IMAGE}"; } > "$file"
        warn "collapsed duplicate BASE_IMAGE lines in $(basename "$file")"
    fi
    return 0
}

# inject_nanogpt_provider <openclaw.json>
# Idempotent: skipped if a providers block already exists in the config.
inject_nanogpt_provider() {
    local cfg="$1"
    grep -q 'providers: {' "$cfg" && return 1   # already present

    # NOTE: the apiKey line stays LITERAL ${NANOGPT_API_KEY} text —
    # openclaw interpolates env vars into config at runtime. Quoted heredoc
    # guarantees the shell does not expand it here.
    local block
    block=$(cat << 'BLKEOF'
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
BLKEOF
)
    # Insert after line 1 (the header comment). JSON5 is order-free, so a
    # top-level key can be prepended safely as long as a comma follows.
    { head -n 1 "$cfg"; printf '%s\n' "$block"; tail -n +2 "$cfg"; } > "${cfg}.new" \
        && mv "${cfg}.new" "$cfg"
    grep -q 'providers: {' "$cfg"
}

# heal_model_refs <openclaw.json>
# 1) Strip double-prefixed catalog ids ("id: "nanogpt/..." -> bare).
#    NanoGPT's API receives the bare id; provider refs carry the prefix.
# 2) Prefix bare model REFERENCES (primary/utilityModel/fallbacks).
#    Both transforms are naturally idempotent.
heal_model_refs() {
    local cfg="$1" healed=0

    if grep -q 'id: "nanogpt/' "$cfg"; then
        sed -i '' 's/id: "nanogpt\//id: "/g' "$cfg"
        healed=$((healed + 1))
    fi

    local pat
    for pat in 'primary: "anthropic/' 'primary: "openai/' \
               'utilityModel: "anthropic/' 'utilityModel: "openai/' \
               'fallbacks: ["anthropic/' 'fallbacks: ["openai/'; do
        # construct replacement: insert nanogpt/ after the opening quote
        if grep -qF "${pat}" "$cfg"; then
            local repl
            repl="$(printf '%s' "$pat" | sed 's|\(["[]\)|\1nanogpt/|')"
            # shellcheck disable=SCSC2086
            sed -i '' "s|${pat}|${repl}|g" "$cfg"
            healed=$((healed + 1))
        fi
    done
    return "$healed"
}

# heal_sandbox_off <openclaw.json>
# Containerized Gateways cannot resolve sandbox bind sources (no docker
# sock); the container's own lockdown IS the sandbox.
heal_sandbox_off() {
    local cfg="$1"
    if grep -q 'sandbox: { mode: "all"' "$cfg"; then
        sed -i '' 's/sandbox: { mode: "all", scope: "agent", workspaceAccess: "none" }/sandbox: { mode: "off" }/' "$cfg"
        # fallback for whitespace/format variants: only on sandbox lines
        sed -i '' '/sandbox/s/mode: "all"/mode: "off"/g' "$cfg"
        return 0
    fi
    return 1
}

# inject_system_agent <openclaw.json> <first-roster-name>
# Makes the TUI / un-scoped CLI land on YOUR first agent, not the built-in
# clawdia slot. Idempotent.
inject_system_agent() {
    local cfg="$1" first="$2"
    grep -q 'systemAgent' "$cfg" && return 1

    awk -v agent="$first" '
        {
            if (!done && $0 ~ /defaults: *\{/ && (ctx || $0 ~ /agents: *\{/)) {
                line = $0
                match(line, /^ */)
                sp = substr(line, RSTART, RLENGTH)
                print line
                printf "%ssystemAgent: { agentId: \"%s\" },\n", sp, agent
                done = 1
                next
            }
            if ($0 ~ /agents: *\{/) ctx = 1
            print
        }
    ' "$cfg" > "${cfg}.new" && mv "${cfg}.new" "$cfg"

    grep -q 'systemAgent' "$cfg"
}

###############################################################################
# ARGUMENTS
###############################################################################

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fresh-vm) FRESH_VM=true; shift ;;
        --no-build) DO_BUILD=false; shift ;;
        --yes|-y)   ASSUME_YES=true; shift ;;
        --help|-h)  usage ;;
        *) die "Unknown option: $1 (try --help)" ;;
    esac
done

###############################################################################
# PHASE 0 — PREFLIGHT + PINNED-RECIPE FETCH
###############################################################################

step "Preflight: fetching pinned recipe (tag ${PINNED_TAG})"

[[ -d "$ORCHESTRATE_DIR" ]] || mkdir -p "$ORCHESTRATE_DIR"
[[ -d "$SCRIPTS_DIR" ]]     || mkdir -p "$SCRIPTS_DIR"

fetch_required "Makefile"                        "$MAKEFILE_PATH" "makefile" "Makefile"
fetch_required "scripts/setup-openclaw-triad.sh" "$SETUP_SCRIPT"  "shell"   "Generator script"

bash -n "$SETUP_SCRIPT" || die "Setup script fails syntax check — fetch produced garbage or local copy is broken."
GEN_VERSION="$(grep -o 'v2\.[0-9]*' "$SETUP_SCRIPT" | head -1)"
ok "Generator syntax OK (version marker: ${GEN_VERSION:-unknown})"

if grep -q 'set -a && . ' "$MAKEFILE_PATH"; then
    ok "Makefile is .env-aware (v2)"
else
    die "Makefile does NOT source .env (old v1) — roster/preset would be dropped."
fi

command -v docker >/dev/null 2>&1 || die "docker CLI not found on PATH"
command -v colima >/dev/null 2>&1 || warn "colima CLI not found (skipping VM management)"

step "Confirm the destruction"
printf '  Recipe source:        %s (mode: %s)\n' "tag ${PINNED_TAG}" "$FETCH_MODE"
printf '  State dir to delete:   %s\n' "$STATE_DIR"
printf '  Colima VM wiped too:   %s\n' "$FRESH_VM"
printf '  Secrets backed up to:  %s\n' "${BACKUP_DIR}/openclaw-env-backup-<date>"
printf '  Forced base image:     %s (tag defaults NOT trusted)\n' "$FORCED_BASE_IMAGE"
printf '  Mem limit enforced:    %s\n' "$MEM_LIMIT_DESIRED"
printf '  Model wiring:          nanogpt provider + ref hygiene (self-healed)\n'
echo
[[ "$ASSUME_YES" == "true" ]] || confirm "Proceed with complete rebuild?"

###############################################################################
# PHASE 1 — SECRETS BACKUP
###############################################################################

step "Backing up secrets"

BACKUP_FILE="${BACKUP_DIR}/openclaw-env-backup-$(date +%Y-%m-%d)"

if [[ -f "$ENV_FILE" ]]; then
    cp "$ENV_FILE" "$BACKUP_FILE"
    chmod 600 "$BACKUP_FILE"
    ok "Secrets saved to ${BACKUP_FILE} ($(wc -c < "$BACKUP_FILE" | tr -d ' ') bytes)"
else
    warn "No existing .env found — you will need to fill in keys after generation"
    BACKUP_FILE=""
fi

###############################################################################
# PHASE 2 — STOP EVERYTHING
###############################################################################

step "Stopping containers"

if [[ -f "${STATE_DIR}/docker-compose.yml" ]]; then
    ( cd "$STATE_DIR" && docker compose --env-file docker.env down ) \
        && ok "Containers stopped" \
        || warn "Compose down failed (continuing — will be deleted anyway)"
else
    ok "No compose file (nothing to stop)"
fi

docker rm -f openclaw-triad >/dev/null 2>&1 || true
docker rmi openclaw-triad:local >/dev/null 2>&1 || true

if [[ "$FRESH_VM" == "true" ]] && command -v colima >/dev/null 2>&1; then
    step "Recreating colima VM (virgin Docker estate)"
    colima stop >/dev/null 2>&1 || true
    colima delete --force || warn "colima delete failed — continuing"
    colima start --cpu 4 --memory 6 || die "colima start failed"
    ok "Fresh VM running (4 CPU / 6GB — headroom for the Node runtime at 3g limit)"
else
    ok "Keeping existing colima VM (use --fresh-vm to nuke it too)"
fi

docker info >/dev/null 2>&1 || die "Docker daemon not reachable — is colima running? (colima start)"
ok "Docker daemon responsive"

###############################################################################
# PHASE 3 — FLATTEN THE STATE DIR
###############################################################################

step "Removing state directory: ${STATE_DIR}"

if [[ -d "$STATE_DIR" ]]; then
    rm -rf "$STATE_DIR"
    ok "State directory deleted (all agent DBs, leases, and journals gone)"
else
    ok "No state directory existed"
fi

###############################################################################
# PHASE 4 — RESTORE SECRETS, SCRUB, THEN FORCE CRITICAL VALUES
###############################################################################

step "Restoring secrets, scrubbing stale overrides, forcing critical values"

mkdir -p "$STATE_DIR"

if [[ -n "$BACKUP_FILE" && -f "$BACKUP_FILE" ]]; then
    cp "$BACKUP_FILE" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    ok "Secrets restored to ${ENV_FILE}"
else
    touch "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    warn "Empty .env created — fill in NANOGPT_API_KEY after generation"
fi

# 4a. Scrub ALL BASE_IMAGE lines (stale or not) …
if grep -E '^BASE_IMAGE=' "$ENV_FILE" >/dev/null 2>&1; then
    sed -i '' '/^BASE_IMAGE=/d' "$ENV_FILE"
    ok "Scrubbed existing BASE_IMAGE lines from .env"
fi

# 4b. …then FORCE the correct value back in (never leave a vacuum for
#     tag defaults to refill with python).
enforce_base_image "$ENV_FILE"
ok "BASE_IMAGE forced to ${FORCED_BASE_IMAGE} in .env"

# 4c. Token / roster defaults, same philosophy: force, don't trust.
if ! grep -E '^OPENCLAW_GATEWAY_TOKEN=..+' "$ENV_FILE" >/dev/null 2>&1; then
    echo "OPENCLAW_GATEWAY_TOKEN=$(openssl rand -hex 32)" >> "$ENV_FILE"
    ok "Generated fresh OPENCLAW_GATEWAY_TOKEN"
else
    ok "OPENCLAW_GATEWAY_TOKEN present"
fi

if ! grep -E '^AGENT_ROSTER=..+' "$ENV_FILE" >/dev/null 2>&1; then
    echo "AGENT_ROSTER=seer,guardian,sage" >> "$ENV_FILE"
    warn "AGENT_ROSTER was empty — defaulted to seer,guardian,sage"
else
    ok "AGENT_ROSTER present: $(grep -E '^AGENT_ROSTER=' "$ENV_FILE" | cut -d= -f2)"
fi
ROSTER_CHECK="$(grep -E '^AGENT_ROSTER=' "$ENV_FILE" | cut -d= -f2)"
ROSTER_FIRST="$(echo "$ROSTER_CHECK" | cut -d, -f1 | tr -d ' ')"

if ! grep -E '^PERSONALITY_PRESET=..+' "$ENV_FILE" >/dev/null 2>&1; then
    echo "PERSONALITY_PRESET=mystic" >> "$ENV_FILE"
    ok "PERSONALITY_PRESET defaulted to mystic"
fi

# Does the nanogpt era apply to this build?
NANOGPT_ERA=false
if grep -E '^NANOGPT_API_KEY=..+' "$ENV_FILE" >/dev/null 2>&1; then
    NANOGPT_ERA=true
    ok "NANOGPT_API_KEY present — model-wiring heals will apply"
else
    warn "NANOGPT_API_KEY missing/empty — model checks skipped; fill key after generation"
fi

###############################################################################
# PHASE 5 — GENERATE THE STACK
###############################################################################

step "Generating stack via make setup"

( cd "$ORCHESTRATE_DIR" && make setup ) || die "make setup failed — inspect output above"
ok "Generation complete"

###############################################################################
# PHASE 5.5 — SELF-HEAL GENERATED FILES (do NOT trust tag defaults)
###############################################################################

step "Self-healing generated files against tag defaults"

HEALED=0
CFG_FILE="${STATE_DIR}/openclaw.json"

# 5.5.1 docker.env: the file compose ACTUALLY interpolates from.
DOCKER_ENV_FILE="${STATE_DIR}/docker.env"
if [[ -f "$DOCKER_ENV_FILE" ]]; then
    if grep -E '^BASE_IMAGE=' "$DOCKER_ENV_FILE" >/dev/null 2>&1; then
        CUR_BASE="$(grep -m1 '^BASE_IMAGE=' "$DOCKER_ENV_FILE" | cut -d= -f2)"
        if [[ "$CUR_BASE" != "$FORCED_BASE_IMAGE" ]]; then
            enforce_base_image "$DOCKER_ENV_FILE"
            warn "docker.env healed: BASE_IMAGE ${CUR_BASE} -> ${FORCED_BASE_IMAGE}"
            HEALED=$((HEALED + 1))
        else
            ok "docker.env BASE_IMAGE already ${FORCED_BASE_IMAGE}"
        fi
    else
        enforce_base_image "$DOCKER_ENV_FILE"
        warn "docker.env had no BASE_IMAGE — pinned ${FORCED_BASE_IMAGE} defensively"
        HEALED=$((HEALED + 1))
    fi
else
    warn "docker.env not found after generation — generator layout changed?"
fi

# 5.5.2 compose / Dockerfile python ghosts
COMPOSE_FILE="${STATE_DIR}/docker-compose.yml"
if [[ -f "$COMPOSE_FILE" ]] && grep -q 'python:3.11-slim' "$COMPOSE_FILE"; then
    sed -i '' 's/python:3.11-slim/node:24-slim/g' "$COMPOSE_FILE"
    warn "docker-compose.yml healed: replaced hardcoded python base"
    HEALED=$((HEALED + 1))
fi
if grep -q 'python:3.11-slim' "${STATE_DIR}/Dockerfile" 2>/dev/null; then
    sed -i '' 's/python:3.11-slim/node:24-slim/g' "${STATE_DIR}/Dockerfile"
    warn "Dockerfile healed: replaced hardcoded python base"
    HEALED=$((HEALED + 1))
fi

# 5.5.3 mem_limit (exit 137 = OOM; also 1.6GiB rss under 2g cap).
if [[ -f "$COMPOSE_FILE" ]] && grep -q 'mem_limit:' "$COMPOSE_FILE"; then
    CUR_MEM="$(grep -m1 'mem_limit:' "$COMPOSE_FILE" | awk '{print $2}')"
    if [[ "$CUR_MEM" != "$MEM_LIMIT_DESIRED" ]]; then
        sed -i '' "s/mem_limit:.*/mem_limit: ${MEM_LIMIT_DESIRED}/" "$COMPOSE_FILE"
        warn "mem_limit healed: ${CUR_MEM} -> ${MEM_LIMIT_DESIRED}"
        HEALED=$((HEALED + 1))
    else
        ok "mem_limit already ${MEM_LIMIT_DESIRED}"
    fi
fi

# 5.5.4 sandbox off (containerized Gateway cannot resolve sandbox binds)
if [[ -f "$CFG_FILE" ]]; then
    if heal_sandbox_off "$CFG_FILE"; then
        warn "openclaw.json healed: sandbox mode all -> off (container IS the sandbox)"
        HEALED=$((HEALED + 1))
    else
        ok "sandbox already off (or absent) in openclaw.json"
    fi
else
    die "openclaw.json not found after generation — generator output layout changed"
fi

# 5.5.5 nanogpt model wiring (only in the nanogpt era)
if [[ "$NANOGPT_ERA" == "true" ]]; then
    if inject_nanogpt_provider "$CFG_FILE"; then
        warn "openclaw.json healed: injected models.providers.nanogpt block"
        HEALED=$((HEALED + 1))
    else
        ok "nanogpt provider already present in openclaw.json"
    fi

    REF_HEALS="$(heal_model_refs "$CFG_FILE" || true)"
    if [[ "${REF_HEALS:-0}" -gt 0 ]]; then
        warn "openclaw.json healed: ${REF_HEALS} model-ref/catalog-id repair(s) applied"
        HEALED=$((HEALED + REF_HEALS))
    else
        ok "model refs already correctly prefixed; catalog ids already bare"
    fi
else
    ok "Skipping model-wiring heals (no NANOGPT_API_KEY)"
fi

# 5.5.6 systemAgent: make the TUI land on YOUR first agent
if [[ -n "$ROSTER_FIRST" ]]; then
    if inject_system_agent "$CFG_FILE" "$ROSTER_FIRST"; then
        warn "openclaw.json healed: systemAgent -> ${ROSTER_FIRST} (TUI default slot)"
        HEALED=$((HEALED + 1))
    else
        ok "systemAgent already configured"
    fi
fi

if [[ "$HEALED" -gt 0 ]]; then
    ok "Self-heal complete: ${HEALED} repair(s) applied — generated files now override tag defaults"
else
    ok "No healing needed — generated files already correct"
fi

###############################################################################
# PHASE 6 — TWELVE-POINT INSPECTION (fail-fast BEFORE the expensive build)
###############################################################################

step "Twelve-point inspection of (healed) generated files"

fail_count=0
inspect() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        ok "${desc}"
    else
        warn "${desc} — CHECK FAILED"
        fail_count=$((fail_count + 1))
    fi
}
# Like inspect(), but PASSES when the command finds nothing.
inspect_absent() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        warn "${desc} — CHECK FAILED"
        fail_count=$((fail_count + 1))
    else
        ok "${desc}"
    fi
}

# 1. getent guard present in Dockerfile (macOS GID 20 fix)
inspect "1. Dockerfile has getent group guard" \
    grep -q 'getent group' "${STATE_DIR}/Dockerfile"

# 2. Node base in the Dockerfile
if grep -qE '(FROM node:24-slim)|(ARG BASE_IMAGE=node:24-slim)' "${STATE_DIR}/Dockerfile"; then
    ok "2. Dockerfile resolves to node base image"
else
    warn "2. Dockerfile base is NOT node:24-slim — CHECK FAILED"
    fail_count=$((fail_count + 1))
fi

# 3. No python ANYWHERE in the build chain
PY_GHOST=0
for f in Dockerfile docker.env docker-compose.yml; do
    if [[ -f "${STATE_DIR}/${f}" ]] && grep -q 'python:3.11-slim' "${STATE_DIR}/${f}"; then
        warn "3. python base image found in ${f} — CHECK FAILED"
        PY_GHOST=$((PY_GHOST + 1))
    fi
done
if [[ "$PY_GHOST" -eq 0 ]]; then
    ok "3. No python base ghost in Dockerfile/docker.env/compose"
else
    fail_count=$((fail_count + 1))
fi

# 4. docker.env positively carries the forced node base
inspect "4. docker.env carries BASE_IMAGE=${FORCED_BASE_IMAGE}" \
    grep -q "^BASE_IMAGE=${FORCED_BASE_IMAGE}\$" "$DOCKER_ENV_FILE"

# 5. gateway.mode (schema requirement)
inspect "5. openclaw.json has gateway.mode" \
    grep -q 'gateway: { mode: "local" }' "$CFG_FILE"

# 6. Correct entrypoint
inspect "6. Dockerfile CMD is openclaw gateway" \
    grep -q 'CMD \["openclaw", "gateway"\]' "${STATE_DIR}/Dockerfile"

# 7. Roster members present; NO default-roster contamination
ok "7. Roster from .env: ${ROSTER_CHECK}"
IFS=',' read -ra CHECK_NAMES <<< "$ROSTER_CHECK"
for name in "${CHECK_NAMES[@]}"; do
    inspect "   - agent '${name}' present in openclaw.json" \
        grep -q "${name}" "$CFG_FILE"
done
if grep -Eq "${DEFAULT_ROSTER_RE}" "$CFG_FILE"; then
    warn "   DEFAULT-ROSTER NAMES in openclaw.json — AGENT_ROSTER not applied!"
    fail_count=$((fail_count + 1))
else
    ok "   No default-roster contamination in config"
fi

# 8. agents/ contains ONLY roster members
if [[ -d "${STATE_DIR}/agents" ]]; then
    orphan_found=false
    for d in "${STATE_DIR}/agents"/*/; do
        [[ -d "$d" ]] || continue
        n="$(basename "$d")"
        if ! echo ",${ROSTER_CHECK}," | grep -q ",${n},"; then
            warn "8. agents/ contains non-roster entry: ${n} (orphan DB)"
            orphan_found=true
        fi
    done
    if [[ "$orphan_found" == "true" ]]; then
        fail_count=$((fail_count + 1))
    else
        ok "8. agents/ contains only roster members"
    fi
else
    ok "8. No agents/ dir yet (DBs created at first boot — clean slate)"
fi

# 9-11. Nanogpt-era checks (conditional)
if [[ "$NANOGPT_ERA" == "true" ]]; then
    # 9. provider block present with the required baseUrl suffix
    inspect "9. models.providers.nanogpt present (baseUrl /api/v1)" \
        grep -q 'baseUrl: "https://nano-gpt.com/api/v1"' "$CFG_FILE"

    # 10. catalog ids must be BARE (no nanogpt/ prefix inside provider list)
    inspect_absent "10. catalog ids bare (no id: \"nanogpt/...) in provider list" \
        grep -q 'id: "nanogpt/' "$CFG_FILE"

    # 11. references must be nanogpt/-prefixed
    if grep -q '"nanogpt/' "$CFG_FILE" \
       && ! grep -Eq '(primary|utilityModel): "(anthropic|openai)/' "$CFG_FILE" \
       && ! grep -q 'fallbacks: \["(anthropic|openai)/' "$CFG_FILE"; then
        ok "11. model refs are nanogpt/-prefixed"
    else
        warn "11. Model refs not fully nanogpt/-prefixed — CHECK FAILED"
        fail_count=$((fail_count + 1))
    fi
else
    ok "9-11. Skipped (nanogpt era off — no NANOGPT_API_KEY)"
fi

# 12. sandbox off + mem_limit enforced (+ systemAgent, soft)
inspect_absent "12. sandbox mode 'all' absent from config" \
    grep -q 'mode: "all"' "$CFG_FILE"
inspect "    sandbox mode 'off' present" \
    grep -q 'sandbox: { mode: "off" }' "$CFG_FILE"
inspect "    mem_limit is ${MEM_LIMIT_DESIRED}" \
    grep -q "mem_limit: ${MEM_LIMIT_DESIRED}" "$COMPOSE_FILE"
if grep -q "systemAgent" "$CFG_FILE"; then
    ok "    systemAgent set (TUI lands on ${ROSTER_FIRST})"
else
    # Soft: schema variance across openclaw versions — warn, don't block
    warn "    systemAgent not set — TUI may land on the clawdia default slot"
fi

if [[ "$fail_count" -gt 0 ]]; then
    die "${fail_count} inspection check(s) failed — NOT building.
    Even after self-heal, something is wrong upstream (generator or tag).
    Fix, then re-run. No build time wasted."
fi

ok "All inspection checks passed"

###############################################################################
# PHASE 7 — BUILD
###############################################################################

if [[ "$DO_BUILD" != "true" ]]; then
    step "Skipping build (--no-build)"
    cat << EOF

======================================================
  REBUILD COMPLETE (generation only)
======================================================
  State dir:   ${STATE_DIR}
  Recipe tag:  ${PINNED_TAG}
  Next steps:
    1. nano ${ENV_FILE}          # review remaining keys
    2. cd ${ORCHESTRATE_DIR}
    3. make docker-build && make docker-up && make logs
======================================================
EOF
    exit 0
fi

step "Building Docker image (the long step: apt + npm layers)"

( cd "$ORCHESTRATE_DIR" && make docker-build ) \
    || die "docker build failed — paste the failing step output"

ok "Image built"

###############################################################################
# PHASE 8 — BOOT AND WATCH
###############################################################################

step "Starting the Gateway"

( cd "$ORCHESTRATE_DIR" && make docker-up ) || die "docker up failed"

ok "Container started — capturing first logs"

sleep 15

step "Gateway logs (first look)"
docker logs openclaw-triad --tail 60 2>&1 || true

CSTATE="$DEFAULT_CONTAINER_STATE_DIR"
if [[ -f "$DOCKER_ENV_FILE" ]]; then
    DETECTED="$(grep -E '^CONTAINER_STATE_DIR=' "$DOCKER_ENV_FILE" | cut -d= -f2)"
    [[ -n "$DETECTED" ]] && CSTATE="$DETECTED"
fi

cat << EOF

======================================================
  REBUILD COMPLETE
======================================================
  State dir:   ${STATE_DIR}
  Recipe tag:  ${PINNED_TAG}
  Backup:      ${BACKUP_FILE:-none}
  Base image:  ${FORCED_BASE_IMAGE} (forced)
  Mem limit:   ${MEM_LIMIT_DESIRED} (enforced)
  Roster:      ${ROSTER_CHECK} (systemAgent: ${ROSTER_FIRST})
  Fresh VM:    ${FRESH_VM}

  Watch it live:      make logs
  Stop everything:    make docker-down
======================================================

First contact (after your NanoGPT balance is topped up):

  docker exec -it openclaw-triad openclaw agent \\
      --agent ${ROSTER_FIRST} --message "Hello — introduce yourself in one sentence."

IF the logs show an agent-database integrity gate:

  cd ${STATE_DIR}
  docker compose --env-file docker.env down
  docker run --rm -it \\
    -v "${STATE_DIR}:${CSTATE}" \\
    --entrypoint openclaw openclaw-triad:local doctor --fix
  cd ${ORCHESTRATE_DIR} && make docker-up

Confirmation the triad is alive:
  [gateway] ready
  no 'exit 137', no 'restart-loop breaker', no admission errors
  model-transport lines WITHOUT 'nanogpt/nanogpt/' double prefixes

Paste the last 40 log lines back to Lumo either way.
EOF
