 // SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "../src/DepositAdapter.sol";
import "./TestSetup.sol";


contract DepositAdapterTest is TestSetup {

    event Deposit(address indexed sender, uint256 amount, uint8 source, address referral);

    DepositAdapter depositAdapterInstance;

    IWETH public wETH;
    IERC20Upgradeable public stETHmainnet;
    IwstETH public wstETHmainnet;

    function setUp() public {
        initializeRealisticFork(MAINNET_FORK);

        wETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
        stETHmainnet = IERC20Upgradeable(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);
        wstETHmainnet = IwstETH(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);

        // deploying+initializing the deposit adapter 
        address depositAdapterImpl = address(
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
        address depositAdapterProxy = address(new UUPSProxy(depositAdapterImpl, ""));
        depositAdapterInstance = DepositAdapter(payable(depositAdapterProxy));
        depositAdapterInstance.initialize();

        vm.startPrank(owner);

        // Caps are hit on mainnet
        liquifierInstance.updateDepositCap(address(stEth), 6000, 400000);

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
        vm.expectRevert(LiquidityPool.InvalidAmount.selector);
        depositAdapterInstance.depositStETHForWeETHWithPermit(0, address(0), liquifierPermitInput);

        // valid input
        uint256 protocolStETHBeforeDeposit = stEth.balanceOf(address(liquifierInstance));
        uint256 stEthBalanceBeforeDeposit = stEth.balanceOf(address(alice));
        permitInput = createPermitInput(2, address(depositAdapterInstance), 1 ether, stEth.nonces(alice), 2**256 - 1, stEth.DOMAIN_SEPARATOR());
        liquifierPermitInput = ILiquifier.PermitInput({value: permitInput.value, deadline: permitInput.deadline, v: permitInput.v, r: permitInput.r, s: permitInput.s});
        depositAdapterInstance.depositStETHForWeETHWithPermit(1 ether, bob, liquifierPermitInput);

        assertApproxEqAbs(stEth.balanceOf(address(alice)), stEthBalanceBeforeDeposit - 1 ether, 3);
        assertApproxEqAbs(weEthInstance.balanceOf(address(alice)), weEthInstance.getWeETHByeETH(1 ether), 3);
        assertApproxEqAbs(stEth.balanceOf(address(liquifierInstance)), protocolStETHBeforeDeposit + 1 ether, 3);

        // reusing the same permit
        vm.expectRevert("ALLOWANCE_EXCEEDED");
        depositAdapterInstance.depositStETHForWeETHWithPermit(1 ether, bob, liquifierPermitInput);


        // much larger deposit
        stEth.submit{value: 5000 ether}(address(0));

        protocolStETHBeforeDeposit = stEth.balanceOf(address(liquifierInstance));
        permitInput = createPermitInput(2, address(depositAdapterInstance), 5000 ether, stEth.nonces(alice), 2**256 - 1, stEth.DOMAIN_SEPARATOR());
        liquifierPermitInput = ILiquifier.PermitInput({value: permitInput.value, deadline: permitInput.deadline, v: permitInput.v, r: permitInput.r, s: permitInput.s});
        depositAdapterInstance.depositStETHForWeETHWithPermit(5000 ether, bob, liquifierPermitInput);

        assertApproxEqAbs(stEth.balanceOf(address(liquifierInstance)), protocolStETHBeforeDeposit + 5000 ether, 3);
    }

    function test_DepositWstETH() public {
        stEth.submit{value: 5 ether}(address(0));
        stEth.approve(address(wstETHmainnet), 5 ether);
        uint256 wstETHAmount = wstETHmainnet.wrap(5 ether);

        // valid wstETH deposit
        uint256 protocolSeETHBeforeDeposit = stEth.balanceOf(address(liquifierInstance));
        ILiquidityPool.PermitInput memory permitInput = createPermitInput(2, address(depositAdapterInstance), wstETHAmount, wstETHmainnet.nonces(alice), 2**256 - 1, wstETHmainnet.DOMAIN_SEPARATOR());
        ILiquifier.PermitInput memory liquifierPermitInput = ILiquifier.PermitInput({value: permitInput.value, deadline: permitInput.deadline, v: permitInput.v, r: permitInput.r, s: permitInput.s});

        depositAdapterInstance.depositWstETHForWeETHWithPermit(wstETHAmount, bob, liquifierPermitInput);

        assertEq(wstETHmainnet.balanceOf(address(alice)), 0);
        assertApproxEqAbs(weEthInstance.balanceOf(address(alice)), weEthInstance.getWeETHByeETH(5 ether), 3);
        assertApproxEqAbs(stEth.balanceOf(address(liquifierInstance)), protocolSeETHBeforeDeposit + 5 ether, 3);

        // deposit with insufficient balance
        permitInput = createPermitInput(2, address(depositAdapterInstance), 1 ether, wstETHmainnet.nonces(alice), 2**256 - 1, wstETHmainnet.DOMAIN_SEPARATOR());
        liquifierPermitInput = ILiquifier.PermitInput({value: permitInput.value, deadline: permitInput.deadline, v: permitInput.v, r: permitInput.r, s: permitInput.s});
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        depositAdapterInstance.depositWstETHForWeETHWithPermit(1 ether, bob, liquifierPermitInput);
    }
}
