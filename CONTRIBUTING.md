# Contributing to OpenClaw Triad 🐾

Thanks for wanting to help build a saner approach to AI-assisted trading. Before you dive in, read the ground rules — most of them exist because something broke without them.

## Ground rules

1. **Testnet first, always.** New features must work in `"mode": "testnet"` before anything else. No PR that wires real money into defaults will be accepted.
2. **Secrets never enter the repo.** No API keys, tokens, `.env` files, journal data, or ledger contents in commits. The generated `.gitignore` exists for a reason; respect it.
3. **The ledger is append-only.** Contributions touching ledgers or calibration data must preserve append-only semantics. Retro-editing a record is the one unforgivable sin.
4. **Least privilege by design.** The judge stays read-only. The wallet stays with the risk agent. Don't centralize permissions "for convenience."

## Bash 3.2 compatibility (hard requirement)

These scripts must run on macOS stock Bash 3.2. CI enforces this, but save yourself a round-trip:

- ❌ Associative arrays: `declare -A`
- ❌ Lowercasing sugar: `${var,,}` / `${var^^}`
- ✅ `printf`/`tr` for case conversion, positional parsing (`IFS=',' read -ra arr <<< "$s"`), plain indexed arrays
- Always `set -euo pipefail`
- Quote everything; assume paths contain spaces

## Getting started

```bash
git clone https://github.com/nolim1t/openclaw-orchestrate.git
cd openclaw-orchestrate

# Everything routes through the Makefile:
make init     # create dirs, seed .env
make setup    # regenerate the stack from .env
```

Test your changes against a **throwaway state dir** so you never clobber real state:

```bash
export OPENCLAW_STATE_DIR=/tmp/openclaw-dev
make setup
```

## What CI checks (your PR must pass)

- `bash -n` + strict `shellcheck --severity=style` on every `.sh` in the repo
- Makefile pipeline: `init` → seeded `.env` → `setup` → asserted outputs
- Generator smoke tests: all five personality presets, asserting the config invariants (schema-valid agents block, bare catalog ids, `nanogpt/`-prefixed references, sandbox off, explicit ownership, judge read-only)
- Model-lineup tests: custom `NANOGPT_MODEL_CATALOG`, per-seat overrides, the missing-model ADVISORY
- Docker job: compose build + brief boot of the generated image

Run the cheap checks locally before pushing:

```bash
shellcheck --severity=style scripts/*.sh
bash -n scripts/setup-openclaw-triad.sh
```

## Areas that need help

- **Exchange/testnet adapters** — BTC/XMR/ETH testnet integrations that fit the risk charter
- **Risk-charter templates** — reusable presets beyond the five built in
- **Paper-trading dashboard** — read-only visualization of ledgers and calibration hit-rates
- **Backtesting hooks** — replaying historical proposals against the veto logic
- **Docs** — macOS (Colima) and Linux (plain Docker) walkthroughs are both welcome

## Submitting changes

1. Fork, branch (`feat/exchange-adapter-kraken`, `fix/roster-validation`, …)
2. Keep diffs focused — one logical change per PR
3. Update the generator's `CHANGELOG` comment block if you touch generation behaviour
4. Open the PR against `main` with a short "why" — the "what" is visible in the diff
5. If your change alters generated output, paste a before/after `diff` of the generated `openclaw.json` from a throwaway state dir into the PR description

## Reporting bugs

Include: OS, Docker setup (Colima/plain/orbstack), the generator version line from `make setup` output, and the relevant log tail from `make logs-system`. **Never** include API keys or full `.env` contents.

## Licensing

By contributing you agree that your contributions will be licensed under the repository's [MIT license](LICENSE).
