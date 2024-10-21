// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

import "src/RoleRegistry.sol";
import "src/UUPSProxy.sol";
import "../../src/helpers/AddressProvider.sol";

/* Tenderly
 *  source .env && forge script ./script/deploys/DeployRoleRegistry.s.sol:DeployRoleRegistry --rpc-url $TESTNET_RPC_URL --broadcast --etherscan-api-key $TESTNET_RPC_URL --verify --verifier-url $TENDERLY_VERIFIER_URL  --slow -vvvv
*/

/* Tenderly
 *  source .env && forge script ./script/deploys/DeployRoleRegistry.s.sol:DeployRoleRegistry --rpc-url MAINNET_RPC_URL --broadcast --etherscan-api-key $ETHERSCAN_API_KEY --verify --slow -vvvv
*/

contract DeployRoleRegistry is Script {

    AddressProvider public addressProvider;
    ///////////////////////////////////////
    address superAdmin = address(0x8D5AAc5d3d5cda4c404fA7ee31B0822B648Bb150); //replace with actual super admin address
    //////////////////////////////////////

    function run() external {
        vm.startBroadcast();

        RoleRegistry roleRegistryImplementation = new RoleRegistry();
        bytes memory initializerData =  abi.encodeWithSelector(RoleRegistry.initialize.selector, superAdmin);
        UUPSProxy roleRegistryProxy = new UUPSProxy(address(roleRegistryImplementation), initializerData);

        vm.stopBroadcast();
    }
}
