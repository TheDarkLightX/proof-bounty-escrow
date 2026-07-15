// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IProofBountyEscrow} from "./interfaces/IProofBountyEscrow.sol";

/// @title ProofBountyEscrowBase
/// @notice Immutable, chain-local escrow for objectively replayable proof bounties.
/// @dev A verifier signature means only that the frozen evaluator accepted the bound result digest.
abstract contract ProofBountyEscrowBase is IProofBountyEscrow, EIP712, ReentrancyGuard {
    /// @dev Static tuple used to keep canonical EIP-712 ABI encoding readable and below stack limits.
    struct AcceptedResultData {
        bytes32 deploymentId;
        uint256 bountyId;
        address solver;
        bytes32 commitment;
        bytes32 resultDigest;
        uint256 reward;
        uint256 verifierFee;
        bytes32 profileId;
        bytes32 specificationHash;
        bytes32 termsHash;
        bytes32 verifierSetHash;
        uint8 signerBitmap;
        uint64 claimDeadline;
    }

    string public constant PROTOCOL_VERSION = "1";
    bytes32 public constant PROTOCOL_ID = keccak256("proof-bounty-escrow/v1");
    bytes32 public constant COMMITMENT_TYPEHASH = keccak256(
        "SolverCommitment(bytes32 deploymentId,uint256 bountyId,address solver,bytes32 resultDigest,bytes32 salt)"
    );
    bytes32 public constant ATTESTATION_TYPEHASH = keccak256(
        "AcceptedResult(bytes32 deploymentId,uint256 bountyId,address solver,bytes32 commitment,bytes32 resultDigest,uint256 reward,uint256 verifierFee,bytes32 profileId,bytes32 specificationHash,bytes32 termsHash,bytes32 verifierSetHash,uint8 signerBitmap,uint64 claimDeadline)"
    );

    uint16 public constant BPS_DENOMINATOR = 10_000;
    uint16 public constant DEVCO_BPS = 200;
    uint16 public constant MIN_VERIFIER_BPS = 50;
    uint16 public constant MAX_VERIFIER_BPS = 10_000;
    uint16 public constant SECURITY_BPS = 50;
    uint16 public constant FIXED_FEE_BPS = DEVCO_BPS + SECURITY_BPS;
    uint256 public constant MIN_REWARD_UNITS = 2;
    uint256 public constant MIN_VERIFIER_FEE_UNITS = 2;
    uint8 public constant VERIFIER_COUNT = 3;
    uint8 public constant VERIFIER_THRESHOLD = 2;
    uint64 public constant MAX_BOUNTY_DURATION = 366 days;

    address public immutable asset;
    address public immutable devCo;
    address public immutable securityReserve;
    bytes32 public immutable verifierSetHash;
    bytes32 public immutable deploymentId;

    uint256 public nextBountyId = 1;
    uint256 public totalEscrowed;
    uint256 public totalClaimable;

    mapping(uint256 bountyId => Bounty bounty) public bounties;
    mapping(uint256 bountyId => mapping(address solver => bytes32 commitment)) public commitments;
    mapping(address account => uint256 amount) public claimable;
    mapping(address verifier => bool authorized) public isVerifier;
    address[VERIFIER_COUNT] private _verifiers;

    error InvalidAddress();
    error InvalidProtocolName();
    error InvalidVerifierSet();
    error InvalidBounty();
    error InvalidHash();
    error InvalidDeadline();
    error InvalidFunding(uint256 expected, uint256 received);
    error InvalidVerifierFee(uint256 minimum, uint256 maximum, uint256 received);
    error BountyNotOpen();
    error CommitPhaseClosed();
    error ClaimPhaseClosed();
    error RefundNotAvailable();
    error InvalidCommitment();
    error InvalidVerifierOrder();
    error InvalidSignerBitmap();
    error InvalidVerifierSignature();
    error NothingToWithdraw();
    error InsufficientClaimable();
    error InsolventAsset(uint256 actual, uint256 accounted);
    error AssetTransferFailed();

    constructor(
        string memory protocolName,
        address asset_,
        address devCo_,
        address securityReserve_,
        address[VERIFIER_COUNT] memory verifiers
    ) EIP712(protocolName, PROTOCOL_VERSION) {
        uint256 nameLength = bytes(protocolName).length;
        if (nameLength == 0 || nameLength > 64) revert InvalidProtocolName();
        if (
            devCo_ == address(0) || securityReserve_ == address(0) || devCo_ == securityReserve_
                || devCo_ == address(this) || securityReserve_ == address(this)
                || (asset_ != address(0) && (devCo_ == asset_ || securityReserve_ == asset_))
        ) {
            revert InvalidAddress();
        }

        address previous = address(0);
        for (uint256 i; i < VERIFIER_COUNT; ++i) {
            address verifier = verifiers[i];
            if (
                verifier == address(0) || verifier == address(this) || verifier.code.length != 0 || verifier == devCo_
                    || verifier == securityReserve_ || uint160(verifier) <= uint160(previous)
            ) revert InvalidVerifierSet();
            isVerifier[verifier] = true;
            _verifiers[i] = verifier;
            previous = verifier;
        }

        asset = asset_;
        devCo = devCo_;
        securityReserve = securityReserve_;
        verifierSetHash = keccak256(abi.encode(verifiers, VERIFIER_THRESHOLD));
        deploymentId = keccak256(
            abi.encode(
                PROTOCOL_ID,
                keccak256(bytes(protocolName)),
                block.chainid,
                address(this),
                asset_,
                devCo_,
                securityReserve_,
                verifierSetHash
            )
        );
    }

    /// @notice Records or replaces the caller's commitment before the commit deadline.
    function commit(uint256 bountyId, bytes32 commitment_) external {
        Bounty storage bounty = bounties[bountyId];
        if (bounty.status != BountyStatus.Open) revert BountyNotOpen();
        if (block.timestamp >= bounty.commitDeadline) revert CommitPhaseClosed();
        if (commitment_ == bytes32(0)) revert InvalidHash();

        commitments[bountyId][msg.sender] = commitment_;
        emit SolverCommitted(bountyId, msg.sender, commitment_);
    }

    /// @notice Atomically reveals a committed result, verifies two attestations, and creates pull credits.
    /// @dev Anyone may relay a claim. The commitment and attestations bind the solver who receives the reward.
    function claim(Claim calldata result, VerifierSignature[VERIFIER_THRESHOLD] calldata signatures)
        external
        nonReentrant
    {
        Bounty storage bounty = bounties[result.bountyId];
        if (bounty.status != BountyStatus.Open) revert BountyNotOpen();
        if (block.timestamp < bounty.commitDeadline || block.timestamp >= bounty.claimDeadline) {
            revert ClaimPhaseClosed();
        }
        if (
            result.solver == address(0) || result.resultDigest == bytes32(0) || result.salt == bytes32(0)
                || isVerifier[result.solver] || (asset != address(0) && result.solver == asset)
        ) revert InvalidBounty();

        bytes32 commitment_ = _computeCommitment(result.bountyId, result.solver, result.resultDigest, result.salt);
        if (commitments[result.bountyId][result.solver] != commitment_) revert InvalidCommitment();

        (bytes32 digest, uint8 signerBitmap) = _verifyAttestations(result, bounty, commitment_, signatures);
        _settleBounty(result, bounty, commitment_, signatures, digest, signerBitmap);
    }

    function _verifyAttestations(
        Claim calldata result,
        Bounty storage bounty,
        bytes32 commitment_,
        VerifierSignature[VERIFIER_THRESHOLD] calldata signatures
    ) internal view returns (bytes32 digest, uint8 signerBitmap) {
        signerBitmap = _signerBitmap(signatures[0].verifierIndex, signatures[1].verifierIndex);
        digest = _attestationDigest(result, bounty, commitment_, signerBitmap);
        for (uint256 i; i < VERIFIER_THRESHOLD; ++i) {
            uint8 verifierIndex = signatures[i].verifierIndex;
            if (ECDSA.recover(digest, signatures[i].signature) != _verifiers[verifierIndex]) {
                revert InvalidVerifierSignature();
            }
        }
    }

    function _settleBounty(
        Claim calldata result,
        Bounty storage bounty,
        bytes32 commitment_,
        VerifierSignature[VERIFIER_THRESHOLD] calldata signatures,
        bytes32 digest,
        uint8 signerBitmap
    ) internal {
        bounty.status = BountyStatus.Paid;
        bounty.winner = result.solver;
        bounty.resultDigest = result.resultDigest;
        delete commitments[result.bountyId][result.solver];

        (uint256 devFee,, uint256 securityFee) = feeBreakdown(bounty.reward, bounty.verifierFee);
        totalEscrowed -= bounty.fundedAmount;
        totalClaimable += bounty.fundedAmount;
        claimable[result.solver] += bounty.reward;
        claimable[devCo] += devFee;

        uint256 verifierShare = bounty.verifierFee / VERIFIER_THRESHOLD;
        uint256 verifierRemainder = bounty.verifierFee % VERIFIER_THRESHOLD;
        for (uint256 i; i < VERIFIER_THRESHOLD; ++i) {
            claimable[_verifiers[signatures[i].verifierIndex]] += verifierShare;
        }
        claimable[securityReserve] += securityFee + verifierRemainder;

        emit BountyPaid(result.bountyId, result.solver, commitment_, result.resultDigest);
        emit SettlementRecorded(
            result.bountyId,
            digest,
            signerBitmap,
            _verifiers[signatures[0].verifierIndex],
            _verifiers[signatures[1].verifierIndex],
            bounty.reward,
            devFee,
            verifierShare,
            securityFee + verifierRemainder
        );
    }

    /// @notice Converts an expired open bounty into a pull credit for its immutable refund recipient.
    function refund(uint256 bountyId) external {
        Bounty storage bounty = bounties[bountyId];
        if (bounty.status != BountyStatus.Open) revert BountyNotOpen();
        if (block.timestamp < bounty.claimDeadline) revert RefundNotAvailable();

        bounty.status = BountyStatus.Refunded;
        totalEscrowed -= bounty.fundedAmount;
        totalClaimable += bounty.fundedAmount;
        claimable[bounty.refundRecipient] += bounty.fundedAmount;

        emit BountyRefunded(bountyId, bounty.refundRecipient, bounty.fundedAmount);
    }

    function withdraw(address destination, uint256 amount) external nonReentrant {
        if (destination == address(0) || destination == address(this) || (asset != address(0) && destination == asset)) revert InvalidAddress();
        if (amount == 0) revert NothingToWithdraw();
        uint256 available = claimable[msg.sender];
        if (amount > available) revert InsufficientClaimable();
        uint256 accountedBefore = accountedBalance();
        uint256 actualBefore = _assetBalance();
        if (actualBefore < accountedBefore) revert InsolventAsset(actualBefore, accountedBefore);

        claimable[msg.sender] = available - amount;
        totalClaimable -= amount;
        _sendAsset(destination, amount);
        uint256 accountedAfter = accountedBefore - amount;
        uint256 actualAfter = _assetBalance();
        if (actualAfter < accountedAfter) revert InsolventAsset(actualAfter, accountedAfter);

        emit Withdrawal(msg.sender, destination, amount);
    }

    function computeCommitment(uint256 bountyId, address solver, bytes32 resultDigest, bytes32 salt)
        external
        view
        returns (bytes32)
    {
        return _computeCommitment(bountyId, solver, resultDigest, salt);
    }

    function attestationDigest(Claim calldata result, uint8 signerBitmap) external view returns (bytes32) {
        Bounty storage bounty = bounties[result.bountyId];
        if (bounty.status == BountyStatus.None) revert InvalidBounty();
        if (!_isValidSignerBitmap(signerBitmap)) revert InvalidSignerBitmap();
        bytes32 commitment_ = _computeCommitment(result.bountyId, result.solver, result.resultDigest, result.salt);
        return _attestationDigest(result, bounty, commitment_, signerBitmap);
    }

    function minimumVerifierFee(uint256 reward) public pure returns (uint256) {
        uint256 percentageFloor = Math.mulDiv(reward, MIN_VERIFIER_BPS, BPS_DENOMINATOR);
        return percentageFloor > MIN_VERIFIER_FEE_UNITS ? percentageFloor : MIN_VERIFIER_FEE_UNITS;
    }

    function maximumVerifierFee(uint256 reward) public pure returns (uint256) {
        return reward;
    }

    function requiredFunding(uint256 reward, uint256 verifierFee) public pure returns (uint256) {
        (uint256 devFee,, uint256 securityFee) = feeBreakdown(reward, verifierFee);
        return reward + devFee + verifierFee + securityFee;
    }

    function feeBreakdown(uint256 reward, uint256 requestedVerifierFee)
        public
        pure
        returns (uint256 devFee, uint256 verifierFee, uint256 securityFee)
    {
        uint256 minimum = minimumVerifierFee(reward);
        uint256 maximum = maximumVerifierFee(reward);
        if (requestedVerifierFee < minimum || requestedVerifierFee > maximum) {
            revert InvalidVerifierFee(minimum, maximum, requestedVerifierFee);
        }
        devFee = Math.mulDiv(reward, DEVCO_BPS, BPS_DENOMINATOR);
        verifierFee = requestedVerifierFee;
        securityFee = Math.mulDiv(reward, SECURITY_BPS, BPS_DENOMINATOR);
    }

    function verifierCount() external pure returns (uint256) {
        return VERIFIER_COUNT;
    }

    function verifierAt(uint256 index) external view returns (address) {
        return _verifiers[index];
    }

    function getBounty(uint256 bountyId) external view returns (Bounty memory) {
        return bounties[bountyId];
    }

    function accountedBalance() public view returns (uint256) {
        return totalEscrowed + totalClaimable;
    }

    function actualBalance() public view returns (uint256) {
        return _assetBalance();
    }

    function isSolvent() public view returns (bool) {
        return _assetBalance() >= accountedBalance();
    }

    function surplus() external view returns (uint256) {
        uint256 balance = _assetBalance();
        uint256 accounted = accountedBalance();
        return balance > accounted ? balance - accounted : 0;
    }

    function _createBounty(address sponsor, BountyRequest calldata request, uint256 received)
        internal
        returns (uint256 bountyId)
    {
        if (
            sponsor == address(0) || request.refundRecipient == address(0) || request.refundRecipient == address(this)
                || (asset != address(0) && request.refundRecipient == asset) || request.reward < MIN_REWARD_UNITS
        ) {
            revert InvalidBounty();
        }
        if (
            request.profileId == bytes32(0) || request.specificationHash == bytes32(0)
                || request.termsHash == bytes32(0)
        ) revert InvalidHash();
        if (
            request.commitDeadline <= block.timestamp || request.claimDeadline <= request.commitDeadline
                || request.claimDeadline > block.timestamp + MAX_BOUNTY_DURATION
        ) revert InvalidDeadline();

        uint256 expected = requiredFunding(request.reward, request.verifierFee);
        if (received != expected) revert InvalidFunding(expected, received);

        bountyId = nextBountyId++;
        bounties[bountyId] = Bounty({
            sponsor: sponsor,
            refundRecipient: request.refundRecipient,
            winner: address(0),
            reward: request.reward,
            verifierFee: request.verifierFee,
            fundedAmount: expected,
            commitDeadline: request.commitDeadline,
            claimDeadline: request.claimDeadline,
            status: BountyStatus.Open,
            profileId: request.profileId,
            specificationHash: request.specificationHash,
            termsHash: request.termsHash,
            resultDigest: bytes32(0)
        });
        totalEscrowed += expected;

        emit BountyCreated(
            bountyId,
            sponsor,
            request.refundRecipient,
            asset,
            request.reward,
            request.verifierFee,
            expected,
            request.commitDeadline,
            request.claimDeadline,
            request.profileId,
            request.specificationHash,
            request.termsHash,
            verifierSetHash
        );
    }

    function _computeCommitment(uint256 bountyId, address solver, bytes32 resultDigest, bytes32 salt)
        internal
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(COMMITMENT_TYPEHASH, deploymentId, bountyId, solver, resultDigest, salt));
    }

    function _attestationDigest(Claim calldata result, Bounty storage bounty, bytes32 commitment_, uint8 signerBitmap)
        internal
        view
        returns (bytes32)
    {
        AcceptedResultData memory data;
        data.deploymentId = deploymentId;
        data.bountyId = result.bountyId;
        data.solver = result.solver;
        data.commitment = commitment_;
        data.resultDigest = result.resultDigest;
        data.reward = bounty.reward;
        data.verifierFee = bounty.verifierFee;
        data.profileId = bounty.profileId;
        data.specificationHash = bounty.specificationHash;
        data.termsHash = bounty.termsHash;
        data.verifierSetHash = verifierSetHash;
        data.signerBitmap = signerBitmap;
        data.claimDeadline = bounty.claimDeadline;
        bytes32 structHash = keccak256(abi.encode(ATTESTATION_TYPEHASH, data));
        return _hashTypedDataV4(structHash);
    }

    function _signerBitmap(uint8 firstIndex, uint8 secondIndex) internal pure returns (uint8 bitmap) {
        if (firstIndex >= secondIndex || secondIndex >= VERIFIER_COUNT) revert InvalidVerifierOrder();
        bitmap = uint8((uint256(1) << firstIndex) | (uint256(1) << secondIndex));
    }

    function _isValidSignerBitmap(uint8 bitmap) internal pure returns (bool) {
        return bitmap == 3 || bitmap == 5 || bitmap == 6;
    }

    function _assetBalance() internal view virtual returns (uint256);
    function _sendAsset(address destination, uint256 amount) internal virtual;
}
