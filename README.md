# OpenClaw Triad — AI Trade Bot Orchestration

A three-agent trading council running on [OpenClaw](https://openclaw.com) inside a hardened Docker container, with NanoGPT as the model provider. Built for testnet first, paper second, live (small) last — the agents' own docs call these the **non-skippable milestones**.

---

## The Triad

Three agents, three positions, one chain of custody:

| Position | Role | Tools | Model (default) |
|---|---|---|---|
| **Scout** (roster #1) | Research and propose trades | read, write, exec, message | Claude Sonnet 4.6 |
| **Risk** (roster #2) | Validate or veto every proposal; co-sign approvals; treasury custodian | read, write, exec, message | Claude Opus 4.6 |
| **Judge** (roster #3) | Binding rulings on disputes; read-only by design | read, message | Claude Opus 4.6 |

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
    ├── setup-openclaw-triad.sh    # generator (v3.2) — emits the whole stack
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
make secrets-save  # after editing .env — persist keys to the stash
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
| `TELEGRAM_BOT_TOKEN` | Telegram channel | — |
| `TELEGRAM_USER_ID` | Comma-separated allowlist of Telegram user IDs | — |
| `ELEVENLABS_API_KEY` | Per-agent TTS voices | — |
| `AGENT_<NAME>_MODEL` | Per-agent model override | position defaults |
| `BASE_IMAGE` | Docker base image (**forced to node:24-slim**) | node:24-slim |
| `OPENCLAW_VERSION` | openclaw npm version | latest |
| `DOCKER_ENABLE` | Emit Docker files | true (via Makefile) |

**Model spelling rules (two audiences):** catalog ids inside the provider list are BARE (`anthropic/claude-sonnet-4-6` — that's what NanoGPT's API expects); model *references* elsewhere are `nanogpt/`-prefixed (that's what openclaw's router expects). The generator and the rebuild's self-heals both enforce this; a double prefix (`nanogpt/nanogpt/`) in the logs means one of them regressed.

---

## Telegram Setup

1. Put `TELEGRAM_BOT_TOKEN` and `TELEGRAM_USER_ID` (your numeric ID — ask `@userinfobot`) in `.env`.
2. After the gateway boots **successfully once**, register the channel:
   ```bash
   make telegram   # = docker exec -it openclaw-triad openclaw channels add telegram
   ```
3. Message your bot from the allowlisted account. Unauthorized senders are silently ignored (by design).

The legacy `plugins/telegram-bot/bot.py` (roster-aware slash commands: `/clawdina hello`) remains as a fallback if the runtime channel route is unavailable.

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

Each of these was a real boot failure. All are fixed at the generator level as of v3.2.

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
| Agent-DB integrity gate in logs | State-dir sqlite inconsistency | `openclaw doctor --fix` via the run-command in the rebuild summary |
| Boot-race errors right after `[gateway] ready` (`usage-cost-cache`, `AgentDatabaseRegistryChangedError`) | Concurrent discovery settling during subagent-recovery | Transient: check if they persist after ~5 min before investigating |

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
| setup-openclaw-triad.sh | v3.2 | Schema-valid config; .tmp tmpfs + TMPDIR; verbatim names; runtime-channel Telegram |
| rebuild-openclaw.sh | v1.4 | 14-point inspection; json:ro heal; config regular-file assertion |
| Makefile | v3 | Secrets stash lifecycle (save/restore); telegram target; status shows stash |
