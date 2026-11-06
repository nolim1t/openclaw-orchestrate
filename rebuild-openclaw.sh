#!/usr/bin/env bash
#
# rebuild-openclaw.sh (v1.1)
# One-command, from-scratch rebuild of the OpenClaw triad stack.
#
# v1.1 CHANGES:
#   - Auto-fetches the Makefile and setup generator from the pinned GitHub
#     tag when missing (or forced with --fetch), so the orchestrator is
#     self-bootstrapping and can never run against a stale copy.
#   - Pinned source: tag 20261106-1428 of github.com/nolim1t/openclaw-orchestrate
#
# WHAT IT DOES, IN ORDER:
#   0. Backs up ~/.openclaw/.env secrets to ~/openclaw-env-backup-<date>
#   1. Ensures Makefile + generator exist (auto-downloads pinned versions)
#   2. Stops the running containers (if any)
#   3. Optionally deletes the colima VM for a virgin Docker estate (--fresh-vm)
#   4. Removes the entire generated state directory (~/.openclaw)
#   5. Verifies the generator script is present and syntax-valid
#   6. Restores your secrets and SCRUBS stale overrides (BASE_IMAGE=python…)
#   7. Runs the generator (make setup) with your .env values
#   8. Runs the FIVE-POINT INSPECTION on the generated files (fail-fast)
#   9. Builds the image and boots the Gateway
#  10. Tails the first logs so you can watch [gateway] ready
#
# USAGE:
#   ./rebuild-openclaw.sh              # standard rebuild (keeps colima VM)
#   ./rebuild-openclaw.sh --fresh-vm   # also delete + recreate the colima VM
#   ./rebuild-openclaw.sh --no-build   # tear down + generate + validate only
#   ./rebuild-openclaw.sh --fetch      # force re-download pinned files
#   ./rebuild-openclaw.sh --yes        # skip the confirmation prompt
#
# BASH 3.2 SAFE (macOS stock) — no ${var,,}, no associative arrays.
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
MAKEFILE="${ORCHESTRATE_DIR}/Makefile"

# Pinned upstream sources — bump the tag when you cut a new release.
ORCHESTRATE_REPO_TAG="20261106-1428"
GITHUB_BASE="https://raw.githubusercontent.com/nolim1t/openclaw-orchestrate/refs/tags/${ORCHESTRATE_REPO_TAG}"
PINNED_MAKEFILE_URL="${GITHUB_BASE}/Makefile"
PINNED_SETUP_URL="${GITHUB_BASE}/scripts/setup-openclaw-triad.sh"

FRESH_VM=false
DO_BUILD=true
ASSUME_YES=false
FORCE_FETCH=false

# Stale overrides from the pre-Node era that must NEVER survive a rebuild.
STALE_PATTERNS='BASE_IMAGE=python'

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

fetch_file() {  # fetch_file <url> <dest> <description>
    local url="$1" dest="$2" desc="$3"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$dest" || die "Could not download ${desc} from ${url}"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$dest" "$url" || die "Could not download ${desc} from ${url}"
    else
        die "Neither curl nor wget available — cannot fetch ${desc}"
    fi
}

usage() {
    cat << 'USAGEEOF'
Usage: ./rebuild-openclaw.sh [OPTIONS]

Options:
  --fresh-vm    Delete and recreate the colima VM (virgin Docker estate).
                Slower (full image re-pull) but erases crash-loop history,
                stale leases, and all cached layers.
  --no-build    Tear down + regenerate + validate, but skip build/boot.
  --fetch       Force re-download of the pinned Makefile and generator,
                even if copies already exist locally.
  --yes         Skip the confirmation prompt.
  --help        This message.

Pinned source tag: (see ORCHESTRATE_REPO_TAG in script)

What gets DELETED (irrecoverably):
  - ~/.openclaw/ (all generated config, workspaces, runtime DB, journals)
  - running openclaw containers + the openclaw-triad image
  - with --fresh-vm: the entire colima VM (all images, volumes, caches)

What gets PRESERVED:
  - ~/.openclaw/.env secrets (backed up before deletion)
  - ~/openclaw-orchestrate/ (recipe — refreshed from the pinned tag)
USAGEEOF
    exit 0
}

