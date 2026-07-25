// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test, console } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { PoolSwapTest } from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import { IPositionManager } from "v4-periphery/src/interfaces/IPositionManager.sol";
import { IStateView } from "v4-periphery/src/interfaces/IStateView.sol";
import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";

import { MockUSDC } from "../../contracts/MockUSDC.sol";
import { JouleToken } from "../../contracts/JouleToken.sol";
import { WorkEscrow } from "../../contracts/WorkEscrow.sol";
import { SumVerifier } from "../../contracts/verifiers/SumVerifier.sol";
import { IVerifier } from "../../contracts/verifiers/IVerifier.sol";

import { SepoliaV4, JoulePoolParams } from "../../script/JouleAddresses.sol";
import { JoulePoolSeeder } from "../../script/JoulePoolSeeder.sol";

/**
 * @notice Milestone 3: the JOULE/USDC pool against the REAL Uniswap v4 on a
 *         Sepolia fork.
 *
 * @dev Not in the default `forge test` path. CI has no funded RPC and public
 *      endpoints rate-limit, so `yarn test` excludes `test/fork/**` and
 *      `yarn test:fork` runs it. Every test here also skips itself if the fork
 *      cannot be created, so a laptop with no network gets a skip rather than a
 *      failure that looks like a broken contract.
 *
 *      WHY THIS EXISTS RATHER THAN A MOCK POOLMANAGER: the two things most
 *      likely to be wrong -- token ordering and 18-vs-6 decimal scaling -- are
 *      wrong in ways a mock we wrote would agree with. Only the real
 *      PoolManager can refuse a mirrored range.
 *
 *      EVERY POOL TEST RUNS TWICE, once per token ordering. JouleToken is
 *      deployed inside WorkEscrow's constructor, so its address -- and
 *      therefore whether it sorts as token0 -- is not ours to choose. The
 *      helper below redeploys the escrow until it lands on the ordering under
 *      test, which is the only honest way to cover the branch that will
 *      actually ship.
 */
