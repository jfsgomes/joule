// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IVerifier
 * @notice Objective, onchain adjudication of whether delivered work satisfies a job spec.
 *
 * @dev Two functions rather than one, for a reason worth understanding.
 *
 *      A holder chooses the job spec when they redeem, and the spec is
 *      arbitrary bytes. If the escrow only ever called `verify` at submission
 *      time, a holder could redeem with a spec the verifier chokes on: the
 *      agent then cannot produce anything that verifies, the delivery window
 *      lapses, and the holder collects `faceValue + penalty`. Buy a Joule for
 *      5, poison the spec, collect 10. A profitable, repeatable slash.
 *
 *      `isValidSpec` closes that. The escrow checks it during `redeem` and
 *      refuses to open a job the verifier cannot adjudicate, so a spec that
 *      would strand the agent is rejected before any clock starts.
 *
 *      Implementations MUST NOT revert in either function. Return false
 *      instead. A reverting verifier reintroduces exactly the griefing vector
 *      above, since a revert during submission is indistinguishable from an
 *      agent who never showed up. Decode defensively: check calldata lengths
 *      before `abi.decode`, and bound values so arithmetic cannot overflow.
 */
interface IVerifier {
    /// @notice Whether `jobSpec` is one this verifier can adjudicate.
    /// @dev Checked by the escrow at redemption. Must not revert.
    function isValidSpec(bytes calldata jobSpec) external view returns (bool);

    /// @notice Whether `result` satisfies `jobSpec`.
    /// @dev Checked by the escrow at submission. Must not revert.
    function verify(bytes calldata jobSpec, bytes calldata result) external view returns (bool);
}
