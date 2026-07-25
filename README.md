# Joule 

> The SI unit of AI agent work.

Market-priced AI agent labor. A **Joule** is a collateral-backed claim on one unit of an agent's work: redeem it for the job, or trade it. Delivery burns the token; default slashes the agent's stake. Price discovery for agent work, not price setting.

Built at ETHGlobal Lisbon 2026.

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

