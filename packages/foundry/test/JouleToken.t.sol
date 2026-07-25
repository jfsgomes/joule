// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { JouleToken } from "../contracts/JouleToken.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/**
 * @dev The test contract deploys the token, so `address(this)` plays the role
 *      of WorkEscrow throughout. That mirrors production, where WorkEscrow
 *      deploys JouleToken from its own constructor.
 *
 *      `ONE` is cached in setUp rather than read as `joule.ONE()` inline. An
 *      external call sitting in argument position is still a call: it consumes
 *      a pending `vm.prank` and satisfies a pending `vm.expectRevert` before
 *      the call under test ever runs.
 */
contract JouleTokenTest is Test {
    JouleToken internal joule;
    uint256 internal ONE;

    address internal agent = makeAddr("agent");
    address internal holder = makeAddr("holder");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        joule = new JouleToken();
        ONE = joule.ONE();
    }

    // --- supply integrity: only the escrow may mint or burn ---

    function test_EscrowIsTheDeployer() public view {
        assertEq(joule.escrow(), address(this), "the deploying escrow must be the permanent minter");
    }

    function test_MintRevertsForNonEscrow() public {
        vm.expectRevert(abi.encodeWithSelector(JouleToken.OnlyEscrow.selector, attacker));
        vm.prank(attacker);
        joule.mint(attacker, ONE);
    }

    function test_BurnRevertsForNonEscrow() public {
        joule.mint(address(this), ONE);

        vm.expectRevert(abi.encodeWithSelector(JouleToken.OnlyEscrow.selector, attacker));
        vm.prank(attacker);
        joule.burn(ONE);
    }

    function testFuzz_NoOneButEscrowCanMint(address caller, uint128 amount) public {
        vm.assume(caller != address(this));

        vm.expectRevert(abi.encodeWithSelector(JouleToken.OnlyEscrow.selector, caller));
        vm.prank(caller);
        joule.mint(caller, amount);

        assertEq(joule.totalSupply(), 0, "supply must be unreachable from outside the escrow");
    }

    // --- burn can only destroy the escrow's own custody ---

    /// @dev The property that matters: even the escrow cannot burn a holder's
    ///      balance. A Joule must be redeemed into custody before it can die.
    function test_EscrowCannotBurnAHoldersBalance() public {
        joule.mint(holder, ONE);
        assertEq(joule.balanceOf(holder), ONE);

        // The escrow holds nothing, so burning reverts against its own balance
        // rather than reaching into the holder's.
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), 0, ONE)
        );
        joule.burn(ONE);

        assertEq(joule.balanceOf(holder), ONE, "holder balance must be untouchable by the escrow");
        assertEq(joule.totalSupply(), ONE);
    }

    function test_BurnDestroysEscrowCustody() public {
        // Simulates redemption: the holder's Joule moves into escrow custody.
        joule.mint(holder, ONE);
        vm.prank(holder);
        joule.transfer(address(this), ONE);

        joule.burn(ONE);

        assertEq(joule.totalSupply(), 0, "a redeemed Joule is destroyed on settlement");
        assertEq(joule.balanceOf(address(this)), 0);
    }

    // --- ordinary token behaviour ---

    function test_MintCreditsRecipient() public {
        joule.mint(agent, 10 * ONE);

        assertEq(joule.balanceOf(agent), 10e18);
        assertEq(joule.totalSupply(), 10e18);
    }

    function test_HasEighteenDecimalsForPoolCompatibility() public view {
        assertEq(joule.decimals(), 18);
        assertEq(joule.ONE(), 10 ** joule.decimals());
    }

    function test_TransfersFreelyWhileNotRedeemed() public {
        joule.mint(agent, ONE);

        vm.prank(agent);
        joule.transfer(holder, ONE);

        assertEq(joule.balanceOf(holder), ONE, "unredeemed Joules trade freely");
        assertEq(joule.balanceOf(agent), 0);
    }
}
