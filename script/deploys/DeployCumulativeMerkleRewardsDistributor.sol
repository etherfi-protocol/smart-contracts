// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import "src/CumulativeMerkleRewardsDistributor.sol";
import "src/UUPSProxy.sol";
import "../../src/helpers/AddressProvider.sol";
import "forge-std/console.sol";

/* Deploy Command
 *  source .env && forge script ./script/deploys/DeployCumulativeMerkleRewardsDistributor.sol:DeployCumulativeMerkleRewardsDistributor --rpc-url MAINNET_RPC_URL --broadcast --etherscan-api-key $ETHERSCAN_API_KEY --verify --slow -vvvv
*/

contract DeployCumulativeMerkleRewardsDistributor is Script {

    AddressProvider public addressProvider;
    ///////////////////////////////////////
    address roleRegistryProxyAddress; 
    //////////////////////////////////////

    function run() external {

        address addressProviderAddress = vm.envAddress("CONTRACT_REGISTRY");

        vm.startBroadcast(); 


        addressProvider = AddressProvider(addressProviderAddress);
        roleRegistryProxyAddress = addressProvider.getContractAddress("RoleRegistry");
        address timelockAddress = addressProvider.getContractAddress("EtherFiTimelock");
        console2.log("RoleRegistry address:", roleRegistryProxyAddress);

        bytes memory initializerData =  abi.encodeWithSelector(CumulativeMerkleRewardsDistributor.initialize.selector);
        CumulativeMerkleRewardsDistributor cumulativeMerkleRewardsDistributorImplementation = new CumulativeMerkleRewardsDistributor(roleRegistryProxyAddress);
        UUPSProxy cumulativeMerkleRewardsDistributorProxy = new UUPSProxy(address(cumulativeMerkleRewardsDistributorImplementation), initializerData);
        CumulativeMerkleRewardsDistributor cumulativeMerkleInstance = CumulativeMerkleRewardsDistributor(address(cumulativeMerkleRewardsDistributorProxy));
        //cumulativeMerkleInstance.grantRole(keccak256("CUMULATIVE_MERKLE_REWARDS_DISTRIBUTOR_ADMIN_ROLE"), msg.sender);
        cumulativeMerkleInstance.transferOwnership(address(timelockAddress));

        vm.stopBroadcast();
    }
}
