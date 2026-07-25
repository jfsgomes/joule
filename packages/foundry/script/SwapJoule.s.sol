// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Script, console } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";


import { IStateView } from "v4-periphery/src/interfaces/IStateView.sol";
import { Actions } from "v4-periphery/src/libraries/Actions.sol";
import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";

import { MockUSDC } from "../contracts/MockUSDC.sol";
import { JouleToken } from "../contracts/JouleToken.sol";
import { WorkEscrow } from "../contracts/WorkEscrow.sol";

import { SepoliaV4, JoulePoolParams } from "./JouleAddresses.sol";
import { JoulePoolSeeder } from "./JoulePoolSeeder.sol";

/// @dev Minimal view of the Universal Router. Declared here rather than pulled
///      in as another submodule: we need exactly one function and one command
///      byte, and uniswap/universal-router drags in its own dependency tree.
interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/**
 * @dev The swap params struct AS THE DEPLOYED SEPOLIA ROUTER EXPECTS IT.
 *
 *      v4-periphery `main` (our submodule, 3245c3c) carries an extra
 *      `minHopPriceX36` field added by PR #516, "add per-hop slippage to single
 *      swaps". The Universal Router deployed at
 *      0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b predates it, so encoding
 *      `IV4Router.ExactInputSingleParams` against it is an ABI mismatch: the
 *      decoder reads our `minHopPriceX36` word as the `hookData` offset, jumps
 *      to a nonsense location, and reverts.
 *
 *      THE FAILURE MODE IS THE INTERESTING PART. It surfaces as a bare
 *      `EvmError: Revert` from inside `PoolManager.unlock` -> `unlockCallback`,
 *      with no selector and no message -- indistinguishable at a glance from a
 *      bad pool key, a missing approval, or an empty pool. Worth writing up in
 *      FEEDBACK.md: pulling periphery from `main` against a months-old
 *      deployment is the obvious thing to do and it fails silently.
 *
 *      Keeping our own copy rather than pinning the submodule back is
 *      deliberate -- PositionManager's MINT_POSITION/SETTLE_PAIR encoding
 *      matches the deployment fine, so downgrading everything to fix one struct
 *      would trade a documented local workaround for an undocumented global one.
 */
struct LegacyExactInputSingleParams {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    bytes hookData;
}

/**
 * @notice Buys Joules from the v4 pool through the real Universal Router.
 *
 * @dev Milestone 3's "swap works from a script". Deliberately routed through
 *      the UNIVERSAL ROUTER rather than a test harness, because that is the
 *      contract the Uniswap Trading API returns calldata for. Getting this to
 *      work now means the prize integration in Milestone 5 is a matter of
 *      sourcing the calldata from the API instead of building it here -- and if
 *      the API declines to quote a pool this thin, this script IS the
 *      documented fallback.
 *
 *        FORK_URL=sepoliaPublic yarn fork
 *        WORK_ESCROW=0x... yarn deploy --file SeedPool.s.sol
 *        WORK_ESCROW=0x... yarn deploy --file SwapJoule.s.sol
 *
 *      AMOUNT_USDC overrides the default 10 USDC of spend.
 */
