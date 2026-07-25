# Joule delivery agent

Watches `WorkEscrow` for `Redeemed`, computes the answer, calls `submitWork`.

With `SumVerifier` the job settles **inside the same transaction** — the verifier confirms the
result, the Joule burns, and no acceptance window ever opens. That is the verified path in
[docs/MECHANISM.md](../docs/MECHANISM.md).

## Run it

```bash
cp .env.example .env    # then fill in the three required values
yarn agent              # from the repo root
```

`AGENT_PRIVATE_KEY` must be the key of the escrow's `agent`. `submitWork` is `onlyAgent`, so any
other key produces a process that logs every redemption and delivers none of them. The agent
checks this at startup and refuses to run rather than let you discover it when the first job times
out.

```
escrow 0xd819…5f4d on Anvil (31337)
agent  0xa0Ee…9720  --  delivery window 10 blocks
scanning blocks 11345349..11350349 for jobs missed while offline
caught up (0 historical redemptions)
watching for redemptions -- ctrl-c to stop (that is demo step 4)
job 1 redeemed by 0xa0Ee…9720, deadline block 11350365
  job 1: sum solver says 2 + 2 = 4
  job 1: submitWork sent, 0x35d7…e814
  job 1: settled in block 11350356 (gas 59721)
```

## It is meant to be killed

Demo step 4 is stopping this process, redeeming a Joule, and letting the delivery window lapse so
`claimTimeout` pays the holder `faceValue + penalty` out of the agent's collateral. That is the
whole argument for why the promise is credible.

So there is no auto-restart, no daemonisation, and no swallowing of fatal errors. `ctrl-c` prints
what it is leaving behind and exits.

## Design notes

**Catch-up before watching.** On start it scans `LOOKBACK_BLOCKS` of history for `Redeemed` events
and re-checks each against current onchain status. A restart mid-demo therefore picks up a job
still inside its delivery window instead of silently ignoring it. Jobs already `Settled` are
skipped, so replaying history is free.

**Submissions are serialised.** Two concurrent `writeContract` calls would read the same nonce and
one would be dropped. On a 10-block window a dropped delivery is a slash, not a retry.

**Polling, not filters.** Public RPCs drop `eth_newFilter` subscriptions without saying so, and a
silently dead watcher is indistinguishable from an idle agent.

**Status is re-read before every submit**, never trusted from the event — which is what makes
catch-up, restarts and duplicate events all safe.

**A job it cannot solve is left open.** Submitting anything at all stops the timeout clock and
pushes the job onto the optimistic path, which is strictly worse for the holder than letting a job
the agent genuinely cannot do simply lapse. See `test_SubmittingAnythingBlocksTheTimeout`.

**Solvers mirror verifiers.** `IVerifier` decides *is this result correct*; a `Solver` decides
*what is the result*. Both are swappable and they must agree on an encoding, which nothing checks
at compile time — so each solver names the verifier it answers.

## Files

| Path | |
|---|---|
| `src/index.ts` | the loop: preflight, catch-up, watch, deliver |
| `src/solver.ts` | `Solver` interface and `sumSolver` |
| `src/escrow.ts` | the slice of the ABI the agent uses, and `Status` |
| `src/config.ts` | env parsing, with chain resolved from the RPC rather than configured |
