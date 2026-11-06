#!/usr/bin/env bash
#
# rebuild-openclaw.sh (v1.1)
# One-command, from-scratch rebuild of the OpenClaw triad stack.
#
# CHANGELOG v1.1
#   - Auto-fetches the PINNED TAG release of the generator (Makefile +
#     setup-openclaw-triad.sh) from GitHub raw, with runtime validation
#     (curl + syntax check) and graceful fallback to existing local copies.
#   - mem_limit auto-bump: exit 137 (SIGKILL/OOM) in crash loops traced to
#     undersized container memory; script now enforces mem_limit: 2g.
#   - Anti-contamination inspection: refuses to build if default-roster
#     names (clawdia/clawdio/arbiter) appear in config, or if agents/
#     contains DBs that aren't members of AGENT_ROSTER.
#   - Prints an "openclaw doctor --fix" recovery command (with the
#     detected container state path) if the DB integrity gate appears.
#
# CHANGELOG v1.0
#   - Initial: backup secrets → teardown → regenerate → five-point
#     inspection → build → boot → tail logs. Scrubs stale BASE_IMAGE
#     overrides. Bash 3.2 safe.
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
#        auto   = try fetch, fall back to local copy on failure (default)
#        always = fetch required — die if the tag is unreachable
#        never  = never touch the network; local files only
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
MEM_LIMIT_DESIRED="${OPENCLAW_MEM_LIMIT:-2g}"
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

Fetch behaviour (environment variables):
  OPENCLAW_PINNED_TAG   GitHub tag to pull the Makefile + generator from
                        (default: 20261106-1428).
  OPENCLAW_FETCH_MODE   auto   = fetch, fall back to local copy (default)
                        always= fetch required, die if unreachable
                        never  = local files only, no network

Memory:
  OPENCLAW_MEM_LIMIT    Container mem_limit to enforce (default: 2g).
                        Exit 137 crash loops were traced to OOM kills.

What gets DELETED (irrecoverably):
  - ~/.openclaw/ (all generated config, workspaces, runtime DBs, journals)
  - running openclaw containers + the openclaw-triad image
  - with --fresh-vm: the entire colima VM (all images, volumes, caches)

What gets PRESERVED:
  - ~/.openclaw/.env secrets (backed up to ~/openclaw-env-backup-<date> first)
  - ~/openclaw-orchestrate/ local copies are overwritten by the pinned tag
    when fetching succeeds (that's the point).
USAGEEOF
    exit 0
}

# fetch_pinned <remote-path> <dest> <kind:shell|makefile>
# Downloads a pinned-tag file, validates it, installs it atomically.
# Returns 0 on success, 1 on failure (caller decides severity by FETCH_MODE).
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

# fetch_required <remote-path> <dest> <kind> <label>
# Wraps fetch_pinned with FETCH_MODE semantics: dies if 'always'.
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

fetch_required "Makefile"                     "$MAKEFILE_PATH" "makefile" "Makefile"
fetch_required "scripts/setup-openclaw-triad.sh" "$SETUP_SCRIPT" "shell"  "Generator script"

# Deep validation of what we now have (fetched or local)
bash -n "$SETUP_SCRIPT" || die "Setup script fails syntax check — fetch produced garbage or local copy is broken."
GEN_VERSION="$(grep -o 'v2\.[0-9]*' "$SETUP_SCRIPT" | head -1)"
ok "Generator syntax OK (version marker: ${GEN_VERSION:-unknown})"

if grep -q 'set -a && . ' "$MAKEFILE_PATH"; then
    ok "Makefile is .env-aware (v2)"
else
    die "Makefile does NOT source .env (old v1) — roster/preset would be dropped.
    Fetched tag broken? Check ${MAKEFILE_PATH}."
fi

command -v docker >/dev/null 2>&1 || die "docker CLI not found on PATH"
command -v colima >/dev/null 2>&1 || warn "colima CLI not found (skipping VM management)"

step "Confirm the destruction"
printf '  Recipe source:        %s (mode: %s)\n' "tag ${PINNED_TAG}" "$FETCH_MODE"
printf '  State dir to delete:   %s\n' "$STATE_DIR"
printf '  Colima VM wiped too:   %s\n' "$FRESH_VM"
printf '  Secrets backed up to:  %s\n' "${BACKUP_DIR}/openclaw-env-backup-<date>"
printf '  Mem limit enforced:    %s\n' "$MEM_LIMIT_DESIRED"
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
    ok "Fresh VM running (4 CPU / 6GB — headroom for the Node runtime)"
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
# PHASE 4 — RESTORE SECRETS, SCRUB STALE OVERRIDES
###############################################################################

