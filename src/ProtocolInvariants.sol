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

    /// @dev Tokens this contract observes. Immutable so the wiring is obvious
    ///      on-chain and can't be silently re-pointed by a governance call. To
    ///      change the addresses, deploy a new ProtocolInvariants and re-wire
    ///      the WeETH/EETH constructors.
    IeETH   public immutable eETH;
    address public immutable weETH;

    Mode public mode;

    /// @notice Initialize the invariants contract.
    /// @param _initialMode Starting mode; should be OBSERVE for new deployments.
    function initialize(Mode _initialMode) external initializer {
        __UUPSUpgradeable_init();
        mode = _initialMode;
        emit ModeChanged(Mode.DISABLED, _initialMode);
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _roleRegistry, address _eETH, address _weETH) RolesLibrary(_roleRegistry) {
        if (_eETH == address(0) || _weETH == address(0)) revert AddressZero();
        eETH = IeETH(_eETH);
        weETH = _weETH;
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
}

/// @dev Minimal IERC20 surface for `totalSupply()` — avoids pulling in OZ's
///      full IERC20 just for one method. weETH is not the only ERC20 we may
///      observe in future invariants.
interface IERC20Like {
    function totalSupply() external view returns (uint256);
}
