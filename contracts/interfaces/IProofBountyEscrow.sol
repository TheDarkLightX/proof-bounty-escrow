// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

interface IProofBountyEscrow {
    enum BountyStatus {
        None,
        Open,
        Paid,
        Refunded
    }

    struct Bounty {
        address sponsor;
        address refundRecipient;
        address winner;
        uint256 reward;
        uint256 verifierFee;
        uint256 fundedAmount;
        uint64 commitDeadline;
        uint64 claimDeadline;
        BountyStatus status;
        bytes32 profileId;
        bytes32 specificationHash;
        bytes32 termsHash;
        bytes32 resultDigest;
    }

    struct BountyRequest {
        address refundRecipient;
        uint256 reward;
        uint256 verifierFee;
        uint64 commitDeadline;
        uint64 claimDeadline;
        bytes32 profileId;
        bytes32 specificationHash;
        bytes32 termsHash;
    }

    struct Claim {
        uint256 bountyId;
        address solver;
        bytes32 resultDigest;
        bytes32 salt;
    }

    struct VerifierSignature {
        uint8 verifierIndex;
        bytes signature;
    }

    event BountyCreated(
        uint256 indexed bountyId,
        address indexed sponsor,
        address indexed refundRecipient,
        address asset,
        uint256 reward,
        uint256 verifierFee,
        uint256 fundedAmount,
        uint64 commitDeadline,
        uint64 claimDeadline,
        bytes32 profileId,
        bytes32 specificationHash,
        bytes32 termsHash,
        bytes32 verifierSetHash
    );

    event SolverCommitted(uint256 indexed bountyId, address indexed solver, bytes32 indexed commitment);
    event BountyPaid(
        uint256 indexed bountyId, address indexed solver, bytes32 indexed commitment, bytes32 resultDigest
    );
    event SettlementRecorded(
        uint256 indexed bountyId,
        bytes32 indexed attestationDigest,
        uint8 signerBitmap,
        address verifierA,
        address verifierB,
        uint256 solverReward,
        uint256 devFee,
        uint256 verifierShare,
        uint256 securityCredit
    );
    event BountyRefunded(uint256 indexed bountyId, address indexed refundRecipient, uint256 amount);
    event Withdrawal(address indexed account, address indexed destination, uint256 amount);

    function commit(uint256 bountyId, bytes32 commitment) external;
    function claim(Claim calldata result, VerifierSignature[2] calldata signatures) external;
    function refund(uint256 bountyId) external;
    function withdraw(address destination, uint256 amount) external;

    function computeCommitment(uint256 bountyId, address solver, bytes32 resultDigest, bytes32 salt)
        external
        view
        returns (bytes32);

    function attestationDigest(Claim calldata result, uint8 signerBitmap) external view returns (bytes32);
    function minimumVerifierFee(uint256 reward) external view returns (uint256);
    function maximumVerifierFee(uint256 reward) external view returns (uint256);
    function requiredFunding(uint256 reward, uint256 verifierFee) external view returns (uint256);
    function getBounty(uint256 bountyId) external view returns (Bounty memory);
}
