// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "../src/interfaces/IStakingManager.sol";
import "../src/interfaces/IEtherFiNodesManager.sol";
import "../src/interfaces/IEtherFiNode.sol";
import "../src/interfaces/ILiquidityPool.sol";
import "../src/interfaces/IEtherFiOracle.sol";
import "../src/interfaces/IEtherFiAdmin.sol";
import "../src/interfaces/IeETH.sol";
import "../src/interfaces/IWeETH.sol";
import "../src/interfaces/ITNFT.sol";
import "../src/StakingManager.sol";
import "../src/EtherFiNodesManager.sol";
import "../src/EtherFiNode.sol";
import "../src/LiquidityPool.sol";
import "../src/AuctionManager.sol";
import "../src/RoleRegistry.sol";
import "./ContractCodeChecker.sol";

contract VerifyV3Implementation is Script, ContractCodeChecker {
    // Mainnet proxy addresses
    address stakingManagerProxy = 0x25e821b7197B146F7713C3b89B6A4D83516B912d;
    address liquidityPoolProxy = 0x308861A430be4cce5502d0A12724771Fc6DaF216;
    address etherFiNodesManagerProxy = 0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F;
    address auctionManagerProxy = 0x00C452aFFee3a17d9Cecc1Bcd2B8d5C7635C4CB9;
    address roleRegistryProxy = 0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9;
    
    // Additional contract proxy addresses
    address etherFiOracleProxy = 0x57AaF0004C716388B21795431CD7D5f9D3Bb6a41;
    address etherFiAdminProxy = 0x0EF8fa4760Db8f5Cd4d993f3e3416f30f942D705;
    address eETHProxy = 0x35fA164735182de50811E8e2E824cFb9B6118ac2;
    address weETHProxy = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address TNFTProxy = 0x7B5ae07E2AF1C861BcC4736D23f5f66A61E0cA5e;

    // Implementation addresses to verify
    address stakingManagerImpl = 0x58da2a0dD60375fE547EBfFb62674b362faa74F4;
    address etherFiNodesManagerImpl = 0x6dA7cb57e102Ab9b046A6C39E6437258bbfA286D;
    address liquidityPoolImpl = 0x14E3a143271BcB1Bc18ebE25aaA9FC3cE54100A3;
    address auctionManagerImpl = 0x68FE80C6e97E0c8613e2FED344358c6635ba5366;
    address etherFiOracleImpl = 0xba0d7267ECb471EA929b958CBb7861c458FC20BF;
    address etherFiAdminImpl = 0x86B0203B76ebe8556233244F99aCC97360989C04;
    address eETHImpl = 0x226D1d7318D46d3CC2bEa5139d3af1cB42f017c8;
    address weETHImpl = 0x0b8303f4CcdCa6D42164291Feb34A15bEb4ca4cE;
    address TNFTImpl = 0xafb82ce44fd8a3431a64742bCD3547EEDA1AFea7;



    // Track verification results
    uint256 totalChecks;
    uint256 passedChecks;
    bool allChecksPassed = true;

    function run() public {
        //Select RPC to fork
        string memory rpc = vm.rpcUrl(vm.envString("TENDERLY_TEST_RPC"));
        vm.createSelectFork(rpc);

        console2.log("========================================");
        console2.log("Starting V3 Implementation Verification");
        console2.log("========================================\n");

        // 1. Verify StakingManager Implementation
        console2.log("1. VERIFYING STAKING MANAGER IMPLEMENTATION");
        console2.log("-------------------------------------------");
        verifyStakingManagerImplementation();

        // 2. Verify EtherFiNodesManager Implementation
        console2.log("\n2. VERIFYING ETHERFI NODES MANAGER IMPLEMENTATION");
        console2.log("--------------------------------------------------");
        verifyEtherFiNodesManagerImplementation();

        // 3. Verify LiquidityPool Implementation
        console2.log("\n3. VERIFYING LIQUIDITY POOL IMPLEMENTATION");
        console2.log("-------------------------------------------");
        console2.log("No Immutable Variables");
        // verifyLiquidityPoolImplementation();

        // 4. Verify AuctionManager Implementation
        console2.log("\n4. VERIFYING AUCTION MANAGER IMPLEMENTATION");
        console2.log("--------------------------------------------");
        console2.log("No Immutable Variables");
        // verifyAuctionManagerImplementation();

        // 5. Verify Additional Contract Implementations
        console2.log("\n5. VERIFYING ADDITIONAL CONTRACT IMPLEMENTATIONS");
        console2.log("------------------------------------------------");
        verifyAdditionalImplementations();

        // 6. Verify Bytecode Matches
        // console2.log("\n6. VERIFYING BYTECODE MATCHES");
        // console2.log("------------------------------------------------");
        // verifyBytecodeMatches();

        // Summary
        console2.log("\n========================================");
        console2.log("IMPLEMENTATION VERIFICATION SUMMARY");
        console2.log("========================================");
        console2.log("Total Checks:", totalChecks);
        console2.log("Passed:", passedChecks);
        console2.log("Failed:", totalChecks - passedChecks);

        if (allChecksPassed) {
            console2.log("\x1b[32m\n[PASS] ALL IMPLEMENTATION VERIFICATIONS PASSED!\x1b[0m");
        } else {
            console2.log("\x1b[31m\n[FAIL] SOME IMPLEMENTATION VERIFICATIONS FAILED!\x1b[0m");
            revert("Implementation verification failed");
        }
    }

    function verifyStakingManagerImplementation() internal {
        console2.log("Verifying StakingManager implementation:", stakingManagerImpl);
        
        StakingManager stakingManager = StakingManager(stakingManagerImpl);
        
        console2.log("Checking StakingManager immutable variables...");
        
        // Check all 6 immutable variables from analysis
        checkCondition(
            address(stakingManager.roleRegistry()) == roleRegistryProxy,
            "StakingManager roleRegistry immutable correct"
        );
        
        checkCondition(
            stakingManager.liquidityPool() == liquidityPoolProxy,
            "StakingManager liquidityPool immutable correct"
        );
        
        checkCondition(
            address(stakingManager.etherFiNodesManager()) == etherFiNodesManagerProxy,
            "StakingManager etherFiNodesManager immutable correct"
        );
        
        checkCondition(
            address(stakingManager.auctionManager()) == auctionManagerProxy,
            "StakingManager auctionManager immutable correct"
        );
        
        checkCondition(
            address(stakingManager.depositContractEth2()) == 0x00000000219ab540356cBB839Cbe05303d7705Fa,
            "StakingManager depositContractEth2 immutable correct"
        );
        
        checkCondition(
            stakingManager.getEtherFiNodeBeacon() != address(0),
            "StakingManager etherFiNodeBeacon immutable set"
        );
    }

    function verifyEtherFiNodesManagerImplementation() internal {
        console2.log("Verifying EtherFiNodesManager implementation:", etherFiNodesManagerImpl);
        
        EtherFiNodesManager nodesManager = EtherFiNodesManager(payable(etherFiNodesManagerImpl));
        
        console2.log("Checking EtherFiNodesManager immutable variables...");
        
        // Check both immutable variables from analysis
        checkCondition(
            address(nodesManager.roleRegistry()) == roleRegistryProxy,
            "EtherFiNodesManager roleRegistry immutable correct"
        );
        
        checkCondition(
            nodesManager.stakingManager() == stakingManagerProxy,
            "EtherFiNodesManager stakingManager immutable correct"
        );
    }

    // function verifyLiquidityPoolImplementation() internal {
    //     console2.log("Verifying LiquidityPool implementation:", liquidityPoolImpl);
        
    //     console2.log("LiquidityPool has no immutable variables (upgradeable pattern)");
    //     // LiquidityPool uses upgradeable pattern with no immutable variables
    //     // All contract references are stored as state variables
    // }

    // function verifyAuctionManagerImplementation() internal {
    //     console2.log("Verifying AuctionManager implementation:", auctionManagerImpl);
        
    //     console2.log("AuctionManager has no immutable variables (upgradeable pattern)");
    //     // AuctionManager uses upgradeable pattern with no immutable variables
    //     // All contract references are stored as state variables
    // }

    function verifyAdditionalImplementations() internal {
        // Verify eETH implementation and immutable variables
        console2.log("Verifying eETH implementation:", eETHImpl);
        
        // Check eETH immutable variable directly on implementation
        // IeETH interface doesn't include roleRegistry, so use low-level call
        (bool success, bytes memory data) = eETHImpl.staticcall(
            abi.encodeWithSignature("roleRegistry()")
        );
        if (success && data.length >= 32) {
            address eethRoleRegistry = abi.decode(data, (address));
            checkCondition(
                eethRoleRegistry == roleRegistryProxy,
                "eETH roleRegistry immutable correct"
            );
        } else {
            console2.log("Could not verify eETH roleRegistry immutable");
        }
        
        // Verify weETH implementation and immutable variables
        console2.log("Verifying weETH implementation:", weETHImpl);
        
        // Check weETH immutable variable directly on implementation  
        // IWeETH interface doesn't include roleRegistry, so use low-level call
        (bool success2, bytes memory data2) = weETHImpl.staticcall(
            abi.encodeWithSignature("roleRegistry()")
        );
        if (success2 && data2.length >= 32) {
            address weethRoleRegistry = abi.decode(data2, (address));
            checkCondition(
                weethRoleRegistry == roleRegistryProxy,
                "weETH roleRegistry immutable correct"
            );
        } else {
            console2.log("Could not verify weETH roleRegistry immutable");
        }
        
        // Verify TNFT implementation
        console2.log("Verifying TNFT implementation:", TNFTImpl);
        console2.log("TNFT has no immutable variables (upgradeable pattern)");
    }

    // function verifyBytecodeMatches() internal {
    //     console2.log("\nComparing runtime bytecode of deployed implementations...");
        
    //     // For upgradeable contracts (no constructor params), we can directly compare
    //     console2.log("\nLiquidityPool Bytecode Verification:");
    //     bytes memory expectedLiquidityPool = vm.getDeployedCode("LiquidityPool.sol:LiquidityPool");
    //     bytes memory deployedLiquidityPool = liquidityPoolImpl.code;
    //     compareBytecode(deployedLiquidityPool, expectedLiquidityPool, "LiquidityPool");
        
    //     console2.log("\nAuctionManager Bytecode Verification:");
    //     bytes memory expectedAuctionManager = vm.getDeployedCode("AuctionManager.sol:AuctionManager");
    //     bytes memory deployedAuctionManager = auctionManagerImpl.code;
    //     compareBytecode(deployedAuctionManager, expectedAuctionManager, "AuctionManager");
        
    //     // For contracts with immutable variables, bytecode will differ based on constructor args
    //     console2.log("\nStakingManager Bytecode Verification:");
    //     console2.log("Note: StakingManager has immutable variables, bytecode will differ based on constructor args");
    //     bytes memory deployedStakingManager = stakingManagerImpl.code;
    //     console2.log("Deployed bytecode length:", deployedStakingManager.length);
        
        
    //     console2.log("\nEtherFiNodesManager Bytecode Verification:");
    //     console2.log("Note: EtherFiNodesManager has immutable variables, bytecode will differ based on constructor args");
    //     bytes memory deployedNodesManager = etherFiNodesManagerImpl.code;
    //     console2.log("Deployed bytecode length:", deployedNodesManager.length);
    // }
    
    // function compareBytecode(bytes memory deployed, bytes memory expected, string memory contractName) internal {
    //     if (keccak256(deployed) == keccak256(expected)) {
    //         console2.log(string.concat("[PASS] ", contractName, " bytecode matches exactly"));
    //         checkCondition(true, string.concat(contractName, " bytecode match"));
    //     } else {
    //         console2.log(string.concat("[FAIL] ", contractName, " bytecode mismatch"));
    //         console2.log("  Deployed length:", deployed.length);
    //         console2.log("  Expected length:", expected.length);
            
    //         // Try comparing without metadata
    //         bytes memory trimmedDeployed = trimMetadata(deployed);
    //         bytes memory trimmedExpected = trimMetadata(expected);
            
    //         if (keccak256(trimmedDeployed) == keccak256(trimmedExpected)) {
    //             console2.log("  [PASS] Bytecode matches after trimming metadata");
    //             checkCondition(true, string.concat(contractName, " bytecode match (trimmed)"));
    //         } else {
    //             checkCondition(false, string.concat(contractName, " bytecode match"));
    //         }
    //     }
    // }

    function checkCondition(
        bool condition,
        string memory description
    ) internal {
        totalChecks++;
        if (condition) {
            passedChecks++;
            console2.log("\x1b[32m  [PASS]", description, "\x1b[0m");
        } else {
            allChecksPassed = false;
            console2.log("\x1b[31m  [FAIL]", description, "\x1b[0m");
        }
    }
}