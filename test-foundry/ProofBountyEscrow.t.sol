// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {ProofBountyEscrowBase} from "../contracts/ProofBountyEscrowBase.sol";
import {ProofBountyEscrowNative} from "../contracts/ProofBountyEscrowNative.sol";
import {ProofBountyEscrowERC20} from "../contracts/ProofBountyEscrowERC20.sol";
import {IProofBountyEscrow} from "../contracts/interfaces/IProofBountyEscrow.sol";
import {MockERC20} from "../contracts/mocks/MockERC20.sol";
import {FeeOnTransferERC20} from "../contracts/mocks/FeeOnTransferERC20.sol";
import {RevertingReceiver} from "../contracts/mocks/RevertingReceiver.sol";

contract ProofBountyEscrowTest is Test {
    string internal constant NAME = "Proof Bounty Escrow";
    uint256 internal constant REWARD = 100 ether;
    uint64 internal constant COMMIT_WINDOW = 1 days;
    uint64 internal constant CLAIM_WINDOW = 2 days;

    address internal sponsor = makeAddr("sponsor");
    address internal refundRecipient = makeAddr("refundRecipient");
    address internal solver = makeAddr("solver");
    address internal secondSolver = makeAddr("secondSolver");
    address internal relayer = makeAddr("relayer");
    address internal devCo = makeAddr("devCo");
    address internal securityReserve = makeAddr("securityReserve");

    uint256[3] internal verifierKeys;
    address[3] internal verifiers;
    ProofBountyEscrowNative internal nativeEscrow;
    ProofBountyEscrowERC20 internal tokenEscrow;
    MockERC20 internal token;

    function setUp() public {
        _sortVerifierKeys([uint256(0xA11CE), uint256(0xB0B), uint256(0xCAFE)]);
        nativeEscrow = new ProofBountyEscrowNative(NAME, devCo, securityReserve, verifiers);
        token = new MockERC20();
        tokenEscrow = new ProofBountyEscrowERC20(NAME, token, devCo, securityReserve, verifiers);

        vm.deal(sponsor, 1_000_000 ether);
        token.mint(sponsor, 1_000_000 ether);
        vm.prank(sponsor);
        token.approve(address(tokenEscrow), type(uint256).max);
    }

    function test_ConfigurationIsImmutableAndSeparatedByDeployment() public view {
        assertEq(nativeEscrow.PROTOCOL_VERSION(), "1");
        assertEq(nativeEscrow.DEVCO_BPS(), 200);
        assertEq(nativeEscrow.MIN_VERIFIER_BPS(), 50);
        assertEq(nativeEscrow.MAX_VERIFIER_BPS(), 10_000);
        assertEq(nativeEscrow.SECURITY_BPS(), 50);
        assertEq(nativeEscrow.FIXED_FEE_BPS(), 250);
        assertEq(nativeEscrow.MIN_REWARD_UNITS(), 2);
        assertEq(nativeEscrow.MIN_VERIFIER_FEE_UNITS(), 2);
        assertEq(nativeEscrow.verifierCount(), 3);
        assertEq(nativeEscrow.devCo(), devCo);
        assertEq(nativeEscrow.securityReserve(), securityReserve);
        assertEq(nativeEscrow.asset(), address(0));
        assertEq(tokenEscrow.asset(), address(token));
        assertNotEq(nativeEscrow.deploymentId(), tokenEscrow.deploymentId());
        assertEq(nativeEscrow.verifierSetHash(), tokenEscrow.verifierSetHash());
        for (uint256 i; i < 3; ++i) {
            assertEq(nativeEscrow.verifierAt(i), verifiers[i]);
            assertTrue(nativeEscrow.isVerifier(verifiers[i]));
        }
    }

    function test_AttestationTypehashExplicitlyBindsRewardAndVerifierFee() public view {
        assertEq(
            nativeEscrow.ATTESTATION_TYPEHASH(),
            keccak256(
                "AcceptedResult(bytes32 deploymentId,uint256 bountyId,address solver,bytes32 commitment,bytes32 resultDigest,uint256 reward,uint256 verifierFee,bytes32 profileId,bytes32 specificationHash,bytes32 termsHash,bytes32 verifierSetHash,uint64 claimDeadline)"
            )
        );
    }

    function test_AttestationDigestCanonicalEncodingBindsFrozenEconomics() public {
        uint256 verifierFee = 1 ether;
        IProofBountyEscrow.BountyRequest memory request = _requestWithVerifierFee(REWARD, verifierFee);
        uint256 funding = nativeEscrow.requiredFunding(REWARD, verifierFee);
        vm.prank(sponsor);
        uint256 bountyId = nativeEscrow.createBounty{value: funding}(request);
        IProofBountyEscrow.Claim memory result = IProofBountyEscrow.Claim({
            bountyId: bountyId,
            solver: solver,
            resultDigest: keccak256("economics-bound-result"),
            salt: keccak256("economics-bound-salt")
        });
        IProofBountyEscrow.Bounty memory bounty = nativeEscrow.getBounty(bountyId);
        bytes32 commitment = nativeEscrow.computeCommitment(bountyId, solver, result.resultDigest, result.salt);
        bytes32 structHash = keccak256(
            abi.encode(
                nativeEscrow.ATTESTATION_TYPEHASH(),
                nativeEscrow.deploymentId(),
                bountyId,
                solver,
                commitment,
                result.resultDigest,
                bounty.reward,
                bounty.verifierFee,
                bounty.profileId,
                bounty.specificationHash,
                bounty.termsHash,
                nativeEscrow.verifierSetHash(),
                bounty.claimDeadline
            )
        );
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(NAME)),
                keccak256(bytes(nativeEscrow.PROTOCOL_VERSION())),
                block.chainid,
                address(nativeEscrow)
            )
        );
        bytes32 expected = keccak256(abi.encodePacked(hex"1901", domainSeparator, structHash));

        assertEq(nativeEscrow.attestationDigest(result), expected);
    }

    function test_ConstructorRejectsInvalidAuthoritiesAndProtocolName() public {
        address[3] memory unsorted = [verifiers[1], verifiers[0], verifiers[2]];
        vm.expectRevert(ProofBountyEscrowBase.InvalidVerifierSet.selector);
        new ProofBountyEscrowNative(NAME, devCo, securityReserve, unsorted);

        address[3] memory overlaps = [devCo, verifiers[1], verifiers[2]];
        _sortAddresses(overlaps);
        vm.expectRevert(ProofBountyEscrowBase.InvalidVerifierSet.selector);
        new ProofBountyEscrowNative(NAME, devCo, securityReserve, overlaps);

        vm.expectRevert(ProofBountyEscrowBase.InvalidAddress.selector);
        new ProofBountyEscrowNative(NAME, devCo, devCo, verifiers);

        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(ProofBountyEscrowBase.InvalidAddress.selector);
        new ProofBountyEscrowNative(NAME, predicted, securityReserve, verifiers);

        predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        address[3] memory selfVerifier = [predicted, verifiers[1], verifiers[2]];
        _sortAddresses(selfVerifier);
        vm.expectRevert(ProofBountyEscrowBase.InvalidVerifierSet.selector);
        new ProofBountyEscrowNative(NAME, devCo, securityReserve, selfVerifier);

        vm.expectRevert(ProofBountyEscrowBase.InvalidProtocolName.selector);
        new ProofBountyEscrowNative("", devCo, securityReserve, verifiers);

        address[3] memory contractVerifier = [address(new RevertingReceiver()), verifiers[1], verifiers[2]];
        _sortAddresses(contractVerifier);
        vm.expectRevert(ProofBountyEscrowBase.InvalidVerifierSet.selector);
        new ProofBountyEscrowNative(NAME, devCo, securityReserve, contractVerifier);
    }

    function test_CreateFreezesTermsAndRequiresExactSponsorPaidFunding() public {
        IProofBountyEscrow.BountyRequest memory request = _request(REWARD);
        uint256 expected = nativeEscrow.requiredFunding(REWARD, request.verifierFee);
        assertEq(expected, 103 ether);

        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(ProofBountyEscrowBase.InvalidFunding.selector, expected, expected - 1));
        nativeEscrow.createBounty{value: expected - 1}(request);

        vm.prank(sponsor);
        uint256 bountyId = nativeEscrow.createBounty{value: expected}(request);
        assertEq(bountyId, 1);
        assertEq(nativeEscrow.nextBountyId(), 2);
        assertEq(nativeEscrow.totalEscrowed(), expected);
        assertEq(nativeEscrow.totalClaimable(), 0);
        assertEq(nativeEscrow.accountedBalance(), expected);
        assertEq(address(nativeEscrow).balance, expected);

        IProofBountyEscrow.Bounty memory bounty = nativeEscrow.getBounty(bountyId);
        assertEq(bounty.sponsor, sponsor);
        assertEq(bounty.refundRecipient, refundRecipient);
        assertEq(bounty.reward, REWARD);
        assertEq(bounty.verifierFee, request.verifierFee);
        assertEq(bounty.fundedAmount, expected);
        assertEq(uint8(bounty.status), uint8(IProofBountyEscrow.BountyStatus.Open));
        assertEq(bounty.profileId, keccak256("Counterexample-v1"));
        assertEq(bounty.specificationHash, keccak256("specification"));
        assertEq(bounty.termsHash, keccak256("terms"));
        assertEq(bounty.winner, address(0));
        assertEq(bounty.resultDigest, bytes32(0));
    }

    function test_CreateRejectsMalformedAndUnboundedBounties() public {
        IProofBountyEscrow.BountyRequest memory request = _request(REWARD);
        uint256 funding = nativeEscrow.requiredFunding(REWARD, request.verifierFee);

        request = _requestWithVerifierFee(1, 2);
        vm.prank(sponsor);
        vm.expectRevert(ProofBountyEscrowBase.InvalidBounty.selector);
        nativeEscrow.createBounty{value: 0}(request);

        request = _request(REWARD);
        request.refundRecipient = address(0);
        vm.prank(sponsor);
        vm.expectRevert(ProofBountyEscrowBase.InvalidBounty.selector);
        nativeEscrow.createBounty{value: funding}(request);

        request = _request(REWARD);
        request.refundRecipient = address(nativeEscrow);
        vm.prank(sponsor);
        vm.expectRevert(ProofBountyEscrowBase.InvalidBounty.selector);
        nativeEscrow.createBounty{value: funding}(request);

        request = _request(REWARD);
        request.termsHash = bytes32(0);
        vm.prank(sponsor);
        vm.expectRevert(ProofBountyEscrowBase.InvalidHash.selector);
        nativeEscrow.createBounty{value: funding}(request);

        request = _request(REWARD);
        request.commitDeadline = uint64(block.timestamp);
        vm.prank(sponsor);
        vm.expectRevert(ProofBountyEscrowBase.InvalidDeadline.selector);
        nativeEscrow.createBounty{value: funding}(request);

        request = _request(REWARD);
        request.claimDeadline = uint64(block.timestamp + nativeEscrow.MAX_BOUNTY_DURATION() + 1);
        vm.prank(sponsor);
        vm.expectRevert(ProofBountyEscrowBase.InvalidDeadline.selector);
        nativeEscrow.createBounty{value: funding}(request);
    }

    function test_VerifierFeeMinimumBoundaryIsAccepted() public {
        uint256 reward = 10_200;
        uint256 minimum = nativeEscrow.minimumVerifierFee(reward);
        assertEq(minimum, 51);
        assertEq(nativeEscrow.maximumVerifierFee(reward), reward);

        IProofBountyEscrow.BountyRequest memory request = _requestWithVerifierFee(reward, minimum);
        uint256 funding = nativeEscrow.requiredFunding(reward, minimum);
        vm.prank(sponsor);
        uint256 bountyId = nativeEscrow.createBounty{value: funding}(request);

        IProofBountyEscrow.Bounty memory bounty = nativeEscrow.getBounty(bountyId);
        assertEq(bounty.verifierFee, minimum);
        assertEq(bounty.fundedAmount, reward + 204 + minimum + 51);
    }

    function test_AbsoluteMinimumFeePaysEachSigningVerifierOneUnit() public {
        uint256 reward = nativeEscrow.MIN_REWARD_UNITS();
        uint256 verifierFee = nativeEscrow.minimumVerifierFee(reward);
        assertEq(reward, 2);
        assertEq(verifierFee, 2);

        IProofBountyEscrow.BountyRequest memory request = _requestWithVerifierFee(reward, verifierFee);
        uint256 funding = nativeEscrow.requiredFunding(reward, verifierFee);
        assertEq(funding, 4);
        vm.prank(sponsor);
        uint256 bountyId = nativeEscrow.createBounty{value: funding}(request);

        IProofBountyEscrow.Claim memory result = _commitResult(nativeEscrow, bountyId, solver, "unit-fee");
        vm.warp(nativeEscrow.getBounty(bountyId).commitDeadline);
        nativeEscrow.claim(result, _signatures(nativeEscrow, result));

        assertEq(nativeEscrow.claimable(solver), 2);
        assertEq(nativeEscrow.claimable(verifiers[0]), 1);
        assertEq(nativeEscrow.claimable(verifiers[1]), 1);
        assertEq(nativeEscrow.claimable(securityReserve), 0);
        assertEq(nativeEscrow.totalClaimable(), funding);
    }

    function test_VerifierFeeMaximumBoundaryIsAcceptedAndPaid() public {
        uint256 reward = 10_200;
        uint256 maximum = nativeEscrow.maximumVerifierFee(reward);
        IProofBountyEscrow.BountyRequest memory request = _requestWithVerifierFee(reward, maximum);
        uint256 funding = nativeEscrow.requiredFunding(reward, maximum);
        vm.prank(sponsor);
        uint256 bountyId = nativeEscrow.createBounty{value: funding}(request);

        IProofBountyEscrow.Claim memory result = _commitResult(nativeEscrow, bountyId, solver, "maximum-fee");
        vm.warp(nativeEscrow.getBounty(bountyId).commitDeadline);
        nativeEscrow.claim(result, _signatures(nativeEscrow, result));

        assertEq(nativeEscrow.claimable(verifiers[0]), maximum / 2);
        assertEq(nativeEscrow.claimable(verifiers[1]), maximum / 2);
        assertEq(nativeEscrow.claimable(securityReserve), 51);
        assertEq(nativeEscrow.totalClaimable(), funding);
    }

    function test_VerifierFeeOutsideBoundsIsRejected() public {
        uint256 reward = 10_200;
        uint256 minimum = nativeEscrow.minimumVerifierFee(reward);
        uint256 maximum = nativeEscrow.maximumVerifierFee(reward);

        vm.expectRevert(abi.encodeWithSelector(ProofBountyEscrowBase.InvalidVerifierFee.selector, 2, 2, 1));
        nativeEscrow.requiredFunding(2, 1);

        vm.expectRevert(
            abi.encodeWithSelector(ProofBountyEscrowBase.InvalidVerifierFee.selector, minimum, maximum, minimum - 1)
        );
        nativeEscrow.requiredFunding(reward, minimum - 1);

        IProofBountyEscrow.BountyRequest memory excessive = _requestWithVerifierFee(reward, maximum + 1);
        vm.prank(sponsor);
        vm.expectRevert(
            abi.encodeWithSelector(ProofBountyEscrowBase.InvalidVerifierFee.selector, minimum, maximum, maximum + 1)
        );
        nativeEscrow.createBounty{value: 0}(excessive);
    }

    function test_CommitmentsArePerSolverAndReplaceableUntilBoundary() public {
        uint256 bountyId = _createNative(REWARD);
        bytes32 firstResult = keccak256("first-result");
        bytes32 finalResult = keccak256("final-result");
        bytes32 firstSalt = keccak256("first-salt");
        bytes32 finalSalt = keccak256("final-salt");
        bytes32 first = nativeEscrow.computeCommitment(bountyId, solver, firstResult, firstSalt);
        bytes32 replacement = nativeEscrow.computeCommitment(bountyId, solver, finalResult, finalSalt);
        bytes32 competitor = nativeEscrow.computeCommitment(
            bountyId, secondSolver, keccak256("competitor"), keccak256("competitor-salt")
        );

        vm.prank(solver);
        nativeEscrow.commit(bountyId, first);
        vm.prank(solver);
        nativeEscrow.commit(bountyId, replacement);
        vm.prank(secondSolver);
        nativeEscrow.commit(bountyId, competitor);

        assertEq(nativeEscrow.commitments(bountyId, solver), replacement);
        assertEq(nativeEscrow.commitments(bountyId, secondSolver), competitor);

        IProofBountyEscrow.Claim memory result =
            IProofBountyEscrow.Claim({bountyId: bountyId, solver: solver, resultDigest: firstResult, salt: firstSalt});
        vm.warp(nativeEscrow.getBounty(bountyId).commitDeadline);
        IProofBountyEscrow.VerifierSignature[2] memory firstSignatures = _signatures(nativeEscrow, result);
        vm.expectRevert(ProofBountyEscrowBase.InvalidCommitment.selector);
        nativeEscrow.claim(result, firstSignatures);

        result.resultDigest = finalResult;
        result.salt = finalSalt;
        IProofBountyEscrow.VerifierSignature[2] memory finalSignatures = _signatures(nativeEscrow, result);
        nativeEscrow.claim(result, finalSignatures);
        assertEq(nativeEscrow.getBounty(bountyId).winner, solver);
    }

    function test_HalfOpenDeadlinesHaveNoClaimRefundOverlap() public {
        uint256 bountyId = _createNative(REWARD);
        IProofBountyEscrow.Claim memory result = _commitResult(nativeEscrow, bountyId, solver, "boundary");
        IProofBountyEscrow.Bounty memory bounty = nativeEscrow.getBounty(bountyId);
        IProofBountyEscrow.VerifierSignature[2] memory signatures = _signatures(nativeEscrow, result);

        vm.warp(bounty.commitDeadline - 1);
        vm.expectRevert(ProofBountyEscrowBase.ClaimPhaseClosed.selector);
        nativeEscrow.claim(result, signatures);
        vm.expectRevert(ProofBountyEscrowBase.RefundNotAvailable.selector);
        nativeEscrow.refund(bountyId);

        vm.warp(bounty.commitDeadline);
        vm.prank(secondSolver);
        vm.expectRevert(ProofBountyEscrowBase.CommitPhaseClosed.selector);
        nativeEscrow.commit(bountyId, keccak256("too-late"));
        vm.expectRevert(ProofBountyEscrowBase.RefundNotAvailable.selector);
        nativeEscrow.refund(bountyId);

        vm.warp(bounty.claimDeadline);
        vm.expectRevert(ProofBountyEscrowBase.ClaimPhaseClosed.selector);
        nativeEscrow.claim(result, signatures);
        nativeEscrow.refund(bountyId);
        assertEq(uint8(nativeEscrow.getBounty(bountyId).status), uint8(IProofBountyEscrow.BountyStatus.Refunded));
    }

    function test_ValidRelayedClaimPaysExactRewardAndFrozenFeeSplit() public {
        uint256 reward = 10_200;
        uint256 bountyId = _createNative(reward);
        IProofBountyEscrow.Claim memory result = _commitResult(nativeEscrow, bountyId, solver, "accepted");
        IProofBountyEscrow.Bounty memory beforeBounty = nativeEscrow.getBounty(bountyId);
        vm.warp(beforeBounty.commitDeadline);

        IProofBountyEscrow.VerifierSignature[2] memory signatures = _signatures(nativeEscrow, result);
        vm.prank(relayer);
        nativeEscrow.claim(result, signatures);

        uint256 declaredVerifierFee = nativeEscrow.minimumVerifierFee(reward);
        (uint256 devFee, uint256 verifierFee, uint256 securityFee) =
            nativeEscrow.feeBreakdown(reward, declaredVerifierFee);
        uint256 funded = reward + devFee + verifierFee + securityFee;
        assertEq(devFee, 204);
        assertEq(verifierFee, 51);
        assertEq(securityFee, 51);
        assertEq(nativeEscrow.claimable(solver), reward);
        assertEq(nativeEscrow.claimable(devCo), devFee);
        assertEq(nativeEscrow.claimable(verifiers[0]), 25);
        assertEq(nativeEscrow.claimable(verifiers[1]), 25);
        assertEq(nativeEscrow.claimable(verifiers[2]), 0);
        assertEq(nativeEscrow.claimable(securityReserve), securityFee + 1);
        assertEq(nativeEscrow.totalEscrowed(), 0);
        assertEq(nativeEscrow.totalClaimable(), funded);
        assertEq(nativeEscrow.accountedBalance(), funded);
        assertTrue(nativeEscrow.isSolvent());

        IProofBountyEscrow.Bounty memory paid = nativeEscrow.getBounty(bountyId);
        assertEq(uint8(paid.status), uint8(IProofBountyEscrow.BountyStatus.Paid));
        assertEq(paid.winner, solver);
        assertEq(paid.resultDigest, result.resultDigest);
        assertEq(nativeEscrow.commitments(bountyId, solver), bytes32(0));

        vm.expectRevert(ProofBountyEscrowBase.BountyNotOpen.selector);
        nativeEscrow.claim(result, signatures);
        vm.expectRevert(ProofBountyEscrowBase.BountyNotOpen.selector);
        nativeEscrow.refund(bountyId);
    }

    function test_FirstValidClaimWinsAmongMultipleSolvers() public {
        uint256 bountyId = _createNative(REWARD);
        IProofBountyEscrow.Claim memory first = _commitResult(nativeEscrow, bountyId, solver, "winner");
        IProofBountyEscrow.Claim memory second = _commitResult(nativeEscrow, bountyId, secondSolver, "loser");
        IProofBountyEscrow.VerifierSignature[2] memory firstSignatures = _signatures(nativeEscrow, first);
        IProofBountyEscrow.VerifierSignature[2] memory secondSignatures = _signatures(nativeEscrow, second);
        vm.warp(nativeEscrow.getBounty(bountyId).commitDeadline);

        nativeEscrow.claim(first, firstSignatures);
        vm.expectRevert(ProofBountyEscrowBase.BountyNotOpen.selector);
        nativeEscrow.claim(second, secondSignatures);

        assertEq(nativeEscrow.getBounty(bountyId).winner, solver);
        assertEq(nativeEscrow.claimable(solver), REWARD);
        assertEq(nativeEscrow.claimable(secondSolver), 0);
    }

    function test_ExpiredRefundReturnsRewardAndEveryFeeWithoutVerifierOrSponsor() public {
        uint256 declaredVerifierFee = 7 ether;
        IProofBountyEscrow.BountyRequest memory request = _requestWithVerifierFee(REWARD, declaredVerifierFee);
        uint256 funded = nativeEscrow.requiredFunding(REWARD, declaredVerifierFee);
        vm.prank(sponsor);
        uint256 bountyId = nativeEscrow.createBounty{value: funded}(request);
        vm.warp(nativeEscrow.getBounty(bountyId).claimDeadline);

        vm.prank(relayer);
        nativeEscrow.refund(bountyId);
        assertEq(nativeEscrow.claimable(refundRecipient), funded);
        assertEq(nativeEscrow.claimable(sponsor), 0);
        assertEq(nativeEscrow.claimable(devCo), 0);
        assertEq(nativeEscrow.totalEscrowed(), 0);
        assertEq(nativeEscrow.totalClaimable(), funded);

        vm.prank(refundRecipient);
        vm.expectRevert(ProofBountyEscrowBase.InvalidAddress.selector);
        nativeEscrow.withdraw(address(nativeEscrow), funded);
        assertEq(nativeEscrow.claimable(refundRecipient), funded);

        vm.prank(refundRecipient);
        nativeEscrow.withdraw(refundRecipient, funded);
        assertEq(nativeEscrow.claimable(refundRecipient), 0);
        assertEq(nativeEscrow.totalClaimable(), 0);
        assertEq(address(nativeEscrow).balance, 0);
    }

    function test_AttestationsRejectWrongOrderKeyResultAndDeployment() public {
        ProofBountyEscrowNative second = new ProofBountyEscrowNative(NAME, devCo, securityReserve, verifiers);
        vm.deal(sponsor, sponsor.balance + 1_000 ether);
        uint256 firstId = _createNative(REWARD);

        IProofBountyEscrow.BountyRequest memory request = _request(REWARD);
        uint256 secondFunding = second.requiredFunding(REWARD, request.verifierFee);
        vm.prank(sponsor);
        uint256 secondId = second.createBounty{value: secondFunding}(request);
        IProofBountyEscrow.Claim memory first = _commitResult(nativeEscrow, firstId, solver, "domain");
        IProofBountyEscrow.Claim memory secondResult = IProofBountyEscrow.Claim({
            bountyId: secondId, solver: solver, resultDigest: first.resultDigest, salt: first.salt
        });
        bytes32 secondCommitment =
            second.computeCommitment(secondId, solver, secondResult.resultDigest, secondResult.salt);
        vm.prank(solver);
        second.commit(secondId, secondCommitment);

        IProofBountyEscrow.VerifierSignature[2] memory firstSignatures = _signatures(nativeEscrow, first);
        vm.warp(nativeEscrow.getBounty(firstId).commitDeadline);
        vm.expectRevert(ProofBountyEscrowBase.InvalidVerifierSignature.selector);
        second.claim(secondResult, firstSignatures);

        IProofBountyEscrow.VerifierSignature[2] memory wrongOrder = _signatures(nativeEscrow, first);
        (wrongOrder[0], wrongOrder[1]) = (wrongOrder[1], wrongOrder[0]);
        vm.expectRevert(ProofBountyEscrowBase.InvalidVerifierOrder.selector);
        nativeEscrow.claim(first, wrongOrder);

        IProofBountyEscrow.Claim memory mutated = IProofBountyEscrow.Claim({
            bountyId: first.bountyId, solver: first.solver, resultDigest: keccak256("mutated"), salt: first.salt
        });
        IProofBountyEscrow.VerifierSignature[2] memory mutatedSignatures = _signatures(nativeEscrow, mutated);
        vm.expectRevert(ProofBountyEscrowBase.InvalidCommitment.selector);
        nativeEscrow.claim(mutated, mutatedSignatures);

        IProofBountyEscrow.VerifierSignature[2] memory wrongKey = _signatures(nativeEscrow, first);
        wrongKey[0] = _sign(0, verifierKeys[2], nativeEscrow.attestationDigest(first));
        vm.expectRevert(ProofBountyEscrowBase.InvalidVerifierSignature.selector);
        nativeEscrow.claim(first, wrongKey);
    }

    function test_AuthorizedVerifierCannotClaimAsSolver() public {
        uint256 bountyId = _createNative(REWARD);
        address verifierSolver = verifiers[2];
        IProofBountyEscrow.Claim memory result = IProofBountyEscrow.Claim({
            bountyId: bountyId,
            solver: verifierSolver,
            resultDigest: keccak256("self-approved"),
            salt: keccak256("verifier-salt")
        });
        bytes32 commitment = nativeEscrow.computeCommitment(bountyId, verifierSolver, result.resultDigest, result.salt);
        vm.prank(verifierSolver);
        nativeEscrow.commit(bountyId, commitment);
        vm.warp(nativeEscrow.getBounty(bountyId).commitDeadline);
        IProofBountyEscrow.VerifierSignature[2] memory signatures = _signatures(nativeEscrow, result);

        vm.expectRevert(ProofBountyEscrowBase.InvalidBounty.selector);
        nativeEscrow.claim(result, signatures);
    }

    function test_FailedNativeWithdrawalRestoresCreditAndAllowsAnotherDestination() public {
        uint256 bountyId = _createNative(REWARD);
        IProofBountyEscrow.Claim memory result = _commitResult(nativeEscrow, bountyId, solver, "withdraw");
        vm.warp(nativeEscrow.getBounty(bountyId).commitDeadline);
        nativeEscrow.claim(result, _signatures(nativeEscrow, result));
        RevertingReceiver receiver = new RevertingReceiver();

        vm.prank(solver);
        vm.expectRevert(ProofBountyEscrowBase.AssetTransferFailed.selector);
        nativeEscrow.withdraw(address(receiver), REWARD);
        assertEq(nativeEscrow.claimable(solver), REWARD);
        assertEq(nativeEscrow.totalClaimable(), nativeEscrow.accountedBalance());

        address safeDestination = makeAddr("safeDestination");
        vm.prank(solver);
        nativeEscrow.withdraw(safeDestination, REWARD);
        assertEq(safeDestination.balance, REWARD);
        assertEq(nativeEscrow.claimable(solver), 0);
    }

    function test_ForcedNativeAndDirectTokenTransfersAreOnlySurplus() public {
        uint256 bountyId = _createNative(REWARD);
        uint256 accounted = nativeEscrow.accountedBalance();
        vm.deal(address(nativeEscrow), address(nativeEscrow).balance + 7 ether);
        assertEq(nativeEscrow.accountedBalance(), accounted);
        assertEq(nativeEscrow.surplus(), 7 ether);
        assertTrue(nativeEscrow.isSolvent());

        uint256 tokenBountyId = _createToken(REWARD);
        uint256 tokenAccounted = tokenEscrow.accountedBalance();
        token.mint(address(tokenEscrow), 9 ether);
        assertEq(tokenEscrow.accountedBalance(), tokenAccounted);
        assertEq(tokenEscrow.surplus(), 9 ether);
        assertEq(nativeEscrow.getBounty(bountyId).fundedAmount, accounted);
        assertEq(tokenEscrow.getBounty(tokenBountyId).fundedAmount, tokenAccounted);
    }

    function test_ERC20ClaimWithdrawAndRefundMirrorNativeAccounting() public {
        uint256 bountyId = _createToken(REWARD);
        IProofBountyEscrow.Claim memory result = _commitResult(tokenEscrow, bountyId, solver, "token");
        vm.warp(tokenEscrow.getBounty(bountyId).commitDeadline);
        tokenEscrow.claim(result, _signatures(tokenEscrow, result));

        assertEq(tokenEscrow.claimable(solver), REWARD);
        uint256 beforeBalance = token.balanceOf(solver);
        vm.prank(solver);
        tokenEscrow.withdraw(solver, REWARD);
        assertEq(token.balanceOf(solver) - beforeBalance, REWARD);
        assertEq(tokenEscrow.claimable(solver), 0);
        assertTrue(tokenEscrow.isSolvent());

        uint256 refundId = _createToken(REWARD / 2);
        uint256 refundAmount = tokenEscrow.getBounty(refundId).fundedAmount;
        vm.warp(tokenEscrow.getBounty(refundId).claimDeadline);
        tokenEscrow.refund(refundId);
        assertEq(tokenEscrow.claimable(refundRecipient), refundAmount);
    }

    function test_ERC20RejectsFeeOnTransferAtFunding() public {
        FeeOnTransferERC20 feeToken = new FeeOnTransferERC20();
        ProofBountyEscrowERC20 feeEscrow = new ProofBountyEscrowERC20(NAME, feeToken, devCo, securityReserve, verifiers);
        uint256 funding = feeEscrow.requiredFunding(REWARD, feeEscrow.minimumVerifierFee(REWARD));
        feeToken.mint(sponsor, funding);
        vm.prank(sponsor);
        feeToken.approve(address(feeEscrow), funding);

        vm.prank(sponsor);
        vm.expectRevert(ProofBountyEscrowERC20.UnsupportedTokenBehavior.selector);
        feeEscrow.createBounty(_request(REWARD));
        assertEq(feeEscrow.nextBountyId(), 1);
        assertEq(feeEscrow.accountedBalance(), 0);
        assertEq(feeToken.balanceOf(address(feeEscrow)), 0);
    }

    function test_NoOwnerPauseCancellationOrArbitraryCallSurface() public {
        (bool ownerSuccess,) = address(nativeEscrow).call(abi.encodeWithSignature("owner()"));
        (bool pauseSuccess,) = address(nativeEscrow).call(abi.encodeWithSignature("pause()"));
        (bool cancelSuccess,) = address(nativeEscrow).call(abi.encodeWithSignature("cancel(uint256)", 1));
        (bool executeSuccess,) =
            address(nativeEscrow).call(abi.encodeWithSignature("execute(address,bytes)", sponsor, bytes("")));
        assertFalse(ownerSuccess);
        assertFalse(pauseSuccess);
        assertFalse(cancelSuccess);
        assertFalse(executeSuccess);

        vm.prank(sponsor);
        (bool directSend,) = address(nativeEscrow).call{value: 1 ether}("");
        assertFalse(directSend);
    }

    function _createNative(uint256 reward) internal returns (uint256) {
        IProofBountyEscrow.BountyRequest memory request = _request(reward);
        uint256 funding = nativeEscrow.requiredFunding(reward, request.verifierFee);
        vm.prank(sponsor);
        return nativeEscrow.createBounty{value: funding}(request);
    }

    function _createToken(uint256 reward) internal returns (uint256) {
        vm.prank(sponsor);
        return tokenEscrow.createBounty(_request(reward));
    }

    function _request(uint256 reward) internal view returns (IProofBountyEscrow.BountyRequest memory) {
        return _requestWithVerifierFee(reward, reward * 50 / 10_000);
    }

    function _requestWithVerifierFee(uint256 reward, uint256 verifierFee)
        internal
        view
        returns (IProofBountyEscrow.BountyRequest memory)
    {
        return IProofBountyEscrow.BountyRequest({
            refundRecipient: refundRecipient,
            reward: reward,
            verifierFee: verifierFee,
            commitDeadline: uint64(block.timestamp + COMMIT_WINDOW),
            claimDeadline: uint64(block.timestamp + COMMIT_WINDOW + CLAIM_WINDOW),
            profileId: keccak256("Counterexample-v1"),
            specificationHash: keccak256("specification"),
            termsHash: keccak256("terms")
        });
    }

    function _commitResult(ProofBountyEscrowBase escrow, uint256 bountyId, address resultSolver, string memory label)
        internal
        returns (IProofBountyEscrow.Claim memory result)
    {
        result = IProofBountyEscrow.Claim({
            bountyId: bountyId,
            solver: resultSolver,
            resultDigest: keccak256(abi.encode("result", label)),
            salt: keccak256(abi.encode("salt", label))
        });
        bytes32 commitment = escrow.computeCommitment(bountyId, resultSolver, result.resultDigest, result.salt);
        vm.prank(resultSolver);
        escrow.commit(bountyId, commitment);
    }

    function _signatures(ProofBountyEscrowBase escrow, IProofBountyEscrow.Claim memory result)
        internal
        view
        returns (IProofBountyEscrow.VerifierSignature[2] memory signatures)
    {
        bytes32 digest = escrow.attestationDigest(result);
        signatures[0] = _sign(0, verifierKeys[0], digest);
        signatures[1] = _sign(1, verifierKeys[1], digest);
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

    function _sortAddresses(address[3] memory addresses_) internal pure {
        for (uint256 i; i < addresses_.length; ++i) {
            for (uint256 j = i + 1; j < addresses_.length; ++j) {
                if (uint160(addresses_[j]) < uint160(addresses_[i])) {
                    (addresses_[i], addresses_[j]) = (addresses_[j], addresses_[i]);
                }
            }
        }
    }
}
