// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {UniswapV3TWAP} from "../src/TWAP.sol";

contract TWAPTest is Test {
    UniswapV3TWAP twap;
    address pool = 0x63818BbDd21E69bE108A23aC1E84cBf66399Bd7D;

    function setUp() public {
        vm.createSelectFork("https://eth.llamarpc.com");

        twap = new UniswapV3TWAP();
    }

    function test_twap() public view {
        (int24 twapTick, uint256 price) = twap.getTWAP(pool, 600000);
    }
}