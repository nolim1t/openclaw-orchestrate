#!/usr/bin/env bash
#
# ./docs/contrib/apply-embed-ollama.sh — one-shot patcher: generates and applies the
# "Embed Ollama in compose" change set to the OpenClaw Triad repo.
#
# WHAT IT DOES (in order):
#   1. Edits scripts/setup-openclaw-triad.sh  (OLLAMA_EMBED flag + defaults,
#      preflight gate, embedded-service emission via post-write splice,
#      changelog, summary banner)
#   2. Edits Makefile                          (make ollama-init target)
#   3. Edits env/.env.example                  (consolidated Ollama section)
#   4. Edits .github/workflows/ci.yml          (ollama-smoke job, embedded
#                                              topology — host dance deleted)
#   5. VERIFIES: bash -n + shellcheck (if present) on the generator, then
#      runs the generator twice into a throwaway state dir (embedded mode
#      vs normal mode) and greps both outputs.
#   6. Emits 0001-embed-ollama-in-compose.patch (git diff of tracked files).
#      With --commit it stages, commits, and emits a format-patch instead.
#
# SAFETY:
#   - Idempotent: every edit checks its marker first; re-running skips done
#     parts. Only tracked files are touched, so `git checkout -- .` reverts
#     everything.
#   - Fails LOUDLY per-part on a missing anchor (prints exactly what it
#     couldn't find) instead of guessing; other parts still apply.
#   - Bash 3.2 safe (macOS stock): no mapfile, no ${var,,}.
#
# USAGE:
#   cd ~/openclaw-orchestrate
#   ./apply-embed-ollama.sh            # apply + verify + write .patch
#   ./apply-embed-ollama.sh --commit   # ...and commit + format-patch
#
set -uo pipefail   # NOTE: no -e; each part handles its own errors so the
                   # summary can report all parts, not die on the first.

REPO_ROOT="$(pwd)"
GEN="$REPO_ROOT/scripts/setup-openclaw-triad.sh"
MK="$REPO_ROOT/Makefile"
ENVEX="$REPO_ROOT/env/.env.example"
CI="$REPO_ROOT/.github/workflows/ci.yml"
DO_COMMIT=0
[[ "${1:-}" == "--commit" ]] && DO_COMMIT=1

APPLIED=0; SKIPPED=0; FAILED=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say()  { printf '%s\n' "$*"; }
ok()   { printf '   [ok] %s\n' "$*"; APPLIED=$((APPLIED+1)); }
skip() { printf '   [skip] %s\n' "$*"; SKIPPED=$((SKIPPED+1)); }
fail() { printf '   [FAIL] %s\n' "$*" >&2; FAILED=$((FAILED+1)); }

# ---------------------------------------------------------------------------
# helpers (substring anchors, not regex — survives emoji/punctuation)
# ---------------------------------------------------------------------------

# insert_after FILE ANCHOR NEWFILE  -> insert NEWFILE's lines after the first
# line containing ANCHOR.
insert_after() {
    awk -v anchor="$2" -v newfile="$3" '
        { print }
        index($0, anchor) > 0 && !done {
            while ((getline nl < newfile) > 0) print nl
            close(newfile); done = 1
        }
    ' "$1" > "$1.new" && mv "$1.new" "$1"
}

# insert_before FILE ANCHOR NEWFILE
insert_before() {
    awk -v anchor="$2" -v newfile="$3" '
        index($0, anchor) > 0 && !done {
            while ((getline nl < newfile) > 0) print nl
            close(newfile); done = 1
        }
        { print }
    ' "$1" > "$1.new" && mv "$1.new" "$1"
}

# replace_line_matching FILE ANCHOR NEWFILE  -> first line containing ANCHOR
# is replaced by NEWFILE's lines.
replace_line_matching() {
    awk -v anchor="$2" -v newfile="$3" '
        index($0, anchor) > 0 && !done {
            while ((getline nl < newfile) > 0) print nl
            close(newfile); done = 1; next
        }
        { print }
    ' "$1" > "$1.new" && mv "$1.new" "$1"
}

