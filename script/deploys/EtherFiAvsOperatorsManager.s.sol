// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../../src/UUPSProxy.sol";
import "../../src/helpers/AddressProvider.sol";
import "../../src/EtherFiAvsOperator.sol";
import "../../src/EtherFiAvsOperatorsManager.sol";

contract DeployEtherFiAvsOperatorsManager is Script {

    AddressProvider public addressProvider;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address addressProviderAddress = vm.envAddress("CONTRACT_REGISTRY");
        addressProvider = AddressProvider(addressProviderAddress);

        address delegationManager;
        if (block.chainid == 1) {
            delegationManager = 0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A;
        } else if (block.chainid == 17000) {
            delegationManager = 0xA44151489861Fe9e3055d95adC98FbD462B948e7;
        } else {
            revert("Chain ID not supported");
        }

        vm.startBroadcast(deployerPrivateKey);

        EtherFiAvsOperatorsManager mgr = EtherFiAvsOperatorsManager(address(0x2093Bbb221f1d8C7c932c32ee28Be6dEe4a37A6a));
        mgr.upgradeEtherFiAvsOperator(address(new EtherFiAvsOperator()));

        mgr.instantiateEtherFiAvsOperator(1);

        // EtherFiAvsOperatorsManager mgr = EtherFiAvsOperatorsManager(address(new UUPSProxy(address(new EtherFiAvsOperatorsManager()), "")));
        // mgr.initialize(delegationManager);

        vm.stopBroadcast();
    }
}
