// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";

import "forge-std/StdJson.sol";
import "forge-std/console2.sol";

import "../Create2Factory.sol";

import "../../src/EtherFiNode.sol";
import "../../src/EtherFiNodesManager.sol";
import "../../src/EtherFiRateLimiter.sol";

import "../../src/RoleRegistry.sol";
import "../../src/StakingManager.sol";
import "../../src/UUPSProxy.sol";

interface IUpgradable {
    function upgradeTo(address newImplementation) external;
}

interface ICreate2Factory {
    function deploy(bytes memory code, bytes32 salt) external payable returns (address);
    function verify(address addr, bytes32 salt, bytes memory code) external view returns (bool);
    function computeAddress(bytes32 salt, bytes memory code) external view returns (address);
}

// Interface for the OLD contract to clear whitelist before upgrade
interface ICurrentEtherFiNodesManager {
    function allowedForwardedEigenpodCalls(bytes4 selector) external view returns (bool);
    function allowedForwardedExternalCalls(bytes4 selector, address target) external view returns (bool);
    function updateAllowedForwardedEigenpodCalls(bytes4 selector, bool allowed) external;
    function updateAllowedForwardedExternalCalls(bytes4 selector, address target, bool allowed) external;
}

/**
 * @title DeployPectraUpgradeCreate2
 * @notice Complete EIP-7002 deployment script using Create2Factory for mainnet
 * @dev Includes: Rate Limiter deployment, contract implementations, following DeployV3Prelude pattern
 *
 * Steps:
 * 1. Deploy EtherFiRateLimiter (impl + proxy + init)
 * 2. Deploy new implementations using Create2Factory (StakingManager, EtherFiNodesManager, EtherFiNode)
 * 3. Generate transaction data for governance execution
 *
 * Usage: forge script script/el-exits/DeployPectraUpgradeCreate2.s.sol --rpc-url <mainnet-rpc> --broadcast --verify
 */
