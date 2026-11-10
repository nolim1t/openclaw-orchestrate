# Council Protocol — Triad Decision Procedure

The council group is an AUDIT TRANSCRIPT, not a workspace.
Nothing said there executes anything. Execution happens only after the
round completes AND tool permissions allow it.

## Round structure (conducted by bot.py)
1. PROPOSAL  — clawdina: one numbered setup — thesis, entry, stop,
   target, R:R, conviction, invalidation.
2. VALIDATION — clawde: APPROVE | VETO | SCALE DOWN, always with reason.
3. ARBITRATION — only on VETO-without-approve: thesource reads both sides
   and rules EXECUTE (modified params stated) or STAND DOWN.
4. VERDICT — conductor posts final state and appends the full round
   to shared/council/YYYY-MM-DD.md.

## Hard rules
- Communication to be done in English only
- One proposal per round. No stacked trades mid-round.
- Nobody argues with a ruling unless its the losing party (clawdina on a rejected proposal, clawde on an overruled veto). If appealed, thesource gets to also step in to try to mediate it and either - thesource's word ends the round or thesource asks the rider (me) for feedback to resolve. When thesource defers to the rider, that should be its own ledger row — appeal_escalated, naming the dispute, the named condition, and why mediation fell short — and crucially, the row records that the round is suspended pending the rider, not stood down. 
- thesource never proposes, never votes, never edits.
- Rounds advance ONLY on human messages in the group.
- Silent step = round STANDS DOWN. If a step goes silent and the round stands down, that should be a ledger row — round_stood_down, which seat was silent, why if known.
- Testnet mode until trading.json says otherwise: no round may reference
  moving real funds. Period.

## Rule execution (Lane 2)
A ratified rule may execute without a human message. Ratification requires a completed council round AND rider approval, recorded in the rules registry with version and evidence citation. Parameters are fixed at ratification and not widen-able; changing them needs a new round. Execution is performed by the conductor only — never by an agent model. The first 3 LIVE executions of any new rule are manual-confirm (clawde, 2026-11-09T05:16Z). Breakers bind automatically; re-arm is the rider's alone. Every trigger, execution, and suspension is its own ledger row.