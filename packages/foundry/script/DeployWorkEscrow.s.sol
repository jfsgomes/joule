// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./DeployHelpers.s.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MockUSDC } from "../contracts/MockUSDC.sol";
import { SumVerifier } from "../contracts/verifiers/SumVerifier.sol";
import { WorkEscrow } from "../contracts/WorkEscrow.sol";
import { JouleToken } from "../contracts/JouleToken.sol";

/**
 * @notice Deploys the Joule contract set.
 *
 * @dev Three transactions, not four: WorkEscrow deploys JouleToken from its own
 *      constructor, which is what fixes the token's minter to the escrow and
 *      makes "only WorkEscrow can mint" true by construction rather than by a
 *      setter someone could later be talked into calling.
 *
 *      Parameters come from docs/MECHANISM.md. The pairing that matters:
 *      coverageRatio >= (faceValue + penalty) / faceValue, which at
 *      penalty == faceValue means exactly 2x. The constructor enforces it, so a
 *      bad combination fails here rather than silently shipping an escrow that
 *      can be drained before its last Joule settles.
 *
 *      yarn deploy --file DeployWorkEscrow.s.sol
 *      yarn deploy --file DeployWorkEscrow.s.sol --network sepolia --keystore ethgloballisbon2026
 */
contract DeployWorkEscrow is ScaffoldETHDeploy {
    // --- demo parameters, all in USDC base units (6 decimals) ---

    /// @notice Agent's declared liability per Joule. NOT a price -- see MECHANISM.md.
    uint256 constant FACE_VALUE = 5e6; // 5 USDC

    /// @notice Paid to the redeemer on default, and the cost of disputing.
    uint256 constant PENALTY = 5e6; // 5 USDC

    /// @notice Collateral multiple per outstanding Joule. Tight at penalty == faceValue.
    uint256 constant COVERAGE_RATIO = 2;

    /// @notice Delivery window. Blocks, not seconds, so the demo is countable.
    uint256 constant DELIVERY_BLOCKS = 10; // ~2 min on Sepolia

    /// @notice How long a redeemer has to accept or dispute an unverified result.
    uint256 constant ACCEPT_BLOCKS = 5; // ~1 min on Sepolia

    function run() external ScaffoldEthDeployerRunner {
        address arbiter = _resolveArbiter();

        MockUSDC usdc = new MockUSDC();
        SumVerifier verifier = new SumVerifier();

        WorkEscrow escrow = new WorkEscrow(
            IERC20(address(usdc)),
            verifier,
            deployer, // the agent
            arbiter,
            FACE_VALUE,
            PENALTY,
            COVERAGE_RATIO,
            DELIVERY_BLOCKS,
            ACCEPT_BLOCKS
        );

        JouleToken joule = escrow.joule();

        _assertPoolTokenOrdering(address(joule), address(usdc));
        _report(address(usdc), address(verifier), address(escrow), address(joule), arbiter);
    }

    /**
     * @dev The arbiter must not be the agent: it rules on disputes about the
     *      agent's work, and the agent is the party being slashed. Falling back
     *      to the deployer keeps local runs frictionless, but it collapses that
     *      separation, so say so rather than let it pass unnoticed.
     */
    function _resolveArbiter() internal view returns (address arbiter) {
        arbiter = vm.envOr("ARBITER_ADDRESS", address(0));

        if (arbiter == address(0)) {
            console.logString("WARNING: ARBITER_ADDRESS unset, falling back to the deployer.");
            console.logString("         The agent will be able to rule on disputes about itself.");
            console.logString("         Generate one: cast wallet new ~/.foundry/keystores joule-arbiter");
            return deployer;
        }

        if (arbiter == deployer) {
            console.logString("WARNING: ARBITER_ADDRESS equals the deployer, so the agent arbitrates");
            console.logString("         its own disputes. Acceptable for a local run, not for a demo.");
        }
    }

    /**
     * @dev Uniswap sorts pool tokens by address, so which of JOULE/USDC is
     *      token0 is decided by deployment order and nothing else. That flips
     *      which tick direction means "above spot".
     *
     *      It matters because the single-sided seeding strategy in MECHANISM.md
     *      places a JOULE-only range above spot as a sell wall. Get the ordering
     *      backwards and the same range is a BUY wall below spot, which fills
     *      instantly against the agent at their own expense.
     *
     *      This does not revert -- ordering is not wrong, only surprising -- but
     *      it prints which case we are in so the pool script is written against
     *      an observed fact rather than an assumption.
     */
    function _assertPoolTokenOrdering(address joule, address usdc) internal pure {
        if (joule < usdc) {
            console.logString("Pool ordering: JOULE is token0, USDC is token1.");
            console.logString("  price = USDC per JOULE; a sell wall sits ABOVE spot (higher ticks).");
        } else {
            console.logString("Pool ordering: USDC is token0, JOULE is token1.");
            console.logString("  price is INVERTED (JOULE per USDC); a JOULE sell wall sits at LOWER ticks.");
            console.logString("  Do not copy tick maths that assumes JOULE is token0.");
        }
    }

    function _report(address usdc, address verifier, address escrow, address joule, address arbiter) internal view {
        console.logString("");
        console.logString("--- Joule deployment ---");
        console.logString(string.concat("MockUSDC     ", vm.toString(usdc)));
        console.logString(string.concat("SumVerifier  ", vm.toString(verifier)));
        console.logString(string.concat("WorkEscrow   ", vm.toString(escrow)));
        console.logString(string.concat("JouleToken   ", vm.toString(joule), "  (deployed by the escrow)"));
        console.logString(string.concat("agent        ", vm.toString(deployer)));
        console.logString(string.concat("arbiter      ", vm.toString(arbiter)));
        console.logString("");
        console.logString(
            string.concat(
                "faceValue ", vm.toString(FACE_VALUE / 1e6), " USDC, penalty ", vm.toString(PENALTY / 1e6), " USDC"
            )
        );
        console.logString(
            string.concat(
                "coverage ",
                vm.toString(COVERAGE_RATIO),
                "x, delivery ",
                vm.toString(DELIVERY_BLOCKS),
                " blocks, accept ",
                vm.toString(ACCEPT_BLOCKS),
                " blocks"
            )
        );
    }
}
