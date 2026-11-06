# OpenClaw Triad Orchestrator

Infrastructure-as-code for a three-agent trading triad (scout / risk / arbiter), built on the OpenClaw gateway and NanoGPT model routing.

**This directory is version-controlled. Runtime state lives elsewhere.**

---

## The Separation Principle

```
~/openclaw-orchestrate/          ← YOU EDIT THIS. Git-tracked. Portable.
├── Makefile                     ← Commands: make setup, make docker-build, make logs
├── README.md                    ← This file
├── scripts/
│   ├── setup-openclaw-triad.sh  ← Generator (v2.5, idempotent, re-runnable)
│   └── rebuild-openclaw.sh      ← One-command full rebuild + validation
└── env/
    └── .env.example             ← Template for secrets

~/.openclaw/                     ← MACHINE-GENERATED. Git-ignored. Disposable.
├── openclaw.json                ← Generated (JSON5, gateway.mode=local)
├── .env                         ← YOUR SECRETS (chmod 600)
├── docker-compose.yml           ← Generated (whole-state-dir mount)
├── Dockerfile                   ← Generated (node:24-slim + openclaw runtime)
├── docker.env                   ← Generated (no secrets, safe to commit)
├── requirements.txt            ← Python plugin deps (telegram bot etc.)
├── agents/                      ← Agent runtime state (sqlite transcripts)
├── workspace-triad/             ← Agent markdown + journals
├── plugins/                     ← Trading logic + telegram bot
├── shared/                      ← Append-only ledgers, calibration
├── state/                       ← Gateway sqlite (created at runtime)
├── tmp/                         ← Runtime lock/lease files
└── logs/
```

**Why separate them?**

| Concern | Orchestrator | State dir |
|---|---|---|
| Version control | ✅ Yes | ❌ No |
| Backup priority | Low (regenerable) | **High** (irreplaceable) |
| Machine-specific | ❌ No | ✅ Yes |
| Contains secrets | ❌ No | ✅ Yes |
| Can be deleted safely | ✅ Yes | ❌ Never |

The orchestrator is *recipe*. The state dir is *cake*. You can hand the recipe to anyone; the cake is yours.

---

## Quick Start

### 1. Set up the orchestrator

```bash
mkdir -p ~/openclaw-orchestrate/{scripts,env}
cd ~/openclaw-orchestrate
# Save setup-openclaw-triad.sh (v2.5), rebuild-openclaw.sh, and the Makefile (v2)
# from their sources into scripts/ and the repo root
chmod +x scripts/*.sh
```

### 2. Full from-scratch rebuild (recommended first path)

```bash
./scripts/rebuild-openclaw.sh --fresh-vm
```

This single command: backs up secrets → stops containers → recreates the colima VM virgin → deletes the state dir → scrubs stale overrides (e.g. legacy `BASE_IMAGE=python…`) → generates the stack → runs a **five-point inspection** (getent guard, node base, gateway.mode, correct CMD, roster wiring) → builds the image → boots the Gateway → prints the first logs.

Any inspection check fails, it aborts **before** the expensive build. No wasted npm layers.

### 3. Manual path (equivalent)

```bash
cd ~/openclaw-orchestrate
make init          # seed .env from template if absent
nano ~/.openclaw/.env   # NANOGPT_API_KEY, OPENCLAW_GATEWAY_TOKEN, AGENT_ROSTER…
make setup         # regenerate the whole state tree
make docker-build  # node:24-slim + openclaw runtime (long: apt + npm)
make docker-up     # boot the Gateway
make logs          # watch it start
```

Minimum viable `.env`:
```bash
NANOGPT_API_KEY=sk-nanogpt-xxxxxxxxxxxx
OPENCLAW_GATEWAY_TOKEN=<openssl rand -hex 32>
AGENT_ROSTER=seer,guardian,sage
PERSONALITY_PRESET=mystic
```

---

## Environment Requirements

| Requirement | Notes |
|---|---|
| macOS or Linux | macOS stock Bash 3.2 supported (no Bash 4+ syntax anywhere) |
| Docker backend | **colima** + Homebrew `docker`/`docker-compose` CLI, or Docker Desktop |
| Compose | v2 (`docker compose`, with space) preferred; v1 tolerated |
| Node | Only inside the container (node:24-slim base) — host Node not required |

### Colima setup (Homebrew-native backend)

