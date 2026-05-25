// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";

import "./interfaces/IeETH.sol";
import "./interfaces/IProtocolInvariants.sol";
import "./utils/RolesLibrary.sol";

/// @title  ProtocolInvariants
/// @notice On-chain conservation checks for ether.fi tokens. Asserts two
///         invariants on every relevant call path:
///
///         1. weETH supply is fully backed by eETH shares held in the proxy.
///         2. The eETH exchange rate (totalPooledEther / totalShares) does not
///            decrease across any share-changing call on LP.
///
///         Both invariants revert on violation. There is no observe-only mode —
///         deployment lands in production with checks live. An OperatingMultisig
///         kill switch (`setEnabled(false)`) exists ONLY for the case where the
///         invariant code itself has a bug that's blocking legitimate traffic;
///         normal operation never touches it.
contract ProtocolInvariants is IProtocolInvariants, Initializable, UUPSUpgradeable, RolesLibrary {

    /// @dev Tokens and LP this contract observes. Immutable so the wiring is
    ///      obvious on-chain and can't be silently re-pointed by a governance
    ///      call. To change the addresses, deploy a new ProtocolInvariants
    ///      and re-wire the dependents.
    ///
    ///      `liquidityPool` is the only authorized caller of the eETH
    ///      rate-monotonicity check — see `onlyLP` modifier and
    ///      `check_eETHRateMonotonic` rationale below. weETH-side check is
    ///      open (callable by anyone) because its values are not
    ///      caller-supplied (read straight from on-chain state).
    IeETH   public immutable eETH;
    address public immutable weETH;
    address public immutable liquidityPool;

    /// @notice Whether invariant checks are live. True at deploy; the only
    ///         flip path is the Multisig-gated `setEnabled` for emergencies.
    bool public enabled;

    function initialize() external initializer {
        __UUPSUpgradeable_init();
        enabled = true;
        emit EnabledChanged(false, true);
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _roleRegistry, address _eETH, address _weETH, address _liquidityPool)
        RolesLibrary(_roleRegistry)
    {
        if (_eETH == address(0) || _weETH == address(0) || _liquidityPool == address(0)) revert AddressZero();
        eETH = IeETH(_eETH);
        weETH = _weETH;
        liquidityPool = _liquidityPool;
        _disableInitializers();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyUpgradeTimelock {}

    //--------------------------------------------------------------------------
    //                                  Admin
    //--------------------------------------------------------------------------

    /// @notice Emergency kill switch. Disables both invariant checks.
    /// @dev Gated to Operating Multisig: single-key Guardian is too low a bar
    ///      for a switch with this blast radius, and a timelock is too slow
    ///      for the only scenario where you'd actually use this — a bug in
    ///      the invariant itself causing false reverts mid-incident. Normal
    ///      operation never flips this.
    function setEnabled(bool _enabled) external onlyOperatingMultisig {
        bool old = enabled;
        enabled = _enabled;
        emit EnabledChanged(old, _enabled);
    }

    //--------------------------------------------------------------------------
    //                Invariant 1: weETH supply backed by eETH shares
    //--------------------------------------------------------------------------

    /// @notice Invariant 1 — weETH is at-least-fully-backed by eETH shares held
    ///         in the weETH proxy.
    /// @dev RATIONALE: every `wrap(X)` mints `sharesForAmount(X)` weETH AND
    ///      transfers `sharesForAmount(X)` eETH shares to the weETH proxy
    ///      (eETH is a rebase token; transferring `X` eETH moves
    ///      `sharesForAmount(X)` shares). Both sides increment by the same
    ///      number. `unwrap` is the symmetric decrement. So the invariant
    ///      `weETH.totalSupply <= eETH.shares(weETHProxy)` is preserved by
    ///      every well-formed mint/burn. Anything that mints weETH without an
    ///      eETH inflow — bridge compromise, exploited mint path, future
    ///      authority that forgets to wire in eETH backing — breaks it.
    ///
    ///      The `<=` form (rather than `==`) is deliberate: if someone calls
    ///      `eETH.transfer(weETHProxy, X)` directly (accidental airdrop), the
    ///      proxy ends up over-collateralized. That's safe for weETH holders.
    ///      Strict equality would false-positive on benign donations.
    function check_weETH_backed() external view {
        if (!enabled) return;

        uint256 supply = IERC20Like(weETH).totalSupply();
        uint256 proxyShares = eETH.shares(weETH);

        if (supply > proxyShares) revert WeETHUnderbacked(supply, proxyShares);
    }

    //--------------------------------------------------------------------------
    //                Invariant 2: eETH exchange-rate monotonicity
    //--------------------------------------------------------------------------

    /// @notice Invariant 2 — across the wrapped LP call, the eETH exchange
    ///         rate (`totalPooledEther / totalShares`) does not decrease.
    /// @dev    SCOPE: applies to every share-changing LP entry point where
    ///         the rate is *supposed* to be preserved or increase by
    ///         construction. The intended on-chain guarantee is:
    ///
    ///             "The eETH exchange rate can only decrease via:
    ///                 (a) `rebase()`     (oracle path, bounded by
    ///                                     EtherFiAdmin._validateRebaseApr's
    ///                                     APR cap), OR
    ///                 (b) `withdraw(uint256, uint256)` (frozen-rate
    ///                                     finalized claim, bounded by the
    ///                                     oracle-finalized `_rate`)."
    ///
    ///         Both (a) and (b) are intentional rate-changing paths and
    ///         do NOT carry the `nonDecreasingRate` modifier in LP. Every
    ///         other share-changing path does — mints (3 deposit overloads),
    ///         the live-rate withdraw, and the ERM/WRN/PQ burn primitives
    ///         (`burnEEthShares`, `burnEEthSharesForNonETHWithdrawal`). On
    ///         those paths the math is either rate-preserving (proportional
    ///         mint/burn with rounding favoring the protocol) or rate-up
    ///         (burn-without-P-side-decrement), so this check fires only
    ///         if a bug or exploit produces an unintended rate drop.
    ///
    ///         RATIONALE: rebase is no longer the ONLY rate-changing path
    ///         (claim-time burns also nudge it up), but it should be the
    ///         only path that can move it DOWN outside of the well-defined
    ///         frozen-rate withdraw exemption. This invariant enforces that
    ///         on-chain.
    ///
    ///         CALL PATTERN: LP wraps a `_;` modifier around the protected
    ///         entry points, snapshotting P0/S0 before and passing
    ///         P0/S0/P1/S1 after. The check happens here so the kill-switch
    ///         policy lives in one place, but the snapshot has to happen in
    ///         the caller's stack frame — there's no on-chain primitive
    ///         that lets us bracket a foreign function.
    ///
    ///         GATING: only `liquidityPool` may call this. An attacker could
    ///         otherwise self-revert with crafted values — harmless to the
    ///         protocol, but pollutes Hypernative's view via spurious revert
    ///         traces. LP-only gating keeps the trace signal clean.
    function check_eETHRateMonotonic(uint256 P0, uint256 S0, uint256 P1, uint256 S1) external view onlyLP {
        if (!enabled) return;

        // Bootstrap exempt: no previous rate to compare against.
        if (S0 == 0 || S1 == 0) return;

        // Cross-multiplied form of: P1/S1 >= P0/S0
        //   integer-exact, division-free, no rounding tolerance needed.
        // Works for mints (S1 > S0), live-rate burns (S1 < S0), and
        // share-only burns (S1 < S0, P1 == P0 — rate goes up).
        // Practical overflow bound: P, S each fit in uint128 in any plausible
        // protocol state (total ETH supply ~1.2e26 wei, shares similar);
        // P*S ≈ 1.4e52 ≪ uint256 max (~1.16e77). Safe by inspection.
        if (P1 * S0 < P0 * S1) revert EETHRateDeflation(P0, S0, P1, S1);
    }

    //--------------------------------------------------------------------------
    //                                  Views
    //--------------------------------------------------------------------------

    /// @notice Read-only check, never reverts. For dashboards and off-chain
    ///         monitoring that wants to know "would the invariant have tripped
    ///         right now?".
    function weETHBackingDelta() external view returns (uint256 supply, uint256 proxyShares, bool underbacked) {
        supply = IERC20Like(weETH).totalSupply();
        proxyShares = eETH.shares(weETH);
        underbacked = supply > proxyShares;
    }

    //--------------------------------------------------------------------------
    //                                  Modifiers
    //--------------------------------------------------------------------------
    modifier onlyLP() {
        if (msg.sender != liquidityPool) revert OnlyLiquidityPool();
        _;
    }
}

/// @dev Minimal IERC20 surface for `totalSupply()` — avoids pulling in OZ's
///      full IERC20 just for one method. weETH is not the only ERC20 we may
///      observe in future invariants.
interface IERC20Like {
    function totalSupply() external view returns (uint256);
}
