// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ProofBountyEscrowBase} from "../contracts/ProofBountyEscrowBase.sol";

/// @dev Shared configuration and audit logging for the two deployment scripts.
abstract contract DeploymentScriptBase is Script {
    struct CommonConfig {
        string protocolName;
        address devCo;
        address securityReserve;
        address[3] verifiers;
    }

    error UnexpectedChainId(uint256 expected, uint256 actual);

    function _loadCommonConfig() internal view returns (CommonConfig memory config) {
        uint256 expectedChainId = vm.envUint("EXPECTED_CHAIN_ID");
        if (block.chainid != expectedChainId) {
            revert UnexpectedChainId(expectedChainId, block.chainid);
        }

        config.protocolName = vm.envString("PROTOCOL_NAME");
        config.devCo = vm.envAddress("DEVCO");
        config.securityReserve = vm.envAddress("SECURITY_RESERVE");
        config.verifiers[0] = vm.envAddress("VERIFIER_0");
        config.verifiers[1] = vm.envAddress("VERIFIER_1");
        config.verifiers[2] = vm.envAddress("VERIFIER_2");
    }

    function _logDeployment(
        string memory variant,
        ProofBountyEscrowBase deployed,
        bytes32 creationCodeHash,
        bytes32 constructorArgumentsHash
    ) internal view {
        console2.log("deployment.variant", variant);
        console2.log("deployment.chainId", block.chainid);
        console2.log("deployment.contract", address(deployed));
        console2.log("deployment.asset", deployed.asset());
        console2.log("deployment.devCo", deployed.devCo());
        console2.log("deployment.securityReserve", deployed.securityReserve());
        console2.log("deployment.verifier[0]", deployed.verifierAt(0));
        console2.log("deployment.verifier[1]", deployed.verifierAt(1));
        console2.log("deployment.verifier[2]", deployed.verifierAt(2));
        console2.log("deployment.verifierThreshold", deployed.VERIFIER_THRESHOLD());
        console2.log("deployment.devCoBps", deployed.DEVCO_BPS());
        console2.log("deployment.securityBps", deployed.SECURITY_BPS());
        console2.log("deployment.fixedFeeBps", deployed.FIXED_FEE_BPS());
        console2.log("deployment.minimumVerifierBps", deployed.MIN_VERIFIER_BPS());
        console2.log("deployment.maximumVerifierBps", deployed.MAX_VERIFIER_BPS());
        console2.log("deployment.minimumRewardUnits", deployed.MIN_REWARD_UNITS());
        console2.log("deployment.minimumVerifierFeeUnits", deployed.MIN_VERIFIER_FEE_UNITS());
        console2.log("deployment.protocolVersion", deployed.PROTOCOL_VERSION());
        console2.log("deployment.protocolId");
        console2.logBytes32(deployed.PROTOCOL_ID());
        console2.log("deployment.deploymentId");
        console2.logBytes32(deployed.deploymentId());
        console2.log("deployment.verifierSetHash");
        console2.logBytes32(deployed.verifierSetHash());
        console2.log("deployment.creationCodeHash");
        console2.logBytes32(creationCodeHash);
        console2.log("deployment.constructorArgumentsHash");
        console2.logBytes32(constructorArgumentsHash);
        console2.log("deployment.runtimeCodeHash");
        console2.logBytes32(keccak256(address(deployed).code));
    }
}
