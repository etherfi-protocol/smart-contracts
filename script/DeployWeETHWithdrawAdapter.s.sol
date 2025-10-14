// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "forge-std/StdJson.sol";
import "../src/helpers/WeETHWithdrawAdapter.sol";
import "../src/UUPSProxy.sol";

interface ICreate2Factory {
    function deploy(bytes memory code, bytes32 salt) external payable returns (address);
    function verify(address addr, bytes32 salt, bytes memory code) external view returns (bool);
    function computeAddress(bytes32 salt, bytes memory code) external view returns (address);
}

/**
 * @title Deploy WeETH Withdraw Adapter
 * @notice Deploys the WeETHWithdrawAdapter implementation and UUPS proxy using Create2Factory
 * 
 * This script will:
 * 1. Compute and display predicted deployment addresses (deterministic across all chains)
 * 2. Deploy the WeETHWithdrawAdapter implementation using Create2
 * 3. Deploy the UUPSProxy with initialization using Create2
 * 4. Transfer ownership to the EtherFi Timelock
 * 5. Verify the deployment
 * 6. Save deployment logs to ./deployment/{contractName}/{timestamp}.json
 * 
 * Key Features:
 * - Uses Create2Factory (0x356d1B83970CeF2018F2c9337cDdb67dff5AEF99) for deterministic addresses
 * - Same addresses across all EVM chains (Mainnet, Base, Arbitrum, etc.)
 * - Commit hash salt: 5bb56076faac983d51c2145b4de117335f6e4fa5
 * 
 * Usage:
 * 
 * 1. Dry run (compute addresses without deploying):
 *    forge script ./script/DeployWeETHWithdrawAdapter.s.sol:DeployWeETHWithdrawAdapter
 *    Note: Will fail at deployment step but shows predicted addresses
 * 
 * 2. Mainnet deployment:
 *    source .env && forge script ./script/DeployWeETHWithdrawAdapter.s.sol:DeployWeETHWithdrawAdapter \
 *      --rpc-url $MAINNET_RPC_URL \
 *      --broadcast \
 *      --verify \
 *      --etherscan-api-key $ETHERSCAN_API_KEY \
 *      --slow \
 *      -vvvv
 * 
 * 3. Other chains (Base, Arbitrum, etc.):
 *    forge script ./script/DeployWeETHWithdrawAdapter.s.sol:DeployWeETHWithdrawAdapter \
 *      --rpc-url $CHAIN_RPC_URL \
 *      --broadcast \
 *      --verify \
 *      -vvvv
 * 
 * Important: The contract addresses MUST match across all chains for the deployment to work.
 *            Update the constants if deploying to chains with different addresses.
 */
