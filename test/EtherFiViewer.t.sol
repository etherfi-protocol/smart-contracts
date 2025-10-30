// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "../src/UUPSProxy.sol";
import "../src/helpers/EtherFiViewer.sol";

contract EtherFiViewerTest is Test {
    EtherFiViewer public etherFiViewer;
    address public eigenPodManager = address(0x91E677b07F7AF907ec9a428aafA9fc14a0d3A338);
    address public delegationManager = address(0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A);

    function setUp() public {
        vm.selectFork(vm.createFork(vm.envString("MAINNET_RPC_URL")));

        etherFiViewer = EtherFiViewer(address(new UUPSProxy(address(new EtherFiViewer(eigenPodManager, delegationManager)), "")));
        etherFiViewer.initialize(address(0x8487c5F8550E3C3e7734Fe7DCF77DB2B72E4A848));
    }

    // TODO(dave): rework?
    /*
    function test_EtherFiNodesManager() public {
        uint256[] memory validatorIds = new uint256[](2);
        validatorIds[0] = 25678;
        validatorIds[1] = 29208;

        address[] memory etherFiNodeAddresses = etherFiViewer.EtherFiNodesManager_etherFiNodeAddress(validatorIds);
        assertEq(etherFiNodeAddresses[0], 0x31db9021ec8E1065e1f55553c69e1B1ea9d20533);
        assertEq(etherFiNodeAddresses[1], 0xC3D3662A44c0d80080D3AF0eea752369c504724e);

        etherFiViewer.EtherFiNodesManager_splitBalanceInExecutionLayer(validatorIds);
        etherFiViewer.EtherFiNodesManager_withdrawableBalanceInExecutionLayer(validatorIds);
    }
    */

    function test_EigenPodManager_podOwnerDepositShares() public {
        uint256[] memory validatorIds = new uint256[](2);
        validatorIds[0] = 25_678;
        validatorIds[1] = 29_208;

        etherFiViewer.EigenPodManager_podOwnerDepositShares(validatorIds);
    }
}
