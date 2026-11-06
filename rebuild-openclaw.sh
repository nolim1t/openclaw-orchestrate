#!/usr/bin/env bash
#
# rebuild-openclaw.sh (v1.0)
# One-command, from-scratch rebuild of the OpenClaw triad stack.
#
# PURPOSE:
#   Automates the entire teardown → regenerate → validate → build → boot
#   sequence, with every hard-won fix from the live deployment baked in as
#   a mandatory checkpoint. Fails FAST (before the expensive npm build) if
#   any generated file looks wrong.
#
# WHAT IT DOES, IN ORDER:
#   0. Backs up ~/.openclaw/.env secrets to ~/openclaw-env-backup-<date>
#   1. Stops the running containers (if any)
#   2. Optionally deletes the colima VM for a virgin Docker estate (--fresh-vm)
#   3. Removes the entire generated state directory (~/.openclaw)
#   4. Verifies the generator script is present and syntax-valid
#   5. Restores your secrets and SCRUBS stale overrides (BASE_IMAGE=python…)
#   6. Runs the generator (make setup) with your .env values
#   7. Runs the FIVE-POINT INSPECTION on the generated files (fail-fast)
#   8. Builds the image and boots the Gateway
#   9. Tails the first 60 seconds of logs so you can watch [gateway] ready
#
# USAGE:
#   ./rebuild-openclaw.sh              # standard rebuild (keeps colima VM)
#   ./rebuild-openclaw.sh --fresh-vm   # also delete + recreate the colima VM
#   ./rebuild-openclaw.sh --no-build   # tear down + generate + validate only
#   ./rebuild-openclaw.sh --yes        # skip the confirmation prompt
#
# REQUIRES:
#   ~/openclaw-orchestrate/scripts/setup-openclaw-triad.sh  (v2.5 or later)
#   ~/openclaw-orchestrate/Makefile                          (v2, .env-aware)
#   colima + docker CLI on PATH
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

FRESH_VM=false
DO_BUILD=true
ASSUME_YES=false

# Stale overrides from the pre-Node era that must NEVER survive a rebuild.
# These are stripped from .env before generation.
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

usage() {
    cat << 'USAGEEOF'
Usage: ./rebuild-openclaw.sh [OPTIONS]

Options:
  --fresh-vm    Delete and recreate the colima VM (virgin Docker estate).
                Slower (full image re-pull) but erases crash-loop history,
                stale leases, and all cached layers.
  --no-build    Tear down + regenerate + validate, but skip build/boot.
                Useful when you just want clean generated files.
  --yes         Skip the confirmation prompt (non-interactive-ish).
  --help        This message.

What gets DELETED (irrecoverably):
  - ~/.openclaw/ (all generated config, workspaces, runtime DB, journals)
  - running openclaw containers + the openclaw-triad image
  - with --fresh-vm: the entire colima VM (all images, volumes, caches)

What gets PRESERVED:
  - ~/.openclaw/.env secrets (backed up to ~/openclaw-env-backup-<date> first)
  - ~/openclaw-orchestrate/ (the recipe — git-tracked, never touched)
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
        --yes|-y)   ASSUME_YES=true; shift ;;
        --help|-h)  usage ;;
        *) die "Unknown option: $1 (try --help)" ;;
    esac
done

###############################################################################
# PHASE 0 — PREFLIGHT
###############################################################################

step "Preflight checks"

[[ -x "$SETUP_SCRIPT" ]] || die "Setup script missing or not executable: ${SETUP_SCRIPT}
    Re-save the v2.5 generator from the canvas into ${SCRIPTS_DIR}/ and chmod +x it."

bash -n "$SETUP_SCRIPT" || die "Setup script fails syntax check — re-save it from the canvas."
ok "Setup script present, syntax OK ($(basename "$SETUP_SCRIPT"))"

[[ -f "${ORCHESTRATE_DIR}/Makefile" ]] || die "Makefile missing in ${ORCHESTRATE_DIR}.
    Re-save the v2 Makefile from the canvas."
ok "Makefile present"

# Makefile version check: must source .env (the v1 Makefile drops roster vars)
if grep -q 'set -a && . ' "${ORCHESTRATE_DIR}/Makefile"; then
    ok "Makefile is .env-aware (v2)"
else
    die "Makefile is the OLD v1 (does not source .env — AGENT_ROSTER/preset would be silently dropped).
    Re-save the v2 Makefile from the canvas."
fi

