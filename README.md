# OpenClaw Triad Orchestrator

Infrastructure-as-code for a **fully customizable** AI trading triad.

**This directory is version-controlled. Runtime state lives elsewhere.**

---

## The Separation Principle

```
~/openclaw-orchestrate/          ← YOU EDIT THIS. Git-tracked. Portable.
├── Makefile                     ← Commands: make setup, make up, make logs
├── README.md                    ← This file
├── scripts/
│   └── setup-openclaw-triad.sh  ← Generator (idempotent, re-runnable, fully customizable)
└── env/
    └── .env.example             ← Template with customization section

~/.openclaw/                     ← MACHINE-GENERATED. Git-ignored. Disposable.
├── openclaw.json                ← Generated from your env vars + agent roster
├── .env                         ← YOUR SECRETS (chmod 600)
├── docker-compose.yml           ← Generated
├── Dockerfile                   ← Generated
├── docker.env                   ← Generated (no secrets, safe to commit)
├── agents/                      ← Runtime state (sqlite transcripts)
├── workspace-triad/             ← Agent markdown + journals
├── plugins/                     ← Trading logic
├── shared/                      ← Append-only ledgers
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

# Save the setup script
# (place setup-openclaw-triad.sh in scripts/)
chmod +x scripts/setup-openclaw-triad.sh

# Save the env template
# (place .env.example in env/)
```

### 2. Configure your secrets

```bash
cp env/.env.example ~/.openclaw/.env 2>/dev/null || {
  mkdir -p ~/.openclaw
  cp env/.env.example ~/.openclaw/.env
}
chmod 600 ~/.openclaw/.env
nano ~/.openclaw/.env
```

**Minimum viable config:**
```bash
NANOGPT_API_KEY=sk-nanogpt-xxxxxxxxxxxx
```

**To customize your agent roster (optional):**
```bash
AGENT_ROSTER=seer,sentinel,judge
PERSONALITY_PRESET=mystic
```

### 3. Generate the stack

```bash
make setup
```

This reads your `.env`, auto-detects which optional features are enabled, and generates the entire `~/.openclaw/` tree — including agent directories, SOUL.md files, and Telegram routing — based on your roster and presets.

### 4. Deploy with Docker

```bash
make docker-build
make docker-up
make status
```

### 5. Watch it run

```bash
make logs
```

---

## Make Targets

| Target | What it does |
|---|---|
| `make init` | Create directory structure, fetch scripts, seed `.env` |
| `make setup` | Run the generator with current env vars (re-runnable, idempotent) |
| `make docker-build` | Build the container image |
| `make docker-up` | Start the triad |
| `make docker-down` | Stop containers (state preserved) |
| `make clean` | Remove containers + images (state preserved) |
| `make wipe` | **DANGER** — removes all state (requires typed confirmation) |
| `make logs` | Follow container logs live |
| `make logs-system` | Last 100 lines |
| `make shell` | Bash into the running container |
| `make status` | Show containers + state directory health |
| `make help` | Full command reference |

---

## Agent Customization

The triad is now **fully parameterized**. Override names, roles, themes, models, and personalities.

### Environment Variables

| Variable | Purpose | Default |
|---|---|---|
| `AGENT_ROSTER` | Comma-separated agent names | `clawdia,clawdio,arbiter` |
| `PERSONALITY_PRESET` | Quick-start archetype pack | `default` |
| `AGENT_{NAME}_THEME` | Visual/personality description | (from preset or "custom agent") |
| `AGENT_{NAME}_ROLE` | Functional role description | (auto-assigned by index) |
| `AGENT_{NAME}_MODEL` | Model override for agent | (legacy vars or utility model) |
| `AGENT_{NAME}_THINKING` | Reasoning depth: `light\|medium\|high` | `medium` |

### Personality Presets

| Preset | Agent 1 | Agent 2 | Agent 3 |
|---|---|---|---|
| `default` | Sassy Oracle | Steady Guardian | Wise Mediator |
| `bold` | Reckless Visionary | Impulse Trader | Momentum Hunter |
| `conservative` | Risk Sentinel | Capital Warden | Loss Avenger |
| `mystic` | Intuitive Seer | Dream Reader | Probability Monk |
| `quant` | Data Hermit | Statistical Phantom | Arbitrage Ghost |

**Examples:**

```bash
# Mystic trio with custom names
export AGENT_ROSTER="seer,dreamer,monk"
export PERSONALITY_PRESET=mystic
./scripts/setup-openclaw-triad.sh
```

