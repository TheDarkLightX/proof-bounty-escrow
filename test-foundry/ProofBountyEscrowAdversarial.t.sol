// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ProofBountyEscrowBase} from "../contracts/ProofBountyEscrowBase.sol";
import {ProofBountyEscrowNative} from "../contracts/ProofBountyEscrowNative.sol";
import {ProofBountyEscrowERC20} from "../contracts/ProofBountyEscrowERC20.sol";
import {IProofBountyEscrow} from "../contracts/interfaces/IProofBountyEscrow.sol";
import {AdversarialERC20} from "../contracts/mocks/AdversarialERC20.sol";

contract ReentrantWithdrawalCallback {
    IProofBountyEscrow internal immutable escrow;
    address internal immutable destination;
    uint256 internal immutable amount;

    constructor(IProofBountyEscrow escrow_, address destination_, uint256 amount_) {
        escrow = escrow_;
        destination = destination_;
        amount = amount_;
    }

    function reenter() external {
        escrow.withdraw(destination, amount);
    }
}

contract ProofBountyEscrowAdversarialTest is Test {
    string internal constant NAME = "Proof Bounty Escrow";
    uint256 internal constant REWARD = 100 ether;
    uint64 internal constant COMMIT_WINDOW = 1 days;
    uint64 internal constant CLAIM_WINDOW = 2 days;
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    address internal sponsor = makeAddr("adversarialSponsor");
    address internal refundRecipient = makeAddr("adversarialRefundRecipient");
    address internal solver = makeAddr("adversarialSolver");
    address internal destination = makeAddr("adversarialDestination");
    address internal devCo = makeAddr("adversarialDevCo");
    address internal securityReserve = makeAddr("adversarialSecurityReserve");

    uint256[3] internal verifierKeys;
    address[3] internal verifiers;
    ProofBountyEscrowNative internal nativeEscrow;

    function setUp() public {
        _sortVerifierKeys([uint256(0xA11CE), uint256(0xB0B), uint256(0xCAFE)]);
        nativeEscrow = new ProofBountyEscrowNative(NAME, devCo, securityReserve, verifiers);
        vm.deal(sponsor, 1_000_000 ether);
    }

    function test_FalseReturnAtFundingRollsBackTokensAllowanceAndBounty() public {
        (AdversarialERC20 token, ProofBountyEscrowERC20 escrow) = _deployTokenEscrow();
        uint256 funding = escrow.requiredFunding(REWARD, escrow.minimumVerifierFee(REWARD));
        uint256 sponsorBefore = token.balanceOf(sponsor);
        uint256 allowanceBefore = token.allowance(sponsor, address(escrow));
        token.setBehavior(AdversarialERC20.Behavior.ReturnFalseAfterTransfer);

        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        escrow.createBounty(_request(REWARD, refundRecipient));

        assertEq(token.balanceOf(sponsor), sponsorBefore);
        assertEq(token.balanceOf(address(escrow)), 0);
        assertEq(token.allowance(sponsor, address(escrow)), allowanceBefore);
        assertEq(escrow.nextBountyId(), 1);
        assertEq(escrow.accountedBalance(), 0);
        assertEq(funding, escrow.requiredFunding(REWARD, escrow.minimumVerifierFee(REWARD)));
    }

    function test_ERC20InsolvencyRejectsNewFundingAndExistingWithdrawal() public {
        (AdversarialERC20 token, ProofBountyEscrowERC20 escrow) = _deployTokenEscrow();
        uint256 firstId = _createTokenBounty(escrow, REWARD, refundRecipient);
        uint256 liability = escrow.getBounty(firstId).fundedAmount;
        token.confiscate(address(escrow), 1);

        assertEq(escrow.actualBalance(), liability - 1);
        assertEq(escrow.accountedBalance(), liability);
        assertFalse(escrow.isSolvent());

        uint256 sponsorBalance = token.balanceOf(sponsor);
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(ProofBountyEscrowBase.InsolventAsset.selector, liability - 1, liability));
        escrow.createBounty(_request(REWARD / 2, refundRecipient));

        assertEq(token.balanceOf(sponsor), sponsorBalance);
        assertEq(escrow.nextBountyId(), 2);
        assertEq(escrow.accountedBalance(), liability);

        vm.warp(escrow.getBounty(firstId).claimDeadline);
        escrow.refund(firstId);
        vm.prank(refundRecipient);
        vm.expectRevert(abi.encodeWithSelector(ProofBountyEscrowBase.InsolventAsset.selector, liability - 1, liability));
        escrow.withdraw(destination, liability);

        assertEq(escrow.claimable(refundRecipient), liability);
        assertEq(token.balanceOf(destination), 0);

        token.mint(address(escrow), 1);
        vm.prank(refundRecipient);
        escrow.withdraw(destination, liability);
        assertEq(token.balanceOf(destination), liability);
        assertEq(escrow.accountedBalance(), 0);
    }

    function test_FalseReturnAtWithdrawalRestoresTransferAndEveryAccountingEffect() public {
        (AdversarialERC20 token, ProofBountyEscrowERC20 escrow) = _deployTokenEscrow();
        uint256 bountyId = _createTokenBounty(escrow, REWARD, refundRecipient);
        uint256 funded = escrow.getBounty(bountyId).fundedAmount;
        vm.warp(escrow.getBounty(bountyId).claimDeadline);
        escrow.refund(bountyId);
        token.setBehavior(AdversarialERC20.Behavior.ReturnFalseAfterTransfer);

        uint256 escrowBefore = token.balanceOf(address(escrow));
        vm.prank(refundRecipient);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        escrow.withdraw(destination, funded);

        assertEq(token.balanceOf(address(escrow)), escrowBefore);
        assertEq(token.balanceOf(destination), 0);
        assertEq(escrow.claimable(refundRecipient), funded);
        assertEq(escrow.totalClaimable(), funded);
        assertTrue(escrow.isSolvent());

        token.setBehavior(AdversarialERC20.Behavior.Exact);
        vm.prank(refundRecipient);
        escrow.withdraw(destination, funded);
        assertEq(token.balanceOf(destination), funded);
        assertEq(escrow.totalClaimable(), 0);
    }

    function test_ShortWithdrawalRevertsAndRestoresCreditUntilTokenIsExactAgain() public {
        (AdversarialERC20 token, ProofBountyEscrowERC20 escrow) = _deployTokenEscrow();
        uint256 bountyId = _createTokenBounty(escrow, REWARD, refundRecipient);
        uint256 funded = escrow.getBounty(bountyId).fundedAmount;
        vm.warp(escrow.getBounty(bountyId).claimDeadline);
        escrow.refund(bountyId);
        token.setBehavior(AdversarialERC20.Behavior.ShortTransfer);

        vm.prank(refundRecipient);
        vm.expectRevert(ProofBountyEscrowERC20.UnsupportedTokenBehavior.selector);
        escrow.withdraw(destination, funded);

        assertEq(token.balanceOf(address(escrow)), funded);
        assertEq(token.balanceOf(destination), 0);
        assertEq(escrow.claimable(refundRecipient), funded);
        assertEq(escrow.totalClaimable(), funded);

        token.setBehavior(AdversarialERC20.Behavior.Exact);
        vm.prank(refundRecipient);
        escrow.withdraw(destination, funded);
        assertEq(token.balanceOf(destination), funded);
    }

    function test_WithdrawalSupportsExactPartialPaymentsToPreFundedDestination() public {
        (AdversarialERC20 token, ProofBountyEscrowERC20 escrow) = _deployTokenEscrow();
        uint256 bountyId = _createTokenBounty(escrow, REWARD, refundRecipient);
        uint256 funded = escrow.getBounty(bountyId).fundedAmount;
        uint256 preexisting = 17 ether;
        uint256 first = funded / 3;
        token.mint(destination, preexisting);
        vm.warp(escrow.getBounty(bountyId).claimDeadline);
        escrow.refund(bountyId);

        vm.prank(refundRecipient);
        escrow.withdraw(destination, first);
        assertEq(token.balanceOf(destination), preexisting + first);
        assertEq(escrow.claimable(refundRecipient), funded - first);
        assertEq(escrow.totalClaimable(), funded - first);

        vm.prank(refundRecipient);
        escrow.withdraw(destination, funded - first);
        assertEq(token.balanceOf(destination), preexisting + funded);
        assertEq(escrow.claimable(refundRecipient), 0);
        assertEq(escrow.totalClaimable(), 0);
        assertTrue(escrow.isSolvent());
    }

    function test_TransferFromCallbackCannotReenterCreateBounty() public {
        (AdversarialERC20 token, ProofBountyEscrowERC20 escrow) = _deployTokenEscrow();
        IProofBountyEscrow.BountyRequest memory request = _request(REWARD, refundRecipient);
        token.configureCallback(
            address(escrow), abi.encodeCall(ProofBountyEscrowERC20.createBounty, (request)), false, true
        );

        vm.prank(sponsor);
        uint256 bountyId = escrow.createBounty(request);

        assertEq(bountyId, 1);
        assertTrue(token.callbackAttempted());
        assertFalse(token.callbackSucceeded());
        assertEq(_selector(token.callbackReturnData()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(escrow.totalEscrowed(), escrow.requiredFunding(REWARD, escrow.minimumVerifierFee(REWARD)));
        assertTrue(escrow.isSolvent());
    }

    function test_TransferCallbackCannotReenterWithdrawalForCreditedContract() public {
        (AdversarialERC20 token, ProofBountyEscrowERC20 escrow) = _deployTokenEscrow();
        uint256 funding = escrow.requiredFunding(REWARD, escrow.minimumVerifierFee(REWARD));
        ReentrantWithdrawalCallback receiver =
            new ReentrantWithdrawalCallback(IProofBountyEscrow(address(escrow)), destination, funding);
        uint256 bountyId = _createTokenBounty(escrow, REWARD, address(receiver));
        uint256 funded = escrow.getBounty(bountyId).fundedAmount;
        vm.warp(escrow.getBounty(bountyId).claimDeadline);
        escrow.refund(bountyId);
        token.configureCallback(address(receiver), abi.encodeCall(ReentrantWithdrawalCallback.reenter, ()), true, false);

        vm.prank(address(receiver));
        escrow.withdraw(destination, funded);

        assertTrue(token.callbackAttempted());
        assertFalse(token.callbackSucceeded());
        assertEq(_selector(token.callbackReturnData()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(token.balanceOf(destination), funded);
        assertEq(escrow.claimable(address(receiver)), 0);
        assertEq(escrow.totalClaimable(), 0);
        assertTrue(escrow.isSolvent());
    }

    function test_PermissionlessRefundCallbackPreservesConservationDuringWithdrawal() public {
        (AdversarialERC20 token, ProofBountyEscrowERC20 escrow) = _deployTokenEscrow();
        uint256 callbackRefundId = _createTokenBounty(escrow, REWARD / 2, refundRecipient);
        uint256 withdrawalId = _createTokenBounty(escrow, REWARD, refundRecipient);
        uint256 withdrawalAmount = escrow.getBounty(withdrawalId).fundedAmount;
        uint256 callbackRefundAmount = escrow.getBounty(callbackRefundId).fundedAmount;
        vm.warp(escrow.getBounty(withdrawalId).claimDeadline);
        escrow.refund(withdrawalId);
        token.configureCallback(
            address(escrow), abi.encodeCall(IProofBountyEscrow.refund, (callbackRefundId)), true, false
        );

        vm.prank(refundRecipient);
        escrow.withdraw(destination, withdrawalAmount);

        assertTrue(token.callbackSucceeded());
        assertEq(uint8(escrow.getBounty(callbackRefundId).status), uint8(IProofBountyEscrow.BountyStatus.Refunded));
        assertEq(escrow.claimable(refundRecipient), callbackRefundAmount);
        assertEq(escrow.totalEscrowed(), 0);
        assertEq(escrow.totalClaimable(), callbackRefundAmount);
        assertEq(escrow.accountedBalance(), token.balanceOf(address(escrow)));
        assertTrue(escrow.isSolvent());
    }

    function test_MalformedAndCompactLengthSignaturesRevertWithoutStateChange() public {
        (uint256 bountyId, IProofBountyEscrow.Claim memory result) = _committedNativeResult("malformed");
        IProofBountyEscrow.VerifierSignature[2] memory signatures = _signatures(nativeEscrow, result);
        vm.warp(nativeEscrow.getBounty(bountyId).commitDeadline);

        signatures[0].signature = bytes("");
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureLength.selector, 0));
        nativeEscrow.claim(result, signatures);
        _assertOpenAndUncredited(bountyId);

        signatures = _signatures(nativeEscrow, result);
        bytes memory compact = new bytes(64);
        signatures[0].signature = compact;
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureLength.selector, 64));
        nativeEscrow.claim(result, signatures);
        _assertOpenAndUncredited(bountyId);
    }

    function test_HighSSignatureMalleationIsRejectedWithoutStateChange() public {
        (uint256 bountyId, IProofBountyEscrow.Claim memory result) = _committedNativeResult("high-s");
        IProofBountyEscrow.VerifierSignature[2] memory signatures = _signatures(nativeEscrow, result);
        bytes32 digest = nativeEscrow.attestationDigest(result, 3);
        (uint8 v, bytes32 r, bytes32 lowS) = vm.sign(verifierKeys[0], digest);
        bytes32 highS = bytes32(SECP256K1_N - uint256(lowS));
        uint8 flippedV = v == 27 ? 28 : 27;
        signatures[0].signature = abi.encodePacked(r, highS, flippedV);
        vm.warp(nativeEscrow.getBounty(bountyId).commitDeadline);

        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, highS));
        nativeEscrow.claim(result, signatures);
        _assertOpenAndUncredited(bountyId);
    }

    function test_DuplicateVerifierIndexCannotSatisfyThreshold() public {
        (uint256 bountyId, IProofBountyEscrow.Claim memory result) = _committedNativeResult("duplicate-verifier");
        IProofBountyEscrow.VerifierSignature[2] memory signatures = _signatures(nativeEscrow, result);
        signatures[1] = signatures[0];
        vm.warp(nativeEscrow.getBounty(bountyId).commitDeadline);

        vm.expectRevert(ProofBountyEscrowBase.InvalidVerifierOrder.selector);
        nativeEscrow.claim(result, signatures);
        _assertOpenAndUncredited(bountyId);
    }

    function test_AttestationCannotReplayAcrossBountiesInSameDeployment() public {
        uint256 firstId = _createNativeBounty(REWARD);
        uint256 secondId = _createNativeBounty(REWARD);
        IProofBountyEscrow.Claim memory first = _commitNativeResult(firstId, solver, "same-result");
        IProofBountyEscrow.Claim memory second = _commitNativeResult(secondId, solver, "same-result");
        IProofBountyEscrow.VerifierSignature[2] memory firstSignatures = _signatures(nativeEscrow, first);
        vm.warp(nativeEscrow.getBounty(firstId).commitDeadline);

        vm.expectRevert(ProofBountyEscrowBase.InvalidVerifierSignature.selector);
        nativeEscrow.claim(second, firstSignatures);
        _assertOpenAndUncredited(secondId);

        nativeEscrow.claim(first, firstSignatures);
        assertEq(uint8(nativeEscrow.getBounty(firstId).status), uint8(IProofBountyEscrow.BountyStatus.Paid));
    }

    function _deployTokenEscrow() internal returns (AdversarialERC20 token, ProofBountyEscrowERC20 escrow) {
        token = new AdversarialERC20();
        escrow = new ProofBountyEscrowERC20(NAME, IERC20(address(token)), devCo, securityReserve, verifiers);
        token.mint(sponsor, 1_000_000 ether);
        vm.prank(sponsor);
        token.approve(address(escrow), type(uint256).max);
    }

    function _createTokenBounty(ProofBountyEscrowERC20 escrow, uint256 reward, address refundTo)
        internal
        returns (uint256)
    {
        vm.prank(sponsor);
        return escrow.createBounty(_request(reward, refundTo));
    }

    function _createNativeBounty(uint256 reward) internal returns (uint256) {
        uint256 funding = nativeEscrow.requiredFunding(reward, nativeEscrow.minimumVerifierFee(reward));
        vm.prank(sponsor);
        return nativeEscrow.createBounty{value: funding}(_request(reward, refundRecipient));
    }

    function _committedNativeResult(string memory label)
        internal
        returns (uint256 bountyId, IProofBountyEscrow.Claim memory result)
    {
        bountyId = _createNativeBounty(REWARD);
        result = _commitNativeResult(bountyId, solver, label);
    }

    function _commitNativeResult(uint256 bountyId, address resultSolver, string memory label)
        internal
        returns (IProofBountyEscrow.Claim memory result)
    {
        result = IProofBountyEscrow.Claim({
            bountyId: bountyId,
            solver: resultSolver,
            resultDigest: keccak256(abi.encode("result", label)),
            salt: keccak256(abi.encode("salt", label))
        });
        bytes32 commitment = nativeEscrow.computeCommitment(bountyId, resultSolver, result.resultDigest, result.salt);
        vm.prank(resultSolver);
        nativeEscrow.commit(bountyId, commitment);
    }

    function _request(uint256 reward, address refundTo)
        internal
        view
        returns (IProofBountyEscrow.BountyRequest memory)
    {
        return IProofBountyEscrow.BountyRequest({
            refundRecipient: refundTo,
            reward: reward,
            verifierFee: reward * 50 / 10_000,
            commitDeadline: uint64(block.timestamp + COMMIT_WINDOW),
            claimDeadline: uint64(block.timestamp + COMMIT_WINDOW + CLAIM_WINDOW),
            profileId: keccak256("Counterexample-v1"),
            specificationHash: keccak256("specification"),
            termsHash: keccak256("terms")
        });
    }

    function _signatures(ProofBountyEscrowBase escrow, IProofBountyEscrow.Claim memory result)
        internal
        view
        returns (IProofBountyEscrow.VerifierSignature[2] memory signatures)
    {
        bytes32 digest = escrow.attestationDigest(result, 3);
        for (uint8 i; i < 2; ++i) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(verifierKeys[i], digest);
            signatures[i] =
                IProofBountyEscrow.VerifierSignature({verifierIndex: i, signature: abi.encodePacked(r, s, v)});
        }
    }

    function _assertOpenAndUncredited(uint256 bountyId) internal view {
        assertEq(uint8(nativeEscrow.getBounty(bountyId).status), uint8(IProofBountyEscrow.BountyStatus.Open));
        assertEq(nativeEscrow.claimable(solver), 0);
        assertEq(nativeEscrow.totalClaimable(), 0);
        assertEq(nativeEscrow.totalEscrowed(), nativeEscrow.actualBalance());
    }

    function _selector(bytes memory revertData) internal pure returns (bytes4 selector) {
        if (revertData.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            selector := mload(add(revertData, 0x20))
        }
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