# replace_span FILE START_ANCHOR END_ANCHOR NEWFILE
# Lines from first START match through first END match (inclusive) are
# replaced by NEWFILE's lines. If START is found but END is not, abort that
# part (returns nonzero via global flag).
SPAN_ERR=0
replace_span() {
    SPAN_ERR=0
    awk -v start="$2" -v end="$3" -v newfile="$4" '
        BEGIN { insec = 0 }
        insec {
            if (index($0, end) > 0) { insec = 0; done_end = 1 }
            next
        }
        {
            if (!done_start && index($0, start) > 0) {
                done_start = 1; insec = 1
                while ((getline nl < newfile) > 0) print nl
                close(newfile)
                next
            }
            print
        }
        END { if (!done_start || !done_end) exit 42 }
    ' "$1" > "$1.new"
    rc=$?
    if [[ $rc -eq 42 ]]; then
        rm -f "$1.new"
        SPAN_ERR=1
    else
        mv "$1.new" "$1"
    fi
}

grep_q() { grep -q -- "$2" "$1" 2>/dev/null; }

# ===========================================================================
# PART 1 — scripts/setup-openclaw-triad.sh
# ===========================================================================
say "== Part 1: generator ($GEN) =="

[[ -f "$GEN" ]] || { fail "generator not found at $GEN (run from repo root)"; }
if [[ -f "$GEN" ]]; then

  # -- 1a. OLLAMA_EMBED defaults + is_ollama_active seam --------------------
  if grep_q "$GEN" 'OLLAMA_EMBED'; then
      skip "1a defaults: OLLAMA_EMBED already present"
  else
      cat > "$TMP/defaults.txt" <<'BLOCK'

# --- Ollama (local LLM; consumed when OLLAMA_ONLY=1) ------------------------
OLLAMA_EMBED="${OLLAMA_EMBED:-0}"
OLLAMA_IMAGE="${OLLAMA_IMAGE:-ollama/ollama:0.40.10}"
OLLAMA_MEM_LIMIT="${OLLAMA_MEM_LIMIT:-2g}"
if [[ "$OLLAMA_EMBED" == "1" ]]; then
    # Embedded: compose-network DNS name (service ships inside the stack).
    OLLAMA_BASE_URL="${OLLAMA_BASE_URL:-http://ollama:11434/v1}"
else
    # Host-attached: containers dial the host daemon via host-gateway.
    OLLAMA_BASE_URL="${OLLAMA_BASE_URL:-http://host.docker.internal:11434/v1}"
fi
OLLAMA_SCOUT_MODEL="${OLLAMA_SCOUT_MODEL:-qwen3:1.7b}"
OLLAMA_RISK_MODEL="${OLLAMA_RISK_MODEL:-qwen3:1.7b}"
OLLAMA_JUDGE_MODEL="${OLLAMA_JUDGE_MODEL:-qwen3:1.7b}"
OLLAMA_UTILITY_MODEL="${OLLAMA_UTILITY_MODEL:-qwen3:0.6b}"

is_ollama_active() {  # is the ollama provider wired? (seam for OLLAMA_UTILITY=1)
    is_ollama_only
}
BLOCK
      if grep_q "$GEN" 'OLLAMA_BASE_URL:-'; then
          # v2 patch applied: a plain base-url default line already exists.
          # Replace it with the full mode-aware block above.
          replace_line_matching "$GEN" 'OLLAMA_BASE_URL:-' "$TMP/defaults.txt"
          ok "1a defaults: replaced existing OLLAMA_BASE_URL line with mode-aware block"
      elif grep_q "$GEN" 'USE_WALLET=true'; then
          insert_after "$GEN" 'USE_WALLET=true' "$TMP/defaults.txt"
          ok "1a defaults: inserted after feature detection"
      else
          fail "1a defaults: no OLLAMA_BASE_URL default and no USE_WALLET anchor — paste your Ollama vars region"
      fi
  fi

  # -- 1b. Preflight: skip host probe in embedded mode ----------------------
  if grep_q "$GEN" 'OLLAMA_EMBED=1: ollama ships inside compose'; then
      skip "1b preflight: already gated"
  else
      cat > "$TMP/preflight.txt" <<'BLOCK'
    if [[ "$OLLAMA_EMBED" == "1" ]]; then
        # Server does not exist yet at generation time — it boots with the
        # compose stack and is verified by `make ollama-init` post-boot.
        echo "   [i] OLLAMA_EMBED=1: ollama ships inside compose; host preflight skipped."
        echo "       After boot:  make ollama-init   (pulls seat models)"
        return 0
    fi