step "Restoring secrets and scrubbing stale overrides"

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

# Scrub the pre-Node ghost that silently defeats the node:24-slim base.
if grep -E "^${STALE_PATTERNS}" "$ENV_FILE" >/dev/null 2>&1; then
    sed -i '' -E "/^${STALE_PATTERNS}/d" "$ENV_FILE"
    warn "Removed stale BASE_IMAGE override (python base) from .env"
else
    ok "No stale BASE_IMAGE overrides in .env"
fi

for key in NANOGPT_API_KEY OPENCLAW_GATEWAY_TOKEN AGENT_ROSTER; do
    if grep -E "^${key}=..+" "$ENV_FILE" >/dev/null 2>&1; then
        ok "${key} present"
    else
        warn "${key} missing/empty"
    fi
done

if ! grep -E "^OPENCLAW_GATEWAY_TOKEN=..+" "$ENV_FILE" >/dev/null 2>&1; then
    echo "OPENCLAW_GATEWAY_TOKEN=$(openssl rand -hex 32)" >> "$ENV_FILE"
    ok "Generated fresh OPENCLAW_GATEWAY_TOKEN"
fi

if ! grep -E "^AGENT_ROSTER=..+" "$ENV_FILE" >/dev/null 2>&1; then
    echo "AGENT_ROSTER=seer,guardian,sage" >> "$ENV_FILE"
    warn "AGENT_ROSTER was empty — defaulted to seer,guardian,sage (old runs defaulted to clawdia-era names)"
fi
if ! grep -E "^PERSONALITY_PRESET=..+" "$ENV_FILE" >/dev/null 2>&1; then
    echo "PERSONALITY_PRESET=mystic" >> "$ENV_FILE"
    ok "PERSONALITY_PRESET defaulted to mystic"
fi

###############################################################################
# PHASE 5 — GENERATE THE STACK
###############################################################################

step "Generating stack via make setup"

( cd "$ORCHESTRATE_DIR" && make setup ) || die "make setup failed — inspect output above"
ok "Generation complete"

###############################################################################
# PHASE 6 — SEVEN-POINT INSPECTION (fail-fast BEFORE the expensive build)
###############################################################################

step "Seven-point inspection of generated files"

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

# 1. getent guard present in Dockerfile (macOS GID 20 fix)
inspect "1. Dockerfile has getent group guard" \
    grep -q 'getent group' "${STATE_DIR}/Dockerfile"

# 2. Node base image (not python)
inspect "2. Dockerfile uses node base image" \
    grep -q 'node:24-slim' "${STATE_DIR}/Dockerfile"

# 3. gateway.mode in config (schema requirement)
inspect "3. openclaw.json has gateway.mode" \
    grep -q 'gateway: { mode: "local" }' "${STATE_DIR}/openclaw.json"

# 4. Correct entrypoint
inspect "4. Dockerfile CMD is openclaw gateway" \
    grep -q 'CMD \["openclaw", "gateway"\]' "${STATE_DIR}/Dockerfile"

# 5. Roster: every .env roster member must appear in config
ROSTER_CHECK="$(grep -E '^AGENT_ROSTER=' "$ENV_FILE" | cut -d= -f2)"
ok "5. Roster from .env: ${ROSTER_CHECK}"
IFS=',' read -ra CHECK_NAMES <<< "$ROSTER_CHECK"
for name in "${CHECK_NAMES[@]}"; do
    inspect "   - agent '${name}' present in openclaw.json" \
        grep -q "${name}" "${STATE_DIR}/openclaw.json"
done

# 6. NO default-roster contamination (the clawdia-DB admission errors)
if grep -Eq "${DEFAULT_ROSTER_RE}" "${STATE_DIR}/openclaw.json"; then
    warn "6. DEFAULT-ROSTER NAMES FOUND in openclaw.json — AGENT_ROSTER not applied!"
    warn "   Delete the container's stale DBs: they alias-check against the wrong paths."
    fail_count=$((fail_count + 1))
else
    ok "6. No default-roster contamination in config"
fi

