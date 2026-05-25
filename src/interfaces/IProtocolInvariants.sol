// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IProtocolInvariants {
    /// @dev Three-mode operation; see ProtocolInvariants.sol for full rationale.
    ///        DISABLED - no-op kill switch
    ///        OBSERVE  - emit on violation, do not revert (rollout default)
    ///        ENFORCE  - emit AND revert on violation (hard on-chain stop)
    enum Mode { DISABLED, OBSERVE, ENFORCE }

    //--------------------------------------------------------------------------
    //                                  Events
    //--------------------------------------------------------------------------
    /// @dev Emitted on every violation, regardless of mode (except DISABLED).
    ///      `name` identifies which invariant tripped; `lhs`/`rhs` are the
    ///      two values that failed the comparison, for post-mortem clarity.
    event InvariantViolated(string name, uint256 lhs, uint256 rhs);
    event ModeChanged(Mode oldMode, Mode newMode);

    //--------------------------------------------------------------------------
    //                                  Errors
    //--------------------------------------------------------------------------
    error AddressZero();
    error WeETHUnderbacked(uint256 weETHSupply, uint256 proxyShares);

    //--------------------------------------------------------------------------
    //                                  Functions
    //--------------------------------------------------------------------------
    function check_weETH_backed() external;
    function weETHBackingDelta() external view returns (uint256 supply, uint256 proxyShares, bool underbacked);
    function setMode(Mode newMode) external;
    function mode() external view returns (Mode);
}
