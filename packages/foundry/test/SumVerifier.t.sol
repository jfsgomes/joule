// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { SumVerifier } from "../contracts/verifiers/SumVerifier.sol";

contract SumVerifierTest is Test {
    SumVerifier internal verifier;

    function setUp() public {
        verifier = new SumVerifier();
    }

    // --- happy path ---

    function test_AcceptsCorrectSum() public view {
        assertTrue(verifier.verify(abi.encode(uint256(2), uint256(2)), abi.encode(uint256(4))));
    }

    function test_RejectsWrongSum() public view {
        assertFalse(verifier.verify(abi.encode(uint256(2), uint256(2)), abi.encode(uint256(5))));
    }

    function testFuzz_AcceptsExactlyTheCorrectSum(uint128 a, uint128 b, uint256 claimed) public view {
        bytes memory spec = abi.encode(uint256(a), uint256(b));
        uint256 truth = uint256(a) + uint256(b);

        assertTrue(verifier.verify(spec, abi.encode(truth)), "the true sum must verify");

        if (claimed != truth) {
            assertFalse(verifier.verify(spec, abi.encode(claimed)), "no other value may verify");
        }
    }

    // --- the griefing defence: nothing may revert, ever ---

    /// @dev The attack this guards against: a holder redeems with a spec the
    ///      verifier cannot handle, the agent is unable to deliver anything
    ///      that verifies, the window lapses and the holder collects
    ///      faceValue + penalty. isValidSpec lets the escrow refuse the job
    ///      before any clock starts.
    function test_OversizedOperandsAreRejectedNotReverted() public view {
        bytes memory poisoned = abi.encode(type(uint256).max, type(uint256).max);

        assertFalse(verifier.isValidSpec(poisoned), "escrow must be able to refuse this at redeem()");
        assertFalse(verifier.verify(poisoned, abi.encode(uint256(0))), "and it must not revert here either");
    }

    /// @dev Where a naive implementation would blow up: a + b overflowing uint256.
    function test_OperandsThatWouldOverflowAreRejected() public view {
        uint256 justOverCap = uint256(type(uint128).max) + 1;

        assertFalse(verifier.isValidSpec(abi.encode(justOverCap, uint256(1))));
        assertTrue(verifier.isValidSpec(abi.encode(uint256(type(uint128).max), uint256(type(uint128).max))));
    }

    function test_MaximumValidOperandsStillVerify() public view {
        uint256 max = type(uint128).max;
        bytes memory spec = abi.encode(max, max);

        assertTrue(verifier.isValidSpec(spec));
        assertTrue(verifier.verify(spec, abi.encode(max + max)), "the largest legal sum must verify");
    }

    function testFuzz_MalformedSpecNeverReverts(bytes calldata junk) public view {
        // No assertion on the outcome -- the property under test is that these
        // calls return rather than revert, whatever bytes arrive.
        verifier.isValidSpec(junk);
        verifier.verify(junk, junk);
    }

    function testFuzz_MalformedResultNeverReverts(bytes calldata junk) public view {
        verifier.verify(abi.encode(uint256(2), uint256(2)), junk);
    }

    function test_WrongLengthSpecIsInvalid() public view {
        assertFalse(verifier.isValidSpec(abi.encode(uint256(1))), "32 bytes is not a spec");
        assertFalse(verifier.isValidSpec(abi.encode(uint256(1), uint256(2), uint256(3))), "96 bytes is not a spec");
        assertFalse(verifier.isValidSpec(""), "empty is not a spec");
    }

    function test_WrongLengthResultDoesNotVerify() public view {
        bytes memory spec = abi.encode(uint256(2), uint256(2));

        assertFalse(verifier.verify(spec, ""));
        assertFalse(verifier.verify(spec, abi.encode(uint256(4), uint256(4))));
    }

    // --- encoding helpers agree with the decoder ---

    function testFuzz_HelpersRoundTrip(uint128 a, uint128 b) public view {
        bytes memory spec = verifier.encodeSpec(a, b);
        bytes memory result = verifier.encodeResult(uint256(a) + uint256(b));

        assertTrue(verifier.isValidSpec(spec));
        assertTrue(verifier.verify(spec, result));
    }
}
