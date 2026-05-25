// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IProtocolInvariants {
    //--------------------------------------------------------------------------
    //                                  Events
    //--------------------------------------------------------------------------
    event EnabledChanged(bool oldEnabled, bool newEnabled);

    //--------------------------------------------------------------------------
    //                                  Errors
    //--------------------------------------------------------------------------
    error AddressZero();
    error WeETHUnderbacked(uint256 weETHSupply, uint256 proxyShares);
    error EETHRateDeflation(uint256 P0, uint256 S0, uint256 P1, uint256 S1);
    error OnlyLiquidityPool();

    //--------------------------------------------------------------------------
    //                                  Functions
    //--------------------------------------------------------------------------
    function check_weETH_backed() external view;
    function check_eETHRateMonotonic(uint256 P0, uint256 S0, uint256 P1, uint256 S1) external view;
    function weETHBackingDelta() external view returns (uint256 supply, uint256 proxyShares, bool underbacked);
    function setEnabled(bool enabled) external;
    function enabled() external view returns (bool);
}
