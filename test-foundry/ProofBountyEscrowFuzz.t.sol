// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {ProofBountyEscrowBase} from "../contracts/ProofBountyEscrowBase.sol";
import {ProofBountyEscrowNative} from "../contracts/ProofBountyEscrowNative.sol";
import {IProofBountyEscrow} from "../contracts/interfaces/IProofBountyEscrow.sol";

contract ProofBountyEscrowFuzzTest is Test {
    address internal sponsor = makeAddr("fuzz-sponsor");
    address internal refundRecipient = makeAddr("fuzz-refund");
    address internal solver = makeAddr("fuzz-solver");
    address internal destination = makeAddr("fuzz-destination");
    address internal devCo = makeAddr("fuzz-devCo");
    address internal securityReserve = makeAddr("fuzz-reserve");

    uint256[3] internal verifierKeys;
    address[3] internal verifiers;
    ProofBountyEscrowNative internal escrow;

    function setUp() public {
        _sortVerifierKeys([uint256(111), uint256(222), uint256(333)]);
        escrow = new ProofBountyEscrowNative("Proof Bounty Escrow", devCo, securityReserve, verifiers);
    }

    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_FeeFormulaIsExactAndCapped(uint128 rawReward, uint128 rawVerifierFee) public view {
        uint256 reward = bound(uint256(rawReward), escrow.MIN_REWARD_UNITS(), type(uint128).max);
        uint256 verifierFee = bound(uint256(rawVerifierFee), escrow.minimumVerifierFee(reward), reward);
        (uint256 devFee, uint256 returnedVerifierFee, uint256 securityFee) = escrow.feeBreakdown(reward, verifierFee);
        uint256 totalFee = devFee + verifierFee + securityFee;

        assertEq(devFee, reward * 200 / 10_000);
        assertEq(returnedVerifierFee, verifierFee);
        assertEq(securityFee, reward * 50 / 10_000);
        assertGe(verifierFee, reward * 50 / 10_000);
        assertLe(verifierFee, reward);
        assertLe(totalFee, reward + reward * 250 / 10_000);
        assertEq(escrow.requiredFunding(reward, verifierFee), reward + totalFee);
    }

    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_CommitmentBindsEveryVariable(
        uint256 bountyId,
        address resultSolver,
        bytes32 resultDigest,
        bytes32 salt,
        uint256 otherBountyId,
        address otherSolver,
        bytes32 otherDigest,
        bytes32 otherSalt
    ) public view {
        vm.assume(resultSolver != address(0));
        bytes32 baseline = escrow.computeCommitment(bountyId, resultSolver, resultDigest, salt);
        if (otherBountyId != bountyId) {
            assertNotEq(baseline, escrow.computeCommitment(otherBountyId, resultSolver, resultDigest, salt));
        }
        if (otherSolver != resultSolver) {
            assertNotEq(baseline, escrow.computeCommitment(bountyId, otherSolver, resultDigest, salt));
        }
        if (otherDigest != resultDigest) {
            assertNotEq(baseline, escrow.computeCommitment(bountyId, resultSolver, otherDigest, salt));
        }
        if (otherSalt != salt) {
            assertNotEq(baseline, escrow.computeCommitment(bountyId, resultSolver, resultDigest, otherSalt));
        }
    }

    /// forge-config: default.fuzz.runs = 2000
    function testFuzz_CreateRefundWithdrawConservesLiability(
        uint128 rawReward,
        uint128 rawVerifierFee,
        uint32 rawCommitWindow,
        uint32 rawClaimWindow,
        uint128 rawWithdrawal
    ) public {
        uint256 reward = bound(uint256(rawReward), escrow.MIN_REWARD_UNITS(), 1e30);
        uint256 verifierFee = bound(uint256(rawVerifierFee), escrow.minimumVerifierFee(reward), reward);
        uint64 commitWindow = uint64(bound(uint256(rawCommitWindow), 1, 180 days));
        uint64 claimWindow = uint64(bound(uint256(rawClaimWindow), 1, 180 days));
        IProofBountyEscrow.BountyRequest memory request = _request(reward, verifierFee, commitWindow, claimWindow);
        uint256 funding = escrow.requiredFunding(reward, verifierFee);
        vm.deal(sponsor, funding);

        vm.prank(sponsor);
        uint256 bountyId = escrow.createBounty{value: funding}(request);
        assertEq(escrow.accountedBalance(), funding);
        assertEq(address(escrow).balance, funding);

        vm.warp(request.claimDeadline);
        escrow.refund(bountyId);
        assertEq(escrow.totalEscrowed(), 0);
        assertEq(escrow.totalClaimable(), funding);
        assertEq(escrow.claimable(refundRecipient), funding);

        uint256 withdrawal = bound(uint256(rawWithdrawal), 1, funding);
        vm.prank(refundRecipient);
        escrow.withdraw(destination, withdrawal);
        assertEq(destination.balance, withdrawal);
        assertEq(escrow.accountedBalance(), funding - withdrawal);
        assertEq(address(escrow).balance, funding - withdrawal);
        assertTrue(escrow.isSolvent());
    }

    /// forge-config: default.fuzz.runs = 2000
    function testFuzz_ClaimCreditsExactlyOneConservativeSettlement(
        uint128 rawReward,
        uint128 rawVerifierFee,
        bytes32 rawResultDigest,
        bytes32 rawSalt,
        uint8 firstVerifierIndex
    ) public {
        uint256 reward = bound(uint256(rawReward), escrow.MIN_REWARD_UNITS(), 1e30);
        uint256 verifierFee = bound(uint256(rawVerifierFee), escrow.minimumVerifierFee(reward), reward);
        bytes32 resultDigest = rawResultDigest == bytes32(0) ? keccak256("nonzero-result") : rawResultDigest;
        bytes32 salt = rawSalt == bytes32(0) ? keccak256("nonzero-salt") : rawSalt;
        uint8 firstIndex = uint8(bound(firstVerifierIndex, 0, 1));
        uint8 secondIndex = firstIndex + 1;
        IProofBountyEscrow.BountyRequest memory request = _request(reward, verifierFee, 1 days, 2 days);
        uint256 funding = escrow.requiredFunding(reward, verifierFee);
        vm.deal(sponsor, funding);
        vm.prank(sponsor);
        uint256 bountyId = escrow.createBounty{value: funding}(request);

        IProofBountyEscrow.Claim memory result =
            IProofBountyEscrow.Claim({bountyId: bountyId, solver: solver, resultDigest: resultDigest, salt: salt});
        bytes32 commitment = escrow.computeCommitment(bountyId, solver, resultDigest, salt);
        vm.prank(solver);
        escrow.commit(bountyId, commitment);

        IProofBountyEscrow.VerifierSignature[2] memory signatures;
        uint8 signerBitmap = uint8((uint256(1) << firstIndex) | (uint256(1) << secondIndex));
        bytes32 digest = escrow.attestationDigest(result, signerBitmap);
        signatures[0] = _sign(firstIndex, verifierKeys[firstIndex], digest);
        signatures[1] = _sign(secondIndex, verifierKeys[secondIndex], digest);
        vm.warp(request.commitDeadline);
        escrow.claim(result, signatures);
        _assertSettlement(reward, verifierFee, funding, firstIndex, secondIndex);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_EIP712SignatureCannotReplayAfterChainIdChanges(uint64 rawChainId) public {
        uint256 newChainId = bound(uint256(rawChainId), 2, type(uint32).max);
        vm.assume(newChainId != block.chainid);
        uint256 reward = 1 ether;
        uint256 verifierFee = escrow.minimumVerifierFee(reward);
        IProofBountyEscrow.BountyRequest memory request = _request(reward, verifierFee, 1 days, 2 days);
        uint256 funding = escrow.requiredFunding(reward, verifierFee);
        vm.deal(sponsor, funding);
        vm.prank(sponsor);
        uint256 bountyId = escrow.createBounty{value: funding}(request);
        IProofBountyEscrow.Claim memory result = IProofBountyEscrow.Claim({
            bountyId: bountyId,
            solver: solver,
            resultDigest: keccak256("chain-bound-result"),
            salt: keccak256("chain-bound-salt")
        });
        bytes32 commitment = escrow.computeCommitment(bountyId, solver, result.resultDigest, result.salt);
        vm.prank(solver);
        escrow.commit(bountyId, commitment);
        IProofBountyEscrow.VerifierSignature[2] memory signatures = _signatures(result, 0, 1);

        vm.chainId(newChainId);
        vm.warp(request.commitDeadline);
        vm.expectRevert(ProofBountyEscrowBase.InvalidVerifierSignature.selector);
        escrow.claim(result, signatures);
    }

    function _request(uint256 reward, uint256 verifierFee, uint64 commitWindow, uint64 claimWindow)
        internal
        view
        returns (IProofBountyEscrow.BountyRequest memory)
    {
        return IProofBountyEscrow.BountyRequest({
            refundRecipient: refundRecipient,
            reward: reward,
            verifierFee: verifierFee,
            commitDeadline: uint64(block.timestamp) + commitWindow,
            claimDeadline: uint64(block.timestamp) + commitWindow + claimWindow,
            profileId: keccak256("Counterexample-v1"),
            specificationHash: keccak256("fuzz-specification"),
            termsHash: keccak256("fuzz-terms")
        });
    }

    function _assertSettlement(
        uint256 reward,
        uint256 verifierFee,
        uint256 funding,
        uint8 firstIndex,
        uint8 secondIndex
    ) internal view {
        (uint256 devFee,, uint256 securityFee) = escrow.feeBreakdown(reward, verifierFee);
        uint256 verifierShare = verifierFee / 2;
        uint256 dust = verifierFee - verifierShare * 2;
        assertEq(escrow.claimable(solver), reward);
        assertEq(escrow.claimable(devCo), devFee);
        assertEq(escrow.claimable(verifiers[firstIndex]), verifierShare);
        assertEq(escrow.claimable(verifiers[secondIndex]), verifierShare);
        assertEq(escrow.claimable(securityReserve), securityFee + dust);
        assertEq(escrow.totalClaimable(), funding);
        assertEq(escrow.totalEscrowed(), 0);
        assertEq(escrow.accountedBalance(), funding);
        assertEq(address(escrow).balance, funding);
        assertTrue(escrow.isSolvent());
    }

    function _signatures(IProofBountyEscrow.Claim memory result, uint8 first, uint8 second)
        internal
        view
        returns (IProofBountyEscrow.VerifierSignature[2] memory signatures)
    {
        uint8 signerBitmap = uint8((uint256(1) << first) | (uint256(1) << second));
        bytes32 digest = escrow.attestationDigest(result, signerBitmap);
        signatures[0] = _sign(first, verifierKeys[first], digest);
        signatures[1] = _sign(second, verifierKeys[second], digest);
    }

    function _sign(uint8 index, uint256 privateKey, bytes32 digest)
        internal
        pure
        returns (IProofBountyEscrow.VerifierSignature memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return IProofBountyEscrow.VerifierSignature({verifierIndex: index, signature: abi.encodePacked(r, s, v)});
    }

    function _sortVerifierKeys(uint256[3] memory keys) internal {
        for (uint256 i; i < keys.length; ++i) {
            for (uint256 j = i + 1; j < keys.length; ++j) {
                if (uint160(vm.addr(keys[j])) < uint160(vm.addr(keys[i]))) {
                    (keys[i], keys[j]) = (keys[j], keys[i]);
                }
            }
            verifierKeys[i] = keys[i];
            verifiers[i] = vm.addr(keys[i]);
        }
    }
}
