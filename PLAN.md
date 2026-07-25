# Joule — Build Plan

> Mechanism and thesis live in [README.md](./README.md). This file is scope, stack, and order of work.

## Prize Target

**Uniswap Foundation — Best Uniswap API Integration ($7,000; 1st $4,000).**

Verified against the [Lisbon 2026 prize page](https://ethglobal.com/events/lisbon2026/prizes#uniswap-foundation) on 2026-07-25. Notes:

- There is **no hooks prize track** at this event. A v4 hook is therefore a technical stretch goal only, not a prize play.
- The second Uniswap track (*Best Uniswap Stack Contribution*, $3k) is **Continuity Track only** — for teams extending a prior project. Joule is new, so treat it as ineligible unless organizers say otherwise.
- What is judged is the **Trading API integration**. Our swap flow routes through it.

### Qualification checklist (cheap, easy to forget, disqualifying if missed)

- [x] Public GitHub repo, open source, MIT — repo is public and `LICENSE` is a standard MIT text. **But** GitHub's API reported no detected license on 2026-07-25, and the sidebar badge is what a judge actually looks at. Confirm it renders before submitting.
- [x] `FEEDBACK.md` at repo root — honest notes on the Uniswap developer experience. Two substantive findings, both reproducible: the `v4-periphery@main` vs deployed-router ABI mismatch, and a v4 pool with zero *active* liquidity being invisible to the Trading API.
- [ ] Uniswap Developer Feedback Form submitted, linking to `FEEDBACK.md`
- [ ] README points to specific contracts **and line numbers** for the API integration

---

## Chain

**Ethereum Sepolia (11155111).** Decided. Fallback if it disappoints: Unichain Sepolia (1301) — with SE2 that is a `scaffold.config.ts` change plus an address swap, both recorded below.

Uniswap v4 is deployed on all four major testnets, so v4 integration difficulty is identical everywhere. Two of the four are ruled out outright:

| Testnet | Chain ID | v4 | Trading API | Uniswap web UI |
|---|---|:--:|:--:|:--:|
| **Ethereum Sepolia** | **11155111** | ✅ | ✅ | ✅ |
| Unichain Sepolia | 1301 | ✅ | ✅ | ✅ |
| Base Sepolia | 84532 | ✅ | ✅ | ❌ |
| Arbitrum Sepolia | 421614 | ✅ | ❌ | ❌ |

Source for the web-interface column, verbatim from [supported-chains](https://developers.uniswap.org/docs/trading/swapping-api/supported-chains): *"Only Ethereum Sepolia and Unichain Sepolia are available as testnets on the Uniswap web interface. All listed testnets are accessible via the API."* Base Sepolia is therefore API-only — it forfeits the "show the pool on Uniswap itself" demo moment. Arbitrum Sepolia is not Trading-API-supported at all, which kills the prize deliverable.

Between the two survivors the tradeoff was pacing vs. funding, and funding won:

| | Ethereum Sepolia | Unichain Sepolia |
|---|---|---|
| Funding | Broadest faucet ecosystem | Typically bridged from Sepolia — needs Sepolia ETH anyway |
| Tooling | Etherscan, every RPC provider, wallets preconfigured | Newer, thinner |
| Block time | ~12s | ~1s ([docs](https://developers.uniswap.org/docs/unichain); 200ms Flashblocks preconfs) |

Testnet ETH acquisition is the classic hackathon time sink, and Unichain Sepolia likely requires Sepolia ETH as an input anyway — so Sepolia is strictly fewer setup steps and has the deepest tooling support.

### The cost we accepted, and how we pay it

~12s blocks against a demo with ~5 sequential live transactions means **plausibly 1–2 minutes of the 3-minute slot spent watching confirmations**. That is the real price of this choice and it has to be designed around, not discovered on stage:

- **Pre-execute demo step 1** (stake + issue + seed pool) before the slot starts. Open on a live pool, not an empty one.
- **Set the delivery window to ~10 blocks (~2 min)**, not a wall-clock value — so the timeout demo is paced in blocks we can count.
- **Every pending transaction gets real UI**: optimistic state, block-confirmation counter, and an explorer link. On a 12s chain the waiting *is* the interface. Budget design time for it in Milestone 7.
- If the demo still drags in rehearsal, switching to Unichain Sepolia is a config + address swap. Rehearse early enough that this remains an option.

### Addresses — Ethereum Sepolia (11155111)

Sourced from official Uniswap docs, then **verified onchain in Milestone 0** (2026-07-25) against `https://ethereum-sepolia-rpc.publicnode.com`, `cast chain-id` → `11155111`.

| Contract | Address | Code | Cross-check |
|---|---|:--:|---|
| PoolManager | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` | ✅ 48021b | — (the anchor) |
| PositionManager | `0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4` | ✅ 47757b | `.poolManager()` → anchor ✅ |
| StateView | `0xe1dd9c3fa50edb962e442f60dfbc432e24537e4c` | ✅ 7065b | `.poolManager()` → anchor ✅ |
| Quoter | `0x61b3f2011a92d183c7dbadbda940a7555ccf9227` | ✅ 11643b | `.poolManager()` → anchor ✅ |
| Universal Router | `0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b` | ✅ 39083b | — |
| Permit2 (all chains) | `0x000000000022D473030F116dDEE9F6B43aC78BA3` | ✅ 18307b | `PositionManager.permit2()` → this ✅ |

Bytecode presence alone only proves *something* is deployed. The cross-check column is the real evidence: three independent peripherals each resolve to the same PoolManager, and PositionManager confirms canonical Permit2. That is a genuinely wired v4 deployment.

### Deployer

Keystore `ethgloballisbon2026` → **`0x37B5b8BF6C6068cdda8506AD7EB0246A87eee20A`** (created Milestone 0; fresh EOA, nonce 0).

```
yarn deploy --network sepolia --keystore ethgloballisbon2026
```

Only ETH for **gas** is needed. Both sides of the `JOULE/USDC` pool are our own contracts (`JouleToken` + `MockUSDC`), so no real value has to be sourced to seed liquidity. At the ~1.1 gwei base fee measured in Milestone 0, four contract deploys land well under 0.01 ETH — 0.1 ETH is comfortable headroom for the whole build plus demo reruns.

Unichain Sepolia fallback (1301) — PoolManager `0x00b036b58a818b1bc34d502d3fe730db729e62ac`, PositionManager `0xf969aee60879c54baaed9f3ed26147db216fd664`, StateView `0xc199f1072a74d4e905aba1a84d9a45e2546b6222`, Quoter `0x56dcd40a3f2d466f48e7f48bdbe5cc9b92ae4472`, Universal Router `0xf70536b3bcc1bd1a972dc186a2cf84cc6da6be5d`. Same verification requirement.

Uniswap docs warn explicitly that v4 addresses are **not** consistent across chains. Never copy an address between networks.

---

## Stack

### Contracts
- **Solidity ~0.8.2x** — version pinned by the scaffold
- **Foundry** (`forge`/`cast`/`anvil`) — Solidity-native tests, which matters because our invariants are contract-level
- **OpenZeppelin** — `ERC20`, `SafeERC20`, `ReentrancyGuard`, `Ownable`. Do not reimplement these.
- **MockUSDC** — ours, freely mintable. **6 decimals, matching real USDC.** The 18-vs-6 assumption is the single most common fund-loss bug and our entire coverage-ratio math runs through it. Testing against an 18-decimal mock would hide it.

### Frontend
- **Scaffold-ETH 2** (`npx create-eth@latest`) — Next.js monorepo. Gives wallet connection, ABI→TypeScript generation, event-history hooks, and deploy/verify scripts. With seven `WorkEscrow` entry points to bind, that generation is where the time is saved.
- **wagmi + viem** — used *through* Scaffold hooks, never raw. Raw wagmi resolves before transaction confirmation, so the UI reports success against an unsettled chain.
- **Tailwind** — DaisyUI defaults get stripped in the design pass
- **Recharts** or **lightweight-charts** — pool price chart
- **Uniswap Trading API** — the prize integration; powers quote + swap

### Agent
- **TypeScript + viem `watchContractEvent`**, run under `tsx`. Watches `Redeemed`, computes the sum, calls `submitWork`. Deliberately killable — that is demo step 4.

### Ops
- **Vercel** from day one, so a working link always exists
- **IPFS + ENS** as a pre-demo polish step. Requires the localStorage polyfill (we are on Node v25.9.0), `trailingSlash: true`, and a clean `rm -rf .next out` before every build.
- **Blockscout / abi.ninja** — fallback demo surface if the frontend breaks
- **Secrets** — `.env` never committed; encrypted keystore for the deploy key

---

## Architecture

```
packages/
  foundry/
    contracts/
      WorkEscrow.sol      # collateral, issuance caps, redemption, timeout slashing
      JouleToken.sol      # ERC-20 future, mint/burn only via WorkEscrow
      MockUSDC.sol        # 6-decimal test collateral
      verifiers/
        IVerifier.sol     # verify(jobSpec, result) -> bool
        SumVerifier.sol   # demo verifier: checks integer addition
      hooks/              # STRETCH ONLY — no prize attached
    script/               # Deploy.s.sol, SeedPool.s.sol
    test/                 # unit, fuzz, invariant, fork
  nextjs/
    app/                  # demo UI
    contracts/            # AUTO-GENERATED — do not hand-edit
agent/                    # TypeScript delivery agent
```

### WorkEscrow key functions

Full ledger with running balances: [docs/MECHANISM.md](./docs/MECHANISM.md).

| Function | Actor | Effect |
|---|---|---|
| `stake(amount)` | Agent | deposits USDC collateral |
| `issue(count)` | Agent | mints `count` Joules **to the agent** if coverage holds |
| `redeem(jobSpec)` | Holder | transfers 1 Joule into escrow custody, starts delivery clock |
| `submitWork(jobId, spec, result)` | Agent | verifier confirms → settles immediately; cannot confirm → opens the acceptance window. The spec is re-supplied and checked against its stored hash |
| `accept(jobId)` | Redeemer | settles an unverified result early |
| `finalize(jobId)` | Anyone | settles an unchallenged result once its window closes |
| `dispute(jobId)` | Redeemer | challenges an unverified result; costs a bond of `penalty` |
| `resolveDispute(jobId, upheld)` | Arbiter | rules on a challenge |
| `claimTimeout(jobId)` | Anyone | after deadline with no submission: burns Joule, **credits** redeemer `faceValue + penalty` from collateral |
| `withdraw()` | Anyone credited | collects a credited payout. Payouts are pull, not push, so a blocklisted recipient cannot brick a job |
| `unstake(amount)` | Agent | withdraw only collateral not backing outstanding Joules |

**`issue()` is a pure mint — there is no price argument and no primary market.** The agent receives the Joules and sells them into the Uniswap pool. The escrow never handles a sale, so it never handles sale proceeds; the collateral is the entire guarantee. An `askPrice` here would be a second pricing path competing with the pool, and price-setting by the agent is the thing the thesis argues against.

### Parameters (immutable, set at deployment)

| Parameter | Meaning | Demo value |
|---|---|---|
| `faceValue` | Agent's declared liability per Joule — the guaranteed refund on default. **Not the price.** | 5 USDC |
| `penalty` | Extra paid to the redeemer on default | 5 USDC |
| `collateralPerJoule` | Collateral locked per outstanding Joule. **Absolute, not a multiple** — an integer ratio cannot express 1.2× and would round a 6-unit liability up to a 10-unit lock | 10 USDC |
| `deliveryBlocks` | Delivery window, **in blocks** so the demo is countable | 10 (~2 min) |
| `acceptBlocks` | Acceptance window for an unverified result | 5 (~1 min) |
| `arbiter` | Rules on disputed jobs. **The system's one centralised trust assumption** | a demo address |

Solvency requires `collateralPerJoule ≥ faceValue + penalty`, checked exactly in the constructor with no rounding. The demo values sit precisely on that bound — settling one Joule frees exactly what one default costs. Raising `penalty` without raising `collateralPerJoule` breaks solvency and the constructor refuses to deploy.

### Invariants (test these)

- Joules can only be minted/burned by `WorkEscrow`.
- `collateral >= collateralPerJoule × outstandingJoules` at all times.
- A redeemed Joule sits in escrow custody, so it cannot be moved by anyone — custody *is* the lock, and no transfer hook on the token is needed.
- An agent can never unstake collateral backing outstanding Joules.
- `claimTimeout` is callable by anyone but pays only the redeemer.
- Defaulting is never profitable while `salePrice < faceValue + penalty`.

---

## Scope

### Must have (demo-critical)

- [ ] `WorkEscrow` + `JouleToken` + `MockUSDC` with happy path and timeout-slash path
- [ ] `SumVerifier` for objective auto-acceptance of one job type
- [ ] Foundry suite: unit + fuzz (all collateral math) + invariant (the five above) + fork
- [ ] **Vanilla v4 pool** (`JOULE/USDC`), no hook, seeded with liquidity
- [ ] **Uniswap Trading API powers the buy flow** — this is the prize deliverable
- [ ] Minimal frontend: buy a Joule, redeem it, watch settlement
- [ ] Demo agent: listens for `Redeemed`, computes the sum, calls `submitWork`
- [ ] `FEEDBACK.md` + README line references + feedback form submitted

### Should have

- [ ] Slash-and-refund path in frontend (kill the agent, show the timeout claim)
- [ ] Agent pricing controls: adjust ask, buy back own Joules below floor
- [ ] Live pool price chart ("the market's estimate of this agent's work")
- [ ] Design pass — strip SE2 branding, make it presentable

### Stretch

- [ ] **v4 hook**: escrow-aware pool, agent as collateral-constrained market maker, swap fees route to collateral. *Technically interesting; no prize attached at this event.* Cheap to attempt only because the must-have pool is already v4 — see note below.
- [ ] IPFS + ENS deploy
- [ ] Multiple agents / multiple Joule tokens with a registry

> **Why the must-have pool is v4, not v3:** if the baseline pool were v3, adding the hook later would mean rewriting the integration on a different architecture. Building vanilla v4 first makes the hook purely additive — write it, attach it. Same must-have cost, far cheaper stretch.

### Out of scope (say no)

- Subjective quality arbitration (Kleros/UMA)
- Reputation systems
- Token-per-job-type generalization
- Mainnet deployment, audits, tokenomics beyond the mechanism

---

## Milestones

Build everything against a **local fork of Sepolia**, then touch the live chain once. This is the Scaffold-ETH three-phase model: phase 1 is a fork with real Uniswap v4 deployed, phase 2 is live contracts with a local UI, phase 3 is the public frontend.

Note the Sepolia deploy is **not** last. A public frontend URL pointing at a laptop's anvil is not a demo, so the deploy has to land between "frontend works locally" and "frontend deployed".

| # | Milestone | Definition of done | Status |
|---|---|---|---|
| 0 | Toolchain | `foundryup` installed; scaffold committed; `.gitignore` covers `.env`, `broadcast/`, `cache/`; deployer funded; all six v4 addresses verified with `cast code` | ✅ |
| 1 | Contracts core | All four contracts written; `forge test` green on happy path, timeout slash, and the optimistic/dispute paths | ✅ |
| 2 | Test depth | Fuzz on all math, all five invariants passing | ✅ *(fork test deferred to 3 — nothing touches Uniswap yet)* |
| 3 | Pool live | `JOULE/USDC` v4 pool seeded on a Sepolia fork; swap works from a script; fork test against real v4 | ✅ |
| 4 | Agent loop | Demo agent auto-delivers on `Redeemed` events | ← next |
| 5 | Frontend functional | Buy → redeem → settle end to end against the fork; Trading API driving the buy | |
| 6 | Deployed + verified | Live on Sepolia, verified on Etherscan, pokeable via abi.ninja; local UI repointed at it | |
| 7 | Frontend beautiful | Design pass, price chart, SE2 branding gone, Vercel deploy | |
| 8 | Slash demo | Timeout path demoable on purpose | |
| 9 | Prize hygiene | `FEEDBACK.md`, README line refs, form submitted | |
| 10 | Stretch | v4 hook / IPFS+ENS, only if 0–9 are done | |

**To work on the fork:** set `targetNetworks: [chains.foundry]` in `scaffold.config.ts` and run `FORK_URL=sepolia yarn fork`. The env var is required — `yarn fork sepolia` silently forks mainnet.

---

## Demo Script (3 min)

1. Agent A stakes 100 USDC, mints 10 Joules, seeds the pool at ~5 USDC. Pool goes live.
2. Human buys Joules via the Trading API → price ticks up on the chart. "This is price discovery for agent labor."
3. Agent B redeems a Joule with job `sum(2,2)`. Demo agent delivers, verifier auto-accepts, token burns.
   - **Gap to close:** `sum(2,2)` only ever takes the *verified* path, so the acceptance window, the dispute bond and the arbiter never appear on stage. That machinery is built and tested but invisible. Add a step — redeem something the verifier cannot confirm, show it enter the window — or at least a slide. It is the answer to "what about work a contract can't check?", which is the obvious question.
4. Kill the demo agent. Redeem another Joule. Deadline passes → `claimTimeout` → refund + penalty visibly leaves the agent's stake. "This is why the promise is credible."
5. Close on the pool chart: market price of Agent A's work, discovered, not set.

Optional flourish: show the pool in the real Uniswap web interface — both shortlisted chains support it, which is why Base Sepolia was dropped.

---

## Open Questions

- ~~Coverage ratio and penalty size~~ **Resolved:** 2× with penalty = face value is the tight solvency solution, not a guess. See MECHANISM.md.
- ~~Should issuance revenue be held or paid immediately?~~ **Resolved: moot.** Sales happen in the pool, so the escrow never receives proceeds and cannot hold them. Collateral is the sole guarantee.
- ~~Seed the pool single-sided or two-sided?~~ **Resolved 2026-07-25: hybrid, with both ranges meeting at spot.** All 10 JOULE as a range order from spot up to 6.00 funded with **zero USDC**, plus a **20 USDC bid** from spot down to 4.00 funded with **zero JOULE**. The bid is not needed to *sell* Joules — it is needed so anyone can sell one *back*, which the pure single-sided design makes impossible and which both the "agent buys back below floor" should-have and a non-monotonic price chart require. 20 USDC instead of the 50 a symmetric two-sided seed would cost. Params live in `packages/foundry/script/JouleAddresses.sol`.
- ~~Does the Trading API quote a pool as thin as ours?~~ **Resolved 2026-07-25: yes — thinness was never the problem.** The API quoted a ~$70 pool without complaint. What it will not quote is a pool with **zero active liquidity at the opening tick**, which is exactly what a textbook single-sided range placed *above* spot produces. The first seed opened at 4.90 with the wall at `[5.00, 6.00]` and the bid at `[4.00, 4.80]`; every contract-level test passed and the API returned `404 ResourceNotFound`. Adding a position spanning spot — about $5 against a $70 pool — flipped it to a working quote, buy and sell, plus executable `/v1/swap` calldata.
  - Also established: the API routes v4 on Sepolia (`protocols: ["V4"]`, with a `V4_NO_HOOKS` option matching our pool), non-standard fee tiers route fine, and it encodes calldata for the *deployed* Universal Router — so it sidesteps the periphery-`main` ABI mismatch documented in `script/SwapJoule.s.sol`.
  - The fix: pin both ranges to the opening tick so they meet with no gap. Subtlety worth keeping — a position is live on `[tickLower, tickUpper)`, so only the range pinned at its **lower** bound is active, and which one that is **flips with the token ordering**. `JoulePoolSeeder.plan` now asserts one of them is live, and the fork tests check it under both orderings.
- Delivery window: express it in **blocks (~10, i.e. ~2 min on Sepolia)**, not wall-clock seconds — the timeout demo should be paced in units the audience can count, and it stays correct if we fall back to a faster chain. 24h is meaningless in a demo.
- Trading API key: acquisition process, rate limits, and approval delay are undocumented on the supported-chains page. **Resolve in Milestone 0** — if there is an approval queue, it blocks the prize deliverable and we need to be in it on day one.
- Does the Trading API quote a pool as thin as ours, or does its router refuse low-liquidity pairs? Test early; the fallback is direct Universal Router calls, which weakens the prize story.
