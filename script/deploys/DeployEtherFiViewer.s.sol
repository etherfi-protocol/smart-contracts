// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import "src/helpers/EtherFiViewer.sol";
import "src/UUPSProxy.sol";

contract DeployEtherFiViewer is Script {

    function run() external {
        address addressProviderAddress = vm.envAddress("CONTRACT_REGISTRY");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);

        EtherFiViewer impl = new EtherFiViewer();

        // UUPSProxy proxy = new UUPSProxy(address(impl), "");
        // EtherFiViewer viewer = EtherFiViewer(address(proxy));
        // viewer.initialize(addressProviderAddress);

        EtherFiViewer viewer = EtherFiViewer(address(0x2ecd155405cA52a5ca0e552981fF44A8252FAb81));
        viewer.upgradeTo(address(impl));
        vm.stopBroadcast();

        uint256[] memory validatorIds = new uint256[](2);
        validatorIds[0] = 25678;
        validatorIds[1] = 29208;

        address[] memory etherFiNodeAddresses = viewer.EtherFiNodesManager_etherFiNodeAddress(validatorIds);
        assert(etherFiNodeAddresses[0] == 0x31db9021ec8E1065e1f55553c69e1B1ea9d20533);
        assert(etherFiNodeAddresses[1] == 0xC3D3662A44c0d80080D3AF0eea752369c504724e);

        // viewer.EigenPod_mostRecentWithdrawalTimestamp(validatorIds);
        // viewer.EigenPod_hasRestaked(validatorIds);
        
    }
}
