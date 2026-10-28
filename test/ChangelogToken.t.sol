// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ChangelogToken} from "../src/ChangelogToken.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {TestBase} from "./support/TestBase.sol";

/// @dev A contract deployer models the launch factory without depending on launch infrastructure.
contract TokenFactoryHarness {
    function deploy() external returns (ChangelogToken) {
        return new ChangelogToken();
    }

    function move(IERC20 token, address recipient, uint256 amount) external {
        require(token.transfer(recipient, amount), "transfer failed");
    }
}

contract ChangelogTokenTest is TestBase {
    uint256 internal constant SUPPLY = 1_000_000_000_000_000_000_000_000_000;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant SPENDER = address(0x5EED);

    ChangelogToken internal token;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        token = new ChangelogToken();
    }

    function testMetadataAndInitialSupply() public view {
        assertEq(token.name(), "Changelog.md");
        assertEq(token.symbol(), "CMD");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.allowance(address(this), SPENDER), 0);
    }

    function testConstructorEmitsInitialAllocation() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), address(this), SUPPLY);
        ChangelogToken created = new ChangelogToken();
        assertEq(created.balanceOf(address(this)), SUPPLY);
        assertEq(created.totalSupply(), SUPPLY);
    }

    function testDirectDeploymentMintsToItsCaller() public {
        vm.prank(ALICE);
        ChangelogToken created = new ChangelogToken();
        assertEq(created.balanceOf(ALICE), SUPPLY);
        assertEq(created.balanceOf(address(this)), 0);
    }

    function testFactoryDeploymentMintsToFactory() public {
        TokenFactoryHarness factory = new TokenFactoryHarness();
        vm.prank(ALICE);
        ChangelogToken created = factory.deploy();
        assertEq(created.totalSupply(), SUPPLY);
        assertEq(created.balanceOf(address(factory)), SUPPLY);
        assertEq(created.balanceOf(ALICE), 0);
        assertEq(created.balanceOf(address(this)), 0);
    }

    function testLaunchAllocationAndClaimTransfersArriveWhole() public {
        TokenFactoryHarness factory = new TokenFactoryHarness();
        ChangelogToken created = factory.deploy();
        uint256 swarm = SUPPLY / 10;
        uint256 pool = SUPPLY * 8 / 10;
        factory.move(created, ALICE, swarm);
        factory.move(created, BOB, pool);
        factory.move(created, SPENDER, SUPPLY - swarm - pool);
        assertEq(created.balanceOf(address(factory)), 0);
        assertEq(created.balanceOf(ALICE), swarm);
        assertEq(created.balanceOf(BOB), pool);
        assertEq(created.balanceOf(SPENDER), SUPPLY / 10);

        // Claim and pool-like transfers use the same unrestricted ERC-20 path.
        vm.prank(ALICE);
        assertTrue(created.transfer(address(this), swarm));
        vm.prank(BOB);
        assertTrue(created.transfer(ALICE, 2 ether));
        vm.prank(ALICE);
        assertTrue(created.transfer(BOB, 2 ether));
        assertEq(created.balanceOf(address(this)), swarm);
        assertEq(created.balanceOf(ALICE), 0);
        assertEq(created.balanceOf(BOB), pool);
        assertEq(created.totalSupply(), SUPPLY);
    }

    function testTransferReturnsTrueAndEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), ALICE, 7 ether);
        assertTrue(token.transfer(ALICE, 7 ether));
        assertEq(token.balanceOf(address(this)), SUPPLY - 7 ether);
        assertEq(token.balanceOf(ALICE), 7 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testTransferEntireSupplyAndReturnIt() public {
        assertTrue(token.transfer(ALICE, SUPPLY));
        assertEq(token.balanceOf(address(this)), 0);
        vm.prank(ALICE);
        assertTrue(token.transfer(address(this), SUPPLY));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
    }

    function testZeroTransferFromEmptyAccountEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(ALICE, BOB, 0);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 0));
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 0);
    }

    function testSelfTransferPreservesBalance() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), address(this), SUPPLY);
        assertTrue(token.transfer(address(this), SUPPLY));
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function testTransferToContractRequiresNoCallback() public {
        TokenFactoryHarness recipient = new TokenFactoryHarness();
        assertTrue(token.transfer(address(recipient), 1 ether));
        assertEq(token.balanceOf(address(recipient)), 1 ether);
    }

    function testTransferAboveBalanceRevertsWithoutChanges() public {
        token.transfer(ALICE, 10);
        vm.expectRevert(
            abi.encodeWithSelector(ChangelogToken.ERC20InsufficientBalance.selector, ALICE, 10, 11)
        );
        vm.prank(ALICE);
        token.transfer(BOB, 11);
        assertEq(token.balanceOf(ALICE), 10);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testSelfTransferStillRequiresBalance() public {
        vm.expectRevert(abi.encodeWithSelector(ChangelogToken.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transfer(ALICE, 1);
    }

    function testTransferMaximumUintRevertsWithoutOverflow() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ChangelogToken.ERC20InsufficientBalance.selector, address(this), SUPPLY, type(uint256).max
            )
        );
        token.transfer(ALICE, type(uint256).max);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function testTransferToZeroRevertsEvenForZeroValue() public {
        vm.expectRevert(abi.encodeWithSelector(ChangelogToken.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(ChangelogToken.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
    }

    function testTransferFromZeroSenderReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ChangelogToken.ERC20InvalidSender.selector, address(0)));
        vm.prank(address(0));
        token.transfer(ALICE, 0);
    }

    function testApproveEmitsEventAndDoesNotMoveBalances() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(address(this), SPENDER, 12 ether);
        assertTrue(token.approve(SPENDER, 12 ether));
        assertEq(token.allowance(address(this), SPENDER), 12 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(SPENDER), 0);
    }

    function testApprovalReplacesRatherThanAdds() public {
        token.approve(SPENDER, 100);
        assertTrue(token.approve(SPENDER, 7));
        assertEq(token.allowance(address(this), SPENDER), 7);
    }

    function testApprovalBelongsOnlyToItsCaller() public {
        token.approve(SPENDER, 100);
        vm.prank(ALICE);
        token.approve(SPENDER, 200);
        assertEq(token.allowance(address(this), SPENDER), 100);
        assertEq(token.allowance(ALICE, SPENDER), 200);
        assertEq(token.allowance(BOB, SPENDER), 0);
    }

    function testRevokeApprovalPreventsFurtherSpending() public {
        token.approve(SPENDER, 100);
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(address(this), SPENDER, 0);
        token.approve(SPENDER, 0);
        vm.expectRevert(
            abi.encodeWithSelector(ChangelogToken.ERC20InsufficientAllowance.selector, SPENDER, 0, 1)
        );
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function testApproveZeroSpenderReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ChangelogToken.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(ChangelogToken.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 0);
    }

    function testApproveZeroApproverReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ChangelogToken.ERC20InvalidApprover.selector, address(0)));
        vm.prank(address(0));
        token.approve(SPENDER, 1);
    }

    function testTransferFromSpendsAllowanceAndEmitsTransfer() public {
        token.approve(SPENDER, 10 ether);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), ALICE, 4 ether);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(address(this), ALICE, 4 ether));
        assertEq(token.allowance(address(this), SPENDER), 6 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 4 ether);
        assertEq(token.balanceOf(ALICE), 4 ether);
        assertEq(token.balanceOf(SPENDER), 0);
    }

    function testTransferFromExactAllowanceExhaustsIt() public {
        token.approve(SPENDER, SUPPLY);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(address(this), ALICE, SUPPLY));
        assertEq(token.allowance(address(this), SPENDER), 0);
        assertEq(token.balanceOf(ALICE), SUPPLY);
        vm.expectRevert(
            abi.encodeWithSelector(ChangelogToken.ERC20InsufficientAllowance.selector, SPENDER, 0, 1)
        );
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 1);
    }

    function testUnlimitedAllowanceIsNotReduced() public {
        token.approve(SPENDER, type(uint256).max);
        vm.startPrank(SPENDER);
        assertTrue(token.transferFrom(address(this), ALICE, 1 ether));
        assertTrue(token.transferFrom(address(this), BOB, 2 ether));
        vm.stopPrank();
        assertEq(token.allowance(address(this), SPENDER), type(uint256).max);
        assertEq(token.balanceOf(ALICE), 1 ether);
        assertEq(token.balanceOf(BOB), 2 ether);
    }

    function testDelegatedSelfTransferConsumesAllowanceOnly() public {
        token.approve(SPENDER, 10);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(address(this), address(this), 4));
        assertEq(token.allowance(address(this), SPENDER), 6);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function testTransferFromZeroValueNeedsNoAllowance() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(ALICE, BOB, 0);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(ALICE, BOB, 0));
        assertEq(token.allowance(ALICE, SPENDER), 0);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 0);
    }

    function testUnapprovedSpenderCannotMoveTokens() public {
        token.approve(SPENDER, 10);
        vm.expectRevert(abi.encodeWithSelector(ChangelogToken.ERC20InsufficientAllowance.selector, BOB, 0, 1));
        vm.prank(BOB);
        token.transferFrom(address(this), BOB, 1);
        assertEq(token.allowance(address(this), SPENDER), 10);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function testHolderNeedsAllowanceForTransferFrom() public {
        vm.expectRevert(
            abi.encodeWithSelector(ChangelogToken.ERC20InsufficientAllowance.selector, address(this), 0, 1)
        );
        token.transferFrom(address(this), ALICE, 1);
        token.approve(address(this), 1);
        assertTrue(token.transferFrom(address(this), ALICE, 1));
    }

    function testDeployerCannotMoveOtherHoldersTokensWithoutApproval() public {
        token.transfer(ALICE, 100);
        vm.expectRevert(
            abi.encodeWithSelector(ChangelogToken.ERC20InsufficientAllowance.selector, address(this), 0, 1)
        );
        token.transferFrom(ALICE, address(this), 1);
        assertEq(token.balanceOf(ALICE), 100);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 100));
    }

    function testTransferFromAboveAllowanceRevertsAtomically() public {
        token.approve(SPENDER, 10);
        vm.expectRevert(
            abi.encodeWithSelector(ChangelogToken.ERC20InsufficientAllowance.selector, SPENDER, 10, 11)
        );
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 11);
        assertEq(token.allowance(address(this), SPENDER), 10);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
    }

    function testTransferFromAboveBalanceRestoresFiniteAllowance() public {
        token.transfer(ALICE, 10);
        vm.prank(ALICE);
        token.approve(SPENDER, 100);
        vm.expectRevert(
            abi.encodeWithSelector(ChangelogToken.ERC20InsufficientBalance.selector, ALICE, 10, 11)
        );
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 11);
        assertEq(token.allowance(ALICE, SPENDER), 100);
        assertEq(token.balanceOf(ALICE), 10);
        assertEq(token.balanceOf(BOB), 0);
    }

    function testTransferFromToZeroRestoresAllowance() public {
        token.approve(SPENDER, 10);
        vm.expectRevert(abi.encodeWithSelector(ChangelogToken.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(SPENDER);
        token.transferFrom(address(this), address(0), 10);
        assertEq(token.allowance(address(this), SPENDER), 10);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function testTransferFromZeroAddressesRejectsZeroValue() public {
        vm.expectRevert(abi.encodeWithSelector(ChangelogToken.ERC20InvalidSender.selector, address(0)));
        token.transferFrom(address(0), ALICE, 0);
        vm.expectRevert(abi.encodeWithSelector(ChangelogToken.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(ALICE, address(0), 0);
    }

    function testTransferFromMaximumValueCannotDrainOrOverflow() public {
        token.approve(SPENDER, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                ChangelogToken.ERC20InsufficientBalance.selector, address(this), SUPPLY, type(uint256).max
            )
        );
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, type(uint256).max);
        assertEq(token.allowance(address(this), SPENDER), type(uint256).max);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function testNoMintBurnAdminOrUpgradeEntryPoints() public {
        token.transfer(ALICE, 100);
        string[22] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "owner()",
            "transferOwnership(address)",
            "setOwner(address)",
            "setMinter(address)",
            "initialize(address)",
            "upgradeTo(address)",
            "upgradeToAndCall(address,bytes)",
            "pause()",
            "unpause()",
            "blacklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "lock(address)",
            "seize(address)",
            "disableTransfers()"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ALICE, uint256(1));
            (bool deployerSuccess,) = address(token).call(data);
            assertFalse(deployerSuccess);
            vm.prank(BOB);
            (bool strangerSuccess,) = address(token).call(data);
            assertFalse(strangerSuccess);
            assertEq(token.totalSupply(), SUPPLY);
            assertEq(token.balanceOf(ALICE), 100);
            assertEq(token.balanceOf(BOB), 0);
        }
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 100));
    }

    function testRejectsEtherAndUnknownSelectors() public {
        vm.deal(address(this), 1 ether);
        (bool received,) = address(token).call{value: 1 wei}("");
        assertFalse(received);
        (bool payableTransfer,) =
            address(token).call{value: 1 wei}(abi.encodeCall(IERC20.transfer, (ALICE, 1)));
        assertFalse(payableTransfer);
        (bool unknown,) = address(token).call(hex"ffffffff");
        assertFalse(unknown);
        assertEq(address(token).balance, 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }
}
