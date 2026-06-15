// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@tests/TestSetup.sol";
import "forge-std/Test.sol";

import "@openzeppelin-upgradeable/contracts/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";

import "@etherfi/interfaces/eigenlayer-interfaces/IDelegationManager.sol";
import "@etherfi/interfaces/eigenlayer-interfaces/IStrategyManager.sol";
import "@etherfi/governance/utils/PausableUntil.sol";

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

        vm.startPrank(owner);
        liquifierInstance.registerToken(address(stEth), address(stEthStrategy), true, 100, 50, 1000, false); // 1% discount, 50 ether timeBoundCap, 1000 ether total cap
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
        // Price validation now runs on every stETH deposit; pin a fresh ~1:1 feed so the
        // deposit reaches the cap check rather than reverting StalePriceFeed first.
        _mockFreshStEthFeed();

        vm.deal(alice, 1000000000 ether);

        vm.startPrank(owner);
        // Curve quoting on a 20k stETH input incurs heavy slippage and trips
        // the chainlink/curve deviation predicate before the cap check fires.
        // This test is about the cap, so quote 1:1 instead.
        liquifierInstance.updateQuoteStEthWithCurve(false);
        liquifierInstance.updateDepositCap(address(stEth), 50, 100);
        vm.stopPrank();

        uint256 amount = 20000 ether;
        vm.startPrank(alice);
        stEth.submit{value: amount + 1 ether}(address(0));
        stEth.approve(address(liquifierInstance), amount);

        vm.expectRevert(Liquifier.Capped.selector);
        liquifierInstance.depositWithERC20(address(stEth), amount, 0, address(0));

        vm.stopPrank();
    }

    function test_deposit_stEth() public {
        initializeRealisticFork(MAINNET_FORK);
        setUpLiquifier(MAINNET_FORK);
        _mockFreshStEthFeed();

        vm.deal(alice, 100 ether);

        vm.startPrank(roleRegistryInstance.owner());
        liquifierInstance.updateQuoteStEthWithCurve(true);
        liquifierInstance.updateDiscountInBasisPoints(address(stEth), 500); // 5%
        vm.stopPrank();

        vm.startPrank(alice);
        stEth.submit{value: 10 ether}(address(0));
        stEth.approve(address(liquifierInstance), 10 ether);
        liquifierInstance.depositWithERC20(address(stEth), 10 ether, 0, address(0));
        vm.stopPrank();

        assertApproxEqAbs(eETHInstance.balanceOf(alice), 10 ether - 0.5 ether, 0.1 ether);

        uint256 aliceQuotedEETH = liquifierInstance.quoteByDiscountedValue(address(stEth), 10 ether, 0);
        // alice will actually receive 1 wei less due to the infamous 1 wei rounding corner case
        assertApproxEqAbs(eETHInstance.balanceOf(alice), aliceQuotedEETH, 1e1);
    }

    /// @dev Slippage guard at the quote level: quoteByDiscountedValue must revert when the
    ///      discounted output would fall below the caller-supplied `_minOutAmount`, and must
    ///      return normally (unchanged value) when the floor is met.
    function test_quoteByDiscountedValue_revertsBelowMinOut() public {
        initializeRealisticFork(MAINNET_FORK);
        setUpLiquifier(MAINNET_FORK);
        _mockFreshStEthFeed();

        vm.startPrank(roleRegistryInstance.owner());
        liquifierInstance.updateQuoteStEthWithCurve(true);
        liquifierInstance.updateDiscountInBasisPoints(address(stEth), 500); // 5%
        vm.stopPrank();

        // Reference discounted value with no floor.
        uint256 quoted = liquifierInstance.quoteByDiscountedValue(address(stEth), 10 ether, 0);
        assertGt(quoted, 0);

        // A floor one wei above the achievable output trips the slippage guard.
        vm.expectRevert(Liquifier.InvalidSlippage.selector);
        liquifierInstance.quoteByDiscountedValue(address(stEth), 10 ether, quoted + 1);

        // A floor exactly at the output passes and returns the same value (>= is allowed).
        assertEq(liquifierInstance.quoteByDiscountedValue(address(stEth), 10 ether, quoted), quoted);
    }

    /// @dev Slippage guard through the full deposit path: depositWithERC20 must revert
    ///      InvalidSlippage when `_minOutAmount` exceeds the discounted credit, and succeed
    ///      (minting ~the discounted value) when the floor is satisfiable.
    function test_depositWithERC20_revertsWhenBelowMinOut() public {
        initializeRealisticFork(MAINNET_FORK);
        setUpLiquifier(MAINNET_FORK);
        _mockFreshStEthFeed();

        vm.deal(alice, 100 ether);

        vm.startPrank(roleRegistryInstance.owner());
        liquifierInstance.updateQuoteStEthWithCurve(true);
        liquifierInstance.updateDiscountInBasisPoints(address(stEth), 500); // 5%
        vm.stopPrank();

        // ~9.5 eETH expected for 10 stETH at a 5% discount.
        uint256 quoted = liquifierInstance.quoteByDiscountedValue(address(stEth), 10 ether, 0);

        vm.startPrank(alice);
        stEth.submit{value: 11 ether}(address(0));
        stEth.approve(address(liquifierInstance), 10 ether);

        // Floor above the achievable discounted output -> reverts, no mint.
        vm.expectRevert(Liquifier.InvalidSlippage.selector);
        liquifierInstance.depositWithERC20(address(stEth), 10 ether, quoted + 1 ether, address(0));
        assertEq(eETHInstance.balanceOf(alice), 0, "no eETH should be minted on a slippage revert");

        // Floor just below the output (covers stETH's 1-2 wei transfer rounding) -> succeeds.
        liquifierInstance.depositWithERC20(address(stEth), 10 ether, quoted - 0.01 ether, address(0));
        vm.stopPrank();

        assertApproxEqAbs(eETHInstance.balanceOf(alice), quoted, 0.01 ether);
    }

    /// @dev Depeg guard (deposit side): a stETH down-depeg below the price floor
    ///      (1e18 - maxPriceThreshold) must block stETH deposits — the protocol must not
    ///      accept cheap stETH at ~par. At peg the deposit proceeds (covered by
    ///      test_deposit_stEth). maxPriceThreshold is STETH_MAX_PRICE_THRESHOLD = 1e16 (1%),
    ///      so the floor sits at 0.99e18.
    function test_deposit_revertsOnStEthDownDepeg() public {
        initializeRealisticFork(MAINNET_FORK);
        setUpLiquifier(MAINNET_FORK);

        vm.deal(alice, 100 ether);
        vm.startPrank(alice);
        stEth.submit{value: 10 ether}(address(0));
        stEth.approve(address(liquifierInstance), 10 ether);

        // stETH at 0.98 ETH — below the 0.99e18 floor → blocked.
        vm.mockCall(
            stEthChainlinkFeed,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(0), int256(0.98 ether), uint256(0), block.timestamp, uint80(0))
        );

        vm.expectRevert(Liquifier.InvalidStEthPrice.selector);
        liquifierInstance.depositWithERC20(address(stEth), 10 ether, 0, address(0));
        vm.stopPrank();
    }

    /// @dev A stETH price just inside the floor (0.995 ≥ 0.99) is still accepted — the guard
    ///      only trips on a genuine depeg beyond the band, not on the normal ~0.1-0.2% discount.
    function test_deposit_allowsStEthWithinBand() public {
        initializeRealisticFork(MAINNET_FORK);
        setUpLiquifier(MAINNET_FORK);

        vm.startPrank(roleRegistryInstance.owner());
        liquifierInstance.updateQuoteStEthWithCurve(false); // isolate the floor from curve-deviation
        vm.stopPrank();

        vm.deal(alice, 100 ether);
        vm.startPrank(alice);
        stEth.submit{value: 10 ether}(address(0));
        stEth.approve(address(liquifierInstance), 10 ether);

        vm.mockCall(
            stEthChainlinkFeed,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(0), int256(0.995 ether), uint256(0), block.timestamp, uint80(0))
        );

        liquifierInstance.depositWithERC20(address(stEth), 10 ether, 0, address(0));
        vm.stopPrank();
        assertGt(eETHInstance.balanceOf(alice), 0, "deposit within band must mint eETH");
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
        liquifierInstance.depositWithERC20(address(stEth), 2 ether, 0, address(0));

        assertGe(eETHInstance.balanceOf(alice), 2 ether - 0.1 ether);
        assertGe(liquifierInstance.getTotalPooledEther(), 2 ether - 0.1 ether);
        assertGe(liquidityPoolInstance.getTotalPooledEther(), lpTvl + 2 ether - 0.1 ether);
        assertEq(address(liquifierInstance).balance, 0 ether);

        lpTvl = liquidityPoolInstance.getTotalPooledEther();
    }

    function test_deopsit_stEth_with_explicit_permit() public {
        initializeRealisticFork(MAINNET_FORK);
        setUpLiquifier(MAINNET_FORK);
        _mockFreshStEthFeed();

        // Clear any code at alice's address to make it act like an EOA (External Owned Account)
        vm.etch(alice, "");

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
        liquifierInstance.depositWithERC20(address(stEth), 1 ether, 0, address(0));

        stEth.approve(address(liquifierInstance), 1 ether);
        liquifierInstance.depositWithERC20(address(stEth), 1 ether, 0, address(0));

        // Deposit 1 stETH with the approval signature
        ILiquidityPool.PermitInput memory permitInput = createPermitInput(2, address(liquifierInstance), 1 ether - 1, stEth.nonces(alice), 2**256 - 1, stEth.DOMAIN_SEPARATOR());
        ILiquifier.PermitInput memory permitInput2 = ILiquifier.PermitInput({value: permitInput.value, deadline: permitInput.deadline, v: permitInput.v, r: permitInput.r, s: permitInput.s});
        vm.expectRevert("ALLOWANCE_EXCEEDED");
        liquifierInstance.depositWithERC20WithPermit(address(stEth), 1 ether, 0, address(0), permitInput2);

        permitInput = createPermitInput(2, address(liquifierInstance), 1 ether, stEth.nonces(alice), 2**256 - 1, stEth.DOMAIN_SEPARATOR());
        permitInput2 = ILiquifier.PermitInput({value: permitInput.value, deadline: permitInput.deadline, v: permitInput.v, r: permitInput.r, s: permitInput.s});
        liquifierInstance.depositWithERC20WithPermit(address(stEth), 1 ether, 0, address(0), permitInput2);
    }

    /// On realistic mainnet fork, the live stETH/ETH feed has a ~24h heartbeat
    /// and may sit just past stalePriceWindow depending on fork-block timing
    /// (or after vm.warp). Pin it to a fresh, ~1:1 answer so deposits exercising
    /// the curve-quoting path don't revert with StalePriceFeed.
    function _mockFreshStEthFeed() internal {
        vm.mockCall(
            stEthChainlinkFeed,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(0), int256(1 ether), uint256(0), block.timestamp, uint80(0))
        );
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
        liquifierInstance.registerToken(address(dummyToken), address(0), true, 100, 50, 1000, true);
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
        liquifierInstance.depositWithERC20(_token, _x, 0, address(0));
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
        vm.expectRevert(Liquifier.NotAllowed.selector);
        liquifierInstance.depositWithERC20(address(randomToken), _x, 0, address(0));
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
        vm.expectRevert(Liquifier.NotAllowed.selector);
        liquifierInstance.depositWithERC20(address(dummyToken), _x, 0, address(0));
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
        liquifierInstance.registerToken(address(dummyToken2), address(0), true, 100, 50, 1000, true);
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

        // bob has no pauser role
        vm.startPrank(bob);
        vm.expectRevert(RoleRegistry.OnlyOperatingMultisig.selector);
        liquifierInstance.pause();
        vm.stopPrank();

        // grant OPERATION_MULTISIG_ROLE (consolidated admin/pauser) to bob
        vm.startPrank(roleRegistryInstance.owner());
        roleRegistryInstance.grantRole(roleRegistryInstance.OPERATION_MULTISIG_ROLE(), bob);
        vm.stopPrank();

        vm.prank(bob);
        liquifierInstance.pause();

        // bob can also unpause now (consolidated into a single admin role).
        vm.prank(bob);
        liquifierInstance.unpause();
    }

    function test_sendToEtherFiRestaker_requiresSenderRole() public {
        initializeRealisticFork(MAINNET_FORK);
        setUpLiquifier(MAINNET_FORK);

        // Fund the liquifier with stETH so a transfer would otherwise succeed
        vm.deal(alice, 5 ether);
        vm.startPrank(alice);
        stEth.submit{value: 5 ether}(address(0));
        stEth.transfer(address(liquifierInstance), 1 ether);
        vm.stopPrank();

        // bob has no roles; sendToEtherFiRestaker now requires HOUSEKEEPING_OPERATIONS_ROLE
        vm.prank(bob);
        vm.expectRevert(RoleRegistry.OnlyHousekeepingOperations.selector);
        liquifierInstance.sendToEtherFiRestaker(address(stEth), 1);

        // chad has only the consolidated admin role — sender path requires HOUSEKEEPING_OPERATIONS_ROLE
        vm.startPrank(roleRegistryInstance.owner());
        roleRegistryInstance.grantRole(roleRegistryInstance.OPERATION_MULTISIG_ROLE(), chad);
        vm.stopPrank();
        vm.prank(chad);
        vm.expectRevert(RoleRegistry.OnlyHousekeepingOperations.selector);
        liquifierInstance.sendToEtherFiRestaker(address(stEth), 1);
    }

    function test_sendToEtherFiRestaker_succeedsWithSenderRole() public {
        initializeRealisticFork(MAINNET_FORK);
        setUpLiquifier(MAINNET_FORK);

        vm.deal(alice, 5 ether);
        vm.startPrank(alice);
        stEth.submit{value: 5 ether}(address(0));
        stEth.transfer(address(liquifierInstance), 2 ether);
        vm.stopPrank();

        address sender = makeAddr("liqSender");
        // LIQUIFIER_SENDER_ROLE consolidated into HOUSEKEEPING_OPERATIONS_ROLE.
        vm.startPrank(roleRegistryInstance.owner());
        roleRegistryInstance.grantRole(roleRegistryInstance.HOUSEKEEPING_OPERATIONS_ROLE(), sender);
        vm.stopPrank();

        uint256 restakerBalBefore = stEth.balanceOf(address(etherFiRestakerInstance));
        uint256 liquifierBalBefore = stEth.balanceOf(address(liquifierInstance));

        vm.prank(sender);
        liquifierInstance.sendToEtherFiRestaker(address(stEth), 1 ether);

        // stETH transfer can be off by 1-2 wei due to share rounding
        assertApproxEqAbs(stEth.balanceOf(address(etherFiRestakerInstance)), restakerBalBefore + 1 ether, 2);
        assertApproxEqAbs(stEth.balanceOf(address(liquifierInstance)), liquifierBalBefore - 1 ether, 2);
    }

    // test_LIQUIFIER_SENDER_ROLE_constant removed:
    // LIQUIFIER_SENDER_ROLE / LIQUIFIER_ADMIN_ROLE no longer exist as named roles —
    // they were consolidated into HOUSEKEEPING_OPERATIONS_ROLE and OPERATION_MULTISIG_ROLE respectively.

    function test_getTotalPooledEther() public {
        initializeRealisticFork(MAINNET_FORK);
        setUpLiquifier(MAINNET_FORK);

        liquidityPoolInstance.getTotalPooledEther();
        liquifierInstance.getTotalPooledEther();
    }

    //--------------------------------------------------------------------------------------
    //--------------------------  pauseContractUntil / unpauseContractUntil  ---------------
    //--------------------------------------------------------------------------------------

    bytes32 constant PAUSABLE_UNTIL_SLOT =
        0x2c7e4bc092c2002f0baaf2f47367bc442b098266b43d189dafe4cb25f1e1fea2;

    address liqPauseUntilPauser = makeAddr("liqPauseUntilPauser");
    address liqUnpauseUntilUnpauser = makeAddr("liqUnpauseUntilUnpauser");
    address liqPauseUntilDurationSetter = makeAddr("liqPauseUntilDurationSetter");

    function _grantLiqPauseUntilRoles() internal {
        vm.startPrank(roleRegistryInstance.owner());
        // pauseContractUntil → GUARDIAN_ROLE; unpause + setPauseUntilDuration → OPERATION_MULTISIG_ROLE (onlyAdmin).
        roleRegistryInstance.grantRole(roleRegistryInstance.GUARDIAN_ROLE(), liqPauseUntilPauser);
        roleRegistryInstance.grantRole(roleRegistryInstance.OPERATION_MULTISIG_ROLE(), liqUnpauseUntilUnpauser);
        roleRegistryInstance.grantRole(roleRegistryInstance.OPERATION_TIMELOCK_ROLE(), liqPauseUntilDurationSetter);
        vm.stopPrank();
        if (block.timestamp < 1_700_000_000) vm.warp(1_700_000_000);

        uint256 maxDur = liquifierInstance.MAX_PAUSE_DURATION();
        vm.prank(liqPauseUntilDurationSetter);
        liquifierInstance.setPauseUntilDuration(maxDur);
    }

    function _liqPausedUntil() internal view returns (uint256) {
        return uint256(vm.load(address(liquifierInstance), PAUSABLE_UNTIL_SLOT));
    }

    function test_pauseContractUntil_requiresRole() public {
        initializeRealisticFork(MAINNET_FORK);
        setUpLiquifier(MAINNET_FORK);
        _grantLiqPauseUntilRoles();

        vm.prank(bob);
        vm.expectRevert(RoleRegistry.OnlyGuardian.selector);
        liquifierInstance.pauseUntil();
    }

    function test_pauseContractUntil_setsState() public {
        initializeRealisticFork(MAINNET_FORK);
        setUpLiquifier(MAINNET_FORK);
        _grantLiqPauseUntilRoles();

        vm.prank(liqPauseUntilPauser);
        liquifierInstance.pauseUntil();
        assertEq(_liqPausedUntil(), block.timestamp + liquifierInstance.MAX_PAUSE_DURATION());
    }

    function test_unpauseContractUntil_requiresRole() public {
        initializeRealisticFork(MAINNET_FORK);
        setUpLiquifier(MAINNET_FORK);
        _grantLiqPauseUntilRoles();

        vm.prank(liqPauseUntilPauser);
        liquifierInstance.pauseUntil();

        vm.prank(bob);
        vm.expectRevert(RoleRegistry.OnlyOperatingMultisig.selector);
        liquifierInstance.unpauseUntil();
    }

    function test_unpauseContractUntil_clearsState() public {
        initializeRealisticFork(MAINNET_FORK);
        setUpLiquifier(MAINNET_FORK);
        _grantLiqPauseUntilRoles();

        vm.prank(liqPauseUntilPauser);
        liquifierInstance.pauseUntil();

        vm.prank(liqUnpauseUntilUnpauser);
        liquifierInstance.unpauseUntil();
        assertEq(_liqPausedUntil(), 0);
    }

    function test_unpauseContractUntil_revertsIfNotPaused() public {
        initializeRealisticFork(MAINNET_FORK);
        setUpLiquifier(MAINNET_FORK);
        _grantLiqPauseUntilRoles();

        vm.prank(liqUnpauseUntilUnpauser);
        vm.expectRevert(PausableUntil.ContractNotPausedUntil.selector);
        liquifierInstance.unpauseUntil();
    }

    // --- setPauseUntilDuration ---

    function test_setPauseUntilDuration_requiresRole() public {
        initializeRealisticFork(MAINNET_FORK);
        setUpLiquifier(MAINNET_FORK);
        _grantLiqPauseUntilRoles();
        uint256 maxDur = liquifierInstance.MAX_PAUSE_DURATION();

        vm.prank(bob);
        vm.expectRevert(RoleRegistry.OnlyOperatingTimelock.selector);
        liquifierInstance.setPauseUntilDuration(maxDur);

        // Guardian-only role (liqPauseUntilPauser) cannot set the duration; needs admin role.
        vm.prank(liqPauseUntilPauser);
        vm.expectRevert(RoleRegistry.OnlyOperatingTimelock.selector);
        liquifierInstance.setPauseUntilDuration(maxDur);
    }

    function test_setPauseUntilDuration_setsValue() public {
        initializeRealisticFork(MAINNET_FORK);
        setUpLiquifier(MAINNET_FORK);
        _grantLiqPauseUntilRoles();
        uint256 d = liquifierInstance.MIN_PAUSE_DURATION() + 1 hours;

        vm.prank(liqPauseUntilDurationSetter);
        liquifierInstance.setPauseUntilDuration(d);

        vm.prank(liqPauseUntilPauser);
        liquifierInstance.pauseUntil();
        assertEq(_liqPausedUntil(), block.timestamp + d);
    }

    function test_setPauseUntilDuration_revertsOnInvalidValue() public {
        initializeRealisticFork(MAINNET_FORK);
        setUpLiquifier(MAINNET_FORK);
        _grantLiqPauseUntilRoles();
        uint256 belowMin = liquifierInstance.MIN_PAUSE_DURATION() - 1;
        uint256 aboveMax = liquifierInstance.MAX_PAUSE_DURATION() + 1;

        vm.prank(liqPauseUntilDurationSetter);
        vm.expectRevert(PausableUntil.InvalidPauseUntilDuration.selector);
        liquifierInstance.setPauseUntilDuration(belowMin);

        vm.prank(liqPauseUntilDurationSetter);
        vm.expectRevert(PausableUntil.InvalidPauseUntilDuration.selector);
        liquifierInstance.setPauseUntilDuration(aboveMax);
    }

    // --- each gated function (whenNotPaused now also enforces pause-until via override) ---

    function test_depositWithERC20_blockedByPauseContractUntil() public {
        initializeRealisticFork(MAINNET_FORK);
        setUpLiquifier(MAINNET_FORK);
        _grantLiqPauseUntilRoles();

        vm.deal(alice, 10 ether);
        vm.startPrank(alice);
        stEth.submit{value: 5 ether}(address(0));
        stEth.approve(address(liquifierInstance), 1 ether);
        vm.stopPrank();

        vm.prank(liqPauseUntilPauser);
        liquifierInstance.pauseUntil();

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(PausableUntil.ContractPausedUntil.selector, _liqPausedUntil())
        );
        liquifierInstance.depositWithERC20(address(stEth), 1 ether, 0, address(0));
    }

    function test_depositWithERC20WithPermit_blockedByPauseContractUntil() public {
        initializeRealisticFork(MAINNET_FORK);
        setUpLiquifier(MAINNET_FORK);
        _grantLiqPauseUntilRoles();

        vm.prank(liqPauseUntilPauser);
        liquifierInstance.pauseUntil();

        ILiquifier.PermitInput memory emptyPermit;
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(PausableUntil.ContractPausedUntil.selector, _liqPausedUntil())
        );
        liquifierInstance.depositWithERC20WithPermit(address(stEth), 1 ether, 0, address(0), emptyPermit);
    }

    function test_pauseContract_allowedWhilePauseUntilActive() public {
        // The indefinite pause and the timed pause are now independent primitives: pausing
        // indefinitely while a timed pause is active is allowed (escalation), and both keep
        // `whenNotPaused`-gated functions blocked.
        initializeRealisticFork(MAINNET_FORK);
        setUpLiquifier(MAINNET_FORK);
        _grantLiqPauseUntilRoles();

        vm.prank(liqPauseUntilPauser);
        liquifierInstance.pauseUntil();

        vm.prank(owner);
        liquifierInstance.pause();
        assertTrue(liquifierInstance.paused());
    }

    function test_depositWithERC20_unblockedAfterPauseExpires() public {
        initializeRealisticFork(MAINNET_FORK);
        setUpLiquifier(MAINNET_FORK);
        _grantLiqPauseUntilRoles();

        vm.deal(alice, 10 ether);
        vm.startPrank(alice);
        stEth.submit{value: 5 ether}(address(0));
        stEth.approve(address(liquifierInstance), 1 ether);
        vm.stopPrank();

        vm.prank(liqPauseUntilPauser);
        liquifierInstance.pauseUntil();

        vm.warp(block.timestamp + liquifierInstance.MAX_PAUSE_DURATION() + 1);
        // Refresh after warp — pause window is days, well past stalePriceWindow.
        _mockFreshStEthFeed();

        vm.prank(alice);
        liquifierInstance.depositWithERC20(address(stEth), 1 ether, 0, address(0));
    }

    function test_depositWithERC20_unblockedAfterExplicitUnpause() public {
        initializeRealisticFork(MAINNET_FORK);
        setUpLiquifier(MAINNET_FORK);
        _grantLiqPauseUntilRoles();
        _mockFreshStEthFeed();

        vm.deal(alice, 10 ether);
        vm.startPrank(alice);
        stEth.submit{value: 5 ether}(address(0));
        stEth.approve(address(liquifierInstance), 1 ether);
        vm.stopPrank();

        vm.prank(liqPauseUntilPauser);
        liquifierInstance.pauseUntil();
        vm.prank(liqUnpauseUntilUnpauser);
        liquifierInstance.unpauseUntil();

        vm.prank(alice);
        liquifierInstance.depositWithERC20(address(stEth), 1 ether, 0, address(0));
    }

    // ---------------------------------------------------------------------
    // T1-11: discount-floor hardening
    // ---------------------------------------------------------------------

    function _ctorAddrs(address roleRegistry_, address priceFeed_, address blacklister_)
        internal
        pure
        returns (ILiquifier.ConstructorAddresses memory)
    {
        return ILiquifier.ConstructorAddresses({
            liquidityPool: address(0xA1),
            lidoWithdrawalQueue: address(0xA2),
            lido: address(0xA3),
            stEth_Eth_Pool: address(0xA4),
            roleRegistry: roleRegistry_,
            stEthPriceFeed: priceFeed_,
            blacklister: blacklister_,
            etherfiRestaker: address(0xA5),
            l1SyncPool: address(0xA6)
        });
    }

    function test_constructor_revertsOnZeroMinDiscount() public {
        vm.expectRevert(Liquifier.InvalidDiscountRate.selector);
        new Liquifier(_ctorAddrs(address(1), address(2), address(3)), 0, 1 days, 500, 1e16);
    }

    function test_constructor_revertsOnMinDiscountAboveScale() public {
        vm.expectRevert(Liquifier.InvalidDiscountRate.selector);
        new Liquifier(_ctorAddrs(address(1), address(2), address(3)), 10_001, 1 days, 500, 1e16);
    }

    function test_constructor_acceptsMinDiscountAtScale() public {
        Liquifier impl = new Liquifier(_ctorAddrs(address(1), address(2), address(3)), 10_000, 1 days, 500, 1e16);
        assertEq(impl.minDiscountRateInBps(), 10_000);
    }

    function test_constructor_storesMinDiscount() public {
        Liquifier impl = new Liquifier(_ctorAddrs(address(1), address(2), address(3)), 250, 1 days, 500, 1e16);
        assertEq(impl.minDiscountRateInBps(), 250);
        assertEq(impl.BASIS_POINT_SCALE(), 10_000);
    }

    function test_constructor_revertsOnZeroStaleWindow() public {
        vm.expectRevert(Liquifier.InvalidPriceWindow.selector);
        new Liquifier(_ctorAddrs(address(1), address(2), address(3)), 100, 0, 500, 1e16);
    }

    function test_constructor_revertsOnZeroMaxPriceDeviation() public {
        vm.expectRevert(Liquifier.InvalidMaxPriceDeviationInBps.selector);
        new Liquifier(_ctorAddrs(address(1), address(2), address(3)), 100, 1 days, 0, 1e16);
    }

    function test_constructor_revertsOnMaxPriceDeviationAboveScale() public {
        vm.expectRevert(Liquifier.InvalidMaxPriceDeviationInBps.selector);
        new Liquifier(_ctorAddrs(address(1), address(2), address(3)), 100, 1 days, 10_001, 1e16);
    }

    function test_constructor_storesPriceFeedImmutables() public {
        Liquifier impl = new Liquifier(_ctorAddrs(address(1), address(2), address(3)), 250, 1 days, 500, 1e16);
        assertEq(address(impl.stEthPriceFeed()), address(2));
        assertEq(impl.stalePriceWindow(), 1 days);
        assertEq(impl.maxPriceDeviationInBps(), 500);
        assertEq(impl.maxPriceThreshold(), 1e16);
    }

    function test_registerToken_revertsOnZeroDiscountRate() public {
        _setUp(MAINNET_FORK);

        vm.prank(owner);
        vm.expectRevert(Liquifier.InvalidDiscountRate.selector);
        liquifierInstance.registerToken(address(stEth), address(stEthStrategy), true, 0, 50, 1000, false);
    }

    function test_registerToken_revertsOnDiscountRateAboveScale() public {
        _setUp(MAINNET_FORK);

        vm.prank(owner);
        vm.expectRevert(Liquifier.InvalidDiscountRate.selector);
        liquifierInstance.registerToken(address(stEth), address(stEthStrategy), true, 10_001, 50, 1000, false);
    }

    function test_updateDiscountInBasisPoints_revertsOnZero() public {
        // The exact attack scenario T1-11 closes: a compromised admin tries to
        // set discount to 0 to mint eETH 1:1 against an LST.
        _setUp(MAINNET_FORK);

        vm.prank(owner);
        vm.expectRevert(Liquifier.InvalidDiscountRate.selector);
        liquifierInstance.updateDiscountInBasisPoints(address(stEth), 0);
    }

    function test_updateDiscountInBasisPoints_revertsBelowFloor() public {
        _setUp(MAINNET_FORK);
        uint256 floor = liquifierInstance.minDiscountRateInBps();
        assertGt(floor, 0);

        vm.prank(owner);
        vm.expectRevert(Liquifier.InvalidDiscountRate.selector);
        liquifierInstance.updateDiscountInBasisPoints(address(stEth), uint16(floor - 1));
    }

    function test_updateDiscountInBasisPoints_acceptsAtFloor() public {
        _setUp(MAINNET_FORK);
        uint256 floor = liquifierInstance.minDiscountRateInBps();

        vm.prank(owner);
        liquifierInstance.updateDiscountInBasisPoints(address(stEth), uint16(floor));

        (, , , , uint16 discount, , , , , , ) = liquifierInstance.tokenInfos(address(stEth));
        assertEq(discount, uint16(floor));
    }

    function test_updateDiscountInBasisPoints_acceptsAboveFloor() public {
        _setUp(MAINNET_FORK);

        vm.prank(owner);
        liquifierInstance.updateDiscountInBasisPoints(address(stEth), 500);

        (, , , , uint16 discount, , , , , , ) = liquifierInstance.tokenInfos(address(stEth));
        assertEq(discount, 500);
    }

    function test_updateDiscountInBasisPoints_revertsAboveScale() public {
        _setUp(MAINNET_FORK);

        vm.prank(owner);
        vm.expectRevert(Liquifier.InvalidDiscountRate.selector);
        liquifierInstance.updateDiscountInBasisPoints(address(stEth), 10_001);
    }

    function test_updateDiscountInBasisPoints_acceptsAtScale() public {
        _setUp(MAINNET_FORK);

        vm.prank(owner);
        liquifierInstance.updateDiscountInBasisPoints(address(stEth), 10_000);

        (, , , , uint16 discount, , , , , , ) = liquifierInstance.tokenInfos(address(stEth));
        assertEq(discount, 10_000);
    }

    function test_updateDiscountInBasisPoints_revertsWithoutRole() public {
        _setUp(MAINNET_FORK);

        // bob never receives OPERATION_MULTISIG_ROLE in setUpLiquifier
        vm.prank(bob);
        vm.expectRevert(RoleRegistry.OnlyOperatingTimelock.selector);
        liquifierInstance.updateDiscountInBasisPoints(address(stEth), 500);
    }

    function test_quoteByDiscountedValue_appliesNewDiscount() public {
        _setUp(MAINNET_FORK);
        // Price validation now runs on every stETH quote; pin a fresh ~1:1 feed.
        _mockFreshStEthFeed();

        vm.prank(admin);
        liquifierInstance.updateDiscountInBasisPoints(address(stEth), 500); // 5%

        uint256 amount = 10 ether;
        uint256 marketValue = liquifierInstance.quoteByMarketValue(address(stEth), amount);
        uint256 expected = (10_000 - 500) * marketValue / 10_000;
        assertEq(liquifierInstance.quoteByDiscountedValue(address(stEth), amount, 0), expected);
    }
}
