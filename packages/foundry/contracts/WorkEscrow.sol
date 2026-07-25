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
 *      SOLVENCY. Every unsettled job can cost `faceValue + penalty`, and
 *      settling one frees `collateralPerJoule`. The constructor requires
 *      `collateralPerJoule >= faceValue + penalty`, which makes those two
 *      exactly balance at the minimum. That is the whole solvency argument, and
 *      storing an absolute amount rather than an integer multiple keeps it free
 *      of rounding: an integer ratio cannot express 1.2x, so it would silently
 *      round a 6-unit liability up to a 10-unit lock.
 *
 *      SETTLEMENT HAS TWO PATHS, chosen by the verifier, not by opinion:
 *
 *      1. VERIFIED -- `verify` confirms the result and the job settles inside
 *         `submitWork`. No window, no counterparty, no delay.
 *
 *      2. OPTIMISTIC -- `verify` cannot confirm. The job enters an acceptance
 *         window; the redeemer may accept early, dispute it, or do nothing, in
 *         which case anyone may finalize once the window closes.
 *
 *      The dispute half is not optional. Auto-accept alone would let an agent
 *      escape the penalty on every unverifiable job by submitting one garbage
 *      byte and waiting. A bare right of refusal is no better: an unbonded
 *      redeemer would reject everything and collect `faceValue + penalty` for
 *      free. The bond makes challenging cost something; the arbiter decides.
 *
 *      THE ARBITER IS A TRUST ASSUMPTION -- a single immutable address that can
 *      rule on any disputed job. It cannot mint, cannot reach collateral outside
 *      a dispute, and cannot be replaced, but within a dispute its word is
 *      final. Decentralising it is out of scope; see MECHANISM.md.
 *
 *      PAYOUTS ARE PULL, NOT PUSH. Slashes and bond refunds credit `owed` and
 *      the recipient calls `withdraw`. A push transfer would let a collateral
 *      token that can block a recipient -- real USDC has a blocklist -- brick
 *      the job permanently: the claim would revert forever, stranding the Joule
 *      and its backing collateral. Pull payments confine that failure to the
 *      one account affected.
 *
 *      DONATIONS ARE STRANDED. Tokens sent here outside `stake` or `dispute`
 *      are not credited to any ledger and cannot be withdrawn by anyone. This
 *      breaks no invariant -- every ledger is tracked independently of the
 *      balance -- but it is a one-way door, so do not send tokens directly.
 */
