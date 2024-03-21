// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../../src/EtherFiNodesManager.sol";
import "../../src/helpers/AddressProvider.sol";

contract ReserveSafes is Script {   

    AddressProvider public addressProvider;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address addressProviderAddress = vm.envAddress("CONTRACT_REGISTRY");
        addressProvider = AddressProvider(addressProviderAddress);

        vm.startBroadcast(deployerPrivateKey);

        EtherFiNodesManager etherFiNodesManager = EtherFiNodesManager(payable(addressProvider.getContractAddress("EtherFiNodesManager")));

        etherFiNodesManager.createUnusedWithdrawalSafe(30, true);
        etherFiNodesManager.createUnusedWithdrawalSafe(30, true);
        etherFiNodesManager.createUnusedWithdrawalSafe(30, true);
        
        vm.stopBroadcast();
    }
}