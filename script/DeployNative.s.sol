// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {ProofBountyEscrowNative} from "../contracts/ProofBountyEscrowNative.sol";
import {DeploymentScriptBase} from "./DeploymentScriptBase.sol";

/// @notice Deploys one immutable native-currency escrow on the selected EVM chain.
contract DeployNative is DeploymentScriptBase {
    function run() external returns (ProofBountyEscrowNative deployed) {
        CommonConfig memory config = _loadCommonConfig();
        bytes32 constructorArgumentsHash =
            keccak256(abi.encode(config.protocolName, config.devCo, config.securityReserve, config.verifiers));

        vm.startBroadcast();
        deployed =
            new ProofBountyEscrowNative(config.protocolName, config.devCo, config.securityReserve, config.verifiers);
        vm.stopBroadcast();

        _logDeployment(
            "native", deployed, keccak256(type(ProofBountyEscrowNative).creationCode), constructorArgumentsHash
        );
    }
}