contract WorkEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- limits ---

    /**
     * @notice Upper bound on a stored job spec.
     * @dev The escrow must bound its own exposure rather than trusting the
     *      verifier to do it. Only the hash is stored, so this caps the calldata
     *      an agent has to re-supply at submission: without a bound, a redeemer
     *      could make delivery arbitrarily expensive and the resulting slash
     *      automatic. 4 KiB comfortably fits a prompt, a URL or a JSON job spec.
     */
    uint256 public constant MAX_SPEC_BYTES = 4096;

    /// @notice Upper bound on either window. Keeps deadlines inside uint64 and
    ///         rules out an escrow whose jobs can never realistically settle.
    uint256 public constant MAX_WINDOW_BLOCKS = 2_000_000; // ~9 months at 12s

    // --- immutable configuration ---

    /// @notice Collateral token. Six decimals if it is USDC -- all sums are base units.
    IERC20 public immutable collateralToken;

    /// @notice The claim token. Deployed here, so this escrow is its permanent minter.
    JouleToken public immutable joule;

    /// @notice One whole Joule. Cached to avoid an external call per settlement.
    uint256 public immutable ONE;

    /// @notice Objective adjudicator for delivered work.
    IVerifier public immutable verifier;

    /// @notice The single agent this escrow serves.
    address public immutable agent;

    /// @notice Rules on disputed jobs. A trust assumption -- see contract notes.
    address public immutable arbiter;

    /// @notice Agent's declared liability per Joule: the guaranteed refund on default. Not a price.
    uint256 public immutable faceValue;

    /// @notice Paid to the redeemer on default, on top of faceValue. Also the dispute bond.
    uint256 public immutable penalty;

    /// @notice Collateral locked per outstanding Joule. Absolute, not a multiple.
    uint256 public immutable collateralPerJoule;

    /// @notice Delivery window, in blocks so the demo is countable.
    uint256 public immutable deliveryBlocks;

    /// @notice How long a redeemer has to accept or dispute an unverified result.
    uint256 public immutable acceptBlocks;

    // --- state ---

    /// @notice USDC backing outstanding Joules. Excludes bonds and owed payouts.
    uint256 public collateral;

    /// @notice USDC held as dispute bonds. Not the agent's money.
    uint256 public disputeBonds;

    /// @notice USDC credited to recipients and awaiting withdrawal.
    uint256 public totalOwed;

    /// @notice Per-account withdrawable balance. See the pull-payment note above.
    mapping(address => uint256) public owed;

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
        /// @dev Closed against the agent; the redeemer was credited.
        Slashed
    }

    struct Job {
        address redeemer;
        uint64 deliveryDeadline;
        uint64 acceptDeadline;
        Status status;
    }

    mapping(uint256 jobId => Job) public jobs;

    /// @notice keccak256 of the job spec. The spec itself is never stored --
    ///         it is emitted for the agent and re-supplied at submission.
    mapping(uint256 jobId => bytes32) public specHashes;

    /// @notice keccak256 of a submitted-but-unverified result.
    mapping(uint256 jobId => bytes32) public resultHashes;

    uint256 public nextJobId = 1;

    // --- events ---

    event Staked(address indexed agent, uint256 amount, uint256 newCollateral);
    event Unstaked(address indexed agent, uint256 amount, uint256 newCollateral);
    event Issued(address indexed agent, uint256 count, uint256 newOutstanding);
    event Redeemed(uint256 indexed jobId, address indexed redeemer, bytes jobSpec, uint256 deliveryDeadline);
    /// @dev `verified` distinguishes the two settlement paths at a glance.
    event WorkSubmitted(uint256 indexed jobId, bytes result, bool verified, uint256 acceptDeadline);
    event JobSettled(uint256 indexed jobId);
    event JobSlashed(uint256 indexed jobId, address indexed redeemer, uint256 credited);
    event JobDisputed(uint256 indexed jobId, address indexed redeemer, uint256 bond);
    event DisputeResolved(uint256 indexed jobId, bool upheld);
    event Withdrawn(address indexed account, uint256 amount);
    /// @dev A verifier that breaks the IVerifier "must not revert" contract.
    ///      Without this, "the verifier is broken" and "the agent submitted a
    ///      wrong answer" are indistinguishable from outside.
    event VerifierReverted(uint256 indexed jobId);
    /// @dev Unreachable while the coverage invariant holds. Emitted rather than
    ///      reverted so a shortfall can never block a redeemer's claim.
    event Shortfall(uint256 indexed jobId, uint256 owedAmount, uint256 credited);

    // --- errors ---

    error OnlyAgent(address caller);
    error OnlyArbiter(address caller);
    error OnlyRedeemer(address caller);
    error InsufficientCoverage(uint256 available, uint256 required);
    error InvalidJobSpec();
    error SpecTooLarge(uint256 length, uint256 maxLength);
    error SpecMismatch(uint256 jobId);
    error JobNotOpen(uint256 jobId);
    error JobNotSubmitted(uint256 jobId);
    error JobNotDisputed(uint256 jobId);
    error DeadlinePassed(uint256 jobId);
    error DeadlineNotReached(uint256 jobId);
    error ZeroCount();
    error ZeroAddress(string what);
    error InvalidParameter(string what);
    error UnsafeParameters(uint256 perJoule, uint256 required);
    error NothingOwed(address account);

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
        uint256 collateralPerJoule_,
        uint256 deliveryBlocks_,
        uint256 acceptBlocks_
    ) {
        if (address(collateralToken_) == address(0)) revert ZeroAddress("collateralToken");
        if (address(verifier_) == address(0)) revert ZeroAddress("verifier");
        if (agent_ == address(0)) revert ZeroAddress("agent");
        // A zero arbiter would leave every disputed job permanently unresolvable.
        if (arbiter_ == address(0)) revert ZeroAddress("arbiter");

        // faceValue is a divisor in coverageRatioBps and the unit of the whole
        // mechanism; zero would make the escrow meaningless and revert with an
        // opaque Panic rather than a named error.
        if (faceValue_ == 0) revert InvalidParameter("faceValue");

        // Zero blocks makes delivery impossible; an unbounded window overflows
        // the uint64 deadline and would truncate to the current block, turning
        // every Joule into a free faceValue + penalty.
        if (deliveryBlocks_ == 0 || deliveryBlocks_ > MAX_WINDOW_BLOCKS) revert InvalidParameter("deliveryBlocks");
        if (acceptBlocks_ == 0 || acceptBlocks_ > MAX_WINDOW_BLOCKS) revert InvalidParameter("acceptBlocks");

        // The solvency condition, exact and without rounding.
        uint256 required = faceValue_ + penalty_;
        if (collateralPerJoule_ < required) revert UnsafeParameters(collateralPerJoule_, required);

        collateralToken = collateralToken_;
        verifier = verifier_;
        agent = agent_;
        arbiter = arbiter_;
        faceValue = faceValue_;
        penalty = penalty_;
        collateralPerJoule = collateralPerJoule_;
        deliveryBlocks = deliveryBlocks_;
        acceptBlocks = acceptBlocks_;

        // Deployed here so JouleToken's immutable `escrow` is this contract.
        joule = new JouleToken();
        ONE = joule.ONE();
    }

    // --- views ---

    /// @notice Collateral that must remain to back `count` outstanding Joules.
    function requiredCollateral(uint256 count) public view returns (uint256) {
        return collateralPerJoule * count;
    }

    /// @notice Collateral the agent could withdraw right now.
    function freeCollateral() public view returns (uint256) {
        uint256 required = requiredCollateral(outstanding);
        return collateral > required ? collateral - required : 0;
    }

    /// @notice How many more Joules the current collateral could back.
    function issuanceHeadroom() external view returns (uint256) {
        return freeCollateral() / collateralPerJoule;
    }

    /// @notice Coverage as a multiple of face value, in basis points. Display only --
    ///         `collateralPerJoule` is the value the contract actually enforces.
    function coverageRatioBps() external view returns (uint256) {
        return (collateralPerJoule * 10_000) / faceValue;
    }

    // --- agent: collateral ---

    /**
     * @notice Deposit collateral.
     * @dev Credits the balance actually received, not the amount requested. A
     *      fee-on-transfer or rebasing collateral token delivers less than it is
     *      asked for, and crediting the request would let the ledger drift above
     *      real holdings -- surfacing later as a failed payout, on the one path
     *      that must never fail.
     */
    function stake(uint256 amount) external onlyAgent nonReentrant {
        uint256 before = collateralToken.balanceOf(address(this));
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = collateralToken.balanceOf(address(this)) - before;

        collateral += received;
        emit Staked(msg.sender, received, collateral);
    }

    function unstake(uint256 amount) external onlyAgent nonReentrant {
        uint256 free = freeCollateral();
        if (amount > free) revert InsufficientCoverage(free, amount);

        collateral -= amount;
        collateralToken.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount, collateral);
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
        joule.mint(agent, count * ONE);
        emit Issued(agent, count, newOutstanding);
    }

    // --- holder: redemption ---

    /**
     * @notice Lock one Joule and open a job. Starts the delivery clock.
     * @dev The Joule moves into this contract's custody -- that IS the lock, so
     *      no transfer hook on the token is needed.
     *
     *      Only the spec's hash is stored. The spec is emitted in `Redeemed`,
     *      which is where the offchain agent reads it from anyway, and
     *      re-supplied at submission. Storing the bytes would mean an unbounded
     *      SSTORE the redeemer chooses the size of, and an unbounded SLOAD the
     *      agent pays for on every delivery.
     *
     *      `isValidSpec` is checked before any clock starts. Without it a holder
     *      could redeem with a spec the verifier cannot parse, making delivery
     *      impossible and the resulting slash automatic. Note this is about
     *      parseability, not decidability: a spec the verifier can parse but
     *      never confirm simply takes the optimistic path.
     */
    function redeem(bytes calldata jobSpec) external nonReentrant returns (uint256 jobId) {
        if (jobSpec.length > MAX_SPEC_BYTES) revert SpecTooLarge(jobSpec.length, MAX_SPEC_BYTES);
        if (!verifier.isValidSpec(jobSpec)) revert InvalidJobSpec();

        jobId = nextJobId++;
        // Safe: deliveryBlocks is bounded by MAX_WINDOW_BLOCKS in the constructor
        // and block numbers are ~9 orders of magnitude below uint64 max.
        uint64 deadline = uint64(block.number + deliveryBlocks);

        jobs[jobId] = Job({ redeemer: msg.sender, deliveryDeadline: deadline, acceptDeadline: 0, status: Status.Open });
        specHashes[jobId] = keccak256(jobSpec);

        IERC20(address(joule)).safeTransferFrom(msg.sender, address(this), ONE);

        emit Redeemed(jobId, msg.sender, jobSpec, deadline);
    }

    // --- agent: delivery ---

    /**
     * @notice Submit a result before the delivery deadline.
     * @param jobSpec The spec this job was opened with, checked against its hash.
     * @dev Settles immediately if the verifier confirms the result; otherwise the
     *      job enters the acceptance window. Submitting stops the timeout clock
     *      either way, which is why `dispute` has to exist.
     */
    function submitWork(uint256 jobId, bytes calldata jobSpec, bytes calldata result)
        external
        onlyAgent
        nonReentrant
    {
        Job storage job = jobs[jobId];
        if (job.status != Status.Open) revert JobNotOpen(jobId);
        if (block.number > job.deliveryDeadline) revert DeadlinePassed(jobId);
        if (keccak256(jobSpec) != specHashes[jobId]) revert SpecMismatch(jobId);

        (bool ok, bool reverted) = _verify(jobSpec, result);
        if (reverted) emit VerifierReverted(jobId);

        if (ok) {
            _settle(jobId, job);
            emit WorkSubmitted(jobId, result, true, 0);
            return;
        }

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
    ///      `faceValue + penalty`. Refunded if the arbiter agrees with them,
    ///      forfeited into the agent's collateral if it does not.
    function dispute(uint256 jobId) external nonReentrant {
        Job storage job = jobs[jobId];
        if (job.status != Status.Submitted) revert JobNotSubmitted(jobId);
        if (msg.sender != job.redeemer) revert OnlyRedeemer(msg.sender);
        if (block.number > job.acceptDeadline) revert DeadlinePassed(jobId);

        job.status = Status.Disputed;

        uint256 before = collateralToken.balanceOf(address(this));
        collateralToken.safeTransferFrom(msg.sender, address(this), penalty);
        uint256 received = collateralToken.balanceOf(address(this)) - before;
        // A short bond would let a fee-on-transfer token buy a cheap challenge.
        if (received < penalty) revert InvalidParameter("bond");

        disputeBonds += received;
        emit JobDisputed(jobId, msg.sender, received);
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
            _credit(job.redeemer, penalty); // bond back
            _slash(jobId, job);
        } else {
            collateral += penalty; // bond forfeited to the agent
            _settle(jobId, job);
        }
    }

    // --- anyone: default ---

    /// @notice After the delivery deadline with nothing submitted: burn the Joule
    ///         and credit the redeemer `faceValue + penalty` out of collateral.
    /// @dev Only reachable from `Open`. Once the agent has submitted anything the
    ///      job is on the acceptance track and the redeemer's remedy is
    ///      `dispute`, not a timeout.
    ///
    ///      Callable by anyone, but credits only the recorded redeemer. That
    ///      keeps the slash permissionless without making it a way to redirect
    ///      funds.
    function claimTimeout(uint256 jobId) external nonReentrant {
        Job storage job = jobs[jobId];
        if (job.status != Status.Open) revert JobNotOpen(jobId);
        if (block.number <= job.deliveryDeadline) revert DeadlineNotReached(jobId);

        _slash(jobId, job);
    }

    // --- payouts ---

    /// @notice Withdraw everything credited to the caller.
    function withdraw() external nonReentrant returns (uint256 amount) {
        amount = owed[msg.sender];
        if (amount == 0) revert NothingOwed(msg.sender);

        owed[msg.sender] = 0;
        totalOwed -= amount;

        collateralToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    // --- internal ---

    function _credit(address account, uint256 amount) internal {
        owed[account] += amount;
        totalOwed += amount;
    }

    /// @dev Close a job in the agent's favour: burn the Joule, release coverage.
    function _settle(uint256 jobId, Job storage job) internal {
        job.status = Status.Settled;
        outstanding -= 1;
        joule.burn(ONE);
        emit JobSettled(jobId);
    }

    /**
     * @dev Close a job against the agent: burn the Joule, credit the redeemer.
     *
     *      `credited` is capped rather than asserted, and the cap is unreachable:
     *      both callers require an unsettled job, so `outstanding >= 1`, so
     *      `collateral >= collateralPerJoule >= faceValue + penalty`.
     *
     *      Capping is deliberate anyway. Reverting here would be the worst
     *      available failure: this is the redeemer's only remedy, and a revert
     *      would leave them holding a claim they cannot collect while locking
     *      every other redeemer out of the same path.
     */
    function _slash(uint256 jobId, Job storage job) internal {
        job.status = Status.Slashed;
        outstanding -= 1;
        joule.burn(ONE);

        uint256 amount = faceValue + penalty;
        uint256 credited = amount > collateral ? collateral : amount;
        if (credited < amount) emit Shortfall(jobId, amount, credited);

        collateral -= credited;
        _credit(job.redeemer, credited);

        emit JobSlashed(jobId, job.redeemer, credited);
    }

    /**
     * @dev IVerifier requires implementations not to revert. This wraps the call
     *      anyway so a misbehaving verifier sends the job down the optimistic
     *      path rather than stranding the agent -- and reports that it reverted,
     *      so "the verifier is broken" stays distinguishable from "the agent got
     *      it wrong". The verifier is nonetheless a total trust root: see the
     *      Limits section of docs/MECHANISM.md.
     */
    function _verify(bytes calldata jobSpec, bytes calldata result) internal view returns (bool ok, bool reverted) {
        try verifier.verify(jobSpec, result) returns (bool result_) {
            return (result_, false);
        } catch {
            return (false, true);
        }
    }
}
