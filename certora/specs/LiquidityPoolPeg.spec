/*
 * Certora CVL spec for ether.fi LiquidityPool — peg/solvency invariants I7, I8.
 * (I9, the pooled-ether decomposition lemma, lives in LiquidityPoolDecomposition.spec;
 *  it is a tautology and runs separately with `rule_sanity: none`.)
 *
 * Target: the SECURITY-UPGRADE LiquidityPool (carries `nonDecreasingRate` +
 * `_checkTotalValueInLp`). These properties hold only OPERATIONALLY on live
 * mainnet today; the upgrade codifies them. CVL proves them for ALL inputs
 * (vs the stateful fuzzer, which samples).
 *
 *   I7 — the `nonDecreasingRate` guard is correctly wired: on every entry point
 *        that carries the modifier, the post-rate is >= the pre-rate. Rate = P/S
 *        where P = getTotalPooledEther() = totalValueInLp + totalValueOutOfLp,
 *        S = eETH.totalShares(). Checked cross-multiplied (no division):
 *        P1 * S0 >= P0 * S1   (the `_checkRateNonDec` predicate). This is a
 *        regression check on the wiring, not a proof that share math can never
 *        dilute holders — the two by-design unguarded rate-moving paths
 *        (withdraw(uint256,uint256), rebase) are intentionally out of scope.
 *
 *   I8 — LP-buffer solvency:  totalValueInLp <= address(this).balance
 *        Enforced by `_checkTotalValueInLp()` (line 668) on every write path.
 *
 * NOTE: rate = P/S is NOT a stored variable; it is derived from two contracts
 * (LiquidityPool P, EETH S). We capture P and S before/after so the prover
 * reasons over the pair.
 */

using EETH as eeth;

methods {
    function totalValueInLp() external returns (uint128) envfree;
    function totalValueOutOfLp() external returns (uint128) envfree;
    function getTotalPooledEther() external returns (uint256) envfree;
    function eeth.totalShares() external returns (uint256) envfree;

    // Resolve cross-contract totalShares() reads through the linked EETH.
    function _.totalShares() external => DISPATCHER(true);
}

// ----------------------------------------------------------------------------
// I8 — LP-buffer solvency, proved in the HONEST, provable form.
//
// `totalValueInLp <= address(this).balance` CANNOT be stated as a pure CVL
// `invariant`: an invariant must survive *every* method, including ones whose
// bodies make external calls to UNLINKED contracts (the eETH rate-limiter, the
// WithdrawRequestNFT, PriorityWithdrawalQueue, StakingManager, the arbitrary
// `_recipient.call` inside `_sendFund`). For those calls the Prover must HAVOC
// `address(this).balance`, which can drop it below `totalValueInLp` — a sound
// over-approximation, not a real reachable state. (That is exactly the set of
// methods the first run flagged: requestWithdraw*, withdraw(uint256,uint256),
// burnEEthShares*, upgradeToAndCall, and every EETH.* method.)
//
// The security property `_checkTotalValueInLp` actually delivers is:
//   "any write path that ENDS in `_checkTotalValueInLp()` leaves the pool
//    solvent, because the call reverts otherwise."
// In every guarded path the check is the LAST state-relevant statement (it runs
// AFTER the ETH send in `_sendFund` / `_lockEth` / `_accountForEthSentOut`), so
// it constrains the post-havoc balance. We therefore prove, per guarded method:
//   method completes without reverting  =>  totalValueInLp <= balance.
//
// Guarded write paths (each UNCONDITIONALLY reaches `_checkTotalValueInLp`,
// call sites at lines 175/189/274/594/651/662):
//   deposit() / deposit(address) / deposit(address,address) /
//   depositToRecipient                    -> _deposit                -> 594
//   withdraw(address,uint256)                                        -> 274
//   addEthAmountLockedForWithdrawal / transferLockedEthForPriority
//                                          -> _lockEth               -> 651
//   batchCreateBeaconValidators / confirmAndFundBeaconValidators
//                                          -> _accountForEthSentOut  -> 662
//   initializeOnUpgradeV2()                                          -> 175
//   receive()                                                        -> 189
// `receive()` IS covered: CVL exposes the receive/fallback dispatch as the
// parametric method with `f.isFallback == true`, so we include it in the filter
// (rather than by selector, which a fallback has no distinct value for).
// NOTE ON SCOPE: rebase() also transitively reaches the check (via
// depositToRecipient) but only WHEN _protocolFees > 0, so it does not
// unconditionally end in the check and is intentionally excluded — including it
// would let the prover start from an already-insolvent havoc state that rebase
// leaves untouched, a spurious counterexample.
// ----------------------------------------------------------------------------
rule I8_lp_buffer_solvency_guarded(method f, env e, calldataarg args)
    filtered {
        f -> f.isFallback
          || f.selector == sig:deposit().selector
          || f.selector == sig:deposit(address).selector
          || f.selector == sig:deposit(address,address).selector
          || f.selector == sig:depositToRecipient(address,uint256,address).selector
          || f.selector == sig:withdraw(address,uint256).selector
          || f.selector == sig:addEthAmountLockedForWithdrawal(uint128).selector
          || f.selector == sig:transferLockedEthForPriority(uint128).selector
          || f.selector == sig:batchCreateBeaconValidators(IStakingManager.DepositData[],uint256[],address).selector
          || f.selector == sig:confirmAndFundBeaconValidators(IStakingManager.DepositData[],uint256).selector
          || f.selector == sig:initializeOnUpgradeV2().selector
    }
{
    f@withrevert(e, args);
    bool reverted = lastReverted;

    // If the method completed, `_checkTotalValueInLp()` did not revert, so the
    // solvency relation held at the (final) check and nothing changes after it.
    assert !reverted =>
        to_mathint(totalValueInLp()) <= to_mathint(nativeBalances[currentContract]),
        "I8: LP buffer insolvent after a guarded write path (totalValueInLp > balance)";
}

