// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/helpers/WeETHWithdrawAdapter.sol";
import "../src/UUPSProxy.sol";

/**
 * @title Deploy WeETH Withdraw Adapter
 * @notice Deploys the WeETHWithdrawAdapter implementation and UUPS proxy
 * 
 * This script will:
 * 1. Deploy the WeETHWithdrawAdapter implementation
 * 2. Deploy the UUPSProxy with initialization
 * 3. Transfer ownership to the timelock
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
    
    // Mainnet contract addresses (hardcoded like in DeployV3Prelude.s.sol)
    address constant weETHAddress = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address constant eETHAddress = 0x35fA164735182de50811E8e2E824cFb9B6118ac2;
    address constant liquidityPoolAddress = 0x308861A430be4cce5502d0A12724771Fc6DaF216;
    address constant withdrawRequestNFTAddress = 0x7d5706f6ef3F89B3951E23e557CDFBC3239D4E2c;
    address constant roleRegistryAddress = 0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9;
    address constant timelockAddress = 0x9f26d4C958fD811A1F59B01B86Be7dFFc9d20761;

    function run() external {
        console.log("\n========================================");
        console.log("WeETH Withdraw Adapter Deployment");
        console.log("========================================\n");

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
    
    function displayAddresses() internal pure {
        console.log("\nUsing Mainnet Contract Addresses:");
        console.log("-------------------");
        console.log("WeETH:              ", weETHAddress);
        console.log("EETH:               ", eETHAddress);
        console.log("LiquidityPool:      ", liquidityPoolAddress);
        console.log("WithdrawRequestNFT: ", withdrawRequestNFTAddress);
        console.log("RoleRegistry:       ", roleRegistryAddress);
        console.log("EtherFiTimelock:    ", timelockAddress);
    }
    
    function displayDeploymentSummary(address implementation, address proxy) internal pure {
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

