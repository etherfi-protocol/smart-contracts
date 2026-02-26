// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import {LiquidityPool} from "../../../src/LiquidityPool.sol";
import {EtherFiNodesManager} from "../../../src/EtherFiNodesManager.sol";
import {Deployed} from "../../deploys/Deployed.s.sol";
import {Utils, ICreate2Factory} from "../../utils/utils.sol";

/**
command: 
forge script script/upgrades/CrossPodApproval/deploy.s.sol:CrossPodApprovalDeployScript --fork-url $MAINNET_RPC_URL --verify --etherscan-api-key $ETHERSCAN_API_KEY
 */

contract CrossPodApprovalDeployScript is Script, Deployed, Utils {
    ICreate2Factory public constant factory = ICreate2Factory(0x356d1B83970CeF2018F2c9337cDdb67dff5AEF99);

    address liquidityPoolImpl;
    address etherFiNodesManagerImpl;
    bytes32 public constant commitHashSalt = bytes32(bytes20(hex"a6b8291c80e620ed48cdf999f546fee4f1ecfd48"));

    function run() public {
        console2.log("================================================");
        console2.log("======================== Deploying Liquidity Pool and EtherFiNodesManager ========================");
        console2.log("================================================");
        console2.log("");

        vm.startBroadcast();
        // vm.startPrank(ETHERFI_OPERATING_ADMIN);

        // LiquidityPool
        {
            string memory contractName = "LiquidityPool";
            bytes memory constructorArgs = abi.encode();
            bytes memory bytecode = abi.encodePacked(
                type(LiquidityPool).creationCode,
                constructorArgs
            );
            liquidityPoolImpl = deploy(contractName, constructorArgs, bytecode, commitHashSalt, false, factory);
        }
        console2.log("LiquidityPool deployed at:", liquidityPoolImpl);

        // EtherFiNodesManager implementation
        {
            string memory contractName = "EtherFiNodesManager";
            bytes memory constructorArgs = abi.encode(
                STAKING_MANAGER,
                ROLE_REGISTRY,
                ETHERFI_RATE_LIMITER
            );
            bytes memory bytecode = abi.encodePacked(
                type(EtherFiNodesManager).creationCode,
                constructorArgs
            );
            etherFiNodesManagerImpl = deploy(contractName, constructorArgs, bytecode, commitHashSalt, false, factory);
        }
        console2.log("EtherFiNodesManager deployed at:", etherFiNodesManagerImpl);
    }
}