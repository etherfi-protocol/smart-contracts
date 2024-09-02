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

        vm.startPrank(alice);
        stEth.submit{value: 10 ether}(address(0));
        stEth.approve(address(liquifierInstance), 10 ether);
        liquifierInstance.depositWithERC20(address(stEth), 10 ether, address(0));
        vm.stopPrank();

        assertGe(eETHInstance.balanceOf(alice), 10 ether - 0.1 ether);
    }

    function test_deopsit_stEth_and_swap() internal {
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

    function test_deopsit_stEth_with_explicit_permit() public {
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

    function test_withdrawal_of_non_restaked_stEth() public {
        test_deposit_stEth();
        
        uint256 lpTvl = liquidityPoolInstance.getTotalPooledEther();
        uint256 lpBalance = address(liquidityPoolInstance).balance;
        uint256 liquifierStEthTvl = liquifierInstance.getTotalPooledEther(address(stEth));
        uint256 liquifierBalance = address(liquifierInstance).balance;

        vm.prank(alice);        
        uint256[] memory reqIds = liquifierInstance.stEthRequestWithdrawal(10 ether);

        assertApproxEqAbs(liquifierInstance.getTotalPooledEther(address(stEth)), liquifierStEthTvl, 1);

        bytes32 FINALIZE_ROLE = liquifierInstance.lidoWithdrawalQueue().FINALIZE_ROLE();
        address finalize_role = liquifierInstance.lidoWithdrawalQueue().getRoleMember(FINALIZE_ROLE, 0);

        // The redemption is approved by the Lido
        vm.startPrank(finalize_role);
        uint256 currentRate = stEth.getTotalPooledEther() * 1e27 / stEth.getTotalShares();
        (uint256 ethToLock, uint256 sharesToBurn) = liquifierInstance.lidoWithdrawalQueue().prefinalize(reqIds, currentRate);
        liquifierInstance.lidoWithdrawalQueue().finalize(reqIds[reqIds.length-1], currentRate);
        vm.stopPrank();

        // The ether.fi admin claims the finalized withdrawal, which sends the ETH to the liquifier contract
        uint256 lastCheckPointIndex = liquifierInstance.lidoWithdrawalQueue().getLastCheckpointIndex();
        uint256[] memory hints = liquifierInstance.lidoWithdrawalQueue().findCheckpointHints(reqIds, 1, lastCheckPointIndex);
        
        vm.prank(alice);
        liquifierInstance.stEthClaimWithdrawals(reqIds, hints);

        assertApproxEqAbs(liquifierInstance.getTotalPooledEther(address(stEth)), liquifierStEthTvl - 10 ether, 1 gwei);
        assertApproxEqAbs(address(liquifierInstance).balance, liquifierBalance + 10 ether, 1 gwei);

        // The ether.fi admin withdraws the ETH from the liquifier contract to the liquidity pool contract
        vm.prank(alice);
        liquifierInstance.withdrawEther();

        assertApproxEqAbs(address(liquidityPoolInstance).balance, lpBalance + 10 ether + liquifierBalance, 1 gwei);
    }

    function test_stEthRequestWithdrawal() public {
        test_deposit_stEth();

        vm.startPrank(alice);        
        liquifierInstance.stEthRequestWithdrawal(1 ether);
        liquifierInstance.stEthRequestWithdrawal(5 ether);
        liquifierInstance.stEthRequestWithdrawal();
        vm.stopPrank();
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

    function test_pancacke_wbETH_swap() internal {
        initializeRealisticFork(MAINNET_FORK);
        setUpLiquifier(MAINNET_FORK);

        uint256 lpTvl = liquidityPoolInstance.getTotalPooledEther();
        uint256 lpBalance = address(liquidityPoolInstance).balance;

        uint256 inputAmount = 50 ether;

        vm.startPrank(alice);

        vm.expectRevert("Too little received");
        liquifierInstance.pancakeSwapForEth(address(wbEth), inputAmount, 500, 2 * inputAmount, 3600);

        uint256 beforeTVL = liquidityPoolInstance.getTotalPooledEther();
        uint256 beforeBalance = address(liquifierInstance).balance;

        uint256 exchangeRate = IWBETH(address(wbEth)).exchangeRate();
        uint256 maxSlippageBp = 50; // 0.5%
        uint256 minOutput = (exchangeRate * inputAmount * (10000 - maxSlippageBp)) / 10000 / 1e18;
        liquifierInstance.pancakeSwapForEth(address(wbEth), inputAmount, 500, minOutput, 3600);

        assertGe(address(liquifierInstance).balance, beforeBalance + minOutput);
        assertEq(liquidityPoolInstance.getTotalPooledEther(), beforeTVL); // does not change till Oracle updates

        vm.stopPrank();
    }

    function test_pancacke_cbETH_swap() internal {
        initializeRealisticFork(MAINNET_FORK);
        setUpLiquifier(MAINNET_FORK);

        uint256 lpTvl = liquidityPoolInstance.getTotalPooledEther();
        uint256 lpBalance = address(liquidityPoolInstance).balance;

        uint256 inputAmount = 50 ether;

        vm.startPrank(alice);

        vm.expectRevert("Too little received");
        liquifierInstance.pancakeSwapForEth(address(cbEth), inputAmount, 500, 2 * inputAmount, 3600);

        uint256 beforeTVL = liquidityPoolInstance.getTotalPooledEther();
        uint256 beforeBalance = address(liquifierInstance).balance;

        uint256 exchangeRate = IWBETH(address(cbEth)).exchangeRate();
        uint256 maxSlippageBp = 50; // 0.5%
        uint256 minOutput = (exchangeRate * inputAmount * (10000 - maxSlippageBp)) / 10000 / 1e18;
        liquifierInstance.pancakeSwapForEth(address(cbEth), inputAmount, 500, minOutput, 3600);

        assertGe(address(liquifierInstance).balance, beforeBalance + minOutput);
        assertEq(liquidityPoolInstance.getTotalPooledEther(), beforeTVL); // does not change till Oracle updates

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

    function test_swapEEthForStEth_mainnet() public {
        initializeRealisticFork(MAINNET_FORK);
        setUpLiquifier(MAINNET_FORK);

        vm.deal(alice, 100 ether);
        vm.startPrank(alice);
        liquidityPoolInstance.deposit{value: 100 ether}();

        eETHInstance.approve(address(liquifierInstance), 50 ether);

        uint256 beforeTVL = liquidityPoolInstance.getTotalPooledEther();
        uint256 beforeLiquifierTotalPooledEther = liquifierInstance.getTotalPooledEther();

        liquifierInstance.swapEEthForStEth(50 ether);
        vm.stopPrank();

        uint256 afterTVL = liquidityPoolInstance.getTotalPooledEther();
        uint256 afterLiquifierTotalPooledEther = liquifierInstance.getTotalPooledEther();

        assertApproxEqAbs(afterTVL, beforeTVL, 2);
        assertApproxEqAbs(beforeLiquifierTotalPooledEther, afterLiquifierTotalPooledEther, 2);
    }

    function test_withdrawEEth() public {
        test_swapEEthForStEth_mainnet();

        _upgrade_liquidity_pool_contract();

        uint256 beforeTVL = liquidityPoolInstance.getTotalPooledEther();
        uint256 beforeLiquifierTotalPooledEther = liquifierInstance.getTotalPooledEther();

        vm.prank(alice);
        liquifierInstance.withdrawEEth(10 ether);

        uint256 afterTVL = liquidityPoolInstance.getTotalPooledEther();
        uint256 afterLiquifierTotalPooledEther = liquifierInstance.getTotalPooledEther();

        assertApproxEqAbs(int256(afterTVL) - int256(beforeTVL), int256(afterLiquifierTotalPooledEther) - int256(beforeLiquifierTotalPooledEther), 1);
    }
}
