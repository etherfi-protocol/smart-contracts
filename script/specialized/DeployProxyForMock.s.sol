// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../../src/UUPSProxy.sol";

import "../../src/Liquifier.sol";


contract Deploy is Script {


    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        address impl = address(new Liquifier());
        // address impl = 0x61e2cA79cA3d90Fd1440976a6C9641431b3F296a;
        UUPSProxy proxy = new UUPSProxy(impl, "");

        // Liquifier(payable(address(proxy))).initialize();

        // mgr.upgradeEtherFiAvsOperator(address(new EtherFiAvsOperator()));
        // mgr.upgradeTo(mgr_impl);
        // mgr.initializeAvsDirectory(avsDirectory);

        // mgr.instantiateEtherFiAvsOperator(1);

        // EtherFiAvsOperatorsManager mgr = EtherFiAvsOperatorsManager(address(new UUPSProxy(address(new EtherFiAvsOperatorsManager()), "")));
        // mgr.initialize(delegationManager, address(new EtherFiAvsOperator()));

        vm.stopBroadcast();
    }
}