// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import {EtherFiRestaker} from "../../../src/EtherFiRestaker.sol";
import {Utils} from "../../utils/utils.sol";

/**
 * @title DeployEtherFiRestakerWithRoles
 * @notice Deploys the new EtherFiRestaker implementation with per-function RoleRegistry roles
 *
 * Constructor now takes a fourth arg: _rateLimiter
 *
 * Command:
 * forge script script/upgrades/restaker-roles/deploy.s.sol --fork-url $MAINNET_RPC_URL -vvvv
 */
contract DeployEtherFiRestakerWithRoles is Utils {
    address public etherFiRestakerImpl;

    // Salt derived from a short description of this change
    bytes32 commitHashSalt = keccak256("restaker-roles-v1");

    function run() public {
        console2.log("================================================");
        console2.log("=== Deploying EtherFiRestaker (roles upgrade) ==");
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

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== Deployment Summary ===");
        console2.log("EtherFiRestaker Implementation:", etherFiRestakerImpl);
    }
}
