// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import "src/EtherFiRewardsRouter.sol";
import "src/UUPSProxy.sol";
import "../../src/helpers/AddressProvider.sol";

/* Tenderly
 *  source .env && forge script ./script/deploys/DeployEtherFiRewardsRouter.s.sol:DeployEtherFiRewardsRouter --rpc-url $TENDERLY_RPC_URL --broadcast --etherscan-api-key $TENDERLY_ACCESS_CODE --verify --verifier-url $TENDERLY_VERIFIER_URL  --slow -vvvv
*/

/* Tenderly
 *  source .env && forge script ./script/deploys/DeployEtherFiRewardsRouter.s.sol:DeployEtherFiRewardsRouter --rpc-url MAINNET_RPC_URL --broadcast --etherscan-api-key $ETHERSCAN_API_KEY --verify --slow -vvvv
*/

contract DeployEtherFiRewardsRouter is Script {

    AddressProvider public addressProvider;
    ///////////////////////////////////////
    address roleRegistryProxyAddress = address(0x0); //replace with deployed RoleRegistryProxy address
    address treasuryGnosisSafeAddress = address(0xCa1b2Ca29e43e6405De9B41647487e8728E517A0);
    //////////////////////////////////////

    function run() external {
        address addressProviderAddress = vm.envAddress("CONTRACT_REGISTRY");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        addressProvider = AddressProvider(addressProviderAddress);

        address liquidityPoolProxyAddress = addressProvider.getContractAddress("LiquidityPool");
        vm.startBroadcast(deployerPrivateKey);

        EtherFiRewardsRouter etherFiRewardsRouterImplementation = new EtherFiRewardsRouter(liquidityPoolProxyAddress, roleRegistryProxyAddress, treasuryGnosisSafeAddress);
        UUPSProxy etherFiRewardsRouterProxy = new UUPSProxy(address(etherFiRewardsRouterImplementation), "");
    }
}
