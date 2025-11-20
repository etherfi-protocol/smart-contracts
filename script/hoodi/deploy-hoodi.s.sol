// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title DeployHoodi
 * @notice Script to deploy contract implementations on Hoodi testnet using Create2Factory
 * 
 * @dev Usage:
 *   1. Ensure contracts are compiled: `forge build`
 *   2. Ensure Create2Factory is deployed at CREATE2_FACTORY_HOODI address
 *   3. Set HOODI_RPC_URL environment variable or use --fork-url flag
 *   4. Set HOODI_PRIVATE_KEY environment variable
 *   5. Run: `forge script script/hoodi/deploy-hoodi.s.sol --fork-url $HOODI_RPC_URL -vvv --broadcast --verify`
 * 
 * @dev Create2 Deployment:
 *   - Uses Create2Factory for deterministic addresses
 *   - Salts are defined in Hoodi-Salts.s.sol
 *   - All implementations are deployed using Create2
 */

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import {Deployed_Hoodi} from "../deploys/Deployed_Hoodi.s.sol";
import {HoodiSalts} from "./Hoodi-Salts.s.sol";
import {StakingManager} from "../../src/StakingManager.sol";
import {EtherFiNodesManager} from "../../src/EtherFiNodesManager.sol";
import {EtherFiRedemptionManager} from "../../src/EtherFiRedemptionManager.sol";
import {EtherFiNode} from "../../src/EtherFiNode.sol";

interface ICreate2Factory {
    function deploy(bytes memory code, string memory contractName) external payable returns (address);
}