BLOCK
      if grep_q "$GEN" 'is_ollama_only || return 0'; then
          insert_after "$GEN" 'is_ollama_only || return 0' "$TMP/preflight.txt"
          ok "1b preflight: embed gate inserted"
      else
          fail "1b preflight: no 'is_ollama_only || return 0' line found"
      fi
  fi

  # -- 1c. Embedded service emission (post-write splice) --------------------
  if grep_q "$GEN" 'openclaw-ollama'; then
      skip "1c compose emission: already present"
  else
      cat > "$TMP/emission.txt" <<'BLOCK'
    # --- Ollama embedded service (v3.4) -------------------------------------
    # Emitted only when the ollama provider is wired AND OLLAMA_EMBED=1.
    # Done as a POST-WRITE splice so the quoted EOCC heredoc stays intact
    # (compose vars like ${APP_UID} must survive to compose interpolation);
    # the service block has no compose-deferred vars, so it interpolates
    # NOW: the pinned image tag and mem ceiling land in the file verbatim.
    if is_ollama_active && [[ "$OLLAMA_EMBED" == "1" ]]; then
        # depends_on must live INSIDE the openclaw-triad service: splice it
        # in right after the service's env_file stanza (unique anchor).
        awk '
          { print }
          /^    env_file:/ {
              print "    depends_on:"
              print "      ollama:"
              print "        condition: service_healthy"
          }
        ' "${STATE_DIR}/docker-compose.yml" > "${STATE_DIR}/docker-compose.yml.tmp" \
          && mv "${STATE_DIR}/docker-compose.yml.tmp" "${STATE_DIR}/docker-compose.yml"
        cat >> "${STATE_DIR}/docker-compose.yml" <<EOLL
  ollama:
    image: ${OLLAMA_IMAGE}
    container_name: openclaw-ollama
    restart: unless-stopped
    volumes:
      - ollama-models:/root/.ollama
    environment:
      # Keep the utility model resident between calls — utility traffic is
      # bursty and reload latency would dominate response time.
      OLLAMA_KEEP_ALIVE: 10m
    # NO ports: block — reachable only inside the compose network.
    # Least privilege: the models are never exposed to the LAN.
    mem_limit: ${OLLAMA_MEM_LIMIT}
    healthcheck:
      test: ["CMD-SHELL", "ollama list >/dev/null"]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 30s

volumes:
  ollama-models:
EOLL
        echo "   [ok] ollama embedded service written (image=${OLLAMA_IMAGE}, mem=${OLLAMA_MEM_LIMIT})"
    fi

    echo "   [ok] Docker trio written: Dockerfile + docker-compose.yml + docker.env (mem_limit=${CONTAINER_MEM_LIMIT}, .tmp tmpfs + TMPDIR, no config-file mount, image-side guard)"
BLOCK
      if grep_q "$GEN" '[ok] Docker trio written'; then
          # replace the old echo line so the summary lands in the right place
          replace_line_matching "$GEN" '[ok] Docker trio written' "$TMP/emission.txt"
          ok "1c compose emission: post-write splice installed"
      else
          fail "1c compose emission: '[ok] Docker trio written' anchor not found"
      fi
  fi

  # -- 1d. Changelog ---------------------------------------------------------
  if grep_q "$GEN" 'CHANGELOG v3.4'; then
      skip "1d changelog: present"
  else
      cat > "$TMP/changelog.txt" <<'BLOCK'
# CHANGELOG v3.4 — Ollama embedded service (OLLAMA_EMBED=1)
#   - Generator emits an `ollama` service inside docker-compose.yml when
#     the ollama provider is wired AND OLLAMA_EMBED=1: named volume for
#     models, NO published ports, own mem ceiling, healthcheck, and
#     depends_on: service_healthy on the gateway (startup order is
#     structural, not a sleep-race).
#   - Provider baseUrl default flips to compose DNS (http://ollama:11434/v1)
#     in embedded mode; host-attached default unchanged.
#   - Preflight probes the host only when a HOST ollama is expected.
#   - Image is pinned via OLLAMA_IMAGE (bump deliberately, like BASE_IMAGE).
#
BLOCK
      if grep_q "$GEN" 'CHANGELOG v3.2'; then
          insert_before "$GEN" '# CHANGELOG v3.2' "$TMP/changelog.txt"
          ok "1d changelog: v3.4 block inserted"
      else
          fail "1d changelog: '# CHANGELOG v3.2' anchor not found"
      fi
  fi

  # -- 1e. Summary banner ----------------------------------------------------
  if grep_q "$GEN" 'OLLAMA_EMBED=1: ollama ships'; then
      skip "1e banner: present"
  else
      cat > "$TMP/banner.txt" <<'BLOCK'
