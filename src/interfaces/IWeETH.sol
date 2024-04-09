// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";


interface IWeETH is IERC20 {
    function wrap(uint256 _eETHAmount) public returns (uint256);
    function wrapWithPermit(uint256 _eETHAmount, ILiquidityPool.PermitInput calldata _permit) external returns (uint256);
    function unwrap(uint256 _weETHAmount) external returns (uint256);
}
