// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ChangelogToken} from "../src/ChangelogToken.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {TestBase} from "./support/TestBase.sol";

/// @dev Drives the token with bounded inputs from a fixed set of actors and keeps an independent ledger.
/// Every call goes through a low-level call so expected reverts are checked rather than discarded.
contract ChangelogTokenHandler is TestBase {
    uint256 internal constant SUPPLY = 1_000_000_000 * 1e18;
    uint256 internal constant ACTORS = 5;

    ChangelogToken public immutable token;
    address[ACTORS] internal actors;

    // Ghost ledger, indexed by actor.
    uint256[ACTORS] public ghostBalance;
    uint256[ACTORS][ACTORS] public ghostAllowance;

    // Ghost counters; a run where nothing succeeded checks nothing.
    uint256 public successfulTransfers;
    uint256 public successfulTransferFroms;
    uint256 public expectedReverts;
    uint256 public movedVolume;

    // Set when a call leaves the token in a state the ledger does not predict.
    bool public unlimitedAllowanceShrank;
    bool public outsiderBalanceChanged;

    constructor(ChangelogToken token_, address[ACTORS] memory actors_) {
        token = token_;
        actors = actors_;
        ghostBalance[0] = SUPPLY;
    }

    function actor(uint256 i) external view returns (address) {
        return actors[i];
    }

    function actorCount() external pure returns (uint256) {
        return ACTORS;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        uint256 from = fromSeed % ACTORS;
        uint256 to = toSeed % ACTORS;
        uint256 amount = _amount(amountSeed, ghostBalance[from]);
        bool expected = amount <= ghostBalance[from];

        vm.prank(actors[from]);
        (bool ok, bytes memory data) =
            address(token).call(abi.encodeCall(IERC20.transfer, (actors[to], amount)));
        require(ok == expected, "transfer success disagrees with ledger");
        if (ok) {
            require(data.length == 32 && abi.decode(data, (bool)), "transfer did not return true");
            ghostBalance[from] -= amount;
            ghostBalance[to] += amount;
            successfulTransfers++;
            movedVolume += amount;
        } else {
            require(
                keccak256(data)
                    == keccak256(
                        abi.encodeWithSelector(
                            ChangelogToken.ERC20InsufficientBalance.selector,
                            actors[from],
                            ghostBalance[from],
                            amount
                        )
                    ),
                "unexpected transfer revert"
            );
            expectedReverts++;
        }
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed) external {
        uint256 owner = ownerSeed % ACTORS;
        uint256 spender = spenderSeed % ACTORS;
        uint256 amount = _amount(amountSeed, ghostBalance[owner]);

        vm.prank(actors[owner]);
        (bool ok, bytes memory data) =
            address(token).call(abi.encodeCall(IERC20.approve, (actors[spender], amount)));
        require(ok && abi.decode(data, (bool)), "approve failed for a valid spender");
        ghostAllowance[owner][spender] = amount;
    }

    function transferFrom(uint256 callerSeed, uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        uint256 caller = callerSeed % ACTORS;
        uint256 from = fromSeed % ACTORS;
        uint256 to = toSeed % ACTORS;
        uint256 approved = ghostAllowance[from][caller];
        // Aim at the allowance or the balance edge, whichever binds, so both failure paths are reached.
        uint256 edge = approved < ghostBalance[from] ? approved : ghostBalance[from];
        uint256 amount = _amount(amountSeed, edge);
        bool allowed = amount <= approved;
        bool expected = allowed && amount <= ghostBalance[from];

        vm.prank(actors[caller]);
        (bool ok, bytes memory data) =
            address(token).call(abi.encodeCall(IERC20.transferFrom, (actors[from], actors[to], amount)));
        require(ok == expected, "transferFrom success disagrees with ledger");
        if (ok) {
            require(data.length == 32 && abi.decode(data, (bool)), "transferFrom did not return true");
            if (approved != type(uint256).max) ghostAllowance[from][caller] = approved - amount;
            ghostBalance[from] -= amount;
            ghostBalance[to] += amount;
            successfulTransferFroms++;
            movedVolume += amount;
        } else {
            bytes memory expectedError = !allowed
                ? abi.encodeWithSelector(
                    ChangelogToken.ERC20InsufficientAllowance.selector, actors[caller], approved, amount
                )
                : abi.encodeWithSelector(
                    ChangelogToken.ERC20InsufficientBalance.selector, actors[from], ghostBalance[from], amount
                );
            require(keccak256(data) == keccak256(expectedError), "unexpected transferFrom revert");
            expectedReverts++;
        }
        if (approved == type(uint256).max && token.allowance(actors[from], actors[caller]) != approved) {
            unlimitedAllowanceShrank = true;
        }
    }

    /// @dev Calls involving the zero address must revert and change nothing.
    function touchZeroAddress(uint256 actorSeed, uint256 amountSeed, uint256 mode) external {
        uint256 who = actorSeed % ACTORS;
        uint256 amount = _amount(amountSeed, ghostBalance[who]);
        bytes memory call_;
        bytes memory expectedError;
        mode %= 4;
        if (mode == 0) {
            vm.prank(actors[who]);
            call_ = abi.encodeCall(IERC20.transfer, (address(0), amount));
            expectedError = abi.encodeWithSelector(ChangelogToken.ERC20InvalidReceiver.selector, address(0));
        } else if (mode == 1) {
            vm.prank(actors[who]);
            call_ = abi.encodeCall(IERC20.approve, (address(0), amount));
            expectedError = abi.encodeWithSelector(ChangelogToken.ERC20InvalidSpender.selector, address(0));
        } else if (mode == 2) {
            vm.prank(address(0));
            call_ = abi.encodeCall(IERC20.transfer, (actors[who], 0));
            expectedError = abi.encodeWithSelector(ChangelogToken.ERC20InvalidSender.selector, address(0));
        } else {
            // A spender with an allowance still cannot send to the zero address, and keeps the allowance.
            uint256 spender = (actorSeed / ACTORS) % ACTORS;
            uint256 approved = ghostAllowance[who][spender];
            amount = amount > approved ? approved : amount;
            vm.prank(actors[spender]);
            call_ = abi.encodeCall(IERC20.transferFrom, (actors[who], address(0), amount));
            expectedError = abi.encodeWithSelector(ChangelogToken.ERC20InvalidReceiver.selector, address(0));
        }
        (bool ok, bytes memory data) = address(token).call(call_);
        require(!ok, "zero-address call succeeded");
        require(keccak256(data) == keccak256(expectedError), "unexpected zero-address revert");
        expectedReverts++;
    }

    /// @dev An address outside the actor set tries to pull from actors with no allowance; nothing moves.
    function outsiderPull(uint256 fromSeed, uint256 amountSeed) external {
        address outsider = address(0xBAD);
        uint256 from = fromSeed % ACTORS;
        uint256 amount = 1 + amountSeed % SUPPLY;
        uint256 before = token.balanceOf(actors[from]);
        vm.prank(outsider);
        (bool ok,) =
            address(token).call(abi.encodeCall(IERC20.transferFrom, (actors[from], outsider, amount)));
        if (ok || token.balanceOf(actors[from]) != before || token.balanceOf(outsider) != 0) {
            outsiderBalanceChanged = true;
        }
        expectedReverts++;
    }

    /// @dev Mixes the exact edges (0, 1, balance, balance + 1, max) with uniform values over the supply.
    function _amount(uint256 seed, uint256 edge) private pure returns (uint256) {
        uint256 mode = seed % 8;
        if (mode == 0) return 0;
        if (mode == 1) return 1;
        if (mode == 2) return edge;
        if (mode == 3) return edge == type(uint256).max ? edge : edge + 1;
        if (mode == 4) return type(uint256).max;
        if (mode == 5) return edge == 0 ? 0 : (seed >> 8) % edge;
        return (seed >> 8) % (SUPPLY + 1);
    }
}

