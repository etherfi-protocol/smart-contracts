// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../../src/EtherFiNodesManager.sol";
import "../../src/EtherFiNode.sol";
import "../../src/LiquidityPool.sol";
import "../../src/WithdrawRequestNFT.sol";
import "../../src/helpers/AddressProvider.sol";

contract Deploy is Script {

    AddressProvider public addressProvider;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        // new EtherFiNodesManager();
        new EtherFiNode();
        // new LiquidityPool();
        // new WithdrawRequestNFT();

        vm.stopBroadcast();
    }

}
