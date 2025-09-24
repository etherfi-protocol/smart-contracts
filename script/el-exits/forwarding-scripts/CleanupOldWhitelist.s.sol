// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

// Interface for the CURRENT (pre-upgrade) contract with OLD signatures
interface ICurrentEtherFiNodesManager {
    // OLD view functions
    function allowedForwardedEigenpodCalls(bytes4 selector) external view returns (bool);
    function allowedForwardedExternalCalls(bytes4 selector, address target) external view returns (bool);

    // OLD admin functions to clear the global mappings
    function updateAllowedForwardedEigenpodCalls(bytes4 selector, bool allowed) external;
    function updateAllowedForwardedExternalCalls(bytes4 selector, address target, bool allowed) external;
}

/**
 * @title CleanupOldWhitelist
 * @notice Clear the old whitelist mappings before upgrade deployment
 * @dev Based on DiscoverCurrentWhitelist.s.sol findings:
 *      Run the discovery script first to identify what needs to be cleared
 */
contract CleanupOldWhitelist is Script {

    ICurrentEtherFiNodesManager constant nodesManager = ICurrentEtherFiNodesManager(0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F);

    function run() external {
        console2.log("=== CLEANING UP OLD WHITELIST MAPPINGS ===");
        console2.log("Contract:", address(nodesManager));
        console2.log("");

        vm.startBroadcast();

        // Clear the specific items found by DiscoverCurrentWhitelist script
        clearFoundWhitelistItems();

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== CLEANUP COMPLETE ===");
        console2.log("Run verifyCleanup() to confirm all mappings are cleared");
    }

    function clearFoundWhitelistItems() internal {
        console2.log("--- Clearing Found Whitelist Items ---");
        console2.log("Based on DiscoverCurrentWhitelist.s.sol results:");
        console2.log("");

        // Clear EigenPod calls that were found whitelisted
        // Update these based on actual discovery script results
        clearEigenPodCall(0x0dd8dd02); // Replace with the found selector
        clearEigenPodCall(0x88676cad); // Replace with the found selector

        // Clear External calls that were found whitelisted  
        // Update these based on actual discovery script results
        clearExternalCall(0x3ccc861d, 0x7750d328b314EfFa365A0402CcfD489B80B0adda); // processClaim on RewardsCoordinator
        clearExternalCall(0x0dd8dd02, 0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A); // on DelegationManager

        console2.log("All found whitelist items cleared");
    }

    function clearEigenPodCall(bytes4 selector) internal {
        console2.log("Clearing EigenPod selector:", vm.toString(selector));
        // Use OLD interface - no user address needed, just selector and allowed=false
        nodesManager.updateAllowedForwardedEigenpodCalls(selector, false);
    }

    function clearExternalCall(bytes4 selector, address target) internal {
        console2.log("Clearing external call:");
        console2.log("  Selector:", vm.toString(selector));
        console2.log("  Target:", target);
        // Use OLD interface - no user address needed, just selector, target, allowed=false
        nodesManager.updateAllowedForwardedExternalCalls(selector, target, false);
    }

    // Verify cleanup worked by checking the same items that were found
    function verifyCleanup() external view {
        console2.log("=== VERIFYING CLEANUP ===");
        console2.log("Checking that previously whitelisted items are now cleared...");
        console2.log("");

        // Check EigenPod calls are cleared (using OLD interface without user address)
        bool eigenPod1 = nodesManager.allowedForwardedEigenpodCalls(0x0dd8dd02);
        bool eigenPod2 = nodesManager.allowedForwardedEigenpodCalls(0x88676cad);

        console2.log("EigenPod 0x0dd8dd02 cleared:", !eigenPod1);
        console2.log("EigenPod 0x88676cad cleared:", !eigenPod2);

        // Check External calls are cleared (using OLD interface without user address)
        bool external1 = nodesManager.allowedForwardedExternalCalls(0x3ccc861d, 0x7750d328b314EfFa365A0402CcfD489B80B0adda);
        bool external2 = nodesManager.allowedForwardedExternalCalls(0x0dd8dd02, 0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A);

        console2.log("External 0x3ccc861d on RewardsCoordinator cleared:", !external1);
        console2.log("External 0x0dd8dd02 on DelegationManager cleared:", !external2);

        console2.log("");
        if (!eigenPod1 && !eigenPod2 && !external1 && !external2) {
            console2.log(unicode"✓ ALL PREVIOUSLY WHITELISTED ITEMS SUCCESSFULLY CLEARED");
        } else {
            console2.log(unicode"✗ SOME ITEMS STILL WHITELISTED:");
            if (eigenPod1) console2.log("  - EigenPod 0x0dd8dd02 still active");
            if (eigenPod2) console2.log("  - EigenPod 0x88676cad still active");
            if (external1) console2.log("  - External 0x3ccc861d on RewardsCoordinator still active");
            if (external2) console2.log("  - External 0x0dd8dd02 on DelegationManager still active");
            console2.log("Check admin permissions and rerun cleanup if needed");
        }
    }
    
    // Helper function to clear specific items manually if needed
    function clearSpecific(bytes4 eigenPodSelector, bytes4 externalSelector, address target) external {
        vm.startBroadcast();

        if (eigenPodSelector != bytes4(0)) {
            console2.log("Manually clearing EigenPod selector:", vm.toString(eigenPodSelector));
            nodesManager.updateAllowedForwardedEigenpodCalls(eigenPodSelector, false);
        }

        if (externalSelector != bytes4(0) && target != address(0)) {
            console2.log("Manually clearing external call:");
            console2.log("  Selector:", vm.toString(externalSelector));
            console2.log("  Target:", target);
            nodesManager.updateAllowedForwardedExternalCalls(externalSelector, target, false);
        }

        vm.stopBroadcast();
    }
}