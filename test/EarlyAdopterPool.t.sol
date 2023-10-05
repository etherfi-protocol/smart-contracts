// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "../src/EarlyAdopterPool.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "./TestERC20.sol";

contract EarlyAdopterPoolTest is Test {
    event ERC20TVLUpdated(
        uint256 rETHBal,
        uint256 wstETHBal,
        uint256 sfrxETHBal,
        uint256 cbETHBal,
        uint256 ETHBal,
        uint256 tvl
    );

    event EthTVLUpdated(uint256 ETHBal, uint256 tvl);

    EarlyAdopterPool earlyAdopterPoolInstance;

    TestERC20 public rETH;
    TestERC20 public wstETH;
    TestERC20 public sfrxEth;
    TestERC20 public cbEth;

    uint256 One_Day = 1 days;
    uint256 One_Month = 1 weeks * 4;

    address owner = vm.addr(1);
    address alice = vm.addr(2);
    address bob = vm.addr(3);

    function setUp() public {
        rETH = new TestERC20("Rocket Pool ETH", "rETH");
        rETH.mint(alice, 10e18);
        rETH.mint(bob, 10e18);

        cbEth = new TestERC20("Staked ETH", "wstETH");
        cbEth.mint(alice, 10e18);
        cbEth.mint(bob, 10e18);

        wstETH = new TestERC20("Coinbase ETH", "cbEth");
        wstETH.mint(alice, 10e18);
        wstETH.mint(bob, 10e18);

        sfrxEth = new TestERC20("Frax ETH", "sfrxEth");
        sfrxEth.mint(alice, 10e18);
        sfrxEth.mint(bob, 10e18);

        vm.startPrank(owner);
        earlyAdopterPoolInstance = new EarlyAdopterPool(
            address(rETH),
            address(wstETH),
            address(sfrxEth),
            address(cbEth)
        );
        vm.stopPrank();
    }

    function test_SetUp() public {
        assertEq(rETH.balanceOf(alice), 10e18);
        assertEq(wstETH.balanceOf(alice), 10e18);
        assertEq(sfrxEth.balanceOf(alice), 10e18);
    }

    function test_DepositERC20IntoEarlyAdopterPool() public {
        vm.startPrank(alice);
        rETH.approve(address(earlyAdopterPoolInstance), 0.1 ether);
        earlyAdopterPoolInstance.deposit(address(rETH), 1e17);
        vm.stopPrank();

        (
            uint256 depositTime,
            ,
            uint256 totalERC20Balance
        ) = earlyAdopterPoolInstance.depositInfo(alice);

        assertEq(totalERC20Balance, 0.1 ether);
        assertEq(
            earlyAdopterPoolInstance.userToErc20Balance(alice, address(rETH)),
            0.1 ether
        );
        assertEq(
            earlyAdopterPoolInstance.userToErc20Balance(alice, address(wstETH)),
            0
        );
        assertEq(
            earlyAdopterPoolInstance.userToErc20Balance(
                alice,
                address(sfrxEth)
            ),
            0
        );

        vm.startPrank(alice);
        wstETH.approve(address(earlyAdopterPoolInstance), 0.1 ether);
        earlyAdopterPoolInstance.deposit(address(wstETH), 1e17);
        vm.stopPrank();

        (depositTime, , totalERC20Balance) = earlyAdopterPoolInstance
            .depositInfo(alice);

        assertEq(totalERC20Balance, 0.2 ether);
        assertEq(
            earlyAdopterPoolInstance.userToErc20Balance(alice, address(rETH)),
            0.1 ether
        );
        assertEq(
            earlyAdopterPoolInstance.userToErc20Balance(alice, address(wstETH)),
            0.1 ether
        );
        assertEq(
            earlyAdopterPoolInstance.userToErc20Balance(
                alice,
                address(sfrxEth)
            ),
            0
        );

        assertEq(rETH.balanceOf(address(earlyAdopterPoolInstance)), 1e17);
        assertEq(wstETH.balanceOf(address(earlyAdopterPoolInstance)), 1e17);

        vm.startPrank(alice);
        sfrxEth.approve(address(earlyAdopterPoolInstance), 0.1 ether);
        earlyAdopterPoolInstance.deposit(address(sfrxEth), 1e17);
        vm.stopPrank();

        (, , totalERC20Balance) = earlyAdopterPoolInstance.depositInfo(alice);

        assertEq(totalERC20Balance, 0.3 ether);
        assertEq(
            earlyAdopterPoolInstance.userToErc20Balance(alice, address(rETH)),
            0.1 ether
        );
        assertEq(
            earlyAdopterPoolInstance.userToErc20Balance(alice, address(wstETH)),
            0.1 ether
        );
        assertEq(
            earlyAdopterPoolInstance.userToErc20Balance(
                alice,
                address(sfrxEth)
            ),
            0.1 ether
        );

        assertEq(rETH.balanceOf(address(earlyAdopterPoolInstance)), 1e17);
        assertEq(wstETH.balanceOf(address(earlyAdopterPoolInstance)), 1e17);
        assertEq(sfrxEth.balanceOf(address(earlyAdopterPoolInstance)), 1e17);
    }

    function test_DepositETHIntoEarlyAdopterPool() public {
        startHoax(0x2Fc348E6505BA471EB21bFe7a50298fd1f02DBEA);
        earlyAdopterPoolInstance.depositEther{value: 0.1 ether}();
        vm.stopPrank();

        (, uint256 ethBalance, ) = earlyAdopterPoolInstance
            .depositInfo(0x2Fc348E6505BA471EB21bFe7a50298fd1f02DBEA);

        assertEq(ethBalance, 0.1 ether);
    }

    function test_EventERC20TVLUpdated() public {
        vm.prank(alice);
        rETH.approve(address(earlyAdopterPoolInstance), 0.1 ether);

        vm.expectEmit(false, false, false, true);
        emit ERC20TVLUpdated(0.1 ether, 0, 0, 0, 0, 0.1 ether);
        vm.prank(alice);
        earlyAdopterPoolInstance.deposit(address(rETH), 1e17);

        vm.prank(alice);
        wstETH.approve(address(earlyAdopterPoolInstance), 0.1 ether);

        vm.expectEmit(false, false, false, true);
        emit ERC20TVLUpdated(0.1 ether, 0.1 ether, 0, 0, 0, 0.2 ether);
        vm.prank(alice);
        earlyAdopterPoolInstance.deposit(address(wstETH), 1e17);

        vm.prank(bob);
        sfrxEth.approve(address(earlyAdopterPoolInstance), 0.5 ether);

        vm.expectEmit(false, false, false, true);
        emit ERC20TVLUpdated(0.1 ether, 0.1 ether, 0.5 ether, 0, 0, 0.7 ether);
        vm.prank(bob);
        earlyAdopterPoolInstance.deposit(address(sfrxEth), 5e17);

        vm.prank(bob);
        rETH.approve(address(earlyAdopterPoolInstance), 0.5 ether);

        vm.expectEmit(false, false, false, true);
        emit ERC20TVLUpdated(0.6 ether, 0.1 ether, 0.5 ether, 0, 0, 1.2 ether);
        vm.prank(bob);
        earlyAdopterPoolInstance.deposit(address(rETH), 5e17);

        vm.prank(bob);
        cbEth.approve(address(earlyAdopterPoolInstance), 0.5 ether);

        vm.expectEmit(false, false, false, true);
        emit ERC20TVLUpdated(
            0.6 ether,
            0.1 ether,
            0.5 ether,
            0.5 ether,
            0,
            1.7 ether
        );
        vm.prank(bob);
        earlyAdopterPoolInstance.deposit(address(cbEth), 5e17);
    }

    function test_EventEthTVLUpdated() public {
        vm.expectEmit(false, false, false, true);
        emit EthTVLUpdated(0.1 ether, 0.1 ether);

        startHoax(0x2Fc348E6505BA471EB21bFe7a50298fd1f02DBEA);
        earlyAdopterPoolInstance.depositEther{value: 0.1 ether}();
        vm.stopPrank();

        vm.expectEmit(false, false, false, true);
        emit EthTVLUpdated(0.6 ether, 0.6 ether);
        hoax(alice);
        earlyAdopterPoolInstance.depositEther{value: 0.5 ether}();
    }

    function test_EventTVLUpdatedOnERC20AndEthDeposit() public {
        vm.expectEmit(false, false, false, true);
        emit EthTVLUpdated(0.1 ether, 0.1 ether);

        startHoax(0x2Fc348E6505BA471EB21bFe7a50298fd1f02DBEA);
        earlyAdopterPoolInstance.depositEther{value: 0.1 ether}();
        vm.stopPrank();

        vm.expectEmit(false, false, false, true);
        emit EthTVLUpdated(0.6 ether, 0.6 ether);
        hoax(alice);
        earlyAdopterPoolInstance.depositEther{value: 0.5 ether}();

        vm.prank(bob);
        rETH.approve(address(earlyAdopterPoolInstance), 0.1 ether);

        vm.expectEmit(false, false, false, true);
        emit ERC20TVLUpdated(0.1 ether, 0, 0, 0, 0.6 ether, 0.7 ether);
        vm.prank(bob);
        earlyAdopterPoolInstance.deposit(address(rETH), 1e17);

        vm.prank(bob);
        wstETH.approve(address(earlyAdopterPoolInstance), 0.7 ether);

        vm.expectEmit(false, false, false, true);
        emit ERC20TVLUpdated(0.1 ether, 0.7 ether, 0, 0, 0.6 ether, 1.4 ether);
        vm.prank(bob);
        earlyAdopterPoolInstance.deposit(address(wstETH), 7e17);

        vm.prank(alice);
        sfrxEth.approve(address(earlyAdopterPoolInstance), 0.6 ether);

        vm.expectEmit(false, false, false, true);
        emit ERC20TVLUpdated(
            0.1 ether,
            0.7 ether,
            0.6 ether,
            0,
            0.6 ether,
            2 ether
        );
        vm.prank(alice);
        earlyAdopterPoolInstance.deposit(address(sfrxEth), 6e17);

        vm.expectEmit(false, false, false, true);
        emit EthTVLUpdated(1.1 ether, 2.5 ether);
        startHoax(bob);
        earlyAdopterPoolInstance.depositEther{value: 0.5 ether}();
        vm.stopPrank();
    }

    function test_GetTVL() public {
        vm.startPrank(bob);
        wstETH.approve(address(earlyAdopterPoolInstance), 0.1 ether);
        earlyAdopterPoolInstance.deposit(address(wstETH), 0.1 ether);
        vm.stopPrank();

        uint256 tvl = earlyAdopterPoolInstance.getContractTVL();

        assertEq(tvl, 0.1 ether);

        vm.startPrank(alice);
        rETH.approve(address(earlyAdopterPoolInstance), 1 ether);
        earlyAdopterPoolInstance.deposit(address(rETH), 1 ether);
        vm.stopPrank();

        tvl = earlyAdopterPoolInstance.getContractTVL();

        assertEq(tvl, 1.1 ether);

        startHoax(bob);
        earlyAdopterPoolInstance.depositEther{value: 2 ether}();
        vm.stopPrank();

        tvl = earlyAdopterPoolInstance.getContractTVL();

        assertEq(tvl, 3.1 ether);
    }

    function test_GetUserTVL() public {
        vm.startPrank(alice);
        rETH.approve(address(earlyAdopterPoolInstance), 1 ether);
        earlyAdopterPoolInstance.deposit(address(rETH), 1 ether);
        vm.stopPrank();

        (
            uint256 rETHBal,
            uint256 wstETHBal,
            uint256 sfrxETHBal,
            uint256 cbETHBal,
            uint256 ethBal,
            uint256 totalBal
        ) = earlyAdopterPoolInstance.getUserTVL(alice);

        assertEq(rETHBal, 1 ether);
        assertEq(wstETHBal, 0);
        assertEq(sfrxETHBal, 0);
        assertEq(cbETHBal, 0);
        assertEq(ethBal, 0);
        assertEq(totalBal, 1 ether);

        vm.startPrank(alice);
        cbEth.approve(address(earlyAdopterPoolInstance), 10 ether);
        earlyAdopterPoolInstance.deposit(address(cbEth), 10 ether);
        vm.stopPrank();

        (
            rETHBal,
            wstETHBal,
            sfrxETHBal,
            cbETHBal,
            ethBal,
            totalBal
        ) = earlyAdopterPoolInstance.getUserTVL(alice);

        assertEq(rETHBal, 1 ether);
        assertEq(wstETHBal, 0);
        assertEq(sfrxETHBal, 0);
        assertEq(cbETHBal, 10 ether);
        assertEq(ethBal, 0);
        assertEq(totalBal, 11 ether);

        startHoax(bob);
        earlyAdopterPoolInstance.depositEther{value: 5 ether}();
        wstETH.approve(address(earlyAdopterPoolInstance), 0.5 ether);
        earlyAdopterPoolInstance.deposit(address(wstETH), 0.5 ether);
        vm.stopPrank();

        (
            rETHBal,
            wstETHBal,
            sfrxETHBal,
            cbETHBal,
            ethBal,
            totalBal
        ) = earlyAdopterPoolInstance.getUserTVL(bob);

        assertEq(rETHBal, 0);
        assertEq(wstETHBal, 0.5 ether);
        assertEq(sfrxETHBal, 0);
        assertEq(cbETHBal, 0);
        assertEq(ethBal, 5 ether);
        assertEq(totalBal, 5.5 ether);
    }

    function test_WithdrawWorksCorrectly() public {
        vm.startPrank(bob);
        wstETH.approve(address(earlyAdopterPoolInstance), 0.1 ether);
        earlyAdopterPoolInstance.deposit(address(wstETH), 0.1 ether);
        (
            ,
            ,
            uint256 totalERC20Balance
        ) = earlyAdopterPoolInstance.depositInfo(bob);
        vm.stopPrank();

        vm.startPrank(alice);
        rETH.approve(address(earlyAdopterPoolInstance), 0.1 ether);
        cbEth.approve(address(earlyAdopterPoolInstance), 0.1 ether);
        earlyAdopterPoolInstance.deposit(address(cbEth), 0.1 ether);
        earlyAdopterPoolInstance.deposit(address(rETH), 0.1 ether);
        vm.stopPrank();

        assertEq(totalERC20Balance, 0.1 ether);
        assertEq(
            earlyAdopterPoolInstance.userToErc20Balance(bob, address(wstETH)),
            0.1 ether
        );
        assertEq(
            wstETH.balanceOf(address(earlyAdopterPoolInstance)),
            0.1 ether
        );

        // 3 days
        vm.warp(block.timestamp + 259201);

        uint256 points = earlyAdopterPoolInstance.calculateUserPoints(bob);
        assertEq(points, 901);

        uint256 balanceBeforeBob = wstETH.balanceOf(bob);
        uint256 balanceBeforeAlice = rETH.balanceOf(alice) +
            cbEth.balanceOf(alice);

        vm.prank(bob);
        earlyAdopterPoolInstance.withdraw();
        vm.prank(alice);
        earlyAdopterPoolInstance.withdraw();
        uint256 balanceAfterAlice = rETH.balanceOf(alice) +
            cbEth.balanceOf(alice);

        (, , totalERC20Balance) = earlyAdopterPoolInstance
            .depositInfo(bob);

        assertEq(balanceAfterAlice, balanceBeforeAlice + 0.2 ether);
        assertEq(wstETH.balanceOf(bob), balanceBeforeBob + 0.1 ether);
        assertEq(totalERC20Balance, 0 ether);
        assertEq(wstETH.balanceOf(address(earlyAdopterPoolInstance)), 0);
    }

    function test_RewardsPoolMinDeposit() public {
        vm.expectRevert("Incorrect Deposit Amount");
        hoax(alice);
        earlyAdopterPoolInstance.deposit(address(rETH), 0.003 ether);
    }

    function test_RewardsPoolMaxDeposit() public {
        vm.expectRevert("Incorrect Deposit Amount");
        hoax(alice);
        earlyAdopterPoolInstance.deposit(address(rETH), 101 ether);
    }

    function test_ClaimWorks() public {
        vm.startPrank(alice);
        sfrxEth.approve(address(earlyAdopterPoolInstance), 0.1 ether);
        earlyAdopterPoolInstance.deposit(address(sfrxEth), 0.1 ether);

        wstETH.approve(address(earlyAdopterPoolInstance), 0.1 ether);
        earlyAdopterPoolInstance.deposit(address(wstETH), 0.1 ether);

        rETH.approve(address(earlyAdopterPoolInstance), 0.1 ether);
        earlyAdopterPoolInstance.deposit(address(rETH), 0.1 ether);
        vm.stopPrank();

        assertEq(
            earlyAdopterPoolInstance.userToErc20Balance(alice, address(rETH)),
            0.1 ether
        );
        assertEq(
            earlyAdopterPoolInstance.userToErc20Balance(alice, address(wstETH)),
            0.1 ether
        );
        assertEq(
            earlyAdopterPoolInstance.userToErc20Balance(
                alice,
                address(sfrxEth)
            ),
            0.1 ether
        );

        (, , uint256 totalERC20Balance) = earlyAdopterPoolInstance.depositInfo(
            alice
        );

        assertEq(totalERC20Balance, 0.3 ether);

        assertEq(rETH.balanceOf(address(earlyAdopterPoolInstance)), 0.1 ether);
        assertEq(
            wstETH.balanceOf(address(earlyAdopterPoolInstance)),
            0.1 ether
        );
        assertEq(
            sfrxEth.balanceOf(address(earlyAdopterPoolInstance)),
            0.1 ether
        );

        vm.startPrank(owner);
        vm.warp(block.timestamp + 4752001);

        earlyAdopterPoolInstance.setClaimingOpen(60);
        earlyAdopterPoolInstance.setClaimReceiverContract(alice);

        uint256 aliceRethBalBefore = rETH.balanceOf(alice);
        uint256 aliceWSTethBalBefore = wstETH.balanceOf(alice);
        uint256 alicesfrxEthBalBefore = sfrxEth.balanceOf(alice);

        vm.stopPrank();
        vm.startPrank(alice);
        assertEq(earlyAdopterPoolInstance.calculateUserPoints(alice), 52055);
        earlyAdopterPoolInstance.claim();

        uint256 aliceRethBalAfter = rETH.balanceOf(alice);
        uint256 aliceWSTethBalAfter = wstETH.balanceOf(alice);
        uint256 alicesfrxEthBalAfter = sfrxEth.balanceOf(alice);

        assertEq(
            earlyAdopterPoolInstance.userToErc20Balance(alice, address(rETH)),
            0 ether
        );
        assertEq(
            earlyAdopterPoolInstance.userToErc20Balance(alice, address(wstETH)),
            0 ether
        );
        assertEq(
            earlyAdopterPoolInstance.userToErc20Balance(
                alice,
                address(sfrxEth)
            ),
            0 ether
        );

        (, , totalERC20Balance) = earlyAdopterPoolInstance.depositInfo(alice);

        assertEq(totalERC20Balance, 0 ether);

        assertEq(rETH.balanceOf(address(earlyAdopterPoolInstance)), 0);
        assertEq(wstETH.balanceOf(address(earlyAdopterPoolInstance)), 0);
        assertEq(sfrxEth.balanceOf(address(earlyAdopterPoolInstance)), 0);

        assertEq(aliceRethBalAfter, aliceRethBalBefore + 0.1 ether);
        assertEq(aliceWSTethBalAfter, aliceWSTethBalBefore + 0.1 ether);
        assertEq(alicesfrxEthBalAfter, alicesfrxEthBalBefore + 0.1 ether);
    }

    function test_ClaimFailsIfClaimingNotOpen() public {
        vm.startPrank(alice);
        sfrxEth.approve(address(earlyAdopterPoolInstance), 0.1 ether);
        earlyAdopterPoolInstance.deposit(address(sfrxEth), 0.1 ether);
        vm.stopPrank();

        vm.startPrank(owner);
        earlyAdopterPoolInstance.setClaimReceiverContract(alice);

        vm.expectRevert("Claiming not open");
        earlyAdopterPoolInstance.claim();
    }

    function test_ClaimFailsIfClaimingReceiverNotSet() public {
        vm.startPrank(alice);
        sfrxEth.approve(address(earlyAdopterPoolInstance), 0.1 ether);
        earlyAdopterPoolInstance.deposit(address(sfrxEth), 0.1 ether);
        vm.stopPrank();

        vm.startPrank(owner);
        earlyAdopterPoolInstance.setClaimingOpen(10);

        vm.expectRevert("Claiming address not set");
        earlyAdopterPoolInstance.claim();
    }

    function test_ClaimFailsIfClaimingIsComplete() public {
        vm.startPrank(alice);
        sfrxEth.approve(address(earlyAdopterPoolInstance), 0.1 ether);
        earlyAdopterPoolInstance.deposit(address(sfrxEth), 0.1 ether);
        vm.stopPrank();

        vm.startPrank(owner);
        earlyAdopterPoolInstance.setClaimingOpen(10);
        earlyAdopterPoolInstance.setClaimReceiverContract(alice);

        vm.warp(block.timestamp + 864001);
        vm.expectRevert("Claiming is complete");
        earlyAdopterPoolInstance.claim();
    }

    function test_SetClaimableStatusTrue() public {
        vm.startPrank(owner);
        assertEq(earlyAdopterPoolInstance.claimingOpen(), 0);
        earlyAdopterPoolInstance.setClaimingOpen(10);
        assertEq(earlyAdopterPoolInstance.claimingOpen(), 1);
    }

    function test_SetClaimableStatusFailsIfNotOwner() public {
        vm.startPrank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        earlyAdopterPoolInstance.setClaimingOpen(10);
    }

    function test_SetReceiverAddress() public {
        vm.startPrank(owner);
        assertEq(earlyAdopterPoolInstance.claimReceiverContract(), address(0));
        earlyAdopterPoolInstance.setClaimReceiverContract(alice);
        assertEq(earlyAdopterPoolInstance.claimReceiverContract(), alice);
    }

    function test_SetReceiverFailsIfNotOwner() public {
        vm.startPrank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        earlyAdopterPoolInstance.setClaimReceiverContract(alice);
    }

    function test_SetReceiverFailsIfAddressZero() public {
        vm.startPrank(owner);
        vm.expectRevert("Cannot set as address zero");
        earlyAdopterPoolInstance.setClaimReceiverContract(address(0));
    }

    function test_DepositAndClaimWithERC20AndETH() public {
        rETH.mint(0x2Fc348E6505BA471EB21bFe7a50298fd1f02DBEA, 10e18);
        sfrxEth.mint(0x2Fc348E6505BA471EB21bFe7a50298fd1f02DBEA, 10e18);
        wstETH.mint(0x2Fc348E6505BA471EB21bFe7a50298fd1f02DBEA, 10e18);

        vm.startPrank(0x2Fc348E6505BA471EB21bFe7a50298fd1f02DBEA);
        sfrxEth.approve(address(earlyAdopterPoolInstance), 0.1 ether);
        earlyAdopterPoolInstance.deposit(address(sfrxEth), 0.1 ether);

        wstETH.approve(address(earlyAdopterPoolInstance), 0.1 ether);
        earlyAdopterPoolInstance.deposit(address(wstETH), 0.1 ether);

        rETH.approve(address(earlyAdopterPoolInstance), 0.1 ether);
        earlyAdopterPoolInstance.deposit(address(rETH), 0.1 ether);
        vm.stopPrank();

        assertEq(
            earlyAdopterPoolInstance.userToErc20Balance(
                0x2Fc348E6505BA471EB21bFe7a50298fd1f02DBEA,
                address(rETH)
            ),
            0.1 ether
        );
        assertEq(
            earlyAdopterPoolInstance.userToErc20Balance(
                0x2Fc348E6505BA471EB21bFe7a50298fd1f02DBEA,
                address(wstETH)
            ),
            0.1 ether
        );
        assertEq(
            earlyAdopterPoolInstance.userToErc20Balance(
                0x2Fc348E6505BA471EB21bFe7a50298fd1f02DBEA,
                address(sfrxEth)
            ),
            0.1 ether
        );

        (, , uint256 totalERC20Balance) = earlyAdopterPoolInstance.depositInfo(
            0x2Fc348E6505BA471EB21bFe7a50298fd1f02DBEA
        );

        assertEq(totalERC20Balance, 0.3 ether);

        assertEq(rETH.balanceOf(address(earlyAdopterPoolInstance)), 0.1 ether);
        assertEq(
            wstETH.balanceOf(address(earlyAdopterPoolInstance)),
            0.1 ether
        );
        assertEq(
            sfrxEth.balanceOf(address(earlyAdopterPoolInstance)),
            0.1 ether
        );
        hoax(0x2Fc348E6505BA471EB21bFe7a50298fd1f02DBEA);
        earlyAdopterPoolInstance.depositEther{value: 0.1 ether}();

        vm.warp(block.timestamp + 5184000);

        vm.startPrank(owner);
        earlyAdopterPoolInstance.setClaimingOpen(60);
        earlyAdopterPoolInstance.setClaimReceiverContract(alice);
        vm.stopPrank();

        (, uint256 ethBalance, ) = earlyAdopterPoolInstance
            .depositInfo(0x2Fc348E6505BA471EB21bFe7a50298fd1f02DBEA);

        assertEq(ethBalance, 0.1 ether);

        hoax(0x2Fc348E6505BA471EB21bFe7a50298fd1f02DBEA);
        assertEq(
            earlyAdopterPoolInstance.calculateUserPoints(
                0x2Fc348E6505BA471EB21bFe7a50298fd1f02DBEA
            ),
            65572
        );

        uint256 RethBalBefore = rETH.balanceOf(alice);
        uint256 WSTethBalBefore = wstETH.balanceOf(alice);
        uint256 sfrxEthBalBefore = sfrxEth.balanceOf(alice);
        uint256 EthBalanceBefore = alice.balance;

        hoax(0x2Fc348E6505BA471EB21bFe7a50298fd1f02DBEA);
        earlyAdopterPoolInstance.claim();

        uint256 RethBalAfter = rETH.balanceOf(alice);
        uint256 WSTethBalAfter = wstETH.balanceOf(alice);
        uint256 sfrxEthBalAfter = sfrxEth.balanceOf(alice);
        uint256 EthBalanceAfter = alice.balance;

        assertEq(
            earlyAdopterPoolInstance.userToErc20Balance(
                0x2Fc348E6505BA471EB21bFe7a50298fd1f02DBEA,
                address(rETH)
            ),
            0 ether
        );
        assertEq(
            earlyAdopterPoolInstance.userToErc20Balance(
                0x2Fc348E6505BA471EB21bFe7a50298fd1f02DBEA,
                address(wstETH)
            ),
            0 ether
        );
        assertEq(
            earlyAdopterPoolInstance.userToErc20Balance(
                0x2Fc348E6505BA471EB21bFe7a50298fd1f02DBEA,
                address(sfrxEth)
            ),
            0 ether
        );

        (, , totalERC20Balance) = earlyAdopterPoolInstance.depositInfo(
            0x2Fc348E6505BA471EB21bFe7a50298fd1f02DBEA
        );

        assertEq(totalERC20Balance, 0 ether);

        assertEq(rETH.balanceOf(address(earlyAdopterPoolInstance)), 0);
        assertEq(wstETH.balanceOf(address(earlyAdopterPoolInstance)), 0);
        assertEq(sfrxEth.balanceOf(address(earlyAdopterPoolInstance)), 0);

        assertEq(RethBalAfter, RethBalBefore + 0.1 ether);
        assertEq(WSTethBalAfter, WSTethBalBefore + 0.1 ether);
        assertEq(sfrxEthBalAfter, sfrxEthBalBefore + 0.1 ether);
        assertEq(EthBalanceAfter, EthBalanceBefore + 0.1 ether);
    }

    function test_PointsCalculatorWorksCorrectly() public {
        sfrxEth.mint(owner, 10e18);
        sfrxEth.mint(0x76Db1a8A8DAc24b14506950ae64100a38e25F5d8, 10e18);

        vm.startPrank(owner);
        sfrxEth.approve(address(earlyAdopterPoolInstance), 10 ether);
        earlyAdopterPoolInstance.deposit(address(sfrxEth), 1e17);
        vm.stopPrank();

        vm.startPrank(alice);
        wstETH.approve(address(earlyAdopterPoolInstance), 10 ether);
        earlyAdopterPoolInstance.deposit(address(wstETH), 1e18);
        vm.stopPrank();

        vm.startPrank(alice);
        cbEth.approve(address(earlyAdopterPoolInstance), 10 ether);
        earlyAdopterPoolInstance.deposit(address(cbEth), 1e18);
        vm.stopPrank();

        vm.startPrank(bob);
        rETH.approve(address(earlyAdopterPoolInstance), 10 ether);
        earlyAdopterPoolInstance.deposit(address(rETH), 10e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 361);
        assertEq(earlyAdopterPoolInstance.calculateUserPoints(owner), 1);

        vm.warp(block.timestamp + 28860);
        assertEq(earlyAdopterPoolInstance.calculateUserPoints(alice), 417);

        vm.warp(block.timestamp + 615249);
        assertEq(earlyAdopterPoolInstance.calculateUserPoints(bob), 25434);

        hoax(0x76Db1a8A8DAc24b14506950ae64100a38e25F5d8);
        earlyAdopterPoolInstance.depositEther{value: 9 ether}();

        vm.startPrank(0x76Db1a8A8DAc24b14506950ae64100a38e25F5d8);
        sfrxEth.approve(address(earlyAdopterPoolInstance), 10 ether);
        earlyAdopterPoolInstance.deposit(address(sfrxEth), 1e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 4031217);
        assertEq(
            earlyAdopterPoolInstance.calculateUserPoints(
                0x76Db1a8A8DAc24b14506950ae64100a38e25F5d8
            ),
            254956
        );
    }
} 