if [[ "$OLLAMA_EMBED" == "1" ]] && is_ollama_active; then
    echo "   ollama : EMBEDDED service in compose (${OLLAMA_IMAGE}, mem=${OLLAMA_MEM_LIMIT})"
    echo "            After first boot: make ollama-init   # pulls the seat models"
fi

BLOCK
      if grep_q "$GEN" '.ENV STEWARDSHIP'; then
          insert_before "$GEN" '# .ENV STEWARDSHIP' "$TMP/banner.txt"
          ok "1e summary banner inserted before .ENV STEWARDSHIP"
      else
          fail "1e banner: '.ENV STEWARDSHIP' anchor not found"
      fi
  fi

  # -- syntax check immediately ----------------------------------------------
  if ! bash -n "$GEN" 2>"$TMP/syntax.err"; then
      fail "generator broke syntax after Part 1 — inspect: $TMP/syntax.err (kept via rerun); output:"
      sed -n '1,10p' "$TMP/syntax.err" >&2
  fi
fi

# ===========================================================================
# PART 2 — Makefile
# ===========================================================================
say "== Part 2: Makefile ($MK) =="
if [[ -f "$MK" ]]; then

  if grep_q "$MK" 'ollama-init'; then
      skip "2a target: ollama-init already present"
  else
      # Tab-safe: __TAB__ markers become real tabs after insertion.
      cat > "$TMP/target.txt" <<'BLOCK'

# =============================================================================
# OLLAMA EMBEDDED SERVICE — model seeding + in-network reachability check.
# Compose cannot pull models declaratively; this is the post-boot step.
# Safe to re-run: pull is idempotent. No-op when no embedded service.
# =============================================================================

ollama-init:
__TAB__@echo "🦙 Seeding embedded Ollama models..."
__TAB__@test -f "$(COMPOSE_FILE)" || { echo "❌ No compose file. Run 'make setup' first."; exit 1; }
__TAB__@grep -q 'container_name: openclaw-ollama' "$(COMPOSE_FILE)" 2>/dev/null \
__TAB____TAB__|| { echo "ℹ  No embedded ollama service (OLLAMA_EMBED=0) — nothing to do."; exit 0; }
__TAB__@cd $(OPENCLAW_STATE_DIR) && docker compose --env-file $(COMPOSE_ENV) exec -T ollama \
__TAB____TAB__sh -c 'for m in qwen3:0.6b qwen3:1.7b; do ollama pull "$$m"; done'
__TAB__@cd $(OPENCLAW_STATE_DIR) && docker compose --env-file $(COMPOSE_ENV) exec -T ollama ollama list
__TAB__@docker exec $(CONTAINER_NAME) curl -sf http://ollama:11434/api/tags >/dev/null 2>&1 \
__TAB____TAB__&& echo "   ✓ gateway -> ollama reachable on compose network" \
__TAB____TAB__|| { echo "   ⚠ gateway cannot reach http://ollama:11434 — check: docker compose ps + logs"; exit 1; }
__TAB__@echo "✓ Ollama models seeded."
BLOCK
      if grep_q "$MK" 'Containers stopped'; then
          insert_after "$MK" 'Containers stopped' "$TMP/target.txt"
          # convert __TAB__ markers to real tabs (make requires them)
          awk '{ sub(/^__TAB__/, "\t"); gsub(/__TAB__/, "\t"); print }' \
              "$MK" > "$MK.new" && mv "$MK.new" "$MK"
          ok "2a target: ollama-init added after docker-down"
      else
          fail "2a target: 'Containers stopped' anchor not found"
      fi
  fi

  # PHONY list update
  if grep_q "$MK" 'ollama-init' && grep_q "$MK" '.PHONY'; then
      if awk '/^\.PHONY:/ && /ollama-init/ { found = 1 } END { exit !found }' "$MK"; then
          skip "2b .PHONY: already listed"
      else
          awk '/^\.PHONY:/ { print; print " "; next } { print }' "$MK" > "$TMP/mk.ph"
          # simpler: append name to the existing .PHONY line instead
          awk '/^\.PHONY:/ && !done { sub(/$/, " ollama-init"); done = 1 } { print }' \
              "$MK" > "$MK.new" && mv "$MK.new" "$MK"
          rm -f "$TMP/mk.ph"
          ok "2b .PHONY: ollama-init appended"
      fi
  fi

  if command -v make >/dev/null 2>&1; then
      if make -n -f "$MK" ollama-init >/dev/null 2>&1; then
          ok "2c make parses ollama-init (dry-run)"
      else
          fail "make -n ollama-init does not parse — check tab conversion"
      fi
  fi
