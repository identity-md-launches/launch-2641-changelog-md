// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Only the Foundry cheatcodes used by this project's tests; no external test dependency.
interface Vm {
    function prank(address msgSender) external;
    function startPrank(address msgSender) external;
    function stopPrank() external;
    function expectRevert(bytes calldata revertData) external;
    function expectRevert() external;
    function expectEmit(bool topic1, bool topic2, bool topic3, bool data, address emitter) external;
    function expectEmit(bool topic1, bool topic2, bool topic3, bool data) external;
    function deal(address account, uint256 newBalance) external;
}

abstract contract TestBase {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function assertTrue(bool value) internal pure {
        require(value, "assertTrue failed");
    }

    function assertFalse(bool value) internal pure {
        require(!value, "assertFalse failed");
    }

    function assertEq(uint256 actual, uint256 expected) internal pure {
        require(actual == expected, "uint256 equality failed");
    }

    function assertEq(address actual, address expected) internal pure {
        require(actual == expected, "address equality failed");
    }

    function assertEq(string memory actual, string memory expected) internal pure {
        require(keccak256(bytes(actual)) == keccak256(bytes(expected)), "string equality failed");
    }
}
