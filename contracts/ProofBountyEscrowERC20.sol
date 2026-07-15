// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ProofBountyEscrowBase} from "./ProofBountyEscrowBase.sol";

/// @title ProofBountyEscrowERC20
/// @notice Single-asset proof bounty escrow for a vetted, exact-transfer ERC-20 token.
/// @dev Fee-on-transfer, rebasing, callback-bearing, and deceptive balanceOf tokens are outside the profile.
contract ProofBountyEscrowERC20 is ProofBountyEscrowBase {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;

    error UnsupportedTokenBehavior();

    constructor(
        string memory protocolName,
        IERC20 token_,
        address devCo_,
        address securityReserve_,
        address[VERIFIER_COUNT] memory verifiers
    ) ProofBountyEscrowBase(protocolName, address(token_), devCo_, securityReserve_, verifiers) {
        if (address(token_) == address(0) || address(token_).code.length == 0) revert InvalidAddress();
        token = token_;
    }

    function createBounty(BountyRequest calldata request) external nonReentrant returns (uint256 bountyId) {
        uint256 expected = requiredFunding(request.reward, request.verifierFee);
        uint256 accountedBefore = accountedBalance();
        uint256 beforeBalance = token.balanceOf(address(this));
        if (beforeBalance < accountedBefore) revert InsolventAsset(beforeBalance, accountedBefore);
        token.safeTransferFrom(msg.sender, address(this), expected);
        uint256 afterBalance = token.balanceOf(address(this));
        if (
            afterBalance < beforeBalance || afterBalance - beforeBalance != expected
                || afterBalance < accountedBefore + expected
        ) {
            revert UnsupportedTokenBehavior();
        }
        return _createBounty(msg.sender, request, expected);
    }

    function _assetBalance() internal view override returns (uint256) {
        return token.balanceOf(address(this));
    }

    function _sendAsset(address destination, uint256 amount) internal override {
        if (destination == address(this)) revert InvalidAddress();
        uint256 contractBefore = token.balanceOf(address(this));
        uint256 destinationBefore = token.balanceOf(destination);
        token.safeTransfer(destination, amount);
        uint256 contractAfter = token.balanceOf(address(this));
        uint256 destinationAfter = token.balanceOf(destination);
        if (
            contractAfter > contractBefore || contractBefore - contractAfter != amount
                || destinationAfter < destinationBefore || destinationAfter - destinationBefore != amount
        ) revert UnsupportedTokenBehavior();
    }
}
