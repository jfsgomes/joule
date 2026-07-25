// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { LiquidityAmounts } from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";

/**
 * @title JoulePoolMath
 * @notice Price and tick maths for the JOULE/USDC Uniswap v4 pool.
 *
 * @dev This is seeding maths, not protocol maths -- nothing in WorkEscrow reads
 *      a price. It lives under `contracts/` rather than `script/` for one
 *      reason: it is where the 18-vs-6 decimal bug would hide, and that class of
 *      bug is only caught by unit tests. See JoulePoolMath.t.sol.
 *
 *      TWO THINGS THIS LIBRARY EXISTS TO GET RIGHT:
 *
 *      1. DECIMALS. JOULE has 18, USDC has 6. A Uniswap price is a ratio of RAW
 *         units, so "5 USDC per JOULE" is not 5 -- it is 5e6/1e18 = 5e-12. Every
 *         function here takes price as USDC base units per WHOLE Joule (so 5.00
 *         USDC is `5_000_000`) and does the scaling internally, so no caller
 *         ever hand-rolls the conversion.
 *
 *      2. ORDERING. Uniswap sorts pool tokens by address. JouleToken is deployed
 *         inside WorkEscrow's constructor, so its address is not ours to choose
 *         and either token may end up as token0. When JOULE is token1 the pool
 *         price is INVERTED -- it reads as JOULE per USDC -- which flips the tick
 *         direction. Every function therefore takes `jouleIsToken0` explicitly
 *         and there is no default. Callers must derive it from the deployed
 *         addresses, never assume it.
 */
library JoulePoolMath {
    /// @notice One whole Joule. Matches JouleToken.ONE.
    uint256 internal constant JOULE_UNIT = 1e18;

    /// @dev 2**192. Squaring a Q64.96 sqrt price gives a Q128.192 price, so this
    ///      is the scaling factor that survives the sqrt back down to Q64.96.
    uint256 internal constant Q192 = 1 << 192;

    error ZeroPrice();
    error PriceOutOfRange(uint256 sqrtPriceX96);
    error RangeTooNarrow(int24 tickLower, int24 tickUpper);
    error InvalidSpacing(int24 spacing);
    error NotSingleSided(int24 tickLower, int24 tickUpper, int24 currentTick, bool wantToken0);

    /**
     * @notice sqrtPriceX96 for a price of `usdcPerJoule` USDC base units per whole Joule.
     * @param usdcPerJoule Price in USDC base units (6dp). 5.00 USDC is `5_000_000`.
     * @param jouleIsToken0 True iff `address(joule) < address(usdc)`.
     *
     * @dev The pool price is always raw-token1-per-raw-token0, so the two
     *      branches are genuinely different quantities rather than reciprocal
     *      conveniences:
     *        JOULE is token0 -> price = usdcPerJoule / 1e18   (a tiny number)
     *        JOULE is token1 -> price = 1e18 / usdcPerJoule   (a huge number)
     *      Both are far inside the representable band, but the assertion below
     *      is kept because an out-of-range sqrt price makes `initialize` revert
     *      with an opaque error much later.
     */
    function sqrtPriceX96For(uint256 usdcPerJoule, bool jouleIsToken0) internal pure returns (uint160) {
        if (usdcPerJoule == 0) revert ZeroPrice();

        // mulDiv, not `*`, so the Q192 scaling cannot overflow before the divide.
        uint256 ratioX192 = jouleIsToken0
            ? FullMath.mulDiv(usdcPerJoule, Q192, JOULE_UNIT)
            : FullMath.mulDiv(JOULE_UNIT, Q192, usdcPerJoule);

        uint256 sqrtPriceX96 = FixedPointMathLib.sqrt(ratioX192);

        if (sqrtPriceX96 < TickMath.MIN_SQRT_PRICE || sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) {
            revert PriceOutOfRange(sqrtPriceX96);
        }
        return uint160(sqrtPriceX96);
    }

    /// @notice The tick containing a given USDC-per-Joule price.
    function tickFor(uint256 usdcPerJoule, bool jouleIsToken0) internal pure returns (int24) {
        return TickMath.getTickAtSqrtPrice(sqrtPriceX96For(usdcPerJoule, jouleIsToken0));
    }

    /**
     * @notice Tick range covering the price band between `priceA` and `priceB`.
     *
     * @dev The two prices are sorted AFTER conversion, not before. That is what
     *      makes this ordering-agnostic: when JOULE is token1 the price is
     *      inverted, so the higher USDC price maps to the LOWER tick, and a
     *      caller who sorted by price first would build the range backwards.
     *
     *      Alignment is INWARD -- lower rounds up, upper rounds down -- so a
     *      band never widens toward spot. Rounding outward could drag a range
     *      that was placed strictly above spot back across it, silently turning
     *      a single-sided position into a two-sided one that demands the token
     *      the caller intended not to spend.
     */
    function rangeFor(uint256 priceA, uint256 priceB, bool jouleIsToken0, int24 spacing)
        internal
        pure
        returns (int24 tickLower, int24 tickUpper)
    {
        if (spacing <= 0) revert InvalidSpacing(spacing);

        int24 tickA = tickFor(priceA, jouleIsToken0);
        int24 tickB = tickFor(priceB, jouleIsToken0);
        (tickLower, tickUpper) = tickA < tickB ? (tickA, tickB) : (tickB, tickA);

        tickLower = ceilToSpacing(tickLower, spacing);
        tickUpper = floorToSpacing(tickUpper, spacing);

        if (tickLower >= tickUpper) revert RangeTooNarrow(tickLower, tickUpper);
    }

    /// @dev Rounds toward negative infinity. Solidity's `/` truncates toward
    ///      zero, which for negative ticks rounds the wrong way.
    function floorToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) compressed--;
        return compressed * spacing;
    }

    /// @dev Rounds toward positive infinity. Same truncation caveat, mirrored.
    function ceilToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick > 0 && tick % spacing != 0) compressed++;
        return compressed * spacing;
    }

    /**
     * @notice Liquidity for a position funded with ONE token only.
     * @param isToken0 Which token funds it. Must match the side of spot the
     *                 range sits on -- call `assertSingleSided` first.
     */
    function singleSidedLiquidity(int24 tickLower, int24 tickUpper, uint256 amount, bool isToken0)
        internal
        pure
        returns (uint128)
    {
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);

        return isToken0
            ? LiquidityAmounts.getLiquidityForAmount0(sqrtLower, sqrtUpper, amount)
            : LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtUpper, amount);
    }

    /**
     * @notice Reverts unless [tickLower, tickUpper) sits wholly on the side of
     *         `currentTick` that makes it hold `wantToken0` and nothing else.
     *
     * @dev This is the check that catches a mirrored range. A concentrated
     *      position holds only token0 while spot is below it and only token1
     *      while spot is at or above it; anywhere in between it holds a mix.
     *      Placing the JOULE sell wall on the wrong side of spot turns it into a
     *      BUY wall that fills instantly against the agent -- the exact failure
     *      MECHANISM.md flags under "Two things that will bite".
     */
    function assertSingleSided(int24 tickLower, int24 tickUpper, int24 currentTick, bool wantToken0) internal pure {
        bool ok = wantToken0 ? currentTick < tickLower : currentTick >= tickUpper;
        if (!ok) revert NotSingleSided(tickLower, tickUpper, currentTick, wantToken0);
    }
}
