// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "forge-std/StdJson.sol";
import  "src/LiquidRefer.sol";
import "../../src/UUPSProxy.sol";
import "../Create2Factory.sol";

/**
 * @title Deploy LiquidRefer on Scroll
 * @notice Deploys the LiquidRefer implementation and UUPS proxy using Create2Factory on Scroll
 *
 * This script will:
 * 1. Compute and display predicted deployment addresses (deterministic across all chains)
 * 2. Deploy the LiquidRefer implementation using Create2
 * 3. Deploy the UUPSProxy with initialization using Create2
 * 4. Set ownership to the Scroll Contract Controller
 * 5. Verify the deployment
 * 6. Save deployment logs to ./deployment/{contractName}/{timestamp}.json
 *
 * Key Features:
 * - Uses Create2Factory (0x356d1B83970CeF2018F2c9337cDdb67dff5AEF99) for deterministic addresses
 * - Same addresses across all EVM chains (Mainnet, Scroll, Base, Arbitrum, etc.)
 *
 * Usage:
 *
 * 1. Dry run (compute addresses without deploying):
 *    forge script ./script/liquid/DeployLiquidReferScroll.s.sol:DeployLiquidReferScroll
 *    Note: Will fail at deployment step but shows predicted addresses
 *
 * 2. Scroll deployment:
 *    source .env && forge script ./script/liquid/DeployLiquidReferScroll.s.sol:DeployLiquidReferScroll \
 *      --rpc-url $SCROLL_RPC_URL \
 *      --broadcast \
 *      --verify \
 *      --verifier-url https://api.scrollscan.com/api \
 *      --etherscan-api-key $SCROLLSCAN_API_KEY \
 *      --slow \
 *      -vvvv
 *
 * Important: The contract addresses MUST match across all chains for the deployment to work.
 */
