// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin-upgradeable/contracts/token/ERC20/IERC20Upgradeable.sol";
import "./ILiquidityPool.sol";
import "./IeETH.sol";

interface IWeETH is IERC20Upgradeable {
    // STATE VARIABLES
    function eETH() external view returns (IeETH);
    function liquidityPool() external view returns (ILiquidityPool);
    function whitelistedSpender(address spender) external view returns (bool);
    function blacklistedRecipient(address recipient) external view returns (bool);

    // STATE-CHANGING FUNCTIONS
    function initialize(address _liquidityPool, address _eETH) external;
    function wrap(uint256 _eETHAmount) external returns (uint256);
    function wrapWithPermit(uint256 _eETHAmount, ILiquidityPool.PermitInput calldata _permit) external returns (uint256);
    function unwrap(uint256 _weETHAmount) external returns (uint256);
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    function setWhitelistedSpender(address[] calldata _spenders, bool _isWhitelisted) external;
    function setBlacklistedRecipient(address[] calldata _recipients, bool _isBlacklisted) external;

    // GETTER FUNCTIONS
    function getWeETHByeETH(uint256 _eETHAmount) external view returns (uint256);
    function getEETHByWeETH(uint256 _weETHAmount) external view returns (uint256);
    function getRate() external view returns (uint256);
    function getImplementation() external view returns (address);
}
