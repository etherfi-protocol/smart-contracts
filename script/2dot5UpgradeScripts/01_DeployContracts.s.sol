// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import "../../src/Pauser.sol";
import "../../src/RoleRegistry.sol";
import "../../src/UUPSProxy.sol";
import "../../src/helpers/AddressProvider.sol";

contract Deploy2Dot5Contracts is Script {

    IPausable[] initialPausables;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        console.log("Configuring Mainnet Addresses...");

        AddressProvider addressProvider = AddressProvider(address(0x8487c5F8550E3C3e7734Fe7DCF77DB2B72E4A848));
        address superAdmin = address(0x0);

        console.log("Deploying RoleRegistry...");
        RoleRegistry roleRegistryImplementation = new RoleRegistry();
        bytes memory initializerData = abi.encodeWithSelector(RoleRegistry.initialize.selector, superAdmin);

        console.log("Deploying Protocol Pauser...");
        Pauser pauserImplementation = new Pauser();
        initialPausables.push(IPausable(addressProvider.getContractAddress("AuctionManager")));
        initialPausables.push(IPausable(addressProvider.getContractAddress("EtherFiNodesManager"))); 
        initialPausables.push(IPausable(addressProvider.getContractAddress("EtherFiOracle")));
        initialPausables.push(IPausable(addressProvider.getContractAddress("LiquidityPool")));
        initialPausables.push(IPausable(addressProvider.getContractAddress("Liquifier"))); 
        initialPausables.push(IPausable(addressProvider.getContractAddress("NodeOperatorManager")));
        initialPausables.push(IPausable(addressProvider.getContractAddress("StakingManager")));

        bytes memory initializerData = abi.encodeWithSelector(Pauser.initialize.selector, initialPausables, address(0x0));
        Pauser pauser = Pauser(address(new UUPSProxy(address(pauserImplementation), initializerData)));
    }
}
