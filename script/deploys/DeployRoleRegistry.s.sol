// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import "src/RoleRegistry.sol";
import "src/UUPSProxy.sol";
import "../../src/helpers/AddressProvider.sol";

/* Tenderly
 *  source .env && forge script ./script/deploys/DeployRoleRegistry.s.sol:DeployRoleRegistry --rpc-url $TENDERLY_RPC_URL --broadcast --etherscan-api-key $TENDERLY_ACCESS_CODE --verify --verifier-url $TENDERLY_VERIFIER_URL  --slow -vvvv
*/

/* Tenderly
 *  source .env && forge script ./script/deploys/DeployRoleRegistry.s.sol:DeployRoleRegistry --rpc-url MAINNET_RPC_URL --broadcast --etherscan-api-key $ETHERSCAN_API_KEY --verify --slow -vvvv
*/

contract DeployRoleRegistry is Script {

    AddressProvider public addressProvider;
    ///////////////////////////////////////
    address superAdmin = address(0x0); //replace with actual super admin address
    //////////////////////////////////////

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        RoleRegistry roleRegistryImplementation = new RoleRegistry();
        bytes memory initializerData =  abi.encodeWithSelector(RoleRegistry.initialize.selector, superAdmin);
        UUPSProxy roleRegistryProxy = new UUPSProxy(address(roleRegistryImplementation), initializerData);

        vm.stopBroadcast();
    }
}
