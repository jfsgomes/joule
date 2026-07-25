// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { WorkEscrow } from "../contracts/WorkEscrow.sol";
import { JouleToken } from "../contracts/JouleToken.sol";
import { MockUSDC } from "../contracts/MockUSDC.sol";
import { IVerifier } from "../contracts/verifiers/IVerifier.sol";
import { SumVerifier } from "../contracts/verifiers/SumVerifier.sol";

// --- verifier doubles -------------------------------------------------------

/// @dev Violates the IVerifier "must not revert" contract on purpose.
contract RevertingVerifier is IVerifier {
    function isValidSpec(bytes calldata) external pure returns (bool) {
        return true;
    }

    function verify(bytes calldata, bytes calldata) external pure returns (bool) {
        revert("verifier is broken");
    }
}

/// @dev A rugged verifier that settles every job regardless of the result.
contract AlwaysTrueVerifier is IVerifier {
    function isValidSpec(bytes calldata) external pure returns (bool) {
        return true;
    }

    function verify(bytes calldata, bytes calldata) external pure returns (bool) {
        return true;
    }
}

/// @dev A rugged verifier that makes every Joule permanently unredeemable.
contract RejectAllSpecsVerifier is IVerifier {
    function isValidSpec(bytes calldata) external pure returns (bool) {
        return false;
    }

    function verify(bytes calldata, bytes calldata) external pure returns (bool) {
        return false;
    }
}

// --- tests ------------------------------------------------------------------

