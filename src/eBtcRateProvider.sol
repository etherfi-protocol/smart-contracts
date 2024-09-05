// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IRateProvider {
    function getRate() external view returns (uint256);
    function getRateSafe() external view returns (uint256 rate);
    function decimals() external view returns (uint8);
}

contract eBtcRateProvider is IRateProvider {
    IRateProvider public rateProvier = IRateProvider(0x1b293DC39F94157fA0D1D36d7e0090C8B8B8c13F);

    function getRate() external view returns (uint256) {
        return rateProvier.getRate() * 1e10;
    }

    function getRateSafe() external view returns (uint256 rate) {
        return rateProvier.getRateSafe() * 1e10;
    }

    function decimals() external view returns (uint8) {
        return rateProvier.decimals() + 10;
    }
}