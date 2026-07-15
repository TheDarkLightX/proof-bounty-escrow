// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Test-only ERC-20 that can violate return-value and exact-transfer assumptions,
///      or perform an ERC-777-style callback during transfer hooks.
contract AdversarialERC20 is ERC20 {
    enum Behavior {
        Exact,
        ReturnFalseBeforeTransfer,
        ReturnFalseAfterTransfer,
        ShortTransfer
    }

    Behavior public behavior;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackOnTransfer;
    bool public callbackOnTransferFrom;
    bool public callbackAttempted;
    bool public callbackSucceeded;
    bytes public callbackReturnData;

    bool private _insideCallback;

    constructor() ERC20("Adversarial Token", "ADV") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function setBehavior(Behavior behavior_) external {
        behavior = behavior_;
    }

    function configureCallback(address target, bytes calldata data, bool onTransfer, bool onTransferFrom) external {
        callbackTarget = target;
        callbackData = data;
        callbackOnTransfer = onTransfer;
        callbackOnTransferFrom = onTransferFrom;
        callbackAttempted = false;
        callbackSucceeded = false;
        delete callbackReturnData;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (behavior == Behavior.ReturnFalseBeforeTransfer) return false;

        _adversarialTransfer(_msgSender(), to, value);
        if (callbackOnTransfer) _callback();

        return behavior != Behavior.ReturnFalseAfterTransfer;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        _spendAllowance(from, _msgSender(), value);
        if (behavior == Behavior.ReturnFalseBeforeTransfer) return false;

        _adversarialTransfer(from, to, value);
        if (callbackOnTransferFrom) _callback();

        return behavior != Behavior.ReturnFalseAfterTransfer;
    }

    function _adversarialTransfer(address from, address to, uint256 value) internal {
        if (behavior == Behavior.ShortTransfer && value != 0) {
            _transfer(from, to, value - 1);
            _burn(from, 1);
        } else {
            _transfer(from, to, value);
        }
    }

    function _callback() internal {
        if (_insideCallback || callbackTarget == address(0)) return;

        _insideCallback = true;
        callbackAttempted = true;
        (callbackSucceeded, callbackReturnData) = callbackTarget.call(callbackData);
        _insideCallback = false;
    }
}
