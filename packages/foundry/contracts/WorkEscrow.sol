// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { JouleToken } from "./JouleToken.sol";
import { IVerifier } from "./verifiers/IVerifier.sol";

/**
 * @title WorkEscrow
 * @notice Collateral, issuance limits, redemption and slashing for one agent.
 *
 * @dev Flow of funds, invariants and known limits: docs/MECHANISM.md.
 *
 *      The escrow never handles a sale. The agent mints Joules to themselves
 *      and sells them into a Uniswap pool, so sale proceeds never arrive here
 *      and cannot be held. The collateral is the entire guarantee -- which is
 *      why `issue` takes no price.
 *
 *      Two parameters do two different jobs, and conflating them breaks things:
 *        - coverageRatio is SOLVENCY: can every possible default be paid?
 *        - penalty is INCENTIVE: does the agent prefer delivering?
 *      Solvency requires coverageRatio >= (faceValue + penalty) / faceValue.
 *      The constructor enforces that rather than trusting the deployer.
 *
 *      SETTLEMENT HAS TWO PATHS, and which one a job takes is decided by the
 *      verifier, not by anyone's opinion:
 *
 *      1. VERIFIED -- `verify` returns true, the job settles inside
 *         `submitWork`. No window, no counterparty, no delay. Objectively
 *         checkable work never waits on a human.
 *
 *      2. OPTIMISTIC -- `verify` cannot confirm the result. The job enters an
 *         acceptance window. The redeemer may `accept` early, `dispute` it, or
 *         do nothing, in which case anyone may `finalize` once the window
 *         closes. This is what lets the escrow take work no onchain function
 *         can adjudicate.
 *
 *      The dispute half is not optional garnish. Auto-accept on its own would
 *      let an agent escape the penalty on every unverifiable job by submitting
 *      one garbage byte and waiting -- the slash would become unreachable for
 *      precisely the jobs the optimistic path exists to support. And a bare
 *      right of refusal is no better: an unbonded redeemer would reject
 *      everything and collect `faceValue + penalty` for free. A bond makes
 *      challenging cost something; an arbiter decides who was right.
 *
 *      THE ARBITER IS A TRUST ASSUMPTION. It is a single immutable address
 *      that can rule on any disputed job. It cannot touch collateral outside a
 *      dispute, cannot mint, and cannot be changed -- but within a dispute its
 *      word is final. Decentralising it (Kleros, UMA, a committee) is out of
 *      scope here and recorded in docs/MECHANISM.md.
 */
