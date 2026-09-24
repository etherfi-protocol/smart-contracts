// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@etherfi/deposits/DepositAdapter.sol";
import "@tests/TestSetup.sol";

/**
 * @title DepositAdapterDirectMintTest
 * @notice Differential tests for minting weETH directly on the ETH and WETH deposit paths.
 * @dev The adapter used to take the eETH shares itself and wrap them, which converted
 *      shares -> eETH amount -> shares and floored twice, leaving 1-2 wei stranded on the
 *      adapter. It now credits the shares to weETH and mints against them.
 *
 *      What these tests are for is proving the swap changed nothing it was not meant to.
 *      Pooled ETH, total eETH shares and therefore the exchange rate are all untouched, so
 *      no existing holder moves by a single wei. The depositor gets the 1-2 wei that used
 *      to be stranded.
 */
contract DepositAdapterDirectMintTest is TestSetup {
    IWETH public wETH;

    address internal depositor = makeAddr("directMintDepositor");
    address internal bystander = makeAddr("directMintBystander");

    function setUp() public {
        initializeRealisticFork(MAINNET_FORK);
        wETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

        // Give the bystander an existing weETH position so we can prove it never moves.
        vm.deal(bystander, 10 ether);
        vm.prank(bystander);
        depositAdapterInstance.depositETHForWeETH{value: 10 ether}(address(0));

        vm.deal(depositor, 200_000 ether);
    }

    //---------------------------------------------------------------------------------
    //  The protocol-wide numbers the swap must not touch
    //---------------------------------------------------------------------------------

    /// @dev The whole safety argument in one test: a deposit leaves the rate, the share
    ///      ledger and every other holder exactly where they were.
    function testFuzz_directMintLeavesRateAndOtherHoldersUntouched(uint256 _amount) public {
        // Below ~1 gwei a deposit mints zero shares at the live rate and LiquidityPool
        // rejects it with InvalidAmount. That floor predates this change.
        uint256 amount = bound(_amount, 1 gwei, 100_000 ether);

        uint256 rateBefore = liquidityPoolInstance.amountForShare(1 ether);
        uint256 weEthRateBefore = weEthInstance.getRate();
        uint256 pooledBefore = liquidityPoolInstance.getTotalPooledEther();
        uint256 sharesBefore = eETHInstance.totalShares();
        uint256 bystanderWeEth = weEthInstance.balanceOf(bystander);
        uint256 bystanderEEth = eETHInstance.balanceOf(bystander);

        vm.prank(depositor);
        uint256 minted = depositAdapterInstance.depositETHForWeETH{value: amount}(address(0));

        // Pooled ETH and the share ledger move by exactly the deposit and exactly the
        // shares minted for it — the same as any other deposit.
        assertEq(liquidityPoolInstance.getTotalPooledEther(), pooledBefore + amount, "pooled ETH");
        assertEq(eETHInstance.totalShares(), sharesBefore + minted, "total shares");

        // The rate is a pure function of those two, so it is unchanged.
        assertEq(liquidityPoolInstance.amountForShare(1 ether), rateBefore, "eETH rate moved");
        assertEq(weEthInstance.getRate(), weEthRateBefore, "weETH rate moved");

        // Nobody else's position moves.
        assertEq(weEthInstance.balanceOf(bystander), bystanderWeEth, "bystander weETH moved");
        assertEq(eETHInstance.balanceOf(bystander), bystanderEEth, "bystander eETH moved");
    }

    /// @dev weETH supply stays fully backed by eETH shares held in the weETH contract.
    function testFuzz_backingInvariantHoldsWithEquality(uint256 _amount) public {
        uint256 amount = bound(_amount, 1 gwei, 100_000 ether);

        uint256 supplyBefore = weEthInstance.totalSupply();
        uint256 proxySharesBefore = eETHInstance.shares(address(weEthInstance));

        vm.prank(depositor);
        uint256 minted = depositAdapterInstance.depositETHForWeETH{value: amount}(address(0));

        assertEq(weEthInstance.totalSupply(), supplyBefore + minted, "supply delta");
        assertEq(eETHInstance.shares(address(weEthInstance)), proxySharesBefore + minted, "backing delta");
        assertLe(weEthInstance.totalSupply(), eETHInstance.shares(address(weEthInstance)), "underbacked");
    }

    //---------------------------------------------------------------------------------
    //  Old path vs new path, on identical state
    //---------------------------------------------------------------------------------

    /// @dev Runs the retired wrap path and the direct-mint path from the same snapshot and
    ///      compares. The depositor is never worse off, and never better off by more than
    ///      the 2 wei the double flooring used to discard.
    function testFuzz_directMintMatchesWrapPathWithinTwoWei(uint256 _amount) public {
        uint256 amount = bound(_amount, 1 gwei, 100_000 ether);

        uint256 snap = vm.snapshotState();

        // Old path, reproduced by hand: take the shares, convert to an eETH amount, wrap.
        vm.startPrank(depositor);
        uint256 shares = liquidityPoolInstance.deposit{value: amount}(address(0));
        uint256 eEthAmount = liquidityPoolInstance.amountForShare(shares);
        IERC20(address(eETHInstance)).approve(address(weEthInstance), eEthAmount);
        uint256 viaWrap = weEthInstance.wrap(eEthAmount);
        vm.stopPrank();

        vm.revertToState(snap);

        // New path.
        vm.prank(depositor);
        uint256 viaDirectMint = depositAdapterInstance.depositETHForWeETH{value: amount}(address(0));

        assertGe(viaDirectMint, viaWrap, "direct mint pays less than wrap");
        assertLe(viaDirectMint - viaWrap, 2, "direct mint pays more than the reclaimed dust");
    }

    /// @dev The reclaimed wei is the dust that used to pile up on the adapter, so the
    ///      adapter no longer accrues an eETH balance on the ETH path.
    function test_directMintStrandsNoDustOnAdapter() public {
        uint256 adapterEEthBefore = eETHInstance.balanceOf(address(depositAdapterInstance));

        vm.startPrank(depositor);
        for (uint256 i = 0; i < 20; i++) {
            depositAdapterInstance.depositETHForWeETH{value: 1 ether + i}(address(0));
        }
        vm.stopPrank();

        assertLe(
            eETHInstance.balanceOf(address(depositAdapterInstance)),
            adapterEEthBefore + 1,
            "adapter still accruing dust"
        );
    }

    /// @dev Depositing and immediately unwrapping returns the deposit, minus only the
    ///      rounding the eETH share math has always had.
    function testFuzz_depositUnwrapRoundTrip(uint256 _amount) public {
        uint256 amount = bound(_amount, 1 gwei, 100_000 ether);

        vm.startPrank(depositor);
        uint256 minted = depositAdapterInstance.depositETHForWeETH{value: amount}(address(0));
        uint256 eEthBack = weEthInstance.unwrap(minted);
        vm.stopPrank();

        assertLe(eEthBack, amount, "round trip returned more than deposited");
        assertApproxEqAbs(eEthBack, amount, 3, "round trip lost more than rounding");
    }

    //---------------------------------------------------------------------------------
    //  The WETH path
    //---------------------------------------------------------------------------------

    function test_wethPathMintsDirectly() public {
        uint256 rateBefore = weEthInstance.getRate();

        vm.startPrank(depositor);
        wETH.deposit{value: 50 ether}();
        wETH.approve(address(depositAdapterInstance), 50 ether);
        uint256 minted = depositAdapterInstance.depositWETHForWeETH(50 ether, address(0));
        vm.stopPrank();

        assertEq(weEthInstance.balanceOf(depositor), minted, "depositor balance");
        assertEq(weEthInstance.getRate(), rateBefore, "weETH rate moved");
        assertLe(weEthInstance.totalSupply(), eETHInstance.shares(address(weEthInstance)), "underbacked");
    }

    //---------------------------------------------------------------------------------
    //  mintFor cannot inflate supply
    //---------------------------------------------------------------------------------

    /// @dev The backing check, not the role, is what bounds the mint. Even the authorised
    ///      caller cannot mint weETH that no eETH share backs.
    function test_mintForRevertsWhenNotBacked() public {
        // Read these before pranking — a view call would consume the prank.
        uint256 supplyAfterMint = weEthInstance.totalSupply() + 1 ether;
        uint256 backing = eETHInstance.shares(address(weEthInstance));

        vm.expectRevert(
            abi.encodeWithSelector(WeETH.WeETHUnderbacked.selector, supplyAfterMint, backing)
        );
        vm.prank(address(depositAdapterInstance));
        weEthInstance.mintFor(depositor, 1 ether);
    }

    function test_mintForRevertsForUnauthorisedCaller() public {
        vm.prank(depositor);
        vm.expectRevert();
        weEthInstance.mintFor(depositor, 1 ether);
    }

    function test_mintForRejectsZeroArguments() public {
        vm.startPrank(address(depositAdapterInstance));
        vm.expectRevert(WeETH.ZeroAmount.selector);
        weEthInstance.mintFor(depositor, 0);

        vm.expectRevert(WeETH.ZeroAddress.selector);
        weEthInstance.mintFor(address(0), 1 ether);
        vm.stopPrank();
    }

    //---------------------------------------------------------------------------------
    //  depositETHToRecipient gating
    //---------------------------------------------------------------------------------

    function test_depositETHToRecipientRevertsForUnauthorisedCaller() public {
        vm.deal(depositor, 1 ether);
        vm.prank(depositor);
        vm.expectRevert();
        liquidityPoolInstance.depositETHToRecipient{value: 1 ether}(depositor, address(0));
    }

    /// @dev The adapter mints straight to the depositor now, so it should never be left
    ///      holding weETH — not before a deposit, and not after one.
    function test_adapterNeverRetainsWeETH() public {
        assertEq(weEthInstance.balanceOf(address(depositAdapterInstance)), 0, "weETH held before deposit");

        vm.prank(depositor);
        depositAdapterInstance.depositETHForWeETH{value: 100 ether}(address(0));

        assertEq(weEthInstance.balanceOf(address(depositAdapterInstance)), 0, "weETH held after deposit");
    }
}
