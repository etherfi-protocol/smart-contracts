// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title UpgradeHoodi
 * @notice Script to upgrade contracts on Hoodi testnet that need upgrades using Create2Factory
 * 
 * @dev Usage:
 *   1. Ensure contracts are compiled: `forge build`
 *   2. Ensure Create2Factory is deployed at CREATE2_FACTORY_HOODI address
 *   3. Set HOODI_RPC_URL environment variable or use --fork-url flag
 *   4. Set HOODI_PRIVATE_KEY environment variable (must be protocol upgrader for most contracts, owner for some)
 *   5. Run: `forge script script/hoodi/Upgrade-hoodi.s.sol --fork-url $HOODI_RPC_URL -vvvv`
 */

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import {Deployed_Hoodi} from "../deploys/Deployed_Hoodi.s.sol";
import {HoodiSalts} from "./Hoodi-Salts.s.sol"; 
import {IRoleRegistry} from "../../src/interfaces/IRoleRegistry.sol";
import {IStakingManager} from "../../src/interfaces/IStakingManager.sol";
import {StakingManager} from "../../src/StakingManager.sol";
import {EtherFiNodesManager} from "../../src/EtherFiNodesManager.sol";
import {EtherFiRedemptionManager} from "../../src/EtherFiRedemptionManager.sol";
import {EtherFiNode} from "../../src/EtherFiNode.sol";
import {EtherFiRedemptionManagerTemp} from "./EtherFiRedemptionManagerTemp.sol";

interface IUpgradeable {
    function upgradeTo(address newImplementation) external;
}

interface ICreate2Factory {
    function deploy(bytes memory code, string memory contractName) external payable returns (address);
}