contract WorkEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- immutable configuration ---

    /// @notice Collateral token. Six decimals if it is USDC -- all sums below are in its base units.
    IERC20 public immutable collateralToken;

    /// @notice The claim token. Deployed here, so this escrow is its permanent minter.
    JouleToken public immutable joule;

    /// @notice Objective adjudicator for delivered work.
    IVerifier public immutable verifier;

    /// @notice The single agent this escrow serves.
    address public immutable agent;

    /// @notice Rules on disputed jobs. A trust assumption -- see contract notes.
    address public immutable arbiter;

    /// @notice Declared liability per Joule: the guaranteed refund on default. Not a price.
    uint256 public immutable faceValue;

    /// @notice Paid to the redeemer on default, on top of faceValue. Also the dispute bond.
    uint256 public immutable penalty;

    /// @notice Collateral multiple backing each outstanding Joule.
    uint256 public immutable coverageRatio;

    /// @notice Delivery window, in blocks so the demo is countable.
    uint256 public immutable deliveryBlocks;

    /// @notice How long a redeemer has to accept or dispute an unverified result.
    uint256 public immutable acceptBlocks;

    // --- state ---

    /// @notice USDC held as collateral. Excludes dispute bonds.
    uint256 public collateral;

    /// @notice USDC held as dispute bonds. Not collateral -- it is not the agent's.
    uint256 public disputeBonds;

    /// @notice Whole Joules minted and not yet burned.
    uint256 public outstanding;

    enum Status {
        None,
        /// @dev Redeemed, awaiting delivery.
        Open,
        /// @dev Delivered but unverified, inside the acceptance window.
        Submitted,
        /// @dev Challenged by the redeemer, awaiting the arbiter.
        Disputed,
        /// @dev Closed in the agent's favour.
        Settled,
        /// @dev Closed against the agent; the redeemer was paid.
        Slashed
    }

    struct Job {
        address redeemer;
        uint64 deliveryDeadline;
        uint64 acceptDeadline;
        Status status;
    }

    mapping(uint256 jobId => Job) public jobs;
    mapping(uint256 jobId => bytes spec) public jobSpecs;
    /// @notice Hash of the submitted result, for a job that took the optimistic path.
    mapping(uint256 jobId => bytes32) public resultHashes;

    uint256 public nextJobId = 1;

    // --- events ---

    event Staked(uint256 amount, uint256 collateral);
    event Unstaked(uint256 amount, uint256 collateral);
    event Issued(uint256 count, uint256 outstanding);
    event Redeemed(uint256 indexed jobId, address indexed redeemer, bytes jobSpec, uint256 deliveryDeadline);
    /// @dev `verified` distinguishes the two settlement paths at a glance.
    event WorkSubmitted(uint256 indexed jobId, bytes result, bool verified, uint256 acceptDeadline);
    event JobSettled(uint256 indexed jobId, Status finalStatus);
    event JobSlashed(uint256 indexed jobId, address indexed redeemer, uint256 paid);
    event JobDisputed(uint256 indexed jobId, address indexed redeemer, uint256 bond);
    event DisputeResolved(uint256 indexed jobId, bool upheld);
    /// @dev Should be unreachable while the coverage invariant holds. Emitted rather
    ///      than reverted so a shortfall can never block a redeemer's claim.
    event Shortfall(uint256 indexed jobId, uint256 owed, uint256 paid);

    // --- errors ---

    error OnlyAgent(address caller);
    error OnlyArbiter(address caller);
    error OnlyRedeemer(address caller);
    error InsufficientCoverage(uint256 available, uint256 required);
    error InvalidJobSpec();
    error JobNotOpen(uint256 jobId);
    error JobNotSubmitted(uint256 jobId);
    error JobNotDisputed(uint256 jobId);
    error DeadlinePassed(uint256 jobId);
    error DeadlineNotReached(uint256 jobId);
    error ZeroCount();
    error UnsafeParameters(uint256 coverageRatio, uint256 required);

    modifier onlyAgent() {
        if (msg.sender != agent) revert OnlyAgent(msg.sender);
        _;
    }

    constructor(
        IERC20 collateralToken_,
        IVerifier verifier_,
        address agent_,
        address arbiter_,
        uint256 faceValue_,
        uint256 penalty_,
        uint256 coverageRatio_,
        uint256 deliveryBlocks_,
        uint256 acceptBlocks_
    ) {
        // Solvency, checked at construction rather than assumed. Burning one
        // Joule frees coverageRatio * faceValue of requirement; one default
        // costs faceValue + penalty. If the former is smaller, the collateral
        // can be drained before the last Joule settles.
        uint256 requiredRatio = (faceValue_ + penalty_ + faceValue_ - 1) / faceValue_; // ceil
        if (coverageRatio_ < requiredRatio) revert UnsafeParameters(coverageRatio_, requiredRatio);

        collateralToken = collateralToken_;
        verifier = verifier_;
        agent = agent_;
        arbiter = arbiter_;
        faceValue = faceValue_;
        penalty = penalty_;
        coverageRatio = coverageRatio_;
        deliveryBlocks = deliveryBlocks_;
        acceptBlocks = acceptBlocks_;

        // Deployed here so JouleToken's immutable `escrow` is this contract.
        joule = new JouleToken();
    }

    // --- views ---

    /// @notice Collateral that must remain to back `count` outstanding Joules.
    function requiredCollateral(uint256 count) public view returns (uint256) {
        return coverageRatio * faceValue * count;
    }

    /// @notice Collateral the agent could withdraw right now.
    function freeCollateral() public view returns (uint256) {
        uint256 required = requiredCollateral(outstanding);
        return collateral > required ? collateral - required : 0;
    }

    /// @notice How many more Joules the current collateral could back.
    function issuanceHeadroom() external view returns (uint256) {
        return freeCollateral() / (coverageRatio * faceValue);
    }

    // --- agent: collateral ---

    function stake(uint256 amount) external onlyAgent nonReentrant {
        collateral += amount;
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(amount, collateral);
    }

    function unstake(uint256 amount) external onlyAgent nonReentrant {
        uint256 free = freeCollateral();
        if (amount > free) revert InsufficientCoverage(free, amount);

        collateral -= amount;
        collateralToken.safeTransfer(msg.sender, amount);
        emit Unstaked(amount, collateral);
    }

    // --- agent: issuance ---

    /// @notice Mint `count` whole Joules to the agent, if collateral covers them.
    /// @dev No price argument by design: selling happens in the pool, not here.
    function issue(uint256 count) external onlyAgent nonReentrant {
        if (count == 0) revert ZeroCount();

        uint256 newOutstanding = outstanding + count;
        uint256 required = requiredCollateral(newOutstanding);
        if (collateral < required) revert InsufficientCoverage(collateral, required);

        outstanding = newOutstanding;
        joule.mint(agent, count * joule.ONE());
        emit Issued(count, newOutstanding);
    }

    // --- holder: redemption ---

    /// @notice Lock one Joule and open a job. Starts the delivery clock.
    /// @dev The Joule moves into this contract's custody -- that IS the lock, so
    ///      no transfer hook on the token is needed.
    ///
    ///      `isValidSpec` is checked here, before any clock starts. Without it a
    ///      holder could redeem with a spec the verifier cannot even parse,
    ///      making delivery impossible and the resulting slash automatic.
    ///      Note this is about *parseability*, not decidability: a verifier may
    ///      accept a spec it can parse but will never be able to confirm, and
    ///      such a job simply takes the optimistic path.
    function redeem(bytes calldata jobSpec) external nonReentrant returns (uint256 jobId) {
        if (!verifier.isValidSpec(jobSpec)) revert InvalidJobSpec();

        jobId = nextJobId++;
        // casting to 'uint64' is safe because block numbers are ~9 orders of
        // magnitude below uint64 max and deliveryBlocks is a small constant.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 deadline = uint64(block.number + deliveryBlocks);

        jobs[jobId] =
            Job({ redeemer: msg.sender, deliveryDeadline: deadline, acceptDeadline: 0, status: Status.Open });
        jobSpecs[jobId] = jobSpec;

        IERC20(address(joule)).safeTransferFrom(msg.sender, address(this), joule.ONE());

        emit Redeemed(jobId, msg.sender, jobSpec, deadline);
    }

    // --- agent: delivery ---

    /// @notice Submit a result before the delivery deadline.
    /// @dev Settles immediately if the verifier confirms it. Otherwise the job
    ///      enters the acceptance window -- see the two settlement paths in the
    ///      contract notes. Submitting stops the timeout clock either way,
    ///      which is why `dispute` has to exist: without it, submitting
    ///      anything at all would be enough to escape the penalty.
    function submitWork(uint256 jobId, bytes calldata result) external onlyAgent nonReentrant {
        Job storage job = jobs[jobId];
        if (job.status != Status.Open) revert JobNotOpen(jobId);
        if (block.number > job.deliveryDeadline) revert DeadlinePassed(jobId);

        if (_verify(jobSpecs[jobId], result)) {
            _settle(jobId, job);
            emit WorkSubmitted(jobId, result, true, 0);
            return;
        }

        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 acceptDeadline = uint64(block.number + acceptBlocks);
        job.status = Status.Submitted;
        job.acceptDeadline = acceptDeadline;
        resultHashes[jobId] = keccak256(result);

        emit WorkSubmitted(jobId, result, false, acceptDeadline);
    }

    // --- optimistic path ---

    /// @notice Redeemer settles an unverified result early, without waiting.
    function accept(uint256 jobId) external nonReentrant {
        Job storage job = jobs[jobId];
        if (job.status != Status.Submitted) revert JobNotSubmitted(jobId);
        if (msg.sender != job.redeemer) revert OnlyRedeemer(msg.sender);

        _settle(jobId, job);
    }

    /// @notice Settle an unchallenged result once its window has closed.
    /// @dev Permissionless: an unfinalised job would otherwise pin the agent's
    ///      collateral forever if the redeemer simply walked away.
    function finalize(uint256 jobId) external nonReentrant {
        Job storage job = jobs[jobId];
        if (job.status != Status.Submitted) revert JobNotSubmitted(jobId);
        if (block.number <= job.acceptDeadline) revert DeadlineNotReached(jobId);

        _settle(jobId, job);
    }

    /// @notice Challenge an unverified result. Costs a bond equal to `penalty`.
    /// @dev The bond is what stops a redeemer rejecting everything to harvest
    ///      `faceValue + penalty`. It is returned if the arbiter agrees with
    ///      them, and forfeited to the agent's collateral if it does not.
    function dispute(uint256 jobId) external nonReentrant {
        Job storage job = jobs[jobId];
        if (job.status != Status.Submitted) revert JobNotSubmitted(jobId);
        if (msg.sender != job.redeemer) revert OnlyRedeemer(msg.sender);
        if (block.number > job.acceptDeadline) revert DeadlinePassed(jobId);

        job.status = Status.Disputed;
        disputeBonds += penalty;

        collateralToken.safeTransferFrom(msg.sender, address(this), penalty);
        emit JobDisputed(jobId, msg.sender, penalty);
    }

    /// @notice Arbiter rules on a disputed job.
    /// @param upheld True if the redeemer was right and the work was inadequate.
    function resolveDispute(uint256 jobId, bool upheld) external nonReentrant {
        if (msg.sender != arbiter) revert OnlyArbiter(msg.sender);

        Job storage job = jobs[jobId];
        if (job.status != Status.Disputed) revert JobNotDisputed(jobId);

        disputeBonds -= penalty;
        emit DisputeResolved(jobId, upheld);

        if (upheld) {
            // Redeemer was right: refund their bond and slash as if undelivered.
            collateralToken.safeTransfer(job.redeemer, penalty);
            _slash(jobId, job);
        } else {
            // Redeemer was wrong: the bond becomes the agent's collateral.
            collateral += penalty;
            _settle(jobId, job);
        }
    }

    // --- anyone: default ---

    /// @notice After the delivery deadline with nothing submitted: burn the
    ///         Joule and pay the redeemer `faceValue + penalty` out of collateral.
    /// @dev Only reachable from `Open`. Once the agent has submitted anything the
    ///      job is on the acceptance track, and the redeemer's remedy is
    ///      `dispute`, not a timeout.
    ///
    ///      Callable by anyone, but pays only the recorded redeemer. That keeps
    ///      the slash permissionless without making it a way to redirect funds.
    function claimTimeout(uint256 jobId) external nonReentrant {
        Job storage job = jobs[jobId];
        if (job.status != Status.Open) revert JobNotOpen(jobId);
        if (block.number <= job.deliveryDeadline) revert DeadlineNotReached(jobId);

        _slash(jobId, job);
    }

    // --- internal ---

    /// @dev Close a job in the agent's favour: burn the Joule, release coverage.
    function _settle(uint256 jobId, Job storage job) internal {
        job.status = Status.Settled;
        outstanding -= 1;
        joule.burn(joule.ONE());
        emit JobSettled(jobId, Status.Settled);
    }

    /// @dev Close a job against the agent: burn the Joule, pay the redeemer out
    ///      of collateral.
    ///
    ///      `paid` is capped rather than asserted, and the cap is unreachable:
    ///      both callers require an unsettled job, so `outstanding >= 1`, so
    ///      `collateral >= coverageRatio * faceValue >= faceValue + penalty`.
    ///
    ///      Capping is deliberate anyway. Reverting here would be the worst
    ///      available failure: this is the redeemer's only remedy, and a revert
    ///      would leave them holding a claim they cannot collect while locking
    ///      every other redeemer out of the same path. Paying what is present
    ///      and emitting `Shortfall` degrades instead of bricking.
    ///
    ///      Note the cap guards the LEDGER, not the balance. If `collateral`
    ///      ever exceeded the escrow's real holdings -- which a fee-on-transfer
    ///      or rebasing collateral token would cause -- the `safeTransfer`
    ///      below still reverts. That is the realistic failure and it is
    ///      tracked separately as C-4, not covered by this cap.
    function _slash(uint256 jobId, Job storage job) internal {
        job.status = Status.Slashed;
        outstanding -= 1;
        joule.burn(joule.ONE());

        uint256 owed = faceValue + penalty;
        uint256 paid = owed > collateral ? collateral : owed;
        if (paid < owed) emit Shortfall(jobId, owed, paid);

        collateral -= paid;
        address redeemer = job.redeemer;

        collateralToken.safeTransfer(redeemer, paid);
        emit JobSlashed(jobId, redeemer, paid);
    }

    /// @dev IVerifier requires implementations not to revert. This wraps the call
    ///      anyway: a third-party verifier that breaks that contract should send
    ///      the job down the optimistic path rather than bubble an opaque revert
    ///      into submitWork and strand the agent.
    function _verify(bytes memory jobSpec, bytes calldata result) internal view returns (bool) {
        try verifier.verify(jobSpec, result) returns (bool ok) {
            return ok;
        } catch {
            return false;
        }
    }
}
