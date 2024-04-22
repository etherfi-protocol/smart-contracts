// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../../src/UUPSProxy.sol";
import "../../src/helpers/AddressProvider.sol";
import "../../src/EtherFiAvsOperator.sol";
import "../../src/EtherFiAvsOperatorsManager.sol";

contract DeployEtherFiAvsOperatorsManager is Script {

    AddressProvider public addressProvider;
    EtherFiAvsOperatorsManager mgr;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address addressProviderAddress = vm.envAddress("CONTRACT_REGISTRY");
        addressProvider = AddressProvider(addressProviderAddress);

        address delegationManager;
        address avsDirectory;
        if (block.chainid == 1) {
            delegationManager = 0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A;
            avsDirectory = 0x135DDa560e946695d6f155dACaFC6f1F25C1F5AF;
            mgr = EtherFiAvsOperatorsManager(address(0x2093Bbb221f1d8C7c932c32ee28Be6dEe4a37A6a));
        } else if (block.chainid == 17000) {
            delegationManager = 0xA44151489861Fe9e3055d95adC98FbD462B948e7;
            avsDirectory = 0x055733000064333CaDDbC92763c58BF0192fFeBf;
            mgr = EtherFiAvsOperatorsManager(address(0xDF9679E8BFce22AE503fD2726CB1218a18CD8Bf4));
        } else {
            revert("Chain ID not supported");
        }

        vm.startBroadcast(deployerPrivateKey);

        address mgr_impl = address(new EtherFiAvsOperatorsManager());

        // mgr.upgradeEtherFiAvsOperator(address(new EtherFiAvsOperator()));
        // mgr.upgradeTo(mgr_impl);
        // mgr.initializeAvsDirectory(avsDirectory);

        // mgr.instantiateEtherFiAvsOperator(1);

        // EtherFiAvsOperatorsManager mgr = EtherFiAvsOperatorsManager(address(new UUPSProxy(address(new EtherFiAvsOperatorsManager()), "")));
        // mgr.initialize(delegationManager, address(new EtherFiAvsOperator()));

        vm.stopBroadcast();
    }
}
