// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

interface ICurrentEtherFiNodesManager {
    function allowedForwardedEigenpodCalls(bytes4 selector) external view returns (bool);
    function allowedForwardedExternalCalls(bytes4 selector, address target) external view returns (bool);
}

/**
 * @title DiscoverCurrentWhitelist
 * @notice Discover what's ACTUALLY whitelisted in the current (pre-upgrade) contract
 */
contract DiscoverCurrentWhitelist is Script {

    ICurrentEtherFiNodesManager constant nodesManager = ICurrentEtherFiNodesManager(0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F);

    function run() external view {
        console2.log("=== DISCOVERING CURRENT WHITELIST ===");
        console2.log("Contract:", address(nodesManager));
        console2.log("Using PRE-UPGRADE interface signatures");
        console2.log("");

        // Check EigenPod calls
        discoverEigenPodCalls();
        console2.log("");

        // Check External calls
        discoverExternalCalls();
        console2.log("");
    }

    function discoverEigenPodCalls() internal view {
        console2.log("--- EigenPod Calls (bytes4 => bool) ---");
        bytes4[] memory selectors = getAllSelectors();
        uint256 foundCount = 0;

        for (uint256 i = 0; i < selectors.length; i++) {
            try nodesManager.allowedForwardedEigenpodCalls(selectors[i]) returns (bool allowed) {
                if (allowed) {
                    console2.log("[FOUND] EigenPod selector:", vm.toString(selectors[i]));
                    foundCount++;
                }
            } catch {
                // Call failed - selector might be invalid format
                console.log("Call failed - 1");
            }
        }

        console2.log("Total EigenPod calls found:", foundCount);
    }

    function discoverExternalCalls() internal view {
        console2.log("--- External Calls (bytes4 => address => bool) ---");
        bytes4[] memory selectors = getAllSelectors();
        address[] memory targets = getAllTargets();
        uint256 foundCount = 0;

        for (uint256 i = 0; i < selectors.length; i++) {
            for (uint256 j = 0; j < targets.length; j++) {
                try nodesManager.allowedForwardedExternalCalls(selectors[i], targets[j]) returns (bool allowed) {
                    if (allowed) {
                        console2.log("[FOUND] External call:");
                        console2.log("  Selector:", vm.toString(selectors[i]));
                        console2.log("  Target:", targets[j]);
                        foundCount++;
                    }
                } catch {
                    console.log("Call failed - 2");
                }
            }
        }

        console2.log("Total external calls found:", foundCount);
    }

    function getAllSelectors() internal pure returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](20);

        // EigenPod functions
        selectors[0] = 0x47d28372; // currentCheckpoint()
        selectors[1] = 0x0b18ff66; // podOwner()
        selectors[2] = 0x84d81062; // eigenPodManager()
        selectors[3] = 0x60f4062b; // hasRestaked()
        selectors[4] = bytes4(keccak256("activateRestaking()"));
        selectors[5] = bytes4(keccak256("withdrawBeforeRestaking()"));
        selectors[6] = bytes4(keccak256("startCheckpoint(bool)"));
        selectors[7] = bytes4(keccak256("verifyBalanceUpdates(uint64,uint40,(bytes32,bytes32,bytes32,bytes32)[],(bytes32,bytes32)[],(bytes32[],bytes)[],(bytes32,bytes)[][])"));

        // RewardsCoordinator functions
        selectors[8] = 0x3ccc861d; // processClaim - complex struct
        selectors[9] = 0xa4ae73a5; // processClaim - simple params
        selectors[10] = bytes4(keccak256("claimRewards(address,address)"));
        selectors[11] = bytes4(keccak256("submitRoot(bytes32,uint32)"));

        // DelegationManager functions  
        selectors[12] = bytes4(keccak256("delegate(address)"));
        selectors[13] = bytes4(keccak256("undelegate()"));
        selectors[14] = bytes4(keccak256("queueWithdrawals((address[],uint256[],address)[])"));
        selectors[15] = bytes4(keccak256("completeQueuedWithdrawals((address,address,address,uint256,uint32,address[],uint256[])[],(address,uint96)[][],bool[])"));
        selectors[16] = bytes4(keccak256("delegatedTo(address)"));
        selectors[17] = bytes4(keccak256("isDelegated(address)"));

        // EigenPodManager functions
        selectors[18] = bytes4(keccak256("createPod()"));
        selectors[19] = bytes4(keccak256("stake(bytes,bytes,bytes32)"));

        return selectors;
    }

    function getAllTargets() internal pure returns (address[] memory) {
        address[] memory targets = new address[](25);

        // EigenLayer contracts
        targets[0] = 0x7750d328b314EfFa365A0402CcfD489B80B0adda; // RewardsCoordinator
        targets[1] = 0x91E677b07F7AF907ec9a428aafA9fc14a0d3A338; // EigenPodManager
        targets[2] = 0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A; // DelegationManager
        targets[3] = 0x858646372CC42E1A627fcE94aa7A7033e7CF075A; // StrategyManager
        targets[4] = 0xbeaC0eeEeeeeEEeEeEEEEeeEEeEeeeEeeEEBEaC0; // BeaconChainETHStrategy

        // EtherFi contracts
        targets[5] = 0x35F4f28A8d3Ff20EEd10e087e8F96Ea2641E6AA2; // EtherFi LiquidityPool
        targets[6] = 0x25e821b7197B146F7713C3b89B6A4D83516B912d; // EtherFi StakingManager
        targets[7] = 0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F; // EtherFi NodesManager
  
        return targets;
    }

    // Helper function to check specific combinations manually
    function checkSpecific(bytes4 selector, address target) external view returns (bool) {
        return nodesManager.allowedForwardedExternalCalls(selector, target);
    }
}