command -v docker >/dev/null 2>&1 || die "docker CLI not found on PATH"
command -v colima >/dev/null 2>&1 || warn "colima CLI not found (skipping VM management)"

# Generator version check — must be v2.5+
GEN_VERSION="$(grep -o 'v2\.[0-9]*' "$SETUP_SCRIPT" | head -1)"
ok "Generator version marker: ${GEN_VERSION:-unknown}"

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
    colima start --cpu 4 --memory 4 || die "colima start failed"
    ok "Fresh VM running (4 CPU / 4GB)"
else
    ok "Keeping existing colima VM (use --fresh-vm to nuke it too)"
fi

# Verify the docker backend is responsive before going further
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
    warn "Empty .env created — fill in NANOGPT_API_KEY and OPENCLAW_GATEWAY_TOKEN after generation"
fi

# Scrub known-bad legacy values that override v2.5 defaults.
# The pre-Node era injected BASE_IMAGE=python:3.11-slim into .env, which
# silently defeats the node:24-slim base and explodes at the npm step.
if grep -E "^${STALE_PATTERNS}" "$ENV_FILE" >/dev/null 2>&1; then
    # delete matching lines (macOS/BSD sed needs no -i suffix arg)
    sed -i '' -E "/^${STALE_PATTERNS}/d" "$ENV_FILE"
    warn "Removed stale BASE_IMAGE override (python base) from .env"
else
    ok "No stale overrides found in .env"
fi

# Require the two essential keys (warn, don't die — generation still works)
for key in NANOGPT_API_KEY OPENCLAW_GATEWAY_TOKEN; do
    if grep -E "^${key}=..+" "$ENV_FILE" >/dev/null 2>&1; then
        ok "${key} present"
    else
        warn "${key} missing/empty — Gateway/agents will not run until filled"
    fi
done

# If OPENCLAW_GATEWAY_TOKEN is empty, generate one so the build boots first try
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
inspect() {  # inspect <description> <command...>
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

# 4. Correct entrypoint (openclaw start does not exist)
inspect "4. Dockerfile CMD is openclaw gateway" \
    grep -q 'CMD \["openclaw", "gateway"\]' "${STATE_DIR}/Dockerfile"

# 5. Roster values present in config (from AGENT_ROSTER in .env)
ROSTER_CHECK="$(grep -E '^AGENT_ROSTER=' "$ENV_FILE" | cut -d= -f2)"
if [[ -n "$ROSTER_CHECK" ]]; then
    ok "5. Roster from .env: ${ROSTER_CHECK}"
    IFS=',' read -ra CHECK_NAMES <<< "$ROSTER_CHECK"
    for name in "${CHECK_NAMES[@]}"; do
        inspect "   - agent '${name}' in openclaw.json" \
            grep -q "${name}:" "${STATE_DIR}/openclaw.json"
    done
else
    warn "5. AGENT_ROSTER not set in .env — generator default (clawdia/clawdio/arbiter) applied"
    warn "   Add AGENT_ROSTER=seer,guardian,sage to ${ENV_FILE} and re-run"
    fail_count=$((fail_count + 1))
fi

# Bonus: docker.env must not carry a python BASE_IMAGE
if [[ -f "${STATE_DIR}/docker.env" ]]; then
    inspect "Bonus: docker.env BASE_IMAGE is node" \
        grep -q 'BASE_IMAGE=node' "${STATE_DIR}/docker.env"
fi

if [[ "$fail_count" -gt 0 ]]; then
    die "${fail_count} inspection check(s) failed — NOT building.
    Fix the generated files or the generator, then re-run. No build time wasted."
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
  Next steps:
    1. nano ${ENV_FILE}          # fill in remaining keys
    2. cd ${ORCHESTRATE_DIR}
    3. make docker-build
    4. make docker-up
    5. make logs
======================================================
EOF
    exit 0
fi

step "Building Docker image (this is the long step: apt + npm layers)"

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

cat << EOF

======================================================
  REBUILD COMPLETE
======================================================
  State dir:   ${STATE_DIR}
  Backup:      ${BACKUP_FILE:-none}
  Fresh VM:    ${FRESH_VM}

  Watch it live:      make logs
  Check roster:       make agents
  Shell inside:       make shell
  Stop everything:    make docker-down
======================================================

Watch for these log lines to confirm the triad is alive:
  [gateway] ready
  scheduler lines referencing YOUR roster names
  (crash-loop breaker should NOT appear on a clean state dir)

If anything looks wrong: paste the last 40 log lines back to Lumo.
EOF
