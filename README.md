# OpenClaw Triad — AI Trade Bot Orchestration

A three-agent trading council running on [OpenClaw](https://openclaw.com) inside a hardened Docker container, with NanoGPT as the model provider. Built for testnet first, paper second, live (small) last — the agents' own docs call these the **non-skippable milestones**.

---

## The Triad

Three agents, three positions, one chain of custody:

| Position | Role | Tools |
|---|---|---|
| **Scout** (roster #1) | Research and propose trades | read, write, exec, message |
| **Risk** (roster #2) | Validate or veto every proposal; co-sign approvals; treasury custodian | read, write, exec, message |
| **Judge** (roster #3) | Binding rulings on disputes; read-only by design | read, message |

The judge is read-only on purpose: *a mediator who can alter the record isn't a mediator.* Current production roster: `clawdina` (scout) / `clawde` (risk) / `thesource` (judge).

Personas (themes, temperaments, roles) live in each agent's `AGENTS.md` and `DREAMS.md` inside the workspace — not in the config schema, which rejects them.

Every decision is logged to append-only calibration CSVs in `shared/calibration/`. Retro-editing a record is the one unforgivable sin.

---

## Repository Layout

```
~/openclaw-orchestrate/
├── Makefile                      # orchestration entrypoint (v3)
├── README.md                     # this file
├── TAGS.md                       # pinned-tag lineage notes
├── env/
│   ├── .env.example              # shape-only template (committable)
│   └── .env.real-secrets         # your ACTUAL keys — gitignored, never commit
└── scripts/
    ├── setup-openclaw-triad.sh    # generator (v3.3) — emits the whole stack
    └── rebuild-openclaw.sh        # one-command from-scratch rebuild (v1.4+)

~/.openclaw/                      # STATE DIR (generated, mostly disposable)
├── .env                          # live secrets (seeded from stash)
├── openclaw.json                 # Gateway config (schema-valid, container paths)
├── Dockerfile / docker-compose.yml / docker.env
├── agents/<name>/agent/          # per-agent DB homes (DBs created at first boot)
├── workspace-triad/<name>/       # AGENTS.md, DREAMS.md, journal/
├── shared/                       # trading.json (testnet), calibration CSVs, GITGUIDE.md
├── plugins/telegram-bot/bot.py   # legacy Telegram fallback front-end
└── tmp/ state/ logs/             # runtime
```

The secrets stash (`env/.env.real-secrets`) lives **outside** the state dir so it survives `make wipe` and state-dir deletion. The rebuild script only ever fetches `Makefile` and `scripts/setup-openclaw-triad.sh` from the pinned tag — your stash is never clobbered.

---

## Specifying Models

The model lineup is **entirely `.env`-driven** since generator v3.3. No script edits, no sed surgery — edit `.env`, regenerate, restart.

### The two spelling rules (memorize these)

Two audiences read model names, and each expects a different spelling:

1. **Catalog ids** inside `providers.nanogpt.models` are **BARE** — `deepseek/deepseek-v4.1-flash-1017`. This is what NanoGPT's API expects.
2. **References** elsewhere (`primary`, `utilityModel`, `fallbacks`) are **`nanogpt/`-prefixed** — `nanogpt/deepseek/deepseek-v4.1-flash-1017`. This is what openclaw's router expects.

The generator and the rebuild's self-heals both enforce this automatically. In your `.env` you always write **bare ids**; the generator adds the prefix. A `nanogpt/nanogpt/` double prefix in the logs means something upstream regressed.

### The model variables

All in `~/.openclaw/.env`:

| Variable | Controls | Example value |
|---|---|---|
| `NANOGPT_MODEL_CATALOG` | The provider's catalog list (comma-separated). Entry format: `vendor/model-id` or `vendor/model-id\|Display Name` (display name defaults to the id's last segment) | `deepseek/deepseek-v4.1-flash-1017,z-ai/glm-5.3,z-ai/glm-5.3-flash-uncensored` |
| `TRIAD_SCOUT_MODEL` | Position default for the scout (roster #1) | `deepseek/deepseek-v4.1-flash-1017` |
| `TRIAD_RISK_MODEL` | Position default for risk/veto (roster #2) | `z-ai/glm-5.3` |
| `TRIAD_JUDGE_MODEL` | Position default for the judge (roster #3) | `z-ai/glm-5.3` |
| `UTILITY_MODEL` | Utility + fallback slot for all agents | `z-ai/glm-5.3-flash-uncensored` |
| `AGENT_<NAME>_MODEL` | Per-agent override (highest precedence) | `AGENT_THESOURCE_MODEL=z-ai/glm-5.3` |

**Precedence per agent:** `AGENT_<NAME>_MODEL` > `TRIAD_<POSITION>_MODEL` > builtin default.

### Worked example: switching to a DeepSeek/GLM subscription

If your NanoGPT subscription doesn't include the Claude/GPT lineup (as happened 2026-11-07), set in `.env`:

```bash
# Catalog: every model ANY agent will reference must appear here.
NANOGPT_MODEL_CATALOG=deepseek/deepseek-v4.1-flash-1017,z-ai/glm-5.3,z-ai/glm-5.3-flash-uncensored

# Seat assignment: fast scanner scouts, heavyweights guard and judge.
TRIAD_SCOUT_MODEL=deepseek/deepseek-v4.1-flash-1017
TRIAD_RISK_MODEL=z-ai/glm-5.3
TRIAD_JUDGE_MODEL=z-ai/glm-5.3
UTILITY_MODEL=z-ai/glm-5.3-flash-uncensored
```

Then apply:

```bash
cd ~/openclaw-orchestrate
make secrets-save        # persist the lineup (the stash captures all of .env)
make setup               # regenerate openclaw.json from .env
make docker-up           # recreate the container (config is read at boot)
```

Verify in the boot logs — each agent's line should show the new model, single-prefixed:

```
[gateway] agent model: nanogpt/deepseek/deepseek-v4.1-flash-1017 (thinking=medium, fast=off)
```

### Consistency guardrail

The generator cross-checks every model **reference** against the **catalog** and prints a loud `[!] ADVISORY` at generation time for any referenced model missing from the catalog. That's your early warning that the runtime may reject the model at transport time — fix the `.env`, not the generated file.

### Changing models on a running stack (emergency only)

If you can't regenerate right now, edit `~/.openclaw/openclaw.json` directly — catalog ids bare, references `nanogpt/`-prefixed — then `docker compose --env-file docker.env up -d --force-recreate`. But know that the next `make setup` overwrites your hand edit, so always land the change in `.env` afterwards.

---

## From-Scratch Bootstrap (the whole point)

Two supported paths:

### Path A — full rebuild, virgin Docker estate (recommended for clean slates)

```bash
cd ~/openclaw-orchestrate
make init               # seeds ~/.openclaw/.env from stash (or example)
make secrets-restore    # belt: ensure latest stash is live
OPENCLAW_PINNED_TAG=<tag> ./scripts/rebuild-openclaw.sh --fresh-vm --yes
```

The rebuild script does, in order: pinned-tag fetch → secrets backup → stop containers → delete colima VM → recreate VM (4 CPU / 6 GB) → flatten state dir → restore secrets → force guardrails (`BASE_IMAGE=node:24-slim`, `mem_limit=3g`) → `make setup` → self-heal generated files → **14-point inspection** → build → boot → first logs.

### Path B — regeneration only (state layout intact)

```bash
cd ~/openclaw-orchestrate
make setup              # regenerates config from .env
make docker-build && make docker-up
```

### Daily commands

```bash
make logs          # follow gateway logs
make status        # deployment + state health (incl. secrets stash)
make agents        # show roster + preset
make shell         # shell into the container
make docker-down   # stop (state preserved)
make secrets-save  # after editing .env — persist keys/lineup to the stash
make wipe          # DANGER: delete ALL state (requires typing WIPE)
```

---

## Environment Variables (`~/.openclaw/.env`)

| Variable | Purpose | Default |
|---|---|---|
| `NANOGPT_API_KEY` | Enables nanogpt provider wiring (models + refs) | — |
| `OPENCLAW_GATEWAY_TOKEN` | Gateway auth (auto-generated if absent) | random hex |
| `AGENT_ROSTER` | Exactly 3 names, comma-separated (scout,risk,judge) | seer,guardian,sage |
| `PERSONALITY_PRESET` | default \| mystic \| bold \| conservative \| quant | default |
| `NANOGPT_MODEL_CATALOG` | Provider catalog (see Specifying Models) | Claude/GPT lineup |
| `TRIAD_SCOUT/RISK/JUDGE_MODEL` | Position model defaults | Claude lineup |
| `UTILITY_MODEL` | Utility + fallback model | openai/gpt-5.4-mini |
| `AGENT_<NAME>_MODEL` | Per-agent override (wins over everything) | — |
| `TELEGRAM_BOT_TOKEN` | Telegram channel | — |
| `TELEGRAM_USER_ID` | Comma-separated allowlist of Telegram user IDs | — |
| `ELEVENLABS_API_KEY` | Per-agent TTS voices | — |
| `BASE_IMAGE` | Docker base image (**forced to node:24-slim**) | node:24-slim |
| `OPENCLAW_VERSION` | openclaw npm version | latest |
| `DOCKER_ENABLE` | Emit Docker files | true (via Makefile) |

---

## Telegram Setup

1. Put `TELEGRAM_BOT_TOKEN` and `TELEGRAM_USER_ID` (your numeric ID — ask `@userinfobot`) in `.env`.
2. After the gateway boots **successfully once**, register the channel:
   ```bash
   make telegram   # = docker exec -it openclaw-triad openclaw channels add telegram
   ```
3. Message your bot from the allowlisted account. Unauthorized senders are silently ignored (by design).

The legacy `plugins/telegram-bot/bot.py` (roster-aware slash commands) remains as a fallback if the runtime channel route is unavailable.

---

## Pinned Tags & Layer Discipline

The rebuild fetches `Makefile` + `scripts/setup-openclaw-triad.sh` from `OPENCLAW_PINNED_TAG` on GitHub and **overwrites local copies**. Consequence: **any local edit to those two files is temporary until committed and tagged.**

Release ritual:

```bash
cd ~/openclaw-orchestrate
git add -A && git commit -m "<change>"
TAG="$(date +%Y%m%d)-$(date +%H%M)"
git tag "$TAG" && git push origin HEAD --tags
# note the tag's purpose in TAGS.md
OPENCLAW_PINNED_TAG="$TAG" ./scripts/rebuild-openclaw.sh --no-build   # cheap full validation
```

If a fetch fails (`FETCH_MODE=auto`), the script falls back to the local copy and **warns** — watch for `[!!] ... using existing LOCAL copy` in Phase 0.

Tag names are opaque strings to git. Whatever you pick, just use it consistently in `OPENCLAW_PINNED_TAG`. Keep `TAGS.md` as the human-readable map.

---

## Troubleshooting Playbook (battle log)

Each of these was a real boot failure. All are fixed at the generator level as of v3.3.

| Symptom | Cause | Fix |
|---|---|---|
| Docker build: `unknown instruction &&` | sed-patch appended to a line-continuation chain in the Dockerfile | Guard `RUN rm -rf` is standalone; never sed-patch heredocs blind |
| Container boot: `not a directory` (OCI mount error) | Per-file `openclaw.json:ro` mount over a state-dir bind; or a config-shaped *directory* left in a cached image layer | Parent bind delivers the config; image-side `rm -rf` guard in Dockerfile |
| Build: `groupadd` exit code 4 | macOS GID 20 (`staff`) collides with Debian `dialout` | `getent group ... \|\| groupadd` idempotent guard |
| Container killed, **exit 137** | OOM: rss 1.6 GiB under a 2g cap with 16 workers | `mem_limit: 3g` inside the 6 GB colima VM |
| Startup: `suppressed ambient channel` for telegram | Env credentials present but no channel registered | `openclaw channels add telegram` (post-boot, once) |
| Config validation: *Unrecognized keys* `theme`, `role`, `bindings`, `swarm`; *agents.ownership* required | Generator emitted fields outside the runtime schema | v3.2 emits schema-valid config; personas live in AGENTS.md |
| Startup: `Unable to create fallback OpenClaw temp dir: /tmp/openclaw-<uid>` | `read_only` root fs; runtime refuses shared /tmp | Second tmpfs `/home/openclaw/.tmp` (uid-owned, 0700) + `TMPDIR` env |
| Startup: config rejected, host paths visible | Config had `/Users/...` paths inside a containerized runtime | All config paths are container paths; host paths only in compose/docker.env |
| Model transport errors / agents silent on reply | Referenced model not in the subscription or not in the catalog | v3.3 advisory warns at generation; fix `NANOGPT_MODEL_CATALOG` in `.env` |
| Agent-DB integrity gate in logs | State-dir sqlite inconsistency | `openclaw doctor --fix` via the run-command in the rebuild summary |
| Boot-race errors right after `[gateway] ready` | Concurrent discovery settling during subagent-recovery | Transient: check if they persist after ~5 min before investigating |

**Health confirmation:** `[gateway] ready` in logs, roster names registering, no `exit 137`, no restart-loop breaker, model-transport lines without `nanogpt/nanogpt/` double prefixes.

**First contact:**

```bash
docker exec -it openclaw-triad openclaw agent \
    --agent <scout> --message "Hello — introduce yourself in one sentence."
```

---

## Trading Milestones (non-skippable)

1. **TESTNET** — four weeks, zero unlogged manual interventions. `shared/trading.json` ships in `"mode": "testnet"` for exactly this reason.
2. **PAPER** — four weeks of positive expectancy on simulated fills.
3. **LIVE (small)** — only when all three agents align on readiness, at limits genuinely affordable to lose.

Weekly ritual: each agent reviews its calibration hit-rate from `shared/calibration/<name>-decisions.csv`; miscalibration gets journaled, never silently corrected. A dead-broke and a broken system look identical from the logs — check the NanoGPT balance alongside.

---

## Version History

| Component | Version | Milestone |
|---|---|---|
| setup-openclaw-triad.sh | v3.3 | Env-driven model catalog + position defaults; catalog/reference consistency advisories |
| rebuild-openclaw.sh | v1.4 | 14-point inspection; json:ro heal; config regular-file assertion |
| Makefile | v3 | Secrets stash lifecycle (save/restore); telegram target; status shows stash |
