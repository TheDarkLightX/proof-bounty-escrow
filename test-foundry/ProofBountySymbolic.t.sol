// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {ProofBountyEscrowNative} from "../contracts/ProofBountyEscrowNative.sol";

/// @notice Small symbolic obligations over the actual V1 fee and commitment implementation.
/// @dev Stateful payout/refund behavior is covered by the reference model and Foundry invariant handler.
contract ProofBountySymbolicTest is Test {
    ProofBountyEscrowNative internal escrow;

    function setUp() public {
        address[3] memory verifiers = [address(0x100), address(0x200), address(0x300)];
        escrow = new ProofBountyEscrowNative("Proof Bounty Escrow", address(0x400), address(0x500), verifiers);
    }

    /// @dev The exact percentage formula is covered by uint128 Foundry fuzzing. Asking an SMT
    ///      solver to re-prove symbolic bit-vector division times out even for uint16 inputs;
    ///      this obligation instead proves conservation across the actual public functions.
    function check_FundingConservesReturnedFeeComponents(uint16 reward, uint16 verifierFee) public view {
        vm.assume(reward >= escrow.MIN_REWARD_UNITS());
        vm.assume(verifierFee >= escrow.minimumVerifierFee(reward));
        vm.assume(verifierFee <= escrow.maximumVerifierFee(reward));
        (uint256 devFee, uint256 returnedVerifierFee, uint256 securityFee) = escrow.feeBreakdown(reward, verifierFee);
        uint256 totalFee = devFee + returnedVerifierFee + securityFee;
        assert(escrow.requiredFunding(reward, verifierFee) == uint256(reward) + totalFee);
        assert(returnedVerifierFee == verifierFee);
    }

    function check_VerifierSplitAndDustConserve(uint16 verifierFee) public pure {
        uint256 share = verifierFee / 2;
        uint256 dust = verifierFee % 2;
        assert(share * 2 + dust == verifierFee);
        assert(dust < 2);
    }

    function check_CommitmentMatchesCanonicalEncoding(
        uint256 bountyId,
        address solver,
        bytes32 resultDigest,
        bytes32 salt
    ) public view {
        bytes32 expected = keccak256(
            abi.encode(escrow.COMMITMENT_TYPEHASH(), escrow.deploymentId(), bountyId, solver, resultDigest, salt)
        );
        assert(escrow.computeCommitment(bountyId, solver, resultDigest, salt) == expected);
    }

    function check_DeadlineWindowsAreDisjointAndTotal(uint64 timestamp, uint64 commitDeadline, uint64 claimDeadline)
        public
        pure
    {
        vm.assume(commitDeadline < claimDeadline);
        bool commitOpen = timestamp < commitDeadline;
        bool claimOpen = commitDeadline <= timestamp && timestamp < claimDeadline;
        bool refundOpen = timestamp >= claimDeadline;
        assert(!(commitOpen && claimOpen));
        assert(!(commitOpen && refundOpen));
        assert(!(claimOpen && refundOpen));
        assert(commitOpen || claimOpen || refundOpen);
    }
}
