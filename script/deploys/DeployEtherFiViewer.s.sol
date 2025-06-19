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
    }
}