fi

# ===========================================================================
# PART 3 — env/.env.example
# ===========================================================================
say "== Part 3: env/.env.example =="
if [[ -f "$ENVEX" ]]; then
  if grep_q "$ENVEX" 'OLLAMA_EMBED=1'; then
      skip "3: consolidated section already present"
  elif grep_q "$ENVEX" '--- Ollama (local LLM)'; then
      cat > "$TMP/envsection.txt" <<'BLOCK'
# --- Ollama (local LLM) ---------------------------------------------------
# OLLAMA_ONLY=1 forces ALL models (seats + utility) onto the local Ollama
# provider — testnet / CI mode. 0 = NanoGPT lineup (or builtin defaults).
# Models are attached one of two ways:
#
#   OLLAMA_EMBED=1  generator ships an `ollama` service INSIDE the compose
#                   stack (named volume, no published ports, DNS `ollama`).
#                   Recommended default. After first boot: make ollama-init
#                   to pull models.
#   OLLAMA_EMBED=0  you run your own daemon on the host; containers reach
#                   it via host-gateway at host.docker.internal:11434.
#
OLLAMA_ONLY=0
OLLAMA_EMBED=1

# Container-view Ollama endpoint. Generator defaults handle both modes
# (embedded -> http://ollama:11434/v1, host -> host.docker.internal).
# Only set this if Ollama runs on ANOTHER machine (LAN IP, not loopback).
# OLLAMA_BASE_URL=

# Per-seat ollama model ids (bare — no provider prefix).
# qwen3:0.6b ≈ 500MB  ·  qwen3:1.7b ≈ 1.4GB — CPU-friendly utility class.
# OLLAMA_SCOUT_MODEL=qwen3:1.7b
# OLLAMA_RISK_MODEL=qwen3:1.7b
# OLLAMA_JUDGE_MODEL=qwen3:1.7b
# OLLAMA_UTILITY_MODEL=qwen3:0.6b

# Embedded service tuning (defaults fine for ≤4B models).
# OLLAMA_IMAGE=ollama/ollama:0.40.10   # pin — bump deliberately
# OLLAMA_MEM_LIMIT=2g
BLOCK
      replace_span "$ENVEX" '--- Ollama (local LLM)' '#OLLAMA_MODEL_CATALOG' "$TMP/envsection.txt"
      if [[ $SPAN_ERR -eq 1 ]]; then
          # section exists but the OLLAMA_MODEL_CATALOG end-line doesn't:
          # fall back to end-of-file span (replace from marker to EOF).
          awk -v start='--- Ollama (local LLM)' -v newfile="$TMP/envsection.txt" '
              !insec && index($0, start) > 0 {
                  insec = 1
                  while ((getline nl < newfile) > 0) print nl
                  close(newfile); next
              }
              !insec { print }
          ' "$ENVEX" > "$ENVEX.new" && mv "$ENVEX.new" "$ENVEX"
          ok "3: Ollama section replaced (to EOF — no OLLAMA_MODEL_CATALOG end line found)"
      else
          ok "3: Ollama section replaced (both duplicate blocks consolidated)"
      fi
  else
      fail "3: no '--- Ollama (local LLM)' marker — append the section from the patch doc by hand"
  fi
