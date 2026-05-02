// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "../test/TestSetup.sol";
import "../src/EtherFiOracle.sol";

contract EtherFiOracleRoleMigrationTest is TestSetup {
    // Workaround: TestSetup.setUpTests() used new EtherFiOracle() (no-arg) before Task 2 updates it.
    // We deploy a fresh implementation here with the correct _roleRegistry arg and upgrade the proxy,
    // so etherFiOracleInstance (the proxy) uses the migrated implementation.
    EtherFiOracle internal freshImpl;

    function setUp() public {
        setUpTests();

        // Deploy a fresh implementation with the correct constructor arg and upgrade the proxy.
        freshImpl = new EtherFiOracle(address(roleRegistryInstance));
        vm.prank(owner);
        etherFiOracleInstance.upgradeTo(address(freshImpl));
    }

    function test_setReportStartSlot_revertsWithoutRole() public {
        address rando = address(0xBEEF);
        vm.prank(rando);
        vm.expectRevert(EtherFiOracle.IncorrectRole.selector);
        etherFiOracleInstance.setReportStartSlot(123);
    }

    function test_isAdminGate_succeedsWithRole() public {
        address admin = address(0xA11CE);
        // Use startPrank so the .owner() call does not consume the prank before grantRole.
        vm.startPrank(owner);
        roleRegistryInstance.grantRole(etherFiOracleInstance.ETHERFI_ORACLE_ADMIN_ROLE(), admin);
        vm.stopPrank();

        // setConsensusVersion is gated by isAdmin and only requires the new value to be greater
        // than the current one (initialized to 1). A successful state mutation proves the ACL passed.
        vm.prank(admin);
        etherFiOracleInstance.setConsensusVersion(7);

        assertEq(etherFiOracleInstance.consensusVersion(), 7);
    }

    function test_pause_revertsWithoutPauserRole() public {
        address rando = address(0xBEEF);
        vm.prank(rando);
        vm.expectRevert(EtherFiOracle.IncorrectRole.selector);
        etherFiOracleInstance.pauseContract();
    }

    function test_pause_succeedsWithPauserRole() public {
        address pauser = address(0xCAFE);
        vm.startPrank(owner);
        roleRegistryInstance.grantRole(roleRegistryInstance.PROTOCOL_PAUSER(), pauser);
        vm.stopPrank();

        vm.prank(pauser);
        etherFiOracleInstance.pauseContract();

        assertTrue(etherFiOracleInstance.paused());
    }

    function test_unpause_succeedsWithUnpauserRole() public {
        address pauser = address(0xCAFE);
        address unpauser = address(0xC0FFEE);
        vm.startPrank(owner);
        roleRegistryInstance.grantRole(roleRegistryInstance.PROTOCOL_PAUSER(), pauser);
        roleRegistryInstance.grantRole(roleRegistryInstance.PROTOCOL_UNPAUSER(), unpauser);
        vm.stopPrank();

        vm.prank(pauser);
        etherFiOracleInstance.pauseContract();

        vm.prank(unpauser);
        etherFiOracleInstance.unPauseContract();

        assertFalse(etherFiOracleInstance.paused());
    }

    function test_DEPRECATED_admins_storageReadable() public view {
        bool v = etherFiOracleInstance.DEPRECATED_admins(address(0x1));
        assertEq(v, false);
    }

    function test_updateAdmin_selectorRemoved() public {
        (bool ok,) = address(etherFiOracleInstance).call(
            abi.encodeWithSignature("updateAdmin(address,bool)", address(this), true)
        );
        assertFalse(ok, "updateAdmin selector must be absent post-migration");
    }
}
