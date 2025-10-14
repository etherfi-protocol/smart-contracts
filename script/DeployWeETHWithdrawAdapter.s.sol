// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/helpers/WeETHWithdrawAdapter.sol";
import "../src/UUPSProxy.sol";
import "../src/helpers/AddressProvider.sol";

/**
 * @title Deploy WeETH Withdraw Adapter
 * @notice Deploys the WeETHWithdrawAdapter implementation and UUPS proxy
 * 
 * This script will:
 * 1. Get required contract addresses from AddressProvider
 * 2. Deploy the WeETHWithdrawAdapter implementation
 * 3. Deploy the UUPSProxy with initialization
 * 4. Transfer ownership to the timelock
 * 
 * Usage:
 * 
 * For mainnet deployment:
 * source .env && forge script ./script/DeployWeETHWithdrawAdapter.s.sol:DeployWeETHWithdrawAdapter \
 *   --rpc-url $MAINNET_RPC_URL \
 *   --broadcast \
 *   --verify \
 *   --etherscan-api-key $ETHERSCAN_API_KEY \
 *   --slow \
 *   -vvvv
 * 
 * For testnet deployment:
 * forge script ./script/DeployWeETHWithdrawAdapter.s.sol:DeployWeETHWithdrawAdapter \
 *   --rpc-url $TESTNET_RPC_URL \
 *   --broadcast \
 *   -vvvv
 */
contract DeployWeETHWithdrawAdapter is Script {
    
    AddressProvider public addressProvider;
    
    // Contract addresses
    address weETHAddress;
    address eETHAddress;
    address liquidityPoolAddress;
    address withdrawRequestNFTAddress;
    address roleRegistryAddress;
    address timelockAddress;

    function run() external {
        console.log("\n========================================");
        console.log("WeETH Withdraw Adapter Deployment");
        console.log("========================================\n");

        // Get AddressProvider from environment
        address addressProviderAddress = vm.envAddress("CONTRACT_REGISTRY");
        addressProvider = AddressProvider(addressProviderAddress);
        
        console.log("Using AddressProvider at:", addressProviderAddress);
        
        // Fetch required contract addresses
        fetchContractAddresses();
        
        // Display addresses for verification
        displayAddresses();
        
        // Start deployment
        vm.startBroadcast();
        
        // Deploy implementation
        console.log("\nDeploying WeETHWithdrawAdapter implementation...");
        WeETHWithdrawAdapter implementation = new WeETHWithdrawAdapter(
            weETHAddress,
            eETHAddress,
            liquidityPoolAddress,
            withdrawRequestNFTAddress,
            roleRegistryAddress
        );
        console.log("Implementation deployed at:", address(implementation));
        
        // Prepare initialization data
        bytes memory initializerData = abi.encodeWithSelector(
            WeETHWithdrawAdapter.initialize.selector
        );
        
        // Deploy UUPS proxy
        console.log("\nDeploying UUPSProxy...");
        UUPSProxy proxy = new UUPSProxy(
            address(implementation),
            initializerData
        );
        console.log("Proxy deployed at:", address(proxy));
        
        // Wrap proxy in implementation interface
        WeETHWithdrawAdapter adapter = WeETHWithdrawAdapter(address(proxy));
        
        // Transfer ownership to timelock
        console.log("\nTransferring ownership to timelock...");
        adapter.transferOwnership(timelockAddress);
        console.log("Ownership transferred to:", timelockAddress);
        
        vm.stopBroadcast();
        
        // Display deployment summary
        displayDeploymentSummary(address(implementation), address(proxy));
        
        // Verify deployment
        verifyDeployment(adapter);
    }
    
    function fetchContractAddresses() internal {
        console.log("\nFetching contract addresses from AddressProvider...");
        
        weETHAddress = addressProvider.getContractAddress("WeETH");
        eETHAddress = addressProvider.getContractAddress("EETH");
        liquidityPoolAddress = addressProvider.getContractAddress("LiquidityPool");
        withdrawRequestNFTAddress = addressProvider.getContractAddress("WithdrawRequestNFT");
        roleRegistryAddress = addressProvider.getContractAddress("RoleRegistry");
        timelockAddress = addressProvider.getContractAddress("EtherFiTimelock");
        
        // Validate addresses
        require(weETHAddress != address(0), "WeETH address not found");
        require(eETHAddress != address(0), "EETH address not found");
        require(liquidityPoolAddress != address(0), "LiquidityPool address not found");
        require(withdrawRequestNFTAddress != address(0), "WithdrawRequestNFT address not found");
        require(roleRegistryAddress != address(0), "RoleRegistry address not found");
        require(timelockAddress != address(0), "EtherFiTimelock address not found");
    }
    
    function displayAddresses() internal view {
        console.log("\nContract Addresses:");
        console.log("-------------------");
        console.log("WeETH:              ", weETHAddress);
        console.log("EETH:               ", eETHAddress);
        console.log("LiquidityPool:      ", liquidityPoolAddress);
        console.log("WithdrawRequestNFT: ", withdrawRequestNFTAddress);
        console.log("RoleRegistry:       ", roleRegistryAddress);
        console.log("EtherFiTimelock:    ", timelockAddress);
    }
    
    function displayDeploymentSummary(address implementation, address proxy) internal view {
        console.log("\n========================================");
        console.log("Deployment Summary");
        console.log("========================================");
        console.log("Implementation:     ", implementation);
        console.log("Proxy:              ", proxy);
        console.log("Owner:              ", timelockAddress);
        console.log("========================================\n");
    }
    
    function verifyDeployment(WeETHWithdrawAdapter adapter) internal view {
        console.log("Verifying deployment...");
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
        
        console.log("\n[PASS] All verifications passed!");
    }
}

