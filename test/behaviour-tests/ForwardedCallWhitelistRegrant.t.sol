// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {EtherFiNodesManager} from "@etherfi/staking/EtherFiNodesManager.sol";
import {RoleRegistry} from "@etherfi/governance/RoleRegistry.sol";
import {SecurityUpgradesScript} from "@scripts/upgrades/security-upgrades/transactions.s.sol";

/// @dev Exposes the script's pinned forwarded-call selector/target lists so the test exercises the
///      exact set the OPERATING_TIMELOCK batch (_buildOperatingConfigBatch) re-grants — no drift.
contract WhitelistHarness is SecurityUpgradesScript {
    function eigenpodSelectors() external pure returns (bytes4[] memory) {
        return _forwardedEigenpodSelectors();
    }
    function externalCalls() external pure returns (bytes4[] memory, address[] memory) {
        return _forwardedExternalCalls();
    }
}

/**
 * @title ForwardedCallWhitelistRegrant
 * @notice Mainnet-fork simulation of the Batch 2 forwarded-call whitelist re-grant.
 *
 * Flow (mirrors the real upgrade):
 *   1. fork mainnet, deploy the new EtherFiNodesManager impl, upgrade the proxy via its timelock owner
 *   2. as the real OPERATING_TIMELOCK, apply updateAllowedForwarded{Eigenpod,External}Calls for the
 *      eigenpod-ops role holder over the exact SEL_* set the script emits
 *   3. assert every entry reads back true for the holder (same check as verifyOperatingConfig), and
 *      that the legacy pod-prover EOA is NOT whitelisted (the "remove from current address" intent)
 *
 * Run: forge test --match-contract ForwardedCallWhitelistRegrant --fork-url $MAINNET_RPC_URL -vv
 */
contract ForwardedCallWhitelistRegrantTest is Test {
    EtherFiNodesManager constant enm = EtherFiNodesManager(payable(0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F));
    RoleRegistry constant roleRegistry = RoleRegistry(0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9);

    address constant STAKING_MANAGER     = 0x25e821b7197B146F7713C3b89B6A4D83516B912d;
    address constant ETHERFI_RATE_LIMITER = 0x6C7c54cfC2225fA985cD25F04d923B93c60a02F8;

    // Upgrade-timelock: owner of the ENM proxy and admin of the RoleRegistry on mainnet.
    address constant TIMELOCK_OWNER    = 0x9f26d4C958fD811A1F59B01B86Be7dFFc9d20761;
    // The operating-timelock that executes Batch 2 (holds OPERATION_TIMELOCK_ROLE on mainnet).
    address constant OPERATING_TIMELOCK = 0xcD425f44758a08BaAB3C4908f3e3dE5776e45d7a;
    // Legacy pod-prover / call forwarder that must NOT be re-granted.
    address constant LEGACY_POD_PROVER = 0x7835fB36A8143a014A2c381363cD1A4DeE586d2A;

    WhitelistHarness harness;
    address holder = makeAddr("eigenpodOperationsRoleHolder");

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        harness = new WhitelistHarness();

        // Deploy + upgrade to the new EtherFiNodesManager impl (per-caller whitelist layout).
        EtherFiNodesManager newImpl = new EtherFiNodesManager(STAKING_MANAGER, address(roleRegistry), ETHERFI_RATE_LIMITER);
        vm.prank(TIMELOCK_OWNER);
        enm.upgradeTo(address(newImpl));

        // The live RoleRegistry predates the new role API, so onlyOperatingTimelock would revert. In
        // production Batch 1 upgrades the RoleRegistry and grants OPERATION_TIMELOCK_ROLE to the
        // operating timelock; here we mock just that auth gate to a pass for the timelock, leaving the
        // rest (real new ENM impl, real per-user whitelist storage, getters) live on the fork.
        vm.mockCall(
            address(roleRegistry),
            abi.encodeWithSelector(bytes4(keccak256("onlyOperatingTimelock(address)")), OPERATING_TIMELOCK),
            bytes("")
        );
    }

    function test_migrateForwardedCallWhitelistToRoleHolder() public {
        (bytes4[] memory eig) = harness.eigenpodSelectors();
        (bytes4[] memory extSel, address[] memory extTgt) = harness.externalCalls();

        // Pre-state: every migrated entry is currently held by the legacy caller on mainnet.
        for (uint256 i = 0; i < eig.length; i++) {
            assertTrue(enm.allowedForwardedEigenpodCalls(LEGACY_POD_PROVER, eig[i]), "legacy eigenpod entry expected live pre-migration");
        }
        for (uint256 i = 0; i < extSel.length; i++) {
            assertTrue(enm.allowedForwardedExternalCalls(LEGACY_POD_PROVER, extSel[i], extTgt[i]), "legacy external entry expected live pre-migration");
        }

        // Apply the Batch 2 migration as the operating timelock: grant new holder + revoke legacy.
        vm.startPrank(OPERATING_TIMELOCK);
        for (uint256 i = 0; i < eig.length; i++) {
            enm.updateAllowedForwardedEigenpodCalls(holder, eig[i], true);
            enm.updateAllowedForwardedEigenpodCalls(LEGACY_POD_PROVER, eig[i], false);
        }
        for (uint256 i = 0; i < extSel.length; i++) {
            enm.updateAllowedForwardedExternalCalls(holder, extSel[i], extTgt[i], true);
            enm.updateAllowedForwardedExternalCalls(LEGACY_POD_PROVER, extSel[i], extTgt[i], false);
        }
        vm.stopPrank();

        // Post-state: holder has every entry, legacy caller has none (verifyOperatingConfig parity).
        for (uint256 i = 0; i < eig.length; i++) {
            assertTrue(enm.allowedForwardedEigenpodCalls(holder, eig[i]), "eigenpod selector not granted to holder");
            assertFalse(enm.allowedForwardedEigenpodCalls(LEGACY_POD_PROVER, eig[i]), "eigenpod selector not revoked from legacy caller");
        }
        for (uint256 i = 0; i < extSel.length; i++) {
            assertTrue(enm.allowedForwardedExternalCalls(holder, extSel[i], extTgt[i]), "external call not granted to holder");
            assertFalse(enm.allowedForwardedExternalCalls(LEGACY_POD_PROVER, extSel[i], extTgt[i]), "external call not revoked from legacy caller");
        }

        // A selector outside the set stays false (the grant is specific, not blanket).
        assertFalse(enm.allowedForwardedEigenpodCalls(holder, bytes4(0xdeadbeef)), "unexpected selector granted");

        console2.log("[OK] migrated eigenpod selectors:", eig.length);
        console2.log("[OK] migrated external (selector,target) pairs:", extSel.length);
    }

    /// @dev Sanity-check the harness exposes the verified set (3 eigenpod + 1 external).
    function test_whitelistSetCounts() public view {
        (bytes4[] memory eig) = harness.eigenpodSelectors();
        (bytes4[] memory extSel,) = harness.externalCalls();
        assertEq(eig.length, 3, "eigenpod selector count");
        assertEq(extSel.length, 1, "external call count");
    }
}
