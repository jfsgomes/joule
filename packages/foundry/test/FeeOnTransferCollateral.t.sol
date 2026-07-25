// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { WorkEscrow } from "../contracts/WorkEscrow.sol";
import { JouleToken } from "../contracts/JouleToken.sol";
import { SumVerifier } from "../contracts/verifiers/SumVerifier.sol";

/// @dev Burns 1% on every transfer, so the recipient always receives less than
///      the sender sent. Real tokens do this; USDT can be configured to.
contract FeeOnTransferUSDC is ERC20 {
    uint256 public constant FEE_BPS = 100; // 1%

    constructor() ERC20("Fee USD Coin", "fUSDC") { }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = (value * FEE_BPS) / 10_000;
        super._update(from, to, value - fee);
        super._update(from, address(0), fee); // burn the fee
    }
}

/**
 * @dev Regression test for review item C-4. `stake` used to credit the amount
 *      requested rather than the amount received, so with a fee-on-transfer
 *      collateral token the ledger drifted permanently above real holdings. The
 *      first symptom would have been a failed payout -- on the one path that
 *      must never fail.
 */
contract FeeOnTransferCollateralTest is Test {
    FeeOnTransferUSDC internal usdc;
    WorkEscrow internal escrow;
    JouleToken internal joule;

    address internal agent = makeAddr("agent");
    address internal holder = makeAddr("holder");

    uint256 constant FACE = 5e6;
    uint256 constant PENALTY = 5e6;
    uint256 constant PER_JOULE = FACE + PENALTY;
    uint256 constant WINDOW = 10;
    uint256 constant ACCEPT = 5;

    function setUp() public {
        usdc = new FeeOnTransferUSDC();
        escrow = new WorkEscrow(
            IERC20(address(usdc)), new SumVerifier(), agent, makeAddr("arbiter"), FACE, PENALTY, PER_JOULE, WINDOW, ACCEPT
        );
        joule = escrow.joule();

        usdc.mint(agent, 10_000e6);
        vm.prank(agent);
        usdc.approve(address(escrow), type(uint256).max);
    }

    function test_StakeCreditsWhatArrivedNotWhatWasSent() public {
        uint256 sent = 1000e6;
        uint256 expected = sent - (sent * usdc.FEE_BPS()) / 10_000;

        vm.prank(agent);
        escrow.stake(sent);

        assertEq(escrow.collateral(), expected, "ledger must follow the balance, not the request");
        assertEq(usdc.balanceOf(address(escrow)), expected);
        assertEq(escrow.collateral(), usdc.balanceOf(address(escrow)), "no drift");
    }

    /// @dev The property that matters: the payout path still works. Under the
    ///      old behaviour the ledger exceeded holdings and this transfer failed.
    function test_PayoutStillSucceedsUnderFeeOnTransfer() public {
        vm.startPrank(agent);
        escrow.stake(1000e6);
        escrow.issue(10);
        joule.transfer(holder, joule.ONE());
        vm.stopPrank();

        vm.startPrank(holder);
        joule.approve(address(escrow), joule.ONE());
        uint256 jobId = escrow.redeem(abi.encode(uint256(2), uint256(2)));
        vm.stopPrank();

        vm.roll(block.number + WINDOW + 1);
        escrow.claimTimeout(jobId);

        vm.prank(holder);
        escrow.withdraw();

        // The holder receives the credit minus the token's own transfer fee.
        uint256 credited = FACE + PENALTY;
        assertEq(usdc.balanceOf(holder), credited - (credited * usdc.FEE_BPS()) / 10_000);
        assertGe(usdc.balanceOf(address(escrow)), escrow.collateral(), "ledger never exceeds holdings");
    }

    function test_LedgerNeverExceedsHoldings() public {
        vm.startPrank(agent);
        escrow.stake(1000e6);
        escrow.issue(5);
        escrow.unstake(100e6);
        vm.stopPrank();

        assertGe(
            usdc.balanceOf(address(escrow)),
            escrow.collateral() + escrow.disputeBonds() + escrow.totalOwed(),
            "holdings must cover every ledger"
        );
    }
}