```bash
brew install docker docker-compose colima
mkdir -p ~/.docker/cli-plugins
ln -sfn $(brew --prefix)/opt/docker-compose/bin/docker-compose ~/.docker/cli-plugins/docker-compose
colima start --cpu 4 --memory 4   # headroom matters for npm build steps
```

Colima doesn't auto-start at login unless you arrange it: `brew services start colima`.

### Migrating away from Docker Desktop

Quit and kill Desktop (`osascript -e 'quit app "Docker Desktop"'`, then `sudo pkill -9 -f com.docker`), remove `/Applications/Docker.app`, the symlinks in `/usr/local/bin`, `~/.docker`, and the `~/Library` support dirs. The image cache dies with the VM — that's fine; host-side state in `~/.openclaw` is untouched (recipe/cake split). Then install the colima stack above.

---

## Roster & Positions

`AGENT_ROSTER=seer,guardian,sage` drives **everything**: directories, config entries, Telegram commands, env var prefixes (`AGENT_SEER_THEME`…), docs. Names are yours to choose; **positions are fixed by order**:

| Position | Name | Role | Permissions |
|---|---|---|---|
| 1 | first roster name | scout — proposes trades | write/exec, delegates to 2 and 3 |
| 2 | second roster name | risk — validates/vetoes | write/exec |
| 3 | third roster name | arbiter — binding rulings | **read-only** |

Swapping names in the roster swaps identities, not roles — the first entry is always the proposer, the third is always the read-only judge.

### Personality presets

| Preset | Scout | Risk | Arbiter | Risk defaults |
|---|---|---|---|---|
| `default` | sassy oracle fox | steady guardian wolf | wise mediator owl | 5% pos / 15% daily / 20 trades |
| `mystic` | purple lotus fox | golden wolf | silver owl | 5% / 15% / 20 |
| `bold` | crimson comet fox | iron mastiff | storm eagle | 7% / 20% / 30 |
| `conservative` | grey heron | granite tortoise | dawn hermit | 3% / 10% / 10 |
| `quant` | chrome pointer | matrix weasel | proof raven | 5% / 15% / 40 |

Per-agent overrides: `AGENT_{NAME}_THEME`, `_ROLE`, `_MODEL`, `_THINKING`.

---

## Feature Matrix

Features activate automatically when their keys are present. No key, no feature, no broken config.

| Feature | Trigger env var | What it adds |
|---|---|---|
| **NanoGPT models** | `NANOGPT_API_KEY` | Required. All agent reasoning. |
| **Gateway auth** | `OPENCLAW_GATEWAY_TOKEN` | Required in containers (refuses unauthenticated non-loopback bind). `openssl rand -hex 32` |
| **ElevenLabs TTS** | `ELEVENLABS_API_KEY` | Per-agent voice in `openclaw.json` |
| **Telegram bot** | `TELEGRAM_BOT_TOKEN` | `plugins/telegram-bot/bot.py` + roster-derived commands |
| **Polymarket live** | `POLYMARKET_API_KEY` | Real order routing (else testnet stubs) |
| **Crypto treasury** | `WALLET_PRIVATE_KEY` | Wallet config + audit log |
| **Docker** | `DOCKER_ENABLE=true` / `make docker-*` | Dockerfile, compose, docker.env |

### Wallet configuration

Exactly one currency. The named agent becomes custodian (defaults to the risk-position agent — giving the treasury to the impulsive scout is a category error).

```bash
WALLET_TYPE=btc              # btc | xmr | eth
WALLET_PRIVATE_KEY=...
WALLET_AGENT=guardian        # must be a roster member
```

Security posture in the generated config: key read from environment only, all operations appended to `logs/wallet.log`, withdrawals require explicit human approval (`max_auto_withdrawal_usd: 0`), cold storage recommended for anything meaningful.

---

## Model Configuration

Defaults favour economics: cheaper model for scanning, stronger model for judgement.

```bash
# Per-position model defaults (used when no AGENT_{NAME}_MODEL override)
CLAWDIA_MODEL=anthropic/claude-sonnet-4-6    # scout
CLAWDIO_MODEL=anthropic/claude-opus-4-6      # risk
ARBITER_MODEL=anthropic/claude-opus-4-6      # arbiter
UTILITY_MODEL=openai/gpt-5.4-mini            # cheap housekeeping + fallback

# Preferred: explicit per-agent overrides
AGENT_SEER_MODEL=anthropic/claude-sonnet-4-6
AGENT_GUARDIAN_MODEL=anthropic/claude-opus-4-6
AGENT_SAGE_MODEL=anthropic/claude-opus-4-6
```