contract DeployLiquidReferScroll is Script {
    using stdJson for string;

    // Create2Factory - will be deployed in this script
    Create2Factory public factory;

    // Scroll contract controller (owner)
    address constant scrollContractController = 0x3cD08f51D0EA86ac93368DE31822117cd70CECA3;

    // Salt - sha256sum of src/LiquidRefer.sol
    bytes32 commitHashSalt = bytes32((hex"da57a51d4edaff4a8ab070f9c5691910280f3c577c7667fc3d97555e9ec0fa04"));

    function run() external {
        console.log("\n========================================");
        console.log("LiquidRefer Scroll Deployment");
        console.log("========================================\n");

        // Load deployer private key
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer address:", deployer);

        // Start deployment
        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deploy Create2Factory
        console.log("\n--- Step 1: Deploying Create2Factory ---");
        factory = new Create2Factory();
        console.log("Create2Factory deployed at:", address(factory));
        saveCreate2FactoryLog(address(factory));

        // Display addresses for verification
        displayAddresses();

        // Compute and display predicted addresses
        console.log("\n========================================");
        console.log("Predicted Deployment Addresses");
        console.log("========================================");
        computePredictedAddresses();

        // Step 2: Deploy LiquidRefer implementation
        console.log("\n--- Step 2: Deploying LiquidRefer Implementation ---");
        address implementationAddress;
        {
            string memory contractName = "LiquidRefer_Implementation";
            bytes memory bytecode = abi.encodePacked(
                type(LiquidRefer).creationCode
            );
            implementationAddress = deployContract(contractName, "", bytecode, commitHashSalt);
            verifyContract(implementationAddress, bytecode, commitHashSalt);
        }

        // Step 3: Deploy UUPSProxy
        console.log("\n--- Step 3: Deploying LiquidRefer Proxy ---");
        {
            string memory contractName = "LiquidRefer_Proxy";

            // Prepare initialization data with scroll contract controller as initial owner
            bytes memory initializerData = abi.encodeWithSelector(
                LiquidRefer.initialize.selector,
                scrollContractController
            );

            bytes memory constructorArgs = abi.encode(
                implementationAddress,
                initializerData
            );
            bytes memory bytecode = abi.encodePacked(
                type(UUPSProxy).creationCode,
                constructorArgs
            );
            address proxyAddress = deployContract(contractName, constructorArgs, bytecode, commitHashSalt);
            verifyContract(proxyAddress, bytecode, commitHashSalt);

            // Wrap proxy in implementation interface
            LiquidRefer liquidRefer = LiquidRefer(proxyAddress);

            // Verify ownership is already set to scroll contract controller (no transfer needed)
            console.log("\nVerifying ownership...");
            address currentOwner = liquidRefer.owner();
            require(currentOwner == scrollContractController, "Owner should be scroll contract controller");
            console.log("Owner correctly set to scroll contract controller:", currentOwner);

            // Final verification
            console.log("\nVerifying deployment...");
            verifyDeployment(liquidRefer, implementationAddress);
        }

        vm.stopBroadcast();
    }

    function displayAddresses() internal view {
        console.log("\nUsing Scroll Contract Addresses:");
        console.log("-------------------");
        console.log("Contract Controller:", scrollContractController);
        console.log("\nCreate2Factory:     ", address(factory));
        console.log("Commit Hash Salt:   ", vm.toString(commitHashSalt));
    }

    function computePredictedAddresses() internal {
        // Compute implementation address
        bytes memory implBytecode = abi.encodePacked(
            type(LiquidRefer).creationCode
        );
        address predictedImpl = factory.computeAddress(commitHashSalt, implBytecode);
        console.log("Implementation:     ", predictedImpl);

        // Compute proxy address (with scroll contract controller as initial owner)
        bytes memory initializerData = abi.encodeWithSelector(
            LiquidRefer.initialize.selector,
            scrollContractController
        );
        bytes memory proxyConstructorArgs = abi.encode(
            predictedImpl,
            initializerData
        );
        bytes memory proxyBytecode = abi.encodePacked(
            type(UUPSProxy).creationCode,
            proxyConstructorArgs
        );
        address predictedProxy = factory.computeAddress(commitHashSalt, proxyBytecode);
        console.log("Proxy:              ", predictedProxy);
        console.log("Initial Owner:      ", scrollContractController);
        console.log("-------------------");
        console.log("Note: These addresses are deterministic across all EVM chains");
    }

    function deployContract(
        string memory contractName,
        bytes memory constructorArgs,
        bytes memory bytecode,
        bytes32 salt
    ) internal returns (address) {
        address predictedAddress = factory.computeAddress(salt, bytecode);
        console.log("\nDeploying", contractName);
        console.log("Predicted address:", predictedAddress);

        address deployedAddress = factory.deploy(bytecode, salt);
        require(deployedAddress == predictedAddress, "Deployment address mismatch");

        console.log("Deployed at:", deployedAddress);

        // Save deployment log
        saveDeploymentLog(contractName, deployedAddress, constructorArgs, salt);

        return deployedAddress;
    }

    function verifyContract(address addr, bytes memory bytecode, bytes32 salt) internal view returns (bool) {
        bool verified = factory.verify(addr, salt, bytecode);
        require(verified, "Contract verification failed");
        console.log("Verification: PASS");
        return verified;
    }

    function saveDeploymentLog(
        string memory contractName,
        address deployedAddress,
        bytes memory constructorArgs,
        bytes32 salt
    ) internal {
        string memory deployLog = string.concat(
            "{\n",
            '  "contractName": "', contractName, '",\n',
            '  "network": "scroll",\n',
            '  "deploymentParameters": {\n',
            '    "factory": "', vm.toString(address(factory)), '",\n',
            '    "salt": "', vm.toString(salt), '",\n',
            '    "constructorArgsEncoded": "', vm.toString(constructorArgs), '"\n',
            '  },\n',
            '  "deployedAddress": "', vm.toString(deployedAddress), '"\n',
            "}"
        );

        string memory root = vm.projectRoot();
        string memory logFileDir = string.concat(root, "/deployment/", contractName);
        vm.createDir(logFileDir, true);

        string memory logFileName = string.concat(
            logFileDir,
            "/scroll-",
            getTimestampString(),
            ".json"
        );
        vm.writeFile(logFileName, deployLog);

        console.log("Deployment log saved to:", logFileName);
    }

    function saveCreate2FactoryLog(address deployedAddress) internal {
        string memory deployLog = string.concat(
            "{\n",
            '  "contractName": "Create2Factory",\n',
            '  "network": "scroll",\n',
            '  "deployedAddress": "', vm.toString(deployedAddress), '"\n',
            "}"
        );

        string memory root = vm.projectRoot();
        string memory logFileDir = string.concat(root, "/deployment/Create2Factory");
        vm.createDir(logFileDir, true);

        string memory logFileName = string.concat(
            logFileDir,
            "/scroll-",
            getTimestampString(),
            ".json"
        );
        vm.writeFile(logFileName, deployLog);

        console.log("Deployment log saved to:", logFileName);
    }

    function verifyDeployment(LiquidRefer liquidRefer, address implementationAddress) internal view {
        console.log("-------------------");

        // Verify initialization state
        require(!liquidRefer.paused(), "Contract should not be paused");
        console.log("[PASS] Contract is not paused");

        require(liquidRefer.owner() == scrollContractController, "Owner should be scroll contract controller");
        console.log("[PASS] Owner is scroll contract controller");

        // Verify implementation
        address actualImpl = liquidRefer.getImplementation();
        require(actualImpl == implementationAddress, "Implementation address mismatch");
        console.log("[PASS] Implementation address verified:", actualImpl);

        console.log("\n[PASS] All verifications passed!");
    }

    function getTimestampString() internal view returns (string memory) {
        uint256 ts = block.timestamp;
        string memory year = vm.toString((ts / 31536000) + 1970);
        string memory month = pad(vm.toString(((ts % 31536000) / 2592000) + 1));
        string memory day = pad(vm.toString(((ts % 2592000) / 86400) + 1));
        string memory hour = pad(vm.toString((ts % 86400) / 3600));
        string memory minute = pad(vm.toString((ts % 3600) / 60));
        string memory second = pad(vm.toString(ts % 60));
        return string.concat(year, "-", month, "-", day, "-", hour, "-", minute, "-", second);
    }

    function pad(string memory n) internal pure returns (string memory) {
        return bytes(n).length == 1 ? string.concat("0", n) : n;
    }
}
