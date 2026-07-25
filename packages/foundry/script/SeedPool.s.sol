// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Script, console } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

import { IPositionManager } from "v4-periphery/src/interfaces/IPositionManager.sol";
import { IStateView } from "v4-periphery/src/interfaces/IStateView.sol";
import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";

import { MockUSDC } from "../contracts/MockUSDC.sol";
import { JouleToken } from "../contracts/JouleToken.sol";
import { WorkEscrow } from "../contracts/WorkEscrow.sol";

import { SepoliaV4, JoulePoolParams } from "./JouleAddresses.sol";
import { JoulePoolSeeder } from "./JoulePoolSeeder.sol";

/**
 * @notice Opens the JOULE/USDC v4 pool and seeds it. Demo step 1.
 *
 * @dev Run against a local Sepolia fork, which is where Milestone 3 lives:
 *
 *        FORK_URL=sepoliaPublic yarn fork          # terminal 1
 *        yarn deploy --file DeployWorkEscrow.s.sol # terminal 2
 *        WORK_ESCROW=0x... yarn deploy --file SeedPool.s.sol
 *
 *      Only WORK_ESCROW is needed: the escrow knows its own collateral token
 *      and deployed JouleToken, so passing them separately would just create
 *      an opportunity to pass a mismatched set.
 *
 *      NOT wired to ScaffoldEthDeployerRunner on purpose. That modifier calls
 *      exportDeployments(), which rewrites deployments/<chainId>.json from this
 *      script's own (empty) deployment list and would erase the record written
 *      by DeployWorkEscrow.
 *
 *      TESTNET ONLY. It mints MockUSDC to cover any shortfall, which is
 *      possible only because MockUSDC is deliberately open-mint.
 */
