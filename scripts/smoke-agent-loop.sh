#!/usr/bin/env bash
# smoke-agent-loop.sh — OLLAMA_ONLY mechanics smoke. Not a quality test.
#
# Asserts PLUMBING only: provider answers on the OpenAI endpoint, one
# agent turn completes without timeout/error, config+ledger surfaces
# respond. Never asserts judgment quality — qwen3:0.6b would fail that
# and SHOULD fail that. Judgment belongs to the calibration phase with
# production models.
#
# Bash 3.2 safe. set -u strict: every knob has a default.
set -euo pipefail

STATE_DIR="${OPENCLAW_STATE_DIR:-${HOME}/.openclaw}"
CFG="${STATE_DIR}/openclaw.json"
AGENT="${SMOKE_AGENT:-seer}"
MESSAGE="${SMOKE_MESSAGE:-State your role in one short line.}"
TIMEOUT_S="${SMOKE_TIMEOUT:-120}"

# --- 1. Static asserts on the generated config ---------------------------
# NB: the runtime normalizes openclaw.json at boot (quotes keys), so
# key-shape greps must accept BOTH dialects — pre-boot and post-boot.
test -f "$CFG"
grep -Eq '"?ollama"?:[ ]*\{' "$CFG" || { echo "FAIL: no ollama provider in config" >&2; exit 1; }
grep -q 'primary: "ollama/qwen3' "$CFG" || { echo "FAIL: no ollama refs in agents" >&2; exit 1; }
grep -q 'utilityModel: "ollama/qwen3' "$CFG" || { echo "FAIL: no ollama utility ref" >&2; exit 1; }
if grep -q 'nanogpt' "$CFG"; then
    echo "FAIL: nanogpt leaked into ollama-only config" >&2
    exit 1
fi
if grep -Eq 'nanogpt/ollama|ollama/ollama' "$CFG"; then
    echo "FAIL: double-prefixed model ref in config" >&2
    exit 1
fi
# --- 2. Provider endpoint answers (OpenAI-compat shape) -------------------
# Embedded topology: NO published ports — probe from INSIDE the triad
# container against compose DNS (node fetch; the image has no curl).
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx openclaw-triad; then
    timeout "${SMOKE_TIMEOUT:-120}" docker exec openclaw-triad node -e '
        fetch("http://ollama:11434/v1/chat/completions", {
          method: "POST",
          headers: {"Content-Type": "application/json"},
          body: JSON.stringify({
            model: process.argv[1],
            messages: [{role: "user", content: "reply with the single word: ok"}],
            stream: false
          })
        }).then(async r => {
          const t = await r.text();
          process.exit(t.includes("\u0022choices\u0022") ? 0 : 1);
        }).catch(() => process.exit(1));
    ' "${SMOKE_MODEL:-qwen3:0.6b}" || { echo "FAIL: embedded ollama probe failed" >&2; exit 1; }
    echo "   [ok] embedded provider answered from inside the network"
else
    # Host-attached fallback: curl the host-published daemon as before.
    resp="$(curl -sf --max-time 10 "${OLLAMA_HOST_BASE:-http://localhost:11434/v1}/chat/completions" \
        -H 'Content-Type: application/json' \
        -d "{\"model\": \"${SMOKE_MODEL:-qwen3:0.6b}\", \"messages\": [{\"role\": \"user\", \"content\": \"reply with the single word: ok\"}], \"stream\": false}")" \
        || { echo "FAIL: no response from provider" >&2; exit 1; }
    echo "$resp" | grep -q '"choices"' || { echo "FAIL: no choices in response" >&2; exit 1; }
fi

# --- 3. Agent round-trip ---------------------------------------------------
# In-container invocation (the same path Telegram/plugins use at runtime).
if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx openclaw-triad; then
    echo "--- smoke: container up, exercising in-container agent turn ---"
    timeout "$TIMEOUT_S" docker exec openclaw-triad openclaw agent \
        --agent "$AGENT" --message "$MESSAGE" || {
            echo "FAIL: agent turn timed out or errored (${TIMEOUT_S}s)" >&2
            exit 1
        }
    echo "SMOKE OK (container round-trip)"
elif [[ -x "/usr/local/bin/openclaw" || -n "$(command -v openclaw || true)" ]]; then
    # Host-mode fallback (gateway booted on host, not container)
    echo "--- smoke: no container, attempting host-side agent turn ---"
    timeout "$TIMEOUT_S" openclaw agent --agent "$AGENT" --message "$MESSAGE" || {
        echo "FAIL: host agent turn failed (${TIMEOUT_S}s)" >&2
        exit 1
    }
    echo "SMOKE OK (host round-trip)"
else
    echo "SKIP: no container and no host openclaw binary — static asserts only" >&2
fi