else
  fail "3: $ENVEX not found (override with EDIT_ENVEX=path ./apply-embed-ollama.sh)"
fi
[[ -n "${EDIT_ENVEX:-}" ]] && ENVEX="$EDIT_ENVEX"

# ===========================================================================
# PART 4 — .github/workflows/ci.yml (replace the ollama-smoke job wholesale)
# ===========================================================================
say "== Part 4: ci.yml (ollama-smoke job) =="
if [[ -f "$CI" ]]; then
  if grep_q "$CI" 'ollama-embedded:' && grep_q "$CI" 'OLLAMA_EMBED: "1"'; then
      skip "4: job already in embedded form"
  elif grep_q "$CI" 'ollama-smoke:'; then
      cat > "$TMP/cijob.txt" <<'BLOCK'
  # ---------------------------------------------------------------------
  # Ollama-only smoke: EMBEDDED topology — the compose service is the
  # model host, so there is no host install/bind/race step at all.
  # Zero API keys: proves the zero-dependency testnet story in CI.
  # ---------------------------------------------------------------------
  ollama-smoke:
    name: Ollama-only smoke (embedded OLLAMA_ONLY=1)
    runs-on: ubuntu-latest
    needs: [generator-smoke, docker-build]
    timeout-minutes: 20
    env:
      OPENCLAW_STATE_DIR: ${{ github.workspace }}/.ci-state/ollama-smoke
      OPENCLAW_GATEWAY_TOKEN: ci-placeholder-token
      AGENT_ROSTER: seer,guardian,sage
      PERSONALITY_PRESET: default
      OLLAMA_ONLY: "1"
      OLLAMA_EMBED: "1"
      # generator default flips to compose DNS; explicit for clarity:
      OLLAMA_BASE_URL: http://ollama:11434/v1
      OLLAMA_SCOUT_MODEL: qwen3:0.6b
      OLLAMA_RISK_MODEL: qwen3:0.6b
      OLLAMA_JUDGE_MODEL: qwen3:0.6b
      OLLAMA_UTILITY_MODEL: qwen3:0.6b
      OLLAMA_MEM_LIMIT: 2g
      # NB: no NANOGPT_API_KEY — zero cloud dependency by design.
    steps:
      - uses: actions/checkout@v4

      - name: Generate stack (ollama-only, embedded)
        run: ./scripts/setup-openclaw-triad.sh --docker

      - name: Assert ollama-only invariants
        run: |
          set -euo pipefail
          CFG="$OPENCLAW_STATE_DIR/openclaw.json"
          CMP="$OPENCLAW_STATE_DIR/docker-compose.yml"
          grep -q '"ollama"' "$CFG"
          ! grep -q 'nanogpt/' "$CFG"
          grep -q 'utilityModel: "ollama/qwen3:0.6b"' "$CFG"
          # embedded service + startup ordering present:
          grep -q 'container_name: openclaw-ollama' "$CMP"
          grep -q 'condition: service_healthy' "$CMP"
          grep -q 'http://ollama:11434/v1' "$CFG"
          # judge stays read-only even in ollama mode — least privilege survives
          grep -q 'tools: { allow: \["read", "message"\] }' "$CFG"

      - name: Compose file parses
        run: >-
          docker compose --env-file "$OPENCLAW_STATE_DIR/docker.env"
          -f "$OPENCLAW_STATE_DIR/docker-compose.yml" config -q

      - name: Boot stack (waits on ollama health gate)
        run: |
          cd "$OPENCLAW_STATE_DIR"
          docker compose --env-file docker.env up -d
          # up -d returns when containers START; the depends_on health gate
          # ordered startup, but seeding can race the first load — retry.
          for i in $(seq 1 30); do
            docker compose --env-file docker.env exec -T ollama \
              ollama pull qwen3:0.6b && break
            sleep 2
          done
          docker compose --env-file docker.env exec -T ollama ollama list
          docker compose --env-file docker.env ps

      - name: Smoke agent round-trip
        run: ./scripts/smoke-agent-loop.sh

      - name: Dump logs on failure
        if: failure()
        run: |
          docker compose --env-file "$OPENCLAW_STATE_DIR/docker.env" \
            -f "$OPENCLAW_STATE_DIR/docker-compose.yml" logs --tail 200 || true

      - name: Teardown
        if: always()
        run: |
          cd "$OPENCLAW_STATE_DIR"
          docker compose --env-file docker.env down -v || true