contract SwapJoule is Script {
    using PoolIdLibrary for PoolKey;

    /// @dev Universal Router command byte for a v4 swap.
    uint8 constant V4_SWAP = 0x10;

    IUniversalRouter router = IUniversalRouter(SepoliaV4.UNIVERSAL_ROUTER);
    IAllowanceTransfer permit2 = IAllowanceTransfer(SepoliaV4.PERMIT2);
    IStateView stateView = IStateView(SepoliaV4.STATE_VIEW);

    error NoUniswapHere(address universalRouter);
    error NothingReceived();

    /// @dev Grouped to keep `run` out of stack-too-deep territory.
    struct Ctx {
        MockUSDC usdc;
        JouleToken joule;
        PoolKey key;
        bool jouleIsToken0;
        uint128 amountIn;
    }

    function run() external {
        WorkEscrow escrow = WorkEscrow(vm.envAddress("WORK_ESCROW"));

        Ctx memory ctx;
        ctx.usdc = MockUSDC(address(escrow.collateralToken()));
        ctx.joule = escrow.joule();
        ctx.jouleIsToken0 = address(ctx.joule) < address(ctx.usdc);
        ctx.amountIn = uint128(vm.envOr("AMOUNT_USDC", uint256(10e6)));
        ctx.key = JoulePoolSeeder.poolKeyFor(
            address(ctx.joule), address(ctx.usdc), JoulePoolParams.FEE, JoulePoolParams.TICK_SPACING
        );

        if (SepoliaV4.UNIVERSAL_ROUTER.code.length == 0) revert NoUniswapHere(SepoliaV4.UNIVERSAL_ROUTER);

        (, int24 tickBefore,,) = stateView.getSlot0(ctx.key.toId());

        uint256 received = _buy(ctx);
        if (received == 0) revert NothingReceived();

        (, int24 tickAfter,,) = stateView.getSlot0(ctx.key.toId());
        _report(ctx, received, tickBefore, tickAfter);
    }

    function _buy(Ctx memory ctx) internal returns (uint256 received) {
        // Buying JOULE means spending USDC. USDC is currency0 exactly when
        // JOULE is NOT token0, so the direction falls out of the ordering
        // rather than being assumed.
        bool zeroForOne = !ctx.jouleIsToken0;

        vm.startBroadcast();
        (, address buyer,) = vm.readCallers();

        if (ctx.usdc.balanceOf(buyer) < ctx.amountIn) {
            ctx.usdc.mint(buyer, ctx.amountIn - ctx.usdc.balanceOf(buyer));
        }
        uint256 jouleBefore = ctx.joule.balanceOf(buyer);

        // Same two-step as the seeder: ERC-20 allowance to Permit2, then a
        // Permit2 allowance to the spender. The Universal Router pulls funds
        // through Permit2, never directly.
        ctx.usdc.approve(address(permit2), type(uint256).max);
        permit2.approve(address(ctx.usdc), address(router), type(uint160).max, type(uint48).max);

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            LegacyExactInputSingleParams({
                poolKey: ctx.key,
                zeroForOne: zeroForOne,
                amountIn: ctx.amountIn,
                // A demo buy against our own pool. A real integration sets this
                // from a quote; zero here keeps the script from failing on the
                // ordinary price drift between runs.
                amountOutMinimum: 0,
                hookData: ""
            })
        );
        params[1] = abi.encode(zeroForOne ? ctx.key.currency0 : ctx.key.currency1, ctx.amountIn);
        params[2] = abi.encode(zeroForOne ? ctx.key.currency1 : ctx.key.currency0, uint256(0));

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL)),
            params
        );

        // Generous, for the same reason as the seeder: this value is fixed at
        // simulation time and must survive until the transaction is mined.
        router.execute(abi.encodePacked(V4_SWAP), inputs, block.timestamp + 1 hours);

        received = ctx.joule.balanceOf(buyer) - jouleBefore;
        vm.stopBroadcast();
    }

    function _report(Ctx memory ctx, uint256 received, int24 tickBefore, int24 tickAfter) internal pure {
        console.log("");
        console.log("--- swapped via Universal Router ---");
        console.log(string.concat("spent            ", vm.toString(uint256(ctx.amountIn)), " USDC base units"));
        console.log(string.concat("received         ", vm.toString(received), " JOULE wei"));
        console.log(
            string.concat(
                "effective price  ", vm.toString((uint256(ctx.amountIn) * 1 ether) / received), " (1e6 = 1 USDC)"
            )
        );
        console.log(string.concat("tick             ", vm.toString(int256(tickBefore)), " -> ", vm.toString(int256(tickAfter))));
        console.log(
            ctx.jouleIsToken0
                ? "JOULE is token0: a rising tick means JOULE got dearer."
                : "USDC is token0: price is inverted, so a FALLING tick means JOULE got dearer."
        );
    }
}
