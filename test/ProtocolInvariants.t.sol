// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "../src/ProtocolInvariants.sol";
import "../src/interfaces/IProtocolInvariants.sol";

/// @notice Tests for Invariant 1: `weETH.totalSupply <= eETH.shares(weETHProxy)`.
///
///         Coverage spine:
///           - Mode machinery (DISABLED / OBSERVE / ENFORCE) and access control.
///           - Real wrap/unwrap don't trigger violations (invariant holds by construction).
///           - Synthetic underbacking via storage poke triggers expected behavior in
///             each mode (no-op / emit-only / emit+revert).
///           - Over-collateralization (accidental eETH airdrop to proxy) does NOT trip.
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
    // Mode machinery & access control
    // =====================================================================

    function test_initial_mode_is_OBSERVE() public {
        assertEq(uint256(protocolInvariantsInstance.mode()), uint256(IProtocolInvariants.Mode.OBSERVE));
    }

    function test_setMode_requires_multisig() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        protocolInvariantsInstance.setMode(IProtocolInvariants.Mode.ENFORCE);

        vm.prank(multisigOnly);
        protocolInvariantsInstance.setMode(IProtocolInvariants.Mode.ENFORCE);
        assertEq(uint256(protocolInvariantsInstance.mode()), uint256(IProtocolInvariants.Mode.ENFORCE));
    }

    function test_setMode_emits_event() public {
        vm.prank(multisigOnly);
        vm.expectEmit(true, true, true, true);
        emit IProtocolInvariants.ModeChanged(IProtocolInvariants.Mode.OBSERVE, IProtocolInvariants.Mode.ENFORCE);
        protocolInvariantsInstance.setMode(IProtocolInvariants.Mode.ENFORCE);
    }

    function test_DISABLED_mode_is_noop_even_when_underbacked() public {
        // Synthesize underbacking, then flip to DISABLED, then run the check.
        // No event, no revert.
        _pokeUnderbacking(1e18);

        vm.prank(multisigOnly);
        protocolInvariantsInstance.setMode(IProtocolInvariants.Mode.DISABLED);

        // No revert in ENFORCE-equivalent scenario, no emit. Record logs to assert.
        vm.recordLogs();
        protocolInvariantsInstance.check_weETH_backed();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "DISABLED mode must not emit");
    }

    // =====================================================================
    // OBSERVE mode: emit on violation, do NOT revert
    // =====================================================================

    function test_OBSERVE_underbacked_emits_event_and_does_NOT_revert() public {
        _pokeUnderbacking(5e18);

        vm.expectEmit(true, true, true, true);
        emit IProtocolInvariants.InvariantViolated(
            "weETH-underbacked",
            weEthInstance.totalSupply(),
            eETHInstance.shares(address(weEthInstance))
        );
        protocolInvariantsInstance.check_weETH_backed();
    }

    function test_OBSERVE_balanced_does_NOT_emit() public {
        // Set up a real wrap so the invariant naturally holds, then check.
        _wrap(alice, 2 ether);

        vm.recordLogs();
        protocolInvariantsInstance.check_weETH_backed();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "balanced state must not emit");
    }

    // =====================================================================
    // ENFORCE mode: emit AND revert on violation
    // =====================================================================

    function test_ENFORCE_underbacked_reverts() public {
        vm.prank(multisigOnly);
        protocolInvariantsInstance.setMode(IProtocolInvariants.Mode.ENFORCE);

        _pokeUnderbacking(5e18);

        vm.expectRevert();
        protocolInvariantsInstance.check_weETH_backed();
    }

    function test_ENFORCE_balanced_passes() public {
        vm.prank(multisigOnly);
        protocolInvariantsInstance.setMode(IProtocolInvariants.Mode.ENFORCE);

        _wrap(alice, 1 ether);
        protocolInvariantsInstance.check_weETH_backed();   // must not revert
    }

    function test_ENFORCE_overcollateralized_passes() public {
        // Donate eETH directly to the weETH proxy. weETH.totalSupply unchanged;
        // eETH.shares(proxy) increases. invariant: totalSupply <= proxyShares holds.
        vm.prank(multisigOnly);
        protocolInvariantsInstance.setMode(IProtocolInvariants.Mode.ENFORCE);

        // Give alice extra eETH to donate.
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        liquidityPoolInstance.deposit{value: 5 ether}();

        vm.prank(alice);
        eETHInstance.transfer(address(weEthInstance), 1 ether);

        // The transfer itself triggered _beforeTokenTransfer hooks etc. but the
        // weETH `_afterTokenTransfer` only runs on weETH state changes; an eETH
        // transfer doesn't trigger weETH hooks. So no automatic check fired.
        // Explicit check still passes — over-collateralization is benign.
        protocolInvariantsInstance.check_weETH_backed();
    }

    // =====================================================================
    // Real wrap/unwrap exercise the in-line hook end-to-end
    // =====================================================================

    function test_wrap_under_ENFORCE_does_not_revert() public {
        vm.prank(multisigOnly);
        protocolInvariantsInstance.setMode(IProtocolInvariants.Mode.ENFORCE);

        // Wrap must succeed even with ENFORCE on — the deposit-then-mint order in
        // wrap() guarantees the invariant holds at the _afterTokenTransfer hook.
        _wrap(alice, 3 ether);
    }

    function test_unwrap_under_ENFORCE_does_not_revert() public {
        _wrap(alice, 3 ether);

        vm.prank(multisigOnly);
        protocolInvariantsInstance.setMode(IProtocolInvariants.Mode.ENFORCE);

        uint256 weAmt = weEthInstance.balanceOf(alice);
        vm.prank(alice);
        weEthInstance.unwrap(weAmt);
    }

    function test_wrap_unwrap_loop_preserves_invariant() public {
        vm.prank(multisigOnly);
        protocolInvariantsInstance.setMode(IProtocolInvariants.Mode.ENFORCE);

        vm.startPrank(alice);
        eETHInstance.approve(address(weEthInstance), type(uint256).max);
        for (uint256 i = 0; i < 20; i++) {
            uint256 minted = weEthInstance.wrap(1 ether);
            weEthInstance.unwrap(minted);
        }
        vm.stopPrank();
    }

    // =====================================================================
    // View helper: weETHBackingDelta
    // =====================================================================

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
