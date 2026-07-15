// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

contract RevertingReceiver {
    receive() external payable {
        revert("reject native currency");
    }
}
