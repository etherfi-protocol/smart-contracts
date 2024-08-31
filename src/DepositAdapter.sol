// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./interfaces/ILiquidityPool.sol";
import "./WeETH.sol";
import "./eETH.sol";

contract DepositAdapter {

    WeETH public immutable weETH;
    ILiquidityPool public immutable liquidityPool;
    EETH public immutable eETH;


    constructor(address _liquidityPool, address _weETH, address _eETH) {
        liquidityPool = ILiquidityPool(_liquidityPool);
        weETH = WeETH(_weETH);
        eETH = EETH(_eETH);
    }

    function depositETHForWeETH() public payable {
        uint256 eETHShares = liquidityPool.deposit{value: msg.value}();
        uint256 eETHAmount = liquidityPool.amountForShare(eETHShares);
        eETH.approve(address(weETH), eETHAmount);
        uint256 weEthAmount = weETH.wrap(eETHAmount);
        weETH.transfer(msg.sender, weEthAmount);
    }
    
    function depositStETHForWeETH(uint256 _stEthAmount) public {
       
    }
    
}