```bash
# Bold gambler triad
export AGENT_ROSTER="highroller,hunchman,casino"
export PERSONALITY_PRESET=bold
export AGENT_HIGHROLLER_THEME="neon-soaked visionary chasing streaks"
export AGENT_HUNCHMAN_THEME="gut-instinct oracle ignoring charts"
./scripts/setup-openclaw-triad.sh
```

```bash
# Quant precision team
export AGENT_ROSTER="analyst,statistician,frequency"
export PERSONALITY_PRESET=quant
export ANALYST_MODEL=deepseek/deepseek-v3.2
export STATISTICIAN_THINKING=high
./scripts/setup-openclaw-triad.sh
```

### Per-Agent Overrides

Override any preset with explicit declarations:

```bash
AGENT_ROSTER=oracle,risk,arbiter
AGENT_ORACLE_THEME="purple holographic fox with crimson claws"
AGENT_ORACLE_ROLE="Opportunity Scout — finds edges, generates signals"
AGENT_ORACLE_MODEL=anthropic/claude-sonnet-4-6
AGENT_ORACLE_THINKING=medium

AGENT_RISK_THEME="navy guardian wolf with silver spectacles"
AGENT_RISK_ROLE="Capital Warden — enforces loss limits, protects downside"
AGENT_RISK_MODEL=anthropic/claude-opus-4-6
AGENT_RISK_THINKING=high
```

These populate directly into `openclaw.json`, SOUL.md, and AGENTS.md.

---

## Governance Model

The triad encodes a **decision procedure**, not decorative multi-agent theatre.

### Default Roster (Clawdia/Clawdio/Arbiter)

```
Clawdia proposes  ──┐
                    ├──► Aligned?  ──► Execute
Clawdio validates ──┘

                    ┌──► Disagree? ──► Arbiter rules ──► Execute (modified) or Stand down
```

**Invariant:** No single agent executes alone. Either Clawdia and Clawdio agree, or the Arbiter resolves the dispute. There is no third path.

This is enforced by tool permissions in `openclaw.json`:
- Clawdia can write/edit/exec but has no execution authority alone
- Clawdio can read/write/exec but his approval isn't sufficient alone
- Arbiter can only read and message — he rules, he doesn't touch

### Custom Rosters

With dynamic rosters, the pattern adapts:

- **First agent** (index 0) = System Agent — can spawn subagents, initiates proposals
- **Second agent** (index 1) = Heartbeat Agent — risk validation, capital guard
- **Remaining agents** — tiebreakers or domain specialists

Disputes escalate to the **highest-indexed agent**, whose ruling is binding.

**Example 4-agent roster:**
```
Agent 1 (seer) → Agent 2 (sentinel) → Aligned? ──► Execute
                                                      │
Disagreement ──► Agent 3 (judge) → Ruling ────────────┤
                                                      ▼
                                                Agent 4 (final)
```

---

## Feature Matrix

Features activate automatically when their keys are present. No key, no feature, no broken config.

| Feature | Trigger env var | What it adds |
|---|---|---|
| **NanoGPT models** | `NANOGPT_API_KEY` | Required. All agent reasoning. |
| **ElevenLabs TTS** | `ELEVENLABS_API_KEY` | Per-agent voice in `openclaw.json` |
| **Telegram bot** | `TELEGRAM_BOT_TOKEN` | `plugins/telegram-bot/bot.py` with dynamic routing |
| **Polymarket live** | `POLYMARKET_API_KEY` | Real order routing (else testnet stubs) |
| **Crypto treasury** | `WALLET_PRIVATE_KEY` | `wallet_manager.py` + audit log |
| **Docker** | `--docker` flag | Dockerfile, compose, docker.env |

### Wallet Configuration

Exactly one currency. The named agent becomes custodian.

```bash
WALLET_TYPE=xmr              # btc | xmr | eth
WALLET_PRIVATE_KEY=...
WALLET_AGENT=clawdio         # Must match a name in AGENT_ROSTER
```

**Why Clawdio by default?** He's the capital-preservation archetype. Giving the treasury to the impulsive one is a category error.

**Security posture in the generated config:**
- Key read from environment, never written to disk
- All operations appended to `logs/wallet.log`
- Withdrawals require explicit human approval (`max_auto_withdrawal_usd: 0`)
- Cold storage recommended for anything meaningful

---

## Model Configuration

Defaults favour economics: cheap model for scanning, expensive model for judgement.

```bash
CLAWDIA_MODEL=anthropic/claude-sonnet-4-6    # Fast scanner
CLAWDIO_MODEL=anthropic/claude-opus-4-6      # Deep risk analysis
ARBITER_MODEL=anthropic/claude-opus-4-6      # Careful arbitration
UTILITY_MODEL=openai/gpt-5.4-mini            # Cheap housekeeping
```

