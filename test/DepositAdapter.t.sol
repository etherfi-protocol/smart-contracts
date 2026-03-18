 // SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "../src/DepositAdapter.sol";
import "./TestSetup.sol";


contract DepositAdapterTest is TestSetup {

    event Deposit(address indexed sender, uint256 amount, uint8 source, address referral);

    // DepositAdapter depositAdapterInstance;

    IWETH public wETH;
    IERC20Upgradeable public stETHmainnet;
    IwstETH public wstETHmainnet;

    function setUp() public {
        initializeRealisticFork(MAINNET_FORK);

        wETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
        stETHmainnet = IERC20Upgradeable(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);
        wstETHmainnet = IwstETH(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);

        // // deploying+initializing the deposit adapter 
        // address depositAdapterImpl = address(
        //     new DepositAdapter(
        //         address(liquidityPoolInstance), 
        //         address(liquifierInstance),
        //         address(weEthInstance), 
        //         address(eETHInstance), 
        //         address(wETH),
        //         address(stETHmainnet),
        //         address(wstETHmainnet)
        //     )
        // );
        // address depositAdapterProxy = address(new UUPSProxy(depositAdapterImpl, ""));
        // depositAdapterInstance = DepositAdapter(payable(depositAdapterProxy));
        // depositAdapterInstance.initialize();

        vm.startPrank(depositAdapterInstance.owner());
        // Upgrade deposit adapter to latest implementation with new functions
        address newImpl = address(
            new DepositAdapter(
                address(liquidityPoolInstance),
                address(liquifierInstance),
                address(weEthInstance),
                address(eETHInstance),
                address(wETH),
                address(stETHmainnet),
                address(wstETHmainnet)
            )
        );
        depositAdapterInstance.upgradeTo(newImpl);
        vm.stopPrank();

        vm.startPrank(owner);

        // Caps are hit on mainnet
        liquifierInstance.updateDepositCap(address(stEth), 600000, 4000000);
        vm.etch((alice), "");
         startHoax(alice);
    }

    function test_DepositWeETH() public {
        vm.expectRevert(LiquidityPool.InvalidAmount.selector);
        depositAdapterInstance.depositETHForWeETH{value: 0 ether}(address(0));
        
        uint256 weEthAmount = depositAdapterInstance.depositETHForWeETH{value: 1 ether}(address(0));
        assertApproxEqAbs(weEthInstance.balanceOf(address(alice)), weEthInstance.getWeETHByeETH(1 ether), 3);
        assertApproxEqAbs(weEthAmount, weEthInstance.getWeETHByeETH(1 ether), 3);
        
        uint256 balanceBeforeDeposit = weEthInstance.balanceOf(address(alice));
        depositAdapterInstance.depositETHForWeETH{value: 1000 ether}(address(0));
        assertApproxEqAbs(weEthInstance.balanceOf(address(alice)), weEthInstance.getWeETHByeETH(1000 ether) + balanceBeforeDeposit, 3);

        depositAdapterInstance.depositETHForWeETH{value: 1 ether}(bob);
    }

    function test_DepositWETH() public {
        wETH.deposit{value: 5 ether}();

        // valid wETH deposit
        uint256 liquidityPoolBalanceBeforeDeposit = address(liquidityPoolInstance).balance;
        wETH.approve(address(depositAdapterInstance), 1 ether);
        depositAdapterInstance.depositWETHForWeETH(1 ether, bob);

        assertEq(address(liquidityPoolInstance).balance, liquidityPoolBalanceBeforeDeposit + 1 ether);
        assertApproxEqAbs(weEthInstance.balanceOf(address(alice)), weEthInstance.getWeETHByeETH(1 ether), 3);

        // invalid deposits
        wETH.approve(address(depositAdapterInstance), 10 ether);
        vm.expectRevert("INSUFFICIENT_BALANCE");
        depositAdapterInstance.depositWETHForWeETH(10 ether, bob);
    }

    function test_DepositStETH() public {
        stEth.submit{value: 2 ether}(address(0));

        // valid permit for not enough amount
        ILiquidityPool.PermitInput memory permitInput = createPermitInput(2, address(depositAdapterInstance), 1 ether - 1, stEth.nonces(alice), 2**256 - 1, stEth.DOMAIN_SEPARATOR());
        ILiquifier.PermitInput memory liquifierPermitInput = ILiquifier.PermitInput({value: permitInput.value, deadline: permitInput.deadline, v: permitInput.v, r: permitInput.r, s: permitInput.s});
        vm.expectRevert("ALLOWANCE_EXCEEDED");
        depositAdapterInstance.depositStETHForWeETHWithPermit(1 ether, address(0), liquifierPermitInput);

        // empty request
        permitInput = createPermitInput(2, address(depositAdapterInstance), 0, stEth.nonces(alice), 2**256 - 1, stEth.DOMAIN_SEPARATOR());
        liquifierPermitInput = ILiquifier.PermitInput({value: permitInput.value, deadline: permitInput.deadline, v: permitInput.v, r: permitInput.r, s: permitInput.s});
        vm.expectRevert();
        depositAdapterInstance.depositStETHForWeETHWithPermit(0, address(0), liquifierPermitInput);

        // valid input
        uint256 protocolStETHBeforeDeposit = stEth.balanceOf(address(etherFiRestakerInstance));
        uint256 stEthBalanceBeforeDeposit = stEth.balanceOf(address(alice));

        // Get eETH amount from stETH input (with discount applied)
        uint256 eETHAmountFromStETH = liquifierInstance.quoteByDiscountedValue(address(stEth), 1 ether);

        permitInput = createPermitInput(2, address(depositAdapterInstance), 1 ether, stEth.nonces(alice), 2**256 - 1, stEth.DOMAIN_SEPARATOR());
        liquifierPermitInput = ILiquifier.PermitInput({value: permitInput.value, deadline: permitInput.deadline, v: permitInput.v, r: permitInput.r, s: permitInput.s});
        depositAdapterInstance.depositStETHForWeETHWithPermit(1 ether, bob, liquifierPermitInput);

        assertApproxEqAbs(stEth.balanceOf(address(alice)), stEthBalanceBeforeDeposit - 1 ether, 3);
        assertApproxEqAbs(weEthInstance.balanceOf(address(alice)), weEthInstance.getWeETHByeETH(eETHAmountFromStETH), 3);
        assertApproxEqAbs(stEth.balanceOf(address(etherFiRestakerInstance)), protocolStETHBeforeDeposit + 1 ether, 3);

        // reusing the same permit
        vm.expectRevert("ALLOWANCE_EXCEEDED");
        depositAdapterInstance.depositStETHForWeETHWithPermit(1 ether, bob, liquifierPermitInput);


        // much larger deposit
        stEth.submit{value: 5000 ether}(address(0));

        protocolStETHBeforeDeposit = stEth.balanceOf(address(etherFiRestakerInstance));
        permitInput = createPermitInput(2, address(depositAdapterInstance), 5000 ether, stEth.nonces(alice), 2**256 - 1, stEth.DOMAIN_SEPARATOR());
        liquifierPermitInput = ILiquifier.PermitInput({value: permitInput.value, deadline: permitInput.deadline, v: permitInput.v, r: permitInput.r, s: permitInput.s});
        depositAdapterInstance.depositStETHForWeETHWithPermit(5000 ether, bob, liquifierPermitInput);

        assertApproxEqAbs(stEth.balanceOf(address(etherFiRestakerInstance)), protocolStETHBeforeDeposit + 5000 ether, 3);
    }

    function test_DepositWstETH() public {
        stEth.submit{value: 5 ether}(address(0));
        stEth.approve(address(wstETHmainnet), 5 ether);
        uint256 wstETHAmount = wstETHmainnet.wrap(5 ether);

        // valid wstETH deposit
        uint256 protocolSeETHBeforeDeposit = stEth.balanceOf(address(etherFiRestakerInstance));
        ILiquidityPool.PermitInput memory permitInput = createPermitInput(2, address(depositAdapterInstance), wstETHAmount, wstETHmainnet.nonces(alice), 2**256 - 1, wstETHmainnet.DOMAIN_SEPARATOR());
        ILiquifier.PermitInput memory liquifierPermitInput = ILiquifier.PermitInput({value: permitInput.value, deadline: permitInput.deadline, v: permitInput.v, r: permitInput.r, s: permitInput.s});

        uint256 eETHAmountFromWstETH = liquifierInstance.quoteByDiscountedValue(address(stEth), 5 ether);
        depositAdapterInstance.depositWstETHForWeETHWithPermit(wstETHAmount, bob, liquifierPermitInput);
        assertEq(wstETHmainnet.balanceOf(address(alice)), 0);
        assertApproxEqAbs(weEthInstance.balanceOf(address(alice)), weEthInstance.getWeETHByeETH(eETHAmountFromWstETH), 4);
        assertApproxEqAbs(stEth.balanceOf(address(etherFiRestakerInstance)), protocolSeETHBeforeDeposit + 5 ether, 4);

        // deposit with insufficient balance
        permitInput = createPermitInput(2, address(depositAdapterInstance), 1 ether, wstETHmainnet.nonces(alice), 2**256 - 1, wstETHmainnet.DOMAIN_SEPARATOR());
        liquifierPermitInput = ILiquifier.PermitInput({value: permitInput.value, deadline: permitInput.deadline, v: permitInput.v, r: permitInput.r, s: permitInput.s});
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        depositAdapterInstance.depositWstETHForWeETHWithPermit(1 ether, bob, liquifierPermitInput);
    }

    function test_DepositStETHWithoutPermit() public {
        stEth.submit{value: 2 ether}(address(0));

        // no approval -> revert
        vm.expectRevert("ALLOWANCE_EXCEEDED");
        depositAdapterInstance.depositStETHForWeETH(1 ether, address(0));

        // zero amount -> revert
        stEth.approve(address(depositAdapterInstance), 1 ether);
        vm.expectRevert();
        depositAdapterInstance.depositStETHForWeETH(0, address(0));

        // valid deposit
        uint256 protocolStETHBeforeDeposit = stEth.balanceOf(address(etherFiRestakerInstance));
        uint256 stEthBalanceBeforeDeposit = stEth.balanceOf(address(alice));
        uint256 eETHAmountFromStETH = liquifierInstance.quoteByDiscountedValue(address(stEth), 1 ether);

        stEth.approve(address(depositAdapterInstance), 1 ether);
        depositAdapterInstance.depositStETHForWeETH(1 ether, bob);

        assertApproxEqAbs(stEth.balanceOf(address(alice)), stEthBalanceBeforeDeposit - 1 ether, 3);
        assertApproxEqAbs(weEthInstance.balanceOf(address(alice)), weEthInstance.getWeETHByeETH(eETHAmountFromStETH), 3);
        assertApproxEqAbs(stEth.balanceOf(address(etherFiRestakerInstance)), protocolStETHBeforeDeposit + 1 ether, 3);

        // larger deposit
        stEth.submit{value: 5000 ether}(address(0));

        protocolStETHBeforeDeposit = stEth.balanceOf(address(etherFiRestakerInstance));
        stEth.approve(address(depositAdapterInstance), 5000 ether);
        depositAdapterInstance.depositStETHForWeETH(5000 ether, bob);

        assertApproxEqAbs(stEth.balanceOf(address(etherFiRestakerInstance)), protocolStETHBeforeDeposit + 5000 ether, 3);
    }

    function test_DepositWstETHWithoutPermit() public {
        stEth.submit{value: 5 ether}(address(0));
        stEth.approve(address(wstETHmainnet), 5 ether);
        uint256 wstETHAmount = wstETHmainnet.wrap(5 ether);

        // no approval -> revert
        vm.expectRevert("ERC20: transfer amount exceeds allowance");
        depositAdapterInstance.depositWstETHForWeETH(wstETHAmount, bob);

        // valid deposit
        uint256 protocolStETHBeforeDeposit = stEth.balanceOf(address(etherFiRestakerInstance));
        uint256 eETHAmountFromWstETH = liquifierInstance.quoteByDiscountedValue(address(stEth), 5 ether);

        IERC20Upgradeable(address(wstETHmainnet)).approve(address(depositAdapterInstance), wstETHAmount);
        depositAdapterInstance.depositWstETHForWeETH(wstETHAmount, bob);

        assertEq(wstETHmainnet.balanceOf(address(alice)), 0);
        assertApproxEqAbs(weEthInstance.balanceOf(address(alice)), weEthInstance.getWeETHByeETH(eETHAmountFromWstETH), 6);
        assertApproxEqAbs(stEth.balanceOf(address(etherFiRestakerInstance)), protocolStETHBeforeDeposit + 5 ether, 6);

        // deposit with insufficient balance
        IERC20Upgradeable(address(wstETHmainnet)).approve(address(depositAdapterInstance), 1 ether);
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        depositAdapterInstance.depositWstETHForWeETH(1 ether, bob);
    }

    function test_DepositStETHWithoutPermit_EmitsEvent() public {
        stEth.submit{value: 2 ether}(address(0));
        stEth.approve(address(depositAdapterInstance), 1 ether);

        vm.expectEmit(true, false, false, false, address(depositAdapterInstance));
        emit DepositAdapter.AdapterDeposit(alice, 0, DepositAdapter.SourceOfFunds.STETH, bob);
        depositAdapterInstance.depositStETHForWeETH(1 ether, bob);
    }

    function test_DepositStETHWithoutPermit_PartialApproval() public {
        stEth.submit{value: 5 ether}(address(0));

        // approve less than deposit amount
        stEth.approve(address(depositAdapterInstance), 0.5 ether);
        vm.expectRevert("ALLOWANCE_EXCEEDED");
        depositAdapterInstance.depositStETHForWeETH(1 ether, address(0));

        // approve exact amount, deposit succeeds
        stEth.approve(address(depositAdapterInstance), 1 ether);
        uint256 weEthBefore = weEthInstance.balanceOf(alice);
        depositAdapterInstance.depositStETHForWeETH(1 ether, address(0));
        assertGt(weEthInstance.balanceOf(alice), weEthBefore);
    }

    function test_DepositStETHWithoutPermit_MultipleDeposits() public {
        stEth.submit{value: 10 ether}(address(0));

        // first deposit
        stEth.approve(address(depositAdapterInstance), 3 ether);
        uint256 weEthAmount1 = depositAdapterInstance.depositStETHForWeETH(3 ether, address(0));
        assertGt(weEthAmount1, 0);

        // second deposit from same user
        uint256 weEthBefore = weEthInstance.balanceOf(alice);
        stEth.approve(address(depositAdapterInstance), 2 ether);
        uint256 weEthAmount2 = depositAdapterInstance.depositStETHForWeETH(2 ether, bob);
        assertGt(weEthAmount2, 0);
        assertApproxEqAbs(weEthInstance.balanceOf(alice), weEthBefore + weEthAmount2, 3);
    }

    function test_DepositStETHWithoutPermit_ReturnValue() public {
        stEth.submit{value: 2 ether}(address(0));
        stEth.approve(address(depositAdapterInstance), 1 ether);

        uint256 eETHAmountFromStETH = liquifierInstance.quoteByDiscountedValue(address(stEth), 1 ether);
        uint256 expectedWeETH = weEthInstance.getWeETHByeETH(eETHAmountFromStETH);

        uint256 weEthAmount = depositAdapterInstance.depositStETHForWeETH(1 ether, address(0));
        assertApproxEqAbs(weEthAmount, expectedWeETH, 3);
        assertApproxEqAbs(weEthInstance.balanceOf(alice), weEthAmount, 0);
    }

    function test_DepositStETHWithoutPermit_NoResidualBalance() public {
        stEth.submit{value: 2 ether}(address(0));
        stEth.approve(address(depositAdapterInstance), 1 ether);

        uint256 adapterStEthBefore = stEth.balanceOf(address(depositAdapterInstance));
        depositAdapterInstance.depositStETHForWeETH(1 ether, address(0));

        // adapter should not hold stETH or weETH after the deposit
        assertApproxEqAbs(stEth.balanceOf(address(depositAdapterInstance)), adapterStEthBefore, 2);
        assertEq(weEthInstance.balanceOf(address(depositAdapterInstance)), 0);
    }

    function test_DepositStETHWithoutPermit_DifferentReferrals() public {
        stEth.submit{value: 3 ether}(address(0));

        // zero address referral
        stEth.approve(address(depositAdapterInstance), 1 ether);
        uint256 weEthAmount1 = depositAdapterInstance.depositStETHForWeETH(1 ether, address(0));
        assertGt(weEthAmount1, 0);

        // bob as referral
        stEth.approve(address(depositAdapterInstance), 1 ether);
        uint256 weEthAmount2 = depositAdapterInstance.depositStETHForWeETH(1 ether, bob);
        assertGt(weEthAmount2, 0);

        // self-referral
        stEth.approve(address(depositAdapterInstance), 1 ether);
        uint256 weEthAmount3 = depositAdapterInstance.depositStETHForWeETH(1 ether, alice);
        assertGt(weEthAmount3, 0);
    }

    function test_DepositWstETHWithoutPermit_EmitsEvent() public {
        stEth.submit{value: 2 ether}(address(0));
        stEth.approve(address(wstETHmainnet), 2 ether);
        uint256 wstETHAmount = wstETHmainnet.wrap(2 ether);

        IERC20Upgradeable(address(wstETHmainnet)).approve(address(depositAdapterInstance), wstETHAmount);

        vm.expectEmit(true, false, false, false, address(depositAdapterInstance));
        emit DepositAdapter.AdapterDeposit(alice, 0, DepositAdapter.SourceOfFunds.WSTETH, bob);
        depositAdapterInstance.depositWstETHForWeETH(wstETHAmount, bob);
    }

    function test_DepositWstETHWithoutPermit_PartialApproval() public {
        stEth.submit{value: 5 ether}(address(0));
        stEth.approve(address(wstETHmainnet), 5 ether);
        uint256 wstETHAmount = wstETHmainnet.wrap(5 ether);

        // approve less than deposit amount
        IERC20Upgradeable(address(wstETHmainnet)).approve(address(depositAdapterInstance), wstETHAmount / 2);
        vm.expectRevert("ERC20: transfer amount exceeds allowance");
        depositAdapterInstance.depositWstETHForWeETH(wstETHAmount, bob);

        // approve exact amount, deposit succeeds
        IERC20Upgradeable(address(wstETHmainnet)).approve(address(depositAdapterInstance), wstETHAmount);
        uint256 weEthBefore = weEthInstance.balanceOf(alice);
        depositAdapterInstance.depositWstETHForWeETH(wstETHAmount, bob);
        assertGt(weEthInstance.balanceOf(alice), weEthBefore);
    }

    function test_DepositWstETHWithoutPermit_MultipleDeposits() public {
        stEth.submit{value: 10 ether}(address(0));
        stEth.approve(address(wstETHmainnet), 10 ether);
        uint256 wstETHAmount = wstETHmainnet.wrap(10 ether);

        // first deposit - half
        uint256 firstDeposit = wstETHAmount / 2;
        IERC20Upgradeable(address(wstETHmainnet)).approve(address(depositAdapterInstance), firstDeposit);
        uint256 weEthAmount1 = depositAdapterInstance.depositWstETHForWeETH(firstDeposit, address(0));
        assertGt(weEthAmount1, 0);

        // second deposit - remaining
        uint256 remaining = wstETHmainnet.balanceOf(alice);
        uint256 weEthBefore = weEthInstance.balanceOf(alice);
        IERC20Upgradeable(address(wstETHmainnet)).approve(address(depositAdapterInstance), remaining);
        uint256 weEthAmount2 = depositAdapterInstance.depositWstETHForWeETH(remaining, bob);
        assertGt(weEthAmount2, 0);
        assertApproxEqAbs(weEthInstance.balanceOf(alice), weEthBefore + weEthAmount2, 3);
    }

    function test_DepositWstETHWithoutPermit_ReturnValue() public {
        stEth.submit{value: 5 ether}(address(0));
        stEth.approve(address(wstETHmainnet), 5 ether);
        uint256 wstETHAmount = wstETHmainnet.wrap(5 ether);

        uint256 eETHAmountFromWstETH = liquifierInstance.quoteByDiscountedValue(address(stEth), 5 ether);
        uint256 expectedWeETH = weEthInstance.getWeETHByeETH(eETHAmountFromWstETH);

        IERC20Upgradeable(address(wstETHmainnet)).approve(address(depositAdapterInstance), wstETHAmount);
        uint256 weEthAmount = depositAdapterInstance.depositWstETHForWeETH(wstETHAmount, address(0));
        assertApproxEqAbs(weEthAmount, expectedWeETH, 6);
        assertApproxEqAbs(weEthInstance.balanceOf(alice), weEthAmount, 0);
    }

    function test_DepositWstETHWithoutPermit_NoResidualBalance() public {
        stEth.submit{value: 5 ether}(address(0));
        stEth.approve(address(wstETHmainnet), 5 ether);
        uint256 wstETHAmount = wstETHmainnet.wrap(5 ether);

        uint256 adapterStEthBefore = stEth.balanceOf(address(depositAdapterInstance));
        uint256 adapterWstEthBefore = IERC20Upgradeable(address(wstETHmainnet)).balanceOf(address(depositAdapterInstance));

        IERC20Upgradeable(address(wstETHmainnet)).approve(address(depositAdapterInstance), wstETHAmount);
        depositAdapterInstance.depositWstETHForWeETH(wstETHAmount, bob);

        // adapter should not hold stETH, wstETH, or weETH after the deposit
        assertApproxEqAbs(stEth.balanceOf(address(depositAdapterInstance)), adapterStEthBefore, 2);
        assertEq(IERC20Upgradeable(address(wstETHmainnet)).balanceOf(address(depositAdapterInstance)), adapterWstEthBefore);
        assertEq(weEthInstance.balanceOf(address(depositAdapterInstance)), 0);
    }

    function test_DepositWstETHWithoutPermit_DifferentReferrals() public {
        stEth.submit{value: 6 ether}(address(0));
        stEth.approve(address(wstETHmainnet), 6 ether);
        uint256 wstETHAmount = wstETHmainnet.wrap(6 ether);
        uint256 perDeposit = wstETHAmount / 3;

        // zero address referral
        IERC20Upgradeable(address(wstETHmainnet)).approve(address(depositAdapterInstance), perDeposit);
        uint256 weEthAmount1 = depositAdapterInstance.depositWstETHForWeETH(perDeposit, address(0));
        assertGt(weEthAmount1, 0);

        // bob as referral
        IERC20Upgradeable(address(wstETHmainnet)).approve(address(depositAdapterInstance), perDeposit);
        uint256 weEthAmount2 = depositAdapterInstance.depositWstETHForWeETH(perDeposit, bob);
        assertGt(weEthAmount2, 0);

        // self-referral
        IERC20Upgradeable(address(wstETHmainnet)).approve(address(depositAdapterInstance), perDeposit);
        uint256 weEthAmount3 = depositAdapterInstance.depositWstETHForWeETH(perDeposit, alice);
        assertGt(weEthAmount3, 0);
    }

    function test_DepositPermitExpired() public {
        stEth.submit{value: 2 ether}(address(0));

        // valid input
        uint256 protocolStETHBeforeDeposit = stEth.balanceOf(address(etherFiRestakerInstance));
        uint256 stEthBalanceBeforeDeposit = stEth.balanceOf(address(alice));
        
        ILiquidityPool.PermitInput memory permitInput = createPermitInput(
            2,
            address(depositAdapterInstance),
            2 ether,
            stEth.nonces(alice),
            2 ** 32 - 1,
            stEth.DOMAIN_SEPARATOR()
        );
        
        ILiquifier.PermitInput memory liquifierPermitInput = ILiquifier.PermitInput({
            value: permitInput.value,
            deadline: permitInput.deadline,
            v: permitInput.v,
            r: permitInput.r,
            s: permitInput.s
        });


        uint256 eETHAmountFromStETH = liquifierInstance.quoteByDiscountedValue(address(stEth), 1 ether);
        //record timestamp and deadline before warp
        uint blockTimestampBefore = block.timestamp;
        uint permitDeadline = permitInput.deadline;
        console.log("Block Timestamp Before:", blockTimestampBefore);
        console.log("Permit Deadline:", permitDeadline);
        depositAdapterInstance.depositStETHForWeETHWithPermit(1 ether, bob, liquifierPermitInput);

        assertApproxEqAbs(stEth.balanceOf(address(alice)), stEthBalanceBeforeDeposit - 1 ether, 3);
        assertApproxEqAbs(weEthInstance.balanceOf(address(alice)), weEthInstance.getWeETHByeETH(eETHAmountFromStETH), 3);
        assertApproxEqAbs(stEth.balanceOf(address(etherFiRestakerInstance)), protocolStETHBeforeDeposit + 1 ether, 3);

        vm.warp(block.timestamp + permitDeadline + 1 days);
        
        //record timestamp and deadline after warp
        uint blockTimestampAfter = block.timestamp;
        console.log("Block Timestamp After:", blockTimestampAfter);
        console.log("Permit Deadline:", permitDeadline);
        vm.expectRevert("PERMIT_EXPIRED");
        depositAdapterInstance.depositStETHForWeETHWithPermit(1 ether, bob, liquifierPermitInput);
    }
        
    function test_Receive() public {
        vm.expectRevert("ETH_TRANSFERS_NOT_ACCEPTED");
        address(depositAdapterInstance).call{value: 1 ether}("");

        address payable depositAdapterPayable = payable(address(depositAdapterInstance));
       
        vm.expectRevert("ETH_TRANSFERS_NOT_ACCEPTED");
        bool success = depositAdapterPayable.send(1 ether);
    }
}
