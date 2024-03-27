// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "../src/EtherFiNode.sol";
import "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "../src/eigenlayer-interfaces/IEigenPodManager.sol";
import "../src/eigenlayer-interfaces/IDelayedWithdrawalRouter.sol";

import "forge-std/console2.sol";


contract EigenLayerIntegraitonTest is TestSetup {

    function setUp() public {
        initializeTestingFork(TESTNET_FORK);

        vm.startPrank(alice);
        liquidityPoolInstance.setRestakeBnftDeposits(true);
        vm.stopPrank();
    }

    // References
    // - https://github.com/Layr-Labs/eigenlayer-contracts/tree/dev?tab=readme-ov-file#current-testnet-deployment
    // - https://github.com/Layr-Labs/eigenlayer-contracts/blob/dev/src/test/unit/EigenPodUnit.t.sol
    // - https://github.com/Layr-Labs/eigenlayer-contracts/blob/dev/src/test/unit/
    // - https://github.com/Layr-Labs/eigenlayer-contracts/tree/dev/src/test/utils

    function create_validator() public returns (uint256, address, EtherFiNode) {        
        uint256[] memory validatorIds = launch_validator(1, 0, true);
        address nodeAddress = managerInstance.etherfiNodeAddress(validatorIds[0]);
        EtherFiNode node = EtherFiNode(payable(nodeAddress));

        return (validatorIds[0], nodeAddress, node);
    }

    // per EigenPod
    // - call `activateRestaking()` to empty the EigenPod contract and disable `withdrawBeforeRestaking()`
    // - call `verifyWithdrawalCredentials()` to register the validator by proving that it is active
    // - call `delegateTo` for delegation

    // Call EigenPod.activateRestaking()
    function test_activateRestaking() public {
        (uint256 validatorId, address nodeAddress, EtherFiNode node) = create_validator();

        assertTrue(node.eigenPod() != address(0));
        
        vm.startPrank(admin);
        // EigenPod contract created after EL contract upgrade is restaked by default in its 'initialize'
        // Therefore, the call to 'activateRestaking()' should fail.
        // We will need to write another test in mainnet for this
        vm.expectRevert(); 
        managerInstance.callEigenPod(validatorId, abi.encodeWithSelector(bytes4(keccak256("activateRestaking()"))));
        vm.stopPrank();
    }

    // Call EigenPod.verifyWithdrawalCredentials()
    // function verifyWithdrawalCredentials(
    //     uint64 oracleTimestamp,
    //     BeaconChainProofs.StateRootProof calldata stateRootProof,
    //     uint40[] calldata validatorIndices,
    //     bytes[] calldata withdrawalCredentialProofs,
    //     bytes32[][] calldata validatorFields
    // )
    //     external;
    function test_verifyWithdrawalCredentials() public {

    }

    // Call DelegationMaanger.delegateTo(address operator)
    function test_delegateTo() public {
        (uint256 validatorId, address nodeAddress, EtherFiNode node) = create_validator();
        
        address operator = bob;

        vm.startPrank(admin);
        vm.expectRevert(); // EigenPod contract created after EL contract upgrade is restaked by default in its 'initialize'
        managerInstance.callDelegationManager(validatorId, abi.encodeWithSelector(bytes4(keccak256("delegateTo(address)")), operator));
        vm.stopPrank();
    }

}