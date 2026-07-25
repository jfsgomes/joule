// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";

import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { JoulePoolMath } from "../contracts/libraries/JoulePoolMath.sol";

/**
 * @notice Unit tests for the JOULE/USDC pool pricing maths.
 *
 * @dev Everything here runs twice, once per token ordering, because JouleToken's
 *      address is decided by WorkEscrow's constructor and we do not get to pick
 *      which side of the pool it lands on. A test suite that only covered
 *      `jouleIsToken0 == true` would pass on a machine where the ordering
 *      happened to fall that way and ship a mirrored pool on one where it did not.
 *
 *      The inverse price used for round-tripping is written in a deliberately
 *      different form from the library's forward maths -- reciprocal of a
 *      squared Q96 rather than a square-rooted Q192 -- so agreement is evidence
 *      rather than a restatement.
 */
/**
 * @dev Internal library calls compile to JUMPs, so they revert at the same call
 *      depth as the test and `vm.expectRevert` cannot see them. This harness
 *      re-exposes the reverting paths behind real external calls. It exists for
 *      no other reason -- the passing tests call the library directly.
 */
contract JoulePoolMathHarness {
    function sqrtPriceX96For(uint256 usdcPerJoule, bool jouleIsToken0) external pure returns (uint160) {
        return JoulePoolMath.sqrtPriceX96For(usdcPerJoule, jouleIsToken0);
    }

    function rangeFromTick(int24 pinnedTick, uint256 price, bool jouleIsToken0, int24 spacing)
        external
        pure
        returns (int24, int24)
    {
        return JoulePoolMath.rangeFromTick(pinnedTick, price, jouleIsToken0, spacing);
    }

    function assertSingleSided(int24 tickLower, int24 tickUpper, int24 currentTick, bool wantToken0) external pure {
        JoulePoolMath.assertSingleSided(tickLower, tickUpper, currentTick, wantToken0);
    }
}

