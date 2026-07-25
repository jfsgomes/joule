// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IVerifier } from "./IVerifier.sol";

/**
 * @title SumVerifier
 * @notice Demo verifier: the job is "add two numbers", the result is the sum.
 *
 * @dev Trivial on purpose. The point of the demo is not that addition is hard,
 *      it is that *some* job types can be adjudicated objectively onchain, and
 *      those settle without any human in the loop. Subjective quality disputes
 *      are explicitly out of scope.
 *
 *      Encoding:
 *        jobSpec = abi.encode(uint256 a, uint256 b)   -- 64 bytes
 *        result  = abi.encode(uint256 sum)            -- 32 bytes
 *
 *      Operands are capped at type(uint128).max. That is what makes `a + b`
 *      unable to overflow a uint256, which in turn is what lets this contract
 *      honour the "must not revert" contract in IVerifier. An unbounded uint256
 *      pair would revert on overflow under 0.8 checked arithmetic, and a
 *      reverting verifier hands a holder a free slash of the agent.
 */
contract SumVerifier is IVerifier {
    uint256 internal constant MAX_OPERAND = type(uint128).max;

    uint256 internal constant SPEC_LENGTH = 64;
    uint256 internal constant RESULT_LENGTH = 32;

    /// @inheritdoc IVerifier
    function isValidSpec(bytes calldata jobSpec) public pure returns (bool) {
        if (jobSpec.length != SPEC_LENGTH) return false;

        (uint256 a, uint256 b) = abi.decode(jobSpec, (uint256, uint256));
        return a <= MAX_OPERAND && b <= MAX_OPERAND;
    }

    /// @inheritdoc IVerifier
    function verify(bytes calldata jobSpec, bytes calldata result) external pure returns (bool) {
        // Re-check the spec: `verify` must be sound even if called directly.
        if (!isValidSpec(jobSpec)) return false;
        if (result.length != RESULT_LENGTH) return false;

        (uint256 a, uint256 b) = abi.decode(jobSpec, (uint256, uint256));
        uint256 claimed = abi.decode(result, (uint256));

        // Cannot overflow: both operands are bounded by uint128 max.
        return claimed == a + b;
    }

    /// @notice Helper for building a well-formed spec offchain or in tests.
    function encodeSpec(uint256 a, uint256 b) external pure returns (bytes memory) {
        return abi.encode(a, b);
    }

    /// @notice Helper for building a well-formed result offchain or in tests.
    function encodeResult(uint256 sum) external pure returns (bytes memory) {
        return abi.encode(sum);
    }
}
