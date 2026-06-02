// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@etherfi/deposits/interfaces/ILiquifier.sol";

interface IDepositAdapter {
    struct ConstructorAddresses {
        address liquidityPool;
        address liquifier;
        address weETH;
        address eETH;
        address wETH;
        address stETH;
        address wstETH;
        address roleRegistry;
        address blacklister;
    }

    enum SourceOfFunds {
        ETH,
        WETH,
        STETH,
        WSTETH
    }

    function depositETHForWeETH(address _referral) external payable returns (uint256);
    function depositWETHForWeETH(uint256 _amount, address _referral) external returns (uint256);
    function depositStETHForWeETHWithPermit(uint256 _amount, address _referral, ILiquifier.PermitInput calldata _permit) external returns (uint256);
    function depositWstETHForWeETHWithPermit(uint256 _amount, address _referral, ILiquifier.PermitInput calldata _permit) external returns (uint256);
    function sweepDust(address _token, address _to) external;
}