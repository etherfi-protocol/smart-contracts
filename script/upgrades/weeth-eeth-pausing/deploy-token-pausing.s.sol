// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import {WeETH as WeETHContract} from "../../../src/WeETH.sol";
import {EETH as EETHContract} from "../../../src/EETH.sol";
import {MembershipManager} from "../../../src/MembershipManager.sol";
import {MembershipNFT} from "../../../src/MembershipNFT.sol";
import {Utils} from "../../utils/utils.sol";

/**
 * @title DeployAuditedPausingContracts
 * @notice Deploys implementation contracts for the audited pausing contracts PR
 * @dev Uses CREATE2 for deterministic deployment addresses
 * 
 * Changes deployed:
 * - WeETH: Pausing functionality
 * - EETH: Pausing functionality
 * - MembershipManager: Pausing functionality for NFTs
 * - MembershipNFT: Pausing functionality for NFTs

Command:
forge script script/upgrades/weeth-eeth-pausing/deploy-token-pausing.s.sol --fork-url $MAINNET_RPC_URL -vvvv
 */

contract DeployTokenPausing is Utils {
    // Deployed implementation addresses (populated after deployment)
    address public weETHImpl;
    address public eETHImpl;
    address public membershipManagerImpl;
    address public membershipNFTImpl;

    // Salt for deterministic deployment - use commit hash or unique identifier
    bytes32 commitHashSalt = bytes32(bytes20(hex"0b0b98b174770750ef716029f080f660c9623500")); // final audited commit hash

    function run() public {
        console2.log("=======================================================");
        console2.log("=== Deploying WeETH and EETH Pausing Implementation ===");
        console2.log("=======================================================");
        console2.log("");

        vm.startBroadcast();

        // 1. EETH Implementation
        {
            string memory contractName = "EETH";
            bytes memory constructorArgs = abi.encode(
                ROLE_REGISTRY,
                LIQUIDITY_POOL
            );
            bytes memory bytecode = abi.encodePacked(
                type(EETHContract).creationCode,
                constructorArgs
            );
            eETHImpl = deploy(contractName, constructorArgs, bytecode, commitHashSalt, true, mainnetCreate2Factory);
        }

        // 2. WeETH Implementation
        {
            string memory contractName = "WeETH";
            bytes memory constructorArgs = abi.encode(
                EETH,
                LIQUIDITY_POOL,
                ROLE_REGISTRY
            );
            bytes memory bytecode = abi.encodePacked(
                type(WeETHContract).creationCode,
                constructorArgs
            );
            weETHImpl = deploy(contractName, constructorArgs, bytecode, commitHashSalt, true, mainnetCreate2Factory);
        }

        // 3. MembershipManager Implementation
        {
            string memory contractName = "MembershipManager";
            bytes memory constructorArgs = abi.encode();
            bytes memory bytecode = abi.encodePacked(
                type(MembershipManager).creationCode,
                constructorArgs
            );
            membershipManagerImpl = deploy(contractName, constructorArgs, bytecode, commitHashSalt, true, mainnetCreate2Factory);
        }

        // 4. MembershipNFT Implementation
        {
            string memory contractName = "MembershipNFT";
            bytes memory constructorArgs = abi.encode(
                EETH
            );
            bytes memory bytecode = abi.encodePacked(
                type(MembershipNFT).creationCode,
                constructorArgs
            );
            membershipNFTImpl = deploy(contractName, constructorArgs, bytecode, commitHashSalt, true, mainnetCreate2Factory);
        }

        vm.stopBroadcast();

        // Print summary
        console2.log("");
        console2.log("=== Deployment Summary ===");
        console2.log("EETH Implementation:", eETHImpl);
        console2.log("WeETH Implementation:", weETHImpl);
        console2.log("MembershipManager Implementation:", membershipManagerImpl);
        console2.log("MembershipNFT Implementation:", membershipNFTImpl);
    }
}
