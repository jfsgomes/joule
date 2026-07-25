// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { MockUSDC } from "../contracts/MockUSDC.sol";

/**
 * @dev These tests exist mainly to pin the decimals down. If someone later
 *      "fixes" MockUSDC to 18 decimals, this suite fails loudly rather than
 *      letting every downstream collateral assertion quietly drift by 10^12.
 */
contract MockUSDCTest is Test {
    MockUSDC internal usdc;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        usdc = new MockUSDC();
    }

    function test_HasSixDecimalsLikeRealUSDC() public view {
        assertEq(usdc.decimals(), 6, "USDC has 6 decimals; an 18 here invalidates every collateral test");
    }

    /// @dev The concrete trap, written out: one dollar is 1e6, not 1e18.
    function test_OneDollarIsOneMillionBaseUnits() public {
        usdc.mint(alice, 1e6);

        assertEq(usdc.balanceOf(alice), 1e6, "1 USDC must be 1e6 base units");
        assertEq(usdc.balanceOf(alice) / (10 ** usdc.decimals()), 1, "1e6 base units must read as 1 whole dollar");

        // The trap in the direction that actually costs money. Someone writing
        // `1e18` while meaning "one dollar of collateral" is not asking for one
        // dollar -- they are asking for a trillion.
        uint256 oneDollarIfYouAssume18Decimals = 1e18;
        assertEq(
            oneDollarIfYouAssume18Decimals / (10 ** usdc.decimals()),
            1_000_000_000_000,
            "1e18 base units is a trillion USDC, not one"
        );
    }

    function test_MintCreditsRecipientAndSupply() public {
        usdc.mint(alice, 100e6);

        assertEq(usdc.balanceOf(alice), 100e6);
        assertEq(usdc.totalSupply(), 100e6);
    }

    function test_TransferMovesBalance() public {
        usdc.mint(alice, 100e6);

        vm.prank(alice);
        usdc.transfer(bob, 40e6);

        assertEq(usdc.balanceOf(alice), 60e6);
        assertEq(usdc.balanceOf(bob), 40e6);
    }

    function testFuzz_MintCreditsExactAmount(address to, uint96 amount) public {
        vm.assume(to != address(0));

        usdc.mint(to, amount);

        assertEq(usdc.balanceOf(to), amount);
        assertEq(usdc.totalSupply(), amount);
    }
}
