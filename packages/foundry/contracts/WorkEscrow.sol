// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { JouleToken } from "./JouleToken.sol";
import { IVerifier } from "./verifiers/IVerifier.sol";

/**
 * @title WorkEscrow
 * @notice Collateral, issuance limits, redemption and timeout slashing for one agent.
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

    /// @notice Declared liability per Joule: the guaranteed refund on default. Not a price.
    uint256 public immutable faceValue;

    /// @notice Paid to the redeemer on default, on top of faceValue.
    uint256 public immutable penalty;

    /// @notice Collateral multiple backing each outstanding Joule.
    uint256 public immutable coverageRatio;

    /// @notice Delivery window, in blocks so the demo is countable.
    uint256 public immutable deliveryBlocks;

    // --- state ---

    /// @notice USDC held as collateral.
    uint256 public collateral;

    /// @notice Whole Joules minted and not yet burned.
    uint256 public outstanding;

    enum Status {
        None,
        Open,
        Delivered,
        TimedOut
    }

    struct Job {
        address redeemer;
        uint64 deadlineBlock;
        Status status;
    }

    mapping(uint256 jobId => Job) public jobs;
    mapping(uint256 jobId => bytes spec) public jobSpecs;

    uint256 public nextJobId = 1;

    // --- events ---

    event Staked(uint256 amount, uint256 collateral);
    event Unstaked(uint256 amount, uint256 collateral);
    event Issued(uint256 count, uint256 outstanding);
    event Redeemed(uint256 indexed jobId, address indexed redeemer, bytes jobSpec, uint256 deadlineBlock);
    event Delivered(uint256 indexed jobId, bytes result);
    event TimedOut(uint256 indexed jobId, address indexed redeemer, uint256 paid);
    /// @dev Should be unreachable while the coverage invariant holds. Emitted rather
    ///      than reverted so a shortfall can never block a redeemer's claim.
    event Shortfall(uint256 indexed jobId, uint256 owed, uint256 paid);

    // --- errors ---

    error OnlyAgent(address caller);
    error InsufficientCoverage(uint256 available, uint256 required);
    error InvalidJobSpec();
    error JobNotOpen(uint256 jobId);
    error DeadlinePassed(uint256 jobId);
    error DeadlineNotReached(uint256 jobId);
    error VerificationFailed(uint256 jobId);
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
        uint256 faceValue_,
        uint256 penalty_,
        uint256 coverageRatio_,
        uint256 deliveryBlocks_
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
        faceValue = faceValue_;
        penalty = penalty_;
        coverageRatio = coverageRatio_;
        deliveryBlocks = deliveryBlocks_;

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
    ///      holder could redeem with a spec the verifier cannot adjudicate,
    ///      making delivery impossible and the resulting slash automatic.
    function redeem(bytes calldata jobSpec) external nonReentrant returns (uint256 jobId) {
        if (!verifier.isValidSpec(jobSpec)) revert InvalidJobSpec();

        jobId = nextJobId++;
        // casting to 'uint64' is safe because block numbers are ~9 orders of
        // magnitude below uint64 max and deliveryBlocks is a small constant.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 deadline = uint64(block.number + deliveryBlocks);

        jobs[jobId] = Job({ redeemer: msg.sender, deadlineBlock: deadline, status: Status.Open });
        jobSpecs[jobId] = jobSpec;

        IERC20(address(joule)).safeTransferFrom(msg.sender, address(this), joule.ONE());

        emit Redeemed(jobId, msg.sender, jobSpec, deadline);
    }

    // --- agent: delivery ---

    /// @notice Submit a result. Settles immediately if the verifier accepts.
    /// @dev There is no separate `accept` step. Every job type this escrow takes
    ///      is objectively adjudicable -- that is enforced at redeem() -- so a
    ///      human acceptance gate would add a way to stall, not a safeguard.
    function submitWork(uint256 jobId, bytes calldata result) external onlyAgent nonReentrant {
        Job storage job = jobs[jobId];
        if (job.status != Status.Open) revert JobNotOpen(jobId);
        if (block.number > job.deadlineBlock) revert DeadlinePassed(jobId);

        if (!_verify(jobSpecs[jobId], result)) revert VerificationFailed(jobId);

        job.status = Status.Delivered;
        outstanding -= 1;
        joule.burn(joule.ONE());

        emit Delivered(jobId, result);
    }

    // --- anyone: default ---

    /// @notice After the deadline with nothing delivered: burn the Joule and pay
    ///         the redeemer `faceValue + penalty` out of collateral.
    /// @dev Callable by anyone, but pays only the recorded redeemer. That keeps
    ///      the slash permissionless without making it a way to redirect funds.
    function claimTimeout(uint256 jobId) external nonReentrant {
        Job storage job = jobs[jobId];
        if (job.status != Status.Open) revert JobNotOpen(jobId);
        if (block.number <= job.deadlineBlock) revert DeadlineNotReached(jobId);

        job.status = Status.TimedOut;
        outstanding -= 1;
        joule.burn(joule.ONE());

        uint256 owed = faceValue + penalty;
        uint256 paid = owed > collateral ? collateral : owed;
        if (paid < owed) emit Shortfall(jobId, owed, paid);

        collateral -= paid;
        address redeemer = job.redeemer;

        collateralToken.safeTransfer(redeemer, paid);
        emit TimedOut(jobId, redeemer, paid);
    }

    // --- internal ---

    /// @dev IVerifier requires implementations not to revert. This wraps the call
    ///      anyway: a third-party verifier that breaks that contract should fail
    ///      the job cleanly rather than bubble an opaque revert into submitWork.
    function _verify(bytes memory jobSpec, bytes calldata result) internal view returns (bool) {
        try verifier.verify(jobSpec, result) returns (bool ok) {
            return ok;
        } catch {
            return false;
        }
    }
}
