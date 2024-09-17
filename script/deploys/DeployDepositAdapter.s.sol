// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import "../../src/helpers/AddressProvider.sol";
import "../../src/DepositAdapter.sol";
import "../../src/UUPSProxy.sol";

contract DeployDepositAdapter is Script {

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        AddressProvider addressProvider = AddressProvider(address(0x8487c5F8550E3C3e7734Fe7DCF77DB2B72E4A848));

        address liquidityPool = addressProvider.getContractAddress("LiquidityPool");
        address liquifier = addressProvider.getContractAddress("Liquifier");
        address weETH = addressProvider.getContractAddress("WeETH");
        address eETH = addressProvider.getContractAddress("EETH");
        address etherFiTimelock = addressProvider.getContractAddress("EtherFiTimelock");

        address wETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        address stETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
        address wstETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

        address depositAdapterImpl = address(new DepositAdapter(liquidityPool, liquifier, weETH, eETH, wETH, stETH, wstETH));

        bytes memory initializerData = abi.encodeWithSelector(DepositAdapter.initialize.selector);
        DepositAdapter depositAdapter = DepositAdapter(payable(address(new UUPSProxy(address(depositAdapterImpl), initializerData))));

        depositAdapter.transferOwnership(etherFiTimelock);

        console.log("DepositAdapter deployed at: ", address(depositAdapter));
        console.log("DepositAdapter Owner: ", depositAdapter.owner());
    }
}