contract DeployWeETHWithdrawAdapter is Script {
    using stdJson for string;
    
    // Create2Factory address (same as in DeployV3Prelude.s.sol)
    ICreate2Factory constant factory = ICreate2Factory(0x356d1B83970CeF2018F2c9337cDdb67dff5AEF99);
    
    // Mainnet contract addresses
    address constant weETHAddress = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address constant eETHAddress = 0x35fA164735182de50811E8e2E824cFb9B6118ac2;
    address constant liquidityPoolAddress = 0x308861A430be4cce5502d0A12724771Fc6DaF216;
    address constant withdrawRequestNFTAddress = 0x7d5706f6ef3F89B3951E23e557CDFBC3239D4E2c;
    address constant roleRegistryAddress = 0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9;
    address constant timelockAddress = 0x9f26d4C958fD811A1F59B01B86Be7dFFc9d20761;
    
    // Commit hash salt
    bytes32 constant commitHashSalt = bytes32(bytes20(hex"5bb56076faac983d51c2145b4de117335f6e4fa5"));

    function run() external {
        console.log("\n========================================");
        console.log("WeETH Withdraw Adapter Deployment");
        console.log("Using Create2Factory for deterministic addresses");
        console.log("========================================\n");

        // Load deployer private key
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer address:", deployer);

        // Display addresses for verification
        displayAddresses();
        
        // Compute and display predicted addresses
        console.log("\n========================================");
        console.log("Predicted Deployment Addresses");
        console.log("========================================");
        computePredictedAddresses();
        
        // Start deployment
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy WeETHWithdrawAdapter implementation
        {
            string memory contractName = "WeETHWithdrawAdapter";
            bytes memory constructorArgs = abi.encode(
                weETHAddress,
                eETHAddress,
                liquidityPoolAddress,
                withdrawRequestNFTAddress,
                roleRegistryAddress
            );
            bytes memory bytecode = abi.encodePacked(
                type(WeETHWithdrawAdapter).creationCode,
                constructorArgs
            );
            address deployedAddress = deployContract(contractName, constructorArgs, bytecode, commitHashSalt);
            verifyContract(deployedAddress, bytecode, commitHashSalt);
        }
        
        // Deploy UUPSProxy
        {
            string memory contractName = "WeETHWithdrawAdapter_Proxy";
            
            // Get implementation address (we need to recalculate it)
            bytes memory implConstructorArgs = abi.encode(
                weETHAddress,
                eETHAddress,
                liquidityPoolAddress,
                withdrawRequestNFTAddress,
                roleRegistryAddress
            );
            bytes memory implBytecode = abi.encodePacked(
                type(WeETHWithdrawAdapter).creationCode,
                implConstructorArgs
            );
            address implementationAddress = factory.computeAddress(commitHashSalt, implBytecode);
            
            // Prepare initialization data with timelock as initial owner
            bytes memory initializerData = abi.encodeWithSelector(
                WeETHWithdrawAdapter.initialize.selector,
                timelockAddress
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
            WeETHWithdrawAdapter adapter = WeETHWithdrawAdapter(proxyAddress);
            
            // Verify ownership is already set to timelock (no transfer needed)
            console.log("\nVerifying ownership...");
            address currentOwner = adapter.owner();
            require(currentOwner == timelockAddress, "Owner should be timelock");
            console.log("Owner correctly set to timelock:", currentOwner);
            
            // Final verification
            console.log("\nVerifying deployment...");
            verifyDeployment(adapter, implementationAddress);
        }
        
        vm.stopBroadcast();
    }
    
    function displayAddresses() internal pure {
        console.log("\nUsing Mainnet Contract Addresses:");
        console.log("-------------------");
        console.log("WeETH:              ", weETHAddress);
        console.log("EETH:               ", eETHAddress);
        console.log("LiquidityPool:      ", liquidityPoolAddress);
        console.log("WithdrawRequestNFT: ", withdrawRequestNFTAddress);
        console.log("RoleRegistry:       ", roleRegistryAddress);
        console.log("EtherFiTimelock:    ", timelockAddress);
        console.log("\nCreate2Factory:     ", address(factory));
        console.log("Commit Hash Salt:   ", vm.toString(commitHashSalt));
    }
    
    function computePredictedAddresses() internal {
        // Compute implementation address
        bytes memory implConstructorArgs = abi.encode(
            weETHAddress,
            eETHAddress,
            liquidityPoolAddress,
            withdrawRequestNFTAddress,
            roleRegistryAddress
        );
        bytes memory implBytecode = abi.encodePacked(
            type(WeETHWithdrawAdapter).creationCode,
            implConstructorArgs
        );
        address predictedImpl = factory.computeAddress(commitHashSalt, implBytecode);
        console.log("Implementation:     ", predictedImpl);
        
        // Compute proxy address (with timelock as initial owner)
        bytes memory initializerData = abi.encodeWithSelector(
            WeETHWithdrawAdapter.initialize.selector,
            timelockAddress
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
        console.log("Initial Owner:      ", timelockAddress);
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
    
    function verifyDeployment(WeETHWithdrawAdapter adapter, address implementationAddress) internal view {
        console.log("-------------------");
        
        // Verify immutable variables
        require(address(adapter.weETH()) == weETHAddress, "WeETH address mismatch");
        console.log("[PASS] WeETH address verified");
        
        require(address(adapter.eETH()) == eETHAddress, "EETH address mismatch");
        console.log("[PASS] EETH address verified");
        
        require(address(adapter.liquidityPool()) == liquidityPoolAddress, "LiquidityPool address mismatch");
        console.log("[PASS] LiquidityPool address verified");
        
        require(address(adapter.withdrawRequestNFT()) == withdrawRequestNFTAddress, "WithdrawRequestNFT address mismatch");
        console.log("[PASS] WithdrawRequestNFT address verified");
        
        require(address(adapter.roleRegistry()) == roleRegistryAddress, "RoleRegistry address mismatch");
        console.log("[PASS] RoleRegistry address verified");
        
        // Verify initialization state
        require(!adapter.paused(), "Contract should not be paused");
        console.log("[PASS] Contract is not paused");
        
        require(adapter.owner() == timelockAddress, "Owner should be timelock");
        console.log("[PASS] Owner is timelock");
        
        // Verify implementation
        address actualImpl = adapter.getImplementation();
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

