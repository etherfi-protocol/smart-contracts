// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import {EtherFiNode} from "../../../src/EtherFiNode.sol";
import {EtherFiRedemptionManager} from "../../../src/EtherFiRedemptionManager.sol";
import {EtherFiRestaker} from "../../../src/EtherFiRestaker.sol";
import {EtherFiRewardsRouter} from "../../../src/EtherFiRewardsRouter.sol";
import {Liquifier} from "../../../src/Liquifier.sol";
import {WithdrawRequestNFT} from "../../../src/WithdrawRequestNFT.sol";
import {EtherFiViewer} from "../../../src/helpers/EtherFiViewer.sol";
import {Utils} from "../../utils/utils.sol";

/**
 * @title DeployReauditedContracts
 * @notice Deploys implementation contracts for the re-audit fixes PR
 * @dev Uses CREATE2 for deterministic deployment addresses
 * 
 * Changes deployed:
 * - EtherFiNode: Caps ETH transfers by totalValueOutOfLp
 * - EtherFiRedemptionManager: Fee handling order fix & totalRedeemableAmount fix
 * - EtherFiRestaker: Lido withdrawal fix & withdrawEther cap
 * - EtherFiRewardsRouter: withdrawToLiquidityPool cap
 * - Liquifier: stETH rounding fix, withdrawEther cap, simplified getTotalPooledEther
 * - WithdrawRequestNFT: Event emission fix
 * - EtherFiViewer: Changed from validatorPubkeyToInfo to validatorPubkeyHashToInfo

Command:
forge script script/upgrades/reaudit-fixes/deploy-reaudit-fixes.s.sol --fork-url $MAINNET_RPC_URL -vvvv
 */

contract DeployReauditFixes is Utils {
    // Deployed implementation addresses (populated after deployment)
    address public etherFiNodeImpl;
    address public etherFiRedemptionManagerImpl;
    address public etherFiRestakerImpl;
    address public etherFiRewardsRouterImpl;
    address public liquifierImpl;
    address public withdrawRequestNFTImpl;
    address public etherFiViewerImpl;

    // Salt for deterministic deployment - use commit hash or unique identifier
    bytes32 commitHashSalt = bytes32(bytes20(hex"77381e3f2ef7ac8ff04f2a044e59432e2486195d")); // final audited commit hash

    function run() public {
        console2.log("================================================");
        console2.log("=== Deploying Re-audit Fixes Implementation ====");
        console2.log("================================================");
        console2.log("");

        vm.startBroadcast();

        // 1. EtherFiNode Implementation
        {
            string memory contractName = "EtherFiNode";
            bytes memory constructorArgs = abi.encode(
                LIQUIDITY_POOL,
                ETHERFI_NODES_MANAGER,
                EIGENLAYER_POD_MANAGER,
                EIGENLAYER_DELEGATION_MANAGER,
                ROLE_REGISTRY
            );
            bytes memory bytecode = abi.encodePacked(
                type(EtherFiNode).creationCode,
                constructorArgs
            );
            etherFiNodeImpl = deploy(contractName, constructorArgs, bytecode, commitHashSalt, true, mainnetCreate2Factory);
        }

        // 2. EtherFiRedemptionManager Implementation
        {
            string memory contractName = "EtherFiRedemptionManager";
            bytes memory constructorArgs = abi.encode(
                LIQUIDITY_POOL,
                EETH,
                WEETH,
                TREASURY,
                ROLE_REGISTRY,
                ETHERFI_RESTAKER
            );
            bytes memory bytecode = abi.encodePacked(
                type(EtherFiRedemptionManager).creationCode,
                constructorArgs
            );
            etherFiRedemptionManagerImpl = deploy(contractName, constructorArgs, bytecode, commitHashSalt, true, mainnetCreate2Factory);
        }

        // 3. EtherFiRestaker Implementation
        {
            string memory contractName = "EtherFiRestaker";
            bytes memory constructorArgs = abi.encode(
                EIGENLAYER_REWARDS_COORDINATOR,
                ETHERFI_REDEMPTION_MANAGER
            );
            bytes memory bytecode = abi.encodePacked(
                type(EtherFiRestaker).creationCode,
                constructorArgs
            );
            etherFiRestakerImpl = deploy(contractName, constructorArgs, bytecode, commitHashSalt, true, mainnetCreate2Factory);
        }

        // 4. EtherFiRewardsRouter Implementation
        {
            string memory contractName = "EtherFiRewardsRouter";
            bytes memory constructorArgs = abi.encode(
                LIQUIDITY_POOL,
                TREASURY,
                ROLE_REGISTRY
            );
            bytes memory bytecode = abi.encodePacked(
                type(EtherFiRewardsRouter).creationCode,
                constructorArgs
            );
            etherFiRewardsRouterImpl = deploy(contractName, constructorArgs, bytecode, commitHashSalt, true, mainnetCreate2Factory);
        }

        // 5. Liquifier Implementation (no constructor args - uses initializer)
        {
            string memory contractName = "Liquifier";
            bytes memory constructorArgs = abi.encode();
            bytes memory bytecode = abi.encodePacked(
                type(Liquifier).creationCode,
                constructorArgs
            );
            liquifierImpl = deploy(contractName, constructorArgs, bytecode, commitHashSalt, true, mainnetCreate2Factory);
        }

        // 6. WithdrawRequestNFT Implementation
        {
            string memory contractName = "WithdrawRequestNFT";
            bytes memory constructorArgs = abi.encode(WITHDRAW_REQUEST_NFT_BUYBACK_SAFE);
            bytes memory bytecode = abi.encodePacked(
                type(WithdrawRequestNFT).creationCode,
                constructorArgs
            );
            withdrawRequestNFTImpl = deploy(contractName, constructorArgs, bytecode, commitHashSalt, true, mainnetCreate2Factory);
        }

        // 7. EtherFiViewer Implementation
        {
            string memory contractName = "EtherFiViewer";
            bytes memory constructorArgs = abi.encode(
                EIGENLAYER_POD_MANAGER,
                EIGENLAYER_DELEGATION_MANAGER
            );
            bytes memory bytecode = abi.encodePacked(
                type(EtherFiViewer).creationCode,
                constructorArgs
            );
            etherFiViewerImpl = deploy(contractName, constructorArgs, bytecode, commitHashSalt, true, mainnetCreate2Factory);
        }

        vm.stopBroadcast();

        // Print summary
        console2.log("");
        console2.log("=== Deployment Summary ===");
        console2.log("EtherFiNode Implementation:", etherFiNodeImpl);
        console2.log("EtherFiRedemptionManager Implementation:", etherFiRedemptionManagerImpl);
        console2.log("EtherFiRestaker Implementation:", etherFiRestakerImpl);
        console2.log("EtherFiRewardsRouter Implementation:", etherFiRewardsRouterImpl);
        console2.log("Liquifier Implementation:", liquifierImpl);
        console2.log("WithdrawRequestNFT Implementation:", withdrawRequestNFTImpl);
        console2.log("EtherFiViewer Implementation:", etherFiViewerImpl);
    }
}
