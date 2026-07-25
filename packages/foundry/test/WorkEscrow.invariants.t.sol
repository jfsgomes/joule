// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { WorkEscrow } from "../contracts/WorkEscrow.sol";
import { JouleToken } from "../contracts/JouleToken.sol";
import { MockUSDC } from "../contracts/MockUSDC.sol";
import { SumVerifier } from "../contracts/verifiers/SumVerifier.sol";
import { WorkEscrowHandler } from "./handlers/WorkEscrowHandler.sol";

/**
 * @title WorkEscrowInvariants
 * @notice The five invariants from PLAN.md, executable.
 *
 * @dev Unit tests check the paths we thought of. This checks the ones we did
 *      not: thousands of random orderings of stake / unstake / issue /
 *      distribute / redeem / deliver / claimTimeout, interleaved with block
 *      jumps and with hostile calls that must always fail.
 */
contract WorkEscrowInvariants is Test {
    MockUSDC internal usdc;
    SumVerifier internal verifier;
    WorkEscrow internal escrow;
    JouleToken internal joule;
    WorkEscrowHandler internal handler;

    address internal agent = makeAddr("agent");
    address internal arbiter = makeAddr("arbiter");

    uint256 internal constant FACE = 5e6;
    uint256 internal constant PENALTY = 5e6;
    uint256 internal constant COVERAGE = 2;
    uint256 internal constant WINDOW = 10;
    uint256 internal constant ACCEPT = 5;

    function setUp() public {
        usdc = new MockUSDC();
        verifier = new SumVerifier();
        escrow = new WorkEscrow(IERC20(address(usdc)), verifier, agent, arbiter, FACE, PENALTY, COVERAGE, WINDOW, ACCEPT);
        joule = escrow.joule();

        address[] memory actors = new address[](4);
        actors[0] = makeAddr("holderA");
        actors[1] = makeAddr("holderB");
        actors[2] = makeAddr("holderC");
        actors[3] = makeAddr("holderD");

        handler = new WorkEscrowHandler(escrow, usdc, agent, actors);
        targetContract(address(handler));
    }

    // --- PLAN.md invariant 2: coverage ---

    /// @dev collateral >= coverageRatio * faceValue * outstanding, always.
    ///      This is the solvency guarantee the whole mechanism rests on.
    function invariant_CollateralAlwaysCoversOutstanding() public view {
        assertGe(
            escrow.collateral(),
            escrow.requiredCollateral(escrow.outstanding()),
            "coverage invariant broken -- the escrow cannot pay every possible default"
        );
    }

    // --- PLAN.md invariant 1: only the escrow mints or burns ---

    /// @dev Any Joule minted outside `issue`, or any burn outside settlement,
    ///      shows up here as supply drifting from `outstanding`.
    function invariant_SupplyEqualsOutstanding() public view {
        assertEq(
            joule.totalSupply(),
            escrow.outstanding() * joule.ONE(),
            "Joule supply drifted from outstanding -- something minted or burned outside the escrow"
        );
    }

    // --- PLAN.md invariant 3: custody is the lock ---

    /// @dev Every unsettled job's Joule must still be sitting in the escrow --
    ///      Open, Submitted and Disputed alike. A Joule only leaves custody by
    ///      being burned at settlement.
    function invariant_EscrowCustodiesEveryUnsettledJoule() public view {
        assertGe(
            joule.balanceOf(address(escrow)),
            handler.unsettledJobCount() * joule.ONE(),
            "an unsettled job's Joule left escrow custody"
        );
    }

    // --- PLAN.md invariant 4: backing collateral cannot be withdrawn ---

    /// @dev The ledger must never exceed the tokens actually held, or a
    ///      redeemer's claim could fail at exactly the wrong moment.
    function invariant_EscrowHoldsAtLeastItsLedger() public view {
        assertGe(
            usdc.balanceOf(address(escrow)),
            escrow.collateral() + escrow.disputeBonds(),
            "the escrow's ledgers exceed its real USDC balance"
        );
    }

    /// @dev freeCollateral is what `unstake` is allowed to release. It must
    ///      never exceed what is actually unencumbered.
    function invariant_FreeCollateralNeverExceedsUnencumbered() public view {
        uint256 required = escrow.requiredCollateral(escrow.outstanding());
        uint256 unencumbered = escrow.collateral() > required ? escrow.collateral() - required : 0;
        assertEq(escrow.freeCollateral(), unencumbered, "freeCollateral disagrees with the coverage requirement");
    }

    // --- PLAN.md invariant 5: claimTimeout pays only the redeemer ---

    /// @dev Actors start with zero USDC and can only ever receive it as a
    ///      timeout payout. Any balance beyond what the ghost says they are
    ///      owed means a payout was routed to the wrong party.
    function invariant_TimeoutPaysOnlyTheRecordedRedeemer() public view {
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; i++) {
            address actor = handler.actors(i);
            // bondFunded is USDC minted to post a bond; a posted bond leaves the
            // wallet, so the ceiling is "everything owed, plus every bond ever
            // funded". Exceeding it means the escrow paid the wrong party.
            assertLe(
                usdc.balanceOf(actor),
                handler.expectedPayout(actor) + handler.bondFunded(actor),
                "an address holds USDC it was never owed -- payout routing is wrong"
            );
        }
    }

    // --- Shortfall must be unreachable ---

    /// @dev The review argues Shortfall cannot fire: at claimTimeout entry the
    ///      job is Open, so outstanding >= 1, so collateral >= k*fv >= fv+p.
    ///      If it ever fired, collateral would have gone below the requirement
    ///      and invariant_CollateralAlwaysCoversOutstanding would trip. This
    ///      asserts the arithmetic precondition directly.
    function invariant_CollateralCoversAnyPendingDefault() public view {
        if (handler.openJobCount() + handler.disputedJobCount() == 0) return;
        assertGe(
            escrow.collateral(),
            escrow.faceValue() + escrow.penalty(),
            "collateral fell below one default's cost while a job was still open"
        );
    }

    /// @dev Anti-vacuity guard. Every invariant above holds trivially against an
    ///      escrow that nothing ever happened to, so prove the handler can
    ///      actually reach each interesting state.
    ///
    ///      This is a deterministic test rather than `afterInvariant`, which
    ///      only observes the final run's state (~50 calls) and would therefore
    ///      flake on whether that particular run happened to time a job out.
    ///      It is also not an `invariant_` function: those are evaluated
    ///      against the initial state too, where no calls have landed yet.
    ///
    ///      This caught a real defect. The handler originally rolled 1-30
    ///      blocks against a 10-block window, so one roll expired every open
    ///      job and `deliver` never once succeeded in 1,245 attempts -- the
    ///      whole campaign silently exercised only the timeout path.
    function test_HandlerCanReachEveryPath() public {
        handler.stake(type(uint256).max);
        assertGt(handler.callsStake(), 0, "handler cannot stake");

        // One Joule per settlement path below, since each burns one.
        handler.issue(6);
        assertGt(handler.callsIssue(), 0, "handler cannot issue");
        handler.distribute(0, 6);

        // 1. verified -- settles inside submitWork, no window
        handler.redeem(0, 2, 2);
        assertGt(handler.callsRedeem(), 0, "handler cannot redeem");
        handler.deliver(0);
        assertGt(handler.callsDeliver(), 0, "handler cannot deliver -- the verified path is unreachable");

        // 2. unverified -> redeemer accepts early
        handler.redeem(0, 3, 3);
        handler.deliverWrong(0, 999);
        assertGt(handler.callsSubmitUnverified(), 0, "handler cannot submit an unverified result");
        handler.acceptWork(0);
        assertGt(handler.callsAccept(), 0, "handler cannot accept -- the optimistic path is unreachable");

        // 3. unverified -> disputed -> arbiter upholds
        handler.redeem(0, 4, 4);
        handler.deliverWrong(0, 999);
        handler.disputeWork(0);
        assertGt(handler.callsDispute(), 0, "handler cannot dispute -- the challenge path is unreachable");
        handler.resolve(0, true);
        assertGt(handler.callsResolve(), 0, "handler cannot resolve a dispute");

        // 4. unverified -> unchallenged -> anyone finalizes after the window
        handler.redeem(0, 5, 5);
        handler.deliverWrong(0, 999);
        handler.roll(8); // ACCEPT is 5
        handler.finalizeWork(0, 0);
        assertGt(handler.callsFinalize(), 0, "handler cannot finalize -- auto-accept is unreachable");

        // 5. nothing submitted at all -> slash
        handler.redeem(0, 6, 6);
        handler.roll(8);
        handler.roll(8); // WINDOW is 10
        handler.claimTimeout(0, 1);
        assertGt(handler.callsTimeout(), 0, "handler cannot time out -- the slash path is unreachable");

        // And the hostile actions must have been refused, not silently ignored.
        uint256 revertsBefore = handler.reverts();
        handler.tryRogueMint(0, 1e18);
        handler.tryMoveCustodiedJoule(0);
        assertGt(handler.reverts(), revertsBefore, "hostile calls were not rejected");
    }
}
