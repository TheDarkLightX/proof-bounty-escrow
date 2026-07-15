// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProofBountyEscrowERC20} from "../contracts/ProofBountyEscrowERC20.sol";
import {IProofBountyEscrow} from "../contracts/interfaces/IProofBountyEscrow.sol";
import {MockERC20} from "../contracts/mocks/MockERC20.sol";

contract ERC20EscrowHandler is Test {
    struct ResultData {
        bytes32 resultDigest;
        bytes32 salt;
    }

    ProofBountyEscrowERC20 public immutable escrow;
    MockERC20 public immutable token;

    address[2] internal sponsors;
    address[2] internal refundRecipients;
    address[3] internal solvers;
    address[2] internal withdrawalDestinations;
    address internal immutable donor;
    uint256[3] internal verifierKeys;
    address[3] internal verifiers;

    address[] internal knownCreditAccounts;
    uint256[] internal bountyIds;
    mapping(uint256 bountyId => mapping(address solver => ResultData result)) internal results;
    mapping(uint256 bountyId => mapping(address solver => uint256 nonce)) internal commitNonces;

    uint256 public totalFunded;
    uint256 public totalDirectSurplus;
    uint256 public totalPaidOut;
    uint256 public successfulClaims;
    uint256 public successfulRefunds;

    constructor(ProofBountyEscrowERC20 escrow_, MockERC20 token_, uint256[3] memory verifierKeys_) {
        escrow = escrow_;
        token = token_;
        sponsors = [makeAddr("erc20-sponsor-a"), makeAddr("erc20-sponsor-b")];
        refundRecipients = [makeAddr("erc20-refund-a"), makeAddr("erc20-refund-b")];
        solvers = [makeAddr("erc20-solver-a"), makeAddr("erc20-solver-b"), makeAddr("erc20-solver-c")];
        withdrawalDestinations = [makeAddr("erc20-destination-a"), makeAddr("erc20-destination-b")];
        donor = makeAddr("erc20-surplus-donor");
        verifierKeys = verifierKeys_;

        knownCreditAccounts.push(refundRecipients[0]);
        knownCreditAccounts.push(refundRecipients[1]);
        knownCreditAccounts.push(solvers[0]);
        knownCreditAccounts.push(solvers[1]);
        knownCreditAccounts.push(solvers[2]);
        knownCreditAccounts.push(escrow_.devCo());
        knownCreditAccounts.push(escrow_.securityReserve());
        for (uint256 i; i < verifiers.length; ++i) {
            verifiers[i] = escrow_.verifierAt(i);
            knownCreditAccounts.push(verifiers[i]);
        }
    }

    function createBounty(
        uint96 rawReward,
        uint96 rawVerifierFee,
        uint32 rawCommitWindow,
        uint32 rawClaimWindow,
        bool secondSponsor
    ) external {
        uint256 reward = bound(uint256(rawReward), escrow.MIN_REWARD_UNITS(), 1e24);
        uint256 verifierFee = bound(uint256(rawVerifierFee), escrow.minimumVerifierFee(reward), reward);
        uint64 commitWindow = uint64(bound(uint256(rawCommitWindow), 1 minutes, 30 days));
        uint64 claimWindow = uint64(bound(uint256(rawClaimWindow), 1 minutes, 30 days));
        address sponsor = sponsors[secondSponsor ? 1 : 0];
        address refundRecipient = refundRecipients[bountyIds.length % refundRecipients.length];
        uint256 funding = escrow.requiredFunding(reward, verifierFee);

        token.mint(sponsor, funding);
        vm.startPrank(sponsor);
        token.approve(address(escrow), funding);
        uint256 bountyId = escrow.createBounty(
            IProofBountyEscrow.BountyRequest({
                refundRecipient: refundRecipient,
                reward: reward,
                verifierFee: verifierFee,
                commitDeadline: uint64(block.timestamp) + commitWindow,
                claimDeadline: uint64(block.timestamp) + commitWindow + claimWindow,
                profileId: keccak256("Counterexample-v1"),
                specificationHash: keccak256(abi.encode("erc20-invariant-spec", bountyIds.length)),
                termsHash: keccak256(abi.encode("erc20-invariant-terms", bountyIds.length))
            })
        );
        vm.stopPrank();

        bountyIds.push(bountyId);
        totalFunded += funding;
    }

    function commitResult(uint256 rawBounty, uint8 rawSolver, bytes32 entropy) external {
        if (bountyIds.length == 0) return;
        uint256 bountyId = bountyIds[rawBounty % bountyIds.length];
        IProofBountyEscrow.Bounty memory bounty = escrow.getBounty(bountyId);
        if (bounty.status != IProofBountyEscrow.BountyStatus.Open || block.timestamp >= bounty.commitDeadline) {
            return;
        }

        address solver = solvers[rawSolver % solvers.length];
        uint256 nonce = ++commitNonces[bountyId][solver];
        bytes32 resultDigest = keccak256(abi.encode("erc20-result", bountyId, solver, nonce, entropy));
        bytes32 salt = keccak256(abi.encode("erc20-salt", bountyId, solver, nonce, entropy));
        bytes32 commitment = escrow.computeCommitment(bountyId, solver, resultDigest, salt);
        vm.prank(solver);
        escrow.commit(bountyId, commitment);
        results[bountyId][solver] = ResultData({resultDigest: resultDigest, salt: salt});
    }

    function advanceTime(uint32 rawSeconds) external {
        vm.warp(block.timestamp + bound(uint256(rawSeconds), 0, 45 days));
    }

    function claimResult(uint256 rawBounty, uint8 rawSolver, uint8 rawPair) external {
        if (bountyIds.length == 0) return;
        uint256 bountyId = bountyIds[rawBounty % bountyIds.length];
        IProofBountyEscrow.Bounty memory bounty = escrow.getBounty(bountyId);
        if (
            bounty.status != IProofBountyEscrow.BountyStatus.Open || block.timestamp < bounty.commitDeadline
                || block.timestamp >= bounty.claimDeadline
        ) return;

        address solver = solvers[rawSolver % solvers.length];
        ResultData memory stored = results[bountyId][solver];
        if (stored.resultDigest == bytes32(0)) return;
        IProofBountyEscrow.Claim memory result = IProofBountyEscrow.Claim({
            bountyId: bountyId, solver: solver, resultDigest: stored.resultDigest, salt: stored.salt
        });
        escrow.claim(result, _signatures(result, rawPair));
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

    function withdrawCredit(uint256 rawAccount, uint128 rawAmount, bool secondDestination) external {
        address account = knownCreditAccounts[rawAccount % knownCreditAccounts.length];
        uint256 available = escrow.claimable(account);
        if (available == 0) return;
        uint256 amount = bound(uint256(rawAmount), 1, available);
        vm.prank(account);
        escrow.withdraw(withdrawalDestinations[secondDestination ? 1 : 0], amount);
        totalPaidOut += amount;
    }

    function transferDirectSurplus(uint128 rawAmount) external {
        uint256 amount = bound(uint256(rawAmount), 1, 1e24);
        token.mint(donor, amount);
        vm.prank(donor);
        assertTrue(token.transfer(address(escrow), amount));
        totalDirectSurplus += amount;
    }

    function attemptTerminalSettlement(uint256 rawBounty, uint8 rawSolver, uint8 rawPair) external {
        if (bountyIds.length == 0) return;
        uint256 bountyId = bountyIds[rawBounty % bountyIds.length];
        if (escrow.getBounty(bountyId).status == IProofBountyEscrow.BountyStatus.Open) return;

        try escrow.refund(bountyId) {} catch {}
        address solver = solvers[rawSolver % solvers.length];
        ResultData memory stored = results[bountyId][solver];
        if (stored.resultDigest == bytes32(0)) return;
        IProofBountyEscrow.Claim memory result = IProofBountyEscrow.Claim({
            bountyId: bountyId, solver: solver, resultDigest: stored.resultDigest, salt: stored.salt
        });
        try escrow.claim(result, _signatures(result, rawPair)) {} catch {}
    }

    function bountyCount() external view returns (uint256) {
        return bountyIds.length;
    }

    function bountyAt(uint256 index) external view returns (uint256) {
        return bountyIds[index];
    }

    function knownCreditAccountCount() external view returns (uint256) {
        return knownCreditAccounts.length;
    }

    function knownCreditAccountAt(uint256 index) external view returns (address) {
        return knownCreditAccounts[index];
    }

    function _signatures(IProofBountyEscrow.Claim memory result, uint8 rawPair)
        internal
        view
        returns (IProofBountyEscrow.VerifierSignature[2] memory signatures)
    {
        uint8 pair = rawPair % 3;
        uint8 first = pair == 2 ? 1 : 0;
        uint8 second = pair == 0 ? 1 : 2;
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
}

/// forge-config: default.invariant.runs = 512
/// forge-config: default.invariant.depth = 80
contract ProofBountyEscrowERC20InvariantTest is StdInvariant, Test {
    ProofBountyEscrowERC20 internal escrow;
    MockERC20 internal token;
    ERC20EscrowHandler internal handler;

    function setUp() public {
        token = new MockERC20();
        address devCo = makeAddr("erc20-invariant-devCo");
        address reserve = makeAddr("erc20-invariant-reserve");
        (uint256[3] memory keys, address[3] memory verifiers) = _sortedVerifiers();
        escrow = new ProofBountyEscrowERC20("Proof Bounty Escrow", IERC20(address(token)), devCo, reserve, verifiers);
        handler = new ERC20EscrowHandler(escrow, token, keys);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = ERC20EscrowHandler.createBounty.selector;
        selectors[1] = ERC20EscrowHandler.commitResult.selector;
        selectors[2] = ERC20EscrowHandler.advanceTime.selector;
        selectors[3] = ERC20EscrowHandler.claimResult.selector;
        selectors[4] = ERC20EscrowHandler.refundBounty.selector;
        selectors[5] = ERC20EscrowHandler.withdrawCredit.selector;
        selectors[6] = ERC20EscrowHandler.transferDirectSurplus.selector;
        selectors[7] = ERC20EscrowHandler.attemptTerminalSettlement.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_ExactTokenBalanceEqualsLiabilitiesPlusKnownSurplus() public view {
        assertTrue(escrow.isSolvent());
        assertEq(escrow.actualBalance(), token.balanceOf(address(escrow)));
        assertEq(token.balanceOf(address(escrow)), escrow.accountedBalance() + handler.totalDirectSurplus());
        assertEq(escrow.surplus(), handler.totalDirectSurplus());
    }

    function invariant_FundingAndWithdrawalConservation() public view {
        assertEq(escrow.accountedBalance() + handler.totalPaidOut(), handler.totalFunded());
        assertEq(escrow.accountedBalance(), escrow.totalEscrowed() + escrow.totalClaimable());
        assertEq(
            token.balanceOf(address(escrow)) + handler.totalPaidOut(),
            handler.totalFunded() + handler.totalDirectSurplus()
        );
    }

    function invariant_OpenBountyDepositsEqualEscrowedTotal() public view {
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

    function invariant_KnownCreditSumEqualsTotalClaimable() public view {
        uint256 credits;
        uint256 count = handler.knownCreditAccountCount();
        for (uint256 i; i < count; ++i) {
            credits += escrow.claimable(handler.knownCreditAccountAt(i));
        }
        assertEq(credits, escrow.totalClaimable());
    }

    function invariant_TerminalStateShapeAndCountsAreConsistent() public view {
        uint256 paid;
        uint256 refunded;
        uint256 count = handler.bountyCount();
        for (uint256 i; i < count; ++i) {
            IProofBountyEscrow.Bounty memory bounty = escrow.getBounty(handler.bountyAt(i));
            assertNotEq(uint8(bounty.status), uint8(IProofBountyEscrow.BountyStatus.None));
            if (bounty.status == IProofBountyEscrow.BountyStatus.Paid) {
                ++paid;
                assertNotEq(bounty.winner, address(0));
                assertNotEq(bounty.resultDigest, bytes32(0));
            } else {
                assertEq(bounty.winner, address(0));
                assertEq(bounty.resultDigest, bytes32(0));
                if (bounty.status == IProofBountyEscrow.BountyStatus.Refunded) ++refunded;
            }
        }
        assertEq(paid, handler.successfulClaims());
        assertEq(refunded, handler.successfulRefunds());
        assertLe(paid + refunded, count);
    }

    function _sortedVerifiers() internal pure returns (uint256[3] memory keys, address[3] memory verifiers) {
        keys = [uint256(777), uint256(888), uint256(999)];
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
