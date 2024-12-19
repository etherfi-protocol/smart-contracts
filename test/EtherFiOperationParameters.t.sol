// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "forge-std/Test.sol";

import "../src/helpers/EtherFiOperationParameters.sol";
import "../src/UUPSProxy.sol";

contract EtherFiOperationParametersTest is TestSetup {

    EtherFiOperationParameters operationParameters;

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
        string calldata value
    ) public {
        operationParameters.updateTagKeyValue(tag, key, value);
        assertEq(operationParameters.tagKeyValues(tag, key), value);
    }

    function testFuzz_updateTagKeyValue(
        string calldata tag,
        string calldata key,
        string calldata value1,
        string calldata value2
    ) public {
        operationParameters.updateTagKeyValue(tag, key, value1);
        assertEq(operationParameters.tagKeyValues(tag, key), value1);
        operationParameters.updateTagKeyValue(tag, key, value2);
        assertEq(operationParameters.tagKeyValues(tag, key), value2);
    }

    function test_upgrade() public {
        address newImplementation = address(new EtherFiOperationParameters());
        operationParameters.upgradeTo(newImplementation);
        assertEq(operationParameters.getImplementation(), newImplementation);
    }
}