contract JoulePoolMathTest is Test {
    int24 constant SPACING = 60;

    JoulePoolMathHarness harness;

    function setUp() public {
        harness = new JoulePoolMathHarness();
    }

    uint256 constant USDC = 1e6;
    uint256 constant SPOT = 4_900_000; // 4.90 USDC per Joule
    uint256 constant SELL_HI = 6_000_000; // 6.00, far edge of the wall
    uint256 constant BID_LO = 4_000_000; // 4.00, far edge of the bid

    uint256 constant Q96 = 1 << 96;

    // --- helpers ---

    /// @dev Recovers USDC-base-units-per-whole-Joule from a sqrt price.
    function _priceFrom(uint160 sqrtPriceX96, bool jouleIsToken0) internal pure returns (uint256) {
        // priceX96 = (raw token1 per raw token0) * 2**96
        uint256 priceX96 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), Q96);

        return jouleIsToken0
            // price is USDC/JOULE already: scale by a whole Joule, drop the Q96.
            ? FullMath.mulDiv(priceX96, JoulePoolMath.JOULE_UNIT, Q96)
            // price is JOULE/USDC: invert, which puts the Q96 in the numerator.
            : FullMath.mulDiv(JoulePoolMath.JOULE_UNIT, Q96, priceX96);
    }

    function _assertClose(uint256 got, uint256 want, uint256 tolBps, string memory what) internal pure {
        uint256 diff = got > want ? got - want : want - got;
        assertLe(diff * 10_000, want * tolBps, what);
    }

    // --- price encoding ---

    function test_SqrtPriceRoundTrips_JouleIsToken0() public pure {
        uint160 sqrtPriceX96 = JoulePoolMath.sqrtPriceX96For(SPOT, true);
        _assertClose(_priceFrom(sqrtPriceX96, true), SPOT, 1, "spot round-trip");
    }

    function test_SqrtPriceRoundTrips_JouleIsToken1() public pure {
        uint160 sqrtPriceX96 = JoulePoolMath.sqrtPriceX96For(SPOT, false);
        _assertClose(_priceFrom(sqrtPriceX96, false), SPOT, 1, "spot round-trip");
    }

    /**
     * @dev The 18-vs-6 decimal guard, stated as a magnitude rather than a
     *      round-trip so it fails loudly if the scaling is ever "tidied".
     *      With JOULE as token0 the pool price is 5e6/1e18 = 5e-12, so the sqrt
     *      price is tiny; get the decimals wrong by 1e12 and it lands orders of
     *      magnitude away from here.
     */
    function test_DecimalScalingIsNotOffByTwelveOrders() public pure {
        uint160 asToken0 = JoulePoolMath.sqrtPriceX96For(5 * USDC, true);
        uint160 asToken1 = JoulePoolMath.sqrtPriceX96For(5 * USDC, false);

        // sqrt(5e-12) * 2**96 ~= 1.7716e23
        assertGt(uint256(asToken0), 1.75e23, "token0 sqrt price too low");
        assertLt(uint256(asToken0), 1.80e23, "token0 sqrt price too high");

        // sqrt(2e11) * 2**96 ~= 3.5432e34
        assertGt(uint256(asToken1), 3.50e34, "token1 sqrt price too low");
        assertLt(uint256(asToken1), 3.60e34, "token1 sqrt price too high");
    }

    /// @dev Inverting the ordering inverts the price, so the ticks mirror about zero.
    function test_TicksMirrorAcrossOrdering() public pure {
        int24 asToken0 = JoulePoolMath.tickFor(SPOT, true);
        int24 asToken1 = JoulePoolMath.tickFor(SPOT, false);

        assertLt(asToken0, int24(0), "USDC/JOULE price is far below 1");
        assertGt(asToken1, int24(0), "JOULE/USDC price is far above 1");

        int24 drift = asToken0 + asToken1; // ~0 if they mirror
        assertLe(drift < 0 ? -drift : drift, int24(2), "ticks should mirror within rounding");
    }

    function test_HigherUsdcPriceRaisesTickOnlyWhenJouleIsToken0() public pure {
        assertGt(JoulePoolMath.tickFor(SELL_HI, true), JoulePoolMath.tickFor(SPOT, true), "token0: price up, tick up");
        assertLt(
            JoulePoolMath.tickFor(SELL_HI, false), JoulePoolMath.tickFor(SPOT, false), "token1: price up, tick DOWN"
        );
    }

    function test_RevertsOnZeroPrice() public {
        vm.expectRevert(JoulePoolMath.ZeroPrice.selector);
        harness.sqrtPriceX96For(0, true);
    }

    // --- tick alignment ---

    function test_FloorAndCeilRoundAwayFromEachOtherOnNegativeTicks() public pure {
        // -100 sits between -120 and -60 at spacing 60.
        assertEq(JoulePoolMath.floorToSpacing(-100, 60), int24(-120), "floor(-100)");
        assertEq(JoulePoolMath.ceilToSpacing(-100, 60), int24(-60), "ceil(-100)");

        assertEq(JoulePoolMath.floorToSpacing(100, 60), int24(60), "floor(100)");
        assertEq(JoulePoolMath.ceilToSpacing(100, 60), int24(120), "ceil(100)");
    }

    function test_AlignmentIsIdempotentOnExactMultiples() public pure {
        assertEq(JoulePoolMath.floorToSpacing(-120, 60), int24(-120), "floor(-120)");
        assertEq(JoulePoolMath.ceilToSpacing(-120, 60), int24(-120), "ceil(-120)");
    }

    function testFuzz_AlignedTicksAreMultiplesAndBracketTheInput(int24 tick) public pure {
        tick = int24(bound(tick, TickMath.MIN_TICK, TickMath.MAX_TICK));

        int24 lo = JoulePoolMath.floorToSpacing(tick, SPACING);
        int24 hi = JoulePoolMath.ceilToSpacing(tick, SPACING);

        assertEq(lo % SPACING, int24(0), "floor is a multiple");
        assertEq(hi % SPACING, int24(0), "ceil is a multiple");
        assertLe(lo, tick, "floor never exceeds input");
        assertGe(hi, tick, "ceil never undershoots input");
        assertLt(tick - lo, SPACING, "floor within one spacing");
        assertLt(hi - tick, SPACING, "ceil within one spacing");
    }

    // --- ranges ---

    /// @dev The pinned side must survive untouched. Rounding it would reopen the
    ///      gap at spot by up to one spacing, which is the whole bug.
    function test_PinnedSideIsNeverMoved() public pure {
        for (uint256 i = 0; i < 2; i++) {
            bool jouleIsToken0 = i == 0;
            int24 spot = JoulePoolMath.alignedSpotTick(SPOT, jouleIsToken0, SPACING);

            (int24 sellLower, int24 sellUpper) = JoulePoolMath.rangeFromTick(spot, SELL_HI, jouleIsToken0, SPACING);
            assertTrue(sellLower == spot || sellUpper == spot, "wall is pinned to spot");

            (int24 bidLower, int24 bidUpper) = JoulePoolMath.rangeFromTick(spot, BID_LO, jouleIsToken0, SPACING);
            assertTrue(bidLower == spot || bidUpper == spot, "bid is pinned to spot");
        }
    }

    /// @dev The far side rounds inward, so a band never reaches past the price
    ///      it was asked for.
    function test_FarSideRoundsInward() public pure {
        int24 spot = JoulePoolMath.alignedSpotTick(SPOT, true, SPACING);
        (, int24 upper) = JoulePoolMath.rangeFromTick(spot, SELL_HI, true, SPACING);

        assertLe(upper, JoulePoolMath.tickFor(SELL_HI, true), "far edge rounded inward");
        assertGt(upper, spot, "range is non-empty");
    }

    function test_AlignedSpotTickIsOnTheGrid() public pure {
        assertEq(JoulePoolMath.alignedSpotTick(SPOT, true, SPACING) % SPACING, int24(0), "token0 case");
        assertEq(JoulePoolMath.alignedSpotTick(SPOT, false, SPACING) % SPACING, int24(0), "token1 case");
    }

    function test_RevertsWhenBandCollapsesBelowOneSpacing() public {
        // A far price inside the same spacing step as the pin leaves nothing.
        int24 spot = JoulePoolMath.alignedSpotTick(SPOT, true, SPACING);
        vm.expectRevert(abi.encodeWithSelector(JoulePoolMath.RangeTooNarrow.selector, spot, spot));
        harness.rangeFromTick(spot, SPOT, true, SPACING);
    }

    // --- the seeding geometry, both orderings ---

    function test_SellWallHoldsOnlyJoule_JouleIsToken0() public pure {
        _assertSeedGeometry(true);
    }

    function test_SellWallHoldsOnlyJoule_JouleIsToken1() public pure {
        _assertSeedGeometry(false);
    }

    /**
     * @dev The whole hybrid seed, checked as geometry: a JOULE-only sell wall on
     *      one side of spot, a USDC-only bid on the other, the two meeting
     *      exactly AT spot with no gap. Which tick direction each lands in flips
     *      with the ordering, which is exactly why this runs twice.
     */
    function _assertSeedGeometry(bool jouleIsToken0) internal pure {
        int24 spotTick = JoulePoolMath.alignedSpotTick(SPOT, jouleIsToken0, SPACING);

        (int24 sellLower, int24 sellUpper) = JoulePoolMath.rangeFromTick(spotTick, SELL_HI, jouleIsToken0, SPACING);
        (int24 bidLower, int24 bidUpper) = JoulePoolMath.rangeFromTick(spotTick, BID_LO, jouleIsToken0, SPACING);

        // The sell wall is funded in JOULE, the bid in USDC. Still exactly true
        // at the shared boundary: the other side's amount there is zero.
        JoulePoolMath.assertSingleSided(sellLower, sellUpper, spotTick, jouleIsToken0);
        JoulePoolMath.assertSingleSided(bidLower, bidUpper, spotTick, !jouleIsToken0);

        // Sell wall sits at higher ticks only when JOULE is token0.
        if (jouleIsToken0) {
            assertEq(sellLower, spotTick, "wall starts at spot");
            assertEq(bidUpper, spotTick, "bid ends at spot");
        } else {
            assertEq(sellUpper, spotTick, "wall ends at spot");
            assertEq(bidLower, spotTick, "bid starts at spot");
        }

        // Half-open intervals, so meeting at spot is not overlapping.
        assertTrue(sellUpper <= bidLower || bidUpper <= sellLower, "ranges disjoint");

        // Exactly one range must be live at spot, or a router sees an empty pool.
        bool sellLive = sellLower <= spotTick && spotTick < sellUpper;
        bool bidLive = bidLower <= spotTick && spotTick < bidUpper;
        assertTrue(sellLive != bidLive, "exactly one range is live at spot");
    }

    /// @dev The mirrored-range failure MECHANISM.md warns about: fund the sell
    ///      wall as though the ordering were the other way and the check must bite.
    function test_MirroredSellWallIsRejected() public {
        bool jouleIsToken0 = true;
        int24 spotTick = JoulePoolMath.alignedSpotTick(SPOT, jouleIsToken0, SPACING);
        (int24 lower, int24 upper) = JoulePoolMath.rangeFromTick(spotTick, SELL_HI, jouleIsToken0, SPACING);

        // Claiming this range holds token1 (USDC) is false -- it is above spot.
        vm.expectRevert(
            abi.encodeWithSelector(JoulePoolMath.NotSingleSided.selector, lower, upper, spotTick, false)
        );
        harness.assertSingleSided(lower, upper, spotTick, false);
    }

    // --- liquidity ---

    /// @dev Ten Joules of inventory must produce liquidity on either ordering.
    ///      The figures differ because the tick ranges differ; what must hold is
    ///      that neither branch silently yields zero, which would mint an empty
    ///      position and look like a successful seed.
    function test_SingleSidedLiquidityIsNonZeroOnBothOrderings() public pure {
        for (uint256 i = 0; i < 2; i++) {
            bool jouleIsToken0 = i == 0;
            int24 spotTick = JoulePoolMath.alignedSpotTick(SPOT, jouleIsToken0, SPACING);

            (int24 sellLower, int24 sellUpper) = JoulePoolMath.rangeFromTick(spotTick, SELL_HI, jouleIsToken0, SPACING);
            uint128 sellLiquidity = JoulePoolMath.singleSidedLiquidity(sellLower, sellUpper, 10 ether, jouleIsToken0);
            assertGt(sellLiquidity, 0, "sell wall liquidity");

            (int24 bidLower, int24 bidUpper) = JoulePoolMath.rangeFromTick(spotTick, BID_LO, jouleIsToken0, SPACING);
            uint128 bidLiquidity = JoulePoolMath.singleSidedLiquidity(bidLower, bidUpper, 20 * USDC, !jouleIsToken0);
            assertGt(bidLiquidity, 0, "bid liquidity");
        }
    }

    function testFuzz_PriceRoundTripsAcrossThePlausibleBand(uint256 price, bool jouleIsToken0) public pure {
        // 0.01 USDC to 10,000 USDC per Joule -- far wider than the demo needs.
        price = bound(price, USDC / 100, 10_000 * USDC);

        uint160 sqrtPriceX96 = JoulePoolMath.sqrtPriceX96For(price, jouleIsToken0);
        _assertClose(_priceFrom(sqrtPriceX96, jouleIsToken0), price, 1, "round-trip");
    }
}