Swap freely — NanoGPT routes to whichever provider hosts the model. Check available IDs: `GET https://nano-gpt.com/api/v1/models`.

---

## Governance Model

The triad is not decorative. It encodes a decision procedure.

```
Scout proposes    ──┐
                    ├──► Aligned?  ──► Execute
Risk validates   ──┘

                    ┌──► Disagree? ──► Arbiter rules ──► Execute (modified) or Stand down
```

**Invariant:** no single agent executes alone. Either scout and risk agree, or the arbiter resolves the dispute. There is no third path. This is enforced by tool permissions in `openclaw.json`:

- scout & risk: read/write/exec/message — but neither approves alone
- arbiter: read and message only. **A mediator who can alter the record isn't a mediator.** Write access would let him fabricate consensus.

`swarm: false` on purpose: emergent multi-agent behaviour is fascinating and unpredictable. When real money is moving, predictable beats clever.

---

## Docker Security Posture

The generated container is locked down by default:

| Measure | Effect |
|---|---|
| Non-root user, host-matched uid/gid | Bind mounts writable; no privilege escalation |
| `getent`-guarded groupadd | macOS GID 20 (staff) collides with Debian's — reuses instead of failing |
| `cap_drop: ALL` | No Linux capabilities |
| `no-new-privileges` | Cannot gain privileges via setuid |
| `read_only: true` rootfs | Immutable container filesystem |
| tmpfs with explicit `uid`/`gid` | Root-owned tmpfs breaks the runtime's secure-temp check — must be user-owned |
| Whole state dir mounted | Runtime needs `tmp/`, sqlite state, lease locks — piecemeal mounts starve it |
| Config mounted `:ro` on top | Container consumes config, never rewrites it |
| `mem_limit` / `cpus` | Resource ceilings prevent runaway loops |
| Log rotation | 10MB × 3 files |

The image contains the OpenClaw runtime itself (`npm install -g openclaw@<version>` on `node:24-slim`, per docs.openclaw.ai/install) plus python3 for plugin tooling. Everything else arrives as bind mounts.

Pin the runtime with `OPENCLAW_VERSION=2026.x.y` in `.env` for reproducible builds.

---

## Development Timeline (non-skippable milestones)

Encoded in each agent's `DREAMS.md`:

1. **Testnet** — 4 weeks, zero unlogged manual interventions. `"mode": "testnet"` ships in `trading.json` for exactly this reason.
2. **Paper** — 4 weeks, positive expectancy on simulated fills.
3. **Live capital (small)** — only with all three agents aligned on readiness, and only at risk limits you can genuinely afford to lose.

Weekly ritual: each agent reviews its `shared/calibration/<name>-decisions.csv` hit rate; miscalibration is noted in `journal/`, never silently corrected.

---

## Backup Strategy

**Back up the state dir. Regenerate the orchestrator from git.**

```bash
tar czf ~/backups/openclaw-$(date +%F).tar.gz \
  -C ~ .openclaw/agents \
       .openclaw/workspace-triad \
       .openclaw/shared \
       .openclaw/.env

# Irreplaceable:
#   agents/          → session transcripts, memory
#   workspace-triad/ → journals, calibration, wallet config
#   shared/          → trade ledger (append-only, never reconstructable)
#   .env             → secrets
```

Moving machines: restore the tar, `rsync` the orchestrator, re-run `make setup && make docker-build` (uid/gid recapture is automatic).

---

## Troubleshooting

Everything below was learned the hard way, live, against the real runtime. The rebuild script pre-empts most of it.

**`groupadd: GID '20' already exists` (exit 4)**
macOS primary GID is 20 (staff); Debian base images already use GID 20 (dialout). Fixed in the generated Dockerfile with a `getent group || groupadd` guard. If you see it, your Dockerfile predates v2.4 — regenerate.

**`npm: not found` at the npm install step**
The base image isn't Node — almost always a stale `BASE_IMAGE=python:3.11-slim` left in `.env` or `docker.env` from an earlier architecture. `rebuild-openclaw.sh` scrubs this line automatically; manually: `sed -i '' '/^BASE_IMAGE=python/d' ~/.openclaw/.env`.