###############################################################################
# ARGUMENTS
###############################################################################

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fresh-vm) FRESH_VM=true; shift ;;
        --no-build) DO_BUILD=false; shift ;;
        --fetch)    FORCE_FETCH=true; shift ;;
        --yes|-y)   ASSUME_YES=true; shift ;;
        --help|-h)  usage ;;
        *) die "Unknown option: $1 (try --help)" ;;
    esac
done

mkdir -p "$ORCHESTRATE_DIR" "$SCRIPTS_DIR"

###############################################################################
# PHASE 0 — BOOTSTRAP: MAKEFILE + GENERATOR (auto-fetch pinned versions)
###############################################################################

step "Bootstrapping orchestrator files (tag ${ORCHESTRATE_REPO_TAG})"

# --- Makefile ---
if [[ "$FORCE_FETCH" == "true" || ! -f "$MAKEFILE" ]]; then
    if [[ "$FORCE_FETCH" == "true" ]]; then
        warn "Forced fetch of Makefile (--fetch)"
    else
        warn "Makefile missing — fetching pinned version"
    fi
    fetch_file "$PINNED_MAKEFILE_URL" "$MAKEFILE" "Makefile"
    ok "Makefile fetched from pinned tag"
else
    ok "Makefile present locally"
fi

# --- Setup generator ---
if [[ "$FORCE_FETCH" == "true" || ! -f "$SETUP_SCRIPT" ]]; then
    if [[ "$FORCE_FETCH" == "true" ]]; then
        warn "Forced fetch of setup generator (--fetch)"
    else
        warn "Setup generator missing — fetching pinned version"
    fi
    fetch_file "$PINNED_SETUP_URL" "$SETUP_SCRIPT" "setup generator"
    ok "Setup generator fetched from pinned tag"
else
    ok "Setup generator present locally"
fi

chmod +x "$SETUP_SCRIPT"

# Sanity: fetched files must be syntax-valid bash
bash -n "$SETUP_SCRIPT" || die "Setup script fails syntax check — tag ${ORCHESTRATE_REPO_TAG} may be broken."
ok "Setup script present, syntax OK"

# Generator version marker
GEN_VERSION="$(grep -o 'v2\.[0-9]*' "$SETUP_SCRIPT" | head -1)"
ok "Generator version marker: ${GEN_VERSION:-unknown}"

# Makefile version check: must source .env (the v1 Makefile drops roster vars)
if grep -q 'set -a && . ' "$MAKEFILE"; then
    ok "Makefile is .env-aware (v2)"
else
    die "Makefile is the OLD v1 (does not source .env).
    Fetch fixed with: $0 --fetch"
fi

command -v docker >/dev/null 2>&1 || die "docker CLI not found on PATH"
command -v colima >/dev/null 2>&1 || warn "colima CLI not found (skipping VM management)"

step "Confirm the destruction"
printf '  State dir to delete:   %s\n' "$STATE_DIR"
printf '  Colima VM wiped too:   %s\n' "$FRESH_VM"
printf '  Secrets backed up to:  %s\n' "${BACKUP_DIR}/openclaw-env-backup-<date>"
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
    warn "No existing .env found — fill in keys after generation"
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
    ok "Fresh VM running (4 CPU / 6GB — headroom matters for the runtime)"
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
    ok "State directory deleted"
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

# Scrub known-bad legacy values (python base image defeats node:24-slim)
if grep -E "^${STALE_PATTERNS}" "$ENV_FILE" >/dev/null 2>&1; then
    sed -i '' -E "/^${STALE_PATTERNS}/d" "$ENV_FILE"
    warn "Removed stale BASE_IMAGE override (python base) from .env"
else
    ok "No stale overrides found in .env"
fi

# Require essential keys
for key in NANOGPT_API_KEY OPENCLAW_GATEWAY_TOKEN; do
    if grep -E "^${key}=..+" "$ENV_FILE" >/dev/null 2>&1; then
        ok "${key} present"
    else
        warn "${key} missing/empty — Gateway/agents will not run until filled"
    fi
done

# Auto-generate gateway token if absent
if ! grep -E "^OPENCLAW_GATEWAY_TOKEN=..+" "$ENV_FILE" >/dev/null 2>&1; then
    echo "OPENCLAW_GATEWAY_TOKEN=$(openssl rand -hex 32)" >> "$ENV_FILE"
    ok "Generated fresh OPENCLAW_GATEWAY_TOKEN"
