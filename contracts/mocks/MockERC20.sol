// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock Exact Token", "MET") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}
