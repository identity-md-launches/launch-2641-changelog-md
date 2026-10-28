// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";

/// @title Changelog.md (CMD)
/// @notice Fixed-supply ERC-20. The constructor assigns the entire supply to its immediate caller.
/// @dev There are no privileged roles, post-construction mint/burn paths, fees, or external calls.
contract ChangelogToken is IERC20 {
    string public constant name = "Changelog.md";
    string public constant symbol = "CMD";
    uint8 public constant decimals = 18;
    uint256 public constant totalSupply = 1_000_000_000 * 10 ** 18;

    mapping(address account => uint256 balance) public balanceOf;
    mapping(address owner => mapping(address spender => uint256 value)) public allowance;

    // ERC-6093 ERC-20 errors.
    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);
    error ERC20InvalidSender(address sender);
    error ERC20InvalidReceiver(address receiver);
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);
    error ERC20InvalidApprover(address approver);
    error ERC20InvalidSpender(address spender);

    /// @dev No arguments or external initialization. During launch, msg.sender is the factory.
    constructor() {
        balanceOf[msg.sender] = totalSupply;
        emit Transfer(address(0), msg.sender, totalSupply);
    }

    /// @notice Transfer exactly value base units. Zero-value and self-transfers are supported.
    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    /// @notice Replace the caller's allowance for spender. Zero revokes it; uint256.max is unlimited.
    function approve(address spender, uint256 value) external returns (bool) {
        if (msg.sender == address(0)) revert ERC20InvalidApprover(address(0));
        if (spender == address(0)) revert ERC20InvalidSpender(address(0));
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    /// @notice Transfer using the caller's allowance. Unlimited allowances are not reduced.
    /// @dev Even the from address needs an allowance to use this method; holders can use transfer instead.
    /// Spending an allowance emits Transfer only. Any failure rolls back the allowance update as well.
    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 approved = allowance[from][msg.sender];
        if (approved != type(uint256).max) {
            if (approved < value) revert ERC20InsufficientAllowance(msg.sender, approved, value);
            unchecked {
                allowance[from][msg.sender] = approved - value;
            }
        }
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) private {
        if (from == address(0)) revert ERC20InvalidSender(address(0));
        if (to == address(0)) revert ERC20InvalidReceiver(address(0));

        uint256 balance = balanceOf[from];
        if (balance < value) revert ERC20InsufficientBalance(from, balance, value);
        unchecked {
            balanceOf[from] = balance - value;
        }
        // Read after debiting so self-transfers restore the original balance.
        balanceOf[to] += value;
        emit Transfer(from, to, value);
    }
}
