// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockUSDC
 * @notice Stand-in for USDC on testnets, where real USDC is scarce.
 *
 * @dev SIX DECIMALS. This is not an arbitrary choice and must not be "tidied"
 *      to 18. Real USDC has 6 decimals, and every collateral figure in
 *      WorkEscrow — face value, coverage ratio, penalties — is denominated in
 *      this token. Testing the escrow against an 18-decimal mock would hide the
 *      single most common category of bug in USDC integrations: a quantity that
 *      is off by 10^12 and therefore either trivially small or wildly large.
 *      Keeping the mock faithful means the maths we test is the maths we ship.
 *
 *      Minting is unrestricted. That is intentional for a disposable testnet
 *      token: the demo has to be re-runnable without waiting on a faucet. It
 *      also means this contract must never be deployed anywhere it could be
 *      mistaken for something of value.
 */
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USD Coin", "USDC") { }

    /// @dev Real USDC returns 6 here. So do we.
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Mint test dollars to any address. Unrestricted by design.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
