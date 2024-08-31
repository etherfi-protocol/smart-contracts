// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/DepositAdapter.sol";
import "../src/WeETH.sol";


contract DepositAdapterTest is Test {

    DepositAdapter depositAdapterInstance;
    WeETH weETHInstance;
    address alice;
    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));

        weETHInstance = WeETH(0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee);
        depositAdapterInstance = new DepositAdapter(0x308861A430be4cce5502d0A12724771Fc6DaF216, 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee, 0x35fA164735182de50811E8e2E824cFb9B6118ac2);
        alice = vm.addr(1);
    }

    function test_DepositWeETH() public {
        startHoax(alice);

        uint256 expectedWeETH = weETHInstance.getWeETHByeETH(1 ether);
        depositAdapterInstance.depositETHForWeETH{value: 1 ether}();

        // The famous 1 wei rounding error rears its ugly head
        assertApproxEqAbs(weETHInstance.balanceOf(address(alice)), expectedWeETH, 1);
    }

    
    

}
