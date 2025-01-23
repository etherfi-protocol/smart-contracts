// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "forge-std/Test.sol";

import "../src/helpers/EtherFiOperationParameters.sol";
import "../src/UUPSProxy.sol";

contract EtherFiOperationParametersTest is TestSetup {

    EtherFiOperationParameters operationParameters;
    address rando1 = address(0x1); // Non-owner account for testing
    address rando2 = address(0x2);   // Another non-owner account

    function setUp() public {
        EtherFiOperationParameters impl = new EtherFiOperationParameters();
        UUPSProxy proxy = new UUPSProxy(address(impl), "");

        operationParameters = EtherFiOperationParameters(address(proxy));
        operationParameters.initialize();
    }

    function testFuzz_updateTagAdmin(
        string calldata tag,
        address admin,
        bool allowed
    ) public {
        operationParameters.updateTagAdmin(tag, admin, allowed);
        assertEq(operationParameters.tagAdmins(tag, admin), allowed);
    }

    function testFuzz_updateTagKeyValue(
        string calldata tag,
        string calldata key,
        string calldata value1,
        string calldata value2
    ) public {
        vm.expectRevert();
        operationParameters.updateTagKeyValue(tag, key, value1);

        vm.prank(operationParameters.owner());
        operationParameters.updateTagAdmin(tag, admin, true);

        vm.prank(admin);
        operationParameters.updateTagKeyValue(tag, key, value1);
        assertEq(operationParameters.tagKeyValues(tag, key), value1);

        vm.prank(admin);
        operationParameters.updateTagKeyValue(tag, key, value2);
        assertEq(operationParameters.tagKeyValues(tag, key), value2);
    }

    // Test that only the owner can call updateTagAdmin
    function testFuzz_updateTagAdmin_onlyOwner(
        string calldata tag,
        address admin,
        bool allowed
    ) public {
        vm.prank(rando1); // Attempt to call from a non-owner account
        vm.expectRevert("Ownable: caller is not the owner");
        operationParameters.updateTagAdmin(tag, admin, allowed);

        // Owner can successfully call the function
        vm.prank(operationParameters.owner());
        operationParameters.updateTagAdmin(tag, admin, allowed);
        assertEq(operationParameters.tagAdmins(tag, admin), allowed);
    }

    // Test that only an admin can call updateTagKeyValue
    function testFuzz_updateTagKeyValue_onlyAdmin(
        string calldata tag,
        string calldata key,
        string calldata value
    ) public {
        // Attempt to call without being an admin
        vm.prank(rando1);
        vm.expectRevert("Only admin can call");
        operationParameters.updateTagKeyValue(tag, key, value);

        // Assign admin role to rando1 for the tag
        vm.prank(operationParameters.owner());
        operationParameters.updateTagAdmin(tag, rando1, true);

        // Alice can now update the key value
        vm.prank(rando1);
        operationParameters.updateTagKeyValue(tag, key, value);
        assertEq(operationParameters.tagKeyValues(tag, key), value);
    }

    // Test the updateTagKeyValue function with multiple updates by an admin
    function testFuzz_updateTagKeyValue_asAdmin(
        string calldata tag,
        string calldata key,
        string calldata value1,
        string calldata value2
    ) public {
        // Assign admin role to rando2 for the tag
        operationParameters.updateTagAdmin(tag, rando2, true);

        // Bob updates the key value
        vm.prank(rando2);
        operationParameters.updateTagKeyValue(tag, key, value1);
        assertEq(operationParameters.tagKeyValues(tag, key), value1);

        // Bob updates the key value again
        vm.prank(rando2);
        operationParameters.updateTagKeyValue(tag, key, value2);
        assertEq(operationParameters.tagKeyValues(tag, key), value2);
    }

    // Test that only the owner can upgrade the contract
    function test_upgrade_onlyOwner() public {
        address newImplementation = address(new EtherFiOperationParameters());

        // Attempt to upgrade from a non-owner account
        vm.prank(rando1);
        vm.expectRevert("Ownable: caller is not the owner");
        operationParameters.upgradeTo(newImplementation);

        // Owner upgrades successfully
        operationParameters.upgradeTo(newImplementation);
        assertEq(operationParameters.getImplementation(), newImplementation);
    }

    function test_upgrade() public {
        address newImplementation = address(new EtherFiOperationParameters());
        operationParameters.upgradeTo(newImplementation);
        assertEq(operationParameters.getImplementation(), newImplementation);
    }
}