// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "../test/TestSetup.sol";
import "../src/NodeOperatorManager.sol";

contract NodeOperatorManagerRoleMigrationTest is TestSetup {
    function setUp() public {
        setUpTests();
    }

    function _grantAdmin(address who) internal {
        vm.startPrank(owner);
        roleRegistryInstance.grantRole(
            nodeOperatorManagerInstance.NODE_OPERATOR_MANAGER_ADMIN_ROLE(),
            who
        );
        vm.stopPrank();
    }

    function test_addToWhitelist_revertsWithoutRole() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(NodeOperatorManager.IncorrectRole.selector);
        nodeOperatorManagerInstance.addToWhitelist(address(0xCAFE));
    }

    function test_addToWhitelist_succeedsWithRole() public {
        address admin = address(0xA11CE);
        _grantAdmin(admin);

        vm.prank(admin);
        nodeOperatorManagerInstance.addToWhitelist(address(0xCAFE));

        assertTrue(nodeOperatorManagerInstance.isWhitelisted(address(0xCAFE)));
    }

    function test_removeFromWhitelist_revertsWithoutRole() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(NodeOperatorManager.IncorrectRole.selector);
        nodeOperatorManagerInstance.removeFromWhitelist(address(0xCAFE));
    }

    function test_pause_revertsWithoutPauserRole() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(NodeOperatorManager.IncorrectRole.selector);
        nodeOperatorManagerInstance.pauseContract();
    }

    function test_pause_succeedsWithPauserRole() public {
        address pauser = address(0xCAFE);
        vm.startPrank(owner);
        roleRegistryInstance.grantRole(roleRegistryInstance.PROTOCOL_PAUSER(), pauser);
        vm.stopPrank();

        vm.prank(pauser);
        nodeOperatorManagerInstance.pauseContract();
        assertTrue(nodeOperatorManagerInstance.paused());
    }

    function test_DEPRECATED_admins_storageReadable() public view {
        bool v = nodeOperatorManagerInstance.DEPRECATED_admins(address(0x1));
        assertEq(v, false);
    }

    function test_updateAdmin_selectorRemoved() public {
        (bool ok,) = address(nodeOperatorManagerInstance).call(
            abi.encodeWithSignature("updateAdmin(address,bool)", address(this), true)
        );
        assertFalse(ok);
    }
}
