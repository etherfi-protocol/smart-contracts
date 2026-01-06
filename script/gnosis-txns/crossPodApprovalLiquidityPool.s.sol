// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import {LiquidityPool} from "../../src/LiquidityPool.sol";
import {EtherFiNodesManager} from "../../src/EtherFiNodesManager.sol";
import {Deployed} from "../deploys/Deployed.s.sol";
import {Utils, ICreate2Factory} from "../utils/Utils.sol";

/**
command: 
forge script script/gnosis-txns/crossPodApprovalLiquidityPool.s.sol:CrossPodApprovalLiquidityPoolScript --rpc-url $MAINNET_RPC_URL --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY --slow -vvvv
 */

contract CrossPodApprovalLiquidityPoolScript is Script, Deployed, Utils {
    ICreate2Factory factory = ICreate2Factory(0x356d1B83970CeF2018F2c9337cDdb67dff5AEF99);

    address liquidityPoolImpl;
    address etherFiNodesManagerImpl;
    bytes32 commitHashSalt = bytes32(bytes20(hex"674dbc5c457d54a8e68133e20486ad8a99ed2843"));

    // === MAINNET CONTRACT ADDRESSES ===
    address constant LIQUIDITY_POOL_PROXY = 0x308861A430be4cce5502d0A12724771Fc6DaF216;
    
    function run() public {
        console2.log("================================================");
        console2.log("======================== Running Cross Pod Approval Liquidity Pool ========================");
        console2.log("================================================");
        console2.log("");

        vm.startBroadcast();
        // vm.startPrank(0x2aCA71020De61bb532008049e1Bd41E451aE8AdC);

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
    }
}