Swap freely — NanoGPT routes to whichever provider hosts the model:

```bash
CLAWDIO_MODEL=deepseek/deepseek-v3.2
ARBITER_MODEL=moonshotai/kimi-k2.5
CLAWDIA_MODEL=google/gemini-flash-latest
```

**Per-agent overrides:**
```bash
AGENT_SEER_MODEL=anthropic/claude-sonnet-4-6
AGENT_SENTINEL_MODEL=deepseek/r1-distilled
AGENT_JUDGE_MODEL=anthropic/claude-opus-4-6
```

Check available IDs: `GET https://nano-gpt.com/api/v1/models`

---

## Docker Security Posture

The generated container is locked down by default:

| Measure | Effect |
|---|---|
| Non-root user, host-matched uid/gid | Bind mounts stay writable; no privilege escalation |
| `cap_drop: ALL` | No Linux capabilities at all |
| `no-new-privileges` | Cannot gain privileges via setuid |
| `read_only: true` rootfs | Container filesystem is immutable |
| `tmpfs` for `/tmp`, `/var/tmp`, `~/.cache` | Writable scratch, size-capped |
| Config mounted `:ro` | Container consumes config, never rewrites it |
| `mem_limit` / `cpus` | Resource ceilings prevent runaway loops |
| Log rotation | 10MB × 3 files, no unbounded growth |

Nothing is baked into the image. Config, workspaces, state, and logs all arrive as bind mounts. The image stays generic and reusable across environments.

### Using an official OpenClaw image

If OpenClaw publishes one, point the build at it:

```bash
make docker-build BASE_IMAGE=ghcr.io/openclaw/openclaw:latest
```