contract SeedPool is Script {
    using PoolIdLibrary for PoolKey;

    IPositionManager posm = IPositionManager(SepoliaV4.POSITION_MANAGER);
    IAllowanceTransfer permit2 = IAllowanceTransfer(SepoliaV4.PERMIT2);
    IStateView stateView = IStateView(SepoliaV4.STATE_VIEW);

    error NotTheAgent(address caller, address agent);
    error NoUniswapHere(address poolManager);

    function run() external {
        WorkEscrow escrow = WorkEscrow(vm.envAddress("WORK_ESCROW"));
        MockUSDC usdc = MockUSDC(address(escrow.collateralToken()));
        JouleToken joule = escrow.joule();

        // Checked by bytecode presence, NOT by chain id: `yarn fork` runs anvil
        // with --chain-id 31337 while carrying Sepolia's state, so a chain-id
        // check would reject the exact environment this script targets. Asking
        // whether the PoolManager is actually there covers the live chain, the
        // fork, and a bare anvil where these addresses point at nothing.
        if (SepoliaV4.POOL_MANAGER.code.length == 0) revert NoUniswapHere(SepoliaV4.POOL_MANAGER);

        vm.startBroadcast();
        (,address agent,) = vm.readCallers();

        // issue() and stake() are onlyAgent, so a wrong signer would fail deep
        // inside the escrow rather than here.
        if (agent != escrow.agent()) revert NotTheAgent(agent, escrow.agent());

        _ensureInventory(escrow, usdc, joule, agent);

        JoulePoolSeeder.Recipe memory recipe = JoulePoolSeeder.Recipe({
            joule: address(joule),
            usdc: address(usdc),
            spotPrice: JoulePoolParams.SPOT_PRICE,
            sellHigh: JoulePoolParams.SELL_HIGH,
            bidLow: JoulePoolParams.BID_LOW,
            jouleInventory: JoulePoolParams.JOULE_INVENTORY,
            usdcBid: JoulePoolParams.USDC_BID,
            fee: JoulePoolParams.FEE,
            tickSpacing: JoulePoolParams.TICK_SPACING
        });

        JoulePoolSeeder.Seeded memory seeded = JoulePoolSeeder.plan(recipe);

        // An hour, not a minute. This value is fixed during forge's simulation
        // pass and must still be in the future when the LAST of a dozen
        // sequentially-broadcast transactions is mined. Slippage is guarded by
        // the per-position maxima, not by this, so a generous window costs
        // nothing.
        JoulePoolSeeder.execute(
            JoulePoolSeeder.Venue({ posm: posm, permit2: permit2, stateView: stateView }),
            recipe,
            seeded,
            agent,
            block.timestamp + 1 hours
        );

        vm.stopBroadcast();

        _report(seeded, address(joule), address(usdc));
    }

    /**
     * @dev Tops the agent up to the inventory the seed needs. Issuing is
     *      coverage-constrained, so the collateral has to go in first -- the
     *      escrow will refuse the mint otherwise, which is the invariant
     *      working rather than a problem to route around.
     */
    function _ensureInventory(WorkEscrow escrow, MockUSDC usdc, JouleToken joule, address agent) internal {
        uint256 heldJoule = joule.balanceOf(agent);

        if (heldJoule < JoulePoolParams.JOULE_INVENTORY) {
            uint256 shortfall = JoulePoolParams.JOULE_INVENTORY - heldJoule;
            // issue() takes WHOLE Joules; round up so we never end a wei short.
            uint256 count = (shortfall + 1 ether - 1) / 1 ether;

            uint256 required = escrow.requiredCollateral(escrow.outstanding() + count);
            uint256 have = escrow.collateral();
            if (required > have) {
                uint256 topUp = required - have;
                usdc.mint(agent, topUp);
                usdc.approve(address(escrow), topUp);
                escrow.stake(topUp);
                console.log("staked additional collateral (1e6 USDC):", topUp);
            }

            escrow.issue(count);
            console.log("issued Joules:", count);
        }

        uint256 heldUsdc = usdc.balanceOf(agent);
        if (heldUsdc < JoulePoolParams.USDC_BID) {
            usdc.mint(agent, JoulePoolParams.USDC_BID - heldUsdc);
        }
    }

    function _report(JoulePoolSeeder.Seeded memory seeded, address joule, address usdc) internal view {
        (uint160 sqrtPriceX96, int24 tick,,) = stateView.getSlot0(seeded.key.toId());

        console.log("");
        console.log("--- JOULE/USDC v4 pool seeded ---");
        console.log("JouleToken  ", joule);
        console.log("MockUSDC    ", usdc);
        console.log(seeded.jouleIsToken0 ? "ordering     JOULE is token0" : "ordering     USDC is token0");
        console.log("fee          3000 (0.30%), tickSpacing 60, no hook");
        console.log("pool id:");
        console.logBytes32(PoolId.unwrap(seeded.key.toId()));
        console.log("");
        console.log(string.concat("opened at tick      ", vm.toString(int256(tick))));
        console.log(string.concat("sqrtPriceX96        ", vm.toString(uint256(sqrtPriceX96))));
        console.log(
            string.concat(
                "sell wall ticks     ",
                vm.toString(int256(seeded.sellLower)),
                " .. ",
                vm.toString(int256(seeded.sellUpper))
            )
        );
        console.log(string.concat("sell wall liquidity ", vm.toString(uint256(seeded.sellLiquidity))));
        console.log(
            string.concat(
                "bid ticks           ",
                vm.toString(int256(seeded.bidLower)),
                " .. ",
                vm.toString(int256(seeded.bidUpper))
            )
        );
        console.log(string.concat("bid liquidity       ", vm.toString(uint256(seeded.bidLiquidity))));
        console.log("");
        console.log(
            string.concat("active liquidity at spot ", vm.toString(uint256(stateView.getLiquidity(seeded.key.toId()))))
        );
        console.log("Must be non-zero: the ranges meet at spot so a router can see");
        console.log("depth there. A gap here reads as an empty pool and will not quote.");
    }
}