# 7. agents/ dir contains ONLY roster members (no orphan DBs to trip the
#    admission alias check or the stale-lease integrity gate)
if [[ -d "${STATE_DIR}/agents" ]]; then
    orphan_found=false
    for d in "${STATE_DIR}/agents"/*/; do
        [[ -d "$d" ]] || continue
        n="$(basename "$d")"
        if ! echo ",${ROSTER_CHECK}," | grep -q ",${n},"; then
            warn "7. agents/ contains non-roster entry: ${n} (orphan DB)"
            orphan_found=true
        fi
    done
    if [[ "$orphan_found" == "true" ]]; then
        fail_count=$((fail_count + 1))
    else
        ok "7. agents/ contains only roster members"
    fi
else
    ok "7. No agents/ dir yet (DBs created at first boot — clean slate)"
fi

# Bonus: docker.env must carry the node base
if [[ -f "${STATE_DIR}/docker.env" ]]; then
    if grep -Eq '(BASE_IMAGE=node)|(^$)' "${STATE_DIR}/docker.env" >/dev/null 2>&1; then
        ok "Bonus: docker.env not carrying a python BASE_IMAGE"
    fi
    if grep -q 'BASE_IMAGE=python' "${STATE_DIR}/docker.env" 2>/dev/null; then
        warn "Bonus: docker.env has python BASE_IMAGE — FIXING"
        sed -i '' '/BASE_IMAGE=python/d' "${STATE_DIR}/docker.env"
    fi
fi

if [[ "$fail_count" -gt 0 ]]; then
    die "${fail_count} inspection check(s) failed — NOT building.
    Fix the generator or .env, then re-run. No build time wasted."
fi

ok "All inspection checks passed"

###############################################################################
# PHASE 6.5 — MEMORY LIMIT GUARD (exit 137 = OOM prevention)
###############################################################################

step "Memory limit guard (target: ${MEM_LIMIT_DESIRED})"

COMPOSE_FILE="${STATE_DIR}/docker-compose.yml"
if [[ -f "$COMPOSE_FILE" ]] && grep -q 'mem_limit:' "$COMPOSE_FILE"; then
    CUR_MEM="$(grep -m1 'mem_limit:' "$COMPOSE_FILE" | awk '{print $2}')"
    if [[ "$CUR_MEM" != "$MEM_LIMIT_DESIRED" ]]; then
        sed -i '' "s/mem_limit:.*/mem_limit: ${MEM_LIMIT_DESIRED}/" "$COMPOSE_FILE"
        ok "Bumped mem_limit ${CUR_MEM} -> ${MEM_LIMIT_DESIRED} (exit 137 = OOM kill — this was the crash loop)"
    else
        ok "mem_limit already ${MEM_LIMIT_DESIRED}"
    fi
else
    ok "No mem_limit directive in compose (uncapped) or file absent"
fi

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

# Detect container-state mount path for the doctor hint
CSTATE="$DEFAULT_CONTAINER_STATE_DIR"
if [[ -f "${STATE_DIR}/docker.env" ]]; then
    DETECTED="$(grep -E '^CONTAINER_STATE_DIR=' "${STATE_DIR}/docker.env" | cut -d= -f2)"
    [[ -n "$DETECTED" ]] && CSTATE="$DETECTED"
fi

cat << EOF

======================================================
  REBUILD COMPLETE
======================================================
  State dir:   ${STATE_DIR}
  Recipe tag:  ${PINNED_TAG}
  Backup:      ${BACKUP_FILE:-none}
  Mem limit:   ${MEM_LIMIT_DESIRED}
  Fresh VM:    ${FRESH_VM}

  Watch it live:      make logs
  Stop everything:    make docker-down
======================================================

IF the logs show an agent-database integrity gate or admission errors,
repair with (stops containers first!):

  cd ${STATE_DIR}
  docker compose --env-file docker.env down
  docker run --rm -it \\
    -v "${STATE_DIR}:${CSTATE}" \\
    --entrypoint openclaw openclaw-triad:local doctor --fix
  cd ${ORCHESTRATE_DIR} && make docker-up

Confirmation the triad is alive:
  [gateway] ready
  scheduler lines referencing YOUR roster (${ROSTER_CHECK})
  NO 'exit 137', NO 'restart-loop breaker', NO admission errors

Paste the last 40 log lines back to Lumo either way.
EOF
