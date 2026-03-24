// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import {EtherFiRestaker} from "../../../src/EtherFiRestaker.sol";
import {EtherFiRedemptionManager} from "../../../src/EtherFiRedemptionManager.sol";
import {Utils} from "../../utils/utils.sol";

/**
 * @title DeployEtherFiRestakerAndRedemptionManagerWithRoles
 * @notice Deploys the new EtherFiRestaker implementation with per-function RoleRegistry roles
 *
 * Constructor now takes a third arg: _roleRegistry
 *
 * Command:
 * forge script script/upgrades/restaker-roles/deploy.s.sol --fork-url $MAINNET_RPC_URL -vvvv
 */
contract DeployEtherFiRestakerAndRedemptionManagerWithRoles is Utils {
    address public etherFiRestakerImpl;
    address public redemptionManagerImpl;

    // Salt derived from a short description of this change. to update this post final audit
    bytes32 commitHashSalt = keccak256("restaker-roles-v2");

    function run() public {
        console2.log("================================================");
        console2.log("=== Deploying EtherFiRestaker + EtherFiRedemptionManager (roles upgrade) ==");
        console2.log("================================================");

        vm.startBroadcast();

        {
            string memory contractName = "EtherFiRestaker";
            bytes memory constructorArgs = abi.encode(
                EIGENLAYER_REWARDS_COORDINATOR,
                ETHERFI_REDEMPTION_MANAGER,
                ROLE_REGISTRY,
                ETHERFI_RATE_LIMITER
            );
            bytes memory bytecode = abi.encodePacked(
                type(EtherFiRestaker).creationCode,
                constructorArgs
            );
            etherFiRestakerImpl = deploy(contractName, constructorArgs, bytecode, commitHashSalt, true, mainnetCreate2Factory);
        }
        {
            string memory contractName = "EtherFiRedemptionManager";
            bytes memory constructorArgs = abi.encode(
                LIQUIDITY_POOL,
                EETH,
                WEETH,
                WITHDRAW_REQUEST_NFT_BUYBACK_SAFE,
                ROLE_REGISTRY,
                ETHERFI_RESTAKER,
                PRIORITY_WITHDRAWAL_QUEUE
            );
            bytes memory bytecode = abi.encodePacked(
                type(EtherFiRedemptionManager).creationCode,
                constructorArgs
            );
            redemptionManagerImpl = deploy(contractName, constructorArgs, bytecode, commitHashSalt, true, mainnetCreate2Factory);
        }

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== Deployment Summary ===");
        console2.log("EtherFiRedemptionManager Implementation:", redemptionManagerImpl);
        console2.log("EtherFiRestaker Implementation:", etherFiRestakerImpl);
    }
}
