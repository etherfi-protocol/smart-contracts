// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import "src/EtherFiRewardsRouter.sol";
import "src/UUPSProxy.sol";

/*
 *  source .env && forge script ./script/deploys/DeployEtherFiRewardsRouter.s.sol:DeployEtherFiRewardsRouter --rpc-url $TENDERLY_RPC_URL --broadcast --etherscan-api-key $TENDERLY_ACCESS_CODE --verify --verifier-url $TENDERLY_VERIFIER_URL
*/

contract DeployEtherFiRewardsRouter is Script {

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address lp_address = address(0x308861A430be4cce5502d0A12724771Fc6DaF216);
        address admin = address(0); //after deployed use correct role registry address
        vm.startBroadcast(deployerPrivateKey);

        EtherFiRewardsRouter etherFiRewardsRouterImplementation = new EtherFiRewardsRouter(lp_address, admin);
        UUPSProxy etherFiRewardsRouterProxy = new UUPSProxy(address(etherFiRewardsRouterImplementation), "");
        EtherFiRewardsRouter etherFiRewardsRouterInstance = EtherFiRewardsRouter(payable(etherFiRewardsRouterProxy));
    }
}
