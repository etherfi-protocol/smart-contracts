// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "../src/EtherFiNode.sol";

import "../src/eigenlayer-interfaces/IDelayedWithdrawalRouter.sol";
import "../src/eigenlayer-interfaces/IEigenPodManager.sol";
import "./TestSetup.sol";

import "./mocks/MockDelegationManager.sol";
import "./mocks/MockEigenPod.sol";
import "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import "forge-std/console2.sol";

interface IEigenlayerTimelock {
    function execute(address target, uint256 value, bytes calldata payload, bytes32 predecessor, bytes32 salt) external;

    function grantRole(bytes32 role, address account) external;
}

contract EtherFiNodeTest is TestSetup, ArrayTestHelper {}
