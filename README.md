# OpenClaw Triad 🐾

[![CI](https://github.com/nolim1t/openclaw-orchestrate/actions/workflows/ci.yml/badge.svg)](https://github.com/nolim1t/openclaw-orchestrate/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-6d4aff.svg)](https://github.com/nolim1t/openclaw-orchestrate/blob/master/LICENSE)
![Shell](https://img.shields.io/badge/shell-bash%203.2%2B-blue)
![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey)

**Three AI agents. One treasury. Checks and balances by design.**

OpenClaw Triad is a self-hosted, Docker-based trading stack where three AI agents collaborate — and keep each other honest — on every trade decision:

- **Scout** — researches the markets and proposes trades
- **Risk** — validates or *vetoes* every proposal against the risk charter; holds the (optional) wallet
- **Judge** — read-only arbiter that issues binding rulings on disputes and can never touch state

> ⚠️ **Status: paper trading / testnet first.** The generated `trading.json` ships in `"mode": "testnet"` for exactly this reason. The stated goal of this project is to prove itself on pretend money and testnets before any real capital is wired in. Nothing here is financial advice.

---

## Why "triad"?

Most single-agent bots are an echo chamber: the thing that proposes the trade is also the thing that approves it. The triad splits proposal, risk control, and arbitration into three independently-configured agents (with separate models, personalities, and permissions), so a bad idea has to survive being argued against.

## Features

- **Roster-driven config** — name and tune your three agents via `AGENT_ROSTER` and per-agent env vars; swap in any names you like
- **Personality presets** — `default`, `mystic`, `bold`, `conservative`, `quant` — each setting hard risk limits (max positions, daily loss, trades per day) and temperament
- **Env-driven model lineup** — pick any vendor/model via `NANOGPT_MODEL_CATALOG` and per-seat vars; a generation-time advisory warns you *before boot* if a referenced model isn't in your catalog
- **Schema-valid config from birth** — the generated `openclaw.json` carries only schema-recognized keys; personas live in each agent's `AGENTS.md`, not the config
- **Telegram front-end** — optional roster-aware bot with a user allowlist, registered at runtime after first boot (`make telegram`)
- **TTS voices** — optional ElevenLabs voices per agent
- **Append-only ledgers + calibration CSVs** — every decision is journaled and auditable; retro-editing the record is treated as the one unforgivable sin
- **Testnet by default** — `trading.json` (and any wallet config) generates in testnet mode with zero auto-withdrawal
- **One-command rebuild** — `rebuild-openclaw.sh` backs up, tears down, regenerates, self-heals the config, inspects (12 checkpoints), builds and boots

## Architecture at a glance

```
~/openclaw-orchestrate/          # this repo: Makefile + scripts
~/.openclaw/                     # state dir (generated, gitignored)
├── openclaw.json                # gateway config (schema-valid, container paths)
├── agents/<name>/               # per-agent dirs + DBs
├── workspace-triad/             # workspaces, journals, AGENTS.md personas
├── shared/                      # ledgers, trading.json, calibration CSVs
├── plugins/telegram-bot/        # optional Telegram front-end
└── Docker: Dockerfile · docker-compose.yml · docker.env (no secrets)
```

The stack runs as a single hardened container: `node:24-slim`, non-root with host-matched uid/gid, read-only rootfs, `cap_drop: ALL`, `no-new-privileges`, 3 GB memory ceiling, private tmpfs temp roots. In-container sandbox mode is intentionally `off` — the container itself is the sandbox.

## Quick start

```bash
git clone https://github.com/nolim1t/openclaw-orchestrate.git
cd openclaw-orchestrate
```

Requirements: Bash 3.2+ (macOS-safe), Docker (Colima works), curl.

```bash
# 1. Initialise dirs and seed .env
make init

# 2. Edit ~/.openclaw/.env
#    MINIMUM: OPENCLAW_GATEWAY_TOKEN (auto-seeded)
#    Recommended for models: NANOGPT_API_KEY + model lineup knobs
#    Optional: TELEGRAM_BOT_TOKEN, TELEGRAM_USER_ID, ELEVENLABS_API_KEY,
#              AGENT_ROSTER, PERSONALITY_PRESET

# 3. Generate the stack
make setup

# 4. Build and boot
make docker-build
make docker-up
```

First contact, once the gateway is up:

```bash
docker exec -it openclaw-triad openclaw agent \
    --agent seer --message "Hello — introduce yourself in one sentence."
```

### One-command rebuild

Nuke and pave the whole stack, safely:

```bash
./rebuild-openclaw.sh              # standard rebuild (keeps the Docker VM)
./rebuild-openclaw.sh --fresh-vm   # also recreate the Docker VM
./rebuild-openclaw.sh --no-build   # regenerate + validate only
```

The rebuild script preserves your `.env` secrets, forces the correct base image, and self-heals the generated config (model provider wiring, id hygiene, sandbox posture) before verifying everything in a 12-point inspection — **before** the expensive build step.

## Make targets

| Target | What it does |
|---|---|
| `make init` | Create dirs, seed `.env` from template |
| `make setup` | Regenerate the stack from `.env` values |
| `make docker-build` | Build the container image |
| `make docker-up` / `docker-down` | Start / stop the gateway |
| `make logs` / `logs-system` | Follow logs / last 100 lines |
| `make shell` | Shell into the container |
| `make status` | Deployment + state health |
| `make agents` | Show roster and preset |
| `make clean` | Remove containers + image (state preserved) |
| `make wipe` | ☣️ Remove ALL state (typed confirmation) |

## Configuration highlights

| Variable | Purpose |
|---|---|
| `AGENT_ROSTER` | Comma list of exactly 3 agent names (pos 1 = scout, 2 = risk, 3 = judge). Default: `seer,guardian,sage` |
| `PERSONALITY_PRESET` | `default` \| `mystic` \| `bold` \| `conservative` \| `quant` |
| `NANOGPT_API_KEY` | Enables the NanoGPT provider (OpenAI-compatible) |
| `NANOGPT_MODEL_CATALOG` | Comma list of `vendor/model-id` (optional `\|Display Name`) — drives the provider model list |
| `TRIAD_SCOUT_MODEL` / `TRIAD_RISK_MODEL` / `TRIAD_JUDGE_MODEL` | Per-seat default models (bare ids, no prefix) |
| `UTILITY_MODEL` | Shared fallback model |
| `AGENT_<NAME>_MODEL` | Per-agent override — beats the seat defaults |
| `TELEGRAM_BOT_TOKEN` / `TELEGRAM_USER_ID` | Telegram bot + allowlist |
| `ELEVENLABS_API_KEY` / `ELEVENLABS_VOICE_ID` | Per-agent TTS voices |
| `--wallet TYPE` | Optional custodial wallet (`btc` \| `xmr` \| `eth`), held by the risk agent, testnet mode, zero auto-withdrawal |

Model spelling is handled for you: catalog ids are **bare** (`vendor/model-id` — what the API expects) while config references are `nanogpt/`-**prefixed** (what the router expects). Change models in `.env`, never in the scripts.

## Safety & design principles

- **Secrets never leave your machine.** `.env` lives in the state dir, is never overwritten, and the generated `.gitignore` keeps secrets and runtime state out of any repo. `docker.env` is committable precisely because it holds no secrets.
- **Least privilege.** The judge is read-only by design (`read` + `message` tools only); the wallet (if enabled) sits with the risk agent, not the proposer.
- **Milestones, not vibes.** Generated agent docs mandate: TESTNET (four weeks) → PAPER (four weeks of positive expectancy) → LIVE-small, with weekly calibration reviews.
- **Idempotent self-healing.** Rebuild scripts patch config deterministically and verify before deploying.
- **Testnet roadmap.** Real money only after the triad proves itself — that's the project's stated path.

## Development

Pull requests should keep the scripts **Bash 3.2-safe** (no associative arrays, no `${var,,}`) so macOS users aren't left behind, and pass the CI checks:

- `bash -n` syntax validation + strict `shellcheck` on all shell scripts
- Makefile sanity (`make init` → seeded `.env` → `make setup` → asserted outputs)
- Generator smoke tests across all five presets, asserting the v3.3 config invariants (bare catalog ids, prefixed refs, sandbox off, explicit ownership, no theme/role keys, judge read-only)
- Model-lineup tests: custom catalogs, per-seat overrides, and the missing-model advisory
- Docker build job: full compose build + brief gateway boot on Ubuntu

CI runs on every push to `main` and on all pull requests via GitHub Actions. See [CONTRIBUTING.md](CONTRIBUTING.md) for the full guidelines.

## Roadmap

- [x] Triad generator + Docker hardening (v3.x)
- [x] Schema-valid config (v3.2)
- [x] Env-driven model lineup + consistency advisory (v3.3)
- [x] Self-healing rebuild (v1.3)
- [x] Telegram front-end, TTS voices
- [ ] Paper-trading performance dashboard
- [ ] Testnet integrations (BTC/XMR/ETH testnets)
- [ ] Gradual real-money rollout behind hard charter limits

## Contributing

Issues and PRs welcome — especially around exchange adapters, risk-charter templates, and backtesting hooks. Please don't commit `.env`, keys, or personal journal data. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT — see [LICENSE](LICENSE).

## Disclaimer

This software is experimental and provided as-is. Trading (even simulated) involves risk. The authors are not responsible for financial losses. Start with pretend money. Seriously.
