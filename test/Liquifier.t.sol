// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "forge-std/Test.sol";

import "@openzeppelin-upgradeable/contracts/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";

import "../src/eigenlayer-interfaces/IDelegationManager.sol";
import "../src/eigenlayer-interfaces/IStrategyManager.sol";

contract DummyERC20 is ERC20BurnableUpgradeable {
    
    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) public {
        _burn(from, amount);
    }
}

interface IWBETH {
    function exchangeRate() external view returns (uint256);
    function deposit(address referral) external payable;
}

contract LiquifierTest is TestSetup {

    uint256 public testnetFork;

    DummyERC20 public dummyToken;
    address public l1SyncPool = address(100000);

    function setUp() public {
    }

    function _setUp(uint8 forkEnum) internal {

        initializeTestingFork(forkEnum);
        setUpLiquifier(forkEnum);

        _enable_deposit(address(stEthStrategy));
        _enable_deposit(address(wbEthStrategy));

        vm.startPrank(owner);
        liquifierInstance.registerToken(address(stEth), address(stEthStrategy), true, 0, false); // 50 ether timeBoundCap, 1000 ether total cap
        if (forkEnum == MAINNET_FORK) {
            liquifierInstance.registerToken(address(cbEth), address(cbEthStrategy), true, 0, false);
            liquifierInstance.registerToken(address(wbEth), address(wbEthStrategy), true, 0, false);
        }

        vm.stopPrank();
    }

    function test_deposit_above_cap() public {
        test_deposit_stEth();

        vm.startPrank(alice);
        stEth.submit{value: 20 ether}(address(0));
        stEth.approve(address(liquifierInstance), 20 ether);

        vm.expectRevert("BucketRateLimiter: rate limit exceeded");
        liquifierInstance.depositWithERC20(address(stEth), 20 ether, address(0));

        vm.stopPrank();
    }

    function test_deposit_stEth() public {
        initializeRealisticFork(MAINNET_FORK);
        setUpLiquifier(MAINNET_FORK);

        vm.deal(alice, 100 ether);

        vm.startPrank(liquifierInstance.owner());
        liquifierInstance.updateQuoteStEthWithCurve(true);
        liquifierInstance.updateDiscountInBasisPoints(address(stEth), 500); // 5%
        vm.stopPrank();

        vm.startPrank(alice);
        stEth.submit{value: 10 ether}(address(0));
        stEth.approve(address(liquifierInstance), 10 ether);
        liquifierInstance.depositWithERC20(address(stEth), 10 ether, address(0));
        vm.stopPrank();

        assertApproxEqAbs(eETHInstance.balanceOf(alice), 10 ether - 0.5 ether, 0.1 ether);

        uint256 aliceQuotedEETH = liquifierInstance.quoteByDiscountedValue(address(stEth), 10 ether);
        // alice will actually receive 1 wei less due to the infamous 1 wei rounding corner case
        assertApproxEqAbs(eETHInstance.balanceOf(alice), aliceQuotedEETH, 1);
    }

    function test_deposit_stEth_and_swap() internal {
        _setUp(MAINNET_FORK);
        uint256 lpTvl = liquidityPoolInstance.getTotalPooledEther();
        vm.deal(alice, 100 ether);
        assertEq(eETHInstance.balanceOf(alice), 0);
        assertEq(liquifierInstance.getTotalPooledEther(), 0);

        vm.startPrank(alice);
        stEth.submit{value: 20 ether}(address(0));
        stEth.approve(address(liquifierInstance), 2 ether);
        liquifierInstance.depositWithERC20(address(stEth), 2 ether, address(0));

        assertGe(eETHInstance.balanceOf(alice), 2 ether - 0.1 ether);
        assertGe(liquifierInstance.getTotalPooledEther(), 2 ether - 0.1 ether);
        assertGe(liquidityPoolInstance.getTotalPooledEther(), lpTvl + 2 ether - 0.1 ether);
        assertEq(address(liquifierInstance).balance, 0 ether);

        lpTvl = liquidityPoolInstance.getTotalPooledEther();
    }

    function test_deposit_stEth_with_explicit_permit() public {
        initializeRealisticFork(MAINNET_FORK);
        setUpLiquifier(MAINNET_FORK);

        vm.deal(alice, 100 ether);

        assertEq(eETHInstance.balanceOf(alice), 0);

        vm.startPrank(alice);
        
        // Alice minted 2 stETH
        stEth.submit{value: 2 ether}(address(0));

        // But, she noticed that eETH is a much better choice 
        // and decided to convert her stETH to eETH
        
        // Deposit 1 stETH after approvals
        stEth.approve(address(liquifierInstance), 1 ether - 1);
        vm.expectRevert("ALLOWANCE_EXCEEDED");
        liquifierInstance.depositWithERC20(address(stEth), 1 ether, address(0));

        stEth.approve(address(liquifierInstance), 1 ether);
        liquifierInstance.depositWithERC20(address(stEth), 1 ether, address(0));

        // Deposit 1 stETH with the approval signature
        ILiquidityPool.PermitInput memory permitInput = createPermitInput(2, address(liquifierInstance), 1 ether - 1, stEth.nonces(alice), 2**256 - 1, stEth.DOMAIN_SEPARATOR());
        ILiquifier.PermitInput memory permitInput2 = ILiquifier.PermitInput({value: permitInput.value, deadline: permitInput.deadline, v: permitInput.v, r: permitInput.r, s: permitInput.s});
        vm.expectRevert("ALLOWANCE_EXCEEDED");
        liquifierInstance.depositWithERC20WithPermit(address(stEth), 1 ether, address(0), permitInput2);

        permitInput = createPermitInput(2, address(liquifierInstance), 1 ether, stEth.nonces(alice), 2**256 - 1, stEth.DOMAIN_SEPARATOR());
        permitInput2 = ILiquifier.PermitInput({value: permitInput.value, deadline: permitInput.deadline, v: permitInput.v, r: permitInput.r, s: permitInput.s});
        liquifierInstance.depositWithERC20WithPermit(address(stEth), 1 ether, address(0), permitInput2);
    }

    function _enable_deposit(address _strategy) internal {
        IEigenLayerStrategyTVLLimits strategyTVLLimits = IEigenLayerStrategyTVLLimits(_strategy);

        address role = strategyTVLLimits.pauserRegistry().unpauser();
        vm.startPrank(role);
        eigenLayerStrategyManager.unpause(0);
        strategyTVLLimits.unpause(0);
        strategyTVLLimits.setTVLLimits(1_000_000_0 ether, 1_000_000_0 ether);
        vm.stopPrank();
    }

    function _setup_L1SyncPool() internal {
        initializeRealisticFork(MAINNET_FORK);
        setUpLiquifier(MAINNET_FORK);

        vm.startPrank(owner);
        dummyToken = new DummyERC20();
        liquifierInstance.registerToken(address(dummyToken), address(0), true, 0, true);
        vm.stopPrank();

        vm.warp(block.timestamp + 20);

        l1SyncPool = liquifierInstance.l1SyncPool();
    }

    function _fast_sync_from_L2_to_L1(address _token, uint256 _x) internal {
        vm.prank(owner);
        DummyERC20(_token).mint(l1SyncPool, _x);

        assertTrue(liquifierInstance.isTokenWhitelisted(_token));

        vm.startPrank(l1SyncPool);
        DummyERC20(_token).approve(address(liquifierInstance), _x);
        liquifierInstance.depositWithERC20(_token, _x, address(0));
        vm.stopPrank();
    }

    function _slow_sync_form_L2_to_L1(uint256 _x) internal {
        vm.startPrank(l1SyncPool);
        liquifierInstance.unwrapL2Eth{value: _x}(address(dummyToken));
        DummyERC20(dummyToken).burn(_x);
        vm.stopPrank();
    }

    function test_fast_sync_with_random_token_fail() public {
        _setup_L1SyncPool();

        vm.startPrank(owner);
        uint256 _x = 1 ether;
        DummyERC20 randomToken = new DummyERC20();
        randomToken.mint(alice, _x);
        vm.stopPrank();

        vm.startPrank(l1SyncPool);
        dummyToken.approve(address(liquifierInstance), _x);
        vm.expectRevert("NOT_ALLOWED");
        liquifierInstance.depositWithERC20(address(randomToken), _x, address(0));
        vm.stopPrank();
    }

    function test_fast_sync_by_rando_fail() public {
        _setup_L1SyncPool();

        // Alice somehow got the dummy token and tried to deposit it
        uint256 _x = 1 ether;
        vm.prank(owner);
        dummyToken.mint(alice, _x);

        vm.startPrank(alice);
        dummyToken.approve(address(liquifierInstance), _x);
        vm.expectRevert("NOT_ALLOWED");
        liquifierInstance.depositWithERC20(address(dummyToken), _x, address(0));
        vm.stopPrank();
    }
    
    function test_slow_sync_with_random_token_fail() public {
        test_fast_sync_success();

        vm.prank(owner);
        DummyERC20 randomToken = new DummyERC20();

        uint256 x = 5 ether;
        // for some reasons only 5 ether arrived this time :)
        vm.deal(l1SyncPool, x);

        vm.startPrank(l1SyncPool);
        vm.expectRevert(Liquifier.NotSupportedToken.selector);
        liquifierInstance.unwrapL2Eth(address(randomToken));
        vm.stopPrank();
    }

    function test_fast_sync_success() public {
        _setup_L1SyncPool();

        uint256 prevTotalDummy = dummyToken.totalSupply();
        uint256 prevLiquifierBalance = address(liquifierInstance).balance;
        uint256 prevTotalPooledEther = liquifierInstance.getTotalPooledEther();

        // L2 layer notifies that eETH (equivalent to X ETH amount) is minted
        uint256 x = 10 ether;
        _fast_sync_from_L2_to_L1(address(dummyToken), x);

        assertEq(dummyToken.totalSupply(), dummyToken.balanceOf(address(liquifierInstance)));
        assertEq(dummyToken.totalSupply(), prevTotalDummy + x);
        assertEq(address(liquifierInstance).balance, prevLiquifierBalance);
        assertEq(liquifierInstance.getTotalPooledEther(), prevTotalPooledEther + x);
        assertEq(liquifierInstance.getTotalPooledEther(address(dummyToken)), x);
    }

    function test_slow_sync_success() public {
        test_fast_sync_success();

        uint256 prevTotalDummy = dummyToken.totalSupply();
        uint256 prevLiquifierBalance = address(liquifierInstance).balance;
        uint256 prevTotalPooledEther = liquifierInstance.getTotalPooledEther();

        uint256 x = 5 ether;
        // for some reasons only 5 ether arrived this time :)
        vm.deal(l1SyncPool, x);

        _slow_sync_form_L2_to_L1(x);

        assertEq(dummyToken.totalSupply(), dummyToken.balanceOf(address(liquifierInstance)));
        assertEq(dummyToken.totalSupply(), prevTotalDummy - x);
        assertEq(address(liquifierInstance).balance, prevLiquifierBalance + x);
        assertEq(liquifierInstance.getTotalPooledEther(), prevTotalPooledEther);

        uint256 y = 10 ether;
        _fast_sync_from_L2_to_L1(address(dummyToken), y);
    }

    function test_multiple_l2Eths() public {
        test_fast_sync_success();

        uint256 prevTotalPooledEther = liquifierInstance.getTotalPooledEther();

        vm.startPrank(owner);
        DummyERC20 dummyToken2 = new DummyERC20();
        liquifierInstance.registerToken(address(dummyToken2), address(0), true, 0, true);
        vm.stopPrank();

        uint256 x = 5 ether;
        _fast_sync_from_L2_to_L1(address(dummyToken2), x);

        assertEq(liquifierInstance.getTotalPooledEther(), prevTotalPooledEther + liquifierInstance.getTotalPooledEther(address(dummyToken2)));
    }

    function test_add_dummy_token_flag() public {
        initializeRealisticFork(MAINNET_FORK);

        bool isTokenWhitelisted = liquifierInstance.isTokenWhitelisted(address(stEth));
        uint256 getTotalPooledEther = liquifierInstance.getTotalPooledEther(address(stEth));

        // Do the upgrade
        setUpLiquifier(MAINNET_FORK);

        uint256 dustELWithdrawAmount = 0; 
        (uint128 strategyShare,,IStrategy strategy,,,,,,,,) = liquifierInstance.tokenInfos(address(stEth));
        dustELWithdrawAmount = liquifierInstance.quoteByFairValue(address(stEth), strategy.sharesToUnderlyingView(strategyShare));

        assertEq(liquifierInstance.isTokenWhitelisted(address(stEth)), isTokenWhitelisted);
        assertEq(liquifierInstance.isL2Eth(address(stEth)), false);
        // Accounting error resulted in `strategyShare` for stETH still having a value even though the withdrawal queue has been cleared
        assertEq(liquifierInstance.getTotalPooledEther(address(stEth)), getTotalPooledEther - dustELWithdrawAmount);
    }

    function test_pauser() public {
        initializeRealisticFork(MAINNET_FORK);
        setUpLiquifier(MAINNET_FORK);

        vm.startPrank(bob);
        vm.expectRevert(Liquifier.IncorrectRole.selector);
        liquifierInstance.pauseContract();
        vm.stopPrank();

        vm.startPrank(address(pauserInstance));
        liquifierInstance.pauseContract();
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert(Liquifier.IncorrectRole.selector);
        liquifierInstance.unPauseContract();
        vm.stopPrank();

        vm.prank(address(pauserInstance));
        liquifierInstance.unPauseContract();
    }

    function test_getTotalPooledEther() public {
        initializeRealisticFork(MAINNET_FORK);
        setUpLiquifier(MAINNET_FORK);

        liquidityPoolInstance.getTotalPooledEther();
        liquifierInstance.getTotalPooledEther();
    }


    function _swapEEthForStEth_mainnet() public {
        vm.deal(bob, 100 ether);
        vm.startPrank(bob);
        liquidityPoolInstance.deposit{value: 100 ether}();

        eETHInstance.approve(address(liquifierInstance), 50 ether);

        uint256 beforeTVL = liquidityPoolInstance.getTotalPooledEther();
        uint256 beforeLiquifierTotalPooledEther = liquifierInstance.getTotalPooledEther();
        uint256 totalValueOutOfLpBefore = liquidityPoolInstance.totalValueOutOfLp(); 
        uint256 totalValueInLpBefore = liquidityPoolInstance.totalValueInLp(); 
        uint256 preBalance = IERC20(liquifierInstance.lido()).balanceOf(address(liquifierInstance));
        liquifierInstance.swapEEthForStEth(50 ether);
        uint256 postBalance = IERC20(liquifierInstance.lido()).balanceOf(address(liquifierInstance));
        uint256 changeInBalance = preBalance - postBalance;
        uint256 afterTVL = liquidityPoolInstance.getTotalPooledEther();
        uint256 afterLiquifierTotalPooledEther = liquifierInstance.getTotalPooledEther();
        uint256 totalValueOutOfLpAfter = liquidityPoolInstance.totalValueOutOfLp();
        uint256 totalValueInLpAfter = liquidityPoolInstance.totalValueInLp();  
        vm.stopPrank();
        // Check LP eth balance remains same, eeth supply decreases, liquifier total pooled ether should decrease
        assertApproxEqAbs(IERC20(address(liquifierInstance.lido())).balanceOf(bob), changeInBalance, 1);
        assertApproxEqAbs(afterTVL + changeInBalance, beforeTVL, 1);
        assertApproxEqAbs(afterLiquifierTotalPooledEther + changeInBalance, beforeLiquifierTotalPooledEther, 1);
        assertApproxEqAbs(totalValueOutOfLpAfter, totalValueOutOfLpBefore, changeInBalance);
        assertApproxEqAbs(totalValueInLpAfter, totalValueInLpBefore, 1);
    }

    //same as no fees for whitelisted user
    function test_whitelisted() public {
        initializeRealisticFork(MAINNET_FORK);
        setUpLiquifier(MAINNET_FORK);
        vm.startPrank(superAdmin);
        roleRegistry.grantRole(liquifierInstance.EETH_STETH_SWAPPER(), bob);
        vm.stopPrank();
        _swapEEthForStEth_mainnet();
    }
}