contract WorkEscrowTest is Test {
    MockUSDC internal usdc;
    SumVerifier internal verifier;
    WorkEscrow internal escrow;
    JouleToken internal joule;

    uint256 internal ONE;

    address internal agent = makeAddr("agent");
    address internal holder = makeAddr("holder");
    address internal stranger = makeAddr("stranger");
    address internal arbiter = makeAddr("arbiter");

    uint256 internal constant FACE = 5e6; // 5 USDC
    uint256 internal constant PENALTY = 5e6; // 5 USDC

    uint256 internal constant WINDOW = 10; // delivery window, blocks
    uint256 internal constant ACCEPT = 5; // acceptance window, blocks

    /// @dev Cost of one default, and also the collateral freed by settling one
    ///      Joule. Their equality at the minimum legal value is what keeps the
    ///      escrow solvent -- see docs/MECHANISM.md.
    uint256 internal constant PER_JOULE = FACE + PENALTY;

    function setUp() public {
        usdc = new MockUSDC();
        verifier = new SumVerifier();
        escrow = new WorkEscrow(IERC20(address(usdc)), verifier, agent, arbiter, FACE, PENALTY, PER_JOULE, WINDOW, ACCEPT);
        joule = escrow.joule();
        ONE = joule.ONE();

        usdc.mint(agent, 10_000e6);
        vm.prank(agent);
        usdc.approve(address(escrow), type(uint256).max);
    }

    // --- helpers ---

    function _stakeAndIssue(uint256 count) internal {
        vm.startPrank(agent);
        escrow.stake(PER_JOULE * count);
        escrow.issue(count);
        vm.stopPrank();
    }

    function _giveJoules(address to, uint256 count) internal {
        vm.prank(agent);
        joule.transfer(to, count * ONE);
    }

    function _redeemAs(address who, uint256 a, uint256 b) internal returns (uint256 jobId) {
        bytes memory spec = abi.encode(a, b);
        vm.startPrank(who);
        joule.approve(address(escrow), ONE);
        jobId = escrow.redeem(spec);
        vm.stopPrank();
    }

    /// @dev Payouts are credited, not pushed -- see the pull-payment note in
    ///      WorkEscrow. Tests collect explicitly so both halves are exercised.
    function _withdrawAs(address who) internal returns (uint256) {
        vm.prank(who);
        return escrow.withdraw();
    }

    /// @dev The escrow stores only a hash, so the spec is re-supplied here.
    function _deliver(uint256 jobId, uint256 a, uint256 b, uint256 sum) internal {
        vm.prank(agent);
        escrow.submitWork(jobId, abi.encode(a, b), abi.encode(sum));
    }

    // --- constructor: solvency is enforced, not assumed ---

    function test_ConstructorRejectsUnderCollateralisation() public {
        // One wei short of faceValue + penalty is still insolvent.
        vm.expectRevert(abi.encodeWithSelector(WorkEscrow.UnsafeParameters.selector, PER_JOULE - 1, PER_JOULE));
        new WorkEscrow(IERC20(address(usdc)), verifier, agent, arbiter, FACE, PENALTY, PER_JOULE - 1, WINDOW, ACCEPT);
    }

    /// @dev The reason collateralPerJoule is absolute rather than an integer
    ///      multiple of faceValue: a ratio cannot express 1.2x, so it would
    ///      round a 6-unit liability up to a 10-unit lock. Here the exact
    ///      requirement is 6 and 6 is accepted.
    function test_ConstructorAcceptsNonIntegerCoverage() public {
        WorkEscrow e = new WorkEscrow(IERC20(address(usdc)), verifier, agent, arbiter, 5e6, 1e6, 6e6, WINDOW, ACCEPT);
        assertEq(e.collateralPerJoule(), 6e6);
        assertEq(e.coverageRatioBps(), 12_000, "1.2x, which an integer ratio could not express");
    }

    /// @dev The gate must be `k*fv >= fv+p`. Rounding down instead of up is the
    ///      single change that silently breaks solvency, so pin it with fuzz.
    function testFuzz_ConstructorGateMatchesSolvencyCondition(uint64 fv, uint64 p, uint64 perJoule) public {
        vm.assume(fv > 0);

        bool solvent = uint256(perJoule) >= uint256(fv) + uint256(p);

        if (!solvent) {
            vm.expectRevert();
        }
        WorkEscrow e = new WorkEscrow(IERC20(address(usdc)), verifier, agent, arbiter, fv, p, perJoule, WINDOW, ACCEPT);

        if (solvent) {
            assertGe(e.collateralPerJoule(), e.faceValue() + e.penalty());
        }
    }

    function test_EscrowIsTheTokensOnlyMinter() public view {
        assertEq(joule.escrow(), address(escrow));
    }

    // --- staking and coverage ---

    function test_StakeIncreasesCollateral() public {
        vm.prank(agent);
        escrow.stake(100e6);

        assertEq(escrow.collateral(), 100e6);
        assertEq(usdc.balanceOf(address(escrow)), 100e6);
    }

    function test_OnlyAgentCanStake() public {
        usdc.mint(stranger, 100e6);
        vm.startPrank(stranger);
        usdc.approve(address(escrow), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(WorkEscrow.OnlyAgent.selector, stranger));
        escrow.stake(100e6);
        vm.stopPrank();
    }

    function test_UnstakeBlockedByOutstandingJoules() public {
        _stakeAndIssue(10); // exactly at the coverage limit

        assertEq(escrow.freeCollateral(), 0);

        vm.expectRevert(abi.encodeWithSelector(WorkEscrow.InsufficientCoverage.selector, 0, 1));
        vm.prank(agent);
        escrow.unstake(1);
    }

    /// @dev Delivery frees exactly one Joule's backing -- not one wei more.
    function test_DeliveryFreesExactlyOneJouleOfCollateral() public {
        _stakeAndIssue(10);
        _giveJoules(holder, 1);
        uint256 jobId = _redeemAs(holder, 2, 2);

        assertEq(escrow.freeCollateral(), 0, "nothing free while the job is open");

        _deliver(jobId, 2, 2, 4);

        assertEq(escrow.freeCollateral(), PER_JOULE, "exactly one Joule's backing is released");

        vm.expectRevert(abi.encodeWithSelector(WorkEscrow.InsufficientCoverage.selector, PER_JOULE, PER_JOULE + 1));
        vm.prank(agent);
        escrow.unstake(PER_JOULE + 1);

        vm.prank(agent);
        escrow.unstake(PER_JOULE);
        assertEq(escrow.freeCollateral(), 0);
    }

    /// @dev redeem() does not decrement `outstanding`, so an open job's backing
    ///      stays inside requiredCollateral and cannot be unstaked away.
    function test_UnstakeCannotStrandAnOpenJob() public {
        _stakeAndIssue(10);
        _giveJoules(holder, 1);
        _redeemAs(holder, 2, 2);

        assertEq(escrow.outstanding(), 10, "redeem must not reduce outstanding");
        assertEq(escrow.freeCollateral(), 0);

        // Roll past the deadline and claim: the collateral is still there.
        vm.roll(block.number + WINDOW + 1);
        escrow.claimTimeout(1);
        _withdrawAs(holder);

        assertEq(usdc.balanceOf(holder), FACE + PENALTY);
    }

    // --- issuance ---

    function test_IssueMintsToAgentAndTracksOutstanding() public {
        vm.startPrank(agent);
        escrow.stake(PER_JOULE * 3);
        escrow.issue(3);
        vm.stopPrank();

        assertEq(joule.balanceOf(agent), 3 * ONE);
        assertEq(escrow.outstanding(), 3);
        assertEq(joule.totalSupply(), 3 * ONE);
    }

    function test_IssueRevertsOneOverTheCoverageLimit() public {
        vm.startPrank(agent);
        escrow.stake(PER_JOULE * 10);

        vm.expectRevert(
            abi.encodeWithSelector(WorkEscrow.InsufficientCoverage.selector, PER_JOULE * 10, PER_JOULE * 11)
        );
        escrow.issue(11);
        vm.stopPrank();
    }

    function test_IssuanceHeadroomAgreesWithIssue() public {
        vm.startPrank(agent);
        escrow.stake(PER_JOULE * 7 + 1); // deliberately not a round multiple

        uint256 headroom = escrow.issuanceHeadroom();
        assertEq(headroom, 7, "dust must not buy an extra Joule");

        vm.expectRevert();
        escrow.issue(headroom + 1);

        escrow.issue(headroom);
        assertEq(escrow.outstanding(), 7);
        assertEq(escrow.issuanceHeadroom(), 0);
        vm.stopPrank();
    }

    function test_IssueZeroReverts() public {
        vm.prank(agent);
        vm.expectRevert(WorkEscrow.ZeroCount.selector);
        escrow.issue(0);
    }

    function test_OnlyAgentCanIssue() public {
        _stakeAndIssue(1);
        vm.expectRevert(abi.encodeWithSelector(WorkEscrow.OnlyAgent.selector, stranger));
        vm.prank(stranger);
        escrow.issue(1);
    }

    // --- redemption ---

    function test_RedeemMovesJouleIntoEscrowCustody() public {
        _stakeAndIssue(1);
        _giveJoules(holder, 1);

        uint256 jobId = _redeemAs(holder, 2, 2);

        assertEq(jobId, 1);
        assertEq(joule.balanceOf(holder), 0, "the holder no longer controls it");
        assertEq(joule.balanceOf(address(escrow)), ONE, "custody is the lock");
        assertEq(escrow.outstanding(), 1, "still outstanding until settled");
    }

    /// @dev The attack isValidSpec exists to stop: a spec the verifier cannot
    ///      adjudicate would make delivery impossible and the slash automatic.
    function test_PoisonedSpecIsRejectedBeforeAnyClockStarts() public {
        _stakeAndIssue(1);
        _giveJoules(holder, 1);

        bytes memory poisoned = abi.encode(type(uint256).max, type(uint256).max);

        vm.startPrank(holder);
        joule.approve(address(escrow), ONE);
        vm.expectRevert(WorkEscrow.InvalidJobSpec.selector);
        escrow.redeem(poisoned);
        vm.stopPrank();

        assertEq(escrow.nextJobId(), 1, "no job id was consumed");
        assertEq(joule.balanceOf(holder), ONE, "the Joule never left the holder");
    }

    function test_FractionalJouleCannotRedeem() public {
        _stakeAndIssue(1);
        vm.prank(agent);
        joule.transfer(holder, ONE / 2);

        vm.startPrank(holder);
        joule.approve(address(escrow), type(uint256).max);
        vm.expectRevert(); // ERC20InsufficientBalance -- redeem burns exactly ONE
        escrow.redeem(abi.encode(uint256(2), uint256(2)));
        vm.stopPrank();
    }

    /// @dev The offchain agent loop reads the spec out of this event.
    function test_RedeemEmitsSpecAndDeadline() public {
        _stakeAndIssue(1);
        _giveJoules(holder, 1);
        bytes memory spec = abi.encode(uint256(2), uint256(2));

        vm.startPrank(holder);
        joule.approve(address(escrow), ONE);

        vm.expectEmit(true, true, false, true, address(escrow));
        emit WorkEscrow.Redeemed(1, holder, spec, block.number + WINDOW);
        escrow.redeem(spec);
        vm.stopPrank();
    }

    /// @dev Buy-back-and-retire, which needs no new code: the agent redeems a
    ///      Joule they hold and immediately delivers against it, freeing
    ///      collateral. redeem() is permissionless, so the agent may be the
    ///      redeemer, and submitWork's onlyAgent passes because they are.
    function test_AgentCanRetireOwnJouleToFreeCollateral() public {
        _stakeAndIssue(10);
        assertEq(escrow.freeCollateral(), 0);

        vm.startPrank(agent);
        joule.approve(address(escrow), ONE);
        uint256 jobId = escrow.redeem(abi.encode(uint256(1), uint256(1)));
        escrow.submitWork(jobId, abi.encode(uint256(1), uint256(1)), abi.encode(uint256(2)));
        vm.stopPrank();

        assertEq(escrow.outstanding(), 9);
        assertEq(escrow.freeCollateral(), PER_JOULE, "retiring frees exactly one Joule's backing");
    }

    // --- delivery ---

    function test_HappyPath() public {
        _stakeAndIssue(10);
        _giveJoules(holder, 1);
        uint256 jobId = _redeemAs(holder, 2, 2);

        uint256 collateralBefore = escrow.collateral();
        _deliver(jobId, 2, 2, 4);

        assertEq(escrow.outstanding(), 9);
        assertEq(joule.totalSupply(), 9 * ONE, "the redeemed Joule is destroyed");
        assertEq(escrow.collateral(), collateralBefore, "no USDC moves -- the holder was paid in work");
        assertEq(usdc.balanceOf(holder), 0);
    }

    // --- the optimistic path ---

    /// @dev An unverified result does not settle and does not revert. It enters
    ///      the acceptance window, which is what lets the escrow take work no
    ///      onchain function can adjudicate.
    function test_UnverifiedResultEntersTheAcceptanceWindow() public {
        _stakeAndIssue(1);
        _giveJoules(holder, 1);
        uint256 jobId = _redeemAs(holder, 2, 2);

        vm.prank(agent);
        escrow.submitWork(jobId, abi.encode(uint256(2), uint256(2)), abi.encode(uint256(5))); // wrong sum

        (,, uint64 acceptDeadline, WorkEscrow.Status status) = escrow.jobs(jobId);
        assertEq(uint8(status), uint8(WorkEscrow.Status.Submitted));
        assertEq(acceptDeadline, block.number + ACCEPT);
        assertEq(escrow.outstanding(), 1, "nothing settles yet");
    }

    /// @dev The reason `dispute` has to exist. Submitting anything stops the
    ///      timeout clock, so without a challenge an agent would escape the
    ///      penalty on every unverifiable job by sending one garbage byte.
    function test_SubmittingAnythingBlocksTheTimeout() public {
        _stakeAndIssue(1);
        _giveJoules(holder, 1);
        uint256 jobId = _redeemAs(holder, 2, 2);

        vm.prank(agent);
        escrow.submitWork(jobId, abi.encode(uint256(2), uint256(2)), hex"00");

        vm.roll(block.number + WINDOW + 1);
        vm.expectRevert(abi.encodeWithSelector(WorkEscrow.JobNotOpen.selector, jobId));
        escrow.claimTimeout(jobId);
    }

    function test_RedeemerCanAcceptEarly() public {
        _stakeAndIssue(2);
        _giveJoules(holder, 1);
        uint256 jobId = _redeemAs(holder, 2, 2);

        vm.prank(agent);
        escrow.submitWork(jobId, abi.encode(uint256(2), uint256(2)), abi.encode(uint256(5)));

        vm.prank(holder);
        escrow.accept(jobId);

        assertEq(escrow.outstanding(), 1);
        assertEq(escrow.freeCollateral(), PER_JOULE, "accepting frees the backing");
    }

    function test_OnlyRedeemerCanAccept() public {
        _stakeAndIssue(1);
        _giveJoules(holder, 1);
        uint256 jobId = _redeemAs(holder, 2, 2);

        vm.prank(agent);
        escrow.submitWork(jobId, abi.encode(uint256(2), uint256(2)), abi.encode(uint256(5)));

        vm.expectRevert(abi.encodeWithSelector(WorkEscrow.OnlyRedeemer.selector, stranger));
        vm.prank(stranger);
        escrow.accept(jobId);
    }

    /// @dev Permissionless, so a redeemer who walks away cannot pin the agent's
    ///      collateral forever.
    function test_AnyoneCanFinalizeAfterTheWindow() public {
        _stakeAndIssue(1);
        _giveJoules(holder, 1);
        uint256 jobId = _redeemAs(holder, 2, 2);

        vm.prank(agent);
        escrow.submitWork(jobId, abi.encode(uint256(2), uint256(2)), abi.encode(uint256(5)));

        vm.expectRevert(abi.encodeWithSelector(WorkEscrow.DeadlineNotReached.selector, jobId));
        escrow.finalize(jobId);

        vm.roll(block.number + ACCEPT + 1);
        vm.prank(stranger);
        escrow.finalize(jobId);

        assertEq(escrow.outstanding(), 0);
    }

    // --- disputes ---

    function _submitUnverified(uint256 jobId) internal {
        vm.prank(agent);
        escrow.submitWork(jobId, abi.encode(uint256(2), uint256(2)), abi.encode(uint256(999)));
    }

    function test_DisputeRequiresABond() public {
        _stakeAndIssue(1);
        _giveJoules(holder, 1);
        uint256 jobId = _redeemAs(holder, 2, 2);
        _submitUnverified(jobId);

        usdc.mint(holder, PENALTY);
        vm.startPrank(holder);
        usdc.approve(address(escrow), PENALTY);
        escrow.dispute(jobId);
        vm.stopPrank();

        assertEq(escrow.disputeBonds(), PENALTY, "the bond is held separately from collateral");
        assertEq(escrow.collateral(), PER_JOULE, "the bond is not the agent's money");
        assertEq(usdc.balanceOf(holder), 0);
    }

    function test_DisputeUpheldSlashesTheAgentAndReturnsTheBond() public {
        _stakeAndIssue(1);
        _giveJoules(holder, 1);
        uint256 jobId = _redeemAs(holder, 2, 2);
        _submitUnverified(jobId);

        usdc.mint(holder, PENALTY);
        vm.startPrank(holder);
        usdc.approve(address(escrow), PENALTY);
        escrow.dispute(jobId);
        vm.stopPrank();

        vm.prank(arbiter);
        escrow.resolveDispute(jobId, true);

        _withdrawAs(holder);
        assertEq(usdc.balanceOf(holder), PENALTY + FACE + PENALTY, "bond back, plus the slash payout");
        assertEq(escrow.collateral(), PER_JOULE - (FACE + PENALTY));
        assertEq(escrow.disputeBonds(), 0);
        assertEq(escrow.outstanding(), 0);
    }

    /// @dev The bond is what stops a redeemer rejecting everything for free.
    function test_DisputeRejectedForfeitsTheBondToCollateral() public {
        _stakeAndIssue(1);
        _giveJoules(holder, 1);
        uint256 jobId = _redeemAs(holder, 2, 2);
        _submitUnverified(jobId);

        usdc.mint(holder, PENALTY);
        vm.startPrank(holder);
        usdc.approve(address(escrow), PENALTY);
        escrow.dispute(jobId);
        vm.stopPrank();

        vm.prank(arbiter);
        escrow.resolveDispute(jobId, false);

        assertEq(usdc.balanceOf(holder), 0, "a frivolous challenge costs the bond");
        assertEq(escrow.collateral(), PER_JOULE + PENALTY, "the bond becomes the agent's collateral");
        assertEq(escrow.disputeBonds(), 0);
        assertEq(escrow.outstanding(), 0);
    }

    function test_OnlyArbiterCanResolve() public {
        _stakeAndIssue(1);
        _giveJoules(holder, 1);
        uint256 jobId = _redeemAs(holder, 2, 2);
        _submitUnverified(jobId);

        usdc.mint(holder, PENALTY);
        vm.startPrank(holder);
        usdc.approve(address(escrow), PENALTY);
        escrow.dispute(jobId);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(WorkEscrow.OnlyArbiter.selector, stranger));
        vm.prank(stranger);
        escrow.resolveDispute(jobId, true);
    }

    function test_CannotDisputeAfterTheWindowCloses() public {
        _stakeAndIssue(1);
        _giveJoules(holder, 1);
        uint256 jobId = _redeemAs(holder, 2, 2);
        _submitUnverified(jobId);

        vm.roll(block.number + ACCEPT + 1);

        usdc.mint(holder, PENALTY);
        vm.startPrank(holder);
        usdc.approve(address(escrow), PENALTY);
        vm.expectRevert(abi.encodeWithSelector(WorkEscrow.DeadlinePassed.selector, jobId));
        escrow.dispute(jobId);
        vm.stopPrank();
    }

    /// @dev A verified result never enters the window, so it can never be disputed.
    function test_VerifiedWorkCannotBeDisputed() public {
        _stakeAndIssue(1);
        _giveJoules(holder, 1);
        uint256 jobId = _redeemAs(holder, 2, 2);

        _deliver(jobId, 2, 2, 4); // verifier confirms

        vm.expectRevert(abi.encodeWithSelector(WorkEscrow.JobNotSubmitted.selector, jobId));
        vm.prank(holder);
        escrow.dispute(jobId);
    }

    function test_OnlyAgentCanSubmitWork() public {
        _stakeAndIssue(1);
        _giveJoules(holder, 1);
        uint256 jobId = _redeemAs(holder, 2, 2);

        vm.expectRevert(abi.encodeWithSelector(WorkEscrow.OnlyAgent.selector, holder));
        vm.prank(holder);
        escrow.submitWork(jobId, abi.encode(uint256(2), uint256(2)), abi.encode(uint256(4)));
    }

    // --- deadline boundaries: the two windows must be disjoint and complete ---

    function test_SubmitWorkSucceedsExactlyAtDeadline() public {
        _stakeAndIssue(1);
        _giveJoules(holder, 1);
        uint256 deadline = block.number + WINDOW;
        uint256 jobId = _redeemAs(holder, 2, 2);

        vm.roll(deadline);
        _deliver(jobId, 2, 2, 4);

        assertEq(escrow.outstanding(), 0);
    }

    function test_SubmitWorkRevertsOneBlockPastDeadline() public {
        _stakeAndIssue(1);
        _giveJoules(holder, 1);
        uint256 deadline = block.number + WINDOW;
        uint256 jobId = _redeemAs(holder, 2, 2);

        vm.roll(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(WorkEscrow.DeadlinePassed.selector, jobId));
        vm.prank(agent);
        escrow.submitWork(jobId, abi.encode(uint256(2), uint256(2)), abi.encode(uint256(4)));
    }

    function test_ClaimTimeoutRevertsAtDeadline() public {
        _stakeAndIssue(1);
        _giveJoules(holder, 1);
        uint256 deadline = block.number + WINDOW;
        uint256 jobId = _redeemAs(holder, 2, 2);

        vm.roll(deadline);
        vm.expectRevert(abi.encodeWithSelector(WorkEscrow.DeadlineNotReached.selector, jobId));
        escrow.claimTimeout(jobId);
    }

    function test_ClaimTimeoutSucceedsOneBlockPastDeadline() public {
        _stakeAndIssue(1);
        _giveJoules(holder, 1);
        uint256 deadline = block.number + WINDOW;
        uint256 jobId = _redeemAs(holder, 2, 2);

        vm.roll(deadline + 1);
        escrow.claimTimeout(jobId);
        _withdrawAs(holder);

        assertEq(usdc.balanceOf(holder), FACE + PENALTY);
    }

    // --- default ---

    function test_TimeoutPaysFaceValuePlusPenaltyFromCollateral() public {
        _stakeAndIssue(10);
        _giveJoules(holder, 1);
        uint256 jobId = _redeemAs(holder, 2, 2);

        uint256 collateralBefore = escrow.collateral();
        vm.roll(block.number + WINDOW + 1);
        escrow.claimTimeout(jobId);

        _withdrawAs(holder);
        assertEq(usdc.balanceOf(holder), FACE + PENALTY, "holder is made whole plus the penalty");
        assertEq(escrow.collateral(), collateralBefore - (FACE + PENALTY));
        assertEq(escrow.outstanding(), 9);
        assertEq(joule.totalSupply(), 9 * ONE);
    }

    /// @dev Permissionless to call, but the payout is not redirectable.
    function test_ClaimTimeoutByStrangerStillPaysTheRedeemer() public {
        _stakeAndIssue(1);
        _giveJoules(holder, 1);
        uint256 jobId = _redeemAs(holder, 2, 2);

        vm.roll(block.number + WINDOW + 1);
        vm.prank(stranger);
        escrow.claimTimeout(jobId);

        assertEq(escrow.owed(holder), FACE + PENALTY, "the recorded redeemer is credited");
        assertEq(escrow.owed(stranger), 0, "the caller is credited nothing");

        _withdrawAs(holder);
        assertEq(usdc.balanceOf(holder), FACE + PENALTY);
        vm.expectRevert(abi.encodeWithSelector(WorkEscrow.NothingOwed.selector, stranger));
        _withdrawAs(stranger);
    }

    // --- shortfall: unreachable, but not untested ---

    /// @dev `paid = min(owed, collateral)` guards a case the coverage invariant
    ///      makes impossible: at slash time the job is unsettled, so
    ///      outstanding >= 1, so collateral >= coverageRatio*faceValue >=
    ///      faceValue + penalty. It cannot be reached through the public API.
    ///
    ///      That would normally make it untested dead code, so this corrupts
    ///      `collateral` directly (slot 0) to force the branch and pin what
    ///      degradation looks like. The choice being pinned: pay what is there
    ///      and emit, rather than revert. Reverting on the payout path would
    ///      leave the redeemer with a burned-but-unpaid claim and no remedy,
    ///      and would lock every other redeemer out too.
    function test_ShortfallPaysWhatRemainsRatherThanReverting() public {
        _stakeAndIssue(1);
        _giveJoules(holder, 1);
        uint256 jobId = _redeemAs(holder, 2, 2);

        uint256 owed = FACE + PENALTY;
        uint256 corrupted = 3e6; // less than owed
        vm.store(address(escrow), bytes32(uint256(0)), bytes32(corrupted));
        assertEq(escrow.collateral(), corrupted, "slot 0 is `collateral`");

        vm.roll(block.number + WINDOW + 1);

        vm.expectEmit(true, false, false, true, address(escrow));
        emit WorkEscrow.Shortfall(jobId, owed, corrupted);
        escrow.claimTimeout(jobId);

        _withdrawAs(holder);
        assertEq(usdc.balanceOf(holder), corrupted, "redeemer is paid what was actually there");
        assertEq(escrow.collateral(), 0);
        assertEq(escrow.outstanding(), 0, "the job still closes -- no stuck Joule");

        (,,, WorkEscrow.Status status) = escrow.jobs(jobId);
        assertEq(uint8(status), uint8(WorkEscrow.Status.Slashed));
    }

    // --- double settlement ---

    function test_CannotSettleTwice() public {
        _stakeAndIssue(2);
        _giveJoules(holder, 2);
        uint256 delivered = _redeemAs(holder, 2, 2);
        uint256 timedOut = _redeemAs(holder, 3, 3);

        _deliver(delivered, 2, 2, 4);
        vm.roll(block.number + WINDOW + 1);
        escrow.claimTimeout(timedOut);

        // delivered: neither path may run again
        vm.expectRevert(abi.encodeWithSelector(WorkEscrow.JobNotOpen.selector, delivered));
        escrow.claimTimeout(delivered);

        vm.expectRevert(abi.encodeWithSelector(WorkEscrow.JobNotOpen.selector, delivered));
        vm.prank(agent);
        escrow.submitWork(delivered, abi.encode(uint256(2), uint256(2)), abi.encode(uint256(4)));

        // timed out: likewise
        vm.expectRevert(abi.encodeWithSelector(WorkEscrow.JobNotOpen.selector, timedOut));
        escrow.claimTimeout(timedOut);

        vm.expectRevert(abi.encodeWithSelector(WorkEscrow.JobNotOpen.selector, timedOut));
        vm.prank(agent);
        escrow.submitWork(timedOut, abi.encode(uint256(3), uint256(3)), abi.encode(uint256(6)));
    }

    // --- total wipeout: the solvency property, executed ---

    /// @dev docs/MECHANISM.md: burning one Joule frees coverageRatio*faceValue,
    ///      one default costs faceValue+penalty, and at the minimum legal ratio
    ///      those are equal -- so an agent who defaults on everything lands
    ///      exactly on zero with every redeemer paid in full.
    function test_TotalWipeoutDrainsExactlyToZero() public {
        uint256 n = 10;
        _stakeAndIssue(n);

        address[] memory redeemers = new address[](n);
        uint256[] memory jobIds = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            redeemers[i] = makeAddr(string.concat("redeemer", vm.toString(i)));
            _giveJoules(redeemers[i], 1);
            jobIds[i] = _redeemAs(redeemers[i], i, i);
        }

        vm.roll(block.number + WINDOW + 1);

        vm.recordLogs();
        for (uint256 i = 0; i < n; i++) {
            escrow.claimTimeout(jobIds[i]);
            vm.prank(redeemers[i]);
            escrow.withdraw();
            assertEq(usdc.balanceOf(redeemers[i]), FACE + PENALTY, "every redeemer paid in full");
        }

        assertEq(escrow.collateral(), 0, "collateral exactly exhausted, never overdrawn");
        assertEq(escrow.outstanding(), 0);
        assertEq(joule.totalSupply(), 0);
        assertEq(usdc.balanceOf(address(escrow)), 0);

        // Shortfall must never have fired.
        bytes32 shortfall = keccak256("Shortfall(uint256,uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != shortfall, "Shortfall is provably unreachable");
        }
    }

    /// @dev The same property must hold at a different legal parameter set.
    function test_TotalWipeoutAtTripleCoverage() public {
        uint256 face = 5e6;
        uint256 pen = 10e6; // 2x face, so each Joule must lock face + pen = 15
        uint256 perJoule = face + pen;
        WorkEscrow e =
            new WorkEscrow(IERC20(address(usdc)), verifier, agent, arbiter, face, pen, perJoule, WINDOW, ACCEPT);
        JouleToken j = e.joule();

        uint256 n = 4;

        vm.startPrank(agent);
        usdc.approve(address(e), type(uint256).max);
        e.stake(perJoule * n);
        e.issue(n);
        vm.stopPrank();

        // Cached: an external call in argument position consumes the pending
        // vm.prank before the call under test runs.
        uint256 one = j.ONE();

        uint256[] memory jobIds = new uint256[](n);
        address[] memory redeemers = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            redeemers[i] = makeAddr(string.concat("r3-", vm.toString(i)));
            vm.prank(agent);
            j.transfer(redeemers[i], one);

            vm.startPrank(redeemers[i]);
            j.approve(address(e), one);
            jobIds[i] = e.redeem(abi.encode(i, i));
            vm.stopPrank();
        }

        vm.roll(block.number + WINDOW + 1);
        for (uint256 i = 0; i < n; i++) {
            e.claimTimeout(jobIds[i]);
            vm.prank(redeemers[i]);
            e.withdraw();
            assertEq(usdc.balanceOf(redeemers[i]), face + pen);
        }

        assertEq(e.collateral(), 0);
        assertEq(e.outstanding(), 0);
    }

    // --- malicious verifiers: the trust root, made visible ---

    /// @dev A verifier that breaks the "must not revert" contract must not strand
    ///      the agent. try/catch sends the job down the optimistic path instead,
    ///      where it can still be accepted, finalized or disputed. Before the
    ///      optimistic path existed, a broken verifier meant guaranteed slashes.
    function test_RevertingVerifierFallsBackToTheOptimisticPath() public {
        WorkEscrow e = _escrowWithVerifier(new RevertingVerifier());
        (, uint256 jobId) = _setupOneJob(e);

        vm.prank(agent);
        e.submitWork(jobId, abi.encode(uint256(2), uint256(2)), abi.encode(uint256(4)));

        (,,, WorkEscrow.Status status) = e.jobs(jobId);
        assertEq(uint8(status), uint8(WorkEscrow.Status.Submitted), "must not revert, must not settle");

        vm.roll(block.number + ACCEPT + 1);
        e.finalize(jobId);
        assertEq(e.outstanding(), 0, "the agent can still be paid out despite a broken verifier");
    }

    function test_AlwaysTrueVerifierSettlesGarbage() public {
        WorkEscrow e = _escrowWithVerifier(new AlwaysTrueVerifier());
        (, uint256 jobId) = _setupOneJob(e);

        vm.prank(agent);
        e.submitWork(jobId, abi.encode(uint256(2), uint256(2)), hex"deadbeef"); // not even a number

        assertEq(e.outstanding(), 0, "a rugged verifier settles anything");
    }

    function test_RejectAllSpecsVerifierMakesJoulesUnredeemable() public {
        WorkEscrow e = _escrowWithVerifier(new RejectAllSpecsVerifier());

        vm.startPrank(agent);
        usdc.approve(address(e), type(uint256).max);
        e.stake(PER_JOULE);
        e.issue(1);
        e.joule().approve(address(e), type(uint256).max);

        vm.expectRevert(WorkEscrow.InvalidJobSpec.selector);
        e.redeem(abi.encode(uint256(2), uint256(2)));
        vm.stopPrank();
    }

    function _escrowWithVerifier(IVerifier v) internal returns (WorkEscrow e) {
        e = new WorkEscrow(IERC20(address(usdc)), v, agent, arbiter, FACE, PENALTY, PER_JOULE, WINDOW, ACCEPT);
    }

    function _setupOneJob(WorkEscrow e) internal returns (JouleToken j, uint256 jobId) {
        j = e.joule();
        vm.startPrank(agent);
        usdc.approve(address(e), type(uint256).max);
        e.stake(PER_JOULE);
        e.issue(1);
        j.transfer(holder, j.ONE());
        vm.stopPrank();

        vm.startPrank(holder);
        j.approve(address(e), j.ONE());
        jobId = e.redeem(abi.encode(uint256(2), uint256(2)));
        vm.stopPrank();
    }

    // --- donations must not corrupt accounting ---

    function test_DonatedTokensDoNotAffectCoverage() public {
        _stakeAndIssue(10);

        usdc.mint(address(escrow), 1_000e6); // unsolicited USDC

        assertEq(escrow.collateral(), PER_JOULE * 10, "ledger ignores donations");
        assertEq(escrow.freeCollateral(), 0, "donations do not buy issuance headroom");

        vm.expectRevert();
        vm.prank(agent);
        escrow.unstake(1);
    }
    // --- C-1: the spec is hashed, not stored ---

    function test_SpecIsNotStoredOnlyItsHash() public {
        _stakeAndIssue(1);
        _giveJoules(holder, 1);
        bytes memory spec = abi.encode(uint256(2), uint256(2));
        uint256 jobId = _redeemAs(holder, 2, 2);

        assertEq(escrow.specHashes(jobId), keccak256(spec), "only the hash is kept");
    }

    function test_SubmitWorkRejectsAMismatchedSpec() public {
        _stakeAndIssue(1);
        _giveJoules(holder, 1);
        uint256 jobId = _redeemAs(holder, 2, 2);

        vm.expectRevert(abi.encodeWithSelector(WorkEscrow.SpecMismatch.selector, jobId));
        vm.prank(agent);
        escrow.submitWork(jobId, abi.encode(uint256(3), uint256(3)), abi.encode(uint256(6)));
    }

    /// @dev The escrow bounds its own exposure rather than trusting the verifier
    ///      to reject long specs -- a variable-length verifier would otherwise
    ///      let a redeemer make delivery arbitrarily expensive.
    function test_OversizedSpecIsRejected() public {
        WorkEscrow e = _escrowWithVerifier(new AlwaysTrueVerifier());
        vm.startPrank(agent);
        usdc.approve(address(e), type(uint256).max);
        e.stake(PER_JOULE);
        e.issue(1);
        e.joule().approve(address(e), type(uint256).max);

        uint256 max = e.MAX_SPEC_BYTES();
        bytes memory tooBig = new bytes(max + 1);
        vm.expectRevert(abi.encodeWithSelector(WorkEscrow.SpecTooLarge.selector, max + 1, max));
        e.redeem(tooBig);

        e.redeem(new bytes(max)); // exactly at the bound is fine
        vm.stopPrank();
    }

    // --- C-2: payouts are pull, so one blocked recipient cannot brick a job ---

    function test_WithdrawRevertsWhenNothingOwed() public {
        vm.expectRevert(abi.encodeWithSelector(WorkEscrow.NothingOwed.selector, stranger));
        vm.prank(stranger);
        escrow.withdraw();
    }

    function test_CreditSurvivesUntilWithdrawn() public {
        _stakeAndIssue(1);
        _giveJoules(holder, 1);
        uint256 jobId = _redeemAs(holder, 2, 2);
        vm.roll(block.number + WINDOW + 1);
        escrow.claimTimeout(jobId);

        assertEq(escrow.owed(holder), FACE + PENALTY);
        assertEq(escrow.totalOwed(), FACE + PENALTY);
        assertEq(usdc.balanceOf(holder), 0, "nothing is pushed");

        assertEq(_withdrawAs(holder), FACE + PENALTY);
        assertEq(escrow.owed(holder), 0);
        assertEq(escrow.totalOwed(), 0);
    }

    // --- C-3: the constructor validates its inputs ---

    function test_ConstructorRejectsZeroAddresses() public {
        vm.expectRevert(abi.encodeWithSelector(WorkEscrow.ZeroAddress.selector, "collateralToken"));
        new WorkEscrow(IERC20(address(0)), verifier, agent, arbiter, FACE, PENALTY, PER_JOULE, WINDOW, ACCEPT);

        vm.expectRevert(abi.encodeWithSelector(WorkEscrow.ZeroAddress.selector, "verifier"));
        new WorkEscrow(IERC20(address(usdc)), IVerifier(address(0)), agent, arbiter, FACE, PENALTY, PER_JOULE, WINDOW, ACCEPT);

        vm.expectRevert(abi.encodeWithSelector(WorkEscrow.ZeroAddress.selector, "agent"));
        new WorkEscrow(IERC20(address(usdc)), verifier, address(0), arbiter, FACE, PENALTY, PER_JOULE, WINDOW, ACCEPT);

        // A zero arbiter would leave every disputed job permanently unresolvable.
        vm.expectRevert(abi.encodeWithSelector(WorkEscrow.ZeroAddress.selector, "arbiter"));
        new WorkEscrow(IERC20(address(usdc)), verifier, agent, address(0), FACE, PENALTY, PER_JOULE, WINDOW, ACCEPT);
    }

    function test_ConstructorRejectsZeroFaceValue() public {
        vm.expectRevert(abi.encodeWithSelector(WorkEscrow.InvalidParameter.selector, "faceValue"));
        new WorkEscrow(IERC20(address(usdc)), verifier, agent, arbiter, 0, PENALTY, PER_JOULE, WINDOW, ACCEPT);
    }

    /// @dev An unbounded window would overflow the uint64 deadline and truncate
    ///      to the current block, turning every Joule into a free slash.
    function test_ConstructorRejectsBadWindows() public {
        uint256 max = escrow.MAX_WINDOW_BLOCKS();

        vm.expectRevert(abi.encodeWithSelector(WorkEscrow.InvalidParameter.selector, "deliveryBlocks"));
        new WorkEscrow(IERC20(address(usdc)), verifier, agent, arbiter, FACE, PENALTY, PER_JOULE, 0, ACCEPT);

        vm.expectRevert(abi.encodeWithSelector(WorkEscrow.InvalidParameter.selector, "deliveryBlocks"));
        new WorkEscrow(IERC20(address(usdc)), verifier, agent, arbiter, FACE, PENALTY, PER_JOULE, max + 1, ACCEPT);

        vm.expectRevert(abi.encodeWithSelector(WorkEscrow.InvalidParameter.selector, "acceptBlocks"));
        new WorkEscrow(IERC20(address(usdc)), verifier, agent, arbiter, FACE, PENALTY, PER_JOULE, WINDOW, 0);
    }

    // --- C-5: a broken verifier is diagnosable ---

    function test_RevertingVerifierEmitsVerifierReverted() public {
        WorkEscrow e = _escrowWithVerifier(new RevertingVerifier());
        (, uint256 jobId) = _setupOneJob(e);

        vm.expectEmit(true, false, false, false, address(e));
        emit WorkEscrow.VerifierReverted(jobId);
        vm.prank(agent);
        e.submitWork(jobId, abi.encode(uint256(2), uint256(2)), abi.encode(uint256(4)));
    }

}
