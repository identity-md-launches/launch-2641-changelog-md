// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ChangelogToken} from "../src/ChangelogToken.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {TestBase} from "./support/TestBase.sol";

/// @notice Stateful model-based fuzzing over sequences of transfers, approvals, and delegated transfers.
/// @dev An independent ledger tracks every holder and allowance, including failed calls and aliases.
contract ChangelogTokenModelTest is TestBase {
    uint256 internal constant SUPPLY = 1_000_000_000 * 1e18;
    ChangelogToken internal token;
    address[4] internal actors;
    uint256[4] internal balances;
    uint256[4][4] internal approvals;

    function setUp() public {
        token = new ChangelogToken();
        actors = [address(this), address(0xA11CE), address(0xB0B), address(0xCA401)];
        balances[0] = SUPPLY;
    }

    function testFuzz_StatefulLedgerMatchesEveryOperation(uint256[48] memory steps) public {
        for (uint256 i; i < steps.length; ++i) {
            uint256 seed = steps[i];
            uint256 caller = (seed >> 2) % 4;
            uint256 from = (seed >> 4) % 4;
            uint256 to = (seed >> 6) % 4;
            uint256 action = seed % 3;
            uint256 amount = _amount(seed, action == 2 ? from : caller);
            if (action == 0) {
                _transfer(caller, to, amount);
            } else if (action == 1) {
                _approve(caller, to, amount);
            } else {
                _transferFrom(caller, from, to, amount);
            }
            _assertModel();
        }
    }

    function _amount(uint256 seed, uint256 from) private view returns (uint256) {
        uint256 mode = (seed >> 8) % 6;
        if (mode == 0) return 0;
        if (mode == 1) return balances[from];
        if (mode == 2) return balances[from] + 1;
        if (mode == 3) return (seed >> 16) % (SUPPLY + 1);
        if (mode == 4) return type(uint256).max;
        return 1;
    }

    function _transfer(uint256 from, uint256 to, uint256 amount) private {
        bool expected = amount <= balances[from];
        vm.prank(actors[from]);
        (bool success, bytes memory data) =
            address(token).call(abi.encodeCall(IERC20.transfer, (actors[to], amount)));
        assertTrue(success == expected);
        if (success) {
            assertTrue(abi.decode(data, (bool)));
            balances[from] -= amount;
            balances[to] += amount;
        } else {
            assertTrue(
                keccak256(data)
                    == keccak256(
                        abi.encodeWithSelector(
                            ChangelogToken.ERC20InsufficientBalance.selector,
                            actors[from],
                            balances[from],
                            amount
                        )
                    )
            );
        }
    }

    function _approve(uint256 from, uint256 spender, uint256 amount) private {
        vm.prank(actors[from]);
        assertTrue(token.approve(actors[spender], amount));
        approvals[from][spender] = amount;
    }

    function _transferFrom(uint256 caller, uint256 from, uint256 to, uint256 amount) private {
        uint256 approved = approvals[from][caller];
        bool allowed = approved >= amount;
        bool expected = allowed && balances[from] >= amount;
        vm.prank(actors[caller]);
        (bool success, bytes memory data) =
            address(token).call(abi.encodeCall(IERC20.transferFrom, (actors[from], actors[to], amount)));
        assertTrue(success == expected);
        if (success) {
            assertTrue(abi.decode(data, (bool)));
            if (approved != type(uint256).max) approvals[from][caller] -= amount;
            balances[from] -= amount;
            balances[to] += amount;
        } else {
            bytes memory expectedError = !allowed
                ? abi.encodeWithSelector(
                    ChangelogToken.ERC20InsufficientAllowance.selector, actors[caller], approved, amount
                )
                : abi.encodeWithSelector(
                    ChangelogToken.ERC20InsufficientBalance.selector, actors[from], balances[from], amount
                );
            assertTrue(keccak256(data) == keccak256(expectedError));
        }
    }

    function _assertModel() private view {
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            assertEq(token.balanceOf(actors[i]), balances[i]);
            sum += token.balanceOf(actors[i]);
            for (uint256 j; j < actors.length; ++j) {
                assertEq(token.allowance(actors[i], actors[j]), approvals[i][j]);
            }
        }
        assertEq(sum, SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0);
    }
}
