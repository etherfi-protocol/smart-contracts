// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "../src/ProtocolInvariants.sol";
import "../src/interfaces/IProtocolInvariants.sol";

/// @notice Tests for ProtocolInvariants — covers both:
///         - Invariant 1: weETH supply backed by eETH shares in proxy.
///         - Invariant 2: eETH exchange-rate monotonicity.
///         Deploys live; the kill switch (`setEnabled(false)`) exists for
///         emergencies only and is exercised here just to prove it works.
contract ProtocolInvariantsTest is TestSetup {
    address internal multisigOnly;
    address internal unauthorized = address(0xDEAD);

    // weETH `_totalSupply` lives at storage slot 103 — verified via
    // `forge inspect WeETH storageLayout`. The slot is higher than naive 0/1/2
    // because WeETH inherits Initializable + multiple OZ upgradeable contracts
    // each carrying a 50-slot __gap. Used to synthesize underbacking via
    // vm.store without going through a real mint path.
    uint256 private constant WEETH_TOTAL_SUPPLY_SLOT = 103;

    function setUp() public {
        setUpTests();

        // Fund alice with eETH so wrap/unwrap tests have something to move.
        vm.deal(alice, 100 ether);
        vm.prank(alice);
        liquidityPoolInstance.deposit{value: 50 ether}();

        // Multisig-only address for access-control proofs.
        multisigOnly = address(0xBEEF);
        vm.startPrank(owner);
        roleRegistryInstance.grantRole(roleRegistryInstance.OPERATION_MULTISIG_ROLE(), multisigOnly);
        vm.stopPrank();
    }

    // =====================================================================
    // Kill switch & access control
    // =====================================================================

    function test_initial_state_is_enabled() public {
        assertTrue(protocolInvariantsInstance.enabled());
    }

    function test_setEnabled_requires_multisig() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        protocolInvariantsInstance.setEnabled(false);

        vm.prank(multisigOnly);
        protocolInvariantsInstance.setEnabled(false);
        assertFalse(protocolInvariantsInstance.enabled());
    }

    function test_setEnabled_emits_event() public {
        vm.prank(multisigOnly);
        vm.expectEmit(true, true, true, true);
        emit IProtocolInvariants.EnabledChanged(true, false);
        protocolInvariantsInstance.setEnabled(false);
    }

    function test_disabled_is_noop_even_when_underbacked() public {
        _pokeUnderbacking(1e18);

        vm.prank(multisigOnly);
        protocolInvariantsInstance.setEnabled(false);

        // No revert when disabled even on a violating state.
        protocolInvariantsInstance.check_weETH_backed();
    }

    // =====================================================================
    // Invariant 1 — weETH backing
    // =====================================================================

    function test_weETH_underbacked_reverts() public {
        _pokeUnderbacking(5e18);

        vm.expectRevert();
        protocolInvariantsInstance.check_weETH_backed();
    }

    function test_weETH_balanced_passes() public {
        _wrap(alice, 2 ether);
        protocolInvariantsInstance.check_weETH_backed();
    }

    function test_weETH_overcollateralized_passes() public {
        // Donate eETH directly to the weETH proxy. weETH.totalSupply unchanged;
        // eETH.shares(proxy) increases. invariant: totalSupply <= proxyShares
        // holds — over-collateralization is benign.
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        liquidityPoolInstance.deposit{value: 5 ether}();

        vm.prank(alice);
        eETHInstance.transfer(address(weEthInstance), 1 ether);

        protocolInvariantsInstance.check_weETH_backed();
    }

    // Real wrap/unwrap exercise the in-line hook end-to-end.

    function test_wrap_does_not_revert() public {
        _wrap(alice, 3 ether);
    }

    function test_unwrap_does_not_revert() public {
        _wrap(alice, 3 ether);
        uint256 weAmt = weEthInstance.balanceOf(alice);
        vm.prank(alice);
        weEthInstance.unwrap(weAmt);
    }

    function test_wrap_unwrap_loop_preserves_invariant() public {
        vm.startPrank(alice);
        eETHInstance.approve(address(weEthInstance), type(uint256).max);
        for (uint256 i = 0; i < 20; i++) {
            uint256 minted = weEthInstance.wrap(1 ether);
            weEthInstance.unwrap(minted);
        }
        vm.stopPrank();
    }

    // View helper

    function test_backingDelta_reports_balanced_when_balanced() public {
        _wrap(alice, 1 ether);
        (uint256 supply, uint256 proxyShares, bool underbacked) = protocolInvariantsInstance.weETHBackingDelta();
        assertEq(supply, proxyShares, "supply should equal proxy shares after a clean wrap");
        assertFalse(underbacked);
    }

    function test_backingDelta_reports_underbacked_when_underbacked() public {
        _pokeUnderbacking(7e18);
        (uint256 supply, uint256 proxyShares, bool underbacked) = protocolInvariantsInstance.weETHBackingDelta();
        assertGt(supply, proxyShares);
        assertTrue(underbacked);
    }

    // =====================================================================
    // Invariant 2 — eETH exchange-rate monotonicity
    // =====================================================================
    //
    // The modifier on LP snapshots (P0,S0) before and (P1,S1) after a
    // share-changing call. The check function is what gets exercised here —
    // calling it directly with constructed values lets us probe the math
    // without having to synthesize a real LP exploit tx.

    function test_eETHRate_check_requires_LP_caller() public {
        // Non-LP callers must hit `onlyLP`. The onlyLP modifier runs BEFORE
        // the enabled-check, so even a disabled invariant doesn't open the
        // gate for fake callers.
        vm.prank(unauthorized);
        vm.expectRevert(IProtocolInvariants.OnlyLiquidityPool.selector);
        protocolInvariantsInstance.check_eETHRateMonotonic(100, 100, 100, 100);

        vm.prank(multisigOnly);
        vm.expectRevert(IProtocolInvariants.OnlyLiquidityPool.selector);
        protocolInvariantsInstance.check_eETHRateMonotonic(100, 100, 100, 100);
    }

    function test_eETHRate_balanced_passes() public {
        vm.prank(address(liquidityPoolInstance));
        protocolInvariantsInstance.check_eETHRateMonotonic(100e18, 100e18, 101e18, 101e18);
    }

    function test_eETHRate_increased_passes() public {
        // Rebase / fee-enriched path: rate ticks UP (more pool per share).
        vm.prank(address(liquidityPoolInstance));
        protocolInvariantsInstance.check_eETHRateMonotonic(100e18, 100e18, 105e18, 100e18);
    }

    function test_eETHRate_share_neutral_passes_even_when_rate_drops() public {
        // Slashing-style rebase: pool shrinks, shares unchanged. The S0 == S1
        // guard skips the check — share-neutral paths are exempt by design.
        vm.prank(address(liquidityPoolInstance));
        protocolInvariantsInstance.check_eETHRateMonotonic(100e18, 100e18, 90e18, 100e18);
    }

    function test_eETHRate_bootstrap_passes() public {
        // S0 == 0 (first deposit) and S1 == 0 (drained pool) are exempted.
        vm.startPrank(address(liquidityPoolInstance));
        protocolInvariantsInstance.check_eETHRateMonotonic(0, 0, 100e18, 100e18);
        protocolInvariantsInstance.check_eETHRateMonotonic(100e18, 100e18, 0, 0);
        vm.stopPrank();
    }

    function test_eETHRate_unbacked_mint_reverts() public {
        // Before: rate = 100/100 = 1.0
        // After:  rate = 100/110 ≈ 0.909  (deflated)
        vm.prank(address(liquidityPoolInstance));
        vm.expectRevert();
        protocolInvariantsInstance.check_eETHRateMonotonic(100e18, 100e18, 100e18, 110e18);
    }

    function test_eETHRate_skim_with_share_change_reverts() public {
        // Pool drained AND shares went up.
        vm.prank(address(liquidityPoolInstance));
        vm.expectRevert();
        protocolInvariantsInstance.check_eETHRateMonotonic(100e18, 100e18, 90e18, 110e18);
    }

    function test_eETHRate_disabled_is_no_op_on_violation() public {
        vm.prank(multisigOnly);
        protocolInvariantsInstance.setEnabled(false);

        vm.prank(address(liquidityPoolInstance));
        protocolInvariantsInstance.check_eETHRateMonotonic(100e18, 100e18, 100e18, 110e18);
    }

    function test_eETHRate_real_deposit_passes() public {
        // End-to-end: real deposit via LP, modifier runs, no revert.
        address user = address(0xC0FFEE);
        vm.deal(user, 5 ether);
        vm.prank(user);
        liquidityPoolInstance.deposit{value: 3 ether}();
    }

    function test_eETHRate_LP_prank_unbacked_mint_aftermath_does_not_false_trip() public {
        // The modifier is designed to revert the EXPLOIT TX itself. After an
        // out-of-band unbacked mint (here simulated by pranking LP), the new
        // (deflated) rate becomes the baseline; subsequent proportional
        // deposits preserve that ratio and don't false-trip. This documents
        // the scope: invariant catches the exploit, not the aftermath.
        vm.prank(address(liquidityPoolInstance));
        eETHInstance.mintShares(address(0xBAD), 50 ether);

        address user = address(0xC0FFEE2);
        vm.deal(user, 5 ether);
        vm.prank(user);
        liquidityPoolInstance.deposit{value: 1 ether}();
    }

    // =====================================================================
    // Helpers
    // =====================================================================

    /// @dev Direct storage poke to forge an underbacked state without an actual
    ///      exploit path. Sets weETH.totalSupply to `currentSupply + delta`,
    ///      leaving eETH.shares(weETHProxy) unchanged → invariant is violated.
    function _pokeUnderbacking(uint256 delta) internal {
        uint256 current = weEthInstance.totalSupply();
        vm.store(address(weEthInstance), bytes32(WEETH_TOTAL_SUPPLY_SLOT), bytes32(current + delta));
    }

    function _wrap(address user, uint256 eETHAmount) internal returns (uint256) {
        vm.startPrank(user);
        eETHInstance.approve(address(weEthInstance), type(uint256).max);
        uint256 weAmt = weEthInstance.wrap(eETHAmount);
        vm.stopPrank();
        return weAmt;
    }
}
