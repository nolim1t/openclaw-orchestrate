# OpenClaw Triad Orchestrator

Multi-agent trading infrastructure with a consciousness-aligned decision triad. Works with Docker Desktop or Homebrew-native (colima) backends.

**Portable recipe repo** (this directory) + **machine-local state** (~/.openclaw).

---

## Quick Decision Tree

| Your situation | Follow these steps |
|---|---|
| Fresh install, no Docker | Choose a backend below, then jump to "Generate the Stack" |
| Docker Desktop already installed | Skip backend selection, use Desktop as-is |
| Switching from Desktop to Homebrew | Read the "Backend Migration" section first |
| Existing stack, breaking/changeing | Backup `~/.openclaw`, re-run `make setup` |

---

## Backend Selection

### Option A: Docker Desktop (simplest, full featured)

**Pros:** GUI, one-click updates, stable v2 compose, extensions  
**Cons:** Paid license for larger orgs, heavier resource usage

**Install:**
1. Download from [docker.com/products/docker-desktop](https://www.docker.com/products/docker-desktop/)
2. Open the app, wait for the whale icon to turn solid blue
3. Verify:
   ```bash
   docker compose version   # expect stable v2.x, e.g. 2.24.x
   docker run hello-world
   ```

### Option B: Homebrew + Colima (lightweight, CLI-first)

**Pros:** Open source, minimal footprint, brew-managed, reproducible  
**Cons:** Manual lifecycle (`colima start`), no GUI

**Install:**
```bash
brew install docker docker-compose colima

# Symlink compose v2 for CLI compatibility
mkdir -p ~/.docker/cli-plugins
ln -sfn $(brew --prefix)/opt/docker-compose/bin/docker-compose ~/.docker/cli-plugins/docker-compose

# Start the VM (runs continuously or until stopped)
colima start
docker context use colima

# Verify
docker compose version
docker run hello-world
```

**Resource tuning** (optional):
```bash
colima stop
colima start --cpu 4 --memory 8   # scale for heavy workloads
```

**Auto-start on login** (optional):
```bash
brew services start colima
```

### Switching Between Backends

If you're migrating from Docker Desktop to Homebrew (or vice versa):

1. **Stop all containers and the VM/app**
   ```bash
   docker compose -f ~/.openclaw/docker-compose.yml down  # if running
   colima stop           # for Homebrew
   # or quit Docker Desktop app
   ```

2. **Remove old binaries and contexts** (macOS example)
   ```bash
   # Remove Docker Desktop leftovers
   sudo rm -rf /Applications/Docker.app
   sudo rm -f /usr/local/bin/docker /usr/local/bin/docker-compose
   rm -rf ~/.docker

   # Now install your chosen backend (A or B above)
   ```

3. **Rebuild state** (images are disposable, your trading state lives in `~/.openclaw`)
   ```bash
   cd ~/.openclaw
   docker compose --env-file docker.env build
   ```

**Why this works:** All your data (agents/ledgers/workspaces) lives in `~/.openclaw` on the host filesystem — outside Docker's VM. The image cache is disposable; the recipe regenerates it on every machine.

---

## Generate the Stack

### 1. Prepare the orchestrator

```bash
cd ~/openclaw-orchestrate
chmod +x scripts/setup-openclaw-triad.sh
```

### 2. Configure your secrets

```bash
cp env/.env.example ~/.openclaw/.env 2>/dev/null || {
  mkdir -p ~/.openclaw
  cp env/.env.example ~/.openclaw/.env
}
chmod 600 ~/.openclaw/.env
nano ~/.openclaw/.env   # edit the file
```

**Minimum viable config:**
```bash
NANOGPT_API_KEY=sk-nanogpt-xxxxxxxxxxxx
```

### 3. Customize your triad (optional)

Change the personality preset and roster in `.env`:

```bash
# Personality presets: default | bold | conservative | mystic | quant
PERSONALITY_PRESET=mystic

# Agent names (position order is fixed: scout/risk/judge)
AGENT_ROSTER=seer,guardian,sage
```

Per-agent overrides (uncomment as needed):
```bash
AGENT_SEER_THEME=purple lotus fox — intuitive seer
AGENT_SEER_ROLE=Senses setups through collective-sentiment patterns
AGENT_SEER_MODEL=anthropic/claude-sonnet-4-6
AGENT_SEER_THINKING=medium

AGENT_GUARDIAN_THINKING=high
AGENT_SAGE_THINKING=high
```

### 4. Run the generator

```bash
make setup
```

Expected output:
- `~/openclaw-orchestrate/scripts/setup-openclaw-triad.sh` runs and creates `~/.openclaw/`
- `openclaw.json`, `docker-compose.yml`, `docker.env` generated
- Agent workspaces created with SOUL.md, AGENTS.md, DREAMS.md files

**Verify:**
```bash
ls -la ~/.openclaw/
cat ~/.openclaw/openclaw.json | head -20
```

---

## Deploy

### Build the container image

```bash
make docker-build
```

This compiles the Python environment and packages the OpenClaw runtime (the TODO in the Dockerfile must be completed — see "Extending" section below).

### Start the triad

```bash
make docker-up
make status        # see containers running
```

### Watch activity

```bash
make logs          # live feed
make logs-system   # last 100 lines
```

### Stop

```bash
make docker-down   # containers stop, state preserved
make docker-down -v  # ALSO removes image volumes (destructive)
```

---

## Architecture Overview

### The Separation Principle

```
~/openclaw-orchestrate/          ← Recipe. Git-tracked. Portable.
├── Makefile
├── README.md
├── scripts/
│   └── setup-openclaw-triad.sh   ← Generator
└── env/
    └── .env.example

~/.openclaw/                     ← State. Machine-local. Irreplaceable.
├── openclaw.json                ← Generated config
├── .env                         ← YOUR SECRETS (backup!)
├── docker-compose.yml
├── docker.env                   ← No secrets, safe to commit
├── agents/                      ← Session transcripts
├── workspace-triad/             ← Journals, calibration, SOUL.md
├── plugins/                     ← Trading logic
├── shared/                      ← Trade ledgers (append-only)
└── logs/
```

| Concern | Orchestrator | State dir |
|---|---|---|
| Version control | ✅ Yes | ❌ No |
| Backup priority | Low (regenerable) | **High** (irreplaceable) |
| Machine-specific | ❌ No | ✅ Yes |
| Contains secrets | ❌ No | ✅ Yes |
| Can be deleted safely | ✅ Yes | ❌ Never |

**Portability workflow:**

```bash
# Move to new machine
tar czf openclaw-state-$(date +%F).tar.gz -C ~ .openclaw
rsync -av ~/openclaw-orchestrate/ newhost:~/openclaw-orchestrate/

# On target machine
tar xzf openclaw-state-*.tar.gz -C ~
cd ~/openclaw-orchestrate
make setup
make docker-build
make docker-up
```

---

## The Triad Model

```
Scout (position 1) proposes ──┐
                               ├──► Aligned? ──► Execute
Risk (position 2) validates ───┘

If disagree ──► Judge (position 3) rules ──► Execute (modified) or Stand down

Invariant: no single agent executes alone.
```

### Position semantics (fixed regardless of names)

| Position | Role | Permissions |
|---|---|---|
| 1 | Scout / Proposer | Read, write, edit, execute proposals |
| 2 | Risk / Validator | Read, write, execute vetoes/approvals |
| 3 | Judge / Arbiter | **Read-only**, rules on disputes |

### Personality presets

| Preset | Scout | Risk | Judge | Best for |
|---|---|---|---|---|
| default | Clawdia | Clawdio | Arbiter | Balanced baseline |
| mystic | Seer | Guardian | Sage | Consciousness lens |
| bold | Momentum hunter | Firm boundary-keeper | Decisive | Aggressive strategies |
| conservative | Patient watcher | Near-immovable | Slow deliberation | Capital preservation |
| quant | Signal detector | Variance calculator | Bayesian synthesis | Data-driven |

---

## Features Matrix

Features auto-enable when their API keys are present.

| Feature | Trigger var | What it adds |
|---|---|---|
| **NanoGPT models** | `NANOGPT_API_KEY` | All agent reasoning (required) |
| **ElevenLabs TTS** | `ELEVENLABS_API_KEY` | Per-agent voice in openclaw.json |
| **Telegram bot** | `TELEGRAM_BOT_TOKEN` | `/seer`, `/guardian`, `/sage` commands |
| **Polymarket live** | `POLYMARKET_API_KEY` | Real order routing (else testnet stubs) |
| **Crypto treasury** | `WALLET_PRIVATE_KEY` | Wallet manager + audit log |

### Treasury configuration

```bash
WALLET_TYPE=xmr              # btc | xmr | eth
WALLET_PRIVATE_KEY=...
WALLET_AGENT=guardian        # Position 2 by default (capital preservation)
```

**Security posture:**
- Key read from environment, never written to disk
- All operations appended to `logs/wallet.log`
- Withdrawals require explicit human approval
- Cold storage recommended for production

---

## Model Configuration

Defaults favor economics (cheap scanner, expensive judge):

```bash
CLAWDIA_MODEL=anthropic/claude-sonnet-4-6      # Fast
CLAWDIO_MODEL=anthropic/claude-opus-4-6        # Deep
ARBITER_MODEL=anthropic/claude-opus-4-6        # Careful
UTILITY_MODEL=openai/gpt-5.4-mini              # Housekeeping
```

Override per-agent:
```bash
AGENT_SEER_MODEL=google/gemini-flash-latest
AGENT_GUARDIAN_MODEL=deepseek/deepseek-v3.2
AGENT_SAGE_MODEL=anthropic/claude-opus-4-6
```

Check available model IDs: `GET https://nano-gpt.com/api/v1/models`

---

## Risk Parameters

Defaults ship conservative for testnet safety. Adjust in `.env` or after sustained paper-trading success:

```bash
MAX_POSITION_SIZE_PCT=5       # Max % of portfolio per trade
DAILY_LOSS_LIMIT_PCT=15       # Hard stop for the day
MAX_DAILY_TRADES=20           # Trade count ceiling
MIN_RISK_REWARD=2:1           # Minimum R:R ratio
```

Preset adjustments applied automatically:
- `bold` → 7% position, 20% daily loss
- `conservative` → 3% position, 10% daily loss
- `quant` → 5% position, 40 trades/day
- `mystic` → 5% position, 15% daily loss, 20 trades

---

## Makefile Targets

| Target | What it does |
|---|---|
| `make init` | Create directory structure, fetch scripts, seed `.env` |
| `make setup` | Run the generator with current env vars |
| `make agents` | Inspect current roster, themes, roles, models |
| `make check` | Validate script syntax + generated JSON configs |
| `make docker-build` | Build the container image |
| `make docker-up` | Start the triad |
| `make docker-down` | Stop containers (state preserved) |
| `make clean` | Remove containers + images (state preserved) |
| `make wipe` | **DANGER** — removes all state (typed confirmation required) |
| `make logs` | Follow container logs live |
| `make logs-system` | Last 100 lines |
| `make shell` | Bash into the running container |
| `make status` | Show containers + state directory health |
| `make help` | Full command reference |

---

## Troubleshooting

### Docker Compose Errors

**`name:` property not allowed**
```bash
# Old Compose schemas (< v2.2) reject top-level `name:` key
# Fix: Edit ~/.openclaw/docker-compose.yml, delete the `name:` line
# Or: Re-run make setup with v2.3+ generator (fixes automatically)
```

**`BASE_IMAGE variable is not set`**
```bash
# Add to ~/.openclaw/docker.env:
echo 'BASE_IMAGE=python:3.11-slim' >> ~/.openclaw/docker.env
```

**`Cannot connect to the Docker daemon`**
```bash
# VM not started
colima status     # should say "running"
colima start      # if stopped
docker context use colima  # if wrong context
```

### Bash Script Errors

**`bad substitution` / `${var,,}` errors**
```bash
# macOS ships Bash 3.2 (too old for some syntax)
# Fix: ensure scripts/setup-openclaw-triad.sh is v2.3+ (uses tr/awk instead)
# Alternative: brew install bash (then `hash -r`)
```

### Container Issues

**Permission denied writing to bind mounts**
```bash
make setup    # regenerates UID/GID matching for your host
make docker-build
```

**Container exits immediately**
```bash
make logs-system    # most likely: OpenClaw runtime not installed in Dockerfile
# See "Extending" section below
```

**`NANOGPT_API_KEY not set` warning**
```bash
# Expected if .env not filled yet — stack generates fine, agents won't run until key present
```

---

## Extending

### Install the OpenClaw Runtime (Dockerfile TODO)

Once OpenClaw publishes an official package, update the Dockerfile:

```dockerfile
# In ~/.openclaw/Dockerfile (after FROM python:3.11-slim):
RUN pip install --no-cache-dir openclaw-runtime
# or:
RUN npm install -g @openclaw/runtime

CMD ["openclaw", "start"]
```

Check their docs for the canonical package name and install method.

### Add a fourth agent

1. Modify `generate_openclaw_json()` to add a fourth entry
2. Modify `create_directory_structure()` to add the workspace directory
3. Add a binding in `bindings` array
4. Re-run `make setup`

### Add a new plugin

Drop it in `~/.openclaw/plugins/<name>/`, add dependencies to `requirements.txt`, rebuild:
```bash
make docker-build
```

### Add a new optional feature

In the generator (`setup-openclaw-triad.sh`):
1. Add `USE_<FEATURE>` toggle
2. Add `detect_features()` line
3. Add `generate_<feature>()` function
4. Follow the existing pattern (wallet, Telegram, ElevenLabs demonstrate the template)

---

## Security Checklist

Before enabling live trading:

- [ ] Testnet mode verified (`"mode": "testnet"` in `trading.json`)
- [ ] Risk parameters reviewed and adjusted to personal limits
- [ ] Secrets file permissions correct (`chmod 600 ~/.openclaw/.env`)
- [ ] Ledger backup strategy in place (see "Backup Strategy" below)
- [ ] Container hardening verified (`cap_drop: ALL`, `read_only: true`)
- [ ] Withdrawal approvals enabled (`max_auto_withdrawal_usd: 0`)
- [ ] Cold storage considered for treasury (not hot wallet)
- [ ] Agent permissions audited (Arbiter read-only, as designed)

---

## Backup Strategy

**Back up state only. Ignore the orchestrator.**

```bash
# Weekly backup of irreplaceable data
tar czf ~/backups/openclaw-$(date +%F).tar.gz \
  -C ~ .openclaw/agents \
       .openclaw/workspace-triad \
       .openclaw/shared \
       .openclaw/.env

# Protect these specifically:
#   agents/          → session transcripts, memory
#   workspace-triad/ → journals, calibration, wallet config
#   shared/          → append-only trade ledger (never reconstructable)
#   .env             → secrets
```

Regenerate everything else with `make setup`.

---

## Development Timeline

### Phase 1: Testnet (Weeks 1-4)

```bash
# Leave trading.json in "testnet" mode
# Focus on:
#   - All three agents proposing, validating, ruling
#   - Ledger appending correctly
#   - No unlogged manual interventions
```

### Phase 2: Paper Trading (Weeks 5-8)

Simulated fills, real market data:
- Positive expectancy on simulated executions
- Calibration CSVs showing accuracy trends
- Weekly reflection in DREAMS.md

### Phase 3: Live Capital (Week 9+)

Only after phases 1–2 complete successfully:
- Small position sizes initially
- All three agents aligned on readiness
- Gradual scaling per DREAMS.md milestones

---

## License & Disclaimer

**Experimental trading infrastructure.** It trades real money if you let it.

- The generated `trading.json` ships with `"mode": "testnet"` for a reason
- Change that only after sustained paper-trading success
- Nothing here is financial advice
- Risk limits encoded (5% max position, 15% daily loss, 2:1 minimum R:R) are starting points, not recommendations

Set limits you can genuinely afford to lose.

---

*Built for Nolimitus Maximus — Conscious Traveller / Raver*  
*Purpose: passive income funding exploration, not accumulation for its own sake*