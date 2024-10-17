// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import "src/EtherFiRewardsRouter.sol";
import "src/UUPSProxy.sol";
import "../../src/helpers/AddressProvider.sol";
import "forge-std/console.sol";

/* Tenderly
 *  source .env && forge script ./script/deploys/DeployEtherFiRewardsRouter.s.sol:DeployEtherFiRewardsRouter --rpc-url $TENDERLY_RPC_URL --broadcast --etherscan-api-key $TENDERLY_ACCESS_CODE --verify --verifier-url $TENDERLY_VERIFIER_URL  --slow -vvvv
*/

/* Tenderly
 *  source .env && forge script ./script/deploys/DeployEtherFiRewardsRouter.s.sol:DeployEtherFiRewardsRouter --rpc-url MAINNET_RPC_URL --broadcast --etherscan-api-key $ETHERSCAN_API_KEY --verify --slow -vvvv
*/

contract DeployEtherFiRewardsRouter is Script {

    AddressProvider public addressProvider;
    ///////////////////////////////////////
    address roleRegistryProxyAddress = address(0x084C62123FccfC9fA7cbc3952cE9321259C0EcB9); //replace with deployed RoleRegistryProxy address
    address treasuryGnosisSafeAddress = address(0x0c83EAe1FE72c390A02E426572854931EefF93BA);
    address etherfiRouterAdmin = address(0xc351788DDb96cD98d99E62C97f57952A8b3Fc1B5);
    //////////////////////////////////////

    function run() external {

        address addressProviderAddress = vm.envAddress("CONTRACT_REGISTRY");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        RoleRegistry roleRegistryInstance = RoleRegistry(roleRegistryProxyAddress);
        roleRegistryInstance.grantRole(keccak256("ETHERFI_ROUTER_ADMIN"), etherfiRouterAdmin);

        addressProvider = AddressProvider(addressProviderAddress);

        address liquidityPoolProxyAddress = addressProvider.getContractAddress("LiquidityPool");
        bytes memory initializerData =  abi.encodeWithSelector(EtherFiRewardsRouter.initialize.selector);
        EtherFiRewardsRouter etherFiRewardsRouterImplementation = new EtherFiRewardsRouter(liquidityPoolProxyAddress, roleRegistryProxyAddress, treasuryGnosisSafeAddress);
        UUPSProxy etherFiRewardsRouterProxy = new UUPSProxy(address(etherFiRewardsRouterImplementation), initializerData);
    }
}
