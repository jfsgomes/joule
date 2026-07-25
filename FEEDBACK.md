# Uniswap developer feedback

Notes from building **Joule** at ETHGlobal Lisbon 2026. We integrated the **Trading API** for the
buy/sell flow and Uniswap **v4** for a `JOULE/USDC` pool on Ethereum Sepolia.

This is written to be useful rather than polite: the things that cost us hours are described in
enough detail to reproduce, and the things that worked are named specifically so it is clear what
not to change.

**Environment.** `v4-periphery` at `3245c3c` (tracking `main`, 2026-07-13) · Foundry `forge 1.7.1`
· Ethereum Sepolia (11155111) · PoolManager `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` ·
Universal Router `0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b` · findings dated 2026-07-25.

---

## What worked well

Genuinely, and worth saying before the complaints:

- **The Trading API returns calldata for the router that is actually deployed.** This turned out
  to matter enormously — see finding 1. Building the calldata ourselves is where we got hurt;
  asking the API for it was the version-proof path. That is a real architectural advantage and
  we would not have appreciated it without having done both.
- **`protocols` is the right abstraction.** Being able to say `["V4"]` and get a `v4-pool` route
  back, with `V4_HOOKS_INCLUSIVE` / `V4_HOOKS_ONLY` / `V4_NO_HOOKS` as further refinement, is a
  clean model. `V4_NO_HOOKS` described our pool exactly.
- **Named custom errors across v4-core and v4-periphery.** `DeadlinePassed(uint256)` in particular
  told us precisely what was wrong, in a situation where a `require` string would have been
  ambiguous. `cast 4byte` resolves them, which makes debugging tractable.
- **Non-standard fee tiers route fine.** We saw the API route a Sepolia pool with `fee: 20`,
  `tickSpacing: 1`. Worth knowing, since a lot of third-party advice says to stick to the
  canonical tiers for routability.
- **v4 itself is unfussy about sparse liquidity.** A swap gaps to the next initialised tick and
  fills. That behaviour is correct and we relied on it — it is only the *router* that disagrees,
  which is finding 2.

---

## Finding 1 — `v4-periphery@main` is ABI-incompatible with deployed Universal Routers, and fails silently

**Severity: high.** This is the one we would most like fixed.

### What happened

We followed the obvious path: add `v4-periphery` as a submodule, take `main`, import
`IV4Router.ExactInputSingleParams`, encode a `SWAP_EXACT_IN_SINGLE` action, call
`UniversalRouter.execute`.

It reverted with:

```
UniversalRouter::execute(...)
  └─ PoolManager::unlock(...)
      └─ UniversalRouter::unlockCallback(...)
          └─ ← [Revert] EvmError: Revert
```

No selector. No message. No revert string.

### Why

`v4-periphery` PR #516 (*"add per-hop slippage to single swaps"*) added a `minHopPriceX36` field to
`ExactInputSingleParams`. The Universal Router deployed on Sepolia predates it. `CalldataDecoder`
locates the struct by offset, so our extra word was read as the `hookData` offset, sending the
decoder to a nonsense location.

The minimum-length guard in `decodeSwapExactInSingleParams` moved from `0x140` to `0x160` with that
change, so it validates the *new* layout and cannot detect an old consumer being handed new
encoding — or vice versa.

### Why it is expensive

The failure is indistinguishable from the other things that make a v4 swap revert:

- a `PoolKey` that does not correspond to an initialised pool
- a missing or expired Permit2 allowance
- a pool with no liquidity to fill against

We checked all three first, because each is more likely a priori than "the struct grew a field".
Reaching the real cause meant reading `CalldataDecoder` assembly and `git log -S minHopPriceX36`.

### Suggested fixes, cheapest first

1. **Version the docs.** State on the swapping pages which `v4-periphery` tag corresponds to the
   deployed routers per chain. A single table would have prevented this entirely.
2. **Tag releases and point people at tags, not `main`.** The natural `forge install uniswap/v4-periphery`
   gives you `main`, which is ahead of every deployment.
3. **Make the struct version-detectable.** If the action byte for a params layout changed when the
   layout changed, an old router would reject a new payload with a specific error instead of
   walking off the end of a buffer.

### Workaround

We declared the pre-#516 struct locally rather than pinning the whole submodule backwards, since
`PositionManager`'s `MINT_POSITION` / `SETTLE_PAIR` encoding matched the deployment fine and
downgrading everything to fix one struct would have traded a documented local workaround for an
undocumented global one.

→ `packages/foundry/script/SwapJoule.s.sol:53` (`LegacyExactInputSingleParams`, with the full
explanation at lines 30–52) and its use at line 145.

---

## Finding 2 — a v4 pool with zero *active* liquidity is invisible to the Trading API

**Severity: high.** This cost us a deployment to diagnose and is, we think, genuinely surprising.

### What happened

We seeded `JOULE/USDC` the way concentrated liquidity is usually taught: a **range order**, all
inventory in a range placed entirely *above* spot, so the position is 100% of the sold token at
open and converts as buyers push through it. Ten JOULE across `[5.00, 6.00]`, opening the pool at
4.90, plus a 20 USDC bid across `[4.00, 4.80]`.

That pool holds real inventory. v4 swaps against it correctly. Every contract-level test we had
passed — the pool opened at the right price, the wall cost zero USDC, buying walked the price up,
selling walked it down.

The Trading API returned, in both directions:

```
HTTP 404  {"errorCode":"ResourceNotFound","detail":"No quotes available"}
```

### Diagnosis

Because spot sat in the 4.80/5.00 gap, `StateView.getLiquidity(poolId)` was **0** at the current
tick. Inventory existed; none of it was *active*.

