// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {ProofBountyEscrowBase} from "../contracts/ProofBountyEscrowBase.sol";
import {ProofBountyEscrowNative} from "../contracts/ProofBountyEscrowNative.sol";
import {ProofBountyEscrowERC20} from "../contracts/ProofBountyEscrowERC20.sol";
import {DeploymentScriptBase} from "./DeploymentScriptBase.sol";

/// @notice Replays immutable configuration and an independently supplied runtime hash.
/// @dev TOKEN must be the zero address for a native deployment and the token for ERC-20.
contract AuditDeployment is DeploymentScriptBase {
    error DeploymentNotFound(address deployment);
    error ConfigurationMismatch(bytes32 field);

    function run() external view {
        CommonConfig memory config = _loadCommonConfig();
        address deployment = vm.envAddress("DEPLOYMENT");
        address expectedAsset = vm.envAddress("TOKEN");
        bytes32 expectedRuntimeCodeHash = vm.envBytes32("EXPECTED_RUNTIME_CODE_HASH");
        if (deployment.code.length == 0) revert DeploymentNotFound(deployment);
        _assertBytes32("runtimeCodeHash", expectedRuntimeCodeHash, keccak256(deployment.code));

        ProofBountyEscrowBase escrow = ProofBountyEscrowBase(deployment);
        _assertAddress("asset", expectedAsset, escrow.asset());
        _assertAddress("devCo", config.devCo, escrow.devCo());
        _assertAddress("securityReserve", config.securityReserve, escrow.securityReserve());
        _assertAddress("verifier[0]", config.verifiers[0], escrow.verifierAt(0));
        _assertAddress("verifier[1]", config.verifiers[1], escrow.verifierAt(1));
        _assertAddress("verifier[2]", config.verifiers[2], escrow.verifierAt(2));
        _assertUint("devCoBps", 200, escrow.DEVCO_BPS());
        _assertUint("securityBps", 50, escrow.SECURITY_BPS());
        _assertUint("fixedFeeBps", 250, escrow.FIXED_FEE_BPS());
        _assertUint("minimumVerifierBps", 50, escrow.MIN_VERIFIER_BPS());
        _assertUint("maximumVerifierBps", 10_000, escrow.MAX_VERIFIER_BPS());
        _assertUint("minimumRewardUnits", 2, escrow.MIN_REWARD_UNITS());
        _assertUint("minimumVerifierFeeUnits", 2, escrow.MIN_VERIFIER_FEE_UNITS());
        _assertUint("minimumVerifierFeeDustProbe", 2, escrow.minimumVerifierFee(199));
        _assertUint("minimumVerifierFeeProbe", 51, escrow.minimumVerifierFee(10_200));
        _assertUint("maximumVerifierFeeProbe", 10_200, escrow.maximumVerifierFee(10_200));
        _assertUint("requiredFundingProbe", 20_655, escrow.requiredFunding(10_200, 10_200));

        bytes32 expectedVerifierSetHash = keccak256(abi.encode(config.verifiers, uint8(2)));
        _assertBytes32("verifierSetHash", expectedVerifierSetHash, escrow.verifierSetHash());

        bytes32 expectedDeploymentId = keccak256(
            abi.encode(
                escrow.PROTOCOL_ID(),
                keccak256(bytes(config.protocolName)),
                block.chainid,
                deployment,
                expectedAsset,
                config.devCo,
                config.securityReserve,
                expectedVerifierSetHash
            )
        );
        _assertBytes32("deploymentId", expectedDeploymentId, escrow.deploymentId());

        bool isNative = expectedAsset == address(0);
        bytes32 constructorArgumentsHash = isNative
            ? keccak256(abi.encode(config.protocolName, config.devCo, config.securityReserve, config.verifiers))
            : keccak256(
                abi.encode(config.protocolName, expectedAsset, config.devCo, config.securityReserve, config.verifiers)
            );
        bytes32 creationCodeHash = isNative
            ? keccak256(type(ProofBountyEscrowNative).creationCode)
            : keccak256(type(ProofBountyEscrowERC20).creationCode);
        _logDeployment(isNative ? "native" : "erc20", escrow, creationCodeHash, constructorArgumentsHash);
    }

    function _assertAddress(bytes32 field, address expected, address actual) private pure {
        if (expected != actual) revert ConfigurationMismatch(field);
    }

    function _assertBytes32(bytes32 field, bytes32 expected, bytes32 actual) private pure {
        if (expected != actual) revert ConfigurationMismatch(field);
    }

    function _assertUint(bytes32 field, uint256 expected, uint256 actual) private pure {
        if (expected != actual) revert ConfigurationMismatch(field);
    }
}
