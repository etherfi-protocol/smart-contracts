// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "forge-std/StdJson.sol";
import  "src/helpers/LiquidRefer.sol";
import "../../src/UUPSProxy.sol";
import "../deploys/Deployed.s.sol";

interface ICreate2Factory {
    function deploy(bytes memory code, bytes32 salt) external payable returns (address);
    function verify(address addr, bytes32 salt, bytes memory code) external view returns (bool);
    function computeAddress(bytes32 salt, bytes memory code) external view returns (address);
}

/**
 * @title Deploy LiquidRefer on Mainnet 
 * @notice Deploys the LiquidRefer implementation and UUPS proxy using Create2Factory
 * 
 * This script will:
 * 1. Compute and display predicted deployment addresses (deterministic across all chains)
 * 2. Deploy the LiquidRefer implementation using Create2
 * 3. Deploy the UUPSProxy with initialization using Create2
 * 4. Transfer ownership to the ETHERFI_OPERATING_ADMIN
 * 5. Verify the deployment
 * 6. Save deployment logs to ./deployment/{contractName}/{timestamp}.json
 * 
 * Key Features:
 * - Uses Create2Factory (0x356d1B83970CeF2018F2c9337cDdb67dff5AEF99) for deterministic addresses
 * - Commit hash salt: 639b4d9717c799be1f06750668ea0067e7ecec8f
 * 
 * Usage:
 * 
 * 1. Dry run (compute addresses without deploying):
 *    forge script ./script/liquid/DeployLiquidReferMainnet.s.sol:DeployLiquidReferMainnet
 *    Note: Will fail at deployment step but shows predicted addresses
 * 
 * 2. Mainnet deployment:
 *    source .env && forge script ./script/liquid/DeployLiquidReferMainnet.s.sol:DeployLiquidReferMainnet \
 *      --rpc-url $MAINNET_RPC_URL \
 *      --broadcast \
 *      --verify \
 *      --etherscan-api-key $ETHERSCAN_API_KEY \
 *      --slow \
 *      -vvvv
 * 
 * 3. Other chains (Base, Arbitrum, etc.):
 *    forge script ./script/liquid/DeployLiquidReferMainnet.s.sol:DeployLiquidReferMainnet \
 *      --rpc-url $CHAIN_RPC_URL \
 *      --broadcast \
 *      --verify \
 *      -vvvv
 * 
 * Important: The contract addresses MUST match across all chains for the deployment to work.
 *            Update the constants if deploying to chains with different addresses.
 */
contract DeployLiquidReferMainnet is Script, Deployed {
    using stdJson for string;
    
    // Create2Factory address (same as in DeployV3Prelude.s.sol)
    ICreate2Factory constant factory = ICreate2Factory(0x356d1B83970CeF2018F2c9337cDdb67dff5AEF99);

    // Mainnet contract controller (owner)
    address constant deploymentLegder = 0x8D5AAc5d3d5cda4c404fA7ee31B0822B648Bb150; // Deployment Legder

    address internal constant LIQUID_ETH_TELLER = 0x9AA79C84b79816ab920bBcE20f8f74557B514734;
    address internal constant LIQUID_USD_TELLER = 0x4DE413a26fC24c3FC27Cc983be70aA9c5C299387;
    address internal constant LIQUID_BTC_TELLER = 0x8Ea0B382D054dbEBeB1d0aE47ee4AC433C730353;

    // Audited commit hash salt
    bytes32 commitHashSalt = bytes32((hex"639b4d9717c799be1f06750668ea0067e7ecec8f"));

    function run() external {
        console.log("\n========================================");
        console.log("LiquidRefer Mainnet Deployment");
        console.log("Using Create2Factory for deterministic addresses");
        console.log("========================================\n");

        // Display addresses for verification
        displayAddresses();
        
        // Compute and display predicted addresses
        console.log("\n========================================");
        console.log("Predicted Deployment Addresses");
        console.log("========================================");
        computePredictedAddresses();
        
        // Start deployment
        vm.startBroadcast(deploymentLegder);
        
        // Deploy LiquidRefer implementation
        address implementationAddress;
        {
            string memory contractName = "LiquidRefer_Implementation";
            bytes memory bytecode = abi.encodePacked(
                type(LiquidRefer).creationCode
            );
            implementationAddress = deployContract(contractName, "", bytecode, commitHashSalt);
            verifyContract(implementationAddress, bytecode, commitHashSalt);
        }

        // Deploy UUPSProxy
        {
            string memory contractName = "LiquidRefer_Proxy";

            // Prepare initialization data with deploymentLegder as initial owner
            bytes memory initializerData = abi.encodeWithSelector(
                LiquidRefer.initialize.selector,
                deploymentLegder // pass the owner
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

            console.log("\nVerifying ownership...");
            address currentOwner = liquidRefer.owner();
            require(currentOwner == deploymentLegder, "Owner should be deploymentLegder");
            console.log("Owner correctly set to deploymentLegder:", currentOwner);

            // Final verification
            console.log("\nVerifying deployment...");
    
            //Next we can toggle our addresses
            liquidRefer.toggleWhiteList(LIQUID_ETH_TELLER, true);
            liquidRefer.toggleWhiteList(LIQUID_USD_TELLER, true);
            liquidRefer.toggleWhiteList(LIQUID_BTC_TELLER, true);
            liquidRefer.transferOwnership(ETHERFI_OPERATING_ADMIN);
            console.log("Owner transferred to ETHERFI_OPERATING_ADMIN:", ETHERFI_OPERATING_ADMIN);

            verifyDeployment(liquidRefer, implementationAddress);
        }

        vm.stopBroadcast();
    }
    
    function displayAddresses() internal view {
        console.log("\nUsing Deployed Contract Addresses:");
        console.log("-------------------");
        console.log("Contract Controller:", deploymentLegder);
        console.log("Liquid ETH Teller:  ", LIQUID_ETH_TELLER);
        console.log("Liquid USD Teller:  ", LIQUID_USD_TELLER);
        console.log("Liquid BTC Teller:  ", LIQUID_BTC_TELLER);
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

        // Compute proxy address (with mainnet contract controller as initial owner)
        bytes memory initializerData = abi.encodeWithSelector(
            LiquidRefer.initialize.selector,
            deploymentLegder
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
        console.log("Initial Owner:      ", deploymentLegder);
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
            "/",
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

        require(liquidRefer.owner() == ETHERFI_OPERATING_ADMIN, "Owner should be ETHERFI_OPERATING_ADMIN");
        console.log("[PASS] Owner is ETHERFI_OPERATING_ADMIN");

        // Verify implementation
        address actualImpl = liquidRefer.getImplementation();
        require(actualImpl == implementationAddress, "Implementation address mismatch");
        console.log("[PASS] Implementation address verified:", actualImpl);

        require(liquidRefer.tellerWhiteList(LIQUID_ETH_TELLER), "LIQUID_ETH_TELLER should be whitelisted");
        console.log("[PASS] LIQUID_ETH_TELLER is whitelisted");
        require(liquidRefer.tellerWhiteList(LIQUID_USD_TELLER), "LIQUID_USD_TELLER should be whitelisted");
        console.log("[PASS] LIQUID_USD_TELLER is whitelisted");
        require(liquidRefer.tellerWhiteList(LIQUID_BTC_TELLER), "LIQUID_BTC_TELLER should be whitelisted");
        console.log("[PASS] LIQUID_BTC_TELLER is whitelisted");

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

