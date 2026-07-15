// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {ProofBountyEscrowNative} from "../contracts/ProofBountyEscrowNative.sol";
import {IProofBountyEscrow} from "../contracts/interfaces/IProofBountyEscrow.sol";

contract NativeEscrowHandler is Test {
    struct ResultData {
        bytes32 resultDigest;
        bytes32 salt;
    }

    ProofBountyEscrowNative public immutable escrow;
    address public immutable sponsor;
    address public immutable refundRecipient;
    address public immutable solverA;
    address public immutable solverB;
    address public immutable devCo;
    address public immutable securityReserve;
    address public immutable withdrawalDestination;

    uint256[3] internal verifierKeys;
    address[3] internal verifiers;
    address[] internal knownAccounts;
    uint256[] internal bountyIds;
    mapping(uint256 bountyId => mapping(address solver => ResultData result)) internal results;
    mapping(uint256 bountyId => mapping(address solver => uint256 nonce)) internal commitNonces;

    uint256 public totalFunded;
    uint256 public totalForced;
    uint256 public totalPaidOut;
    uint256 public successfulClaims;
    uint256 public successfulRefunds;

    constructor(ProofBountyEscrowNative escrow_, uint256[3] memory verifierKeys_) {
        escrow = escrow_;
        sponsor = address(uint160(uint256(keccak256("handler-sponsor"))));
        refundRecipient = address(uint160(uint256(keccak256("handler-refund"))));
        solverA = address(uint160(uint256(keccak256("handler-solver-a"))));
        solverB = address(uint160(uint256(keccak256("handler-solver-b"))));
        devCo = escrow_.devCo();
        securityReserve = escrow_.securityReserve();
        withdrawalDestination = address(uint160(uint256(keccak256("handler-destination"))));
        verifierKeys = verifierKeys_;
        for (uint256 i; i < 3; ++i) {
            verifiers[i] = escrow_.verifierAt(i);
        }

        knownAccounts.push(sponsor);
        knownAccounts.push(refundRecipient);
        knownAccounts.push(solverA);
        knownAccounts.push(solverB);
        knownAccounts.push(devCo);
        knownAccounts.push(securityReserve);
        for (uint256 i; i < 3; ++i) {
            knownAccounts.push(verifiers[i]);
        }
    }

    function createBounty(uint96 rawReward, uint96 rawVerifierFee, uint32 rawCommitWindow, uint32 rawClaimWindow)
        external
    {
        uint256 reward = bound(uint256(rawReward), escrow.MIN_REWARD_UNITS(), 1e24);
        uint256 verifierFee = bound(uint256(rawVerifierFee), escrow.minimumVerifierFee(reward), reward);
        uint64 commitWindow = uint64(bound(uint256(rawCommitWindow), 1 minutes, 30 days));
        uint64 claimWindow = uint64(bound(uint256(rawClaimWindow), 1 minutes, 30 days));
        IProofBountyEscrow.BountyRequest memory request = IProofBountyEscrow.BountyRequest({
            refundRecipient: refundRecipient,
            reward: reward,
            verifierFee: verifierFee,
            commitDeadline: uint64(block.timestamp) + commitWindow,
            claimDeadline: uint64(block.timestamp) + commitWindow + claimWindow,
            profileId: keccak256("Counterexample-v1"),
            specificationHash: keccak256(abi.encode("invariant-spec", bountyIds.length)),
            termsHash: keccak256(abi.encode("invariant-terms", bountyIds.length))
        });
        uint256 funding = escrow.requiredFunding(reward, verifierFee);
        vm.deal(sponsor, sponsor.balance + funding);
        vm.prank(sponsor);
        uint256 bountyId = escrow.createBounty{value: funding}(request);
        bountyIds.push(bountyId);
        totalFunded += funding;
    }

    function commitResult(uint256 rawBounty, bool secondSolver, bytes32 entropy) external {
        if (bountyIds.length == 0) return;
        uint256 bountyId = bountyIds[rawBounty % bountyIds.length];
        IProofBountyEscrow.Bounty memory bounty = escrow.getBounty(bountyId);
        if (bounty.status != IProofBountyEscrow.BountyStatus.Open || block.timestamp >= bounty.commitDeadline) {
            return;
        }
        address resultSolver = secondSolver ? solverB : solverA;
        uint256 nonce = ++commitNonces[bountyId][resultSolver];
        bytes32 resultDigest = keccak256(abi.encode("result", bountyId, resultSolver, nonce, entropy));
        bytes32 salt = keccak256(abi.encode("salt", bountyId, resultSolver, nonce, entropy));
        bytes32 commitment = escrow.computeCommitment(bountyId, resultSolver, resultDigest, salt);
        vm.prank(resultSolver);
        escrow.commit(bountyId, commitment);
        results[bountyId][resultSolver] = ResultData({resultDigest: resultDigest, salt: salt});
    }

    function advanceTime(uint32 rawSeconds) external {
        uint256 secondsToAdvance = bound(uint256(rawSeconds), 0, 45 days);
        vm.warp(block.timestamp + secondsToAdvance);
    }

    function claimResult(uint256 rawBounty, bool secondSolver, uint8 rawPair) external {
        if (bountyIds.length == 0) return;
        uint256 bountyId = bountyIds[rawBounty % bountyIds.length];
        IProofBountyEscrow.Bounty memory bounty = escrow.getBounty(bountyId);
        if (
            bounty.status != IProofBountyEscrow.BountyStatus.Open || block.timestamp < bounty.commitDeadline
                || block.timestamp >= bounty.claimDeadline
        ) return;

        address resultSolver = secondSolver ? solverB : solverA;
        ResultData memory stored = results[bountyId][resultSolver];
        if (stored.resultDigest == bytes32(0)) return;
        IProofBountyEscrow.Claim memory result = IProofBountyEscrow.Claim({
            bountyId: bountyId, solver: resultSolver, resultDigest: stored.resultDigest, salt: stored.salt
        });
        IProofBountyEscrow.VerifierSignature[2] memory signatures = _signatures(result, rawPair);
        escrow.claim(result, signatures);
        ++successfulClaims;
    }

    function refundBounty(uint256 rawBounty) external {
        if (bountyIds.length == 0) return;
        uint256 bountyId = bountyIds[rawBounty % bountyIds.length];
        IProofBountyEscrow.Bounty memory bounty = escrow.getBounty(bountyId);
        if (bounty.status != IProofBountyEscrow.BountyStatus.Open || block.timestamp < bounty.claimDeadline) return;
        escrow.refund(bountyId);
        ++successfulRefunds;
    }

    function withdrawCredit(uint256 rawAccount, uint128 rawAmount) external {
        address account = knownAccounts[rawAccount % knownAccounts.length];
        uint256 available = escrow.claimable(account);
        if (available == 0) return;
        uint256 amount = bound(uint256(rawAmount), 1, available);
        vm.prank(account);
        escrow.withdraw(withdrawalDestination, amount);
        totalPaidOut += amount;
    }

    function forceNative(uint128 rawAmount) external {
        uint256 amount = bound(uint256(rawAmount), 1, 1e24);
        vm.deal(address(escrow), address(escrow).balance + amount);
        totalForced += amount;
    }

    function attemptTerminalSettlement(uint256 rawBounty, bool secondSolver, uint8 rawPair) external {
        if (bountyIds.length == 0) return;
        uint256 bountyId = bountyIds[rawBounty % bountyIds.length];
        IProofBountyEscrow.Bounty memory bounty = escrow.getBounty(bountyId);
        if (bounty.status == IProofBountyEscrow.BountyStatus.Open) return;

        try escrow.refund(bountyId) {} catch {}
        address resultSolver = secondSolver ? solverB : solverA;
        ResultData memory stored = results[bountyId][resultSolver];
        if (stored.resultDigest == bytes32(0)) return;
        IProofBountyEscrow.Claim memory result = IProofBountyEscrow.Claim({
            bountyId: bountyId, solver: resultSolver, resultDigest: stored.resultDigest, salt: stored.salt
        });
        IProofBountyEscrow.VerifierSignature[2] memory signatures = _signatures(result, rawPair);
        try escrow.claim(result, signatures) {} catch {}
    }

    function bountyCount() external view returns (uint256) {
        return bountyIds.length;
    }

    function bountyAt(uint256 index) external view returns (uint256) {
        return bountyIds[index];
    }

    function knownAccountCount() external view returns (uint256) {
        return knownAccounts.length;
    }

    function knownAccountAt(uint256 index) external view returns (address) {
        return knownAccounts[index];
    }

    function _signatures(IProofBountyEscrow.Claim memory result, uint8 rawPair)
        internal
        view
        returns (IProofBountyEscrow.VerifierSignature[2] memory signatures)
    {
        uint8 pair = rawPair % 3;
        uint8 first = pair == 2 ? 1 : 0;
        uint8 second = pair == 0 ? 1 : 2;
        bytes32 digest = escrow.attestationDigest(result);
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
}

contract ProofBountyEscrowInvariantTest is StdInvariant, Test {
    ProofBountyEscrowNative internal escrow;
    NativeEscrowHandler internal handler;

    function setUp() public {
        address devCo = makeAddr("invariant-devCo");
        address reserve = makeAddr("invariant-reserve");
        (uint256[3] memory keys, address[3] memory verifiers) = _sortedVerifiers();
        escrow = new ProofBountyEscrowNative("Proof Bounty Escrow", devCo, reserve, verifiers);
        handler = new NativeEscrowHandler(escrow, keys);
        targetContract(address(handler));
    }

    function invariant_SolvencyAndSurplusIdentityAlwaysHold() public view {
        assertTrue(escrow.isSolvent());
        assertGe(address(escrow).balance, escrow.accountedBalance());
        assertEq(address(escrow).balance, escrow.accountedBalance() + escrow.surplus());
        assertEq(escrow.surplus(), handler.totalForced());
    }

    function invariant_LiabilityChangesOnlyOnFundingAndWithdrawal() public view {
        assertEq(escrow.accountedBalance() + handler.totalPaidOut(), handler.totalFunded());
        assertEq(escrow.accountedBalance(), escrow.totalEscrowed() + escrow.totalClaimable());
    }

    function invariant_OpenDepositsEqualTotalEscrowed() public view {
        uint256 openDeposits;
        uint256 count = handler.bountyCount();
        for (uint256 i; i < count; ++i) {
            IProofBountyEscrow.Bounty memory bounty = escrow.getBounty(handler.bountyAt(i));
            assertGe(bounty.reward, escrow.MIN_REWARD_UNITS());
            assertGe(bounty.verifierFee, escrow.minimumVerifierFee(bounty.reward));
            assertLe(bounty.verifierFee, escrow.maximumVerifierFee(bounty.reward));
            assertEq(bounty.fundedAmount, escrow.requiredFunding(bounty.reward, bounty.verifierFee));
            if (bounty.status == IProofBountyEscrow.BountyStatus.Open) openDeposits += bounty.fundedAmount;
        }
        assertEq(openDeposits, escrow.totalEscrowed());
    }

    function invariant_KnownCreditsEqualTotalClaimable() public view {
        uint256 credits;
        uint256 count = handler.knownAccountCount();
        for (uint256 i; i < count; ++i) {
            credits += escrow.claimable(handler.knownAccountAt(i));
        }
        assertEq(credits, escrow.totalClaimable());
    }

    function invariant_TerminalStateShapeIsConsistent() public view {
        uint256 count = handler.bountyCount();
        for (uint256 i; i < count; ++i) {
            IProofBountyEscrow.Bounty memory bounty = escrow.getBounty(handler.bountyAt(i));
            if (bounty.status == IProofBountyEscrow.BountyStatus.Paid) {
                assertNotEq(bounty.winner, address(0));
                assertNotEq(bounty.resultDigest, bytes32(0));
            } else {
                assertEq(bounty.winner, address(0));
                assertEq(bounty.resultDigest, bytes32(0));
            }
        }
    }

    function _sortedVerifiers() internal pure returns (uint256[3] memory keys, address[3] memory verifiers) {
        keys = [uint256(444), uint256(555), uint256(666)];
        for (uint256 i; i < keys.length; ++i) {
            for (uint256 j = i + 1; j < keys.length; ++j) {
                if (uint160(vm.addr(keys[j])) < uint160(vm.addr(keys[i]))) {
                    (keys[i], keys[j]) = (keys[j], keys[i]);
                }
            }
            verifiers[i] = vm.addr(keys[i]);
        }
    }
}