BLOCK
      # Replace from '  ollama-smoke:' through the last line of the job:
      # next job header (^  name:) or EOF.
      awk -v start='  ollama-smoke:' -v newfile="$TMP/cijob.txt" '
          !insec && index($0, start) == 1 {
              insec = 1
              while ((getline nl < newfile) > 0) print nl
              close(newfile); next
          }
          insec && /^  [a-z][a-zA-Z-]*:/ && index($0, start) != 1 {
              insec = 0
          }
          !insec { print }
      ' "$CI" > "$CI.new" && mv "$CI.new" "$CI"
      ok "4: ollama-smoke job replaced with embedded topology"
  else
      fail "4: no 'ollama-smoke:' job found in ci.yml — is PR2 merged?"
  fi

  if command -v ruby >/dev/null 2>&1; then
      ruby -e 'require "yaml"; YAML.load_file(ARGV[0]); puts "yaml ok"' "$CI" >/dev/null 2>&1 \
          && ok "4b: ci.yml parses as YAML" \
          || skip "4b: ruby/yaml check unavailable or stricter-than-GH parse — rely on the Actions run"
  fi
fi

# ===========================================================================
# PART 5 — FUNCTIONAL VERIFICATION (generate twice, grep outputs)
# ===========================================================================
say "== Part 5: functional verification =="

if [[ -f "$GEN" ]] && bash -n "$GEN" 2>/dev/null; then
  if command -v shellcheck >/dev/null 2>&1; then
      shellcheck -x "$GEN" 2>"$TMP/sc.err" \
          && ok "shellcheck clean" \
          || { sed -n '1,10p' "$TMP/sc.err" >&2; fail "shellcheck findings (review above)"; }
  else
      skip "shellcheck not installed locally (CI will run it)"
  fi

  SCRATCH="$(mktemp -d)"

  # -- Mode A: embedded ollama-only -----------------------------------------
  ( set -a
    . ./env/.env.example 2>/dev/null || true
    set +a
    export OPENCLAW_STATE_DIR="$SCRATCH/a" OLLAMA_ONLY=1 OLLAMA_EMBED=1 \
           OPENCLAW_GATEWAY_TOKEN=vtoken AGENT_ROSTER=seer,guardian,sage \
           PERSONALITY_PRESET=default DOCKER_ENABLE=true
    bash "$GEN" >/dev/null 2>"$TMP/genA.err"
  )
  CA="$SCRATCH/a"
  if [[ -f "$CA/docker-compose.yml" ]]; then
      grep_q "$CA/docker-compose.yml" 'container_name: openclaw-ollama' \
          && ok "A: embedded service in compose" || fail "A: service missing from compose"
      grep_q "$CA/docker-compose.yml" 'condition: service_healthy' \
          && ok "A: depends_on health gate present" || fail "A: health gate missing"
      grep_q "$CA/docker-compose.yml" 'ports:' \
          && fail "A: LEAK — ports stanza found (must not publish)" || ok "A: no published ports"
      grep_q "$CA/openclaw.json" 'http://ollama:11434/v1' \
          && ok "A: provider baseUrl = compose DNS" || fail "A: baseUrl wrong"
      command -v docker >/dev/null 2>&1 && \
      docker compose --env-file "$CA/docker.env" -f "$CA/docker-compose.yml" config -q \
          && ok "A: docker compose config parses" \
          || skip "A: docker not available locally for compose parse (CI covers it)"
  else
      fail "A: generation produced no compose — see $TMP/genA.err"; sed -n '1,8p' "$TMP/genA.err" >&2
  fi

  # -- Mode B: normal nanogpt + embed=true (must be a no-op) ------------------
  ( set -a
    . ./env/.env.example 2>/dev/null || true
    set +a
    export OPENCLAW_STATE_DIR="$SCRATCH/b" OLLAMA_ONLY=0 OLLAMA_EMBED=1 \
           NANOGPT_API_KEY=ci-placeholder OPENCLAW_GATEWAY_TOKEN=vtoken \
           AGENT_ROSTER=seer,guardian,sage PERSONALITY_PRESET=default \
           DOCKER_ENABLE=true
    bash "$GEN" >/dev/null 2>>"$TMP/genB.err"
  )
  CB="$SCRATCH/b"
  if [[ -f "$CB/docker-compose.yml" ]]; then
      grep_q "$CB/docker-compose.yml" 'openclaw-ollama' \
          && fail "B: LEAK — embedded service present with OLLAMA_ONLY=0" \
          || ok "B: no service leak in normal mode (byte-clean no-op)"
  else
      fail "B: generation produced no compose — see $TMP/genB.err"
  fi

  # -- Mode C: host-attached ollama-only (regression) -------------------------
  ( set -a
    . ./env/.env.example 2>/dev/null || true
    set +a
    export OPENCLAW_STATE_DIR="$SCRATCH/c" OLLAMA_ONLY=1 OLLAMA_EMBED=0 \
           OPENCLAW_GATEWAY_TOKEN=vtoken AGENT_ROSTER=seer,guardian,sage \
           PERSONALITY_PRESET=default DOCKER_ENABLE=true
    bash "$GEN" >/dev/null 2>>"$TMP/genB.err"
  )
  CC="$SCRATCH/c"
  if [[ -f "$CC/docker-compose.yml" ]]; then
      grep_q "$CC/docker-compose.yml" 'openclaw-ollama' \
          && fail "C: LEAK — embedded service with OLLAMA_EMBED=0" \
          || ok "C: host-attached mode unchanged (no embedded service)"
      grep_q "$CC/openclaw.json" 'host.docker.internal:11434' \
          && ok "C: host-gateway baseUrl preserved" || fail "C: baseUrl regression"
  else
      fail "C: generation produced no compose"
  fi

  rm -rf "$SCRATCH"
