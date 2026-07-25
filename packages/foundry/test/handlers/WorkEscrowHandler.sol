// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { CommonBase } from "forge-std/Base.sol";
import { StdUtils } from "forge-std/StdUtils.sol";
import { StdCheats } from "forge-std/StdCheats.sol";

import { WorkEscrow } from "../../contracts/WorkEscrow.sol";
import { JouleToken } from "../../contracts/JouleToken.sol";
import { MockUSDC } from "../../contracts/MockUSDC.sol";

/**
 * @title WorkEscrowHandler
 * @notice Bounded, stateful driver for the invariant suite.
 *
 * @dev Every action is wrapped in try/catch. A reverting call is a legitimate
 *      outcome here -- `unstake` beyond coverage, `submitWork` past a deadline,
 *      `claimTimeout` before one -- and the point of the run is that the
 *      invariants survive whichever calls happen to land, not that every call
 *      succeeds. Reverts are counted so a run that silently did nothing is
 *      visible rather than passing vacuously.
 *
 *      Ghost state mirrors what the escrow should be doing, so the invariants
 *      can be checked against an independently maintained view rather than
 *      against the contract's own accounting.
 */
contract WorkEscrowHandler is CommonBase, StdUtils, StdCheats {
    WorkEscrow public immutable escrow;
    JouleToken public immutable joule;
    MockUSDC public immutable usdc;
    address public immutable agent;

    uint256 public immutable ONE;
    uint256 public immutable FACE;
    uint256 public immutable PENALTY;

    address[] public actors;

    /// @notice Job ids currently in Status.Open, for swap-and-pop removal.
    uint256[] public openJobIds;
    /// @notice Jobs on the optimistic track, awaiting acceptance.
    uint256[] public submittedJobIds;
    /// @notice Jobs challenged and awaiting the arbiter.
    uint256[] public disputedJobIds;
    mapping(uint256 jobId => uint256) private _indexOfSubmitted;
    mapping(uint256 jobId => uint256) private _indexOfDisputed;
    /// @notice USDC minted to an actor purely to post a bond. Excluded from the
    ///         payout ghost, which only tracks money the escrow owes them.
    mapping(address => uint256) public bondFunded;
    mapping(uint256 jobId => address) public jobRedeemer;
    mapping(uint256 jobId => uint256) private _indexOfJob;

    /// @notice USDC each address is *owed* by timeouts. Anything an address
    ///         holds beyond this would mean claimTimeout paid the wrong party.
    mapping(address => uint256) public expectedPayout;

    // --- coverage counters, so a vacuous run is visible ---
    uint256 public callsStake;
    uint256 public callsUnstake;
    uint256 public callsIssue;
    uint256 public callsRedeem;
    uint256 public callsDeliver;
    uint256 public callsTimeout;
    uint256 public callsSubmitUnverified;
    uint256 public callsAccept;
    uint256 public callsFinalize;
    uint256 public callsDispute;
    uint256 public callsResolve;
    uint256 public reverts;

    constructor(WorkEscrow escrow_, MockUSDC usdc_, address agent_, address[] memory actors_) {
        escrow = escrow_;
        joule = escrow_.joule();
        usdc = usdc_;
        agent = agent_;
        actors = actors_;

        ONE = joule.ONE();
        FACE = escrow_.faceValue();
        PENALTY = escrow_.penalty();

        usdc.mint(agent_, 1_000_000e6);
        vm.prank(agent_);
        usdc.approve(address(escrow_), type(uint256).max);

        for (uint256 i = 0; i < actors_.length; i++) {
            vm.prank(actors_[i]);
            joule.approve(address(escrow_), type(uint256).max);
        }
    }

    function openJobCount() external view returns (uint256) {
        return openJobIds.length;
    }

    function submittedJobCount() external view returns (uint256) {
        return submittedJobIds.length;
    }

    function disputedJobCount() external view returns (uint256) {
        return disputedJobIds.length;
    }

    /// @notice Joules the escrow must still be holding: every unsettled job.
    function unsettledJobCount() external view returns (uint256) {
        return openJobIds.length + submittedJobIds.length + disputedJobIds.length;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    // --- agent: collateral ---

    function stake(uint256 amount) external {
        amount = bound(amount, 1, 100_000e6);
        vm.prank(agent);
        try escrow.stake(amount) {
            callsStake++;
        } catch {
            reverts++;
        }
    }

    /// @dev Deliberately allowed to exceed freeCollateral. The escrow must
    ///      refuse; the invariant then confirms nothing leaked.
    function unstake(uint256 amount) external {
        amount = bound(amount, 1, escrow.collateral() + 1e6);
        vm.prank(agent);
        try escrow.unstake(amount) {
            callsUnstake++;
        } catch {
            reverts++;
        }
    }

    // --- agent: issuance ---

    function issue(uint256 count) external {
        count = bound(count, 1, 20);
        vm.prank(agent);
        try escrow.issue(count) {
            callsIssue++;
        } catch {
            reverts++;
        }
    }

    /// @dev Moves Joules into circulation so holders have something to redeem.
    function distribute(uint256 actorSeed, uint256 count) external {
        uint256 available = joule.balanceOf(agent) / ONE;
        if (available == 0) return;
        count = bound(count, 1, available);

        vm.prank(agent);
        try joule.transfer(_actor(actorSeed), count * ONE) { }
        catch {
            reverts++;
        }
    }

    // --- holders: redemption ---

    function redeem(uint256 actorSeed, uint256 a, uint256 b) external {
        address who = _actor(actorSeed);
        if (joule.balanceOf(who) < ONE) return;

        a = bound(a, 0, type(uint128).max);
        b = bound(b, 0, type(uint128).max);

        vm.prank(who);
        try escrow.redeem(abi.encode(a, b)) returns (uint256 jobId) {
            callsRedeem++;
            jobRedeemer[jobId] = who;
            _indexOfJob[jobId] = openJobIds.length;
            openJobIds.push(jobId);
        } catch {
            reverts++;
        }
    }

    // --- agent: delivery ---

    function deliver(uint256 jobSeed) external {
        if (openJobIds.length == 0) return;
        uint256 idx = bound(jobSeed, 0, openJobIds.length - 1);
        uint256 jobId = openJobIds[idx];

        (uint256 a, uint256 b) = abi.decode(escrow.jobSpecs(jobId), (uint256, uint256));

        vm.prank(agent);
        try escrow.submitWork(jobId, abi.encode(a + b)) {
            callsDeliver++;
            _closeJob(jobId);
        } catch {
            reverts++;
        }
    }


    /// @dev A wrong answer must never settle a job outright. It may only move it
    ///      onto the optimistic track, where acceptance or a dispute decides.
    function deliverWrong(uint256 jobSeed, uint256 wrong) external {
        if (openJobIds.length == 0) return;
        uint256 jobId = openJobIds[bound(jobSeed, 0, openJobIds.length - 1)];

        vm.prank(agent);
        try escrow.submitWork(jobId, abi.encode(wrong)) {
            (uint256 a, uint256 b) = abi.decode(escrow.jobSpecs(jobId), (uint256, uint256));
            (,,, WorkEscrow.Status status) = escrow.jobs(jobId);

            if (wrong == a + b) {
                require(status == WorkEscrow.Status.Settled, "the true sum failed to settle");
                callsDeliver++;
                _closeJob(jobId);
            } else {
                require(status == WorkEscrow.Status.Submitted, "a wrong answer settled a job outright");
                callsSubmitUnverified++;
                _toSubmitted(jobId);
            }
        } catch {
            reverts++;
        }
    }

    // --- optimistic path ---

    function acceptWork(uint256 jobSeed) external {
        if (submittedJobIds.length == 0) return;
        uint256 jobId = submittedJobIds[bound(jobSeed, 0, submittedJobIds.length - 1)];

        vm.prank(jobRedeemer[jobId]);
        try escrow.accept(jobId) {
            callsAccept++;
            _closeSubmitted(jobId);
        } catch {
            reverts++;
        }
    }

    function finalizeWork(uint256 jobSeed, uint256 callerSeed) external {
        if (submittedJobIds.length == 0) return;
        uint256 jobId = submittedJobIds[bound(jobSeed, 0, submittedJobIds.length - 1)];

        vm.prank(_actor(callerSeed));
        try escrow.finalize(jobId) {
            callsFinalize++;
            _closeSubmitted(jobId);
        } catch {
            reverts++;
        }
    }

    function disputeWork(uint256 jobSeed) external {
        if (submittedJobIds.length == 0) return;
        uint256 jobId = submittedJobIds[bound(jobSeed, 0, submittedJobIds.length - 1)];
        address who = jobRedeemer[jobId];

        // Fund the bond from outside the system so it never pollutes the
        // expectedPayout ghost: bondFunded records what was handed over.
        usdc.mint(who, PENALTY);
        bondFunded[who] += PENALTY;

        vm.prank(who);
        usdc.approve(address(escrow), PENALTY);

        vm.prank(who);
        try escrow.dispute(jobId) {
            callsDispute++;
            _toDisputed(jobId);
        } catch {
            reverts++;
        }
    }

    function resolve(uint256 jobSeed, bool upheld) external {
        if (disputedJobIds.length == 0) return;
        uint256 jobId = disputedJobIds[bound(jobSeed, 0, disputedJobIds.length - 1)];
        address redeemer = jobRedeemer[jobId];

        uint256 owed = FACE + PENALTY;
        uint256 willPay = owed > escrow.collateral() ? escrow.collateral() : owed;

        vm.prank(escrow.arbiter());
        try escrow.resolveDispute(jobId, upheld) {
            callsResolve++;
            if (upheld) {
                // bond refunded, plus the slash payout
                expectedPayout[redeemer] += PENALTY + willPay;
            }
            _closeDisputed(jobId);
        } catch {
            reverts++;
        }
    }

    // --- anyone: default ---

    /// @dev `callerSeed` deliberately picks an arbitrary caller. Payout routing
    ///      is then checked by the expectedPayout ghost.
    function claimTimeout(uint256 jobSeed, uint256 callerSeed) external {
        if (openJobIds.length == 0) return;
        uint256 jobId = openJobIds[bound(jobSeed, 0, openJobIds.length - 1)];
        address caller = _actor(callerSeed);

        uint256 owed = FACE + PENALTY;
        uint256 collateralBefore = escrow.collateral();
        uint256 willPay = owed > collateralBefore ? collateralBefore : owed;

        vm.prank(caller);
        try escrow.claimTimeout(jobId) {
            callsTimeout++;
            expectedPayout[jobRedeemer[jobId]] += willPay;
            _closeJob(jobId);
        } catch {
            reverts++;
        }
    }

    // --- time ---

    /// @dev Bounded below the delivery window on purpose. Rolling further than
    ///      WINDOW in one step expires every open job before `deliver` can be
    ///      selected, so the happy path never executes and the run silently
    ///      only ever tests timeouts. Two rolls still expire a job, so the
    ///      slash path stays well covered.
    function roll(uint256 blocks) external {
        vm.roll(block.number + bound(blocks, 1, 8));
    }

    // --- hostile actions that must always fail ---

    /// @dev Invariant 1: only WorkEscrow may mint.
    function tryRogueMint(uint256 actorSeed, uint256 amount) external {
        address who = _actor(actorSeed);
        vm.prank(who);
        try joule.mint(who, amount) {
            revert("a non-escrow address minted Joules");
        } catch {
            reverts++;
        }
    }

    /// @dev Invariant 3: a redeemed Joule is in escrow custody and immovable.
    function tryMoveCustodiedJoule(uint256 actorSeed) external {
        if (openJobIds.length == 0) return;
        address who = _actor(actorSeed);

        vm.prank(who);
        try joule.transferFrom(address(escrow), who, ONE) {
            revert("a custodied Joule was moved out of the escrow");
        } catch {
            reverts++;
        }
    }

    // --- internal ---

    function _toSubmitted(uint256 jobId) internal {
        _closeJob(jobId);
        _indexOfSubmitted[jobId] = submittedJobIds.length;
        submittedJobIds.push(jobId);
    }

    function _toDisputed(uint256 jobId) internal {
        _closeSubmitted(jobId);
        _indexOfDisputed[jobId] = disputedJobIds.length;
        disputedJobIds.push(jobId);
    }

    function _closeSubmitted(uint256 jobId) internal {
        uint256 idx = _indexOfSubmitted[jobId];
        uint256 last = submittedJobIds.length - 1;
        if (idx != last) {
            uint256 moved = submittedJobIds[last];
            submittedJobIds[idx] = moved;
            _indexOfSubmitted[moved] = idx;
        }
        submittedJobIds.pop();
        delete _indexOfSubmitted[jobId];
    }

    function _closeDisputed(uint256 jobId) internal {
        uint256 idx = _indexOfDisputed[jobId];
        uint256 last = disputedJobIds.length - 1;
        if (idx != last) {
            uint256 moved = disputedJobIds[last];
            disputedJobIds[idx] = moved;
            _indexOfDisputed[moved] = idx;
        }
        disputedJobIds.pop();
        delete _indexOfDisputed[jobId];
    }

    function _closeJob(uint256 jobId) internal {
        uint256 idx = _indexOfJob[jobId];
        uint256 last = openJobIds.length - 1;
        if (idx != last) {
            uint256 moved = openJobIds[last];
            openJobIds[idx] = moved;
            _indexOfJob[moved] = idx;
        }
        openJobIds.pop();
        delete _indexOfJob[jobId];
    }
}
