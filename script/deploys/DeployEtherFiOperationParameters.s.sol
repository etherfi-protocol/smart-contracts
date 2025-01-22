// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import "@openzeppelin/contracts/utils/Strings.sol";

import "../../src/Liquifier.sol";
import "../../src/EtherFiRestaker.sol";
import "../../src/helpers/AddressProvider.sol";
import "../../src/UUPSProxy.sol";
import "../../src/helpers/EtherFiOperationParameters.sol";


contract Deploy is Script {
    using Strings for string;
    AddressProvider public addressProvider;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address addressProviderAddress = vm.envAddress("CONTRACT_REGISTRY");
        addressProvider = AddressProvider(addressProviderAddress);

        vm.startBroadcast(deployerPrivateKey);

        bool to_upgrade = true;

        if (to_upgrade) {
            EtherFiOperationParameters instance = EtherFiOperationParameters(0xD0Ff8996DB4bDB46870b7E833b7532f484fEad1A);
            EtherFiOperationParameters impl = new EtherFiOperationParameters();
            instance.upgradeTo(address(impl));
        } else {
            EtherFiOperationParameters impl = new EtherFiOperationParameters();
            UUPSProxy proxy = new UUPSProxy(address(impl), "");

            EtherFiOperationParameters instance = EtherFiOperationParameters(payable(proxy));

            instance.updateTagAdmin("ORACLE", 0x566E58ac0F2c4BCaF6De63760C56cC3f825C48f5, true);
            instance.updateTagAdmin("EIGENPOD", 0x566E58ac0F2c4BCaF6De63760C56cC3f825C48f5, true);
            // instance.updateTagKeyValue("ORACLE", "WITHDRAWAL_TARGET_GAS_PRICE", "12.5"); // 12.5 gwei
            // instance.updateTagKeyValue("ORACLE", "TARGET_LIQUIDITY_IN_PERCENT_OF_TVL", "2.0"); // 2.0 % of TVL
            // instance.updateTagKeyValue("EIGENPOD", "PROOF_SUBMIT_TARGET_GAS_PRICE", "12.5"); // 12.5 gwei
        }

        vm.stopBroadcast();
    }
}