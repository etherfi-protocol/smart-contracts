// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import "../src/EtherFiRateLimiter.sol";
import "../src/UUPSProxy.sol";
import "../src/helpers/AddressProvider.sol";

/* Deploy Command
 *  source .env && forge script ./script/deploys/DeployEtherFiRateLimiter.sol:DeployEtherFiRateLimiter --rpc-url MAINNET_RPC_URL --broadcast --etherscan-api-key $ETHERSCAN_API_KEY --verify --slow -vvvv
*/

contract DeployEtherFiRateLimiter is Script {

    AddressProvider public addressProvider;
    ///////////////////////////////////////
    address roleRegistryProxyAddress; 
    //////////////////////////////////////

    function run() external {

        address addressProviderAddress = 0xd4bBb3Ba0827Ed7abC6977C572910d25a1488296;
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey); 

        addressProvider = AddressProvider(addressProviderAddress);
        roleRegistryProxyAddress = addressProvider.getContractAddress("RoleRegistry");
        // address timelockAddress = addressProvider.getContractAddress("EtherFiTimelock");
        console2.log("RoleRegistry address:", roleRegistryProxyAddress);

        bytes memory initializerData = abi.encodeWithSelector(EtherFiRateLimiter.initialize.selector);
        EtherFiRateLimiter etherFiRateLimiterImplementation = new EtherFiRateLimiter(roleRegistryProxyAddress);
        UUPSProxy etherFiRateLimiterProxy = new UUPSProxy(address(etherFiRateLimiterImplementation), initializerData);
        // EtherFiRateLimiter etherFiRateLimiterInstance = EtherFiRateLimiter(address(etherFiRateLimiterProxy));
        
        console2.log("EtherFiRateLimiter implementation deployed at:", address(etherFiRateLimiterImplementation));
        console2.log("EtherFiRateLimiter proxy deployed at:", address(etherFiRateLimiterProxy));
        
        // Transfer ownership to timelock
        // etherFiRateLimiterInstance.transferOwnership(address(timelockAddress));
        // console2.log("Ownership transferred to timelock:", timelockAddress);

        vm.stopBroadcast();
    }
}