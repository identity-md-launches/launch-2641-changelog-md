// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ChangelogToken} from "../src/ChangelogToken.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {TestBase} from "./support/TestBase.sol";

/// @dev Models ProjectFactory.launchCustom: deploys by CREATE2 and splits the supply in the same call,
/// so the test sees what one launch transaction would.
contract LaunchFactoryModel {
    struct Result {
        address token;
        uint256 supplyAtDeploy;
        uint256 factoryBalanceAtDeploy;
    }

    function launch(bytes32 salt, address distributor, address pool, uint256 poolBps, address remainderTo)
        external
        returns (Result memory result)
    {
        ChangelogToken token = new ChangelogToken{salt: salt}();
        result.token = address(token);
        result.supplyAtDeploy = token.totalSupply();
        result.factoryBalanceAtDeploy = token.balanceOf(address(this));

        uint256 supply = result.supplyAtDeploy;
        uint256 swarm = supply / 10;
        uint256 seed = supply * poolBps / 10_000;
        require(token.transfer(distributor, swarm), "swarm transfer");
        require(token.balanceOf(distributor) == swarm, "swarm arrived short");
        // The pool pulls the seed through an allowance, as a settlement contract would.
        require(token.approve(pool, seed), "approve pool");
        PoolModel(pool).pull(token, seed);
        require(token.balanceOf(pool) == seed, "seed arrived short");
        require(token.allowance(address(this), pool) == 0, "seed allowance not consumed");
        uint256 rest = token.balanceOf(address(this));
        require(token.transfer(remainderTo, rest), "remainder transfer");
        require(token.balanceOf(address(this)) == 0, "factory kept tokens");
    }

    function predict(bytes32 salt) external view returns (address) {
        bytes32 hash = keccak256(
            abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(type(ChangelogToken).creationCode))
        );
        return address(uint160(uint256(hash)));
    }
}

/// @dev Stands in for a pool: pulls a payer's tokens with transferFrom and pays them out with transfer.
contract PoolModel {
    function pull(IERC20 token, uint256 amount) external {
        uint256 before = token.balanceOf(address(this));
        require(token.transferFrom(msg.sender, address(this), amount), "pull returned false");
        require(token.balanceOf(address(this)) - before == amount, "pull arrived short");
    }

    function pay(IERC20 token, address to, uint256 amount) external {
        uint256 before = token.balanceOf(to);
        require(token.transfer(to, amount), "pay returned false");
        require(token.balanceOf(to) - before == amount, "payment arrived short");
    }
}

