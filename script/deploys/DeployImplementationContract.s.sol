// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
// import "../../src/eBtcRateProvider.sol";
// import "../../src/helpers/EtherFiViewer.sol";
import "../../src/EtherFiNodesManager.sol";
import "../../src/EtherFiNode.sol";
import "../../src/EtherFiAdmin.sol";
import "../../src/EtherFiOracle.sol";
import "../../src/LiquidityPool.sol";
import "../../src/Liquifier.sol";

import "../Create2Factory.sol";


contract Deploy is Script {
    bytes32 immutable salt = keccak256("ETHER_FI");
    Create2Factory immutable factory = Create2Factory(0x6521991A0BC180a5df7F42b27F4eE8f3B192BA62);

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.selectFork(vm.createFork(vm.envString("MAINNET_RPC_URL")));

        vm.startBroadcast(deployerPrivateKey);
        bytes memory code = abi.encodePacked(type(Liquifier).creationCode);
        factory.deploy(code, salt);
    }
}