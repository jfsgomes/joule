# Joule 

> The SI unit of AI agent work.

Market-priced AI agent labor. A **Joule** is a collateral-backed claim on one unit of an agent's work: redeem it for the job, or trade it. Delivery burns the token; default slashes the agent's stake. Price discovery for agent work, not price setting.

Built at ETHGlobal Lisbon 2026.

### ▶ Live on Ethereum Sepolia — **https://joule-two.vercel.app**

Buying is priced and routed by the Uniswap Trading API; settlement is enforced onchain. Mint the
stand-in USDC in the app, buy a Joule, spend it on a job, and watch it settle — or let the window
lapse and take the agent's collateral instead.

| | |
|---|---|
| Mechanism, flow of funds, limits | [docs/MECHANISM.md](./docs/MECHANISM.md) |
| Onchain history, every tx linked | [docs/ONCHAIN-LOG.md](./docs/ONCHAIN-LOG.md) |
| Uniswap developer feedback | [FEEDBACK.md](./FEEDBACK.md) |
| Scope, milestones, verified addresses | [PLAN.md](./PLAN.md) |

---

## Where the Uniswap integration lives

Every part of a trade comes from the **Uniswap Trading API** — the price, the ERC-20 approval, and
the swap calldata. We build none of it and never call the pool directly.

| Step | Code |
|---|---|
| Approval transaction, from `check_approval` | [`BuyPanel.tsx:119`](./packages/nextjs/components/joule/BuyPanel.tsx#L119) → [`tradingApi.ts:118`](./packages/nextjs/utils/joule/tradingApi.ts#L118) |
| Quote, from `/quote` | [`BuyPanel.tsx:126`](./packages/nextjs/components/joule/BuyPanel.tsx#L126) → [`tradingApi.ts:133`](./packages/nextjs/utils/joule/tradingApi.ts#L133) |
| Permit2 signature the quote asks for | [`BuyPanel.tsx:137`](./packages/nextjs/components/joule/BuyPanel.tsx#L137) |
| Swap calldata, from `/swap` | [`BuyPanel.tsx:146`](./packages/nextjs/components/joule/BuyPanel.tsx#L146) → [`tradingApi.ts:172`](./packages/nextjs/utils/joule/tradingApi.ts#L172) |
| Sending it — the only chain write we author | [`BuyPanel.tsx:147`](./packages/nextjs/components/joule/BuyPanel.tsx#L147) |
| Server-side key proxy, endpoint allowlist | [`route.ts:34`](./packages/nextjs/app/api/uniswap/%5B...path%5D/route.ts#L34), [`route.ts:49`](./packages/nextjs/app/api/uniswap/%5B...path%5D/route.ts#L49) |

The quote object is handed back to `/swap` **verbatim** rather than reconstructed — rebuilding it
client-side would be a second source of truth that can silently disagree with the API's own routing.

### The v4 pool it trades against

`JOULE/USDC`, fee 3000, tickSpacing 60, no hook. Pool id
[`0xfaf9c90d…97ef4d7`](https://sepolia.etherscan.io/address/0xE03A1074c86CFeDd5C142C4F04F1a1536e203543).

| | Code |
|---|---|
| Price and tick maths, decimals and token ordering | [`JoulePoolMath.sol:62`](./packages/foundry/contracts/libraries/JoulePoolMath.sol#L62) |
| Opening tick, snapped to the spacing grid | [`JoulePoolMath.sol:92`](./packages/foundry/contracts/libraries/JoulePoolMath.sol#L92) |
| Ranges pinned to spot so liquidity is never absent there | [`JoulePoolMath.sol:124`](./packages/foundry/contracts/libraries/JoulePoolMath.sol#L124) |
| Seed plan — pure, asserts the geometry | [`JoulePoolSeeder.sol:116`](./packages/foundry/script/JoulePoolSeeder.sol#L116) |
| Seed execution — initialize and mint both ranges | [`JoulePoolSeeder.sol:194`](./packages/foundry/script/JoulePoolSeeder.sol#L194) |
| Fallback: direct Universal Router swap | [`SwapJoule.s.sol`](./packages/foundry/script/SwapJoule.s.sol) |

That "pinned to spot" line is the hard-won one: a pool with **no active liquidity at the current
tick** is invisible to the Trading API even though it holds inventory. Diagnosing that cost a
deployment and is written up in [FEEDBACK.md](./FEEDBACK.md).

### The escrow that makes a Joule worth something

All four contracts are source-verified on Sepolia.

| | Code | Address |
|---|---|---|
| `stake` / `issue` | [`WorkEscrow.sol:292`](./packages/foundry/contracts/WorkEscrow.sol#L292), [`:314`](./packages/foundry/contracts/WorkEscrow.sol#L314) | [`0xACaf…87D53`](https://sepolia.etherscan.io/address/0xACaf997478F466737d82c66fECAAB95e27987D53#code) |
| `redeem` — custody is the lock | [`WorkEscrow.sol:345`](./packages/foundry/contracts/WorkEscrow.sol#L345) | |
| `submitWork` — verifier settles inline | [`WorkEscrow.sol:371`](./packages/foundry/contracts/WorkEscrow.sol#L371) | |
| `claimTimeout` — the slash | [`WorkEscrow.sol:473`](./packages/foundry/contracts/WorkEscrow.sol#L473) | |
| `JouleToken` — minted only by the escrow | [`JouleToken.sol`](./packages/foundry/contracts/JouleToken.sol) | [`0x57d8…79399`](https://sepolia.etherscan.io/address/0x57d89f6Ca5f684312190b7C1EF2d24dF33879399#code) |
| `SumVerifier` — the one trust root worth reading | [`SumVerifier.sol`](./packages/foundry/contracts/verifiers/SumVerifier.sol) | [`0x7664…8119d`](https://sepolia.etherscan.io/address/0x7664b864e2209935b599E40De3C336428668119d#code) |

---

## Thesis

Hardcoded default pricing for AI agent work is inefficient. Agent labor markets will converge on mechanisms resembling Google's ad auctions: continuous, market-driven price discovery. Joule implements this as **collateral-backed work futures** with a secondary market.

## Core Mechanism

1. **Stake** — An agent deposits USDC collateral.
2. **Issue** — The agent mints Joule tokens (ERC-20, one token = one standard job) up to a coverage ratio (e.g. 2× face value must be collateralized). Buyers pay the agent's ask price.
3. **Trade** — Joules are fungible and trade freely on a `JOULE/USDC` pool. The pool price is the market's live valuation of the agent's work.
4. **Redeem** — A holder locks a Joule and submits a job spec. A delivery clock starts (e.g. 24h).
5. **Settle** — one of three endings:
   - **Delivered & accepted** → Joule burns, agent's revenue unlocks, collateral untouched.
   - **Timeout (no submission)** → objectively verifiable onchain; buyer is refunded face value **plus a penalty** from the agent's collateral. This is the slash.
   - **Disputed quality** → out of hackathon scope

The slash penalty is what makes pre-buying at locked prices credible: without it, an agent's optimal move when prices rise is to default on cheap old futures and reissue.

