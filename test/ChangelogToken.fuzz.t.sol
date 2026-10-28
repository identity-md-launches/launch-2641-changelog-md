// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ChangelogToken} from "../src/ChangelogToken.sol";
import {TestBase} from "./support/TestBase.sol";

contract ChangelogTokenFuzzTest is TestBase {
    uint256 internal constant SUPPLY = 1_000_000_000 * 1e18;
    address internal constant SPENDER = address(0x5EED);
    address internal constant HOLDER = address(0xA11CE);
    ChangelogToken internal token;

    function setUp() public {
        token = new ChangelogToken();
    }

    function testFuzz_TransferConservesSupply(address recipient, uint256 rawAmount) public {
        uint256 amount = rawAmount % (SUPPLY + 1);
        if (recipient == address(0)) {
            vm.expectRevert(abi.encodeWithSelector(ChangelogToken.ERC20InvalidReceiver.selector, address(0)));
            token.transfer(recipient, amount);
            assertEq(token.balanceOf(address(this)), SUPPLY);
        } else {
            assertTrue(token.transfer(recipient, amount));
            if (recipient == address(this)) {
                assertEq(token.balanceOf(address(this)), SUPPLY);
            } else {
                assertEq(token.balanceOf(address(this)), SUPPLY - amount);
                assertEq(token.balanceOf(recipient), amount);
            }
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
    }

    function testFuzz_ApprovalReplacementAndIsolation(address spender, uint256 first, uint256 second) public {
        if (spender == address(0)) {
            vm.expectRevert(abi.encodeWithSelector(ChangelogToken.ERC20InvalidSpender.selector, address(0)));
            token.approve(spender, first);
            assertEq(token.allowance(address(this), spender), 0);
        } else {
            assertTrue(token.approve(spender, first));
            assertEq(token.allowance(address(this), spender), first);
            assertTrue(token.approve(spender, second));
            assertEq(token.allowance(address(this), spender), second);
            assertEq(token.allowance(HOLDER, spender), 0);
        }
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_DelegatedTransferAccounting(uint256 rawAmount, uint256 rawExtra, bool unlimited)
        public
    {
        uint256 amount = rawAmount % (SUPPLY + 1);
        uint256 approved = unlimited ? type(uint256).max : amount + rawExtra % (SUPPLY - amount + 1);
        token.approve(SPENDER, approved);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(address(this), HOLDER, amount));
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.balanceOf(HOLDER), amount);
        assertEq(token.allowance(address(this), SPENDER), unlimited ? approved : approved - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_SpendingAboveAllowanceAlwaysReverts(uint256 rawApproved) public {
        uint256 approved = rawApproved % (SUPPLY + 1);
        token.approve(SPENDER, approved);
        vm.expectRevert(
            abi.encodeWithSelector(
                ChangelogToken.ERC20InsufficientAllowance.selector, SPENDER, approved, approved + 1
            )
        );
        vm.prank(SPENDER);
        token.transferFrom(address(this), HOLDER, approved + 1);
        assertEq(token.allowance(address(this), SPENDER), approved);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(HOLDER), 0);
    }

    function testFuzz_SpendingAboveBalanceAlwaysReverts(uint256 rawBalance, uint256 rawExcess) public {
        uint256 balance = rawBalance % (SUPPLY + 1);
        uint256 amount = balance + 1 + rawExcess % (type(uint256).max - balance);
        token.transfer(HOLDER, balance);
        vm.prank(HOLDER);
        token.approve(SPENDER, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(ChangelogToken.ERC20InsufficientBalance.selector, HOLDER, balance, amount)
        );
        vm.prank(SPENDER);
        token.transferFrom(HOLDER, SPENDER, amount);
        assertEq(token.allowance(HOLDER, SPENDER), type(uint256).max);
        assertEq(token.balanceOf(HOLDER), balance);
        assertEq(token.balanceOf(address(this)), SUPPLY - balance);
        assertEq(token.balanceOf(SPENDER), 0);
    }

    function testFuzz_FailedTransferToZeroRestoresAllowance(uint256 rawAmount) public {
        uint256 amount = rawAmount % (SUPPLY + 1);
        token.approve(SPENDER, amount);
        vm.expectRevert(abi.encodeWithSelector(ChangelogToken.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(SPENDER);
        token.transferFrom(address(this), address(0), amount);
        assertEq(token.allowance(address(this), SPENDER), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
    }
}
