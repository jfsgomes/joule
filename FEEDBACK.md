# Uniswap developer feedback

Notes from building **Joule** at ETHGlobal Lisbon 2026. We integrated the **Trading API** for the
buy/sell flow and Uniswap **v4** for a `JOULE/USDC` pool on Ethereum Sepolia.

**Environment.** `v4-periphery` at `3245c3c` (tracking `main`, 2026-07-13) · Foundry `forge 1.7.1`
· Ethereum Sepolia (11155111) · PoolManager `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` ·
Universal Router `0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b` · findings dated 2026-07-25.

---

## What worked well

Worth naming specifically, since it is easy to only report problems:

- **The Trading API returns calldata for the router that is actually deployed.** This turned out
  to matter enormously — see finding 1. Building the calldata ourselves is where we got hurt;
  asking the API for it was the version-proof path. That is a real architectural advantage and
  we would not have appreciated it without having done both.
- **`protocols` is the right abstraction.** Being able to say `["V4"]` and get a `v4-pool` route
  back, with `hooksOptions` (`V4_HOOKS_INCLUSIVE` / `V4_HOOKS_ONLY` / `V4_NO_HOOKS`) as further
  refinement, is a clean model. `V4_NO_HOOKS` described our pool exactly.
- **Named custom errors across v4-core and v4-periphery.** `DeadlinePassed(uint256)` in particular
  told us precisely what was wrong, in a situation where a `require` string would have been
  ambiguous. `cast 4byte` resolves them, which makes debugging tractable.
- **Non-standard fee tiers route fine.** We saw the API route a Sepolia pool with `fee: 20`,
  `tickSpacing: 1`. Worth knowing, since a lot of third-party advice says to stick to the
  canonical tiers for routability.
- **v4 itself is unfussy about sparse liquidity.** A swap gaps to the next initialised tick and
  fills. That behaviour is correct and we relied on it; finding 2 is about the routing layer
  appearing to expect something stricter.

---

## Finding 1 — `v4-periphery@main` encodes swap params the deployed Universal Router cannot decode

This one we were able to trace to a specific commit, so we state it with more confidence than
Finding 2.

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

### Why it took a while

The failure is indistinguishable from the other things that make a v4 swap revert:

- a `PoolKey` that does not correspond to an initialised pool
- a missing or expired Permit2 allowance
- a pool with no liquidity to fill against

We checked all three first, because each is more likely a priori than "the struct grew a field".
Reaching the real cause meant reading `CalldataDecoder` assembly and `git log -S minHopPriceX36`.

### Workaround

We declared the pre-#516 struct locally rather than pinning the whole submodule backwards, since
`PositionManager`'s `MINT_POSITION` / `SETTLE_PAIR` encoding matched the deployment fine and
downgrading everything to fix one struct would have traded a documented local workaround for an
undocumented global one.

---

## Finding 2 — no route for a pool with zero active liquidity at the current tick

In our Sepolia deployment the Trading API returned no route while the pool had zero active
liquidity at the current tick, despite holding inventory in nearby ranges. It began routing the
same pool after we added a small position spanning the current tick. We found no documentation of
this apparent routing requirement.

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

### What we measured

Because spot sat in the 4.80/5.00 gap, `StateView.getLiquidity(poolId)` returned **0** at the
current tick. Inventory existed; none of it was active there.

We minted a small position spanning the current tick — same pool, same
tokens, same fee tier — and re-queried.

| | active liquidity at spot | Trading API |
|---|---|---|
| as originally seeded | `0` | `404 ResourceNotFound` |
| after adding ~$5 spanning spot | `35645481612126` | `200`, `"route":"v4-pool"` |

Aggregate depth moved from roughly $69 to $74, so the change in total liquidity was small.

The observation is consistent with a routing requirement for active liquidity at the current tick, 
and we could not find that requirement documented. Someone with visibility into the router could 
confirm or dismiss it.

### Why it seemed worth reporting anyway

The configuration is not exotic. It is the canonical single-sided range order — inventory placed
entirely above spot, converting as buyers push through it — which is close to the reason
concentrated liquidity exists. Anyone bootstrapping a token with inventory but no paired capital
may arrive at it naturally.

And `404 ResourceNotFound` is returned identically for an unknown token, a non-existent pool, and
a real pool we could later route against. With no way to tell those apart, our first conclusion was
that the API did not support new tokens on testnets, which would have been the wrong lesson.

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

## What we would tell the next team

1. Pin `v4-periphery` to a tag matching the deployed routers on your chain, or let the Trading API
   build your calldata. Do not hand-encode router actions from `main`.
2. Assert `StateView.getLiquidity(poolId) > 0` immediately after seeding. Whatever the underlying
   cause, a pool with nothing active at its opening tick was not routable for us, and one line
   catches it before you deploy.
3. Never assume your token is `token0`. Branch on the address comparison and test both.
4. Verify every v4 address onchain. They are not deterministic across chains, and cross-checking
   `.poolManager()` on each peripheral is a thirty-second sanity check that proves the whole set is
   coherent.
