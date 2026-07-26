# Onchain log — Joule on Ethereum Sepolia

Every transaction below happened on public **Ethereum Sepolia (11155111)** and is linked to
Etherscan. Nothing here is a local fork, a mock, or a screenshot.

It is a working log rather than a highlight reel: the first pool we deployed was **invisible to the
Uniswap Trading API**, and the transactions that diagnosed and fixed that are included, because the
diagnosis is more interesting than the success. See [FEEDBACK.md](../FEEDBACK.md) for the
developer-experience write-up.

Deployer / agent: [`0x37B5b8BF…eee20A`](https://sepolia.etherscan.io/address/0x37B5b8BF6C6068cdda8506AD7EB0246A87eee20A)
· Demo buyer: [`0x4B85b8e5…4cFC`](https://sepolia.etherscan.io/address/0x4B85b8e5D4d2e3220218F69500C4804721eE4cFC)

---

## Contracts

The live set, which the frontend points at. **All source-verified on Etherscan** — the `#code` tab
shows the real source, and the published ABIs match the local artifacts function for function.

| Contract | Address | Source |
|---|---|---|
| `WorkEscrow` | [`0xACaf9974…87D53`](https://sepolia.etherscan.io/address/0xACaf997478F466737d82c66fECAAB95e27987D53) | [verified](https://sepolia.etherscan.io/address/0xACaf997478F466737d82c66fECAAB95e27987D53#code) |
| `JouleToken` | [`0x57d89f6C…79399`](https://sepolia.etherscan.io/address/0x57d89f6Ca5f684312190b7C1EF2d24dF33879399) | [verified](https://sepolia.etherscan.io/address/0x57d89f6Ca5f684312190b7C1EF2d24dF33879399#code) |
| `MockUSDC` | [`0xCd7Bd62E…43007`](https://sepolia.etherscan.io/address/0xCd7Bd62E6C0439853393Df29a8619B04e2943007) | [verified](https://sepolia.etherscan.io/address/0xCd7Bd62E6C0439853393Df29a8619B04e2943007#code) |
| `SumVerifier` | [`0x7664b864…8119d`](https://sepolia.etherscan.io/address/0x7664b864e2209935b599E40De3C336428668119d) | [verified](https://sepolia.etherscan.io/address/0x7664b864e2209935b599E40De3C336428668119d#code) |

Verification matters more than usual here. `MECHANISM.md` argues the verifier is the system's one
total trust root — two one-line implementations of `IVerifier` would break the escrow completely —
so **reading `SumVerifier`'s source is not optional** for anyone evaluating a Joule. An unverified
contract makes that impossible.

`JouleToken` has no deploy transaction of its own — `WorkEscrow` creates it inside its constructor,
which is what fixes the minter to the escrow by construction rather than by a setter. That is also
why SE-2's `yarn verify` cannot see it; `yarn verify:sepolia` reads the same
`deployments/<chainId>.nested.json` manifest the ABI generator uses.

Uniswap v4, verified onchain before use (each peripheral's `.poolManager()` resolves to the same
PoolManager):

| | Address |
|---|---|
| PoolManager | [`0xE03A1074…03543`](https://sepolia.etherscan.io/address/0xE03A1074c86CFeDd5C142C4F04F1a1536e203543) |
| PositionManager | [`0x429ba701…c09b4`](https://sepolia.etherscan.io/address/0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4) |
| Universal Router | [`0x3A9D48AB…dF98b`](https://sepolia.etherscan.io/address/0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b) |
| Permit2 | [`0x00000000…78BA3`](https://sepolia.etherscan.io/address/0x000000000022D473030F116dDEE9F6B43aC78BA3) |

`JOULE/USDC` pool — fee 3000, tickSpacing 60, no hook.
Pool id `0xfaf9c90d16c5929e136d0229791b7a31f75a182a9aaa5b674263b066897ef4d7`.

---

## Act 1 — the pool the Trading API refused

**Blocks 11350262–11350277.** A throwaway probe deployment, made specifically to ask the Trading
API a question we could not answer from a fork: *will it quote a pool this thin?*

Seeded exactly as concentrated liquidity is usually taught — a **range order**, all 10 JOULE placed
entirely *above* spot at `[5.00, 6.00]`, opening the pool at 4.90, plus a 20 USDC bid at
`[4.00, 4.80]`. Zero USDC in the sell wall, which is the capital-efficiency claim in
[MECHANISM.md](./MECHANISM.md).

The pool held real inventory and swapped correctly under v4. The Trading API returned
`404 ResourceNotFound` in both directions.

| Block | Call | Transaction |
|---|---|---|
| 11350262 | `deploy MockUSDC` | [`0x288503…0714`](https://sepolia.etherscan.io/tx/0x288503683c80d4fbc3ff44f0a54a2d5c56df575367b04525aec9cca92ff20714) |
| 11350262 | `deploy SumVerifier` | [`0x8adc6d…df92`](https://sepolia.etherscan.io/tx/0x8adc6d25140ac187ce7d0bb81e0678ac08d80de419fe0b887cc2951313f5df92) |
| 11350262 | `deploy WorkEscrow` | [`0x6adc81…9b1c`](https://sepolia.etherscan.io/tx/0x6adc8196c2965157b07f22a90f4c931b4250de2b07d1cc6c350fdbac1ff59b1c) |

| Block | Call | Transaction |
|---|---|---|
| 11350277 | `mint(address,uint256)` | [`0x404d50…80fa`](https://sepolia.etherscan.io/tx/0x404d5071e0601d39ee99f785a76d07b43d3d8bf3d843428308711558905c80fa) |
| 11350277 | `approve(address,uint256)` | [`0x69c17a…7bef`](https://sepolia.etherscan.io/tx/0x69c17a69be46c0a9a0d1edd0538b6ff2eb2861ccb92a153a159816a4a6127bef) |
| 11350277 | `stake(uint256)` | [`0x6872cf…5f59`](https://sepolia.etherscan.io/tx/0x6872cf4801f128c38d24696a95122d5414920cddc784d18903ab2a3328a85f59) |
| 11350277 | `issue(uint256)` | [`0xb59a1b…e74c`](https://sepolia.etherscan.io/tx/0xb59a1baf75bf6273da7bfc6685951e8b97cadd0d456fe2463c1e6df8e9a3e74c) |
| 11350277 | `mint(address,uint256)` | [`0x24d084…f77b`](https://sepolia.etherscan.io/tx/0x24d08477bb11bf06956defebe80d743d223bf7404c9afae816a27ee1e689f77b) |
| 11350277 | `initializePool((address,address,uint24,int24,address),uint160)` | [`0x3d5ebf…f4cf`](https://sepolia.etherscan.io/tx/0x3d5ebfa473140e13606fec82c571fc26492a113fe46a0d5c2f4d608e24acf4cf) |
| 11350277 | `approve(address,uint256)` | [`0xb723a8…4042`](https://sepolia.etherscan.io/tx/0xb723a844d680ec17e1278cc77d8563a55e2a121da065b4abacf934350c7d4042) |
| 11350277 | `approve(address,address,uint160,uint48)` | [`0xaaacd3…42a1`](https://sepolia.etherscan.io/tx/0xaaacd386e85a02c553cd70a14a1bc2c7f5c89b0d7abba8345b6ebbbeabaa42a1) |
| 11350277 | `approve(address,uint256)` | [`0x7bd215…9294`](https://sepolia.etherscan.io/tx/0x7bd21515084baefeb11939a81df2c4ad8b365c41b944b1f8dafb676a93409294) |
| 11350277 | `approve(address,address,uint160,uint48)` | [`0x052005…b01e`](https://sepolia.etherscan.io/tx/0x052005455787d535e7369e377afaed5e1975d2d2bf8ec3b00ae58eace975b01e) |
| 11350277 | `modifyLiquidities(bytes,uint256)` | [`0x4f722c…18dc`](https://sepolia.etherscan.io/tx/0x4f722c641f5aec4709dcad074dd40a26da5d0584f860f3a035b2a55c8a9b18dc) |

Probe escrow: [`0x3a08a46a…00c746`](https://sepolia.etherscan.io/address/0x3a08a46ac3987731616812e39b42e9fada00c746).
A 24-minute poll ruled out indexing lag.

---

## Act 2 — the one-variable experiment

**Block 11350437.** Three hypotheses fitted the 404 and they demanded very different responses:
indexing lag (wait), no active liquidity at spot (a constants change), or tokens not curated on
testnet (nothing parametric would fix it).

`ProbeStraddle.s.sol` changed exactly one thing: it minted a small position **spanning the current
tick** on the same pool, same tokens, same fee tier. Deliberately not a second pool at a different
fee tier, which would have confounded two variables at once.

| Block | Call | Transaction |
|---|---|---|
| 11350437 | `mint(address,uint256)` | [`0x94383a…e121`](https://sepolia.etherscan.io/tx/0x94383a38c14c0f7ac7493dbd2f1c725bee7047478de3b6036623a02ddcc5e121) |
| 11350437 | `mint(address,uint256)` | [`0x4a1a1c…3c82`](https://sepolia.etherscan.io/tx/0x4a1a1ce2325185930d35f8b4316f77842048e1928fe188adfc60ebec89fb3c82) |
| 11350437 | `approve(address,uint256)` | [`0x7a8388…d98d`](https://sepolia.etherscan.io/tx/0x7a83884fe1926960fb2d012d893c01a90172c3831d1756043b11277dda4bd98d) |
| 11350437 | `stake(uint256)` | [`0x8cca8f…2484`](https://sepolia.etherscan.io/tx/0x8cca8f376a0a8d30a16c2764d1e0757518c9a421e36f3e9a99bec6cc8eb62484) |
| 11350437 | `issue(uint256)` | [`0x7748c9…ca85`](https://sepolia.etherscan.io/tx/0x7748c900e0870015aaf3a0aa98b2fc64d5aac267444303035c21c75ef709ca85) |
| 11350437 | `approve(address,uint256)` | [`0x0cf7b4…f603`](https://sepolia.etherscan.io/tx/0x0cf7b4a466676ba78ae356eee0fc95ab8eb0e23e88f182c504489931a688f603) |
| 11350437 | `approve(address,address,uint160,uint48)` | [`0xd677b5…d545`](https://sepolia.etherscan.io/tx/0xd677b503aeb1b5691aec24e943a3ed304ca147cfbdf4ef6cacef1b8875a4d545) |
| 11350437 | `approve(address,uint256)` | [`0xdca593…65dd`](https://sepolia.etherscan.io/tx/0xdca59360349dd7a6e6c0889f399d8dae0ac1ac715821bf9750669602798965dd) |
| 11350437 | `approve(address,address,uint160,uint48)` | [`0x131328…76ca`](https://sepolia.etherscan.io/tx/0x13132804b28aed7a4db438043bc2ae50b9b1beee9b95fd8456883b45596b76ca) |
| 11350437 | `modifyLiquidities(bytes,uint256)` | [`0xb4720a…23c7`](https://sepolia.etherscan.io/tx/0xb4720a4f4de046dc9fe28a46deb008c2bb68c215af119b58cd5d9518f34123c7) |

| | active liquidity at spot | Trading API |
|---|---|---|
| before | `0` | `404 ResourceNotFound` |
| after | `35645481612126` | `200`, `"route":"v4-pool"` |

Aggregate depth moved from roughly \$69 to \$74 — about five dollars. **Thinness was never the
problem.** The router ignores a pool with no liquidity at the current tick, even when inventory
sits a few ticks away and v4 itself will happily gap to it.

---

## Act 3 — the gap-free redeploy

**Blocks 11350589–11350593.** Both ranges are now pinned to the opening tick so they **meet** at
spot with no gap. The opening tick is snapped onto the spacing grid first, because inward alignment
would otherwise push both ranges away from an unaligned spot and reopen the gap.

Single-sidedness survives: at the shared boundary the other token's amount is exactly
`L(√P − √Pa) = 0`, so the sell wall still costs zero USDC.

This deployment landed on **JOULE as token0**, the opposite ordering to Act 1 — so both branches of
the ordering-dependent tick maths are now exercised on a real chain, not just in tests.

| Block | Call | Transaction |
|---|---|---|
| 11350589 | `deploy MockUSDC` | [`0x36d3dc…f462`](https://sepolia.etherscan.io/tx/0x36d3dcfb384b003d0e5868961702582ac18434641ca2b32279b9f34aa88ef462) |
| 11350589 | `deploy SumVerifier` | [`0x1a0ab9…2e83`](https://sepolia.etherscan.io/tx/0x1a0ab927767c3440ea916bc0cf1a6d858d4afecd49c782966c37e4c6f9dd2e83) |
| 11350589 | `deploy WorkEscrow` | [`0x39642b…7bba`](https://sepolia.etherscan.io/tx/0x39642bb15b101cfc0da2ff66a987482d9db65b125a4676ef301bd5dee8327bba) |

| Block | Call | Transaction |
|---|---|---|
| 11350593 | `mint(address,uint256)` | [`0xf24df6…5525`](https://sepolia.etherscan.io/tx/0xf24df63f6bad441411efb14a29000bc37f9b32b0386801027a88be9f87f05525) |
| 11350593 | `approve(address,uint256)` | [`0x389024…fd10`](https://sepolia.etherscan.io/tx/0x3890247f1d969ee76dad437abab89c60556ab449f29ae485aedf17781725fd10) |
| 11350593 | `stake(uint256)` | [`0xa3534f…34a6`](https://sepolia.etherscan.io/tx/0xa3534fa0866f447e4c204d00ce40a3b311793a81ae46f5e903d70789630634a6) |
| 11350593 | `issue(uint256)` | [`0xb92693…1d25`](https://sepolia.etherscan.io/tx/0xb92693b621180d4774011ae8d274de96ab1aca6a8a6ca901eaf0e2a0188c1d25) |
| 11350593 | `mint(address,uint256)` | [`0xa6c21a…f0c9`](https://sepolia.etherscan.io/tx/0xa6c21a649107a0604ecac145222a7c98dce2c03ab6d2bbc356c37f0ab907f0c9) |
| 11350593 | `initializePool((address,address,uint24,int24,address),uint160)` | [`0x964c06…87e5`](https://sepolia.etherscan.io/tx/0x964c067302dd7b05b21c48e1f95e04a6d88e236954a6dad10ae0706119a987e5) |
| 11350593 | `approve(address,uint256)` | [`0x8b6feb…cbae`](https://sepolia.etherscan.io/tx/0x8b6feb25398c5f785b9537a8793bd53b6c4baa85824075b91876c741f063cbae) |
| 11350593 | `approve(address,address,uint160,uint48)` | [`0x919d3f…08bd`](https://sepolia.etherscan.io/tx/0x919d3f446ce21d0c02171cf954682ae3a6f8e4e794e78fc08c216ae891bf08bd) |
| 11350593 | `approve(address,uint256)` | [`0xa51036…f708`](https://sepolia.etherscan.io/tx/0xa51036ba541294f726564b346261dc31cb46ecc483b7f55a89a27394fae5f708) |
| 11350593 | `approve(address,address,uint160,uint48)` | [`0x6757ed…b1af`](https://sepolia.etherscan.io/tx/0x6757edf70e60b1a85002e74a909e29db9a5150ae5869cd2dc457e3fb0337b1af) |
| 11350593 | `modifyLiquidities(bytes,uint256)` | [`0xbea897…a56f`](https://sepolia.etherscan.io/tx/0xbea89773954dfcb36d220bb5c3102ea7f9d752a1175d2495ee47199a0ca7a56f) |

The API quoted it immediately, with no indexing wait and nothing done by hand: 10 USDC →
`2001032626487004890` JOULE wei, 2.23% impact — **the same wei the Foundry fork test produces for
this ordering.**

---

## Act 4 — the demo, end to end

**Blocks 11351115–11351224.** A browser wallet, a real Permit2 signature, and the delivery agent
running locally. Both settlement paths in one session.

| Block | Who | What | Gas | Transaction |
|---|---|---|---|---|
| 11351115 | buyer | Mint 100 test USDC from the UI | 51 267 | [`0xee71b8…f819`](https://sepolia.etherscan.io/tx/0xee71b8775edec1605d6b305c512fc454034dc6b1157e5c1a0edda25136d7f819) |
| 11351117 | buyer | Approve USDC → Permit2 — *transaction supplied by the API's `check_approval`* | 46 618 | [`0x0c8815…6880`](https://sepolia.etherscan.io/tx/0x0c881528eb35ae8bc52d7a8b33caf8dd0d6dc9958d27ec82459f56d625336880) |
| **11351120** | buyer | **Universal Router `execute` — the buy. Calldata built entirely by the Trading API** | 187 982 | [`0xdba09c…90d9`](https://sepolia.etherscan.io/tx/0xdba09c4cc962b7c009e888a514ecd6a2a84d8a97192b14303e31274f3e8490d9) |
| 11351139 | buyer | Approve JOULE → escrow | 46 678 | [`0xf49c41…9f21`](https://sepolia.etherscan.io/tx/0xf49c41ac5e6864ca0ff6af45465f4be0c770f47e72a8f402b25f58fce2699f21) |
| 11351141 | buyer | `redeem` — job 1 opened, deadline block 11351151 | 139 306 | [`0x74b399…a3b9`](https://sepolia.etherscan.io/tx/0x74b399c19347c94161e534fa3801d12b42bb1f046a24da7282313ef04b34a3b9) |
| | | *agent not yet running — the 10-block window lapses* | | |
| 11351205 | buyer | `claimTimeout` — job 1 **Slashed**, collateral 100 → 90 USDC | 99 138 | [`0x0d06ff…2587`](https://sepolia.etherscan.io/tx/0x0d06ffa1c7fed8fbfc6a7b1f417b5da3895fd83b40c42dd608f902cba7a82587) |
| 11351208 | buyer | `withdraw` — 10 USDC refund collected | 43 204 | [`0x7ce1bd…4ae7`](https://sepolia.etherscan.io/tx/0x7ce1bdcfedd837f2a78360170a159c90385f5fe64f3dced26fd853cf166b4ae7) |
| 11351223 | buyer | `redeem` — job 2 opened, deadline block 11351233 | 139 306 | [`0xd4ff12…59a1`](https://sepolia.etherscan.io/tx/0xd4ff126107502f1277115bc79ad72e02ff2f812c5bfc53b0bdb36e343d1959a1) |
| **11351224** | **agent** | **`submitWork` — verifier confirmed, settled in the very next block, 9 to spare** | 59 721 | [`0x01f3c5…f267`](https://sepolia.etherscan.io/tx/0x01f3c5aa1fa3b585e2d5aa40aabad88cd5822875aa2021b76861b08d74e3f267) |

The `WorkSubmitted` event on the last transaction carries `verified: true` and `acceptDeadline: 0`
— proof it took the **verified path**: the verifier checked the answer inside `submitWork` and
settled immediately. No acceptance window, no counterparty, no delay.

Its gas, 59 721, is byte-identical to the figure the Foundry fork test reports.

---

## What the ledger proves

Following the numbers across Act 4:

| | collateral | outstanding | JOULE supply | buyer USDC |
|---|---|---|---|---|
| after seeding | 100 | 10 | 10 | — |
| after the buy | 100 | 10 | 10 | 100 → 90 |
| after job 1 slashed | **90** | 9 | 9 | 90 → **100** |
| after job 2 settled | 90 | **8** | **8** | 100 |

Three things fall out of that, and each is a claim the mechanism makes:

**Default is bounded and exact.** The slash moved collateral by precisely `faceValue + penalty`
= 10 USDC, and `outstanding` fell by one. Burning one Joule releases exactly what one default
costs, which is why `collateralPerJoule = faceValue + penalty` keeps the escrow solvent through a
total wipeout.

**The buyer's downside was real and covered.** They paid 10 USDC for 2.001 JOULE, were defaulted
on, and ended the session back at 100 USDC while still holding 1.001 JOULE. Bounded downside,
demonstrated rather than asserted.

**Delivering pays in released capital, not cash.** After job 2 settled, collateral stayed at 90 but
`freeCollateral` became 10 — the agent's reward for delivering is capital it can now withdraw. It
was already paid for the work back at the buy, by the pool. The escrow never touches sale proceeds.

---

## Reproducing this

```bash
yarn deploy --file DeployWorkEscrow.s.sol --network sepolia --keystore <account>
WORK_ESCROW=0x… yarn deploy --file SeedPool.s.sol --network sepolia --keystore <account>
yarn agent          # after filling agent/.env
yarn start          # then buy, redeem, and watch
```

`yarn foundry:test:fork` runs the same pool logic against a Sepolia fork without spending anything.