// ----------------------------------------------------------------------------
// I7 — the `nonDecreasingRate` guard is correctly wired on its entry points.
//
// This is regression protection for the modifier's wiring, NOT a proof that
// share math can never dilute holders: it asserts that on exactly the methods
// carrying `nonDecreasingRate`, the rate P/S does not decrease across the call.
// The two rate-moving paths that are unguarded BY DESIGN — withdraw(uint256,
// uint256) (frozen-rate finalized claim, bounded by that function's three-guard
// design) and rebase() (oracle path, bounded by EtherFiAdmin's APR cap) — are
// out of scope here on purpose. The filter below must stay in exact sync with
// the modifier sites in LiquidityPool.sol: withdraw(address,uint256):261,
// burnEEthShares:504, burnEEthSharesForNonETHWithdrawal:515, and _deposit:585
// (reached by the four deposit entry points).
//
// Expressed cross-multiplied to avoid division and rounding:
//     P_after * S_before >= P_before * S_after
// (bootstrap-exempt when either S is zero — no rate to compare, matching
//  `_checkRateNonDec`'s `S0 != 0 && S1 != 0` guard).
// ----------------------------------------------------------------------------
rule I7_rate_non_decreasing_on_guarded_methods(method f, env e, calldataarg args)
    filtered {
        f -> f.selector == sig:withdraw(address,uint256).selector
          || f.selector == sig:burnEEthShares(uint256).selector
          || f.selector == sig:burnEEthSharesForNonETHWithdrawal(uint256,uint256).selector
          || f.selector == sig:deposit().selector
          || f.selector == sig:deposit(address).selector
          || f.selector == sig:deposit(address,address).selector
          || f.selector == sig:depositToRecipient(address,uint256,address).selector
    }
{
    uint256 P0 = getTotalPooledEther();
    uint256 S0 = eeth.totalShares();

    f(e, args);

    uint256 P1 = getTotalPooledEther();
    uint256 S1 = eeth.totalShares();

    // bootstrap exemption (mirrors _checkRateNonDec)
    assert (S0 != 0 && S1 != 0) =>
        to_mathint(P1) * to_mathint(S0) >= to_mathint(P0) * to_mathint(S1),
        "I7: exchange rate decreased across a nonDecreasingRate-guarded call";
}
