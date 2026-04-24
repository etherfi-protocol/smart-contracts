// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "forge-std/Test.sol";

import "@openzeppelin-upgradeable/contracts/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";

import "../src/eigenlayer-interfaces/IDelegationManager.sol";
import "../src/eigenlayer-interfaces/IStrategyManager.sol";
import "../src/utils/PausableUntil.sol";

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

        vm.startPrank(liquifierInstance.owner());
        liquifierInstance.updateDepositCap(address(stEth), 50, 100);
        vm.stopPrank();

        uint256 amount = 20000 ether;
        vm.startPrank(alice);
        stEth.submit{value: amount + 1 ether}(address(0));
        stEth.approve(address(liquifierInstance), amount);

        vm.expectRevert("CAPPED");
        liquifierInstance.depositWithERC20(address(stEth), amount, address(0));

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
        assertApproxEqAbs(eETHInstance.balanceOf(alice), aliceQuotedEETH, 1e1);
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

        // bob has no pauser role
        vm.startPrank(bob);
        vm.expectRevert(Liquifier.IncorrectRole.selector);
        liquifierInstance.pauseContract();
        vm.stopPrank();

        // grant PROTOCOL_PAUSER to bob
        vm.startPrank(roleRegistryInstance.owner());
        roleRegistryInstance.grantRole(roleRegistryInstance.PROTOCOL_PAUSER(), bob);
        vm.stopPrank();

        vm.prank(bob);
        liquifierInstance.pauseContract();

        // bob cannot unpause — no PROTOCOL_UNPAUSER
        vm.prank(bob);
        vm.expectRevert(Liquifier.IncorrectRole.selector);
        liquifierInstance.unPauseContract();

        // setUpLiquifier granted PROTOCOL_UNPAUSER to owner
        vm.prank(owner);
        liquifierInstance.unPauseContract();
    }

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

    function _grantLiqPauseUntilRoles() internal {
        vm.startPrank(roleRegistryInstance.owner());
        roleRegistryInstance.grantRole(roleRegistryInstance.PAUSE_UNTIL_ROLE(), liqPauseUntilPauser);
        roleRegistryInstance.grantRole(roleRegistryInstance.UNPAUSE_UNTIL_ROLE(), liqUnpauseUntilUnpauser);
        vm.stopPrank();
        if (block.timestamp < 1_700_000_000) vm.warp(1_700_000_000);
    }

    function _liqPausedUntil() internal view returns (uint256) {
        return uint256(vm.load(address(liquifierInstance), PAUSABLE_UNTIL_SLOT));
    }

    function test_pauseContractUntil_requiresRole() public {
        initializeRealisticFork(MAINNET_FORK);
        setUpLiquifier(MAINNET_FORK);
        _grantLiqPauseUntilRoles();

        vm.prank(bob);
        vm.expectRevert(Liquifier.IncorrectRole.selector);
        liquifierInstance.pauseContractUntil();

        // PROTOCOL_PAUSER alone is insufficient
        vm.prank(owner);
        vm.expectRevert(Liquifier.IncorrectRole.selector);
        liquifierInstance.pauseContractUntil();
    }

    function test_pauseContractUntil_setsState() public {
        initializeRealisticFork(MAINNET_FORK);
        setUpLiquifier(MAINNET_FORK);
        _grantLiqPauseUntilRoles();

        vm.prank(liqPauseUntilPauser);
        liquifierInstance.pauseContractUntil();
        assertEq(_liqPausedUntil(), block.timestamp + liquifierInstance.MAX_PAUSE_DURATION());
    }

    function test_unpauseContractUntil_requiresRole() public {
        initializeRealisticFork(MAINNET_FORK);
        setUpLiquifier(MAINNET_FORK);
        _grantLiqPauseUntilRoles();

        vm.prank(liqPauseUntilPauser);
        liquifierInstance.pauseContractUntil();

        vm.prank(bob);
        vm.expectRevert(Liquifier.IncorrectRole.selector);
        liquifierInstance.unpauseContractUntil();

        // PROTOCOL_UNPAUSER alone is insufficient
        vm.prank(owner);
        vm.expectRevert(Liquifier.IncorrectRole.selector);
        liquifierInstance.unpauseContractUntil();
    }

    function test_unpauseContractUntil_clearsState() public {
        initializeRealisticFork(MAINNET_FORK);
        setUpLiquifier(MAINNET_FORK);
        _grantLiqPauseUntilRoles();

        vm.prank(liqPauseUntilPauser);
        liquifierInstance.pauseContractUntil();

        vm.prank(liqUnpauseUntilUnpauser);
        liquifierInstance.unpauseContractUntil();
        assertEq(_liqPausedUntil(), 0);
    }

    function test_unpauseContractUntil_revertsIfNotPaused() public {
        initializeRealisticFork(MAINNET_FORK);
        setUpLiquifier(MAINNET_FORK);
        _grantLiqPauseUntilRoles();

        vm.prank(liqUnpauseUntilUnpauser);
        vm.expectRevert(PausableUntil.ContractNotPausedUntil.selector);
        liquifierInstance.unpauseContractUntil();
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
        liquifierInstance.pauseContractUntil();

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(PausableUntil.ContractPausedUntil.selector, _liqPausedUntil())
        );
        liquifierInstance.depositWithERC20(address(stEth), 1 ether, address(0));
    }

    function test_depositWithERC20WithPermit_blockedByPauseContractUntil() public {
        initializeRealisticFork(MAINNET_FORK);
        setUpLiquifier(MAINNET_FORK);
        _grantLiqPauseUntilRoles();

        vm.prank(liqPauseUntilPauser);
        liquifierInstance.pauseContractUntil();

        ILiquifier.PermitInput memory emptyPermit;
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(PausableUntil.ContractPausedUntil.selector, _liqPausedUntil())
        );
        liquifierInstance.depositWithERC20WithPermit(address(stEth), 1 ether, address(0), emptyPermit);
    }

    function test_pauseContract_blockedWhilePauseUntilActive() public {
        // OZ's _pause() is internally gated by whenNotPaused, which now routes through the
        // _requireNotPaused override. So full pauseContract is blocked while paused-until is active.
        initializeRealisticFork(MAINNET_FORK);
        setUpLiquifier(MAINNET_FORK);
        _grantLiqPauseUntilRoles();

        vm.prank(liqPauseUntilPauser);
        liquifierInstance.pauseContractUntil();
        uint256 until = block.timestamp + liquifierInstance.MAX_PAUSE_DURATION();

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PausableUntil.ContractPausedUntil.selector, until));
        liquifierInstance.pauseContract();
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
        liquifierInstance.pauseContractUntil();

        vm.warp(block.timestamp + liquifierInstance.MAX_PAUSE_DURATION() + 1);

        vm.prank(alice);
        liquifierInstance.depositWithERC20(address(stEth), 1 ether, address(0));
    }

    function test_depositWithERC20_unblockedAfterExplicitUnpause() public {
        initializeRealisticFork(MAINNET_FORK);
        setUpLiquifier(MAINNET_FORK);
        _grantLiqPauseUntilRoles();

        vm.deal(alice, 10 ether);
        vm.startPrank(alice);
        stEth.submit{value: 5 ether}(address(0));
        stEth.approve(address(liquifierInstance), 1 ether);
        vm.stopPrank();

        vm.prank(liqPauseUntilPauser);
        liquifierInstance.pauseContractUntil();
        vm.prank(liqUnpauseUntilUnpauser);
        liquifierInstance.unpauseContractUntil();

        vm.prank(alice);
        liquifierInstance.depositWithERC20(address(stEth), 1 ether, address(0));
    }
}
