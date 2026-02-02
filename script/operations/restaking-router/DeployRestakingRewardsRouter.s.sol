// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../../../src/RestakingRewardsRouter.sol";
import "../../../src/UUPSProxy.sol";
import "../../utils/utils.sol";

// forge script script/operations/restaking-router/DeployRestakingRewardsRouter.s.sol --fork-url $MAINNET_RPC_URL -vvvv
contract DeployRestakingRewardsRouter is Script, Utils {
    address routerImpl;
    address routerProxy;
    bytes32 commitHashSalt =
        bytes32(bytes20(hex"1a10a60fc25f1c7f7052123edbe683ed2524943d"));

    ICreate2Factory constant factory = ICreate2Factory(0x356d1B83970CeF2018F2c9337cDdb67dff5AEF99);
    address constant REWARD_TOKEN_ADDRESS = 0xec53bF9167f50cDEB3Ae105f56099aaaB9061F83;

    function run() public {
        console2.log("================================================");
        console2.log(
            "======== Running Deploy Restaking Rewards Router ========"
        );
        console2.log("================================================");
        console2.log("");

        vm.startBroadcast();

        // Deploy RestakingRewardsRouter implementation
        {
            string memory contractName = "RestakingRewardsRouter";
            bytes memory constructorArgs = abi.encode(
                ROLE_REGISTRY,
                REWARD_TOKEN_ADDRESS,
                LIQUIDITY_POOL
            );
            bytes memory bytecode = abi.encodePacked(
                type(RestakingRewardsRouter).creationCode,
                constructorArgs
            );
            routerImpl = deploy(
                contractName,
                constructorArgs,
                bytecode,
                commitHashSalt,
                true,
                factory
            );
        }
        console2.log("====== Restaking Rewards Router Implementation Deployed Successfully");
        console2.log("================================================");
        console2.log("");
        console2.log("====== Restaking Rewards Router Implementation Address:");
        console2.log(routerImpl);
        console2.log("================================================");
        console2.log("");

        // Deploy UUPSProxy
        {
            string memory contractName = "UUPSProxy";

            // Prepare initialization data (initialize takes no parameters)
            bytes memory initializerData = abi.encodeWithSelector(
                RestakingRewardsRouter.initialize.selector
            );

            bytes memory constructorArgs = abi.encode(
                routerImpl,
                initializerData
            );
            bytes memory bytecode = abi.encodePacked(
                type(UUPSProxy).creationCode,
                constructorArgs
            );
            routerProxy = deploy(
                contractName,
                constructorArgs,
                bytecode,
                commitHashSalt,
                true,
                factory
            );
        }

        console2.log("====== Restaking Rewards Router Deployed Successfully");
        console2.log("================================================");
        console2.log("");

        console2.log("====== Restaking Rewards Router Address:");
        console2.log(routerProxy);
        console2.log("================================================");
        console2.log("");

        vm.stopBroadcast();
    }
}