**`Invalid config: Unrecognized key "memory" / "web"`**
Those keys aren't in the current schema. Removed in v2.5; don't re-add them.

**`Gateway start blocked: missing gateway.mode`**
Admission check. Config now ships `gateway: { mode: "local" }`.

**`Unsafe fallback OpenClaw temp dir … EACCES`**
The `.cache` tmpfs is root-owned by default; the runtime requires a user-owned 0700 private dir. Fixed via tmpfs mount options `uid=${APP_UID},gid=${APP_GID}`.

**`Refusing to bind gateway to auto without auth`**
Container default binds 0.0.0.0; the Gateway refuses unauthenticated exposure. Set `OPENCLAW_GATEWAY_TOKEN=$(openssl rand -hex 32)` in `.env` — the rebuild script generates one if absent.

**`OpenClaw does not know the command "start"`**
There is no `openclaw start`. The entrypoint is `openclaw gateway`. Fixed in v2.5.

**`${ROSTER_RAW,,}: bad substitution`**
Bash 4+ syntax on macOS's frozen Bash 3.2. All scripts are now 3.2-safe (`tr`/`awk` for case conversion). Alternatively `brew install bash`.

**Container crash-looping / `restart-loop breaker tripped`**
Previous failed boots accumulate. On a clean state dir this won't occur. To recover manually: `docker compose down && up`, or `rebuild-openclaw.sh` (a fresh state dir and `--fresh-vm` resets the breaker's history completely).

**`make setup` ignored my AGENT_ROSTER**
You're on the v1 Makefile, which hand-enumerated variables and dropped the rest. v2 sources the whole `.env` (`set -a && . .env && set +a`) so every variable reaches the generator.

**Agents registered as clawdia/clawdio/arbiter despite my roster**
The stack was generated before `AGENT_ROSTER` was set, or with the v1 Makefile. Set the roster in `.env` and re-run `make setup`.

**Cannot connect to the Docker daemon**
colima isn't running: `colima start` (every boot, unless you've enabled `brew services start colima`).

---

## Extending

**Add a preset:** add a block to the `case "$PERSONALITY_PRESET"` sections in the generator (themes, roles, risk numbers, temperament note).

**Add a per-agent knob:** follow the `AGENT_{NAME}_*` pattern — add the variable to `usage()`, an accessor if needed, and a line in `.env.example` generation.

**Add an optional feature:** add a `USE_<FEATURE>` toggle, a `detect_features()` line, and a `generate_<feature>()` function. Every optional feature is self-contained.

**Add a fourth agent:** bump the roster length check in the generator, add position-4 permissions (decide what position 4 *means* before granting it anything), extend bindings, re-run `make setup`. Think hard before giving anything write access — the read-only-arbiter invariant is the system's spine.

---

## Design Notes

**Why a generator instead of committed config?** Config contains machine-specific values (paths, uid/gid, endpoints). Committing generated config means merge conflicts and stale paths; committing the *generator* means one source of truth that produces correct output everywhere.

**Why `docker.env` committable but `.env` not?** `docker.env` holds interpolation variables — paths, uids, limits, no credentials. `.env` holds keys. Share topology without leaking secrets.

**Why does the arbiter have no write access?** He rules, he doesn't touch. His job is to read both agents' reasoning via `sessions_history` and issue binding rulings. Write access would let him forge the consensus he's arbitrating.

**Why the five-point inspection?** Because a failure discovered after a ten-minute npm build costs ten minutes, and a failure discovered in a grep costs ten seconds. Fail fast, fail cheap.

**Why scrub stale overrides?** The worst bugs in this project weren't missing pieces — they were *survivors*: a python `BASE_IMAGE` from an old architecture silently defeating a correct generator default. Regeneration must not inherit ghosts.

---

## License & Disclaimer

This is infrastructure scaffolding for an experimental trading system.

**It trades real money if you let it.** Start on testnet. The generated `trading.json` ships with `"mode": "testnet"` for a reason. Change that only after sustained paper-trading success across both milestone phases.

Nothing here is financial advice. The risk limits encoded (5% max position, 15% daily loss, 2:1 minimum R/R as defaults) are starting points, not recommendations. Set them to numbers you can genuinely afford to lose.

---

*Built for Nolimitus Maximus — Conscious Traveller / Raver*
*Purpose: passive income funding exploration, not accumulation for its own sake*