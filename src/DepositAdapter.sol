// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";

import "./interfaces/ILiquidityPool.sol";
import "./interfaces/IeETH.sol";
import "./interfaces/IWeETH.sol";

contract DepositAdapter is UUPSUpgradeable, OwnableUpgradeable {


    ILiquidityPool public immutable liquidityPool;
    IeETH public immutable eETH;
    IWeETH public immutable weETH;


    constructor(address _liquidityPool, address _weETH, address _eETH) {
        liquidityPool = ILiquidityPool(_liquidityPool);
        eETH = IeETH(_eETH);
        weETH = IWeETH(_weETH);
        _disableInitializers();
    }

    function initialize() initializer external {
        __Ownable_init();
        __UUPSUpgradeable_init();
    }
    
    function depositETHForWeETH() external payable {
        _depositETHForWeETH(address(0));
    }

    function depositETHForWeETH(address _referral) external payable {
        _depositETHForWeETH(_referral);
    }
    
    function depositStETHForWeETH(uint256 _stEthAmount) public {
        
    }

    function _depositETHForWeETH(address _referral) internal {
        uint256 eETHShares;

        if (_referral != address(0)) {
            eETHShares = liquidityPool.deposit{value: msg.value}(_referral);
        } else {
            eETHShares = liquidityPool.deposit{value: msg.value}();
        }

        uint256 eETHAmount = liquidityPool.amountForShare(eETHShares);
        eETH.approve(address(weETH), eETHAmount);
        uint256 weEthAmount = weETH.wrap(eETHAmount);
        weETH.transfer(msg.sender, weEthAmount);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