contract ChangelogTokenLaunchTest is TestBase {
    uint256 internal constant SUPPLY = 1_000_000_000 * 1e18;
    address internal constant DISTRIBUTOR = address(0xD157);
    address internal constant REQUESTER = address(0x2E9E);
    address internal constant TRADER = address(0x7EAD);

    LaunchFactoryModel internal factory;
    PoolModel internal pool;

    function setUp() public {
        factory = new LaunchFactoryModel();
        pool = new PoolModel();
    }

    function testLaunchInOneCallMovesExactAmounts() public {
        LaunchFactoryModel.Result memory r =
            factory.launch(bytes32(uint256(1)), DISTRIBUTOR, address(pool), 6_000, REQUESTER);
        IERC20 token = IERC20(r.token);
        assertEq(r.token, factory.predict(bytes32(uint256(1))));
        assertEq(r.supplyAtDeploy, SUPPLY);
        assertEq(r.factoryBalanceAtDeploy, SUPPLY);
        assertEq(token.balanceOf(DISTRIBUTOR), SUPPLY / 10);
        assertEq(token.balanceOf(address(pool)), SUPPLY * 6 / 10);
        assertEq(token.balanceOf(REQUESTER), SUPPLY * 3 / 10);
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_LaunchSplitIsExactForAnyPoolShare(uint256 rawBps, bytes32 salt) public {
        uint256 poolBps = rawBps % 9_001; // the requester's ninety percent at most
        LaunchFactoryModel.Result memory r =
            factory.launch(salt, DISTRIBUTOR, address(pool), poolBps, REQUESTER);
        IERC20 token = IERC20(r.token);
        uint256 seed = SUPPLY * poolBps / 10_000;
        assertEq(token.balanceOf(DISTRIBUTOR), SUPPLY / 10);
        assertEq(token.balanceOf(address(pool)), seed);
        assertEq(token.balanceOf(REQUESTER), SUPPLY - SUPPLY / 10 - seed);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testSameSaltCannotLaunchTwice() public {
        factory.launch(bytes32(uint256(7)), DISTRIBUTOR, address(pool), 1_000, REQUESTER);
        vm.expectRevert();
        factory.launch(bytes32(uint256(7)), DISTRIBUTOR, address(pool), 1_000, REQUESTER);
    }

    function testLaunchWithMoreThanTheRequesterShareRevertsWhole() public {
        // 91% + the swarm's 10% exceeds the supply: the pull fails and nothing is left half-launched.
        vm.expectRevert(
            abi.encodeWithSelector(
                ChangelogToken.ERC20InsufficientBalance.selector,
                address(factory),
                SUPPLY - SUPPLY / 10,
                SUPPLY * 9_100 / 10_000
            )
        );
        factory.launch(bytes32(uint256(3)), DISTRIBUTOR, address(pool), 9_100, REQUESTER);
        assertEq(factory.predict(bytes32(uint256(3))).code.length, 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_TradesThroughPoolArriveWhole(uint256 rawBuy, uint256 rawSell) public {
        LaunchFactoryModel.Result memory r =
            factory.launch(bytes32(uint256(9)), DISTRIBUTOR, address(pool), 6_000, REQUESTER);
        IERC20 token = IERC20(r.token);
        uint256 seed = SUPPLY * 6 / 10;
        uint256 bought = rawBuy % (seed + 1);
        pool.pay(token, TRADER, bought);
        assertEq(token.balanceOf(TRADER), bought);

        uint256 sold = rawSell % (bought + 1);
        vm.prank(TRADER);
        token.approve(address(pool), sold);
        vm.prank(TRADER);
        pool.pull(token, sold);
        assertEq(token.balanceOf(TRADER), bought - sold);
        assertEq(token.balanceOf(address(pool)), seed - bought + sold);
        assertEq(token.allowance(TRADER, address(pool)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testPoolCannotPayMoreThanItHolds() public {
        LaunchFactoryModel.Result memory r =
            factory.launch(bytes32(uint256(11)), DISTRIBUTOR, address(pool), 6_000, REQUESTER);
        IERC20 token = IERC20(r.token);
        uint256 seed = SUPPLY * 6 / 10;
        vm.expectRevert(
            abi.encodeWithSelector(
                ChangelogToken.ERC20InsufficientBalance.selector, address(pool), seed, seed + 1
            )
        );
        pool.pay(token, TRADER, seed + 1);
        assertEq(token.balanceOf(address(pool)), seed);
    }

    function testPoolCannotPullWithoutApproval() public {
        LaunchFactoryModel.Result memory r =
            factory.launch(bytes32(uint256(12)), DISTRIBUTOR, address(pool), 6_000, REQUESTER);
        IERC20 token = IERC20(r.token);
        vm.expectRevert(
            abi.encodeWithSelector(ChangelogToken.ERC20InsufficientAllowance.selector, address(pool), 0, 1)
        );
        vm.prank(REQUESTER);
        pool.pull(token, 1);
        assertEq(token.balanceOf(REQUESTER), SUPPLY * 3 / 10);
    }

    function testDistributorClaimsArriveWhole() public {
        LaunchFactoryModel.Result memory r =
            factory.launch(bytes32(uint256(13)), DISTRIBUTOR, address(pool), 6_000, REQUESTER);
        IERC20 token = IERC20(r.token);
        uint256 swarm = SUPPLY / 10;
        vm.startPrank(DISTRIBUTOR);
        assertTrue(token.transfer(address(0xC1), swarm / 3));
        assertTrue(token.transfer(address(0xC2), swarm / 3));
        assertTrue(token.transfer(address(0xC3), swarm - 2 * (swarm / 3)));
        vm.stopPrank();
        assertEq(token.balanceOf(DISTRIBUTOR), 0);
        assertEq(
            token.balanceOf(address(0xC1)) + token.balanceOf(address(0xC2)) + token.balanceOf(address(0xC3)),
            swarm
        );
    }

    /// @dev Same reachable-code scan as the launch floor: no DELEGATECALL, CALLCODE or SELFDESTRUCT.
    function testRuntimeHasNoDelegatecallCallcodeOrSelfdestruct() public {
        bytes memory runtime = address(new ChangelogToken()).code;
        assertTrue(runtime.length > 0);
        assertTrue(runtime.length <= 24_576);
        bool reachable = true;
        for (uint256 i; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op == 0x5B) reachable = true;
            if (op >= 0x60 && op <= 0x7F) {
                i += op - 0x5F;
                continue;
            }
            if (reachable) {
                assertTrue(op != 0xF4);
                assertTrue(op != 0xF2);
                assertTrue(op != 0xFF);
            }
            if (op == 0x00 || op == 0x56 || op == 0xF3 || op == 0xFD || op == 0xFE || op == 0xFF) {
                reachable = false;
            }
        }
    }

    function testCreationCodeTakesNoConstructorArguments() public {
        // Appending arguments must not change the result: the constructor reads none.
        bytes memory code = abi.encodePacked(type(ChangelogToken).creationCode, abi.encode(address(0xBEEF)));
        address created;
        assembly ("memory-safe") {
            created := create(0, add(code, 32), mload(code))
        }
        assertTrue(created != address(0));
        assertEq(IERC20(created).balanceOf(address(this)), SUPPLY);
        assertEq(IERC20(created).balanceOf(address(0xBEEF)), 0);
    }

    function testConstructorRejectsEther() public {
        vm.deal(address(this), 1 ether);
        bytes memory code = type(ChangelogToken).creationCode;
        address created;
        assembly ("memory-safe") {
            created := create(1, add(code, 32), mload(code))
        }
        assertEq(created, address(0));
    }
}
