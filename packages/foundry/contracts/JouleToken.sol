// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title JouleToken
 * @notice One Joule is a collateral-backed claim on one unit of an agent's work.
 *
 * @dev The token is deliberately dumb. It holds no collateral, knows no prices
 *      and enforces no policy -- all of that lives in WorkEscrow. What it does
 *      guarantee is supply integrity, via two constraints:
 *
 *      1. `escrow` is set to `msg.sender` at construction and is immutable.
 *         WorkEscrow deploys this contract from its own constructor, so the
 *         minter is fixed to the escrow by construction rather than by a
 *         setter someone could later be tricked into calling. There is no
 *         ownership transfer and no upgrade path.
 *
 *      2. `burn` destroys only the escrow's OWN balance. It cannot reach into
 *         an arbitrary holder's balance even when called by the escrow. Since
 *         redemption works by moving a Joule into escrow custody, this means a
 *         Joule can only be destroyed after it has actually been redeemed --
 *         the token itself enforces that, so an escrow bug cannot silently
 *         burn a bystander's holdings.
 *
 *      Locked Joules need no transfer hook. A redeemed Joule is held by the
 *      escrow, and a token the escrow holds cannot be moved by anyone else.
 *      Custody is the lock.
 *
 *      Eighteen decimals, the ERC-20 default, because this token has to sit in
 *      a Uniswap pool and be priced by ordinary tooling. Fractional balances
 *      are therefore possible but not redeemable: redemption burns exactly
 *      `ONE`, so a holder needs a whole Joule to claim a whole job.
 */
contract JouleToken is ERC20 {
    /// @notice The only address permitted to mint or burn. Fixed at construction.
    address public immutable escrow;

    /// @notice One whole Joule -- one unit of work.
    uint256 public constant ONE = 1e18;

    error OnlyEscrow(address caller);

    modifier onlyEscrow() {
        if (msg.sender != escrow) revert OnlyEscrow(msg.sender);
        _;
    }

    /// @dev Deployed by WorkEscrow, which thereby becomes the permanent minter.
    constructor() ERC20("Joule", "JOULE") {
        escrow = msg.sender;
    }

    /// @notice Mint newly issued Joules. Coverage is enforced by the escrow.
    function mint(address to, uint256 amount) external onlyEscrow {
        _mint(to, amount);
    }

    /// @notice Destroy Joules the escrow itself holds -- i.e. ones already redeemed.
    /// @dev Burns from `msg.sender`, never from an arbitrary address. See contract notes.
    function burn(uint256 amount) external onlyEscrow {
        _burn(msg.sender, amount);
    }
}
