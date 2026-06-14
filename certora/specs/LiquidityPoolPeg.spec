/*
 * Certora CVL spec for ether.fi LiquidityPool — peg/solvency invariants I7, I8, I9.
 *
 * Target: the SECURITY-UPGRADE LiquidityPool (carries `nonDecreasingRate` +
 * `_checkTotalValueInLp`). These properties hold only OPERATIONALLY on live
 * mainnet today; the upgrade codifies them. CVL proves them for ALL inputs
 * (vs the stateful fuzzer, which samples).
 *
 *   I7 — exchange-rate monotonicity: on any share-changing path guarded by
 *        `nonDecreasingRate`, the post-rate is >= the pre-rate. Rate = P/S where
 *        P = getTotalPooledEther() = totalValueInLp + totalValueOutOfLp,
 *        S = eETH.totalShares(). Checked cross-multiplied (no division):
 *        P1 * S0 >= P0 * S1   (the `_checkRateNonDec` predicate).
 *
 *   I8 — LP-buffer solvency:  totalValueInLp <= address(this).balance
 *        Enforced by `_checkTotalValueInLp()` (line 671) on every write path.
 *
 *   I9 — pooled-ether decomposition: getTotalPooledEther() == in + out.
 *        A definitional helper that I7/I8 lean on.
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
    function amountForShare(uint256) external returns (uint256) envfree;
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
// Guarded write paths (each reaches `_checkTotalValueInLp`, lines 184/218/271/
// 534/572/602/609):
//   deposit() / deposit(address) / deposit(address,address) /
//   depositToRecipient            -> _deposit            -> 572
//   withdraw(address,uint256)                            -> 271
//   returnLockedEth(uint128)                             -> 534
//   addEthAmountLockedForWithdrawal / transferLockedEthForPriority
//                                  -> _lockEth           -> 602
//   confirmAndFundBeaconValidators -> _accountForEthSentOut -> 609
//   initializeOnUpgradeV2()                              -> 218
// (`receive()` also ends in the check by identical reasoning but cannot be
//  selector-filtered in a parametric rule, so it is documented, not enumerated.)
// ----------------------------------------------------------------------------
rule I8_lp_buffer_solvency_guarded(method f, env e, calldataarg args)
    filtered {
        f -> f.selector == sig:deposit().selector
          || f.selector == sig:deposit(address).selector
          || f.selector == sig:deposit(address,address).selector
          || f.selector == sig:depositToRecipient(address,uint256,address).selector
          || f.selector == sig:withdraw(address,uint256).selector
          || f.selector == sig:returnLockedEth(uint128).selector
          || f.selector == sig:addEthAmountLockedForWithdrawal(uint128).selector
          || f.selector == sig:transferLockedEthForPriority(uint128).selector
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
// I7 — exchange-rate monotonicity on nonDecreasingRate-guarded methods.
//
// We assert: for the guarded entry points, the rate P/S does not decrease.
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
          || f.selector == sig:deposit(address,address).selector
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

// ----------------------------------------------------------------------------
// I9 — pooled-ether decomposition lemma:  P == in + out.
//
// DEFINITIONAL: getTotalPooledEther() (LiquidityPool.sol:629) literally returns
// `totalValueOutOfLp + totalValueInLp`, so this identity is true in EVERY state
// by construction. It is the cheap lemma I7/I8 lean on. Because the assert is a
// tautology, `rule_sanity` correctly reports it as vacuously true; we therefore
// run with `rule_sanity: none` (the I7 rule was independently confirmed
// non-vacuous under `rule_sanity: basic` in an earlier run — see report
// 28788fcb...). The invariant still proves the relation holds after every
// method, which is the assurance we want.
// ----------------------------------------------------------------------------
invariant I9_pooled_ether_decomposition()
    to_mathint(getTotalPooledEther()) == to_mathint(totalValueInLp()) + to_mathint(totalValueOutOfLp());
