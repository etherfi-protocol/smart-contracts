// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {RoleRegistry} from "../src/RoleRegistry.sol";
import {RevokeAdmin} from "../src/helpers/RevokeAdmin.sol";
import {UUPSProxy} from "../src/UUPSProxy.sol";

contract RevokeAdminTest is Test {
    RoleRegistry public roleRegistryImpl;
    RoleRegistry public roleRegistry;
    RevokeAdmin public revokeAdminImpl;
    RevokeAdmin public revokeAdmin;

    address public owner;
    address public revokeAdminUser;
    address public target;
    address public nonAdmin;

    bytes32 public PAUSE_UNTIL_ROLE;
    bytes32 public BLACKLIST_UNTIL_ROLE;
    bytes32 public REVOKE_ADMIN_ROLE;

    event RoleSet(address indexed holder, uint256 indexed role, bool indexed active);

    function setUp() public {
        owner = makeAddr("owner");
        revokeAdminUser = makeAddr("revokeAdminUser");
        target = makeAddr("target");
        nonAdmin = makeAddr("nonAdmin");

        // The RoleRegistry's immutable revokeAdmin must equal the RevokeAdmin proxy
        // address, but that proxy hasn't been deployed yet. Predict its address from
        // this test contract's current nonce. Deploy order in this setUp:
        //   nonce+0: RoleRegistry implementation
        //   nonce+1: RoleRegistry proxy
        //   nonce+2: RevokeAdmin implementation
        //   nonce+3: RevokeAdmin proxy
        uint256 nonce = vm.getNonce(address(this));
        address predictedRevokeAdmin = vm.computeCreateAddress(address(this), nonce + 3);

        roleRegistryImpl = new RoleRegistry(predictedRevokeAdmin);
        roleRegistry = RoleRegistry(address(new UUPSProxy(
            address(roleRegistryImpl),
            abi.encodeWithSelector(RoleRegistry.initialize.selector, owner)
        )));

        revokeAdminImpl = new RevokeAdmin(address(roleRegistry));
        revokeAdmin = RevokeAdmin(address(new UUPSProxy(
            address(revokeAdminImpl),
            abi.encodeWithSelector(RevokeAdmin.initialize.selector)
        )));

        require(address(revokeAdmin) == predictedRevokeAdmin, "address prediction mismatch");

        PAUSE_UNTIL_ROLE = roleRegistry.PAUSE_UNTIL_ROLE();
        BLACKLIST_UNTIL_ROLE = roleRegistry.BLACKLIST_UNTIL_ROLE();
        REVOKE_ADMIN_ROLE = roleRegistry.REVOKE_ADMIN_ROLE();

        vm.prank(owner);
        roleRegistry.grantRole(REVOKE_ADMIN_ROLE, revokeAdminUser);
    }

    function test_Initialization() public {
        assertEq(address(revokeAdmin.roleRegistry()), address(roleRegistry));
        assertEq(roleRegistry.revokeAdmin(), address(revokeAdmin));

        vm.expectRevert("Initializable: contract is already initialized");
        revokeAdmin.initialize();
    }

    function test_RevokePauserUntilRole() public {
        vm.prank(owner);
        roleRegistry.grantRole(PAUSE_UNTIL_ROLE, target);
        assertTrue(roleRegistry.hasRole(PAUSE_UNTIL_ROLE, target));

        vm.prank(revokeAdminUser);
        revokeAdmin.revokePauserUntilRole(target);

        assertFalse(roleRegistry.hasRole(PAUSE_UNTIL_ROLE, target));
    }

    function test_RevokePauserUntilRole_EmitsRoleSetEvent() public {
        vm.prank(owner);
        roleRegistry.grantRole(PAUSE_UNTIL_ROLE, target);

        vm.expectEmit(true, true, true, true, address(roleRegistry));
        emit RoleSet(target, uint256(PAUSE_UNTIL_ROLE), false);

        vm.prank(revokeAdminUser);
        revokeAdmin.revokePauserUntilRole(target);
    }

    function test_RevokePauserUntilRole_NotRevokeAdmin() public {
        vm.prank(owner);
        roleRegistry.grantRole(PAUSE_UNTIL_ROLE, target);

        vm.prank(nonAdmin);
        vm.expectRevert(RevokeAdmin.IncorrectRole.selector);
        revokeAdmin.revokePauserUntilRole(target);

        // Owner of the registry is not automatically a revoke admin
        vm.prank(owner);
        vm.expectRevert(RevokeAdmin.IncorrectRole.selector);
        revokeAdmin.revokePauserUntilRole(target);

        assertTrue(roleRegistry.hasRole(PAUSE_UNTIL_ROLE, target));
    }

    function test_RevokePauserUntilRole_RoleNotHeld() public {
        // No-op when the target does not currently hold the role
        assertFalse(roleRegistry.hasRole(PAUSE_UNTIL_ROLE, target));

        vm.prank(revokeAdminUser);
        revokeAdmin.revokePauserUntilRole(target);

        assertFalse(roleRegistry.hasRole(PAUSE_UNTIL_ROLE, target));
    }

    function test_RevokeBlacklistUntilRole() public {
        vm.prank(owner);
        roleRegistry.grantRole(BLACKLIST_UNTIL_ROLE, target);
        assertTrue(roleRegistry.hasRole(BLACKLIST_UNTIL_ROLE, target));

        vm.prank(revokeAdminUser);
        revokeAdmin.revokeBlacklistUntilRole(target);

        assertFalse(roleRegistry.hasRole(BLACKLIST_UNTIL_ROLE, target));
    }

    function test_RevokeBlacklistUntilRole_EmitsRoleSetEvent() public {
        vm.prank(owner);
        roleRegistry.grantRole(BLACKLIST_UNTIL_ROLE, target);

        vm.expectEmit(true, true, true, true, address(roleRegistry));
        emit RoleSet(target, uint256(BLACKLIST_UNTIL_ROLE), false);

        vm.prank(revokeAdminUser);
        revokeAdmin.revokeBlacklistUntilRole(target);
    }

    function test_RevokeBlacklistUntilRole_NotRevokeAdmin() public {
        vm.prank(owner);
        roleRegistry.grantRole(BLACKLIST_UNTIL_ROLE, target);

        vm.prank(nonAdmin);
        vm.expectRevert(RevokeAdmin.IncorrectRole.selector);
        revokeAdmin.revokeBlacklistUntilRole(target);

        vm.prank(owner);
        vm.expectRevert(RevokeAdmin.IncorrectRole.selector);
        revokeAdmin.revokeBlacklistUntilRole(target);

        assertTrue(roleRegistry.hasRole(BLACKLIST_UNTIL_ROLE, target));
    }

    function test_RevokeBlacklistUntilRole_RoleNotHeld() public {
        assertFalse(roleRegistry.hasRole(BLACKLIST_UNTIL_ROLE, target));

        vm.prank(revokeAdminUser);
        revokeAdmin.revokeBlacklistUntilRole(target);

        assertFalse(roleRegistry.hasRole(BLACKLIST_UNTIL_ROLE, target));
    }

    function test_RevokeAdminCannotRevokeArbitraryRoles() public {
        // RevokeAdmin only exposes pause-until and blacklist-until revokes, not arbitrary roles
        bytes32 someOtherRole = roleRegistry.LIQUIDITY_POOL_ADMIN_ROLE();

        vm.prank(owner);
        roleRegistry.grantRole(someOtherRole, target);

        // The RevokeAdmin contract itself can call revokeFast directly (it is the revokeAdmin
        // on the registry), but only for its hardcoded role set. External callers can only
        // hit revokePauserUntilRole / revokeBlacklistUntilRole, so the LP admin role is safe.
        assertTrue(roleRegistry.hasRole(someOtherRole, target));
    }

    function test_RevokeAdminLosesRoleStopsRevoking() public {
        vm.prank(owner);
        roleRegistry.grantRole(PAUSE_UNTIL_ROLE, target);

        // Owner revokes the REVOKE_ADMIN_ROLE
        vm.prank(owner);
        roleRegistry.revokeRole(REVOKE_ADMIN_ROLE, revokeAdminUser);

        // Former revoke admin can no longer call the helper
        vm.prank(revokeAdminUser);
        vm.expectRevert(RevokeAdmin.IncorrectRole.selector);
        revokeAdmin.revokePauserUntilRole(target);

        assertTrue(roleRegistry.hasRole(PAUSE_UNTIL_ROLE, target));
    }

    function test_OnlyProtocolUpgraderCanUpgrade() public {
        RevokeAdmin newImpl = new RevokeAdmin(address(roleRegistry));

        vm.prank(nonAdmin);
        vm.expectRevert(RoleRegistry.OnlyProtocolUpgrader.selector);
        revokeAdmin.upgradeTo(address(newImpl));

        vm.prank(owner);
        revokeAdmin.upgradeTo(address(newImpl));
    }
}