/// @notice Foundry invariant tests: random sequences of transfers, approvals and delegated transfers,
/// checked against the handler's ledger after every call.
contract ChangelogTokenInvariantTest is TestBase {
    uint256 internal constant SUPPLY = 1_000_000_000 * 1e18;

    ChangelogToken internal token;
    ChangelogTokenHandler internal handler;

    function setUp() public {
        address[5] memory actors =
            [address(0xF4C7041), address(0xA11CE), address(0xB0B), address(0xCA401), address(0xD00D)];
        // The first actor plays the factory: it deploys the token and receives the whole supply.
        vm.prank(actors[0]);
        token = new ChangelogToken();
        handler = new ChangelogTokenHandler(token, actors);
    }

    /// @dev Read by forge's invariant runner in place of forge-std's StdInvariant.
    function targetContracts() public view returns (address[] memory targets) {
        targets = new address[](1);
        targets[0] = address(handler);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_totalSupplyIsFixed() public view {
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_balancesSumToSupplyAndMatchLedger() public view {
        uint256 sum;
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            uint256 balance = token.balanceOf(handler.actor(i));
            assertEq(balance, handler.ghostBalance(i));
            sum += balance;
        }
        assertEq(sum, SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(0xBAD)), 0);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_allowancesMatchLedger() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address owner = handler.actor(i);
            for (uint256 j; j < n; ++j) {
                assertEq(token.allowance(owner, handler.actor(j)), handler.ghostAllowance(i, j));
            }
            assertEq(token.allowance(owner, address(0)), 0);
            assertEq(token.allowance(owner, address(0xBAD)), 0);
        }
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_noUnauthorisedMovementOrUnlimitedAllowanceDecay() public view {
        assertFalse(handler.outsiderBalanceChanged());
        assertFalse(handler.unlimitedAllowanceShrank());
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_metadataNeverChanges() public view {
        assertEq(token.name(), "Changelog.md");
        assertEq(token.symbol(), "CMD");
        assertEq(token.decimals(), 18);
        assertEq(address(token).balance, 0);
    }
}
