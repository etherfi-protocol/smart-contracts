// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "../src/DepositAdapter.sol";
import "./TestSetup.sol";


contract DepositAdapterTest is TestSetup {

    event Deposit(address indexed sender, uint256 amount, uint8 source, address referral);

    DepositAdapter depositAdapterInstance;

    function setUp() public {
        initializeRealisticFork(MAINNET_FORK);

        address depositAdapterImpl = address(new DepositAdapter(address(liquidityPoolInstance), address(weEthInstance), address(eETHInstance)));
        address depositAdapterProxy = address(new UUPSProxy(depositAdapterImpl, ""));
        depositAdapterInstance = DepositAdapter(depositAdapterProxy);
        depositAdapterInstance.initialize();
    }

    function test_DepositWeETH() public {
        startHoax(alice);

        vm.expectRevert(LiquidityPool.InvalidAmount.selector);
        depositAdapterInstance.depositETHForWeETH{value: 0 ether}();
        
        depositAdapterInstance.depositETHForWeETH{value: 1 ether}();
        assertApproxEqAbs(weEthInstance.balanceOf(address(alice)), weEthInstance.getWeETHByeETH(1 ether), 1);

        depositAdapterInstance.depositETHForWeETH{value: 1000 ether}();
        assertApproxEqAbs(weEthInstance.balanceOf(address(alice)), weEthInstance.getWeETHByeETH(1001 ether), 2);

        vm.expectEmit(true, false, false, true);
        emit Deposit(alice,  1 ether, 1, bob);
        depositAdapterInstance.depositETHForWeETH{value: 1 ether}(bob);
    }
}