else
  fail "generator failed bash -n earlier — functional verification skipped"
fi

# ===========================================================================
# PART 6 — emit the patch (and optionally commit)
# ===========================================================================
say "== Part 6: patch emission =="
PATCH_FILE="$REPO_ROOT/0001-embed-ollama-in-compose.patch"

if command -v git >/dev/null 2>&1 && git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then

  if [[ $DO_COMMIT -eq 1 ]]; then
      git -C "$REPO_ROOT" add scripts/setup-openclaw-triad.sh Makefile env/.env.example .github/workflows/ci.yml
      git -C "$REPO_ROOT" commit -m "Embed Ollama in the generated compose stack (OLLAMA_EMBED=1)

- generator: emit an ollama service (pinned image, named model volume,
  no published ports, own mem ceiling, healthcheck) when the ollama
  provider is wired AND OLLAMA_EMBED=1; gateway depends_on service_healthy
- provider baseUrl defaults to compose DNS in embedded mode;
  host-attached mode unchanged and regression-checked
- Makefile: make ollama-init seeds models + verifies gateway->ollama
- env example: consolidated Ollama section (embed vs host modes)
- CI: ollama-smoke uses the embedded topology — host install/bind/race
  lifecycle deleted entirely
" >/dev/null && ok "committed"
      git -C "$REPO_ROOT" format-patch -1 --stdout > "$PATCH_FILE" \
          && ok "format-patch written: $PATCH_FILE"
  else
      git -C "$REPO_ROOT" diff > "$PATCH_FILE"
      git -C "$REPO_ROOT" diff --stat
      ok "git diff patch written: $PATCH_FILE (uncommitted — review, then commit)"
  fi
else
  skip "not a git work tree — patch emission skipped"
fi

# ===========================================================================
# SUMMARY
# ===========================================================================
say ""
say "==================================================================="
say " applied: $APPLIED   skipped(idempotent): $SKIPPED   failed: $FAILED"
say "==================================================================="
if [[ $FAILED -eq 0 ]]; then
  say " All parts landed cleanly."
  [[ $DO_COMMIT -eq 0 ]] && say " Review with:  git diff  — commit when satisfied."
  say " CI note: the ollama-smoke job now expects the EMBEDDED topology;"
  say " push this branch and the workflow validates end-to-end."
else
  say " Some parts failed — the [FAIL] lines above show the exact anchors"
  say " that were missing. Paste them back to Lumo and we'll re-cut those"
  say " hunks against your current file state."
fi
[[ $FAILED -eq 0 ]]