contract JoulePoolForkTest is Test {
    using PoolIdLibrary for PoolKey;

    // Escrow parameters, matching DeployWorkEscrow and docs/MECHANISM.md.
    uint256 constant FACE_VALUE = 5e6;
    uint256 constant PENALTY = 5e6;
    uint256 constant COLLATERAL_PER_JOULE = 10e6;
    uint256 constant DELIVERY_BLOCKS = 10;
    uint256 constant ACCEPT_BLOCKS = 5;

    address agent = makeAddr("agent");
    address arbiter = makeAddr("arbiter");
    address buyer = makeAddr("buyer");

    IPositionManager posm = IPositionManager(SepoliaV4.POSITION_MANAGER);
    IAllowanceTransfer permit2 = IAllowanceTransfer(SepoliaV4.PERMIT2);
    IStateView stateView = IStateView(SepoliaV4.STATE_VIEW);

    PoolSwapTest swapRouter;
    bool forked;

    // --- fork setup ---

    function setUp() public {
        try vm.createSelectFork(vm.rpcUrl("sepoliaPublic")) {
            forked = true;
        } catch {
            forked = false;
            return;
        }

        assertEq(block.chainid, SepoliaV4.CHAIN_ID, "not on Sepolia");

        // The addresses are only useful if something is actually deployed at
        // them. Assert here so a moved deployment fails with this message
        // rather than as an unexplained revert inside a swap.
        assertGt(SepoliaV4.POOL_MANAGER.code.length, 0, "no PoolManager");
        assertGt(SepoliaV4.POSITION_MANAGER.code.length, 0, "no PositionManager");
        assertGt(SepoliaV4.STATE_VIEW.code.length, 0, "no StateView");
        assertGt(SepoliaV4.PERMIT2.code.length, 0, "no Permit2");

        swapRouter = new PoolSwapTest(IPoolManager(SepoliaV4.POOL_MANAGER));
    }

    modifier onFork() {
        if (!forked) {
            emit log("skipping: could not reach the Sepolia RPC");
            vm.skip(true);
        }
        _;
    }

    // --- deployment helpers ---

    struct Stack {
        MockUSDC usdc;
        WorkEscrow escrow;
        JouleToken joule;
    }

    /**
     * @dev Deploys the escrow repeatedly until JouleToken's address sorts on
     *      the requested side of MockUSDC. WorkEscrow mints a fresh JouleToken
     *      in its constructor, so each attempt is an independent coin flip;
     *      forty misses in a row is a 1-in-2^40 event, so exhausting the loop
     *      means something is structurally wrong rather than unlucky.
     */
    function _deployStack(bool wantJouleIsToken0) internal returns (Stack memory stack) {
        stack.usdc = new MockUSDC();
        SumVerifier verifier = new SumVerifier();

        for (uint256 i = 0; i < 40; i++) {
            WorkEscrow escrow = new WorkEscrow(
                IERC20(address(stack.usdc)),
                IVerifier(address(verifier)),
                agent,
                arbiter,
                FACE_VALUE,
                PENALTY,
                COLLATERAL_PER_JOULE,
                DELIVERY_BLOCKS,
                ACCEPT_BLOCKS
            );
            JouleToken joule = escrow.joule();

            if ((address(joule) < address(stack.usdc)) == wantJouleIsToken0) {
                stack.escrow = escrow;
                stack.joule = joule;
                return stack;
            }
        }
        revert("could not reach the requested token ordering in 40 deploys");
    }

    /// @dev Stakes collateral and issues `count` whole Joules to the agent.
    function _stakeAndIssue(Stack memory stack, uint256 count) internal {
        uint256 collateral = COLLATERAL_PER_JOULE * count;
        stack.usdc.mint(agent, collateral + JoulePoolParams.USDC_BID);

        vm.startPrank(agent);
        stack.usdc.approve(address(stack.escrow), type(uint256).max);
        stack.escrow.stake(collateral);
        stack.escrow.issue(count);
        vm.stopPrank();
    }

    function _recipe(Stack memory stack) internal pure returns (JoulePoolSeeder.Recipe memory) {
        return JoulePoolSeeder.Recipe({
            joule: address(stack.joule),
            usdc: address(stack.usdc),
            spotPrice: JoulePoolParams.SPOT_PRICE,
            sellHigh: JoulePoolParams.SELL_HIGH,
            bidLow: JoulePoolParams.BID_LOW,
            jouleInventory: JoulePoolParams.JOULE_INVENTORY,
            usdcBid: JoulePoolParams.USDC_BID,
            fee: JoulePoolParams.FEE,
            tickSpacing: JoulePoolParams.TICK_SPACING
        });
    }

    function _seed(Stack memory stack) internal returns (JoulePoolSeeder.Seeded memory seeded) {
        JoulePoolSeeder.Recipe memory recipe = _recipe(stack);
        seeded = JoulePoolSeeder.plan(recipe);

        JoulePoolSeeder.Venue memory venue =
            JoulePoolSeeder.Venue({ posm: posm, permit2: permit2, stateView: stateView });

        vm.startPrank(agent);
        JoulePoolSeeder.execute(venue, recipe, seeded, agent, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function _priceLimit(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function _swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        return swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: _priceLimit(zeroForOne)
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            ""
        );
    }

    // --- the pool opens where we said it would ---

    function test_PoolOpensAtSpot_JouleIsToken0() public onFork {
        _assertPoolOpensAtSpot(true);
    }

    function test_PoolOpensAtSpot_JouleIsToken1() public onFork {
        _assertPoolOpensAtSpot(false);
    }

    function _assertPoolOpensAtSpot(bool wantJouleIsToken0) internal {
        Stack memory stack = _deployStack(wantJouleIsToken0);
        _stakeAndIssue(stack, 10);
        JoulePoolSeeder.Seeded memory seeded = _seed(stack);

        assertEq(seeded.jouleIsToken0, wantJouleIsToken0, "ordering under test");

        (uint160 sqrtPriceX96, int24 tick,,) = stateView.getSlot0(seeded.key.toId());
        assertEq(sqrtPriceX96, seeded.sqrtPriceX96, "pool opened at the planned price");
        assertEq(tick, seeded.spotTick, "pool opened at the planned tick");
    }

    // --- the seed costs no USDC beyond the bid ---

    function test_SellWallCostsZeroUsdc_JouleIsToken0() public onFork {
        _assertSeedFunding(true);
    }

    function test_SellWallCostsZeroUsdc_JouleIsToken1() public onFork {
        _assertSeedFunding(false);
    }

    /**
     * @dev The capital-efficiency claim in MECHANISM.md, measured rather than
     *      asserted in prose: the sell wall is a range order placed entirely
     *      above spot, so it is 100% JOULE at open and consumes no USDC. The
     *      only USDC that leaves the agent is the 20 that funds the bid -- the
     *      deliberate cost of a two-directional market. A two-sided seed at
     *      these parameters would have cost 50.
     */
    function _assertSeedFunding(bool wantJouleIsToken0) internal {
        Stack memory stack = _deployStack(wantJouleIsToken0);
        _stakeAndIssue(stack, 10);

        uint256 usdcBefore = stack.usdc.balanceOf(agent);
        uint256 jouleBefore = stack.joule.balanceOf(agent);
        assertEq(jouleBefore, 10 ether, "agent holds the issued Joules");

        _seed(stack);

        uint256 usdcSpent = usdcBefore - stack.usdc.balanceOf(agent);
        uint256 jouleSpent = jouleBefore - stack.joule.balanceOf(agent);

        assertLe(usdcSpent, JoulePoolParams.USDC_BID, "no USDC beyond the bid");
        assertGt(usdcSpent, (JoulePoolParams.USDC_BID * 99) / 100, "the bid was actually funded");

        // Liquidity rounds down, so a wei or two of inventory stays behind.
        assertLe(jouleSpent, JoulePoolParams.JOULE_INVENTORY, "never more than the inventory");
        assertGt(jouleSpent, (JoulePoolParams.JOULE_INVENTORY * 99) / 100, "the wall was actually funded");
    }

    // --- buying walks the price up through the sell wall ---

    function test_BuyingWalksPriceUp_JouleIsToken0() public onFork {
        _assertBuyingWalksPriceUp(true);
    }

    function test_BuyingWalksPriceUp_JouleIsToken1() public onFork {
        _assertBuyingWalksPriceUp(false);
    }

    /**
     * @dev Demo step 2. A buyer spends 10 USDC and receives Joules at roughly
     *      the ask, and the pool price moves in the direction that means "more
     *      expensive" -- which is UP in ticks only when JOULE is token0.
     */
    function _assertBuyingWalksPriceUp(bool wantJouleIsToken0) internal {
        Stack memory stack = _deployStack(wantJouleIsToken0);
        _stakeAndIssue(stack, 10);
        JoulePoolSeeder.Seeded memory seeded = _seed(stack);

        (, int24 tickBefore,,) = stateView.getSlot0(seeded.key.toId());

        stack.usdc.mint(buyer, 100e6);
        vm.startPrank(buyer);
        stack.usdc.approve(address(swapRouter), type(uint256).max);
        stack.joule.approve(address(swapRouter), type(uint256).max);
        // Buying JOULE spends USDC. USDC is token1 exactly when JOULE is token0.
        _swap(seeded.key, !seeded.jouleIsToken0, -int256(10e6));
        vm.stopPrank();

        uint256 bought = stack.joule.balanceOf(buyer);
        assertGt(bought, 0, "buyer received Joules");

        // The wall now opens AT spot, so the ceiling is the spot price itself
        // rather than a separate ask. The 1% allowance is tick alignment: the
        // opening tick is snapped down onto the 60-tick grid, which is worth up
        // to ~0.6% of price and always in the buyer's favour.
        uint256 ceiling = (10e6 * 1 ether * 101) / (JoulePoolParams.SPOT_PRICE * 100);
        assertLt(bought, ceiling, "cannot beat the opening ask");
        assertGt(bought, (ceiling * 85) / 100, "execution is near the ask, not miles through it");

        (, int24 tickAfter,,) = stateView.getSlot0(seeded.key.toId());
        if (seeded.jouleIsToken0) {
            assertGt(tickAfter, tickBefore, "JOULE dearer means higher tick");
        } else {
            assertLt(tickAfter, tickBefore, "price is inverted, so dearer means LOWER tick");
        }

        console.log("bought (1e18 JOULE):", bought);
        console.log("effective price (USDC per JOULE, 1e6):", (10e6 * 1 ether) / bought);
    }

    // --- the bid is what the hybrid seed bought us ---

    function test_JouleCanBeSoldBackAtOpen_JouleIsToken0() public onFork {
        _assertJouleCanBeSoldBackAtOpen(true);
    }

    function test_JouleCanBeSoldBackAtOpen_JouleIsToken1() public onFork {
        _assertJouleCanBeSoldBackAtOpen(false);
    }

    /**
     * @dev THE TEST THAT DISTINGUISHES THE HYBRID SEED FROM THE PURE
     *      SINGLE-SIDED ONE. With only a sell wall above spot the pool holds no
     *      USDC at all, so a holder trying to sell a Joule before anyone has
     *      bought one receives nothing -- the market is one-directional and the
     *      price chart can only go up. The 20 USDC bid makes selling possible
     *      from the moment the pool opens.
     *
     *      A round-trip (buy then sell) would NOT prove this: after a buy, the
     *      sell wall itself holds USDC and would absorb the sale. Selling
     *      first, at the opening price, is the only version of this test that
     *      fails on a single-sided pool.
     *
     *      The agent issues 12 rather than 10 here, backed by proportionally
     *      more collateral, so two Joules stay out of the pool to be sold.
     *      Coverage still binds exactly -- this is extra stake, not a weaker
     *      invariant.
     */
    function _assertJouleCanBeSoldBackAtOpen(bool wantJouleIsToken0) internal {
        Stack memory stack = _deployStack(wantJouleIsToken0);
        _stakeAndIssue(stack, 12);
        JoulePoolSeeder.Seeded memory seeded = _seed(stack);

        // Ten went into the wall; two are still in the agent's hands.
        uint256 held = stack.joule.balanceOf(agent);
        assertGe(held, 2 ether, "two Joules held back for the sale");

        (, int24 tickBefore,,) = stateView.getSlot0(seeded.key.toId());
        uint256 usdcBefore = stack.usdc.balanceOf(agent);

        vm.startPrank(agent);
        stack.joule.approve(address(swapRouter), type(uint256).max);
        // Selling JOULE. JOULE is the input, so zeroForOne is true when it is token0.
        _swap(seeded.key, seeded.jouleIsToken0, -int256(2 ether));
        vm.stopPrank();

        uint256 received = stack.usdc.balanceOf(agent) - usdcBefore;
        assertGt(received, 0, "a seller gets paid -- impossible without the bid");

        // Two Joules into a bid spanning 4.00-4.80 clears well under 4.80 each.
        assertLt(received, 2 * 4_800_000, "cannot beat the top of the bid");
        assertGt(received, 2 * 3_500_000, "the bid is deep enough to matter");

        (, int24 tickAfter,,) = stateView.getSlot0(seeded.key.toId());
        if (seeded.jouleIsToken0) {
            assertLt(tickAfter, tickBefore, "selling cheapens JOULE: lower tick");
        } else {
            assertGt(tickAfter, tickBefore, "inverted price: cheaper means HIGHER tick");
        }

        console.log("sold 2 JOULE for (1e6 USDC):", received);
    }

    // --- the shape of the book at open ---

    // --- the property that makes the pool routable ---

    function test_ActiveLiquidityAtSpotIsNonZero_JouleIsToken0() public onFork {
        _assertLiveAtSpot(true);
    }

    function test_ActiveLiquidityAtSpotIsNonZero_JouleIsToken1() public onFork {
        _assertLiveAtSpot(false);
    }

    /**
     * @dev THE REGRESSION TEST FOR THE BUG THAT COST US A SEPOLIA DEPLOY.
     *
     *      An earlier seed opened at 4.90 with the wall at [5.00, 6.00] and the
     *      bid at [4.00, 4.80]. Every test then in this file passed: the pool
     *      opened at the right price, the wall cost zero USDC, buying walked the
     *      price up, selling walked it down. And the Uniswap Trading API refused
     *      to quote it -- 404 ResourceNotFound -- because `getLiquidity()` at
     *      the opening tick was zero. v4 itself was perfectly happy, gapping to
     *      the nearest initialized tick, which is exactly why the fork tests
     *      caught nothing.
     *
     *      Confirmed on Sepolia: minting a position spanning spot, worth about
     *      five dollars against a pool already holding seventy, flipped the same
     *      pool from 404 to a working quote. So this asserts the routability
     *      property directly rather than trusting that inventory implies depth.
     *
     *      Both orderings, because which of the two ranges is live at spot flips
     *      with the ordering -- a position is active on [tickLower, tickUpper),
     *      so only the one pinned at its LOWER bound counts.
     */
    function _assertLiveAtSpot(bool wantJouleIsToken0) internal {
        Stack memory stack = _deployStack(wantJouleIsToken0);
        _stakeAndIssue(stack, 10);
        JoulePoolSeeder.Seeded memory seeded = _seed(stack);

        assertGt(stateView.getLiquidity(seeded.key.toId()), 0, "a router must see liquidity at spot");
        assertGt(seeded.sellLiquidity, 0, "the wall is not empty");
        assertGt(seeded.bidLiquidity, 0, "the bid is not empty");

        // The ranges meet exactly at the opening tick, with no gap either side.
        if (seeded.jouleIsToken0) {
            assertEq(seeded.sellLower, seeded.spotTick, "wall starts at spot");
            assertEq(seeded.bidUpper, seeded.spotTick, "bid ends at spot");
        } else {
            assertEq(seeded.sellUpper, seeded.spotTick, "wall ends at spot");
            assertEq(seeded.bidLower, seeded.spotTick, "bid starts at spot");
        }

        console.log("pool id:");
        console.logBytes32(PoolId.unwrap(seeded.key.toId()));
        console.log("active liquidity at spot:", stateView.getLiquidity(seeded.key.toId()));
    }
}
