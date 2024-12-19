// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import "@openzeppelin/contracts/utils/Strings.sol";

import "../../src/Liquifier.sol";
import "../../src/EtherFiRestaker.sol";
import "../../src/helpers/AddressProvider.sol";
import "../../src/UUPSProxy.sol";
import "../../src/EtherFiWithdrawalBuffer.sol";


contract Deploy is Script {
    using Strings for string;
    AddressProvider public addressProvider;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address addressProviderAddress = vm.envAddress("CONTRACT_REGISTRY");
        addressProvider = AddressProvider(addressProviderAddress);

        vm.startBroadcast(deployerPrivateKey);

        EtherFiWithdrawalBuffer impl = new EtherFiWithdrawalBuffer(
            addressProvider.getContractAddress("LiquidityPool"), 
            addressProvider.getContractAddress("EETH"), 
            addressProvider.getContractAddress("WeETH"), 
            0x0c83EAe1FE72c390A02E426572854931EefF93BA, // protocol safe
            0x1d3Af47C1607A2EF33033693A9989D1d1013BB50 // role registry
        );
        UUPSProxy proxy = new UUPSProxy(payable(impl), "");

        EtherFiWithdrawalBuffer instance = EtherFiWithdrawalBuffer(payable(proxy));
        instance.initialize(10_00, 1_00, 1_00, 5 ether, 0.001 ether);

        vm.stopBroadcast();
    }
}
