// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title SepoliaV4
 * @notice Uniswap v4 deployment addresses for Ethereum Sepolia (11155111).
 *
 * @dev VERIFIED ONCHAIN, not copied from docs. Every address below was checked
 *      with `cast code` and, where the contract exposes it, cross-checked by
 *      calling `.poolManager()` and confirming it resolves to POOL_MANAGER.
 *      Three independent peripherals agreeing on the same PoolManager is what
 *      makes this a real deployment rather than six plausible-looking strings.
 *      Last re-verified 2026-07-25.
 *
 *      DO NOT COPY THESE TO ANOTHER CHAIN. Uniswap's own docs are explicit that
 *      v4 addresses are not deterministic across networks -- unlike v3 there is
 *      no CREATE2 guarantee, so the same address on another chain is either
 *      nothing or something else entirely. The Unichain Sepolia fallback set
 *      lives in PLAN.md and must be re-verified the same way before use.
 */
library SepoliaV4 {
    uint256 internal constant CHAIN_ID = 11155111;

    address internal constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address internal constant POSITION_MANAGER = 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4;
    address internal constant STATE_VIEW = 0xE1Dd9c3fA50EDB962E442f60DfBc432e24537E4C;
    address internal constant QUOTER = 0x61B3f2011A92d183C7dbaDBdA940a7555Ccf9227;
    address internal constant UNIVERSAL_ROUTER = 0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b;

    /// @dev Permit2 IS the same on every chain -- it is a canonical CREATE2
    ///      deploy. It is the one address here that may be reused elsewhere.
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
}

/**
 * @title JoulePoolParams
 * @notice The demo pool's shape, in one place so the deploy script, the fork
 *         test and the frontend cannot drift apart.
 *
 * @dev Prices are USDC base units (6 decimals) per WHOLE Joule, so 5.00 USDC is
 *      5_000_000. See JoulePoolMath for why that convention exists.
 *
 *      The hybrid seed, decided 2026-07-25:
 *
 *        SELL WALL  10 JOULE from spot up to 6.00, funded with ZERO USDC.
 *                   A range order -- a limit sell expressed as liquidity. It is
 *                   100% JOULE the moment it is minted and converts to USDC as
 *                   buyers push through it. Average execution is the geometric
 *                   mean, sqrt(4.90 * 6.00) ~= 5.42.
 *
 *        BID        20 USDC from spot down to 4.00, funded with ZERO JOULE.
 *                   Not required to sell Joules, and MECHANISM.md's pure
 *                   single-sided design omits it. It is here because without
 *                   liquidity below spot nobody can sell a Joule BACK: the
 *                   price chart could only ever go up, and the "agent buys back
 *                   its own Joules below floor" behaviour has no market to act
 *                   in. 20 USDC buys a two-directional demo for a third of what
 *                   a symmetric two-sided seed would cost.
 *
 *      THE TWO RANGES TOUCH AT SPOT. There is no gap and no bid/ask spread,
 *      which is deliberate and was learned the hard way. An earlier version
 *      opened at 4.90 with the wall at [5.00, 6.00] and the bid at
 *      [4.00, 4.80]; that pool held 10 JOULE and 20 USDC, swapped correctly
 *      under v4, and was INVISIBLE to the Uniswap Trading API, which returned
 *      404 ResourceNotFound because `getLiquidity()` at the opening tick was
 *      zero. Confirmed on Sepolia: adding a position spanning spot -- worth
 *      about five dollars, changing aggregate depth barely at all -- flipped it
 *      to a working quote. Thin is fine; a hole at spot is not.
 *
 *      Losing the spread costs a round-tripper only the 0.6% in fees, which is
 *      a small price for being routable.
 */
library JoulePoolParams {
    /// @dev 0.30%, the familiar tier. NOT chosen for routability: the Trading
    ///      API was observed on 2026-07-25 routing a Sepolia v4 ETH/USDC pool
    ///      with fee 20 and tickSpacing 1, so non-standard tiers quote fine and
    ///      an exotic fee is not the risk it is often described as. This is
    ///      picked because it is legible to anyone reading the demo.
    uint24 internal constant FEE = 3000;

    /// @dev The canonical spacing for the 0.30% tier. At ~0.6% of price per
    ///      step it is fine enough that alignment barely moves our bounds.
    int24 internal constant TICK_SPACING = 60;

    /// @dev The opening price, and the shared boundary of both ranges. Snapped
    ///      onto the tick-spacing grid at seed time -- see
    ///      JoulePoolMath.alignedSpotTick -- so the realised opening price is
    ///      within one 60-tick step (~0.6%) of this.
    uint256 internal constant SPOT_PRICE = 4_900_000; // 4.90 USDC per Joule

    /// @dev Far edge of the sell wall. The near edge is spot.
    uint256 internal constant SELL_HIGH = 6_000_000; // 6.00

    /// @dev Far edge of the bid. The near edge is spot.
    uint256 internal constant BID_LOW = 4_000_000; // 4.00

    /// @dev Matches the 10 Joules the agent issues against 100 USDC of
    ///      collateral at collateralPerJoule = 10 USDC. Issuing more and
    ///      seeding less would leave Joules outstanding with no market.
    uint256 internal constant JOULE_INVENTORY = 10 ether;

    uint256 internal constant USDC_BID = 20_000_000; // 20 USDC
}
