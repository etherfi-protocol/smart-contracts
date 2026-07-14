/*
 * Certora CVL spec for ether.fi LiquidityPool — invariant I9 (pooled-ether decomposition).
 *
 * Split out of LiquidityPoolPeg.spec: I9 is a definitional tautology, so it is
 * vacuously true and cannot survive `rule_sanity: basic`. It runs here on its own
 * with `rule_sanity: none` (see LiquidityPoolDecomposition.conf) so that the peg
 * spec can keep `rule_sanity: basic` for its genuinely non-vacuous rules I7/I8.
 *
 *   I9 — pooled-ether decomposition: getTotalPooledEther() == in + out.
 *        A definitional helper that I7/I8 lean on.
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
// I9 — pooled-ether decomposition lemma:  P == in + out.
//
// DEFINITIONAL: getTotalPooledEther() (LiquidityPool.sol:729) literally returns
// `totalValueOutOfLp + totalValueInLp`, so this identity is true in EVERY state
// by construction. It is the cheap lemma I7/I8 lean on. Because the assert is a
// tautology, `rule_sanity` would (correctly) report it as vacuously true — that
// is exactly why this spec runs with `rule_sanity: none` in its own conf, apart
// from LiquidityPoolPeg.spec which keeps `rule_sanity: basic`. The invariant
// still proves the relation holds after every method, which is the assurance we
// want.
// ----------------------------------------------------------------------------
invariant I9_pooled_ether_decomposition()
    to_mathint(getTotalPooledEther()) == to_mathint(totalValueInLp()) + to_mathint(totalValueOutOfLp());
