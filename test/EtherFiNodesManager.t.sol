// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "../src/EtherFiNode.sol";
import "./TestSetup.sol";

import "forge-std/console2.sol";

contract EtherFiNodesManagerTest is TestSetup {
    function setUp() public {
        setUpTests();
    }
}
