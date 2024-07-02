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
        liquifierInstance.registerToken(address(stEth), address(stEthStrategy), true, 0, 50, 1000, false); // 50 ether timeBoundCap, 1000 ether total cap
        if (forkEnum == MAINNET_FORK) {
            liquifierInstance.registerToken(address(cbEth), address(cbEthStrategy), true, 0, 50, 1000, false);
            liquifierInstance.registerToken(address(wbEth), address(wbEthStrategy), true, 0, 50, 1000, false);
        }
        vm.stopPrank();

        dummyToken = new DummyERC20();
    }

    function test_rando_deposit_fails() public {
        _setUp(MAINNET_FORK);

        vm.deal(alice, 100 ether);
        vm.startPrank(alice);
        vm.expectRevert("not allowed");
        payable(address(liquifierInstance)).call{value: 10 ether}("");
        vm.stopPrank();
    }

    function test_deposit_above_cap() public {
        initializeRealisticFork(MAINNET_FORK);
        setUpLiquifier(MAINNET_FORK);

        vm.deal(alice, 1000000000 ether);

        vm.startPrank(alice);
        stEth.submit{value: 100000 ether + 1 ether}(address(0));
        stEth.approve(address(liquifierInstance), 100000 ether);

        vm.expectRevert("CAPPED");
        liquifierInstance.depositWithERC20(address(stEth), 100000 ether, address(0));

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
        _setUp(MAINNET_FORK);
        
        uint256 lpTvl = liquidityPoolInstance.getTotalPooledEther();
        uint256 lpBalance = address(liquidityPoolInstance).balance;

        assertEq(eETHInstance.balanceOf(alice), 0);
        assertEq(liquifierInstance.getTotalPooledEther(), 0);

        vm.deal(alice, 100 ether);
        vm.startPrank(alice);        
        stEth.submit{value: 10 ether}(address(0));
        
        ILiquidityPool.PermitInput memory permitInput = createPermitInput(2, address(liquifierInstance), 10 ether, stEth.nonces(alice), 2**256 - 1, stEth.DOMAIN_SEPARATOR());
        ILiquifier.PermitInput memory permitInput2 = ILiquifier.PermitInput({value: permitInput.value, deadline: permitInput.deadline, v: permitInput.v, r: permitInput.r, s: permitInput.s});
        liquifierInstance.depositWithERC20WithPermit(address(stEth), 10 ether, address(0), permitInput2);

        // Aliice has 10 ether eETH
        // Total eETH TVL is 10 ether
        assertGe(eETHInstance.balanceOf(alice), 10 ether - 0.1 ether);
        assertGe(liquifierInstance.getTotalPooledEther(), 10 ether - 0.1 ether);
        assertGe(liquidityPoolInstance.getTotalPooledEther(), lpTvl + 10 ether - 0.1 ether);

        // The protocol admin initiates the redemption process for 3500 stETH
        uint256[] memory reqIds = liquifierInstance.stEthRequestWithdrawal();
        vm.stopPrank();

        assertGe(eETHInstance.balanceOf(alice), 10 ether - 0.1 ether);
        assertGe(liquifierInstance.getTotalPooledEther(), 10 ether - 0.1 ether);
        assertGe(liquidityPoolInstance.getTotalPooledEther(), lpTvl + 10 ether - 0.1 ether);

        bytes32 FINALIZE_ROLE = liquifierInstance.lidoWithdrawalQueue().FINALIZE_ROLE();
        address finalize_role = liquifierInstance.lidoWithdrawalQueue().getRoleMember(FINALIZE_ROLE, 0);

        // The redemption is approved by the Lido
        vm.startPrank(finalize_role);
        uint256 currentRate = stEth.getTotalPooledEther() * 1e27 / stEth.getTotalShares();
        (uint256 ethToLock, uint256 sharesToBurn) = liquifierInstance.lidoWithdrawalQueue().prefinalize(reqIds, currentRate);
        liquifierInstance.lidoWithdrawalQueue().finalize(reqIds[reqIds.length-1], currentRate);
        vm.stopPrank();

        assertGe(eETHInstance.balanceOf(alice), 10 ether - 0.1 ether);
        assertGe(liquifierInstance.getTotalPooledEther(), 10 ether - 0.1 ether);
        assertGe(liquidityPoolInstance.getTotalPooledEther(), lpTvl + 10 ether - 0.1 ether);

        // The ether.fi admin claims the finalized withdrawal, which sends the ETH to the liquifier contract
        vm.startPrank(alice);
        uint256 lastCheckPointIndex = liquifierInstance.lidoWithdrawalQueue().getLastCheckpointIndex();
        uint256[] memory hints = liquifierInstance.lidoWithdrawalQueue().findCheckpointHints(reqIds, 1, lastCheckPointIndex);
        liquifierInstance.stEthClaimWithdrawals(reqIds, hints);

        assertGe(eETHInstance.balanceOf(alice), 10 ether - 0.1 ether);
        assertGe(liquifierInstance.getTotalPooledEther(), 10 ether - 0.1 ether);
        assertGe(liquidityPoolInstance.getTotalPooledEther(), lpTvl + 10 ether - 0.1 ether);
        assertGe(address(liquidityPoolInstance).balance, lpBalance);

        // The ether.fi admin withdraws the ETH from the liquifier contract to the liquidity pool contract
        liquifierInstance.withdrawEther();
        vm.stopPrank();

        // the cycle completes
        assertGe(eETHInstance.balanceOf(alice), 10 ether - 0.1 ether);
        assertEq(liquifierInstance.getTotalPooledEther() / 100, 0);
        assertGe(liquidityPoolInstance.getTotalPooledEther(), lpTvl + 10 ether - 0.1 ether);
        assertGe(address(liquidityPoolInstance).balance + liquifierInstance.getTotalPooledEther(), lpBalance + 10 ether - 0.1 ether);

    }

    function test_withdrawal_of_restaked_wBETH_succeeds() internal {
        _setUp(MAINNET_FORK);

        _enable_deposit(address(wbEthStrategy));

        vm.deal(alice, 100 ether);
        vm.startPrank(alice);        
        wbEth.deposit{value: 20 ether}(address(0));
        wbEth.approve(address(eigenLayerStrategyManager), 20 ether);
        
        eigenLayerStrategyManager.depositIntoStrategy(wbEthStrategy, wbEthStrategy.underlyingToken(), 10 ether);

        IDelegationManager.Withdrawal memory queuedWithdrawal = _get_queued_withdrawal_of_restaked_LST_before_m2(wbEthStrategy);

        _complete_queued_withdrawal_V2(queuedWithdrawal, wbEthStrategy);

        uint256[] memory reqIds = liquifierInstance.stEthRequestWithdrawal();
        vm.stopPrank();

        _finalizeLidoWithdrawals(reqIds);
    }

    function test_erc20_queued_withdrawal_v2() public {
        initializeRealisticFork(MAINNET_FORK);
        setUpLiquifier(MAINNET_FORK);
       
        uint256 liquifierTVL = liquifierInstance.getTotalPooledEther();
        uint256 lpTvl = liquidityPoolInstance.getTotalPooledEther();

        // While this unit test works, after EL m2 upgrade,
        // this flow will be deprecated because setting 'wtihdrawer' != msg.sender won't be allowed within `queueWithdrawals`
        address actor = address(liquifierInstance);

        vm.deal(actor, 100 ether);
        vm.startPrank(actor);        
        stEth.submit{value: 1 ether}(address(0));

        stEth.approve(address(eigenLayerStrategyManager), 1 ether);
        eigenLayerStrategyManager.depositIntoStrategy(stEthStrategy, stEthStrategy.underlyingToken(), 1 ether);


        uint256[] memory strategyIndexes = new uint256[](1);
        IStrategy[] memory strategies = new IStrategy[](1);
        uint256[] memory shares = new uint256[](1);
        strategyIndexes[0] = 0;
        strategies[0] = stEthStrategy;
        shares[0] = stEthStrategy.shares(actor);

        //  Queue withdrawal
        IDelegationManager.QueuedWithdrawalParams[] memory queuedWithdrawalParams = new IDelegationManager.QueuedWithdrawalParams[](1);
        queuedWithdrawalParams[0] = IDelegationManager.QueuedWithdrawalParams({
            strategies: strategies,
            shares: shares,
            withdrawer: actor
        });
        
        IDelegationManager.Withdrawal[] memory queuedWithdrawals = new IDelegationManager.Withdrawal[](1);
        queuedWithdrawals[0] = IDelegationManager.Withdrawal({
            staker: actor,
            delegatedTo: address(0),
            withdrawer: actor,
            nonce: uint96(eigenLayerDelegationManager.cumulativeWithdrawalsQueued(actor)),
            startBlock: uint32(block.number),
            strategies: strategies,
            shares: shares
        });

        bytes32[] memory withdrawalRoots = eigenLayerDelegationManager.queueWithdrawals(queuedWithdrawalParams);
        bytes32 withdrawalRoot = withdrawalRoots[0];

        assertTrue(eigenLayerDelegationManager.pendingWithdrawals(withdrawalRoot));

        liquifierInstance.depositWithQueuedWithdrawal(queuedWithdrawals[0], address(0));
        vm.stopPrank();

        vm.roll(block.number + 7 days);

        IERC20[][] memory tokens = new IERC20[][](1);
        tokens[0] = new IERC20[](1);
        tokens[0][0] = stEthStrategy.underlyingToken();
        uint256[] memory middlewareTimesIndexes = new uint256[](1);
        middlewareTimesIndexes[0] = 0;
        bool[] memory receiveAsTokens = new bool[](1);
        receiveAsTokens[0] = true;

        vm.startPrank(owner);
        liquifierInstance.completeQueuedWithdrawals(queuedWithdrawals, tokens, middlewareTimesIndexes);
        vm.stopPrank();

    }

    function _get_queued_withdrawal_of_restaked_LST_before_m2(IStrategy strategy) internal returns (IDelegationManager.Withdrawal memory) {
        uint256[] memory strategyIndexes = new uint256[](1);
        IStrategy[] memory strategies = new IStrategy[](1);
        uint256[] memory shares = new uint256[](1);
        strategyIndexes[0] = 0;
        strategies[0] = strategy;
        shares[0] = strategy.shares(alice);

        uint32 startBlock = uint32(block.number);
        uint96 nonce = uint96(eigenLayerStrategyManager.numWithdrawalsQueued(alice));

        // Step 1 - Queued withdrawal
        bytes32 withdrawalRoot = eigenLayerStrategyManager.queueWithdrawal(strategyIndexes, strategies, shares, address(liquifierInstance), true);
        assertEq(eigenLayerStrategyManager.withdrawalRootPending(withdrawalRoot), true);
        vm.stopPrank();

        _perform_eigenlayer_upgrade();

        uint256 newNonce = eigenLayerDelegationManager.cumulativeWithdrawalsQueued(alice);

        vm.startPrank(alice);

        // Step 2 - Mint eETH
        IDelegationManager.Withdrawal memory queuedWithdrawal = IDelegationManager.Withdrawal({
            staker: alice,
            delegatedTo: address(0),
            withdrawer: address(liquifierInstance),
            nonce: newNonce,
            startBlock: startBlock,
            strategies: strategies,
            shares: shares
        });

        // Before migration
        vm.expectRevert("WrongQ");
        liquifierInstance.depositWithQueuedWithdrawal(queuedWithdrawal, address(0));

        IStrategyManager.DeprecatedStruct_QueuedWithdrawal[] memory withdrawalsToMigrate = new IStrategyManager.DeprecatedStruct_QueuedWithdrawal[](1);
        withdrawalsToMigrate[0] = IStrategyManager.DeprecatedStruct_QueuedWithdrawal({
            strategies: strategies,
            shares: shares,
            staker: alice,
            withdrawerAndNonce: IStrategyManager.DeprecatedStruct_WithdrawerAndNonce({
                withdrawer: address(liquifierInstance),
                nonce: nonce
            }),
            withdrawalStartBlock: startBlock,
            delegatedAddress: address(0)
        });
        assertEq(eigenLayerStrategyManager.calculateWithdrawalRoot(withdrawalsToMigrate[0]), withdrawalRoot);

        eigenLayerDelegationManager.migrateQueuedWithdrawals(withdrawalsToMigrate);

        IDelegationManager.Withdrawal memory migratedWithdrawal = IDelegationManager.Withdrawal({
            staker: withdrawalsToMigrate[0].staker,
            delegatedTo: withdrawalsToMigrate[0].delegatedAddress,
            withdrawer: withdrawalsToMigrate[0].withdrawerAndNonce.withdrawer,
            nonce: withdrawalsToMigrate[0].withdrawerAndNonce.nonce,
            startBlock: withdrawalsToMigrate[0].withdrawalStartBlock,
            strategies: withdrawalsToMigrate[0].strategies,
            shares: withdrawalsToMigrate[0].shares
        });

        bytes32 newWithdrawalRoot = eigenLayerDelegationManager.calculateWithdrawalRoot(migratedWithdrawal);
        assertEq(eigenLayerDelegationManager.pendingWithdrawals(newWithdrawalRoot), true);

        liquifierInstance.depositWithQueuedWithdrawal(queuedWithdrawal, address(0));

        // multipme mints using the same queued withdrawal fails
        vm.expectRevert("Deposited");
        liquifierInstance.depositWithQueuedWithdrawal(queuedWithdrawal, address(0));

        return queuedWithdrawal;
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

    function _complete_queued_withdrawal(IStrategyManager.DeprecatedStruct_QueuedWithdrawal memory queuedWithdrawal, IStrategy strategy) internal {
        vm.roll(block.number + 7 days);

        IStrategyManager.DeprecatedStruct_QueuedWithdrawal[] memory queuedWithdrawals = new IStrategyManager.DeprecatedStruct_QueuedWithdrawal[](1);
        queuedWithdrawals[0] = queuedWithdrawal;
        IERC20[][] memory tokens = new IERC20[][](1);
        tokens[0] = new IERC20[](1);
        tokens[0][0] = strategy.underlyingToken();
        uint256[] memory middlewareTimesIndexes = new uint256[](1);
        middlewareTimesIndexes[0] = 0;
        // liquifierInstance.completeQueuedWithdrawals(queuedWithdrawals, tokens, middlewareTimesIndexes);

        vm.expectRevert();
        // liquifierInstance.completeQueuedWithdrawals(queuedWithdrawals, tokens, middlewareTimesIndexes);
    }

    function _complete_queued_withdrawal_V2(IDelegationManager.Withdrawal memory queuedWithdrawal, IStrategy strategy) internal {
        vm.roll(block.number + 7 days);
        
        IDelegationManager.Withdrawal[] memory queuedWithdrawals = new IDelegationManager.Withdrawal[](1);
        queuedWithdrawals[0] = queuedWithdrawal;
        IERC20[][] memory tokens = new IERC20[][](1);
        tokens[0] = new IERC20[](1);
        tokens[0][0] = strategy.underlyingToken();
        uint256[] memory middlewareTimesIndexes = new uint256[](1);
        middlewareTimesIndexes[0] = 0;
        liquifierInstance.completeQueuedWithdrawals(queuedWithdrawals, tokens, middlewareTimesIndexes);

        vm.expectRevert();
        liquifierInstance.completeQueuedWithdrawals(queuedWithdrawals, tokens, middlewareTimesIndexes);
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
        liquifierInstance.registerToken(address(dummyToken), address(0), true, 0, 50, 1000, true);
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
        liquifierInstance.registerToken(address(dummyToken2), address(0), true, 0, 50, 1000, true);
        vm.stopPrank();

        uint256 x = 5 ether;
        _fast_sync_from_L2_to_L1(address(dummyToken2), x);

        assertEq(liquifierInstance.getTotalPooledEther(), prevTotalPooledEther + liquifierInstance.getTotalPooledEther(address(dummyToken2)));
    }

    function test_add_dummy_token_flag() public {
        initializeRealisticFork(MAINNET_FORK);

        bool isTokenWhitelisted = liquifierInstance.isTokenWhitelisted(address(stEth));
        uint256 timeBoundCap = liquifierInstance.timeBoundCap(address(stEth));
        uint256 totalCap = liquifierInstance.totalCap(address(stEth));
        uint256 totalDeposited = liquifierInstance.totalDeposited(address(stEth));
        uint256 getTotalPooledEther = liquifierInstance.getTotalPooledEther(address(stEth));

        // Do the upgrade
        setUpLiquifier(MAINNET_FORK);

        assertEq(liquifierInstance.isTokenWhitelisted(address(stEth)), isTokenWhitelisted);
        assertEq(liquifierInstance.isL2Eth(address(stEth)), false);
        assertEq(liquifierInstance.timeBoundCap(address(stEth)), timeBoundCap);
        assertEq(liquifierInstance.totalCap(address(stEth)), totalCap);
        assertEq(liquifierInstance.totalDeposited(address(stEth)), totalDeposited);
        assertEq(liquifierInstance.getTotalPooledEther(address(stEth)), getTotalPooledEther);
    }

    function test_pauser() public {
        initializeRealisticFork(MAINNET_FORK);
        setUpLiquifier(MAINNET_FORK);

        owner = liquifierInstance.owner();

        vm.startPrank(bob);
        vm.expectRevert();
        liquifierInstance.pauseContract();
        vm.stopPrank();

        vm.prank(owner);
        liquifierInstance.updatePauser(bob, true);

        vm.startPrank(bob);
        liquifierInstance.pauseContract();
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert();
        liquifierInstance.unPauseContract();
        vm.stopPrank();

        vm.prank(owner);
        liquifierInstance.unPauseContract();

    }

    function test_getTotalPooledEther() public {
        initializeRealisticFork(MAINNET_FORK);
        setUpLiquifier(MAINNET_FORK);

        liquidityPoolInstance.getTotalPooledEther();
        liquifierInstance.getTotalPooledEther();
    }
}
