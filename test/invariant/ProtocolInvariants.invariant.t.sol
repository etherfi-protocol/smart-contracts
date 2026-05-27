// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "../TestSetup.sol";
import "./handlers/ProtocolInvariantsHandler.sol";

/// @notice Stateful invariant suite for PR #428's two inlined invariants AND
///         the global protocol-accounting conservation laws those two
///         invariants are built on top of.
///
///         Foundry's invariant runner calls random sequences of handler
///         functions (depth × runs). After each sequence, the assertions
///         below are evaluated against live contract state. The unit fuzz
///         in `test/ProtocolInvariants.t.sol` pressure-tests SINGLE calls;
///         this suite pressure-tests SEQUENCES, where path-dependent
///         interactions between deposit / wrap / unwrap / burn / rebase /
///         transfer / donate / raw-ETH-into-`receive()` / ERM-burn can
///         surface bugs no single-call fuzz would see.
///
///         What "non-exempt path never drops the rate" actually checks:
///         the in-contract modifier already reverts on such drops, so a
///         successful return implies non-decrease per-call. The handler's
///         ghost flag would only flip if the modifier were ever broken,
///         bypassed, or refactored to widen its coverage and accidentally
///         classify a real exempt path as non-exempt (or vice versa). This
///         flag is the regression guard for that specific class of bug.
///
///         The global-conservation invariants below are the load-bearing
///         additions. PR #428's two hooks are LOCAL (single-call) properties;
///         a refactor or new mint authority that drifts total-shares or LP
///         solvency across a long sequence could still pass them silently.
///         Conservation laws catch that class without needing the hook to
///         fire.
///
///         Defaults: 256 runs × 15-call depth. Overridden via the
///         `forge-config` magic comments below to 256 × 64 (~50k calls per
///         invariant). For local stress, bump these inline — the suite scales
///         linearly and stayed green at 512 × 100 (~150k calls) during
///         authoring.
///
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = false
/// forge-config: default.invariant.call-override = false
contract ProtocolInvariantsInvariantTest is TestSetup {
    ProtocolInvariantsHandler internal handler;

    function setUp() public {
        setUpTests();

        handler = new ProtocolInvariantsHandler(
            liquidityPoolInstance,
            eETHInstance,
            weEthInstance,
            address(etherFiRedemptionManagerInstance),
            address(withdrawRequestNFTInstance),
            address(priorityQueueInstance),
            address(membershipManagerInstance),
            treasuryInstance
        );

        // Whitelist only the handler so the fuzzer doesn't try to call
        // protocol contracts directly (which would either need correct
        // pranks/calldata or just bounce off auth checks).
        targetContract(address(handler));
    }

    // =====================================================================
    // INVARIANT 1 — weETH supply at-most-fully-backed by proxy eETH shares
    // =====================================================================

    /// @notice `weETH.totalSupply() <= eETH.shares(weETH_proxy)` survives ANY
    ///         sequence of handler operations. The in-contract hook enforces
    ///         it per-call; this verifies no cross-call composition (over-
    ///         donations followed by burns, wrap/unwrap loops interleaved
    ///         with rebases, etc.) can leave the proxy under-backed.
    ///
    ///         Also polls the handler's worst-underbacking tap so a
    ///         hypothetical hook regression that allowed a tiny positive
    ///         gap during a call (but reverted at the end via some other
    ///         path) would still surface in the failure trace.
    function invariant_inv1_weeth_at_most_backed_by_proxy_shares() public {
        // Update the running worst-gap ghost before asserting — the function
        // returns the live gap; we ignore the return and assert against the
        // ghost so the failure message points at the worst observation.
        handler.observeBackingGap();

        assertLe(
            weEthInstance.totalSupply(),
            eETHInstance.shares(address(weEthInstance)),
            "weETH underbacked across handler sequence"
        );
        assertLe(
            handler.ghost_worstWeethUnderbacking(),
            int256(0),
            "weETH underbacking observed during sequence"
        );
    }

    // =====================================================================
    // INVARIANT 2 — non-exempt LP paths never drop the eETH rate
    // =====================================================================

    /// @notice Across every handler call sequence, no non-exempt path (deposit,
    ///         burnEEthShares, burnEEthSharesForNonETHWithdrawal,
    ///         withdraw(address, uint256)) was observed to drop the rate.
    ///         Exempt paths (`rebase`, `withdraw(uint256, uint256)`) are
    ///         allowed to drop it; the handler does not flag those.
    function invariant_inv2_non_exempt_paths_never_drop_rate() public view {
        assertFalse(
            handler.ghost_nonExemptRateDrop(),
            "non-exempt path dropped the eETH rate"
        );
    }

    // =====================================================================
    // GLOBAL CONSERVATION — load-bearing properties the per-call hooks
    // assume but never assert directly. A regression that drifts these
    // could leave PR #428's local invariants still passing.
    // =====================================================================

    /// @notice `LP.totalValueInLp + LP.totalValueOutOfLp == LP.getTotalPooledEther()`.
    ///         Definitional today — `getTotalPooledEther` literally returns
    ///         the sum — but pins the relationship so a future refactor that
    ///         splits the accumulator (e.g., introduces a third bucket for
    ///         restaked-but-not-yet-accounted ETH) can't silently break the
    ///         rate's denominator.
    function invariant_lp_tvl_decomposition() public view {
        uint256 sum = uint256(liquidityPoolInstance.totalValueInLp())
                    + uint256(liquidityPoolInstance.totalValueOutOfLp());
        assertEq(
            sum,
            liquidityPoolInstance.getTotalPooledEther(),
            "TVL decomposition broken"
        );
    }

    /// @notice `address(LP).balance >= totalValueInLp`. The PR-existing
    ///         `_checkTotalValueInLp` enforces this at call sites; checking
    ///         it globally surfaces any path that *bypasses* the helper
    ///         (e.g., a future `_sendFund` variant that forgets to call it).
    ///         A negative-rebase + ETH-out-of-LP composition is the most
    ///         likely way to drift this if the per-site checks were ever
    ///         relaxed.
    function invariant_lp_solvency_in_lp_bucket() public view {
        assertGe(
            address(liquidityPoolInstance).balance,
            uint256(liquidityPoolInstance.totalValueInLp()),
            "LP cannot cover totalValueInLp"
        );
    }

    /// @notice `sum eETH.shares(holder) == eETH.totalShares()` across every
    ///         address the handler has ever observed receiving shares.
    ///         If a mint path is ever added that increments `totalShares`
    ///         without crediting a tracked address (or the inverse — a path
    ///         that mutates `shares[user]` without `totalShares`), this
    ///         assertion fails immediately.
    ///
    ///         The enumeration is conservative: it includes the handler's
    ///         EOA pool plus protocol contracts that have received shares
    ///         (LP, eETH/weETH proxies, ERM, WRN, PQ, treasury). Any path
    ///         that credits a NEW address the handler never observed would
    ///         leave `sum < totalShares` and trip `assertEq`.
    function invariant_global_total_shares_conserved() public view {
        uint256 n = handler.shareHoldersLength();
        uint256 acc;
        for (uint256 i = 0; i < n; i++) {
            acc += eETHInstance.shares(handler.shareHolderAt(i));
        }
        assertEq(
            acc,
            eETHInstance.totalShares(),
            "eETH total-shares accounting drift across handler sequence"
        );
    }

    // =====================================================================
    // CALL SUMMARY — observability, not a true invariant
    // =====================================================================

    /// @notice Always-pass invariant whose purpose is to print the handler's
    ///         call-count buckets so we can confirm the fuzzer actually
    ///         exercises each path during a `-vv` run. If any bucket is
    ///         dominated by `_skipped` / `_revert`, the handler's input
    ///         bounds need tuning (the sequence would be biased away from
    ///         that path).
    function invariant_call_coverage_summary() public {
        emit log_named_uint("deposit                ", handler.callCounts("deposit"));
        emit log_named_uint("deposit_revert         ", handler.callCounts("deposit_revert"));
        emit log_named_uint("wrap                   ", handler.callCounts("wrap"));
        emit log_named_uint("wrap_skipped           ", handler.callCounts("wrap_skipped"));
        emit log_named_uint("wrap_revert            ", handler.callCounts("wrap_revert"));
        emit log_named_uint("unwrap                 ", handler.callCounts("unwrap"));
        emit log_named_uint("unwrap_skipped         ", handler.callCounts("unwrap_skipped"));
        emit log_named_uint("unwrap_revert          ", handler.callCounts("unwrap_revert"));
        emit log_named_uint("burn                   ", handler.callCounts("burn"));
        emit log_named_uint("burn_skipped           ", handler.callCounts("burn_skipped"));
        emit log_named_uint("burn_revert            ", handler.callCounts("burn_revert"));
        emit log_named_uint("bForNon                ", handler.callCounts("bForNon"));
        emit log_named_uint("bForNon_skipped        ", handler.callCounts("bForNon_skipped"));
        emit log_named_uint("bForNon_revert         ", handler.callCounts("bForNon_revert"));
        emit log_named_uint("rebase_positive        ", handler.callCounts("rebase_positive"));
        emit log_named_uint("rebase_negative        ", handler.callCounts("rebase_negative"));
        emit log_named_uint("rebase_revert          ", handler.callCounts("rebase_revert"));
        emit log_named_uint("donate                 ", handler.callCounts("donate"));
        emit log_named_uint("donate_skipped         ", handler.callCounts("donate_skipped"));
        emit log_named_uint("donate_revert          ", handler.callCounts("donate_revert"));
        emit log_named_uint("transfer_eeth          ", handler.callCounts("transfer_eeth"));
        emit log_named_uint("transfer_eeth_revert   ", handler.callCounts("transfer_eeth_revert"));
        emit log_named_uint("transfer_weeth         ", handler.callCounts("transfer_weeth"));
        emit log_named_uint("transfer_weeth_revert  ", handler.callCounts("transfer_weeth_revert"));
        emit log_named_uint("sendRawEth             ", handler.callCounts("sendRawEth"));
        emit log_named_uint("sendRawEth_revert      ", handler.callCounts("sendRawEth_revert"));
    }
}
