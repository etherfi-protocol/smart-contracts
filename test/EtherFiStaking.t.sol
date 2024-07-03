// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "forge-std/Test.sol";


import "../src/EtherFiStaking.sol";
import "../src/UUPSProxy.sol";

import "./eigenlayer-mocks/ERC20Mock.sol";

contract EtherFiStakingTest is TestSetup {
// contract EtherFiStakingTest is Test {
    // address alice = vm.addr(2);

    address public token;

    EtherFiStaking public etherfiStaking;

    function setUp() public {
        initializeRealisticFork(MAINNET_FORK);
        token = address(ethfiToken);

        // token = address(new ERC20Mock());

        _deploy_EtherFiStaking();

        address ethfi_foundation = 0x7A6A41F353B3002751d94118aA7f4935dA39bB53;
        vm.prank(ethfi_foundation);
        IERC20(token).transfer(alice, 1000 ether);
    }

    function _deploy_EtherFiStaking() public {
        EtherFiStaking impl = new EtherFiStaking();
        UUPSProxy proxy = new UUPSProxy(
            address(impl), 
            abi.encodeWithSelector(EtherFiStaking.initialize.selector, address(token))
        );

        etherfiStaking = EtherFiStaking(address(proxy));
    }


    function test_deposit_with_zeroaddress_delegatee_fail() public {
        vm.startPrank(alice);
        IERC20(token).approve(address(etherfiStaking), 100 ether);
        vm.expectRevert("Delegatee cannot be zero address");
        etherfiStaking.deposit(100 ether, address(0));
        vm.stopPrank();
    }


    function test_deposit_success() public {
        assertEq(etherfiStaking.balanceOf(alice), 0 ether);
        assertEq(etherfiStaking.getVotes(alice), 0 ether);

        vm.startPrank(alice);
        IERC20(token).approve(address(etherfiStaking), 100 ether);
        etherfiStaking.deposit(100 ether, alice);
        vm.stopPrank();

        assertEq(etherfiStaking.balanceOf(alice), 100 ether);
        assertEq(etherfiStaking.getVotes(alice), 100 ether);
    }

    function test_withdraw_success() public {
        test_deposit_success();

        vm.prank(alice);
        etherfiStaking.withdraw(50 ether);
        assertEq(etherfiStaking.balanceOf(alice), 50 ether);
        assertEq(etherfiStaking.getVotes(alice), 50 ether);

        vm.prank(alice);
        etherfiStaking.withdraw(25 ether);
        assertEq(etherfiStaking.balanceOf(alice), 25 ether);
        assertEq(etherfiStaking.getVotes(alice), 25 ether);

        vm.prank(alice);
        etherfiStaking.withdraw(25 ether);
        assertEq(etherfiStaking.balanceOf(alice), 0 ether);
        assertEq(etherfiStaking.getVotes(alice), 0 ether);

        test_deposit_success();

        vm.prank(alice);
        etherfiStaking.withdraw(50 ether);
        assertEq(etherfiStaking.balanceOf(alice), 50 ether);
        assertEq(etherfiStaking.getVotes(alice), 50 ether);
    }

    function test_withdraw_beyond_balance_fails() public {
        test_deposit_success();

        vm.prank(alice);
        vm.expectRevert("Insufficient balance for withdrawal");
        etherfiStaking.withdraw(1000 ether);
    }

    function test_delegate() public {
        test_deposit_success();

        vm.prank(alice);
        etherfiStaking.delegate(bob);

        assertEq(etherfiStaking.balanceOf(alice), 100 ether);
        assertEq(etherfiStaking.balanceOf(bob), 0 ether);
        assertEq(etherfiStaking.getVotes(alice), 0 ether);
        assertEq(etherfiStaking.getVotes(bob), 100 ether);
    }

}