fi

###############################################################################
# PHASE 5 — GENERATE THE STACK
###############################################################################

step "Generating stack via make setup"

( cd "$ORCHESTRATE_DIR" && make setup ) || die "make setup failed — inspect output above"

ok "Generation complete"

###############################################################################
# PHASE 6 — FIVE-POINT INSPECTION (fail-fast BEFORE the expensive build)
###############################################################################

step "Five-point inspection of generated files"

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

inspect "1. Dockerfile has getent group guard" \
    grep -q 'getent group' "${STATE_DIR}/Dockerfile"

inspect "2. Dockerfile uses node base image" \
    grep -q 'node:24-slim' "${STATE_DIR}/Dockerfile"

inspect "3. openclaw.json has gateway.mode" \
    grep -q 'gateway: { mode: "local" }' "${STATE_DIR}/openclaw.json"

inspect "4. Dockerfile CMD is openclaw gateway" \
    grep -q 'CMD \["openclaw", "gateway"\]' "${STATE_DIR}/Dockerfile"

ROSTER_CHECK="$(grep -E '^AGENT_ROSTER=' "$ENV_FILE" | cut -d= -f2)"
if [[ -n "$ROSTER_CHECK" ]]; then
    ok "5. Roster from .env: ${ROSTER_CHECK}"
    IFS=',' read -ra CHECK_NAMES <<< "$ROSTER_CHECK"
    for name in "${CHECK_NAMES[@]}"; do
        inspect "   - agent '${name}' in openclaw.json" \
            grep -q "${name}:" "${STATE_DIR}/openclaw.json"
    done
else
    warn "5. AGENT_ROSTER not set in .env — generator default roster applied"
    fail_count=$((fail_count + 1))
fi

if [[ -f "${STATE_DIR}/docker.env" ]]; then
    inspect "Bonus: docker.env BASE_IMAGE is node" \
        grep -q 'BASE_IMAGE=node' "${STATE_DIR}/docker.env"
fi

if [[ "$fail_count" -gt 0 ]]; then
    die "${fail_count} inspection check(s) failed — NOT building.
    Fix the generated files or the generator, then re-run."
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
  Next: fill .env keys, then make docker-build && make docker-up
======================================================
EOF
    exit 0
fi

step "Building Docker image (long step: apt + npm layers)"

( cd "$ORCHESTRATE_DIR" && make docker-build ) \
    || die "docker build failed — paste the failing step output"

ok "Image built"

###############################################################################
# PHASE 8 — BOOT AND WATCH
###############################################################################

step "Starting the Gateway"

( cd "$ORCHESTRATE_DIR" && make docker-up ) || die "docker up failed"

ok "Container started — capturing first logs"

sleep 12

step "Gateway logs (first look)"
docker logs openclaw-triad --tail 60 2>&1 || true

# Post-boot health probe: detect the silent-kill pattern (exit 137 / OOM)
STATUS="$(docker inspect -f '{{.State.Status}} OOMKilled={{.State.OOMKilled}} ExitCode={{.State.ExitCode}}' openclaw-triad 2>/dev/null || echo 'inspect-failed')"
ok "Container state: ${STATUS}"

case "$STATUS" in
    *OOMKilled=true*|*ExitCode=137*)
        warn "Container was OOM-killed (exit 137). Fixes:"
        warn "  1. Give the colima VM more RAM: colima stop && colima start --cpu 4 --memory 6"
        warn "  2. Re-run this script WITHOUT --fresh-vm (layers are cached, fast rebuild)"
        ;;
    *running*)
        ok "Container is running cleanly"
        ;;
esac

cat << EOF

======================================================
  REBUILD COMPLETE
======================================================
  State dir:   ${STATE_DIR}
  Backup:      ${BACKUP_FILE:-none}
  Fresh VM:    ${FRESH_VM}
  Source tag:  ${ORCHESTRATE_REPO_TAG}

  Watch it live:      make logs
  Stop everything:    make docker-down
======================================================

Watch for: [gateway] ready, then your roster names registering.
Crash-loop breaker messages? Clean state dir + this rebuild clears them.
EOF
