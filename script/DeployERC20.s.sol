// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProofBountyEscrowERC20} from "../contracts/ProofBountyEscrowERC20.sol";
import {DeploymentScriptBase} from "./DeploymentScriptBase.sol";

/// @notice Deploys one immutable, single-token escrow on the selected EVM chain.
contract DeployERC20 is DeploymentScriptBase {
    function run() external returns (ProofBountyEscrowERC20 deployed) {
        CommonConfig memory config = _loadCommonConfig();
        IERC20 token = IERC20(vm.envAddress("TOKEN"));
        bytes32 constructorArgumentsHash =
            keccak256(abi.encode(config.protocolName, token, config.devCo, config.securityReserve, config.verifiers));

        vm.startBroadcast();
        deployed = new ProofBountyEscrowERC20(
            config.protocolName, token, config.devCo, config.securityReserve, config.verifiers
        );
        vm.stopBroadcast();

        _logDeployment(
            "erc20", deployed, keccak256(type(ProofBountyEscrowERC20).creationCode), constructorArgumentsHash
        );
    }
}