contract DeployPectraUpgradeCreate2 is Script {
    using stdJson for string;

    // === CREATE2 FACTORY ===
    ICreate2Factory constant factory = ICreate2Factory(0x356d1B83970CeF2018F2c9337cDdb67dff5AEF99);

    // === MAINNET CONTRACT ADDRESSES ===
    address constant STAKING_MANAGER_PROXY = 0x25e821b7197B146F7713C3b89B6A4D83516B912d;
    address constant LIQUIDITY_POOL_PROXY = 0x308861A430be4cce5502d0A12724771Fc6DaF216;
    address constant ETHERFI_NODES_MANAGER_PROXY = 0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F;
    address constant AUCTION_MANAGER = 0x00C452aFFee3a17d9Cecc1Bcd2B8d5C7635C4CB9;
    address constant ETHERFI_NODE_BEACON = 0x3c55986Cfee455E2533F4D29006634EcF9B7c03F;
    address constant ROLE_REGISTRY = 0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9;
    address constant ETH_DEPOSIT_CONTRACT = 0x00000000219ab540356cBB839Cbe05303d7705Fa;
    address constant EIGEN_POD_MANAGER = 0x91E677b07F7AF907ec9a428aafA9fc14a0d3A338;
    address constant DELEGATION_MANAGER = 0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A;

    // === DEPLOYMENT SALT ===
    // Final commit hash: 6c46a46c04f65838ca4ea2750f2b293e01117eb7
    bytes32 constant commitHashSalt = bytes32(bytes20(hex"6c46a46c04f65838ca4ea2750f2b293e01117eb7"));

    // === DEPLOYED CONTRACTS ===
    EtherFiRateLimiter public rateLimiterProxy;
    address public stakingManagerImpl;
    address public etherFiNodesManagerImpl;
    address public etherFiNodeImpl;

    function run() external {
        vm.startBroadcast();

        console2.log("========================================");
        console2.log("EIP-7002 Mainnet Deployment (Create2)");
        console2.log("========================================");
        console2.log("Deployer:", msg.sender);
        console2.log("Factory:", address(factory));
        console2.log("Salt:", vm.toString(commitHashSalt));
        console2.log("");

        // Step 1: Deploy EtherFiRateLimiter
        deployRateLimiter();

        // Step 2: Deploy new implementations using Create2Factory
        deployImplementationsCreate2();

        // Step 3: Print governance transaction data
        printGovernanceInstructions();

        vm.stopBroadcast();
    }

    function deployRateLimiter() internal {
        console2.log("=== STEP 1: DEPLOYING ETHERFI RATE LIMITER ===");

        address rateLimiterImpl;
        // Deploy implementation using Create2Factory
        {
            string memory contractName = "EtherFiRateLimiter";
            bytes memory constructorArgs = abi.encode(ROLE_REGISTRY);
            bytes memory bytecode = abi.encodePacked(type(EtherFiRateLimiter).creationCode, constructorArgs);
            rateLimiterImpl = deployCreate2(contractName, constructorArgs, bytecode, commitHashSalt, true);
            console2.log("Rate limiter implementation:", rateLimiterImpl);
        }

        address rateLimiterProxyAddr;
        // Deploy proxy using Create2Factory
        {
            string memory contractName = "UUPSProxy";
            bytes memory constructorArgs = abi.encode(address(rateLimiterImpl), "");
            bytes memory bytecode = abi.encodePacked(type(UUPSProxy).creationCode, constructorArgs);
            rateLimiterProxyAddr = deployCreate2(contractName, constructorArgs, bytecode, commitHashSalt, true);
        }
        rateLimiterProxy = EtherFiRateLimiter(rateLimiterProxyAddr);
        console2.log("Rate limiter proxy:", address(rateLimiterProxy));

        // Initialize
        rateLimiterProxy.initialize();
        console2.log(unicode"✓ Rate limiter deployed and initialized");
        console2.log("");
    }

    function deployImplementationsCreate2() internal {
        console2.log("=== STEP 2: DEPLOYING NEW IMPLEMENTATIONS (CREATE2) ===");

        // StakingManager
        {
            string memory contractName = "StakingManager";
            bytes memory constructorArgs = abi.encode(LIQUIDITY_POOL_PROXY, ETHERFI_NODES_MANAGER_PROXY, ETH_DEPOSIT_CONTRACT, AUCTION_MANAGER, ETHERFI_NODE_BEACON, ROLE_REGISTRY);
            bytes memory bytecode = abi.encodePacked(type(StakingManager).creationCode, constructorArgs);
            stakingManagerImpl = deployCreate2(contractName, constructorArgs, bytecode, commitHashSalt, true);
        }

        // EtherFiNodesManager (with rate limiter)
        {
            string memory contractName = "EtherFiNodesManager";
            bytes memory constructorArgs = abi.encode(
                STAKING_MANAGER_PROXY,
                ROLE_REGISTRY,
                address(rateLimiterProxy) // New rate limiter integration
            );
            bytes memory bytecode = abi.encodePacked(type(EtherFiNodesManager).creationCode, constructorArgs);
            etherFiNodesManagerImpl = deployCreate2(contractName, constructorArgs, bytecode, commitHashSalt, true);
        }

        // EtherFiNode
        {
            string memory contractName = "EtherFiNode";
            bytes memory constructorArgs = abi.encode(LIQUIDITY_POOL_PROXY, ETHERFI_NODES_MANAGER_PROXY, EIGEN_POD_MANAGER, DELEGATION_MANAGER, ROLE_REGISTRY);
            bytes memory bytecode = abi.encodePacked(type(EtherFiNode).creationCode, constructorArgs);
            etherFiNodeImpl = deployCreate2(contractName, constructorArgs, bytecode, commitHashSalt, true);
        }

        console2.log(unicode"✓ All implementations deployed using Create2");
        console2.log("");
    }

    function printGovernanceInstructions() internal view {
        console2.log("========================================");
        console2.log("GOVERNANCE TRANSACTION DATA");
        console2.log("========================================");
        console2.log("");

        console2.log("=== CONTRACT UPGRADE TRANSACTIONS ===");
        console2.log("Safe Address: 0x9f26d4C958fD811A1F59B01B86Be7dFFc9d20761 (timelock)");
        console2.log("");

        // Generate upgrade transaction data
        bytes memory upgradeStakingManager = abi.encodeWithSelector(bytes4(keccak256("upgradeTo(address)")), stakingManagerImpl);

        bytes memory upgradeNodesManager = abi.encodeWithSelector(bytes4(keccak256("upgradeTo(address)")), etherFiNodesManagerImpl);

        bytes memory upgradeEtherFiNode = abi.encodeWithSelector(StakingManager.upgradeEtherFiNode.selector, etherFiNodeImpl);

        console2.log("Transaction 1 - Upgrade StakingManager:");
        console2.log("  Target:", STAKING_MANAGER_PROXY);
        console2.log("  Data:", vm.toString(upgradeStakingManager));
        console2.log("");

        console2.log("Transaction 2 - Upgrade EtherFiNodesManager:");
        console2.log("  Target:", ETHERFI_NODES_MANAGER_PROXY);
        console2.log("  Data:", vm.toString(upgradeNodesManager));
        console2.log("");

        console2.log("Transaction 3 - Upgrade EtherFiNode:");
        console2.log("  Target:", STAKING_MANAGER_PROXY);
        console2.log("  Data:", vm.toString(upgradeEtherFiNode));
        console2.log("");

        console2.log("=== DEPLOYMENT SUMMARY ===");
        console2.log("");
        console2.log("New Contracts Deployed:");
        console2.log("- EtherFiRateLimiter Proxy:", address(rateLimiterProxy));
        console2.log("");

        console2.log("New Implementations (Create2):");
        console2.log("- StakingManager:", stakingManagerImpl);
        console2.log("- EtherFiNodesManager:", etherFiNodesManagerImpl);
        console2.log("- EtherFiNode:", etherFiNodeImpl);
        console2.log("");

        console2.log("Updated JSON Files Needed:");
        console2.log("Replace placeholder addresses in:");
        console2.log("- phase2_contract_upgrades.json:");
        console2.log("  * 0x2222... -> ", stakingManagerImpl);
        console2.log("  * 0x3333... -> ", etherFiNodesManagerImpl);
        console2.log("  * 0x4444... -> ", etherFiNodeImpl);
        console2.log("");
        console2.log("- phase4_rate_limiter_init.json:");
        console2.log("  * RATE_LIMITER_PROXY_ADDRESS -> ", address(rateLimiterProxy));
        console2.log("");

        console2.log("New Features:");
        console2.log(unicode"✓ EL-triggered exits");
        console2.log(unicode"✓ Consolidation requests");
        console2.log(unicode"✓ Rate limiting system");
        console2.log(unicode"✓ User-specific call forwarding");
        console2.log("");

        console2.log("Next Steps:");
        console2.log("1. Update JSON files with deployed addresses");
        console2.log("2. Submit phase2_contract_upgrades.json to 3CP process");
        console2.log("3. After upgrades: submit phase3_role_assignments.json");
        console2.log("4. After roles: submit phase4_rate_limiter_init.json");
    }

    // === CREATE2 DEPLOYMENT HELPER (following DeployV3Prelude pattern) ===

    function deployCreate2(string memory contractName, bytes memory constructorArgs, bytes memory bytecode, bytes32 salt, bool logging) internal returns (address) {
        address predictedAddress = factory.computeAddress(salt, bytecode);
        address deployedAddress = factory.deploy(bytecode, salt);
        require(deployedAddress == predictedAddress, "Deployment address mismatch");

        if (logging) {
            // Create JSON deployment log (exact same format as DeployV3Prelude)
            string memory deployLog = string.concat("{\n", '  "contractName": "', contractName, '",\n', '  "deploymentParameters": {\n', '    "factory": "', vm.toString(address(factory)), '",\n', '    "salt": "', vm.toString(salt), '",\n', formatConstructorArgs(constructorArgs, contractName), "\n", "  },\n", '  "deployedAddress": "', vm.toString(deployedAddress), '"\n', "}");

            // Save deployment log
            string memory root = vm.projectRoot();
            string memory logFileDir = string.concat(root, "/deployment/", contractName);
            vm.createDir(logFileDir, true);

            string memory logFileName = string.concat(logFileDir, "/", getTimestampString(), ".json");
            vm.writeFile(logFileName, deployLog);

            // Console output
            console2.log("=== Deployment Successful ===");
            console2.log("Contract:", contractName);
            console2.log("Deployed to:", deployedAddress);
            console2.log("Deployment log saved to:", logFileName);
        }

        return deployedAddress;
    }

    function verify(address addr, bytes memory bytecode, bytes32 salt) internal view returns (bool) {
        return factory.verify(addr, salt, bytecode);
    }

    //-------------------------------------------------------------------------
    // Constructor args formatting (same as DeployV3Prelude)
    //-------------------------------------------------------------------------

    function formatConstructorArgs(bytes memory constructorArgs, string memory contractName) internal view returns (string memory) {
        // Load artifact JSON
        string memory artifactJson = readArtifact(contractName);

        // Parse ABI inputs for the constructor
        bytes memory inputsArray = vm.parseJson(artifactJson, "$.abi[?(@.type == 'constructor')].inputs");
        if (inputsArray.length == 0) {
            // No constructor, return empty object
            return '    "constructorArgs": {}';
        }

        // Decode to get the number of inputs
        bytes[] memory decodedInputs = abi.decode(inputsArray, (bytes[]));
        uint256 inputCount = decodedInputs.length;

        // Collect param names and types in arrays
        (string[] memory names, string[] memory typesArr) = getConstructorMetadata(artifactJson, inputCount);

        // Build the final JSON
        return decodeParamsJson(constructorArgs, names, typesArr);
    }

    function readArtifact(string memory contractName) internal view returns (string memory) {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/out/", contractName, ".sol/", contractName, ".json");
        return vm.readFile(path);
    }

    function getConstructorMetadata(string memory artifactJson, uint256 inputCount) internal pure returns (string[] memory, string[] memory) {
        string[] memory names = new string[](inputCount);
        string[] memory typesArr = new string[](inputCount);

        for (uint256 i = 0; i < inputCount; i++) {
            string memory baseQuery = string.concat("$.abi[?(@.type == 'constructor')].inputs[", vm.toString(i), "]");
            names[i] = trim(string(vm.parseJson(artifactJson, string.concat(baseQuery, ".name"))));
            typesArr[i] = trim(string(vm.parseJson(artifactJson, string.concat(baseQuery, ".type"))));
        }
        return (names, typesArr);
    }

    function decodeParamsJson(bytes memory constructorArgs, string[] memory names, string[] memory typesArr) internal pure returns (string memory) {
        uint256 offset;
        string memory json = '    "constructorArgs": {\n';

        for (uint256 i = 0; i < names.length; i++) {
            (string memory val, uint256 newOffset) = decodeParam(constructorArgs, offset, typesArr[i]);
            offset = newOffset;

            json = string.concat(json, '      "', names[i], '": "', val, '"', (i < names.length - 1) ? ",\n" : "\n");
        }
        return string.concat(json, "    }");
    }

    //-------------------------------------------------------------------------
    // Parameter decoding helpers (same as DeployV3Prelude)
    //-------------------------------------------------------------------------

    function decodeParam(bytes memory data, uint256 offset, string memory t) internal pure returns (string memory, uint256) {
        if (!isDynamicType(t)) {
            bytes memory chunk = slice(data, offset, 32);
            return (formatStaticParam(t, bytes32(chunk)), offset + 32);
        } else {
            uint256 dataLoc = uint256(bytes32(slice(data, offset, 32)));
            offset += 32;
            uint256 len = uint256(bytes32(slice(data, dataLoc, 32)));
            bytes memory dynData = slice(data, dataLoc + 32, len);
            return (formatDynamicParam(t, dynData), offset);
        }
    }

    function formatStaticParam(string memory t, bytes32 chunk) internal pure returns (string memory) {
        if (compare(t, "address")) {
            return vm.toString(address(uint160(uint256(chunk))));
        } else if (compare(t, "uint256")) {
            return vm.toString(uint256(chunk));
        } else if (compare(t, "bool")) {
            return uint256(chunk) != 0 ? "true" : "false";
        } else if (compare(t, "bytes32")) {
            return vm.toString(chunk);
        }
        revert("Unsupported static type");
    }

    function formatDynamicParam(string memory t, bytes memory dynData) internal pure returns (string memory) {
        if (compare(t, "string")) {
            return string(dynData);
        } else if (compare(t, "bytes")) {
            return vm.toString(dynData);
        }
        revert("Unsupported dynamic type");
    }

    function isDynamicType(string memory t) internal pure returns (bool) {
        return startsWith(t, "string") || startsWith(t, "bytes");
    }

    function slice(bytes memory data, uint256 start, uint256 length) internal pure returns (bytes memory) {
        require(data.length >= start + length, "slice_outOfBounds");
        bytes memory out = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            out[i] = data[start + i];
        }
        return out;
    }

    function trim(string memory str) internal pure returns (string memory) {
        bytes memory b = bytes(str);
        uint256 start;
        uint256 end = b.length;
        while (start < b.length && uint8(b[start]) <= 0x20) {
            start++;
        }
        while (end > start && uint8(b[end - 1]) <= 0x20) {
            end--;
        }
        bytes memory out = new bytes(end - start);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = b[start + i];
        }
        return string(out);
    }

    function compare(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function startsWith(string memory str, string memory prefix) internal pure returns (bool) {
        bytes memory s = bytes(str);
        bytes memory p = bytes(prefix);
        if (s.length < p.length) {
            return false;
        }
        for (uint256 i = 0; i < p.length; i++) {
            if (s[i] != p[i]) {
                return false;
            }
        }
        return true;
    }

    function getTimestampString() internal view returns (string memory) {
        uint256 ts = block.timestamp;
        string memory year = vm.toString((ts / 31_536_000) + 1970);
        string memory month = pad(vm.toString(((ts % 31_536_000) / 2_592_000) + 1));
        string memory day = pad(vm.toString(((ts % 2_592_000) / 86_400) + 1));
        string memory hour = pad(vm.toString((ts % 86_400) / 3600));
        string memory minute = pad(vm.toString((ts % 3600) / 60));
        string memory second = pad(vm.toString(ts % 60));
        return string.concat(year, "-", month, "-", day, "-", hour, "-", minute, "-", second);
    }

    function pad(string memory n) internal pure returns (string memory) {
        return bytes(n).length == 1 ? string.concat("0", n) : n;
    }

    // Helper functions for manual execution if needed
    function onlyUpgradeContracts() external {
        vm.startBroadcast();
        console2.log("=== MANUAL CONTRACT UPGRADES ===");

        IUpgradable(STAKING_MANAGER_PROXY).upgradeTo(stakingManagerImpl);
        console2.log(unicode"✓ StakingManager upgraded");

        IUpgradable(ETHERFI_NODES_MANAGER_PROXY).upgradeTo(etherFiNodesManagerImpl);
        console2.log(unicode"✓ EtherFiNodesManager upgraded");

        StakingManager(STAKING_MANAGER_PROXY).upgradeEtherFiNode(etherFiNodeImpl);
        console2.log(unicode"✓ EtherFiNode upgraded");

        vm.stopBroadcast();
    }
}
