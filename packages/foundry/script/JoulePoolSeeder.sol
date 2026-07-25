// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";

import { IPositionManager } from "v4-periphery/src/interfaces/IPositionManager.sol";
import { IStateView } from "v4-periphery/src/interfaces/IStateView.sol";
import { Actions } from "v4-periphery/src/libraries/Actions.sol";
import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";

import { JoulePoolMath } from "../contracts/libraries/JoulePoolMath.sol";

/**
 * @title JoulePoolSeeder
 * @notice Opens the JOULE/USDC v4 pool and mints the hybrid two-range seed.
 *
 * @dev Deliberately split into `plan` and `execute`:
 *
 *        plan()     pure. Decides token ordering, price, ticks and liquidity,
 *                   and asserts the geometry. No chain access, so the entire
 *                   risky part -- decimals and tick direction -- is unit
 *                   testable without a fork or an RPC.
 *
 *        execute()  stateful. Initializes the pool and mints. Contains no
 *                   arithmetic; if it reverts, the cause is approvals, an
 *                   already-initialized pool, or insufficient balance, never
 *                   maths.
 *
 *      Both are `internal`, so a script running under `vm.startBroadcast` and a
 *      fork test running under `vm.startPrank` share one code path. There is no
 *      second implementation for tests to drift away from.
 */