The Python layer becomes redundant. Verify the official image name at [docs.openclaw.ai](https://docs.openclaw.ai) before relying on this.

---

## Portability

### Move to another machine

```bash
# On the source machine — back up state only
tar czf openclaw-state-$(date +%F).tar.gz -C ~ .openclaw

# On the target machine — restore
tar xzf openclaw-state-*.tar.gz -C ~

# Copy the orchestrator (it's just files)
rsync -av ~/openclaw-orchestrate/ newhost:~/openclaw-orchestrate/

# Rebuild for the new machine's uid/gid
cd ~/openclaw-orchestrate
make setup
make docker-build
make docker-up
```

The generated `docker.env` recalculates `APP_UID`/`APP_GID` for the new host automatically. Bind mounts stay writable.

### Relocate state without regenerating

Edit `~/.openclaw/docker.env`:
```bash
OPENCLAW_HOST_STATE_DIR=/mnt/bigdisk/openclaw
OPENCLAW_WORKSPACE_DIR=/mnt/bigdisk/openclaw/workspace-triad
```

Then `make docker-down && make docker-up`. No rebuild needed.

### Different state directory entirely

```bash
export OPENCLAW_STATE_DIR=/srv/openclaw
make setup
make docker-up
```

Or persist it in the Makefile:
```make
OPENCLAW_STATE_DIR ?= /srv/openclaw
```

---

## SOUL.md Files

Each agent gets a `SOUL.md` describing its temperament, biases, and calibration targets. These are generated dynamically from your preset + overrides:

```markdown
# SOUL.md — Seer

**Theme:** Mystical seer reading market omens

## Temperament Profile

Generated from personality preset: `mystic`

### Core Traits
- **Primary function:** Probability diviner — reads market omens
- **Decision style:** Derived from `medium` thinking depth
- **Bias profile:** Trusts pattern recognition over explicit calculation

### Behavioral Guidelines

- Trusts pattern recognition over explicit calculation
- Seeks coherence across seemingly unrelated signals
- Operates with higher uncertainty tolerance

### Calibration Targets

- Signal hit rate: Target >55%
- False positive rate: Target <10%
- Drawdown tolerance: Per role definition

Current phase: testnet
```

Edit these after generation to inject your own archetype definitions. They're the best place to codify *how* you want the agent to think.

---

## Backup Strategy

**Back up the state dir. Ignore the orchestrator.**

```bash
# Weekly backup of irreplaceable data
tar czf ~/backups/openclaw-$(date +%F).tar.gz \
  -C ~ .openclaw/agents \
       .openclaw/workspace-triad \
       .openclaw/shared \
       .openclaw/.env

# What you're protecting:
#   agents/          → session transcripts, memory
#   workspace-triad/ → journals, calibration, wallet config
#   shared/          → trade ledger (append-only, never reconstructable)
#   .env             → secrets
```

Regenerate everything else with `make setup`.

---

## Troubleshooting

**`docker compose` can't find the compose file**
```bash
ls -la ~/.openclaw/docker-compose.yml
# If missing: make setup
```

**Permission denied writing to mounted volumes**
```bash
# uid/gid mismatch. Regenerate:
make setup
make docker-build
```
The build reads your host `id -u`/`id -g` and creates a matching container user.

**Container starts then exits immediately**
```bash
make logs-system
```
Most likely: `openclaw` binary not installed in the image. See the TODO in the generated Dockerfile — verify the official install method.

**`NANOGPT_API_KEY not set` warning during setup**
Expected if you haven't filled `.env` yet. The stack generates fine; agents just won't run until the key is present.

**Wallet manager raises `WALLET_PRIVATE_KEY is not set`**
```bash
grep WALLET_PRIVATE_KEY ~/.openclaw/.env
```
Ensure it's uncommented and the container has the env var via `env_file`.

**Agent not appearing in Telegram commands**
```bash
# Re-run setup after updating AGENT_ROSTER
make setup
# Restart container
make docker-down && make docker-up
```

---

## Extending

### Add a custom archetype

1. Edit the agent's `SOUL.md` in `workspace-triad/{agent}/SOUL.md`
2. Define behavioral guidelines, bias profiles, calibration targets
3. Reference it from your `.env`:
   ```bash
   AGENT_MYAGENT_THEME="dragon with crystal scales"
   AGENT_MYAGENT_ROLE="Market chaos wrangler — thrives in volatility"
   ```

### Add a fourth agent

1. Expand `AGENT_ROSTER="a,b,c,d"`
2. Add per-agent overrides for theme, role, model (optional)
3. Re-run `make setup`
4. The script handles everything dynamically — no manual edits needed

### Add a new plugin

Drop it in `~/.openclaw/plugins/<name>/`, add dependencies to `requirements.txt`, rebuild.

### Add a new optional feature

In the generator, add a `USE_<FEATURE>` toggle, a `detect_features()` line, and a `generate_<feature>()` function. Follow the existing pattern — every optional feature is self-contained.

---

## Design Notes

**Why a generator script instead of committed config files?**

Because config contains machine-specific values (absolute paths, uid/gid, resolved endpoints). Committing generated config means constant merge conflicts and stale paths. Committing the *generator* means one source of truth that produces correct output everywhere.

**Why is `docker.env` safe to commit but `.env` isn't?**

`docker.env` holds interpolation variables — paths, uids, resource limits. No credentials. `.env` holds API keys and private keys. The split means you can share your deployment topology without leaking secrets.

**Why does the Arbiter have no write access?**

A mediator who can alter the record isn't a mediator. The Arbiter reads both agents' reasoning via `sessions_history` and issues rulings via `sessions_send`. That's the whole job. Write access would let him fabricate consensus.

**Why `swarm: false`?**

Emergent multi-agent behaviour is fascinating and unpredictable. When real money is moving, predictable beats clever. The triad is a fixed, auditable structure with a defined decision procedure — not a self-organising pool.

**Why is the roster now dynamic?**

Reusability. The same orchestrator can now serve:
- A conservative quant team (data hermits, statisticians)
- A mystical intuition crew (seers, dream readers)
- A bold momentum squad (visionaries, impulse traders)
- Your own custom constellation

Just change `AGENT_ROSTER` and `PERSONALITY_PRESET`. Everything else follows.

---

## Testing Before Live

**Dry run syntax check:**
```bash
bash -n scripts/setup-openclaw-triad.sh
```

**Test with throwaway directory:**
```bash
export OPENCLAW_STATE_DIR=/tmp/openclaw-test
./scripts/setup-openclaw-triad.sh --docker
```

**Verify generated files:**
```bash
cat ~/.openclaw/openclaw.json | jq .agents.entries  # Should show all agents
cat ~/.openclaw/workspace-triad/*/SOUL.md           # Each agent has a soul
cat ~/.openclaw/trading.json                        # Should say "testnet"
```

---

## License & Disclaimer

This is infrastructure scaffolding for an experimental trading system.

**It trades real money if you let it.** Start on testnet. The generated `trading.json` ships with `"mode": "testnet"` for a reason. Change that only after sustained paper-trading success.

Nothing here is financial advice. The risk limits encoded (5% max position, 15% daily loss, 2:1 minimum R:R) are starting points, not recommendations. Set them to numbers you can genuinely afford to lose.

---

*Built for Nolimitus Maximus — Conscious Traveller / Raver*
*Purpose: passive income funding exploration, not accumulation for its own sake*
*Version: 2.0 with fully customizable agent rosters*