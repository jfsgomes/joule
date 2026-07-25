// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Script, console } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";

import { IPositionManager } from "v4-periphery/src/interfaces/IPositionManager.sol";
import { IStateView } from "v4-periphery/src/interfaces/IStateView.sol";
import { LiquidityAmounts } from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import { Actions } from "v4-periphery/src/libraries/Actions.sol";
import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";

import { MockUSDC } from "../contracts/MockUSDC.sol";
import { JouleToken } from "../contracts/JouleToken.sol";
import { WorkEscrow } from "../contracts/WorkEscrow.sol";
import { JoulePoolMath } from "../contracts/libraries/JoulePoolMath.sol";

import { SepoliaV4, JoulePoolParams } from "./JouleAddresses.sol";
import { JoulePoolSeeder } from "./JoulePoolSeeder.sol";

/**
 * @notice A ONE-VARIABLE EXPERIMENT, not production code.
 *
 * @dev The Trading API returns 404 ResourceNotFound for our pool. Three
 *      hypotheses fit that evidence and they need very different responses:
 *
 *        1. Indexing lag           -> wait; nothing to fix.
 *        2. Zero liquidity AT SPOT -> narrow the spread; a constant change.
 *        3. Token not curated      -> no parameter fixes it; use the
 *                                     V4Quoter + Universal Router fallback.
 *
 *      Hypothesis 1 is ruled out by polling. This script discriminates 2 from
 *      3, and it is built to change exactly one thing: it mints a small
 *      position STRADDLING the current tick on the SAME pool, same tokens,
 *      same fee tier. Nothing else moves. If the pool then quotes, the gap was
 *      the cause and the production fix is cheap. If it still 404s, no amount
 *      of liquidity shaping will help and the fallback is the answer.
 *
 *      A second pool at a different fee tier would have confounded two
 *      variables at once, which is why this adds to the existing pool instead.
 *
 *      Safe to run only against the throwaway probe deployment -- it
 *      permanently alters that pool's shape.
 *
 *        WORK_ESCROW=0x... yarn deploy --file ProbeStraddle.s.sol \
 *          --network sepolia --keystore ethgloballisbon2026
 */
contract ProbeStraddle is Script {
    using PoolIdLibrary for PoolKey;

    /// @dev Deliberately small. The question is whether ANY liquidity at spot
    ///      flips the answer, not whether a lot of it does.
    uint256 constant JOULE_SIDE = 0.5 ether;
    uint256 constant USDC_SIDE = 3e6;

    /// @dev +/- this many spacings around the current tick.
    int24 constant SPAN = 10;

    IPositionManager posm = IPositionManager(SepoliaV4.POSITION_MANAGER);
    IAllowanceTransfer permit2 = IAllowanceTransfer(SepoliaV4.PERMIT2);
    IStateView stateView = IStateView(SepoliaV4.STATE_VIEW);

    function run() external {
        WorkEscrow escrow = WorkEscrow(vm.envAddress("WORK_ESCROW"));
        MockUSDC usdc = MockUSDC(address(escrow.collateralToken()));
        JouleToken joule = escrow.joule();

        PoolKey memory key = JoulePoolSeeder.poolKeyFor(
            address(joule), address(usdc), JoulePoolParams.FEE, JoulePoolParams.TICK_SPACING
        );

        (uint160 sqrtPriceX96, int24 tick,,) = stateView.getSlot0(key.toId());

        int24 spacing = JoulePoolParams.TICK_SPACING;
        int24 lower = JoulePoolMath.floorToSpacing(tick, spacing) - SPAN * spacing;
        int24 upper = JoulePoolMath.ceilToSpacing(tick, spacing) + SPAN * spacing;

        // Straddling means the position holds BOTH tokens, so this uses the
        // two-sided helper rather than the single-sided one the seed uses.
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(lower),
            TickMath.getSqrtPriceAtTick(upper),
            key.currency0.toId() == uint256(uint160(address(usdc))) ? USDC_SIDE : JOULE_SIDE,
            key.currency0.toId() == uint256(uint160(address(usdc))) ? JOULE_SIDE : USDC_SIDE
        );
        require(liquidity > 0, "straddle liquidity rounded to zero");

        vm.startBroadcast();
        (, address agent,) = vm.readCallers();

        _ensureFunds(escrow, usdc, joule, agent);

        usdc.approve(address(permit2), type(uint256).max);
        permit2.approve(address(usdc), address(posm), type(uint160).max, type(uint48).max);
        joule.approve(address(permit2), type(uint256).max);
        permit2.approve(address(joule), address(posm), type(uint160).max, type(uint48).max);

        bytes[] memory params = new bytes[](2);
        // Both maxima are generous here: unlike the seed, this position is
        // MEANT to consume both tokens, so a zero max would be wrong.
        params[0] = abi.encode(key, lower, upper, liquidity, type(uint128).max, type(uint128).max, agent, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);

        posm.modifyLiquidities(
            abi.encode(abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR)), params),
            block.timestamp + 1 hours
        );
        vm.stopBroadcast();

        console.log("");
        console.log("--- straddle minted ---");
        console.log(string.concat("tick        ", vm.toString(int256(tick))));
        console.log(string.concat("range       ", vm.toString(int256(lower)), " .. ", vm.toString(int256(upper))));
        console.log(string.concat("liquidity   ", vm.toString(uint256(liquidity))));
        console.log(
            string.concat("active liquidity at spot is now ", vm.toString(stateView.getLiquidity(key.toId())))
        );
    }

    function _ensureFunds(WorkEscrow escrow, MockUSDC usdc, JouleToken joule, address agent) internal {
        if (usdc.balanceOf(agent) < USDC_SIDE) usdc.mint(agent, USDC_SIDE - usdc.balanceOf(agent));

        if (joule.balanceOf(agent) < JOULE_SIDE) {
            uint256 count = 1; // one whole Joule covers the 0.5 needed
            uint256 required = escrow.requiredCollateral(escrow.outstanding() + count);
            uint256 have = escrow.collateral();
            if (required > have) {
                uint256 topUp = required - have;
                usdc.mint(agent, topUp);
                usdc.approve(address(escrow), topUp);
                escrow.stake(topUp);
            }
            escrow.issue(count);
        }
    }
}