contract UpgradeHoodi is Script, Deployed_Hoodi, HoodiSalts {
    // Create2Factory for deterministic deployments
    ICreate2Factory constant factory = ICreate2Factory(CREATE2_FACTORY_HOODI);

    // Contract addresses that need upgrades
    address constant STAKING_MANAGER_PROXY = 0xDbE50E32Ed95f539F36bA315a75377FBc35aBc12;
    address constant ETHERFI_NODES_MANAGER_PROXY = 0x7579194b8265e3Aa7df451c6BD2aff5B1FC5F945;
    address constant ETHERFI_REDEMPTION_MANAGER_PROXY = 0x95AeCaa1B0C3A04C8aFf5D05f27363e9e3367D6F;

    // Contract names for Create2Factory (must match Hoodi-Salts.s.sol)
    string constant STAKING_MANAGER_NAME = "StakingManager";
    string constant ETHERFI_NODE_NAME = "EtherFiNode";
    string constant ETHERFI_NODES_MANAGER_NAME = "EtherFiNodesManager";
    string constant ETHERFI_REDEMPTION_MANAGER_NAME = "EtherFiRedemptionManager";
    string constant ETHERFI_REDEMPTION_MANAGER_TEMP_NAME = "EtherFiRedemptionManagerTemp";

    struct UpgradeResult {
        string name;
        bool upgraded;
        string reason;
    }

    UpgradeResult[] public upgradeResults;
    
    // Deployer address (set in run())
    address public deployer;

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
        deployer = vm.addr(deployerPrivateKey);
        
        console2.log("========================================");
        console2.log("Upgrading Hoodi Contracts (Create2)");
        console2.log("========================================");
        console2.log("Deployer: %s", vm.toString(deployer));
        console2.log("Create2Factory: %s", vm.toString(address(factory)));
        console2.log("");

        // Get RoleRegistry to check protocol upgrader
        IRoleRegistry roleRegistry = IRoleRegistry(ROLE_REGISTRY);
        address protocolUpgrader = roleRegistry.owner();
        console2.log("Protocol Upgrader (RoleRegistry owner): %s", vm.toString(protocolUpgrader));

        // Check if deployer is protocol upgrader
        bool isProtocolUpgrader = (deployer == protocolUpgrader);
        console2.log("Deployer is protocol upgrader: %s\n", isProtocolUpgrader ? "YES" : "NO");

        vm.startBroadcast(deployerPrivateKey);
        // vm.startPrank(deployer);
        console2.log("Broadcasting from: %s", vm.toString(deployer));

        // Upgrade contracts that require protocol upgrader
        if (isProtocolUpgrader) {
            upgradeStakingManager();
            upgradeEtherFiNodesManager();
            upgradeEtherFiRedemptionManager();
            upgradeEtherFiNodeBeacon();
        } else {
            console2.log("[SKIP] Skipping protocol upgrader contracts (deployer is not protocol upgrader)\n");
        }

        vm.stopBroadcast();
        // vm.stopPrank();

        // Print summary
        printSummary();
    }

    // Protocol Upgrader Contracts
    function upgradeStakingManager() internal {
        console2.log("Upgrading STAKING_MANAGER...");
        address impl = _deployStakingManager();
        IUpgradeable(STAKING_MANAGER_PROXY).upgradeTo(impl);
        console2.log("  [OK] STAKING_MANAGER upgraded: %s\n", vm.toString(impl));
        upgradeResults.push(UpgradeResult("STAKING_MANAGER", true, ""));
    }

    function upgradeEtherFiNodesManager() internal {
        console2.log("Upgrading ETHERFI_NODES_MANAGER...");
        address impl = _deployEtherFiNodesManager();
        IUpgradeable(ETHERFI_NODES_MANAGER_PROXY).upgradeTo(impl);
        console2.log("  [OK] ETHERFI_NODES_MANAGER upgraded: %s\n", vm.toString(impl));
        upgradeResults.push(UpgradeResult("ETHERFI_NODES_MANAGER", true, ""));
    }

    function upgradeEtherFiRedemptionManager() internal {
        address tempImpl = _deployEtherFiRedemptionManagerTemp();
        IUpgradeable(ETHERFI_REDEMPTION_MANAGER_PROXY).upgradeTo(tempImpl);
        console2.log("  [OK] ETHERFI_REDEMPTION_MANAGER_TEMP upgraded: %s\n", vm.toString(tempImpl));

        console2.log("Clearnig out slot for upgrade...");
        EtherFiRedemptionManagerTemp(payable(ETHERFI_REDEMPTION_MANAGER_PROXY)).clearOutSlotForUpgrade();
        console2.log("  [OK] ETHERFI_REDEMPTION_MANAGER_TEMP slot cleared \n");

        console2.log("Upgrading ETHERFI_REDEMPTION_MANAGER...");
        address impl = _deployEtherFiRedemptionManager();
        IUpgradeable(ETHERFI_REDEMPTION_MANAGER_PROXY).upgradeTo(impl);
        console2.log("  [OK] ETHERFI_REDEMPTION_MANAGER upgraded: %s\n", vm.toString(impl));
        upgradeResults.push(UpgradeResult("ETHERFI_REDEMPTION_MANAGER", true, ""));
    }

    function upgradeEtherFiNodeBeacon() internal {
        console2.log("Upgrading ETHERFI_NODE_BEACON...");
        address impl = _deployEtherFiNode();
        IStakingManager(STAKING_MANAGER_PROXY).upgradeEtherFiNode(impl);
        console2.log("  [OK] ETHERFI_NODE_BEACON upgraded: %s\n", vm.toString(impl));
        upgradeResults.push(UpgradeResult("ETHERFI_NODE_BEACON", true, ""));
    }

    // Internal deployment functions

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

    function _deployEtherFiRedemptionManagerTemp() internal returns (address) {
        bytes memory constructorArgs = abi.encode(
            LIQUIDITY_POOL,
            EETH,
            WEETH,
            TREASURY,
            ROLE_REGISTRY
        );
        bytes memory bytecode = abi.encodePacked(
            type(EtherFiRedemptionManagerTemp).creationCode,
            constructorArgs
        );

        bytes32 salt = keccak256(abi.encodePacked(ETHERFI_REDEMPTION_MANAGER_TEMP_NAME));
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
        address deployedAddress = factory.deploy(bytecode, ETHERFI_REDEMPTION_MANAGER_TEMP_NAME);
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
        console2.log("Upgrade Summary");
        console2.log("========================================");
        
        uint256 successCount = 0;
        uint256 failCount = 0;
        uint256 skipCount = 0;

        for (uint256 i = 0; i < upgradeResults.length; i++) {
            UpgradeResult memory result = upgradeResults[i];
            if (result.upgraded) {
                console2.log("[OK] %s", result.name);
                successCount++;
            } else if (bytes(result.reason).length > 0) {
                console2.log("[%s] %s: %s", 
                    keccak256(bytes(result.reason)) == keccak256(bytes("Not owner")) ? "SKIP" : "FAIL",
                    result.name,
                    result.reason
                );
                if (keccak256(bytes(result.reason)) == keccak256(bytes("Not owner"))) {
                    skipCount++;
                } else {
                    failCount++;
                }
            } else {
                console2.log("[FAIL] %s", result.name);
                failCount++;
            }
        }

        console2.log("\nTotal: %d upgraded, %d failed, %d skipped", successCount, failCount, skipCount);
    }
}
