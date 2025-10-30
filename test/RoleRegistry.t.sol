// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {RoleRegistry} from "../src/RoleRegistry.sol";
import {UUPSProxy} from "../src/UUPSProxy.sol";
import {Test} from "forge-std/Test.sol";

contract RoleRegistryTest is Test {
    RoleRegistry public implementation;
    RoleRegistry public registry;

    address public owner;
    address public user1;
    address public user2;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    event RoleSet(address indexed holder, uint256 indexed role, bool active);

    function setUp() public {
        owner = makeAddr("owner");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        // Deploy implementation
        implementation = new RoleRegistry();

        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(RoleRegistry.initialize.selector, owner);

        UUPSProxy proxy = new UUPSProxy(address(implementation), initData);

        registry = RoleRegistry(address(proxy));
    }

    function test_Initialization() public {
        assertEq(registry.owner(), owner);

        vm.expectRevert("Initializable: contract is already initialized");
        registry.initialize(address(1));
    }

    function test_GrantRole() public {
        vm.startPrank(owner);

        // Grant role
        registry.grantRole(ADMIN_ROLE, user1);
        assertTrue(registry.hasRole(ADMIN_ROLE, user1));

        // Verify role holders
        address[] memory holders = registry.roleHolders(ADMIN_ROLE);
        assertEq(holders.length, 1);
        assertEq(holders[0], user1);

        vm.stopPrank();
    }

    function test_RevokeRole() public {
        vm.startPrank(owner);

        // Grant and revoke role
        registry.grantRole(ADMIN_ROLE, user1);
        registry.revokeRole(ADMIN_ROLE, user1);

        assertFalse(registry.hasRole(ADMIN_ROLE, user1));

        // Verify role holders is empty
        address[] memory holders = registry.roleHolders(ADMIN_ROLE);
        assertEq(holders.length, 0);

        vm.stopPrank();
    }

    function test_CheckRoles() public {
        vm.startPrank(owner);

        // Grant multiple roles to user1
        registry.grantRole(ADMIN_ROLE, user1);
        registry.grantRole(OPERATOR_ROLE, user1);

        // Encode roles for checking
        bytes memory encodedRoles = abi.encode(ADMIN_ROLE, OPERATOR_ROLE);

        // Should not revert
        registry.checkRoles(user1, encodedRoles);

        // Should revert for user2 who has no roles
        vm.expectRevert();
        registry.checkRoles(user2, encodedRoles);

        vm.stopPrank();
    }

    function test_OnlyOwnerCanGrantRoles() public {
        // Try to grant role as non-owner
        vm.startPrank(user1);
        vm.expectRevert();
        registry.grantRole(ADMIN_ROLE, user2);
        vm.stopPrank();

        // Verify role was not granted
        assertFalse(registry.hasRole(ADMIN_ROLE, user2));
    }

    function test_OnlyOwnerCanRevokeRoles() public {
        // Setup: owner grants role
        vm.prank(owner);
        registry.grantRole(ADMIN_ROLE, user2);

        // Try to revoke role as non-owner
        vm.startPrank(user1);
        vm.expectRevert();
        registry.revokeRole(ADMIN_ROLE, user2);
        vm.stopPrank();

        // Verify role was not revoked
        assertTrue(registry.hasRole(ADMIN_ROLE, user2));
    }

    function test_Upgradeability() public {
        // Deploy new implementation
        RoleRegistry newImplementation = new RoleRegistry();

        // Only owner can upgrade
        vm.prank(user1);
        vm.expectRevert("Ownable: caller is not the owner");
        registry.upgradeTo(address(newImplementation));

        // Owner can upgrade
        vm.startPrank(owner);
        registry.upgradeTo(address(newImplementation));

        registry.grantRole(ADMIN_ROLE, user1);
        assertTrue(registry.hasRole(ADMIN_ROLE, user1));
        vm.stopPrank();
    }

    function test_RoleEnumeration() public {
        vm.startPrank(owner);

        // Grant roles to multiple users
        registry.grantRole(ADMIN_ROLE, user1);
        registry.grantRole(ADMIN_ROLE, user2);

        // Check role holders
        address[] memory holders = registry.roleHolders(ADMIN_ROLE);
        assertEq(holders.length, 2);
        assertTrue(holders[0] == user1 || holders[1] == user1);
        assertTrue(holders[0] == user2 || holders[1] == user2);

        vm.stopPrank();
    }

    function test_TwoStepOwnershipTransfer() public {
        // Start transfer
        vm.prank(owner);
        registry.transferOwnership(user1);

        // Verify pending owner
        assertEq(registry.pendingOwner(), user1);
        assertEq(registry.owner(), owner);

        // Accept transfer
        vm.prank(user1);
        registry.acceptOwnership();

        // Verify new owner
        assertEq(registry.owner(), user1);
        assertEq(registry.pendingOwner(), address(0));
    }
}
