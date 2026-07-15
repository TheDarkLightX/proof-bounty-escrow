// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {ProofBountyEscrowBase} from "./ProofBountyEscrowBase.sol";

/// @title ProofBountyEscrowNative
/// @notice Proof bounty escrow settled in the chain's native currency.
contract ProofBountyEscrowNative is ProofBountyEscrowBase {
    constructor(
        string memory protocolName,
        address devCo_,
        address securityReserve_,
        address[VERIFIER_COUNT] memory verifiers
    ) ProofBountyEscrowBase(protocolName, address(0), devCo_, securityReserve_, verifiers) {}

    function createBounty(BountyRequest calldata request) external payable nonReentrant returns (uint256 bountyId) {
        return _createBounty(msg.sender, request, msg.value);
    }

    receive() external payable {
        revert InvalidFunding(0, msg.value);
    }

    fallback() external payable {
        revert InvalidFunding(0, msg.value);
    }

    function _assetBalance() internal view override returns (uint256) {
        return address(this).balance;
    }

    function _sendAsset(address destination, uint256 amount) internal override {
        (bool success,) = payable(destination).call{value: amount}("");
        if (!success) revert AssetTransferFailed();
    }
}
