//SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./DeployHelpers.s.sol";
import { DeployWorkEscrow } from "./DeployWorkEscrow.s.sol";

/**
 * @notice Main deployment script for all contracts
 * @dev Run this when you want to deploy multiple contracts at once
 *
 * Example: yarn deploy # runs this script(without`--file` flag)
 */
contract DeployScript is ScaffoldETHDeploy {
    function run() external {
        // Deploys MockUSDC, SumVerifier and WorkEscrow. JouleToken is not listed
        // because WorkEscrow deploys it from its own constructor -- that is what
        // makes the escrow its permanent and only minter.
        DeployWorkEscrow deployWorkEscrow = new DeployWorkEscrow();
        deployWorkEscrow.run();
    }
}