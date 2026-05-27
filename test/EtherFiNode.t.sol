// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@tests/TestSetup.sol";
import "@etherfi/staking/EtherFiNode.sol";
import "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@etherfi/eigenlayer-interfaces/IEigenPodManager.sol";
import "@etherfi/eigenlayer-interfaces/IDelayedWithdrawalRouter.sol";
import "@tests/mocks/MockDelegationManager.sol";
import "@tests/mocks/MockEigenPod.sol";

import "forge-std/console2.sol";

interface IEigenlayerTimelock {
    function execute(
        address target,
        uint256 value,
        bytes calldata payload,
        bytes32 predecessor,
        bytes32 salt
    ) external;

    function grantRole(bytes32 role, address account) external;
}

contract EtherFiNodeTest is TestSetup, ArrayTestHelper {

}


