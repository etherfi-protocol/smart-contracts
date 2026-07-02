// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "../TestSetup.sol";
import "./handlers/WithdrawalSolvencyHandler.sol";

/// @notice FORK-based stateful invariant suite for I3 — Withdrawal Queue
///         Accounting / Solvency — exercised against the WithdrawRequestNFT
///         escrow path on a *latest-block mainnet fork* via
///         `initializeRealisticFork(MAINNET_FORK)`.
///
/// ─────────────────────────────────────────────────────────────────────────
/// I3 PROPERTY (protocol-ops/security/architecture/invariants.md)
/// ─────────────────────────────────────────────────────────────────────────
/// Informal: the total outstanding withdrawal claim never exceeds the
/// protocol's redeemable ETH.
/// Formal:  WithdrawRequestNFT outstanding finalizable claims
///            <= LP.getTotalPooledEther()
///             + EigenLayer-queued withdrawals (all pods)
///             - already-finalized claims.
///
/// ─────────────────────────────────────────────────────────────────────────
/// WHAT IS PROVABLE ON A FORK vs WHAT IS RECLASSIFIED
/// ─────────────────────────────────────────────────────────────────────────
/// The `+ EigenLayer-queued withdrawals(all pods)` term is LIVE state spread
/// across every EtherFiNode/EigenPod on mainnet. It cannot be deterministically
/// controlled at a latest-block fork (it drifts block-to-block and depends on
/// beacon-chain / EL checkpoint state we cannot author). Asserting an absolute
/// bound that includes that term would either (a) require us to fabricate EL
/// state (forbidden — would make the test assert something we didn't really
/// prove) or (b) be vacuous. We therefore RECLASSIFY that part to the
/// SC-enforced bound the contracts actually guarantee and which is strictly
/// STRONGER for the protocol's solvency (it ignores the favorable EL term and
/// requires the obligation be backed by in-protocol accounting alone):
///
///   (P1) finalize-never-exceeds-liquidity  [PROVED, SC-enforced]
///        Every successful finalize+lock had its locked eETH amount
///        <= LiquidityPool.totalValueInLp() at lock time. This is the exact
///        bound EtherFiAdmin._validateWithdrawals enforces
///        (`finalizedWithdrawalAmount <= totalValueInLp`) and that
///        LiquidityPool._lockEth re-enforces (`totalValueInLp < _amount`
///        reverts). Driven non-vacuously: see ghost_finalizeBoundChecks.
///
///   (P2) locked-within-accounted-state  [ASSUMPTION-SCOPED: bounded rebases]
///        ethAmountLockedForWithdrawal <= totalValueOutOfLp
///                                     <= getTotalPooledEther.
///        Finalize moves `amount` 1:1 from inLp->outOfLp AND adds `amount` to
///        the lock; claim removes `amountOfEEth` (full) from the lock but only
///        `amountToWithdraw (<= amountOfEEth)` from outOfLp (plus a stranded-ETH
///        sweep). Those two operations keep the lock a subset of out-of-LP value.
///        A NEGATIVE rebase, however, decrements totalValueOutOfLp WITHOUT
///        touching the lock, so a large enough slash could push outOfLp below the
///        lock and break this bound. This suite holds the bound only under the
///        assumption that rebases are bounded — enforced HERE by the handler's
///        rebaseNegative input filter (WithdrawalSolvencyHandler L416-431, which
///        caps the slash to <=0.5% of TVL and keeps headroom above the lock).
///        The corresponding PROTOCOL-level defense is EtherFiAdmin's rebase-APR
///        caps. So P2 is assumption-scoped, not unconditionally true. Also assert
///        WRN raw-ETH escrow >= lock (the segregated-balance solvency the claim
///        path relies on).
///
///   (P3) finalized-always-claimable  [PROVED, SC-enforced]
///        A finalized, valid, owned request whose frozen rate is in
///        [min,max] always claims successfully (escrow segregated at finalize
///        covers the payout; the frozen-rate share burn is bounded by the
///        request's own shares). Any revert under those preconditions trips
///        ghost_finalizedClaimFailed.
///
/// ─────────────────────────────────────────────────────────────────────────
/// SOUNDNESS ASSUMPTIONS (documented, not weakening)
/// ─────────────────────────────────────────────────────────────────────────
///  - We mirror production's finalize flow EXACTLY: WithdrawRequestNFT.finalizeRequests
///    the newly-finalized range, then lock its summed eETH via
///    LP.addEthAmountLockedForWithdrawal — the same finalize-then-lock order as
///    EtherFiAdmin._finalizeWithdrawals (both pranked as the real EtherFiAdmin
///    immutable that gates them). We do NOT call any path src/ doesn't expose.
///  - Negative rebases are bounded to <= 0.5% of TVL and kept above the WRN
///    lock. An extreme slash that drives amountForShare(1e18) below
///    LiquidityPool.minAmountForShare would legitimately block claims via
///    `_checkMinAmountForShare` — that is a *liveness* edge of the rate guard,
///    NOT an I3 solvency violation, so we keep it out of the P3 property by
///    bounding the slash. (Documented; the bound does not weaken P1/P2.)
///  - All assertions are DELTA-AWARE / construction-true: we never assume a
///    zero baseline. Mainnet starts with ~20.3k ETH locked, ~876 ETH in-LP,
///    ~1.84M ETH out-of-LP, and 69 pending unfinalized requests; the
///    invariants hold against that live state.
///
/// forge-config: default.invariant.runs = 32
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = false
/// forge-config: default.invariant.call-override = false
contract WithdrawalSolvencyInvariantTest is TestSetup {
    WithdrawalSolvencyHandler internal handler;
    address[5] internal handlerActors;

    /// @dev Pinned mainnet block (M1). Pinning removes the block-to-block drift
    ///      that made the old latest-block setUp's hardcoded state assumptions
    ///      (pending count, in-LP size) fragile. Every state-dependent value
    ///      below is DERIVED from the fork at this block, not hardcoded.
    uint256 internal constant PINNED_BLOCK = 25447657;

    // N1: post-setUp baselines. setUp seeds a full lifecycle (creates + finalizes
    // requests), so the created/finalized non-vacuity gates are pre-satisfied by
    // the seed. Record the seeded baselines and require the fuzzer to move
    // STRICTLY ABOVE them, so those gates reflect genuine fuzz activity.
    uint256 internal baselineCreated;
    uint256 internal baselineFinalized;

    function setUp() public {
        initializeRealisticForkWithBlock(MAINNET_FORK, PINNED_BLOCK);

        // WithdrawRequestNFT is already unpaused on the fork at the current
        // block; unpause defensively only if needed (OPERATION_MULTISIG = alice).
        if (withdrawRequestNFTInstance.paused()) {
            vm.prank(alice);
            withdrawRequestNFTInstance.unpause();
        }

        // Grant GUARDIAN_ROLE to alice so the S3 probe can call the
        // guardian-gated invalidateRequest. The fork setUp intentionally does not
        // grant GUARDIAN to anyone; this test needs it. alice already holds
        // OPERATION_TIMELOCK_ROLE, used for the timelock-gated validateRequest.
        // Resolve the role id and owner BEFORE vm.prank — an external call in the
        // grantRole arguments would otherwise consume the single-shot prank and
        // run grantRole as the test contract (EnumerableRolesUnauthorized).
        bytes32 _guardianRole = roleRegistryInstance.GUARDIAN_ROLE();
        address _rrOwner = roleRegistryInstance.owner();
        vm.prank(_rrOwner);
        roleRegistryInstance.grantRole(_guardianRole, alice);

        // DERIVE the pre-existing pending backlog (M1): sum the requested eETH of
        // every unfinalized request at the pinned block. This is the exact ETH
        // that must be lockable to finalize the whole backlog; we size the actor
        // deposits from it so the finalize can never be starved (no silent skip
        // in _finalizePreExistingPending), regardless of how the backlog drifts
        // if the pinned block is ever changed.
        uint256 backlogTotal = _preExistingBacklogTotal();

        // 5 actors. Each deposit is DERIVED from the backlog: a per-actor share
        // of the backlog plus a fixed working buffer for our own seed/fuzz
        // requests. This guarantees totalValueInLp backs both the backlog
        // finalize and our requests without assuming any particular baseline
        // in-LP size.
        uint256 perActorDeposit = backlogTotal / 5 + 800 ether;
        for (uint256 i = 0; i < 5; i++) {
            address a = address(uint160(uint256(keccak256(abi.encodePacked("i3.solvency.actor.", i)))));
            handlerActors[i] = a;
            vm.deal(a, perActorDeposit + 1 ether);
            vm.prank(a);
            liquidityPoolInstance.deposit{value: perActorDeposit}();
            vm.prank(a);
            eETHInstance.approve(address(liquidityPoolInstance), type(uint256).max);
        }

        // Finalize the PRE-EXISTING mainnet pending range once, mirroring what
        // EtherFiAdmin does in production (finalizeRequests the range, then lock
        // its summed eETH via addEthAmountLockedForWithdrawal). This clears
        // the legacy pending requests that would otherwise sit ahead of our fresh
        // tokenIds in id-order and make finalizing+claiming OUR requests
        // unreachable within a single fuzz sequence. The lock amount is fully
        // backed by the derived deposits above. This is setup, not an
        // assertion-bearing path; the fuzzed finalize op then operates on our own
        // fresh requests. P1's bound is still exercised (and counted) on every
        // fuzzed finalize.
        _finalizePreExistingPending();

        handler = new WithdrawalSolvencyHandler(
            liquidityPoolInstance,
            eETHInstance,
            withdrawRequestNFTInstance,
            address(etherFiAdminInstance),
            handlerActors,
            alice, // guardian (GUARDIAN_ROLE granted above)
            alice  // operating timelock (OPERATION_TIMELOCK_ROLE on the fork)
        );

        targetContract(address(handler));

        // Restrict fuzzing to the action functions. Without this, the engine
        // also targets the handler's public getters/counters, burning call
        // budget on no-ops. probeOverLiquidityLock is included so the I3/P1
        // liquidity guard is positively driven on every run. rebasePositive/
        // rebaseNegative add rate churn (bounded so the share rate stays well
        // above minAmountForShare) and are driven through the real
        // etherFiAdminContract caller that LiquidityPool.rebase requires.
        // doInvalidateValidateProbe drives the S3 invalidate/validate lifecycle.
        bytes4[] memory sel = new bytes4[](7);
        sel[0] = handler.requestWithdraw.selector;
        sel[1] = handler.finalizeRequests.selector;
        sel[2] = handler.claimWithdraw.selector;
        sel[3] = handler.probeOverLiquidityLock.selector;
        sel[4] = handler.rebasePositive.selector;
        sel[5] = handler.rebaseNegative.selector;
        sel[6] = handler.doInvalidateValidateProbe.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));

        // Pre-seed a batch of OUR OWN requests and finalize them, so every fuzz
        // run starts with claimable inventory the `claimWithdraw` op can hit.
        // Foundry resets handler/contract state to this post-setUp snapshot
        // before each run, so this inventory is present at the start of every
        // run — making the request→finalize→claim chain reachable within the
        // run depth (otherwise a claim, which requires three distinct ops in
        // sequence, almost never completes and the non-vacuity gate is unmet).
        //
        // NOTE: these seed requests are created/finalized THROUGH the handler
        // (its real ops, EtherFiAdmin-pranked finalize), so they are
        // indistinguishable from fuzzed ones. The fuzzer still independently
        // exercises requestWithdraw / finalizeRequests / claimWithdraw at
        // runtime (see the call-coverage summary), so non-vacuity reflects
        // genuine fuzz activity, not just this seed.
        for (uint256 i = 0; i < 24; i++) {
            handler.requestWithdraw(i, uint128(uint256(keccak256(abi.encodePacked("seed", i)))));
        }
        handler.finalizeRequests(type(uint256).max);

        // Seed the S3 invalidate/validate probe once so its non-vacuity counters
        // (invalidate/validate round-trip + finalized-invalidate rejection) fire
        // reliably on every run regardless of the fuzzed sequence.
        handler.doInvalidateValidateProbe(0, uint128(uint256(keccak256("seed.probe"))));

        // N1: record the seeded lifecycle baselines AFTER all seeding, so the
        // created/finalized gates require strictly-above-baseline fuzz activity.
        baselineCreated = handler.ghost_requestsCreated();
        baselineFinalized = handler.ghost_requestsFinalized();
    }

    /// @dev DERIVE the summed requested eETH of the pre-existing pending range at
    ///      the pinned block. Used to size actor deposits so the backlog finalize
    ///      is always backed (M1).
    function _preExistingBacklogTotal() internal view returns (uint256 total) {
        uint32 lastFin = withdrawRequestNFTInstance.lastFinalizedRequestId();
        uint32 nextId = withdrawRequestNFTInstance.nextRequestId();
        for (uint32 id = lastFin + 1; id < nextId; id++) {
            total += uint256(withdrawRequestNFTInstance.getRequest(id).amountOfEEth);
        }
    }

    /// @dev Finalize the pre-existing mainnet pending range in bounded batches,
    ///      mirroring EtherFiAdmin._finalizeWithdrawals order EXACTLY:
    ///      `finalizeRequests` first, then `addEthAmountLockedForWithdrawal` for
    ///      the batch's summed eETH (order is inert here since neither call reads
    ///      the other's state, but it stays identical to production and to the
    ///      handler's _finalizeThenLock so all paths agree on the flow). The
    ///      actor deposits in setUp are DERIVED from the backlog total, so every
    ///      batch is backed by construction; if a batch is ever unbacked the
    ///      setUp fails loudly (require) rather than silently skipping it and
    ///      leaving the seeds starved behind an unfinalized backlog (M1).
    function _finalizePreExistingPending() internal {
        uint32 lastFin = withdrawRequestNFTInstance.lastFinalizedRequestId();
        uint32 nextId = withdrawRequestNFTInstance.nextRequestId();
        while (lastFin + 1 < nextId) {
            uint32 remaining = nextId - 1 - lastFin;
            uint32 advance = remaining > 80 ? 80 : remaining;
            uint32 target = lastFin + advance;

            uint256 lockAmount;
            for (uint32 id = lastFin + 1; id <= target; id++) {
                lockAmount += uint256(withdrawRequestNFTInstance.getRequest(id).amountOfEEth);
            }
            require(
                lockAmount <= uint256(liquidityPoolInstance.totalValueInLp()),
                "setUp: derived deposits do not back the pre-existing backlog"
            );

            vm.prank(address(etherFiAdminInstance));
            withdrawRequestNFTInstance.finalizeRequests(uint256(target));
            if (lockAmount > 0) {
                vm.prank(address(etherFiAdminInstance));
                liquidityPoolInstance.addEthAmountLockedForWithdrawal(uint128(lockAmount));
            }
            lastFin = target;
        }
    }

    // =====================================================================
    // I3 — P1: finalize never exceeds liquidity (SC-enforced bound)
    // =====================================================================

    function invariant_i3_finalized_backed_by_liquidity() public view {
        assertFalse(
            handler.ghost_finalizeExceededLiquidity(),
            string.concat(
                "I3/P1: a finalize+lock SUCCEEDED with lockAmount > totalValueInLp - lock=",
                vm.toString(handler.ghost_failLockAmount()),
                " inLp=", vm.toString(handler.ghost_failInLp())
            )
        );
        // Dual direction: the guard must not reject a lock that WAS backed.
        assertFalse(
            handler.ghost_lockRejectedWhileBacked(),
            string.concat(
                "I3/P1: _lockEth rejected a backed lock (lockAmount <= totalValueInLp) - lock=",
                vm.toString(handler.ghost_failLockAmount()),
                " inLp=", vm.toString(handler.ghost_failInLp())
            )
        );
    }

    // =====================================================================
    // I3 — P2: locked obligation within accounted state
    //          (ASSUMPTION-SCOPED: bounded rebases — see file header)
    // =====================================================================

    /// The outstanding finalized-but-unclaimed obligation (the lock) stays a
    /// subset of out-of-LP value under the finalize/claim operations alone. This
    /// bound is NOT unconditional: a large negative rebase drops totalValueOutOfLp
    /// without touching the lock. It holds here because the handler caps negative
    /// rebases (rebaseNegative input filter); the protocol-level defense is
    /// EtherFiAdmin's rebase-APR caps.
    function invariant_i3_locked_within_accounted_state() public view {
        uint256 lock = uint256(withdrawRequestNFTInstance.ethAmountLockedForWithdrawal());
        uint256 outOfLp = uint256(liquidityPoolInstance.totalValueOutOfLp());
        assertLe(lock, outOfLp, "I3/P2: ethAmountLockedForWithdrawal > totalValueOutOfLp");
        assertLe(lock, liquidityPoolInstance.getTotalPooledEther(),
            "I3/P2: ethAmountLockedForWithdrawal > getTotalPooledEther");
    }

    /// Segregated-escrow solvency: WRN's own ETH balance always backs its lock
    /// counter. This is what the claim payout draws on.
    function invariant_i3_escrow_backs_lock() public view {
        assertGe(
            address(withdrawRequestNFTInstance).balance,
            uint256(withdrawRequestNFTInstance.ethAmountLockedForWithdrawal()),
            "I3/P2: WRN balance < ethAmountLockedForWithdrawal"
        );
    }

    // =====================================================================
    // I3 — P3: a finalized request is always claimable (SC-enforced)
    // =====================================================================

    function invariant_i3_finalized_always_claimable() public view {
        assertFalse(
            handler.ghost_finalizedClaimFailed(),
            string.concat(
                "I3/P3: a finalized+valid+owned+in-escrow request reverted on claim - tokenId=",
                vm.toString(handler.ghost_failTokenId()),
                " selector=", vm.toString(uint256(uint32(handler.ghost_failSelector())))
            )
        );
    }

    // =====================================================================
    // I3 — M3: every successful claim moves the exact contract-correct deltas
    // =====================================================================

    /// A successful claimWithdraw must move all three balances by their exact,
    /// independently-recomputed deltas: recipient += amountToWithdraw, lock -=
    /// request.amountOfEEth (the FULL escrowed amount), totalValueOutOfLp -=
    /// (amountToWithdraw + stranded-ETH sweep). Any mismatch means the withdrawal
    /// accounting silently diverged from the value actually paid out.
    function invariant_i3_claim_deltas_exact() public view {
        assertFalse(
            handler.ghost_claimDeltaViolated(),
            string.concat(
                "I3/M3: claim moved a balance by the wrong amount - tokenId=",
                vm.toString(handler.ghost_deltaFailTokenId()),
                " expected=", vm.toString(handler.ghost_deltaFailExpected()),
                " actual=", vm.toString(handler.ghost_deltaFailActual())
            )
        );
    }

    // =====================================================================
    // I3 — S3: invalidate/validate lifecycle behaves as specified
    // =====================================================================

    /// Invalidating a non-finalized request makes it unclaimable (claim reverts
    /// RequestNotValid); validating it restores its validity; and invalidating a
    /// FINALIZED request is always rejected with CannotInvalidateFinalizedRequest.
    function invariant_i3_invalidate_validate_lifecycle() public view {
        assertFalse(
            handler.ghost_invalidateProbeFailed(),
            "I3/S3: invalidate/validate round-trip produced an unexpected outcome"
        );
        assertFalse(
            handler.ghost_finalizedInvalidateAllowed(),
            "I3/S3: invalidateRequest on a finalized request was not rejected"
        );
    }

    // =====================================================================
    // LP TVL decomposition sanity (must always hold)
    // =====================================================================

    function invariant_i3_tvl_decomposition() public view {
        assertEq(
            uint256(liquidityPoolInstance.totalValueInLp())
                + uint256(liquidityPoolInstance.totalValueOutOfLp()),
            liquidityPoolInstance.getTotalPooledEther(),
            "TVL decomposition broken"
        );
    }

    function invariant_i3_lp_solvent_in_lp() public view {
        assertGe(
            address(liquidityPoolInstance).balance,
            uint256(liquidityPoolInstance.totalValueInLp()),
            "LP balance < totalValueInLp"
        );
    }

    // =====================================================================
    // NON-VACUITY GATES (afterInvariant)
    // =====================================================================
    //
    // Proves the fuzzer actually drove the full lifecycle — requests created
    // AND finalized AND claimed — and that P1's bound was positively verified
    // through at least one successful lock. Without these gates, "no violation"
    // could be trivially true because no request was ever finalized/claimed.

    function afterInvariant() public {
        emit log_named_uint("requestsCreated     ", handler.ghost_requestsCreated());
        emit log_named_uint("requestsFinalized   ", handler.ghost_requestsFinalized());
        emit log_named_uint("requestsClaimed     ", handler.ghost_requestsClaimed());
        emit log_named_uint("finalizeBoundChecks ", handler.ghost_finalizeBoundChecks());
        emit log_named_uint("lockBoundEnforced   ", handler.ghost_lockBoundEnforced());
        emit log_named_uint("claimDeltaChecks    ", handler.ghost_claimDeltaChecks());
        emit log_named_uint("invValidateProbes   ", handler.ghost_invalidateValidateProbes());
        emit log_named_uint("finalizedInvRejected", handler.ghost_finalizedInvalidateRejected());
        emit log_named_uint("baselineCreated     ", baselineCreated);
        emit log_named_uint("baselineFinalized   ", baselineFinalized);

        // N1: created/finalized are pre-satisfied by the setUp seed, so require
        // the fuzzer to move STRICTLY ABOVE the recorded baselines (genuine fuzz
        // activity, not just the seed).
        assertGt(handler.ghost_requestsCreated(), baselineCreated, "non-vacuity: fuzzer created no NEW withdraw request beyond the seed");
        assertGt(handler.ghost_requestsFinalized(), baselineFinalized, "non-vacuity: fuzzer finalized no NEW request beyond the seed");
        // Claims are never seeded in setUp, so `> 0` is already fuzz-genuine.
        assertGt(handler.ghost_requestsClaimed(), 0, "non-vacuity: no finalized request was ever claimed");
        assertGt(handler.ghost_finalizeBoundChecks(), 0, "non-vacuity: P1 liquidity bound never exercised");
        // P1 enforcement must be POSITIVELY driven: the liquidity guard rejected
        // at least one genuinely over-backed lock. This is what makes I3/P1 a
        // live assertion rather than dead code.
        assertGt(handler.ghost_lockBoundEnforced(), 0, "non-vacuity: P1 liquidity guard never rejected an over-bound lock");
        // M3: at least one claim's exact three-way deltas were verified (never
        // seeded — a claim only happens under the fuzzer, so this is fuzz-genuine).
        assertGt(handler.ghost_claimDeltaChecks(), 0, "non-vacuity: M3 claim-delta check never exercised");
        // S3: the invalidate/validate lifecycle and finalized-invalidate rejection
        // were driven (seeded once in setUp, so reliably > 0 every run).
        assertGt(handler.ghost_invalidateValidateProbes(), 0, "non-vacuity: S3 invalidate/validate round-trip never completed");
        assertGt(handler.ghost_finalizedInvalidateRejected(), 0, "non-vacuity: S3 finalized-invalidate rejection never exercised");
    }

    // =====================================================================
    // COVERAGE SUMMARY
    // =====================================================================

    function invariant_call_coverage_summary() public {
        emit log_named_uint("req                        ", handler.callCounts("req"));
        emit log_named_uint("req_skipped_funds          ", handler.callCounts("req_skipped_funds"));
        emit log_named_uint("req_revert                 ", handler.callCounts("req_revert"));
        emit log_named_uint("finalize                   ", handler.callCounts("finalize"));
        emit log_named_uint("finalize_skipped_none      ", handler.callCounts("finalize_skipped_none"));
        emit log_named_uint("finalize_skipped_liquidity ", handler.callCounts("finalize_skipped_liquidity"));
        emit log_named_uint("finalize_revert            ", handler.callCounts("finalize_revert"));
        emit log_named_uint("lock_revert_liquidity      ", handler.callCounts("lock_revert_liquidity"));
        emit log_named_uint("lock_revert_migration      ", handler.callCounts("lock_revert_migration"));
        emit log_named_uint("lock_revert_other          ", handler.callCounts("lock_revert_other"));
        emit log_named_uint("probe_rejected_liquidity   ", handler.callCounts("probe_rejected_liquidity"));
        emit log_named_uint("probe_unexpected_ok        ", handler.callCounts("probe_unexpected_ok"));
        emit log_named_uint("claim                      ", handler.callCounts("claim"));
        emit log_named_uint("claim_skipped_empty        ", handler.callCounts("claim_skipped_empty"));
        emit log_named_uint("claim_skipped_unfinalized  ", handler.callCounts("claim_skipped_unfinalized"));
        emit log_named_uint("claim_skipped_claimed      ", handler.callCounts("claim_skipped_claimed"));
        emit log_named_uint("claim_skipped_rate         ", handler.callCounts("claim_skipped_rate"));
        emit log_named_uint("claim_revert               ", handler.callCounts("claim_revert"));
        emit log_named_uint("rebase_pos                 ", handler.callCounts("rebase_pos"));
        emit log_named_uint("rebase_neg                 ", handler.callCounts("rebase_neg"));
        emit log_named_uint("rebase_neg_skipped         ", handler.callCounts("rebase_neg_skipped"));
        emit log_named_uint("invalidate_ok              ", handler.callCounts("invalidate_ok"));
        emit log_named_uint("invalidated_claim_rejected ", handler.callCounts("invalidated_claim_rejected"));
        emit log_named_uint("validate_ok                ", handler.callCounts("validate_ok"));
        emit log_named_uint("revalidated_claim_rejected ", handler.callCounts("revalidated_claim_rejected"));
        emit log_named_uint("invalidate_finalized_reject", handler.callCounts("invalidate_finalized_rejected"));
    }
}