contract DeployHoodi is Script, Deployed_Hoodi, HoodiSalts {
    // Create2Factory for deterministic deployments
    ICreate2Factory constant factory = ICreate2Factory(CREATE2_FACTORY_HOODI);

    // Artifact paths for contracts (no constructor params)
    string constant LIQUIDITY_POOL_ARTIFACT = "LiquidityPool.sol:LiquidityPool";
    string constant ETHERFI_ADMIN_ARTIFACT = "EtherFiAdmin.sol:EtherFiAdmin";
    string constant TNFT_ARTIFACT = "TNFT.sol:TNFT";
    string constant ETHERFI_VIEWER_ARTIFACT = "helpers/EtherFiViewer.sol:EtherFiViewer";
    string constant ETHERFI_REWARDS_ROUTER_ARTIFACT = "EtherFiRewardsRouter.sol:EtherFiRewardsRouter";
    string constant EETH_ARTIFACT = "EETH.sol:EETH";
    string constant WEETH_ARTIFACT = "WeETH.sol:WeETH";
    string constant MEMBERSHIP_MANAGER_ARTIFACT = "MembershipManager.sol:MembershipManager";
    string constant WITHDRAW_REQUEST_NFT_ARTIFACT = "WithdrawRequestNFT.sol:WithdrawRequestNFT";
    string constant BUCKET_RATE_LIMITER_ARTIFACT = "BucketRateLimiter.sol:BucketRateLimiter";

    // Contract names for Create2Factory (must match Hoodi-Salts.s.sol)
    string constant STAKING_MANAGER_NAME = "StakingManager";
    string constant ETHERFI_NODE_NAME = "EtherFiNode";
    string constant ETHERFI_NODES_MANAGER_NAME = "EtherFiNodesManager";
    string constant ETHERFI_REDEMPTION_MANAGER_NAME = "EtherFiRedemptionManager";

    // Deployed implementation addresses
    address public stakingManagerImpl;
    address public etherFiNodeImpl;
    address public etherFiNodesManagerImpl;
    address public etherFiRedemptionManagerImpl;

    function run() external {
        // Fork Hoodi testnet
        string memory rpc;
        try vm.envString("HOODI_RPC_URL") returns (string memory envRpc) {
            rpc = envRpc;
        } catch {
            try vm.rpcUrl("hoodi") returns (string memory configRpc) {
                rpc = configRpc;
            } catch {
                revert("Please set HOODI_RPC_URL env var, add 'hoodi' to foundry.toml rpc_endpoints, or use --fork-url flag");
            }
        }
        vm.createSelectFork(rpc);

        uint256 deployerPrivateKey = vm.envUint("HOODI_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console2.log("========================================");
        console2.log("Deploying Hoodi Contract Implementations (Create2)");
        console2.log("========================================");
        console2.log("Deployer: %s", vm.toString(deployer));
        console2.log("Create2Factory: %s", vm.toString(address(factory)));
        console2.log("");

        // vm.startBroadcast(deployerPrivateKey);
        vm.startPrank(deployer);

        deployStakingManager();
        deployEtherFiNodesManager();
        deployEtherFiRedemptionManager();
        deployEtherFiNode();

        // vm.stopBroadcast();
        vm.stopPrank();

        // Print summary
        printSummary();
    }

    function deployStakingManager() internal {
        console2.log("Deploying STAKING_MANAGER implementation...");
        stakingManagerImpl = _deployStakingManager();
        console2.log("  [OK] STAKING_MANAGER deployed: %s\n", vm.toString(stakingManagerImpl));
    }

    function deployEtherFiNodesManager() internal {
        console2.log("Deploying ETHERFI_NODES_MANAGER implementation...");
        etherFiNodesManagerImpl = _deployEtherFiNodesManager();
        console2.log("  [OK] ETHERFI_NODES_MANAGER deployed: %s\n", vm.toString(etherFiNodesManagerImpl));
    }

    function deployEtherFiRedemptionManager() internal {
        console2.log("Deploying ETHERFI_REDEMPTION_MANAGER implementation...");
        etherFiRedemptionManagerImpl = _deployEtherFiRedemptionManager();
        console2.log("  [OK] ETHERFI_REDEMPTION_MANAGER deployed: %s\n", vm.toString(etherFiRedemptionManagerImpl));
    }

    function deployEtherFiNode() internal {
        console2.log("Deploying ETHERFI_NODE implementation...");
        etherFiNodeImpl = _deployEtherFiNode();
        console2.log("  [OK] ETHERFI_NODE deployed: %s\n", vm.toString(etherFiNodeImpl));
    }

    // Internal deployment functions
    /// @notice Deploys implementation using Create2Factory for deterministic addresses
    /// @param artifactPath Path to contract artifact (e.g., "LiquidityPool.sol:LiquidityPool")
    /// @param contractName Contract name for Create2 salt (must match Hoodi-Salts.s.sol)
    function _deployImplementation(string memory artifactPath, string memory contractName) internal returns (address) {
        bytes memory bytecode = vm.getCode(artifactPath);
        require(bytecode.length > 0, "Failed to get bytecode");
        
        bytes32 salt = keccak256(abi.encodePacked(contractName));
        bytes32 initCodeHash = keccak256(bytecode);
        address predictedAddress = vm.computeCreate2Address(salt, initCodeHash, address(factory));
        console2.log("  Predicted address: %s", vm.toString(predictedAddress));
        
        // Check if contract already exists at this address
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(predictedAddress)
        }
        if (codeSize > 0) {
            console2.log("  Contract already deployed, skipping deployment");
            return predictedAddress;
        }
        
        address deployedAddress = factory.deploy(bytecode, contractName);
        require(deployedAddress == predictedAddress, "Deployment address mismatch");
        require(deployedAddress != address(0), "Failed to deploy implementation");
        
        console2.log("  Deployed address: %s", vm.toString(deployedAddress));
        return deployedAddress;
    }

    function _deployStakingManager() internal returns (address) {
        bytes memory constructorArgs = abi.encode(
            LIQUIDITY_POOL,
            ETHERFI_NODES_MANAGER,
            ETH2_DEPOSIT,
            AUCTION_MANAGER,
            ETHERFI_NODE_BEACON,
            ROLE_REGISTRY
        );
        bytes memory bytecode = abi.encodePacked(
            type(StakingManager).creationCode,
            constructorArgs
        );
        
        bytes32 salt = keccak256(abi.encodePacked(STAKING_MANAGER_NAME));
        bytes32 initCodeHash = keccak256(bytecode);
        address predictedAddress = vm.computeCreate2Address(salt, initCodeHash, address(factory));
        console2.log("  Predicted address: %s", vm.toString(predictedAddress));
        
        // Check if contract already exists at this address
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(predictedAddress)
        }
        if (codeSize > 0) {
            console2.log("  Contract already deployed, skipping deployment");
            return predictedAddress;
        }
        
        address deployedAddress = factory.deploy(bytecode, STAKING_MANAGER_NAME);
        require(deployedAddress == predictedAddress, "Deployment address mismatch");
        console2.log("  Deployed address: %s", vm.toString(deployedAddress));
        return deployedAddress;
    }

    function _deployEtherFiNodesManager() internal returns (address) {
        bytes memory constructorArgs = abi.encode(
            STAKING_MANAGER,
            ROLE_REGISTRY,
            ETHERFI_RATE_LIMITER
        );
        bytes memory bytecode = abi.encodePacked(
            type(EtherFiNodesManager).creationCode,
            constructorArgs
        );
        
        bytes32 salt = keccak256(abi.encodePacked(ETHERFI_NODES_MANAGER_NAME));
        bytes32 initCodeHash = keccak256(bytecode);
        address predictedAddress = vm.computeCreate2Address(salt, initCodeHash, address(factory));
        console2.log("  Predicted address: %s", vm.toString(predictedAddress));
        
        // Check if contract already exists at this address
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(predictedAddress)
        }
        if (codeSize > 0) {
            console2.log("  Contract already deployed, skipping deployment");
            return predictedAddress;
        }
        
        address deployedAddress = factory.deploy(bytecode, ETHERFI_NODES_MANAGER_NAME);
        require(deployedAddress == predictedAddress, "Deployment address mismatch");
        console2.log("  Deployed address: %s", vm.toString(deployedAddress));
        return deployedAddress;
    }

    function _deployEtherFiRedemptionManager() internal returns (address) {
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
        
        bytes32 salt = keccak256(abi.encodePacked(ETHERFI_REDEMPTION_MANAGER_NAME));
        bytes32 initCodeHash = keccak256(bytecode);
        address predictedAddress = vm.computeCreate2Address(salt, initCodeHash, address(factory));
        console2.log("  Predicted address: %s", vm.toString(predictedAddress));
        
        // Check if contract already exists at this address
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(predictedAddress)
        }
        if (codeSize > 0) {
            console2.log("  Contract already deployed, skipping deployment");
            return predictedAddress;
        }
        
        address deployedAddress = factory.deploy(bytecode, ETHERFI_REDEMPTION_MANAGER_NAME);
        require(deployedAddress == predictedAddress, "Deployment address mismatch");
        console2.log("  Deployed address: %s", vm.toString(deployedAddress));
        return deployedAddress;
    }

    function _deployEtherFiNode() internal returns (address) {
        bytes memory constructorArgs = abi.encode(
            LIQUIDITY_POOL,
            ETHERFI_NODES_MANAGER,
            EIGEN_POD_MANAGER,
            DELEGATION_MANAGER,
            ROLE_REGISTRY
        );
        bytes memory bytecode = abi.encodePacked(
            type(EtherFiNode).creationCode,
            constructorArgs
        );
        
        bytes32 salt = keccak256(abi.encodePacked(ETHERFI_NODE_NAME));
        bytes32 initCodeHash = keccak256(bytecode);
        address predictedAddress = vm.computeCreate2Address(salt, initCodeHash, address(factory));
        console2.log("  Predicted address: %s", vm.toString(predictedAddress));
        
        // Check if contract already exists at this address
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(predictedAddress)
        }
        if (codeSize > 0) {
            console2.log("  Contract already deployed, skipping deployment");
            return predictedAddress;
        }
        
        address deployedAddress = factory.deploy(bytecode, ETHERFI_NODE_NAME);
        require(deployedAddress == predictedAddress, "Deployment address mismatch");
        console2.log("  Deployed address: %s", vm.toString(deployedAddress));
        return deployedAddress;
    }

    function printSummary() internal view {
        console2.log("\n========================================");
        console2.log("Deployment Summary");
        console2.log("========================================");
        console2.log("STAKING_MANAGER: %s", vm.toString(stakingManagerImpl));
        console2.log("ETHERFI_NODES_MANAGER: %s", vm.toString(etherFiNodesManagerImpl));
        console2.log("ETHERFI_REDEMPTION_MANAGER: %s", vm.toString(etherFiRedemptionManagerImpl));
        console2.log("ETHERFI_NODE: %s", vm.toString(etherFiNodeImpl));
        console2.log("");
    }
}

