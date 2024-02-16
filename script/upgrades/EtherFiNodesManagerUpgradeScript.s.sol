// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../../src/EtherFiNodesManager.sol";
import "../../src/helpers/AddressProvider.sol";

contract EtherFiNodesManagerUpgrade is Script {

    AddressProvider public addressProvider;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address addressProviderAddress = vm.envAddress("CONTRACT_REGISTRY");
        addressProvider = AddressProvider(addressProviderAddress);

        address EtherFiNodesManagerProxyAddress = addressProvider.getContractAddress("EtherFiNodesManager");
        address etherFiAdminAddress = addressProvider.getContractAddress("EtherFiAdmin");

        address eigenPodManager;
        address delayedWithdrawalRouter;
        uint8 maxEigenlayerWithdrawals = 5;

        if (block.chainid == 1) {
            eigenPodManager = 0x91E677b07F7AF907ec9a428aafA9fc14a0d3A338;
            delayedWithdrawalRouter = 0x7Fe7E9CC0F274d2435AD5d56D5fa73E47F6A23D8;
        } else if (block.chainid == 5) {
            eigenPodManager = 0xa286b84C96aF280a49Fe1F40B9627C2A2827df41;
            delayedWithdrawalRouter = 0x89581561f1F98584F88b0d57c2180fb89225388f;
        } else {
            require(false);
        }

        uint64 numberOfValidators = IEtherFiNodesManager(EtherFiNodesManagerProxyAddress).numberOfValidators();
        address treasury = IEtherFiNodesManager(EtherFiNodesManagerProxyAddress).treasuryContract();

        vm.startBroadcast(deployerPrivateKey);

        EtherFiNodesManager EtherFiNodesManagerInstance = EtherFiNodesManager(payable(EtherFiNodesManagerProxyAddress));
        EtherFiNodesManager EtherFiNodesManagerV2Implementation = new EtherFiNodesManager();

        EtherFiNodesManagerInstance.upgradeTo(address(EtherFiNodesManagerV2Implementation));
        EtherFiNodesManagerInstance.initializeOnUpgrade(etherFiAdminAddress, eigenPodManager, delayedWithdrawalRouter, maxEigenlayerWithdrawals);

        require(IEtherFiNodesManager(EtherFiNodesManagerProxyAddress).numberOfValidators() == numberOfValidators);
        require(IEtherFiNodesManager(EtherFiNodesManagerProxyAddress).treasuryContract() == treasury);
        require(IEtherFiNodesManager(EtherFiNodesManagerProxyAddress).maxEigenlayerWithdrawals() == maxEigenlayerWithdrawals);
        require(IEtherFiNodesManager(EtherFiNodesManagerProxyAddress).admins(etherFiAdminAddress), "EtherFiAdmin should be an admin");

        vm.stopBroadcast();
    }
}