library JoulePoolSeeder {
    using PoolIdLibrary for PoolKey;

    /// @notice Where we are trading -- the real, verified v4 periphery.
    struct Venue {
        IPositionManager posm;
        IAllowanceTransfer permit2;
        IStateView stateView;
    }

    /// @notice What to build. Prices are USDC base units per whole Joule.
    struct Recipe {
        address joule;
        address usdc;
        uint256 spotPrice;
        uint256 sellLow;
        uint256 sellHigh;
        uint256 bidLow;
        uint256 bidHigh;
        uint256 jouleInventory;
        uint256 usdcBid;
        uint24 fee;
        int24 tickSpacing;
    }

    /// @notice The resolved plan. Everything a caller needs to log or assert.
    struct Seeded {
        PoolKey key;
        bool jouleIsToken0;
        uint160 sqrtPriceX96;
        int24 spotTick;
        int24 sellLower;
        int24 sellUpper;
        uint128 sellLiquidity;
        int24 bidLower;
        int24 bidUpper;
        uint128 bidLiquidity;
    }

    error PoolAlreadyPriced(uint160 existingSqrtPriceX96, uint160 intendedSqrtPriceX96);
    error EmptyPosition(string which);
    error RangesOverlap(int24 sellLower, int24 sellUpper, int24 bidLower, int24 bidUpper);

    /**
     * @notice The PoolKey for a JOULE/USDC pool, without planning a seed.
     *
     * @dev Anything that needs to TRADE the pool -- a swap script, the quoter,
     *      the frontend -- needs the key and nothing else. Exposing it
     *      separately keeps those callers off `plan`, whose single-sidedness
     *      assertions are about the opening price and stop being meaningful
     *      once the pool has traded away from it.
     */
    function poolKeyFor(address joule, address usdc, uint24 fee, int24 tickSpacing)
        internal
        pure
        returns (PoolKey memory)
    {
        (address token0, address token1) = joule < usdc ? (joule, usdc) : (usdc, joule);
        return PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });
    }

    /**
     * @notice Resolves ordering, price, ticks and liquidity. Pure.
     *
     * @dev The ordering is READ from the addresses, never assumed. JouleToken is
     *      deployed inside WorkEscrow's constructor precisely so its minter is
     *      fixed by construction, which means we do not get to choose its
     *      address and either token may sort first. Everything downstream
     *      branches off the single `jouleIsToken0` computed here.
     */
    function plan(Recipe memory recipe) internal pure returns (Seeded memory seeded) {
        seeded.jouleIsToken0 = recipe.joule < recipe.usdc;

        // No hook. The v4 hook is a documented stretch goal with no prize
        // attached at this event; building the baseline pool on v4 anyway is
        // what makes adding one later purely additive.
        seeded.key = poolKeyFor(recipe.joule, recipe.usdc, recipe.fee, recipe.tickSpacing);

        seeded.sqrtPriceX96 = JoulePoolMath.sqrtPriceX96For(recipe.spotPrice, seeded.jouleIsToken0);
        seeded.spotTick = TickMath.getTickAtSqrtPrice(seeded.sqrtPriceX96);

        (seeded.sellLower, seeded.sellUpper) =
            JoulePoolMath.rangeFor(recipe.sellLow, recipe.sellHigh, seeded.jouleIsToken0, recipe.tickSpacing);
        (seeded.bidLower, seeded.bidUpper) =
            JoulePoolMath.rangeFor(recipe.bidLow, recipe.bidHigh, seeded.jouleIsToken0, recipe.tickSpacing);

        // The sell wall must hold only JOULE and the bid only USDC. Get this
        // backwards and the "sell wall" is a buy wall that fills instantly
        // against the agent at their own expense.
        JoulePoolMath.assertSingleSided(seeded.sellLower, seeded.sellUpper, seeded.spotTick, seeded.jouleIsToken0);
        JoulePoolMath.assertSingleSided(seeded.bidLower, seeded.bidUpper, seeded.spotTick, !seeded.jouleIsToken0);

        if (!(seeded.sellUpper <= seeded.bidLower || seeded.bidUpper <= seeded.sellLower)) {
            revert RangesOverlap(seeded.sellLower, seeded.sellUpper, seeded.bidLower, seeded.bidUpper);
        }

        seeded.sellLiquidity = JoulePoolMath.singleSidedLiquidity(
            seeded.sellLower, seeded.sellUpper, recipe.jouleInventory, seeded.jouleIsToken0
        );
        seeded.bidLiquidity =
            JoulePoolMath.singleSidedLiquidity(seeded.bidLower, seeded.bidUpper, recipe.usdcBid, !seeded.jouleIsToken0);

        // Liquidity rounds down. A range wide enough and an amount small enough
        // can round to zero, which mints an empty position and looks exactly
        // like a successful seed until the first swap finds nothing to trade.
        if (seeded.sellLiquidity == 0) revert EmptyPosition("sell");
        if (seeded.bidLiquidity == 0) revert EmptyPosition("bid");
    }

    /**
     * @notice Initializes the pool and mints both ranges in a single call.
     *
     * @dev The caller must hold the tokens. Under `vm.startBroadcast` that is
     *      the deployer EOA; under `vm.startPrank` it is the pranked address.
     *
     *      THE SAFETY PROPERTY IS IN THE MAXIMA. Each mint declares a maximum
     *      of ZERO for the token it is not meant to spend. If the geometry were
     *      mirrored -- the sell wall placed below spot, say -- the pool would
     *      demand the other token and the mint would revert on a zero maximum
     *      instead of quietly consuming the agent's USDC. That makes the
     *      ordering assumption fail closed at the only point where it costs
     *      real money, which is a stronger guarantee than `plan`'s assertions
     *      alone because it is enforced by Uniswap rather than by us.
     *
     *      `deadline` IS A PARAMETER, NOT `block.timestamp + n`. Computing it
     *      here would evaluate it during forge's simulation pass and bake the
     *      result into broadcast calldata; the transaction then lands minutes
     *      later, in wall-clock time, against a deadline that expired while the
     *      preceding transactions were being mined. That failure is invisible
     *      to fork tests -- they execute in a single frozen-timestamp context
     *      where no time passes at all -- and it gets worse, not better, on a
     *      real chain with 12-second blocks.
     */
    function execute(
        Venue memory venue,
        Recipe memory recipe,
        Seeded memory seeded,
        address recipient,
        uint256 deadline
    ) internal {
        // Returns type(int24).max instead of reverting when the pool already
        // exists. What matters is not whether it existed but whether it is
        // still at OUR price: a pool someone else opened, or one that has
        // already traded, would put our ranges on the wrong side of a spot we
        // never chose. A pool sitting at exactly the price we were about to set
        // is our own interrupted attempt, and re-running should finish the job
        // rather than force a redeploy -- which is precisely the situation a
        // half-broadcast seed leaves behind.
        int24 initializedTick = venue.posm.initializePool(seeded.key, seeded.sqrtPriceX96);
        if (initializedTick == type(int24).max) {
            (uint160 existing,,,) = venue.stateView.getSlot0(seeded.key.toId());
            if (existing != seeded.sqrtPriceX96) revert PoolAlreadyPriced(existing, seeded.sqrtPriceX96);
        }

        _approveThroughPermit2(venue, recipe.joule);
        _approveThroughPermit2(venue, recipe.usdc);

        // Zero on the side each position must not touch. See the note above.
        (uint128 sellMax0, uint128 sellMax1) = seeded.jouleIsToken0
            ? (uint128(recipe.jouleInventory), uint128(0))
            : (uint128(0), uint128(recipe.jouleInventory));
        (uint128 bidMax0, uint128 bidMax1) =
            seeded.jouleIsToken0 ? (uint128(0), uint128(recipe.usdcBid)) : (uint128(recipe.usdcBid), uint128(0));

        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION), uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR)
        );

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            seeded.key, seeded.sellLower, seeded.sellUpper, seeded.sellLiquidity, sellMax0, sellMax1, recipient, bytes("")
        );
        params[1] = abi.encode(
            seeded.key, seeded.bidLower, seeded.bidUpper, seeded.bidLiquidity, bidMax0, bidMax1, recipient, bytes("")
        );
        // One settle covers both mints -- the deltas net inside the same unlock.
        params[2] = abi.encode(seeded.key.currency0, seeded.key.currency1);

        venue.posm.modifyLiquidities(abi.encode(actions, params), deadline);
    }

    /**
     * @dev PositionManager pulls funds through Permit2, not through a direct
     *      ERC-20 allowance, so this is two approvals and not one. Missing the
     *      second is the classic v4 integration failure: the ERC-20 approve
     *      succeeds, and the mint reverts far away inside Permit2.
     */
    function _approveThroughPermit2(Venue memory venue, address token) private {
        IERC20(token).approve(address(venue.permit2), type(uint256).max);
        venue.permit2.approve(token, address(venue.posm), type(uint160).max, type(uint48).max);
    }
}
