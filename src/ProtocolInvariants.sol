// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";

import "./interfaces/IeETH.sol";
import "./interfaces/IProtocolInvariants.sol";
import "./utils/RolesLibrary.sol";

/// @title  ProtocolInvariants
/// @notice On-chain conservation checks for ether.fi tokens. Currently asserts
///         Invariant 1: weETH is at-least-fully-backed by eETH shares held in
///         the weETH proxy. Designed to run on every state-changing call on
///         weETH that could affect supply.
/// @dev
///   THREE-MODE OPERATION:
///     - DISABLED: every check is a no-op. Emergency kill-switch in case the
///       invariant itself has a bug that's blocking legitimate traffic. Must be
///       toggleable by Operating Multisig (single-key risk vs full-protocol-brick).
///     - OBSERVE:  default. Violations emit `InvariantViolated` and DO NOT
///       revert. Hypernative + ops monitor the event and decide on response.
///       Used during initial rollout to validate the invariant formulas
///       against real mainnet activity before they can revert anything.
///     - ENFORCE:  violations emit the event AND revert. Hard on-chain stop
///       for unbacked-mint exploits.
///
///   INVARIANT 2 NOTE (eETH share consistency):
///     The original RFC proposed a second invariant `eETH.totalShares == LP.totalShares`.
///     During implementation we confirmed LP does not maintain a SEPARATE share
///     counter — every reference in `LiquidityPool.sol` reads `eETH.totalShares()`
///     directly. So that comparison is tautological and provides no defense.
///     A meaningful eETH-side check would be a per-transaction delta invariant
///     INSIDE LP (snapshot ETH balance + totalShares pre-call, assert consistent
///     deltas post-call). That's structurally a different change and is out of
///     scope for the first iteration. See `docs/rfc-protocol-invariants.md`.
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

    Mode public mode;

    /// @notice Initialize the invariants contract.
    /// @param _initialMode Starting mode; should be OBSERVE for new deployments.
    function initialize(Mode _initialMode) external initializer {
        __UUPSUpgradeable_init();
        mode = _initialMode;
        emit ModeChanged(Mode.DISABLED, _initialMode);
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

    /// @notice Switch operational mode. Operating Multisig only.
    /// @dev Multisig is the right gate here:
    ///        - DISABLE during incident if invariant is misfiring (urgent).
    ///        - OBSERVE -> ENFORCE promotion (deliberate, after monitoring).
    ///        - ENFORCE -> OBSERVE/DISABLE rollback (urgent, if false positives).
    ///      Single-key Guardian is too low a bar to flip the kill switch given
    ///      the blast radius. Timelock is too slow for an active incident.
    function setMode(Mode _newMode) external onlyOperatingMultisig {
        Mode old = mode;
        mode = _newMode;
        emit ModeChanged(old, _newMode);
    }

    //--------------------------------------------------------------------------
    //                                  Checks
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
    ///
    ///      VIEW SEMANTICS: in DISABLED mode this is a no-op view. In OBSERVE
    ///      mode it emits on violation and returns. In ENFORCE mode it emits
    ///      AND reverts. The emit-before-revert order is intentional — even
    ///      when reverting, the event helps post-mortem reconstruction by
    ///      surfacing in trace logs.
    function check_weETH_backed() external {
        if (mode == Mode.DISABLED) return;

        uint256 supply = IERC20Like(weETH).totalSupply();
        uint256 proxyShares = eETH.shares(weETH);

        if (supply > proxyShares) {
            emit InvariantViolated("weETH-underbacked", supply, proxyShares);
            if (mode == Mode.ENFORCE) revert WeETHUnderbacked(supply, proxyShares);
        }
    }

    //--------------------------------------------------------------------------
    //                                  Views
    //--------------------------------------------------------------------------

    /// @notice Read-only check, never reverts, never emits. For dashboards and
    ///         off-chain monitoring that wants to know "would the invariant
    ///         have tripped right now?" without burning gas on an event.
    function weETHBackingDelta() external view returns (uint256 supply, uint256 proxyShares, bool underbacked) {
        supply = IERC20Like(weETH).totalSupply();
        proxyShares = eETH.shares(weETH);
        underbacked = supply > proxyShares;
    }

    //--------------------------------------------------------------------------
    //                Invariant: eETH exchange-rate monotonicity
    //--------------------------------------------------------------------------

    /// @notice Invariant: in every share-changing call, the eETH exchange rate
    ///         must not decrease.
    /// @dev    RATIONALE: a healthy deposit pulls ETH in and mints shares in
    ///         proportion — the rate (totalPooledEther / totalShares) stays
    ///         constant. A healthy withdrawal burns shares and sends ETH out
    ///         in proportion — same. Fee paths keep ETH in the pool relative
    ///         to shares burned, which makes the rate go UP. Rebases change
    ///         totalPooledEther without touching shares — exempted via the
    ///         S0 == S1 guard. The ONE scenario where the rate goes DOWN and
    ///         shares change is the threat: shares were minted without an
    ///         equivalent ETH inflow (LP compromise, exploited path, missing
    ///         accounting). The invariant catches that with the cross-multiplied
    ///         form `P1 * S0 >= P0 * S1` (rate_after >= rate_before).
    ///
    ///         CALL PATTERN: LP wraps a `_;` modifier around share-changing
    ///         functions, snapshotting P0/S0 before and passing P0/S0/P1/S1
    ///         after. The check happens here so the policy (mode toggle,
    ///         emit, revert) lives in one place, but the snapshot has to
    ///         happen in the caller's stack frame — there's no on-chain
    ///         primitive that lets us bracket a foreign function.
    ///
    ///         GATING: only `liquidityPool` may call this. Otherwise an
    ///         attacker could call with fake P/S values and either (a) spam
    ///         false `InvariantViolated` events to trip Hypernative auto-pause
    ///         in OBSERVE mode, or (b) self-revert in ENFORCE mode (harmless
    ///         but noisy). LP-only gating keeps the event stream high-signal.
    function check_eETHRateMonotonic(uint256 P0, uint256 S0, uint256 P1, uint256 S1) external onlyLP {
        if (mode == Mode.DISABLED) return;

        // Skip cases where the check is meaningless or doesn't apply:
        //   - Bootstrap: no shares before or after (rate undefined).
        //   - Share-neutral: rebase / oracle adjustment — totalShares
        //     unchanged. Those legitimately move the rate (intentional).
        if (S0 == 0 || S1 == 0 || S0 == S1) return;

        // Cross-multiplied form of: P1/S1 >= P0/S0
        //   integer-exact, division-free, no rounding tolerance needed.
        // Practical overflow bound: P, S each fit in uint128 in any plausible
        // protocol state (total ETH supply ~1.2e26 wei, shares similar);
        // P*S ≈ 1.4e52 ≪ uint256 max (~1.16e77). Safe by inspection.
        uint256 lhs = P1 * S0;
        uint256 rhs = P0 * S1;
        if (lhs < rhs) {
            emit InvariantViolated("eETH-rate-deflation", lhs, rhs);
            if (mode == Mode.ENFORCE) revert EETHRateDeflation(P0, S0, P1, S1);
        }
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