We ruled out indexing lag with a 24-minute poll, then ran a one-variable experiment on the same
pool, same tokens, same fee tier: mint a small position spanning the current tick.

| | active liquidity at spot | Trading API |
|---|---|---|
| as originally seeded | `0` | `404 ResourceNotFound` |
| after adding ~$5 spanning spot | `35645481612126` | `200`, `"route":"v4-pool"` |

Aggregate depth moved from roughly $69 to $74. **Thinness was never the problem** — the API
quotes a $70 pool without complaint. A hole at spot is fatal; a shallow book is not.

### Why this is worth fixing

The configuration that triggers it is not exotic — it is the canonical single-sided range order,
the thing v3/v4 concentrated liquidity is *for*. Anyone bootstrapping a new token with inventory
but no paired capital will land on it naturally, and will conclude the API does not support their
pool, their chain, or new tokens.

The failure gives no signal about which. `404 ResourceNotFound` is returned identically for an
unknown token, a non-existent pool, and a real pool that merely has a gap at spot. We only
distinguished them by deploying and experimenting.

### Suggested fixes

1. **Differentiate the error.** Something like `NoActiveLiquidity` with the pool id would have
   turned a multi-hour investigation into a one-line fix. The router already knows the difference.
2. **Consider routing through the gap.** v4 does this natively — a swap crosses uninitialised
   ticks and fills at the next range. A router that simulated the same way would quote these
   pools correctly.
3. **Document it.** A sentence on the liquidity page saying the router requires liquidity at the
   current tick, not merely in the pool, would be enough.

### Our fix

Both ranges are now pinned to the opening tick so they **meet** at spot with no gap.

One subtlety that makes this harder than it sounds, and which we would flag to anyone else: a
position is active on the half-open interval `[tickLower, tickUpper)`, so of two ranges meeting at
spot, only the one pinned at its **lower** bound is live — and **which one that is flips with token
ordering**. Pinning only the sell wall works when your token sorts as `token0` and silently fails
when it does not. Both orderings occur in practice; we hit each of them on separate Sepolia
deployments.

Single-sidedness survives: at the shared boundary the other token's amount is exactly
`L(√P − √Pa) = 0`, so a range pinned at spot is genuinely single-sided *and* active at the same
time.

→ `packages/foundry/contracts/libraries/JoulePoolMath.sol:92` (`alignedSpotTick`), `:124`
(`rangeFromTick`), `:195` (`assertSingleSided`, where equality is load-bearing rather than a
loosened check) · guard at `packages/foundry/script/JoulePoolSeeder.sol:155` (`NoLiquidityAtSpot`)
· regression test at `packages/foundry/test/fork/JoulePool.fork.t.sol:413`.

---

## Finding 3 — v4 support is hard to confirm from the Trading API docs

**Severity: medium.** Purely a documentation-navigation problem, but it nearly changed our
architecture.

Reading the supported-chains material, we could not determine whether v4 pools were routable —
the chain/router-version tables are framed around Universal Router versions, and we came away
believing v4 might be v2/v3-only. That very nearly pushed us to deploy a v3 pool instead, which
would have been a significant and unnecessary rewrite.

The answer was on the quote API reference: `protocols` accepts `V4`, with the `V4_HOOKS_*` options
alongside it. Cross-linking the two — or a "protocol support" column on the chains table — would
close the gap.

**Suggestion:** state v4 support explicitly on the supported-chains page, per chain. For a team
choosing an architecture on day one of a hackathon, "is v4 routable here" is close to the first
question asked.

---

## Smaller notes

**Permit2 is two approvals, not one.** `IERC20.approve(permit2, ...)` then
`permit2.approve(token, spender, ...)`. Missing the second succeeds locally and fails deep inside
Permit2 later. This *is* documented — we mention it only because it is the single most common
thing we saw others hit, and a callout box near the first `PositionManager` example would earn its
space. → `packages/foundry/script/JoulePoolSeeder.sol:248`.

**`deadline` and scripted broadcasts.** Our bug, not Uniswap's, but the interaction is worth
naming. In a Foundry script, `block.timestamp + 60` is evaluated during *simulation* and baked into
broadcast calldata; the transaction then lands minutes later, in wall-clock time, and reverts
`DeadlinePassed`. Fork tests cannot catch it — they run in one frozen-timestamp context where no
time passes at all. `DeadlinePassed(uint256)` naming the expired value is exactly what made this
diagnosable, so this is half a compliment. → `packages/foundry/script/JoulePoolSeeder.sol:199`,
where the deadline is a required parameter specifically so it cannot be computed at simulation time.

**`initializePool` returning `type(int24).max`** instead of reverting when the pool exists is a
good design — it let us make seeding idempotent after a partially-broadcast run, by checking
whether the existing pool is still at our intended price rather than blanket-refusing. Not obvious
from the signature; worth an example.

**Token ordering deserves louder placement.** `token0` is decided by address comparison, so which
side of the pool your token lands on is not yours to choose unless you mine a salt. Every piece of
tick reasoning inverts with it. We wrote our maths to take `jouleIsToken0` explicitly and tested
both branches, and both branches occurred across two real deployments — this is not a theoretical
concern.

---

## What we would tell the next team

1. Pin `v4-periphery` to a tag matching the deployed routers on your chain, or let the Trading API
   build your calldata. Do not hand-encode router actions from `main`.
2. Make sure liquidity is **active at your opening tick**, not merely present in the pool.
   Check `StateView.getLiquidity(poolId) > 0` immediately after seeding — one assertion.
3. Never assume your token is `token0`. Branch on the address comparison and test both.
4. Verify every v4 address onchain. They are not deterministic across chains, and cross-checking
   `.poolManager()` on each peripheral is a thirty-second sanity check that proves the whole set is
   coherent.
