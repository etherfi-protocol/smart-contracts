// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import "src/EtherFiRewardsRouter.sol";
import "src/UUPSProxy.sol";
import "../../src/helpers/AddressProvider.sol";
import "forge-std/console.sol";

/* Deploy Command
 *  source .env && forge script ./script/deploys/DeployEtherFiRewardsRouter.s.sol:DeployEtherFiRewardsRouter --rpc-url MAINNET_RPC_URL --broadcast --etherscan-api-key $ETHERSCAN_API_KEY --verify --slow -vvvv
*/

contract DeployEtherFiRewardsRouter is Script {

    AddressProvider public addressProvider;
    ///////////////////////////////////////
    address roleRegistryProxyAddress = address(0x1d3Af47C1607A2EF33033693A9989D1d1013BB50); //replace with deployed RoleRegistryProxy address
    address treasuryGnosisSafeAddress = address(0x0c83EAe1FE72c390A02E426572854931EefF93BA);
    address etherfiRouterAdmin = address(0xc13C06899a9BbEbB3E2b38dBe86e4Ea8852AFC9b);
    //////////////////////////////////////

    function run() external {

        address addressProviderAddress = vm.envAddress("CONTRACT_REGISTRY");

        vm.startBroadcast();

        RoleRegistry roleRegistryInstance = RoleRegistry(roleRegistryProxyAddress);
        roleRegistryInstance.grantRole(keccak256("ETHERFI_REWARDS_ROUTER_ADMIN_ROLE"), etherfiRouterAdmin);

        addressProvider = AddressProvider(addressProviderAddress);

        address liquidityPoolProxyAddress = addressProvider.getContractAddress("LiquidityPool");
        bytes memory initializerData =  abi.encodeWithSelector(EtherFiRewardsRouter.initialize.selector);
        EtherFiRewardsRouter etherFiRewardsRouterImplementation = new EtherFiRewardsRouter(liquidityPoolProxyAddress, treasuryGnosisSafeAddress, roleRegistryProxyAddress);
        UUPSProxy etherFiRewardsRouterProxy = new UUPSProxy(address(etherFiRewardsRouterImplementation), initializerData);
    }
}
